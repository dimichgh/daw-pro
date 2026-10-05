import Foundation

// m34-k — ESCAPE RIDES THE KEY MONITOR: THE FOURTH KEY RESCUED FROM SwiftUI
// FOCUS, AND THE ONLY ONE THAT IS A DISMISSAL KEY.
//
// ═══ WHY THIS FILE EXISTS: TWO MEASUREMENTS ═══
//
// 1. m34-j's assessment (`scripts/gates/_m34j-escape-assessment.mjs`,
//    2026-08-30): the arrange backstop's `editorEscapeMountHits` went 0→1
//    normally, 1→1 AFTER A RENAME FIELD WAS DISMISSED (never reached), and 1→2
//    once a clip was clicked again — the arrows' exact signature. So a user who
//    renamed a track or a marker could no longer leave the maximized note editor
//    from the keyboard.
// 2. m23-ap I7b's roll probe (2026-09-25): with the roll open, MAXIMIZED and
//    three notes selected, 7 of 7 real posted Escapes landed on the workspace
//    backstop — `pianoRollEditorFocused` false every time — so I4's ladder
//    ("clear the selection first, then leave the mode") was never reached: the
//    press left the mode and KEPT the selection. The roll's `.onKeyPress` mount
//    had never been delivered a real key in that state.
//
// Both are the m34-j law again: WHEN YOU RESCUE ONE KEY FROM A BROKEN ROUTE,
// RESCUE EVERY RIDER ON IT. ⌫ (m23-cf-3) and the arrows (m34-j) already ride
// `AppModel.handleKeyDownEvent`; Escape was left on the focus path.
//
// ═══ WHY ESCAPE IS NOT ARROW-SHAPED, AND WHAT THAT COSTS THIS FILE ═══
//
// ⚠️⚠️ **ESCAPE IS A DISMISSAL KEY. IT BELONGS TO WHATEVER IS ON TOP.** An
// app-wide monitor runs BEFORE the key window's key equivalents and before
// any responder, so a monitor that swallowed Escape whenever an editor could
// use it would eat the dismissal of a sheet, a popover, the field editor, a
// scrimmed card — anything the user is actually looking at. So the monitor
// SWALLOWS ONLY WHAT AN EDITOR MOUNT WOULD HAVE TAKEN, and passes everything
// else on untouched, exactly as the `.onKeyPress` mounts' `.ignored` does:
//
//   • `.textEditing` — a rename field (track, marker, a chat title, Settings)
//     owns its Escape: it reverts the edit. The m34-j caret pin, for Escape.
//   • `.secondaryWindow` — a popover, a sheet, a floating plugin window.
//   • the ladder's `blocked` term (the app's, not this file's) — a scrimmed
//     modal, the explain mode, the "Replace your hand edits?" card. ⚠️ TWO OF
//     THOSE OWN ESCAPE THROUGH A KEY EQUIVALENT (`.keyboardShortcut(
//     .cancelAction)`), and a key equivalent for a plain Escape runs LAST —
//     after this monitor AND after the `.onKeyPress` mounts. That is MEASURED,
//     not assumed (m23-ap I7b-2's A/B, 2026-09-25): a mount that CONSUMES the
//     key starves the key equivalent. On the pre-m34-k build, with the editor
//     maximized, Escape under the explain mode or under the card LEFT THE MODE
//     and kept explain / the card up — the workspace backstop, unblocked, took
//     `.exitMaximize`. So ONE `blocked` term, `AppModel.escapeIsOwnedElsewhere`,
//     hands both of them their key on BOTH routes. (This file's first cut said
//     the mounts "never competed" with a key equivalent; the A/B proved that
//     wrong.) The arrows shipped on "ZERO `.keyboardShortcut` carrying an
//     arrow"; Escape has two, and that property is where they are named.
//   • `route` answering nil — no editor pane is open (the Mix console, or the
//     arrange with nothing open), or nothing in the open pane would be taken
//     down (no selection, not maximized).
//
// ⚠️ **A KEY-REPEAT IS REFUSED, AND THAT IS THE OPPOSITE OF THE ARROWS.** The
// ladder is ONE RUNG PER PRESS (`EditorEscapeLadder`), and the `.onKeyPress`
// mounts take `.down` only, so a held Escape takes one rung today. A monitor that
// took repeats would walk cancel → clear → exit in half a second. A chord is
// refused too (⌘⎋ and friends are not this editor's Escape), the delete
// predicate's order exactly.
//
// ═══ SYNCHRONOUS SWALLOW, ASYNCHRONOUS EFFECT — AND WHY THAT IS HONEST ═══
//
// The monitor must answer "swallow or pass" NOW, and the rung's effect belongs
// to an editor whose model is `@State private`. So the monitor PREDICTS with
// the one ladder, from the open pane's REPORTED selection (the ⌫ terms), and
// hands the key to the pane's own Escape path through its bridge. The pane then
// runs the SAME ladder with its LIVE facts (a gesture in flight included) — the
// ladder is asked twice by one route, never restated. The prediction assumes no
// gesture, and it degrades safely: whenever it predicts a consuming rung, the
// live answer consumes too (a live gesture only ADDS the cancel rung above the
// others); a gesture with nothing else to take down is predicted `.pass` and
// the key goes on to the mounts exactly as it does today.
//
// ═══ THE FIVE `.onKeyPress(.escape)` MOUNTS, AND WHICH ONES THIS RESCUES ═══
//
//   RESCUED (they asked the app's ladder, and SwiftUI focus decided whether
//   they ever ran):
//     • `PianoRollView` — the roll's own mount (the I4 ladder).
//     • `PitchEditorView` — the note editor pane's own mount (I6a).
//     • `ContentView` — the arrange workspace's BACKSTOP.
//   PASSED THROUGH, ON PURPOSE (they sit on a TEXT FIELD and ride the field
//   editor's focus, which works; `.textEditing` hands them the key):
//     • `TimelineLanesView` — the marker rename field.
//     • `TrackListView` — the track rename field.
//
// The mounts STAY, for m23-cf-3's reason: they are correct wiring wherever focus
// is healthy, and the monitor swallows an owned key before SwiftUI sees it, so
// nothing can double-fire.

/// Why an Escape key-down did not reach the editor ladder through the monitor.
///
/// NAMED, never a bare `false` — the `ArrowNudgeMonitorRefusal` rule: a test
/// that meant to prove the TEXT-EDITING guard would pass identically against a
/// monitor that refused everything.
public enum EscapeKeyMonitorRefusal: String, Equatable, Sendable, CaseIterable {
    /// Not the Escape key. The one refusal that falls through to the app's
    /// other key branches rather than being answered or counted here.
    case otherKey = "other-key"
    /// A modifier is held. ⌘⎋ / ⌥⎋ / ⌃⎋ / ⇧⎋ are not the editor's Escape; they
    /// pass on to whatever else claims them.
    case chord
    /// An auto-repeat of a held Escape. One rung per PRESS.
    case keyRepeat = "key-repeat"
    /// A text-input surface owns keyboard focus. ⚠️ **THE LOAD-BEARING ONE:** a
    /// rename field's Escape REVERTS THE EDIT, and a monitor that ate it would
    /// leave the field open with the half-typed name in it.
    case textEditing = "text-editing"
    /// The event is aimed at another window — a popover, a sheet, a floating
    /// plugin window — which owns its own Escape.
    case secondaryWindow = "secondary-window"
}

/// May this key-down reach the editor ladder through the monitor?
public struct EscapeKeyMonitorDecision: Equatable, Sendable {
    /// Which guard refused; nil when eligible.
    public var refusedBy: EscapeKeyMonitorRefusal?

    public var eligible: Bool { refusedBy == nil }

    public init(refusedBy: EscapeKeyMonitorRefusal? = nil) {
        self.refusedBy = refusedBy
    }
}

/// The open editor pane an eligible Escape is handed to.
public enum EscapeKeyMonitorTarget: String, Equatable, Sendable, CaseIterable {
    case pianoRoll = "piano-roll"
    case pitchEditor = "pitch-editor"
}

/// The pure half of Escape's monitor route (m34-k). Reuses `TransportKeyResponder`
/// / `TransportKeyWindow` / `TransportKeyModifiers` — the app's one mapping of
/// those live facts, shared with the delete and arrow predicates.
public enum EscapeKeyMonitorRouting {

    /// `kVK_Escape`. Layout-independent — the m23-fi law, MATCH BY VIRTUAL KEY
    /// CODE. Disjoint from every other key the monitor owns (space 49, ⌫/⌦
    /// 51/117, arrows 123–126, and none of musical typing's layout keys —
    /// pinned by `escapeIsDisjointFromEveryOtherMonitorKey`), so the monitor's
    /// branch order stays documentation, never arbitration.
    public static let escapeKeyCode: UInt16 = 53

    /// GUARD ORDER IS THE DIAGNOSIS: the refusal a caller is told is the FIRST
    /// that fired. `DeleteKeyMonitorRouting.decide`'s order exactly — cheapest
    /// and most specific first (was this even Escape?), then the event's own
    /// shape (chord, repeat), then its CONTEXT (text, window).
    public static func decide(
        keyCode: UInt16,
        modifiers: TransportKeyModifiers,
        isRepeat: Bool,
        responder: TransportKeyResponder,
        window: TransportKeyWindow
    ) -> EscapeKeyMonitorDecision {
        guard keyCode == escapeKeyCode else { return EscapeKeyMonitorDecision(refusedBy: .otherKey) }
        guard modifiers.isEmpty else { return EscapeKeyMonitorDecision(refusedBy: .chord) }
        guard !isRepeat else { return EscapeKeyMonitorDecision(refusedBy: .keyRepeat) }
        guard responder == .none else { return EscapeKeyMonitorDecision(refusedBy: .textEditing) }
        guard window == .main else { return EscapeKeyMonitorDecision(refusedBy: .secondaryWindow) }
        return EscapeKeyMonitorDecision()
    }

    /// WHERE AN ELIGIBLE ESCAPE GOES: the open pane that would take something
    /// down, or nil to pass the key on untouched.
    ///
    /// ⭐ **THE OPEN PANE, NOT THE ENGAGED ONE, AND NOT THE FOCUSED ONE.**
    /// Focus is the coin flip this whole route exists to stop consulting (m23-al
    /// 6/6, I7b 7/7). Engagement is the ⌘A answer the user overruled at m34-d
    /// ("make it work whenever the editor is open"): ⌘A selects every note of a
    /// roll the user merely OPENED, and an Escape that could not clear that
    /// selection would be the same defect one key over. Only one pane is ever
    /// open (`EditorSurfaceRouter`, structural), so "whose selection" has exactly
    /// one answer — and it is the same reported selection ⌫ routes on.
    ///
    /// ⚠️ **NO PANE, NO ROUTE** — `.notArrangeWorkspace` and `.noRollOpen`
    /// answer nil even while the maximized slot is set: with no pane on screen
    /// the mode has no visible effect, and a key swallowed to flip an invisible
    /// slot is a key that did nothing. (The Mix console mounts no Escape handler
    /// at all, so nothing there is lost; in the arrange the backstop mount still
    /// answers whenever focus reaches it, exactly as before.)
    ///
    /// - Parameters:
    ///   - open: `AppModel.openEditorSurface.reason`.
    ///   - rollHasSelection: the roll's reported note selection
    ///     (`PianoRollNoteSelectionBridge.hasSelection`).
    ///   - pitchEditorHasSelection: the note editor pane's reported selection
    ///     (`PitchEditorInteractionBridge.hasNoteSelection`).
    ///   - maximized: `PanelLayoutStore.editorMaximized`.
    ///   - blocked: the app's `blocked` term — a modal, the explain mode, the
    ///     preset card, a live text field (`AppModel.escapeIsOwnedElsewhere`).
    public static func route(open: OpenEditorSurface.Reason,
                             rollHasSelection: Bool,
                             pitchEditorHasSelection: Bool,
                             maximized: Bool,
                             blocked: Bool) -> EscapeKeyMonitorTarget? {
        let target: EscapeKeyMonitorTarget
        let hasSelection: Bool
        switch open {
        case .rollOpen:
            target = .pianoRoll
            hasSelection = rollHasSelection
        case .pitchEditorOpen:
            target = .pitchEditor
            hasSelection = pitchEditorHasSelection
        case .notArrangeWorkspace, .noRollOpen:
            return nil
        }
        // THE ONE LADDER, asked with no gesture (the prediction — see the
        // banner); the pane re-asks it with its live facts.
        let predicted = EditorEscapeLadder.resolve(gestureLive: false, hasSelection: hasSelection,
                                                   maximized: maximized, blocked: blocked)
        return predicted.consumesKey ? target : nil
    }
}
