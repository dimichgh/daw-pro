import CSignalsmithStretch
import Foundation
import Testing

@testable import DAWEngine

/// m23-q Phase 0, experiment E1 — "can signalsmith-stretch change transpose
/// mid-stream, cleanly?" (design `docs/research/m23-q-pitch-correction-design.md`
/// §2.4; results `docs/research/m23-q-phase0-curve-experiment.md`).
///
/// Phase 0 ships nothing user-visible: no wire verb, no MCP tool, no `Clip`
/// field. The surface under test is `OfflineStretcher.stretchTransposeCurve`,
/// which is internal and reachable only from this target.
///
/// Deliberately NOT `@MainActor` — DSP has no business on the main actor, and
/// `MainActorOccupancySiteTests` Leg C is at its cadence cap.
///
/// Reading order matters and is enforced by the section comments: (d)
/// determinism/equivalence proves the re-chunked loop measures the same thing
/// the shipping loop does, then the instrument is positive-controlled against
/// synthetic signals with known answers, and only then are (a) alignment,
/// (b) the click test and (c) vibrato resolution believed.
@Suite("m23-q Phase 0 E1 — mid-stream transpose curve")
struct OfflineStretcherCurveTests {
    static let sampleRate = 48_000.0
    static let baseHz = 220.0
    static let amplitude: Float = 0.8
    static let twoSemitoneHz = baseHz * pow(2.0, 2.0 / 12.0) // 246.9417…
    static let frames = Int(sampleRate * 3.0) // 144_000
    /// Deliberately a MULTIPLE OF THE HOP (50 × 1440 = 1.5 s). A step requested
    /// mid-hop cannot be applied until the next chunk boundary, which would add
    /// an extra 0…1439 frames to leg (a)'s headline number; `curveQuantisesToTheHop`
    /// measures that term separately instead of smearing it into this one.
    static let stepFrame = 50 * 1440 // 72_000

    /// Renders settle within roughly a block of the edges; every steady-state
    /// reading stays this far inside.
    static let edgeGuardFrames = Int(sampleRate * 0.15)

    static func log(_ leg: String, _ message: String) {
        print("E1|\(leg)| \(message)")
    }

    static func sine(hz: Double = baseHz) -> [Float] {
        M23QSignal.sine(
            hz: hz, frames: frames, sampleRate: sampleRate, amplitude: amplitude)
    }

    // MARK: - The hop, MEASURED

    /// The accessor reads `stft.defaultInterval()`. It is NOT
    /// `Int(sampleRate * 0.03)`: `configure` hands the STFT `intervalSamples+1`
    /// and then calls `setInterval(intervalSamples)`, so the preset formula and
    /// the value the block loop compares `samplesSinceLast` against are two
    /// different quantities that happen to agree. Reading it is the point.
    @Test("hop: css_interval_samples reports the stretcher's own hop (1440 @ 48k)")
    func hopIsMeasuredNotDerived() throws {
        let handle = try #require(css_create(1, Float(Self.sampleRate), 1))
        defer { css_destroy(handle) }
        let interval = Int(css_interval_samples(handle))
        let inputLatency = Int(css_input_latency(handle))
        let outputLatency = Int(css_output_latency(handle))
        Self.log(
            "hop",
            "48000 Hz: interval=\(interval) inputLatency=\(inputLatency) "
                + "outputLatency=\(outputLatency) "
                + "(interval = \(Double(interval) / Self.sampleRate * 1000) ms)")
        #expect(
            interval == 1440,
            """
            design §2.2 predicts a 1440-sample (30 ms) hop at 48 kHz; the \
            stretcher reports \(interval). If this ever changes, the hop \
            analysis in §2.2 and every E1 number derived from it is stale.
            """)

        // A second rate, so the test cannot pass by coincidence of one preset.
        let handle441 = try #require(css_create(1, 44_100, 1))
        defer { css_destroy(handle441) }
        let interval441 = Int(css_interval_samples(handle441))
        Self.log("hop", "44100 Hz: interval=\(interval441)")
        #expect(interval441 != interval, "the hop must scale with sample rate")
        #expect(interval441 > 0)
    }

    // MARK: - (d) determinism and equivalence — RUN AND BELIEVED FIRST

    /// A constant-ZERO curve must be bit-identical to `stretch(ratio: 1,
    /// semitones: 0)`. This is the weaker of the two equivalence legs (a
    /// multiplier of exactly 1 takes a different branch at
    /// `signalsmith-stretch.h:300`), which is why the +2 leg below exists.
    @Test("(d) constant-zero curve is bit-identical to the constant call")
    func curveZeroMatchesConstantZero() throws {
        let input = [Self.sine()]
        let reference = try OfflineStretcher.stretch(
            input: input, sampleRate: Self.sampleRate, ratio: 1, semitones: 0,
            formantPreserve: false)
        let curved = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: Self.sampleRate, ratio: 1,
            curve: [(outputFrame: 0, semitones: 0)], formantPreserve: false)
        let differing = Self.differingSamples(reference[0], curved[0])
        Self.log("d", "constant-0 curve vs constant-0 call: \(differing) differing samples of \(reference[0].count)")
        #expect(curved[0].count == reference[0].count)
        #expect(differing == 0)
        #expect(M23QWaveform.isAllFinite(curved[0]))
    }

    /// THE LEG THAT CATCHES THE RE-CHUNKING. The curve entry point processes in
    /// 1440-frame chunks where `stretch` uses 4096; §2.2 note 5 says the hop
    /// grid counts OUTPUT samples, so if re-chunking perturbed the cumulative
    /// `inTarget` arithmetic, every downstream E1 number would measure a
    /// different render than the shipping path produces. A non-trivial
    /// multiplier exercises the mapped-frequency branch while doing it.
    @Test("(d) constant +2 curve is bit-identical to the constant call")
    func curveTwoMatchesConstantTwo() throws {
        let input = [Self.sine()]
        let reference = try OfflineStretcher.stretch(
            input: input, sampleRate: Self.sampleRate, ratio: 1, semitones: 2,
            formantPreserve: false)
        let curved = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: Self.sampleRate, ratio: 1,
            curve: [(outputFrame: 0, semitones: 2)], formantPreserve: false)
        let differing = Self.differingSamples(reference[0], curved[0])
        Self.log("d", "constant-+2 curve vs constant-+2 call: \(differing) differing samples of \(reference[0].count)")
        #expect(curved[0].count == reference[0].count)
        #expect(differing == 0)
        #expect(M23QWaveform.isAllFinite(curved[0]))
    }

    /// Anti-vacuity for the two legs above: the same comparison against a
    /// DIFFERENT constant must differ in essentially every sample. Without
    /// this, a comparator that always returns 0 would pass both.
    @Test("(d) anti-vacuity: unequal constants differ nearly everywhere")
    func differingConstantsDiffer() throws {
        let input = [Self.sine()]
        let zero = try OfflineStretcher.stretch(
            input: input, sampleRate: Self.sampleRate, ratio: 1, semitones: 0,
            formantPreserve: false)
        let two = try OfflineStretcher.stretch(
            input: input, sampleRate: Self.sampleRate, ratio: 1, semitones: 2,
            formantPreserve: false)
        let differing = Self.differingSamples(zero[0], two[0])
        Self.log("d", "anti-vacuity 0 vs +2: \(differing) differing samples of \(zero[0].count)")
        #expect(differing > zero[0].count * 9 / 10)
    }

    /// Two runs of the same time-VARYING curve, bit-identical (fixed RNG seed,
    /// `OfflineStretcher.rngSeed`).
    @Test("(d) a stepped curve renders deterministically across runs")
    func curveRunsAreDeterministic() throws {
        let input = [Self.sine()]
        let curve = [
            (outputFrame: 0, semitones: 0.0),
            (outputFrame: Self.stepFrame, semitones: 2.0),
        ]
        let first = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: Self.sampleRate, ratio: 1, curve: curve,
            formantPreserve: false)
        let second = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: Self.sampleRate, ratio: 1, curve: curve,
            formantPreserve: false)
        let differing = Self.differingSamples(first[0], second[0])
        Self.log("d", "two runs of the stepped curve: \(differing) differing samples")
        #expect(differing == 0)
        #expect(M23QWaveform.isAllFinite(first[0]))
    }

    /// At ratio 1 the re-chunk is provably harmless: `inTarget` reduces to
    /// `outDone + outBlock` and `inputOffset = round(outputIndex·in/out)`
    /// reduces to `outputIndex`, whatever the chunk size. At ratio ≠ 1 neither
    /// reduction holds — the per-call output→input map is a piecewise
    /// approximation of the global ratio, and finer chunks approximate it
    /// differently. This leg therefore does not ASSERT equality, it MEASURES
    /// the divergence — and the measurement (2026-08-17, ratio 1.5, +2 st) came
    /// back at **0 differing samples of 216000**, peak |difference| exactly 0.
    /// The cumulative `inTarget` rounding tracks the same global map at both
    /// chunk sizes. Recorded as a measured fact, not as a guarantee: the
    /// expectations below stay deliberately weak so that a future divergence
    /// shows up in the logged number rather than as a red test nobody expected.
    @Test("(d) at ratio ≠ 1 the re-chunk is measured, not assumed, to be free")
    func nonUnityRatioChunkDivergence() throws {
        let input = [Self.sine()]
        let reference = try OfflineStretcher.stretch(
            input: input, sampleRate: Self.sampleRate, ratio: 1.5, semitones: 2,
            formantPreserve: false)[0]
        let curved = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: Self.sampleRate, ratio: 1.5,
            curve: [(outputFrame: 0, semitones: 2)], formantPreserve: false)[0]
        let differing = Self.differingSamples(reference, curved)
        var peak = 0.0
        for index in reference.indices where index < curved.count {
            peak = max(peak, abs(Double(reference[index]) - Double(curved[index])))
        }
        Self.log(
            "d",
            "ratio 1.5, constant +2: \(differing) differing samples of "
                + "\(reference.count) (\(Double(differing) / Double(reference.count) * 100) %), "
                + "peak |difference| \(peak) on a 0.8 signal "
                + "(\(20 * log10(max(peak, 1e-12) / 0.8)) dB below nominal)")
        #expect(reference.count == curved.count)
        #expect(M23QWaveform.isAllFinite(curved))
    }

    /// Every other leg runs `formantPreserve: false`. Vocal mode is the mode
    /// this milestone is FOR, and it takes a different branch
    /// (`blockProcess.processFormants`, `signalsmith-stretch.h:310`), so the
    /// artefact numbers do not transfer for free.
    @Test("(b) the same step with formant preservation ON")
    func formantPreserveStepArtefacts() throws {
        let input = [Self.sine()]
        let hop = 1440
        let landing = Self.stepFrame + OfflineStretcher.measuredCurveLatencyFrames
        let window = (landing - 3 * hop)..<(landing + 4 * hop)
        let body = Self.edgeGuardFrames..<(Self.frames - Self.edgeGuardFrames)

        func report(_ signal: [Float]) -> (dipDb: Double, hfDb: Double, peak: Double) {
            let envelope = M23QWaveform.envelope(signal)
            let plateau = envelope.filter { body.contains($0.frame) }
                .map(\.amplitude).sorted()
            let reference = plateau.isEmpty ? 1 : plateau[plateau.count / 2]
            let low = envelope.filter { window.contains($0.frame) }
                .map(\.amplitude).min() ?? reference
            let hf = M23QWaveform.highFrequencyEnergy(
                signal, sampleRate: Self.sampleRate)
                .filter { window.contains($0.frame) }.map(\.hfDb).max() ?? -200
            return (
                20 * log10(max(low, 1e-9) / reference), hf,
                M23QWaveform.peakStepDifference(signal, in: window).peak)
        }

        for preserve in [false, true] {
            let curved = try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: Self.sampleRate, ratio: 1,
                curve: [
                    (outputFrame: 0, semitones: 0.0),
                    (outputFrame: Self.stepFrame, semitones: 2.0),
                ], formantPreserve: preserve)[0]
            let constant = try OfflineStretcher.stretch(
                input: input, sampleRate: Self.sampleRate, ratio: 1,
                semitones: 2, formantPreserve: preserve)[0]
            let stepped = report(curved)
            let flat = report(constant)
            Self.log(
                "b",
                "formantPreserve \(preserve): step dip \(stepped.dipDb) dB, "
                    + "HF>2 kHz \(stepped.hfDb) dB, peak |Δ| \(stepped.peak); "
                    + "constant-+2 baseline dip \(flat.dipDb) dB, HF "
                    + "\(flat.hfDb) dB, peak |Δ| \(flat.peak); broadband excess "
                    + "\(stepped.hfDb - flat.hfDb) dB")
            #expect(M23QWaveform.isAllFinite(curved))
            #expect(
                stepped.hfDb <= flat.hfDb + 6,
                "formantPreserve \(preserve): broadband excess \(stepped.hfDb - flat.hfDb) dB is a click")
        }
    }

    @Test("(d) curve validation rejects malformed input")
    func curveValidation() throws {
        let input = [Self.sine()]
        #expect(throws: OfflineStretcherError.self) {
            _ = try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: Self.sampleRate, ratio: 1, curve: [],
                formantPreserve: false)
        }
        #expect(throws: OfflineStretcherError.self) {
            _ = try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: Self.sampleRate, ratio: 1,
                curve: [(outputFrame: 100, semitones: 0), (outputFrame: 10, semitones: 1)],
                formantPreserve: false)
        }
        #expect(throws: OfflineStretcherError.self) {
            _ = try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: Self.sampleRate, ratio: 1,
                curve: [(outputFrame: 0, semitones: Double.nan)],
                formantPreserve: false)
        }
    }

    @Test("(d) sample-and-hold curve lookup")
    func curveLookup() {
        let curve = [
            (outputFrame: 100, semitones: -1.0),
            (outputFrame: 200, semitones: 3.0),
        ]
        #expect(OfflineStretcher.transposeCurveValue(curve, at: 0) == -1)
        #expect(OfflineStretcher.transposeCurveValue(curve, at: 99) == -1)
        #expect(OfflineStretcher.transposeCurveValue(curve, at: 100) == -1)
        #expect(OfflineStretcher.transposeCurveValue(curve, at: 199) == -1)
        #expect(OfflineStretcher.transposeCurveValue(curve, at: 200) == 3)
        #expect(OfflineStretcher.transposeCurveValue(curve, at: 10_000) == 3)
    }

    // MARK: - Instrument positive controls (before any stretcher number)

    /// The tracker on a signal with no stretcher in the loop: a pure tone must
    /// read back within a cent, at both ends of the step.
    @Test("instrument: steady-tone accuracy")
    func instrumentSteadyTone() throws {
        for hz in [Self.baseHz, Self.twoSemitoneHz] {
            let estimates = M23QToneTracker.track(
                Self.sine(hz: hz), sampleRate: Self.sampleRate)
            let median = try #require(
                M23QToneTracker.medianHz(
                    estimates,
                    centreIn: Double(Self.edgeGuardFrames)
                        ..< Double(Self.frames - Self.edgeGuardFrames)))
            let error = M23QToneTracker.cents(median, above: hz)
            Self.log(
                "instrument",
                "steady \(hz) Hz: measured \(median) Hz, error \(error) cents")
            #expect(abs(error) < 1.0)
        }
    }

    /// The tracker on a synthetic frequency STEP with no stretcher in the loop.
    /// This is the number leg (a) subtracts: the estimator's own transition
    /// bias, which comes from its window and its centre-frame convention. If a
    /// windowed estimate were attributed to the window's START, this would come
    /// back at ≈ +512 frames instead of ≈ 0.
    @Test("instrument: step-location bias")
    func instrumentStepBias() throws {
        let signal = M23QSignal.steppedSine(
            fromHz: Self.baseHz, toHz: Self.twoSemitoneHz,
            stepFrame: Self.stepFrame, frames: Self.frames,
            sampleRate: Self.sampleRate, amplitude: Self.amplitude)
        let profile = try Self.measuredStepProfile(signal)
        let bias = profile.f50 - Double(Self.stepFrame)
        Self.log(
            "instrument",
            "synthetic step at \(Self.stepFrame): tracker f50 bias \(bias) frames "
                + "(\(bias / Self.sampleRate * 1000) ms); f10 "
                + "\(profile.f10 - Double(Self.stepFrame)), f90 "
                + "\(profile.f90 - Double(Self.stepFrame)); own transition width "
                + "\(profile.widthFrames) frames — the instrument's floor")
        #expect(abs(bias) < 256, "tracker step bias must be small and known")
    }

    /// The tracker on synthetic vibrato with no stretcher in the loop: its own
    /// tracking error and depth attenuation. Leg (c) reports the stretcher's
    /// error against THIS floor, never in isolation — a 21 ms analysis window
    /// and a 30 ms hop produce indistinguishable-looking errors.
    @Test("instrument: vibrato floor")
    func instrumentVibratoFloor() throws {
        let signal = M23QSignal.vibratoSine(
            baseHz: Self.baseHz, depthCents: 50, rateHz: 5, frames: Self.frames,
            sampleRate: Self.sampleRate, amplitude: Self.amplitude)
        let result = Self.vibratoError(signal, offsetFrames: 0)
        Self.log(
            "instrument",
            "synthetic 5 Hz ±50 c: rms \(result.rmsCents) c, max \(result.maxCents) c, "
                + "peak-to-peak depth \(result.peakToPeakDepthCents) c, "
                + "fitted depth \(result.fittedDepthCents) c of 50 requested, "
                + "fitted lag \(result.fittedLagFrames) frames, "
                + "non-sinusoidal rms \(result.nonSinusoidalRMSCents) c")
        #expect(result.rmsCents < 6.0)
        #expect(result.fittedDepthCents > 44)
        #expect(
            abs(result.fittedLagFrames) < 240 || abs(result.fittedLagFrames - 9600) < 240,
            "the instrument must not invent a lag on a signal that has none")
    }

    // MARK: - (a) alignment

    /// Where the requested step ACTUALLY lands in the delivered output.
    /// Design §2.3 derives ≈60 ms of input latency and ≈60 ms of output latency
    /// at 48 k and flags that `outputSeek` may make them partly cancel — that
    /// derivation is not a measurement, and this is the measurement.
    @Test("(a) a requested step lands at the measured curve latency")
    func stepAlignment() throws {
        let input = [Self.sine()]
        let curve = [
            (outputFrame: 0, semitones: 0.0),
            (outputFrame: Self.stepFrame, semitones: 2.0),
        ]
        let rendered = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: Self.sampleRate, ratio: 1, curve: curve,
            formantPreserve: false)[0]

        let control = M23QSignal.steppedSine(
            fromHz: Self.baseHz, toHz: Self.twoSemitoneHz,
            stepFrame: Self.stepFrame, frames: Self.frames,
            sampleRate: Self.sampleRate, amplitude: Self.amplitude)
        let controlProfile = try Self.measuredStepProfile(control)
        let profile = try Self.measuredStepProfile(rendered)
        let instrumentBias = controlProfile.f50 - Double(Self.stepFrame)
        let offset = profile.f50 - Double(Self.stepFrame) - instrumentBias

        Self.log(
            "a",
            "control (no stretcher): plateaus \(controlProfile.lowHz)/\(controlProfile.highHz) Hz, "
                + "f10 \(controlProfile.f10) f50 \(controlProfile.f50) f90 \(controlProfile.f90), "
                + "width \(controlProfile.widthFrames) frames "
                + "(\(controlProfile.widthFrames / Self.sampleRate * 1000) ms), "
                + "instrument bias \(instrumentBias)")
        Self.log(
            "a",
            "render: plateaus \(profile.lowHz)/\(profile.highHz) Hz, "
                + "f10 \(profile.f10) f50 \(profile.f50) f90 \(profile.f90), "
                + "transition width \(profile.widthFrames) frames "
                + "(\(profile.widthFrames / Self.sampleRate * 1000) ms)")
        Self.log(
            "a",
            "requested step at \(Self.stepFrame) (hop-aligned); NET offset of the "
                + "50 % point \(offset) frames = \(offset / Self.sampleRate * 1000) ms. "
                + "css_output_latency = 2880 (60 ms); design §2.3 predicts ≈60 ms "
                + "for each of input and output latency and flags that outputSeek "
                + "may make them partly cancel.")
        Self.log(
            "a",
            "onset (10 %) offset \(profile.f10 - Double(Self.stepFrame)) frames; "
                + "settle (90 %) offset \(profile.f90 - Double(Self.stepFrame)) frames")

        #expect(
            abs(offset - Double(OfflineStretcher.measuredCurveLatencyFrames)) < 480,
            """
            E1(a): the curve-application offset moved away from the measured \
            constant \(OfflineStretcher.measuredCurveLatencyFrames) frames. \
            Measured \(offset). If this is a deliberate change, RE-MEASURE and \
            update the constant with the new number in its comment — never the \
            other way round.
            """)
        #expect(M23QWaveform.isAllFinite(rendered))
    }

    /// The second term in leg (a)'s budget, measured on its own: the curve is
    /// read once per chunk, so a step requested mid-hop waits for the next
    /// chunk boundary. Three requests — one hop-aligned, one 720 frames before
    /// the NEXT boundary, one on that boundary — must produce exactly two
    /// distinct landings, one hop apart.
    @Test("(a) curve application quantises to the hop, not to the request")
    func curveQuantisesToTheHop() throws {
        let input = [Self.sine()]
        func landing(requestedAt frame: Int) throws -> Double {
            let rendered = try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: Self.sampleRate, ratio: 1,
                curve: [
                    (outputFrame: 0, semitones: 0.0),
                    (outputFrame: frame, semitones: 2.0),
                ], formantPreserve: false)[0]
            return try Self.measuredStepProfile(rendered).f50
        }
        let onBoundary = try landing(requestedAt: Self.stepFrame)
        let justAfter = try landing(requestedAt: Self.stepFrame + 720)
        let nextBoundary = try landing(requestedAt: Self.stepFrame + 1440)
        Self.log(
            "a",
            "quantisation: request \(Self.stepFrame) → \(onBoundary); "
                + "+720 → \(justAfter); +1440 → \(nextBoundary); "
                + "hop = 1440")
        #expect(abs(justAfter - nextBoundary) < 120, "a mid-hop request waits for the next boundary")
        #expect(
            abs((justAfter - onBoundary) - 1440) < 240,
            "the wait is exactly one hop, not a fraction of one")
    }

    // MARK: - (b) the click test

    /// ⭐ **THE POSITIVE CONTROL FOR THE CLICK DETECTOR ITSELF** (added by the
    /// orchestrator during verification; the E1 agent did not write one).
    ///
    /// Leg (b)'s verdict rests on an ABSENCE: broadband energy above 2 kHz in
    /// the curve render sits at the constant render's floor, therefore no
    /// click. **A negative result from a hand-built probe proves nothing until
    /// the probe is shown to detect what it is looking for** — a detector that
    /// is simply blind returns exactly the same "no click found".
    ///
    /// So plant real discontinuities of known size into a REAL stretcher output
    /// (the constant +2 render, so the floor is the true phase-vocoder floor
    /// rather than a bypass) and confirm `highFrequencyEnergy` sees them. The
    /// smallest size planted, 0.001, is deliberately the magnitude of the very
    /// excess §5.2 dismisses (curve peak |Δ| 0.026399 − constant baseline
    /// 0.025374 = 0.001025): if the detector fires on a click THAT small, then
    /// its silence on the real render is evidence, and §5.2's dismissal is
    /// falsifiable rather than merely asserted.
    @Test("(b) POSITIVE CONTROL: the click detector fires on planted clicks")
    func clickDetectorSeesAPlantedClick() throws {
        let input = [Self.sine()]
        let clean = try OfflineStretcher.stretch(
            input: input, sampleRate: Self.sampleRate, ratio: 1, semitones: 2,
            formantPreserve: false)[0]

        // Well inside the body, away from the edge guard and from leg (b)'s
        // own transition window, so nothing else is happening here.
        let plantFrame = Self.frames / 2 + 7_000
        let window = (plantFrame - 2048)..<(plantFrame + 2048)

        func hfMax(_ signal: [Float]) -> Double {
            M23QWaveform.highFrequencyEnergy(signal, sampleRate: Self.sampleRate)
                .filter { window.contains($0.frame) }
                .map(\.hfDb)
                .max() ?? .nan
        }

        let floor = hfMax(clean)
        Self.log(
            "b-control",
            "unplanted constant-+2 render in the plant window: \(floor) dB")

        // ⚠️ THE FLOOR'S OWN SPREAD, without which "+0.17 dB excess" cannot be
        // called small. A rise is only evidence if it exceeds how much this
        // measure wanders on a render where nothing is happening. Measured
        // across the whole body of the unplanted constant render.
        let body = Self.edgeGuardFrames..<(Self.frames - Self.edgeGuardFrames)
        let floorProfile = M23QWaveform.highFrequencyEnergy(
            clean, sampleRate: Self.sampleRate
        ).filter { body.contains($0.frame) }.map(\.hfDb)
        let floorMin = floorProfile.min() ?? .nan
        let floorMax = floorProfile.max() ?? .nan
        let mean = floorProfile.reduce(0, +) / Double(floorProfile.count)
        let sd = (floorProfile.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(floorProfile.count)).squareRoot()
        Self.log(
            "b-control",
            "FLOOR SPREAD on the unplanted render across \(floorProfile.count) "
                + "windows: min \(floorMin) dB, max \(floorMax) dB, "
                + "peak-to-peak \(floorMax - floorMin) dB, sd \(sd) dB — "
                + "the curve render's in-window excess was +0.17 dB, so compare "
                + "that against THIS, not against zero")
        #expect(
            sd > 0,
            """
            a floor with no spread means highFrequencyEnergy returned a \
            constant, i.e. it is not measuring the signal at all
            """)

        var detected: [(delta: Float, hfDb: Double, rise: Double)] = []
        for delta in [Float(0.001), 0.005, 0.02, 0.1] {
            var planted = clean
            // A single-sample additive step: the minimal true discontinuity.
            planted[plantFrame] += delta
            let hf = hfMax(planted)
            detected.append((delta, hf, hf - floor))
            Self.log(
                "b-control",
                "planted single-sample click of \(delta): HF \(hf) dB "
                    + "(rise \(hf - floor) dB over the unplanted floor)")
        }

        // The largest planted click must be unmistakable. If this fails the
        // detector is blind and leg (b)'s entire verdict is unsupported.
        let biggest = try #require(detected.last)
        #expect(
            biggest.rise > 6.0,
            """
            the click detector did not see a planted 0.1 discontinuity \
            (rise \(biggest.rise) dB). Leg (b) concluded "no click" from an \
            ABSENCE on this same measure — if the measure is blind, that \
            conclusion is void, not merely weak.
            """)

        // Monotonicity: a bigger discontinuity must read as more broadband
        // energy. A detector that fires identically on everything is measuring
        // something other than the click.
        for (a, b) in zip(detected, detected.dropFirst()) {
            #expect(
                b.hfDb > a.hfDb,
                "HF did not increase from delta \(a.delta) to \(b.delta)")
        }

        // ⭐ THE RESOLUTION LIMIT, ASSERTED — the number that says how small a
        // click leg (b) could still have caught. A rise only counts as detection
        // if it clears the floor's OWN wander, so the yardstick is `sd`, not
        // zero. Measured: sd ≈ 1.61 dB, so 0.005 (+11.5 dB ≈ 7 sd) is resolved
        // unambiguously while 0.001 (+1.15 dB ≈ 0.7 sd) is NOT.
        let smallest = try #require(detected.first)
        let resolved = try #require(detected.dropFirst().first)
        #expect(
            resolved.rise > 3 * sd,
            """
            the detector cannot resolve a planted 0.005 click (rise \
            \(resolved.rise) dB against a floor sd of \(sd) dB). That is the \
            smallest discontinuity leg (b) is entitled to claim it ruled out.
            """)
        Self.log(
            "b-control",
            "RESOLUTION: floor sd \(sd) dB. A 0.005 click rises "
                + "\(resolved.rise) dB (\(resolved.rise / sd) sd) — RESOLVED. A "
                + "0.001 click rises only \(smallest.rise) dB "
                + "(\(smallest.rise / sd) sd) — NOT resolved, so leg (b) must "
                + "NOT be read as ruling out clicks that small. The curve "
                + "render's own in-window excess was +0.17 dB "
                + "(\(0.17 / sd) sd), i.e. indistinguishable from no excess at "
                + "all — which is the actual finding. E2 covers what this "
                + "instrument cannot resolve.")
    }

    /// Peak sample-to-sample discontinuity across the step, beside the SAME
    /// statistic on the two constant renders measured by the SAME harness. The
    /// kill criterion is relative, so an absolute number cannot adjudicate it;
    /// and because it asks whether "a ≤30 ms crossfade" could hide the
    /// artefact, the excess DURATION is measured too.
    @Test("(b) the step is no clickier than a constant-pitch render")
    func clickTest() throws {
        let input = [Self.sine()]
        let curve = [
            (outputFrame: 0, semitones: 0.0),
            (outputFrame: Self.stepFrame, semitones: 2.0),
        ]
        let curved = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: Self.sampleRate, ratio: 1, curve: curve,
            formantPreserve: false)[0]
        let flat0 = try OfflineStretcher.stretch(
            input: input, sampleRate: Self.sampleRate, ratio: 1, semitones: 0,
            formantPreserve: false)[0]
        let flat2 = try OfflineStretcher.stretch(
            input: input, sampleRate: Self.sampleRate, ratio: 1, semitones: 2,
            formantPreserve: false)[0]

        // Window: the WHOLE transition plus a hop of margin either side. The
        // pitch does not move instantaneously (leg (a) measures the width), so
        // a window sized to the 50 % point alone would look at the wrong place.
        let hop = 1440
        let landing = Self.stepFrame + OfflineStretcher.measuredCurveLatencyFrames
        let window = (landing - 3 * hop)..<(landing + 4 * hop)
        let body = Self.edgeGuardFrames..<(Self.frames - Self.edgeGuardFrames)

        let curvePeak = M23QWaveform.peakStepDifference(curved, in: window)
        let flat0Peak = M23QWaveform.peakStepDifference(flat0, in: window)
        let flat2Peak = M23QWaveform.peakStepDifference(flat2, in: window)
        let baseline = max(flat0Peak.peak, flat2Peak.peak)
        let theory0 = M23QWaveform.theoreticalPeakStep(
            hz: Self.baseHz, amplitude: Double(Self.amplitude),
            sampleRate: Self.sampleRate)
        let theory2 = M23QWaveform.theoreticalPeakStep(
            hz: Self.twoSemitoneHz, amplitude: Double(Self.amplitude),
            sampleRate: Self.sampleRate)

        Self.log(
            "b",
            "window \(window.lowerBound)..<\(window.upperBound) around landing \(landing): "
                + "curve peak |Δ| \(curvePeak.peak) at frame \(curvePeak.frame); "
                + "constant-0 \(flat0Peak.peak) at \(flat0Peak.frame); "
                + "constant-+2 \(flat2Peak.peak) at \(flat2Peak.frame); "
                + "theoretical 2πfA/fs = \(theory0) (220 Hz) / \(theory2) (246.94 Hz); "
                + "curve/baseline = \(curvePeak.peak / baseline)")

        let excursions = M23QWaveform.excursions(curved, in: window, above: baseline)
        Self.log(
            "b",
            "in-window excess over the constant baseline \(baseline): "
                + "\(excursions.count) samples, span \(excursions.spanFrames) frames "
                + "(\(Double(excursions.spanFrames) / Self.sampleRate * 1000) ms), "
                + "first \(String(describing: excursions.firstFrame)), "
                + "last \(String(describing: excursions.lastFrame))")

        // Whole-body too, so the window choice cannot hide anything — and the
        // whole-body baseline is itself measured, not assumed.
        let curveBody = M23QWaveform.peakStepDifference(curved, in: body)
        let flat0Body = M23QWaveform.peakStepDifference(flat0, in: body)
        let flat2Body = M23QWaveform.peakStepDifference(flat2, in: body)
        let bodyBaseline = max(flat0Body.peak, flat2Body.peak)
        let bodyExcursions = M23QWaveform.excursions(
            curved, in: body, above: bodyBaseline)
        Self.log(
            "b",
            "whole-body peak |Δ|: curve \(curveBody.peak) at \(curveBody.frame) "
                + "(\(curveBody.frame - landing) frames from the landing); "
                + "constant-0 \(flat0Body.peak) at \(flat0Body.frame); "
                + "constant-+2 \(flat2Body.peak) at \(flat2Body.frame); "
                + "curve/baseline = \(curveBody.peak / bodyBaseline)")
        Self.log(
            "b",
            "whole-body excess over \(bodyBaseline): \(bodyExcursions.count) samples, "
                + "span \(bodyExcursions.spanFrames) frames "
                + "(\(Double(bodyExcursions.spanFrames) / Self.sampleRate * 1000) ms), "
                + "first \(String(describing: bodyExcursions.firstFrame)), "
                + "last \(String(describing: bodyExcursions.lastFrame))")

        // A raw peak |Δ| cannot tell a click from the tone simply getting
        // higher or louder, and across a 0 → +2 step it does BOTH. This
        // normalises by the locally measured f and A: ≈1 for any clean sine,
        // well above 1 for a genuine discontinuity.
        func ratioReport(_ signal: [Float], label: String) -> (bodyMax: Double, windowMax: Double) {
            let estimates = M23QToneTracker.track(signal, sampleRate: Self.sampleRate)
            let ratios = M23QWaveform.sinusoidalityRatios(
                signal, sampleRate: Self.sampleRate, estimates: estimates)
            let inBody = ratios.filter { body.contains($0.frame) }
            let inWindow = ratios.filter { window.contains($0.frame) }
            let bodyMax = inBody.max { $0.ratio < $1.ratio }
            let windowMax = inWindow.max { $0.ratio < $1.ratio }
            Self.log(
                "b",
                "\(label): sinusoidality ratio (peak |Δ| ÷ 2πfA/fs) body max "
                    + "\(bodyMax?.ratio ?? .nan) at \(bodyMax?.frame ?? -1); "
                    + "in-window max \(windowMax?.ratio ?? .nan) at "
                    + "\(windowMax?.frame ?? -1); window amplitude range "
                    + "\(inWindow.map(\.amplitude).min() ?? .nan)…"
                    + "\(inWindow.map(\.amplitude).max() ?? .nan)")
            return (bodyMax?.ratio ?? .nan, windowMax?.ratio ?? .nan)
        }
        let curveRatios = ratioReport(curved, label: "curve")
        let flat0Ratios = ratioReport(flat0, label: "constant-0")
        let flat2Ratios = ratioReport(flat2, label: "constant-+2")
        let ratioBaseline = max(flat0Ratios.bodyMax, flat2Ratios.bodyMax)
        Self.log(
            "b",
            "normalised verdict: curve in-window \(curveRatios.windowMax) vs "
                + "constant-render baseline \(ratioBaseline) — excess "
                + "\(curveRatios.windowMax - ratioBaseline)")

        // THE CLICK DETECTOR PROPER. Everything above still moves when the tone
        // merely gets louder or higher. A click is BROADBAND: it puts energy
        // where a 220 Hz sine has none.
        func hfReport(_ signal: [Float], label: String) -> (bodyMax: Double, windowMax: Double) {
            let profile = M23QWaveform.highFrequencyEnergy(
                signal, sampleRate: Self.sampleRate)
            let inBody = profile.filter { body.contains($0.frame) }
            let inWindow = profile.filter { window.contains($0.frame) }
            let bodyMax = inBody.max { $0.hfDb < $1.hfDb }
            let windowMax = inWindow.max { $0.hfDb < $1.hfDb }
            Self.log(
                "b",
                "\(label): energy above 2 kHz, body max \(bodyMax?.hfDb ?? .nan) dB "
                    + "at \(bodyMax?.frame ?? -1); in-window max "
                    + "\(windowMax?.hfDb ?? .nan) dB at \(windowMax?.frame ?? -1)")
            return (bodyMax?.hfDb ?? .nan, windowMax?.hfDb ?? .nan)
        }
        let curveHF = hfReport(curved, label: "curve")
        let flat0HF = hfReport(flat0, label: "constant-0")
        let flat2HF = hfReport(flat2, label: "constant-+2")
        let hfBaseline = max(flat0HF.bodyMax, flat2HF.bodyMax)

        // And the level dip: overlap-adding frames at two different pitches
        // makes them beat. Real, audible, and NOT a discontinuity.
        func dip(_ signal: [Float]) -> Double {
            let envelope = M23QWaveform.envelope(signal)
            let inWindow = envelope.filter { window.contains($0.frame) }
                .map(\.amplitude)
            let plateau = envelope.filter { body.contains($0.frame) }
                .map(\.amplitude).sorted()
            let reference = plateau.isEmpty ? 1 : plateau[plateau.count / 2]
            let low = inWindow.min() ?? reference
            return 20 * log10(max(low, 1e-9) / reference)
        }
        Self.log(
            "b",
            "level dip through the transition: curve \(dip(curved)) dB; "
                + "constant-0 \(dip(flat0)) dB; constant-+2 \(dip(flat2)) dB")

        // The dip's WIDTH, not just its depth. This is what disposes of the
        // raw first-difference excursion span: if the level sags for about as
        // long as the "excess |Δ|" lasts, the excess IS the sag — a smooth
        // envelope movement co-located with the transition — and not a
        // discontinuity that a crossfade would have to hide.
        func dipWidth(_ signal: [Float], belowDb: Double) -> (frames: Int, ms: Double) {
            let envelope = M23QWaveform.envelope(signal)
            let plateau = envelope.filter { body.contains($0.frame) }
                .map(\.amplitude).sorted()
            let reference = plateau.isEmpty ? 1 : plateau[plateau.count / 2]
            let limit = reference * pow(10, belowDb / 20)
            let offending = envelope.filter {
                window.contains($0.frame) && $0.amplitude < limit
            }
            guard let first = offending.first?.frame,
                let last = offending.last?.frame
            else { return (0, 0) }
            let span = last - first + 128 // one envelope hop of granularity
            return (span, Double(span) / Self.sampleRate * 1000)
        }
        // THE FRAME THAT DECIDES IT. The raw first-difference excess is spread
        // over ~45 ms, far longer than the dip, so "it is the dip" is not the
        // whole answer. Evaluate the sine law AT the offending frame: if the
        // locally measured f and A predict the observed |Δ|, the excess is the
        // envelope rippling and the tone sitting higher, with nothing left over
        // for a discontinuity.
        func explainPeak(_ signal: [Float], label: String) {
            let peak = M23QWaveform.peakStepDifference(signal, in: body)
            let local = (peak.frame - 128)..<(peak.frame + 128)
            let amplitude = M23QWaveform.peakAmplitude(signal, in: local)
            let estimates = M23QToneTracker.track(signal, sampleRate: Self.sampleRate)
            let nearest = estimates.min {
                abs($0.centreFrame - Double(peak.frame))
                    < abs($1.centreFrame - Double(peak.frame))
            }
            let hz = nearest?.hz ?? .nan
            let predicted = M23QWaveform.theoreticalPeakStep(
                hz: hz, amplitude: amplitude, sampleRate: Self.sampleRate)
            Self.log(
                "b",
                "\(label): at the peak-|Δ| frame \(peak.frame) — local amplitude "
                    + "\(amplitude) (plateau nominal 0.8), local f0 \(hz) Hz, "
                    + "sine law predicts \(predicted), observed \(peak.peak), "
                    + "observed/predicted \(peak.peak / predicted)")
        }
        explainPeak(curved, label: "curve")
        explainPeak(flat2, label: "constant-+2")

        for threshold in [-1.0, -3.0] {
            let curveWidth = dipWidth(curved, belowDb: threshold)
            let flatWidth = dipWidth(flat2, belowDb: threshold)
            Self.log(
                "b",
                "dip width at \(threshold) dB below plateau: curve "
                    + "\(curveWidth.frames) frames (\(curveWidth.ms) ms); "
                    + "constant-+2 \(flatWidth.frames) frames (\(flatWidth.ms) ms)")
        }

        #expect(
            curvePeak.peak <= baseline * 1.15,
            """
            E1(b) KILL CRITERION: peak discontinuity across the step \
            (\(curvePeak.peak)) rose above the constant-pitch baseline \
            (\(baseline)). Re-read §2.4 before relaxing this.
            """)
        #expect(
            curveHF.windowMax <= hfBaseline + 6,
            """
            E1(b) KILL CRITERION: broadband energy above 2 kHz across the step \
            reached \(curveHF.windowMax) dB against a constant-render baseline \
            of \(hfBaseline) dB. More than ~6 dB of excess broadband energy is \
            a click, and no ≤30 ms crossfade hides a click that is already \
            inside the crossfade window.
            """)
        #expect(M23QWaveform.isAllFinite(curved))
        #expect(M23QWaveform.peakMagnitude(curved) < 2.0, "no runaway gain")
    }

    /// **The measurement the kill criterion actually turns on.** The 2-semitone
    /// step above is an instantaneous jump far larger than anything a
    /// CORRECTION curve asks for — correction moves a note by tens of cents,
    /// and design §2.2 note 3 predicts the artefact scales with the size of the
    /// map jump. So: the same transition at five sizes, reporting the level dip
    /// (frames at two pitches beat against each other) and the broadband
    /// excess (a click) for each.
    @Test("(b) transition artefacts versus jump size")
    func stepSizeSweep() throws {
        let input = [Self.sine()]
        let flat0 = try OfflineStretcher.stretch(
            input: input, sampleRate: Self.sampleRate, ratio: 1, semitones: 0,
            formantPreserve: false)[0]
        let hop = 1440
        let landing = Self.stepFrame + OfflineStretcher.measuredCurveLatencyFrames
        let window = (landing - 3 * hop)..<(landing + 4 * hop)
        let body = Self.edgeGuardFrames..<(Self.frames - Self.edgeGuardFrames)

        func report(_ signal: [Float]) -> (dipDb: Double, hfDb: Double) {
            let envelope = M23QWaveform.envelope(signal)
            let plateau = envelope.filter { body.contains($0.frame) }
                .map(\.amplitude).sorted()
            let reference = plateau.isEmpty ? 1 : plateau[plateau.count / 2]
            let low = envelope.filter { window.contains($0.frame) }
                .map(\.amplitude).min() ?? reference
            let hf = M23QWaveform.highFrequencyEnergy(
                signal, sampleRate: Self.sampleRate)
                .filter { window.contains($0.frame) }
                .map(\.hfDb).max() ?? -200
            return (20 * log10(max(low, 1e-9) / reference), hf)
        }

        let identity = report(flat0)
        Self.log(
            "b",
            "jump-size sweep, identity render (constant 0 st) for scale: dip "
                + "\(identity.dipDb) dB, HF>2 kHz \(identity.hfDb) dB — note this "
                + "is the BYPASS floor, not the right comparator: a stretcher "
                + "that is actually transposing has a much higher broadband "
                + "floor even at constant pitch, which is why each size below "
                + "is compared against a CONSTANT SHIFT OF THE SAME SIZE.")
        for semitones in [0.1, 0.25, 0.5, 1.0, 2.0] {
            let rendered = try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: Self.sampleRate, ratio: 1,
                curve: [
                    (outputFrame: 0, semitones: 0.0),
                    (outputFrame: Self.stepFrame, semitones: semitones),
                ], formantPreserve: false)[0]
            let constant = try OfflineStretcher.stretch(
                input: input, sampleRate: Self.sampleRate, ratio: 1,
                semitones: semitones, formantPreserve: false)[0]
            let measured = report(rendered)
            let baseline = report(constant)
            // Beat period of the two coexisting pitches, for the doc's arithmetic.
            let beatHz = Self.baseHz * (pow(2, semitones / 12) - 1)
            Self.log(
                "b",
                "jump \(semitones) st (\(semitones * 100) cents, beat "
                    + "\(beatHz) Hz = \(1000 / beatHz) ms period): dip "
                    + "\(measured.dipDb) dB vs constant-\(semitones) baseline "
                    + "\(baseline.dipDb) dB; HF>2 kHz \(measured.hfDb) dB vs "
                    + "baseline \(baseline.hfDb) dB; broadband excess "
                    + "\(measured.hfDb - baseline.hfDb) dB")
            #expect(M23QWaveform.isAllFinite(rendered))
            #expect(
                measured.hfDb <= baseline.hfDb + 6,
                """
                a \(semitones) st jump put \(measured.hfDb - baseline.hfDb) dB \
                of broadband energy above what the same shift held constant \
                produces — that is a click.
                """)
        }

        // The obvious Phase 1 mitigation, measured rather than assumed: the same
        // 2-semitone move spread over three hops instead of taken in one.
        var ramp: [(outputFrame: Int, semitones: Double)] = [(0, 0.0)]
        for hopIndex in 1...3 {
            ramp.append(
                (outputFrame: Self.stepFrame + (hopIndex - 1) * hop,
                 semitones: 2.0 * Double(hopIndex) / 3))
        }
        let ramped = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: Self.sampleRate, ratio: 1, curve: ramp,
            formantPreserve: false)[0]
        let rampedReport = report(ramped)
        let constantTwo = try OfflineStretcher.stretch(
            input: input, sampleRate: Self.sampleRate, ratio: 1, semitones: 2,
            formantPreserve: false)[0]
        Self.log(
            "b",
            "2 st taken over 3 hops (90 ms) instead of one: dip "
                + "\(rampedReport.dipDb) dB, HF>2 kHz \(rampedReport.hfDb) dB "
                + "(constant-2 baseline \(report(constantTwo).dipDb) / "
                + "\(report(constantTwo).hfDb) dB)")
        #expect(M23QWaveform.isAllFinite(ramped))
    }

    /// A side finding leg (a) turned up and the shipping path has never been
    /// asserted against: how accurately does a CONSTANT +2 semitone request
    /// come out? `OfflineStretcherTests` checks pitch by zero-crossing rate
    /// within ±3 % (≈±52 cents), which is far too loose to see this, and a
    /// pitch CORRECTOR that trusts the setter inherits whatever bias is here.
    @Test("constant-shift pitch accuracy, in cents")
    func constantShiftPitchAccuracy() throws {
        let input = [Self.sine()]
        for semitones in [0.0, 2.0, -2.0] {
            let rendered = try OfflineStretcher.stretch(
                input: input, sampleRate: Self.sampleRate, ratio: 1,
                semitones: semitones, formantPreserve: false)[0]
            let expected = Self.baseHz * pow(2, semitones / 12)
            let estimates = M23QToneTracker.track(
                rendered, sampleRate: Self.sampleRate,
                band: (expected * 0.7)...(expected * 1.4))
            let median = try #require(
                M23QToneTracker.medianHz(
                    estimates,
                    centreIn: Double(Self.edgeGuardFrames)
                        ..< Double(Self.frames - Self.edgeGuardFrames)))
            let error = M23QToneTracker.cents(median, above: expected)
            Self.log(
                "pitch",
                "constant \(semitones) st: expected \(expected) Hz, measured "
                    + "\(median) Hz, error \(error) cents")
            #expect(abs(error) < 25, "constant shift is \(error) cents off at \(semitones) st")
        }
    }

    // MARK: - (c) vibrato resolution

    /// f0 tracking error for a 5 Hz ±50-cent curve, reported against the
    /// instrument's own floor on the same modulation.
    @Test("(c) a 5 Hz ±50-cent curve is tracked within the hop's resolution")
    func vibratoResolution() throws {
        let input = [Self.sine()]
        var curve: [(outputFrame: Int, semitones: Double)] = []
        curve.reserveCapacity(Self.frames / 64 + 1)
        for frame in stride(from: 0, to: Self.frames, by: 64) {
            curve.append(
                (outputFrame: frame,
                 semitones: M23QSignal.vibratoCents(
                    depthCents: 50, rateHz: 5, frame: frame,
                    sampleRate: Self.sampleRate) / 100))
        }
        let rendered = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: Self.sampleRate, ratio: 1, curve: curve,
            formantPreserve: false)[0]

        let floorSignal = M23QSignal.vibratoSine(
            baseHz: Self.baseHz, depthCents: 50, rateHz: 5, frames: Self.frames,
            sampleRate: Self.sampleRate, amplitude: Self.amplitude)
        let floor = Self.vibratoError(floorSignal, offsetFrames: 0)
        let measured = Self.vibratoError(
            rendered, offsetFrames: OfflineStretcher.measuredCurveLatencyFrames)

        Self.log(
            "c",
            "stretcher: rms \(measured.rmsCents) c (vs ideal delayed "
                + "\(OfflineStretcher.measuredCurveLatencyFrames) frames), "
                + "max \(measured.maxCents) c, peak-to-peak depth "
                + "\(measured.peakToPeakDepthCents) c, fitted depth "
                + "\(measured.fittedDepthCents) c of 50 requested, fitted lag "
                + "\(measured.fittedLagFrames) frames "
                + "(\(measured.fittedLagFrames / Self.sampleRate * 1000) ms), "
                + "non-sinusoidal rms \(measured.nonSinusoidalRMSCents) c")
        Self.log(
            "c",
            "instrument floor: rms \(floor.rmsCents) c, max \(floor.maxCents) c, "
                + "peak-to-peak depth \(floor.peakToPeakDepthCents) c, fitted depth "
                + "\(floor.fittedDepthCents) c, fitted lag \(floor.fittedLagFrames), "
                + "non-sinusoidal rms \(floor.nonSinusoidalRMSCents) c")
        Self.log(
            "c",
            "excess over floor: rms \(measured.rmsCents - floor.rmsCents) c, "
                + "fitted-depth shortfall \(floor.fittedDepthCents - measured.fittedDepthCents) c, "
                + "non-sinusoidal excess "
                + "\(measured.nonSinusoidalRMSCents - floor.nonSinusoidalRMSCents) c, "
                + "lag difference \(measured.fittedLagFrames - floor.fittedLagFrames) frames")

        #expect(measured.rmsCents < 25.0)
        #expect(measured.fittedDepthCents > 30)
        #expect(M23QWaveform.isAllFinite(rendered))
    }

    /// The 5 Hz leg above measures a depth GAIN, not a loss — the tracked
    /// excursion comes back bigger than the one requested. A single rate cannot
    /// say whether that is a static nonlinearity of the transposer or a
    /// rate-dependent emphasis of the 30 ms staircase, and the two have
    /// opposite implications for vibrato SHAPING. So: the same measurement at
    /// three rates.
    @Test("(c) depth gain and lag versus modulation rate")
    func vibratoRateSweep() throws {
        let input = [Self.sine()]
        for rate in [1.0, 5.0, 8.0] {
            var curve: [(outputFrame: Int, semitones: Double)] = []
            for frame in stride(from: 0, to: Self.frames, by: 64) {
                curve.append(
                    (outputFrame: frame,
                     semitones: M23QSignal.vibratoCents(
                        depthCents: 50, rateHz: rate, frame: frame,
                        sampleRate: Self.sampleRate) / 100))
            }
            let rendered = try OfflineStretcher.stretchTransposeCurve(
                input: input, sampleRate: Self.sampleRate, ratio: 1, curve: curve,
                formantPreserve: false)[0]
            let floorSignal = M23QSignal.vibratoSine(
                baseHz: Self.baseHz, depthCents: 50, rateHz: rate,
                frames: Self.frames, sampleRate: Self.sampleRate,
                amplitude: Self.amplitude)
            let floor = Self.vibratoError(
                floorSignal, offsetFrames: 0, rateHz: rate)
            let measured = Self.vibratoError(
                rendered, offsetFrames: OfflineStretcher.measuredCurveLatencyFrames,
                rateHz: rate)
            let updatesPerCycle = Self.sampleRate / 1440 / rate
            Self.log(
                "c",
                "rate \(rate) Hz (\(updatesPerCycle) hop updates per cycle): "
                    + "fitted depth \(measured.fittedDepthCents) c of 50 → gain "
                    + "\(measured.fittedDepthCents / 50); instrument reads the "
                    + "same modulation as \(floor.fittedDepthCents) c (gain "
                    + "\(floor.fittedDepthCents / 50)); corrected gain "
                    + "\(measured.fittedDepthCents / floor.fittedDepthCents); lag "
                    + "\(measured.fittedLagFrames) frames; non-sinusoidal rms "
                    + "\(measured.nonSinusoidalRMSCents) c (floor "
                    + "\(floor.nonSinusoidalRMSCents) c)")
            #expect(M23QWaveform.isAllFinite(rendered))
            #expect(measured.fittedDepthCents > 25)
        }
    }

    // MARK: - E2 by-product

    /// The comparison-pair renderer, round-tripped through disk on synthetic
    /// input so it cannot rot before a real dry vocal exists. E2 itself is NOT
    /// run here: a formant-less sine says nothing about formant wobble.
    @Test("E2 by-product: the comparison-pair renderer round-trips")
    func comparisonPairRenders() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23q-e1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.wav")
        try M23QComparisonPair.writeWAV(
            [Self.sine()], sampleRate: Self.sampleRate, to: sourceURL)

        let pair = try M23QComparisonPair.render(
            sourceURL: sourceURL, outputDirectory: directory,
            constantSemitones: 2,
            curve: [
                (outputFrame: 0, semitones: 0.0),
                (outputFrame: Self.stepFrame, semitones: 2.0),
            ],
            formantPreserve: true)

        #expect(FileManager.default.fileExists(atPath: pair.constantURL.path))
        #expect(FileManager.default.fileExists(atPath: pair.curveURL.path))
        #expect(pair.constant[0].count == Self.frames)
        #expect(pair.curve[0].count == Self.frames)
        #expect(M23QWaveform.isAllFinite(pair.constant[0]))
        #expect(M23QWaveform.isAllFinite(pair.curve[0]))
        // The two must actually differ — otherwise the "pair" is one render.
        #expect(
            Self.differingSamples(pair.constant[0], pair.curve[0])
                > Self.frames / 4)
        Self.log(
            "e2",
            "pair written: \(pair.constantURL.lastPathComponent) / "
                + "\(pair.curveURL.lastPathComponent) at \(pair.sampleRate) Hz")
    }

    // MARK: - Shared measurement plumbing

    static func differingSamples(_ a: [Float], _ b: [Float]) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) }
        var count = 0
        for index in a.indices where a[index].bitPattern != b[index].bitPattern {
            count += 1
        }
        return count
    }

    struct StepProfile {
        let lowHz: Double
        let highHz: Double
        /// Frames at which the tracked f0 has completed 10 / 50 / 90 % of the
        /// journey between the two plateaus.
        let f10: Double
        let f50: Double
        let f90: Double
        /// f90 − f10: how long the pitch takes to move. A phase vocoder cannot
        /// change pitch instantaneously — the analysis block is 120 ms — so
        /// this width is expected to be substantial, and reporting a single
        /// crossing frame without it would overstate the precision of leg (a).
        var widthFrames: Double { f90 - f10 }
    }

    /// Locates a 0 → +2 semitone transition by tracking f0 and finding where it
    /// crosses 10/50/90 % of the way between the two plateaus. The plateaus are
    /// read from the signal itself rather than assumed, so a render whose
    /// absolute pitch is slightly off still yields a valid transition time.
    static func measuredStepProfile(_ signal: [Float]) throws -> StepProfile {
        let estimates = M23QToneTracker.track(signal, sampleRate: sampleRate)
        let low = try #require(
            M23QToneTracker.medianHz(
                estimates,
                centreIn: Double(edgeGuardFrames)
                    ..< Double(stepFrame - edgeGuardFrames)))
        let high = try #require(
            M23QToneTracker.medianHz(
                estimates,
                centreIn: Double(stepFrame + 3 * edgeGuardFrames)
                    ..< Double(frames - edgeGuardFrames)))
        func crossing(_ fraction: Double) throws -> Double {
            let threshold = low + (high - low) * fraction
            return try #require(
                M23QToneTracker.upwardCrossingFrame(
                    estimates, threshold: threshold),
                "no upward crossing of \(threshold) Hz (plateaus \(low) / \(high))")
        }
        return StepProfile(
            lowHz: low, highHz: high, f10: try crossing(0.1),
            f50: try crossing(0.5), f90: try crossing(0.9))
    }

    struct VibratoResult {
        /// RMS / max error against the requested contour delayed by
        /// `offsetFrames`. Sensitive to any residual timing error, which is why
        /// the lag-independent numbers below exist beside it.
        let rmsCents: Double
        let maxCents: Double
        /// Half the peak-to-peak excursion of the tracked contour.
        let peakToPeakDepthCents: Double
        /// Amplitude of the fitted 5 Hz component — the depth measure that a
        /// single ringing sample cannot inflate.
        let fittedDepthCents: Double
        /// Lag of the fitted 5 Hz component, in frames. An independent read of
        /// the same latency leg (a) measures from a step.
        let fittedLagFrames: Double
        /// RMS of everything that is NOT the fitted 5 Hz sinusoid: staircase
        /// edges, ringing, tracker noise. This is the number that says whether
        /// a 30 ms hop can carry a 5 Hz contour, independent of timing.
        let nonSinusoidalRMSCents: Double
    }

    /// Tracking error for the 5 Hz ±50-cent contour. `offsetFrames` (leg (a)'s
    /// measured latency) shifts the ideal so a pure alignment offset is not
    /// reported as a tracking failure; the fitted numbers do not depend on it
    /// at all.
    static func vibratoError(
        _ signal: [Float], offsetFrames: Int, rateHz: Double = 5,
        depthCents: Double = 50
    ) -> VibratoResult {
        let estimates = M23QToneTracker.track(signal, sampleRate: sampleRate)
        var sumSquares = 0.0
        var maxError = 0.0
        var minCents = Double.greatestFiniteMagnitude
        var maxCents = -Double.greatestFiniteMagnitude
        var count = 0
        var series: [(frame: Double, value: Double)] = []
        for estimate in estimates {
            let frame = estimate.centreFrame
            guard frame >= Double(edgeGuardFrames),
                frame < Double(frames - edgeGuardFrames)
            else { continue }
            let ideal = M23QSignal.vibratoCents(
                depthCents: depthCents, rateHz: rateHz,
                frame: Int(frame.rounded()) - offsetFrames,
                sampleRate: sampleRate)
            let actual = M23QToneTracker.cents(estimate.hz, above: baseHz)
            let error = actual - ideal
            sumSquares += error * error
            maxError = max(maxError, abs(error))
            minCents = min(minCents, actual)
            maxCents = max(maxCents, actual)
            series.append((frame: frame, value: actual))
            count += 1
        }
        guard count > 0 else {
            return VibratoResult(
                rmsCents: .nan, maxCents: .nan, peakToPeakDepthCents: .nan,
                fittedDepthCents: .nan, fittedLagFrames: .nan,
                nonSinusoidalRMSCents: .nan)
        }
        // Fit over a WHOLE number of modulation cycles. A partial cycle biases
        // both the amplitude and the phase of a one-bin DFT, and at 1 Hz the
        // usable body is only ~2.7 cycles — enough to make the weakest row of
        // the rate sweep look like a disagreement between instruments.
        let period = sampleRate / rateHz
        let span = (series.last?.frame ?? 0) - (series.first?.frame ?? 0)
        let wholeCycles = (span / period).rounded(.down)
        let fitEnd = (series.first?.frame ?? 0) + wholeCycles * period
        let fitted = wholeCycles >= 1 ? series.filter { $0.frame < fitEnd } : series
        let fit = M23QToneTracker.fitSinusoid(
            fitted, rateHz: rateHz, sampleRate: sampleRate)
        return VibratoResult(
            rmsCents: (sumSquares / Double(count)).squareRoot(),
            maxCents: maxError,
            peakToPeakDepthCents: (maxCents - minCents) / 2,
            fittedDepthCents: fit?.amplitude ?? .nan,
            fittedLagFrames: fit?.lagFrames ?? .nan,
            nonSinusoidalRMSCents: fit?.residualRMS ?? .nan)
    }
}
