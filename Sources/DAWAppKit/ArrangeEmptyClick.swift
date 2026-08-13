import Foundation

// What a CLICK on empty arrange space does to the selection (m25-m). Headless
// (no SwiftUI, no AppKit), in the `ArrangeMarquee` / `ArrangeSelection` /
// `ArrangeGroupDrag` tradition, so the rule can be asserted without a window.
//
// USER-REPORTED 2026-08-13: *"when user selects any clips of group of clips and
// same aplies to notes and then clicks on empty space somehere else in track or
// editor … then it should unselect the clips/notes - s standard behvior for
// text/elements in other editors."* They are right about the convention — Finder,
// every vector/text editor, Logic, Live and Pro Tools all deselect on a click
// into nothing.
//
// ⚠️⚠️ WHY THIS IS A POLICY TYPE AND NOT AN `if` IN THE VIEW. The naive spelling
// — "mouse down on empty ⇒ clear" — breaks THREE shipped behaviours, and the
// only reason to write the rule down is that each of them fails silently:
//
//  1. A PRESS on empty grid ARMS THE RUBBER BAND (`ArrangeMarquee`, m23-g3).
//     Clearing on mouse-DOWN would destroy marquee-from-empty-space. The remedy
//     is not expressed here because it cannot be: it is that the handler runs
//     from a TAP, which SwiftUI delivers only for a press+release that never
//     travelled `ArrangeMarquee.dragSlop`. A drag never reaches this rule at all.
//  2. A RIGHT-CLICK must keep the selection its context menu was invoked on.
//     Also structural: `.onTapGesture` recognises the primary button only, and
//     the empty-lane surface carries no `.contextMenu` of its own.
//  3. ⇧/⌘ ARE ADDITIVE (`ArrangeClickIntent` — the app's ONE chord→intent
//     mapping). A chorded click into empty space is a user building a selection,
//     not abandoning one. THIS one is a real decision, so it lives here.
//
// And one more that only appeared once deselect existed at all — see
// `followsClipCreate`.
public enum ArrangeEmptyClick {
    public enum Outcome: String, Equatable, Sendable {
        /// Clear the clip selection — which also closes the note editor, because
        /// `openEditorClip` derives from the selection's focus (m23-g1).
        case deselect
        /// Leave the selection exactly as it is.
        case keepSelection
    }

    /// The rule.
    ///
    /// - `modifiers`: the chord held at the click. Routed through
    ///   `ArrangeClickIntent` rather than compared here, so shift and ⌘ mean the
    ///   same thing on empty space as they do on a clip block and on a band —
    ///   there is exactly one chord table in this app and this is not a second.
    /// - `followsClipCreate`: this tap is the single-tap half of a double-click
    ///   that just CREATED a clip on empty space (m23-e). The two tap counts
    ///   share one surface, and `TimelineLanesView`'s own note records that the
    ///   create path is built to be correct "whether or not the single tap also
    ///   fires" — which was free while the single tap only SEEKED. Once it also
    ///   deselects, the order `double → single` would create the clip, open the
    ///   editor on it, and then close it again: the beginner's only path from a
    ///   fresh instrument track to a writable grid, killed by a fix to something
    ///   else. Passing this makes BOTH orders correct rather than depending on
    ///   SwiftUI's arbitration between the two recognisers.
    public static func outcome(modifiers: ArrangeClickModifiers,
                               followsClipCreate: Bool) -> Outcome {
        if followsClipCreate { return .keepSelection }
        return ArrangeClickIntent.intent(for: modifiers) == .replace
            ? .deselect : .keepSelection
    }
}
