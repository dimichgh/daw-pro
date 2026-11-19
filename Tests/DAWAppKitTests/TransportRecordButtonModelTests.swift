import DAWAppKit
import DAWCore
import Foundation
import Testing

/// Counts every take the song's store asks the engine for: the proof that a refused Record started NOTHING
/// (p2-sing-f2). Internal: `GenerationPresenceModelTests`' recorder-on-a-real-store tests use it too.
@MainActor
final class RecordRefusalSpyEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    /// `startTake` (the ordinary record path) calls.
    private(set) var takeStarts = 0
    /// `startTakeInPlayback` (a layer) calls.
    private(set) var layerStarts = 0
    private(set) var stopRecordingCalls = 0

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
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        takeStarts += 1
    }
    func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                   completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
        takeStarts += 1
    }
    func startTakeInPlayback(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                             completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
        layerStarts += 1
    }
    func stopRecording() { stopRecordingCalls += 1 }
}

/// p2-sing-f2: the transport's Record button, headless (`TransportRecordButtonModel`).
///
/// ⚠️ This suite is deliberately NOT `@MainActor`-isolated (the `LoopDeckControlModelTests` precedent): the tree's
/// `@MainActor` suite count sits at its cadence cap, so the functions that need a real store carry `@MainActor`
/// themselves and the pure `resolve` tests stay nonisolated.
@Suite struct TransportRecordButtonModelTests {

    private static let recorderOpen = "The voice recorder is open. Close it before recording in the song."

    /// A store with one armed instrument track and a take spy.
    @MainActor
    private func armedStore() throws -> (ProjectStore, RecordRefusalSpyEngine) {
        let engine = RecordRefusalSpyEngine()
        let store = ProjectStore(projectName: "p2-sing-f2 record button")
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument)
        _ = try store.setTrackArm(id: track.id, armed: true)
        return (store, engine)
    }

    // MARK: resolve (pure)

    @Test("the bar's old rules hold: recording = Stop; nothing armed = disabled with the arm hint; armed = Record")
    func theOldRulesHold() {
        let recording = TransportRecordButtonModel.resolve(isRecording: true, hasArmedTracks: false,
                                                           recorderOpenReason: nil, pressRefusal: nil,
                                                           lastRecordingError: "stale")
        #expect(recording == TransportRecordButtonModel(isEnabled: true, help: TransportRecordButtonModel.stopHelp))
        let unarmed = TransportRecordButtonModel.resolve(isRecording: false, hasArmedTracks: false,
                                                         recorderOpenReason: nil, pressRefusal: nil,
                                                         lastRecordingError: nil)
        #expect(unarmed == TransportRecordButtonModel(isEnabled: false,
                                                      help: TransportRecordButtonModel.armFirstHelp))
        let armed = TransportRecordButtonModel.resolve(isRecording: false, hasArmedTracks: true,
                                                       recorderOpenReason: nil, pressRefusal: nil,
                                                       lastRecordingError: nil)
        #expect(armed == TransportRecordButtonModel(isEnabled: true, help: TransportRecordButtonModel.readyHelp))
        let lastError = TransportRecordButtonModel.resolve(isRecording: false, hasArmedTracks: true,
                                                           recorderOpenReason: nil, pressRefusal: nil,
                                                           lastRecordingError: "microphone access denied")
        #expect(lastError == TransportRecordButtonModel(isEnabled: true, help: "microphone access denied"))
    }

    @Test("the recorder being open disables Record with its sentence, over every other reason")
    func theRecorderDisablesRecordWithItsSentence() {
        let model = TransportRecordButtonModel.resolve(isRecording: false, hasArmedTracks: true,
                                                       recorderOpenReason: Self.recorderOpen,
                                                       pressRefusal: "an older refusal",
                                                       lastRecordingError: "an older error")
        #expect(model == TransportRecordButtonModel(isEnabled: false, help: Self.recorderOpen))
    }

    @Test("this press's own refusal is the tooltip, over the store's last error from another door")
    func thePressRefusalIsTheTooltip() {
        let model = TransportRecordButtonModel.resolve(isRecording: false, hasArmedTracks: true,
                                                       recorderOpenReason: nil,
                                                       pressRefusal: "this press",
                                                       lastRecordingError: "another door")
        #expect(model.help == "this press")
        #expect(model.isEnabled)
    }

    // MARK: press, and agreement with a real store

    @Test("⭐ a refused press comes back in the STORE'S words (never swallowed) and starts nothing")
    @MainActor
    func aRefusedPressReturnsTheStoresSentence() throws {
        let (store, engine) = try armedStore()
        store.play()   // the store refuses Record while the song plays
        let refusal = TransportRecordButtonModel.press(store)
        let expected = "stop playback before recording — recording starts from a stopped transport "
            + "(set a punch window to record into a range)"
        #expect(refusal == expected)
        #expect(engine.takeStarts == 0)
        #expect(!store.transport.isRecording)
        let model = TransportRecordButtonModel.resolve(store: store, pressRefusal: refusal)
        #expect(model.help == expected)
    }

    @Test("⭐ the recorder's refusal: the model predicts it and the store really gives it (agreement)")
    @MainActor
    func theRecorderRefusalAgreesWithTheStore() throws {
        let (store, engine) = try armedStore()
        store.voiceRecorderOpenReason = Self.recorderOpen
        let model = TransportRecordButtonModel.resolve(store: store, pressRefusal: nil)
        #expect(model == TransportRecordButtonModel(isEnabled: false, help: Self.recorderOpen))
        // The button is disabled, but the store is authoritative: a press that got through anyway is refused in
        // the same words.
        #expect(TransportRecordButtonModel.press(store) == Self.recorderOpen)
        #expect(engine.takeStarts == 0)
        store.voiceRecorderOpenReason = nil
        #expect(TransportRecordButtonModel.resolve(store: store, pressRefusal: nil).isEnabled)
        #expect(TransportRecordButtonModel.press(store) == nil)
        #expect(engine.takeStarts == 1)
        #expect(store.transport.isRecording)
        // Pressed again while the take records: Stop.
        #expect(TransportRecordButtonModel.resolve(store: store, pressRefusal: nil).help
                == TransportRecordButtonModel.stopHelp)
        #expect(TransportRecordButtonModel.press(store) == nil)
        #expect(engine.stopRecordingCalls == 1)
    }
}
