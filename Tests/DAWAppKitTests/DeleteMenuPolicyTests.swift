import Testing
import Foundation
@testable import DAWAppKit

/// m23-cf — the DELETE **menu** routes. `DAWApp` has no test target, so the whole
/// point of `DeleteMenuPolicy` is that the decisions (which surface owns the
/// delete, what the item says, when it is disabled) are testable here while
/// `DAWApp` keeps only composition. What these tests CANNOT reach is the mount
/// itself: whether the `Button`s appear, and whether the bridge nonces actually
/// arrive in the roll and the lane. That residue is a live exercise, recorded as
/// such rather than implied by a green suite.
@Suite("Delete menu policy (m23-cf)")
struct DeleteMenuPolicyTests {

    // MARK: - Edit ▸ Delete: the guard stack

    @Test("the Mix console has no clip selection — Delete is inert there")
    func mixWorkspaceRefuses() {
        let item = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: false, isModalPresented: false,
            pianoRollHasNoteSelection: true, automationPointCount: 3,
            pitchEditorOpen: false, pitchEditorHasNoteSelection: false,
            arrangeClipCount: 5)
        #expect(item.isEnabled == false)
        #expect(item.surface == nil)
        #expect(item.refusedBy == .workspace)
        // A DISABLED ITEM MUST NOT NAME A BLAST RADIUS. Every surface above is
        // richly populated and the title still carries no count — a greyed
        // "Delete 5 Clips" would tell the user a delete is pending that is not.
        #expect(item.title == DeleteMenuPolicy.inertTitle)
    }

    @Test("a blocking modal refuses — deleting clips behind a scrim is silent destruction")
    func modalRefuses() {
        let item = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: true,
            pianoRollHasNoteSelection: true, automationPointCount: 3,
            pitchEditorOpen: false, pitchEditorHasNoteSelection: false,
            arrangeClipCount: 5)
        #expect(item.refusedBy == .modal)
        #expect(item.isEnabled == false)
    }

    @Test("the workspace guard is checked BEFORE the modal guard")
    func guardOrderWorkspaceBeforeModal() {
        // Order matters for the same reason `AppModel.ArrangeNudgeRefusal` is
        // reported at all: a bare `isEnabled == false` cannot distinguish a
        // policy that ran its guards in the documented order from one that
        // happens to refuse. Both conditions true -> the FIRST must be named.
        let item = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: false, isModalPresented: true,
            pianoRollHasNoteSelection: false, automationPointCount: 0,
            pitchEditorOpen: false, pitchEditorHasNoteSelection: false,
            arrangeClipCount: 0)
        #expect(item.refusedBy == .workspace)
    }

    @Test("nothing selected anywhere — the item exists, greyed, and teaches")
    func emptySelectionRefuses() {
        let item = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0,
            pitchEditorOpen: false, pitchEditorHasNoteSelection: false,
            arrangeClipCount: 0)
        #expect(item.refusedBy == .emptySelection)
        #expect(item.isEnabled == false)
        #expect(item.title == DeleteMenuPolicy.inertTitle)
    }

    // MARK: - Edit ▸ Delete: the precedence between the three surfaces

    @Test("the piano roll wins over BOTH other surfaces — the key path's first claim")
    func pianoRollTakesPrecedence() {
        // This mirrors `handleArrangeNudgeKey`'s FIFTH guard, which is the app's
        // focus-free statement of what the DELETE key already does: the roll owns
        // `.onKeyPress(.delete)` as a descendant of `ArrangeDeleteKey`, so a roll
        // holding notes consumes the key and the arrange never sees it.
        let item = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: true, automationPointCount: 2,
            pitchEditorOpen: false, pitchEditorHasNoteSelection: false,
            arrangeClipCount: 7)
        #expect(item.surface == .pianoRollNotes)
        #expect(item.isEnabled)
        // NO COUNT: the bridge publishes a Bool, so the policy has no number and
        // must not invent one. Pinned, because a future "improvement" that
        // interpolated `arrangeClipCount` here would read plausibly and lie.
        #expect(item.title == "Delete Selected Notes")
    }

    @Test("an automation lane wins over the arrange — the key path's second claim")
    func automationTakesPrecedenceOverClips() {
        let item = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 1,
            pitchEditorOpen: false, pitchEditorHasNoteSelection: false,
            arrangeClipCount: 7)
        #expect(item.surface == .automationPoints)
        #expect(item.title == "Delete Automation Point")
    }

    @Test("several lanes each holding a breakpoint — the lane count IS the point count")
    func automationPluralises() {
        let item = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 3,
            pitchEditorOpen: false, pitchEditorHasNoteSelection: false,
            arrangeClipCount: 0)
        #expect(item.surface == .automationPoints)
        #expect(item.title == "Delete 3 Automation Points")
    }

    @Test("with neither editor claiming, the arrange owns it")
    func arrangeIsTheFallback() {
        let one = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0,
            pitchEditorOpen: false, pitchEditorHasNoteSelection: false,
            arrangeClipCount: 1)
        #expect(one.surface == .arrangeClips)
        #expect(one.title == "Delete Clip")
        let many = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0,
            pitchEditorOpen: false, pitchEditorHasNoteSelection: false,
            arrangeClipCount: 4)
        #expect(many.surface == .arrangeClips)
        #expect(many.title == "Delete 4 Clips")
    }

    @Test("a roll that is on screen with NO notes selected does not claim the key")
    func rollWithoutNotesFallsThrough() {
        // The roll's own handler returns `.ignored` on an empty selection and the
        // key falls through to the clips — shipped, accepted behaviour
        // (`PianoRollNoteSelectionBridge`'s doc comment). The caller folds "on
        // screen AND holding notes" into the one flag, so `false` here IS the
        // open-roll-empty-selection state, and the menu must behave the same way.
        let item = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0,
            pitchEditorOpen: false, pitchEditorHasNoteSelection: false,
            arrangeClipCount: 2)
        #expect(item.surface == .arrangeClips)
        #expect(item.title == "Delete 2 Clips")
    }

    // MARK: - m23-ap p2-del — the NOTE EDITOR (pitch editor) pane is open

    /// One call per state, so each assertion below reads as the state it pins.
    private func menuItem(arrange: Bool = true, modal: Bool = false, notes: Bool = false,
                      points: Int = 0, pitch: Bool, pitchNotes: Bool = false,
                      clips: Int) -> DeleteMenuItem {
        DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: arrange, isModalPresented: modal,
            pianoRollHasNoteSelection: notes, automationPointCount: points,
            pitchEditorOpen: pitch, pitchEditorHasNoteSelection: pitchNotes,
            arrangeClipCount: clips)
    }

    @Test("the note editor open greys Edit ▸ Delete by name — the menu is a door to the same clip")
    func noteEditorOpenGreysTheMenu() {
        // The fixture: the pane is open on the ONE selected clip (it opens only
        // on the arrange focus clip), no roll notes, no breakpoint.
        let open = menuItem(pitch: true, clips: 1)
        #expect(open.refusedBy == .pitchEditorOpen)
        #expect(open.surface == nil)
        #expect(open.isEnabled == false)
        // A disabled item names no blast radius — never a greyed "Delete Clip".
        #expect(open.title == DeleteMenuPolicy.inertTitle)
        // CONTROL: the same state with the pane SHUT is the shipped behaviour, so
        // the refusal above is the new term talking and not a policy that greys
        // everything.
        let shut = menuItem(pitch: false, clips: 1)
        #expect(shut.surface == .arrangeClips)
        #expect(shut.title == "Delete Clip")
    }

    @Test("the note-editor guard sits after both editors and before the arrange")
    func noteEditorGuardPlacement() {
        // The Mix console and a modal are named FIRST, as for every refusal.
        #expect(menuItem(arrange: false, pitch: true, clips: 1).refusedBy == .workspace)
        #expect(menuItem(modal: true, pitch: true, clips: 1).refusedBy == .modal)
        // A breakpoint the user clicked still takes the key: the hazard is the
        // CLIP, and deleting a point with the pane open deletes no clip.
        #expect(menuItem(points: 2, pitch: true, clips: 1).surface == .automationPoints)
        // Roll notes AND the pitch pane open is unreachable in the app (the two
        // panes resolve the same `selectedClipID` on opposite sides of
        // `isMIDI`). The roll wins it — the router's own tie-break, measured
        // here rather than cited, so the two cannot disagree silently.
        #expect(EditorSurfaceRouter.openSurface(workspaceIsArrange: true, rollOpen: true,
                                                pitchEditorOpen: true).reason == .rollOpen)
        #expect(menuItem(notes: true, pitch: true, clips: 1).surface == .pianoRollNotes)
        // An open pane with NOTHING selected is unreachable too (the pane needs
        // its clip selected). It is still the pane's refusal, never
        // `.emptySelection`: while the pane is open the arrange owns nothing.
        #expect(menuItem(pitch: true, clips: 0).refusedBy == .pitchEditorOpen)
        #expect(menuItem(pitch: true, clips: 4).refusedBy == .pitchEditorOpen)
    }

    /// ⚠️ RENAMED AND REWRITTEN at m23-ap I7b from "I4: the note-selection arm
    /// sits directly in front of the note-editor refusal and only narrows it"
    /// (`noteSelectionArmPlacement`). I4 greyed Edit ▸ Delete here by name
    /// until ⌫ had a clear action with a visible result; I7b ships it, so the
    /// arm is a LIVE Clear. Its PLACEMENT — every guard in front of it still
    /// names itself first, a stale bit with the pane shut is inert — is
    /// re-asserted unchanged.
    @Test("I7b: the note-selection arm is a LIVE Clear, directly in front of the note-editor refusal, and only narrows it")
    func noteSelectionArmIsALiveClear() {
        // The fixture: the pane open on its one selected clip, notes selected
        // in it. Edit ▸ Delete is LIVE and says what it does — the same action
        // as ⌫ and the note editor's right-click Clear (I7b).
        let selected = menuItem(pitch: true, pitchNotes: true, clips: 1)
        #expect(selected.surface?.rawValue == "pitch-editor-notes")
        #expect(selected.refusedBy == nil)
        #expect(selected.isEnabled)
        #expect(selected.title == "Clear Selected Notes")
        // A CLEAR, NEVER A DELETE: the word the user reads must not promise to
        // remove something that stays on screen, hollow, and can be restored.
        #expect(!selected.title.contains("Delete"))
        // It ONLY NARROWS p2-del's refusal: every guard in front of it still
        // names itself first, exactly as with the pane open and nothing selected.
        #expect(menuItem(arrange: false, pitch: true, pitchNotes: true, clips: 1).refusedBy == .workspace)
        #expect(menuItem(modal: true, pitch: true, pitchNotes: true, clips: 1).refusedBy == .modal)
        #expect(menuItem(points: 2, pitch: true, pitchNotes: true, clips: 1).surface == .automationPoints)
        #expect(menuItem(notes: true, pitch: true, pitchNotes: true, clips: 1).surface == .pianoRollNotes)
        // A STALE BIT WITH THE PANE SHUT IS INERT: the arm reads openness too,
        // so a bridge that failed to clear cannot lock ⌫ out of the clips.
        #expect(menuItem(pitch: false, pitchNotes: true, clips: 1).surface == .arrangeClips)
        #expect(menuItem(pitch: false, pitchNotes: true, clips: 0).refusedBy == .emptySelection)
        // CONTROL: the pane open with NOTHING selected keeps p2-del's refusal.
        #expect(menuItem(pitch: true, pitchNotes: false, clips: 1).refusedBy == .pitchEditorOpen)
    }

    @Test("every surface is reachable — no branch is dead")
    func everySurfaceIsReachable() {
        // ANTI-VACUITY. A policy that always returned `.arrangeClips` would pass
        // several assertions above individually; this pins that every case of
        // the sum type is actually produced by some input. ⚠️ m23-ap I7b added
        // the fourth row (the note editor open WITH notes selected — the live
        // Clear) and the fourth case; without that row `seen` stops one short of
        // `allCases` and this goes red, which is the point of the line.
        var seen: Set<DeleteSurface> = []
        for (notes, points, pitch, pitchNotes, clips) in [(true, 0, false, false, 0),
                                                          (false, 1, false, false, 0),
                                                          (false, 0, false, false, 1),
                                                          (false, 0, true, true, 1)] {
            let item = DeleteMenuPolicy.editMenuItem(
                arrangeWorkspace: true, isModalPresented: false,
                pianoRollHasNoteSelection: notes, automationPointCount: points,
                pitchEditorOpen: pitch, pitchEditorHasNoteSelection: pitchNotes,
                arrangeClipCount: clips)
            if let surface = item.surface { seen.insert(surface) }
        }
        #expect(seen == Set(DeleteSurface.allCases))
        #expect(seen.count == 4)
    }

    @Test("an enabled item always names a surface, a disabled one never does")
    func enabledIsDerivedFromSurface() {
        for arrange in [true, false] {
            for modal in [true, false] {
                for notes in [true, false] {
                    for points in [0, 2] {
                        // m23-ap p2-del: the note-editor term, so the complement
                        // law is proven over the new refusal too — and (m23-ap
                        // I4) the pane's note-selection term, for the same reason.
                        for (pitch, clips) in [(false, 0), (false, 3), (true, 0), (true, 3)] {
                            for pitchNotes in [false, true] {
                                let item = DeleteMenuPolicy.editMenuItem(
                                    arrangeWorkspace: arrange, isModalPresented: modal,
                                    pianoRollHasNoteSelection: notes,
                                    automationPointCount: points,
                                    pitchEditorOpen: pitch,
                                    pitchEditorHasNoteSelection: pitchNotes,
                                    arrangeClipCount: clips)
                                #expect(item.isEnabled == (item.surface != nil))
                                // The two are complements, never both and never
                                // neither: a live item with a refusal, or a dead
                                // one without, would each make the reported
                                // reason meaningless.
                                #expect((item.refusedBy == nil) == item.isEnabled)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test("the inert title does NOT collide with macOS's own Edit ▸ Delete")
    func inertTitleDoesNotCollideWithTheNativeItem() {
        // MEASURED on staging 2026-08-04, not reasoned: enumerating the live Edit
        // menu with nothing selected returned
        //   Undo…, Redo, —, Cut, Copy, Paste, Delete, Select All, Delete, …
        // — TWO adjacent greyed "Delete"s, because the standard pasteboard group
        // already ships one that routes `delete:` down the responder chain. The
        // native item is NOT redundant (it comes alive inside a text field and
        // deletes TEXT), so the fix is to distinguish, not to suppress.
        //
        // ⚠️ THIS IS THE ONLY ASSERTION IN THIS FILE ABOUT A STRING THE APP DOES
        // NOT OWN. It is pinned because the collision is invisible to every other
        // test here: each title assertion passes just as happily with the bare
        // word, and only a live menu enumeration can see the duplicate.
        #expect(DeleteMenuPolicy.inertTitle != "Delete")
        #expect(DeleteMenuPolicy.inertTitle == "Delete Selection")
    }

    // MARK: - The arrange clip context menu

    @Test("right-clicking a clip that is NOT selected targets that clip alone")
    func unselectedClipTargetsItself() {
        let command = DeleteMenuPolicy.clipContextCommand(
            clickedClipIsSelected: false, arrangeSelectionCount: 5)
        #expect(command.targetsWholeSelection == false)
        // AND THE TITLE SAYS SO. Five clips are selected; the menu must not read
        // "Delete 5 Clips" when the action removes one — the label is the user's
        // only warning of blast radius.
        #expect(command.title == "Delete Clip")
    }

    @Test("right-clicking a clip INSIDE the selection targets the whole selection")
    func selectedClipTargetsTheSelection() {
        let command = DeleteMenuPolicy.clipContextCommand(
            clickedClipIsSelected: true, arrangeSelectionCount: 3)
        #expect(command.targetsWholeSelection)
        #expect(command.title == "Delete 3 Clips")
    }

    @Test("a selection of one reads in the singular, whichever way it was reached")
    func singleSelectionReadsSingular() {
        let clicked = DeleteMenuPolicy.clipContextCommand(
            clickedClipIsSelected: true, arrangeSelectionCount: 1)
        #expect(clicked.title == "Delete Clip")
        #expect(clicked.targetsWholeSelection)
        let unselected = DeleteMenuPolicy.clipContextCommand(
            clickedClipIsSelected: false, arrangeSelectionCount: 1)
        #expect(unselected.title == "Delete Clip")
        #expect(unselected.targetsWholeSelection == false)
    }

    @Test("selected-but-count-zero degrades to the clicked clip, never to nothing")
    func inconsistentInputDegradesSafely() {
        // `ArrangeSelection` INV2 makes this unreachable; resolved rather than
        // trusted so a future caller bug deletes the clip the user pointed at
        // instead of silently deleting nothing — which is the exact no-op this
        // whole item exists to remove.
        let command = DeleteMenuPolicy.clipContextCommand(
            clickedClipIsSelected: true, arrangeSelectionCount: 0)
        #expect(command.targetsWholeSelection == false)
        #expect(command.title == "Delete Clip")
    }

    // MARK: - The piano-roll note context menu

    @Test("the roll's own menu DOES carry the count — it can see the selection")
    func noteTitleCarriesCount() {
        #expect(DeleteMenuPolicy.noteContextTitle(selectedNoteCount: 1) == "Delete Note")
        #expect(DeleteMenuPolicy.noteContextTitle(selectedNoteCount: 3) == "Delete 3 Notes")
    }

    @Test("no selection — the entry still appears (disabled) and reads plural")
    func noteTitleWithNoSelection() {
        // The DISABLED title. A menu that does not appear teaches nothing; the
        // user who right-clicks having selected nothing must learn that the
        // operation exists and needs a selection, which is precisely the
        // discovery the reported bug denied.
        #expect(DeleteMenuPolicy.noteContextTitle(selectedNoteCount: 0) == "Delete Notes")
    }

    // MARK: - The shared plural

    @Test("one producer for the plural — no surface invents its own")
    func countedTitleIsOneProducer() {
        #expect(DeleteMenuPolicy.countedTitle(1, "Clip", "Clips") == "Delete Clip")
        #expect(DeleteMenuPolicy.countedTitle(2, "Clip", "Clips") == "Delete 2 Clips")
        #expect(DeleteMenuPolicy.countedTitle(0, "Clip", "Clips") == "Delete 0 Clips")
    }

    // MARK: - The two delete channels the menu reaches the editors through

    @MainActor
    @Test("the roll's delete request is a SECOND nonce — it never disturbs the staged selection")
    func rollDeleteNonceIsIndependent() {
        let bridge = PianoRollNoteSelectionBridge()
        #expect(bridge.deleteNonce == 0)
        bridge.stage(selectAll: true)
        let stagedAfterSelect = bridge.stageNonce
        bridge.requestDelete()
        #expect(bridge.deleteNonce == 1)
        // THE LOAD-BEARING HALF. Folding delete into `stageNonce` would make one
        // number mean two things; the roll routes `stagedSelectAll == false` to
        // `clearSelection()`, so a shared nonce would let a delete silently
        // rewrite what "select none" means. Neither the staging nonce nor its
        // payload may move.
        #expect(bridge.stageNonce == stagedAfterSelect)
        #expect(bridge.stagedSelectAll)
    }

    @MainActor
    @Test("asking twice is two requests — a repeat delete must still apply")
    func rollDeleteNonceIsRepeatable() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.requestDelete()
        bridge.requestDelete()
        #expect(bridge.deleteNonce == 2)
    }

    @MainActor
    @Test("requesting a delete does NOT itself claim a selection")
    func rollDeleteDoesNotSetHasSelection() {
        // The `stage` rule, for the same reason: `hasSelection` must come back
        // FROM the roll. A bridge that set it here would make the Edit-menu item
        // look live because the menu had been used, which is a feedback loop, not
        // a report.
        let bridge = PianoRollNoteSelectionBridge()
        bridge.requestDelete()
        #expect(bridge.hasSelection == false)
    }

    @MainActor
    @Test("the automation bridge's delete request likewise leaves staging and claims alone")
    func automationDeleteNonceIsIndependent() {
        let bridge = AutomationPointSelectionBridge()
        let lane = UUID()
        bridge.report(lane: lane, hasSelection: true)
        bridge.stage(select: true)
        let stagedAfterSelect = bridge.stageNonce
        #expect(bridge.deleteNonce == 0)
        bridge.requestDelete()
        #expect(bridge.deleteNonce == 1)
        #expect(bridge.stageNonce == stagedAfterSelect)
        #expect(bridge.stagedSelect)
        // The claim survives the REQUEST. Only each editor's own
        // `liveSelectionIndex` decides whether anything was deleted, and it
        // reports the result back through `report(lane:hasSelection:)` — the
        // bridge must not pre-empt that.
        #expect(bridge.lanesWithSelection == [lane])
    }

    @MainActor
    @Test("the automation delete request is a broadcast with no lane addressing")
    func automationDeleteIsABroadcast() {
        // Deliberate: the guard asks "is any lane claiming", not "which one", so
        // there is no per-lane addressing to invent for the delete either. Safe
        // because every mounted editor re-applies its own `liveSelectionIndex`
        // guard — a lane the user was not editing mutates nothing.
        let bridge = AutomationPointSelectionBridge()
        let a = UUID(), b = UUID()
        bridge.report(lane: a, hasSelection: true)
        bridge.report(lane: b, hasSelection: true)
        bridge.requestDelete()
        #expect(bridge.deleteNonce == 1)
        #expect(bridge.lanesWithSelection == [a, b])
    }
}
