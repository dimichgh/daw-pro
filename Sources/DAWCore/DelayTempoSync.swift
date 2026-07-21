import Foundation

/// The m22-f control-plane resolver for tempo-synced delays: substitutes a
/// synced delay descriptor's `timeMs` with its division-derived effective
/// time so everything DOWNSTREAM of the engine intake seams — the render
/// thread, the offline bounce, engine rebuilds — sees a plain, final
/// `timeMs` and never does a tempo lookup.
///
/// Applied at the ENGINE's descriptor intake (`AudioEngine.tracksDidChange`
/// / `masterEffectsChanged`, plus the tempo-adoption re-push and the
/// `OfflineRenderer` session start). IDEMPOTENT by construction: `sync` and
/// `division` ride along in the substituted descriptor and re-deriving needs
/// only those plus the tempo, so re-resolving an already-resolved list at a
/// new tempo is exactly the recompute (the stored `timeMs` matters only
/// while `sync` is off, and then it is never touched).
///
/// Pure and allocation-honest: when nothing is synced the INPUT collections
/// are returned unchanged (no copies on the overwhelmingly common path).
public enum DelayTempoSync {

    /// True when any descriptor in `effects` would be rewritten.
    public static func containsSyncedDelay(effects: [EffectDescriptor]) -> Bool {
        effects.contains { $0.kind == .delay && ($0.delay?.resolvedSync ?? false) }
    }

    /// True when any insert on any track would be rewritten.
    public static func containsSyncedDelay(tracks: [Track]) -> Bool {
        tracks.contains { containsSyncedDelay(effects: $0.effects) }
    }

    /// One descriptor: a synced delay gets `timeMs` replaced by
    /// `effectiveTimeMs(atTempoBPM:)` (already clamped to the param range);
    /// everything else passes through untouched.
    public static func resolved(_ effect: EffectDescriptor,
                                tempoBPM: Double) -> EffectDescriptor {
        guard effect.kind == .delay, let params = effect.delay,
              params.resolvedSync else { return effect }
        var resolvedParams = params
        resolvedParams.timeMs = params.effectiveTimeMs(atTempoBPM: tempoBPM)
        var resolvedEffect = effect
        resolvedEffect.delay = resolvedParams
        return resolvedEffect
    }

    /// A whole chain — unchanged input when nothing is synced.
    public static func resolved(effects: [EffectDescriptor],
                                tempoBPM: Double) -> [EffectDescriptor] {
        guard containsSyncedDelay(effects: effects) else { return effects }
        return effects.map { resolved($0, tempoBPM: tempoBPM) }
    }

    /// A whole track list — unchanged input when nothing is synced.
    public static func resolved(tracks: [Track], tempoBPM: Double) -> [Track] {
        guard containsSyncedDelay(tracks: tracks) else { return tracks }
        return tracks.map { track in
            var resolvedTrack = track
            resolvedTrack.effects = resolved(effects: track.effects, tempoBPM: tempoBPM)
            return resolvedTrack
        }
    }
}
