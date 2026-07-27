import Foundation
import Testing
@testable import DAWCore

/// m23-d note-audition POLICY, headless: set semantics, the diff, the voice
/// cap, the heartbeat, the one-shot release, the hold ceiling, and the refusals
/// (§13 C10–C12, C14's store half, C17's defeat-switch half). No engine, no
/// renderers, no audio — the render-side mechanism is gated separately by
/// `AuditionRenderTests`.
@MainActor
@Suite("Note audition policy (m23-d)")
struct AuditionControllerTests {
    private func instrumentStore() -> (ProjectStore, FakeEngine, UUID) {
        let store = ProjectStore()
        let engine = FakeEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument)
        engine.clearAuditionCalls()
        return (store, engine, track.id)
    }

    // MARK: - Set semantics and the diff

    @Test("set() is idempotent: an unchanged set still heartbeats, never re-triggers")
    func unchangedSetStillHeartbeats() {
        let controller = AuditionController()
        let engine = FakeEngine()
        let track = UUID()

        controller.set(trackID: track, pitches: [60, 64], velocity: 100, engine: engine)
        controller.set(trackID: track, pitches: [64, 60], velocity: 100, engine: engine)

        // Two calls out — the ENGINE diffs the pitches; the controller's job is
        // to keep asserting the set so the render watchdog sees liveness.
        #expect(engine.auditionCalls.count == 2)
        #expect(engine.auditionCalls.allSatisfy { $0.pitches == [60, 64] })
        #expect(controller.heldPitches == [60, 64])
        #expect(controller.isHolding)
    }

    @Test("an empty set stops, and stopping is idempotent")
    func emptySetStops() {
        let controller = AuditionController()
        let engine = FakeEngine()
        let track = UUID()

        controller.set(trackID: track, pitches: [60], velocity: 100, engine: engine)
        controller.set(trackID: track, pitches: [], velocity: 0, engine: engine)
        controller.set(trackID: track, pitches: [], velocity: 0, engine: engine)
        controller.stop(engine: engine)

        #expect(!controller.isHolding)
        #expect(controller.heldPitches.isEmpty)
        // on, then exactly one release (the repeats hold nothing to release)
        #expect(engine.auditionCalls.count == 2)
        #expect(engine.auditionCalls[1].pitches.isEmpty)
    }

    @Test("switching tracks mid-hold silences the previous track FIRST")
    func trackSwitchSilencesThePrevious() {
        let controller = AuditionController()
        let engine = FakeEngine()
        let first = UUID(), second = UUID()

        controller.set(trackID: first, pitches: [60], velocity: 100, engine: engine)
        controller.set(trackID: second, pitches: [67], velocity: 100, engine: engine)

        #expect(engine.auditionCalls.count == 3)
        #expect(engine.auditionCalls[1].trackID == first)
        #expect(engine.auditionCalls[1].pitches.isEmpty)   // released before the new one sounds
        #expect(engine.auditionCalls[2].trackID == second)
        #expect(controller.heldTrackID == second)
    }

    @Test("the voice cap keeps the LOWEST 8 pitches, de-duped and ascending")
    func voiceCapKeepsTheLowestEight() {
        #expect(AuditionController.clampPitches([72, 60, 64, 60]) == [60, 64, 72])
        let wide = Array(40...60)
        #expect(AuditionController.clampPitches(wide) == Array(40...47))
        #expect(AuditionController.clampPitches([-3, 200, 64]) == [64])
        #expect(AuditionController.clampPitches([]) == [])
    }

    @Test("a noRenderer outcome holds nothing (no heartbeat for voices that don't exist)")
    func noRendererDoesNotHold() {
        let controller = AuditionController()
        let engine = FakeEngine()
        engine.auditionOutcomeStub = .noRenderer

        let outcome = controller.set(trackID: UUID(), pitches: [60], velocity: 100, engine: engine)

        #expect(outcome == .noRenderer)
        #expect(!controller.isHolding)
    }

    @Test("an inaudible outcome still HOLDS — muted is not undelivered")
    func mutedStillHolds() {
        let controller = AuditionController()
        let engine = FakeEngine()
        engine.auditionOutcomeStub = .inaudibleMuted

        let outcome = controller.set(trackID: UUID(), pitches: [60], velocity: 100, engine: engine)

        #expect(outcome == .inaudibleMuted)
        #expect(controller.isHolding)   // the events WERE delivered; the strip is silent
    }

    // MARK: - C11: overlapping one-shots

    @Test("C11 two overlapping one-shots leave ZERO open voices")
    func overlappingOneShotsLeaveNothingOpen() async throws {
        let controller = AuditionController()
        let engine = FakeEngine()
        let track = UUID()

        let first = controller.oneShot(trackID: track, pitches: [60], velocity: 100,
                                       durationMs: 10, engine: engine)
        let second = controller.oneShot(trackID: track, pitches: [60], velocity: 100,
                                        durationMs: 60, engine: engine)
        #expect(first.durationMs == 10 && second.durationMs == 60)
        // The first release was cancelled — LAST CALL WINS.
        var waited = 0
        while controller.isHolding, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(!controller.isHolding)
        #expect(engine.auditionCalls.last?.pitches.isEmpty == true)
        // Exactly ONE release went out, not two.
        #expect(engine.auditionCalls.filter { $0.pitches.isEmpty }.count == 1)
    }

    @Test("C10 the one-shot clamps durationMs into range instead of refusing")
    func oneShotClampsDuration() {
        let controller = AuditionController()
        let engine = FakeEngine()
        let low = controller.oneShot(trackID: UUID(), pitches: [60], velocity: 100,
                                     durationMs: 1, engine: engine)
        controller.stop(engine: engine)
        let high = controller.oneShot(trackID: UUID(), pitches: [60], velocity: 100,
                                      durationMs: 99_999, engine: engine)
        controller.stop(engine: engine)
        #expect(low.durationMs == AuditionController.durationRangeMs.lowerBound)
        #expect(high.durationMs == AuditionController.durationRangeMs.upperBound)
    }

    // MARK: - C12: the stuck-note sweep

    @Test("C12 the 30 s hold ceiling releases a lost mouse-up")
    func holdCeilingReleasesALostGesture() {
        let controller = AuditionController()
        let engine = FakeEngine()
        var now = ContinuousClock.now
        controller.clock = { now }

        controller.set(trackID: UUID(), pitches: [60], velocity: 100, engine: engine)
        #expect(controller.isHolding)
        // Inside the ceiling: the heartbeat re-asserts.
        now = now.advanced(by: .seconds(10))
        #expect(controller.heartbeatOnceForTesting(engine: engine))
        #expect(controller.isHolding)
        // Past it: the same iteration releases instead of re-asserting. Clock is
        // INJECTED — the gate never sleeps for 30 s.
        now = now.advanced(by: .seconds(25))
        #expect(!controller.heartbeatOnceForTesting(engine: engine))
        #expect(!controller.isHolding)
        #expect(engine.auditionCalls.last?.pitches.isEmpty == true)
    }

    @Test("C12 stopAll clears held state and reaches the engine's all-stop")
    func stopAllSweepsEverything() {
        let controller = AuditionController()
        let engine = FakeEngine()
        controller.set(trackID: UUID(), pitches: [60, 64], velocity: 100, engine: engine)
        controller.stopAll(engine: engine)
        #expect(!controller.isHolding)
        #expect(engine.stopAllAuditionCount == 1)
        controller.stopAll(engine: engine)      // idempotent
        #expect(engine.stopAllAuditionCount == 2)
        #expect(!controller.isHolding)
    }

    @Test("C12 a project boundary releases a held audition")
    func projectBoundaryReleasesAudition() throws {
        let (store, engine, track) = instrumentStore()
        try store.auditionPitches(trackID: track, pitches: [60])
        #expect(store.audition.isHolding)

        try store.newProject(discardChanges: true)

        #expect(!store.audition.isHolding)
        #expect(engine.stopAllAuditionCount >= 1)
    }

    // MARK: - Store-level refusals (C10 / C14's store half)

    @Test("C10 the store refuses an unknown track, a non-instrument track, and bad fields")
    func storeRefusalsTeach() throws {
        let (store, engine, track) = instrumentStore()
        let audioTrack = store.addTrack(name: "Vox", kind: .audio)
        engine.clearAuditionCalls()

        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: UUID(), pitches: [60])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: audioTrack.id, pitches: [60])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: Array(40...50))
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [128])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [60], velocity: 0)
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [60], velocity: 200)
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [60], durationMs: 9)
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [60], durationMs: 5_001)
        }
        // EVERY rejection landed before anything was pushed.
        #expect(engine.auditionCalls.isEmpty)
    }

    @Test("C14 a take starts SILENT: a held audition is released, and none can start")
    func auditionRefusedWhileRecording() throws {
        let store = ProjectStore()
        let engine = AuditionTakeEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id
        try store.auditionPitches(trackID: track, pitches: [60])
        #expect(store.audition.isHolding)
        engine.clearAuditionCalls()
        try store.setTrackArm(id: track, armed: true)
        try store.record()
        #expect(store.transport.isRecording)

        // THE HALF A REFUSAL ALONE CANNOT COVER: the voice held when record
        // began. Refusing NEW auditions does nothing about it — the controller
        // heartbeat re-asserts a held voice every 500 ms straight through the
        // take, and the render watchdog would sustain it ~3 s even with the
        // heartbeat stopped. The capture ring can't see an audition, so it
        // would be heard and not recorded. `record()` releases it — through
        // stopAll, so a voice held on ANY track (not just the armed one) is
        // silenced, and the renderer-side flush rides along.
        #expect(engine.stopAllAuditionCount == 1)
        #expect(engine.auditionCalls.isEmpty)              // nothing NEW sounded
        #expect(!store.audition.isHolding)
        engine.clearAuditionCalls()

        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [60])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionPitches(trackID: track, pitches: [60])
        }
        #expect(engine.auditionCalls.isEmpty)   // nothing sounded during the take

        // Stopping is never refused, so a voice cannot get stuck BEHIND the
        // gate. Held straight through the controller here — the store's own
        // door is shut mid-take, which is the point — then released through the
        // store, proving the release path still reaches the engine.
        store.audition.set(trackID: track, pitches: [60], velocity: 100, engine: engine)
        engine.clearAuditionCalls()
        try store.auditionPitches(trackID: track, pitches: [])
        #expect(engine.auditionCalls.count == 1)
        #expect(engine.auditionCalls[0].pitches.isEmpty)
        #expect(!store.audition.isHolding)
    }

    @Test("the store's one-shot returns immediately and echoes what it sounded")
    func storeOneShotEchoesTheRequest() throws {
        // `store.engine` is WEAK — the engine must stay bound for the call.
        let (store, engine, track) = instrumentStore()
        #expect(engine.auditionCalls.isEmpty)
        let result = try store.auditionNote(trackID: track, pitches: [67, 60, 64],
                                            velocity: 90, durationMs: 250)
        #expect(result.trackID == track)
        #expect(result.pitches == [60, 64, 67])       // ascending, de-duped
        #expect(result.velocity == 90)
        #expect(result.durationMs == 250)
        // A FakeEngine has no renderers, but the protocol default is overridden
        // by the spy, so the store's answer is the spy's.
        #expect(result.outcome == .sounded)
        #expect(result.isAudible)
    }

    @Test("velocity clamps rather than throwing inside the controller")
    func controllerClampsVelocity() {
        let controller = AuditionController()
        let engine = FakeEngine()
        controller.set(trackID: UUID(), pitches: [60], velocity: 999, engine: engine)
        #expect(engine.auditionCalls[0].velocity == 127)
        controller.stop(engine: engine)
        controller.set(trackID: UUID(), pitches: [60], velocity: -5, engine: engine)
        #expect(engine.auditionCalls.last?.velocity == 1)
    }

    @Test("the heartbeat interval sits comfortably inside the render watchdog window")
    func heartbeatIntervalIsSafelyInsideTheWatchdog() {
        // Not a numeric contract between two authorities — the renderer's
        // frame count is THE authority. This pins that the derivation copy the
        // controller reasons from still leaves ≥ 4 heartbeats per window.
        let perWindow = AuditionController.watchdogSeconds
            / (Double(AuditionController.heartbeatMilliseconds) / 1_000)
        #expect(perWindow >= 4)
        #expect(AuditionController.maxHoldSeconds > AuditionController.watchdogSeconds)
    }
}

/// Minimal conformer that ALSO accepts a MIDI take (the `BareEngine` shape) —
/// the shared `FakeEngine` uses the protocol's default `startTake`, which
/// refuses MIDI capture, and the refuse-while-recording gate needs a store that
/// actually reaches `transport.isRecording == true`.
@MainActor
private final class AuditionTakeEngine: AudioEngineControlling {
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false
    private(set) var auditionCalls: [(trackID: UUID, pitches: [UInt8], velocity: UInt8)] = []
    private(set) var stopAllAuditionCount = 0

    func clearAuditionCalls() {
        auditionCalls.removeAll()
        stopAllAuditionCount = 0
    }

    func setAuditionPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8) -> AuditionOutcome {
        auditionCalls.append((trackID, pitches, velocity))
        return .sounded
    }

    func stopAllAudition() { stopAllAuditionCount += 1 }

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
