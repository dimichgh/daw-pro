import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in feedback flanger (m39-j) — ONE interpolated delay tap per channel,
/// swept by an LFO, with BIPOLAR feedback.
/// `docs/design/2026-09-19-creative-effects.md` §6.3 is the frozen contract.
///
/// ⭐ THIS IS THE SECOND CALLER OF `InterpolatedDelayLine` (§4.1), and it is the
/// second caller ON PURPOSE: the flanger is the cheapest structure that would
/// expose a wrong home, because it needs everything the chorus needed PLUS the
/// one axis the chorus never exercised — feedback. The home fits unchanged; the
/// two things a feedback caller has to bring itself are written out below.
///
/// WHAT IT DOES, in the order the render path does it, per channel per sample:
///   1. **Tap** the line at `delayMs + depthMs · (0.5 + 0.5·sin φ)` samples
///      behind the write head, fractionally interpolated.
///   2. **Flush** that tapped value if it is denormally small (see below).
///   3. **Write** `dry + tapped · feedback` at the write head. This is the
///      recirculation, and it is why the order is tap-before-write: the value
///      being written DEPENDS on the value just read.
///   4. **Mix** — `out = dry·(1−m) + tapped·m`. At `m == 0` exactly, THE BUFFER
///      IS NEVER WRITTEN — bit-exact dry by IEEE (rule 6.0.7) — while the line
///      and the LFO keep running, so raising `mix` later picks up mid-sweep
///      rather than jumping (the `ChorusEffect` convention).
///   5. **Advance** the single shared write head once per FRAME, after both
///      channels have been tapped and written.
///
/// Summing a signal with a delayed copy of itself produces a COMB — notches at
/// the odd multiples of `1/(2·delay)` (`FlangerParams.combNotchHz`), peaks
/// halfway between. Sweeping the delay slides the whole comb, and that is the
/// jet-plane whoosh. Feedback recirculates the delayed copy and sharpens the
/// peaks into resonances; NEGATIVE feedback inverts the pattern, which is the
/// hollow/metallic side and is why the range crosses zero.
///
/// ⛔ **THE SWEEP IS UPWARD-ONLY (§6.3.2), AND THAT LAW LIVES IN DAWCore.**
/// `FlangerParams.sweptDelayMs(phaseRadians:delayMs:depthMs:)` is its ONE HOME;
/// this file calls it and never re-derives it. A bipolar sweep
/// (`delayMs + depthMs·sin φ`) goes NEGATIVE whenever `depthMs > delayMs`, and
/// both ranges are `0.1 … 10`, so the default surface permits that trivially.
/// Modulating upward from a floor removes the failure mode instead of clamping
/// it (which flattens the sweep bottom and sounds broken) or branching around
/// it (which hides the mistake in the inner loop). Consequence worth stating:
/// there is NO render-thread bounds check on the delay, here or in the home,
/// and none is needed — the arithmetic cannot leave `[delayMs, delayMs+depthMs]`
/// and `prepare()` has already proved that interval fits the line.
///
/// ⛔ **THE DENORMAL FLUSH IS THIS FILE'S JOB, NOT THE LINE'S (§4.1).**
/// `InterpolatedDelayLine` deliberately carries no flushing: the chorus is
/// feedback-free and provably cannot generate denormals, so a per-sample branch
/// in the home would tax a caller that does not need one. A flanger IS a
/// feedback structure — on silence the line decays as `feedback^n` and lands in
/// subnormal territory, where every operation costs orders of magnitude more,
/// on the render thread, during silence, which is exactly when nobody is
/// looking. The flush is `abs(x) < 1e-20`, matching `DelayEffect.swift`'s
/// existing `if abs(lpL) < 1e-20 { lpL = 0 }` rather than inventing a second
/// approach, and it sits on the TAPPED value — the only recirculating word this
/// effect owns. Flushing there means the line is never fed a denormal in the
/// first place, and the output never carries one either.
///
/// SMOOTHING (rule 6.0.6 — a new creative effect smooths its own derived state
/// internally): effect params arrive as ONE SCALAR PER QUANTUM, so the LFO
/// phase increment, the delay floor, the sweep depth, the feedback coefficient,
/// the mix gain and the stereo phase offset are all interpolated **per sample**
/// across the quantum. Feedback and mix especially: both multiply the signal
/// directly, and a per-quantum step in either is an audible click at a 10.7 ms
/// cadence. There are no `sin`/`cos` COEFFICIENTS here (the LFO's own `sin` is
/// per-sample, as in `ChorusEffect`), so this effect has no 32-frame stride.
/// ⚠️ THE LFO PHASE IS NEVER RESET BY A PARAMETER CHANGE. `reset()` clears it
/// (a stop-time cut); `apply`/`storeAutomatedParam` never do, so an automated
/// rate change speeds the sweep up without jumping the comb.
///
/// Parameter updates follow the `GainEffect` atomic-POD-publish convention.
/// Render-path contract: `process()`/`reset()` allocate nothing, take no locks,
/// log nothing, touch no ObjC, hop no actors. The line is preallocated in
/// `prepare()` for `FlangerParams.lineCapacitySeconds` (20 ms — the largest
/// delay the upward sweep can reach), so every parameter move is arithmetic and
/// never an allocation.
final class FlangerEffect: EffectRendering, @unchecked Sendable {
    /// Denormal-flush threshold for the recirculating tap — `DelayEffect`'s
    /// existing constant and its existing shape, deliberately not a second one.
    /// −400 dB: far below anything audible, far above the subnormal boundary
    /// (~1.18e-38 for `Float`), so the tail is cut before it ever gets slow.
    private static let denormalFloor: Float = 1e-20

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: FlangerParams

        init(generation: UInt64, params: FlangerParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Prepared storage (main-actor allocated, render-thread used).
    private var sampleRate: Double = 48_000
    /// THE SHARED HOME (§4.1), used unchanged. Capacity is declared in SECONDS
    /// from `FlangerParams.lineCapacitySeconds` — the ONE HOME for the 20 ms
    /// number — and `.linear` interpolation is the home's safe default, which
    /// the design forbids "improving" to `.cubicHermite`.
    private let line = InterpolatedDelayLine(
        capacitySeconds: FlangerParams.lineCapacitySeconds, interpolation: .linear)

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    /// LFO phase in RADIANS, [0, 2π). The LEFT channel's phase; the right
    /// channel reads it plus `stereoOffset`.
    private var phase = 0.0

    // Interpolation endpoints. `previous*` is where the last quantum ENDED,
    // `target*` is what this quantum was asked for. All in RENDER units.
    private var previousIncrement = 2.0 * .pi * 0.3 / 48_000.0
    private var targetIncrement = 2.0 * .pi * 0.3 / 48_000.0
    private var previousDelayMs = 1.0
    private var targetDelayMs = 1.0
    private var previousDepthMs = 3.0
    private var targetDepthMs = 3.0
    private var previousFeedback = 0.5
    private var targetFeedback = 0.5
    private var previousMix = 0.5
    private var targetMix = 0.5
    private var previousOffset = Double.pi / 2
    private var targetOffset = Double.pi / 2
    /// Set by `prepare`/`reset`: the next quantum starts AT its target instead
    /// of sweeping into it from a stale value.
    private var needsPrime = true

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<FlangerParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: FlangerParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: FlangerParams = FlangerParams()) {
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
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: FlangerParams) {
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
        // The SHALLOWEST delay the upward-only sweep can ever reach is the
        // sweep FLOOR at its own minimum — `delayRange.lowerBound`, 0.1 ms —
        // because the LFO only ever adds. That is the invariant the home checks
        // once, here, off the render thread. At 44.1 kHz it is 4.41 samples and
        // at 48 kHz 4.8, comfortably above `.linear`'s 1-sample stencil floor;
        // a refusal needs a sample rate below 10 kHz, which CoreAudio does not
        // deliver, and it leaves the line unprepared so `process` passes the
        // buffer through bit-exact dry rather than reading its own write head.
        let minDelaySamples = FlangerParams.delayRange.lowerBound * 0.001 * sampleRate
        // ALWAYS two channels: the render path duplicates a mono input into the
        // right line so a later stereo quantum is phase-coherent.
        do {
            try line.prepare(sampleRate: sampleRate, minDelaySamples: minDelaySamples,
                             channelCount: 2)
        } catch {
            // Not swallowed: the refusal IS `line.isPrepared == false`, which
            // the render path reads every quantum.
        }
        clearRuntimeState()
        lastGeneration = .max  // re-derive at the new rate
    }

    var latencySamples: Int { 0 }

    /// Clears the line and restarts the LFO (stop-time cut / un-bypass).
    func reset() {
        clearRuntimeState()
    }

    /// Render-thread safe: a bounded clear of preallocated memory plus a
    /// handful of stores.
    private func clearRuntimeState() {
        line.reset()
        phase = 0
        needsPrime = true
    }

    /// Adopts a newly published main-actor snapshot (borrowed — retire bin
    /// guarantees lifetime). Called at the top of `process()` AND by
    /// `storeAutomatedParam`, so an automation store never loses to a snapshot
    /// adopted later in the same quantum.
    private func adoptPendingParams() {
        guard let raw = daw_atomic_ptr_load(paramsSlot) else { return }
        let snapshot = Unmanaged<ParamSnapshot>.fromOpaque(raw).takeUnretainedValue()
        guard snapshot.generation != lastGeneration else { return }
        lastGeneration = snapshot.generation
        overlay.rebase(snapshot.params)
        deriveRenderParams(snapshot.params)
    }

    /// Captures this quantum's interpolation TARGETS. Generation changes,
    /// automation stores and the automation revert all route through here, so
    /// there is exactly one place where a parameter becomes a render value.
    ///
    /// ⚠️ EVERY FIELD IS RE-GUARDED AND RE-CLAMPED, AND HERE THAT IS A MEMORY-
    /// SAFETY REQUIREMENT, NOT A TIDINESS ONE. A field-by-field overlay poke
    /// (`storeAutomatedParam`) bypasses `FlangerParams.init`, so the clamping
    /// the init does is NOT in force. `delayMs` and `depthMs` sum into a delay
    /// that reaches `Int(delay)` inside `InterpolatedDelayLine.tap`, and that
    /// line has NO render-thread bounds check by design (§4.1): an unclamped
    /// 50 ms would read off the end of a 20 ms line, and `Int(Double.nan)`
    /// TRAPS outright. `feedback` unclamped would be an unstable recirculation.
    /// (The `BitCrusherParams.bits` precedent, same shape, worse consequence.)
    private func deriveRenderParams(_ p: FlangerParams) {
        let rate = (p.rateHz.isFinite ? p.rateHz : 0.3).clamped(to: FlangerParams.rateRange)
        targetIncrement = 2.0 * .pi * rate / sampleRate
        targetDelayMs = (p.delayMs.isFinite ? p.delayMs : 1.0)
            .clamped(to: FlangerParams.delayRange)
        targetDepthMs = (p.depthMs.isFinite ? p.depthMs : 3)
            .clamped(to: FlangerParams.depthRange)
        targetFeedback = (p.feedback.isFinite ? p.feedback : 0.5)
            .clamped(to: FlangerParams.feedbackRange)
        targetMix = (p.mix.isFinite ? p.mix : 0.5).clamped(to: FlangerParams.mixRange)
        // THROUGH THE LAW, never a second copy of the degrees→radians math.
        targetOffset = FlangerParams.stereoPhaseOffsetRadians(stereoPhaseDeg: p.stereoPhaseDeg)
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .flanger)`: 0 rateHz, 1 depthMs, 2 delayMs,
    /// 3 feedback, 4 mix, 5 stereoPhaseDeg. Pokes a preallocated params copy
    /// and re-derives — no allocation, no locks. The LFO phase and the line are
    /// untouched, so an automated sweep stays continuous.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...5).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.rateHz = value
        case 1: overlay.effective.depthMs = value
        case 2: overlay.effective.delayMs = value
        case 3: overlay.effective.feedback = value
        case 4: overlay.effective.mix = value
        default: overlay.effective.stereoPhaseDeg = value
        }
        deriveRenderParams(overlay.effective)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard line.isPrepared, frameCount > 0 else { return }

        if needsPrime {
            previousIncrement = targetIncrement
            previousDelayMs = targetDelayMs
            previousDepthMs = targetDepthMs
            previousFeedback = targetFeedback
            previousMix = targetMix
            previousOffset = targetOffset
            needsPrime = false
        }

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
        guard channelCount > 0, minFrames > 0, let left = channelData[0] else { return }
        let right = channelCount > 1 ? channelData[1] : nil

        let span = Double(minFrames)
        let incrementDelta = (targetIncrement - previousIncrement) / span
        let delayDelta = (targetDelayMs - previousDelayMs) / span
        let depthDelta = (targetDepthMs - previousDepthMs) / span
        let feedbackDelta = (targetFeedback - previousFeedback) / span
        let mixDelta = (targetMix - previousMix) / span
        let offsetDelta = (targetOffset - previousOffset) / span
        let msToSamples = 0.001 * sampleRate
        let denormalFloor = Self.denormalFloor

        var increment = previousIncrement
        var delayMs = previousDelayMs
        var depthMs = previousDepthMs
        var feedback = previousFeedback
        var mix = previousMix
        var offset = previousOffset
        var lfo = phase

        // ⚠️ `while`, not `for i in 0..<n` — measured at
        // `EffectChainProcessor.swift:402-412`, a `Range` iteration raises
        // ~2 malloc/free events PER ITERATION at `-Onone`, which is why the
        // allocation gates can assert an absolute zero.
        var frame = 0
        while frame < minFrames {
            let dryL = left[frame]
            let dryR = right?[frame] ?? dryL
            let feedbackGain = Float(feedback)
            let dryGain = Float(1 - mix)
            let mixGain = Float(mix)

            // THE §6.3.2 LAW, through its one home — upward only, so the result
            // is always >= delayMs >= 0.1 ms and never approaches the write
            // head. `sweptDelayMs` re-guards its own inputs.
            let delaySamplesL = FlangerParams.sweptDelayMs(
                phaseRadians: lfo, delayMs: delayMs, depthMs: depthMs) * msToSamples

            // TAP BEFORE WRITE: the value written is the value just read. This
            // is the recirculation, and it is the whole difference between this
            // caller and the feedback-free chorus.
            var wetL = line.tap(channel: 0, delaySamples: delaySamplesL)
            // THE FLUSH THE HOME DELIBERATELY DOES NOT DO (§4.1). Cutting the
            // tap kills the denormal in the recirculation AND in the output,
            // because both read this one word.
            if abs(wetL) < denormalFloor { wetL = 0 }
            line.write(channel: 0, dryL + wetL * feedbackGain)

            var wetR: Float = 0
            if right != nil {
                let delaySamplesR = FlangerParams.sweptDelayMs(
                    phaseRadians: lfo + offset, delayMs: delayMs, depthMs: depthMs) * msToSamples
                wetR = line.tap(channel: 1, delaySamples: delaySamplesR)
                if abs(wetR) < denormalFloor { wetR = 0 }
                line.write(channel: 1, dryR + wetR * feedbackGain)
            } else {
                // Mono input: keep the right line fed with the same material so
                // a later stereo quantum is phase-coherent rather than starting
                // from silence (the `ChorusEffect` convention).
                var mirrored = line.tap(channel: 1, delaySamples: delaySamplesL)
                if abs(mirrored) < denormalFloor { mirrored = 0 }
                line.write(channel: 1, dryR + mirrored * feedbackGain)
            }

            // `mix == 0` is the BIT-EXACT DRY path: the line and the LFO above
            // still ran (so a later mix raise is phase-coherent), the buffer is
            // simply never touched. `mix` reaches exactly 0 by arithmetic, not
            // by an epsilon — a knob parked at 0 gives a 0 target and a 0 delta.
            if mix != 0 {
                left[frame] = dryL * dryGain + wetL * mixGain
                if let right {
                    right[frame] = dryR * dryGain + wetR * mixGain
                }
            }

            // ONE advance per FRAME, after both channels are written.
            line.advance()

            lfo += increment
            if lfo >= 2.0 * .pi { lfo -= 2.0 * .pi }
            increment += incrementDelta
            delayMs += delayDelta
            depthMs += depthDelta
            feedback += feedbackDelta
            mix += mixDelta
            offset += offsetDelta
            frame += 1
        }

        phase = lfo

        previousIncrement = targetIncrement
        previousDelayMs = targetDelayMs
        previousDepthMs = targetDepthMs
        previousFeedback = targetFeedback
        previousMix = targetMix
        previousOffset = targetOffset
    }
}
