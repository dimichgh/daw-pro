import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m12-c Phase B — multi-segment engine correctness (design §9-B).
///
/// The canonical fixture map everywhere here: 120 BPM → 90 BPM at beat 4,
/// 48 kHz. Every expected sample position is an exact closed form the test
/// computes itself (the "event-timestamp tests assert `==`" discipline,
/// ARCHITECTURE.md): S(b) = b·(60/120) for b ≤ 4, 2 + (b−4)·(60/90) after.
///   S(3.9) = 1.95 s → 93 600      S(4.1) = 2 + 0.1·(2/3) → 99 200
///   S(4.5) = 2⅓ s   → 112 000     S(5)   = 2⅔ s          → 128 000
@MainActor
@Suite("Tempo map Phase B — multi-segment engine correctness", .serialized)
struct TempoMapPhaseBTests {

    private static func boundaryMap() throws -> TempoMap {
        try TempoMap(segments: [
            .init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 90),
        ])
    }

    // MARK: - Gate 1a: MIDI event frames (pure build math)

    @Test("MIDI event frames are the exact integral across the boundary; no-chase untouched")
    func midiEventFramesAcrossBoundary() throws {
        let map = try Self.boundaryMap()
        let rate = 48_000.0
        let clip = Clip(name: "n", startBeat: 0, lengthBeats: 16, notes: [
            MIDINote(pitch: 60, startBeat: 3.9, lengthBeats: 0.05),   // fully pre-boundary
            MIDINote(pitch: 64, startBeat: 4.1, lengthBeats: 0.4),    // fully post-boundary
            MIDINote(pitch: 67, startBeat: 3.5, lengthBeats: 1.0),    // CROSSES the boundary
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 0, tempoMap: map, sampleRate: rate)
        #expect(events.count == 6)

        // Closed-form expectations, computed HERE (not read back from the map).
        let on39 = Int64((rate * (3.9 * (60.0 / 120.0))).rounded())
        let off395 = Int64((rate * (3.95 * (60.0 / 120.0))).rounded())
        let on41 = Int64((rate * (4.0 * (60.0 / 120.0) + 0.1 * (60.0 / 90.0))).rounded())
        let off45 = Int64((rate * (4.0 * (60.0 / 120.0) + 0.5 * (60.0 / 90.0))).rounded())
        let on35 = Int64((rate * (3.5 * (60.0 / 120.0))).rounded())
        #expect(on39 == 93_600)
        #expect(off395 == 94_800)
        #expect(on41 == 99_200)
        #expect(off45 == 112_000)
        #expect(on35 == 84_000)

        func event(pitch: UInt8, kind: UInt8) -> ScheduledMIDIEvent? {
            events.first { $0.pitch == pitch && $0.kind == kind }
        }
        #expect(event(pitch: 60, kind: ScheduledMIDIEvent.noteOn)?.sampleTime == on39)
        #expect(event(pitch: 60, kind: ScheduledMIDIEvent.noteOff)?.sampleTime == off395)
        #expect(event(pitch: 64, kind: ScheduledMIDIEvent.noteOn)?.sampleTime == on41)
        #expect(event(pitch: 64, kind: ScheduledMIDIEvent.noteOff)?.sampleTime == off45)
        #expect(event(pitch: 67, kind: ScheduledMIDIEvent.noteOn)?.sampleTime == on35)
        // The crossing note's off integrates piecewise to the SAME frame as
        // pitch 64's off (both end at beat 4.5).
        #expect(event(pitch: 67, kind: ScheduledMIDIEvent.noteOff)?.sampleTime == off45)

        // No-chase (beat-domain guard, untouched by the map): scheduling from
        // beat 4 drops BOTH events of every note whose onset is < 4.
        let chased = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 4.0, tempoMap: map, sampleRate: rate)
        #expect(chased.count == 2)
        let onFrom4 = Int64((rate * (0.1 * (60.0 / 90.0))).rounded())
        #expect(onFrom4 == 3_200)
        #expect(chased.first { $0.kind == ScheduledMIDIEvent.noteOn }?.sampleTime == onFrom4)
    }

    // MARK: - Gate 1b: automation breakpoints (pure build math)

    @Test("automation breakpoint sample times are the exact integral across the boundary")
    func automationBreakpointsAcrossBoundary() throws {
        let map = try Self.boundaryMap()
        let points = [
            AutomationPoint(beat: 3.9, value: 0.9),
            AutomationPoint(beat: 4.1, value: 0.4),
        ]
        let breakpoints = AutomationSchedule.buildBreakpoints(
            points: points, fromBeat: 0, tempoMap: map, sampleRate: 48_000)
        #expect(breakpoints.count == 2)
        #expect(breakpoints[0].sampleTime == 93_600)
        #expect(breakpoints[1].sampleTime == 99_200)
        // Non-zero schedule anchor: the integral is FROM the anchor beat.
        let anchored = AutomationSchedule.buildBreakpoints(
            points: points, fromBeat: 4.0, tempoMap: map, sampleRate: 48_000)
        let expected39From4 = Int64((48_000.0 * -(0.1 * (60.0 / 120.0))).rounded())
        #expect(anchored[0].sampleTime == expected39From4)   // signed, pre-anchor
        #expect(anchored[1].sampleTime == 3_200)
    }

    // MARK: - Gate 1c: derivedBeats inverse (the anchor formula)

    @Test("map inverse: beat(from: 0, elapsed: S(4.1)) == 4.1 to 1e-12")
    func derivedBeatsInverseAcrossBoundary() throws {
        let map = try Self.boundaryMap()
        // The exact elapsed seconds a wall clock would report at beat 4.1.
        let elapsed = 4.0 * (60.0 / 120.0) + 0.1 * (60.0 / 90.0)
        #expect(abs(map.beat(from: 0, elapsedSeconds: elapsed) - 4.1) <= 1e-12)
        // Round-trip through the map's own integral, and from a mid-segment
        // anchor (the restart-from-derived-beats shape).
        #expect(abs(map.beat(from: 0, elapsedSeconds: map.seconds(fromBeatZeroTo: 4.1)) - 4.1) <= 1e-12)
        #expect(abs(map.beat(from: 3.9, elapsedSeconds: map.seconds(from: 3.9, to: 4.1)) - 4.1) <= 1e-12)
        // Pre-boundary inverse stays the plain linear form.
        #expect(map.beat(from: 0, elapsedSeconds: 1.95) == 3.9)
    }

    // MARK: - Gate 1d: metronome clicks (offline render)

    @Test("metronome click at beat 5 lands exactly at frame 128 000 across the boundary")
    func metronomeClickAcrossBoundary() throws {
        let map = try Self.boundaryMap()
        let audio = try OfflineRenderer().render(
            tracks: [], tempoMap: map, fromBeat: 0, durationSeconds: 3.0,
            metronomeEnabled: true)
        let left = audio.channelData[0]
        #expect(left.count == 144_000)
        #expect(left.allSatisfy { $0.isFinite })

        // Self-calibrated == discipline: the beat-3 click (non-downbeat, mid
        // segment 0, exactly frame 72 000 = S(3)·48k) measures the buffer's
        // leading-zero count j; the beat-5 click (same buffer) must then
        // start at exactly 128 000 + j — asserted as an exact 56 000-frame
        // difference between the two measured onsets.
        let beat3Onset = try #require((70_000..<73_440).first { abs(left[$0]) > 0 })
        let j = beat3Onset - 72_000
        print("[measured] beat-3 click onset frame \(beat3Onset) (leading zeros j = \(j))")
        #expect((0...2).contains(j))

        // Strict digital silence between the end of the beat-4 click
        // (96 000 + 1 440) and the expected beat-5 onset.
        #expect(TestSignals.peak(left, in: 97_450..<127_995) == 0)

        let beat5Onset = try #require((97_450..<144_000).first { abs(left[$0]) > 0 })
        print("[measured] beat-5 click onset frame \(beat5Onset) (expected \(128_000 + j))")
        #expect(beat5Onset - beat3Onset == 56_000)
        #expect(beat5Onset == 128_000 + j)

        // The boundary-beat click itself (beat 4, downbeat): self-calibrated
        // against the beat-0 downbeat click at frame 0.
        let beat0Onset = try #require((0..<1_440).first { abs(left[$0]) > 0 })
        let beat4Onset = try #require((74_000..<97_440).first { abs(left[$0]) > 0 })
        #expect(beat4Onset - beat0Onset == 96_000)
    }

    // MARK: - Gate 1e: clip scheduling (offline render)

    @Test("audio clip at beat 4.1 sounds exactly at frame 99 200 across the boundary")
    func clipOnsetAcrossBoundary() throws {
        let map = try Self.boundaryMap()
        let fixtures = try TestSignals.fixtures()
        let track = Track(name: "T", kind: .audio, clips: [
            Clip(name: "clip", startBeat: 4.1, lengthBeats: 2,
                 audioFileURL: fixtures.cos1k48),
        ])
        let audio = try OfflineRenderer().render(
            tracks: [track], tempoMap: map, fromBeat: 0, durationSeconds: 3.0)
        let left = audio.channelData[0]
        #expect(left.allSatisfy { $0.isFinite })
        // Exact digital silence before the onset frame, then the cosine's
        // first-frame peak exactly ON it (fixture frame 0 = +0.5).
        #expect(TestSignals.peak(left, in: 0..<99_200) == 0)
        let onset = try #require(TestSignals.firstFrame(in: left, exceeding: 0.1))
        print("[measured] clip onset frame \(onset) (expected 99 200)")
        #expect(onset == 99_200)
    }

    // MARK: - Gate 1f: fade piece plan (pure build math)

    @Test("piecePlan integrates piecewise for a clip crossing the boundary; trivial map bit-parity")
    func fadePiecePlanAcrossBoundary() throws {
        let map = try Self.boundaryMap()
        // Clip [3, 6): fade-in 0.5 (inside segment 0), fade-out 1 (inside
        // segment 1), the body crossing the boundary at beat 4.
        let clip = Clip(name: "x", startBeat: 3, lengthBeats: 3,
                        audioFileURL: URL(fileURLWithPath: "/tmp/unused.wav"),
                        fadeInBeats: 0.5, fadeOutBeats: 1.0)
        // Closed forms at 48 kHz file rate:
        //   length  = S(3→6)·48k = (0.5 + 2·(2/3))·48k = 88 000
        //   fadeIn  = S(3→3.5)·48k = 0.25·48k          = 12 000
        //   fadeOut = S(5→6)·48k = (2/3)·48k           = 32 000 → outStart 56 000
        let plan = ClipFadeBake.piecePlan(
            clip: clip, tempoMap: map, fileRate: 48_000,
            segmentStart: 0, segmentFrameCount: 88_000)
        #expect(plan.segmentStart == 0)
        #expect(plan.fadeInEnd == 12_000)
        #expect(plan.fadeOutStart == 56_000)
        #expect(plan.segmentEnd == 88_000)
        #expect(plan.fadeInFrames + plan.middleFrames + plan.fadeOutFrames == 88_000)

        // Trivial-map fast path: bit-identical to the legacy constant-rate
        // arithmetic (the null-case byte-gate contract, re-pinned here).
        let trivial = TempoMap(constantBPM: 120)
        let perBeat = 48_000.0 * 60.0 / 120.0
        let legacy = ClipFadeBake.piecePlan(
            clip: clip, tempoMap: trivial, fileRate: 48_000,
            segmentStart: 0, segmentFrameCount: Int64((3.0 * perBeat).rounded()))
        #expect(legacy.fadeInEnd == Int64((0.5 * perBeat).rounded()))
        #expect(legacy.fadeOutStart == Int64((3.0 * perBeat).rounded()) - Int64((1.0 * perBeat).rounded()))
        #expect(legacy.segmentEnd == 72_000)
    }

    // MARK: - Gate 1g: fade envelope evaluation (piecewise frame→beat)

    @Test("applyEnvelope evaluates the beat-domain fade at the piecewise-warped frame position")
    func fadeEnvelopeAcrossBoundary() throws {
        let map = try Self.boundaryMap()
        // Clip [3, 6), LINEAR fade-out over its last beat [5, 6). Frame
        // 72 000 (clip-relative) = 1.5 wall seconds after the clip start
        // = beat 5.5 = clip-relative beat 2.5 = fade progress 0.5 exactly →
        // linear gain 0.5, exact in FP.
        let clip = Clip(name: "x", startBeat: 3, lengthBeats: 3,
                        audioFileURL: URL(fileURLWithPath: "/tmp/unused.wav"),
                        fadeOutBeats: 1.0)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            channels[channel][0] = 1.0
            channels[channel][1] = 1.0
        }
        ClipFadeBake.applyEnvelope(buffer: buffer, clip: clip,
                                   clipRelativeStartFrame: 72_000,
                                   tempoMap: map, fileRate: 48_000)
        #expect(channels[0][0] == 0.5)
        #expect(channels[1][0] == 0.5)
        // Next frame: strictly deeper into the fade, still sane.
        #expect(channels[0][1] < 0.5 && channels[0][1] > 0.49)

        // Under the OLD constant-rate math (frames/perBeat at the clip-start
        // segment), frame 72 000 would have read beat 3.0 → gain 0 — pin that
        // the piecewise path did NOT do that.
        #expect(channels[0][0] != 0.0)
    }

    // MARK: - Gate 2: crossfade seam continuity across the boundary

    @Test("equal-power crossfade spanning the boundary: windowed power spread <= 0.05 dB")
    func crossfadeSeamContinuityAcrossBoundary() throws {
        let map = try Self.boundaryMap()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m12c-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urlA = dir.appendingPathComponent("noiseA.wav")
        let urlB = dir.appendingPathComponent("noiseB.wav")
        // Decorrelated fixtures (independent seeds/channels), block-RMS-
        // normalized so windowed power measures the CROSSFADE envelope, not
        // noise luck. Deterministic — reruns are identical.
        try Self.writeBlockNormalizedNoise(to: urlA, seconds: 8, sampleRate: 48_000,
                                           rms: 0.25, seed: 0x5EED_A)
        try Self.writeBlockNormalizedNoise(to: urlB, seconds: 8, sampleRate: 48_000,
                                           rms: 0.25, seed: 0x5EED_B)

        // The m11-d bowtie shape, constructed directly: seam at beat 4 (the
        // tempo boundary), overlap [3.5, 4.5], equal-power complements.
        let clipA = Clip(name: "A", startBeat: 0, lengthBeats: 4.5,
                         audioFileURL: urlA,
                         fadeOutBeats: 1.0, fadeOutCurve: .equalPower)
        let clipB = Clip(name: "B", startBeat: 3.5, lengthBeats: 4.5,
                         audioFileURL: urlB, startOffsetSeconds: 1.0,
                         fadeInBeats: 1.0, fadeInCurve: .equalPower)
        let track = Track(name: "T", kind: .audio, clips: [clipA, clipB])
        let audio = try OfflineRenderer().render(
            tracks: [track], tempoMap: map, fromBeat: 0,
            durationSeconds: 4.0 * 0.5 + 4.0 * (60.0 / 90.0) + 0.1)
        #expect(audio.channelData.allSatisfy { $0.allSatisfy(\.isFinite) })

        // Sliding 1.0 s windows, 0.1 s hop, spanning flat noise → crossfade →
        // flat noise: wall [1.0, 3.4] s covers beats [2, 6.1] around the
        // overlap's wall span [S(3.5), S(4.5)] = [1.75, 2.333].
        let rate = 48_000
        let window = 48_000
        var spreads: [Double] = []
        var start = rate
        while start + window <= Int(3.4 * Double(rate)) {
            var sum = 0.0
            for channel in audio.channelData {
                for index in start..<(start + window) {
                    sum += Double(channel[index]) * Double(channel[index])
                }
            }
            spreads.append(sum / Double(window * audio.channelData.count))
            start += 4_800
        }
        let maxMS = try #require(spreads.max())
        let minMS = try #require(spreads.min())
        let spreadDb = 10.0 * log10(maxMS / minMS)
        print(String(format: "[measured] m12-c seam spread %.4f dB over %d windows "
                     + "(gate <= 0.05 dB)", spreadDb, spreads.count))
        #expect(spreadDb <= 0.05)
    }

    // MARK: - Noise fixture writer (gate 2)

    /// Stereo Float32 WAV of uniform white noise, per-channel independent
    /// streams (SplitMix64), each 256-frame block scaled to EXACTLY `rms` so
    /// windowed power is flat by construction (the seam gate measures the
    /// crossfade envelope, not noise variance).
    private static func writeBlockNormalizedNoise(
        to url: URL, seconds: Double, sampleRate: Double, rms: Float, seed: UInt64
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(seconds * sampleRate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 2,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            throw NSError(domain: "TempoMapPhaseBTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        var stateL = seed
        var stateR = seed ^ 0x9E37_79B9_7F4A_7C15
        func next(_ state: inout UInt64) -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            // Uniform in [-1, 1).
            return Float(Int64(bitPattern: z)) / Float(Int64.max)
        }
        let block = 256
        for channel in 0..<2 {
            var state = channel == 0 ? stateL : stateR
            var frame = 0
            while frame < frames {
                let count = min(block, frames - frame)
                var sumSquares: Double = 0
                for offset in 0..<count {
                    let value = next(&state)
                    channels[channel][frame + offset] = value
                    sumSquares += Double(value) * Double(value)
                }
                let blockRMS = (sumSquares / Double(count)).squareRoot()
                if blockRMS > 0 {
                    let scale = Float(Double(rms) / blockRMS)
                    for offset in 0..<count {
                        channels[channel][frame + offset] *= scale
                    }
                }
                frame += count
            }
            if channel == 0 { stateL = state } else { stateR = state }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }
}
