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
/// ⭐⭐ **OVERRULED AND RE-POINTED AT m34-d (2026-08-30).** The user reported
/// *"⌘A does nothing on the first press"* and ruled, verbatim: ***"Make it work
/// whenever the editor is open."*** The first guard moved from
/// `EditorSurfaceRouter.resolve` (engagement) to `.openSurface` (mount), and this
/// suite moved with it — **`consumesTheRouterVerdict` below now asserts the exact
/// OPPOSITE of what it asserted for seventeen days**, on purpose and by name.
///
/// ⚠️ **WHAT NO TEST IN THIS REPO CAN SEE.** Nothing here presses ⌘A. The
/// keystroke reaches this app through AppKit's responder chain, and `DAWApp` has
/// no test target — so the suite proves the DECISIONS and the WIRING SHAPE, and
/// the AppKit half was measured out-of-tree with a standalone probe (recorded on
/// `ClipboardResponderRouting.claimedSelectorNames` and
/// `ClipboardResponder.selectAll(_:)`). Do not read a green run here as "⌘A
/// works"; read it as "if the key arrives, this is what happens".
///
/// ⭐ **THE OTHER HALF NOW EXISTS AND IS NAMED**: `scripts/gates/
/// m34d-select-all-editor-open.mjs` posts a REAL ⌘A `NSEvent` through
/// `NSApp.postEvent` on a staging app — the real queue, real
/// `NSApplication.sendEvent`, real main-menu key-equivalent dispatch — and reads
/// the roll's own selection report back over the wire. It is what proves DELIVERY
/// and it is where the TEXT-FIELD guard is pinned, because that guard is
/// STRUCTURAL (AppKit resolves `selectAll:` to the field editor, which sits
/// nearer the front of the chain than we do) and is deliberately NOT a term in
/// the policy below. A unit test cannot see it. ⚠️ Even that gate cannot press a
/// physical key; the first-press fix still wants a human at the keyboard once.
@Suite("⌘A selects all notes in the roll (m25-s; open-not-engaged since m34-d)")
struct SelectAllMenuPolicyTests {

    private func note(_ pitch: Int, _ start: Double, _ length: Double = 1,
                      id: UUID = UUID()) -> MIDINote {
        MIDINote(id: id, pitch: pitch, velocity: 100, startBeat: start, lengthBeats: length)
    }

    /// The ONLY way to build the policy's first argument, and that is the design
    /// rather than test ceremony: `OpenEditorSurface.init` is `fileprivate` to the
    /// router, so every row below is fed a verdict the SHIPPED router computed. A
    /// suite that could hand-build one could pin a rule the app never applies.
    private func open(workspaceIsArrange: Bool = true, rollOpen: Bool = true,
                      pitchEditorOpen: Bool = false) -> OpenEditorSurface {
        EditorSurfaceRouter.openSurface(
            workspaceIsArrange: workspaceIsArrange, rollOpen: rollOpen,
            pitchEditorOpen: pitchEditorOpen)
    }

    // MARK: - The policy

    @Test("the roll is OPEN and holds notes — LIVE, targeting the roll")
    func liveInTheRoll() {
        let item = SelectAllMenuPolicy.editMenuItem(
            openSurface: open(), isModalPresented: false, rollNoteCount: 3, pitchEditorNoteCount: 0)
        #expect(item.surface == .pianoRollNotes)
        #expect(item.isEnabled)
        #expect(item.refusedBy == nil)
        #expect(item.title == "Select All")
    }

    /// ⚠️⚠️ **THE SCOPE GUARD, AND THE REASON THIS ITEM WAS ALLOWED TO EXIST AT
    /// ALL.** `ClipboardResponderRouting` refused `selectAll:` at m25-f-1 partly
    /// because *"there is no arrange-wide 'select all clips' verb in this app
    /// yet, and inventing one here would ship it through a keystroke nobody
    /// reviewed."* That objection was never withdrawn — it became the boundary,
    /// and **m34-d did not touch it**: widening from ENGAGED to OPEN widened
    /// *when* the roll's select-all is live, never *what else* ⌘A may act on.
    /// If this test ever goes green with a non-nil surface, an unreviewed
    /// arrange-wide select-all has shipped.
    @Test("no clip is open — DECLINES, and no arrange-wide select-all was invented")
    func declinesInTheArrange() {
        let item = SelectAllMenuPolicy.editMenuItem(
            openSurface: open(rollOpen: false), isModalPresented: false, rollNoteCount: 3,
            pitchEditorNoteCount: 0)
        #expect(item.surface == nil)
        #expect(!item.isEnabled)
        #expect(item.refusedBy == .noRollOpen)
        // Even greyed, the row reads the bare macOS words — the 2026-08-12 ruling.
        #expect(item.title == "Select All")
    }

    /// ⚠️ THE WORKSPACE TERM, WHICH `EditorSurfaceRouter` CALLS THE EASIEST THING
    /// TO DROP — and dropping it costs MORE here than for zoom. `openEditorClip`
    /// carries no workspace term, so in the Mix console a MIDI clip stays selected
    /// with no `PianoRollView` mounted: without this guard ⌘A would select notes
    /// in a roll that is not even on screen to show what happened.
    ///
    /// ⭐ AND IT IS ITS OWN REFUSAL SINCE m34-d, not folded in with "no clip
    /// open": a red fixture that forgot to leave the mixer and one that forgot to
    /// open a clip are two different bugs.
    @Test("the MIX CONSOLE refuses under its own name, even with a clip open")
    func refusesInTheMixConsole() {
        let item = SelectAllMenuPolicy.editMenuItem(
            openSurface: open(workspaceIsArrange: false, rollOpen: true),
            isModalPresented: false, rollNoteCount: 3, pitchEditorNoteCount: 0)
        #expect(item.surface == nil)
        #expect(item.refusedBy == .notArrangeWorkspace)
    }

    @Test("a modal is up — refuses, matching both sibling policies")
    func refusesBehindAModal() {
        let item = SelectAllMenuPolicy.editMenuItem(
            openSurface: open(), isModalPresented: true, rollNoteCount: 3, pitchEditorNoteCount: 0)
        #expect(item.refusedBy == .modal)
        #expect(!item.isEnabled)
    }

    @Test("the roll's clip is empty — refuses rather than offering a provable no-op")
    func refusesOnAnEmptyRoll() {
        let item = SelectAllMenuPolicy.editMenuItem(
            openSurface: open(), isModalPresented: false, rollNoteCount: 0, pitchEditorNoteCount: 0)
        #expect(item.refusedBy == .emptyRoll)
        #expect(!item.isEnabled)
    }

    /// GUARD ORDER IS OBSERVABLE, and it is pinned for `DeleteMenuRefusal`'s
    /// reason: a refusal-only assertion passes identically against a policy that
    /// refused for the wrong reason, which is how a dead guard survives a suite.
    @Test("guard ORDER: workspace, then roll-open, then modal, then emptiness")
    func guardOrderIsPinned() {
        // Mixer + no roll + modal + empty: the WORKSPACE term must answer first.
        #expect(SelectAllMenuPolicy.editMenuItem(
            openSurface: open(workspaceIsArrange: false, rollOpen: false),
            isModalPresented: true, rollNoteCount: 0, pitchEditorNoteCount: 0)
            .refusedBy == .notArrangeWorkspace)
        // Arrange + no roll + modal + empty: ROLL-OPEN before modal.
        #expect(SelectAllMenuPolicy.editMenuItem(
            openSurface: open(rollOpen: false), isModalPresented: true, rollNoteCount: 0,
            pitchEditorNoteCount: 0)
            .refusedBy == .noRollOpen)
        // Roll open + modal + empty: MODAL before emptiness.
        #expect(SelectAllMenuPolicy.editMenuItem(
            openSurface: open(), isModalPresented: true, rollNoteCount: 0, pitchEditorNoteCount: 0)
            .refusedBy == .modal)
    }

    /// EXHAUSTIVE, the `EditorSurfaceRouterTests` idiom: the rule is a function of
    /// four small values, so sweep them rather than sampling.
    @Test("exhaustive sweep — exactly one state is live")
    func exhaustiveSweep() {
        var live = 0
        for workspaceIsArrange in [false, true] {
            for rollOpen in [false, true] {
                for modal in [false, true] {
                    for count in [0, 1, 7] {
                        let item = SelectAllMenuPolicy.editMenuItem(
                            openSurface: open(workspaceIsArrange: workspaceIsArrange,
                                              rollOpen: rollOpen),
                            isModalPresented: modal, rollNoteCount: count,
                            pitchEditorNoteCount: count)
                        // INV: enabled iff a surface, and the two are never both set.
                        #expect(item.isEnabled == (item.surface != nil))
                        #expect((item.surface == nil) == (item.refusedBy != nil))
                        if item.isEnabled {
                            live += 1
                            #expect(workspaceIsArrange && rollOpen && !modal && count > 0)
                        }
                    }
                }
            }
        }
        // arrange × rollOpen × !modal × {1, 7} = 2
        #expect(live == 2)
    }

    /// m23-ap I4 — the NOTE EDITOR's arm, swept the way the roll's is above.
    @Test("I4: the note editor's arm is live exactly when the pane is open in the arrange, no modal, and it draws notes")
    func noteEditorArmSweep() {
        var live = 0
        for workspaceIsArrange in [false, true] {
            for pitchEditorOpen in [false, true] {
                for modal in [false, true] {
                    for count in [0, 1, 7] {
                        let item = SelectAllMenuPolicy.editMenuItem(
                            openSurface: open(workspaceIsArrange: workspaceIsArrange,
                                              rollOpen: false,
                                              pitchEditorOpen: pitchEditorOpen),
                            isModalPresented: modal, rollNoteCount: 0,
                            pitchEditorNoteCount: count)
                        #expect(item.isEnabled == (item.surface != nil))
                        #expect((item.surface == nil) == (item.refusedBy != nil))
                        if item.isEnabled {
                            live += 1
                            #expect(item.surface == .pitchEditorNotes)
                            #expect(workspaceIsArrange && pitchEditorOpen && !modal && count > 0)
                        }
                        // Guard order on the pane's arm: modal before emptiness.
                        if workspaceIsArrange && pitchEditorOpen && modal {
                            #expect(item.refusedBy == .modal)
                        }
                    }
                }
            }
        }
        // arrange × pane open × !modal × {1, 7} = 2
        #expect(live == 2)
    }

    /// EVERY REFUSAL IS REACHABLE — no dead guard. `EditorSurfaceRouterTests`'s
    /// `everyReasonIsReachable` idiom: a named refusal nothing can produce is a
    /// guard that was removed and left a label behind.
    @Test("every SelectAllRefusal case is produced by some real state")
    func everyRefusalIsReachable() {
        var seen = Set<SelectAllRefusal>()
        for workspaceIsArrange in [false, true] {
            for rollOpen in [false, true] {
                for pitchEditorOpen in [false, true] {
                    for modal in [false, true] {
                        for count in [0, 3] {
                            let item = SelectAllMenuPolicy.editMenuItem(
                                openSurface: open(workspaceIsArrange: workspaceIsArrange,
                                                  rollOpen: rollOpen,
                                                  pitchEditorOpen: pitchEditorOpen),
                                isModalPresented: modal, rollNoteCount: count,
                                pitchEditorNoteCount: count)
                            if let r = item.refusedBy { seen.insert(r) }
                        }
                    }
                }
            }
        }
        #expect(seen == Set(SelectAllRefusal.allCases))
        // ⭐ 4 → 5 AT m23-ap p2-b, whose fifth was `pitchEditorOpen` (⌘A had no
        // meaning in a read-only pane). ⭐ STILL 5 AT m23-ap I4, AND NOT THE SAME
        // FIVE: the pane's arm went LIVE, `pitchEditorOpen` was retired, and
        // `emptyPitchEditor` took its place — the pane refuses only when it
        // draws nothing, under its OWN name rather than the roll's `emptyRoll`
        // or `noRollOpen` (which would tell a red gate "no clip is open" about a
        // pane that is plainly on screen).
        #expect(SelectAllRefusal.allCases.count == 5)
        #expect(!SelectAllRefusal.allCases.map(\.rawValue).contains("pitch-editor-open"))
    }

    /// ⭐⭐ **m34-d — THIS TEST'S ASSERTIONS ARE INVERTED FROM WHAT THEY WERE, AND
    /// THAT INVERSION IS THE FIX.** It used to read *"fed by the real router: roll
    /// open but arrange engaged still declines"* and pin the shipped behaviour as
    /// an accepted consequence, with the note *"if somebody ever overrules that,
    /// this test says where it shows up."* Somebody did: the user, on 2026-08-30,
    /// verbatim — ***"Make it work whenever the editor is open."***
    ///
    /// So this is the FIRST-PRESS CASE, which is the defect they reported: click a
    /// MIDI clip in the arrange, the roll opens, ⌘A must work **without a second
    /// click**. Measured on staging before the fix (a real posted ⌘A selected
    /// nothing) and after.
    ///
    /// THE ROUTER IS STILL CONSUMED, NOT RE-DERIVED — the policy takes a verdict,
    /// so feeding it the shipped router's real output is the honest end-to-end
    /// shape of the decision.
    @Test("fed by the real router: roll merely OPEN is LIVE — the m34-d first press")
    func consumesTheRouterVerdict() {
        // ⭐ THE BUG, NOW THE FEATURE. `resolve` still answers `.arrange` for this
        // state (asserted here, so the two verdicts' DISAGREEMENT is the pin
        // rather than an accident) — and ⌘A no longer asks it.
        let engagementSaysArrange = EditorSurfaceRouter.resolve(
            workspaceIsArrange: true, rollOpen: true, pitchEditorOpen: false,
            lastEngaged: .arrange)
        #expect(engagementSaysArrange.surface == .arrange)
        #expect(engagementSaysArrange.reason == .engagedArrange)

        let firstPress = SelectAllMenuPolicy.editMenuItem(
            openSurface: open(), isModalPresented: false, rollNoteCount: 4, pitchEditorNoteCount: 0)
        #expect(firstPress.surface == .pianoRollNotes)
        #expect(firstPress.isEnabled)
        #expect(firstPress.refusedBy == nil)

        // The MIX CONSOLE still refuses — the workspace term survived the widening.
        #expect(SelectAllMenuPolicy.editMenuItem(
            openSurface: open(workspaceIsArrange: false, rollOpen: true),
            isModalPresented: false, rollNoteCount: 4, pitchEditorNoteCount: 0)
            .refusedBy == .notArrangeWorkspace)
    }

    /// ⭐ **THE ENGAGEMENT LATCH IS NOT A TERM AT ALL ANY MORE**, and this is the
    /// regression guard for the fix rather than a restatement of it: sweep BOTH
    /// latch values through the SHIPPED accessors' terms and require the ⌘A answer
    /// to be identical. A future edit that reintroduced engagement — even as an
    /// "extra safety" conjunct, the shape `PianoRollNoteSelectionBridge` records
    /// as worse than useless — reddens here.
    @Test("engagement cannot influence ⌘A: both latch values give the identical item")
    func theEngagementLatchIsNotATermAtAll() {
        for workspaceIsArrange in [false, true] {
            for rollOpen in [false, true] {
                let verdict = open(workspaceIsArrange: workspaceIsArrange, rollOpen: rollOpen)
                let item = SelectAllMenuPolicy.editMenuItem(
                    openSurface: verdict, isModalPresented: false, rollNoteCount: 4,
                    pitchEditorNoteCount: 0)
                // The latch moves; `openSurface` takes no such parameter, so the
                // only way this could fail is somebody adding one back.
                for latch in EditorSurface.allCases {
                    let engaged = EditorSurfaceRouter.resolve(
                        workspaceIsArrange: workspaceIsArrange,
                        rollOpen: rollOpen, pitchEditorOpen: false, lastEngaged: latch)
                    // The two verdicts genuinely DISAGREE in the m34-d state —
                    // asserted so this sweep cannot pass by them being the same.
                    if workspaceIsArrange && rollOpen && latch == .arrange {
                        #expect(engaged.surface != verdict.surface)
                    }
                    let again = SelectAllMenuPolicy.editMenuItem(
                        openSurface: verdict, isModalPresented: false, rollNoteCount: 4,
                        pitchEditorNoteCount: 0)
                    #expect(again.surface == item.surface)
                    #expect(again.refusedBy == item.refusedBy)
                }
            }
        }
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
                openSurface: open(), isModalPresented: false, rollNoteCount: 2,
                pitchEditorNoteCount: 0))
        #expect(live.isEnabled)
        #expect(live.title == "Select All")

        let declined = ClipboardResponderRouting.presentation(
            for: SelectAllMenuPolicy.editMenuItem(
                openSurface: open(rollOpen: false), isModalPresented: false, rollNoteCount: 2,
                pitchEditorNoteCount: 0))
        #expect(!declined.isEnabled)
        // ⚠️ THE BARE macOS WORDS IN BOTH STATES — the user's 2026-08-12 ruling on
        // this menu group. A qualified "Select All Notes" here would re-open it.
        #expect(declined.title == "Select All")
    }
}
