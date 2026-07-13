import AVFAudio
import CryptoKit
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m14-b (L-2) gates — gapless loop wrap: MIDI + automation unroll
// (docs/research/design-m13f-gapless-loop.md §4-A "MIDI"/"Automation", §5,
// §8 failure mode 1, §9 L-2, §10 conditions C2/C3/C4):
//
//  · C2 — MIDI republish law: schedule extensions are APPEND-ONLY from the
//    same anchor; across any republish every noteID delivers its on exactly
//    once and its off exactly once. Pinned at BOTH levels: the renderer state
//    machine (extension republish mid-render, prefix-identical arrays, the
//    re-seek landing on the first event ≥ the delivered watermark) and the
//    production path (the real `topUpLoopCycles` extension cadence driving an
//    offline render). The NEGATIVE direction is pinned too: the flush family
//    (stop/seek/edit → fresh timeline) still resets and cuts voices.
//  · Fixtures — straddling note (sounds across the loop seam, off fires
//    exactly once at its natural post-seam position, no flush at the wrap)
//    and same-pitch-across-seam (cycle N's off and cycle N+1's on of the SAME
//    pitch on the SAME boundary frame pair correctly, off delivered first).
//  · C3 for MIDI — under a multi-segment tempo map with the loop spanning a
//    tempo boundary, ≥ 3 unrolled cycles, every delivered MIDI event frame ==
//    the absolute integral from the schedule anchor, exact == (the m12-c
//    discipline); ≥ 1 automation breakpoint per cycle pinned the same way.
//  · Audibility A/B — a sustained PolySynth note through the seam shows
//    continuous nonzero energy at the wrap where the pre-L-2 schedule (head
//    pass only — reproduced by the linear negative control) goes silent.
//  · C8 — the loop machinery is invisible offline: a non-looping
//    representative render is deterministic; its SHA is printed for the
//    cross-era before/after comparison.
//
// All offline: manual-rendering AVAudioEngine + the REAL PlaybackGraph loop
// machinery (reconcile → scheduleAll(loop:) → topUpLoopCycles), the L-1 rig
// idiom. EventCaptureInstrument gives frame-exact delivery evidence; the
// audibility test uses the real PolySynth.

private let l2Rate = 48_000.0
private let l2Quantum = 512

// MARK: - Offline rig driving the REAL graph loop machinery (L-1 idiom)

@MainActor
private struct L2GraphRig {
    let engine: AVAudioEngine
    let graph: PlaybackGraph

    /// `loop: nil` schedules the LINEAR path (the pre-L-2 offline behavior
    /// for MIDI under a loop — the negative control). `configure` runs before
    /// `reconcile` (instrument-factory injection).
    init(tracks: [Track], tempoMap: TempoMap, fromBeat: Double,
         loop: PlaybackGraph.LoopWindow?, horizonSeconds: Double = 0.2,
         configure: (PlaybackGraph) -> Void = { _ in }) throws {
        engine = AVAudioEngine()
        graph = PlaybackGraph(engine: engine)
        configure(graph)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: l2Rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: tracks))
        graph.applyParameters(tracks: tracks)
        try engine.start()
        graph.applyParameters(tracks: tracks)
        graph.scheduleAll(fromBeat: fromBeat, tempoMap: tempoMap, loop: loop)
        if loop != nil {
            graph.topUpLoopCycles(elapsedPlayerSeconds: 0,
                                  horizonSeconds: horizonSeconds)
        }
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)
    }

    /// Pulls `frames` total, ticking `topUpLoopCycles` after every third
    /// 512-frame quantum — the live playhead cadence (`serviceLoop`), which
    /// is what drives the mid-render extension republishes under test.
    func render(frames: Int, horizonSeconds: Double = 0.2, looping: Bool = true,
                into channelData: inout [[Float]]) throws {
        let format = engine.manualRenderingFormat
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var rendered = 0
        var pulls = 0
        while rendered < frames {
            let request = AVAudioFrameCount(min(frames - rendered, l2Quantum))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            let source = try #require(buffer.floatChannelData)
            let count = Int(buffer.frameLength)
            for channel in 0..<2 {
                channelData[channel].append(contentsOf:
                    UnsafeBufferPointer(start: source[channel], count: count))
            }
            rendered += count
            pulls += 1
            if looping, pulls % 3 == 0 {
                graph.topUpLoopCycles(
                    elapsedPlayerSeconds: Double(rendered) / l2Rate,
                    horizonSeconds: horizonSeconds)
            }
        }
    }
}

// MARK: - Shared analysis helpers

/// RMS of `channelData[0]` over `range` (mono-sufficient: test signals are
/// identical across channels).
private func l2RMS(_ channelData: [[Float]], _ range: Range<Int>) -> Double {
    var sum = 0.0
    for frame in range {
        let v = Double(channelData[0][frame])
        sum += v * v
    }
    return (sum / Double(range.count)).squareRoot()
}

/// Minimum RMS over consecutive `chunk`-frame windows spanning `range` —
/// the "continuous nonzero energy" detector (a single silent chunk drops it
/// to ~0).
private func l2MinChunkRMS(_ channelData: [[Float]], _ range: Range<Int>,
                           chunk: Int = 480) -> Double {
    var minimum = Double.greatestFiniteMagnitude
    var start = range.lowerBound
    while start + chunk <= range.upperBound {
        minimum = min(minimum, l2RMS(channelData, start..<start + chunk))
        start += chunk
    }
    return minimum
}

private func l2NaNCount(_ channelData: [[Float]]) -> Int {
    channelData.reduce(0) { total, samples in
        total + samples.lazy.filter { $0.isNaN }.count
    }
}

/// Groups captured (non-reset) events by noteID → (ons, offs, on frame,
/// off frame) for the exactly-once accounting.
private func l2NoteLedger(_ events: [EventCaptureInstrument.CapturedEvent])
    -> [UInt64: (ons: Int, offs: Int, onFrame: Int64, offFrame: Int64)] {
    var ledger: [UInt64: (ons: Int, offs: Int, onFrame: Int64, offFrame: Int64)] = [:]
    for captured in events where !captured.wasReset {
        var entry = ledger[captured.event.noteID] ?? (0, 0, -1, -1)
        if captured.event.kind == ScheduledMIDIEvent.noteOn {
            entry.ons += 1
            entry.onFrame = captured.firedAtFrame
        } else {
            entry.offs += 1
            entry.offFrame = captured.firedAtFrame
        }
        ledger[captured.event.noteID] = entry
    }
    return ledger
}

// MARK: - The gates

@MainActor
@Suite("Gapless loop MIDI + automation unroll (m14-b L-2)", .serialized)
struct GaplessLoopMIDITests {
    /// The A/B phrase: one PolySynth note [beat 1, beat 2.5) inside a 4-beat
    /// clip, loop [0, 2) at 120 → the note SOUNDS ACROSS every loop seam by
    /// half a beat (12 000 frames) on each side.
    private func sustainedPhraseTrack() -> Track {
        Track(name: "Synth", kind: .instrument, clips: [
            Clip(name: "phrase", startBeat: 0, lengthBeats: 4, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 1, lengthBeats: 1.5),
            ]),
        ])
    }

    /// AUDIBILITY A/B, the "after" side: with the L-2 unroll, the sustained
    /// note rings THROUGH both wraps (continuous nonzero energy across every
    /// boundary window) and every unrolled cycle re-fires its onset on the
    /// true grid. The pre-L-2 "before" is `audibilityBeforeControl` below.
    @Test("A/B after: sustained note rings through 2 wraps; every cycle onset fires")
    func audibilityVoicesPersistAcrossWraps() throws {
        let cycleFrames = 48_000  // loop [0,2) at 120
        let rig = try L2GraphRig(
            tracks: [sustainedPhraseTrack()], tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 0, loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 2))
        var output: [[Float]] = [[], []]
        try rig.render(frames: 3 * cycleFrames, into: &output)
        rig.engine.stop()

        // Seam windows: ±2400 frames around each boundary — the note is held
        // across both (previous cycle's voice off at +12000 past the seam,
        // next cycle's onset 24000 before the NEXT seam).
        var seamMinima: [Double] = []
        for boundary in [cycleFrames, 2 * cycleFrames] {
            seamMinima.append(l2MinChunkRMS(output, boundary - 2_400..<boundary + 2_400))
        }
        // Onset evidence per unrolled cycle (skip 480 frames of attack).
        var onsetRMS: [Double] = []
        for k in 1...2 {
            let onset = k * cycleFrames + 24_000
            onsetRMS.append(l2RMS(output, onset + 480..<onset + 2_880))
        }
        print("[measured] A/B after: seam min-chunk RMS \(seamMinima), "
              + "cycle onset RMS \(onsetRMS), NaNs \(l2NaNCount(output))")
        for minimum in seamMinima {
            #expect(minimum > 1e-4)
        }
        for rms in onsetRMS {
            #expect(rms > 1e-4)
        }
        #expect(l2NaNCount(output) == 0)
    }

    /// AUDIBILITY A/B, the "before" side (negative control, kept permanent):
    /// the pre-L-2 offline schedule for MIDI under a loop was the LINEAR head
    /// build with no cycle events at all — reproduced here byte-for-byte by
    /// the linear path (`loop: nil`, the C8-pinned null path). The head note
    /// ends at beat 2.5 (frame 60 000) and nothing ever sounds again: the
    /// second seam window is SILENT and cycle onsets are missing — exactly
    /// what L-2 fixes.
    @Test("A/B before control: the linear (pre-L-2) schedule is silent at the second seam")
    func audibilityBeforeControl() throws {
        let cycleFrames = 48_000
        let rig = try L2GraphRig(
            tracks: [sustainedPhraseTrack()], tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 0, loop: nil)
        var output: [[Float]] = [[], []]
        try rig.render(frames: 3 * cycleFrames, looping: false, into: &output)
        rig.engine.stop()

        let seam2 = l2MinChunkRMS(output, 2 * cycleFrames - 2_400..<2 * cycleFrames + 2_400)
        let onset2 = l2RMS(output, 2 * cycleFrames + 24_480..<2 * cycleFrames + 26_880)
        print("[measured] A/B before: seam-2 min-chunk RMS \(seam2), "
              + "cycle-2 onset RMS \(onset2)")
        #expect(seam2 < 1e-6)
        #expect(onset2 < 1e-6)
    }

    /// C8 — offline null case: the loop machinery is provably invisible to a
    /// NON-looping render. A representative project (faded audio clip,
    /// gain-enveloped audio clip, PolySynth MIDI, volume + pan automation,
    /// 2-segment tempo map) renders twice through two independent
    /// OfflineRenderers: byte-identical, SHA printed for the cross-era
    /// before/after comparison (the m14-b gate ran this on the pre-change
    /// tree and this tree; the SHAs must match).
    @Test("C8: non-looping representative render is deterministic — SHA printed for the era gate")
    func c8NonLoopingRenderDeterminism() throws {
        // Deterministic ramp source written once for both renders.
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: l2Rate, channels: 2))
        let frames = 96_000
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            let sample = 0.25 + Float(frame) * 1e-6
            channels[0][frame] = sample
            channels[1][frame] = -sample
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m14b-c8-\(UUID().uuidString).caf")
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let tracks = [
            Track(name: "Faded", kind: .audio, clips: [
                Clip(name: "f", startBeat: 0, lengthBeats: 3, audioFileURL: url,
                     fadeInBeats: 0.5, fadeOutBeats: 0.5, fadeOutCurve: .equalPower),
            ], automation: [
                AutomationLane(target: .volume, points: [
                    AutomationPoint(beat: 0, value: 0.4),
                    AutomationPoint(beat: 4, value: 1.0),
                ]),
            ]),
            Track(name: "Shaped", kind: .audio, clips: [
                Clip(name: "e", startBeat: 1, lengthBeats: 2, audioFileURL: url,
                     gainEnvelope: [ClipGainPoint(beat: 0.5, gainDb: -6),
                                    ClipGainPoint(beat: 1.5, gainDb: -2)]),
            ]),
            Track(name: "Keys", kind: .instrument, clips: [
                Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
                    MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
                    MIDINote(pitch: 67, velocity: 90, startBeat: 1.5, lengthBeats: 0.75),
                ]),
            ], automation: [
                AutomationLane(target: .pan, points: [
                    AutomationPoint(beat: 0, value: -0.5),
                    AutomationPoint(beat: 3, value: 0.5),
                ]),
            ]),
        ]
        let map = try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 120),
            TempoMap.Segment(startBeat: 4, bpm: 90),
        ])

        func renderOnce() throws -> RenderedAudio {
            try OfflineRenderer().render(tracks: tracks, tempoMap: map,
                                         fromBeat: 0, durationSeconds: 4.0)
        }
        func sha(_ audio: RenderedAudio) -> String {
            var hasher = SHA256()
            for channel in audio.channelData {
                channel.withUnsafeBufferPointer { samples in
                    hasher.update(data: Data(buffer: samples))
                }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        let first = try renderOnce()
        let second = try renderOnce()
        let shaFirst = sha(first)
        let shaSecond = sha(second)
        var peak: Float = 0
        for channel in first.channelData {
            for sample in channel { peak = max(peak, abs(sample)) }
        }
        print("[measured] C8 non-looping render SHA \(shaFirst) "
              + "(repeat \(shaSecond)), frames \(first.frameCount), peak \(peak)")
        #expect(shaFirst == shaSecond)
        #expect(first.frameCount == 192_000)
        #expect(peak > 0.1)  // determinism over real signal, not silence
    }

    // MARK: - C2, renderer level (the InstrumentRendererTests harness idiom)

    private struct RendererHarness {
        let capture: EventCaptureInstrument
        let renderer: InstrumentRenderer
        let buffer: AVAudioPCMBuffer

        @MainActor
        init() {
            capture = EventCaptureInstrument()
            capture.prepare(sampleRate: l2Rate, maxFramesPerQuantum: 512, channelCount: 2)
            renderer = InstrumentRenderer(instrument: capture, sampleRate: l2Rate)
            let format = AVAudioFormat(standardFormatWithSampleRate: l2Rate, channels: 2)!
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            buffer.frameLength = 512
        }

        @MainActor
        func pull(_ sampleTime: Double) {
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = sampleTime
            timestamp.mFlags = .sampleTimeValid
            var silence = ObjCBool(false)
            _ = renderer.renderQuantum(
                timestamp: &timestamp, frameCount: 512,
                audioBufferList: buffer.mutableAudioBufferList, isSilence: &silence)
        }
    }

    private func event(_ t: Int64, id: UInt64, on: Bool,
                       pitch: UInt8 = 60, velocity: UInt8 = 100) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(sampleTime: t, noteID: id,
                           kind: on ? ScheduledMIDIEvent.noteOn : ScheduledMIDIEvent.noteOff,
                           pitch: pitch, velocity: on ? velocity : 0)
    }

    /// C2, THE unit test: an extension republish LANDS MID-RENDER (between
    /// offline pulls) on the SAME timelineID. The extended array is literally
    /// prefix-identical; across the republish every noteID delivers its on
    /// exactly once and its off exactly once; the already-DELIVERED on@600
    /// never re-fires; the PENDING off@1600 (behind the delivered watermark's
    /// horizon but not yet due) is not skipped — the re-seek lands on the
    /// first event ≥ the delivered watermark, and the epoch stays latched
    /// (same timeline, no shift).
    @Test("C2: mid-render extension republish — prefix-identical, exactly-once, pending off survives")
    func c2ExtensionRepublishMidRender() {
        let harness = RendererHarness()
        let family: UInt64 = 77
        let base = [
            event(600, id: 0, on: true), event(1_600, id: 0, on: false),
            event(2_000, id: 1, on: true), event(2_400, id: 1, on: false),
        ]
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: l2Rate,
            events: base, timelineID: family))
        harness.pull(0)      // window [0, 512): nothing due
        harness.pull(512)    // [512, 1024): on@600 delivered; off@1600 pending

        // The extension: the old array verbatim + strictly-future events.
        let extended = base + [event(4_000, id: 2, on: true),
                               event(4_500, id: 2, on: false)]
        #expect(Array(extended.prefix(base.count)) == base)  // append-only, literal
        harness.renderer.publish(MIDIEventSchedule(
            generation: 2, mode: .offline, sampleRate: l2Rate,
            events: extended, timelineID: family))

        var t = 1_024.0
        while t <= 4_608 {
            harness.pull(t)
            t += 512
        }

        let captured = harness.capture.capturedEvents()
        let ledger = l2NoteLedger(captured)
        print("[measured] C2 renderer extension: ledger \(ledger.sorted { $0.key < $1.key }), "
              + "resets \(captured.filter(\.wasReset).count)")
        #expect(ledger.count == 3)
        for id: UInt64 in [0, 1, 2] {
            #expect(ledger[id]?.ons == 1)
            #expect(ledger[id]?.offs == 1)
        }
        #expect(ledger[0]?.onFrame == 600)     // fired once, BEFORE the republish
        #expect(ledger[0]?.offFrame == 1_600)  // pending at republish — not dropped
        #expect(ledger[1]?.onFrame == 2_000)
        #expect(ledger[1]?.offFrame == 2_400)
        #expect(ledger[2]?.onFrame == 4_000)   // appended events fire on the same epoch
        #expect(ledger[2]?.offFrame == 4_500)
        #expect(captured.filter(\.wasReset).isEmpty)  // an extension NEVER flushes
        #expect(harness.capture.overflowCount == 0)
    }

    /// C2, the negative direction: the flush family (stop/seek/edit) is
    /// UNCHANGED — requestFlush + unpublish cuts the voice (reset delivered),
    /// and the next schedule on a FRESH timelineID resets the cursor and
    /// re-latches the epoch (its events fire schedule-relative, exactly the
    /// pre-L-2 restart contract).
    @Test("C2 negative: flush family still fires and cuts; a fresh timeline fully resets")
    func c2FlushFamilyStillCuts() {
        let harness = RendererHarness()
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: l2Rate,
            events: [event(0, id: 0, on: true), event(96_000, id: 0, on: false)]))
        harness.pull(0)   // on@0 delivered — a voice is sounding

        harness.renderer.requestFlush()
        harness.renderer.publish(nil)
        harness.pull(512)  // flush honored: all-notes-off

        // Fresh restart schedule: default timelineID (== generation 2 ≠ 1) →
        // cursor 0 + epoch re-latch at the next pull (mSampleTime 1024).
        harness.renderer.publish(MIDIEventSchedule(
            generation: 2, mode: .offline, sampleRate: l2Rate,
            events: [event(100, id: 9, on: true), event(400, id: 9, on: false)]))
        harness.pull(1_024)

        let captured = harness.capture.capturedEvents()
        let resets = captured.filter(\.wasReset).count
        let ledger = l2NoteLedger(captured)
        print("[measured] C2 flush direction: resets \(resets), ledger "
              + "\(ledger.sorted { $0.key < $1.key })")
        #expect(resets == 1)                    // the flush fired, exactly once
        #expect(ledger[0]?.ons == 1)
        #expect(ledger[0]?.offs == 0)           // voice was CUT by the flush, not off'd
        #expect(ledger[9]?.onFrame == 100)      // fresh epoch: schedule-relative frames
        #expect(ledger[9]?.offFrame == 400)
        #expect(harness.capture.overflowCount == 0)
    }

    /// The merge law, pure math: appending a cycle block whose span the
    /// previous cycle's straddling OFF reaches into produces one globally
    /// sorted array, the old array's elements in their old relative order,
    /// literal prefix identity below the appended block's first frame — and
    /// a same-frame off/on collision orders off-BEFORE-on (the load-bearing
    /// tie rule, now across blocks).
    @Test("merge law: global order, prefix identity, off-before-on across blocks")
    func mergeAppendOnlyLaw() throws {
        let map = TempoMap(constantBPM: 120)
        // Straddling interleave: note [1, 3.5) in loop [0,2) — head off@84000
        // lands past cycle 1's on@72000.
        let straddle = [Clip(name: "s", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 1, lengthBeats: 2.5),
        ])]
        let head = MIDIEventSchedule.buildEvents(
            clips: straddle, fromBeat: 0, tempoMap: map, sampleRate: l2Rate,
            onsetEndBeat: 2).events
        let block = MIDIEventSchedule.buildEvents(
            clips: straddle, fromBeat: 0, tempoMap: map, sampleRate: l2Rate,
            onsetEndBeat: 2, offsetSeconds: 1.0, noteIDBase: 1).events
        let merged = MIDIEventSchedule.mergeSorted(head, block)
        #expect(head.map(\.sampleTime) == [24_000, 84_000])
        #expect(block.map(\.sampleTime) == [72_000, 132_000])
        // Interleaved yet sorted; head's elements keep relative order.
        #expect(merged.map(\.sampleTime) == [24_000, 72_000, 84_000, 132_000])
        #expect(merged.map(\.noteID) == [0, 1, 0, 1])
        // Prefix identity below the block's first frame (72 000).
        #expect(merged.prefix(1).elementsEqual(head.prefix(1)))
        for i in 1..<merged.count {
            #expect(!MIDIEventSchedule.orderedBefore(merged[i], merged[i - 1]))
        }

        // Same-frame collision at the seam: note [0,2) — off(cycle 0)@48000
        // and on(cycle 1)@48000 → off FIRST.
        let seam = [Clip(name: "p", startBeat: 0, lengthBeats: 2, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2),
        ])]
        let seamHead = MIDIEventSchedule.buildEvents(
            clips: seam, fromBeat: 0, tempoMap: map, sampleRate: l2Rate,
            onsetEndBeat: 2).events
        let seamBlock = MIDIEventSchedule.buildEvents(
            clips: seam, fromBeat: 0, tempoMap: map, sampleRate: l2Rate,
            onsetEndBeat: 2, offsetSeconds: 1.0, noteIDBase: 1).events
        let seamMerged = MIDIEventSchedule.mergeSorted(seamHead, seamBlock)
        #expect(seamMerged.map(\.sampleTime) == [0, 48_000, 48_000, 96_000])
        #expect(seamMerged[1].kind == ScheduledMIDIEvent.noteOff)   // off(0) first
        #expect(seamMerged[1].noteID == 0)
        #expect(seamMerged[2].kind == ScheduledMIDIEvent.noteOn)    // then on(1)
        #expect(seamMerged[2].noteID == 1)
    }

    // MARK: - C2 production path + fixtures (the real extension cadence)

    /// One instrument track through the REAL machinery (scheduleAll(loop:) →
    /// startAllPlayers → mid-render topUpLoopCycles republishes). Returns the
    /// non-reset triples and the reset count.
    private func renderLoopedCapture(
        notes: [MIDINote], clipLengthBeats: Double, loopEndBeat: Double,
        renderFrames: Int, tempoMap: TempoMap = TempoMap(constantBPM: 120),
        fromBeat: Double = 0, loopStartBeat: Double = 0,
        clipStartBeat: Double = 0, automation: [AutomationLane] = []
    ) throws -> (byID: [UInt64: (pitch: UInt8, on: Int64, off: Int64)],
                 resets: Int, rig: L2GraphRig, trackID: UUID) {
        let capture = EventCaptureInstrument()
        capture.prepare(sampleRate: l2Rate, maxFramesPerQuantum: 4_096, channelCount: 2)
        let track = Track(name: "I", kind: .instrument, clips: [
            Clip(name: "m", startBeat: clipStartBeat, lengthBeats: clipLengthBeats,
                 notes: notes),
        ], automation: automation)
        let rig = try L2GraphRig(
            tracks: [track], tempoMap: tempoMap, fromBeat: fromBeat,
            loop: PlaybackGraph.LoopWindow(startBeat: loopStartBeat, endBeat: loopEndBeat),
            configure: { $0.instrumentFactory = { _ in capture } })
        var output: [[Float]] = [[], []]
        try rig.render(frames: renderFrames, into: &output)
        rig.engine.stop()
        #expect(capture.overflowCount == 0)

        var byID: [UInt64: (pitch: UInt8, on: Int64, off: Int64)] = [:]
        var resets = 0
        for captured in capture.capturedEvents() {
            if captured.wasReset {
                resets += 1
                continue
            }
            var entry = byID[captured.event.noteID] ?? (captured.event.pitch, -1, -1)
            if captured.event.kind == ScheduledMIDIEvent.noteOn {
                // A second on for the same id would overwrite silently — pin
                // exactly-once explicitly.
                #expect(entry.on == -1, "double-fired on for id \(captured.event.noteID)")
                entry.on = captured.firedAtFrame
            } else {
                #expect(entry.off == -1, "double-fired off for id \(captured.event.noteID)")
                entry.off = captured.firedAtFrame
            }
            byID[captured.event.noteID] = entry
        }
        return (byID, resets, rig, track.id)
    }

    /// C2 on the production path: two notes per cycle, three cycles, the
    /// extension republishes riding the real top-up cadence mid-render.
    /// Every noteID exactly once, every frame == the absolute integral, ZERO
    /// flushes at the wraps, and the published schedule is append-only on the
    /// wire: same timelineID across a grown generation, the start schedule a
    /// literal prefix of the final one.
    @Test("C2 production: 3 cycles, exactly-once, append-only republish on one timeline, zero flushes")
    func c2ProductionExactlyOnce() throws {
        let capture = EventCaptureInstrument()
        capture.prepare(sampleRate: l2Rate, maxFramesPerQuantum: 4_096, channelCount: 2)
        let track = Track(name: "I", kind: .instrument, clips: [
            Clip(name: "m", startBeat: 0, lengthBeats: 2, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 0.5),
                MIDINote(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 0.5),
            ]),
        ])
        let rig = try L2GraphRig(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0,
            loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 2),
            configure: { $0.instrumentFactory = { _ in capture } })

        // Wire-level append-only pins: borrow the schedule at roll start...
        let renderer = try #require(rig.graph.instrumentRenderer(forTrack: track.id))
        let startSchedule = try #require(renderer.currentSchedule)
        let startEvents = Array(startSchedule.events)
        let startGeneration = startSchedule.generation
        let familyID = startSchedule.timelineID

        var output: [[Float]] = [[], []]
        try rig.render(frames: 3 * 48_000, into: &output)
        rig.engine.stop()

        // ...and after the mid-render extensions: same timeline, grown
        // generation, literal prefix identity (no straddling notes here).
        let finalSchedule = try #require(renderer.currentSchedule)
        #expect(finalSchedule.generation > startGeneration)
        #expect(finalSchedule.timelineID == familyID)
        #expect(finalSchedule.events.count > startEvents.count)
        #expect(Array(finalSchedule.events.prefix(startEvents.count)) == startEvents)

        var byID: [UInt64: (pitch: UInt8, on: Int64, off: Int64)] = [:]
        var resets = 0
        for captured in capture.capturedEvents() {
            if captured.wasReset { resets += 1; continue }
            var entry = byID[captured.event.noteID] ?? (captured.event.pitch, -1, -1)
            if captured.event.kind == ScheduledMIDIEvent.noteOn { entry.on = captured.firedAtFrame }
            else { entry.off = captured.firedAtFrame }
            byID[captured.event.noteID] = entry
        }
        let triples = byID.values.sorted { $0.on < $1.on }
        var expected: [(pitch: UInt8, on: Int64, off: Int64)] = []
        for k in Int64(0)...2 {
            expected.append((60, k * 48_000, k * 48_000 + 12_000))
            expected.append((64, k * 48_000 + 24_000, k * 48_000 + 36_000))
        }
        print("[measured] C2 production: \(triples.count) notes "
              + "\(triples.map { "(p\($0.pitch) \($0.on)→\($0.off))" }.joined(separator: " ")), "
              + "resets \(resets), schedule gen \(startGeneration)→\(finalSchedule.generation) "
              + "tid \(familyID), events \(startEvents.count)→\(finalSchedule.events.count)")
        try #require(triples.count == expected.count)
        for (got, want) in zip(triples, expected) {
            #expect(got.pitch == want.pitch)
            #expect(got.on == want.on)
            #expect(got.off == want.off)
        }
        #expect(resets == 0)  // the wrap never flushes — voices persist
        #expect(capture.overflowCount == 0)
    }

    /// FIXTURE — straddling note: p60 sounds [beat 1, beat 2.5) across every
    /// seam of loop [0,2). Its off fires EXACTLY ONCE per cycle instance, at
    /// the natural post-seam frame (12 000 into the next cycle) — never
    /// clamped to the boundary, never dropped, and the wrap never flushes the
    /// sounding voice.
    @Test("fixture: straddling note persists across the seam; off fires once at its natural frame")
    func straddlingNoteFixture() throws {
        let (byID, resets, _, _) = try renderLoopedCapture(
            notes: [MIDINote(pitch: 60, velocity: 100, startBeat: 1, lengthBeats: 1.5)],
            clipLengthBeats: 4, loopEndBeat: 2, renderFrames: 3 * 48_000 + 24_000)
        let triples = byID.values.sorted { $0.on < $1.on }
        print("[measured] straddling fixture: "
              + "\(triples.map { "(\($0.on)→\($0.off))" }.joined(separator: " ")), resets \(resets)")
        try #require(triples.count == 3)
        for (k, triple) in triples.enumerated() {
            #expect(triple.on == Int64(k) * 48_000 + 24_000)
            // seconds(0 → 2.5) = 1.25 s: the off lands 12 000 frames PAST the
            // seam — inside the NEXT cycle, at the content's natural time.
            #expect(triple.off == Int64(k) * 48_000 + 60_000)
        }
        #expect(resets == 0)
    }

    /// FIXTURE — same pitch across the seam: p60 fills the whole loop [0,2),
    /// so cycle N's off and cycle N+1's on land on the SAME boundary frame.
    /// They must pair by noteID (no stolen off, no orphaned voice) and
    /// deliver off-BEFORE-on at the shared frame.
    @Test("fixture: same-pitch across the seam — off(N) before on(N+1) at the boundary frame")
    func samePitchAcrossSeamFixture() throws {
        let capture = EventCaptureInstrument()
        capture.prepare(sampleRate: l2Rate, maxFramesPerQuantum: 4_096, channelCount: 2)
        let track = Track(name: "I", kind: .instrument, clips: [
            Clip(name: "m", startBeat: 0, lengthBeats: 2, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2),
            ]),
        ])
        let rig = try L2GraphRig(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0,
            loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 2),
            configure: { $0.instrumentFactory = { _ in capture } })
        var output: [[Float]] = [[], []]
        try rig.render(frames: 3 * 48_000 + 512, into: &output)
        rig.engine.stop()

        let fired = capture.capturedEvents().filter { !$0.wasReset }
        let ledger = l2NoteLedger(fired)
        print("[measured] same-pitch seam: ledger "
              + "\(ledger.sorted { $0.value.onFrame < $1.value.onFrame }.map(\.value))")
        // 3 complete voices + cycle 3's voice sounding at render end (its on
        // at 144 000 falls inside the final 512-frame window; its off is past
        // the render — a HELD voice, not an orphan).
        try #require(ledger.count == 4)
        let complete = ledger.values.filter { $0.offs == 1 }.sorted { $0.onFrame < $1.onFrame }
        try #require(complete.count == 3)
        for entry in complete {
            #expect(entry.ons == 1)
            #expect(entry.offFrame - entry.onFrame == 48_000)  // full-cycle voice
        }
        let held = try #require(ledger.values.first { $0.offs == 0 })
        #expect(held.ons == 1)
        #expect(held.onFrame == 144_000)
        // At each boundary frame: exactly one off and one on, off FIRST —
        // the merged blocks' off-before-on rule, live at every seam.
        for boundary in [Int64(48_000), 96_000, 144_000] {
            let atBoundary = fired.filter { $0.firedAtFrame == boundary }
            try #require(atBoundary.count == 2)
            #expect(atBoundary[0].event.kind == ScheduledMIDIEvent.noteOff)
            #expect(atBoundary[1].event.kind == ScheduledMIDIEvent.noteOn)
            #expect(atBoundary[0].event.noteID != atBoundary[1].event.noteID)
        }
        #expect(capture.capturedEvents().filter(\.wasReset).isEmpty)
    }

    // MARK: - C3 for MIDI + automation (multi-segment map, m12-c discipline)

    /// C3: map 120 → 96@4 → 150@8, loop [2,6) spans the 96 boundary; the 150
    /// segment sits past the loop end and must never leak into cycle timing
    /// (any leak shifts a frame and fails an == below). Three notes per cycle
    /// — one per tempo segment plus one STRADDLING the seam (off at beat 6.5,
    /// evaluated on the real map past the loop end — the content's natural
    /// time). ≥ 3 unrolled cycles; every delivered event frame == the
    /// absolute integral from the anchor, computed here with independent
    /// exact arithmetic (spb 0.5 / 0.625, both exactly representable).
    /// The volume lane pins ≥ 1 automation breakpoint per cycle == the same
    /// integral, plus the boundary step and cross-cycle evaluation.
    @Test("C3: multi-segment map — every MIDI event frame and per-cycle automation breakpoint == the absolute integral")
    func c3MultiSegmentExactness() throws {
        let map = try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 120),
            TempoMap.Segment(startBeat: 4, bpm: 96),
            TempoMap.Segment(startBeat: 8, bpm: 150),
        ])
        let notes = [
            MIDINote(pitch: 60, velocity: 100, startBeat: 1, lengthBeats: 0.5),    // beats [3, 3.5)
            MIDINote(pitch: 64, velocity: 90, startBeat: 3, lengthBeats: 0.5),     // beats [5, 5.5)
            MIDINote(pitch: 72, velocity: 80, startBeat: 3.5, lengthBeats: 1),     // beats [5.5, 6.5) — straddles
        ]
        let volumeLane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 2, value: 1.0),
            AutomationPoint(beat: 5, value: 0.5),
        ])
        let cycleFrames = Int64(108_000)  // (2·0.5 + 2·0.625) s · 48 000, exact
        let (byID, resets, rig, trackID) = try renderLoopedCapture(
            notes: notes, clipLengthBeats: 5, loopEndBeat: 6,
            renderFrames: 448_000,  // covers cycle 3's straddling off @447000
            tempoMap: map, fromBeat: 2, loopStartBeat: 2, clipStartBeat: 2,
            automation: [volumeLane])

        // MIDI: expected (pitch, on, off) per cycle, independent arithmetic.
        // seconds from beat 2 to: 3→0.5, 3.5→0.75, 5→1.625, 5.5→1.9375,
        // 6.5→2.5625 (across the loop end, INSIDE the 96 segment — the 150
        // segment is never touched).
        var expected: [(pitch: UInt8, on: Int64, off: Int64)] = []
        for k in Int64(0)...3 {
            let cycle = k * cycleFrames
            expected.append((60, cycle + 24_000, cycle + 36_000))
            expected.append((64, cycle + 78_000, cycle + 93_000))
            expected.append((72, cycle + 93_000, cycle + 123_000))
        }
        let triples = byID.values.sorted { $0.on != $1.on ? $0.on < $1.on : $0.pitch < $1.pitch }
        print("[measured] C3 MIDI: \(triples.count) notes over 4 cycles, resets \(resets); "
              + "frames \(triples.map { "(p\($0.pitch) \($0.on)→\($0.off))" }.joined(separator: " "))")
        try #require(triples.count == expected.count)
        for (got, want) in zip(triples, expected.sorted { $0.on != $1.on ? $0.on < $1.on : $0.pitch < $1.pitch }) {
            #expect(got.pitch == want.pitch)
            #expect(got.on == want.on)   // == the absolute integral, m12-c discipline
            #expect(got.off == want.off)
        }
        #expect(resets == 0)

        // Automation: the published (extension-republished) schedule.
        let schedule = try #require(
            rig.graph.automationRenderer(forTrack: trackID)?.currentSchedule)
        let points = schedule.volumePoints
        let times = (0..<points.count).map { points[$0].sampleTime }
        // ≥ 1 breakpoint per cycle at the exact integral: the beat-5 interior
        // point of every unrolled cycle (head included).
        for k in Int64(0)...3 {
            let interior = k * cycleFrames + 78_000
            let index = times.firstIndex(of: interior)
            #expect(index != nil, "cycle \(k): no breakpoint at \(interior)")
            if let index {
                #expect(points[index].value == 0.5)
            }
        }
        // Boundary pair at each cycle start: the previous block's end (0.5)
        // then this cycle's start (1.0) on the SAME frame — the loop-semantics
        // step, owned by the incoming cycle.
        for k in Int64(1)...3 {
            let boundary = k * cycleFrames
            let indices = times.enumerated().filter { $0.element == boundary }.map(\.offset)
            #expect(indices.count == 2, "cycle \(k): boundary pair missing")
            if indices.count == 2 {
                #expect(points[indices[0]].value == 0.5)
                #expect(points[indices[1]].value == 1.0)
            }
        }
        // Value semantics across cycles: mid-ramp in cycle 2 reads the
        // wrapped lane exactly (time-linear midpoint of 1.0 → 0.5), and the
        // boundary frame itself already reads the NEW cycle's start value.
        var cursor = -1
        #expect(AutomationSchedule.value(at: 2 * cycleFrames + 39_000,
                                         points: points, cursor: &cursor) == 0.75)
        cursor = -1
        #expect(AutomationSchedule.value(at: 2 * cycleFrames,
                                         points: points, cursor: &cursor) == 1.0)
        cursor = -1
        #expect(AutomationSchedule.value(at: 2 * cycleFrames - 1,
                                         points: points, cursor: &cursor) == 0.5)
        print("[measured] C3 automation: \(points.count) breakpoints, per-cycle interior "
              + "@ +78000 all 0.5, boundary pairs (0.5→1.0) at cycle starts, "
              + "mid-ramp probe 0.75, boundary step 0.5→1.0")
    }
}
