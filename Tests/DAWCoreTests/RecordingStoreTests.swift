import Foundation
import Testing
@testable import DAWCore

/// Captures every recording-related intent ProjectStore emits, so the record
/// state machine is testable without AVFoundation or a microphone. Tests fire
/// the captured completion to simulate a finalized take. Internal (not private):
/// the undo suite reuses it for take-completion round-trips.
@MainActor
final class FakeRecordingEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?

    var recordPermission: RecordPermission = .granted
    var startRecordingError: (any Error)?

    private(set) var permissionRequests = 0
    private(set) var startRecordingTransports: [TransportState] = []
    private(set) var startRecordingURLs: [URL] = []
    private(set) var stopRecordingCount = 0
    private(set) var stopPlaybackCount = 0
    private(set) var tracksDidChangeCount = 0
    private(set) var completion: (@MainActor (Result<RecordingResult, Error>) -> Void)?

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) { tracksDidChangeCount += 1 }
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() { stopPlaybackCount += 1 }
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}

    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }

    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        permissionRequests += 1
    }

    var inputDevices: [AudioInputDevice] = []

    func availableInputDevices() -> [AudioInputDevice] { inputDevices }

    func setInputDevice(uid: String?) throws {
        if let uid, !inputDevices.contains(where: { $0.uid == uid }) {
            throw ProjectError.inputDeviceNotFound(uid)
        }
    }

    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        if let startRecordingError { throw startRecordingError }
        startRecordingTransports.append(transport)
        startRecordingURLs.append(url)
        self.completion = completion
    }

    func stopRecording() { stopRecordingCount += 1 }

    /// Simulates the engine finalizing the take.
    func finishTake(_ result: Result<RecordingResult, Error>) {
        completion?(result)
    }
}

@MainActor
@Suite("Recording — ProjectStore state machine")
struct RecordingStoreTests {
    /// Result of a happy 2-second mono take at `url`.
    private func take(_ url: URL, durationSeconds: Double = 2,
                      startOffsetSeconds: Double = 0) -> RecordingResult {
        RecordingResult(
            fileURL: url,
            info: AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 1),
            startOffsetSeconds: startOffsetSeconds
        )
    }

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do {
            try body()
            return nil
        } catch let error as ProjectError {
            return error
        } catch {
            Issue.record("unexpected error type: \(error)")
            return nil
        }
    }

    // T10.
    @Test("record() preconditions throw in order and land in lastRecordingError")
    func recordPreconditions() throws {
        // No engine.
        let bare = ProjectStore()
        var error = projectError { try bare.record() }
        guard case .engineUnavailable = try #require(error) else {
            Issue.record("expected engineUnavailable, got \(String(describing: error))")
            return
        }
        #expect(bare.lastRecordingError == "audio engine not available")
        #expect(!bare.transport.isRecording && !bare.transport.isPlaying)

        // Engine present but playing.
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        store.play()
        error = projectError { try store.record() }
        guard case .transportBusy(let message) = try #require(error) else {
            Issue.record("expected transportBusy, got \(String(describing: error))")
            return
        }
        #expect(message == "stop playback before recording — recording starts from a stopped transport (set a punch window to record into a range)")
        #expect(store.lastRecordingError == message)
        #expect(store.transport.isPlaying && !store.transport.isRecording)  // untouched
        store.stop()

        // Stopped but nothing armed.
        try store.setTrackArm(id: track.id, armed: false)
        error = projectError { try store.record() }
        guard case .noArmedTracks = try #require(error) else {
            Issue.record("expected noArmedTracks, got \(String(describing: error))")
            return
        }
        #expect(store.lastRecordingError
                == "no armed audio or instrument tracks — arm a track (track.setArm) before recording")
        #expect(engine.startRecordingURLs.isEmpty)  // never reached the engine
    }

    // T11.
    @Test("permission gates: denied refuses, undetermined prompts, granted rolls")
    func permissionGates() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)

        engine.recordPermission = .denied
        var error = projectError { try store.record() }
        guard case .recordPermissionDenied = try #require(error) else {
            Issue.record("expected recordPermissionDenied, got \(String(describing: error))")
            return
        }
        #expect(store.lastRecordingError?.contains("microphone access denied") == true)

        engine.recordPermission = .undetermined
        let requestsBefore = engine.permissionRequests
        error = projectError { try store.record() }
        guard case .recordPermissionPending = try #require(error) else {
            Issue.record("expected recordPermissionPending, got \(String(describing: error))")
            return
        }
        #expect(engine.permissionRequests == requestsBefore + 1)  // prompt fired
        #expect(!store.transport.isRecording && !store.transport.isPlaying)

        engine.recordPermission = .granted
        try store.record()
        #expect(store.transport.isRecording && store.transport.isPlaying)
        #expect(store.lastRecordingError == nil)
        #expect(engine.startRecordingURLs.count == 1)
    }

    // T12.
    @Test("finished take fans out: beat 8 @120, 2 s + 0.5 s offset → start 9, length 4")
    func takeFanOut() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let guitar = store.addTrack(name: "Gtr", kind: .audio)
        let vocals = store.addTrack(name: "Vox", kind: .audio)
        try store.setTrackArm(id: guitar.id, armed: true)
        try store.setTrackArm(id: vocals.id, armed: true)
        try store.seek(toBeats: 8)  // tempo stays at the 120 default

        try store.record()
        let transport = try #require(engine.startRecordingTransports.last)
        #expect(transport.positionBeats == 8)
        #expect(transport.isRecording && transport.isPlaying)
        let url = try #require(engine.startRecordingURLs.last)
        #expect(url.lastPathComponent == "take-1.wav")

        store.stop()
        let changesBefore = engine.tracksDidChangeCount
        engine.finishTake(.success(RecordingResult(
            fileURL: url,
            info: AudioFileInfo(durationSeconds: 2, sampleRate: 48_000, channelCount: 2),
            startOffsetSeconds: 0.5
        )))

        let guitarClip = try #require(store.tracks[0].clips.first)
        let vocalClip = try #require(store.tracks[1].clips.first)
        for clip in [guitarClip, vocalClip] {
            #expect(clip.startBeat == 9)      // 8 + 0.5 s * 120/60
            #expect(clip.lengthBeats == 4)    // 2 s * 120/60
            #expect(clip.audioFileURL == url) // one file, shared
            #expect(!clip.isAIGenerated)
        }
        #expect(guitarClip.id != vocalClip.id)  // distinct clip identities
        #expect(guitarClip.name == "Gtr Take 1")
        #expect(vocalClip.name == "Vox Take 1")
        #expect(guitarClip.name.hasSuffix("Take 1") && vocalClip.name.hasSuffix("Take 1"))
        #expect(engine.tracksDidChangeCount == changesBefore + 1)  // fired after creation
        #expect(store.lastRecordingError == nil)
    }

    // T13.
    @Test("a zero-length take is discarded with a readable reason")
    func emptyTakeDiscarded() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)

        try store.record()
        store.stop()
        let url = try #require(engine.startRecordingURLs.last)
        engine.finishTake(.success(take(url, durationSeconds: 0)))

        #expect(store.tracks[0].clips.isEmpty)
        #expect(store.lastRecordingError == "empty take discarded")
    }

    // T14.
    @Test("engine failures surface: async completion and sync throw both roll back")
    func engineFailures() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)

        // Async failure after a successful start.
        try store.record()
        store.stop()
        engine.finishTake(.failure(ProjectError.recordingFailed("input device vanished")))
        #expect(store.tracks[0].clips.isEmpty)
        #expect(store.lastRecordingError == "recording failed: input device vanished")

        // Sync throw from startRecording: both transport flags roll back.
        engine.startRecordingError = ProjectError.recordingFailed("no input")
        #expect(throws: (any Error).self) { try store.record() }
        #expect(!store.transport.isRecording && !store.transport.isPlaying)
        #expect(store.lastRecordingError == "recording failed: no input")
    }

    // T15.
    @Test("stop() while recording routes to stopRecording, never stopPlayback")
    func stopRouting() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)

        try store.record()
        #expect(store.transport.isRecording && store.transport.isPlaying)
        store.stop()
        #expect(engine.stopRecordingCount == 1)
        #expect(engine.stopPlaybackCount == 0)  // engine stops playback internally
        #expect(!store.transport.isRecording && !store.transport.isPlaying)

        // Plain playback still stops through stopPlayback.
        store.play()
        store.stop()
        #expect(engine.stopRecordingCount == 1)
        #expect(engine.stopPlaybackCount == 1)
    }

    // T16.
    @Test("seek/returnToZero/setTempo refuse while recording; loop and arm stay allowed")
    func transportLocksWhileRecording() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        let other = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()

        var error = projectError { try store.seek(toBeats: 4) }
        guard case .transportBusy(let seekMessage) = try #require(error) else {
            Issue.record("expected transportBusy from seek"); return
        }
        #expect(seekMessage == "cannot seek while recording — stop first")

        error = projectError { try store.returnToZero() }
        guard case .transportBusy = try #require(error) else {
            Issue.record("expected transportBusy from returnToZero"); return
        }

        error = projectError { try store.setTempo(90) }
        guard case .transportBusy(let tempoMessage) = try #require(error) else {
            Issue.record("expected transportBusy from setTempo"); return
        }
        #expect(tempoMessage == "cannot change tempo while recording — stop first")
        #expect(store.transport.tempoBPM == 120)  // untouched

        // Loop, arm, and mixer moves stay legal mid-take.
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 8)
        #expect(try store.setTrackArm(id: other.id, armed: true))
        #expect(store.setTrackMute(id: track.id, muted: true))

        store.stop()
        try store.seek(toBeats: 4)  // allowed again
        #expect(store.transport.positionBeats == 4)
    }

    // T17.
    @Test("clip destinations are the tracks armed at record START")
    func armedSetSnapshottedAtStart() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let armed = store.addTrack(name: "A", kind: .audio)
        let unarmed = store.addTrack(name: "B", kind: .audio)
        let doomed = store.addTrack(name: "C", kind: .audio)
        try store.setTrackArm(id: armed.id, armed: true)
        try store.setTrackArm(id: doomed.id, armed: true)

        try store.record()
        // Mid-take churn: disarm A, arm B, delete C entirely.
        try store.setTrackArm(id: armed.id, armed: false)
        try store.setTrackArm(id: unarmed.id, armed: true)
        store.removeTrack(id: doomed.id)

        store.stop()
        let url = try #require(engine.startRecordingURLs.last)
        engine.finishTake(.success(take(url)))

        // A was armed at start → clip lands despite the mid-take disarm.
        #expect(store.tracks[0].clips.count == 1)
        // B armed mid-take → no clip. C removed → skipped, no crash.
        #expect(store.tracks[1].clips.isEmpty)
        #expect(store.lastRecordingError == nil)
    }

    // T20.
    @Test("setPunch while recording throws transportBusy with the exact message")
    func setPunchWhileRecording() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()

        let error = projectError { try store.setPunch(enabled: true, inBeat: 0, outBeat: 8) }
        guard case .transportBusy(let message) = try #require(error) else {
            Issue.record("expected transportBusy from setPunch"); return
        }
        #expect(message == "cannot change punch window while recording — stop first")
        #expect(!store.transport.isPunchEnabled)  // untouched

        store.stop()
        try store.setPunch(enabled: true, inBeat: 0, outBeat: 8)  // allowed again
        #expect(store.transport.isPunchEnabled)
    }

    // T21.
    @Test("record() with the punch window behind the playhead refuses with the exact message")
    func punchBehindPlayhead() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.setPunch(enabled: true, inBeat: 0, outBeat: 4)
        try store.seek(toBeats: 8)  // playhead past the whole window

        let error = projectError { try store.record() }
        guard case .invalidPunchRange(let message) = try #require(error) else {
            Issue.record("expected invalidPunchRange, got \(String(describing: error))")
            return
        }
        #expect(message == "punch window is behind the playhead — seek before punch in or disable punch")
        #expect(store.lastRecordingError == message)
        #expect(!store.transport.isRecording && !store.transport.isPlaying)  // untouched
        #expect(engine.startRecordingURLs.isEmpty)  // never reached the engine

        // Disabling punch clears the refusal — same position records fine.
        try store.setPunch(enabled: false)
        try store.record()
        #expect(store.transport.isRecording)
        #expect(store.lastRecordingError == nil)
    }

    // T22.
    @Test("punched fan-out: startOffsetSeconds lands the clip at the punch-in point")
    func punchedFanOut() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.setPunch(enabled: true, inBeat: 2, outBeat: 6)  // 1 s .. 3 s at 120 BPM

        try store.record()  // from beat 0, tempo 120
        // The engine reads punch straight off the TransportState it was handed.
        let transport = try #require(engine.startRecordingTransports.last)
        #expect(transport.isPunchEnabled)
        #expect(transport.punchInBeat == 2)
        #expect(transport.punchOutBeat == 6)

        store.stop()
        let url = try #require(engine.startRecordingURLs.last)
        // startOffsetSeconds is ANCHOR-relative BY CONTRACT (see
        // RecordingResult.startOffsetSeconds / RecordingWriter.Result): the
        // engine keeps the record anchor as the offset reference even when
        // the accept window starts later, so a punched take reports the
        // record-start → punch-in gap (1 s here) and the trimmed window as
        // the file duration (2 s) — the EXISTING fan-out formula does the
        // rest. A window-relative offset (≈ 0) would land this clip at beat 0
        // (the live-E2E bug); the writer-level regression guard is W5 in
        // RecordingWriterTests.
        engine.finishTake(.success(RecordingResult(
            fileURL: url,
            info: AudioFileInfo(durationSeconds: 2, sampleRate: 48_000, channelCount: 1),
            startOffsetSeconds: 1.0
        )))

        let clip = try #require(store.tracks[0].clips.first)
        #expect(clip.startBeat == 2)    // 0 + 1.0 s × 120/60 == the punch-in beat
        #expect(clip.lengthBeats == 4)  // 2 s × 120/60 == the window's length
        #expect(clip.audioFileURL == url)
        #expect(store.lastRecordingError == nil)
    }

    // T18.
    @Test("take numbering, session directory shape, arm rules, snapshot error field")
    func takeBookkeeping() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)

        // Take 1.
        try store.record()
        store.stop()
        let firstURL = try #require(engine.startRecordingURLs.last)
        engine.finishTake(.success(take(firstURL)))
        #expect(firstURL.lastPathComponent == "take-1.wav")
        let sessionDir = firstURL.deletingLastPathComponent()
        #expect(sessionDir.lastPathComponent.hasPrefix("session-"))
        #expect(sessionDir.path.contains("DAWPro/Recordings"))

        // Take 2: same session dir, bumped take number in file and clip names.
        // Recorded over the SAME range as take 1 → M5 (iii-b) recording
        // auto-group kicks in (spec §3 risk 3, deliberate behavior change):
        // the two takes become a 2-lane take group instead of stacking as
        // sum-overlap clips, newest (take 2) wins the default comp.
        try store.record()
        store.stop()
        let secondURL = try #require(engine.startRecordingURLs.last)
        engine.finishTake(.success(take(secondURL)))
        #expect(secondURL.lastPathComponent == "take-2.wav")
        #expect(secondURL.deletingLastPathComponent() == sessionDir)
        #expect(store.tracks[0].takeGroups.count == 1)
        #expect(store.tracks[0].takeGroups[0].lanes.count == 2)
        #expect(store.tracks[0].takeGroups[0].lanes.map(\.name) == ["Gtr Take 1", "Gtr Take 2"])
        #expect(store.tracks[0].clips.count == 1)  // comp = newest lane, full range
        #expect(store.tracks[0].clips[0].name == "Gtr Take 2")
        #expect(store.tracks[0].clips[0].takeGroupID == store.tracks[0].takeGroups[0].id)

        // setTrackArm rules: unknown id → false; non-audio → throws.
        #expect(try store.setTrackArm(id: UUID(), armed: true) == false)
        let bus = store.addTrack(kind: .bus)
        #expect(throws: ProjectError.self) {
            try store.setTrackArm(id: bus.id, armed: true)
        }
        // Arming while the decision is open fires the prompt, fire-and-forget.
        engine.recordPermission = .undetermined
        let requestsBefore = engine.permissionRequests
        try store.setTrackArm(id: track.id, armed: true)
        #expect(engine.permissionRequests == requestsBefore + 1)

        // The snapshot carries the recording error state for agents.
        #expect(store.snapshot().lastRecordingError == nil)
        engine.recordPermission = .granted
        try store.record()
        store.stop()
        engine.finishTake(.failure(ProjectError.recordingFailed("boom")))
        #expect(store.snapshot().lastRecordingError == "recording failed: boom")
    }
}
