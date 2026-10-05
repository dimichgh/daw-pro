import Foundation

/// Where a chop's boundaries come from (m32-b2). ⭐ A `mode` that selects a
/// boundary SOURCE is a parameter; a `destination` that selects an output
/// DOMAIN would be a different verb — which is exactly why chop-to-timeline
/// stayed on `clip.quantizeAudio` and did not become a flag here.
public enum SliceBoundaryMode: String, Codable, Sendable, CaseIterable {
    /// Detected onsets from the engine's spectral-flux analyzer.
    case transients
    /// N equal parts of the clip's source window (source-seconds domain).
    case divisions
    /// Musical grid lines through the tempo map (the ONLY mode that consults
    /// the tempo map, and therefore the only one that rejects a clip spanning
    /// a tempo change).
    case grid
}

/// Knobs for `clip.sliceToSampler` (m32-b2). Clamped on init like every other
/// settings struct here, so a plan built from these is always renderable.
public struct SliceToSamplerSettings: Sendable, Equatable {
    public var mode: SliceBoundaryMode
    /// Detector knob, 0...1 (higher finds more onsets). `transients` only.
    public var sensitivity: Double
    /// Equal parts of the window, 2...128. `divisions` only.
    public var divisions: Int?
    /// Grid resolution in beats, > 0. `grid` only.
    public var gridBeats: Double?
    /// Boundaries closer than this merge, and no slice is narrower.
    public var minSliceSeconds: Double
    /// Hard refusal ceiling on the number of pads produced.
    public var maxSlices: Int
    /// Keep the material BEFORE the first boundary as pad 1.
    ///
    /// ⚠️ **Only `.transients` reads it** (see `effectiveIncludeHead`). In
    /// `.divisions` and `.grid` pad 1 ALWAYS starts at the window, and this
    /// flag changes nothing.
    public var includeHead: Bool
    /// MIDI note of pad 1; pad i sits at `baseNote + i`.
    public var baseNote: Int
    /// Half-width of the boundary snap search, in seconds. 0 disables it.
    public var snapWindowSeconds: Double
    /// Emit the reconstruction MIDI clip that replays the original groove.
    public var generateMIDI: Bool
    /// Where the reconstruction clip lands; nil = the source clip's own start.
    public var atBeat: Double?
    /// ⭐⭐ Default FALSE, and the reason is arithmetic, not taste — see
    /// `SliceToSamplerPlan`'s velocity note.
    public var velocityFromStrength: Bool

    public static let defaultMinSliceSeconds: Double = 0.05
    public static let defaultMaxSlices = 32
    /// Refusal ceiling on `maxSlices` itself. 96 pads is already four banks of
    /// an MPC; beyond that the workflow wants a second chop, not a longer one.
    public static let maxSlicesHardCap = 96
    public static let defaultBaseNote = 36            // C1, the MPC pad-1 note
    public static let defaultSnapWindowSeconds: Double = 0.003
    public static let snapWindowRange: ClosedRange<Double> = 0...0.020
    public static let divisionsRange: ClosedRange<Int> = 2...128
    /// The zone envelope every generated pad gets. `attack` 0 preserves the
    /// transient (and stops a nonzero GLOBAL attack from softening every
    /// chop); `release` is ⭐ the real end-of-slice click fix — a pad played
    /// in isolation stops dead at its `endFrame`, and only an envelope fixes
    /// that. 10 ms is `AudioQuantizeSettings.defaultCrossfadeSeconds`: the
    /// tree's existing number for a slice join, not a new one.
    public static let generatedZoneAttackSeconds: Double = 0.0
    public static let generatedZoneReleaseSeconds: Double =
        AudioQuantizeSettings.defaultCrossfadeSeconds

    public init(mode: SliceBoundaryMode = .transients,
                sensitivity: Double = 0.5,
                divisions: Int? = nil,
                gridBeats: Double? = nil,
                minSliceSeconds: Double = SliceToSamplerSettings.defaultMinSliceSeconds,
                maxSlices: Int = SliceToSamplerSettings.defaultMaxSlices,
                includeHead: Bool = false,
                baseNote: Int = SliceToSamplerSettings.defaultBaseNote,
                snapWindowSeconds: Double = SliceToSamplerSettings.defaultSnapWindowSeconds,
                generateMIDI: Bool = true,
                atBeat: Double? = nil,
                velocityFromStrength: Bool = false) {
        self.mode = mode
        self.sensitivity = sensitivity.clamped(to: 0...1)
        self.divisions = divisions.map { $0.clamped(to: Self.divisionsRange) }
        self.gridBeats = gridBeats.map { max(0, $0) }
        self.minSliceSeconds = max(0.001, minSliceSeconds)
        self.maxSlices = maxSlices.clamped(to: 1...Self.maxSlicesHardCap)
        self.includeHead = includeHead
        self.baseNote = baseNote.clamped(to: SamplerZone.pitchRange)
        self.snapWindowSeconds = snapWindowSeconds.clamped(to: Self.snapWindowRange)
        self.generateMIDI = generateMIDI
        self.atBeat = atBeat
        self.velocityFromStrength = velocityFromStrength
    }

    /// ⭐ The snap window ACTUALLY used: never more than half the minimum
    /// slice, so two adjacent boundaries can never cross while snapping.
    /// (At the defaults — 3 ms against 25 ms — this never bites; it exists
    /// for the caller who passes `minSliceSeconds: 0.004`.)
    public var effectiveSnapWindowSeconds: Double {
        min(snapWindowSeconds, minSliceSeconds / 2)
    }

    /// ⭐ Whether pad 1 ACTUALLY starts at the window edge (m33-d) — the ONE
    /// rule `validateSliceCount`, the pad starts and the head warning all read.
    ///
    /// Only a DETECTOR leaves material before its first boundary that may be
    /// pre-roll, and deciding that is all `includeHead` is for. In `.divisions`
    /// and `.grid` the window's start IS the first cut, by construction: the
    /// boundary helpers return only the INTERIOR cuts (their contract — they are
    /// shared with `clip.quantizeAudio`, which emits a head and a tail itself),
    /// so the first piece reaches the planner looking exactly like a head.
    ///
    /// ⛔ MEASURED 2026-09-24: honouring `includeHead: false` there turned "8
    /// equal pieces" of a 1.93 s loop into 7 pads, dropped the first eighth of
    /// the audio from every pad, and warned about a detector that never ran.
    ///
    /// `includeHead: true` in those modes still means N pads — the head is
    /// counted once, never twice — so a caller that learned that workaround
    /// keeps its exact result.
    public var effectiveIncludeHead: Bool {
        includeHead || !includeHeadIsEffective
    }

    /// Does `includeHead` reach the chop at all? Only where a detector picks
    /// the first boundary. ⭐ THE ONE HOME for that mode rule: the chop card
    /// dims its "Keep the lead-in" toggle on exactly this (DESIGN-LANGUAGE:
    /// "a setting that cannot reach the sound stays live, goes dim, and says
    /// so") and `effectiveIncludeHead` derives from it, so the card and the
    /// planner cannot come to disagree about which modes read the flag.
    public var includeHeadIsEffective: Bool {
        mode == .transients
    }
}

/// One emitted pad, as the wire reports it (m32-b2 §6.11). The `Codable`
/// conformance IS the response shape — the wire-never-drifts rule.
public struct SliceReport: Codable, Sendable, Equatable {
    /// 0-based pad index.
    public var index: Int
    /// The MIDI note that fires this pad (`baseNote + index`).
    public var pitch: Int
    /// Source-file frame the pad starts at, at the FILE's sample rate.
    public var startFrame: Int
    /// Source-file frame the pad stops at; nil = the file's end (the last pad
    /// of a chop that reaches the end of the file).
    public var endFrame: Int?
    /// `startFrame / sampleRate` — the POST-SNAP source position, so the
    /// seconds, the frames, the audio and the reconstruction MIDI all agree
    /// by construction. Subtract `snapOffsetFrames` to recover the candidate.
    public var sourceSeconds: Double
    /// Timeline beat the reconstruction note fires at (absolute).
    public var beat: Double
    /// Detector strength 0...1; absent in `divisions`/`grid` mode and on the
    /// head pad, which no detector produced.
    public var strength: Double?
    /// Frames the boundary moved during the snap; absent on the head pad,
    /// whose start is the clip's window edge and was never snapped.
    public var snapOffsetFrames: Int?
    /// `max_c |x_c[k]|` at the chosen frame — how quiet the cut actually is.
    /// Absent on the head pad, for the same reason.
    public var residualAmplitude: Double?

    public init(index: Int, pitch: Int, startFrame: Int, endFrame: Int?,
                sourceSeconds: Double, beat: Double, strength: Double?,
                snapOffsetFrames: Int?, residualAmplitude: Double?) {
        self.index = index
        self.pitch = pitch
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.sourceSeconds = sourceSeconds
        self.beat = beat
        self.strength = strength
        self.snapOffsetFrames = snapOffsetFrames
        self.residualAmplitude = residualAmplitude
    }
}

/// Pure, headless chop-to-sampler planner (m32-b2). Given an audio clip's
/// geometry, the file geometry the ENGINE resolved, the detector strengths,
/// and the settings, it returns the zones, the reconstruction MIDI, and the
/// per-pad report. Mirrors `AudioQuantizePlan`: **no file I/O, no engine, no
/// UI** — every frame number it emits came in through `SliceBoundaryGeometry`,
/// carrying the rate those frames are in.
///
/// ## ⭐⭐ Why reconstruction velocity is 127 and not the detector's strength
///
/// `SamplerInstrument` computes `amp = velocityAmp × gain` where, at the
/// default `ampVelTrack` of nil (= 1), `velocityAmp = velocity / 127`. **The
/// slice already contains its own recorded amplitude.** A ghost note detected
/// at `strength: 0.1` and fired at velocity 13 would land ~20 dB BELOW its own
/// recorded level — double attenuation — and the reconstruction would not
/// sound like the record. That destroys the single most valuable property of
/// the MPC pattern: you start from "plays back identically to the source" and
/// edit from there.
///
/// 127/127 is exactly 1.0, so each pad plays at precisely its recorded level —
/// a bit-faithful reconstruction — while the zone's velocity law stays LIVE,
/// so an agent writing a NEW pattern at velocity 64 still gets half amplitude.
/// `velocityFromStrength: true` restores the detector's dynamics for callers
/// who want them; `strength` is in the report either way, so nothing is lost.
///
/// (Rejected alternative: `ampVelTrack: 0` on every generated zone plus
/// velocity 100. Also exact, but it makes velocity INERT on a sampler
/// instrument, which would be a baffling default.)
public enum SliceToSamplerPlan {

    /// Everything one chop produces, ready for a single `performEdit`.
    public struct Result: Sendable, Equatable {
        public var zones: [SamplerZone]
        /// Reconstruction notes, CLIP-RELATIVE to `midiClipStartBeat`. Empty
        /// when `generateMIDI` is false.
        public var notes: [MIDINote]
        public var slices: [SliceReport]
        public var midiClipStartBeat: Double
        public var midiClipLengthBeats: Double
        /// Material before the first boundary, in seconds. ALWAYS reported —
        /// `includeHead` defaults false because that material is usually
        /// pre-roll, but a detector that misses the first hit would otherwise
        /// silently eat a downbeat. In `.divisions`/`.grid` the head is always
        /// pad 1 (`effectiveIncludeHead`), so there this is pad 1's own length.
        public var headSeconds: Double
        public var warnings: [String]
    }

    /// The count rules, split out so the orchestrator can refuse BEFORE it
    /// pays for the PCM pass — and so `compute` stays self-contained for the
    /// pure tests. `boundaryCount` is the conditioned boundary count.
    ///
    /// ⭐ Both ceilings REJECT and never truncate. Keeping the strongest N
    /// would silently drop the tail of the groove and hand back a
    /// plausible-looking valid answer, which is the failure mode this whole
    /// design is arranged against.
    public static func validateSliceCount(boundaryCount: Int,
                                          settings: SliceToSamplerSettings,
                                          clipId: UUID) throws {
        // `effectiveIncludeHead`, not `includeHead`: the ceilings must count the
        // pads `compute` will REALLY make, or "8 equal pieces" under a ceiling
        // of 7 would pass here and land 8 pads.
        let slices = boundaryCount + (settings.effectiveIncludeHead ? 1 : 0)
        guard slices >= 1 else {
            throw ProjectError.audioQuantizeNoTransients(clipId)
        }
        guard slices <= settings.maxSlices else {
            throw ProjectError.invalidClipEdit(
                "chopping clip \(clipId.uuidString) would make \(slices) pads, over the "
                + "maxSlices limit of \(settings.maxSlices) — nothing was changed. Raise "
                + "maxSlices (hard cap \(SliceToSamplerSettings.maxSlicesHardCap)), lower "
                + "sensitivity, raise minSliceSeconds, or trim the clip to a shorter passage. "
                + "Slices are never silently dropped, because a chop missing its last bar "
                + "still looks like a successful chop")
        }
        let highest = settings.baseNote + slices - 1
        guard highest <= SamplerZone.pitchRange.upperBound else {
            throw ProjectError.invalidClipEdit(
                "chopping clip \(clipId.uuidString) would make \(slices) pads starting at note "
                + "\(settings.baseNote), which needs note \(highest) — MIDI stops at 127. "
                + "Lower baseNote (36 = C1 is the default) or make fewer slices")
        }
    }

    /// Builds the zones, the reconstruction MIDI and the per-pad report.
    ///
    /// `strengths` is index-aligned with `geometry.boundaryFrames` (empty in
    /// the non-detector modes). `tempoMap` maps post-snap source seconds to
    /// timeline beats through `tempoMap.beat(from:elapsedSeconds:)` — the SAME
    /// projection `detectClipTransients` uses, so the two sites cannot drift,
    /// and it integrates the map correctly in all three modes.
    public static func compute(clip: Clip,
                               geometry: SliceBoundaryGeometry,
                               strengths: [Double],
                               settings: SliceToSamplerSettings,
                               tempoMap: TempoMap) throws -> Result {
        guard let audioFileURL = clip.audioFileURL else {
            throw ProjectError.invalidClipEdit(
                "clip \(clip.id.uuidString) has no audio file to chop")
        }
        // The seam guarantees a real rate; refuse rather than divide by a
        // fabricated one if some future fake ever hands over a zero.
        guard geometry.sampleRate > 0, geometry.frameCount > 0 else {
            throw ProjectError.invalidClipEdit(
                "the engine reported no usable audio geometry for clip "
                + "\(clip.id.uuidString) (sampleRate \(geometry.sampleRate), "
                + "frameCount \(geometry.frameCount))")
        }
        try validateSliceCount(boundaryCount: geometry.boundaryFrames.count,
                               settings: settings, clipId: clip.id)

        let rate = geometry.sampleRate
        let windowStart = clip.startOffsetSeconds
        let windowEnd = windowStart + clip.sourceWindowSeconds(tempoMap: tempoMap)
        let lastFrame = geometry.frameCount - 1
        let windowStartFrame = min(max(Int((windowStart * rate).rounded()), 0), lastFrame)
        let windowEndFrame = min(max(Int((windowEnd * rate).rounded()), 0), geometry.frameCount)

        // Pad starts: the head (window edge) when it is kept — asked for in
        // `.transients`, ALWAYS in `.divisions`/`.grid` (see
        // `effectiveIncludeHead`) — then every snapped boundary. `headOffset`
        // is how far the boundary arrays are shifted relative to the pad arrays.
        let keepsHead = settings.effectiveIncludeHead
        let headOffset = keepsHead ? 1 : 0
        var starts: [Int] = []
        starts.reserveCapacity(geometry.boundaryFrames.count + headOffset)
        if keepsHead { starts.append(windowStartFrame) }
        starts.append(contentsOf: geometry.boundaryFrames)
        let count = starts.count

        var warnings: [String] = []

        var zones: [SamplerZone] = []
        var notes: [MIDINote] = []
        var slices: [SliceReport] = []
        zones.reserveCapacity(count)
        slices.reserveCapacity(count)

        let midiClipStart = settings.atBeat ?? clip.startBeat
        let windowEndBeat = tempoMap.beat(
            from: clip.startBeat,
            elapsedSeconds: (windowEnd - windowStart) * clip.stretchRatio)

        // Absolute timeline beat of each pad, from its POST-SNAP source
        // position — so audio, MIDI and the response agree by construction.
        func beat(ofFrame frame: Int) -> Double {
            tempoMap.beat(from: clip.startBeat,
                          elapsedSeconds: (Double(frame) / rate - windowStart) * clip.stretchRatio)
        }
        let beats = starts.map(beat(ofFrame:))

        for i in 0..<count {
            // ⭐ ONE boundary, snapped ONCE, shared by both adjacent spans:
            // pad i's end IS pad i+1's start. Snapping starts and ends
            // independently would open gaps and overlaps and silently destroy
            // the [boundaryᵢ, boundaryᵢ₊₁) invariant.
            let end: Int?
            if i < count - 1 {
                end = starts[i + 1]
            } else if windowEndFrame >= geometry.frameCount {
                // ⭐ nil resolves to the exact file end in SamplerInstrument,
                // so no `durationSeconds × sampleRate` round-trip can overshoot
                // by a frame and trigger a spurious "zone end clamped" note.
                end = nil
            } else {
                // A TRIMMED clip: the window stops before the file does, so
                // the last pad must stop there too. nil here would hand the
                // last pad the whole rest of the record — the design's
                // "the last runs to the clip's window end" rule, which the
                // nil shortcut only satisfies when the two coincide.
                end = windowEndFrame
            }
            let pitch = settings.baseNote + i
            let strengthIndex = i - headOffset
            let strength = (strengthIndex >= 0 && strengthIndex < strengths.count)
                ? strengths[strengthIndex] : nil

            zones.append(SamplerZone(
                audioFileURL: audioFileURL,
                rootPitch: pitch,
                // One pad, one slice. A slice is a fragment of a record;
                // letting it sound across a whole keyboard by default makes
                // overlapping garbage on a chord. Chromatic play is one
                // `sampler.zonePatches` call away (widen maxPitch) — the
                // "16 Levels" pattern.
                minPitch: pitch, maxPitch: pitch,
                gain: 1,
                startFrame: starts[i], endFrame: end,
                attack: SliceToSamplerSettings.generatedZoneAttackSeconds,
                release: SliceToSamplerSettings.generatedZoneReleaseSeconds))

            if settings.generateMIDI {
                let nextBeat = (i < count - 1) ? beats[i + 1] : windowEndBeat
                let velocity: Int
                if settings.velocityFromStrength, let strength {
                    velocity = Int((strength * 127).rounded()).clamped(to: MIDINote.velocityRange)
                } else {
                    velocity = MIDINote.velocityRange.upperBound
                }
                notes.append(MIDINote(
                    pitch: pitch, velocity: velocity,
                    // Clip-relative to the SOURCE clip's start, then the whole
                    // clip lands at `atBeat` — so moving the reconstruction
                    // moves the groove intact rather than re-timing it.
                    startBeat: beats[i] - clip.startBeat,
                    lengthBeats: max(MIDINote.minLengthBeats, nextBeat - beats[i])))
            }

            slices.append(SliceReport(
                index: i, pitch: pitch, startFrame: starts[i], endFrame: end,
                sourceSeconds: Double(starts[i]) / rate, beat: beats[i],
                strength: strength,
                snapOffsetFrames: strengthIndex >= 0
                    && strengthIndex < geometry.snapOffsetFrames.count
                    ? geometry.snapOffsetFrames[strengthIndex] : nil,
                residualAmplitude: strengthIndex >= 0
                    && strengthIndex < geometry.residualAmplitude.count
                    ? geometry.residualAmplitude[strengthIndex] : nil))
        }

        let firstBoundarySeconds = geometry.boundaryFrames.first.map { Double($0) / rate }
        let headSeconds = max(0, (firstBoundarySeconds ?? windowEnd) - windowStart)
        // ClampNotice doctrine: warn, never reject, and only when something
        // actually happened — noise is ignored, taking the warning that
        // mattered with it. `keepsHead`, so this can only fire where a
        // DETECTOR ran: the sentence blames one.
        if !keepsHead && headSeconds > 2 * settings.minSliceSeconds {
            warnings.append(headDiscardedWarning(headSeconds: headSeconds))
        }
        if settings.effectiveSnapWindowSeconds < settings.snapWindowSeconds {
            warnings.append(
                "snapWindowMs was reduced to "
                + "\(ClampNotice.number(settings.effectiveSnapWindowSeconds * 1000)) ms — it can "
                + "never exceed half of minSliceSeconds "
                + "(\(ClampNotice.number(settings.minSliceSeconds)) s), or two adjacent "
                + "boundaries could snap past each other and reorder the slices")
        }

        return Result(zones: zones, notes: notes, slices: slices,
                      midiClipStartBeat: midiClipStart,
                      midiClipLengthBeats: max(MIDINote.minLengthBeats, clip.lengthBeats),
                      headSeconds: headSeconds, warnings: warnings)
    }

    /// The WIRE's sentence for a dropped head — built in ONE place (m33-d).
    ///
    /// ⚠️ **PUBLIC SO THE PAD GRID CAN RECOGNISE IT, NOT SO ANYONE CAN REWORD
    /// IT.** It is wire contract, written for an agent, and it names the
    /// `includeHead` parameter precisely — which is exactly why a PERSON must
    /// not read it: the pad grid has no control by that name. The grid shows its
    /// own sentence instead (`PadGridModel.chopWarningsForHumans`) and knows it
    /// is looking at THIS warning by exact equality against the result's own
    /// `headSeconds`, so the two texts cannot drift apart without a test seeing.
    public static func headDiscardedWarning(headSeconds: Double) -> String {
        "\(ClampNotice.number(headSeconds)) s of audio before the first slice point was "
            + "discarded (pad 1 starts at the first onset, like an MPC or Recycle). "
            + "Pass includeHead: true to keep it as pad 1 — worth doing if the detector "
            + "missed the downbeat"
    }
}
