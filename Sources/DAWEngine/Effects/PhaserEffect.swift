import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in swept all-pass phaser (m39-o) — a cascade of FIRST-ORDER ALL-PASS
/// sections sharing one swept corner, summed with the dry signal, with BIPOLAR
/// feedback around the chain. `PhaserParams` carries the frozen laws and the
/// argument for them; `docs/design/2026-09-19-creative-effects.md` §2.1 rank 7
/// is the item and §6.0 is the contract every new kind inherits.
///
/// ⛔ **THIS IS NOT A FLANGER, AND THERE IS NO DELAY LINE IN THIS FILE.** That
/// absence is the design, not an omission. A flanger sums the signal with a
/// DELAYED copy, which cancels at the odd multiples of `1/(2·delay)` — a dense,
/// evenly spaced, HARMONIC comb that slides rigidly as the delay sweeps. This
/// effect sums the signal with a PHASE-SHIFTED copy, and cancellation happens
/// only where the chain's accumulated phase crosses an odd multiple of 180°.
/// An N-section chain sweeps 0° → −N·180°, so it makes exactly **N/2 notches**,
/// spaced at `PhaserParams.notchRatio` — a NON-harmonic series that spreads as
/// it climbs (8 stages: 1 : 3.36 : 7.52 : 25.3 where a flanger is 1 : 3 : 5 : 7).
/// Few, uneven, spreading notches is what "phaser" sounds like; many, even ones
/// is what "flanger" sounds like. `PhaserTests` runs ONE notch-finder over BOTH
/// kinds and asserts each law fits its own effect and is rejected by the other,
/// because a test that only shows "the output changed" cannot tell them apart.
///
/// WHAT IT DOES, in the order the render path does it, per channel per sample:
///   1. **Inject feedback** — `x = dry + previousWet · feedback`. `previousWet`
///      is the PRECEDING sample's chain output, so the loop carries an explicit
///      one-sample delay and is not an algebraic loop. An all-pass chain has
///      unit magnitude at every frequency, so the loop gain is exactly
///      `|feedback| < 0.95` and the recursion is unconditionally stable.
///   2. **Run the chain** — `stageCount` first-order sections in series, all on
///      the SAME coefficient, each realised as `y = a·x + s`, `s' = x − a·y`
///      (one state word per section).
///   3. **Flush** each section's state word, and the chain output, if denormally
///      small (see below).
///   4. **Mix** — `out = dry·(1−m) + wet·m`. At `m == 0` exactly, THE BUFFER IS
///      NEVER WRITTEN — bit-exact dry by IEEE (rule 6.0.7) — while the chain and
///      the LFO keep running, so raising `mix` later picks up mid-sweep rather
///      than jumping (the `ChorusEffect` convention).
///
/// ⚠️ **THE COEFFICIENT SIGN IS THE ONE THING THAT LOOKS RIGHT WHILE BEING
/// WRONG.** `PhaserParams.allpassCoefficient` is `(t − 1)/(t + 1)`, not the
/// `(1 − t)/(1 + t)` that appears in one-pole and shelf derivations. Dropped
/// into `H(z) = (a + z⁻¹)/(1 + a·z⁻¹)` the wrong sign still gives a STABLE
/// all-pass with the SAME number of notches — it just puts them in the wrong
/// places (its phase at its own corner is a few degrees instead of −90°). A
/// notch-COUNT test passes either way. Only a notch-POSITION measurement
/// separates them, which is why the suite measures positions.
///
/// ⛔ **THE SWEEP IS UPWARD-ONLY IN LOG FREQUENCY, AND THE LAW LIVES IN
/// DAWCore.** `PhaserParams.sweptCornerHz(phaseRadians:centerHz:depthOctaves:)`
/// is its ONE HOME; this file calls it and never re-derives it. The corner can
/// therefore never leave `[centerHz, centerHz·2^depthOctaves]`, whose ceiling
/// over the whole surface is `PhaserParams.maxCornerHz` = 16 kHz — below
/// `0.45·fs` at every rate this app runs at, so the `tan` guard inside
/// `allpassCoefficient` (which exists for a hypothetical 32 kHz project) never
/// engages and the sweep top is never flattened.
///
/// ⛔ **THE DENORMAL FLUSH IS PER SECTION, AND THAT IS NOT THE FLANGER'S RULE.**
/// The flanger owns exactly one recirculating word because its delay line is the
/// only memory it has. **Every first-order all-pass here is ITSELF an IIR** with
/// a pole at `|a|` (0.96 at the 300 Hz default, 0.999 at 20 Hz), so on silence
/// each section's state decays as `a^n` into subnormal territory INDEPENDENTLY —
/// at `feedback == 0` as much as at 0.95, which is what makes it easy to miss.
/// Subnormal arithmetic costs orders of magnitude more, on the render thread,
/// during silence, which is exactly when nobody is looking. The flush is
/// `abs(x) < 1e-20` on each section's state word and on the chain output,
/// matching `DelayEffect.swift`'s existing constant and `StereoWidthEffect`'s
/// per-stage placement rather than inventing a second approach. Flushing the
/// STATE is sufficient for the cascade: a section whose state is 0 and whose
/// input is 0 outputs 0, so the zero propagates down the chain on the next
/// sample.
///
/// SMOOTHING (rule 6.0.6 — a new creative effect smooths its own derived state
/// internally): effect params arrive as ONE SCALAR PER QUANTUM. `feedback` and
/// `mix` multiply the signal directly and are interpolated **per sample**; a
/// per-quantum step in either is an audible click at a 10.7 ms cadence. The
/// all-pass coefficient needs a `tan`, so it is recomputed on the frozen
/// **32-frame stride** (§6.0.6, the `DJFilterEffect` cadence) — and then
/// interpolated per sample from the previous block's value to this one's, so
/// there is no zipper at the block boundary either (the `TapeDelayEffect`
/// precedent of interpolating a coefficient rather than re-deriving it).
/// ⚠️ THE LFO PHASE IS NEVER RESET BY A PARAMETER CHANGE. `reset()` clears it
/// (a stop-time cut); `apply`/`storeAutomatedParam` never do, so an automated
/// rate change speeds the sweep up without jumping the notches.
///
/// ⚠️ **`stages` IS THE ONE PARAM THAT CLEARS STATE.** Sections above the new
/// count stop being visited, so their state words freeze rather than decay, and
/// re-entering them later would splice a stale value into the chain. Changing
/// the count therefore clears ALL section state — a bounded store of
/// preallocated memory, off the inner loop, in `deriveRenderParams`. That step
/// is why the param is `Modulatable: refused` and wants a `hold` automation
/// lane; it is a character change, not a glide.
///
/// Parameter updates follow the `GainEffect` atomic-POD-publish convention.
/// Render-path contract: `process()`/`reset()` allocate nothing, take no locks,
/// log nothing, touch no ObjC, hop no actors. Section state is a single
/// `UnsafeMutablePointer<Float>` allocated ONCE in `init` at the MAXIMUM stage
/// count for both channels, so every parameter move — including a stage-count
/// change — is arithmetic and never an allocation.
final class PhaserEffect: EffectRendering, @unchecked Sendable {
    /// Denormal-flush threshold — `DelayEffect`'s existing constant and its
    /// existing shape, deliberately not a second one. −400 dB: far below
    /// anything audible, far above the subnormal boundary (~1.18e-38 for
    /// `Float`).
    private static let denormalFloor: Float = 1e-20

    /// Coefficient recompute cadence, in frames — the stride the modulation
    /// design froze (§6.0.6) and the one `DJFilterEffect` already uses, for the
    /// same reason: `tan` is the only libm call in this effect and it does not
    /// belong in a per-sample loop.
    private static let coefficientStride = 32

    /// Sections allocated per channel: the TOP of `stagesRange`, so a
    /// stage-count change is an index bound and never a reallocation.
    private static let maxStages = Int(PhaserParams.stagesRange.upperBound)

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: PhaserParams

        init(generation: UInt64, params: PhaserParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    /// ALL-PASS SECTION STATE, one `Float` per section per channel, laid out
    /// `[channel * maxStages + stage]`. Allocated ONCE here (main actor, at
    /// construction) at the maximum size the surface can ask for, so nothing on
    /// the render thread ever resizes it. A flat pointer rather than an array of
    /// arrays because the inner loop walks it with a `while` and an index, which
    /// is the shape the allocation gates assert an absolute zero against.
    private let sectionState: UnsafeMutablePointer<Float>

    // Prepared storage (main-actor allocated, render-thread used).
    private var sampleRate: Double = 48_000

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    /// LFO phase in RADIANS, [0, 2π). The LEFT channel's phase; the right
    /// channel reads it plus `stereoOffset`.
    private var phase = 0.0
    /// The PRECEDING sample's chain output per channel — the explicit one-sample
    /// delay that makes the feedback loop computable. Denormal-flushed.
    private var feedbackStateL: Float = 0
    private var feedbackStateR: Float = 0
    /// The all-pass coefficients currently in force, interpolated toward each
    /// 32-frame block's freshly derived target.
    private var coefficientL = 0.0
    private var coefficientR = 0.0
    /// How many sections are in circuit right now. A change clears state.
    private var stageCount = 6

    // Interpolation endpoints. `previous*` is where the last quantum ENDED,
    // `target*` is what this quantum was asked for. All in RENDER units.
    private var previousIncrement = 2.0 * .pi * 0.5 / 48_000.0
    private var targetIncrement = 2.0 * .pi * 0.5 / 48_000.0
    private var previousCenterHz = 300.0
    private var targetCenterHz = 300.0
    private var previousDepthOctaves = 3.0
    private var targetDepthOctaves = 3.0
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
    private var overlay: AutomationParamOverlay<PhaserParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: PhaserParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: PhaserParams = PhaserParams()) {
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        sectionState = .allocate(capacity: Self.maxStages * 2)
        sectionState.initialize(repeating: 0, count: Self.maxStages * 2)
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
        sectionState.deinitialize(count: Self.maxStages * 2)
        sectionState.deallocate()
    }

    /// ⭐⭐ TEST INSTRUMENT (m39-o), AND IT EXISTS BECAUSE THE OBVIOUS LEG
    /// CANNOT SEE THE DEFECT IT IS FOR. `PhaserTests` L6 originally asserted
    /// "no OUTPUT sample is subnormal" — the `FlangerTests` L6 shape — and that
    /// leg **passed with every per-section flush deleted**, measured by planting
    /// exactly that deletion and watching all 35 phaser tests stay green. The
    /// reason is structural rather than a tuning: the chain OUTPUT is flushed
    /// separately, so it never carries a subnormal no matter what the sections
    /// are doing, and an output-only assertion is blind by construction. The
    /// subnormals live in the SECTION STATE, so the section state is what this
    /// reports. Returns how many of the `maxStages * 2` words are currently
    /// subnormal (non-zero and not `.isNormal`).
    ///
    /// Reading it is render-thread safe in the same sense `reset()` is — a
    /// bounded read of preallocated memory — but it is called only from tests.
    var subnormalSectionStateCount: Int {
        var count = 0
        var index = 0
        let total = Self.maxStages * 2
        while index < total {
            let value = sectionState[index]
            if value != 0 && !value.isNormal { count += 1 }
            index += 1
        }
        return count
    }

    /// The largest absolute section-state word, so a test can prove its tail
    /// actually DECAYED THROUGH the subnormal band rather than jumping over it
    /// — a "0 subnormals" reading from a chain that was already at hard zero is
    /// not evidence of a flush.
    var peakAbsoluteSectionState: Float {
        var peak: Float = 0
        var index = 0
        let total = Self.maxStages * 2
        while index < total {
            peak = max(peak, abs(sectionState[index]))
            index += 1
        }
        return peak
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: PhaserParams) {
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

    /// Clears every section, the feedback memory and the LFO (stop-time cut /
    /// un-bypass).
    func reset() {
        clearRuntimeState()
    }

    /// Render-thread safe: a bounded clear of preallocated memory plus a handful
    /// of stores.
    private func clearRuntimeState() {
        clearSections()
        feedbackStateL = 0
        feedbackStateR = 0
        phase = 0
        needsPrime = true
        // m39-d CR-2: a reset drops the ramp and the coefficient block in flight
        // (`needsPrime` re-seats both); the cell geometry is the renderer's.
        rampFramesLeft = 0
        rampIncrementDelta = 0
        rampCenterDelta = 0
        rampDepthDelta = 0
        rampFeedbackDelta = 0
        rampMixDelta = 0
        rampOffsetDelta = 0
        blockFramesLeft = 0
    }

    /// A bounded store over memory that was allocated in `init` — no allocation,
    /// no branch on the inner loop, and `while` rather than `for i in 0..<n`.
    private func clearSections() {
        var index = 0
        let total = Self.maxStages * 2
        while index < total {
            sectionState[index] = 0
            index += 1
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

    /// Captures this quantum's interpolation TARGETS. Generation changes,
    /// automation stores and the automation revert all route through here, so
    /// there is exactly one place where a parameter becomes a render value.
    ///
    /// ⚠️ EVERY FIELD IS RE-GUARDED AND RE-CLAMPED. A field-by-field overlay poke
    /// (`storeAutomatedParam`) bypasses `PhaserParams.init`, so the clamping the
    /// init does is NOT in force. An unclamped `centerHz` or `depthOctaves`
    /// would push the corner past Nyquist, where `tan` is beyond its asymptote
    /// and the all-pass coefficient exceeds 1 in magnitude — an UNSTABLE
    /// section, i.e. a strip that gets louder every sample until it is inf. A
    /// NaN would poison the interpolation accumulators permanently. (The
    /// `BitCrusherParams.bits` precedent, same shape.) The re-clamp is done by
    /// the DAWCore laws themselves, which is why they all re-guard their inputs.
    private func deriveRenderParams(_ p: PhaserParams) {
        let rate = (p.rateHz.isFinite ? p.rateHz : 0.5).clamped(to: PhaserParams.rateRange)
        targetIncrement = 2.0 * .pi * rate / sampleRate
        targetCenterHz = (p.centerHz.isFinite ? p.centerHz : 300)
            .clamped(to: PhaserParams.centerRange)
        targetDepthOctaves = (p.depthOctaves.isFinite ? p.depthOctaves : 3)
            .clamped(to: PhaserParams.depthRange)
        targetFeedback = (p.feedback.isFinite ? p.feedback : 0.5)
            .clamped(to: PhaserParams.feedbackRange)
        targetMix = (p.mix.isFinite ? p.mix : 0.5).clamped(to: PhaserParams.mixRange)
        // THROUGH THE LAW, never a second copy of the degrees→radians math.
        targetOffset = PhaserParams.stereoPhaseOffsetRadians(stereoPhaseDeg: p.stereoPhaseDeg)
        // THROUGH THE LAW, never a second copy of the even-snap rule.
        let snapped = PhaserParams.snappedStages(p.stages)
        if snapped != stageCount {
            // Sections that were out of circuit hold a FROZEN value, not a
            // decayed one — splicing one back in would click. Bounded store of
            // preallocated memory, off the inner loop.
            stageCount = snapped
            clearSections()
        }
        rampPending = true  // m39-d CR-2: the next `process` starts a ramp
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .phaser)`: 0 rateHz, 1 centerHz,
    /// 2 depthOctaves, 3 stages, 4 feedback, 5 mix, 6 stereoPhaseDeg. Pokes a
    /// preallocated params copy and re-derives — no allocation, no locks. The
    /// LFO phase is untouched, so an automated sweep stays continuous.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...6).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.rateHz = value
        case 1: overlay.effective.centerHz = value
        case 2: overlay.effective.depthOctaves = value
        case 3: overlay.effective.stages = value
        case 4: overlay.effective.feedback = value
        case 5: overlay.effective.mix = value
        default: overlay.effective.stereoPhaseDeg = value
        }
        deriveRenderParams(overlay.effective)
    }

    // MARK: - m39-d CR-2: the control cell (docs/design/2026-10-07-effect-control-rate.md §5.4)
    //
    // Render-thread only. A ramp starts in the `process` call after a derive
    // (`rampPending`). On the control grid (`cellFramesLeft` covers the whole
    // call) it spans the REST OF THE CELL and carries across calls; off it,
    // it spans the call, exactly as before the grid. A ramp in flight that
    // would end INSIDE a call is re-spanned over that call, so no ramp ever
    // ends mid-call and the per-sample loop is untouched. In a 512 bounce the
    // cell is the call: the same delta expression, run the same number of
    // times (G1 byte gate).
    /// Frames from the next `process` call to the next control-cell line
    /// (0 = off the grid). Set by `beginControlCell`, counted down here.
    private var cellFramesLeft = 0
    /// Frames left in the ramp in flight (0 = values sit at their targets).
    private var rampFramesLeft = 0
    /// A derive landed since the ramp in flight began.
    private var rampPending = false
    /// The ramp in flight's per-frame steps (carried across calls; 0 at rest).
    private var rampIncrementDelta = 0.0
    private var rampCenterDelta = 0.0
    private var rampDepthDelta = 0.0
    private var rampFeedbackDelta = 0.0
    private var rampMixDelta = 0.0
    private var rampOffsetDelta = 0.0
    /// The 32-frame coefficient block in flight (W9-CR12, CR-0's Phaser
    /// finding): frames left in it, and its per-sample steps and end targets.
    /// On the grid a block never crosses a cell line and a block that a call
    /// ends inside CARRIES into the next call, so the stride is counted from
    /// the cell line and a split cannot move a block boundary.
    private var blockFramesLeft = 0
    private var blockStepL = 0.0
    private var blockStepR = 0.0
    private var blockTargetL = 0.0
    private var blockTargetR = 0.0

    /// m39-d CR-1 (design §5.3): the automated values stored at this control
    /// cell's entry still stand. Adopt FIRST, so a knob publish waiting in the
    /// slot is seen now, as a store would see it (then `overlay.hold()`
    /// answers false and the renderer re-stores). Render thread; no allocation.
    func holdAutomatedParams() -> Bool {
        adoptPendingParams()
        return overlay.hold()
    }

    /// m39-d CR-2 (design §5.4): the ramp toward a new value spans the
    /// rest of the cell (`frames`), carried across calls, and the 32-frame
    /// coefficient stride counts from the cell line, so a split call renders the
    /// same samples as the unsplit bounce. (Called on an unautomated phaser too:
    /// its LFO moves the coefficient every block whether or not a lane does.)
    func beginControlCell(frames: Int) {
        cellFramesLeft = max(0, frames)
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
            previousCenterHz = targetCenterHz
            previousDepthOctaves = targetDepthOctaves
            previousFeedback = targetFeedback
            previousMix = targetMix
            previousOffset = targetOffset
            // Start the coefficients AT the corner this quantum asks for, so a
            // freshly prepared effect does not glide up from a stale value.
            coefficientL = PhaserParams.allpassCoefficient(
                cornerHz: PhaserParams.sweptCornerHz(
                    phaseRadians: phase, centerHz: targetCenterHz,
                    depthOctaves: targetDepthOctaves),
                sampleRate: sampleRate)
            coefficientR = PhaserParams.allpassCoefficient(
                cornerHz: PhaserParams.sweptCornerHz(
                    phaseRadians: phase + targetOffset, centerHz: targetCenterHz,
                    depthOctaves: targetDepthOctaves),
                sampleRate: sampleRate)
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

        // m39-d CR-2: start (or re-span) the ramp — see the MARK above. The
        // delta expressions are the pre-grid ones, verbatim.
        if rampPending || (rampFramesLeft > 0 && rampFramesLeft < minFrames) {
            rampPending = false
            let rampFrames = cellFramesLeft >= minFrames ? cellFramesLeft : minFrames
            let span = Double(rampFrames)
            rampIncrementDelta = (targetIncrement - previousIncrement) / span
            rampCenterDelta = (targetCenterHz - previousCenterHz) / span
            rampDepthDelta = (targetDepthOctaves - previousDepthOctaves) / span
            rampFeedbackDelta = (targetFeedback - previousFeedback) / span
            rampMixDelta = (targetMix - previousMix) / span
            rampOffsetDelta = (targetOffset - previousOffset) / span
            rampFramesLeft = rampFrames
        }
        let incrementDelta = rampIncrementDelta
        let centerDelta = rampCenterDelta
        let depthDelta = rampDepthDelta
        let feedbackDelta = rampFeedbackDelta
        let mixDelta = rampMixDelta
        let offsetDelta = rampOffsetDelta
        let denormalFloor = Self.denormalFloor
        let sections = stageCount
        let rightBase = Self.maxStages
        // m39-d CR-2: on the grid a block is capped at the CELL's end (and may
        // carry into the next call); off it, at the CALL's end, as before. In a
        // 512 bounce the two are the same frame.
        let onGrid = cellFramesLeft >= minFrames
        var blockLeft = blockFramesLeft
        var aStepL = blockStepL
        var aStepR = blockStepR
        var targetA = blockTargetL
        var targetAR = blockTargetR

        var increment = previousIncrement
        var centerHz = previousCenterHz
        var depthOctaves = previousDepthOctaves
        var feedback = previousFeedback
        var mix = previousMix
        var offset = previousOffset
        var lfo = phase
        var aL = coefficientL
        var aR = coefficientR
        var fbL = feedbackStateL
        var fbR = feedbackStateR

        // ⚠️ `while`, not `for i in 0..<n` — measured at
        // `EffectChainProcessor.swift:402-412`, a `Range` iteration raises
        // ~2 malloc/free events PER ITERATION at `-Onone`, which is why the
        // allocation gates can assert an absolute zero.
        var frame = 0
        while frame < minFrames {
            if blockLeft == 0 {
                let regionLeft = onGrid ? cellFramesLeft - frame : minFrames - frame
                let blockLength = regionLeft < Self.coefficientStride
                    ? regionLeft : Self.coefficientStride

                // ONE `tan` per channel per 32-frame block (§6.0.6's frozen
                // stride), evaluated at the LFO phase the block will END on, then
                // interpolated per sample from where the last block left off — so
                // the cadence is cheap AND there is no step at the boundary.
                let blockEndPhase = lfo + increment * Double(blockLength)
                targetA = PhaserParams.allpassCoefficient(
                    cornerHz: PhaserParams.sweptCornerHz(
                        phaseRadians: blockEndPhase, centerHz: centerHz,
                        depthOctaves: depthOctaves),
                    sampleRate: sampleRate)
                aStepL = (targetA - aL) / Double(blockLength)
                targetAR = PhaserParams.allpassCoefficient(
                    cornerHz: PhaserParams.sweptCornerHz(
                        phaseRadians: blockEndPhase + offset, centerHz: centerHz,
                        depthOctaves: depthOctaves),
                    sampleRate: sampleRate)
                aStepR = (targetAR - aR) / Double(blockLength)
                blockLeft = blockLength
            }
            var blockEnd = frame + blockLeft
            if blockEnd > minFrames { blockEnd = minFrames }
            var index = frame
            while index < blockEnd {
                let dryL = left[index]
                let dryR = right?[index] ?? dryL
                let feedbackGain = Float(feedback)
                let dryGain = Float(1 - mix)
                let mixGain = Float(mix)
                let coeffL = Float(aL)
                let coeffR = Float(aR)

                // LEFT — inject the PRECEDING sample's wet (the explicit
                // one-sample loop delay), then walk the cascade.
                var xL = dryL + fbL * feedbackGain
                var stage = 0
                while stage < sections {
                    let s = sectionState[stage]
                    let y = coeffL * xL + s
                    // THE PER-SECTION FLUSH. Each section is its own IIR with a
                    // pole at |a|, so each decays into subnormals on silence
                    // independently — including at feedback 0.
                    var next = xL - coeffL * y
                    if abs(next) < denormalFloor { next = 0 }
                    sectionState[stage] = next
                    xL = y
                    stage += 1
                }
                var wetL = xL
                if abs(wetL) < denormalFloor { wetL = 0 }
                fbL = wetL

                // RIGHT — its own cascade on its own coefficient (the stereo
                // phase offset puts it elsewhere in the sweep). On a MONO
                // buffer it still runs, on the same dry material, so a later
                // stereo quantum starts from a settled chain rather than
                // silence (the `ChorusEffect` convention).
                var xR = dryR + fbR * feedbackGain
                stage = 0
                while stage < sections {
                    let s = sectionState[rightBase + stage]
                    let y = coeffR * xR + s
                    var next = xR - coeffR * y
                    if abs(next) < denormalFloor { next = 0 }
                    sectionState[rightBase + stage] = next
                    xR = y
                    stage += 1
                }
                var wetR = xR
                if abs(wetR) < denormalFloor { wetR = 0 }
                fbR = wetR

                // `mix == 0` is the BIT-EXACT DRY path: the chain and the LFO
                // above still ran (so a later mix raise is phase-coherent), the
                // buffer is simply never touched. `mix` reaches exactly 0 by
                // arithmetic, not by an epsilon — a knob parked at 0 gives a 0
                // target and a 0 delta.
                if mix != 0 {
                    left[index] = dryL * dryGain + wetL * mixGain
                    if let right {
                        right[index] = dryR * dryGain + wetR * mixGain
                    }
                }

                lfo += increment
                if lfo >= 2.0 * .pi { lfo -= 2.0 * .pi }
                increment += incrementDelta
                centerHz += centerDelta
                depthOctaves += depthDelta
                feedback += feedbackDelta
                mix += mixDelta
                offset += offsetDelta
                aL += aStepL
                aR += aStepR
                index += 1
            }
            blockLeft -= blockEnd - frame
            if blockLeft == 0 {
                // SNAPPED to this block's targets rather than left at whatever the
                // accumulation landed on (the `StereoWidthEffect` rule): a
                // coefficient that settled at 0.96148002 instead of 0.96148 would
                // drift the notch positions by a hair, every block, forever.
                aL = targetA
                aR = targetAR
            }
            frame = blockEnd
        }

        phase = lfo
        feedbackStateL = fbL
        feedbackStateR = fbR
        coefficientL = aL
        coefficientR = aR
        blockFramesLeft = blockLeft
        blockStepL = aStepL
        blockStepR = aStepR
        blockTargetL = targetA
        blockTargetR = targetAR

        // m39-d CR-2: a ramp still in flight carries what it reached; at the
        // ramp's end the values are SNAPPED to their targets, exactly as every
        // call end did before the grid (and still does off it).
        rampFramesLeft = rampFramesLeft > minFrames ? rampFramesLeft - minFrames : 0
        cellFramesLeft = cellFramesLeft > minFrames ? cellFramesLeft - minFrames : 0
        if rampFramesLeft > 0 {
            previousIncrement = increment
            previousCenterHz = centerHz
            previousDepthOctaves = depthOctaves
            previousFeedback = feedback
            previousMix = mix
            previousOffset = offset
            return
        }
        rampIncrementDelta = 0
        rampCenterDelta = 0
        rampDepthDelta = 0
        rampFeedbackDelta = 0
        rampMixDelta = 0
        rampOffsetDelta = 0

        previousIncrement = targetIncrement
        previousCenterHz = targetCenterHz
        previousDepthOctaves = targetDepthOctaves
        previousFeedback = targetFeedback
        previousMix = targetMix
        previousOffset = targetOffset
    }
}
