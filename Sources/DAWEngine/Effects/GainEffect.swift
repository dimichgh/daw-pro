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
/// clamped finite (0...16, m27-c — was 0...4) by `GainParams`' clamping init.
/// The wider ceiling costs the render path nothing: this is still one multiply
/// per sample, and 16× a full-scale sample is ~24 dB inside Float32's range —
/// it can OVERDRIVE the mix (that is the point, and the caller's business) but
/// it cannot overflow, denormalize, or become non-finite.
///
/// POLARITY (m38-a): `GainParams.invertPolarity` is folded into the SIGN of
/// that same coefficient (`signedTarget`), so the render path stays exactly
/// one multiply per sample and a flip inherits the existing ~5 ms declick
/// ramp — +g to -g passes through zero by construction, a brief dip instead
/// of the full-scale discontinuity an instant flip would be. Magnitude is
/// still clamped to 0...16, so the coefficient lives in -16...16 and every
/// non-finite / denormal argument above holds unchanged.
final class GainEffect: EffectRendering, @unchecked Sendable {
    /// Immutable box crossing main actor → render thread. POD payload — no
    /// ARC or bridging work on the render-side read.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: RenderParams

        init(generation: UInt64, params: RenderParams) {
            self.generation = generation
            self.params = params
        }
    }

    /// The render-side POD params (m38-a). A struct rather than a bare Float
    /// because the automation overlay must carry BOTH knobs — slot 0 gain,
    /// slot 1 polarity — and poke either one without losing the other.
    private struct RenderParams {
        var gainLinear: Float
        var invertPolarity: Bool
    }

    /// THE fold (m38-a): polarity is not a second stage, it is the SIGN of the
    /// one coefficient the smoother already ramps. So an armed flip retargets
    /// +g → -g and the existing ~5 ms declick ramp walks it through zero — a
    /// brief dip, never a full-scale step. `invertPolarity == false` returns
    /// the identical Float the pre-m38-a code used, so nothing existing moves.
    private static func signedTarget(_ params: RenderParams) -> Float {
        params.invertPolarity ? -params.gainLinear : params.gainLinear
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
    private var overlay: AutomationParamOverlay<RenderParams>

    // Main-actor-only publish state (retire bin ≥ 1 s, PolySynth contract).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: GainParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: GainParams = GainParams()) {
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        lastAppliedParams = params
        let render = RenderParams(gainLinear: Float(params.gainLinear),
                                  invertPolarity: params.invertPolarity)
        overlay = AutomationParamOverlay(base: render)
        // Initial publish: nothing renders yet, so a plain exchange is safe.
        let snapshot = ParamSnapshot(generation: 0, params: render)
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
        let snapshot = ParamSnapshot(
            generation: publishedGeneration,
            params: RenderParams(gainLinear: Float(params.gainLinear),
                                 invertPolarity: params.invertPolarity))
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
        overlay.rebase(snapshot.params)
        setGainTarget(Self.signedTarget(snapshot.params), exact: firstAdoption)
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
    /// `EffectParamSpec.specs(for: .gain)`: 0 = gainLinear, 1 = invertPolarity
    /// (m38-a, binary at >= 0.5 — the store's own snap). Pokes the
    /// preallocated overlay copy and retargets — no allocation, no locks.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...1).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.gainLinear = Float(value)
        default: overlay.effective.invertPolarity = value >= 0.5
        }
        // Quantum step, ~5 ms declick — a polarity lane flip ramps through
        // zero exactly as a knob flip does.
        setGainTarget(Self.signedTarget(overlay.effective), exact: false)
    }

    /// m39-d CR-1 (`docs/design/2026-10-07-effect-control-rate.md` §5.3): the
    /// automated values stored at this control cell's entry still stand. Adopt
    /// FIRST, so a knob publish waiting in the slot is seen now, as a store
    /// would see it (then `overlay.hold()` answers false and the renderer
    /// re-stores). Render thread; no allocation, no lock.
    func holdAutomatedParams() -> Bool {
        adoptPendingParams()
        return overlay.hold()
    }

    /// m39-d CR-2 (design §5.4): deliberately a no-op — class (b): its own ~5 ms (240-frame)
    /// retarget ramp already carries across calls, and a hold (unlike a re-store) never restarts it
    /// — that restart is the reason the hold exists.
    func beginControlCell(frames: Int) {}

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished (republish without this effect, or
        // stop): the knob value restores — no main-actor republish needed.
        if overlay.endQuantum() {
            setGainTarget(Self.signedTarget(overlay.base), exact: false)
        }

        let stride = MemoryLayout<Float>.stride
        if rampRemaining == 0 {
            // Steady state: one exact constant multiply per channel. Unity
            // skips the pass entirely (bit-exact null by construction) — and
            // that skip is +1 ONLY, so an inverted unity (-1) correctly still
            // runs the pass (m38-a).
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
