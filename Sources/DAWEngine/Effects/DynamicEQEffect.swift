import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in dynamic EQ (m39-af) — FOUR identical bell bands IN SERIES, each one
/// a single side-path biquad whose gain is driven by that band's own filtered
/// level. `docs/design/2026-09-20-dynamic-eq.md` is the settled design;
/// `EffectDescriptor.Kind.dynamicEQ` carries the user-facing story.
///
/// ## The topology, and why it is this one
///
/// Each band is
///
///     y = x + (G − 1)·BP(x)
///
/// with `BP` the CONSTANT-0-dB-PEAK band-pass (`EQFilterResponse.bandPassSection`,
/// the same function `CompressorEffect`'s de-ess detector uses, for the same
/// reason: a threshold has to mean the same dBFS banded as broadband). Expanded
/// with RBJ's `α = sin(ω₀)/(2Q)`, that is
///
///     [(1 + Gα) − 2cos(ω₀)z⁻¹ + (1 − Gα)z⁻²] / [(1 + α) − 2cos(ω₀)z⁻¹ + (1 − α)z⁻²]
///
/// — and **the denominator does not contain G**. The poles depend on
/// `(freq, Q, sampleRate)` alone, so moving the band's gain costs ONE MULTIPLY
/// AND ONE ADD: no trig, no coefficient recompute, no control stride, no
/// discontinuity in the filter's memory. That is the whole reason this design is
/// cheap enough to run the gain at audio rate.
///
/// ⭐ **THE SAME ONE FILTER SERVES BOTH JOBS.** `s[c]` is the band-isolated
/// signal the gain is applied through AND the signal the detector reads, so the
/// detector is band-isolated for free — no second filter, no second bank of
/// state, no second set of coefficients to keep in sync.
///
/// ⚠️ **SERIES, SO BAND b's DETECTOR HEARS BANDS 1…b−1's OUTPUT.** That is
/// standard and arguably right, and it is written down because it looks like a
/// bug from the outside. Series also makes overlapping bands compose as a
/// PRODUCT (dB-additive, matching `.eq` and every user's intuition) where a
/// parallel sum would overshoot where they overlap.
///
/// ## Latency
///
/// `latencySamples` is a LITERAL 0 at every setting of every parameter:
/// minimum-phase IIR, no delay line, no lookahead. (A Q-2 bell has
/// frequency-dependent GROUP delay — a fraction of a millisecond near its
/// centre — but group delay is not reportable latency and PDC neither can nor
/// should compensate it. `.eq` has exactly the same property and reports 0.)
/// That is why `Automation.swift` has no refusal entry for this kind.
///
/// ## Render-path contract
///
/// `process()` / `reset()` / `prepare()` / `storeAutomatedParam()` allocate
/// nothing, take no locks, log nothing and touch no ObjC. Per-sample work is
/// pure arithmetic plus `log10`/`pow` (libm — the compressor's existing budget).
/// Coefficient trig runs only when a band's `freq`/`Q`/rate actually moves.
/// Parameters cross the boundary by the `GainEffect` atomic-POD-publish
/// convention with a ≥ 1 s retire bin.
final class DynamicEQEffect: EffectRendering, @unchecked Sendable {
    private static let maxChannels = 8
    private static let bandCount = DynamicEQParams.bandCount

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: DynamicEQParams

        init(generation: UInt64, params: DynamicEQParams) {
            self.generation = generation
            self.params = params
        }
    }

    /// One band's complete render state — coefficients, derived constants,
    /// ballistics and the coefficient cache — in ONE POD struct so the whole
    /// band can be hoisted into a local at the top of its loop and written back
    /// once at the end (§9's "one switch in, one switch out" shape). Copying
    /// ~15 Doubles four times per quantum is negligible and is not an
    /// allocation.
    private struct BandRender {
        var mode: DynamicEQParams.Mode = .off
        /// Normalized band-pass coefficients (b0, b1, b2, a1, a2).
        var c0 = 0.0, c1 = 0.0, c2 = 0.0, d1 = 0.0, d2 = 0.0
        var thresholdDb = -18.0
        /// `1 − 1/ratio` — the NEGATION of the compressor's `slope`, because
        /// `depth` here is a non-negative MAGNITUDE that a sign is applied to.
        /// `k >= 0` always, and `k == 0` at ratio 1 (the band does nothing).
        var k = 1.0 - 1.0 / 4.0
        /// SIGNED, and the sign is the direction the band moves.
        var rangeDb = -6.0
        var attackCoeff = 0.0
        var releaseCoeff = 0.0
        /// Smoothed band gain in dB. ⛔ SIGNED — see the ballistics in
        /// `process`; this is what makes the compressor's smoother unusable
        /// here.
        var env = 0.0
        /// Peak-follower state (linear).
        var level = 0.0
        /// Coefficient cache. ⚠️ Seeded with NaN so the FIRST derive always
        /// recomputes (`NaN != NaN`), where a 0 seed would collide with a real
        /// request for 0. ⛔ `mode` is deliberately NOT part of this key: both
        /// live modes use the IDENTICAL band-pass, so an above↔below change
        /// must recompute nothing and must clear nothing.
        var lastFreq = Double.nan
        var lastQ = Double.nan
        var lastRate = Double.nan
    }

    /// The per-frame side-path samples, one per channel, living between the two
    /// channel loops inside the frame loop.
    ///
    /// ⚠️ **PRIVATE HERE, NOT A SHARED PRIMITIVE, AND THAT IS THE TREE'S RULE
    /// RATHER THAN LAZINESS.** `Biquad.swift:8-13` states it: a type becomes a
    /// primitive when its SECOND caller appears, "not before and not on spec".
    /// This has one caller. An ARRAY would allocate on `init` and, mutated
    /// through a subscript inside the per-sample loop, would cost a CoW check
    /// per sample.
    private struct InlineSidePath {
        var s0, s1, s2, s3, s4, s5, s6, s7: Double

        init() {
            s0 = 0; s1 = 0; s2 = 0; s3 = 0
            s4 = 0; s5 = 0; s6 = 0; s7 = 0
        }

        subscript(index: Int) -> Double {
            get {
                switch index {
                case 0: return s0
                case 1: return s1
                case 2: return s2
                case 3: return s3
                case 4: return s4
                case 5: return s5
                case 6: return s6
                default: return s7
                }
            }
            set {
                switch index {
                case 0: s0 = newValue
                case 1: s1 = newValue
                case 2: s2 = newValue
                case 3: s3 = newValue
                case 4: s4 = newValue
                case 5: s5 = newValue
                case 6: s6 = newValue
                default: s7 = newValue
                }
            }
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Render-thread-only state.
    private var sampleRate: Double = 48_000
    private var lastGeneration = UInt64.max
    private var preparedChannels = 2
    /// The peak follower's fixed 5 ms decay — `CompressorEffect.swift:182`'s
    /// constant, shared so the two units' detectors agree about what "the level
    /// right now" means.
    private var detectorDecay = 0.0
    private var band0 = BandRender(), band1 = BandRender()
    private var band2 = BandRender(), band3 = BandRender()
    /// ONE filter bank PER BAND, indexed BY CHANNEL. `InlineBiquads` holds 8
    /// sections, so four banks cover 4 bands × 8 channels = 32 sections with no
    /// heap anywhere. ⛔ One section per channel, never shared: a filter has
    /// memory, and sharing one between channels would make the result depend on
    /// channel order (`DynamicEQRenderTests.channelOrderInvariance` proves it
    /// does not).
    private var bank0 = InlineBiquads(), bank1 = InlineBiquads()
    private var bank2 = InlineBiquads(), bank3 = InlineBiquads()
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<DynamicEQParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: DynamicEQParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: DynamicEQParams = DynamicEQParams()) {
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
    func apply(params: DynamicEQParams) {
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

    // MARK: - Band state accessors (a switch, never an array)

    @inline(__always)
    private func bandState(_ index: Int) -> BandRender {
        switch index {
        case 0: return band0
        case 1: return band1
        case 2: return band2
        default: return band3
        }
    }

    @inline(__always)
    private func setBandState(_ index: Int, _ value: BandRender) {
        switch index {
        case 0: band0 = value
        case 1: band1 = value
        case 2: band2 = value
        default: band3 = value
        }
    }

    @inline(__always)
    private func bank(_ index: Int) -> InlineBiquads {
        switch index {
        case 0: return bank0
        case 1: return bank1
        case 2: return bank2
        default: return bank3
        }
    }

    @inline(__always)
    private func setBank(_ index: Int, _ value: InlineBiquads) {
        switch index {
        case 0: bank0 = value
        case 1: bank1 = value
        case 2: bank2 = value
        default: bank3 = value
        }
    }

    @inline(__always)
    private func clearBank(_ index: Int) {
        switch index {
        case 0: bank0.clearAll()
        case 1: bank1.clearAll()
        case 2: bank2.clearAll()
        default: bank3.clearAll()
        }
    }

    // MARK: - EffectRendering

    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        preparedChannels = min(channelCount, Self.maxChannels)
        detectorDecay = exp(-1.0 / (0.005 * sampleRate))  // fixed 5 ms peak decay
        for index in 0..<Self.bandCount {
            clearBank(index)
            var b = bandState(index)
            b.env = 0
            b.level = 0
            // The sections are STATE and a rate change invalidates both them and
            // their coefficients. `lastRate` is NaN-poisoned, not assigned, so
            // the next derive cannot decide nothing changed.
            b.lastRate = .nan
            setBandState(index, b)
        }
        lastGeneration = .max  // re-derive coefficients at the new rate
    }

    /// ⛔ A LITERAL 0, AND IT STAYS ONE — at every setting of every parameter.
    /// See the type's doc comment: that constancy is what lets
    /// `Automation.swift` refuse none of the 32 slots.
    var latencySamples: Int { 0 }

    /// Clears every band's filter sections AND its envelopes, so a transport
    /// stop does not leave a band holding 6 dB of movement into the first frame
    /// after the restart.
    func reset() {
        for index in 0..<Self.bandCount {
            clearBank(index)
            var b = bandState(index)
            b.env = 0
            b.level = 0
            setBandState(index, b)
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

    /// Recomputes all four bands' render constants — generation change,
    /// automation stores and the automation revert route through the SAME math
    /// (pure libm, no allocation; render-thread safe). Each band is guarded by
    /// its OWN coefficient cache, so an automation lane riding
    /// `band1ThresholdDb` — which routes through here — costs twelve
    /// comparisons and NO trig.
    private func deriveRenderParams(_ p: DynamicEQParams) {
        deriveBand(0, mode: p.band1Mode, freq: p.band1Freq, q: p.band1Q,
                   threshold: p.band1ThresholdDb, ratio: p.band1Ratio,
                   rangeDb: p.band1RangeDb, attackMs: p.band1AttackMs,
                   releaseMs: p.band1ReleaseMs)
        deriveBand(1, mode: p.band2Mode, freq: p.band2Freq, q: p.band2Q,
                   threshold: p.band2ThresholdDb, ratio: p.band2Ratio,
                   rangeDb: p.band2RangeDb, attackMs: p.band2AttackMs,
                   releaseMs: p.band2ReleaseMs)
        deriveBand(2, mode: p.band3Mode, freq: p.band3Freq, q: p.band3Q,
                   threshold: p.band3ThresholdDb, ratio: p.band3Ratio,
                   rangeDb: p.band3RangeDb, attackMs: p.band3AttackMs,
                   releaseMs: p.band3ReleaseMs)
        deriveBand(3, mode: p.band4Mode, freq: p.band4Freq, q: p.band4Q,
                   threshold: p.band4ThresholdDb, ratio: p.band4Ratio,
                   rangeDb: p.band4RangeDb, attackMs: p.band4AttackMs,
                   releaseMs: p.band4ReleaseMs)
    }

    /// One band's derive.
    ///
    /// ⚠️⚠️ **EVERY FIELD IS RE-GUARDED AND RE-CLAMPED HERE, and that is a
    /// correctness requirement rather than defensive habit.** A field-by-field
    /// overlay poke from `storeAutomatedParam` BYPASSES `DynamicEQParams.init`,
    /// so that init's clamping is not in force (the `ClipperEffect` /
    /// `CompressorEffect` trap, spelled out the same way in both). Two of the
    /// ways it bites here are specific:
    ///   · `DynamicEQParams.mode(at:)` does an `Int()` conversion, which
    ///     **TRAPS** on a NaN. It guards `isFinite` itself, and that guard is
    ///     the reason it exists rather than a local `Int(round(x))`.
    ///   · an unclamped `freq` at or above Nyquist makes `w0` reach π, where the
    ///     section is degenerate. `bandPassSection`'s own
    ///     `min(freq, sampleRate * 0.49)` covers it, but clamping to the
    ///     DECLARED range first means the clamp the user is TOLD about is the
    ///     clamp that happens, at every rate down to 32 kHz.
    ///
    /// ⛔⛔ **THE BAND LIFECYCLE CLEARS MORE THAN THE COMPRESSOR'S DOES, AND ON
    /// EXIT RATHER THAN ENTRY.** Clearing on ENTRY would restart the filter from
    /// silence on every automated `0→1→0→1` flutter and click
    /// (`CompressorEffect.swift:270-280` states that reason). But the
    /// compressor's rule alone is not sufficient here and copying it verbatim
    /// ships a step: there, `detectorMode` gates only the detector FILTER and
    /// the envelope keeps running either way; here `mode` gates the WHOLE band.
    /// A band that goes off holding `env = −6` and comes back would apply −6 dB
    /// in-band **on its very first frame** — a 6 dB step in one band, which is a
    /// click, repeated by every `off → above → off → above` flutter. So `env`
    /// and `level` are zeroed on exit too, and re-entry attacks from rest.
    ///
    /// ⚠️ A mode change from 1 to 2 (above ↔ below) MUST NOT clear anything:
    /// the coefficients are identical and the band never stopped running, so
    /// clearing would click for no reason. The test is *"did the mode leave
    /// `off`"*, not *"did the mode change"*.
    private func deriveBand(_ index: Int, mode modeRaw: Double, freq freqRaw: Double,
                            q qRaw: Double, threshold thresholdRaw: Double,
                            ratio ratioRaw: Double, rangeDb rangeRaw: Double,
                            attackMs attackRaw: Double, releaseMs releaseRaw: Double) {
        var b = bandState(index)
        let mode = DynamicEQParams.mode(at: modeRaw)
        b.thresholdDb = (thresholdRaw.isFinite ? thresholdRaw : -18)
            .clamped(to: DynamicEQParams.thresholdRange)
        let ratio = (ratioRaw.isFinite ? ratioRaw : 4)
            .clamped(to: DynamicEQParams.ratioRange)
        b.k = 1.0 - 1.0 / ratio
        b.rangeDb = (rangeRaw.isFinite ? rangeRaw : -6)
            .clamped(to: DynamicEQParams.rangeDbRange)
        let attackMs = (attackRaw.isFinite ? attackRaw : 10)
            .clamped(to: DynamicEQParams.attackRange)
        let releaseMs = (releaseRaw.isFinite ? releaseRaw : 100)
            .clamped(to: DynamicEQParams.releaseRange)
        // One-pole time constants: coeff = e^(−1/(ms·rate)); the envelope covers
        // 63.2% of a step in exactly attack/release ms.
        b.attackCoeff = exp(-1.0 / (attackMs * 0.001 * sampleRate))
        b.releaseCoeff = exp(-1.0 / (releaseMs * 0.001 * sampleRate))

        guard mode != .off else {
            if b.mode != .off {
                clearBank(index)
                b.env = 0
                b.level = 0
            }
            b.mode = .off
            setBandState(index, b)
            return
        }
        b.mode = mode
        let freq = (freqRaw.isFinite ? freqRaw : DynamicEQParams.defaultFreq(band: index + 1))
            .clamped(to: DynamicEQParams.freqRange)
        let q = (qRaw.isFinite ? qRaw : 2).clamped(to: DynamicEQParams.qRange)
        guard freq != b.lastFreq || q != b.lastQ || sampleRate != b.lastRate else {
            setBandState(index, b)
            return
        }
        b.lastFreq = freq
        b.lastQ = q
        b.lastRate = sampleRate
        // THROUGH THE ONE HOME (`EQFilterResponse`), never a second copy of the
        // RBJ cookbook. ⛔ The CONSTANT-0-dB-PEAK band-pass, not the
        // constant-skirt one: `thresholdDb` must mean dBFS at the band centre at
        // EVERY Q, or widening a band would silently lower its threshold.
        let section = EQFilterResponse.bandPassSection(freq: freq, q: q, sampleRate: sampleRate)
        b.c0 = section.b0
        b.c1 = section.b1
        b.c2 = section.b2
        b.d1 = section.a1
        b.d2 = section.a2
        setBandState(index, b)
    }

    /// RENDER-THREAD automation store (M4 vii-c). ⛔ SLOT ORDER IS
    /// `EffectParamSpec.specs(for: .dynamicEQ)` AND IT IS FROZEN, band-major,
    /// `slot = (band−1)·8 + p`: 0 band1Mode, 1 band1Freq, 2 band1Q,
    /// 3 band1ThresholdDb, 4 band1Ratio, 5 band1RangeDb, 6 band1AttackMs,
    /// 7 band1ReleaseMs, then the same eight for bands 2, 3 and 4 at 8…15,
    /// 16…23 and 24…31. Pokes a preallocated params copy and re-derives — no
    /// allocation, no locks.
    ///
    /// ⭐ **ALL 32 SLOTS ARE ACCEPTED**, and the guard is the WHOLE table. The
    /// two reasons this tree has ever refused a lane are both absent: nothing
    /// here needs tempo math (the `delay.sync` reason), and `latencySamples` is
    /// a literal 0 at every setting (the `saturator.oversampling` reason), so
    /// there is no PDC plan a store from this thread could leave stale.
    ///
    /// ⚠️ Slot `8k` (a band's `mode`) CAN clear that band's filter bank and
    /// envelopes when it leaves the on state (`deriveBand`). That is bounded
    /// work on a fixed struct — 16 stores and two assignments, not an
    /// allocation — and not a reason to refuse it.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...(DynamicEQParams.slotCount - 1)).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.band1Mode = value
        case 1: overlay.effective.band1Freq = value
        case 2: overlay.effective.band1Q = value
        case 3: overlay.effective.band1ThresholdDb = value
        case 4: overlay.effective.band1Ratio = value
        case 5: overlay.effective.band1RangeDb = value
        case 6: overlay.effective.band1AttackMs = value
        case 7: overlay.effective.band1ReleaseMs = value
        case 8: overlay.effective.band2Mode = value
        case 9: overlay.effective.band2Freq = value
        case 10: overlay.effective.band2Q = value
        case 11: overlay.effective.band2ThresholdDb = value
        case 12: overlay.effective.band2Ratio = value
        case 13: overlay.effective.band2RangeDb = value
        case 14: overlay.effective.band2AttackMs = value
        case 15: overlay.effective.band2ReleaseMs = value
        case 16: overlay.effective.band3Mode = value
        case 17: overlay.effective.band3Freq = value
        case 18: overlay.effective.band3Q = value
        case 19: overlay.effective.band3ThresholdDb = value
        case 20: overlay.effective.band3Ratio = value
        case 21: overlay.effective.band3RangeDb = value
        case 22: overlay.effective.band3AttackMs = value
        case 23: overlay.effective.band3ReleaseMs = value
        case 24: overlay.effective.band4Mode = value
        case 25: overlay.effective.band4Freq = value
        case 26: overlay.effective.band4Q = value
        case 27: overlay.effective.band4ThresholdDb = value
        case 28: overlay.effective.band4Ratio = value
        case 29: overlay.effective.band4RangeDb = value
        case 30: overlay.effective.band4AttackMs = value
        default: overlay.effective.band4ReleaseMs = value
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

    /// m39-d CR-2 (design §5.4): deliberately a no-op — class (c): band coefficients step at the
    /// store; detectors carry per sample.
    func beginControlCell(frames: Int) {}

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }

        let strideBytes = MemoryLayout<Float>.stride
        // Gather channel pointers once (fixed-size stack storage, no heap).
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

        // ⛔ BAND-OUTER, THEN FRAME, THEN CHANNEL, and all three levels are
        // forced rather than chosen:
        //   · BAND-OUTER is what makes the cascade a SERIES — band b+1 simply
        //     reads the buffer band b just wrote.
        //   · FRAME OUTSIDE CHANNEL is what makes the detector STEREO-LINKED.
        //     One gain for all channels, or the stereo image shifts every time a
        //     band moves. (This is precisely the nesting `EQEffect` does NOT
        //     have — it is channel-outer — and the reason a dynamic mode could
        //     not be bolted onto that kind.)
        //   · The bank is hoisted into a LOCAL once per band per block, so the
        //     inner loop runs ONE switch (on channel, inside `InlineBiquads`)
        //     rather than a nested one.
        for index in 0..<Self.bandCount {
            var b = bandState(index)
            // ⛔ A BAND AT `mode == 0` IS NOT STEPPED AT ALL — not multiplied by
            // one, not run and discarded. That is what makes a fresh Dynamic EQ
            // bit-exact transparent rather than merely inaudible, and it is what
            // `DynamicEQRenderTests.offBandIsNotStepped` proves by sweeping an
            // off band's freq/Q/threshold wildly and demanding identical bytes.
            guard b.mode != .off else { continue }
            var filters = bank(index)
            var side = InlineSidePath()
            let above = b.mode == .above
            let thresholdDb = b.thresholdDb
            let k = b.k
            let knee = DynamicEQParams.kneeDb
            let rangeMagnitude = abs(b.rangeDb)
            // The SIGN carries the direction. Exactly 0 at rangeDb 0, which
            // makes `targetDb` exactly 0 and the apply branch below never fire.
            let rangeSign: Double = b.rangeDb > 0 ? 1 : (b.rangeDb < 0 ? -1 : 0)
            let attackCoeff = b.attackCoeff
            let releaseCoeff = b.releaseCoeff
            let c0 = b.c0, c1 = b.c1, c2 = b.c2, d1 = b.d1, d2 = b.d2
            var env = b.env
            var level = b.level

            for frame in 0..<minFrames {
                // 1. The side path, per channel — the band-isolated signal that
                //    is BOTH what the detector reads and what the gain is
                //    applied through.
                var peak = 0.0
                for channel in 0..<channelCount {
                    var s = filters.step(channel, Double(channelData[channel]![frame]),
                                         b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
                    // ⛔⛔ THE NaN GUARD LIVES HERE, AT THE PRODUCER, AND IT
                    // MATTERS MORE THAN THE COMPRESSOR'S. A recursive filter fed
                    // a NaN is poisoned FOREVER — z1/z2 never recover. In
                    // `CompressorEffect` a poisoned filter meant a dead
                    // DETECTOR, with the audio path untouched. **Here `s` is
                    // summed INTO the audio**, so an unguarded poison writes NaN
                    // into the mix on every subsequent sample, for the rest of
                    // the session, with nothing logged. Clearing the whole bank
                    // (16 stores, no allocation) rather than one section is
                    // deliberate: a poisoned bank is useless, and a buffer
                    // carrying a NaN is already a catastrophe upstream.
                    if !s.isFinite { filters.clearAll(); s = 0 }
                    side[channel] = s
                    let magnitude = abs(s)
                    if magnitude > peak { peak = magnitude }
                }
                // 2. Peak follower — instant attack, fixed 5 ms decay, the
                //    compressor's semantics verbatim. STEREO-LINKED: one `peak`
                //    across all channels, so the image cannot shift.
                level = max(peak, level * detectorDecay)
                if level < 1e-20 { level = 0 }  // denormal flush on silence
                // 3. Band level in dB.
                let levelDb = 20.0 * log10(max(level, 1e-9))
                // 4. Distance past the threshold, SIGN-NORMALISED so `over > 0`
                //    always means "triggered", in both modes.
                //    ⚠️ `below` can never be "not triggered" on digital silence:
                //    level 0 reads as −180 dBFS, so `over = T + 180` and the band
                //    sits at full range. That is what an expander does to
                //    silence and it is correct — see the kind's `mode` note.
                let over = above ? (levelDb - thresholdDb) : (thresholdDb - levelDb)
                // 5. Depth — a NON-NEGATIVE magnitude, through the compressor's
                //    quadratic soft knee with `k = 1 − 1/ratio` (the NEGATION of
                //    the compressor's `slope`, because this is a magnitude).
                //    ⚠️ THE SAME LAW RUNS IN BOTH MODES, deliberately: one law,
                //    one set of tests, and a `ratio` that means the same thing in
                //    both directions for a user who is not a dynamics
                //    specialist. A builder who knows expanders will expect
                //    `(R − 1)·(T − L)` below the threshold — that is a recorded
                //    design decision (design §4.3 / §14.3), not an omission.
                let depthRaw: Double
                if 2.0 * over <= -knee {
                    depthRaw = 0
                } else if 2.0 * over >= knee {
                    depthRaw = k * over
                } else {
                    let t = over + knee / 2.0
                    depthRaw = k * t * t / (2.0 * knee)
                }
                // 6. Signed target, capped by the band's own range.
                let targetDb = rangeSign * min(depthRaw, rangeMagnitude)
                // 7. ⛔⛔ BALLISTICS — AND THIS IS *NOT* THE COMPRESSOR'S LINE.
                //    `CompressorEffect.swift:487` reads `targetDb < env` and
                //    `:489` snaps at `env > -1e-10`. Both are correct THERE only
                //    because a compressor's `env` is never positive. This band's
                //    range is SIGNED:
                //      · `targetDb < env` would give a band working UPWARD its
                //        attack and release BACKWARDS;
                //      · `env > -1e-10` is true for EVERY POSITIVE VALUE, so a
                //        boost band would have its gain snapped to zero on every
                //        sample and would silently do nothing, forever — while
                //        every test that exercises only downward bands still
                //        passed.
                //    `|targetDb| > |env|` is correct in both directions, and a
                //    crossing of zero (reachable when `rangeDb` is automated
                //    through 0) correctly reads as release-then-attack. The
                //    rest-snap is TWO-SIDED for the same reason.
                //    `DynamicEQRenderTests.aBoostBandActuallyBoosts` is the pin.
                let coeff = abs(targetDb) > abs(env) ? attackCoeff : releaseCoeff
                env = coeff * env + (1.0 - coeff) * targetDb
                if abs(env) < 1e-10 { env = 0 }
                // 8. Apply. ⛔ A REAL BRANCH, NOT A MULTIPLY BY ZERO. `x += 0.0 *
                //    s` is NOT a no-op: for `x == -0.0`, IEEE-754
                //    round-to-nearest gives `-0.0 + 0.0 = +0.0`, a DIFFERENT BIT
                //    PATTERN. On silent or near-silent frames that is a
                //    byte-gate failure with no audible cause. ⚠️ And the branch
                //    is ONLY around the add — the filter above is still stepped,
                //    because it has memory.
                let gMinus1 = pow(10.0, env / 20.0) - 1.0
                if gMinus1 != 0 {
                    for channel in 0..<channelCount {
                        channelData[channel]![frame] = Float(
                            Double(channelData[channel]![frame]) + gMinus1 * side[channel])
                    }
                }
            }

            b.env = env
            b.level = level
            setBandState(index, b)
            setBank(index, filters)
        }
    }
}
