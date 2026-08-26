import Testing
@testable import DAWAppKit

/// m25-f-1 — the ELIGIBILITY half of ⌘X / ⌘C / ⌘V.
///
/// `ClipboardMenuPolicyTests` already pins WHAT each verb does and what it says.
/// This suite pins the three things the responder route adds: which selectors the
/// app may claim, what a native item reads when this app is NOT the one
/// performing it, and where the responder is spliced into the chain.
///
/// ⚠️ **NONE OF THIS CAN SEE A KEYSTROKE** (the m23-g1 law): an unbundled binary
/// routes no real key events, so ⌘C itself is a human check on a bundled
/// `dist/DAWPro.app`. What IS testable is every decision made before the event
/// arrives — and those are the ones that turn a working keystroke into a
/// regression if they drift.
@Suite("Clipboard responder routing (m25-f-1)")
struct ClipboardResponderRoutingTests {

    // MARK: - Which selectors we claim

    @Test("The three pasteboard selectors map to their verbs")
    func selectorsMapToVerbs() {
        #expect(ClipboardResponderRouting.verb(forSelectorName: "cut:") == .cut)
        #expect(ClipboardResponderRouting.verb(forSelectorName: "copy:") == .copy)
        #expect(ClipboardResponderRouting.verb(forSelectorName: "paste:") == .paste)
    }

    /// ⚠️ THE NEGATIVE CASES ARE THE POINT — each names a real defect.
    ///
    /// `delete:` would put a SECOND live Delete row in the Edit menu and a second
    /// route into the ⌫ fix the user confirmed by hand on 2026-08-12.
    /// `pasteAsPlainText:` is a TEXT verb with no meaning for clips. And `copy`
    /// WITHOUT THE COLON is `NSObject.copy()` — an argument-less selector every
    /// object in the process responds to, which a name-based matcher can claim by
    /// accident.
    ///
    /// ⚠️ `selectAll:` IS STILL HERE AND ITS MEANING CHANGED AT m25-s. It is now
    /// CLAIMED by the responder (⌘A selects the roll's notes) but it is still not
    /// a CLIPBOARD VERB, so this mapper must still answer nil for it. That gap is
    /// exactly why `ClipboardResponder.validateMenuItem` dispatches on the
    /// selector before reaching this function — see
    /// `ClipboardResponderSiteTests.selectAllIsDispatchedBeforeTheVerbLookup`.
    @Test("Neighbouring selectors are refused, including the colon-less one")
    func neighbouringSelectorsAreRefused() {
        for name in ["delete:", "selectAll:", "pasteAsPlainText:", "copy", "cut",
                     "paste", "undo:", "redo:", "", "copy::"] {
            #expect(ClipboardResponderRouting.verb(forSelectorName: name) == nil,
                    "\(name) must not resolve to a clipboard verb")
        }
    }

    /// ⭐ SPLIT AT m25-s. `claimedSelectorNames` is what the responder IMPLEMENTS
    /// (four since ⌘A); `clipboardSelectorNames` is the subset that maps onto a
    /// `ClipboardVerb`, and the round-trip invariant holds over that.
    @Test("The claimed list is the clipboard three plus select-all, in menu order")
    func claimedListIsPinned() {
        #expect(ClipboardResponderRouting.clipboardSelectorNames == ["cut:", "copy:", "paste:"])
        #expect(ClipboardResponderRouting.claimedSelectorNames
                == ["cut:", "copy:", "paste:", "selectAll:"])
        // Every CLIPBOARD name must resolve — a list entry the mapper does not
        // know would be a selector the responder implements and then ignores.
        for name in ClipboardResponderRouting.clipboardSelectorNames {
            #expect(ClipboardResponderRouting.verb(forSelectorName: name) != nil)
        }
        // …and every verb must be claimed, so a fourth verb cannot be added to
        // the policy while quietly having no keystroke.
        for verb in ClipboardVerb.allCases {
            #expect(ClipboardResponderRouting.clipboardSelectorNames.contains("\(verb.rawValue):"))
            #expect(ClipboardResponderRouting.claimedSelectorNames.contains("\(verb.rawValue):"))
        }
        // ⚠️ `delete:` STAYS OUT — m25-s admitted `selectAll:` and is not a
        // precedent for it.
        #expect(!ClipboardResponderRouting.claimedSelectorNames.contains("delete:"))
    }

    // MARK: - What the native item says

    /// The bare macOS word, in every state.
    ///
    /// ⭐ THE USER'S 2026-08-12 RULING, PINNED: *"we do not need to use copy 3
    /// clips… use common logic and commonly adopted partice for such
    /// behavior."* A plain "Copy", greyed when unavailable, is that practice.
    @Test("The native item's title is the bare macOS word")
    func plainTitleIsTheBareWord() {
        #expect(ClipboardResponderRouting.plainTitle(for: .cut) == "Cut")
        #expect(ClipboardResponderRouting.plainTitle(for: .copy) == "Copy")
        #expect(ClipboardResponderRouting.plainTitle(for: .paste) == "Paste")
        for verb in ClipboardVerb.allCases {
            #expect(ClipboardResponderRouting.plainTitle(for: verb) == verb.word)
        }
    }

    /// ⚠️⚠️ **THE PIN THE USER'S CORRECTION IS ABOUT.** The policy still resolves
    /// a COUNTED title for the `debug.editClipboard` echo — and the Edit menu
    /// must not show it. If this ever reads "Copy 3 Clips" again, the item is
    /// rendering `ClipboardMenuItem.title`, which is exactly what was ruled out.
    @Test("A live item renders the PLAIN word, not the policy's counted title")
    func livePresentationDropsTheCount() {
        let item = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0, arrangeClipCount: 3)
        // The policy's own answer still counts — this is the negative control
        // that keeps the assertion below from passing vacuously.
        #expect(item.title == "Copy 3 Clips")
        let presentation = ClipboardResponderRouting.presentation(for: item)
        #expect(presentation.title == "Copy")
        #expect(presentation.isEnabled)
    }

    /// A refused item is a GREYED PLAIN WORD — no teaching string. The refusal is
    /// still carried (`refusedBy`), because the echo and the tests need to tell
    /// an empty selection from a closed roll.
    @Test("A refused item renders the plain word, disabled")
    func refusedPresentationIsThePlainWord() {
        let item = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0, arrangeClipCount: 0)
        let presentation = ClipboardResponderRouting.presentation(for: item)
        #expect(item.refusedBy == .emptySelection)
        #expect(presentation.title == "Copy")
        #expect(!presentation.isEnabled)
    }

    /// Paste is resolved on the CLIPBOARD'S KIND rather than on a selection, so
    /// its ENABLEMENT must come from the paste policy — routing it through Copy's
    /// body would compile and answer a different question. Its title is the plain
    /// word either way, which is why enablement is the only thing worth asserting.
    @Test("Paste's enablement comes from its own policy; its title stays plain")
    func pasteEnablementComesFromThePastePolicy() {
        let live = ClipboardResponderRouting.presentation(for: ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .notes, clipCount: 0, noteCount: 2, arrangeWorkspace: true,
            isModalPresented: false, rollOpen: true, trackCount: 1))
        #expect(live.title == "Paste")
        #expect(live.isEnabled)

        let empty = ClipboardResponderRouting.presentation(for: ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: nil, clipCount: 0, noteCount: 0, arrangeWorkspace: true,
            isModalPresented: false, rollOpen: true, trackCount: 1))
        #expect(empty.title == "Paste")
        #expect(!empty.isEnabled)

        // ⭐ THE CONFIRMATION OF "paste behavior of what is being copied": the
        // clipboard's KIND alone picks the destination surface — notes can only
        // go in a roll, clips only in the arrange — so a paste never has to
        // arbitrate between surfaces.
        let notes = ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .notes, clipCount: 0, noteCount: 2, arrangeWorkspace: true,
            isModalPresented: false, rollOpen: true, trackCount: 1)
        let clips = ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .clips, clipCount: 2, noteCount: 0, arrangeWorkspace: true,
            isModalPresented: false, rollOpen: true, trackCount: 1)
        #expect(notes.surface == .pianoRollNotes)
        #expect(clips.surface == .arrangeClips)
    }

    /// The states where the app must NOT own ⌘C at all — a modal is up, or the
    /// user is in the Mix console. The native item must go grey, which is what
    /// stops the keystroke acting on a surface the user is not looking at.
    @Test("Refusals reach the native item as a disabled state")
    func refusalsDisableTheNativeItem() {
        let behindModal = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: true,
            pianoRollHasNoteSelection: true, automationPointCount: 0, arrangeClipCount: 3)
        #expect(!ClipboardResponderRouting.presentation(for: behindModal).isEnabled)

        let inMixer = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: false, isModalPresented: false,
            pianoRollHasNoteSelection: true, automationPointCount: 0, arrangeClipCount: 3)
        #expect(!ClipboardResponderRouting.presentation(for: inMixer).isEnabled)
    }

    // MARK: - Where the responder sits

    @Test("No window: nothing to splice into")
    func chainInstallHeadless() {
        #expect(ClipboardResponderRouting.chainInstall(
            hasWindow: false, windowNextResponderIsOurs: false) == .noWindow)
        // A window that does not exist cannot already hold us, but the guard
        // order must not let that combination answer "already installed".
        #expect(ClipboardResponderRouting.chainInstall(
            hasWindow: false, windowNextResponderIsOurs: true) == .noWindow)
    }

    @Test("A fresh window is spliced; an installed one is left alone")
    func chainInstallIsIdempotent() {
        #expect(ClipboardResponderRouting.chainInstall(
            hasWindow: true, windowNextResponderIsOurs: false) == .insert)
        // ⚠️ THE TEETH: splicing twice would set our own `nextResponder` to
        // ourselves and hang every responder-chain walk in the process — a
        // freeze, not a missing menu item.
        #expect(ClipboardResponderRouting.chainInstall(
            hasWindow: true, windowNextResponderIsOurs: true) == .alreadyInstalled)
    }
}
