import Foundation
import DAWCore

/// Classifies a journaled `ProjectStore.EditEvent` into the onboarding tour signal
/// it should emit (M8 ob-b; design in docs/research/design-onboarding.md §3–4).
///
/// The tour has TWO edit-driven steps that must never collapse into each other:
/// `shape` (`editPerformed` — "make one edit", deliberately broad) and `mix`
/// (`mixerAdjusted` — "slide a fader or drop a preset"). The onboarding doc's
/// warning is explicit: if the app watched the journal globally, a fader move would
/// fire `editPerformed` too and the two steps would collapse. So the app-side
/// signal adapter routes EVERY journaled edit through this pure function, which
/// splits them apart on the edit's own structural fields.
///
/// **The rule** (prefer the coalescing KEY where present, the LABEL only where the
/// key is nil — the key is the most structural field a ProjectStore edit carries):
///
/// - `mixerAdjusted` — the level/pan/preset family the `mix` step listens for:
///   - key `"mixer.master"` (`setMasterVolume`),
///   - key prefixed `"track.volume:"` (`setTrackVolume` — the fader),
///   - key prefixed `"track.pan:"` (`setTrackPan` — the pan knob),
///   - key-less label prefixed `"Apply Preset"` (`applyMixerPreset` — the macro
///     carries no coalescing key).
/// - `editPerformed` — EVERYTHING else journaled (clip moves/trims/splits, mutes,
///   tempo nudges, sends, routing, note edits, quantize, humanize, …). A mute is
///   deliberately here, not in the mixer family: the `shape` step invites "mute a
///   track to drop it out", so a mute must reach `shape`, never `mix`.
///
/// The constants below MIRROR `ProjectStore`'s edit label/key conventions
/// (ProjectStore.swift `setMasterVolume`/`setTrackVolume`/`setTrackPan`,
/// MixerPresets.swift `applyMixerPreset`); a drift there is caught by these tests
/// plus the app-adapter tests. Pure + headless (the `ClipStretch` idiom), so the
/// taxonomy is proven without a running app.
public enum OnboardingEditClassifier {
    /// The master-volume edit's coalescing key.
    static let masterVolumeKey = "mixer.master"
    /// The track-fader edit's coalescing-key prefix (per-track uuid follows).
    static let trackVolumeKeyPrefix = "track.volume:"
    /// The track-pan edit's coalescing-key prefix (per-track uuid follows).
    static let trackPanKeyPrefix = "track.pan:"
    /// The mixer-preset macro's undo-label prefix (it carries NO coalescing key).
    static let mixerPresetLabelPrefix = "Apply Preset"

    /// The tour signal a journaled edit should emit: `.mixerAdjusted` for the
    /// level/pan/preset family, `.editPerformed` for everything else.
    public static func signal(for event: EditEvent) -> OnboardingSignal {
        isMixerAdjustment(event) ? .mixerAdjusted : .editPerformed
    }

    /// True when the edit is a level/pan/preset move (the `mix`-step family).
    /// Classifies on the coalescing key where present (the most structural field),
    /// falling back to the undo label only for the key-less mixer-preset macro.
    public static func isMixerAdjustment(_ event: EditEvent) -> Bool {
        if let key = event.key {
            return key == masterVolumeKey
                || key.hasPrefix(trackVolumeKeyPrefix)
                || key.hasPrefix(trackPanKeyPrefix)
        }
        return event.label.hasPrefix(mixerPresetLabelPrefix)
    }
}
