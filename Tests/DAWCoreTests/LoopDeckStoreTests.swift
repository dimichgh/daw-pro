import Foundation
import Testing
@testable import DAWCore

/// A fake engine that implements the m34-h LAYER surface — `startTakeInPlayback`
/// and `finishTakeKeepingPlayback` — so a whole live-looping session can be
/// driven headlessly, with the take completion fired by hand.
///
/// ⚠️ The protocol's defaults for both are deliberately USELESS (`false` and a
/// throw), so a fake that forgot to override them would make every deck test
/// pass vacuously. They are overridden here, and the store's own refusal on
/// `false` is pinned in `LiveLayerCapture`'s suite against the real engine.
@MainActor
final class FakeDeckEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    private(set) var tracksDidChangeCount = 0
    private(set) var layerStarts = 0
    private(set) var stopPlaybackCalls = 0
    private(set) var stopRecordingCalls = 0
    private(set) var endStopPushes: [Double?] = []
    private(set) var completion: (@MainActor (Result<TakeResult, Error>) -> Void)?
    /// Every layer take's completion, in order — with layering several takes can
    /// be in flight, so the newest must not overwrite an older one's handle.
    private(set) var layerCompletions: [@MainActor (Result<TakeResult, Error>) -> Void] = []

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) { tracksDidChangeCount += 1 }
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() { stopPlaybackCalls += 1 }
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func setEndStop(beat: Double?) { endStopPushes.append(beat) }
    var currentEndStop: Double? { endStopPushes.last ?? nil }

    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }

    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func availableMIDIInputs() -> [MIDIInputDevice] { [] }
    func midiEventCount() -> Int { 0 }

    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        Issue.record("the deck must never reach the legacy startRecording")
    }

    func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                   completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
        self.completion = completion
    }

    func startTakeInPlayback(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                             completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
        layerStarts += 1
        layerCompletions.append(completion)
        completion_ = completion
    }
    private var completion_: (@MainActor (Result<TakeResult, Error>) -> Void)?

    func finishTakeKeepingPlayback() -> Bool { completion_ != nil }
    func stopRecording() { stopRecordingCalls += 1 }

    /// Fires the OLDEST outstanding layer completion — takes land in the order
    /// they were closed.
    func landLayer(notes: [MIDINote], lengthBeats: Double = 4) {
        guard !layerCompletions.isEmpty else {
            Issue.record("no layer take is outstanding")
            return
        }
        let c = layerCompletions.removeFirst()
        if layerCompletions.isEmpty { completion_ = nil }
        c(.success(TakeResult(midi: MIDIRecordingResult(notes: notes, lengthBeats: lengthBeats))))
    }

    func failLayer(_ error: Error) {
        guard !layerCompletions.isEmpty else { return }
        let c = layerCompletions.removeFirst()
        if layerCompletions.isEmpty { completion_ = nil }
        c(.failure(error))
    }
}

/// m34-h-1 LIVE LOOPING — **the deck's state machine, through the real store.**
///
/// `LoopDeckMathTests` pins the arithmetic. This suite pins what the store does
/// with it: who arms, what a landing writes onto the timeline, what a peel takes
/// back, and — the ones that are easy to get wrong — what happens when a pass
/// captures nothing, fails, or lands after the deck moved on.
@MainActor
@Suite("Loop deck — store state machine (m34-h-1)")
struct LoopDeckStoreTests {

    /// A store with two instrument tracks, playing, at `beat`.
    private func rolling(at beat: Double = 0)
        -> (ProjectStore, FakeDeckEngine, Track, Track) {
        let engine = FakeDeckEngine()
        let store = ProjectStore(projectName: "m34-h-1 deck")
        store.engine = engine
        let a = store.addTrack(name: "Chords", kind: .instrument)
        let b = store.addTrack(name: "Bass", kind: .instrument)
        store.play()
        engine.playheadHandler?(beat)
        return (store, engine, a, b)
    }

    /// Moves the playhead through the PRODUCTION path — the engine's own
    /// `playheadHandler`, which is what pushes `transport.positionBeats` on a
    /// live session — and then applies what the deck's schedule says is due.
    ///
    /// ⚠️ **THE APPLY IS CALLED DIRECTLY RATHER THAN AWAITED, AND THAT IS
    /// DELIBERATE.** `refreshLoopDeck()` defers the work onto a fresh
    /// main-actor `Task` so the engine's playhead handler never re-enters the
    /// engine; a synchronous test cannot observe that task without a
    /// wall-clock wait, and a wall-clock wait is the shape that retired a test
    /// on m34-a-2 under full-suite load. Every deck action is idempotent, so if
    /// the hopped task does run it finds nothing left to do. The hop's own
    /// existence is pinned by `theHopIsRealAndFiresTheLaunch`.
    private func tick(_ store: ProjectStore, to beat: Double, _ engine: FakeDeckEngine) {
        engine.playheadHandler?(beat)
        store.applyDueDeckActions()
    }

    // MARK: Session lifecycle

    @Test("begin sets the origin to the bar line at or BEFORE the playhead")
    func beginFloorsTheOriginToABar() throws {
        let (store, _, _, _) = rolling(at: 13.7)
        let status = try store.beginLoopDeck(bars: 4)
        #expect(status.originBeat == 12)
        #expect(status.cycleBeats == 16)
        #expect(status.beatsPerBar == 4)
        #expect(status.lengthMode == .fixedBars)
    }

    @Test("no bar count means PRESS-TO-END, and the length is not known yet")
    func pressToEndStartsWithoutALength() throws {
        let (store, _, _, _) = rolling()
        let status = try store.beginLoopDeck(bars: nil)
        #expect(status.lengthMode == .pressToEnd)
        #expect(status.cycleBeats == nil)
    }

    @Test("⛔ begin REFUSES while the transport loop is enabled, and says why")
    func beginRefusesTheTransportLoop() throws {
        let (store, _, _, _) = rolling()
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 8)
        var message = ""
        #expect(throws: ProjectError.self) {
            do { _ = try store.beginLoopDeck(bars: 4) }
            catch { message = (error as? LocalizedError)?.errorDescription ?? ""; throw error }
        }
        // The refusal must TEACH: this tree already shipped loop-cycle take
        // recording, and reading it as live looping builds the wrong feature.
        #expect(message.contains("transport loop"))
        #expect(message.contains("take-comping"))
        #expect(store.loopDeck == nil)
    }

    @Test("begin refuses a second session, and end closes the first")
    func oneSessionAtATime() throws {
        let (store, _, _, _) = rolling()
        _ = try store.beginLoopDeck(bars: 2)
        #expect(throws: ProjectError.self) { _ = try store.beginLoopDeck(bars: 2) }
        try store.endLoopDeck()
        #expect(store.loopDeck == nil)
        _ = try store.beginLoopDeck(bars: 2)   // now free
    }

    @Test("⭐ AN OPEN SESSION SUSPENDS THE CONTENT-END BOUND — the music does not stop by itself")
    func anOpenDeckSuspendsTheEndStop() throws {
        let (store, engine, a, _) = rolling()
        // Content ending at beat 4, and the stop-at-content-end preference on.
        _ = try store.addMIDIClip(toTrack: a.id, atBeat: 0, lengthBeats: 4,
                                  notes: [MIDINote(pitch: 60, startBeat: 0)])
        store.setStopAtContentEnd(true)
        engine.playheadHandler?(0)
        #expect(store.contentEndBeat == 4)
        _ = try store.beginLoopDeck(bars: 1)
        // The bound is recomputed the moment the deck opens, and it is nil.
        #expect(engine.currentEndStop == nil)
        try store.endLoopDeck()
        // ...and it comes back when the session ends.
        #expect(engine.currentEndStop == 4)
    }

    @Test("⭐ OPENING AND CLOSING A SESSION DOES NOT DIRTY THE PROJECT — a performance mode is not a document edit")
    func theDeckIsNotADocumentEdit() throws {
        let (store, _, _, _) = rolling()
        // A genuinely clean document: save it, so `isDirty` is false for real
        // rather than false because nothing has happened yet.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m34h1-dirty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.saveProject(to: dir.appendingPathComponent("deck.dawproj").path)
        #expect(store.isDirty == false, "control: the save must actually clear the flag")
        // ⚠️ NOT `canUndo == false` — a save clears the DIRTY flag, not the
        // journal, and `rolling()`'s two `addTrack` calls are real edits that
        // legitimately sit on the stack. The claim is that the deck adds
        // NOTHING to it, so the measurement is the stack's top BEFORE vs AFTER.
        let historyBefore = store.undoHistory().undo
        #expect(historyBefore.isEmpty == false, "control: the stack is non-empty to begin with")

        _ = try store.beginLoopDeck(bars: 2)
        // ⚠️ THE REGRESSION. The first version routed the end-stop refresh
        // through `performEdit`, whose `markDirty()` is UNCONDITIONAL — so
        // merely opening a live-looping session raised an unsaved-changes
        // prompt for a document nobody had edited. Nothing here changes project
        // content: no clip has landed yet.
        #expect(store.isDirty == false, "opening a deck must not dirty the project")
        #expect(store.undoHistory().undo == historyBefore, "and it must not pollute the undo stack")

        try store.endLoopDeck()
        #expect(store.isDirty == false, "closing one must not either")
        #expect(store.undoHistory().undo == historyBefore)
    }

    // MARK: Arming

    @Test("arm refuses without a session, without playback, and on an audio track")
    func armRefusals() throws {
        let engine = FakeDeckEngine()
        let store = ProjectStore(projectName: "m34-h-1 refusals")
        store.engine = engine
        let inst = store.addTrack(kind: .instrument)
        let audio = store.addTrack(kind: .audio)

        #expect(throws: ProjectError.self) { _ = try store.armLoopLayer(trackID: inst.id) }
        store.play()
        _ = try store.beginLoopDeck(bars: 1)
        // v1 is MIDI layers only — a waveform cannot be tiled inside one clip.
        #expect(throws: ProjectError.self) { _ = try store.armLoopLayer(trackID: audio.id) }
        // ...and a stopped transport gets `recordLayer()`'s own teaching error.
        store.stop()
        #expect(throws: ProjectError.self) { _ = try store.armLoopLayer(trackID: inst.id) }
    }

    @Test("arming queues the layer and arms EXACTLY that track")
    func armIsExclusive() throws {
        let (store, _, a, b) = rolling(at: 1)
        _ = try store.setTrackArm(id: b.id, armed: true)   // a stale arm elsewhere
        _ = try store.beginLoopDeck(bars: 1)
        let status = try store.armLoopLayer(trackID: a.id)

        #expect(status.pendingPhase == .queued)
        #expect(status.lamps.count == 1)
        #expect(status.lamps[0].state == .queued)
        // `recordLayer()` records onto EVERY armed instrument track, so a stale
        // arm would silently capture the same performance onto two layers.
        #expect(store.tracks.first { $0.id == a.id }?.isArmed == true)
        #expect(store.tracks.first { $0.id == b.id }?.isArmed == false)
    }

    @Test("⭐ THE FIRST LAYER'S LAUNCH BOUNDARY BECOMES THE ORIGIN")
    func theFirstLayerDefinesCycleZero() throws {
        // The deck opened at beat 0, but the performer waited and armed at 9.4.
        // Cycle 0 is where they play, not where they pressed `begin`.
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)   // 4-beat cycle, origin 0
        engine.playheadHandler?(9.4)
        let status = try store.armLoopLayer(trackID: a.id)
        #expect(status.originBeat == 12)
        #expect(status.pendingLaunchBeat == 12)
    }

    @Test("the take fires at the ARM beat and carries a deck window, not an ordinary layer")
    func theLaunchFiresEarly() throws {
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        _ = try store.armLoopLayer(trackID: a.id)      // launch 4, arm 3
        tick(store, to: 2.9, engine)
        #expect(engine.layerStarts == 0)
        #expect(store.loopDeckStatus?.pendingPhase == .queued)
        tick(store, to: 3.0, engine)
        #expect(engine.layerStarts == 1)
        #expect(store.loopDeckStatus?.pendingPhase == .recording)
        #expect(store.transport.isRecording)
    }

    @Test("⭐ THE HOP IS REAL: the engine's playhead handler alone fires the launch, without re-entering the engine")
    func theHopIsRealAndFiresTheLaunch() async throws {
        // Every other test in this suite applies deck actions synchronously, so
        // this is the one that proves the production driver works at all: a bare
        // `playheadHandler` push, with NO direct call to `applyDueDeckActions`.
        //
        // ⚠️ The engine's handler documents that it "NEVER calls back into the
        // engine", and `AudioEngine` is `@MainActor` — so the deck's work is
        // deferred onto a fresh main-actor task rather than run inline. The
        // yields below let that task run; they are not a wall-clock wait, and
        // the assertion is on a state change, not on elapsed time.
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        _ = try store.armLoopLayer(trackID: a.id)          // launch 4, arm 3
        #expect(engine.layerStarts == 0)

        engine.playheadHandler?(3.2)                       // due — and nothing else
        for _ in 0..<8 where engine.layerStarts == 0 { await Task.yield() }
        #expect(engine.layerStarts == 1)
        #expect(store.loopDeckStatus?.pendingPhase == .recording)
        // The gate cleared, so the next tick can act again.
        #expect(store.loopDeck?.launchInFlight == false)
    }

    // MARK: Landing

    /// Records one layer end to end.
    ///
    /// `played` gives each note's position **relative to the capture window**,
    /// which is how a performer experiences it: "the chord on the downbeat of
    /// my layer, and another two beats later". The helper converts to the
    /// clip-relative beats the engine really delivers, so no test hand-computes
    /// a take's start — the mistake that would make an alignment assertion
    /// agree with a bug.
    ///
    /// - Parameter cyclesToPlay: how many cycles the pass runs before the
    ///   finish is pressed.
    private func recordLayer(_ store: ProjectStore, _ engine: FakeDeckEngine,
                             track: Track, played: [(pitch: Int, offset: Double)],
                             armAt: Double, cyclesToPlay: Double = 1,
                             mode: LoopLayerMode? = nil) throws {
        engine.playheadHandler?(armAt)
        _ = try store.armLoopLayer(trackID: track.id, mode: mode)
        let launch = store.loopDeckStatus!.pendingLaunchBeat!
        let armBeat = store.loopDeck!.pending!.armBeat
        tick(store, to: armBeat, engine)                       // the take starts here
        let takeStart = armBeat
        let cycle = store.loopDeck!.cycleBeats ?? store.loopDeck!.beatsPerBar
        engine.playheadHandler?(launch + cycle * cyclesToPlay - 0.5)
        _ = try store.finishLoopLayer()
        let close = store.loopDeck!.pending!.closeBeat!
        tick(store, to: close, engine)                         // the close fires
        // The engine delivers the capture clip-relative to where it began.
        engine.landLayer(notes: played.map {
            MIDINote(pitch: $0.pitch, velocity: 100,
                     startBeat: launch + $0.offset - takeStart, lengthBeats: 0.5)
        })
    }

    @Test("⭐⭐ TWO LAYERS STACK ONTO TWO TRACKS, ALIGNED, AND BOTH REPEAT")
    func twoLayersStackAndTile() throws {
        let (store, engine, a, b) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)           // 4-beat cycle

        // Layer 1: a chord on the downbeat and beat 3 of cycle 0 (origin 4).
        try recordLayer(store, engine, track: a,
                        played: [(60, 0), (67, 2)], armAt: 0)

        // Layer 2: a bass note on the downbeat of cycle 2 (beat 12) and beat 14
        // — a DIFFERENT cycle, so a folding bug would show up as an offset.
        try recordLayer(store, engine, track: b,
                        played: [(40, 0), (47, 2)], armAt: 9)

        let deck = store.loopDeck!
        #expect(deck.layers.count == 2)
        #expect(deck.originBeat == 4)
        // The two layers' CYCLE positions are identical, which is the proof the
        // second one lines up with the first regardless of when it was recorded.
        #expect(deck.layers[0].cycle.map(\.startBeat) == [0, 2])
        #expect(deck.layers[1].cycle.map(\.startBeat) == [0, 2])

        // On the timeline: one clip per track, both starting at the origin, both
        // tiled across the same span.
        let clipA = store.tracks.first { $0.id == a.id }!.clips
        let clipB = store.tracks.first { $0.id == b.id }!.clips
        #expect(clipA.count == 1)
        #expect(clipB.count == 1)
        #expect(clipA[0].startBeat == 4)
        #expect(clipB[0].startBeat == 4)
        #expect(clipA[0].lengthBeats == clipB[0].lengthBeats)
        // Tiled: the pattern repeats every 4 beats, on both tracks.
        #expect(clipA[0].notes!.prefix(6).map(\.startBeat) == [0, 2, 4, 6, 8, 10])
        #expect(clipB[0].notes!.prefix(6).map(\.startBeat) == [0, 2, 4, 6, 8, 10])
    }

    @Test("recording again on the SAME track overdubs by default and replaces on request")
    func recordAgainOverdubsThenReplaces() throws {
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        try recordLayer(store, engine, track: a, played: [(60, 0)], armAt: 0)
        #expect(store.loopDeck!.layers.count == 1)

        try recordLayer(store, engine, track: a, played: [(64, 1)], armAt: 8)
        // ONE layer, TWO notes: the second pass joined the first.
        #expect(store.loopDeck!.layers.count == 1)
        #expect(store.loopDeck!.layers[0].cycle.map(\.pitch) == [60, 64])

        try recordLayer(store, engine, track: a, played: [(72, 1)], armAt: 16,
                        mode: .replace)
        #expect(store.loopDeck!.layers[0].cycle.map(\.pitch) == [72])
    }

    @Test("press-to-end: the FINISH press decides the loop length, rounded to whole bars")
    func pressToEndSetsTheLengthAtFinish() throws {
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: nil)
        engine.playheadHandler?(0)
        _ = try store.armLoopLayer(trackID: a.id)      // no cycle yet: grids on the bar
        let launch = store.loopDeckStatus!.pendingLaunchBeat!
        #expect(launch == 4)                           // the bar after the pre-roll
        tick(store, to: 3, engine)                     // the take starts at the arm beat
        #expect(store.loopDeck!.cycleBeats == nil)     // still unknown mid-pass

        // Finished 7.6 beats after the window opened — nearly two bars. Rounds
        // to 8, and the pass runs on to the length it just defined.
        engine.playheadHandler?(11.6)
        _ = try store.finishLoopLayer()
        #expect(store.loopDeck!.cycleBeats == 8)
        #expect(store.loopDeck!.pending!.closeBeat == 12)
        tick(store, to: 12, engine)
        // One note played on beat 2 of the layer: captured at absolute 5, and
        // the take began at 3.
        engine.landLayer(notes: [MIDINote(pitch: 60, startBeat: 2, lengthBeats: 1)])
        #expect(store.loopDeck!.layers[0].cycle.map(\.startBeat) == [1])
    }

    // MARK: Peel

    @Test("⭐⭐ PEEL REMOVES THE LAST LAYER AND ITS CLIP — and the transport never stops")
    func peelRemovesTheLastLayer() throws {
        let (store, engine, a, b) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        try recordLayer(store, engine, track: a, played: [(60, 0)], armAt: 0)
        try recordLayer(store, engine, track: b, played: [(40, 0)], armAt: 8)

        let stopsBefore = engine.stopPlaybackCalls
        let peel = try store.peelLoopLayer()
        #expect(peel.removedLayer)
        #expect(peel.trackID == b.id)
        #expect(store.loopDeck!.layers.count == 1)
        #expect(store.tracks.first { $0.id == b.id }!.clips.isEmpty)
        // Layer 1 is untouched and still on the timeline.
        #expect(store.tracks.first { $0.id == a.id }!.clips.count == 1)
        // ⭐ THE WHOLE POINT: the music kept running.
        #expect(store.transport.isPlaying)
        #expect(engine.stopPlaybackCalls == stopsBefore)
    }

    @Test("peeling an OVERDUB restores the cycle as it stood before that pass")
    func peelRestoresAnOverdub() throws {
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        try recordLayer(store, engine, track: a, played: [(60, 0)], armAt: 0)
        try recordLayer(store, engine, track: a, played: [(64, 1)], armAt: 8)
        #expect(store.loopDeck!.layers[0].cycle.count == 2)

        let peel = try store.peelLoopLayer()
        #expect(!peel.removedLayer)
        #expect(peel.remainingNotes == 1)
        #expect(store.loopDeck!.layers[0].cycle.map(\.pitch) == [60])
        // The clip still exists and now carries only the first pass.
        let clip = store.tracks.first { $0.id == a.id }!.clips[0]
        #expect(Set(clip.notes!.map(\.pitch)) == [60])
    }

    @Test("peel is MULTI-LEVEL — three bad passes take three presses")
    func peelIsMultiLevel() throws {
        let (store, engine, a, b) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        try recordLayer(store, engine, track: a, played: [(60, 0)], armAt: 0)
        try recordLayer(store, engine, track: a, played: [(64, 1)], armAt: 8)
        try recordLayer(store, engine, track: b, played: [(40, 0)], armAt: 16)

        #expect(try store.peelLoopLayer().removedLayer)          // layer 2 gone
        #expect(!(try store.peelLoopLayer().removedLayer))       // overdub undone
        #expect(try store.peelLoopLayer().removedLayer)          // layer 1 gone
        #expect(store.loopDeck!.layers.isEmpty)
        #expect(!store.loopDeckStatus!.canPeel)
        #expect(throws: ProjectError.self) { _ = try store.peelLoopLayer() }
    }

    // MARK: The endings nobody asks for

    @Test("a pass that captured NOTHING inside the window leaves no ghost lamp")
    func anEmptyPassRemovesItsLayer() throws {
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        engine.playheadHandler?(0)
        _ = try store.armLoopLayer(trackID: a.id)      // launch 4, arm 3
        tick(store, to: 3, engine)
        engine.playheadHandler?(7.5)
        _ = try store.finishLoopLayer()
        tick(store, to: 8, engine)
        // Everything played landed in the PRE-ROLL (absolute 3.1), before the
        // window opened at 4.
        engine.landLayer(notes: [MIDINote(pitch: 60, startBeat: 0.1, lengthBeats: 0.2)])

        #expect(store.loopDeck!.layers.isEmpty)
        #expect(store.loopDeck!.pending == nil)
        #expect(store.tracks.first { $0.id == a.id }!.clips.isEmpty)
        #expect(store.lastRecordingError?.contains("empty loop layer") == true)
        // ...and the deck is armable again rather than wedged.
        engine.playheadHandler?(8)
        _ = try store.armLoopLayer(trackID: a.id)
    }

    @Test("a FAILED take unwinds the pass instead of wedging the deck")
    func aFailedTakeUnwindsThePass() throws {
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        engine.playheadHandler?(0)
        _ = try store.armLoopLayer(trackID: a.id)
        tick(store, to: 3, engine)
        engine.playheadHandler?(7.5)
        _ = try store.finishLoopLayer()
        tick(store, to: 8, engine)
        engine.failLayer(ProjectError.recordingFailed("input died"))

        #expect(store.loopDeck!.pending == nil)
        #expect(store.loopDeck!.layers.isEmpty)
        engine.playheadHandler?(8)
        _ = try store.armLoopLayer(trackID: a.id)   // armable again
    }

    @Test("stop() cancels a QUEUED layer — nothing ticks while stopped, so it would wait forever")
    func stopCancelsAQueuedLayer() throws {
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        _ = try store.armLoopLayer(trackID: a.id)
        #expect(store.loopDeck!.pending?.phase == .queued)
        store.stop()
        #expect(store.loopDeck!.pending == nil)
        #expect(store.loopDeck != nil)              // the SESSION survives a stop
        #expect(engine.layerStarts == 0)
    }

    @Test("a stale completion — the deck moved on while the take was in flight — lands nothing")
    func aStaleCompletionLandsNothing() throws {
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        engine.playheadHandler?(0)
        _ = try store.armLoopLayer(trackID: a.id)
        tick(store, to: 3, engine)
        engine.playheadHandler?(7.5)
        _ = try store.finishLoopLayer()
        tick(store, to: 8, engine)
        // The performer ended the session before the writer delivered.
        try store.endLoopDeck()
        engine.landLayer(notes: [MIDINote(pitch: 60, startBeat: 1, lengthBeats: 1)])
        #expect(store.loopDeck == nil)
        #expect(store.tracks.first { $0.id == a.id }!.clips.isEmpty)
    }

    @Test("a project boundary drops the session — its layers point at a project that is gone")
    func aProjectBoundaryDropsTheDeck() throws {
        let (store, _, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        _ = try store.armLoopLayer(trackID: a.id)
        store.stop()
        try store.newProject()
        #expect(store.loopDeck == nil)
    }

    // MARK: Muting

    @Test("muting a layer silences its clip without losing the material")
    func mutingKeepsTheMaterial() throws {
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1)
        try recordLayer(store, engine, track: a, played: [(60, 0)], armAt: 0)
        let layerID = store.loopDeck!.layers[0].id

        _ = try store.setLoopLayerMuted(layerID: layerID, muted: true)
        #expect(store.tracks.first { $0.id == a.id }!.clips[0].notes!.isEmpty)
        #expect(store.loopDeckStatus!.lamps[0].state == .muted)
        // The cycle itself is untouched, so unmuting restores it exactly.
        #expect(store.loopDeck!.layers[0].cycle.count == 1)

        _ = try store.setLoopLayerMuted(layerID: layerID, muted: false)
        #expect(!store.tracks.first { $0.id == a.id }!.clips[0].notes!.isEmpty)
        #expect(store.loopDeckStatus!.lamps[0].state == .playing)
    }

    // MARK: Runway

    @Test("⭐ THE RUNWAY EXTENDS AS THE PLAYHEAD APPROACHES THE END OF THE MATERIAL")
    func theRunwayExtends() throws {
        let (store, engine, a, _) = rolling(at: 0)
        _ = try store.beginLoopDeck(bars: 1, horizonCycles: 4)
        try recordLayer(store, engine, track: a, played: [(60, 0)], armAt: 0)
        // Landed in cycle 1 (playhead 8, origin 4) with a 4-cycle horizon.
        let span = store.loopDeck!.spanCycles
        #expect(span == 5)
        let lengthBefore = store.tracks.first { $0.id == a.id }!.clips[0].lengthBeats

        // Run to two cycles from the end.
        tick(store, to: 4 + 3 * 4.0, engine)
        #expect(store.loopDeck!.spanCycles == 7)
        let lengthAfter = store.tracks.first { $0.id == a.id }!.clips[0].lengthBeats
        #expect(lengthAfter > lengthBefore)
        // And the clip really carries the extra cycles' notes.
        #expect(store.tracks.first { $0.id == a.id }!.clips[0].notes!.count == 7)
    }
}
