import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Wire-level gate for `note.audition` (m23-d) through `CommandRouter.handle`
/// — §13's C10 (every clamp/refusal is a TEACHING error that pushes nothing),
/// C16's catalog half, and the `audible:false + reason` contract that must stay
/// a successful answer rather than an error.
@MainActor
@Suite("note.audition wire command (m23-d)")
struct AuditionCommandTests {
    /// Engine spy: records every audition intent so a rejection can be proven
    /// to have sounded NOTHING, and lets a test drive the inaudible branches.
    @MainActor
    private final class AuditionSpyEngine: AudioEngineControlling {
        var isRunning = true
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        private(set) var auditionCalls: [(trackID: UUID, pitches: [UInt8], velocity: UInt8)] = []
        var outcomeStub: AuditionOutcome = .sounded

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

    private func makeRouter() -> (CommandRouter, ProjectStore, AuditionSpyEngine, UUID, UUID) {
        let store = ProjectStore()
        let engine = AuditionSpyEngine()
        store.engine = engine
        let instrument = store.addTrack(name: "Keys", kind: .instrument).id
        let audio = store.addTrack(name: "Vox", kind: .audio).id
        return (CommandRouter(store: store), store, engine, instrument, audio)
    }

    private func audition(_ router: CommandRouter, _ params: [String: JSONValue]) async
        -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: "note.audition", params: params))
    }

    @Test("note.audition sounds a chord and echoes what it sounded")
    func auditionSoundsAChord() async {
        let (router, _, engine, instrument, _) = makeRouter()

        let response = await audition(router, [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(67), .number(60), .number(64)]),
            "velocity": .number(90),
            "durationMs": .number(1_200),
        ])

        #expect(response.ok)
        #expect(response.result?["trackId"]?.stringValue == instrument.uuidString)
        // Ascending + de-duped, so the echo is what actually sounded.
        #expect(response.result?["pitches"]?.arrayValue?.compactMap(\.doubleValue) == [60, 64, 67])
        #expect(response.result?["velocity"]?.doubleValue == 90)
        #expect(response.result?["durationMs"]?.doubleValue == 1_200)
        #expect(response.result?["audible"]?.boolValue == true)
        #expect(response.result?["reason"] == nil)   // an audible answer carries no reason
        #expect(engine.auditionCalls.count == 1)
        #expect(engine.auditionCalls[0].pitches == [60, 64, 67])
        #expect(engine.auditionCalls[0].velocity == 90)
    }

    @Test("velocity and durationMs default when omitted")
    func defaultsApply() async {
        let (router, _, engine, instrument, _) = makeRouter()
        let response = await audition(router, [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(60)]),
        ])
        #expect(response.ok)
        #expect(response.result?["velocity"]?.doubleValue == 100)
        #expect(response.result?["durationMs"]?.doubleValue == 500)
        #expect(engine.auditionCalls[0].velocity == 100)
    }

    @Test("audible:false carries a teaching reason and is STILL a successful answer")
    func inaudibleIsAnAnswerNotAnError() async {
        let (router, _, engine, instrument, _) = makeRouter()
        engine.outcomeStub = .inaudibleMuted

        let muted = await audition(router, [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(60)]),
        ])
        #expect(muted.ok)                                       // NOT an error
        #expect(muted.result?["audible"]?.boolValue == false)
        #expect(muted.result?["reason"]?.stringValue == "trackMuted")
        #expect(engine.auditionCalls.count == 1)                // it WAS delivered

        engine.outcomeStub = .inaudibleNotReady
        let notReady = await audition(router, [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(62)]),
        ])
        #expect(notReady.ok)
        #expect(notReady.result?["reason"]?.stringValue == "instrumentNotReady")

        engine.outcomeStub = .noRenderer
        let rebuilding = await audition(router, [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(64)]),
        ])
        #expect(rebuilding.ok)
        #expect(rebuilding.result?["reason"]?.stringValue == "engineRebuilding")
    }

    @Test("C10 every rejection is a teaching error that pushed NOTHING")
    func rejectionsTeachAndSoundNothing() async {
        let (router, _, engine, instrument, audio) = makeRouter()
        let cases: [(name: String, params: [String: JSONValue])] = [
            ("unknown track", ["trackId": .string(UUID().uuidString),
                               "pitches": .array([.number(60)])]),
            ("not an instrument track", ["trackId": .string(audio.uuidString),
                                         "pitches": .array([.number(60)])]),
            ("missing pitches", ["trackId": .string(instrument.uuidString)]),
            ("pitches not an array", ["trackId": .string(instrument.uuidString),
                                      "pitches": .number(60)]),
            ("empty pitches", ["trackId": .string(instrument.uuidString),
                               "pitches": .array([])]),
            ("too many pitches", ["trackId": .string(instrument.uuidString),
                                  "pitches": .array((40...48).map { .number(Double($0)) })]),
            ("pitch out of range", ["trackId": .string(instrument.uuidString),
                                    "pitches": .array([.number(128)])]),
            ("non-integer pitch", ["trackId": .string(instrument.uuidString),
                                   "pitches": .array([.number(60.5)])]),
            ("velocity too low", ["trackId": .string(instrument.uuidString),
                                  "pitches": .array([.number(60)]), "velocity": .number(0)]),
            ("velocity too high", ["trackId": .string(instrument.uuidString),
                                   "pitches": .array([.number(60)]), "velocity": .number(200)]),
            ("durationMs too short", ["trackId": .string(instrument.uuidString),
                                      "pitches": .array([.number(60)]), "durationMs": .number(9)]),
            ("durationMs too long", ["trackId": .string(instrument.uuidString),
                                     "pitches": .array([.number(60)]),
                                     "durationMs": .number(5_001)]),
            ("unknown key", ["trackId": .string(instrument.uuidString),
                             "pitches": .array([.number(60)]), "hold": .bool(true)]),
            ("the singular alias does not exist", ["trackId": .string(instrument.uuidString),
                                                   "pitch": .number(60)]),
            ("bad uuid", ["trackId": .string("not-a-uuid"),
                          "pitches": .array([.number(60)])]),
        ]
        for testCase in cases {
            let response = await audition(router, testCase.params)
            #expect(!response.ok, "\(testCase.name) should be refused")
            #expect(response.error?.isEmpty == false, "\(testCase.name) needs a readable reason")
        }
        // THE POINT: not one of them reached a renderer.
        #expect(engine.auditionCalls.isEmpty)
    }

    @Test("C10 note.audition is refused while recording")
    func refusedWhileRecording() async throws {
        let (router, store, engine, instrument, _) = makeRouter()
        try store.setTrackArm(id: instrument, armed: true)
        try store.record()
        #expect(store.transport.isRecording)

        let response = await audition(router, [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(60)]),
        ])
        #expect(!response.ok)
        #expect(response.error?.contains("recording") == true)
        #expect(engine.auditionCalls.isEmpty)
    }

    @Test("C16 the verb is on allCommands and in the copilot catalog exactly once")
    func wirePins() {
        #expect(CommandRouter.allCommands.contains("note.audition"))
        #expect(CommandRouter.allCommands.filter { $0 == "note.audition" }.count == 1)
        let entries = CopilotToolCatalog.v1.filter { $0.command == "note.audition" }
        #expect(entries.count == 1)
        // The catalog must teach the two things an agent gets wrong: that it is
        // a preview rather than an edit, and that audible:false is an answer.
        let description = entries.first?.description ?? ""
        #expect(description.contains("NOT an edit"))
        #expect(description.contains("audible:false"))
        #expect(!CommandRouter.allCommands.contains("note.auditionStop"))
    }
}
