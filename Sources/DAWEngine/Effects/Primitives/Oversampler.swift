import DAWCore
import Foundation

// ============================================================================
// MARK: - DESIGN (m39-ac). The reusable oversampling primitive. The FILTER's
//         design and every quality number live in `DAWCore.OversamplerDesign`;
//         this file is the RENDER-THREAD machinery that runs it.
// ============================================================================
//
// ## 1. What it is for
//
// Any non-linear stage — a clipper, a saturator, a waveshaper — creates
// harmonics that did not exist in the input. The ones above Nyquist cannot be
// represented, so they FOLD BACK as inharmonic tones: audible as a thin
// metallic fizz that tracks the material but is unrelated to it musically.
// Running the non-linearity at 2× or 4× the sample rate moves that fold above
// the audio band, and the anti-alias filter on the way down removes it.
//
// `.clipper` (m39-ac) is the first caller. Saturator v2 is the second, and this
// seam is shaped for it: `SaturatorEffect.swift` already describes its own
// missing oversampling as "an additive internal change behind the same seam",
// and the change there is `upsample` → `tanh` the scratch → `downsample`.
//
// ## 2. The API shape, and why it is TWO CALLS and not a closure
//
//     oversampler.upsample(input, frameCount: n, channel: c)
//     // caller shapes oversampler.scratch(channel: c) in place, n * factor
//     // samples, knowing nothing about the filter
//     oversampler.downsample(into: output, frameCount: n, channel: c)
//
// A `process(buffers:shape:)` taking a closure would be an INDIRECT CALL PER
// SAMPLE at `-Onone`, which is where every render-path test in this tree runs,
// and the allocation gate has already measured that `-Onone` turns innocuous
// constructs into per-iteration malloc traffic. Two plain methods over a scratch
// buffer have neither problem, and they let a caller vary the shaping
// parameters WITHIN the block (the clipper interpolates its ceiling per BASE
// frame across that frame's `factor` sub-samples) — which a closure taking one
// sample could not express without another parameter.
//
// ## 3. Render-thread contract
//
// `upsample`, `downsample`, `setFactor` and `reset` allocate nothing, take no
// locks, log nothing, touch no ObjC and hop no actors. Every buffer is sized in
// `prepare()` for `OversamplerDesign.maxFactor` and the caller's maximum
// quantum, so a factor change is an index bound and never an allocation.
//
// ⚠️ `while`, never `for i in 0..<n`, in every loop that runs per sample —
// MEASURED at `EffectChainProcessor.swift:402-412`: a `Range` iteration raises
// ~2 malloc/free events PER ITERATION at `-Onone`, which is why the allocation
// gates in this tree can assert an absolute zero.
//
// ## 4. Cost, as an operation count (NOT a benchmark)
//
// Per base-rate sample per channel, with `M = OversamplerDesign.tapsPerPhase`:
//
//   · upsample:   `L · M` multiply-accumulates (each of the L output samples
//                 reads one polyphase phase of ~M taps)
//   · downsample: `L · M + 1` (direct form, one output per L inputs)
//
// So ≈ 257 MACs/sample/channel at 4× and 129 at 2×. At 1× the MAC loops are
// SKIPPED entirely (§5) and the cost is two array reads.
//
// ## 5. Factor 1 is a member of the family, not an exception
//
// At `L = 1` the kernel's cutoff is 0.5 of the (un-)oversampled rate, so
// `sinc(n − M/2)` is 1 at the centre tap and EXACTLY zero at every other
// integer — the kernel degenerates to a pure `M/2`-sample delay. The two stages
// therefore still contribute exactly `M` samples of delay, which is what keeps
// `latencySamples` constant across the whole factor range (see
// `OversamplerDesign` §3 for why that constancy is a correctness requirement
// and not a convenience).
//
// The code still takes a COPY path there rather than multiplying by 32 zeroes.
// That is a CPU decision, not a semantic one: `OversamplerDesignTests` D2 proves
// the factor-1 kernel really is a unit impulse, and `ClipperTests` L3 proves the
// shipped path delays by the same 32 samples at every factor and returns the
// impulse at FULL amplitude at 1×.
//
// ## 6. Denormal policy — flush on WRITE, and the exception it creates
//
// An FIR has no feedback, so it cannot generate decaying denormals of its own.
// It can PROPAGATE them: a reverb tail decaying into subnormals upstream would
// otherwise put up to 129 subnormal multiplies per output sample on the render
// thread, during silence, when nobody is listening for it. So every value
// written into either history is flushed at `DelayEffect`'s `1e-20` — the
// `StereoWidthEffect` rule ("a line is never fed a subnormal"), one compare per
// push.
//
// ⚠️ **THAT MAKES THE FACTOR-1 IDENTITY "EXACT EXCEPT SUBNORMALS", AND IT IS
// SAID OUT LOUD HERE BECAUSE A HALF-TRUE IDENTITY LAW IS WORSE THAN NONE.** A
// subnormal `Float` is below −750 dBFS. The CLIPPER's own `mix == 0` law does
// NOT route through this class at all — it reads a plain, unflushed dry ring —
// so that law stays bit-exact for subnormals and for −0.0, and it is the one a
// test should hold to the strict standard.
final class Oversampler: @unchecked Sendable {
    /// Denormal-flush threshold — `DelayEffect`'s existing constant. See §6.
    private static let denormalFloor: Float = 1e-20

    /// Base-rate samples of input the up stage must remember: `M + 1` for the
    /// zero-phase, rounded up to a power of two for mask indexing.
    private static let upHistoryCapacity = 64
    private static let upHistoryMask = upHistoryCapacity - 1
    /// Oversampled samples the down stage must remember: the longest kernel
    /// (`4·M + 1` = 129), rounded up to a power of two.
    private static let downHistoryCapacity = 256
    private static let downHistoryMask = downHistoryCapacity - 1

    /// Every supported factor's kernel, concatenated, `Float`. Copied out of
    /// `OversamplerDesign.kernel` ONCE at init so the render thread never
    /// touches a Swift `Array`.
    private let kernels: UnsafeMutablePointer<Float>
    /// Where each supported factor's kernel starts inside `kernels`, indexed BY
    /// FACTOR (so entries 0 and 3 are `-1`, "not a supported factor").
    ///
    /// ⛔⛔ **A RAW POINTER TABLE, NOT A `Dictionary`, AND THE REASON IS
    /// MEASURED.** The first draft looked this up with `[Int: Int]` on every
    /// `upsample`/`downsample` call, and the allocation gate read **163 296
    /// malloc events over 2 000 quanta** at `-Onone` against the absolute zero
    /// it asserts. A Swift `Dictionary` (and a Swift `Array`) is as forbidden on
    /// this thread as a lock.
    private let kernelOffsets: UnsafeMutablePointer<Int>
    private let kernelOffsetCount: Int
    private let kernelTotal: Int

    // Per-channel state (allocated in `prepare`, main actor).
    private var upHistory: UnsafeMutablePointer<Float>?
    private var downHistory: UnsafeMutablePointer<Float>?
    private var scratchStorage: UnsafeMutablePointer<Float>?
    private var upWrite: UnsafeMutablePointer<Int>?
    private var downWrite: UnsafeMutablePointer<Int>?

    private(set) var preparedChannels = 0
    private(set) var preparedFrames = 0
    /// The live factor. Always one of `OversamplerDesign.supportedFactors`.
    private(set) var factor = 1

    /// Per-channel oversampled scratch stride, in samples.
    private var scratchStride: Int { preparedFrames * OversamplerDesign.maxFactor }

    /// MAIN-ACTOR-ONLY: the Swift `Array` traffic here is deliberate and
    /// confined to init. `OversamplerDesign.supportedFactors` and
    /// `OversamplerDesign.kernel` are both `Array`-shaped and neither is ever
    /// touched again after this function returns.
    init() {
        kernelOffsetCount = OversamplerDesign.maxFactor + 1
        kernelOffsets = .allocate(capacity: kernelOffsetCount)
        kernelOffsets.initialize(repeating: -1, count: kernelOffsetCount)
        var total = 0
        for supported in OversamplerDesign.supportedFactors
        where supported >= 0 && supported < kernelOffsetCount {
            kernelOffsets[supported] = total
            total += OversamplerDesign.kernelLength(factor: supported)
        }
        kernelTotal = max(1, total)
        kernels = .allocate(capacity: kernelTotal)
        kernels.initialize(repeating: 0, count: kernelTotal)
        for supported in OversamplerDesign.supportedFactors
        where supported >= 0 && supported < kernelOffsetCount {
            let base = kernelOffsets[supported]
            guard base >= 0 else { continue }
            let taps = OversamplerDesign.kernel(factor: supported)
            var index = 0
            while index < taps.count {
                kernels[base + index] = Float(taps[index])
                index += 1
            }
        }
    }

    deinit {
        kernels.deinitialize(count: kernelTotal)
        kernels.deallocate()
        kernelOffsets.deinitialize(count: kernelOffsetCount)
        kernelOffsets.deallocate()
        releaseChannelStorage()
    }

    /// Render-thread-safe kernel lookup: a bounds-checked read of a preallocated
    /// table. `nil` for any factor this instance has no kernel for.
    @inline(__always)
    private func kernelBase(_ factor: Int) -> Int? {
        guard factor >= 0, factor < kernelOffsetCount else { return nil }
        let base = kernelOffsets[factor]
        return base >= 0 ? base : nil
    }

    private func releaseChannelStorage() {
        upHistory?.deallocate()
        downHistory?.deallocate()
        scratchStorage?.deallocate()
        upWrite?.deallocate()
        downWrite?.deallocate()
        upHistory = nil
        downHistory = nil
        scratchStorage = nil
        upWrite = nil
        downWrite = nil
    }

    /// MAIN-ACTOR setup. Allocates every buffer at the MAXIMUM factor, so no
    /// later factor change can need memory. Re-preparing reallocates and
    /// re-zeroes; the graph is not rendering during `prepare` (the
    /// `CompensationDelayState.allocate` guarantee).
    func prepare(maxFramesPerQuantum: Int, channelCount: Int) {
        releaseChannelStorage()
        preparedChannels = max(0, channelCount)
        preparedFrames = max(0, maxFramesPerQuantum)
        guard preparedChannels > 0, preparedFrames > 0 else { return }

        let up = UnsafeMutablePointer<Float>.allocate(
            capacity: preparedChannels * Self.upHistoryCapacity)
        up.initialize(repeating: 0, count: preparedChannels * Self.upHistoryCapacity)
        upHistory = up

        let down = UnsafeMutablePointer<Float>.allocate(
            capacity: preparedChannels * Self.downHistoryCapacity)
        down.initialize(repeating: 0, count: preparedChannels * Self.downHistoryCapacity)
        downHistory = down

        let scratchCount = preparedChannels * preparedFrames * OversamplerDesign.maxFactor
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCount)
        scratch.initialize(repeating: 0, count: scratchCount)
        scratchStorage = scratch

        let upIndex = UnsafeMutablePointer<Int>.allocate(capacity: preparedChannels)
        upIndex.initialize(repeating: 0, count: preparedChannels)
        upWrite = upIndex
        let downIndex = UnsafeMutablePointer<Int>.allocate(capacity: preparedChannels)
        downIndex.initialize(repeating: 0, count: preparedChannels)
        downWrite = downIndex
    }

    /// RENDER-THREAD safe: stores over already-allocated storage. Clears both
    /// histories and both write cursors.
    func reset() {
        if let up = upHistory {
            var index = 0
            let total = preparedChannels * Self.upHistoryCapacity
            while index < total { up[index] = 0; index += 1 }
        }
        if let down = downHistory {
            var index = 0
            let total = preparedChannels * Self.downHistoryCapacity
            while index < total { down[index] = 0; index += 1 }
        }
        if let cursor = upWrite {
            var index = 0
            while index < preparedChannels { cursor[index] = 0; index += 1 }
        }
        if let cursor = downWrite {
            var index = 0
            while index < preparedChannels { cursor[index] = 0; index += 1 }
        }
    }

    /// RENDER-THREAD safe. Snaps to a supported factor and, **when the factor
    /// actually changes, CLEARS the histories.**
    ///
    /// ⚠️ The clear is not tidiness: the down history holds samples at the OLD
    /// oversampled rate, and re-using them against a different kernel would
    /// filter garbage rather than audio. It costs a ~32-sample ramp-in (0.67 ms
    /// at 48 kHz) at the moment of the change — the `PhaserEffect.stages`
    /// precedent, where a discrete param is likewise the one thing that clears
    /// state, and the reason both params are `Modulatable: refused`.
    /// ⛔ The argument must ALREADY be one of `OversamplerDesign
    /// .supportedFactors` — snap it through `ClipperParams
    /// .oversamplingFactor(at:)` first. An unsupported value is IGNORED rather
    /// than snapped here, because snapping needs the roster and touching a Swift
    /// `Array` on this thread allocates (see `kernelOffsets`). The table lookup
    /// below is the validation.
    func setFactor(_ requested: Int) {
        guard requested != factor, kernelBase(requested) != nil else { return }
        factor = requested
        reset()
    }

    /// The oversampled scratch for one channel: `frameCount * factor` valid
    /// samples after `upsample`, and what `downsample` reads back. The caller
    /// shapes this in place.
    func scratch(channel: Int) -> UnsafeMutablePointer<Float>? {
        guard let storage = scratchStorage, channel >= 0, channel < preparedChannels
        else { return nil }
        return storage + channel * scratchStride
    }

    /// Expands `frameCount` base-rate samples into `frameCount * factor`
    /// oversampled samples in `scratch(channel:)`.
    ///
    /// Polyphase interpolation: output phase `p` of input `i` is
    /// `Σ_t h[p + t·L] · x[i − t]`, which is the zero-stuffed convolution with
    /// every guaranteed-zero product skipped.
    func upsample(_ input: UnsafePointer<Float>, frameCount: Int, channel: Int) {
        guard frameCount > 0, frameCount <= preparedFrames,
              channel >= 0, channel < preparedChannels,
              let history = upHistory, let cursor = upWrite,
              let out = scratch(channel: channel),
              let base = kernelBase(factor)
        else { return }

        let line = history + channel * Self.upHistoryCapacity
        let mask = Self.upHistoryMask
        var write = cursor[channel]
        let length = OversamplerDesign.kernelLength(factor: factor)
        let taps = kernels + base
        let localFactor = factor
        // §5: at 1× the kernel is a single unit tap at `centre`, so the MAC
        // loop would be 32 multiplies by exactly 0.0 plus one by 1.0. The copy
        // path below is the same function, evaluated.
        let centre = (length - 1) / 2

        var frame = 0
        while frame < frameCount {
            var sample = input[frame]
            if sample > -Self.denormalFloor && sample < Self.denormalFloor { sample = 0 }
            line[write & mask] = sample
            if localFactor == 1 {
                out[frame] = line[(write - centre) & mask]
            } else {
                var phase = 0
                while phase < localFactor {
                    var accumulator = 0.0
                    var tap = phase
                    var back = 0
                    while tap < length {
                        accumulator += Double(taps[tap]) * Double(line[(write - back) & mask])
                        tap += localFactor
                        back += 1
                    }
                    out[frame * localFactor + phase] = Float(accumulator)
                    phase += 1
                }
            }
            write += 1
            frame += 1
        }
        cursor[channel] = write & mask
    }

    /// Collapses the `frameCount * factor` oversampled samples in
    /// `scratch(channel:)` back down into `output` (`frameCount` samples).
    ///
    /// Direct-form decimation: push this base frame's FIRST oversampled sample,
    /// evaluate the whole kernel at that position, then push the remaining
    /// `factor − 1`. Evaluating at the first sub-sample rather than the last is
    /// what makes the down stage contribute exactly `(N−1)/2` oversampled
    /// samples — `M/2` base-rate samples — of delay, matching the up stage.
    func downsample(into output: UnsafeMutablePointer<Float>, frameCount: Int, channel: Int) {
        guard frameCount > 0, frameCount <= preparedFrames,
              channel >= 0, channel < preparedChannels,
              let history = downHistory, let cursor = downWrite,
              let source = scratch(channel: channel),
              let base = kernelBase(factor)
        else { return }

        let line = history + channel * Self.downHistoryCapacity
        let mask = Self.downHistoryMask
        var write = cursor[channel]
        let length = OversamplerDesign.kernelLength(factor: factor)
        let taps = kernels + base
        let localFactor = factor
        let centre = (length - 1) / 2
        // The decimator is the same prototype at unity DC gain: the shared
        // kernel is normalised to `Σh == factor` for the interpolator, so the
        // decimator divides it back out. ONE constant, not a second kernel.
        let normalise = 1.0 / Double(localFactor)

        var frame = 0
        while frame < frameCount {
            var head = source[frame * localFactor]
            if head > -Self.denormalFloor && head < Self.denormalFloor { head = 0 }
            line[write & mask] = head
            if localFactor == 1 {
                output[frame] = line[(write - centre) & mask]
            } else {
                var accumulator = 0.0
                var tap = 0
                while tap < length {
                    accumulator += Double(taps[tap]) * Double(line[(write - tap) & mask])
                    tap += 1
                }
                output[frame] = Float(accumulator * normalise)
                // Push the sub-samples this output did not read from; they are
                // history for the next one.
                var phase = 1
                while phase < localFactor {
                    write += 1
                    var value = source[frame * localFactor + phase]
                    if value > -Self.denormalFloor && value < Self.denormalFloor { value = 0 }
                    line[write & mask] = value
                    phase += 1
                }
            }
            write += 1
            frame += 1
        }
        cursor[channel] = write & mask
    }

    // MARK: - Test instruments
    //
    // Bounded reads of already-allocated storage, render-thread safe in the
    // same sense `reset()` is, called only from tests.

    /// How many history words are currently non-zero — the
    /// `PhaserEffect.nonZeroStateWords` shape, so a test can prove `reset()`
    /// cleared something rather than asserting over an empty filter.
    var nonZeroStateWords: Int {
        var count = 0
        if let up = upHistory {
            var index = 0
            let total = preparedChannels * Self.upHistoryCapacity
            while index < total {
                if up[index] != 0 { count += 1 }
                index += 1
            }
        }
        if let down = downHistory {
            var index = 0
            let total = preparedChannels * Self.downHistoryCapacity
            while index < total {
                if down[index] != 0 { count += 1 }
                index += 1
            }
        }
        return count
    }

    /// One kernel tap, for the design tests. nil for an unsupported factor or
    /// an out-of-range index.
    func kernelTap(factor: Int, index: Int) -> Float? {
        guard let base = kernelBase(factor), index >= 0,
              index < OversamplerDesign.kernelLength(factor: factor) else { return nil }
        return kernels[base + index]
    }
}
