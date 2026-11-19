import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in single-knob bipolar resonant multimode filter (m39-i) — the club /
/// DJ-mixer sweep. `docs/design/2026-09-19-creative-effects.md` §6.1 is the
/// frozen contract; this file implements it, and every place it reads against
/// the letter of that section is called out in a ⚠️ comment below rather than
/// left to be discovered.
///
/// WHAT IT DOES, in the order the render path does it. One knob, `position`:
///   · `position == 0` — the centre. **BIT-EXACT DRY**: the buffers are never
///     written. The filter still RUNS on the input and its output is discarded,
///     so the integrators stay warm and re-entering the sweep is continuous
///     rather than a click (the `ChorusEffect` mix-0 convention, expressed on
///     the only knob this effect has).
///   · `position < 0` — a LOW-pass falling DOWN from 20 kHz. The treble leaves
///     first. At -1 the corner is 20 Hz, i.e. very nearly silence.
///   · `position > 0` — a HIGH-pass climbing UP from 20 Hz. The bass leaves
///     first. At +1 the corner is 20 kHz, i.e. very nearly silence.
/// The cutoff law is log-symmetric and lives in ONE HOME,
/// `DJFilterParams.cutoffHz(atPosition:)`, so the DSP, the UI and
/// `fx.describe`'s note text cannot disagree about where the corner is.
///
/// TOPOLOGY: a 2-pole Simper TPT state-variable filter, cascaded twice for
/// 24 dB/oct. The coefficient derivation is lifted — the MATH, not an import —
/// from `Sources/DAWEngine/Instruments/PolySynthInstrument.swift` (`recompute
/// Coefficients`, "2-pole SVF (Simper TPT form, shared coefficients)"), which
/// ships only the low-pass output `v2`; the high-pass output `v0 - k·v1 - v2`
/// is derived here from the same state. `DAWCore` stays engine-free and the
/// instrument stays out of the effects path, so a second copy with a comment
/// naming its sibling is the correct shape; a THIRD copy is when it gets a home
/// (design §6.1.3).
///
/// ⚠️ RESONANCE IS ON THE SECOND SECTION ONLY. At 24 dB/oct, section A runs at
/// Butterworth Q and section B carries the resonance; at 12 dB/oct ONLY the
/// resonant section B runs. So flipping 12 ↔ 24 changes STEEPNESS without
/// changing how loud the resonant peak is — which is the frozen behaviour, and
/// it is only true because the resonant section is the one present in both.
///
/// ⚠️⚠️ THE `1/sqrt(Q)` NORMALISATION IS APPLIED **RELATIVE TO THE BUTTERWORTH
/// Q**, and this is a deliberate, measured reading of a frozen line rather than
/// a slip — see `docs/design/2026-09-19-creative-effects-errata.md` §E1.
/// §6.1.3 freezes "apply `1 / sqrt(Q)` normalisation to the resonant section's
/// output". Taken literally that is `1/sqrt(0.707) = 1.19` at `resonance: 0` —
/// a **+1.5 dB boost on a filter that is supposed to be a clean Butterworth**,
/// and it would put the passband 1.5 dB hot and read -1.5 dB at the corner
/// where the SAME section's gate #9 demands -3 dB. The referenced form
/// `sqrt(Q_butterworth / Q_eff)` is the same law with its reference point
/// named: exactly 1.0 at `resonance: 0`, and -11.5 dB at Q 10. Both facts are
/// asserted in `DJFilterTests`.
///
/// SMOOTHING (rule 6.0.6 — a new creative effect smooths its own derived state
/// internally): effect params arrive as ONE SCALAR PER QUANTUM. `position`,
/// `resonance`, `deadZoneWidth` and `resonanceTrack` are held from the previous
/// quantum and linearly interpolated toward the new values across this one,
/// with the SVF coefficient triple recomputed every 32 frames — the stride the
/// modulation design froze. The wet/dry crossfade `w` additionally ramps PER
/// SAMPLE, because it is a gain and a stepped gain clicks.
///
/// ⚠️ INTERPOLATION IS OF `position`, NOT OF THE DERIVED CUTOFF. Across the
/// centre the sign flips and the topology switches HP ↔ LP, so an interpolated
/// *cutoff* is not even meaningful there (it would sweep 20 Hz → 20 kHz through
/// the wrong mode). Interpolating the knob and re-deriving cutoff + mode + wet
/// gain from it is what makes a centre crossing coherent, and it is the
/// behaviour §6.1.3 describes even where its wording names the cutoff.
/// Erratum §E2.
///
/// ⚠️ This lags by at most one quantum (≤ 10.7 ms at 512 frames) and is
/// therefore BLOCK-SIZE DEPENDENT. That is accepted and out of m39-d's scope:
/// m39-d gates EDGE PLACEMENT, and a continuous filter sweep has no edges.
/// ⛔ This mechanism must NEVER be used to place an edge.
///
/// Parameter updates follow the `GainEffect` atomic-POD-publish convention.
/// Render-path contract: `process()`/`reset()` allocate nothing, take no locks,
/// log nothing, touch no ObjC, hop no actors. ALL state is a fixed number of
/// scalars — 4 SVF sections of 2 integrators — so there is nothing to size and
/// `prepare()` has nothing to allocate. Both integrators of every section are
/// denormal-flushed PER SAMPLE: this is a feedback structure and the denormal
/// flushing belongs to the caller, not to the primitive (design §4.1).
final class DJFilterEffect: EffectRendering, @unchecked Sendable {
    /// Coefficient recompute stride, in frames. The modulation design's frozen
    /// stride, adopted here for the same reason: fine enough that a sweep is
    /// continuous, coarse enough that `tan`/`pow` never run per sample.
    private static let coefficientStride = 32
    /// The Q a `resonance` of 0 selects — the reference point the resonant
    /// section's output normalisation is measured against.
    private static let butterworthQ = DJFilterParams.q(resonance: 0)

    /// One 2-pole Simper TPT state-variable section, one channel.
    /// ⚠️ Both integrators are denormal-flushed on every sample. An idle
    /// resonant filter decays toward zero geometrically and lands in denormal
    /// territory, where each operation costs orders of magnitude more — on the
    /// render thread, during silence, which is exactly when nobody is looking.
    private struct SVFSection {
        var ic1: Float = 0
        var ic2: Float = 0

        @inline(__always)
        mutating func step(_ input: Float, a1: Float, a2: Float, a3: Float,
                           k: Float, highPass: Bool) -> Float {
            let v3 = input - ic2
            let v1 = a1 * ic1 + a2 * v3
            let v2 = ic2 + a2 * ic1 + a3 * v3
            ic1 = 2 * v1 - ic1
            ic2 = 2 * v2 - ic2
            if abs(ic1) < 1e-20 { ic1 = 0 }
            if abs(ic2) < 1e-20 { ic2 = 0 }
            // Simper's SVF gives every mode from the same state: low = v2,
            // band = v1, high = v0 - k·v1 - v2.
            return highPass ? input - k * v1 - v2 : v2
        }

        @inline(__always)
        mutating func clear() {
            ic1 = 0
            ic2 = 0
        }
    }

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: DJFilterParams

        init(generation: UInt64, params: DJFilterParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Prepared storage (main-actor set, render-thread read).
    private var sampleRate: Double = 48_000

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    /// Section A — Butterworth, runs only at 24 dB/oct.
    private var sectionAL = SVFSection()
    private var sectionAR = SVFSection()
    /// Section B — the RESONANT section. Runs at both slopes.
    private var sectionBL = SVFSection()
    private var sectionBR = SVFSection()

    // Derived coefficients, recomputed every `coefficientStride` frames.
    private var a1A: Float = 0
    private var a2A: Float = 0
    private var a3A: Float = 0
    private var kA: Float = 0
    private var a1B: Float = 0
    private var a2B: Float = 0
    private var a3B: Float = 0
    private var kB: Float = 0
    private var resonanceNormalisation: Float = 1
    private var highPassMode = false
    private var slopeIs24 = true

    // Interpolation endpoints. `previous*` is where the last quantum ENDED,
    // `target*` is what this quantum was asked for.
    private var previousPosition = 0.0
    private var targetPosition = 0.0
    private var previousResonance = 0.25
    private var targetResonance = 0.25
    private var previousDeadZone = 0.04
    private var targetDeadZone = 0.04
    private var previousTrack = 0.0
    private var targetTrack = 0.0
    /// Current wet-mix gain, ramped per sample. 0 means the buffers are not
    /// written at all, which is what makes the centre bit-exact dry.
    private var wetGain: Float = 0
    /// Set by `prepare`/`reset`: the next quantum starts AT its target instead
    /// of sweeping into it from a stale value.
    private var needsPrime = true

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<DJFilterParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: DJFilterParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: DJFilterParams = DJFilterParams()) {
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
    func apply(params: DJFilterParams) {
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

    /// Clears the filter state (stop-time cut / un-bypass). Render-thread safe:
    /// this effect owns no buffers, so a reset is eight stores.
    func reset() {
        clearRuntimeState()
    }

    private func clearRuntimeState() {
        sectionAL.clear()
        sectionAR.clear()
        sectionBL.clear()
        sectionBR.clear()
        wetGain = 0
        needsPrime = true
        // m39-d CR-2: a reset drops the ramp and the coefficient block in flight
        // (`needsPrime` re-seats the values); the cell geometry is the renderer's.
        rampFramesLeft = 0
        rampElapsed = 0
        rampPositionDelta = 0
        rampResonanceDelta = 0
        rampDeadZoneDelta = 0
        rampTrackDelta = 0
        blockFramesLeft = 0
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

    /// Captures this quantum's interpolation TARGETS. Generation changes,
    /// automation stores and the automation revert all route through here, so
    /// there is exactly one place where a parameter becomes a render value.
    ///
    /// ⚠️ EVERY FIELD IS RE-GUARDED AND RE-CLAMPED. A field-by-field overlay
    /// poke (`storeAutomatedParam`) bypasses `DJFilterParams.init`, so the
    /// clamping the init does is NOT in force here — the `BitCrusherParams`
    /// precedent, where the same hole would have let a NaN reach an `Int()`
    /// conversion and TRAP on the render thread. Here a NaN would reach `tan()`
    /// and `pow()` and poison the filter state permanently.
    private func deriveRenderParams(_ p: DJFilterParams) {
        targetPosition = (p.position.isFinite ? p.position : 0)
            .clamped(to: DJFilterParams.positionRange)
        targetResonance = (p.resonance.isFinite ? p.resonance : 0)
            .clamped(to: DJFilterParams.resonanceRange)
        targetDeadZone = (p.deadZoneWidth.isFinite ? p.deadZoneWidth : 0)
            .clamped(to: DJFilterParams.deadZoneRange)
        targetTrack = (p.resonanceTrack.isFinite ? p.resonanceTrack : 0)
            .clamped(to: DJFilterParams.resonanceTrackRange)
        // Discrete: snapped, never interpolated. A topology switch cannot be
        // half-applied, so it takes effect at the quantum boundary like the
        // `eq` slopes it is modelled on.
        slopeIs24 = EQParams.snapSlope(
            (p.slopeDbPerOct.isFinite ? p.slopeDbPerOct : 24)
                .clamped(to: DJFilterParams.slopeRange)) == 24
        rampPending = true  // m39-d CR-2: the next `process` starts a ramp
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .djFilter)`: 0 position, 1 resonance,
    /// 2 slopeDbPerOct, 3 deadZoneWidth, 4 resonanceTrack. Pokes a
    /// preallocated params copy and re-derives — no allocation, no locks.
    /// The filter STATE is untouched, so an automated sweep stays continuous.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...4).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.position = value
        case 1: overlay.effective.resonance = value
        case 2: overlay.effective.slopeDbPerOct = value
        case 3: overlay.effective.deadZoneWidth = value
        default: overlay.effective.resonanceTrack = value
        }
        deriveRenderParams(overlay.effective)
    }

    /// Recomputes the SVF coefficient triple for both sections from one knob
    /// position. Pure libm (`tan`, `pow`, `sqrt`) — no allocation, no locks —
    /// and it runs once per `coefficientStride` frames, never per sample.
    ///
    /// At a position of exactly 0 there is no cutoff to derive (the filter is
    /// bypassed), so the LAST coefficients are held: nothing is heard through
    /// them anyway, and holding keeps the integrators evolving against a sane
    /// corner so the first audible sample after the centre is continuous.
    private func deriveCoefficients(position: Double, resonance: Double, track: Double) {
        guard let cutoff = DJFilterParams.cutoffHz(atPosition: position) else { return }
        // ⚠️ THROUGH THE LAW, NEVER A SECOND COPY OF THE SIGN TEST. This read
        // `position < 0` until errata E4 reversed the knob direction, and that
        // line was a SECOND HOME for a rule this file's own header says lives in
        // `DJFilterParams` — so flipping the law left the cutoff and the mode
        // disagreeing, and the filter measured nearly FLAT at its own corner.
        // `isHighPass` is nil only at the bypassing centre, which the guard
        // above has already returned for.
        highPassMode = DJFilterParams.isHighPass(atPosition: position) ?? false
        // `tan()` stability guard — the PolySynth sibling's, for the same
        // reason: the ceiling is 20 kHz and Nyquist is 16 kHz at a 32 kHz
        // project rate, where an unguarded tan() is past its vertical asymptote.
        let guarded = min(max(cutoff, 5.0), sampleRate * 0.45)
        let g = Float(tan(.pi * guarded / sampleRate))
        let qEffective = DJFilterParams.effectiveQ(
            resonance: resonance, position: position, resonanceTrack: track)

        // Section A — Butterworth, flat. Only in the 24 dB/oct cascade.
        let kButterworth = Float(1.0 / Self.butterworthQ)
        a1A = 1 / (1 + g * (g + kButterworth))
        a2A = g * a1A
        a3A = g * a2A
        kA = kButterworth

        // Section B — the resonant one.
        let kResonant = Float(1.0 / qEffective)
        a1B = 1 / (1 + g * (g + kResonant))
        a2B = g * a1B
        a3B = g * a2B
        kB = kResonant

        // ⚠️ REFERENCED to the Butterworth Q (see the type comment + erratum
        // §E1): exactly 1.0 at `resonance: 0`, 0.266 (-11.5 dB) at Q 10. A
        // bare `1/sqrt(Q)` would make a no-resonance filter 1.5 dB LOUD.
        resonanceNormalisation = Float((Self.butterworthQ / qEffective).squareRoot())
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
    /// The ramp in flight. This kind interpolates PARAMETRICALLY — each block
    /// reads `previous + delta · t`, `t` = frames since the ramp began / span —
    /// so mid-ramp `previous*` stays the ramp's START and `rampElapsed` is the
    /// position. (0 / 0 at rest.)
    private var rampPositionDelta = 0.0
    private var rampResonanceDelta = 0.0
    private var rampDeadZoneDelta = 0.0
    private var rampTrackDelta = 0.0
    private var rampSpan = 1.0
    private var rampElapsed = 0
    /// The 32-frame coefficient block in flight and its wet-gain step: on the
    /// grid a block never crosses a cell line and one a call ends inside
    /// CARRIES into the next call (its SVF coefficients persist in the fields
    /// above), so the stride is counted from the cell line.
    private var blockFramesLeft = 0
    private var blockWetStep: Float = 0

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
    /// coefficient stride counts from the cell line (design §5.4: "a 64-frame call
    /// picks the stride up where the last one left it").
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
            previousPosition = targetPosition
            previousResonance = targetResonance
            previousDeadZone = targetDeadZone
            previousTrack = targetTrack
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

        // m39-d CR-2: start (or re-span) the ramp — see the MARK above. A ramp
        // re-started in flight first moves its start to where it is now. The
        // delta expressions are the pre-grid ones, verbatim.
        if rampPending || (rampFramesLeft > 0 && rampFramesLeft < minFrames) {
            if rampFramesLeft > 0 {
                let reached = Double(rampElapsed) / rampSpan
                previousPosition = previousPosition + rampPositionDelta * reached
                previousResonance = previousResonance + rampResonanceDelta * reached
                previousDeadZone = previousDeadZone + rampDeadZoneDelta * reached
                previousTrack = previousTrack + rampTrackDelta * reached
            }
            rampPending = false
            let rampFrames = cellFramesLeft >= minFrames ? cellFramesLeft : minFrames
            rampSpan = Double(rampFrames)
            rampElapsed = 0
            rampPositionDelta = targetPosition - previousPosition
            rampResonanceDelta = targetResonance - previousResonance
            rampDeadZoneDelta = targetDeadZone - previousDeadZone
            rampTrackDelta = targetTrack - previousTrack
            rampFramesLeft = rampFrames
        }
        // At rest the deltas are 0, so `t` multiplies nothing — the pre-grid
        // per-call `target − previous` was 0 there too.
        let span = rampFramesLeft > 0 ? rampSpan : Double(minFrames)
        let elapsed = rampFramesLeft > 0 ? rampElapsed : 0
        let positionDelta = rampPositionDelta
        let resonanceDelta = rampResonanceDelta
        let deadZoneDelta = rampDeadZoneDelta
        let trackDelta = rampTrackDelta
        let stereo = right != nil
        let cascade = slopeIs24
        // m39-d CR-2: on the grid a block is capped at the CELL's end (and may
        // carry into the next call); off it, at the CALL's end, as before. In a
        // 512 bounce the two are the same frame.
        let onGrid = cellFramesLeft >= minFrames
        var blockLeft = blockFramesLeft
        var wStep = blockWetStep

        // ⚠️ `while`, not `for i in 0..<n` — measured at
        // `EffectChainProcessor.swift:402-412`, a `Range` iteration raises
        // ~2 malloc/free events PER ITERATION at `-Onone`, which is why the
        // allocation gates can assert an absolute zero at all.
        var frame = 0
        while frame < minFrames {
            if blockLeft == 0 {
                let regionLeft = onGrid ? cellFramesLeft - frame : minFrames - frame
                let blockLength = regionLeft < Self.coefficientStride
                    ? regionLeft : Self.coefficientStride

                // One interpolation point per coefficient block. The knob is what
                // is interpolated; cutoff, mode and wet gain are DERIVED from it,
                // which is what makes a centre crossing coherent.
                let t = Double(elapsed + frame) / span
                let position = previousPosition + positionDelta * t
                let resonance = previousResonance + resonanceDelta * t
                let deadZone = previousDeadZone + deadZoneDelta * t
                let track = previousTrack + trackDelta * t
                deriveCoefficients(position: position, resonance: resonance, track: track)

                let wTarget = Float(DJFilterParams.wetGain(
                    atPosition: position, deadZoneWidth: deadZone))
                wStep = (wTarget - wetGain) / Float(blockLength)
                blockLeft = blockLength
            }
            var blockEnd = frame + blockLeft
            if blockEnd > minFrames { blockEnd = minFrames }
            var w = wetGain
            let highPass = highPassMode
            let norm = resonanceNormalisation

            var i = frame
            while i < blockEnd {
                let dryL = left[i]
                var wetL = cascade
                    ? sectionAL.step(dryL, a1: a1A, a2: a2A, a3: a3A, k: kA, highPass: highPass)
                    : dryL
                wetL = sectionBL.step(wetL, a1: a1B, a2: a2B, a3: a3B,
                                      k: kB, highPass: highPass) * norm

                var wetR: Float = 0
                var dryR: Float = 0
                if stereo, let right {
                    dryR = right[i]
                    wetR = cascade
                        ? sectionAR.step(dryR, a1: a1A, a2: a2A, a3: a3A, k: kA, highPass: highPass)
                        : dryR
                    wetR = sectionBR.step(wetR, a1: a1B, a2: a2B, a3: a3B,
                                          k: kB, highPass: highPass) * norm
                }

                // w == 0 is the BIT-EXACT DRY centre: the filter above still
                // ran (the integrators stay warm), the buffer is simply never
                // touched. `w` reaches exactly 0 by arithmetic, not by an
                // epsilon — a knob parked at 0 gives wTarget 0 and wStep 0.
                if w != 0 {
                    let dryGain = 1 - w
                    left[i] = dryL * dryGain + wetL * w
                    if stereo, let right {
                        right[i] = dryR * dryGain + wetR * w
                    }
                }

                w += wStep
                i += 1
            }
            wetGain = w
            blockLeft -= blockEnd - frame
            frame = blockEnd
        }
        blockFramesLeft = blockLeft
        blockWetStep = wStep

        // m39-d CR-2: a ramp still in flight keeps its start and advances its
        // position; at the ramp's end the values are SNAPPED to their targets,
        // exactly as every call end did before the grid (and still does off it).
        cellFramesLeft = cellFramesLeft > minFrames ? cellFramesLeft - minFrames : 0
        if rampFramesLeft > minFrames {
            rampFramesLeft -= minFrames
            rampElapsed += minFrames
            return
        }
        rampFramesLeft = 0
        rampElapsed = 0
        rampPositionDelta = 0
        rampResonanceDelta = 0
        rampDeadZoneDelta = 0
        rampTrackDelta = 0

        previousPosition = targetPosition
        previousResonance = targetResonance
        previousDeadZone = targetDeadZone
        previousTrack = targetTrack
    }
}
