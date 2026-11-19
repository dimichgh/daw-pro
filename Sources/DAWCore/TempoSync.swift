import Foundation

/// m39-c — THE ONE HOME for tempo sync on the effect chain: which effect kinds
/// carry tempo-synced params, how each resolves at a tempo, and which params
/// are CONTROL-PLANE ONLY (they steer the resolve and never reach the render
/// thread). Before m39-c this knowledge was a hand-written
/// `guard effect.kind == .delay` in the resolver plus a second hand-written
/// `.delay` check in the automation lane refusal; a new synced kind meant
/// finding both. Now it is ONE entry in `effectRegistrations`.
///
/// Who reads it:
/// - the engine's descriptor intake seams (`AudioEngine.tracksDidChange`,
///   `masterEffectsChanged`, the tempo-adoption re-push `adoptDelayTempo`, and
///   `OfflineRenderer`'s session start) call `resolved(tracks:tempoBPM:)`,
///   `resolved(effects:tempoBPM:)` and `containsSynced(...)`;
/// - the automation lane refusal (`AutomationTarget.valueRange(in:)`) calls
///   `isControlPlaneOnly(kind:paramName:)`;
/// - the modulation-target refusal (`ModulationRules.validate`, for
///   `mod.addRoute`) calls `isControlPlaneOnly` to pick the `controlPlaneOnly`
///   reason and `controlPlaneOnlyDetail(kind:)` for its sentence;
/// - `DelayTempoSync` (the m22-f name) forwards here so its callers compile
///   unchanged.
///
/// The properties every registration must keep (the m22-f contract):
/// - PURE and IDEMPOTENT: the control-plane params ride along in the resolved
///   descriptor, so re-resolving an already-resolved list at a new tempo is
///   exactly the recompute.
/// - The INPUT comes back unchanged when nothing is synced (no copies on the
///   common path).
/// - Resolution runs on the control plane (main actor / the offline session
///   start). Everything downstream sees plain, final values; the render thread
///   never does a tempo lookup: it never consults the tempo map, though it may
///   read a precomputed clock (the modulation clock's `ClockSegment` values,
///   compiled on the main actor by `ModulationSnapshotBuilder`, m39-w4-4).
///
/// No other file names a tempo-synced kind by hand: `TempoSyncRegistryTests`
/// pins hand-written `.delay` + `"sync"`/`"division"` checks outside this file
/// at ZERO, so a new one turns that test red.
///
/// The second consumer is not an effect: a modulation SOURCE locked to a note
/// division. It has its own sibling table here, keyed by source kind
/// (`modulationSourceRegistrations`, m39-w4-4, design
/// `docs/design/2026-10-07-loop-drum-depth.md` §4.2). It registers the step
/// sequencer's `stepDivision` and nothing else: the LFO's `syncDivision` is
/// still REFUSED (`modulationTempoSyncUnavailable`), because a synced LFO is
/// its own item. A synced source is not RESOLVED to a rate: its division
/// reaches the snapshot builder as beats, and the render reads the musical
/// clock the main actor compiled.
public enum TempoSync {

    /// One effect kind's tempo sync: its control-plane-only params, whether a
    /// descriptor is currently synced, and the pure resolve at a tempo.
    public struct EffectRegistration: Sendable {
        /// The effect kind this entry covers. At most one entry per kind.
        public let kind: EffectDescriptor.Kind
        /// Params that only steer the resolve (e.g. `sync`, `division`). Lanes
        /// on them are refused: the render thread cannot do tempo math, so a
        /// lane would be a silent dead lane.
        public let controlPlaneParams: [String]
        /// What the resolve derives from the tempo, in words, for refusal text:
        /// "the effective <effectiveValue> derives from the tempo …". The
        /// delay's "delay time" makes its `mod.addRoute` refusal byte-identical
        /// to the sentence shipped before m39-c (pinned by
        /// `TempoSyncRegistryTests`).
        public let effectiveValue: String
        /// True when `resolve` would rewrite this descriptor.
        public let isSynced: @Sendable (EffectDescriptor) -> Bool
        /// The descriptor the render path should see at `tempoBPM`. Must return
        /// its input untouched when not synced, and must be idempotent.
        public let resolve: @Sendable (EffectDescriptor, _ tempoBPM: Double) -> EffectDescriptor

        public init(kind: EffectDescriptor.Kind,
                    controlPlaneParams: [String],
                    effectiveValue: String,
                    isSynced: @escaping @Sendable (EffectDescriptor) -> Bool,
                    resolve: @escaping @Sendable (EffectDescriptor, _ tempoBPM: Double) -> EffectDescriptor) {
            self.kind = kind
            self.controlPlaneParams = controlPlaneParams
            self.effectiveValue = effectiveValue
            self.isSynced = isSynced
            self.resolve = resolve
        }
    }

    /// m22-f: a synced delay renders `timeMs` = the division's length at the
    /// tempo, clamped to the param range (`DelayParams.effectiveTimeMs`).
    public static let delayRegistration = EffectRegistration(
        kind: .delay,
        controlPlaneParams: ["sync", "division"],
        effectiveValue: "delay time",
        isSynced: { $0.delay?.resolvedSync ?? false },
        resolve: { effect, tempoBPM in
            guard let params = effect.delay, params.resolvedSync else { return effect }
            var resolvedParams = params
            resolvedParams.timeMs = params.effectiveTimeMs(atTempoBPM: tempoBPM)
            var resolvedEffect = effect
            resolvedEffect.delay = resolvedParams
            return resolvedEffect
        })

    /// ⭐ THE REGISTRY. Adding a synced effect kind is one entry here — never a
    /// new `kind ==` check at an intake seam or in a refusal.
    public static let effectRegistrations: [EffectRegistration] = [delayRegistration]

    /// The registration for `kind`, or nil when that kind has no tempo sync.
    public static func registration(for kind: EffectDescriptor.Kind) -> EffectRegistration? {
        effectRegistrations.first { $0.kind == kind }
    }

    /// True when `paramName` on `kind` only steers the tempo resolve and must
    /// never be automated (the lane refusal reads this).
    public static func isControlPlaneOnly(kind: EffectDescriptor.Kind, paramName: String) -> Bool {
        registration(for: kind)?.controlPlaneParams.contains(paramName) ?? false
    }

    /// The sentence a `controlPlaneOnly` modulation refusal carries for `kind`
    /// (`ModulationRules.validate`). For the delay it is, byte for byte, the
    /// sentence shipped before m39-c; a kind without a registration (never
    /// refused this way) gets the general wording.
    public static func controlPlaneOnlyDetail(kind: EffectDescriptor.Kind) -> String {
        let value = registration(for: kind)?.effectiveValue ?? "value"
        return "this parameter is resolved off the render thread (the effective "
            + "\(value) derives from the tempo on the main actor), so a "
            + "modulator could not reach it. Automation refuses it too."
    }

    // MARK: - Detection

    /// True when `effect` would be rewritten by `resolved(_:tempoBPM:)`.
    public static func isSynced(_ effect: EffectDescriptor) -> Bool {
        registration(for: effect.kind)?.isSynced(effect) ?? false
    }

    /// True when any descriptor in `effects` would be rewritten.
    public static func containsSynced(effects: [EffectDescriptor]) -> Bool {
        effects.contains { isSynced($0) }
    }

    /// True when any insert on any track would be rewritten.
    public static func containsSynced(tracks: [Track]) -> Bool {
        tracks.contains { containsSynced(effects: $0.effects) }
    }

    // MARK: - Resolution (control plane only)

    /// One descriptor: a synced one gets its render values derived at
    /// `tempoBPM`; everything else passes through untouched.
    public static func resolved(_ effect: EffectDescriptor,
                                tempoBPM: Double) -> EffectDescriptor {
        guard let registration = registration(for: effect.kind),
              registration.isSynced(effect) else { return effect }
        return registration.resolve(effect, tempoBPM)
    }

    /// A whole chain — the unchanged input when nothing is synced.
    public static func resolved(effects: [EffectDescriptor],
                                tempoBPM: Double) -> [EffectDescriptor] {
        guard containsSynced(effects: effects) else { return effects }
        return effects.map { resolved($0, tempoBPM: tempoBPM) }
    }

    /// A whole track list — the unchanged input when nothing is synced.
    public static func resolved(tracks: [Track], tempoBPM: Double) -> [Track] {
        guard containsSynced(tracks: tracks) else { return tracks }
        return tracks.map { track in
            var resolvedTrack = track
            resolvedTrack.effects = resolved(effects: track.effects, tempoBPM: tempoBPM)
            return resolvedTrack
        }
    }

    // MARK: - The modulation-source sibling table (m39-w4-4)

    /// One modulation-source kind's tempo sync: the param that locks a source
    /// of this kind to a note division, and the free-running rate that the
    /// division makes inert while it is set.
    public struct ModulationSourceRegistration: Sendable {
        /// The source kind this entry covers. At most one entry per kind.
        public let kind: ModulationSourceKind
        /// The division param: one of `NoteDivision`'s raw values, or null to
        /// run free.
        public let divisionParam: String
        /// The free-running rate param, inert while a division is set.
        public let freeRateParam: String
        /// What one unit of `freeRateParam` counts, for the inert sentence.
        public let freeRateUnit: String
        /// The division `params` is locked to, or nil when it runs free (or is
        /// another kind).
        public let division: @Sendable (ModulationSourceParams) -> NoteDivision?

        public init(kind: ModulationSourceKind, divisionParam: String,
                    freeRateParam: String, freeRateUnit: String,
                    division: @escaping @Sendable (ModulationSourceParams) -> NoteDivision?) {
            self.kind = kind
            self.divisionParam = divisionParam
            self.freeRateParam = freeRateParam
            self.freeRateUnit = freeRateUnit
            self.division = division
        }
    }

    /// m39-w4-4: a step sequencer's `stepDivision` locks one step to a note
    /// division; its `rateHz` (steps per second) is inert while it is set.
    public static let stepSequencerRegistration = ModulationSourceRegistration(
        kind: .stepSequencer, divisionParam: "stepDivision",
        freeRateParam: "rateHz", freeRateUnit: "steps per second",
        division: { params in
            guard case .stepSequencer(let step) = params else { return nil }
            return step.syncedDivision
        })

    /// ⭐ THE SIBLING TABLE, keyed by modulation-source kind. The LFO is
    /// deliberately ABSENT: its `syncDivision` stays refused until a synced
    /// LFO is built and gated as its own item. Readers: the setter
    /// (`ModulationSourceParams.apply`), the publish key's synced-strip test
    /// (`ModulationSnapshotBuilder.hasSyncedSource`), `mod.describe` and
    /// `mod.describeKinds`.
    public static let modulationSourceRegistrations: [ModulationSourceRegistration] = [
        stepSequencerRegistration,
    ]

    /// The registration for a source `kind`, or nil when that kind cannot sync.
    public static func registration(forSource kind: ModulationSourceKind)
        -> ModulationSourceRegistration? {
        modulationSourceRegistrations.first { $0.kind == kind }
    }

    /// The note division `params` is locked to, or nil when it runs free.
    public static func syncedDivision(of params: ModulationSourceParams) -> NoteDivision? {
        registration(forSource: params.kind)?.division(params)
    }

    /// Every value a division param accepts, in picker order (longest first).
    public static var divisionValues: [String] { NoteDivision.allCases.map(\.rawValue) }

    /// THE ONE SENTENCE for "this source's free-running rate does nothing
    /// right now" (design §4.4). The setter's `modulationParamIgnored` warning
    /// and `mod.describe`'s `tempoSync.rateHz` are both this string, so they
    /// cannot drift apart (the W7-SMP lesson: an inert sampler release once
    /// replied plain success). nil when `params` runs free.
    public static func inertRateNote(for params: ModulationSourceParams) -> String? {
        guard let registration = registration(forSource: params.kind),
              let division = registration.division(params) else { return nil }
        return "'\(registration.freeRateParam)' is ignored while "
            + "'\(registration.divisionParam)' is set: each step lasts a "
            + "\(division.rawValue) note at the song's tempo instead of a fixed number of "
            + "\(registration.freeRateUnit). The value stays stored and takes over again if you "
            + "set '\(registration.divisionParam)' to null."
    }

    // MARK: - Shared kernels

    /// A note division as a RATE: cycles per second at a constant tempo
    /// (1/4 @ 120 = 2 Hz, 1/8d @ 120 = 2.666… Hz). The form a synced LFO
    /// would need (its free-running knob is `rateHz`); the delay uses the
    /// duration form, `NoteDivision.milliseconds(atBPM:)`. NaN for a
    /// non-finite or non-positive tempo, never a trap — callers keep their
    /// free-running value in that case, as `DelayParams.effectiveTimeMs` does.
    public static func rateHz(of division: NoteDivision, atTempoBPM bpm: Double) -> Double {
        let milliseconds = division.milliseconds(atBPM: bpm)
        guard milliseconds.isFinite, milliseconds > 0 else { return .nan }
        return 1_000.0 / milliseconds
    }
}
