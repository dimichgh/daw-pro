import AVFAudio
import CSignalsmithStretch
import Foundation

/// Errors from the offline stretch facade.
public enum OfflineStretcherError: Error, Equatable, Sendable {
    /// The caller's `isCancelled` closure returned true between blocks.
    case cancelled
    case invalidInput(String)
    case unsupportedFormat(String)
    case allocationFailed
}

/// Pure offline time-stretch / pitch-shift facade over the vendored
/// signalsmith-stretch library (M5 ii-b). Stateless, main-actor-free, pure
/// computation — call it from a detached task. NOT the cache/job model (that
/// is ii-d, `StretchRenderCache`); this converts one buffer into another and
/// nothing else. Never call on the render thread: it allocates freely.
///
/// Alignment contract: output frame 0 corresponds to input frame 0 and the
/// output is exactly `round(inputFrames × ratio)` frames — the upstream
/// `exact()` recipe (`outputSeek` → chunked `process` → `flush`), with the
/// seek length derived from the shim's latency accessors:
/// `seekLength = inputLatency + outputLatency/ratio`. The `outputSeek`
/// pre-roll means no output trimming is needed afterwards.
///
/// Determinism: the stretcher's phase-randomisation RNG is seeded with a
/// fixed constant (upstream's default constructor seeds from
/// `std::random_device`, which we deliberately bypass), so identical inputs
/// and parameters produce bit-identical output — renders are cacheable by
/// parameter key (ii-d) and null-testable.
public enum OfflineStretcher {
    /// Output frames processed per block; the cancellation closure is checked
    /// once per block.
    public static let blockFrames = 4096

    /// Upstream-recommended tonality limit: harmonics below this stay
    /// phase-coherent under transposition (signalsmith's own CLI default).
    static let tonalityLimitHz: Float = 8000

    /// Fixed RNG seed for reproducible renders (see type docs).
    static let rngSeed: Int64 = 0x51_6E_57_e7

    /// The exact-identity predicate the ii-d bypass contract consumes: true
    /// ONLY for exactly (ratio: 1.0, semitones: 0.0). Callers (the render
    /// cache) must never invoke `stretch` for identity parameters — identity
    /// clips play the original file byte-for-byte (the seam's null-test
    /// guarantee). `formantPreserve` is deliberately not a parameter:
    /// formant preservation without a pitch shift is also identity.
    public static func isIdentity(ratio: Double, semitones: Double) -> Bool {
        ratio == 1.0 && semitones == 0.0
    }

    /// Stretches planar float32 audio by `ratio` (output duration multiplier:
    /// 2.0 = twice as long / half speed) and pitch-shifts by `semitones`,
    /// optionally preserving formants. `isCancelled` is polled between
    /// blocks; returning true aborts promptly with `.cancelled`.
    ///
    /// Returns planar channels of exactly `round(inputFrames × ratio)`
    /// frames, aligned to input frame 0.
    public static func stretch(
        input: [[Float]],
        sampleRate: Double,
        ratio: Double,
        semitones: Double,
        formantPreserve: Bool,
        isCancelled: () -> Bool = { false }
    ) throws -> [[Float]] {
        try constantLoop(.whole(input), sampleRate: sampleRate, ratio: ratio,
                         semitones: semitones, formantPreserve: formantPreserve,
                         isCancelled: isCancelled).planar
    }

    /// **I1-F1: THE SECOND ENTRY into the constant loop below**: one WINDOW
    /// of the whole-file render `stretch(input:…)` makes of the same source,
    /// in the whole-file render's output frames. Not a copy of the loop; the
    /// loop, and the schedule it runs on, are the same code (`constantLoop`,
    /// `StretchSchedule`). See `StretchWindow` for what a window can and cannot
    /// reproduce.
    static func stretch(
        window: StretchWindow,
        sampleRate: Double,
        ratio: Double,
        semitones: Double,
        formantPreserve: Bool,
        isCancelled: () -> Bool = { false }
    ) throws -> StretchWindowOutput {
        try constantLoop(.window(window), sampleRate: sampleRate, ratio: ratio,
                         semitones: semitones, formantPreserve: formantPreserve,
                         isCancelled: isCancelled)
    }

    /// THE constant-transpose loop, for both entries.
    private static func constantLoop(
        _ source: StretchSource,
        sampleRate: Double,
        ratio: Double,
        semitones: Double,
        formantPreserve: Bool,
        isCancelled: () -> Bool
    ) throws -> StretchWindowOutput {
        let (channels, frames) = try source.validatedShape()
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw OfflineStretcherError.invalidInput("bad sample rate \(sampleRate)")
        }
        guard ratio.isFinite, ratio > 0 else {
            throw OfflineStretcherError.invalidInput("bad ratio \(ratio)")
        }
        guard semitones.isFinite else {
            throw OfflineStretcherError.invalidInput("bad semitones \(semitones)")
        }
        let outputFrames = Int((Double(frames) * ratio).rounded())
        guard outputFrames >= 1 else {
            throw OfflineStretcherError.invalidInput("output would be empty")
        }
        StretchLoopTrace.current?.record(.constant, source.entry)

        guard let handle = css_create(Int32(channels), Float(sampleRate), rngSeed) else {
            throw OfflineStretcherError.allocationFailed
        }
        defer { css_destroy(handle) }
        css_set_transpose_semitones(handle, Float(semitones), tonalityLimitHz)
        css_set_formant_preserve(handle, formantPreserve)

        // Upstream `outputSeekLength(1/ratio)`, truncation and all. The
        // outputSeek consumes this many head frames and leaves the delivered
        // output aligned to input frame 0 (of the window, for a window).
        let schedule = StretchSchedule(
            sourceFrames: frames, ratio: ratio,
            inputLatency: Int(css_input_latency(handle)),
            outputLatency: Int(css_output_latency(handle)),
            blockFrames: blockFrames)
        let span = schedule.span(for: source)

        // Working copies: input padded with silence to at least seekLength
        // (sub-latency-sized sources are legal, just smeared), output sized
        // exactly. Manual allocation gives the C shim stable base pointers.
        let io = try StretchBuffers(source: source, channels: channels, schedule: schedule,
                                    span: span)
        defer { io.deallocate() }

        // 1. Align (consumes input[start..<start + seekLength], produces the
        //    pre-roll internally).
        io.withInPointers(atSourceFrame: span.inputStart) {
            css_output_seek(handle, $0, Int32(schedule.seekLength))
        }

        // 2. Chunked middle: the remaining input maps onto the output before
        //    the flush tail; cumulative targets keep the average per-call
        //    out/in ratio exact (upstream: block splits "work just the same").
        var outDone = span.startOutputFrame
        var inDone = span.inputStart
        while outDone < span.loopEndOutputFrame {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            let outBlock = min(blockFrames, schedule.processOut - outDone)
            let inTarget = schedule.inputTarget(afterOutputFrame: outDone + outBlock)
            let inBlock = inTarget - inDone
            io.withInPointers(atSourceFrame: schedule.seekLength + inDone) { inPtrs in
                io.withOutPointers(atOutputFrame: outDone) { outPtrs in
                    css_process(
                        handle, inPtrs, Int32(inBlock), outPtrs, Int32(outBlock))
                }
            }
            outDone += outBlock
            inDone = inTarget
        }

        // 3. Drain the synthesis tail (click-free ending, no more input).
        if isCancelled() { throw OfflineStretcherError.cancelled }
        if span.flushes {
            let flushFrames = outputFrames - outDone
            if flushFrames > 0 {
                io.withOutPointers(atOutputFrame: outDone) {
                    css_flush(handle, $0, Int32(flushFrames), schedule.playbackRate)
                }
            }
        }

        return io.output(span)
    }

    // MARK: - m23-q: time-varying transpose (E1 measured it, Phase 1 ships it)

    /// **MEASURED, not chosen** (m23-q E1(a), 2026-08-17, 48 kHz, this exact
    /// vendored build): a transpose value handed to
    /// `stretchTransposeCurve` for output frame F appears in the delivered
    /// output centred **2379 frames (49.56 ms) later**, on top of any hop
    /// quantisation. Method: a 220 Hz sine, a 0 → +2 semitone step requested at
    /// a hop-aligned frame, f0 tracked by phase-difference FFT; the 50 % point
    /// of the transition landed at +2378.94 frames after subtracting the
    /// tracker's own −1.22-frame bias (measured on a synthetic hard step).
    /// Independent corroboration, sharing no machinery with the step beyond the
    /// tracker itself: the vibrato leg's fitted phase lag, over a whole number
    /// of modulation cycles, reads **2170.6 / 2285.7 / 2349.0 frames at
    /// 1 / 5 / 8 Hz** — a 208-frame (4.3 ms) spread around the step's 2378.94,
    /// with the rate dependence itself consistent with the transition taking
    /// ≈712 frames to complete. All three are quoted rather than the closest
    /// one, which would overstate the agreement.
    ///
    /// It is NOT `css_output_latency` (2880 frames / 60 ms) — design §2.3
    /// derived ≈60 ms and flagged that the `outputSeek` recipe might make the
    /// input and output latencies partly cancel. They partly do: the measured
    /// figure is 501 frames short of the derived one. That §2.3 caveat is the
    /// reason this is a measurement and not an arithmetic constant.
    ///
    /// Two terms sit on top of it and are NOT included here, because they
    /// depend on the caller's curve rather than on the library:
    ///   * hop quantisation — the curve is read once per chunk, so a request
    ///     landing mid-hop waits 0…1439 frames (measured exactly one hop by
    ///     `curveQuantisesToTheHop`);
    ///   * transition width — the pitch ramps over ≈712 frames (14.8 ms)
    ///     10 %→90 % as seen by a 21 ms tracker, not instantly.
    ///
    /// E1 measured the RAW path and compensated for nothing; `m23-q` Phase 1
    /// (this item) compensates, through `CurveLatencyCompensation` below —
    /// which is the ONLY consumer of this constant, so the number and the code
    /// cannot drift apart without `curveLookupFrame` changing with them.
    static let measuredCurveLatencyFrames = 2379

    /// The sample rate `measuredCurveLatencyFrames` was measured at. Quoted
    /// separately because the constant is a FRAME count, and frames are not a
    /// rate-independent unit.
    static let measuredCurveLatencySampleRate: Double = 48_000

    /// How the curve is aligned against the DELIVERED output. Two cases, and
    /// the distinction is a measurement one rather than a preference:
    ///
    ///  * `.none` — index the curve naively against the output write cursor.
    ///    **This is the phase-0 EXPERIMENT path**, and it must stay reachable:
    ///    E1(a) measures `measuredCurveLatencyFrames` with it, and a
    ///    compensated render would measure its own correction.
    ///  * `.frames(n)` — the SHIPPING path: read the curve `n` delivered
    ///    frames ahead, so a value asked for at output frame F is handed to the
    ///    stretcher early enough to arrive AT F.
    enum CurveLatencyCompensation: Equatable, Sendable {
        case none
        case frames(Int)
    }

    /// The compensation for a render at `sampleRate`.
    ///
    /// ⚠️ **MEASURED AT 48 kHz, SCALED TO OTHER RATES — and the scaling is a
    /// STRUCTURAL argument plus one corroborating measurement, not a
    /// coincidence.** Every window in this stretcher is defined in
    /// MILLISECONDS: `presetDefault` hands `configure` `sampleRate*0.12`
    /// (block) and `sampleRate*0.03` (hop), so the latency a 48 kHz render
    /// shows in FRAMES must scale with the rate to stay the same duration.
    /// `PitchCurveRenderTests.compensationHoldsAt44k` renders the same step at
    /// 44 100 Hz and checks the landing, so the extrapolation is gated rather
    /// than assumed.
    static func curveLatencyCompensation(sampleRate: Double) -> CurveLatencyCompensation {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return .frames(measuredCurveLatencyFrames)
        }
        let scaled = (Double(measuredCurveLatencyFrames) * sampleRate
            / measuredCurveLatencySampleRate).rounded()
        return .frames(Int(scaled))
    }

    /// **The curve loop's schedule for a source of this shape** (I1-F1, R2/R4
    /// of the incremental-note-render design): the block grid and every input
    /// target the whole-file curve render runs on, built by the SAME
    /// `StretchSchedule` initialiser the loop calls, from a stretcher configured
    /// exactly as the loop configures one (hop and latencies READ from it,
    /// never derived). Creates and destroys one stretcher: call it off the main
    /// actor if called often.
    static func curveSchedule(sourceFrames: Int, channels: Int, sampleRate: Double,
                              ratio: Double) throws -> StretchSchedule {
        guard channels >= 1, sourceFrames >= 1, sampleRate.isFinite, sampleRate > 0,
              ratio.isFinite, ratio > 0 else {
            throw OfflineStretcherError.invalidInput(
                "bad shape: \(channels) ch, \(sourceFrames) frames, \(sampleRate) Hz, ratio \(ratio)")
        }
        guard let handle = css_create(Int32(channels), Float(sampleRate), rngSeed) else {
            throw OfflineStretcherError.allocationFailed
        }
        defer { css_destroy(handle) }
        let interval = Int(css_interval_samples(handle))
        guard interval >= 1 else {
            throw OfflineStretcherError.invalidInput(
                "stretcher reported non-positive interval \(interval)")
        }
        return StretchSchedule(sourceFrames: sourceFrames, ratio: ratio,
                               inputLatency: Int(css_input_latency(handle)),
                               outputLatency: Int(css_output_latency(handle)),
                               blockFrames: interval)
    }

    /// **THE ONE PLACE THE COMPENSATION ARITHMETIC LIVES**, so a test can spy
    /// on exactly what the render loop does rather than on a copy of it.
    ///
    /// The chunk that begins at delivered frame `outputFrame` governs the
    /// delivered window `[outputFrame + n, outputFrame + n + interval)`, whose
    /// CENTRE is `outputFrame + n + interval/2`. Reading the curve at the
    /// window's centre rather than at its start is what makes the residual
    /// error symmetric instead of 0…+1 hop LATE on top of the latency just
    /// removed. DERIVED, not measured, and marked as such: a hop-aligned
    /// request at 72 000 is first served by the chunk at 70 560 under
    /// start-sampling (landing 72 939, 939 LATE) and by the chunk at 69 120
    /// under centre-sampling (landing 71 499, 501 early).
    ///
    /// What IS measured is the result. Sweeping a request across one whole hop
    /// with a HARD step, the compensated landing is unbiased — residuals
    /// −500 / +581 / +221 / −139 frames, mean +41 (+0.85 ms) — against +50 ms
    /// LATE uncompensated. The ±half-hop spread is IRREDUCIBLE at a 30 ms hop
    /// and is the same limit that puts the floor under `PitchEditSet.retuneMs`.
    /// Driven by a real 30 ms `PitchEditSet` ramp the same sweep sits ~8-10 ms
    /// early on average; that bias is the RAMP meeting the hop grid, not this
    /// arithmetic, and `PitchCurveRenderTests`' landing budget records both
    /// sweeps and the discriminator between them.
    static func curveLookupFrame(outputFrame: Int,
                                 compensation: CurveLatencyCompensation,
                                 intervalSamples: Int) -> Int {
        switch compensation {
        case .none:
            return outputFrame
        case .frames(let latency):
            return outputFrame + latency + intervalSamples / 2
        }
    }

    /// **Natural tuning §1(b): THE PER-HOP FORMANT CURVE**, the second thing
    /// the curve loop hands the stretcher once per chunk, beside the transpose.
    /// Built by `StretchCurvePlan.formantCurve(formantPreserve:)` and ONLY for
    /// a set that `engagesFormantCurve`; `nil` everywhere else, and `nil` IS
    /// TODAY'S LOOP, byte for byte.
    ///
    /// ONE optional carrying BOTH closures, rather than the design's two
    /// optional closures: a render that set the shift and left the base to
    /// signalsmith's estimator (or the reverse) is a state this type cannot
    /// represent.
    ///
    /// Both closures are asked for WHOLE-FILE delivered output frames at
    /// `curveLookupFrame` (the transpose's own lookup, so a formant change
    /// lands with the pitch change it belongs to), may be asked past the end
    /// of the render, and must be TOTAL: a non-finite shift or a base ≤ 0
    /// would reach the shim. The plan's closures are (the DAWCore evaluators
    /// return the clip term and a ≥ 50 Hz floor).
    struct FormantCurve {
        /// Formant shift in semitones RELATIVE TO THE SOURCE ENVELOPE (the
        /// shim's `compensatePitch = true`): 0 keeps the singer's envelope.
        let semitonesAtOutputFrame: (Int) -> Double
        /// The f0 hint in Hz. Never ≤ 0: 0 would hand signalsmith its own
        /// estimator, whose cross-block IIR a window render cannot reproduce.
        let baseHzAtOutputFrame: (Int) -> Double
    }

    /// Hands the stretcher both formant values for the chunk whose curve
    /// lookup frame is `lookupFrame`. The ONE place the engaged branch talks
    /// to the shim, for the pre-roll and for every chunk alike.
    private static func applyFormant(_ formant: FormantCurve, to handle: OpaquePointer,
                                     lookupFrame: Int) {
        css_set_formant_semitones(
            handle, Float(formant.semitonesAtOutputFrame(lookupFrame)), true)
        css_set_formant_base_hz(handle, Float(formant.baseHzAtOutputFrame(lookupFrame)))
    }

    /// The step value of a transpose curve at an output frame. Sample-and-hold:
    /// the value in effect at `frame` is the last breakpoint at or before it,
    /// and the first breakpoint's value extends backwards to output frame 0.
    /// No interpolation — the hop grid quantises the curve anyway
    /// (design §2.2 note 4), and interpolation is a Phase 1 decision.
    /// `curve` must be sorted ascending by `outputFrame`; the caller's
    /// entry point validates that.
    static func transposeCurveValue(
        _ curve: [(outputFrame: Int, semitones: Double)], at frame: Int
    ) -> Double {
        guard let first = curve.first else { return 0 }
        var value = first.semitones
        for point in curve {
            if point.outputFrame > frame { break }
            value = point.semitones
        }
        return value
    }

    /// **m23-q: the time-varying transpose path.** Phase 0 built it as an
    /// experiment surface; Phase 1 (this item) ships it — `StretchRenderCache`
    /// renders a clip's `pitchEdits` through the closure core below, with
    /// `compensation: .frames(…)`. The phase-0 legs still drive THIS entry
    /// point with `.none`, which is why the compensation is a parameter rather
    /// than a constant folded into the loop. Renders with a *time-varying*
    /// transpose: `css_set_transpose_semitones` is called
    /// between `css_process` calls, and the chunk is exactly the stretcher's
    /// own hop (`css_interval_samples`, measured not derived) so the curve
    /// resolves per analysis block. The 4096-frame chunk of `stretch(...)`
    /// spans ~2.8 hops at 48 k and would throw that resolution away.
    ///
    /// This is a deliberate near-duplicate of `stretch(...)` rather than a
    /// refactor of it: `stretch` is live in `StretchRenderCache` and must stay
    /// byte-for-byte identical while Phase 0 decides whether the curve path
    /// survives at all. The E1(d) equivalence legs
    /// (`OfflineStretcherCurveTests`) are the guard against the two copies
    /// drifting — a constant curve must be bit-identical to the constant call.
    ///
    /// **Latency compensation is the caller's explicit choice**, and it
    /// DEFAULTS TO `.none` so the phase-0 measurement legs keep measuring the
    /// raw path: the curve is indexed naively against the output write cursor,
    /// upstream centres a parameter change at the *processing time* which
    /// leads the delivered output, and anything that pre-shifted the curve by
    /// default would make E1(a) measure its own correction. The SHIPPING path
    /// (`StretchRenderCache.performRender`) passes
    /// `curveLatencyCompensation(sampleRate:)`.
    ///
    /// `curve` is `(outputFrame, semitones)` breakpoints in DELIVERED output
    /// frames, sorted ascending, non-empty. Returns exactly
    /// `round(inputFrames × ratio)` frames, aligned to input frame 0 — the same
    /// contract as `stretch(...)`.
    static func stretchTransposeCurve(
        input: [[Float]],
        sampleRate: Double,
        ratio: Double,
        curve: [(outputFrame: Int, semitones: Double)],
        formantPreserve: Bool,
        compensation: CurveLatencyCompensation = .none,
        isCancelled: () -> Bool = { false }
    ) throws -> [[Float]] {
        guard !curve.isEmpty else {
            throw OfflineStretcherError.invalidInput("empty curve")
        }
        guard curve.allSatisfy({ $0.semitones.isFinite }) else {
            throw OfflineStretcherError.invalidInput("non-finite semitones in curve")
        }
        guard zip(curve, curve.dropFirst()).allSatisfy({ $0.outputFrame <= $1.outputFrame })
        else {
            throw OfflineStretcherError.invalidInput("curve not sorted by outputFrame")
        }
        return try stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: ratio,
            semitonesAtOutputFrame: { transposeCurveValue(curve, at: $0) },
            formantPreserve: formantPreserve, compensation: compensation,
            isCancelled: isCancelled)
    }

    /// The core of the curve path: the transpose at a delivered output frame
    /// comes from a CLOSURE rather than a breakpoint array, so a caller with a
    /// continuous curve (`PitchCorrectionCurve`, via `StretchCurvePlan`) does
    /// not have to materialise one breakpoint per hop for a five-minute vocal
    /// and then quantise twice — once onto its own grid and again onto the
    /// stretcher's hop. The array entry point above is implemented on top of
    /// this one, so both paths run the SAME loop and the E1(d) equivalence
    /// legs cover both.
    ///
    /// `semitonesAtOutputFrame` is called once per hop with a frame index that
    /// may be past the end of the render (that is what the lookahead IS) and
    /// must be total: it is sampled, never interpolated, and a non-finite
    /// return would reach `css_set_transpose_semitones`.
    ///
    /// Natural tuning §1(b): `formant` is the per-hop formant curve
    /// (`FormantCurve`), `nil` by default and for every legacy set, and then
    /// the loop is today's, byte for byte. When it is non-nil,
    /// `formantPreserve` is NOT sent to the stretcher: the curve already
    /// carries the clip's flag (the plan builds it with the flag).
    static func stretchTransposeCurve(
        input: [[Float]],
        sampleRate: Double,
        ratio: Double,
        semitonesAtOutputFrame: (Int) -> Double,
        formantPreserve: Bool,
        formant: FormantCurve? = nil,
        compensation: CurveLatencyCompensation = .none,
        isCancelled: () -> Bool = { false }
    ) throws -> [[Float]] {
        try curveLoop(.whole(input), sampleRate: sampleRate, ratio: ratio,
                      semitonesAtOutputFrame: semitonesAtOutputFrame,
                      formantPreserve: formantPreserve, formant: formant,
                      compensation: compensation, isCancelled: isCancelled).planar
    }

    /// **I1-F1: THE SECOND ENTRY into the curve loop below**: one WINDOW of
    /// the whole-file render the closure entry above makes of the same source.
    /// `semitonesAtOutputFrame` is asked for WHOLE-FILE output frames, exactly
    /// as the whole-file render asks it (the window's frames ARE whole-file
    /// frames), so a caller hands both entries the same closure. Not a copy of
    /// the loop: see `StretchWindow`. `formant` likewise: the SAME curve as the
    /// whole-file render's, asked for whole-file frames.
    static func stretchTransposeCurve(
        window: StretchWindow,
        sampleRate: Double,
        ratio: Double,
        semitonesAtOutputFrame: (Int) -> Double,
        formantPreserve: Bool,
        formant: FormantCurve? = nil,
        compensation: CurveLatencyCompensation = .none,
        isCancelled: () -> Bool = { false }
    ) throws -> StretchWindowOutput {
        try curveLoop(.window(window), sampleRate: sampleRate, ratio: ratio,
                      semitonesAtOutputFrame: semitonesAtOutputFrame,
                      formantPreserve: formantPreserve, formant: formant,
                      compensation: compensation, isCancelled: isCancelled)
    }

    /// THE time-varying-transpose loop, for both entries.
    private static func curveLoop(
        _ source: StretchSource,
        sampleRate: Double,
        ratio: Double,
        semitonesAtOutputFrame: (Int) -> Double,
        formantPreserve: Bool,
        formant: FormantCurve?,
        compensation: CurveLatencyCompensation,
        isCancelled: () -> Bool
    ) throws -> StretchWindowOutput {
        let (channels, frames) = try source.validatedShape()
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw OfflineStretcherError.invalidInput("bad sample rate \(sampleRate)")
        }
        guard ratio.isFinite, ratio > 0 else {
            throw OfflineStretcherError.invalidInput("bad ratio \(ratio)")
        }
        let outputFrames = Int((Double(frames) * ratio).rounded())
        guard outputFrames >= 1 else {
            throw OfflineStretcherError.invalidInput("output would be empty")
        }
        StretchLoopTrace.current?.record(.curve, source.entry)

        guard let handle = css_create(Int32(channels), Float(sampleRate), rngSeed) else {
            throw OfflineStretcherError.allocationFailed
        }
        defer { css_destroy(handle) }

        // MEASURED, never derived: the hop is whatever the stretcher says it
        // is. Guarded because a zero would spin the loop forever. Read BEFORE
        // the pre-roll's transpose because the compensated lookup needs it.
        let interval = Int(css_interval_samples(handle))
        guard interval >= 1 else {
            throw OfflineStretcherError.invalidInput(
                "stretcher reported non-positive interval \(interval)")
        }
        // The schedule is read BEFORE the pre-roll's transpose too (I1-F1): a
        // window's pre-roll runs at its OWN first chunk's value, and where that
        // chunk starts depends on the schedule. The three accessors are
        // `const` reads of the configured STFT (`signalsmith-stretch.h`
        // `inputLatency()`/`outputLatency()`), so reading them before the two
        // setters below changes no state; `wholeFileGoldenCapture` diffs the
        // whole-file bytes across this reordering.
        let schedule = StretchSchedule(
            sourceFrames: frames, ratio: ratio,
            inputLatency: Int(css_input_latency(handle)),
            outputLatency: Int(css_output_latency(handle)),
            blockFrames: interval)
        let span = schedule.span(for: source)

        // The pre-roll runs at whatever the FIRST chunk will ask for, not at
        // the curve's value at frame 0.
        //
        // ⚠️ **THE FIRST `n` DELIVERED FRAMES CANNOT BE COMPENSATED, AND THIS
        // IS THE LEAST-WRONG ANSWER RATHER THAN A FIX.** Compensating output
        // frame F means handing its value over at processing position F − n;
        // for F < n that position is before the render starts and there is
        // nowhere to put it. `outputSeek` takes ONE transpose value for the
        // whole pre-roll, so the choice is between the curve's value at 0
        // (leaves a discontinuity at delivered frame n, and phase-0 §5.4
        // measured a −5.11 dB level dip across an instantaneous 2-semitone
        // map change) and the first chunk's value (continuous, and wrong only
        // over the first ~50 ms). Continuity wins. A curve that moves inside
        // the first 49.6 ms of a file therefore moves at frame 0 instead; a
        // pitch-correction curve is flat there, because a note boundary at
        // source second 0 has no earlier note to ramp from. (A WINDOW's first
        // chunk is its own; the span render's pre-roll keeps the frames it
        // delivers well past this, see `StretchRenderCache.spanPreRollSeconds`.)
        css_set_transpose_semitones(
            handle,
            Float(semitonesAtOutputFrame(curveLookupFrame(
                outputFrame: span.startOutputFrame, compensation: compensation,
                intervalSamples: interval))),
            tonalityLimitHz)
        if let formant {
            // Natural tuning §1(b), the ENGAGED branch: the formant curve, and
            // NEVER `css_set_formant_preserve` (its base 0 is the estimator).
            // The pre-roll runs at the FIRST chunk's values, the transpose's
            // continuity rule above, at the transpose's own lookup frame.
            applyFormant(formant, to: handle, lookupFrame: curveLookupFrame(
                outputFrame: span.startOutputFrame, compensation: compensation,
                intervalSamples: interval))
        } else {
            // nil: today's call, unchanged (a legacy set, the clip's flag).
            css_set_formant_preserve(handle, formantPreserve)
        }

        let io = try StretchBuffers(source: source, channels: channels, schedule: schedule,
                                    span: span)
        defer { io.deallocate() }

        io.withInPointers(atSourceFrame: span.inputStart) {
            css_output_seek(handle, $0, Int32(schedule.seekLength))
        }

        // Chunked middle — identical bookkeeping to `stretch(...)` except that
        // the chunk is `interval`, and the transpose is re-set before each one.
        var outDone = span.startOutputFrame
        var inDone = span.inputStart
        while outDone < span.loopEndOutputFrame {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            let outBlock = min(interval, schedule.processOut - outDone)
            let inTarget = schedule.inputTarget(afterOutputFrame: outDone + outBlock)
            let inBlock = inTarget - inDone
            css_set_transpose_semitones(
                handle,
                Float(semitonesAtOutputFrame(curveLookupFrame(
                    outputFrame: outDone, compensation: compensation,
                    intervalSamples: interval))),
                tonalityLimitHz)
            if let formant {
                // Beside the transpose, at the SAME lookup frame: both are
                // consumed by the same block process (`splitComputation` is
                // false in `presetDefault`), so they land together (§1 G4).
                applyFormant(formant, to: handle, lookupFrame: curveLookupFrame(
                    outputFrame: outDone, compensation: compensation,
                    intervalSamples: interval))
            }
            io.withInPointers(atSourceFrame: schedule.seekLength + inDone) { inPtrs in
                io.withOutPointers(atOutputFrame: outDone) { outPtrs in
                    css_process(
                        handle, inPtrs, Int32(inBlock), outPtrs, Int32(outBlock))
                }
            }
            outDone += outBlock
            inDone = inTarget
        }

        if isCancelled() { throw OfflineStretcherError.cancelled }
        if span.flushes {
            let flushFrames = outputFrames - outDone
            if flushFrames > 0 {
                io.withOutPointers(atOutputFrame: outDone) {
                    css_flush(handle, $0, Int32(flushFrames), schedule.playbackRate)
                }
            }
        }

        return io.output(span)
    }

    /// AVAudioPCMBuffer convenience over the planar core. Requires
    /// deinterleaved float32 (the engine's working format everywhere).
    public static func stretch(
        input: AVAudioPCMBuffer,
        ratio: Double,
        semitones: Double,
        formantPreserve: Bool,
        isCancelled: () -> Bool = { false }
    ) throws -> AVAudioPCMBuffer {
        let format = input.format
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
            let channelData = input.floatChannelData
        else {
            throw OfflineStretcherError.unsupportedFormat(
                "expected deinterleaved float32, got \(format)")
        }
        let frames = Int(input.frameLength)
        let channels = Int(format.channelCount)
        guard frames >= 1 else {
            throw OfflineStretcherError.invalidInput("empty buffer")
        }
        var planar: [[Float]] = []
        planar.reserveCapacity(channels)
        for c in 0..<channels {
            planar.append(Array(UnsafeBufferPointer(start: channelData[c], count: frames)))
        }

        let out = try stretch(
            input: planar, sampleRate: format.sampleRate, ratio: ratio,
            semitones: semitones, formantPreserve: formantPreserve,
            isCancelled: isCancelled)

        let outFrames = out[0].count
        guard
            let outBuffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(outFrames)),
            let outData = outBuffer.floatChannelData
        else {
            throw OfflineStretcherError.allocationFailed
        }
        for c in 0..<channels {
            out[c].withUnsafeBufferPointer { src in
                outData[c].update(from: src.baseAddress!, count: outFrames)
            }
        }
        outBuffer.frameLength = AVAudioFrameCount(outFrames)
        return outBuffer
    }
}
