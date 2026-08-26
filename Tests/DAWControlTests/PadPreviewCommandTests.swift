import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Wire-level gate for `pad.previewEffort` (breath pad P6) through
/// `CommandRouter.handle`: the gesture scoping is enforced ON THE WIRE, every
/// refusal is a teaching error that pushed NOTHING, and `end` restores neutral
/// rather than parking the last value.
///
/// ⚠️ Deliberately NOT a `@MainActor` suite — the tree's `@MainActor` suite
/// budget is nearly spent, so isolation rides each test (the
/// `OutputDeviceTests` shape).
@Suite("pad.previewEffort wire command (breath pad P6)")
struct PadPreviewCommandTests {

    /// Records every controller push, so a refusal can be PROVEN to have moved
    /// nothing rather than merely to have returned an error.
    @MainActor
    private final class PadSpyEngine: AudioEngineControlling {
        var isRunning = true
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        private(set) var pushes: [(trackID: UUID, controller: UInt8, value: UInt8)] = []
        var outcomeStub: AuditionOutcome = .sounded

        func clear() { pushes.removeAll() }

        func previewController(trackID: UUID, controller: UInt8,
                               value: UInt8) -> AuditionOutcome {
            pushes.append((trackID, controller, value))
            return outcomeStub
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

    @MainActor
    private func makeRouter() -> (CommandRouter, ProjectStore, PadSpyEngine, UUID, UUID) {
        let store = ProjectStore()
        let engine = PadSpyEngine()
        store.engine = engine
        let instrument = store.addTrack(name: "Sax", kind: .instrument).id
        let audio = store.addTrack(name: "Vox", kind: .audio).id
        return (CommandRouter(store: store), store, engine, instrument, audio)
    }

    private func preview(_ router: CommandRouter, _ params: [String: JSONValue]) async
        -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: "pad.previewEffort", params: params))
    }

    @Test("pad.previewEffort is registered on the wire")
    @MainActor
    func verbIsRegistered() {
        #expect(CommandRouter.allCommands.contains("pad.previewEffort"))
        // Placed NEXT TO its sibling, not at the tail — a tail append broke 80
        // assertions across 22 tests at m27 leg D and every filtered run stayed
        // green. This pins the neighbourhood, so a later "tidy-up" that moves it
        // to the end is caught here rather than in 22 unrelated files.
        let index = CommandRouter.allCommands.firstIndex(of: "pad.previewEffort")
        let sibling = CommandRouter.allCommands.firstIndex(of: "note.audition")
        #expect(index != nil && sibling != nil)
        #expect(index == sibling.map { $0 + 1 })
        #expect(index != CommandRouter.allCommands.count - 1, "must NOT be at the tail")
    }

    @Test("a whole gesture: begin streams, move updates, end restores NEUTRAL")
    @MainActor
    func aWholeGestureStreamsAndReleases() async {
        let (router, _, engine, instrument, _) = makeRouter()

        let begun = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "value": .number(0.5),
            "gesture": .string("begin"),
        ])
        #expect(begun.ok)
        #expect(begun.result?["controller"]?.doubleValue == 11)
        #expect(begun.result?["controllerValue"]?.doubleValue == 64)
        #expect(begun.result?["streaming"]?.boolValue == true)
        #expect(begun.result?["delivered"]?.boolValue == true)
        #expect(begun.result?["audible"]?.boolValue == true)
        #expect(begun.result?["reason"] == nil)

        let ended = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "gesture": .string("end"),
        ])
        #expect(ended.ok)
        #expect(ended.result?["streaming"]?.boolValue == false)
        // ⛔ NEUTRAL, not the last effort. A CC is sticky; parking 64 would make
        // the next playback differ from a fresh bounce of the same project.
        #expect(ended.result?["controllerValue"]?.doubleValue == 127)
        // `end` carries no effort, so the echo must omit the key rather than
        // synthesize a 0 that a caller could mistake for "effort fell to zero".
        #expect(ended.result?["value"] == nil)

        #expect(engine.pushes.count == 2)
        #expect(engine.pushes[0].value == 64)
        #expect(engine.pushes[1].value == 127)
    }

    @Test("a move with NO open gesture is refused, and nothing reached the engine")
    @MainActor
    func moveWithoutBeginIsRefusedOnTheWire() async {
        let (router, _, engine, instrument, _) = makeRouter()

        let response = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "value": .number(0.8),
            "gesture": .string("move"),
        ])

        #expect(!response.ok)
        #expect(response.error?.contains("no pad gesture is open") == true)
        // The teaching half: it says what to do instead.
        #expect(response.error?.contains("begin") == true)
        #expect(engine.pushes.isEmpty,
                "the pad must never stream while the transport merely rolls")
    }

    @Test("an end naming a DIFFERENT track than the open gesture is refused on the wire")
    @MainActor
    func endOnTheWrongTrackIsRefusedOnTheWire() async {
        // The `pad_preview_effort` MCP description tells agents that an `end`
        // naming a different trackId "is REFUSED", and the schema-vs-description
        // test checks KEY SETS, not behaviour — so without this, the promise most
        // likely to be relied on by a caller is the one nothing verifies.
        // The bug it forbids: `end` on B releasing the gesture open on A and
        // answering with a payload that names B.
        let (router, store, engine, instrument, _) = makeRouter()
        let other = store.addTrack(name: "Flute", kind: .instrument).id

        let begun = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "value": .number(0.5),
            "gesture": .string("begin"),
        ])
        #expect(begun.ok)
        engine.clear()

        let wrong = await preview(router, [
            "trackId": .string(other.uuidString),
            "gesture": .string("end"),
        ])
        #expect(!wrong.ok)
        #expect(wrong.error?.contains(instrument.uuidString) == true,
                "the refusal must name the track that IS open, so the caller can fix the call")
        #expect(engine.pushes.isEmpty, "a refused end must release nothing")

        // The gesture survives, and the RIGHT track still ends cleanly.
        let right = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "gesture": .string("end"),
        ])
        #expect(right.ok)
        #expect(right.result?["streaming"]?.boolValue == false)
        #expect(right.result?["delivered"]?.boolValue == true)
        #expect(engine.pushes.count == 1)
        #expect(engine.pushes.first?.value == 127)
    }

    @Test("an unknown gesture, a missing gesture and a bad value are teaching errors")
    @MainActor
    func malformedCallsAreTeachingErrors() async {
        let (router, _, engine, instrument, _) = makeRouter()
        let id = JSONValue.string(instrument.uuidString)

        let noGesture = await preview(router, ["trackId": id, "value": .number(0.5)])
        #expect(!noGesture.ok)
        #expect(noGesture.error?.contains("begin") == true)

        let badGesture = await preview(router, [
            "trackId": id, "value": .number(0.5), "gesture": .string("start"),
        ])
        #expect(!badGesture.ok)
        #expect(badGesture.error?.contains("start") == true)

        let noValue = await preview(router, ["trackId": id, "gesture": .string("begin")])
        #expect(!noValue.ok)
        #expect(noValue.error?.contains("0…1") == true)

        let badValue = await preview(router, [
            "trackId": id, "value": .number(1.4), "gesture": .string("begin"),
        ])
        #expect(!badValue.ok)
        #expect(badValue.error?.contains("0…1") == true)

        let badCC = await preview(router, [
            "trackId": id, "value": .number(0.5), "gesture": .string("begin"),
            "expressionCC": .number(200),
        ])
        #expect(!badCC.ok)

        #expect(engine.pushes.isEmpty, "not one malformed call may reach a renderer")
    }

    @Test("unknown keys are refused by name, with the valid set listed")
    @MainActor
    func unknownKeysAreRefused() async {
        let (router, _, engine, instrument, _) = makeRouter()
        let response = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "value": .number(0.5),
            "gesture": .string("begin"),
            "effort": .number(0.5),
        ])
        #expect(!response.ok)
        #expect(response.error?.contains("effort") == true)
        #expect(response.error?.contains("expressionCC") == true)
        #expect(engine.pushes.isEmpty)
    }

    @Test("audio and bus tracks are refused before anything is pushed")
    @MainActor
    func nonInstrumentTracksAreRefused() async {
        let (router, _, engine, _, audio) = makeRouter()
        let response = await preview(router, [
            "trackId": .string(audio.uuidString),
            "value": .number(0.5),
            "gesture": .string("begin"),
        ])
        #expect(!response.ok)
        #expect(engine.pushes.isEmpty)
    }

    @Test("refused while RECORDING — but end is always allowed, so nothing can strand")
    @MainActor
    func refusedWhileRecordingExceptEnd() async throws {
        let (router, store, engine, instrument, _) = makeRouter()
        try store.setTrackArm(id: instrument, armed: true)

        // Open a gesture, then start a take under it.
        #expect(await preview(router, [
            "trackId": .string(instrument.uuidString),
            "value": .number(0.1),
            "gesture": .string("begin"),
        ]).ok)
        // Starting the take releases the gesture to neutral: a parked CC 11
        // would attenuate the whole take while being invisible in the project.
        try store.record()
        #expect(engine.pushes.last?.value == 127)
        #expect(!store.padPreview.isStreaming)

        let refused = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "value": .number(0.5),
            "gesture": .string("begin"),
        ])
        #expect(!refused.ok)
        #expect(refused.error?.contains("recording") == true)

        // `end` is never refused, so a gesture can always be closed.
        let ended = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "gesture": .string("end"),
        ])
        // Nothing was open, so this is the honest "nothing to release" refusal
        // rather than a transport refusal — the point is that the RECORDING gate
        // did not produce it.
        #expect(ended.error?.contains("recording") != true)
        store.stop()
    }

    @Test("expressionCC rides through and its own neutral is restored on end")
    @MainActor
    func nonDefaultControllerRoundTrips() async {
        let (router, _, engine, instrument, _) = makeRouter()

        let begun = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "value": .number(1.0),
            "gesture": .string("begin"),
            "expressionCC": .number(74),
        ])
        #expect(begun.ok)
        #expect(begun.result?["controller"]?.doubleValue == 74)
        #expect(begun.result?["controllerValue"]?.doubleValue == 127)

        let ended = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "gesture": .string("end"),
        ])
        // CC 74's neutral is 0, not 127: a hard-coded release value would be
        // wrong here.
        #expect(ended.result?["controllerValue"]?.doubleValue == 0)
        #expect(engine.pushes.last?.controller == 74)
        #expect(engine.pushes.last?.value == 0)
    }

    @Test("an inaudible strip is a REAL ANSWER with a reason, not an error")
    @MainActor
    func inaudibleIsAnAnswerNotAnError() async {
        let (router, _, engine, instrument, _) = makeRouter()
        engine.outcomeStub = .inaudibleMuted

        let response = await preview(router, [
            "trackId": .string(instrument.uuidString),
            "value": .number(0.5),
            "gesture": .string("begin"),
        ])

        #expect(response.ok, "the controller WAS delivered; the strip is just silent")
        #expect(response.result?["audible"]?.boolValue == false)
        #expect(response.result?["reason"]?.stringValue != nil)
        #expect(engine.pushes.count == 1)
    }

    @Test("the preview writes NOTHING to the project and makes no undo entry")
    @MainActor
    func previewIsNotAnEdit() async {
        let (router, store, _, instrument, _) = makeRouter()
        let historyBefore = store.undoHistory().undo

        #expect(await preview(router, [
            "trackId": .string(instrument.uuidString),
            "value": .number(0.9),
            "gesture": .string("begin"),
        ]).ok)
        #expect(await preview(router, [
            "trackId": .string(instrument.uuidString),
            "gesture": .string("end"),
        ]).ok)

        #expect(store.undoHistory().undo == historyBefore,
                "a preview is a gesture, never the record — the lane verb is the record")
        #expect(store.tracks.first { $0.id == instrument }?.clips.isEmpty == true)
    }
}
