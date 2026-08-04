import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m23-bp gates, LAYER 2 — note chase through the REAL PlaybackGraph, offline
// (docs/research/design-m23bp-note-chase.md §9 layer 2, G-L1 / G-L2).
//
//  · G-L1 (AUDIBILITY, both arms in ONE test so a broken rig cannot pass as a
//    finding). A real PolySynth voice, one long note started before the
//    reschedule anchor. `.continuation` → the note SOUNDS from the anchor;
//    `.relocation` on the byte-identical rig → SILENCE. This is the layer that
//    proves the fix is audible rather than merely present in an array.
//  · G-L2 (F1 GUARD — cycle blocks must NEVER chase). The head build of a
//    continuation resume chases a note straddling the loop start EXACTLY ONCE;
//    every appended loop-cycle block leaves it alone, because a cycle block
//    must reproduce what a fresh seek-to-loop-start produces (the §8.6 prune
//    self-containment law) and a seek is a RELOCATION. If chase leaked into
//    `extendLoopMIDI`, that pad would re-attack on EVERY wrap on top of the
//    still-ringing head voice — a doubled, repeating attack, which is a worse
//    musical outcome than the bug this cycle fixes.
//    NOTE (measured, not assumed): the two arms' event arrays cannot be
//    compared literally — the `.relocation` head build consumes one fewer
//    noteID, so every subsequent ID shifts. The ID-independent assertion is the
//    per-pitch note-ON COUNT, which a leak moves from 1 to 1-per-cycle.
//  · G-L3 (offline unmoved) is the EXISTING offline SHA suites re-run
//    (`StemNullTests`, `DeliveryFormatRenderTests`, GaplessLoopMIDITests' C8
//    render) — `OfflineRenderer` takes the `.relocation` default, so no new
//    test belongs here, only a required green.
//
// 48 kHz, 120 BPM ⇒ 1 beat = 24 000 frames.

private let ncgRate = 48_000.0
private let ncgQuantum = 512

// MARK: - Offline rig (the L2GraphRig idiom, GaplessLoopMIDITests:46-80)

@MainActor
private struct NoteChaseRig {
    let engine: AVAudioEngine
    let graph: PlaybackGraph

    init(tracks: [Track], tempoMap: TempoMap, fromBeat: Double,
         cause: RescheduleCause,
         loop: PlaybackGraph.LoopWindow? = nil,
         horizonSeconds: Double = 0.2,
         configure: (PlaybackGraph) -> Void = { _ in }) throws {
        engine = AVAudioEngine()
        graph = PlaybackGraph(engine: engine)
        configure(graph)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: ncgRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: tracks))
        graph.applyParameters(tracks: tracks)
        try engine.start()
        graph.applyParameters(tracks: tracks)
        graph.scheduleAll(fromBeat: fromBeat, tempoMap: tempoMap, loop: loop, cause: cause)
        if loop != nil {
            graph.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: horizonSeconds)
        }
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)
    }

    func render(frames: Int, into channelData: inout [[Float]]) throws {
        let format = engine.manualRenderingFormat
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var rendered = 0
        while rendered < frames {
            let request = AVAudioFrameCount(min(frames - rendered, ncgQuantum))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            let source = try #require(buffer.floatChannelData)
            let count = Int(buffer.frameLength)
            for channel in 0..<2 {
                channelData[channel].append(contentsOf:
                    UnsafeBufferPointer(start: source[channel], count: count))
            }
            rendered += count
        }
    }
}

private func ncgRMS(_ channelData: [[Float]], _ range: Range<Int>) -> Double {
    var sum = 0.0
    for frame in range { sum += Double(channelData[0][frame]) * Double(channelData[0][frame]) }
    return (sum / Double(range.count)).squareRoot()
}

private func ncgNaNCount(_ channelData: [[Float]]) -> Int {
    channelData.reduce(0) { $0 + $1.lazy.filter { $0.isNaN || $0.isInfinite }.count }
}

@MainActor
@Suite("Note chase — graph level, offline (m23-bp layer 2)", .serialized)
struct NoteChaseGraphTests {

    /// One PolySynth track holding a single long note from beat 0.
    private func heldNoteTrack() -> Track {
        Track(name: "Pad", kind: .instrument, clips: [
            Clip(name: "held", startBeat: 0, lengthBeats: 64, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 64),
            ]),
        ])
    }

    // MARK: - G-L1: audibility, both arms

    @Test("G-L1: a continuation resume SOUNDS the held note; the relocation control is silent")
    func continuationResumeIsAudible() throws {
        let renderFrames = 24_000   // 0.5 s

        var chased: [[Float]] = [[], []]
        let chasedRig = try NoteChaseRig(
            tracks: [heldNoteTrack()], tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 8, cause: .continuation)
        try chasedRig.render(frames: renderFrames, into: &chased)
        chasedRig.engine.stop()

        var relocated: [[Float]] = [[], []]
        let relocatedRig = try NoteChaseRig(
            tracks: [heldNoteTrack()], tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 8, cause: .relocation)
        try relocatedRig.render(frames: renderFrames, into: &relocated)
        relocatedRig.engine.stop()

        // Skip 480 frames of attack, then read a steady window.
        let window = 480..<renderFrames
        let chasedRMS = ncgRMS(chased, window)
        let relocatedRMS = ncgRMS(relocated, window)
        print("[measured] G-L1 continuation RMS \(chasedRMS), relocation RMS \(relocatedRMS), "
              + "NaN/Inf \(ncgNaNCount(chased) + ncgNaNCount(relocated))")
        #expect(chasedRMS > 1e-3)       // the fix: the held note is AUDIBLE
        #expect(relocatedRMS < 1e-6)    // the control: v0 policy is still silence
        #expect(ncgNaNCount(chased) == 0)
        #expect(ncgNaNCount(relocated) == 0)
    }

    // MARK: - G-L2: the F1 guard — cycle blocks never chase

    /// Loop [4, 6), continuation resume at beat 5. The 64-beat pad (onset 0)
    /// straddles the loop start; the in-loop marker note [5.5, 5.9) is the
    /// anti-vacuity control that proves cycle blocks really are being appended.
    private func straddlingLoopTrack() -> Track {
        Track(name: "Pad", kind: .instrument, clips: [
            Clip(name: "held", startBeat: 0, lengthBeats: 64, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 64),
                MIDINote(pitch: 67, velocity: 100, startBeat: 5.5, lengthBeats: 0.4),
            ]),
        ])
    }

    /// Publishes head + ≥ 3 cycle blocks and returns the on-events of the final
    /// schedule, per pitch.
    private func loopOnsByPitch(cause: RescheduleCause)
        throws -> (onsByPitch: [UInt8: [Int64]], total: Int) {
        let track = straddlingLoopTrack()
        let rig = try NoteChaseRig(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 5, cause: cause,
            loop: PlaybackGraph.LoopWindow(startBeat: 4, endBeat: 6),
            horizonSeconds: 3.5)   // head 0.5 s + 1.0 s cycles ⇒ ≥ 3 cycles
        let renderer = try #require(rig.graph.instrumentRenderer(forTrack: track.id))
        let schedule = try #require(renderer.currentSchedule)
        var onsByPitch: [UInt8: [Int64]] = [:]
        for event in schedule.events where event.kind == ScheduledMIDIEvent.noteOn {
            onsByPitch[event.pitch, default: []].append(event.sampleTime)
        }
        rig.engine.stop()
        return (onsByPitch.mapValues { $0.sorted() }, schedule.events.count)
    }

    @Test("G-L2: the head build chases ONCE; no loop-cycle block ever re-attacks it")
    func cycleBlocksNeverChase() throws {
        let continuation = try loopOnsByPitch(cause: .continuation)
        let relocation = try loopOnsByPitch(cause: .relocation)
        print("[measured] G-L2 continuation ons \(continuation.onsByPitch) "
              + "(total \(continuation.total)); relocation ons \(relocation.onsByPitch) "
              + "(total \(relocation.total))")

        // ANTI-VACUITY: cycle blocks really were appended — the in-loop marker
        // fires once per block, and IDENTICALLY in both arms (chase touched
        // nothing but the straddling note).
        let markerContinuation = continuation.onsByPitch[67] ?? []
        let markerRelocation = relocation.onsByPitch[67] ?? []
        #expect(markerContinuation.count >= 4)          // head + ≥ 3 cycles
        #expect(markerContinuation == markerRelocation)

        // THE GUARD: the straddling pad is admitted EXACTLY ONCE, by the head
        // build, at the anchor frame — never again by any cycle block.
        let padContinuation = continuation.onsByPitch[60] ?? []
        #expect(padContinuation == [0])
        // And the v0 control: without chase it never sounds at all.
        #expect(relocation.onsByPitch[60] == nil)

        // Event-count delta is exactly the chased pair (on + off), so no cycle
        // block gained anything either.
        #expect(continuation.total == relocation.total + 2)
    }
}
