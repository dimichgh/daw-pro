import AVFAudio
import CAtomics
import DAWCore
import Foundation

// ============================================================================
// MARK: - DESIGN (m39-ac). There is no separate design doc for this kind; this
//         section is it. `ClipperParams` in DAWCore is the frozen contract and
//         `OversamplerDesign` is the filter's.
// ============================================================================
//
// ## 1. What this is, in one paragraph
//
// A clipper puts a HARD CEILING on the waveform. Everything above it is cut
// off, and the corners that leaves ARE new harmonics — which is why a clipped
// kick reads as harder rather than merely louder, and why clipping is how loud
// masters are actually made. Two shapes: `hard` slices flat at the ceiling;
// `soft` bends into it through a cubic knee and goes flat at 1.5× the ceiling.
//
// ⛔ It is NOT `.saturator`. `tanh` only ASYMPTOTICALLY approaches its bound,
// so there is no finite input at which a saturator's output equals its maximum
// — a saturator therefore cannot promise a peak ceiling, and this kind can.
// ⛔ It is NOT `.limiter`. A limiter rides a GAIN to keep peaks down and
// preserves the waveform's shape. This deforms the waveform on purpose.
//
// ## 2. The signal path
//
//     x ─┬─────────────── [dry ring, M samples] ──────────────┐
//        │                                                  (1−mix)
//        └─ ×driveGain ─ [↑L] ─ shape(ceiling) ─ [↓L] ─ ×out ─┴─ mix → y
//
// `[↑L]`/`[↓L]` are `Oversampler`, whose two stages together delay by exactly
// `OversamplerDesign.latencySamples` = M = 32 base-rate samples AT EVERY
// FACTOR. The dry ring delays by the same 32, which is what keeps a partial
// `mix` phase-coherent instead of hollow.
//
// ⭐ **DRIVE IS APPLIED AT THE BASE RATE, BEFORE THE UP STAGE.** It is a linear
// gain, so this is mathematically identical to applying it after, and it is `L`
// times cheaper. The CEILING is not: it is the non-linearity's own parameter
// and is applied inside the shaping pass, at the oversampled rate.
//
// ## 3. Latency, and the correctness bug that shaped it
//
// `latencySamples` is a CONSTANT 32, at every factor and every sample rate. It
// would have been natural to report `0` at 1× and `32` at 2×/4×, and that would
// have been a silent correctness bug: the factor is a user-facing PARAMETER,
// and `EffectRendering`'s contract is that "Param edits never republish the
// chain". `EffectChainProcessor.latencySamples` — and the PDC plan built from
// it, measured sample-exact at m25-n — would have gone stale the moment a user
// turned the knob, with every unit test still green. `OversamplerDesign` §3
// makes the constant a property of the FILTER FAMILY rather than a convention
// this file has to remember.
//
// ⚠️ **m39-ad's `.saturator` DOES report a factor-dependent latency (0 at 1, 32
// at 2/4) and is not a counter-example to this paragraph.** It had to: that kind
// SHIPPED before the control existed, so 32 samples at its default would shift
// every saved project. It buys the exception with two properties THIS kind does
// not have — its factor moves on the main actor only, and its `oversampling`
// slot is inert to automation. This kind's factor is automatable, which is
// precisely why its latency must not move. See `SaturatorEffect` DESIGN §3.
//
// ## 4. The identity law — DELAYED, and deliberately not rule 6.0.7's
//
// ⛔⛔ **THIS KIND CANNOT SATISFY "mix == 0 NEVER WRITES THE BUFFER", AND
// PRETENDING OTHERWISE WOULD BE THE BUG.** An effect that reports 32 samples of
// latency and then passes audio through UNDELAYED is mis-aligned by 32 samples
// against everything PDC compensates around it. So the law here is:
//
//   **at `mix == 0`, `out[n] == in[n − 32]`, BIT-EXACT** — including −0.0,
//   subnormals and infinities, because the value is copied out of a plain
//   `Float` ring and stored, with no arithmetic anywhere on that path.
//
// It is still an IDENTITY (which cannot be satisfied by accident the way a
// DIFFERENCE can), it is still the strongest statement available, and PDC
// removes the 32 samples again so a user hears exactly the dry signal in
// context. `ClipperTests` L5 seeds the buffer with −0.0 and subnormals and
// compares BIT PATTERNS, with every other knob non-default.
//
// ⚠️ The dry ring is deliberately NOT the `Oversampler`'s factor-1 copy path:
// that one flushes subnormals (`Oversampler` §6) and this law must not.
//
// ⛔ The wet path KEEPS RUNNING at `mix == 0` (the `FreqShifterEffect`
// convention) so the FIR histories stay warm and raising `mix` later picks up
// mid-signal rather than ramping in from a cleared filter. It costs CPU on a
// setting nobody parks at; state coherence is worth more than that saving.
//
// ## 5. Parameters — ORDER IS FROZEN, APPEND-ONLY FOREVER
//
// | slot | name | range | default | unit | curve | Modulatable |
// |---:|---|---|---:|---|---|---|
// | **0** | `driveDb` | −12 … 36 | **0** | dB | `.linear` | yes |
// | **1** | `ceilingDb` | −24 … 0 | **−0.3** | dBFS | `.linear` | yes |
// | **2** | `mode` | 0 … 1 | **0** (hard) | mode | `.linear` | **refused** |
// | **3** | `oversampling` | 1 … 4 | **1** new · 4 absent | x | `.linear` | **refused** |
// | **4** | `mix` | 0 … 1 | **1** | linear | `.linear` | yes |
// | **5** | `outputDb` | −24 … 24 | **0** | dB | `.linear` | yes |
//
// **Totals contributed: 4 yes, 0 warned, 2 refused.**
//
// `oversampling` has two defaults (2026-09-24, the user's "clipper-os" pick): a
// clipper added now starts at 1 (`ClipperParams.defaultOversampling`), while a
// saved clipper with no stored settings decodes as 4
// (`ClipperParams.legacyOversampling`), so existing projects keep their tone.
//
// Both refusals are rule 6.0.5 discrete params (the `PhaserEffect.stages`
// precedent), and `oversampling` has a second, independent reason: changing it
// CLEARS the oversampler's histories, so an LFO on it would be a stutter
// generator rather than a sweep.
//
// ⚠️ **SMOOTHING (rule 6.0.6).** `driveGain`, `ceilingLinear`, `mix` and the
// output gain all multiply or threshold the signal directly, so all four
// interpolate PER SAMPLE. The ceiling interpolates per BASE frame and is held
// across that frame's `factor` sub-samples — a threshold that moved within one
// base frame would put a step INSIDE the non-linearity, which is the one place
// a step becomes a new harmonic rather than a small level error.
//
// ## 6. Denormals and NaN
//
// The shaper is bounded and the filters are all-zero (no feedback), so nothing
// here can generate a decaying denormal of its own. The `Oversampler` flushes
// what it is FED (§6 there). `ClipperParams.shaped` returns 0 for a non-finite
// input rather than propagating: a NaN entering the decimation filter's history
// would poison 129 later output samples and then leave — but a NaN entering the
// interpolation accumulators would silence the strip permanently, so every
// derived field is re-guarded and re-clamped in `deriveRenderParams` (a
// field-by-field overlay poke bypasses `ClipperParams.init`'s clamping).

/// Built-in clipper (m39-ac) — the first caller of `Oversampler`. See the
/// DESIGN section above.
final class ClipperEffect: EffectRendering, @unchecked Sendable {
    /// Matches `CompressorEffect`'s `InlineChannelPointers` capacity.
    private static let maxChannels = 8

    /// Dry-delay ring capacity: the next power of two at or above
    /// `OversamplerDesign.latencySamples` (32 → 64), for mask indexing.
    private static let dryRingCapacity = 64
    private static let dryRingMask = dryRingCapacity - 1

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: ClipperParams

        init(generation: UInt64, params: ClipperParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    /// The shared primitive. Owned here; `prepare`/`reset` forward to it.
    private let oversampler = Oversampler()

    // Prepared storage (main-actor allocated, render-thread read/written).
    /// Per-channel dry delay ring — a PLAIN copy, no arithmetic, so §4's
    /// identity law holds bit-exactly.
    private var dryRing: UnsafeMutablePointer<Float>?
    private var dryWrite: UnsafeMutablePointer<Int>?
    /// One quantum of delayed dry, one channel at a time.
    private var dryScratch: UnsafeMutablePointer<Float>?
    /// One quantum of driven input, one channel at a time.
    private var drivenScratch: UnsafeMutablePointer<Float>?
    private var preparedChannels = 0
    private var preparedFrames = 0

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    private var previousDriveGain = 1.0
    private var targetDriveGain = 1.0
    private var previousCeiling = 0.966_050_57   // −0.3 dBFS
    private var targetCeiling = 0.966_050_57
    private var previousMix = 1.0
    private var targetMix = 1.0
    private var previousOutGain = 1.0
    private var targetOutGain = 1.0
    private var soft = false
    /// Set by `prepare`/`reset`: the next quantum starts AT its target instead
    /// of sweeping into it from a stale value.
    private var needsPrime = true

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<ClipperParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: ClipperParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: ClipperParams = ClipperParams()) {
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
        releaseChannelStorage()
    }

    private func releaseChannelStorage() {
        dryRing?.deallocate()
        dryWrite?.deallocate()
        dryScratch?.deallocate()
        drivenScratch?.deallocate()
        dryRing = nil
        dryWrite = nil
        dryScratch = nil
        drivenScratch = nil
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: ClipperParams) {
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

    /// MAIN-ACTOR. Every buffer is sized for the maximum factor here, so a
    /// later `oversampling` change is an index bound, never an allocation.
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        releaseChannelStorage()
        preparedChannels = max(0, min(channelCount, Self.maxChannels))
        preparedFrames = max(0, maxFramesPerQuantum)
        oversampler.prepare(maxFramesPerQuantum: preparedFrames, channelCount: preparedChannels)
        guard preparedChannels > 0, preparedFrames > 0 else {
            lastGeneration = .max
            needsPrime = true
            return
        }

        let ringCount = preparedChannels * Self.dryRingCapacity
        let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringCount)
        ring.initialize(repeating: 0, count: ringCount)
        dryRing = ring
        let cursor = UnsafeMutablePointer<Int>.allocate(capacity: preparedChannels)
        cursor.initialize(repeating: 0, count: preparedChannels)
        dryWrite = cursor
        let dry = UnsafeMutablePointer<Float>.allocate(capacity: preparedFrames)
        dry.initialize(repeating: 0, count: preparedFrames)
        dryScratch = dry
        let driven = UnsafeMutablePointer<Float>.allocate(capacity: preparedFrames)
        driven.initialize(repeating: 0, count: preparedFrames)
        drivenScratch = driven

        needsPrime = true
        lastGeneration = .max  // re-derive (and re-apply the factor) at quantum 1
    }

    /// ⛔ **A CONSTANT 32, AT EVERY FACTOR AND EVERY SAMPLE RATE.** Not a
    /// convenience — see DESIGN §3 and `OversamplerDesign` §3. An implementer
    /// who makes this depend on a PARAMETER must first make parameter edits
    /// republish the chain, and must re-measure against m25-n.
    var latencySamples: Int { ClipperParams.latencySamples }

    /// Clears the dry ring and both filter histories (stop-time cut /
    /// un-bypass), so a stale tail cannot ring into the next passage.
    /// Render-thread safe: stores over already-allocated storage.
    func reset() {
        oversampler.reset()
        if let ring = dryRing {
            var index = 0
            let total = preparedChannels * Self.dryRingCapacity
            while index < total { ring[index] = 0; index += 1 }
        }
        if let cursor = dryWrite {
            var index = 0
            while index < preparedChannels { cursor[index] = 0; index += 1 }
        }
        needsPrime = true
        // m39-d CR-2: a reset drops the ramp in flight (`needsPrime` re-seats
        // the values); the cell geometry is the renderer's and stays.
        rampFramesLeft = 0
        rampDriveDelta = 0
        rampCeilingDelta = 0
        rampMixDelta = 0
        rampOutDelta = 0
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
    /// ⚠️ EVERY FIELD IS RE-GUARDED AND RE-CLAMPED. A field-by-field overlay
    /// poke (`storeAutomatedParam`) bypasses `ClipperParams.init`, so that
    /// init's clamping and SNAPPING are not in force: `oversampling` reaches an
    /// `Int()` conversion that TRAPS on a NaN (the `RingModParams.waveform`
    /// precedent), and a NaN gain would reach the interpolation accumulators,
    /// from which there is no path back.
    private func deriveRenderParams(_ p: ClipperParams) {
        let driveDb = (p.driveDb.isFinite ? p.driveDb : 0)
            .clamped(to: ClipperParams.driveDbRange)
        targetDriveGain = pow(10.0, driveDb / 20.0)
        let ceilingDb = (p.ceilingDb.isFinite ? p.ceilingDb : -0.3)
            .clamped(to: ClipperParams.ceilingDbRange)
        targetCeiling = pow(10.0, ceilingDb / 20.0)
        targetMix = (p.mix.isFinite ? p.mix : 1).clamped(to: ClipperParams.mixRange)
        let outputDb = (p.outputDb.isFinite ? p.outputDb : 0)
            .clamped(to: ClipperParams.outputDbRange)
        targetOutGain = pow(10.0, outputDb / 20.0)
        // THROUGH THE LAWS in DAWCore, never a second copy of the snapping.
        soft = ClipperParams.mode(at: p.mode) == .soft
        oversampler.setFactor(ClipperParams.oversamplingFactor(at: p.oversampling))
        rampPending = true  // m39-d CR-2: the next `process` starts a ramp
    }

    /// RENDER-THREAD automation store (M4 vii-c). ⛔ SLOT ORDER IS
    /// `EffectParamSpec.specs(for: .clipper)` AND IT IS FROZEN:
    /// 0 driveDb, 1 ceilingDb, 2 mode, 3 oversampling, 4 mix, 5 outputDb.
    /// Pokes a preallocated params copy and re-derives — no allocation, no
    /// locks. ⚠️ Slot 3 can CLEAR the oversampler's histories (that is what
    /// makes it `Modulatable: refused`); automation stepping it between
    /// sections is fine, sweeping it is not.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...5).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.driveDb = value
        case 1: overlay.effective.ceilingDb = value
        case 2: overlay.effective.mode = value
        case 3: overlay.effective.oversampling = value
        case 4: overlay.effective.mix = value
        default: overlay.effective.outputDb = value
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
    private var rampDriveDelta = 0.0
    private var rampCeilingDelta = 0.0
    private var rampMixDelta = 0.0
    private var rampOutDelta = 0.0

    /// m39-d CR-1 (design §5.3): the automated values stored at this control
    /// cell's entry still stand. Adopt FIRST, so a knob publish waiting in the
    /// slot is seen now, as a store would see it (then `overlay.hold()`
    /// answers false and the renderer re-stores). Render thread; no allocation.
    func holdAutomatedParams() -> Bool {
        adoptPendingParams()
        return overlay.hold()
    }

    /// m39-d CR-2 (design §5.4): the drive, ceiling, mix and output ramps
    /// span the rest of the cell (`frames`), carried across calls, instead of one
    /// call. (Mode and oversampling step at the derive, as before.)
    func beginControlCell(frames: Int) {
        cellFramesLeft = max(0, frames)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard frameCount > 0, preparedChannels > 0, preparedFrames > 0,
              let ring = dryRing, let ringCursor = dryWrite,
              let dry = dryScratch, let driven = drivenScratch
        else { return }

        if needsPrime {
            previousDriveGain = targetDriveGain
            previousCeiling = targetCeiling
            previousMix = targetMix
            previousOutGain = targetOutGain
            needsPrime = false
        }

        let strideBytes = MemoryLayout<Float>.stride
        var channelData = InlineChannelPointers()
        var channelCount = 0
        var minFrames = min(frameCount, preparedFrames)
        for buffer in buffers where channelCount < preparedChannels {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            channelData[channelCount] = data
            minFrames = min(minFrames, Int(buffer.mDataByteSize) / strideBytes)
            channelCount += 1
        }
        guard channelCount > 0, minFrames > 0 else { return }

        // m39-d CR-2: start (or re-span) the ramp — see the MARK above. The
        // delta expressions are the pre-grid ones, verbatim.
        if rampPending || (rampFramesLeft > 0 && rampFramesLeft < minFrames) {
            rampPending = false
            let rampFrames = cellFramesLeft >= minFrames ? cellFramesLeft : minFrames
            let span = Double(rampFrames)
            rampDriveDelta = (targetDriveGain - previousDriveGain) / span
            rampCeilingDelta = (targetCeiling - previousCeiling) / span
            rampMixDelta = (targetMix - previousMix) / span
            rampOutDelta = (targetOutGain - previousOutGain) / span
            rampFramesLeft = rampFrames
        }
        let driveDelta = rampDriveDelta
        let ceilingDelta = rampCeilingDelta
        let mixDelta = rampMixDelta
        let outDelta = rampOutDelta
        // Where each accumulation ends (every channel runs the same sequence),
        // for a ramp that carries past this call.
        var endDrive = previousDriveGain
        var endCeiling = previousCeiling
        var endMix = previousMix
        var endOut = previousOutGain
        let factor = oversampler.factor
        let shapeSoft = soft
        let ringMask = Self.dryRingMask
        let latency = ClipperParams.latencySamples

        var channel = 0
        while channel < channelCount {
            guard let data = channelData[channel] else { channel += 1; continue }
            let line = ring + channel * Self.dryRingCapacity
            var write = ringCursor[channel]

            // ── PASS 1 ── the dry ring and the drive, at the base rate.
            // ⛔ The ring is a PLAIN COPY: read the sample `latency` back, then
            // store this one. No arithmetic touches that path, which is what
            // makes DESIGN §4's identity law bit-exact for −0.0 and subnormals.
            var drive = previousDriveGain
            var frame = 0
            while frame < minFrames {
                let sample = data[frame]
                dry[frame] = line[(write - latency) & ringMask]
                line[write & ringMask] = sample
                driven[frame] = Float(Double(sample) * drive)
                drive += driveDelta
                write += 1
                frame += 1
            }
            endDrive = drive
            ringCursor[channel] = write & ringMask

            // ── PASS 2 ── up to the oversampled rate.
            oversampler.upsample(driven, frameCount: minFrames, channel: channel)

            // ── PASS 3 ── THE NON-LINEARITY, at the oversampled rate.
            if let scratch = oversampler.scratch(channel: channel) {
                var ceiling = previousCeiling
                frame = 0
                while frame < minFrames {
                    let base = frame * factor
                    var sub = 0
                    while sub < factor {
                        // Through `ClipperParams.shaped` — the ONE home of the
                        // shaping law, read by this loop and by the tests.
                        scratch[base + sub] = Float(ClipperParams.shaped(
                            Double(scratch[base + sub]), ceilingLinear: ceiling,
                            soft: shapeSoft))
                        sub += 1
                    }
                    // Per BASE frame, held across its sub-samples: a threshold
                    // that moved inside one base frame would put a step INSIDE
                    // the non-linearity (DESIGN §5).
                    ceiling += ceilingDelta
                    frame += 1
                }
                endCeiling = ceiling
            }

            // ── PASS 4 ── back down. Writes the WET signal into `driven`,
            // which pass 1 is finished with — no third scratch buffer.
            oversampler.downsample(into: driven, frameCount: minFrames, channel: channel)

            // ── PASS 5 ── the blend, at the base rate.
            var mix = previousMix
            var outGain = previousOutGain
            frame = 0
            while frame < minFrames {
                if mix != 0 {
                    let wet = Double(driven[frame]) * outGain
                    data[frame] = Float(Double(dry[frame]) * (1 - mix) + wet * mix)
                } else {
                    // DESIGN §4: a bare store of the value the ring handed
                    // back. No multiply by 1.0, no add of 0.0 — `−0.0 + 0.0` is
                    // `+0.0` in IEEE, and that one addition would break the
                    // identity for negative zero.
                    data[frame] = dry[frame]
                }
                mix += mixDelta
                outGain += outDelta
                frame += 1
            }
            endMix = mix
            endOut = outGain
            channel += 1
        }

        // m39-d CR-2: a ramp still in flight carries what it reached; at the
        // ramp's end the values are SNAPPED to their targets, exactly as every
        // call end did before the grid (and still does off it).
        rampFramesLeft = rampFramesLeft > minFrames ? rampFramesLeft - minFrames : 0
        cellFramesLeft = cellFramesLeft > minFrames ? cellFramesLeft - minFrames : 0
        if rampFramesLeft > 0 {
            previousDriveGain = endDrive
            previousCeiling = endCeiling
            previousMix = endMix
            previousOutGain = endOut
            return
        }
        rampDriveDelta = 0
        rampCeilingDelta = 0
        rampMixDelta = 0
        rampOutDelta = 0

        // SNAPPED to this quantum's targets rather than left at whatever the
        // accumulation landed on (the `StereoWidthEffect` rule): a value that
        // settled at 0.9999999 instead of 1 would drift every quantum forever
        // — and for `mix` in particular that would break the `mix == 0`
        // bit-exactness DESIGN §4 depends on.
        previousDriveGain = targetDriveGain
        previousCeiling = targetCeiling
        previousMix = targetMix
        previousOutGain = targetOutGain
    }

    // MARK: - Test instruments

    /// The live oversampling factor, for tests that need to prove the snap
    /// actually reached the primitive rather than only the params struct.
    var activeFactor: Int { oversampler.factor }

    /// Non-zero words in the OVERSAMPLER's two FIR histories only. Separate
    /// from `nonZeroStateWords` because the two have different laws: the FIR
    /// histories are denormal-FLUSHED and are cleared by a factor change, while
    /// the dry ring is deliberately neither (DESIGN §4). A test that conflated
    /// them could not state either.
    var filterStateWords: Int { oversampler.nonZeroStateWords }

    /// Non-zero words across the dry ring AND both filter histories — the
    /// `PhaserEffect.nonZeroStateWords` shape, so a test can prove `reset()`
    /// cleared something rather than asserting over an empty effect.
    var nonZeroStateWords: Int {
        var count = oversampler.nonZeroStateWords
        if let ring = dryRing {
            var index = 0
            let total = preparedChannels * Self.dryRingCapacity
            while index < total {
                if ring[index] != 0 { count += 1 }
                index += 1
            }
        }
        return count
    }
}
