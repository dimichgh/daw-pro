/// WHY a (re)schedule is happening — THE discriminator for note chase (m23-bp,
/// docs/research/design-m23bp-note-chase.md §2; amended by m23-cd).
///
/// `.continuation`: `fromBeat` is the position playback would have reached
/// anyway (`derivedBeats()` or a captured resume tuple). Playback was never
/// stopped from the user's point of view, so a held note going permanently
/// silent is a defect, not a policy.
/// `.transportStart`: the user pressed PLAY (m23-cd). The beat WAS chosen — so
/// this is not a continuation and the start still anchors
/// `.asSoonAsPractical` — but it chases anyway, because "resume where I
/// paused and hear what was sounding" is what Logic/Ableton/Cubase do and is
/// what the user ruled for on 2026-08-04. THE ACCEPTED COST, stated not
/// implied: a note that was already decaying when the transport stopped
/// re-attacks at full velocity on the next play. That counter-case was put to
/// the user before they ruled; it is a cost, not a defect.
/// `.relocation`: the beat was CHOSEN **and** the build must reproduce a fresh
/// seek — a seek while rolling, a record start, a loop-wrap jump, a bounce
/// range. The v0 no-chase rule stands.
///
/// ⚠️ CHASE AND ANCHOR POLICY ARE INDEPENDENT AXES (ARCHITECTURE.md, m23-bs-3b
/// note): "who chose the beat?" decides `StartAnchorPolicy`, "does this build
/// chase?" decides this. They correlated at every m23-bp site by coincidence;
/// `.transportStart` is the chase-yes-with-a-chosen-beat case that ARCHITECTURE
/// anticipated, and it is a THIRD CASE precisely so `.continuation` keeps
/// meaning "wall time chose the beat" for the anchor-policy table.
///
/// The enum (rather than a bare `Bool`) exists so the mapping has ONE home and
/// so a future user-facing "chase MIDI notes on locate" preference has a place
/// to land; it is threaded WITHOUT A DEFAULT through `AudioEngine.restart` /
/// `AudioEngine.startPlayers`, so the compiler — not a comment — enumerates
/// every reschedule site in the tree.
/// `CaseIterable` is carried FOR THE SITE PIN, not for production: the m23-bp
/// cause-sequence scan matches a hard-coded token list, and a case missing from
/// that list reads as "this site does not exist" rather than as a failure.
/// `NoteChaseSiteTests` asserts the list covers `allCases`, so a fourth case
/// reddens the pin instead of hiding a site from it (m23-cd).
enum RescheduleCause: CaseIterable {
    case relocation
    case continuation
    case transportStart

    /// THE mapping. It exists exactly once in the tree (read only by
    /// `PlaybackGraph.scheduleAll`); every consumer reads this property rather
    /// than switching on the case itself.
    ///
    /// An EXHAUSTIVE switch, not `self != .relocation`: a fourth cause must not
    /// be able to inherit a chase answer by saying nothing — the same reason
    /// `cause` itself carries no default.
    var chasesHeldNotes: Bool {
        switch self {
        case .relocation: return false
        case .continuation, .transportStart: return true
        }
    }
}
