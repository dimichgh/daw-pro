import Foundation
import SwiftUI
import DAWControl

/// ⚠️ **m23-fi PROBE SCAFFOLDING — AN INSTRUMENT, NOT A FEATURE.** Nothing in
/// the app ROUTES on anything here; every field is write-once-from-a-handler /
/// read-once-from-the-debug-echo. Deleting this file and its call sites would
/// change no user-visible behaviour.
///
/// ═══ WHY IT EXISTS ═══
/// m23-cf measured that `.onKeyPress(.delete)` never fires in this app: the
/// handler was entered 0/12 with the `NSEvent` monitor disabled and 12/12 with
/// it live. The fix (`DAWAppKit/DeleteKeyMonitorRouting.swift`) BYPASSES SwiftUI
/// focus rather than repairing it, so the root cause — `arrangeKeyFocusNonce`'s
/// focus assertion never reaching AppKit — is still live. m23-fi asks the next
/// question: **which OTHER `.onKeyPress` mounts are dead the same way?**
///
/// ═══ THE DISCRIMINATOR, AND WHY A SHARED COUNTER IS THE ONLY HONEST ONE ═══
/// Each counter is bumped as the **FIRST STATEMENT** of its `.onKeyPress`
/// closure, before any guard. That is what separates the two silences a bare
/// "nothing happened" conflates:
///   • counter did NOT move → SwiftUI never delivered the key. The mount is
///     dead; no guard inside it is implicated.
///   • counter moved, effect did not → the key arrived and a guard declined.
///
/// ⚠️ **A BARE ⌦ CANNOT ANSWER THIS ANY MORE.** Since m23-cf-3 the key monitor
/// calls `handleDeleteKey()` and returns `nil` (swallows), so `deleteKeyFunnelSeq`
/// moves for a DELETE that SwiftUI never saw. Re-measuring the three delete
/// mounts needs the ⇧-chord route described below.
///
/// ⭐ **WHAT THIS INSTRUMENT FOUND (m23-fi, 2026-08-10, measured):** the roadmap
/// item's premise is wrong. Focus is HEALTHY — `arrangeWorkspaceFocused` reads
/// `true` with a clip selected, and the ←/→ and ↑/↓ mounts on that very view
/// fire on real posted key events. What fails is ONE KEY: SwiftUI's
/// `KeyEquivalent.delete` is **0x08** (read out of SwiftUI itself, below), the
/// system translates `kVK_Delete` to **0x7F**, and `.onKeyPress` matches on the
/// event's characters. The three `.onKeyPress(.delete)` mounts therefore cannot
/// fire for the physical ⌫ key on any amount of focus repair.
///
/// ⭐⭐ **AND THE ONE-TOKEN REPAIR IS MEASURED, NOT REASONED.** Temporarily
/// adding `KeyEquivalent("\u{7F}")` to the arrange mount's key list made the
/// authentically-translated ⌫ enter it (`entered a mount = true` in the
/// census's authentic-translation table). The edit was reverted — m23-fi is a
/// diagnosis item and the fix has architectural weight — but the fix pattern is
/// now a measurement rather than a guess:
///     `.onKeyPress(keys: [KeyEquivalent("\u{7F}"), .deleteForward]) { … }`
/// catches BOTH ⌫ and ⌦, which is more than `.delete` has ever caught.
///
/// ✅ **SHIPPED AT m23-fk (2026-08-10), WITH ONE ARGUMENT THE PROPOSAL ABOVE
/// DOES NOT HAVE AND THAT ARGUMENT IS THE WHOLE SAFETY STORY.** All three
/// mounts now read `.onKeyPress(keys: [KeyEquivalent("\u{7F}"), .delete,
/// .deleteForward], phases: [.down])`. `phases: [.down]` is NOT redundant with
/// the documented default: measured on this app, omitting it delivers presses
/// whose `KeyPress.phase` reads `.repeat`, the m23-cf-3 monitor refuses an
/// auto-repeat and RETURNS the event, and a HELD ⌫ therefore walked from
/// "delete the selected notes" to "delete the clip" in one measured sequence.
/// A mount cannot re-derive repeat-ness for itself — the monitor swallowed the
/// initial key-down, so SwiftUI's own key-state tracking never saw it. The
/// paragraph above is history, not a pending proposal. This instrument is
/// KEPT rather than removed: it is what measured the defect, and
/// `_m23fk-delete-character-probe.mjs` re-reads the same counters to prove the
/// respelling took. `.delete` stayed in each list deliberately (0x08 costs
/// nothing and covers a future SwiftUI that normalises the character).
///
/// ═══ WHY STATIC AND NOT PLUMBED THROUGH `AppModel` ═══
/// The seven mounts live in five view types, three of which (`AutomationLaneEditor`,
/// `TrackRow`'s rename field, `MarkerRenameField`) have no reference to
/// `AppModel` and take their inputs as closures. Plumbing a probe through their
/// initialisers would mean editing every construction site of each — a diff far
/// larger than the measurement, in files three other agents are working in, for
/// scaffolding that is meant to be removable in one `git rm`. `@MainActor`
/// statics carry no such cost and are Swift-6-clean: every writer is a SwiftUI
/// event handler and the only reader is the `@MainActor` debug seam.
@MainActor
enum KeyPressProbe {
    // MARK: `.onKeyPress` entry counters — one per real mount

    // ⚠️⚠️ TWO MOUNTS DELIBERATELY HAVE NO COUNTER, AND THAT IS A FINDING, NOT
    // A GAP. `DeleteKeySiteTests.arrangeRoutes` and `.rollRoutes` pin the EXACT
    // spelling of `ContentView`'s and `PianoRollView`'s delete mounts, so a
    // first-statement counter cannot be added to either without weakening a
    // shipped guard for scaffolding's sake.
    //
    // ⭐ THE SUBSTITUTE DISCRIMINATOR, AND IT IS EXACT: post the delete key on a
    // key code the MONITOR does not own (anything but 51/117) while carrying the
    // CHARACTER SwiftUI matches. `DeleteKeyMonitorRouting.decide`'s first guard
    // answers `.otherKey`, so the monitor can neither bump the funnel nor
    // swallow the event and SwiftUI gets it exactly as it would with no monitor
    // at all. `deleteKeyFunnelSeq` moving then means a delete mount fired, and
    // nothing else can produce it. (A ⇧ CHORD on key code 51 works too — the
    // monitor refuses `.chord` and returns the event — and was m23-fi's route;
    // the key-code route is preferred because it needs no modifier and so cannot
    // be confused with the separate question of whether chords should delete.)
    //
    /// `ContentView.ArrangeDeleteKey.onKeyPress(keys: [.leftArrow, .rightArrow])`.
    static var arrangeHorizontalArrow = 0
    /// `ContentView.ArrangeDeleteKey.onKeyPress(keys: [.upArrow, .downArrow])`.
    static var arrangeVerticalArrow = 0
    /// `AutomationLaneEditor.onKeyPress(.delete)` — ALL mounts, arrange and mixer.
    static var automationLaneDelete = 0
    /// `TimelineLanesView`'s marker rename field, `.onKeyPress(.escape)`.
    static var markerRenameEscape = 0
    /// `TrackListView`'s track rename field, `.onKeyPress(.escape)`.
    static var trackRenameEscape = 0

    // MARK: Focus ground truth — the `@FocusState` VALUES, not the assertions
    //
    // ⭐ THE READ THAT DECIDES THE FIX. `arrangeKeyFocusNonce` writes `true` into
    // `ArrangeDeleteKey.focused` on every clip click; whether that write STICKS
    // is invisible from outside the view. Two outcomes with two different fixes:
    //   • `false` while a clip is selected → focus was never granted, and
    //     repairing focus once lights up all five non-text mounts.
    //   • `true` while `debug.keySpace`'s `firstResponder` reads `none` → SwiftUI's
    //     focus bookkeeping is disconnected from the AppKit responder chain, and
    //     no assertion can fix it — monitors are then the architecture.

    /// `ArrangeDeleteKey.focused`, mirrored on every change.
    static var arrangeWorkspaceFocused = false
    /// Lane ids whose `AutomationLaneEditor.focused` is currently true. A SET
    /// because N lanes are mounted at once and a Bool would let the last one to
    /// report clobber the others.
    static var automationLanesFocused: Set<UUID> = []
    /// The marker rename field's `fieldFocused`.
    static var markerRenameFieldFocused = false
    /// The track rename field's `nameFieldFocused`.
    static var trackRenameFieldFocused = false

    /// Bumps `automationLanesFocused` for one lane. A helper rather than an
    /// inline `insert`/`remove` at the call site so the view keeps one line.
    static func reportAutomationLaneFocus(lane: UUID, focused: Bool) {
        if focused { automationLanesFocused.insert(lane) } else { automationLanesFocused.remove(lane) }
    }

    /// ⭐ THE ECHO↔STORAGE POSITIVE CONTROL (`debug.arrangeSelection
    /// {act:"probeSelfTest"}`). Bumps every counter by one so a probe can prove
    /// the seam reads the SAME variables the closures write. It does NOT prove a
    /// closure runs — nothing can, short of the key arriving — but it rules out
    /// the failure where a zero means "the echo is reading a different field",
    /// which looks identical to "the key never arrived".
    static func selfTestBumpAll() {
        arrangeHorizontalArrow += 1
        arrangeVerticalArrow += 1
        automationLaneDelete += 1
        markerRenameEscape += 1
        trackRenameEscape += 1
    }

    /// Every counter and focus mirror, as the debug echo's `keyPressProbe` object.
    static var echo: [String: JSONValue] {
        [
            "arrangeHorizontalArrow": .number(Double(arrangeHorizontalArrow)),
            "arrangeVerticalArrow": .number(Double(arrangeVerticalArrow)),
            "automationLaneDelete": .number(Double(automationLaneDelete)),
            "markerRenameEscape": .number(Double(markerRenameEscape)),
            "trackRenameEscape": .number(Double(trackRenameEscape)),
            "arrangeWorkspaceFocused": .bool(arrangeWorkspaceFocused),
            "automationLanesFocusedCount": .number(Double(automationLanesFocused.count)),
            "markerRenameFieldFocused": .bool(markerRenameFieldFocused),
            "trackRenameFieldFocused": .bool(trackRenameFieldFocused),
            // ⭐⭐ m23-fi — WHAT SWIFTUI'S OWN CONSTANTS ACTUALLY ARE, read out of
            // SwiftUI rather than asserted. The SDK's `.swiftinterface` declares
            // these as bare `public static let` with no initialiser, so the
            // literals are not readable from source at all; this is the only
            // primary source. It is what turns "measured: `.onKeyPress(.delete)`
            // matched 0x08 and not 0x7F" from a surprising observation into a
            // stated fact about the framework.
            "keyEquivalentScalars": .object([
                "delete": .number(Double(KeyEquivalent.delete.character.unicodeScalars.first?.value ?? 0)),
                "deleteForward": .number(
                    Double(KeyEquivalent.deleteForward.character.unicodeScalars.first?.value ?? 0)),
                "rightArrow": .number(
                    Double(KeyEquivalent.rightArrow.character.unicodeScalars.first?.value ?? 0)),
                "escape": .number(Double(KeyEquivalent.escape.character.unicodeScalars.first?.value ?? 0)),
            ]),
        ]
    }
}

/// The keys `debug.arrangeSelection {act:"postKey"}` can synthesize — the m23-fi
/// twin of `{act:"keyDelete", post:true}`, which is hard-wired to ⌦.
///
/// ⚠️ **CHARACTERS, NOT JUST KEY CODES.** SwiftUI matches `KeyEquivalent` on the
/// event's `characters`, so an arrow event carrying only `keyCode: 126` matches
/// nothing. The values below are AppKit's `NS*ArrowFunctionKey` constants, which
/// are what a real arrow key press carries. Key codes are the layout-independent
/// `kVK_*` values so the seam behaves identically on a non-US layout.
enum ProbeKey: String, CaseIterable {
    case left, right, up, down, escape
    /// ⌫. ⚠️ **NOT A DUPLICATE OF `{act:"keyDelete", post:true}`** — that branch
    /// hard-codes an EMPTY modifier set and five gates read its echo, so it must
    /// not grow a chord parameter. This one exists precisely to send a CHORDED
    /// delete, which is the only way to get past the m23-cf-3 monitor's `.chord`
    /// guard and see whether the three `.onKeyPress(.delete)` mounts are dead or
    /// merely SHADOWED by a monitor that swallows the key before SwiftUI sees it.
    case delete

    var keyCode: UInt16 {
        switch self {
        case .left: return 123    // kVK_LeftArrow
        case .right: return 124   // kVK_RightArrow
        case .down: return 125    // kVK_DownArrow
        case .up: return 126      // kVK_UpArrow
        case .escape: return 53   // kVK_Escape
        case .delete: return 51   // kVK_Delete
        }
    }

    var characters: String {
        switch self {
        case .up: return "\u{F700}"      // NSUpArrowFunctionKey
        case .down: return "\u{F701}"    // NSDownArrowFunctionKey
        case .left: return "\u{F702}"    // NSLeftArrowFunctionKey
        case .right: return "\u{F703}"   // NSRightArrowFunctionKey
        case .escape: return "\u{1B}"
        case .delete: return "\u{7F}"    // NSDeleteCharacter
        }
    }
}
