import Foundation
import Testing
@testable import DAWCore

/// m25-a — AUTO-EXTEND. The user ruled on 2026-08-13 (*"extend in both as you
/// suggested"*) that placing a note past a clip's end GROWS the clip rather than
/// refusing the note.
///
/// Two layers are pinned here:
///  - `ClipAutoExtend`, the pure rule, callable on its own — that is what lets
///    m25-f-3's edge drag reuse this decision instead of writing a second one.
///  - `ProjectStore.setClipNotes(clipID:notes:extendToCover:)`, which applies it
///    in ONE `performEdit` alongside the note write.
///
/// ⚠️ What this does NOT do, and the tests say so explicitly: it does not make
/// out-of-range notes illegal. The m18-f/m19-g legal-but-latent rule survives —
/// the default `extendToCover: []` still writes past-the-end notes as latent
/// data, and every refusal path here leaves exactly that behaviour.
@Suite("ClipAutoExtend — the pure grow rule")
struct ClipAutoExtendRuleTests {

    // MARK: - Does it need to grow at all?

    @Test("a note wholly inside the clip is not an extension")
    func insideIsNoOp() {
        // End 3 in a 4-beat clip: nothing to do, and crucially `nil` rather than
        // "grow to 4" — an unchanged length must not journal an edit.
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 2, coveringEndBeat: 3,
            beatsPerBar: 4) == nil)
    }

    @Test("a note ending EXACTLY at the clip end is not an extension")
    func flushEndIsNoOp() {
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 3, coveringEndBeat: 4,
            beatsPerBar: 4) == nil)
    }

    @Test("a float crumb past the end does NOT buy a whole bar")
    func epsilonIsNotGrowth() {
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 3, coveringEndBeat: 4 + 1e-12,
            beatsPerBar: 4) == nil)
    }

    // MARK: - Grow to GRID, not to the note's exact end

    @Test("grows to the next BAR LINE, not to the note's ragged end")
    func growsToBarNotToNote() {
        // Note ends at 5.25 in a 4-beat 4/4 clip → 8, not 5.25.
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 5, coveringEndBeat: 5.25,
            beatsPerBar: 4) == 8)
    }

    @Test("a note ending exactly ON a bar line grows to that line, not past it")
    func exactBarLineDoesNotOvershoot() {
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 7, coveringEndBeat: 8,
            beatsPerBar: 4) == 8)
    }

    @Test("bar snapping is METER-AWARE (3 beats per bar in 3/4, 7 in 7/8)")
    func meterAware() {
        // 3/4: a note ending at 7 lands in the third bar → 9.
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 3, coveringOnsetBeat: 6, coveringEndBeat: 7,
            beatsPerBar: 3) == 9)
        // 7/8: bars are 7 beats → 14.
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 7, coveringOnsetBeat: 8, coveringEndBeat: 9,
            beatsPerBar: 7) == 14)
        // Degenerate meters clamp to 1 beat per bar rather than dividing by zero.
        #expect(ClipAutoExtend.barSnappedLength(2.5, beatsPerBar: 0) == 3)
    }

    @Test("the beatsPerBar entry counts bars from the CLIP's first beat — whole bars of length")
    func clipLocalBars() {
        // This entry has no song placement, so it counts bars from the clip's
        // first beat and the result is always a whole number of bars of LENGTH.
        // That is the roll's grid only for a clip on a song bar line; the store
        // calls the song entry instead (m23-ap AX, `ClipAutoExtendSongBarTests`).
        let grown = ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 4.5, coveringEndBeat: 5,
            beatsPerBar: 4)
        #expect(grown == 8)
    }

    // MARK: - The two ceilings

    @Test("the growth CAP refuses a wild click instead of reshaping the arrangement")
    func capRefusesRunaway() {
        // 4-beat clip, note dropped at beat 100 (reachable when zoomed far out —
        // the grid is drawn to the viewport edge). Cap is 16 bars = 64 beats, so
        // the clamped target 68 cannot reach an onset at 100 → no growth at all.
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 100, coveringEndBeat: 101,
            beatsPerBar: 4) == nil)
        #expect(ClipAutoExtend.maxGrowthBars == 16)
    }

    @Test("just inside the cap still grows; just past it does not")
    func capBoundary() {
        // Cap ceiling = 4 + 16·4 = 68.
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 66, coveringEndBeat: 67,
            beatsPerBar: 4) == 68)
        // Onset at 68 is NOT strictly inside a 68-beat clip → still latent, so
        // the rule declines rather than growing for nothing.
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 68, coveringEndBeat: 69,
            beatsPerBar: 4) == nil)
    }

    @Test("headroom clamps the grow, and beats bar alignment when they conflict")
    func headroomClamps() {
        // A neighbour 6 beats along: the clip butts against it at 6 rather than
        // taking the tidy 8 and eating into the neighbour.
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 5, coveringEndBeat: 5.5,
            beatsPerBar: 4, maxLengthBeats: 6) == 6)
    }

    @Test("no headroom at all → NO growth (the note stays latent, the neighbour is safe)")
    func noHeadroomRefuses() {
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 5, coveringEndBeat: 6,
            beatsPerBar: 4, maxLengthBeats: 4) == nil)
    }

    @Test("headroom that cannot reach the ONSET → NO growth, not a pointless partial one")
    func partialGrowthIsRefused() {
        // Room to grow to 6, but the note's onset is at 7: growing would move
        // the clip's edge AND leave the note silent — the worst of both. The
        // rule declines and the user keeps the documented latent behaviour.
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 7, coveringEndBeat: 8,
            beatsPerBar: 4, maxLengthBeats: 6) == nil)
    }

    @Test("an onset landing EXACTLY on the new end is still latent → refused")
    func onsetAtBoundaryRefused() {
        // Engine truth is a STRICT `<` on the onset
        // (`PianoRollModel.playableEndBeat`), so an onset at 6 in a 6-beat clip
        // does not sound.
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: 6, coveringEndBeat: 6.5,
            beatsPerBar: 4, maxLengthBeats: 6) == nil)
    }

    // MARK: - coverage()

    @Test("coverage reads ONLY the named ids — a latent note elsewhere is invisible to it")
    func coverageIsIdScoped() {
        let fresh = MIDINote(pitch: 60, startBeat: 5, lengthBeats: 1)
        let forgottenLatent = MIDINote(pitch: 72, startBeat: 20, lengthBeats: 1)
        let span = ClipAutoExtend.coverage(of: [fresh, forgottenLatent], ids: [fresh.id])
        #expect(span?.onsetBeat == 5)
        #expect(span?.endBeat == 6)
    }

    @Test("coverage spans MULTIPLE named notes (the shape m25-f-3's multi-note drag needs)")
    func coverageSpansMany() {
        let a = MIDINote(pitch: 60, startBeat: 5, lengthBeats: 1)
        let b = MIDINote(pitch: 64, startBeat: 9, lengthBeats: 2)
        let span = ClipAutoExtend.coverage(of: [a, b], ids: [a.id, b.id])
        #expect(span?.onsetBeat == 9)
        #expect(span?.endBeat == 11)
    }

    @Test("coverage is nil for an empty id set or ids the array does not contain")
    func coverageNilCases() {
        let a = MIDINote(pitch: 60, startBeat: 5, lengthBeats: 1)
        #expect(ClipAutoExtend.coverage(of: [a], ids: []) == nil)
        #expect(ClipAutoExtend.coverage(of: [a], ids: [UUID()]) == nil)
        #expect(ClipAutoExtend.coverage(of: [], ids: [a.id]) == nil)
    }
}

/// The store half: `setClipNotes(clipID:notes:extendToCover:)`.
@MainActor
@Suite("ProjectStore — setClipNotes auto-extend (m25-a)")
struct ClipAutoExtendStoreTests {

    /// One instrument track, one 4-beat MIDI clip at timeline beat 0 holding one
    /// note. Returns the store, the track id and the clip.
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
    /// STRICTLY inside `[0, clipLengthBeats)` (`MIDISchedule.buildEvents`, and
    /// `PianoRollModel.playableEndBeat` is its editor-side twin).
    private func isAudible(_ note: MIDINote, in clip: Clip) -> Bool {
        note.startBeat < clip.lengthBeats
    }

    // MARK: - The pinned behaviours

    @Test("a note created INSIDE the clip does not grow it")
    func insideDoesNotGrow() throws {
        let (store, _, clip) = try midiClip()
        let added = MIDINote(pitch: 62, startBeat: 2, lengthBeats: 1)
        let out = try store.setClipNotes(
            clipID: clip.id, notes: (clip.notes ?? []) + [added],
            extendToCover: [added.id])
        #expect(out.lengthBeats == 4)
        #expect(out.notes?.count == 2)
        #expect(store.undoHistory().undo.first == "Edit Notes")
    }

    @Test("a note created PAST the end grows the clip and BECOMES AUDIBLE")
    func pastEndGrowsAndSounds() throws {
        let (store, _, clip) = try midiClip()
        let added = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)
        // Before: the note is latent — this is the defect the user reported.
        #expect(!isAudible(added, in: clip))

        let out = try store.setClipNotes(
            clipID: clip.id, notes: (clip.notes ?? []) + [added],
            extendToCover: [added.id])

        #expect(out.lengthBeats == 8)              // next bar past end 6
        #expect(isAudible(added, in: out))         // ← the whole point of m25-a
        #expect(out.notes?.count == 2)
        #expect(out.startBeat == 0)                // leading edge never moves
    }

    @Test("ONE undo step: depth grows by exactly 1 and it reverses BOTH halves")
    func oneUndoStep() throws {
        let (store, _, clip) = try midiClip()
        let depthBefore = store.undoHistory().undo.count
        let added = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)

        let out = try store.setClipNotes(
            clipID: clip.id, notes: (clip.notes ?? []) + [added],
            extendToCover: [added.id])
        #expect(out.lengthBeats == 8)

        // Depth, not "undo worked": two journal entries would still undo, just
        // twice — which is exactly the failure this pins against.
        #expect(store.undoHistory().undo.count == depthBefore + 1)
        #expect(store.undoHistory().undo.first == "Edit Notes & Extend Clip")

        #expect(try store.undo() == "Edit Notes & Extend Clip")
        let reverted = liveClip(store, clip.id)
        #expect(reverted?.lengthBeats == 4)        // length restored …
        #expect(reverted?.notes?.count == 1)       // … and the note, in one step
        #expect(store.undoHistory().undo.count == depthBefore)

        // Redo puts both halves back together too.
        #expect(try store.redo() == "Edit Notes & Extend Clip")
        #expect(liveClip(store, clip.id)?.lengthBeats == 8)
        #expect(liveClip(store, clip.id)?.notes?.count == 2)
    }

    @Test("the label distinguishes a grow from a plain note edit")
    func labelIsHonest() throws {
        let (store, _, clip) = try midiClip()
        let inside = MIDINote(pitch: 62, startBeat: 1, lengthBeats: 1)
        _ = try store.setClipNotes(clipID: clip.id, notes: [inside],
                                   extendToCover: [inside.id])
        #expect(store.undoHistory().undo.first == "Edit Notes")
    }

    // MARK: - What must NOT change

    @Test("DEFAULT (no extendToCover) still writes a past-the-end note as LATENT data")
    func defaultKeepsLegalButLatent() throws {
        let (store, _, clip) = try midiClip()
        let far = MIDINote(pitch: 62, startBeat: 20, lengthBeats: 1)
        // This is the wire verb's path, paste's path, the AI's path.
        let out = try store.setClipNotes(clipID: clip.id, notes: [far])
        #expect(out.lengthBeats == 4)              // m18-f: clip untouched
        #expect(out.notes?.count == 1)             // note kept, not refused
        #expect(!isAudible(far, in: out))          // …and still latent
        #expect(store.undoHistory().undo.first == "Edit Notes")
    }

    @Test("a FORGOTTEN latent note is not resurrected by an unrelated add")
    func latentNotesDoNotDragTheEdge() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        // A clip that already holds legal-but-latent data far past its end.
        let clip = try store.addMIDIClip(
            toTrack: track.id, atBeat: 0, lengthBeats: 4,
            notes: [MIDINote(pitch: 72, startBeat: 20, lengthBeats: 1)])

        let added = MIDINote(pitch: 60, startBeat: 5, lengthBeats: 1)
        let out = try store.setClipNotes(
            clipID: clip.id, notes: (clip.notes ?? []) + [added],
            extendToCover: [added.id])

        // Grew for the NEW note only — not out to beat 21.
        #expect(out.lengthBeats == 8)
        #expect(out.notes?.count == 2)
        // The old latent note is still there, still latent.
        let old = out.notes?.first { $0.startBeat == 20 }
        #expect(old != nil)
        #expect(!isAudible(old!, in: out))
    }

    @Test("a capped-out grow does NOT drop the notes beyond the cap")
    func cappedGrowKeepsFarNotes() throws {
        // The `applyTrimWindow` hazard, pinned: that helper re-windows the note
        // list and drops every note starting past the new length. A grow must
        // never delete the latent data m18-f promises to keep, which is why this
        // verb writes the length directly instead.
        let (store, _, clip) = try midiClip()
        let far = MIDINote(pitch: 62, startBeat: 100, lengthBeats: 1)
        let out = try store.setClipNotes(
            clipID: clip.id, notes: (clip.notes ?? []) + [far],
            extendToCover: [far.id])
        #expect(out.lengthBeats == 4)              // cap refused the grow
        #expect(out.notes?.count == 2)             // and the note SURVIVED
        #expect(out.notes?.contains { $0.id == far.id } == true)
    }

    // MARK: - The neighbour must survive

    @Test("the grow NEVER trims a same-track neighbour")
    func neighbourIsUntouched() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let first = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4,
                                          notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let neighbour = try store.addMIDIClip(toTrack: track.id, atBeat: 6, lengthBeats: 4,
                                              notes: [MIDINote(pitch: 67, startBeat: 0, lengthBeats: 2)])

        let added = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 0.5)
        let out = try store.setClipNotes(
            clipID: first.id, notes: (first.notes ?? []) + [added],
            extendToCover: [added.id])

        // Butts against the neighbour at 6 instead of taking the tidy 8.
        #expect(out.lengthBeats == 6)
        #expect(isAudible(added, in: out))
        // The neighbour is byte-identical — geometry AND content.
        let after = liveClip(store, neighbour.id)
        #expect(after?.startBeat == 6)
        #expect(after?.lengthBeats == 4)
        #expect(after?.notes?.count == 1)
        #expect(after == neighbour)
    }

    @Test("an adjacent neighbour leaves no room → no grow, no edit to the neighbour")
    func adjacentNeighbourBlocksGrowth() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let first = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4,
                                          notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let neighbour = try store.addMIDIClip(toTrack: track.id, atBeat: 4, lengthBeats: 4,
                                              notes: [MIDINote(pitch: 67, startBeat: 0, lengthBeats: 2)])

        let added = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)
        let out = try store.setClipNotes(
            clipID: first.id, notes: (first.notes ?? []) + [added],
            extendToCover: [added.id])

        #expect(out.lengthBeats == 4)              // refused
        #expect(!isAudible(added, in: out))        // stays latent — honest
        #expect(out.notes?.count == 2)             // but never discarded
        #expect(liveClip(store, neighbour.id) == neighbour)
        #expect(store.undoHistory().undo.first == "Edit Notes")
    }

    @Test("headroom ignores clips on OTHER tracks")
    func otherTracksAreNotBlockers() throws {
        let store = ProjectStore()
        let a = store.addTrack(kind: .instrument)
        let b = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: a.id, atBeat: 0, lengthBeats: 4,
                                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        _ = try store.addMIDIClip(toTrack: b.id, atBeat: 5, lengthBeats: 4)

        let added = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)
        let out = try store.setClipNotes(
            clipID: clip.id, notes: (clip.notes ?? []) + [added],
            extendToCover: [added.id])
        #expect(out.lengthBeats == 8)
    }

    @Test("headroom measures to the NEAREST following clip, not the first found")
    func headroomTakesTheNearest() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4,
                                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        // Added far-first so the nearest is NOT the first in the array.
        _ = try store.addMIDIClip(toTrack: track.id, atBeat: 20, lengthBeats: 2)
        _ = try store.addMIDIClip(toTrack: track.id, atBeat: 7, lengthBeats: 2)

        let added = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)
        let out = try store.setClipNotes(
            clipID: clip.id, notes: (clip.notes ?? []) + [added],
            extendToCover: [added.id])
        #expect(out.lengthBeats == 7)              // clamped to the clip at 7
    }

    // MARK: - Meter

    @Test("the grow uses the meter AT THE CLIP'S START (3/4 grows in 3s)")
    func growUsesTheClipsMeter() throws {
        let store = ProjectStore()
        try store.setTempoMap(store.transport.tempoMap,
                              meterMap: MeterMap(constant: TimeSignature(beatsPerBar: 3, beatUnit: 4)))
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 3,
                                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let added = MIDINote(pitch: 62, startBeat: 4, lengthBeats: 1)
        let out = try store.setClipNotes(
            clipID: clip.id, notes: (clip.notes ?? []) + [added],
            extendToCover: [added.id])
        #expect(out.lengthBeats == 6)              // 3/4 bars, not 8
        #expect(isAudible(added, in: out))
    }

    // MARK: - m23-ap AX — the grown end is the SONG's bar line

    /// ⭐ THE DEFECT, AT THE STORE: a clip at song beat 2 in 4/4 sees bar lines
    /// drawn at song 4, 8, 12 (clip-local 2, 6, 10). The clip-bar rule grew it
    /// to local 8, song 10: between two of them.
    @Test("m23-ap AX — an OFF-bar clip grows to the SONG's next bar line, where the roll draws one")
    func offBarClipGrowsToTheSongsBarLine() throws {
        let (store, _, clip) = try midiClip(atBeat: 2)
        let added = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 0.5)   // song 7…7.5
        let out = try store.setClipNotes(
            clipID: clip.id, notes: (clip.notes ?? []) + [added],
            extendToCover: [added.id])
        #expect(out.lengthBeats == 6)                   // song 8, not local 8 (song 10)
        #expect(out.startBeat == 2)                     // the leading edge never moves
        #expect(isAudible(added, in: out))
        #expect(store.lastAutoExtendOutcome == .grew(6))
        #expect(store.transport.meterMap.barBeat(atBeat: out.startBeat + out.lengthBeats).beatInBar == 0)

        // Past song 8 the next line is song 12: local 10.
        let further = MIDINote(pitch: 64, startBeat: 6.5, lengthBeats: 0.5)   // song 8.5…9
        let out2 = try store.setClipNotes(
            clipID: clip.id, notes: (out.notes ?? []) + [further],
            extendToCover: [further.id])
        #expect(out2.lengthBeats == 10)
        #expect(store.undoHistory().undo.first == "Edit Notes & Extend Clip")
    }

    /// The hands-on-confirmed case must not move: a clip ON a bar line grows
    /// exactly as the clip at beat 0 always has.
    @Test("m23-ap AX — an ON-bar clip grows exactly as before, bit for bit, wherever the bar is")
    func onBarClipGrowsAsBefore() throws {
        for start in [0.0, 4, 12, 4096] {
            let (store, _, clip) = try midiClip(atBeat: start)
            let added = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)
            let out = try store.setClipNotes(
                clipID: clip.id, notes: (clip.notes ?? []) + [added],
                extendToCover: [added.id])
            #expect(out.lengthBeats.bitPattern == (8.0).bitPattern, "clip at \(start): \(out.lengthBeats)")
        }
    }

    /// ⭐ THE HEADROOM, MEASURED AGAINST THE REAL END. Clip at song 1, 3 beats
    /// long; the next clip starts at song 6. A note to song 4.5: the clip-bar
    /// end (local 4, song 5) would clear that neighbour, but the song-bar end
    /// (local 7, song 8) runs past it. Measured against the end the clip really
    /// gets, the grow stops at the neighbour. Measured against the old end, it
    /// would overlap it, and the overlap resolver would TRIM the neighbour.
    @Test("m23-ap AX — a neighbour between the clip-bar end and the song-bar end stops the grow and is untouched")
    func neighbourBetweenTheTwoEndsIsUntouched() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let first = try store.addMIDIClip(toTrack: track.id, atBeat: 1, lengthBeats: 3,
                                          notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let neighbour = try store.addMIDIClip(toTrack: track.id, atBeat: 6, lengthBeats: 4,
                                              notes: [MIDINote(pitch: 67, startBeat: 0, lengthBeats: 2)])
        let added = MIDINote(pitch: 62, startBeat: 3.2, lengthBeats: 0.3)
        let out = try store.setClipNotes(
            clipID: first.id, notes: (first.notes ?? []) + [added],
            extendToCover: [added.id])
        #expect(out.lengthBeats == 5)                   // butts the neighbour at song 6
        #expect(isAudible(added, in: out))
        #expect(store.lastAutoExtendOutcome == .grew(5))
        #expect(liveClip(store, neighbour.id) == neighbour)
    }

    // MARK: - Guards that were already there

    @Test("extendToCover naming an id the submission lacks changes nothing")
    func unknownIdIsInert() throws {
        let (store, _, clip) = try midiClip()
        let far = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)
        let out = try store.setClipNotes(
            clipID: clip.id, notes: (clip.notes ?? []) + [far],
            extendToCover: [UUID()])
        #expect(out.lengthBeats == 4)
    }

    @Test("auto-extend cannot bypass the audio-clip guard")
    func audioClipStillRefused() throws {
        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(
            durationSeconds: 2, sampleRate: 44_100, channelCount: 2))
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"),
                                         toTrack: track.id)
        let note = MIDINote(pitch: 60, startBeat: 99, lengthBeats: 1)
        #expect(throws: ProjectError.self) {
            _ = try store.setClipNotes(clipID: clip.id, notes: [note],
                                       extendToCover: [note.id])
        }
        #expect(liveClip(store, clip.id)?.lengthBeats == 4)
    }
}

// MARK: - m23-ap AX — the grown end is a SONG bar line

/// m23-ap AX — **a grown clip ends on the SONG's next bar line**, the line the
/// piano roll draws (`PianoRollSongGrid`, since I5-F2), not on a bar counted
/// from the clip's first beat.
///
/// Five jobs:
///  1. ⭐ **INVARIANCE.** Every clip that starts ON a song bar line gets exactly
///     the outcome it got before, bit for bit. The reference is a FROZEN copy
///     of the pre-AX rule (`PreAX`), not the live clip-local entry, which now
///     shares the new body and so could not tell.
///  2. **PHYSICS.** An off-bar clip's grown end is the first bar line at or
///     after the covering end, derived from `MeterMap` alone.
///  3. **CEILINGS.** The growth cap and the neighbour are measured against the
///     NEW end: rows where the two rules put the end on opposite sides of a
///     ceiling.
///  4. **REFUSALS.** Their classification cannot differ between the two rules
///     for a note the store can hold (onset before end), measured, not argued.
///  5. **SCOPE.** A song whose meter changes keeps the clip-bar rule, pinned so
///     changing that is a decision.
///
/// The roll-side proof (the end IS a line the roll draws, asked of the roll's
/// own grid code) is `DAWAppKitTests/ClipAutoExtendSongGridTests.swift`.
///
/// Nonisolated value math: a plain suite, no `@MainActor` slot.
@Suite("ClipAutoExtend — a grown clip ends on a SONG bar line (m23-ap AX)")
struct ClipAutoExtendSongBarTests {

    /// `ClipAutoExtend.outcome` and `barSnappedLength` as they stood before
    /// m23-ap AX (`git show 813c415:Sources/DAWCore/ClipAutoExtend.swift`,
    /// lines 240-312), body for body, so the invariance table compares CODE
    /// against CODE. That rule took no song placement: bars from the clip's
    /// first beat.
    private enum PreAX {
        static let epsilon: Double = 1e-9
        static let maxGrowthBars: Int = 16

        static func outcome(currentLengthBeats: Double, coveringOnsetBeat: Double,
                            coveringEndBeat: Double, beatsPerBar: Int,
                            maxLengthBeats: Double?) -> ClipAutoExtend.ExtendOutcome {
            guard coveringEndBeat > currentLengthBeats + epsilon else { return .notNeeded }
            let barTarget = barSnappedLength(coveringEndBeat, beatsPerBar: beatsPerBar)
            let bpb = Double(Swift.max(1, beatsPerBar))
            let growthCeiling = currentLengthBeats + Double(maxGrowthBars) * bpb
            var target = Swift.min(barTarget, growthCeiling)
            if let maxLengthBeats { target = Swift.min(target, maxLengthBeats) }
            func blame() -> ClipAutoExtend.ExtendOutcome {
                guard target < barTarget else { return .refusedOnsetStillLatent }
                if let maxLengthBeats, maxLengthBeats <= growthCeiling { return .refusedByNeighbour }
                return .refusedByGrowthCap
            }
            guard target > currentLengthBeats + epsilon else { return blame() }
            guard coveringOnsetBeat < target else { return blame() }
            return .grew(target)
        }

        static func barSnappedLength(_ endBeat: Double, beatsPerBar: Int) -> Double {
            let bpb = Double(Swift.max(1, beatsPerBar))
            guard endBeat > 0 else { return bpb }
            let bars = (endBeat / bpb).rounded(.up)
            let snapped = bars * bpb
            return snapped < endBeat - epsilon ? snapped + bpb : snapped
        }
    }

    private static func oneMeter(_ beatsPerBar: Int) -> MeterMap {
        MeterMap(constant: TimeSignature(beatsPerBar: beatsPerBar, beatUnit: 4))
    }

    /// 4/4, then 3/4 from beat 8: bar lines at 0, 4, 8, 11, 14, 17 …
    private static func fourThenThree() throws -> MeterMap {
        try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                               .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4)])
    }

    /// `.grew` compared by BIT PATTERN (`==` on a Double calls 0 and −0 equal),
    /// every other outcome by case.
    private static func bitIdentical(_ a: ClipAutoExtend.ExtendOutcome,
                                     _ b: ClipAutoExtend.ExtendOutcome) -> Bool {
        if case .grew(let x) = a, case .grew(let y) = b { return x.bitPattern == y.bitPattern }
        return a == b
    }

    private static func isRefusal(_ o: ClipAutoExtend.ExtendOutcome) -> Bool {
        switch o {
        case .notNeeded, .grew: return false
        case .refusedByGrowthCap, .refusedByNeighbour, .refusedOnsetStillLatent: return true
        }
    }

    /// The song's store entry, spelled once.
    private static func songOutcome(current: Double, onset: Double, end: Double, start: Double,
                                    map: MeterMap, maxLength: Double?) -> ClipAutoExtend.ExtendOutcome {
        ClipAutoExtend.outcome(currentLengthBeats: current, coveringOnsetBeat: onset,
                               coveringEndBeat: end, clipStartBeat: start, meterMap: map,
                               maxLengthBeats: maxLength)
    }

    /// The first SONG bar line at or after `songBeat`, from the meter map
    /// alone: the physics oracle, independent of `SongGridPhase` and of the rule
    /// under test.
    private static func firstBarLine(atOrAfter songBeat: Double, in map: MeterMap) -> Double {
        let bar = map.barBeat(atBeat: songBeat).bar
        let lower = map.beat(ofBar: bar)
        return songBeat - lower <= 1e-9 ? lower : map.beat(ofBar: bar + 1)
    }

    // MARK: 1. Invariance

    /// ⭐⭐ **THE HEADLINE.** The user confirmed edge auto-extend by hand
    /// (m25-f-3); a clip on a bar line must not move by one bit.
    ///
    /// ⚠️ **Why the late starts and the crumbs.** Small dyadic values cannot
    /// tell the right arithmetic from `nextBar(start + end) − start`: that
    /// formula is exact until `start + end` drops the end's low bits, which
    /// takes a start in the thousands or more AND an end within a crumb of a bar
    /// line. Without those rows a bit table stays green over exactly the
    /// regression it exists to catch.
    @Test("⭐ m23-ap AX INVARIANCE — a clip that starts ON a song bar line gets the pre-AX outcome BIT FOR BIT: 8 one-meter songs × 7 bar-line starts up to bar 2^20, and 16 on-bar starts in 3 songs whose meter changes")
    func onBarClipIsBitIdentical() throws {
        var songs: [(map: MeterMap, starts: [Double], label: String)] = []
        for bpb in [1, 2, 3, 4, 5, 6, 7, 12] {
            let starts = [0, 1, 2, 5, 256, 1024, 1 << 20].map { Double($0 * bpb) }
            songs.append((Self.oneMeter(bpb), starts, "\(bpb)/4"))
        }
        songs.append((try Self.fourThenThree(), [0, 4, 8, 11, 14, 29], "4/4→3/4@8"))
        songs.append((try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 3, beatUnit: 4),
                                             .init(startBeat: 6, beatsPerBar: 4, beatUnit: 4)]),
                      [0, 3, 6, 10, 14], "3/4→4/4@6"))
        songs.append((try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 7, beatUnit: 8),
                                             .init(startBeat: 14, beatsPerBar: 5, beatUnit: 8)]),
                      [0, 7, 14, 19, 24], "7/8→5/8@14"))

        var compared = 0
        var failed = 0
        var failures: [String] = []
        // notNeeded, grew, cap, neighbour, latent: every outcome must be reached,
        // or the table is not testing what it says.
        var reached = [0, 0, 0, 0, 0]
        var starts = 0
        for song in songs {
            for start in song.starts {
                starts += 1
                // Positive control: the start IS on a bar line of this song.
                #expect(song.map.barBeat(atBeat: start).beatInBar == 0,
                        "\(song.label): \(start) is not on a bar line, so the table is mislabelled")
                let bpb = song.map.beatsPerBar(atBeat: start)
                for current in [0.25, 1, 4, 7.5, 16] {
                    for bars in [1, 2, 3, 5, 9, 17, 25] {
                        for crumb in [-0.5, -1e-7, -4e-13, 0, 4e-13, 1e-12, 1e-10, 1e-7, 0.1, 1.0 / 3.0] {
                            let end = Double(bars * bpb) + crumb
                            for gap in [-0.5, 0, 0.001, 0.5] {
                                for maxLength in [nil, 0, current, current + 1.5, current + 64, 1000] as [Double?] {
                                    compared += 1
                                    let old = PreAX.outcome(
                                        currentLengthBeats: current, coveringOnsetBeat: end - gap,
                                        coveringEndBeat: end, beatsPerBar: bpb, maxLengthBeats: maxLength)
                                    let new = Self.songOutcome(current: current, onset: end - gap, end: end,
                                                               start: start, map: song.map, maxLength: maxLength)
                                    switch old {
                                    case .notNeeded: reached[0] += 1
                                    case .grew: reached[1] += 1
                                    case .refusedByGrowthCap: reached[2] += 1
                                    case .refusedByNeighbour: reached[3] += 1
                                    case .refusedOnsetStillLatent: reached[4] += 1
                                    }
                                    if !Self.bitIdentical(old, new) {
                                        failed += 1
                                        if failures.count < 6 {
                                            failures.append("\(song.label) start \(start) current \(current) end \(end) onset \(end - gap) max \(String(describing: maxLength)): \(old) → \(new)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(starts == 72)
        #expect(compared == 72 * 5 * 7 * 10 * 4 * 6, "the table did not run in full: \(compared)")
        #expect(reached.allSatisfy { $0 > 0 }, "an outcome was never reached, so the table cannot vouch for it: \(reached)")
        #expect(failed == 0, "\(failed) of \(compared) on-bar outcomes moved, e.g. \(failures)")
    }

    /// The clip-local entry (`beatsPerBar`, no placement) IS the song entry for
    /// a clip at song beat 0 in one meter. Both run one body, so this pins the
    /// forwarding, not the arithmetic.
    @Test("m23-ap AX — the beatsPerBar entry equals the song entry for a clip at song beat 0, bit for bit")
    func clipLocalEntryIsTheClipAtBeatZero() {
        var compared = 0
        var differ = 0
        for bpb in [1, 3, 4, 7] {
            for current in [1.0, 4, 7.5] {
                for end in stride(from: current - 1, through: current + 90, by: 0.75) {
                    for maxLength in [nil, current + 2, 1000] as [Double?] {
                        compared += 1
                        let clipLocal = ClipAutoExtend.outcome(
                            currentLengthBeats: current, coveringOnsetBeat: end - 0.5,
                            coveringEndBeat: end, beatsPerBar: bpb, maxLengthBeats: maxLength)
                        let song = Self.songOutcome(current: current, onset: end - 0.5, end: end, start: 0,
                                                    map: Self.oneMeter(bpb), maxLength: maxLength)
                        if !Self.bitIdentical(clipLocal, song) { differ += 1 }
                    }
                }
            }
        }
        #expect(compared == 4_392, "the sweep's size moved: \(compared)")
        #expect(differ == 0)
    }

    // MARK: 2. Physics

    /// Every off-bar clip in the table grows to the first song bar line at or
    /// after the covering end, and every one of them MOVED away from the
    /// clip-bar answer (which for an off-bar clip can never be a song line).
    @Test("m23-ap AX PHYSICS — an OFF-bar clip grows to the first SONG bar line at or after the note's end, from MeterMap alone")
    func offBarClipGrowsToTheSongsNextBarLine() {
        var checked = 0
        var wrong: [String] = []
        var unmoved: [String] = []
        for bpb in [2, 3, 4, 5, 7] {
            let map = Self.oneMeter(bpb)
            let b = Double(bpb)
            for start in [0.5, 1, 2.1, 2.5, 3.75, 6.75, 1.0 / 3.0, 9.5, 101.25, 1000.2] {
                let inBar = map.barBeat(atBeat: start).beatInBar
                guard inBar > 1e-9, b - inBar > 1e-9 else { continue }   // off-bar starts only
                for current in [1, 2.5, 4] {
                    for extra in [0.25, 0.5, 1, 1.5, 2.75, 3, 4.5, 7.25, 10.0 / 3.0] {
                        let end = current + extra
                        checked += 1
                        let got = Self.songOutcome(current: current, onset: end - 0.25, end: end,
                                                   start: start, map: map, maxLength: nil)
                        let expected = Self.firstBarLine(atOrAfter: start + end, in: map) - start
                        guard case .grew(let length) = got else {
                            wrong.append("\(bpb)/4 start \(start) current \(current) end \(end): \(got)")
                            continue
                        }
                        // On a bar line from either side: `start + length` is one
                        // rounding away from the whole song beat it names.
                        let inBar = map.barBeat(atBeat: start + length).beatInBar
                        let onLine = inBar < 1e-6 || b - inBar < 1e-6
                        guard abs(length - expected) <= 1e-9, onLine,
                              length >= end - 1e-9, length < end + b else {
                            wrong.append("\(bpb)/4 start \(start) current \(current) end \(end): \(got), expected ≈\(expected)")
                            continue
                        }
                        let clipBar = PreAX.outcome(currentLengthBeats: current, coveringOnsetBeat: end - 0.25,
                                                    coveringEndBeat: end, beatsPerBar: bpb, maxLengthBeats: nil)
                        if Self.bitIdentical(got, clipBar) { unmoved.append("\(bpb)/4 start \(start) end \(end)") }
                    }
                }
            }
        }
        // Derived outside Swift (fmod of each start by each bar length): all 10
        // starts are off a bar line in all 5 meters, so 5 × 10 × 3 × 9 = 1350.
        #expect(checked == 1350, "the table's size moved: \(checked)")
        #expect(wrong.isEmpty, "\(wrong.count) grown ends are not the song's next bar line, e.g. \(wrong.prefix(4))")
        #expect(unmoved.isEmpty, "\(unmoved.count) off-bar rows kept the clip-bar end, e.g. \(unmoved.prefix(4))")
    }

    // MARK: 3. Ceilings, measured against the NEW end

    /// ⭐ **THE ROWS WHERE THE TWO RULES PUT THE END ON OPPOSITE SIDES OF A
    /// CEILING.** A song-bar end can be up to a bar longer or shorter than the
    /// clip-bar end. When a neighbour (or the growth cap) sits between them,
    /// only the end the clip would REALLY get may be compared with it: judged
    /// against the old end, the first row grows to 7 straight over a neighbour
    /// at 5, and the store's overlap resolver would trim that neighbour.
    @Test("⭐ m23-ap AX — the neighbour and the growth cap are measured against the NEW end, in both directions")
    func ceilingsAreMeasuredAgainstTheNewEnd() {
        struct Row { var label: String; var start: Double; var current: Double; var onset: Double
                     var end: Double; var maxLength: Double?; var expected: ClipAutoExtend.ExtendOutcome
                     var clipBar: ClipAutoExtend.ExtendOutcome }
        let rows: [Row] = [
            // Song 1..4, note to song 4.5. Clip-bar end 4 (song 5) clears a
            // neighbour at song 6; the song-bar end 7 (song 8) does not.
            Row(label: "neighbour between, new end LONGER", start: 1, current: 3, onset: 3.2, end: 3.5,
                maxLength: 5, expected: .grew(5), clipBar: .grew(4)),
            // Song 3..7, note to song 7.75. Clip-bar end 8 (song 11) is past a
            // neighbour at song 9; the song-bar end 5 (song 8) is clear of it.
            Row(label: "neighbour between, new end SHORTER", start: 3, current: 4, onset: 4.5, end: 4.75,
                maxLength: 6, expected: .grew(5), clipBar: .grew(6)),
            // Cap 5 + 64 = 69. Clip-bar end 68 fits under it; song-bar end 71 does not.
            Row(label: "cap between, new end LONGER", start: 1, current: 5, onset: 67.2, end: 67.5,
                maxLength: nil, expected: .grew(69), clipBar: .grew(68)),
            // Cap 5.5 + 64 = 69.5. Clip-bar end 72 is past it; song-bar end 69 is not.
            Row(label: "cap between, new end SHORTER", start: 3, current: 5.5, onset: 68.2, end: 68.5,
                maxLength: nil, expected: .grew(69), clipBar: .grew(69.5)),
        ]
        for row in rows {
            let got = Self.songOutcome(current: row.current, onset: row.onset, end: row.end,
                                       start: row.start, map: Self.oneMeter(4), maxLength: row.maxLength)
            #expect(Self.bitIdentical(got, row.expected), "\(row.label): expected \(row.expected), got \(got)")
            // Discrimination: the clip-bar rule really answers differently here,
            // so these rows can tell which end the ceiling was compared with.
            let clipBar = PreAX.outcome(currentLengthBeats: row.current, coveringOnsetBeat: row.onset,
                                        coveringEndBeat: row.end, beatsPerBar: 4, maxLengthBeats: row.maxLength)
            #expect(Self.bitIdentical(clipBar, row.clipBar), "\(row.label): the clip-bar control moved: \(clipBar)")
            #expect(!Self.bitIdentical(got, clipBar), "\(row.label) does not discriminate the two ends")
        }
    }

    /// The refusals on an off-bar clip, one row each, with the reason each one
    /// names. The last row is the one that differs from the clip-bar rule, and
    /// it is pure-function-only: an onset AT the end is a zero-length note,
    /// which the store never holds.
    @Test("m23-ap AX — each refusal on an OFF-bar clip, named against the SONG-bar end")
    func offBarRefusals() {
        let map = Self.oneMeter(4)
        // Clip at song 2, 4 beats long (song 2..6). Song bar lines: local 2, 6, 10 …
        #expect(Self.songOutcome(current: 4, onset: 5, end: 6, start: 2, map: map, maxLength: 4)
                == .refusedByNeighbour, "a flush neighbour")
        #expect(Self.songOutcome(current: 4, onset: 6.5, end: 7, start: 2, map: map, maxLength: 6)
                == .refusedByNeighbour, "a neighbour below the onset")
        #expect(Self.songOutcome(current: 4, onset: 100, end: 101, start: 2, map: map, maxLength: nil)
                == .refusedByGrowthCap, "a note past the 16-bar cap")
        // The song-bar end for a note ending at local 6 is 6 itself (song 8);
        // an onset exactly there would stay silent. The clip-bar rule grew to 8.
        #expect(Self.songOutcome(current: 4, onset: 6, end: 6, start: 2, map: map, maxLength: nil)
                == .refusedOnsetStillLatent)
        #expect(PreAX.outcome(currentLengthBeats: 4, coveringOnsetBeat: 6, coveringEndBeat: 6,
                              beatsPerBar: 4, maxLengthBeats: nil) == .grew(8))
    }

    // MARK: 4. Refusals — measured, not argued

    /// ⚠️ **For a note the store can hold (onset strictly before end), a refusal
    /// is the SAME refusal under both rules; only the grown length moves.** Why:
    /// any ceiling low enough to refuse sits at or below the onset, so below
    /// BOTH bar targets, which are at or past the end. The target is then that
    /// ceiling under either rule, and so is the blame. So no test can catch a
    /// ceiling judged against the old end by its refusal NAME; the rows above
    /// catch it by the LENGTH. This sweep measures the claim.
    @Test("m23-ap AX — for onset < end, every refusal is the same refusal under both rules; only grown lengths differ")
    func refusalClassificationDoesNotMove() {
        var compared = 0
        var refusals = 0
        var lengthsMoved = 0
        var mismatched: [String] = []
        for bpb in [3, 4, 7] {
            let map = Self.oneMeter(bpb)
            for start in [0.5, 1, 2.1, 2.5, 3.75] {
                for current in [1.0, 4, 7.5] {
                    for end in stride(from: current + 0.25, through: current + 130, by: 0.75) {
                        for gap in [0.001, 0.5, 3] {
                            for maxLength in [nil, 0, current, current + 0.5, current + 2, current + 5,
                                              current + 20] as [Double?] {
                                compared += 1
                                let onset = end - gap
                                let song = Self.songOutcome(current: current, onset: onset, end: end,
                                                            start: start, map: map, maxLength: maxLength)
                                let clipBar = PreAX.outcome(currentLengthBeats: current, coveringOnsetBeat: onset,
                                                            coveringEndBeat: end, beatsPerBar: bpb,
                                                            maxLengthBeats: maxLength)
                                if Self.isRefusal(song) || Self.isRefusal(clipBar) {
                                    refusals += 1
                                    if song != clipBar, mismatched.count < 8 {
                                        mismatched.append("\(bpb)/4 start \(start) current \(current) end \(end) onset \(onset) max \(String(describing: maxLength)): \(clipBar) → \(song)")
                                    }
                                } else if !Self.bitIdentical(song, clipBar) {
                                    lengthsMoved += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        // 3 meters × 5 starts × 3 lengths × 522 ends × 3 gaps × 7 ceilings,
        // derived outside Swift.
        #expect(compared == 164_430, "the sweep's size moved: \(compared)")
        print("[measured] m23-ap AX refusal sweep: \(compared) fixtures, \(refusals) refusals, \(lengthsMoved) lengths moved")
        #expect(refusals > 10_000, "too few refusals reached for the claim to mean anything: \(refusals)")
        #expect(lengthsMoved > 10_000, "the song rule never moved a length here, so this sweep compares nothing: \(lengthsMoved)")
        #expect(mismatched.isEmpty, "a refusal changed its name between the rules: \(mismatched)")
    }

    // MARK: 5. Scope

    /// ⚠️ **SCOPE, PINNED ON PURPOSE.** In a song whose meter changes, the grow
    /// still counts bars from the clip's first beat (`songBarPhase`). The cost
    /// is written down here: an off-bar clip there can still grow to an end
    /// between the lines the roll draws. The reason: after 4/4 → 3/4 at beat 8,
    /// a clip at beat 8 sits ON bar 3, yet `SongGridPhase` (uniform from song
    /// beat 0) reads it as 2 beats off, so using it here would move an on-bar
    /// clip. Changing this is a decision: this test flips when it is made.
    @Test("⚠️ m23-ap AX SCOPE — a song whose meter changes keeps the clip-bar rule, even where that misses the drawn lines")
    func meterChangeKeepsTheClipBarRule() throws {
        let map = try Self.fourThenThree()
        // Why the rule is not applied: an on-bar clip reads as off the uniform grid.
        #expect(map.barBeat(atBeat: 8).beatInBar == 0)
        #expect(SongGridPhase.phase(of: 8, step: 3) == 2)
        #expect(ClipAutoExtend.songBarPhase(clipStartBeat: 8, meterMap: map) == 0)
        // What it costs: a clip at song 9.5 (1.5 into bar 3), 3 beats long,
        // note to song 13. Clip bars of 3 give local 6 = song 15.5, between the
        // drawn lines at 14 and 17.
        let got = Self.songOutcome(current: 3, onset: 3.2, end: 3.5, start: 9.5, map: map, maxLength: nil)
        let clipBar = PreAX.outcome(currentLengthBeats: 3, coveringOnsetBeat: 3.2, coveringEndBeat: 3.5,
                                    beatsPerBar: 3, maxLengthBeats: nil)
        #expect(Self.bitIdentical(got, clipBar))
        #expect(got == .grew(6))
        #expect(map.barBeat(atBeat: 9.5 + 6).beatInBar != 0, "the known gap closed: update this pin and the doc on `songBarPhase`")
        // And in one meter the same start IS phased: the gate is the meter change.
        #expect(ClipAutoExtend.songBarPhase(clipStartBeat: 9.5, meterMap: Self.oneMeter(3)) == 0.5)
    }
}
