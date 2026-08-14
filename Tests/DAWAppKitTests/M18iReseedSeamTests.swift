import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// The m18-i external-mutation reseed seam, headless. A wire/arrange-side
/// geometry op (`clip.trim`/`move`/`split`, bar ops, undo/redo) mutates the
/// clip VALUE under the same identity, so the open editor's seeded models must
/// decide staleness themselves: reseed on real divergence, no-op when the
/// editor's own commit echoes back content-equal (the idempotence guard — a
/// double reseed would clobber selection/scroll/the strip's chosen lane).
@MainActor
@Suite("M18i reseed seam")
struct M18iReseedSeamTests {

    // MARK: PianoRollModel

    private func notesABC() -> [MIDINote] {
        [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, velocity: 96, startBeat: 2, lengthBeats: 1),
            MIDINote(pitch: 67, velocity: 104, startBeat: 5, lengthBeats: 1.5),
        ]
    }

    @Test("grid: own-commit echo (reordered, content-equal) needs no reseed")
    func gridSelfEchoNoReseed() {
        let notes = notesABC()
        let m = PianoRollModel(notes: notes, clipLengthBeats: 8)
        // The store re-canonicalizes on commit, so the echo arrives reordered
        // but content-equal — the seam must read it as NOT stale.
        #expect(!m.needsReseed(notes: notes.reversed(), clipLengthBeats: 8))
    }

    @Test("grid: length-only change (trim-extend) is stale — the boundary must move")
    func gridLengthOnlyChangeReseeds() {
        let m = PianoRollModel(notes: notesABC(), clipLengthBeats: 8)
        #expect(m.needsReseed(notes: notesABC(), clipLengthBeats: 13))
    }

    @Test("grid: dropped note (trim-shorter) is stale even at equal length")
    func gridDroppedNoteReseeds() {
        let notes = notesABC()
        let m = PianoRollModel(notes: notes, clipLengthBeats: 8)
        #expect(m.needsReseed(notes: Array(notes.dropLast()), clipLengthBeats: 8))
    }

    @Test("grid: reseed matches a fresh seed and keeps only surviving selection")
    func gridReseedMatchesFreshSeed() {
        let notes = notesABC()
        let m = PianoRollModel(notes: notes, clipLengthBeats: 8)
        m.selection = [notes[0].id, notes[2].id]
        // Wire trim to 4 beats: the store drops the beat-5 note.
        let trimmed = Array(notes.dropLast())
        m.reseed(notes: trimmed, clipLengthBeats: 4)
        let fresh = PianoRollModel(notes: trimmed, clipLengthBeats: 4)
        #expect(m.draft == fresh.draft)
        #expect(m.clipLengthBeats == 4)
        // The surviving selected note stays selected; the dropped id never dangles.
        #expect(m.selection == [notes[0].id])
    }

    // MARK: ControllerStripModel

    private func ccLane(_ controller: Int, beats: [Double]) -> MIDIControllerLane {
        MIDIControllerLane(
            type: .cc(controller: controller),
            points: beats.map { MIDIControllerPoint(beat: $0, value: 60 + Int($0)) })
    }

    @Test("strip: own-commit echo (non-canonical shape, equal content) needs no reseed")
    func stripSelfEchoNoReseed() {
        let lane = ccLane(1, beats: [0, 4, 10])
        let m = ControllerStripModel(lanes: [lane], clipLengthBeats: 13)
        // Same lane content with points in a non-canonical order: the seam
        // canonicalizes the incoming shape before comparing.
        let shuffled = MIDIControllerLane(
            type: .cc(controller: 1),
            points: [10, 0, 4].map { MIDIControllerPoint(beat: $0, value: 60 + Int($0)) })
        #expect(!m.needsReseed(lanes: [shuffled], clipLengthBeats: 13))
    }

    @Test("strip: length-only change is stale — the m18-e ghost boundary rides clipLengthBeats")
    func stripLengthOnlyChangeReseeds() {
        let m = ControllerStripModel(lanes: [ccLane(1, beats: [0, 4, 10])], clipLengthBeats: 8)
        #expect(m.needsReseed(lanes: [ccLane(1, beats: [0, 4, 10])], clipLengthBeats: 13))
    }

    @Test("strip: dropped point (windowed trim) is stale even at equal length")
    func stripDroppedPointReseeds() {
        let m = ControllerStripModel(lanes: [ccLane(1, beats: [0, 4, 10])], clipLengthBeats: 8)
        #expect(m.needsReseed(lanes: [ccLane(1, beats: [0, 4])], clipLengthBeats: 8))
    }

    @Test("strip: reseed keeps the chosen lane when its type survives the trim")
    func stripReseedPreservesChosenLane() {
        let m = ControllerStripModel(
            lanes: [ccLane(1, beats: [0, 4, 10]), ccLane(11, beats: [0, 6])],
            clipLengthBeats: 13)
        m.select(type: .cc(controller: 11))
        // Trim to 4 beats: the store's windowing drops out-of-window points.
        let trimmedLanes = [ccLane(1, beats: [0]), ccLane(11, beats: [0])]
        m.reseed(lanes: trimmedLanes, clipLengthBeats: 4)
        #expect(m.selectedType == .cc(controller: 11))
        #expect(m.draft == trimmedLanes[1].points)
        #expect(m.clipLengthBeats == 4)
    }

    @Test("strip: reseed falls to the first lane when the chosen type was dropped")
    func stripReseedFallsToFirstLaneWhenChosenDropped() {
        let m = ControllerStripModel(
            lanes: [ccLane(1, beats: [0, 4]), ccLane(11, beats: [0, 6])],
            clipLengthBeats: 8)
        m.select(type: .cc(controller: 11))
        // External replace drops the cc11 lane entirely.
        let replaced = [ccLane(1, beats: [0, 4])]
        m.reseed(lanes: replaced, clipLengthBeats: 8)
        #expect(m.selectedType == .cc(controller: 1))
        #expect(m.draft == replaced[0].points)
    }

    // MARK: - m25-f-2 — the seam is what makes a GROWN PASTE visible

    /// ⭐ **THE PROPAGATION LEG OF m25-f-2, AND IT IS NOT OBVIOUS.**
    ///
    /// `ProjectStore.pasteNotes(…, extendToCover:)` grows the clip, but the view
    /// discards the returned `Clip` (`_ = try? store.pasteNotes(…)`) and the roll
    /// keeps its OWN `clipLengthBeats` — the value `playableEndBeat`,
    /// `contentWidth` and `moveIDsStartingAudible` all read. So a store-side
    /// grow that never reached the model would leave the user looking at the
    /// exact defect they reported: notes pasted past a boundary that did not
    /// move. THIS seam is the only thing that carries it across, and it carries
    /// it through the length comparison rather than the note comparison —
    /// `needsReseed`'s FIRST line, before notes are looked at.
    ///
    /// Pinned here rather than in `PasteAutoExtendTests` because it is a
    /// property of the editor model, not of the store, and nothing else covers
    /// it: `m23ek-clipboard.mjs` N2e measured selection survival on a 16-beat
    /// clip where no growth occurs, and the source-site pins cannot execute.
    @Test("m25-f-2: a grown paste reseeds the roll AND keeps the pasted selection")
    func grownPasteReseedsAndKeepsSelection() {
        // The roll as it stands just before the paste: a 4-beat clip, one note.
        let existing = MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let m = PianoRollModel(notes: [existing], clipLengthBeats: 4)

        // The paste, as the view applies it locally: two notes past the end,
        // and they become the selection ("arrives ready to drag").
        let pasted = [MIDINote(pitch: 64, velocity: 100, startBeat: 3, lengthBeats: 1),
                      MIDINote(pitch: 67, velocity: 100, startBeat: 4.5, lengthBeats: 2)]
        m.draft = MIDINote.canonicallyOrdered([existing] + pasted)
        m.selection = Set(pasted.map(\.id))

        // The store's echo: same notes, but the clip GREW to 8 (bar-snapped past
        // the covered end 6.5). Notes alone are content-equal, so the length
        // comparison is the ONLY thing that can call this stale.
        let echoed = MIDINote.canonicallyOrdered([existing] + pasted)
        #expect(m.needsReseed(notes: echoed, clipLengthBeats: 8))

        m.reseed(notes: echoed, clipLengthBeats: 8)

        // The boundary moved — which is the whole user-visible point.
        #expect(m.clipLengthBeats == 8)
        // …and the pasted notes are now inside it, so they draw and sound as
        // placed rather than as latent (strict `<`, engine truth).
        #expect(pasted.allSatisfy { $0.startBeat < m.clipLengthBeats })
        // ⚠️ AND THE SELECTION SURVIVED. `reseed` keeps the ids still present,
        // and the pasted ids are — so the group is still drag-ready. A reseed
        // that cleared it would silently undo m23-ek-3's promise for exactly
        // the pastes m25-f-2 added, and every other test would stay green.
        #expect(m.selection == Set(pasted.map(\.id)))
    }

    /// ANTI-VACUITY for the test above: `reseed` really does DROP ids that are
    /// gone, so "the selection survived" is a result and not a tautology about a
    /// method that never filters anything.
    @Test("m25-f-2 control: reseed still drops selected ids the echo no longer has")
    func reseedStillDropsVanishedSelection() {
        let notes = notesABC()
        let m = PianoRollModel(notes: notes, clipLengthBeats: 8)
        m.selection = Set(notes.map(\.id))
        m.reseed(notes: [notes[0]], clipLengthBeats: 8)
        #expect(m.selection == [notes[0].id])
    }

    @Test("strip: readout truth — the reseeded draft no longer contains a deleted point's value")
    func stripReseedDropsDeletedPointFromDraft() {
        let m = ControllerStripModel(lanes: [ccLane(1, beats: [0, 4, 10])], clipLengthBeats: 13)
        // The filing's evidence: post-trim the readout showed the deleted
        // beat-10 point's value. After reseed the draft holds only the
        // windowed points, so every readout derived from it tells the truth.
        m.reseed(lanes: [ccLane(1, beats: [0, 4])], clipLengthBeats: 4)
        #expect(!m.draft.contains { $0.beat > 4 })
        #expect(m.draft.count == 2)
    }
}
