import Testing
import Foundation
import DAWCore
@testable import DAWAppKit

/// m25-l-2 — CROSS-TRACK CLIP DRAG, the vertical axis of the gesture.
///
/// The user's report (m25-l): *"I should be able to drag clips to other tracks,
/// currently I can only drag it on the same track."*
///
/// ⚠️ **WHAT THIS SUITE CANNOT SEE, STATED UP FRONT.** `DAWApp` has no test
/// target, so nothing here executes a pointer, a `DragGesture`, or a pixel. It
/// pins the two DECISIONS the gesture delegates — *which row is the pointer
/// over* and *what will the drop actually achieve* — and nothing about whether
/// `TimelineLanesView` asks them. `ArrangeVerticalDragSiteTests` covers the
/// asking; the drag ITSELF has no proof surface in this tree, exactly as
/// m23-aj-3 recorded for the keyboard layer. **A green run here must not be read
/// as "cross-track drag works".**
///
/// ⚠️ The companion cadence guarantee lives in `ArrangeBodyDragTests`: the
/// vertical request is stored, not applied, until `commit()`. That is the m25-k
/// defect's blast radius being kept closed on a second axis.
@Suite("Cross-track drag — the vertical axis (m25-l-2)")
struct ArrangeVerticalDragTests {

    // MARK: - Fixtures

    private func midiClip(_ name: String, start: Double = 0, length: Double = 4) -> Clip {
        Clip(name: name, startBeat: start, lengthBeats: length, notes: [])
    }

    private func audioClip(_ name: String, start: Double = 0, length: Double = 4) -> Clip {
        Clip(name: name, startBeat: start, lengthBeats: length,
             audioFileURL: URL(fileURLWithPath: "/tmp/\(name).wav"))
    }

    private func midiTrack(_ name: String, clips: [Clip] = []) -> Track {
        Track(name: name, kind: .instrument, clips: clips)
    }

    private func audioTrack(_ name: String, clips: [Clip] = []) -> Track {
        Track(name: name, kind: .audio, clips: clips)
    }

    private func busTrack(_ name: String) -> Track {
        Track(name: name, kind: .bus)
    }

    /// A UNIFORM ladder: `TimelineLanesView`'s real geometry with nothing
    /// expanded — `laneHeight` 34 + `laneSpacing` 6 = a 40 pt band.
    private func uniformLadder(_ count: Int) -> (tops: [Double], bottom: Double) {
        let tops = (0..<count).map { Double($0) * 40 }
        return (tops, Double(count) * 40)
    }

    // MARK: - Pointer → row

    @Test("a pointer inside a band resolves to that band's row")
    func pointerInsideABandResolvesToThatRow() {
        let ladder = uniformLadder(4)
        #expect(ArrangeVerticalDrag.row(atContentY: 5, bandTops: ladder.tops,
                                        stackBottom: ladder.bottom) == 0)
        #expect(ArrangeVerticalDrag.row(atContentY: 55, bandTops: ladder.tops,
                                        stackBottom: ladder.bottom) == 1)
        #expect(ArrangeVerticalDrag.row(atContentY: 155, bandTops: ladder.tops,
                                        stackBottom: ladder.bottom) == 3)
    }

    /// Bands are HALF-OPEN — `[top, nextTop)` — which is the contract
    /// `TimelineLanesView` already used for file drops. A closed upper bound
    /// would make the single pixel row on every boundary ambiguous.
    @Test("a band's own top belongs to it; the next top belongs to the next row")
    func bandBoundariesAreHalfOpen() {
        let ladder = uniformLadder(3)
        #expect(ArrangeVerticalDrag.row(atContentY: 0, bandTops: ladder.tops,
                                        stackBottom: ladder.bottom) == 0)
        #expect(ArrangeVerticalDrag.row(atContentY: 39.999, bandTops: ladder.tops,
                                        stackBottom: ladder.bottom) == 0)
        #expect(ArrangeVerticalDrag.row(atContentY: 40, bandTops: ladder.tops,
                                        stackBottom: ladder.bottom) == 1)
    }

    /// ⚠️⚠️ THE `?? 0` TRAP. The ruler sits directly above lane 0, so if "off the
    /// stack" collapsed to row 0 the drag would fling clips to the TOP track
    /// every time the pointer drifted up out of the lanes.
    @Test("above the stack is nil — never row 0")
    func aboveTheStackIsNilNeverRowZero() {
        // A `.full` composition insets the lanes below an 80 pt ruler.
        let tops = [80.0, 120.0, 160.0]
        #expect(ArrangeVerticalDrag.row(atContentY: 79, bandTops: tops,
                                        stackBottom: 200) == nil)
        #expect(ArrangeVerticalDrag.row(atContentY: 0, bandTops: tops,
                                        stackBottom: 200) == nil)
        #expect(ArrangeVerticalDrag.row(atContentY: 80, bandTops: tops,
                                        stackBottom: 200) == 0)
    }

    /// ⚠️ Do NOT inherit the file-drop reading of this same geometry, where
    /// below-the-last-lane means "make a new track". Moving a clip that already
    /// lives somewhere has no such branch.
    @Test("below the last band is nil — never the last row")
    func belowTheStackIsNilNeverTheLastRow() {
        let ladder = uniformLadder(3)
        #expect(ArrangeVerticalDrag.row(atContentY: 119.999, bandTops: ladder.tops,
                                        stackBottom: ladder.bottom) == 2)
        #expect(ArrangeVerticalDrag.row(atContentY: 120, bandTops: ladder.tops,
                                        stackBottom: ladder.bottom) == nil)
        #expect(ArrangeVerticalDrag.row(atContentY: 5_000, bandTops: ladder.tops,
                                        stackBottom: ladder.bottom) == nil)
    }

    /// THE NON-UNIFORM LADDER — the reason this resolver takes measured tops
    /// instead of a row height. Track 1 here has expanded take lanes, so
    /// `y / rowHeight` would land two rows off by the bottom of the stack.
    @Test("a taller expanded lane does not shift the rows below it")
    func aTallerLaneDoesNotShiftTheRowsBelowIt() {
        // Track 0: 40 pt.  Track 1: 140 pt (expanded).  Track 2: 40 pt.
        let tops = [0.0, 40.0, 180.0]
        let bottom = 220.0
        #expect(ArrangeVerticalDrag.row(atContentY: 20, bandTops: tops, stackBottom: bottom) == 0)
        #expect(ArrangeVerticalDrag.row(atContentY: 100, bandTops: tops, stackBottom: bottom) == 1)
        #expect(ArrangeVerticalDrag.row(atContentY: 179, bandTops: tops, stackBottom: bottom) == 1)
        #expect(ArrangeVerticalDrag.row(atContentY: 190, bandTops: tops, stackBottom: bottom) == 2)
        // CONTROL: the naive uniform reading would say row 4 for y=190, which is
        // not even a row. The measurement above is what makes that impossible.
        #expect(Int(190.0 / 40.0) == 4)
    }

    @Test("an empty project resolves no row at all")
    func anEmptyProjectResolvesNoRow() {
        #expect(ArrangeVerticalDrag.row(atContentY: 0, bandTops: [], stackBottom: 0) == nil)
    }

    // MARK: - Row → requested delta

    @Test("a pointer on the anchor's own row requests no vertical change")
    func pointerOnTheAnchorsOwnRowRequestsNothing() {
        let ladder = uniformLadder(4)
        #expect(ArrangeVerticalDrag.requestedDelta(
            fromRow: 2, pointerContentY: 90, bandTops: ladder.tops,
            stackBottom: ladder.bottom) == 0)
    }

    @Test("the delta is the ABSOLUTE row under the pointer minus the anchor's row")
    func theDeltaIsAbsoluteRowMinusAnchorRow() {
        let ladder = uniformLadder(5)
        #expect(ArrangeVerticalDrag.requestedDelta(
            fromRow: 1, pointerContentY: 150, bandTops: ladder.tops,
            stackBottom: ladder.bottom) == 2)
        #expect(ArrangeVerticalDrag.requestedDelta(
            fromRow: 3, pointerContentY: 10, bandTops: ladder.tops,
            stackBottom: ladder.bottom) == -3)
    }

    /// The composition of the two nil rules above with the anchor's row. Reading
    /// the nil as row 0 would make this `-3`, i.e. a jump to the top track.
    @Test("a pointer off the lane stack requests ZERO, not a jump to row 0")
    func offTheStackRequestsZeroNotAJumpToRowZero() {
        let ladder = uniformLadder(5)
        #expect(ArrangeVerticalDrag.requestedDelta(
            fromRow: 3, pointerContentY: -50, bandTops: ladder.tops,
            stackBottom: ladder.bottom) == 0)
        #expect(ArrangeVerticalDrag.requestedDelta(
            fromRow: 3, pointerContentY: 9_999, bandTops: ladder.tops,
            stackBottom: ladder.bottom) == 0)
    }

    // MARK: - Requested → achieved: the plain cases

    @Test("no request, no movement")
    func noRequestNoMovement() {
        let clip = midiClip("a")
        let tracks = [midiTrack("A", clips: [clip]), midiTrack("B")]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 0, movingClipIDs: [clip.id], tracks: tracks) == 0)
    }

    @Test("one clip onto a compatible lane below achieves the request")
    func oneClipOntoACompatibleLaneAchievesTheRequest() {
        let clip = midiClip("a")
        let tracks = [midiTrack("A", clips: [clip]), midiTrack("B"), midiTrack("C")]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 2, movingClipIDs: [clip.id], tracks: tracks) == 2)
    }

    @Test("upward moves are achieved the same way")
    func upwardMovesAreAchievedTheSameWay() {
        let clip = midiClip("a")
        let tracks = [midiTrack("A"), midiTrack("B"), midiTrack("C", clips: [clip])]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: -2, movingClipIDs: [clip.id], tracks: tracks) == -2)
    }

    @Test("ids that name no live clip move nothing")
    func idsThatNameNoLiveClipMoveNothing() {
        let tracks = [midiTrack("A"), midiTrack("B")]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 1, movingClipIDs: [UUID()], tracks: tracks) == 0)
    }

    @Test("an empty selection and an empty project both move nothing")
    func emptySelectionAndEmptyProjectMoveNothing() {
        let clip = midiClip("a")
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 1, movingClipIDs: [], tracks: [midiTrack("A", clips: [clip])]) == 0)
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 1, movingClipIDs: [clip.id], tracks: []) == 0)
    }

    // MARK: - Requested → achieved: the clamp

    @Test("a clip on the last track cannot be dragged past the end")
    func aClipOnTheLastTrackCannotBeDraggedPastTheEnd() {
        let clip = midiClip("a")
        let tracks = [midiTrack("A"), midiTrack("B", clips: [clip])]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 1, movingClipIDs: [clip.id], tracks: tracks) == 0)
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 9, movingClipIDs: [clip.id], tracks: tracks) == 0)
    }

    /// THE WHOLE-GROUP CLAMP, which is the shape the store mandates and a
    /// per-clip clamp would break. The group spans rows 0–1 of a 3-track
    /// project, so the most it can move is +1 — NOT "clip A to row 2 and clip B
    /// pinned to row 2 as well", which is the fold a per-clip
    /// `min(max(...))` would produce.
    @Test("a multi-track group clamps as ONE unit and keeps its vertical shape")
    func aMultiTrackGroupClampsAsOneUnit() {
        let top = midiClip("top")
        let bottom = midiClip("bottom")
        let tracks = [midiTrack("A", clips: [top]),
                      midiTrack("B", clips: [bottom]),
                      midiTrack("C")]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 5, movingClipIDs: [top.id, bottom.id], tracks: tracks) == 1)
        // CONTROL — the SAME request with only the TOP clip moving has more room,
        // which is what proves the reduction above came from the GROUP's extent
        // and not from a per-clip rule that happens to agree.
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 5, movingClipIDs: [top.id], tracks: tracks) == 2)
    }

    @Test("the top of the list clamps symmetrically")
    func theTopOfTheListClampsSymmetrically() {
        let clip = midiClip("a")
        let tracks = [midiTrack("A"), midiTrack("B", clips: [clip]), midiTrack("C")]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: -1, movingClipIDs: [clip.id], tracks: tracks) == -1)
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: -7, movingClipIDs: [clip.id], tracks: tracks) == -1)
    }

    /// ⭐ THE PHASE-ORDER PROOF — clamp FIRST, kind-check the CLAMPED landing
    /// SECOND, mirroring `ProjectStore.moveClips(ids:landing:byBeats:)`.
    ///
    /// The request is +5 into a 3-track project, so row 5 does not exist. If the
    /// kind check ran against the RAW request it could only fail (or crash), and
    /// this would return 0. It returns 2 because the clamp resolved a REAL row
    /// first and the check then asked about that row.
    @Test("the clamp runs BEFORE the kind check, never after")
    func theClampRunsBeforeTheKindCheck() {
        let clip = midiClip("a")
        let tracks = [midiTrack("A", clips: [clip]), audioTrack("B"), midiTrack("C")]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 5, movingClipIDs: [clip.id], tracks: tracks) == 2)
    }

    // MARK: - Requested → achieved: the compatibility back-off

    /// ⭐ THE REASON THIS BACKS OFF INSTEAD OF LETTING THE STORE REFUSE. The
    /// store refuses the WHOLE call — and `byBeats` rides in that same call — so
    /// a MIDI clip whose pointer strays over an audio lane would lose its
    /// perfectly legal HORIZONTAL move too. Declining the illegal half is
    /// strictly less destructive than discarding both.
    @Test("a MIDI clip declines an audio lane rather than refusing the whole drag")
    func aMIDIClipDeclinesAnAudioLane() {
        let clip = midiClip("a")
        let tracks = [midiTrack("A", clips: [clip]), audioTrack("B")]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 1, movingClipIDs: [clip.id], tracks: tracks) == 0)
    }

    @Test("an audio clip declines an instrument lane symmetrically")
    func anAudioClipDeclinesAnInstrumentLane() {
        let clip = audioClip("a")
        let tracks = [audioTrack("A", clips: [clip]), midiTrack("B")]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 1, movingClipIDs: [clip.id], tracks: tracks) == 0)
    }

    /// A bus occupies a ROW — the arrange draws one — and holds no clips of
    /// either kind. It is therefore a lane the drag can pass over and not land
    /// on, which is the visible consequence of the no-skip axis rule.
    @Test("a bus row is a real row that nothing can land on")
    func aBusRowIsARealRowNothingCanLandOn() {
        let clip = midiClip("a")
        let tracks = [midiTrack("A", clips: [clip]), busTrack("Reverb"), midiTrack("C")]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 1, movingClipIDs: [clip.id], tracks: tracks) == 0)
        // But the row BEYOND it is reachable — the bus is not a wall, it is a row.
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 2, movingClipIDs: [clip.id], tracks: tracks) == 2)
    }

    /// ⚠️ **IT NEVER SEARCHES.** +2 lands on an audio lane, so the whole request
    /// backs off to 0 — it does NOT quietly settle for +1. A drag that landed
    /// somewhere other than where the pointer was would be a worse lie than
    /// declining, and searching is what `clampedTrackDelta`'s "pure RANGE clamp"
    /// rule forbids one layer down.
    @Test("a blocked landing backs off to ZERO and never hunts for a nearer one")
    func aBlockedLandingNeverHuntsForANearerOne() {
        let clip = midiClip("a")
        let tracks = [midiTrack("A", clips: [clip]), midiTrack("B"), audioTrack("C")]
        // CONTROL: +1 on its own is perfectly legal, so the 0 below is a refusal
        // of +2 rather than a lane that was never reachable.
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 1, movingClipIDs: [clip.id], tracks: tracks) == 1)
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 2, movingClipIDs: [clip.id], tracks: tracks) == 0)
    }

    /// ALL-OR-NOTHING, matching the store: one mover that cannot land declines
    /// the whole group. Moving "the ones that can" would silently break the
    /// selection's vertical shape — the same defect the per-clip clamp has.
    @Test("one blocked mover declines the whole group")
    func oneBlockedMoverDeclinesTheWholeGroup() {
        let ok = midiClip("ok")
        let blocked = midiClip("blocked")
        let tracks = [midiTrack("A", clips: [ok]),
                      midiTrack("B", clips: [blocked]),
                      midiTrack("C"),
                      audioTrack("D")]
        // CONTROL: `ok` alone would move happily onto track C.
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 2, movingClipIDs: [ok.id], tracks: tracks) == 2)
        // Together, `blocked` would land on the AUDIO track D — so neither moves.
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 2, movingClipIDs: [ok.id, blocked.id], tracks: tracks) == 0)
    }

    @Test("two clips on the SAME track travel together with no extra clamping")
    func twoClipsOnTheSameTrackTravelTogether() {
        let a = midiClip("a", start: 0)
        let b = midiClip("b", start: 8)
        let tracks = [midiTrack("A", clips: [a, b]), midiTrack("B"), midiTrack("C")]
        #expect(ArrangeVerticalDrag.effectiveDelta(
            requested: 2, movingClipIDs: [a.id, b.id], tracks: tracks) == 2)
    }

    // MARK: - The ghost's vertical offset

    @Test("the ghost offsets only the clips that are moving")
    func theGhostOffsetsOnlyTheMovers() {
        let mover = UUID()
        let bystander = UUID()
        let preview = ArrangeDragPreview(anchorClipID: mover, movingClipIDs: [mover],
                                         deltaBeats: 4, deltaTracks: 2)
        #expect(preview.offsetTracks(for: mover) == 2)
        #expect(preview.offsetTracks(for: bystander) == 0)
        #expect(preview.offsetBeats(for: bystander) == 0)
    }

    /// The default keeps every pre-m25-l-2 construction site — and the whole
    /// same-track drag path — byte-identical.
    @Test("a preview built without a vertical term has none")
    func aPreviewWithoutAVerticalTermHasNone() {
        let id = UUID()
        let preview = ArrangeDragPreview(anchorClipID: id, movingClipIDs: [id], deltaBeats: 3)
        #expect(preview.deltaTracks == 0)
        #expect(preview.offsetTracks(for: id) == 0)
    }
}
