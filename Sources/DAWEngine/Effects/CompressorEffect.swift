import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in soft-knee downward compressor (M4 iii). Topology (the classic
/// log-domain feed-forward design):
///   [de-ess detector filter (m39-ae, OFF by default)] → stereo-linked peak
///   detector → log-domain gain computer (quadratic soft knee) → one-pole
///   attack/release smoothing ON THE GAIN SIGNAL → makeup → parallel dry/wet
///   blend (m23-ck).
///
/// ## The de-esser (m39-ae) — one filter, on the detector, and nowhere else
///
/// `detectorMode` 1/2 inserts a per-channel 2-pole biquad (`Primitives/Biquad`)
/// in front of the peak detector. **It is not in the audio path.** The samples
/// that get multiplied by the computed gain are the same samples that arrived;
/// the filter only changes WHICH of them the unit decides to react to. That is
/// the whole of a wideband de-esser, it needs no crossover, and it adds ZERO
/// latency — `latencySamples` stays a literal 0, so no existing project moves
/// in time and delay compensation has nothing new to plan.
///
/// ⛔⛔ **THE DEFAULT IS OFF AND IT IS BIT-EXACT, NOT "CLOSE".** At
/// `detectorMode` 0 the filter is never stepped and the detector's expression
/// is character-for-character what it was: `abs(channelData[c]![frame])`. The
/// branch that chooses between filtered and raw is OUTSIDE the arithmetic, so
/// the raw path's rounding cannot change. Pinned off rendered audio — including
/// a SIDECHAIN-KEYED variant, because the keyed detector loop is the branch
/// this item restructured — by
/// `scripts/gates/m39ae-compressor-default-bytes.mjs`.
///
/// ⚠️ The filter composes with the sidechain key rather than competing with it:
/// with a key attached it is the KEY that gets filtered, because the key IS the
/// detector's input. The dry signal is always this effect's own main input.
///
/// The blend is `out = mix·wet + (1−mix)·dry` with the dry term the unit's own
/// MAIN input at the same sample index — the compressor has no lookahead and
/// reports `latencySamples == 0`, so no delay compensation is needed and the
/// blend cannot comb. `mix` defaults to 1 (fully wet), which collapses the
/// blend back to the original single multiply, bit-for-bit.
///
/// The detector is an instant-attack peak follower with a short FIXED 5 ms
/// decay (not the raw rectified sample): it bridges the rectifier's
/// zero-crossing dips so a steady tone reads as its peak level and the static
/// curve matches theory (measured −14.96 dBFS out for a −6 dBFS 1 kHz sine at
/// −18 dB threshold / 4:1 — the textbook −15). 5 ms is well under the minimum
/// release (5 ms floor), so attack/release timing stays governed by the gain
/// smoother.
///
/// With the envelope at rest and no makeup, the computed gain is EXACTLY 1.0
/// (pow(10, 0) == 1), so below-threshold input nulls bit-exact against dry.
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention;
/// smoothing coefficients recompute only on generation change (they depend on
/// the prepared sample rate). Render-path contract: `process()`/`reset()`
/// allocate nothing, take no locks, log nothing, touch no ObjC — per-sample
/// log10/pow are pure libm. The envelope snaps to 0 near rest (denormal/
/// asymptote guard).
final class CompressorEffect: KeyableEffectRendering, GainReductionReporting,
                              @unchecked Sendable {
    private static let maxChannels = 8

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: CompressorParams

        init(generation: UInt64, params: CompressorParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Render-thread-only state.
    private var sampleRate: Double = 48_000
    private var lastGeneration = UInt64.max
    private var thresholdDb = -18.0
    private var slope = 1.0 / 4.0 - 1.0  // (1/ratio − 1) ≤ 0, dB of reduction per dB over
    private var kneeDb = 6.0
    private var makeupDb = 0.0
    /// Parallel-compression blend (m23-ck), pre-split so the inner loop does
    /// one multiply-add and no branch: `wet = mix`, `dry = 1 − mix`. Defaults
    /// are fully wet (1, 0) — the pre-m23-ck compressor exactly.
    private var mixWet = 1.0
    private var mixDry = 0.0
    private var attackCoeff = 0.0   // per-sample one-pole feedback coefficient
    private var releaseCoeff = 0.0
    /// De-ess detector filter (m39-ae). `detectorActive` false is the DEFAULT
    /// and the bit-exact path: the filters are never stepped and the coeffs
    /// are never read. One section per channel — the detector is stereo-LINKED
    /// (it takes the max across channels) but the FILTER cannot be, because a
    /// filter has memory and sharing one section between channels would make
    /// the result depend on channel order.
    private var detectorActive = false
    private var detectorFilters = InlineBiquads()
    private var dB0 = 0.0, dB1 = 0.0, dB2 = 0.0, dA1 = 0.0, dA2 = 0.0
    /// Coefficient cache. Recomputing `sin`/`cos` on every automation store is
    /// affordable but pointless; this makes a lane on `thresholdDb` — which
    /// routes through the same `deriveRenderParams` — cost nothing extra.
    /// ⚠️ Seeded with NaN so the FIRST derive always recomputes: `NaN != NaN`,
    /// whereas a 0 seed would collide with a real request for 0.
    private var lastDetectorFreq = Double.nan
    private var lastDetectorQ = Double.nan
    private var lastDetectorMode = CompressorParams.DetectorMode.off
    private var lastDetectorRate = Double.nan
    /// Smoothed gain reduction in dB (≤ 0; 0 = no reduction).
    private var envelopeDb = 0.0
    /// Instant-attack peak-follower state (linear) + its fixed 5 ms decay.
    private var detectorLevel = 0.0
    private var detectorDecay = 0.0
    private var preparedChannels = 2
    /// GR meter (m22-e): held-peak reduction in POSITIVE dB. The envelope is
    /// already in the dB domain, so the −20 dB/s release is a per-sample
    /// SUBTRACTION (`grDecayDbPerSample`) — linear-in-dB, exactly the peakDB
    /// convention. Render-thread-only state; published via `grSlot`.
    private var grHeldDb = 0.0
    private var grDecayDbPerSample = 0.0
    /// Render → control-plane publish slot (`Float.bitPattern`), one atomic
    /// store per quantum. See `GainReductionMeter`.
    private let grSlot: UnsafeMutablePointer<daw_atomic_u32>
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<CompressorParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: CompressorParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: CompressorParams = CompressorParams()) {
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
    }

    // MARK: - GainReductionReporting (m22-e)

    /// Held-peak gain reduction, POSITIVE dB (0 = untouched), −20 dB/s
    /// release. One atomic load — safe from any thread.
    var gainReductionDb: Float { Float(bitPattern: daw_atomic_u32_load(grSlot)) }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: CompressorParams) {
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
        envelopeDb = 0
        detectorLevel = 0
        detectorDecay = exp(-1.0 / (0.005 * sampleRate))  // fixed 5 ms peak decay
        grHeldDb = 0
        grDecayDbPerSample = GainReductionMeter.decayDbPerSample(sampleRate: sampleRate)
        GainReductionMeter.publish(grSlot, db: 0)
        // m39-ae: the de-ess sections are STATE and a rate change invalidates
        // both them and their coefficients. `lastDetectorRate` is compared, not
        // assigned here, so the next derive cannot decide nothing changed.
        detectorFilters.clearAll()
        lastDetectorRate = .nan
        lastGeneration = .max  // re-derive coefficients at the new rate
    }

    /// ⛔ A LITERAL 0, AND IT STAYS ONE. m39-ae adds a filter to the DETECTOR,
    /// which needs no lookahead and no delay line, so nothing here becomes
    /// parameter-dependent. (Contrast `SaturatorEffect`, whose latency DOES
    /// depend on a param and which therefore had to refuse an automation lane
    /// on it — see `Automation.swift`. This kind refuses none of its three new
    /// params for that reason, because the reason does not exist here.)
    var latencySamples: Int { 0 }

    /// Clears the envelopes — post-reset output is uncompressed immediately,
    /// and the GR meter honestly reads 0 (atomic store — render-thread safe).
    /// m39-ae: the de-ess filter sections are cleared too, so a transport stop
    /// does not leave a decaying tail from the last "sss" biasing the first
    /// samples after the restart.
    func reset() {
        envelopeDb = 0
        detectorLevel = 0
        grHeldDb = 0
        detectorFilters.clearAll()
        GainReductionMeter.publish(grSlot, db: 0)
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
    /// math (pure libm, no allocation; render-thread safe).
    private func deriveRenderParams(_ p: CompressorParams) {
        thresholdDb = p.thresholdDb
        slope = 1.0 / p.ratio - 1.0
        kneeDb = p.kneeDb
        makeupDb = p.makeupDb
        mixWet = p.mix
        mixDry = 1.0 - p.mix
        // One-pole time constants: coeff = e^(−1/(ms·rate)); the
        // envelope covers 63.2% of a step in exactly attack/release ms.
        attackCoeff = exp(-1.0 / (p.attackMs * 0.001 * sampleRate))
        releaseCoeff = exp(-1.0 / (p.releaseMs * 0.001 * sampleRate))
        deriveDetectorFilter(p)
    }

    /// m39-ae — the de-ess detector filter's coefficients.
    ///
    /// ⚠️⚠️ **EVERY FIELD IS RE-GUARDED AND RE-CLAMPED HERE, and that is a
    /// correctness requirement rather than defensive habit.** A field-by-field
    /// overlay poke from `storeAutomatedParam` BYPASSES `CompressorParams.init`,
    /// so that init's clamping is not in force — the `ClipperEffect` comment
    /// spells out the same trap. Two of the three ways this bites are specific:
    ///   · `detectorMode(at:)` does an `Int()` conversion, which **TRAPS** on a
    ///     NaN (the `RingModParams.waveform` precedent). It guards `isFinite`
    ///     itself, and that guard is the reason it exists rather than a local
    ///     `Int(round(x))`.
    ///   · an unclamped `detectorFreqHz` at or above Nyquist makes `w0` reach
    ///     π, where the section is degenerate. `min(freq, sampleRate * 0.49)`
    ///     inside `EQFilterResponse` already covers it; clamping to the
    ///     DECLARED range first means the clamp the user is told about is the
    ///     clamp that happens, at every sample rate down to 32 kHz where
    ///     16 kHz would otherwise be half of Nyquist.
    ///
    /// The `sin`/`cos` are skipped unless the mode is on AND something the
    /// coefficients depend on actually moved, so an automation lane riding
    /// `thresholdDb` — which routes through `deriveRenderParams` and therefore
    /// through here — costs three comparisons per quantum and no trig.
    /// Render-thread safe: pure libm, no allocation, no locks.
    private func deriveDetectorFilter(_ p: CompressorParams) {
        let mode = CompressorParams.detectorMode(at: p.detectorMode)
        guard mode != .off else {
            detectorActive = false
            // ⛔ The sections are CLEARED when the mode leaves, not when it
            // arrives. Clearing on arrival would be the same thing at a steady
            // state and WRONG during an automated 0→1→0→1 flutter: the filter
            // would restart from silence on every re-entry and click. Clearing
            // on exit means a re-entry starts from a state that is already zero
            // because nothing fed it while it was off.
            if lastDetectorMode != .off { detectorFilters.clearAll() }
            lastDetectorMode = .off
            return
        }
        let freq = (p.detectorFreqHz.isFinite ? p.detectorFreqHz : 6_500)
            .clamped(to: CompressorParams.detectorFreqRange)
        let q = (p.detectorQ.isFinite ? p.detectorQ : 2)
            .clamped(to: CompressorParams.detectorQRange)
        detectorActive = true
        guard mode != lastDetectorMode || freq != lastDetectorFreq
                || q != lastDetectorQ || sampleRate != lastDetectorRate else { return }
        lastDetectorMode = mode
        lastDetectorFreq = freq
        lastDetectorQ = q
        lastDetectorRate = sampleRate
        // THROUGH THE ONE HOME (`EQFilterResponse`), never a second copy of the
        // RBJ cookbook. The band-pass is the constant-0-dB-PEAK form on
        // purpose: `thresholdDb` must mean the same dBFS banded as broadband.
        let section: EQBiquad = mode == .bandPass
            ? EQFilterResponse.bandPassSection(freq: freq, q: q, sampleRate: sampleRate)
            : EQFilterResponse.cutSection(highPass: true, freq: freq, q: q,
                                          sampleRate: sampleRate)
        dB0 = section.b0
        dB1 = section.b1
        dB2 = section.b2
        dA1 = section.a1
        dA2 = section.a2
    }

    /// RENDER-THREAD automation store (M4 vii-c). ⛔ SLOT ORDER IS
    /// `EffectParamSpec.specs(for: .compressor)` AND IT IS FROZEN: 0
    /// thresholdDb, 1 ratio, 2 attackMs, 3 releaseMs, 4 kneeDb, 5 makeupDb,
    /// 6 mix, 7 detectorMode, 8 detectorFreqHz, 9 detectorQ. Pokes a
    /// preallocated params copy and re-derives — no allocation, no locks. The
    /// envelope smoother naturally declicks the quantum steps. Slot 6 (m23-ck)
    /// IS accepted: the blend is two multiplies against state that already
    /// exists, so a lane can ride it without allocating anything.
    ///
    /// ⭐ m39-ae's three slots are ALL accepted, and the contrast with
    /// `SaturatorEffect` — which guards `(0...2)` and refuses a lane on its
    /// fourth param — is the point. That refusal is about LATENCY: the
    /// saturator's `latencySamples` depends on its factor, and moving it from
    /// the render thread would leave the delay-compensation plan stale. This
    /// kind reports a literal 0 at every setting of every param, so there is no
    /// plan to invalidate. Slot 7 does clear the filter sections when it leaves
    /// the on state (`deriveDetectorFilter`), which is bounded work on a fixed
    /// struct — not an allocation, and not a reason to refuse.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...9).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.thresholdDb = value
        case 1: overlay.effective.ratio = value
        case 2: overlay.effective.attackMs = value
        case 3: overlay.effective.releaseMs = value
        case 4: overlay.effective.kneeDb = value
        case 5: overlay.effective.makeupDb = value
        case 6: overlay.effective.mix = value
        case 7: overlay.effective.detectorMode = value
        case 8: overlay.effective.detectorFreqHz = value
        default: overlay.effective.detectorQ = value
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

    /// m39-d CR-2 (design §5.4): deliberately a no-op — class (c): the ballistics step at the store
    /// and the envelope carries per sample.
    func beginControlCell(frames: Int) {}

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        process(buffers: buffers, key: nil, frameCount: frameCount)
    }

    /// Keyed entry (m12-f, `KeyableEffectRendering`): with `key` non-nil the
    /// peak detector reads the KEY buffers while gain still applies to the
    /// main buffers; `key` nil is the plain path above — bit-exact self-keyed
    /// by construction (the detector loop reads the same main pointers in the
    /// same order; condition-4 pinned by test). Key frames past the delivered
    /// byte size read as silence.
    func process(buffers: UnsafeMutableAudioBufferListPointer,
                 key: UnsafeMutableAudioBufferListPointer?, frameCount: Int) {
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

        // Key channel gather (m12-f): same fixed-size stack shape, no heap.
        var keyData = InlineChannelPointers()
        var keyCount = 0
        var keyFrames = 0
        if let key {
            var delivered = frameCount
            for buffer in key where keyCount < Self.maxChannels {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                keyData[keyCount] = data
                delivered = min(delivered, Int(buffer.mDataByteSize) / strideBytes)
                keyCount += 1
            }
            if keyCount > 0 { keyFrames = delivered }
        }

        var env = envelopeDb
        var level = detectorLevel
        var grHeld = grHeldDb
        let grDecay = grDecayDbPerSample
        for frame in 0..<minFrames {
            // Stereo-linked peak detector: instant attack, fixed 5 ms decay.
            // Keyed: the detector listens to the KEY signal (frames beyond
            // the delivered key read as silence); self-keyed: the main signal.
            //
            // ⛔⛔ m39-ae: THE BRANCH IS OUTSIDE THE ARITHMETIC, AND THAT IS WHY
            // THE DEFAULT IS BIT-EXACT. The two `else` limbs below are the
            // pre-m39-ae expressions character-for-character — same operand
            // order, same `abs` on the same `Float`, same comparison. A
            // "filtered = active ? step(x) : x" one-liner would have read
            // better and would have been a REWRITE of the shipped path, which
            // is the shape that changes a low bit and passes every unit test.
            var peak: Float = 0
            if detectorActive {
                // The de-ess path: filter each detector channel, THEN rectify.
                // One section per channel — sharing one would make the result
                // depend on channel order.
                if keyCount > 0 {
                    if frame < keyFrames {
                        for channel in 0..<keyCount {
                            var filtered = detectorFilters.step(
                                channel, Double(keyData[channel]![frame]),
                                b0: dB0, b1: dB1, b2: dB2, a1: dA1, a2: dA2)
                            if !filtered.isFinite { detectorFilters.clearAll(); filtered = 0 }
                            let sample = abs(Float(filtered))
                            if sample > peak { peak = sample }
                        }
                    } else {
                        // ⚠️ KEY UNDERRUN, AND THE FILTER IS FED THE SILENCE
                        // RATHER THAN FROZEN. The unfiltered path above reads
                        // these frames as silence and that is the end of it;
                        // a 2-pole band-pass, though, is RECURSIVE — freezing
                        // it holds its last output and would keep the
                        // compressor pinned for the length of the underrun.
                        // Feeding zeros lets it ring down the way the signal
                        // actually did. Costs a loop only in a case that
                        // should not happen.
                        for channel in 0..<keyCount {
                            _ = detectorFilters.step(channel, 0,
                                                     b0: dB0, b1: dB1, b2: dB2,
                                                     a1: dA1, a2: dA2)
                        }
                    }
                } else {
                    for channel in 0..<channelCount {
                        var filtered = detectorFilters.step(
                            channel, Double(channelData[channel]![frame]),
                            b0: dB0, b1: dB1, b2: dB2, a1: dA1, a2: dA2)
                        // ⛔ THE NaN GUARD LIVES HERE, NOT IN `Biquad`. A
                        // recursive filter fed a NaN is poisoned FOREVER —
                        // z1/z2 never recover, so the de-esser would be dead
                        // for the rest of the session while every meter read
                        // 0 and nothing logged. Note the unfiltered path needs
                        // no such guard and has never had one: `NaN > peak` is
                        // false, so a NaN sample is simply not the peak. Only
                        // the filter has memory. Clearing the whole bank
                        // (16 stores, no allocation) rather than one section is
                        // deliberate: a poisoned bank is useless, and a buffer
                        // carrying a NaN is already a catastrophe upstream.
                        if !filtered.isFinite { detectorFilters.clearAll(); filtered = 0 }
                        let sample = abs(Float(filtered))
                        if sample > peak { peak = sample }
                    }
                }
            } else if keyCount > 0 {
                if frame < keyFrames {
                    for channel in 0..<keyCount {
                        let sample = abs(keyData[channel]![frame])
                        if sample > peak { peak = sample }
                    }
                }
            } else {
                for channel in 0..<channelCount {
                    let sample = abs(channelData[channel]![frame])
                    if sample > peak { peak = sample }
                }
            }
            level = max(Double(peak), level * detectorDecay)
            if level < 1e-20 { level = 0 }  // denormal flush on silence
            // Gain computer (log domain, quadratic soft knee).
            let levelDb = 20.0 * log10(max(level, 1e-9))
            let over = levelDb - thresholdDb
            let targetDb: Double
            if 2.0 * over <= -kneeDb {
                targetDb = 0
            } else if 2.0 * over >= kneeDb {
                targetDb = slope * over
            } else {
                let t = over + kneeDb / 2.0
                targetDb = slope * t * t / (2.0 * kneeDb)
            }
            // One-pole smoothing on the gain signal: attack when reduction
            // deepens, release when it recovers.
            let coeff = targetDb < env ? attackCoeff : releaseCoeff
            env = coeff * env + (1.0 - coeff) * targetDb
            if env > -1e-10 { env = 0 }  // snap at rest → exact unity below threshold
            // GR meter (m22-e): instant attack to the applied reduction
            // (−env, makeup EXCLUDED — makeup is static gain, not the
            // detector's doing), −20 dB/s linear-in-dB release. One max +
            // one subtract per sample; publish happens once after the loop.
            grHeld = max(-env, grHeld - grDecay)
            // Makeup applied last, then the m23-ck parallel blend folded into
            // the SAME per-sample scalar:
            //     out = mix·(x·wetGain) + (1−mix)·x = x·(mix·wetGain + 1−mix)
            // so parallel compression costs one multiply-add per sample, no
            // dry buffer, no branch, no extra state — and the plain and keyed
            // paths cannot diverge because there is only one application site.
            // At the default mix (wet 1, dry 0) this is `1·g + 0` on a strictly
            // positive g, which is `g` bit-for-bit: the pre-m23-ck expression.
            // NOTE the loop is NOT skipped at mix 0 (the saturator's trick):
            // this unit is STATEFUL — the detector, the gain smoother and the
            // GR meter must keep running or an automated mix 0→1 would snap
            // from stale state.
            let gain = Float(mixWet * pow(10.0, (env + makeupDb) / 20.0) + mixDry)
            for channel in 0..<channelCount {
                channelData[channel]![frame] *= gain
            }
        }
        envelopeDb = env
        detectorLevel = level
        grHeldDb = grHeld
        GainReductionMeter.publish(grSlot, db: Float(grHeld))
    }
}

/// Fixed-size stack storage for up to 8 channel pointers — avoids any heap
/// allocation for the per-quantum pointer gather on the render thread.
struct InlineChannelPointers {
    var p0, p1, p2, p3, p4, p5, p6, p7: UnsafeMutablePointer<Float>?

    init() {
        p0 = nil; p1 = nil; p2 = nil; p3 = nil
        p4 = nil; p5 = nil; p6 = nil; p7 = nil
    }

    subscript(index: Int) -> UnsafeMutablePointer<Float>? {
        get {
            switch index {
            case 0: return p0
            case 1: return p1
            case 2: return p2
            case 3: return p3
            case 4: return p4
            case 5: return p5
            case 6: return p6
            default: return p7
            }
        }
        set {
            switch index {
            case 0: p0 = newValue
            case 1: p1 = newValue
            case 2: p2 = newValue
            case 3: p3 = newValue
            case 4: p4 = newValue
            case 5: p5 = newValue
            case 6: p6 = newValue
            default: p7 = newValue
            }
        }
    }
}
