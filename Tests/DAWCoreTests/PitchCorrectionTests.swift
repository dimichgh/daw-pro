import Foundation
import Testing
@testable import DAWCore

// m23-ap Phase 1 (2) — the pitch-correction model, the ONE curve evaluator, and
// the auto-correct policy. `Sources/DAWCore/PitchCorrection.swift`.
//
// ═══ ON FIXTURES, AND THE TRAP THIS MILESTONE ALREADY PAID FOR ═══
//
// m23-ap-2a nearly condemned a working detector because the FIXTURE was the
// defect: a 220 Hz PURE SINE measured 88.8 % octave errors, while the same
// pitch with 8 harmonics measured 0.48 cents and 0 % octave errors. A
// spectrogram CNN has never seen a pure sine.
//
// ⚠️ **THAT TRAP DOES NOT APPLY TO THESE TESTS, AND SAYING SO IS NOT A DODGE.**
// Every input here is a `[ClipPitchFrame]` — a per-frame PITCH READING, the
// detector's OUTPUT — not audio, and no detector is invoked anywhere in this
// file. There is no spectrum for a harmonic to be missing from. What the
// detector's own accuracy costs this subsystem is recorded in the source file's
// banner as a constraint on what may be PROMISED (±12.90 cents of bin floor,
// +5.45 cents of transposer bias), not as something these tests can measure.
// The contours below are deliberately vocal-SHAPED — sustained centres,
// sinusoidal vibrato, unvoiced gaps between phrases — because that is what the
// POLICY consumes.
//
// ═══ ON NEGATIVE CONTROLS ═══
//
// Every measured assertion here is paired with a proof that the same predicate,
// at the same tolerance, REJECTS the defect it exists to catch — the no-op
// policy, the doubled correction, the flattened vibrato, the filled hole. A
// test that cannot fail is the failure mode this repo keeps hitting, so the
// counter-value is asserted rather than assumed.
//
// Not `@MainActor`: nothing here needs the actor, and the tree's `@MainActor`
// suite count is at its review-cadence cap. Persistence is exercised at the
// DOCUMENT layer (`ClipDocument`, `ProjectDocument.runtimeState`,
// `TakeGroupDocument.takeGroup`) rather than through `ProjectStore`, which is
// both actor-free and closer to the four-touch-point trap design §7.3 names.

// MARK: - Contour fixtures

/// Builders for synthetic DETECTED CONTOURS (not audio — see the banner).
private enum Contour {
    /// SwiftF0's rate, and the rate every fixture here uses.
    static let frameRateHz: Double = 62.5
    static let framePeriod: Double = 1 / 62.5

    /// A sung note as the detector would report it: `centreHz`, optionally with
    /// sinusoidal vibrato of `vibratoPeakToPeakCents` at `vibratoHz`, and
    /// optionally a linear macro drift of `driftCents` across the note.
    static func note(startSeconds: Double,
                     durationSeconds: Double,
                     centreHz: Double,
                     vibratoPeakToPeakCents: Double = 0,
                     vibratoHz: Double = 0,
                     driftCents: Double = 0,
                     confidence: Double = 0.97) -> [ClipPitchFrame] {
        let count = Int((durationSeconds / framePeriod).rounded())
        return (0..<count).map { i in
            let offsetSeconds = Double(i) * framePeriod
            let vibrato = vibratoPeakToPeakCents == 0 || vibratoHz == 0
                ? 0
                : (vibratoPeakToPeakCents / 2) * sin(2 * .pi * vibratoHz * offsetSeconds)
            // Symmetric about the centre so the note's MEDIAN is the centre —
            // a drift that only went up would move the thing under test.
            let drift = driftCents == 0
                ? 0
                : driftCents * ((offsetSeconds / durationSeconds) - 0.5)
            let hz = centreHz * pow(2, (vibrato + drift) / 1200)
            return ClipPitchFrame(timeSeconds: startSeconds + offsetSeconds,
                                  frequencyHz: hz, confidence: confidence,
                                  levelDbfs: -18, absence: nil)
        }
    }

    /// An UNVOICED gap: frames exist, they carry no pitch, and they say why.
    /// This is the shape `PitchDetectionResult` actually produces — the holes
    /// are the signal, and a hole is never a frequency of 0.
    static func hole(startSeconds: Double, durationSeconds: Double) -> [ClipPitchFrame] {
        let count = Int((durationSeconds / framePeriod).rounded())
        return (0..<count).map { i in
            ClipPitchFrame(timeSeconds: startSeconds + Double(i) * framePeriod,
                           frequencyHz: nil, confidence: 0.2,
                           levelDbfs: -54, absence: .belowConfidence)
        }
    }

    /// A note with an ONSET SCOOP: the singer arrives from `scoopCents` below
    /// and slides onto the pitch over `scoopSeconds`, then holds. This is the
    /// asymmetric contour a MEAN gets dragged by and a MEDIAN does not, and it
    /// is what §7.1's "median f0" is chosen for.
    static func scoopedNote(startSeconds: Double,
                            scoopSeconds: Double,
                            scoopCents: Double,
                            sustainSeconds: Double,
                            centreHz: Double) -> [ClipPitchFrame] {
        let scoopFrames = Int((scoopSeconds / framePeriod).rounded())
        let scoop = (0..<scoopFrames).map { i -> ClipPitchFrame in
            let progress = Double(i) / Double(max(1, scoopFrames))
            let cents = scoopCents * (1 - progress)
            return ClipPitchFrame(timeSeconds: startSeconds + Double(i) * framePeriod,
                                  frequencyHz: centreHz * pow(2, cents / 1200),
                                  confidence: 0.93, levelDbfs: -20, absence: nil)
        }
        return scoop + note(startSeconds: startSeconds + Double(scoopFrames) * framePeriod,
                            durationSeconds: sustainSeconds, centreHz: centreHz)
    }

    /// Cents from A440, i.e. `(midi − 69) × 100`.
    static func centsFromA440(_ hz: Double) -> Double { 1200 * log2(hz / 440) }
}

/// The sounding pitch after correction, in cents from A440, sampled on the
/// detector's own frame grid across `[from, to)`.
///
/// This is the quantity the listener hears: what was sung, plus what the curve
/// asks the transposer for. Every "did the correction land" and "did the
/// modulation survive" assertion below is made on THIS, not on the edit-set
/// numbers — reading the model back to itself would prove nothing.
private func soundingCents(frames: [ClipPitchFrame],
                           curve: PitchCorrectionCurve,
                           from: Double, to: Double) -> [Double] {
    frames.compactMap { frame -> Double? in
        guard let hz = frame.frequencyHz,
              frame.timeSeconds >= from, frame.timeSeconds < to else { return nil }
        return Contour.centsFromA440(hz) + 100 * curve.semitones(atSourceSecond: frame.timeSeconds)
    }
}

private func peakToPeak(_ values: [Double]) -> Double {
    guard let low = values.min(), let high = values.max() else { return 0 }
    return high - low
}

// MARK: - Scale + snapping

struct PitchCorrectionScaleTests {

    /// The repo has ONE home for what "major" means in semitones, and one for
    /// pitch-class names. This file must read them, not restate them.
    @Test("major/minor DELEGATE to KeyMode; the tonic name comes from KeyEstimate")
    func scaleReadsTheOneHomes() {
        #expect(PitchCorrectionScaleMode.major.scaleIntervals == KeyMode.major.scaleIntervals)
        #expect(PitchCorrectionScaleMode.minor.scaleIntervals == KeyMode.minor.scaleIntervals)
        #expect(PitchCorrectionScaleMode.chromatic.scaleIntervals.count == 12)

        // C major is the white keys; A minor is the same set, transposed home.
        #expect(PitchCorrectionScale(tonicPitchClass: 0, mode: .major)
            .allowedPitchClasses == [0, 2, 4, 5, 7, 9, 11])
        #expect(PitchCorrectionScale(tonicPitchClass: 9, mode: .minor)
            .allowedPitchClasses == [0, 2, 4, 5, 7, 9, 11])
        // NEGATIVE CONTROL: the predicate above can fail — C minor is a
        // DIFFERENT set, so "any seven pitch classes pass" is excluded.
        #expect(PitchCorrectionScale(tonicPitchClass: 0, mode: .minor)
            .allowedPitchClasses != [0, 2, 4, 5, 7, 9, 11])

        #expect(PitchCorrectionScale(tonicPitchClass: 1, mode: .major).displayName == "C# major")
        #expect(PitchCorrectionScale(tonicPitchClass: 9, mode: .minor).displayName == "A minor")
        // Chromatic has no tonic to name, and must not pretend to.
        #expect(PitchCorrectionScale(tonicPitchClass: 7, mode: .chromatic)
            .displayName == "chromatic")
        // A tonic outside 0…11 wraps rather than traps.
        #expect(PitchCorrectionScale(tonicPitchClass: -1, mode: .major).displayName == "B major")
    }

    /// The move auto-correct can request is bounded by the SCALE'S GEOMETRY —
    /// there is no clamp doing this, so if the snapper is wrong the bound is
    /// what notices. Half a semitone chromatic, a whole semitone in a
    /// seven-note mode (the largest gap being two semitones).
    @Test("the snap is bounded by the scale's own geometry, over a full-octave sweep")
    func snapIsBoundedByGeometry() {
        var worstChromatic = 0.0
        var worstMajor = 0.0
        var worstMinor = 0.0
        // 1 cent at a time across an octave, so every gap in every mode is hit.
        for step in 0...1200 {
            let midi = 60 + Double(step) / 100
            worstChromatic = max(worstChromatic,
                abs(PitchCorrectionScale.chromatic.nearestAllowedMidi(to: midi) - midi))
            worstMajor = max(worstMajor,
                abs(PitchCorrectionScale(tonicPitchClass: 0, mode: .major)
                    .nearestAllowedMidi(to: midi) - midi))
            worstMinor = max(worstMinor,
                abs(PitchCorrectionScale(tonicPitchClass: 9, mode: .minor)
                    .nearestAllowedMidi(to: midi) - midi))
        }
        #expect(worstChromatic <= 0.5 + 1e-9)
        #expect(worstMajor <= 1.0 + 1e-9)
        #expect(worstMinor <= 1.0 + 1e-9)
        // NEGATIVE CONTROL: a tighter bound REDDENS, so these are not vacuous
        // ceilings that any implementation would clear.
        #expect(worstChromatic > 0.49)
        #expect(worstMajor > 0.99)
        #expect(worstMinor > 0.99)
    }

    @Test("an exact tie snaps UP, deterministically")
    func tieBreaksUpward() {
        // C#4 (61) sits exactly between C (60) and D (62) in C major.
        let cMajor = PitchCorrectionScale(tonicPitchClass: 0, mode: .major)
        #expect(cMajor.nearestAllowedMidi(to: 61) == 62)
        // Not a tie: 60.9 is nearer C than D.
        #expect(cMajor.nearestAllowedMidi(to: 60.9) == 60)
        #expect(cMajor.nearestAllowedMidi(to: 61.1) == 62)
    }
}

// MARK: - The auto-correct policy

struct PitchAutoCorrectPolicyTests {

    /// LEG 1 — an off-key note is pulled onto the scale, and the correction is
    /// verified IN CENTS on the sounding pitch.
    ///
    /// 445 Hz is A4 + 19.562 cents (1200·log₂(445/440)). A is in C major, so
    /// the whole correction is the −19.562 cents that puts it back on A440.
    @Test("an off-key note is pulled to the scale, measured in cents on the RESULT")
    func offKeyNoteIsPulledToScale() throws {
        let frames = Contour.note(startSeconds: 0.2, durationSeconds: 1.0, centreHz: 445)
        let options = PitchAutoCorrectOptions(
            scale: PitchCorrectionScale(tonicPitchClass: 0, mode: .major),
            strength: 1, retuneMs: 30, preserveVibrato: true)
        let set = PitchAutoCorrect.editSet(contour: frames,
                                           frameRateHz: Contour.frameRateHz,
                                           options: options)
        try #require(set.segments.count == 1)
        let curve = PitchCorrectionCurve.make(editSet: set, contour: frames)

        // Sampled strictly inside the note, clear of both boundary ramps.
        let sounding = soundingCents(frames: frames, curve: curve, from: 0.4, to: 1.0)
        #expect(sounding.count > 30)
        let worstError = sounding.map { abs($0 - 0) }.max() ?? .infinity
        // A440 is 0 cents from A440: the note now sounds ON the scale pitch.
        #expect(worstError < 0.5)

        // The edit itself, in the units the model stores.
        let offset = set.segments[0].pitchOffsetCents
        #expect(abs(offset - (-19.562)) < 0.05)

        // NEGATIVE CONTROLS — the same 0.05-cent window REJECTS both the
        // do-nothing policy and the doubled one, so it has teeth.
        #expect(abs(0.0 - (-19.562)) >= 0.05)
        #expect(abs(-39.124 - (-19.562)) >= 0.05)
        // And the uncorrected performance fails the 0.5-cent sounding bar by a
        // wide margin — proving the bar is not something silence would pass.
        let uncorrected = frames.compactMap { $0.frequencyHz.map(Contour.centsFromA440) }
        #expect((uncorrected.map { abs($0) }.max() ?? 0) > 19)
    }

    /// Correction SCALES with strength, and the detection facts never move.
    @Test("strength scales the correction; detectedHz is never mutated by an edit")
    func strengthScalesAndDetectionIsImmutable() throws {
        let frames = Contour.note(startSeconds: 0, durationSeconds: 0.8, centreHz: 445)
        let cMajor = PitchCorrectionScale(tonicPitchClass: 0, mode: .major)
        var offsets: [Double] = []
        for strength in [0.25, 0.5, 1.0] {
            let set = PitchAutoCorrect.editSet(
                contour: frames, frameRateHz: Contour.frameRateHz,
                options: PitchAutoCorrectOptions(scale: cMajor, strength: strength))
            let only = try #require(set.segments.first)
            #expect(set.segments.count == 1)
            offsets.append(only.pitchOffsetCents)
            // The detector said 445 Hz; no strength changes that.
            #expect(abs(only.detectedHz - 445) < 0.01)
        }
        #expect(abs(offsets[0] - (-19.562 * 0.25)) < 0.05)
        #expect(abs(offsets[1] - (-19.562 * 0.50)) < 0.05)
        #expect(abs(offsets[2] - (-19.562)) < 0.05)
        // NEGATIVE CONTROL: the three are genuinely different, so an
        // implementation that ignored `strength` could not pass all three.
        #expect(offsets[0] != offsets[1] && offsets[1] != offsets[2])

        // An EDIT does not touch the detection facts — the property that makes
        // the curve a pure function of (contour, edits) and re-detecting on
        // already-corrected audio structurally impossible.
        let set = PitchAutoCorrect.editSet(
            contour: frames, frameRateHz: Contour.frameRateHz,
            options: PitchAutoCorrectOptions(scale: cMajor, strength: 1))
        var segment = try #require(set.segments.first)
        let detectedBefore = segment.detectedHz
        let confidenceBefore = segment.detectedConfidence
        segment.pitchOffsetCents = 700
        segment.vibratoScale = 0
        #expect(segment.detectedHz == detectedBefore)
        #expect(segment.detectedConfidence == confidenceBefore)
    }

    /// The note's centre is the MEDIAN, and that choice is load-bearing: a
    /// singer scooping up into a note produces an ASYMMETRIC contour that drags
    /// a mean flat while leaving a median where the note actually sits.
    ///
    /// ⚠️ **THIS TEST EXISTS BECAUSE MUTATION TESTING FOUND ITS ABSENCE.**
    /// Swapping the log-median for an arithmetic mean of the raw Hz survived
    /// every other test in this file — the symmetric vibrato and constant-pitch
    /// fixtures cannot tell the two apart (for a symmetric contour they agree
    /// to ~0.4 cents). Only an asymmetric contour separates them.
    @Test("the centre is a MEDIAN: an onset scoop does not drag the note flat")
    func onsetScoopDoesNotDragTheCentre() throws {
        // 128 ms of scoop from 200 cents flat, then 1.0 s held on 445 Hz.
        let frames = Contour.scoopedNote(startSeconds: 0, scoopSeconds: 0.128,
                                         scoopCents: -200, sustainSeconds: 1.0,
                                         centreHz: 445)
        let runs = PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: Contour.frameRateHz)
        try #require(runs.count == 1)
        let centreCents = Contour.centsFromA440(runs[0].centreHz)
        // The note's centre is where it was HELD: 445 Hz = +19.562 cents.
        #expect(abs(centreCents - 19.562) < 2.0)

        // NEGATIVE CONTROL — the arithmetic mean of the same frames is dragged
        // measurably flat, and the 2-cent window above REJECTS it. Computed
        // here rather than asserted as a constant, so the control tracks the
        // fixture if the fixture changes.
        let hz = frames.compactMap(\.frequencyHz)
        let meanCents = Contour.centsFromA440(hz.reduce(0, +) / Double(hz.count))
        #expect(abs(meanCents - 19.562) > 2.0)
        #expect(meanCents < centreCents)   // the mean is FLAT of the median

        // The correction that follows is therefore the real one: A is in C
        // major, so the note goes back to A440 and not somewhere below it.
        let set = PitchAutoCorrect.editSet(
            contour: frames, frameRateHz: Contour.frameRateHz,
            options: PitchAutoCorrectOptions(
                scale: PitchCorrectionScale(tonicPitchClass: 0, mode: .major), strength: 1))
        #expect(abs(try #require(set.segments.first).pitchOffsetCents - (-19.562)) < 2.0)
    }

    /// ⚠️ **A RECORDED NON-RESULT, NOT A GUARD.** Mutation testing swapped the
    /// log-domain median for a plain linear one and every test still passed.
    /// That is arithmetic, not a hole: over an ODD count a median is an ELEMENT
    /// of the sample and `log2` is monotonic, so both forms pick the same
    /// frame and agree exactly; they can differ only on an EVEN count, by less
    /// than the gap between two adjacent detector frames.
    ///
    /// This test MEASURES that difference on the suite's own vibrato fixture
    /// and prints it, so the claim is a number rather than an argument — and
    /// so nobody later writes a test that pretends to guard the choice.
    @Test("RECORDED: log and linear medians agree to a fraction of a cent here")
    func logAndLinearMediansAgreeOnDenseContours() throws {
        for (label, frames) in [
            ("vibrato 100c/5Hz", Contour.note(startSeconds: 0, durationSeconds: 1.2,
                                              centreHz: 445,
                                              vibratoPeakToPeakCents: 100, vibratoHz: 5)),
            ("scoop −200c", Contour.scoopedNote(startSeconds: 0, scoopSeconds: 0.128,
                                                scoopCents: -200, sustainSeconds: 1.0,
                                                centreHz: 445)),
        ] {
            let hz = frames.compactMap(\.frequencyHz)
            let logMedian = try #require(PitchCorrectionMath.medianFrequency(hz))
            let linearMedian = try #require(PitchCorrectionMath.median(hz))
            let deltaCents = abs(PitchCorrectionMath.cents(from: linearMedian, to: logMedian))
            print("[measured] \(label): log median \(logMedian) Hz, "
                  + "linear median \(linearMedian) Hz, Δ \(deltaCents) cents "
                  + "over \(hz.count) frames")
            #expect(deltaCents < 0.5)

            // The EVEN-count case is the only one where the two forms can
            // differ at all (an odd count makes the median an ELEMENT, and
            // `log2` is monotonic, so both pick the same frame). Dropping one
            // frame forces it, and the difference is still bounded by the gap
            // between two ADJACENT frames.
            let even = Array(hz.dropLast())
            #expect(even.count % 2 == 0)
            let evenDelta = abs(PitchCorrectionMath.cents(
                from: try #require(PitchCorrectionMath.median(even)),
                to: try #require(PitchCorrectionMath.medianFrequency(even))))
            print("[measured] \(label) EVEN count \(even.count): Δ \(evenDelta) cents")
            #expect(evenDelta < 0.5)
        }
        // POSITIVE CONTROL for the comparison itself: on a SPARSE two-element
        // sample an octave apart, the two forms diverge by 51.3 cents — so the
        // 0.5-cent agreement above is a property of dense contours, not of the
        // measurement being blind.
        let sparse = [220.0, 440.0]
        let sparseLog = try #require(PitchCorrectionMath.medianFrequency(sparse))
        let sparseLinear = try #require(PitchCorrectionMath.median(sparse))
        #expect(abs(sparseLog - 311.1269837) < 1e-4)
        #expect(sparseLinear == 330)
        #expect(abs(PitchCorrectionMath.cents(from: sparseLinear, to: sparseLog)) > 50)
    }

    /// LEG 2 — THE MUSICAL/ROBOT SPLIT. The note's CENTRE is corrected and the
    /// modulation SURVIVES; flip one flag and it is flattened.
    ///
    /// Both halves are asserted on the SOUNDING contour, and each half's bound
    /// excludes the other half's outcome — so a bug that swapped the two
    /// branches reddens twice.
    @Test("preserveVibrato corrects the CENTRE and keeps the modulation; off, it flattens")
    func vibratoSurvivesCorrectionAndFlattensOnDemand() throws {
        // 100 cents peak-to-peak at 5 Hz on a centre of 445 Hz — a wide, fast
        // vibrato, so a policy that half-flattened it would be visible.
        let frames = Contour.note(startSeconds: 0.2, durationSeconds: 1.2,
                                  centreHz: 445,
                                  vibratoPeakToPeakCents: 100, vibratoHz: 5)
        let inputDepth = peakToPeak(frames.compactMap { $0.frequencyHz.map(Contour.centsFromA440) })
        #expect(abs(inputDepth - 100) < 3)

        let cMajor = PitchCorrectionScale(tonicPitchClass: 0, mode: .major)

        // ── KEEP ────────────────────────────────────────────────────────────
        let keepSet = PitchAutoCorrect.editSet(
            contour: frames, frameRateHz: Contour.frameRateHz,
            options: PitchAutoCorrectOptions(scale: cMajor, strength: 1,
                                             preserveVibrato: true))
        let keepSegment = try #require(keepSet.segments.first)
        #expect(keepSet.segments.count == 1)
        #expect(keepSegment.vibratoScale == 1)
        #expect(keepSegment.driftScale == 1)
        let keepCurve = PitchCorrectionCurve.make(editSet: keepSet, contour: frames)
        let kept = soundingCents(frames: frames, curve: keepCurve, from: 0.4, to: 1.2)
        let keptDepth = peakToPeak(kept)
        // The modulation is RETAINED, not merely "not fully removed".
        #expect(abs(keptDepth - inputDepth) < 1.0)
        // …and the CENTRE has moved onto A440: the mean of a symmetric
        // modulation is its centre.
        let keptCentre = kept.reduce(0, +) / Double(kept.count)
        #expect(abs(keptCentre) < 1.5)

        // ── FLATTEN ─────────────────────────────────────────────────────────
        let robotSet = PitchAutoCorrect.editSet(
            contour: frames, frameRateHz: Contour.frameRateHz,
            options: PitchAutoCorrectOptions(scale: cMajor, strength: 1,
                                             preserveVibrato: false))
        let robotSegment = try #require(robotSet.segments.first)
        #expect(robotSegment.vibratoScale == 0)
        #expect(robotSegment.driftScale == 0)
        let robotCurve = PitchCorrectionCurve.make(editSet: robotSet, contour: frames)
        #expect(robotCurve.unresolvedShapingSegmentIDs.isEmpty)
        let robot = soundingCents(frames: frames, curve: robotCurve, from: 0.4, to: 1.2)
        let robotDepth = peakToPeak(robot)
        // Flat, at the target.
        #expect(robotDepth < 2.0)
        #expect((robot.map { abs($0) }.max() ?? .infinity) < 2.0)

        // NEGATIVE CONTROLS — each branch's bound EXCLUDES the other branch's
        // measured outcome, so the two cannot both be satisfied by one
        // behaviour and a swap of the flag reddens.
        #expect(robotDepth < 2.0 && keptDepth > 95)
        #expect(abs(robotDepth - inputDepth) >= 1.0)   // the flatten bar would REJECT "kept"
        #expect(keptDepth >= 2.0)                      // the keep bar would REJECT "flattened"
    }

    /// Partial flattening is continuous in strength — the robot branch is a
    /// scale, not a switch, and at strength 0 it is the identity.
    @Test("partial strength partially flattens, monotonically")
    func partialFlatteningIsMonotonic() {
        let frames = Contour.note(startSeconds: 0, durationSeconds: 1.2, centreHz: 445,
                                  vibratoPeakToPeakCents: 100, vibratoHz: 5)
        let cMajor = PitchCorrectionScale(tonicPitchClass: 0, mode: .major)
        var depths: [Double] = []
        for strength in [0.25, 0.5, 1.0] {
            let set = PitchAutoCorrect.editSet(
                contour: frames, frameRateHz: Contour.frameRateHz,
                options: PitchAutoCorrectOptions(scale: cMajor, strength: strength,
                                                 preserveVibrato: false))
            let curve = PitchCorrectionCurve.make(editSet: set, contour: frames)
            depths.append(peakToPeak(soundingCents(frames: frames, curve: curve,
                                                   from: 0.2, to: 1.0)))
        }
        #expect(depths[0] > depths[1] && depths[1] > depths[2])
        // NEGATIVE CONTROL: the spread is LARGE, so this is not three equal
        // numbers passing a strict-inequality chain by floating-point noise.
        #expect(depths[0] - depths[2] > 50)
    }

    /// LEG 3 — A HOLE IS NOT FILLED, NOT INTERPOLATED ACROSS, AND NOT CORRECTED.
    ///
    /// Two notes an octave-and-a-bit apart with an unvoiced gap between them.
    /// If the gap were bridged, ONE run would form and its median would land
    /// between the two pitches — nowhere either note was sung.
    @Test("an unvoiced hole ends the note: not filled, not interpolated, not corrected")
    func holesAreNeverFilled() throws {
        let first = Contour.note(startSeconds: 0.0, durationSeconds: 0.4, centreHz: 445)
        let gap = Contour.hole(startSeconds: 0.4, durationSeconds: 0.3)
        let second = Contour.note(startSeconds: 0.7, durationSeconds: 0.4, centreHz: 227)
        let frames = first + gap + second

        let set = PitchAutoCorrect.editSet(
            contour: frames, frameRateHz: Contour.frameRateHz,
            options: PitchAutoCorrectOptions(
                scale: PitchCorrectionScale(tonicPitchClass: 0, mode: .major),
                strength: 1, retuneMs: 30))

        // TWO notes, each with the pitch that was actually sung in it.
        // `#require`, not `#expect`: a BRIDGED run yields one segment, and
        // indexing [1] on it would CRASH the whole test process instead of
        // reddening this one test. (Mutation testing found exactly that — the
        // hole-filling mutant took the runner down rather than failing.)
        try #require(set.segments.count == 2)
        #expect(abs(set.segments[0].detectedHz - 445) < 0.5)
        #expect(abs(set.segments[1].detectedHz - 227) < 0.5)
        // NEGATIVE CONTROL: a bridged run's median would be ~317 Hz (the
        // geometric centre), which neither segment is anywhere near — so
        // "two segments" is not the only way this could have come out.
        #expect(!set.segments.contains { abs($0.detectedHz - 317) < 30 })

        // No segment may overlap the hole's interior.
        for segment in set.segments {
            #expect(segment.endSeconds <= 0.42 || segment.startSeconds >= 0.68)
        }

        let curve = PitchCorrectionCurve.make(editSet: set, contour: frames)
        // The hole's INTERIOR is EXACTLY uncorrected — bit-exact zero, not a
        // small number. The ±15 ms margins are the §6.4 boundary ramp, which is
        // the renderer's own minimum transition and is physically required; the
        // probe excludes them deliberately rather than by accident.
        for step in 0...40 {
            let t = 0.44 + Double(step) * (0.24 / 40)
            #expect(curve.semitones(atSourceSecond: t) == 0.0)
        }
        // NEGATIVE CONTROL: inside the notes the curve is emphatically NOT
        // zero, so "returns zero everywhere" would fail this test.
        #expect(abs(curve.semitones(atSourceSecond: 0.2) - (-0.19562)) < 0.001)
        #expect(abs(curve.semitones(atSourceSecond: 0.9) - (-0.54229)) < 0.001)
    }

    /// LEG 4 — `strength = 0` is EXACTLY identity.
    @Test("strength 0 is EXACTLY identity: no segments, no offsets, bit-exact curve")
    func strengthZeroIsExactIdentity() throws {
        let frames = Contour.note(startSeconds: 0, durationSeconds: 1.0, centreHz: 445,
                                  vibratoPeakToPeakCents: 80, vibratoHz: 6)
        let cMajor = PitchCorrectionScale(tonicPitchClass: 0, mode: .major)

        for preserve in [true, false] {
            let set = PitchAutoCorrect.editSet(
                contour: frames, frameRateHz: Contour.frameRateHz,
                options: PitchAutoCorrectOptions(scale: cMajor, strength: 0,
                                                 preserveVibrato: preserve))
            #expect(set.segments.isEmpty)
            #expect(set.isEmpty)
            #expect(set.isIdentity)
            #expect(set == PitchEditSet.empty)

            // BIT-EXACT: the curve is the clip's own constant shift and nothing
            // else, at every probe, including a shift of −3 semitones.
            let curve = PitchCorrectionCurve.make(editSet: set, contour: frames,
                                                  clipPitchShiftSemitones: -3)
            for step in 0...200 {
                #expect(curve.semitones(atSourceSecond: Double(step) / 100) == -3.0)
            }
            // A clip built from it carries NO edit set at all.
            #expect(Clip(name: "c", pitchEdits: set).pitchEdits == nil)
        }

        // NEGATIVE CONTROL: the very next value of strength is NOT identity, so
        // "strength 0 is identity" is a property of 0 and not of the policy
        // being inert.
        let nudged = PitchAutoCorrect.editSet(
            contour: frames, frameRateHz: Contour.frameRateHz,
            options: PitchAutoCorrectOptions(scale: cMajor, strength: 0.05))
        #expect(nudged.segments.count == 1)
        #expect(try #require(nudged.segments.first).pitchOffsetCents != 0)
        #expect(!nudged.isIdentity)
    }

    /// The segmentation seam Phase 2 replaces, pinned so the limitation is
    /// VISIBLE rather than discovered by a user. Design §11.2 gives
    /// segmentation its own design doc; inventing a target-change splitter here
    /// would build on a foundation that is still being designed.
    @Test("KNOWN PHASE-2 LIMIT: a legato slur is ONE run, and the pin says so")
    func legatoSlurIsOneSegmentToday() {
        // Two pitches, no gap between them — the singer never stopped.
        let frames = Contour.note(startSeconds: 0, durationSeconds: 0.5, centreHz: 440)
            + Contour.note(startSeconds: 0.5, durationSeconds: 0.5, centreHz: 494)
        let set = PitchAutoCorrect.editSet(
            contour: frames, frameRateHz: Contour.frameRateHz,
            options: PitchAutoCorrectOptions(
                scale: PitchCorrectionScale(tonicPitchClass: 0, mode: .major), strength: 1))
        // ⚠️ ONE segment — today's honest behaviour, not the desired one.
        #expect(set.segments.count == 1)
        // NEGATIVE CONTROL / the contrast that shows WHY: insert a 200 ms hole
        // between exactly the same two pitches and it becomes two.
        let separated = Contour.note(startSeconds: 0, durationSeconds: 0.5, centreHz: 440)
            + Contour.hole(startSeconds: 0.5, durationSeconds: 0.2)
            + Contour.note(startSeconds: 0.7, durationSeconds: 0.5, centreHz: 494)
        #expect(PitchAutoCorrect.editSet(
            contour: separated, frameRateHz: Contour.frameRateHz,
            options: PitchAutoCorrectOptions(
                scale: PitchCorrectionScale(tonicPitchClass: 0, mode: .major),
                strength: 1)).segments.count == 2)
    }

    @Test("a run shorter than the minimum is not a note; an empty or rate-less contour is empty")
    func shortRunsAndDegenerateInputs() {
        let options = PitchAutoCorrectOptions(strength: 1)
        // 32 ms = 2 frames, under the 60 ms floor.
        let blip = Contour.note(startSeconds: 0, durationSeconds: 0.032, centreHz: 445)
        #expect(PitchAutoCorrect.editSet(contour: blip, frameRateHz: Contour.frameRateHz,
                                         options: options).segments.isEmpty)
        // NEGATIVE CONTROL: 160 ms of the SAME pitch IS a note.
        let real = Contour.note(startSeconds: 0, durationSeconds: 0.16, centreHz: 445)
        #expect(PitchAutoCorrect.editSet(contour: real, frameRateHz: Contour.frameRateHz,
                                         options: options).segments.count == 1)

        #expect(PitchAutoCorrect.editSet(contour: [], frameRateHz: Contour.frameRateHz,
                                         options: options).segments.isEmpty)
        #expect(PitchAutoCorrect.editSet(contour: real, frameRateHz: 0,
                                         options: options).segments.isEmpty)
        #expect(PitchAutoCorrect.editSet(contour: real, frameRateHz: .nan,
                                         options: options).segments.isEmpty)
        // All-unvoiced is empty, and is NOT an error.
        #expect(PitchAutoCorrect.editSet(contour: Contour.hole(startSeconds: 0,
                                                               durationSeconds: 2),
                                         frameRateHz: Contour.frameRateHz,
                                         options: options).segments.isEmpty)
    }

    @Test("the PitchDetectionResult convenience uses the RESULT's own frame rate")
    func resultConvenienceForwards() throws {
        let frames = Contour.note(startSeconds: 0, durationSeconds: 0.8, centreHz: 445)
        let result = PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: frames.count,
            voicedFraction: 1, frameRateHz: Contour.frameRateHz,
            analysisSampleRateHz: 16_000, sourceSampleRateHz: 48_000,
            windowStartSeconds: 0, windowDurationSeconds: 0.8,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs,
            minFrequencyHz: 46.875, maxFrequencyHz: 2093.75)
        let options = PitchAutoCorrectOptions(
            scale: PitchCorrectionScale(tonicPitchClass: 0, mode: .major), strength: 1)
        let viaResult = PitchAutoCorrect.editSet(from: result, options: options)
        let viaFrames = PitchAutoCorrect.editSet(contour: frames,
                                                 frameRateHz: Contour.frameRateHz,
                                                 options: options)
        #expect(viaResult.segments.count == 1)
        #expect(abs(try #require(viaResult.segments.first).pitchOffsetCents
                    - (try #require(viaFrames.segments.first)).pitchOffsetCents) < 1e-12)
    }
}

// MARK: - The one evaluator

struct PitchCorrectionCurveTests {

    private func segment(_ start: Double, _ end: Double, cents: Double) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: end, detectedHz: 440,
                    detectedConfidence: 0.95, pitchOffsetCents: cents)
    }

    @Test("an empty set is the clip's own shift, bit-exact, everywhere")
    func emptySetIsBitExactIdentity() {
        for shift in [0.0, -3.0, 7.5] {
            let curve = PitchCorrectionCurve.make(editSet: .empty,
                                                  clipPitchShiftSemitones: shift)
            for step in -50...300 {
                #expect(curve.semitones(atSourceSecond: Double(step) / 10) == shift)
            }
        }
    }

    /// The curve SUBSUMES `Clip.pitchShiftSemitones` (§6.4/§7.8: no second
    /// whole-clip pitch path). A renderer driven by this curve must not also
    /// apply the constant shift.
    @Test("the clip's whole-clip shift is SUMMED IN, not ignored and not applied twice")
    func clipShiftIsSubsumed() {
        let set = PitchEditSet(segments: [segment(1, 2, cents: -50)])
        let curve = PitchCorrectionCurve.make(editSet: set, clipPitchShiftSemitones: 4)
        #expect(abs(curve.semitones(atSourceSecond: 1.5) - 3.5) < 1e-12)
        // Outside any note it is the bare clip shift, bit-exact.
        #expect(curve.semitones(atSourceSecond: 0.1) == 4.0)
        #expect(curve.semitones(atSourceSecond: 5.0) == 4.0)
        // NEGATIVE CONTROL: both plausible bugs give different numbers.
        #expect(abs(curve.semitones(atSourceSecond: 1.5) - (-0.5)) > 1e-6)  // shift dropped
        #expect(abs(curve.semitones(atSourceSecond: 1.5) - 7.5) > 1e-6)     // shift doubled
    }

    /// §6.4: smooth inside a note, fast but never instantaneous across a
    /// boundary. Phase-0 §5.4 measured what an instantaneous jump costs:
    /// −5.11 dB of level dip at 2 semitones, against −1.20 dB spread over three
    /// hops.
    @Test("boundaries ramp: continuous, monotone, and never instantaneous")
    func boundariesRampSmoothly() {
        let set = PitchEditSet(segments: [segment(1.0, 2.0, cents: 200)], retuneMs: 40)
        let curve = PitchCorrectionCurve.make(editSet: set)
        // Outside the ramp: exactly 0 before, exactly the target inside.
        #expect(curve.semitones(atSourceSecond: 0.90) == 0.0)
        #expect(abs(curve.semitones(atSourceSecond: 1.50) - 2.0) < 1e-12)
        #expect(curve.semitones(atSourceSecond: 2.10) == 0.0)
        // The ramp is CENTRED on the boundary: half-way up exactly at it.
        #expect(abs(curve.semitones(atSourceSecond: 1.0) - 1.0) < 1e-9)

        // No step larger than a small fraction of the move, sampled at 0.1 ms
        // across the whole ramp — i.e. it is a ramp, not a disguised jump.
        var previous = curve.semitones(atSourceSecond: 0.95)
        var worstStep = 0.0
        for step in 1...1000 {
            let value = curve.semitones(atSourceSecond: 0.95 + Double(step) * 0.0001)
            worstStep = max(worstStep, abs(value - previous))
            previous = value
        }
        #expect(worstStep < 0.02)
        // NEGATIVE CONTROL: the same probe over an INSTANTANEOUS 2-semitone
        // step would read 2.0. It does not, and the measured value is orders of
        // magnitude below — so the bound is not something any curve would pass.
        #expect(worstStep > 0)
        #expect(worstStep < 2.0 / 50)
    }

    /// Abutting notes must CROSSFADE, not notch. Complementary smoothsteps sum
    /// to exactly 1, which is the whole reason the ramps are centred on the
    /// boundary rather than sitting one-sided inside each note.
    @Test("two abutting notes crossfade: the shared boundary is the MIDPOINT, no notch")
    func abuttingNotesCrossfadeWithoutANotch() {
        let set = PitchEditSet(segments: [segment(0, 1, cents: -100),
                                          segment(1, 2, cents: 300)], retuneMs: 50)
        let curve = PitchCorrectionCurve.make(editSet: set)
        // Exactly at the boundary: the midpoint of −1 and +3 semitones.
        #expect(abs(curve.semitones(atSourceSecond: 1.0) - 1.0) < 1e-9)
        // Across the whole crossfade the value stays BETWEEN the two targets —
        // no notch toward 0, no overshoot past either.
        for step in 0...200 {
            let t = 0.975 + Double(step) * (0.05 / 200)
            let value = curve.semitones(atSourceSecond: t)
            #expect(value >= -1.0 - 1e-9 && value <= 3.0 + 1e-9)
        }
        // NEGATIVE CONTROL: a one-sided ramp would notch to 0 at the boundary,
        // and 0 is inside [−1, 3] — so the bracket alone is not enough. The
        // midpoint assertion above is what excludes it, and here is the
        // explicit statement that 0 is NOT what comes out.
        #expect(abs(curve.semitones(atSourceSecond: 1.0)) > 0.5)
    }

    /// Very short notes under a long ramp are the one case where gates can
    /// over-sum. The result must stay a BLEND of the active corrections.
    @Test("short notes under a long ramp blend, never overshoot")
    func shortNotesNeverOvershoot() {
        let set = PitchEditSet(segments: [segment(0.00, 0.05, cents: 400),
                                          segment(0.05, 0.10, cents: -400),
                                          segment(0.10, 0.15, cents: 400)],
                               retuneMs: 200)
        let curve = PitchCorrectionCurve.make(editSet: set)
        var worst = 0.0
        for step in 0...600 {
            let value = curve.semitones(atSourceSecond: -0.05 + Double(step) * 0.0005)
            worst = max(worst, abs(value))
        }
        // Never past the largest single correction.
        #expect(worst <= 4.0 + 1e-9)
        // NEGATIVE CONTROL: it is not trivially zero either — something is
        // being produced for the bound to bound.
        #expect(worst > 0.5)
    }

    /// §7.3 deliberately does NOT persist the detected contour, so a reopened
    /// project can carry shaping edits with nothing to shape. That must be
    /// READABLE, not a silently-omitted term.
    @Test("shaping without a contour is REPORTED, not invented — and the constant still applies")
    func shapingWithoutAContourIsHonest() {
        let shaped = NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 440,
                                 detectedConfidence: 0.9, pitchOffsetCents: -50,
                                 driftScale: 0, vibratoScale: 0)
        let set = PitchEditSet(segments: [shaped])

        let blind = PitchCorrectionCurve.make(editSet: set, contour: [])
        #expect(blind.unresolvedShapingSegmentIDs == [shaped.id])
        // The constant correction still lands — the shaping term is the only
        // thing missing.
        #expect(abs(blind.semitones(atSourceSecond: 0.5) - (-0.5)) < 1e-12)

        // NEGATIVE CONTROL: give it the contour and nothing is unresolved.
        let frames = Contour.note(startSeconds: 0, durationSeconds: 1.0, centreHz: 440,
                                  vibratoPeakToPeakCents: 60, vibratoHz: 5)
        let sighted = PitchCorrectionCurve.make(editSet: set, contour: frames)
        #expect(sighted.unresolvedShapingSegmentIDs.isEmpty)
        // …and it now does something DIFFERENT, so "resolved" is not cosmetic.
        #expect(abs(sighted.semitones(atSourceSecond: 0.55)
                    - blind.semitones(atSourceSecond: 0.55)) > 0.001)

        // A segment with DEFAULT scales never needs a contour and is never
        // reported unresolved.
        let plain = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 440,
                        detectedConfidence: 0.9, pitchOffsetCents: -50)])
        #expect(PitchCorrectionCurve.make(editSet: plain, contour: [])
            .unresolvedShapingSegmentIDs.isEmpty)
    }

    /// The drift/vibrato split CANCELS whenever the two scales are equal, which
    /// is every set the Phase-1 policy produces. That makes the window an
    /// uncalibrated pick that Phase 1 never exercises — asserted rather than
    /// argued, because the window is the one number in this file nobody
    /// measured.
    @Test("with equal drift/vibrato scales the split cancels: the window cannot matter")
    func equalScalesMakeTheWindowIrrelevant() {
        let frames = Contour.note(startSeconds: 0, durationSeconds: 1.2, centreHz: 445,
                                  vibratoPeakToPeakCents: 90, vibratoHz: 5,
                                  driftCents: 40)
        let equal = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1.2, detectedHz: 445,
                        detectedConfidence: 0.95, pitchOffsetCents: -19.562,
                        driftScale: 0.5, vibratoScale: 0.5)])
        let curve = PitchCorrectionCurve.make(editSet: equal, contour: frames)

        // Algebraic prediction, computed WITHOUT any windowing: with both
        // scales at s, the shaping term is exactly (s − 1)·(contour − centre).
        for frame in frames where frame.timeSeconds > 0.2 && frame.timeSeconds < 1.0 {
            let deviation = 1200 * log2((frame.frequencyHz ?? 445) / 445)
            let predicted = (-19.562 + (0.5 - 1) * deviation) / 100
            #expect(abs(curve.semitones(atSourceSecond: frame.timeSeconds) - predicted) < 1e-6)
        }

        // NEGATIVE CONTROL: make the scales UNEQUAL and the prediction fails —
        // so the equality above is a property of the cancellation, not of the
        // predicate being loose.
        let unequal = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1.2, detectedHz: 445,
                        detectedConfidence: 0.95, pitchOffsetCents: -19.562,
                        driftScale: 0.5, vibratoScale: 1.0)])
        let other = PitchCorrectionCurve.make(editSet: unequal, contour: frames)
        var sawADifference = false
        for frame in frames where frame.timeSeconds > 0.2 && frame.timeSeconds < 1.0 {
            let deviation = 1200 * log2((frame.frequencyHz ?? 445) / 445)
            let predicted = (-19.562 + (0.5 - 1) * deviation) / 100
            if abs(other.semitones(atSourceSecond: frame.timeSeconds) - predicted) > 1e-6 {
                sawADifference = true
            }
        }
        #expect(sawADifference)
    }

    @Test("NaN and infinity in, a finite number out — at the input and in the model")
    func denormalAndNaNGuards() {
        let set = PitchEditSet(segments: [segment(1, 2, cents: 100)])
        let curve = PitchCorrectionCurve.make(editSet: set, clipPitchShiftSemitones: 2)
        #expect(curve.semitones(atSourceSecond: .nan) == 2.0)
        #expect(curve.semitones(atSourceSecond: .infinity) == 2.0)
        #expect(curve.semitones(atSourceSecond: -.infinity) == 2.0)
        for step in -100...400 {
            #expect(curve.semitones(atSourceSecond: Double(step) / 10).isFinite)
        }

        // A non-finite clip shift is neutralised rather than propagated.
        #expect(PitchCorrectionCurve.make(editSet: set, clipPitchShiftSemitones: .nan)
            .semitones(atSourceSecond: 0) == 0.0)

        // A poisoned segment heals at construction — a NaN offset becomes 0, a
        // NaN scale becomes 1, and nothing downstream ever sees the NaN.
        let poisoned = NoteSegment(startSeconds: .nan, endSeconds: .infinity,
                                   detectedHz: .nan, detectedConfidence: .nan,
                                   pitchOffsetCents: .nan, driftScale: .nan,
                                   vibratoScale: .infinity,
                                   formantOffsetSemitones: .nan,
                                   timeStartDeltaSeconds: .nan,
                                   timeEndDeltaSeconds: .nan, amplitudeDb: .nan)
        #expect(poisoned.startSeconds == 0)
        #expect(poisoned.endSeconds == 0)
        #expect(poisoned.detectedHz == 0)
        #expect(poisoned.detectedConfidence == 0)
        #expect(poisoned.pitchOffsetCents == 0)
        #expect(poisoned.driftScale == 1)
        // +∞ is not finite, so it heals to the DEFAULT (1) rather than being
        // clamped to the range's ceiling (4) — "not a number" and "too big" are
        // different failures and get different answers.
        #expect(poisoned.vibratoScale == 1)
        #expect(poisoned.amplitudeDb == 0)
        #expect(poisoned.isIdentity)
    }

    @Test("the curve is deterministic — the same inputs give bit-identical output")
    func curveIsDeterministic() {
        let frames = Contour.note(startSeconds: 0, durationSeconds: 1.0, centreHz: 445,
                                  vibratoPeakToPeakCents: 70, vibratoHz: 4)
        let set = PitchAutoCorrect.editSet(
            contour: frames, frameRateHz: Contour.frameRateHz,
            options: PitchAutoCorrectOptions(strength: 0.8, preserveVibrato: false))
        let a = PitchCorrectionCurve.make(editSet: set, contour: frames,
                                          clipPitchShiftSemitones: 1.25)
        let b = PitchCorrectionCurve.make(editSet: set, contour: frames,
                                          clipPitchShiftSemitones: 1.25)
        #expect(a == b)
        for step in 0...300 {
            let t = Double(step) / 200
            #expect(a.semitones(atSourceSecond: t) == b.semitones(atSourceSecond: t))
        }
    }
}

// MARK: - The set's own invariants

struct PitchEditSetInvariantTests {

    @Test("segments canonicalize: sorted, non-overlapping first-wins, zero-length dropped")
    func canonicalization() throws {
        func seg(_ a: Double, _ b: Double) -> NoteSegment {
            NoteSegment(startSeconds: a, endSeconds: b, detectedHz: 440, detectedConfidence: 0.9)
        }
        let set = PitchEditSet(segments: [seg(2, 3), seg(0, 1), seg(0.5, 2.5), seg(4, 4)])
        // Sorted by start; the middle one is truncated to start where the first
        // ended; the zero-length one is gone.
        try #require(set.segments.count == 3)
        #expect(set.segments.map(\.startSeconds) == [0, 1, 2.5])
        #expect(set.segments.map(\.endSeconds) == [1, 2.5, 3])
        // Strictly non-overlapping — the invariant the curve relies on.
        for i in 1..<set.segments.count {
            #expect(set.segments[i].startSeconds >= set.segments[i - 1].endSeconds)
        }
        // A fully NESTED segment is dropped (first-wins).
        let nested = PitchEditSet(segments: [seg(0, 10), seg(2, 3)])
        #expect(nested.segments.count == 1)
        #expect(try #require(nested.segments.first).endSeconds == 10)
        // NEGATIVE CONTROL: the unhealed input DID overlap, so canonicalization
        // is doing work rather than being handed clean data.
        #expect(seg(0, 1).endSeconds > seg(0.5, 2.5).startSeconds)
    }

    @Test("isEmpty and isIdentity are DIFFERENT questions")
    func emptyAndIdentityDiffer() {
        let detectedOnly = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 440, detectedConfidence: 0.9)])
        #expect(!detectedOnly.isEmpty)     // there ARE notes, worth saving
        #expect(detectedOnly.isIdentity)   // …and they render as nothing
        #expect(PitchEditSet.empty.isEmpty && PitchEditSet.empty.isIdentity)

        let edited = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 440,
                        detectedConfidence: 0.9, pitchOffsetCents: -10)])
        #expect(!edited.isEmpty && !edited.isIdentity)

        // A detected-only set still carries through to the clip — this is the
        // note table an editor draws, and losing it would cost a model run.
        #expect(Clip(name: "c", pitchEdits: detectedOnly).pitchEdits == detectedOnly)
        #expect(Clip(name: "c", pitchEdits: detectedOnly).hasPitchEdits == false)
        #expect(Clip(name: "c", pitchEdits: edited).hasPitchEdits == true)
    }

    /// **EVERY** edit field breaks identity — including the phase-3/4 ones no
    /// renderer reads yet.
    ///
    /// ⚠️ **THIS PINS A DECISION, NOT JUST A BOOLEAN, AND THE RENDER
    /// INTEGRATION INHERITS IT.** When `Clip.hasPitchEdits` is eventually
    /// folded into `isStretchIdentity`, a segment carrying ONLY a phase-4 field
    /// (say `amplitudeDb`) will LEAVE the identity bypass and re-render, even
    /// though nothing reads that field today, so the audio comes back the same.
    /// That costs a needless render and is the CONSERVATIVE direction on
    /// purpose: the other answer — treat carried fields as identity — is
    /// silent, and it breaks on the day phase 4 starts rendering them, in a
    /// place nobody would look. Chosen now rather than discovered then.
    @Test("each of the seven edit fields ALONE breaks identity, carried ones included")
    func everyEditFieldBreaksIdentity() {
        func setWith(_ mutate: (inout NoteSegment) -> Void) -> PitchEditSet {
            var segment = NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 440,
                                      detectedConfidence: 0.9)
            mutate(&segment)
            return PitchEditSet(segments: [segment])
        }
        // The baseline: untouched IS identity, so the seven below are measuring
        // the field and not a broken predicate.
        #expect(setWith { _ in }.isIdentity)

        let cases: [(String, (inout NoteSegment) -> Void)] = [
            ("pitchOffsetCents", { $0.pitchOffsetCents = -10 }),
            ("driftScale", { $0.driftScale = 0.5 }),
            ("vibratoScale", { $0.vibratoScale = 0 }),
            ("formantOffsetSemitones (phase 4)", { $0.formantOffsetSemitones = -1.5 }),
            ("timeStartDeltaSeconds (phase 3)", { $0.timeStartDeltaSeconds = 0.01 }),
            ("timeEndDeltaSeconds (phase 3)", { $0.timeEndDeltaSeconds = -0.01 }),
            ("amplitudeDb (phase 4)", { $0.amplitudeDb = 2.5 }),
        ]
        for (name, mutate) in cases {
            let set = setWith(mutate)
            #expect(!set.isIdentity, "\(name) must break identity")
            #expect(!set.isEmpty, "\(name) must not be empty")
            #expect(Clip(name: "c", pitchEdits: set).hasPitchEdits,
                    "\(name) must make the clip report edits")
        }
        #expect(cases.count == 7)
    }

    /// The retune floor is an ENGINE limit — one 30 ms analysis hop at 48 kHz —
    /// and the value reads back as what ACTUALLY applies, because a setter's
    /// return is not proof it took.
    @Test("retuneMs clamps to the engine floor and reads back the applied value")
    func retuneClamps() {
        #expect(PitchEditSet(retuneMs: 0).retuneMs == PitchEditSet.engineMinimumRetuneMs)
        #expect(PitchEditSet(retuneMs: 5).retuneMs == 30)
        #expect(PitchEditSet(retuneMs: 120).retuneMs == 120)
        #expect(PitchEditSet(retuneMs: 9_999).retuneMs == 500)
        #expect(PitchEditSet(retuneMs: .nan).retuneMs == 30)
        // The same floor applies through the policy's options.
        #expect(PitchAutoCorrectOptions(retuneMs: 1).retuneMs == 30)
        #expect(PitchAutoCorrectOptions(strength: 5).strength == 1)
        #expect(PitchAutoCorrectOptions(strength: -2).strength == 0)
        #expect(PitchAutoCorrectOptions(strength: .nan).strength == 0)
        // NEGATIVE CONTROL: a value INSIDE the range is not clamped, so the
        // clamp is not simply pinning everything to one number.
        #expect(PitchEditSet(retuneMs: 45).retuneMs == 45)
    }

    /// The exact strings design §7.4 specifies — one home, so a store operation
    /// and a test can never disagree about the key.
    @Test("undo keys are the exact §7.4 strings, per-segment and per-verb")
    func undoKeys() {
        let clipID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let segmentID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        #expect(PitchCorrectionUndoKey.segment(clipID: clipID, segmentID: segmentID)
            == "pitch.segment:11111111-2222-3333-4444-555555555555:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(PitchCorrectionUndoKey.drift(clipID: clipID, segmentID: segmentID)
            == "pitch.drift:11111111-2222-3333-4444-555555555555:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(PitchCorrectionUndoKey.vibrato(clipID: clipID, segmentID: segmentID)
            == "pitch.vibrato:11111111-2222-3333-4444-555555555555:AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(PitchCorrectionUndoKey.structuralKey == nil)

        // The coalescing CONTRACT, not just the spelling: a different segment,
        // a different clip, or a different verb all produce a different key, so
        // none of those three coalesce with each other.
        let otherSegment = UUID()
        let otherClip = UUID()
        let base = PitchCorrectionUndoKey.segment(clipID: clipID, segmentID: segmentID)
        #expect(base != PitchCorrectionUndoKey.segment(clipID: clipID, segmentID: otherSegment))
        #expect(base != PitchCorrectionUndoKey.segment(clipID: otherClip, segmentID: segmentID))
        #expect(base != PitchCorrectionUndoKey.drift(clipID: clipID, segmentID: segmentID))
        // …while the SAME drag produces the SAME key, which is what coalesces.
        #expect(base == PitchCorrectionUndoKey.segment(clipID: clipID, segmentID: segmentID))
    }
}

// MARK: - Persistence: the four touch points, plus the fifth design §7.5 calls free

struct PitchCorrectionPersistenceTests {

    private func editedSet() -> PitchEditSet {
        PitchEditSet(analysisVersion: 1, segments: [
            NoteSegment(startSeconds: 0.25, endSeconds: 0.80, detectedHz: 445.0,
                        detectedConfidence: 0.973, pitchOffsetCents: -19.562),
            NoteSegment(startSeconds: 0.95, endSeconds: 1.60, detectedHz: 227.0,
                        detectedConfidence: 0.912, pitchOffsetCents: -54.23,
                        driftScale: 0.5, vibratoScale: 0,
                        formantOffsetSemitones: -1.5,
                        timeStartDeltaSeconds: 0.01, timeEndDeltaSeconds: -0.02,
                        amplitudeDb: 2.5),
        ], retuneMs: 80)
    }

    private func audioClip(pitchEdits: PitchEditSet? = nil) -> Clip {
        Clip(name: "Vox", lengthBeats: 8,
             audioFileURL: URL(fileURLWithPath: "/tmp/vox.wav"),
             pitchEdits: pitchEdits)
    }

    /// TOUCH POINT 1 — `Clip`'s own Codable (the WIRE: `project.snapshot`,
    /// command round-tripping). Deliberately not the disk path.
    @Test("touch point 1 — the wire: a clip with edits round-trips deep-equal")
    func wireRoundTrip() throws {
        let clip = audioClip(pitchEdits: editedSet())
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(back.pitchEdits == clip.pitchEdits)
        #expect(back == clip)
        // Every carried phase-3/4 field survives — they exist precisely so the
        // schema does not change under a saved project later.
        let restored = try #require(back.pitchEdits?.segments.last)
        #expect(restored.formantOffsetSemitones == -1.5)
        #expect(restored.timeStartDeltaSeconds == 0.01)
        #expect(restored.timeEndDeltaSeconds == -0.02)
        #expect(restored.amplitudeDb == 2.5)
        #expect(restored.driftScale == 0.5)
        #expect(restored.vibratoScale == 0)
        #expect(back.pitchEdits?.retuneMs == 80)
        #expect(back.pitchEdits?.analysisVersion == 1)
    }

    /// THE NULL ERA — an edit-free clip must not grow a single key, on EITHER
    /// path. Asserted as the EXACT key set rather than just
    /// `obj["pitchEdits"] == nil`, so any future field that forgets its
    /// omit-when-default rule reddens here too.
    @Test("the null era: an edit-free clip writes NO pitchEdits key, and no other new key")
    func nullEraOmitsTheKey() throws {
        for edits in [nil, PitchEditSet.empty,
                      PitchEditSet(analysisVersion: 7, segments: [], retuneMs: 250)] {
            let clip = audioClip(pitchEdits: edits)
            // An EMPTY set normalises to nil at construction — "no notes" and
            // "never detected" are one state, not two that round-trip apart.
            #expect(clip.pitchEdits == nil)

            let model = try #require(try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(clip)) as? [String: Any])
            #expect(model["pitchEdits"] == nil)
            #expect(model.keys.sorted() == ["audioFileURL", "fadeInBeats", "fadeOutBeats",
                                            "gainDb", "id", "isAIGenerated", "lengthBeats",
                                            "name", "startBeat"].sorted()
                    || model.keys.sorted() == ["audioFileURL", "id", "isAIGenerated",
                                               "lengthBeats", "name", "startBeat"].sorted())

            let dto = try #require(try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(ClipDocument(from: clip, media: nil)))
                as? [String: Any])
            #expect(dto["pitchEdits"] == nil)
            #expect(dto.keys.sorted() == ["id", "isAIGenerated", "lengthBeats",
                                          "media", "name", "startBeat"])
        }

        // POSITIVE CONTROL — the same two probes DO see the key when there are
        // edits, and the difference is EXACTLY one key on each path. An absence
        // check whose probe never fires is worth nothing.
        let edited = audioClip(pitchEdits: editedSet())
        let editedModel = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(edited)) as? [String: Any])
        #expect(editedModel["pitchEdits"] != nil)
        let editedDTO = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ClipDocument(from: edited, media: nil)))
            as? [String: Any])
        #expect(editedDTO["pitchEdits"] != nil)
        #expect(editedDTO.keys.count
                == (try #require(try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(ClipDocument(from: audioClip(), media: nil)))
                    as? [String: Any])).keys.count + 1)

        // A pre-m23-ap payload (no key at all) decodes to nil on both paths.
        let legacy = Data(#"{"id":"\#(UUID().uuidString)","name":"x","startBeat":0,"lengthBeats":4,"isAIGenerated":false}"#.utf8)
        #expect(try JSONDecoder().decode(Clip.self, from: legacy).pitchEdits == nil)
        #expect(try JSONDecoder().decode(ClipDocument.self, from: legacy).pitchEdits == nil)
    }

    /// An edit-free clip's BYTES are unchanged by the existence of the field —
    /// the strongest form available without the pre-field build: encode the
    /// same clip through both paths and assert the payload does not contain the
    /// key's name at all, with a positive control that the matcher can see it.
    @Test("the byte gate: 'pitchEdits' does not appear in an edit-free payload, either path")
    func byteGate() throws {
        let plain = audioClip()
        let modelBytes = try JSONEncoder().encode(plain)
        let dtoBytes = try JSONEncoder().encode(ClipDocument(from: plain, media: "media/vox.wav"))
        #expect(!String(decoding: modelBytes, as: UTF8.self).contains("pitchEdits"))
        #expect(!String(decoding: dtoBytes, as: UTF8.self).contains("pitchEdits"))
        // POSITIVE CONTROL for the matcher itself — it CAN find the string.
        let edited = audioClip(pitchEdits: editedSet())
        #expect(String(decoding: try JSONEncoder().encode(edited), as: UTF8.self)
            .contains("pitchEdits"))
        #expect(String(decoding: try JSONEncoder().encode(
            ClipDocument(from: edited, media: "media/vox.wav")), as: UTF8.self)
            .contains("pitchEdits"))

        // Omit-when-default INSIDE the set too: an unedited segment writes its
        // five detection keys and none of the seven edit keys.
        let detectedOnly = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 440,
                        detectedConfidence: 0.9)])
        let segmentJSON = String(decoding: try JSONEncoder().encode(detectedOnly),
                                 as: UTF8.self)
        for key in ["pitchOffsetCents", "driftScale", "vibratoScale",
                    "formantOffsetSemitones", "timeStartDeltaSeconds",
                    "timeEndDeltaSeconds", "amplitudeDb", "retuneMs"] {
            #expect(!segmentJSON.contains(key))
        }
        // POSITIVE CONTROL: the detection keys ARE there, so the absence above
        // is not a failure to encode anything at all.
        #expect(segmentJSON.contains("detectedHz") && segmentJSON.contains("startSeconds"))
    }

    /// TOUCH POINTS 2–4 — the DISK path: `ClipDocument`'s property, its
    /// `init(from clip:)`, its Codable, and `ProjectDocument.runtimeState`'s
    /// reconstruction. This is the trap design §7.3 names: `Clip`'s Codable is
    /// NOT the project file format.
    @Test("touch points 2–4 — the disk path: save → bytes → reopen is deep-equal")
    func diskRoundTrip() throws {
        let clip = audioClip(pitchEdits: editedSet())
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let document = ProjectDocument(name: "P", transport: TransportState(),
                                       tracks: [track], masterVolume: 1,
                                       mediaRefs: [clip.id: "media/vox.wav"])
        // Through real bytes, not just the in-memory DTO.
        let reopened = try JSONDecoder().decode(
            ProjectDocument.self, from: JSONEncoder().encode(document))
        #expect(try #require(reopened.tracks.first?.clips.first).pitchEdits == clip.pitchEdits)

        let runtime = reopened.runtimeState(
            bundleURL: URL(fileURLWithPath: "/tmp/does-not-exist-bundle"))
        let restored = try #require(runtime.tracks.first?.clips.first)
        #expect(restored.pitchEdits == clip.pitchEdits)
        #expect(restored.pitchEdits?.segments.count == 2)
        #expect(restored.pitchEdits?.retuneMs == 80)

        // NEGATIVE CONTROL: the same round trip on a clip WITHOUT edits comes
        // back nil, so "deep-equal" above is not two nils matching.
        let plainClip = audioClip()
        let plainDoc = ProjectDocument(name: "P", transport: TransportState(),
                                       tracks: [Track(name: "V", clips: [plainClip])],
                                       masterVolume: 1,
                                       mediaRefs: [plainClip.id: nil])
        let plainBack = try JSONDecoder().decode(
            ProjectDocument.self, from: JSONEncoder().encode(plainDoc))
            .runtimeState(bundleURL: URL(fileURLWithPath: "/tmp/nope"))
        #expect(try #require(plainBack.tracks.first?.clips.first).pitchEdits == nil)
        #expect(clip.pitchEdits != nil)
    }

    /// TOUCH POINT 5 — TAKE LANES, WHICH DESIGN §7.5 CALLS "FREE" AND WHICH
    /// ARE NOT.
    ///
    /// `TakeLaneDocument.clip` IS a `ClipDocument`, so the DTO half genuinely
    /// is free. The RECONSTRUCTION half is not: `TakeGroupDocument.takeGroup`
    /// is a SECOND hand-maintained field list, and that is exactly how
    /// `gainEnvelope` silently vanished from take lanes from m13-e until m16-b3
    /// found it. This test exists so that cannot happen a third time.
    @Test("touch point 5 — take lanes: the SECOND reconstruction threads the set too")
    func takeLaneRoundTrip() throws {
        let laneClip = audioClip(pitchEdits: editedSet())
        let group = TakeGroup(name: "Comp", lanes: [TakeLane(name: "Take 1", clip: laneClip)])
        let document = TakeGroupDocument(from: group,
                                         mediaRefs: [laneClip.id: "media/take1.wav"])
        let reopened = try JSONDecoder().decode(
            TakeGroupDocument.self, from: JSONEncoder().encode(document))
        #expect(try #require(reopened.lanes.first).clip.pitchEdits == laneClip.pitchEdits)

        let restored = reopened.takeGroup(bundleURL: URL(fileURLWithPath: "/tmp/nope")) { _ in }
        let restoredLane = try #require(restored.lanes.first)
        #expect(restoredLane.clip.pitchEdits == laneClip.pitchEdits)
        #expect(restoredLane.clip.pitchEdits?.segments.count == 2)
        // The gainEnvelope regression this site already suffered, pinned
        // alongside — the two share one field list and one failure mode.
        #expect(restoredLane.clip.gainEnvelope == laneClip.gainEnvelope)

        // NEGATIVE CONTROL: a lane WITHOUT edits comes back nil, so the
        // assertion above is not two nils agreeing.
        let plainLane = audioClip()
        let plainGroup = TakeGroupDocument(
            from: TakeGroup(name: "C", lanes: [TakeLane(name: "T", clip: plainLane)]),
            mediaRefs: [plainLane.id: nil])
        #expect(try #require(plainGroup
            .takeGroup(bundleURL: URL(fileURLWithPath: "/tmp/nope")) { _ in }
            .lanes.first).clip.pitchEdits == nil)
    }

    /// A decoded set is HEALED, not trusted — a hand-authored or damaged
    /// payload cannot smuggle a NaN, an out-of-range scale, or overlapping
    /// notes past the disk boundary.
    @Test("a damaged payload heals on decode rather than poisoning the curve")
    func decodeHeals() throws {
        let json = """
        {"analysisVersion":3,"retuneMs":1,"segments":[
          {"id":"\(UUID().uuidString)","startSeconds":2.0,"endSeconds":3.0,
           "detectedHz":440,"detectedConfidence":5.0,"driftScale":99,
           "pitchOffsetCents":99999},
          {"id":"\(UUID().uuidString)","startSeconds":0.0,"endSeconds":2.5,
           "detectedHz":-10,"detectedConfidence":0.5}
        ]}
        """
        let set = try JSONDecoder().decode(PitchEditSet.self, from: Data(json.utf8))
        #expect(set.analysisVersion == 3)
        #expect(set.retuneMs == PitchEditSet.engineMinimumRetuneMs)  // clamped up
        try #require(set.segments.count == 2)
        // Sorted, and the overlap healed first-wins.
        #expect(set.segments[0].startSeconds == 0.0)
        #expect(set.segments[0].endSeconds == 2.5)
        #expect(set.segments[1].startSeconds == 2.5)
        #expect(set.segments[0].detectedHz == 0)      // a negative Hz is not a pitch
        #expect(set.segments[1].detectedConfidence == 1)  // clamped from 5
        #expect(set.segments[1].driftScale == 4)      // clamped from 99
        #expect(set.segments[1].pitchOffsetCents == 2400)
        // …and the curve built from it is finite everywhere.
        let curve = PitchCorrectionCurve.make(editSet: set)
        for step in -20...60 {
            #expect(curve.semitones(atSourceSecond: Double(step) / 10).isFinite)
        }
    }
}
