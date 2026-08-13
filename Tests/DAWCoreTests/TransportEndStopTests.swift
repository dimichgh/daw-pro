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

    /// Polls for an OUTCOME instead of sleeping a fixed wall-clock interval.
    ///
    /// ⚠️ **Measured, not defensive.** The headless ticker is a detached `Task`
    /// that must hop to the MAIN ACTOR on every iteration. Under a saturated
    /// full-suite run it can get none: an earlier draft of these tests slept a
    /// fixed 600–900 ms and observed `positionBeats == 0.0` after **23 seconds**
    /// of wall time — zero ticks, not "too many". A fixed sleep measures the
    /// machine's load, not the feature. Polling for the outcome makes these
    /// load-independent, and fast in the common case.
    @discardableResult
    private func waitUntil(_ budget: Duration = .seconds(30),
                           _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: budget)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("headless: playback STOPS at the content end, playhead parked exactly there")
    func headlessStopsAtContentEnd() async {
        let store = makeHeadless(contentEnd: 1)
        store.play()
        #expect(store.transport.isPlaying)
        let stopped = await waitUntil { !store.transport.isPlaying }
        #expect(stopped, "the transport should have stopped at the last clip")
        #expect(store.transport.positionBeats == 1,
                "parked exactly on the content end, not wherever the tick overshot to")
    }

    @Test("headless: an EMPTY project does not stop instantly — it keeps running")
    func headlessEmptyProjectKeepsRunning() async {
        let store = makeHeadless(contentEnd: 0)
        store.play()
        // Wait for POSITIVE evidence the ticker ran well past where a content
        // end would have been. If the feature wrongly stopped an empty project
        // the playhead freezes and this wait fails — that is the discriminating
        // assertion, not the `isPlaying` read after it.
        let advanced = await waitUntil { store.transport.positionBeats > 2 }
        #expect(advanced, "an empty project must not stop the instant you press play")
        #expect(store.transport.isPlaying)
        store.stop()
    }

    @Test("headless: preference OFF runs past the content end")
    func headlessPreferenceOffRunsPast() async {
        let store = makeHeadless(contentEnd: 1)
        store.setStopAtContentEnd(false)
        store.play()
        let ranPast = await waitUntil { store.transport.positionBeats > 1 }
        #expect(ranPast, "ran past the last clip, as asked")
        #expect(store.transport.isPlaying)
        store.stop()
    }

    @Test("headless: an active LOOP keeps cycling past the content end")
    func headlessLoopKeepsRunning() async throws {
        let store = makeHeadless(contentEnd: 1)
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 4)
        store.play()
        let ranPast = await waitUntil { store.transport.positionBeats > 1 }
        #expect(ranPast, "looping takes precedence over the content-end stop")
        #expect(store.transport.isPlaying)
        store.stop()
    }

    @Test("headless: pressing play AGAIN after an end stop free-runs instead of dying")
    func headlessSecondPlayFreeRuns() async {
        let store = makeHeadless(contentEnd: 1)
        store.play()
        #expect(await waitUntil { !store.transport.isPlaying })
        #expect(store.transport.positionBeats == 1)
        // The playhead now sits AT the content end. A `<=` arming rule would
        // stop again immediately and the play button would look dead; strict
        // `<` free-runs instead.
        store.play()
        let ranOn = await waitUntil { store.transport.positionBeats > 1 }
        #expect(ranOn, "the second press must not be a dead button")
        #expect(store.transport.isPlaying)
        store.stop()
    }

    @Test("headless: content BEHIND the playhead start is not a reason to stop instantly")
    func headlessStartPastContentRunsOn() async throws {
        let store = makeHeadless(contentEnd: 1)
        try store.seek(toBeats: 8)
        store.play()
        let ranOn = await waitUntil { store.transport.positionBeats > 8 }
        #expect(ranOn, "starting past the content end free-runs, it does not stop")
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
