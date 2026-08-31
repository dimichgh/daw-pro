import DAWControl
import DAWCore
import Foundation
import Testing

/// m34-h LIVE LOOPING phase 1 — the wire taxonomy for `transport.recordLayer`
/// and `transport.finishLayer`.
///
/// ⭐ **WHY THESE TWO VERBS NEED THEIR OWN SUITE AT ALL:** they are the two
/// commands `ControlTests`' every-command routing loop cannot exercise, and for
/// opposite reasons — that loop is mid-take from `transport.record` onwards, so
/// `recordLayer` correctly refuses there, while `finishLayer` runs against a
/// `FakeEngine` that answers the "closed nothing" protocol default. Excluding
/// them without a replacement would leave two live verbs with no route
/// coverage; this suite is that replacement.
///
/// ⚠️ **THE SPY ENGINE HERE DOES IMPLEMENT THE KEEP-PLAYING CLOSE.** That is
/// deliberate and is exactly what the bare router's engine does not do. It
/// means this suite proves the STORE and the WIRE, and proves nothing about the
/// real engine — `DAWEngineTests/LiveLayerCaptureTests` is what closes that,
/// against `AudioEngine` itself.
@MainActor
@Suite("Transport layer commands (m34-h)")
struct TransportLayerCommandTests {

    /// An engine that can genuinely close a take without stopping — the
    /// capability the protocol default deliberately lacks.
    @MainActor
    private final class LayerSpyEngine: AudioEngineControlling {
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var isRunning = true

        /// Completions for takes that have been STARTED and not yet delivered.
        /// A LIST, not a single slot, because that is the real shape once
        /// layering exists: take N's completion can still be outstanding when
        /// take N+1 starts.
        private var pendingCompletions: [@MainActor (Result<TakeResult, Error>) -> Void] = []
        /// When false, a close returns true but HOLDS the completion, so a test
        /// can choose the instant it lands. The real engine's completion is
        /// always asynchronous (writer queue → main actor); delivering inline is
        /// a convenience for the tests that do not care about the ordering.
        var deliverOnClose = true
        /// Recorded so the tests can assert the store reached the LAYER
        /// primitive and not the ordinary one — the two have opposite
        /// preconditions and only one of them leaves the music running.
        private(set) var layerStarts = 0
        private(set) var ordinaryStarts = 0
        private(set) var keepPlayingCloses = 0
        private(set) var stopRecordingCalls = 0
        private(set) var stopPlaybackCalls = 0
        /// The transport the last layer start was handed — the store's own
        /// playhead read, which is what places the clip.
        private(set) var lastLayerTransport: TransportState?
        /// Flip to make the layer primitive refuse, standing in for the real
        /// engine's "nothing is playing" / "already rolling" refusals.
        var refuseLayerStart: (any Error)?

        func prepare() throws {}
        func shutdown() {}
        func tracksDidChange(_ tracks: [Track]) {}
        func startPlayback(_ transport: TransportState) {}
        func stopPlayback() { stopPlaybackCalls += 1 }
        func seek(_ transport: TransportState) {}
        func setTempo(_ transport: TransportState) {}
        func loopChanged(_ transport: TransportState) {}
        func masterVolumeChanged(_ volume: Double) {}
        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL) async throws -> AudioFileInfo {
            throw ProjectError.engineUnavailable
        }
        var recordPermission: RecordPermission { .granted }
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
            completion(true)
        }
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func setInputDevice(uid: String?) throws {}
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
            throw ProjectError.engineUnavailable
        }

        func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                       completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
            ordinaryStarts += 1
            pendingCompletions.append(completion)
        }

        func startTakeInPlayback(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                                 completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
            if let refuseLayerStart { throw refuseLayerStart }
            layerStarts += 1
            lastLayerTransport = transport
            pendingCompletions.append(completion)
        }

        func stopRecording() {
            stopRecordingCalls += 1
            stopPlaybackCalls += 1  // the real engine stops playback in here too
            deliverOldest()
        }

        func finishTakeKeepingPlayback() -> Bool {
            guard !pendingCompletions.isEmpty else { return false }
            keepPlayingCloses += 1
            if deliverOnClose { deliverOldest() }
            return true
        }

        /// Fires the OLDEST outstanding completion at a moment of the test's
        /// choosing — the only way to exercise a completion that lands after
        /// something else happened to the store.
        func deliverOldest() {
            guard !pendingCompletions.isEmpty else { return }
            let completion = pendingCompletions.removeFirst()
            completion(.success(takeResult()))
        }

        /// Hands back a take carrying one sentinel note, so the store's landing
        /// path (and therefore the clip it creates) is genuinely exercised.
        private func takeResult() -> TakeResult {
            TakeResult(
                audio: nil,
                midi: MIDIRecordingResult(
                    notes: [MIDINote(pitch: 64, velocity: 100, startBeat: 0, lengthBeats: 1)],
                    lengthBeats: 4
                ),
                stopBeats: 4
            )
        }
    }

    /// A router over a store with one armed instrument track and a live spy.
    private func fixture() throws -> (CommandRouter, ProjectStore, LayerSpyEngine) {
        let engine = LayerSpyEngine()
        let store = ProjectStore(projectName: "m34-h layer")
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument)
        _ = try store.setTrackArm(id: track.id, armed: true)
        return (CommandRouter(store: store), store, engine)
    }

    private func send(_ router: CommandRouter, _ command: String,
                      _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await router.handle(ControlRequest(id: command, command: command, params: params))
    }

    // MARK: - Registration

    @Test("both verbs are registered, exactly once, next to transport.record and NOT at the tail")
    func registration() {
        #expect(CommandRouter.allCommands.contains("transport.recordLayer"))
        #expect(CommandRouter.allCommands.contains("transport.finishLayer"))
        #expect(CommandRouter.allCommands.filter { $0 == "transport.recordLayer" }.count == 1)
        #expect(CommandRouter.allCommands.filter { $0 == "transport.finishLayer" }.count == 1)
        // ⚠️ THE PLACEMENT IS PINNED, not incidental. A tail append broke 80
        // assertions across 22 tests at m27 leg D while every filtered run
        // stayed green; these two sit immediately after the verb whose take
        // machinery they share, ~120 entries from the end.
        let recordIndex = try? #require(CommandRouter.allCommands.firstIndex(of: "transport.record"))
        let layerIndex = try? #require(CommandRouter.allCommands.firstIndex(of: "transport.recordLayer"))
        let finishIndex = try? #require(CommandRouter.allCommands.firstIndex(of: "transport.finishLayer"))
        #expect(layerIndex == (recordIndex ?? 0) + 1)
        #expect(finishIndex == (recordIndex ?? 0) + 2)
        // And far from the end, so every end-relative assertion in the tree
        // stays true by construction. MEASURED at 73 entries from the end when
        // this landed (an earlier draft asserted >100 from a comment elsewhere
        // in Commands.swift that describes a DIFFERENT insertion point — the
        // number here is this pair's own, read off the array).
        #expect((CommandRouter.allCommands.count - (finishIndex ?? 0)) > 50)
    }

    // MARK: - The happy path, end to end over the wire

    @Test("⭐ THE ITEM OVER THE WIRE: record, finishLayer keeps playing, then a SECOND layer with no stop")
    func twoLayersWithoutEverStopping() async throws {
        let (router, store, engine) = try fixture()

        // Layer 1 through the ordinary record path (a stopped transport).
        var r = await send(router, "transport.record")
        #expect(r.ok, "\(r.error ?? "nil")")
        #expect(engine.ordinaryStarts == 1)
        #expect(store.transport.isRecording)
        #expect(store.transport.isPlaying)

        // ⭐ CLOSE IT WITHOUT STOPPING. This is the whole item.
        r = await send(router, "transport.finishLayer")
        #expect(r.ok, "\(r.error ?? "nil")")
        #expect(engine.keepPlayingCloses == 1)
        #expect(engine.stopRecordingCalls == 0, "finishLayer must NOT route through stopRecording")
        #expect(engine.stopPlaybackCalls == 0, "finishLayer must NOT stop playback")
        // The response itself carries the proof a caller reads.
        #expect(r.result?["isPlaying"]?.boolValue == true)
        #expect(r.result?["isRecording"]?.boolValue == false)
        #expect(store.transport.isPlaying, "the music must still be running")
        #expect(!store.transport.isRecording)

        // The layer landed as a clip — read it back, do not trust the state.
        let clipsAfterOne = store.tracks.first?.clips.count ?? 0
        #expect(clipsAfterOne == 1, "layer 1 must have landed as a clip")

        // Layer 2, with NO transport.stop and NO transport.play in between.
        r = await send(router, "transport.recordLayer")
        #expect(r.ok, "\(r.error ?? "nil")")
        #expect(engine.layerStarts == 1, "recordLayer must reach the LAYER primitive, not startTake")
        #expect(engine.ordinaryStarts == 1, "recordLayer must NOT reach the ordinary record primitive")
        #expect(store.transport.isRecording)
        #expect(store.transport.isPlaying)

        r = await send(router, "transport.finishLayer")
        #expect(r.ok, "\(r.error ?? "nil")")
        #expect(engine.keepPlayingCloses == 2)
        #expect(store.transport.isPlaying, "still playing after TWO layers")

        // ⭐ BOTH layers landed. A single clip here would mean layer 2's take
        // was dropped against a cleared pending record — the exact race the
        // threaded PendingTake fixes.
        #expect((store.tracks.first?.clips.count ?? 0) == 2,
                "both layers must land — got \(store.tracks.first?.clips.count ?? 0)")
    }

    @Test("each layer is ONE undo step, named Record Take N")
    func eachLayerIsOneUndoStep() async throws {
        // ⚠️ `engine` is BOUND, never `_`. `ProjectStore.engine` is a WEAK
        // reference: discarding the spy here deallocates it mid-test, the store
        // silently sees a nil engine, and every command refuses with
        // engineUnavailable — which reads as "no clips landed", i.e. exactly
        // the failure this test is meant to detect. Measured, not theorised:
        // this test failed with 0 clips until the binding was added.
        let (router, store, engine) = try fixture()
        _ = await send(router, "transport.record")
        _ = await send(router, "transport.finishLayer")
        _ = await send(router, "transport.recordLayer")
        _ = await send(router, "transport.finishLayer")
        #expect((store.tracks.first?.clips.count ?? 0) == 2)

        // A layer that cost two undos would be a bug — the roadmap says so
        // explicitly. One undo must remove exactly one layer.
        _ = try store.undo()
        #expect((store.tracks.first?.clips.count ?? 0) == 1,
                "one undo must remove exactly ONE layer")
        _ = try store.undo()
        #expect((store.tracks.first?.clips.count ?? 0) == 0)
        #expect(engine.keepPlayingCloses == 2)  // keeps the spy alive to here
    }

    // MARK: - Refusals

    @Test("transport.finishLayer refuses when nothing is recording")
    func finishLayerRefusesWhenNotRecording() async throws {
        let (router, _, engine) = try fixture()
        let r = await send(router, "transport.finishLayer")
        #expect(!r.ok)
        #expect(r.error?.contains("not recording") == true, "\(r.error ?? "nil")")
        #expect(engine.keepPlayingCloses == 0)
    }

    @Test("transport.recordLayer refuses a STOPPED transport — it is record()'s mirror, not a relaxation")
    func recordLayerRefusesWhenStopped() async throws {
        let (router, store, engine) = try fixture()
        #expect(!store.transport.isPlaying)
        let r = await send(router, "transport.recordLayer")
        #expect(!r.ok)
        #expect(r.error?.contains("nothing is playing") == true, "\(r.error ?? "nil")")
        #expect(engine.layerStarts == 0)
        // And the refusal left the transport exactly as it found it.
        #expect(!store.transport.isRecording)
        #expect(!store.transport.isPlaying)
    }

    @Test("transport.recordLayer refuses while a layer is already recording")
    func recordLayerRefusesWhileRecording() async throws {
        let (router, _, engine) = try fixture()
        _ = await send(router, "transport.record")
        let r = await send(router, "transport.recordLayer")
        #expect(!r.ok)
        #expect(r.error?.contains("already recording") == true, "\(r.error ?? "nil")")
        #expect(engine.layerStarts == 0)
    }

    @Test("⛔ transport.recordLayer refuses while the LOOP is enabled, and the error TEACHES the difference")
    func recordLayerRefusesUnderALoop() async throws {
        let (router, store, engine) = try fixture()
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 8)
        try store.play()
        let r = await send(router, "transport.recordLayer")
        #expect(!r.ok)
        // ⭐ THE ERROR MUST NAME THE TRAP. "We already have loop recording" is
        // the single most likely wrong reading of this feature: loop-cycle
        // takes record ALTERNATE ATTEMPTS at one part, live looping stacks
        // DIFFERENT parts. Identical gesture, opposite intent.
        #expect(r.error?.contains("loop") == true, "\(r.error ?? "nil")")
        #expect(r.error?.contains("overdub") == true, "\(r.error ?? "nil")")
        #expect(engine.layerStarts == 0)
        #expect(!store.transport.isRecording)
        #expect(store.transport.isPlaying, "a refused layer must not stop the music")
    }

    @Test("⛔ transport.recordLayer refuses with a punch window enabled")
    func recordLayerRefusesWithPunch() async throws {
        let (router, store, engine) = try fixture()
        try store.setPunch(enabled: true, inBeat: 2, outBeat: 6)
        try store.play()
        let r = await send(router, "transport.recordLayer")
        #expect(!r.ok)
        #expect(r.error?.contains("punch") == true, "\(r.error ?? "nil")")
        #expect(engine.layerStarts == 0)
        #expect(store.transport.isPlaying)
    }

    @Test("transport.recordLayer refuses with no armed track")
    func recordLayerRefusesWithNothingArmed() async throws {
        let (router, store, engine) = try fixture()
        let track = try #require(store.tracks.first)
        _ = try store.setTrackArm(id: track.id, armed: false)
        try store.play()
        let r = await send(router, "transport.recordLayer")
        #expect(!r.ok)
        #expect(engine.layerStarts == 0)
    }

    @Test("a FAILED layer start leaves the music playing and winds the recording intent back")
    func failedLayerStartKeepsPlaying() async throws {
        let (router, store, engine) = try fixture()
        try store.play()
        engine.refuseLayerStart = ProjectError.recordingFailed("input device vanished")
        let r = await send(router, "transport.recordLayer")
        #expect(!r.ok)
        // ⭐ THE POINT: a layer that could not start must not take the
        // performance down with it.
        #expect(store.transport.isPlaying, "a failed layer start must NOT stop playback")
        #expect(!store.transport.isRecording)
        #expect(store.lastRecordingError != nil)
    }

    // MARK: - Param hygiene

    @Test("both verbs reject unknown params")
    func unknownParamsRejected() async throws {
        let (router, _, _) = try fixture()
        for verb in ["transport.recordLayer", "transport.finishLayer"] {
            let r = await send(router, verb, ["bogus": .bool(true)])
            #expect(!r.ok, "\(verb) accepted an unknown param")
            #expect(r.error?.contains("bogus") == true, "\(r.error ?? "nil")")
        }
    }

    @Test("⭐ a take still in flight when the PROJECT is replaced lands NOTHING in the new project")
    func takeInFlightAcrossAProjectBoundaryIsDropped() async throws {
        let (router, store, engine) = try fixture()
        engine.deliverOnClose = false
        _ = await send(router, "transport.record")
        // Close the layer — the completion is HELD, exactly as the real
        // engine's is until its writer queue drains.
        _ = await send(router, "transport.finishLayer")
        _ = await send(router, "transport.stop")
        try store.newProject(discardChanges: true)
        // Now the engine's completion arrives, carrying the OUTGOING project's
        // take. Without the session-generation guard it would land clips (and a
        // lastRecordingError) on a project that never recorded anything.
        engine.deliverOldest()
        #expect(store.tracks.allSatisfy { $0.clips.isEmpty },
                "a take from the previous project must not land in the new one")
    }

    @Test("⭐ layer 1's completion still lands AFTER layer 2 has taken the pending slot")
    func layerOneLandsEvenWhenLayerTwoIsAlreadyRolling() async throws {
        // ⚠️ THE RACE THIS PINS IS THE REASON `PendingTake` IS THREADED THROUGH
        // THE COMPLETION. Take completions are asynchronous; with layering,
        // take N+1 is already the store's "current pending" by the time take N
        // lands. Reading the shared slot in `finishTake` would have dropped
        // every layer but the last — and the store would have looked fine.
        let (router, store, engine) = try fixture()
        engine.deliverOnClose = false          // model the real async completion
        _ = await send(router, "transport.record")
        var r = await send(router, "transport.finishLayer")
        #expect(r.ok, "\(r.error ?? "nil")")
        #expect((store.tracks.first?.clips.count ?? 0) == 0, "layer 1 has not landed yet")
        // Layer 2 starts and takes over the shared pending slot.
        r = await send(router, "transport.recordLayer")
        #expect(r.ok, "\(r.error ?? "nil")")
        #expect(store.transport.isRecording)
        // Layer 1's completion arrives LAST.
        engine.deliverOldest()
        #expect((store.tracks.first?.clips.count ?? 0) == 1,
                "layer 1 must still land after layer 2 claimed the pending slot")
    }

    @Test("the layer start carries the LIVE playhead, which is what places the clip")
    func layerStartCarriesTheLivePlayhead() async throws {
        let (router, store, engine) = try fixture()
        _ = await send(router, "transport.record")
        _ = await send(router, "transport.finishLayer")
        try store.seek(toBeats: 12.5)
        let r = await send(router, "transport.recordLayer")
        #expect(r.ok, "\(r.error ?? "nil")")
        // The engine translates this onto the running anchor; a zero here would
        // land every layer at the top of the song.
        #expect(engine.lastLayerTransport?.positionBeats == 12.5)
    }
}
