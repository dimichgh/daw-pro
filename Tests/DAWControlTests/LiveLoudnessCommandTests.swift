import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Engine fake for `mixer.liveLoudness` (m22-c): a settable snapshot plus
/// reset bookkeeping — reset:true must reset THEN return the fresh (empty)
/// snapshot, which is exactly what the real engine's cache does.
@MainActor
private final class FakeLiveLoudnessEngine: AudioEngineControlling {
    var snapshot = LiveLoudnessSnapshot.empty
    private(set) var resetCount = 0
    private(set) var lastResetFlag: Bool?

    func liveLoudness(reset: Bool) -> LiveLoudnessSnapshot? {
        lastResetFlag = reset
        if reset {
            resetCount += 1
            snapshot = .empty
        }
        return snapshot
    }

    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false
    func prepare() throws {}
    func shutdown() {}
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
    func stopRecording() {}
}

/// Control-protocol coverage for m22-c `mixer.liveLoudness`: registration
/// (additive-at-END law), wire shape + nil-omission honesty, reset
/// semantics, unknown-key teaching, and the headless / no-capability
/// engineUnavailable path. The DSP truth behind the snapshot is proven by
/// DAWCoreTests (LRA fixtures + the offline-convergence gate) and the
/// engine wrapper by DAWEngineTests/LiveLoudnessAnalyzerTests.
@MainActor
@Suite("Live loudness — control protocol (m22-c)")
struct LiveLoudnessCommandTests {
    private func makeRouter(engine: FakeLiveLoudnessEngine? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    @Test("advertised at the END of allCommands (additive-at-end law); count 143 -> 144 (148 as of m22-g's reference.*)")
    func advertisedAtEnd() {
        #expect(CommandRouter.allCommands.contains("mixer.liveLoudness"))
        // m22-g's reference.* quartet appended after it — no longer LAST,
        // but the additive-at-end law held at ITS landing.
        #expect(CommandRouter.allCommands.count == 231)   // 159 -> 161 at m23-n3b -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w -> 166 at m23-af -> 168 at m20-j -> 169 at m23-br-1 -> 171 at m23-aj-2 -> 173 at m23-dl -> 174 at m23-di-2a -> 175 at m25-d -> 176 at m25-z -> 177 at m23-ap-3 -> 178 (clip.getNotes) -> 179 (m26-i instrument.describeSampler) -> 180 (edit.pasteClips) -> 181 (m27 leg D clip.applyBreathContour, placed next to its controller-lane siblings, NOT at the tail) -> 182 (breath pad P1 clip.applyEffortShape, placed next to clip.applyBreathContour, NOT at the tail) -> 183 (breath pad P6 pad.previewEffort, placed next to note.audition — the other 'sounds now, outside the timeline, not an edit' verb — NOT at the tail) -> 186 (m28-knob midi.getControlMap/setControlMap/learnControl, placed next to midi.listInputs — their only sibling on this surface — and BEFORE transport.record, NOT at the tail) -> 187 (m31-f instrument.probeLiveness) -> 188 (m31-c clip.repeatNotes, placed next to clip.setNotes/clip.getNotes, NOT at the tail) -> 189 (m26-a/m27-n clip.patchNotes, placed next to clip.repeatNotes, NOT at the tail) -> 190 (m32-b2 clip.sliceToSampler, placed next to clip.detectTransients/clip.quantizeAudio, NOT at the tail) -> 191 (m24-m leg A vc.convertClips, placed next to vc.convertVocals — its single-clip sibling — NOT at the tail) -> 193 (m24-n project.embeddedVoices next to project.snapshot/project.open, and vc.installEmbeddedVoice next to vc.importVoiceModel, both at the tail per the additive-at-end law) -> 194 (m23-ct note.play, placed next to note.audition/pad.previewEffort — the other 'sounds now, outside the timeline' verbs — NOT at the tail; a tail append reddened 19 end-relative assertions across 7 files on this item's first run) -> 195 (m23-cv chord.voice, a PURE read-only computation, placed next to note.play and NOT at the tail: LivePlayCommandTests pins note.play to pad.previewEffort + 1, so an insertion BEFORE it would redden that instead) -> 202 (m34-c instrument.listDownloadableSoundBanks/downloadSoundBank/soundBankDownloadStatus/cancelSoundBankDownload — the one-click SoundFont download, all four placed next to instrument.importSoundBank — their nearest sibling — and NOT at the tail, so every dropLast(N) window above stays true by construction; a tail placement was tried first and reddened 14 tests) -> 211 (m34-h-1 LIVE LOOPING looper.begin/armLayer/finishLayer/undoLayer/setLayerMuted/status/end, all seven placed immediately after transport.recordLayer/finishLayer — the verbs whose machinery the deck drives — and ~71 entries from the END, NOT at the tail, so every dropLast(N) window and suffix assertion above stays true by construction) -> 215 (M35 view.capture/view.selectClip/view.panelLayout/view.openEditor, the agent-facing VIEW surface, all four placed immediately after plugin.listOpenUIs and ~70 entries from the END, NOT at the tail) -> 218 (m39-f instrument.describeSynth, placed next to instrument.describeSampler, NOT at the tail) -> 231 at m39-dm (instrument.setDrumParam/describeDrumKit/listDrumPresets/loadDrumPreset — the drum machine's four verbs, placed next to instrument.describeSynth/describeSampler, their only siblings on this surface, and NOT at the tail, so every dropLast(N) window and suffix assertion stays true by construction)
        // -> 187 (m31-f instrument.probeLiveness, placed next to instrument.describeSampler — its read-only instrument.* sibling — NOT at the tail)
        // Additive: the mixer.* neighbors are untouched.
        #expect(CommandRouter.allCommands.contains("mixer.setMasterVolume"))
        #expect(CommandRouter.allCommands.contains("mixer.masterAnalysis"))
    }

    @Test("happy path: the engine snapshot rides the wire verbatim")
    func happyPath() async throws {
        let engine = FakeLiveLoudnessEngine()
        engine.snapshot = LiveLoudnessSnapshot(
            momentaryLufs: -18.5, shortTermLufs: -19.25, maxMomentaryLufs: -15,
            maxShortTermLufs: -16.5, integratedLufs: -20.125, loudnessRangeLu: 6.5,
            truePeakDbtp: -0.8, dcOffset: 0.001, crestFactorDb: 12.5,
            secondsAnalyzed: 42.5)
        let (router, _) = makeRouter(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness"))
        #expect(response.ok, "mixer.liveLoudness failed: \(response.error ?? "?")")
        #expect(response.result?["momentaryLufs"]?.doubleValue == -18.5)
        #expect(response.result?["shortTermLufs"]?.doubleValue == -19.25)
        #expect(response.result?["maxMomentaryLufs"]?.doubleValue == -15)
        #expect(response.result?["maxShortTermLufs"]?.doubleValue == -16.5)
        #expect(response.result?["integratedLufs"]?.doubleValue == -20.125)
        #expect(response.result?["loudnessRangeLu"]?.doubleValue == 6.5)
        #expect(response.result?["truePeakDbtp"]?.doubleValue == -0.8)
        #expect(response.result?["dcOffset"]?.doubleValue == 0.001)
        #expect(response.result?["crestFactorDb"]?.doubleValue == 12.5)
        #expect(response.result?["secondsAnalyzed"]?.doubleValue == 42.5)
        // Plain read: no reset happened.
        #expect(engine.resetCount == 0)
        #expect(engine.lastResetFlag == false)
    }

    @Test("nil fields are OMITTED on the wire (nil = no evidence, never 0)")
    func nilOmission() async throws {
        let engine = FakeLiveLoudnessEngine()
        engine.snapshot = LiveLoudnessSnapshot(truePeakDbtp: -12, secondsAnalyzed: 0.3)
        let (router, _) = makeRouter(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness"))
        #expect(response.ok)
        #expect(response.result?["truePeakDbtp"]?.doubleValue == -12)
        #expect(response.result?["secondsAnalyzed"]?.doubleValue == 0.3)
        // Warming up: no momentary/integrated/LRA keys AT ALL — an agent
        // must see absence, not a fabricated floor.
        #expect(response.result?["momentaryLufs"] == nil)
        #expect(response.result?["shortTermLufs"] == nil)
        #expect(response.result?["integratedLufs"] == nil)
        #expect(response.result?["loudnessRangeLu"] == nil)
    }

    @Test("reset:true resets THEN returns the fresh snapshot")
    func resetSemantics() async throws {
        let engine = FakeLiveLoudnessEngine()
        engine.snapshot = LiveLoudnessSnapshot(
            momentaryLufs: -10, integratedLufs: -12, secondsAnalyzed: 120)
        let (router, _) = makeRouter(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness",
            params: ["reset": .bool(true)]))
        #expect(response.ok)
        #expect(engine.resetCount == 1)
        #expect(engine.lastResetFlag == true)
        // The RESPONSE is the post-reset snapshot: empty, not the 120 s run.
        #expect(response.result?["secondsAnalyzed"]?.doubleValue == 0)
        #expect(response.result?["momentaryLufs"] == nil)
        #expect(response.result?["integratedLufs"] == nil)

        // reset:false is a plain read (no second reset).
        let read = await router.handle(ControlRequest(
            id: "2", command: "mixer.liveLoudness",
            params: ["reset": .bool(false)]))
        #expect(read.ok)
        #expect(engine.resetCount == 1)
    }

    @Test("unknown params are rejected with the teaching key list")
    func unknownKeysRejected() async throws {
        let (router, _) = makeRouter(engine: FakeLiveLoudnessEngine())
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness",
            params: ["restart": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'restart'") == true)
        #expect(response.error?.contains("'reset'") == true)
    }

    @Test("headless (no engine): the engineUnavailable teaching error, not a fake meter")
    func headlessTeachingError() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness"))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("an engine without live metering (protocol default nil) also refuses readably")
    func engineWithoutCapabilityRefuses() async throws {
        // An engine that does NOT override liveLoudness: the
        // AudioEngineControlling default returns nil and the store maps it
        // to the same teaching error — a live meter is never faked with
        // floors (`store.engine` is weak, so the fake is held locally).
        let store = ProjectStore()
        store.media = FakeMedia()
        let bare = BareEngine()
        store.engine = bare
        let router = CommandRouter(store: store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness"))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }
}

/// The minimal conformance: NO liveLoudness override, so the protocol
/// default (nil) is what the store sees.
@MainActor
private final class BareEngine: AudioEngineControlling {
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false
    func prepare() throws {}
    func shutdown() {}
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
    func stopRecording() {}
}
