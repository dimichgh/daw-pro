import Foundation
import Testing
@testable import DAWCore

/// End-of-content transport stop (m25-d): "when music playing reaches the edge
/// where there are no more clips past that point, it should stop the play".
///
/// Three layers, deliberately separated:
///  * the PURE policy (`TransportEndStop`) — extent math and the five nil
///    reasons, tested without a store;
///  * the STORE's arming — what `Double?` reaches the engine on each transport
///    transition, spied through `FakeEngine`;
///  * the HEADLESS TICKER — the engine-less transport, which is the only layer
///    here that actually stops itself in real time.
///
/// ⚠️ **What these do NOT prove.** With an engine attached the store's ticker
/// never runs, so the load-bearing check is the one inside
/// `AudioEngine.startPlayheadTask`. That tick body needs a live CoreAudio graph
/// and is not reachable from a unit test; these tests pin the CONTRACT around
/// it (the store hands over the right bound, and firing the sink stops the
/// transport on the ordinary path) rather than the line itself.
@MainActor
@Suite("Transport end-of-content stop (m25-d)")
struct TransportEndStopTests {

    // MARK: - Helpers

    private func audioClip(start: Double, length: Double) -> Clip {
        Clip(name: "c", startBeat: start, lengthBeats: length,
             audioFileURL: URL(fileURLWithPath: "/tmp/m25d.wav"))
    }

    /// A store with one INSTRUMENT track whose clip ends at `contentEnd`
    /// beats, plus a spying engine already attached. Instrument/MIDI clips are
    /// used because they need no file on disk — the content extent is
    /// clip-kind-blind (`startBeat + lengthBeats`), and an instrument track
    /// also lets `record()` roll a MIDI-only take with no microphone prompt.
    private func makeStore(contentEnd: Double) -> (ProjectStore, FakeEngine) {
        let store = ProjectStore()
        let engine = FakeEngine()
        store.engine = engine
        let track = store.addTrack(name: "T", kind: .instrument)
        if contentEnd > 0 {
            _ = try! store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: contentEnd)
        }
        engine.clearCalls()
        return (store, engine)
    }

    // MARK: - Content extent (the pure max)

    @Test("content end is the largest clip end across ALL tracks, not the last track's")
    func contentEndSpansTracks() {
        let a = Track(name: "A", kind: .audio, clips: [audioClip(start: 0, length: 40)])
        let b = Track(name: "B", kind: .audio, clips: [audioClip(start: 4, length: 4)])
        // B is last in order but ends at 8; A ends at 40. A naive "last track"
        // or "last clip in the flattened list" reading would answer 8.
        #expect(TransportEndStop.contentEndBeat(tracks: [a, b]) == 40)
        #expect(TransportEndStop.contentEndBeat(tracks: [b, a]) == 40)
    }

    @Test("content end accounts for clip START, not just length")
    func contentEndUsesStart() {
        let t = Track(name: "T", kind: .audio, clips: [audioClip(start: 100, length: 4)])
        #expect(TransportEndStop.contentEndBeat(tracks: [t]) == 104)
    }

    @Test("a project with no clips has content end 0")
    func contentEndEmpty() {
        #expect(TransportEndStop.contentEndBeat(tracks: []) == 0)
        #expect(TransportEndStop.contentEndBeat(
            tracks: [Track(name: "T", kind: .audio, clips: [])]) == 0)
    }

    @Test("clips on a MUTED track still count — a mute must not move the stop point")
    func mutedTracksCount() {
        var muted = Track(name: "M", kind: .audio, clips: [audioClip(start: 0, length: 32)])
        muted.isMuted = true
        #expect(TransportEndStop.contentEndBeat(tracks: [muted]) == 32)
    }

    @Test("stretch and source-offset do NOT change the extent — lengthBeats is the timeline authority")
    func stretchDoesNotChangeExtent() {
        // The brief asked for "audio clips' trims/stretch where applicable".
        // `Clip.lengthBeats` IS the beat span occupied on the timeline;
        // stretchRatio sizes the SOURCE window consumed and startOffsetSeconds
        // offsets INTO the source. A clip stretched 2x still occupies exactly
        // `lengthBeats`. Applying a factor here would double-count.
        var clip = audioClip(start: 8, length: 16)
        clip.stretchRatio = 2
        clip.startOffsetSeconds = 3.5
        let t = Track(name: "T", kind: .audio, clips: [clip])
        #expect(TransportEndStop.contentEndBeat(tracks: [t]) == 24)
    }

    @Test("MIDI notes past the clip end do not extend the content end (latent space is silent)")
    func latentNotesDoNotExtend() {
        // m18-f/m19-g: notes past the clip end are legal-but-latent and are
        // engine-windowed by strict `<` — they never sound, so they are not
        // content.
        let clip = Clip(name: "m", startBeat: 0, lengthBeats: 4,
                        notes: [MIDINote(pitch: 60, velocity: 100, startBeat: 40, lengthBeats: 4)])
        let t = Track(name: "T", kind: .instrument, clips: [clip])
        #expect(TransportEndStop.contentEndBeat(tracks: [t]) == 4)
    }

    @Test("a NaN clip end is skipped rather than poisoning the max")
    func nanIsSkipped() {
        // A NaN max would compare false against every position and silently
        // disable the feature for the whole session.
        let t = Track(name: "T", kind: .audio, clips: [
            audioClip(start: .nan, length: 4),
            audioClip(start: 0, length: 12),
        ])
        let end = TransportEndStop.contentEndBeat(tracks: [t])
        #expect(!end.isNaN)
        #expect(end == 12)
    }

    // MARK: - The policy: when a bound exists

    private func bound(contentEnd: Double = 32, position: Double = 0,
                       enabled: Bool = true, recording: Bool = false,
                       looping: Bool = false) -> Double? {
        TransportEndStop.bound(contentEndBeat: contentEnd, positionBeats: position,
                               isEnabled: enabled, isRecording: recording,
                               isLoopActive: looping)
    }

    @Test("armed in the ordinary case: playing from before the end")
    func armedOrdinary() {
        #expect(bound() == 32)
        #expect(bound(position: 31.9) == 32)
    }

    @Test("preference OFF disarms")
    func disarmedWhenPreferenceOff() {
        #expect(bound(enabled: false) == nil)
    }

    @Test("⚠️ RECORDING disarms — a take must never stop at content end")
    func disarmedWhileRecording() {
        #expect(bound(recording: true) == nil)
        // …and it stays disarmed no matter how favourable everything else is.
        #expect(bound(contentEnd: 8, position: 0, enabled: true, recording: true) == nil)
    }

    @Test("an ACTIVE LOOP disarms — looping takes precedence")
    func disarmedWhileLooping() {
        #expect(bound(looping: true) == nil)
    }

    @Test("an empty project never arms — no pathological instant stop at beat 0")
    func emptyProjectNeverArms() {
        #expect(bound(contentEnd: 0, position: 0) == nil)
        #expect(bound(contentEnd: -1, position: 0) == nil)
        #expect(bound(contentEnd: .nan) == nil)
        #expect(bound(contentEnd: .infinity) == nil)
    }

    @Test("starting AT or PAST the end does not arm — the play button must not look dead")
    func startingPastEndDoesNotArm() {
        #expect(bound(contentEnd: 32, position: 32) == nil)
        #expect(bound(contentEnd: 32, position: 99) == nil)
    }

    @Test("isLoopActive matches the engine's own wrap condition, degenerate window included")
    func loopActivePredicate() {
        var t = TransportState()
        t.isLoopEnabled = true
        t.loopStartBeat = 4
        t.loopEndBeat = 8
        #expect(TransportEndStop.isLoopActive(t))
        // Enabled but EMPTY/inverted: the engine wraps nothing, so the end stop
        // should still apply.
        t.loopEndBeat = 4
        #expect(!TransportEndStop.isLoopActive(t))
        t.loopEndBeat = 2
        #expect(!TransportEndStop.isLoopActive(t))
        t.isLoopEnabled = false
        t.loopEndBeat = 8
        #expect(!TransportEndStop.isLoopActive(t))
    }

    // MARK: - Store arming (what actually reaches the engine)

    @Test("the preference defaults to ON")
    func preferenceDefaultsOn() {
        #expect(ProjectStore().stopAtContentEnd)
    }

    @Test("play() hands the engine the content end as a pre-computed scalar")
    func playArmsEngine() {
        let (store, engine) = makeStore(contentEnd: 32)
        #expect(store.contentEndBeat == 32)
        store.play()
        #expect(engine.currentEndStop == 32)
    }

    @Test("play() on an EMPTY project pushes nil, and the transport keeps running")
    func playEmptyProjectPushesNil() {
        let (store, engine) = makeStore(contentEnd: 0)
        store.play()
        #expect(engine.currentEndStop == nil)
        #expect(store.transport.isPlaying)
    }

    @Test("preference OFF: play() pushes nil")
    func preferenceOffPushesNil() {
        let (store, engine) = makeStore(contentEnd: 32)
        store.setStopAtContentEnd(false)
        store.play()
        #expect(engine.currentEndStop == nil)
    }

    @Test("toggling the preference mid-play re-arms/disarms on THIS run")
    func togglingMidPlayTakesEffectNow() {
        let (store, engine) = makeStore(contentEnd: 32)
        store.play()
        #expect(engine.currentEndStop == 32)
        store.setStopAtContentEnd(false)
        #expect(engine.currentEndStop == nil)
        store.setStopAtContentEnd(true)
        #expect(engine.currentEndStop == 32)
    }

    @Test("enabling a loop mid-play disarms; disabling it re-arms (looping takes precedence)")
    func loopTogglesArming() throws {
        let (store, engine) = makeStore(contentEnd: 32)
        store.play()
        #expect(engine.currentEndStop == 32)
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 8)
        #expect(engine.currentEndStop == nil)
        try store.setLoop(enabled: false)
        #expect(engine.currentEndStop == 32)
    }

    @Test("seeking back from past the end re-arms; seeking past it disarms")
    func seekReArms() throws {
        let (store, engine) = makeStore(contentEnd: 32)
        try store.seek(toBeats: 40)
        store.play()
        #expect(engine.currentEndStop == nil, "started past the end — free-run")
        try store.seek(toBeats: 4)
        #expect(engine.currentEndStop == 32)
    }

    @Test("stop() disarms, so a bound cannot outlive the run that armed it")
    func stopDisarms() {
        let (store, engine) = makeStore(contentEnd: 32)
        store.play()
        #expect(engine.currentEndStop == 32)
        store.stop()
        #expect(engine.currentEndStop == nil)
        #expect(engine.endStopPushes.last == .some(nil), "an explicit nil was pushed")
    }

    @Test("⚠️⚠️ record() pushes an EXPLICIT nil — recording never stops at content end")
    func recordExplicitlyDisarms() throws {
        let (store, engine) = makeStore(contentEnd: 32)
        // An AUDIO track for the take: `FakeEngine` implements the audio
        // `startRecording` path (the protocol default refuses MIDI capture).
        let track = store.addTrack(name: "Rec", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        engine.clearEndStopPushes()
        try store.record()
        #expect(store.transport.isRecording)
        // The push happened, and it was nil — not merely "no push".
        #expect(!engine.endStopPushes.isEmpty,
                "record() must DISARM explicitly, not rely on never having armed")
        #expect(engine.currentEndStop == nil)
    }

    @Test("⚠️⚠️ the arming predicate refuses while recording even if asked directly")
    func armingRefusedWhileRecording() throws {
        let (store, engine) = makeStore(contentEnd: 32)
        // An AUDIO track for the take: `FakeEngine` implements the audio
        // `startRecording` path (the protocol default refuses MIDI capture).
        let track = store.addTrack(name: "Rec", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        engine.clearEndStopPushes()
        // Second, independent guard: a preference toggle mid-take runs the
        // predicate again and must still produce nil.
        store.setStopAtContentEnd(true)
        #expect(engine.currentEndStop == nil)
    }

    // MARK: - The armed bound must not go STALE mid-playback
    //
    // These four were MEASURED failing before the `performEdit` /
    // `restoreEditState` hooks existed: the bound was pinned at play() and a
    // mid-run edit could not reach it. Both directions are user-visible bugs of
    // exactly the kind this feature exists to remove — one stops the song
    // early, the other defeats the stop entirely.

    @Test("extending the song mid-playback re-arms to the NEW end (was: stopped early)")
    func editExtendingContentReArms() throws {
        let (store, engine) = makeStore(contentEnd: 8)
        store.play()
        #expect(engine.currentEndStop == 8)
        let track = store.tracks[0]
        _ = try store.addMIDIClip(toTrack: track.id, atBeat: 16, lengthBeats: 8)
        #expect(store.contentEndBeat == 24)
        #expect(engine.currentEndStop == 24,
                "a clip added mid-run must move the stop, not be cut off by it")
    }

    @Test("undoing the last clip mid-playback re-arms DOWN (was: overran past the end)")
    func undoShrinkingContentReArms() throws {
        let (store, engine) = makeStore(contentEnd: 8)
        let track = store.tracks[0]
        _ = try store.addMIDIClip(toTrack: track.id, atBeat: 16, lengthBeats: 8)
        store.play()
        #expect(engine.currentEndStop == 24)
        try store.undo()
        #expect(store.contentEndBeat == 8)
        #expect(engine.currentEndStop == 8, "undo must not leave a bound behind its content")
        try store.redo()
        #expect(engine.currentEndStop == 24, "and redo must put it back")
    }

    @Test("deleting ALL content mid-playback disarms rather than stopping at a phantom end")
    func deletingAllContentDisarms() throws {
        let (store, engine) = makeStore(contentEnd: 8)
        store.play()
        #expect(engine.currentEndStop == 8)
        _ = try store.removeTrack(id: store.tracks[0].id)
        #expect(store.contentEndBeat == 0)
        #expect(engine.currentEndStop == nil, "no content means no bound, not a bound of 0")
        #expect(store.transport.isPlaying, "and the transport keeps running")
    }

    /// ⚠️⚠️ THE DESTRUCTIVE-MODE ORDERING, MEASURED ON THE REAL PATH.
    ///
    /// `refreshEndStop()` now fires inside `performEdit`, and `finishTake`
    /// lands a recorded take inside `performEdit("Record Take N")` — so the new
    /// hook runs during take finalization, the one path where an armed bound
    /// could truncate a user's work. This drives the ACTUAL `finishTake`
    /// (via `FakeTakeEngine`'s captured completion), not a simulation of its
    /// shape, and asserts the invariant directly: **no push made while
    /// `isRecording` was true was ever non-nil.**
    ///
    /// It also records the answer to "what is `isRecording` at finalization":
    /// `stop()` clears it BEFORE `engine.stopRecording()` fires the completion,
    /// so the landing edit sees `isRecording == false` and computes a real
    /// bound from the just-landed clips — correct, and armed for the next play
    /// rather than the finished take.
    @Test("⚠️⚠️ take finalization never arms a bound while a take is rolling (real finishTake)")
    func takeFinalizationNeverArmsMidTake() throws {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        engine.observedStore = store
        store.engine = engine
        let inst = store.addTrack(name: "Keys", kind: .instrument)
        _ = try store.addMIDIClip(toTrack: inst.id, atBeat: 0, lengthBeats: 8)
        try store.setTrackArm(id: inst.id, armed: true)
        #expect(store.contentEndBeat == 8)

        engine.clearEndStopPushes()
        try store.record()
        #expect(store.transport.isRecording)
        #expect(engine.currentEndStop == nil, "the take itself is never bounded")

        store.stop()
        // The take finalizes here, landing a clip that runs to beat 40 — well
        // past the old content end of 8. This is the real store code path.
        engine.finishTake(.success(TakeResult(
            audio: nil,
            midi: MIDIRecordingResult(
                notes: [MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)],
                lengthBeats: 40, droppedEvents: false))))
        #expect(store.contentEndBeat == 40, "the recorded tail landed")

        // NON-VACUITY FIRST. An "everything armed mid-take was nil" assertion
        // over an EMPTY set passes without proving anything, and would keep
        // passing if the mid-take push were deleted entirely. MEASURED push
        // sequence for this lifecycle: [0] nil while recording (record()'s
        // explicit disarm), [1] nil not-recording (stop()), [2] 40.0
        // not-recording (finishTake's landing edit). So exactly one push is
        // in scope and the filter below is a real test.
        #expect(engine.endStopPushRecordingFlags.contains(true),
                "no push happened mid-take at all — the invariant below is vacuous")

        // THE INVARIANT: across every push in the whole take lifecycle, not one
        // made while recording was live carried a bound.
        let armedWhileRecording = zip(engine.endStopPushes, engine.endStopPushRecordingFlags)
            .filter { $0.1 && $0.0 != nil }
        #expect(armedWhileRecording.isEmpty,
                "a bound was armed mid-take: \(armedWhileRecording)")
        // And the measured answer to the ordering question.
        #expect(!store.transport.isRecording,
                "stop() clears isRecording before the completion fires")

        store.play()
        #expect(engine.currentEndStop == 40,
                "the newly recorded tail must be reachable on playback")
    }

    /// A take that records PAST the old content end must leave the next run
    /// armed at the new, longer end — never at the old one (which would make
    /// the newly recorded tail unplayable).
    @Test("⚠️ a take that extends content leaves the NEXT play armed at the new end")
    func takeExtendingContentArmsNextPlay() throws {
        let (store, engine) = makeStore(contentEnd: 8)
        let track = store.addTrack(name: "Rec", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        #expect(engine.currentEndStop == nil, "the take itself is never bounded")

        // Land a clip past the old end the way finishTake does — one edit.
        store.stop()
        let inst = store.tracks[0]
        _ = try store.addMIDIClip(toTrack: inst.id, atBeat: 8, lengthBeats: 24)
        #expect(store.contentEndBeat == 32)

        store.play()
        #expect(engine.currentEndStop == 32,
                "the recorded tail must be reachable on playback")
    }

    // MARK: - The engine's callback lands on the ordinary stop path

    @Test("firing the engine end-stop sink stops the transport, playhead parked on the end")
    func endStopSinkStopsTransport() {
        let (store, engine) = makeStore(contentEnd: 32)
        store.play()
        #expect(store.transport.isPlaying)
        engine.fireEndStop()
        #expect(!store.transport.isPlaying)
        #expect(store.transport.positionBeats == 32, "parked exactly on the content end")
    }

    @Test("the end stop is not an edit — nothing to undo, session not dirtied by it")
    func endStopIsNotAnEdit() {
        let (store, engine) = makeStore(contentEnd: 32)
        store.play()
        let undoBefore = store.snapshot().undoLabel
        engine.fireEndStop()
        #expect(store.snapshot().undoLabel == undoBefore,
                "stopping at content end must not journal an undo step")
    }

    @Test("a late sink firing after the transport already stopped is inert")
    func lateSinkIsInert() {
        let (store, engine) = makeStore(contentEnd: 32)
        store.play()
        store.stop()
        #expect(!store.transport.isPlaying)
        engine.fireEndStop()   // must not throw, must not resurrect anything
        #expect(!store.transport.isPlaying)
    }

    @Test("⚠️⚠️ a sink firing DURING a take does not stop the take")
    func sinkDuringTakeIsInert() throws {
        let (store, engine) = makeStore(contentEnd: 32)
        // An AUDIO track for the take: `FakeEngine` implements the audio
        // `startRecording` path (the protocol default refuses MIDI capture).
        let track = store.addTrack(name: "Rec", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        #expect(store.transport.isRecording)
        // Third guard: even a stale sink call mid-take is refused by the store.
        engine.fireEndStop()
        #expect(store.transport.isRecording, "the take must still be rolling")
        #expect(store.transport.isPlaying)
    }

    // MARK: - Headless ticker (no engine — the only layer that self-stops here)

    /// A store with no engine, a fast tempo, and content ending at
    /// `contentEnd` beats. At 240 BPM one beat is 0.25 s, so the 33 ms ticker
    /// crosses 1 beat in ~8 ticks.
    private func makeHeadless(contentEnd: Double) -> ProjectStore {
        let store = ProjectStore()
        try! store.setTempo(240)
        let track = store.addTrack(name: "T", kind: .instrument)
        if contentEnd > 0 {
            _ = try! store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: contentEnd)
        }
        return store
    }

    /// `Duration` → `Double` seconds. Local to this suite on purpose: it is
    /// test-timing scaffolding, so it must not migrate into `DAWCore` (which
    /// stays headless and ships the product domain model).
    private static func secondsOf(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
    }

    /// What a headless wait OBSERVED — the outcome AND the main-actor
    /// availability record that decides what a TIMEOUT means.
    private struct WaitOutcome {
        /// Did the awaited condition become true (grace re-check included)?
        let satisfied: Bool
        /// Wall seconds the wait consumed.
        let elapsedSeconds: Double
        /// Poll iterations completed. ~100/s on a quiet machine (10 ms cadence).
        let polls: Int
        /// **THE INSTRUMENT.** The longest interval between two consecutive
        /// polls. This loop is `@MainActor`-isolated, exactly like the ticker
        /// it is watching, so a gap of G seconds is a MEASUREMENT that the main
        /// actor served this suite nothing for G seconds — and therefore that
        /// the ticker, which needs the same actor, got no turn either. It is
        /// not a proxy for load; it is the starvation itself.
        let maxGapSeconds: Double
    }

    /// The load population these six headless tests are readable in — the
    /// longest main-actor dark gap under which a TIMEOUT is still evidence
    /// ABOUT THE FEATURE rather than evidence about the machine.
    ///
    /// ── WHY A FENCE EXISTS HERE AT ALL (m31-i, 2026-08-28) ─────────────────
    /// MEASURED: this suite is 0.538 s green in isolation and has been observed
    /// at 66.6 s under the loaded full suite — a ~124x inflation, with
    /// `waitUntil` timeouts. It is the same class as the m19-e clean-path
    /// flake fenced the same day in `AUPrepareRenegotiationStressTests`
    /// (`populationValidityMaxMedianSeconds`), and it has the same cause: the
    /// harness grew ~44 % (4 693 -> 6 752 tests) and the main actor is now
    /// saturated for stretches long enough that a detached `@MainActor` ticker
    /// gets NO turn. An earlier draft of these tests recorded
    /// `positionBeats == 0.0` after 23 s of wall time — zero ticks, not "too
    /// many". Under those conditions the wait measures the harness, not m25-d.
    ///
    /// ── WHY THIS FENCE IS NARROW, AND WHY THAT MATTERS ────────────────────
    /// ⭐ It does NOT excuse a timeout. It excuses ONE residual, ambiguous
    /// case. Every one of the six tests hands `requireHeadless` an
    /// AFFIRMATIVE-REGRESSION predicate that is asserted UNCONDITIONALLY, at
    /// any load, because starvation is only ever able to produce TOO FEW
    /// ticks — it can never make the transport DO something:
    ///   * the stop test: `positionBeats >= contentEnd` while still playing.
    ///     The ticker assigns the position and stops IN THE SAME synchronous
    ///     hop (no `await` between), so that state is unreachable unless the
    ///     end-stop arming is broken.
    ///   * the five keeps-running tests: `!isPlaying`. A stop is an
    ///     affirmative act; a starved ticker leaves the transport rolling.
    /// So the bug each test was written to catch — an early stop, a dead play
    /// button, a phantom end — reddens at ANY load. What the fence covers is
    /// only "the ticker did not get far enough, and the actor was dark", which
    /// is not a statement about m25-d.
    ///
    /// ── THE VALUE, AND HOW TO RE-DERIVE IT ────────────────────────────────
    /// DERIVED, not tuned: one ticker hop after t >= 0.5 s satisfies ALL SIX
    /// tests, because the ticker advances by REAL ELAPSED TIME
    /// (`ContinuousClock` delta x 240 BPM = 4 beats/s), not by a fixed
    /// increment — a single hop at t = 0.5 s already lands the playhead at
    /// 2 beats. The ticker's period is 33 ms. So a run whose largest dark gap
    /// is <= 1.0 s left >= 29 of its 30 s served, during which a 33 ms-period
    /// task cannot fail to be scheduled: a timeout there is the feature's
    /// fault, not the machine's. Quiet-machine noise is ~0.010-0.015 s (the
    /// 10 ms poll cadence), so the bound keeps ~70x of teeth in isolation.
    ///
    /// RE-DERIVATION: `maxGap` is printed on EVERY outcome, satisfied or not,
    /// by `requireHeadless` — so any full-suite log is already a population
    /// sample. Re-derive by tabulating `[endstop-gate` lines across >= 5 green
    /// full-suite runs; the envelope must stay far above the isolated-run gap
    /// (or the fence eats its own teeth) and below the dark stretches that
    /// produce the timeouts.
    ///
    /// ⚠️ A TIMEOUT INSIDE THIS ENVELOPE IS NOT A FLAKE. It is a real
    /// regression, or evidence the envelope needs re-deriving on a grown
    /// harness. Investigate; do not raise this constant to make it green.
    ///
    /// ⚠️ HONEST CONSEQUENCE: on a saturated run the six waits can RECORD AND
    /// SKIP their timeout leg. That is a real coverage loss, stated here so it
    /// cannot be discovered by surprise. It is bounded by the affirmative legs
    /// above (which never skip) and by the 40 non-headless tests in this file,
    /// which need no ticker at all.
    ///
    /// ⛔ NOT A LICENCE TO SELF-EXCUSE ELSEWHERE. Licensed by one measured
    /// fact: a wait whose contaminant is TOTAL (zero hops) rather than small
    /// or multiplicative. A bound whose contaminant is small gets fixed.
    private static let mainActorStarvationEnvelopeSeconds = 1.0

    /// Polls for an OUTCOME instead of sleeping a fixed wall-clock interval,
    /// and records the main-actor availability of the window it polled.
    ///
    /// ⚠️ **Measured, not defensive.** The headless ticker is a detached `Task`
    /// that must hop to the MAIN ACTOR on every iteration. Under a saturated
    /// full-suite run it can get none: an earlier draft of these tests slept a
    /// fixed 600–900 ms and observed `positionBeats == 0.0` after **23 seconds**
    /// of wall time — zero ticks, not "too many". A fixed sleep measures the
    /// machine's load, not the feature. Polling for the outcome makes these
    /// load-independent, and fast in the common case.
    ///
    /// ⚠️ **The grace re-check is not padding — it closes a measured race.**
    /// This loop and the ticker contend for the SAME actor. If the actor goes
    /// dark until just before the deadline, this loop can be resumed FIRST,
    /// see the deadline expired and report a timeout while the ticker sits
    /// queued one slot behind it, about to do exactly the right thing. Yielding
    /// past the deadline before the final read costs nothing on the happy path
    /// (it is only reached on an otherwise-failing wait) and removes a failure
    /// mode that is purely an artefact of scheduling order.
    private func waitUntil(_ budget: Duration = .seconds(30),
                           _ condition: () -> Bool) async -> WaitOutcome {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: budget)
        var polls = 0
        var maxGapSeconds = 0.0
        var previous = start
        while ContinuousClock.now < deadline {
            let now = ContinuousClock.now
            maxGapSeconds = max(maxGapSeconds, Self.secondsOf(previous.duration(to: now)))
            previous = now
            polls += 1
            if condition() {
                return WaitOutcome(satisfied: true,
                                   elapsedSeconds: Self.secondsOf(start.duration(to: now)),
                                   polls: polls,
                                   maxGapSeconds: maxGapSeconds)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(150))
        let end = ContinuousClock.now
        maxGapSeconds = max(maxGapSeconds, Self.secondsOf(previous.duration(to: end)))
        return WaitOutcome(satisfied: condition(),
                           elapsedSeconds: Self.secondsOf(start.duration(to: end)),
                           polls: polls,
                           maxGapSeconds: maxGapSeconds)
    }

    /// THE DECISION POINT for all six headless waits: assert, or RECORD AND
    /// SKIP **loudly**. It never silently passes — every call prints exactly
    /// one `[endstop-gate …]` line, so a campaign log states on its face
    /// whether these bounds ran or declined.
    ///
    /// Three legs, in order:
    ///  1. **AFFIRMATIVE REGRESSION — asserted at ANY load.** `regression`
    ///     names a state that REQUIRES the ticker to have run. Starvation can
    ///     only ever produce too few ticks, so no load envelope excuses it.
    ///     This is where each test's real bug lives; see
    ///     `mainActorStarvationEnvelopeSeconds` for the per-test list.
    ///  2. **THE ACTOR WAS AVAILABLE — asserted.** The largest dark gap sits
    ///     inside the envelope, so a 33 ms-period ticker had its turns and did
    ///     not take them. Red.
    ///  3. **OUT OF POPULATION — recorded, NOT asserted.** Loud, greppable,
    ///     and it prints the values it declined to assert on.
    ///
    /// ⚠️ The print prefix is `[endstop-gate` and deliberately NOT
    /// `[measured] ` — `scripts/gates/m23aw-prepare-headroom.mjs` and Leg D of
    /// `MainActorOccupancySiteTests` both key off that prefix and must see
    /// exactly what they saw before.
    private func requireHeadless(_ outcome: WaitOutcome,
                                 _ label: String,
                                 regression: Bool,
                                 state: String,
                                 failure: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let record = "polls \(outcome.polls) over \(outcome.elapsedSeconds) s, "
            + "maxGap \(outcome.maxGapSeconds) s, envelope "
            + "\(Self.mainActorStarvationEnvelopeSeconds) s"
        if outcome.satisfied {
            print("[endstop-gate ACTIVE] \(label): outcome REACHED, assertions ran (\(record)).")
            return
        }
        if regression {
            print("[endstop-gate ACTIVE] \(label): timeout ASSERTED as an AFFIRMATIVE "
                  + "REGRESSION — load-independent (\(record)).")
            Issue.record("""
                \(failure) — state: \(state). This state REQUIRES the ticker to have run; \
                main-actor starvation can only ever produce too FEW ticks, so no load envelope \
                excuses it. \(record)
                """, sourceLocation: sourceLocation)
            return
        }
        if outcome.maxGapSeconds <= Self.mainActorStarvationEnvelopeSeconds {
            print("[endstop-gate ACTIVE] \(label): timeout ASSERTED — the main actor stayed "
                  + "inside the envelope, so the ticker had its turns (\(record)).")
            Issue.record("""
                \(failure) — state: \(state). The main actor's longest dark gap was \
                \(outcome.maxGapSeconds) s, inside the \(Self.mainActorStarvationEnvelopeSeconds) s \
                envelope, so a 33 ms-period ticker was schedulable throughout. This is a real \
                failure, not ambient load. \(record)
                """, sourceLocation: sourceLocation)
            return
        }
        print("[endstop-gate skipped: ambient load] \(label): timeout RECORDED, NOT ASSERTED — "
              + "the main actor went dark for \(outcome.maxGapSeconds) s, past the "
              + "\(Self.mainActorStarvationEnvelopeSeconds) s envelope, so the headless ticker "
              + "provably got no turn. Unasserted: \(failure) — state: \(state). \(record). "
              + "This is NOT a pass of that bound.")
    }

    @Test("headless: playback STOPS at the content end, playhead parked exactly there")
    func headlessStopsAtContentEnd() async {
        let store = makeHeadless(contentEnd: 1)
        store.play()
        #expect(store.transport.isPlaying)
        let w = await waitUntil { !store.transport.isPlaying }
        requireHeadless(w, "headlessStopsAtContentEnd",
                        // AFFIRMATIVE: the ticker demonstrably reached the content
                        // end and did NOT stop. The ticker assigns the position and
                        // stops in ONE synchronous hop, so this is unreachable
                        // unless arming is broken — starvation cannot fake it.
                        regression: store.transport.positionBeats >= 1,
                        state: "positionBeats \(store.transport.positionBeats), "
                             + "isPlaying \(store.transport.isPlaying)",
                        failure: "the transport should have stopped at the last clip")
        if w.satisfied {
            #expect(store.transport.positionBeats == 1,
                    "parked exactly on the content end, not wherever the tick overshot to")
        }
        store.stop()
    }

    @Test("headless: an EMPTY project does not stop instantly — it keeps running")
    func headlessEmptyProjectKeepsRunning() async {
        let store = makeHeadless(contentEnd: 0)
        store.play()
        // Wait for POSITIVE evidence the ticker ran well past where a content
        // end would have been. If the feature wrongly stopped an empty project
        // the playhead freezes and this wait fails — that is the discriminating
        // assertion, not the `isPlaying` read after it.
        let w = await waitUntil { store.transport.positionBeats > 2 }
        requireHeadless(w, "headlessEmptyProjectKeepsRunning",
                        // AFFIRMATIVE: a stop is an act. This IS the bug.
                        regression: !store.transport.isPlaying,
                        state: "positionBeats \(store.transport.positionBeats), "
                             + "isPlaying \(store.transport.isPlaying)",
                        failure: "an empty project must not stop the instant you press play")
        #expect(store.transport.isPlaying)
        store.stop()
    }

    @Test("headless: preference OFF runs past the content end")
    func headlessPreferenceOffRunsPast() async {
        let store = makeHeadless(contentEnd: 1)
        store.setStopAtContentEnd(false)
        store.play()
        let w = await waitUntil { store.transport.positionBeats > 1 }
        requireHeadless(w, "headlessPreferenceOffRunsPast",
                        regression: !store.transport.isPlaying,
                        state: "positionBeats \(store.transport.positionBeats), "
                             + "isPlaying \(store.transport.isPlaying)",
                        failure: "ran past the last clip, as asked")
        #expect(store.transport.isPlaying)
        store.stop()
    }

    @Test("headless: an active LOOP keeps cycling past the content end")
    func headlessLoopKeepsRunning() async throws {
        let store = makeHeadless(contentEnd: 1)
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 4)
        store.play()
        let w = await waitUntil { store.transport.positionBeats > 1 }
        requireHeadless(w, "headlessLoopKeepsRunning",
                        regression: !store.transport.isPlaying,
                        state: "positionBeats \(store.transport.positionBeats), "
                             + "isPlaying \(store.transport.isPlaying)",
                        failure: "looping takes precedence over the content-end stop")
        #expect(store.transport.isPlaying)
        store.stop()
    }

    @Test("headless: pressing play AGAIN after an end stop free-runs instead of dying")
    func headlessSecondPlayFreeRuns() async {
        let store = makeHeadless(contentEnd: 1)
        store.play()
        let first = await waitUntil { !store.transport.isPlaying }
        requireHeadless(first, "headlessSecondPlayFreeRuns/firstStop",
                        regression: store.transport.positionBeats >= 1,
                        state: "positionBeats \(store.transport.positionBeats), "
                             + "isPlaying \(store.transport.isPlaying)",
                        failure: "the first play must stop at the content end")
        guard first.satisfied else {
            // The second half is only meaningful from a parked playhead. Its
            // own bound is not being skipped for load — it is UNREACHABLE, and
            // saying so is different from saying it passed.
            print("[endstop-gate skipped: ambient load] headlessSecondPlayFreeRuns/secondPlay: "
                  + "NOT REACHED — the first stop never happened, so the dead-button bound had no "
                  + "parked playhead to start from. This is NOT a pass of that bound.")
            store.stop()
            return
        }
        #expect(store.transport.positionBeats == 1)
        // The playhead now sits AT the content end. A `<=` arming rule would
        // stop again immediately and the play button would look dead; strict
        // `<` free-runs instead.
        store.play()
        let second = await waitUntil { store.transport.positionBeats > 1 }
        requireHeadless(second, "headlessSecondPlayFreeRuns/secondPlay",
                        // AFFIRMATIVE, and it is THE bug this test exists for: a
                        // `<=` arming rule stops instantly, which is an ACT.
                        regression: !store.transport.isPlaying,
                        state: "positionBeats \(store.transport.positionBeats), "
                             + "isPlaying \(store.transport.isPlaying)",
                        failure: "the second press must not be a dead button")
        #expect(store.transport.isPlaying)
        store.stop()
    }

    @Test("headless: content BEHIND the playhead start is not a reason to stop instantly")
    func headlessStartPastContentRunsOn() async throws {
        let store = makeHeadless(contentEnd: 1)
        try store.seek(toBeats: 8)
        store.play()
        let w = await waitUntil { store.transport.positionBeats > 8 }
        requireHeadless(w, "headlessStartPastContentRunsOn",
                        regression: !store.transport.isPlaying,
                        state: "positionBeats \(store.transport.positionBeats), "
                             + "isPlaying \(store.transport.isPlaying)",
                        failure: "starting past the content end free-runs, it does not stop")
        #expect(store.transport.isPlaying)
        store.stop()
    }

    // MARK: - Snapshot mirror

    /// The snapshot field is the OVERRIDE (`runsPastContentEnd`), not the
    /// preference — so the omitted state reads TRUE in plain English ("does not
    /// run past the content end") instead of being a lie an agent has to know a
    /// `?? true` convention to decode. It is never emitted as `false`.
    @Test("snapshot OMITS runsPastContentEnd at the default and carries true when opted out")
    func snapshotMirrorsPreference() {
        let (store, _) = makeStore(contentEnd: 32)
        #expect(store.snapshot().runsPastContentEnd == nil,
                "default (stops) is omitted — a default session stays byte-identical")
        store.setStopAtContentEnd(false)
        #expect(store.snapshot().runsPastContentEnd == true,
                "opting out is the ONLY state that emits the key, and it emits true")
        store.setStopAtContentEnd(true)
        #expect(store.snapshot().runsPastContentEnd == nil)
    }

    /// The polarity guard. If someone ever "tidies" the inversion away, the
    /// field starts reading `false` at the opted-out state and every absent-key
    /// reader silently flips meaning. `false` must be unreachable.
    @Test("runsPastContentEnd is NEVER false — absent or true, never a third state")
    func overrideIsNeverFalse() {
        let (store, _) = makeStore(contentEnd: 32)
        for enabled in [true, false, true, false] {
            store.setStopAtContentEnd(enabled)
            #expect(store.snapshot().runsPastContentEnd != false)
            // And it is the exact inverse of the store's preference.
            #expect((store.snapshot().runsPastContentEnd ?? false) == !enabled)
        }
    }

    @Test("snapshot carries the measured content end, omitted for an empty project")
    func snapshotCarriesContentEnd() {
        let (store, _) = makeStore(contentEnd: 32)
        #expect(store.snapshot().contentEndBeat == 32)
        #expect(ProjectStore().snapshot().contentEndBeat == nil)
    }

    @Test("the preference survives undo/redo — it is session state, not document state")
    func preferenceUntouchedByUndo() throws {
        let (store, _) = makeStore(contentEnd: 32)
        store.setStopAtContentEnd(false)
        _ = store.addTrack(name: "another", kind: .audio)
        try store.undo()
        #expect(!store.stopAtContentEnd, "undo must not restore a preference")
        try store.redo()
        #expect(!store.stopAtContentEnd)
    }
}
