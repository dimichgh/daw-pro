import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Engine fake for `clip.detectPitch` (m23-ap-3): returns a stubbed
/// `PitchDetectionResult` and records the forwarded call, so the tests pin
/// the wire shape + window/knob forwarding without real SwiftF0 inference
/// (real-inference coverage lives in `ClipPitchAnalyzerTests`,
/// DAWEngineTests). The stub DELIBERATELY carries both a voiced AND an
/// unvoiced frame — an all-voiced stub would let the honest-absence
/// assertions below pass without ever exercising the omission path.
@MainActor
final class FakePitchDetectionEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    var stubResult = PitchDetectionResult(
        frames: [
            ClipPitchFrame(timeSeconds: 0.0, frequencyHz: 220.0, confidence: 0.97,
                           levelDbfs: -12.0, absence: nil),
            ClipPitchFrame(timeSeconds: 0.016, frequencyHz: nil, confidence: 0.2,
                           levelDbfs: -70.0, absence: .belowConfidence),
        ],
        frameCount: 2, voicedFrameCount: 1, voicedFraction: 0.5,
        frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
        windowStartSeconds: 0, windowDurationSeconds: 0.032,
        confidenceThreshold: 0.9, silenceFloorDbfs: -75,
        minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    var detectCalls = 0
    var lastURL: URL?
    var lastFromSeconds: Double?
    var lastDurationSeconds: Double?
    var lastConfidenceThreshold: Double?
    var lastSilenceFloorDbfs: Double?

    func detectPitch(inFileAt url: URL, fromSeconds: Double, durationSeconds: Double,
                     confidenceThreshold: Double,
                     silenceFloorDbfs: Double) async throws -> PitchDetectionResult {
        detectCalls += 1
        lastURL = url
        lastFromSeconds = fromSeconds
        lastDurationSeconds = durationSeconds
        lastConfidenceThreshold = confidenceThreshold
        lastSilenceFloorDbfs = silenceFloorDbfs
        return stubResult
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

/// Control-protocol coverage for m23-ap-3 `clip.detectPitch`: happy-path
/// wire shape (honest absence across the JSON boundary), default/explicit
/// window forwarding, the out-of-window rejection vs. the past-the-end
/// clamp, tuning-knob validation, the MIDI/missing-file/unknown-clip
/// rejections verbatim, and the engine-default-throw/headless paths.
@MainActor
@Suite("Clip pitch detection — control protocol (m23-ap-3)")
struct ClipDetectPitchCommandTests {
    private func makeRouter(engine: (any AudioEngineControlling)? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    /// A REAL file on disk (unlike `ClipAnalyzeAudioCommandTests`'s
    /// `/tmp/Loop.wav`, which never needs to exist there — `FakeMedia`
    /// never touches disk). `detectClipPitch` DOES check
    /// `FileManager.fileExists`, so the happy-path tests need a real path.
    private func makeRealAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-detect-pitch-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        return url
    }

    private func addAudioClip(_ router: CommandRouter, path: String, atBeat: Double = 0) async throws
        -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string(path),
                     "atBeat": .number(atBeat)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    private func addMIDIClip(_ router: CommandRouter) async throws
        -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(4)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    @Test("happy path: default window, honest absence across the JSON boundary, stretch/pitch echo")
    func happyPathDefaultWindow() async throws {
        let engine = FakePitchDetectionEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch", params: ["clipId": .string(clipID)]))
        #expect(response.ok)

        #expect(engine.detectCalls == 1)
        #expect(engine.lastURL?.path == fileURL.path)
        #expect(engine.lastFromSeconds == 0)
        #expect(engine.lastDurationSeconds == 2.0, "the 2 s FakeMedia file -> 2 s window at 0 offset")
        #expect(engine.lastConfidenceThreshold == PitchDetectionDefaults.defaultConfidenceThreshold)
        #expect(engine.lastSilenceFloorDbfs == PitchDetectionDefaults.defaultSilenceFloorDbfs)

        let pitch = try #require(response.result?["pitch"]?.objectValue)
        #expect(pitch["frameCount"]?.doubleValue == 2)
        #expect(pitch["voicedFrameCount"]?.doubleValue == 1)
        #expect(pitch["voicedFraction"]?.doubleValue == 0.5)
        #expect(pitch["frameRateHz"]?.doubleValue == 62.5)
        #expect(pitch["minFrequencyHz"]?.doubleValue == 46.875)
        #expect(pitch["maxFrequencyHz"]?.doubleValue == 2_093.75)

        let frames = try #require(pitch["frames"]?.arrayValue)
        #expect(frames.count == 2)
        let voiced = frames[0]
        #expect(voiced["frequencyHz"]?.doubleValue == 220.0)
        #expect(voiced["absence"] == nil, "a voiced frame must omit absence")
        let unvoiced = frames[1]
        #expect(unvoiced["frequencyHz"] == nil,
                "an unvoiced frame must OMIT frequencyHz entirely — never null, never 0")
        #expect(unvoiced["absence"]?.stringValue == "belowConfidence")
        #expect(unvoiced["confidence"]?.doubleValue == 0.2,
                "confidence is reported even for an unvoiced frame")

        // Identity clip: echo present.
        #expect(response.result?["stretchRatio"]?.doubleValue == 1)
        #expect(response.result?["pitchShiftSemitones"]?.doubleValue == 0)
        #expect(response.result?["clipWindowDurationSeconds"]?.doubleValue == 2.0)
    }

    @Test("explicit fromSeconds/durationSeconds/tuning knobs forward verbatim")
    func explicitParamsForward() async throws {
        let engine = FakePitchDetectionEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch",
            params: ["clipId": .string(clipID), "fromSeconds": .number(0.5),
                     "durationSeconds": .number(1.0), "confidenceThreshold": .number(0.6),
                     "silenceFloorDbfs": .number(-50)]))
        #expect(response.ok)
        #expect(engine.lastFromSeconds == 0.5)
        #expect(engine.lastDurationSeconds == 1.0)
        #expect(engine.lastConfidenceThreshold == 0.6)
        #expect(engine.lastSilenceFloorDbfs == -50)
    }

    @Test("durationSeconds past the clip's window end is CLAMPED, not rejected")
    func durationClampedAtWindowEnd() async throws {
        let engine = FakePitchDetectionEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch",
            params: ["clipId": .string(clipID), "fromSeconds": .number(1.5),
                     "durationSeconds": .number(100.0)]))
        #expect(response.ok)
        #expect(engine.lastFromSeconds == 1.5)
        #expect(engine.lastDurationSeconds == 0.5, "clamped to the remaining 0.5 s of the 2 s window")
    }

    @Test("fromSeconds outside the clip's current window is a teaching invalidClipEdit; zero engine calls")
    func fromSecondsOutsideWindowRejected() async throws {
        let engine = FakePitchDetectionEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch",
            params: ["clipId": .string(clipID), "fromSeconds": .number(5.0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("current window is") == true)
        #expect(response.error?.contains("outside it") == true)
        #expect(engine.detectCalls == 0)
    }

    @Test("negative fromSeconds / non-positive durationSeconds / out-of-range confidenceThreshold / non-finite silenceFloorDbfs are field-named")
    func paramValidation() async throws {
        let engine = FakePitchDetectionEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let negFrom = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch",
            params: ["clipId": .string(clipID), "fromSeconds": .number(-1)]))
        #expect(!negFrom.ok)
        #expect(negFrom.error?.contains("fromSeconds") == true)

        let zeroDuration = await router.handle(ControlRequest(
            id: "2", command: "clip.detectPitch",
            params: ["clipId": .string(clipID), "durationSeconds": .number(0)]))
        #expect(!zeroDuration.ok)
        #expect(zeroDuration.error?.contains("durationSeconds") == true)

        let badConfidence = await router.handle(ControlRequest(
            id: "3", command: "clip.detectPitch",
            params: ["clipId": .string(clipID), "confidenceThreshold": .number(1.5)]))
        #expect(!badConfidence.ok)
        #expect(badConfidence.error?.contains("confidenceThreshold") == true)

        let badFloor = await router.handle(ControlRequest(
            id: "4", command: "clip.detectPitch",
            params: ["clipId": .string(clipID), "silenceFloorDbfs": .number(.nan)]))
        #expect(!badFloor.ok)
        #expect(badFloor.error?.contains("silenceFloorDbfs") == true)

        #expect(engine.detectCalls == 0)
    }

    @Test("MIDI clip surfaces pitchDetectionRequiresAudioClip verbatim")
    func rejectsMIDI() async throws {
        let engine = FakePitchDetectionEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addMIDIClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error == "clip \(clipID) is a MIDI clip — clip.detectPitch applies only to "
                + "audio clips (MIDI notes already carry a definite pitch — read them directly)")
        #expect(engine.detectCalls == 0)
    }

    @Test("a clip whose backing file has been moved/deleted surfaces a teaching invalidClipEdit, not audioFileNotFound's path-specific wording")
    func missingBackingFile() async throws {
        let engine = FakePitchDetectionEngine()
        let (router, _) = makeRouter(engine: engine)
        let goneURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-detect-pitch-gone-\(UUID().uuidString).wav")
        let (_, clipID) = try await addAudioClip(router, path: goneURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error?.contains("audio file is missing") == true)
        #expect(response.error?.contains(goneURL.path) == true)
        #expect(engine.detectCalls == 0)
    }

    @Test("unknown clip surfaces clipNotFound; missing clipId is field-named")
    func unknownClip() async throws {
        let engine = FakePitchDetectionEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        _ = try await addAudioClip(router, path: fileURL.path)

        let unknown = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch",
            params: ["clipId": .string(UUID().uuidString)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("no clip with id") == true)

        let missing = await router.handle(ControlRequest(id: "2", command: "clip.detectPitch"))
        #expect(!missing.ok)
        #expect(missing.error?.contains("clipId") == true)
    }

    @Test("unknown params are rejected with the teaching key list")
    func unknownKeysRejected() async throws {
        let engine = FakePitchDetectionEngine()
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch",
            params: ["clipId": .string(clipID), "bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'bogus'") == true)
        #expect(engine.detectCalls == 0)
    }

    @Test("engine-default-throw path: a real engine that doesn't override detectPitch surfaces engineUnavailable")
    func engineDefaultThrow() async throws {
        let engine = FakeEngine()  // ControlTests.swift — inherits the protocol's throwing default
        let (router, _) = makeRouter(engine: engine)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("headless (no engine) surfaces engineUnavailable")
    func headless() async throws {
        let (router, _) = makeRouter(engine: nil)
        let fileURL = try makeRealAudioFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (_, clipID) = try await addAudioClip(router, path: fileURL.path)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectPitch", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("clip.detectPitch is a registered command, appended after audio.profileFile")
    func commandRegistered() {
        let all = CommandRouter.allCommands
        #expect(all.contains("clip.detectPitch"))
        if let pitchIndex = all.firstIndex(of: "clip.detectPitch"),
           let profileIndex = all.firstIndex(of: "audio.profileFile") {
            #expect(profileIndex < pitchIndex)
        } else {
            Issue.record("clip.detectPitch or audio.profileFile missing from allCommands")
        }
        // m26-k appended `edit.pasteClips` after it — clip.detectPitch is no
        // longer the tail itself, but the additive-at-end law only requires
        // it stay UNMOVED relative to what came before it, which the
        // profileIndex < pitchIndex check above still proves.
        #expect(all.last == "edit.pasteClips", "additive-at-end law (now one past clip.detectPitch)")
        #expect(all.dropLast().last == "clip.detectPitch", "clip.detectPitch is unmoved, just no longer the tail")
    }
}
