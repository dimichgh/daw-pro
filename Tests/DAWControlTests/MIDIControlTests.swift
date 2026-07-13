import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// M3 (vii) control surface: midi.listInputs, instrument-track arming through
/// track.setArm, and the snapshot's midiInputs/midiEventCount fields.
@MainActor
final class FakeMIDIEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    var midiInputs: [MIDIInputDevice] = []
    var eventCount = 0

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }

    func availableMIDIInputs() -> [MIDIInputDevice] { midiInputs }
    func midiEventCount() -> Int { eventCount }
}

@MainActor
@Suite("MIDI control surface")
struct MIDIControlTests {
    private func makeRouter(engine: FakeMIDIEngine) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    @Test("midi.listInputs returns the engine's devices (and is a known command)")
    func midiListInputsReturnsEngineDevices() async {
        let engine = FakeMIDIEngine()
        engine.midiInputs = [
            MIDIInputDevice(uniqueID: 42, name: "Test Keys", isVirtual: false, isOnline: true),
            MIDIInputDevice(uniqueID: -7, name: "Virtual Src", isVirtual: true, isOnline: false),
        ]
        let (router, _) = makeRouter(engine: engine)

        #expect(CommandRouter.allCommands.contains("midi.listInputs"))
        let response = await router.handle(ControlRequest(id: "1", command: "midi.listInputs"))
        #expect(response.ok)
        let inputs = response.result?["inputs"]?.arrayValue
        #expect(inputs?.count == 2)
        #expect(inputs?[0]["uniqueID"]?.doubleValue == 42)
        #expect(inputs?[0]["name"]?.stringValue == "Test Keys")
        #expect(inputs?[0]["isVirtual"]?.boolValue == false)
        #expect(inputs?[0]["isOnline"]?.boolValue == true)
        #expect(inputs?[1]["uniqueID"]?.doubleValue == -7)
        #expect(inputs?[1]["isVirtual"]?.boolValue == true)
    }

    @Test("track.setArm accepts instrument tracks; bus still errors readably")
    func trackSetArmAcceptsInstrumentTracks() async {
        let engine = FakeMIDIEngine()
        let (router, store) = makeRouter(engine: engine)
        let inst = store.addTrack(kind: .instrument)
        let bus = store.addTrack(kind: .bus)

        let armed = await router.handle(ControlRequest(
            id: "1", command: "track.setArm",
            params: ["trackId": .string(inst.id.uuidString), "armed": .bool(true)]))
        #expect(armed.ok)
        #expect(store.tracks[0].isArmed)

        let refused = await router.handle(ControlRequest(
            id: "2", command: "track.setArm",
            params: ["trackId": .string(bus.id.uuidString), "armed": .bool(true)]))
        #expect(!refused.ok)
        #expect(refused.error?.contains("bus") == true)
    }

    @Test("project.snapshot carries midiInputs and midiEventCount")
    func snapshotCarriesMIDIInputsAndEventCount() async {
        let engine = FakeMIDIEngine()
        engine.midiInputs = [
            MIDIInputDevice(uniqueID: 7, name: "Pad", isVirtual: true, isOnline: true),
        ]
        engine.eventCount = 123
        let (router, _) = makeRouter(engine: engine)

        let response = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(response.ok)
        #expect(response.result?["midiEventCount"]?.doubleValue == 123)
        let inputs = response.result?["midiInputs"]?.arrayValue
        #expect(inputs?.count == 1)
        #expect(inputs?[0]["name"]?.stringValue == "Pad")
        #expect(inputs?[0]["uniqueID"]?.doubleValue == 7)
    }
}
