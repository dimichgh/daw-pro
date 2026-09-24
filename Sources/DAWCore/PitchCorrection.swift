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
//    ~~**UI is still absent**~~ **UI LANDED**: the clip menu's *Tune Vocal*
//    and `PitchEditorView` both draw `PitchCorrectionPreset.offeredInUI`
//    (all four since contour-to-render — Hard Tune included).
//  * ~~No store operations.~~ **LANDED** in `ProjectStore+PitchCorrection.swift`,
//    using the `PitchCorrectionUndoKey` coalescing strings below.
//
// ~~STILL GENUINELY ABSENT: the render path passes `contour: []`.~~ **CLOSED
// (contour-to-render, 2026-09-24).** `StretchRenderCache.performRender` now
// fetches-or-detects the WHOLE-FILE contour through ONE seam
// (`PitchContourCache.renderContour`, cached beside the renders, keyed by
// content — design §7.2/§7.3) whenever a set asks for shaping, and builds the
// curve through `PitchRenderContour.curve(editSet:…)`. Measured on the real dry
// vocal through that path: Hard Tune cuts within-note wander 62.8 → 18.2 cents
// (median 70 % per note) where Tight moves it by 1 %. When detection cannot
// run, the render still falls back to the constant per-note offset and names
// the segments in `unresolvedShapingSegmentIDs` — that fallback is now a
// failure path with a visible engine notice, not the product's only behaviour.
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
    ///
    /// ⚠️ ~~AND IT DOES NOT RENDER TODAY.~~ **IT RENDERS (contour-to-render,
    /// 2026-09-24)** — the render resolves it against the detected whole-file
    /// contour (`PitchRenderContour`). It still names itself in
    /// `PitchCorrectionCurve.unresolvedShapingSegmentIDs` when that contour
    /// is unavailable (detection failed, or the set was made by another
    /// detector generation), and the render then keeps only the constant
    /// offset. The GENERATOR below is deliberately independent of it — see
    /// its banner.
    public var vibratoScale: Double

    // ───────────────────────────────────────────────────────────────────────
    // m23-ap Phase 2 / C5a — THE GENERATOR. Read the banner before the fields.
    // ───────────────────────────────────────────────────────────────────────
    //
    // ⛔ **`vibratoScale` ABOVE CANNOT EXPRESS "ADD MORE CYCLES", AND NO
    // AMOUNT OF UI CAN FIX THAT.** It is a MULTIPLIER on the detected contour:
    // multiplying changes how deep an existing wobble is and can never change
    // its RATE, and on a note sung without vibrato it yields nothing however
    // large it gets (`0 × anything = 0`). The reference app's readout moving
    // from `Vibrato 5.5 Hz ±93 c` to `Vibrato 7.8 Hz ±32 c` is SYNTHESIS.
    // Design `docs/design/2026-09-22-pitch-editor-ui.md` §7.5 conflict 2.
    //
    // **THE THREE FIELDS BELOW ARE A GENERATOR, NOT A SCALE**, and the two
    // mechanisms are deliberately separate rather than merged into one number:
    //
    //  * `vibratoScale` is RELATIVE — a fraction of a quantity nobody has
    //    written down (the sung modulation), resolvable only with the detected
    //    contour in hand.
    //  * `vibratoDepthCents` is ABSOLUTE — a number of cents, resolvable with
    //    nothing but itself, which is why it renders through the shipped path
    //    and `vibratoScale` does not.
    //
    // One stored number cannot be both. A UI that wants ONE axis running
    // `sung → flat → synthesised` (which is what the reference frames show, as
    // one continuous edit of one note) maps that axis onto BOTH fields in one
    // atomic edit: the flat half drives `vibratoScale` 1 → 0, and the
    // synthesised half drives `vibratoDepthCents` 0 → N. The natural zero the
    // axis passes through is exactly the point where both are at zero.
    //
    // **THE GENERATOR ADDS; IT DOES NOT REPLACE.** Replacement is
    // `vibratoScale: 0` set in the same edit — see `PitchCorrectionCurve`'s
    // banner for the full argument and for what does and does not render.

    /// Rate of the SYNTHESISED vibrato, Hz. `0` = no generator.
    ///
    /// ⚠️ **THE CEILING IS MEASURED, NOT PICKED** — see
    /// `vibratoRateHzRange`. Above it the renderer's 30 ms hop cannot carry
    /// the shape, and a readout printing the rate would be printing a request
    /// rather than a result.
    public var vibratoRateHz: Double

    /// Peak deviation of the SYNTHESISED vibrato, cents. `0` = INERT: the
    /// generator contributes exactly nothing and the curve is bit-identical to
    /// a curve built before this field existed.
    ///
    /// ⚠️ **A PEAK, NOT A PEAK-TO-PEAK.** `±93 c` in the reference readout is
    /// this number at 93: the contour swings 93 cents above and 93 below the
    /// note's corrected centre, a 186-cent total excursion.
    ///
    /// ⚠️⚠️ **WHAT COMES BACK IS AN OFFSET, NOT A GAIN — AND SAYING IT THE
    /// OTHER WAY ROUND IS HOW THIS TREE'S TWO EXISTING VIBRATO-DEPTH
    /// MEASUREMENTS CAME TO DISAGREE.** Measured through the shipping render
    /// path by `NoteVibratoGeneratorTests` §C, at 5.5 Hz, as the error between
    /// what was asked and what the rendered f0 actually carries:
    ///
    ///     ±16 c → −3.3    ±32 c → +0.4    ±50 c → +7.3
    ///     ±70 c → +6.7    ±93 c → +6.5   ±140 c → −2.4
    ///
    /// The chain adds a roughly DEPTH-INDEPENDENT excess excursion of a few
    /// cents, which grows with RATE (≈+3 at 1 Hz, +7 at 5.5, +10 at 8). Quoted
    /// as a ratio the same data reads 0.80×–1.16×, which invites a
    /// compensation table for a multiplicative error that is not there.
    ///
    /// **This is what reconciles the banner's own 1.06×/1.15×/1.20× with
    /// `PitchCurveRenderTests`' 0.966×/0.969×/1.043×: neither is wrong and
    /// neither is rotted** (the banner's figures were re-run 2026-09-23 and
    /// still reproduce). They are ratios taken at a single depth, ±50 cents,
    /// which is the depth at which this offset is largest relative to the ask.
    ///
    /// ⭐ **THE HONEST BOUND FOR A READOUT: ±7 cents at typical rates.** So a
    /// whole-cent display overstates the resolution — round to the nearest 5.
    /// NO PRE-COMPENSATION IS APPLIED, deliberately: correcting a chain that
    /// is itself several cents out is the closed loop this file's banner
    /// (constraint 2) says will not close.
    public var vibratoDepthCents: Double

    /// How long after the note's START the synthesised vibrato takes to reach
    /// full depth, seconds. `0` = full depth immediately.
    ///
    /// Musically this is the difference between a vibrato and a test tone: a
    /// singer's vibrato builds over the sustain rather than arriving with the
    /// consonant. The fade is the same C¹ `smoothstep` the boundary ramps use,
    /// so the generator never introduces a corner the ramp would then have to
    /// smooth.
    ///
    /// ⚠️ Measured from `startSeconds`, which `PitchEditSet.canonical` can
    /// TRUNCATE (first-wins overlap healing). That is deliberate: the onset is
    /// an ENVELOPE, so a shortened note should re-anchor its fade. The
    /// generator's PHASE deliberately does not — see `PitchCorrectionCurve`.
    public var vibratoOnsetSeconds: Double

    /// Phase 4 — carried so the schema does not change under a saved project
    /// later. **No renderer reads it today.**
    public var formantOffsetSemitones: Double
    /// Per-note timing (m23-ap C2): how far this note's start / end edge has
    /// moved, read as EDITED seconds. The edited start is `startSeconds +
    /// timeStartDeltaSeconds`, and the edited end is `endSeconds +
    /// timeEndDeltaSeconds` (design `2026-09-24-pitch-editor-timing-and-freehand.md`
    /// §3.1). `PitchTimeWarp.make` reads them since C2-1. ⚠️ **The render does
    /// not read them until C2-3.** Until then a retimed set renders untimed,
    /// under a key the digest's time-warp block has already moved.
    ///
    /// Per-note timing has a hard ceiling (`maxCleanStretch = 2`) that the
    /// setter must clamp against (design §3.7). This field is deliberately
    /// NOT clamped to an invented range here, only sanitised against NaN,
    /// because every limit lives in the setter. A hand-written set that
    /// ignores them is healed by `PitchTimeWarp` and reported through its
    /// `healed` flag.
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

    /// **THE CEILING IS AN ENGINE LIMIT, MEASURED, NOT A TASTE DECISION** —
    /// the same kind of number as `PitchEditSet.engineMinimumRetuneMs`, and
    /// arrived at the same way.
    ///
    /// The curve is read ONCE PER ANALYSIS HOP (`css_interval_samples` = 1440
    /// frames = 30 ms at 48 kHz, MEASURED by
    /// `OfflineStretcherCurveTests.hopIsMeasuredNotDerived`). A generated sine
    /// is therefore delivered as a ZERO-ORDER HOLD sampled at 33.33 Hz, whose
    /// Nyquist is **16.67 Hz**. A request above that does not come back
    /// shallow — it comes back as a DIFFERENT, LOWER rate (aliased), which is
    /// the one failure a rate readout could not survive.
    ///
    /// **8 Hz IS THE SHIPPED CEILING AND IT WAS MOVED DOWN FROM 10 BY A
    /// MEASUREMENT, NOT BY TASTE.** Aliasing is not what binds first — the
    /// SHAPE goes before the rate does. Measured through the shipping render
    /// path (`NoteVibratoGeneratorTests` §C), the non-sinusoidal energy the
    /// chain adds to the rendered f0, over the tracker's own ~0.8 cent floor,
    /// as a fraction of the depth requested at ±93 cents:
    ///
    ///     3.0 Hz  3.7 %   ·   4.5 Hz  6.9 %   ·   5.5 Hz 10.1 %
    ///     6.5 Hz 14.5 %   ·   7.8 Hz 23.8 %   ·  10.0 Hz 61.7 %
    ///
    /// At 10 Hz a ±93 cent request comes back with 58 cents of content that is
    /// not the sine that was asked for: a staircase, not a vibrato. Its FITTED
    /// depth still reads 0.98×, which is exactly the trap — the headline
    /// metric looks excellent while the shape is gone. 8 Hz is the last rate
    /// at which a printed number describes what a listener gets.
    ///
    /// It also covers the reference app's own deepest readout (7.8 Hz) and the
    /// whole of human sung vibrato (4–8 Hz), and sits well under the grid's
    /// 16.67 Hz alias limit — which is the OTHER limit, the one that turns a
    /// request into a different and LOWER rate, and is pinned separately.
    public static let vibratoRateHzRange: ClosedRange<Double> = 0...8

    /// 0 (inert) to 200 cents peak — two semitones each way.
    ///
    /// A BOUNDED PICK, not a measurement, and marked as one. It is set from
    /// the reference app's own deepest observed readout (±93 c) with headroom,
    /// so a user cannot ask for something the readout has never been seen to
    /// show. Nothing measured says 200 is where the chain stops being honest;
    /// what IS measured is the delivery ratio, in `NoteVibratoGeneratorTests`.
    public static let vibratoDepthCentsRange: ClosedRange<Double> = 0...200

    /// 0 (immediate) to 5 seconds. Bounded rather than measured; 5 s is longer
    /// than any note this editor segments, so the clamp can never be the
    /// reason a fade fails to complete.
    public static let vibratoOnsetSecondsRange: ClosedRange<Double> = 0...5

    /// True when this segment asks the curve for nothing — a detected note the
    /// user has not edited. Such a segment is still worth persisting (it is the
    /// note table an editor draws), which is why this is NOT the emptiness test
    /// persistence uses.
    ///
    /// ⚠️⚠️ **`vibratoRateHz` AND `vibratoOnsetSeconds` ARE DELIBERATELY NOT
    /// HERE, AND THAT IS THE OPPOSITE OF THE RULE THE PHASE-3/4 FIELDS
    /// FOLLOW.** `formantOffsetSemitones` and the timing deltas break identity
    /// even though nothing reads them, on the stated ground that a field
    /// nobody renders today might render tomorrow and stale audio is worse
    /// than a needless render. Rate and onset are the other case and the
    /// distinction is structural, not a preference:
    ///
    ///  * Those fields are UNREAD, so their render effect is UNKNOWN.
    ///  * Rate and onset are READ, and they enter the curve only as
    ///    `depthSemitones × envelope(t) × sin(…)`. At `vibratoDepthCents == 0`
    ///    that product is exactly zero for every `t`, for every rate and every
    ///    onset. Their inertness is arithmetic, not a guess about the future.
    ///
    /// And the cost of getting it the other way round is NOT symmetric here.
    /// §6.4's rule is that a set which renders as nothing must reach
    /// `OfflineStretcher.isIdentity` and play its source BYTE-FOR-BYTE. A
    /// half-set control (a rate chosen, a depth still at zero — exactly what a
    /// UI holds mid-gesture) that broke identity would push an untouched clip
    /// through a full stretch render, and a ratio-1 stretch is not its own
    /// input. So the conservative direction for THESE two is to stay out.
    /// `NoteVibratoGeneratorTests` pins both halves of this.
    public var isIdentity: Bool {
        pitchOffsetCents == 0 && driftScale == 1 && vibratoScale == 1
            && vibratoDepthCents == 0
            && formantOffsetSemitones == 0
            && timeStartDeltaSeconds == 0 && timeEndDeltaSeconds == 0
            && amplitudeDb == 0
    }

    /// True when ANY per-note edit field departs from its default — "has
    /// anyone touched this note" (m23-ap C-0, design 2026-09-24 §4.4), the
    /// question the pitch editor's accent and the `debug.pitchEditor` spy ask.
    ///
    /// ⚠️ **DELIBERATELY WIDER THAN `!isIdentity`, AND THE DIFFERENCE IS EXACTLY
    /// THE TWO FIELDS THAT DOC EXCLUDES.** A generator rate (or onset) with a
    /// zero depth renders as nothing, which is why identity leaves them out —
    /// but it IS a stored edit, and a spy that called that note untouched would
    /// report a write that took as one that did not. Before this existed the
    /// spy read `pitchOffsetCents != 0` alone, so a Hard-Tuned note that sat
    /// already in tune (offset 0, both scales 0) read as untouched.
    public var isEdited: Bool {
        !isIdentity || vibratoRateHz != 0 || vibratoOnsetSeconds != 0
    }

    /// True when the synthesised generator contributes anything at all.
    /// The ONE predicate for that question — the curve, the digest and any
    /// future readout all read this rather than restating `!= 0`.
    public var hasGeneratedVibrato: Bool { vibratoDepthCents != 0 }

    /// True when either edge of this note has been retimed (m23-ap C2-1,
    /// timing design §3.2).
    ///
    /// ⭐ **THE ONE PREDICATE FOR "IS THIS NOTE RETIMED"**, following the
    /// `hasGeneratedVibrato` rule. The digest's time-warp block,
    /// `PitchTimeWarp.make`, the render's warped branch and the editor all ask
    /// this, and none of them restates it. `-0.0` is no edit, which is how
    /// `isIdentity` already reads it.
    public var hasTimeEdits: Bool { timeStartDeltaSeconds != 0 || timeEndDeltaSeconds != 0 }

    /// True when this segment's rendered curve depends on the DETECTED
    /// CONTOUR — a drift or vibrato scale other than 1, which is a fraction of
    /// a quantity only the contour carries.
    ///
    /// ⭐ **THE ONE PREDICATE FOR "DOES THIS NEED THE CONTOUR".**
    /// `PitchCorrectionCurve.make` uses it to decide what to resolve, and the
    /// render cache uses it (through `PitchEditSet.needsDetectedContour`) to
    /// decide whether the contour enters the render's key. Two spellings of
    /// this test that disagreed would render against a contour the key did not
    /// name — stale audio that looks like a working cache.
    public var wantsContourShaping: Bool { driftScale != 1 || vibratoScale != 1 }

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
        vibratoRateHz: Double = 0,
        vibratoDepthCents: Double = 0,
        vibratoOnsetSeconds: Double = 0,
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
        // A non-finite rate/depth/onset reverts to INERT rather than to some
        // other number: the defaults here are the only values that guarantee
        // the generator contributes exactly nothing, and a damaged project
        // must degrade to silence from this feature, never to a wobble nobody
        // asked for.
        self.vibratoRateHz = PitchCorrectionMath
            .finite(vibratoRateHz, default: 0).clamped(to: Self.vibratoRateHzRange)
        self.vibratoDepthCents = PitchCorrectionMath
            .finite(vibratoDepthCents, default: 0).clamped(to: Self.vibratoDepthCentsRange)
        self.vibratoOnsetSeconds = PitchCorrectionMath
            .finite(vibratoOnsetSeconds, default: 0).clamped(to: Self.vibratoOnsetSecondsRange)
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
        case vibratoRateHz, vibratoDepthCents, vibratoOnsetSeconds
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
            vibratoRateHz: try c.decodeIfPresent(Double.self, forKey: .vibratoRateHz) ?? 0,
            vibratoDepthCents: try c.decodeIfPresent(
                Double.self, forKey: .vibratoDepthCents) ?? 0,
            vibratoOnsetSeconds: try c.decodeIfPresent(
                Double.self, forKey: .vibratoOnsetSeconds) ?? 0,
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
        // Omit-when-default, same rule as every other edit field: a project
        // saved before the generator existed and one saved after it, with the
        // generator untouched, produce the SAME KEYS. That is what makes the
        // byte-identical claim in `NoteVibratoGeneratorTests` §A structural.
        if vibratoRateHz != 0 { try c.encode(vibratoRateHz, forKey: .vibratoRateHz) }
        if vibratoDepthCents != 0 {
            try c.encode(vibratoDepthCents, forKey: .vibratoDepthCents)
        }
        if vibratoOnsetSeconds != 0 {
            try c.encode(vibratoOnsetSeconds, forKey: .vibratoOnsetSeconds)
        }
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

    /// **What the LAST auto-correct pass wrote, as a content stamp** (m23-ap
    /// C-F3) — or nil when no pass wrote this set (a table the note editor
    /// seeded) or the set predates the field (a project saved before
    /// 2026-09-24).
    ///
    /// It exists for ONE question, `hasHandEditsSinceAutoCorrect`: "would
    /// replacing this set throw away work a preset cannot re-create?" Only
    /// `ProjectStore.autoCorrectClipPitch` writes it. Every other writer — a
    /// note drag, a split, every per-note setter still to come — leaves it
    /// alone, so the content moves away from the stamp and the question
    /// answers itself without any setter knowing this field exists. The whole
    /// mechanism is argued in `PitchEditProvenance.swift`.
    ///
    /// ⚠️ **NOT RENDER MATERIAL, AND DELIBERATELY ABSENT FROM
    /// `PitchEditSetDigest.hex`** (the render key, in DAWEngine): two sets
    /// with identical notes render identically whoever wrote them. Omitted
    /// from the payload when nil, so a legacy set re-saves byte-identically.
    public var autoCorrectStamp: String?

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

    /// True when rendering this set needs the DETECTED contour: at least one
    /// segment asks for drift/vibrato shaping (`NoteSegment.wantsContourShaping`,
    /// the one predicate). The preset LADDER never does (it keeps both scales
    /// at 1); `hardTune` always does. A set for which this is false renders —
    /// and keys — exactly as it did before the contour reached the render.
    public var needsDetectedContour: Bool { segments.contains(where: \.wantsContourShaping) }

    /// True when any note is retimed: `NoteSegment.hasTimeEdits`, the one
    /// predicate (m23-ap C2-1). When this is false, `PitchTimeWarp.make`
    /// returns nil, the digest emits no time-warp block, and a render takes
    /// today's linear loop byte for byte. Timing is invisible until it is used.
    public var hasTimeEdits: Bool { segments.contains(where: \.hasTimeEdits) }

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
        case analysisVersion, segments, retuneMs, autoCorrectStamp
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            analysisVersion: try c.decodeIfPresent(Int.self, forKey: .analysisVersion)
                ?? Self.currentAnalysisVersion,
            segments: try c.decodeIfPresent([NoteSegment].self, forKey: .segments) ?? [],
            retuneMs: try c.decodeIfPresent(Double.self, forKey: .retuneMs)
                ?? Self.engineMinimumRetuneMs)
        // Absent (every set saved before C-F3) stays nil, which reads as "may
        // carry hand edits" — the CONFIRM answer, never the silent one.
        self.autoCorrectStamp = try c.decodeIfPresent(String.self, forKey: .autoCorrectStamp)
    }

    /// `retuneMs` is omitted at the floor and `autoCorrectStamp` when nil, the
    /// same omit-when-default rule the rest of the clip payload follows.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(analysisVersion, forKey: .analysisVersion)
        try c.encode(segments, forKey: .segments)
        if retuneMs != Self.engineMinimumRetuneMs { try c.encode(retuneMs, forKey: .retuneMs) }
        if let autoCorrectStamp { try c.encode(autoCorrectStamp, forKey: .autoCorrectStamp) }
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

    /// A vibrato drag on one note.
    ///
    /// ⭐ **ONE KEY FOR BOTH MECHANISMS, DELIBERATELY.** The reference app's
    /// gesture runs one note from sung → flat → synthesised without letting
    /// go, which writes `vibratoScale` on the way down and
    /// `vibratoRateHz`/`vibratoDepthCents` on the way up. A second key for the
    /// generator would split ONE drag into TWO undo entries at the moment the
    /// axis crossed zero — the user would have to undo twice to get back to
    /// where they started, and the halfway state they land in is one they
    /// never saw. The key is the rule, so the rule is stated at the key.
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
///     * `(vibratoScale − 1) × vibrato(t)` — periodic modulation, likewise;
///     * **the SYNTHESISED generator** (m23-ap C5a) —
///       `depth × fade(t) × sin(2π · rate · t)`.
///
/// ⭐ **TWO TIME AXES, ONE RULE (m23-ap C2-1, timing design §3.4 step 4).**
/// On a curve with a `timeWarp`, the generator (its phase AND its fade) runs
/// in EDITED seconds, `W(t)`. The gates and both shaping terms stay in SOURCE
/// seconds. The shaping terms describe the sung audio, and the stretcher moves
/// the sung audio together with the note. The generator is a rate the user
/// chose, so it must keep that rate when the note is stretched. Evaluated in
/// source time, a 5.5 Hz wobble on a note stretched 1.4× would play at about
/// 3.9 Hz. A curve WITHOUT a warp takes no edited-time arithmetic at all.
/// See `semitones(atSourceSecond:editedSecond:)`.
///
/// The two shaping terms are ZERO whenever their scales are 1, which is the
/// entire Phase-1 policy: a preserve-vibrato correction is a CONSTANT per note,
/// so the performance's modulation passes through untouched by construction
/// rather than by a filter that tries to leave it alone.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// ⭐⭐ THE GENERATOR: WHY IT **ADDS** AND DOES NOT **REPLACE**
/// ═══════════════════════════════════════════════════════════════════════════
///
/// This is the load-bearing decision of m23-ap C5a, and it was made on a
/// structural argument rather than a taste one.
///
/// A curve value is a DELTA the renderer transposes the source BY. The source
/// already contains whatever the singer did. So:
///
///  * **ADD** is `+ generated(t)`. It needs nothing but the stored numbers.
///  * **REPLACE** is `− sung(t) + generated(t)`. The `− sung(t)` half requires
///    the DETECTED CONTOUR, because you cannot cancel what you have not
///    measured.
///
/// And the tree already has a mechanism for `− sung(t)`: `vibratoScale = 0`.
/// Making the generator replace would therefore mint a SECOND way to say
/// "remove the sung wobble", with its own failure mode, beside one that is
/// already shipped, already tested and already reports its own unavailability
/// through `unresolvedShapingSegmentIDs`. So:
///
/// ⭐ **REPLACE IS A COMPOSITION, NOT A MODE: `vibratoScale: 0` AND a
/// generator, set in ONE edit.** The reference app's own sequence — one note
/// going sung → flat → synthesised under one continuous gesture — is exactly
/// that composition, and it is why the UI's single axis has a natural zero:
/// zero is where the flatten has finished and the generator has not started.
///
/// ⚠️ ~~AND HALF OF THAT DOES NOT RENDER TODAY.~~ **BOTH HALVES RENDER
/// (contour-to-render, 2026-09-24):** the render resolves `vibratoScale: 0`
/// against the detected whole-file contour, so "replace" now sounds like
/// replace. What survives is the FAILURE path: when the contour is
/// unavailable (detection failed, or the set came from another detector
/// generation) the flatten half resolves to nothing, the segment is named in
/// `unresolvedShapingSegmentIDs`, the engine posts a notice, and a replace
/// gesture sounds like "add" for that render. **A UI that offers replace
/// should read `PitchRenderContour`'s resolution and say so.** It is NOT
/// papered over here by making the generator subtract a contour it does not
/// have.
///
/// **THE PHASE IS ANCHORED AT SOURCE SECOND ZERO — `sin(2π · rate · t)` — NOT
/// AT THE NOTE'S START**, and that choice is defensive:
///
///  * `PitchEditSet.canonical` heals overlaps FIRST-WINS by moving a later
///    segment's `startSeconds` forward. A start-anchored phase would silently
///    re-phase the vibrato of a note the user never touched.
///  * Splitting a note (editor C3) makes two segments from one. Start-anchored,
///    identical generator settings would restart the sine at the split; at
///    source second 0 the two halves stay one continuous vibrato.
///
/// The ENVELOPE (`vibratoOnsetSeconds`) is anchored at the note start instead,
/// because a fade-in is a statement about the note and a shortened note should
/// re-anchor its fade. `generatorIsContinuousAcrossASplit` pins the phase half.
/// On a retimed curve both anchors move onto the edited axis: the phase is
/// `sin(2π · rate · W(t))`, which is anchored at edited second 0 (`W(0) = 0`),
/// and the fade is anchored at `W(startSeconds)`.
///
/// **EXTENSION SEAM (editor C5b, freehand ⌘+drag).** The generator is a TERM
/// IN A SUM, not "the note's shape". A later per-note contour OVERRIDE is
/// another term in the same sum inside the same gate, and adding one does not
/// disturb anything here. What it WOULD need is a rule for override + generator
/// together; that is a UI decision, not a representation one, and nothing in
/// this layout forecloses it.
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

        /// `vibratoDepthCents / 100`. **EXACTLY ZERO means no generator**, and
        /// the evaluator branches on it rather than adding a zero — see the
        /// `-0.0` note in `semitones(atSourceSecond:)`.
        let vibratoDepthSemitones: Double
        /// `2π × vibratoRateHz`, precomputed so the hot loop is one multiply.
        let vibratoRadiansPerSecond: Double
        /// Fade-in length, seconds, from `envelopeStartSeconds`.
        let vibratoOnsetSeconds: Double
        /// The note's start ON THE GENERATOR'S AXIS, which is the ENVELOPE's
        /// anchor. Deliberately NOT the phase's anchor; see the class banner.
        ///
        /// On an untimed curve this is `startSeconds`, the same Double, never
        /// passed through anything. On a retimed curve it is
        /// `W(startSeconds)`, computed once in `make`, because the generator
        /// runs in edited time (C2-1). Precomputing it branches on the
        /// warp's PRESENCE, so an untimed curve's fade is bit-identical to
        /// the pre-C2 fade by construction.
        let envelopeStartSeconds: Double
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
    ///
    /// Since contour-to-render (2026-09-24) the render builds its curve from
    /// `PitchRenderContour`, so this is non-empty in exactly two situations:
    /// the contour is not `.detected` (the render's fallback — the engine also
    /// posts a notice), or it is but carries fewer than two voiced frames
    /// inside a segment (a note the detector did not hear as voiced).
    public let unresolvedShapingSegmentIDs: [UUID]

    /// The per-note timing map this curve was built with, or `nil` for an
    /// untimed curve (m23-ap C2-1, timing design §3.2 "Where W lives at run
    /// time").
    ///
    /// Stored so that the synthesised generator can run in edited time, and so
    /// that this type's `Equatable` compares W too. A display that forgot to
    /// pass W then fails an equality gate against the render on any retimed
    /// set. `nil` is not an identity map: it means "no time edits", and every
    /// evaluation branches on it rather than evaluating an identity W (IEEE
    /// `a + (t − a)·1.0` is not `t` bit for bit).
    public let timeWarp: PitchTimeWarp?

    fileprivate let spans: [Span]

    fileprivate init(clipPitchShiftSemitones: Double,
                     spans: [Span],
                     unresolvedShapingSegmentIDs: [UUID],
                     timeWarp: PitchTimeWarp?) {
        self.clipPitchShiftSemitones = clipPitchShiftSemitones
        self.spans = spans
        self.unresolvedShapingSegmentIDs = unresolvedShapingSegmentIDs
        self.timeWarp = timeWarp
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
    ///     `unresolvedShapingSegmentIDs` afterwards. ⚠️ The RENDER does not
    ///     call this with a contour directly — it calls
    ///     `PitchRenderContour.curve(editSet:clipPitchShiftSemitones:)`, which
    ///     supplies the contour AND the offset below together.
    ///   - contourValueOffsetSeconds: where, relative to each frame's
    ///     `timeSeconds`, that frame's pitch belongs. `0` (the default) treats
    ///     a frame as a point sample at its timestamp, which is what every
    ///     synthetic model contour in the tests is. A DETECTOR frame is not: its
    ///     `timeSeconds` is the frame START and its value describes the
    ///     interval `[t, t + 1/frameRate)`, so `PitchRenderContour` passes half
    ///     a frame. **MEASURED, not assumed:** SwiftF0's contour of a known
    ///     5.5 Hz vibrato LEADS the sung pitch by 8.58 ms (half a frame is
    ///     8.0), and on the real dry vocal Hard Tune's residual wander is
    ///     24.2 c at +0 ms, 18.2 c at +8, 17.7 c at +12, 20.0 c at +16, 25.2 c
    ///     at +24 — the centre of the frame sits on the minimum. Only the TIME
    ///     AXIS of the shaping moves; which frames belong to a segment is still
    ///     decided on `timeSeconds`, the same frame-start convention
    ///     `PitchNoteSplitter` (over `PitchAutoCorrect.voicedRuns`) builds
    ///     segment boundaries in.
    ///   - clipPitchShiftSemitones: `Clip.pitchShiftSemitones`, which this
    ///     curve SUBSUMES.
    ///   - timeWarp: the set's per-note timing map, built by the caller with
    ///     `PitchTimeWarp.make(editSet:sourceDurationSeconds:)` from THIS
    ///     `editSet`, or `nil` (the default) for an untimed curve. Every
    ///     caller that passes nothing gets exactly the pre-C2 curve, because
    ///     `nil` takes no edited-time arithmetic anywhere. ⚠️ A retimed set
    ///     built WITHOUT its warp plays its synthesised wobble in source time,
    ///     which is at the wrong rate on a stretched note.
    public static func make(editSet: PitchEditSet,
                            contour: [ClipPitchFrame] = [],
                            contourValueOffsetSeconds: Double = 0,
                            clipPitchShiftSemitones: Double = 0,
                            timeWarp: PitchTimeWarp? = nil) -> PitchCorrectionCurve {
        let base = PitchCorrectionMath.finite(clipPitchShiftSemitones, default: 0)
        guard !editSet.segments.isEmpty else {
            return PitchCorrectionCurve(clipPitchShiftSemitones: base,
                                        spans: [], unresolvedShapingSegmentIDs: [],
                                        timeWarp: timeWarp)
        }
        let ramp = editSet.retuneMs / 1000
        let valueOffset = PitchCorrectionMath.finite(contourValueOffsetSeconds, default: 0)
        // Voiced frames only, ascending. An unvoiced frame carries no pitch and
        // is not turned into one — it simply is not here.
        let voiced = contour
            .filter { $0.frequencyHz != nil }
            .sorted { $0.timeSeconds < $1.timeSeconds }

        var spans: [Span] = []
        var unresolved: [UUID] = []
        spans.reserveCapacity(editSet.segments.count)

        for segment in editSet.segments {
            let wantsShaping = segment.wantsContourShaping
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
                        // `+ valueOffset` is the ONLY place the offset
                        // enters: at the default 0 this line is exactly the
                        // one every pre-offset curve was built with.
                        shapingStart = frames[0].timeSeconds + valueOffset
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
                shapingStepSeconds: shapingStep,
                // ⚠️ `hasGeneratedVibrato` is the ONE predicate; a literal
                // `!= 0` here would be the second home. A segment with a rate
                // but no depth collapses to EXACTLY 0.0 rather than to a very
                // small number, which is what lets the evaluator skip the
                // whole term rather than add a zero to it.
                vibratoDepthSemitones: segment.hasGeneratedVibrato
                    ? segment.vibratoDepthCents / 100 : 0,
                vibratoRadiansPerSecond: 2 * .pi * segment.vibratoRateHz,
                vibratoOnsetSeconds: segment.vibratoOnsetSeconds,
                // Branch on the warp's PRESENCE: an untimed curve stores the
                // same Double it always did, never an identity W's output.
                envelopeStartSeconds: timeWarp?.editedSecond(
                    forSourceSecond: segment.startSeconds) ?? segment.startSeconds))
        }
        return PitchCorrectionCurve(clipPitchShiftSemitones: base,
                                    spans: spans,
                                    unresolvedShapingSegmentIDs: unresolved,
                                    timeWarp: timeWarp)
    }

    /// Absolute pitch, in semitones, that the renderer should be transposing by
    /// at source-file second `sourceSecond`.
    ///
    /// Pure and total. A non-finite input returns the whole-clip term rather
    /// than propagating a NaN, and a result that somehow came out non-finite
    /// does the same — this value ends up driving a transpose curve, and a NaN
    /// there is an audible catastrophe, not a log line.
    ///
    /// On a retimed curve this computes the edited second itself,
    /// `timeWarp.editedSecond(forSourceSecond:)`. On an untimed curve it passes
    /// `nil` through optional chaining, so no W is ever evaluated.
    public func semitones(atSourceSecond sourceSecond: Double) -> Double {
        semitones(atSourceSecond: sourceSecond,
                  editedSecond: timeWarp?.editedSecond(forSourceSecond: sourceSecond))
    }

    /// The evaluator, for a caller that already holds both seconds (m23-ap
    /// C2-1, timing design §3.4 step 4).
    ///
    /// The render starts from an EDITED second (the delivered output frame
    /// divided by `ratio · sampleRate`), maps it to source through
    /// `timeWarp.sourceSecond(forEditedSecond:)`, and passes both. That avoids
    /// a W(W⁻¹(e)) round trip that would not return `e` bit for bit.
    ///
    /// - Parameter editedSecond: the edited second that `sourceSecond` plays
    ///   at: `timeWarp.editedSecond(forSourceSecond: sourceSecond)`. Pass
    ///   `nil` exactly when the curve has no `timeWarp`. The synthesised
    ///   generator runs on `editedSecond ?? sourceSecond`, and the gates and
    ///   shaping terms run on `sourceSecond`. A non-finite `editedSecond` is
    ///   treated like a non-finite `sourceSecond`: the whole-clip term.
    public func semitones(atSourceSecond sourceSecond: Double,
                          editedSecond: Double?) -> Double {
        guard sourceSecond.isFinite else { return clipPitchShiftSemitones }
        guard !spans.isEmpty else { return clipPitchShiftSemitones }
        if let editedSecond, !editedSecond.isFinite { return clipPitchShiftSemitones }
        // ⭐ BRANCH ON PRESENCE, never evaluate an identity W: with no warp the
        // generator reads `sourceSecond` itself, exactly as it did before C2.
        let generatorSecond = editedSecond ?? sourceSecond

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
                // ⚠️ **THE BRANCH IS DEFENSIVE, NOT LOAD-BEARING — AND THAT IS
                // A MEASUREMENT, NOT A GUESS.** The reasoning that put it here
                // was: `x + 0.0` is `x` for every finite `x` EXCEPT `-0.0`,
                // where it is `+0.0`, so adding an always-zero term could flip
                // a bit pattern on its way to `Float(…)` and
                // `css_set_transpose_semitones`.
                //
                // That hazard is REAL in general and UNREACHABLE here, and it
                // was checked rather than argued: removing this branch and
                // adding the term unconditionally was planted as a defect and
                // the §A render/digest goldens **passed**. The reason is the
                // line directly above — `span.constantSemitones + shaping(…)`
                // already adds `shaping`'s positive-zero literal, and IEEE
                // round-to-nearest gives `-0.0 + 0.0 == +0.0`, so
                // `contribution` is never `-0.0` by the time the generator
                // could touch it.
                //
                // The branch stays because it is free, it skips a call per
                // span per hop, and it keeps the invariance structural if
                // `shaping` ever learns to return a signed zero. It is NOT
                // what the byte gates are standing on, and saying otherwise
                // would be a protection nobody has ever seen fire.
                //
                // C2-1: the gate and the shaping stay in SOURCE time, and the
                // generator runs on `generatorSecond` (EDITED time on a
                // retimed curve). See the type banner, "two time axes".
                var contribution = span.constantSemitones
                    + Self.shaping(span, at: sourceSecond)
                if span.vibratoDepthSemitones != 0 {
                    contribution += Self.generatedVibrato(span, at: generatorSecond)
                }
                weighted += gate * contribution
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

    /// The SYNTHESISED vibrato term, semitones, before the boundary gate.
    ///
    /// `depth × fade(t) × sin(2π · rate · t)`, with the phase anchored at
    /// SOURCE SECOND ZERO and the fade anchored at the NOTE'S START — see the
    /// type's banner for why those two anchors differ on purpose.
    ///
    /// `t` is on the GENERATOR'S axis: source seconds on an untimed curve,
    /// EDITED seconds on a retimed one (C2-1), and `span.envelopeStartSeconds`
    /// is already on the same axis. The phase stays anchored at axis zero,
    /// which is source zero because `W(0) = 0`.
    ///
    /// Total and inert-by-construction: a zero depth or a zero rate returns
    /// exactly `0`, and a non-finite `t` cannot reach here (the evaluator
    /// rejects it first). The caller does NOT call this when the depth is
    /// zero, so the guard below is a second line of defence rather than the
    /// mechanism the byte gates rely on.
    fileprivate static func generatedVibrato(_ span: Span, at t: Double) -> Double {
        let depth = span.vibratoDepthSemitones
        guard depth != 0, span.vibratoRadiansPerSecond != 0 else { return 0 }
        // The same C¹ smoothstep the boundary ramps use, so a fade-in never
        // introduces a corner the ramp would then have to smooth. `<= 0`
        // rather than `== 0` because a decoded onset is clamped, never
        // trusted.
        let fade: Double
        if span.vibratoOnsetSeconds <= 0 {
            fade = 1
        } else {
            fade = smoothstep((t - span.envelopeStartSeconds) / span.vibratoOnsetSeconds)
        }
        // SLOT (C5a-1, vibrato-handle design §7.1 and §7.6): the stored phase
        // anchor lands here as `sin(ω · (t − anchorOnThisAxis))`, where the
        // anchor is precomputed in `make` as `W(vibratoPhaseAnchorSeconds)` on
        // a retimed curve and as the stored value verbatim otherwise, exactly
        // like `envelopeStartSeconds`.
        return depth * fade * sin(span.vibratoRadiansPerSecond * t)
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

// MARK: - The contour a render shapes against

/// ⭐ **THE CONTOUR THE RENDER USES FOR A CLIP — and the ONE place a curve is
/// built from it.**
///
/// Produced by exactly one function, the engine's
/// `PitchContourCache.renderContour(source:analysisVersion:…)` (reached from
/// outside the engine through `AudioEngineControlling.renderPitchContour`).
/// `StretchRenderCache.performRender` calls that function and then
/// `curve(editSet:clipPitchShiftSemitones:)` below; a display that wants its
/// picture to agree with the sound calls the SAME two things, so there is no
/// second contour and no second way to turn one into a curve.
///
/// **What `.detected` carries** (design §7.3 — the contour is regenerable
/// analysis, cached beside the renders, never persisted in `.dawproj`):
///  * the WHOLE source file, analysed from source second 0 — never the clip's
///    trim window — so it is a pure function of the file and does not move
///    when the clip is trimmed or split;
///  * `ClipPitchFrame.timeSeconds` in SOURCE-FILE-ABSOLUTE seconds, never
///    rebased to the clip;
///  * this build's detector at the product's own detection settings
///    (`PitchDetectionDefaults`), which are what `clip.autoCorrectPitch`
///    segments with.
///
/// It is an ENUM so "a contour" and "a reason there is none" cannot both be
/// present: every non-`detected` case renders the constant per-note offsets
/// only and leaves the shaping segments in `unresolvedShapingSegmentIDs`.
public enum PitchRenderContour: Sendable, Equatable {
    /// The whole-file detection, fresh or from the cache.
    case detected(PitchDetectionResult)
    /// The edit set was built by a different detector generation than this
    /// build runs. Design §7.2: a contour/version mismatch must be a visible
    /// re-detection notice, NEVER a silent substitution of this build's
    /// contour under edits made against another's — so nothing is resolved.
    case analysisVersionMismatch(editSet: Int, detector: Int)
    /// Detection could not run or failed (missing model, unreadable file,
    /// runtime error). The render falls back to the constant offsets.
    case unavailable(reason: String)

    /// The detection, or `nil` when there is none to shape against.
    public var detection: PitchDetectionResult? {
        if case .detected(let result) = self { return result }
        return nil
    }

    /// The frames the render shapes against — `[]` for every case but
    /// `.detected`, which is exactly the contour the render used before this
    /// type existed.
    public var frames: [ClipPitchFrame] { detection?.frames ?? [] }

    /// Where a detector frame's value belongs relative to its `timeSeconds`:
    /// the CENTRE of the frame, half a frame period. See
    /// `PitchCorrectionCurve.make`'s `contourValueOffsetSeconds` for the
    /// measurement that put it there. `0` whenever there is no detection.
    public var frameValueOffsetSeconds: Double {
        guard let rate = detection?.frameRateHz, rate.isFinite, rate > 0 else { return 0 }
        return 0.5 / rate
    }

    /// **THE VERSION OF THE CONTOUR-SHAPING ARITHMETIC** — bump it whenever a
    /// curve built by `curve(editSet:…)` from an UNCHANGED edit set and an
    /// UNCHANGED contour would come out different: the drift/vibrato separator
    /// (`PitchCorrectionCurve.driftWindowSeconds` and the moving average
    /// behind it), `frameValueOffsetSeconds`, or the shaping expression in
    /// `PitchCorrectionCurve.make`.
    ///
    /// It sits in every CONTOUR-SHAPED render's cache key and in no other
    /// (`StretchRenderCache.renderKeys`), so a bump re-renders exactly the
    /// renders whose audio it changes. Neither the edit-set digest nor the
    /// contour's key can see these choices — they are code, not data — so
    /// without this a better separator would ship and every cached render
    /// shaped by the old one would keep playing as if it were current.
    /// (`StretchRenderCache.stretchEngineVersion` would also re-key them, but
    /// it re-renders EVERY stretched clip on every disk, including all the
    /// contour-free ones this cannot affect.)
    ///
    /// ⚠️ The separator IS the likeliest thing to change: on a 5.5 Hz vibrato
    /// the 250 ms window passes 121 % of the wobble into "vibrato", so
    /// `vibratoScale: 0` on its own over-corrects wherever the detector reads
    /// the depth fully (measured 2026-09-24: 34 % wander cut at B3, where
    /// SwiftF0 reads 97 % of the depth, against 56 % at A3, where it reads
    /// 80 %; Hard Tune — drift AND vibrato at 0, which cancels the split —
    /// cuts 48–58 % at both, through the product render). Most of what is
    /// left in every case is the renderer, not the arithmetic: the same
    /// curves evaluated WITHOUT the stretcher leave 2.6–8.2 cents.
    /// `ContourShapingSweepTests` (DAWEngineTests, env-gated) re-derives all
    /// of these.
    public static let shapingVersion = 1

    /// **THE curve a render of `editSet` plays.** `StretchCurvePlan` builds its
    /// curve through this and nothing else; a display must too.
    ///
    /// `timeWarp` (m23-ap C2-1) is `PitchTimeWarp.make(editSet:
    /// sourceDurationSeconds:)` for THIS `editSet`, or `nil` for an untimed
    /// set. Passing nothing is exactly the pre-C2 call.
    public func curve(editSet: PitchEditSet,
                      clipPitchShiftSemitones: Double,
                      timeWarp: PitchTimeWarp? = nil) -> PitchCorrectionCurve {
        PitchCorrectionCurve.make(editSet: editSet, contour: frames,
                                  contourValueOffsetSeconds: frameValueOffsetSeconds,
                                  clipPitchShiftSemitones: clipPitchShiftSemitones,
                                  timeWarp: timeWarp)
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

/// One run of consecutive VOICED frames — a stretch the singer never stopped in.
///
/// ⭐ **THIS IS THE RUN RULE, NOT THE NOTE RULE** (p2-seg, design
/// `docs/design/2026-09-24-pitch-note-splitting.md` §0). A run is a maximal
/// stretch of voiced frames; a hole, or a gap in the analysis, ends it. A run
/// can hold several NOTES — a legato phrase where the singer changes note
/// without stopping is ONE run, and `voicedRuns` on it returns ONE element on
/// purpose (`legatoSlurSplitsAtTheNoteChange` pins that too).
///
/// Notes are found INSIDE runs by `PitchNoteSplitter.parts(in:frameRateHz:onsetSeconds:)`,
/// and the two note-table builders (`PitchAutoCorrect.editSet`,
/// `PitchNoteTable.detected`) read those parts, never runs. What stays on runs,
/// deliberately: the editor's measured contour and the played line, which are
/// drawn per RUN so a note boundary never draws a hole where the singer never
/// stopped (`PitchPlayedLine`, `PitchEditorModel.contourRuns`). A run that has
/// no note change inside it comes out of the splitter as exactly this value,
/// field for field (design §2.4).
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

/// What a flattening pass (`preserveVibrato: false` — Hard Tune) does to a
/// `.transition` part: a slide into, between or out of held notes (p2-seg,
/// design `docs/design/2026-09-24-pitch-note-splitting.md` §3.2).
///
/// ONE AXIS, and the user's to pick (§9 Q1). Every shape writes the SAME note
/// table — one segment per part, each with its own part's median as
/// `detectedHz` — and sets only the correction values (offset, drift and
/// vibrato scales), so the notes the editor draws never depend on the pick.
/// The preserve-vibrato presets ignore the shape (a transition is identity for
/// them in every shape, §3.4). THE product's shape is the one constant
/// `PitchAutoCorrect.slideShape`.
///
/// (b) "Robot staircase" is deliberately NOT a case: shipping it needs engine
/// and model work (S6), and its listening prototype produced no audible steps
/// (§15.1).
public enum PitchSlideShape: String, Sendable, Equatable, CaseIterable {
    /// **(c) "Today's sound"** — every part of a split run, held and transition
    /// alike, is locked to the nearest note of the WHOLE run's median and
    /// flattened: the pre-p2-seg pin, played on the split table. ⚠️ It is not
    /// byte-identical to a pre-p2-seg render of a split run: each segment's
    /// shaping is held at its own edge and crossfaded with its neighbour where
    /// one segment used to interpolate straight through.
    case runPin
    /// **(d) "Straight to the note"** — a transition keeps its own `detectedHz`
    /// but aims at the note of the held part it leads INTO (a tail-off: the one
    /// it leaves; §12 item 2), flattened, so the voice starts on the locked note.
    case straightToNote
    /// **(a-T) "Slide kept, note locked"** — a transition is an IDENTITY
    /// segment: the singer's own slide plays as sung, then the held note snaps
    /// on through the retune crossfade. The Melodyne-style two-part shape.
    case slideKeptNoteLocked
    /// **(a-N) "In-between note"** — a transition is locked, like a held note,
    /// to the nearest note of its OWN median: two stepped pitches.
    case inBetweenNote
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

    /// Split a contour into voiced RUNS — the run rule (see `VoicedRun`). Notes
    /// inside a run are `PitchNoteSplitter`'s job, which calls this first and
    /// never re-derives a run edge.
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

    /// ⭐ **THE SLIDE-SHAPE POLICY — ONE CONSTANT** (p2-seg, design §3, §4.4).
    /// What a `preserveVibrato: false` pass (Hard Tune) does to a `.transition`
    /// part; see `PitchSlideShape` for each shape and `editSet` for the table.
    ///
    /// ⭐ **THE USER'S PICK (2026-09-24): (a-T) "Slide kept, note locked"** —
    /// chosen from renders of their own take on the handoff page, among (c),
    /// (d), (a-T) and (a-N) (design §9 Q1, §15.1). It was also the design's
    /// recommendation. The other three stay as cases, each with its test, so a
    /// later change of mind is this one line plus a gate re-run. It is
    /// deliberately NOT a `PitchAutoCorrectOptions` field or a wire key: the
    /// options are Codable and echoed as `appliedOptions`, and one shape is the
    /// product's answer, not a per-call knob (§4.4 — more than one would each
    /// become a named, additive, optional key with an MCP field and a test).
    /// ⚠️ **The MCP `clip_auto_correct_pitch` description states this default**
    /// (`mcp-server/src/server.ts`: every preset stores a slide AS SUNG). That
    /// holds only while this is (a-T) — preserve-vibrato presets are identity in
    /// every shape, Hard Tune only under (a-T) — so changing this line changes
    /// that text too. (a-N) also turns an over-split wobble edge into a locked
    /// note: 6 of 29 ±80 c edges would lock to a different semitone
    /// (`PitchWobbleDetectorTests`, measured 2026-09-24).
    public static let slideShape: PitchSlideShape = .slideKeptNoteLocked

    /// **THE POLICY.** Detected contour + options ⇒ a populated `PitchEditSet`.
    ///
    /// `strength == 0` returns `PitchEditSet.empty` — no segments, no offsets,
    /// and a curve that is bit-for-bit the clip's own constant shift. That is
    /// the structural identity the whole feature must collapse to, so it is a
    /// short-circuit and not an arithmetic coincidence.
    ///
    /// ⭐ **ONE SEGMENT PER NOTE PART** (p2-seg). The notes are
    /// `PitchNoteSplitter.parts` — the same call `PitchNoteTable.detected` makes,
    /// so this writes exactly the notes the editor draws, for every preset and
    /// every slide shape (design §4.5). Each segment keeps its OWN part's median
    /// as `detectedHz` (what was sung — the editor stays honest); the preset and
    /// the shape set only the correction values:
    ///
    ///     options                  .held part                  .transition part
    ///     preserveVibrato: true    its own nearest note,       IDENTITY, in every
    ///       (Gentle/Natural/Tight) one constant (§3.4)         shape (§3.4)
    ///     false, (c) .runPin       the WHOLE run's note        the WHOLE run's note
    ///     false, (d) .straightTo…  its own note                its destination's note
    ///     false, (a-T) .slideKept… its own note                IDENTITY (as sung)
    ///     false, (a-N) .inBetween… its own note                its own nearest note
    ///
    /// "Note" is `options.scale.nearestAllowedMidi` of the named median, reached
    /// with `strength` and flattened with `1 − strength` — today's arithmetic, for
    /// one part. A run with no note change is ONE `.held` part equal to its
    /// `VoicedRun`, and every row maps it to exactly the segment this function
    /// wrote before p2-seg (design §2.4; `PitchNoteSplitterTests` checks it field
    /// by field against a frozen copy of that function).
    ///
    /// - Parameter slideShape: THE policy constant `slideShape` by default; every
    ///   production caller leaves it there. A test passes each case.
    public static func editSet(contour frames: [ClipPitchFrame],
                               frameRateHz: Double,
                               options: PitchAutoCorrectOptions,
                               analysisVersion: Int = PitchEditSet.currentAnalysisVersion,
                               slideShape: PitchSlideShape = PitchAutoCorrect.slideShape)
    -> PitchEditSet {
        guard options.strength > 0 else { return .empty }
        // f0 alone decides where notes are: onset placement (S3) is not scheduled
        // (design §12 item 3), so no onsets are passed.
        let parts = PitchNoteSplitter.parts(in: frames, frameRateHz: frameRateHz,
                                            onsetSeconds: [])
        guard !parts.isEmpty else {
            return PitchEditSet(analysisVersion: analysisVersion,
                                segments: [], retuneMs: options.retuneMs)
        }
        // Flattening IS correction, so it scales with strength: at strength 0
        // both branches are the identity, and at strength 1 the robot branch
        // replaces the contour outright.
        let shapeScale = options.preserveVibrato ? 1 : (1 - options.strength)

        let segments = parts.indices.map { index -> NoteSegment in
            segment(forPart: index, of: parts, options: options,
                    shapeScale: shapeScale, slideShape: slideShape)
        }
        return PitchEditSet(analysisVersion: analysisVersion,
                            segments: segments,
                            retuneMs: options.retuneMs)
    }

    /// One part's segment: the table on `editSet`, and nothing else.
    private static func segment(forPart index: Int, of parts: [NotePart],
                                options: PitchAutoCorrectOptions, shapeScale: Double,
                                slideShape: PitchSlideShape) -> NoteSegment {
        let part = parts[index]
        // Today's per-note arithmetic, for ONE part, aimed at the nearest allowed
        // note to `aimHz`. Aimed at the part's own median it is, expression for
        // expression, what this function computed per run before p2-seg.
        func locked(aimingAt aimHz: Double) -> NoteSegment {
            let detectedMidi = PitchCorrectionMath.midi(fromHz: part.centreHz)
            let targetMidi = options.scale.nearestAllowedMidi(
                to: PitchCorrectionMath.midi(fromHz: aimHz))
            let offset = options.strength * (targetMidi - detectedMidi) * 100
            return NoteSegment(
                startSeconds: part.startSeconds,
                endSeconds: part.endSeconds,
                detectedHz: part.centreHz,
                detectedConfidence: part.medianConfidence,
                pitchOffsetCents: offset,
                driftScale: shapeScale,
                vibratoScale: shapeScale)
        }
        // IDENTITY: the note as sung — offset 0, both scales 1. A real, editable
        // note rather than a gap: a gap would sound the same (the curve is
        // identity where nothing covers a time) but would leave a voiced stretch
        // with no note drawn over it, which the editor has never drawn and the
        // user could not grab (design §3.2 (a-T)).
        func asSung() -> NoteSegment {
            NoteSegment(startSeconds: part.startSeconds, endSeconds: part.endSeconds,
                        detectedHz: part.centreHz, detectedConfidence: part.medianConfidence)
        }
        switch part.kind {
        case .held:
            return locked(aimingAt: !options.preserveVibrato && slideShape == .runPin
                          ? part.runCentreHz : part.centreHz)
        case .transition:
            // §3.4: a slide has no centre to move; moving it by one constant would
            // shift the whole sweep by an arbitrary amount. Identity in EVERY shape.
            guard !options.preserveVibrato else { return asSung() }
            switch slideShape {
            case .runPin:
                return locked(aimingAt: part.runCentreHz)
            case .straightToNote:
                return locked(aimingAt: destination(ofTransition: index, in: parts).centreHz)
            case .slideKeptNoteLocked:
                return asSung()
            case .inBetweenNote:
                return locked(aimingAt: part.centreHz)
            }
        }
    }

    /// The held part a transition takes its target from under (d), design §12
    /// item 2: a lead-in or a link takes the held note it leads INTO; a tail-off
    /// takes the held note it leaves. Structurally a transition always has a held
    /// part in its own run; the last line is a total fallback (its own median,
    /// i.e. (a-N)), never a neighbouring run's note.
    static func destination(ofTransition index: Int, in parts: [NotePart]) -> NotePart {
        let run = parts[index].runIndex
        var j = index + 1
        while j < parts.count, parts[j].runIndex == run {
            if parts[j].kind == .held { return parts[j] }
            j += 1
        }
        j = index - 1
        while j >= 0, parts[j].runIndex == run {
            if parts[j].kind == .held { return parts[j] }
            j -= 1
        }
        return parts[index]
    }

    /// Convenience over a whole `clip.detectPitch` response — forwards to the
    /// one policy above with the result's OWN reported frame rate rather than a
    /// hardcoded 62.5, because the wire contract says the rate is a property of
    /// the backend and the backend may change.
    public static func editSet(from result: PitchDetectionResult,
                               options: PitchAutoCorrectOptions,
                               analysisVersion: Int = PitchEditSet.currentAnalysisVersion,
                               slideShape: PitchSlideShape = PitchAutoCorrect.slideShape)
    -> PitchEditSet {
        editSet(contour: result.frames, frameRateHz: result.frameRateHz,
                options: options, analysisVersion: analysisVersion, slideShape: slideShape)
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
    /// **THE DETECTOR'S RESOLUTION FLOOR, cents — ITS ONE HOME** (design
    /// `2026-09-24-pitch-editor-vibrato-handle.md` §8.3): half of one
    /// 25.79-cent SwiftF0 output bin, this file's header constraint 1. Nothing
    /// finer than this may be claimed about a detected pitch.
    ///
    /// ⚠️ It bounds a SINGLE VALUE's quantisation error, not a fitted sine's:
    /// a wobble toggling between two adjacent outputs has a fundamental of
    /// up to 4/π × 12.90 = 16.4 cents whatever its true depth — see the
    /// `PitchWobbleEstimate` banner. So it is NOT the floor for calling
    /// something a wobble: that is `PitchWobbleEstimate.reportFloorCents`
    /// (20 c, design §18.1.4). `PitchEditorReadout.centsResolutionFloor`
    /// (DAWAppKit) aliases this, so no readout can disagree with it about what
    /// the detector resolves. (§18.1.7 names C5a-F6: this half-bin figure was
    /// derived from a lattice model the product is not; re-derive it from
    /// product data.)
    public static let detectorResolutionFloorCents: Double = 12.90

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
