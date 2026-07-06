import Foundation
import Testing
@testable import DAWCore

/// Captures the `startTake` surface ProjectStore drives for MIDI-capable
/// takes, so the M3 (vii) record state machine is testable without CoreMIDI
/// or a microphone. Tests fire the captured completion to simulate a
/// finalized take.
@MainActor
final class FakeTakeEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?

    var recordPermission: RecordPermission = .granted
    var midiInputs: [MIDIInputDevice] = []
    var eventCount = 0

    private(set) var permissionRequests = 0
    private(set) var prepareCalls = 0
    private(set) var startTakeTransports: [TransportState] = []
    private(set) var startTakeAudioURLs: [URL?] = []
    private(set) var startTakeCaptureMIDI: [Bool] = []
    private(set) var tracksDidChangeCount = 0
    private(set) var completion: (@MainActor (Result<TakeResult, Error>) -> Void)?

    func prepare() throws {
        prepareCalls += 1
        isRunning = true
    }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) { tracksDidChangeCount += 1 }
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}

    func renderMixdown(tracks: [Track], tempoBPM: Double, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }

    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        permissionRequests += 1
    }

    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func availableMIDIInputs() -> [MIDIInputDevice] { midiInputs }
    func midiEventCount() -> Int { eventCount }

    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        Issue.record("ProjectStore must drive startTake, not the legacy startRecording")
    }

    func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                   completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
        startTakeTransports.append(transport)
        startTakeAudioURLs.append(audioURL)
        startTakeCaptureMIDI.append(captureMIDI)
        self.completion = completion
    }

    func stopRecording() {}

    /// Simulates the engine finalizing the take.
    func finishTake(_ result: Result<TakeResult, Error>) {
        completion?(result)
    }
}

@MainActor
@Suite("MIDI recording — ProjectStore state machine")
struct MIDIRecordingStoreTests {
    private func midiResult(notes: [MIDINote], lengthBeats: Double = 4,
                            dropped: Bool = false) -> MIDIRecordingResult {
        MIDIRecordingResult(notes: notes, lengthBeats: lengthBeats, droppedEvents: dropped)
    }

    private func arpeggio() -> [MIDINote] {
        [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, velocity: 100, startBeat: 1, lengthBeats: 1),
            MIDINote(pitch: 67, velocity: 100, startBeat: 2, lengthBeats: 1),
        ]
    }

    @Test("arming an instrument track succeeds (and warms the engine); a bus throws")
    func armInstrumentTrackSucceedsBusThrows() throws {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let inst = store.addTrack(kind: .instrument)
        let bus = store.addTrack(kind: .bus)

        let preparesBefore = engine.prepareCalls
        #expect(try store.setTrackArm(id: inst.id, armed: true))
        #expect(store.tracks[0].isArmed)
        #expect(store.hasArmedInstrumentTracks)
        #expect(engine.prepareCalls == preparesBefore + 1)  // graph warmed for thru
        #expect(engine.permissionRequests == 0)             // never the mic prompt

        #expect(throws: ProjectError.self) {
            try store.setTrackArm(id: bus.id, armed: true)
        }
        #expect(!store.tracks[1].isArmed)
    }

    @Test("record() with only an instrument armed skips the microphone gates entirely")
    func recordWithOnlyInstrumentArmedSkipsMicPermission() throws {
        let engine = FakeTakeEngine()
        engine.recordPermission = .undetermined  // would refuse an audio take
        let store = ProjectStore()
        store.engine = engine
        let inst = store.addTrack(kind: .instrument)
        try store.setTrackArm(id: inst.id, armed: true)

        try store.record()  // no permission throw, no prompt
        #expect(engine.permissionRequests == 0)
        #expect(store.transport.isRecording && store.transport.isPlaying)
        #expect(engine.startTakeAudioURLs.last == URL?.none)  // MIDI-only: no file
        #expect(engine.startTakeCaptureMIDI.last == true)
    }

    @Test("a MIDI take lands one clip at the record anchor with canonical notes")
    func midiTakeLandsClipAtRecordAnchorWithCanonicalNotes() throws {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let inst = store.addTrack(name: "Keys", kind: .instrument)
        try store.setTrackArm(id: inst.id, armed: true)
        try store.seek(toBeats: 8)

        try store.record()
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: nil, midi: midiResult(notes: arpeggio(), lengthBeats: 4))))

        let clip = try #require(store.tracks[0].clips.first)
        #expect(clip.name == "Keys Take 1")
        #expect(clip.startBeat == 8)          // the record position, not punch/offset
        #expect(clip.lengthBeats == 4)
        #expect(clip.isMIDI)
        #expect(clip.audioFileURL == nil)
        let notes = try #require(clip.notes)
        #expect(notes.map(\.pitch) == [60, 64, 67])
        #expect(notes == MIDINote.canonicallyOrdered(notes))
        #expect(store.lastRecordingError == nil)
    }

    @Test("a concurrent audio+MIDI take lands both clips in ONE undo step")
    func concurrentAudioAndMIDITakeLandsBothClipsInOneUndoStep() throws {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let vocal = store.addTrack(name: "Vox", kind: .audio)
        let keys = store.addTrack(name: "Keys", kind: .instrument)
        try store.setTrackArm(id: vocal.id, armed: true)
        try store.setTrackArm(id: keys.id, armed: true)

        try store.record()
        #expect(engine.startTakeAudioURLs.last != URL?.none)  // audio side wanted
        #expect(engine.startTakeCaptureMIDI.last == true)
        store.stop()
        let url = try #require(engine.startTakeAudioURLs.last ?? nil)
        engine.finishTake(.success(TakeResult(
            audio: RecordingResult(
                fileURL: url,
                info: AudioFileInfo(durationSeconds: 2, sampleRate: 48_000, channelCount: 1),
                startOffsetSeconds: 0),
            midi: midiResult(notes: arpeggio(), lengthBeats: 4))))

        #expect(store.tracks[0].clips.count == 1)  // audio clip
        #expect(store.tracks[1].clips.count == 1)  // MIDI clip
        #expect(store.tracks[0].clips[0].audioFileURL == url)
        #expect(store.tracks[1].clips[0].isMIDI)
        #expect(store.undoLabel == "Record Take 1")

        try store.undo()  // ONE undo removes the whole take
        #expect(store.tracks[0].clips.isEmpty)
        #expect(store.tracks[1].clips.isEmpty)
    }

    @Test("undo removes the entire take under the Record Take label")
    func undoRemovesEntireTakeUnderRecordTakeLabel() throws {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let keys = store.addTrack(name: "Keys", kind: .instrument)
        try store.setTrackArm(id: keys.id, armed: true)

        try store.record()
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: nil, midi: midiResult(notes: arpeggio()))))
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.undoLabel == "Record Take 1")

        let undone = try store.undo()
        #expect(undone == "Record Take 1")
        #expect(store.tracks[0].clips.isEmpty)
        // Redo restores it.
        try store.redo()
        #expect(store.tracks[0].clips.count == 1)
    }

    @Test("an empty MIDI-only take sets a readable lastRecordingError")
    func emptyMIDIOnlyTakeSetsLastRecordingError() throws {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let keys = store.addTrack(kind: .instrument)
        try store.setTrackArm(id: keys.id, armed: true)

        try store.record()
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: nil, midi: midiResult(notes: [], lengthBeats: 1))))

        #expect(store.tracks[0].clips.isEmpty)
        #expect(store.lastRecordingError == "empty take discarded — no MIDI notes received")

        // A MIXED take with an empty MIDI side lands the audio, no error.
        let vocal = store.addTrack(name: "Vox", kind: .audio)
        try store.setTrackArm(id: vocal.id, armed: true)
        try store.record()
        store.stop()
        let url = try #require(engine.startTakeAudioURLs.last ?? nil)
        engine.finishTake(.success(TakeResult(
            audio: RecordingResult(
                fileURL: url,
                info: AudioFileInfo(durationSeconds: 2, sampleRate: 48_000, channelCount: 1),
                startOffsetSeconds: 0),
            midi: midiResult(notes: [], lengthBeats: 1))))
        #expect(store.tracks[1].clips.count == 1)   // audio landed
        #expect(store.tracks[0].clips.isEmpty)      // no empty MIDI clip
        #expect(store.lastRecordingError == nil)    // not an error
    }

    @Test("the punch window does NOT trim MIDI notes (pins the v0 decision)")
    func punchWindowDoesNotTrimMIDINotes() throws {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let keys = store.addTrack(name: "Keys", kind: .instrument)
        let vocal = store.addTrack(name: "Vox", kind: .audio)
        try store.setTrackArm(id: keys.id, armed: true)
        try store.setTrackArm(id: vocal.id, armed: true)
        try store.setPunch(enabled: true, inBeat: 2, outBeat: 6)

        try store.record()  // from beat 0 — audio will be trimmed to [2, 6]
        store.stop()
        let url = try #require(engine.startTakeAudioURLs.last ?? nil)
        // Engine reports: trimmed audio (window only) + FULL-ROLL MIDI,
        // including notes outside the punch window.
        let fullRoll = [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),   // before punch-in
            MIDINote(pitch: 64, velocity: 100, startBeat: 3, lengthBeats: 1),   // inside
            MIDINote(pitch: 67, velocity: 100, startBeat: 7, lengthBeats: 1),   // after punch-out
        ]
        engine.finishTake(.success(TakeResult(
            audio: RecordingResult(
                fileURL: url,
                info: AudioFileInfo(durationSeconds: 2, sampleRate: 48_000, channelCount: 1),
                startOffsetSeconds: 1.0),
            midi: midiResult(notes: fullRoll, lengthBeats: 8))))

        let audioClip = try #require(store.tracks[1].clips.first)
        #expect(audioClip.startBeat == 2)  // audio: punched to the window
        let midiClip = try #require(store.tracks[0].clips.first)
        #expect(midiClip.startBeat == 0)   // MIDI: full roll from record start
        #expect(midiClip.lengthBeats == 8)
        #expect(midiClip.notes?.count == 3)  // NOTHING trimmed
        #expect(midiClip.notes?.map(\.pitch) == [60, 64, 67])
    }
}
