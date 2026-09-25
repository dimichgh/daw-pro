import Testing
import Foundation
import DAWCore
@testable import DAWAppKit

/// m23-ek-3 — the COPY / CUT / PASTE menu routes and the clipboard they read.
///
/// `DAWApp` has no test target, which is the whole reason `ClipboardMenuPolicy`
/// and `EditClipboard` live in DAWAppKit: the decisions (which surface owns the
/// operation, what the item says, when it is disabled, what the clipboard holds)
/// are testable here while `DAWApp` keeps only composition. What these tests
/// CANNOT reach is the mount — whether the `Button`s appear in the Edit menu and
/// whether the bridge nonces arrive in the roll. That residue is covered by
/// `scripts/gates/m23ek-clipboard.mjs` against a staging binary, and by hands.
@Suite("Clipboard menu policy (m23-ek-3)")
struct ClipboardMenuPolicyTests {

    // MARK: - Copy / Cut: the guard stack is Delete's, verbatim

    @Test("the Mix console has no clip selection — Copy is inert there")
    func copyRefusesInMixWorkspace() {
        let item = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: false, isModalPresented: false,
            pianoRollHasNoteSelection: true, automationPointCount: 3,
            pitchEditorOpen: false, arrangeClipCount: 5)
        #expect(item.isEnabled == false)
        #expect(item.surface == nil)
        #expect(item.refusedBy == .workspace)
        // A DISABLED ITEM MUST NOT NAME A BLAST RADIUS — every surface above is
        // richly populated and the title still carries no count. ⭐ RETARGETED
        // 2026-08-12: the title is the BARE macOS word, not the old teaching
        // string ("Copy Selection"), on the user's ruling that a plain greyed
        // "Copy" is the commonly adopted practice.
        #expect(item.title == "Copy")
    }

    @Test("a blocking modal refuses Copy — no acting behind a scrimmed panel")
    func copyRefusesBehindAModal() {
        let item = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: true,
            pianoRollHasNoteSelection: true, automationPointCount: 1,
            pitchEditorOpen: false, arrangeClipCount: 4)
        #expect(item.refusedBy == .modal)
        #expect(item.title == "Copy")
    }

    @Test("the roll holding a note selection takes Copy, ahead of the arrange")
    func rollNoteSelectionWinsCopy() {
        let item = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: true, automationPointCount: 0,
            pitchEditorOpen: false, arrangeClipCount: 7)
        #expect(item.surface == .pianoRollNotes)
        // NO COUNT, and the seven selected clips prove it is not merely absent
        // for want of a number: the bridge publishes a Bool, so this policy does
        // not have the note count and must not invent one.
        #expect(item.title == "Copy Selected Notes")
        #expect(item.refusedBy == nil)
    }

    @Test("a live automation selection REFUSES Copy rather than falling through to the clips")
    func automationSelectionRefusesCopy() {
        let item = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 2,
            pitchEditorOpen: false, arrangeClipCount: 6)
        // THE POINT OF THIS TEST: breakpoints are out of scope in v1, and the
        // honest v1 behaviour is to refuse. Falling through would COPY THE SIX
        // CLIPS while the user has two breakpoints selected — acting on a
        // surface they were not pointing at, and disagreeing with Delete about
        // what the same state means.
        #expect(item.isEnabled == false)
        #expect(item.refusedBy == .automationSelection)
        #expect(item.surface == nil)
    }

    @Test("nothing selected anywhere — Copy is shown but greyed")
    func emptySelectionRefusesCopy() {
        let item = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0,
            pitchEditorOpen: false, arrangeClipCount: 0)
        #expect(item.refusedBy == .emptySelection)
        #expect(item.title == "Copy")
    }

    @Test("the arrange owns Copy when it has a selection, and the title names the count")
    func arrangeOwnsCopy() {
        let one = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0,
            pitchEditorOpen: false, arrangeClipCount: 1)
        #expect(one.surface == .arrangeClips)
        #expect(one.title == "Copy Clip")

        let many = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0,
            pitchEditorOpen: false, arrangeClipCount: 3)
        #expect(many.title == "Copy 3 Clips")
    }

    // MARK: - The Copy/Cut state space (swept by the Cut laws below)

    /// Every input `copyMenuItem` takes besides the verb, so the sweeps read as
    /// state rather than as six positional arguments.
    private struct State {
        var arrange = true
        var modal = false
        var rollNotes = false
        var points = 0
        /// m23-ap p2-del-2 — the NOTE EDITOR (pitch editor pane) is open.
        var pitch = false
        var clips = 0
    }

    private func menuItem(_ verb: ClipboardVerb, _ s: State) -> ClipboardMenuItem {
        ClipboardMenuPolicy.copyMenuItem(
            verb: verb, arrangeWorkspace: s.arrange, isModalPresented: s.modal,
            pianoRollHasNoteSelection: s.rollNotes, automationPointCount: s.points,
            pitchEditorOpen: s.pitch, arrangeClipCount: s.clips)
    }

    /// The whole space: 2 × 2 × 2 × 3 × 2 × 3 = 144 states. Counts carry
    /// 0/1/many because the plural rule and the "any lane claiming" rule both
    /// change behaviour at 0→1 and neither changes again after. Some rows are
    /// unreachable in the app (roll notes AND the note editor open; the pane
    /// open with no clip selected) and are swept anyway: a pure rule must
    /// answer every input, and an unswept row is an answer nobody chose.
    private var allStates: [State] {
        var out: [State] = []
        for arrange in [true, false] {
            for modal in [true, false] {
                for notes in [true, false] {
                    for points in [0, 1, 3] {
                        for pitch in [true, false] {
                            for clips in [0, 1, 4] {
                                out.append(State(arrange: arrange, modal: modal, rollNotes: notes,
                                                 points: points, pitch: pitch, clips: clips))
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    @Test("CUT resolves through the SAME body as COPY — identical everywhere except where the note editor refuses Cut, over 144 states")
    func cutMirrorsCopyExceptTheNoteEditor() {
        // The property this pins: Cut is "Copy, plus the delete that already
        // ships", so its ENABLEMENT can never drift from Copy's — with ONE named
        // exception since m23-ap p2-del-2, and it is that delete: while the note
        // editor is open, Delete refuses, so Cut must too. Copy removes nothing
        // and is not governed.
        //
        // ⚠️ THIS REPLACES A SEVEN-CASE SPOT CHECK THAT PINNED "only the verb
        // differs" — a law the ruling deliberately broke in one place. It is
        // rewritten as the new law, swept over the whole space, because a drift
        // would most likely appear in one branch only.
        var sawIdentical = 0
        var sawNoteEditorRefusal = 0
        for s in allStates {
            let copy = menuItem(.copy, s)
            let cut = menuItem(.cut, s)
            let governed = s.arrange && !s.modal && !s.rollNotes && s.points == 0 && s.pitch
            if governed {
                #expect(cut.refusedBy == .pitchEditorOpen)
                #expect(cut.surface == nil)
                #expect(cut.title == "Cut")
                // COPY ANSWERS WHAT IT ANSWERED BEFORE: its answer with the pane shut.
                var shut = s
                shut.pitch = false
                #expect(copy == menuItem(.copy, shut))
                sawNoteEditorRefusal += 1
            } else {
                #expect(copy.surface == cut.surface)
                #expect(copy.refusedBy == cut.refusedBy)
                #expect(copy.isEnabled == cut.isEnabled)
                // The titles differ ONLY in the verb.
                #expect(cut.title == copy.title.replacingOccurrences(of: "Copy", with: "Cut"))
                sawIdentical += 1
            }
            // THE UNGOVERNED HALF, PROVEN OVER THE WHOLE SPACE: Copy never
            // refuses on the pane, and flipping the pane never changes its answer.
            #expect(copy.refusedBy != .pitchEditorOpen)
            var flipped = s
            flipped.pitch.toggle()
            #expect(copy == menuItem(.copy, flipped))
        }
        // ANTI-VACUITY: both arms populated, and the divergence is exactly the
        // three governed rows (arrange, no modal, no roll notes, no points, the
        // pane open × clips 0/1/4).
        #expect(sawIdentical == 141)
        #expect(sawNoteEditorRefusal == 3)
    }

    @Test("Cut removes clips exactly where Delete would, and refuses on the note editor exactly where Delete does — over 144 states")
    func cutRefusesExactlyWhereDeleteDoes() {
        // THE SAME OPENNESS VERDICT, TWO DOORS. Cut is "Copy plus the delete",
        // so the states in which Cut may remove arrange clips must be the states
        // in which Delete may, and the note editor must refuse both in the same
        // states. `DeleteMenuPolicy.editMenuItem` takes the same six inputs (its
        // text-editing guard is the KEY route's, not the menu's), so the two are
        // compared state for state.
        var sawRemoval = 0
        var sawNoteEditorRefusal = 0
        for s in allStates {
            let cut = menuItem(.cut, s)
            let delete = DeleteMenuPolicy.editMenuItem(
                arrangeWorkspace: s.arrange, isModalPresented: s.modal,
                pianoRollHasNoteSelection: s.rollNotes, automationPointCount: s.points,
                pitchEditorOpen: s.pitch,
                // Cut has no note term (there is no note clipboard): ⌘X keeps
                // p2-del-2's refusal with notes selected. The notes arm is
                // Delete's alone, swept in `DeleteKeyRoutingTests` (m23-ap I4).
                pitchEditorHasNoteSelection: false, arrangeClipCount: s.clips)
            #expect((cut.surface == .arrangeClips) == (delete.surface == .arrangeClips))
            #expect((cut.refusedBy == .pitchEditorOpen) == (delete.refusedBy == .pitchEditorOpen))
            if cut.surface == .arrangeClips { sawRemoval += 1 }
            if cut.refusedBy == .pitchEditorOpen { sawNoteEditorRefusal += 1 }
        }
        // ANTI-VACUITY: removal happens only with the pane shut (clips 1 and 4);
        // the refusal only with it open (clips 0, 1 and 4).
        #expect(sawRemoval == 2)
        #expect(sawNoteEditorRefusal == 3)
    }

    @Test("every Copy/Cut refusal branch is reachable and distinctly named")
    func everyCopyRefusalIsReachable() {
        // The `refusedBy` idiom exists so a test that meant to prove one guard
        // cannot silently pass on another. That is only true if each branch is
        // actually reachable — swept here so a future reordering that shadows
        // one guard fails loudly. (No force-unwraps: a live item where a
        // refusal was expected must read as a set mismatch, not crash the run.)
        var seen: Set<ClipboardMenuRefusal> = []
        for verb in [ClipboardVerb.copy, .cut] {
            for s in [State(arrange: false, clips: 1), State(modal: true, clips: 1),
                      State(points: 1, clips: 1), State(clips: 0)] {
                if let refusal = menuItem(verb, s).refusedBy { seen.insert(refusal) }
            }
        }
        // m23-ap p2-del-2 — the fifth, CUT ONLY. Copy handed the very same state
        // stays live on the clip: the ungoverned half.
        if let refusal = menuItem(.cut, State(pitch: true, clips: 1)).refusedBy { seen.insert(refusal) }
        #expect(menuItem(.copy, State(pitch: true, clips: 1)).surface == .arrangeClips)
        #expect(seen == [.workspace, .modal, .automationSelection, .pitchEditorOpen, .emptySelection])
    }

    // MARK: - m23-ap p2-del-2 — the NOTE EDITOR (pitch editor) pane is open

    @Test("⌘X with the note editor open on the selected vocal clip never cuts the clip")
    func noteEditorOpenNeverCutsTheClip() {
        // ⛔ RED FIRST, MEASURED 2026-09-24 BEFORE ANY SOURCE CHANGE: written
        // against the six-argument API (no way to tell the policy the pane was
        // open), this fixture failed with "(cut.surface → .arrangeClips) !=
        // .arrangeClips" — Edit ▸ Cut, and so ⌘X, would have cut the vocal clip
        // the pane showed.
        //
        // THE FIXTURE, AS THE APP FEEDS IT — F13's (`DeleteKeyRoutingTests`),
        // because Cut is "Copy plus the delete": the pane opens only on the
        // arrange FOCUS clip, so one clip is selected; the vocal is AUDIO, so no
        // roll is open and `pianoRollWouldConsumeKey` is false; no lane holds a
        // breakpoint. The pane-open verdict is the real router's, and the term
        // handed to the policy is that verdict, as `AppModel.pitchEditorPaneOpen`
        // computes it.
        let open = EditorSurfaceRouter.openSurface(workspaceIsArrange: true, rollOpen: false,
                                                   pitchEditorOpen: true)
        #expect(open.reason == .pitchEditorOpen)
        let fixture = State(pitch: open.reason == .pitchEditorOpen, clips: 1)
        let cut = menuItem(.cut, fixture)
        #expect(cut.surface != .arrangeClips,
                "⌘X with the note editor open resolved to \(String(describing: cut.surface)) — it would cut the vocal clip the pane is showing")
        // REFUSED BY NAME, so a red gate reads which guard fired…
        #expect(cut.surface == nil)
        #expect(cut.refusedBy == .pitchEditorOpen)
        #expect(cut.title == "Cut")
        // …and the native Edit ▸ Cut item GREYS. That is what makes ⌘X do
        // nothing: a greyed item's key equivalent runs no action (measured for
        // ⌘A at m25-s; `AppModel.performMenuSelectAll`'s doc).
        #expect(ClipboardResponderRouting.presentation(for: cut).isEnabled == false)
        // COPY IS NOT GOVERNED — it removes nothing. Same fixture, still live.
        let copy = menuItem(.copy, fixture)
        #expect(copy.surface == .arrangeClips)
        #expect(copy.title == "Copy Clip")
        // CONTROL: the pane SHUT, everything else identical — the shipped
        // behaviour, and the one the user reaches on purpose by closing the
        // note editor.
        let shut = menuItem(.cut, State(clips: 1))
        #expect(shut.surface == .arrangeClips)
        #expect(shut.title == "Cut Clip")
    }

    // MARK: - Paste routes on clipboard KIND, not on a selection

    @Test("an empty clipboard refuses Paste, ahead of every other guard")
    func emptyClipboardRefusesPaste() {
        // Deliberately in the state where EVERY other guard would also pass:
        // the reported refusal must still be the clipboard's, because "you have
        // not copied anything" is the fact the user needs.
        let item = ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: nil, clipCount: 0, noteCount: 0,
            arrangeWorkspace: true, isModalPresented: false, rollOpen: true, trackCount: 4)
        #expect(item.refusedBy == .emptyClipboard)
        #expect(item.title == "Paste")
        #expect(item.isEnabled == false)
    }

    @Test("Paste is inert in the Mix console and behind a modal")
    func pasteRefusesOnWorkspaceAndModal() {
        #expect(ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .clips, clipCount: 2, noteCount: 0,
            arrangeWorkspace: false, isModalPresented: false, rollOpen: false,
            trackCount: 4).refusedBy == .workspace)
        #expect(ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .clips, clipCount: 2, noteCount: 0,
            arrangeWorkspace: true, isModalPresented: true, rollOpen: false,
            trackCount: 4).refusedBy == .modal)
    }

    @Test("a NOTE payload needs a roll on screen — not a note selection")
    func notePayloadNeedsARoll() {
        let closed = ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .notes, clipCount: 0, noteCount: 12,
            arrangeWorkspace: true, isModalPresented: false, rollOpen: false, trackCount: 4)
        #expect(closed.refusedBy == .noRollOpen)

        let open = ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .notes, clipCount: 0, noteCount: 12,
            arrangeWorkspace: true, isModalPresented: false, rollOpen: true, trackCount: 4)
        #expect(open.surface == .pianoRollNotes)
        // ⚠️ PASTE CAN NAME THE NOTE COUNT where Copy cannot — the number comes
        // from the CLIPBOARD, which this policy holds, not from the bridge that
        // publishes a Bool. The asymmetry is deliberate; this test is what stops
        // someone "fixing" it into consistency.
        #expect(open.title == "Paste 12 Notes")
    }

    @Test("a CLIP payload needs at least one track, and pastes with nothing selected")
    func clipPayloadNeedsATrack() {
        let empty = ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .clips, clipCount: 3, noteCount: 0,
            arrangeWorkspace: true, isModalPresented: false, rollOpen: false, trackCount: 0)
        #expect(empty.refusedBy == .noTracks)

        // NOTHING IS SELECTED and no roll is open, and Paste is still LIVE: its
        // enablement depends on the clipboard, not on a selection. That is the
        // structural difference from the Delete stack, pinned.
        let live = ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .clips, clipCount: 3, noteCount: 0,
            arrangeWorkspace: true, isModalPresented: false, rollOpen: false, trackCount: 2)
        #expect(live.surface == .arrangeClips)
        #expect(live.title == "Paste 3 Clips")
    }

    @Test("the payload's KIND alone picks the surface — a clip payload never lands in the roll")
    func kindAlonePicksTheSurface() {
        // With the roll OPEN and tracks present, both destinations are
        // available; the clipboard's kind is what decides, with nothing else to
        // arbitrate.
        let clips = ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .clips, clipCount: 1, noteCount: 0,
            arrangeWorkspace: true, isModalPresented: false, rollOpen: true, trackCount: 2)
        let notes = ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .notes, clipCount: 0, noteCount: 1,
            arrangeWorkspace: true, isModalPresented: false, rollOpen: true, trackCount: 2)
        #expect(clips.surface == .arrangeClips)
        #expect(clips.title == "Paste Clip")
        #expect(notes.surface == .pianoRollNotes)
        #expect(notes.title == "Paste Note")
    }

    @Test("every Paste refusal branch is reachable and distinctly named")
    func everyPasteRefusalIsReachable() {
        var seen: Set<ClipboardMenuRefusal> = []
        seen.insert(ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: nil, clipCount: 0, noteCount: 0, arrangeWorkspace: true,
            isModalPresented: false, rollOpen: true, trackCount: 1).refusedBy!)
        seen.insert(ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .clips, clipCount: 1, noteCount: 0, arrangeWorkspace: false,
            isModalPresented: false, rollOpen: true, trackCount: 1).refusedBy!)
        seen.insert(ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .clips, clipCount: 1, noteCount: 0, arrangeWorkspace: true,
            isModalPresented: true, rollOpen: true, trackCount: 1).refusedBy!)
        seen.insert(ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .notes, clipCount: 0, noteCount: 1, arrangeWorkspace: true,
            isModalPresented: false, rollOpen: false, trackCount: 1).refusedBy!)
        seen.insert(ClipboardMenuPolicy.pasteMenuItem(
            clipboardKind: .clips, clipCount: 1, noteCount: 0, arrangeWorkspace: true,
            isModalPresented: false, rollOpen: true, trackCount: 0).refusedBy!)
        #expect(seen == [.emptyClipboard, .workspace, .modal, .noRollOpen, .noTracks])
    }

    // MARK: - Context-menu titles

    @Test("right-clicking a SELECTED clip acts on the whole selection; an unselected one does not")
    func clipContextFollowsTheFinderConvention() {
        let inSelection = ClipboardMenuPolicy.clipContextCommand(
            verb: .copy, clickedClipIsSelected: true, arrangeSelectionCount: 3)
        #expect(inSelection.targetsWholeSelection)
        #expect(inSelection.title == "Copy 3 Clips")

        let outside = ClipboardMenuPolicy.clipContextCommand(
            verb: .cut, clickedClipIsSelected: false, arrangeSelectionCount: 3)
        #expect(outside.targetsWholeSelection == false)
        #expect(outside.title == "Cut Clip")
    }

    @Test("a selected-clicked clip with a zero count degrades to the clicked clip, never a no-op")
    func clipContextDegradesSafely() {
        // Violates `ArrangeSelection`'s INV2 and cannot occur — resolved rather
        // than trusted, so a future caller bug degrades to "act on the one you
        // pointed at" instead of copying nothing.
        let command = ClipboardMenuPolicy.clipContextCommand(
            verb: .copy, clickedClipIsSelected: true, arrangeSelectionCount: 0)
        #expect(command.targetsWholeSelection == false)
        #expect(command.title == "Copy Clip")
    }

    @Test("the roll's own context menu CAN count notes, and shows a plural title when empty")
    func noteContextTitles() {
        #expect(ClipboardMenuPolicy.noteContextTitle(verb: .copy, selectedNoteCount: 1) == "Copy Note")
        #expect(ClipboardMenuPolicy.noteContextTitle(verb: .cut, selectedNoteCount: 5) == "Cut 5 Notes")
        // Zero is a DISABLED item that still appears — "the operation exists and
        // it needs a selection" is exactly what the reported bug denied users.
        #expect(ClipboardMenuPolicy.noteContextTitle(verb: .copy, selectedNoteCount: 0) == "Copy Notes")
        #expect(ClipboardMenuPolicy.notePasteContextTitle(noteCount: 4) == "Paste 4 Notes")
        #expect(ClipboardMenuPolicy.notePasteContextTitle(noteCount: 0) == "Paste")
    }

    // MARK: - The empty-lane right-click Paste (m25-f-4)

    @Test("an empty lane with clips on the clipboard offers a COUNTED Paste")
    func laneContextPasteIsLiveAndCounted() {
        let item = ClipboardMenuPolicy.laneContextPasteItem(
            clipboardKind: .clips, clipCount: 3, hasTargetTrack: true)
        #expect(item.isEnabled)
        #expect(item.surface == .arrangeClips)
        #expect(item.refusedBy == nil)
        // The right-click menus name their blast radius (`clipContextCommand`);
        // only the EDIT menu was stripped to bare words on 2026-08-12.
        #expect(item.title == "Paste 3 Clips")
        #expect(ClipboardMenuPolicy.laneContextPasteItem(
            clipboardKind: .clips, clipCount: 1, hasTargetTrack: true).title == "Paste Clip")
    }

    @Test("an empty clipboard shows Paste GREYED rather than hiding it")
    func laneContextPasteWithNothingCopied() {
        let item = ClipboardMenuPolicy.laneContextPasteItem(
            clipboardKind: nil, clipCount: 0, hasTargetTrack: true)
        #expect(item.isEnabled == false)
        #expect(item.refusedBy == .emptyClipboard)
        // The bare greyed word — the user learns the operation exists and that
        // it needs something copied. A present, ENABLED item that then does
        // nothing is the defect class this item was written to avoid.
        #expect(item.title == "Paste")
    }

    @Test("a NOTES payload refuses on the lane, and NOT with the Edit menu's reason")
    func laneContextPasteRefusesNotes() {
        let item = ClipboardMenuPolicy.laneContextPasteItem(
            clipboardKind: .notes, clipCount: 0, hasTargetTrack: true)
        #expect(item.isEnabled == false)
        // ⚠️ `.notesPayload`, never `.noRollOpen`: opening a roll cannot help
        // here, because notes never land in the arrange at all. A refusal that
        // names an action which cannot help is worse than a bare refusal.
        #expect(item.refusedBy == .notesPayload)
        #expect(item.title == "Paste")
    }

    @Test("a point that names no lane refuses — the gap, the extras, an empty project")
    func laneContextPasteNeedsALane() {
        let item = ClipboardMenuPolicy.laneContextPasteItem(
            clipboardKind: .clips, clipCount: 2, hasTargetTrack: false)
        #expect(item.isEnabled == false)
        #expect(item.refusedBy == .noLaneTarget)
        #expect(item.title == "Paste")
    }

    @Test("the clipboard is asked BEFORE the pointer — a notes payload says so wherever you click")
    func laneContextPastePrecedence() {
        // Both guards would fire; the reported one must be the clipboard's,
        // because moving the pointer cannot fix a notes payload.
        let item = ClipboardMenuPolicy.laneContextPasteItem(
            clipboardKind: .notes, clipCount: 0, hasTargetTrack: false)
        #expect(item.refusedBy == .notesPayload)
    }

    @Test("every empty-lane Paste refusal branch is reachable and distinctly named")
    func everyLaneContextPasteRefusalIsReachable() {
        var seen: Set<ClipboardMenuRefusal> = []
        seen.insert(ClipboardMenuPolicy.laneContextPasteItem(
            clipboardKind: nil, clipCount: 0, hasTargetTrack: true).refusedBy!)
        seen.insert(ClipboardMenuPolicy.laneContextPasteItem(
            clipboardKind: .notes, clipCount: 0, hasTargetTrack: true).refusedBy!)
        seen.insert(ClipboardMenuPolicy.laneContextPasteItem(
            clipboardKind: .clips, clipCount: 1, hasTargetTrack: false).refusedBy!)
        #expect(seen == [.emptyClipboard, .notesPayload, .noLaneTarget])
        // ⚠️ NO TRACK-KIND REFUSAL IS REACHABLE HERE, DELIBERATELY: whether the
        // payload fits THIS lane is per-clip (`Track.canHold` inside
        // `PasteAnchorPolicy`) and surfaces as a named skip in the amber bubble.
        // A menu-time kind guard could only ever be partial for a payload
        // spanning an audio and an instrument track.
        #expect(seen.contains(.noTracks) == false)
    }

    // MARK: - EditMenuTitles — the ONE plural producer

    @Test("the hoisted plural rule reproduces DeleteMenuPolicy's titles character for character")
    func deleteTitlesSurviveTheHoist() {
        // The acceptance criterion for the m23-ek-3 refactor, stated as a test
        // rather than trusted to `DeleteMenuPolicyTests` staying green: the verb
        // moved from a hardcoded literal to a parameter, and this is what pins
        // that the output did not move with it.
        #expect(DeleteMenuPolicy.countedTitle(1, "Clip", "Clips") == "Delete Clip")
        #expect(DeleteMenuPolicy.countedTitle(3, "Clip", "Clips") == "Delete 3 Clips")
        #expect(DeleteMenuPolicy.countedTitle(1, "Automation Point", "Automation Points")
                == "Delete Automation Point")
        #expect(EditMenuTitles.counted(verb: "Delete", count: 2,
                                       singular: "Clip", plural: "Clips") == "Delete 2 Clips")
        // Zero names its count rather than claiming a blast radius of one.
        #expect(EditMenuTitles.counted(verb: "Paste", count: 0,
                                       singular: "Note", plural: "Notes") == "Paste 0 Notes")
    }
}

/// The clipboard itself — what it holds, what it refuses to hold, and how a gate
/// can tell two identical copies apart.
@Suite("EditClipboard (m23-ek-3)")
@MainActor
struct EditClipboardTests {

    private func makeClip(name: String = "C", start: Double = 0) -> Clip {
        Clip(name: name, startBeat: start, lengthBeats: 4, notes: [])
    }

    @Test("a fresh clipboard holds nothing and reports no kind")
    func startsEmpty() {
        let board = EditClipboard()
        #expect(board.payload == nil)
        #expect(board.kind == nil)
        #expect(board.clipCount == 0)
        #expect(board.noteCount == 0)
        #expect(board.seq == 0)
    }

    @Test("putting clips reports the clips kind and its count; notes the notes kind")
    func kindAndCountsAreDerived() {
        let board = EditClipboard()
        #expect(board.put(.clips([
            ClipboardClip(clip: makeClip(), sourceTrackID: UUID(), sourceTrackIndex: 0),
            ClipboardClip(clip: makeClip(), sourceTrackID: UUID(), sourceTrackIndex: 1),
        ])))
        #expect(board.kind == .clips)
        #expect(board.clipCount == 2)
        #expect(board.noteCount == 0)

        #expect(board.put(.notes(ClipboardNotes(
            notes: [MIDINote(pitch: 60, startBeat: 0), MIDINote(pitch: 64, startBeat: 1)],
            sourceClipID: UUID()))))
        #expect(board.kind == .notes)
        #expect(board.noteCount == 2)
        // The sum type means the clip count is now honestly zero, not stale.
        #expect(board.clipCount == 0)
    }

    @Test("an EMPTY payload is refused and leaves the previous contents standing")
    func emptyPayloadIsRefused() {
        let board = EditClipboard()
        let clip = ClipboardClip(clip: makeClip(name: "keep"), sourceTrackID: UUID(),
                                 sourceTrackIndex: 0)
        #expect(board.put(.clips([clip])))
        let seqAfterRealPut = board.seq

        #expect(board.put(.clips([])) == false)
        #expect(board.put(.notes(ClipboardNotes(notes: [], sourceClipID: UUID()))) == false)
        // WHY THIS MATTERS: a clipboard holding `.clips([])` would light Paste up
        // with the title "Paste 0 Clips" and then do nothing — a live menu item
        // that is a no-op. And macOS's own pasteboard does not let a copy that
        // captured nothing destroy what you copied a minute ago.
        #expect(board.clipCount == 1)
        #expect(board.kind == .clips)
        #expect(board.seq == seqAfterRealPut, "a refused put must not look like an event")
    }

    @Test("seq distinguishes two copies of IDENTICAL content")
    func seqSeparatesIdenticalPuts() {
        // The property a gate stands on: copying the same selection twice
        // produces an identical payload, so without a counter there is nothing to
        // wait on and no way to tell "the second copy ran" from "the first is
        // still standing".
        let board = EditClipboard()
        let entry = ClipboardClip(clip: makeClip(), sourceTrackID: UUID(), sourceTrackIndex: 0)
        board.put(.clips([entry]))
        let first = board.seq
        board.put(.clips([entry]))
        #expect(board.seq == first + 1)
    }

    @Test("clear empties the clipboard and is a true no-op when already empty")
    func clearIsIdempotent() {
        let board = EditClipboard()
        board.put(.clips([ClipboardClip(clip: makeClip(), sourceTrackID: UUID(),
                                        sourceTrackIndex: 0)]))
        let loaded = board.seq
        board.clear()
        #expect(board.payload == nil)
        #expect(board.kind == nil)
        #expect(board.seq == loaded + 1, "emptying a loaded clipboard IS an event")
        board.clear()
        #expect(board.seq == loaded + 1, "a clear on an empty clipboard must not tick")
    }
}
