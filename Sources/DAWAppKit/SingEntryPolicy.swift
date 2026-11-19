import DAWCore

/// Should a door to the Sing sheet be offered for this clip? (p2-sing-pr-words-f2)
///
/// ONE home for the question both doors ask: the arrange's clip menu and the
/// piano roll's SING chip. The answer is the planner's own two refusals that a
/// door can see ahead of time, so a door never opens a sheet that then refuses:
///
/// - an audio clip (`SingPlanner.plan` throws `.audioClip`);
/// - a drum track (`.drumTrack`), asked through `ProjectTranspose.isDrumTrack`,
///   the predicate the planner itself checks (`SingPlanner.swift`, "The tree's
///   one drum-track rule").
///
/// ⚠️ NOT `SMFProjectExporter.isDrumKit`. That is the General MIDI export
/// question (does this track go on channel 10?), and it answers "no" for our
/// drum machine in its `pads` note layout, which the planner still refuses.
/// Asking it here is how the roll's chip came to open a sheet that refused
/// (design `docs/design/2026-10-12-piano-roll-words.md` §1.9 F2).
///
/// The other refusals (no notes, no words, too many words, a note too long)
/// depend on what the user is about to type in the sheet, so the sheet says
/// them in words; a door does not hide for them.
public enum SingEntryPolicy {

    /// True when `clip`, which lives on `track`, can be offered to the singer.
    public static func offersSing(clip: Clip, on track: Track) -> Bool {
        clip.isMIDI && !ProjectTranspose.isDrumTrack(track)
    }
}
