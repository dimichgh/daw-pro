import CoreGraphics

/// Pure width-budget decisions for the arrange track-header row (beta m10-i
/// round 2). The sidebar is user-resizable across the m10-d range (250–420 pt),
/// and at the narrow end a fully-loaded row (icon + name + level bar + clip badge
/// + disclosures + M/S/R) can't show every optional chip without either squeezing
/// the NAME to nothing or inflating the window's minimum width off-screen. This
/// namespace owns the "what folds away first" rule so the SwiftUI row stays thin
/// and the budget unit-tests headless (the `PianoRollPlayhead`/`ClipStretch`
/// precedent).
///
/// The load-bearing invariant the view relies on: the track NAME is rendered as a
/// SOFT, priority-won, truncating label (no hard minimum width), so it can never
/// inflate the window minimum — the round-2 clip bug. The badge fold below only
/// keeps that soft name READABLE at the narrow end by freeing its neighbours.
public enum TrackHeaderLayout {

    /// At/above this sidebar width the clip-count badge ("N ♪") rides in the row;
    /// below it the badge folds into the identity tooltip so the name keeps a
    /// readable share (the "drop the least load-bearing chip first" rule). Chosen
    /// so that when the badge shows, the soft name still wins ≳ 90 pt; when it is
    /// folded (250–299), the name wins ≳ 60 pt — both past the ~56 pt readable
    /// floor at the row's tightest, most-loaded state.
    public static let clipBadgeMinSidebarWidth: CGFloat = 300

    /// Whether the standalone clip-count badge should render at this sidebar width.
    /// False when the track has no clips (nothing to count) OR the sidebar is
    /// narrow enough that the badge would steal the name's readable room.
    public static func showsClipBadge(sidebarWidth: CGFloat, clipCount: Int) -> Bool {
        clipCount > 0 && sidebarWidth >= clipBadgeMinSidebarWidth
    }

    /// The identity hover tooltip: the full (possibly truncated) name, plus the
    /// clip count so it stays discoverable even when the badge has folded away.
    /// Plain language, no unit jargon — the Rule 6 beginner test.
    public static func identityTooltip(name: String, clipCount: Int) -> String {
        guard clipCount > 0 else { return name }
        return "\(name) — \(clipCount) clip\(clipCount == 1 ? "" : "s")"
    }

    // MARK: - Take-group row degradation (m10-j)

    /// The soft track name's readable floor (pt) at the row's tightest, most-loaded
    /// state. The fold rules below keep the priority-won name above this in EVERY
    /// row variant at the 250 pt sidebar minimum — including the heaviest one, a
    /// take-group track (which carries a SECOND disclosure). Below this the name is
    /// too clipped to read (Rule 6). Layout-derived, not enforced here (the name's
    /// pixel width is a SwiftUI layout outcome) — it documents what the fold rules
    /// are FOR, and is pinned by the fold-boolean tests.
    public static let nameReadableFloor: CGFloat = 56

    /// Whether the automation disclosure rides INLINE in the track-header row.
    ///
    /// A take-group track carries BOTH a takes disclosure AND an automation
    /// disclosure; at the narrow end of the m10-d sidebar range the two together
    /// squeeze the soft name below its readable floor (the deferred m10-i "~36 pt at
    /// 250" edge). The surgical fix, matching the badge's "drop the least
    /// load-bearing chip first" idiom: on a HEAVY row (one that already shows a
    /// take-group disclosure) the automation disclosure folds into the row's context
    /// menu while the sidebar is narrow (< `clipBadgeMinSidebarWidth`), reclaiming
    /// ~25 pt so the name stays ≳ 56 pt. The takes disclosure — the control that
    /// makes the row heavy and that the user just reached for — stays visible.
    ///
    /// A one-disclosure row (no take group) ALWAYS keeps automation inline (it has
    /// the room), and a take-group row at a wide sidebar keeps both. So the fold is
    /// reachable only on the exact rows + widths that need it.
    public static func showsInlineAutomationDisclosure(sidebarWidth: CGFloat,
                                                       hasTakeGroups: Bool) -> Bool {
        guard hasTakeGroups else { return true }
        return sidebarWidth >= clipBadgeMinSidebarWidth
    }
}
