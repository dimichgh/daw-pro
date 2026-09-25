import Testing
import Foundation
@testable import DAWAppKit

/// m23-cf (second pass) — the DELETE **key**'s routing decision.
///
/// ═══ THE BUG, AND WHY IT IS THIS SUITE'S JOB ═══
///
/// A user reported that selecting a note and pressing DELETE did nothing, and
/// that a freshly double-click-created clip could be dragged but not deleted.
/// One defect: THREE views claim `.onKeyPress(.delete)` — `PianoRollView`,
/// `AutomationLaneEditor` and `ContentView`'s `ArrangeDeleteKey` — each behind
/// its own `@FocusState`, and only one view can hold focus. Which one is
/// eligible flips on every clip selection (`pianoRollEditorFocused` measured
/// alternating 6 true / 6 false across 12 consecutive selections). Each handler
/// then answered the question its own way, so DELETE did different things on
/// alternate presses — and on one parity it deleted the CLIP while the user had
/// NOTES selected, because `handleArrangeDeleteKey` carried no piano-roll term
/// while `handleArrangeNudgeKey` did.
///
/// THE FIX IS NOT RELIABLE FOCUS ARBITRATION — it is ONE decision that all three
/// claimants consult, so whichever wins the coin flip produces the same result.
/// `DeleteMenuPolicy.keyPress` is that decision, and everything below is about
/// it being ONE rather than three.
///
/// ⚠️⚠️ WHAT THIS SUITE CANNOT REACH, STATED PLAINLY RATHER THAN IMPLIED BY A
/// GREEN RUN: whether a real DELETE keystroke ever ARRIVES at a handler. An
/// unbundled staging binary does not route real key events (the m23-g1 law), and
/// SwiftUI's arbitration between the three `@FocusState` owners is not observable
/// in this tree at all (m23-bw). So the ROUTING is verified here and the
/// DELIVERY is not — which is precisely why the design refuses to depend on
/// delivery reaching any particular one of the three.
@Suite("DELETE key routing (m23-cf, second pass)")
struct DeleteKeyRoutingTests {

    /// Every state the routing is a function of, so the sweeps below read as
    /// state rather than as six positional arguments.
    private struct State {
        var arrangeWorkspace = true
        var modal = false
        var textEditing = false
        var rollNotes = false
        var points = 0
        /// m23-ap p2-del — the NOTE EDITOR (pitch editor pane) is open.
        var pitchEditorOpen = false
        /// m23-ap I4 — the open note editor holds a NOTE SELECTION (the
        /// bridge's `hasNoteSelection`, never engagement or focus).
        var pitchNotes = false
        var clips = 0
    }

    private func key(_ s: State) -> DeleteMenuItem {
        DeleteMenuPolicy.keyPress(
            arrangeWorkspace: s.arrangeWorkspace, isModalPresented: s.modal,
            isTextEditingFocused: s.textEditing, pianoRollHasNoteSelection: s.rollNotes,
            automationPointCount: s.points, pitchEditorOpen: s.pitchEditorOpen,
            pitchEditorHasNoteSelection: s.pitchNotes,
            arrangeClipCount: s.clips)
    }

    private func menu(_ s: State) -> DeleteMenuItem {
        DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: s.arrangeWorkspace, isModalPresented: s.modal,
            pianoRollHasNoteSelection: s.rollNotes,
            automationPointCount: s.points, pitchEditorOpen: s.pitchEditorOpen,
            pitchEditorHasNoteSelection: s.pitchNotes,
            arrangeClipCount: s.clips)
    }

    /// The whole state space (2 × 2 × 2 × 2 × 2 × 2 × 3 × 3 = 576 states).
    /// Counts carry 0/1/many because the plural rule and the "any lane claiming"
    /// rule both change behaviour at 0→1 and neither changes again after.
    ///
    /// ⭐ 144 → 288 AT m23-ap p2-del: the note-editor term DOUBLES the space
    /// rather than adding a lone test beside it, so every law below is proven
    /// with the pane open as well as shut. Some of the new rows are unreachable
    /// in the app (roll notes AND the pitch pane open; the pane open with no
    /// clip selected) — swept anyway, because a pure rule must answer every
    /// input and an unswept row is an answer nobody chose.
    ///
    /// ⭐ 288 → 576 AT m23-ap I4, by the same rule: the pane's NOTE-SELECTION
    /// term doubles it again. Its unreachable half (notes selected with the
    /// pane SHUT — a stale bridge bit) is swept too, and
    /// `aStaleNotesBitWithThePaneShutChangesNothing` pins what it must answer.
    private var allStates: [State] {
        var out: [State] = []
        for arrange in [true, false] {
            for modal in [true, false] {
                for text in [true, false] {
                    for notes in [true, false] {
                        for pitch in [true, false] {
                            for pitchNotes in [true, false] {
                                for points in [0, 1, 3] {
                                    for clips in [0, 1, 4] {
                                        out.append(State(arrangeWorkspace: arrange, modal: modal,
                                                         textEditing: text, rollNotes: notes,
                                                         points: points, pitchEditorOpen: pitch,
                                                         pitchNotes: pitchNotes, clips: clips))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - THE PROPERTY THE WHOLE ITEM RESTS ON

    /// ⚠️ RENAMED at m23-ap I4 from "…exhaustively, over 288 states": the
    /// pane's note-selection term doubled the space (see `allStates`). The claim
    /// and the body are unchanged; only the anti-vacuity counts moved with it.
    @Test("the key route IS the menu route plus one guard — exhaustively, over 576 states")
    func keyRouteIsTheMenuRoutePlusTheTextGuard() {
        // ⭐⭐ THE LOAD-BEARING TEST. m23-cf's fix is "both handlers consult ONE
        // headless ownership decision", and the standing law from m23-x → m23-al
        // is that a guard must MIRROR the condition the shielded surface applies
        // — two computations of one rule is the defect shape that has cost this
        // tree real cycles. A `keyPress` that had been written as its own guard
        // stack could pass every individual assertion below and still disagree
        // with the menu somewhere in the space; this sweeps the space.
        //
        // The claim is exact, not approximate: OUTSIDE text editing the two
        // routes are IDENTICAL (title, surface and refusal), and INSIDE it the
        // key refuses. Nothing else may differ.
        var sawIdentical = 0
        var sawTextRefusal = 0
        for s in allStates {
            let k = key(s)
            if s.textEditing {
                #expect(k.refusedBy == .textEditing)
                #expect(k.surface == nil)
                sawTextRefusal += 1
            } else {
                #expect(k == menu(s))
                sawIdentical += 1
            }
        }
        // ANTI-VACUITY: a sweep that visited nothing, or that fell entirely into
        // one branch, would pass both arms above in silence. (72/72 until
        // m23-ap p2-del doubled the space with the note-editor term; 144/144
        // until m23-ap I4 doubled it with the pane's note-selection term.)
        #expect(sawIdentical == 288)
        #expect(sawTextRefusal == 288)
    }

    @Test("the decision has NO focus term — it cannot be reached, so it cannot be added by accident")
    func focusIsNotATerm() {
        // Structural, and stated as a test because it is the entire premise. If
        // `keyPress` ever grew a focus parameter this would not compile, which is
        // the strongest form this assertion can take. The measurements that
        // rejected focus as a term live on `PianoRollNoteSelectionBridge`
        // (alternating 6/6 across clip switches) and `EditorSurfaceRouter` (C1–C3:
        // two competing `@FocusState` owners in an ancestor/descendant pair, so
        // the flag is a REPORT of arbitration and no consumer of it is
        // deterministic).
        //
        // The observable half: the SAME state answers the SAME way every time,
        // whichever of the three claimants happens to be asking.
        let s = State(rollNotes: true, points: 2, clips: 5)
        let answers = (0..<8).map { _ in key(s) }
        #expect(Set(answers.map(\.title)).count == 1)
        #expect(answers.allSatisfy { $0.surface == .pianoRollNotes })
    }

    // MARK: - The text-editing guard (the one term the menu route omits)

    @Test("a Backspace typed into a rename field deletes NEITHER clips NOR notes")
    func textEditingRefusesEverySurface() {
        // The destructive failure this guard exists for, on BOTH surfaces. The
        // menu route deliberately omits the term (an item with no key equivalent
        // has no delivery ambiguity, and a responder read would make its enabled
        // state stale — `DeleteMenuPolicy.editMenuItem`'s banner); a KEY has
        // exactly that ambiguity, so the key route re-adds it.
        let withClips = key(State(textEditing: true, clips: 3))
        #expect(withClips.refusedBy == .textEditing)
        #expect(withClips.isEnabled == false)
        let withNotes = key(State(textEditing: true, rollNotes: true, clips: 3))
        #expect(withNotes.refusedBy == .textEditing)
        #expect(withNotes.surface == nil)
        let withPoints = key(State(textEditing: true, points: 2, clips: 3))
        #expect(withPoints.surface == nil)
        // ...and the menu, handed the same state minus the term it does not take,
        // is still LIVE. This is the CONTROL half: without it the assertions above
        // would pass just as happily against a policy that refused everything.
        #expect(menu(State(clips: 3)).surface == .arrangeClips)
        #expect(menu(State(rollNotes: true, clips: 3)).surface == .pianoRollNotes)
    }

    @Test("the text-editing guard is reported FIRST — a gate aiming at it cannot be answered by luck")
    func textEditingIsReportedBeforeEveryOtherRefusal() {
        // `AppModel.ArrangeNudgeRefusal`'s doc states why the ORDER of a reported
        // refusal matters: "a leg that meant to test the text-editing guard would
        // pass identically if the selection had quietly emptied, which is how a
        // dead handler slips through a refusal-only test." Ordered first, this
        // guard names itself whatever the rest of the state is — so a gate that
        // forgot to select anything gets `text-editing` and not a plausible
        // `empty-selection` it would have read as a pass.
        //
        // Note this DIVERGES from `handleArrangeDeleteKey`'s order (workspace,
        // modal, textEditing, empty). Deliberate, and free: all four are
        // refusals, so the user-visible outcome is identical either way and only
        // the DIAGNOSTIC changes — for the better.
        #expect(key(State(textEditing: true)).refusedBy == .textEditing)              // vs empty
        #expect(key(State(arrangeWorkspace: false, textEditing: true)).refusedBy == .textEditing)
        #expect(key(State(modal: true, textEditing: true)).refusedBy == .textEditing)
        #expect(key(State(arrangeWorkspace: false, modal: true, textEditing: true,
                          rollNotes: true, points: 3, clips: 9)).refusedBy == .textEditing)
    }

    @Test("`.textEditing` is UNREACHABLE on the menu route — the asymmetry is real, not aspirational")
    func theMenuRouteNeverReportsTheTextRefusal() {
        // The complement of the sweep above, asserted directly on the refusal
        // vocabulary the two routes share. If some future edit taught
        // `editMenuItem` the term, the menu item's enabled state would start
        // going stale (a `Commands` body has no reason to re-evaluate when focus
        // enters a text field) — the exact failure that method's banner rejects.
        for s in allStates {
            #expect(menu(s).refusedBy != .textEditing)
        }
    }

    // MARK: - The precedence, restated on the KEY route

    @Test("notes selected in an open roll win the key — the reported bug, directly")
    func rollWinsOverClips() {
        // THE USER'S FIRST SENTENCE: "selecting a note and pressing delete does
        // not work". On the parity where the ARRANGE won focus, the old key path
        // ran `handleArrangeDeleteKey`, which had NO piano-roll term among its
        // four guards — so DELETE removed the clip the user was editing instead
        // of the notes they had selected inside it. Now every claimant resolves
        // here and gets the roll.
        let item = key(State(rollNotes: true, clips: 5))
        #expect(item.surface == .pianoRollNotes)
        #expect(item.title == "Delete Selected Notes")
    }

    @Test("a roll on screen with NO notes selected lets the key fall through to the clips")
    func rollWithoutNotesFallsThroughToClips() {
        // THE USER'S SECOND SENTENCE: a double-click-created clip that could be
        // dragged but not deleted. The roll opens for ANY single selected MIDI
        // clip and self-focuses on appear, so on the parity where the ROLL won
        // focus the old handler hit `guard !model.selection.isEmpty` and returned
        // `.ignored` — correct in isolation, but the fall-through then depended
        // on SwiftUI bubbling the key to an ancestor, which this tree cannot
        // observe. Routing removes the dependency: the roll's own handler now
        // resolves `.arrangeClips` and deletes the clip itself.
        let item = key(State(clips: 1))
        #expect(item.surface == .arrangeClips)
        #expect(item.title == "Delete Clip")
    }

    @Test("an automation lane holding a breakpoint wins over the clips, and loses to the roll")
    func automationSitsBetween() {
        #expect(key(State(points: 1, clips: 4)).surface == .automationPoints)
        #expect(key(State(rollNotes: true, points: 1, clips: 4)).surface == .pianoRollNotes)
        // The lane editor is the THIRD claimant the original diagnosis did not
        // name (`AutomationLaneEditor.onKeyPress(.delete)`, one mount per
        // expanded track, each with its own `@FocusState`). It routes through the
        // same decision, so a focused lane can no longer eat a DELETE the user
        // aimed at their notes.
        #expect(key(State(points: 3, clips: 0)).title == "Delete 3 Automation Points")
    }

    @Test("the Mix console and a blocking modal both refuse, in that order")
    func workspaceAndModalRefuse() {
        #expect(key(State(arrangeWorkspace: false, rollNotes: true, clips: 5)).refusedBy
            == .workspace)
        #expect(key(State(modal: true, rollNotes: true, clips: 5)).refusedBy == .modal)
        #expect(key(State(arrangeWorkspace: false, modal: true)).refusedBy == .workspace)
    }

    @Test("nothing selected anywhere — nobody owns the key, so it must keep propagating")
    func emptySelectionIsNotOwned() {
        // `surface == nil` is what every call site turns into `.ignored`, and
        // that is load-bearing rather than cosmetic: an unclaimed DELETE has to
        // keep bubbling so unrelated handlers (and AppKit's own) still see it.
        let item = key(State())
        #expect(item.refusedBy == .emptySelection)
        #expect(item.isEnabled == false)
        #expect(item.title == DeleteMenuPolicy.inertTitle)
    }

    // MARK: - m23-ap p2-del — the NOTE EDITOR (pitch editor) pane is open

    @Test("F13: the note editor open on the selected vocal clip — ⌫ never resolves to the clip")
    func noteEditorOpenNeverRoutesToTheClip() {
        // ⛔ RED FIRST, MEASURED 2026-09-24 BEFORE ANY SOURCE CHANGE: written
        // against the six-argument API (no way to tell the policy the pane was
        // open — which IS F13), `key(State(clips: 1))` resolved
        // `.arrangeClips`, i.e. ⌫ deleted the vocal clip the pane showed.
        //
        // THE FIXTURE, AS THE APP FEEDS IT. The pane opens only on the arrange
        // FOCUS clip (`openPitchEditorClip` requires `id == selectedClipID`), so
        // one clip is selected; the vocal is AUDIO, so `openEditorClip` is nil
        // and `pianoRollWouldConsumeKey` is false; no lane holds a breakpoint.
        // The pane-open verdict is the real router's, so the fixture is a
        // reachable state rather than a guess — and the term handed to the
        // policy is that verdict, exactly as `AppModel.pitchEditorPaneOpen`
        // computes it.
        let open = EditorSurfaceRouter.openSurface(workspaceIsArrange: true, rollOpen: false,
                                                   pitchEditorOpen: true)
        #expect(open.reason == .pitchEditorOpen)
        let fixture = State(pitchEditorOpen: open.reason == .pitchEditorOpen, clips: 1)
        let k = key(fixture)
        #expect(k.surface != .arrangeClips,
                "⌫ with the note editor open resolved to \(String(describing: k.surface)) — it would delete the vocal clip the pane is showing")
        // REFUSED BY NAME, so a red gate reads which guard fired…
        #expect(k.surface == nil)
        #expect(k.refusedBy == .pitchEditorOpen)
        #expect(k.title == DeleteMenuPolicy.inertTitle)
        // …and SWALLOWED rather than propagated: the pane owns the key and says
        // why. Handed back, it would re-enter the funnel through the three
        // `.onKeyPress` mounts and then beep.
        #expect(k.consumesKeystroke)
        // The Edit-menu door resolves the SAME decision and is greyed.
        #expect(menu(fixture) == k)
        #expect(menu(fixture).isEnabled == false)
        // CONTROL: the pane SHUT, everything else identical — the shipped
        // behaviour, and the one the user can still reach on purpose by closing
        // the note editor.
        let shut = key(State(clips: 1))
        #expect(shut.surface == .arrangeClips)
        #expect(shut.title == "Delete Clip")
    }

    /// ⚠️ RENAMED AND REWRITTEN TWICE. At m23-ap I4 from "the note editor's
    /// refusal is the ONLY one that swallows the key — every other refusal
    /// still propagates" (`onlyTheNoteEditorRefusalConsumes`), when I4 added
    /// `.pitchEditorNotes` as a SECOND consuming refusal. At m23-ap I7b from
    /// "the note editor's two refusals are the ONLY ones that swallow the key —
    /// every other refusal still propagates" (`onlyTheNoteEditorsRefusalsConsume`):
    /// I7b turned that refusal into a LIVE surface (⌫ clears the selected
    /// notes), so the consuming refusals are p2-del's one again, and a
    /// surface-owned key is swallowed by the `surface != nil` half of the
    /// derivation like every other surface's.
    @Test("the note editor's OPEN refusal is the ONLY refusal that swallows the key — every other refusal still propagates")
    func onlyTheNoteEditorsOpenRefusalConsumes() {
        // `AppModel.handleDeleteKey` bumps the pane's hint nonce on
        // `.pitchEditorOpen` and returns `consumesKeystroke`. Those agree only
        // while this set is exactly that one; a new consuming refusal reddens
        // this line and sends its author to the handler.
        var consuming: Set<DeleteMenuRefusal> = []
        var sawPropagatingRefusal = false
        for s in allStates {
            let k = key(s)
            // THE DERIVATION, pinned over the whole space: a surface owns the
            // key, or the refusal is the open pane's.
            #expect(k.consumesKeystroke == (k.surface != nil || k.refusedBy == .pitchEditorOpen))
            if let refusal = k.refusedBy {
                if k.consumesKeystroke { consuming.insert(refusal) } else { sawPropagatingRefusal = true }
            }
        }
        #expect(consuming == [.pitchEditorOpen])
        // ANTI-VACUITY: the other side of the split is populated too, so this
        // is not a policy that swallows every refusal.
        #expect(sawPropagatingRefusal)
        // The text-editing guard still comes FIRST with the pane open — and with
        // notes selected in it: a Backspace typed into a rename field must reach
        // the field, never clear a note.
        let typing = key(State(textEditing: true, pitchEditorOpen: true, clips: 1))
        #expect(typing.refusedBy == .textEditing)
        #expect(typing.consumesKeystroke == false)
        let typingOverNotes = key(State(textEditing: true, pitchEditorOpen: true, pitchNotes: true,
                                        clips: 1))
        #expect(typingOverNotes.refusedBy == .textEditing)
        #expect(typingOverNotes.surface == nil)
    }

    // MARK: - m23-ap I4 — notes SELECTED in the open note editor

    /// ⚠️ RENAMED AND REWRITTEN at m23-ap I7b from "I4: notes selected in the
    /// open note editor — ⌫ belongs to the notes, never to the clip"
    /// (`noteEditorSelectionOwnsTheKey`). I4 kept this row a REFUSAL on
    /// purpose ("a live item whose only effect is a refusal line would lie")
    /// until ⌫ had an action with a visible result; I7b ships it — ⌫ CLEARS the
    /// selected notes (the user's `delete-clears = yes`), drawn hollow and
    /// dashed — so the row is a LIVE surface now. What I4 proved still holds and
    /// is re-asserted: the clip is never the target, and the key is swallowed.
    @Test("I7b: notes selected in the open note editor — ⌫ is a LIVE Clear of the notes, never the clip")
    func noteEditorSelectionClearsTheNotes() {
        // ⛔ RED FIRST, MEASURED 2026-09-25 BEFORE ANY SOURCE CHANGE: against
        // I4's policy this fixture resolved the REFUSAL `.pitchEditorNotes`, so
        // `surface?.rawValue` read nil and every live-item assertion below went
        // red. Written in raw values and plain fields so it compiled against
        // that source.
        //
        // THE FIXTURE, AS THE APP FEEDS IT: the pane open on the selected vocal
        // clip (the real router's verdict) AND the pane's bridge reporting a
        // note selection.
        let open = EditorSurfaceRouter.openSurface(workspaceIsArrange: true, rollOpen: false,
                                                   pitchEditorOpen: true)
        #expect(open.reason == .pitchEditorOpen)
        let fixture = State(pitchEditorOpen: open.reason == .pitchEditorOpen, pitchNotes: true,
                            clips: 1)
        let k = key(fixture)
        #expect(k.surface != .arrangeClips,
                "⌫ with notes selected in the note editor resolved to \(String(describing: k.surface)) — it would delete the vocal clip")
        #expect(k.surface?.rawValue == "pitch-editor-notes",
                "⌫ with notes selected resolved \(String(describing: k.surface)) / refused \(String(describing: k.refusedBy)) — it must be the notes' LIVE Clear")
        #expect(k.refusedBy == nil)
        #expect(k.isEnabled)
        // THE TITLE SAYS WHAT IT DOES, and carries no count on purpose: the
        // bridge publishes a Bool, and a number this layer does not have would
        // be the honesty violation the design language forbids (the roll's
        // "Delete Selected Notes" precedent). The right-click menu, which can
        // see the selection, carries the count.
        #expect(k.title == "Clear Selected Notes")
        #expect(k.consumesKeystroke)
        // The Edit-menu door resolves the SAME decision and is LIVE.
        #expect(menu(fixture) == k)
        #expect(menu(fixture).isEnabled)
        // CONTROL: the same pane with NO note selected keeps p2-del's refusal,
        // verbatim — the arm only narrows it.
        let nothingSelected = key(State(pitchEditorOpen: true, clips: 1))
        #expect(nothingSelected.refusedBy == .pitchEditorOpen)
        #expect(nothingSelected.surface == nil)
        #expect(nothingSelected.consumesKeystroke)
        // …and with the pane SHUT the clip is the shipped target again.
        #expect(key(State(clips: 1)).surface == .arrangeClips)
    }

    @Test("I4: a stale notes bit with the pane SHUT changes nothing — over all 576 states")
    func aStaleNotesBitWithThePaneShutChangesNothing() {
        // The arm reads openness as well as the bit, so a bridge that failed to
        // clear cannot swallow a ⌫ meant for the clips. Every pane-shut state
        // answers identically with the bit set and clear.
        var compared = 0
        for s in allStates where !s.pitchEditorOpen && s.pitchNotes {
            var clear = s
            clear.pitchNotes = false
            #expect(key(s) == key(clear))
            #expect(menu(s) == menu(clear))
            compared += 1
        }
        // ANTI-VACUITY: a quarter of the space (pane shut × bit set).
        #expect(compared == 144)
        // POSITIVE CONTROL: with the pane OPEN the bit does change the answer
        // somewhere, so the equality above is the openness term talking.
        #expect(allStates.contains { s in
            s.pitchEditorOpen && s.pitchNotes
                && key(s) != key(State(arrangeWorkspace: s.arrangeWorkspace, modal: s.modal,
                                       textEditing: s.textEditing, rollNotes: s.rollNotes,
                                       points: s.points, pitchEditorOpen: true,
                                       pitchNotes: false, clips: s.clips))
        })
    }

    // MARK: - Totality

    /// ⚠️ RENAMED at m23-ap I4 from "…across all 288 states"; the refusal
    /// census below gained I4's `.pitchEditorNotes`. ⚠️ REWRITTEN at m23-ap
    /// I7b (name kept, it is still true): `pitch-editor-notes` moved from the
    /// refusal census to the SURFACE census — a live Clear — so the refusals
    /// are the five below and `seen` must reach the fourth surface.
    @Test("the routing is TOTAL and its two halves are complements across all 576 states")
    func routingIsTotalAndCoherent() {
        var seen: Set<DeleteSurface> = []
        var refusals: Set<DeleteMenuRefusal> = []
        for s in allStates {
            let item = key(s)
            // A live item with a refusal, or a dead one without, would each make
            // the reported reason meaningless — and `deleteKeyHandled` on the
            // debug seam is derived from exactly this complement.
            #expect(item.isEnabled == (item.surface != nil))
            #expect((item.refusedBy == nil) == item.isEnabled)
            if let surface = item.surface { seen.insert(surface) }
            if let refusal = item.refusedBy { refusals.insert(refusal) }
        }
        // ANTI-VACUITY on both sides: every surface AND every refusal is actually
        // produced by some reachable state. A policy that always refused, or one
        // that never reported `.textEditing`, would satisfy the loop above.
        #expect(seen == Set(DeleteSurface.allCases))
        #expect(refusals == Set([.workspace, .modal, .textEditing, .emptySelection,
                                 .pitchEditorOpen]))
        #expect(Set(seen.map(\.rawValue)) == ["piano-roll-notes", "automation-points",
                                             "arrange-clips", "pitch-editor-notes"])
    }
}
