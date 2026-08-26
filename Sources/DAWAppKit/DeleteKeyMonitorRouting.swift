import Foundation

// m23-cf-3 — THE ELIGIBILITY HALF OF THE DELETE KEY.
//
// ═══ WHY THIS FILE EXISTS: A MEASUREMENT, NOT A PREFERENCE ═══
//
// m23-cf gave the DELETE key ONE decision (`DeleteMenuPolicy.keyPress`) that all
// three `.onKeyPress(.delete)` claimants call, so whichever of them SwiftUI
// happened to focus produced the same answer. That closed a real divergence —
// and it could not close the user's bug, because the bug is that NO claimant is
// ever asked.
//
// MEASURED HEADLESSLY, on the real event queue, 2026-08-10
// (`scripts/gates/_m23cf3-onkeypress-probe.mjs`, all three legs):
//
//   E1  DELETE posted while a marker rename field is focused
//         → fieldText "RenameMe" → ""            AppKit CONSUMED the key.
//   E2  DELETE posted with a clip selected, no text focus
//         → `deleteKeyFunnelSeq` 0 → 0            NO `.onKeyPress(.delete)` fired.
//         → and `firstResponder` read "none".
//   E3  SPACE posted in E2's EXACT state (the CONTROL)
//         → isPlaying false → true                `NSApp.postEvent` DELIVERS.
//
// E3 is what makes E2 evidence rather than silence: without it, "nothing
// happened" could have been the injection failing. It matches the user's own
// three results on a freshly built bundle: note delete dead, clip delete dead,
// text delete alive.
//
// ⚠️ SO THE OLD "m23-bw WALL" IS MIS-STATED WHEREVER IT SAYS AN UNBUNDLED
// STAGING BINARY "DOES NOT ROUTE REAL KEY EVENTS". It routes them fine — to
// AppKit.
//
// ⚠️⚠️ CORRECTED AT m23-fi (2026-08-10) — THE PARAGRAPH THAT USED TO STAND HERE
// WAS MEASURED FALSE, AND THE CORRECTION MATTERS BECAUSE IT NAMES A DIFFERENT
// BUG. It said: "no SwiftUI `.onKeyPress` ever fires, because the content
// window's first responder is the window itself, so no SwiftUI focus exists for
// `.onKeyPress` to hang off." Both halves are wrong.
//
//   • THE RESPONDER. `debug.keySpace`'s `firstResponder: "none"` is this app's
//     OWN `TransportKeyResponder` CLASSIFIER collapsing "not a text editor" to
//     `.none`. The `responderClass` field in the same echo reads
//     `AppKitWindowHostingView<…>` — there IS a first responder and it is the
//     SwiftUI hosting view.
//   • THE FOCUS. `ArrangeDeleteKey`'s `@FocusState` reads `true` with a clip
//     selected, and reads `true` on a COLD app at `arrangeKeyFocusNonce == 0` —
//     i.e. the arrange workspace holds SwiftUI key focus from launch, before
//     any assertion. Its ←/→ and ↑/↓ `.onKeyPress` mounts fire on real posted
//     key events and move the clip.
//
// ⭐ WHAT ACTUALLY KILLS `.onKeyPress(.delete)` IS ONE CHARACTER. Read out of
// SwiftUI itself, `KeyEquivalent.delete` is **0x08**; the system's own
// HID→Unicode translation of `kVK_Delete` (51) is **0x7F**; and `.onKeyPress`
// matches on the event's characters (measured: keyCode 51 with 0x08 enters the
// mount, the SAME keyCode with 0x7F does not). So the three
// `.onKeyPress(.delete)` mounts cannot fire for the ⌫ key under any amount of
// focus repair — which is exactly why the monitor below is the right fix, but
// for a different reason than the one originally written down.
// See `scripts/gates/_m23fi-onkeypress-census.mjs` and `DAWApp/KeyPressProbe.swift`.
//
// ═══ THE SHAPE OF THE FIX, AND WHY IT IS THIS ONE ═══
//
// The SPACE BAR WORKS, and it works because it does not go through SwiftUI focus
// at all: `AppModel.installKeyDownMonitor` runs an `NSEvent` local monitor and
// asks the headless `TransportKeyRouting.decide`. Both halves of the delete fix
// therefore already existed in this tree, separately — the ELIGIBILITY half (an
// NSEvent monitor) and the CORRECTNESS half (`DeleteMenuPolicy`, unified by
// m23-cf). This file is only the first half, and it deliberately answers a
// SMALLER question than the policy does:
//
//   THIS decides "may this keystroke reach the delete policy at all?"
//   `DeleteMenuPolicy.keyPress` decides "which surface owns it, if any?"
//
// ⚠️⚠️ NOTHING HERE MAY RESTATE THE POLICY. m23-x → m23-al is this tree's own
// record of what a second computation of one rule costs. The overlap is exactly
// one term — the text-editing guard — and it is deliberate defence in depth
// across two tiers (a redden run measured it: removing only the policy's copy
// left the clips safe because `handleArrangeDeleteKey` still refused). This tier
// reads the EVENT'S window, that tier reads the app's live responder; they can
// only disagree in states neither of them should act in.
//
// ⚠️ AND THE `.onKeyPress(.delete)` MOUNTS STAY. This is ADDITIVE. They are the
// correct wiring if SwiftUI focus is ever repaired, `DeleteKeySiteTests` pins
// that there are exactly three of them, and the monitor swallows the event when
// a surface owns it — so even if a mount became eligible it could not double-fire.
//
// ⚠️ m23-fi FOOTNOTE ON THAT SENTENCE: "if SwiftUI focus is ever repaired" is
// now known to be the wrong conditional — focus is not broken. The mounts are
// dead on the CHARACTER, and the one-token repair is measured: adding
// `KeyEquivalent("\u{7F}")` to a mount's key list makes the authentically
// translated ⌫ enter it. That repair is deliberately NOT applied here (m23-fi is
// a diagnosis item); when it is, the double-fire argument above still holds,
// because the monitor still swallows an owned key before SwiftUI sees it.

/// Why a DELETE key-down did not reach the delete policy.
///
/// NAMED, never a bare `false`, for `ArrangeNudgeRefusal`'s reason: a test that
/// meant to prove the TEXT-EDITING guard would pass identically against a
/// monitor that refused everything, which is how a dead feature passes a
/// refusal-only suite.
public enum DeleteKeyMonitorRefusal: String, Equatable, Sendable, CaseIterable {
    /// Not a delete key at all.
    case otherKey = "other-key"
    /// A ⌘/⌥/⌃/⇧ chord — not ours. ⌘⌫ is "move to trash" on macOS and ⌥⌫ is
    /// "delete word left" in every text surface; claiming either would be a
    /// land grab.
    case chord
    /// A HELD key auto-repeating.
    ///
    /// ⚠️ REFUSED, AND THIS IS THE ONE GUARD WITH TEETH RATHER THAN SYMMETRY.
    /// The space bar refuses repeats so a held space cannot machine-gun the
    /// transport. Here the stake is destruction: the FIRST press deletes the
    /// selected notes, which empties the roll's selection, which makes the very
    /// next press route to `.arrangeClips` and delete THE CLIP. A user holding
    /// DELETE for half a second would lose the clip they were editing. A
    /// deliberate second press still does that — correctly, and `m23cf-delete-key`
    /// leg U2 pins it — but an auto-repeat is not a second press.
    case keyRepeat = "key-repeat"
    /// A text-input surface owns keyboard focus — the m17-d trap. Backspace
    /// typed into a track or marker rename field must reach the field editor.
    case textEditing = "text-editing"
    /// The event is aimed at some other window — a floating plugin window, a
    /// panel, or an unresolvable synthesized window number. DELETE pressed in an
    /// AU's preset browser must never reach the user's clips.
    case secondaryWindow = "secondary-window"
}

/// May this key-down reach `DeleteMenuPolicy.keyPress`?
public struct DeleteKeyMonitorDecision: Equatable, Sendable {
    /// True: hand it to the delete policy, which decides which surface owns it.
    public var eligible: Bool
    /// Which guard refused; nil when eligible.
    public var refusedBy: DeleteKeyMonitorRefusal?

    public init(eligible: Bool, refusedBy: DeleteKeyMonitorRefusal? = nil) {
        self.eligible = eligible
        self.refusedBy = refusedBy
    }
}

/// The pure predicate behind the DELETE key's `NSEvent` monitor (m23-cf-3).
///
/// Deliberately reuses `TransportKeyModifiers` / `TransportKeyResponder` /
/// `TransportKeyWindow` rather than declaring a parallel vocabulary: they are
/// already the app's mapping of the same three live facts, the app already has
/// one mapper for each, and two enums that agree about everything are two things
/// to keep in step.
public enum DeleteKeyMonitorRouting {

    /// `kVK_Delete` — the key labelled ⌫ (Backspace) on every Mac keyboard, and
    /// what `NSDeleteCharacter` (0x7F) comes from. Layout-independent.
    public static let deleteKeyCode: UInt16 = 51

    /// `kVK_ForwardDelete` — the ⌦ key (fn+⌫ on laptops).
    ///
    /// ACCEPTED ALONGSIDE ⌫, and that is a decision rather than an oversight.
    /// SwiftUI's `KeyEquivalent.delete` matches only the backspace character, so
    /// the three `.onKeyPress(.delete)` mounts never claimed ⌦ — but every DAW
    /// and every Finder treats both as "remove the selection", and a user who
    /// reaches for ⌦ and gets silence has the same bug this item is closing.
    public static let forwardDeleteKeyCode: UInt16 = 117

    /// GUARD ORDER IS THE DIAGNOSIS, not just the answer: the refusal a caller
    /// is told is the FIRST one that fired, so the order decides what a red test
    /// reads. Cheapest-and-most-specific first (was this even a delete key?),
    /// then the two that are about the KEYSTROKE (chord, repeat), then the two
    /// that are about the CONTEXT (focus, window).
    ///
    /// - Parameters:
    ///   - keyCode: `NSEvent.keyCode`.
    ///   - modifiers: the four chord modifiers, device-independent. Caps lock /
    ///     fn / numeric-pad flags deliberately do NOT block — caps lock being on
    ///     must not kill the delete key (`TransportKeyRouting`'s rule, same
    ///     reason).
    ///   - isRepeat: `NSEvent.isARepeat`.
    ///   - responder: the classified first responder of the event's window.
    ///   - window: whether the event targets the app's content window.
    public static func decide(
        keyCode: UInt16,
        modifiers: TransportKeyModifiers,
        isRepeat: Bool,
        responder: TransportKeyResponder,
        window: TransportKeyWindow
    ) -> DeleteKeyMonitorDecision {
        guard keyCode == deleteKeyCode || keyCode == forwardDeleteKeyCode else {
            return DeleteKeyMonitorDecision(eligible: false, refusedBy: .otherKey)
        }
        guard modifiers.isEmpty else {
            return DeleteKeyMonitorDecision(eligible: false, refusedBy: .chord)
        }
        guard !isRepeat else {
            return DeleteKeyMonitorDecision(eligible: false, refusedBy: .keyRepeat)
        }
        guard responder == .none else {
            return DeleteKeyMonitorDecision(eligible: false, refusedBy: .textEditing)
        }
        guard window == .main else {
            return DeleteKeyMonitorDecision(eligible: false, refusedBy: .secondaryWindow)
        }
        return DeleteKeyMonitorDecision(eligible: true)
    }
}
