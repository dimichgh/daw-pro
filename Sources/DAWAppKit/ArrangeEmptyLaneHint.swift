import Foundation
import DAWCore

/// The ONE home for "does this arrange lane look inert, and what does it say
/// about it" (m23-v) — the empty-instrument-lane hint.
///
/// m23-e shipped the empty-lane double-click: a fresh instrument track now
/// reaches a writable note grid in one gesture. What it could not ship is the
/// word the user's report actually used — AFFORDANCE. A double-click is
/// invisible, so a brand-new track still presented an empty lane that promised
/// nothing. This is the promise, and it lives here rather than in the view so
/// the rule and the words are unit-testable: `DAWApp` has no test target, so a
/// predicate composed inside a SwiftUI `body` is invisible to everything under
/// `Tests/`.
///
/// **ALWAYS while the lane is empty — deliberately NOT hover-gated.** The
/// roadmap offered both. The filed complaint is "an empty lane that promises
/// nothing", which is a LOOKING failure, not a hovering one: a hint you must
/// already be pointing at is only marginally more discoverable than the
/// double-click it advertises, and it would be invisible to exactly the user who
/// filed this. That is also why this is not routed through the m17-c pointer
/// seam (`onPointerState`), which reports null in precisely the resting state
/// the hint exists for — it gets its own report path, keyed on lane CONTENT.
///
/// **Content-keyed only, and that is the whole rule.** It does not consult the
/// transport: a track added while the transport is rolling or recording still
/// has no clips and still looks inert, so it still gets the hint. The input here
/// is `[Track]` and nothing else, which makes that property structural rather
/// than a promise — there is no transport in scope to accidentally read.
///
/// **Never on audio or bus lanes.** That is where the double-click legitimately
/// refuses with `midiClipsRequireInstrumentTrack`, and advertising an action that
/// will refuse is worse than silence. Eligibility is `Track.canHoldMIDIClips`,
/// the store's OWN guard (DAWCore) — never a local `kind == .instrument`, and
/// never `canExportMIDI`, which is a coincidentally-identical expression for a
/// different question (see that property's note).

/// One lane's hint: which track it belongs to, where that track sits in the
/// ladder, and the exact words to draw.
///
/// The initializer is `fileprivate`, so the ONLY way to obtain one is
/// `ArrangeEmptyLaneHints.hints(for:)` — the `ResolvedDropBeat` pattern, which
/// is what makes "the drawn hint and the reported hint are one value" a
/// compile-time property instead of a convention. A view cannot mint a hint to
/// report that it never drew, and cannot draw one it never reported.
public struct ArrangeEmptyLaneHint: Sendable, Equatable, Identifiable, Hashable {
    /// The track whose lane this hint sits on.
    public let trackID: UUID
    /// That track's position in the `tracks` array the hints were built from —
    /// i.e. its lane index in the arrange ladder. Carried so the drawing view
    /// resolves `laneTop(index)` from the reported value itself rather than
    /// looking the track up a second time, and so a gate can name the band it
    /// expects the hint in.
    public let laneIndex: Int
    /// The words drawn on the lane. Carried per-hint rather than read from the
    /// static constant at draw time so the debug echo reports what is on screen,
    /// not what the catalogue says should be.
    public let text: String

    public var id: UUID { trackID }

    fileprivate init(trackID: UUID, laneIndex: Int, text: String) {
        self.trackID = trackID
        self.laneIndex = laneIndex
        self.text = text
    }
}

public enum ArrangeEmptyLaneHints {
    /// The hint's words.
    ///
    /// Beginner-readable and literal about the gesture — the roadmap's own
    /// example wording, and "clip" is the noun the whole app already uses for a
    /// block on the timeline (the `.clipBlock` Explain card is titled "Clip").
    /// Deliberately a bare invitation with no exclamation, no arrow and no verb
    /// chrome: this string sits on EVERY empty instrument lane at once, so a
    /// project with four fresh tracks shows it four times, and anything that
    /// reads as a call to action becomes noise at that multiplicity.
    public static let copy = "Double-click to add a clip"

    /// The hint for one track, or nil when that lane must stay silent.
    ///
    /// TWO conditions, both required:
    ///   * `canHoldMIDIClips` — the store's own guard. An audio or bus lane
    ///     refuses the double-click, so it is never offered one.
    ///   * `clips.isEmpty` — ANY clip ANYWHERE on the lane counts, not "no clip
    ///     in the visible window". That is the honest reading of "this track has
    ///     content": a lane scrolled away from its only clip is a scroll problem,
    ///     not an empty-state one, and a hint that blinked in and out as you
    ///     scrolled would be worse than none.
    public static func hint(for track: Track, laneIndex: Int) -> ArrangeEmptyLaneHint? {
        guard track.canHoldMIDIClips, track.clips.isEmpty else { return nil }
        return ArrangeEmptyLaneHint(trackID: track.id, laneIndex: laneIndex, text: copy)
    }

    /// Every lane's hint, in ladder order — the ONE value the arrange lanes both
    /// DRAW and REPORT (see `ArrangeEmptyLaneHint`).
    public static func hints(for tracks: [Track]) -> [ArrangeEmptyLaneHint] {
        tracks.enumerated().compactMap { hint(for: $0.element, laneIndex: $0.offset) }
    }
}
