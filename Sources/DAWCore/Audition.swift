import Foundation

/// One note-audition request's answer (m23-d) — what the wire echoes back.
public struct AuditionResult: Sendable, Equatable, Codable {
    public var trackID: UUID
    /// The pitches actually sounded, ascending (post voice-cap, post de-dupe).
    public var pitches: [Int]
    public var velocity: Int
    /// Milliseconds until the controller releases them; 0 for a held audition
    /// (drag / key press) that releases on the caller's own gesture end.
    public var durationMs: Int
    public var outcome: AuditionOutcome

    public var isAudible: Bool { outcome.isAudible }

    public init(trackID: UUID, pitches: [Int], velocity: Int,
                durationMs: Int, outcome: AuditionOutcome) {
        self.trackID = trackID
        self.pitches = pitches
        self.velocity = velocity
        self.durationMs = durationMs
        self.outcome = outcome
    }
}

/// THE policy home for note audition (m23-d): voice cap, retrigger diffing, the
/// liveness heartbeat, the one-shot release, and the hard hold ceiling. UI-free
/// and engine-free (it is handed an `AudioEngineControlling` per call), so it is
/// headless-testable — the piano roll's drag, the keyboard gutter's key press
/// and the `note.audition` wire verb all execute THIS code, which is what makes
/// "one command surface" true rather than aspirational.
///
/// The render side holds MECHANISM only: it knows how to sound a set of pitches
/// and how to kill voices whose main actor stopped heartbeating. Everything
/// about *when* and *which* lives here.
@MainActor
public final class AuditionController {
    /// Simultaneous audition pitches. A drag over a chord can select more; the
    /// lowest N win (a musician anchors on the bass).
    public static let maxVoices = 8
    /// How often a held audition re-asserts itself. Comfortably under
    /// `watchdogSeconds` — 6 heartbeats per window.
    public static let heartbeatMilliseconds = 500
    /// DERIVATION COPY ONLY, never compared against anything: the authority for
    /// when a voice dies is the renderer's own `auditionWatchdogFrames`. This
    /// exists so the heartbeat interval above can be seen to be safe.
    public static let watchdogSeconds = 3.0
    /// Main-actor hard ceiling: a lost mouse-up with the button physically
    /// stuck still terminates.
    public static let maxHoldSeconds = 30.0
    public static let defaultVelocity = 100
    public static let velocityRange = 1...127
    public static let defaultDurationMs = 500
    public static let durationRangeMs = 10...5_000
    public static let pitchRange = 0...127

    /// What the controller believes is sounding right now.
    public private(set) var heldTrackID: UUID?
    public private(set) var heldPitches: [Int] = []
    public private(set) var heldVelocity = defaultVelocity

    private var heartbeatTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var holdStarted: ContinuousClock.Instant?
    /// Injectable so the hold-ceiling gate does not sleep for 30 s.
    var clock: () -> ContinuousClock.Instant = { ContinuousClock.now }

    public init() {}

    /// True while the controller believes voices are open.
    public var isHolding: Bool { heldTrackID != nil && !heldPitches.isEmpty }

    /// SET semantics: "exactly these pitches should be sounding on `trackID`
    /// now". `[]` stops. Idempotent — re-calling with the same set pushes no
    /// events but still heartbeats, which is precisely what a held note needs.
    /// A DIFFERENT track silences the previous one first: one audition at a
    /// time, because a drag can only be in one editor.
    @discardableResult
    public func set(trackID: UUID, pitches: [Int], velocity: Int,
                    engine: (any AudioEngineControlling)?) -> AuditionOutcome {
        let clamped = Self.clampPitches(pitches)
        let vel = min(Self.velocityRange.upperBound,
                      max(Self.velocityRange.lowerBound, velocity))

        if let heldTrackID, heldTrackID != trackID {
            engine?.setAuditionPitches(trackID: heldTrackID, pitches: [], velocity: 0)
            self.heldTrackID = nil
            heldPitches = []
        }

        guard !clamped.isEmpty else {
            stop(engine: engine)
            return .sounded
        }

        guard let engine else {
            heldTrackID = trackID
            heldPitches = clamped
            heldVelocity = vel
            return .unsupported
        }

        let outcome = engine.setAuditionPitches(
            trackID: trackID, pitches: clamped.map { UInt8($0) }, velocity: UInt8(vel))
        // `noRenderer`/`unsupported` delivered nothing — do not start holding
        // state (and a heartbeat) for voices that do not exist.
        guard outcome != .noRenderer, outcome != .unsupported else {
            heldTrackID = nil
            heldPitches = []
            stopHeartbeat()
            return outcome
        }
        heldTrackID = trackID
        heldPitches = clamped
        heldVelocity = vel
        if holdStarted == nil { holdStarted = clock() }
        startHeartbeat(engine: engine)
        return outcome
    }

    /// A one-shot the caller does not have to release (the wire's entry — an
    /// agent has no mouse-up). Returns IMMEDIATELY; the release rides a task, so
    /// a control connection is never blocked for `durationMs`. A second one-shot
    /// on the same track cancels the first's release: LAST CALL WINS, so two
    /// overlapping calls can never leave a voice unreleased.
    @discardableResult
    public func oneShot(trackID: UUID, pitches: [Int], velocity: Int, durationMs: Int,
                        engine: (any AudioEngineControlling)?) -> AuditionResult {
        let duration = min(Self.durationRangeMs.upperBound,
                           max(Self.durationRangeMs.lowerBound, durationMs))
        let outcome = set(trackID: trackID, pitches: pitches, velocity: velocity, engine: engine)
        releaseTask?.cancel()
        if outcome != .noRenderer, outcome != .unsupported {
            releaseTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(duration))
                guard !Task.isCancelled, let self, self.heldTrackID == trackID else { return }
                self.stop(engine: engine)
            }
        }
        return AuditionResult(trackID: trackID, pitches: Self.clampPitches(pitches),
                              velocity: min(Self.velocityRange.upperBound,
                                            max(Self.velocityRange.lowerBound, velocity)),
                              durationMs: duration, outcome: outcome)
    }

    /// Releases whatever is held on the CURRENT track. Idempotent.
    public func stop(engine: (any AudioEngineControlling)?) {
        releaseTask?.cancel()
        releaseTask = nil
        stopHeartbeat()
        if let heldTrackID {
            engine?.setAuditionPitches(trackID: heldTrackID, pitches: [], velocity: 0)
        }
        heldTrackID = nil
        heldPitches = []
        holdStarted = nil
    }

    /// Releases audition EVERYWHERE — engine shutdown, project boundary, app
    /// resign-active. Idempotent; safe to call with no engine.
    public func stopAll(engine: (any AudioEngineControlling)?) {
        releaseTask?.cancel()
        releaseTask = nil
        stopHeartbeat()
        heldTrackID = nil
        heldPitches = []
        holdStarted = nil
        engine?.stopAllAudition()
    }

    /// De-dupes, clamps to the MIDI range, sorts ascending, and applies the
    /// voice cap by keeping the LOWEST pitches.
    public static func clampPitches(_ pitches: [Int]) -> [Int] {
        Array(Set(pitches.filter { pitchRange.contains($0) }).sorted().prefix(maxVoices))
    }

    // MARK: - Heartbeat

    /// The 500 ms re-assert that keeps a legitimately held key alive past the
    /// render side's 3 s watchdog. Runs ONLY while something is held, so an idle
    /// app schedules nothing. It also enforces the 30 s hard ceiling — the
    /// render watchdog covers a wedged main actor, this covers a live main actor
    /// that never got its mouse-up.
    private func startHeartbeat(engine: any AudioEngineControlling) {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.heartbeatMilliseconds))
                guard !Task.isCancelled, let self, let trackID = self.heldTrackID,
                      !self.heldPitches.isEmpty else { return }
                if let started = self.holdStarted,
                   started.duration(to: self.clock()) > .seconds(Self.maxHoldSeconds) {
                    self.stop(engine: engine)
                    return
                }
                engine.setAuditionPitches(trackID: trackID,
                                          pitches: self.heldPitches.map { UInt8($0) },
                                          velocity: UInt8(self.heldVelocity))
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Test seam: runs one heartbeat iteration synchronously (the repeating task
    /// is the same body). Keeps the hold-ceiling gate off the wall clock.
    @discardableResult
    func heartbeatOnceForTesting(engine: (any AudioEngineControlling)?) -> Bool {
        guard let trackID = heldTrackID, !heldPitches.isEmpty else { return false }
        if let started = holdStarted, started.duration(to: clock()) > .seconds(Self.maxHoldSeconds) {
            stop(engine: engine)
            return false
        }
        engine?.setAuditionPitches(trackID: trackID, pitches: heldPitches.map { UInt8($0) },
                                   velocity: UInt8(heldVelocity))
        return true
    }
}
