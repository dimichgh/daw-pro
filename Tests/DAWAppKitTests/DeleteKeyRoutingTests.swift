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
        var clips = 0
    }

    private func key(_ s: State) -> DeleteMenuItem {
        DeleteMenuPolicy.keyPress(
            arrangeWorkspace: s.arrangeWorkspace, isModalPresented: s.modal,
            isTextEditingFocused: s.textEditing, pianoRollHasNoteSelection: s.rollNotes,
            automationPointCount: s.points, arrangeClipCount: s.clips)
    }

    private func menu(_ s: State) -> DeleteMenuItem {
        DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: s.arrangeWorkspace, isModalPresented: s.modal,
            pianoRollHasNoteSelection: s.rollNotes,
            automationPointCount: s.points, arrangeClipCount: s.clips)
    }

    /// The whole reachable state space (2 × 2 × 2 × 2 × 3 × 3 = 144 states).
    /// Counts carry 0/1/many because the plural rule and the "any lane claiming"
    /// rule both change behaviour at 0→1 and neither changes again after.
    private var allStates: [State] {
        var out: [State] = []
        for arrange in [true, false] {
            for modal in [true, false] {
                for text in [true, false] {
                    for notes in [true, false] {
                        for points in [0, 1, 3] {
                            for clips in [0, 1, 4] {
                                out.append(State(arrangeWorkspace: arrange, modal: modal,
                                                 textEditing: text, rollNotes: notes,
                                                 points: points, clips: clips))
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - THE PROPERTY THE WHOLE ITEM RESTS ON

    @Test("the key route IS the menu route plus one guard — exhaustively, over 144 states")
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
        // one branch, would pass both arms above in silence.
        #expect(sawIdentical == 72)
        #expect(sawTextRefusal == 72)
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

    // MARK: - Totality

    @Test("the routing is TOTAL and its two halves are complements across all 144 states")
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
        #expect(refusals == Set([.workspace, .modal, .textEditing, .emptySelection]))
    }
}
