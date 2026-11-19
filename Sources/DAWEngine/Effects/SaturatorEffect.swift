import AVFAudio
import CAtomics
import DAWCore
import Foundation

// ============================================================================
// MARK: - DESIGN (M4 iv, oversampling by m39-ad). `SaturatorParams` in DAWCore
//         is the frozen contract and `OversamplerDesign` is the filter's.
// ============================================================================
//
// ## 1. What this is, in one paragraph
//
// A saturator BENDS the wave instead of cutting it. Quiet parts come through
// almost untouched; loud parts get squashed toward a limit but never quite reach
// it. The bending adds tones that were not in the source, which is the point:
// it is what "warm", "thick" and "fuzzy" are made of.
//
//     wet = tanh(g·x) · g^(−1/2) · out,   g = 10^(driveDb/20), out = 10^(outputDb/20)
//
// The FIXED drive compensation is −driveDb/2 dB (× g^(−1/2)): tanh compresses
// peaks as drive rises, so backing off by half the drive keeps typical program
// unity-ish loud at mix 1 (measured: a −6 dBFS sine at the default 12 dB drive
// comes out within ~1.5 dB of its input level). Output is dry·(1−mix) + wet·mix.
//
// ⛔ It is NOT `.clipper`. `tanh` only ASYMPTOTICALLY approaches its bound, so
// there is no finite input at which this effect's output equals its maximum — a
// saturator therefore cannot promise a peak ceiling, and `.clipper` can. If a
// level must not be exceeded, that is the other kind.
//
// ## 2. The signal path
//
//   factor 1 (THE DEFAULT):
//
//     x ─┬────────────────────────────────────────── (1−mix) ─┐
//        └─ tanh(×g) ─ ×g^(−1/2)·out ──────────────── ×mix ────┴─ y
//
//   factor 2 / 4:
//
//     x ─┬───────────────── [dry ring, 32 samples] ─────────── (1−mix) ─┐
//        └─ ×g ─ [↑L] ─ tanh ─ [↓L] ─ ×g^(−1/2)·out ────────── ×mix ────┴─ y
//
// ⭐ **THE DRIVE IS APPLIED AT THE BASE RATE, BEFORE THE UP STAGE.** It is a
// linear gain and the interpolator is linear, so `up(g·x) == g·up(x)`: this is
// mathematically the same thing and it is `L` times cheaper (the
// `ClipperEffect` precedent). The tanh is not: it is the non-linearity and it
// runs at the oversampled rate, which is the entire point of the exercise.
//
// ## 3. ⛔⛔ LATENCY IS PARAMETER-DEPENDENT HERE, AND `.clipper` REFUSED TO
//         LET IT BE. READ THIS BEFORE CHANGING ANYTHING IN THIS FILE.
//
// `ClipperEffect` reports a CONSTANT 32 samples at every factor, including 1,
// and its DESIGN §3 calls a factor-dependent latency "a silent correctness bug".
// That reasoning is right about the mechanism and it does not apply here,
// because this kind cannot take the clipper's way out:
//
//  · `.clipper` was NEW, so it could default to 4 and pay 32 samples forever.
//  · `.saturator` HAS SHIPPED. Reporting 32 at factor 1 would shift every
//    existing project by 32 samples and — because the dry half of `mix` would
//    have to be delayed to match — change what they sound like too. Refusing
//    that is the whole of m39-ad.
//
// So `latencySamples` is 0 at factor 1 and 32 at factors 2 and 4, and the
// staleness the clipper feared is closed by construction rather than by
// constancy. TWO properties do it, and BOTH are load-bearing:
//
//  1. **THE FACTOR MOVES ONLY ON THE MAIN ACTOR.** It is set exactly once, in
//     `adoptPendingParams`, from a snapshot published by `apply(params:)`.
//     `EffectFactory.applyParams` has ONE production call site —
//     `EffectChainState.sync` — and that runs inside
//     `PlaybackGraph.applyParameters`, whose TAIL calls
//     `recomputeCompensation`. The PDC plan is therefore rebuilt in the SAME
//     pass that moved the latency. (`latencySamples` reads a main-actor value
//     written by `apply`, NOT `oversampler.factor`: the render thread has not
//     adopted the snapshot yet when the plan is recomputed, so reading the live
//     factor would publish a stale number by exactly one pass.)
//  2. **THE FACTOR IS INERT TO AUTOMATION.** `storeAutomatedParam` ignores slot
//     3 — the `delay.sync` / `delay.division` precedent, where a param that must
//     not move from the render thread simply falls outside the slot guard. Were
//     it automatable, a lane could move the factor mid-render with no main-actor
//     pass at all, and that IS the silent staleness.
//
// ⚠️ There is a bounded transient at a deliberate factor change: the plan target
// is stored on the main actor while the render thread adopts the new factor at
// the top of its next quantum, so for up to one quantum the compensation and the
// effect disagree by 32 samples. It is a one-off at the moment a user turns a
// knob, alongside the ~32-sample filter ramp-in that `Oversampler.setFactor`
// already costs, and it is the price of not making every existing project pay.
//
// ## 4. The identity law — TWO laws, because the latency is two numbers
//
// At **factor 1**: `mix == 0` leaves the buffer COMPLETELY UNTOUCHED (the v0
// `GainEffect` unity-skip). The shaper is stateless at this factor and the
// reported latency is 0, so there is nothing to align and nothing to write.
//
// At **factor 2 / 4**: `out[n] == in[n − 32]`, BIT-EXACT — including −0.0,
// subnormals and infinities, because the value is copied out of a plain `Float`
// ring and stored with no arithmetic anywhere on that path. An effect that
// reports 32 samples of latency and then passes audio through UNDELAYED would be
// mis-aligned by 32 samples against everything PDC compensates around it
// (`ClipperEffect` DESIGN §4, the same law for the same reason).
//
// ⚠️ The dry ring is deliberately NOT the `Oversampler`'s factor-1 copy path:
// that one flushes subnormals (`Oversampler` §6) and this law must not.
//
// ⛔ At factor 2/4 the wet path KEEPS RUNNING at `mix == 0` (the
// `FreqShifterEffect` convention) so the FIR histories stay warm and raising
// `mix` later picks up mid-signal rather than ramping in from a cleared filter.
//
// ## 5. ⛔ NO PARAMETER SMOOTHING, AT EITHER FACTOR, AND THAT IS DELIBERATE
//
// `ClipperEffect` interpolates its drive / ceiling / mix / trim per sample
// (rule 6.0.6). This kind does NOT, and must not: it has never smoothed, a
// knob step has always been a step here, and adding interpolation would change
// what a shipped effect does at its existing settings — the exact regression
// m39-ad exists to refuse. It would also break byte identity outright, because
// a `Float(Double(sample) * gain)` accumulator does not round the way
// `sample * gain` in `Float` does even when the gain is constant.
//
// The two factors therefore differ in EXACTLY ONE respect — whether the tanh
// runs at the base rate or an oversampled one — which is what makes
// `scripts/gates/m39ad-saturator-physics.mjs`'s H1/H3 invariance legs meaningful.
//
// ## 6. Denormals and NaN
//
// tanh is bounded (|wet| ≤ comp·out) and the filters are all-zero (no feedback),
// so nothing here can generate a decaying denormal of its own; the `Oversampler`
// flushes what it is FED (§6 there). At factor 2/4 the shaped value is re-checked
// for finiteness before it reaches the decimation history: a NaN there would
// poison 129 later output samples. At factor 1 the arithmetic is v0's, untouched,
// NaN behaviour included — changing it would be a behaviour change on the default.
//
// Parameter updates follow the GainEffect atomic-POD-publish convention.
// Render-path contract: `process()`/`reset()` allocate nothing, take no locks,
// log nothing, touch no ObjC.

final class SaturatorEffect: EffectRendering, @unchecked Sendable {
    /// Matches `CompressorEffect`'s `InlineChannelPointers` capacity.
    private static let maxChannels = 8

    /// Dry-delay ring capacity: the next power of two at or above
    /// `OversamplerDesign.latencySamples` (32 → 64), for mask indexing.
    private static let dryRingCapacity = 64
    private static let dryRingMask = dryRingCapacity - 1

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: SaturatorParams

        init(generation: UInt64, params: SaturatorParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    /// The shared primitive (m39-ac). Owned here; `prepare`/`reset` forward to
    /// it. Idle at factor 1, which is the default — see DESIGN §3.
    private let oversampler = Oversampler()

    // Prepared storage (main-actor allocated, render-thread read/written).
    /// Per-channel dry delay ring — a PLAIN copy, no arithmetic, so DESIGN §4's
    /// factor-2/4 identity law holds bit-exactly.
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
    private var driveLinear: Float = 3.981_071_7   // +12 dB
    private var postGain: Float = 0.501_187_23     // g^(−1/2) · 10^(outputDb/20)
    private var mix: Float = 1
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<SaturatorParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: SaturatorParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []
    /// ⛔ **MAIN-ACTOR STATE, AND THAT IS THE POINT (DESIGN §3.1).** Written by
    /// `init` and `apply(params:)`; read by `latencySamples`. Reading
    /// `oversampler.factor` instead would report the factor the RENDER thread
    /// has adopted, which lags the published snapshot by up to one quantum —
    /// and `recomputeCompensation` runs at the tail of the very pass that
    /// publishes it, so the plan would be built from the previous value.
    private var publishedLatencySamples: Int

    init(params: SaturatorParams = SaturatorParams()) {
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        lastAppliedParams = params
        publishedLatencySamples =
            SaturatorParams.latencySamples(oversampling: params.oversampling)
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
    ///
    /// ⛔ `publishedLatencySamples` moves HERE, synchronously, before this
    /// function returns — so the `recomputeCompensation` at the tail of the same
    /// `applyParameters` pass sees the new number (DESIGN §3.1).
    @MainActor
    func apply(params: SaturatorParams) {
        guard params != lastAppliedParams else { return }
        lastAppliedParams = params
        publishedLatencySamples =
            SaturatorParams.latencySamples(oversampling: params.oversampling)
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
    /// later `oversampling` change is an index bound, never an allocation —
    /// including the very common case of an effect that lives its whole life at
    /// factor 1 and then gets switched up once.
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        releaseChannelStorage()
        preparedChannels = max(0, min(channelCount, Self.maxChannels))
        preparedFrames = max(0, maxFramesPerQuantum)
        oversampler.prepare(maxFramesPerQuantum: preparedFrames, channelCount: preparedChannels)
        guard preparedChannels > 0, preparedFrames > 0 else {
            lastGeneration = .max
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

        lastGeneration = .max  // re-derive (and re-apply the factor) at quantum 1
    }

    /// ⛔ **0 AT FACTOR 1, 32 AT FACTORS 2 AND 4 — see DESIGN §3 for the two
    /// properties that make a parameter-dependent latency safe on this kind and
    /// why `.clipper` deliberately did the opposite.** Reads MAIN-ACTOR state,
    /// never `oversampler.factor`.
    var latencySamples: Int { publishedLatencySamples }

    /// Clears the dry ring and both filter histories (stop-time cut /
    /// un-bypass), so a stale tail cannot ring into the next passage.
    /// Render-thread safe: stores over already-allocated storage.
    ///
    /// ⚠️ At factor 1 there is genuinely nothing to clear — the shaper is
    /// stateless and neither the ring nor the filters are written — but the
    /// clear is unconditional, because a `reset()` taken while at factor 1 must
    /// still wipe whatever a previous stint at 2×/4× left behind.
    func reset() {
        oversampler.reset()
        clearDryLine()
    }

    /// Zeroes the dry ring and its write cursors. Render-thread safe.
    private func clearDryLine() {
        if let ring = dryRing {
            var index = 0
            let total = preparedChannels * Self.dryRingCapacity
            while index < total { ring[index] = 0; index += 1 }
        }
        if let cursor = dryWrite {
            var index = 0
            while index < preparedChannels { cursor[index] = 0; index += 1 }
        }
    }

    /// Adopts a newly published main-actor snapshot (borrowed — retire bin
    /// guarantees lifetime). Called at the top of `process()` AND by
    /// `storeAutomatedParam`, so an automation store never loses to a
    /// snapshot adopted later in the same quantum.
    ///
    /// ⛔⛔ **THIS IS THE ONLY PLACE THE OVERSAMPLING FACTOR EVER MOVES**
    /// (DESIGN §3.1). Deliberately NOT in `deriveRenderParams`, which is also
    /// reached from `storeAutomatedParam` and from the automation revert —
    /// both render-thread events, neither of which may move a latency the PDC
    /// plan has already been built from.
    private func adoptPendingParams() {
        guard let raw = daw_atomic_ptr_load(paramsSlot) else { return }
        let snapshot = Unmanaged<ParamSnapshot>.fromOpaque(raw).takeUnretainedValue()
        guard snapshot.generation != lastGeneration else { return }
        lastGeneration = snapshot.generation
        overlay.rebase(snapshot.params)
        deriveRenderParams(snapshot.params)
        // THROUGH THE LAWS in DAWCore, never a second copy of the snapping.
        let factor = SaturatorParams.oversamplingFactor(at: snapshot.params.oversampling)
        if factor != oversampler.factor {
            // `setFactor` clears the FIR histories (they hold samples at the OLD
            // oversampled rate). The dry ring is cleared HERE because it is not
            // the primitive's: a 32-sample burst of audio from before the change
            // would otherwise be read back through the new path.
            oversampler.setFactor(factor)
            clearDryLine()
        }
    }

    /// Recomputes the derived gains from `p` — generation change, automation
    /// stores, and the automation revert route through the SAME math (pure
    /// libm, no allocation; render-thread safe).
    ///
    /// ⛔ **UNCHANGED FROM v0, TO THE EXPRESSION.** `ClipperEffect` re-guards and
    /// re-clamps every field here because a field-by-field overlay poke bypasses
    /// `init`'s clamping and its `oversampling` reaches an `Int()` that traps on
    /// a NaN. Neither hazard exists on this kind: `oversampling` is never read
    /// from the overlay (it is not automatable), and `storeAutomatedParam`
    /// already refuses a non-finite value. Adding clamps would change what an
    /// out-of-range automation lane does to an effect that has shipped.
    private func deriveRenderParams(_ p: SaturatorParams) {
        let g = pow(10.0, p.driveDb / 20.0)
        // Fixed −driveDb/2 dB compensation folded with the output trim.
        postGain = Float(pow(g, -0.5) * pow(10.0, p.outputDb / 20.0))
        driveLinear = Float(g)
        mix = Float(p.mix)
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .saturator)`: 0 driveDb, 1 mix,
    /// 2 outputDb, **3 oversampling — WHICH THIS FUNCTION DELIBERATELY DOES NOT
    /// ACCEPT.** Pokes a preallocated params copy and re-derives — no
    /// allocation, no locks.
    ///
    /// ⛔⛔ **THE `(0...2)` GUARD IS A CORRECTNESS REQUIREMENT, NOT AN
    /// OVERSIGHT.** Slot 3 changes this effect's LATENCY (DESIGN §3), and the
    /// PDC plan is rebuilt only on a main-actor parameter pass. A lane moving the
    /// factor from the render thread would leave the plan stale with every unit
    /// test still green — the exact failure `OversamplerDesign` §3 describes. It
    /// is inert here for the same reason `delay.sync` and `delay.division` are
    /// inert in `DelayEffect.storeAutomatedParam`, and both spec notes say
    /// "NOT automatable" out loud.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...2).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.driveDb = value
        case 1: overlay.effective.mix = value
        default: overlay.effective.outputDb = value
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

    /// m39-d CR-2 (design §5.4): deliberately a no-op — class (c): "a knob step has always been a
    /// step here" (`SaturatorEffect` DESIGN §5).
    func beginControlCell(frames: Int) {}

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        if oversampler.factor == 1 {
            processAtBaseRate(buffers: buffers, frameCount: frameCount)
        } else {
            processOversampled(buffers: buffers, frameCount: frameCount)
        }
    }

    // MARK: - Factor 1 — THE DEFAULT, AND IT IS v0 VERBATIM

    /// ⛔⛔ **EVERY ARITHMETIC EXPRESSION IN THIS FUNCTION IS v0's, IN v0's
    /// ORDER, IN `Float`.** It is what
    /// `scripts/gates/m39ad-saturator-default-bytes.mjs` pins the sha256 of. Do
    /// not introduce a `Double` intermediate, a `Float(Double(...))` cast, a
    /// per-sample interpolation, or a fused expression: each of those changes the
    /// rounding, and the rounding is the promise. The ONLY change from v0 is
    /// `while` in place of `for frame in 0..<frames` — a `Range` iteration raises
    /// ~2 malloc/free events PER ITERATION at `-Onone`, which is where every
    /// render-path test in this tree runs, and the allocation gate asserts an
    /// absolute zero. The loop body is untouched, so the bytes are too (measured:
    /// the pinned hash is unchanged).
    ///
    /// The oversampler is not merely idle here, it is BYPASSED: no history is
    /// written, no filter runs, and `latencySamples` is 0.
    private func processAtBaseRate(
        buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int
    ) {
        // mix 0: stateless at this factor, so skip the whole pass (bit-exact
        // dry, DESIGN §4). The buffer is not written at all — not even a
        // multiply by 1.0, which would turn a −0.0 into a +0.0.
        guard mix != 0 else { return }

        let strideBytes = MemoryLayout<Float>.stride
        let dryGain = 1 - mix
        let mixGain = mix
        let drive = driveLinear
        let post = postGain
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = min(frameCount, Int(buffer.mDataByteSize) / strideBytes)
            var frame = 0
            while frame < frames {
                let dry = data[frame]
                let wet = tanhf(drive * dry) * post
                data[frame] = dry * dryGain + wet * mixGain
                frame += 1
            }
        }
    }

    // MARK: - Factors 2 and 4 — the oversampled path

    /// The `ClipperEffect` five-pass structure, with tanh where its shaper was
    /// and WITHOUT its per-sample parameter interpolation (DESIGN §5).
    private func processOversampled(
        buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int
    ) {
        guard frameCount > 0, preparedChannels > 0, preparedFrames > 0,
              let ring = dryRing, let ringCursor = dryWrite,
              let dry = dryScratch, let driven = drivenScratch
        else { return }

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

        let factor = oversampler.factor
        let dryGain = 1 - mix
        let mixGain = mix
        let drive = driveLinear
        let post = postGain
        let ringMask = Self.dryRingMask
        let latency = OversamplerDesign.latencySamples

        var channel = 0
        while channel < channelCount {
            guard let data = channelData[channel] else { channel += 1; continue }
            let line = ring + channel * Self.dryRingCapacity
            var write = ringCursor[channel]

            // ── PASS 1 ── the dry ring and the drive, at the base rate.
            // ⛔ The ring is a PLAIN COPY: read the sample `latency` back, then
            // store this one. No arithmetic touches that path, which is what
            // makes DESIGN §4's identity law bit-exact for −0.0 and subnormals.
            var frame = 0
            while frame < minFrames {
                let sample = data[frame]
                dry[frame] = line[(write - latency) & ringMask]
                line[write & ringMask] = sample
                driven[frame] = drive * sample
                write += 1
                frame += 1
            }
            ringCursor[channel] = write & ringMask

            // ── PASS 2 ── up to the oversampled rate.
            oversampler.upsample(driven, frameCount: minFrames, channel: channel)

            // ── PASS 3 ── THE NON-LINEARITY, at the oversampled rate. This is
            // the whole reason the other four passes exist.
            if let scratch = oversampler.scratch(channel: channel) {
                let count = minFrames * factor
                var index = 0
                while index < count {
                    let shaped = tanhf(scratch[index])
                    // DESIGN §6: a NaN reaching the decimation history would
                    // poison 129 later output samples. One compare per sample.
                    scratch[index] = shaped.isFinite ? shaped : 0
                    index += 1
                }
            }

            // ── PASS 4 ── back down. Writes the WET signal into `driven`,
            // which pass 1 is finished with — no third scratch buffer.
            oversampler.downsample(into: driven, frameCount: minFrames, channel: channel)

            // ── PASS 5 ── the blend, at the base rate. The output trim and the
            // fixed drive compensation are both folded into `post`, exactly as
            // at factor 1, and applied AFTER the decimation — a linear gain
            // commutes with a linear filter, and doing it here is one multiply
            // per output sample instead of `factor` of them.
            frame = 0
            if mix != 0 {
                while frame < minFrames {
                    let wet = driven[frame] * post
                    data[frame] = dry[frame] * dryGain + wet * mixGain
                    frame += 1
                }
            } else {
                // DESIGN §4: a bare store of the value the ring handed back. No
                // multiply by 1.0, no add of 0.0 — `−0.0 + 0.0` is `+0.0` in
                // IEEE, and that one addition would break the identity for
                // negative zero. The WET passes above still ran, so the filter
                // histories stay warm.
                while frame < minFrames {
                    data[frame] = dry[frame]
                    frame += 1
                }
            }
            channel += 1
        }
    }

    // MARK: - Test instruments

    /// The live oversampling factor, for tests that need to prove the snap
    /// actually reached the primitive rather than only the params struct.
    var activeFactor: Int { oversampler.factor }

    /// Non-zero words in the OVERSAMPLER's two FIR histories only. Separate from
    /// `nonZeroStateWords` because the two have different laws: the FIR
    /// histories are denormal-FLUSHED, while the dry ring is deliberately not
    /// (DESIGN §4).
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
