import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Wire-level gate for `play.sustain` (m34-l) through `CommandRouter.handle`.
///
/// ⭐ The pin the verb exists for is `pedalIsNotRefusedWhileRecording` paired
/// with `liftIsNeverRefused`: pressing is a performance act with the same
/// validation a note-on gets, and lifting has none at all, because a lift that
/// could be refused is a pedal that can get stuck.
@MainActor
@Suite("play.sustain wire command (m34-l)")
struct SustainPedalCommandTests {
    /// Engine spy: records every controller intent, so a REFUSED call can be
    /// proven to have moved nothing — the "a refused call sounds nothing"
    /// contract, which an ok/error assertion alone cannot see.
    @MainActor
    private final class SustainSpyEngine: AudioEngineControlling {
        var isRunning = true
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        private(set) var expressionCalls: [(trackID: UUID, controller: UInt8, value: UInt8,
                                            captureIntoTake: Bool)] = []
        var outcomeStub: AuditionOutcome = .sounded

        func setLiveExpression(trackID: UUID, controller: UInt8, value: UInt8,
                               captureIntoTake: Bool) -> LiveExpressionOutcome {
            expressionCalls.append((trackID, controller, value, captureIntoTake))
            let delivered = outcomeStub != .noRenderer && outcomeStub != .unsupported
            return LiveExpressionOutcome(
                audition: outcomeStub,
                capturedPoints: captureIntoTake && delivered ? 1 : 0,
                recording: captureIntoTake && delivered)
        }

        func setLivePlayPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8,
                                captureIntoTake: Bool) -> LivePlayOutcome {
            LivePlayOutcome(audition: .sounded, capturedEdges: 0, recording: false)
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

    private func makeRouter() -> (CommandRouter, ProjectStore, SustainSpyEngine, UUID, UUID) {
        let store = ProjectStore()
        let engine = SustainSpyEngine()
        store.engine = engine
        let instrument = store.addTrack(name: "Keys", kind: .instrument).id
        let audio = store.addTrack(name: "Vox", kind: .audio).id
        return (CommandRouter(store: store), store, engine, instrument, audio)
    }

    private func pedal(_ router: CommandRouter, _ params: [String: JSONValue]) async
        -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: "play.sustain", params: params))
    }

    private func object(_ response: ControlResponse) -> [String: JSONValue] {
        guard case .object(let fields)? = response.result else { return [:] }
        return fields
    }

    @Test("play.sustain is registered, next to pad.playEffort and NOT at the tail")
    func verbIsRegistered() {
        #expect(CommandRouter.allCommands.contains("play.sustain"))
        // ⚠️ THE NEIGHBOURHOOD IS PINNED, and the reason is measured rather than
        // stylistic: a TAIL append was tried first on this item and reddened
        // 80+ assertions across 22 tests, because every dropLast/suffix window
        // in this corpus is end-relative. A "tidy-up" that moves it to the tail
        // must redden HERE rather than in 22 unrelated files.
        let index = CommandRouter.allCommands.firstIndex(of: "play.sustain")
        let sibling = CommandRouter.allCommands.firstIndex(of: "pad.playEffort")
        #expect(index != nil && sibling != nil)
        #expect(index == sibling.map { $0 + 1 })
        #expect(index != CommandRouter.allCommands.count - 1, "must NOT be at the tail")
    }

    @Test("pressing sends CC 64 = 127 and echoes the state, not the request")
    func pressSendsTheStandardValue() async {
        let (router, _, engine, instrument, _) = makeRouter()

        let response = await pedal(router, ["trackId": .string(instrument.uuidString),
                                            "down": .bool(true)])
        #expect(response.ok)
        let fields = object(response)
        #expect(fields["down"] == .bool(true))
        #expect(fields["controller"] == .number(64))
        #expect(fields["value"] == .number(127))
        #expect(fields["pushed"] == .bool(true))
        // THE HONESTY LIGHT: nothing is recording, so nothing was kept.
        #expect(fields["recording"] == .bool(false))
        #expect(fields["capturedPoints"] == .number(0))

        #expect(engine.expressionCalls.count == 1)
        #expect(engine.expressionCalls[0].controller == 64)
        #expect(engine.expressionCalls[0].value == 127)
    }

    @Test("lifting sends CC 64 = 0")
    func liftSendsZero() async {
        let (router, _, engine, instrument, _) = makeRouter()
        _ = await pedal(router, ["trackId": .string(instrument.uuidString),
                                 "down": .bool(true)])
        let response = await pedal(router, ["trackId": .string(instrument.uuidString),
                                            "down": .bool(false)])
        #expect(response.ok)
        #expect(object(response)["down"] == .bool(false))
        #expect(object(response)["value"] == .number(0))
        #expect(engine.expressionCalls.last?.value == 0)
    }

    /// ⚠️ A re-press is an honest no-op, and the reply SAYS so rather than
    /// pretending a byte went out. A caller that counted CC pushes off `ok`
    /// alone would over-count; `pushed` is what it should read.
    @Test("re-pressing a pedal that is already down reports pushed:false")
    func rePressIsAnHonestNoOp() async {
        let (router, _, engine, instrument, _) = makeRouter()
        _ = await pedal(router, ["trackId": .string(instrument.uuidString),
                                 "down": .bool(true)])
        let again = await pedal(router, ["trackId": .string(instrument.uuidString),
                                         "down": .bool(true)])
        #expect(again.ok)
        #expect(object(again)["pushed"] == .bool(false))
        #expect(object(again)["down"] == .bool(true))
        #expect(engine.expressionCalls.count == 1)
    }

    /// ⭐ The pin the verb exists for. Every other "sounds now" verb on this
    /// surface (`note.audition`, `pad.previewEffort`) is REFUSED mid-take;
    /// this one must not be, because its edges are CAPTURED.
    @Test("play.sustain is NOT refused while recording, and the edge is kept when armed")
    func pedalIsNotRefusedWhileRecording() async throws {
        let (router, store, engine, instrument, _) = makeRouter()
        try store.setTrackArm(id: instrument, armed: true)
        try store.record()
        #expect(store.transport.isRecording)

        let response = await pedal(router, ["trackId": .string(instrument.uuidString),
                                            "down": .bool(true)])
        #expect(response.ok, "the pedal was refused mid-take: \(response.error ?? "?")")
        #expect(object(response)["recording"] == .bool(true))
        #expect(object(response)["capturedPoints"] == .number(1))
        #expect(engine.expressionCalls.last?.captureIntoTake == true)
    }

    @Test("a PRESS on an audio track is refused, and moves no controller")
    func pressIsValidated() async {
        let (router, _, engine, _, audio) = makeRouter()
        let response = await pedal(router, ["trackId": .string(audio.uuidString),
                                            "down": .bool(true)])
        #expect(!response.ok)
        // ⛔ THE HALF AN `ok:false` CANNOT SEE: a refused call must have moved
        // NOTHING. Without this the verb could refuse loudly and pedal anyway.
        #expect(engine.expressionCalls.isEmpty)
    }

    /// ⛔⛔ GATE THE ONS, NEVER GATE THE OFFS. A lift on an audio track, and on
    /// a track that does not exist at all, must both succeed — the states where
    /// a lift is most needed are exactly the states where something has gone
    /// wrong.
    @Test("a LIFT is never refused — not on an audio track, not on a missing one")
    func liftIsNeverRefused() async {
        let (router, _, _, _, audio) = makeRouter()
        let onAudio = await pedal(router, ["trackId": .string(audio.uuidString),
                                           "down": .bool(false)])
        #expect(onAudio.ok, "a lift was refused on an audio track: \(onAudio.error ?? "?")")
        let onMissing = await pedal(router, ["trackId": .string(UUID().uuidString),
                                             "down": .bool(false)])
        #expect(onMissing.ok, "a lift was refused on a missing track: \(onMissing.error ?? "?")")
    }

    /// `down` has no default on purpose: "press or lift?" is not a question a
    /// verb may guess at, and a defaulted `false` would make a typo'd call
    /// silently lift a pedal the user is holding.
    @Test("'down' is required, and an unknown key is a teaching error")
    func parameterContract() async {
        let (router, _, _, instrument, _) = makeRouter()
        let missing = await pedal(router, ["trackId": .string(instrument.uuidString)])
        #expect(!missing.ok)
        #expect(missing.error?.contains("down") == true)

        let unknown = await pedal(router, ["trackId": .string(instrument.uuidString),
                                           "down": .bool(true),
                                           "pedal": .bool(true)])
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("pedal") == true)
    }

    /// A press that reached no renderer comes back UP. A caller lighting a lamp
    /// off its own request would show a pedal that is not down — the failure the
    /// read-back exists to make impossible.
    @Test("a press that reached no renderer echoes down:false with a reason")
    func undeliveredPressEchoesUp() async {
        let (router, _, engine, instrument, _) = makeRouter()
        engine.outcomeStub = .noRenderer
        let response = await pedal(router, ["trackId": .string(instrument.uuidString),
                                            "down": .bool(true)])
        // A real answer, not an error — the `note.play` contract.
        #expect(response.ok)
        #expect(object(response)["down"] == .bool(false))
        #expect(object(response)["reason"] != nil)
    }
}
