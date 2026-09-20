import CAtomics
import DAWCore
import Foundation

/// One strip's modulation graph, resolved on the main actor and published to
/// the render thread as an immutable POD (m39-e §3.4).
///
/// Storage discipline is `MIDIEventSchedule`'s, verbatim: every array lives in
/// memory this object allocates in `init` and frees in `deinit`, so the render
/// thread never touches Swift `Array` machinery. Publication is
/// `AutomationSchedule`'s, verbatim: a heap `daw_atomic_ptr` slot holding a +1
/// retain, `takeUnretainedValue` on the render thread, and a main-actor retire
/// bin that keeps a displaced snapshot alive ≥ 1 s so a quantum still
/// borrowing the old pointer can never touch freed memory.
///
/// ⛔⛔ **THIS SNAPSHOT IS DELIBERATELY NOT UNPUBLISHED BY
/// `stopAllPlayers()`, AND THAT ASYMMETRY WITH `AutomationSchedule` IS THE
/// POINT (§7.8).** It is published by `applyParameters` and LIVES ACROSS STOP.
/// Its position-dependent sources (`lfo`, `stepSequencer`) return NEUTRAL
/// while stopped — there is no transport position to be a function of — while
/// `macro` and `envelopeFollower` keep working, because one is a control and
/// the other follows audio, and audio exists while monitoring a stopped
/// transport. Tidying this into symmetry would silently kill stopped-transport
/// macros, which is exactly the workflow an agent uses to dial a sound in
/// before pressing play.
///
/// ⚠️ **`originSample` exists because the schedule anchor is NOT project
/// zero.** `AutomationSchedule`'s `t = 0` is "the transport beat the schedule
/// was built from", so the render-side position `p` is *roll-relative*. Every
/// source here is a function of the PROJECT-ABSOLUTE position
/// `originSample + p`, or an LFO would restart its phase at every play press
/// and the position-absolute determinism law (§3.2) would be false in exactly
/// the case it exists to guarantee.
final class ModulationSnapshot {
    /// Target classes, resolved on the main actor so the render thread never
    /// switches on an enum with associated values.
    enum TargetCode {
        static let volume: Int32 = 0
        static let pan: Int32 = 1
        static let effectParam: Int32 = 2
        static let instrumentParam: Int32 = 3
    }

    /// Source kinds, likewise.
    enum SourceCode {
        static let lfo: Int32 = 0
        static let stepSequencer: Int32 = 1
        static let envelopeFollower: Int32 = 2
        static let macro: Int32 = 3
    }

    /// One source, fully resolved: every rate is already in samples and every
    /// string is already a code. POD — no references, no ARC.
    struct Source {
        var kindCode: Int32 = 0
        var waveformCode: Int32 = 0
        /// LFO phase increment per sample (`rateHz / sampleRate`).
        var cyclesPerSample: Double = 0
        /// LFO phase at project sample 0, in `[0, 1)`.
        var phaseOffset: Double = 0
        var pulseWidth: Double = 0.5
        /// Raised-cosine edge width as a fraction of one cycle (LFO) or one
        /// step (sequencer).
        var edgeFraction: Double = 0
        var samplesPerStep: Double = 0
        var stepOffset: Int32 = 0
        var stepCount: Int32 = 0
        var seed: UInt32 = 0
        /// `false` maps the bipolar output to `[0, 1]`.
        var bipolar: Bool = true
        /// Index into the macro atomic bank, or -1.
        var macroSlot: Int32 = -1
        // Envelope follower — the ONE stateful source (§3.2's declared exception).
        var attackCoefficient: Float = 0
        var releaseCoefficient: Float = 0
        var floorDb: Double = -60
        var detectorGainLinear: Double = 1
        var detectorIsPeak: Bool = false
    }

    /// One route: a source index and a depth. Grouped by target, so the
    /// summation order is the published array order — Float addition is not
    /// associative and an unspecified order would make a render
    /// non-reproducible (§7.3, pinned by test).
    struct Route {
        var sourceIndex: Int32 = 0
        var depth: Double = 0
    }

    /// One modulated target with its resolved domain and its route run.
    struct Target {
        var kindCode: Int32 = 0
        var effectID: UUID = UUID()
        /// Effect-param slot, or `InstrumentParamID.code`.
        var paramSlot: Int32 = 0
        var rangeLo: Double = 0
        var rangeHi: Double = 1
        /// `ParamCurve` as a code: 0 linear, 1 logarithmic, 2 decibel.
        var curveCode: Int32 = 0
        /// The knob value the depth law offsets when nothing else is in
        /// control (§7.3's `base`). A lane, when one is active, overrides it.
        var baseValue: Double = 0
        var routeOffset: Int32 = 0
        var routeCount: Int32 = 0
    }

    let generation: UInt64
    /// Identical meaning to `AutomationSchedule.timelineID`: schedules sharing
    /// a timeline share one anchor, so a mid-playback route edit RE-SEEKS
    /// rather than restarting.
    let timelineID: UInt64
    let sampleRate: Double
    /// Project-absolute sample position of the schedule anchor. See the type doc.
    let originSample: Int64
    /// False while the transport is stopped: position-dependent sources hold
    /// neutral, live sources keep working (§7.8).
    let positionValid: Bool

    let sources: UnsafeBufferPointer<Source>
    let routes: UnsafeBufferPointer<Route>
    let targets: UnsafeBufferPointer<Target>
    /// Flattened step-sequencer values; each source carries its own offset and
    /// count into this one pool.
    let steps: UnsafeBufferPointer<Float>

    /// Indices into `targets`, or -1 — the render path's O(1) answer to "does
    /// anything take this strip's fader over?", so the null path costs one
    /// integer compare.
    let volumeTargetIndex: Int32
    let panTargetIndex: Int32
    let hasInstrumentTargets: Bool
    let hasEffectTargets: Bool
    /// Whether any source needs the per-sample detector to run at all.
    let hasFollower: Bool

    /// 16 preallocated macro slots, Float bit patterns (§7.2). `mod.setMacro`
    /// is ONE atomic store into this array and touches nothing else — no
    /// republish, no reallocation, no retire-bin churn.
    private let macroValues: UnsafeMutablePointer<daw_atomic_u32>

    /// Envelope-follower detector LEVELS, one per source slot — the ONE HOME
    /// every consumer reads: the fader stage, `storeEffectParams`, and the
    /// instrument. Written each quantum by the strip's `ModulationStage`,
    /// which owns the smoothing STATE (this is the level it produces, not the
    /// integrator).
    ///
    /// ⚠️ A consumer that runs BEFORE the stage in a quantum — the instrument
    /// (P1) and the pre-walk effect-param store (P3) — reads the level the
    /// PREVIOUS quantum produced. That is the follower's declared
    /// history-dependence (§3.2's one exception), not a bug, and it costs one
    /// block of latency. On a republish these start at zero for exactly one
    /// quantum before the stage writes them again; the stage's integrator
    /// survives the republish, so the level RESTORES rather than re-attacking.
    let followerLevels: UnsafeMutablePointer<Float>

    init(generation: UInt64, timelineID: UInt64, sampleRate: Double,
         originSample: Int64, positionValid: Bool,
         sources: [Source], routes: [Route], targets: [Target], steps: [Float],
         macroValues macros: [Float]) {
        self.generation = generation
        self.timelineID = timelineID
        self.sampleRate = sampleRate
        self.originSample = originSample
        self.positionValid = positionValid
        self.sources = Self.own(sources)
        self.routes = Self.own(routes)
        self.targets = Self.own(targets)
        self.steps = Self.own(steps)
        var volumeIndex: Int32 = -1
        var panIndex: Int32 = -1
        var instrument = false
        var effect = false
        for (index, target) in targets.enumerated() {
            switch target.kindCode {
            case TargetCode.volume: volumeIndex = Int32(index)
            case TargetCode.pan: panIndex = Int32(index)
            case TargetCode.instrumentParam: instrument = true
            default: effect = true
            }
        }
        self.volumeTargetIndex = volumeIndex
        self.panTargetIndex = panIndex
        self.hasInstrumentTargets = instrument
        self.hasEffectTargets = effect
        self.hasFollower = sources.contains { $0.kindCode == SourceCode.envelopeFollower }
        followerLevels = .allocate(capacity: ModulationLimits.maxSources)
        followerLevels.initialize(repeating: 0, count: ModulationLimits.maxSources)
        macroValues = .allocate(capacity: ModulationLimits.maxMacros)
        for slot in 0..<ModulationLimits.maxMacros {
            let value = slot < macros.count ? macros[slot] : 0
            daw_atomic_u32_store(macroValues.advanced(by: slot), value.bitPattern)
        }
    }

    deinit {
        if sources.baseAddress != nil { UnsafeMutableBufferPointer(mutating: sources).deallocate() }
        if routes.baseAddress != nil { UnsafeMutableBufferPointer(mutating: routes).deallocate() }
        if targets.baseAddress != nil { UnsafeMutableBufferPointer(mutating: targets).deallocate() }
        if steps.baseAddress != nil { UnsafeMutableBufferPointer(mutating: steps).deallocate() }
        macroValues.deallocate()
        followerLevels.deinitialize(count: ModulationLimits.maxSources)
        followerLevels.deallocate()
    }

    private static func own<Element>(_ elements: [Element]) -> UnsafeBufferPointer<Element> {
        guard !elements.isEmpty else { return UnsafeBufferPointer(start: nil, count: 0) }
        let storage = UnsafeMutableBufferPointer<Element>.allocate(capacity: elements.count)
        _ = storage.initialize(from: elements)
        return UnsafeBufferPointer(storage)
    }

    /// `mod.setMacro`'s delivery: ONE atomic store (§7.2). Main actor.
    func storeMacro(slot: Int, value: Float) {
        guard slot >= 0, slot < ModulationLimits.maxMacros else { return }
        daw_atomic_u32_store(macroValues.advanced(by: slot), value.bitPattern)
    }

    /// Render thread: one acquire load plus a bit-cast. No branch on kind
    /// beyond the slot bound.
    @inline(__always)
    func macroValue(slot: Int32) -> Double {
        guard slot >= 0, slot < Int32(ModulationLimits.maxMacros) else { return 0 }
        return Double(Float(bitPattern: daw_atomic_u32_load(macroValues.advanced(by: Int(slot)))))
    }

    /// Whether this snapshot addresses anything at all. The render path's
    /// first question, and a `false` here is what keeps an unmodulated
    /// project's render byte-identical: nothing downstream of this test runs.
    var isEmpty: Bool { targets.count == 0 }
}
