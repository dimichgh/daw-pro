import Foundation

// p2-sing-pr-words — RETURN RIDES THE KEY MONITOR: THE SIXTH KEY CLASS, AND THE ONLY ONE THAT OPENS SOMETHING.
// (Design `docs/design/2026-10-12-piano-roll-words.md` §2.5 D4 item 3, Lane A.)
//
// ═══ WHY RETURN IS ON THE MONITOR AT ALL ═══
//
// With notes selected and the Words lane shown, Return opens the word field on the earliest selected melody note.
// The roll's `.onKeyPress` is MEASURABLY unreliable in this app: ⌫ never fired through `.onKeyPress(.delete)`
// (m23-cf-3) and 7 of 7 real Escapes missed the maximized roll's mount (m23-ap I7b, `EscapeKeyMonitorRouting`'s
// banner). A Return mounted on the same focus path would inherit both. So it rides `AppModel.handleKeyDownEvent`
// with the other five — space, ⌫/⌦, the arrows, Escape, musical typing — Escape-shaped: the monitor PREDICTS from the
// roll's REPORTED facts (its selection, whether its lane is shown) and hands the key to the roll through its bridge
// (`PianoRollNoteSelectionBridge.requestWordField()`); the roll opens the field with its LIVE selection.
//
// ═══ WHY IT SWALLOWS SO LITTLE ═══
//
// Return is the default-button key and the field editor's submit key, and the monitor runs before the window's key
// equivalents and before any responder. So it takes Return ONLY in the one state the feature is for, and passes
// everything else on untouched:
//
//   • `.textEditing` — ⚠️ THE LOAD-BEARING ONE. Return inside the word field is the FIELD'S (it commits), and inside a
//     track or marker rename it commits the rename. A monitor that ate it would leave every field uncommittable.
//   • `.secondaryWindow` — a sheet, a popover, a plugin window owns its Return.
//   • `.chord` — ⇧↩ / ⌘↩ / ⌥↩ / ⌃↩ are not this; `.keyRepeat` — a held Return opens ONE field.
//   • `route` answers false — no roll open, nothing selected, the lane hidden (or in its empty state), or something
//     above the editors owns the key (`blocked` = `AppModel.escapeIsOwnedElsewhere`: a modal — which counts the
//     template card and its `.defaultAction` — a live text field, the explain mode).

/// Why a Return key-down did not reach the roll's word field through the monitor. NAMED, never a bare `false` (the
/// `EscapeKeyMonitorRefusal` rule): a test that meant to prove the text-editing guard would pass identically against a
/// monitor that refused everything.
public enum WordFieldKeyMonitorRefusal: String, Equatable, Sendable, CaseIterable {
    /// Neither Return nor keypad Enter. The one refusal that falls through to the app's other key branches rather than
    /// being answered or counted here.
    case otherKey = "other-key"
    /// A modifier is held: ⇧↩, ⌘↩, ⌥↩ and ⌃↩ pass on to whatever claims them.
    case chord
    /// An auto-repeat of a held Return. One field per PRESS.
    case keyRepeat = "key-repeat"
    /// A text-input surface owns keyboard focus. ⚠️ **THE LOAD-BEARING ONE:** Return in the word field commits the
    /// word, Return in a rename field commits the name; the monitor must never take either.
    case textEditing = "text-editing"
    /// The event is aimed at another window (a sheet, a popover, a plugin window), which owns its own Return.
    case secondaryWindow = "secondary-window"
}

/// May this key-down reach the roll's word field through the monitor?
public struct WordFieldKeyMonitorDecision: Equatable, Sendable {
    /// Which guard refused; nil when eligible.
    public var refusedBy: WordFieldKeyMonitorRefusal?

    public var eligible: Bool { refusedBy == nil }

    public init(refusedBy: WordFieldKeyMonitorRefusal? = nil) {
        self.refusedBy = refusedBy
    }
}

/// The pure half of Return's monitor route. Reuses `TransportKeyResponder` / `TransportKeyWindow` /
/// `TransportKeyModifiers` — the app's one mapping of those live facts, shared with the other five key classes.
public enum WordFieldKeyMonitorRouting {

    /// `kVK_Return` (0x24). Layout-independent — the m23-fi law, MATCH BY VIRTUAL KEY CODE.
    public static let returnKeyCode: UInt16 = 36
    /// `kVK_ANSI_KeypadEnter` (0x4C). Its `.numericPad` flag is not a chord (`AppModel.transportKeyModifiers` maps
    /// only ⌘ ⌥ ⌃ ⇧).
    public static let keypadEnterKeyCode: UInt16 = 76
    /// Both. Disjoint from every other key the monitor owns — space 49, ⌫/⌦ 51/117, Escape 53, arrows 123–126, and
    /// every musical-typing and pad key (`MusicalTypingRouting.allCaps` / `padAllCaps`) — pinned by
    /// `returnIsDisjointFromEveryOtherMonitorKey`, so the monitor's branch order stays documentation, never
    /// arbitration.
    public static let keyCodes: [UInt16] = [returnKeyCode, keypadEnterKeyCode]

    /// GUARD ORDER IS THE DIAGNOSIS: the refusal a caller is told is the FIRST that fired. `EscapeKeyMonitorRouting
    /// .decide`'s order exactly — was this even Return, then the event's own shape (chord, repeat), then its CONTEXT
    /// (text, window).
    public static func decide(
        keyCode: UInt16,
        modifiers: TransportKeyModifiers,
        isRepeat: Bool,
        responder: TransportKeyResponder,
        window: TransportKeyWindow
    ) -> WordFieldKeyMonitorDecision {
        guard keyCodes.contains(keyCode) else { return WordFieldKeyMonitorDecision(refusedBy: .otherKey) }
        guard modifiers.isEmpty else { return WordFieldKeyMonitorDecision(refusedBy: .chord) }
        guard !isRepeat else { return WordFieldKeyMonitorDecision(refusedBy: .keyRepeat) }
        guard responder == .none else { return WordFieldKeyMonitorDecision(refusedBy: .textEditing) }
        guard window == .main else { return WordFieldKeyMonitorDecision(refusedBy: .secondaryWindow) }
        return WordFieldKeyMonitorDecision()
    }

    /// WHETHER AN ELIGIBLE RETURN GOES TO THE ROLL: true only for the OPEN roll (`OpenEditorSurface.Reason.rollOpen` —
    /// the surface on screen, never the engaged one and never the focused one, Escape's rule), holding a reported note
    /// selection, with its Words lane reported shown, and nothing above the editors owning the key. Every other state
    /// answers false and the key passes on untouched. No ladder: Return has one effect, opening the field.
    ///
    /// - Parameters:
    ///   - open: `AppModel.openEditorSurface.reason`.
    ///   - rollHasSelection: `PianoRollNoteSelectionBridge.hasSelection`.
    ///   - rollShowsWords: `PianoRollNoteSelectionBridge.wordsShown`.
    ///   - blocked: `AppModel.escapeIsOwnedElsewhere` — a modal, a live text field, the explain mode.
    public static func route(open: OpenEditorSurface.Reason,
                             rollHasSelection: Bool,
                             rollShowsWords: Bool,
                             blocked: Bool) -> Bool {
        guard open == .rollOpen else { return false }
        return rollHasSelection && rollShowsWords && !blocked
    }
}
