import AVFAudio
import CryptoKit
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m15-a gates — the metronome follows the REAL meter map (audit-m15 F1/§2-B1):
//
//  · Null era (the fix is a NO-OP for a trivial map): a constant-meter
//    4/4-only project renders byte-identical before/after the change,
//    metronome OFF and ON. SHAs printed for the cross-era comparison — the
//    m15-a gate ran this exact fixture on the pre-change tree:
//    OFF a3927faf04f52758bb9e4593e5ede27e232bb5d966c22f5e62ec50e8446e7643,
//    ON  7dd272aa4df8730309cf7de36e312deab63d2963c000ed1e11c75aa7e08fe0e3
//    — the SHAs must match forever (the m14-c C8 3/4 fixture is the same
//    law's second anchor: OFF a3927faf…, ON 692e713d…; the OFF SHAs COINCIDE
//    because the C8 fixture's 120→90 tempo boundary at beat 4 sits past all
//    of the shared fixture's clip content).
//
//  · Offline == map (the m14-c meter pin extended to the OFFLINE path): an
//    OfflineRenderer click render under the audit's exact scenario
//    (4/4 → 3/4 at beat 8) puts downbeat clicks (1600 Hz) at beats
//    0, 4, 8, 11, 14, 17, 20 and regular clicks (1000 Hz) everywhere else —
//    the audit measured the OLD code accenting 0/4/8/12/16/20 live.
//
//  · Plumbing pins (the m15-a regression chain): every transport intent
//    caches `transport.meterMap` itself — never a constant rebuilt from the
//    base time signature — and the map the `Metronome` API RECEIVES is that
//    cached map (m14-c already proved the API renders a real map correctly;
//    these pins prove production HANDS it one).
//
// C4: everything here is control-thread scheduling — zero render-thread
// surface.

@MainActor
@Suite("Metronome meter map (m15-a)", .serialized)
struct MetronomeMeterMapTests {

    /// Deterministic 4/4 fixture: one faded/enveloped audio clip + one MIDI
    /// clip, constant 120 BPM, DEFAULT meter (the m14-c C8 fixture shape,
    /// re-anchored on a fully trivial map).
    private func nullEraTracks() throws -> (tracks: [Track], cleanup: () -> Void) {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
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
            .appendingPathComponent("m15a-era-\(UUID().uuidString).caf")
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
        }
        let tracks = [
            Track(name: "Faded", kind: .audio, clips: [
                Clip(name: "f", startBeat: 0, lengthBeats: 3, audioFileURL: url,
                     fadeInBeats: 0.5, fadeOutBeats: 0.5, fadeOutCurve: .equalPower),
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
            ]),
        ]
        return (tracks, { try? FileManager.default.removeItem(at: url) })
    }

    private func sha(_ audio: RenderedAudio) -> String {
        var hasher = SHA256()
        for channel in audio.channelData {
            channel.withUnsafeBufferPointer { samples in
                hasher.update(data: Data(buffer: samples))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Null era (m15-a gate 6): a 4/4-only project — trivial tempo AND meter
    /// maps, all render parameters at their defaults — renders deterministic,
    /// metronome OFF and ON. SHAs printed for the cross-era before/after
    /// comparison (see the suite header for the pinned pre-change values).
    @Test("null era: 4/4-only project renders are deterministic, metronome OFF and ON — SHAs printed for the era gate")
    func nullEra44Renders() throws {
        let (tracks, cleanup) = try nullEraTracks()
        defer { cleanup() }
        let map = TempoMap(constantBPM: 120)

        let off = try OfflineRenderer().render(
            tracks: tracks, tempoMap: map, fromBeat: 0, durationSeconds: 4.0)
        let off2 = try OfflineRenderer().render(
            tracks: tracks, tempoMap: map, fromBeat: 0, durationSeconds: 4.0)
        let on = try OfflineRenderer().render(
            tracks: tracks, tempoMap: map, fromBeat: 0, durationSeconds: 4.0,
            metronomeEnabled: true)
        let on2 = try OfflineRenderer().render(
            tracks: tracks, tempoMap: map, fromBeat: 0, durationSeconds: 4.0,
            metronomeEnabled: true)
        print("[era] m15a null OFF SHA \(sha(off)) (repeat \(sha(off2)))")
        print("[era] m15a null ON  SHA \(sha(on)) (repeat \(sha(on2)))")
        #expect(sha(off) == sha(off2))
        #expect(sha(on) == sha(on2))
        #expect(sha(off) != sha(on))  // the ON render really carries clicks
    }

    /// The audit's meter map, exactly: 4/4 from beat 0, 3/4 from beat 8.
    private func auditMeterMap() throws -> MeterMap {
        try MeterMap(changes: [
            MeterMap.Change(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            MeterMap.Change(startBeat: 8, beatsPerBar: 3, beatUnit: 4),
        ])
    }

    /// Classifies the click at `beat` (constant 120 BPM ⇒ frame = beat ×
    /// 24 000) by dominant frequency and peak amplitude — the audit's
    /// capture-probe method, offline.
    private func classify(_ samples: [Float], beat: Int)
        -> (frequency: Double, peak: Float, isDownbeat: Bool) {
        let start = beat * 24_000
        let frequency = TestSignals.dominantFrequency(
            byZeroCrossings: samples, sampleRate: 48_000, in: (start + 96)..<(start + 1_200))
        let peak = TestSignals.peak(samples, in: start..<(start + 1_440))
        // Downbeat: 1600 Hz @ 0.5; regular: 1000 Hz @ 0.35 (Metronome.swift).
        // Both classifiers must agree for a confident downbeat call.
        return (frequency, peak, abs(frequency - 1_600) < 10 && peak > 0.42)
    }

    /// Offline == map (m15-a gate 3, the audit scenario end-to-end): an
    /// OfflineRenderer click render under 4/4 → 3/4-at-beat-8 accents
    /// beats 0, 4, 8, 11, 14, 17, 20 — every one of the 23 clicks classified
    /// by frequency AND amplitude, zero ambiguity. The OLD code (constant
    /// map from the scalar) accented 12/16 and failed this exact list.
    @Test("offline render follows the meter map: 4/4→3/4 at beat 8 puts downbeats at 0,4,8,11,14,17,20")
    func offlineRenderFollowsMeterMap() throws {
        let audio = try OfflineRenderer().render(
            tracks: [], tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 0, durationSeconds: 11.5,
            metronomeEnabled: true, meterMap: try auditMeterMap()
        )
        let left = audio.channelData[0]
        #expect(left.count == 552_000)
        #expect(left.allSatisfy { $0.isFinite })

        let expectedDownbeats: Set<Int> = [0, 4, 8, 11, 14, 17, 20]
        var measuredDownbeats: [Int] = []
        for beat in 0..<23 {
            let click = classify(left, beat: beat)
            let expected = expectedDownbeats.contains(beat)
            print(String(format: "[measured] m15a offline beat %2d: %6.1f Hz  peak %.3f  → %@",
                         beat, click.frequency, click.peak,
                         click.isDownbeat ? "DOWNBEAT" : "beat"))
            // Unambiguous class: the right frequency AND the right amplitude.
            #expect(abs(click.frequency - (expected ? 1_600 : 1_000)) < 10, "beat \(beat)")
            #expect(expected ? click.peak > 0.42 : (click.peak > 0.28 && click.peak < 0.42),
                    "beat \(beat) peak \(click.peak)")
            if click.isDownbeat { measuredDownbeats.append(beat) }
        }
        print("[measured] m15a offline downbeats: \(measuredDownbeats) "
              + "(audit-correct 0,4,8,11,14,17,20; the old bug produced 0,4,8,12,16,20)")
        #expect(Set(measuredDownbeats) == expectedDownbeats)
    }

    /// Count-in scheduling honesty (m15-a gate 4): recording at beat 9 —
    /// inside the audit map's 3/4 region — pre-rolls 3-beat bars with the
    /// downbeat on the first click of each bar, rendered through the REAL
    /// `scheduleCountIn`. The count-in precedes the record beat in wall time
    /// and the beat domain does not extend backward, so bar length anchors to
    /// the meter AT THE RECORD BEAT (the countInPlan LOOKUP policy — the
    /// meter twin of the m12-b tempo lookup).
    @Test("count-in in a 3/4 region: 2 bars = 6 clicks, downbeats on clicks 0 and 3")
    func countInFollowsMeterAtRecordBeat() throws {
        let engine = AVAudioEngine()
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        let metronome = Metronome()
        metronome.attach(to: engine)
        try engine.start()
        defer { engine.stop() }

        let map = try auditMeterMap()
        let plan = Metronome.countInPlan(
            countInBars: 2, meterMap: map, tempoMap: TempoMap(constantBPM: 120), atBeat: 9)
        #expect(plan.clickBeats == 6)     // 2 bars × 3 beats — NOT 8
        #expect(plan.delaySeconds == 3.0) // 6 beats × 0.5 s

        metronome.scheduleCountIn(clickBeats: plan.clickBeats,
                                  tempoMap: TempoMap(constantBPM: 120),
                                  atBeat: 9, meterMap: map)
        metronome.start(at: nil)

        let frames = 168_000  // 3.5 s: 6 clicks + trailing silence
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var left: [Float] = []
        while left.count < frames {
            let request = AVAudioFrameCount(min(frames - left.count, 4_096))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            let source = try #require(buffer.floatChannelData)
            left.append(contentsOf:
                UnsafeBufferPointer(start: source[0], count: Int(buffer.frameLength)))
        }

        for click in 0..<6 {
            let c = classify(left, beat: click)
            let expected = click % 3 == 0  // 3-beat bars: downbeats at 0 and 3
            print(String(format: "[measured] m15a count-in click %d: %6.1f Hz  peak %.3f", click, c.frequency, c.peak))
            #expect(c.isDownbeat == expected, "count-in click \(click)")
        }
        // Nothing sounds past the 6th click (count-in only, no top-up).
        #expect(TestSignals.peak(left, in: 145_440..<168_000) < 0.001)
    }

    /// Plumbing pin, link 1 (m15-a gate 5): transport intents cache
    /// `transport.meterMap` ITSELF — the trivial default when the project has
    /// no meter changes, the override verbatim when it does. Headless-safe:
    /// both intents cache before their live-scheduling guards.
    @Test("transport intents cache the real meter map, never a constant")
    func intentsCacheRealMeterMap() throws {
        let engine = AudioEngine()
        var transport = TransportState()

        engine.metronomeChanged(transport)
        #expect(engine.clickMeterMapForTesting == MeterMap(constant: TimeSignature()))

        transport.isMetronomeEnabled = true
        transport.meterMapOverride = try auditMeterMap()
        engine.metronomeChanged(transport)
        #expect(engine.clickMeterMapForTesting == transport.meterMap)
        #expect(engine.clickMeterMapForTesting.changes.count == 2)

        // A second intent path (loopChanged) refreshes the same cache.
        transport.meterMapOverride = try MeterMap(changes: [
            MeterMap.Change(startBeat: 0, beatsPerBar: 5, beatUnit: 4),
            MeterMap.Change(startBeat: 10, beatsPerBar: 7, beatUnit: 8),
        ])
        engine.loopChanged(transport)
        #expect(engine.clickMeterMapForTesting == transport.meterMap)
        #expect(engine.clickMeterMapForTesting.beatsPerBar(atBeat: 12) == 7)
    }

    /// Plumbing pin, link 2 (m15-a gate 5, live smoke — headless machines
    /// return early): the meter map the `Metronome` API RECEIVES from every
    /// production schedule path is the transport's real map — the m14-c
    /// live-loop meter scenario (4/4 → 3/4 mid-loop), now through the REAL
    /// engine intents. Covers all four live call sites: start-with-loop,
    /// toggle-on-with-loop, start-linear, toggle-on-linear.
    @Test("live smoke: every live schedule path hands the Metronome the real meter map")
    func liveSchedulePathsCarryRealMap() async throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return  // headless machine without an output device
        }

        var transport = TransportState()
        transport.isPlaying = true
        transport.isMetronomeEnabled = true
        transport.meterMapOverride = try auditMeterMap()
        transport.isLoopEnabled = true
        transport.loopStartBeat = 0
        transport.loopEndBeat = 7

        // Site 1: startMetronome's loop branch (scheduleLoopClicks).
        engine.startPlayback(transport)
        try await Task.sleep(for: .milliseconds(150))
        let site1 = engine.metronomeMeterMapForTesting
        #expect(site1 == transport.meterMap)

        // Site 2: metronomeChanged's loop branch (toggle off → on mid-play).
        transport.isMetronomeEnabled = false
        engine.metronomeChanged(transport)
        transport.isMetronomeEnabled = true
        engine.metronomeChanged(transport)
        try await Task.sleep(for: .milliseconds(150))
        let site2 = engine.metronomeMeterMapForTesting
        #expect(site2 == transport.meterMap)
        engine.stopPlayback()

        // Site 3: startMetronome's linear branch (scheduleClicks).
        transport.isLoopEnabled = false
        engine.startPlayback(transport)
        try await Task.sleep(for: .milliseconds(150))
        let site3 = engine.metronomeMeterMapForTesting
        #expect(site3 == transport.meterMap)

        // Site 4: metronomeChanged's linear branch.
        transport.isMetronomeEnabled = false
        engine.metronomeChanged(transport)
        transport.isMetronomeEnabled = true
        engine.metronomeChanged(transport)
        try await Task.sleep(for: .milliseconds(150))
        let site4 = engine.metronomeMeterMapForTesting
        #expect(site4 == transport.meterMap)
        // The cache agrees end-to-end while rolling.
        #expect(engine.clickMeterMapForTesting == transport.meterMap)

        engine.stopPlayback()
        engine.shutdown()
        print("[measured] m15a live smoke: all four live schedule paths handed "
              + "the Metronome the 2-change map (4/4@0, 3/4@8) verbatim")
    }
}
