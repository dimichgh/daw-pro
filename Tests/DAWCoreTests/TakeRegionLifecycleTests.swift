import Foundation
import Testing
@testable import DAWCore

/// m34-a-2 — **THE PROVISIONAL REGION'S LIFETIME, THROUGH THE STORE.**
///
/// `TakeRegionPreviewTests` pins the RULE (what should be drawn for a given
/// state). This suite pins the STATE MACHINE around it: who recomputes
/// `liveTakeRegion`, and — the part that is easy to get wrong — whether it is
/// recomputed on the take endings **the user never asked for**.
///
/// ⭐⭐ **THE FEATURE IS DRIVEN BY A ~30 Hz TRANSPORT TICK, AND THAT IS EXACTLY
/// WHY THE ENDINGS NEED THEIR OWN PINS.** A tick-driven refresh is invisibly
/// correct while the transport is moving and invisibly WRONG the moment it
/// stops: `AudioEngine.abortRecordingNoInput` (the dead-input watchdog) and
/// `endTakeOnFatalConfigurationChange` (device unplug) both end a take and kill
/// playback ENGINE-SIDE, so no further tick ever arrives. Refreshing only at the
/// user-initiated edges (`stop()`, `finishLayer()`) would leave a region painted
/// over a lane that is never getting a clip — the ghost this item's whole rule
/// exists to prevent, restored on the one path nobody watches.
///
/// Both of those paths reach the store the same way every take does: through the
/// `startTake` completion, i.e. `ProjectStore.finishTake`. `FakeTakeEngine`
/// fires that completion directly, which is what makes the ending testable
/// headlessly at all.
@MainActor
@Suite("Provisional take region — lifetime (m34-a-2)")
struct TakeRegionLifecycleTests {

    /// A store with one armed instrument track and a take rolling, plus an
    /// engine already reporting captured notes — i.e. the exact moment the
    /// region is on screen.
    private func rollingTakeWithARegion() throws -> (ProjectStore, FakeTakeEngine) {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let inst = store.addTrack(name: "Keys", kind: .instrument)
        try store.setTrackArm(id: inst.id, armed: true)
        try store.record()
        engine.liveExtent = LiveTakeExtent(anchorBeat: 0, latestEventBeat: 1.5, noteCount: 3)
        store.refreshLiveTakeRegion()
        return (store, engine)
    }

    @Test("⭐ the store publishes a region during a take and grows it with the playhead")
    func theStorePublishesAGrowingRegion() throws {
        let (store, engine) = try rollingTakeWithARegion()
        let first = try #require(store.liveTakeRegion,
                                 "no region during a take — every 'it is gone' assertion below would be vacuous")
        #expect(first.noteCount == 3)
        #expect(first.trackIDs == [store.tracks[0].id])

        // The take keeps rolling and more notes arrive. (`transport` has no
        // public setter, so the growth is driven from the CAPTURE side — which
        // is the half that matters here anyway: the region can never be shorter
        // than the notes already inside it.)
        engine.liveExtent = LiveTakeExtent(anchorBeat: 0, latestEventBeat: 6.0, noteCount: 9)
        store.refreshLiveTakeRegion()
        let grown = try #require(store.liveTakeRegion)
        #expect(grown.lengthBeats > first.lengthBeats, "the region did not grow with the take")
        #expect(grown.lengthBeats == 6)
        #expect(grown.noteCount == 9)
    }

    // MARK: - The endings the user never asked for

    @Test("""
          ⭐⭐ AN ENGINE-INITIATED ABORT LEAVES NO GHOST — no stop(), no tick, \
          nothing but the failure completion
          """)
    func anEngineInitiatedAbortLeavesNoGhostRegion() throws {
        let (store, engine) = try rollingTakeWithARegion()
        #expect(store.liveTakeRegion != nil, "positive control: the region must be on screen before the abort")

        // EXACTLY what `AudioEngine.abortRecordingNoInput` does: the capture
        // session is dropped (so there is no extent to read any more) and the
        // take's completion is failed. Deliberately NOTHING else — no `stop()`,
        // no seek, no position change. If the region only cleared on a
        // transport tick, it would still be here.
        engine.liveExtent = nil
        engine.finishTake(.failure(EngineErrorStub.noInput))

        #expect(store.liveTakeRegion == nil, """
            A take aborted BY THE ENGINE left its provisional region behind. \
            abortRecordingNoInput and endTakeOnFatalConfigurationChange kill playback \
            engine-side, so no transport tick follows them: the region would stay \
            painted over a lane that never receives a clip until the user's next \
            transport action.
            """)
        #expect(store.tracks[0].clips.isEmpty, "an aborted take must land nothing")
        #expect(store.lastRecordingError != nil, "the failure must still be reported to the user")
    }

    @Test("a take that ends by LANDING clears the region on the same completion")
    func aLandedTakeClearsTheRegion() throws {
        let (store, engine) = try rollingTakeWithARegion()
        #expect(store.liveTakeRegion != nil, "positive control")

        store.stop()
        engine.liveExtent = nil
        engine.finishTake(.success(TakeResult(
            audio: nil,
            midi: MIDIRecordingResult(
                notes: [MIDINote(pitch: 60, velocity: 96, startBeat: 0, lengthBeats: 1)],
                lengthBeats: 4))))

        #expect(store.liveTakeRegion == nil, "the real clip landed and the placeholder must be gone")
        #expect(store.tracks[0].clips.count == 1, "positive control: the take did land")
    }

    @Test("⛔ a take that outlives its PROJECT lands nothing and draws nothing")
    func aLateCompletionFromThePreviousSessionDrawsNothing() throws {
        let (store, engine) = try rollingTakeWithARegion()
        #expect(store.liveTakeRegion != nil, "positive control: a region is on screen while the take rolls")

        // ⚠️ A project cannot be swapped WHILE recording — `newProject` throws
        // `transportBusy`, measured. The reachable sequence is: stop (which
        // retires the region and leaves the writer finalizing asynchronously),
        // swap, and only THEN the completion arrives — against a session that
        // no longer exists.
        store.stop()
        engine.liveExtent = nil
        #expect(store.liveTakeRegion == nil, "stop() must retire the region immediately, not one tick later")
        try store.newProject(discardChanges: true)

        engine.finishTake(.success(TakeResult(
            audio: nil,
            midi: MIDIRecordingResult(
                notes: [MIDINote(pitch: 62, velocity: 96, startBeat: 0, lengthBeats: 1)],
                lengthBeats: 4))))
        #expect(store.liveTakeRegion == nil, "a late completion from the previous session drew a region")
        #expect(store.tracks.allSatisfy { $0.clips.isEmpty },
                "a take from the previous session landed a clip in the new one")
    }
}

/// A minimal failure for the abort path — the store only reads its message.
private enum EngineErrorStub: LocalizedError {
    case noInput
    var errorDescription: String? {
        "no audio arrived from input device 'stub' — device may be unavailable; take aborted"
    }
}
