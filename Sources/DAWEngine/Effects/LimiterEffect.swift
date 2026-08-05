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
/// TRUE-PEAK MODE (m23-ch, `LimiterParams.truePeak`, opt-in, DEFAULT OFF).
/// The flag decides WHICH PEAK `ceilingDb` counts — OFF it is a dBFS SAMPLE
/// peak (everything above), ON it is a dBTP TRUE peak. A sample-peak ceiling
/// MUST read above itself on a dBTP meter, because the meter reconstructs the
/// waveform between samples and a brickwall that only sees the samples cannot
/// see those peaks. That gap (measured 0.43–0.98 dB on real dense material)
/// is what forced a user's mastering agent through four renders of manual
/// headroom guessing — an ambiguous ceiling unit, not a bug. With the flag ON
/// the DETECTION signal — and only the detection signal — is 4× oversampled:
///  · The interpolator is `DAWCore.Loudness.interpolatorPhases`, THE ONE
///    HOME: the identical taps the project's dBTP meter, `Loudness.Stream`
///    and `ReferenceAnalyzer` use (BS.1770-4 Annex 2, phases 1–3 × 32 taps,
///    Kaiser β = 6). Deliberately imported, never copied — a second
///    estimator would let the ceiling and the meter disagree.
///  · Phase p's group delay is `32/2 − p/4`, so the dot products computed at
///    input sample n estimate the signal BETWEEN base samples n−16 and n−15.
///    Those magnitudes are therefore folded into the deque entry pushed at
///    position n, alongside |x(n)| itself. For the sample leaving the delay
///    line at index m the window [m, m+D] then contains BOTH its own sample
///    peak (position m) AND its inter-sample estimate (position m+16) — so
///    the peak-hold, window length, deque capacity and `latencySamples`
///    (still 240 @ 48 kHz — the 16-sample detector delay is absorbed by the
///    5 ms lookahead) are all unchanged, and a mode toggle mid-stream stays
///    seamless because deque positions never move. Requires D ≥ 16, i.e.
///    fs ≥ 3.2 kHz.
///  · Flag OFF (the default, so this is what every EXISTING project renders)
///    pushes exactly `|x(n)|`, the pre-m23-ch expression — the OFF arm is the
///    pre-m23-ch limiter BIT FOR BIT, by construction rather than by
///    approximation, and it skips the 96 multiply-adds per sample per channel
///    entirely. Test-pinned against an independent oracle of the old
///    algorithm, not merely against itself.
///  · The bit-exact null survives in BOTH modes: detection is a MAX that
///    includes |x(n)|, and material whose reconstructed peak never reaches
///    the ceiling leaves `target` at exactly 1.0, so the envelope never
///    leaves 1.0 and the output is the delayed dry signal bit for bit. ON
///    limits EARLIER than OFF, never MORE OFTEN than the ceiling demands.
///  · RESIDUAL, stated honestly and MEASURED (2026-08-04, ceiling −1.0, the
///    `LimiterTruePeakTests` L6 arms verified with ffmpeg `ebur128
///    peak=true` and against a 16× high-order reconstruction):
///      – 4× is the BS.1770-4 METERING GRID, not the continuous peak. On
///        realistic dense programme material (fs/4 tone + drum-flavoured
///        transients) the ON render measured **−1.00 dBTP by ffmpeg and
///        −0.98 by the 16× arbiter** — the grid error is a few hundredths of
///        a dB and the delivery target is genuinely met. The OFF arm on the
///        same material measured +0.92 dBTP: 1.9 dB over its own ceiling,
///        which is the non-bug this mode exists to explain.
///      – On content with FULL-SCALE energy right up to Nyquist (white-noise
///        bursts — not programme material), the grid error grows to several
///        tenths of a dB: the same render measured ours −1.00, ffmpeg −0.92,
///        16× arbiter −0.53. NO 4× limiter of any design holds a true
///        continuous −1.0 there, because the clamped quantity (the 4× grid
///        maximum) genuinely diverges from the continuous peak. Two
///        different 4× estimators also disagree by ~0.09 dB on such content.
///      – Applying the gain at base rate re-modulates the signal across the
///        interpolator's 32-tap span, which can reintroduce a little
///        inter-sample content; it is inside the numbers above.
///      – `ceilingDb` is dBTP AT THIS LIMITER'S OWN SAMPLE RATE. Any
///        downstream sample-rate conversion (a 44.1 k delivery from a 48 k
///        graph) re-creates inter-sample peaks this guarantee does not cover.
///    It is a true-peak MODE, not an absolute true-peak guarantee. The
///    SAMPLE-peak guarantee above stays absolute in both modes.
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention.
/// All buffers (delay lines, deque, true-peak taps and history rings) are
/// preallocated in `prepare` on the main actor. Render-path contract:
/// `process()`/`reset()` allocate nothing, take no locks, log nothing, touch
/// no ObjC.
final class LimiterEffect: EffectRendering, GainReductionReporting,
                           @unchecked Sendable {
    private static let maxChannels = 8
    /// True-peak interpolation phases (1–3; phase 0 IS the original sample).
    private static let tpPhaseCount = 3

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
    /// True-peak taps, `Loudness.interpolatorPhases` flattened to
    /// 3 × `tpTapsPerPhase` in Float (tap ORDER per phase preserved, so each
    /// phase is one ascending-k walk). Peak DETECTION only — Float carries
    /// ~1.6e-5 dB of worst-case summation error over 32 taps, far below any
    /// audible or metering threshold.
    private var tpTaps: UnsafeMutablePointer<Float>?
    /// Per-channel DOUBLE-WRITTEN input history (`2 * tpTapsPerPhase` per
    /// channel, the `Loudness.Stream` idiom): each sample is stored at `slot`
    /// and `slot + tpTapsPerPhase`, so `history[slot + k]` for k = 0..<taps is
    /// always one contiguous newest-to-oldest walk with no per-tap wrap math.
    private var tpHistory: UnsafeMutablePointer<Float>?
    private var tpTapsPerPhase = 0
    /// Newest-sample slot, shared across channels (they advance together).
    private var tpSlot = 0

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    private var ceilingLinear: Float = 0.891250938  // −1 dB
    private var releaseCoeff: Float = 0
    /// m23-ch: derived from `LimiterParams.truePeak` alongside the other
    /// render constants, so the generation/automation/revert routes all reach
    /// it through the same door.
    private var useTruePeak = false
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
        tpTaps?.deallocate()
        tpHistory?.deallocate()
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
        delaySamples = LimiterParams.lookaheadSamples(sampleRate: sampleRate)

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
        // True-peak detection storage (m23-ch) — allocated UNCONDITIONALLY,
        // whatever the current flag says, because the flag can flip at any
        // quantum via a param publish or an automation lane and the render
        // path must never allocate. The window/deque above are NOT resized:
        // the true-peak estimates ride the existing positions (header).
        let taps = Loudness.interpolatorPhases.first?.count ?? 0
        if tpTapsPerPhase != taps || tpTaps == nil || tpHistory == nil {
            tpTaps?.deallocate()
            tpHistory?.deallocate()
            tpTapsPerPhase = taps
            // `max(1, …)`: the pointers are NEVER nil after prepare, so the
            // render path holds plain non-optional locals and a degenerate
            // taps == 0 disables the mode (via `useTruePeak`) instead of
            // turning the whole limiter into a no-op.
            let tapBuffer = UnsafeMutablePointer<Float>.allocate(
                capacity: max(1, Self.tpPhaseCount * taps))
            for (phase, coefficients) in Loudness.interpolatorPhases.enumerated()
            where phase < Self.tpPhaseCount {
                for k in 0..<taps { tapBuffer[phase * taps + k] = Float(coefficients[k]) }
            }
            tpTaps = tapBuffer
            tpHistory = .allocate(capacity: max(1, Self.maxChannels * 2 * taps))
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
        if let tpHistory, tpTapsPerPhase > 0 {
            tpHistory.update(repeating: 0, count: Self.maxChannels * 2 * tpTapsPerPhase)
        }
        tpSlot = 0
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
        useTruePeak = p.truePeak && tpTapsPerPhase > 0
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .limiter)`: 0 ceilingDb, 1 releaseMs,
    /// 2 truePeak. Pokes a preallocated params copy and re-derives — no
    /// allocation, no locks. The release smoother naturally declicks the
    /// quantum steps. Slot 2 IS accepted (unlike the delay's tempo sync,
    /// which the render thread genuinely cannot evaluate): its buffers are
    /// preallocated whatever the flag says, so a lane may flip the mode
    /// without allocating — silently dropping a lane the schema advertises
    /// would be the worse failure.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...2).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.ceilingDb = value
        case 1: overlay.effective.releaseMs = value
        default: overlay.effective.truePeak = value >= 0.5
        }
        deriveRenderParams(overlay.effective)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard let delayLine, let dequeValues, let dequePositions,
              let tpTaps, let tpHistory else { return }

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
        // m23-ch true-peak detection state, hoisted out of the loop.
        let taps = tpTapsPerPhase
        let tpChannelStride = 2 * taps
        let trackTruePeak = useTruePeak && taps > 0
        // Hoisted: a `static let` read inside the per-sample loop compiles to
        // an accessor call at -Onone, which is measurable work in the hot
        // path (and, on this class, showed up in the malloc probe).
        let phaseCount = Self.tpPhaseCount
        var tpWrite = tpSlot
        // EVERY LOOP FROM HERE DOWN IS `while`, NOT `for … in 0..<n`. At
        // -Onone (which is how the test suite — and therefore the render-path
        // allocation probe — builds this file) Range iteration raises ~2
        // malloc/free events PER ITERATION from its own generic machinery.
        // Before m23-ch this loop nest was `for`-based and measured 10 heap
        // events per FRAME on the render path; the m23-r1 probe in
        // `LimiterTruePeakTests` L7 now pins it at 0 in both modes. The
        // arithmetic and its order are untouched — L1's bit-exact oracle is
        // what proves that.
        var frame = 0
        while frame < minFrames {
            // Newest sample into the interpolator history — written in BOTH
            // modes (two stores per sample per channel) so flipping the flag
            // mid-stream starts from a WARM filter instead of 32 stale
            // samples. Costs nothing measurable and never touches the output.
            if taps > 0 { tpWrite = tpWrite == 0 ? taps - 1 : tpWrite - 1 }
            // Stereo-linked peak of the INCOMING sample.
            var peak: Float = 0
            var channel = 0
            while channel < channelCount {
                let raw = channelData[channel]![frame]
                let sample = abs(raw)
                if sample > peak { peak = sample }
                if taps > 0 {
                    // NaN/Inf never enters the interpolator — one poisoned
                    // sample would otherwise smear across 32 taps. (`abs(raw)
                    // .isFinite` ≡ `raw.isFinite`; the peak comparison above
                    // already rejects NaN by falling through.)
                    let base = channel * tpChannelStride + tpWrite
                    let sanitized = sample.isFinite ? raw : 0
                    tpHistory[base] = sanitized
                    tpHistory[base + taps] = sanitized
                }
                channel += 1
            }
            // 4× TRUE-PEAK detection (m23-ch) — ONLY when the flag is on, so
            // the default path pays not one multiply-add. Each phase is one
            // contiguous ascending-k walk over the double-written history,
            // the exact `Loudness` order. Raw pointers + `while` loops: this
            // runs ~96 MACs/sample/channel and the test suite builds -Onone,
            // where Range iteration costs generic-metadata lookups per step.
            // The magnitudes belong to the interval between base samples
            // n−16 and n−15; they are folded into THIS sample's deque entry
            // (header) so the window geometry never changes.
            if trackTruePeak {
                channel = 0
                while channel < channelCount {
                    let history = tpHistory + channel * tpChannelStride + tpWrite
                    var phase = 0
                    while phase < phaseCount {
                        let coefficients = tpTaps + phase * taps
                        var accumulator: Float = 0
                        var k = 0
                        while k < taps {
                            accumulator += coefficients[k] * history[k]
                            k += 1
                        }
                        let magnitude = abs(accumulator)
                        if magnitude > peak { peak = magnitude }
                        phase += 1
                    }
                    channel += 1
                }
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
            channel = 0
            while channel < channelCount {
                let data = channelData[channel]!
                let slot = channel * delayCapacityPerChannel + writeIndex
                let delayed = delayLine[slot]
                delayLine[slot] = data[frame]
                data[frame] = delayed * env
                channel += 1
            }
            writeIndex += 1
            if writeIndex == delaySamples { writeIndex = 0 }
            n += 1
            frame += 1
        }
        envelope = env
        grHeldLinear = grHeld
        delayWriteIndex = writeIndex
        sampleCounter = n
        tpSlot = tpWrite
        // Publish positive dB of reduction: pure libm log10 once per
        // quantum, floored at 10^(−80/20) so the value caps at 80 dB.
        GainReductionMeter.publish(
            grSlot,
            db: -20.0 * log10f(max(grHeld, GainReductionMeter.floorLinear)))
    }
}
