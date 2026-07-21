# Design — Imported-Audio Analysis for AI Composition (`clip.analyzeAudio`, m21-e)

**Status**: design only, not implemented. **Date**: 2026-07-20.
**Goal**: give agents harmonic/tempo/spectral ground truth about an imported audio clip — key
estimate, tempo/beat estimate, spectral-balance summary, duration/levels — so "compose matching
tracks for this song" starts from measurement, not guesswork. Offline only; the render thread is
never involved. Honest probabilistic framing throughout: confidences and alternatives, never fake
certainty.

## 1. Verified current state (grep/read, 2026-07-20)

- **Onset front-end exists**: `Sources/DAWEngine/Analysis/TransientAnalyzer.swift` — spectral flux
  over 1024-sample Hann frames at 256 hop (`windowSize`/`hopSize`, lines 34-35), vDSP packed real
  FFT, Nyquist-zeroed bin-0 convention (line 195). `spectralFlux(monoSamples:)` (line 151) is a
  module-internal `static` pure function taking samples — a clean reuse seam that needs **no
  change to TransientAnalyzer** (its `analyzerVersion`/cache semantics stay untouched).
- **Band machinery exists**: `Sources/DAWEngine/Analysis/MasterMixAnalyzer.swift` — 24 geometric
  bands 40 Hz → 16 kHz (`bandEdges`, line 80; `bandIndex(containing:)`, line 87, both `public
  static`), bin→band contiguous-run mapping (init, lines 185-206), dB floor −80 convention
  (`MasterAnalysisSnapshot.floorDB`, `Sources/DAWCore/Model.swift:1889`).
- **Offline-clip-analysis idiom**: `clip.detectTransients` (Commands.swift:1841) → 
  `ProjectStore.detectClipTransients(clipId:sensitivity:)`
  (`Sources/DAWCore/ProjectStore+Quantize.swift:47`) — clipId-ONLY param (no trackId;
  `locateClipIndex` is global), MIDI-clip rejection **before** the engine guard, re-locate-by-id
  after the await (spec §8 risk 7), read-only/no-undo/nothing-persisted. Engine seam:
  `AudioEngineControlling.detectTransients(inFileAt:sensitivity:)`
  (`Sources/DAWCore/EngineProtocol.swift:345`, protocol at :301, `@MainActor`), no-op default
  at :689.
- **Cache discipline**: `Sources/DAWEngine/Analysis/TransientCache.swift` — `@MainActor` service,
  SHA256 content key (path ‖ size ‖ mtime bits ‖ quantized-param bits ‖ analyzerVersion, line 53),
  JSON sidecars under `~/Library/Caches/DAWPro/<domain>/`, single-flight coalescing, blocking
  vDSP work inside `Task.detached` (line 118), write-partial + atomic rename, `analysisCount`
  test spy. `AudioEngine.detectTransients` (AudioEngine.swift:1152) is a 2-line forward to it.
- **Offline-measurement API precedent**: `Sources/DAWCore/Loudness.swift` — Codable result struct
  IS the wire shape (wire-never-drifts), nil = honest "no signal" encoding, doc comment per field
  with units.
- **Clip window fields**: `Clip.audioFileURL` (Model.swift:463), `startOffsetSeconds` (:476),
  `stretchRatio` (:499, elapsed timeline seconds = source seconds × stretchRatio — see
  ProjectStore+Quantize.swift:83), `pitchShiftSemitones` (:503, −24…24),
  `sourceWindowSeconds(tempoMap:)` (:579).
- **Errors**: `ProjectError.transientsRequireAudioClip` message is contract-frozen and names
  `clip.detectTransients` (MediaImporting.swift:307) — NOT reusable here; a new case is needed.
- **Counts before this feature**: wire 142 commands, MCP 145 tools, copilot catalog 59 entries
  (`grep -c "CopilotTool(" CopilotCatalog.swift` = 59). Additive-only law; new wire names append
  at the END of `CommandRouter.allCommands` (Commands.swift:153).
- **Fixture precedents**: `Tests/DAWEngineTests/TransientAnalyzerTests.swift` — deterministic
  in-test synthesis (clickTrain/LCG noise), mono Float32 WAV writer, `[measured]` prints,
  `.serialized` for disk-touching cache tests. `OfflineRenderer` renders polySynth headless
  (`Tests/DAWEngineTests/InstrumentRenderTests.swift:40,150`).

## 2. Decisions at a glance

| Question | Decision |
|---|---|
| Command | **`clip.analyzeAudio { clipId }`** — clip-based, clipId-only (the `clip.detectTransients` signature exactly); no file-path command in v1 |
| Analysis scope | **The clip's current source window** `[startOffsetSeconds, +sourceWindowSeconds)` — not the whole file (aggregate answers can't be window-filtered post-hoc, unlike transient maps) |
| Key algorithm | FFT-folded 12-bin chroma (16384-pt FFT, hop 8192, fold 55 Hz–3.52 kHz) + Krumhansl-Kessler 24-profile Pearson correlation; best + confidence + `tonal` flag + top-3 alternatives |
| Tempo algorithm | Onset-envelope autocorrelation over the **reused `TransientAnalyzer.spectralFlux`** front-end; fold to the 70–180 BPM lattice, report unfolded/half/double alternates; `steady` flag from 4-segment agreement; beat-phase offset |
| Spectral balance | Mean power spectrum of the same 16384-pt STFT → the MasterMixAnalyzer 24-band geometry (dB, −80 floor) + centroid + 6 verbal macro-bands (sub/bass/lowMid/mid/highMid/air) |
| Chord tracking | **SKIPPED v1** (filed follow-up — needs beat-synchronous Viterbi decoding and its own result-lane API design; template-only chord accuracy on real mixes is too poor to ship honestly) |
| No tuning knobs | Zero params besides clipId — deterministic defaults keep the cache key simple; tuning changes bump `analyzerVersion` |
| Cache | New `AudioAnalysisCache` (TransientCache clone), key = source path ‖ size ‖ mtime ‖ **window offsets quantized to 1 ms** ‖ analyzerVersion |
| Stretch/pitch honesty | Results are SOURCE-domain; response echoes `stretchRatio`/`pitchShiftSemitones` and adds a derived `playback {bpm, key}` block when the clip is non-identity |
| Engine seam | One additive `AudioEngineControlling` method with a **throwing** default (an empty analysis would be a lie, unlike an empty marker list) |
| MCP / catalog | `clip_analyze_audio` (read-only ⇒ direct `server.registerTool`), 145→146; copilot catalog 59→60 with when-to-call teaching |

**Why clip-based, not `audio.analyze {path}`:** every precedent (`clip.detectTransients`,
`clip.quantizeAudio`, `take.autoAlign`) targets project clips; a path command would open sandbox/
file-permission questions the control plane has never had to answer, invite agents to analyze
files that aren't in the project (then compose against material the user can't hear), and skip
the clip-echo honesty (stretch/pitch) that makes the numbers composition-safe. Import first is
already one command. The path variant is a filed follow-up if a real workflow demands it.

**Why clipId-only (deviation from the task sketch's `{trackId, clipId}`):** the read-only clip
analysis precedent is clipId-only — `detectClipTransients` locates globally via
`locateClipIndex` (ProjectStore+Quantize.swift:51). A required trackId would add a
failure mode (mismatched pair) with zero disambiguation value.

**Why window-scoped, not whole-file (deviation from TransientCache's geometry-free rule):**
transient maps are dense per-file data filterable to any window after the fact, so whole-file is
the perfect cache unit. Key/tempo/balance are **aggregates** — a whole-file answer for a clip
trimmed to one section is simply the wrong answer, and un-filterable. The window therefore enters
the analysis and the cache key. Cost: a trim re-analyzes (~1-2 s, single-flighted); accepted.

## 3. Algorithms (all offline, Accelerate/vDSP, in `Task.detached` — never the render thread)

### 3a. Key — chroma + Krumhansl-Schmuckler

1. Windowed mono read of the clip's source window (loop-read with `framePosition` seek; channel
   average — the `TransientAnalyzer.readMono` recipe in a new windowed helper).
2. STFT: 16384-pt Hann, hop 8192, vDSP packed real FFT (the Nyquist-zero convention). At 48 kHz:
   bin width 2.93 Hz, one frame per ~171 ms → ~1,758 frames for 5 min.
3. Per frame (skipping frames with RMS < −60 dBFS — silence must not dilute the profile):
   accumulate spectral **magnitude** of every bin whose center lies in 55 Hz (A1) … 3520 Hz (A7)
   into 12 pitch-class bins by nearest equal-tempered semitone, A440 reference. (Bin width
   2.93 Hz < the 3.27 Hz semitone spacing at 55 Hz — the folding is well-resolved at the bottom
   without a constant-Q transform; that is why the FFT is 16384.)
4. Average over frames → one 12-vector. Pearson-correlate against all 24 rotations of the
   Krumhansl-Kessler major/minor profiles → ranked (tonic, mode, r).
5. Output: best key, `alternatives` = next 3 with scores, and
   `confidence = clamp01(r1) × clamp01((r1 − r2) / 0.1)` (margin-gated — a strong but ambiguous
   profile reads low). `tonal = (r1 ≥ 0.5 AND chroma spectral flatness ≤ 0.95)`; percussion-only
   and atonal material reads `tonal: false` (ranked guesses still reported — agents are taught to
   trust `tonal` first). Constants are v1 tuning, re-keyed by `analyzerVersion`.

**Honest accuracy expectation** (doc statement, not CI contract): ~70% exact key on real
commercial mixes; truth in top-3 ~90%. Classic failure modes, stated in the MCP/catalog text:
relative major/minor confusion (the #1 miss), perfect-fifth errors, **modulating songs** (one
aggregate profile → whichever key dominates wins, confidence sags), atonal/percussion-only
(`tonal:false`), non-A440 tunings more than ~30 cents off the semitone grid (rare). Fixture
contract is §7's fixed numbers.

### 3b. Tempo — onset autocorrelation with octave discipline

1. `TransientAnalyzer.spectralFlux(monoSamples:)` on the same windowed mono read (1024/256
   geometry → envelope rate = rate/256 = 187.5 Hz at 48 kHz).
2. Detrend: subtract a 1 s moving mean, half-wave rectify.
3. FFT-based autocorrelation, normalized by lag 0, over lags 0.25–2.0 s (30–240 BPM).
4. Candidates: local ACF maxima. Fold each into the **70–180 BPM lattice** by doubling/halving;
   a folded candidate's score sums its unfolded family (weight 1.0 direct, 0.5 half/double
   members). Winner = `bpm`, refined by parabolic interpolation of its direct ACF peak.
   `alternates` (≤ 3, each `{bpm, score}`) always include the RAW unfolded ACF winner when it
   differs — so a true 60 BPM pulse reports `bpm: 120` (lattice convention, stated in the field
   docs) with 60 listed first among alternates.
5. `confidence = clamp01((p − m) / 0.4)` where p = winner's direct ACF value, m = median ACF over
   the lag range. `bpm` is **null** when p − m < 0.08 (no periodic evidence) or the window < 6 s.
6. `steady`: split the window into 4 equal segments (each ≥ 5 s; fewer segments below 20 s),
   estimate per-segment folded BPM; `steady = true` iff max pairwise deviation ≤ 4% AND
   confidence ≥ 0.3. Rubato, free time, and mid-song tempo changes read `steady: false` — the
   agent-facing meaning is "a fixed project tempo can match this clip".
7. `beatOffsetSeconds`: best circular phase of an impulse comb at the winning period against the
   onset envelope — seconds from the analyzed window's start to the first beat (< one period).
   Null when `bpm` is null.

### 3c. Spectral balance — reuse the 24-band shape

From the SAME 16384-pt STFT pass as chroma (one pass serves both): accumulate the mean power
spectrum over ALL frames (no silence gate — balance describes the clip as it plays), then:
- `bands`: the 24 `MasterMixAnalyzer.bandEdges` geometric bands 40 Hz–16 kHz, mean power density
  per band in dB, −80 floor (at 2.93 Hz bin width every band owns ≥ 4 bins — no empty-band
  special case).
- `centroidHz`: power-weighted mean frequency (bins 1…half).
- `summary` (beginner/agent-readable macro bands, mean power density dB, −80 floor):
  `subDb` 20–60 Hz, `bassDb` 60–250, `lowMidDb` 250–500, `midDb` 500–2000, `highMidDb` 2000–6000,
  `airDb` 6000–16000 (edges clamped to [bin 1, Nyquist)).

### 3d. Levels

`samplePeakDb` (vDSP_maxmgv → 20·log10, −80 floor), `rmsDb` (vDSP_rmsqv → dB, −80 floor),
`durationSeconds` (the analyzed window), `windowStartSeconds`, `sampleRate` (source file's).
Not LUFS — the response text points agents at `render.measureLoudness` for BS.1770.

## 4. Engine API, DTOs, cache

New file `Sources/DAWCore/AudioAnalysis.swift` (the Loudness.swift precedent — Codable IS the
wire shape, every field doc-commented with units):

```swift
public struct KeyAlternative: Codable, Sendable, Equatable {
    public var tonic: String      // "C", "C#", … "B" (sharps canonical)
    public var mode: String       // "major" | "minor"
    public var score: Double      // Pearson r, −1…1
}
public struct KeyEstimate: Codable, Sendable, Equatable {
    public var tonic: String
    public var mode: String
    public var confidence: Double        // 0…1, margin-gated (NOT a probability)
    public var tonal: Bool               // false ⇒ don't trust tonic/mode (percussion/atonal)
    public var alternatives: [KeyAlternative]  // next 3, ranked
}
public struct TempoAlternate: Codable, Sendable, Equatable {
    public var bpm: Double
    public var score: Double
}
public struct TempoEstimate: Codable, Sendable, Equatable {
    public var bpm: Double?              // nil = no periodic evidence / window < 6 s
    public var confidence: Double        // 0…1 ACF-prominence
    public var steady: Bool              // "a fixed project tempo can match this clip"
    public var beatOffsetSeconds: Double?  // first beat, seconds from window start; nil with bpm
    public var alternates: [TempoAlternate]  // incl. half/double + raw unfolded winner
}
public struct SpectralSummary: Codable, Sendable, Equatable {
    public var subDb, bassDb, lowMidDb, midDb, highMidDb, airDb: Double  // dB, −80 floor
}
public struct SpectralBalance: Codable, Sendable, Equatable {
    public var bands: [Double]           // 24 log bands 40 Hz–16 kHz, dB, −80 floor
    public var centroidHz: Double
    public var summary: SpectralSummary
}
public struct AudioContentAnalysis: Codable, Sendable, Equatable {   // engine-level result
    public var durationSeconds: Double   // analyzed window
    public var windowStartSeconds: Double
    public var sampleRate: Double
    public var samplePeakDb: Double      // −80 floor
    public var rmsDb: Double             // −80 floor
    public var key: KeyEstimate
    public var tempo: TempoEstimate
    public var spectral: SpectralBalance
    public var analyzerVersion: Int
}
public struct ClipPlaybackProjection: Codable, Sendable, Equatable { // only when non-identity
    public var bpm: Double?              // source bpm ÷ stretchRatio
    public var keyTonic: String?         // transposed by pitchShift iff integral (±0.01), else nil
    public var keyMode: String?
}
public struct ClipAudioAnalysisResult: Codable, Sendable, Equatable { // store-level = wire shape
    public var analysis: AudioContentAnalysis
    public var stretchRatio: Double
    public var pitchShiftSemitones: Double
    public var playback: ClipPlaybackProjection?   // nil (omitted) for identity clips
}
```

Protocol addition (`AudioEngineControlling`, EngineProtocol.swift, additive):

```swift
func analyzeAudioContent(inFileAt url: URL, windowStartSeconds: Double,
                         windowDurationSeconds: Double) async throws -> AudioContentAnalysis
```

Default implementation **throws `ProjectError.engineUnavailable`** — deliberate deviation from
`detectTransients`'s `[]` default: an empty marker list is honest, a fabricated all-floors
analysis is not. Fakes that need the surface override it.

Engine side, `Sources/DAWEngine/Analysis/`:
- `AudioContentAnalyzer.swift` — orchestrator `enum` (the TransientAnalyzer shape):
  `analyzerVersion = 1`, windowed `readMono(url:startSeconds:durationSeconds:)` helper
  (TransientAnalyzer.readMono is NOT refactored — its loop-read recipe is duplicated windowed;
  keeping the shipped analyzer byte-untouched outweighs 30 lines of DRY), and a pure
  `analyze(monoSamples:sampleRate:) -> AudioContentAnalysis` core testable without files.
- `KeyEstimator.swift`, `TempoEstimator.swift` — pure static sub-analyzers (separately testable).
- `AudioAnalysisCache.swift` — TransientCache clone: `@MainActor`, sidecars at
  `~/Library/Caches/DAWPro/AudioAnalysis/<key>.json`, key = SHA256(path ‖ size ‖ mtime bits ‖
  windowStart-quantized-1ms bits ‖ windowDuration-quantized-1ms bits ‖ analyzerVersion),
  single-flight, `Task.detached(priority: .userInitiated)`, partial + atomic rename,
  `analysisCount` spy. `AudioEngine` gains `var audioAnalysisCache` + the 2-line forward
  (the :1152 pattern).

`ProjectStore` (extension in `ProjectStore+Quantize.swift` or a new `ProjectStore+Analysis.swift`
— recommend the new file, the domain is analysis not quantize):
`analyzeClipAudio(clipId: UUID) async throws -> ClipAudioAnalysisResult` — locate (else
`clipNotFound`), reject MIDI with NEW `ProjectError.analysisRequiresAudioClip(UUID)` ("clip … is
a MIDI clip — clip.analyzeAudio applies only to audio clips (read MIDI notes directly for key and
timing)"), reject a window < 1.0 s with a teaching `invalidClipEdit`, guard engine
(`engineUnavailable`), call the engine with the clip's window, **re-locate after the await**
(spec §8 risk 7 — the clip may be gone; window edits mid-flight are harmless, the result matches
the requested window), attach stretch/pitch echo + `playback` projection. Read-only: no
`performEdit`, no undo, nothing persisted or snapshotted.

## 5. Wire command (142 → 143)

`clip.analyzeAudio` — appended at the END of `CommandRouter.allCommands` (additive-at-end law).
params: `clipId` (required UUID). `rejectUnknownKeys(["clipId"])`. Handler doc comment states:
read-only, cached per (file, window), source-domain results, the lattice/fold convention, and the
null semantics. Response = `ClipAudioAnalysisResult` encoded verbatim:

```json
{ "analysis": { "durationSeconds": 212.4, "windowStartSeconds": 0, "sampleRate": 44100,
    "samplePeakDb": -0.3, "rmsDb": -14.2,
    "key": { "tonic": "A", "mode": "minor", "confidence": 0.78, "tonal": true,
             "alternatives": [ { "tonic": "C", "mode": "major", "score": 0.71 }, … ] },
    "tempo": { "bpm": 128.2, "confidence": 0.86, "steady": true, "beatOffsetSeconds": 0.113,
               "alternates": [ { "bpm": 64.1, "score": 0.58 } ] },
    "spectral": { "bands": [ -38.1, … 24 values … ], "centroidHz": 1834.0,
        "summary": { "subDb": -38.1, "bassDb": -20.3, "lowMidDb": -18.9, "midDb": -16.4,
                     "highMidDb": -22.0, "airDb": -30.5 } },
    "analyzerVersion": 1 },
  "stretchRatio": 1.0, "pitchShiftSemitones": 0.0 }
```

Errors (LocalizedError-mapped teaching text): MIDI clip → `analysisRequiresAudioClip`; unknown id
→ `clipNotFound`; no engine → `engineUnavailable`; unreadable source → the analyzer's
`.unreadable` naming the path; window < 1 s → "too short to analyze (needs ≥ 1.0 s; tempo needs
≥ 6 s)".

## 6. MCP tool (145 → 146) + copilot catalog (59 → 60) + plugin partition

- `clip_analyze_audio` in `mcp-server/src/server.ts` — read-only ⇒ direct `server.registerTool`
  (the `clip_detect_transients` precedent, :2935). zod: `clipId: z.string().uuid()`. Description
  teaches: WHEN (the FIRST move after importing a full song, before composing/arranging to match
  it), WHAT each field means with units, confidence-is-not-probability, `tonal:false` /
  `bpm:null` / `steady:false` honesty, the 70–180 fold convention + alternates, source-domain vs
  `playback` on stretched/pitched clips, and cached-so-repeat-calls-are-instant.
- Copilot catalog entry after the `clip.detectTransients` group (`CopilotCatalog.swift`), count
  pin 59→60; same teaching compressed to ~2 sentences with the WHEN framing up front ("Before
  composing over an imported song, call this…"). `CopilotCatalogTests` picks it up by
  construction.
- Claude-plugin partition: grant `clip_analyze_audio` to COMPOSER and ARRANGER (the agents that
  compose against imported material); regenerate the bundled server; `claude plugin validate
  --strict`.

## 7. Performance budget

For a 5-min 48 kHz stereo file (14.4 M frames): windowed mono read ~58 MB transient allocation
(the TransientAnalyzer whole-file precedent; freed at task end) + streaming decode I/O; flux
front-end ≈ 56,250 × 1024-pt FFTs ≈ 0.2-0.4 s; chroma/balance pass ≈ 1,758 × 16384-pt FFTs
≈ 0.1-0.2 s; ACF + profile correlation + folding: negligible (< 10 ms). **Budget: ≤ 2 s typical
on Apple silicon, ≤ 5 s hard for a 5-min file** — printed as `[measured]` in the perf test, bar
fixed at 5 s. All of it inside the cache's `Task.detached`; the main actor blocks only for the
await (UI stays live, matching detectTransients). Repeat calls: sidecar hit, ~0 ms.

## 8. Test plan (fixed thresholds — no goal-post moving)

`Tests/DAWEngineTests/AudioContentAnalyzerTests.swift` (+ KeyEstimator/TempoEstimator units),
`.serialized` where disk is touched; synthesis in-test (clickTrain/LCG precedents):

- **KEY (6 fixtures, exact-match REQUIRED, confidence ≥ 0.6, tonal:true)**: sine-triad
  progressions with 3 harmonics (1, 0.5, 0.25 amplitude), 4 chords × 2 s each — C major
  (C-F-G-C), D major ii-V-I (Em-A-D as rendered chords), F# major, A minor (Am-Dm-E-Am),
  C# minor, G minor. One END-TO-END fixture rendered through `OfflineRenderer` + polySynth
  playing the D-major ii-V-I (InstrumentRenderTests harness) — real instrument timbre, same
  exact-match bar.
- **KEY negative**: click train + LCG noise bursts (percussion-only) → `tonal: false`.
- **TEMPO (3 fixtures)**: click trains at 90.0, 120.0, 174.0 BPM, 30 s →
  `|bpm − truth| ≤ 0.5`, `steady: true`, confidence ≥ 0.6. One at 44.1 kHz (rate-independence
  pin). **Fold pin**: 60 BPM click → `bpm` 120 ± 0.5 with 60 ± 0.5 present in alternates.
  **Phase pin**: 120 BPM clicks first-click at 0.250 s → `beatOffsetSeconds` within ± 0.025 of
  0.250 (mod 0.5).
- **TEMPO negatives**: 100 BPM for 15 s then 140 BPM for 15 s → `steady: false`. Pink noise
  (filtered LCG) 30 s → `bpm == nil`.
- **SPECTRAL**: 1 kHz sine → `summary.midDb` the max macro band, every other macro band ≥ 30 dB
  below it, centroid 1000 ± 50 Hz. Pink noise → linear fit of band dB vs log2(centerHz) has slope
  −3.0 ± 0.75 dB/octave. Silence → all bands/levels exactly −80.
- **LEVELS**: 0.5-amplitude sine → peak −6.02 ± 0.1 dB, RMS −9.03 ± 0.1 dB.
- **WINDOW**: a file whose first half is A-minor material at 100 BPM and second half C-major-ish
  at 140 — a clip windowed to each half must report THAT half's key/tempo (the window-scoped
  contract pinned).
- **CACHE** (TransientCacheTests clone): hit skips analyzer (`analysisCount`), window change
  re-keys, mtime re-keys, corrupt sidecar self-heals, same-key coalescing.
- **PERF**: 5-min synthesized file, `[measured]` wall print, bar 5 s.
- **DAWControlTests** (fake engine overriding the throwing default): error taxonomy of §5, wire
  shape stability (incl. `playback` present iff non-identity, nil-field omission),
  rejectUnknownKeys, headless `engineUnavailable`.
- **mcp-server npm**: registration/parity counts (146), description-teaches-when smoke.
- **Staging live gate (port 17695 ONLY — never 17600)**: import a real song, `clip.analyzeAudio`
  round-trip sanity (plausible key/bpm, bands finite), repeat-call cache timing, then a REAL
  copilot round: "what key and tempo is this imported clip?" must be tool-call-visible and quote
  the response's confidences.

## 9. v1 scope cuts — filed follow-ups

1. **Chord-progression tracking** (beat-synchronous chroma + Viterbi over chord templates; needs
   its own result-surface design — chord lane/markers — and honest accuracy work).
2. **Per-section analysis** (verse/chorus segmentation; self-similarity matrix — the window
   contract above already gives agents manual sectioning via trimmed clips).
3. **Live/streaming analysis** (analyze-while-recording; different machinery entirely).
4. **Arbitrary-file analysis** (`audio.analyze {path}` — sandbox/permission questions).
5. **Tuning-offset estimation** (non-A440 material; 10-cent chroma refinement).
6. **Beat-grid export** (conform project tempo map to the clip's detected beats — wants full beat
   TRACKING, not one global phase).

## 10. Implementation touch points

| File | Change |
|---|---|
| `Sources/DAWCore/AudioAnalysis.swift` | NEW — all §4 DTOs |
| `Sources/DAWCore/EngineProtocol.swift` | `analyzeAudioContent(…)` + throwing default |
| `Sources/DAWCore/MediaImporting.swift` | `ProjectError.analysisRequiresAudioClip` + message |
| `Sources/DAWCore/ProjectStore+Analysis.swift` | NEW — `analyzeClipAudio(clipId:)` |
| `Sources/DAWEngine/Analysis/AudioContentAnalyzer.swift` | NEW — orchestrator + windowed mono read |
| `Sources/DAWEngine/Analysis/KeyEstimator.swift`, `TempoEstimator.swift` | NEW — pure sub-analyzers |
| `Sources/DAWEngine/Analysis/AudioAnalysisCache.swift` | NEW — TransientCache clone |
| `Sources/DAWEngine/AudioEngine.swift` | cache property + forward |
| `Sources/DAWControl/Commands.swift` | `clip.analyzeAudio` (allCommands END + handler) |
| `Sources/DAWControl/CopilotCatalog.swift` | catalog entry, 59→60 |
| `mcp-server/src/server.ts` | `clip_analyze_audio`, 145→146 |
| `claude-plugin/` | grant to composer + arranger, bundle regen, validate --strict ×2 |
| Tests per §8; `docs/ARCHITECTURE.md` counts + settled-decision note; CHANGELOG; roadmap tick | close-out convention |

**Xcode requirement: NONE** — pure vDSP + wire/MCP; no entitlements, AUv3, or signing. Command
Line Tools + `./scripts/test.sh` suffice end to end.

**Route**: audio-dsp-engineer (engine/DAWCore §3-§4) then mcp-integration-engineer (§5-§6), one
building agent at a time.
