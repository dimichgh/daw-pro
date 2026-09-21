import AVFAudio
import CAtomics
import DAWCore
import Foundation

// ============================================================================
// MARK: - DESIGN (m39-z). There is no separate design doc for this kind; this
//         section is it. `FreqShifterParams` in DAWCore is the frozen contract.
// ============================================================================
//
// ## 1. What this is, in one paragraph
//
// A frequency shifter moves every partial by the same number of **Hz**. A pitch
// shifter multiplies every partial by the same **ratio**. That one difference is
// the whole effect: a harmonic series 100/200/300 Hz shifted by +100 becomes
// 200/300/400 Hz, which is no longer a harmonic series — the ear stops hearing a
// note and starts hearing a bell. The inharmonicity IS the feature. Small shifts
// (±1–20 Hz) beat slowly against the dry signal and read as a wide chorus that a
// pitch shifter cannot produce; large shifts (hundreds of Hz) are clangorous
// sound design.
//
// ⛔ It is ALSO not `.ringMod`. A ring modulator is DOUBLE-sideband — it emits
// both `f + fc` and `|f − fc|`, and the input itself disappears. This is
// SINGLE-sideband: exactly one of those two survives. The other is the "unwanted
// sideband", and how far down it sits is this effect's only real quality number.
//
// ## 2. Structure, and why this one
//
//     x ──┬── [I-chain: 5 all-passes in z⁻²] ── z⁻¹ ── I ──×── cos(2πφ) ─┐
//         │                                                              (+/−)→ wet
//         └── [Q-chain: 5 all-passes in z⁻²] ─────────── Q ──×── sin(2πφ) ┘
//
// `I` and `Q` are the analytic signal: the same magnitude spectrum, held ~90°
// apart across the band. Then single-sideband modulation by a quadrature
// oscillator at the shift frequency:
//
//     wet = I·cos(2πφ) + Q·sin(2πφ)     ⟶ shift UP   by φ̇·fs
//     wet = I·cos(2πφ) − Q·sin(2πφ)     ⟶ shift DOWN by φ̇·fs
//
// ⭐ **BOTH DIRECTIONS COME FROM ONE SIGN, AND THAT IS WHY `shiftHz` IS SIGNED
// RATHER THAN A MAGNITUDE PLUS A SWITCH.** Running the oscillator BACKWARDS
// (negative phase increment) turns `+` into `−` for free, because
// `cos(−θ) = cos θ` and `sin(−θ) = −sin θ`. So the render path has ONE formula
// and no direction branch, and `shiftHz` sweeps continuously through 0 — which a
// discrete direction param could never do, and which rule 6.0.5 would have
// forced to `Modulatable: refused`.
//
// ### 2.1 Why an IIR all-pass pair and not the two obvious alternatives
//
// - **FIR Hilbert transformer (windowed sinc).** Linear phase, dead simple, and
//   REJECTED: its length is set by the LOWEST frequency it must handle. Holding
//   90° down to 20 Hz at 48 kHz needs thousands of taps, i.e. tens of
//   milliseconds of latency that would become a NEW DECLARED LATENCY SOURCE
//   inside the insert-PDC guarantee measured sample-exact at m25-n. Paying that
//   for an effect whose small-shift use is explicitly about beating against the
//   DRY signal is a bad trade.
// - **FFT / analytic signal by block transform.** Block latency, a forward and
//   inverse transform per quantum, and heap. Fails the render-path contract
//   outright.
// - **IIR all-pass pair (chosen).** ~10 multiplies per sample per channel, no
//   buffer of any kind, `latencySamples == 0`. The cost is that it is NOT linear
//   phase — but neither is any filter in this suite, and phase linearity is
//   irrelevant to an effect that deliberately destroys harmonic relationships.
//
// ### 2.2 The section form, and the sign trap that cost a measured defect
//
// Each section is a first-order all-pass **in z⁻²**:
//
//     H(z) = (a − z⁻²) / (1 − a·z⁻²)        y[n] = a·(x[n] + y[n−2]) − x[n−2]
//
// ⛔⛔ **THE OTHER TRANSCRIPTION IS ALSO A VALID ALL-PASS AND IS SILENTLY WRONG.**
// `y[n] = a·(x[n] − y[n−2]) + x[n−2]` is `H(z) = (a + z⁻²)/(1 + a·z⁻²)` — unity
// magnitude, perfectly stable, and a DIFFERENT filter. MEASURED during this
// build: with that form the two branches are no longer in quadrature, the
// unwanted sideband returns at **equal amplitude (0.03 dB apart)**, and the
// effect degrades into a ring modulator. ⚠️ It still sounds metallic, still
// changes the audio, and would still pass every test that only asks "did the
// output change" — this tree's named characteristic failure exactly. It was
// caught only by measuring the two sidebands separately. `FreqShifterTests` L2
// plants this form and asserts the rejection collapses.
//
// ## 3. The numbers — MEASURED, not quoted
//
// Coefficients were DESIGNED here, not copied: a minimax (soft-max-polished
// Nelder-Mead) fit of 10 sections split 5/5 over a log-spaced grid, seeded from
// a known-good 8-section set and verified on a 40 001-point grid.
//
// | quantity | value |
// |---|---|
// | sections | 10 (5 on I + 5 on Q), first-order in z⁻² |
// | design band | `f/fs ∈ [0.0002, 0.4998]` |
// | …in Hz at 48 kHz | 9.6 Hz … 23 990 Hz |
// | …in Hz at 96 kHz | 19.2 Hz … 47 981 Hz |
// | worst phase error | **0.376°** from 90°, across that band |
// | ⇒ predicted rejection | `20·log10(tan(ε/2))` = **−49.7 dB** |
// | MEASURED rejection | **−49.7 dB** (time-domain Goertzel on a rendered sine) |
// | carrier leakage | ≤ −80 dB (typically −120 dB) |
//
// ⭐ **THE PREDICTION AND THE MEASUREMENT ARE TWO INDEPENDENT INSTRUMENTS AND
// THEY AGREE TO 0.1 dB.** One evaluates the transfer functions in the frequency
// domain; the other runs real samples through the real difference equations and
// reads three spectral bins. That agreement is the evidence the network is
// implemented as designed — neither number alone would be.
//
// ⚠️ **THE BAND IS NORMALISED, SO IT MOVES WITH THE SESSION RATE.** At 48 kHz the
// low corner is 9.6 Hz, comfortably below hearing. At 96 kHz it is 19.2 Hz,
// which only just covers the audio band, and BELOW it the rejection degrades
// fast (≈ −15 dB at 20 Hz for a 192 kHz session). This is inherent to a
// fixed-coefficient IIR network and is stated rather than hidden;
// `FreqShifterParams.designBandHz(sampleRate:)` is the one home for it.
//
// ## 4. Parameters — ORDER IS FROZEN, APPEND-ONLY FOREVER
//
// | slot | name | range | default | unit | curve | Modulatable |
// |---:|---|---|---:|---|---|---|
// | **0** | `shiftHz` | −2000 … 2000 | **0** | Hz | `.linear` | yes |
// | **1** | `fineHz` | −20 … 20 | **0** | Hz | `.linear` | yes |
// | **2** | `stereoSpreadHz` | −20 … 20 | **0** | Hz | `.linear` | yes |
// | **3** | `mix` | 0 … 1 | **0.5** | linear | `.linear` | yes |
// | **4** | `outputDb` | −24 … 24 | **0** | dB | `.linear` | yes |
//
// **Totals contributed: 5 yes, 0 warned, 0 refused.**
//
// Every curve is `.linear` **by force** (rule 6.0.2): four ranges cross 0 and
// `mix`'s touches it, and `.logarithmic`/`.decibel` require `lo > 0` with a
// SILENT runtime fallback. ⭐ `fineHz` exists precisely BECAUSE that rule denies
// `shiftHz` a log taper: the musically famous ±1–20 Hz zone is 1 % of the coarse
// knob's travel, unreachable by hand and unusable as an automation lane. Two
// linear knobs solve what one cannot. Their sum is clamped to `shiftHz`'s own
// range (`FreqShifterParams.effectiveShiftHz`) so the pair can never exceed the
// range `fx.describe` advertises.
//
// **No `feedback`, deliberately.** Bode-style regeneration is the obvious slot 5,
// and it is DECLINED for v1: the analytic envelope can exceed the real input's
// peak, so a feedback path around this block is not unity-bounded, and
// `PhaserTests` already records a run where feedback drove a render to NaN while
// the allocation probe read a clean 0. It appends at slot 5 whenever someone
// wants to do that work properly. `.ringMod` already covers Ableton's "Ring"
// mode, so that is not a missing feature either.
//
// ## 5. Render-path contract
//
// `process()`/`reset()` allocate nothing, take no locks, log nothing, touch no
// ObjC, hop no actors. All state is a single `UnsafeMutablePointer<Double>`
// allocated ONCE in `init` on the main actor (the `PhaserEffect.sectionState`
// pattern) and only ZEROED by `prepare()`/`reset()`. Nothing here scales with
// frame count, so `prepare()` allocates nothing either.
//
// ⚠️ **SMOOTHING (rule 6.0.6).** Params arrive as ONE SCALAR PER QUANTUM. The
// phase INCREMENT is interpolated **per sample** — `RingModEffect.swift:77`
// records that 32-frame steps in a phase increment are audible, and that is a
// measurement, not a preference. `mix` and the wet gain multiply the signal
// directly and are likewise per-sample. Nothing here is left on a 32-frame
// stride.
//
// ⛔ **`mix == 0` NEVER WRITES THE BUFFER** (rule 6.0.7) — bit-exact dry by IEEE,
// including for −0.0, subnormals and infinities, because the bytes are not
// touched at all. The all-pass network and BOTH oscillators keep running, so
// raising `mix` again is phase-coherent rather than a jump. `outputDb` is
// applied to the WET copy only, before the blend, which is what keeps that law
// true at every `outputDb` setting rather than only at 0.

/// Built-in frequency shifter (m39-z) — a ZERO-LATENCY single-sideband shifter
/// built on a 10-section IIR Hilbert pair. See the DESIGN section above.
final class FreqShifterEffect: EffectRendering, @unchecked Sendable {
    /// Two, like `RingModEffect`: this kind's stereo spread is defined on a
    /// left/right pair and a third channel has no defined shift.
    private static let maxChannels = 2

    /// 5 on I + 5 on Q. Read off the shipped arrays rather than written down,
    /// so a coefficient-count change cannot leave this stale.
    private static let sectionsPerBranch = FreqShifterParams.hilbertI.count
    private static let sectionsPerChannel = sectionsPerBranch * 2

    /// Each section keeps `x[n−1], x[n−2], y[n−1], y[n−2]`.
    private static let wordsPerSection = 4
    private static let stateWordsPerChannel = sectionsPerChannel * wordsPerSection

    /// Denormal-flush threshold — `DelayEffect`'s existing constant. Every
    /// section is its own IIR and decays toward zero on silence INDEPENDENTLY,
    /// so the flush is applied per section, not once at the end.
    private static let denormalFloor = 1e-20

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: FreqShifterParams

        init(generation: UInt64, params: FreqShifterParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    /// All-pass state, `[channel * stateWordsPerChannel + section * 4 + k]`.
    /// Allocated ONCE in `init` (main actor) — the `PhaserEffect.sectionState`
    /// pattern. `prepare()` only zeroes it.
    private let sectionState: UnsafeMutablePointer<Double>
    /// The I branch's extra `z⁻¹`, one word per channel. Part of the NETWORK,
    /// not a convenience: without it the branches are ~0° apart, not ~90°.
    private let delayState: UnsafeMutablePointer<Double>
    /// The two coefficient branches, copied out of the DAWCore arrays at `init`
    /// so the render thread never touches a Swift `Array`.
    private let coefficients: UnsafeMutablePointer<Double>

    // Prepared storage (main-actor set, render-thread read).
    private var sampleRate: Double = 48_000
    private var preparedChannels = 2

    /// Carrier phase in CYCLES, [0, 1), one per channel. Two, not one plus an
    /// offset: `stereoSpreadHz` is a FREQUENCY difference, so the phase
    /// difference between the sides accumulates and cannot be a constant.
    private var phaseL = 0.0
    private var phaseR = 0.0

    private var lastGeneration = UInt64.max

    // Interpolation endpoints. `previous*` is where the last quantum ENDED,
    // `target*` is what this quantum was asked for.
    // ⛔ The SHIFT and the SPREAD are held SEPARATELY, not pre-summed into a
    // left and a right increment. `stereoSpreadHz` is defined as a LEFT/RIGHT
    // DIFFERENCE, and on a mono strip there is no right channel to differ from
    // — so whether half of it applies at all is a decision that can only be
    // made once the buffer list is in hand. Pre-summing here made a mono track
    // at `shiftHz 200, spread 8` land at 204 Hz with nothing at 200 (measured),
    // while `effectiveShiftHz` still reported 200. See `process()`.
    private var previousShiftIncrement = 0.0
    private var targetShiftIncrement = 0.0
    private var previousSpreadHalf = 0.0
    private var targetSpreadHalf = 0.0
    private var previousMix = 0.5
    private var targetMix = 0.5
    private var previousWetGain = 1.0
    private var targetWetGain = 1.0
    /// Set by `prepare`/`reset`: the next quantum starts AT its target instead
    /// of sweeping into it from a stale value.
    private var needsPrime = true

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<FreqShifterParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: FreqShifterParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: FreqShifterParams = FreqShifterParams()) {
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)

        let stateWords = Self.stateWordsPerChannel * Self.maxChannels
        sectionState = .allocate(capacity: stateWords)
        sectionState.initialize(repeating: 0, count: stateWords)
        delayState = .allocate(capacity: Self.maxChannels)
        delayState.initialize(repeating: 0, count: Self.maxChannels)

        // I branch first, then Q — the order the render loop walks them.
        coefficients = .allocate(capacity: Self.sectionsPerChannel)
        coefficients.initialize(repeating: 0, count: Self.sectionsPerChannel)
        for (index, value) in FreqShifterParams.hilbertI.enumerated() {
            coefficients[index] = value
        }
        for (index, value) in FreqShifterParams.hilbertQ.enumerated() {
            coefficients[Self.sectionsPerBranch + index] = value
        }

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
        let stateWords = Self.stateWordsPerChannel * Self.maxChannels
        sectionState.deinitialize(count: stateWords)
        sectionState.deallocate()
        delayState.deinitialize(count: Self.maxChannels)
        delayState.deallocate()
        coefficients.deinitialize(count: Self.sectionsPerChannel)
        coefficients.deallocate()
    }

    // MARK: - Test instruments
    //
    // ⭐ Bounded reads of already-allocated storage, render-thread safe in the
    // same sense `reset()` is, called only from tests. The WET SIGNAL is never
    // exposed — a test that wants it renders audio and measures the audio,
    // which is the only reading that can catch an inert effect.

    /// Both carrier phases, in cycles. Used to prove the oscillators keep
    /// advancing at `mix == 0` (rule 6.0.7's second half, which is the half
    /// that has no other instrument).
    var carrierPhases: (left: Double, right: Double) { (phaseL, phaseR) }

    /// How many of the all-pass state words are currently non-zero. The
    /// `PhaserEffect.nonZeroStateWords` shape: lets a test prove `reset()`
    /// actually cleared something rather than asserting over an empty network.
    var nonZeroStateWords: Int {
        var count = 0
        let total = Self.stateWordsPerChannel * Self.maxChannels
        var index = 0
        while index < total {
            if sectionState[index] != 0 { count += 1 }
            index += 1
        }
        return count
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: FreqShifterParams) {
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

    /// Allocates NOTHING — all storage is sized at `init` for the maximum of
    /// every range, so every parameter move is arithmetic.
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        preparedChannels = min(channelCount, Self.maxChannels)
        clearRuntimeState()
        lastGeneration = .max  // re-derive the increments at the new rate
    }

    /// ⛔ ZERO, and it is honest rather than convenient: an IIR all-pass network
    /// adds no BULK delay — its group delay is frequency-dependent, exactly like
    /// `.eq`, `.djFilter` and `.phaser`, all of which also report 0. There is no
    /// lookahead and no buffer in this file, so nothing new enters the insert
    /// PDC guarantee measured sample-exact at m25-n. ⛔ An implementer who later
    /// adds an FIR Hilbert transformer MUST declare its latency here and
    /// re-measure against m25-n.
    var latencySamples: Int { 0 }

    /// Clears the network and the carriers (stop-time cut / un-bypass), so a
    /// stale tail cannot ring into the next passage.
    func reset() {
        clearRuntimeState()
    }

    /// Render-thread safe: stores over already-allocated storage, no allocation.
    private func clearRuntimeState() {
        let total = Self.stateWordsPerChannel * Self.maxChannels
        var index = 0
        while index < total {
            sectionState[index] = 0
            index += 1
        }
        var channel = 0
        while channel < Self.maxChannels {
            delayState[channel] = 0
            channel += 1
        }
        phaseL = 0
        phaseR = 0
        needsPrime = true
    }

    /// Adopts a newly published main-actor snapshot (borrowed — the retire bin
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
    /// ⚠️ EVERY FIELD IS RE-GUARDED AND RE-CLAMPED. A field-by-field overlay poke
    /// (`storeAutomatedParam`) bypasses `FreqShifterParams.init`, so that init's
    /// clamping is NOT in force. A NaN reaching the phase accumulator would be
    /// UNRECOVERABLE — there is no path back from a NaN phase, so every later
    /// sample would be NaN and the strip would be silenced permanently (the
    /// `RingModEffect` precedent, same shape, same reason).
    private func deriveRenderParams(_ p: FreqShifterParams) {
        // THROUGH THE LAW, never a second copy of the coarse+fine sum.
        let shift = FreqShifterParams.effectiveShiftHz(shiftHz: p.shiftHz, fineHz: p.fineHz)
        let spread = (p.stereoSpreadHz.isFinite ? p.stereoSpreadHz : 0)
            .clamped(to: FreqShifterParams.stereoSpreadHzRange)
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        // ⭐ The SIGN survives into the increment, and that is the whole
        // direction mechanism: a negative increment runs the oscillator
        // backwards, which turns the upper-sideband formula into the lower one
        // for free. See DESIGN §2.
        targetShiftIncrement = shift / rate
        targetSpreadHalf = spread * 0.5 / rate
        targetMix = (p.mix.isFinite ? p.mix : 0.5).clamped(to: FreqShifterParams.mixRange)
        let db = (p.outputDb.isFinite ? p.outputDb : 0)
            .clamped(to: FreqShifterParams.outputDbRange)
        // Interpolated as a LINEAR gain rather than in dB: it multiplies the
        // signal directly, so linear is what must be continuous, and it saves a
        // `pow` per sample on the render thread.
        targetWetGain = pow(10.0, db / 20.0)
    }

    /// RENDER-THREAD automation store (M4 vii-c). ⛔ SLOT ORDER IS
    /// `EffectParamSpec.specs(for: .freqShifter)` AND IT IS FROZEN:
    /// 0 shiftHz, 1 fineHz, 2 stereoSpreadHz, 3 mix, 4 outputDb.
    /// Pokes a preallocated params copy and re-derives — no allocation, no
    /// locks. The carrier PHASES and the network state are UNTOUCHED, so an
    /// automated sweep bends the trajectory without moving the state.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...4).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.shiftHz = value
        case 1: overlay.effective.fineHz = value
        case 2: overlay.effective.stereoSpreadHz = value
        case 3: overlay.effective.mix = value
        default: overlay.effective.outputDb = value
        }
        deriveRenderParams(overlay.effective)
    }

    /// One all-pass section, in place over its four state words.
    ///
    ///     H(z) = (a − z⁻²)/(1 − a·z⁻²)      y[n] = a·(x[n] + y[n−2]) − x[n−2]
    ///
    /// ⛔ The `+`/`−` placement is the trap documented in DESIGN §2.2. Do not
    /// "simplify" it to `a·(x − y₂) + x₂`: that is a different filter, it
    /// destroys the quadrature, and the unit silently becomes a ring modulator.
    @inline(__always)
    private func allPass(_ input: Double, _ state: UnsafeMutablePointer<Double>,
                         _ coefficient: Double) -> Double {
        let x2 = state[1]
        let y2 = state[3]
        var y = coefficient * (input + y2) - x2
        // Per-section denormal flush: each section is its own IIR and each
        // decays toward zero on silence INDEPENDENTLY, so one flush at the end
        // would leave nine of them subnormal. Subnormal arithmetic costs orders
        // of magnitude more, on the render thread, during silence — exactly
        // when nobody is listening for it.
        if y > -Self.denormalFloor && y < Self.denormalFloor { y = 0 }
        state[1] = state[0]
        state[0] = input
        state[3] = state[2]
        state[2] = y
        return y
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard frameCount > 0 else { return }

        if needsPrime {
            previousShiftIncrement = targetShiftIncrement
            previousSpreadHalf = targetSpreadHalf
            previousMix = targetMix
            previousWetGain = targetWetGain
            needsPrime = false
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
        guard channelCount > 0, minFrames > 0, let left = channelData[0] else { return }
        let right = channelCount > 1 ? channelData[1] : nil
        let stereo = right != nil

        // ⛔⛔ THE ONE PLACE THE SPREAD IS ALLOWED TO REACH A CHANNEL.
        // `stereoSpreadHz`'s parameter note promises "It does nothing on a mono
        // track", and this `stereo ?` is the entire mechanism that makes that
        // sentence true. Left takes `+spread/2` ONLY when there is a right
        // channel to take `−spread/2`; on mono the only channel gets exactly
        // `effectiveShiftHz`, which is also the number `fx.add` echoes back.
        // Deciding here rather than in `deriveRenderParams` also keeps a
        // stereo-PREPARED effect correct if it is handed a mono buffer list.
        // Covered by L7b, which renders mono and asserts 1204 Hz is empty.
        let targetIncrementL = targetShiftIncrement + (stereo ? targetSpreadHalf : 0)
        let targetIncrementR = targetShiftIncrement - targetSpreadHalf
        let previousIncrementL = previousShiftIncrement + (stereo ? previousSpreadHalf : 0)
        let previousIncrementR = previousShiftIncrement - previousSpreadHalf

        let span = Double(minFrames)
        let incrementLDelta = (targetIncrementL - previousIncrementL) / span
        let incrementRDelta = (targetIncrementR - previousIncrementR) / span
        let mixDelta = (targetMix - previousMix) / span
        let wetGainDelta = (targetWetGain - previousWetGain) / span

        var incrementL = previousIncrementL
        var incrementR = previousIncrementR
        var mix = previousMix
        var wetGain = previousWetGain
        var phL = phaseL
        var phR = phaseR

        let sections = Self.sectionsPerBranch
        let rightStateBase = Self.stateWordsPerChannel
        let twoPi = 2.0 * Double.pi

        // ⚠️ `while`, not `for i in 0..<n` — measured at
        // `EffectChainProcessor.swift:402-412`, a `Range` iteration raises
        // ~2 malloc/free events PER ITERATION at `-Onone`, which is why the
        // allocation gate (L6) can assert an absolute zero.
        var frame = 0
        while frame < minFrames {
            // ---- LEFT ------------------------------------------------------
            let dryL = Double(left[frame])
            var inPhaseL = dryL
            var section = 0
            while section < sections {
                inPhaseL = allPass(inPhaseL, sectionState + section * 4, coefficients[section])
                section += 1
            }
            // The I branch's extra z⁻¹ — read the previous sample out, put this
            // one in. Part of the network (DESIGN §2.2).
            let heldL = delayState[0]
            delayState[0] = inPhaseL
            inPhaseL = heldL

            var quadL = dryL
            section = 0
            while section < sections {
                quadL = allPass(quadL, sectionState + (sections + section) * 4,
                                coefficients[sections + section])
                section += 1
            }

            // ---- RIGHT (independent network AND independent oscillator) -----
            var dryR = 0.0
            var inPhaseR = 0.0
            var quadR = 0.0
            if stereo, let right {
                dryR = Double(right[frame])
                inPhaseR = dryR
                section = 0
                while section < sections {
                    inPhaseR = allPass(inPhaseR, sectionState + rightStateBase + section * 4,
                                       coefficients[section])
                    section += 1
                }
                let heldR = delayState[1]
                delayState[1] = inPhaseR
                inPhaseR = heldR

                quadR = dryR
                section = 0
                while section < sections {
                    quadR = allPass(quadR,
                                    sectionState + rightStateBase + (sections + section) * 4,
                                    coefficients[sections + section])
                    section += 1
                }
            }

            // ---- SINGLE-SIDEBAND MODULATION --------------------------------
            // `I·cos + Q·sin`. A NEGATIVE increment runs the oscillator
            // backwards and turns this into `I·cos − Q·sin`, which is the other
            // sideband — so downward shift needs no branch here. DESIGN §2.
            let angleL = twoPi * phL
            let wetL = (inPhaseL * cos(angleL) + quadL * sin(angleL)) * wetGain
            var wetR = 0.0
            if stereo {
                let angleR = twoPi * phR
                wetR = (inPhaseR * cos(angleR) + quadR * sin(angleR)) * wetGain
            }

            // `mix == 0` is the BIT-EXACT DRY path: the network and both
            // oscillators above still ran (so a later mix raise is
            // phase-coherent), the buffer is simply never touched. `mix`
            // reaches exactly 0 by arithmetic, not by an epsilon — a knob
            // parked at 0 gives a 0 target and a 0 delta. The
            // `RingModEffect` convention, verbatim.
            if mix != 0 {
                let dryGain = 1 - mix
                left[frame] = Float(dryL * dryGain + wetL * mix)
                if stereo, let right {
                    right[frame] = Float(dryR * dryGain + wetR * mix)
                }
            }

            phL += incrementL
            if phL >= 1 { phL -= 1 } else if phL < 0 { phL += 1 }
            phR += incrementR
            if phR >= 1 { phR -= 1 } else if phR < 0 { phR += 1 }
            incrementL += incrementLDelta
            incrementR += incrementRDelta
            mix += mixDelta
            wetGain += wetGainDelta
            frame += 1
        }

        phaseL = phL
        phaseR = phR

        // SNAPPED to this quantum's targets rather than left at whatever the
        // accumulation landed on (the `StereoWidthEffect` rule): a value that
        // settled at 0.9999999 instead of 1 would drift, every quantum, forever
        // — and for `mix` in particular that would break the `mix == 0`
        // bit-exactness the identity gate depends on.
        previousShiftIncrement = targetShiftIncrement
        previousSpreadHalf = targetSpreadHalf
        previousMix = targetMix
        previousWetGain = targetWetGain
    }
}
