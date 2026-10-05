import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Wire-level gate for `note.play` (m23-ct) through `CommandRouter.handle`.
///
/// ⭐ The pin the whole verb exists for is `playSucceedsWhileRecording`: every
/// other "sounds now" verb on this surface (`note.audition`, `pad.previewEffort`)
/// is REFUSED mid-take, and this one must not be — it is the only path by which
/// a user with no hardware MIDI controller can record a performance at all.
@MainActor
@Suite("note.play wire command (m23-ct)")
struct LivePlayCommandTests {
    /// Engine spy: records every live-play intent, so a rejection can be proven
    /// to have sounded NOTHING and a capture verdict can be read off the wire.
    @MainActor
    private final class LivePlaySpyEngine: AudioEngineControlling {
        var isRunning = true
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        private(set) var livePlayCalls: [(trackID: UUID, pitches: [UInt8], velocity: UInt8,
                                          captureIntoTake: Bool)] = []
        private(set) var auditionCalls: [(trackID: UUID, pitches: [UInt8], velocity: UInt8)] = []
        var outcomeStub: AuditionOutcome = .sounded

        func setLivePlayPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8,
                                captureIntoTake: Bool) -> LivePlayOutcome {
            livePlayCalls.append((trackID, pitches, velocity, captureIntoTake))
            let outcome = pitches.isEmpty ? .sounded : outcomeStub
            let delivered = outcome != .noRenderer && outcome != .unsupported
            return LivePlayOutcome(audition: outcome, capturedEdges: pitches.count,
                                   recording: captureIntoTake && delivered)
        }

        func setAuditionPitches(trackID: UUID, pitches: [UInt8],
                                velocity: UInt8) -> AuditionOutcome {
            auditionCalls.append((trackID, pitches, velocity))
            return pitches.isEmpty ? .sounded : outcomeStub
        }

        func prepare() throws { isRunning = true }
        func shutdown() { isRunning = false }
        func tracksDidChange(_ tracks: [Track]) {}
        func startPlayback(_ transport: TransportState) {}
        func stopPlayback() {}
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
                       completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {}
        func stopRecording() {}
    }

    private func makeRouter() -> (CommandRouter, ProjectStore, LivePlaySpyEngine, UUID, UUID) {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let instrument = store.addTrack(name: "Keys", kind: .instrument).id
        let audio = store.addTrack(name: "Vox", kind: .audio).id
        return (CommandRouter(store: store), store, engine, instrument, audio)
    }

    private func play(_ router: CommandRouter, _ params: [String: JSONValue]) async
        -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: "note.play", params: params))
    }

    @Test("note.play is registered, next to note.audition and NOT at the tail")
    func verbIsRegistered() {
        #expect(CommandRouter.allCommands.contains("note.play"))
        // The neighbourhood is pinned for the reason written on the registry
        // entry: a TAIL append reddened 19 end-relative assertions across 7
        // files on this item's first run, and a "tidy-up" that moves it there
        // must be caught here rather than in those 7 unrelated files.
        let index = CommandRouter.allCommands.firstIndex(of: "note.play")
        let sibling = CommandRouter.allCommands.firstIndex(of: "pad.previewEffort")
        #expect(index != nil && sibling != nil)
        #expect(index == sibling.map { $0 + 1 })
        #expect(index != CommandRouter.allCommands.count - 1, "must NOT be at the tail")
    }

    @Test("note.play sounds a chord and echoes what it sounded, with the honesty light off")
    func playSoundsAChord() async {
        let (router, _, engine, instrument, _) = makeRouter()

        let response = await play(router, [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(67), .number(60), .number(64)]),
            "velocity": .number(90),
        ])

        #expect(response.ok)
        #expect(response.result?["trackId"]?.stringValue == instrument.uuidString)
        // PRESS ORDER, not sorted — the live-play cap keeps the most recent, so
        // the echo must not silently re-order what the caller played.
        #expect(response.result?["pitches"]?.arrayValue?.compactMap(\.doubleValue) == [67, 60, 64])
        #expect(response.result?["velocity"]?.doubleValue == 90)
        #expect(response.result?["holding"]?.boolValue == true)
        #expect(response.result?["audible"]?.boolValue == true)
        #expect(response.result?["reason"] == nil)
        // Nothing is recording, so the honesty light is OFF: the notes sounded
        // and went into no take.
        #expect(response.result?["recording"]?.boolValue == false)
        #expect(engine.livePlayCalls.count == 1)
        #expect(engine.livePlayCalls[0].pitches == [67, 60, 64])
        #expect(!engine.livePlayCalls[0].captureIntoTake)
    }

    @Test("⭐ note.play SUCCEEDS while a take is recording — the one thing note.audition cannot do")
    func playSucceedsWhileRecording() async throws {
        let (router, store, engine, instrument, _) = makeRouter()
        try store.setTrackArm(id: instrument, armed: true)
        try store.record()
        #expect(store.transport.isRecording)

        let response = await play(router, [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(60)]),
        ])

        #expect(response.ok)
        #expect(response.result?["recording"]?.boolValue == true)
        #expect(response.result?["capturedEdges"]?.doubleValue == 1)
        #expect(engine.livePlayCalls.last?.captureIntoTake == true)

        // The companion refusal is UNCHANGED: note.audition still refuses,
        // because audition is heard-but-not-captured and this path is not.
        let refused = await router.handle(ControlRequest(
            id: "2", command: "note.audition",
            params: ["trackId": .string(instrument.uuidString),
                     "pitches": .array([.number(64)])]))
        #expect(!refused.ok)
        #expect(refused.error?.contains("while recording") == true)
    }

    @Test("an EMPTY pitches array releases and is never refused — including mid-take")
    func emptyReleases() async throws {
        let (router, store, engine, instrument, _) = makeRouter()
        _ = await play(router, ["trackId": .string(instrument.uuidString),
                                "pitches": .array([.number(60)])])
        try store.setTrackArm(id: instrument, armed: true)
        try store.record()

        let response = await play(router, ["trackId": .string(instrument.uuidString),
                                           "pitches": .array([])])

        #expect(response.ok)
        #expect(response.result?["pitches"]?.arrayValue?.isEmpty == true)
        #expect(response.result?["holding"]?.boolValue == false)
        #expect(engine.livePlayCalls.last?.pitches.isEmpty == true)
        #expect(!store.livePlay.isHolding)
    }

    @Test("velocity defaults to 100 when omitted")
    func velocityDefaults() async {
        let (router, _, engine, instrument, _) = makeRouter()
        let response = await play(router, ["trackId": .string(instrument.uuidString),
                                           "pitches": .array([.number(60)])])
        #expect(response.ok)
        #expect(response.result?["velocity"]?.doubleValue == 100)
        #expect(engine.livePlayCalls[0].velocity == 100)
    }

    @Test("audible:false + reason is a REAL ANSWER, never an error")
    func inaudibleIsAnAnswer() async {
        let (router, _, engine, instrument, _) = makeRouter()
        engine.outcomeStub = .inaudibleMuted

        let response = await play(router, ["trackId": .string(instrument.uuidString),
                                           "pitches": .array([.number(60)])])

        #expect(response.ok)
        #expect(response.result?["audible"]?.boolValue == false)
        #expect(response.result?["reason"]?.stringValue == "trackMuted")
    }

    @Test("every clamp and refusal is a teaching error that sounds NOTHING")
    func refusalsSoundNothing() async {
        let (router, _, engine, instrument, audio) = makeRouter()

        let bad: [[String: JSONValue]] = [
            ["trackId": .string(audio.uuidString), "pitches": .array([.number(60)])],
            ["trackId": .string(UUID().uuidString), "pitches": .array([.number(60)])],
            ["trackId": .string(instrument.uuidString),
             "pitches": .array((60...68).map { .number(Double($0)) })],   // 9 pitches
            ["trackId": .string(instrument.uuidString), "pitches": .array([.number(128)])],
            ["trackId": .string(instrument.uuidString), "pitches": .array([.number(60.5)])],
            ["trackId": .string(instrument.uuidString), "pitches": .number(60)],  // not an array
            ["trackId": .string(instrument.uuidString), "pitches": .array([.number(60)]),
             "velocity": .number(0)],
            ["trackId": .string(instrument.uuidString), "pitches": .array([.number(60)]),
             "velocity": .number(128)],
            // The singular alias does NOT exist, and neither does durationMs:
            // note.play is HELD, never a one-shot.
            ["trackId": .string(instrument.uuidString), "pitch": .number(60)],
            ["trackId": .string(instrument.uuidString), "pitches": .array([.number(60)]),
             "durationMs": .number(500)],
            ["pitches": .array([.number(60)])],   // no trackId
        ]
        for params in bad {
            let response = await play(router, params)
            #expect(!response.ok, "expected a refusal for \(params)")
            #expect(response.error?.isEmpty == false)
        }
        #expect(engine.livePlayCalls.isEmpty)
    }

    @Test("note.play and note.audition arbitrate: starting one releases the other")
    func arbitration() async {
        let (router, store, engine, instrument, _) = makeRouter()

        _ = await router.handle(ControlRequest(
            id: "1", command: "note.audition",
            params: ["trackId": .string(instrument.uuidString),
                     "pitches": .array([.number(60)]), "durationMs": .number(5_000)]))
        #expect(store.audition.isHolding)

        _ = await play(router, ["trackId": .string(instrument.uuidString),
                                "pitches": .array([.number(64)])])

        #expect(!store.audition.isHolding)
        #expect(store.livePlay.isHolding)
        // The audition release went out BEFORE the live note sounded — without
        // it the two controllers ping-pong over the same engine ledger at
        // 500 ms, each heartbeat undoing the other.
        #expect(engine.auditionCalls.last?.pitches.isEmpty == true)
    }

    @Test("transport.panic releases a held live note")
    func panicReleasesLivePlay() async throws {
        let (router, store, engine, instrument, _) = makeRouter()
        try store.setTrackArm(id: instrument, armed: true)
        try store.record()
        _ = await play(router, ["trackId": .string(instrument.uuidString),
                                "pitches": .array([.number(60)])])
        #expect(store.livePlay.isHolding)

        let response = await router.handle(ControlRequest(id: "2", command: "transport.panic",
                                                          params: [:]))

        #expect(response.ok)
        #expect(!store.livePlay.isHolding)
        #expect(engine.livePlayCalls.last?.pitches.isEmpty == true)
    }
}
