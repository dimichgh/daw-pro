import Testing
import Foundation
import DAWCore
@testable import DAWAppKit

/// m23-ek-3 — WHERE A PASTE LANDS. Every rule in the paste-anchor decision,
/// pinned headlessly: the playhead anchor, rigid group translation, the group
/// clamp at beat 0, in-place vs relocated track resolution and its mandatory
/// index clamp, skip-and-report, and the note path's snap-once contract.
@Suite("Paste anchor policy (m23-ek-3)")
struct PasteAnchorPolicyTests {

    // MARK: - Fixtures

    private func midiTrack(_ name: String) -> Track {
        Track(name: name, kind: .instrument)
    }

    private func audioTrack(_ name: String) -> Track {
        Track(name: name, kind: .audio)
    }

    private func midiClip(_ name: String, start: Double, length: Double = 4) -> Clip {
        Clip(name: name, startBeat: start, lengthBeats: length, notes: [])
    }

    private func audioClip(_ name: String, start: Double, length: Double = 4) -> Clip {
        Clip(name: name, startBeat: start, lengthBeats: length,
             audioFileURL: URL(fileURLWithPath: "/tmp/\(name).wav"))
    }

    private func entry(_ clip: Clip, track: Track, index: Int) -> ClipboardClip {
        ClipboardClip(clip: clip, sourceTrackID: track.id, sourceTrackIndex: index)
    }

    /// An INFERRED destination — "the focused clip happens to live here", which
    /// is what every fixture in this suite meant before m25-l-3 gave the value a
    /// provenance. Every relocation case below has a DEAD SOURCE TRACK, so it
    /// reaches `.relocated` on its own and the origin cannot change its verdict;
    /// spelling them `.inferred` therefore keeps them measuring exactly what they
    /// measured, AND makes them the regression guard for the half of the m25-l-3
    /// rule that must not move — an inferred destination still bases a relocated
    /// paste, exactly as it always did.
    private func inferred(_ track: Track) -> ArrangeActiveTrack.Resolution {
        ArrangeActiveTrack.Resolution(id: track.id, origin: .inferred)
    }

    /// An EXPLICIT destination — "the user clicked this track's header". The only
    /// origin that overrides the in-place rule (m25-l-3).
    private func explicit(_ track: Track) -> ArrangeActiveTrack.Resolution {
        ArrangeActiveTrack.Resolution(id: track.id, origin: .explicit)
    }

    // MARK: - The anchor and rigid translation

    @Test("the EARLIEST member lands on the playhead and the rest keep their offsets")
    func earliestMemberAnchorsTheGroup() {
        let track = midiTrack("Keys")
        let a = midiClip("a", start: 8)
        let b = midiClip("b", start: 12)
        let c = midiClip("c", start: 20)
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(c, track: track, index: 0),
                      entry(a, track: track, index: 0),
                      entry(b, track: track, index: 0)],
            anchorBeat: 100, tracks: [track], activeTrack: nil)

        #expect(plan.refusedBy == nil)
        #expect(plan.mode == .inPlace)
        let starts = plan.landings.map(\.startBeat)
        // a is earliest (8), so it lands ON the anchor; b is +4 from it, c is +12.
        #expect(starts == [100, 104, 112])
        // And the payload's ORDER did not matter — the reference is the minimum
        // start, not whatever came first in the array.
        #expect(plan.landings.map(\.clip.name) == ["a", "b", "c"])
    }

    @Test("the anchor is the min START, not the first member of the track-sorted order")
    func anchorIsTheMinStartAcrossTracks() {
        // The trap this pins: `ordered` sorts by TRACK first, so a two-track copy
        // whose UPPER clip starts LATER would anchor on the wrong member if the
        // reference were `ordered.first` — shifting the whole group left by the
        // difference.
        let upper = midiTrack("Upper")
        let lower = midiTrack("Lower")
        let late = midiClip("upper-late", start: 16)
        let early = midiClip("lower-early", start: 4)
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(late, track: upper, index: 0), entry(early, track: lower, index: 1)],
            anchorBeat: 50, tracks: [upper, lower], activeTrack: nil)

        let byName = Dictionary(uniqueKeysWithValues: plan.landings.map { ($0.clip.name, $0) })
        #expect(byName["lower-early"]?.startBeat == 50)
        #expect(byName["upper-late"]?.startBeat == 62)  // 50 + (16 − 4)
    }

    @Test("pasting the same payload twice at one anchor yields IDENTICAL landings")
    func theAnchorDoesNotAdvance() {
        // Settled decision 4: repeated paste does not advance the anchor, so two
        // pastes at one playhead position stack. The policy holds no state, which
        // IS the implementation of that rule — pinned so a future "convenience"
        // advance has to break a test to land.
        let track = midiTrack("Keys")
        let payload = [entry(midiClip("a", start: 0), track: track, index: 0),
                       entry(midiClip("b", start: 6), track: track, index: 0)]
        let first = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 32, tracks: [track], activeTrack: nil)
        let second = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 32, tracks: [track], activeTrack: nil)
        #expect(first.landings.map(\.startBeat) == second.landings.map(\.startBeat))
        #expect(first.landings.map(\.startBeat) == [32, 38])
    }

    // MARK: - ⚠️ The GROUP clamp at beat 0

    @Test("a negative anchor clamps the GROUP — the earliest member sits at 0, every gap survives")
    func negativeAnchorClampsTheGroupNotItsMembers() {
        // ⚠️⚠️ THE LOAD-BEARING TEST OF THIS FILE. Clamping each member's
        // absolute start instead would put a, b AND c all at beat 0 — welding
        // them together and silently destroying the rhythm the user copied. That
        // is the m23-g2 group-drag defect, one layer up.
        let track = midiTrack("Keys")
        let payload = [entry(midiClip("a", start: 0, length: 1), track: track, index: 0),
                       entry(midiClip("b", start: 3, length: 1), track: track, index: 0),
                       entry(midiClip("c", start: 7, length: 1), track: track, index: 0)]
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: -5, tracks: [track], activeTrack: nil)

        #expect(plan.anchorBeat == 0, "the plan reports the CLAMPED anchor it used")
        #expect(plan.landings.map(\.startBeat) == [0, 3, 7])
        // Stated as the property rather than as three numbers: every internal
        // gap is preserved exactly.
        let gaps = zip(plan.landings.dropFirst(), plan.landings).map { $0.startBeat - $1.startBeat }
        #expect(gaps == [3, 4])
    }

    @Test("ANTI-VACUITY: the same payload at a POSITIVE anchor is not already at 0")
    func theClampTestIsNotVacuous() {
        // Without this control, the clamp test above would pass unchanged if the
        // policy ignored its anchor entirely and always emitted the source
        // starts. Same payload, positive anchor, different answer.
        let track = midiTrack("Keys")
        let payload = [entry(midiClip("a", start: 0, length: 1), track: track, index: 0),
                       entry(midiClip("b", start: 3, length: 1), track: track, index: 0),
                       entry(midiClip("c", start: 7, length: 1), track: track, index: 0)]
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 16, tracks: [track], activeTrack: nil)
        #expect(plan.anchorBeat == 16)
        #expect(plan.landings.map(\.startBeat) == [16, 19, 23])
    }

    @Test("no reachable payload can produce a negative landing")
    func noLandingIsEverNegative() {
        // A property sweep rather than a case: any anchor, any offsets.
        var generator = SystemRandomNumberGenerator()
        let track = midiTrack("Keys")
        for _ in 0..<200 {
            let anchor = Double.random(in: -500...500, using: &generator)
            let payload = (0..<Int.random(in: 1...5, using: &generator)).map { _ in
                entry(midiClip("x", start: Double.random(in: 0...400, using: &generator)),
                      track: track, index: 0)
            }
            let plan = PasteAnchorPolicy.resolveClipPaste(
                payload: payload, anchorBeat: anchor, tracks: [track], activeTrack: nil)
            #expect(plan.landings.allSatisfy { $0.startBeat >= 0 })
        }
    }

    // MARK: - Refusals

    @Test("an empty payload and a track-less project each refuse, distinctly")
    func refusals() {
        let track = midiTrack("Keys")
        #expect(PasteAnchorPolicy.resolveClipPaste(
            payload: [], anchorBeat: 0, tracks: [track], activeTrack: nil)
            .refusedBy == .emptyPayload)
        #expect(PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(midiClip("a", start: 0), track: track, index: 0)],
            anchorBeat: 0, tracks: [], activeTrack: nil)
            .refusedBy == .noTracks)
    }

    @Test("a relocated paste with no compatible track refuses the WHOLE paste")
    func noCompatibleTrackRefuses() {
        // The source track is gone (relocated), there is no focus, and the only
        // live track is audio — so there is no base track that can hold the
        // topmost MIDI clip and nothing to place relative to.
        let gone = midiTrack("Deleted")
        let live = audioTrack("Audio")
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(midiClip("a", start: 0), track: gone, index: 0)],
            anchorBeat: 8, tracks: [live], activeTrack: nil)
        #expect(plan.refusedBy == .noCompatibleTrack)
        #expect(plan.mode == .relocated)
        #expect(plan.isEmpty)
    }

    // MARK: - P1 / P2 track resolution

    @Test("every source track still alive ⇒ IN PLACE, each clip goes home")
    func inPlaceWhenEverySourceSurvives() {
        let one = midiTrack("One")
        let two = midiTrack("Two")
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(midiClip("a", start: 0), track: one, index: 0),
                      entry(midiClip("b", start: 0), track: two, index: 1)],
            anchorBeat: 12,
            // Note the focus points at a THIRD track — an in-place paste ignores
            // it entirely, which is the half of the all-or-nothing rule that is
            // easy to get wrong.
            tracks: [one, two, midiTrack("Three")], activeTrack: nil)
        #expect(plan.mode == .inPlace)
        let byName = Dictionary(uniqueKeysWithValues: plan.landings.map { ($0.clip.name, $0) })
        #expect(byName["a"]?.targetTrackID == one.id)
        #expect(byName["b"]?.targetTrackID == two.id)
    }

    @Test("ONE missing source track relocates the WHOLE group, not just the orphan")
    func relocationIsAllOrNothing() {
        // A paste that landed two clips at home and one relocated is
        // unexplainable to a user — the switch is deterministic and total.
        let alive = midiTrack("Alive")
        let gone = midiTrack("Gone")
        let base = midiTrack("Base")
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(midiClip("a", start: 0), track: alive, index: 0),
                      entry(midiClip("b", start: 0), track: gone, index: 1)],
            anchorBeat: 0, tracks: [base, alive], activeTrack: inferred(base))
        #expect(plan.mode == .relocated)
        let byName = Dictionary(uniqueKeysWithValues: plan.landings.map { ($0.clip.name, $0) })
        // Base index 0 + (0 − 0) = 0 → base; + (1 − 0) = 1 → alive. NEITHER went
        // "home"; `a` moved even though its own track is still there.
        #expect(byName["a"]?.targetTrackID == base.id)
        #expect(byName["b"]?.targetTrackID == alive.id)
    }

    @Test("a relocated paste keeps its VERTICAL geometry — a two-track gap survives")
    func relocationPreservesTrackSpacing() {
        let gone = midiTrack("Gone")
        let t = (0..<5).map { midiTrack("T\($0)") }
        // Copied from source indices 3 and 5 — a two-track gap.
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [ClipboardClip(clip: midiClip("hi", start: 0), sourceTrackID: gone.id,
                                    sourceTrackIndex: 3),
                      ClipboardClip(clip: midiClip("lo", start: 0), sourceTrackID: gone.id,
                                    sourceTrackIndex: 5)],
            anchorBeat: 0, tracks: t, activeTrack: inferred(t[1]))
        let byName = Dictionary(uniqueKeysWithValues: plan.landings.map { ($0.clip.name, $0) })
        #expect(byName["hi"]?.targetTrackID == t[1].id)   // 1 + (3−3)
        #expect(byName["lo"]?.targetTrackID == t[3].id)   // 1 + (5−3)
    }

    @Test("the base track falls back to the first track that can hold the topmost clip")
    func baseFallsBackWhenThereIsNoFocus() {
        let gone = midiTrack("Gone")
        let audio = audioTrack("Audio")
        let midi = midiTrack("Midi")
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(midiClip("a", start: 0), track: gone, index: 0)],
            anchorBeat: 0, tracks: [audio, midi], activeTrack: nil)
        // Index 0 is audio and cannot hold a MIDI clip, so the base is index 1.
        #expect(plan.landings.first?.targetTrackID == midi.id)
    }

    @Test("⚠️ the P2 index clamp: a 3-track copy onto the LAST track folds instead of crashing")
    func p2IndexClamps() {
        let gone = midiTrack("Gone")
        let t = (0..<3).map { midiTrack("T\($0)") }
        // Source indices 0,1,2 onto base index 2 → 2, 3, 4 — two of which are
        // past the end. Without the clamp this indexes out of bounds.
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [ClipboardClip(clip: midiClip("a", start: 0, length: 2),
                                    sourceTrackID: gone.id, sourceTrackIndex: 0),
                      ClipboardClip(clip: midiClip("b", start: 4, length: 2),
                                    sourceTrackID: gone.id, sourceTrackIndex: 1),
                      ClipboardClip(clip: midiClip("c", start: 8, length: 2),
                                    sourceTrackID: gone.id, sourceTrackIndex: 2)],
            anchorBeat: 0, tracks: t, activeTrack: inferred(t[2]))
        // All three fold onto the last track — and because their windows do NOT
        // overlap (2-beat clips at 0, 4, 8) all three still land.
        #expect(plan.landings.count == 3)
        #expect(plan.skipped.isEmpty)
        #expect(plan.landings.allSatisfy { $0.targetTrackID == t[2].id })
    }

    @Test("⚠️ the clamp folding two source tracks into one SKIPS the overlapping sibling")
    func foldedTracksSkipOverlappingSiblings() {
        // The failure this catches is NOT the +6 dB resident overlap — it is
        // worse-shaped. Every pasted clip is a CLAIMANT of its window, and
        // `resolvingOverlaps` exempts claimants from trimming by construction, so
        // two pasted clips folded onto one track would stack SILENTLY with
        // nothing downstream able to notice. The policy is the only layer that
        // can see it.
        let gone = midiTrack("Gone")
        let only = midiTrack("Only")
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [ClipboardClip(clip: midiClip("upper", start: 0, length: 4),
                                    sourceTrackID: gone.id, sourceTrackIndex: 0),
                      ClipboardClip(clip: midiClip("lower", start: 2, length: 4),
                                    sourceTrackID: gone.id, sourceTrackIndex: 1)],
            anchorBeat: 0, tracks: [only], activeTrack: inferred(only))
        #expect(plan.landings.count == 1)
        #expect(plan.landings.first?.clip.name == "upper")
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.reason == .overlapsPastedSibling)
        #expect(plan.skipped.first?.clipName == "lower")
    }

    @Test("a FLUSH sibling — one starting exactly where another ends — is not an overlap")
    func flushSiblingsBothLand() {
        let gone = midiTrack("Gone")
        let only = midiTrack("Only")
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [ClipboardClip(clip: midiClip("first", start: 0, length: 4),
                                    sourceTrackID: gone.id, sourceTrackIndex: 0),
                      ClipboardClip(clip: midiClip("second", start: 4, length: 4),
                                    sourceTrackID: gone.id, sourceTrackIndex: 1)],
            anchorBeat: 0, tracks: [only], activeTrack: inferred(only))
        // Half-open windows, the same form `resolvingOverlaps` uses — so the two
        // layers agree at the boundary instead of one of them rejecting a flush
        // landing the other would have accepted.
        #expect(plan.landings.count == 2)
        #expect(plan.skipped.isEmpty)
    }

    // MARK: - Kind mismatch: skip and report

    @Test("a MIDI clip aimed at an audio track is SKIPPED, and the rest still land")
    func kindMismatchSkipsWithoutAbortingTheGroup() {
        // The `importAudioBatch` rule: a bad item is reported and skipped, and
        // never aborts the others.
        let gone = midiTrack("Gone")
        let audio = audioTrack("Audio")
        let midi = midiTrack("Midi")
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [ClipboardClip(clip: midiClip("m", start: 0), sourceTrackID: gone.id,
                                    sourceTrackIndex: 0),
                      ClipboardClip(clip: audioClip("a", start: 0), sourceTrackID: gone.id,
                                    sourceTrackIndex: 1)],
            anchorBeat: 0, tracks: [midi, audio], activeTrack: inferred(midi))
        // m → index 0 (midi, ok); a → index 1 (audio, ok). Both land.
        #expect(plan.landings.count == 2)
        #expect(plan.skipped.isEmpty)

        // Now flip the destination order so both are aimed at the wrong kind.
        let flipped = PasteAnchorPolicy.resolveClipPaste(
            payload: [ClipboardClip(clip: midiClip("m", start: 0), sourceTrackID: gone.id,
                                    sourceTrackIndex: 0),
                      ClipboardClip(clip: audioClip("a", start: 0), sourceTrackID: gone.id,
                                    sourceTrackIndex: 1)],
            anchorBeat: 0, tracks: [audio, midi], activeTrack: inferred(audio))
        #expect(flipped.landings.isEmpty)
        #expect(flipped.skipped.count == 2)
        #expect(flipped.skipped.allSatisfy { $0.reason == .trackKindMismatch })
        // ⚠️ Not a refusal: a plan WAS produced and every member was skipped.
        // The two states are distinguishable, which is what lets the app say
        // "none of these fit" rather than "nothing happened".
        #expect(flipped.refusedBy == nil)
        #expect(flipped.isEmpty)
    }

    @Test("a bus track can hold neither kind")
    func busTracksHoldNothing() {
        let gone = midiTrack("Gone")
        let bus = Track(name: "Bus", kind: .bus)
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(midiClip("m", start: 0), track: gone, index: 0)],
            anchorBeat: 0, tracks: [bus], activeTrack: inferred(bus))
        #expect(plan.skipped.first?.reason == .trackKindMismatch)
    }

    // MARK: - Notes

    @Test("the insertion point is the playhead's CLIP-LOCAL beat when the transport is inside")
    func noteAnchorInsideTheClip() {
        #expect(PasteAnchorPolicy.noteInsertionPoint(
            playheadProjectBeat: 18, clipStartBeat: 12, clipLengthBeats: 16) == 6)
        // Both edges inclusive, matching `PianoRollPlayhead.isVisible` — the ONE
        // predicate the line and the off-clip cue are complementary on.
        #expect(PasteAnchorPolicy.noteInsertionPoint(
            playheadProjectBeat: 12, clipStartBeat: 12, clipLengthBeats: 16) == 0)
        #expect(PasteAnchorPolicy.noteInsertionPoint(
            playheadProjectBeat: 28, clipStartBeat: 12, clipLengthBeats: 16) == 16)
    }

    @Test("outside the clip there is NO insertion point — nil, never a clamp to the nearer edge")
    func noteAnchorOutsideTheClipIsNil() {
        // ⚠️ THIS ASSERTED `== 0` UNTIL m25-f-2. The old rule borrowed
        // `PianoRollBarOps.targetBarStartBeat`'s "else bar 0", which is still
        // right for BAR OPS and is still what that function does. It was wrong
        // for PASTE, which has two better referents than bar 0 — the notes it
        // came from, and what the user is looking at — and sending a paste to
        // bar 0 put it somewhere the user often could not see. `nil` is this
        // predicate declining to answer; `resolveNotePaste` decides instead.
        //
        // ⚠️ The inside case above must keep returning 0 at the clip's own
        // start, so this pair is also the anti-vacuity control for the change:
        // 0-the-beat and nil-the-absence are now distinguishable, and a
        // regression that revived `return 0` would collapse them again.
        #expect(PasteAnchorPolicy.noteInsertionPoint(
            playheadProjectBeat: 4, clipStartBeat: 12, clipLengthBeats: 16) == nil)
        #expect(PasteAnchorPolicy.noteInsertionPoint(
            playheadProjectBeat: 400, clipStartBeat: 12, clipLengthBeats: 16) == nil)
        // Parking at the nearer EDGE is still refused by m23-c1: neither of the
        // two answers an edge-clamp would give (0 for the first, 16 for the
        // second) is produced.
    }

    @Test("notes translate RIGIDLY to the anchor — every internal offset survives")
    func notesTranslateRigidly() {
        let notes = [MIDINote(pitch: 60, startBeat: 4, lengthBeats: 0.5),
                     MIDINote(pitch: 64, startBeat: 4.75, lengthBeats: 0.5),   // off-grid
                     MIDINote(pitch: 67, startBeat: 6, lengthBeats: 2)]
        let out = PasteAnchorPolicy.translatedNotes(notes, toAnchor: 10)
        #expect(out.map(\.startBeat) == [10, 10.75, 12])
        // ⚠️ THE SWUNG NOTE AT +0.75 IS THE POINT. If the anchor were applied per
        // note WITH a snap, it would land on the grid and the figure would come
        // out straight — the m23-g2 weld. Nothing here snaps; the caller snaps
        // the anchor once.
        #expect(out.map(\.pitch) == [60, 64, 67])
        #expect(out.map(\.velocity) == notes.map(\.velocity))
        #expect(out.map(\.lengthBeats) == [0.5, 0.5, 2])
    }

    @Test("a negative note anchor clamps the GROUP, not each note")
    func negativeNoteAnchorClampsTheGroup() {
        // ⚠️ LIVE CODE, NOT A FORMALITY. `MIDINote.init` floors `startBeat` at 0
        // PER NOTE and `pasteNotes` reconstructs every note through it — so a
        // payload reaching the store with negative starts does not error, it
        // welds. This clamp is what keeps it from getting there.
        let notes = [MIDINote(pitch: 60, startBeat: 0),
                     MIDINote(pitch: 62, startBeat: 1.5),
                     MIDINote(pitch: 64, startBeat: 3)]
        let out = PasteAnchorPolicy.translatedNotes(notes, toAnchor: -8)
        #expect(out.map(\.startBeat) == [0, 1.5, 3])
        // The control: the same payload at a positive anchor moves, so the
        // assertion above is not passing because nothing translated.
        let moved = PasteAnchorPolicy.translatedNotes(notes, toAnchor: 8)
        #expect(moved.map(\.startBeat) == [8, 9.5, 11])
    }

    @Test("every pasted note gets a FRESH id, and two pastes never collide")
    func pastedNotesGetFreshIds() {
        // Reusing source ids while pasting into the SOURCE clip yields duplicate
        // ids in one clip, which breaks `canonicallyOrdered`'s id tiebreak (used
        // by the roll's `needsReseed`) and makes selection ambiguous.
        let notes = [MIDINote(pitch: 60, startBeat: 0), MIDINote(pitch: 64, startBeat: 1)]
        let first = PasteAnchorPolicy.translatedNotes(notes, toAnchor: 0)
        let second = PasteAnchorPolicy.translatedNotes(notes, toAnchor: 0)
        let sourceIDs = Set(notes.map(\.id))
        #expect(Set(first.map(\.id)).isDisjoint(with: sourceIDs))
        #expect(Set(second.map(\.id)).isDisjoint(with: sourceIDs))
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
        #expect(Set(first.map(\.id)).count == 2)
    }

    @Test("an empty note payload translates to nothing rather than dividing by an absent min")
    func emptyNotePayload() {
        #expect(PasteAnchorPolicy.translatedNotes([], toAnchor: 12).isEmpty)
    }

    // MARK: - The refusal copy the user actually reads

    @Test("every paste refusal has copy, and it names what to do next rather than what failed")
    func refusalCopyIsActionable() {
        // The design language's rule for refusals. Swept over ALL cases so a new
        // one cannot ship with a nil message that reaches the amber bubble as an
        // empty bar.
        for reason in PasteAnchorPolicy.ClipPasteRefusal.allCases {
            let text = ClipboardPasteRefusal(reason).errorDescription
            #expect(text?.isEmpty == false, "no copy for \(reason)")
            // Each one tells the user the next move ("copy something first",
            // "add a track first"), which is what "first" is doing here.
            #expect(text?.contains("first") == true, "\(reason) does not say what to do next")
        }
        // And they are DISTINCT, so the bubble tells the three states apart.
        let all = PasteAnchorPolicy.ClipPasteRefusal.allCases
            .map { ClipboardPasteRefusal($0).errorDescription ?? "" }
        #expect(Set(all).count == all.count)
        #expect(ClipboardPasteRefusal(.noTracks).errorDescription?
            .contains("add a track") == true)
    }

    @Test("a skip report NAMES the clip it could not place, and pluralises honestly")
    func skipReportNamesTheClip() {
        // Skips are reported, never swallowed: a paste of three clips quietly
        // becoming a paste of two is exactly what this copy prevents.
        let one = ClipboardPasteSkipReport([
            PasteAnchorPolicy.ClipPasteSkip(sourceClipID: UUID(), clipName: "Verse",
                                            reason: .trackKindMismatch),
        ]).errorDescription
        #expect(one?.contains("Verse") == true)
        #expect(one?.contains("can't hold it") == true)

        let many = ClipboardPasteSkipReport([
            PasteAnchorPolicy.ClipPasteSkip(sourceClipID: UUID(), clipName: "Verse",
                                            reason: .overlapsPastedSibling),
            PasteAnchorPolicy.ClipPasteSkip(sourceClipID: UUID(), clipName: "Chorus",
                                            reason: .overlapsPastedSibling),
        ]).errorDescription
        #expect(many?.contains("2 clips") == true)
        #expect(many?.contains("Verse") == true)
        #expect(many?.contains("another pasted clip") == true)

        // Empty is nil rather than an empty bubble — `presentClipboardSkips`
        // guards on `skips.first`, and this is the second line of defence.
        #expect(ClipboardPasteSkipReport([]).errorDescription == nil)
    }

    @Test("notes pasted past the clip end are NOT clamped — the app draws them honestly")
    func notesPastTheClipEndSurvive() {
        // `PianoRollModel.playableEndBeat` returns nil for these and `drawNotes`
        // gives them the m19-g ghost pill, with the velocity lane matching. The
        // honest behaviour already has a visual vocabulary; a clamp here would
        // destroy pasted material to avoid a state the app can draw.
        let notes = [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)]
        let out = PasteAnchorPolicy.translatedNotes(notes, toAnchor: 900)
        #expect(out.first?.startBeat == 900)
    }
    // MARK: - m25-f-4: the empty-lane right-click's composition

    /// ⭐ **THE ITEM'S WHOLE PROMISE, IN ONE ASSERTION**: a right-click on empty
    /// lane space names a TRACK and a BEAT, and the paste honours both.
    ///
    /// The gesture cannot be driven from here — nothing in this tree can
    /// right-click — so what is pinned is the composition it rides: the lane's
    /// track fed in as `.explicit` (which is what
    /// `AppModel.pasteClipsFromClipboardDetailed(intoTrack:atBeat:)` produces by
    /// handing it to `ArrangeActiveTrack.resolve`'s `explicit:` input), and the
    /// pointer's beat as the anchor.
    ///
    /// ⚠️ **THE SOURCE TRACK IS DELIBERATELY STILL LIVE**, which is the ordinary
    /// copy-then-paste case and is EXACTLY the configuration that made this item
    /// wait for m25-l-3: before that ruling a live-source paste was always
    /// `.inPlace` and the named destination was DISCARDED, so this menu would
    /// have pasted into a lane other than the one it was opened on.
    @Test("m25-f-4: a lane-named destination and a pointer-named beat are both honoured")
    func laneRightClickHonoursTrackAndBeat() {
        let source = midiTrack("Keys")
        let other = midiTrack("Pad")
        let target = midiTrack("Bass")
        let clip = midiClip("riff", start: 16)
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(clip, track: source, index: 0)],
            anchorBeat: 37.5,                       // the pointer's snapped beat
            tracks: [source, other, target],
            activeTrack: explicit(target))          // the lane that was clicked

        #expect(plan.refusedBy == nil)
        #expect(plan.skipped.isEmpty)
        #expect(plan.mode == .relocated)
        #expect(plan.landings.count == 1)
        #expect(plan.landings.first?.targetTrackID == target.id)
        #expect(plan.landings.first?.startBeat == 37.5)
        // NEGATIVE CONTROL for the assertion above: the same call with the
        // destination merely INFERRED lands home at the same beat. So the track
        // move is the `.explicit` origin doing work, not the anchor override.
        let inferredPlan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(clip, track: source, index: 0)],
            anchorBeat: 37.5, tracks: [source, other, target],
            activeTrack: inferred(target))
        #expect(inferredPlan.mode == .inPlace)
        #expect(inferredPlan.landings.first?.targetTrackID == source.id)
        #expect(inferredPlan.landings.first?.startBeat == 37.5)
    }

    @Test("m25-f-4: a MIDI payload right-clicked onto an AUDIO lane is a NAMED skip, never silence")
    func laneRightClickOntoAWrongKindLaneSkipsWithAReason() {
        // The menu deliberately does NOT grey out on kind (that decision is
        // `ClipboardMenuPolicy.laneContextPasteItem`'s banner) — the refusal
        // happens here, per clip, WITH a reason and the clip's name, which is
        // what the amber bubble renders.
        let source = midiTrack("Keys")
        let lane = audioTrack("Vox")
        let clip = midiClip("riff", start: 0)
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(clip, track: source, index: 0)],
            anchorBeat: 8, tracks: [source, lane], activeTrack: explicit(lane))
        #expect(plan.landings.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.trackKindMismatch])
        #expect(plan.skipped.first?.clipName == "riff")
        // NOT a policy-level refusal: a plan WAS resolved and one member was
        // skipped, which is what lets the app say WHICH clip and WHY.
        #expect(plan.refusedBy == nil)
    }

    @Test("m25-f-4: the group clamp still owns a negative pointer beat")
    func laneRightClickNegativeBeatClampsTheGroup() {
        // The wire route (`edit.pasteClips {atBeat}`) does not validate the beat
        // — this is the one home for that rule, and it slides the group rigidly
        // rather than welding its members onto 0.
        let track = midiTrack("Keys")
        let a = midiClip("a", start: 8)
        let b = midiClip("b", start: 12)
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: [entry(a, track: track, index: 0), entry(b, track: track, index: 0)],
            anchorBeat: -5, tracks: [track], activeTrack: explicit(track))
        #expect(plan.anchorBeat == 0)
        #expect(plan.landings.map(\.startBeat) == [0, 4])
    }

}
