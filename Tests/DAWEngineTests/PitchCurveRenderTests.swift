import AVFAudio
import CryptoKit
import CSignalsmithStretch
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// m23-q Phase 1 — THE CURVE PATH AS A SHIPPING PATH: latency compensation,
/// the output-frame ↔ source-second mapping, and the render-cache identity.
///
/// Phase 0 (`OfflineStretcherCurveTests`) measured the RAW path and compensated
/// for nothing; those legs still drive `compensation: .none` and their numbers
/// are unchanged by anything here. This suite asserts the PHYSICS of the
/// compensated path: not "the two renders differ" — distinct bytes prove
/// nothing — but WHERE IN TIME the pitch actually moves, measured with the
/// phase-difference tracker in `M23QCurveHarness`, which phase 0
/// positive-controlled against synthetic signals with known answers.
///
/// Every gate here has a control that CAN fail, and the controls are run and
/// asserted rather than described: the uncompensated render must MISS the
/// tolerance the compensated one passes, and the ratio-2 mapping must be as far
/// from the ratio-blind answer as it is close to the right one.
///
/// Deliberately NOT `@MainActor` (DSP has no business there, and Leg C of
/// `MainActorOccupancySiteTests` is at its cadence cap).
@Suite("m23-q Phase 1 — compensated pitch curve render")
struct PitchCurveRenderTests {
    static let baseHz = 220.0
    static let amplitude: Float = 0.8

    static func log(_ leg: String, _ message: String) {
        print("m23-q-P1|\(leg)| \(message)")
    }

    // MARK: - Instrument (parameterised twin of phase 0's fixed-rate reader)

    /// Where a 0 → +2 semitone transition actually lands in a rendered signal,
    /// in delivered output frames. Phase 0's `measuredStepProfile` is welded to
    /// its own 48 kHz / 3 s constants; this is the same reading, parameterised,
    /// because three of the legs below run at other rates and ratios. The
    /// TRACKER — the part that could be wrong — is the shared one.
    static func transitionFrame(_ signal: [Float], sampleRate: Double,
                                expectedNear: Double) throws -> (f50: Double,
                                                                 lowHz: Double,
                                                                 highHz: Double) {
        let estimates = M23QToneTracker.track(signal, sampleRate: sampleRate)
        let guardFrames = sampleRate * 0.15
        let lowWindow: Range<Double> = guardFrames..<(expectedNear - guardFrames)
        let highStart: Double = expectedNear + 3 * guardFrames
        let highWindow: Range<Double> = highStart..<(Double(signal.count) - guardFrames)
        let low = try #require(
            M23QToneTracker.medianHz(estimates, centreIn: lowWindow),
            "no low plateau before \(expectedNear)")
        let high = try #require(
            M23QToneTracker.medianHz(estimates, centreIn: highWindow),
            "no high plateau after \(expectedNear)")
        let f50 = try #require(
            M23QToneTracker.upwardCrossingFrame(
                estimates, threshold: low + (high - low) * 0.5),
            "no upward crossing (plateaus \(low) / \(high))")
        return (f50, low, high)
    }

    /// **THE LANDING BUDGET, AND WHERE EVERY TERM OF IT WAS MEASURED.**
    ///
    ///  * ±half a hop (720 frames / 15 ms at 48 k) — IRREDUCIBLE. The curve is
    ///    read once per hop, so the delivered value is a zero-order hold and
    ///    the request's position inside the hop is unrecoverable. This is the
    ///    same limit that puts the floor under `PitchEditSet.retuneMs`.
    ///  * +400 frames for a MEASURED, DISCRIMINATED mean bias. Sweeping the
    ///    request across one whole hop, driven by a real `PitchEditSet` (a
    ///    30 ms ramp — what ships), gave residuals −683 / −477 / −303 / −148
    ///    frames at ratio 1 and −711 / −629 / +123 / −655 at ratio 2: a mean
    ///    of −8 to −10 ms.
    ///
    ///    ⭐ **AND THE BIAS IS NOT THE COMPENSATION'S.** Two candidates fitted
    ///    that number — the latency constant being ~100 frames long, or the
    ///    ramp — so they were separated rather than argued about. The same
    ///    sweep driven by a HARD STEP (a closure, no ramp, everything else
    ///    identical) reads −500 / +581 / +221 / −139, **mean +41 frames
    ///    (+0.85 ms)**: unbiased, spread exactly the ±half hop predicted. So
    ///    the compensation is right and the negative mean belongs to a 30 ms
    ///    ramp meeting a 30 ms hop grid — at the `retuneMs` floor the curve is
    ///    sampled once or twice across the whole ramp, so it is delivered as a
    ///    staircase whose halfway crossing is not the ramp's midpoint.
    ///
    /// ±1120 frames / ±23 ms at 48 kHz. The uncompensated control lands at
    /// ≈+2855, 2.5× outside it, and that is ASSERTED below rather than
    /// described: a tolerance wide enough to pass the control proves nothing.
    static func landingTolerance(hop: Double) -> Double { hop / 2 + 400 }

    /// The edit set under test everywhere below: ONE note starting at
    /// `startSeconds` (source-file seconds) pulled +200 cents, with the ramp at
    /// its engine floor. `PitchCorrectionCurve` centres the boundary ramp, so
    /// the curve's 50 % point is EXACTLY `startSeconds` — which is what makes
    /// "where did the pitch move" a question with a right answer.
    static func stepEditSet(startSeconds: Double) -> PitchEditSet {
        PitchEditSet(
            segments: [
                NoteSegment(
                    startSeconds: startSeconds,
                    endSeconds: startSeconds + 1_000,  // runs past the file
                    detectedHz: baseHz,
                    detectedConfidence: 1,
                    pitchOffsetCents: 200)
            ],
            retuneMs: PitchEditSet.engineMinimumRetuneMs)
    }

    /// Render a sine through the edit set, via the SHIPPING plan.
    static func renderStep(sampleRate: Double, seconds: Double, ratio: Double,
                           stepSourceSecond: Double,
                           compensated: Bool) throws -> [Float] {
        let input = [M23QSignal.sine(
            hz: baseHz, frames: Int(sampleRate * seconds),
            sampleRate: sampleRate, amplitude: amplitude)]
        let plan = try #require(StretchCurvePlan.make(
            editSet: stepEditSet(startSeconds: stepSourceSecond),
            clipPitchShiftSemitones: 0,
            sampleRate: sampleRate,
            ratio: ratio))
        return try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: ratio,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: false,
            compensation: compensated
                ? OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate)
                : .none)[0]
    }

    // MARK: - (1) the constant and the code cannot drift apart

    /// ⭐ **THE SPY GATE.** `curveLookupFrame` is not a copy of what the render
    /// loop does — it IS what the render loop calls, once per hop. A magic
    /// number pre-shifting the curve inside the loop would be invisible to any
    /// test; this one reads the exact arithmetic that runs.
    @Test("(1) the compensated lookup is the measured constant plus half a hop")
    func lookupFrameIsTheMeasuredConstant() {
        let hop = 1440
        // The phase-0 path is untouched: no pre-shift at all.
        #expect(OfflineStretcher.curveLookupFrame(
            outputFrame: 0, compensation: .none, intervalSamples: hop) == 0)
        #expect(OfflineStretcher.curveLookupFrame(
            outputFrame: 72_000, compensation: .none, intervalSamples: hop) == 72_000)

        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: 48_000)
        #expect(compensation == .frames(OfflineStretcher.measuredCurveLatencyFrames),
                """
                the 48 kHz compensation must BE the measured constant \
                (\(OfflineStretcher.measuredCurveLatencyFrames)), not a number \
                beside it. Got \(compensation).
                """)
        let lookup = OfflineStretcher.curveLookupFrame(
            outputFrame: 72_000, compensation: compensation, intervalSamples: hop)
        #expect(lookup == 72_000 + OfflineStretcher.measuredCurveLatencyFrames + hop / 2,
                """
                the render loop reads the curve at output frame + \
                measuredCurveLatencyFrames + interval/2. Got \(lookup) for \
                72000; if the constant moved, this moves WITH it — a literal \
                here would be the drift this gate exists to catch.
                """)
        // Rate scaling is a division, not a table: 44.1 k must be smaller.
        let at44k = OfflineStretcher.curveLatencyCompensation(sampleRate: 44_100)
        #expect(at44k == .frames(2_186), "2379 × 44100/48000 = 2185.9 → 2186; got \(at44k)")
        Self.log("1", "48k \(compensation), 44.1k \(at44k)")
    }

    // MARK: - (2) THE PHYSICS, with the control that can fail

    @Test("(2) a correction asked for at source second 1.25 lands there")
    func compensatedStepLandsWhereItWasAsked() throws {
        let sr = 48_000.0
        let seconds = 2.5
        let stepSecond = 1.25
        let expected = stepSecond * sr
        let hop = 1440.0

        let compensated = try Self.renderStep(
            sampleRate: sr, seconds: seconds, ratio: 1,
            stepSourceSecond: stepSecond, compensated: true)
        let raw = try Self.renderStep(
            sampleRate: sr, seconds: seconds, ratio: 1,
            stepSourceSecond: stepSecond, compensated: false)

        let hit = try Self.transitionFrame(compensated, sampleRate: sr, expectedNear: expected)
        let miss = try Self.transitionFrame(raw, sampleRate: sr, expectedNear: expected)
        let hitOffset = hit.f50 - expected
        let missOffset = miss.f50 - expected
        Self.log("2", "compensated offset \(hitOffset) frames "
            + "(\(hitOffset / sr * 1000) ms), plateaus \(hit.lowHz)/\(hit.highHz)")
        Self.log("2", "UNCOMPENSATED control offset \(missOffset) frames "
            + "(\(missOffset / sr * 1000) ms) vs the measured "
            + "\(OfflineStretcher.measuredCurveLatencyFrames)")

        let tolerance = Self.landingTolerance(hop: hop)
        #expect(abs(hitOffset) < tolerance,
                """
                the compensated curve moved the pitch \(hitOffset) frames from \
                where it was asked for; the budget is ±\(tolerance) (half a hop \
                plus tracker width).
                """)
        // ⭐ THE CONTROL, ASSERTED: the same gate applied to the uncompensated
        // render must FAIL. A tolerance that swallowed 2379 frames would pass
        // both and prove nothing.
        #expect(abs(missOffset) > tolerance,
                """
                the uncompensated control passed the compensated tolerance — \
                the gate cannot fail and is worthless. offset \(missOffset), \
                tolerance \(tolerance).
                """)
        // The control is not merely "large" — it is PREDICTED. Uncompensated,
        // a request at R is first seen by the chunk at ceil(R/hop)·hop and
        // lands one latency later, so reading it back re-confirms the phase-0
        // constant on this build rather than just failing the tolerance.
        let boundary = (expected / hop).rounded(.up) * hop
        let modelled = boundary - expected
            + Double(OfflineStretcher.measuredCurveLatencyFrames)
        Self.log("2", "control modelled \(modelled) = hop ceiling "
            + "\(boundary - expected) + latency "
            + "\(OfflineStretcher.measuredCurveLatencyFrames); measured \(missOffset)")
        #expect(abs(missOffset - modelled) < 240,
                """
                the uncompensated path no longer behaves as phase 0 measured \
                it: modelled \(modelled), measured \(missOffset). Either the \
                constant is stale or the hop quantisation changed.
                """)
    }

    // MARK: - (3) THE MAPPING, at a ratio where getting it wrong is visible

    @Test("(3) source seconds map through the stretch ratio, not around it")
    func mappingHonoursTheStretchRatio() throws {
        let sr = 48_000.0
        let ratio = 2.0
        let stepSecond = 1.25
        let expected = stepSecond * sr * ratio          // 120_000
        let ratioBlind = stepSecond * sr                //  60_000
        let hop = 1440.0

        let rendered = try Self.renderStep(
            sampleRate: sr, seconds: 2.5, ratio: ratio,
            stepSourceSecond: stepSecond, compensated: true)
        #expect(rendered.count == Int(2.5 * sr * ratio))
        let hit = try Self.transitionFrame(rendered, sampleRate: sr, expectedNear: expected)
        let offset = hit.f50 - expected
        Self.log("3", "ratio \(ratio): landing \(hit.f50), expected \(expected), "
            + "offset \(offset) frames (\(offset / sr * 1000) ms); "
            + "the ratio-blind answer would be \(ratioBlind)")

        let tolerance = Self.landingTolerance(hop: hop)
        #expect(abs(offset) < tolerance,
                "ratio-2 landing off by \(offset) frames, budget ±\(tolerance)")
        // The discriminator: the same reading must be nowhere near the answer
        // a ratio-blind mapping would give, or the test could pass on both.
        #expect(abs(hit.f50 - ratioBlind) > 10 * tolerance,
                "the gate does not discriminate the ratio-blind mapping")
    }

    // MARK: - (4) the rate extrapolation, MEASURED rather than assumed

    @Test("(4) the compensation holds at 44.1 kHz")
    func compensationHoldsAt44k() throws {
        let sr = 44_100.0
        let stepSecond = 1.25
        let expected = stepSecond * sr
        // ⚠️ READ FROM THE STRETCHER, NOT `Int(sr * 0.03)`. Phase 0's
        // `hopIsMeasuredNotDerived` is explicit that the preset formula and
        // the value the block loop actually compares against are two different
        // quantities that happen to agree at 48 kHz, and it pins 44.1 kHz only
        // as "different". A derived hop here would put a number nobody
        // measured inside this leg's tolerance.
        let handle = try #require(css_create(1, Float(sr), 1))
        defer { css_destroy(handle) }
        let hop = Double(css_interval_samples(handle))
        #expect(hop >= 1, "the stretcher reported a non-positive hop at 44.1 kHz")

        let rendered = try Self.renderStep(
            sampleRate: sr, seconds: 2.5, ratio: 1,
            stepSourceSecond: stepSecond, compensated: true)
        let hit = try Self.transitionFrame(rendered, sampleRate: sr, expectedNear: expected)
        let offset = hit.f50 - expected
        Self.log("4", "44.1k: hop \(hop), compensation "
            + "\(OfflineStretcher.curveLatencyCompensation(sampleRate: sr)), "
            + "offset \(offset) frames (\(offset / sr * 1000) ms)")
        let tolerance = Self.landingTolerance(hop: hop)
        #expect(abs(offset) < tolerance,
                """
                the 48 kHz constant does not scale to 44.1 kHz: offset \
                \(offset) frames, budget ±\(tolerance). The scaling in \
                `curveLatencyCompensation` is an extrapolation from ONE \
                measured rate — if this fails, measure 44.1 kHz and make the \
                compensation a function of the rate rather than a division.
                """)
    }

    // MARK: - (5) THE INVARIANCE CONTROL

    /// ⭐ The boring one that catches the bug. Compensation must be a
    /// TRANSLATION of the curve in time, so a curve that does not move in time
    /// must come out bit-identical to the constant call it is equivalent to —
    /// at BOTH a trivial multiplier (1.0 takes a different branch upstream) and
    /// a real one.
    @Test("(5) a constant curve is bit-identical to the constant call, compensated")
    func constantCurveIsBitIdenticalUnderCompensation() throws {
        let sr = 48_000.0
        let input = [M23QSignal.sine(hz: Self.baseHz, frames: Int(sr * 1.5),
                                     sampleRate: sr, amplitude: Self.amplitude)]
        for semitones in [0.0, 2.0] {
            let reference = try OfflineStretcher.stretch(
                input: input, sampleRate: sr, ratio: 1, semitones: semitones,
                formantPreserve: false)[0]
            let curved = try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: sr, ratio: 1,
                semitonesAtOutputFrame: { _ in semitones },
                formantPreserve: false,
                compensation: OfflineStretcher.curveLatencyCompensation(sampleRate: sr))[0]
            let differing = zip(reference, curved).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
            Self.log("5", "constant \(semitones) st: \(differing) differing samples "
                + "of \(reference.count)")
            #expect(curved.count == reference.count)
            #expect(differing == 0,
                    "compensation perturbed a render that does not move in time")
        }
    }

    // MARK: - (6) the 8–11 % amplitude shortfall — WHOSE?

    /// The user measured a ±35 cent, 0.25 Hz correction coming back at ±32
    /// cents through an AUTOCORRELATION f0 tracker, and asked whether the chain
    /// or the tracker is short. This is the second instrument: the same request
    /// through the same render, read by the harness's PHASE-DIFFERENCE tracker,
    /// which shares nothing with an autocorrelation peak-interpolator.
    ///
    /// Phase 0 §8 measured this chain returning vibrato DEEPER than asked
    /// (1.06× at 1 Hz, 1.20× at 8 Hz) — the opposite sign — so a 0.91× reading
    /// here would be a finding and a 1.0× reading points at the other tracker.
    @Test("(6) a ±35 cent 0.25 Hz correction comes back at full depth")
    func gentleCorrectionDepthIsNotShallow() throws {
        let sr = 48_000.0
        let seconds = 10.0
        let rateHz = 0.25
        let depthCents = 35.0
        let input = [M23QSignal.sine(hz: Self.baseHz, frames: Int(sr * seconds),
                                     sampleRate: sr, amplitude: Self.amplitude)]
        let rendered = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sr, ratio: 1,
            semitonesAtOutputFrame: { frame in
                depthCents / 100 * sin(2 * .pi * rateHz * Double(frame) / sr)
            },
            formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(sampleRate: sr))[0]

        // Fit over EXACTLY two modulation cycles, 1 s … 9 s, so the projection
        // is exact and the edges are outside the window.
        let series = M23QToneTracker.track(rendered, sampleRate: sr)
            .filter { $0.centreFrame >= sr && $0.centreFrame <= 9 * sr }
            .map { (frame: $0.centreFrame,
                    value: M23QToneTracker.cents($0.hz, above: Self.baseHz)) }
        let fit = try #require(
            M23QToneTracker.fitSinusoid(series, rateHz: rateHz, sampleRate: sr))
        let ratio = fit.amplitude / depthCents

        // ⭐ THE INSTRUMENT'S OWN POSITIVE CONTROL, and the reason this leg can
        // answer the question at all: the SAME tracker, fit and window, on a
        // signal modulated by exactly ±35 cents with no stretcher anywhere. A
        // chain reading of 0.97× means nothing until this reads 1.00×.
        let ideal = M23QSignal.frequencyModulated(
            frames: Int(sr * seconds), sampleRate: sr, amplitude: Self.amplitude
        ) { n in
            Self.baseHz * pow(2, depthCents * sin(2 * .pi * rateHz * Double(n) / sr) / 1200)
        }
        let controlSeries = M23QToneTracker.track(ideal, sampleRate: sr)
            .filter { $0.centreFrame >= sr && $0.centreFrame <= 9 * sr }
            .map { (frame: $0.centreFrame,
                    value: M23QToneTracker.cents($0.hz, above: Self.baseHz)) }
        let control = try #require(
            M23QToneTracker.fitSinusoid(controlSeries, rateHz: rateHz, sampleRate: sr))
        let controlRatio = control.amplitude / depthCents

        var lag = fit.lagFrames
        let period = sr / rateHz
        if lag > period / 2 { lag -= period }
        Self.log("6", "requested ±\(depthCents) cents at \(rateHz) Hz; CHAIN "
            + "±\(fit.amplitude) (\(ratio)× of asked), lag \(lag) frames "
            + "(\(lag / sr * 1000) ms), residual rms \(fit.residualRMS) cents over "
            + "\(series.count) estimates; INSTRUMENT CONTROL ±\(control.amplitude) "
            + "(\(controlRatio)×)")

        #expect(abs(controlRatio - 1) < 0.01,
                """
                the depth instrument is itself short by \(1 - controlRatio) on a \
                signal carrying exactly ±\(depthCents) cents — the chain reading \
                below cannot be interpreted until that is fixed.
                """)
        // MEASURED 0.966× here, 0.969× at 1 Hz, 1.043× at 5 Hz: the deficit
        // REVERSES SIGN with rate, which no first-order smoother can do. The
        // band pins the CLAIM — "a slow correction comes back within a few
        // percent of the depth asked" — not the digit, and still catches a
        // regression to 0.8×.
        #expect(ratio > 0.92 && ratio < 1.08,
                "a ±\(depthCents) cent correction came back at \(ratio)× of what was asked")
    }

    // MARK: - (7) the digest: every field, and the identity rule

    /// ⭐ REFLECTION, not a hand-listed census: a field added to `NoteSegment`
    /// and forgotten in the digest is stale audio nobody can explain, and it is
    /// exactly the kind of omission a hand-maintained list stops catching after
    /// the second person edits it.
    @Test("(7) the digest covers every stored field of a note segment")
    func digestCoversEveryStoredField() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        func base() -> NoteSegment {
            NoteSegment(id: id, startSeconds: 1, endSeconds: 2, detectedHz: 220,
                        detectedConfidence: 0.5, pitchOffsetCents: 10,
                        driftScale: 1, vibratoScale: 1,
                        formantOffsetSemitones: 0, timeStartDeltaSeconds: 0,
                        timeEndDeltaSeconds: 0, amplitudeDb: 0)
        }
        let fields = Mirror(reflecting: base()).children.compactMap(\.label)
        let covered = [
            "id", "startSeconds", "endSeconds", "detectedHz", "detectedConfidence",
            "pitchOffsetCents", "driftScale", "vibratoScale",
            // m23-ap C5a — the synthesised generator. Hashed in a SUFFIX
            // BLOCK, not inline, so a set without a generator keeps the bytes
            // it had before these existed. The exception that buys is pinned
            // by `generatorFieldsRekeyOnlyWhenTheyCanBeHeard` below.
            "vibratoRateHz", "vibratoDepthCents", "vibratoOnsetSeconds",
            // m23-ap C5a-1 — the phase anchor. Hashed in its OWN block
            // (slot 2), gated on a generated wobble carrying an anchor, so
            // like rate and onset it is inert, and deliberately NOT a
            // mutation row below: `base()` has no depth, the block is gated
            // off, and that row would fail on purpose. Both halves are
            // pinned by `digestSeesTheAnchor`.
            "vibratoPhaseAnchorSeconds",
            "formantOffsetSemitones", "timeStartDeltaSeconds",
            "timeEndDeltaSeconds", "amplitudeDb",
            // Natural tuning §4 (NT-C C0 named them, R28; NT-C C4 hashes them
            // in slot 9, gated on `usesSoftJoins`). A COVERAGE pin since C4:
            // the two mutation rows below must move the digest.
            "transitionOutMs", "glideFollow",
            // C5b-1: the drawn shape, hashed ONLY in its own block (slot 4),
            // gated on `hasShape`. A COVERAGE pin: the shaped-base rows after
            // the loop move each field on a note that CARRIES a shape, and
            // `NoteShapeRenderTests.digestCoversEveryShapeSample` moves every
            // sample position.
            "shapeStartIndex", "shapeTenthsOfCents",
            // I7a: hashed in the LEVEL block (slot 5), not inline, so a set
            // with no cleared note keeps the bytes it had before the flag
            // existed. The mutation row below proves the block carries it.
            "isCleared",
            // U-A: hashed in the ORIGIN block (slot 6), not inline, so a set
            // with no sound and no slide keeps the bytes it had before the
            // field existed. A `let`: the rebuild row below proves the block
            // carries it.
            "origin",
        ]
        #expect(Set(fields) == Set(covered),
                """
                NoteSegment's stored properties changed (\(fields)). Add the new \
                field to `PitchEditSetDigest.hex` AND to this list, or an edit \
                to it will serve the previous render's audio.
                """)

        let reference = PitchEditSetDigest.hex(PitchEditSet(segments: [base()]))
        #expect(!reference.isEmpty)
        var mutated: [NoteSegment] = []
        for change in [
            { (s: inout NoteSegment) in s.startSeconds = 1.5 },
            { s in s.endSeconds = 2.5 },
            { s in s.pitchOffsetCents = 11 },
            { s in s.driftScale = 0.5 },
            { s in s.vibratoScale = 0.5 },
            // Only DEPTH is listed here. Rate and onset with a zero depth are
            // audibly and arithmetically inert, so they deliberately do NOT
            // re-key — pinned as its own case rather than quietly omitted.
            { s in s.vibratoDepthCents = 45 },
            { s in s.formantOffsetSemitones = 1 },
            { s in s.timeStartDeltaSeconds = 0.01 },
            { s in s.timeEndDeltaSeconds = 0.01 },
            { s in s.amplitudeDb = -3 },
            // I7a: the base note carries a pitch edit, so it is not identity
            // either way, and ONLY the level block can make this re-key.
            { s in s.isCleared = true },
            // NT-C C4: the base set has slope 0, so ONLY the transition
            // block (slot 9, gated on `usesSoftJoins` — on a slope-0 set that
            // is "some note `hasTransitionEdits`") can re-key these.
            { s in s.transitionOutMs = 120 },
            { s in s.glideFollow = 1 },
        ] {
            var segment = base()
            change(&segment)
            mutated.append(segment)
        }
        // `id`, `detectedHz` and `detectedConfidence` are `let` — rebuild.
        mutated.append(NoteSegment(id: UUID(), startSeconds: 1, endSeconds: 2,
                                   detectedHz: 220, detectedConfidence: 0.5,
                                   pitchOffsetCents: 10))
        mutated.append(NoteSegment(id: id, startSeconds: 1, endSeconds: 2,
                                   detectedHz: 221, detectedConfidence: 0.5,
                                   pitchOffsetCents: 10))
        mutated.append(NoteSegment(id: id, startSeconds: 1, endSeconds: 2,
                                   detectedHz: 220, detectedConfidence: 0.6,
                                   pitchOffsetCents: 10))
        // U-A: `origin` is a `let` too. The base note is moved (+10 c), so it
        // is not identity as either origin, and ONLY the origin block can
        // make this re-key.
        mutated.append(NoteSegment(id: id, startSeconds: 1, endSeconds: 2,
                                   detectedHz: 220, detectedConfidence: 0.5,
                                   pitchOffsetCents: 10, origin: .unpitched))
        for segment in mutated {
            let digest = PitchEditSetDigest.hex(PitchEditSet(segments: [segment]))
            #expect(digest != reference,
                    "a field change left the digest unchanged: \(segment)")
        }
        // C5b-1: the two shape fields, each moved on a base that CARRIES a
        // shape (on a shape-free note the block is gated off, and a start
        // index there would re-key for the wrong reason, or not at all).
        var shaped = base()
        shaped.shapeStartIndex = 120
        shaped.shapeTenthsOfCents = [0, 50, 0]
        let shapedReference = PitchEditSetDigest.hex(PitchEditSet(segments: [shaped]))
        #expect(shapedReference != reference, "adding a drawn shape left the digest unchanged")
        var movedShape = shaped
        movedShape.shapeStartIndex = 121
        #expect(PitchEditSetDigest.hex(PitchEditSet(segments: [movedShape])) != shapedReference,
                "moving a drawn shape by one grid step left the digest unchanged")
        var redrawn = shaped
        redrawn.shapeTenthsOfCents = [0, 51, 0]
        #expect(PitchEditSetDigest.hex(PitchEditSet(segments: [redrawn])) != shapedReference,
                "redrawing one sample left the digest unchanged")
        // Set-level fields.
        #expect(PitchEditSetDigest.hex(
            PitchEditSet(segments: [base()], retuneMs: 80)) != reference)
        #expect(PitchEditSetDigest.hex(
            PitchEditSet(analysisVersion: 2, segments: [base()])) != reference)
        // Natural tuning §2 (NT-C C2): the consonant flag, hashed in slot 8.
        // The base note is moved (+10 c), so the set bends and ONLY the
        // consonant block can make this re-key.
        #expect(PitchEditSetDigest.hex(
            PitchEditSet(segments: [base()], keepsConsonantsUntuned: true)) != reference)
        // Determinism: the same set, built twice, and after a Codable round
        // trip (the shape a reopened project actually arrives in).
        #expect(PitchEditSetDigest.hex(PitchEditSet(segments: [base()])) == reference)
    }

    /// ⭐⭐ **THE ONE DOCUMENTED EXCEPTION TO "EVERY FIELD RE-KEYS", PINNED
    /// FROM BOTH SIDES.** `digestCoversEveryStoredField` above asserts that a
    /// change to a stored field moves the digest. The generator's RATE and
    /// ONSET break that rule on purpose: with `vibratoDepthCents == 0` they
    /// contribute exactly zero to the curve for every `t`, so re-keying on
    /// them would push a clip that renders identically through a fresh
    /// stretch render — and a ratio-1 stretch is not its own input.
    ///
    /// Both halves are asserted, because only asserting "they don't re-key"
    /// would be indistinguishable from the digest having forgotten them
    /// entirely — the exact silent omission the reflection census exists to
    /// catch.
    @Test("(7) generator rate/onset re-key only once a depth makes them audible")
    func generatorFieldsRekeyOnlyWhenTheyCanBeHeard() {
        let id = UUID(uuidString: "77777777-2222-3333-4444-555555555555")!
        func segment(rate: Double = 0, depth: Double = 0,
                     onset: Double = 0) -> NoteSegment {
            NoteSegment(id: id, startSeconds: 1, endSeconds: 2, detectedHz: 220,
                        detectedConfidence: 0.5, pitchOffsetCents: 10,
                        vibratoRateHz: rate, vibratoDepthCents: depth,
                        vibratoOnsetSeconds: onset)
        }
        func hex(_ s: NoteSegment) -> String {
            PitchEditSetDigest.hex(PitchEditSet(segments: [s]))
        }
        let plain = hex(segment())
        #expect(!plain.isEmpty)

        // INERT ⇒ same key. This is the cache-preserving half.
        #expect(hex(segment(rate: 5.5)) == plain)
        #expect(hex(segment(onset: 0.3)) == plain)
        #expect(hex(segment(rate: 5.5, onset: 0.3)) == plain)

        // AUDIBLE ⇒ new key, and the rate and onset are INSIDE it. This is the
        // half that proves they were not simply forgotten.
        let deep = hex(segment(depth: 40))
        #expect(deep != plain)
        #expect(hex(segment(rate: 5.5, depth: 40)) != deep,
                """
                a rate change alongside a real depth left the digest unchanged \
                — the suffix block is not covering `vibratoRateHz`, and the \
                render will serve the previous rate's audio.
                """)
        #expect(hex(segment(rate: 5.5, depth: 40, onset: 0.3))
            != hex(segment(rate: 5.5, depth: 40)),
                """
                an onset change alongside a real depth left the digest \
                unchanged — the suffix block is not covering \
                `vibratoOnsetSeconds`.
                """)
    }

    /// ⭐⭐ **THE PHASE ANCHOR (m23-ap C5a-1, vibrato-handle design §7.4/§7.5):
    /// it re-keys exactly the sets whose sound it changes, in its own block, in
    /// slot 2.** Five legs:
    ///  1. with a generated wobble, the anchor's VALUE re-keys (not merely its
    ///     presence);
    ///  2. on a note with no generator it is inert, and does NOT re-key;
    ///  3. the every-segment rule: once any wobble carries an anchor, an inert
    ///     NEIGHBOUR's anchor re-keys too (the one cost design §7.5 accepts);
    ///  4. the bytes are EXACTLY the pre-anchor material plus one block
    ///     (marker, count, every anchor), and on a retimed set the block sits
    ///     BEFORE the time-warp block (slot order), against the independent
    ///     restatement `c21PreC2Material`, itself proven on captured hexes;
    ///  5. an anchor of 0 or −0.0 emits nothing: the pre-anchor bytes.
    /// Planted, red: the block removed (leg 1); gated on the anchor alone
    /// (leg 2).
    @Test("(7) C5a-1: the phase anchor re-keys only a wobble it moves, in its own slot-2 block")
    func digestSeesTheAnchor() {
        let idA = UUID(uuidString: "A0000000-0000-4000-8000-00000000C5A1")!
        let idB = UUID(uuidString: "B0000000-0000-4000-8000-00000000C5A1")!
        func note(_ id: UUID, _ start: Double, depth: Double, anchor: Double,
                  endDelta: Double = 0) -> NoteSegment {
            NoteSegment(id: id, startSeconds: start, endSeconds: start + 1, detectedHz: 220,
                        detectedConfidence: 0.9, pitchOffsetCents: 10,
                        vibratoRateHz: 5.5, vibratoDepthCents: depth,
                        vibratoPhaseAnchorSeconds: anchor, timeEndDeltaSeconds: endDelta)
        }
        func hex(_ segments: [NoteSegment]) -> String {
            PitchEditSetDigest.hex(PitchEditSet(segments: segments, retuneMs: 30))
        }
        // (1) With a wobble: the value re-keys.
        let wobble0 = hex([note(idA, 1, depth: 40, anchor: 0)])
        let wobbleA = hex([note(idA, 1, depth: 40, anchor: 1.5)])
        #expect(!wobble0.isEmpty)
        #expect(wobbleA != wobble0,
                "an anchor on a wobbling note left the key unchanged: stale audio at the old phase")
        #expect(hex([note(idA, 1, depth: 40, anchor: 1.51)]) != wobbleA,
                "a second anchor value hashed like the first: the block carries presence, not value")
        // (2) No wobble: inert, same key.
        #expect(hex([note(idA, 1, depth: 0, anchor: 1.5)]) == hex([note(idA, 1, depth: 0, anchor: 0)]),
                "an anchor on a note with no wobble re-keyed a render it cannot change")
        // (3) The every-segment rule.
        let withNeighbour = hex([note(idA, 1, depth: 40, anchor: 1.5), note(idB, 3, depth: 0, anchor: 0)])
        #expect(hex([note(idA, 1, depth: 40, anchor: 1.5), note(idB, 3, depth: 0, anchor: 3.2)])
                != withNeighbour,
                "the anchor block covers only the wobbling notes, not EVERY segment (design §7.5)")
        // (4) Exactly one block, in slot 2, before the time-warp block.
        #expect(PitchEditSetDigest.anchorSuffixMarker == 0x4131_4E43_484F_5201)
        func anchorBlock(_ set: PitchEditSet) -> [UInt8] {
            var bytes: [UInt8] = []
            func put(_ value: UInt64) {
                withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
            }
            put(0x4131_4E43_484F_5201)
            put(UInt64(bitPattern: Int64(set.segments.count)))
            for s in set.segments { put(s.vibratoPhaseAnchorSeconds.bitPattern) }
            return bytes
        }
        let anchored = PitchEditSet(segments: [note(idA, 1, depth: 40, anchor: 1.5),
                                               note(idB, 3, depth: 0, anchor: 3.2)], retuneMs: 30)
        #expect(PitchEditSetDigest.hex(anchored)
                == Self.c21SHA(Self.c21PreC2Material(anchored) + anchorBlock(anchored)))
        let retimed = PitchEditSet(segments: [note(idA, 1, depth: 40, anchor: 1.5, endDelta: 0.1),
                                              note(idB, 3, depth: 0, anchor: 0)], retuneMs: 30)
        #expect(retimed.hasTimeEdits)
        #expect(PitchEditSetDigest.hex(retimed)
                == Self.c21SHA(Self.c21PreC2Material(retimed) + anchorBlock(retimed)
                               + Self.c21WarpBlock()),
                "the anchor block is not in slot 2 (after the generator block, before the time warp)")
        // (5) 0 and −0.0 emit nothing.
        for zero in [0.0, -0.0] {
            let set = PitchEditSet(segments: [note(idA, 1, depth: 40, anchor: zero)], retuneMs: 30)
            #expect(PitchEditSetDigest.hex(set) == Self.c21SHA(Self.c21PreC2Material(set)),
                    "anchor \(zero) emitted an anchor block")
        }
    }

    @Test("(7) determinism survives a save/reopen round trip")
    func digestSurvivesCodableRoundTrip() throws {
        let set = PitchEditSet(
            segments: [
                NoteSegment(startSeconds: 0.5, endSeconds: 1.25, detectedHz: 196.4,
                            detectedConfidence: 0.87, pitchOffsetCents: -13.75,
                            driftScale: 0.5, vibratoScale: 1.25),
                NoteSegment(startSeconds: 1.5, endSeconds: 2, detectedHz: 233.1,
                            detectedConfidence: 0.91, pitchOffsetCents: 8.5),
            ],
            retuneMs: 120)
        let decoded = try JSONDecoder().decode(
            PitchEditSet.self, from: JSONEncoder().encode(set))
        #expect(PitchEditSetDigest.hex(decoded) == PitchEditSetDigest.hex(set))
        #expect(!PitchEditSetDigest.hex(set).isEmpty)
    }

    /// The §6.4 rule as a key: nothing that renders as nothing may change it.
    @Test("(7) a set that bends nothing digests to nothing — and agrees with the model")
    func identitySetsDigestEmpty() {
        #expect(PitchEditSetDigest.hex(nil).isEmpty)
        #expect(PitchEditSetDigest.hex(.empty).isEmpty)
        let detectedOnly = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 220,
                        detectedConfidence: 0.9)
        ])
        #expect(!detectedOnly.isEmpty)
        #expect(detectedOnly.isIdentity)
        #expect(PitchEditSetDigest.hex(detectedOnly).isEmpty,
                "a detected-but-unedited note table must not re-key the cache")

        // The two identity rules — the model's and the engine's — must agree
        // on every one of these, or a clip renders under one rule and schedules
        // under the other.
        let edited = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 220,
                        detectedConfidence: 0.9, pitchOffsetCents: 25)
        ])
        // I7a/U-C: a clear alone, or a level alone, is a real edit. It renders
        // (the mask), so it digests, and the model agrees.
        var clearedOnly = detectedOnly
        clearedOnly.segments[0].isCleared = true
        var levelledOnly = detectedOnly
        levelledOnly.segments[0].amplitudeDb = -72
        #expect(!clearedOnly.isIdentity && !levelledOnly.isIdentity)
        #expect(!PitchEditSetDigest.hex(clearedOnly).isEmpty,
                "a cleared note digests to nothing: the cache would play the uncleared source")
        #expect(!PitchEditSetDigest.hex(levelledOnly).isEmpty)
        for set in [nil, PitchEditSet.empty, detectedOnly, edited, clearedOnly, levelledOnly]
            as [PitchEditSet?] {
            let clip = Clip(name: "c", audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"),
                            pitchEdits: set)
            #expect(clip.hasPitchEdits == !PitchEditSetDigest.hex(set).isEmpty,
                    "hasPitchEdits and the digest disagree for \(String(describing: set))")
        }
    }

    /// `Params.isIdentity` (what the CACHE bypasses on) and `needsRender` (what
    /// the ENGINE schedules on) are two expressions of one rule while
    /// `Clip.isStretchIdentity` cannot see pitch edits. Pin them together.
    @Test("(7) the cache's identity and the engine's needsRender agree")
    func paramsIdentityAgreesWithNeedsRender() {
        let edited = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 220,
                        detectedConfidence: 0.9, pitchOffsetCents: 25)
        ])
        let detectedOnly = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 220,
                        detectedConfidence: 0.9)
        ])
        // I7a/U-C: a table whose only edit is a cleared note.
        var clearedOnly = detectedOnly
        clearedOnly.segments[0].isCleared = true
        for ratio in [1.0, 1.5] {
            for semitones in [0.0, 3.0] {
                for set in [nil, detectedOnly, edited, clearedOnly] as [PitchEditSet?] {
                    let clip = Clip(name: "c",
                                    audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"),
                                    stretchRatio: ratio,
                                    pitchShiftSemitones: semitones,
                                    pitchEdits: set)
                    let params = StretchRenderCache.Params(clip: clip)
                    #expect(StretchRenderCache.needsRender(clip) == !params.isIdentity,
                            """
                            ratio \(ratio) semitones \(semitones) edits \
                            \(set == nil ? "nil" : (set!.isIdentity ? "detected-only" : "edited")): \
                            needsRender=\(StretchRenderCache.needsRender(clip)) \
                            params.isIdentity=\(params.isIdentity)
                            """)
                }
            }
        }
    }

    /// Main-actor cost, MEASURED: `Params(clip:)` and the `ClipKey` builder both
    /// digest the edit set on every reconcile pass, on the main actor. Design
    /// §7.3 sizes a corrected vocal at ~450 segments.
    @Test("(7) digesting a 450-segment vocal is not main-actor work worth noticing")
    func digestCostAtDesignSize() {
        var segments: [NoteSegment] = []
        for index in 0..<450 {
            let start: Double = Double(index) * 0.4
            let hz: Double = 180 + Double(index % 40)
            let cents: Double = Double(index % 17) - 8
            segments.append(NoteSegment(startSeconds: start,
                                        endSeconds: start + 0.3,
                                        detectedHz: hz,
                                        detectedConfidence: 0.8,
                                        pitchOffsetCents: cents))
        }
        let set = PitchEditSet(segments: segments)
        #expect(set.segments.count == 450)
        let start = Date()
        var last = ""
        for _ in 0..<100 { last = PitchEditSetDigest.hex(set) }
        let perCall = Date().timeIntervalSince(start) / 100 * 1_000
        Self.log("7", "450-segment digest: \(perCall) ms per call")
        #expect(!last.isEmpty)
        #expect(perCall < 2.0, "digesting one vocal clip costs \(perCall) ms on the main actor")
    }

    // MARK: - (8) m23-ap C2-1: the time-warp block, and timing invisible until used

    // ⭐ HOW EVERY LITERAL BELOW WAS CAPTURED (the task's own rule: capture on
    // today's tree BEFORE changing anything). At 2026-09-24 05:58 the tree's
    // `Package.swift`, `Package.resolved`, `Sources/` and `Tests/` were
    // rsync'd into an isolated scratch copy. The SHA-256 of the five files
    // this item touches (`PitchCorrection.swift`, `StretchCurvePlan.swift`,
    // `StretchRenderCache.swift`, this file, `NoteVibratoGeneratorTests.swift`)
    // was compared between the copy and the live tree: identical. A
    // capture-only test in the COPY printed each digest, and was run twice
    // with identical output. The copy reproduced the four goldens already
    // committed in `NoteVibratoGeneratorTests` §A (two digests, two renders),
    // which is the positive control that the capture harness measures what
    // the suites measure. Nothing here was captured after the change.

    /// The three legacy sets C2-1 must not re-key: plain offsets, a flattened
    /// set, a generator set. `offset` and `shaping` ARE
    /// `NoteVibratoGeneratorTests`' `legacyOffsetSet` / `legacyShapingSet`.
    static let c21LegacyDigestGoldens: [(set: String, hex: String)] = [
        ("offset", "ec8e1bd8e04e4d8a6861e27ed620ff5772422fee40b8c6fd886e9e712ca77f6a"),
        ("shaping", "1102f9a9e5bc74e92a449ed9a4a9ee28fe93915fd7e43922ce38bc2318c84a8a"),
        ("generator", "1931c6528936e6b607f282d24c1a30dcabefc0f1add0d106bf84e4086d279a7b"),
    ]

    /// Sets that ALREADY carried non-zero time deltas before C2 existed. Their
    /// pre-C2 renders ignored the deltas, under these keys.
    static let c21PreC2TimedHex: [(set: String, hex: String)] = [
        ("delta", "aec7143a81feaabd91aa732a5d50dfacb008418539f4a79a07b4092b0f151558"),
        ("timingOnly", "5f5a27300b3328ed71f1ba060316e41335e5d603c23c1728253a0cad14be3644"),
        ("startDelta", "ae03940717ec60ccf2905193efd412e639fad7d0b40db3508f925a1f6da04cef"),
    ]

    static let c21IdA = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    static let c21IdB = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!

    /// Value for value the sets the pre-change capture hashed.
    static func c21Set(_ name: String) -> PitchEditSet {
        let idA = c21IdA
        let idB = c21IdB
        switch name {
        case "offset": return NoteVibratoGeneratorTests.legacyOffsetSet()
        case "shaping": return NoteVibratoGeneratorTests.legacyShapingSet()
        case "generator":
            return PitchEditSet(analysisVersion: 1, segments: [
                NoteSegment(id: idA, startSeconds: 0.25, endSeconds: 1.25,
                            detectedHz: 220, detectedConfidence: 0.9,
                            pitchOffsetCents: -37.5,
                            vibratoRateHz: 5.5, vibratoDepthCents: 40,
                            vibratoOnsetSeconds: 0.2),
                NoteSegment(id: idB, startSeconds: 1.25, endSeconds: 1.9,
                            detectedHz: 233.08, detectedConfidence: 0.81,
                            pitchOffsetCents: 22.0),
            ], retuneMs: 45)
        case "delta":
            return PitchEditSet(analysisVersion: 1, segments: [
                NoteSegment(id: idA, startSeconds: 0.5, endSeconds: 1.0,
                            detectedHz: 220, detectedConfidence: 0.9,
                            pitchOffsetCents: 25, timeEndDeltaSeconds: 0.1),
                NoteSegment(id: idB, startSeconds: 1.4, endSeconds: 1.9,
                            detectedHz: 233.08, detectedConfidence: 0.81,
                            pitchOffsetCents: -12),
            ], retuneMs: 30)
        case "timingOnly":
            return PitchEditSet(analysisVersion: 1, segments: [
                NoteSegment(id: idA, startSeconds: 0.5, endSeconds: 1.0,
                            detectedHz: 220, detectedConfidence: 0.9,
                            timeEndDeltaSeconds: 0.1),
                NoteSegment(id: idB, startSeconds: 1.4, endSeconds: 1.9,
                            detectedHz: 233.08, detectedConfidence: 0.81),
            ], retuneMs: 30)
        case "startDelta":
            return PitchEditSet(analysisVersion: 1, segments: [
                NoteSegment(id: idA, startSeconds: 0.5, endSeconds: 1.0,
                            detectedHz: 220, detectedConfidence: 0.9,
                            pitchOffsetCents: 25, timeStartDeltaSeconds: -0.05),
            ], retuneMs: 30)
        default:
            Issue.record("no C2-1 fixture set named \(name)")
            return .empty
        }
    }

    static func c21SHA(_ bytes: [UInt8]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(bytes))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// An INDEPENDENT restatement of the digest's pre-C2 byte layout: the
    /// inline section and the generator block, written out here rather than
    /// read from `PitchEditSetDigest`. It is validated against the CAPTURED
    /// pre-C2 goldens before anything is derived from it, so it cannot just
    /// agree with a production change.
    static func c21PreC2Material(_ set: PitchEditSet) -> [UInt8] {
        var bytes: [UInt8] = []
        func putBits(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        func putDouble(_ value: Double) { putBits(value.bitPattern) }
        func putInt(_ value: Int) { putBits(UInt64(bitPattern: Int64(value))) }
        putBits(1)  // layoutVersion
        putInt(set.analysisVersion)
        putDouble(set.retuneMs)
        putInt(set.segments.count)
        for s in set.segments {
            withUnsafeBytes(of: s.id.uuid) { bytes.append(contentsOf: $0) }
            for value in [s.startSeconds, s.endSeconds, s.detectedHz, s.detectedConfidence,
                          s.pitchOffsetCents, s.driftScale, s.vibratoScale,
                          s.formantOffsetSemitones, s.timeStartDeltaSeconds,
                          s.timeEndDeltaSeconds, s.amplitudeDb] {
                putDouble(value)
            }
        }
        if set.segments.contains(where: { $0.vibratoDepthCents != 0 }) {
            putBits(0x5631_4252_4154_4F01)  // the generator block's marker
            putInt(set.segments.count)
            for s in set.segments {
                putDouble(s.vibratoRateHz)
                putDouble(s.vibratoDepthCents)
                putDouble(s.vibratoOnsetSeconds)
            }
        }
        return bytes
    }

    /// The block C2-1 appends, restated: the marker, pinned as a literal here
    /// because changing it would silently re-key every retimed render, then
    /// the schedule version.
    static func c21WarpBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: UInt64(0x5431_4D45_5752_5001).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        withUnsafeBytes(of: UInt64(bitPattern: Int64(PitchTimeWarp.scheduleVersion)).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        return bytes
    }

    /// The design's C2-1 gate (§3.5): the three legacy digests are UNCHANGED.
    /// Planted in isolation: inverting `hasTimeEdits` turns this red.
    @Test("(8) C2-1: the three legacy digests are unchanged, and hash no time-warp block")
    func c21LegacyDigestsUnchanged() {
        for golden in Self.c21LegacyDigestGoldens {
            let set = Self.c21Set(golden.set)
            #expect(!set.hasTimeEdits)
            #expect(PitchEditSetDigest.hex(set) == golden.hex,
                    """
                    the digest of the legacy '\(golden.set)' set MOVED \
                    (\(PitchEditSetDigest.hex(set))). Every cache entry for it on every \
                    disk is now orphaned. The time-warp block must be emitted only \
                    when `PitchEditSet.hasTimeEdits` is true.
                    """)
        }
        // These are the same captures as `NoteVibratoGeneratorTests` §A, taken
        // on a different day. They must agree, or one of the two is not what it says.
        #expect(Self.c21LegacyDigestGoldens[0].hex == NoteVibratoGeneratorTests.goldenDigestOffset)
        #expect(Self.c21LegacyDigestGoldens[1].hex == NoteVibratoGeneratorTests.goldenDigestShaping)
    }

    /// The stale-key hazard (design F7, §3.5), closed: a set that carried
    /// deltas BEFORE C2 must NOT keep the key under which its deltas were
    /// ignored. The re-key must also be EXACTLY the appended block. That is
    /// proven against an independent restatement of the layout, which is
    /// itself proven against the captured hexes first. Planted in isolation:
    /// removing the block turns this red.
    @Test("(8) C2-1: a set carrying time deltas re-keys against its pre-C2 hex, by exactly the block")
    func c21TimedSetsRekeyByExactlyTheBlock() {
        // The restatement reproduces every captured pre-C2 hex: all three
        // legacy sets and all three timed sets.
        for golden in Self.c21LegacyDigestGoldens + Self.c21PreC2TimedHex {
            #expect(Self.c21SHA(Self.c21PreC2Material(Self.c21Set(golden.set))) == golden.hex,
                    "the test's own layout restatement does not reproduce '\(golden.set)'")
        }
        #expect(PitchEditSetDigest.timeWarpSuffixMarker == 0x5431_4D45_5752_5001)
        for golden in Self.c21PreC2TimedHex {
            let set = Self.c21Set(golden.set)
            #expect(set.hasTimeEdits)
            let now = PitchEditSetDigest.hex(set)
            #expect(now != golden.hex,
                    """
                    '\(golden.set)' carries time deltas and still has its pre-C2 key \
                    \(golden.hex). That key holds audio rendered with the deltas \
                    IGNORED, and C2-3's render would serve it as the retimed audio.
                    """)
            #expect(now == Self.c21SHA(Self.c21PreC2Material(set) + Self.c21WarpBlock()),
                    "'\(golden.set)' re-keyed, but not by exactly the time-warp block")
        }
        // Block order: generator block, then the time-warp block. (The anchor
        // block's slot sits between them. It is gated, and absent here.)
        var both = Self.c21Set("generator")
        both.segments[1].timeStartDeltaSeconds = 0.02
        #expect(PitchEditSetDigest.hex(both)
                == Self.c21SHA(Self.c21PreC2Material(both) + Self.c21WarpBlock()))
        // A −0.0 delta is no time edit: no block, and the pre-C2 material.
        var negativeZero = Self.c21Set("offset")
        negativeZero.segments[0].timeEndDeltaSeconds = -0.0
        #expect(!negativeZero.hasTimeEdits)
        #expect(PitchEditSetDigest.hex(negativeZero)
                == Self.c21SHA(Self.c21PreC2Material(negativeZero)))
    }

    /// Render through the shipping plan exactly as the capture did: 2 s of a
    /// 220 Hz sine at 48 kHz, `StretchCurvePlan.make`, the shipping
    /// compensation. This is `NoteVibratoGeneratorTests.renderThroughShippingPath`
    /// with a ratio.
    static func c21Render(_ set: PitchEditSet, ratio: Double) throws -> [Float] {
        let sr = 48_000.0
        let input = [M23QSignal.sine(hz: 220, frames: Int(sr * 2.0),
                                     sampleRate: sr, amplitude: 0.8)]
        let plan = try #require(StretchCurvePlan.make(
            editSet: set, clipPitchShiftSemitones: 0, sampleRate: sr, ratio: ratio))
        #expect(plan.curve.timeWarp == nil,
                "C2-1 builds no W for the render; C2-3 does, and must move the timed goldens")
        return try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sr, ratio: ratio,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(sampleRate: sr))[0]
    }

    /// The "generator" set's ratio-1 render, captured pre-C2. ONE home, because
    /// `NoteVibratoGeneratorTests.anchorZeroIsTodayBitForBit` (C5a-1's T12)
    /// pins the same bytes: a change that moves the audio (the transposer fix)
    /// re-pins it here once, and T12 then keeps testing the anchor alone.
    /// ⚠️ RE-PINNED TWICE on 2026-09-25, both times by the vendored
    /// transposer (see `c21UntimedRendersAreByteIdentical`), never by C2:
    /// pristine f6b1edfc… → p2-acc (patch 0001) c7eaddc1… → p2-acc-3
    /// (patches 0002+0003) 538abd33….
    static let c21GeneratorRenderGolden =
        "538abd3345aa7d45c335fc74baa7a99b1f92db473413ef6ad417aaee8485cca2"

    /// ⭐ TIMING IS INVISIBLE UNTIL IT IS USED. An untimed set renders the
    /// bytes it rendered before C2 existed, at two ratios, with a generator
    /// among them. That generator is what C2-1's edited-time branch sits on.
    @Test("(8) C2-1: untimed sets render byte-identically to pre-C2")
    func c21UntimedRendersAreByteIdentical() throws {
        // ⚠️ RE-PINNED TWICE on 2026-09-25, NOT by any C2 change: each time the
        // vendored transposer changed, which moves every transposed render.
        // Chain pristine → p2-acc (VENDORED.md patch 0001, the fractional-bin
        // phase read) → p2-acc-3 (patches 0002 peak position + flat lobe map,
        // 0003 exact previous hop):
        //   offset        7a2a181e… → afe83f96… → c193adae…
        //   shaping       3493573a… → 98636380… → da7078cf…
        //   generator@1   f6b1edfc… → c7eaddc1… → 538abd33…
        //   generator@1.5 a807f0c9… → 8910312f… → 8c118bc7…
        // Untimed sets still render exactly what they rendered before C2.
        let goldens: [(set: String, ratio: Double, frames: Int, hex: String)] = [
            ("offset", 1, 96_000, "c193adae511145da424f0a70032c7561e264494104a568ac88714348b68e4ae9"),
            ("shaping", 1, 96_000, "da7078cfcbebd589c7c27e87994bacebf5269565460e5c02e9b10dfe871b8bb7"),
            ("generator", 1, 96_000, Self.c21GeneratorRenderGolden),
            ("generator", 1.5, 144_000, "8c118bc7eefd65c348b9b204aad6ff1237cfead90d34d1aa3706b6ed4b626cd7"),
        ]
        for golden in goldens {
            let set = Self.c21Set(golden.set)
            #expect(!set.hasTimeEdits)
            let rendered = try Self.c21Render(set, ratio: golden.ratio)
            #expect(rendered.count == golden.frames)
            let hex = NoteVibratoGeneratorTests.renderDigest(rendered)
            #expect(hex == golden.hex,
                    "'\(golden.set)' at ratio \(golden.ratio) no longer renders its pre-C2 bytes (\(hex))")
        }
    }

    /// ⚠️ **C2-1 ONLY, AND OWED TO C2-3.** C2-1 does not wire W into the
    /// render, so even a set that CARRIES deltas still renders exactly its
    /// pre-C2 bytes (deltas ignored). This pins that C2-1 changed no render at
    /// all. **C2-3 must move these three literals.** That move is its evidence
    /// that the render reads timing, and a C2-3 that leaves them green has not
    /// wired anything. Its KEYS already moved (the test above). The audio
    /// catches up in C2-3.
    @Test("(8) C2-1 only: sets carrying deltas still render their pre-C2 bytes (C2-3 must move these)")
    func c21TimedRendersUnchangedUntilC23() throws {
        // ⚠️ The two `delta` literals were RE-PINNED TWICE on 2026-09-25, both
        // times by the vendored transposer — NOT by C2-3. Chain pristine →
        // p2-acc (VENDORED.md patch 0001) → p2-acc-3 (patches 0002+0003):
        //   delta@1   aa608771… → 7bfa528e… → 3e66c227…
        //   delta@1.5 895d2ca7… → 4c7fca4a… → f914ff4a…
        // C2-1 still renders these sets with their deltas IGNORED, so **C2-3
        // must STILL move both again**; that move remains its evidence.
        // `timingOnly` (0 st at every hop, ratio exactly 1) moved for neither:
        // 0001 cannot reach an integer-bin read, 0002 runs only on mapped
        // frequencies, and ratio 1 is outside 0003's near-unity window.
        let goldens: [(set: String, ratio: Double, frames: Int, hex: String)] = [
            ("delta", 1, 96_000, "3e66c227438395a935b0e98458c0f09fe8268cc19451434d37bf4acbaa7c9e01"),
            ("timingOnly", 1, 96_000, "80be09798fdff09b9156e8bb2de7820205c8b61b6f9d350b37f53c8d341f43d5"),
            ("delta", 1.5, 144_000, "f914ff4aa39ea46aedeb333d82c0285f03ed12c03376ed5d1691bcfe1e4709d3"),
        ]
        for golden in goldens {
            let set = Self.c21Set(golden.set)
            #expect(set.hasTimeEdits)
            let rendered = try Self.c21Render(set, ratio: golden.ratio)
            #expect(rendered.count == golden.frames)
            #expect(NoteVibratoGeneratorTests.renderDigest(rendered) == golden.hex,
                    "'\(golden.set)' at ratio \(golden.ratio): the render changed in C2-1")
        }
    }

    /// Writes a quiet sine to `url` in the given file format and closes it.
    static func c21WriteFixture(to url: URL, frames: Int, sampleRate: Double,
                                channels: Int, int16: Bool) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: int16 ? 16 : 32,
            AVLinearPCMIsFloatKey: !int16,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: sampleRate,
                                                channels: AVAudioChannelCount(channels),
                                                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(frames)))
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            let value = Float(0.25 * sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            for channel in 0..<channels { data[channel][frame] = value }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        // Scoped: the writer deallocates, flushing and closing, on return.
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// ⭐ **D HAS ONE EXPRESSION, AND ITS TWO SITES AGREE BIT FOR BIT** (design
    /// §3.2, "Why D is a parameter"). The store and the editor read
    /// `media.audioFileInfo(at:).durationSeconds` (`AudioFileImporter`). The
    /// render (C2-3) must compute D with `StretchCurvePlan.sourceDurationSeconds(of:)`
    /// on the reader `performRender` already opened. If the two ever differ,
    /// the display's W and the render's W differ in their last piece.
    ///
    /// The fixtures are chosen so "bit-identical" DISCRIMINATES: their lengths
    /// make `Double(n) / sr` and `Double(n) * (1 / sr)` round differently
    /// (checked in the positive control below). A pin that two expressions
    /// agree is worthless on lengths where every plausible expression agrees.
    @Test("(8) C2-1: the importer's D is bit-identical to the render's D on fixture files")
    func c21ImporterAndRenderAgreeOnD() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-c21-d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let generated: [(name: String, sr: Double, frames: Int, channels: Int, int16: Bool)] = [
            ("mono-44k1-f32.wav", 44_100, 100_019, 1, false),
            ("stereo-48k-i16.wav", 48_000, 81_613, 2, true),
            ("mono-96k-f32.wav", 96_000, 100_009, 1, false),
        ]
        var urls: [URL] = []
        for fixture in generated {
            let url = dir.appendingPathComponent(fixture.name)
            try Self.c21WriteFixture(to: url, frames: fixture.frames, sampleRate: fixture.sr,
                                     channels: fixture.channels, int16: fixture.int16)
            let reader = try AVAudioFile(forReading: url)
            #expect(reader.length == AVAudioFramePosition(fixture.frames),
                    "\(fixture.name): wrote \(fixture.frames) frames, the file holds \(reader.length)")
            urls.append(url)
        }
        // The committed fixtures: every bundled sample, and a system sound
        // every macOS install ships (`AudioFileImporterTests` relies on it too).
        for entry in BundledSamples.catalog {
            urls.append(try BundledSamples.resolve(entry.wireName))
        }
        urls.append(URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff"))

        // A retimed set whose knots sit inside the shortest fixture, so each
        // file's W is a real, non-trivial map.
        let timed = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.05, endSeconds: 0.1, detectedHz: 220,
                        detectedConfidence: 0.9, timeEndDeltaSeconds: 0.01)
        ])
        var discriminating = 0
        for url in urls {
            let reader = try AVAudioFile(forReading: url)
            let renderD = StretchCurvePlan.sourceDurationSeconds(of: reader)
            let importerD = try AudioFileImporter().audioFileInfo(at: url).durationSeconds
            Self.log("8", "\(url.lastPathComponent): length \(reader.length) @ "
                + "\(reader.processingFormat.sampleRate) Hz — importer \(importerD), render \(renderD)")
            #expect(renderD > 0.15, "\(url.lastPathComponent): D = \(renderD)")
            #expect(renderD.bitPattern == importerD.bitPattern,
                    """
                    \(url.lastPathComponent): the render's D (\(renderD)) and the importer's \
                    D (\(importerD)) differ in bits. The display's W and the render's W \
                    would then differ in their last piece.
                    """)
            #expect(PitchTimeWarp.make(editSet: timed, sourceDurationSeconds: renderD)
                    == PitchTimeWarp.make(editSet: timed, sourceDurationSeconds: importerD))
            let sr = reader.processingFormat.sampleRate
            if (Double(reader.length) / sr).bitPattern != (Double(reader.length) * (1 / sr)).bitPattern {
                discriminating += 1
            }
        }
        // ⭐ POSITIVE CONTROL: the bit comparison CAN fail on these fixtures,
        // because a plausible second spelling of D really does differ on them.
        #expect(discriminating >= 3,
                "only \(discriminating) fixture(s) distinguish n/sr from n·(1/sr); the pin would be vacuous")
    }

    // MARK: - (9) I7a/U-C: digest slot (5), THE LEVEL BLOCK

    /// The block I7a appends (interaction-batch design §17.6), restated
    /// independently: the marker (a literal here, because changing it would
    /// silently re-key every cleared or levelled render), the mask version,
    /// the note count, then ONE BYTE PER NOTE, its cleared flag. `amplitudeDb`
    /// is not in it: that value has been hashed inline since the field
    /// existed, and it stays there.
    static func i7aLevelBlock(_ set: PitchEditSet) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: UInt64(0x4C31_4556_454C_5301).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        withUnsafeBytes(of: UInt64(bitPattern: Int64(PitchEditSet.levelMaskVersion)).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        withUnsafeBytes(of: UInt64(bitPattern: Int64(set.segments.count)).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        for segment in set.segments { bytes.append(segment.isCleared ? 1 : 0) }
        return bytes
    }

    /// ⭐ THE STALE-KEY HAZARD, FOR LEVELS. A cleared note that kept its old
    /// key would be served the audio rendered before it was cleared: a clear
    /// that "does nothing" until some other edit happens to re-key the clip.
    /// The re-key must be EXACTLY the level block, in slot (5), after the
    /// time-warp block. That is proven against the independent restatement,
    /// which is itself proven against the captured pre-C2 goldens first. And
    /// every set with no level edit keeps its bytes (the legacy goldens).
    @Test("(9) I7a: a cleared or levelled set re-keys by exactly the level block, in slot 5, after the time-warp block")
    func i7aLevelBlockRekeysByExactlyTheBlock() {
        for golden in Self.c21LegacyDigestGoldens + Self.c21PreC2TimedHex {
            #expect(Self.c21SHA(Self.c21PreC2Material(Self.c21Set(golden.set))) == golden.hex,
                    "the test's own layout restatement does not reproduce '\(golden.set)'")
        }
        #expect(PitchEditSetDigest.levelSuffixMarker == 0x4C31_4556_454C_5301)
        #expect(PitchEditSet.levelMaskVersion == 1,
                "a mask version bump re-keys every level-edited render: make it on purpose, then move this pin")

        // No level edit: no block, the legacy bytes (the goldens above, unmoved).
        for golden in Self.c21LegacyDigestGoldens {
            let set = Self.c21Set(golden.set)
            #expect(!set.hasLevelEdits)
            #expect(PitchEditSetDigest.hex(set) == golden.hex)
        }

        // A clear alone, on a plain-offset set.
        var cleared = Self.c21Set("offset")
        cleared.segments[0].isCleared = true
        #expect(cleared.hasLevelEdits)
        let clearedHex = PitchEditSetDigest.hex(cleared)
        #expect(clearedHex != Self.c21LegacyDigestGoldens[0].hex,
                "a cleared note kept its pre-clear key: the old audio would be served as the clear")
        #expect(clearedHex == Self.c21SHA(Self.c21PreC2Material(cleared) + Self.i7aLevelBlock(cleared)),
                "a clear re-keyed, but not by exactly the level block")

        // A level alone: amplitudeDb is already hashed inline, and the block
        // (all flags 0) marks that the render now reads it.
        var levelled = Self.c21Set("offset")
        levelled.segments[0].amplitudeDb = -72
        #expect(levelled.hasLevelEdits)
        #expect(PitchEditSetDigest.hex(levelled)
                == Self.c21SHA(Self.c21PreC2Material(levelled) + Self.i7aLevelBlock(levelled)))
        #expect(PitchEditSetDigest.hex(levelled) != clearedHex)

        // A clear on a note whose level was also set: both, and distinct from each.
        var both = levelled
        both.segments[0].isCleared = true
        #expect(Set([PitchEditSetDigest.hex(both), clearedHex, PitchEditSetDigest.hex(levelled)]).count == 3)

        // ORDER: the generator block (inside the material), then the time-warp
        // block (slot 3), then the level block (slot 5).
        var everything = Self.c21Set("generator")
        everything.segments[1].timeStartDeltaSeconds = 0.02
        everything.segments[0].isCleared = true
        #expect(PitchEditSetDigest.hex(everything)
                == Self.c21SHA(Self.c21PreC2Material(everything) + Self.c21WarpBlock()
                               + Self.i7aLevelBlock(everything)),
                "the level block is not in slot 5, after the time-warp block")

        // A clear on a DETECTED-ONLY table is a real edit: it digests.
        let detectedOnly = PitchEditSet(segments: [
            NoteSegment(id: Self.c21IdA, startSeconds: 0, endSeconds: 1, detectedHz: 220,
                        detectedConfidence: 0.9)
        ])
        #expect(PitchEditSetDigest.hex(detectedOnly).isEmpty)
        var clearedDetectedOnly = detectedOnly
        clearedDetectedOnly.segments[0].isCleared = true
        #expect(PitchEditSetDigest.hex(clearedDetectedOnly)
                == Self.c21SHA(Self.c21PreC2Material(clearedDetectedOnly)
                               + Self.i7aLevelBlock(clearedDetectedOnly)))

        // Restore is exact: the flag back to false is the pre-clear key, bit for bit.
        var restored = cleared
        restored.segments[0].isCleared = false
        #expect(PitchEditSetDigest.hex(restored) == Self.c21LegacyDigestGoldens[0].hex)
    }

    // MARK: - (10) U-A: sounds with no detected pitch — G-C13 and digest slot (6)

    /// The block U-A appends (unpitched-notes design §1.4), restated
    /// independently: the marker (a literal here, because changing it would
    /// silently re-key every set carrying a sound or a slide), the note count,
    /// then ONE BYTE PER NOTE by an explicit mapping, never a case's position.
    static func uaOriginBlock(_ set: PitchEditSet) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: UInt64(0x4F31_5249_4749_4E01).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        withUnsafeBytes(of: UInt64(bitPattern: Int64(set.segments.count)).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        for segment in set.segments {
            switch segment.origin {
            case .detected: bytes.append(0)
            case .transition: bytes.append(1)
            case .unpitched: bytes.append(2)
            }
        }
        return bytes
    }

    static let uaIdSoundShort = UUID(uuidString: "A0000000-0000-4000-8000-0000000000C1")!
    static let uaIdSoundLong = UUID(uuidString: "A0000000-0000-4000-8000-0000000000C2")!

    /// The G-C13 fixture. Two corrected notes under a SLOW ramp (110 ms), and
    /// two sounds:
    ///  * a SHORT one (64 ms) abutting note A's end. Its own half-ramp is
    ///    32 ms against A's 55 ms, so if it joined the gate sum it would be
    ///    normalised against A and trim A's correction near their shared
    ///    edge (design §1.6's example). That is what makes the bit-exact leg
    ///    able to fail;
    ///  * a LONG one (0.5 s) alone in a gap, long enough for the tone tracker
    ///    to read the pitch a move gives it.
    static func uaSet(soundOffsetCents: Double? = 0) -> PitchEditSet {
        var segments = [
            NoteSegment(id: c21IdA, startSeconds: 0.20, endSeconds: 0.90,
                        detectedHz: 220, detectedConfidence: 0.9, pitchOffsetCents: 100),
            NoteSegment(id: c21IdB, startSeconds: 1.00, endSeconds: 1.25,
                        detectedHz: 220, detectedConfidence: 0.9, pitchOffsetCents: -50),
        ]
        if let soundOffsetCents {
            segments.append(NoteSegment(id: uaIdSoundShort, startSeconds: 0.90,
                                        endSeconds: 0.964, detectedHz: 220,
                                        detectedConfidence: 0.4, origin: .unpitched))
            segments.append(NoteSegment(id: uaIdSoundLong, startSeconds: 1.30,
                                        endSeconds: 1.80, detectedHz: 220,
                                        detectedConfidence: 0.4,
                                        pitchOffsetCents: soundOffsetCents,
                                        origin: .unpitched))
        }
        return PitchEditSet(analysisVersion: 1, segments: segments, retuneMs: 110)
    }

    /// ⭐ **G-C13 (natural-tuning design R21): AN UNTOUCHED SOUND IS DRY, A
    /// MOVED ONE IS NOT.** Two halves, each able to fail:
    ///  * the table WITH two untouched sounds renders BIT-EXACT to the same
    ///    table without them (and builds an equal curve). Planted: letting an
    ///    untouched sound into the curve fails this through the short sound's
    ///    normalisation against note A;
    ///  * the long sound moved +300 c renders AT +300 c inside its span, and
    ///    note A outside it is where it was. Planted: a predicate that ignores
    ///    the offset renders the moved sound dry and fails the physics.
    /// The physics is the tone tracker's reading of WHERE the pitch is, never
    /// "the bytes differ".
    @Test("(10) U-A G-C13: untouched sounds render bit-exact to no sounds; a sound moved +300 c renders at +300 c")
    func uaUntouchedSoundsAreDryAndAMovedOneIsNot() throws {
        let without = Self.uaSet(soundOffsetCents: nil)
        let untouched = Self.uaSet(soundOffsetCents: 0)
        let moved = Self.uaSet(soundOffsetCents: 300)
        #expect(untouched.segments.count == 4, "positive control: the sounds are in the set")
        #expect(untouched.segments.filter { $0.origin == .unpitched }.count == 2)
        #expect(untouched.segments.filter(\.entersPitchCurve).count == 2)
        #expect(moved.segments.filter(\.entersPitchCurve).count == 3)

        // The curve: equal as a value (spans, unresolved ids, warp), and no
        // unresolved id names a sound.
        let curveWithout = PitchCorrectionCurve.make(editSet: without)
        let curveUntouched = PitchCorrectionCurve.make(editSet: untouched)
        #expect(curveUntouched == curveWithout,
                "an untouched sound changed the curve: it joined the gate sum")
        #expect(curveUntouched.unresolvedShapingSegmentIDs.isEmpty)

        // Bit-exact, through the shipping plan and the stretcher.
        let renderWithout = try Self.c21Render(without, ratio: 1)
        let renderUntouched = try Self.c21Render(untouched, ratio: 1)
        #expect(renderWithout.count == 96_000)
        #expect(renderUntouched.map(\.bitPattern) == renderWithout.map(\.bitPattern),
                "a table with untouched sounds did not render bit-exact to the same table without them")

        // Moved: the physics.
        let renderMoved = try Self.c21Render(moved, ratio: 1)
        let sr = 48_000.0
        let trackMoved = M23QToneTracker.track(renderMoved, sampleRate: sr)
        let trackWithout = M23QToneTracker.track(renderWithout, sampleRate: sr)
        let insideSound: Range<Double> = (1.40 * sr)..<(1.70 * sr)
        let insideNoteA: Range<Double> = (0.35 * sr)..<(0.75 * sr)
        let movedHz = try #require(M23QToneTracker.medianHz(trackMoved, centreIn: insideSound))
        let dryHz = try #require(M23QToneTracker.medianHz(trackWithout, centreIn: insideSound))
        let noteAMoved = try #require(M23QToneTracker.medianHz(trackMoved, centreIn: insideNoteA))
        let noteAWithout = try #require(M23QToneTracker.medianHz(trackWithout, centreIn: insideNoteA))
        let movedCents = 1200 * log2(movedHz / 220)
        let dryCents = 1200 * log2(dryHz / 220)
        let noteACents = 1200 * log2(noteAMoved / noteAWithout)
        // The INSTRUMENT'S control: the same tracker, over the same window, on
        // PURE tones at +100 c and +300 c, reads them within a cent (measured
        // 99.999 c). So the readings below are the render's, not the tracker's.
        func pureCents(_ cents: Double, in window: Range<Double>) throws -> Double {
            let tone = M23QSignal.sine(hz: 220 * pow(2, cents / 1200), frames: 96_000,
                                       sampleRate: sr, amplitude: 0.8)
            let hz = try #require(M23QToneTracker.medianHz(
                M23QToneTracker.track(tone, sampleRate: sr), centreIn: window))
            return 1200 * log2(hz / 220)
        }
        let pure100 = try pureCents(100, in: insideNoteA)
        let pure300 = try pureCents(300, in: insideSound)
        let noteAReads = 1200 * log2(noteAWithout / 220)
        Self.log("10", "G-C13: sound span reads \(movedCents) c moved, \(dryCents) c untouched; "
            + "note A moved by \(noteACents) c between the two renders; note A (+100 c asked) "
            + "reads \(noteAReads) c; pure tones read \(pure100) c / \(pure300) c")
        #expect(abs(pure100 - 100) < 1 && abs(pure300 - 300) < 1,
                "the tracker misreads a pure tone (\(pure100) / \(pure300)): nothing below is evidence")
        // The window is on the corrected note: it reads MOVED, not dry.
        // Pinned to +100 since p2-acc (2026-09-25). Before, this chain played
        // note A's +100 c at +109.7 c on this pure 220 Hz sine (the moved
        // sound's +300 at +301.5): the vendored transposer's fractional-bin
        // phase read, fixed by VENDORED.md patch 0001. Measured after: +99.88 c.
        #expect(noteAReads > 50, "control: the note A window reads dry (\(noteAReads) c)")
        #expect(abs(noteAReads - 100) < 0.5,
                "note A asked +100 c and reads \(noteAReads) c: the transposer is off again")
        #expect(abs(dryCents) < 5, "the untouched sound's span is not dry: \(dryCents) c")
        #expect(abs(movedCents - 300) < 5,
                "a sound moved +300 c renders at \(movedCents) c: the move did not reach the render")
        #expect(abs(noteACents) < 1, "moving the sound moved note A by \(noteACents) c")
    }

    /// ⭐ SLOT (6), THE ORIGIN BLOCK. Every set with no sound and no slide
    /// keeps its bytes (the legacy goldens, unmoved). A set that has one
    /// re-keys by EXACTLY the block, in slot 6, after the level block. That
    /// is proven against the independent restatement, which is itself proven
    /// against the captured goldens first. Planted: gating the block on
    /// `true` moves every legacy golden.
    @Test("(10) U-A: a set with a sound re-keys by exactly the origin block, in slot 6, and every other set keeps its bytes")
    func uaOriginBlockRekeysByExactlyTheBlock() {
        for golden in Self.c21LegacyDigestGoldens + Self.c21PreC2TimedHex {
            #expect(Self.c21SHA(Self.c21PreC2Material(Self.c21Set(golden.set))) == golden.hex,
                    "the test's own layout restatement does not reproduce '\(golden.set)'")
        }
        #expect(PitchEditSetDigest.originSuffixMarker == 0x4F31_5249_4749_4E01)
        #expect(NoteOrigin.allCases.map(PitchEditSetDigest.originByte) == [0, 1, 2])

        // No sound, no slide: no block, the legacy bytes.
        for golden in Self.c21LegacyDigestGoldens {
            let set = Self.c21Set(golden.set)
            #expect(set.segments.allSatisfy { $0.origin == .detected })
            #expect(PitchEditSetDigest.hex(set) == golden.hex)
        }

        // An untouched sound added to an EDITED set: the inline section gains
        // the segment and the block marks it, nothing else.
        let offset = Self.c21Set("offset")
        let withSound = PitchEditSet(
            analysisVersion: offset.analysisVersion,
            segments: offset.segments + [NoteSegment(
                id: Self.uaIdSoundLong, startSeconds: 1.9, endSeconds: 2.0, detectedHz: 233.08,
                detectedConfidence: 0.5, origin: .unpitched)],
            retuneMs: offset.retuneMs)
        #expect(withSound.segments.count == 3)
        let withSoundHex = PitchEditSetDigest.hex(withSound)
        #expect(withSoundHex == Self.c21SHA(Self.c21PreC2Material(withSound)
                                            + Self.uaOriginBlock(withSound)),
                "a set with a sound re-keyed, but not by exactly the origin block")
        // The same segment as a DETECTED note keys differently: the block is
        // what tells the two apart (they render differently once moved).
        var asNote = withSound
        asNote.segments[2] = NoteSegment(id: Self.uaIdSoundLong, startSeconds: 1.9,
                                         endSeconds: 2.0, detectedHz: 233.08,
                                         detectedConfidence: 0.5)
        #expect(PitchEditSetDigest.hex(asNote) == Self.c21SHA(Self.c21PreC2Material(asNote)))
        #expect(PitchEditSetDigest.hex(asNote) != withSoundHex)
        // A slide keys differently from a sound: its own byte.
        var asSlide = withSound
        asSlide.segments[2] = NoteSegment(id: Self.uaIdSoundLong, startSeconds: 1.9,
                                          endSeconds: 2.0, detectedHz: 233.08,
                                          detectedConfidence: 0.5, origin: .transition)
        #expect(Set([PitchEditSetDigest.hex(asSlide), withSoundHex,
                     PitchEditSetDigest.hex(asNote)]).count == 3)

        // ORDER: generator (inside the material), time warp (3), level (5),
        // origin (6).
        var everything = Self.c21Set("generator")
        everything.segments[1].timeStartDeltaSeconds = 0.02
        everything.segments[0].isCleared = true
        everything = everything.withSegments(everything.segments + [NoteSegment(
            id: Self.uaIdSoundShort, startSeconds: 1.9, endSeconds: 1.97, detectedHz: 233.08,
            detectedConfidence: 0.5, origin: .unpitched)])
        #expect(everything.segments.count == 3)
        #expect(PitchEditSetDigest.hex(everything)
                == Self.c21SHA(Self.c21PreC2Material(everything) + Self.c21WarpBlock()
                               + Self.i7aLevelBlock(everything) + Self.uaOriginBlock(everything)),
                "the origin block is not in slot 6, after the level block")

        // IDENTITY: detected notes plus an untouched sound bend nothing, so
        // they digest to "" and keep the identity bypass.
        let detectedPlusSound = PitchEditSet(segments: [
            NoteSegment(id: Self.c21IdA, startSeconds: 0, endSeconds: 1, detectedHz: 220,
                        detectedConfidence: 0.9),
            NoteSegment(id: Self.uaIdSoundShort, startSeconds: 1, endSeconds: 1.1,
                        detectedHz: 220, detectedConfidence: 0.4, origin: .unpitched),
        ])
        #expect(detectedPlusSound.isIdentity)
        #expect(PitchEditSetDigest.hex(detectedPlusSound).isEmpty)
        // …and the sound MOVED is a real edit: it digests, with the block.
        var movedSound = detectedPlusSound
        movedSound.segments[1].pitchOffsetCents = 300
        #expect(PitchEditSetDigest.hex(movedSound)
                == Self.c21SHA(Self.c21PreC2Material(movedSound) + Self.uaOriginBlock(movedSound)))
    }
}
