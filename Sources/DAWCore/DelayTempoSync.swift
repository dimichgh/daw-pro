import Foundation

/// The m22-f name for the control-plane tempo-sync resolver, kept so the
/// existing TESTS that call it compile unchanged. Since m39-c every member is a
/// one-line forward to `TempoSync` (`Sources/DAWCore/TempoSync.swift`), the ONE
/// home that says which effect kinds are tempo-synced, how each resolves, and
/// which params are control-plane only. No production code calls this name any
/// more: the engine's intake seams and the tempo re-push call `TempoSync`
/// directly. New code calls `TempoSync` too.
///
/// ⚠️ The forwards resolve EVERY registered kind, not only `.delay`. Today the
/// registry holds the delay alone, so the two are the same; once a second kind
/// registers, `containsSyncedDelay` answers "anything synced", despite its name.
///
/// The m22-f contract, now kept by `TempoSync`: a synced delay's `timeMs` is
/// replaced by its division-derived effective time at the engine's descriptor
/// intake (`AudioEngine.tracksDidChange` / `masterEffectsChanged`, the
/// tempo-adoption re-push and the `OfflineRenderer` session start), so the
/// render thread never does a tempo lookup. IDEMPOTENT (`sync` and `division`
/// ride along), and the INPUT comes back unchanged when nothing is synced.
public enum DelayTempoSync {

    /// True when any descriptor in `effects` would be rewritten.
    public static func containsSyncedDelay(effects: [EffectDescriptor]) -> Bool {
        TempoSync.containsSynced(effects: effects)
    }

    /// True when any insert on any track would be rewritten.
    public static func containsSyncedDelay(tracks: [Track]) -> Bool {
        TempoSync.containsSynced(tracks: tracks)
    }

    /// One descriptor: a synced one is resolved at `tempoBPM`; everything else
    /// passes through untouched.
    public static func resolved(_ effect: EffectDescriptor,
                                tempoBPM: Double) -> EffectDescriptor {
        TempoSync.resolved(effect, tempoBPM: tempoBPM)
    }

    /// A whole chain — unchanged input when nothing is synced.
    public static func resolved(effects: [EffectDescriptor],
                                tempoBPM: Double) -> [EffectDescriptor] {
        TempoSync.resolved(effects: effects, tempoBPM: tempoBPM)
    }

    /// A whole track list — unchanged input when nothing is synced.
    public static func resolved(tracks: [Track], tempoBPM: Double) -> [Track] {
        TempoSync.resolved(tracks: tracks, tempoBPM: tempoBPM)
    }
}
