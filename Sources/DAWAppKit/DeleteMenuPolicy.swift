import Foundation

/// The ONE home for the question "what does a DELETE **menu item** act on, what
/// does it say, and is it live?" (m23-cf).
///
/// WHY THIS EXISTS. Until m23-cf the only way to remove a clip or a note was the
/// bare DELETE key — `grep 'Button("Delete\|Button("Remove'` over `Sources/DAWApp`
/// found Remove Track / Send / Insert / Tempo Change / Meter Change / Take Lane
/// and Delete Marker, and NOTHING for clips or notes. A user reported exactly
/// that ("I cannot remove them") and they were right: with the key path dead for
/// any reason, the operation was unreachable. This type is the decision half of
/// the second, non-keyboard route.
///
/// ⚠️ THE MENU ITEM MUST NEVER CARRY `.keyboardShortcut(.delete)`. `ContentView`'s
/// `ArrangeDeleteKey` records why, and it stands: menu key equivalents are checked
/// BEFORE text insertion, so a Delete item with that shortcut would steal
/// Backspace from every rename field in the app (the m17-d trap). The HAZARD
/// BELONGS TO THE SHORTCUT, NOT TO THE ITEM — an item with no key equivalent
/// carries none of it, which is the distinction that makes this whole route
/// possible. The existing `.onKeyPress(.delete)` handlers are untouched: this is
/// a SECOND route, not a move of the first.
///
/// WHY IN DAWAppKit. `DAWApp` has no test target, so a menu policy written there
/// is unverifiable by the Swift suite — the standing remedy in this tree
/// (`ArrangeScrollQuery`, `GenerationCardDebugKeys`, `ArrangeTrackSelection`).
/// Everything that DECIDES lives here; `DAWApp` keeps only composition — reading
/// live state, calling the store, mounting the `Button`s.
public enum DeleteMenuPolicy {

    /// What Edit ▸ Delete says when it is greyed.
    ///
    /// ⚠️ NOT THE BARE WORD "Delete", AND THAT IS A MEASURED CORRECTION, not a
    /// style preference. macOS's own Edit menu already carries a `Delete` in the
    /// standard pasteboard group (Cut / Copy / Paste / **Delete** / Select All),
    /// which routes `delete:` down the responder chain. MEASURED on staging
    /// 2026-08-04 by enumerating the live menu: with nothing selected the Edit
    /// menu showed TWO adjacent greyed items both reading "Delete". A bare title
    /// here is therefore not a neutral default, it is a collision.
    ///
    /// ⭐ AND THE TWO ITEMS ARE GENUINELY DIFFERENT OPERATIONS, which is why the
    /// answer is to distinguish them rather than to suppress one. The native item
    /// comes alive inside a TEXT FIELD (`NSTextView` implements `delete:`) and
    /// deletes the selected TEXT; this one deletes the user's OBJECTS. So while a
    /// rename field is open the Edit menu honestly offers both — "Delete" for the
    /// text, "Delete 2 Clips" for the clips — which is exactly the disambiguation
    /// that makes this policy's omission of the text-editing guard safe (see
    /// `editMenuItem`). Suppressing the native item would have taken away the
    /// text answer to buy a tidier menu.
    ///
    /// "Delete Selection" also teaches the thing the disabled state exists to
    /// teach: the operation is here, and it wants a selection.
    public static let inertTitle = "Delete Selection"

    // MARK: - Edit ▸ Delete

    /// Resolves the Edit-menu Delete item: which surface it targets, what it
    /// says, and whether it is live.
    ///
    /// ═══ THE ARBITRATION IS NOT A NEW ONE ═══
    ///
    /// It is `AppModel.handleArrangeNudgeKey`'s guard stack, in the same order
    /// and for the same reasons — which is itself the app's own FOCUS-FREE
    /// expression of what the DELETE key already does:
    ///
    ///   1. `workspaceMode == .arrange` — the Mix console has no clip selection,
    ///      so DELETE there is inert (`handleArrangeDeleteKey`'s first guard).
    ///   2. `!isModalPresented` — deleting the user's clips behind a scrimmed
    ///      panel they are looking at is silent destruction
    ///      (`handleArrangeDeleteKey`'s second guard).
    ///   3. THE PIANO ROLL WOULD HAVE CONSUMED IT — roll on screen AND holding a
    ///      note selection. Exactly `handleArrangeNudgeKey`'s fifth guard, and
    ///      exactly the test the roll's own `.onKeyPress(.delete)` applies
    ///      (`guard !model.selection.isEmpty`).
    ///   4. AN AUTOMATION LANE WOULD HAVE CONSUMED IT — some mounted lane editor
    ///      holds a live breakpoint selection. `handleArrangeNudgeKey`'s sixth
    ///      guard, mirroring `AutomationLaneEditor.liveSelectionIndex`.
    ///   5. Otherwise the ARRANGE owns it, if anything is selected.
    ///
    /// ⚠️ FOCUS IS NOT A TERM, DELIBERATELY, AND THAT IS THE WHOLE POINT OF
    /// ROUTING THE MENU THIS WAY. On the KEY path the arbitration between (3),
    /// (4) and (5) is structural — the roll and the lane editor own
    /// `.onKeyPress(.delete)` as DESCENDANTS of `ArrangeDeleteKey`, so a focused
    /// descendant consumes the key first. m23-cf exists because that structural
    /// arbitration is the prime suspect for the reported bug (DELETE dead on
    /// BOTH notes and clips while selection works and menu key equivalents keep
    /// firing — the signature of `.onKeyPress` not being delivered at all). A
    /// menu item that depended on the same focus would inherit the same failure.
    /// So this reads the two SELECTION BRIDGES instead, which is precisely how
    /// `handleArrangeNudgeKey` already states the same precedence without focus.
    /// Both bridges were built for that purpose and their doc comments record
    /// the measurements that rejected focus as a term.
    ///
    /// ⚠️ `isArrangeTextEditingFocused` IS THE ONE GUARD DELIBERATELY NOT
    /// MIRRORED, and this is a reasoned divergence rather than an oversight.
    /// Two independent reasons:
    ///
    ///   • WHAT IT GUARDS CANNOT HAPPEN HERE. That guard exists because a
    ///     Backspace typed into a rename field must not reach the clips — an
    ///     ambiguity of KEY DELIVERY. This item has no key equivalent (see the
    ///     banner above), so the only way to reach it is an explicit click on a
    ///     menu item that names its own blast radius ("Delete 3 Clips").
    ///   • INCLUDING IT WOULD MAKE THE ITEM LIE. The responder classifier reads
    ///     `NSApp.keyWindow.firstResponder`, which is NOT observable, so a
    ///     `Commands` body has no reason to re-evaluate when focus enters or
    ///     leaves a text field. The item's enabled state would be computed from
    ///     whenever the body last ran — greyed when it should work, or live when
    ///     it should be greyed. Every OTHER term above is `@Observable` state, so
    ///     the item cannot go stale; the term that would break that property is
    ///     the one term whose hazard this route does not have.
    ///
    /// The consequence, stated rather than hidden: Edit ▸ Delete remains live
    /// while a rename field is open, and will delete the arrange selection. It is
    /// labelled, deliberate and journaled (undo restores it) — which is the
    /// opposite of the silent destruction the key-path guard prevents.
    ///
    /// - Parameters:
    ///   - arrangeWorkspace: `workspaceMode == .arrange`.
    ///   - isModalPresented: a blocking modal is on screen (`AppModel.isModalPresented`).
    ///   - pianoRollHasNoteSelection: the roll is on screen AND holds a note
    ///     selection (`openEditorClip != nil && pianoRollNoteSelection.hasSelection`).
    ///   - automationPointCount: how many mounted lane editors hold a live
    ///     breakpoint (`automationPointSelection.lanesWithSelection.count`). Each
    ///     editor holds at most ONE selected index, so the lane count IS the
    ///     point count.
    ///   - arrangeClipCount: `arrangeSelection.count`.
    public static func editMenuItem(
        arrangeWorkspace: Bool,
        isModalPresented: Bool,
        pianoRollHasNoteSelection: Bool,
        automationPointCount: Int,
        arrangeClipCount: Int
    ) -> DeleteMenuItem {
        guard arrangeWorkspace else { return DeleteMenuItem(refusedBy: .workspace) }
        guard !isModalPresented else { return DeleteMenuItem(refusedBy: .modal) }
        if pianoRollHasNoteSelection {
            // NO COUNT, ON PURPOSE. `PianoRollNoteSelectionBridge` publishes a
            // BOOL, not a count, because its report fires on the
            // empty ↔ non-empty transition only — keying it on `count` would
            // rewrite a keyboard-gating observable to fire on every pointer
            // update of a note marquee. A title claiming "Delete 3 Notes" from a
            // number this policy does not have would be the honesty violation
            // the design language forbids; the ROLL'S OWN context menu, which
            // can see `model.selection.count` directly, does carry the count.
            return DeleteMenuItem(title: "Delete Selected Notes", surface: .pianoRollNotes)
        }
        if automationPointCount > 0 {
            return DeleteMenuItem(
                title: countedTitle(automationPointCount, "Automation Point", "Automation Points"),
                surface: .automationPoints)
        }
        guard arrangeClipCount > 0 else { return DeleteMenuItem(refusedBy: .emptySelection) }
        return DeleteMenuItem(title: countedTitle(arrangeClipCount, "Clip", "Clips"),
                              surface: .arrangeClips)
    }

    // MARK: - The arrange clip context menu

    /// What a right-click Delete on ONE arrange clip targets, and what it says.
    ///
    /// TITLE AND TARGET COME OUT OF THE SAME CALL, and that is the point of
    /// returning a struct rather than two free functions. The label is the user's
    /// only warning of blast radius; a menu reading "Delete Clip" while the
    /// action removes three would be worse than the missing item this replaces.
    ///
    /// THE RULE — the Finder/DAW convention, and the one that cannot surprise:
    /// right-clicking a clip that IS part of the current selection acts on the
    /// WHOLE selection (you selected three, you asked to delete, you meant
    /// three); right-clicking a clip that is NOT selected acts on that clip
    /// alone and leaves the selection untouched (you pointed at one thing).
    ///
    /// UNLIKE THE EDIT-MENU ITEM THIS IS NEVER DISABLED. A clip context menu only
    /// exists because the pointer is over a clip, so there is always exactly one
    /// unambiguous target — the empty-selection case that greys the Edit item
    /// cannot arise here.
    ///
    /// - Parameters:
    ///   - clickedClipIsSelected: the right-clicked clip is in `arrangeSelection`.
    ///   - arrangeSelectionCount: `arrangeSelection.count`.
    public static func clipContextCommand(clickedClipIsSelected: Bool,
                                          arrangeSelectionCount: Int) -> ClipDeleteCommand {
        // `clickedClipIsSelected` with a count of 0 violates `ArrangeSelection`'s
        // INV2 and cannot occur — resolved to the clicked clip rather than
        // trusted, so a future caller bug degrades to "delete the one you
        // pointed at" instead of an empty no-op.
        guard clickedClipIsSelected, arrangeSelectionCount > 0 else {
            return ClipDeleteCommand(title: "Delete Clip", targetsWholeSelection: false)
        }
        return ClipDeleteCommand(title: countedTitle(arrangeSelectionCount, "Clip", "Clips"),
                                 targetsWholeSelection: true)
    }

    // MARK: - The piano-roll note context menu

    /// The roll's own right-click Delete title.
    ///
    /// SELECTION-BASED, NOT LOCATION-BASED, and that is a decision. SwiftUI's
    /// `.contextMenu` hands the builder no click location, and the roll's notes
    /// are drawn into a single `Canvas` rather than as per-note views, so "delete
    /// the note under the pointer" would need a hover-tracked point AND a second
    /// targeting policy alongside the key path's `guard !model.selection.isEmpty`.
    /// Mirroring the key path instead means the menu and the key can never
    /// disagree about what DELETE means in the roll.
    ///
    /// Zero returns a plural title for a DISABLED item: the menu still appears,
    /// greyed, so a user who right-clicks without selecting learns that the
    /// operation exists and needs a selection — which is exactly the discovery
    /// the reported bug denied them.
    public static func noteContextTitle(selectedNoteCount: Int) -> String {
        guard selectedNoteCount > 0 else { return "Delete Notes" }
        return countedTitle(selectedNoteCount, "Note", "Notes")
    }

    // MARK: - Shared

    /// "Delete Clip" for one, "Delete 3 Clips" for many — ONE producer, so no
    /// surface can invent its own plural.
    static func countedTitle(_ count: Int, _ singular: String, _ plural: String) -> String {
        count == 1 ? "Delete \(singular)" : "Delete \(count) \(plural)"
    }
}

/// Which surface a DELETE acts on. Enumerated as a sum type so the compiler
/// forces every consumer to answer for all three — a fourth deletable surface
/// must be routed, not silently defaulted to the arrange.
public enum DeleteSurface: String, Sendable, CaseIterable, Equatable {
    case pianoRollNotes = "piano-roll-notes"
    case automationPoints = "automation-points"
    case arrangeClips = "arrange-clips"
}

/// WHY the Edit-menu Delete item is inert, named for the guard that refused.
///
/// Carried on the disabled item rather than discarded for the reason
/// `AppModel.ArrangeNudgeRefusal` exists: a bare `isEnabled == false` cannot tell
/// a test that meant to prove the MODAL guard from one whose selection had
/// quietly emptied, which is how a dead policy passes a refusal-only suite.
public enum DeleteMenuRefusal: String, Sendable, Equatable {
    case workspace
    case modal
    case emptySelection = "empty-selection"
}

/// The resolved Edit ▸ Delete item.
public struct DeleteMenuItem: Equatable, Sendable {
    /// What the menu says. `DeleteMenuPolicy.inertTitle` when inert — no count,
    /// because a disabled item must not name a blast radius it does not have.
    public var title: String
    /// The surface the item acts on; nil when inert.
    public var surface: DeleteSurface?
    /// Which guard refused; nil when the item is live.
    public var refusedBy: DeleteMenuRefusal?

    /// DERIVED, never stored: "there is a surface to act on" and "the item is
    /// clickable" are the same fact, and a stored twin could drift from it.
    public var isEnabled: Bool { surface != nil }

    public init(title: String = DeleteMenuPolicy.inertTitle,
                surface: DeleteSurface? = nil,
                refusedBy: DeleteMenuRefusal? = nil) {
        self.title = title
        self.surface = surface
        self.refusedBy = refusedBy
    }
}

/// What one arrange clip's context-menu Delete does.
public struct ClipDeleteCommand: Equatable, Sendable {
    /// What the menu says — always names the real blast radius.
    public var title: String
    /// True: delete the whole arrange selection. False: delete only the clip
    /// that was right-clicked, leaving the selection alone.
    public var targetsWholeSelection: Bool

    public init(title: String, targetsWholeSelection: Bool) {
        self.title = title
        self.targetsWholeSelection = targetsWholeSelection
    }
}
