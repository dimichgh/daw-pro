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
            pianoRollHasNoteSelection: true, automationPointCount: 3, arrangeClipCount: 5)
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
            pianoRollHasNoteSelection: true, automationPointCount: 1, arrangeClipCount: 4)
        #expect(item.refusedBy == .modal)
        #expect(item.title == "Copy")
    }

    @Test("the roll holding a note selection takes Copy, ahead of the arrange")
    func rollNoteSelectionWinsCopy() {
        let item = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: true, automationPointCount: 0, arrangeClipCount: 7)
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
            pianoRollHasNoteSelection: false, automationPointCount: 2, arrangeClipCount: 6)
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
            pianoRollHasNoteSelection: false, automationPointCount: 0, arrangeClipCount: 0)
        #expect(item.refusedBy == .emptySelection)
        #expect(item.title == "Copy")
    }

    @Test("the arrange owns Copy when it has a selection, and the title names the count")
    func arrangeOwnsCopy() {
        let one = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0, arrangeClipCount: 1)
        #expect(one.surface == .arrangeClips)
        #expect(one.title == "Copy Clip")

        let many = ClipboardMenuPolicy.copyMenuItem(
            verb: .copy, arrangeWorkspace: true, isModalPresented: false,
            pianoRollHasNoteSelection: false, automationPointCount: 0, arrangeClipCount: 3)
        #expect(many.title == "Copy 3 Clips")
    }

    @Test("CUT resolves through the SAME body as COPY — only the verb differs")
    func cutMirrorsCopyExactly() {
        // The property this pins: Cut is "Copy, plus the delete that already
        // ships", so its ENABLEMENT can never drift from Copy's. Swept over the
        // whole input space rather than spot-checked, because a drift would
        // most likely appear in one branch only.
        let cases: [(Bool, Bool, Bool, Int, Int)] = [
            (false, false, true, 3, 5), (true, true, true, 1, 4), (true, false, true, 0, 7),
            (true, false, false, 2, 6), (true, false, false, 0, 0), (true, false, false, 0, 1),
            (true, false, false, 0, 3),
        ]
        for (workspace, modal, roll, autoCount, clipCount) in cases {
            let copy = ClipboardMenuPolicy.copyMenuItem(
                verb: .copy, arrangeWorkspace: workspace, isModalPresented: modal,
                pianoRollHasNoteSelection: roll, automationPointCount: autoCount,
                arrangeClipCount: clipCount)
            let cut = ClipboardMenuPolicy.copyMenuItem(
                verb: .cut, arrangeWorkspace: workspace, isModalPresented: modal,
                pianoRollHasNoteSelection: roll, automationPointCount: autoCount,
                arrangeClipCount: clipCount)
            #expect(copy.surface == cut.surface)
            #expect(copy.refusedBy == cut.refusedBy)
            #expect(copy.isEnabled == cut.isEnabled)
            // The titles differ ONLY in the verb.
            #expect(cut.title == copy.title.replacingOccurrences(of: "Copy", with: "Cut"))
        }
    }

    @Test("every Copy/Cut refusal branch is reachable and distinctly named")
    func everyCopyRefusalIsReachable() {
        // The `refusedBy` idiom exists so a test that meant to prove one guard
        // cannot silently pass on another. That is only true if each branch is
        // actually reachable — swept here so a future reordering that shadows
        // one guard fails loudly.
        var seen: Set<ClipboardMenuRefusal> = []
        for verb in [ClipboardVerb.copy, .cut] {
            seen.insert(ClipboardMenuPolicy.copyMenuItem(
                verb: verb, arrangeWorkspace: false, isModalPresented: false,
                pianoRollHasNoteSelection: false, automationPointCount: 0,
                arrangeClipCount: 1).refusedBy!)
            seen.insert(ClipboardMenuPolicy.copyMenuItem(
                verb: verb, arrangeWorkspace: true, isModalPresented: true,
                pianoRollHasNoteSelection: false, automationPointCount: 0,
                arrangeClipCount: 1).refusedBy!)
            seen.insert(ClipboardMenuPolicy.copyMenuItem(
                verb: verb, arrangeWorkspace: true, isModalPresented: false,
                pianoRollHasNoteSelection: false, automationPointCount: 1,
                arrangeClipCount: 1).refusedBy!)
            seen.insert(ClipboardMenuPolicy.copyMenuItem(
                verb: verb, arrangeWorkspace: true, isModalPresented: false,
                pianoRollHasNoteSelection: false, automationPointCount: 0,
                arrangeClipCount: 0).refusedBy!)
        }
        #expect(seen == [.workspace, .modal, .automationSelection, .emptySelection])
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
