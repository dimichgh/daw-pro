import Foundation
import Testing
import DAWCore
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
        // edit.pasteClips (m26-k) is now the very last command, appended after
        // clip.detectPitch (m23-ap-3); profileFile is third-to-last — still
        // adjacent, still an exact prefix of HEAD.
        #expect(CommandRouter.allCommands.dropLast(2).last == "audio.profileFile")
        #expect(CommandRouter.allCommands.dropLast(3).last == "transport.setStopAtContentEnd")
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
