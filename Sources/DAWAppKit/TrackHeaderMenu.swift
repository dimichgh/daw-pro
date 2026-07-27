import CoreGraphics
import DAWCore

/// One action the arrange track-header context menu can offer (m23-m3b).
///
/// A raw-value enum rather than loose strings so the SwiftUI switch, the
/// `debug.trackMenu` echo and the suites all name items from ONE vocabulary: a
/// renamed action breaks the switch's exhaustiveness at COMPILE time instead of
/// quietly dropping an item nobody notices is gone.
public enum TrackHeaderMenuAction: String, Sendable, CaseIterable {
    case rename
    case toggleAutomation
    case bounceInPlace
    case exportMIDI
    case removeTrack
}

/// A menu entry as the row will render it: what it does, what it says, and
/// whether it carries SwiftUI's destructive role.
public struct TrackHeaderMenuItem: Identifiable, Sendable, Equatable {
    public let action: TrackHeaderMenuAction
    /// The visible title. It lives HERE, not in the ViewBuilder, because one of
    /// them is STATEFUL ("Show Automation" vs "Hide Automation") — a title
    /// computed at the call site would be a second reading of the same state,
    /// and the echo could then agree with a menu that says the wrong thing.
    public let title: String

    public var id: TrackHeaderMenuAction { action }

    /// Only removal is destructive. DERIVED from the action rather than stored,
    /// so a new item cannot forget to declare it and render in the wrong role.
    public var isDestructive: Bool { action == .removeTrack }

    public init(action: TrackHeaderMenuAction, title: String) {
        self.action = action
        self.title = title
    }
}

/// The arrange track-header context menu's ITEM LIST, headless (m23-m3b).
///
/// **Why this exists at all.** A SwiftUI `.contextMenu` is an AppKit popup that
/// no headless seam can open — `debug.captureUI` photographs the window, not the
/// menu. So a gate that asserted only the underlying predicate
/// (`Track.canExportMIDI`) would not DISCRIMINATE: the rule can be perfectly
/// right while the menu ignores it. Moving the list here makes the menu's
/// contents assertable, and the row RENDERS FROM this function with no inline
/// conditions left in its builder — if the view kept its own `if`s and this
/// merely described them, the test would be a vacuous echo of a second opinion.
///
/// Pure over the domain `Track` plus the two pieces of view state that actually
/// change the list, so it unit-tests with no store, no app model and no window
/// (the `TrackHeaderLayout` / `MixerStripLayout` precedent).
///
/// Scoped to the ARRANGE track header on purpose: the mixer strip has its own,
/// much shorter context menu (one "Remove Track" item), and folding two menus
/// with different jobs into one list would invent a shared rule that no surface
/// actually wants.
public enum TrackHeaderMenu {

    /// The items this track's header menu offers, in render order.
    ///
    /// - Parameters:
    ///   - track: The row's track — the only domain input.
    ///   - sidebarWidth: The live arrange sidebar width, because the automation
    ///     item's presence is a WIDTH-BUDGET decision (see below).
    ///   - isAutomationExpanded: Whether this track's automation rows are open,
    ///     which flips the automation item's title but not its presence.
    public static func items(track: Track,
                             sidebarWidth: CGFloat,
                             isAutomationExpanded: Bool) -> [TrackHeaderMenuItem] {
        // Discoverability twin of the double-click rename (beta m10-i) — always
        // offered, on every kind.
        var items = [TrackHeaderMenuItem(action: .rename, title: "Rename Track")]

        // The automation item is the INVERSE of the inline disclosure (m10-j):
        // it appears here exactly when the row could NOT afford to keep the
        // disclosure inline, so automation is never lost — only relocated. The
        // width rule itself stays in `TrackHeaderLayout`, which the row also
        // reads for the disclosure; this is a second CALLER of one rule, not a
        // second copy of it. Note the `!` — the sign is the easy thing to get
        // wrong here, and it is pinned by a narrow-sidebar test.
        if !TrackHeaderLayout.showsInlineAutomationDisclosure(
            sidebarWidth: sidebarWidth,
            hasTakeGroups: TakeLaneSelection.hasTakeGroups(track)) {
            items.append(TrackHeaderMenuItem(
                action: .toggleAutomation,
                title: isAutomationExpanded ? "Hide Automation" : "Show Automation"))
        }

        // Bounce in Place (m11-e): offered only for master inputs (a
        // direct-to-master track or a bus) — a bus-routed source has no stem of
        // its own, so the item hides rather than fail.
        //
        // `Track.isMasterInput` (m23-m3c) is the store's OWN rule, not a copy of
        // it: `bounceTrackInPlace` plans through `StemPlan.descriptors`, which
        // both filters and refuses by this same property. Until m23-m3c this
        // condition was a byte-identical duplicate of `StemPlan`'s — the
        // divergence class m23-m3b closed for MIDI export and filed as an open
        // for this one.
        if track.isMasterInput {
            items.append(TrackHeaderMenuItem(action: .bounceInPlace,
                                             title: "Bounce in Place"))
        }

        // Export MIDI… (m23-m3b) sits BESIDE Bounce in Place, and after it: the
        // two are the row's "get this track out of here" pair, and bounce is the
        // older, more-reached-for one. Order is pinned by the suite, so it is a
        // choice a later reader can see was made rather than fallen into.
        //
        // `Track.canExportMIDI` is the store's OWN guard (m23-m3b), and it is
        // TOTAL — an instrument track with no notes yet still writes a valid
        // file — so every track that shows this item will export successfully.
        // That is what earns HIDE over disable: there is nothing to explain.
        if track.canExportMIDI {
            items.append(TrackHeaderMenuItem(action: .exportMIDI, title: "Export MIDI…"))
        }

        // Destructive, so it goes last and wears the role.
        items.append(TrackHeaderMenuItem(action: .removeTrack, title: "Remove Track"))
        return items
    }
}
