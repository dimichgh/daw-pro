import Foundation

/// One live-play call's answer (m23-ct) — what the wire echoes back.
///
/// The three fields answer three different questions and are deliberately not
/// collapsed into one: *was it heard* (`audition`), *what went into the take
/// on THIS call* (`capturedEdges`), and *is a take receiving it at all*
/// (`recording`).
public struct LivePlayOutcome: Sendable, Equatable, Codable {
    /// Identical semantics to `setAuditionPitches`' answer: the audible half of
    /// live play IS an audition, on the same per-renderer ring, so the same
    /// reporting vocabulary applies unchanged.
    public var audition: AuditionOutcome

    /// Note edges (ons + offs) ingested into the rolling take by THIS call.
    ///
    /// ⚠️ **0 ON A HEARTBEAT, AND THAT IS THE POINT.** A held note re-asserts
    /// itself every 500 ms with an UNCHANGED set; an unchanged set has no
    /// edges, so it contributes nothing to the take. Anything else would write
    /// one note per heartbeat into the clip.
    public var capturedEdges: Int

    /// ⭐ **THE HONESTY LIGHT — playing vs recording.** True only when this
    /// call's edges actually reached a live `MIDICaptureSession`. False means
    /// the notes sounded and went into NO take: the transport is not recording,
    /// the track is not armed, it is not an instrument track, the take is not
    /// capturing MIDI, or CoreMIDI is unavailable. A UI (or an agent) that
    /// shows "recording" off this flag can never tell the user their
    /// performance is being kept when it is not.
    public var recording: Bool

    public init(audition: AuditionOutcome, capturedEdges: Int, recording: Bool) {
        self.audition = audition
        self.capturedEdges = capturedEdges
        self.recording = recording
    }

    /// The engine-less / unsupported answer: nothing sounded, nothing captured.
    public static let unsupported = LivePlayOutcome(
        audition: .unsupported, capturedEdges: 0, recording: false)

    public var isAudible: Bool { audition.isAudible }
}

/// One live-play request's answer as the wire sees it (the `AuditionResult`
/// shape, minus `durationMs` — live play is HELD, never a one-shot).
public struct LivePlayResult: Sendable, Equatable, Codable {
    public var trackID: UUID
    /// The pitches actually sounded, in the order the controller holds them
    /// (most-recent last) — post voice-cap, post de-dupe.
    public var pitches: [Int]
    public var velocity: Int
    public var outcome: LivePlayOutcome

    public var isAudible: Bool { outcome.isAudible }
    public var capturedEdges: Int { outcome.capturedEdges }
    public var isRecording: Bool { outcome.recording }

    public init(trackID: UUID, pitches: [Int], velocity: Int, outcome: LivePlayOutcome) {
        self.trackID = trackID
        self.pitches = pitches
        self.velocity = velocity
        self.outcome = outcome
    }
}

/// One sustain-pedal push's answer as the wire sees it (m34-l) — the
/// `LivePlayResult` shape with the pedal's one bit where the pitches were.
///
/// ⭐ **`down` IS READ BACK, NEVER ASSUMED.** It is the state the controller
/// actually holds after the call, so a surface that lights its pedal lamp from
/// this can never show a pedal the engine does not have. A setter's return is
/// not proof it took — unless the setter returns the state rather than an ack.
public struct LiveSustainResult: Sendable, Equatable, Codable {
    public var trackID: UUID
    /// The pedal state AFTER this call.
    public var down: Bool
    /// Did this call actually push a CC 64 to the engine? False when the state
    /// filter coalesced it away — a re-assert of an unchanged pedal on an
    /// unchanged track is honestly a no-op, not a failure.
    public var pushed: Bool
    public var outcome: LiveExpressionOutcome

    public var isAudible: Bool { outcome.isAudible }
    public var capturedPoints: Int { outcome.capturedPoints }
    public var isRecording: Bool { outcome.recording }

    public init(trackID: UUID, down: Bool, pushed: Bool, outcome: LiveExpressionOutcome) {
        self.trackID = trackID
        self.down = down
        self.pushed = pushed
        self.outcome = outcome
    }
}

/// THE policy home for LIVE PLAY (m23-ct): the same voice cap / diffing /
/// heartbeat / hold-ceiling machinery `AuditionController` runs, pointed at the
/// one engine entry that ALSO feeds the take. UI-free and engine-free (handed
/// an `AudioEngineControlling` per call), so it is headless-testable.
///
/// ⚠️ **A SIBLING OF `AuditionController`, NOT A `mode` FLAG ON IT — ON
/// PURPOSE.** The two carry genuinely different policy: audition REFUSES while
/// recording (it is heard-but-not-captured, so sounding it during a take would
/// be a lie), and live play MUST NOT refuse (it IS captured, so the assumption
/// audition's refusal protects is true here rather than false). Folding a
/// second cadence into a heavily-pinned controller is the m25-k shape — *a
/// correct policy at the wrong cadence looks exactly like a correct policy*.
/// The ~50 duplicated heartbeat lines are the cheaper error.
///
/// ⚠️ **ONE LIVE-NOTE OWNER AT A TIME.** Both controllers write the SAME
/// engine-side `auditionVoices` ledger, so a piano-roll drag and a held typed
/// note would ping-pong over it at 500 ms. `ProjectStore` arbitrates: starting
/// one stops the other (`playLiveNotes` / `auditionPitches` / `auditionNote`).
@MainActor
public final class LivePlayController {
    /// Simultaneous live-play pitches. Shares `AuditionController`'s number so
    /// the two surfaces cannot disagree about how many notes "at once" means,
    /// and so the wire/MCP bounds stay a single fact.
    public static let maxVoices = AuditionController.maxVoices
    /// How often a held note re-asserts itself. Comfortably under the render
    /// side's `watchdogSeconds` — 6 heartbeats per window.
    public static let heartbeatMilliseconds = 500
    /// DERIVATION COPY ONLY, never compared against anything: the authority for
    /// when a voice dies is the renderer's own `auditionWatchdogFrames`.
    public static let watchdogSeconds = 3.0
    /// Main-actor hard ceiling: a lost key-up with the key physically stuck
    /// still terminates.
    public static let maxHoldSeconds = 30.0
    public static let defaultVelocity = AuditionController.defaultVelocity
    public static let velocityRange = AuditionController.velocityRange
    public static let pitchRange = AuditionController.pitchRange

    /// What the controller believes is sounding right now, in press order
    /// (oldest first, most recent last).
    public private(set) var heldTrackID: UUID?
    public private(set) var heldPitches: [Int] = []
    public private(set) var heldVelocity = defaultVelocity
    /// The capture verdict `ProjectStore` computed for the LAST call.
    ///
    /// Re-used by the heartbeat, which cannot recompute it (this type is
    /// store-free by design). Staleness is harmless BY CONSTRUCTION: a
    /// heartbeat re-asserts an UNCHANGED set, an unchanged set has no edges,
    /// and a call with no edges ingests nothing whatever this flag says.
    public private(set) var heldCaptureIntoTake = false

    // MARK: - The sustain pedal (m34-l)

    /// **THE SUSTAIN PEDAL, CC 64.** True while the pedal is DOWN.
    ///
    /// ⭐⭐ **IT LIVES HERE RATHER THAN IN `PadPreviewController`, AND THAT WAS A
    /// MEASURED CHOICE, NOT A FILING PREFERENCE.** m34-f's expression seam
    /// bottoms out in `PadPreviewController`, which is a GESTURE machine: it
    /// permits exactly one open gesture (`preview`'s `.begin` calls
    /// `releaseToNeutral` on any other) and auto-releases it at
    /// `maxGestureSeconds` (30 s). Both are right for a drag and wrong for a
    /// LATCH — a pedal held past 30 s would silently lift mid-performance, and a
    /// breath-pad drag would lift a pedal whose lamp stayed lit, which is this
    /// tree's characteristic failure twice over. The pedal reuses everything
    /// BELOW that layer: `AudioEngine.setLiveExpression` is the same funnel, so
    /// the value sounds and reaches the take by exactly the m34-f path.
    ///
    /// ⭐ **AND IT LIVES BESIDE THE NOTES BECAUSE STAND-DOWN COMPLETENESS IS THE
    /// WHOLE RISK.** A stuck pedal is an infinite drone with no visible cause.
    /// Every site that stands live play down — `record()`, `recordLayer()`,
    /// `stopAllAudition()`, `panic()`, `newProject()`, `applyOpenedState()` —
    /// already calls `stopAll`, so the pedal lifts at all six *structurally*,
    /// with no per-site pairing for a future site to forget.
    public private(set) var sustainDown = false
    /// The track the pedal is down on. One pedal, like one pair of hands.
    public private(set) var sustainTrackID: UUID?
    /// The capture verdict in force when the pedal went DOWN, re-used by the
    /// lift for `stopReleasing`'s reason verbatim: a disarm mid-hold must still
    /// land the closing CC 64 = 0, or the take's lane ends at 127 and every
    /// clip after it inherits a pedal nobody pressed (CC 64 is one of the
    /// controllers `MIDIControllerType.resetsAtClipOnset` deliberately does NOT
    /// clear at a clip boundary).
    public private(set) var sustainCaptureIntoTake = false

    /// Presses or lifts the sustain pedal on `trackID`.
    ///
    /// ⛔⛔ **GATE THE ONS, NEVER GATE THE OFFS — and the sustain shape of that
    /// law is specific.** Pressing is a performance act and may be refused
    /// upstream (`ProjectStore.playLiveSustain` validates the track the way a
    /// note-on is validated); lifting is never refused by anything, and the lift
    /// rides the capture verdict from the PRESS rather than a fresh one.
    ///
    /// ⚠️ **STATE-FILTERED, unlike the pad's `.move`.** `PadPreviewController`
    /// deliberately does NOT gate its ingest on its strip filter, because a
    /// value the strip already holds is still a value the user is *performing at
    /// that instant*. A latch has no such continuum: re-asserting "down" while
    /// down is not a second press, it is the same press, and pushing it would
    /// stack duplicate points into a take and a duplicate CC into the ring on
    /// every stand-down. `pushed` in the result says honestly when the filter
    /// coalesced a call away.
    ///
    /// A pedal down on ANOTHER track lifts there first: one pedal.
    @discardableResult
    public func setSustain(trackID: UUID, down: Bool, captureIntoTake: Bool,
                           engine: (any AudioEngineControlling)?) -> LiveSustainResult {
        if sustainDown, let held = sustainTrackID, held != trackID {
            // Lift the old strip THROUGH the capture path, for `set`'s reason:
            // a pedal left down on a track the user has walked away from is a
            // drone, and a take on that track would keep a 127 it never closed.
            pushSustain(trackID: held, down: false,
                        captureIntoTake: sustainCaptureIntoTake, engine: engine)
            sustainDown = false
            sustainTrackID = nil
        }
        guard down != sustainDown || (down && sustainTrackID != trackID) else {
            return LiveSustainResult(
                trackID: trackID, down: sustainDown, pushed: false,
                outcome: LiveExpressionOutcome(audition: .sounded, capturedPoints: 0,
                                               recording: false))
        }
        // The LIFT rides the verdict from the PRESS; the PRESS takes the fresh
        // one. Same asymmetry `stopReleasing` documents for note-offs.
        let verdict = down ? captureIntoTake : sustainCaptureIntoTake
        let outcome = pushSustain(trackID: trackID, down: down,
                                  captureIntoTake: verdict, engine: engine)
        // ⚠️ A push that reached NO renderer does not become held state — the
        // `set` rule: do not remember a pedal on an instrument that does not
        // exist, or the lift would be filtered away as "already up" later.
        if down, outcome.audition == .noRenderer || outcome.audition == .unsupported {
            sustainDown = false
            sustainTrackID = nil
            sustainCaptureIntoTake = false
            return LiveSustainResult(trackID: trackID, down: false, pushed: true,
                                     outcome: outcome)
        }
        sustainDown = down
        sustainTrackID = down ? trackID : nil
        sustainCaptureIntoTake = down ? captureIntoTake : false
        return LiveSustainResult(trackID: trackID, down: down, pushed: true, outcome: outcome)
    }

    /// Lifts the pedal wherever it is down. Idempotent, never refused, safe with
    /// no engine — the one call every stand-down site needs.
    @discardableResult
    public func liftSustain(engine: (any AudioEngineControlling)?) -> Bool {
        guard sustainDown, let trackID = sustainTrackID else {
            sustainDown = false
            sustainTrackID = nil
            sustainCaptureIntoTake = false
            return false
        }
        pushSustain(trackID: trackID, down: false,
                    captureIntoTake: sustainCaptureIntoTake, engine: engine)
        sustainDown = false
        sustainTrackID = nil
        sustainCaptureIntoTake = false
        return true
    }

    /// The ONE place a CC 64 leaves this type. `value` is the MIDI standard's,
    /// not a choice: ≥ 64 is DOWN, < 64 is UP, so 127/0 are the two ends.
    @discardableResult
    private func pushSustain(trackID: UUID, down: Bool, captureIntoTake: Bool,
                             engine: (any AudioEngineControlling)?) -> LiveExpressionOutcome {
        engine?.setLiveExpression(trackID: trackID, controller: Self.sustainCC,
                                  value: down ? 127 : 0,
                                  captureIntoTake: captureIntoTake) ?? .unsupported
    }

    /// CC 64 — the damper pedal. MIDI 1.0's assignment, mirrored from
    /// `MIDIControllerRouting.samplerRoutedCCs` / `polySynthRoutedCCs`, which
    /// are the tables that say both built-ins consume it.
    public static let sustainCC: UInt8 = 64

    private var heartbeatTask: Task<Void, Never>?
    private var holdStarted: ContinuousClock.Instant?
    /// Injectable so the hold-ceiling gate does not sleep for 30 s.
    var clock: () -> ContinuousClock.Instant = { ContinuousClock.now }

    public init() {}

    /// True while the controller believes voices are open.
    public var isHolding: Bool { heldTrackID != nil && !heldPitches.isEmpty }

    /// SET semantics: "exactly these pitches should be sounding on `trackID`
    /// now, and they should be going into the take if `captureIntoTake`". `[]`
    /// stops. Idempotent — re-calling with the same set pushes no note edges
    /// but still heartbeats, which is precisely what a held key needs.
    /// A DIFFERENT track silences the previous one first: one performance at a
    /// time, because a person has one pair of hands.
    @discardableResult
    public func set(trackID: UUID, pitches: [Int], velocity: Int,
                    captureIntoTake: Bool,
                    engine: (any AudioEngineControlling)?) -> LivePlayOutcome {
        let clamped = Self.clampPitches(pitches)
        let vel = min(Self.velocityRange.upperBound,
                      max(Self.velocityRange.lowerBound, velocity))

        if let heldTrackID, heldTrackID != trackID {
            // Release the old track THROUGH the capture path, so its notes are
            // closed in the take rather than left open to clamp at take end.
            engine?.setLivePlayPitches(trackID: heldTrackID, pitches: [], velocity: 0,
                                       captureIntoTake: heldCaptureIntoTake)
            self.heldTrackID = nil
            heldPitches = []
        }

        // `captureIntoTake` is deliberately IGNORED on this path: a release
        // closes something opened under the verdict in force when it was
        // PRESSED, and the fresh verdict describes a press that is not
        // happening. See `stop(engine:)`.
        guard !clamped.isEmpty else { return stopReleasing(engine: engine) }

        guard let engine else {
            heldTrackID = trackID
            heldPitches = clamped
            heldVelocity = vel
            heldCaptureIntoTake = captureIntoTake
            return .unsupported
        }

        let outcome = engine.setLivePlayPitches(
            trackID: trackID, pitches: clamped.map { UInt8($0) }, velocity: UInt8(vel),
            captureIntoTake: captureIntoTake)
        // `noRenderer`/`unsupported` delivered nothing — do not start holding
        // state (and a heartbeat) for voices that do not exist.
        guard outcome.audition != .noRenderer, outcome.audition != .unsupported else {
            heldTrackID = nil
            heldPitches = []
            heldCaptureIntoTake = false
            stopHeartbeat()
            return outcome
        }
        heldTrackID = trackID
        heldPitches = clamped
        heldVelocity = vel
        heldCaptureIntoTake = captureIntoTake
        if holdStarted == nil { holdStarted = clock() }
        startHeartbeat(engine: engine)
        return outcome
    }

    /// Releases whatever is held on the CURRENT track. Idempotent.
    ///
    /// Uses the LAST KNOWN capture verdict, because a release must reach the
    /// take even when the answer has since become "no" — the engine ingests
    /// note-OFFs whenever a take is capturing, precisely so a disarm mid-hold
    /// cannot strand an open note that then clamps to the end of the take.
    public func stop(engine: (any AudioEngineControlling)?) {
        _ = stopReleasing(engine: engine)
    }

    /// Releases live play EVERYWHERE — engine shutdown, project boundary,
    /// record start, panic. Idempotent; safe to call with no engine.
    ///
    /// ⚠️ **DELIBERATELY DOES NOT CALL `engine.stopAllAudition()`, unlike
    /// `AuditionController.stopAll`.** Two reasons, both measured elsewhere in
    /// this tree: (1) the engine-wide sweep has ONE home — `AuditionController`
    /// owns it and runs at every site this one does, so a second call would be
    /// a second record of "what is sounding"; (2) `AudioEngine.stopAllAudition()`
    /// also clears the controller-preview ledger, which is exactly the thing
    /// `ProjectStore.stopAllAudition()`'s load-bearing ordering exists to
    /// protect (a cleared ledger makes the pad's neutral release look like a
    /// cold-app first touch, which STARTS THE AUDIO HARDWARE).
    ///
    /// ⚠️ **AND IT MUST RUN BEFORE `audition.stopAll` AT EVERY SITE.** That one
    /// wipes `auditionVoices` wholesale; run it first and the release below
    /// diffs against an empty ledger, ingests zero note-offs, and every open
    /// note clamps to the end of the take. Bites hardest at `panic()`, which is
    /// used mid-take by definition.
    public func stopAll(engine: (any AudioEngineControlling)?) {
        stop(engine: engine)
        // ⛔⛔ **THE PEDAL LIFTS HERE AND *ONLY* HERE — NEVER IN `stopReleasing`
        // (m34-l).** That path runs on every all-keys-up (`set(pitches: [])`),
        // and all keys up WITH THE PEDAL DOWN is the feature working, not a
        // stand-down: it is precisely the moment the pedal is holding the sound
        // the fingers let go of. Lifting there would make the pedal a no-op that
        // *looked* implemented — this tree's characteristic failure, and the one
        // failure mode a pedal has that nothing else would catch.
        //
        // ⚠️ ORDER: after the note release, so the take's note-offs are ingested
        // before the closing CC 64 — the lane then reads "notes ended, then the
        // pedal came up", which is what happened.
        liftSustain(engine: engine)
        stopHeartbeat()
        heldTrackID = nil
        heldPitches = []
        heldCaptureIntoTake = false
        holdStarted = nil
    }

    /// The one release path: pushes the empty set (which is what closes both
    /// the voices and the take's open notes) and clears local state.
    ///
    /// Pushes NOTHING when the controller holds nothing — a repeated release is
    /// idempotent and silent, the `AuditionController.stop` precedent. It also
    /// releases whatever track is HELD, not a track named by the caller: there
    /// is only ever one, and `set` has already handed a track switch over.
    @discardableResult
    private func stopReleasing(engine: (any AudioEngineControlling)?) -> LivePlayOutcome {
        stopHeartbeat()
        guard let trackID = heldTrackID else {
            heldPitches = []
            heldCaptureIntoTake = false
            holdStarted = nil
            return LivePlayOutcome(audition: .sounded, capturedEdges: 0, recording: false)
        }
        // The LAST KNOWN capture verdict, never a fresh one: a release must
        // reach the take even when the answer has since become "no" (a disarm
        // mid-hold), or the open note clamps to the end of the recording.
        let outcome = engine?.setLivePlayPitches(trackID: trackID, pitches: [], velocity: 0,
                                                 captureIntoTake: heldCaptureIntoTake)
            ?? .unsupported
        heldTrackID = nil
        heldPitches = []
        heldCaptureIntoTake = false
        holdStarted = nil
        return outcome
    }

    /// De-dupes, clamps to the MIDI range, and applies the voice cap by keeping
    /// the MOST RECENTLY PRESSED pitches — press order is PRESERVED, not sorted.
    ///
    /// ⚠️ **DELIBERATELY THE OPPOSITE OF `AuditionController.clampPitches`, AND
    /// THE DIVERGENCE IS THE WHOLE REASON THIS FUNCTION EXISTS.** Audition caps
    /// at 8 keeping the LOWEST pitches, because a drag over a chord is a musical
    /// selection and a musician anchors on the bass. Live play caps at 8 keeping
    /// the LAST 8 pressed, because a typist pressing a 9th key means the 9th
    /// key — dropping it in favour of a note they pressed five seconds ago would
    /// make the instrument feel broken. Do not "unify" these.
    ///
    /// De-dupe keeps the LAST occurrence for the same reason: a repeated pitch
    /// in the incoming set is the newest statement of it.
    public static func clampPitches(_ pitches: [Int]) -> [Int] {
        var seen = Set<Int>()
        var reversed: [Int] = []
        for pitch in pitches.reversed() where pitchRange.contains(pitch) {
            if seen.insert(pitch).inserted { reversed.append(pitch) }
            if reversed.count == maxVoices { break }
        }
        return reversed.reversed()
    }

    // MARK: - Heartbeat

    /// The 500 ms re-assert that keeps a legitimately held key alive past the
    /// render side's 3 s watchdog. Runs ONLY while something is held, so an idle
    /// app schedules nothing. It also enforces the 30 s hard ceiling — the
    /// render watchdog covers a wedged main actor, this covers a live main actor
    /// that never got its key-up.
    ///
    /// ⭐ Every heartbeat pushes an UNCHANGED set, so it contributes ZERO edges
    /// to the take by construction. That is what keeps a 4-second held note one
    /// note in the clip rather than eight.
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
                engine.setLivePlayPitches(trackID: trackID,
                                          pitches: self.heldPitches.map { UInt8($0) },
                                          velocity: UInt8(self.heldVelocity),
                                          captureIntoTake: self.heldCaptureIntoTake)
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
        engine?.setLivePlayPitches(trackID: trackID, pitches: heldPitches.map { UInt8($0) },
                                   velocity: UInt8(heldVelocity),
                                   captureIntoTake: heldCaptureIntoTake)
        return true
    }
}
