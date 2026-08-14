import Testing
import Foundation
@testable import DAWCore

/// m25-f-2 — **the paste half of auto-extend.**
///
/// The user, hands-on 2026-08-13: *"Paste notes with no playhead in the clip -
/// generally works, but when I paste to the clip which is smaller then selected
/// notes, it does not expand automatically to accomodate pasted notes"*. The
/// landing logic (`PasteAnchorPolicy`) was already right; what was missing is
/// that `pasteNotes` never consulted `ClipAutoExtend`, so pasted notes past the
/// end stayed latent.
///
/// ⚠️⚠️ **WHY THIS IS A SEPARATE VERB AND NOT `setClipNotes(extendToCover:)`,
/// which already had the rule.** `setClipNotes` journals under
/// `clip.notes:<id>` and the undo journal folds same-key edits inside 800 ms —
/// a paste routed through it within 800 ms of a note drag would FOLD INTO THAT
/// DRAG and one ⌘Z would undo both. `pasteNotes` passes no key. The grow POLICY
/// is shared (`ClipAutoExtend`, a pure namespace); only the journal key differs.
/// `stillUncoalescedWhenItGrows` below is the test that keeps this true — the
/// grow branch added a second label, and a second label is exactly the kind of
/// change that could have quietly acquired a key.
@MainActor
@Suite("ProjectStore — pasteNotes auto-extend (m25-f-2)")
struct PasteAutoExtendTests {

    /// One instrument track, one MIDI clip holding one note at clip-local 0.
    /// Mirrors `ClipAutoExtendStoreTests`' fixture so the two halves of the rule
    /// are compared under identical geometry.
    private func midiClip(lengthBeats: Double = 4, atBeat: Double = 0)
        throws -> (store: ProjectStore, trackID: UUID, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(
            toTrack: track.id, atBeat: atBeat, lengthBeats: lengthBeats,
            notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        return (store, track.id, clip)
    }

    private func liveClip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.flatMap(\.clips).first { $0.id == id }
    }

    /// The engine's scheduling rule, stated once: a note sounds iff its onset is
    /// STRICTLY inside `[0, clipLengthBeats)` (`MIDISchedule.buildEvents`).
    private func isAudible(_ note: MIDINote, in clip: Clip) -> Bool {
        note.startBeat < clip.lengthBeats
    }

    // MARK: - The defect the user reported

    /// ⭐ **THE CENTRAL TEST.** A paste that overruns the clip grows it, and the
    /// pasted notes become AUDIBLE — which is the user's actual complaint, not
    /// "the number changed".
    @Test("a paste landing PAST the clip end grows the clip and the notes SOUND")
    func pastePastEndGrows() throws {
        let (store, _, clip) = try midiClip()          // 4 beats
        // A two-note figure pasted at beat 3: ends at 6.5, past the 4-beat clip.
        let pasted = [MIDINote(pitch: 64, startBeat: 3, lengthBeats: 1),
                      MIDINote(pitch: 67, startBeat: 4.5, lengthBeats: 2)]
        // BEFORE: the second note is latent — this is the reported defect.
        #expect(!isAudible(pasted[1], in: clip))

        let out = try store.pasteNotes(clipID: clip.id,
                                       notes: (clip.notes ?? []) + pasted,
                                       extendToCover: Set(pasted.map(\.id)))

        // Bar-snapped (4/4 ⇒ 4 beats/bar): covered end 6.5 rounds up to 8.
        #expect(out.lengthBeats == 8)
        #expect(pasted.allSatisfy { isAudible($0, in: out) })   // ← the point
        #expect(out.notes?.count == 3)
        #expect(out.startBeat == 0)                             // leading edge never moves
        #expect(store.undoHistory().undo.first == "Paste Notes & Extend Clip")
    }

    /// The other half of the same rule: a paste that FITS must not resize
    /// anything. Without this, "always grow to the next bar" would pass the test
    /// above while quietly reshaping every ordinary paste.
    @Test("a paste landing INSIDE the clip does not resize it")
    func pasteInsideDoesNotGrow() throws {
        let (store, _, clip) = try midiClip(lengthBeats: 8)
        let pasted = [MIDINote(pitch: 64, startBeat: 2, lengthBeats: 1)]
        let out = try store.pasteNotes(clipID: clip.id,
                                       notes: (clip.notes ?? []) + pasted,
                                       extendToCover: Set(pasted.map(\.id)))
        #expect(out.lengthBeats == 8)
        #expect(out.notes?.count == 2)
        #expect(store.undoHistory().undo.first == "Paste Notes")
    }

    /// ⚠️ **THE DEFAULT IS THE PRE-m25-f-2 BEHAVIOUR, BYTE FOR BYTE.** Every
    /// caller that does not name ids — and any future one — keeps writing
    /// past-the-end notes as legal-but-latent data (m18-f). This is what makes
    /// the new parameter additive rather than a contract change.
    @Test("extendToCover defaults to [] and then NOTHING grows")
    func defaultDoesNotGrow() throws {
        let (store, _, clip) = try midiClip()
        let out = try store.pasteNotes(
            clipID: clip.id,
            notes: (clip.notes ?? []) + [MIDINote(pitch: 64, startBeat: 20, lengthBeats: 1)])
        #expect(out.lengthBeats == 4)
        #expect(out.notes?.count == 2)                 // the latent note is KEPT
        #expect(store.undoHistory().undo.first == "Paste Notes")
    }

    // MARK: - The m25-f-3 hazard, and why paste is immune to it

    /// ⚠️⚠️ **THE HAZARD THIS ITEM WAS ASKED TO CHECK FOR, MADE CONCRETE.**
    ///
    /// m25-f-3 had to filter a DRAG's ids to notes whose baseline onset was
    /// inside the clip (`moveIDsStartingAudible`), because ⌘A + a one-16th nudge
    /// would otherwise hand `ClipAutoExtend.coverage` a forgotten latent note at
    /// bar 20 and stretch the clip to it.
    ///
    /// Paste cannot reproduce that, and the reason is structural rather than
    /// lucky: `PasteAnchorPolicy.translatedNotes` mints a fresh `UUID()` per
    /// pasted note, so the id set is DISJOINT from every pre-existing note, and
    /// `coverage(of:ids:)` iterates `notes where ids.contains(note.id)`. A
    /// stationary latent note is therefore unreachable from the paste's span.
    ///
    /// This test states that as behaviour rather than as an argument: the clip
    /// holds a latent note at bar 5 (beat 20), the paste lands at beat 5, and
    /// the clip grows to cover the PASTE ONLY. If someone ever "simplifies"
    /// `coverage` to look at all notes, this goes red at 24 instead of 8.
    @Test("a pre-existing LATENT note does NOT get resurrected by a paste")
    func latentNoteDoesNotWidenTheGrow() throws {
        let (store, _, clip) = try midiClip()          // 4 beats
        let latent = MIDINote(pitch: 48, startBeat: 20, lengthBeats: 1)
        let pasted = [MIDINote(pitch: 64, startBeat: 5, lengthBeats: 1)]

        let out = try store.pasteNotes(
            clipID: clip.id,
            notes: (clip.notes ?? []) + [latent] + pasted,
            extendToCover: Set(pasted.map(\.id)))

        // Grows to cover the PASTE (end 6 → bar line 8), NOT to the latent note
        // at 20 (which would be 24 and is well inside the 16-bar cap, so the cap
        // is not what is doing the work here — the id set is).
        #expect(out.lengthBeats == 8)
        #expect(isAudible(pasted[0], in: out))
        // And the latent note is neither deleted nor made audible: m18-f intact.
        #expect(out.notes?.contains { $0.id == latent.id } == true)
        #expect(!isAudible(latent, in: out))
    }

    // MARK: - The ceilings

    /// **CAP CASE 1 — a REFUSAL, and it is total.** When the covered ONSET sits
    /// beyond `currentLength + 16 bars`, `extendedLength` returns nil and the
    /// clip is left ALONE: notes written, geometry untouched, no error thrown.
    /// That is deliberate (`ClipAutoExtend` step 4) — growing the clip while the
    /// note stayed silent would be the worst of both worlds, an undo entry for
    /// nothing. The user sees the documented latent-note behaviour.
    ///
    /// ⚠️ It is also SILENT, which is a known rough edge tracked as m25-a-2
    /// (telling the user a grow was refused). This test pins today's behaviour
    /// so that item can change it deliberately rather than by accident.
    @Test("16-bar cap, onset beyond it: the grow is REFUSED and nothing changes")
    func capRefusesWhenOnsetIsTooFar() throws {
        let (store, _, clip) = try midiClip()          // 4 beats, 4/4
        // Cap is 4 + 16*4 = 68 beats. An onset at 80 is past it.
        let pasted = [MIDINote(pitch: 64, startBeat: 80, lengthBeats: 1)]
        let out = try store.pasteNotes(clipID: clip.id,
                                       notes: (clip.notes ?? []) + pasted,
                                       extendToCover: Set(pasted.map(\.id)))
        #expect(out.lengthBeats == 4)                  // untouched
        #expect(out.notes?.count == 2)                 // the note is KEPT, latent
        #expect(!isAudible(pasted[0], in: out))
        #expect(store.undoHistory().undo.first == "Paste Notes")   // no "& Extend"
    }

    /// **CAP CASE 2 — a PARTIAL grow, which is a different outcome.** When the
    /// onset is inside the cap but the note's END is not, the length clamps to
    /// `current + 16 bars`: the note SOUNDS (onset strictly inside) but its tail
    /// is truncated by the clip edge. "What happens at the cap" has two answers
    /// depending on where the onset sits, and both ship.
    @Test("16-bar cap, onset inside but END past it: PARTIAL grow, note still sounds")
    func capClampsButKeepsTheNoteAudible() throws {
        let (store, _, clip) = try midiClip()          // 4 beats, cap ⇒ 68
        let pasted = [MIDINote(pitch: 64, startBeat: 60, lengthBeats: 30)]  // ends 90
        let out = try store.pasteNotes(clipID: clip.id,
                                       notes: (clip.notes ?? []) + pasted,
                                       extendToCover: Set(pasted.map(\.id)))
        #expect(out.lengthBeats == 68)                 // 4 + 16 bars, not 92
        #expect(isAudible(pasted[0], in: out))         // onset 60 < 68
        #expect(store.undoHistory().undo.first == "Paste Notes & Extend Clip")
    }

    /// ⚠️⚠️ **THE GROW NEVER EATS A NEIGHBOUR.** A grow is routed through
    /// `resolvingOverlaps`, and that choke point resolves an overlap by TRIMMING
    /// OR DELETING the stationary clip — so a paste in the piano roll could
    /// otherwise silently destroy part of a clip the user is not even looking
    /// at. `trailingHeadroom` is the ceiling; a clamped result may be mid-bar.
    @Test("growth is bounded by the NEXT CLIP and never trims it")
    func growthStopsAtTheNeighbour() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(
            toTrack: track.id, atBeat: 0, lengthBeats: 4,
            notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let neighbour = try store.addMIDIClip(
            toTrack: track.id, atBeat: 6, lengthBeats: 4,
            notes: [MIDINote(pitch: 72, startBeat: 0, lengthBeats: 1)])

        // Wants to reach bar line 8; the neighbour starts at 6.
        let pasted = [MIDINote(pitch: 64, startBeat: 5, lengthBeats: 1)]
        let out = try store.pasteNotes(clipID: clip.id,
                                       notes: (clip.notes ?? []) + pasted,
                                       extendToCover: Set(pasted.map(\.id)))

        #expect(out.lengthBeats == 6)                  // mid-bar, clamped to headroom
        #expect(isAudible(pasted[0], in: out))         // onset 5 < 6 — still sounds
        // The neighbour is untouched: same id, same start, same length, same notes.
        let after = liveClip(store, neighbour.id)
        #expect(after != nil)
        #expect(after?.startBeat == 6)
        #expect(after?.lengthBeats == 4)
        #expect(after?.notes?.count == 1)
    }

    // MARK: - One undo step, still uncoalesced

    /// A grown paste is ONE undoable action — notes AND length reverse together.
    /// Two `performEdit`s would read identically in every other assertion in
    /// this file and cost the user a second ⌘Z.
    @Test("ONE undo step: depth grows by exactly 1 and it reverses BOTH halves")
    func growIsOneUndoStep() throws {
        let (store, _, clip) = try midiClip()
        let before = store.journal.undoStack.count
        let pasted = [MIDINote(pitch: 64, startBeat: 5, lengthBeats: 1)]
        _ = try store.pasteNotes(clipID: clip.id,
                                 notes: (clip.notes ?? []) + pasted,
                                 extendToCover: Set(pasted.map(\.id)))
        #expect(store.journal.undoStack.count == before + 1)
        #expect(liveClip(store, clip.id)?.lengthBeats == 8)

        try store.undo()
        let back = liveClip(store, clip.id)
        #expect(back?.lengthBeats == 4)                // length restored…
        #expect(back?.notes?.count == 1)               // …and notes, in ONE step
    }

    /// ⚠️⚠️ **THE COALESCING TRAP, RE-PINNED ON THE GROW BRANCH.** The trap
    /// `pasteNotes` exists to close is that a paste 100 ms after a note edit
    /// folds into it. m25-f-2 added a second undo LABEL to this verb, and a
    /// label is exactly the sort of edit that could pick up a journal key on the
    /// way past. The clock is pinned WELL INSIDE the 800 ms window, so this
    /// cannot pass vacuously — `ProjectStorePasteTests`'
    /// `setClipNotesStillCoalescesUnderTheSameClock` is the anti-vacuity control
    /// proving the window is in force under exactly this seam.
    @Test("a GROWING paste 100 ms after a note edit is STILL its own undo step")
    func stillUncoalescedWhenItGrows() throws {
        let (store, _, clip) = try midiClip()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.setClipNotes(clipID: clip.id,
                               notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
                                       MIDINote(pitch: 62, startBeat: 1, lengthBeats: 1)])
        let afterEdit = store.journal.undoStack.count
        clock = clock.advanced(by: .milliseconds(100))     // WELL inside the window

        let pasted = [MIDINote(pitch: 64, startBeat: 5, lengthBeats: 1)]
        let out = try store.pasteNotes(
            clipID: clip.id,
            notes: (liveClip(store, clip.id)?.notes ?? []) + pasted,
            extendToCover: Set(pasted.map(\.id)))

        #expect(out.lengthBeats == 8)                      // it really did grow…
        #expect(store.journal.undoStack.count == afterEdit + 1)   // …in its OWN entry
        #expect(store.undoHistory().undo.first == "Paste Notes & Extend Clip")

        // And one ⌘Z reverses ONLY the paste, leaving the edit standing.
        try store.undo()
        #expect(liveClip(store, clip.id)?.notes?.map(\.pitch) == [60, 62])
        #expect(liveClip(store, clip.id)?.lengthBeats == 4)
        #expect(store.undoHistory().undo.first == "Edit Notes")
    }

    // MARK: - Meter awareness

    /// The bar snap follows the METER AT THE CLIP'S START, not a hardcoded 4 —
    /// the same sampling `setClipNotes` does, so the clip's new end lands on a
    /// bar line the piano roll is already drawing.
    @Test("bar snapping follows the meter at the clip's start (3/4)")
    func growSnapsToTheClipsMeter() throws {
        let store = ProjectStore()
        try store.setTempoMap(TempoMap(constantBPM: 120),
                              meterMap: MeterMap(changes: [
                                .init(startBeat: 0, beatsPerBar: 3, beatUnit: 4),
                              ]))
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(
            toTrack: track.id, atBeat: 0, lengthBeats: 3,
            notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])

        let pasted = [MIDINote(pitch: 64, startBeat: 4, lengthBeats: 1)]   // ends 5
        let out = try store.pasteNotes(clipID: clip.id,
                                       notes: (clip.notes ?? []) + pasted,
                                       extendToCover: Set(pasted.map(\.id)))
        #expect(out.lengthBeats == 6)                  // 2 bars of 3, not 8
        #expect(isAudible(pasted[0], in: out))
    }
}
