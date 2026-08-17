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

    /// The field-report case (2026-08-17): an agent read `audible: true` off a
    /// soundBank track whose patch was still loading, A/B'd two candidate
    /// patches on the strength of it, and reported a tonal preference it could
    /// not have heard. `audible` answers "is this signal path gated?", not "did
    /// the patch I just set finish loading?" — the two read the registry through
    /// different questions and can disagree for an instant. So the reply carries
    /// the load status for the two kinds that HAVE one, and stays silent for the
    /// three that don't (a default "pending" on a polySynth would read as a
    /// stall that cannot happen).
    @Test("the reply carries instrumentStatus for soundBank/AU, and NOT for polySynth")
    func instrumentStatusRidesTheReply() async throws {
        // `engine` is bound (not `_`): ProjectStore holds it weakly, so dropping
        // the only strong reference deallocates the spy mid-test and every
        // audition answers inaudible for the wrong reason.
        let (router, store, engine, instrument, _) = makeRouter()
        #expect(engine.isRunning)

        // Negative control FIRST: a default (polySynth) track holds no registry
        // slot, so the key must be absent — not "pending", not "ready".
        let poly = await audition(router, [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(60)]),
        ])
        #expect(poly.ok)
        #expect(poly.result?["audible"]?.boolValue == true)
        #expect(poly.result?["instrumentStatus"] == nil)

        // The reported case: a soundBank patch, headless, so the engine has
        // recorded no status yet — `audible:true` NEXT TO "pending" is exactly
        // the pair that misled the agent, and it is now visible in one reply.
        // A real config, not a bare `kind:` — the snapshot only publishes the
        // `soundBank` object (and with it the status this cross-check reads)
        // when the descriptor actually carries one.
        _ = try store.setInstrument(id: instrument, kind: .soundBank,
                                    soundBank: SoundBankConfig(source: .generalMIDI, program: 0))
        let bank = await audition(router, [
            "trackId": .string(instrument.uuidString),
            "pitches": .array([.number(60)]),
        ])
        #expect(bank.ok)
        #expect(bank.result?["audible"]?.boolValue == true)
        #expect(bank.result?["instrumentStatus"]?.stringValue == "pending")
        // It agrees with the OTHER place the same status is published, so an
        // agent can't be told two different stories about one track.
        let snapshot = await router.handle(
            ControlRequest(id: "s", command: "project.snapshot", params: [:]))
        let tracks = snapshot.result?["tracks"]?.arrayValue ?? []
        let bankTrack = tracks.first { $0.objectValue?["id"]?.stringValue == instrument.uuidString }
        let snapshotStatus = bankTrack?.objectValue?["instrument"]?
            .objectValue?["soundBank"]?.objectValue?["status"]?.stringValue
        #expect(snapshotStatus == bank.result?["instrumentStatus"]?.stringValue)
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
