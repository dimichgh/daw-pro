import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in algorithmic reverb (M4 iv) — the classic Freeverb topology:
/// per-channel 8 parallel damped-feedback combs → 4 series allpasses, fed by
/// the mono sum (× 0.015 fixed input gain) through a pre-delay line. The
/// right channel's lines are offset by the classic 23-sample stereo spread;
/// the canonical comb/allpass tunings (44.1 kHz samples) scale with the
/// prepared rate. `width` is mid/side on the WET signal only (1 = full
/// stereo, 0 = mono wet); `roomSize` maps to comb feedback 0.7 + 0.28·size
/// and `damping` to the in-loop one-pole coefficient 0.4·damping (Freeverb's
/// scaled constants). Output is dry·(1−mix) + wet·mix.
///
/// mix == 0 is BIT-EXACT dry: the buffer is never written (the tank still
/// advances so a later mix raise has a coherent tail).
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention;
/// derived constants recompute only on generation change. All lines are
/// preallocated in `prepare` for the MAX param ranges (200 ms pre-delay), so
/// no param value ever allocates. Render-path contract: `process()`/`reset()`
/// allocate nothing, take no locks, log nothing, touch no ObjC. Comb filter
/// state is denormal-flushed per sample (feedback loops idle on silence).
final class ReverbEffect: EffectRendering, @unchecked Sendable {
    private static let combCount = 8
    private static let allpassCount = 4
    /// Canonical Freeverb tunings in samples at 44.1 kHz.
    private static let combTunings = [1_116, 1_188, 1_277, 1_356, 1_422, 1_491, 1_557, 1_617]
    private static let allpassTunings = [556, 441, 341, 225]
    private static let stereoSpread = 23
    private static let fixedGain: Float = 0.015
    private static let allpassFeedback: Float = 0.5

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: ReverbParams

        init(generation: UInt64, params: ReverbParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Prepared storage (main-actor allocated, render-thread used). One flat
    // block per line family; per-line offsets/lengths in fixed arrays.
    private var sampleRate: Double = 48_000
    /// Comb lines for both channels: [channel][comb] regions in one block.
    private var combStore: UnsafeMutablePointer<Float>?
    private var combLengths = [Int](repeating: 0, count: combCount * 2)
    private var combOffsets = [Int](repeating: 0, count: combCount * 2)
    private var combIndices = [Int](repeating: 0, count: combCount * 2)
    /// Damping one-pole state per (channel, comb).
    private var combFilterStore = [Float](repeating: 0, count: combCount * 2)
    private var combCapacity = 0
    /// Allpass lines for both channels: [channel][allpass] regions.
    private var allpassStore: UnsafeMutablePointer<Float>?
    private var allpassLengths = [Int](repeating: 0, count: allpassCount * 2)
    private var allpassOffsets = [Int](repeating: 0, count: allpassCount * 2)
    private var allpassIndices = [Int](repeating: 0, count: allpassCount * 2)
    private var allpassCapacity = 0
    /// Pre-delay line (mono input feed), sized for the MAX 200 ms.
    private var preDelayStore: UnsafeMutablePointer<Float>?
    private var preDelayCapacity = 0
    private var preDelayWriteIndex = 0

    // Render-thread-only derived params.
    private var lastGeneration = UInt64.max
    private var combFeedback: Float = 0.84   // 0.7 + 0.28 × 0.5
    private var damp: Float = 0.2            // 0.4 × 0.5
    private var mix: Float = 0.35
    private var preDelaySamples = 480
    private var width: Float = 1
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<ReverbParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: ReverbParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: ReverbParams = ReverbParams()) {
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
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
        combStore?.deallocate()
        allpassStore?.deallocate()
        preDelayStore?.deallocate()
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: ReverbParams) {
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
        let scale = sampleRate / 44_100.0

        // Comb + allpass line lengths at the prepared rate; right channel
        // offset by the scaled stereo spread. All regions live in one block.
        let spread = max(1, Int((Double(Self.stereoSpread) * scale).rounded()))
        var combTotal = 0
        for channel in 0..<2 {
            for comb in 0..<Self.combCount {
                let base = max(2, Int((Double(Self.combTunings[comb]) * scale).rounded()))
                let length = base + (channel == 1 ? spread : 0)
                let slot = channel * Self.combCount + comb
                combLengths[slot] = length
                combOffsets[slot] = combTotal
                combTotal += length
            }
        }
        if combCapacity != combTotal || combStore == nil {
            combStore?.deallocate()
            combStore = .allocate(capacity: combTotal)
            combCapacity = combTotal
        }
        var allpassTotal = 0
        for channel in 0..<2 {
            for allpass in 0..<Self.allpassCount {
                let base = max(2, Int((Double(Self.allpassTunings[allpass]) * scale).rounded()))
                let length = base + (channel == 1 ? spread : 0)
                let slot = channel * Self.allpassCount + allpass
                allpassLengths[slot] = length
                allpassOffsets[slot] = allpassTotal
                allpassTotal += length
            }
        }
        if allpassCapacity != allpassTotal || allpassStore == nil {
            allpassStore?.deallocate()
            allpassStore = .allocate(capacity: allpassTotal)
            allpassCapacity = allpassTotal
        }
        // Pre-delay sized for the MAX of the param range (200 ms) + 1, so any
        // published preDelayMs is a read-offset change, never an allocation.
        let maxPreDelay = Int((ReverbParams.preDelayRange.upperBound * 0.001 * sampleRate)
                              .rounded()) + 1
        if preDelayCapacity != maxPreDelay || preDelayStore == nil {
            preDelayStore?.deallocate()
            preDelayStore = .allocate(capacity: maxPreDelay)
            preDelayCapacity = maxPreDelay
        }
        clearRuntimeState()
        lastGeneration = .max  // re-derive at the new rate
    }

    var latencySamples: Int { 0 }

    /// Clears the tank + pre-delay (stop-time tail cut / un-bypass).
    func reset() {
        clearRuntimeState()
    }

    /// Render-thread safe: bounded clears of preallocated memory.
    private func clearRuntimeState() {
        combStore?.update(repeating: 0, count: combCapacity)
        allpassStore?.update(repeating: 0, count: allpassCapacity)
        preDelayStore?.update(repeating: 0, count: preDelayCapacity)
        for index in combIndices.indices { combIndices[index] = 0 }
        for index in allpassIndices.indices { allpassIndices[index] = 0 }
        for index in combFilterStore.indices { combFilterStore[index] = 0 }
        preDelayWriteIndex = 0
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
    /// math (pure arithmetic, no allocation; render-thread safe — the lines
    /// are sized for the MAX ranges, so preDelay is a read-offset change).
    private func deriveRenderParams(_ p: ReverbParams) {
        combFeedback = Float(0.7 + 0.28 * p.roomSize)
        damp = Float(0.4 * p.damping)
        mix = Float(p.mix)
        width = Float(p.width)
        preDelaySamples = min(preDelayCapacity - 1,
                              Int((p.preDelayMs * 0.001 * sampleRate).rounded()))
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .reverb)`: 0 roomSize, 1 damping, 2 mix,
    /// 3 preDelayMs, 4 width. Pokes a preallocated params copy and
    /// re-derives — no allocation, no locks.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...4).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.roomSize = value
        case 1: overlay.effective.damping = value
        case 2: overlay.effective.mix = value
        case 3: overlay.effective.preDelayMs = value
        default: overlay.effective.width = value
        }
        deriveRenderParams(overlay.effective)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard let combStore, let allpassStore, let preDelayStore else { return }

        let strideBytes = MemoryLayout<Float>.stride
        var channelData = InlineChannelPointers()
        var channelCount = 0
        var minFrames = frameCount
        for buffer in buffers where channelCount < 2 {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            channelData[channelCount] = data
            minFrames = min(minFrames, Int(buffer.mDataByteSize) / strideBytes)
            channelCount += 1
        }
        guard channelCount > 0, let left = channelData[0] else { return }
        let right = channelCount > 1 ? channelData[1] : nil

        let dryWrite = mix != 0  // mix 0: advance the tank, never write (bit-exact dry)
        let dryGain = 1 - mix
        let mixGain = mix
        let feedback = combFeedback
        let damp1 = damp
        let damp2 = 1 - damp

        for frame in 0..<minFrames {
            let dryL = left[frame]
            let dryR = right?[frame] ?? dryL

            // Mono feed × fixed gain, through the pre-delay line.
            let feed = (dryL + dryR) * Self.fixedGain
            preDelayStore[preDelayWriteIndex] = feed
            var readIndex = preDelayWriteIndex - preDelaySamples
            if readIndex < 0 { readIndex += preDelayCapacity }
            let input = preDelaySamples == 0 ? feed : preDelayStore[readIndex]
            preDelayWriteIndex += 1
            if preDelayWriteIndex == preDelayCapacity { preDelayWriteIndex = 0 }

            // 8 parallel damped combs + 4 series allpasses per channel.
            var wetL: Float = 0
            var wetR: Float = 0
            for channel in 0..<2 {
                var acc: Float = 0
                for comb in 0..<Self.combCount {
                    let slot = channel * Self.combCount + comb
                    let base = combOffsets[slot]
                    let index = combIndices[slot]
                    let output = combStore[base + index]
                    acc += output
                    // In-loop damping one-pole, denormal-flushed (the loop
                    // otherwise idles in subnormal territory on silence).
                    var filtered = output * damp2 + combFilterStore[slot] * damp1
                    if abs(filtered) < 1e-20 { filtered = 0 }
                    combFilterStore[slot] = filtered
                    combStore[base + index] = input + filtered * feedback
                    let next = index + 1
                    combIndices[slot] = next == combLengths[slot] ? 0 : next
                }
                for allpass in 0..<Self.allpassCount {
                    let slot = channel * Self.allpassCount + allpass
                    let base = allpassOffsets[slot]
                    let index = allpassIndices[slot]
                    var buffered = allpassStore[base + index]
                    if abs(buffered) < 1e-20 { buffered = 0 }
                    allpassStore[base + index] = acc + buffered * Self.allpassFeedback
                    acc = buffered - acc
                    let next = index + 1
                    allpassIndices[slot] = next == allpassLengths[slot] ? 0 : next
                }
                if channel == 0 { wetL = acc } else { wetR = acc }
            }

            guard dryWrite else { continue }
            // Width via mid/side on the wet only, then dry/wet crossfade.
            let midWet = (wetL + wetR) * 0.5
            let sideWet = (wetL - wetR) * 0.5 * width
            left[frame] = dryL * dryGain + (midWet + sideWet) * mixGain
            if let right {
                right[frame] = dryR * dryGain + (midWet - sideWet) * mixGain
            }
        }
    }
}
