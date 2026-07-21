import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in lookahead brickwall limiter (M4 iii). Fixed 5 ms lookahead delay
/// (`LimiterParams.lookaheadSeconds`), reported as `latencySamples` — the
/// first nonzero insert latency (the M4 (viii) PDC hook consumes it).
///
/// Design (hard sample-peak guarantee BY CONSTRUCTION, not just post-settle):
///  · Stereo-linked peak-hold: a monotonic-deque sliding-window maximum over
///    the last `lookahead + 1` samples of the linked |peak| (amortized O(1)
///    per sample, preallocated storage).
///  · Gain target = min(1, ceiling / windowMax). Because the sample leaving
///    the delay line is INSIDE the window, target ≤ ceiling/|out sample|.
///  · Attack is instantaneous on the (still-delayed) gain signal — the drop
///    lands during the lookahead, before the peak plays. Release recovers
///    with a one-pole toward the target, from below, so the envelope NEVER
///    exceeds the target: output can never exceed the ceiling.
///  · A never-limited signal keeps the envelope at exactly 1.0, so
///    below-ceiling input nulls bit-exact against the delayed dry signal.
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention.
/// All buffers (delay lines, deque) are preallocated in `prepare` on the
/// main actor. Render-path contract: `process()`/`reset()` allocate nothing,
/// take no locks, log nothing, touch no ObjC.
final class LimiterEffect: EffectRendering, GainReductionReporting,
                           @unchecked Sendable {
    private static let maxChannels = 8

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: LimiterParams

        init(generation: UInt64, params: LimiterParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Prepared storage (main-actor allocated, render-thread used).
    private var sampleRate: Double = 48_000
    private var preparedChannels = 2
    private var delaySamples = 240
    /// Per-channel circular delay lines, one flat block: [channel][delaySamples].
    private var delayLine: UnsafeMutablePointer<Float>?
    private var delayCapacityPerChannel = 0
    private var delayWriteIndex = 0
    /// Monotonic deque for the sliding-window maximum (capacity window+1).
    private var dequeValues: UnsafeMutablePointer<Float>?
    private var dequePositions: UnsafeMutablePointer<Int64>?
    private var dequeCapacity = 0
    private var dequeHead = 0  // monotonically increasing; index % capacity
    private var dequeTail = 0
    private var sampleCounter: Int64 = 0

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    private var ceilingLinear: Float = 0.891250938  // −1 dB
    private var releaseCoeff: Float = 0
    private var envelope: Float = 1
    /// GR meter (m22-e): held MINIMUM linear gain (1 = untouched). The
    /// envelope lives in the linear domain here, so the −20 dB/s release is
    /// a per-sample MULTIPLY by `grRisePerSample` (multiplicative in linear
    /// ≡ linear in dB — the same peakDB ballistic as the compressor's
    /// subtraction). Render-thread-only; published via `grSlot` as positive
    /// dB, ONE log10 per quantum (never per sample).
    private var grHeldLinear: Float = 1
    private var grRisePerSample: Float = 1
    /// Render → control-plane publish slot (`Float.bitPattern`), one atomic
    /// store per quantum. See `GainReductionMeter`.
    private let grSlot: UnsafeMutablePointer<daw_atomic_u32>
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<LimiterParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: LimiterParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: LimiterParams = LimiterParams()) {
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        grSlot = .allocate(capacity: 1)
        daw_atomic_u32_store(grSlot, Float(0).bitPattern)
        lastAppliedParams = params
        overlay = AutomationParamOverlay(base: params)
        let snapshot = ParamSnapshot(generation: 0, params: params)
        _ = daw_atomic_ptr_exchange(
            paramsSlot, UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque()))
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(paramsSlot, nil) {
            Unmanaged<ParamSnapshot>.fromOpaque(raw).release()
        }
        paramsSlot.deallocate()
        grSlot.deallocate()
        delayLine?.deallocate()
        dequeValues?.deallocate()
        dequePositions?.deallocate()
    }

    // MARK: - GainReductionReporting (m22-e)

    /// Held-peak gain reduction, POSITIVE dB (0 = untouched), −20 dB/s
    /// release. One atomic load — safe from any thread.
    var gainReductionDb: Float { Float(bitPattern: daw_atomic_u32_load(grSlot)) }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: LimiterParams) {
        guard params != lastAppliedParams else { return }
        lastAppliedParams = params
        publishedGeneration &+= 1
        let snapshot = ParamSnapshot(generation: publishedGeneration, params: params)
        let now = ContinuousClock.now
        let raw = UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque())
        if let old = daw_atomic_ptr_exchange(paramsSlot, raw) {
            retired.append((Unmanaged<ParamSnapshot>.fromOpaque(old).takeRetainedValue(), now))
        }
        retired.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

    // MARK: - EffectRendering

    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        preparedChannels = min(channelCount, Self.maxChannels)
        grRisePerSample = GainReductionMeter.risePerSample(sampleRate: sampleRate)
        delaySamples = max(1, Int((LimiterParams.lookaheadSeconds * sampleRate).rounded()))

        // (Re)allocate the delay lines and deque — main actor, pre-render.
        let neededDelay = delaySamples
        if delayCapacityPerChannel != neededDelay || delayLine == nil {
            delayLine?.deallocate()
            delayLine = .allocate(capacity: neededDelay * Self.maxChannels)
            delayCapacityPerChannel = neededDelay
        }
        let neededDeque = delaySamples + 2
        if dequeCapacity != neededDeque || dequeValues == nil {
            dequeValues?.deallocate()
            dequePositions?.deallocate()
            dequeValues = .allocate(capacity: neededDeque)
            dequePositions = .allocate(capacity: neededDeque)
            dequeCapacity = neededDeque
        }
        clearRuntimeState()
        lastGeneration = .max  // re-derive coefficients at the new rate
    }

    /// The fixed 5 ms lookahead at the prepared rate (240 @ 48 kHz).
    var latencySamples: Int { delaySamples }

    /// Clears the delay line and envelope (stop-time tail cut / un-bypass).
    func reset() {
        clearRuntimeState()
    }

    /// Render-thread safe: bounded memset-style clears of preallocated memory.
    private func clearRuntimeState() {
        if let delayLine {
            delayLine.update(repeating: 0, count: delayCapacityPerChannel * Self.maxChannels)
        }
        delayWriteIndex = 0
        dequeHead = 0
        dequeTail = 0
        sampleCounter = 0
        envelope = 1
        grHeldLinear = 1
        GainReductionMeter.publish(grSlot, db: 0)  // atomic store — RT-safe
    }

    /// Adopts a newly published main-actor snapshot (borrowed — retire bin
    /// guarantees lifetime). Called at the top of `process()` AND by
    /// `storeAutomatedParam`, so an automation store never loses to a
    /// snapshot adopted later in the same quantum.
    private func adoptPendingParams() {
        guard let raw = daw_atomic_ptr_load(paramsSlot) else { return }
        let snapshot = Unmanaged<ParamSnapshot>.fromOpaque(raw).takeUnretainedValue()
        guard snapshot.generation != lastGeneration else { return }
        lastGeneration = snapshot.generation
        overlay.rebase(snapshot.params)
        deriveRenderParams(snapshot.params)
    }

    /// Recomputes the derived render constants from `p` — generation change,
    /// automation stores, and the automation revert route through the SAME
    /// math (pure libm, no allocation; render-thread safe). The lookahead is
    /// FIXED, so no automated param can ever resize the prepared lines.
    private func deriveRenderParams(_ p: LimiterParams) {
        ceilingLinear = Float(pow(10.0, p.ceilingDb / 20.0))
        releaseCoeff = Float(exp(-1.0 / (p.releaseMs * 0.001 * sampleRate)))
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .limiter)`: 0 ceilingDb, 1 releaseMs.
    /// Pokes a preallocated params copy and re-derives — no allocation, no
    /// locks. The release smoother naturally declicks the quantum steps.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...1).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.ceilingDb = value
        default: overlay.effective.releaseMs = value
        }
        deriveRenderParams(overlay.effective)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard let delayLine, let dequeValues, let dequePositions else { return }

        let strideBytes = MemoryLayout<Float>.stride
        var channelData = InlineChannelPointers()
        var channelCount = 0
        var minFrames = frameCount
        for buffer in buffers where channelCount < preparedChannels {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            channelData[channelCount] = data
            minFrames = min(minFrames, Int(buffer.mDataByteSize) / strideBytes)
            channelCount += 1
        }
        guard channelCount > 0 else { return }

        let window = Int64(delaySamples)  // window spans samples n−D … n
        var env = envelope
        var grHeld = grHeldLinear
        let grRise = grRisePerSample
        var writeIndex = delayWriteIndex
        var n = sampleCounter
        for frame in 0..<minFrames {
            // Stereo-linked peak of the INCOMING sample.
            var peak: Float = 0
            for channel in 0..<channelCount {
                let sample = abs(channelData[channel]![frame])
                if sample > peak { peak = sample }
            }
            // Sliding-window maximum (monotonic deque, amortized O(1)).
            while dequeTail > dequeHead && dequeValues[(dequeTail - 1) % dequeCapacity] <= peak {
                dequeTail -= 1
            }
            dequeValues[dequeTail % dequeCapacity] = peak
            dequePositions[dequeTail % dequeCapacity] = n
            dequeTail += 1
            while dequePositions[dequeHead % dequeCapacity] < n - window {
                dequeHead += 1
            }
            let windowMax = dequeValues[dequeHead % dequeCapacity]

            // Gain target; instant attack, one-pole release from below.
            let target: Float = windowMax > ceilingLinear ? ceilingLinear / windowMax : 1.0
            if target < env {
                env = target
            } else {
                env = target + (env - target) * releaseCoeff
            }
            // GR meter (m22-e): held minimum of the applied gain — instant
            // attack downward (a one-quantum clamp always registers), then a
            // multiplicative +20 dB/s rise back toward unity. One multiply +
            // two mins per sample; the dB conversion runs once per quantum.
            let grRisen = grHeld * grRise
            grHeld = min(env, grRisen < 1 ? grRisen : 1)

            // Swap through the delay line and apply the gain to the DELAYED
            // sample (which the window still covers → |out| ≤ ceiling).
            for channel in 0..<channelCount {
                let data = channelData[channel]!
                let slot = channel * delayCapacityPerChannel + writeIndex
                let delayed = delayLine[slot]
                delayLine[slot] = data[frame]
                data[frame] = delayed * env
            }
            writeIndex += 1
            if writeIndex == delaySamples { writeIndex = 0 }
            n += 1
        }
        envelope = env
        grHeldLinear = grHeld
        delayWriteIndex = writeIndex
        sampleCounter = n
        // Publish positive dB of reduction: pure libm log10 once per
        // quantum, floored at 10^(−80/20) so the value caps at 80 dB.
        GainReductionMeter.publish(
            grSlot,
            db: -20.0 * log10f(max(grHeld, GainReductionMeter.floorLinear)))
    }
}
