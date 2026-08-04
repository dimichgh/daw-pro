import Foundation
import Testing
@testable import DAWCore

@Suite("Transport")
struct TransportTests {
    @Test("tempo clamps to valid range")
    func tempoClamping() {
        #expect(TransportState(tempoBPM: 5).tempoBPM == 20)
        #expect(TransportState(tempoBPM: 9999).tempoBPM == 400)
        #expect(TransportState(tempoBPM: 128).tempoBPM == 128)
    }

    @Test("bars.beats display is 1-based")
    func barsBeats() {
        var transport = TransportState()
        #expect(transport.barsBeatsDisplay == "1.1")
        transport.positionBeats = 4
        #expect(transport.barsBeatsDisplay == "2.1")
        transport.positionBeats = 6.5
        #expect(transport.barsBeatsDisplay == "2.3")
    }

    @Test("position in seconds follows tempo")
    func positionSeconds() {
        var transport = TransportState(tempoBPM: 120)
        transport.positionBeats = 4
        #expect(abs(transport.positionSeconds - 2.0) < 0.0001)
        transport.tempoBPM = 60
        #expect(abs(transport.positionSeconds - 4.0) < 0.0001)
    }

    @Test("loop fields round-trip through Codable")
    func loopCodable() throws {
        let transport = TransportState(isLoopEnabled: true, loopStartBeat: 8, loopEndBeat: 24)
        let data = try JSONEncoder().encode(transport)
        let decoded = try JSONDecoder().decode(TransportState.self, from: data)
        #expect(decoded == transport)
        #expect(decoded.isLoopEnabled)
        #expect(decoded.loopStartBeat == 8)
        #expect(decoded.loopEndBeat == 24)
    }

    @Test("loop end is sanitized to at least a quarter beat past start")
    func loopSanitize() {
        // Zero-length region opens up to the minimum length.
        #expect(TransportState(loopStartBeat: 4, loopEndBeat: 4).loopEndBeat == 4.25)
        // Inverted region is corrected relative to the start.
        #expect(TransportState(loopStartBeat: 10, loopEndBeat: 2).loopEndBeat == 10.25)
        // A valid region is left untouched.
        #expect(TransportState(loopStartBeat: 0, loopEndBeat: 16).loopEndBeat == 16)
    }

    @Test("punch fields round-trip through Codable")
    func punchCodable() throws {
        let transport = TransportState(isPunchEnabled: true, punchInBeat: 2, punchOutBeat: 6)
        let data = try JSONEncoder().encode(transport)
        let decoded = try JSONDecoder().decode(TransportState.self, from: data)
        #expect(decoded == transport)
        #expect(decoded.isPunchEnabled)
        #expect(decoded.punchInBeat == 2)
        #expect(decoded.punchOutBeat == 6)
    }

    @Test("punch out is sanitized to at least a quarter beat past punch in")
    func punchSanitize() {
        // Zero-length window opens up to the minimum length.
        #expect(TransportState(punchInBeat: 4, punchOutBeat: 4).punchOutBeat == 4.25)
        // Inverted window is corrected relative to the punch-in.
        #expect(TransportState(punchInBeat: 10, punchOutBeat: 2).punchOutBeat == 10.25)
        // A valid window is left untouched.
        #expect(TransportState(punchInBeat: 0, punchOutBeat: 16).punchOutBeat == 16)
        // Defaults: disabled, one bar at 4/4.
        let defaults = TransportState()
        #expect(!defaults.isPunchEnabled)
        #expect(defaults.punchInBeat == 0)
        #expect(defaults.punchOutBeat == 4)
    }

    @Test("metronome fields round-trip through Codable")
    func metronomeCodable() throws {
        let transport = TransportState(isMetronomeEnabled: true, countInBars: 2)
        let data = try JSONEncoder().encode(transport)
        let decoded = try JSONDecoder().decode(TransportState.self, from: data)
        #expect(decoded == transport)
        #expect(decoded.isMetronomeEnabled)
        #expect(decoded.countInBars == 2)
        // Defaults: click off, no count-in.
        let defaults = TransportState()
        #expect(!defaults.isMetronomeEnabled)
        #expect(defaults.countInBars == 0)
    }

    @Test("countInBars clamps to 0...4 on init")
    func countInBarsClamping() {
        #expect(TransportState(countInBars: -3).countInBars == 0)
        #expect(TransportState(countInBars: 9).countInBars == 4)
        #expect(TransportState(countInBars: 4).countInBars == 4)
        #expect(TransportState(countInBars: 1).countInBars == 1)
    }
}

@Suite("Track invariants")
struct TrackTests {
    @Test("volume and pan clamp on init")
    func clamping() {
        let track = Track(name: "T", volume: 99, pan: -7)
        #expect(track.volume == 2)
        #expect(track.pan == -1)
    }
}

@MainActor
@Suite("ProjectStore commands")
struct ProjectStoreTests {
    @Test("play and stop toggle transport")
    func playStop() {
        let store = ProjectStore()
        store.play()
        #expect(store.transport.isPlaying)
        store.stop()
        #expect(!store.transport.isPlaying)
    }

    @Test("add, mutate, and remove tracks")
    func trackLifecycle() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Drums", kind: .audio)
        #expect(store.tracks.count == 1)

        #expect(store.setTrackVolume(id: track.id, volume: 1.5))
        #expect(store.tracks[0].volume == 1.5)

        // Out-of-range values clamp rather than fail.
        #expect(store.setTrackVolume(id: track.id, volume: 10))
        #expect(store.tracks[0].volume == 2)
        #expect(store.setTrackPan(id: track.id, pan: -3))
        #expect(store.tracks[0].pan == -1)

        #expect(store.setTrackMute(id: track.id, muted: true))
        #expect(store.tracks[0].isMuted)

        #expect(try store.removeTrack(id: track.id))
        #expect(store.tracks.isEmpty)
        #expect(try !store.removeTrack(id: track.id))
    }

    @Test("default track names count per kind")
    func defaultNames() {
        let store = ProjectStore()
        #expect(store.addTrack(kind: .audio).name == "Audio 1")
        #expect(store.addTrack(kind: .audio).name == "Audio 2")
        #expect(store.addTrack(kind: .instrument).name == "Inst 1")
        #expect(store.addTrack(kind: .bus).name == "Bus 1")
    }

    @Test("rename rejects empty names")
    func renameValidation() {
        let store = ProjectStore()
        let track = store.addTrack()
        #expect(!store.renameTrack(id: track.id, name: ""))
        #expect(store.renameTrack(id: track.id, name: "Lead Vox"))
        #expect(store.tracks[0].name == "Lead Vox")
    }

    @Test("seek clamps to zero and setTempo clamps to range")
    func transportCommands() throws {
        let store = ProjectStore()
        try store.seek(toBeats: -5)
        #expect(store.transport.positionBeats == 0)
        try store.setTempo(1000)
        #expect(store.transport.tempoBPM == 400)
    }

    @Test("setLoop enables looping and stores the region")
    func setLoopHappyPath() throws {
        let store = ProjectStore()
        try store.setLoop(enabled: true, startBeat: 4, endBeat: 12)
        #expect(store.transport.isLoopEnabled)
        #expect(store.transport.loopStartBeat == 4)
        #expect(store.transport.loopEndBeat == 12)
    }

    @Test("setLoop keeps existing bounds when beats are nil")
    func setLoopKeepsExisting() throws {
        let store = ProjectStore()
        try store.setLoop(enabled: true, startBeat: 2, endBeat: 10)
        try store.setLoop(enabled: false)
        #expect(!store.transport.isLoopEnabled)
        #expect(store.transport.loopStartBeat == 2)
        #expect(store.transport.loopEndBeat == 10)
    }

    @Test("setLoop clamps a negative start to zero")
    func setLoopClampsStart() throws {
        let store = ProjectStore()
        try store.setLoop(enabled: true, startBeat: -5, endBeat: 8)
        #expect(store.transport.loopStartBeat == 0)
        #expect(store.transport.loopEndBeat == 8)
    }

    @Test("setLoop throws when end is not after start")
    func setLoopInvalidRange() {
        let store = ProjectStore()
        #expect(throws: ProjectError.self) {
            try store.setLoop(enabled: true, startBeat: 8, endBeat: 8)
        }
        #expect(throws: ProjectError.self) {
            try store.setLoop(enabled: true, startBeat: 8, endBeat: 4)
        }
        // A rejected call leaves the transport untouched (still disabled).
        #expect(!store.transport.isLoopEnabled)
    }

    @Test("setPunch enables the window and stores the bounds")
    func setPunchHappyPath() throws {
        let store = ProjectStore()
        try store.setPunch(enabled: true, inBeat: 4, outBeat: 12)
        #expect(store.transport.isPunchEnabled)
        #expect(store.transport.punchInBeat == 4)
        #expect(store.transport.punchOutBeat == 12)
    }

    @Test("setPunch keeps existing bounds when beats are nil")
    func setPunchKeepsExisting() throws {
        let store = ProjectStore()
        try store.setPunch(enabled: true, inBeat: 2, outBeat: 10)
        try store.setPunch(enabled: false)
        #expect(!store.transport.isPunchEnabled)
        #expect(store.transport.punchInBeat == 2)
        #expect(store.transport.punchOutBeat == 10)
    }

    @Test("setPunch clamps a negative punch-in to zero")
    func setPunchClampsIn() throws {
        let store = ProjectStore()
        try store.setPunch(enabled: true, inBeat: -5, outBeat: 8)
        #expect(store.transport.punchInBeat == 0)
        #expect(store.transport.punchOutBeat == 8)
    }

    @Test("setPunch throws the exact message when punch out is not after punch in")
    func setPunchInvalidRange() {
        let store = ProjectStore()
        do {
            try store.setPunch(enabled: true, inBeat: 8, outBeat: 8)
            Issue.record("expected invalidPunchRange")
        } catch let error as ProjectError {
            guard case .invalidPunchRange(let message) = error else {
                Issue.record("expected invalidPunchRange, got \(error)")
                return
            }
            #expect(message == "punch out must be after punch in")
            #expect(error.errorDescription == "punch out must be after punch in")
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(throws: ProjectError.self) {
            try store.setPunch(enabled: true, inBeat: 8, outBeat: 4)
        }
        // A rejected call leaves the transport untouched (still disabled).
        #expect(!store.transport.isPunchEnabled)
    }

    @Test("setMetronome toggles the click, clamps count-in, and nil keeps it")
    func setMetronomeHappyPath() throws {
        let store = ProjectStore()
        try store.setMetronome(enabled: true, countInBars: 2)
        #expect(store.transport.isMetronomeEnabled)
        #expect(store.transport.countInBars == 2)

        // nil count-in keeps the current value, so the UI chip can toggle
        // the click without re-stating the count-in.
        try store.setMetronome(enabled: false)
        #expect(!store.transport.isMetronomeEnabled)
        #expect(store.transport.countInBars == 2)

        // Out-of-range count-ins clamp rather than fail.
        try store.setMetronome(enabled: true, countInBars: 99)
        #expect(store.transport.countInBars == 4)
        try store.setMetronome(enabled: true, countInBars: -1)
        #expect(store.transport.countInBars == 0)
    }

    @Test("setMetronome while recording throws transportBusy with the exact message")
    func setMetronomeWhileRecording() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()

        do {
            try store.setMetronome(enabled: true, countInBars: 1)
            Issue.record("expected transportBusy")
        } catch let error as ProjectError {
            guard case .transportBusy(let message) = error else {
                Issue.record("expected transportBusy, got \(error)")
                return
            }
            #expect(message == "cannot change metronome while recording — stop first")
        }
        // A rejected call leaves the transport untouched.
        #expect(!store.transport.isMetronomeEnabled)
        #expect(store.transport.countInBars == 0)

        store.stop()
        try store.setMetronome(enabled: true)  // allowed again once stopped
        #expect(store.transport.isMetronomeEnabled)
    }

    @Test("setMasterVolume clamps to the track volume range")
    func masterVolumeClamping() {
        let store = ProjectStore()
        #expect(store.masterVolume == 1)  // unity by default
        store.setMasterVolume(3)
        #expect(store.masterVolume == 2)
        store.setMasterVolume(-1)
        #expect(store.masterVolume == 0)
        store.setMasterVolume(0.5)
        #expect(store.masterVolume == 0.5)
    }

    @Test("snapshot round-trips through Codable")
    func snapshotCodable() throws {
        let store = ProjectStore(projectName: "Demo")
        store.addTrack(name: "Bass")
        let snapshot = store.snapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.tracks.first?.name == "Bass")
    }

    @Test("snapshot carries the master volume")
    func snapshotMasterVolume() throws {
        let store = ProjectStore()
        #expect(store.snapshot().masterVolume == 1)  // default is unity
        store.setMasterVolume(0.75)
        let snapshot = store.snapshot()
        #expect(snapshot.masterVolume == 0.75)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        #expect(decoded.masterVolume == 0.75)
    }
}

/// Records every engine intent ProjectStore emits, so the store↔engine
/// contract is testable without AVFoundation. Internal (not private): the
/// mixdown suite in MixdownTests.swift shares it.
@MainActor
final class FakeEngine: AudioEngineControlling {
    enum Call: Equatable {
        case prepare
        case shutdown
        case tracksDidChange(count: Int)
        case startPlayback(beats: Double, tempo: Double)
        case stopPlayback
        case seek(beats: Double)
        case setTempo(bpm: Double)
        case loopChanged(enabled: Bool)
        case metronomeChanged(enabled: Bool)
        case masterVolume(Double)
        case renderMixdown(fromBeat: Double, durationSeconds: Double)
        case startRecording(beats: Double)
        case stopRecording
    }

    /// Everything a renderMixdown intent carried, for URL/parameter asserts.
    struct MixdownRequest {
        var tracks: [Track]
        var tempoMap: TempoMap
        var masterVolume: Double
        var fromBeat: Double
        var durationSeconds: Double
        var url: URL
    }

    private(set) var calls: [Call] = []
    private(set) var mixdownRequests: [MixdownRequest] = []
    var mixdownStub = AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?

    func clearCalls() { calls.removeAll() }

    func prepare() throws {
        isRunning = true
        calls.append(.prepare)
    }

    func shutdown() {
        isRunning = false
        calls.append(.shutdown)
    }

    func tracksDidChange(_ tracks: [Track]) {
        calls.append(.tracksDidChange(count: tracks.count))
    }

    /// Transient-detection stub (M5 iii-e/iii-f): configurable onsets and an
    /// optional error, plus a record of every request for spying.
    var detectTransientsStub: [TransientMarker] = []
    /// Per-URL onset stubs (M6 v-d): a URL with an entry here wins over
    /// `detectTransientsStub`, so take-alignment tests can feed the reference
    /// and candidate lanes DIFFERENT onset sets.
    var detectTransientsStubByURL: [URL: [TransientMarker]] = [:]
    var detectTransientsError: (any Error)?
    private(set) var detectTransientsCalls: [(url: URL, sensitivity: Double)] = []

    func detectTransients(inFileAt url: URL, sensitivity: Double) async throws -> [TransientMarker] {
        detectTransientsCalls.append((url, sensitivity))
        if let detectTransientsError { throw detectTransientsError }
        return detectTransientsStubByURL[url] ?? detectTransientsStub
    }

    /// Audio-content analysis stub (m21-e): configurable result + error and
    /// a request spy — the detectTransients stub pattern. A nil stub throws
    /// `engineUnavailable`, mirroring the protocol default's honesty rule
    /// (never fabricate an empty analysis).
    var analyzeAudioContentStub: AudioContentAnalysis?
    var analyzeAudioContentError: (any Error)?
    private(set) var analyzeAudioContentCalls:
        [(url: URL, windowStartSeconds: Double, windowDurationSeconds: Double)] = []

    func analyzeAudioContent(inFileAt url: URL, windowStartSeconds: Double,
                             windowDurationSeconds: Double) async throws -> AudioContentAnalysis {
        analyzeAudioContentCalls.append((url, windowStartSeconds, windowDurationSeconds))
        if let analyzeAudioContentError { throw analyzeAudioContentError }
        guard let analyzeAudioContentStub else { throw ProjectError.engineUnavailable }
        return analyzeAudioContentStub
    }

    func startPlayback(_ transport: TransportState) {
        calls.append(.startPlayback(beats: transport.positionBeats, tempo: transport.tempoBPM))
    }

    func stopPlayback() {
        calls.append(.stopPlayback)
    }

    func seek(_ transport: TransportState) {
        calls.append(.seek(beats: transport.positionBeats))
    }

    func setTempo(_ transport: TransportState) {
        calls.append(.setTempo(bpm: transport.tempoBPM))
    }

    func loopChanged(_ transport: TransportState) {
        calls.append(.loopChanged(enabled: transport.isLoopEnabled))
    }

    func metronomeChanged(_ transport: TransportState) {
        calls.append(.metronomeChanged(enabled: transport.isMetronomeEnabled))
    }

    func masterVolumeChanged(_ volume: Double) {
        calls.append(.masterVolume(volume))
    }

    /// Every master-chain publish the store emitted, newest last (m13-d):
    /// the master-chain suite asserts one push per mutation AND per
    /// restore-funnel crossing, each carrying the full post-edit chain.
    private(set) var masterEffectsPushes: [[EffectDescriptor]] = []

    func masterEffectsChanged(_ effects: [EffectDescriptor]) {
        masterEffectsPushes.append(effects)
    }

    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        calls.append(.renderMixdown(fromBeat: fromBeat, durationSeconds: durationSeconds))
        mixdownRequests.append(MixdownRequest(
            tracks: tracks, tempoMap: tempoMap, masterVolume: masterVolume,
            fromBeat: fromBeat, durationSeconds: durationSeconds, url: url
        ))
        return mixdownStub
    }

    var recordPermission: RecordPermission = .granted

    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }

    /// Configurable device list, mirroring what CoreAudio enumeration would
    /// report; `setInputDeviceCalls` records every ACCEPTED selection.
    var inputDevices: [AudioInputDevice] = []
    private(set) var setInputDeviceCalls: [String?] = []

    func availableInputDevices() -> [AudioInputDevice] { inputDevices }

    func setInputDevice(uid: String?) throws {
        if let uid, !inputDevices.contains(where: { $0.uid == uid }) {
            throw ProjectError.inputDeviceNotFound(uid)
        }
        setInputDeviceCalls.append(uid)
    }

    /// m20-j output twin. `outputDevices` is the raw hardware list;
    /// `availableOutputDevices()` stamps `isSelected` from the accepted
    /// selection the way `OutputDevices.enumerate(selectedUID:)` does, and
    /// `setOutputDeviceCalls` records every ACCEPTED selection (rejections are
    /// never recorded — the store must not advance its own state either).
    var outputDevices: [AudioOutputDevice] = []
    private(set) var setOutputDeviceCalls: [String?] = []
    private var selectedOutputUID: String?

    func availableOutputDevices() -> [AudioOutputDevice] {
        outputDevices.map {
            var device = $0
            device.isSelected = selectedOutputUID != nil && $0.uid == selectedOutputUID
            return device
        }
    }

    func setOutputDevice(uid: String?) throws {
        if let uid, !outputDevices.contains(where: { $0.uid == uid }) {
            throw ProjectError.outputDeviceNotFound(uid)
        }
        setOutputDeviceCalls.append(uid)
        selectedOutputUID = uid
    }

    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        calls.append(.startRecording(beats: transport.positionBeats))
    }

    func stopRecording() {
        calls.append(.stopRecording)
    }

    /// Note-audition spy (m23-d): every `setAuditionPitches` intent in order —
    /// including the heartbeat re-asserts, whose pitch set is unchanged. The
    /// stub lets a test drive the `noRenderer` / `inaudible*` branches.
    private(set) var auditionCalls: [(trackID: UUID, pitches: [UInt8], velocity: UInt8)] = []
    private(set) var stopAllAuditionCount = 0
    var auditionOutcomeStub: AuditionOutcome = .sounded

    func setAuditionPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8) -> AuditionOutcome {
        auditionCalls.append((trackID, pitches, velocity))
        return pitches.isEmpty ? .sounded : auditionOutcomeStub
    }

    func stopAllAudition() {
        stopAllAuditionCount += 1
    }

    func clearAuditionCalls() {
        auditionCalls.removeAll()
        stopAllAuditionCount = 0
    }
}

@MainActor
@Suite("ProjectStore ↔ engine intents")
struct EngineIntentTests {
    @Test("play sends prepare + one startPlayback with current beats and tempo")
    func playIntent() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        try store.seek(toBeats: 4)
        try store.setTempo(90)
        engine.clearCalls()

        store.play()

        #expect(engine.calls == [.prepare, .startPlayback(beats: 4, tempo: 90)])
        #expect(store.transport.isPlaying)
    }

    @Test("stop sends stopPlayback")
    func stopIntent() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        store.play()
        engine.clearCalls()

        store.stop()

        #expect(engine.calls == [.stopPlayback])
        #expect(!store.transport.isPlaying)
    }

    @Test("seek while playing forwards clamped beats")
    func seekIntent() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        store.play()
        engine.clearCalls()

        try store.seek(toBeats: -3)

        #expect(engine.calls == [.seek(beats: 0)])
        #expect(store.transport.positionBeats == 0)
    }

    @Test("setTempo forwards clamped BPM")
    func tempoIntent() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        engine.clearCalls()

        try store.setTempo(1000)

        #expect(engine.calls == [.setTempo(bpm: 400)])
        #expect(store.transport.tempoBPM == 400)
    }

    @Test("setLoop forwards a loopChanged intent")
    func loopChangedIntent() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        engine.clearCalls()

        try store.setLoop(enabled: true, startBeat: 0, endBeat: 8)

        #expect(engine.calls == [.loopChanged(enabled: true)])
        #expect(store.transport.isLoopEnabled)
    }

    @Test("a rejected setLoop sends no engine intent")
    func loopRejectionSendsNoIntent() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        engine.clearCalls()

        #expect(throws: ProjectError.self) {
            try store.setLoop(enabled: true, startBeat: 8, endBeat: 4)
        }
        #expect(engine.calls.isEmpty)
    }

    @Test("setMasterVolume forwards the clamped gain")
    func masterVolumeIntent() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        engine.clearCalls()

        store.setMasterVolume(3)
        store.setMasterVolume(-1)

        #expect(engine.calls == [.masterVolume(2), .masterVolume(0)])
        #expect(store.masterVolume == 0)
    }

    @Test("setMetronome while playing sends the click-player-local intent — never seek/restart (m14-c)")
    func metronomeIntentWhilePlaying() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        store.play()
        engine.playheadHandler?(3.5)
        engine.clearCalls()

        try store.setMetronome(enabled: true)

        // The retired pre-m14-c fallback was `.seek(beats: 3.5)` (a transport
        // restart with its ~60 ms seam). The toggle is now click-player-local:
        // exactly one metronomeChanged intent, and NO seek in the call log.
        #expect(engine.calls == [.metronomeChanged(enabled: true)])
        #expect(store.transport.isMetronomeEnabled)

        try store.setMetronome(enabled: false)
        #expect(engine.calls == [.metronomeChanged(enabled: true),
                                 .metronomeChanged(enabled: false)])
    }

    @Test("setMetronome while stopped sends no engine intent")
    func metronomeNoIntentWhileStopped() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        engine.clearCalls()

        try store.setMetronome(enabled: true, countInBars: 3)

        // The engine reads TransportState at the next start — nothing to send.
        #expect(engine.calls.isEmpty)
        #expect(store.transport.isMetronomeEnabled)
        #expect(store.transport.countInBars == 3)
    }

    @Test("playhead pushes update the transport with NO engine callback")
    func playheadLoopPrevention() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        engine.clearCalls()

        engine.playheadHandler?(3.25)

        #expect(store.transport.positionBeats == 3.25)
        #expect(engine.calls.isEmpty)  // loop-prevention regression guard
    }

    @Test("no engine: the display ticker still advances the playhead")
    func tickerFallback() async throws {
        let store = ProjectStore()
        store.play()
        // Poll for progress rather than assuming a fixed window: the fallback
        // ticker advances on ~33 ms main-actor hops, which can be starved when
        // many @MainActor suites run in parallel. Each sleep yields the actor,
        // giving the ticker a chance to run, up to a ~1 s ceiling.
        var waited = 0
        while store.transport.positionBeats == 0 && waited < 50 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        store.stop()
        #expect(store.transport.positionBeats > 0)
    }
}

@MainActor
@Suite("Input device selection")
struct InputDeviceSelectionTests {
    private let mic = AudioInputDevice(
        uid: "mic-1", name: "Built-in Mic", sampleRate: 48_000, channelCount: 1, isDefault: true
    )
    private let interface = AudioInputDevice(
        uid: "usb-2", name: "Scarlett 2i2", sampleRate: 44_100, channelCount: 2, isDefault: false
    )

    @Test("listInputDevices is empty headless and mirrors the engine's list")
    func listDevices() {
        let store = ProjectStore()
        #expect(store.listInputDevices().isEmpty)  // no engine → no devices

        let engine = FakeEngine()
        engine.inputDevices = [mic, interface]
        store.engine = engine
        #expect(store.listInputDevices().map(\.uid) == ["mic-1", "usb-2"])
    }

    @Test("selectInputDevice stores the uid, forwards to the engine, nil resets")
    func selectHappyPath() throws {
        let engine = FakeEngine()
        engine.inputDevices = [mic, interface]
        let store = ProjectStore()
        store.engine = engine

        #expect(store.selectedInputDeviceUID == nil)  // default: system default
        try store.selectInputDevice(uid: "usb-2")
        #expect(store.selectedInputDeviceUID == "usb-2")
        try store.selectInputDevice(uid: nil)
        #expect(store.selectedInputDeviceUID == nil)
        #expect(engine.setInputDeviceCalls == ["usb-2", nil])
    }

    @Test("unknown-uid errors pass through and leave the selection untouched")
    func selectUnknownUID() throws {
        let engine = FakeEngine()
        engine.inputDevices = [mic]
        let store = ProjectStore()
        store.engine = engine
        try store.selectInputDevice(uid: "mic-1")

        do {
            try store.selectInputDevice(uid: "ghost")
            Issue.record("expected inputDeviceNotFound")
        } catch let error as ProjectError {
            guard case .inputDeviceNotFound(let uid) = error else {
                Issue.record("expected inputDeviceNotFound, got \(error)")
                return
            }
            #expect(uid == "ghost")
            #expect(error.errorDescription
                    == "no input device with uid 'ghost' — use input.listDevices")
        }
        #expect(store.selectedInputDeviceUID == "mic-1")  // only updated on success
        #expect(engine.setInputDeviceCalls == ["mic-1"])  // rejection never recorded
    }

    @Test("selectInputDevice while recording throws transportBusy with the exact message")
    func selectWhileRecording() throws {
        let engine = FakeEngine()
        engine.inputDevices = [mic, interface]
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()

        do {
            try store.selectInputDevice(uid: "usb-2")
            Issue.record("expected transportBusy")
        } catch let error as ProjectError {
            guard case .transportBusy(let message) = error else {
                Issue.record("expected transportBusy, got \(error)")
                return
            }
            #expect(message == "cannot switch input device while recording — stop first")
        }
        #expect(store.selectedInputDeviceUID == nil)  // untouched
        #expect(engine.setInputDeviceCalls.isEmpty)   // never reached the engine

        store.stop()
        try store.selectInputDevice(uid: "usb-2")  // allowed again
        #expect(store.selectedInputDeviceUID == "usb-2")
    }

    @Test("snapshot round-trips selectedInputDeviceUID; missing key decodes nil")
    func snapshotRoundTrip() throws {
        let engine = FakeEngine()
        engine.inputDevices = [mic]
        let store = ProjectStore()
        store.engine = engine

        // Default (nil) round-trips, and its encoded form omits the key —
        // which doubles as the older-snapshot decode check.
        let defaultSnapshot = store.snapshot()
        #expect(defaultSnapshot.selectedInputDeviceUID == nil)
        let defaultData = try JSONEncoder().encode(defaultSnapshot)
        let defaultObject = try JSONSerialization.jsonObject(with: defaultData) as? [String: Any]
        #expect(defaultObject?["selectedInputDeviceUID"] == nil)
        #expect(try JSONDecoder().decode(ProjectSnapshot.self, from: defaultData)
                    .selectedInputDeviceUID == nil)

        try store.selectInputDevice(uid: "mic-1")
        let snapshot = store.snapshot()
        #expect(snapshot.selectedInputDeviceUID == "mic-1")
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.selectedInputDeviceUID == "mic-1")
    }
}

/// A conformer that implements NOTHING of the m20-j output surface, so it
/// picks up the `AudioEngineControlling` extension defaults. Deliberately
/// separate from `FakeEngine` (which DOES override them): this exists to pin
/// what an engine with no output capability at all does, and it would stop
/// doing that the moment it gained an override.
@MainActor
final class MinimalOutputCapabilityEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

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
}

@MainActor
@Suite("Output device selection (m20-j)")
struct OutputDeviceSelectionTests {
    private let speakers = AudioOutputDevice(
        uid: "builtin-speakers", name: "MacBook Pro Speakers", sampleRate: 48_000,
        channelCount: 2, isDefault: true
    )
    private let loopback = AudioOutputDevice(
        uid: "BlackHole2ch_UID", name: "BlackHole 2ch", sampleRate: 44_100,
        channelCount: 2, isDefault: false
    )

    private func fixture() -> (ProjectStore, FakeEngine) {
        let engine = FakeEngine()
        engine.outputDevices = [speakers, loopback]
        let store = ProjectStore()
        store.engine = engine
        return (store, engine)
    }

    @Test("listOutputDevices is empty headless and mirrors the engine's list")
    func listDevices() {
        let store = ProjectStore()
        #expect(store.listOutputDevices().isEmpty)  // no engine → no devices

        // `store.engine` is WEAK — the engine binding must stay alive to the
        // end of the test or the store silently goes headless and every
        // assertion below reads [] (which is exactly what happened first try).
        let (withEngine, engine) = fixture()
        #expect(withEngine.listOutputDevices().map(\.uid)
                == ["builtin-speakers", "BlackHole2ch_UID"])
        withExtendedLifetime(engine) {}
    }

    @Test("selectOutputDevice stores the uid, forwards to the engine, nil resets")
    func selectHappyPath() throws {
        let (store, engine) = fixture()

        #expect(store.selectedOutputDeviceUID == nil)  // default: system default
        try store.selectOutputDevice(uid: "BlackHole2ch_UID")
        #expect(store.selectedOutputDeviceUID == "BlackHole2ch_UID")
        try store.selectOutputDevice(uid: nil)
        #expect(store.selectedOutputDeviceUID == nil)
        #expect(engine.setOutputDeviceCalls == ["BlackHole2ch_UID", nil])
    }

    /// The distinction the input side does not have to make: `isDefault` is the
    /// SYSTEM's output, `isSelected` is this app's pin, and "following the
    /// default" is NOT the same state as "pinned to the device that is
    /// currently the default". A picker that cannot tell those apart shows the
    /// wrong thing the moment the user changes their system default.
    @Test("isSelected tracks the app's pin and is independent of isDefault")
    func selectedIsDistinctFromDefault() throws {
        // `store.engine` is weak — keep `engine` bound (see `listDevices`).
        let (store, engine) = fixture()
        defer { withExtendedLifetime(engine) {} }

        // Following the system default: NO device is selected, even though one
        // of them IS the default.
        let following = store.listOutputDevices()
        #expect(following.filter(\.isSelected).isEmpty)
        #expect(following.filter(\.isDefault).map(\.uid) == ["builtin-speakers"])

        // Pinned to a NON-default device: the two flags land on different rows.
        try store.selectOutputDevice(uid: "BlackHole2ch_UID")
        let pinned = store.listOutputDevices()
        #expect(pinned.filter(\.isSelected).map(\.uid) == ["BlackHole2ch_UID"])
        #expect(pinned.filter(\.isDefault).map(\.uid) == ["builtin-speakers"])

        // Explicitly pinned to the device that IS the default: both flags on
        // the same row — and crucially NOT the same as `following` above.
        try store.selectOutputDevice(uid: "builtin-speakers")
        let pinnedToDefault = store.listOutputDevices()
        #expect(pinnedToDefault.filter(\.isSelected).map(\.uid) == ["builtin-speakers"])
        #expect(pinnedToDefault.filter(\.isDefault).map(\.uid) == ["builtin-speakers"])
        #expect(pinnedToDefault != following,
                "pinned-to-the-default must be distinguishable from following-the-default")
    }

    @Test("unknown-uid errors pass through and leave the selection untouched")
    func selectUnknownUID() throws {
        let (store, engine) = fixture()
        try store.selectOutputDevice(uid: "BlackHole2ch_UID")

        do {
            try store.selectOutputDevice(uid: "ghost")
            Issue.record("expected outputDeviceNotFound")
        } catch let error as ProjectError {
            guard case .outputDeviceNotFound(let uid) = error else {
                Issue.record("expected outputDeviceNotFound, got \(error)")
                return
            }
            #expect(uid == "ghost")
            #expect(error.errorDescription
                    == "no output device with uid 'ghost' — use output.listDevices")
        }
        // Only updated on success — the pin survives the rejection.
        #expect(store.selectedOutputDeviceUID == "BlackHole2ch_UID")
        #expect(engine.setOutputDeviceCalls == ["BlackHole2ch_UID"])
    }

    @Test("selectOutputDevice while recording throws transportBusy with the exact message")
    func selectWhileRecording() throws {
        let (store, engine) = fixture()
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()

        do {
            try store.selectOutputDevice(uid: "BlackHole2ch_UID")
            Issue.record("expected transportBusy")
        } catch let error as ProjectError {
            guard case .transportBusy(let message) = error else {
                Issue.record("expected transportBusy, got \(error)")
                return
            }
            #expect(message == "cannot switch output device while recording — stop first")
        }
        #expect(store.selectedOutputDeviceUID == nil)   // untouched
        #expect(engine.setOutputDeviceCalls.isEmpty)    // never reached the engine

        store.stop()
        try store.selectOutputDevice(uid: "BlackHole2ch_UID")  // allowed again
        #expect(store.selectedOutputDeviceUID == "BlackHole2ch_UID")
    }

    @Test("snapshot round-trips selectedOutputDeviceUID; missing key decodes nil")
    func snapshotRoundTrip() throws {
        // `store.engine` is weak — keep `engine` bound (see `listDevices`).
        // This test passed even without it, because the store records the uid
        // whether or not an engine is attached; binding it keeps the test
        // honest about which path it is exercising.
        let (store, engine) = fixture()
        defer { withExtendedLifetime(engine) {} }

        // Default (nil) round-trips, and its encoded form OMITS the key — a
        // pre-m20-j snapshot stays byte-identical, and an old snapshot still
        // decodes.
        let defaultSnapshot = store.snapshot()
        #expect(defaultSnapshot.selectedOutputDeviceUID == nil)
        let defaultData = try JSONEncoder().encode(defaultSnapshot)
        let defaultObject = try JSONSerialization.jsonObject(with: defaultData) as? [String: Any]
        #expect(defaultObject?["selectedOutputDeviceUID"] == nil)
        #expect(try JSONDecoder().decode(ProjectSnapshot.self, from: defaultData)
                    .selectedOutputDeviceUID == nil)

        try store.selectOutputDevice(uid: "BlackHole2ch_UID")
        let snapshot = store.snapshot()
        #expect(snapshot.selectedOutputDeviceUID == "BlackHole2ch_UID")
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.selectedOutputDeviceUID == "BlackHole2ch_UID")
    }

    /// `outputDeviceNotApplied` is thrown by the AUHAL read-back guard — the
    /// m20-b "AudioUnitSetProperty returns noErr on a write the unit
    /// DISCARDED" defence. Staging a device that accepts the write and
    /// discards it is not something a test can arrange, so what IS pinned here
    /// is the wording (it reaches the wire and the MCP surface verbatim) and
    /// the fact that the case carries the offending uid.
    @Test("outputDeviceNotApplied names the device and points at the list verb")
    func notAppliedMessage() {
        let error = ProjectError.outputDeviceNotApplied("BlackHole2ch_UID")
        #expect(error.errorDescription
                == "output device 'BlackHole2ch_UID' would not accept the selection — "
                + "it may have been unplugged; use output.listDevices")
    }

    /// The protocol default (`AudioEngineControlling` extension) must REFUSE a
    /// uid rather than silently succeed: an engine with no output AUHAL cannot
    /// pin anything, and a silent success would let a caller believe a
    /// selection took effect.
    @Test("the optional-capability default refuses a uid and accepts nil")
    func optionalCapabilityDefault() throws {
        // A conformer that implements NOTHING of the output surface — it picks
        // up the extension defaults.
        let engine = MinimalOutputCapabilityEngine()
        #expect(engine.availableOutputDevices().isEmpty)
        try engine.setOutputDevice(uid: nil)  // trivially satisfied
        #expect {
            try engine.setOutputDevice(uid: "anything")
        } throws: { error in
            (error as? LocalizedError)?.errorDescription
                == "no output device with uid 'anything' — use output.listDevices"
        }
    }
}

@MainActor
@Suite("Per-track metering")
struct TrackMeteringTests {
    @Test("engine pushes land in trackMeters keyed by track ID")
    func trackMeterPushes() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Drums")

        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.8, rms: 0.5))

        #expect(store.trackMeters[track.id] == MeterFrame(peak: 0.8, rms: 0.5))
    }

    @Test("stop resets every track meter and the master meter to silence, keeping keys")
    func stopResetsMeters() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Drums")
        store.play()
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.8, rms: 0.5))
        engine.meteringHandler?(MeterFrame(peak: 0.9, rms: 0.6))

        store.stop()

        #expect(store.trackMeters.keys.contains(track.id))  // key survives
        #expect(store.trackMeters[track.id] == .silence)
        #expect(store.masterMeter == .silence)
    }

    @Test("removeTrack drops the track's meter entry")
    func removeTrackDropsMeter() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Drums")
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.4, rms: 0.2))
        #expect(store.trackMeters[track.id] != nil)

        try store.removeTrack(id: track.id)

        #expect(store.trackMeters[track.id] == nil)
    }

    @Test("snapshot meters round-trip through Codable with uuidString keys")
    func snapshotMetersCodable() throws {
        let engine = FakeEngine()
        let store = ProjectStore(projectName: "Demo")
        store.engine = engine
        let track = store.addTrack(name: "Bass")
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.75, rms: 0.5))
        engine.meteringHandler?(MeterFrame(peak: 0.9, rms: 0.7))

        let snapshot = store.snapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProjectSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.meters.master == MeterFrame(peak: 0.9, rms: 0.7))
        #expect(decoded.meters.tracks[track.id.uuidString] == MeterFrame(peak: 0.75, rms: 0.5))

        // String keys are deliberate: the wire shape must be a JSON object
        // keyed by uuidString (a [UUID:] dictionary would encode as an array).
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let meters = object?["meters"] as? [String: Any]
        let tracksDict = meters?["tracks"] as? [String: Any]
        #expect(tracksDict?.keys.contains(track.id.uuidString) == true)
    }
}
