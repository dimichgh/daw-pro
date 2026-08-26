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
        let channels = input.count
        guard channels >= 1 else {
            throw OfflineStretcherError.invalidInput("no channels")
        }
        let frames = input[0].count
        guard frames >= 1 else {
            throw OfflineStretcherError.invalidInput("empty input")
        }
        guard input.allSatisfy({ $0.count == frames }) else {
            throw OfflineStretcherError.invalidInput("channels differ in length")
        }
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

        guard let handle = css_create(Int32(channels), Float(sampleRate), rngSeed) else {
            throw OfflineStretcherError.allocationFailed
        }
        defer { css_destroy(handle) }
        css_set_transpose_semitones(handle, Float(semitones), tonalityLimitHz)
        css_set_formant_preserve(handle, formantPreserve)

        // Upstream `outputSeekLength(1/ratio)`, truncation and all. The
        // outputSeek consumes this many head frames and leaves the delivered
        // output aligned to input frame 0.
        let inputLatency = Int(css_input_latency(handle))
        let outputLatency = Int(css_output_latency(handle))
        let playbackRate = 1.0 / ratio
        let seekLength = Int(Double(inputLatency) + playbackRate * Double(outputLatency))

        // Working copies: input padded with silence to at least seekLength
        // (sub-latency-sized sources are legal, just smeared), output sized
        // exactly. Manual allocation gives the C shim stable base pointers.
        let totalIn = max(frames, seekLength)
        var inChans: [UnsafeMutableBufferPointer<Float>] = []
        var outChans: [UnsafeMutableBufferPointer<Float>] = []
        defer {
            for b in inChans { b.deallocate() }
            for b in outChans { b.deallocate() }
        }
        for channel in input {
            let inBuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: totalIn)
            inBuf.initialize(repeating: 0)
            channel.withUnsafeBufferPointer { src in
                inBuf.baseAddress!.update(from: src.baseAddress!, count: frames)
            }
            inChans.append(inBuf)
            let outBuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: outputFrames)
            outBuf.initialize(repeating: 0)
            outChans.append(outBuf)
        }
        let inBase = inChans.map { UnsafePointer($0.baseAddress!) }
        let outBase = outChans.map { $0.baseAddress! }

        func withInPointers<R>(
            offset: Int, _ body: (UnsafePointer<UnsafePointer<Float>>) -> R
        ) -> R {
            let shifted = inBase.map { $0 + offset }
            return shifted.withUnsafeBufferPointer { body($0.baseAddress!) }
        }
        func withOutPointers<R>(
            offset: Int, _ body: (UnsafePointer<UnsafeMutablePointer<Float>>) -> R
        ) -> R {
            let shifted = outBase.map { $0 + offset }
            return shifted.withUnsafeBufferPointer { body($0.baseAddress!) }
        }

        // 1. Align (consumes input[0..<seekLength], produces the pre-roll
        //    internally).
        withInPointers(offset: 0) { css_output_seek(handle, $0, Int32(seekLength)) }

        // 2. Chunked middle: the remaining input maps onto the output before
        //    the flush tail; cumulative targets keep the average per-call
        //    out/in ratio exact (upstream: block splits "work just the same").
        let processIn = totalIn - seekLength
        let seekOut = Int(Double(seekLength) / playbackRate) // upstream truncation
        let processOut = max(0, outputFrames - seekOut)
        var outDone = 0
        var inDone = 0
        while outDone < processOut {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            let outBlock = min(blockFrames, processOut - outDone)
            let inTarget = Int(
                (Double(outDone + outBlock) * Double(processIn) / Double(processOut))
                    .rounded())
            let inBlock = inTarget - inDone
            withInPointers(offset: seekLength + inDone) { inPtrs in
                withOutPointers(offset: outDone) { outPtrs in
                    css_process(
                        handle, inPtrs, Int32(inBlock), outPtrs, Int32(outBlock))
                }
            }
            outDone += outBlock
            inDone = inTarget
        }

        // 3. Drain the synthesis tail (click-free ending, no more input).
        if isCancelled() { throw OfflineStretcherError.cancelled }
        let flushFrames = outputFrames - outDone
        if flushFrames > 0 {
            withOutPointers(offset: outDone) {
                css_flush(handle, $0, Int32(flushFrames), playbackRate)
            }
        }

        return outBase.map { Array(UnsafeBufferPointer(start: $0, count: outputFrames)) }
    }

    // MARK: - m23-q Phase 0 (E1): time-varying transpose — EXPERIMENT ONLY

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
    /// Nothing in this file compensates for it: E1 measures the raw path, and
    /// deciding what to do about 50 ms is Phase 1's business.
    static let measuredCurveLatencyFrames = 2379

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

    /// **m23-q Phase 0 experiment surface — not a shipping path.** Renders with
    /// a *time-varying* transpose: `css_set_transpose_semitones` is called
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
    /// **No latency compensation.** The curve is indexed naively against the
    /// output write cursor. Upstream centres a parameter change at the
    /// *processing time*, which leads the delivered output; measuring that
    /// offset is E1(a) and compensating for it is Phase 1. Anything that
    /// pre-shifts the curve here would make E1(a) measure its own correction.
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
        isCancelled: () -> Bool = { false }
    ) throws -> [[Float]] {
        let channels = input.count
        guard channels >= 1 else {
            throw OfflineStretcherError.invalidInput("no channels")
        }
        let frames = input[0].count
        guard frames >= 1 else {
            throw OfflineStretcherError.invalidInput("empty input")
        }
        guard input.allSatisfy({ $0.count == frames }) else {
            throw OfflineStretcherError.invalidInput("channels differ in length")
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw OfflineStretcherError.invalidInput("bad sample rate \(sampleRate)")
        }
        guard ratio.isFinite, ratio > 0 else {
            throw OfflineStretcherError.invalidInput("bad ratio \(ratio)")
        }
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
        let outputFrames = Int((Double(frames) * ratio).rounded())
        guard outputFrames >= 1 else {
            throw OfflineStretcherError.invalidInput("output would be empty")
        }

        guard let handle = css_create(Int32(channels), Float(sampleRate), rngSeed) else {
            throw OfflineStretcherError.allocationFailed
        }
        defer { css_destroy(handle) }
        // The pre-roll runs at the curve's initial value.
        css_set_transpose_semitones(
            handle, Float(transposeCurveValue(curve, at: 0)), tonalityLimitHz)
        css_set_formant_preserve(handle, formantPreserve)

        // MEASURED, never derived: the hop is whatever the stretcher says it
        // is. Guarded because a zero would spin the loop forever.
        let interval = Int(css_interval_samples(handle))
        guard interval >= 1 else {
            throw OfflineStretcherError.invalidInput(
                "stretcher reported non-positive interval \(interval)")
        }

        let inputLatency = Int(css_input_latency(handle))
        let outputLatency = Int(css_output_latency(handle))
        let playbackRate = 1.0 / ratio
        let seekLength = Int(Double(inputLatency) + playbackRate * Double(outputLatency))

        let totalIn = max(frames, seekLength)
        var inChans: [UnsafeMutableBufferPointer<Float>] = []
        var outChans: [UnsafeMutableBufferPointer<Float>] = []
        defer {
            for b in inChans { b.deallocate() }
            for b in outChans { b.deallocate() }
        }
        for channel in input {
            let inBuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: totalIn)
            inBuf.initialize(repeating: 0)
            channel.withUnsafeBufferPointer { src in
                inBuf.baseAddress!.update(from: src.baseAddress!, count: frames)
            }
            inChans.append(inBuf)
            let outBuf = UnsafeMutableBufferPointer<Float>.allocate(capacity: outputFrames)
            outBuf.initialize(repeating: 0)
            outChans.append(outBuf)
        }
        let inBase = inChans.map { UnsafePointer($0.baseAddress!) }
        let outBase = outChans.map { $0.baseAddress! }

        func withInPointers<R>(
            offset: Int, _ body: (UnsafePointer<UnsafePointer<Float>>) -> R
        ) -> R {
            let shifted = inBase.map { $0 + offset }
            return shifted.withUnsafeBufferPointer { body($0.baseAddress!) }
        }
        func withOutPointers<R>(
            offset: Int, _ body: (UnsafePointer<UnsafeMutablePointer<Float>>) -> R
        ) -> R {
            let shifted = outBase.map { $0 + offset }
            return shifted.withUnsafeBufferPointer { body($0.baseAddress!) }
        }

        withInPointers(offset: 0) { css_output_seek(handle, $0, Int32(seekLength)) }

        // Chunked middle — identical bookkeeping to `stretch(...)` except that
        // the chunk is `interval`, and the transpose is re-set before each one.
        let processIn = totalIn - seekLength
        let seekOut = Int(Double(seekLength) / playbackRate)
        let processOut = max(0, outputFrames - seekOut)
        var outDone = 0
        var inDone = 0
        while outDone < processOut {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            let outBlock = min(interval, processOut - outDone)
            let inTarget = Int(
                (Double(outDone + outBlock) * Double(processIn) / Double(processOut))
                    .rounded())
            let inBlock = inTarget - inDone
            css_set_transpose_semitones(
                handle, Float(transposeCurveValue(curve, at: outDone)), tonalityLimitHz)
            withInPointers(offset: seekLength + inDone) { inPtrs in
                withOutPointers(offset: outDone) { outPtrs in
                    css_process(
                        handle, inPtrs, Int32(inBlock), outPtrs, Int32(outBlock))
                }
            }
            outDone += outBlock
            inDone = inTarget
        }

        if isCancelled() { throw OfflineStretcherError.cancelled }
        let flushFrames = outputFrames - outDone
        if flushFrames > 0 {
            withOutPointers(offset: outDone) {
                css_flush(handle, $0, Int32(flushFrames), playbackRate)
            }
        }

        return outBase.map { Array(UnsafeBufferPointer(start: $0, count: outputFrames)) }
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
