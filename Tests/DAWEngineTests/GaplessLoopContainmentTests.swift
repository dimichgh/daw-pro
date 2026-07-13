import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m14-d (L-4) — §8.6 containment soak (docs/research/design-m13f-gapless-loop.md
// §8.6 DECIDED amendment: prune-below-watermark on the same timelineID — THE
// SUFFIX-IDENTITY LAW). The soak loops enough cycles to trigger ≥ 2 containment
// events and pins, on OBSERVABLES (array counts / high-water / event ledgers —
// never timing):
//
//  (i)  BOUNDED MEMORY — the published MIDI event array and automation
//       breakpoint array are bounded by ~(threshold + margin + lookahead)
//       cycles at every observation point, and the measured high-water is
//       far below the unpruned total the same run would have produced; the
//       delivered prefix is PHYSICALLY gone (first event == the containment
//       bound's absolute integral).
//  (ii) C2 LEDGER — across both containment events every noteID delivers its
//       on exactly once and its off exactly once, at frames == the absolute
//       integrals (the m12-c discipline); zero double-fires, zero drops.
//  (iii) VOICES NOT CUT — zero resets across the whole soak, and the
//       straddling voice SOUNDING ACROSS each containment boundary delivers
//       its off at its natural post-seam frame (the straddling-note fixture
//       idiom, applied to the containment seam instead of the wrap seam).
//
// All offline: the L-1/L-2 rig idiom — manual-rendering AVAudioEngine driving
// the REAL PlaybackGraph loop machinery on the live top-up cadence.

private let soakRate = 48_000.0
private let soakQuantum = 512

@MainActor
@Suite("Gapless loop §8.6 containment (m14-d L-4)", .serialized)
struct GaplessLoopContainmentTests {
    /// Fixture: loop [0, 1) at 240 BPM → cycle = 0.25 s = 12 000 frames.
    /// Two notes per cycle — one in-cycle ([0, 0.25) beats) and one
    /// STRADDLING every seam ([0.5, 1.5) beats: its off lands 6 000 frames
    /// past each boundary, so a containment republish always lands with a
    /// voice sounding across it). One volume lane (1.0 → 0.5 ramp over
    /// [0, 0.5), then flat) exercises the automation containment path.
    @Test("soak: ≥ 2 containment events — bounded arrays, exactly-once ledger, straddling voice uncut")
    func containmentSoak() throws {
        let threshold = PlaybackGraph.loopPruneThresholdCycles
        let cycleFrames = Int64(12_000)                      // 1 beat at 240 BPM, exact
        // First containment at sounding == threshold + 1, second at
        // 2·threshold + 1 — render past the second with margin.
        let renderCycles = 2 * threshold + 5                 // 21 at threshold 8
        let renderFrames = renderCycles * Int(cycleFrames)   // 252 000

        let capture = EventCaptureInstrument()
        capture.prepare(sampleRate: soakRate, maxFramesPerQuantum: 4_096, channelCount: 2)
        let volumeLane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 1.0),
            AutomationPoint(beat: 0.5, value: 0.5),
        ])
        let track = Track(name: "I", kind: .instrument, clips: [
            Clip(name: "m", startBeat: 0, lengthBeats: 4, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 0.25),
                MIDINote(pitch: 64, velocity: 90, startBeat: 0.5, lengthBeats: 1.0),
            ]),
        ], automation: [volumeLane])

        // Rig (the L-2 idiom, inline so the soak can observe between ticks).
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        graph.instrumentFactory = { _ in capture }
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: soakRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: [track]))
        graph.applyParameters(tracks: [track])
        try engine.start()
        graph.applyParameters(tracks: [track])
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 240),
                          loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 1))
        graph.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)

        let renderer = try #require(graph.instrumentRenderer(forTrack: track.id))
        let automation = try #require(graph.automationRenderer(forTrack: track.id))

        // Render on the live tick cadence, observing AFTER every top-up.
        var prunedTransitions: [(atCycle: Int, prunedBelow: Int)] = []
        var lastPruned = graph.loopPrunedBelowCycle ?? 0
        var eventHighWater = 0
        var pointHighWater = 0
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var rendered = 0
        var pulls = 0
        while rendered < renderFrames {
            let request = AVAudioFrameCount(min(renderFrames - rendered, soakQuantum))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            rendered += Int(buffer.frameLength)
            pulls += 1
            if pulls % 3 == 0 {
                graph.topUpLoopCycles(elapsedPlayerSeconds: Double(rendered) / soakRate,
                                      horizonSeconds: 0.2)
                let pruned = graph.loopPrunedBelowCycle ?? 0
                if pruned != lastPruned {
                    prunedTransitions.append(
                        (atCycle: rendered / Int(cycleFrames), prunedBelow: pruned))
                    lastPruned = pruned
                }
                eventHighWater = max(eventHighWater,
                                     renderer.currentSchedule?.events.count ?? 0)
                pointHighWater = max(pointHighWater,
                                     automation.currentSchedule?.volumePoints.count ?? 0)
            }
        }
        let finalThrough = try #require(graph.loopScheduledThroughCycle)
        let finalPruned = try #require(graph.loopPrunedBelowCycle)
        let finalSchedule = try #require(renderer.currentSchedule)
        let finalPoints = try #require(automation.currentSchedule).volumePoints
        engine.stop()

        // ---- (i) bounded memory, on observables ----------------------------
        // ≥ 2 containment events, at the trigger's own arithmetic: prunedBelow
        // jumps to (sounding − 1) when history spans ≥ threshold cycles.
        print("[measured] containment soak: \(prunedTransitions.count) containment events "
              + "\(prunedTransitions), threshold \(threshold), finalThrough \(finalThrough), "
              + "finalPruned \(finalPruned), event high-water \(eventHighWater) "
              + "(final \(finalSchedule.events.count)), breakpoint high-water \(pointHighWater) "
              + "(final \(finalPoints.count))")
        try #require(prunedTransitions.count >= 2)
        #expect(prunedTransitions[0].prunedBelow == threshold)
        #expect(prunedTransitions[1].prunedBelow == 2 * threshold)
        // 4 events / 3 breakpoints per cycle block; retained span is bounded
        // by threshold + margin(1) + eager/coverage lookahead(≤ 3) + the head
        // — the high-water can NEVER reach the unpruned totals this same run
        // would have produced (4·(finalThrough + 1) events), and a generous
        // concrete ceiling pins "bounded" absolutely, not relatively.
        let unprunedEvents = 4 * (finalThrough + 1)
        #expect(eventHighWater < unprunedEvents - 30)
        #expect(eventHighWater <= 4 * (threshold + 6))
        #expect(pointHighWater <= 3 * (threshold + 6))
        #expect(finalSchedule.events.count <= 4 * (threshold + 6))
        // The delivered prefix is PHYSICALLY gone: the first surviving event
        // is exactly the containment bound's absolute integral — cycle
        // (2·threshold)'s start frame — and the first breakpoint matches,
        // re-stating the lane's cycle-entry value (self-contained blocks).
        let bound = Int64(2 * threshold) * cycleFrames
        #expect(finalSchedule.events[0].sampleTime == bound)
        #expect(finalPoints[0].sampleTime == bound)
        #expect(finalPoints[0].value == 1.0)
        // Suffix identity, value-level: automation at/after the bound reads
        // exactly what the unpruned build would give — mid-ramp 0.75 at
        // bound + 3000 (halfway down 1.0 → 0.5 over [bound, bound + 6000])
        // and the flat 0.5 at the interior point.
        var cursor = -1
        #expect(AutomationSchedule.value(at: bound + 3_000, points: finalPoints,
                                         cursor: &cursor) == 0.75)
        cursor = -1
        #expect(AutomationSchedule.value(at: bound + 6_000, points: finalPoints,
                                         cursor: &cursor) == 0.5)

        // ---- (ii) the C2 ledger across containment events ------------------
        var byID: [UInt64: (pitch: UInt8, on: Int64, off: Int64)] = [:]
        var resets = 0
        for captured in capture.capturedEvents() {
            if captured.wasReset { resets += 1; continue }
            var entry = byID[captured.event.noteID] ?? (captured.event.pitch, -1, -1)
            if captured.event.kind == ScheduledMIDIEvent.noteOn {
                #expect(entry.on == -1, "double-fired on for id \(captured.event.noteID)")
                entry.on = captured.firedAtFrame
            } else {
                #expect(entry.off == -1, "double-fired off for id \(captured.event.noteID)")
                entry.off = captured.firedAtFrame
            }
            byID[captured.event.noteID] = entry
        }
        #expect(capture.overflowCount == 0)
        // Expected: cycles 0..<renderCycles each fire A(on k·12000,
        // off +3000) and straddle(on k·12000+6000, off k·12000+18000); the
        // final cycle's straddling off lands past the render end — ONE held
        // voice, everything else complete at exact integrals.
        var expected: [(pitch: UInt8, on: Int64, off: Int64)] = []
        for k in Int64(0)..<Int64(renderCycles) {
            expected.append((60, k * cycleFrames, k * cycleFrames + 3_000))
            let straddleOff = k * cycleFrames + 18_000
            expected.append((64, k * cycleFrames + 6_000,
                             straddleOff < Int64(renderFrames) ? straddleOff : -1))
        }
        let triples = byID.values.sorted { $0.on != $1.on ? $0.on < $1.on : $0.pitch < $1.pitch }
        print("[measured] containment ledger: \(triples.count) notes, resets \(resets), "
              + "held \(triples.filter { $0.off == -1 }.count); "
              + "first surviving event @ \(finalSchedule.events[0].sampleTime) == bound \(bound)")
        try #require(triples.count == expected.count)
        for (got, want) in zip(triples, expected.sorted {
            $0.on != $1.on ? $0.on < $1.on : $0.pitch < $1.pitch
        }) {
            #expect(got.pitch == want.pitch)
            #expect(got.on == want.on)    // == the absolute integral
            #expect(got.off == want.off)  // exactly once, natural frame (-1 = held)
        }

        // ---- (iii) voices NOT cut at a containment event --------------------
        // Zero resets anywhere (a containment republish rides the same-tid
        // extension: no flush, no all-notes-off)...
        #expect(resets == 0)
        // ...and the straddling voice across EACH containment boundary
        // (sounding when the prune landed: its on is delivered, its off still
        // pending 6 000 frames past the boundary) delivered that off at its
        // natural frame — stated explicitly per containment event.
        for transition in prunedTransitions.prefix(2) {
            // The prune lands while cycle (prunedBelow + 1) sounds; the
            // straddling voice that entered from cycle prunedBelow is mid-air.
            let straddleOn = Int64(transition.prunedBelow) * cycleFrames + 6_000
            let voice = triples.first { $0.pitch == 64 && $0.on == straddleOn }
            #expect(voice != nil, "straddling voice at containment \(transition) missing")
            #expect(voice?.off == Int64(transition.prunedBelow) * cycleFrames + 18_000)
        }
    }
}
