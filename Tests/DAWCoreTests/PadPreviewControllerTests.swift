import Foundation
import Testing
@testable import DAWCore

/// Breath pad P6 — the PREVIEW POLICY layer: the gesture state machine, the
/// 30 Hz cap, the release-to-neutral rule, and the total-duration ceiling.
/// Engine-free: a spy stands in for `AudioEngineControlling`, which is the whole
/// point of putting the policy in DAWCore (design-breath-pad §5.3).
///
/// ⚠️ NOT a `@MainActor` suite. The type is main-actor-isolated, so each test
/// carries `@MainActor` itself — the `OutputDeviceTests`/`InputDeviceTests`
/// shape — because the tree's `@MainActor` suite budget is nearly spent and a
/// whole new isolated suite is the expensive way to buy what one annotation per
/// test buys for free.
@Suite("Breath pad live preview policy (P6)")
struct PadPreviewControllerTests {

    /// Records every controller push in order, and can be told to refuse — the
    /// `noRenderer` case a real engine reports for an audio/bus/unknown track.
    @MainActor
    private final class PreviewSpy: AudioEngineControlling {
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var isRunning = true

        private(set) var pushes: [(trackID: UUID, controller: UInt8, value: UInt8)] = []
        /// Every protocol call in ORDER — the ordering pin below needs the
        /// sequence, not just the counts.
        private(set) var calls: [String] = []
        var outcome: AuditionOutcome = .sounded

        func clear() { pushes.removeAll(); calls.removeAll() }

        func previewController(trackID: UUID, controller: UInt8,
                               value: UInt8) -> AuditionOutcome {
            pushes.append((trackID, controller, value))
            calls.append("previewController")
            return outcome
        }

        func stopAllAudition() { calls.append("stopAllAudition") }

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
        func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                       completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {}
        func stopRecording() {}
    }

    /// A controller whose clock the test drives, so no gate ever sleeps.
    @MainActor
    private static func fixture() -> (PadPreviewController, PreviewSpy, UUID, ManualClock) {
        let clock = ManualClock()
        let pad = PadPreviewController()
        pad.clock = { clock.now }
        return (pad, PreviewSpy(), UUID(), clock)
    }

    /// A monotonic instant the test advances by hand. `ContinuousClock.Instant`
    /// has no public initializer that takes a duration, so the base is captured
    /// once and advanced by `advancing(by:)`.
    @MainActor
    private final class ManualClock {
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { instant }
        func advance(_ duration: Duration) { instant = instant.advanced(by: duration) }
    }

    // MARK: - Rule 1: streaming iff a gesture is open

    @Test("a move with no begin is REFUSED, and nothing reaches the engine")
    @MainActor
    func moveWithoutBeginIsRefused() {
        let (pad, spy, track, _) = Self.fixture()

        #expect(throws: ProjectError.self) {
            try pad.preview(trackID: track, effort: 0.7, phase: .move, engine: spy)
        }
        #expect(spy.pushes.isEmpty, "a refused call must never have moved a controller")
        #expect(!pad.isStreaming)
    }

    @Test("an end with no begin is REFUSED — there is nothing to release")
    @MainActor
    func endWithoutBeginIsRefused() {
        let (pad, spy, track, _) = Self.fixture()

        #expect(throws: ProjectError.self) {
            try pad.preview(trackID: track, effort: 0, phase: .end, engine: spy)
        }
        #expect(spy.pushes.isEmpty)
    }

    @Test("a move addressed at a DIFFERENT track than the open gesture is refused")
    @MainActor
    func moveOnTheWrongTrackIsRefused() throws {
        let (pad, spy, track, _) = Self.fixture()
        try pad.preview(trackID: track, effort: 0.5, phase: .begin, engine: spy)
        spy.clear()

        #expect(throws: ProjectError.self) {
            try pad.preview(trackID: UUID(), effort: 0.9, phase: .move, engine: spy)
        }
        #expect(spy.pushes.isEmpty)
        #expect(pad.isStreaming, "the ORIGINAL gesture is untouched by the refusal")
    }

    @Test("an END addressed at a DIFFERENT track than the open gesture is refused")
    @MainActor
    func endOnTheWrongTrackIsRefused() throws {
        // ⛔ The twin of the move guard, and the sharper of the two. Without it an
        // `end` naming track B releases the gesture open on track A and answers
        // with a result naming B — the strip that moved is not the one the reply
        // describes, which is this tree's characteristic failure mode (an answer
        // that looks valid). A refusal is the only honest outcome.
        let (pad, spy, track, _) = Self.fixture()
        let other = UUID()
        try pad.preview(trackID: track, effort: 0.5, phase: .begin, engine: spy)
        spy.clear()

        #expect(throws: ProjectError.self) {
            try pad.preview(trackID: other, effort: 0, phase: .end, engine: spy)
        }
        #expect(spy.pushes.isEmpty, "a refused end must move NO strip, least of all the open one")
        #expect(pad.isStreaming, "the gesture on the original track survives")
        #expect(pad.gestureTrackID == track)

        // …and the right track still ends cleanly, so the guard is a guard and
        // not a wedge.
        let ended = try pad.preview(trackID: track, effort: 0, phase: .end, engine: spy)
        #expect(!pad.isStreaming)
        #expect(ended.delivered)
        #expect(spy.pushes.count == 1)
    }

    @Test("isStreaming is false before begin and after end — the wire-visible law")
    @MainActor
    func streamingFlagTracksTheGesture() throws {
        let (pad, spy, track, _) = Self.fixture()
        #expect(!pad.isStreaming)

        let begun = try pad.preview(trackID: track, effort: 0.5, phase: .begin, engine: spy)
        #expect(begun.streaming)
        #expect(pad.isStreaming)

        let ended = try pad.preview(trackID: track, effort: 0, phase: .end, engine: spy)
        #expect(!ended.streaming)
        #expect(!pad.isStreaming)
    }

    // MARK: - Rule 2: the 30 Hz cap, with begin/end exempt

    @Test("begin always delivers, bypassing the rate cap")
    @MainActor
    func beginAlwaysDelivers() throws {
        let (pad, spy, track, _) = Self.fixture()
        let result = try pad.preview(trackID: track, effort: 0.5, phase: .begin, engine: spy)

        #expect(result.delivered)
        #expect(spy.pushes.count == 1)
        #expect(spy.pushes.first?.controller == 11)
        #expect(spy.pushes.first?.value == 64)   // round(0.5 * 127)
    }

    @Test("moves inside one 30 Hz window are COALESCED, and the window then reopens")
    @MainActor
    func rapidMovesAreCoalesced() throws {
        let (pad, spy, track, clock) = Self.fixture()
        try pad.preview(trackID: track, effort: 0.0, phase: .begin, engine: spy)
        spy.clear()

        // Three moves inside the same window: none may reach the engine.
        for effort in [0.2, 0.4, 0.6] {
            let r = try pad.preview(trackID: track, effort: effort, phase: .move, engine: spy)
            #expect(!r.delivered)
        }
        #expect(spy.pushes.isEmpty, "the cap is the ring's protection and it must actually cap")

        // Past the window, the CURRENT value goes out — not a stale queued one.
        clock.advance(.milliseconds(40))
        let r = try pad.preview(trackID: track, effort: 0.8, phase: .move, engine: spy)
        #expect(r.delivered)
        #expect(spy.pushes.count == 1)
        #expect(spy.pushes.first?.value == UInt8(102))   // round(0.8 * 127)
    }

    @Test("a dot held STILL pushes nothing even when the window is open")
    @MainActor
    func unchangedValuesAreNotPushed() throws {
        let (pad, spy, track, clock) = Self.fixture()
        try pad.preview(trackID: track, effort: 0.5, phase: .begin, engine: spy)
        spy.clear()

        for _ in 0..<5 {
            clock.advance(.milliseconds(40))
            let r = try pad.preview(trackID: track, effort: 0.5, phase: .move, engine: spy)
            #expect(!r.delivered)
        }
        #expect(spy.pushes.isEmpty)
    }

    @Test("a value the cap DROPPED is not later mistaken for one the strip already holds")
    @MainActor
    func theChangeFilterReadsWhatWasDeliveredNotWhatWasAsked() throws {
        // The subtle bug this pins: if the change filter remembered the last
        // ASKED-FOR value, a request dropped by the cap would poison it and the
        // same value would then never be delivered at all.
        let (pad, spy, track, clock) = Self.fixture()
        try pad.preview(trackID: track, effort: 0.0, phase: .begin, engine: spy)
        spy.clear()

        // Asked for 0.8 inside the window ⇒ dropped.
        #expect(try !pad.preview(trackID: track, effort: 0.8, phase: .move, engine: spy).delivered)
        // Window reopens; the SAME value is asked for again and MUST land.
        clock.advance(.milliseconds(40))
        #expect(try pad.preview(trackID: track, effort: 0.8, phase: .move, engine: spy).delivered)
        #expect(spy.pushes.count == 1)
        #expect(spy.pushes.first?.value == 102)
    }

    @Test("a push the engine could not deliver is not remembered as delivered")
    @MainActor
    func noRendererIsNotRememberedAsDelivered() throws {
        let (pad, spy, track, clock) = Self.fixture()
        spy.outcome = .noRenderer

        let begun = try pad.preview(trackID: track, effort: 0.5, phase: .begin, engine: spy)
        #expect(!begun.delivered, "noRenderer delivered nothing, so the result must not claim it did")

        // The next attempt at the SAME value must therefore still be tried.
        spy.outcome = .sounded
        clock.advance(.milliseconds(40))
        let again = try pad.preview(trackID: track, effort: 0.5, phase: .move, engine: spy)
        #expect(again.delivered)
        #expect(spy.pushes.count == 2)
    }

    // MARK: - Rule 3: end restores NEUTRAL, it does not park the last value

    @Test("end pushes the controller's NEUTRAL default, never the last effort")
    @MainActor
    func endRestoresNeutral() throws {
        // ⛔ THE DETERMINISM RULE. A CC is sticky and nothing takes it back, so
        // parking the last preview value would make the next playback quieter
        // than a fresh bounce of the same project — precisely what THE PAD LAW
        // (§5.1) forbids. Neutral is not an invented constant: it is DAWCore's
        // one definition of what the schedule itself emits for that controller
        // when no lane point precedes.
        let (pad, spy, track, clock) = Self.fixture()
        try pad.preview(trackID: track, effort: 0.05, phase: .begin, engine: spy)
        clock.advance(.milliseconds(40))
        try pad.preview(trackID: track, effort: 0.02, phase: .move, engine: spy)
        spy.clear()

        let ended = try pad.preview(trackID: track, effort: 0.02, phase: .end, engine: spy)

        #expect(spy.pushes.count == 1)
        #expect(spy.pushes.first?.controller == 11)
        #expect(spy.pushes.first?.value == 127,
                "CC 11's neutral is FULL — an abandoned gesture must not leave the strip quiet")
        #expect(spy.pushes.first?.value
                == UInt8(MIDIControllerType.cc(controller: 11).neutralDefault))
        #expect(ended.controllerValue == 127)
        #expect(ended.effort == nil, "end carries no effort by construction")
        #expect(ended.delivered)
    }

    @Test("end IGNORES the rate cap and the change filter — the release always lands")
    @MainActor
    func endBypassesTheCap() throws {
        let (pad, spy, track, _) = Self.fixture()
        // Begin at full effort: the delivered value is ALREADY 127, which is
        // also neutral, so a change filter applied to the release would swallow
        // it… and then a lower-effort gesture later would find a stale ledger.
        try pad.preview(trackID: track, effort: 1.0, phase: .begin, engine: spy)
        spy.clear()

        // No clock advance at all: the window is wide open and unchanged.
        try pad.preview(trackID: track, effort: 1.0, phase: .end, engine: spy)
        #expect(spy.pushes.count == 1)
        #expect(spy.pushes.first?.value == 127)
    }

    @Test("end restores the NON-DEFAULT controller's own neutral, not CC 11's")
    @MainActor
    func endRestoresTheRightNeutralForAnotherCC() throws {
        let (pad, spy, track, _) = Self.fixture()
        // CC 74's neutral is 0, not 127 — a hard-coded 127 release would be
        // wrong here and this is the test that says so.
        try pad.preview(trackID: track, effort: 0.9, phase: .begin, expressionCC: 74, engine: spy)
        spy.clear()

        try pad.preview(trackID: track, effort: 0.9, phase: .end, engine: spy)
        #expect(spy.pushes.count == 1)
        #expect(spy.pushes.first?.controller == 74)
        #expect(spy.pushes.first?.value == UInt8(MIDIControllerType.cc(controller: 74).neutralDefault))
        #expect(spy.pushes.first?.value == 0)
    }

    @Test("a begin elsewhere releases the previous gesture to neutral first")
    @MainActor
    func beginElsewhereReleasesTheOldGesture() throws {
        let (pad, spy, first, _) = Self.fixture()
        let second = UUID()
        try pad.preview(trackID: first, effort: 0.1, phase: .begin, engine: spy)
        spy.clear()

        try pad.preview(trackID: second, effort: 0.9, phase: .begin, engine: spy)

        #expect(spy.pushes.count == 2)
        #expect(spy.pushes.first?.trackID == first)
        #expect(spy.pushes.first?.value == 127, "the abandoned track must not be left parked")
        #expect(spy.pushes.last?.trackID == second)
        #expect(spy.pushes.last?.value == UInt8((0.9 * 127).rounded()))
    }

    @Test("stop() releases an open gesture to neutral and is idempotent")
    @MainActor
    func stopReleasesAndIsIdempotent() throws {
        let (pad, spy, track, _) = Self.fixture()
        try pad.preview(trackID: track, effort: 0.3, phase: .begin, engine: spy)
        spy.clear()

        #expect(pad.stop(engine: spy))
        #expect(spy.pushes.count == 1)
        #expect(spy.pushes.first?.value == 127)
        #expect(!pad.isStreaming)

        #expect(!pad.stop(engine: spy), "a second stop has nothing to do")
        #expect(spy.pushes.count == 1)
    }

    // MARK: - Rule 4: the total-duration ceiling

    @Test("a gesture past its ceiling is released to neutral and refused")
    @MainActor
    func theCeilingReleasesAnAbandonedGesture() throws {
        let (pad, spy, track, clock) = Self.fixture()
        try pad.preview(trackID: track, effort: 0.2, phase: .begin, engine: spy)
        spy.clear()

        // A drag legitimately holds the dot STILL for many seconds — this is a
        // TOTAL-duration ceiling, never an idle timeout — so advance past 30 s.
        clock.advance(.seconds(PadPreviewController.maxGestureSeconds + 1))

        #expect(throws: ProjectError.self) {
            try pad.preview(trackID: track, effort: 0.9, phase: .move, engine: spy)
        }
        #expect(spy.pushes.count == 1)
        #expect(spy.pushes.first?.value == 127, "the ceiling releases, it does not merely refuse")
        #expect(!pad.isStreaming)
    }

    @Test("the ceiling does NOT fire inside the window — a long, still hold is legal")
    @MainActor
    func theCeilingDoesNotFireEarly() throws {
        let (pad, spy, track, clock) = Self.fixture()
        try pad.preview(trackID: track, effort: 0.2, phase: .begin, engine: spy)
        spy.clear()

        clock.advance(.seconds(PadPreviewController.maxGestureSeconds - 1))
        let r = try pad.preview(trackID: track, effort: 0.9, phase: .move, engine: spy)
        #expect(r.delivered)
        #expect(pad.isStreaming)
        #expect(spy.pushes.count == 1)
        #expect(spy.pushes.first?.value != 127 || r.controllerValue == 114)
    }

    // MARK: - Ranges, and the effort mapping

    @Test("effort maps monotonically across the FULL 0…127 lane")
    @MainActor
    func effortMapsFullScaleAndMonotonically() {
        // ⚠️ The mapping deliberately is NOT `BreathContour.scaled`'s law, whose
        // default `EffortResponse` is the identity — mirroring that would emit
        // 127 at EVERY effort and ship a dead control (P1's finding 5, a third
        // time). Full-scale and monotone is the property that makes the pad
        // audible by construction.
        #expect(PadPreviewController.controllerValue(forEffort: 0) == 0)
        #expect(PadPreviewController.controllerValue(forEffort: 1) == 127)
        #expect(PadPreviewController.controllerValue(forEffort: 0.5) == 64)
        var previous = -1
        for step in 0...100 {
            let value = PadPreviewController.controllerValue(forEffort: Double(step) / 100.0)
            #expect(value >= previous)
            previous = value
        }
        // Out-of-range is clamped, never wrapped into a bogus MIDI byte.
        #expect(PadPreviewController.controllerValue(forEffort: -5) == 0)
        #expect(PadPreviewController.controllerValue(forEffort: 5) == 127)
    }

    @Test("an out-of-range effort or CC is refused with a sentence, not clamped")
    @MainActor
    func outOfRangeIsRefused() {
        let (pad, spy, track, _) = Self.fixture()

        #expect(throws: ProjectError.self) {
            try pad.preview(trackID: track, effort: 1.5, phase: .begin, engine: spy)
        }
        #expect(throws: ProjectError.self) {
            try pad.preview(trackID: track, effort: -0.1, phase: .begin, engine: spy)
        }
        #expect(throws: ProjectError.self) {
            try pad.preview(trackID: track, effort: 0.5, phase: .begin,
                            expressionCC: 128, engine: spy)
        }
        #expect(spy.pushes.isEmpty)
        #expect(!pad.isStreaming)
    }

    @Test("with NO engine the gesture machine still works — it simply reports unsupported")
    @MainActor
    func worksHeadlessWithoutAnEngine() throws {
        // This is exactly why the anti-vacuity gate in DAWEngineTests exists: the
        // policy layer keeps working against an engine that cannot preview, so a
        // forgotten engine override would be invisible from here.
        let pad = PadPreviewController()
        let track = UUID()
        let begun = try pad.preview(trackID: track, effort: 0.5, phase: .begin, engine: nil)
        #expect(begun.outcome == .unsupported)
        #expect(!begun.delivered)
        #expect(pad.isStreaming)
        let ended = try pad.preview(trackID: track, effort: 0.5, phase: .end, engine: nil)
        #expect(!pad.isStreaming)
        // ⚠️ `end` used to hardcode `delivered: true`, and this test passed OVER
        // that lie by not asserting it. Nothing can have been delivered through a
        // nil engine, and `end` computes `delivered` with `move`'s predicate
        // verbatim so the two phases can never drift apart.
        #expect(!ended.delivered)
        #expect(ended.outcome == .unsupported)
    }

    // MARK: - The release must never START the audio hardware

    @Test("a release that never parked anything touches the engine at all")
    @MainActor
    func aReleaseWithNothingParkedPushesNothing() throws {
        // ⛔ THIS GUARD IS NOT TIDINESS. `AudioEngine.previewController` starts
        // CoreAudio for a FIRST touch (the pad must sound with the transport
        // stopped) and only recognises a release by the ledger entry it holds for
        // that track. A gesture whose pushes were all refused leaves NO entry, so
        // a release pushed anyway would read as a first touch — and the paths
        // that send one are the project boundary and app RESIGN-ACTIVE. Booting
        // the audio hardware as the app goes away is the bug this prevents.
        let (pad, spy, track, _) = Self.fixture()
        spy.outcome = .noRenderer

        let begun = try pad.preview(trackID: track, effort: 0.5, phase: .begin, engine: spy)
        #expect(!begun.delivered)
        spy.clear()
        spy.outcome = .sounded          // the engine would happily answer now

        let ended = try pad.preview(trackID: track, effort: 0, phase: .end, engine: spy)
        #expect(spy.pushes.isEmpty, "nothing was ever parked, so nothing needs restoring")
        #expect(!ended.delivered)
        #expect(!pad.isStreaming, "the gesture still closes — the guard skips the push, not the state")
    }

    @Test("the project boundary releases the pad BEFORE the engine drops its ledger")
    @MainActor
    func projectBoundaryReleasesThePadFirst() throws {
        // ⛔ AN ORDERING PIN, and the order is load-bearing (unlike `panic()`'s,
        // which is documented as merely defensive). `AudioEngine.stopAllAudition()`
        // CLEARS the controller-preview ledger — the only thing that tells the
        // engine a push is a release rather than a cold first touch. Clear it
        // first and the neutral that follows starts the audio hardware on
        // resign-active. Sequence, not counts, is what proves it.
        let spy = PreviewSpy()
        let store = ProjectStore()
        store.engine = spy
        let track = store.addTrack(name: "Sax", kind: .instrument)
        try store.previewEffort(trackID: track.id, value: 0.4, phase: .begin)
        spy.clear()

        store.stopAllAudition()

        #expect(spy.calls == ["previewController", "stopAllAudition"],
                "the pad's neutral must go out while the engine still knows it is a release")
    }

    @Test("the 30 Hz cap is the number the design's ring arithmetic depends on")
    @MainActor
    func theCapIsTheDocumentedNumber() {
        // The overflow argument is arithmetic, not taste: a capacity-64 ring that
        // drains FULLY every quantum holds 0–1 events at 30 Hz against ~93
        // quanta/s. If someone raises this, that argument has to be redone.
        #expect(PadPreviewController.maxPushesPerSecond == 30.0)
        #expect(PadPreviewController.minimumPushInterval == .microseconds(33_333))
        #expect(PadPreviewController.defaultExpressionCC == 11)
    }
}
