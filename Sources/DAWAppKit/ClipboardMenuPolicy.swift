import Foundation

/// The ONE home for the question "what do the COPY / CUT / PASTE **menu items**
/// act on, what do they say, and are they live?" (m23-ek-3).
///
/// A SIBLING OF `DeleteMenuPolicy`, NOT AN EXTENSION OF IT. That type's doc
/// declares it "The ONE home for the question *what does a DELETE menu item act
/// on*"; copy/cut/paste is a different question with a larger answer set, and a
/// file that owns two questions is how a home stops being one. The two are
/// cross-referenced instead, and the ONE thing they genuinely share — the plural
/// rule — was hoisted into `EditMenuTitles` so neither owns it.
///
/// ⚠️⚠️ **NO ⌘C / ⌘X / ⌘V IN v1, AND THAT IS THE USER'S OWN RULING**, given
/// after being shown the tradeoff. It is not a default and must not be
/// "improved" later without re-asking them. Two independent reasons stand
/// behind it:
///
///   • **THE m17-d HAZARD, TRANSPOSED.** `Button("Copy 3 Clips") { … }
///     .keyboardShortcut("c", modifiers: .command)` inside a `CommandGroup`
///     creates a menu item whose key equivalent is ⌘C and whose action is our
///     closure — and menu key equivalents are checked BEFORE the responder
///     chain. So ⌘C typed in a rename field would fire CLIP-COPY instead of
///     copying the text. That is exactly the trap `DeleteMenuPolicy`'s banner
///     records, pointing the other way: there, Backspace would be stolen FROM
///     text fields; here, ⌘C would be. **The hazard belongs to the SHORTCUT,
///     not to the ITEM** — which is the distinction that makes this whole
///     menu-only route possible.
///   • **THE DECISIVE ONE — A KEY EQUIVALENT CANNOT BE VERIFIED BY ANY GATE IN
///     THIS TREE** (the m23-g1 law, recorded on `ExportMenuPolicy.swift:17-33`
///     and again on `FileCommands.swift:47-55`): an unbundled staging binary
///     does not route real key events, so a key equivalent is invisible to the
///     entire gate corpus and could only ever be checked by a `dist/DAWPro.app`
///     rebuild plus hands on a keyboard, every time, forever. A menu item with
///     no key equivalent is fully testable. That asymmetry, not taste, is why
///     every recent menu item in this app ships without one.
///
/// The macOS-correct end state is to implement `copy:` / `cut:` / `paste:` on
/// the RESPONDER CHAIN so the NATIVE pasteboard items go live per surface —
/// which adds the keystrokes WITHOUT creating a `CommandGroup` key equivalent
/// that outranks text fields. It is a separate item, and its precondition is
/// m23-cf's undiagnosed DELETE key being diagnosed first: `FileCommands.swift`
/// and `docs/ROADMAP.md` both already forbid building a second keyboard
/// consumer on top of an unexplained keyboard-delivery bug.
///
/// ⚠️ THE INERT TITLES ("Copy", "Cut", "Paste") DO COLLIDE with macOS's own
/// pasteboard items, and unlike Delete's collision that one is not avoidable by
/// renaming — these ARE the words. It is tolerable for the same reason
/// `DeleteMenuPolicy.swift:40-48` keeps both Deletes: the native items come
/// alive inside a TEXT FIELD and act on TEXT; ours act on the user's OBJECTS.
/// With a rename field open the Edit menu honestly offers both, and what carries
/// the disambiguation is the LIVE title ("Copy 3 Clips"), exactly as it does
/// there.
///
/// WHY IN DAWAppKit: `DAWApp` has no test target, so a menu policy written there
/// is unverifiable by the Swift suite. Everything that DECIDES lives here;
/// `DAWApp` keeps only composition.
public enum ClipboardMenuPolicy {

    /// What Edit ▸ Copy / Cut / Paste say when they are greyed.
    ///
    /// ⚠️ **NOT BARE — and the earlier "bare, per `DeleteMenuPolicy`" comment
    /// here MISQUOTED that precedent, which says the opposite.** `DeleteMenuPolicy`
    /// uses `"Delete Selection"`, and its own reasoning is that the noun *teaches
    /// the thing the disabled state exists to teach: the operation is here, and it
    /// wants a selection.*
    ///
    /// The concrete defect bare titles cause here: this group mounts with
    /// `CommandGroup(after: .pasteboard)`, so AppKit's native Cut / Copy / Paste
    /// stay above ours. With nothing selected and an empty clipboard, bare titles
    /// render the Edit menu as **six near-identical greyed rows** — Cut, Copy,
    /// Paste, Cut, Copy, Paste — where the user cannot tell which pair is which,
    /// and neither pair explains what it is waiting for.
    ///
    /// ⚠️ **`CommandGroup(replacing: .pasteboard)` IS NOT THE FIX AND MUST NOT BE
    /// USED.** The native items are the ones the responder chain wires to text
    /// editing; replacing the group strips Cut/Copy/Paste from every rename field
    /// in the app — the m17-d hazard one family over. Keep both pairs; make OURS
    /// legible. The LIVE titles ("Copy 3 Clips") already disambiguate, so only the
    /// inert case ever needed this.
    public static let inertCopyTitle = "Copy Selection"
    /// See `inertCopyTitle` — same rule, same reason.
    public static let inertCutTitle = "Cut Selection"
    /// See `inertCopyTitle`. The object differs because the wait differs: Copy and
    /// Cut want a SELECTION, Paste wants something ON THE CLIPBOARD, and the title
    /// should say which is missing.
    public static let inertPasteTitle = "Paste Clipboard"

    // MARK: - Edit ▸ Copy / Edit ▸ Cut

    /// Resolves the Edit-menu Copy (or Cut) item: which surface it targets, what
    /// it says, and whether it is live.
    ///
    /// ═══ THE ARBITRATION IS `DeleteMenuPolicy.editMenuItem`'s, VERBATIM ═══
    ///
    /// Same order, same terms, same reasons (`DeleteMenuPolicy.swift:59-114`) —
    /// which is itself this app's own FOCUS-FREE expression of what the DELETE
    /// key already does:
    ///
    ///   1. `workspaceMode == .arrange` — the Mix console has no clip selection.
    ///   2. `!isModalPresented` — no acting behind a scrimmed panel.
    ///   3. THE PIANO ROLL WOULD HAVE CONSUMED IT — the roll is on screen AND
    ///      holds a note selection. Read from `AppModel.pianoRollWouldConsumeKey`,
    ///      the SAME property the nudge guard and the Delete item read, never a
    ///      second spelling.
    ///   4. AN AUTOMATION LANE WOULD HAVE CONSUMED IT.
    ///   5. Otherwise the ARRANGE owns it, if anything is selected.
    ///
    /// ⚠️ **AUTOMATION POINTS ARE OUT OF SCOPE FOR THE CLIPBOARD IN v1, AND
    /// STEP 4 THEREFORE REFUSES RATHER THAN FALLING THROUGH.** That is the
    /// honest behaviour and it is a deliberate choice over the two alternatives.
    /// Dropping the term entirely would make Copy act on the ARRANGE while the
    /// user has breakpoints selected — silently copying a surface they were not
    /// pointing at, and disagreeing with Delete about what the same selection
    /// means. Implementing breakpoint copy is a later item. Refusing keeps this
    /// item's precedence IDENTICAL to Delete's, which is the property that makes
    /// both explainable in one sentence.
    ///
    /// ⚠️ `isArrangeTextEditingFocused` IS DELIBERATELY NOT A TERM, carrying
    /// `DeleteMenuPolicy`'s two reasoned divergences unchanged. (a) What it
    /// guards cannot happen here: it exists so a Backspace typed into a rename
    /// field cannot reach the clips — an ambiguity of KEY DELIVERY — and these
    /// items have no key equivalent at all. (b) Including it would make the item
    /// LIE: the responder classifier reads `NSApp.keyWindow.firstResponder`,
    /// which is NOT observable, so a `Commands` body has no reason to
    /// re-evaluate when focus enters or leaves a text field, and the enabled
    /// state would be computed from whenever the body last ran. Every OTHER term
    /// here is `@Observable`, so the item cannot go stale; that one term would
    /// break the property.
    ///
    /// - Parameters:
    ///   - verb: `.copy` or `.cut`. The ONLY difference between the two items is
    ///     this word and what the action does afterwards — resolving both through
    ///     one function is what stops Cut's enablement drifting from Copy's, when
    ///     the whole point is that Cut is Copy plus the delete that already ships.
    ///   - arrangeWorkspace: `workspaceMode == .arrange`.
    ///   - isModalPresented: a blocking modal is on screen.
    ///   - pianoRollHasNoteSelection: `AppModel.pianoRollWouldConsumeKey`.
    ///   - automationPointCount: `automationPointSelection.lanesWithSelection.count`.
    ///   - arrangeClipCount: `arrangeSelection.count`.
    public static func copyMenuItem(
        verb: ClipboardVerb,
        arrangeWorkspace: Bool,
        isModalPresented: Bool,
        pianoRollHasNoteSelection: Bool,
        automationPointCount: Int,
        arrangeClipCount: Int
    ) -> ClipboardMenuItem {
        guard arrangeWorkspace else { return ClipboardMenuItem(verb: verb, refusedBy: .workspace) }
        guard !isModalPresented else { return ClipboardMenuItem(verb: verb, refusedBy: .modal) }
        if pianoRollHasNoteSelection {
            // NO COUNT, ON PURPOSE, and this is the ASYMMETRY WITH PASTE below —
            // say so or somebody will "fix" it. `PianoRollNoteSelectionBridge`
            // publishes a BOOL, not a count, because its report fires on the
            // empty ↔ non-empty transition only; keying it on `count` would
            // rewrite a keyboard-gating observable to fire on every pointer
            // update of a note marquee, which is a correctness regression for
            // that gate and not merely a performance one. A title claiming
            // "Copy 3 Notes" from a number this policy does not have would be
            // the honesty violation the design language forbids. The ROLL'S OWN
            // context menu, which can see `model.selection.count` directly, does
            // carry the count.
            return ClipboardMenuItem(verb: verb,
                                     title: "\(verb.word) Selected Notes",
                                     surface: .pianoRollNotes)
        }
        guard automationPointCount == 0 else {
            return ClipboardMenuItem(verb: verb, refusedBy: .automationSelection)
        }
        guard arrangeClipCount > 0 else {
            return ClipboardMenuItem(verb: verb, refusedBy: .emptySelection)
        }
        return ClipboardMenuItem(
            verb: verb,
            title: EditMenuTitles.counted(verb: verb.word, count: arrangeClipCount,
                                          singular: "Clip", plural: "Clips"),
            surface: .arrangeClips)
    }

    // MARK: - Edit ▸ Paste

    /// Resolves the Edit-menu Paste item.
    ///
    /// ⚠️ **PASTE IS A GENUINELY DIFFERENT QUESTION AND IS NOT ROUTED ON THE
    /// DELETE STACK.** Its enablement depends on the CLIPBOARD, not on a
    /// selection — you can paste with nothing selected at all, and the Delete
    /// precedence stack has no term for that. So the routing is: **clipboard
    /// KIND first, then the surface that kind requires.**
    ///
    /// WHY KIND AND NOT ENGAGEMENT. `AppModel` explicitly rejects
    /// `activeEditorSurface` for Delete — engagement answers "which editor did
    /// the user last ENGAGE", which comes apart from "which surface would
    /// CONSUME this". For paste the discriminator is simpler and more honest
    /// still: **notes can only go in a roll and clips can only go in the
    /// arrange**, so the payload determines the surface with no ambiguity left
    /// to arbitrate. `EditorSurfaceEngagement.lastEngaged` is deliberately
    /// unused here; reach for it only if a case is found that kind alone cannot
    /// resolve.
    ///
    /// EVERY INPUT IS `@Observable` (`EditClipboard.payload`, `workspaceMode`,
    /// `isModalPresented`, `openEditorClip`, `store.tracks`), so the item cannot
    /// go stale — the property `deleteMenuItem`'s doc calls load-bearing. A
    /// Paste still greyed after a successful Copy is precisely the staleness a
    /// user cannot diagnose.
    ///
    /// - Parameters:
    ///   - clipboardKind: `EditClipboard.kind`.
    ///   - clipCount: `EditClipboard.clipCount` — for the title only.
    ///   - noteCount: `EditClipboard.noteCount` — for the title only. ⚠️ PASTE
    ///     **CAN** NAME THE NOTE COUNT even though Copy cannot: the number comes
    ///     from the CLIPBOARD, which this policy holds, not from the bridge that
    ///     publishes a Bool. The asymmetry is correct; do not "fix" it.
    ///   - arrangeWorkspace: `workspaceMode == .arrange`.
    ///   - isModalPresented: a blocking modal is on screen.
    ///   - rollOpen: `openEditorClip != nil`. Note this is the ROLL BEING ON
    ///     SCREEN, not the roll holding a selection — a note paste needs a
    ///     destination clip, not a note selection.
    ///   - trackCount: `store.tracks.count`. A clip paste into a project with no
    ///     tracks has nowhere to go; refusing here means the user is told, rather
    ///     than clicking a live item that silently does nothing.
    public static func pasteMenuItem(
        clipboardKind: ClipboardKind?,
        clipCount: Int,
        noteCount: Int,
        arrangeWorkspace: Bool,
        isModalPresented: Bool,
        rollOpen: Bool,
        trackCount: Int
    ) -> ClipboardMenuItem {
        let verb = ClipboardVerb.paste
        guard let clipboardKind else {
            return ClipboardMenuItem(verb: verb, refusedBy: .emptyClipboard)
        }
        guard arrangeWorkspace else { return ClipboardMenuItem(verb: verb, refusedBy: .workspace) }
        guard !isModalPresented else { return ClipboardMenuItem(verb: verb, refusedBy: .modal) }
        switch clipboardKind {
        case .notes:
            guard rollOpen else { return ClipboardMenuItem(verb: verb, refusedBy: .noRollOpen) }
            return ClipboardMenuItem(
                verb: verb,
                title: EditMenuTitles.counted(verb: verb.word, count: noteCount,
                                              singular: "Note", plural: "Notes"),
                surface: .pianoRollNotes)
        case .clips:
            guard trackCount > 0 else { return ClipboardMenuItem(verb: verb, refusedBy: .noTracks) }
            return ClipboardMenuItem(
                verb: verb,
                title: EditMenuTitles.counted(verb: verb.word, count: clipCount,
                                              singular: "Clip", plural: "Clips"),
                surface: .arrangeClips)
        }
    }

    // MARK: - The arrange clip context menu

    /// What a right-click Copy / Cut on ONE arrange clip targets, and what it
    /// says — `DeleteMenuPolicy.clipContextCommand`'s twin, and deliberately the
    /// same rule.
    ///
    /// THE RULE, which is the Finder/DAW convention and the one that cannot
    /// surprise: right-clicking a clip that IS part of the current selection
    /// acts on the WHOLE selection (you selected three, you asked to copy, you
    /// meant three); right-clicking a clip that is NOT selected acts on that
    /// clip alone and leaves the selection untouched (you pointed at one thing).
    ///
    /// NEVER DISABLED, for the same reason: a clip context menu only exists
    /// because the pointer is over a clip, so there is always exactly one
    /// unambiguous target.
    public static func clipContextCommand(verb: ClipboardVerb,
                                          clickedClipIsSelected: Bool,
                                          arrangeSelectionCount: Int) -> ClipboardContextCommand {
        // `clickedClipIsSelected` with a count of 0 violates `ArrangeSelection`'s
        // INV2 and cannot occur — resolved to the clicked clip rather than
        // trusted, so a future caller bug degrades to "act on the one you pointed
        // at" instead of an empty no-op.
        guard clickedClipIsSelected, arrangeSelectionCount > 0 else {
            return ClipboardContextCommand(title: "\(verb.word) Clip", targetsWholeSelection: false)
        }
        return ClipboardContextCommand(
            title: EditMenuTitles.counted(verb: verb.word, count: arrangeSelectionCount,
                                          singular: "Clip", plural: "Clips"),
            targetsWholeSelection: true)
    }

    // MARK: - The piano-roll note context menu

    /// The roll's own right-click Copy / Cut title.
    ///
    /// SELECTION-BASED, NOT LOCATION-BASED — `DeleteMenuPolicy.noteContextTitle`'s
    /// decision, verbatim and for its reasons: SwiftUI's `.contextMenu` hands the
    /// builder no click location and the roll's notes are drawn into a single
    /// `Canvas`, so "copy the note under the pointer" would need hover tracking
    /// AND a second targeting policy. Mirroring the selection means the roll's
    /// menu and the Edit menu can never disagree about what Copy means here.
    ///
    /// COUNTED, unlike the Edit-menu note title, and that is not an
    /// inconsistency: this builder runs inside the roll and can read
    /// `model.selection.count` directly, where the Edit menu can only see the
    /// bridge's Bool.
    ///
    /// Zero returns a plural title for a DISABLED item: the menu still appears,
    /// greyed, so a user who right-clicks without selecting learns that the
    /// operation exists and needs a selection.
    public static func noteContextTitle(verb: ClipboardVerb, selectedNoteCount: Int) -> String {
        guard selectedNoteCount > 0 else { return "\(verb.word) Notes" }
        return EditMenuTitles.counted(verb: verb.word, count: selectedNoteCount,
                                      singular: "Note", plural: "Notes")
    }

    /// The roll's own right-click Paste title — counted from the CLIPBOARD (see
    /// `pasteMenuItem`'s note on the asymmetry).
    public static func notePasteContextTitle(noteCount: Int) -> String {
        guard noteCount > 0 else { return inertPasteTitle }
        return EditMenuTitles.counted(verb: ClipboardVerb.paste.word, count: noteCount,
                                      singular: "Note", plural: "Notes")
    }
}

/// Which of the three clipboard operations an item is.
///
/// CARRIES ITS OWN MENU WORD so the verb and its title can never disagree, and
/// so `copyMenuItem` can resolve Copy and Cut through one body — the property
/// that keeps Cut's enablement from drifting from Copy's when Cut is defined as
/// "Copy, plus the delete that already ships".
public enum ClipboardVerb: String, Sendable, CaseIterable, Equatable {
    case copy
    case cut
    case paste

    /// The word the menu shows. Capitalised here rather than at each call site.
    public var word: String {
        switch self {
        case .copy: return "Copy"
        case .cut: return "Cut"
        case .paste: return "Paste"
        }
    }

    /// The bare title a DISABLED item of this verb shows.
    public var inertTitle: String {
        switch self {
        case .copy: return ClipboardMenuPolicy.inertCopyTitle
        case .cut: return ClipboardMenuPolicy.inertCutTitle
        case .paste: return ClipboardMenuPolicy.inertPasteTitle
        }
    }
}

/// Which surface a clipboard operation acts on.
///
/// TWO CASES, NOT `DeleteSurface`'s THREE, and that is the type-level statement
/// that AUTOMATION BREAKPOINTS ARE OUT OF SCOPE IN v1. Reusing `DeleteSurface`
/// would have compiled while quietly implying a `.automationPoints` branch that
/// does not exist; a distinct sum type makes the omission a decision the
/// compiler enforces rather than a gap a reader has to notice.
public enum ClipboardSurface: String, Sendable, CaseIterable, Equatable {
    case pianoRollNotes = "piano-roll-notes"
    case arrangeClips = "arrange-clips"
}

/// WHY a clipboard menu item is inert, named for the guard that refused.
///
/// Carried on the disabled item rather than discarded, for `DeleteMenuRefusal`'s
/// reason: a bare `isEnabled == false` cannot tell a test that meant to prove
/// the EMPTY-CLIPBOARD guard from one whose roll had quietly closed, which is
/// how a dead policy passes a refusal-only suite.
public enum ClipboardMenuRefusal: String, Sendable, CaseIterable, Equatable {
    case workspace
    case modal
    /// Copy/Cut only — a live automation-breakpoint selection. See
    /// `copyMenuItem`'s banner: refusing is honest, falling through would copy a
    /// surface the user was not pointing at.
    case automationSelection = "automation-selection"
    /// Copy/Cut only — nothing is selected on any surface this can act on.
    case emptySelection = "empty-selection"
    /// Paste only — nothing has been copied or cut yet.
    case emptyClipboard = "empty-clipboard"
    /// Paste only — the clipboard holds notes and no roll is on screen to put
    /// them in.
    case noRollOpen = "no-roll-open"
    /// Paste only — the clipboard holds clips and the project has no tracks.
    case noTracks = "no-tracks"
}

/// A resolved Edit-menu clipboard item.
public struct ClipboardMenuItem: Equatable, Sendable {
    /// Which operation this is.
    public var verb: ClipboardVerb
    /// What the menu says. The verb's bare `inertTitle` when inert — no count,
    /// because a disabled item must not name a blast radius it does not have.
    public var title: String
    /// The surface the item acts on; nil when inert.
    public var surface: ClipboardSurface?
    /// Which guard refused; nil when the item is live.
    public var refusedBy: ClipboardMenuRefusal?

    /// DERIVED, never stored: "there is a surface to act on" and "the item is
    /// clickable" are the same fact, and a stored twin could drift from it.
    public var isEnabled: Bool { surface != nil }

    public init(verb: ClipboardVerb,
                title: String? = nil,
                surface: ClipboardSurface? = nil,
                refusedBy: ClipboardMenuRefusal? = nil) {
        self.verb = verb
        self.title = title ?? verb.inertTitle
        self.surface = surface
        self.refusedBy = refusedBy
    }
}

/// What one arrange clip's context-menu Copy or Cut does.
public struct ClipboardContextCommand: Equatable, Sendable {
    /// What the menu says — always names the real blast radius.
    public var title: String
    /// True: act on the whole arrange selection. False: act only on the clip
    /// that was right-clicked, leaving the selection alone.
    public var targetsWholeSelection: Bool

    public init(title: String, targetsWholeSelection: Bool) {
        self.title = title
        self.targetsWholeSelection = targetsWholeSelection
    }
}
