import CoreGraphics
import Testing
@testable import DAWAppKit

/// Unit tests for the headless track-header width budget (beta m10-i round 2).
/// The track row is thin over this: it folds the clip-count badge into the tooltip
/// below a sidebar-width threshold so the SOFT (priority-won, no-hard-minimum)
/// name keeps a readable share and the sidebar never inflates the window off its
/// left edge. Exercising the fold rule + tooltip here pins the budget without a
/// display (the `PianoRollPlayhead` test-suite style).
@Suite("TrackHeaderLayout")
struct TrackHeaderLayoutTests {

    // 1. The badge only rides in the row when there are clips AND the sidebar is
    // wide enough; otherwise it folds away (into the tooltip).
    @Test("clip badge shows only with clips and a wide-enough sidebar")
    func badgeVisibility() {
        let t = TrackHeaderLayout.clipBadgeMinSidebarWidth
        // No clips → never a badge, at any width.
        #expect(TrackHeaderLayout.showsClipBadge(sidebarWidth: 420, clipCount: 0) == false)
        #expect(TrackHeaderLayout.showsClipBadge(sidebarWidth: 250, clipCount: 0) == false)
        // Clips + wide → badge shows.
        #expect(TrackHeaderLayout.showsClipBadge(sidebarWidth: 420, clipCount: 3) == true)
        #expect(TrackHeaderLayout.showsClipBadge(sidebarWidth: t, clipCount: 1) == true)   // inclusive at the threshold
        // Clips + narrow → badge folds away so the name keeps its room.
        #expect(TrackHeaderLayout.showsClipBadge(sidebarWidth: t - 1, clipCount: 1) == false)
        #expect(TrackHeaderLayout.showsClipBadge(sidebarWidth: 250, clipCount: 5) == false)
    }

    // 2. The narrow end of the m10-d sidebar range (250–299) folds the badge; the
    // wide end (300–420) shows it — the range straddles the threshold on purpose.
    @Test("the m10-d sidebar range straddles the fold threshold")
    func rangeStraddlesThreshold() {
        // Narrow end: folded.
        #expect(TrackHeaderLayout.showsClipBadge(sidebarWidth: 250, clipCount: 2) == false)
        #expect(TrackHeaderLayout.showsClipBadge(sidebarWidth: 299, clipCount: 2) == false)
        // Wide end: shown.
        #expect(TrackHeaderLayout.showsClipBadge(sidebarWidth: 300, clipCount: 2) == true)
        #expect(TrackHeaderLayout.showsClipBadge(sidebarWidth: 420, clipCount: 2) == true)
        // The threshold sits strictly inside the m10-d range so BOTH states are reachable.
        #expect(TrackHeaderLayout.clipBadgeMinSidebarWidth > 250)
        #expect(TrackHeaderLayout.clipBadgeMinSidebarWidth < 420)
    }

    // 3. The tooltip keeps the clip count discoverable when the badge is folded,
    // and pluralizes / omits correctly.
    @Test("identity tooltip carries the name and, when present, the clip count")
    func tooltip() {
        #expect(TrackHeaderLayout.identityTooltip(name: "Bass", clipCount: 0) == "Bass")
        #expect(TrackHeaderLayout.identityTooltip(name: "Bass", clipCount: 1) == "Bass — 1 clip")
        #expect(TrackHeaderLayout.identityTooltip(name: "Bass", clipCount: 3) == "Bass — 3 clips")
        // A long custom name (the truncation case) keeps its full text in the tip.
        #expect(TrackHeaderLayout.identityTooltip(name: "Lead Vocal Comp Final V2", clipCount: 2)
                == "Lead Vocal Comp Final V2 — 2 clips")
    }

    // 4. The take-group row degradation (m10-j): the automation disclosure folds
    // into the context menu ONLY on a heavy (take-group) row at a narrow sidebar,
    // so the second disclosure doesn't squeeze the soft name below its floor.
    @Test("automation disclosure folds only on a take-group row at a narrow sidebar")
    func automationFold() {
        let t = TrackHeaderLayout.clipBadgeMinSidebarWidth
        // A one-disclosure row (no take group) ALWAYS keeps automation inline —
        // it has the room, at any width.
        #expect(TrackHeaderLayout.showsInlineAutomationDisclosure(sidebarWidth: 250, hasTakeGroups: false) == true)
        #expect(TrackHeaderLayout.showsInlineAutomationDisclosure(sidebarWidth: 420, hasTakeGroups: false) == true)
        // A take-group row folds automation at the narrow end so the name keeps its
        // readable share (the ~36 pt-at-250 edge).
        #expect(TrackHeaderLayout.showsInlineAutomationDisclosure(sidebarWidth: 250, hasTakeGroups: true) == false)
        #expect(TrackHeaderLayout.showsInlineAutomationDisclosure(sidebarWidth: t - 1, hasTakeGroups: true) == false)
        // A take-group row at a wide sidebar keeps both disclosures inline.
        #expect(TrackHeaderLayout.showsInlineAutomationDisclosure(sidebarWidth: t, hasTakeGroups: true) == true)
        #expect(TrackHeaderLayout.showsInlineAutomationDisclosure(sidebarWidth: 420, hasTakeGroups: true) == true)
    }

    // 5. The fold threshold sits strictly inside the m10-d sidebar range, so BOTH
    // the folded (narrow) and unfolded (wide) take-group states are reachable, and
    // the name floor is a positive, meaningful target.
    @Test("automation fold threshold is reachable inside the m10-d range")
    func automationFoldThresholdReachable() {
        #expect(TrackHeaderLayout.clipBadgeMinSidebarWidth > 250)
        #expect(TrackHeaderLayout.clipBadgeMinSidebarWidth < 420)
        #expect(TrackHeaderLayout.nameReadableFloor > 0)
    }
}
