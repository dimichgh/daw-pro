import Foundation
import Testing
@testable import DAWCore

/// m34-a-2 — **THE RULE FOR THE GROWING TAKE REGION**, headless.
///
/// The user's report: *"when I record playing using keys on instrument track it
/// would be good to automatically create and auto extend [the region] as user
/// plays."* m34-a-1 made the view FOLLOW during a take; until this item there
/// was still nothing on the timeline to look at, because
/// `MIDICaptureSession.finish(atBeat:)` is what builds the clip and its length
/// does not exist until the stop beat is known.
///
/// This suite pins the DECISION, which is why it can be headless at all: the
/// view is handed a value and renders it, and every "should anything be drawn"
/// question is answered here.
///
/// ⭐ **THE GHOST TEST IS THE POINT OF THE WHOLE SUITE** (`aTakeThatCaptures…`).
/// `ProjectStore.finishTake` DISCARDS a take with zero notes. So a region drawn
/// from record start would promise a clip on every take and, on a silent one,
/// vanish at stop having created nothing.
@Suite("Growing take region — the rule (m34-a-2)")
struct TakeRegionPreviewTests {

    private static let trackA = UUID()
    private static let trackB = UUID()

    private static func pending(instrument: [UUID] = [trackA],
                                audio: [UUID] = [],
                                startBeat: Double = 8,
                                loop: Bool = false) -> PendingTakeInfo {
        PendingTakeInfo(instrumentTrackIDs: instrument, audioTrackIDs: audio,
                        startBeat: startBeat, takeNumber: 3, isLoopTake: loop)
    }

    private static func extent(anchor: Double = 8, latest: Double? = 9.5,
                               notes: Int = 2) -> LiveTakeExtent {
        LiveTakeExtent(anchorBeat: anchor, latestEventBeat: latest, noteCount: notes)
    }

    // MARK: - Decision 1: nothing is drawn until a note has been captured

    @Test("⭐⭐ a take that captures NOTHING draws no region — the ghost this feature must not leave")
    func aTakeThatCapturesNothingDrawsNothing() {
        // POSITIVE CONTROL FIRST. Everything about this fixture except the note
        // count produces a region, so the nil below is attributable.
        let drawn = TakeRegionPreview.region(pending: Self.pending(),
                                             extent: Self.extent(notes: 1),
                                             playheadBeat: 10, isRecording: true)
        #expect(drawn != nil, "fixture cannot produce a region at all — every nil in this suite would be vacuous")

        let silent = TakeRegionPreview.region(
            pending: Self.pending(),
            extent: Self.extent(latest: nil, notes: 0),
            playheadBeat: 10, isRecording: true)
        #expect(silent == nil, """
            A take with zero notes drew a region. ProjectStore.finishTake discards \
            that take ("empty take discarded — no MIDI notes received"), so the \
            region would vanish at stop with no clip behind it.
            """)
    }

    @Test("a HELD note counts — an open note lands when finish clamps it")
    func aHeldNoteAlreadyCounts() {
        // `MIDICaptureSession.liveExtent` counts closed + open notes for exactly
        // this case: one key still down IS a note that will land.
        let region = TakeRegionPreview.region(pending: Self.pending(),
                                              extent: Self.extent(latest: 8.2, notes: 1),
                                              playheadBeat: 9, isRecording: true)
        #expect(region?.noteCount == 1)
    }

    // MARK: - Decision 2: the length is `finish`'s own formula

    @Test("⭐ the region's length is MIDICaptureSession.finish's formula, so the swap at stop is exact")
    func lengthMatchesTheFinishFormula() {
        // `finish` computes `max(1, (stopBeat − anchorBeats).rounded(.up))`.
        // Re-stated here as an INDEPENDENT expression rather than by calling
        // the same helper, so this test can actually disagree with it.
        for (anchor, stop) in [(0.0, 0.1), (0.0, 4.0), (8.0, 13.25), (8.0, 8.0), (2.5, 7.5)] {
            let expected = max(1, (stop - anchor).rounded(.up))
            #expect(TakeRegionPreview.length(anchorBeat: anchor, endBeat: stop) == expected,
                    "length(\(anchor) → \(stop)) disagrees with finish's formula")
        }
    }

    @Test("the region GROWS as the playhead advances, in whole beats")
    func theRegionGrowsWithThePlayhead() {
        let lengths = [8.4, 9.0, 9.6, 12.0, 12.1].map { playhead in
            TakeRegionPreview.region(pending: Self.pending(),
                                     extent: Self.extent(latest: 8.1),
                                     playheadBeat: playhead, isRecording: true)?.lengthBeats
        }
        #expect(lengths == [1, 1, 2, 4, 5], "got \(lengths)")
        // MONOTONIC: a region that could shrink mid-take would read as a glitch.
        #expect(zip(lengths, lengths.dropFirst()).allSatisfy { ($0 ?? 0) <= ($1 ?? 0) })
    }

    @Test("the region lands where the CLIP will land — the pending snapshot's start beat")
    func theRegionStartsWhereTheClipWill() {
        let region = TakeRegionPreview.region(pending: Self.pending(startBeat: 16),
                                              extent: Self.extent(anchor: 16, latest: 17),
                                              playheadBeat: 18, isRecording: true)
        #expect(region?.startBeat == 16)
    }

    // MARK: - Decision 3: the end is max(playhead, latest event)

    @Test("⭐ a note captured PAST the display playhead still fits inside the region")
    func aNotePastTheDisplayPlayheadStillFits() {
        // The playhead is a ~30 Hz display value; the capture clock is the audio
        // anchor. Taking only the playhead would draw a region shorter than the
        // notes inside it.
        let region = TakeRegionPreview.region(pending: Self.pending(),
                                              extent: Self.extent(anchor: 8, latest: 12.7),
                                              playheadBeat: 9.0, isRecording: true)
        #expect(region?.lengthBeats == 5, "expected the LATEST EVENT to set the end, got \(String(describing: region?.lengthBeats))")
    }

    // MARK: - Decision 4: loop takes draw nothing (v1)

    @Test("⛔ a LOOP-CYCLE take draws no region — a modular playhead against a linear anchor would lie")
    func loopTakesDrawNothing() {
        let linear = TakeRegionPreview.region(pending: Self.pending(loop: false),
                                              extent: Self.extent(),
                                              playheadBeat: 10, isRecording: true)
        #expect(linear != nil, "positive control: the same fixture without the loop MUST draw")

        let looped = TakeRegionPreview.region(pending: Self.pending(loop: true),
                                              extent: Self.extent(),
                                              playheadBeat: 10, isRecording: true)
        #expect(looped == nil, """
            A loop-cycle take drew a region. transport.positionBeats is MODULAR under \
            a loop while every capture clock is linear, and finishTake lands per-cycle \
            take LANES, not one growing clip.
            """)
    }

    // MARK: - Lifetime

    @Test("⛔ the lifetime is isRecording — pendingTake OUTLIVES the stop and is not a lifetime")
    func theLifetimeIsIsRecordingNotPendingTake() {
        let rolling = TakeRegionPreview.region(pending: Self.pending(), extent: Self.extent(),
                                               playheadBeat: 10, isRecording: true)
        #expect(rolling != nil, "positive control")

        // Exactly the state after a stop: the snapshot is still there (the writer
        // finalizes asynchronously) but the take is over.
        let stopped = TakeRegionPreview.region(pending: Self.pending(), extent: Self.extent(),
                                               playheadBeat: 10, isRecording: false)
        #expect(stopped == nil, "the region outlived the take — a stopped transport must draw nothing")
    }

    @Test("no extent (an engine that cannot report one) draws nothing rather than assuming")
    func noExtentDrawsNothing() {
        #expect(TakeRegionPreview.region(pending: Self.pending(), extent: nil,
                                         playheadBeat: 10, isRecording: true) == nil)
    }

    @Test("no take snapshot draws nothing")
    func noPendingDrawsNothing() {
        #expect(TakeRegionPreview.region(pending: nil, extent: Self.extent(),
                                         playheadBeat: 10, isRecording: true) == nil)
    }

    @Test("an AUDIO-only take draws nothing — v1 previews the MIDI side")
    func audioOnlyTakesDrawNothing() {
        let region = TakeRegionPreview.region(
            pending: Self.pending(instrument: [], audio: [Self.trackB]),
            extent: Self.extent(), playheadBeat: 10, isRecording: true)
        #expect(region == nil)
    }

    // MARK: - Destinations

    @Test("⭐ every instrument DESTINATION gets a block — a multi-armed take lands one clip per track")
    func everyDestinationIsPreviewed() {
        let region = TakeRegionPreview.region(
            pending: Self.pending(instrument: [Self.trackA, Self.trackB]),
            extent: Self.extent(), playheadBeat: 10, isRecording: true)
        #expect(region?.trackIDs == [Self.trackA, Self.trackB])
    }
}
