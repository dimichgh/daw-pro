import AVFAudio
import Foundation
import Testing
import DAWCore
import DAWEngine
@testable import DAWControl

// m25-z: audio.profileFile — windowed peak/RMS profile of an ARBITRARY file
// on disk. Wire-level coverage (params, validation, rejections, JSON shape,
// the reference-slot/References-library untouched proof); the REAL DSP is
// proven separately and exhaustively by DAWEngineTests/FileProfilerTests.

/// Engine fake whose ONLY relevant capability is `profileFile` (the
/// FakeReferenceEngine idiom, ReferenceCommandTests.swift): `result` nil ⇒
/// profileFile throws `engineUnavailable`, exercising the headless refusal;
/// `capturedCalls` lets a test assert the exact params that reached the
/// engine seam.
@MainActor
private final class FakeProfileEngine: AudioEngineControlling {
    var result: FileProfile?
    private(set) var capturedCalls: [(url: URL, windowSeconds: Double,
                                      fromSeconds: Double, durationSeconds: Double?)] = []

    func profileFile(at url: URL, windowSeconds: Double, fromSeconds: Double,
                     durationSeconds: Double?) async throws -> FileProfile {
        capturedCalls.append((url, windowSeconds, fromSeconds, durationSeconds))
        guard let result else { throw ProjectError.engineUnavailable }
        return result
    }

    // Reference capability left at the throwing-default (unused here) so a
    // stray reference.* call in a shared harness fails loudly rather than
    // silently landing a slot this suite never asked for.

    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
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

private func cannedProfile() -> FileProfile {
    FileProfile(
        durationSeconds: 56.58, sampleRateHz: 48_000, channelCount: 2,
        bitDepth: 24, isFloat: false,
        windows: [
            FileProfileWindow(startSeconds: 53, durationSeconds: 1.0, peakDb: -70.96, rmsDb: -75.0),
            FileProfileWindow(startSeconds: 54, durationSeconds: 1.0, peakDb: -93.04, rmsDb: -97.0),
            // The m25-z evidence shape: a decayed-past-silence tail OMITS
            // its fields rather than reading 0.
            FileProfileWindow(startSeconds: 55, durationSeconds: 1.58, peakDb: nil, rmsDb: nil),
        ])
}

@MainActor
@Suite("audio.profileFile — control protocol (m25-z)")
struct AudioProfileFileCommandTests {

    /// Router + store with a temp file this test owns, and — separately — a
    /// reference-imports home + a real (different) source file, so the
    /// untouched-reference-slot test can prove profileFile never reaches
    /// either.
    private func makeHarness(engine: FakeProfileEngine?) throws
        -> (router: CommandRouter, store: ProjectStore, profilePath: String) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audio-profile-cmd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let profilePath = base.appendingPathComponent("bounce.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: profilePath)  // "RIFF" — existence is all the wire checks
        return (CommandRouter(store: store), store, profilePath.path)
    }

    // MARK: - Registration (additive-at-end law)

    @Test("audio.profileFile is registered exactly once, appended at the very END of allCommands")
    func registeredAdditivelyAtEnd() {
        #expect(CommandRouter.allCommands.contains("audio.profileFile"))
        #expect(CommandRouter.allCommands
            .filter { $0 == "audio.profileFile" }.count == 1)
        // edit.pasteClips (m26-k) is the very last command, appended after
        // clip.detectPitch (m23-ap-3); profileFile is third-to-last — still
        // adjacent, still an exact prefix of HEAD. (m27 leg D's
        // clip.applyBreathContour did NOT extend this chain: it landed next to
        // its controller-lane siblings 116 elements from the end, the
        // clip.getNotes / instrument.describeSampler precedent, so every
        // end-relative assertion here is untouched by it.)
        #expect(CommandRouter.allCommands.dropLast(5).last == "edit.pasteClips")
        // m24-n appended project.embeddedVoices then vc.installEmbeddedVoice;
        // m23-q Phase 2 then appended clip.autoCorrectPitch/
        // clip.clearPitchEdits/clip.getPitchEdits AFTER those, at the new END
        // (same law).
        #expect(CommandRouter.allCommands.dropLast(4).last == "project.embeddedVoices")
        #expect(CommandRouter.allCommands.dropLast(3).last == "vc.installEmbeddedVoice")
        #expect(CommandRouter.allCommands.dropLast(2).last == "clip.autoCorrectPitch")
        #expect(CommandRouter.allCommands.dropLast().last == "clip.clearPitchEdits")
        #expect(CommandRouter.allCommands.last == "clip.getPitchEdits")
        #expect(CommandRouter.allCommands.dropLast(7).last == "audio.profileFile")
        #expect(CommandRouter.allCommands.dropLast(8).last == "transport.setStopAtContentEnd")
    }

    // MARK: - Happy path: params forwarded, response shape verbatim

    @Test("happy path: path/windowSeconds/fromSeconds/durationSeconds reach the engine verbatim; response threads the model's own Codable, honest-absence included")
    func happyPathForwardsParamsAndShape() async throws {
        let engine = FakeProfileEngine()
        engine.result = cannedProfile()
        let (router, _, profilePath) = try makeHarness(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(1.0),
                     "fromSeconds": .number(53), "durationSeconds": .number(3.58)]))
        #expect(response.ok, "audio.profileFile failed: \(response.error ?? "?")")

        #expect(engine.capturedCalls.count == 1)
        let call = try #require(engine.capturedCalls.first)
        #expect(call.url.path == profilePath)
        #expect(call.windowSeconds == 1.0)
        #expect(call.fromSeconds == 53)
        #expect(call.durationSeconds == 3.58)

        #expect(response.result?["durationSeconds"]?.doubleValue == 56.58)
        #expect(response.result?["sampleRateHz"]?.doubleValue == 48_000)
        #expect(response.result?["channelCount"]?.doubleValue == 2)
        #expect(response.result?["bitDepth"]?.doubleValue == 24)
        #expect(response.result?["isFloat"]?.boolValue == false)

        let windows = try #require(response.result?["windows"]?.arrayValue)
        #expect(windows.count == 3)
        #expect(windows[0]["startSeconds"]?.doubleValue == 53)
        #expect(windows[0]["durationSeconds"]?.doubleValue == 1.0)
        #expect(windows[0]["peakDb"]?.doubleValue == -70.96)
        #expect(windows[0]["rmsDb"]?.doubleValue == -75.0)
        #expect(windows[2]["startSeconds"]?.doubleValue == 55)
        #expect(abs((windows[2]["durationSeconds"]?.doubleValue ?? 0) - 1.58) < 1e-9)
        // Honest absence: the silent tail window OMITS peakDb/rmsDb — never 0.
        #expect(windows[2]["peakDb"] == nil, "a silent window must OMIT peakDb, not encode 0")
        #expect(windows[2]["rmsDb"] == nil, "a silent window must OMIT rmsDb, not encode 0")
    }

    @Test("fromSeconds/durationSeconds are optional — omitted means fromSeconds defaults 0, durationSeconds nil (rest of file)")
    func optionalParamsOmittedMeansDefaults() async throws {
        let engine = FakeProfileEngine()
        engine.result = cannedProfile()
        let (router, _, profilePath) = try makeHarness(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(1.0)]))
        #expect(response.ok)
        let call = try #require(engine.capturedCalls.first)
        #expect(call.fromSeconds == 0)
        #expect(call.durationSeconds == nil)
    }

    // MARK: - Validation, rejected BEFORE the engine is ever called

    @Test("windowSeconds <= 0 is rejected at the wire, engine never called")
    func rejectsNonPositiveWindowSeconds() async throws {
        let engine = FakeProfileEngine()
        engine.result = cannedProfile()
        let (router, _, profilePath) = try makeHarness(engine: engine)

        let zero = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(0)]))
        #expect(!zero.ok)
        #expect(zero.error?.contains("windowSeconds") == true)

        let negative = await router.handle(ControlRequest(
            id: "2", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(-1)]))
        #expect(!negative.ok)
        #expect(engine.capturedCalls.isEmpty, "an invalid windowSeconds must never reach the engine")
    }

    @Test("fromSeconds < 0 is rejected at the wire")
    func rejectsNegativeFromSeconds() async throws {
        let engine = FakeProfileEngine()
        engine.result = cannedProfile()
        let (router, _, profilePath) = try makeHarness(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(1.0),
                     "fromSeconds": .number(-0.5)]))
        #expect(!response.ok)
        #expect(response.error?.contains("fromSeconds") == true)
        #expect(engine.capturedCalls.isEmpty)
    }

    @Test("durationSeconds <= 0 is rejected at the wire")
    func rejectsNonPositiveDurationSeconds() async throws {
        let engine = FakeProfileEngine()
        engine.result = cannedProfile()
        let (router, _, profilePath) = try makeHarness(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(1.0),
                     "durationSeconds": .number(0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("durationSeconds") == true)
        #expect(engine.capturedCalls.isEmpty)
    }

    @Test("missing path / missing windowSeconds teach the missing param; unknown keys teach the valid set")
    func requiredParamsAndUnknownKeys() async throws {
        let engine = FakeProfileEngine()
        engine.result = cannedProfile()
        let (router, _, profilePath) = try makeHarness(engine: engine)

        let noPath = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile", params: ["windowSeconds": .number(1.0)]))
        #expect(!noPath.ok)
        #expect(noPath.error?.contains("path") == true)

        let noWindow = await router.handle(ControlRequest(
            id: "2", command: "audio.profileFile", params: ["path": .string(profilePath)]))
        #expect(!noWindow.ok)
        #expect(noWindow.error?.contains("windowSeconds") == true)

        let unknown = await router.handle(ControlRequest(
            id: "3", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(1.0),
                     "bogus": .bool(true)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown parameter 'bogus'") == true)
        #expect(unknown.error?.contains("'windowSeconds'") == true)
        #expect(unknown.error?.contains("'fromSeconds'") == true)
        #expect(unknown.error?.contains("'durationSeconds'") == true)
        #expect(engine.capturedCalls.isEmpty)
    }

    // MARK: - File-existence and headless refusals

    @Test("no file at path -> audioFileNotFound, naming the path; engine never called")
    func missingFileRefusesBeforeTheEngine() async throws {
        let engine = FakeProfileEngine()
        engine.result = cannedProfile()
        let (router, _, _) = try makeHarness(engine: engine)
        let missingPath = "/tmp/not-there-\(UUID().uuidString).wav"

        let response = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(missingPath), "windowSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error?.contains(missingPath) == true)
        #expect(engine.capturedCalls.isEmpty, "a missing file must never reach the engine")
    }

    @Test("headless (no engine) refuses with engineUnavailable — a profile is never fabricated")
    func headlessRefusesEngineUnavailable() async throws {
        let (router, _, profilePath) = try makeHarness(engine: nil)
        let response = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("an engine present but incapable (profileFile throws) surfaces engineUnavailable too")
    func incapableEngineRefusesEngineUnavailable() async throws {
        let engine = FakeProfileEngine()  // result nil -> profileFile throws
        let (router, _, profilePath) = try makeHarness(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    // MARK: - The hard constraint: reference slot + References library untouched

    @Test("audio.profileFile NEVER touches the project reference slot or the References import directory, even with a reference already loaded")
    func referenceSlotAndLibraryUntouched() async throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audio-profile-ref-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let imports = base.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        store.referenceImportsDirectory = imports

        // A reference-capable engine, distinct from the profiling engine —
        // this suite exercises BOTH capabilities on the SAME store to prove
        // one command's traffic never crosses into the other's territory.
        final class DualCapabilityEngine: AudioEngineControlling {
            var referenceResult: ReferenceAnalysis?
            var profileResult: FileProfile?
            private(set) var profileFileCalls = 0
            func analyzeReferenceFile(at url: URL) async throws -> ReferenceAnalysis {
                guard let referenceResult else { throw ProjectError.engineUnavailable }
                return referenceResult
            }
            func profileFile(at url: URL, windowSeconds: Double, fromSeconds: Double,
                             durationSeconds: Double?) async throws -> FileProfile {
                profileFileCalls += 1
                guard let profileResult else { throw ProjectError.engineUnavailable }
                return profileResult
            }
            var isRunning = false
            var meteringHandler: ((MeterFrame) -> Void)?
            var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
            var playheadHandler: ((Double) -> Void)?
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
        let engine = DualCapabilityEngine()
        engine.referenceResult = ReferenceAnalysis(
            bandsDb: (0..<MasterAnalysisSnapshot.bandCount).map { Double($0) - 40 },
            correlation: 1, width: 0, balance: 0,
            durationSeconds: 30, sampleRateHz: 48_000, analyzerVersion: 1)
        engine.profileResult = cannedProfile()
        store.engine = engine
        let router = CommandRouter(store: store)

        // Load a REAL reference first (the slot is non-nil, non-trivial to
        // accidentally leave "unchanged" by never having touched it).
        let referenceSource = base.appendingPathComponent("MyReference.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: referenceSource)
        let importResponse = await router.handle(ControlRequest(
            id: "1", command: "reference.import", params: ["path": .string(referenceSource.path)]))
        #expect(importResponse.ok, "reference.import failed: \(importResponse.error ?? "?")")
        let slotBefore = try #require(store.reference)
        let importsBefore = try FileManager.default.contentsOfDirectory(atPath: imports.path)
        #expect(!importsBefore.isEmpty, "the reference import must have landed a real file")

        // Profile an UNRELATED file, several times, including with the
        // reference's own path (still must never touch the SLOT/library).
        let unrelated = base.appendingPathComponent("Unrelated.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: unrelated)
        for path in [unrelated.path, referenceSource.path] {
            let response = await router.handle(ControlRequest(
                id: "2", command: "audio.profileFile",
                params: ["path": .string(path), "windowSeconds": .number(1.0)]))
            #expect(response.ok, "audio.profileFile failed: \(response.error ?? "?")")
        }
        #expect(engine.profileFileCalls == 2)

        // The reference slot is BYTE-IDENTICAL (same Codable struct), and the
        // References import directory holds exactly the same files as before
        // — profileFile copied nothing, occupied no slot, wrote nothing.
        #expect(store.reference == slotBefore)
        let importsAfter = try FileManager.default.contentsOfDirectory(atPath: imports.path)
        #expect(Set(importsAfter) == Set(importsBefore))
    }
}

// MARK: - m27-k: the opt-in loudness reading (one meter, a second door)
//
// m27-k (dogfood): `audio_profile_file` reported no LUFS, so the documented
// way to check a bounce's loudness was `reference_import`, which COPIES the
// file into the References library (three checks left 243 MB behind). The
// fix is an OPT-IN `loudness` flag on this verb that calls the SAME meter
// `reference.import`/`reference.analyze` use. These wire tests run the REAL
// `AudioEngine` (headless: assigning `store.engine` never calls `prepare()`,
// so no device is opened). The DSP-level proofs live in
// `DAWEngineTests/FileProfileLoudnessTests.swift`.

/// Deinterleaved Float32 WAV, so read-back is bit-exact (the
/// ReferenceAnalyzerTests idiom).
private func m27kWriteFloat32Wav(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
    struct FixtureError: Error {}
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels.count), interleaved: false) else { throw FixtureError() }
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ],
        commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = channels.map(\.count).min() ?? 0
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { throw FixtureError() }
    for (index, channel) in channels.enumerated() {
        channel.withUnsafeBufferPointer {
            buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames)
        }
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    try file.write(from: buffer)
}

/// The byte-pin program: values EXACT in Float so the golden is hand-checkable
/// and immune to summation order — 2 s of a +-0.5 square (24-sample half
/// periods, 1 kHz at 48 k), 1 s of a +-0.125 square, 0.5 s of digital silence
/// (the honest-absence window). Peak and RMS of a square equal its amplitude.
private func m27kPinProgram() -> [Float] {
    var samples: [Float] = []
    for (amplitude, seconds) in [(Float(0.5), 2.0), (Float(0.125), 1.0)] {
        let count = Int(seconds * 48_000)
        samples += (0..<count).map { ($0 / 24) % 2 == 0 ? amplitude : -amplitude }
    }
    samples += [Float](repeating: 0, count: 24_000)
    return samples
}

/// The wire `result` in CANONICAL form. `JSONValue.object` is a dictionary, so
/// the live server's key order is not fixed; sorted keys make the bytes a
/// stable function of the reply's content.
private func m27kCanonical(_ value: JSONValue?) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// CAPTURED FROM THE TREE BEFORE THE m27-k EDIT (W8-M27K, 2026-10-07): the
/// no-flag reply for `m27kPinProgram()` (stereo, float32, 48 k) at
/// windowSeconds 1. Hand-check: 20*log10(0.5) = -6.0206 for peak AND rms of
/// the first two windows, 20*log10(0.125) = -18.0618 for the third, and the
/// silent half-second window carries NO peakDb/rmsDb.
private let m27kNoFlagGolden = #"{"bitDepth":32,"channelCount":2,"durationSeconds":3.5,"isFloat":true,"sampleRateHz":48000,"windows":[{"durationSeconds":1,"peakDb":-6.020599913279624,"rmsDb":-6.020599913279624,"startSeconds":0},{"durationSeconds":1,"peakDb":-6.020599913279624,"rmsDb":-6.020599913279624,"startSeconds":1},{"durationSeconds":1,"peakDb":-18.06179973983887,"rmsDb":-18.06179973983887,"startSeconds":2},{"durationSeconds":0.5,"startSeconds":3}]}"#

extension AudioProfileFileCommandTests {

    @Test("m27-k pin: the reply WITHOUT the loudness flag stays byte-identical (sorted-key golden captured before the edit, real engine)")
    func m27kNoFlagReplyIsByteIdentical() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let router = CommandRouter(store: store)
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m27k-pin-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let wav = base.appendingPathComponent("pin.wav")
        let program = m27kPinProgram()
        try m27kWriteFloat32Wav([program, program], sampleRate: 48_000, to: wav)

        let response = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(wav.path), "windowSeconds": .number(1.0)]))
        #expect(response.ok, "audio.profileFile failed: \(response.error ?? "?")")
        let bytes = try m27kCanonical(response.result)
        print("[measured] m27-k no-flag canonical reply: \(bytes)")
        #expect(bytes == m27kNoFlagGolden)
    }
}

/// A real headless engine on a store whose References library is an EMPTY
/// directory this test owns (never the real library), plus a stereo
/// -20 dBFS 1 kHz, 10 s float32 file to profile. The caller keeps `engine`
/// alive (`store.engine` is weak) and shuts it down.
@MainActor
private func m27kRealEngineHarness() throws
    -> (engine: AudioEngine, store: ProjectStore, router: CommandRouter, wav: URL, imports: URL, base: URL) {
    let engine = AudioEngine()
    let store = ProjectStore()
    store.media = FakeMedia()
    store.engine = engine
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("m27k-wire-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let imports = base.appendingPathComponent("References", isDirectory: true)
    try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
    store.referenceImportsDirectory = imports
    let tone = (0..<480_000).map { Float(0.1 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
    let wav = base.appendingPathComponent("bounce.wav")
    try m27kWriteFloat32Wav([tone, tone], sampleRate: 48_000, to: wav)
    return (engine, store, CommandRouter(store: store), wav, imports, base)
}

/// The References library as {file name: byte size} — the invariance snapshot.
private func m27kLibrarySnapshot(_ imports: URL) throws -> [String: Int] {
    var snapshot: [String: Int] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: imports.path) {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: imports.appendingPathComponent(name).path)
        snapshot[name] = (attributes[.size] as? NSNumber)?.intValue ?? -1
    }
    return snapshot
}

extension AudioProfileFileCommandTests {

    @Test("m27-k: loudness:false reads the SAME golden bytes as no flag")
    func m27kExplicitFalseIsTheNoFlagReply() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let router = CommandRouter(store: store)
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m27k-false-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let wav = base.appendingPathComponent("pin.wav")
        let program = m27kPinProgram()
        try m27kWriteFloat32Wav([program, program], sampleRate: 48_000, to: wav)

        let response = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(wav.path), "windowSeconds": .number(1.0),
                     "loudness": .bool(false)]))
        #expect(response.ok, "audio.profileFile failed: \(response.error ?? "?")")
        #expect(try m27kCanonical(response.result) == m27kNoFlagGolden)
    }

    @Test("m27-k: loudness:true reports the file's BS.1770 reading, and reference.import of the SAME file reads the SAME numbers (one meter, two doors)")
    func m27kLoudnessMatchesReferenceImport() async throws {
        let h = try m27kRealEngineHarness()
        defer {
            h.engine.shutdown()
            try? FileManager.default.removeItem(at: h.base)
        }

        let response = await h.router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(h.wav.path), "windowSeconds": .number(1.0),
                     "loudness": .bool(true)]))
        #expect(response.ok, "audio.profileFile failed: \(response.error ?? "?")")
        let loudness = try #require(response.result?["loudness"], "loudness:true must attach a reading")
        let integrated = try #require(loudness["integratedLufs"]?.doubleValue)
        let truePeak = try #require(loudness["truePeakDbtp"]?.doubleValue)
        print("[measured] m27-k wire: stereo -20 dBFS 1 kHz -> integrated \(integrated) LUFS, true peak \(truePeak) dBTP")
        // BS.1770 sums the channels and is transparent at 1 kHz: -20 dBFS on
        // both channels reads -20.0 LUFS (the LoudnessTests calibration).
        #expect(abs(integrated - -20.0) <= 0.1)
        #expect(abs(truePeak - -20.0) <= 0.1)
        // The windows are still there, unchanged in kind.
        #expect(response.result?["windows"]?.arrayValue?.count == 10)

        // Door two: the documented-but-leaky path, into this test's own library.
        let imported = await h.router.handle(ControlRequest(
            id: "2", command: "reference.import", params: ["path": .string(h.wav.path)]))
        #expect(imported.ok, "reference.import failed: \(imported.error ?? "?")")
        let analysis = try #require(h.store.reference?.analysis)
        #expect(integrated == analysis.integratedLufs)
        #expect(truePeak == analysis.truePeakDbtp)
        #expect(loudness["maxMomentaryLufs"]?.doubleValue == analysis.maxMomentaryLufs)
        #expect(loudness["maxShortTermLufs"]?.doubleValue == analysis.maxShortTermLufs)
        #expect(loudness["loudnessRangeLu"]?.doubleValue == analysis.loudnessRangeLu)
    }

    @Test("m27-k invariance: loudness:true copies nothing and never touches the reference slot (empty library, then a loaded one; snapshot before/after)")
    func m27kLoudnessLeavesReferencesUntouched() async throws {
        let h = try m27kRealEngineHarness()
        defer {
            h.engine.shutdown()
            try? FileManager.default.removeItem(at: h.base)
        }
        let sourceBytes = try Data(contentsOf: h.wav)
        func profile(_ path: String) async -> ControlResponse {
            await h.router.handle(ControlRequest(
                id: "p", command: "audio.profileFile",
                params: ["path": .string(path), "windowSeconds": .number(2.0),
                         "loudness": .bool(true)]))
        }

        // 1. The defect's own shape: an EMPTY library and an EMPTY slot.
        #expect(try m27kLibrarySnapshot(h.imports).isEmpty)
        #expect(h.store.reference == nil)
        for _ in 0..<2 {
            let response = await profile(h.wav.path)
            #expect(response.ok, "audio.profileFile failed: \(response.error ?? "?")")
            #expect(response.result?["loudness"]?["integratedLufs"]?.doubleValue != nil)
        }
        #expect(try m27kLibrarySnapshot(h.imports).isEmpty,
                "checking loudness must never copy the file into the References library")
        #expect(h.store.reference == nil, "checking loudness must never occupy the reference slot")

        // 2. A loaded slot: import once (the positive control: the library
        // CAN grow, and this snapshot sees it), then profile both the source
        // and the imported copy.
        let imported = await h.router.handle(ControlRequest(
            id: "i", command: "reference.import", params: ["path": .string(h.wav.path)]))
        #expect(imported.ok, "reference.import failed: \(imported.error ?? "?")")
        let slotBefore = try #require(h.store.reference)
        let libraryBefore = try m27kLibrarySnapshot(h.imports)
        #expect(libraryBefore.count == 1, "the positive control: an import DOES land a copy here")
        for path in [h.wav.path, slotBefore.sourcePath] {
            let response = await profile(path)
            #expect(response.ok, "audio.profileFile failed: \(response.error ?? "?")")
        }
        #expect(h.store.reference == slotBefore)
        #expect(try m27kLibrarySnapshot(h.imports) == libraryBefore)
        #expect(try Data(contentsOf: h.wav) == sourceBytes, "the profiled file is never modified")
    }

    @Test("m27-k: an engine without the loudness capability refuses loudness:true (never a profile missing the reading it was asked for); the no-flag request still works")
    func m27kIncapableEngineRefusesLoudness() async throws {
        let engine = FakeProfileEngine()
        engine.result = cannedProfile()
        let (router, _, profilePath) = try makeHarness(engine: engine)

        let flagged = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(1.0),
                     "loudness": .bool(true)]))
        #expect(!flagged.ok)
        #expect(flagged.error == "audio engine not available")
        #expect(engine.capturedCalls.isEmpty, "the protocol default refuses before forwarding")

        let plain = await router.handle(ControlRequest(
            id: "2", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(1.0)]))
        #expect(plain.ok)
        #expect(engine.capturedCalls.count == 1)
        #expect(plain.result?["loudness"] == nil)
    }

    @Test("m27-k: loudness must be a boolean; a string is refused before the engine is called")
    func m27kLoudnessMustBeBoolean() async throws {
        let engine = FakeProfileEngine()
        engine.result = cannedProfile()
        let (router, _, profilePath) = try makeHarness(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "audio.profileFile",
            params: ["path": .string(profilePath), "windowSeconds": .number(1.0),
                     "loudness": .string("yes")]))
        #expect(!response.ok)
        #expect(response.error?.contains("'loudness' must be a boolean") == true)
        #expect(engine.capturedCalls.isEmpty)
    }
}
