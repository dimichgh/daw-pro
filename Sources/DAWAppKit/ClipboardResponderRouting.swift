import Foundation

// m25-f-1 — THE ELIGIBILITY HALF OF ⌘X / ⌘C / ⌘V, and since m25-s ⌘A.
//
// ⚠️ THE FILE AND ITS TYPE ARE STILL NAMED "Clipboard" WHILE ONE OF THE FOUR
// SELECTORS IS NOT A CLIPBOARD VERB. Deliberate, and cheaper than the
// alternative: the rename would touch `ClipboardResponder`, three site tests
// that anchor on the type name, and the `debug.editClipboard` echo, to buy a
// better noun. `claimedSelectorNames` vs `clipboardSelectorNames` carries the
// distinction where it actually matters — in the code. Revisit if a THIRD
// non-clipboard selector is ever admitted.
//
// ═══ WHY THE RESPONDER CHAIN, AND NOT `.keyboardShortcut` ═══
//
// The user asked for the keystrokes 2026-08-12 ("copy/paste keybord shortcuts
// should also work based on track area for clips supporting group copy and
// pasting at playhead. In note editor we need the same"), reversing the
// menu-only ruling `ClipboardMenuPolicy`'s banner records. THE OUTCOME WAS
// AUTHORISED; THE MECHANISM WAS NOT, and one of the two available mechanisms is
// a regression:
//
//   • `CommandGroup { Button(…).keyboardShortcut("c", modifiers: .command) }`
//     creates a MENU KEY EQUIVALENT, which AppKit checks BEFORE the responder
//     chain. ⌘C typed into a track-rename field would then fire CLIP-COPY
//     instead of copying the text — the m17-d trap, transposed. BANNED.
//   • `cut:` / `copy:` / `paste:` on the RESPONDER CHAIN lights up the NATIVE
//     pasteboard items macOS already ships in the Edit menu. They are nil-target
//     items, so the FIRST responder that claims the selector wins: a focused
//     field editor keeps ⌘C for text, and our responder — spliced in AFTER the
//     window — only sees the verbs nothing else wanted. CHOSEN.
//
// ⚠️ NOT A SECOND POLICY. `ClipboardMenuPolicy` still decides which surface each
// verb acts on, what the item says and whether it is live; `AppModel
// .performMenuCut/Copy/Paste` still performs it. This file decides only "may a
// selector reach that policy, and where does the responder sit" — the m23-cf
// rule (one decision, many routes), and the same split
// `DeleteKeyMonitorRouting` makes against `DeleteMenuPolicy`.
//
// ═══ MEASURED, NOT REASONED — a standalone SwiftUI+AppKit probe, 2026-08-12 ═══
//
// Every claim below was measured in a throwaway app with this app's exact menu
// shape (`CommandGroup(after: .pasteboard)` over SwiftUI's own Edit menu):
//
//   P1  A responder spliced in at `window.nextResponder` IS found:
//         chain = AppKitWindow → ★ours → AppKitWindowController →
//                 AppKitApplication → AppDelegate
//       and `NSApp.target(forAction: "copy:")` returned ★ours.
//   P2  SwiftUI's Edit menu really does carry nil-target `cut:` ⌘X, `copy:` ⌘C,
//       `paste:` ⌘V, `delete:` (no equivalent) and `selectAll:` ⌘A.
//   P3  A title assigned from `validateMenuItem(_:)` STICKS on those
//       SwiftUI-owned items ("Copy 3 Clips" survived to display).
//   P4  WITH A FIELD EDITOR FOCUSED the target became `NSTextView` and our
//       `validateMenuItem` was NOT called at all — so text keeps ⌘C, and the
//       item cannot be re-titled by us in that state.
//   P5  DISPLAY RESETS THE TITLE. A deliberately stale "STALE-COUNT" planted on
//       the native Copy item read back as plain "Copy" after a display in the
//       field-editor state, and as "Copy 3 Clips" after a display in ours.
//   P6  `NSMenu.didBeginTrackingNotification` fires BEFORE the validation pass
//       (measured order: beginTracking:Edit → validate:cut: → validate:copy: →
//       validate:paste:), so it is a usable pre-display reset hook.
//   P7  The Edit menu's DELEGATE SLOT IS TAKEN (`AppKitMainMenuItem`) — SwiftUI
//       owns it. Do NOT set a menu delegate; use the notification (P6).
//
// ⭐⭐ P3–P6 ARE KEPT THOUGH THE APP NO LONGER USES WHAT THEY MEASURED, SO THAT
// NOBODY RE-MEASURES THEM. They were taken to answer "can the native items carry
// this app's counted titles?" — the answer is YES, both the assignment (P3) and
// the reset that keeps it honest (P5/P6) work. THE USER THEN RULED THE COUNTED
// TITLES OUT (2026-08-12: "we do not need to use copy 3 clips… use common logic
// and commonly adopted partice for such behavior"), so the native items now read
// the bare macOS word in every state, and the pre-display reset that existed only
// to un-write a counted title was deleted with it. THE CAPABILITY EXISTS AND IS
// DELIBERATELY UNUSED.
//
// ⚠️ P1, P2 AND P4 REMAIN LOAD-BEARING: they are why ⌘C reaches this app at all,
// and why it still copies TEXT in a rename field.

/// Which clipboard verb a responder-chain selector means, and where the
/// responder that claims those selectors belongs.
public enum ClipboardResponderRouting {

    // MARK: - The selectors we claim

    /// `cut:` — the native Edit ▸ Cut item's action (⌘X).
    public static let cutSelectorName = "cut:"
    /// `copy:` — the native Edit ▸ Copy item's action (⌘C).
    public static let copySelectorName = "copy:"
    /// `paste:` — the native Edit ▸ Paste item's action (⌘V).
    public static let pasteSelectorName = "paste:"
    /// `selectAll:` — the native Edit ▸ Select All item's action (⌘A). CLAIMED
    /// SINCE m25-s; see `claimedSelectorNames` for the decision that admitted it.
    public static let selectAllSelectorName = "selectAll:"

    /// The three CLIPBOARD selectors, in menu order — the subset that maps onto a
    /// `ClipboardVerb`.
    ///
    /// SPLIT OUT AT m25-s so `verb(forSelectorName:)`'s round-trip invariant
    /// ("every name here resolves to a verb, and every verb spells a name here")
    /// still has a set it holds over. It does NOT hold over
    /// `claimedSelectorNames` any more: `selectAll:` is claimed and is not a
    /// clipboard verb.
    public static let clipboardSelectorNames: [String] =
        [cutSelectorName, copySelectorName, pasteSelectorName]

    /// Exactly the selectors this app's Edit-menu responder implements, in menu
    /// order.
    ///
    /// ⚠️ **A LIST, SO THAT ADDING A FOURTH IS A DECISION RATHER THAN A DIFF.**
    ///
    /// ═══ THE FOURTH WAS ADDED 2026-08-13 (m25-s), AND HERE IS THE DECISION ═══
    ///
    /// THE USER ASKED FOR IT, VERBATIM: *"One small feature to add when in node
    /// editor and user uses keyboard shortcut \"select all\"/cmd+A - it should
    /// select all the notes in the editor"* ("node editor" = the piano roll).
    ///
    /// This entry previously read as an exclusion with two reasons. Both were
    /// good, and NEITHER WAS WITHDRAWN — one is now answered structurally and the
    /// other now BOUNDS the feature instead of blocking it:
    ///
    ///   1. *"⌘A inside a rename field must keep selecting TEXT."* ⭐ ANSWERED BY
    ///      THE MECHANISM, AND MEASURED FOR THIS SELECTOR RATHER THAN INHERITED.
    ///      P4 was taken for `copy:`; m25-s re-ran the same probe for
    ///      `selectAll:` and got the same answer — with a field editor focused
    ///      the target became `NSTextView` and our `validateMenuItem` was NOT
    ///      CALLED AT ALL (0 calls), with `copy:` alongside it as the positive
    ///      control. Text keeps ⌘A for free, exactly as it keeps ⌘C.
    ///   2. *"There is no arrange-wide 'select all clips' verb in this app yet,
    ///      and inventing one here would ship it through a keystroke nobody
    ///      reviewed."* ⭐⭐ STILL TRUE, STILL OBEYED, AND IT IS NOW THE FEATURE'S
    ///      SCOPE. `SelectAllMenuPolicy` returns a surface for the PIANO ROLL
    ///      ONLY and refuses everywhere else. No arrange-wide select-all was
    ///      invented; the user asked for the note editor and got the note editor.
    ///
    /// ⚠️ AND `delete:` IS STILL EXCLUDED — the exclusion this list was really
    /// protecting. The ⌫ key already routes through `DeleteKeyMonitorRouting` →
    /// `DeleteMenuPolicy` (m23-cf-3), and the Edit menu already carries our own
    /// Delete item. Claiming `delete:` would light a SECOND live Delete row
    /// beside it and put a second route into a fix the user confirmed by hand.
    /// Do not read m25-s as a precedent for it: `selectAll:` was admitted
    /// because NOTHING else in this app claims it (measured — see below), which
    /// is the opposite of `delete:`'s situation.
    ///
    /// ⭐ MEASURED 2026-08-13, AND IT IS WHY CLAIMING THIS COSTS NOTHING: with no
    /// responder claiming `selectAll:`, `NSApp.target(forAction:)` answered
    /// **nil** and the native Select All item was ALREADY DISABLED. Nothing
    /// behind our splice point implements it either —
    /// `class_getInstanceMethod(_, "selectAll:")` is nil on `NSResponder`,
    /// `NSWindow`, `NSWindowController` and `NSApplication`. So the item we take
    /// over was inert, and the app has no other ⌘A handler to displace.
    public static let claimedSelectorNames: [String] =
        clipboardSelectorNames + [selectAllSelectorName]

    /// Maps a responder-chain selector NAME onto the clipboard verb it performs,
    /// or nil when the selector is none of ours.
    ///
    /// STRING-KEYED, NOT `Selector`-KEYED, on purpose: `Selector` is an ObjC
    /// runtime type and this module is AppKit-free (`DAWAppKit` imports
    /// Foundation and CoreGraphics only) so that the whole decision stays
    /// testable headlessly. The app side converts once, at the boundary.
    ///
    /// ⚠️ THE COLON IS PART OF THE NAME. `"copy"` (no colon) is `NSObject.copy()`
    /// — a completely different, argument-less selector that every object in the
    /// process responds to. Matching it would claim a method AppKit calls for
    /// object duplication.
    ///
    /// ⚠️⚠️ **RETURNS nil FOR `selectAll:`, WHICH IS CLAIMED BUT IS NOT A
    /// CLIPBOARD VERB (m25-s).** A caller that treats nil as "not ours" is
    /// therefore WRONG since m25-s — it must dispatch on the selector FIRST and
    /// reach this only for the clipboard three. `ClipboardResponder
    /// .validateMenuItem` does exactly that, and the ordering is load-bearing:
    /// its old `else { return true }` fallback would leave a claimed Select All
    /// permanently ENABLED in every state while its action quietly did nothing.
    public static func verb(forSelectorName name: String) -> ClipboardVerb? {
        switch name {
        case cutSelectorName: return .cut
        case copySelectorName: return .copy
        case pasteSelectorName: return .paste
        default: return nil
        }
    }

    // MARK: - What the native item says

    /// The BARE macOS word for a verb — and since 2026-08-12 the ONLY thing a
    /// native pasteboard item ever reads, in every state.
    ///
    /// ⭐⭐ **THE USER RULED OUT COUNTED TITLES IN THE EDIT MENU:** *"we do not
    /// need to use copy 3 clips, it should just copy anything selected to the
    /// copy buffer and when pasted, it should use paste behavior of what is being
    /// copied. use common logic and commonly adopted partice for such
    /// behavior."* A plain "Copy", greyed when unavailable, IS that commonly
    /// adopted practice.
    ///
    /// ⚠️ NOT A TEACHING TITLE EITHER ("Copy Selection" and its two siblings were
    /// deleted in the same ruling — see `ClipboardMenuPolicy`).
    public static func plainTitle(for verb: ClipboardVerb) -> String { verb.word }

    /// What the native item should read, and whether it should be clickable,
    /// once `ClipboardMenuPolicy` has resolved the verb.
    ///
    /// ⚠️⚠️ **THE TITLE COMES FROM THE VERB, THE ENABLED STATE FROM THE POLICY —
    /// AND THAT SPLIT IS THE WHOLE POINT OF THIS FUNCTION.** `item.title` is
    /// deliberately ignored: the policy still computes "Copy 3 Clips" for the
    /// `debug.editClipboard` echo, and rendering it here is exactly what the user
    /// ruled against. What the policy DOES decide is whether the item is live,
    /// and that is unchanged — the ruling was about what the item SAYS, never
    /// about what it does or when it can be used.
    ///
    /// ⭐ RECORDED SO NOBODY RE-MEASURES IT: a counted title on these native
    /// items WORKS (P3/P5 — measured, both the assignment and the reset). The
    /// capability exists and is deliberately unused.
    public static func presentation(for item: ClipboardMenuItem) -> ClipboardItemPresentation {
        ClipboardItemPresentation(title: plainTitle(for: item.verb), isEnabled: item.isEnabled)
    }

    /// What the native Edit ▸ Select All item should read, and whether it should
    /// be clickable, once `SelectAllMenuPolicy` has resolved it (m25-s).
    ///
    /// SAME SHAPE AS ITS CLIPBOARD TWIN — title from the item, enabled state from
    /// the policy — so `ClipboardResponder.validateMenuItem` renders both
    /// branches identically and neither can grow a hand-built string. The title
    /// here is the bare "Select All" in every state; `SelectAllMenuPolicy.title`
    /// carries the user's ruling that put it there.
    public static func presentation(for item: SelectAllMenuItem) -> ClipboardItemPresentation {
        ClipboardItemPresentation(title: item.title, isEnabled: item.isEnabled)
    }

    // MARK: - Where the responder sits

    /// What installing the clipboard responder into a window should do.
    ///
    /// - Parameters:
    ///   - hasWindow: the app's content window exists (false headless, and
    ///     before the WindowGroup's first appearance).
    ///   - windowNextResponderIsOurs: the window's `nextResponder` is already the
    ///     app's clipboard responder.
    public static func chainInstall(hasWindow: Bool,
                                    windowNextResponderIsOurs: Bool) -> ClipboardChainInstall {
        guard hasWindow else { return .noWindow }
        return windowNextResponderIsOurs ? .alreadyInstalled : .insert
    }
}

/// What a native pasteboard menu item should show.
public struct ClipboardItemPresentation: Equatable, Sendable {
    /// The title to assign — never a hand-built string, always the policy's.
    public var title: String
    /// Whether the item is clickable (and its key equivalent live).
    public var isEnabled: Bool

    public init(title: String, isEnabled: Bool) {
        self.title = title
        self.isEnabled = isEnabled
    }
}

/// The outcome of an install attempt for the clipboard responder.
///
/// NAMED RATHER THAN A `Bool`, for `DeleteKeyMonitorRefusal`'s reason: "did not
/// install" has two completely different causes here — no window yet (expected,
/// headless and at launch) versus already installed (expected, on every
/// re-assert) — and a test that meant to prove idempotency would pass
/// identically against an install that never runs.
public enum ClipboardChainInstall: String, Equatable, Sendable, CaseIterable {
    /// No content window yet: nothing to splice into. Headless, and before the
    /// window's first appearance.
    case noWindow = "no-window"
    /// The window's `nextResponder` is already ours — the re-assert path. MUST
    /// NOT splice again: doing so would set our own `nextResponder` to
    /// ourselves and hang every responder-chain walk in the process.
    case alreadyInstalled = "already-installed"
    /// Splice in: our responder takes the window's `nextResponder` slot, and the
    /// window's PREVIOUS next responder becomes ours — so nothing downstream of
    /// the window (the window controller, NSApp, the app delegate) is cut off.
    case insert
}
