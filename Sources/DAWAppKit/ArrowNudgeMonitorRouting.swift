import Foundation

// m34-j — THE ELIGIBILITY HALF OF THE ARROW-KEY NUDGES.
//
// ═══ WHY THIS FILE EXISTS: A MEASUREMENT, AND NOT THE ONE THE ITEM PREDICTED ═══
//
// m34-j was filed predicting that ←/→/↑/↓ were "intermittently dead after a clip
// switch, roughly half the time", riding the focus pair m23-al measured
// alternating 6-true/6-false. **THAT PREMISE IS REFUTED, MEASURED**
// (`scripts/gates/_m34j-arrow-nudge-repro.mjs`, 2026-08-30): 36/36 posted arrows
// entered their `.onKeyPress` mount and moved the clip across 12 consecutive
// clip switches per leg — WHILE `pianoRollEditorFocused` alternated exactly
// `101010101010` in the same run. The antecedent was present; the arrows did not
// care.
//
// ⚠️ THE ITEM CONFLATED TWO DIFFERENT FLAGS, AND THE DISTINCTION IS THE WHOLE
// DIAGNOSIS. `pianoRollEditorFocused` is the ROLL's own `@FocusState` and it
// alternates. `ArrangeDeleteKey.focused` — the one the arrow mounts actually
// hang off — read TRUE 12/12 through the same switches. They are not the same
// coin, and only one of them is flipping.
//
// ⭐⭐ BUT THE DEFECT CLASS IS REAL, WITH AN ORDINARY DOOR NOBODY HAD TRIED:
// **dismissing any text field drops `ArrangeDeleteKey.focused` 1 → 0 and never
// restores it.** Found by `_m34j-arrow-dead-state-hunt.mjs`, characterised by
// `_m34j-focus-loss-characterise.mjs`:
//
//   • LATCHED — three consecutive presses dead, not a settling hiccup.
//   • BOTH AXES — ↑/↓ die with ←/→, as one `@FocusState` predicts.
//   • ALL THREE DISMISSAL ROUTES — commit (Return), cancel (Escape), and
//     unmounting the field. It is not an Escape-handling bug.
//   • RECOVERED ONLY BY CLICKING A CLIP, which bumps `arrangeKeyFocusNonce` and
//     re-asserts focus. Until then the user's arrow keys do nothing.
//   • NEGATIVE CONTROL — opening and closing a NON-text modal (undo history) the
//     same way left focus ALIVE and the arrows working. So it is the field
//     editor specifically, not "any overlay". One route into a dead state is a
//     coincidence; three routes plus a control that stays alive is a mechanism.
//
// ⭐ AND THAT IS THE ITEM'S HEADLINE AFTER ALL — "⌫ was rescued from this exact
// route at m23-cf-3; the arrows were left behind." Measured SIDE BY SIDE in the
// SAME dead state (`_m34j-monitor-viability.mjs`): ⌫ reached the monitor, was
// ACCEPTED (`refusedBy: null`) and deleted the clip; the arrow reached nothing.
// The rescue was framed as "fix delete" rather than "fix the class", so the
// class kept one rider and lost the rest.
//
// ═══ WHY A MONITOR AND NOT A FOCUS REPAIR ═══
//
// Re-asserting `arrangeKeyFocusNonce` whenever a field resigns was the obvious
// alternative and is deliberately NOT what shipped. It is whack-a-mole — every
// text field in the app (track rename, marker rename, chat rename, the Copilot
// input, five Settings fields including the CONTROL-PORT one) would need its own
// call, and the next field added would silently not have it. Worse, it would be
// a NEW mechanism where this tree already has a measured, shipped one for
// exactly this failure. `_m34j-monitor-viability.mjs` measured that the monitor
// route is alive in precisely the state where SwiftUI focus is dead, so copying
// it costs nothing that a focus repair would have bought.
//
// ═══ WHAT THIS PREDICATE DOES **NOT** DO, EACH ON PURPOSE ═══
//
// ⚠️⚠️ IT DOES NOT REFUSE CHORDS, AND THAT IS THE OPPOSITE OF
// `DeleteKeyMonitorRouting`. ⌥ (fine) and ⇧ (bar) are MEANINGFUL nudge
// modifiers; ⌘/⌃ are pass-throughs. All of that policy already lives in exactly
// one place — `ArrangeNudge.step` / `ArrangeNudge.verticalStep`, reached through
// `AppModel.handleArrangeNudgeKey` — and restating any of it here would be the
// second computation of one rule that m23-x → m23-al is this tree's own record
// of the cost of. A chord the policy declines comes back `handled: false`, and
// the monitor then PASSES THE EVENT THROUGH, which is byte-identical to what the
// `.onKeyPress` mount does with `.ignored` today.
//
// ⚠️⚠️ IT DOES NOT REFUSE AUTO-REPEAT, AND THAT IS ALSO THE OPPOSITE OF DELETE.
// `DeleteKeyMonitorRouting.keyRepeat` calls itself "the ONE guard with teeth"
// because a held ⌫ walks from "delete the notes" to "delete the clip". Here the
// stake is inverted: **walking a clip into place by HOLDING an arrow is the
// gesture**, the mounts ask for `phases: [.down, .repeat]` on purpose, and the
// undo cost is already paid by `ProjectStore.moveClipsKey`'s selection-stable
// coalescing. There is also a mechanical reason no comment should omit: once
// this monitor swallows an owned key-down, SwiftUI's own key-state tracking
// never sees it, so the mount CANNOT receive the repeats even if it wanted to —
// refusing repeats here would not hand them to SwiftUI, it would delete them.
//
// ⚠️ IT DOES NOT RESTATE THE NUDGE GUARDS. Workspace, modal, empty selection,
// the piano-roll shield and the automation-lane shield are all
// `handleArrangeNudgeKey`'s, tested there, and asked exactly once. This tier
// answers only "may this keystroke reach the nudge policy at all?" — the same
// split `DeleteKeyMonitorRouting` draws against `DeleteMenuPolicy.keyPress`.
// The overlap with that handler is exactly ONE term, the text-editing guard, and
// it is deliberate defence in depth across two tiers: this one reads the EVENT'S
// window, that one reads the app's LIVE responder.
//
// ⚠️ THE `.onKeyPress` MOUNTS STAY. This is ADDITIVE, for the m23-cf-3 reason:
// they are correct wiring wherever focus is healthy, and the monitor swallows an
// owned key before SwiftUI sees it, so nothing can double-fire. In the states
// where the monitor passes the event on, the mount asks the SAME
// `handleArrangeNudgeKey` and gets the same answer.
//
// ⚠️ ENUMERATED BEFORE SHIPPING, because an app-wide monitor for a key OTHER
// surfaces might want is the hazard here (musical typing's ⌘ handler cutting a
// piano-roll note mid-drag is this tree's own example, days old). Measured with
// a positive control on every pattern: `Sources/DAWApp` holds exactly TWO arrow
// `.onKeyPress` mounts and both are the ones this backs; ZERO `onMoveCommand`;
// ZERO SwiftUI `List` (so no built-in keyboard list navigation); ZERO
// `.keyboardShortcut` carrying an arrow (so no menu key equivalent to race).
// Popovers and floating plugin windows are covered by `.secondaryWindow`, modals
// by the handler's own guard, and every text surface by `.textEditing`.

/// Why an arrow key-down did not reach the nudge policy.
///
/// NAMED, never a bare `false` — the `ArrangeNudgeRefusal` rule: a test that
/// meant to prove the TEXT-EDITING guard would pass identically against a
/// monitor that refused everything, which is how a dead feature passes a
/// refusal-only suite.
public enum ArrowNudgeMonitorRefusal: String, Equatable, Sendable, CaseIterable {
    /// Not an arrow key at all — the cheapest guard, and the one refusal that
    /// must fall through to the app's other key branches rather than being
    /// answered here.
    case otherKey = "other-key"
    /// A text-input surface owns keyboard focus. ⚠️ **THE LOAD-BEARING ONE ON
    /// THIS PATH.** A Backspace typed into a rename field is a rare accident;
    /// ← and → are pressed inside text fields constantly, by every user, in
    /// every rename. If this guard is wrong the user's clips move while they
    /// are trying to move a caret.
    case textEditing = "text-editing"
    /// The event is aimed at some other window — a floating plugin window, a
    /// popover, or an unresolvable synthesized window number. An arrow pressed
    /// in an AU's preset browser must never move the user's clips.
    case secondaryWindow = "secondary-window"
}

/// Which arrow, in `DAWAppKit`'s own vocabulary.
///
/// Deliberately reuses `ArrangeNudgeDirection` / `ArrangeVerticalNudgeDirection`
/// — the types `ArrangeNudge.step` and `.verticalStep` already speak — rather
/// than declaring a parallel four-case enum the app would have to translate.
/// `AppModel.ArrangeNudgeAxisKey` is the same sum type one module up; it cannot
/// be used here because it lives in `DAWApp`, which has no test target (which is
/// the whole reason this predicate is in `DAWAppKit` at all).
public enum ArrowNudgeMonitorKey: Equatable, Sendable {
    case horizontal(ArrangeNudgeDirection)
    case vertical(ArrangeVerticalNudgeDirection)
}

/// May this key-down reach `AppModel.handleArrangeNudgeKey`?
public struct ArrowNudgeMonitorDecision: Equatable, Sendable {
    /// Which arrow it is; nil when refused. Carrying the KEY rather than a bare
    /// `eligible: Bool` is what keeps the key-code → direction mapping in one
    /// tested place instead of in a `switch` at the call site.
    public var key: ArrowNudgeMonitorKey?
    /// Which guard refused; nil when eligible.
    public var refusedBy: ArrowNudgeMonitorRefusal?

    public var eligible: Bool { key != nil }

    public init(key: ArrowNudgeMonitorKey? = nil,
                refusedBy: ArrowNudgeMonitorRefusal? = nil) {
        self.key = key
        self.refusedBy = refusedBy
    }
}

/// The pure predicate behind the arrow keys' `NSEvent` monitor (m34-j).
///
/// Deliberately reuses `TransportKeyResponder` / `TransportKeyWindow` rather
/// than declaring a parallel vocabulary, for `DeleteKeyMonitorRouting`'s stated
/// reason: they are already the app's mapping of the same live facts, the app
/// already has one mapper for each, and two enums that agree about everything
/// are two things to keep in step.
public enum ArrowNudgeMonitorRouting {

    /// `kVK_LeftArrow`. Layout-independent — the m23-fi law is MATCH BY VIRTUAL
    /// KEY CODE, NOT BY CHARACTER. That law was learned expensively on the
    /// delete key, where `KeyEquivalent.delete` is 0x08 while the ⌫ key sends
    /// 0x7F, and three mounts were dead for months on the difference. The arrows
    /// have the same hazard in a different spelling: their characters are the
    /// private-use `NS*ArrowFunctionKey` scalars (0xF700–0xF703), which nothing
    /// in this file needs to know.
    public static let leftArrowKeyCode: UInt16 = 123
    /// `kVK_RightArrow`.
    public static let rightArrowKeyCode: UInt16 = 124
    /// `kVK_DownArrow`. ⚠️ 125 is DOWN and 126 is UP — the pair is easy to
    /// transpose and a transposition would be invisible to any test that only
    /// asserted "some vertical key was recognised". `verticalKeyCodesAreNotTransposed`
    /// pins them by name.
    public static let downArrowKeyCode: UInt16 = 125
    /// `kVK_UpArrow`.
    public static let upArrowKeyCode: UInt16 = 126

    /// GUARD ORDER IS THE DIAGNOSIS, not just the answer: the refusal a caller
    /// is told is the FIRST one that fired, so the order decides what a red test
    /// reads. Cheapest-and-most-specific first (was this even an arrow key?),
    /// then the two that are about the CONTEXT.
    ///
    /// - Parameters:
    ///   - keyCode: `NSEvent.keyCode`.
    ///   - responder: the classified first responder of the event's window.
    ///   - window: whether the event targets the app's content window.
    ///
    /// ⚠️ **THERE IS NO `modifiers:` PARAMETER AND NO `isRepeat:` PARAMETER, AND
    /// BOTH ABSENCES ARE DECISIONS** — see this file's banner. Chords are the
    /// nudge policy's business (⌥ fine, ⇧ bar, ⌘/⌃ pass through) and repeats are
    /// the gesture. Adding either here would move a rule that has one home.
    public static func decide(
        keyCode: UInt16,
        responder: TransportKeyResponder,
        window: TransportKeyWindow
    ) -> ArrowNudgeMonitorDecision {
        let key: ArrowNudgeMonitorKey
        switch keyCode {
        case leftArrowKeyCode: key = .horizontal(.left)
        case rightArrowKeyCode: key = .horizontal(.right)
        case upArrowKeyCode: key = .vertical(.up)
        case downArrowKeyCode: key = .vertical(.down)
        default: return ArrowNudgeMonitorDecision(refusedBy: .otherKey)
        }
        guard responder == .none else {
            return ArrowNudgeMonitorDecision(refusedBy: .textEditing)
        }
        guard window == .main else {
            return ArrowNudgeMonitorDecision(refusedBy: .secondaryWindow)
        }
        return ArrowNudgeMonitorDecision(key: key)
    }
}
