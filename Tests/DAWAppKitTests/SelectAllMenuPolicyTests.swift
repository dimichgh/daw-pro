import Testing
import Foundation
import DAWCore
@testable import DAWAppKit

/// m25-s — ⌘A / Edit ▸ Select All selects every note in the piano roll.
///
/// The user, 2026-08-13: *"One small feature to add when in node editor and user
/// uses keyboard shortcut \"select all\"/cmd+A - it should select all the notes
/// in the editor"*.
///
/// ⚠️ **WHAT NO TEST IN THIS REPO CAN SEE.** Nothing here presses ⌘A. The
/// keystroke reaches this app through AppKit's responder chain, and `DAWApp` has
/// no test target — so the suite proves the DECISIONS and the WIRING SHAPE, and
/// the AppKit half was measured out-of-tree with a standalone probe (recorded on
/// `ClipboardResponderRouting.claimedSelectorNames` and
/// `ClipboardResponder.selectAll(_:)`). Do not read a green run here as "⌘A
/// works"; read it as "if the key arrives, this is what happens".
@Suite("⌘A selects all notes in the roll (m25-s)")
struct SelectAllMenuPolicyTests {

    private func note(_ pitch: Int, _ start: Double, _ length: Double = 1,
                      id: UUID = UUID()) -> MIDINote {
        MIDINote(id: id, pitch: pitch, velocity: 100, startBeat: start, lengthBeats: length)
    }

    // MARK: - The policy

    @Test("the roll is the active surface and holds notes — LIVE, targeting the roll")
    func liveInTheRoll() {
        let item = SelectAllMenuPolicy.editMenuItem(
            activeSurface: .pianoRoll, isModalPresented: false, rollNoteCount: 3)
        #expect(item.surface == .pianoRollNotes)
        #expect(item.isEnabled)
        #expect(item.refusedBy == nil)
        #expect(item.title == "Select All")
    }

    /// ⚠️⚠️ **THE SCOPE GUARD, AND THE REASON THIS ITEM WAS ALLOWED TO EXIST AT
    /// ALL.** `ClipboardResponderRouting` refused `selectAll:` at m25-f-1 partly
    /// because *"there is no arrange-wide 'select all clips' verb in this app
    /// yet, and inventing one here would ship it through a keystroke nobody
    /// reviewed."* That objection was never withdrawn — it became the boundary.
    /// If this test ever goes green with a non-nil surface, an unreviewed
    /// arrange-wide select-all has shipped.
    @Test("the ARRANGE is active — DECLINES, and no arrange-wide select-all was invented")
    func declinesInTheArrange() {
        let item = SelectAllMenuPolicy.editMenuItem(
            activeSurface: .arrange, isModalPresented: false, rollNoteCount: 3)
        #expect(item.surface == nil)
        #expect(!item.isEnabled)
        #expect(item.refusedBy == .notPianoRoll)
        // Even greyed, the row reads the bare macOS words — the 2026-08-12 ruling.
        #expect(item.title == "Select All")
    }

    @Test("a modal is up — refuses, matching both sibling policies")
    func refusesBehindAModal() {
        let item = SelectAllMenuPolicy.editMenuItem(
            activeSurface: .pianoRoll, isModalPresented: true, rollNoteCount: 3)
        #expect(item.refusedBy == .modal)
        #expect(!item.isEnabled)
    }

    @Test("the roll's clip is empty — refuses rather than offering a provable no-op")
    func refusesOnAnEmptyRoll() {
        let item = SelectAllMenuPolicy.editMenuItem(
            activeSurface: .pianoRoll, isModalPresented: false, rollNoteCount: 0)
        #expect(item.refusedBy == .emptyRoll)
        #expect(!item.isEnabled)
    }

    /// GUARD ORDER IS OBSERVABLE, and it is pinned for `DeleteMenuRefusal`'s
    /// reason: a refusal-only assertion passes identically against a policy that
    /// refused for the wrong reason, which is how a dead guard survives a suite.
    @Test("guard ORDER: surface, then modal, then emptiness")
    func guardOrderIsPinned() {
        // Arrange + modal + empty: the SURFACE term must answer first.
        #expect(SelectAllMenuPolicy.editMenuItem(
            activeSurface: .arrange, isModalPresented: true, rollNoteCount: 0)
            .refusedBy == .notPianoRoll)
        // Roll + modal + empty: MODAL before emptiness.
        #expect(SelectAllMenuPolicy.editMenuItem(
            activeSurface: .pianoRoll, isModalPresented: true, rollNoteCount: 0)
            .refusedBy == .modal)
    }

    /// EXHAUSTIVE, the `EditorSurfaceRouterTests` idiom: the rule is a function of
    /// three small values, so sweep them rather than sampling.
    @Test("exhaustive sweep — exactly one state is live")
    func exhaustiveSweep() {
        var live = 0
        for surface in EditorSurface.allCases {
            for modal in [false, true] {
                for count in [0, 1, 7] {
                    let item = SelectAllMenuPolicy.editMenuItem(
                        activeSurface: surface, isModalPresented: modal, rollNoteCount: count)
                    // INV: enabled iff a surface, and the two are never both set.
                    #expect(item.isEnabled == (item.surface != nil))
                    #expect((item.surface == nil) == (item.refusedBy != nil))
                    if item.isEnabled {
                        live += 1
                        #expect(surface == .pianoRoll && !modal && count > 0)
                    }
                }
            }
        }
        // pianoRoll × !modal × {1, 7} = 2
        #expect(live == 2)
    }

    /// ⭐ THE ROUTER IS CONSUMED, NOT RE-DERIVED. The policy takes a VERDICT, so
    /// feeding it `EditorSurfaceRouter.resolve`'s real output is the honest
    /// end-to-end shape of the decision — and it pins the accepted consequence
    /// `EditorSurfaceRouter` names up front: opening the roll by clicking a clip
    /// in the arrange leaves the ARRANGE engaged, so ⌘A waits for a click in the
    /// roll. If somebody ever overrules that, this test says where it shows up.
    @Test("fed by the real router: roll open but arrange engaged still declines")
    func consumesTheRouterVerdict() {
        let engagedArrange = EditorSurfaceRouter.resolve(
            workspaceIsArrange: true, rollOpen: true, lastEngaged: .arrange)
        #expect(SelectAllMenuPolicy.editMenuItem(
            activeSurface: engagedArrange.surface, isModalPresented: false, rollNoteCount: 4)
            .refusedBy == .notPianoRoll)

        let engagedRoll = EditorSurfaceRouter.resolve(
            workspaceIsArrange: true, rollOpen: true, lastEngaged: .pianoRoll)
        #expect(SelectAllMenuPolicy.editMenuItem(
            activeSurface: engagedRoll.surface, isModalPresented: false, rollNoteCount: 4)
            .surface == .pianoRollNotes)

        // The MIX CONSOLE keeps a latched roll engagement from acting on a roll
        // nobody can see — the workspace term `EditorSurfaceRouter` calls the
        // easiest thing to drop.
        let inMixer = EditorSurfaceRouter.resolve(
            workspaceIsArrange: false, rollOpen: true, lastEngaged: .pianoRoll)
        #expect(SelectAllMenuPolicy.editMenuItem(
            activeSurface: inMixer.surface, isModalPresented: false, rollNoteCount: 4)
            .refusedBy == .notPianoRoll)
    }

    // MARK: - The verb

    @Test("selectAllNotes selects every note in the DRAFT")
    @MainActor
    func selectAllNotesSelectsTheDraft() {
        let model = PianoRollModel()
        let notes = [note(60, 0), note(64, 1), note(67, 2)]
        model.load(notes: notes, clipLengthBeats: 4)
        #expect(model.selection.isEmpty)

        model.selectAllNotes()
        #expect(model.selection == Set(notes.map(\.id)))
    }

    @Test("selectAllNotes on an empty draft is a harmless no-op")
    @MainActor
    func selectAllNotesOnEmptyDraft() {
        let model = PianoRollModel()
        model.load(notes: [], clipLengthBeats: 4)
        model.selectAllNotes()
        #expect(model.selection.isEmpty)
    }

    /// ⭐ REPLACES, NEVER UNIONS — the shape a user expects from ⌘A, and the one
    /// the extracted expression always had.
    @Test("selectAllNotes replaces an existing partial selection")
    @MainActor
    func selectAllNotesReplaces() {
        let model = PianoRollModel()
        let notes = [note(60, 0), note(64, 1)]
        model.load(notes: notes, clipLengthBeats: 4)
        model.selectOnly(notes[0].id)
        model.selectAllNotes()
        #expect(model.selection.count == 2)
    }

    /// ⚠️ **SELECTING IS NOT EDITING.** The draft must come back byte-identical:
    /// a select-all that touched note data would be journalled by the caller's
    /// `commit()`, and there is deliberately no `commit()` on this path.
    @Test("selectAllNotes does not touch the draft")
    @MainActor
    func selectAllNotesLeavesTheDraftAlone() {
        let model = PianoRollModel()
        let notes = [note(60, 0), note(64, 1, 2)]
        model.load(notes: notes, clipLengthBeats: 4)
        let before = model.draft
        model.selectAllNotes()
        #expect(model.draft.map(\.id) == before.map(\.id))
        #expect(model.draft.map(\.startBeat) == before.map(\.startBeat))
        #expect(model.draft.map(\.lengthBeats) == before.map(\.lengthBeats))
        #expect(model.draft.map(\.pitch) == before.map(\.pitch))
    }

    // MARK: - ⚠️ The m25-f-3 filter must survive the new door

    /// ⚠️⚠️ **THE HAZARD THIS FEATURE WALKS STRAIGHT INTO.**
    /// `PianoRollModel.moveIDsStartingAudible`'s own doc names the exact sequence
    /// m25-s now makes ONE KEYSTROKE long: *"select all, nudge everything one
    /// 16th to fix the timing, and the clip silently grows toward a forgotten note
    /// at bar 20"*. Before m25-s that selection took a rubber band; now ⌘A does
    /// it. The filter is what stops the growth, and this pins that ⌘A's OWN verb
    /// — not a hand-assigned `selection` — still goes through it.
    ///
    /// ⭐ THE ANTI-VACUITY HALF IS THE POINT: the unfiltered set really would grow
    /// the clip, so the `nil` is the filter working rather than the rule declining
    /// anyway. (Fixture distances lifted from `NotePasteLandingTests`, where the
    /// `maxGrowthBars` cap was measured to bound — not close — this hazard.)
    @Test("⚠️ ⌘A then a nudge still cannot grow the clip toward a latent note (m25-f-3)")
    @MainActor
    func selectAllThenNudgeCannotGrowTheClip() {
        let model = PianoRollModel()
        let audible = note(60, 1)
        let latent = note(72, 20)
        model.load(notes: [audible, latent], clipLengthBeats: 4)

        // THE ⌘A PATH ITSELF, not `model.selection = [...]`.
        model.selectAllNotes()
        #expect(model.selection == [audible.id, latent.id])

        model.beginMove(anchorID: audible.id)
        let mayGrow = model.moveIDsStartingAudible()
        #expect(mayGrow == [audible.id], "the latent note must be filtered out")

        let span = ClipAutoExtend.coverage(of: model.draft, ids: mayGrow)
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: span?.onsetBeat ?? 0,
            coveringEndBeat: span?.endBeat ?? 0, beatsPerBar: 4) == nil)

        // ANTI-VACUITY: without the filter, this selection grows a 4-beat clip to 24.
        let unfiltered = ClipAutoExtend.coverage(of: model.draft, ids: model.selection)
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: unfiltered?.onsetBeat ?? 0,
            coveringEndBeat: unfiltered?.endBeat ?? 0, beatsPerBar: 4) == 24)
    }

    // MARK: - The bridge

    @Test("requestSelectAll bumps its OWN nonce and no other")
    @MainActor
    func requestSelectAllBumpsOnlyItsOwnNonce() {
        let bridge = PianoRollNoteSelectionBridge()
        let stage = bridge.stageNonce
        let delete = bridge.deleteNonce
        let clipboard = bridge.clipboardNonce
        let marquee = bridge.marqueeStageNonce

        bridge.requestSelectAll()

        #expect(bridge.selectAllNonce == 1)
        // ⚠️ THE WHOLE DESIGN OF m25-s IN FOUR ASSERTIONS. If `requestSelectAll`
        // is ever "simplified" to call `stage(selectAll: true)`, the user's
        // keystroke starts riding the m23-x DEBUG seam — which also carries
        // m23-ak's production CLEAR — and these go red.
        #expect(bridge.stageNonce == stage, "⌘A must NOT ride the m23-x staging nonce")
        #expect(bridge.deleteNonce == delete)
        #expect(bridge.clipboardNonce == clipboard)
        #expect(bridge.marqueeStageNonce == marquee)
    }

    @Test("re-asking selects again — the nonce climbs, so a second ⌘A is a second request")
    @MainActor
    func requestSelectAllIsRepeatable() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.requestSelectAll()
        bridge.requestSelectAll()
        #expect(bridge.selectAllNonce == 2)
    }

    @Test("the staging seam still works and still means what it did")
    @MainActor
    func stagingSeamIsUntouched() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.stage(selectAll: true)
        #expect(bridge.stagedSelectAll)
        #expect(bridge.stageNonce == 1)
        #expect(bridge.selectAllNonce == 0, "the seam must not fire the user's route either")
    }

    // MARK: - Selector routing

    @Test("selectAll: is claimed, and is NOT a clipboard verb")
    func selectAllIsClaimedButNotAClipboardVerb() {
        #expect(ClipboardResponderRouting.selectAllSelectorName == "selectAll:")
        #expect(ClipboardResponderRouting.claimedSelectorNames.contains("selectAll:"))
        // ⚠️ THE TRAP `ClipboardResponder.validateMenuItem` ORDERS AROUND: this
        // is nil, so a caller that reaches the verb lookup FIRST would treat a
        // claimed selector as "not ours" and leave the item permanently enabled.
        #expect(ClipboardResponderRouting.verb(forSelectorName: "selectAll:") == nil)
    }

    @Test("the claimed list is the clipboard three PLUS select-all, in menu order")
    func claimedListShape() {
        #expect(ClipboardResponderRouting.clipboardSelectorNames
                == ["cut:", "copy:", "paste:"])
        #expect(ClipboardResponderRouting.claimedSelectorNames
                == ["cut:", "copy:", "paste:", "selectAll:"])
        // The round-trip invariant now holds over the CLIPBOARD subset only.
        for name in ClipboardResponderRouting.clipboardSelectorNames {
            #expect(ClipboardResponderRouting.verb(forSelectorName: name) != nil)
        }
        // ⚠️ `delete:` STAYS OUT. m25-s is not a precedent for it — the ⌫ key
        // already routes through `DeleteKeyMonitorRouting` → `DeleteMenuPolicy`,
        // a fix the user confirmed by hand.
        #expect(!ClipboardResponderRouting.claimedSelectorNames.contains("delete:"))
    }

    @Test("the presentation renders the policy, greyed and live alike")
    func presentationRendersThePolicy() {
        let live = ClipboardResponderRouting.presentation(
            for: SelectAllMenuPolicy.editMenuItem(
                activeSurface: .pianoRoll, isModalPresented: false, rollNoteCount: 2))
        #expect(live.isEnabled)
        #expect(live.title == "Select All")

        let declined = ClipboardResponderRouting.presentation(
            for: SelectAllMenuPolicy.editMenuItem(
                activeSurface: .arrange, isModalPresented: false, rollNoteCount: 2))
        #expect(!declined.isEnabled)
        // ⚠️ THE BARE macOS WORDS IN BOTH STATES — the user's 2026-08-12 ruling on
        // this menu group. A qualified "Select All Notes" here would re-open it.
        #expect(declined.title == "Select All")
    }
}
