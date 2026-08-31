import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-ct LIVE PLAY, against the **REAL `AudioEngine`** with a real rolling
/// take. This suite exists because `AudioEngineControlling.setLivePlayPitches`
/// ships with a SILENT DEFAULT: a fake conformer that never captured anything
/// would pass every DAWCore test, and the symptom in the product would not be
/// an error — it would be a performance the user played, heard, and then found
/// missing from the take. `previewController`'s header documents the same
/// vacuity hazard; this is its closure for the capture path.
///
/// ⭐ **THE MEASUREMENT IS THE FINISHED TAKE, NOT THE RETURN VALUE.** A setter's
/// return is not proof it took, so every assertion below reads the notes
/// `MIDICaptureSession.finish` actually produced. `capturedEdges` is checked
/// only alongside that independent read.
///
/// ⚠️ CoreMIDI is SYSTEM-GLOBAL: another suite's virtual-source traffic can land
/// in this capture session, so every assertion filters to sentinel pitches
/// 101-105, which no other suite here sends (`LoopRecordEngineTests` uses 113).
@MainActor
@Suite("Live play capture — real engine (m23-ct)", .serialized)
struct LivePlayCaptureTests {

    /// Collects one take completion (the no-writer MIDI path completes
    /// synchronously inside `stopRecording`).
    @MainActor
    private final class TakeBox {
        var result: Result<TakeResult, Error>?
    }

    /// A prepared engine with one instrument track and a rolling MIDI-only
    /// take, or nil on a machine with no output device (the headless-skip idiom
    /// this tree already uses in `LoopRecordEngineTests`).
    ///
    /// ⚠️ **THE SETTLE CALLERS DO IS NOT PADDING — IT IS REAL, MEASURED
    /// BEHAVIOUR.** A take's `PlaybackAnchor` is scheduled slightly AHEAD of
    /// `startTake` (hardware latency), and `MIDICaptureSession` DROPS every
    /// note-on whose beat is before the anchor — the same rule that makes
    /// count-in work. Measured here: without the settle the first chord
    /// (pressed at t≈0) vanished while a note pressed 120 ms later landed at
    /// beat 0.103. A note played in the first ~70 ms of a take is genuinely
    /// pre-anchor and genuinely dropped, for hardware and typing alike. The
    /// wait puts the fixture past the anchor instead of hiding the rule.
    private func rollingTake() throws -> (AudioEngine, Track, TakeBox)? {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return nil  // headless machine without an output device
        }
        let track = Track(name: "Keys", kind: .instrument)
        engine.tracksDidChange([track])
        var transport = TransportState()
        transport.positionBeats = 0
        // ⚠️ EXPLICIT, not inherited (m23-cy): the project default is now ONE
        // bar of count-in, which delays the take anchor by 2.0 s at 120 BPM —
        // six times `settlePastAnchor`'s 300 ms wait, so every note in this
        // suite would land pre-anchor and be dropped. This suite is about the
        // ~70 ms hardware lead, NOT about count-in, so it says 0 out loud
        // rather than depending on a default that just moved under it.
        transport.countInBars = 0
        let box = TakeBox()
        try engine.startTake(transport, audioURL: nil, captureMIDI: true) { box.result = $0 }
        return (engine, track, box)
    }

    /// Waits past the take anchor (see `rollingTake`).
    private func settlePastAnchor() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// The notes the session actually produced, filtered to this suite's
    /// sentinel range.
    private func sentinelNotes(_ box: TakeBox) throws -> [MIDINote] {
        try sentinelTake(box).notes
    }

    /// The sentinel notes PLUS the take's own clip-relative length.
    ///
    /// ⭐ **THE LENGTH IS THE ONLY HONEST YARDSTICK FOR "WAS THIS NOTE CLAMPED".**
    /// `MIDICaptureSession.finish` clamps every still-open note to the stop
    /// beat, so a clamped note ends at `lengthBeats` (which is that stop beat,
    /// rounded up). Comparing against it is exact and needs no knowledge of the
    /// take anchor's absolute beat.
    ///
    /// ⚠️ **IT REPLACED AN ABSOLUTE MILLISECOND BOUND, WHICH WAS A FLAKE.** The
    /// first draft asserted `lengthBeats < 0.55` for a note held ~150 ms.
    /// MEASURED under a full 7 000-test run: that same 150 ms sleep took 600 ms
    /// of wall clock (and elsewhere in the suite a 200 ms sleep produced a
    /// 7.5-beat note), so the bound went red while the property it was trying to
    /// express — "closed at the loss, not clamped at the end" — was still true.
    /// A wall-clock UPPER bound is an assumption about the scheduler; a
    /// comparison against the take's own end is a fact about the take.
    private func sentinelTake(_ box: TakeBox) throws -> (notes: [MIDINote], lengthBeats: Double) {
        let take = try #require(box.result).get()
        let midi = try #require(take.midi)
        return (midi.notes.filter { (101...105).contains($0.pitch) }, midi.lengthBeats)
    }

    // MARK: - The core edge contract

    @Test("an on then an off ingests exactly 2 edges — one paired note in the take")
    func onThenOffIngestsTwoEdges() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        // A session must EXIST, or every assertion below would pass vacuously
        // on an empty take. Loud, not skipped.
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        let on = engine.setLivePlayPitches(trackID: track.id, pitches: [101], velocity: 96,
                                           captureIntoTake: true)
        #expect(on.capturedEdges == 1)
        #expect(on.recording)                 // THE HONESTY LIGHT is on
        #expect(on.audition != .noRenderer && on.audition != .unsupported)

        try await Task.sleep(for: .milliseconds(200))

        let off = engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                            captureIntoTake: true)
        #expect(off.capturedEdges == 1)
        engine.stopRecording()

        let notes = try sentinelNotes(box)
        print("[measured] m23-ct on/off: \(notes.map { ($0.pitch, $0.startBeat, $0.lengthBeats) })")
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.pitch == 101)
        #expect(note.velocity == 96)
        #expect(note.lengthBeats > 0.05)      // ~0.4 beats at 120 BPM for 200 ms
    }

    @Test("⭐ an UNCHANGED set ingests 0 — the heartbeat pin: a held key is ONE note, not one per beat")
    func unchangedSetIngestsNothing() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        engine.setLivePlayPitches(trackID: track.id, pitches: [102], velocity: 100,
                                  captureIntoTake: true)
        // Six heartbeats — what a 3-second held key produces at 500 ms.
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(30))
            let beat = engine.setLivePlayPitches(trackID: track.id, pitches: [102],
                                                 velocity: 100, captureIntoTake: true)
            #expect(beat.capturedEdges == 0)
            #expect(beat.recording)
        }
        engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                  captureIntoTake: true)
        engine.stopRecording()

        let notes = try sentinelNotes(box)
        print("[measured] m23-ct heartbeat: \(notes.map { ($0.pitch, $0.lengthBeats) })")
        #expect(notes.count == 1)   // not 7
        #expect(notes.first?.pitch == 102)
    }

    @Test("captureIntoTake:false ingests 0 and reports recording:false — heard, in no take")
    func captureIntoTakeFalseIngestsNothing() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        let on = engine.setLivePlayPitches(trackID: track.id, pitches: [103], velocity: 100,
                                           captureIntoTake: false)
        #expect(on.capturedEdges == 0)
        #expect(!on.recording)
        // …but it WAS delivered to the speakers. Not capturing is not silence.
        #expect(on.audition != .noRenderer && on.audition != .unsupported)

        try await Task.sleep(for: .milliseconds(120))
        engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                  captureIntoTake: false)
        engine.stopRecording()

        #expect(try sentinelNotes(box).isEmpty)
    }

    @Test("no rolling take ⇒ recording:false, 0 edges, and the notes still SOUND")
    func noSessionMeansNotRecording() throws {
        let engine = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument)
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))

        let outcome = engine.setLivePlayPitches(trackID: track.id, pitches: [104], velocity: 100,
                                                captureIntoTake: true)

        #expect(!outcome.recording)
        #expect(outcome.capturedEdges == 0)
        // The audible half is untouched by the absence of a take.
        var events: [LiveMIDIEvent] = []
        while let event = renderer.auditionRing.pop() { events.append(event) }
        #expect(events.count == 1)
        #expect(events[0].kind == ScheduledMIDIEvent.noteOn && events[0].pitch == 104)
    }

    // MARK: - The distinction the whole design rests on

    @Test("⚠️ a mid-hold RENDERER REBUILD ingests 0 — a graph rebuild is not a performance")
    func rendererRebuildMidHoldIngestsNothing() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()
        let original = try #require(engine.graph.instrumentRenderer(forTrack: track.id))

        engine.setLivePlayPitches(trackID: track.id, pitches: [105], velocity: 100,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(120))

        // An instrument change rebuilds the node — a DIFFERENT renderer object.
        engine.graph.invalidateInstrumentNode(trackID: track.id)
        engine.tracksDidChange([track])
        let rebuilt = try #require(engine.graph.instrumentRenderer(forTrack: track.id))
        #expect(rebuilt !== original)

        // The next heartbeat crosses the rebuild. `setAuditionPitches` releases
        // the whole held set on the OLD object and re-triggers it on the NEW
        // one — real ring pushes, and they must NOT reach the take: the user
        // did not lift and re-press the key. The LEDGER diff is empty, and the
        // ledger is what live play reads.
        let across = engine.setLivePlayPitches(trackID: track.id, pitches: [105], velocity: 100,
                                               captureIntoTake: true)
        #expect(across.capturedEdges == 0)
        var oldEvents: [LiveMIDIEvent] = []
        while let event = original.auditionRing.pop() { oldEvents.append(event) }
        var newEvents: [LiveMIDIEvent] = []
        while let event = rebuilt.auditionRing.pop() { newEvents.append(event) }
        // The rebuild really did push — this is the positive control that makes
        // `capturedEdges == 0` evidence rather than an empty probe.
        #expect(oldEvents.contains { $0.kind == ScheduledMIDIEvent.noteOff && $0.pitch == 105 })
        #expect(newEvents.contains { $0.kind == ScheduledMIDIEvent.noteOn && $0.pitch == 105 })

        try await Task.sleep(for: .milliseconds(120))
        engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                  captureIntoTake: true)
        engine.stopRecording()

        let notes = try sentinelNotes(box)
        print("[measured] m23-ct rebuild: \(notes.map { ($0.pitch, $0.startBeat, $0.lengthBeats) })")
        #expect(notes.count == 1)   // ONE note across the rebuild, not two
        #expect(notes.first?.pitch == 105)
    }

    @Test("a LOST renderer closes the take's note and opens none — recording:false, no clamped tail")
    func lostRendererClosesTheNoteAndOpensNone() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        engine.setLivePlayPitches(trackID: track.id, pitches: [101], velocity: 100,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(150))

        engine.tracksDidChange([])   // the track is gone: nothing can be delivered
        let lost = engine.setLivePlayPitches(trackID: track.id, pitches: [101], velocity: 100,
                                             captureIntoTake: true)

        // The audible half released EVERYTHING it held and dropped the ledger
        // entry, so the take sees the same release — and NO on, which no later
        // off could have closed (the ledger those offs come from is now empty).
        // Without this branch the note would clamp to the end of the take.
        #expect(lost.audition == .noRenderer)
        #expect(lost.capturedEdges == 1)
        #expect(!lost.recording)

        // Comfortably more than one beat of daylight between the loss and the
        // stop, so the clamp test below cannot be defeated by rounding.
        try await Task.sleep(for: .milliseconds(700))
        engine.stopRecording()

        let (notes, takeLength) = try sentinelTake(box)
        print("[measured] m23-ct lost renderer: take \(takeLength) beats, "
              + "\(notes.map { ($0.pitch, $0.startBeat, $0.endBeat) })")
        #expect(notes.count == 1)
        // Closed AT THE LOSS, not clamped at the take's end. A clamped note ends
        // AT the stop beat, so `lengthBeats` (that beat, rounded up) minus the
        // note's end is < 1 for a clamp and > 1 here. Scheduler-independent: the
        // 700 ms gap can only grow under load, never shrink.
        let note = try #require(notes.first)
        #expect(takeLength - note.endBeat > 1.0)
    }

    @Test("note-OFFs ride the take even when captureIntoTake has gone false (a disarm mid-hold)")
    func offsIngestEvenWhenTheVerdictFlipped() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        engine.setLivePlayPitches(trackID: track.id, pitches: [102], velocity: 100,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(150))

        // The domain verdict has flipped (the track was disarmed mid-hold). The
        // OFF gate is deliberately wider than the ON gate: an off can only
        // CLOSE a note (the session drops orphan offs), and refusing it here
        // would leave the note to clamp at the END of the take — a duration the
        // user never played, landing on every other armed instrument track.
        let off = engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                            captureIntoTake: false)
        #expect(off.capturedEdges == 1)
        #expect(!off.recording)

        try await Task.sleep(for: .milliseconds(700))
        engine.stopRecording()

        let (notes, takeLength) = try sentinelTake(box)
        print("[measured] m23-ct disarm mid-hold: take \(takeLength) beats, "
              + "\(notes.map { ($0.pitch, $0.startBeat, $0.endBeat) })")
        #expect(notes.count == 1)
        // Closed by the off, NOT clamped at the take's end — the whole reason
        // the off gate is wider than the on gate. Measured against the take's
        // own end rather than a wall-clock bound (see `sentinelTake`).
        #expect(takeLength - (try #require(notes.first).endBeat) > 1.0)
    }

    @Test("POSITIVE CONTROL for the two clamp tests: a NEVER-released note DOES clamp at the take's end")
    func aNeverReleasedNoteClamps() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        engine.setLivePlayPitches(trackID: track.id, pitches: [104], velocity: 100,
                                  captureIntoTake: true)
        // Deliberately NO release, and a long tail — the exact failure the two
        // clamp tests exist to exclude.
        try await Task.sleep(for: .milliseconds(700))
        engine.stopRecording()

        let (notes, takeLength) = try sentinelTake(box)
        print("[measured] m23-ct clamp control: take \(takeLength) beats, "
              + "\(notes.map { ($0.pitch, $0.startBeat, $0.endBeat) })")
        #expect(notes.count == 1)
        // ⭐ WITHOUT THIS TEST the `> 1.0` threshold in the two clamp tests would
        // be an untested bound, and a probe that has never found anything is the
        // weakest evidence there is. A clamped note ends AT the stop beat, so
        // `lengthBeats` (that beat, rounded up) minus its end is always < 1 —
        // the SAME expression the other two require to be > 1. The threshold is
        // therefore exact, not empirical: clamped ⇒ < 1 always; released with
        // ≥ 1.4 beats of daylight ⇒ > 1 always.
        let note = try #require(notes.first)
        #expect(takeLength - note.endBeat < 1.0)
    }

    @Test("a chord ingests one edge per pitch, and the take pairs them all")
    func chordIngestsOneEdgePerPitch() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        let on = engine.setLivePlayPitches(trackID: track.id, pitches: [101, 103, 105],
                                           velocity: 100, captureIntoTake: true)
        #expect(on.capturedEdges == 3)
        try await Task.sleep(for: .milliseconds(120))

        // Lift one finger, add another: one off + one on, never a re-trigger of
        // the two that stayed down.
        let moved = engine.setLivePlayPitches(trackID: track.id, pitches: [101, 104, 105],
                                              velocity: 100, captureIntoTake: true)
        #expect(moved.capturedEdges == 2)
        try await Task.sleep(for: .milliseconds(120))

        let released = engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                                 captureIntoTake: true)
        #expect(released.capturedEdges == 3)
        engine.stopRecording()

        let notes = try sentinelNotes(box)
        print("[measured] m23-ct chord: \(notes.map { ($0.pitch, $0.startBeat, $0.lengthBeats) })")
        #expect(notes.count == 4)
        #expect(notes.map(\.pitch).sorted() == [101, 103, 104, 105])
        // 101 and 105 were held straight through both calls: ONE long note each.
        let held = notes.filter { $0.pitch == 101 || $0.pitch == 105 }
        #expect(held.count == 2)
        let shortNote = try #require(notes.first { $0.pitch == 103 })
        #expect(held.allSatisfy { $0.lengthBeats > shortNote.lengthBeats })
    }

    // ═══════════════════════════════════════════════════════════════════════
    // m34-f step ② — LIVE EXPRESSION capture, against the same REAL engine.
    //
    // ⚠️ **A STRUCTURAL FOLD, NOT A TOPICAL MERGE**, and the reason is written
    // here rather than left to be re-derived: `MainActorOccupancySiteTests`
    // Leg C caps this tree's `@MainActor` `@Suite` count, and the tree is AT
    // the cap — measured, by this very item, which added a suite of its own
    // and pushed it to 370 against a bound of 369. Raising the bound to fit a
    // new suite would be raising the thing it measures. The same fold
    // `HumanizeModelTests` performs for `BreathPadModel`.
    //
    // The fold is a good fit rather than merely a legal one: these tests need
    // exactly this suite's fixture (a REAL `AudioEngine` with a rolling
    // MIDI-only take, past the anchor), and a separate suite duplicated
    // `rollingTake`, `TakeBox` and `settlePastAnchor` verbatim to get it.
    //
    // ⛔⛔ **THEY EXIST FOR THE SAME REASON THE NOTE TESTS ABOVE DO, ONE AXIS
    // OVER, AND THE DEFAULT THEY GUARD IS MORE DANGEROUS.**
    // `AudioEngineControlling.setLiveExpression` ships with a default that
    // FORWARDS to `previewController` and captures nothing — chosen so every
    // existing fake keeps SOUNDING, and therefore the one default in the family
    // whose failure is inaudible. A real engine that forgot to override it
    // would sound perfect, report a plausible `AuditionOutcome`, and record
    // nothing, while every DAWCore test stayed green because
    // `PadPreviewController` is written to keep working against an engine that
    // cannot capture.
    //
    // ⚠️ SENTINEL CONTROLLER: CC 102, in the MIDI 1.0 "undefined" block, which
    // no other suite here sends and no hardware default maps to — the
    // sentinel-pitch discipline above, applied to a controller. CC 11 is
    // asserted separately only where the DEFAULT ITSELF is the claim.
    // ═══════════════════════════════════════════════════════════════════════

    private static let sentinelCC = 102

    private func expressionLane(_ box: TakeBox, controller: Int) throws -> MIDIControllerLane? {
        let take = try #require(box.result).get()
        let midi = try #require(take.midi)
        return midi.controllerLanes.first { $0.type == .cc(controller: controller) }
    }

    // MARK: - The vacuity closer

    @Test("⛔ THE REAL ENGINE ACTUALLY CAPTURES — a performed value reaches the finished take's lane")
    func theRealEngineIngestsAControllerPoint() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        // A session must EXIST, or every assertion below would pass vacuously on
        // an empty take. Loud, not skipped.
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        let pushed = engine.setLiveExpression(trackID: track.id,
                                              controller: UInt8(Self.sentinelCC),
                                              value: 40, captureIntoTake: true)
        #expect(pushed.capturedPoints == 1)
        #expect(pushed.recording, "THE HONESTY LIGHT must be on when the take really received it")
        #expect(pushed.audition != .noRenderer && pushed.audition != .unsupported)

        engine.stopRecording()

        let recorded = try #require(try expressionLane(box, controller: Self.sentinelCC),
                                    "the take must carry a CC \(Self.sentinelCC) lane")
        print("[measured] m34-f ingest: \(recorded.points.map { ($0.beat, $0.value) })")
        #expect(recorded.points.contains { $0.value == 40 })
    }

    @Test("⚠️ THE PACKING PIN: the controller NUMBER and the DATA BYTE are not swapped")
    func theEventPackingIsNotSwapped() async throws {
        // ⛔ A SWAP IS THE ONE DEFECT A POINT-COUNTING TEST CANNOT SEE.
        // `MIDICaptureSession.ingestController` reads the CC number out of
        // `pitch` and the value out of `velocity`; reversing them still produces
        // a lane with the right number of points, at the right beats, and every
        // "did it record" assertion still passes — the lane is simply the wrong
        // controller carrying the wrong numbers. The two are chosen DISTINCT and
        // both in 0…127 so a swap cannot hide behind a clamp.
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        engine.setLiveExpression(trackID: track.id, controller: UInt8(Self.sentinelCC),
                                 value: 7, captureIntoTake: true)
        engine.stopRecording()

        let onTheRightLane = try expressionLane(box, controller: Self.sentinelCC)
        let onTheSwappedLane = try expressionLane(box, controller: 7)
        #expect(onTheRightLane != nil, "the lane must be CC \(Self.sentinelCC), the controller")
        #expect(onTheSwappedLane == nil, "a lane at CC 7 means number and value were swapped")
        #expect(onTheRightLane?.points.contains { $0.value == 7 } == true)
    }

    @Test("the DEFAULT controller really is CC 11 end to end, not only in a constant")
    func theDefaultLaneIsExpression() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        engine.setLiveExpression(
            trackID: track.id,
            controller: UInt8(PadPreviewController.defaultExpressionCC),
            value: 64, captureIntoTake: true)
        engine.stopRecording()

        #expect(try expressionLane(box, controller: 11) != nil,
                "the pad's default must land on the expression lane BreathContour writes")
    }

    // MARK: - The gate

    @Test("captureIntoTake:false SOUNDS and records NOTHING — the preview contract, at the engine")
    func theCaptureGateIsRespected() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        let previewed = engine.setLiveExpression(trackID: track.id,
                                                 controller: UInt8(Self.sentinelCC),
                                                 value: 90, captureIntoTake: false)
        #expect(previewed.capturedPoints == 0)
        #expect(previewed.recording == false)
        // It still SOUNDED — a preview is heard, it is simply not kept.
        #expect(previewed.audition != .noRenderer && previewed.audition != .unsupported)
        engine.stopRecording()

        #expect(try expressionLane(box, controller: Self.sentinelCC) == nil,
                "a preview must leave NO lane in the take")
    }

    @Test("a value the engine could not deliver captures nothing — a take never contains what never sounded")
    func anUndeliveredValueIsNotCaptured() async throws {
        guard let (engine, _, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        // A track the engine has never heard of has no renderer.
        let ghost = engine.setLiveExpression(trackID: UUID(),
                                             controller: UInt8(Self.sentinelCC),
                                             value: 55, captureIntoTake: true)
        #expect(ghost.audition == .noRenderer)
        #expect(ghost.capturedPoints == 0)
        #expect(ghost.recording == false)
        engine.stopRecording()
        #expect(try expressionLane(box, controller: Self.sentinelCC) == nil)
    }

    // MARK: - The strip filter must not gate the take

    @Test("⛔ A REPEATED VALUE THE STRIP ALREADY HOLDS IS STILL CAPTURED — the filters are decoupled")
    func theStripStateFilterDoesNotSuppressCapture() async throws {
        // `previewController` suppresses a push whose (controller, value) is
        // already parked on the SAME renderer — a correct optimisation for the
        // strip and a wrong one for a take. A value the strip already holds is
        // still a value the user is performing at this instant, and the
        // session's own thinning is what decides whether it is worth a point.
        // Coupling them would let a strip coincidence silently delete a take
        // point.
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        for _ in 0..<4 {
            let repeated = engine.setLiveExpression(trackID: track.id,
                                                    controller: UInt8(Self.sentinelCC),
                                                    value: 33, captureIntoTake: true)
            #expect(repeated.capturedPoints == 1,
                    "the engine must OFFER every push to the take, even one the strip ignores")
            try await Task.sleep(for: .milliseconds(40))
        }
        engine.stopRecording()

        let recorded = try #require(try expressionLane(box, controller: Self.sentinelCC))
        print("[measured] m34-f repeats: \(recorded.points.map { ($0.beat, $0.value) })")
        // ⚠️ THE LANE ITSELF IS THINNED, AND THAT IS THE RIGHT LAYER FOR IT.
        // `MIDICaptureSession`'s §7 duplicate-drop keeps one point for a run of
        // identical values, so four offered pushes become one stored point. The
        // assertion is therefore "the point exists", not "there are four" — the
        // engine's job is to OFFER, the session's job is to THIN.
        #expect(recorded.points.contains { $0.value == 33 })
    }

    // MARK: - A whole performed gesture

    @Test("a swell performed through the pad's own controller lands as a rising lane")
    func aPerformedSwellLandsAsARisingLane() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        let performed: [UInt8] = [10, 30, 60, 95, 120, 95, 60, 20]
        for value in performed {
            engine.setLiveExpression(trackID: track.id, controller: UInt8(Self.sentinelCC),
                                     value: value, captureIntoTake: true)
            try await Task.sleep(for: .milliseconds(40))
        }
        engine.stopRecording()

        let recorded = try #require(try expressionLane(box, controller: Self.sentinelCC))
        print("[measured] m34-f swell: \(recorded.points.map { ($0.beat, $0.value) })")
        // ⚠️ NOT AN EXACT POINT COUNT. The session's spacing law may coalesce
        // neighbours, and a wall-clock sleep is not a scheduler contract — an
        // exact count here would be a flake, which this tree has already paid
        // for once in `LivePlayCaptureTests`. What is asserted is the SHAPE: the
        // performance rose and fell, and the extremes survived.
        #expect(recorded.points.count >= 4)
        let values = recorded.points.map(\.value)
        #expect(values.max() ?? 0 >= 95, "the peak of the swell must be in the take")
        #expect(values.first ?? 127 < 60, "the take must start quiet, as performed")
        #expect(values.last ?? 127 < 60, "and end quiet")
        // Beats must ADVANCE — a lane whose points all sit at one beat would be
        // a stack, not a performance.
        #expect(Set(recorded.points.map(\.beat)).count == recorded.points.count)
    }
}
