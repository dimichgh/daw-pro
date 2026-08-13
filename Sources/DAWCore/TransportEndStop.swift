import Foundation

/// End-of-content transport stop (m25-d) — "when playback reaches the point
/// past which there are no more clips, stop".
///
/// Pure domain: no UI, no engine, no AVFoundation. Both the store's engine
/// arming path and the headless position ticker call THESE functions, so the
/// policy exists once and cannot drift between the two transports.
///
/// **Why a `Double?` bound and not an `isArmed` flag.** The whole decision
/// ("should the transport stop, and where") collapses into one optional
/// scalar: `nil` means *never stop on this run*, non-nil is the linear beat to
/// stop at. One piece of state, evaluated by one predicate, pushed to the
/// engine as a plain pre-computed value the playhead tick compares against —
/// the tick never calls back into `ProjectStore`, never allocates, and never
/// walks the track list.
public enum TransportEndStop {

    /// TRUE end of content on the timeline, in beats: the largest
    /// `startBeat + lengthBeats` over every clip on every track, or 0 for a
    /// project with no clips.
    ///
    /// **This is the RENDER extent, not the DISPLAY extent.** The two
    /// pre-existing computations of "project end"
    /// (`TimelineLanesView.totalBeats`, `MixerStripView.spanBeats`) each add
    /// their own padding/floor on top of the same max — a display heuristic,
    /// explicitly not a snap path. Views keep that padding; this value has
    /// none.
    ///
    /// **Why no trim/stretch arithmetic.** `Clip.lengthBeats` IS the timeline
    /// authority (see its doc comment). `startOffsetSeconds` is an offset
    /// *into the source*, and `stretchRatio` sizes the *source window
    /// consumed* — both are derived from, and never change, the beat span the
    /// clip occupies on the timeline. So `startBeat + lengthBeats` already
    /// accounts for trims and stretch; adding a factor here would double-count.
    ///
    /// **What is deliberately NOT content.** MIDI notes past their clip's end
    /// (legal-but-latent "shaded" data, engine-windowed by strict `<`, m18-f /
    /// m19-g) never sound, so they never extend the end. Automation
    /// breakpoints and markers are not sound-producing either. Clips on MUTED
    /// tracks DO count: a mute is a monitoring decision, and letting it move
    /// the stop point would make the transport's behaviour jump around as you
    /// toggle mutes mid-mix.
    public static func contentEndBeat(tracks: [Track]) -> Double {
        var end = 0.0
        for track in tracks {
            for clip in track.clips {
                let clipEnd = clip.startBeat + clip.lengthBeats
                // NaN-safe: a NaN never satisfies `>`, so a corrupt clip is
                // skipped rather than poisoning the max into NaN (a NaN bound
                // compares false against everything and would silently disable
                // the feature for the whole session).
                if clipEnd > end { end = clipEnd }
            }
        }
        return end
    }

    /// The linear stop bound for the run that is about to start (or is
    /// running), or `nil` for "do not stop at content end on this run".
    ///
    /// Every caller — `ProjectStore.play()`, `seek`, `setLoop`,
    /// `setStopAtContentEnd`, and the headless ticker — evaluates THIS
    /// function; the store never re-derives the policy inline.
    ///
    /// The five reasons this returns `nil`, in order:
    ///  1. `isEnabled == false` — the user turned the preference off, so the
    ///     transport free-runs past the last clip (what Logic and Live do).
    ///  2. `isRecording == true` — ⚠️ **RECORDING MUST NEVER STOP AT CONTENT
    ///     END.** Recording past the end of existing material is the entire
    ///     point of recording; stopping there would be actively destructive.
    ///     This is one of two guards (the engine tick carries a structural
    ///     `activeTake == nil` guard as well), so deleting either one alone
    ///     still leaves the take safe.
    ///  3. `isLoopActive == true` — LOOPING TAKES PRECEDENCE. A cycling
    ///     transport is meant to run forever; the loop window's own wrap owns
    ///     the bound. "Active" means an EFFECTIVE window (enabled AND
    ///     `end > start`), matching the engine's own wrap condition exactly —
    ///     a degenerate enabled-but-empty window loops nothing, so the end
    ///     stop should still apply.
    ///  4. `contentEndBeat <= 0` — an empty project has no end to reach.
    ///     Without this an empty session would satisfy `position >= end` at
    ///     beat 0 and stop the instant you pressed play.
    ///  5. `positionBeats >= contentEndBeat` — playback is STARTING at or past
    ///     the end, which is deliberate free-run into empty space (and is
    ///     exactly the state an end stop leaves the playhead in). Arming here
    ///     would make the play button look dead: press play, transport stops
    ///     immediately, nothing appears to happen. Strict `<` means the second
    ///     press free-runs instead — a running transport in silence is a
    ///     better failure than a button that does nothing.
    public static func bound(contentEndBeat: Double,
                             positionBeats: Double,
                             isEnabled: Bool,
                             isRecording: Bool,
                             isLoopActive: Bool) -> Double? {
        guard isEnabled, !isRecording, !isLoopActive else { return nil }
        guard contentEndBeat > 0, contentEndBeat.isFinite else { return nil }
        guard positionBeats < contentEndBeat else { return nil }
        return contentEndBeat
    }

    /// Whether a transport's loop window is EFFECTIVE — the exact condition
    /// the engine's own linear wrap uses (`AudioEngine.startPlayheadTask`), so
    /// "looping takes precedence" is the same predicate on both sides.
    public static func isLoopActive(_ transport: TransportState) -> Bool {
        transport.isLoopEnabled && transport.loopEndBeat > transport.loopStartBeat
    }
}
