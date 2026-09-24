import Foundation

// m23-ap Phase 1 (2) — THE PITCH-CORRECTION DATA MODEL, THE ONE CURVE
// EVALUATOR, AND THE AUTO-CORRECT POLICY.
//
// Design record: `docs/research/m23-q-pitch-correction-design.md` §6.4 (curve
// rules), §7.1 (schema), §7.3 (persistence), §7.4 (undo keys), §7.8 (the
// one-home law). Measurements: `docs/research/m23-q-phase0-curve-experiment.md`.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⚠️⚠️ COORDINATE AXIS — SOURCE SECONDS, AND THE DESIGN SAYS THIS THREE WAYS
// ═══════════════════════════════════════════════════════════════════════════
//
// The design states the curve's domain three different ways: §6.4 writes
// `semitones(atOutputFrame:)`, §7.1 writes `semitones(atSourceSecond:)`, and
// the shipped E1 entry point takes an `outputFrame`. Those three COINCIDE at
// stretch ratio 1 and DIVERGE the moment Phase 3 introduces per-note timing.
//
// **RULED (m23-ap Phase 1): the model is authoritative in SOURCE-FILE SECONDS.**
// `PitchCorrectionCurve.semitones(atSourceSecond:)` is the ONLY evaluator.
//
// There is deliberately NO output-frame overload here, and adding one would be
// the divergence this file exists to prevent. Converting output frames → source
// seconds belongs to the RENDER path, because that is where the stretch
// schedule lives — and so does the measured 2379-frame (49.56 ms) curve
// pre-shift (`OfflineStretcher.measuredCurveLatencyFrames`, phase-0 §6). A
// model that knew about output frames would have to know about both, and then
// there would be two places that believe they own the mapping.
//
// Source seconds also buy geometry-independence: a segment's boundaries do not
// move when the clip is trimmed, split, moved, or the tempo changes — the same
// property `StretchRenderCache` engineered for, and the same domain
// `ClipPitchFrame.timeSeconds` and `clip.detectTransients` already use.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⚠️⚠️ WHAT THIS CHAIN CAN AND CANNOT PROMISE — MEASURED, NOT ASSERTED
// ═══════════════════════════════════════════════════════════════════════════
//
// Read this before writing a tolerance, a UI label, or a doc sentence that
// implies exactness. Each figure was measured in this tree; none of them is
// composed with another, because composing two independently-measured biases
// produces a number nobody has ever seen.
//
//  1. **DETECTOR QUANTISATION FLOOR: ±12.90 cents, before the model is even
//     consulted.** SwiftF0 reports pitch as an argmax over 256 log-spaced bins
//     covering 46.875–2093.75 Hz = 6577.4 cents ⇒ 25.79 cents/bin. Our decode
//     reads the exported graph's own `pitch` output in Hz — the argmax already
//     happened inside the graph — so there is no bin arithmetic on our side to
//     interpolate away. A tolerance tighter than ±12.90 cents is unreachable by
//     construction, not by quality.
//
//  2. **THE TRANSPOSER WE SHIP IS ITSELF SHARP: +5.45 cents at +2 st, +3.95 at
//     −2 st, −0.019 at 0** (phase-0 §7, measured on `OfflineStretcher` as
//     shipped). Correcting to ±5 cents through a transposer that is 5 cents off
//     is a closed loop that will not close.
//
//  3. **CONFIDENCE GATES VOICING. IT DOES NOT GATE ACCURACY.** A 440 Hz sine
//     reads 437.55 Hz — 9.7 cents FLAT — at confidence ≥ 0.985. Nothing in this
//     file may treat a high-confidence frame as an accurate one. The only thing
//     `detectedConfidence` is for is telling a human, and a future editor, how
//     much the detector committed to the frame being VOICED.
//
//  4. **A HOLE IS THE SIGNAL.** `ClipPitchFrame.frequencyHz` is `nil` on an
//     unvoiced frame, deliberately and with a `precondition` behind it. This
//     file never fills a hole, never interpolates across one, and never lets a
//     note segment span one. A gap in the contour ends a note; it does not get
//     a pitch invented for it.
//
//  5. **VIBRATO COMES BACK DEEPER THAN ASKED: 1.06× at 1 Hz, 1.15× at 5 Hz,
//     1.20× at 8 Hz** (phase-0 §8, the 30 ms automation grid emphasising the
//     staircase). That is comfortably good enough to CORRECT through and is
//     NOT good enough to SHAPE with. `NoteSegment.vibratoScale` therefore
//     exists as a field and is documented as a KEEP/FLATTEN lever — it is not a
//     calibrated depth control and must never be presented as one.
//
// So: this subsystem's honest claim is "pulls a note's centre onto the scale,
// to roughly the detector's own resolution". It is not "tunes to ±5 cents".
//
// ═══════════════════════════════════════════════════════════════════════════
// SCOPE OF THIS FILE (m23-ap Phase 1 sub-item 2)
// ═══════════════════════════════════════════════════════════════════════════
//
// The model, the single evaluator, and the auto-correct policy. Deliberately
// ABSENT, and none of these is an oversight:
//
// ⚠️ **THIS LIST WAS WRITTEN BEFORE 2026-09-22 AND MOST OF IT IS NOW WRONG.**
// Kept, corrected in place, because a list of absences is exactly the kind of
// prose that reads as current forever:
//
//  * ~~No render integration.~~ **LANDED.** `StretchRenderCache` keys on
//    `pitchEditSetHash` (both the in-memory `Params` and the on-disk SHA256,
//    which are separate and both had to change), `performRender` takes the
//    curve branch, and `OfflineStretcher.curveLatencyCompensation` removes the
//    2379-frame lookup latency. E2 ran on a real dry vocal: quarter-cent
//    agreement with the constant path. ⚠️ `Clip.isStretchIdentity` is STILL
//    unchanged — see the second-home warning on `Clip.pitchEdits`.
//  * ~~No edit-set hash for the render cache key.~~ **LANDED** as
//    `PitchEditSetDigest` — SHA256 over raw bit patterns, never `hashValue`
//    (per-process seeded, so an on-disk key built on it misses forever). The
//    field is appended only when non-empty, so every pre-m23-q key is
//    byte-identical and no existing cache entry was orphaned.
//  * ~~No wire verb, no MCP tool, no UI.~~ **WIRE + MCP LANDED**
//    (`clip.autoCorrectPitch` / `clip.clearPitchEdits` / `clip.getPitchEdits`).
//    **UI is still absent**: `PitchEditorModel` (DAWAppKit) is the headless
//    model only; no view exists yet.
//  * ~~No store operations.~~ **LANDED** in `ProjectStore+PitchCorrection.swift`,
//    using the `PitchCorrectionUndoKey` coalescing strings below.
//
// STILL GENUINELY ABSENT: the render path passes `contour: []`, so
// `preserveVibrato: false` (the `.hardTune` preset) degrades to a constant
// per-note offset and populates `unresolvedShapingSegmentIDs`, which no caller
// reads. That is the one remaining hole, and it is user-visible as Hard Tune
// sounding like Tight.
//
// Everything here is pure, value-typed, and total: same inputs ⇒ byte-identical
// outputs, no clock, no I/O, no actor. None of it is reachable from the render
// thread (§7.6 is absolute), and nothing in this file would be safe there.

// MARK: - Scale

/// Which pitches an auto-correct pass is allowed to snap a note's centre onto.
///
/// ⚠️ **NOT A SECOND SCALE TABLE.** `.major`/`.minor` DELEGATE to
/// `KeyMode.scaleIntervals` (`ChordVoicing.swift`), which is this repo's one
/// home for what "major" means in semitones. Only `.chromatic` is defined here,
/// and it is defined as "all twelve", which cannot drift from anything.
///
/// The raw values of `.major`/`.minor` are exactly `KeyEstimate.mode`'s two
/// strings, so a future "default the scale to the clip's detected key" is a
/// direct construction rather than a translation table.
public enum PitchCorrectionScaleMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Every semitone is allowed — snap to the nearest equal-tempered pitch.
    /// The tonic is irrelevant and is ignored.
    case chromatic
    case major
    case minor

    /// Semitone offsets above the tonic that this mode allows.
    ///
    /// Major and minor read through `KeyMode` rather than restating its arrays:
    /// a second copy that disagreed about the minor sixth would be a wrong note
    /// nobody could see.
    public var scaleIntervals: [Int] {
        switch self {
        case .chromatic: return Array(0..<12)
        case .major: return KeyMode.major.scaleIntervals
        case .minor: return KeyMode.minor.scaleIntervals
        }
    }

    /// Beginner-readable, for a picker. Never "Ionian"/"Aeolian" — the
    /// design-language rule `KeyMode.displayName` already follows.
    public var displayName: String {
        switch self {
        case .chromatic: return "chromatic"
        case .major: return "major"
        case .minor: return "minor"
        }
    }
}

/// A tonic plus a mode: the set of pitches auto-correct may pull a note onto.
public struct PitchCorrectionScale: Codable, Sendable, Equatable {
    /// 0 = C … 11 = B — the index convention of `KeyEstimate.pitchClassesSharp`
    /// (`AudioAnalysis.swift`), this repo's SOLE pitch-class-name array. Values
    /// outside 0…11 wrap rather than trap; ignored entirely when `mode` is
    /// `.chromatic`.
    public var tonicPitchClass: Int
    public var mode: PitchCorrectionScaleMode

    /// Chromatic — every semitone allowed. The identity scale, in the sense
    /// that it never moves a note by more than half a semitone.
    ///
    /// ⛔⛔ **AND THAT SENTENCE IS TRUE AND MISLEADING, MEASURED 2026-09-23.**
    /// "Never moves a note by more than half a semitone" is a statement about
    /// DISTANCE, not about CORRECTNESS. A note sung more than 50 cents off its
    /// intended pitch is nearer the WRONG semitone, and chromatic snapping then
    /// moves it confidently onto that wrong note — a smaller move than the
    /// right one would have been, and musically a different note.
    ///
    /// Measured on a real vocal deliberately pushed to 42–48 cents (where
    /// vibrato and detector noise routinely carry a centre across the
    /// watershed): **24 % of frames came back a semitone away from what was
    /// sung.** The same take corrected at its natural ~19 cents of drift: 1.4 %.
    /// So the failure is not latent everywhere — it switches on as the singer
    /// gets further off, which is exactly when a user reaches for auto-tune.
    ///
    /// ⭐⭐ **AND IT SCORES AS A TRIUMPH.** Distance-to-the-nearest-semitone —
    /// the obvious quality metric, and the one I used — reported the wrong-note
    /// render at 11.7 cents against the untouched take's 18.8, i.e. BETTER than
    /// the original. **A wrong note perfectly in tune is perfect by that
    /// measure.** Any gate on intonation must also check that the note is the
    /// note that was sung.
    ///
    /// ⚠️ **THE MITIGATION IS A KEY, AND IT IS NOT BUILT.** With a real scale
    /// the wrong neighbour is usually not a member, so the snap cannot choose
    /// it. Design §6.3 item 3 (detected-key defaulting, resolved in the STORE
    /// so all three doors inherit it) is the fix and is still unimplemented —
    /// which makes chromatic the default for exactly the material it handles
    /// worst.
    public static let chromatic = PitchCorrectionScale(tonicPitchClass: 0, mode: .chromatic)

    public init(tonicPitchClass: Int = 0, mode: PitchCorrectionScaleMode = .chromatic) {
        self.tonicPitchClass = ((tonicPitchClass % 12) + 12) % 12
        self.mode = mode
    }

    /// The pitch classes this scale allows, ascending from C (not from the
    /// tonic) so the set is directly comparable against `midi % 12`.
    public var allowedPitchClasses: [Int] {
        mode.scaleIntervals.map { (($0 + tonicPitchClass) % 12 + 12) % 12 }.sorted()
    }

    /// Human-readable, for a readout: `"chromatic"`, `"C major"`, `"A minor"`.
    /// Reads the tonic name from `KeyEstimate.pitchClassesSharp` rather than
    /// carrying a second name table.
    public var displayName: String {
        guard mode != .chromatic else { return mode.displayName }
        let name = KeyEstimate.pitchClassesSharp[tonicPitchClass]
        return "\(name) \(mode.displayName)"
    }

    /// The nearest allowed pitch to a (possibly fractional) MIDI note number.
    ///
    /// **The move this can request is bounded BY THE SCALE'S OWN GEOMETRY, not
    /// by a clamp:** chromatic allows every semitone so the move is ≤ 50 cents;
    /// major and minor have a largest gap of 2 semitones so the move is
    /// ≤ 100 cents. That bound is what keeps a confidently-wrong octave reading
    /// from being turned into a confidently-wrong 1200-cent yank — the policy
    /// literally cannot ask for one. (It does NOT make an octave error
    /// harmless: the note lands on the right pitch class in the wrong octave,
    /// correctly tuned. See constraint 3 in the banner.)
    ///
    /// On an exact tie — a note sitting precisely between two allowed pitches,
    /// e.g. C♯ in C major — the HIGHER pitch wins. Arbitrary, deterministic,
    /// and stated so a test can pin it.
    public func nearestAllowedMidi(to midi: Double) -> Double {
        guard midi.isFinite else { return midi }
        let allowed = Set(allowedPitchClasses)
        // 12 candidates each side is more than enough: the largest gap in any
        // mode here is 2 semitones.
        let centre = (midi).rounded()
        var best: Double?
        var bestDistance = Double.infinity
        for offset in -12...12 {
            let candidate = centre + Double(offset)
            let pitchClass = ((Int(candidate) % 12) + 12) % 12
            guard allowed.contains(pitchClass) else { continue }
            let distance = abs(candidate - midi)
            // `>` on the tie, so a later (higher) candidate replaces an equal
            // earlier (lower) one — the documented tie-break.
            if distance < bestDistance || (distance == bestDistance && candidate > (best ?? -.infinity)) {
                bestDistance = distance
                best = candidate
            }
        }
        return best ?? centre
    }
}

// MARK: - The edit set

/// ONE detected note and the edits standing on it.
///
/// `detectedHz` / `detectedConfidence` are what the DETECTOR said. They are
/// **never mutated by an edit** — that is what makes the rendered curve a pure
/// function of `(detected contour, edit set)`, and what makes "re-run detection
/// on already-corrected audio", the classic way these features rot, structurally
/// impossible.
///
/// Times are SOURCE-FILE seconds (see the banner). Every numeric field is
/// sanitised in `init`: a non-finite value reverts to its default rather than
/// propagating a NaN into the curve.
public struct NoteSegment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID

    /// Note start / end, SOURCE-FILE seconds. `endSeconds > startSeconds` is
    /// healed in `init` (an inverted or zero-length pair collapses to a
    /// zero-length segment, which `PitchEditSet.init` then drops).
    public var startSeconds: Double
    public var endSeconds: Double

    /// The note's detected centre, Hz. **Never changed by an edit.** For a
    /// segment produced by `PitchAutoCorrect` this is the MEDIAN of the run's
    /// voiced frames, which is what survives vibrato and an onset scoop.
    public let detectedHz: Double
    /// The detector's own confidence at that centre, 0…1. **Voicing evidence
    /// ONLY** — see constraint 3 in the banner. Never read as accuracy.
    public let detectedConfidence: Double

    /// THE edit: the signed correction applied to this note's centre, in cents.
    /// Negative pulls flat, positive pulls sharp.
    public var pitchOffsetCents: Double

    /// How much of the note's MACRO pitch drift to keep: 0 flattens it onto the
    /// centre, 1 keeps it verbatim, >1 exaggerates. Needs the detected contour
    /// at evaluation time (see `PitchCorrectionCurve.make`).
    public var driftScale: Double

    /// How much of the note's PERIODIC modulation to keep: 0 flattens, 1 keeps,
    /// >1 exaggerates.
    ///
    /// ⚠️ **A KEEP/FLATTEN LEVER, NOT A CALIBRATED DEPTH CONTROL.** The chain
    /// returns vibrato 1.06×/1.15×/1.20× deeper than asked at 1/5/8 Hz
    /// (phase-0 §8), so a control that said "50 cents" would deliver 57.
    /// Do not label this as a depth in cents anywhere.
    public var vibratoScale: Double

    /// Phase 4 — carried so the schema does not change under a saved project
    /// later. **No renderer reads it today.**
    public var formantOffsetSemitones: Double
    /// Phase 3 — carried, unread. Per-note timing has a hard ceiling
    /// (`maxCleanStretch = 2`) that phase 3 must clamp against; this field is
    /// deliberately NOT clamped to an invented range here, only sanitised
    /// against NaN, because inventing phase 3's limit now would ship a number
    /// nobody measured.
    public var timeStartDeltaSeconds: Double
    public var timeEndDeltaSeconds: Double
    /// Phase 4 — carried, unread. Shares `Clip.gainDbRange` rather than
    /// minting a second gain range.
    public var amplitudeDb: Double

    /// ±24 semitones expressed in cents — the same span as
    /// `Clip.pitchShiftSemitonesRange`, so a per-note offset can never ask for
    /// something the whole-clip control could not.
    public static let pitchOffsetCentsRange: ClosedRange<Double> = -2400...2400
    /// 0 = flatten, 1 = keep, up to 4× exaggeration. The ceiling is a pick: it
    /// bounds the curve without pretending to be a measured limit.
    public static let shapeScaleRange: ClosedRange<Double> = 0...4
    /// ±24 semitones, matching the whole-clip pitch range.
    public static let formantOffsetSemitonesRange: ClosedRange<Double> = -24...24

    /// True when this segment asks the curve for nothing — a detected note the
    /// user has not edited. Such a segment is still worth persisting (it is the
    /// note table an editor draws), which is why this is NOT the emptiness test
    /// persistence uses.
    public var isIdentity: Bool {
        pitchOffsetCents == 0 && driftScale == 1 && vibratoScale == 1
            && formantOffsetSemitones == 0
            && timeStartDeltaSeconds == 0 && timeEndDeltaSeconds == 0
            && amplitudeDb == 0
    }

    /// Note length in source seconds; never negative.
    public var durationSeconds: Double { max(0, endSeconds - startSeconds) }

    public init(
        id: UUID = UUID(),
        startSeconds: Double,
        endSeconds: Double,
        detectedHz: Double,
        detectedConfidence: Double,
        pitchOffsetCents: Double = 0,
        driftScale: Double = 1,
        vibratoScale: Double = 1,
        formantOffsetSemitones: Double = 0,
        timeStartDeltaSeconds: Double = 0,
        timeEndDeltaSeconds: Double = 0,
        amplitudeDb: Double = 0
    ) {
        self.id = id
        let start = max(0, PitchCorrectionMath.finite(startSeconds, default: 0))
        self.startSeconds = start
        self.endSeconds = max(start, PitchCorrectionMath.finite(endSeconds, default: start))
        // A detected pitch is a real positive frequency or it is not a detected
        // pitch — the same contract `ClipPitchFrame` enforces with a
        // precondition. Here it is healed rather than trapped, because this type
        // is decoded from disk and a damaged file must not crash the app.
        let hz = PitchCorrectionMath.finite(detectedHz, default: 0)
        self.detectedHz = hz > 0 ? hz : 0
        self.detectedConfidence = PitchCorrectionMath
            .finite(detectedConfidence, default: 0).clamped(to: 0...1)
        self.pitchOffsetCents = PitchCorrectionMath
            .finite(pitchOffsetCents, default: 0).clamped(to: Self.pitchOffsetCentsRange)
        self.driftScale = PitchCorrectionMath
            .finite(driftScale, default: 1).clamped(to: Self.shapeScaleRange)
        self.vibratoScale = PitchCorrectionMath
            .finite(vibratoScale, default: 1).clamped(to: Self.shapeScaleRange)
        self.formantOffsetSemitones = PitchCorrectionMath
            .finite(formantOffsetSemitones, default: 0)
            .clamped(to: Self.formantOffsetSemitonesRange)
        self.timeStartDeltaSeconds = PitchCorrectionMath.finite(timeStartDeltaSeconds, default: 0)
        self.timeEndDeltaSeconds = PitchCorrectionMath.finite(timeEndDeltaSeconds, default: 0)
        self.amplitudeDb = PitchCorrectionMath
            .finite(amplitudeDb, default: 0).clamped(to: Clip.gainDbRange)
    }

    private enum CodingKeys: String, CodingKey {
        case id, startSeconds, endSeconds, detectedHz, detectedConfidence
        case pitchOffsetCents, driftScale, vibratoScale
        case formantOffsetSemitones, timeStartDeltaSeconds, timeEndDeltaSeconds, amplitudeDb
    }

    /// Decoding routes through the healing `init` — the `Clip`/`MIDINote`
    /// precedent — so a hand-authored payload cannot smuggle in a NaN or an
    /// out-of-range scale, and every phase-3/4 field tolerates absence.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            startSeconds: try c.decodeIfPresent(Double.self, forKey: .startSeconds) ?? 0,
            endSeconds: try c.decodeIfPresent(Double.self, forKey: .endSeconds) ?? 0,
            detectedHz: try c.decodeIfPresent(Double.self, forKey: .detectedHz) ?? 0,
            detectedConfidence: try c.decodeIfPresent(Double.self, forKey: .detectedConfidence) ?? 0,
            pitchOffsetCents: try c.decodeIfPresent(Double.self, forKey: .pitchOffsetCents) ?? 0,
            driftScale: try c.decodeIfPresent(Double.self, forKey: .driftScale) ?? 1,
            vibratoScale: try c.decodeIfPresent(Double.self, forKey: .vibratoScale) ?? 1,
            formantOffsetSemitones: try c.decodeIfPresent(
                Double.self, forKey: .formantOffsetSemitones) ?? 0,
            timeStartDeltaSeconds: try c.decodeIfPresent(
                Double.self, forKey: .timeStartDeltaSeconds) ?? 0,
            timeEndDeltaSeconds: try c.decodeIfPresent(
                Double.self, forKey: .timeEndDeltaSeconds) ?? 0,
            amplitudeDb: try c.decodeIfPresent(Double.self, forKey: .amplitudeDb) ?? 0)
    }

    /// Writes the four detection facts always (they are what the segment IS),
    /// and every EDIT field only when it departs from its default — the
    /// `Clip`/`Track` omit-when-default rule. A freshly detected, unedited note
    /// is therefore five keys, not twelve, which is what keeps §7.3's ~200
    /// bytes/segment sizing honest at 450 segments per corrected vocal.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startSeconds, forKey: .startSeconds)
        try c.encode(endSeconds, forKey: .endSeconds)
        try c.encode(detectedHz, forKey: .detectedHz)
        try c.encode(detectedConfidence, forKey: .detectedConfidence)
        if pitchOffsetCents != 0 { try c.encode(pitchOffsetCents, forKey: .pitchOffsetCents) }
        if driftScale != 1 { try c.encode(driftScale, forKey: .driftScale) }
        if vibratoScale != 1 { try c.encode(vibratoScale, forKey: .vibratoScale) }
        if formantOffsetSemitones != 0 {
            try c.encode(formantOffsetSemitones, forKey: .formantOffsetSemitones)
        }
        if timeStartDeltaSeconds != 0 {
            try c.encode(timeStartDeltaSeconds, forKey: .timeStartDeltaSeconds)
        }
        if timeEndDeltaSeconds != 0 {
            try c.encode(timeEndDeltaSeconds, forKey: .timeEndDeltaSeconds)
        }
        if amplitudeDb != 0 { try c.encode(amplitudeDb, forKey: .amplitudeDb) }
    }
}

/// Every pitch edit on one clip. Lives on `Clip` (design §7.1/§7.5), which is
/// what makes take lanes free at the model layer: `TakeLane.clip` IS a `Clip`.
public struct PitchEditSet: Codable, Sendable, Equatable {
    /// Which detector produced `segments`' detection facts. A stale set is
    /// still honoured — never silently re-detected — and §7.2 requires this to
    /// be part of the render cache's hashed material so a detector change
    /// re-keys instead of quietly changing how a vocal sounds.
    public var analysisVersion: Int

    /// Detected notes and their edits, CANONICAL: ascending by `startSeconds`,
    /// strictly non-overlapping, zero-length entries dropped. `init` heals any
    /// input, so no construction path (decode, policy, a future editor) can
    /// store a set the curve would double-count.
    public var segments: [NoteSegment]

    /// How long the correction takes to reach its target at a note boundary,
    /// milliseconds.
    ///
    /// ⚠️⚠️ **THIS FIELD IS NOT IN DESIGN §7.1's SCHEMA. IT IS AN ADDITION, AND
    /// HERE IS WHY IT HAD TO BE ONE.** §7.7 gives `clip.autoCorrectPitch` a
    /// `retune-speed ms` option, and §6.4 requires the curve to ramp across a
    /// boundary rather than jump. Those are the same mechanism. With nowhere to
    /// store it, a project would reopen with the ramp the code happened to
    /// default to rather than the one the user chose — a silent, invisible
    /// change to how a corrected vocal sounds. Set-level rather than per-segment
    /// because it is one musical decision about a performance, not 450 of them.
    ///
    /// **The lower bound is an ENGINE FLOOR, not a preference.** §6.4 allows a
    /// 20–40 ms transition because that is 1–2 analysis hops, and one hop is
    /// 30 ms at 48 kHz — the curve is read once per hop, so anything faster is
    /// a request the renderer cannot honour. `init` CLAMPS rather than rejects,
    /// so `set.retuneMs` always reads back what actually applies (a setter's
    /// return is not proof it took).
    public var retuneMs: Double

    /// The shortest ramp the renderer can honour: one 30 ms analysis hop at
    /// 48 kHz (phase-0 §2/§6 — the curve is read once per chunk, and a mid-hop
    /// request waits exactly one full hop, not a fraction of one).
    public static let engineMinimumRetuneMs: Double = 30
    /// 30 ms (the floor, a natural-sounding correction) to 500 ms (a slow,
    /// scoop-preserving retune). The ceiling is a pick, bounded rather than
    /// measured.
    public static let retuneMsRange: ClosedRange<Double> = engineMinimumRetuneMs...500

    /// The detector generation this build's segments come from. Bump when the
    /// DETECTOR changes, never when this file changes.
    public static let currentAnalysisVersion: Int = 1

    /// No notes at all. The persistence emptiness test: an empty set is stored
    /// as no key, so a project without pitch edits is byte-identical to one
    /// saved before this field existed.
    public var isEmpty: Bool { segments.isEmpty }

    /// The curve this set produces is flat — either there are no notes, or every
    /// note is untouched. §6.4's "never bypass the identity path" hook: a clip
    /// whose set is identity must still hit `OfflineStretcher.isIdentity` and
    /// play its source byte-for-byte.
    ///
    /// ⚠️ DISTINCT FROM `isEmpty` ON PURPOSE. A set of freshly DETECTED,
    /// unedited notes is `isIdentity == true` but `isEmpty == false`: it renders
    /// as nothing and is still worth saving, because it is the note table the
    /// editor draws and re-detecting it costs a model run.
    public var isIdentity: Bool { segments.allSatisfy(\.isIdentity) }

    public static let empty = PitchEditSet(analysisVersion: currentAnalysisVersion, segments: [])

    public init(analysisVersion: Int = PitchEditSet.currentAnalysisVersion,
                segments: [NoteSegment] = [],
                retuneMs: Double = PitchEditSet.engineMinimumRetuneMs) {
        self.analysisVersion = analysisVersion
        self.retuneMs = PitchCorrectionMath
            .finite(retuneMs, default: Self.engineMinimumRetuneMs)
            .clamped(to: Self.retuneMsRange)
        self.segments = Self.canonical(segments)
    }

    /// Ascending by start, strictly non-overlapping, zero-length dropped.
    ///
    /// **Overlap HEALS rather than trapping, and the rule is FIRST-WINS:** a
    /// later segment's start truncates the previous one's end. Overlapping
    /// notes are structurally invalid for a monophonic vocal, and a decoded
    /// project must not crash on a damaged one. This is the invariant
    /// `PitchCorrectionCurve` relies on to know at most two segments are ever
    /// blending at once, so it cannot be relaxed without revisiting the curve.
    public static func canonical(_ segments: [NoteSegment]) -> [NoteSegment] {
        guard !segments.isEmpty else { return [] }
        let sorted = segments.sorted {
            $0.startSeconds != $1.startSeconds
                ? $0.startSeconds < $1.startSeconds
                : $0.endSeconds < $1.endSeconds
        }
        var out: [NoteSegment] = []
        out.reserveCapacity(sorted.count)
        for var segment in sorted {
            if let previousEnd = out.last?.endSeconds, segment.startSeconds < previousEnd {
                // FIRST-WINS: the earlier note keeps its full length and the
                // later one starts where it left off. A fully NESTED segment
                // collapses to zero length and is dropped on the next line.
                segment.startSeconds = previousEnd
            }
            guard segment.endSeconds > segment.startSeconds else { continue }
            out.append(segment)
        }
        return out
    }

    private enum CodingKeys: String, CodingKey {
        case analysisVersion, segments, retuneMs
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            analysisVersion: try c.decodeIfPresent(Int.self, forKey: .analysisVersion)
                ?? Self.currentAnalysisVersion,
            segments: try c.decodeIfPresent([NoteSegment].self, forKey: .segments) ?? [],
            retuneMs: try c.decodeIfPresent(Double.self, forKey: .retuneMs)
                ?? Self.engineMinimumRetuneMs)
    }

    /// `retuneMs` is omitted at the floor, the same omit-when-default rule the
    /// rest of the clip payload follows.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(analysisVersion, forKey: .analysisVersion)
        try c.encode(segments, forKey: .segments)
        if retuneMs != Self.engineMinimumRetuneMs { try c.encode(retuneMs, forKey: .retuneMs) }
    }
}

// MARK: - Undo keys (design §7.4)

/// The EXACT coalescing keys design §7.4 specifies, in one place, so a store
/// operation and a test can never disagree about the string.
///
/// The shape is `ProjectStore.swift`'s own (`"track.volume:<uuid>"`): a dotted
/// verb path, then colon-separated uppercase `uuidString`s.
///
/// **What coalesces and what does not** — the rules, stated here because the
/// key IS the rule:
///  * A continuous DRAG on one segment coalesces, because every step of it
///    produces the same key. Dragging a DIFFERENT note starts a new undo entry,
///    because the segment id differs. Dragging drift and dragging pitch on the
///    SAME note are separate entries, because the verb differs.
///  * A STRUCTURAL edit — split a segment, merge two, re-run detection, apply
///    or clear a whole auto-correct pass — passes `structuralKey` (`nil`) and
///    never coalesces with anything, including itself.
///  * A MULTI-SELECT edit over N segments is ONE entry over all N (the
///    `clip.moveMany` group-verb precedent), so it uses `structuralKey` too — a
///    per-segment key would either make N entries or coalesce two different
///    multi-selects into one.
///
/// No store operation exists yet; this task is model-layer only.
public enum PitchCorrectionUndoKey {
    /// A pitch drag on one note.
    public static func segment(clipID: UUID, segmentID: UUID) -> String {
        "pitch.segment:\(clipID.uuidString):\(segmentID.uuidString)"
    }

    /// A drift-scale drag on one note.
    public static func drift(clipID: UUID, segmentID: UUID) -> String {
        "pitch.drift:\(clipID.uuidString):\(segmentID.uuidString)"
    }

    /// A vibrato-scale drag on one note.
    public static func vibrato(clipID: UUID, segmentID: UUID) -> String {
        "pitch.vibrato:\(clipID.uuidString):\(segmentID.uuidString)"
    }

    /// Structural and multi-select edits: `nil` — never coalesces.
    /// Named rather than written as a bare `nil` at each call site so the
    /// decision is greppable.
    public static let structuralKey: String? = nil
}

// MARK: - The one evaluator

/// **THE** pitch-correction curve. One evaluator, one place to be wrong
/// (design §6.4/§7.1, the `ArrangeDropSnap` model).
///
/// `init` is `fileprivate` and `make` is the only producer in this file, so a
/// curve whose internals disagree with the rule is UNREPRESENTABLE — no caller,
/// and no test, can assemble one. When the render path lands it calls `make`
/// and `semitones(atSourceSecond:)`; a UI readout calls the same two things.
/// There is no second path, and the type offers no way to build one.
///
/// **What it sums**, at a source-file second `t`:
///
///  1. `Clip.pitchShiftSemitones` — the existing whole-clip term. The curve
///     SUBSUMES it (§6.4/§7.8: no second whole-clip pitch path), so a renderer
///     driven by this curve must NOT also apply the clip's constant shift.
///  2. For each note segment overlapping `t`, gated by the boundary ramp:
///     * `pitchOffsetCents` — the note's constant correction;
///     * `(driftScale − 1) × drift(t)` — macro pitch wander, relative to the
///       note's detected centre;
///     * `(vibratoScale − 1) × vibrato(t)` — periodic modulation, likewise.
///
/// The two shaping terms are ZERO whenever their scales are 1, which is the
/// entire Phase-1 policy: a preserve-vibrato correction is a CONSTANT per note,
/// so the performance's modulation passes through untouched by construction
/// rather than by a filter that tries to leave it alone.
///
/// **Smoothness, honestly.** Inside a note with default scales the curve is
/// CONSTANT, and each boundary is a smoothstep — C¹ everywhere, which is what
/// §6.4 asks for. The shaping terms, when a future editor turns them on, are
/// interpolated linearly between detector frames: C⁰ on a 16 ms grid, finer
/// than the renderer's own 30 ms hop but not C¹. Stated rather than claimed
/// away.
///
/// **Ramps are CENTRED on boundaries.** A segment `[s, e]` rises across
/// `[s − r/2, s + r/2]` and falls across `[e − r/2, e + r/2]`. One-sided ramps
/// would notch to zero at a shared boundary between two abutting notes;
/// centred complementary smoothsteps sum to exactly 1 there, giving a
/// crossfade. Where gates do sum above 1 (very short notes under a long ramp)
/// they are normalised, so the result is always a convex blend of the active
/// corrections and never overshoots past either of them.
public struct PitchCorrectionCurve: Sendable, Equatable {
    /// One note's precomputed contribution.
    fileprivate struct Span: Sendable, Equatable {
        let startSeconds: Double
        let endSeconds: Double
        /// Half the ramp width, already clamped so it cannot exceed half the
        /// note.
        let halfRamp: Double
        /// `pitchOffsetCents / 100`.
        let constantSemitones: Double
        /// Shaping contribution per detector frame, semitones, or empty when
        /// both scales are 1 (the Phase-1 case) or no contour covered the note.
        let shapingSemitones: [Double]
        /// Time of `shapingSemitones[0]`, and the frame spacing.
        let shapingStartSeconds: Double
        let shapingStepSeconds: Double
    }

    /// The whole-clip term this curve subsumes.
    public let clipPitchShiftSemitones: Double

    /// Segments that asked for drift/vibrato shaping but had no detected
    /// contour to shape — their constant `pitchOffsetCents` still applies, the
    /// shaping term is ZERO, and they are named here.
    ///
    /// ⚠️ **HONEST ABSENCE, NOT A SILENT BEST EFFORT.** The detected contour is
    /// deliberately NOT persisted (§7.3 — it is regenerable and belongs beside
    /// the renders), so a project can be reopened with an edit set whose
    /// shaping terms have nothing to stand on. Inventing a contour would be the
    /// exact "confident wrong answer" failure this subsystem is full of
    /// warnings about; returning a curve that silently omits the shaping with
    /// no way to know would be worse. A caller that finds this non-empty should
    /// re-run detection before rendering.
    public let unresolvedShapingSegmentIDs: [UUID]

    fileprivate let spans: [Span]

    fileprivate init(clipPitchShiftSemitones: Double,
                     spans: [Span],
                     unresolvedShapingSegmentIDs: [UUID]) {
        self.clipPitchShiftSemitones = clipPitchShiftSemitones
        self.spans = spans
        self.unresolvedShapingSegmentIDs = unresolvedShapingSegmentIDs
    }

    /// Window over which macro DRIFT is separated from periodic VIBRATO: drift
    /// is the contour averaged over this long, vibrato is what is left.
    ///
    /// ⚠️ **AN UNCALIBRATED PICK, and it is exercised less than it looks.**
    /// 250 ms averages away anything at or above 4 Hz, which is where sung
    /// vibrato lives. But when `driftScale == vibratoScale` — which is EVERY
    /// set `PitchAutoCorrect` produces — the split cancels algebraically
    /// (`(s−1)·drift + (s−1)·vib == (s−1)·(drift + vib)`) and the window has no
    /// effect at all. It only starts to matter when a Phase-2 editor moves the
    /// two apart, and that is the point at which it should be measured rather
    /// than picked.
    public static let driftWindowSeconds: Double = 0.25

    /// Build the curve. The ONLY producer.
    ///
    /// - Parameters:
    ///   - editSet: the clip's edits. Empty ⇒ the curve is exactly
    ///     `clipPitchShiftSemitones` everywhere, bit-for-bit.
    ///   - contour: the DETECTED per-frame pitch, source-file seconds. Needed
    ///     only by segments whose `driftScale`/`vibratoScale` depart from 1;
    ///     pass `[]` when there is none and read
    ///     `unresolvedShapingSegmentIDs` afterwards.
    ///   - clipPitchShiftSemitones: `Clip.pitchShiftSemitones`, which this
    ///     curve SUBSUMES.
    public static func make(editSet: PitchEditSet,
                            contour: [ClipPitchFrame] = [],
                            clipPitchShiftSemitones: Double = 0) -> PitchCorrectionCurve {
        let base = PitchCorrectionMath.finite(clipPitchShiftSemitones, default: 0)
        guard !editSet.segments.isEmpty else {
            return PitchCorrectionCurve(clipPitchShiftSemitones: base,
                                        spans: [], unresolvedShapingSegmentIDs: [])
        }
        let ramp = editSet.retuneMs / 1000
        // Voiced frames only, ascending. An unvoiced frame carries no pitch and
        // is not turned into one — it simply is not here.
        let voiced = contour
            .filter { $0.frequencyHz != nil }
            .sorted { $0.timeSeconds < $1.timeSeconds }

        var spans: [Span] = []
        var unresolved: [UUID] = []
        spans.reserveCapacity(editSet.segments.count)

        for segment in editSet.segments {
            let wantsShaping = segment.driftScale != 1 || segment.vibratoScale != 1
            var shaping: [Double] = []
            var shapingStart = 0.0
            var shapingStep = 0.0

            if wantsShaping {
                let frames = voiced.filter {
                    $0.timeSeconds >= segment.startSeconds && $0.timeSeconds < segment.endSeconds
                }
                if frames.count >= 2, segment.detectedHz > 0 {
                    let step = (frames[frames.count - 1].timeSeconds - frames[0].timeSeconds)
                        / Double(frames.count - 1)
                    if step > 0 {
                        // Contour in cents relative to the note's DETECTED
                        // centre. `detectedHz` is never mutated by an edit, so
                        // this reference point is stable no matter what the
                        // user has done to the note.
                        let cents = frames.map {
                            PitchCorrectionMath.cents(from: segment.detectedHz,
                                                      to: $0.frequencyHz ?? segment.detectedHz)
                        }
                        let drift = PitchCorrectionMath.movingAverage(
                            cents, windowSeconds: driftWindowSeconds, stepSeconds: step)
                        shaping = zip(cents, drift).map { total, macro in
                            let vibrato = total - macro
                            return ((segment.driftScale - 1) * macro
                                + (segment.vibratoScale - 1) * vibrato) / 100
                        }
                        shapingStart = frames[0].timeSeconds
                        shapingStep = step
                    }
                }
                if shaping.isEmpty { unresolved.append(segment.id) }
            }

            spans.append(Span(
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                halfRamp: min(ramp / 2, segment.durationSeconds / 2),
                constantSemitones: segment.pitchOffsetCents / 100,
                shapingSemitones: shaping,
                shapingStartSeconds: shapingStart,
                shapingStepSeconds: shapingStep))
        }
        return PitchCorrectionCurve(clipPitchShiftSemitones: base,
                                    spans: spans,
                                    unresolvedShapingSegmentIDs: unresolved)
    }

    /// Absolute pitch, in semitones, that the renderer should be transposing by
    /// at source-file second `sourceSecond`.
    ///
    /// Pure and total. A non-finite input returns the whole-clip term rather
    /// than propagating a NaN, and a result that somehow came out non-finite
    /// does the same — this value ends up driving a transpose curve, and a NaN
    /// there is an audible catastrophe, not a log line.
    public func semitones(atSourceSecond sourceSecond: Double) -> Double {
        guard sourceSecond.isFinite else { return clipPitchShiftSemitones }
        guard !spans.isEmpty else { return clipPitchShiftSemitones }

        var weighted = 0.0
        var totalGate = 0.0
        // Segments are canonical (ascending, non-overlapping) and a ramp reaches
        // at most half its width past an edge, so only neighbours of the hit
        // point can contribute. Scan from the first span that could still be
        // open at `sourceSecond`.
        var index = Self.firstSpanIndex(spans, notEndedBefore: sourceSecond)
        while index < spans.count {
            let span = spans[index]
            if sourceSecond < span.startSeconds - span.halfRamp { break }
            let gate = Self.gate(span, at: sourceSecond)
            // Flush a vanishing gate rather than accumulating denormals into
            // the blend.
            if gate > 1e-12 {
                weighted += gate * (span.constantSemitones + Self.shaping(span, at: sourceSecond))
                totalGate += gate
            }
            index += 1
        }
        guard totalGate > 1e-12 else { return clipPitchShiftSemitones }
        // Normalise only when the gates over-sum — abutting notes with equal
        // ramps already sum to exactly 1, and normalising then would be a no-op
        // that still cost a divide.
        let blended = totalGate > 1 ? weighted / totalGate : weighted
        let total = clipPitchShiftSemitones + blended
        return total.isFinite ? total : clipPitchShiftSemitones
    }

    /// The boundary ramp, 0 outside the note and 1 in its middle, C¹ at both
    /// ends (§6.4: smooth inside a note, fast but never instantaneous across a
    /// boundary — a map change moves the spectral envelope discontinuously, and
    /// phase-0 §5.4 measured the resulting level dip at −5.11 dB for an
    /// instantaneous 2-semitone jump against −1.20 dB spread over three hops).
    fileprivate static func gate(_ span: Span, at t: Double) -> Double {
        let half = span.halfRamp
        guard half > 0 else {
            return (t >= span.startSeconds && t < span.endSeconds) ? 1 : 0
        }
        let rise = smoothstep((t - (span.startSeconds - half)) / (2 * half))
        let fall = 1 - smoothstep((t - (span.endSeconds - half)) / (2 * half))
        return rise * fall
    }

    /// Hermite smoothstep `3x² − 2x³`, clamped. C¹ at both ends, and
    /// COMPLEMENTARY — `s(x) + s(1 − x) == 1` — which is exactly why two
    /// abutting notes crossfade to unity instead of notching.
    fileprivate static func smoothstep(_ x: Double) -> Double {
        let c = x.clamped(to: 0...1)
        return c * c * (3 - 2 * c)
    }

    /// Linear interpolation into the precomputed per-frame shaping, held at
    /// both ends. Empty ⇒ 0, which is the Phase-1 case and the
    /// no-contour-available case alike (the latter is reported through
    /// `unresolvedShapingSegmentIDs` rather than being indistinguishable).
    fileprivate static func shaping(_ span: Span, at t: Double) -> Double {
        guard !span.shapingSemitones.isEmpty, span.shapingStepSeconds > 0 else { return 0 }
        let position = (t - span.shapingStartSeconds) / span.shapingStepSeconds
        guard position > 0 else { return span.shapingSemitones[0] }
        let last = span.shapingSemitones.count - 1
        guard position < Double(last) else { return span.shapingSemitones[last] }
        let lower = Int(position)
        let fraction = position - Double(lower)
        return span.shapingSemitones[lower] * (1 - fraction)
            + span.shapingSemitones[lower + 1] * fraction
    }

    /// Binary search for the first span whose ramped window could still be open
    /// at `t` — i.e. the first with `endSeconds + halfRamp > t`.
    fileprivate static func firstSpanIndex(_ spans: [Span], notEndedBefore t: Double) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let mid = (low + high) / 2
            if spans[mid].endSeconds + spans[mid].halfRamp > t {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}

// MARK: - The auto-correct policy

/// What an auto-correct pass should do. Design §7.7's `clip.autoCorrectPitch`
/// option set, as a value type so the policy stays a pure function of it.
public struct PitchAutoCorrectOptions: Codable, Sendable, Equatable {
    /// Which pitches a note may be pulled onto.
    public var scale: PitchCorrectionScale

    /// How much of the way to the target to go: 0 = no correction at all
    /// (EXACTLY identity — no segments, no offsets), 1 = all the way onto the
    /// scale pitch. Clamped to 0…1.
    public var strength: Double

    /// How long the correction takes to arrive at a note boundary. Clamped to
    /// `PitchEditSet.retuneMsRange`; the floor is the renderer's one-hop limit,
    /// not a taste decision.
    public var retuneMs: Double

    /// Keep the performance's modulation, or flatten it.
    ///
    /// **This is the difference between a musical result and a robot, and the
    /// two branches are structurally different, not two settings of one dial:**
    ///  * `true` — the note's CENTRE is moved by one constant number of cents
    ///    and nothing else is touched. Vibrato, drift and the onset scoop pass
    ///    through untouched BY CONSTRUCTION, because the curve inside the note
    ///    is a constant. `driftScale`/`vibratoScale` stay at 1.
    ///  * `false` — the contour is flattened onto the target as well, by
    ///    setting both scales to `1 − strength`. At `strength == 1` the sung
    ///    pitch is replaced by the target exactly; this is the hard-tune sound,
    ///    and it needs the detected contour at render time.
    public var preserveVibrato: Bool

    public init(scale: PitchCorrectionScale = .chromatic,
                strength: Double = 1,
                retuneMs: Double = PitchEditSet.engineMinimumRetuneMs,
                preserveVibrato: Bool = true) {
        self.scale = scale
        self.strength = PitchCorrectionMath.finite(strength, default: 0).clamped(to: 0...1)
        self.retuneMs = PitchCorrectionMath
            .finite(retuneMs, default: PitchEditSet.engineMinimumRetuneMs)
            .clamped(to: PitchEditSet.retuneMsRange)
        self.preserveVibrato = preserveVibrato
    }
}

/// One run of consecutive VOICED frames — a provisional note.
///
/// ⚠️ **THE SEAM PHASE 2 REPLACES.** Design §11.2 gives segmentation its own
/// design doc, and this is deliberately the dumbest thing that is not wrong: a
/// note is a maximal run of voiced frames, and a hole ends it. It does NOT
/// split a legato phrase where the singer changes note without stopping — two
/// slurred notes come out as ONE run with a median somewhere between them, and
/// a test pins exactly that so the limitation is visible rather than discovered.
/// Onset evidence (`detectTransients`) and a target-change splitter are
/// Phase 2's problem; inventing one here would build on a foundation §11.2 says
/// is still being designed.
public struct VoicedRun: Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    /// MEDIAN of the run's frames, Hz. Median rather than mean because it is
    /// what survives vibrato (symmetric, so it lands on the centre) and an
    /// onset scoop (a minority of frames, so it is outvoted).
    public let centreHz: Double
    /// Median of the run's per-frame confidences. **Voicing evidence only.**
    public let medianConfidence: Double
    /// How many voiced frames the run was built from.
    public let frameCount: Int

    public init(startSeconds: Double, endSeconds: Double, centreHz: Double,
                medianConfidence: Double, frameCount: Int) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.centreHz = centreHz
        self.medianConfidence = medianConfidence
        self.frameCount = frameCount
    }
}

/// The auto-correct policy: a detected contour plus options in, a populated
/// `PitchEditSet` out. Pure — no clock, no I/O, no store, no engine.
public enum PitchAutoCorrect {
    /// A run shorter than this is not treated as a note. At the detector's
    /// 62.5 fps that is ~4 frames.
    ///
    /// A pick, bounded by two facts rather than measured: a single 16 ms frame
    /// is not a note anybody sang, and the renderer's own ramp is 30 ms, so a
    /// note shorter than this could not be corrected without the ramp swallowing
    /// it whole.
    public static let minimumNoteSeconds: Double = 0.06

    /// Split a contour into provisional notes. See `VoicedRun` for what this
    /// deliberately does not do.
    ///
    /// **Holes end runs and are never crossed.** An unvoiced frame carries no
    /// pitch (`frequencyHz == nil`), and this treats that as the END of the
    /// note rather than as a gap to bridge. A run's median is therefore computed
    /// only from frames that actually had a pitch — a hole can never pull a
    /// note's centre anywhere.
    public static func voicedRuns(in frames: [ClipPitchFrame],
                                  frameRateHz: Double) -> [VoicedRun] {
        let rate = PitchCorrectionMath.finite(frameRateHz, default: 0)
        guard rate > 0, !frames.isEmpty else { return [] }
        let framePeriod = 1 / rate
        let ordered = frames.sorted { $0.timeSeconds < $1.timeSeconds }

        var runs: [VoicedRun] = []
        var current: [ClipPitchFrame] = []

        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard let first = current.first, let last = current.last else { return }
            let start = first.timeSeconds
            let end = last.timeSeconds + framePeriod
            guard end - start >= minimumNoteSeconds else { return }
            let hz = current.compactMap(\.frequencyHz)
            guard let centre = PitchCorrectionMath.medianFrequency(hz) else { return }
            runs.append(VoicedRun(
                startSeconds: start,
                endSeconds: end,
                centreHz: centre,
                medianConfidence: PitchCorrectionMath.median(current.map(\.confidence)) ?? 0,
                frameCount: current.count))
        }

        var previousTime: Double?
        for frame in ordered {
            guard frame.frequencyHz != nil else { flush(); previousTime = nil; continue }
            // A jump larger than 1.5 frame periods is a gap in the analysis
            // itself (a windowed detection request, a decimated payload) and
            // ends the run for the same reason a hole does: nothing was
            // measured in between, so nothing may be assumed about it.
            if let previous = previousTime, frame.timeSeconds - previous > framePeriod * 1.5 {
                flush()
            }
            current.append(frame)
            previousTime = frame.timeSeconds
        }
        flush()
        return runs
    }

    /// **THE POLICY.** Detected contour + options ⇒ a populated `PitchEditSet`.
    ///
    /// `strength == 0` returns `PitchEditSet.empty` — no segments, no offsets,
    /// and a curve that is bit-for-bit the clip's own constant shift. That is
    /// the structural identity the whole feature must collapse to, so it is a
    /// short-circuit and not an arithmetic coincidence.
    public static func editSet(contour frames: [ClipPitchFrame],
                               frameRateHz: Double,
                               options: PitchAutoCorrectOptions,
                               analysisVersion: Int = PitchEditSet.currentAnalysisVersion)
    -> PitchEditSet {
        guard options.strength > 0 else { return .empty }
        let runs = voicedRuns(in: frames, frameRateHz: frameRateHz)
        guard !runs.isEmpty else {
            return PitchEditSet(analysisVersion: analysisVersion,
                                segments: [], retuneMs: options.retuneMs)
        }
        // Flattening IS correction, so it scales with strength: at strength 0
        // both branches are the identity, and at strength 1 the robot branch
        // replaces the contour outright.
        let shapeScale = options.preserveVibrato ? 1 : (1 - options.strength)

        let segments = runs.map { run -> NoteSegment in
            let detectedMidi = PitchCorrectionMath.midi(fromHz: run.centreHz)
            let targetMidi = options.scale.nearestAllowedMidi(to: detectedMidi)
            let offset = options.strength * (targetMidi - detectedMidi) * 100
            return NoteSegment(
                startSeconds: run.startSeconds,
                endSeconds: run.endSeconds,
                detectedHz: run.centreHz,
                detectedConfidence: run.medianConfidence,
                pitchOffsetCents: offset,
                driftScale: shapeScale,
                vibratoScale: shapeScale)
        }
        return PitchEditSet(analysisVersion: analysisVersion,
                            segments: segments,
                            retuneMs: options.retuneMs)
    }

    /// Convenience over a whole `clip.detectPitch` response — forwards to the
    /// one policy above with the result's OWN reported frame rate rather than a
    /// hardcoded 62.5, because the wire contract says the rate is a property of
    /// the backend and the backend may change.
    public static func editSet(from result: PitchDetectionResult,
                               options: PitchAutoCorrectOptions,
                               analysisVersion: Int = PitchEditSet.currentAnalysisVersion)
    -> PitchEditSet {
        editSet(contour: result.frames, frameRateHz: result.frameRateHz,
                options: options, analysisVersion: analysisVersion)
    }
}

// MARK: - Shared arithmetic

/// Pitch arithmetic used by this file, in one place so a cents conversion
/// cannot drift between the policy and the curve.
///
/// ⚠️ **A FIRST HOME IN `DAWCore`, NOT A SECOND ONE — CENSUSED BEFORE WRITING.**
/// `Sources/DAWCore` had no Hz↔MIDI or cents helper at all (the only
/// `1200 * log2` in the module is `Effects.swift`'s wow-and-flutter depth
/// conversion, a different quantity). The two Hz→MIDI sites that DO exist —
/// `PitchObservation.midiNote` and `AudioContentAnalyzer` — are both in
/// `DAWEngine`, which `DAWCore` cannot import (`Package.swift`: "DAWCore must
/// NOT reach it"). That is the same module boundary that makes
/// `PitchDetection.swift` a hand-kept twin of `PitchObservation`, and it is
/// why this cannot simply call theirs.
public enum PitchCorrectionMath {
    /// Replace a NaN or an infinity with a stated default. Used at every
    /// boundary this file has: a bad number becomes a known one HERE rather
    /// than becoming a NaN in a transpose curve later.
    @inlinable
    public static func finite(_ value: Double, default fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }

    /// Fractional MIDI note number for a frequency. A4 = 69 = 440 Hz.
    /// Non-positive or non-finite input returns 69 rather than −∞.
    public static func midi(fromHz hz: Double) -> Double {
        guard hz.isFinite, hz > 0 else { return 69 }
        return 69 + 12 * log2(hz / 440)
    }

    /// Frequency for a fractional MIDI note number.
    public static func hz(fromMidi midi: Double) -> Double {
        guard midi.isFinite else { return 440 }
        return 440 * pow(2, (midi - 69) / 12)
    }

    /// Interval in cents from `from` to `to`. 0 when either end is not a real
    /// positive frequency — there is no honest interval from a non-pitch.
    public static func cents(from: Double, to: Double) -> Double {
        guard from.isFinite, to.isFinite, from > 0, to > 0 else { return 0 }
        return 1200 * log2(to / from)
    }

    /// Median of a sample, averaging the two middles on an even count. `nil`
    /// for an empty sample — an absent median, never 0.
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Median of a set of frequencies, taken in the LOG domain and converted
    /// back.
    ///
    /// ⚠️ **LOG DOMAIN ON PRINCIPLE, AND THE TESTS CANNOT TELL — SAID OUT LOUD
    /// BECAUSE MUTATION TESTING PROVED IT.** Pitch is perceived
    /// logarithmically, so the centre of 220 Hz and 440 Hz is 311 Hz, not
    /// 330 Hz, and that is why this is written the way it is. But swapping it
    /// for a plain linear median SURVIVES every test in
    /// `PitchCorrectionTests`, and that is not a hole in the tests — it is
    /// arithmetic: a median over an ODD count is an ELEMENT of the sample, and
    /// `log2` is monotonic, so the two forms pick the SAME frame and agree
    /// EXACTLY. They can only differ on an even count, where each averages the
    /// two middle samples, and the difference is then bounded by the gap
    /// between two ADJACENT detector frames — a fraction of a cent on any
    /// contour this consumes (measured on the suite's own vibrato fixture; see
    /// `logAndLinearMediansAgreeOnDenseContours`).
    ///
    /// So: keep the log form, and do NOT write a test that claims to guard it.
    /// The difference is real in principle and immaterial at this sample
    /// density, and pretending otherwise would put a tautology in the suite.
    public static func medianFrequency(_ values: [Double]) -> Double? {
        let usable = values.filter { $0.isFinite && $0 > 0 }
        guard let logMedian = median(usable.map { log2($0) }) else { return nil }
        return pow(2, logMedian)
    }

    /// Centred moving average over `windowSeconds`, edge-clamped. The drift /
    /// vibrato separator — see `PitchCorrectionCurve.driftWindowSeconds` for
    /// why the window is a pick and when it is exercised at all.
    public static func movingAverage(_ values: [Double],
                                     windowSeconds: Double,
                                     stepSeconds: Double) -> [Double] {
        guard !values.isEmpty else { return [] }
        guard stepSeconds > 0, windowSeconds > 0 else { return values }
        let halfWidth = max(0, Int((windowSeconds / stepSeconds / 2).rounded()))
        guard halfWidth > 0 else { return values }
        var out = [Double](repeating: 0, count: values.count)
        for i in values.indices {
            let low = max(0, i - halfWidth)
            let high = min(values.count - 1, i + halfWidth)
            var sum = 0.0
            for j in low...high { sum += values[j] }
            out[i] = sum / Double(high - low + 1)
        }
        return out
    }
}
