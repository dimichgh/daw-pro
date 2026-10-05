import Foundation
import Testing
@testable import DAWCore

/// m34-l — THE SUSTAIN (DAMPER) PEDAL, headless.
///
/// ══ THE FEATURE, IN THE USER'S OWN WORDS ════════════════════════════════════
///
/// *"when I play piano and as soon as I lift the finger from the key it stops
/// the sound. Is it intended behavior, is it how real piano works? I remember it
/// somehow sustains/continue the sound while pianist plays next notes. Is it
/// related to pedals."* — yes to both. A real piano's dampers fall on key
/// release; the damper pedal holds them off. This is that pedal.
///
/// ══ WHAT THIS SUITE PINS AND WHAT IT DELIBERATELY CANNOT ════════════════════
///
/// Policy only: WHEN a CC 64 is pushed, with WHAT value, carrying WHICH capture
/// verdict, and — the leg the whole feature hangs on — that a stand-down can
/// never leave it down. No engine, no renderers, no audio.
///
/// ⛔ **THAT AN INSTRUMENT ACTUALLY HONOURS CC 64 IS NOT ASSERTED HERE AND MUST
/// NOT BE READ OUT OF A GREEN RUN.** A spy conformer proves the byte left the
/// store, which is exactly the "agrees with itself through a dead pipe" failure
/// this tree keeps paying for. The audible half is measured against the REAL
/// renderer by `Tests/DAWEngineTests/AuditionPedalSustainTests.swift`, and
/// against all three shipped instrument paths by
/// `scripts/gates/_m34l-sustain-pedal-smoke.mjs`.
@MainActor
@Suite("Live sustain pedal (m34-l)")
struct LiveSustainPedalTests {

    // MARK: - The two edges

    @Test("pressing pushes CC 64 = 127; lifting pushes CC 64 = 0")
    func theTwoEdgesAreTheMIDIStandardValues() {
        let controller = LivePlayController()
        let engine = SustainSpyEngine()
        let track = UUID()

        controller.setSustain(trackID: track, down: true, captureIntoTake: false,
                              engine: engine)
        controller.setSustain(trackID: track, down: false, captureIntoTake: false,
                              engine: engine)

        // ⚠️ >= 64 is DOWN and < 64 is UP is the MIDI 1.0 standard, not a choice
        // this repo gets to make, so the two ends are pinned by value.
        #expect(engine.expressionCalls.count == 2)
        #expect(engine.expressionCalls[0].controller == 64)
        #expect(engine.expressionCalls[0].value == 127)
        #expect(engine.expressionCalls[1].controller == 64)
        #expect(engine.expressionCalls[1].value == 0)
        #expect(!controller.sustainDown)
    }

    @Test("the state survives the call: down stays down until it is lifted")
    func theLatchIsSticky() {
        let controller = LivePlayController()
        let engine = SustainSpyEngine()
        let track = UUID()

        #expect(!controller.sustainDown)
        let pressed = controller.setSustain(trackID: track, down: true,
                                            captureIntoTake: false, engine: engine)
        #expect(pressed.down)
        #expect(pressed.pushed)
        #expect(controller.sustainDown)
        #expect(controller.sustainTrackID == track)

        // ⭐ THE POINT OF A LATCH: notes come and go underneath it and it stays.
        controller.set(trackID: track, pitches: [60], velocity: 100,
                       captureIntoTake: false, engine: engine)
        controller.set(trackID: track, pitches: [], velocity: 0,
                       captureIntoTake: false, engine: engine)
        #expect(controller.sustainDown,
                "all keys up lifted the pedal — that is the feature working, not a stand-down")
    }

    /// ⛔⛔ **THE SINGLE MOST IMPORTANT LEG IN THE SUITE.** `set(pitches: [])`
    /// runs on every all-keys-up, and all keys up WITH THE PEDAL DOWN is
    /// precisely the moment the pedal is doing its job. A lift wired into
    /// `stopReleasing` would make the pedal a no-op that still *looked*
    /// implemented — the tree's characteristic failure, and the one failure mode
    /// a pedal has that no smoke test counting CC bytes would catch.
    @Test("all keys up does NOT lift the pedal — the release path pushes no CC 64")
    func releasingEveryKeyLeavesThePedalDown() {
        let controller = LivePlayController()
        let engine = SustainSpyEngine()
        let track = UUID()

        controller.setSustain(trackID: track, down: true, captureIntoTake: false,
                              engine: engine)
        controller.set(trackID: track, pitches: [60, 64], velocity: 100,
                       captureIntoTake: false, engine: engine)
        engine.clear()
        controller.set(trackID: track, pitches: [], velocity: 0,
                       captureIntoTake: false, engine: engine)

        #expect(controller.sustainDown)
        #expect(engine.expressionCalls.isEmpty,
                "the all-keys-up path pushed a controller — it must only push notes")
        // And the notes really were released, so this is not passing because
        // nothing happened at all.
        #expect(engine.livePlayCalls.count == 1)
        #expect(engine.livePlayCalls[0].pitches.isEmpty)
    }

    // MARK: - The state filter

    @Test("re-pressing a pedal that is already down pushes nothing, and says so")
    func theLatchIsStateFiltered() {
        let controller = LivePlayController()
        let engine = SustainSpyEngine()
        let track = UUID()

        controller.setSustain(trackID: track, down: true, captureIntoTake: false,
                              engine: engine)
        let again = controller.setSustain(trackID: track, down: true,
                                          captureIntoTake: false, engine: engine)
        // ⚠️ DELIBERATELY UNLIKE `PadPreviewController`'s `.move`, whose ingest
        // is NOT gated on its strip filter because a value the strip already
        // holds is still a value being performed at that instant. A latch has no
        // such continuum: re-asserting down is the same press, not a second one.
        #expect(engine.expressionCalls.count == 1)
        #expect(again.down)
        #expect(!again.pushed, "an unchanged latch must report the no-op honestly")

        // And a lift that has nothing to lift is equally silent.
        engine.clear()
        controller.setSustain(trackID: track, down: false, captureIntoTake: false,
                              engine: engine)
        controller.setSustain(trackID: track, down: false, captureIntoTake: false,
                              engine: engine)
        #expect(engine.expressionCalls.count == 1)
    }

    @Test("pressing on a SECOND track lifts the first — one pedal, like one pair of hands")
    func pedallingAnotherTrackLiftsTheFirst() {
        let controller = LivePlayController()
        let engine = SustainSpyEngine()
        let first = UUID(), second = UUID()

        controller.setSustain(trackID: first, down: true, captureIntoTake: false,
                              engine: engine)
        engine.clear()
        controller.setSustain(trackID: second, down: true, captureIntoTake: false,
                              engine: engine)

        #expect(engine.expressionCalls.count == 2)
        // ORDER IS THE ASSERTION: the old track is released BEFORE the new one
        // is pressed, or a track the user walked away from is left droning.
        #expect(engine.expressionCalls[0].trackID == first)
        #expect(engine.expressionCalls[0].value == 0)
        #expect(engine.expressionCalls[1].trackID == second)
        #expect(engine.expressionCalls[1].value == 127)
        #expect(controller.sustainTrackID == second)
    }

    // MARK: - Stand-down

    /// Every DAWCore site that stands live play down calls `stopAll`:
    /// `record()`, `recordLayer()`, `stopAllAudition()`, `panic()`,
    /// `newProject()`, `applyOpenedState()`. Putting the lift there is what
    /// makes all six structural instead of six things to remember.
    @Test("stopAll lifts the pedal — and lifts it AFTER releasing the notes")
    func stopAllLiftsThePedalAfterTheNotes() {
        let controller = LivePlayController()
        let engine = SustainSpyEngine()
        let track = UUID()

        controller.setSustain(trackID: track, down: true, captureIntoTake: true,
                              engine: engine)
        controller.set(trackID: track, pitches: [60], velocity: 100,
                       captureIntoTake: true, engine: engine)
        engine.clear()
        controller.stopAll(engine: engine)

        #expect(!controller.sustainDown)
        #expect(controller.sustainTrackID == nil)
        // ORDER: notes first, then the pedal. The take's lane then reads "the
        // notes ended, then the pedal came up", which is what happened — and the
        // note-offs land on voices the pedal is no longer deferring.
        #expect(engine.log == [.livePlay(pitches: []), .expression(controller: 64, value: 0)],
                "wrong order or a missing call — \(engine.log)")
    }

    @Test("stopAll with no pedal down pushes no controller at all")
    func stopAllIsAStructuralNoOpWithoutAPedal() {
        let controller = LivePlayController()
        let engine = SustainSpyEngine()
        let track = UUID()

        controller.set(trackID: track, pitches: [60], velocity: 100,
                       captureIntoTake: false, engine: engine)
        engine.clear()
        controller.stopAll(engine: engine)
        // Every existing caller of `stopAll` in the tree hits this branch, so
        // this leg is what says m34-l changed no shipped behaviour.
        #expect(engine.expressionCalls.isEmpty)
    }

    @Test("liftSustain is idempotent and safe with no engine at all")
    func liftIsIdempotentAndEngineless() {
        let controller = LivePlayController()
        #expect(!controller.liftSustain(engine: nil))
        controller.setSustain(trackID: UUID(), down: true, captureIntoTake: false,
                              engine: nil)
        // With no engine the push comes back `.unsupported`, which is NOT
        // delivery — so the latch must not be remembered as down.
        #expect(!controller.sustainDown,
                "a pedal that reached no engine was remembered as down")
        #expect(!controller.liftSustain(engine: nil))
    }

    // MARK: - The capture verdict

    /// ⛔⛔ **GATE THE ONS, NEVER GATE THE OFFS**, in its controller-lane form:
    /// the lift rides the verdict from the PRESS, never a fresh one. A disarm
    /// mid-hold must still land the closing CC 64 = 0, or the take's lane ends
    /// at 127 — and CC 64 is one of the types `resetsAtClipOnset` deliberately
    /// does NOT clear at a clip boundary, so every clip after it would inherit a
    /// pedal nobody pressed.
    @Test("the LIFT carries the capture verdict from the PRESS, not a fresh one")
    func theLiftRidesThePressVerdict() {
        let controller = LivePlayController()
        let engine = SustainSpyEngine()
        let track = UUID()

        controller.setSustain(trackID: track, down: true, captureIntoTake: true,
                              engine: engine)
        // The user disarms mid-hold; the store's fresh verdict is now false.
        controller.setSustain(trackID: track, down: false, captureIntoTake: false,
                              engine: engine)

        #expect(engine.expressionCalls.count == 2)
        #expect(engine.expressionCalls[0].captureIntoTake)
        #expect(engine.expressionCalls[1].captureIntoTake,
                "the closing CC 64 = 0 skipped the take — the lane will park at 127")
    }

    @Test("a press that reached NO renderer is not remembered as down")
    func anUndeliveredPressIsNotHeld() {
        let controller = LivePlayController()
        let engine = SustainSpyEngine()
        engine.outcomeStub = .noRenderer
        let track = UUID()

        let result = controller.setSustain(trackID: track, down: true,
                                           captureIntoTake: false, engine: engine)
        // ⭐ THE READ-BACK IS THE ANSWER, NOT AN ACK. A caller that trusted its
        // own request would light a lamp over an instrument that does not exist.
        #expect(!result.down)
        #expect(!controller.sustainDown)
        // And the NEXT press is not filtered away as "already up".
        engine.outcomeStub = .sounded
        let retry = controller.setSustain(trackID: track, down: true,
                                          captureIntoTake: false, engine: engine)
        #expect(retry.down)
        #expect(engine.expressionCalls.count == 2)
    }

    // MARK: - The store funnel

    @Test("playLiveSustain refuses a PRESS on a non-instrument track and never a LIFT")
    func pressIsValidatedAndLiftIsNot() throws {
        let store = ProjectStore()
        let engine = SustainSpyEngine()
        store.engine = engine
        let audio = store.addTrack(name: "audio", kind: .audio)

        #expect(throws: ProjectError.self) {
            try store.playLiveSustain(trackID: audio.id, down: true)
        }
        #expect(engine.expressionCalls.isEmpty,
                "a refused press still moved a controller")

        // ⛔ A LIFT IS NEVER REFUSED — not on the wrong kind of track, and not
        // on a track that has gone entirely. `liftSustain` finds nothing down
        // and is a silent no-op, which is the honest answer.
        #expect(throws: Never.self) {
            try store.playLiveSustain(trackID: audio.id, down: false)
        }
        #expect(throws: Never.self) {
            try store.playLiveSustain(trackID: UUID(), down: false)
        }
    }

    @Test("playLiveSustain is NOT refused while recording — the whole reason it exists")
    func pedallingIsAllowedMidTake() throws {
        let store = ProjectStore()
        let engine = SustainSpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "keys", kind: .instrument)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        #expect(store.transport.isRecording)
        engine.clear()

        // `previewEffort` throws `transportBusy` here by design. This path is
        // CAPTURED, so the assumption that refusal protects is true rather than
        // false — the `playLiveNotes` argument, one control over.
        let result = try store.playLiveSustain(trackID: track.id, down: true)
        #expect(result.down)
        #expect(engine.expressionCalls.count == 1)
        #expect(engine.expressionCalls[0].value == 127)
    }

    @Test("the capture verdict is isRecording AND isArmed AND instrument — playLiveNotes' rule")
    func captureVerdictMatchesTheNotePath() throws {
        let store = ProjectStore()
        let engine = SustainSpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "keys", kind: .instrument)

        // Not recording: nothing captured.
        try store.playLiveSustain(trackID: track.id, down: true)
        #expect(engine.expressionCalls.last?.captureIntoTake == false)
        try store.playLiveSustain(trackID: track.id, down: false)

        // Recording but NOT armed — the footgun state: it sounds, it is not kept.
        // A SECOND track is armed so `record()` has something to capture, which
        // keeps this leg about ARM STATE rather than about the transport.
        let other = store.addTrack(name: "other", kind: .instrument)
        try store.setTrackArm(id: other.id, armed: true)
        try store.record()
        #expect(store.transport.isRecording)
        try store.playLiveSustain(trackID: track.id, down: true)
        #expect(engine.expressionCalls.last?.captureIntoTake == false)
        try store.playLiveSustain(trackID: track.id, down: false)

        // Recording AND armed: kept.
        try store.setTrackArm(id: track.id, armed: true)
        try store.playLiveSustain(trackID: track.id, down: true)
        #expect(engine.expressionCalls.last?.captureIntoTake == true)
    }

    /// ⛔⛔ **A STAND-DOWN MUST NEVER OUTLIVE ITS TAKE.** The lift has to reach
    /// the capture session BEFORE `finish()` closes the lanes, or the clip's
    /// sustain lane ends at 127 and every clip that plays after it inherits a
    /// pedal nobody pressed.
    @Test("ending a TAKE lifts the pedal, and does it before the engine finalizes")
    func takeEndLiftsThePedalBeforeStopRecording() throws {
        let store = ProjectStore()
        let engine = SustainSpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "keys", kind: .instrument)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        try store.playLiveSustain(trackID: track.id, down: true)
        engine.clear()

        store.stop()

        #expect(!store.livePlay.sustainDown)
        #expect(engine.log.contains(.expression(controller: 64, value: 0)),
                "the take ended with the pedal still down — \(engine.log)")
        let liftIndex = engine.log.firstIndex(of: .expression(controller: 64, value: 0))
        let finalizeIndex = engine.log.firstIndex(of: .stopRecording)
        #expect(liftIndex != nil && finalizeIndex != nil)
        #expect(liftIndex! < finalizeIndex!,
                "the pedal lifted AFTER the take was finalized — the lane parks at 127")
    }

    /// ⚠️ **DELIBERATELY NOT ON A PLAIN PLAYBACK STOP**, and stated as a test so
    /// nobody "fixes" it later: stopping a jam is not the end of a performance,
    /// the latch is the user's explicit choice, and its lamp is lit. Turning it
    /// off underneath them would be a state change with no cause they can see.
    @Test("stopping PLAYBACK (no take) deliberately leaves the pedal alone")
    func plainPlaybackStopLeavesThePedalDown() throws {
        let store = ProjectStore()
        let engine = SustainSpyEngine()
        store.engine = engine
        let track = store.addTrack(name: "keys", kind: .instrument)
        store.play()
        try store.playLiveSustain(trackID: track.id, down: true)
        engine.clear()

        store.stop()

        #expect(store.livePlay.sustainDown)
        #expect(engine.expressionCalls.isEmpty)
    }
}

// MARK: - The spy

/// Records every controller and note push. ⚠️ **`log` is ORDERED and several
/// legs assert on the order** — "the notes released, then the pedal came up" is
/// a sequence claim, and a set-shaped spy could not make it.
@MainActor
private final class SustainSpyEngine: AudioEngineControlling {
    enum Event: Equatable {
        case livePlay(pitches: [UInt8])
        case expression(controller: UInt8, value: UInt8)
        case stopRecording
        case stopAllAudition
    }

    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false

    private(set) var log: [Event] = []
    private(set) var expressionCalls: [(trackID: UUID, controller: UInt8, value: UInt8,
                                        captureIntoTake: Bool)] = []
    private(set) var livePlayCalls: [(trackID: UUID, pitches: [UInt8])] = []
    var outcomeStub: AuditionOutcome = .sounded

    func clear() {
        log.removeAll()
        expressionCalls.removeAll()
        livePlayCalls.removeAll()
    }

    func setLiveExpression(trackID: UUID, controller: UInt8, value: UInt8,
                           captureIntoTake: Bool) -> LiveExpressionOutcome {
        expressionCalls.append((trackID, controller, value, captureIntoTake))
        log.append(.expression(controller: controller, value: value))
        let delivered = outcomeStub != .noRenderer && outcomeStub != .unsupported
        return LiveExpressionOutcome(audition: outcomeStub,
                                     capturedPoints: captureIntoTake && delivered ? 1 : 0,
                                     recording: captureIntoTake && delivered)
    }

    func setLivePlayPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8,
                            captureIntoTake: Bool) -> LivePlayOutcome {
        livePlayCalls.append((trackID, pitches))
        log.append(.livePlay(pitches: pitches))
        return LivePlayOutcome(audition: pitches.isEmpty ? .sounded : outcomeStub,
                               capturedEdges: pitches.count, recording: captureIntoTake)
    }

    func stopRecording() { log.append(.stopRecording) }
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
}
