import Darwin
import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

// Shared fixtures for the SingWire* suites (p2-sing-e part 2). No tests here. Everything is nonisolated except the
// builders marked `@MainActor` (no `@Suite` is MainActor-isolated: the tree is at its `@MainActor` suite cap).
// DAWControlTests cannot import AIServicesTests, so the few helpers SE1's `SingFixture` has that these suites need
// (the sine pitch tracker, the WAV media fake, the wait loop) are copied here, under their own names.

enum SingWireFixture {

    static func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sing-wire-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// SE1's two-unit melody (two breath phrases of four one-beat notes at beats 4 and 36, 120 BPM).
    static let twoUnitOnsets: [Double] = [4, 5, 6, 7, 36, 37, 38, 39]
    static let twoUnitLyrics = "one two three four\nfive six seven eight"
    static let twoUnitPitches = [60, 62, 64, 65, 67, 65, 64, 62]

    /// A store with the WAV media fake, a temp Generations folder, and one melody clip (no lyrics unless given).
    @MainActor
    static func store(root: URL, lyrics: String? = nil, onsets: [Double] = twoUnitOnsets,
                      pitches: [Int] = twoUnitPitches) throws -> (ProjectStore, UUID) {
        let store = ProjectStore()
        store.media = SingWireWAVMedia()
        store.generationImportsDirectory = root.appendingPathComponent("generations", isDirectory: true)
        let track = store.addTrack(kind: .instrument)
        let notes = onsets.enumerated().map { i, onset in
            MIDINote(pitch: pitches[i % pitches.count], startBeat: onset, lengthBeats: 1)
        }
        let clip = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0,
                                         lengthBeats: (onsets.max() ?? 0) + 2, notes: notes)
        if let lyrics {
            for t in store.tracks.indices {
                if let c = store.tracks[t].clips.firstIndex(where: { $0.id == clip.id }) {
                    store.tracks[t].clips[c].lyrics = ClipLyrics(text: lyrics)
                }
            }
        }
        return (store, clip.id)
    }

    // MARK: A voice recording that passes the clip check (VoiceClipCheckTests' clean take)

    static let hop = 0.016

    /// P1 at C4 with its first onset at `tau`, on SwiftF0's 16 ms grid over `total` (VoiceClipCheckTests.p1Frames).
    static func p1Frames(tau: Double = 1.0, total: Double = 6.8) -> [ClipPitchFrame] {
        let notes = SingGuideLine.timedNotes(startMidi: 60)
        return (0..<Int(total / hop)).map { i in
            let t = Double(i) * hop
            guard let note = notes.first(where: { t >= tau + $0.startSeconds && t < tau + $0.endSeconds }) else {
                return ClipPitchFrame(timeSeconds: t, frequencyHz: nil, confidence: 0.1, levelDbfs: -70,
                                      absence: .belowLevel)
            }
            return ClipPitchFrame(timeSeconds: t, frequencyHz: 440 * pow(2, (Double(note.midi) - 69) / 12),
                                  confidence: 0.99, levelDbfs: -20, absence: nil)
        }
    }

    /// A take at 16 kHz: a 262 Hz tone at −20 dBFS RMS over [tone, tone + 4.8) and uniform noise at `noiseDb`
    /// (VoiceClipCheckTests.take).
    static func take(tone: Double = 1.0, total: Double = 6.8, noiseDb: Double = -70) -> [Float] {
        let rate = 16_000.0
        var x = [Float](repeating: 0, count: Int(total * rate))
        var state: UInt64 = 3
        let noiseHalfWidth = pow(10, noiseDb / 20) * 3.0.squareRoot()
        let amplitude = pow(10, -20.0 / 20) * 2.0.squareRoot()
        for i in x.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Double(state >> 11) / Double(UInt64(1) << 53) - 0.5) * 2 * noiseHalfWidth
            let t = Double(i) / rate
            let sung = t >= tone && t < tone + 4.8 ? amplitude * sin(2 * .pi * 262 * t) : 0
            x[i] = Float(sung + noise)
        }
        return x
    }

    /// Writes `take(...)` as a 16 kHz Float32 WAV.
    static func writeTake(_ url: URL, total: Double = 6.8, noiseDb: Double = -70) throws {
        try SingWAV.writeFloat32Mono(take(total: total, noiseDb: noiseDb), sampleRate: 16_000, to: url)
    }

    /// Polls `condition` every 5 ms until it holds or `seconds` pass.
    static func waitUntil(_ seconds: Double = 20, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return try await condition()
    }

    /// A free loopback TCP port: bind port 0, read it back, close.
    static func unusedLoopbackPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        return UInt16(bigEndian: out.sin_port)
    }

    // MARK: The services, with fakes

    /// A lifecycle coordinator of the test's own (never `.shared`), with SoulX registered and no evictor.
    static func lifecycle(_ root: URL, baseURL: URL) async -> ModelLifecycleCoordinator {
        let lifecycle = ModelLifecycleCoordinator(
            storageDirectory: root.appendingPathComponent("lifecycle", isDirectory: true), settleSeconds: 0)
        var soulx = ModelRegistry.soulxSinger(baseURL: baseURL)
        soulx.idleUnloadSeconds = nil
        await lifecycle.register(soulx, evictor: nil)
        return lifecycle
    }

    static func config(root: URL, baseURL: URL, lifecycle: ModelLifecycleCoordinator,
                       runtime: URL? = nil) -> SingingSidecarManager.Configuration {
        var config = SingingSidecarManager.Configuration(
            baseURL: baseURL, scriptsDir: nil,
            runtimeDir: runtime ?? root.appendingPathComponent("SingingEngine", isDirectory: true),
            voicesDir: root.appendingPathComponent("voices", isDirectory: true),
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            startupTimeoutSeconds: 5, healthPollIntervalSeconds: 0.05, healthProbeTimeoutSeconds: 0.5,
            stopTimeoutSeconds: 2, lifecycle: lifecycle, logFileURL: root.appendingPathComponent("sing.log"))
        config.watchdogReadMemoryPressureCritical = { false }
        return config
    }

    /// The services with a fake engine and fake jobs; every other part real, rooted under `root`.
    @MainActor
    static func services(root: URL, engine: any SingEngineControlling, jobs: any SingJobSubmitting,
                         installFunction: @escaping SingingEngineInstallCoordinator.InstallFunction,
                         autoConsent: Bool = false,
                         detectPitch: @escaping @Sendable (URL, Double) async throws -> [ClipPitchFrame]
                             = { _, _ in SingWireFixture.p1Frames() },
                         transcribe: @escaping @Sendable (URL) async throws -> String? = { _ in nil },
                         freeDiskBytes: @escaping @Sendable (URL) -> Int64? = { _ in 1 << 50 },
                         trash: @escaping @Sendable (URL) throws -> URL) -> SingWireServices {
        let config = engine.engineConfig
        return SingWireServices(
            engine: engine, jobs: jobs, install: SingingEngineInstallCoordinator(installFunction: installFunction),
            consent: SingConsentBroker(autoConsent: autoConsent),
            voices: SingVoiceLibrary(root: config.voicesDir ?? root.appendingPathComponent("voices")),
            engineFiles: SingEngineFiles(config: config), lifecycle: config.lifecycle,
            detectPitch: detectPitch, transcribe: transcribe, freeDiskBytes: freeDiskBytes, trash: trash,
            voiceCheckGuides: [:])
    }

    /// A trash that moves into `<root>/Trash`, for tests (never the real Trash).
    static func trash(into root: URL) -> @Sendable (URL) throws -> URL {
        { url in
            let bin = root.appendingPathComponent("Trash", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let target = bin.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }

    static func request(_ command: String, _ params: [String: JSONValue] = [:]) -> ControlRequest {
        ControlRequest(id: command, command: command, params: params)
    }
}

/// `ProjectStore.media` for these tests: the duration read from the WAV itself.
struct SingWireWAVMedia: MediaImporting {
    func audioFileInfo(at url: URL) throws -> AudioFileInfo {
        let audio = try SingWAV.read(url)
        return AudioFileInfo(durationSeconds: Double(audio.frameCount) / Double(audio.sampleRate),
                             sampleRate: Double(audio.sampleRate), channelCount: audio.channels.count)
    }
}

// MARK: - Fakes and spies

/// The singing engine, scripted: a state, a start that may fail, and a stop that reports evidence.
actor SingWireFakeEngine: SingEngineControlling {
    nonisolated let engineConfig: SingingSidecarManager.Configuration
    private(set) var state: SingingSidecarState
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: (any Error)?
    var startLeavesState: SingingSidecarState = .healthy

    init(config: SingingSidecarManager.Configuration, state: SingingSidecarState) {
        self.engineConfig = config
        self.state = state
    }

    func set(_ state: SingingSidecarState) { self.state = state }
    func failStart(with error: any Error) { startError = error }
    func startLeaves(_ state: SingingSidecarState) { startLeavesState = state }

    static func message(_ state: SingingSidecarState) -> String { "fake engine: \(state.rawValue)" }

    func status() async -> SingingSidecarStatus {
        SingingSidecarStatus(state: state, message: Self.message(state))
    }

    func start() async throws -> SingingSidecarStatus {
        startCount += 1
        if let startError { throw startError }
        state = startLeavesState
        return SingingSidecarStatus(state: state, message: Self.message(state))
    }

    func lastStopClassification() async -> SingingStopReason? { nil }

    func stopReportingEvidence() async throws -> SingingStopReport {
        stopCount += 1
        state = .installedNotRunning
        return SingingStopReport(
            status: SingingSidecarStatus(state: state, message: "fake engine stopped"),
            evidence: ModelStopEvidence(portFree: true, probeUnreachable: true, detail: "fake engine stopped"))
    }
}

/// `SingJobSubmitting`, recording every call. `status`/`cancel` serve what `statuses` holds.
actor SingWireFakeJobs: SingJobSubmitting {
    private(set) var submitted: [SingJobRequest] = []
    private(set) var cancelled: [String] = []
    private(set) var planned: [SingJobRequest] = []
    var previewAnswer: SingJobCoordinator.PlanPreview?
    var held: [SingJobStatus] = []
    var submitError: SingJobError?
    /// Shared with a lyrics spy, to prove the ORDER of the two writes.
    let log: SingWireCallLog?

    init(log: SingWireCallLog? = nil) { self.log = log }

    func hold(_ statuses: [SingJobStatus]) { held = statuses }
    func refuseSubmits(_ error: SingJobError) { submitError = error }

    static func status(id: String = "sing-test-1", clipID: UUID = UUID(), phase: SingJobPhase = .queued)
        -> SingJobStatus {
        SingJobStatus(
            jobID: id, clipID: clipID, phase: phase, stageText: "stage \(phase.rawValue)", unitIndex: nil,
            unitCount: 2, progress: 0, etaSeconds: nil, waitingFor: nil, cancelRequested: false,
            seed: SingJobRequestBuilder.firstTakeSeed, retriedUnits: [], cachedUnits: 0, renderedUnits: 0,
            yields: 0, engineRestarts: 0, warnings: [], notices: [], result: nil, gates: nil, error: nil,
            keptTakePath: nil, fromAgent: true, submittedAt: Date(timeIntervalSince1970: 1_800_000_000),
            finishedAt: nil)
    }

    func submit(_ request: SingJobRequest) async throws -> SingJobStatus {
        log?.append("submit")
        if let submitError { throw submitError }
        submitted.append(request)
        let status = Self.status(id: "sing-test-\(submitted.count)", clipID: request.clipID)
        held.append(status)
        return status
    }

    /// Records the call, then answers with `previewAnswer` (a test sets one); without one it refuses like an unknown
    /// clip, so a test that forgot to script it fails loudly.
    func plan(_ request: SingJobRequest) async throws -> SingJobCoordinator.PlanPreview {
        try await plan(request, lyrics: nil)
    }

    /// The words a `plan(_:lyrics:)` call carried (nil = none sent), one per call, in order.
    private(set) var plannedLyrics: [ClipLyrics??] = []

    func plan(_ request: SingJobRequest, lyrics: ClipLyrics??) async throws -> SingJobCoordinator.PlanPreview {
        planned.append(request)
        plannedLyrics.append(lyrics)
        if let submitError { throw submitError }
        guard let previewAnswer else { throw SingJobError.clipNotFound(request.clipID) }
        return previewAnswer
    }
    func setPreview(_ preview: SingJobCoordinator.PlanPreview?) { previewAnswer = preview }

    func status(jobID: String) async throws -> SingJobStatus {
        guard let found = held.first(where: { $0.jobID == jobID }) else { throw SingJobError.jobNotFound(jobID) }
        return found
    }

    func statuses(limit: Int) async -> [SingJobStatus] { Array(held.reversed().prefix(limit)) }

    func cancel(jobID: String) async throws -> SingJobStatus {
        guard let index = held.firstIndex(where: { $0.jobID == jobID }) else { throw SingJobError.jobNotFound(jobID) }
        guard !held[index].phase.isTerminal, !held[index].phase.hasLanded else {
            throw SingJobError.jobFinished(jobID)
        }
        cancelled.append(jobID)
        held[index].cancelRequested = true
        return held[index]
    }
}

/// A call log both spies write to synchronously, so the ORDER of two writes can be asserted.
final class SingWireCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var calls: [String] { lock.withLock { entries } }
    func append(_ call: String) { lock.withLock { entries.append(call) } }
}

/// A spy in front of THE lyrics write: records each call, then calls the store's own `setClipLyrics`.
@MainActor
final class SingWireLyricsSpy: SingLyricsWriting {
    struct Call: Equatable { var clipId: UUID; var text: String; var undoLabel: String }
    private(set) var calls: [Call] = []
    let store: ProjectStore
    let log: SingWireCallLog?

    init(store: ProjectStore, log: SingWireCallLog? = nil) {
        self.store = store
        self.log = log
    }

    @discardableResult
    func setClipLyrics(clipId: UUID, text: String, undoLabel: String) throws -> Clip {
        calls.append(Call(clipId: clipId, text: text, undoLabel: undoLabel))
        log?.append("setClipLyrics")
        return try store.setClipLyrics(clipId: clipId, text: text, undoLabel: undoLabel)
    }
}

/// A spy in front of THE key change.
@MainActor
final class SingWireTransposeSpy: SongTransposing {
    struct Call: Equatable { var semitones: Int; var excludeTrackIds: Set<UUID>; var dryRun: Bool }
    private(set) var calls: [Call] = []
    let store: ProjectStore

    init(store: ProjectStore) { self.store = store }

    @discardableResult
    func transposeProject(semitones: Int, excludeTrackIds: Set<UUID>, dryRun: Bool) throws -> TransposeReport {
        calls.append(Call(semitones: semitones, excludeTrackIds: excludeTrackIds, dryRun: dryRun))
        return try store.transposeProject(semitones: semitones, excludeTrackIds: excludeTrackIds, dryRun: dryRun)
    }
}

/// The voice recorder window, faked.
@MainActor
final class SingWireFakeRecorder: SingVoiceRecorderPresenting {
    private(set) var opened: [Bool] = []
    func openVoiceRecorder(fromAgent: Bool) throws { opened.append(fromAgent) }
}

/// An install function that counts its calls and finishes only when the test says so.
final class SingWireInstallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var finish: CheckedContinuation<Void, Never>?
    private var released = false

    var calls: Int { lock.withLock { count } }

    var function: SingingEngineInstallCoordinator.InstallFunction {
        { [self] _ in
            lock.withLock { count += 1 }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    if released { return true }
                    finish = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            return .succeeded(installedBytes: 1)
        }
    }

    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { finish = nil }
            return finish
        }
        pending?.resume()
    }
}
