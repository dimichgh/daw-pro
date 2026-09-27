import Foundation
import Testing
@testable import DAWCore

// Natural tuning, NT-C step C1 (m23-nt, design
// `docs/design/2026-09-25-natural-tuning.md` §1(b), R3, R6): THE FORMANT
// EVALUATOR, ITS BASE AND ITS ENGAGEMENT PREDICATE.
//
// Pure and nonisolated (no `ProjectStore`). The store setters, their undo and
// round trip, and the auto-correct carry live in `PitchCorrectionWriterTests`.
//
// Every known answer below is EXACT where the arithmetic is exact (moves of
// whole semitones and amounts of 0, 0.5 and 1 are dyadic), so a formula that
// is off by any term reads red rather than "close".
@Suite("Natural tuning C1: the formant curve, its base and its predicate (m23-nt)")
struct FormantCorrectionModelTests {

    // MARK: - Fixtures

    static func note(_ start: Double, _ end: Double, hz: Double = 220,
                     cents: Double = 0, formant: Double = 0,
                     origin: NoteOrigin = .detected) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: end, detectedHz: hz,
                    detectedConfidence: 0.9, pitchOffsetCents: cents,
                    formantOffsetSemitones: formant, origin: origin)
    }

    static func set(_ notes: [NoteSegment], retuneMs: Double = 30,
                    correction: Double? = nil) -> PitchEditSet {
        PitchEditSet(segments: notes, retuneMs: retuneMs, formantCorrection: correction)
    }

    static func curve(_ set: PitchEditSet, clipShift: Double = 0) -> PitchCorrectionCurve {
        PitchCorrectionCurve.make(editSet: set, clipPitchShiftSemitones: clipShift)
    }

    /// F at `t` with the clip flag off unless stated.
    static func f(_ set: PitchEditSet, at t: Double, clipShift: Double = 0,
                  preserve: Bool = false) -> Double {
        curve(set, clipShift: clipShift).formantSemitones(atSourceSecond: t,
                                                          formantPreserve: preserve)
    }

    // MARK: - F: one moved note, the amount is the axis (§1(b), G3's model half)

    @Test("F: one note moved +4 st reads (1 - c) x 4 mid-note at c = 1, 0.5 and 0, and 0 outside it")
    func oneMovedNoteFollowsTheAmount() {
        let moved = [Self.note(1.0, 2.0, cents: 400)]
        #expect(Self.f(Self.set(moved, correction: 1.0), at: 1.5) == 0, "c = 1: the envelope stays put")
        #expect(Self.f(Self.set(moved, correction: 0.5), at: 1.5) == 2, "c = 0.5: half the move")
        #expect(Self.f(Self.set(moved, correction: 0.0), at: 1.5) == 4, "c = 0: follows the note")
        // Outside the note every amount reads the clip part (0 here).
        for c in [0.0, 0.5, 1.0] {
            #expect(Self.f(Self.set(moved, correction: c), at: 0.5) == 0)
            #expect(Self.f(Self.set(moved, correction: c), at: 2.5) == 0)
        }
        // Strictly ordered in c, the G3 shape (distinct values alone prove nothing).
        let values = [0.0, 0.25, 0.5, 0.75, 1.0].map { Self.f(Self.set(moved, correction: $0), at: 1.5) }
        #expect(values == [4, 3, 2, 1, 0])
    }

    @Test("F: the edit term is the CONSTANT move only; shaping and the generator never reach it")
    func onlyTheConstantMoveReachesF() {
        var wobbly = Self.note(1.0, 2.0, cents: 400)
        wobbly.vibratoRateHz = 5.5
        wobbly.vibratoDepthCents = 80
        let set = Self.set([wobbly], correction: 0.0)
        let curve = Self.curve(set)
        // The pitch curve wobbles; F does not.
        let pitches = stride(from: 1.1, to: 1.9, by: 0.01).map { curve.semitones(atSourceSecond: $0) }
        #expect(Set(pitches).count > 10, "positive control: the generator does move the pitch")
        for t in stride(from: 1.1, to: 1.9, by: 0.01) {
            #expect(curve.formantSemitones(atSourceSecond: t, formantPreserve: false) == 4)
        }
    }

    // MARK: - F: the per-note offset (the Voice tool)

    @Test("F: a per-note offset at c = 1 reads the offset alone, moved note or not, and only on its note")
    func perNoteOffsetAtFullCorrection() {
        let notes = [Self.note(1.0, 2.0, cents: 400, formant: -2),
                     Self.note(3.0, 4.0, formant: 1.5),
                     Self.note(5.0, 6.0, cents: -300)]
        let set = Self.set(notes, correction: 1.0)
        #expect(Self.f(set, at: 1.5) == -2, "moved +4 st and kept: only the Voice offset remains")
        #expect(Self.f(set, at: 3.5) == 1.5, "unmoved note: the offset alone")
        #expect(Self.f(set, at: 5.5) == 0, "a neighbour with no offset is untouched")
        #expect(Self.f(set, at: 2.5) == 0, "between notes: the clip part")
        // At c = 0.5 the offset rides on top of half the move.
        #expect(Self.f(Self.set(notes, correction: 0.5), at: 1.5) == 0)
        #expect(Self.f(Self.set(notes, correction: 0.5), at: 5.5) == -1.5)
    }

    @Test("F: two abutting notes crossfade their offsets over retuneMs, with the pitch curve's own gates")
    func abuttingNotesCrossfadeOffsets() {
        // retune 100 ms: each gate spans ±50 ms about the shared edge at 2.0 s.
        let notes = [Self.note(1.0, 2.0, formant: -2), Self.note(2.0, 3.0, formant: 2)]
        let set = Self.set(notes, retuneMs: 100, correction: 1.0)
        #expect(Self.f(set, at: 1.9) == -2, "before the ramp: the left note's offset")
        #expect(Self.f(set, at: 2.1) == 2, "after the ramp: the right note's offset")
        #expect(abs(Self.f(set, at: 2.0)) < 1e-12, "the midpoint of complementary gates")
        // A quarter into the ramp: smoothstep(0.25) = 0.15625, so
        // -2 x 0.84375 + 2 x 0.15625 = -1.375.
        #expect(abs(Self.f(set, at: 1.975) - (-1.375)) < 1e-9)
        #expect(abs(Self.f(set, at: 2.025) - 1.375) < 1e-9)
        // Monotone through the join: a crossfade, never a jump or an overshoot.
        let sweep = stride(from: 1.94, through: 2.06, by: 0.002).map { Self.f(set, at: $0) }
        #expect(zip(sweep, sweep.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(sweep.allSatisfy { $0 >= -2 && $0 <= 2 })
        #expect(sweep.filter { $0 > -2 && $0 < 2 }.count > 20, "the offsets did blend across the ramp")
    }

    @Test("F: at c = 0 with no offsets, F IS the pitch curve bit for bit (same gates, scan and normaliser)")
    func zeroCorrectionTracksThePitchCurveBitForBit() {
        // Short notes under a long retune make the gates OVER-SUM, so the
        // normaliser is exercised, and a hole and an abutting join both occur.
        let notes = [Self.note(0.50, 0.56, cents: 300), Self.note(0.56, 0.60, cents: -250),
                     Self.note(0.60, 1.40, cents: 120), Self.note(1.50, 1.53, cents: 700),
                     Self.note(1.53, 2.40, cents: -40)]
        // (Planted "always divide" and "never divide" normalisers each turn
        // this red: see the C1 report. At 500 ms the 40 ms note's gate peaks
        // at 0.58 s while the next note's rise is already ~0.44 open.)
        for retune in [30.0, 200.0, 500.0] {
            let curve = Self.curve(Self.set(notes, retuneMs: retune, correction: 0.0), clipShift: 1.5)
            var mismatches = 0
            var blended = 0
            for step in 0...3000 {
                let t = 0.3 + Double(step) * 0.0008
                let pitch = curve.semitones(atSourceSecond: t)
                let formant = curve.formantSemitones(atSourceSecond: t, formantPreserve: false)
                if formant.bitPattern != pitch.bitPattern { mismatches += 1 }
                if pitch != 1.5 { blended += 1 }
            }
            #expect(mismatches == 0, "retune \(retune): F left the pitch curve at \(mismatches) points")
            #expect(blended > 1000, "positive control: the sweep sits on the notes, not on the clip term")
        }
    }

    // MARK: - F: the clip part and the nil fallback of c

    @Test("F: clipPart is the clip transpose with formantPreserve off and 0 with it on")
    func clipPartFollowsTheFlag() {
        let set = Self.set([Self.note(1.0, 2.0, cents: 400)], correction: 1.0)
        // Engaged at c = 1: the note's move is removed, the whole-clip
        // transpose is governed by the flag alone (§1(c), out of scope).
        #expect(Self.f(set, at: 1.5, clipShift: 3, preserve: false) == 3)
        #expect(Self.f(set, at: 0.5, clipShift: 3, preserve: false) == 3)
        #expect(Self.f(set, at: 1.5, clipShift: 3, preserve: true) == 0)
        #expect(Self.f(set, at: 0.5, clipShift: 3, preserve: true) == 0)
        // At c = 0.5 the two parts add.
        let half = Self.set([Self.note(1.0, 2.0, cents: 400)], correction: 0.5)
        #expect(Self.f(half, at: 1.5, clipShift: -2, preserve: false) == 0)
        #expect(Self.f(half, at: 1.5, clipShift: -2, preserve: true) == 2)
        // An empty set is the clip part everywhere.
        let empty = Self.set([], correction: 1.0)
        #expect(Self.f(empty, at: 1.5, clipShift: 3, preserve: false) == 3)
        #expect(Self.f(empty, at: 1.5, clipShift: 3, preserve: true) == 0)
    }

    @Test("F: a legacy set (nil) takes c from the flag: off = 0 (follows), on = 1 (kept)")
    func nilCorrectionFallsBackToTheFlag() {
        let legacy = Self.set([Self.note(1.0, 2.0, cents: 400, formant: -1)], correction: nil)
        #expect(legacy.formantCorrection == nil)
        #expect(Self.f(legacy, at: 1.5, preserve: false) == 3, "c = 0: move 4 plus offset -1")
        #expect(Self.f(legacy, at: 1.5, preserve: true) == -1, "c = 1: the offset alone")
        #expect(Self.f(legacy, at: 1.5, clipShift: 2, preserve: false) == 5)
        #expect(Self.f(legacy, at: 1.5, clipShift: 2, preserve: true) == -1)
        // 0.0 is NOT the fallback: an explicit 0 with the flag on still follows.
        let zero = Self.set([Self.note(1.0, 2.0, cents: 400)], correction: 0.0)
        #expect(Self.f(zero, at: 1.5, preserve: true) == 4)
    }

    @Test("F: non-finite seconds fall back to the clip part, like the pitch curve")
    func nonFiniteInputsFallBack() {
        let curve = Self.curve(Self.set([Self.note(1.0, 2.0, cents: 400)], correction: 0.0),
                               clipShift: 2)
        for t in [Double.nan, .infinity, -.infinity] {
            #expect(curve.formantSemitones(atSourceSecond: t, formantPreserve: false) == 2)
            #expect(curve.formantSemitones(atSourceSecond: t, formantPreserve: true) == 0)
        }
        #expect(curve.formantSemitones(atSourceSecond: 1.5, editedSecond: .nan,
                                       formantPreserve: false) == 2)
        #expect(curve.formantSemitones(atSourceSecond: 1.5, editedSecond: 1.5,
                                       formantPreserve: false) == 6)
    }

    // MARK: - The base (§1(b), R3): a step function that is never 0

    static func base(_ notes: [NoteSegment], at t: Double) -> Double {
        curve(set(notes)).formantBaseHz(atSourceSecond: t)
    }

    @Test("base: covering, between (held), before the first, after the last, and at an edge")
    func baseIsAStepFunctionOverTheNotes() {
        let notes = [Self.note(1.0, 2.0, hz: 220), Self.note(3.0, 4.0, hz: 330)]
        #expect(Self.base(notes, at: 1.5) == 220, "covering")
        #expect(Self.base(notes, at: 3.5) == 330, "covering")
        #expect(Self.base(notes, at: 2.5) == 220, "between: the last note's value is held")
        #expect(Self.base(notes, at: 0.2) == 220, "before the first: the first note's")
        #expect(Self.base(notes, at: 0.0) == 220)
        #expect(Self.base(notes, at: 9.0) == 330, "after the last: held")
        #expect(Self.base(notes, at: 3.0) == 330, "a note's own start is inside it")
        #expect(Self.base(notes, at: 2.0) == 220, "the end of a note holds its value")
        // Edits never move it: `detectedHz` is the SOURCE f0 (m23-q §6.4).
        let moved = [Self.note(1.0, 2.0, hz: 220, cents: 700, formant: -3),
                     Self.note(3.0, 4.0, hz: 330)]
        #expect(Self.base(moved, at: 1.5) == 220)
    }

    @Test("base: a non-finite or non-positive detectedHz is skipped, never returned")
    func baseSkipsUnmeasuredNotes() {
        let notes = [Self.note(0.5, 1.0, hz: .nan), Self.note(1.0, 2.0, hz: 220),
                     Self.note(2.0, 3.0, hz: -40), Self.note(3.0, 3.5, hz: .infinity),
                     Self.note(4.0, 5.0, hz: 330)]
        #expect(Self.base(notes, at: 0.7) == 220, "the first MEASURED note stands in before it")
        #expect(Self.base(notes, at: 2.5) == 220, "a skipped note holds the last measured one")
        #expect(Self.base(notes, at: 3.2) == 220)
        #expect(Self.base(notes, at: 4.5) == 330)
    }

    @Test("base: floored at 50 Hz, and NEVER 0, whatever the set")
    func baseIsFlooredAndNeverZero() {
        #expect(PitchCorrectionCurve.formantBaseFloorHz == 50)
        // The floor and the skip rules are version-1 policy, unchanged in 2
        // and 3 (§1(d); NT-E1b's bump is the render reading the curve,
        // NT-F220's the library's envelope, vendored patch 0004): changing
        // either without bumping this re-uses engaged renders made under the old one.
        #expect(PitchEditSet.formantRenderVersion == 3)
        #expect(Self.base([Self.note(1.0, 2.0, hz: 30)], at: 1.5) == 50, "floored")
        #expect(Self.base([Self.note(1.0, 2.0, hz: 50.5)], at: 1.5) == 50.5, "above the floor: as detected")
        // No measured note at all, and no note at all: the floor, never 0.
        #expect(Self.base([Self.note(1.0, 2.0, hz: 0)], at: 1.5) == 50)
        #expect(Self.base([], at: 1.5) == 50)
        #expect(PitchCorrectionCurve.make(editSet: .empty).formantBaseHz(atSourceSecond: 0) == 50)
        // Non-finite seconds read as "before the first note".
        let notes = [Self.note(1.0, 2.0, hz: 220), Self.note(3.0, 4.0, hz: 330)]
        for t in [Double.nan, .infinity, -.infinity] {
            #expect(Self.base(notes, at: t) == 220)
        }
        // A sweep over a mixed table: every value finite and at or above the floor.
        let mixed = notes + [Self.note(5.0, 5.2, hz: 20), Self.note(6.0, 7.0, hz: .nan),
                             Self.note(7.0, 7.5, hz: 0, origin: .unpitched)]
        for step in 0...1000 {
            let hz = Self.base(mixed, at: Double(step) * 0.008)
            #expect(hz.isFinite && hz >= 50, "\(hz) at step \(step)")
        }
    }

    @Test("base: a SOUND's borrowed anchor is skipped; the last sung note's f0 holds across it")
    func baseSkipsUnpitchedSounds() {
        // The sound between A and B borrowed B's 330 Hz to be drawn
        // (`PitchUnpitchedFinder`, the following note). It is not A's f0 and
        // not a measurement, so across it the base holds A.
        let notes = [Self.note(1.0, 2.0, hz: 220),
                     Self.note(2.0, 2.3, hz: 330, origin: .unpitched),
                     Self.note(2.3, 3.0, hz: 330)]
        #expect(Self.base(notes, at: 2.1) == 220)
        #expect(Self.base(notes, at: 2.5) == 330)
        // A sound BEFORE the first note does not stand in for it either.
        let leading = [Self.note(0.5, 1.0, hz: 440, origin: .unpitched), Self.note(1.0, 2.0, hz: 220)]
        #expect(Self.base(leading, at: 0.7) == 220)
        // A MOVED sound is still no measurement.
        let moved = [Self.note(1.0, 2.0, hz: 220),
                     Self.note(2.0, 2.3, hz: 330, cents: 200, origin: .unpitched),
                     Self.note(2.3, 3.0, hz: 330)]
        #expect(Self.base(moved, at: 2.1) == 220)
        // A sung slide IS a measurement: `.transition` counts.
        let slide = [Self.note(1.0, 2.0, hz: 220), Self.note(2.0, 2.3, hz: 260, origin: .transition)]
        #expect(Self.base(slide, at: 2.1) == 260)
        // Only sounds: nothing measured, so the floor (never the borrowed 330).
        #expect(Self.base([Self.note(1.0, 2.0, hz: 330, origin: .unpitched)], at: 1.5) == 50)
    }

    // MARK: - engagesFormantCurve (§1(b)), and the unpitched ruling

    @Test("engages: a legacy set with every offset 0 does not; any amount (0.0 included) or a note offset does")
    func engagementPredicate() {
        let legacy = Self.set([Self.note(1.0, 2.0, cents: 400), Self.note(3.0, 4.0)])
        #expect(!legacy.engagesFormantCurve)
        #expect(!PitchEditSet.empty.engagesFormantCurve)
        #expect(Self.set([], correction: 1.0).engagesFormantCurve, "an amount engages even with no notes")
        #expect(Self.set(legacy.segments, correction: 0.0).engagesFormantCurve, "0.0 is engaged, not legacy")
        #expect(Self.set(legacy.segments, correction: 1.0).engagesFormantCurve)
        // Legacy + a note offset (a hand-authored file): engages with c = the flag.
        let withOffset = Self.set([Self.note(1.0, 2.0, formant: -2)])
        #expect(withOffset.formantCorrection == nil && withOffset.engagesFormantCurve)
        #expect(!Self.set([Self.note(1.0, 2.0, formant: -0.0)]).engagesFormantCurve, "-0.0 is no edit")
        // `seeded` sets engage; `predatesNaturalTuning` and this are different questions.
        let seeded = PitchEditSet.seeded(analysisVersion: 1, segments: legacy.segments,
                                         retuneMs: 30, partKinds: [:], seedPolicy: .editor)
        #expect(seeded.engagesFormantCurve && !seeded.predatesNaturalTuning)
    }

    @Test("engages (unpitched ruling): an UNTOUCHED sound's offset neither engages nor is read; a moved one's does")
    func untouchedSoundOffsetIsInert() {
        let note = Self.note(1.0, 2.0)
        let still = Self.note(2.0, 2.5, formant: -2, origin: .unpitched)
        #expect(!still.entersPitchCurve && !still.engagesFormantCurve)
        let stillSet = Self.set([note, still])
        #expect(!stillSet.engagesFormantCurve, "a value nothing reads must not switch the formant stage on")
        // And it is not read, even on an engaged set: F over the sound is the clip part.
        #expect(Self.f(Self.set([note, still], correction: 1.0), at: 2.25) == 0)
        // Positive control: the same offset on a NOTE is read at the same place.
        #expect(Self.f(Self.set([note, Self.note(2.0, 2.5, formant: -2)], correction: 1.0),
                       at: 2.25) == -2)
        // A MOVED sound enters like any note (R21): engages, and its offset is read.
        let moved = Self.note(2.0, 2.5, cents: 300, formant: -2, origin: .unpitched)
        #expect(moved.entersPitchCurve && moved.engagesFormantCurve)
        #expect(Self.set([note, moved]).engagesFormantCurve)
        #expect(Self.f(Self.set([note, moved], correction: 1.0), at: 2.25) == -2)
        #expect(Self.f(Self.set([note, moved], correction: 0.0), at: 2.25) == 1, "3 + (-2)")
        // A moved sound with no offset engages only through an amount.
        #expect(!Self.set([note, Self.note(2.0, 2.5, cents: 300, origin: .unpitched)]).engagesFormantCurve)
    }

    // MARK: - Byte identity: the PITCH curve did not move (the law that matters most)

    /// A rich pitch fixture: contour shaping (drift and vibrato scales off 1),
    /// short notes under a long retune (the normaliser), a moved sound, a
    /// hole, and a `-0.0` clip transpose. No generator, so no `sin` in the
    /// hash: the only libm call on the path is `cents`' `log2`.
    static func pitchGoldenCurve(formant: Bool) -> PitchCorrectionCurve {
        var frames: [ClipPitchFrame] = []
        for k in 0..<140 {
            let phase = k % 16
            let tri = Double(phase < 8 ? phase : 16 - phase) / 8 - 0.5
            frames.append(ClipPitchFrame(timeSeconds: 0.3 + Double(k) * 0.016,
                                         frequencyHz: 220 * (1 + 0.02 * tri), confidence: 0.95,
                                         levelDbfs: -12, absence: nil))
        }
        var shaped = note(0.60, 1.40, cents: 120, formant: formant ? -2 : 0)
        shaped.driftScale = 0.5
        shaped.vibratoScale = 0.25
        let notes = [note(0.50, 0.56, cents: 300), note(0.56, 0.60, cents: -250), shaped,
                     note(1.40, 1.46, cents: 50, origin: .unpitched),
                     note(1.50, 1.53, cents: 700), note(1.53, 2.40, cents: -40)]
        let set = PitchEditSet(segments: notes, retuneMs: 200,
                               formantCorrection: formant ? 0.75 : nil)
        return PitchCorrectionCurve.make(editSet: set, contour: frames,
                                         contourValueOffsetSeconds: 0.008,
                                         clipPitchShiftSemitones: -0.0)
    }

    /// FNV-1a over the bit patterns of `semitones` on a dense sweep.
    static func pitchHash(_ curve: PitchCorrectionCurve) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for step in 0...4000 {
            var bits = curve.semitones(atSourceSecond: 0.2 + Double(step) * 0.0006).bitPattern
            for _ in 0..<8 {
                hash = (hash ^ (bits & 0xff)) &* 0x0000_0100_0000_01b3
                bits >>= 8
            }
        }
        return hash
    }

    /// ⛔ Captured from `semitones` as it stands in 813c415 + C0: the C1 diff
    /// leaves that function's text untouched (only `Span` grew a field the
    /// pitch loop never reads), `diff`-verified against the orchestrator's
    /// snapshot. Never regenerate it after editing `semitones`.
    ///
    /// ⚠️ RE-PINNED 2026-09-25 by p2-span, a deliberate move and the only one
    /// it made: this fixture's short notes under a 200 ms retune make the
    /// spans' reach and opening NON-monotone, and the old span search skipped
    /// ramps that were still open here (`PitchSpanSearchTests`). The new value
    /// was checked, not captured on trust: at all 4001 sweep points the
    /// shipped curve equals a SEARCH-FREE evaluation (each point read from a
    /// curve built from only the spans open there). Pre-p2-span:
    /// 10_344_288_514_428_929_922.
    static let pitchGolden: UInt64 = 12_426_807_464_652_067_473

    @Test("bytes: semitones() is bit-identical on a rich fixture, and formant fields never touch it")
    func pitchCurveBitsDidNotMove() {
        let legacy = Self.pitchGoldenCurve(formant: false)
        let engaged = Self.pitchGoldenCurve(formant: true)
        #expect(legacy.unresolvedShapingSegmentIDs.isEmpty, "the shaping resolved")
        #expect(Self.pitchHash(legacy) == Self.pitchGolden, "got \(Self.pitchHash(legacy))")
        // An amount and a Voice offset change F, and not one pitch bit.
        #expect(Self.pitchHash(engaged) == Self.pitchHash(legacy))
        #expect(engaged.formantSemitones(atSourceSecond: 1.0, formantPreserve: false)
                != legacy.formantSemitones(atSourceSecond: 1.0, formantPreserve: false),
                "positive control: the formant side did change")
        // A legacy set: not engaged, no amount on the curve.
        let legacySet = PitchEditSet(segments: [Self.note(1.0, 2.0, cents: 400)])
        #expect(!legacySet.engagesFormantCurve)
        #expect(PitchCorrectionCurve.make(editSet: legacySet).formantCorrection == nil)
    }
}
