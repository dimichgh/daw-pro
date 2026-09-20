import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in ring modulator (m39-m) — the input multiplied, sample by sample, by
/// a BAND-LIMITED carrier oscillator. `docs/design/2026-09-19-creative-effects.md`
/// §6.4 is the frozen contract; this file implements it, and every place it
/// reads against the letter of that section is called out in a ⚠️ comment below
/// and written up in `2026-09-19-creative-effects-errata.md` rather than left to
/// be discovered.
///
/// WHAT IT DOES, in the order the render path does it, per channel per sample:
///   1. **Input high-cut** — a 2-pole Butterworth low-pass at `inputHighCutHz`,
///      on the signal that feeds the multiply. ⚠️ THE DRY PATH IS UNTOUCHED BY
///      IT, which is what §6.4.1's word "pre-filter" means: it sits BEFORE the
///      multiply, not in front of the whole unit. So pulling it down tames the
///      metallic layer's fold-back without dulling the user's original sound,
///      and at `mix == 1` (where there is no dry path) the two readings are the
///      same signal anyway. This is the FOLD-BACK control: a partial you
///      removed cannot produce a sideband that folds.
///   2. **Carrier** — a phase accumulator advanced by `carrierHz / sampleRate`,
///      shaped by `waveform`. Waveforms 1–3 are generated BAND-LIMITED.
///   3. **The multiply** — `wet = x · c`. Neither `x` nor `c` survives: each
///      input partial at `f` becomes the pair `|f - fc|` and `f + fc`
///      (`RingModParams.sidebandsHz`). ⚠️ THE CARRIER IS ABSENT FROM THE OUTPUT,
///      and that is what makes this a RING modulator rather than a tremolo. A
///      tremolo multiplies by `1 + depth·c` and keeps the original; this does
///      not, and a build that leaked `c` would be an amplitude modulator wearing
///      this name.
///   4. **Mix** — `out = dry·(1−m) + wet·m`. At `m == 0` exactly, THE BUFFER IS
///      NEVER WRITTEN — bit-exact dry by IEEE (rule 6.0.7) — while the carrier
///      and the input filter keep advancing, so raising `mix` later is
///      phase-coherent rather than a jump (the `ChorusEffect` convention).
///
/// ⛔ NO OVERSAMPLING, DELIBERATELY (design §6.4.2 part 2). `f + fc` routinely
/// exceeds Nyquist and folds back down as an extra inharmonic tone. Classic
/// hardware ring modulators do exactly this and it is half their character.
/// Removing it would remove the sound people reach for this effect to get.
/// `inputHighCutHz` is the control given to anyone who wants less of it, and
/// `RingModParams.foldedHz` is where the arithmetic lives so the note text, the
/// tests and this file cannot disagree about where a folded tone lands.
///
/// ⭐ THE CARRIER'S OWN HARMONICS **ARE** BAND-LIMITED (design §6.4.2 part 1),
/// and the two problems are genuinely different: the PRODUCT's fold-back is the
/// sound, the CARRIER's own aliasing is a defect. A raw `sign(sin)` square at
/// 3 kHz aliases violently and would sound broken before anyone reached for the
/// high-cut. Saw and square use PolyBLEP; the triangle uses PolyBLAMP.
/// ⚠️ §6.4.2 names "an INTEGRATED band-limited triangle" and this file does not
/// integrate — see erratum §E5 for the measurement that decided it.
///
/// SMOOTHING (rule 6.0.6 — a new creative effect smooths its own derived state
/// internally): effect params arrive as ONE SCALAR PER QUANTUM.
///   · the carrier's phase INCREMENT, the mix gain and the stereo phase offset
///     are interpolated **per sample** across the quantum. The increment has to
///     be: interpolating the increment rather than jumping it is exactly what
///     makes a `carrierHz` change a FREQUENCY step instead of a PHASE
///     discontinuity, and a phase discontinuity in a signal you are multiplying
///     by is a click at full amplitude. That is what earns `carrierHz` its
///     `modulatable: yes` instead of `warned` (§6.4.1).
///   · the input filter's coefficients are recomputed every **32 frames** — the
///     stride the modulation design froze — because they cost `sin`/`cos`.
/// ⚠️ THE PHASE ACCUMULATOR IS NEVER RESET BY A PARAMETER CHANGE. `reset()`
/// clears it (a stop-time cut); `apply`/`storeAutomatedParam` never do.
///
/// Parameter updates follow the `GainEffect` atomic-POD-publish convention.
/// Render-path contract: `process()`/`reset()` allocate nothing, take no locks,
/// log nothing, touch no ObjC, hop no actors. ALL state is a fixed number of
/// scalars — 2 channels × 1 biquad of 2 TDF2 taps, plus one phase — so there is
/// nothing to size and `prepare()` has nothing to allocate. Both state words of
/// each biquad are denormal-flushed PER SAMPLE (see `Biquad.step`).
final class RingModEffect: EffectRendering, @unchecked Sendable {
    /// Coefficient recompute stride, in frames — the modulation design's frozen
    /// stride, adopted for the same reason: fine enough that an automated
    /// high-cut sweep is continuous, coarse enough that `sin`/`cos` never run
    /// per sample. ⚠️ The CARRIER is NOT on this stride; it interpolates per
    /// sample, because 32-frame steps in a phase increment are audible.
    private static let coefficientStride = 32
    /// Butterworth Q for the 2-pole input high-cut — the one home, shared with
    /// the EQ and the bass enhancer.
    private static let butterworthQ = EQFilterResponse.butterworth2Q

    /// One 2-pole transposed-direct-form-II biquad, one channel.
    /// TDF2 is the shape `BassEnhancerEffect` uses for the same coefficients,
    /// for the same reason: two state words, good numerical behaviour at low
    /// corners, and it is what `EQFilterResponse.cutSection`'s normalisation
    /// assumes.
    private struct Biquad {
        var z1: Double = 0
        var z2: Double = 0

        /// ⚠️ Both state words are denormal-flushed on EVERY sample — the
        /// `DJFilterEffect.SVFSection` convention, and for the same reason: a
        /// recursive filter decaying toward zero on silence lands in subnormal
        /// territory, where each operation costs orders of magnitude more, on
        /// the render thread, during silence, which is exactly when nobody is
        /// looking. A 500 Hz corner's poles sit at radius ~0.955, so a
        /// quantum-boundary flush would leave hundreds of samples in the slow
        /// path on every fade-out.
        @inline(__always)
        mutating func step(_ x: Double, b0: Double, b1: Double, b2: Double,
                           a1: Double, a2: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            if abs(z1) < 1e-25 { z1 = 0 }
            if abs(z2) < 1e-25 { z2 = 0 }
            return y
        }

        @inline(__always)
        mutating func clear() {
            z1 = 0
            z2 = 0
        }
    }

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: RingModParams

        init(generation: UInt64, params: RingModParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Prepared storage (main-actor set, render-thread read).
    private var sampleRate: Double = 48_000

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    /// Carrier phase in CYCLES, [0, 1). The left channel's phase; the right
    /// channel reads it plus `stereoPhaseOffset`.
    private var carrierPhase = 0.0
    private var filterL = Biquad()
    private var filterR = Biquad()

    // Derived input-filter coefficients, recomputed every `coefficientStride`.
    private var b0: Double = 1
    private var b1: Double = 0
    private var b2: Double = 0
    private var a1: Double = 0
    private var a2: Double = 0

    /// Snapped at the quantum boundary — a shape switch cannot be half-applied.
    private var waveform: RingModParams.Waveform = .sine

    // Interpolation endpoints. `previous*` is where the last quantum ENDED,
    // `target*` is what this quantum was asked for.
    private var previousIncrement = 440.0 / 48_000.0
    private var targetIncrement = 440.0 / 48_000.0
    private var previousMix = 0.5
    private var targetMix = 0.5
    private var previousSpread = 0.0
    private var targetSpread = 0.0
    private var previousHighCut = 20_000.0
    private var targetHighCut = 20_000.0
    /// Set by `prepare`/`reset`: the next quantum starts AT its target instead
    /// of sweeping into it from a stale value.
    private var needsPrime = true

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<RingModParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: RingModParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: RingModParams = RingModParams()) {
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
    func apply(params: RingModParams) {
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
        clearRuntimeState()
        lastGeneration = .max  // re-derive at the new rate
    }

    var latencySamples: Int { 0 }

    /// Clears the carrier phase and the filter tails (stop-time cut /
    /// un-bypass). Render-thread safe: this effect owns no buffers, so a reset
    /// is a handful of stores.
    func reset() {
        clearRuntimeState()
    }

    private func clearRuntimeState() {
        carrierPhase = 0
        filterL.clear()
        filterR.clear()
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
    /// ⚠️ EVERY FIELD IS RE-GUARDED AND RE-CLAMPED. A field-by-field overlay
    /// poke (`storeAutomatedParam`) bypasses `RingModParams.init`, so the
    /// clamping the init does is NOT in force here — the `BitCrusherParams`
    /// precedent, where the same hole would have let a NaN reach an `Int()`
    /// conversion and TRAP on the render thread. Here `waveform` reaches
    /// exactly that conversion (inside `RingModParams.waveform(at:)`, which
    /// carries its own guard for this reason), and a NaN carrier would poison
    /// the phase accumulator permanently — there is no path back from a NaN
    /// phase, so every later sample would be NaN too.
    private func deriveRenderParams(_ p: RingModParams) {
        let carrier = (p.carrierHz.isFinite ? p.carrierHz : 440)
            .clamped(to: RingModParams.carrierRange)
        targetIncrement = carrier / sampleRate
        targetMix = (p.mix.isFinite ? p.mix : 0.5).clamped(to: RingModParams.mixRange)
        targetHighCut = (p.inputHighCutHz.isFinite ? p.inputHighCutHz : 20_000)
            .clamped(to: RingModParams.inputHighCutRange)
        // THROUGH THE LAW, never a second copy of the degrees→cycles division.
        targetSpread = RingModParams.carrierPhaseOffsetCycles(stereoSpreadDeg: p.stereoSpreadDeg)
        // Discrete: snapped, never interpolated. A shape switch cannot be
        // half-applied, so it takes effect at the quantum boundary like the
        // `eq`/`djFilter` slopes it is modelled on. THROUGH THE LAW — this is
        // the only place in the engine that turns the number into a shape.
        waveform = RingModParams.waveform(at: p.waveform)
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .ringMod)`: 0 carrierHz, 1 mix, 2 waveform,
    /// 3 inputHighCutHz, 4 stereoSpreadDeg. Pokes a preallocated params copy
    /// and re-derives — no allocation, no locks. The carrier PHASE and the
    /// filter state are untouched, so an automated carrier sweep stays
    /// continuous.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...4).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.carrierHz = value
        case 1: overlay.effective.mix = value
        case 2: overlay.effective.waveform = value
        case 3: overlay.effective.inputHighCutHz = value
        default: overlay.effective.stereoSpreadDeg = value
        }
        deriveRenderParams(overlay.effective)
    }

    /// Recomputes the input high-cut's coefficients. Pure libm (`sin`, `cos`
    /// inside `cutSection`) — no allocation, no locks — and it runs once per
    /// `coefficientStride` frames, never per sample. The coefficients come from
    /// `EQFilterResponse.cutSection`, this project's declared ONE HOME for
    /// biquad cut math (it also clamps the corner to `sampleRate · 0.49`, so a
    /// 20 kHz default at a 32 kHz project rate stays below Nyquist instead of
    /// running `tan` past its asymptote).
    private func deriveCoefficients(highCutHz: Double) {
        let section = EQFilterResponse.cutSection(
            highPass: false, freq: highCutHz, q: Self.butterworthQ, sampleRate: sampleRate)
        b0 = section.b0
        b1 = section.b1
        b2 = section.b2
        a1 = section.a1
        a2 = section.a2
    }

    // MARK: - Band-limited carrier
    //
    // The two residual functions below are the entire anti-aliasing story, and
    // they are three lines each because that is genuinely all it takes.
    //
    // ⭐ polyBLEP corrects a STEP discontinuity (square, saw). It is the
    // difference between an ideal step and a step smoothed over ±1 sample:
    //     r(τ) =  (τ+1)²/2   for τ ∈ [-1, 0)      ← the sample BEFORE the edge
    //     r(τ) = -(1-τ)²/2   for τ ∈ [ 0, 1)      ← the sample AFTER it
    // scaled by the step's SIZE and sign. It integrates to zero over its
    // support, so it adds no DC — which matters here, because DC on the carrier
    // would leak the INPUT into the output and turn a ring modulator into an
    // amplitude modulator.
    //
    // ⭐ polyBLAMP corrects a SLOPE discontinuity (triangle) and is the integral
    // of the one above, which collapses to something remarkably tidy:
    //     R(τ) = (1 - |τ|)³ / 6     for |τ| ≤ 1
    // scaled by the slope CHANGE in units per sample. Both of a triangle's
    // corners carry equal and opposite slope changes, so their corrections also
    // cancel to zero DC.

    /// polyBLEP residual for a unit UP-step at phase 0, evaluated at `phase`.
    /// Zero everywhere except within one sample of the edge.
    @inline(__always)
    private func blep(_ phase: Double, _ dt: Double) -> Double {
        if phase < dt {
            let t = 1 - phase / dt
            return -0.5 * t * t
        }
        if phase > 1 - dt {
            let t = (phase - 1) / dt + 1
            return 0.5 * t * t
        }
        return 0
    }

    /// polyBLAMP residual for a unit slope INCREASE at phase 0, evaluated at
    /// `phase`. Zero everywhere except within one sample of the corner.
    @inline(__always)
    private func blamp(_ phase: Double, _ dt: Double) -> Double {
        if phase < dt {
            let t = 1 - phase / dt
            return t * t * t / 6
        }
        if phase > 1 - dt {
            let t = (phase - 1) / dt + 1
            return t * t * t / 6
        }
        return 0
    }

    /// The carrier value at `phase`, band-limited for the given per-sample
    /// phase increment `dt`. Peak amplitude is ±1 for every shape, so switching
    /// `waveform` changes the timbre without slamming the level (the RMS still
    /// differs — a square is ~3 dB hotter than a sine, which the param's note
    /// states rather than hides).
    @inline(__always)
    private func carrier(_ phase: Double, _ dt: Double,
                         _ shape: RingModParams.Waveform) -> Double {
        switch shape {
        case .sine:
            // Already band-limited by construction: one partial, no edges.
            return sin(2 * .pi * phase)
        case .triangle:
            // Naive triangle: -1 at phase 0, +1 at phase 0.5, slope ±4 per
            // cycle = ±4·dt per sample. Corners at 0 (slope +8·dt) and 0.5
            // (slope -8·dt).
            var half = phase + 0.5
            if half >= 1 { half -= 1 }
            let naive = 1 - 4 * abs(phase - 0.5)
            return naive + 8 * dt * (blamp(phase, dt) - blamp(half, dt))
        case .square:
            // Naive square: +1 on [0, 0.5), -1 on [0.5, 1). UP-step of 2 at
            // phase 0, DOWN-step of 2 at phase 0.5.
            var half = phase + 0.5
            if half >= 1 { half -= 1 }
            let naive: Double = phase < 0.5 ? 1 : -1
            return naive + 2 * (blep(phase, dt) - blep(half, dt))
        case .saw:
            // Naive saw: rises -1 → +1 across the cycle, DOWN-step of 2 at the
            // wrap.
            return (2 * phase - 1) - 2 * blep(phase, dt)
        }
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard frameCount > 0 else { return }

        if needsPrime {
            previousIncrement = targetIncrement
            previousMix = targetMix
            previousSpread = targetSpread
            previousHighCut = targetHighCut
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
        let mixDelta = (targetMix - previousMix) / span
        let spreadDelta = (targetSpread - previousSpread) / span
        let highCutDelta = targetHighCut - previousHighCut
        let stereo = right != nil
        let shape = waveform

        var increment = previousIncrement
        var mix = previousMix
        var spread = previousSpread
        var phase = carrierPhase

        // ⚠️ `while`, not `for i in 0..<n` — measured at
        // `EffectChainProcessor.swift:402-412`, a `Range` iteration raises
        // ~2 malloc/free events PER ITERATION at `-Onone`, which is why the
        // allocation gates can assert an absolute zero at all.
        var frame = 0
        while frame < minFrames {
            var blockEnd = frame + Self.coefficientStride
            if blockEnd > minFrames { blockEnd = minFrames }

            // One coefficient recompute per block; the carrier and the gains
            // interpolate inside it, per sample.
            let t = Double(frame) / span
            deriveCoefficients(highCutHz: previousHighCut + highCutDelta * t)
            let c0 = b0, c1 = b1, c2 = b2, d1 = a1, d2 = a2

            var i = frame
            while i < blockEnd {
                let dryL = Double(left[i])
                let filteredL = filterL.step(dryL, b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
                let carrierL = carrier(phase, increment, shape)

                var dryR = 0.0
                var filteredR = 0.0
                var carrierR = 0.0
                if stereo, let right {
                    dryR = Double(right[i])
                    filteredR = filterR.step(dryR, b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
                    var rightPhase = phase + spread
                    if rightPhase >= 1 { rightPhase -= 1 }
                    carrierR = carrier(rightPhase, increment, shape)
                }

                // `mix == 0` is the BIT-EXACT DRY path: the filter and the
                // oscillator above still ran (so a later mix raise is
                // phase-coherent), the buffer is simply never touched. `mix`
                // reaches exactly 0 by arithmetic, not by an epsilon — a knob
                // parked at 0 gives a 0 target and a 0 delta.
                if mix != 0 {
                    let dryGain = 1 - mix
                    left[i] = Float(dryL * dryGain + filteredL * carrierL * mix)
                    if stereo, let right {
                        right[i] = Float(dryR * dryGain + filteredR * carrierR * mix)
                    }
                }

                phase += increment
                if phase >= 1 { phase -= 1 }
                increment += incrementDelta
                mix += mixDelta
                spread += spreadDelta
                i += 1
            }
            frame = blockEnd
        }

        carrierPhase = phase

        previousIncrement = targetIncrement
        previousMix = targetMix
        previousSpread = targetSpread
        previousHighCut = targetHighCut
    }
}
