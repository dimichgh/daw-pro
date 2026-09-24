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
            "formantOffsetSemitones", "timeStartDeltaSeconds",
            "timeEndDeltaSeconds", "amplitudeDb",
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
            { s in s.formantOffsetSemitones = 1 },
            { s in s.timeStartDeltaSeconds = 0.01 },
            { s in s.timeEndDeltaSeconds = 0.01 },
            { s in s.amplitudeDb = -3 },
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
        for segment in mutated {
            let digest = PitchEditSetDigest.hex(PitchEditSet(segments: [segment]))
            #expect(digest != reference,
                    "a field change left the digest unchanged: \(segment)")
        }
        // Set-level fields.
        #expect(PitchEditSetDigest.hex(
            PitchEditSet(segments: [base()], retuneMs: 80)) != reference)
        #expect(PitchEditSetDigest.hex(
            PitchEditSet(analysisVersion: 2, segments: [base()])) != reference)
        // Determinism: the same set, built twice, and after a Codable round
        // trip (the shape a reopened project actually arrives in).
        #expect(PitchEditSetDigest.hex(PitchEditSet(segments: [base()])) == reference)
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
        for set in [nil, PitchEditSet.empty, detectedOnly, edited] as [PitchEditSet?] {
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
        for ratio in [1.0, 1.5] {
            for semitones in [0.0, 3.0] {
                for set in [nil, detectedOnly, edited] as [PitchEditSet?] {
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
}
