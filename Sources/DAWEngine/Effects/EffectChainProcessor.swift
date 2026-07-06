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
/// replay. v0 accepts the bypass-toggle click (hard swap); a short crossfade
/// ramp is an additive later change inside the walk.
final class ChainEffectUnit: @unchecked Sendable {
    let id: UUID
    let kind: EffectDescriptor.Kind
    let instance: any EffectRendering
    /// 1 = skip this unit in the walk. Heap-allocated for a stable address.
    let bypassFlag: UnsafeMutablePointer<daw_atomic_u32>
    /// 1 = call `instance.reset()` at the top of the next walk.
    let resetFlag: UnsafeMutablePointer<daw_atomic_u32>

    init(id: UUID, kind: EffectDescriptor.Kind,
         instance: any EffectRendering, isBypassed: Bool) {
        self.id = id
        self.kind = kind
        self.instance = instance
        bypassFlag = .allocate(capacity: 1)
        daw_atomic_u32_store(bypassFlag, isBypassed ? 1 : 0)
        resetFlag = .allocate(capacity: 1)
        daw_atomic_u32_store(resetFlag, 0)
    }

    deinit {
        bypassFlag.deallocate()
        resetFlag.deallocate()
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

    @MainActor
    func requestReset() {
        daw_atomic_u32_store(resetFlag, 1)
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

    /// Arms every unit's reset flag — the stop-time tail-cut contract
    /// (`stopAllPlayers`), matching the v0-honest instrument flush.
    @MainActor
    func requestResetAll() {
        guard let snapshot = currentSnapshot else { return }
        for unit in snapshot.units {
            unit.requestReset()
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
    /// flag, skip if bypassed, else process. No-op when nothing is published.
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard let raw = daw_atomic_ptr_load(slot) else { return }
        let snapshot = Unmanaged<EffectChainSnapshot>.fromOpaque(raw).takeUnretainedValue()
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        snapshot.units.withUnsafeBufferPointer { units in
            for index in 0..<units.count {
                let unit = units[index]
                if daw_atomic_u32_exchange(unit.resetFlag, 0) == 1 {
                    unit.instance.reset()
                }
                if daw_atomic_u32_load(unit.bypassFlag) == 1 { continue }
                unit.instance.process(buffers: buffers, frameCount: frameCount)
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
            }
            // Params + bypass land in place on every pass (both dedupe).
            EffectFactory.applyParams(descriptor, to: unit.instance)
            unit.setBypassed(descriptor.isBypassed)
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

    /// Total fixed latency of the WHOLE chain including bypassed effects —
    /// `chainLatencyAll` from the PDC spec (§1): the stable, reported total
    /// and the input to the global stage maxima. Bypass toggles never move
    /// it (instances survive bypass); only add/remove does.
    var latencySamplesAllEffects: Int {
        lastDescriptors.reduce(0) { total, descriptor in
            total + (units[descriptor.id]?.instance.latencySamples ?? 0)
        }
    }

    /// Arms every unit's reset flag (stop-time tail cut).
    func requestResetAll() {
        for unit in units.values {
            unit.requestReset()
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
