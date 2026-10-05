import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m34-a-2 — **THE LIVE TAKE EXTENT, AGAINST THE REAL `AudioEngine`.**
///
/// ⭐ **THIS SUITE IS THE VACUITY CLOSURE FOR A SILENT PROTOCOL DEFAULT.**
/// `AudioEngineControlling.liveTakeExtent()` defaults to `nil` ("this engine has
/// no take to describe"). An `AudioEngine` that forgot to override it would
/// return nil forever, every DAWCore and DAWControl test in the tree would still
/// pass — because `TakeRegionPreview` is written to treat "no extent" as "draw
/// nothing" — and the symptom in the product would be a blank timeline during a
/// take, i.e. exactly the defect this item exists to fix, silently restored.
/// `finishTakeKeepingPlayback` (m34-h) and `previewController` (breath pad P6)
/// document the same hazard; this is its closure for the take-preview path.
///
/// ⭐⭐ **THE MEASUREMENT IS THE MOVING EXTENT, NEVER A SINGLE READ.** A
/// non-nil extent with `noteCount == 0` is what an engine reports the instant a
/// take opens, so any assertion built on one read could pass against a session
/// that never ingested anything. Every claim here reads the extent TWICE with a
/// real note played between.
///
/// ⚠️ CoreMIDI is SYSTEM-GLOBAL: another suite's virtual-source traffic can land
/// in this capture session, so this suite plays sentinel pitches 96-99, which no
/// other suite here sends (`LiveLayerCaptureTests` uses 90-95,
/// `LivePlayCaptureTests` 101-105, `LoopRecordEngineTests` 113).
@MainActor
@Suite("Live take extent — real engine (m34-a-2)", .serialized)
struct LiveTakeExtentTests {

    @MainActor
    private final class TakeBox {
        var result: Result<TakeResult, Error>?
    }

    /// A prepared engine with one instrument track and a rolling MIDI-only
    /// take, or nil on a machine with no output device (the headless-skip idiom
    /// `LiveLayerCaptureTests` uses).
    ///
    /// ⚠️ `countInBars = 0` is EXPLICIT (m23-cy): the project default is one
    /// bar, which delays the take anchor by 2.0 s at 120 BPM, so every note here
    /// would land pre-anchor and drop.
    private func rollingTake() throws -> (AudioEngine, Track, TakeBox)? {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return nil  // headless machine without an output device
        }
        let track = Track(name: "Extent", kind: .instrument)
        engine.tracksDidChange([track])
        var transport = TransportState()
        transport.positionBeats = 0
        transport.countInBars = 0
        let box = TakeBox()
        try engine.startTake(transport, audioURL: nil, captureMIDI: true) { box.result = $0 }
        return (engine, track, box)
    }

    /// Waits past the take anchor — `LivePlayCaptureTests.settlePastAnchor`'s
    /// measured 300 ms: a note played in the first ~70 ms of a take is genuinely
    /// pre-anchor and genuinely dropped.
    private func settlePastAnchor() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - The vacuity closure

    @Test("⭐⭐ THE ITEM: the REAL engine reports a live extent that MOVES as notes are played")
    func theRealEngineReportsAMovingExtent() async throws {
        guard let (engine, track, _) = try rollingTake() else { return }
        defer { engine.shutdown() }
        await settlePastAnchor()

        // ⭐ THE VACUITY CLOSURE. The protocol default is nil; an engine that
        // never overrode this fails here rather than shipping a blank timeline.
        let opening = engine.liveTakeExtent()
        #expect(opening != nil, """
            The REAL AudioEngine reported no live take extent while a take was rolling — \
            that is the AudioEngineControlling default leaking through, and the product \
            symptom is a timeline that stays blank while you play.
            """)
        #expect(opening?.noteCount == 0,
                "a take that has captured nothing must report zero notes, got \(String(describing: opening?.noteCount))")
        #expect(opening?.latestEventBeat == nil,
                "an untouched take must have no latest event beat")

        engine.setLivePlayPitches(trackID: track.id, pitches: [96], velocity: 96,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(250))
        let held = engine.liveTakeExtent()
        engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(150))
        let released = engine.liveTakeExtent()
        engine.stopRecording()

        print("[measured] extent: open notes=\(opening?.noteCount ?? -1) " +
              "held notes=\(held?.noteCount ?? -1) latest=\(String(describing: held?.latestEventBeat)) " +
              "released notes=\(released?.noteCount ?? -1) latest=\(String(describing: released?.latestEventBeat))")

        // ⭐ A HELD note already counts: `finish` clamps every open note to the
        // stop beat and lands it, so the region must appear on the key-DOWN.
        #expect((held?.noteCount ?? 0) >= 1,
                "a note still HELD must already count — the region has to appear on key-down, not key-up")
        #expect(held?.latestEventBeat != nil,
                "the latest-event beat must be set by the note-on")
        #expect((held?.latestEventBeat ?? -1) >= (held?.anchorBeat ?? 0),
                "an accepted event can never sit before the anchor")
        #expect((released?.latestEventBeat ?? 0) >= (held?.latestEventBeat ?? 0),
                "the extent must advance monotonically across the note-off")
        #expect((released?.noteCount ?? 0) >= 1, "a closed note must still count")
    }

    @Test("⛔ the extent is nil BETWEEN takes — it is not a stale reading of the last one")
    func theExtentIsNilBetweenTakes() async throws {
        guard let (engine, track, _) = try rollingTake() else { return }
        defer { engine.shutdown() }
        await settlePastAnchor()

        engine.setLivePlayPitches(trackID: track.id, pitches: [97], velocity: 96,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(200))
        engine.setLivePlayPitches(trackID: track.id, pitches: [], velocity: 0,
                                  captureIntoTake: true)
        try await Task.sleep(for: .milliseconds(120))

        // POSITIVE CONTROL: the extent is genuinely populated right now, so the
        // nil after the stop is attributable to the stop and not to a fixture
        // that never captured anything.
        let during = engine.liveTakeExtent()
        #expect((during?.noteCount ?? 0) >= 1, "positive control: nothing was captured, so the nil below proves nothing")

        engine.stopRecording()
        #expect(engine.liveTakeExtent() == nil, """
            The engine still reported an extent after the take stopped. A stale extent \
            would keep a provisional region painted over a lane after the real clip \
            landed — two objects claiming the same beats.
            """)
    }

    // ⚠️ **A PRE-ANCHOR TEST CANNOT LIVE HERE — RETIRED ON MEASUREMENT, NOT ON
    // TASTE.** `preAnchorNotesDoNotMoveTheExtent` used to sit at this spot: it
    // started a take with a ONE-BAR count-in and played a note 200 ms in,
    // expecting the drop. It passed filtered (0.69 s) and FAILED in the full
    // suite (11.81 s), capturing the note at beat 10.97 — because under load
    // `Task.sleep(.milliseconds(200))` returns seconds later, by which time the
    // 2.0 s count-in is genuinely over and the note is genuinely POST-anchor.
    // The engine was right and the test was wrong.
    //
    // ⭐ THE ASYMMETRY IS THE LESSON, AND IT IS WHY THE TWO TESTS ABOVE ARE SAFE:
    // they assert that something DID happen after waiting, so load only makes
    // them more true. A pre-anchor test asserts that time has NOT yet passed —
    // the one direction a loaded machine can falsify. The claim now lives in
    // `MIDICaptureTests.aPreAnchorNoteDoesNotMoveTheLiveExtent`, on fabricated
    // host times, where "before the anchor" is arithmetic instead of a race.
}
