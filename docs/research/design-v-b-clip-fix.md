# M6 (v-b) Clip Vocal-Fix Flow — Design

Author: daw-architect. Status: settled, ready to implement (stub-first; real sidecar run is the v-c gate).
Baseline studied: v-a repaint client (`Sources/AIServices/Providers.swift` `RepaintRequest`/`RepaintMode`, `ACEStepClient.repaintAudio`, `ai.repaintAudio` in `Sources/DAWControl/Commands.swift` ~L1495), M5 takes (`Sources/DAWCore/Takes.swift`, `Sources/DAWCore/ProjectStore+Takes.swift`), M6 iii-a/c import (`Sources/DAWCore/ProjectStore+Generation.swift`, `Sources/DAWCore/GenerationImport.swift`, `Sources/DAWControl/GenerationImportSource.swift`), offline render seam (`Sources/DAWCore/EngineProtocol.swift` `renderOffline`/`writeAudioFile`, `Sources/DAWCore/ProjectStore+Render.swift`), recording undo pattern (`ProjectStore.finishTake`, `autoGroupRecordedTake`), Sketchpad poll precedent (`Sources/DAWAppKit/SketchpadModel.swift`).

## 0. Scope and slice split

One-cycle scope (**v-b-1**, this cycle, swift-app-engineer executable):
store methods + `GenerationImporting` seam growth + DAWControl adapter + two control commands (`ai.fixClipRegion`, `ai.importClipFix`) + two MCP tools + headless tests. Fully testable with fakes; no real sidecar, no UI.

Deferred (**v-b-2**, next cycle): UI affordance — region selection in the clip editor, a violet "Fix with AI" action, a `ClipFixModel` (DAWAppKit) that polls and calls the SAME store import path (Sketchpad precedent: model owns transitions, view owns the timer). The M5 take-lane UI already renders the resulting lanes/comp, so the feature is fully usable from MCP/control after v-b-1 alone.

No full-Xcode requirements anywhere in this design (no entitlements, no AUv3, no signing). Everything runs under `swift build` / `./scripts/test.sh`.

---

## 1. Decisions

### D1. What gets bounced for repaint: a DRY, AS-HEARD window render — region ± context padding, clamped, with clip fades STRIPPED on a plain-clip target

**Decision.** The repaint source is an offline render of the target material *as timeline material* (trim/offset/stretch/clip-gain applied; track inserts/sends/automation/volume/pan all stripped; master untouched), over a window = `[regionStart − context, regionEnd + context]` clamped to the material's span. Default `contextSeconds = 10`, caller-tunable 1…60. The repaint window (`repainting_start/end`) is expressed in seconds *within that bounced file*.

Rendered via the existing `engine.renderOffline` buffer seam with a **synthetic single track**: `Track(kind: .audio, volume: 1, pan: 0, effects: [], sends: [], automation: [], outputBusID: nil)` holding only the relevant clips, `masterVolume: 1`, `forcedCompensationTargets: nil` (no inserts ⇒ zero-latency plan), duration = exact window seconds (**no** +2 s mixdown tail — the file length must map 1:1 onto the timeline window). Written with `engine.writeAudioFile` to `NSTemporaryDirectory()/DAWPro/fix-bounce-<uuid8>.wav` (transient; the ACE-Step client stages its own copy into the sidecar allowlist, v-a behavior).

Which clips go into the synthetic track:
- **Plain clip target** (`takeGroupID == nil`): just that clip, with `fadeInBeats/fadeOutBeats` zeroed on the synthetic copy (see below), window clamped to the clip's span.
- **Comp-member target** (`takeGroupID == G`): all of track's current member clips of group `G` (the materialized comp — "what you hear"), window clamped to `G.rangeBeats`. Member joins' flattener-managed crossfades stay in (they ARE the as-heard comp output).

Why fades are stripped on the plain-clip path: `CompFlattener.flatten` emits members with fades zeroed ("fades default clean; the crossfade pass sets audio joins" — `Sources/DAWCore/Takes.swift`). The moment we group the original clip, its own fade-in/out stops rendering (existing M5 semantics). If the bounce baked those fades, the fix lane would carry faded material while the original lane plays unfaded — an audible mismatch outside the fix region, exactly where comping demands equivalence. Bounce must match what the original lane will sound like *post-grouping*. Clip `gainDb` and stretch/pitch stay IN the bounce because the flattener copies them onto members (they keep rendering) — and the fix lane neutralizes them (`gainDb 0`, `ratio 1`), so both lanes remain audibly equal outside the region.

**Alternatives rejected.**
- *Raw media segment* (slice source file bytes): loses stretch/gain, cannot represent a comp-member target at all, forces gnarly source-domain alignment math at import, and hands the model material that doesn't sound like the timeline. Loses on every axis.
- *Whole-clip bounce* (fix window inside the full clip): trivially simple alignment, maximal context — but ACE-Step diffuses over the *whole* source latents, so job time scales with clip length; a 2-bar fix on a 3-minute vocal comp becomes a multi-minute job on a local MPS sidecar, for zero benefit: everything outside the fix region from the returned file is **discarded by the comp anyway** (see D4 — upstream decodes non-repainted regions through its VAE, so the outside-window audio is a reconstruction, not the original samples; we deliberately never play it). 10 s of phrase-level context each side comfortably exceeds the upstream latent crossfade (10 × 25 Hz frames ≈ 0.4 s) and keeps job duration bounded and clip-length-independent.

**Failure modes handled.** Silent window (region over silence): legal, renders and submits — upstream will generate into silence; not our policy call. Engine absent (headless without fake): `engineUnavailable`. Region shorter than 0.1 s: rejected with a readable `invalidClipEdit` message (sub-latent-frame windows can't change anything; honest early error).

### D2. Region addressing on the wire: absolute TIMELINE BEATS, `trackId + clipId + startBeat/endBeat`

**Decision.** `ai.fixClipRegion` params: `trackId` (required), `clipId` (required), `startBeat`/`endBeat` (required, absolute timeline beats, `endBeat > startBeat`, region must lie inside the target clip's span). The store converts beats → seconds at the current tempo for the bounce and the `repainting_*` fields.

**Why.** Every editing command on the surface speaks absolute timeline beats: `clip.split atBeat`, `clip.move toStartBeat`, `take.setComp` segments (`CompSegment.startBeat/endBeat` are absolute beats by model invariant), `transport.setLoop`. Take lanes themselves store absolute beats ("no relative math is ever needed" — `Takes.swift`). An agent that just read `project.snapshot` can compute a fix region with zero unit conversion.

**Alternatives rejected.**
- *Clip-relative seconds*: forces every caller to do tempo/stretch math the store already owns; a stretched clip makes "seconds into the clip" ambiguous (source seconds vs timeline seconds).
- *File-domain seconds like `ai.repaintAudio`*: right for v-a (that command addresses a FILE), wrong here (this command addresses TIMELINE material; the file is an implementation detail the store manufactures).

### D3. Result alignment math: take lands at the window position, `offset 0`, `stretchRatio 1.0`

**Decision.** All frozen at submit time (beats at the submit-time tempo):

```
contextBeats       = contextSeconds * tempoBPM / 60
windowStartBeat    = max(spanStart, regionStartBeat − contextBeats)   // span = clip span (plain) or group range (member)
windowEndBeat      = min(spanEnd,   regionEndBeat  + contextBeats)
bounceSeconds      = (windowEndBeat − windowStartBeat) * 60 / tempoBPM
repaintStartSec    = (regionStartBeat − windowStartBeat) * 60 / tempoBPM
repaintEndSec      = (regionEndBeat  − windowStartBeat) * 60 / tempoBPM
```

The imported take-lane clip is exactly:

```
startBeat          = windowStartBeat (+ rebase delta, D6)
lengthBeats        = windowEndBeat − windowStartBeat
startOffsetSeconds = 0
stretchRatio       = 1.0, pitchShiftSemitones = 0, formantPreserve = false
gainDb             = 0, fades = 0/0 linear
audioFileURL       = stable copy of the repainted WAV
isAIGenerated      = true          // violet lane, violet members via CompFlattener
```

Because the bounce is rendered at project tempo with the source clip's stretch/gain **baked in**, the timeline↔file mapping is the identity: file second 0 ≡ `windowStartBeat`. A stretched original therefore yields a take at **rate 1.0 with equivalent audible timing** — the take must NOT inherit the stretch ratio (it would double-apply on already-stretched material, and the repainted region is new audio with no meaningful "unstretched source" anyway).

Duration rounding: ACE-Step output length can round to 25 Hz latent frames (±40 ms at the file tail). We pin `lengthBeats` to the *requested* window; a marginally shorter returned file plays honest silence in its last microsliver, a longer one is clip-trimmed — both irrelevant because the comp only ever plays the interior fix region (D4). Sample rate mismatch (engine 48 k vs sidecar output) is handled by the existing per-clip player SR conversion; alignment is defined in seconds/beats, not frames.

### D4. Take-lane integration: reuse the M5 group machinery; new lane + **comp SPLICE of the fix region only**; one `performEdit("AI Fix Take")`

**Decision.** On import:
- **Plain clip target**: remove the original clip from `track.clips`, create a `TakeGroup` with `lanes = [original (lane 0), fix lane]` — the `autoGroupRecordedTake` case-2 shape, inline, no nested `performEdit`. Base comp = `[original lane over full range]`, then splice.
- **Member / group target**: append the fix lane to the existing group, splice its current comp.
- **Comp splice** (new pure function): replace `[regionStartBeat, regionEndBeat)` in the comp with a segment on the fix lane; overlapping existing segments are trimmed/split/dropped; everything outside is untouched; result sorted, non-overlapping. Gaps stay legal.
- Everything — clip removal, group creation/lane append, comp set, `rebuildCompMembers` — inside ONE `performEdit("AI Fix Take")`, no coalescing key. One `edit.undo` restores the plain clip (or the previous comp/lane list) exactly; the WAV stays on disk for redo (the recording-take file-outlives-undo model).
- **Naming**: lane and its payload clip named `"AI Fix N"`, `N = 1 + count(lanes in this group whose name hasPrefix "AI Fix")` — the "Record Take N" per-scope counter precedent.
- **Comp default**: the fix region auto-selects the NEW lane; everything else keeps playing whatever it played before. Join smoothing = the group's existing `crossfadeSeconds` (default 10 ms equal-power) via `CompFlattener.applyCrossfades`, on top of upstream's ≈0.4 s latent crossfade *inside* the window making the window edges converge to the source.

**Why fix-region-only, not newest-wins full range (the recording default):** (1) the fix lane only spans the padded window — full-range selection would read silence across the rest of the group range; (2) upstream repaint returns the full bounced span *re-decoded through its VAE*, so outside-window audio is a near-identical reconstruction, NOT the original samples — auto-playing it would swap pristine material for a codec round-trip. The splice guarantees VAE-reconstructed audio outside the requested region never reaches the mix. The user asked to fix a region; the comp change is exactly that region.

**Alternative rejected:** landing the repainted file as an overlapping ordinary clip (no group) — violates the M5 model (sum-overlap double-play), gives no comping UX, and "member clips are store-managed" protection (`requireNotCompMember`) exists precisely so we don't invent a parallel mechanism.

### D5. Async ownership: EXPLICIT submit → poll → import, with a store-held in-memory pending registry

**Decision.** Three-step, caller-driven, matching the settled `ai.generateSong`/`ai.generationStatus`/`ai.importGeneration` shape:

1. `ai.fixClipRegion` → `ProjectStore.fixClipRegion(...)`: validates, bounces, submits via the seam, registers a `PendingClipFix` in `ProjectStore.pendingClipFixes: [String: PendingClipFix]` (in-memory, observable for the future UI, NOT persisted), returns `{jobId, …placement echo…}`. **No project mutation, no undo entry** — submit is a pure side-effect job.
2. Caller polls `ai.generationStatus` (unchanged — repaint job ids ride the ordinary status surface, v-a).
3. `ai.importClipFix {jobId}` → `ProjectStore.importClipFix(jobID:)`: fetches via the existing `GenerationImporting.fetchGeneration`, revalidates the target (D6), performs the single `performEdit("AI Fix Take")`, removes the pending record on success only.

The store (not the command layer) owns bounce+submit+import orchestration, so the SwiftUI app and the control protocol converge on the same `ProjectStore` methods — the one-command-surface invariant. `DAWCore` stays AI-free: `GenerationImporting` (the existing DAWCore seam) grows an additive `submitRepaint(_:)` with a throwing default (`generationSourceUnavailable`) so every existing conformer/fake compiles unchanged; `SongGenerationImportSource` (DAWControl) implements it over `SongGenerating.repaintAudio`.

**Alternatives rejected.**
- *Store auto-import on completion (background poll loop)*: mutates the project without a command — un-auditable on the control surface, surprises a user mid-edit, entangles Task lifecycle with undo, and makes crash semantics murky. The Sketchpad precedent deliberately keeps polling in the app-model layer and imports through an explicit call; v-b-2's `ClipFixModel` will do the same against `importClipFix`.
- *Fully stateless (submit response carries placement, caller passes it back to import)*: trusts the caller with alignment-critical data, and the store cannot honestly revalidate geometry drift (D6) against values a caller may have edited.

**Crash/reopen semantics:** pending records don't survive relaunch (v0, documented). The sidecar job may still finish; `ai.importClipFix` for an unknown job returns an actionable `clipFixJobNotFound` telling the caller to re-run `ai.fixClipRegion`. `project.open`/`project.new` clear `pendingClipFixes` (stale UUIDs point into the old project).

### D6. Target revalidation at import: fingerprint + move-rebase; everything else is an honest `clipFixStale`

The project can change during a minutes-long job. Pending records freeze a target descriptor:

```swift
enum PendingFixTarget {
    case clip(id: UUID, fingerprint: ClipGeometryFingerprint) // plain-clip submit
    case group(id: UUID, frozenRangeStart: Double, frozenRangeEnd: Double) // member submit
}
```

`ClipGeometryFingerprint` = `startBeat, lengthBeats, startOffsetSeconds, stretchRatio, pitchShiftSemitones, gainDb`. `PendingClipFix` also freezes `tempoBPM` at submit.

Import resolution rules:
- **`.group`**: locate the group (comp members are REBUILT with fresh clip UUIDs on every comp edit — `CompFlattener` doc — so the member clip id from submit time is worthless; the *group* id is the stable anchor). Comp edits during the job are fine (splice applies to the current comp). `delta = currentRange.lowerBound − frozenRangeStart`; if the range *shape* changed beyond a uniform shift (`moveTakeGroup` shifts lanes+comp uniformly), or tempo changed → `clipFixStale` with a message naming what changed.
- **`.clip`**: search `track.clips` first; if absent, search every group's `lanes[].clip` payloads on that track (a FIRST fix consumed the plain clip into a group — its payload keeps the clip id and geometry, so a SECOND pending fix on the same clip lands as another lane in the same group; queued fixes compose). Fingerprint must match except a pure `startBeat` delta (a clip/group move) → rebase `windowStartBeat/regionStart/regionEnd` by that delta. Any other drift (trim, re-stretch, re-gain, tempo change — the bounced material no longer matches what the lane will play) → `clipFixStale`. Deleted target → `clipFixStale` ("the original clip no longer exists…").

Rationale: a pure move is the common case during a long wait and is provably safe (identical material, uniform shift). Everything else genuinely invalidates boundary continuity; failing with a re-run instruction is honest, cheap, and testable. Tempo change additionally breaks beats↔seconds mapping of the *bounced material itself* — no rebase can save it.

---

## 2. End-to-end flow (reference walkthrough)

```
agent: ai.fixClipRegion {trackId, clipId, startBeat: 33, endBeat: 41, lyrics: "[Chorus]\n…", contextSeconds: 10}
  store.fixClipRegion:
    validate track/clip (audio, region inside span, ≥ 0.1 s)
    window = [33 − 20beats@120bpm→clamped, 41 + 20beats→clamped]   (tempo 120: contextBeats = 20)
    renderOffline(synthetic dry track, fromBeat: windowStart, exact seconds) → writeAudioFile(tmp wav)
    generationSource.submitRepaint(ClipRepaintRequest(path, repaintStartSec, repaintEndSec, prompt/lyrics/mode/strength/seed/model))
    pendingClipFixes["job-…"] = PendingClipFix(target:…, frozen beats, tempo)
  → {jobId, state:"queued", queuePosition?, windowStartBeat, windowEndBeat, regionStartBeat, regionEndBeat,
     repaintStartSeconds, repaintEndSeconds, bouncePath}

agent: ai.generationStatus {jobId}   (poll; unchanged command)
agent: ai.importClipFix {jobId}
  store.importClipFix:
    pending lookup → fetchGeneration(jobID) → audioPath (else generationNotReady/generationAudioMissing)
    copyGeneratedAudioToStableLocation(…, jobID: "fix-<jobId>")   // reused iii-a helper, promoted internal
    resolve target + rebase/stale check (D6)
    performEdit("AI Fix Take") { group-create-or-append + comp splice + rebuildCompMembers + tracksDidChange }
    pendingClipFixes[jobId] = nil
  → {trackId, groupId, laneId, laneName: "AI Fix 1", group: <TakeGroup JSON>}

edit.undo   → original plain clip back (or previous comp/lanes), ONE step.
```

---

## 3. New types and signatures (exact)

### `Sources/DAWCore/ClipFix.swift` (NEW — pure, headless)

```swift
/// Regeneration intensity for a clip-region AI fix. DAWCore-side mirror of the
/// provider's repaint mode (raw values are the wire contract; the DAWControl
/// adapter maps 1:1 onto AIServices.RepaintMode).
public enum ClipFixMode: String, Codable, Sendable, CaseIterable {
    case conservative, balanced, aggressive
}

/// What the store hands the generation seam to submit (provider-agnostic).
public struct ClipRepaintRequest: Sendable, Equatable {
    public var sourceAudioPath: String
    public var startSeconds: Double        // repaint window WITHIN the bounced file
    public var endSeconds: Double
    public var prompt: String?
    public var lyrics: String?
    public var mode: ClipFixMode
    public var strength: Double?           // 0…1, balanced-mode only (upstream rule)
    public var seed: Int?
    public var model: String?
    public init(...)                       // memberwise, defaults nil/.balanced
}

/// Seam receipt (jobID + queue position — the SongGenerationSubmission subset DAWCore needs).
public struct ClipFixJobReceipt: Sendable, Equatable {
    public var jobID: String
    public var queuePosition: Int?
    public init(jobID: String, queuePosition: Int? = nil)
}

/// Response of ProjectStore.fixClipRegion — the placement echo agents/tests assert.
public struct ClipFixSubmission: Codable, Sendable, Equatable {
    public var jobID: String               // CodingKeys: jobId
    public var state: String               // "queued"
    public var queuePosition: Int?
    public var windowStartBeat: Double
    public var windowEndBeat: Double
    public var regionStartBeat: Double
    public var regionEndBeat: Double
    public var repaintStartSeconds: Double
    public var repaintEndSeconds: Double
    public var bouncePath: String
}

public struct ClipGeometryFingerprint: Sendable, Equatable {
    public var startBeat, lengthBeats, startOffsetSeconds, stretchRatio,
               pitchShiftSemitones, gainDb: Double
    public init(of clip: Clip)
    /// nil when only startBeat differs (returns the delta); throws-style enum otherwise.
    public func moveDelta(to current: ClipGeometryFingerprint) -> Double?  // nil = incompatible drift
}

public enum PendingFixTarget: Sendable, Equatable {
    case clip(id: UUID, fingerprint: ClipGeometryFingerprint)
    case group(id: UUID, frozenRangeStart: Double, frozenRangeEnd: Double)
}

/// One in-flight fix job (in-memory only; NOT persisted — documented v0 cut).
public struct PendingClipFix: Sendable, Equatable, Identifiable {
    public var id: String { jobID }
    public var jobID: String
    public var trackID: UUID
    public var target: PendingFixTarget
    public var windowStartBeat: Double
    public var windowLengthBeats: Double
    public var regionStartBeat: Double
    public var regionEndBeat: Double
    public var tempoBPM: Double
    public var submittedAt: Date
}

public struct ClipFixImportResult: Sendable, Equatable {
    public var trackID: UUID
    public var groupID: UUID
    public var laneID: UUID
    public var laneName: String
}

/// Pure planner: window math + comp splice. Deterministic, no store access.
public enum ClipFixPlanner {
    /// Clamped context window (D3 formulas).
    public static func window(regionStart: Double, regionEnd: Double,
                              spanStart: Double, spanEnd: Double,
                              contextBeats: Double) -> (start: Double, end: Double)

    /// Replaces [regionStart, regionEnd) with a segment on `laneID`.
    /// Existing segments are trimmed at the region edges; a segment spanning the
    /// whole region splits in two; segments fully inside are dropped; empties
    /// (< 1e-9 beats) are dropped. Output sorted, non-overlapping. Gaps legal.
    public static func splice(_ comp: [CompSegment],
                              regionStart: Double, regionEnd: Double,
                              laneID: UUID) -> [CompSegment]
}
```

### `Sources/DAWCore/GenerationImport.swift` (extend)

```swift
public protocol GenerationImporting: Sendable {
    func fetchGeneration(jobID: String) async throws -> GeneratedSongResult
    func fetchGenerationStems(jobID: String) async throws -> GeneratedStemsResult
    /// M6 v-b: submit a repaint of a window WITHIN a bounced file. Additive.
    func submitRepaint(_ request: ClipRepaintRequest) async throws -> ClipFixJobReceipt
}
public extension GenerationImporting {
    /// Default: conformers without repaint submission (older fakes) refuse
    /// readably — the SongGenerating.repaintAudio bridge-default precedent.
    func submitRepaint(_ request: ClipRepaintRequest) async throws -> ClipFixJobReceipt {
        throw ProjectError.generationSourceUnavailable
    }
}
```

### `Sources/DAWCore/ProjectStore.swift` (small additions)

```swift
/// In-flight AI clip fixes, jobId-keyed (M6 v-b). In-memory only: cleared by
/// project.open/new, not persisted (a pending fix does not survive relaunch —
/// re-run ai.fixClipRegion). Observable so the future UI can badge it.
public private(set) var pendingClipFixes: [String: PendingClipFix] = [:]
```
plus internal setters used by the extension file (or make the extension mutate directly — same file module, `internal(set)` is enough: use `public internal(set)`). Clear it inside `newProject`/`openProject` alongside the other transient resets. In `Sources/DAWCore/ProjectStore+Generation.swift`, promote `copyGeneratedAudioToStableLocation` from `private` to `internal` (one keyword; add a comment that v-b reuses it with a `"fix-<jobId>"` key).

### `Sources/DAWCore/ProjectStore+ClipFix.swift` (NEW — @MainActor extension)

```swift
@discardableResult
public func fixClipRegion(trackId: UUID, clipId: UUID,
                          startBeat: Double, endBeat: Double,
                          prompt: String? = nil, lyrics: String? = nil,
                          mode: ClipFixMode = .balanced, strength: Double? = nil,
                          seed: Int? = nil, contextSeconds: Double = 10.0,
                          model: String? = nil) async throws -> ClipFixSubmission

@discardableResult
public func importClipFix(jobID: String) async throws -> ClipFixImportResult
```

`fixClipRegion` step order (all on @MainActor; the render stalls it — the accepted `renderBounce` v0 precedent):
1. `guard generationSource / engine` (fail early, before an expensive bounce).
2. Locate track+clip (`trackNotFound`/`clipNotFound`). Reject MIDI → new `ProjectError.clipFixRequiresAudioClip(UUID)`. Reject bus/instrument targets implicitly (audio clips only live on audio tracks).
3. Validate region: `endBeat > startBeat`, inside the clip span, `(endBeat−startBeat)*60/tempo ≥ 0.1` — violations throw `invalidClipEdit` with messages built at throw time (existing precedent).
4. Clamp `contextSeconds` to `1…60`.
5. Resolve span + source clips (D1): plain → the clip, fades zeroed on a copy; member → that group's members, group range as span. Compute window/seconds (D3, `ClipFixPlanner.window`).
6. `renderOffline` (synthetic dry track) → `writeAudioFile` to the temp bounce path.
7. `generationSource.submitRepaint(...)` (errors surface verbatim — sidecar-unreachable actionable messages already exist in the client).
8. Register `PendingClipFix` (target flavor per D6), return the echo.

`importClipFix` step order:
1. `pendingClipFixes[jobID]` else `clipFixJobNotFound(jobID)`.
2. `fetchGeneration(jobID)` → require `audioPath` (`generationNotReady`), file exists (`generationAudioMissing`) — identical to `importGeneration` steps 1–2.
3. `copyGeneratedAudioToStableLocation(from:…, jobID: "fix-<safe jobID>")`.
4. Resolve + revalidate target (D6) → `delta` or `clipFixStale(String)`.
5. Build the fix lane clip (D3 field list, beats shifted by `delta`), name `"AI Fix N"`.
6. `performEdit("AI Fix Take") { … }` per D4 (mirror `autoGroupRecordedTake`'s inline no-nested-performEdit discipline; call `rebuildCompMembers`; `engine?.tracksDidChange` happens inside `rebuildCompMembers` already).
7. Drop the pending record; return `ClipFixImportResult`.

### `Sources/DAWCore/MediaImporting.swift` (ProjectError additions)

```swift
case clipFixRequiresAudioClip(UUID)
case clipFixJobNotFound(String)
case clipFixStale(String)          // message built at throw time (what changed)
```
Messages (exact wording is contract, MCP/control surface verbatim):
- `clipFixRequiresAudioClip`: `"clip <id> is a MIDI clip — ai.fixClipRegion applies only to audio clips"`
- `clipFixJobNotFound`: `"no pending clip fix with jobId '<id>' — pending fixes do not survive app restart or project switches; submit again with ai.fixClipRegion"`
- `clipFixStale`: verbatim passthrough.

### `Sources/DAWControl/GenerationImportSource.swift` (extend the adapter)

```swift
func submitRepaint(_ request: ClipRepaintRequest) async throws -> ClipFixJobReceipt {
    var repaint = RepaintRequest(srcAudioPath: request.sourceAudioPath,
                                 startSeconds: request.startSeconds)
    repaint.endSeconds = request.endSeconds
    repaint.prompt = request.prompt
    repaint.lyrics = request.lyrics
    repaint.mode = RepaintMode(rawValue: request.mode.rawValue) ?? .balanced
    repaint.strength = request.strength
    repaint.seed = request.seed
    repaint.model = request.model
    // wavCrossfadeSec / latentCrossfadeFrames deliberately left nil: upstream
    // latent-crossfade default (≈0.4 s) is the boundary-quality mechanism;
    // the comp splice + 10 ms take crossfade own the timeline-side joins.
    let submission = try await generator.repaintAudio(repaint)
    return ClipFixJobReceipt(jobID: submission.jobID, queuePosition: submission.queuePosition)
}
```

---

## 4. Control commands (`Sources/DAWControl/Commands.swift`)

Register `"ai.fixClipRegion"` and `"ai.importClipFix"` in `knownCommands` (after `"ai.repaintAudio"`).

**`ai.fixClipRegion`** — params: `trackId` (required), `clipId` (required), `startBeat`/`endBeat` (required numbers, absolute timeline beats, `endBeat > startBeat` — field-named validation), `prompt?`, `lyrics?`, `mode?` (`"conservative"|"balanced"|"aggressive"`, default balanced; new `parseClipFixMode` helper mapping to `ClipFixMode` — do NOT reuse `parseRepaintMode`, which produces the AIServices type), `strength?` (0…1 field-named), `seed?` (integer), `contextSeconds?` (number, 1…60 field-named, default 10), `model?`. Handler: parse → `store.fixClipRegion(...)` inside the `translateSongGeneratorError` do/catch (sidecar-unreachable actionable messages, the `ai.generateSong` pattern). Response: `ClipFixSubmission` via `JSONValue(encoding:)`. Doc comment must state: submit-only, poll `ai.generationStatus`, then `ai.importClipFix`; retake = re-run without `seed`; a pending fix does not survive restart.

**`ai.importClipFix`** — params: `jobId` (required string). Handler: `store.importClipFix(jobID:)` in the same do/catch. Response:
```json
{ "trackId": "...", "groupId": "...", "laneId": "...", "laneName": "AI Fix 1",
  "group": { ...TakeGroup Codable... } }
```
(the `take.group` response precedent — return the group so agents see lanes+comp without a snapshot round-trip; fetch it from the store after import via track/group lookup).

## 5. MCP tools (`mcp-server/src/index.ts`)

Two tools, 86 → **88**: `ai_fix_clip_region`, `ai_import_clip_fix` — thin bridges over the two commands (the `ai_repaint_audio` pattern). Descriptions must teach: the three-step flow (fix → poll `ai_generation_status` → import); region in absolute timeline beats; the result is a violet take LANE comped in over exactly the region (comp elsewhere untouched, original audio never replaced); retake = submit again without `seed`; comp between takes with the existing `take_*` tools; pending fixes die with the app process.

## 6. File-by-file implementation checklist

| # | File | Change |
|---|---|---|
| 1 | `Sources/DAWCore/ClipFix.swift` | NEW: types + `ClipFixPlanner` (§3) |
| 2 | `Sources/DAWCore/GenerationImport.swift` | `submitRepaint` requirement + throwing default |
| 3 | `Sources/DAWCore/MediaImporting.swift` | 3 new `ProjectError` cases + messages |
| 4 | `Sources/DAWCore/ProjectStore.swift` | `pendingClipFixes` property; clear it in `newProject`/`openProject` |
| 5 | `Sources/DAWCore/ProjectStore+Generation.swift` | `copyGeneratedAudioToStableLocation` private → internal |
| 6 | `Sources/DAWCore/ProjectStore+ClipFix.swift` | NEW: `fixClipRegion` + `importClipFix` (§3) |
| 7 | `Sources/DAWControl/GenerationImportSource.swift` | `submitRepaint` adapter (§3) |
| 8 | `Sources/DAWControl/Commands.swift` | 2 commands + `parseClipFixMode` + knownCommands |
| 9 | `mcp-server/src/index.ts` | 2 tools (86→88); `npm run build` clean |
| 10 | `Tests/DAWCoreTests/ClipFixTests.swift` | NEW (§7) |
| 11 | `Tests/DAWControlTests/ClipFixCommandTests.swift` | NEW (§7) |
| 12 | `docs/ARCHITECTURE.md` | Command-docs paragraph for the pair (the `ai.repaintAudio` entry's sibling) + append to "Key future decisions": **Clip vocal-fix flow: SETTLED (M6 v-b)** — dry as-heard windowed bounce (region ± 10 s clamped, plain-clip fades stripped to match post-grouping lane playback), absolute-beat wire addressing, take lands `ratio 1.0/offset 0` at the window position, comp SPLICE of the fix region only (VAE-recon outside-window audio never plays), explicit submit/poll/import with in-memory pending registry + move-rebase/stale revalidation |
| 13 | `docs/ROADMAP.md` | check v-b on completion (with test counts), note v-b-2 UI slice if split |

Baseline to preserve: 1118 tests / 137 suites, 0 warnings (`./scripts/test.sh`, never bare `swift test`).

## 7. Test strategy

### `Tests/DAWCoreTests/ClipFixTests.swift` (headless, fake-driven)

Fakes: extend the local pattern from `GenerationImportTests.swift` — `FakeGenerationSource` gains `submitRepaint` (records the `ClipRepaintRequest`, returns scripted receipt) alongside its scripted `fetchGeneration`; a `FakeRenderEngine` (DAWCore-side; model on `RenderPolicyTests`'s fake) records `renderOffline` invocations (tracks/fromBeat/duration/masterVolume) and returns a small silent `RenderedAudio`; `writeAudioFile` writes a stub file; `FakeMedia` returns a scripted duration for the fetched WAV.

Planner (pure, no store):
1. `window`: interior region (both pads applied), region at clip start (left clamp), at clip end (right clamp), region == span (window == span), context larger than clip.
2. `splice`: into single full-range segment (→ 3 segments), at segment start/end edges (→ 2), covering whole comp (→ 1), across two abutting segments, into empty comp, region beyond comp segments (gap + new segment), float-edge empties dropped.

Submit:
3. Happy path plain clip: bounce called with ONE synthetic track — volume 1/pan 0/no effects/sends/automation, only the target clip, **fades zeroed**, gain/stretch preserved; `fromBeat == windowStart`, exact duration (no +2 s tail); `ClipRepaintRequest` seconds match D3 math; pending registered with `.clip` target; echo fields exact.
4. Stretched clip: bounce duration uses timeline seconds (ratio-independent); request seconds unchanged by ratio.
5. Member target: synthetic track holds ALL of that group's member clips (and nothing else); span clamps to group range; pending target `.group` with frozen range.
6. Rejections: MIDI clip (`clipFixRequiresAudioClip`), region outside span / end ≤ start / < 0.1 s (`invalidClipEdit`), unknown track/clip, engine nil (`engineUnavailable`), generationSource nil (`generationSourceUnavailable`) — and no bounce happened for the early guards (fake records zero renders).

Import:
7. Happy path plain clip: group created; lane 0 == original (id + geometry preserved, no nested `takeGroupID`); lane 1 `"AI Fix 1"`, violet, `ratio 1/offset 0/gain 0`, `startBeat == windowStart`, `lengthBeats == window`; comp == `[orig | fix(region) | orig]`; members rebuilt (3 members, fix member violet); **one** `edit.undo` restores the plain clip and removes the group; redo restores everything.
8. Import onto member/group target: lane appended, other comp segments untouched outside the region, existing lanes intact.
9. Two pending fixes on the same plain clip: import both → ONE group, lanes `"AI Fix 1"`+`"AI Fix 2"`, second splice wins inside its region.
10. Comp edited between submit and import (group target): import still lands (fresh member UUIDs are irrelevant — group anchor).
11. Move rebase: `clip.move`/`take.move` by +4 beats mid-job → take lands shifted by +4, comp splice shifted; stale: trim/re-stretch/re-gain/tempo change/deleted target → `clipFixStale`; region outside shrunk group range → stale.
12. Job-state errors: unknown jobId (`clipFixJobNotFound`), still-running (`generationNotReady` verbatim), missing file (`generationAudioMissing`); pending record SURVIVES a failed import (retryable) and is consumed on success; `project.new` clears the registry.

### `Tests/DAWControlTests/ClipFixCommandTests.swift`

13. Routing + happy path over a real `ProjectStore` with the fakes: response shapes for both commands (echo fields; import returns group JSON with 2 lanes).
14. Field-named validation: missing/NaN `startBeat`/`endBeat`, bad `mode` string (names valid values), `strength` out of 0…1, `contextSeconds` out of 1…60, missing `jobId`.
15. Adapter: `SongGenerationImportSource.submitRepaint` maps every field onto `RepaintRequest` (mode raw-value mapping, end/strength/seed passthrough, crossfade fields left nil) — assert via a recording `FakeSongGenerator` (the `RepaintCommandTests` fake).
16. Error translation: fake generator throwing sidecar-unreachable surfaces the actionable message (the `translateSongGeneratorError` path); store errors surface verbatim (LocalizedError mapping).

### MCP
17. `npm run build` clean; `tools/list` stdio smoke shows 88 including both new tools (the iii-c/v-a verification pattern).

### Deferred to v-c (real gate — explicitly NOT this cycle)
Real sidecar run on the archived gate vocals stem: verify boundary continuity at the repaint seams by cross-correlating the bounce vs the returned file *outside* the window (expect peak at lag 0 — confirms upstream preserves timing through the VAE), audition artifacts archived. Any full-app E2E with the stub sidecar follows the v-a stub-E2E pattern.

## 8. Edge cases (settled behaviors)

| Case | Behavior |
|---|---|
| Clip deleted mid-job | `importClipFix` → `clipFixStale` (actionable); pending record kept for inspection until project switch |
| Project closed/reopened mid-job | registry cleared → `clipFixJobNotFound` with re-run instruction (v0; persisting pending fixes into `.dawproj` is a flagged future decision) |
| Region outside clip bounds / zero-length / < 0.1 s | rejected at submit, field-named / `invalidClipEdit` |
| MIDI clip | rejected at submit, `clipFixRequiresAudioClip` |
| Overlapping second fix while one pending | allowed; both import into the same group as separate lanes (D6 lane-payload resolution) |
| Tempo change mid-job | `clipFixStale` (bounced material's beats↔seconds mapping broken; no safe rebase) |
| Clip/group moved mid-job | rebase by the uniform delta; imports correctly |
| Comp edited mid-job (group target) | fine — splice applies to the current comp |
| Job failed upstream | `ai.generationStatus`/import surface the client's own jobFailed error verbatim; pending record kept (retake = new submit) |
| Returned file length ≠ requested window (latent rounding) | take length pinned to requested window; interior comp region unaffected |
| Undo after import | one step: plain clip restored / previous comp+lanes restored; WAV stays on disk; redo works |

## 9. Invariant compliance

- **Render thread**: untouched. Bounce is `renderOffline` (fresh offline renderer per pass, existing seam); submit/import are main-actor + async network in the client. No new engine API.
- **One command surface**: both operations are `ProjectStore` methods; UI (v-b-2) and control protocol call the same methods; every capability ships command + MCP tool + tests.
- **DAWCore purity**: no AIServices/network/AVFoundation import — the AI hop rides the existing `GenerationImporting` seam (additive method, throwing default); the audio hop rides `AudioEngineControlling`. All new DAWCore types are `Sendable` values; store mutation stays `@MainActor`; one `performEdit` = one undo step.
- **Swift 6 strict concurrency**: no new callbacks; async store methods on `@MainActor` (the `importGeneration` shape); watch the known `@Sendable` callback pitfall only if v-b-2 adds poll timers (not this cycle).
- **Stub-first**: every test runs against fakes; the real sidecar is v-c.
