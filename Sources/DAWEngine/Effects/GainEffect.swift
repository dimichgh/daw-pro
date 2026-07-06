import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// The built-in gain/trim insert (M4 ii) — the seam-proving effect: exactly
/// assertable output that exercises chain math, ordering, params, bypass, and
/// persistence end-to-end.
///
/// Parameter updates are RT-safe: `apply(params:)` publishes an immutable
/// snapshot through a heap `daw_atomic_ptr` with the ≥ 1 s retire bin —
/// verbatim the `PolySynthInstrument.apply` convention. The render side
/// smooths param CHANGES over ~5 ms (linear, zipper-free) but starts EXACTLY
/// at its prepared value, so offline chain-math tests assert exact
/// multiplication.
///
/// Render-path contract: `process()`/`reset()` allocate nothing, take no
/// locks, log nothing, touch no ObjC. Gain is memoryless (no feedback state),
/// so it can neither generate denormals nor blow up: the published value is
/// clamped finite (0...4) by `GainParams`' clamping init.
final class GainEffect: EffectRendering, @unchecked Sendable {
    /// Immutable box crossing main actor → render thread. POD payload — no
    /// ARC or bridging work on the render-side read.
    private final class ParamSnapshot {
        let generation: UInt64
        let gainLinear: Float

        init(generation: UInt64, gainLinear: Float) {
            self.generation = generation
            self.gainLinear = gainLinear
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Render-thread-only state.
    private var sampleRate: Double = 48_000
    private var currentGain: Float = 1
    private var targetGain: Float = 1
    private var rampRemaining = 0
    private var rampStep: Float = 0
    private var lastGeneration = UInt64.max  // .max forces exact first-quantum adoption
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<Float>

    // Main-actor-only publish state (retire bin ≥ 1 s, PolySynth contract).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: GainParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: GainParams = GainParams()) {
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        lastAppliedParams = params
        overlay = AutomationParamOverlay(base: Float(params.gainLinear))
        // Initial publish: nothing renders yet, so a plain exchange is safe.
        let snapshot = ParamSnapshot(generation: 0, gainLinear: Float(params.gainLinear))
        _ = daw_atomic_ptr_exchange(
            paramsSlot, UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque()))
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(paramsSlot, nil) {
            Unmanaged<ParamSnapshot>.fromOpaque(raw).release()
        }
        paramsSlot.deallocate()
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed, so the chain sync may call this on every
    /// parameter pass. Never republishes the chain snapshot.
    @MainActor
    func apply(params: GainParams) {
        guard params != lastAppliedParams else { return }
        lastAppliedParams = params
        publishedGeneration &+= 1
        let snapshot = ParamSnapshot(generation: publishedGeneration,
                                     gainLinear: Float(params.gainLinear))
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
        // Next process() adopts the published value EXACTLY — no ramp — so a
        // fresh (or re-prepared) chain multiplies exactly from frame 0.
        lastGeneration = .max
    }

    var latencySamples: Int { 0 }

    /// Adopts a newly published main-actor snapshot (borrowed — no
    /// retain/release; the retire bin guarantees its lifetime). Called at the
    /// top of `process()` AND by `storeAutomatedParam`, so an automation
    /// store never loses to a snapshot adopted later in the same quantum.
    private func adoptPendingParams() {
        guard let raw = daw_atomic_ptr_load(paramsSlot) else { return }
        let snapshot = Unmanaged<ParamSnapshot>.fromOpaque(raw).takeUnretainedValue()
        guard snapshot.generation != lastGeneration else { return }
        let firstAdoption = lastGeneration == .max
        lastGeneration = snapshot.generation
        overlay.rebase(snapshot.gainLinear)
        setGainTarget(snapshot.gainLinear, exact: firstAdoption)
    }

    /// One retargeting path for UI publishes, automation stores, and the
    /// automation revert: exact adoption (fresh/re-prepared chain multiplies
    /// exactly from frame 0) or the ~5 ms declick ramp. A no-change retarget
    /// in steady state is skipped, so a constant automated 1.0 keeps the
    /// unity bit-exact-skip path.
    private func setGainTarget(_ gain: Float, exact: Bool) {
        if exact {
            currentGain = gain
            targetGain = gain
            rampRemaining = 0
        } else {
            if gain == currentGain, gain == targetGain, rampRemaining == 0 { return }
            targetGain = gain
            rampRemaining = max(1, Int(0.005 * sampleRate))  // ~5 ms
            rampStep = (targetGain - currentGain) / Float(rampRemaining)
        }
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .gain)`: 0 = gainLinear. Pokes the
    /// preallocated overlay copy and retargets — no allocation, no locks.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard slot == 0, value.isFinite else { return }
        adoptPendingParams()
        overlay.beginStore()
        overlay.effective = Float(value)
        setGainTarget(Float(value), exact: false)  // quantum step, ~5 ms declick
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished (republish without this effect, or
        // stop): the knob value restores — no main-actor republish needed.
        if overlay.endQuantum() {
            setGainTarget(overlay.base, exact: false)
        }

        let stride = MemoryLayout<Float>.stride
        if rampRemaining == 0 {
            // Steady state: one exact constant multiply per channel. Unity
            // skips the pass entirely (bit-exact null by construction).
            guard currentGain != 1 else { return }
            let gain = currentGain
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = min(frameCount, Int(buffer.mDataByteSize) / stride)
                for frame in 0..<frames {
                    data[frame] *= gain
                }
            }
        } else {
            // Ramp active: frame-major so every channel sees the SAME gain at
            // a given frame. Channel counts here are tiny (stereo).
            for frame in 0..<frameCount {
                if rampRemaining > 0 {
                    rampRemaining -= 1
                    currentGain = rampRemaining == 0 ? targetGain : currentGain + rampStep
                }
                let gain = currentGain
                for buffer in buffers {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self),
                          frame < Int(buffer.mDataByteSize) / stride else { continue }
                    data[frame] *= gain
                }
            }
        }
    }

    /// Gain holds no audio tails; reset kills any in-flight ramp so
    /// post-reset output is exact immediately.
    func reset() {
        currentGain = targetGain
        rampRemaining = 0
    }
}
