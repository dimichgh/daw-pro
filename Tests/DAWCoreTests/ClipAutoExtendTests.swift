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

    @Test("bar snapping is CLIP-LOCAL — a clip that starts off the bar still gets whole bars")
    func clipLocalBars() {
        // The roll draws its bar emphasis from clip-local 0
        // (`PianoRollGrid.drawGridLines`: `b % beatsPerBar == 0`), so the rule
        // never sees the clip's timeline start and the result is always a whole
        // number of bars of LENGTH.
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
