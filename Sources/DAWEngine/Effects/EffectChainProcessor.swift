import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Stable wrapper around one live effect instance in a chain. The wrapper —
/// not the instance — carries the bypass/reset atomics, so a bypass toggle is
/// one atomic store and NEVER a chain republish. Instances are reused by
/// effect id across chain edits (add/remove/reorder), so DSP state survives.
///
/// Un-bypass sets `resetFlag`, so stale tails from before the bypass never
/// replay. A bypass toggle crossfades equal-power over ~10 ms at the swap
/// point inside the walk (m15-f — the audit-m15 B3 click fix): the render
/// side detects the flag change, keeps processing the unit through the fade,
/// and mixes wet against a preallocated dry copy. Steady bypass states walk
/// exactly the pre-m15f paths (bit-identical null when nothing toggles).
final class ChainEffectUnit: @unchecked Sendable {
    /// Dry-scratch bounds: the house max quantum (the `EffectChainState`
    /// prepare bound) × stereo. Allocated once at init — control plane.
    static let scratchFrames = 8_192
    static let scratchChannels = 2
    /// Bypass crossfade length: 10 ms equal-power. Why 10 ms: the audit gate
    /// asks ≥ 5 ms of monotone ramp where today is a ≤ 2 ms step, 10 ms gives
    /// 2× margin while staying well under the ~30 ms threshold where a swap
    /// starts reading as two events; equal-power (sin/cos) because wet and
    /// dry are distinct signals — a linear fade would dip −3 dB power at the
    /// midpoint on decorrelated material (100 %-wet delays/reverbs), while
    /// the correlated worst case overshoots ≤ +3 dB for 5 ms, inaudible next
    /// to the click it replaces.
    static let crossfadeSeconds = 0.010

    let id: UUID
    let kind: EffectDescriptor.Kind
    let instance: any EffectRendering
    /// The instance's keyable face (m12-f), cast ONCE here on the control
    /// plane — the render walk must never run a dynamic cast (the Swift
    /// runtime's conformance lookup can allocate/lock on first use). nil for
    /// non-keyable kinds; the walk then always takes the plain path.
    let keyableInstance: (any KeyableEffectRendering)?
    /// The instance's gain-reduction face (m22-e), cast ONCE at creation for
    /// the same reason. nil for kinds that don't measure GR — the control
    /// plane then reports nothing rather than fabricating a 0.
    let gainReducingInstance: (any GainReductionReporting)?
    /// 1 = skip this unit in the walk. Heap-allocated for a stable address.
    let bypassFlag: UnsafeMutablePointer<daw_atomic_u32>
    /// COUNTDOWN of `instance.reset()` passes, consumed one per walk (m15-f).
    /// 1 = reset at the top of the next walk (un-bypass, stop-time tail cut).
    /// 2 = the flush-family DOUBLE-ARM: live, the render thread can deliver
    /// one in-flight pre-flush quantum AFTER the first reset consumes — the
    /// ring is wiped and immediately re-dirtied by stale signal (the m14-d
    /// edit-seam echo blip). The second pass survives to the NEXT walk, whose
    /// input is post-flush silence, and wipes the leak for good.
    let resetFlag: UnsafeMutablePointer<daw_atomic_u32>
    /// Preallocated dry copy for the bypass crossfade — written and read only
    /// inside `renderCrossfade` (render thread), sized `scratchFrames ×
    /// scratchChannels`, allocated at init (control plane).
    private let dryScratch: UnsafeMutablePointer<Float>
    /// Crossfade length in frames at the prepared rate. Control-plane write
    /// window only (`StagePlacementBox` discipline): unit creation and the
    /// quiesced rate-change re-prepare, both before the next render observes
    /// it. Default = 10 ms @ 48 kHz for directly constructed test units.
    private(set) var crossfadeFrames = 480

    // Render-thread-only fade state (the DelayEffect field discipline:
    // touched exclusively inside the walk).
    private var renderBypassed: Bool
    private var fadeTotal = 0     // 0 = no fade active
    private var fadePosition = 0  // frames into the active fade
    /// 1 = this unit's detector reads the strip's key buffer when the walk
    /// receives one (m12-f, `Effect.sidechainSourceTrackID != nil`). Armed by
    /// `EffectChainState.sync` like bypass — one atomic store, never a chain
    /// republish. 0, or a walk with no key delivered, is the self-keyed
    /// (bit-exact pre-sidechain) path.
    let useKeyFlag: UnsafeMutablePointer<daw_atomic_u32>

    init(id: UUID, kind: EffectDescriptor.Kind,
         instance: any EffectRendering, isBypassed: Bool) {
        self.id = id
        self.kind = kind
        self.instance = instance
        self.keyableInstance = instance as? any KeyableEffectRendering
        self.gainReducingInstance = instance as? any GainReductionReporting
        bypassFlag = .allocate(capacity: 1)
        daw_atomic_u32_store(bypassFlag, isBypassed ? 1 : 0)
        resetFlag = .allocate(capacity: 1)
        daw_atomic_u32_store(resetFlag, 0)
        useKeyFlag = .allocate(capacity: 1)
        daw_atomic_u32_store(useKeyFlag, 0)
        dryScratch = .allocate(capacity: Self.scratchFrames * Self.scratchChannels)
        dryScratch.initialize(repeating: 0,
                              count: Self.scratchFrames * Self.scratchChannels)
        // The render side starts in agreement with the flag: the first walk
        // of a freshly built unit never fades (byte-identity for constant
        // bypass states).
        renderBypassed = isBypassed
    }

    deinit {
        bypassFlag.deallocate()
        resetFlag.deallocate()
        useKeyFlag.deallocate()
        dryScratch.deallocate()
    }

    @MainActor
    var isBypassed: Bool { daw_atomic_u32_load(bypassFlag) == 1 }

    /// One atomic store; un-bypassing arms the reset flag (tails cleared
    /// before the unit processes again).
    @MainActor
    func setBypassed(_ bypassed: Bool) {
        let was = daw_atomic_u32_exchange(bypassFlag, bypassed ? 1 : 0)
        if was == 1 && !bypassed {
            daw_atomic_u32_store(resetFlag, 1)
        }
    }

    /// Arms `passes` reset walks (see `resetFlag`). 1 = the classic single
    /// arm; 2 = the flush-family double-arm (m15-f). Clamped to 1...2.
    @MainActor
    func requestReset(passes: UInt32 = 1) {
        daw_atomic_u32_store(resetFlag, max(1, min(2, passes)))
    }

    /// Pending reset passes (test seam, @testable).
    @MainActor
    var pendingResetPasses: UInt32 { daw_atomic_u32_load(resetFlag) }

    /// Sets the crossfade length for the prepared rate. Control-plane write
    /// window only: `EffectChainState.sync` calls this at unit creation and
    /// inside the quiesced rate-change re-prepare.
    @MainActor
    func setCrossfadeLength(sampleRate: Double) {
        crossfadeFrames = max(1, Int(Self.crossfadeSeconds * sampleRate))
    }

    @MainActor
    var usesKey: Bool { daw_atomic_u32_load(useKeyFlag) == 1 }

    /// One atomic store (the bypass convention) — flipping the key never
    /// republishes the chain and never rebuilds the unit (DSP state survives
    /// a key set/clear; the graph edge itself is PlaybackGraph's business).
    @MainActor
    func setUsesKey(_ usesKey: Bool) {
        daw_atomic_u32_store(useKeyFlag, usesKey ? 1 : 0)
    }

    // MARK: - Render surface (render thread, called only by the chain walk)

    /// Equal-power crossfade gains at `progress` ∈ [0, 1]: `toward` rises
    /// 0 → 1, `away` falls 1 → 0, `toward² + away² == 1` at every point (the
    /// constant-power law). Pure libm — render-thread safe.
    static func crossfadeGains(progress: Float) -> (toward: Float, away: Float) {
        let theta = min(1, max(0, progress)) * (Float.pi / 2)
        return (sinf(theta), cosf(theta))
    }

    /// True while a bypass crossfade is in flight.
    var fadeActive: Bool { fadeTotal > 0 }

    /// Reconciles the observed bypass flag with the render-side fade state:
    /// a change starts a crossfade toward the new state; a change while a
    /// fade is already running REVERSES it in place (position inversion —
    /// the gain trajectory stays continuous because sin/cos mirror around
    /// the midpoint). No-op while the flag is steady.
    func observeBypass(_ bypassedNow: Bool) {
        guard bypassedNow != renderBypassed else { return }
        if fadeTotal > 0 {
            fadePosition = fadeTotal - fadePosition
        } else {
            fadeTotal = max(1, crossfadeFrames)
            fadePosition = 0
        }
        renderBypassed = bypassedNow
    }

    /// The steady-state active walk step: keyed iff a key buffer arrived AND
    /// this unit's key flag is armed AND the instance is keyable — verbatim
    /// the pre-m15f dispatch.
    func processActive(buffers: UnsafeMutableAudioBufferListPointer,
                       key: UnsafeMutableAudioBufferListPointer?,
                       frameCount: Int) {
        if let key, let keyable = keyableInstance,
           daw_atomic_u32_load(useKeyFlag) == 1 {
            keyable.process(buffers: buffers, key: key, frameCount: frameCount)
        } else {
            instance.process(buffers: buffers, frameCount: frameCount)
        }
    }

    /// One crossfading walk step (m15-f): dry-copy into the preallocated
    /// scratch, process wet in place, mix equal-power along the fade
    /// position. The unit keeps processing through a fade-OUT so its tail
    /// rings under the falling wet gain; a fade-IN starts on a clean ring
    /// (un-bypass armed the reset, consumed at the top of this walk).
    /// RENDER-THREAD CONTRACT: memcpy + pure libm only — no allocation, no
    /// locks, no ObjC.
    func renderCrossfade(buffers: UnsafeMutableAudioBufferListPointer,
                         key: UnsafeMutableAudioBufferListPointer?,
                         frameCount: Int) {
        // Oversized quantum or channel layout (never expected — instances
        // prepare at the same bounds): degrade to the pre-m15f hard swap.
        guard frameCount <= Self.scratchFrames,
              buffers.count <= Self.scratchChannels else {
            fadeTotal = 0
            fadePosition = 0
            if !renderBypassed {
                processActive(buffers: buffers, key: key, frameCount: frameCount)
            }
            return
        }
        let stride = MemoryLayout<Float>.stride
        // 1. Dry copy (bounded memcpy per channel).
        for (channel, buffer) in buffers.enumerated() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = min(frameCount, Int(buffer.mDataByteSize) / stride)
            (dryScratch + channel * Self.scratchFrames).update(from: data, count: frames)
        }
        // 2. Wet in place — the same dispatch as the steady path.
        processActive(buffers: buffers, key: key, frameCount: frameCount)
        // 3. Equal-power mix along the fade. Gains are a pure function of
        //    the frame index, so channel-major iteration applies identical
        //    gains per frame across channels.
        let total = Float(fadeTotal)
        for (channel, buffer) in buffers.enumerated() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = min(frameCount, Int(buffer.mDataByteSize) / stride)
            let dry = dryScratch + channel * Self.scratchFrames
            for frame in 0..<frames {
                let progress = (Float(fadePosition) + Float(frame)) / total
                let (toward, away) = Self.crossfadeGains(progress: progress)
                let wetGain = renderBypassed ? away : toward
                let dryGain = renderBypassed ? toward : away
                data[frame] = data[frame] * wetGain + dry[frame] * dryGain
            }
        }
        fadePosition += frameCount
        if fadePosition >= fadeTotal {
            fadeTotal = 0
            fadePosition = 0
        }
    }
}

/// Immutable, atomically published chain: snapshot array order = `Track.effects`
/// order. Chain edits build a NEW snapshot (reusing surviving units by id) and
/// publish it through `EffectChainProcessor` — never a graph mutation.
final class EffectChainSnapshot: @unchecked Sendable {
    let units: ContiguousArray<ChainEffectUnit>

    init(units: ContiguousArray<ChainEffectUnit>) {
        self.units = units
    }
}

/// The render-side chain walker: one per strip (audio track sandwich, bus
/// sandwich, instrument renderer). Field ownership mirrors
/// `InstrumentRenderer.scheduleSlot`:
///  · `slot` (heap `daw_atomic_ptr`): shared main-actor ⇄ render-thread
///  · `retired` bin: main actor ONLY — displaced snapshots stay alive ≥ 1 s
///    so a render quantum still borrowing the old pointer can never touch
///    freed memory.
///
/// RENDER-THREAD CONTRACT for `process(...)`: no allocation, no locks, no
/// ObjC, no retain/release of the snapshot (borrowed via takeUnretainedValue).
final class EffectChainProcessor: @unchecked Sendable {
    private let slot: UnsafeMutablePointer<daw_atomic_ptr>
    private var retired: [(snapshot: EffectChainSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init() {
        slot = .allocate(capacity: 1)
        daw_atomic_ptr_init(slot)
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(slot, nil) {
            Unmanaged<EffectChainSnapshot>.fromOpaque(raw).release()
        }
        slot.deallocate()
    }

    // MARK: - Main-actor surface

    /// Publishes `snapshot` (nil unpublishes — the empty chain). The slot
    /// holds a +1 retain; the displaced snapshot moves to the retire bin and
    /// is released only when older than 1 s.
    @MainActor
    func publish(_ snapshot: EffectChainSnapshot?) {
        let now = ContinuousClock.now
        let newRaw = snapshot.map { UnsafeMutableRawPointer(Unmanaged.passRetained($0).toOpaque()) }
        if let oldRaw = daw_atomic_ptr_exchange(slot, newRaw) {
            retired.append((Unmanaged<EffectChainSnapshot>.fromOpaque(oldRaw).takeRetainedValue(), now))
        }
        retired.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

    /// Main-actor borrow of the live snapshot (reset fan-out + test seam) —
    /// the slot's retain keeps it alive for the duration of the read.
    @MainActor
    var currentSnapshot: EffectChainSnapshot? {
        daw_atomic_ptr_load(slot).map {
            Unmanaged<EffectChainSnapshot>.fromOpaque($0).takeUnretainedValue()
        }
    }

    /// Arms every unit's reset countdown — the stop-time tail-cut contract
    /// (`stopAllPlayers`), matching the v0-honest instrument flush.
    /// `passes: 2` is the live flush-family double-arm (m15-f; see
    /// `ChainEffectUnit.resetFlag`).
    @MainActor
    func requestResetAll(passes: UInt32 = 1) {
        guard let snapshot = currentSnapshot else { return }
        for unit in snapshot.units {
            unit.requestReset(passes: passes)
        }
    }

    // MARK: - Render surface (render thread)

    /// True when a chain is published (it may still be all-bypassed). The
    /// silence-path check: a non-empty chain must process every quantum so
    /// tails ring on silent input.
    var hasPublishedChain: Bool {
        daw_atomic_ptr_load(slot) != nil
    }

    /// Render-thread borrow of the published snapshot (+0 via
    /// `takeUnretainedValue`; the retire bin guarantees lifetime) — the
    /// automation effect-param store (M4 vii-c) walks it BEFORE `process`.
    var renderSnapshot: EffectChainSnapshot? {
        daw_atomic_ptr_load(slot).map {
            Unmanaged<EffectChainSnapshot>.fromOpaque($0).takeUnretainedValue()
        }
    }

    /// Walks the chain IN PLACE over `bufferList`. Per unit: honor the reset
    /// countdown, crossfade a just-toggled bypass, skip if steadily bypassed,
    /// else process. No-op when nothing is published.
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        process(bufferList: bufferList, frameCount: frameCount, key: nil)
    }

    /// Keyed walk (m12-f): `key` is the strip's pulled sidechain buffer for
    /// this quantum (ChainHostAU's preallocated key scratch), handed to any
    /// unit whose `useKeyFlag` is armed and whose instance is keyable. nil —
    /// no key connected, or the bus-1 pull degraded (§6.2) — walks every
    /// unit self-keyed, bit-exact with the pre-sidechain walk.
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int,
                 key: UnsafeMutableAudioBufferListPointer?) {
        guard let raw = daw_atomic_ptr_load(slot) else { return }
        let snapshot = Unmanaged<EffectChainSnapshot>.fromOpaque(raw).takeUnretainedValue()
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        snapshot.units.withUnsafeBufferPointer { units in
            for index in 0..<units.count {
                let unit = units[index]
                // Reset countdown (m15-f): consume one pass per walk; a
                // double-armed flush re-arms the remainder so the NEXT walk
                // wipes whatever an in-flight pre-flush quantum leaked into
                // the just-cleared ring. The store-back race with a
                // concurrent control-plane arm can only ADD resets, never
                // lose the one in hand.
                let pendingResets = daw_atomic_u32_exchange(unit.resetFlag, 0)
                if pendingResets > 0 {
                    unit.instance.reset()
                    if pendingResets > 1 {
                        daw_atomic_u32_store(unit.resetFlag, pendingResets - 1)
                    }
                }
                // Bypass with equal-power crossfade (m15-f): a flag CHANGE
                // fades over ~10 ms; steady states walk the pre-m15f paths
                // verbatim (skip / keyed-or-plain process).
                let bypassedNow = daw_atomic_u32_load(unit.bypassFlag) == 1
                unit.observeBypass(bypassedNow)
                if unit.fadeActive {
                    unit.renderCrossfade(buffers: buffers, key: key, frameCount: frameCount)
                } else if !bypassedNow {
                    unit.processActive(buffers: buffers, key: key, frameCount: frameCount)
                }
            }
        }
    }
}

/// Main-actor sync half of one strip's chain: diffs the domain descriptor
/// list against the live units and turns edits into the cheapest legal
/// operation — param apply (atomic POD publish inside the instance), bypass
/// toggle (atomic flag), or snapshot republish (identity/order change).
/// NOTHING here is structural: it runs inside `PlaybackGraph.applyParameters`
/// (both sides of every start → offline parity for free) and never touches
/// graph topology.
@MainActor
final class EffectChainState {
    let processor: EffectChainProcessor
    private var lastDescriptors: [EffectDescriptor] = []
    private var units: [UUID: ChainEffectUnit] = [:]
    private var preparedSampleRate: Double = 0

    /// Resolves the live hosted instance for one `.audioUnit` effect id
    /// (M4 v); nil — not prepared yet, missing component, or no provider —
    /// installs the passthrough placeholder from the factory. Set by
    /// `PlaybackGraph` at strip creation (the `audioUnitProvider` mirror).
    var hostedEffectProvider: (@MainActor (UUID) -> (any EffectRendering)?)?

    /// Same max-quantum bound the instrument nodes prepare with.
    private static let maxFramesPerQuantum = 8_192

    init(processor: EffectChainProcessor) {
        self.processor = processor
    }

    private struct IdentityKey: Equatable {
        let id: UUID
        let kind: EffectDescriptor.Kind
    }

    /// Reconciles the chain with `descriptors`. Surviving units (same id +
    /// kind) are reused — DSP state survives add/remove/reorder. Only an
    /// identity/order change republishes the snapshot; bypass and params
    /// land in place.
    func sync(descriptors: [EffectDescriptor], sampleRate: Double) {
        // Rate change (live device swap): re-prepare surviving instances.
        // Fresh graphs land here once with their own rate before first render.
        if sampleRate != preparedSampleRate {
            for unit in units.values {
                unit.instance.prepare(sampleRate: sampleRate,
                                      maxFramesPerQuantum: Self.maxFramesPerQuantum,
                                      channelCount: 2)
                unit.setCrossfadeLength(sampleRate: sampleRate)
            }
            preparedSampleRate = sampleRate
        }
        guard descriptors != lastDescriptors else { return }

        let oldIdentity = lastDescriptors.map { IdentityKey(id: $0.id, kind: $0.kind) }
        let newIdentity = descriptors.map { IdentityKey(id: $0.id, kind: $0.kind) }

        var next: [UUID: ChainEffectUnit] = [:]
        var ordered = ContiguousArray<ChainEffectUnit>()
        ordered.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            let unit: ChainEffectUnit
            if let existing = units[descriptor.id], existing.kind == descriptor.kind {
                unit = existing
            } else {
                let instance: any EffectRendering
                if descriptor.kind == .audioUnit,
                   let hosted = hostedEffectProvider?(descriptor.id) {
                    instance = hosted
                } else {
                    instance = EffectFactory.makeInstance(for: descriptor)
                }
                instance.prepare(sampleRate: sampleRate,
                                 maxFramesPerQuantum: Self.maxFramesPerQuantum,
                                 channelCount: 2)
                unit = ChainEffectUnit(id: descriptor.id, kind: descriptor.kind,
                                       instance: instance,
                                       isBypassed: descriptor.isBypassed)
                unit.setCrossfadeLength(sampleRate: sampleRate)
            }
            // Params + bypass land in place on every pass (both dedupe).
            EffectFactory.applyParams(descriptor, to: unit.instance)
            unit.setBypassed(descriptor.isBypassed)
            // Sidechain key intent (m12-f): armed like bypass — an atomic
            // flag, never a republish; the unit (and its DSP state) survives
            // a key set/clear. The physical edge is PlaybackGraph's job; a
            // flag armed with no key delivered stays self-keyed by contract.
            unit.setUsesKey(descriptor.sidechainSourceTrackID != nil)
            next[descriptor.id] = unit
            ordered.append(unit)
        }
        units = next
        if newIdentity != oldIdentity {
            // Removed units die with the retired snapshot (≥ 1 s later).
            processor.publish(ordered.isEmpty ? nil : EffectChainSnapshot(units: ordered))
        }
        lastDescriptors = descriptors
    }

    /// Total fixed latency of the ACTIVE (non-bypassed) chain, in samples at
    /// the prepared rate — the M4 (viii) PDC hook (240 per active limiter
    /// @ 48 kHz, 0 for the other built-ins).
    var latencySamples: Int {
        lastDescriptors.reduce(0) { total, descriptor in
            guard !descriptor.isBypassed, let unit = units[descriptor.id] else { return total }
            return total + unit.instance.latencySamples
        }
    }

    /// Fixed latency of ONE live effect instance (0 when the id is unknown),
    /// regardless of bypass — it is a property of the effect; the chain sum
    /// above applies the non-bypassed rule. Feeds the per-effect
    /// `latencySamples` on the control snapshot.
    func latencySamples(forEffect id: UUID) -> Int {
        units[id]?.instance.latencySamples ?? 0
    }

    /// Current held-peak gain reduction of ONE live effect instance (m22-e),
    /// POSITIVE dB (0 = untouched, −20 dB/s release — see
    /// `GainReductionMeter`). nil = this effect doesn't measure GR (every
    /// non-dynamics kind, hosted AUs, unknown ids) so the wire OMITS the
    /// field instead of fabricating a number. A steadily BYPASSED unit reads
    /// 0 — it is applying no reduction (its frozen internal value would be a
    /// stale lie); un-bypass arms `reset()`, which also re-zeros the meter.
    /// One atomic load per call — cheap enough for every poll.
    func gainReductionDb(forEffect id: UUID) -> Double? {
        guard let unit = units[id],
              let reporting = unit.gainReducingInstance else { return nil }
        return unit.isBypassed ? 0 : Double(reporting.gainReductionDb)
    }

    /// Total fixed latency of the WHOLE chain including bypassed effects —
    /// `chainLatencyAll` from the PDC spec (§1): the stable, reported total
    /// and the input to the global stage maxima. Bypass toggles never move
    /// it (instances survive bypass); only add/remove does.
    var latencySamplesAllEffects: Int {
        lastDescriptors.reduce(0) { total, descriptor in
            total + (units[descriptor.id]?.instance.latencySamples ?? 0)
        }
    }

    /// Arms every unit's reset countdown (stop-time tail cut). `passes: 2`
    /// is the live flush-family double-arm (m15-f).
    func requestResetAll(passes: UInt32 = 1) {
        for unit in units.values {
            unit.requestReset(passes: passes)
        }
    }

    /// Drops the live unit behind one effect id so the NEXT `sync` builds a
    /// fresh instance and republishes the snapshot — the M4 (v) async-prepare
    /// hook (placeholder → real hosted AU) and its stale-config release
    /// mirror. Clearing `lastDescriptors` defeats both dedupe guards; every
    /// OTHER unit survives via the `units` map, so their DSP state is kept.
    /// No-op for unknown ids. Never touches graph topology or playback.
    func invalidateEffect(id: UUID) {
        guard units[id] != nil else { return }
        units[id] = nil
        lastDescriptors = []
    }

    // MARK: - Test seams (@testable)

    /// The live unit behind one effect id — identity assertions across chain
    /// edits compare instances.
    func unit(forEffect id: UUID) -> ChainEffectUnit? {
        units[id]
    }
}
