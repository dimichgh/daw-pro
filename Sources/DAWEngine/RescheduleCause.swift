/// WHY a (re)schedule is happening — THE discriminator for note chase (m23-bp,
/// docs/research/design-m23bp-note-chase.md §2).
///
/// `.continuation`: `fromBeat` is the position playback would have reached
/// anyway (`derivedBeats()` or a captured resume tuple). Playback was never
/// stopped from the user's point of view, so a held note going permanently
/// silent is a defect, not a policy.
/// `.relocation`: the beat was CHOSEN — a transport start, a seek, a record
/// start, a loop-wrap jump, a bounce range. The v0 no-chase rule stands.
///
/// The enum (rather than a bare `Bool`) exists so the mapping has ONE home and
/// so a future user-facing "chase MIDI notes on locate" preference has a place
/// to land; it is threaded WITHOUT A DEFAULT through `AudioEngine.restart` /
/// `AudioEngine.startPlayers`, so the compiler — not a comment — enumerates
/// every reschedule site in the tree.
enum RescheduleCause {
    case relocation
    case continuation

    /// THE mapping. It exists exactly once in the tree (read only by
    /// `PlaybackGraph.scheduleAll`); every consumer reads this property rather
    /// than switching on the case itself.
    var chasesHeldNotes: Bool { self == .continuation }
}
