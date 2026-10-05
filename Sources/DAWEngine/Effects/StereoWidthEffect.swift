import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in mid/side stereo widener and mono-maker (m23-dj).
/// `docs/ROADMAP.md:1190` is the item; `StereoWidthParams` carries the frozen
/// laws and the argument for them.
///
/// ⛔ **THE ONE STRUCTURAL LAW, AND EVERY LINE BELOW OBEYS IT: THE MID IS
/// NEVER TOUCHED.** Per sample:
///
///   1. **Split** — `M = (L+R)·0.5`, `S = (L-R)·0.5`.
///   2. **Decorrelate** — push `M` through four cascaded Schroeder all-pass
///      stages (`StereoWidthParams.decorrelationDelaysMs`). An all-pass has
///      unit magnitude at every frequency, so this changes WHEN each partial
///      arrives and not HOW LOUD it is.
///   3. **Build the new side** — `S' = width·S + spread·A(M)`.
///   4. **Protect the low end** — high-pass `S'` at `bassMonoHz` (two cascaded
///      one-poles, 12 dB/oct) and crossfade toward that high-passed version by
///      `bassMonoAmount`, so at 1 there is no side content below the corner.
///   5. **Recombine** — `L' = M + S'`, `R' = M - S'`.
///
/// Therefore `L' + R' = 2·M = L + R` at EVERY setting: the mono fold-down is
/// the dry mono fold-down, to within a couple of float ULPs. That is this
/// item's acceptance test and it holds by construction rather than by tuning.
/// A Haas widener (one side delayed 5-30 ms) and a polarity-flipped duplicate
/// both fail it, loudly, on the speaker the user does not own.
///
/// ⚠️ **WHAT IT COSTS, AND IT IS NOT HIDEABLE.** With `S' = spread·A(M)` the
/// channels are `M·(1 ± spread·A)`, so each one alone ripples between
/// `1 - spread` and `1 + spread` — `StereoWidthParams.channelPeakDb` /
/// `channelNotchDb`. The peaks of one channel sit at the notches of the other,
/// which is exactly what makes it sound wide, and they cancel EXACTLY in the
/// sum. The alternative arrangement (a different all-pass per channel) gives
/// flat channels and a combed sum, and that is the failure this item was filed
/// to refuse. There is no third option; this one is chosen deliberately.
///
/// ⛔ **BIT-EXACT AT THE NEUTRAL POSITION (rule 6.0.7), AND IT CANNOT BE DONE
/// BY ARITHMETIC.** A mid/side round trip is NOT an identity in IEEE floating
/// point — `0.5·(L+R) + 0.5·(L-R)` loses `L` entirely when `R` dwarfs it — so
/// the neutral case is an explicit early-out: the buffer is never written.
/// `StereoWidthParams.isNeutral` is the one home for the condition, and the
/// check reads BOTH the interpolation endpoints, so a quantum that is still
/// ramping out of a non-neutral setting takes the normal path and reaches
/// bypass one quantum later, without a click. The decorrelator and the
/// crossover keep running underneath (the `ChorusEffect` convention) so a
/// later `spread` raise opens into a settled image.
///
/// ⛔ **THE DENORMAL FLUSH IS THIS FILE'S JOB, NOT THE LINE'S (§4.1).** All
/// four all-pass stages are feedback structures: on silence each decays as
/// `g^n` into subnormal territory, where every operation costs orders of
/// magnitude more, on the render thread, during silence, which is exactly when
/// nobody is looking. The flush is `abs(x) < 1e-20` on the value WRITTEN into
/// each line (so the line is never fed a denormal) and on both crossover
/// one-poles, matching `DelayEffect.swift`'s existing constant rather than
/// inventing a second approach.
///
/// SMOOTHING (rule 6.0.6 — a new creative effect smooths its own derived state
/// internally): effect params arrive as ONE SCALAR PER QUANTUM, and all three
/// gains here multiply the signal directly, so `width`, `spread`, the bass-mono
/// amount and the crossover COEFFICIENT are interpolated **per sample** across
/// the quantum. The coefficient is interpolated directly rather than re-derived
/// (the `TapeDelayEffect` precedent), so there is no `exp` in the inner loop
/// and no 32-frame stride. Each endpoint is SNAPPED to its target at the end of
/// the quantum, not left at whatever the accumulation landed on — otherwise
/// `width` would settle at 0.99999994 and the bypass would never re-engage.
///
/// ⚠️ **MONO BUFFERS PASS THROUGH UNTOUCHED.** A single-channel buffer has no
/// left/right to be wide, and inventing a second channel is not this seam's
/// job (effects process IN PLACE). The graph format is stereo deinterleaved
/// throughout, so a mono SOURCE arrives as two identical channels and `spread`
/// works on it exactly as intended; the one-channel case is the degenerate
/// path, and it is bit-exact.
///
/// Parameter updates follow the `GainEffect` atomic-POD-publish convention.
/// Render-path contract: `process()`/`reset()` allocate nothing, take no locks,
/// log nothing, touch no ObjC, hop no actors. The four lines are preallocated
/// in `prepare()` for `StereoWidthParams.lineCapacitySeconds`, so no parameter
/// move can ever resize anything. `latencySamples` is 0: the dry mid path has
/// no delay in it at all, and the all-pass chain's group delay is dispersion
/// inside a manufactured side signal, not a delayed copy of the input that PDC
/// could or should align.
final class StereoWidthEffect: EffectRendering, @unchecked Sendable {
    /// Denormal-flush threshold — `DelayEffect`'s existing constant and its
    /// existing shape, deliberately not a second one. −400 dB: far below
    /// anything audible, far above the subnormal boundary (~1.18e-38 for
    /// `Float`).
    private static let denormalFloor: Float = 1e-20

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: StereoWidthParams

        init(generation: UInt64, params: StereoWidthParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Prepared storage (main-actor allocated, render-thread used).
    private var sampleRate: Double = 48_000

    /// THE FOUR DECORRELATOR STAGES, each on the shared `InterpolatedDelayLine`
    /// home (§4.1), used unchanged and MONO — the chain runs on the mid only,
    /// so one channel each. Delays are whole samples, so the home's linear
    /// interpolator returns `s0 + (s1 - s0) * 0` = `s0` exactly and the stage
    /// stays exactly all-pass. They are spelled out rather than held in an
    /// array because the render loop is unrolled: a `for` over a collection is
    /// the allocation shape the gates assert an absolute zero against.
    private let stage0 = InterpolatedDelayLine(
        capacitySeconds: StereoWidthParams.lineCapacitySeconds, interpolation: .linear)
    private let stage1 = InterpolatedDelayLine(
        capacitySeconds: StereoWidthParams.lineCapacitySeconds, interpolation: .linear)
    private let stage2 = InterpolatedDelayLine(
        capacitySeconds: StereoWidthParams.lineCapacitySeconds, interpolation: .linear)
    private let stage3 = InterpolatedDelayLine(
        capacitySeconds: StereoWidthParams.lineCapacitySeconds, interpolation: .linear)

    /// Whole-sample stage delays, derived once in `prepare()`.
    private var delay0 = 629.0
    private var delay1 = 398.0
    private var delay2 = 245.0
    private var delay3 = 139.0

    /// The last `prepare()` refusal from any stage, or nil. Kept for the same
    /// reason `TapeDelayEffect` keeps it: the observable symptom of a refusal
    /// is a silently missing `spread`, and a test that cannot see the refusal
    /// would measure "no width" and call it a DSP bug.
    private(set) var lastPrepareRefusal: InterpolatedDelayLine.PrepareRefusal?

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    /// The two one-pole low-pass words behind the bass-mono crossover. Each
    /// one is subtracted from its own input, so the pair is TWO CASCADED
    /// HIGH-PASSES (12 dB/oct) and not one cascaded low-pass subtracted once
    /// (which would be 6 dB/oct with a +6 dB lift — see `process`).
    private var crossLowA: Float = 0
    private var crossLowB: Float = 0

    // Interpolation endpoints. `previous*` is where the last quantum ENDED,
    // `target*` is what this quantum was asked for.
    private var previousWidth = 1.0
    private var targetWidth = 1.0
    private var previousSpread = 0.3
    private var targetSpread = 0.3
    private var previousBassMono = 1.0
    private var targetBassMono = 1.0
    private var previousCrossCoeff = 0.0
    private var targetCrossCoeff = 0.0
    /// Set by `prepare`/`reset`: the next quantum starts AT its target instead
    /// of sweeping into it from a stale value.
    private var needsPrime = true

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<StereoWidthParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: StereoWidthParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: StereoWidthParams = StereoWidthParams()) {
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
    func apply(params: StereoWidthParams) {
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
        let delays = StereoWidthParams.decorrelationDelaysMs
        // Whole samples: a fractional tap inside an all-pass feedback path is
        // no longer exactly all-pass (linear interpolation is a mild low-pass)
        // and the energy preservation is what bounds the per-channel ripple at
        // `1 ± spread`. `.rounded()` never exceeds `ceil`, so a tap at the
        // longest stage still fits the declared capacity plus the home's
        // stencil margin.
        delay0 = (delays[0] * 0.001 * sampleRate).rounded()
        delay1 = (delays[1] * 0.001 * sampleRate).rounded()
        delay2 = (delays[2] * 0.001 * sampleRate).rounded()
        delay3 = (delays[3] * 0.001 * sampleRate).rounded()
        // The SHALLOWEST delay any stage can ever ask for. It is a constant —
        // nothing modulates these lengths — so the invariant the home checks
        // once, here, off the render thread, is simply the shortest stage. A
        // refusal needs a sample rate under ~350 Hz, which CoreAudio does not
        // deliver, and it leaves the lines unprepared so `spread` contributes
        // nothing rather than reading a write head.
        let minDelaySamples = min(delay0, delay1, delay2, delay3)
        lastPrepareRefusal = nil
        for line in [stage0, stage1, stage2, stage3] {
            do {
                try line.prepare(sampleRate: sampleRate, minDelaySamples: minDelaySamples,
                                 channelCount: 1)
            } catch let refusal as InterpolatedDelayLine.PrepareRefusal {
                // NOT swallowed: it is recorded here for the tests and it IS
                // `line.isPrepared == false`, which the render path reads every
                // quantum through `decorrelationReady`.
                lastPrepareRefusal = refusal
            } catch {
                lastPrepareRefusal = .nonPositiveSampleRate(sampleRate)
            }
        }
        clearRuntimeState()
        lastGeneration = .max  // re-derive at the new rate
    }

    var latencySamples: Int { 0 }

    /// Clears the decorrelator and the crossover (stop-time cut / un-bypass).
    func reset() {
        clearRuntimeState()
    }

    /// Render-thread safe: bounded clears of preallocated memory plus a handful
    /// of stores.
    private func clearRuntimeState() {
        stage0.reset()
        stage1.reset()
        stage2.reset()
        stage3.reset()
        crossLowA = 0
        crossLowB = 0
        needsPrime = true
    }

    /// True when all four decorrelator stages prepared. False leaves `spread`
    /// inert while `width` and the bass-mono stage keep working — an honest
    /// degradation, not a silent one: `lastPrepareRefusal` names the reason.
    private var decorrelationReady: Bool {
        stage0.isPrepared && stage1.isPrepared && stage2.isPrepared && stage3.isPrepared
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
    /// ⚠️ EVERY FIELD IS RE-GUARDED AND RE-CLAMPED. A field-by-field overlay
    /// poke (`storeAutomatedParam`) bypasses `StereoWidthParams.init`, so the
    /// clamping the init does is NOT in force. No value here reaches an `Int()`
    /// conversion (the taps are prepare-time constants), so this is not the
    /// memory-safety case the flanger and tape delay have — but a NaN `width`
    /// would silence the strip permanently through the interpolation
    /// accumulator, and a NaN `bassMonoHz` would poison the crossover
    /// coefficient with no path back. (The `BitCrusherParams.bits` precedent.)
    private func deriveRenderParams(_ p: StereoWidthParams) {
        targetWidth = (p.width.isFinite ? p.width : 1)
            .clamped(to: StereoWidthParams.widthRange)
        targetSpread = (p.spread.isFinite ? p.spread : 0.3)
            .clamped(to: StereoWidthParams.spreadRange)
        targetBassMono = (p.bassMonoAmount.isFinite ? p.bassMonoAmount : 1)
            .clamped(to: StereoWidthParams.bassMonoAmountRange)
        // THROUGH THE LAW, never a second copy of the one-pole mapping. ONE
        // `exp` per quantum; the coefficient itself is what interpolates.
        targetCrossCoeff = StereoWidthParams.onePoleCoefficient(
            cutoffHz: p.bassMonoHz, sampleRate: sampleRate)
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .stereoWidth)`: 0 width, 1 spread,
    /// 2 bassMonoHz, 3 bassMonoAmount. Pokes a preallocated params copy and
    /// re-derives — no allocation, no locks. The decorrelator lines and the
    /// crossover state are untouched, so an automated width ride stays
    /// continuous.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...3).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.width = value
        case 1: overlay.effective.spread = value
        case 2: overlay.effective.bassMonoHz = value
        default: overlay.effective.bassMonoAmount = value
        }
        deriveRenderParams(overlay.effective)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard frameCount > 0 else { return }

        if needsPrime {
            previousWidth = targetWidth
            previousSpread = targetSpread
            previousBassMono = targetBassMono
            previousCrossCoeff = targetCrossCoeff
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
        // A mono buffer has no image to widen and no second channel to write
        // one into, so it passes through BIT-EXACT. The decorrelator is
        // deliberately NOT fed here (unlike the flanger's mirrored line): a
        // channel-count change arrives through `prepare()`, which resets every
        // stage anyway, so there is no stereo quantum for a mono one to have
        // kept coherent.
        guard channelCount > 1, let right = channelData[1] else { return }

        // ⛔ THE BIT-EXACT BYPASS, hoisted out of the inner loop. BOTH
        // endpoints must be neutral: a quantum still ramping DOWN to neutral
        // takes the normal path and reaches bypass on the next one, which is
        // what keeps a width move from ending in a click. `previous*` is
        // SNAPPED to `target*` below, so "still ramping" is an exact test and
        // not an epsilon one.
        let neutral =
            StereoWidthParams.isNeutral(width: targetWidth, spread: targetSpread,
                                        bassMonoAmount: targetBassMono)
            && StereoWidthParams.isNeutral(width: previousWidth, spread: previousSpread,
                                           bassMonoAmount: previousBassMono)
        let ready = decorrelationReady

        let span = Double(minFrames)
        let widthDelta = (targetWidth - previousWidth) / span
        let spreadDelta = (targetSpread - previousSpread) / span
        let bassDelta = (targetBassMono - previousBassMono) / span
        let coeffDelta = (targetCrossCoeff - previousCrossCoeff) / span
        let denormalFloor = Self.denormalFloor
        let allpassG = Float(StereoWidthParams.decorrelationCoefficient)

        var width = previousWidth
        var spread = previousSpread
        var bassMono = previousBassMono
        var coeff = previousCrossCoeff
        var lowA = crossLowA
        var lowB = crossLowB

        // ⚠️ `while`, not `for i in 0..<n` — measured at
        // `EffectChainProcessor.swift:402-412`, a `Range` iteration raises
        // ~2 malloc/free events PER ITERATION at `-Onone`, which is why the
        // allocation gates can assert an absolute zero.
        var frame = 0
        while frame < minFrames {
            let dryL = left[frame]
            let dryR = right[frame]
            let mid = (dryL + dryR) * 0.5
            let side = (dryL - dryR) * 0.5

            // ── The decorrelator: four cascaded Schroeder all-passes on the
            // MID. Tap BEFORE write at every stage — `v[n]` depends on
            // `v[n-D]`, which is the recirculation. Each written value is
            // denormal-flushed, so no line is ever fed a subnormal and the
            // chain's output can never carry one either.
            var decorrelated: Float = 0
            if ready {
                var x = mid

                var d0 = stage0.tap(channel: 0, delaySamples: delay0)
                var v0 = x + allpassG * d0
                if abs(v0) < denormalFloor { v0 = 0 }
                stage0.write(channel: 0, v0)
                if abs(d0) < denormalFloor { d0 = 0 }
                x = d0 - allpassG * v0

                var d1 = stage1.tap(channel: 0, delaySamples: delay1)
                var v1 = x + allpassG * d1
                if abs(v1) < denormalFloor { v1 = 0 }
                stage1.write(channel: 0, v1)
                if abs(d1) < denormalFloor { d1 = 0 }
                x = d1 - allpassG * v1

                var d2 = stage2.tap(channel: 0, delaySamples: delay2)
                var v2 = x + allpassG * d2
                if abs(v2) < denormalFloor { v2 = 0 }
                stage2.write(channel: 0, v2)
                if abs(d2) < denormalFloor { d2 = 0 }
                x = d2 - allpassG * v2

                var d3 = stage3.tap(channel: 0, delaySamples: delay3)
                var v3 = x + allpassG * d3
                if abs(v3) < denormalFloor { v3 = 0 }
                stage3.write(channel: 0, v3)
                if abs(d3) < denormalFloor { d3 = 0 }
                x = d3 - allpassG * v3

                decorrelated = x

                stage0.advance()
                stage1.advance()
                stage2.advance()
                stage3.advance()
            }

            // ── The new side channel, and then the low-end protection.
            let built = side * Float(width) + decorrelated * Float(spread)
            // ⛔ TWO CASCADED ONE-POLE HIGH-PASSES, AND THE ORDER OF THE
            // SUBTRACTION IS LOAD-BEARING. `x - lowpass(x)` is a 6 dB/oct
            // high-pass; cascading THAT twice gives 12 dB/oct, which is what
            // "mono below 120 Hz" claims. The tempting alternative — one
            // cascaded LOW-pass and a single subtraction, `x - lowpass²(x)` —
            // factors as `(1 - LP)(1 + LP)` and is therefore only 6 dB/oct
            // with a +6 dB lift, measured: at 40 Hz against a 120 Hz corner it
            // removes 4.3 dB where this removes 20.0 dB. The `bassMonoAt40Hz`
            // leg is what tells those two apart.
            let coeffF = Float(coeff)
            lowA += coeffF * (built - lowA)
            if abs(lowA) < denormalFloor { lowA = 0 }
            let highA = built - lowA
            lowB += coeffF * (highA - lowB)
            if abs(lowB) < denormalFloor { lowB = 0 }
            let high = highA - lowB
            let sideOut = built + (high - built) * Float(bassMono)

            // ⛔ THE NEUTRAL EARLY-OUT. The decorrelator and the crossover ran
            // above (so a later `spread` raise is phase-coherent); the buffer
            // is simply never touched, which is the only way a mid/side
            // structure can be bit-exact dry.
            if !neutral {
                left[frame] = mid + sideOut
                right[frame] = mid - sideOut
            }

            width += widthDelta
            spread += spreadDelta
            bassMono += bassDelta
            coeff += coeffDelta
            frame += 1
        }

        crossLowA = lowA
        crossLowB = lowB

        // SNAP, do not keep the accumulated value: per-sample addition drifts,
        // and a `width` that settles at 0.99999994 would hold this effect out
        // of its bit-exact bypass forever.
        previousWidth = targetWidth
        previousSpread = targetSpread
        previousBassMono = targetBassMono
        previousCrossCoeff = targetCrossCoeff
    }
}
