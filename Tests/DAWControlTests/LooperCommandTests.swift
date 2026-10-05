import DAWControl
import Foundation
import Testing
@testable import DAWCore

/// m34-h-1 LIVE LOOPING — the wire taxonomy for the seven `looper.*` verbs.
///
/// ⭐ **WHY THIS SUITE EXISTS:** six of the seven are excluded from
/// `ControlTests`' every-command routing loop, each for a reason that is the
/// verb WORKING (a session cannot open over that loop's rolling take; two need
/// ids a params-free loop cannot supply; three correctly refuse with no session
/// open). Excluding six live verbs without a replacement would leave them with
/// no route coverage at all. This is that replacement.
///
/// ⚠️ **THE SPY ENGINE HERE DOES IMPLEMENT THE KEEP-PLAYING CLOSE**, which the
/// bare router's `FakeEngine` deliberately does not. So this suite proves the
/// STORE and the WIRE and proves nothing about the real engine —
/// `DAWEngineTests/LiveLayerCaptureTests` closes that half.
@MainActor
@Suite("Looper commands — the loop deck over the wire (m34-h-1)")
struct LooperCommandTests {

    @MainActor
    private final class DeckSpyEngine: AudioEngineControlling {
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var isRunning = true

        private var pending: [@MainActor (Result<TakeResult, Error>) -> Void] = []
        private(set) var layerStarts = 0
        private(set) var keepPlayingCloses = 0
        private(set) var stopPlaybackCalls = 0
        private(set) var stopRecordingCalls = 0

        func prepare() throws {}
        func shutdown() {}
        func tracksDidChange(_ tracks: [Track]) {}
        func startPlayback(_ transport: TransportState) {}
        func stopPlayback() { stopPlaybackCalls += 1 }
        func seek(_ transport: TransportState) {}
        func setTempo(_ transport: TransportState) {}
        func loopChanged(_ transport: TransportState) {}
        func masterVolumeChanged(_ volume: Double) {}
        func setEndStop(beat: Double?) {}
        var recordPermission: RecordPermission { .granted }
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func setInputDevice(uid: String?) throws {}
        func availableMIDIInputs() -> [MIDIInputDevice] { [] }
        func midiEventCount() -> Int { 0 }
        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL) async throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
        }
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
        func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                       completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
            pending.append(completion)
        }
        func startTakeInPlayback(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                                 completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
            layerStarts += 1
            pending.append(completion)
        }
        func finishTakeKeepingPlayback() -> Bool {
            guard !pending.isEmpty else { return false }
            keepPlayingCloses += 1
            return true
        }
        func stopRecording() { stopRecordingCalls += 1 }

        /// Delivers the oldest outstanding take, carrying notes at the given
        /// CLIP-RELATIVE beats.
        func deliver(notesAt beats: [Double], pitch: Int = 64) {
            guard !pending.isEmpty else { return }
            let completion = pending.removeFirst()
            completion(.success(TakeResult(
                midi: MIDIRecordingResult(
                    notes: beats.map { MIDINote(pitch: pitch, velocity: 100,
                                                startBeat: $0, lengthBeats: 0.5) },
                    lengthBeats: 8))))
        }
    }

    private func fixture() throws -> (CommandRouter, ProjectStore, DeckSpyEngine, Track, Track) {
        let engine = DeckSpyEngine()
        let store = ProjectStore(projectName: "m34-h-1 wire deck")
        store.engine = engine
        let chords = store.addTrack(name: "Chords", kind: .instrument)
        let bass = store.addTrack(name: "Bass", kind: .instrument)
        return (CommandRouter(store: store), store, engine, chords, bass)
    }

    private func send(_ router: CommandRouter, _ command: String,
                      _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await router.handle(ControlRequest(id: command, command: command, params: params))
    }

    /// Pushes the playhead through the engine's own handler and applies what the
    /// deck's schedule says is due. See `LoopDeckStoreTests.tick` for why the
    /// apply is synchronous rather than awaited.
    private func tick(_ store: ProjectStore, _ engine: DeckSpyEngine, to beat: Double) {
        engine.playheadHandler?(beat)
        store.applyDueDeckActions()
    }

    // MARK: - Registration

    @Test("all seven verbs are registered exactly once, in order after transport.finishLayer, and NOT at the tail")
    func registration() throws {
        let verbs = ["looper.begin", "looper.armLayer", "looper.finishLayer",
                     "looper.undoLayer", "looper.setLayerMuted", "looper.status", "looper.end"]
        for verb in verbs {
            #expect(CommandRouter.allCommands.filter { $0 == verb }.count == 1, "\(verb)")
        }
        // ⚠️ THE PLACEMENT IS PINNED, not incidental. A tail append broke 80
        // assertions across 22 tests at m27 leg D while every filtered run
        // stayed green.
        let anchor = try #require(CommandRouter.allCommands.firstIndex(of: "transport.finishLayer"))
        let indices = try verbs.map { try #require(CommandRouter.allCommands.firstIndex(of: $0)) }
        #expect(indices == Array((anchor + 1)...(anchor + 7)))
        // Far from the end, so every end-relative assertion in the tree stays
        // true by construction. MEASURED off the array, not copied.
        #expect(CommandRouter.allCommands.count - indices.last! > 50)
    }

    @Test("looper.status answers null when no session is open — a read that never lies about a deck that is not there")
    func statusIsNullWithoutASession() async throws {
        let (router, _, _, _, _) = try fixture()
        let r = await send(router, "looper.status")
        #expect(r.ok, "\(r.error ?? "nil")")
        #expect(r.result == .null)
    }

    // MARK: - Parameter taxonomy

    @Test("unknown keys are refused on every looper verb")
    func unknownKeysRefused() async throws {
        let (router, _, _, track, _) = try fixture()
        for (verb, params) in [
            ("looper.begin", ["bogus": JSONValue.bool(true)]),
            ("looper.armLayer", ["trackId": .string(track.id.uuidString), "bogus": .bool(true)]),
            ("looper.finishLayer", ["bogus": JSONValue.bool(true)]),
            ("looper.undoLayer", ["bogus": JSONValue.bool(true)]),
            ("looper.status", ["bogus": JSONValue.bool(true)]),
            ("looper.end", ["bogus": JSONValue.bool(true)]),
        ] {
            let r = await send(router, verb, params)
            #expect(!r.ok, "\(verb)")
            #expect(r.error?.contains("bogus") == true, "\(verb): \(r.error ?? "nil")")
        }
    }

    @Test("a bad quantize or mode names the valid values instead of failing silently")
    func enumsTeach() async throws {
        let (router, _, _, _, _) = try fixture()
        var r = await send(router, "looper.begin", ["quantize": .string("sometimes")])
        #expect(!r.ok)
        #expect(r.error?.contains("cycle") == true, "\(r.error ?? "nil")")
        r = await send(router, "looper.begin", ["mode": .string("sideways")])
        #expect(!r.ok)
        #expect(r.error?.contains("overdub") == true, "\(r.error ?? "nil")")
    }

    @Test("⛔ looper.begin REFUSES while the transport loop is enabled, and the message names the other feature")
    func beginRefusesTheTransportLoop() async throws {
        let (router, _, _, _, _) = try fixture()
        var r = await send(router, "transport.setLoop",
                           ["enabled": .bool(true), "startBeat": .number(0), "endBeat": .number(8)])
        #expect(r.ok, "\(r.error ?? "nil")")
        r = await send(router, "looper.begin", ["bars": .number(4)])
        #expect(!r.ok)
        // The refusal must TEACH: this tree already ships loop-cycle TAKE
        // recording, and reading it as live looping builds the wrong feature.
        #expect(r.error?.contains("take-comping") == true, "\(r.error ?? "nil")")
    }

    @Test("looper.armLayer refuses an audio track — v1 tiles MIDI, and a waveform cannot be tiled inside one clip")
    func armRefusesAudio() async throws {
        let (router, store, _, _, _) = try fixture()
        let audio = store.addTrack(name: "Vox", kind: .audio)
        _ = await send(router, "transport.play")
        let begun = await send(router, "looper.begin", ["bars": .number(1)])
        #expect(begun.ok, "\(begun.error ?? "nil")")
        let r = await send(router, "looper.armLayer", ["trackId": .string(audio.id.uuidString)])
        #expect(!r.ok)
    }

    // MARK: - The item over the wire

    @Test("⭐⭐ THE ITEM OVER THE WIRE: two layers stacked, aligned, with transport.stop sent ZERO times")
    func twoLayersStackedWithoutEverStopping() async throws {
        let (router, store, engine, chords, bass) = try fixture()
        var sent: [String] = []
        func go(_ command: String, _ params: [String: JSONValue] = [:]) async -> ControlResponse {
            sent.append(command)
            return await send(router, command, params)
        }

        var r = await go("transport.play")
        #expect(r.ok, "\(r.error ?? "nil")")
        r = await go("looper.begin", ["bars": .number(1)])          // a 4-beat cycle
        #expect(r.ok, "\(r.error ?? "nil")")
        #expect(r.result?["cycleBeats"]?.doubleValue == 4)
        #expect(r.result?["lengthMode"]?.stringValue == "fixedBars")

        // ---- Layer 1 on Chords.
        r = await go("looper.armLayer", ["trackId": .string(chords.id.uuidString)])
        #expect(r.ok, "\(r.error ?? "nil")")
        #expect(r.result?["pendingPhase"]?.stringValue == "queued")
        let launch1 = try #require(r.result?["pendingLaunchBeat"]?.doubleValue)
        #expect(launch1 == 4)                                        // the bar after the pre-roll
        tick(store, engine, to: 3)                                   // the take opens at the arm beat
        #expect(engine.layerStarts == 1)
        tick(store, engine, to: 7.5)
        r = await go("looper.finishLayer")
        #expect(r.ok, "\(r.error ?? "nil")")
        tick(store, engine, to: 8)
        #expect(engine.keepPlayingCloses == 1)
        // Played on the downbeat of the layer and two beats later. The take
        // began at beat 3, so those are 1 and 3 clip-relative.
        engine.deliver(notesAt: [1, 3], pitch: 60)

        // ---- Layer 2 on Bass, several cycles later, WITHOUT STOPPING.
        r = await go("looper.armLayer", ["trackId": .string(bass.id.uuidString)])
        #expect(r.ok, "\(r.error ?? "nil")")
        let launch2 = try #require(r.result?["pendingLaunchBeat"]?.doubleValue)
        #expect(launch2 == 12)                                       // a different cycle entirely
        tick(store, engine, to: 11)
        tick(store, engine, to: 15.5)
        r = await go("looper.finishLayer")
        #expect(r.ok, "\(r.error ?? "nil")")
        tick(store, engine, to: 16)
        engine.deliver(notesAt: [1, 3], pitch: 40)

        // ---- ⭐ THE PROOF, read back out of the model rather than off a
        // command's return value.
        let chordsClips = try #require(store.tracks.first { $0.id == chords.id }?.clips)
        let bassClips = try #require(store.tracks.first { $0.id == bass.id }?.clips)
        #expect(chordsClips.count == 1)
        #expect(bassClips.count == 1)
        // ⭐⭐ ALIGNMENT: both layers' onsets sit at the SAME positions within
        // the cycle, though they were recorded two cycles apart. A
        // quantized-launch bug looks exactly like "it works" until this is
        // measured.
        #expect(chordsClips[0].startBeat == 4)
        #expect(bassClips[0].startBeat == 4)
        let chordOnsets = chordsClips[0].notes!.prefix(4).map(\.startBeat)
        let bassOnsets = bassClips[0].notes!.prefix(4).map(\.startBeat)
        #expect(chordOnsets == [0, 2, 4, 6])
        #expect(bassOnsets == [0, 2, 4, 6])

        // ---- ⭐ AND THE MUSIC NEVER STOPPED.
        #expect(!sent.contains("transport.stop"))
        #expect(sent.filter { $0 == "transport.play" }.count == 1)
        #expect(engine.stopPlaybackCalls == 0)
        #expect(engine.stopRecordingCalls == 0)
        #expect(store.transport.isPlaying)

        // ---- ⭐⭐ PEEL THE LAST LAYER, STILL WITHOUT STOPPING.
        r = await go("looper.undoLayer")
        #expect(r.ok, "\(r.error ?? "nil")")
        #expect(r.result?["removedLayer"]?.boolValue == true)
        #expect(r.result?["trackId"]?.stringValue == bass.id.uuidString)
        #expect(store.tracks.first { $0.id == bass.id }?.clips.isEmpty == true)
        #expect(store.tracks.first { $0.id == chords.id }?.clips.count == 1)
        #expect(store.transport.isPlaying, "peeling a layer must never stop the music")
        #expect(engine.stopPlaybackCalls == 0)

        // ---- looper.status agrees with the model, and is not merely an echo.
        r = await go("looper.status")
        #expect(r.ok, "\(r.error ?? "nil")")
        let lamps = try #require(r.result?["lamps"]?.arrayValue)
        #expect(lamps.count == 1)
        #expect(lamps[0]["state"]?.stringValue == "playing")
        #expect(lamps[0]["trackName"]?.stringValue == "Chords")
        #expect(r.result?["canPeel"]?.boolValue == true)   // layer 1's pass is still peelable
    }

    @Test("looper.end closes the session and LEAVES the layers on the timeline")
    func endKeepsTheLayers() async throws {
        let (router, store, engine, chords, _) = try fixture()
        _ = await send(router, "transport.play")
        _ = await send(router, "looper.begin", ["bars": .number(1)])
        _ = await send(router, "looper.armLayer", ["trackId": .string(chords.id.uuidString)])
        tick(store, engine, to: 3)
        tick(store, engine, to: 7.5)
        _ = await send(router, "looper.finishLayer")
        tick(store, engine, to: 8)
        engine.deliver(notesAt: [1], pitch: 60)
        #expect(store.tracks.first { $0.id == chords.id }?.clips.count == 1)

        let r = await send(router, "looper.end")
        #expect(r.ok, "\(r.error ?? "nil")")
        // The layers are ordinary clips on ordinary tracks — the whole point of
        // the linear route.
        #expect(store.tracks.first { $0.id == chords.id }?.clips.count == 1)
        #expect((await send(router, "looper.status")).result == .null)
    }
}
