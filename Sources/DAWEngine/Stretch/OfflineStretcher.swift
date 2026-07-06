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
