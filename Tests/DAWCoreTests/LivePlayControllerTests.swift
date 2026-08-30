import Foundation
import Testing
@testable import DAWCore

/// m23-ct LIVE PLAY policy, headless: set semantics, the diff, the
/// most-recent-wins voice cap, the heartbeat, the hold ceiling, the
/// arbitration against audition, and — the pin the whole feature hangs on —
/// **`playLiveNotes` SUCCEEDS while the transport is recording**, which is the
/// single behavioural difference from `auditionPitches` and the entire reason
/// this path exists.
///
/// No engine, no renderers, no audio. The engine-side mechanism (does an edge
/// actually reach a `MIDICaptureSession`) is gated separately, against the REAL
/// `AudioEngine`, by `Tests/DAWEngineTests/LivePlayCaptureTests.swift` — the
/// silent protocol default means a fake conformer would otherwise pass a test
/// the real engine could fail.
@MainActor
@Suite("Live play policy (m23-ct)")
struct LivePlayControllerTests {

    // MARK: - Set semantics and the diff

    @Test("set() is idempotent: an unchanged set still heartbeats, never re-triggers")
    func unchangedSetStillHeartbeats() {
        let controller = LivePlayController()
        let engine = LivePlaySpyEngine()
        let track = UUID()

        controller.set(trackID: track, pitches: [60, 64], velocity: 100,
                       captureIntoTake: true, engine: engine)
        controller.set(trackID: track, pitches: [60, 64], velocity: 100,
                       captureIntoTake: true, engine: engine)

        // Two calls out — the ENGINE diffs the pitches; the controller's job is
        // to keep asserting the set so the render watchdog sees liveness. The
        // second call carries the SAME set, which is what makes it contribute
        // zero edges to the take.
        #expect(engine.livePlayCalls.count == 2)
        #expect(engine.livePlayCalls.allSatisfy { $0.pitches == [60, 64] })
        #expect(controller.heldPitches == [60, 64])
        #expect(controller.isHolding)
    }

    @Test("an empty set stops, and stopping is idempotent")
    func emptySetStops() {
        let controller = LivePlayController()
        let engine = LivePlaySpyEngine()
        let track = UUID()

        controller.set(trackID: track, pitches: [60], velocity: 100,
                       captureIntoTake: false, engine: engine)
        controller.set(trackID: track, pitches: [], velocity: 0,
                       captureIntoTake: false, engine: engine)
        controller.set(trackID: track, pitches: [], velocity: 0,
                       captureIntoTake: false, engine: engine)
        controller.stop(engine: engine)

        #expect(!controller.isHolding)
        #expect(controller.heldPitches.isEmpty)
        // on, then exactly one release (the repeats hold nothing to release)
        #expect(engine.livePlayCalls.count == 2)
        #expect(engine.livePlayCalls[1].pitches.isEmpty)
    }

    @Test("switching tracks mid-hold releases the previous track FIRST, through the capture path")
    func trackSwitchReleasesThePreviousThroughCapture() {
        let controller = LivePlayController()
        let engine = LivePlaySpyEngine()
        let first = UUID(), second = UUID()

        controller.set(trackID: first, pitches: [60], velocity: 100,
                       captureIntoTake: true, engine: engine)
        controller.set(trackID: second, pitches: [67], velocity: 100,
                       captureIntoTake: true, engine: engine)

        #expect(engine.livePlayCalls.count == 3)
        #expect(engine.livePlayCalls[1].trackID == first)
        #expect(engine.livePlayCalls[1].pitches.isEmpty)
        // The release must go through setLivePlayPitches, not a bare audition
        // stop: that is what closes the note in the take instead of leaving it
        // open to clamp at the take's end.
        #expect(engine.livePlayCalls[1].captureIntoTake)
        #expect(engine.livePlayCalls[2].trackID == second)
        #expect(controller.heldTrackID == second)
    }

    @Test("the voice cap keeps the MOST RECENTLY PRESSED 8, in press order — NOT audition's lowest-8")
    func voiceCapKeepsTheMostRecentEight() {
        // Press order is preserved; the 9th key pressed means the 9th key.
        #expect(LivePlayController.clampPitches([60, 62, 64, 65, 67, 69, 71, 72, 74])
                == [62, 64, 65, 67, 69, 71, 72, 74])
        // A repeated pitch keeps its NEWEST statement's position.
        #expect(LivePlayController.clampPitches([72, 60, 64, 60]) == [72, 64, 60])
        #expect(LivePlayController.clampPitches([-3, 200, 64]) == [64])
        #expect(LivePlayController.clampPitches([]) == [])

        // ⭐ THE DIVERGENCE, PINNED SIDE BY SIDE. Audition anchors on the bass
        // (a drag over a chord is a musical selection); live play answers the
        // key the typist actually pressed. A "unification" refactor breaks this
        // line, which is the point of writing it.
        let nineAscending = [60, 62, 64, 65, 67, 69, 71, 72, 74]
        #expect(AuditionController.clampPitches(nineAscending) == [60, 62, 64, 65, 67, 69, 71, 72])
        #expect(LivePlayController.clampPitches(nineAscending) != AuditionController.clampPitches(nineAscending))
    }

    @Test("a noRenderer outcome holds nothing (no heartbeat for voices that don't exist)")
    func noRendererDoesNotHold() {
        let controller = LivePlayController()
        let engine = LivePlaySpyEngine()
        engine.auditionOutcomeStub = .noRenderer

        let outcome = controller.set(trackID: UUID(), pitches: [60], velocity: 100,
                                     captureIntoTake: true, engine: engine)

        #expect(outcome.audition == .noRenderer)
        #expect(!controller.isHolding)
    }

    @Test("an inaudible outcome still HOLDS — muted is not undelivered")
    func mutedStillHolds() {
        let controller = LivePlayController()
        let engine = LivePlaySpyEngine()
        engine.auditionOutcomeStub = .inaudibleMuted

        let outcome = controller.set(trackID: UUID(), pitches: [60], velocity: 100,
                                     captureIntoTake: true, engine: engine)

        #expect(outcome.audition == .inaudibleMuted)
        #expect(controller.isHolding)
    }

    @Test("with no engine the controller still holds, and reports unsupported")
    func engineLessStillHolds() {
        let controller = LivePlayController()
        let outcome = controller.set(trackID: UUID(), pitches: [60], velocity: 100,
                                     captureIntoTake: true, engine: nil)
        #expect(outcome == .unsupported)
        #expect(!outcome.recording)   // the honesty light is OFF with no engine
        #expect(controller.isHolding)
    }

    // MARK: - Heartbeat and the hold ceiling

    @Test("the heartbeat re-asserts the SAME set (zero edges) and carries the last capture verdict")
    func heartbeatReassertsTheSameSet() {
        let controller = LivePlayController()
        let engine = LivePlaySpyEngine()
        let track = UUID()

        controller.set(trackID: track, pitches: [60, 67], velocity: 90,
                       captureIntoTake: true, engine: engine)
        #expect(controller.heartbeatOnceForTesting(engine: engine))
        #expect(controller.heartbeatOnceForTesting(engine: engine))

        #expect(engine.livePlayCalls.count == 3)
        #expect(engine.livePlayCalls.dropFirst().allSatisfy {
            $0.pitches == [60, 67] && $0.velocity == 90 && $0.captureIntoTake
        })
    }

    @Test("the 30 s hold ceiling releases a stuck key, through the capture path")
    func holdCeilingReleases() {
        let controller = LivePlayController()
        let engine = LivePlaySpyEngine()
        var now = ContinuousClock.now
        controller.clock = { now }
        let track = UUID()

        controller.set(trackID: track, pitches: [60], velocity: 100,
                       captureIntoTake: true, engine: engine)
        #expect(controller.isHolding)
        now = now.advanced(by: .seconds(LivePlayController.maxHoldSeconds + 1))
        #expect(!controller.heartbeatOnceForTesting(engine: engine))

        #expect(!controller.isHolding)
        #expect(engine.livePlayCalls.count == 2)
        #expect(engine.livePlayCalls[1].pitches.isEmpty)
        #expect(engine.livePlayCalls[1].captureIntoTake)  // the release reaches the take
    }

    // MARK: - THE PIN: recording does not refuse

    @Test("⭐ playLiveNotes SUCCEEDS while the transport is recording — the whole point of the feature")
    func playLiveNotesSucceedsWhileRecording() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id
        try store.setTrackArm(id: track, armed: true)
        try store.record()
        #expect(store.transport.isRecording)
        engine.clear()

        let result = try store.playLiveNotes(trackID: track, pitches: [60])

        #expect(result.pitches == [60])
        #expect(store.livePlay.isHolding)
        #expect(engine.livePlayCalls.count == 1)
        // The domain verdict: recording AND armed AND an instrument track.
        #expect(engine.livePlayCalls[0].captureIntoTake)

        // The companion half, unchanged: audition STILL refuses while recording.
        // Relaxing it would make a piano-roll DRAG capturable, fabricating notes
        // into a take the user never played.
        #expect(throws: ProjectError.self) {
            try store.auditionPitches(trackID: track, pitches: [64])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [64])
        }
    }

    @Test("captureIntoTake is the domain verdict: recording AND armed AND an instrument track")
    func captureVerdictNeedsAllThree() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let armed = store.addTrack(name: "Keys", kind: .instrument).id
        let idle = store.addTrack(name: "Pad", kind: .instrument).id
        try store.setTrackArm(id: armed, armed: true)

        // Not recording: audible, but going into no take.
        engine.clear()
        let stopped = try store.playLiveNotes(trackID: armed, pitches: [60])
        #expect(!engine.livePlayCalls[0].captureIntoTake)
        #expect(!stopped.isRecording)
        try store.playLiveNotes(trackID: armed, pitches: [])

        try store.record()
        engine.clear()

        // Recording + armed + instrument → captured.
        try store.playLiveNotes(trackID: armed, pitches: [60])
        #expect(engine.livePlayCalls[0].captureIntoTake)
        try store.playLiveNotes(trackID: armed, pitches: [])

        // Recording, instrument, but NOT armed → sounds, captures nothing.
        engine.clear()
        let unarmed = try store.playLiveNotes(trackID: idle, pitches: [64])
        #expect(!engine.livePlayCalls[0].captureIntoTake)
        #expect(!unarmed.isRecording)
    }

    @Test("[] is allowed always — unvalidated, and it carries the take verdict so the take's note closes")
    func emptyIsAlwaysAllowed() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let audio = store.addTrack(name: "Gtr", kind: .audio).id
        let keys = store.addTrack(name: "Keys", kind: .instrument).id
        try store.setTrackArm(id: keys, armed: true)

        // Never throws, even for a track kind that could never sound.
        try store.playLiveNotes(trackID: audio, pitches: [])
        try store.playLiveNotes(trackID: UUID(), pitches: [])

        try store.record()
        try store.playLiveNotes(trackID: keys, pitches: [60])
        engine.clear()
        try store.playLiveNotes(trackID: keys, pitches: [])
        #expect(engine.livePlayCalls.count == 1)
        #expect(engine.livePlayCalls[0].pitches.isEmpty)
        #expect(engine.livePlayCalls[0].captureIntoTake)   // the take sees the note-off
    }

    @Test("a DISARM mid-hold still closes the take's note — the release uses the last known verdict")
    func disarmMidHoldStillClosesTheNote() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let keys = store.addTrack(name: "Keys", kind: .instrument).id
        let other = store.addTrack(name: "Bass", kind: .instrument).id
        try store.setTrackArm(id: keys, armed: true)
        try store.setTrackArm(id: other, armed: true)
        try store.record()
        try store.playLiveNotes(trackID: keys, pitches: [60])
        #expect(engine.livePlayCalls.last?.captureIntoTake == true)

        // Disarm mid-hold: the store's fresh verdict is now FALSE…
        try store.setTrackArm(id: keys, armed: false)
        engine.clear()
        try store.playLiveNotes(trackID: keys, pitches: [])

        // …but the controller releases with the LAST KNOWN verdict, so the
        // engine still gets a chance to close the note. Without this the open
        // note clamps to the end of the take and lands on every OTHER armed
        // instrument track as a duration the user never played.
        #expect(engine.livePlayCalls.count == 1)
        #expect(engine.livePlayCalls[0].pitches.isEmpty)
        #expect(engine.livePlayCalls[0].captureIntoTake)
    }

    // MARK: - Validation (the SAME validator audition runs)

    @Test("validation rejects non-instrument tracks, unknown tracks, 9 pitches, and a bad velocity")
    func validationRejects() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let audio = store.addTrack(name: "Gtr", kind: .audio).id
        let bus = store.addTrack(name: "Verb", kind: .bus).id
        let keys = store.addTrack(name: "Keys", kind: .instrument).id
        engine.clear()

        #expect(throws: ProjectError.self) { try store.playLiveNotes(trackID: audio, pitches: [60]) }
        #expect(throws: ProjectError.self) { try store.playLiveNotes(trackID: bus, pitches: [60]) }
        #expect(throws: ProjectError.self) { try store.playLiveNotes(trackID: UUID(), pitches: [60]) }
        #expect(throws: ProjectError.self) {
            try store.playLiveNotes(trackID: keys, pitches: [60, 61, 62, 63, 64, 65, 66, 67, 68])
        }
        #expect(throws: ProjectError.self) {
            try store.playLiveNotes(trackID: keys, pitches: [128])
        }
        #expect(throws: ProjectError.self) {
            try store.playLiveNotes(trackID: keys, pitches: [60], velocity: 0)
        }
        #expect(throws: ProjectError.self) {
            try store.playLiveNotes(trackID: keys, pitches: [60], velocity: 128)
        }

        // EVERY rejection landed before anything was pushed.
        #expect(engine.livePlayCalls.isEmpty)
        #expect(!store.livePlay.isHolding)
    }

    // MARK: - Arbitration: one live-note owner at a time

    @Test("playLiveNotes takes the ledger from a held AUDITION (no 500 ms ping-pong)")
    func livePlayTakesTheLedgerFromAudition() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id

        try store.auditionPitches(trackID: track, pitches: [60])
        #expect(store.audition.isHolding)
        engine.clear()

        try store.playLiveNotes(trackID: track, pitches: [64])

        #expect(!store.audition.isHolding)
        #expect(store.livePlay.isHolding)
        // The audition release happened BEFORE the live note sounded.
        #expect(engine.log.first == .audition(trackID: track, pitches: []))
        #expect(engine.log.contains(.livePlay(trackID: track, pitches: [64], captureIntoTake: false)))
    }

    @Test("auditionPitches takes the ledger back from a held LIVE PLAY (the mirror)")
    func auditionTakesTheLedgerFromLivePlay() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id

        try store.playLiveNotes(trackID: track, pitches: [60])
        #expect(store.livePlay.isHolding)
        engine.clear()

        try store.auditionPitches(trackID: track, pitches: [64])

        #expect(!store.livePlay.isHolding)
        #expect(store.audition.isHolding)
        #expect(engine.log.first == .livePlay(trackID: track, pitches: [], captureIntoTake: false))
    }

    @Test("auditionNote (the one-shot) ALSO takes the ledger back — it opens a hold too")
    func auditionOneShotTakesTheLedgerFromLivePlay() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id

        try store.playLiveNotes(trackID: track, pitches: [60])
        engine.clear()

        try store.auditionNote(trackID: track, pitches: [64], durationMs: 5_000)

        #expect(!store.livePlay.isHolding)
        #expect(engine.log.first == .livePlay(trackID: track, pitches: [], captureIntoTake: false))
    }

    @Test("a REJECTED audition leaves a held live note alone (validate, then arbitrate)")
    func rejectedAuditionDoesNotStealTheLedger() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id
        let audio = store.addTrack(name: "Gtr", kind: .audio).id

        try store.playLiveNotes(trackID: track, pitches: [60])
        engine.clear()

        #expect(throws: ProjectError.self) { try store.auditionPitches(trackID: audio, pitches: [64]) }

        #expect(store.livePlay.isHolding)
        #expect(engine.log.isEmpty)
    }

    // MARK: - §6: every flush site clears the NEW ledger (one test per row)

    @Test("flush row 1 — stopAllAudition() releases live play, BEFORE the engine-wide sweep")
    func stopAllAuditionFlushesLivePlay() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id
        try store.playLiveNotes(trackID: track, pitches: [60])
        engine.clear()

        store.stopAllAudition()

        #expect(!store.livePlay.isHolding)
        try assertReleasedBeforeSweep(engine, track: track)
    }

    @Test("flush row 2 — panic() releases live play, BEFORE the engine-wide sweep")
    func panicFlushesLivePlay() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id
        try store.setTrackArm(id: track, armed: true)
        try store.record()
        try store.playLiveNotes(trackID: track, pitches: [60])
        engine.clear()

        _ = store.panic()

        #expect(!store.livePlay.isHolding)
        // ⚠️ ORDER IS LOAD-BEARING HERE, and panic is the site where it bites:
        // it is used MID-TAKE by definition. `stopAllAudition()` wipes the
        // engine's `auditionVoices` wholesale; run it first and the live-play
        // release diffs against an empty ledger, ingests zero note-offs, and
        // the open note clamps to the end of the take.
        try assertReleasedBeforeSweep(engine, track: track, captureIntoTake: true)
    }

    @Test("flush row 3 — record() releases live play: a take starts SILENT, and pre-anchor ons are dropped")
    func recordFlushesLivePlay() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id
        try store.setTrackArm(id: track, armed: true)
        try store.playLiveNotes(trackID: track, pitches: [60])
        #expect(store.livePlay.isHolding)
        engine.clear()

        try store.record()

        // Not merely hygiene: `MIDICaptureSession` DROPS every pre-anchor
        // note-on, so a key still down when the take opens would be heard and
        // never captured — the exact lie audition's release exists to prevent.
        #expect(!store.livePlay.isHolding)
        try assertReleasedBeforeSweep(engine, track: track)
        // And nothing NEW sounded on the way into the take.
        #expect(!engine.log.contains { event in
            if case .livePlay(_, let pitches, _) = event { return !pitches.isEmpty }
            return false
        })
    }

    @Test("flush row 4 — a NEW project releases live play, BEFORE the engine-wide sweep")
    func newProjectFlushesLivePlay() throws {
        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id
        try store.playLiveNotes(trackID: track, pitches: [60])
        engine.clear()

        try store.newProject(discardChanges: true)

        #expect(!store.livePlay.isHolding)
        try assertReleasedBeforeSweep(engine, track: track)
    }

    @Test("flush row 5 — OPENING a project releases live play, BEFORE the engine-wide sweep")
    func openProjectFlushesLivePlay() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23ct-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let seed = ProjectStore()
        seed.addTrack(name: "Saved", kind: .instrument)
        let path = dir.appendingPathComponent("Opened").path
        try seed.saveProject(to: path)

        let store = ProjectStore()
        let engine = LivePlaySpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id
        try store.playLiveNotes(trackID: track, pitches: [60])
        engine.clear()

        _ = try store.openProject(at: path)

        #expect(!store.livePlay.isHolding)
        try assertReleasedBeforeSweep(engine, track: track)
    }

    /// The §6 assertion every flush row shares: the live-play release went out
    /// on the LIVE-PLAY path (so a rolling take sees the note-offs) and it went
    /// out BEFORE `stopAllAudition()` wiped the engine's ledger.
    private func assertReleasedBeforeSweep(_ engine: LivePlaySpyEngine, track: UUID,
                                           captureIntoTake: Bool = false) throws {
        // A surviving DAWCore ledger + an engine-side flush resurrects the note
        // within one 500 ms heartbeat (m23-af, MEASURED red at -17.65 LUFS two
        // heartbeats after a panic). That is what this index proves absent.
        let releaseIndex = try #require(engine.log.firstIndex(
            of: .livePlay(trackID: track, pitches: [], captureIntoTake: captureIntoTake)))
        let sweepIndex = try #require(engine.log.firstIndex(of: .stopAllAudition))
        #expect(releaseIndex < sweepIndex)
    }
}

/// Ordered spy over the three calls whose RELATIVE ORDER is load-bearing
/// (m23-ct §6): the live-play push, the audition push, and the engine-wide
/// audition sweep. A count-only spy cannot see the bug this suite pins.
@MainActor
private final class LivePlaySpyEngine: AudioEngineControlling {
    enum Event: Equatable {
        case livePlay(trackID: UUID, pitches: [UInt8], captureIntoTake: Bool)
        case audition(trackID: UUID, pitches: [UInt8])
        case stopAllAudition
    }

    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false

    private(set) var log: [Event] = []
    private(set) var livePlayCalls: [(trackID: UUID, pitches: [UInt8], velocity: UInt8,
                                      captureIntoTake: Bool)] = []
    private(set) var auditionCalls: [(trackID: UUID, pitches: [UInt8], velocity: UInt8)] = []
    var auditionOutcomeStub: AuditionOutcome = .sounded

    func clear() {
        log.removeAll()
        livePlayCalls.removeAll()
        auditionCalls.removeAll()
    }

    func setLivePlayPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8,
                            captureIntoTake: Bool) -> LivePlayOutcome {
        livePlayCalls.append((trackID, pitches, velocity, captureIntoTake))
        log.append(.livePlay(trackID: trackID, pitches: pitches, captureIntoTake: captureIntoTake))
        let outcome = pitches.isEmpty ? .sounded : auditionOutcomeStub
        let delivered = outcome != .noRenderer && outcome != .unsupported
        return LivePlayOutcome(audition: outcome, capturedEdges: pitches.count,
                               recording: captureIntoTake && delivered)
    }

    func setAuditionPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8) -> AuditionOutcome {
        auditionCalls.append((trackID, pitches, velocity))
        log.append(.audition(trackID: trackID, pitches: pitches))
        return pitches.isEmpty ? .sounded : auditionOutcomeStub
    }

    func stopAllAudition() { log.append(.stopAllAudition) }

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
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
    func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                   completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {}
    func stopRecording() {}
}
