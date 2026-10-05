import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m34-h LIVE LOOPING phase 1, against the **REAL `AudioEngine`**: close a take
/// and deliver its result WITHOUT tearing down playback, then record the next
/// layer on top without ever stopping.
///
/// ⭐ **THIS SUITE IS THE VACUITY CLOSURE FOR TWO SILENT PROTOCOL DEFAULTS.**
/// `AudioEngineControlling.finishTakeKeepingPlayback()` defaults to `false`
/// ("closed nothing") and `startTakeInPlayback` defaults to a throw. A real
/// engine that forgot to override either would still pass every DAWCore and
/// DAWControl test in the tree, because both callers are written to handle the
/// unsupported answer honestly. The symptom in the product would not be an
/// error — it would be a performance the user played and then could not find.
/// `previewController` and `setLivePlayPitches` document the same hazard; this
/// is its closure for the layering path.
///
/// ⭐ **THE MEASUREMENT IS THE FINISHED TAKE AND THE MOVING PLAYHEAD, NEVER THE
/// RETURN VALUE.** A setter's return is not proof it took: every "playback
/// survived" assertion below reads the playhead TWICE and requires it to have
/// advanced, and every "the take landed" assertion reads the notes
/// `MIDICaptureSession.finish` actually produced.
///
/// ⚠️ CoreMIDI is SYSTEM-GLOBAL: another suite's virtual-source traffic can land
/// in this capture session, so every assertion filters to sentinel pitches
/// 90-95, which no other suite here sends (`LivePlayCaptureTests` uses 101-105,
/// `LoopRecordEngineTests` uses 113).
@MainActor
@Suite("Live layer capture — real engine (m34-h)", .serialized)
struct LiveLayerCaptureTests {

    /// Collects one take completion. A MIDI-only take has no writer, so its
    /// completion fires synchronously inside the close.
    @MainActor
    private final class TakeBox {
        var result: Result<TakeResult, Error>?
    }

    /// A prepared engine with one instrument track and a rolling MIDI-only
    /// take, or nil on a machine with no output device (the headless-skip idiom
    /// `LoopRecordEngineTests` and `LivePlayCaptureTests` already use).
    ///
    /// ⚠️ `countInBars = 0` is EXPLICIT, not inherited (m23-cy): the project
    /// default is one bar, which delays the take anchor by 2.0 s at 120 BPM —
    /// six times `settlePastAnchor`'s wait, so every note would land pre-anchor
    /// and drop. This suite is about layering, not count-in.
    private func rollingTake() throws -> (AudioEngine, Track, TakeBox)? {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return nil  // headless machine without an output device
        }
        let track = Track(name: "Layer", kind: .instrument)
        engine.tracksDidChange([track])
        var transport = TransportState()
        transport.positionBeats = 0
        transport.countInBars = 0
        let box = TakeBox()
        try engine.startTake(transport, audioURL: nil, captureMIDI: true) { box.result = $0 }
        return (engine, track, box)
    }

    /// Waits past the take anchor. See `LivePlayCaptureTests.settlePastAnchor`
    /// for the measurement behind the 300 ms: a note played in the first ~70 ms
    /// of a take is genuinely pre-anchor and genuinely dropped.
    private func settlePastAnchor() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func sentinelNotes(_ box: TakeBox) throws -> [MIDINote] {
        let take = try #require(box.result).get()
        let midi = try #require(take.midi)
        return midi.notes.filter { (90...95).contains($0.pitch) }
    }

    /// A transport carrying the engine's own live beat — what `ProjectStore`
    /// hands `startTakeInPlayback` for a layer.
    private func layerTransport(_ engine: AudioEngine) -> TransportState {
        var transport = TransportState()
        transport.positionBeats = engine.derivedLinearBeats()
        transport.countInBars = 0
        return transport
    }

    // MARK: - The primitive itself

    @Test("⭐ THE ITEM: the real engine closes a take and KEEPS PLAYING — playhead advances past the close")
    func closingATakeLeavesPlaybackRunning() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        #expect(engine.midiCaptureSessionForTesting != nil)
        await settlePastAnchor()

        engine.setLivePlayPitches(trackID: track.id, pitches: [90], velocity: 96,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(200))
        engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                  captureIntoTake: true)

        let beatBeforeClose = engine.derivedLinearBeats()

        // ⭐ THE VACUITY CLOSURE. The protocol default is `false`; a real engine
        // that never overrode this would return `false` here and every
        // assertion below would be measuring a stopped transport.
        let closed = engine.finishTakeKeepingPlayback()
        #expect(closed, "the REAL AudioEngine must implement the keep-playing close: a false here is the AudioEngineControlling default leaking through")

        // State: the transport is still rolling and the take is gone.
        #expect(engine.transportRollingForTesting,
                "the close must NOT tear down playback — currentAnchor survived?")
        #expect(engine.activeTakeKeepsPlaybackForTesting == nil, "the take must be closed")

        // ⭐ BEHAVIOUR, not just state: the playhead has to actually MOVE. A
        // stopped transport keeps reporting `lastKnownBeats` forever, so a
        // frozen-but-non-nil anchor would pass the state check above and fail
        // this one. Two reads, a real wait between them.
        try await Task.sleep(for: .milliseconds(400))
        let beatAfterClose = engine.derivedLinearBeats()
        print("[measured] m34-h close: beat \(beatBeforeClose) -> \(beatAfterClose)")
        #expect(beatAfterClose > beatBeforeClose,
                "the playhead must ADVANCE past the close — got \(beatBeforeClose) -> \(beatAfterClose)")

        // And the take landed, through the ordinary completion.
        let notes = try sentinelNotes(box)
        #expect(notes.count == 1)
        #expect(notes.first?.pitch == 90)
        #expect((notes.first?.lengthBeats ?? 0) > 0.05)
    }

    @Test("stopRecording still stops playback — the sibling is additive, the original is untouched")
    func stopRecordingStillStopsPlayback() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        await settlePastAnchor()
        engine.setLivePlayPitches(trackID: track.id, pitches: [91], velocity: 96,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(150))

        #expect(engine.transportRollingForTesting)
        engine.stopRecording()
        // The whole point of the m34-h sibling is that THIS behaviour did not
        // change. If this ever goes green-by-accident the additive claim is
        // false and every existing caller of stopRecording has been altered.
        #expect(!engine.transportRollingForTesting,
                "stopRecording must STILL stop playback — m34-h is additive")
        _ = try? sentinelNotes(box)
    }

    @Test("a note held across the close clamps to the close beat — identical to the stop path")
    func heldNoteClampsOnTheKeepPlayingClose() async throws {
        // ⭐ A TWO-ARM COMPARISON, because "the clamp is right" is only
        // meaningful against the path it must match. Both arms hold a note and
        // never release it; the clamped note must end at the take's own length
        // on BOTH, which is the only yardstick that needs no knowledge of the
        // anchor's absolute beat (LivePlayCaptureTests' own finding).
        func heldNoteTake(closeKeepingPlayback: Bool) async throws -> (length: Double, note: MIDINote)? {
            guard let (engine, track, box) = try rollingTake() else { return nil }
            defer { engine.shutdown() }
            await settlePastAnchor()
            engine.setLivePlayPitches(trackID: track.id, pitches: [92], velocity: 100,
                                      captureIntoTake: true)
            try await Task.sleep(for: .milliseconds(250))
            if closeKeepingPlayback {
                #expect(engine.finishTakeKeepingPlayback())
            } else {
                engine.stopRecording()
            }
            let take = try #require(box.result).get()
            let midi = try #require(take.midi)
            guard let note = midi.notes.first(where: { $0.pitch == 92 }) else { return nil }
            return (midi.lengthBeats, note)
        }

        guard let stopArm = try await heldNoteTake(closeKeepingPlayback: false) else { return }
        guard let keepArm = try await heldNoteTake(closeKeepingPlayback: true) else { return }
        print("[measured] m34-h clamp: stop-path end=\(stopArm.note.endBeat)/len=\(stopArm.length), "
            + "keep-path end=\(keepArm.note.endBeat)/len=\(keepArm.length)")

        // The clamp property, on both arms: the held note ends AT the take's own
        // end, not before it and not unbounded past it.
        for (name, arm) in [("stop", stopArm), ("keep-playing", keepArm)] {
            #expect(arm.note.lengthBeats >= MIDINote.minLengthBeats,
                    "\(name) arm: a clamped note must not be degenerate")
            #expect(arm.note.endBeat <= arm.length + 0.001,
                    "\(name) arm: a clamped note must not run past the take end (\(arm.note.endBeat) vs \(arm.length))")
            #expect(arm.note.endBeat > arm.note.startBeat,
                    "\(name) arm: the clamped note must have real duration")
        }
    }

    // MARK: - Layer 2: recording again without ever stopping

    @Test("⭐ THE POINT OF THE ITEM: layer 2 records without stopping, and layer 1's notes are NOT in it")
    func secondLayerRecordsWithoutStopping() async throws {
        guard let (engine, track, box1) = try rollingTake() else { return }
        defer { engine.shutdown() }
        await settlePastAnchor()

        // --- layer 1 --------------------------------------------------------
        engine.setLivePlayPitches(trackID: track.id, pitches: [93], velocity: 96,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(200))
        engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                  captureIntoTake: true)
        let beatAtClose = engine.derivedLinearBeats()
        #expect(engine.finishTakeKeepingPlayback())
        #expect(engine.transportRollingForTesting)

        // --- layer 2, with NO stop and NO play in between --------------------
        let box2 = TakeBox()
        try engine.startTakeInPlayback(layerTransport(engine), audioURL: nil,
                                       captureMIDI: true) { box2.result = $0 }
        #expect(engine.activeTakeKeepsPlaybackForTesting == true,
                "a layer take must be marked keepsPlayback, so its FAILURE paths keep playing too")
        #expect(engine.midiCaptureSessionForTesting != nil,
                "layer 2 must get its own capture session")
        await settlePastAnchor()

        engine.setLivePlayPitches(trackID: track.id, pitches: [94], velocity: 100,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(200))
        engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                  captureIntoTake: true)
        let beatAtSecondClose = engine.derivedLinearBeats()
        #expect(engine.finishTakeKeepingPlayback())
        #expect(engine.transportRollingForTesting,
                "still playing after TWO layers — the transport was never stopped")

        // The music genuinely ran forward across both closes.
        print("[measured] m34-h two layers: close1 at \(beatAtClose), close2 at \(beatAtSecondClose)")
        #expect(beatAtSecondClose > beatAtClose)

        // ⭐ THE SEPARATION ASSERTION. Without it, a layer-2 take that somehow
        // reused layer 1's session would look identical to a correct one.
        let layer1 = try sentinelNotes(box1)
        let layer2 = try sentinelNotes(box2)
        print("[measured] m34-h layer1=\(layer1.map(\.pitch)) layer2=\(layer2.map(\.pitch))")
        #expect(layer1.map(\.pitch) == [93], "layer 1 holds only what was played into it")
        #expect(layer2.map(\.pitch) == [94], "layer 2 holds only what was played into it")
    }

    @Test("a layer take does NOT reschedule: it reuses the running anchor, so the playhead never jumps back")
    func layerTakeDoesNotRestartTheTransport() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        await settlePastAnchor()
        _ = track
        #expect(engine.finishTakeKeepingPlayback())

        // ⭐ THE ANTI-RESCHEDULE PIN, and it is the load-bearing property of the
        // whole feature. `startPlayers` re-anchors the transport at the
        // requested beat; if the layer path ever started calling it, the
        // playhead would visibly reset toward the requested beat instead of
        // continuing. Measuring "did not go backwards" across the start is the
        // observable consequence, and it needs no private state.
        let before = engine.derivedLinearBeats()
        let box2 = TakeBox()
        try engine.startTakeInPlayback(layerTransport(engine), audioURL: nil,
                                       captureMIDI: true) { box2.result = $0 }
        try await Task.sleep(for: .milliseconds(200))
        let after = engine.derivedLinearBeats()
        print("[measured] m34-h anti-reschedule: \(before) -> \(after)")
        #expect(after >= before,
                "a layer start must never move the playhead backwards — got \(before) -> \(after)")
        #expect(engine.transportRollingForTesting)
        _ = try? sentinelNotes(box)
    }

    @Test("count-in is INERT on the layer path — capture starts now, not one bar later")
    func countInDoesNotDelayALayer() async throws {
        guard let (engine, track, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        await settlePastAnchor()
        #expect(engine.finishTakeKeepingPlayback())

        // The project default is ONE BAR (m23-cy) = 2.0 s at 120 BPM. If the
        // layer path honoured it, the note below — played 300 ms in — would be
        // pre-anchor and dropped. Measured rather than left emergent, because
        // "ignored by design" and "ignored by accident" look identical.
        var transport = layerTransport(engine)
        transport.countInBars = 1
        let box2 = TakeBox()
        try engine.startTakeInPlayback(transport, audioURL: nil, captureMIDI: true) { box2.result = $0 }
        await settlePastAnchor()
        engine.setLivePlayPitches(trackID: track.id, pitches: [95], velocity: 100,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(200))
        engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                  captureIntoTake: true)
        #expect(engine.finishTakeKeepingPlayback())

        let notes = try sentinelNotes(box2)
        print("[measured] m34-h count-in inert: \(notes.map { ($0.pitch, $0.startBeat) })")
        #expect(notes.map(\.pitch) == [95],
                "a count-in must NOT delay a layer's anchor — the note was dropped as pre-anchor")
        _ = try? sentinelNotes(box)
    }

    // MARK: - Refusals (each one names a real hazard, not caution)

    @Test("startTakeInPlayback refuses when nothing is playing")
    func layerRefusesAStoppedTransport() throws {
        let engine = AudioEngine()
        do { try engine.prepare() } catch { return }
        defer { engine.shutdown() }
        engine.tracksDidChange([Track(name: "Layer", kind: .instrument)])
        #expect(!engine.transportRollingForTesting)
        #expect(throws: (any Error).self) {
            try engine.startTakeInPlayback(TransportState(), audioURL: nil,
                                           captureMIDI: true) { _ in }
        }
    }

    @Test("startTakeInPlayback refuses a second take while one is already rolling")
    func layerRefusesWhileAlreadyRecording() async throws {
        guard let (engine, _, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        await settlePastAnchor()
        #expect(throws: (any Error).self) {
            try engine.startTakeInPlayback(layerTransport(engine), audioURL: nil,
                                           captureMIDI: true) { _ in }
        }
        engine.stopRecording()
        _ = try? sentinelNotes(box)
    }

    @Test("⛔ startTakeInPlayback refuses while the LOOP is enabled — modular beats vs a linear capture clock")
    func layerRefusesUnderALoop() async throws {
        guard let (engine, _, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        await settlePastAnchor()
        #expect(engine.finishTakeKeepingPlayback())

        // The refusal is checked against the TRANSPORT FLAG as well as the live
        // schedule: a linear schedule with a loop merely ENABLED still wraps
        // through `restart(fromBeat: loopStartBeat)` at the loop end, which
        // replaces the anchor under a rolling take.
        var transport = layerTransport(engine)
        transport.isLoopEnabled = true
        transport.loopStartBeat = 0
        transport.loopEndBeat = 8
        #expect(throws: (any Error).self) {
            try engine.startTakeInPlayback(transport, audioURL: nil, captureMIDI: true) { _ in }
        }
        _ = try? sentinelNotes(box)
    }

    @Test("⛔ startTakeInPlayback refuses with a punch window enabled")
    func layerRefusesWithPunch() async throws {
        guard let (engine, _, box) = try rollingTake() else { return }
        defer { engine.shutdown() }
        await settlePastAnchor()
        #expect(engine.finishTakeKeepingPlayback())

        var transport = layerTransport(engine)
        transport.isPunchEnabled = true
        transport.punchInBeat = transport.positionBeats + 1
        transport.punchOutBeat = transport.positionBeats + 4
        #expect(throws: (any Error).self) {
            try engine.startTakeInPlayback(transport, audioURL: nil, captureMIDI: true) { _ in }
        }
        _ = try? sentinelNotes(box)
    }

    @Test("finishTakeKeepingPlayback answers false when nothing is recording — and touches nothing")
    func closeIsANoOpWhenNotRecording() throws {
        let engine = AudioEngine()
        do { try engine.prepare() } catch { return }
        defer { engine.shutdown() }
        // False here means "closed nothing", which is exactly what the store
        // turns into a teaching error rather than a silent success.
        #expect(!engine.finishTakeKeepingPlayback())
        #expect(!engine.transportRollingForTesting)
    }
}
