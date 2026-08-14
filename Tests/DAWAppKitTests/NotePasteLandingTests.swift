import Testing
import Foundation
import DAWCore
@testable import DAWAppKit

/// m25-f-2 — PASTE WITH NO INSERTION POINT. The user asked that a paste with no
/// playhead in the target clip *"create a slightly repositioned selected group of
/// notes above the source ones so that user can immediately capture them with
/// mouse and drag where he wants them to go"*, and for the cross-clip case that
/// it land *"in visible area in selected state ready to be dragged"*.
///
/// These pin the three-branch rule, the nudge search, and — the test that makes
/// the group clamps REAL rather than asserted — the two weld negative controls.
@Suite("Note paste landing (m25-f-2)")
struct NotePasteLandingTests {

    // MARK: - Fixtures

    /// A clip at project beat 12, 16 beats long. A playhead at project beat 4 is
    /// OUTSIDE it (before), one at 400 is outside it (after), one at 18 is
    /// inside it at clip-local 6.
    private let clipStart: Double = 12
    private let clipLength: Double = 16

    private func note(_ pitch: Int, _ start: Double, _ length: Double = 1,
                      id: UUID = UUID()) -> MIDINote {
        MIDINote(id: id, pitch: pitch, velocity: 100, startBeat: start, lengthBeats: length)
    }

    private func resolve(payload: [MIDINote],
                         playhead: Double,
                         existing: [MIDINote],
                         visibleStart: Double = 0,
                         visiblePitches: ClosedRange<Int>? = nil)
        -> PasteAnchorPolicy.NotePasteLanding {
        PasteAnchorPolicy.resolveNotePaste(
            payload: payload,
            playheadProjectBeat: playhead,
            clipStartBeat: clipStart,
            clipLengthBeats: clipLength,
            existingNotes: existing,
            visibleStartLocalBeat: visibleStart,
            visiblePitches: visiblePitches)
    }

    // MARK: - The three branches

    @Test("a playhead INSIDE the clip is an insertion point — the shipped rule, unchanged")
    func playheadInsideWins() {
        let source = note(60, 3)
        // Sources present AND a playhead inside: the playhead must win, or
        // m25-f-2 would have silently changed the behaviour the m23-ek-3 gate
        // pins (its note legs seek to a beat inside the target clip).
        let landing = resolve(payload: [source], playhead: 18, existing: [source])
        #expect(landing.mode == .playhead)
        #expect(landing.localBeat == 6)
        #expect(landing.pitchOffset == 0)
        #expect(landing.snap == .nearest)
    }

    @Test("no insertion point + the sources are still here → ABOVE them, at the same time")
    func aboveSourceBranch() {
        let source = note(60, 3.5)
        let landing = resolve(payload: [source], playhead: 4, existing: [source])
        #expect(landing.mode == .aboveSource)
        // TIME UNCHANGED — the group is nudged in pitch only.
        #expect(landing.localBeat == 3.5)
        #expect(landing.pitchOffset > 0)
        // ⚠️ AND IT MUST NOT BE SNAPPED. 3.5 is off a 1/1 grid; snapping the
        // anchor would move a copy away from the notes it copied.
        #expect(landing.snap == PasteAnchorPolicy.NotePasteSnap.none)
    }

    @Test("no insertion point + the sources are GONE (a CUT) → the visible area")
    func cutFallsToVisibleStart() {
        // ⚠️ THE CASE `ClipboardNotes.sourceClipID` CANNOT DECIDE. After a cut it
        // still names this clip, but the notes it names are gone and "sit above
        // the source ones" is meaningless. Id presence answers the question that
        // is actually being asked.
        let source = note(60, 3)
        let landing = resolve(payload: [source], playhead: 4, existing: [], visibleStart: 8)
        #expect(landing.mode == .visibleStart)
        #expect(landing.localBeat == 8)
        #expect(landing.pitchOffset == 0)
        #expect(landing.snap == .upward)
    }

    @Test("no insertion point + a payload from ANOTHER clip → the visible area")
    func crossClipFallsToVisibleStart() {
        // "Came from elsewhere" and "was cut from here" resolve through the same
        // test, because both mean the same thing to the user: there is nothing
        // here to sit above. (⚠️ NOT because ids are globally unique — measured
        // false: `ProjectStore.reidentified` copies `notes:` verbatim, so a
        // DUPLICATED CLIP carries identical note ids. Rule 2 firing there is the
        // right behaviour anyway; see `resolveNotePaste`'s banner.)
        let elsewhere = note(72, 40)
        let residents = [note(60, 0), note(64, 2)]
        let landing = resolve(payload: [elsewhere], playhead: 400,
                              existing: residents, visibleStart: 5)
        #expect(landing.mode == .visibleStart)
        #expect(landing.localBeat == 5)
        #expect(landing.pitchOffset == 0)
    }

    @Test("the visible-start anchor is clamped to >= 0 as a GROUP")
    func visibleStartClampsAtZero() {
        let landing = resolve(payload: [note(60, 0)], playhead: 4,
                              existing: [], visibleStart: -20)
        #expect(landing.localBeat == 0)
    }

    // MARK: - The nudge

    @Test("the nudge is the SMALLEST offset that clears the source — one semitone for one note")
    func nudgeIsMinimal() {
        let source = note(60, 0, 2)
        let offset = PasteAnchorPolicy.nudgePitchOffset(
            payload: [source], existing: [source], visiblePitches: nil)
        // Nothing sits on 61, so 61 is enough. A fixed +12 would throw every
        // paste an octave for a problem this paste does not have.
        #expect(offset == 1)
    }

    @Test("the nudge steps past occupied rows until it clears")
    func nudgeSkipsOccupiedRows() {
        let source = note(60, 0, 2)
        // A chromatic wall on 61, 62, 63 at the same time: the first free row is
        // 64, i.e. +4.
        let wall = [note(61, 0, 2), note(62, 0, 2), note(63, 0, 2)]
        let offset = PasteAnchorPolicy.nudgePitchOffset(
            payload: [source], existing: [source] + wall, visiblePitches: nil)
        #expect(offset == 4)
    }

    @Test("a row occupied at a DIFFERENT time does not block — windows are half-open")
    func nudgeIgnoresNonOverlappingTime() {
        let source = note(60, 0, 2)
        // Pitch 61 is used, but at beats 8-9, nowhere near the payload. And a
        // note that ABUTS exactly (starts at 2, where the payload ends) is flush,
        // not colliding — the same `a.start < b.end && b.start < a.end` form
        // `resolvingOverlaps` uses.
        let elsewhere = [note(61, 8, 1), note(61, 2, 1)]
        let offset = PasteAnchorPolicy.nudgePitchOffset(
            payload: [source], existing: [source] + elsewhere, visiblePitches: nil)
        #expect(offset == 1)
    }

    @Test("the nudge is bounded by the VISIBLE pitch window — visibility is never traded")
    func nudgeStaysOnScreen() {
        // Only rows 60 and 61 are on screen, so there is exactly ONE candidate:
        // +1, and it collides. Visibility wins anyway — a colliding copy the
        // user can see beats a clean one they cannot.
        let source = note(60, 0, 2)
        let blocker = note(61, 0, 2)
        let offset = PasteAnchorPolicy.nudgePitchOffset(
            payload: [source], existing: [source, blocker], visiblePitches: 60...61)
        #expect(offset == 1)
        // ANTI-VACUITY: with the window opened up, the same payload and the same
        // blocker resolve to 2 — so the 1 above is the CEILING biting, not the
        // collision test failing to see the blocker.
        let unbounded = PasteAnchorPolicy.nudgePitchOffset(
            payload: [source], existing: [source, blocker], visiblePitches: 40...80)
        #expect(unbounded == 2)
    }

    @Test("no room above → the nudge goes DOWN rather than off screen or nowhere")
    func nudgeFallsDownward() {
        let source = note(60, 0, 2)
        // The group is already at the very top of the visible window.
        let offset = PasteAnchorPolicy.nudgePitchOffset(
            payload: [source], existing: [source], visiblePitches: 40...60)
        #expect(offset == -1)
    }

    @Test("⚠️ a CLEAN nudge down beats a COLLIDING one up — capturability is the goal")
    func nonCollidingDownwardBeatsCollidingUpward() {
        // ⭐ THIS TEST CORRECTED ITS OWN IMPLEMENTATION'S DOC. "Above" is the
        // user's word and the preferred direction, but their stated PURPOSE is
        // that they can immediately grab the copy — and a copy sharing rows with
        // its source is ambiguous to click on either side of it. So direction is
        // a preference and capturability is the goal.
        let source = note(60, 0, 2)
        // Every row from 61 up to 72 (a full octave) is occupied at the same
        // time; 59 is free.
        let wall = (61...72).map { note($0, 0, 2) }
        let offset = PasteAnchorPolicy.nudgePitchOffset(
            payload: [source], existing: [source] + wall, visiblePitches: nil)
        #expect(offset == -1)
        // ANTI-VACUITY: clear ONE row inside the wall and the upward preference
        // reasserts itself — so the -1 above is the search exhausting upward
        // candidates, not a downward bias.
        let gapped = wall.filter { $0.pitch != 65 }
        let preferred = PasteAnchorPolicy.nudgePitchOffset(
            payload: [source], existing: [source] + gapped, visiblePitches: nil)
        #expect(preferred == 5)
    }

    @Test("no room in EITHER direction → 0, a stack, and the paste still happens")
    func nudgeExhausted() {
        let source = note(60, 0, 2)
        let offset = PasteAnchorPolicy.nudgePitchOffset(
            payload: [source], existing: [source], visiblePitches: 60...60)
        #expect(offset == 0)
    }

    @Test("the nudge never exceeds one octave, however dense the material")
    func nudgeIsBoundedByAnOctave() {
        let source = note(60, 0, 2)
        // Walled a full octave in BOTH directions at the same time, so nothing
        // clears anywhere the search is allowed to look. It stops at the octave
        // and takes its first candidate rather than searching on: a copy 20
        // semitones up would satisfy "doesn't overlap" while failing both
        // "slightly repositioned" and "immediately capturable".
        let wall = (Array(48...59) + Array(61...72)).map { note($0, 0, 2) }
        let offset = PasteAnchorPolicy.nudgePitchOffset(
            payload: [source], existing: [source] + wall, visiblePitches: nil)
        #expect(offset == 1)
        #expect(abs(offset) <= PasteAnchorPolicy.maxNudgeSemitones)
        // ANTI-VACUITY: row 73 IS free and IS within 0...127, so an unbounded
        // search would have found +13. The bound is what stops it.
        #expect(!wall.contains { $0.pitch == 73 })
    }

    // MARK: - ⚠️ THE WELD NEGATIVE CONTROLS

    @Test("⚠️ a SWUNG figure nudged in pitch keeps every internal offset EXACTLY")
    func swungFigureSurvivesTheNudge() {
        // The m23-g2 defect, on the paste path: the sub-grid phases here (+0.75,
        // +1.5) are what a per-note snap would destroy, silently turning a swung
        // figure straight. `translatedNotes` snaps nothing and the
        // `.aboveSource` branch does not ask the caller to.
        let notes = [note(60, 4, 0.5), note(64, 4.75, 0.5), note(67, 5.5, 2)]
        let out = PasteAnchorPolicy.translatedNotes(notes, toAnchor: 4, pitchOffset: 3)
        #expect(out.map(\.startBeat) == [4, 4.75, 5.5])
        // RELATIVE offsets, stated as the thing that must survive rather than
        // inferred from the absolutes above.
        let starts = out.map(\.startBeat)
        #expect(zip(starts.dropFirst(), starts).map(-) == [0.75, 0.75])
        #expect(out.map(\.lengthBeats) == [0.5, 0.5, 2])
    }

    @Test("⚠️ a chord nudged into the 127 ceiling keeps its INTERVALS — the group clamp")
    func chordAtThePitchCeilingKeepsItsIntervals() {
        // MEASURED HAZARD, not an argued one: `MIDINote.init` does
        // `pitch.clamped(to: 0...127)` PER NOTE. Without a group clamp the top
        // note would stop at 127 while the rest kept rising, and a chord would
        // silently become a cluster — `PianoRollModel.moveSelection` states this
        // defect in those words for the drag path.
        let chord = [note(120, 0), note(124, 0), note(127, 0)]
        let out = PasteAnchorPolicy.translatedNotes(chord, toAnchor: 0, pitchOffset: 12)
        // The ask was +12; the group has 0 headroom, so the applied delta is 0.
        #expect(out.map(\.pitch) == [120, 124, 127])
        let pitches = out.map(\.pitch)
        #expect(zip(pitches.dropFirst(), pitches).map(-) == [4, 3])
        #expect(pitches.allSatisfy { MIDINote.pitchRange.contains($0) })

        // ANTI-VACUITY: the SAME chord with room moves as one body, intervals
        // intact — so the equality above is the clamp firing, not the offset
        // being ignored everywhere.
        let roomy = [note(60, 0), note(64, 0), note(67, 0)]
        let moved = PasteAnchorPolicy.translatedNotes(roomy, toAnchor: 0, pitchOffset: 12)
        #expect(moved.map(\.pitch) == [72, 76, 79])
    }

    @Test("⚠️ a chord nudged DOWN into 0 keeps its intervals too")
    func chordAtTheFloorKeepsItsIntervals() {
        let chord = [note(0, 0), note(4, 0), note(7, 0)]
        let out = PasteAnchorPolicy.translatedNotes(chord, toAnchor: 0, pitchOffset: -5)
        #expect(out.map(\.pitch) == [0, 4, 7])
        let pitches = out.map(\.pitch)
        #expect(zip(pitches.dropFirst(), pitches).map(-) == [4, 3])
    }

    @Test("the default pitchOffset is 0, so every pre-m25-f-2 caller is byte-identical")
    func pitchOffsetDefaultsToZero() {
        let notes = [note(60, 4), note(67, 6)]
        let out = PasteAnchorPolicy.translatedNotes(notes, toAnchor: 10)
        #expect(out.map(\.pitch) == [60, 67])
        #expect(out.map(\.startBeat) == [10, 12])
    }

    @Test("a nudged paste still mints FRESH ids — it lands in the SOURCE clip")
    func nudgedPasteMintsFreshIDs() {
        // The whole reason this branch exists is that the copy lands in the clip
        // it came from. Reusing ids there would put duplicate ids in one clip,
        // break `MIDINote.canonicallyOrdered`'s id tiebreak and make the
        // selection ambiguous — click one, both respond.
        let source = note(60, 3)
        let out = PasteAnchorPolicy.translatedNotes([source], toAnchor: 3, pitchOffset: 1)
        #expect(out.first?.id != source.id)
    }

    // MARK: - ⚠️ THE VISIBLE-AREA PASTE MUST NOT LAND OFF SCREEN

    @Test("⚠️ the visible-area anchor snaps UP — `snap` would round it OFF THE SCREEN")
    @MainActor
    func visibleStartSnapsUpNotNearest() {
        // ⭐ A REAL DEFECT THIS CAUGHT, not a hypothetical. `PianoRollModel.snap`
        // rounds to NEAREST: `max(0, (beat/grid).rounded() * grid)`. The
        // `.visibleStart` anchor is the viewport's LEADING EDGE, so at `.bar` in
        // 4/4 an edge at clip-local 5 rounds to 4 — a beat BEFORE the left edge
        // of the screen. The one branch whose entire purpose is that the user
        // can see and grab the group would have put it off screen.
        let model = PianoRollModel()
        let visibleEdge: Double = 5
        #expect(model.snap(beat: visibleEdge, resolution: .bar) == 4)        // the defect
        #expect(model.snapUp(beat: visibleEdge, resolution: .bar) == 8)      // the fix
        // THE INVARIANT, stated directly: the snapped anchor is never before the
        // visible edge. Swept across the whole grid ladder so a future
        // resolution cannot quietly break it.
        for resolution in SnapResolution.allCases {
            for edge in stride(from: 0.0, through: 8.0, by: 0.25) {
                #expect(model.snapUp(beat: edge, resolution: resolution) >= edge)
            }
        }
    }

    @Test("snapUp passes through with snapping OFF, and floors at 0 — `snap`'s own contract")
    @MainActor
    func snapUpMatchesSnapOnTheEdgeCases() {
        let model = PianoRollModel()
        #expect(model.snapUp(beat: 3.7, resolution: .off) == 3.7)
        #expect(model.snapUp(beat: -9, resolution: .off) == 0)
        #expect(model.snapUp(beat: -9, resolution: .bar) == 0)
        // Already ON a line stays put — "at or after", not "strictly after", or
        // a paste at an exact bar edge would jump a whole bar right.
        #expect(model.snapUp(beat: 8, resolution: .bar) == 8)
    }

    // MARK: - ⚠️ AUTO-EXTEND MUST NOT RESURRECT LATENT NOTES (m25-f-3)

    @Test("⚠️ a group nudge does NOT let an already-latent note drag the clip's end out")
    @MainActor
    func latentNotesCannotGrowTheClip() {
        // ⭐ THE DEFECT: `ClipAutoExtend.coverage` takes the MAX end over the ids
        // it is given, so handing it the raw selection means ⌘A + a one-16th
        // timing nudge grows the clip toward a forgotten note at bar 20. m25-a
        // names that exact surprise for the double-click path; arriving through
        // the drag door does not make it a different surprise.
        //
        // ⭐ THE FIXTURE DISTANCE IS ITSELF A FINDING, and my anti-vacuity
        // control is what produced it. I first put the latent note at beat 80
        // (bar 20) — and the control went RED, because `maxGrowthBars` (16 bars
        // = 68 beats here) already caps the target below that onset, so
        // `extendedLength`'s strict-onset test refuses. **The m25-a cap bounds
        // this hazard but does not close it**: a latent note within 16 bars is
        // not protected at all, and beat 20 below grows a 4-beat clip to 24.
        // That is the range the filter has to cover.
        let model = PianoRollModel()
        let audible = note(60, 1)         // inside a 4-beat clip
        let latent = note(72, 20)         // bar 5 — already past the end, inside the cap
        model.load(notes: [audible, latent], clipLengthBeats: 4)
        model.selection = [audible.id, latent.id]
        model.beginMove(anchorID: audible.id)

        let mayGrow = model.moveIDsStartingAudible()
        #expect(mayGrow == [audible.id])
        #expect(!mayGrow.contains(latent.id))

        // AND THE CONSEQUENCE, asserted through the real rule rather than
        // inferred: with only the audible id, the clip does not grow at all.
        let span = ClipAutoExtend.coverage(of: model.draft, ids: mayGrow)
        #expect(span?.endBeat == 2)
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: span?.onsetBeat ?? 0,
            coveringEndBeat: span?.endBeat ?? 0, beatsPerBar: 4) == nil)

        // ANTI-VACUITY: the UNFILTERED selection really would have grown it, so
        // the nil above is the filter working, not the rule declining anyway.
        let unfiltered = ClipAutoExtend.coverage(of: model.draft, ids: model.selection)
        #expect(unfiltered?.endBeat == 21)
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: unfiltered?.onsetBeat ?? 0,
            coveringEndBeat: unfiltered?.endBeat ?? 0, beatsPerBar: 4) == 24)
    }

    @Test("a note the gesture pushed past the end DOES still grow the clip — the feature works")
    @MainActor
    func draggingANoteOutStillExtends() {
        // The other side of the filter: m25-f-3's whole point is that dragging a
        // note to the clip edge extends it. Only notes that STARTED latent are
        // excluded, never notes the user just pushed out.
        let model = PianoRollModel()
        let inside = note(60, 1)
        model.load(notes: [inside], clipLengthBeats: 4)
        model.selection = [inside.id]
        model.beginMove(anchorID: inside.id)
        // Drag it well past the end.
        model.moveSelection(deltaBeats: 5, deltaPitch: 0, resolution: .off)

        let mayGrow = model.moveIDsStartingAudible()
        #expect(mayGrow == [inside.id])
        let span = ClipAutoExtend.coverage(of: model.draft, ids: mayGrow)
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: span?.onsetBeat ?? 0,
            coveringEndBeat: span?.endBeat ?? 0, beatsPerBar: 4) == 8)
    }

    @Test("with no move in flight the set is empty — safe from any gesture-end branch")
    @MainActor
    func noMoveMeansNoGrowth() {
        let model = PianoRollModel()
        model.load(notes: [note(60, 1)], clipLengthBeats: 4)
        #expect(model.moveIDsStartingAudible().isEmpty)
    }

    // MARK: - Composition

    @Test("the above-source branch composes into a group the user can actually grab")
    func aboveSourceComposesEndToEnd() {
        // The whole feature, resolved then applied, as the view does it.
        let sources = [note(60, 2, 1), note(64, 2.5, 1)]
        let landing = resolve(payload: sources, playhead: 4, existing: sources,
                              visiblePitches: 40...90)
        #expect(landing.mode == .aboveSource)
        let pasted = PasteAnchorPolicy.translatedNotes(
            sources, toAnchor: landing.localBeat, pitchOffset: landing.pitchOffset)
        // Same rhythm, same interval, shifted up as one body.
        #expect(pasted.map(\.startBeat) == sources.map(\.startBeat))
        #expect(pasted.map { $0.pitch - landing.pitchOffset } == sources.map(\.pitch))
        // And NOT on any source row+window, which is what "capturable" means.
        for p in pasted {
            #expect(!sources.contains {
                $0.pitch == p.pitch && $0.startBeat < p.endBeat && p.startBeat < $0.endBeat
            })
        }
    }
}
