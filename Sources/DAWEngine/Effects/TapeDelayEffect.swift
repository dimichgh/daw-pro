import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in tape echo (m39-n), FREE-MS ONLY — ONE cubic-Hermite interpolated
/// read tap per channel whose position is pushed around by a wow LFO and a
/// two-component flutter, with the RECORD path saturated and low-passed so
/// every pass through the machine is duller and more compressed than the last.
///
/// ⭐ THIS IS THE FOURTH CALLER OF `InterpolatedDelayLine` (§4.1) and the first
/// one to ask for `.cubicHermite`, which §4.1 recommends to this effect BY
/// NAME: a slow deep wow sweeps the fractional tap continuously, and linear
/// interpolation's frequency-dependent loss (it is a one-zero low-pass whose
/// depth varies with the fraction) becomes an audibly dull, wobbling top end.
///
/// WHAT IT DOES, in the order the render path does it, per channel per sample:
///   1. **Tap** the line at `TapeDelayParams.readDelayMs(...)` samples behind
///      the write head, fractionally interpolated. That is `timeMs` MINUS the
///      transport offset — see the downward-only law in `TapeDelayParams`.
///   2. **Flush** the tapped value if it is denormally small.
///   3. **Record**: `toTape = dry + tapped · feedback`, then that word goes
///      through the tape stage — `TapeDelayParams.saturated` then a one-pole
///      high cut — and the filter state is flushed too. The result is written
///      at the write head.
///   4. **Mix** — `out = dry·(1−m) + tapped·m`. At `m == 0` exactly, THE BUFFER
///      IS NEVER WRITTEN — bit-exact dry by IEEE (rule 6.0.7) — while the tape
///      and the transport keep running, so raising `mix` later drops into
///      repeats that are already there.
///   5. **Advance** the single shared write head once per FRAME, after both
///      channels have been tapped and written.
///
/// ⛔ **THE TAPE STAGE IS IN THE RECORD PATH, NOT THE FEEDBACK PATH, AND THAT
/// IS THE ONE STRUCTURAL DIFFERENCE FROM `DelayEffect`.** There, the filter
/// sits inside the feedback loop only, so the FIRST echo is unfiltered and
/// untouched. On a real machine the signal is already on tape by the time it
/// reaches the playback head, so here the first repeat is already saturated and
/// rolled off, and each later one has been through the stage again. That is
/// what makes a long feedback dissolve instead of piling up.
///
/// ⛔ **ONE TRANSPORT, BOTH CHANNELS.** A tape machine has one motor and one
/// capstan; L and R wow together. There is deliberately no stereo phase
/// parameter, and the consequence is worth stating: a mono source stays
/// perfectly mono and a mono fold-down never cancels.
///
/// ⛔ **THE DENORMAL FLUSH IS THIS FILE'S JOB, NOT THE LINE'S (§4.1).**
/// `InterpolatedDelayLine` deliberately carries no flushing: the chorus it was
/// lifted from is feedback-free and provably cannot generate denormals, so a
/// per-sample branch in the home would tax a caller that does not need one.
/// This IS a feedback structure. TWO recirculating words are flushed here, and
/// both are needed: the TAPPED value (the line's own recirculation) and the
/// record-path LOW-PASS STATE (a one-pole holds its own decaying history, and
/// `tanh` preserves a subnormal rather than killing it, so a denormal that got
/// into the filter would stay there). The threshold is `abs(x) < 1e-20`,
/// matching `DelayEffect.swift`'s existing `if abs(lpL) < 1e-20 { lpL = 0 }`
/// rather than inventing a second approach.
///
/// ⚠️ **MEASURED BY PLANT, m39-n, and worth knowing before anyone "tidies"
/// one of them away: the two flushes are MUTUALLY REDUNDANT AT THE OUTPUT.**
/// The filter is the last stage before the write, so with ITS flush in place
/// the line can never hold a subnormal and the tap can never read one; and
/// with the TAP's flush in place, a subnormal the unflushed filter wrote is
/// killed on the way back out. Removing either one alone therefore leaves
/// every rendered sample spotless. `TapeDelayTests` L8 sees the FILTER one go
/// (by reading the state directly, at a stride fine enough to catch the
/// crossing) and sees BOTH go (in the output); **it cannot see the TAP one go,
/// and no gate in this tree can.** The tap flush is kept regardless — §4.1
/// obliges a feedback caller to flush its own recirculating word, it costs one
/// compare, and it is what survives someone later making the high cut
/// bypassable. The full plant table is in L8's own comment.
///
/// SMOOTHING (rule 6.0.6 — a new creative effect smooths its own derived state
/// internally): effect params arrive as ONE SCALAR PER QUANTUM, so the delay
/// time, both depths, the wow phase increment, the feedback coefficient, the
/// mix gain, the drive gain, the drive amount and the low-pass COEFFICIENT are
/// all interpolated **per sample** across the quantum. `timeMs` especially: a
/// per-quantum step in the read position of a fractional line is an audible
/// click, and interpolating it is exactly what turns a time move into the
/// varispeed glide the param note promises. The low-pass coefficient is
/// interpolated directly rather than re-deriving `1 − exp(−2π·fc/fs)` per
/// sample; it is monotonic in `fc` and the path between two stable one-pole
/// coefficients is stable, so there is no 32-frame stride here either.
/// ⚠️ THE TRANSPORT PHASES ARE NEVER RESET BY A PARAMETER CHANGE. `reset()`
/// clears them (a stop-time cut); `apply`/`storeAutomatedParam` never do, so an
/// automated rate change speeds the drift up without jumping it.
///
/// Parameter updates follow the `GainEffect` atomic-POD-publish convention.
/// Render-path contract: `process()`/`reset()` allocate nothing, take no locks,
/// log nothing, touch no ObjC, hop no actors. The line is preallocated in
/// `prepare()` for `TapeDelayParams.lineCapacitySeconds` (4.0 s — §4.1's
/// declared capacity for this caller), so every parameter move is arithmetic
/// and never an allocation.
final class TapeDelayEffect: EffectRendering, @unchecked Sendable {
    /// Denormal-flush threshold — `DelayEffect`'s existing constant and its
    /// existing shape, deliberately not a second one. −400 dB: far below
    /// anything audible, far above the subnormal boundary (~1.18e-38 for
    /// `Float`), so the tail is cut before it ever gets slow.
    private static let denormalFloor: Float = 1e-20

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: TapeDelayParams

        init(generation: UInt64, params: TapeDelayParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Prepared storage (main-actor allocated, render-thread used).
    private var sampleRate: Double = 48_000
    /// THE SHARED HOME (§4.1), used unchanged. Capacity is declared in SECONDS
    /// from `TapeDelayParams.lineCapacitySeconds` — the ONE HOME for the 4.0 s
    /// number. `.cubicHermite` is the interpolation §4.1 names for this effect.
    private let line = InterpolatedDelayLine(
        capacitySeconds: TapeDelayParams.lineCapacitySeconds, interpolation: .cubicHermite)

    /// Why the last `prepare()` refused, or nil if it succeeded. ⭐ NOT
    /// SWALLOWED, and that is deliberate: `FlangerEffect.prepare` catches the
    /// refusal into an empty block, so a caller that got the minimum-delay
    /// invariant wrong sees only a silent bit-exact passthrough with no message
    /// anywhere. Keeping the error here costs one stored property and makes the
    /// refusal readable from a test instead of inferable from silence. It is
    /// written on the main actor in `prepare()` and never touched by the render
    /// thread.
    private(set) var lastPrepareRefusal: InterpolatedDelayLine.PrepareRefusal?

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    /// Transport phases in RADIANS, [0, 2π): the wow motor and the two flutter
    /// components. Shared by both channels — one machine, one transport.
    private var wowPhase = 0.0
    private var flutterPhaseA = 0.0
    private var flutterPhaseB = 0.0
    /// Record-path one-pole low-pass state, per channel.
    private var lowpassL: Float = 0
    private var lowpassR: Float = 0

    // Interpolation endpoints. `previous*` is where the last quantum ENDED,
    // `target*` is what this quantum was asked for. All in RENDER units.
    private var previousTimeMs = 350.0
    private var targetTimeMs = 350.0
    private var previousWowIncrement = 2.0 * .pi * 0.8 / 48_000.0
    private var targetWowIncrement = 2.0 * .pi * 0.8 / 48_000.0
    private var previousWowDepthMs = 2.5
    private var targetWowDepthMs = 2.5
    private var previousFlutterDepthMs = 0.25
    private var targetFlutterDepthMs = 0.25
    private var previousFeedback = 0.4
    private var targetFeedback = 0.4
    private var previousMix = 0.3
    private var targetMix = 0.3
    private var previousDriveGain = TapeDelayParams.driveGain(saturation: 0.3)
    private var targetDriveGain = TapeDelayParams.driveGain(saturation: 0.3)
    private var previousDriveAmount = 0.3
    private var targetDriveAmount = 0.3
    private var previousLowpassCoeff = 0.0
    private var targetLowpassCoeff = 0.0
    /// Set by `prepare`/`reset`: the next quantum starts AT its target instead
    /// of sweeping into it from a stale value.
    private var needsPrime = true

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<TapeDelayParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: TapeDelayParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: TapeDelayParams = TapeDelayParams()) {
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
    func apply(params: TapeDelayParams) {
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
        // ⭐⭐⭐ THE §4.1 ERRATUM, HIT AND RECORDED (m39-n). The capability
        // table in §4.1 states the minimum-delay floor as "**1 sample**"
        // flatly, and the first draft of this line said `minDelaySamples: 1`.
        // The home refused it:
        //     minimumDelayBelowStencil(minDelaySamples: 1.0, required: 2.0)
        // — correctly, because `.cubicHermite`'s stencil reads `whole - 1`,
        // one sample NEWER than the tap, so at a 1-sample minimum it would
        // read the write head. `.cubicHermite` is the interpolation §4.1
        // recommends to THIS effect by name, so the table and the
        // recommendation contradict each other for exactly this caller; the
        // addendum under that table predicted this refusal in advance.
        //
        // ⛔ The fix is NOT "write 2". A literal would be right today and
        // silently wrong the moment a depth range moves. The floor is DERIVED
        // from the ranges — `timeRange.lowerBound` minus both depth maxima —
        // and `TapeDelayParamsTests.minimumDelayInvariantHolds` pins the
        // inequality that keeps it positive. At 48 kHz it is 528 samples.
        let minDelaySamples = TapeDelayParams.minimumDelaySamples(sampleRate: sampleRate)
        // ALWAYS two channels: the render path duplicates a mono input into the
        // right line so a later stereo quantum is phase-coherent.
        do {
            try line.prepare(sampleRate: sampleRate, minDelaySamples: minDelaySamples,
                             channelCount: 2)
            lastPrepareRefusal = nil
        } catch let refusal as InterpolatedDelayLine.PrepareRefusal {
            lastPrepareRefusal = refusal
        } catch {
            lastPrepareRefusal = nil
        }
        clearRuntimeState()
        lastGeneration = .max  // re-derive at the new rate
    }

    var latencySamples: Int { 0 }

    /// ⚠️ NOT RENDER-CALLABLE — a test-only read of the RECORD-PATH one-pole's
    /// state, and the denormal gate cannot be written without it. The flush on
    /// the TAP is visible from the output; the flush on this filter is NOT,
    /// because by the time the value reaches a listener the tap flush has
    /// already cleaned it. An output-only subnormal test stays green while two
    /// subnormal filter words grind through every sample of silence — the exact
    /// shape `HallReverbEffect.internalShelfStateMagnitudes` exists for, and
    /// the reason this is `internal` rather than `private`. Named so nobody
    /// mistakes it for a control surface.
    var internalRecordFilterStateMagnitudes: [Float] { [abs(lowpassL), abs(lowpassR)] }

    /// ⚠️ NOT RENDER-CALLABLE. The three transport phases, for the structural
    /// half of the wow gate: ONE motor drives both channels, and no output
    /// measure separates "both channels share a phase" from "each has its own"
    /// on material that is identical in both channels.
    var internalTransportPhases: [Double] { [wowPhase, flutterPhaseA, flutterPhaseB] }

    /// Clears the tape + the transport (stop-time cut / un-bypass).
    func reset() {
        clearRuntimeState()
    }

    /// Render-thread safe: a bounded clear of preallocated memory plus a
    /// handful of stores.
    private func clearRuntimeState() {
        line.reset()
        wowPhase = 0
        flutterPhaseA = 0
        flutterPhaseB = 0
        lowpassL = 0
        lowpassR = 0
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
    /// (`storeAutomatedParam`) bypasses `TapeDelayParams.init`, so the clamping
    /// the init does is NOT in force. `timeMs` minus the depths reaches
    /// `Int(delay)` inside `InterpolatedDelayLine.tap`, and that line has NO
    /// render-thread bounds check by design (§4.1): an unclamped 9 000 ms would
    /// read off the end of a 4 s line, and `Int(Double.nan)` TRAPS outright.
    /// `feedback` unclamped would be an unstable recirculation and a
    /// `highCutHz` ≤ 0 would put the one-pole's own pole outside the unit
    /// circle. (The `FlangerEffect` / `DelayEffect` precedent, same shape.)
    private func deriveRenderParams(_ p: TapeDelayParams) {
        targetTimeMs = (p.timeMs.isFinite ? p.timeMs : 350).clamped(to: TapeDelayParams.timeRange)
        let wowRate = (p.wowRateHz.isFinite ? p.wowRateHz : 0.8)
            .clamped(to: TapeDelayParams.wowRateRange)
        targetWowIncrement = 2.0 * .pi * wowRate / sampleRate
        targetWowDepthMs = (p.wowDepthMs.isFinite ? p.wowDepthMs : 2.5)
            .clamped(to: TapeDelayParams.wowDepthRange)
        targetFlutterDepthMs = (p.flutterDepthMs.isFinite ? p.flutterDepthMs : 0.25)
            .clamped(to: TapeDelayParams.flutterDepthRange)
        targetFeedback = (p.feedback.isFinite ? p.feedback : 0.4)
            .clamped(to: TapeDelayParams.feedbackRange)
        targetMix = (p.mix.isFinite ? p.mix : 0.3).clamped(to: TapeDelayParams.mixRange)
        // THROUGH THE LAW, never a second copy of the drive mapping.
        targetDriveAmount = (p.saturationDrive.isFinite ? p.saturationDrive : 0.3)
            .clamped(to: TapeDelayParams.saturationRange)
        targetDriveGain = TapeDelayParams.driveGain(saturation: targetDriveAmount)
        // One-pole low-pass y += a·(x − y): a = 1 − e^(−2π·fc/fs) — the same
        // derivation `DelayEffect` uses, at the same place in the code.
        let highCut = (p.highCutHz.isFinite ? p.highCutHz : 6_000)
            .clamped(to: TapeDelayParams.highCutRange)
        targetLowpassCoeff = 1.0 - exp(-2.0 * .pi * highCut / sampleRate)
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .tapeDelay)`: 0 timeMs, 1 feedback, 2 mix,
    /// 3 wowDepthMs, 4 wowRateHz, 5 flutterDepthMs, 6 saturationDrive,
    /// 7 highCutHz. Pokes a preallocated params copy and re-derives — no
    /// allocation, no locks. The transport phases and the tape are untouched,
    /// so an automated ride stays continuous.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...7).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.timeMs = value
        case 1: overlay.effective.feedback = value
        case 2: overlay.effective.mix = value
        case 3: overlay.effective.wowDepthMs = value
        case 4: overlay.effective.wowRateHz = value
        case 5: overlay.effective.flutterDepthMs = value
        case 6: overlay.effective.saturationDrive = value
        default: overlay.effective.highCutHz = value
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
            previousTimeMs = targetTimeMs
            previousWowIncrement = targetWowIncrement
            previousWowDepthMs = targetWowDepthMs
            previousFlutterDepthMs = targetFlutterDepthMs
            previousFeedback = targetFeedback
            previousMix = targetMix
            previousDriveGain = targetDriveGain
            previousDriveAmount = targetDriveAmount
            previousLowpassCoeff = targetLowpassCoeff
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
        let timeDelta = (targetTimeMs - previousTimeMs) / span
        let wowIncrementDelta = (targetWowIncrement - previousWowIncrement) / span
        let wowDepthDelta = (targetWowDepthMs - previousWowDepthMs) / span
        let flutterDepthDelta = (targetFlutterDepthMs - previousFlutterDepthMs) / span
        let feedbackDelta = (targetFeedback - previousFeedback) / span
        let mixDelta = (targetMix - previousMix) / span
        let driveGainDelta = (targetDriveGain - previousDriveGain) / span
        let driveAmountDelta = (targetDriveAmount - previousDriveAmount) / span
        let lowpassDelta = (targetLowpassCoeff - previousLowpassCoeff) / span
        let msToSamples = 0.001 * sampleRate
        let denormalFloor = Self.denormalFloor
        // The flutter components run at FIXED rates (the one home is
        // `TapeDelayParams`), so their increments are constants for the
        // quantum rather than interpolated values.
        let flutterIncrementA = 2.0 * .pi * TapeDelayParams.flutterRateHz / sampleRate
        let flutterIncrementB = 2.0 * .pi * TapeDelayParams.flutterSecondaryRateHz / sampleRate

        var timeMs = previousTimeMs
        var wowIncrement = previousWowIncrement
        var wowDepthMs = previousWowDepthMs
        var flutterDepthMs = previousFlutterDepthMs
        var feedback = previousFeedback
        var mix = previousMix
        var driveGain = previousDriveGain
        var driveAmount = previousDriveAmount
        var lowpassCoeff = previousLowpassCoeff
        var wow = wowPhase
        var flutA = flutterPhaseA
        var flutB = flutterPhaseB
        var lpL = lowpassL
        var lpR = lowpassR

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
            let a = Float(lowpassCoeff)

            // THE DOWNWARD-ONLY LAW, through its one home. The result is always
            // in [timeMs − wowDepth − flutterDepth, timeMs], which `prepare()`
            // has already proved fits the line at both ends, so there is no
            // render-thread bounds check here and none is needed.
            let delaySamples = TapeDelayParams.readDelayMs(
                timeMs: timeMs, wowPhase: wow, flutterPhaseA: flutA, flutterPhaseB: flutB,
                wowDepthMs: wowDepthMs, flutterDepthMs: flutterDepthMs) * msToSamples

            // TAP BEFORE WRITE: the value written depends on the value just
            // read. This is the recirculation.
            var wetL = line.tap(channel: 0, delaySamples: delaySamples)
            // THE FLUSH THE HOME DELIBERATELY DOES NOT DO (§4.1).
            if abs(wetL) < denormalFloor { wetL = 0 }
            // THE RECORD PATH: saturate, then roll off. Both act on the FIRST
            // repeat as well as every later one — see the type comment.
            var toTapeL = Float(TapeDelayParams.saturated(
                Double(dryL + wetL * feedbackGain), driveGain: driveGain, amount: driveAmount))
            lpL += a * (toTapeL - lpL)
            if abs(lpL) < denormalFloor { lpL = 0 }
            toTapeL = lpL
            line.write(channel: 0, toTapeL)

            var wetR: Float = 0
            if right != nil {
                wetR = line.tap(channel: 1, delaySamples: delaySamples)
                if abs(wetR) < denormalFloor { wetR = 0 }
                var toTapeR = Float(TapeDelayParams.saturated(
                    Double(dryR + wetR * feedbackGain), driveGain: driveGain,
                    amount: driveAmount))
                lpR += a * (toTapeR - lpR)
                if abs(lpR) < denormalFloor { lpR = 0 }
                toTapeR = lpR
                line.write(channel: 1, toTapeR)
            } else {
                // Mono input: keep the right line fed with the same material so
                // a later stereo quantum is phase-coherent rather than starting
                // from silence (the `ChorusEffect` convention).
                var mirrored = line.tap(channel: 1, delaySamples: delaySamples)
                if abs(mirrored) < denormalFloor { mirrored = 0 }
                var toTapeR = Float(TapeDelayParams.saturated(
                    Double(dryR + mirrored * feedbackGain), driveGain: driveGain,
                    amount: driveAmount))
                lpR += a * (toTapeR - lpR)
                if abs(lpR) < denormalFloor { lpR = 0 }
                toTapeR = lpR
                line.write(channel: 1, toTapeR)
            }

            // `mix == 0` is the BIT-EXACT DRY path: the tape and the transport
            // above still ran (so a later mix raise is coherent), the buffer is
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

            wow += wowIncrement
            if wow >= 2.0 * .pi { wow -= 2.0 * .pi }
            flutA += flutterIncrementA
            if flutA >= 2.0 * .pi { flutA -= 2.0 * .pi }
            flutB += flutterIncrementB
            if flutB >= 2.0 * .pi { flutB -= 2.0 * .pi }

            timeMs += timeDelta
            wowIncrement += wowIncrementDelta
            wowDepthMs += wowDepthDelta
            flutterDepthMs += flutterDepthDelta
            feedback += feedbackDelta
            mix += mixDelta
            driveGain += driveGainDelta
            driveAmount += driveAmountDelta
            lowpassCoeff += lowpassDelta
            frame += 1
        }

        wowPhase = wow
        flutterPhaseA = flutA
        flutterPhaseB = flutB
        lowpassL = lpL
        lowpassR = lpR

        previousTimeMs = targetTimeMs
        previousWowIncrement = targetWowIncrement
        previousWowDepthMs = targetWowDepthMs
        previousFlutterDepthMs = targetFlutterDepthMs
        previousFeedback = targetFeedback
        previousMix = targetMix
        previousDriveGain = targetDriveGain
        previousDriveAmount = targetDriveAmount
        previousLowpassCoeff = targetLowpassCoeff
    }
}
