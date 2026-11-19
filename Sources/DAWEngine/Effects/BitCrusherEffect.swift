import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in bit-crusher / sample-rate reducer (m32-e) — the lo-fi character of
/// a 1980s sampling drum machine, as an INSERT effect (the SP-1200's sound comes
/// from the machine's D/A stage, so it belongs to the whole part, not to one
/// pad).
///
/// ## The signal path, in order
///
/// 1. **Optional pre-filter** (`antiAlias`): 4th-order Butterworth low-pass at
///    `downsampleHz / 2`, run on EVERY input sample. Removes the content that
///    would otherwise fold down through the sample-and-hold.
/// 2. **Sample and hold** at `downsampleHz`, driven by a PHASE ACCUMULATOR.
/// 3. **Quantize at capture** to `bits`, optionally dithered.
/// 4. **Optional post-filter** (`antiAlias`): the same 4th-order Butterworth,
///    the reconstruction filter a real converter would have.
/// 5. Dry/wet blend.
///
/// ## ⭐ Why a phase accumulator and not integer modulo of a sample counter
///
/// The graph rate is almost never an integer multiple of `downsampleHz` (the
/// default 26 040 Hz into a 48 kHz graph is a ratio of 1.843). A `frame % k`
/// scheme has to pick an integer `k`, which silently retunes the effect to
/// 24 kHz or 16 kHz — and, worse, `frame` is normally the frame index WITHIN
/// the quantum, so the hold pattern re-phases at every block boundary and the
/// rendered artifact becomes a function of the host's buffer size. A fractional
/// accumulator carried across quanta holds the true rate, so a render is
/// byte-identical whether it runs in one block or in 512-frame quanta — pinned
/// by `holdPatternIsChunkInvariant`.
///
/// ⚠️ **The accumulator COUNTS DOWN in input samples against the hold PERIOD
/// (`G / R`), rather than counting up in output-sample phase by the RATIO
/// (`R / G`). The two are algebraically identical and numerically are not.**
/// The design doc (`design-m32-sample-flip.md` §8) writes the ratio form:
/// `phase += ratio; if phase >= 1 { phase -= 1; capture }`. MEASURED, in IEEE
/// 754 double, at a 48 kHz graph rate with `downsampleHz: 8000`: the ratio form
/// emits **one run of 7 among 666 runs of 6**, because `8000/48000` is not
/// representable and six of them sum to just under 1. The countdown form's
/// increment is exactly 1.0 and its period is exactly 6.0, so it emits 6 every
/// time, forever — and at the non-integer default it still converges on the
/// true mean (measured 1.843321 against an exact 1.843318 over 480 000 frames,
/// no drift). Same accumulator, same "not integer modulo" ruling, one fewer
/// artifact that no one asked for.
///
/// **CHECK then ADVANCE, with the accumulator starting at 0**: that makes the
/// very first sample of a pass a capture and puts the steady-state run length in
/// place from frame 0 (advancing first would spend one short run getting
/// there), and — unlike seeding it to the period — the seed does not depend on
/// a `downsampleHz` that `reset()` has no business knowing.
///
/// ## Quantization: a converter's code range, not a rounding trick
///
/// `code = clamp(round(x · 2^(N−1)), −2^(N−1), 2^(N−1)−1)`, then `code / 2^(N−1)`.
/// That is exactly an N-bit two's-complement converter, so a full-scale ramp
/// takes **exactly 2^N distinct output levels** (4096 at the default 12 bits) —
/// the property the gate measures. A naive `round(x·L)/L` with a symmetric clamp
/// would give 2^N + 1 levels and would not correspond to any real machine.
///
/// ⭐ **Quantization happens AT CAPTURE, not per output sample.** With dither on,
/// quantizing each output sample would give every sample of a hold run its own
/// noise value and the "hold" would not be flat. Capturing once and repeating
/// the captured code is both what the hardware does and what keeps the run
/// structure intact at any `dither` setting.
///
/// ## ⭐⭐ Why the defaults are `antiAlias: false` / `dither: false`
///
/// Because the aliasing IS the character. The SP-1200's signature comes
/// specifically from its converter omitting the reconstruction filter, and a
/// generic bit-crusher with proper dithering and anti-aliasing sounds
/// "clean-but-crunchy" rather than gritty (`docs/research/sampling-flip-workflow.md`
/// §2.4). Both switches ship, both default OFF, and `antiAliasChangesSpectrum`
/// measures that turning one ON actually changes the spectrum — a decorative
/// flag would pass every other test in the suite.
///
/// ## Render-path contract
///
/// `process()` / `reset()` allocate nothing, take no locks, log nothing, touch
/// no ObjC and make no ARC traffic: all per-channel state lives in two arrays
/// sized at `init` and only ever indexed. Parameters cross from the main actor
/// as an immutable POD box through `daw_atomic_ptr` + a ≥ 1 s retire bin (the
/// GainEffect convention); coefficients recompute only on a generation change
/// or an automation store, never per frame. Every `Int(...)` the derive performs
/// is fenced by an `isFinite` check and a clamp, because a trap here is a crash
/// in the audio callback, not an exception.
///
/// Denormals: the four biquad sections are flushed per channel per pass (the
/// BassEnhancer 1e-25 pattern). The held value cannot denormalize — it is a
/// multiple of 2^−15 or coarser by construction.
///
/// Latency: 0. The sample-and-hold delays content by up to one hold period, but
/// that is a modulating, program-dependent effect and not a fixed algorithmic
/// latency; the anti-alias biquads are minimum-phase IIR, reported the same way
/// the EQ reports its own group delay (which is to say, not at all).
final class BitCrusherEffect: EffectRendering, @unchecked Sendable {
    private static let maxChannels = 8
    /// Per-channel state stride: pre-A s1/s2, pre-B s1/s2, post-A s1/s2,
    /// post-B s1/s2, hold countdown, held (already-quantized) value.
    private static let stateStride = 10
    private static let countdownSlot = 8
    private static let heldSlot = 9
    /// Number of leading slots that are biquad state (denormal-flushed).
    private static let filterSlots = 8

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: BitCrusherParams

        init(generation: UInt64, params: BitCrusherParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Render-thread-only state.
    private var sampleRate: Double = 48_000
    private var preparedChannels = 2
    private var lastGeneration = UInt64.max  // .max forces first-quantum adoption
    /// Flat [channel][pre-A s1, pre-A s2, pre-B s1, pre-B s2,
    ///                post-A s1, post-A s2, post-B s1, post-B s2,
    ///                hold countdown, held].
    private var state = [Double](repeating: 0, count: maxChannels * stateStride)
    /// Per-channel xorshift32 dither generator. Seeded DETERMINISTICALLY (and
    /// differently per channel, so left and right do not share one noise
    /// sequence): a render with `dither: true` is reproducible byte-for-byte,
    /// which is what lets this repo pin renders by digest at all.
    private var rngState = [UInt32](repeating: 0, count: maxChannels)

    // Derived render params (scalars — no array indirection in the inner loop).
    /// 2^(bits−1): the converter's full-scale code.
    private var quantScale = 2_048.0
    private var quantInvScale = 1.0 / 2_048.0
    private var quantMaxCode = 2_047.0
    private var quantMinCode = -2_048.0
    /// One LSB in signal units — the TPDF dither's peak amplitude.
    private var ditherLSB = 1.0 / 2_048.0
    /// `max(graphRate / downsampleHz, 1)` — the hold period in INPUT samples.
    /// Floored at 1 so a `downsampleHz` at or above the graph rate captures
    /// every sample (transparent) instead of driving the countdown negative.
    private var holdPeriod = 1.843_317_972_350_230_4
    private var antiAliasOn = false
    private var ditherOn = false
    private var wetGain = 1.0
    private var dryGain = 0.0
    /// False when `mix == 0`: `process` returns before touching the buffer, so
    /// the pass is bit-exact dry AND advances no hold/filter state.
    private var active = true
    // The two Butterworth sections. The pre- and post-filters share the SAME
    // corner and Qs (one converter's filter, used on both sides), so there are
    // two coefficient sets and four state pairs.
    private var aB0 = 0.0, aB1 = 0.0, aB2 = 0.0, aA1 = 0.0, aA2 = 0.0
    private var bB0 = 0.0, bB1 = 0.0, bB2 = 0.0, bA1 = 0.0, bA2 = 0.0

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<BitCrusherParams>

    // Main-actor-only publish state (retire bin ≥ 1 s, GainEffect contract).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: BitCrusherParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: BitCrusherParams = BitCrusherParams()) {
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        lastAppliedParams = params
        overlay = AutomationParamOverlay(base: params)
        let snapshot = ParamSnapshot(generation: 0, params: params)
        _ = daw_atomic_ptr_exchange(
            paramsSlot, UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque()))
        seedState()
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
    func apply(params: BitCrusherParams) {
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
        seedState()
        lastGeneration = .max  // adopt (and recompute coefficients) at the first quantum
    }

    var latencySamples: Int { 0 }

    func reset() {
        seedState()
    }

    /// Clears filter/hold state and re-seeds the dither generators. The hold
    /// countdown starts at 0 so the FIRST sample after a reset is a capture (see
    /// the type's doc comment); `held` starts at 0 so nothing from a previous
    /// passage can be re-emitted.
    private func seedState() {
        for index in state.indices { state[index] = 0 }
        for channel in 0..<Self.maxChannels {
            // The countdown seed is 0 (already set by the zeroing loop above):
            // the first sample of the next pass captures, whatever the period.
            // Odd, channel-distinct, never zero (xorshift is stuck at 0).
            rngState[channel] = 0x1234_5679 &+ UInt32(channel) &* 0x9E37_79B9
        }
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

    /// Recomputes the quantizer scale, the hold ratio and the Butterworth
    /// coefficients from `p` — generation change, automation stores, and the
    /// automation revert route through the SAME math (pure libm, no allocation;
    /// render-thread safe).
    ///
    /// ⚠️ EVERY numeric field is re-sanitized here even though `BitCrusherParams`
    /// clamps in its init: `storeAutomatedParam` writes into `overlay.effective`
    /// FIELD BY FIELD, which bypasses that init entirely. Without the re-clamp a
    /// `bits` lane at 40 would build `1 << 39` and a NaN would trap `Int(_:)` —
    /// on the render thread.
    private func deriveRenderParams(_ p: BitCrusherParams) {
        let rawBits = p.bits.isFinite ? p.bits : 12
        let bits = Int(rawBits.clamped(to: BitCrusherParams.bitsRange).rounded())
        let scale = Double(1 << (bits - 1))
        quantScale = scale
        quantInvScale = 1 / scale
        quantMaxCode = scale - 1
        quantMinCode = -scale
        ditherLSB = 1 / scale

        let rawRate = p.downsampleHz.isFinite ? p.downsampleHz : 26_040
        let rate = rawRate.clamped(to: BitCrusherParams.downsampleRange)
        holdPeriod = max(sampleRate / rate, 1)

        // ONE HOME for this project's biquad math: the same `EQFilterResponse`
        // sections the EQ and the bass enhancer use. `cutSection` already caps
        // the corner at 0.49 × rate, so a downsampleHz at or above the graph
        // rate cannot produce a degenerate w0 = π.
        let corner = rate / 2
        let a = EQFilterResponse.cutSection(highPass: false, freq: corner,
                                            q: EQFilterResponse.butterworth4QA,
                                            sampleRate: sampleRate)
        aB0 = a.b0; aB1 = a.b1; aB2 = a.b2; aA1 = a.a1; aA2 = a.a2
        let b = EQFilterResponse.cutSection(highPass: false, freq: corner,
                                            q: EQFilterResponse.butterworth4QB,
                                            sampleRate: sampleRate)
        bB0 = b.b0; bB1 = b.b1; bB2 = b.b2; bA1 = b.a1; bA2 = b.a2

        // Turning anti-aliasing OFF clears the four sections, so turning it back
        // on behaves like a freshly-prepared insert rather than resuming a
        // second of stale filter memory (the BassEnhancer neutral-pass rule).
        let wasAntiAlias = antiAliasOn
        antiAliasOn = p.antiAlias
        if wasAntiAlias && !antiAliasOn { clearFilterState() }
        ditherOn = p.dither

        let mix = (p.mix.isFinite ? p.mix : 1).clamped(to: BitCrusherParams.mixRange)
        wetGain = mix
        dryGain = 1 - mix
        active = mix != 0
    }

    /// Zeroes just the biquad sections, leaving phase/hold running.
    private func clearFilterState() {
        for channel in 0..<Self.maxChannels {
            let base = channel * Self.stateStride
            for slot in 0..<Self.filterSlots { state[base + slot] = 0 }
        }
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .bitCrusher)`: 0 bits, 1 downsampleHz,
    /// 2 antiAlias, 3 dither, 4 mix. Pokes a preallocated params copy and
    /// re-derives — no allocation, no locks. The two boolean params take the
    /// `truePeak`/`pingPong` numeric convention (≥ 0.5 = on).
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...4).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.bits = value
        case 1: overlay.effective.downsampleHz = value
        case 2: overlay.effective.antiAlias = value >= 0.5
        case 3: overlay.effective.dither = value >= 0.5
        default: overlay.effective.mix = value
        }
        deriveRenderParams(overlay.effective)
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

    /// m39-d CR-2 (design §5.4): deliberately a no-op — class (c): every param steps at the store;
    /// nothing ramps over the call.
    func beginControlCell(frames: Int) {}

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        // mix 0: skip the whole pass (bit-exact dry, and no state advances —
        // the hold and the filters resume exactly where they were).
        guard active else { return }

        let strideBytes = MemoryLayout<Float>.stride
        let scale = quantScale, invScale = quantInvScale
        let maxCode = quantMaxCode, minCode = quantMinCode
        let lsb = ditherLSB
        let period = holdPeriod
        let aa = antiAliasOn
        let dither = ditherOn
        let wet = wetGain, dry = dryGain
        let a0 = aB0, a1 = aB1, a2 = aB2, ap1 = aA1, ap2 = aA2
        let c0 = bB0, c1 = bB1, c2 = bB2, cp1 = bA1, cp2 = bA2

        state.withUnsafeMutableBufferPointer { s in
            var channel = 0
            for buffer in buffers {
                guard channel < preparedChannels,
                      let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    channel += 1
                    continue
                }
                let frames = min(frameCount, Int(buffer.mDataByteSize) / strideBytes)
                let base = channel * Self.stateStride
                var preA1 = s[base], preA2 = s[base + 1]
                var preB1 = s[base + 2], preB2 = s[base + 3]
                var postA1 = s[base + 4], postA2 = s[base + 5]
                var postB1 = s[base + 6], postB2 = s[base + 7]
                var countdown = s[base + Self.countdownSlot]
                var held = s[base + Self.heldSlot]
                var rng = rngState[channel]

                // MANUALLY-INCREMENTED `while`, NOT `for frame in 0..<frames` —
                // the m23-r2a chain-walk finding: at `-Onone` (how `swift test`
                // builds) `Range` iteration raises ~2 malloc/free events PER
                // ITERATION, making an effect's per-sample loop the largest
                // allocation source in a debug render. **NEVER put a `continue`
                // in this body** — `frame` would not advance and the render
                // thread would spin forever (a hang, not a glitch).
                var frame = 0
                while frame < frames {
                    let raw = Double(data[frame])
                    // ONE sanitize, feeding BOTH paths. A NaN reaching the dry
                    // blend would survive `0 × NaN`, and a NaN reaching the
                    // pre-filter would poison its recursion permanently — a
                    // stuck-NaN insert, not a click.
                    let input = raw.isFinite ? raw : 0

                    // 1. Pre-filter runs on EVERY input sample, not only at
                    //    captures: it is a filter at the GRAPH rate, and
                    //    advancing it only at captures would put its corner at
                    //    the wrong frequency by exactly the hold ratio.
                    var x = input
                    if aa {
                        let y = a0 * x + preA1
                        preA1 = a1 * x - ap1 * y + preA2
                        preA2 = a2 * x - ap2 * y
                        let z = c0 * y + preB1
                        preB1 = c1 * y - cp1 * z + preB2
                        preB2 = c2 * y - cp2 * z
                        x = z
                    }

                    // 2/3. Sample-and-hold, quantizing AT CAPTURE. Check then
                    //      advance (see the doc comment) so the steady-state
                    //      run length holds from the very first frame. The
                    //      countdown is in INPUT samples against the hold
                    //      PERIOD — see the doc comment for the measured reason
                    //      it is not the ratio form.
                    if countdown <= 0 {
                        countdown += period
                        var v = x
                        if dither {
                            // TPDF = sum of two independent uniforms, ±1 LSB
                            // peak. Two xorshift32 steps, no allocation, no libm.
                            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
                            let u1 = Double(rng) * (1.0 / 4_294_967_296.0) - 0.5
                            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
                            let u2 = Double(rng) * (1.0 / 4_294_967_296.0) - 0.5
                            v += (u1 + u2) * lsb
                        }
                        // An N-bit converter's code range, clamped asymmetrically
                        // exactly as two's complement is: 2^N codes, no more.
                        var code = (v * scale).rounded()
                        if code > maxCode {
                            code = maxCode
                        } else if code < minCode {
                            code = minCode
                        }
                        held = code * invScale
                    }
                    countdown -= 1

                    // 4. Reconstruction filter on the held staircase.
                    var out = held
                    if aa {
                        let y = a0 * out + postA1
                        postA1 = a1 * out - ap1 * y + postA2
                        postA2 = a2 * out - ap2 * y
                        let z = c0 * y + postB1
                        postB1 = c1 * y - cp1 * z + postB2
                        postB2 = c2 * y - cp2 * z
                        out = z
                    }

                    // 5. Blend.
                    data[frame] = Float(input * dry + out * wet)
                    frame &+= 1
                }

                // Denormal flush: keep the four recursions out of subnormal
                // territory on silent input. `held` is a multiple of the LSB
                // (≥ 2^−15) and the countdown is bounded in (−1, period], so
                // neither can denormalize.
                if abs(preA1) < 1e-25 { preA1 = 0 }
                if abs(preA2) < 1e-25 { preA2 = 0 }
                if abs(preB1) < 1e-25 { preB1 = 0 }
                if abs(preB2) < 1e-25 { preB2 = 0 }
                if abs(postA1) < 1e-25 { postA1 = 0 }
                if abs(postA2) < 1e-25 { postA2 = 0 }
                if abs(postB1) < 1e-25 { postB1 = 0 }
                if abs(postB2) < 1e-25 { postB2 = 0 }
                s[base] = preA1; s[base + 1] = preA2
                s[base + 2] = preB1; s[base + 3] = preB2
                s[base + 4] = postA1; s[base + 5] = postA2
                s[base + 6] = postB1; s[base + 7] = postB2
                s[base + Self.countdownSlot] = countdown
                s[base + Self.heldSlot] = held
                rngState[channel] = rng
                channel += 1
            }
        }
    }
}
