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
//  2. **THE TRANSPOSER WAS SHARP; SINCE p2-acc-3 (2026-09-25) IT LANDS WITHIN
//     0.01 c.** Phase-0 §7 measured +5.45 c at +2 st, +3.95 at −2 st: three
//     defects in the vendored stretcher (a fractional-bin phase read, a biased
//     peak position, a reused previous hop), fixed by three local patches
//     (`Sources/CSignalsmithStretch/VENDORED.md`, 0001-0003). Measured: steady
//     partials within 0.01 c across ±24 st, harmonic tones to ±12 st and +24 st.
//     Item 1 still sets the tolerance: a ±5 c loop does not close through a
//     25.79 c-per-bin detector, however exact the transposer is.
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
// vocal through that path, Hard Tune flattens each held note onto its own note
// while Tight leaves the wobble as sung (the figures live in ONE home,
// `PitchCorrectionPreset.offeredInUI`'s doc). When detection cannot
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
    // **THE FOUR FIELDS BELOW (rate, depth, onset and, since C5a-1, the phase
    // anchor) ARE A GENERATOR, NOT A SCALE**, and the two
    // mechanisms are deliberately separate rather than merged into one number:
    //
    //  * `vibratoScale` is RELATIVE — a fraction of a quantity nobody has
    //    written down (the sung modulation), resolvable only with the detected
    //    contour in hand.
    //  * `vibratoDepthCents` is ABSOLUTE — a number of cents, resolvable with
    //    nothing but itself, which is why it renders through the shipped path
    //    and `vibratoScale` does not.
    //
    // One stored number cannot be both. ⚠️ Corrected at C5a-2 (vibrato-handle
    // design §5.3 D5 and §5.6): this paragraph used to say a UI running ONE
    // axis `sung → flat → synthesised` drives `vibratoScale` 1 → 0 on its flat
    // half. Both halves of that were wrong. `vibratoScale 0` ALONE is not flat:
    // it keeps the slow drift, and with the 250 ms boxcar separator it also kept
    // an INVERTED 17–22 % of a 4.5–6 Hz wobble (V3). Since natural tuning §3
    // (W7-C3) an unequal-scale note takes the non-inverting v2 separator
    // (`PitchCorrectionCurve.Separator`), so the inversion is gone, but flat is
    // still BOTH scales at 0, where the drift/vibrato split cancels and the note
    // sits on its centre (Hard Tune's composition).
    // And the Wobble tool is not one continuous range: narrowing the singer's
    // wobble and adding a new one are two branches, chosen at mouse-down
    // (§5.1), joined only by the one-way handoff (§6). The two mechanisms stay
    // separate fields either way; `ProjectStore.setClipNoteVibrato` writes any
    // of them in one atomic edit.
    //
    // **THE GENERATOR ADDS; IT DOES NOT REPLACE.** Replacement is
    // `vibratoScale: 0` AND `driftScale: 0` set in the same edit as the
    // generator (the handoff's write) — see `PitchCorrectionCurve`'s banner for
    // the full argument and for what does and does not render.

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

    /// Where the SYNTHESISED wobble's phase is anchored, source seconds
    /// (m23-ap C5a-1, vibrato-handle design §7): the generator is
    /// `depth × fade(t) × sin(2π · rate · (t − vibratoPhaseAnchorSeconds))`,
    /// so the wobble crosses zero, rising, at the anchor.
    ///
    /// `0` (the default) is exactly the phase every set had before this field
    /// existed, anchored at source second zero, bit for bit (`t − 0.0 == t`).
    /// **STORED, NOT DERIVED FROM `startSeconds`**, so `PitchEditSet.canonical`
    /// truncation cannot re-phase it and a split copies it to both halves (the
    /// two guarantees the curve banner's source-zero phase existed for). The
    /// wobble editor puts it at the note's centre, so a speed change stretches
    /// the cycles around the knob instead of jumping them (design V6). Under
    /// per-note timing the phase is anchored at `W(anchor)` on the edited axis.
    ///
    /// Inert at `vibratoDepthCents == 0`, like rate and onset, so it is in
    /// `isEdited` but NOT in `isIdentity` (see there). Codable key
    /// `vibratoPhaseAnchorSeconds`, written only when non-zero. The digest
    /// hashes it in its own block, slot 2 (`PitchEditSetDigest.hex`).
    public var vibratoPhaseAnchorSeconds: Double

    /// The Voice tool's per-note value (natural tuning §1(b)): semitones of
    /// formant shift ON TOP of what the set's `formantCorrection` leaves,
    /// relative to the source envelope. Negative = deeper, positive =
    /// brighter; the pitch does not move. `PitchCorrectionCurve`'s
    /// `formantSemitones` reads it (NT-C C1) and `engagesFormantCurve` says
    /// when it counts; ⚠️ the RENDER reads it only once NT-E1's formant
    /// closures land. Writer: `ProjectStore.setClipNoteFormant`.
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
    /// The note's own LEVEL, dB (I7a merged with U-C, interaction-batch design
    /// §17). Shares `Clip.gainDbRange` rather than minting a second gain range,
    /// and means what a clip's gain means: −72 dB is a very quiet level
    /// (2.5e-4), never silence — silence is `isCleared`. The offline render
    /// reads it through `PitchEditSet.gain(atSourceSecond:)`, the ONE mask
    /// home. ⚠️ Nothing writes it yet (U-D's `clip.setNoteGain` is the planned
    /// writer), so only a hand-authored file carries a non-zero value today —
    /// and the digest's level block (slot 5) re-keys exactly those sets, so
    /// none of them is served a render made while this field was unread.
    public var amplitudeDb: Double

    /// Natural tuning §4 (m23-nt, design `docs/design/2026-09-25-natural-tuning.md`
    /// §4.b.1): the width of the join to the NEXT note, ms of the ORIGINAL take,
    /// stored on the LEFT note (Melodyne's "rear part of the note"). `0` = Auto.
    /// Otherwise `30...1000`: the floor is one analysis hop, the ceiling a
    /// bounded pick, not a measurement.
    ///
    /// Read by the curve since NT-C C4 (`PitchEditSet.softJoin`, the one
    /// width rule) and hashed in digest slot 9. It is deliberately NOT part
    /// of `isPitchIdentity`, `isIdentity` or `isEdited`: with every offset at
    /// 0 a width bends nothing, so a seeded table stays identity (§4.b.1 ⛔).
    /// Codable key `transitionOut`, written only when non-zero.
    public var transitionOutMs: Double

    /// Natural tuning §4: this note is a sung SLIDE that follows its
    /// neighbours, `0...1`. `0` = today (its own constant only). New editor
    /// tables seed `1` on `.transition` parts (`PitchEditSet.seeded`, X3);
    /// presets keep `0`, the user's (a-T) ruling. Read by the curve since C4
    /// (the TILT, `PitchCorrectionCurve.bridge`; slot 9 keys it), and outside
    /// every identity predicate for the reason `transitionOutMs` gives.
    /// Codable key `glideFollow`, written only when non-zero.
    ///
    /// ⚠️ Both natural-tuning note fields are Doubles declared BEFORE
    /// `isCleared`, so the note stays a UUID, Doubles, the drawn shape's two
    /// 8-byte fields below, and two trailing one-byte fields, `isCleared` and
    /// `origin` (`ClipRenderSignatureTests.noteBytesAreExactlyItsFields`).
    public var glideFollow: Double

    // ───────────────────────────────────────────────────────────────────────
    // m23-ap C5b-1 — THE DRAWN SHAPE (design
    // `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` §5.2, B1).
    // ───────────────────────────────────────────────────────────────────────
    //
    // A DELTA, in tenths of a cent, ADDED to whatever the note already plays:
    // one more term in the curve's sum, inside the note's gate, read in SOURCE
    // time (`PitchCorrectionCurve.drawnShape`). It needs no contour, so it
    // plays the same whether or not detection is available. Stored densely on
    // ONE global grid anchored at source second 0 (`shapeGridHz`, 10 ms), so a
    // split, a first-wins truncation and a retime are index operations that
    // never resample. FLAT fields, not a nested struct, so the reflection
    // censuses see each one.
    //
    // ⚠️ **DECLARED BEFORE `isCleared`, ON PURPOSE.** An `Int` and an
    // `Array` are 8 bytes each and 8-aligned, so the note keeps all its
    // padding at the TAIL. The array is a REFERENCE (one pointer), which is
    // why `ClipRenderSignature.Tuning.bitIdentical` skips its 8 bytes and
    // compares its CONTENTS instead (`noteBytesAreExactlyItsFields`).

    /// Grid index of `shapeTenthsOfCents[0]`: sample `k` sits at source
    /// second `Double(shapeStartIndex + k) / shapeGridHz`. 0 when there is no
    /// shape. Codable key `shapeStartIndex`, written only with a shape.
    public var shapeStartIndex: Int

    /// The drawn delta, tenths of a cent, one sample per grid step, within
    /// ±12 000 (±1200 c: an octave move is what `pitchOffsetCents` is for).
    /// EMPTY means no shape (`hasShape`, the one predicate). Codable key
    /// `shapeTenthsOfCents`, written only when non-empty; healed by
    /// `healedShape` in `init`, decode included.
    public var shapeTenthsOfCents: [Int16]

    /// The note is CLEARED: silenced in place, nothing else moved (I7a, design
    /// `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §10/§17).
    ///
    /// ⭐ **SILENCE IS THIS FLAG, NEVER A LEVEL.** `amplitudeDb` at −72 dB is a
    /// level. Restore flips this back and the note returns at ITS OWN level,
    /// which a floor-as-silence scheme would have overwritten with 0 dB. The
    /// pitch curve never reads it, so a cleared note keeps its place in the
    /// curve and its neighbours render exactly as before.
    ///
    /// ⚠️ **DECLARED AFTER EVERY 8-BYTE FIELD ON PURPOSE.** It and `origin`
    /// below are the only one-byte fields, so as the last two stored
    /// properties their padding sits at the TAIL of the struct.
    /// `ClipRenderSignature.Tuning.bitIdentical` compares each note's `size`
    /// bytes (skipping only the drawn shape's pointer, whose contents it
    /// compares) and relies on there being no INTERIOR padding;
    /// `ClipRenderSignatureTests.noteBytesAreExactlyItsFields` pins that.
    /// Codable key `cleared`, written only when true.
    public var isCleared: Bool

    /// Where this segment came from (U-A, unpitched-notes design §1.4, U2): a
    /// note the splitter found, a sung slide, or a SOUND with no detected
    /// pitch (`PitchUnpitchedFinder`). A DETECTION fact, like `detectedHz`:
    /// no edit changes it, which is why it is a `let`. A split carries it
    /// through `reidentified`'s Codable round trip.
    ///
    /// For `.unpitched`, `detectedHz` is the BORROWED drawing anchor (§1.5),
    /// never a measurement, and `detectedConfidence` the median confidence of
    /// the sound's own frames. It is not part of `isIdentity`, `isEdited` or
    /// any other edit predicate: where a note came from is not an edit. It
    /// decides one thing on its own, `entersPitchCurve`.
    ///
    /// ⚠️ **DECLARED LAST, AFTER `isCleared`, ON PURPOSE.** A one-byte enum
    /// anywhere before an 8-byte field would put padding INSIDE the note, and
    /// the byte comparison would then call equal notes unequal
    /// (`noteBytesAreExactlyItsFields` pins the layout). Codable key
    /// `origin`, written only when it is not `.detected`, so every stored
    /// table keeps its bytes and its `contentStamp`; decoded through
    /// `NoteOrigin(storedValue:)`, so a missing OR unknown value reads as
    /// `.detected` and a file from a newer build still opens.
    public let origin: NoteOrigin

    /// ±24 semitones expressed in cents — the same span as
    /// `Clip.pitchShiftSemitonesRange`, so a per-note offset can never ask for
    /// something the whole-clip control could not.
    public static let pitchOffsetCentsRange: ClosedRange<Double> = -2400...2400
    /// 0 = flatten, 1 = keep, up to 4× exaggeration. The ceiling is a pick: it
    /// bounds the curve without pretending to be a measured limit.
    public static let shapeScaleRange: ClosedRange<Double> = 0...4
    /// ±24 semitones, matching the whole-clip pitch range.
    public static let formantOffsetSemitonesRange: ClosedRange<Double> = -24...24
    /// Natural tuning §4.b.1: an explicit join width, ms. `0` (Auto) sits
    /// outside it on purpose; `init` maps `0 < x < 30` to the floor. The
    /// floor is one 30 ms hop (`PitchEditSet.engineMinimumRetuneMs`), the
    /// ceiling a bounded pick.
    public static let transitionOutMsRange: ClosedRange<Double> =
        PitchEditSet.engineMinimumRetuneMs...1000
    /// Natural tuning §4.b.1: 0 (own constant only) to 1 (fully follows).
    public static let glideFollowRange: ClosedRange<Double> = 0...1

    /// C5b-1: the drawn shape's grid, samples per SOURCE second (10 ms). A
    /// pick, not a measurement (§5.2): finer than the detector's 16 ms frame
    /// and the renderer's 30 ms hop, coarse enough to keep a fully drawn
    /// vocal small.
    public static let shapeGridHz: Double = 100
    /// C5b-1: the drawn delta's range, cents. Stored as tenths of a cent in
    /// `shapeTenthsRange`.
    public static let shapeCentsRange: ClosedRange<Double> = -1200...1200
    /// `shapeCentsRange` in the stored unit, tenths of a cent.
    public static let shapeTenthsRange: ClosedRange<Int16> = -12_000...12_000
    /// C5b-1: the last grid index a sample may sit at, 24 h on the grid. A
    /// STRUCTURAL bound (the phase anchor's 24 h precedent) that keeps
    /// `shapeStartIndex + k` far from overflow; no take is that long.
    public static let shapeMaxIndex: Int = 86_400 * 100
    /// C5b-1: the version of the curve's shape arithmetic (grid, units,
    /// interpolation, held ends). It sits inside the render digest's shape
    /// block (slot 4), so a bump re-keys exactly the renders of shaped sets.
    public static let shapeRenderVersion: Int = 1

    /// True when this note carries a drawn shape. ⭐ **THE ONE PREDICATE**
    /// (C5b-1): `isPitchIdentity`, `entersPitchCurve`, the curve's
    /// structural branch, the digest's shape block and `encode` all ask
    /// this, and none of them restates it. An all-zero array IS a shape here
    /// (it renders as nothing through the stretcher); emptying one is the
    /// setter's normalisation (§5.2), not `init`'s.
    public var hasShape: Bool { !shapeTenthsOfCents.isEmpty }

    /// ⭐ THE SHAPE'S HEALING RULE (C5b-1), the one home for `init` and so
    /// for decode:
    ///  * every sample is clamped to `shapeTenthsRange` (±1200 c);
    ///  * a sample whose GRID INDEX falls outside `0...shapeMaxIndex` is
    ///    DROPPED, never moved: a negative start keeps only the samples at
    ///    index ≥ 0, each at its own source second (the global-grid rule),
    ///    and samples past 24 h go the same way;
    ///  * nothing left means no shape, and no shape stores index 0.
    /// A shape that needs none of this is returned as it came, storage and
    /// all, so an untouched note's array is never copied.
    static func healedShape(startIndex: Int, tenths: [Int16]) -> (startIndex: Int, tenths: [Int16]) {
        let count = tenths.count
        // Every index is `startIndex + k`, `k` in `0..<count`. Rejecting the
        // all-outside cases first keeps every sum below in range, `Int.min`
        // and `Int.max` included.
        guard count > 0, startIndex > -count, startIndex <= shapeMaxIndex else { return (0, []) }
        let first = max(0, -startIndex)
        let end = min(count, shapeMaxIndex - startIndex + 1)
        guard first < end else { return (0, []) }
        let range = shapeTenthsRange
        if first == 0, end == count, tenths.allSatisfy({ range.contains($0) }) {
            return (startIndex, tenths)
        }
        return (startIndex + first, tenths[first..<end].map { $0.clamped(to: range) })
    }

    /// Decode's reading of the stored samples: JSON numbers, healed one by
    /// one to the nearest tenth within `shapeTenthsRange` (a non-finite one
    /// to 0, no delta), BEFORE any conversion to `Int16`. Decoding `[Int16]`
    /// directly would THROW on a hand-written 40 000, and one bad note would
    /// fail the whole project.
    static func decodedShapeTenths(_ values: [Double]) -> [Int16] {
        let low = Double(shapeTenthsRange.lowerBound)
        let high = Double(shapeTenthsRange.upperBound)
        return values.map { value in
            guard value.isFinite else { return 0 }
            return Int16(value.rounded().clamped(to: low...high))
        }
    }

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

    /// −1 s to 24 h. A STRUCTURAL bound for sanity, not a taste pick: the
    /// wobble editor anchors inside a note or within half a period of one, so
    /// no real value falls outside it (design §7.1).
    public static let vibratoPhaseAnchorSecondsRange: ClosedRange<Double> = -1...86_400

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
    ///  * Those fields were UNREAD when this was written, so their render
    ///    effect was UNKNOWN. (Since natural tuning C1 the formant offset is
    ///    READ by `PitchCorrectionCurve.formantSemitones`, and a non-zero
    ///    offset DOES change the render once NT-E1 lands, so it belongs here
    ///    on the stronger ground: it is an edit, not a maybe.)
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
    ///
    /// `vibratoPhaseAnchorSeconds` (C5a-1) is a third field of that kind, for
    /// the same arithmetic reason: it enters only inside the same `sin(…)`, so
    /// at depth 0 it is inert for every `t`.
    ///
    /// **I7a/U-C (interaction-batch design §17): identity is two halves, each
    /// with ONE home.** `isPitchIdentity` is everything the STRETCHER would
    /// have to do for this note; `hasLevelEdits` is everything the LEVEL MASK
    /// does (`isCleared`, `amplitudeDb`). A note bends nothing only when both
    /// are quiet. `hasPitchEdits`, `rendersThroughStretchCache`, `isEdited` and
    /// `ClipRenderSignature` follow from here with no second predicate.
    public var isIdentity: Bool { isPitchIdentity && !hasLevelEdits }

    /// True when the stretcher has nothing to do for this note: no pitch,
    /// shaping, generator, formant or timing edit. It is `isIdentity` without
    /// the two LEVEL terms, and it is the render's one bypass predicate
    /// (`StretchCurvePlan.make` guards on `PitchEditSet.isPitchIdentity`). A
    /// set whose only edits are levels therefore takes no curve, and on a
    /// clip that is neither stretched nor transposed it never runs the
    /// stretcher at all. A ratio-1 stretch is not its own input, and clearing
    /// one breath must not recolour the take.
    ///
    /// ⛔ **C5b-1: `!hasShape` IS HERE, NOT ONLY IN `isIdentity`.** A drawn
    /// shape is a STRETCHER edit. Without it a shape-only set would take the
    /// render's bypass (and hash to `""`), and the clip would play unshaped
    /// while every setter echoed success (design §5.8, mode 1).
    /// `isIdentity`, `isEdited`, `hasPitchEdits`, the digest guard and
    /// `RenderDiff`'s plan all follow from this line.
    public var isPitchIdentity: Bool {
        pitchOffsetCents == 0 && driftScale == 1 && vibratoScale == 1
            && vibratoDepthCents == 0
            && formantOffsetSemitones == 0
            && timeStartDeltaSeconds == 0 && timeEndDeltaSeconds == 0
            && !hasShape
    }

    /// True when the LEVEL MASK touches this note: it is cleared, or its level
    /// is not 0 dB. ⭐ **THE ONE PREDICATE** for "does the mask read this note":
    /// the digest's level block (slot 5), the render's mask pass,
    /// `PitchEditSet.gain(atSourceSecond:)` and `isIdentity` all ask this and
    /// none of them restates it. `-0.0` dB is no edit, as everywhere in this
    /// type.
    public var hasLevelEdits: Bool { isCleared || amplitudeDb != 0 }

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
    /// C5a-1: the phase anchor is the third such field.
    public var isEdited: Bool {
        !isIdentity || vibratoRateHz != 0 || vibratoOnsetSeconds != 0
            || vibratoPhaseAnchorSeconds != 0
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

    /// Natural tuning §3b/§3d (W7-C3): true when this note's shaping takes the
    /// SEPARATED (v2) branch of `PitchCorrectionCurve.make`: it shapes against
    /// the contour AND its two scales differ, so the drift/vibrato split no
    /// longer cancels and the separator's kernel is heard.
    ///
    /// ⭐ **THE ONE PREDICATE FOR "WHICH SEPARATOR SHAPES THIS NOTE".** `make`
    /// branches on it, and the render key's `shaping:` version comes from it
    /// (`PitchEditSet.needsSeparatedShaping` →
    /// `PitchRenderContour.shapingVersion(for:)`), so a note can never be shaped
    /// by one separator and keyed as the other. Equal scales, which is every set
    /// the product has ever written, are false here and render and key exactly
    /// as before v2.
    public var takesSeparatedShaping: Bool { wantsContourShaping && driftScale != vibratoScale }

    /// True when `PitchCorrectionCurve.make` builds a span for this segment.
    /// ⭐ **THE ONE PREDICATE** for "does this segment take part in the pitch
    /// curve" (unpitched-notes design §1.6, U4, as amended by natural-tuning
    /// design R21): every note does; a SOUND (`.unpitched`) does only once
    /// someone asked the curve for something on it.
    ///
    /// **Why an untouched sound must stay out, even though it is identity.**
    /// An identity span still joins the gate sum, and the evaluator normalises
    /// that sum whenever it exceeds 1. Beside a note with a longer ramp, the
    /// sound's gate then trims the NOTE's correction near their shared edge.
    /// Out of the curve, a table with untouched sounds renders byte for byte
    /// as the same table without them (`PitchCurveRenderTests` §10, G-C13).
    ///
    /// **Why a moved sound comes in (R21, U5 kept).** The user asked to move
    /// sounds: a breath or an "s" dragged on purpose renders moved (it
    /// transposes noise; the editor says so). A deliberate drift, vibrato or
    /// generator value on a sound enters too, rather than being a silent
    /// no-op: a sound has no voiced frames to shape, so the curve names it in
    /// `unresolvedShapingSegmentIDs`, the honest failure. The shape setters
    /// refuse sounds in words before that can happen (§1.7).
    ///
    /// **A drawn shape comes in too (C5b-1), by the same R21 rule.** A shape
    /// breaks `isPitchIdentity`, so the stretcher runs; a sound with no span
    /// would then drop the shape in silence. With a span it plays like a
    /// moved sound: the drawn delta needs no contour, so it resolves.
    public var entersPitchCurve: Bool {
        origin != .unpitched || pitchOffsetCents != 0 || wantsContourShaping
            || hasGeneratedVibrato || hasShape
    }

    /// True when this note's OWN formant offset reaches the formant curve
    /// (natural tuning §1(b), NT-C C1): the offset is non-zero AND the note
    /// has a span to carry it (`entersPitchCurve`). `PitchEditSet`'s
    /// `engagesFormantCurve` asks this and nothing else.
    ///
    /// ⚠️ **AN UNTOUCHED SOUND'S OFFSET DOES NOT COUNT, AND THAT IS THE
    /// RULING, NOT AN OVERSIGHT.** The formant evaluator reads offsets from
    /// the pitch curve's spans (one set of gates, X7), and an untouched sound
    /// has none. Making a formant-only edit give a sound a span would put it
    /// into the PITCH gate sum too, where its normaliser trims a neighbour's
    /// pitch near their shared edge (`entersPitchCurve`'s own reason): a pitch
    /// change caused by a voice edit. And under `keepsConsonantsUntuned` (R21)
    /// that sound plays the dry take anyway. So the offset is not read, it
    /// does not engage the curve (engaging would run the formant stage for a
    /// value nothing applies), and `ProjectStore.setClipNoteFormant` refuses
    /// every sound in words, so only a hand-authored file can carry one. A
    /// MOVED sound enters like any note (R21): its move follows the set's
    /// amount, and a hand-authored offset on it is read.
    public var engagesFormantCurve: Bool { formantOffsetSemitones != 0 && entersPitchCurve }

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
        vibratoPhaseAnchorSeconds: Double = 0,
        formantOffsetSemitones: Double = 0,
        timeStartDeltaSeconds: Double = 0,
        timeEndDeltaSeconds: Double = 0,
        amplitudeDb: Double = 0,
        transitionOutMs: Double = 0,
        glideFollow: Double = 0,
        shapeStartIndex: Int = 0,
        shapeTenthsOfCents: [Int16] = [],
        isCleared: Bool = false,
        origin: NoteOrigin = .detected
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
        // Non-finite reverts to 0, today's phase: never to a phase nobody set.
        self.vibratoPhaseAnchorSeconds = PitchCorrectionMath
            .finite(vibratoPhaseAnchorSeconds, default: 0)
            .clamped(to: Self.vibratoPhaseAnchorSecondsRange)
        self.formantOffsetSemitones = PitchCorrectionMath
            .finite(formantOffsetSemitones, default: 0)
            .clamped(to: Self.formantOffsetSemitonesRange)
        self.timeStartDeltaSeconds = PitchCorrectionMath.finite(timeStartDeltaSeconds, default: 0)
        self.timeEndDeltaSeconds = PitchCorrectionMath.finite(timeEndDeltaSeconds, default: 0)
        self.amplitudeDb = PitchCorrectionMath
            .finite(amplitudeDb, default: 0).clamped(to: Clip.gainDbRange)
        self.transitionOutMs = Self.healedTransitionOutMs(transitionOutMs)
        // Non-finite reverts to 0 (today's behaviour), never to a follow
        // nobody asked for.
        self.glideFollow = PitchCorrectionMath
            .finite(glideFollow, default: 0).clamped(to: Self.glideFollowRange)
        // C5b-1: clamp, drop what sits off the grid, empty stores index 0
        // (`healedShape`, the one rule).
        (self.shapeStartIndex, self.shapeTenthsOfCents) =
            Self.healedShape(startIndex: shapeStartIndex, tenths: shapeTenthsOfCents)
        self.isCleared = isCleared
        self.origin = origin
    }

    /// `0` stays Auto (non-finite and non-positive read as Auto, so `-0.0`
    /// cannot round-trip as a distinct value); a positive width below one
    /// hop is raised to the floor and one above the ceiling lowered to it,
    /// so a read-back is what applies (the `retuneMs` precedent).
    private static func healedTransitionOutMs(_ value: Double) -> Double {
        let ms = PitchCorrectionMath.finite(value, default: 0)
        return ms > 0 ? ms.clamped(to: transitionOutMsRange) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, startSeconds, endSeconds, detectedHz, detectedConfidence
        case pitchOffsetCents, driftScale, vibratoScale
        case vibratoRateHz, vibratoDepthCents, vibratoOnsetSeconds, vibratoPhaseAnchorSeconds
        case formantOffsetSemitones, timeStartDeltaSeconds, timeEndDeltaSeconds, amplitudeDb
        case transitionOutMs = "transitionOut", glideFollow
        case shapeStartIndex, shapeTenthsOfCents
        case isCleared = "cleared"
        case origin
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
            // C5a-1: absent from every note saved before the field, and from
            // every note since whose anchor is 0 (written only when non-zero),
            // so absent is today's source-zero phase.
            vibratoPhaseAnchorSeconds: try c.decodeIfPresent(
                Double.self, forKey: .vibratoPhaseAnchorSeconds) ?? 0,
            formantOffsetSemitones: try c.decodeIfPresent(
                Double.self, forKey: .formantOffsetSemitones) ?? 0,
            timeStartDeltaSeconds: try c.decodeIfPresent(
                Double.self, forKey: .timeStartDeltaSeconds) ?? 0,
            timeEndDeltaSeconds: try c.decodeIfPresent(
                Double.self, forKey: .timeEndDeltaSeconds) ?? 0,
            amplitudeDb: try c.decodeIfPresent(Double.self, forKey: .amplitudeDb) ?? 0,
            // Natural tuning §4: absent from every note saved before the
            // fields existed, and from every note since that keeps them at
            // 0 (written only when non-zero), so absent is today's join.
            transitionOutMs: try c.decodeIfPresent(Double.self, forKey: .transitionOutMs) ?? 0,
            glideFollow: try c.decodeIfPresent(Double.self, forKey: .glideFollow) ?? 0,
            // C5b-1: absent from every note saved before the shape existed
            // and from every note without one (written only with a shape),
            // so absent is no shape. Samples are read as NUMBERS and healed
            // (`decodedShapeTenths`), never as `Int16`, which would throw.
            shapeStartIndex: try c.decodeIfPresent(Int.self, forKey: .shapeStartIndex) ?? 0,
            shapeTenthsOfCents: Self.decodedShapeTenths(
                try c.decodeIfPresent([Double].self, forKey: .shapeTenthsOfCents) ?? []),
            // I7a: absent from every set saved before clearing existed, and
            // from every uncleared note since (it is written only when true).
            isCleared: try c.decodeIfPresent(Bool.self, forKey: .isCleared) ?? false,
            // U-A: read as a STRING and healed, never as `NoteOrigin` itself.
            // A decode of the enum would THROW on a case a newer build added,
            // and one unknown note would then fail the whole project. Absent
            // (every note written before U-A, and every detected note since)
            // and unknown both read as `.detected`.
            origin: NoteOrigin(storedValue: try c.decodeIfPresent(String.self, forKey: .origin)))
    }

    /// Writes the four detection facts always (they are what the segment IS;
    /// `origin`, the fifth, only when it is not `.detected`, U-A), and every
    /// EDIT field only when it departs from its default — the
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
        if vibratoPhaseAnchorSeconds != 0 {
            try c.encode(vibratoPhaseAnchorSeconds, forKey: .vibratoPhaseAnchorSeconds)
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
        // Natural tuning §4: omit-when-default, so a note saved before these
        // existed re-saves byte-identically (G-FILE).
        if transitionOutMs != 0 { try c.encode(transitionOutMs, forKey: .transitionOutMs) }
        if glideFollow != 0 { try c.encode(glideFollow, forKey: .glideFollow) }
        // C5b-1: both keys, or neither (an empty shape stores index 0), so a
        // note with no shape saves byte-identically to one saved before it
        // existed and keeps its `contentStamp`.
        if hasShape {
            try c.encode(shapeStartIndex, forKey: .shapeStartIndex)
            try c.encode(shapeTenthsOfCents, forKey: .shapeTenthsOfCents)
        }
        // I7a: omit-when-default like every edit field, so a project with no
        // cleared note saves byte-identically to one saved before the flag.
        if isCleared { try c.encode(true, forKey: .isCleared) }
        // U-A: omit-when-default, so a table with no sound and no slide saves
        // byte-identically to one saved before the field (and keeps its
        // `contentStamp`, so a preset's own output still reads as untouched).
        if origin != .detected { try c.encode(origin.rawValue, forKey: .origin) }
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

    // ───────────────────────────────────────────────────────────────────────
    // Natural tuning (m23-nt, design `docs/design/2026-09-25-natural-tuning.md`).
    // THREE SET-LEVEL FIELDS, ONE RULE FOR EACH OF THEM:
    //  * the memberwise default is the LEGACY value, so every existing
    //    `PitchEditSet(...)` call and every test golden is unchanged (X2);
    //  * an ABSENT key decodes to that legacy value and the legacy value is
    //    never written, so a saved project re-saves byte-identically (G-FILE);
    //  * NEW sets get the new values only through `PitchEditSet.seeded` (X3),
    //    and every rebuild goes through `withSegments`, which carries them.
    // ⚠️ NT-C C0 landed the fields only. C1 added the formant evaluator
    // (`PitchCorrectionCurve.formantSemitones`, `engagesFormantCurve`; slot
    // 7, NT-E1). C4 made the curve read the §4 fields (`usesSoftJoins`) and
    // keys them in slot 9. C2 gave `keepsConsonantsUntuned` its mask
    // (`PitchConsonantMask.swift`) and keys it in slot 8; the render's mix
    // that reads the mask is NT-E2's. NT-C2-F1 (W7-D2) made the consonant
    // field's STORED state `consonantProtection` (three cases, so a preset
    // re-run can tell an OFF somebody chose from one nobody chose);
    // `keepsConsonantsUntuned` is its on/off reading, and the legacy rule
    // above still holds for it.
    // ───────────────────────────────────────────────────────────────────────

    /// §1: how much of a moved note's formant shift is REMOVED, `0...1`.
    /// `nil` = legacy (the clip's `formantPreserve` flag alone, today's code).
    ///
    /// ⚠️ **`0.0` IS NOT LEGACY.** At 0.0 the formant branch still runs
    /// (§1(b)), so 0.0 is ENCODED like any other value; only nil is omitted.
    /// An omit-at-zero habit would silently flip a saved 0.0 back to legacy
    /// on reopen. A non-finite value reads as nil.
    public var formantCorrection: Double?

    /// §2: the gaps between notes play the untouched take, so consonants and
    /// breaths keep their own pitch. ⭐ **THE ON/OFF READING of
    /// `consonantProtection`** (the stored state, below), and what every
    /// reader asks: the mask (`PitchConsonantMask.swift`, `hasConsonantMix`,
    /// `tunedWeight`), digest slot 8, the wire. `false` = legacy. Its store
    /// door is `ProjectStore.setClipConsonantProtection`.
    ///
    /// ⚠️ **WRITING IT SWITCHES THE FLAG AND NEVER RECORDS OR ERASES A
    /// CHOICE:** `true` is `.on`; `false` on an `.on` set is `.offByDefault`;
    /// `false` on either off state changes nothing. Only
    /// `setClipConsonantProtection` records a choice (`.offByChoice`), so no
    /// other writer (a fixture, a copy, a future rebuild) can turn an OFF
    /// nobody chose into a chosen one, or quietly forget a chosen one.
    public var keepsConsonantsUntuned: Bool {
        get { consonantProtection == .on }
        set {
            if newValue {
                consonantProtection = .on
            } else if consonantProtection == .on {
                consonantProtection = .offByDefault
            }
        }
    }

    /// §2, NT-C2-F1 (W7-D2): the consonant setting AS STORED, three states,
    /// because a Bool cannot tell an OFF somebody CHOSE from one nobody
    /// chose, and a preset re-run must keep the first and seed the second
    /// (`ProjectStore.autoCorrectClipPitchReport` is the one home of that
    /// rule). Codable key `keepsConsonantsUntuned`: ABSENT is
    /// `.offByDefault`, `true` is `.on`, an explicit `false` is
    /// `.offByChoice` (`ConsonantProtection` argues each).
    ///
    /// ⭐ **ONE STORED FIELD, NOT A Bool PLUS A "chosen" Bool.** Two fields
    /// need an invariant between them ("OFF was chosen" with the flag on
    /// means nothing), and a state the file cannot hold would not survive a
    /// save. Three cases are exactly the three encodings, and the
    /// synthesized `==` tells `.offByDefault` from `.offByChoice`, which is
    /// what makes `performEdit` journal a choice and undo restore "never
    /// chosen" exactly.
    ///
    /// ⚠️ **NOT RENDER MATERIAL BEYOND ITS ON/OFF READING.** Every render
    /// reader asks `keepsConsonantsUntuned`, which is false in both off
    /// states, so `.offByDefault` and `.offByChoice` render, key and digest
    /// alike (the `autoCorrectStamp` precedent; DAWEngineTests'
    /// `ConsonantChoiceDigestTests` pins it). It IS part of what the set
    /// saves, so `contentStamp` sees it: a choice made after a preset reads
    /// as a change since that preset, as a flip of the flag always has.
    ///
    /// ⚠️ Not the `consonantProtection` OBJECT in `clip.getPitchEdits`' reply
    /// (`active`/`inactiveReason`: whether the mix runs, read through
    /// `consonantMixIsActive`). That reply does not carry this state yet.
    public var consonantProtection: ConsonantProtection

    /// §4: the fastest the ADDED correction may travel across a soft join,
    /// cents per second; also the soft-join mode switch. `0` = legacy
    /// (today's centred per-span ramps), otherwise `500...20000` (bounded
    /// picks). Codable key `transitionSlope`, written only when non-zero.
    public var transitionSlopeCentsPerSecond: Double

    /// §1(c): the correction a NEW set starts with. Provisional: the 1(h)
    /// listening round picks the final value, and this is the one line.
    public static let newSetFormantCorrection: Double = 1.0
    /// §1: the amount's range. nil (legacy) sits outside it.
    public static let formantCorrectionRange: ClosedRange<Double> = 0...1
    /// §1(d): the version of what an ENGAGED formant curve renders, hashed in
    /// digest slot 7 (NT-E1) so a bump re-keys only the sets that
    /// `engagesFormantCurve`, never every stretched clip
    /// (`stretchEngineVersion` is NOT the lever). Bump it when the base
    /// policy (`PitchCorrectionCurve.formantBaseHz`: the step rule, the
    /// unpitched skip, the 50 Hz floor), the F arithmetic
    /// (`formantSemitones`), the shim's formant semantics or the vendored
    /// library's ENGAGED formant path (patch 0004) change. R8: the explicit
    /// base's half-bin offset is part of versions 1 and 2.
    ///
    /// **2 (NT-E1b): the render READS the curve.** Under version 1, slot 7
    /// keyed every engaged set while `StretchRenderCache.renderAudio` still
    /// handed the curve loop no formant curve, so every render cached then
    /// (staging builds share the render cache) holds UN-shaped audio under
    /// an engaged key. Version 2 orphans those entries ON PURPOSE: each
    /// re-renders once, shaped. A legacy set has no slot 7 and keeps its key.
    ///
    /// **3 (NT-F220): the library's formant envelope, explicit base only.**
    /// Vendored patch 0004 (`Sources/CSignalsmithStretch/VENDORED.md`)
    /// replaces signalsmith's decay-and-erode envelope with one drawn through
    /// the harmonic peaks, WHEN the caller hands over a base (every engaged
    /// render does: `formantBaseHz`). The old envelope sagged about 4 dB
    /// between two strong harmonics and handed a weak harmonic its louder
    /// neighbour's skirt, so the compensation over-corrected down-shifts
    /// (220 Hz −5 st read +63 c against a 50 c bound). Every render cached
    /// under version 2 holds the old envelope under an engaged key, so it
    /// re-renders once. With no explicit base (the clip's own formant flag,
    /// `css_set_formant_preserve`) the library runs upstream's code and the
    /// bytes do not move, so a legacy set keeps its key AND its audio. R8's
    /// half bin: the new envelope reads the spacing as `freqEstimate + 0.5`
    /// bins, so the half-bin offset no longer shapes an engaged render; the
    /// base handed over is unchanged.
    public static let formantRenderVersion: Int = 3
    /// §1 R11: the shortest note whose Voice offset
    /// (`NoteSegment.formantOffsetSemitones`) the render can give to that
    /// note alone, seconds. MEASURED by NT-E1 (`NaturalTuningFormantRender
    /// Tests.probeMinimumVoiceNote`: f0 110 Hz, a −3 st offset on a note
    /// between two long abutting notes, retune 45 ms, amount 1, one
    /// 2048-frame envelope window at the note's centre): the offset reaches
    /// 82 % of a 1 s note's reading at 60 ms, 90 % at 80 ms and about 100 %
    /// from 100 ms, with no leak into either neighbour. The render sets one
    /// formant value per 1440-frame hop and shapes 120 ms blocks, so a
    /// shorter note cannot hold its own value. Nothing reads this yet: the
    /// pitch editor's "too short to change the voice of this note alone"
    /// line (NT-U) will.
    public static let minimumVoiceNoteSeconds: Double = 0.08
    /// §4.c: the slope a NEW set starts with, provisional 3000 c/s pending
    /// the 4.h listening round (R14: presets get it too).
    public static let defaultTransitionSlope: Double = 3000
    /// §4.b.1: `0` (legacy) sits outside it; `init` raises `0 < x < 500`.
    public static let transitionSlopeRange: ClosedRange<Double> = 500...20000

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

    /// Natural tuning §3d (W7-C3): true when some note takes the SEPARATED (v2)
    /// drift/vibrato branch (`NoteSegment.takesSeparatedShaping`, the one
    /// predicate). The render key's `shaping:` field is version 2 exactly when
    /// this holds (`PitchRenderContour.shapingVersion(for:)`); every other set,
    /// Hard Tune and every preset included, keys version 1 as it always did.
    public var needsSeparatedShaping: Bool { segments.contains(where: \.takesSeparatedShaping) }

    /// True when any note is retimed: `NoteSegment.hasTimeEdits`, the one
    /// predicate (m23-ap C2-1). When this is false, `PitchTimeWarp.make`
    /// returns nil, the digest emits no time-warp block, and a render takes
    /// today's linear loop byte for byte. Timing is invisible until it is used.
    public var hasTimeEdits: Bool { segments.contains(where: \.hasTimeEdits) }

    /// True when every note is `NoteSegment.isPitchIdentity`: the set asks the
    /// stretcher for nothing, whatever its levels. THE render's bypass
    /// predicate (`StretchCurvePlan.make` returns nil on it). Distinct from
    /// `isIdentity`, which is also false for a set that only clears or levels
    /// notes; such a set still renders, through the level mask alone.
    public var isPitchIdentity: Bool { segments.allSatisfy(\.isPitchIdentity) }

    /// True when any note is cleared or carries a level:
    /// `NoteSegment.hasLevelEdits`, the one predicate (I7a/U-C). When this is
    /// false the digest emits no level block and the render never runs the
    /// mask, so a set nobody cleared or levelled keys and renders byte for
    /// byte as it did before either existed.
    public var hasLevelEdits: Bool { segments.contains(where: \.hasLevelEdits) }

    public static let empty = PitchEditSet(analysisVersion: currentAnalysisVersion, segments: [])

    /// The three natural-tuning parameters are TRAILING and DEFAULT TO LEGACY
    /// (X2), so no existing call site changes. They CLAMP, like `retuneMs`,
    /// so a decoded or hand-built set reads back what applies.
    public init(analysisVersion: Int = PitchEditSet.currentAnalysisVersion,
                segments: [NoteSegment] = [],
                retuneMs: Double = PitchEditSet.engineMinimumRetuneMs,
                formantCorrection: Double? = nil,
                keepsConsonantsUntuned: Bool = false,
                transitionSlopeCentsPerSecond: Double = 0) {
        self.analysisVersion = analysisVersion
        self.retuneMs = PitchCorrectionMath
            .finite(retuneMs, default: Self.engineMinimumRetuneMs)
            .clamped(to: Self.retuneMsRange)
        self.segments = Self.canonical(segments)
        self.formantCorrection = formantCorrection.flatMap {
            $0.isFinite ? $0.clamped(to: Self.formantCorrectionRange) : nil
        }
        // The memberwise Bool can say on or off, never "chosen": a choice is
        // the store door's alone (`consonantProtection`).
        self.consonantProtection = keepsConsonantsUntuned ? .on : .offByDefault
        let slope = PitchCorrectionMath.finite(transitionSlopeCentsPerSecond, default: 0)
        self.transitionSlopeCentsPerSecond = slope > 0
            ? slope.clamped(to: Self.transitionSlopeRange) : 0
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
        case formantCorrection, keepsConsonantsUntuned
        case transitionSlopeCentsPerSecond = "transitionSlope"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let consonants = try c.decodeIfPresent(Bool.self, forKey: .keepsConsonantsUntuned)
        self.init(
            analysisVersion: try c.decodeIfPresent(Int.self, forKey: .analysisVersion)
                ?? Self.currentAnalysisVersion,
            segments: try c.decodeIfPresent([NoteSegment].self, forKey: .segments) ?? [],
            retuneMs: try c.decodeIfPresent(Double.self, forKey: .retuneMs)
                ?? Self.engineMinimumRetuneMs,
            // Natural tuning: ABSENT is LEGACY for all three (every set saved
            // before 2026-09-25 lacks them), routed through the clamping init.
            formantCorrection: try c.decodeIfPresent(Double.self, forKey: .formantCorrection),
            keepsConsonantsUntuned: consonants == true,
            transitionSlopeCentsPerSecond: try c.decodeIfPresent(
                Double.self, forKey: .transitionSlopeCentsPerSecond) ?? 0)
        // NT-C2-F1: an EXPLICIT `false` is an OFF somebody chose (only
        // `.offByChoice` writes one). Absent stays the init's `.offByDefault`.
        if consonants == false { self.consonantProtection = .offByChoice }
        // Absent (every set saved before C-F3) stays nil, which reads as "may
        // carry hand edits" — the CONFIRM answer, never the silent one.
        self.autoCorrectStamp = try c.decodeIfPresent(String.self, forKey: .autoCorrectStamp)
    }

    /// `retuneMs` is omitted at the floor and `autoCorrectStamp` when nil, the
    /// same omit-when-default rule the rest of the clip payload follows. The
    /// natural-tuning fields follow it too, with TWO deliberate exceptions:
    /// `formantCorrection` is omitted only when nil and written at every
    /// value INCLUDING 0.0, because 0.0 is an engaged amount, not legacy; and
    /// a consonant OFF somebody CHOSE (`.offByChoice`) writes an explicit
    /// `false`, because it is not the legacy default either. An OFF nobody
    /// chose still writes nothing.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(analysisVersion, forKey: .analysisVersion)
        try c.encode(segments, forKey: .segments)
        if retuneMs != Self.engineMinimumRetuneMs { try c.encode(retuneMs, forKey: .retuneMs) }
        if let autoCorrectStamp { try c.encode(autoCorrectStamp, forKey: .autoCorrectStamp) }
        if let formantCorrection { try c.encode(formantCorrection, forKey: .formantCorrection) }
        switch consonantProtection {
        case .offByDefault: break
        case .on: try c.encode(true, forKey: .keepsConsonantsUntuned)
        case .offByChoice: try c.encode(false, forKey: .keepsConsonantsUntuned)
        }
        if transitionSlopeCentsPerSecond != 0 {
            try c.encode(transitionSlopeCentsPerSecond, forKey: .transitionSlopeCentsPerSecond)
        }
    }
}

// MARK: - Natural tuning: the ONE seed and the ONE rebuild (design X2/X3)

extension PitchEditSet {

    /// NT-C2-F1 (W7-D2): the three consonant states `consonantProtection`
    /// stores, one per encoding.
    public enum ConsonantProtection: Sendable, Equatable, CaseIterable {
        /// OFF, and nobody chose it: the legacy default. Every set saved
        /// before natural tuning, every memberwise construction, and a legacy
        /// set given only a voice size (`setClipFormantCorrection` writes its
        /// own field alone). Encoded as NO key. A preset re-run gives it the
        /// new-set seed, ON.
        case offByDefault
        /// ON: seeded (every new set, `seeded`) or switched on. Encoded
        /// `true`. A preset re-run keeps it. "Chosen ON" and "seeded ON" are
        /// not told apart because the seed is ON too, so they have one
        /// future; `ConsonantChoiceTests`' seed tripwire fails the day the
        /// seed stops being ON, and that day this needs a chosen-ON case.
        case on
        /// OFF because somebody switched it off
        /// (`ProjectStore.setClipConsonantProtection(enabled: false)`, the
        /// only writer). Encoded as an EXPLICIT `false`, which no file saved
        /// before this state existed contains: every encoder this field has
        /// had wrote `true` or nothing. A preset re-run and the
        /// natural-tuning update (`upgradedToNaturalTuning`) both keep it.
        case offByChoice
    }

    /// Which product seam is minting a NEW set. The seed values differ in
    /// exactly one place, deliberately (X3, "do NOT unify them"): only the
    /// editor marks sung slides as following their neighbours.
    public enum SeedPolicy: Sendable, Equatable {
        /// `PitchNoteTable.detected`: the note table the editor draws.
        case editor
        /// `PitchAutoCorrect.editSet`: auto-correct and every preset. Slides
        /// stay AS SUNG (`glideFollow` 0), the user's (a-T) ruling.
        case preset
    }

    /// This set with its notes replaced and EVERY other stored property
    /// carried, the set-level natural-tuning fields and `autoCorrectStamp`
    /// included. ⭐ **THE ONE REBUILD (X2 rule 2).** A copy, not a memberwise
    /// call, so a field added tomorrow is carried without this function
    /// changing; `canonical` heals the notes exactly as `init` would.
    ///
    /// ⛔ A rebuild through `PitchEditSet(analysisVersion:segments:retuneMs:)`
    /// silently reverts every other field to legacy: a tone change nobody
    /// asked for. `NaturalTuningFieldCarryTests` and the store-writer carry
    /// test in `PitchCorrectionWriterTests` pin it.
    public func withSegments(_ segments: [NoteSegment]) -> PitchEditSet {
        var copy = self
        copy.segments = Self.canonical(segments)
        return copy
    }

    /// ⭐ **THE ONE SEED (X2 rule 3, R29).** Every product seam that CREATES a
    /// set calls this, and nothing else sets the natural-tuning fields on a
    /// new set. Per-field policy (X3 as amended by R14):
    ///
    ///     field                      editor seed        preset seed
    ///     formantCorrection          newSet (1.0)       newSet (1.0)
    ///     keepsConsonantsUntuned     true               true
    ///     transitionSlope            default (3000)     default (3000)
    ///     glideFollow, .transition   1                  0
    ///
    /// `partKinds` is a TRANSIENT hint (never stored): the splitter's kind for
    /// each segment id, which only the editor seam still holds. The POLICY
    /// decides whether it is read, not its emptiness, so a preset caller that
    /// passed kinds by mistake still cannot tilt a slide.
    public static func seeded(analysisVersion: Int,
                              segments: [NoteSegment],
                              retuneMs: Double,
                              partKinds: [UUID: NotePart.Kind],
                              seedPolicy: SeedPolicy) -> PitchEditSet {
        var notes = segments
        if seedPolicy == .editor {
            for index in notes.indices where partKinds[notes[index].id] == .transition {
                notes[index].glideFollow = 1
            }
        }
        return PitchEditSet(analysisVersion: analysisVersion,
                            segments: notes,
                            retuneMs: retuneMs,
                            formantCorrection: newSetFormantCorrection,
                            keepsConsonantsUntuned: true,
                            transitionSlopeCentsPerSecond: defaultTransitionSlope)
    }

    /// R16: a tuned vocal made before natural tuning existed. It carries no
    /// formant amount and asks the stretcher for something. The editor's
    /// "Tuned before this update. Tap to update." line and the wire's
    /// `predatesNaturalTuning` both read THIS, and the tap is
    /// `ProjectStore.upgradeToNaturalTuning`. A set that bends nothing is not
    /// "tuned", so it never asks.
    public var predatesNaturalTuning: Bool { formantCorrection == nil && !isPitchIdentity }

    /// §1(b)/(d): the render builds the per-hop FORMANT curve for this set
    /// (NT-E1's closures, digest slot 7). ⭐ **THE ONE PREDICATE**: the plan,
    /// the digest block and RenderDiff all ask this and none restates it.
    ///
    /// True when the set carries an amount (`0.0` included: it is an engaged
    /// amount, not legacy) or any note's own offset reaches the curve
    /// (`NoteSegment.engagesFormantCurve`). A legacy set with every offset 0
    /// is false, so it renders and keys exactly as before §1. A legacy set
    /// with a hand-authored offset engages with `c` = the clip's flag, which
    /// is how that offset is finally read (§1(c) row 2).
    public var engagesFormantCurve: Bool {
        formantCorrection != nil || segments.contains(where: \.engagesFormantCurve)
    }
}

// MARK: - Natural tuning §4: soft joins (NT-C C4)

/// Where two NEIGHBOURING CURVE NOTES meet (natural tuning R15, which amends
/// §4.b.2, §2b.2 and X8). ⭐ **THE ONE PREDICATE** for "soft join": §4's
/// curve (`PitchCorrectionCurve.make`), the digest and the wire read it, and
/// §2's consonant mask reads the same function, so the two sections act on
/// disjoint places by construction: a `.gap` is §2's (the dry take plays
/// there), a `.soft` join is §4's (the correction crossfades across it).
public enum PitchJoinKind: String, Sendable, Equatable, CaseIterable {
    /// The notes abut bit for bit (a join inside one voiced run), or a hole
    /// shorter than `PitchEditSet.consonantMinimumGapSeconds` separates
    /// them (a detector blink). The correction crossfades across it.
    case soft
    /// A silence, a breath or a consonant separates them. Each note keeps its
    /// own ramp into the gap, today's rule.
    case gap
}

extension NoteSegment {
    /// True when this note carries a §4 transition edit: an explicit join
    /// width or a follow amount. ⭐ **THE ONE PREDICATE**; `PitchEditSet`'s
    /// `usesSoftJoins` asks it. NOT part of any identity predicate: with
    /// every offset at 0 a width or a follow bends nothing (§4.b.1 ⛔).
    public var hasTransitionEdits: Bool { transitionOutMs != 0 || glideFollow != 0 }
}

extension PitchEditSet {

    /// True when `PitchCorrectionCurve.make` takes the SOFT branch (§4.b.2):
    /// the set carries a transition slope, or some note carries a transition
    /// edit. ⭐ **THE ONE PREDICATE**: `make`, the digest's slot 9 and the
    /// wire all ask this. A LEGACY set (every set saved before natural
    /// tuning) is false, takes the unchanged branch and keeps its key.
    public var usesSoftJoins: Bool {
        transitionSlopeCentsPerSecond > 0 || segments.contains(where: \.hasTransitionEdits)
    }

    /// The version of the join arithmetic a SOFT set renders with, hashed in
    /// digest slot 9 so a bump re-keys exactly the soft sets (never
    /// `stretchEngineVersion`, which would re-render every stretched clip).
    /// ⚠️ **BUMP IT** when `softJoin`'s width or edge rule, the bridge
    /// (`PitchCorrectionCurve.bridge`), `joinKind` or
    /// `consonantMinimumGapSeconds` changes: none of them is in the digest
    /// as a value.
    public static let transitionRenderVersion: Int = 1

    /// The shortest hole between two curve notes that counts as a GAP rather
    /// than a soft join, seconds (R15). ⚠️ **A PROVISIONAL PICK, NOT A
    /// MEASUREMENT:** 64 ms is four detector frames, U-A's "keep ≥ 4 frames"
    /// precedent and §2's starting candidate; M-3's gap histogram sets the
    /// one threshold for both sections. `voicedRuns` ends a note at any
    /// unvoiced frame, so a one-frame blink leaves a 16-32 ms hole: soft.
    /// Changing this changes which joins are soft on every soft set AND
    /// where the consonant mask plays the dry take, so it bumps BOTH
    /// `transitionRenderVersion` and §2's `consonantMaskVersion`.
    public static let consonantMinimumGapSeconds: Double = 0.064

    /// R15's rule on two EDGES: `.soft` when the notes abut bit for bit or
    /// the hole between them is shorter than `consonantMinimumGapSeconds`,
    /// else `.gap`. Pure; §2's mask calls this with its own region bounds.
    public static func joinKind(leftEndSeconds: Double,
                                rightStartSeconds: Double) -> PitchJoinKind {
        if leftEndSeconds == rightStartSeconds { return .soft }
        return rightStartSeconds - leftEndSeconds < consonantMinimumGapSeconds ? .soft : .gap
    }

    /// R15's `joinKind(between: i, and: i+1)`, on segment INDICES.
    ///
    /// ⚠️ **MEANINGFUL BETWEEN NEIGHBOURING CURVE NOTES ONLY**
    /// (`NoteSegment.entersPitchCurve`; `nextCurveNoteIndex(after:)` finds
    /// the neighbour). An untouched SOUND builds no span, and a note abuts
    /// its neighbouring sound bit for bit, so asking about a note and its
    /// sound would call that edge soft and widen the correction INTO the
    /// consonant: the exact spill §2 exists to stop. The curve never asks
    /// that question: across an untouched sound, the join is between the two
    /// notes on either side of it, and the sound's length is the gap.
    public func joinKind(between left: Int, and right: Int) -> PitchJoinKind {
        Self.joinKind(leftEndSeconds: segments[left].endSeconds,
                      rightStartSeconds: segments[right].startSeconds)
    }

    /// The index of the next segment after `index` that enters the pitch
    /// curve, or nil when there is none (`index` is the last curve note).
    public func nextCurveNoteIndex(after index: Int) -> Int? {
        guard index + 1 < segments.count else { return nil }
        return segments[(index + 1)...].firstIndex(where: \.entersPitchCurve)
    }

    /// The index of the previous segment before `index` that enters the
    /// pitch curve, or nil when there is none.
    public func previousCurveNoteIndex(before index: Int) -> Int? {
        guard index > 0, index <= segments.count else { return nil }
        return segments[..<index].lastIndex(where: \.entersPitchCurve)
    }

    /// One soft join as the curve applies it: the edge both gates centre on
    /// (the shared boundary, or an R15 short hole's midpoint) and the ONE
    /// half-width both sides use.
    public struct SoftJoin: Sendable, Equatable {
        public let edgeSeconds: Double
        public let halfWidthSeconds: Double
    }

    /// ⭐ **THE ONE WIDTH RULE** (§4.b.2 step 2), for a join the caller has
    /// already found `.soft` between two neighbouring curve notes.
    /// `PitchCorrectionCurve.make` and `joinReading(afterSegmentAt:)` (the
    /// wire's echo) both call it, so what an agent reads is what renders.
    ///  * Each side's value at the join, cents: its own offset, plus, when
    ///    it FOLLOWS (`glideFollow` g > 0), g × the other side's OWN offset
    ///    (the bridge's value at that edge; no recursion). So a slide that
    ///    follows a moved note meets it with Δ = 0 and takes the floor.
    ///  * `W` = the LEFT note's `transitionOutMs` when set; else, with a
    ///    slope, `max(retuneMs, 1000 · Δ / slope)` ms; else nil: this join
    ///    keeps its legacy halves (a set can be soft only because another
    ///    note carries an explicit width).
    ///  * `h = min(W / 2, left / 2, right / 2)`: never wider than half the
    ///    shorter note, so no point along a chain of soft joins sees three
    ///    gates (I1). The slope cap is not honoured next to a very short
    ///    note (§4.b.6, a stated bound).
    public static func softJoin(left: NoteSegment, right: NoteSegment,
                                retuneMs: Double,
                                slopeCentsPerSecond: Double) -> SoftJoin? {
        let widthMs: Double
        if left.transitionOutMs > 0 {
            widthMs = left.transitionOutMs
        } else if slopeCentsPerSecond > 0 {
            var endValue = left.pitchOffsetCents
            if left.glideFollow > 0 { endValue += left.glideFollow * right.pitchOffsetCents }
            var startValue = right.pitchOffsetCents
            if right.glideFollow > 0 { startValue += right.glideFollow * left.pitchOffsetCents }
            widthMs = max(retuneMs, 1000 * abs(endValue - startValue) / slopeCentsPerSecond)
        } else {
            return nil
        }
        let half = min(widthMs / 2000, left.durationSeconds / 2, right.durationSeconds / 2)
        let edge = left.endSeconds == right.startSeconds
            ? left.endSeconds : (left.endSeconds + right.startSeconds) / 2
        return SoftJoin(edgeSeconds: edge, halfWidthSeconds: half)
    }

    /// What the join to a note's RIGHT is, as the curve applies it: the
    /// wire's `joinToNext` and `effectiveTransitionMs` (§4.e), and the pitch
    /// editor's slide caption (R12).
    public struct JoinReading: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            /// A soft join to `nextSegmentId` (R15).
            case soft
            /// A gap before `nextSegmentId`: no slide to shape.
            case gap
            /// No curve note after this one.
            case last
        }
        public let kind: Kind
        public let nextSegmentId: UUID?
        /// The full width the soft rule applies, ms of the ORIGINAL take
        /// (`2 · h`, clamps included), or nil when this join keeps each
        /// note's legacy ramp: a gap, a last note, or a soft join on a set
        /// with no width rule for it (a legacy set).
        public let appliedWidthMs: Double?
        /// The note's `transitionOutMs` is 0: the width is the automatic one.
        public let isAuto: Bool
    }

    /// The join after the note at `index`, or nil when that segment does not
    /// enter the pitch curve (an untouched sound has no join).
    public func joinReading(afterSegmentAt index: Int) -> JoinReading? {
        guard segments.indices.contains(index), segments[index].entersPitchCurve else { return nil }
        let left = segments[index]
        let isAuto = left.transitionOutMs == 0
        guard let next = nextCurveNoteIndex(after: index) else {
            return JoinReading(kind: .last, nextSegmentId: nil, appliedWidthMs: nil, isAuto: isAuto)
        }
        let right = segments[next]
        guard joinKind(between: index, and: next) == .soft else {
            return JoinReading(kind: .gap, nextSegmentId: right.id, appliedWidthMs: nil,
                               isAuto: isAuto)
        }
        let applied = usesSoftJoins
            ? Self.softJoin(left: left, right: right, retuneMs: retuneMs,
                            slopeCentsPerSecond: transitionSlopeCentsPerSecond)
                .map { $0.halfWidthSeconds * 2000 }
            : nil
        return JoinReading(kind: .soft, nextSegmentId: right.id, appliedWidthMs: applied,
                           isAuto: isAuto)
    }

    /// The source seconds a change of ONE note's pitch offset can change on
    /// the curve: the window a pitch drag's DRAFT line must own (NT-U2; the
    /// pitch editor's `draftSpan`), so that outside it the committed line and
    /// the line that plays are the same numbers. CONSERVATIVE, never exact: a
    /// wider window only redraws more of a line that is correct everywhere.
    ///  * ⭐ D4-1 (b), the user's ruling (`handEditUpgradesLegacyVocal`): on a
    ///    vocal that `predatesNaturalTuning` a drag that MOVES the note is its
    ///    FIRST hand edit (one that moves nothing changes nothing, the no-op
    ///    rule), and it updates the WHOLE vocal in the same step (every
    ///    bent note takes the new voice amount, every join the soft rule). So
    ///    the reach is the whole vocal, `wholeVocalDragReach()`.
    ///  * Otherwise (a second drag, or a set that is already new) the note's
    ///    own reach, `noteDragReach(ofSegmentAt:)`: this function's rule
    ///    before D4-1 (b).
    /// nil for an index outside the table.
    public func pitchDragReach(ofSegmentAt index: Int) -> ClosedRange<Double>? {
        guard segments.indices.contains(index) else { return nil }
        if afterHandEdit() != self { return wholeVocalDragReach() }
        return noteDragReach(ofSegmentAt: index)
    }

    /// Every segment of this set, each widened the way the soft rule widens
    /// a dragged note (`max(retuneMs / 2, half its length + half an R15 short
    /// hole)` on each side), merged into one range: the reach of a drag that
    /// updates the whole vocal (D4-1 (b), `pitchDragReach`). Sounds count
    /// too: a wider window is the safe direction. nil for an empty set.
    func wholeVocalDragReach() -> ClosedRange<Double>? {
        guard !segments.isEmpty else { return nil }
        let legacyHalf = max(0, retuneMs / 1000 / 2)
        let slack = Self.consonantMinimumGapSeconds / 2
        var lower = Double.infinity
        var upper = -Double.infinity
        for segment in segments {
            let widening = max(legacyHalf, segment.durationSeconds / 2 + slack)
            lower = min(lower, segment.startSeconds - widening)
            upper = max(upper, segment.endSeconds + widening)
        }
        return lower...upper
    }

    /// The NOTE's own reach: what moving the note at `index` can change while
    /// every other note stays as it is (`pitchDragReach`'s rule before D4-1
    /// (b)).
    ///  * A LEGACY set (`!usesSoftJoins`): the note widened by half the
    ///    retune on each side, today's `draftSpan` rule verbatim.
    ///  * A SOFT set, also: the note's own soft edges (a soft half never
    ///    exceeds half the note, but its centre can sit half an R15 short hole
    ///    outside it), and each neighbouring curve note across a soft join:
    ///    its side of the join moves with the jump (to the neighbour's middle
    ///    at most), and a neighbour that FOLLOWS tilts over its whole length.
    ///    ⚠️ This is why today's `draftSpan` is too narrow on a soft set: a
    ///    300 c drag widens the join past `retuneMs / 2` and tilts a followed
    ///    slide next to it end to end.
    ///  * ⚠️ LEGACY OR SOFT IS READ ON THE SET THE DRAG STORES, not on this
    ///    one (`setADragStores(ofSegmentAt:)`). A table with no voice amount
    ///    whose notes bend nothing yet (never tuned, or every move undone) does
    ///    not predate natural tuning, so `pitchDragReach` does not give it the
    ///    whole vocal. But the drag bends a note, and `afterHandEdit()` then
    ///    updates the set it stores, default slope included, so its joins are
    ///    soft. Nothing else bends there, so the note's own reach holds, by
    ///    the SOFT rule.
    /// nil for an index outside the table.
    func noteDragReach(ofSegmentAt index: Int) -> ClosedRange<Double>? {
        guard segments.indices.contains(index) else { return nil }
        let note = segments[index]
        let legacyHalf = max(0, retuneMs / 1000 / 2)
        var lower = note.startSeconds - legacyHalf
        var upper = note.endSeconds + legacyHalf
        guard setADragStores(ofSegmentAt: index).usesSoftJoins else { return lower...upper }
        let slack = Self.consonantMinimumGapSeconds / 2
        lower = min(lower, note.startSeconds - note.durationSeconds / 2 - slack)
        upper = max(upper, note.endSeconds + note.durationSeconds / 2 + slack)
        // A note outside the curve today (an untouched sound) ENTERS it when
        // dragged, so its neighbours are the curve notes around it, joined
        // either to it (after) or to each other across it (before).
        let previous = previousCurveNoteIndex(before: index)
        let next = nextCurveNoteIndex(after: index)
        func softAcross(_ left: NoteSegment, _ right: NoteSegment) -> Bool {
            Self.joinKind(leftEndSeconds: left.endSeconds,
                          rightStartSeconds: right.startSeconds) == .soft
        }
        if let p = previous {
            let neighbour = segments[p]
            if softAcross(neighbour, note) || next.map({ softAcross(neighbour, segments[$0]) }) == true {
                let whole = neighbour.startSeconds
                    - max(legacyHalf, neighbour.durationSeconds / 2 + slack)
                let side = neighbour.startSeconds + neighbour.durationSeconds / 2
                lower = min(lower, neighbour.glideFollow > 0 ? whole : side)
            }
        }
        if let n = next {
            let neighbour = segments[n]
            if softAcross(note, neighbour) || previous.map({ softAcross(segments[$0], neighbour) }) == true {
                let whole = neighbour.endSeconds
                    + max(legacyHalf, neighbour.durationSeconds / 2 + slack)
                let side = neighbour.endSeconds - neighbour.durationSeconds / 2
                upper = max(upper, neighbour.glideFollow > 0 ? whole : side)
            }
        }
        return lower...upper
    }

    /// The set a pitch drag of the note at `index` stores, for its SET-LEVEL
    /// fields: this set with that note bent, through D4-1's one home
    /// (`afterHandEdit(from: self)`), so the reach never restates which sets
    /// a hand edit updates. The bend is always a real move (never 0 c): the
    /// reach answers for a drag that MOVES the note. A drag that moves
    /// nothing changes nothing (the no-op rule: no update, not one sample),
    /// so any window holds for it. Whether the home updates a set depends on
    /// whether a note changed, never on how far, so the notes it returns are
    /// a probe, not the drag's: read only the set-level fields.
    private func setADragStores(ofSegmentAt index: Int) -> PitchEditSet {
        var bent = self
        bent.segments[index].pitchOffsetCents = abs(segments[index].pitchOffsetCents) + 100
        return bent.afterHandEdit(from: self)
    }

    /// ⭐ **D4-1 = (b), THE USER'S RULING (Q-U1, 2026-09-26). FINAL: do not
    /// re-ask, do not soften it.** The handoff page asked "Vocals you tuned
    /// before this update: what should happen?" and the user picked "Update
    /// when I edit them: The first note you drag on an old vocal updates the
    /// whole vocal (also one Undo)." (The design had recommended (a).)
    ///
    /// So `true`: a HAND edit on a vocal that `predatesNaturalTuning` switches
    /// it onto natural tuning through `afterHandEdit(from:)`, in the edit's
    /// own undo step. A hand edit is EVERY per-note change, from the editor
    /// or the wire: pitch, split, slide width and follow, wobble and drift
    /// (and Reset Wobble), the drawn line, a note's Voice, its level, clear
    /// and restore. One rule, "the first time you change a note", so the
    /// vocal never updates on the 2nd or 3rd edit depending on the tool.
    /// ⚠️ **AN EDIT THAT CHANGES NO NOTE IS NOT A CHANGE** (the 2026-09-27
    /// ruling on the user's words, "the first note you DRAG"): Reset Wobble on
    /// a note already as sung, a Restore of a note that is not cleared, a
    /// drag released where it started. It leaves an old vocal exactly as it
    /// is, with no undo step: switching the whole vocal is audible, so a
    /// no-op must have no side effect. `afterHandEdit(from:)` is the ONE home
    /// of both rules; `NaturalTuningHandEditCensusTests` keeps every such
    /// writer routed through it. NOT a hand edit: the set-level switches
    /// (`setClipFormantCorrection`, `setClipConsonantProtection`,
    /// `setClipPitchTransitionSmoothness`: explicit requests, their own field
    /// only), `upgradeToNaturalTuning` (it IS the update), and auto-correct
    /// (it builds a new, seeded set).
    public static let handEditUpgradesLegacyVocal = true

    /// X4's upgrade, pure: the voice size kept, consonants untuned, and
    /// soft joins, at the values a NEW set is seeded with.
    /// `ProjectStore.upgradeToNaturalTuning` (the one-tap line and the wire)
    /// and `afterHandEdit()` (D4-1) both call it.
    ///
    /// ⚠️ **AN EXPLICIT SLOPE IS KEPT** (C4's ruling, the decision C0's doc
    /// left here): `transitionSlopeCentsPerSecond` is filled only when it
    /// is 0 (legacy). A set whose slope a user or agent PICKED
    /// (`setClipPitchTransitionSmoothness`) can still predate natural tuning
    /// (its formant amount is nil), and tapping "update" must not throw that
    /// pick away. The formant amount is set as X4 says.
    ///
    /// ⚠️ **A CHOSEN CONSONANT OFF IS KEPT TOO** (NT-C2-F1, W7-D2, for the
    /// slope's reason): consonants are switched on unless they are
    /// `.offByChoice`. An old vocal whose consonants somebody switched off
    /// keeps them off through the tap AND through D4-1's first hand edit.
    /// That state did not exist before the choice was recorded, so no vocal
    /// that could be updated before it updates differently now.
    public func upgradedToNaturalTuning() -> PitchEditSet {
        var copy = self
        copy.formantCorrection = Self.newSetFormantCorrection
        if copy.consonantProtection != .offByChoice {
            copy.consonantProtection = .on
        }
        if copy.transitionSlopeCentsPerSecond == 0 {
            copy.transitionSlopeCentsPerSecond = Self.defaultTransitionSlope
        }
        return copy
    }

    /// D4-1's update, for a hand edit that CHANGED a note: on a set that
    /// `predatesNaturalTuning` it returns `upgradedToNaturalTuning()` (the
    /// user's ruling (b) of 2026-09-26, "The first note you drag on an old
    /// vocal updates the whole vocal (also one Undo)"); on any other set,
    /// `self`, so only the FIRST such edit updates. It answers "what would a
    /// real edit leave this set as", the question `pitchDragReach` asks.
    ///
    /// ⛔ **A WRITER NEVER CALLS THIS BARE: it calls `afterHandEdit(from:)`**,
    /// which adds the no-op rule. Called bare, a no-op (Reset Wobble on a note
    /// already as sung) would switch a whole old vocal.
    /// `NaturalTuningHandEditCensusTests` refuses a bare call in every
    /// hand-edit writer and transform.
    public func afterHandEdit() -> PitchEditSet {
        guard Self.handEditUpgradesLegacyVocal, predatesNaturalTuning else { return self }
        return upgradedToNaturalTuning()
    }

    /// ⭐ **D4-1's ONE HOME**: this set after a HAND edit that started from
    /// `before` (the set the edit was applied to).
    ///  * The edit changed NO note (`segments == before.segments`): `self`,
    ///    as the edit left it. A no-op has no side effect (the 2026-09-27
    ///    ruling: an edit that changes nothing must not update an old vocal).
    ///  * Otherwise `afterHandEdit()`: an old vocal is updated, any other set
    ///    is left as the edit made it.
    /// The writer stores the result in the edit's own `performEdit`, so the
    /// edit and the update are ONE undo step and undoing it gives back the
    /// old vocal exactly; a no-op stores the set it found, which journals
    /// nothing (`performEdit` records only a real change).
    ///
    /// ⚠️ Every hand edit calls it LAST. The transforms pass `from: self`:
    /// `applyingNotePitchOffsets` (the drag's draft and both commits),
    /// `applyingNoteTransition`, `applyingNoteGlideFollow`,
    /// `applyingNoteShapes` and `applyingNoteVibratos`. The store writers that
    /// edit notes inline (split, clear, level, Voice, Reset Wobble) pass the
    /// table they started from. `NaturalTuningHandEditCensusTests` is the
    /// census. A draft built any other way must call it too, or the line
    /// drawn during a FIRST drag on an old vocal differs from what plays after
    /// the release.
    public func afterHandEdit(from before: PitchEditSet) -> PitchEditSet {
        segments == before.segments ? self : afterHandEdit()
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
///    `clip.moveMany` group-verb precedent). A per-segment key would either
///    make N entries or coalesce two different multi-selects into one.
///    ⭐ **CORRECTED AT m23-ap I4.** This bullet used to end "so it uses
///    `structuralKey` too", which contradicted UI design §8.4 — the design this
///    enum's own header cites. §8.4 gives a GROUP DRAG its own key,
///    `group(clipID:selectionToken:)`, so a second drag of the SAME selection
///    coalesces (one continuous decision, like dragging one note twice) and a
///    drag of a DIFFERENT selection does not. A group edit that is not a drag
///    — clearing or levelling notes (`setClipNotesCleared`/`setClipNoteGain`)
///    — is a deliberate on/off and still passes `structuralKey`.
///
/// The store operations live in `ProjectStore+PitchNoteEdits.swift`.
public enum PitchCorrectionUndoKey {
    /// A pitch drag on one note.
    public static func segment(clipID: UUID, segmentID: UUID) -> String {
        "pitch.segment:\(clipID.uuidString):\(segmentID.uuidString)"
    }

    /// A drift-scale drag on one note: natural tuning's Drift tool (§3b,
    /// C5a-5), which writes `driftScale` alone through a one-item
    /// `ProjectStore.setClipNotesVibrato`.
    public static func drift(clipID: UUID, segmentID: UUID) -> String {
        "pitch.drift:\(clipID.uuidString):\(segmentID.uuidString)"
    }

    /// A wobble edit on one note: the Wobble tool's gesture and the
    /// `clip.setNoteVibrato` verb (`ProjectStore.setClipNoteVibrato`).
    ///
    /// ⭐ **ONE KEY FOR BOTH MECHANISMS, DELIBERATELY.** ⚠️ Corrected at C5a-2
    /// (vibrato-handle design §5.6): the reason is NOT one continuous
    /// sung → flat → synthesised axis. The Wobble tool does not run one range
    /// through flat: pulling down narrows the singer's wobble, and a new
    /// wobble is a separate branch chosen at mouse-down (§5.1). The reason is
    /// the HANDOFF (§6): ONE gesture that crosses the dead zone writes BOTH
    /// scales to 0 (the singer's wobble and drift out) AND the generator's
    /// rate, depth and anchor (the new wobble in). A second key for the
    /// generator would split that one gesture into two undo entries, and the
    /// halfway state undo would land in (flattened, nothing added) is one the
    /// user never saw. The key is the rule, so the rule is stated at the key.
    public static func vibrato(clipID: UUID, segmentID: UUID) -> String {
        "pitch.vibrato:\(clipID.uuidString):\(segmentID.uuidString)"
    }

    /// A wobble edit on a GROUP of selected notes: the Wobble tool's keep
    /// lever on a multi-selection (natural tuning §3b). The `group` key's twin,
    /// built the same way and for the same reason (a second drag of the SAME
    /// selection coalesces, a different selection does not).
    ///
    /// ⚠️ **ITS OWN VERB, NOT `group`'s.** `group` is a PITCH drag's key; a
    /// wobble drag and a pitch drag of the same selection inside the 800 ms
    /// window are two decisions and must be two undo steps.
    public static func vibratoGroup(clipID: UUID, selectionToken: UUID) -> String {
        "pitch.vibratoGroup:\(clipID.uuidString):\(selectionToken.uuidString)"
    }

    /// A drift edit on a GROUP of selected notes: the Drift tool on a
    /// multi-selection (natural tuning §3b). `vibratoGroup`'s twin, with its
    /// own verb so a drift drag and a wobble drag of one selection never fold.
    public static func driftGroup(clipID: UUID, selectionToken: UUID) -> String {
        "pitch.driftGroup:\(clipID.uuidString):\(selectionToken.uuidString)"
    }

    /// A pitch drag on a GROUP of selected notes (m23-ap I4, UI design §8.4).
    ///
    /// `selectionToken` is stable for the life of ONE selection — the pitch
    /// editor re-mints it whenever the set of selected notes changes, and
    /// never otherwise — so a second drag of the same selection inside the
    /// journal's 800 ms window coalesces into the first, and a drag of a
    /// different selection starts a new undo entry. ONE entry covers every
    /// note the drag moved (`ProjectStore.setClipNotePitchOffsets`).
    ///
    /// ⚠️ **NOT THE SEGMENT KEY OF ANY MEMBER.** A one-note drag still uses
    /// `segment(clipID:segmentID:)`, byte-identical to before; a group drag
    /// that happened to share a member with it must not fold into it.
    public static func group(clipID: UUID, selectionToken: UUID) -> String {
        "pitch.group:\(clipID.uuidString):\(selectionToken.uuidString)"
    }

    /// A slide-width edit on the join to the RIGHT of one note (natural
    /// tuning §4.e, `ProjectStore.setClipNoteTransition`): the rear-edge drag
    /// and `clip.setNoteTransition`. Its own verb, so a width drag and a
    /// pitch drag of the same note inside the 800 ms window are two undo
    /// steps; two width drags of the same join fold into one.
    public static func transition(clipID: UUID, segmentID: UUID) -> String {
        "pitch.transition:\(clipID.uuidString):\(segmentID.uuidString)"
    }

    /// Structural and deliberate on/off edits: `nil` — never coalesces.
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
/// **THE PHASE IS ANCHORED AT A STORED SOURCE SECOND —
/// `sin(2π · rate · (t − vibratoPhaseAnchorSeconds))` — NEVER AT THE NOTE'S
/// START**, and that choice is defensive:
///
///  * `PitchEditSet.canonical` heals overlaps FIRST-WINS by moving a later
///    segment's `startSeconds` forward. A start-anchored phase would silently
///    re-phase the vibrato of a note the user never touched.
///  * Splitting a note (editor C3) makes two segments from one. Start-anchored,
///    identical generator settings would restart the sine at the split; with a
///    STORED anchor, which the split copies to both halves, the two halves
///    stay one continuous vibrato.
///
/// The anchor defaults to 0, which is source second zero: the phase every set
/// had before the field existed (m23-ap C5a-1, vibrato-handle design §7), bit
/// for bit, because `t − 0.0 == t` in IEEE arithmetic. The wobble editor
/// stores the note's centre instead, so a speed change stretches the cycles
/// around the knob rather than moving the phase by `2π · t · Δrate`, which a
/// note 30 s into a take would feel as a jump of whole cycles (design V6).
///
/// The ENVELOPE (`vibratoOnsetSeconds`) is anchored at the note start instead,
/// because a fade-in is a statement about the note and a shortened note should
/// re-anchor its fade. `generatorIsContinuousAcrossASplit` pins the phase half.
/// On a retimed curve both anchors move onto the edited axis: the phase is
/// `sin(2π · rate · (W(t) − W(anchor)))`, which at the default is anchored at
/// edited second 0 (`W(0) = 0` exactly), and the fade is anchored at
/// `W(startSeconds)`.
///
/// **EXTENSION SEAM (editor C5b, freehand ⌘+drag).** The generator is a TERM
/// IN A SUM, not "the note's shape". A later per-note contour OVERRIDE is
/// another term in the same sum inside the same gate, and adding one does not
/// disturb anything here. What it WOULD need is a rule for override + generator
/// together; that is a UI decision, not a representation one, and nothing in
/// this layout forecloses it.
///
/// ⭐ **C5b-1 FILLED THE SEAM, AS A DELTA, NOT AN OVERRIDE** (design
/// `2026-09-24-pitch-editor-timing-and-freehand.md` §5.1-§5.3). Inside a
/// note's gate the sum is four terms: `constant + shaping(s) + generator(e ?? s)
/// + drawnShape(s)`. The drawn shape ADDS, for the generator's reason
/// (replacing needs `− sung(t)`, which needs the contour), so "override +
/// generator" is simply both terms. It reads SOURCE time and is held at both
/// ends; it never enters the formant curve (the envelope follows the constant
/// move only); and it is local to its own span, so at a soft join it reaches
/// the neighbour only through the gates' crossfade, never through the tilt
/// or the join's width, which read offsets alone.
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
///
/// ⭐ **SOFT JOINS (natural tuning §4, NT-C C4).** On a set that
/// `usesSoftJoins`, each join between neighbouring curve notes that
/// `PitchEditSet.joinKind` calls `.soft` takes ONE width from
/// `PitchEditSet.softJoin` (it grows with the size of the jump, capped by the
/// set's slope) and ONE edge, on both sides, so the two gates are exactly
/// complementary there and never dip (F12 gone). A sung slide that follows
/// its neighbours (`glideFollow`) TILTS from the previous note's offset to
/// the next one's. Joins facing a GAP, and every join of a LEGACY set, keep
/// the per-note ramps above, bit for bit.
public struct PitchCorrectionCurve: Sendable, Equatable {
    /// One note's precomputed contribution.
    fileprivate struct Span: Sendable, Equatable {
        let startSeconds: Double
        let endSeconds: Double
        /// Half the RISE ramp's width, and the second the rise is centred on
        /// (natural tuning §4.b.2). On a LEGACY set, and at every edge a soft
        /// join does not reach, the half is today's `min(ramp/2, duration/2)`
        /// and the centre is `startSeconds`, the same Double, so the gate
        /// reads exactly the values it always read. A soft join replaces
        /// both with the ONE width and edge it shares with the note before
        /// (`PitchEditSet.softJoin`); across an R15 short hole that edge is
        /// the hole's midpoint.
        var halfRampIn: Double
        var riseCentreSeconds: Double
        /// The FALL ramp's half and centre: `halfRampIn`'s twin at the end.
        var halfRampOut: Double
        var fallCentreSeconds: Double
        /// `pitchOffsetCents / 100`.
        let constantSemitones: Double
        /// §4.b.2 step 3, the TILT of a sung slide that follows its
        /// neighbours (`NoteSegment.glideFollow`): the previous and next
        /// SOFT-joined curve notes' own offsets, semitones (0 across a gap),
        /// and the follow amount. `bridgeAmount` EXACTLY 0 means no tilt,
        /// and both evaluators branch on it rather than adding a zero (the
        /// generator's rule; see the `-0.0` note in `semitones`).
        var bridgeFromSemitones: Double
        var bridgeToSemitones: Double
        var bridgeAmount: Double
        /// `NoteSegment.formantOffsetSemitones`, verbatim. Read ONLY by the
        /// formant evaluator (natural tuning §1(b)); the pitch loop never
        /// touches it, so it cannot move a pitch bit.
        let formantOffsetSemitones: Double
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
        /// `NoteSegment.vibratoPhaseAnchorSeconds` ON THE GENERATOR'S AXIS
        /// (C5a-1, design §7.1/§7.6): the stored value verbatim on an untimed
        /// curve, `W(anchor)` on a retimed one, computed once in `make` by the
        /// same presence branch as `envelopeStartSeconds`.
        let vibratoPhaseAnchorSeconds: Double
        /// C5b-1: the DRAWN shape, semitones per grid sample
        /// (`NoteSegment.shapeTenthsOfCents` ÷ 1000), or EMPTY when the note
        /// has none (`hasShape`). Empty means no term: the evaluator branches
        /// on it rather than adding a zero (the generator's rule).
        let shapeSemitones: [Double]
        /// `NoteSegment.shapeStartIndex` as a Double: sample `k` is read at
        /// grid position `sourceSecond · shapeGridHz − shapeStartGrid = k`.
        let shapeStartGrid: Double
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

    /// The set's `PitchEditSet.formantCorrection`, carried verbatim for the
    /// formant evaluator (natural tuning §1(b)). `nil` = legacy, and the
    /// evaluator then falls back to the clip's `formantPreserve` flag, which
    /// it is HANDED per call rather than stored: see
    /// `formantSemitones(atSourceSecond:editedSecond:formantPreserve:)`.
    public let formantCorrection: Double?

    fileprivate let spans: [Span]

    /// p2-span: the SEARCH's key, the running maximum of
    /// `fallCentreSeconds + halfRampOut` (on a legacy set exactly
    /// `endSeconds + halfRamp`) over `spans[0...i]`. The reach itself is NOT
    /// non-decreasing in start order: `halfRamp` clamps to half the note, so
    /// a short note after a long one reaches LESS far (NT-G: `[2.1, 2.09]`),
    /// and a binary search over the raw reach could land past a span still
    /// open. Every span before the first index this passes has closed. Where
    /// the reach already ascends this IS the reach, value for value, so the
    /// search lands where it always did.
    fileprivate let spanReachPrefixMax: [Double]
    /// p2-span: the EARLY EXIT's key, the minimum of
    /// `riseCentreSeconds − halfRampIn` (on a legacy set exactly
    /// `startSeconds − halfRamp`) over `spans[i...]`. A long note after a
    /// short one OPENS before it, so stopping at the first span not yet open
    /// could stop short of a later one that is. Below this nothing from `i`
    /// on is open. Where the openings ascend it IS the span's own opening.
    fileprivate let spanOpenSuffixMin: [Double]

    /// The formant BASE's step function (§1(b)): the start second and the
    /// detected f0 of every note whose `detectedHz` is a measurement,
    /// ascending. Built from ALL of the set's notes, not from `spans`: an
    /// untouched note still tells the stretcher where the singer's f0 is.
    fileprivate let formantBaseStarts: [Double]
    fileprivate let formantBaseValues: [Double]

    fileprivate init(clipPitchShiftSemitones: Double,
                     spans: [Span],
                     unresolvedShapingSegmentIDs: [UUID],
                     timeWarp: PitchTimeWarp?,
                     formantCorrection: Double?,
                     formantBaseStarts: [Double],
                     formantBaseValues: [Double]) {
        self.clipPitchShiftSemitones = clipPitchShiftSemitones
        self.spans = spans
        (self.spanReachPrefixMax, self.spanOpenSuffixMin) = Self.searchBounds(spans)
        self.unresolvedShapingSegmentIDs = unresolvedShapingSegmentIDs
        self.timeWarp = timeWarp
        self.formantCorrection = formantCorrection
        self.formantBaseStarts = formantBaseStarts
        self.formantBaseValues = formantBaseValues
    }

    /// Window of the v1 drift/vibrato separator (`PitchCorrectionMath.movingAverage`,
    /// an edge-truncated boxcar): drift is the contour averaged over this long,
    /// vibrato is what is left.
    ///
    /// ⭐ **SINCE natural tuning §3 (W7-C3) THE v1 SEPARATOR SHAPES ONLY
    /// EQUAL-SCALE NOTES, WHERE ITS SPLIT CANCELS.** When `driftScale ==
    /// vibratoScale`, which is every set `PitchAutoCorrect` produces, Hard Tune
    /// included, `(s−1)·drift + (s−1)·vib == (s−1)·(drift + vib)`, so this
    /// window reaches only the low bits of those renders. It stays exactly as it
    /// was so that they stay bit for bit (`PitchSeparatorV2Tests`, G1). It is
    /// NOT a good separator: its response at 5.5 Hz is −0.2155 (16 ms frames),
    /// so it passes 121 % of a sung wobble into "vibrato" and inverts the rest.
    /// A note whose scales DIFFER takes the v2 kernel instead
    /// (`separatedDriftWindowSeconds`).
    public static let driftWindowSeconds: Double = 0.25

    /// Natural tuning §3b (W7-C3): the v2 separator's boxcar length L. An
    /// UNEQUAL-scale note's drift is its contour averaged by a TRIANGULAR
    /// kernel, two cascaded centred boxcars of this length
    /// (`PitchCorrectionMath.triangularAverage`). Its response is sinc² ≥ 0, so
    /// no band is passed into "vibrato" at more than 100 % and nothing is
    /// inverted.
    ///
    /// PICKED 2026-09-27 by G3's pre-registered FALLBACK rule
    /// (`NaturalTuningDriftVibratoTests`). The primary rule, the smallest L in
    /// {0.16, 0.20, 0.25} s that passes every G3 cell at 110 Hz, found none: the
    /// (1,0) cell kept 0.211 (0.16 s) to 0.237 (0.25 s) of the sung wobble
    /// against ≤ 0.2 for every kernel. The fallback, the same rule over the
    /// separator's own legs only, picks 0.16 s. Its measured cost, not part of
    /// the rule: under Drift 0 at 220 Hz a 4 Hz wobble keeps 0.886 of itself
    /// at 0.16 s (0.991 at 0.25 s), where a 5.5 Hz one keeps 0.994. A change
    /// here changes the audio of every unequal-scale render: bump
    /// `PitchRenderContour.separatedShapingVersion`, never `shapingVersion`.
    public static let separatedDriftWindowSeconds: Double = 0.16

    /// Natural tuning §3b (W7-C3): how the v2 kernel treats a note's ends. Picked
    /// with `separatedDriftWindowSeconds` by the pre-registered tie-break
    /// (truncate); on G3's 4 s notes the two edges read identically, because
    /// both edges sit inside the measured window's trim. Versioned with it.
    public static let separatedDriftEdge: PitchCorrectionMath.AverageEdge = .truncate

    /// Natural tuning §3g (W7-C3): the shortest note, seconds, whose drift and
    /// wobble the v2 separator tells apart, by G3's pre-registered short-note
    /// rule (`NaturalTuningDriftVibratoTests`, "§8 minimumSeparableSeconds …"):
    /// the shortest tested length that, together with every longer tested
    /// length, keeps a Drift-0 note's 5.5 Hz wobble within [0.8, 1.2] of the
    /// ideal AND removes at least half its drift, at 110 Hz, through the
    /// product render. MEASURED 2026-09-27: 0.5 s (0.4 s removed 47 % of the
    /// drift; 0.2 and 0.3 s notes did not detect as one note). Nothing reads it
    /// yet: it is the length below which a Drift control should warn. The test
    /// named above re-derives it and fails if the rule's answer moves.
    public static let minimumSeparableSeconds: Double = 0.5

    /// Natural tuning §3b (W7-C3): WHICH drift/vibrato separator `make` gives a
    /// note whose scales DIFFER (`NoteSegment.takesSeparatedShaping`).
    ///
    /// ⚠️ **AN EQUAL-SCALE NOTE ALWAYS TAKES THE v1 LINES, WHATEVER THIS SAYS.**
    /// That branch keeps every Hard Tune and preset render bit for bit (G1), and
    /// no separator value can reach it.
    ///
    /// `.production` is the only value the app ever passes. The others exist so
    /// the physics gate (`NaturalTuningDriftVibratoTests`, G3) can render its
    /// controls through the SHIPPING path: `StretchRenderCache` carries one per
    /// instance (a test initialiser; the app's is `.production`), never a global
    /// switch, because tests render in parallel.
    public enum Separator: Sendable, Hashable {
        /// v2: `triangularAverage` over `separatedDriftWindowSeconds`, with
        /// `separatedDriftEdge`.
        case production
        /// v1 for unequal notes too: `movingAverage` over `driftWindowSeconds`,
        /// the separator before natural tuning §3. G3's negative control.
        case v1Everywhere
        /// v2's kernel at an explicit L and edge. G3's sweep.
        case triangular(windowSeconds: Double, edge: PitchCorrectionMath.AverageEdge)
        /// Any centred kernel, one tap per contour frame (odd count), edges
        /// truncated and renormalised. G3's negative-lobe plant.
        case kernelTaps([Double])

        /// The drift (slow) part of an unequal-scale note's contour, `cents`
        /// sampled every `stepSeconds`.
        func separatedDrift(_ cents: [Double], stepSeconds: Double) -> [Double] {
            switch self {
            case .production:
                return PitchCorrectionMath.triangularAverage(
                    cents, windowSeconds: PitchCorrectionCurve.separatedDriftWindowSeconds,
                    stepSeconds: stepSeconds, edge: PitchCorrectionCurve.separatedDriftEdge)
            case .v1Everywhere:
                return PitchCorrectionMath.movingAverage(
                    cents, windowSeconds: PitchCorrectionCurve.driftWindowSeconds,
                    stepSeconds: stepSeconds)
            case .triangular(let windowSeconds, let edge):
                return PitchCorrectionMath.triangularAverage(
                    cents, windowSeconds: windowSeconds, stepSeconds: stepSeconds, edge: edge)
            case .kernelTaps(let taps):
                return PitchCorrectionMath.centredAverage(cents, weights: taps, edge: .truncate)
            }
        }
    }

    /// TEST SEAM (natural tuning §3 G1, W7-C3): every span's stored shaping
    /// samples, in span order, exactly as `make` built them. `internal`, so only
    /// an `@testable` import reaches it; nothing in the product reads it.
    var shapingSamplesForTesting: [(startSeconds: Double, stepSeconds: Double, semitones: [Double])] {
        spans.map { ($0.shapingStartSeconds, $0.shapingStepSeconds, $0.shapingSemitones) }
    }

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
    ///   - separator: natural tuning §3 (W7-C3): the drift/vibrato separator for
    ///     notes whose scales DIFFER. The app always passes nothing
    ///     (`.production`); see `Separator`. Equal-scale notes never read it.
    public static func make(editSet: PitchEditSet,
                            contour: [ClipPitchFrame] = [],
                            contourValueOffsetSeconds: Double = 0,
                            clipPitchShiftSemitones: Double = 0,
                            timeWarp: PitchTimeWarp? = nil,
                            separator: Separator = .production) -> PitchCorrectionCurve {
        let base = PitchCorrectionMath.finite(clipPitchShiftSemitones, default: 0)
        guard !editSet.segments.isEmpty else {
            return PitchCorrectionCurve(clipPitchShiftSemitones: base,
                                        spans: [], unresolvedShapingSegmentIDs: [],
                                        timeWarp: timeWarp,
                                        formantCorrection: editSet.formantCorrection,
                                        formantBaseStarts: [], formantBaseValues: [])
        }
        // The formant base's steps (§1(b)), from EVERY note that carries a
        // measured f0. ⚠️ **A SOUND (`.unpitched`) IS SKIPPED:** its
        // `detectedHz` is a neighbour's pitch BORROWED as a drawing anchor
        // (`PitchUnpitchedFinder`'s `anchorHz`), not the singer's f0 at that
        // moment. A non-positive value (`init` heals non-finite to 0) is no
        // measurement either. Segments are canonical, so the steps ascend.
        var baseStarts: [Double] = []
        var baseValues: [Double] = []
        for segment in editSet.segments
        where segment.origin != .unpitched && segment.detectedHz > 0 && segment.detectedHz.isFinite {
            baseStarts.append(segment.startSeconds)
            baseValues.append(segment.detectedHz)
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
        // Natural tuning §4: the soft pass below needs each span's note. A
        // LEGACY set (`usesSoftJoins` false, THE one predicate) collects
        // nothing and never reaches the pass, so its spans are exactly the
        // ones this loop has always built.
        let softJoins = editSet.usesSoftJoins
        var curveNotes: [NoteSegment] = []

        // U-A: an untouched SOUND builds no span at all (`entersPitchCurve`,
        // the one predicate, argues why): skipping it here is what keeps a
        // table with sounds rendering byte for byte as the same table
        // without them. A moved sound comes in like any note (R21).
        for segment in editSet.segments where segment.entersPitchCurve {
            if softJoins { curveNotes.append(segment) }
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
                        // ⛔ Natural tuning §3b (W7-C3): BYTE IDENTITY BY
                        // BRANCH, NOT BY ALGEBRA. `PitchSeparatorV2Tests` (G1)
                        // is the guard. An EQUAL-scale note, every set the
                        // product has ever written, runs the v1 lines below
                        // EXACTLY as they stood before v2: its split cancels,
                        // but the expression still carries `macro` in its low
                        // bits, so any other separator here would move every
                        // Hard Tune render. Only an unequal-scale note reaches
                        // `separator`. Edit the first branch → bump
                        // `PitchRenderContour.shapingVersion` (re-keys Hard
                        // Tune); edit the second → bump
                        // `separatedShapingVersion` only.
                        if !segment.takesSeparatedShaping {
                            let drift = PitchCorrectionMath.movingAverage(
                                cents, windowSeconds: driftWindowSeconds, stepSeconds: step)
                            shaping = zip(cents, drift).map { total, macro in
                                let vibrato = total - macro
                                return ((segment.driftScale - 1) * macro
                                    + (segment.vibratoScale - 1) * vibrato) / 100
                            }
                        } else {
                            let drift = separator.separatedDrift(cents, stepSeconds: step)
                            shaping = zip(cents, drift).map { total, macro in
                                let vibrato = total - macro
                                return ((segment.driftScale - 1) * macro
                                    + (segment.vibratoScale - 1) * vibrato) / 100
                            }
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

            // The LEGACY half, today's expression, stored in BOTH halves; the
            // centres are the note's own edges. `softened` below rewrites
            // only the edges a soft join reaches.
            let halfRamp = min(ramp / 2, segment.durationSeconds / 2)
            spans.append(Span(
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                halfRampIn: halfRamp,
                riseCentreSeconds: segment.startSeconds,
                halfRampOut: halfRamp,
                fallCentreSeconds: segment.endSeconds,
                constantSemitones: segment.pitchOffsetCents / 100,
                bridgeFromSemitones: 0,
                bridgeToSemitones: 0,
                bridgeAmount: 0,
                formantOffsetSemitones: segment.formantOffsetSemitones,
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
                    forSourceSecond: segment.startSeconds) ?? segment.startSeconds,
                // C5a-1: the phase anchor, by the same presence branch. At the
                // default 0 a retimed curve stores `W(0)`, and `W` returns a
                // non-positive input verbatim (`PitchTimeWarp.interpolate`), so
                // it is exactly 0.0 there too and the edited-time phase is the
                // pre-anchor phase, bit for bit.
                vibratoPhaseAnchorSeconds: timeWarp?.editedSecond(
                    forSourceSecond: segment.vibratoPhaseAnchorSeconds)
                    ?? segment.vibratoPhaseAnchorSeconds,
                // C5b-1: precomputed once per curve, and only for a note that
                // `hasShape` (the one predicate), so every other span stores
                // the empty array the evaluator skips. SOURCE time needs no
                // warp here: the grid is on the source axis.
                shapeSemitones: segment.hasShape
                    ? segment.shapeTenthsOfCents.map { Double($0) / 1000 } : [],
                shapeStartGrid: segment.hasShape ? Double(segment.shapeStartIndex) : 0))
        }
        if softJoins {
            spans = Self.softened(spans, notes: curveNotes, editSet: editSet)
        }
        return PitchCorrectionCurve(clipPitchShiftSemitones: base,
                                    spans: spans,
                                    unresolvedShapingSegmentIDs: unresolved,
                                    timeWarp: timeWarp,
                                    formantCorrection: editSet.formantCorrection,
                                    formantBaseStarts: baseStarts,
                                    formantBaseValues: baseValues)
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
        // at most half its width past an edge, so only spans near the hit
        // point can contribute. Scan from the first span that could still be
        // open at `sourceSecond`, and stop once no later span has opened.
        // ⚠️ p2-span: BOTH bounds come from the precomputed
        // `spanReachPrefixMax` / `spanOpenSuffixMin`, never from the span in
        // hand. A short note's clamped ramp reaches less far than a long
        // predecessor's and opens later than a long successor's, so neither
        // the reach nor the opening ascends in start order, and the per-span
        // bounds skipped open ramps (for 220 ms, 41 c per 100 c of move, in
        // `PitchSpanSearchTests`' 500 ms-retune cases).
        // `PitchSpanSearchTests` holds this loop to a linear scan, bit for bit.
        var index = Self.firstSpanIndex(spanReachPrefixMax, notEndedBefore: sourceSecond)
        while index < spans.count {
            let span = spans[index]
            if sourceSecond < spanOpenSuffixMin[index] { break }
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
                //
                // Natural tuning §4.b.3: a following slide's TILT is ADDED
                // to its own constant (so dragging the slide still moves
                // it), in source time like the gate, and only when present:
                // BRANCH ON PRESENCE, never `+ 0`. Everything that is not
                // a followed slide takes today's expression untouched.
                var constant = span.constantSemitones
                if span.bridgeAmount != 0 {
                    constant += Self.bridge(span, at: sourceSecond)
                }
                var contribution = constant
                    + Self.shaping(span, at: sourceSecond)
                if span.vibratoDepthSemitones != 0 {
                    contribution += Self.generatedVibrato(span, at: generatorSecond)
                }
                // C5b-1 (design §5.3): the DRAWN shape, the fourth term, in
                // SOURCE time like the gate and the shaping. BRANCH ON
                // PRESENCE, never `+ 0`, so every shape-free span keeps
                // today's expression bit for bit.
                if !span.shapeSemitones.isEmpty {
                    contribution += Self.drawnShape(span, at: sourceSecond)
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

    // MARK: Natural tuning §1(b): the formant curve (NT-C C1)

    /// The formant shift the stretcher should apply at `sourceSecond`, in
    /// semitones RELATIVE TO THE SOURCE ENVELOPE (signalsmith's
    /// `compensatePitch = true`): `0` keeps the singer's envelope where the
    /// throat put it, the note's own move follows the pitch (the "chipmunk"),
    /// and `−2` is deeper than sung. Design
    /// `docs/design/2026-09-25-natural-tuning.md` §1(b), R6:
    ///
    ///     spanFormant_i = (1 − c) · constantSemitones_i + formantOffsetSemitones_i
    ///     F(t)          = clipPart + Σ gate_i(t) · spanFormant_i / norm(t)
    ///     clipPart      = formantPreserve ? 0 : clipPitchShiftSemitones
    ///     c             = formantCorrection ?? (formantPreserve ? 1 : 0)
    ///
    /// ⚠️ **`formantPreserve` IS A PARAMETER, NOT STORED, ON PURPOSE.** It is
    /// `Clip.formantPreserve`, a CLIP fact, and every other stored property
    /// of this type comes from the edit set, the contour, the clip transpose
    /// and the warp, which the pitch editor's display curve and the render's
    /// curve are built from alike (`PitchEditorDisplayMatchesRenderTests`
    /// compares the two as OBJECTS). Storing the flag would make those two
    /// objects differ on every `formantPreserve` clip unless both builders
    /// passed it; as a non-defaulted argument here, no caller can forget it.
    ///
    /// ⚠️ **THE EDIT TERM IS THE NOTE'S CONSTANT MOVE ONLY.** No drift or
    /// vibrato shaping and no generator: a real singer's formants stay put
    /// through vibrato, so the envelope must never wobble with a kept or a
    /// synthesised one. Hence `editedSecond` enters nothing but the
    /// non-finite guard; it is accepted so that this evaluator and
    /// `semitones(atSourceSecond:editedSecond:)` fall back to their clip
    /// terms at exactly the same hops, and so the render's two per-hop calls
    /// take the same arguments.
    ///
    /// **Same gates, same scan, same normaliser as the pitch curve** (§1(b),
    /// X7): `gate(_:at:)`, `firstSpanIndex` and "divide only when the gates
    /// over-sum", over the SAME `spans`. So a per-note offset ramps over the
    /// same `retuneMs` window as the move, two abutting notes crossfade their
    /// offsets, and a join §4 later widens is widened for the formant too. Only the
    /// LOOP is a second copy: see the `-0.0` banner in `semitones` for why
    /// the pitch loop is never refactored into a shared helper.
    ///
    /// ⚠️ An offset is read only on a segment that has a span
    /// (`NoteSegment.entersPitchCurve`), which is exactly what
    /// `PitchEditSet.engagesFormantCurve` counts: an untouched SOUND's
    /// offset neither engages the curve nor is read, so it can never switch
    /// the formant stage on for a value nothing applies.
    ///
    /// Pure and total: a non-finite input, or a result that came out
    /// non-finite, returns `clipPart`.
    public func formantSemitones(atSourceSecond sourceSecond: Double,
                                 editedSecond: Double?,
                                 formantPreserve: Bool) -> Double {
        let clipPart = formantPreserve ? 0 : clipPitchShiftSemitones
        guard sourceSecond.isFinite else { return clipPart }
        guard !spans.isEmpty else { return clipPart }
        if let editedSecond, !editedSecond.isFinite { return clipPart }
        let correction = formantCorrection ?? (formantPreserve ? 1 : 0)
        let follow = 1 - correction

        var weighted = 0.0
        var totalGate = 0.0
        // The pitch loop's scan, verbatim in shape: canonical spans, ramps
        // reach at most half their width past an edge, and p2-span's two
        // precomputed bounds (see the pitch loop for why not the span's own).
        var index = Self.firstSpanIndex(spanReachPrefixMax, notEndedBefore: sourceSecond)
        while index < spans.count {
            let span = spans[index]
            if sourceSecond < spanOpenSuffixMin[index] { break }
            let gate = Self.gate(span, at: sourceSecond)
            // Flush a vanishing gate, as the pitch loop does.
            if gate > 1e-12 {
                // §4 / X7: a followed slide's tilt is part of the note's
                // CONSTANT move (the correction, not the singer's shape), so
                // the formant follows it exactly as it follows the constant,
                // by the same presence branch as the pitch loop. At the new
                // sets' `c` = 1 `follow` is 0 and the tilt cannot reach F.
                var constant = span.constantSemitones
                if span.bridgeAmount != 0 {
                    constant += Self.bridge(span, at: sourceSecond)
                }
                let spanFormant = follow * constant + span.formantOffsetSemitones
                weighted += gate * spanFormant
                totalGate += gate
            }
            index += 1
        }
        guard totalGate > 1e-12 else { return clipPart }
        let blended = totalGate > 1 ? weighted / totalGate : weighted
        let total = clipPart + blended
        return total.isFinite ? total : clipPart
    }

    /// `formantSemitones(atSourceSecond:editedSecond:formantPreserve:)` for a
    /// caller holding only the source second: the edited second comes from
    /// this curve's own warp, exactly as `semitones(atSourceSecond:)` does it.
    public func formantSemitones(atSourceSecond sourceSecond: Double,
                                 formantPreserve: Bool) -> Double {
        formantSemitones(atSourceSecond: sourceSecond,
                         editedSecond: timeWarp?.editedSecond(forSourceSecond: sourceSecond),
                         formantPreserve: formantPreserve)
    }

    /// The lowest formant base this curve ever returns, Hz (§1(b)). Below it a
    /// detection is not a sung f0 the envelope estimate should trust, and a
    /// base must never reach 0 (the next doc says why).
    public static let formantBaseFloorHz: Double = 50

    /// The f0 HINT for the formant stage at `sourceSecond`, Hz (§1(b), R3):
    /// a STEP function over the set's notes.
    ///  * the `detectedHz` of the note covering `sourceSecond`;
    ///  * between notes, the LAST note's value is held;
    ///  * before the first note, the FIRST note's value;
    ///  * a SOUND (`.unpitched`) is skipped: its `detectedHz` is borrowed from
    ///    a neighbour to draw it, never measured (the steps are built in
    ///    `make`, which says so);
    ///  * a non-finite or non-positive `detectedHz` is skipped;
    ///  * the result is floored at `formantBaseFloorHz`.
    ///
    /// ⛔ **NEVER 0.** A base of 0 tells signalsmith to estimate f0 itself,
    /// an estimator upstream calls "VERY rough", smoothed by an IIR across
    /// blocks that a window render cannot reproduce. An explicit base buys
    /// DETERMINISM and a trusted f0 (R3). With no measured note at all this
    /// returns the floor; a non-finite `sourceSecond` reads as "before the
    /// first note". Neither is ever 0.
    ///
    /// Source seconds, like the gates: the base describes the SUNG audio,
    /// which the stretcher moves together with the note. `detectedHz` is
    /// never changed by an edit, so a pure function of stored data: a window
    /// render reproduces it exactly.
    public func formantBaseHz(atSourceSecond sourceSecond: Double) -> Double {
        let floor = Self.formantBaseFloorHz
        guard let first = formantBaseValues.first else { return floor }
        guard sourceSecond.isFinite else { return max(floor, first) }
        // The last step whose start is at or before `sourceSecond`: the note
        // covering it, or the last one to end before it. None ⇒ the first.
        var low = 0
        var high = formantBaseStarts.count
        while low < high {
            let mid = (low + high) / 2
            if formantBaseStarts[mid] <= sourceSecond {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let hz = low == 0 ? first : formantBaseValues[low - 1]
        return max(floor, hz)
    }

    /// The boundary ramp, 0 outside the note and 1 in its middle, C¹ at both
    /// ends (§6.4: smooth inside a note, fast but never instantaneous across a
    /// boundary — a map change moves the spectral envelope discontinuously, and
    /// phase-0 §5.4 measured the resulting level dip at −5.11 dB for an
    /// instantaneous 2-semitone jump against −1.20 dB spread over three hops).
    ///
    /// Natural tuning §4.b.3: the rise reads `halfRampIn` about
    /// `riseCentreSeconds` and the fall `halfRampOut` about
    /// `fallCentreSeconds`. ⭐ **ON A LEGACY SET THIS IS TODAY'S GATE BIT FOR
    /// BIT:** both halves hold the same `min(ramp/2, duration/2)` and the
    /// centres are `startSeconds`/`endSeconds` themselves, so each smoothstep
    /// takes the same arguments; a zero (or non-positive, or NaN) half makes
    /// that edge a hard step, and the product of two `1`/`0` steps is the
    /// `1`/`0` today's `half > 0` guard returned.
    fileprivate static func gate(_ span: Span, at t: Double) -> Double {
        let halfIn = span.halfRampIn
        let rise: Double
        if halfIn > 0 {
            rise = smoothstep((t - (span.riseCentreSeconds - halfIn)) / (2 * halfIn))
        } else {
            rise = t >= span.riseCentreSeconds ? 1 : 0
        }
        let halfOut = span.halfRampOut
        let fall: Double
        if halfOut > 0 {
            fall = 1 - smoothstep((t - (span.fallCentreSeconds - halfOut)) / (2 * halfOut))
        } else {
            fall = t < span.fallCentreSeconds ? 1 : 0
        }
        return rise * fall
    }

    /// Natural tuning §4.b.3: a following slide's TILT at source second `t`,
    /// semitones, before the gate: `g · (from + (to − from) · u)` with `u` a
    /// smoothstep across the note's OWN span, so the tilt adds no slope at
    /// either join and stays C¹ with the crossfades. The caller adds it only
    /// when `bridgeAmount != 0`.
    fileprivate static func bridge(_ span: Span, at t: Double) -> Double {
        let length = span.endSeconds - span.startSeconds
        let u = length > 0 ? smoothstep((t - span.startSeconds) / length) : 0
        return span.bridgeAmount
            * (span.bridgeFromSemitones + (span.bridgeToSemitones - span.bridgeFromSemitones) * u)
    }

    /// Natural tuning §4.b.2 steps 2 and 3, R15: the SOFT pass over a set
    /// that `usesSoftJoins`. `spans` arrive with legacy halves and centres,
    /// one per `notes[i]` (the curve notes, `entersPitchCurve`, in order).
    ///  * Each join between neighbouring curve notes that
    ///    `PitchEditSet.joinKind` calls `.soft` and that
    ///    `PitchEditSet.softJoin` gives a width gets ONE half and ONE edge on
    ///    both sides (the left note's fall, the right note's rise), so the
    ///    two gates are complementary and sum to exactly 1: no F12 dip (I2).
    ///    A soft join with no width rule (slope 0, no explicit width) keeps
    ///    its legacy halves and edges. Every GAP keeps them too (§2's
    ///    protection: a join facing a silence or a sound is never widened).
    ///  * Each note with `glideFollow > 0` gets its bridge: the previous and
    ///    next curve notes' OWN offsets across SOFT joins (0 across a gap or
    ///    at an end), never their bridged values (no recursion).
    /// O(n), once per curve; the per-hop evaluators only read the result.
    fileprivate static func softened(_ spans: [Span], notes: [NoteSegment],
                                     editSet: PitchEditSet) -> [Span] {
        guard spans.count == notes.count, !spans.isEmpty else { return spans }
        var out = spans
        let count = notes.count
        var softAfter = [Bool](repeating: false, count: count)
        for index in 0..<(count - 1) {
            softAfter[index] = PitchEditSet.joinKind(
                leftEndSeconds: notes[index].endSeconds,
                rightStartSeconds: notes[index + 1].startSeconds) == .soft
        }
        for index in 0..<count where notes[index].glideFollow > 0 {
            out[index].bridgeFromSemitones = index > 0 && softAfter[index - 1]
                ? notes[index - 1].pitchOffsetCents / 100 : 0
            out[index].bridgeToSemitones = softAfter[index]
                ? notes[index + 1].pitchOffsetCents / 100 : 0
            out[index].bridgeAmount = notes[index].glideFollow
        }
        for index in 0..<(count - 1) where softAfter[index] {
            guard let join = PitchEditSet.softJoin(
                left: notes[index], right: notes[index + 1], retuneMs: editSet.retuneMs,
                slopeCentsPerSecond: editSet.transitionSlopeCentsPerSecond) else { continue }
            out[index].halfRampOut = join.halfWidthSeconds
            out[index].fallCentreSeconds = join.edgeSeconds
            out[index + 1].halfRampIn = join.halfWidthSeconds
            out[index + 1].riseCentreSeconds = join.edgeSeconds
        }
        return out
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

    /// C5b-1 (design §5.3): the DRAWN shape's term at SOURCE second `t`,
    /// semitones, before the gate. Linear between grid samples, at grid
    /// position `t · shapeGridHz − shapeStartIndex`, and HELD at both ends,
    /// the convention `shaping` uses. The caller adds it only when the span
    /// has a shape; the empty guard is a second line of defence.
    ///
    /// ⭐ **SOURCE TIME, NEVER THE GENERATOR'S AXIS.** The user drew against
    /// the SUNG audio, so a retime (C2) carries the drawing with the audio it
    /// was drawn on. The synthesised generator is the other case: a rate the
    /// user chose, so it runs in edited time.
    fileprivate static func drawnShape(_ span: Span, at t: Double) -> Double {
        let samples = span.shapeSemitones
        guard let first = samples.first else { return 0 }
        let position = t * NoteSegment.shapeGridHz - span.shapeStartGrid
        guard position > 0 else { return first }
        let last = samples.count - 1
        guard position < Double(last) else { return samples[last] }
        let lower = Int(position)
        let fraction = position - Double(lower)
        return samples[lower] * (1 - fraction) + samples[lower + 1] * fraction
    }

    /// The SYNTHESISED vibrato term, semitones, before the boundary gate.
    ///
    /// `depth × fade(t) × sin(2π · rate · (t − anchor))`, with the phase
    /// anchored at the STORED `vibratoPhaseAnchorSeconds` (source second zero
    /// by default) and the fade anchored at the NOTE'S START — see the type's
    /// banner for why those two anchors differ on purpose.
    ///
    /// `t` is on the GENERATOR'S axis: source seconds on an untimed curve,
    /// EDITED seconds on a retimed one (C2-1), and `span.envelopeStartSeconds`
    /// and `span.vibratoPhaseAnchorSeconds` are already on the same axis. The
    /// default anchor stays at axis zero, which is source zero because
    /// `W(0) = 0`.
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
        // C5a-1 (vibrato-handle design §7.1 and §7.6): the phase anchor, on
        // this axis (`make` precomputed `W(anchor)` on a retimed curve).
        // ⭐ NO BRANCH AT THE DEFAULT, ON PURPOSE: `t − (+0.0) == t` for every
        // finite `t` in IEEE arithmetic, `−0.0` included (`−0 − +0 = −0`), so
        // at anchor 0 the argument is bit for bit the pre-anchor `ω · t`.
        // `NoteVibratoGeneratorTests.anchorZeroIsTodayBitForBit` (T12) is the
        // proof, not this comment.
        let phase = span.vibratoRadiansPerSecond * (t - span.vibratoPhaseAnchorSeconds)
        return depth * fade * sin(phase)
    }

    /// Binary search for the first span whose ramped window could still be open
    /// at `t` — i.e. the first with `reachPrefixMax > t`, where
    /// `reachPrefixMax` is `spanReachPrefixMax`: NON-DECREASING by
    /// construction, which a binary search needs and the raw
    /// `endSeconds + halfRamp` is not (p2-span).
    fileprivate static func firstSpanIndex(_ reachPrefixMax: [Double],
                                           notEndedBefore t: Double) -> Int {
        var low = 0
        var high = reachPrefixMax.count
        while low < high {
            let mid = (low + high) / 2
            if reachPrefixMax[mid] > t {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }

    /// p2-span: `spanReachPrefixMax` and `spanOpenSuffixMin`, O(n), built
    /// once per curve so the per-hop evaluators read them and never allocate.
    /// The reach and opening are the same expressions the scan evaluated per
    /// span before, so on a set where both already ascend the two arrays hold
    /// exactly those values and every search and exit lands where it did.
    fileprivate static func searchBounds(_ spans: [Span])
        -> (reachPrefixMax: [Double], openSuffixMin: [Double]) {
        var reachPrefixMax: [Double] = []
        reachPrefixMax.reserveCapacity(spans.count)
        // Natural tuning §4: the reach and opening are the GATE's edges,
        // `centre ± half`. On a legacy set the centres ARE `endSeconds` and
        // `startSeconds` and both halves are the legacy half, so these are
        // the p2-span expressions value for value.
        var running = -Double.infinity
        for span in spans {
            running = max(running, span.fallCentreSeconds + span.halfRampOut)
            reachPrefixMax.append(running)
        }
        var openSuffixMin = [Double](repeating: 0, count: spans.count)
        var lowest = Double.infinity
        for index in spans.indices.reversed() {
            lowest = min(lowest, spans[index].riseCentreSeconds - spans[index].halfRampIn)
            openSuffixMin[index] = lowest
        }
        return (reachPrefixMax, openSuffixMin)
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

    /// **THE VERSION OF THE EQUAL-SCALE CONTOUR-SHAPING ARITHMETIC** — bump it
    /// whenever a curve built by `curve(editSet:…)` from an UNCHANGED edit set
    /// whose notes all have `driftScale == vibratoScale` and an UNCHANGED
    /// contour would come out different: the v1 separator
    /// (`PitchCorrectionCurve.driftWindowSeconds` and the moving average behind
    /// it), `frameValueOffsetSeconds`, or the equal-scale branch of
    /// `PitchCorrectionCurve.make`. Since natural tuning §3 (W7-C3) a set with an
    /// UNEQUAL-scale note keys `separatedShapingVersion` instead
    /// (`shapingVersion(for:)`); a bump here re-keys every Hard Tune render,
    /// a bump there never does.
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
    /// ⚠️ The v1 separator was the likeliest thing to change, and it did: on a
    /// 5.5 Hz vibrato the 250 ms window passes 121 % of the wobble into
    /// "vibrato", so `vibratoScale: 0` on its own over-corrected wherever the
    /// detector reads the depth fully. Since W7-C3 `vibratoScale: 0` alone is
    /// an unequal-scale note and takes v2, which does not invert; Hard Tune
    /// still takes v1 and is unchanged. `ContourShapingSweepTests`
    /// (DAWEngineTests, env-gated) re-derives the wander cut through the
    /// product render; MEASURED 2026-09-27 on one tree before and after v2:
    /// `vibratoScale: 0` alone cuts 44–46 % at A3 and 26–31 % at B3 under v1,
    /// 48–51 % and 41–45 % under v2; Hard Tune cuts 39–51 %, identical under
    /// both. (The 2026-09-24 figures, 56 % / 34 % / 48–58 %, no longer
    /// reproduce even on v1: the render changed between the two dates, the
    /// curve did not.) Most of what is left in every case is the renderer: the
    /// same curves evaluated WITHOUT the stretcher leave 2.6–8.2 cents (v1)
    /// and 3.7–9.3 cents (v2).
    public static let shapingVersion = 1

    /// Natural tuning §3b/§3d (W7-C3): **THE VERSION OF THE SEPARATED (v2)
    /// SHAPING ARITHMETIC**: the unequal-scale branch of
    /// `PitchCorrectionCurve.make` and its kernel
    /// (`PitchCorrectionMath.triangularAverage`,
    /// `PitchCorrectionCurve.separatedDriftWindowSeconds`, `.separatedDriftEdge`).
    /// Bump THIS, never `shapingVersion`, when that branch changes: it re-keys
    /// only renders that hold an unequal-scale note, never Hard Tune.
    /// `ShapingKeyVersionTests` (G2) holds the split.
    public static let separatedShapingVersion = 2

    /// The `shaping:` version a contour-shaped render of `set` keys:
    /// `separatedShapingVersion` when some note takes the v2 branch
    /// (`PitchEditSet.needsSeparatedShaping`, the one predicate), else
    /// `shapingVersion`. A pure function of the set, so `ClipRenderSignature`,
    /// which already covers the set, needs no field of its own.
    public static func shapingVersion(for set: PitchEditSet?) -> Int {
        set?.needsSeparatedShaping == true ? separatedShapingVersion : shapingVersion
    }

    /// **THE curve a render of `editSet` plays.** `StretchCurvePlan` builds its
    /// curve through this and nothing else; a display must too.
    ///
    /// `timeWarp` (m23-ap C2-1) is `PitchTimeWarp.make(editSet:
    /// sourceDurationSeconds:)` for THIS `editSet`, or `nil` for an untimed
    /// set. Passing nothing is exactly the pre-C2 call.
    public func curve(editSet: PitchEditSet,
                      clipPitchShiftSemitones: Double,
                      timeWarp: PitchTimeWarp? = nil,
                      separator: PitchCorrectionCurve.Separator = .production) -> PitchCorrectionCurve {
        PitchCorrectionCurve.make(editSet: editSet, contour: frames,
                                  contourValueOffsetSeconds: frameValueOffsetSeconds,
                                  clipPitchShiftSemitones: clipPitchShiftSemitones,
                                  timeWarp: timeWarp,
                                  separator: separator)
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

    /// Natural tuning §1(e): the voice-size amount (`PitchEditSet.formantCorrection`)
    /// this pass STORES, over both rules that otherwise decide it.
    ///  * `nil` (the default, and every preset's): today's rule. A new set
    ///    takes the seed (`PitchEditSet.newSetFormantCorrection`), and
    ///    `ProjectStore.autoCorrectClipPitch` carries an amount the clip's
    ///    CURRENT table already holds (the user's own pick, §1(c) D-F2).
    ///  * a number: clamped to `PitchEditSet.formantCorrectionRange` and
    ///    stored over BOTH the seed and the carry. `0.0` is an engaged
    ///    amount, never legacy (the `PitchEditSet.formantCorrection` rule).
    ///  * a NON-FINITE number is kept as it is, never healed to nil:
    ///    `autoCorrectClipPitch` REFUSES it in words before detection runs.
    ///    A NaN quietly read as "no override" would drop a request without
    ///    a word. `formantCorrectionOverride` is the one reading of it.
    ///
    /// ⚠️ nil means "no override", so this can never ask a pass for LEGACY
    /// (no amount): legacy stays reachable only through
    /// `ProjectStore.setClipFormantCorrection(amount: nil)`. Declared LAST
    /// and omitted from the payload when nil (the synthesized `Codable`
    /// skips a nil optional), so an options value that names no amount
    /// encodes byte for byte as it did before the field existed.
    public var formantCorrection: Double?

    public init(scale: PitchCorrectionScale = .chromatic,
                strength: Double = 1,
                retuneMs: Double = PitchEditSet.engineMinimumRetuneMs,
                preserveVibrato: Bool = true,
                formantCorrection: Double? = nil) {
        self.scale = scale
        self.strength = PitchCorrectionMath.finite(strength, default: 0).clamped(to: 0...1)
        self.retuneMs = PitchCorrectionMath
            .finite(retuneMs, default: PitchEditSet.engineMinimumRetuneMs)
            .clamped(to: PitchEditSet.retuneMsRange)
        self.preserveVibrato = preserveVibrato
        // Clamped like `strength`, but a non-finite value is KEPT so the
        // store can refuse it in words (see the field).
        self.formantCorrection = formantCorrection.map {
            $0.isFinite ? $0.clamped(to: PitchEditSet.formantCorrectionRange) : $0
        }
    }

    /// ⭐ **THE ONE READING of `formantCorrection`**, shared by the policy
    /// (`PitchAutoCorrect.build`, over the seed) and the store
    /// (`ProjectStore.autoCorrectClipPitch`, over the carry): the amount
    /// clamped to `PitchEditSet.formantCorrectionRange` (a direct field
    /// write bypasses `init`'s clamp), or nil for "no override". A
    /// non-finite amount reads nil here: the store has refused it before
    /// this is asked, and the pure policy keeps the seed.
    public var formantCorrectionOverride: Double? {
        guard let amount = formantCorrection, amount.isFinite else { return nil }
        return amount.clamped(to: PitchEditSet.formantCorrectionRange)
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
    /// **Plus one IDENTITY `.unpitched` segment per SOUND between the notes
    /// (U-A)**, in every row; `build(contour:…)` says why, and returns the
    /// finder's result beside the set.
    ///
    /// - Parameter slideShape: THE policy constant `slideShape` by default; every
    ///   production caller leaves it there. A test passes each case.
    public static func editSet(contour frames: [ClipPitchFrame],
                               frameRateHz: Double,
                               options: PitchAutoCorrectOptions,
                               analysisVersion: Int = PitchEditSet.currentAnalysisVersion,
                               slideShape: PitchSlideShape = PitchAutoCorrect.slideShape)
    -> PitchEditSet {
        build(contour: frames, frameRateHz: frameRateHz, options: options,
              analysisVersion: analysisVersion, slideShape: slideShape).editSet
    }

    /// `editSet(contour:…)` plus what the unpitched finder decided (U-A,
    /// unpitched-notes design §1.10): the ONE policy, and the variant a caller
    /// uses when it has to REPORT the finder's skip reason, floor or threshold
    /// (`ProjectStore.autoCorrectClipPitchReport`, the wire's
    /// `unpitchedSkippedReason`). `editSet(contour:…)` forwards here, so the
    /// two cannot build different sets.
    ///
    /// ⭐ **SOUNDS (U-A, §1.6, U4).** After the splitter's parts, the finder
    /// adds one `.unpitched` segment per audible stretch between notes. Each
    /// is IDENTITY under every preset and every slide shape (never `locked`,
    /// never `shapeScale`): a sound has no voiced frames to shape, and Hard
    /// Tune's scale 0 would name it in `unresolvedShapingSegmentIDs`, which
    /// the editor reads as "couldn't analyse". Untouched, it does not enter
    /// the curve (`NoteSegment.entersPitchCurve`), so every preset renders
    /// exactly as it did before sounds existed.
    public static func build(contour frames: [ClipPitchFrame],
                             frameRateHz: Double,
                             options: PitchAutoCorrectOptions,
                             analysisVersion: Int = PitchEditSet.currentAnalysisVersion,
                             slideShape: PitchSlideShape = PitchAutoCorrect.slideShape)
    -> PitchNoteTableBuild {
        guard options.strength > 0 else {
            return PitchNoteTableBuild(editSet: .empty, unpitched: nil)
        }
        // f0 alone decides where notes are: onset placement (S3) is not scheduled
        // (design §12 item 3), so no onsets are passed.
        let parts = PitchNoteSplitter.parts(in: frames, frameRateHz: frameRateHz,
                                            onsetSeconds: [])
        // Run even with no parts, so the report names the reason (`noNotes`,
        // or a guard that fired first) rather than going quiet.
        let unpitched = PitchUnpitchedFinder.sounds(
            in: frames, frameRateHz: frameRateHz,
            notes: parts.map(PitchUnpitchedFinder.Note.init(part:)))
        // Natural tuning X3 (R14, R29): a NEW set, so the preset seed. Slides
        // stay as sung (`glideFollow` 0) because the policy says so, not
        // because no kinds are passed.
        guard !parts.isEmpty else {
            return PitchNoteTableBuild(
                editSet: newSet(segments: [], options: options, analysisVersion: analysisVersion),
                unpitched: unpitched)
        }
        // Flattening IS correction, so it scales with strength: at strength 0
        // both branches are the identity, and at strength 1 the robot branch
        // replaces the contour outright.
        let shapeScale = options.preserveVibrato ? 1 : (1 - options.strength)

        let notes = parts.indices.map { index -> NoteSegment in
            segment(forPart: index, of: parts, options: options,
                    shapeScale: shapeScale, slideShape: slideShape)
        }
        let sounds = unpitched.sounds.map(segment(forSound:))
        return PitchNoteTableBuild(
            editSet: newSet(segments: notes + sounds, options: options,
                            analysisVersion: analysisVersion),
            unpitched: unpitched)
    }

    /// A pass's NEW set: the preset seed (X3, `PitchEditSet.seeded`), then
    /// the voice size the options NAME (§1(e), `formantCorrectionOverride`)
    /// over the seed's. Both of `build`'s tables come through here, so an
    /// empty one and a full one cannot disagree about it. With no override
    /// this is exactly the seed, byte for byte.
    private static func newSet(segments: [NoteSegment], options: PitchAutoCorrectOptions,
                               analysisVersion: Int) -> PitchEditSet {
        var set = PitchEditSet.seeded(analysisVersion: analysisVersion, segments: segments,
                                      retuneMs: options.retuneMs, partKinds: [:],
                                      seedPolicy: .preset)
        if let amount = options.formantCorrectionOverride { set.formantCorrection = amount }
        return set
    }

    /// ONE sound's segment (U-A, §1.4/§1.6): `.unpitched`, drawn at the
    /// borrowed anchor, and IDENTITY — every edit field at its default, under
    /// every preset. Both builders and the merge verb
    /// (`ProjectStore.findUnpitchedSounds`) make sounds here and nowhere else.
    static func segment(forSound sound: PitchUnpitchedFinder.Sound) -> NoteSegment {
        NoteSegment(startSeconds: sound.startSeconds,
                    endSeconds: sound.endSeconds,
                    detectedHz: sound.anchorHz,
                    detectedConfidence: sound.medianConfidence,
                    origin: .unpitched)
    }

    /// ⭐ **THE ONE MAPPING from a part's kind to the stored origin** (UA-2,
    /// unpitched-notes design §1.4 U2; it settles p2-seg §10 item 9). Both
    /// builders call it: `segment(forPart:)` below and `PitchNoteTable.build`.
    /// So the editor and the corrector cannot stamp a slide differently. A
    /// `.held` part is a `.detected` note and a `.transition` part is a sung
    /// slide. A part is never `.unpitched` (`segment(forSound:)` makes the
    /// sounds). The switch is exhaustive, so a new part kind is a compile
    /// error here and never a silent `.detected`.
    ///
    /// The stamp bends nothing: `.transition` enters the curve exactly as
    /// `.detected` does (`NoteSegment.entersPitchCurve`, and the formant base
    /// in `PitchCorrectionCurve.make`). It moves only the render KEY (digest
    /// slot 6), and only for a set that bends pitch and has a slide.
    static func origin(of kind: NotePart.Kind) -> NoteOrigin {
        switch kind {
        case .held: return .detected
        case .transition: return .transition
        }
    }

    /// One part's segment: the table on `editSet`, and nothing else.
    private static func segment(forPart index: Int, of parts: [NotePart],
                                options: PitchAutoCorrectOptions, shapeScale: Double,
                                slideShape: PitchSlideShape) -> NoteSegment {
        let part = parts[index]
        // UA-2: the part's own kind, in every preset and every shape, whichever
        // branch below builds the segment (a slide can be locked or as sung).
        let origin = Self.origin(of: part.kind)
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
                vibratoScale: shapeScale,
                origin: origin)
        }
        // IDENTITY: the note as sung — offset 0, both scales 1. A real, editable
        // note rather than a gap: a gap would sound the same (the curve is
        // identity where nothing covers a time) but would leave a voiced stretch
        // with no note drawn over it, which the editor has never drawn and the
        // user could not grab (design §3.2 (a-T)).
        func asSung() -> NoteSegment {
            NoteSegment(startSeconds: part.startSeconds, endSeconds: part.endSeconds,
                        detectedHz: part.centreHz, detectedConfidence: part.medianConfidence,
                        origin: origin)
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

    /// `build(contour:…)` over a whole `clip.detectPitch` response, at the
    /// result's OWN frame rate (the `editSet(from:…)` rule).
    public static func build(from result: PitchDetectionResult,
                             options: PitchAutoCorrectOptions,
                             analysisVersion: Int = PitchEditSet.currentAnalysisVersion,
                             slideShape: PitchSlideShape = PitchAutoCorrect.slideShape)
    -> PitchNoteTableBuild {
        build(contour: result.frames, frameRateHz: result.frameRateHz,
              options: options, analysisVersion: analysisVersion, slideShape: slideShape)
    }
}

/// A note table as one of the two builders made it, with what the unpitched
/// finder decided on the way (U-A, unpitched-notes design §1.10).
/// `PitchAutoCorrect.build` and `PitchNoteTable.build` return it; their plain
/// twins (`editSet`, `detected`) forward to them and keep only `editSet`.
public struct PitchNoteTableBuild: Sendable, Equatable {
    /// The table, sounds included (`NoteOrigin.unpitched`).
    public let editSet: PitchEditSet
    /// The finder's result: the sounds it found, the floor, the threshold and,
    /// when it found none on purpose, why. `nil` exactly when the builder
    /// never ran it (a zero-strength pass, which returns `PitchEditSet.empty`
    /// before looking at a frame).
    public let unpitched: PitchUnpitchedFinder.Result?

    public init(editSet: PitchEditSet, unpitched: PitchUnpitchedFinder.Result?) {
        self.editSet = editSet
        self.unpitched = unpitched
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

    /// Centred moving average over `windowSeconds`, edge-clamped. The v1 drift /
    /// vibrato separator, which since natural tuning §3 shapes only equal-scale
    /// notes (where its split cancels) — see
    /// `PitchCorrectionCurve.driftWindowSeconds`. NOT edited by v2: G1 holds its
    /// callers bit for bit.
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

    /// Natural tuning §3b (W7-C3): how a centred average treats a note's ends.
    public enum AverageEdge: String, Sendable, Hashable, CaseIterable {
        /// The kernel is cut at the ends and renormalised over what is left:
        /// `movingAverage`'s rule, generalised. A near-edge output averages one
        /// side only.
        case truncate
        /// The contour is mirrored about its end frames (`x[−k] = x[k]`,
        /// whole-sample symmetric), repeatedly when the kernel is longer than
        /// the note, so the kernel keeps its full shape everywhere.
        case reflect
    }

    /// Natural tuning §3b (W7-C3): the v2 drift/vibrato separator. Two cascaded
    /// centred boxcars of `windowSeconds`, a TRIANGULAR kernel, applied as one
    /// centred convolution.
    ///
    /// Each boxcar has `M = 2h + 1` taps, `h = round(windowSeconds /
    /// stepSeconds / 2)` (`movingAverage`'s own half-width rule), so the
    /// triangle has `2M − 1` taps with integer weights `M − |k|`. Its response
    /// is the boxcar's squared, `[sin(πfMT) / (M·sin(πfT))]²`: never negative.
    /// No frequency is passed into "vibrato" at more than 100 % and none is
    /// inverted, which is the boxcar's defect (−0.2155 at 5.5 Hz, 16 ms frames).
    ///
    /// Total, like `movingAverage`: an empty input returns `[]`; a
    /// non-positive or non-finite window or step, or one under a frame,
    /// returns the input unchanged. Unlike it, a non-finite sample is LEFT OUT
    /// of every average that reaches it (its weight dropped, the rest
    /// renormalised), and an output no finite sample reaches is 0.
    public static func triangularAverage(_ values: [Double],
                                         windowSeconds: Double,
                                         stepSeconds: Double,
                                         edge: AverageEdge) -> [Double] {
        guard !values.isEmpty else { return [] }
        guard stepSeconds.isFinite, windowSeconds.isFinite,
              stepSeconds > 0, windowSeconds > 0 else { return values }
        let halfWidth = max(0, Int((windowSeconds / stepSeconds / 2).rounded()))
        guard halfWidth > 0 else { return values }
        let taps = 2 * halfWidth + 1
        let weights = (-(taps - 1)...(taps - 1)).map { Double(taps - abs($0)) }
        return centredAverage(values, weights: weights, edge: edge)
    }

    /// A centred weighted average: `weights` has an odd count and its middle
    /// tap sits on the output frame; each output is divided by the sum of the
    /// weights that reached a finite sample (0 when that sum is 0). The ONE
    /// convolution behind `triangularAverage` and G3's plant kernel
    /// (`PitchCorrectionCurve.Separator.kernelTaps`). An even `weights` count
    /// returns the input unchanged.
    static func centredAverage(_ values: [Double], weights: [Double],
                               edge: AverageEdge) -> [Double] {
        let count = values.count
        guard count > 0 else { return [] }
        guard weights.count % 2 == 1 else { return values }
        let half = weights.count / 2
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            var sum = 0.0
            var norm = 0.0
            for k in -half...half {
                let j: Int
                switch edge {
                case .truncate:
                    j = i + k
                    if j < 0 || j >= count { continue }
                case .reflect:
                    j = reflectedIndex(i + k, count: count)
                }
                let value = values[j]
                guard value.isFinite else { continue }
                let weight = weights[k + half]
                sum += weight * value
                norm += weight
            }
            out[i] = norm != 0 ? sum / norm : 0
        }
        return out
    }

    /// Whole-sample symmetric reflection of index `j` into `0..<count`
    /// (`−1 → 1`, `count → count − 2`), repeated for any distance.
    static func reflectedIndex(_ j: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * (count - 1)
        var m = j % period
        if m < 0 { m += period }
        return m < count ? m : period - m
    }
}
