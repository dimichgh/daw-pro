import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m20-g: sampler sustain loops — the render GATE (§8.3), the sustain vs
/// continuous release semantics + pedal proof (§8.4), and the crossfade
/// click-bound / raw-wrap / no-loop byte-identity assertions (§8.5).
///
/// Direct-render idiom from `SamplerPlaybackTests`: 512-frame quanta,
/// hand-built event arrays, programmatic temp-dir fixtures. Graph 48 kHz,
/// files 44.1 kHz mono — the loop `[4410, 48510)` is exactly 1.0 s = 440
/// whole cycles of the 440 Hz fixture, so seams are phase-coherent and
/// zero-crossing counts are clean.
@MainActor
@Suite("Sampler sustain loops (m20-g)", .serialized)
struct SamplerLoopTests {
    private let sampleRate = 48_000.0

    // MARK: - Fixtures (written once per run)

    private struct Fixtures {
        let dir: URL
        /// 1.5 s @ 44.1 kHz mono = 66 150 frames, 440 Hz sine amp 0.5.
        let loop440: URL
        /// 1.5 s @ 44.1 kHz mono: frames [0, 48 510) 440 Hz; frames
        /// [48 510, 66 150) 880 Hz — the §8.4 tail marker.
        let loop440tail880: URL
    }

    private static var cachedFixtures: Fixtures?

    private func fixtures() throws -> Fixtures {
        if let cached = Self.cachedFixtures { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-sampler-loop-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let loop440 = dir.appendingPathComponent("loop440_44k1_mono.wav")
        try Self.writeMono(to: loop440) { frame, fileRate in
            0.5 * sin(2.0 * .pi * 440.0 * Double(frame) / fileRate)
        }
        let loop440tail880 = dir.appendingPathComponent("loop440tail880_44k1_mono.wav")
        try Self.writeMono(to: loop440tail880) { frame, fileRate in
            let frequency = frame < 48_510 ? 440.0 : 880.0
            return 0.5 * sin(2.0 * .pi * frequency * Double(frame) / fileRate)
        }
        let set = Fixtures(dir: dir, loop440: loop440, loop440tail880: loop440tail880)
        Self.cachedFixtures = set
        return set
    }

    /// 1.5 s mono Float32 WAV at 44.1 kHz (the SamplerPlaybackTests.writeMono
    /// idiom, stretched to 66 150 frames so the loop span is 1.0 s with a
    /// 0.5 s tail). Scoped so the AVAudioFile flushes before anyone reads it.
    private static func writeMono(to url: URL,
                                  sample: (Int, Double) -> Double) throws {
        let fileRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fileRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = 66_150
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw NSError(domain: "SamplerLoopTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        for frame in 0..<frames {
            data[0][frame] = Float(sample(frame, fileRate))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    // MARK: - Harness (the SamplerPlaybackTests direct-render idiom)

    private func makeSampler(_ params: SamplerParams) -> SamplerInstrument {
        let sampler = SamplerInstrument(params: params)
        sampler.prepare(sampleRate: sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return sampler
    }

    private func note(on: Int64, off: Int64, pitch: UInt8,
                      velocity: UInt8 = 127, id: UInt64) -> [ScheduledMIDIEvent] {
        [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                            kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
         ScheduledMIDIEvent(sampleTime: off, noteID: id,
                            kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
    }

    private func cc64(at time: Int64, down: Bool) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(sampleTime: time, noteID: 0,
                           kind: ScheduledMIDIEvent.controlChange,
                           pitch: 64, velocity: down ? 127 : 0)
    }

    /// Renders the instrument directly in 512-frame quanta, replicating
    /// InstrumentRenderer's slicing. Returns BOTH channels.
    private func renderDirect(
        _ instrument: SamplerInstrument,
        events unsorted: [ScheduledMIDIEvent],
        frames totalFrames: Int,
        quantum: Int = 512
    ) throws -> (left: [Float], right: [Float]) {
        let events = unsorted.sorted { a, b in
            if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
            let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            return a.noteID < b.noteID
        }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        let channels = try #require(buffer.floatChannelData)

        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(totalFrames)
        right.reserveCapacity(totalFrames)
        var cursor = 0
        var rendered = 0
        while rendered < totalFrames {
            let frames = min(quantum, totalFrames - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) {
                end += 1
            }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                let slice = UnsafeBufferPointer(rebasing: all[cursor..<end])
                instrument.render(events: slice, renderStart: Int64(rendered),
                                  frameCount: frames, output: output)
            }
            cursor = end
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))
            rendered += frames
        }
        return (left, right)
    }

    private func params(zones: [SamplerZone], oneShot: Bool = false,
                        gain: Double = 0.8) -> SamplerParams {
        SamplerParams(zones: zones, oneShot: oneShot,
                      attack: 0.001, release: 0.05, gain: gain)
    }

    /// Sign-change count over `range` — 2× the whole cycles of a steady tone.
    private func zeroCrossings(_ samples: [Float], in range: Range<Int>) -> Int {
        var count = 0
        for index in range.dropFirst() {
            let previous = samples[index - 1]
            let current = samples[index]
            if (previous < 0 && current >= 0) || (previous >= 0 && current < 0) {
                count += 1
            }
        }
        return count
    }

    private func maxSampleDelta(_ samples: [Float]) -> Float {
        var maximum: Float = 0
        for index in 1..<samples.count {
            maximum = max(maximum, abs(samples[index] - samples[index - 1]))
        }
        return maximum
    }

    // MARK: - 1. The render GATE (§8.3)

    @Test("GATE: a continuous loop holds a 1.5 s file for 10 s at full level, pitch-true, then releases to exact zeros")
    func continuousLoopGate() throws {
        let fixtures = try fixtures()
        // Loop [4410, 48510) = 1.0 s. Without loops the file exhausts at
        // 72 000 output frames (1.5 s); RMS > 0.2 through t = 10 s is ≥ 6.6×
        // the file's natural length.
        let zone = SamplerZone(audioFileURL: fixtures.loop440, rootPitch: 69,
                               loopMode: .continuous, loopStart: 4_410, loopEnd: 48_510)
        let out = try renderDirect(makeSampler(params(zones: [zone])),
                                   events: note(on: 0, off: 480_000, pitch: 69, id: 0),
                                   frames: 528_000)

        // Every 1 s window RMS > 0.2 (expected ≈ 0.283 = 0.5 × 0.8 × 1/√2).
        var minWindowRMS = Float.greatestFiniteMagnitude
        for second in 0..<10 {
            let rms = TestSignals.rms(out.left, in: second * 48_000..<(second + 1) * 48_000)
            minWindowRMS = min(minWindowRMS, rms)
            #expect(rms > 0.2, "window \(second)s..\(second + 1)s RMS \(rms)")
        }
        // Pitch integrity across ~6 wraps: 440 Hz → 880 crossings in the
        // 8–9 s window.
        let crossings = zeroCrossings(out.left, in: 384_000..<432_000)
        #expect(abs(crossings - 880) <= 4)
        // noteOff at 10 s → the 0.05 s release reaches EXACT zero and frees
        // the voice (true zeros from then on).
        let tailPeak = TestSignals.peak(out.left, in: 490_000..<528_000)
        #expect(tailPeak == 0)
        print("[measured] GATE — min 1 s-window RMS: \(minWindowRMS) (expected ≈ 0.283), "
              + "zero crossings 8–9 s: \(crossings) (expected 880 ± 4), "
              + "post-release peak: \(tailPeak) (expected exact 0)")
    }

    // MARK: - 2. Sustain vs continuous release semantics (§8.4)

    @Test("loop_sustain plays THROUGH the loop end into the 880 tail on release; loop_continuous never does")
    func sustainVersusContinuousRelease() throws {
        let fixtures = try fixtures()
        // Hold 4 s (≥ 3 wraps). At noteOff (t = 192 000 output frames) the
        // playhead sits at source frame 44 100 (192 000 × 0.91875 wrapped) —
        // 0.1 s of loop remainder, then the 880 Hz tail [48 510, 66 150),
        // freeing at endFrame (t = 216 000). Release 1.0 s keeps the tail
        // audible the whole way.
        func render(_ mode: SamplerLoopMode) throws -> [Float] {
            let zone = SamplerZone(audioFileURL: fixtures.loop440tail880, rootPitch: 69,
                                   release: 1.0,
                                   loopMode: mode, loopStart: 4_410, loopEnd: 48_510)
            return try renderDirect(makeSampler(params(zones: [zone])),
                                    events: note(on: 0, off: 192_000, pitch: 69, id: 0),
                                    frames: 220_000).left
        }

        let sustain = try render(.sustain)
        // Held windows: only 440 present (the loop never reaches the tail).
        for window in [48_000..<96_000, 96_000..<144_000, 144_000..<192_000] {
            let frequency = TestSignals.dominantFrequency(
                byZeroCrossings: sustain, sampleRate: sampleRate, in: window)
            #expect(abs(frequency - 440) < 8, "held window \(window): \(frequency) Hz")
        }
        // Loop remainder right after noteOff is still 440…
        let remainder = TestSignals.dominantFrequency(
            byZeroCrossings: sustain, sampleRate: sampleRate, in: 193_000..<196_000)
        #expect(abs(remainder - 440) < 8)
        // …then the playhead crosses into the tail: an 880-dominant window.
        let sustainTail = TestSignals.dominantFrequency(
            byZeroCrossings: sustain, sampleRate: sampleRate, in: 198_000..<210_000)
        #expect(abs(sustainTail - 880) < 8)
        // The voice frees at endFrame (t = 216 000) → exact zeros.
        let freedPeak = TestSignals.peak(sustain, in: 216_200..<220_000)
        #expect(freedPeak == 0)

        // The continuous twin NEVER reaches the tail — 440 through hold AND
        // release, still sounding at the render edge (release 1.0 s > window).
        let continuous = try render(.continuous)
        let continuousTail = TestSignals.dominantFrequency(
            byZeroCrossings: continuous, sampleRate: sampleRate, in: 198_000..<210_000)
        #expect(abs(continuousTail - 440) < 8)
        let continuousLate = TestSignals.dominantFrequency(
            byZeroCrossings: continuous, sampleRate: sampleRate, in: 210_000..<216_000)
        #expect(abs(continuousLate - 440) < 8)
        #expect(TestSignals.rms(continuous, in: 210_000..<216_000) > 0.05)
        print("[measured] sustain-vs-continuous — sustain tail: \(sustainTail) Hz "
              + "(expected 880 ± 8), continuous same window: \(continuousTail) Hz "
              + "(expected 440 ± 8), sustain freed peak: \(freedPeak)")
    }

    @Test("CC64 defers the release of a sustain loop: 440 persists past noteOff; pedal-up starts the release and the 880 tail appears")
    func pedalDeferredSustainLoop() throws {
        let fixtures = try fixtures()
        let zone = SamplerZone(audioFileURL: fixtures.loop440tail880, rootPitch: 69,
                               release: 1.0,
                               loopMode: .sustain, loopStart: 4_410, loopEnd: 48_510)
        var events = note(on: 0, off: 120_000, pitch: 69, id: 0)
        events.append(cc64(at: 96_000, down: true))    // pedal down before noteOff
        events.append(cc64(at: 192_000, down: false))  // pedal up = true release start
        let out = try renderDirect(makeSampler(params(zones: [zone])),
                                   events: events, frames: 220_000).left

        // Past noteOff, under the pedal: still looping 440 at full level.
        let held = TestSignals.dominantFrequency(
            byZeroCrossings: out, sampleRate: sampleRate, in: 150_000..<162_000)
        #expect(abs(held - 440) < 8)
        #expect(TestSignals.rms(out, in: 150_000..<162_000) > 0.2)
        // Pedal-up at 4 s: same wrapped playhead as the noteOff variant →
        // the 880 tail appears in the same window.
        let tail = TestSignals.dominantFrequency(
            byZeroCrossings: out, sampleRate: sampleRate, in: 198_000..<210_000)
        #expect(abs(tail - 880) < 8)
        print("[measured] pedal — post-noteOff frequency: \(held) Hz (expected 440 ± 8), "
              + "post-pedal-up tail: \(tail) Hz (expected 880 ± 8)")
    }

    // MARK: - 3. Crossfade click bound + raw wrap + no-loop byte identity (§8.5)

    @Test("phase-hostile loop bounds render click-free: full-render max sample delta ≤ 0.06")
    func phaseHostileSeamClickBound() throws {
        let fixtures = try fixtures()
        // Loop [4410, 48560) = 44 150 frames ≈ 440.5 periods — the seam lands
        // a half-cycle out of phase. A raw wrap would jump ≈ 0.8; the natural
        // max delta of the 0.4-amp rendered sine at 48 k is ≈ 0.023. The
        // equal-gain crossfade must keep every sample-to-sample step small.
        let zone = SamplerZone(audioFileURL: fixtures.loop440, rootPitch: 69,
                               loopMode: .continuous, loopStart: 4_410, loopEnd: 48_560)
        let out = try renderDirect(makeSampler(params(zones: [zone])),
                                   events: note(on: 0, off: 90_000_000, pitch: 69, id: 0),
                                   frames: 240_000).left
        let maxDelta = maxSampleDelta(out)
        #expect(maxDelta <= 0.06)
        // The loop is really looping — full level long past the 1.5 s file.
        #expect(TestSignals.rms(out, in: 192_000..<240_000) > 0.2)
        print("[measured] click bound — max |x[n]−x[n−1]| over 5 s: \(maxDelta) "
              + "(bound 0.06, natural sine delta ≈ 0.023)")
    }

    @Test("loopStart 0 degrades to a raw wrap (no pre-start material): still loops, stays finite; clicks accepted")
    func loopStartZeroRawWrap() throws {
        let fixtures = try fixtures()
        // loopXfade = min(512, 0, len) = 0 — documented degradation: no
        // crossfade material exists before frame 0. The test asserts ONLY
        // that the loop engages and the output stays finite; the half-phase
        // seam click is accepted and documented for loopStart-0.
        let zone = SamplerZone(audioFileURL: fixtures.loop440, rootPitch: 69,
                               loopMode: .continuous, loopStart: 0, loopEnd: 48_560)
        let out = try renderDirect(makeSampler(params(zones: [zone])),
                                   events: note(on: 0, off: 90_000_000, pitch: 69, id: 0),
                                   frames: 240_000).left
        let lateRMS = TestSignals.rms(out, in: 192_000..<240_000)
        let allFinite = out.allSatisfy { $0.isFinite }
        #expect(lateRMS > 0.2)                      // still looping at 4–5 s
        #expect(allFinite)                          // raw wrap never blows up
        print("[measured] raw wrap — 4–5 s RMS: \(lateRMS) (loop engaged), all finite: \(allFinite)")
    }

    @Test("A/B: nil loop fields render the pre-m20-g playback law byte-for-byte on the loop fixture")
    func nilLoopFieldsByteIdentical() throws {
        let fixtures = try fixtures()
        // The non-loop twin of the GATE zone (loop fields nil) must follow
        // the legacy law exactly — replayed in-test per frame (the
        // SamplerPlaybackTests nil-collapse idiom): attack ramp to 1, hold,
        // release from noteOff, level×amp×outputGain, linear interpolation
        // toward 0 at the file edge, free at the end frame.
        let zone = SamplerZone(audioFileURL: fixtures.loop440, rootPitch: 69, gain: 0.9)
        let out = try renderDirect(
            makeSampler(params(zones: [zone])),
            events: note(on: 0, off: 60_000, pitch: 69, velocity: 100, id: 0),
            frames: 120_000)

        let source = try TestSignals.readFile(fixtures.loop440)[0]
        let frameCount = source.count
        #expect(frameCount == 66_150)
        let amp = Float(100) / 127.0 * Float(0.9)          // velocity/127 × zone.gain
        let outputGain = Float(0.8)
        let attackStep = Float(1.0 / max(1.0, 0.001 * sampleRate))
        let releaseSlope = Float(1.0 / max(1.0, 0.05 * sampleRate))
        let increment = exp2((69.0 - 69.0) / 12.0) * 44_100.0 / sampleRate
        var expected = [Float](repeating: 0, count: 120_000)
        var level: Float = 0
        var releaseFrom: Float = 0
        var releasing = false
        var alive = true
        var position = 0.0
        for frame in 0..<120_000 where alive {
            if frame == 60_000 {                           // noteOff lands here
                releasing = true
                releaseFrom = level
            }
            if releasing {
                level -= releaseFrom * releaseSlope
                if level <= 0 { alive = false; continue }
            } else if level < 1 {
                level += attackStep
                if level > 1 { level = 1 }
            }
            let idx = Int(position)
            if idx >= frameCount { alive = false; continue }
            let frac = Float(position - Double(idx))
            let s0 = source[idx]
            let s1 = idx + 1 < frameCount ? source[idx + 1] : 0
            expected[frame] = ((s0 + (s1 - s0) * frac) * (level * amp)) * outputGain
            position += increment
        }

        var firstMismatch = -1
        for frame in 0..<120_000 where out.left[frame] != expected[frame] {
            firstMismatch = frame
            break
        }
        #expect(out.left == expected)
        #expect(out.left == out.right)                     // mono, unity pan gains
        #expect(TestSignals.peak(out.left, in: 1_200..<60_000) > 0.25)  // the null means something
        print("[measured] no-loop A/B — first mismatch frame: \(firstMismatch) "
              + "(-1 = byte-identical)")
    }
}
