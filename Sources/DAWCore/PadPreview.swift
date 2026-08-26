import Foundation

/// Where a `pad.previewEffort` call sits in a drag (breath pad P6).
///
/// The phase is not decoration — it is the mechanism by which THE PAD LAW
/// (design-breath-pad §5.1) survives a live preview. §5.2, verbatim:
///
/// > The pad NEVER streams while the transport is simply rolling. Streaming
/// > happens if and only if a gesture is in progress.
///
/// A phase-less "set the preview value" verb could not express that rule, so an
/// agent could leave a controller streaming forever and the next bounce would
/// disagree with what was heard. With phases the rule is a state machine one
/// test can check.
public enum PadPreviewPhase: String, Sendable, Equatable, Codable, CaseIterable {
    /// Pointer down / an agent starting a gesture. Opens streaming and always
    /// delivers, bypassing the rate cap.
    case begin
    /// The dot moved. Rate-capped and change-filtered; refused if no gesture is
    /// open.
    case move
    /// Pointer up, or the gesture abandoned. ALWAYS delivers
    /// `MIDIControllerType.neutralDefault` — never the last preview value. See
    /// `PadPreviewController` for why that is not a detail.
    case end
}

/// What one `pad.previewEffort` call did (breath pad P6) — what the wire echoes
/// back, and what a UI needs to render the pad honestly.
public struct PadPreviewResult: Sendable, Equatable, Codable {
    public var trackID: UUID
    public var phase: PadPreviewPhase
    /// The CC the preview rides (default 11, expression).
    public var controller: Int
    /// The raw MIDI value this call put on that lane, 0…127. On `.end` this is
    /// the controller's NEUTRAL default (127 for CC 11), not the last effort.
    public var controllerValue: Int
    /// Effort as asked for, clamped to 0…1. nil on `.end`, which carries no
    /// effort by construction.
    public var effort: Double?
    /// Is a gesture in progress AFTER this call? `false` after `.end`, and the
    /// wire-visible half of "the pad never streams without a gesture".
    public var streaming: Bool
    /// Did this call reach the engine, or did the 30 Hz cap / the change filter
    /// coalesce it away? A caller that never sees `true` is previewing nothing.
    public var delivered: Bool
    public var outcome: AuditionOutcome

    public var isAudible: Bool { outcome.isAudible }

    public init(trackID: UUID, phase: PadPreviewPhase, controller: Int,
                controllerValue: Int, effort: Double?, streaming: Bool,
                delivered: Bool, outcome: AuditionOutcome) {
        self.trackID = trackID
        self.phase = phase
        self.controller = controller
        self.controllerValue = controllerValue
        self.effort = effort
        self.streaming = streaming
        self.delivered = delivered
        self.outcome = outcome
    }
}

/// THE policy home for the breath pad's live drag preview (P6) — the gesture
/// state machine, the 30 Hz cap, and the release-to-neutral rule. UI-free and
/// engine-free (it is handed an `AudioEngineControlling` per call), exactly like
/// `AuditionController`, so the pad view's drag, the `pad.previewEffort` wire
/// verb, and P7's `BreathPadModel` all execute THIS code.
///
/// ## The three rules, and why each is here rather than in the engine
///
/// **1. Streaming iff a gesture is open.** A `.move` or `.end` with nothing open
/// is REFUSED, not ignored, so "the pad never streams while the transport merely
/// rolls" is enforced on the wire and not only in the UI (design §12). This is
/// the rule that keeps playback, replay and bounce agreeing sample-for-sample:
/// with no gesture, the only thing sounding is the committed lane.
///
/// **2. The 30 Hz cap, with `begin`/`end` exempt.** The arithmetic
/// (design §5.3): the audition ring is capacity 64 and drains FULLY every
/// quantum, so at 30 Hz it holds 0–1 events and overflowing it would need a
/// multi-second audio stall. ⚠️ **The cap lives HERE, with the gesture phase,
/// and that pairing is the whole point.** A cap in the engine cannot tell an
/// intermediate drag frame from the last value of a gesture, so it can drop the
/// value the strip ends up parked at — a correct policy at the wrong cadence
/// looks exactly like a correct policy (m25-k). Because `begin` and `end` bypass
/// it, **every gesture's first and last values are guaranteed to be delivered.**
///
/// **3. `end` restores `MIDIControllerType.neutralDefault`, it does not park the
/// last effort.** ⛔ This is the rule most likely to look wrong and be right, so
/// the reasoning is written down rather than reasoned:
///
/// - A CC is STICKY. Nothing takes it back. Parking the last preview value would
///   leave CC 11 at, say, 12 on a strip whose committed lane has no point until
///   bar 9 — so the next playback is quieter than a fresh bounce of the same
///   project. **That is a determinism break**, and §5.1's law forbids exactly
///   it. "The preview is not the record" has to mean the preview leaves nothing
///   behind.
/// - `neutralDefault` is not an invented constant. It is DAWCore's ONE
///   definition (`MIDIControllerType.neutralDefault`) of *the value a chase
///   snapshot falls back to when no scheduled point precedes a block's start* —
///   i.e. literally what the schedule itself emits for that controller in the
///   absence of a lane point.
/// - It matters most on CC 11, whose neutral is **127 (full)**: a gesture
///   abandoned at low effort would otherwise leave the track quiet with nothing
///   in the UI explaining why — this tree's characteristic silent failure.
///
/// ⛔ **THE LIMIT OF RULE 3, MEASURED — it does not fully restore a track that
/// already has a committed CC lane.** The chase that supplies `neutralDefault`
/// is a SCHEDULE-BUILD-TIME PREFIX (`MIDISchedule.buildEvents`: one synthetic
/// event per lane type at each block's own anchor frame), **not a per-render-
/// block re-assert.** So on a track whose committed lane's last point was, say,
/// 40 and whose next point is bars away, a release mid-playback parks **127**
/// and the strip stays there until that next point — playback is LOUDER than a
/// fresh bounce of the same project over that span. The error is one-directional
/// (toward neutral), self-heals at the next lane point, and cannot happen on a
/// track with no committed lane, which is the pad's own authoring case. Parking
/// the last effort instead would be strictly worse: it diverges in an arbitrary
/// direction and never self-heals. The real fix is to restore *the committed
/// lane's value at the playhead*, which needs `buildEvents`' cross-clip merge
/// (clip-relative beat ∈ [0, clipLen), latest absolute beat wins) SHARED rather
/// than reimplemented — a second, subtly-different copy would be a worse lie
/// than this documented one. Filed as its own roadmap item; not built here.
///
/// **4. A hard gesture ceiling.** A wire caller that sends `begin` and dies would
/// otherwise hold the controller parked forever. `maxGestureSeconds` mirrors
/// `AuditionController.maxHoldSeconds` (30 s) and auto-releases to neutral. A
/// drag legitimately holds the dot STILL for many seconds — that is a musician
/// listening — so this is a total-duration ceiling, never an idle timeout.
@MainActor
public final class PadPreviewController {
    /// The push cap, per design §5.3 step 3. Not taste: see rule 2 above.
    public static let maxPushesPerSecond = 30.0
    /// `1 / maxPushesPerSecond`, as the `Duration` the gate actually compares.
    public static let minimumPushInterval = Duration.microseconds(
        Int(1_000_000.0 / maxPushesPerSecond))
    /// Main-actor hard ceiling on one gesture — the `AuditionController.max-
    /// HoldSeconds` precedent, for a caller whose "mouse-up" never arrives.
    public static let maxGestureSeconds = 30.0
    /// CC 11, expression: the lane `clip.applyEffortShape` writes by default and
    /// the one the built-in sampler routes to amplitude with no opt-in.
    public static let defaultExpressionCC = 11
    public static let controllerRange = 0...127
    public static let effortRange = 0.0...1.0

    /// The track a gesture is open on, or nil when nothing is streaming.
    public private(set) var gestureTrackID: UUID?
    /// The CC the open gesture rides. Fixed at `begin`: a mid-gesture change
    /// would strand the previous lane at a preview value.
    public private(set) var gestureController = defaultExpressionCC
    /// The last value handed to the engine on this gesture, for the change
    /// filter. nil before the first delivery.
    public private(set) var lastDeliveredValue: Int?

    private var lastPushAt: ContinuousClock.Instant?
    private var gestureStarted: ContinuousClock.Instant?
    private var ceilingTask: Task<Void, Never>?
    /// Injectable so the cap and ceiling gates never sleep in a test.
    var clock: () -> ContinuousClock.Instant = { ContinuousClock.now }

    public init() {}

    /// True while a gesture is open — the property that answers "is the pad
    /// streaming right now?" without asking the engine.
    public var isStreaming: Bool { gestureTrackID != nil }

    /// Maps effort 0…1 onto the expression lane's full range.
    ///
    /// ⚠️ **Deliberately NOT `BreathContour.scaled`'s law**, and this is a
    /// finding rather than a shortcut. That law is
    /// `peak × (1 − loudnessDepth × (1 − effort))`, and `EffortResponse`'s
    /// default is `.identity` (`loudnessDepth == 0`) — so a preview that
    /// "faithfully mirrored the commit" would emit **127 at every effort** and
    /// the pad would be a dead control at its own defaults. That is P1's
    /// finding 5 arriving a third time (a knob that is stored, displayed and
    /// inert). The preview is defined instead as what the dot IS — a direct,
    /// monotone, full-range read-out of effort — which §5.2 already licenses:
    /// "what you hear is an approximation of the gesture".
    public static func controllerValue(forEffort effort: Double) -> Int {
        let clamped = min(effortRange.upperBound, max(effortRange.lowerBound, effort))
        return Int((clamped * 127.0).rounded())
    }

    /// One pad-preview call. Throws `ProjectError.invalidPadPreview` BEFORE
    /// touching the engine for every refusal, so a refused call is guaranteed to
    /// have moved no controller.
    @discardableResult
    public func preview(trackID: UUID, effort: Double, phase: PadPreviewPhase,
                        expressionCC: Int = defaultExpressionCC,
                        engine: (any AudioEngineControlling)?) throws -> PadPreviewResult {
        guard Self.controllerRange.contains(expressionCC) else {
            throw ProjectError.invalidPadPreview(
                "expressionCC must be \(Self.controllerRange.lowerBound)…"
                + "\(Self.controllerRange.upperBound) — got \(expressionCC)")
        }
        guard phase == .end || Self.effortRange.contains(effort) else {
            throw ProjectError.invalidPadPreview(
                "value must be 0…1 (the pad's effort scale) — got \(effort)")
        }

        switch phase {
        case .begin:
            // A gesture on ANOTHER track (or another CC) is released to neutral
            // first: one pad gesture at a time, because a drag can only be in
            // one pad, and leaving the old lane parked is rule 3's whole point.
            if gestureTrackID != nil { releaseToNeutral(engine: engine) }
            gestureTrackID = trackID
            gestureController = expressionCC
            gestureStarted = clock()
            lastDeliveredValue = nil
            lastPushAt = nil
            startCeiling(engine: engine)

        case .move:
            guard let open = gestureTrackID else {
                throw ProjectError.invalidPadPreview(
                    "no pad gesture is open — send gesture 'begin' before 'move'. The pad "
                    + "streams ONLY while a gesture is in progress, so that playback, replay "
                    + "and a bounce always agree")
            }
            guard open == trackID else {
                throw ProjectError.invalidPadPreview(
                    "a pad gesture is open on track \(open.uuidString), not "
                    + "\(trackID.uuidString) — send 'end' on that track first, or 'begin' on "
                    + "this one")
            }
            // The total-duration ceiling, checked on the call path too so the
            // gate is deterministic in a test and does not depend on the task.
            if let started = gestureStarted,
               started.duration(to: clock()) > .seconds(Self.maxGestureSeconds) {
                releaseToNeutral(engine: engine)
                throw ProjectError.invalidPadPreview(
                    "the pad gesture exceeded its \(Int(Self.maxGestureSeconds)) s ceiling and "
                    + "was released — send 'begin' to start a new one")
            }

        case .end:
            guard let open = gestureTrackID else {
                throw ProjectError.invalidPadPreview(
                    "no pad gesture is open — 'end' has nothing to release")
            }
            // The SAME identity guard `.move` carries, and for a sharper reason:
            // without it an `end` naming track B releases the gesture open on
            // track A and returns a result naming B — the strip that actually
            // moved is not the one the answer describes. That is this tree's
            // characteristic failure (an answer that looks valid), so it is a
            // refusal, not a best-effort release.
            guard open == trackID else {
                throw ProjectError.invalidPadPreview(
                    "a pad gesture is open on track \(open.uuidString), not "
                    + "\(trackID.uuidString) — 'end' releases the track it names")
            }
        }

        if phase == .end {
            let neutral = MIDIControllerType.cc(controller: gestureController).neutralDefault
            let controller = gestureController
            let outcome = releaseToNeutral(engine: engine)
            // ⚠️ `delivered` is computed with `.move`'s predicate VERBATIM, not
            // hardcoded true. A release through a nil engine, or onto a track
            // whose renderer has gone, moves no strip — and reporting it as
            // delivered is precisely the "returns something that looks like a
            // valid answer" failure. `inaudibleMuted`/`NotReady`/`EngineStopped`
            // stay delivered on BOTH paths: the event really is in the ring.
            return PadPreviewResult(
                trackID: trackID, phase: .end, controller: controller,
                controllerValue: neutral, effort: nil, streaming: false,
                delivered: Self.didReachTheStrip(outcome), outcome: outcome)
        }

        let value = Self.controllerValue(forEffort: effort)
        // `begin` always delivers; `move` is capped and change-filtered. The
        // change filter reads `lastDeliveredValue` — what actually went out, not
        // what was asked for — so a value dropped by the cap is not later
        // mistaken for one the strip already holds.
        let now = clock()
        var deliver = phase == .begin
        if !deliver {
            let dueByRate = lastPushAt.map {
                $0.duration(to: now) >= Self.minimumPushInterval
            } ?? true
            deliver = dueByRate && value != lastDeliveredValue
        }

        var outcome = AuditionOutcome.sounded
        if deliver {
            outcome = engine?.previewController(trackID: trackID,
                                                controller: UInt8(gestureController),
                                                value: UInt8(value)) ?? .unsupported
            // Nothing reached the strip on these two, so remembering the value
            // would suppress the next attempt at it (the `AuditionController`
            // rule).
            if Self.didReachTheStrip(outcome) {
                lastDeliveredValue = value
                lastPushAt = now
            } else {
                deliver = false
            }
        }
        return PadPreviewResult(
            trackID: trackID, phase: phase, controller: gestureController,
            controllerValue: value, effort: min(1, max(0, effort)),
            streaming: true, delivered: deliver, outcome: outcome)
    }

    /// Ends whatever gesture is open, restoring the controller to neutral.
    /// Idempotent; safe with no engine. Called on the project boundary, on
    /// resign-active, and by the ceiling.
    @discardableResult
    public func stop(engine: (any AudioEngineControlling)?) -> Bool {
        guard gestureTrackID != nil else { return false }
        releaseToNeutral(engine: engine)
        return true
    }

    /// Did this outcome actually move the strip? `.noRenderer` and `.unsupported`
    /// mean the value went nowhere; the three `inaudible*` cases mean the event
    /// IS queued in the renderer's ring and the strip really holds it — the track
    /// is merely muted, not yet prepared, or the engine is not rendering. ONE
    /// predicate so `.move` and `.end` can never drift apart.
    static func didReachTheStrip(_ outcome: AuditionOutcome) -> Bool {
        outcome != .noRenderer && outcome != .unsupported
    }

    /// The one place a gesture closes. Pushes neutral (rule 3) without consulting
    /// the rate cap or the change filter, because the whole reason this exists is
    /// that no preview value may be left parked on the strip.
    ///
    /// ⚠️ **The one thing it will not do is push when nothing was ever parked.**
    /// `lastDeliveredValue == nil` means every push this gesture attempted was
    /// refused (no renderer, no engine), so the strip holds no preview value and
    /// there is nothing to restore. That guard is not tidiness: without it, a
    /// release on app-resign-active reaches `AudioEngine.previewController` with
    /// an empty ledger, which reads as a cold-app FIRST touch and starts the
    /// audio hardware — on the path where the app is going away.
    @discardableResult
    private func releaseToNeutral(engine: (any AudioEngineControlling)?) -> AuditionOutcome {
        ceilingTask?.cancel()
        ceilingTask = nil
        // The skipped-release outcome is chosen so the WIRE's reason string stays
        // true. `.unsupported` maps to "engineStopped", which is right for a
        // headless caller and WRONG here: a skip with a live engine means the
        // gesture's pushes never found a renderer (a mid-rebuild gap), which is
        // exactly `.noRenderer` → "engineRebuilding". Reporting a running engine
        // as stopped is the small end of this tree's characteristic failure.
        var outcome: AuditionOutcome = engine == nil ? .unsupported : .noRenderer
        if let trackID = gestureTrackID, lastDeliveredValue != nil {
            let neutral = MIDIControllerType.cc(controller: gestureController).neutralDefault
            outcome = engine?.previewController(trackID: trackID,
                                                controller: UInt8(gestureController),
                                                value: UInt8(neutral)) ?? .unsupported
        }
        gestureTrackID = nil
        gestureStarted = nil
        lastDeliveredValue = nil
        lastPushAt = nil
        return outcome
    }

    /// Arms the total-duration ceiling. Runs ONLY while a gesture is open, so an
    /// idle app schedules nothing (the `AuditionController.startHeartbeat`
    /// shape).
    private func startCeiling(engine: (any AudioEngineControlling)?) {
        ceilingTask?.cancel()
        ceilingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxGestureSeconds))
            guard !Task.isCancelled, let self, self.gestureTrackID != nil else { return }
            self.releaseToNeutral(engine: engine)
        }
    }

    /// Test seam: runs the ceiling check synchronously against the injected
    /// clock, so the gate never sleeps for 30 s. Returns true when it fired.
    @discardableResult
    func enforceCeilingForTesting(engine: (any AudioEngineControlling)?) -> Bool {
        guard gestureTrackID != nil, let started = gestureStarted,
              started.duration(to: clock()) > .seconds(Self.maxGestureSeconds) else { return false }
        releaseToNeutral(engine: engine)
        return true
    }
}
