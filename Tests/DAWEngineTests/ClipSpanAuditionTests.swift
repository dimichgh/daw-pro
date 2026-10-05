import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// I1 (hear the note while editing it, design
// `2026-09-24-pitch-editor-interaction-batch.md` §4): the pure half of the
// engine's audition voice, nonisolated and device-free.
//
//  · The OUTPUT-FRAME ↔ SOURCE-SECOND inverse (`StretchCurvePlan.outputFrame`)
//    round-trips the one forward mapping, on the constant form and on a curve
//    plan, at ratios 1, 1.5 and 0.5.
//  · The reader (`ClipSpanAuditionReader`) cuts the span through that mapping,
//    converts to the graph's rate and channel count, fades both ends, applies
//    the level, and scrubs NaN and denormals.
//  · The test's own YIN is checked against known tones before any physics
//    gate leans on it.
//
// The engine-bound gates (the file playback plays, the physics after a real
// edit, latest wins, the render-complete handshake) live in the existing
// `AuditionEngineTests` suite, and the lane's transparency and rendered-output
// gates in `ReferenceLaneTransparencyTests`, so no `@MainActor` suite is added.

/// Nonisolated signal helpers for the I1 gates. `TestSignals` is `@MainActor`,
/// and this suite is not, so the few helpers it needs live here.
enum I1Signals {

    static func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-i1-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Phase-continuous sine, piecewise constant in frequency: each piece
    /// plays `hz` for `seconds`. `ramp` multiplies by a 0 → 1 ramp across the
    /// whole file, so a position in the file is observable from level.
    static func tone(pieces: [(seconds: Double, hz: Double)], sampleRate: Double = 48_000,
                     amplitude: Float = 0.5, ramp: Bool = false) -> [Float] {
        var samples: [Float] = []
        var phase = 0.0
        let total = pieces.reduce(0) { $0 + Int(($1.seconds * sampleRate).rounded()) }
        samples.reserveCapacity(total)
        for piece in pieces {
            let frames = Int((piece.seconds * sampleRate).rounded())
            let step = 2 * Double.pi * piece.hz / sampleRate
            for _ in 0..<frames {
                let level = ramp ? Float(samples.count) / Float(max(1, total)) : 1
                samples.append(amplitude * level * Float(sin(phase)))
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
        }
        return samples
    }

    /// Float32 WAV of `planar` (one array per channel).
    static func write(_ planar: [[Float]], sampleRate: Double, to url: URL) throws {
        let channels = planar.count
        let frames = planar.first?.count ?? 0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(max(1, frames))),
              let data = buffer.floatChannelData else {
            throw EngineError.renderFailed("I1 fixture buffer allocation failed")
        }
        for (channel, samples) in planar.enumerated() {
            for (frame, sample) in samples.enumerated() { data[channel][frame] = sample }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    /// Every sample of a file, one array per channel, and its rate.
    static func read(_ url: URL) throws -> (planar: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = Int(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(max(1, frames))) else {
            throw EngineError.renderFailed("I1 read buffer allocation failed")
        }
        var planar = [[Float]](repeating: [], count: Int(format.channelCount))
        while planar[0].count < frames {
            try file.read(into: buffer)
            let got = Int(buffer.frameLength)
            guard got > 0, let data = buffer.floatChannelData else { break }
            for channel in planar.indices {
                planar[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: got))
            }
        }
        return (planar, format.sampleRate)
    }

    /// A buffer's samples, one array per channel.
    static func planar(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: frames))
        }
    }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)).squareRoot()
    }

    static func cents(_ hz: Double, from reference: Double) -> Double {
        1200 * log2(hz / reference)
    }

    /// ONE frame of YIN (de Cheveigné & Kawahara 2002): the difference
    /// function, its cumulative-mean normalisation, the first dip under
    /// `threshold` walked to its local minimum, and a parabolic refinement.
    /// nil when no lag dips under `unvoicedAbove` (an unvoiced frame).
    /// Written for these gates; it shares no code with the product's
    /// detectors, so it is an independent instrument.
    static func yinHz(_ x: ArraySlice<Float>, sampleRate: Double, minHz: Double, maxHz: Double,
                      threshold: Double = 0.10, unvoicedAbove: Double = 0.30) -> Double? {
        let samples = Array(x)
        let tauMin = max(2, Int(sampleRate / maxHz))
        let tauMax = min(samples.count / 2, Int((sampleRate / minHz).rounded(.up)))
        guard tauMax > tauMin + 2 else { return nil }
        let window = samples.count - tauMax - 1
        guard window > 0 else { return nil }
        var diff = [Double](repeating: 0, count: tauMax + 2)
        for tau in 1...(tauMax + 1) {
            var sum = 0.0
            for j in 0..<window {
                let d = Double(samples[j]) - Double(samples[j + tau])
                sum += d * d
            }
            diff[tau] = sum
        }
        var cmnd = [Double](repeating: 1, count: tauMax + 2)
        var running = 0.0
        for tau in 1...(tauMax + 1) {
            running += diff[tau]
            cmnd[tau] = running > 0 ? diff[tau] * Double(tau) / running : 1
        }
        var chosen: Int?
        var tau = tauMin
        while tau <= tauMax {
            if cmnd[tau] < threshold {
                while tau + 1 <= tauMax, cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                chosen = tau
                break
            }
            tau += 1
        }
        if chosen == nil {
            let best = (tauMin...tauMax).min { cmnd[$0] < cmnd[$1] } ?? tauMin
            guard cmnd[best] < unvoicedAbove else { return nil }
            chosen = best
        }
        guard let t = chosen, t > 1, t < tauMax + 1 else { return nil }
        let (a, b, c) = (cmnd[t - 1], cmnd[t], cmnd[t + 1])
        let curvature = a + c - 2 * b
        let shift = curvature != 0 ? 0.5 * (a - c) / curvature : 0
        return sampleRate / (Double(t) + max(-1, min(1, shift)))
    }

    /// The median of per-frame YIN readings across `x` (2048-sample frames,
    /// 512 hop); nil when no frame is voiced.
    static func medianYinHz(_ x: ArraySlice<Float>, sampleRate: Double, minHz: Double,
                            maxHz: Double, frame: Int = 2_048, hop: Int = 512) -> Double? {
        var readings: [Double] = []
        var start = x.startIndex
        while start + frame <= x.endIndex {
            if let hz = yinHz(x[start..<(start + frame)], sampleRate: sampleRate,
                              minHz: minHz, maxHz: maxHz) {
                readings.append(hz)
            }
            start += hop
        }
        guard !readings.isEmpty else { return nil }
        readings.sort()
        return readings[readings.count / 2]
    }
}

@Suite("I1 clip-span audition — the inverse mapping, the voice's buffer, the test's YIN")
struct ClipSpanAuditionTests {

    // MARK: - The inverse mapping

    @Test("I1 outputFrame(forSourceSecond:) inverts sourceSecond(forOutputFrame:) exactly at ratios 1, 1.5 and 0.5 (the constant form)")
    func outputFrameRoundTripsOnTheConstantMapping() {
        // Known values, written as literals: source second 1.0 is delivered
        // output frame ratio × rate.
        let known: [(ratio: Double, rate: Double, frame: Int)] = [
            (1, 48_000, 48_000), (1.5, 48_000, 72_000), (0.5, 48_000, 24_000),
            (1, 44_100, 44_100), (1.5, 44_100, 66_150), (0.5, 44_100, 22_050),
        ]
        for row in known {
            #expect(StretchCurvePlan.outputFrame(forSourceSecond: 1.0, ratio: row.ratio,
                                                 sampleRate: row.rate) == row.frame,
                    "ratio \(row.ratio) @ \(row.rate)")
        }
        for ratio in [1.0, 1.5, 0.5] {
            for rate in [48_000.0, 44_100.0] {
                // Frame → second → frame is exact on every frame tried.
                for frame in [0, 1, 2, 3, 7, 1_000, 47_999, 48_000, 72_001, 1_234_567] {
                    let second = StretchCurvePlan.sourceSecond(forOutputFrame: frame, ratio: ratio,
                                                               sampleRate: rate)
                    #expect(StretchCurvePlan.outputFrame(forSourceSecond: second, ratio: ratio,
                                                         sampleRate: rate) == frame,
                            "frame \(frame) at ratio \(ratio) @ \(rate)")
                }
                // Second → frame is the FIRST frame at or after the second.
                for second in [0.000_01, 0.123_456, 0.5, 1.7, 2.25, 33.3] {
                    let frame = StretchCurvePlan.outputFrame(forSourceSecond: second, ratio: ratio,
                                                             sampleRate: rate)
                    #expect(StretchCurvePlan.sourceSecond(forOutputFrame: frame, ratio: ratio,
                                                          sampleRate: rate) >= second)
                    #expect(frame == 0 || StretchCurvePlan.sourceSecond(
                        forOutputFrame: frame - 1, ratio: ratio, sampleRate: rate) < second)
                }
            }
        }
        // Unusable inputs answer 0, an unreachable second the search limit.
        #expect(StretchCurvePlan.outputFrame(forSourceSecond: .nan, ratio: 1, sampleRate: 48_000) == 0)
        #expect(StretchCurvePlan.outputFrame(forSourceSecond: -1, ratio: 1, sampleRate: 48_000) == 0)
        #expect(StretchCurvePlan.outputFrame(forSourceSecond: 1, ratio: 0, sampleRate: 48_000) == 0)
        #expect(StretchCurvePlan.outputFrame(forSourceSecond: 1, ratio: 1, sampleRate: 0) == 0)
        #expect(StretchCurvePlan.outputFrame(forSourceSecond: .infinity, ratio: 1, sampleRate: 48_000)
            == StretchCurvePlan.outputFrameSearchLimit)
    }

    @Test("I1 on a CURVE plan the inverse round-trips too and agrees with the constant form: a pitch curve never moves time")
    func outputFrameOnACurvePlanMatchesTheConstantForm() throws {
        let edits = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.2, endSeconds: 0.8, detectedHz: 220,
                        detectedConfidence: 0.9, pitchOffsetCents: 200),
        ])
        for ratio in [1.0, 1.5, 0.5] {
            let plan = try #require(StretchCurvePlan.make(
                editSet: edits, clipPitchShiftSemitones: 0, sampleRate: 48_000, ratio: ratio),
                "a +200 c edit must build a curve plan")
            for frame in [0, 1, 5, 9_600, 48_000, 71_999, 72_000, 500_000] {
                #expect(plan.outputFrame(forSourceSecond: plan.sourceSecond(forOutputFrame: frame))
                    == frame, "curve plan, frame \(frame), ratio \(ratio)")
            }
            for second in [0.1, 0.2, 0.5, 0.8, 1.25] {
                #expect(plan.outputFrame(forSourceSecond: second)
                    == StretchCurvePlan.outputFrame(forSourceSecond: second, ratio: ratio,
                                                    sampleRate: 48_000))
            }
            // The curve itself is live on this plan (the control: it is a
            // curve plan, not an identity one).
            #expect(abs(plan.semitones(atOutputFrame: plan.outputFrame(forSourceSecond: 0.5)) - 2)
                < 1e-9)
        }
    }

    // MARK: - The reader

    private func request(_ url: URL, ratio: Double = 1, start: Double, end: Double,
                         gain: Double = 1, fade: Double = 0.005) -> ClipSpanAuditionRequest {
        ClipSpanAuditionRequest(fileURL: url, ratio: ratio, startSourceSeconds: start,
                                endSourceSeconds: end, gain: gain, fadeSeconds: fade)
    }

    @Test("I1 the reader cuts the span through the plan: source 1.0–1.2 s is file frames 72000..<86400 at ratio 1.5, clamped to the file")
    func readerFrameRangeMapsThroughThePlan() {
        let url = URL(fileURLWithPath: "/nonexistent/i1.caf")
        #expect(ClipSpanAuditionReader.frameRange(for: request(url, ratio: 1.5, start: 1.0, end: 1.2),
                                                  fileLength: 200_000, fileSampleRate: 48_000)
            == 72_000..<86_400)
        #expect(ClipSpanAuditionReader.frameRange(for: request(url, ratio: 1, start: 1.0, end: 1.2),
                                                  fileLength: 200_000, fileSampleRate: 48_000)
            == 48_000..<57_600)
        #expect(ClipSpanAuditionReader.frameRange(for: request(url, ratio: 0.5, start: 1.0, end: 1.2),
                                                  fileLength: 200_000, fileSampleRate: 48_000)
            == 24_000..<28_800)
        // Clamped at the file's end, and empty wholly past it.
        #expect(ClipSpanAuditionReader.frameRange(for: request(url, ratio: 1.5, start: 1.0, end: 1.2),
                                                  fileLength: 80_000, fileSampleRate: 48_000)
            == 72_000..<80_000)
        #expect(ClipSpanAuditionReader.frameRange(for: request(url, ratio: 1.5, start: 3.0, end: 3.5),
                                                  fileLength: 80_000, fileSampleRate: 48_000).isEmpty)
    }

    @Test("I1 fades reach exactly zero at both ends and unity in the middle; the level multiplies; NaN and denormals come out +0")
    func shapedFadesGainAndGuards() {
        let frames = 1_000, fade = 240
        func s(_ x: Float, _ frame: Int, gain: Float = 1) -> Float {
            ClipSpanAuditionReader.shaped(x, frame: frame, frames: frames, fadeFrames: fade,
                                          gain: gain)
        }
        #expect(s(1, 0) == 0)
        #expect(s(1, frames - 1) == 0)
        #expect(s(1, 500) == 1)
        #expect(s(1, fade) == 1)
        #expect(abs(s(1, fade / 2) - 0.5) < 1e-6)
        #expect(abs(s(1, frames - 1 - fade / 2) - 0.5) < 1e-6)
        // Monotone rise across the fade-in.
        var previous: Float = -1
        for frame in 0...fade {
            let value = s(1, frame)
            #expect(value >= previous)
            previous = value
        }
        #expect(s(0.8, 500, gain: 0.25) == 0.2)
        #expect(s(.nan, 500) == 0)
        #expect(s(.infinity, 500) == 0)
        // A subnormal computed, not written as a literal (a literal this small
        // draws an underflow warning).
        let denormal = Float.leastNormalMagnitude / 4
        #expect(denormal != 0 && !denormal.isNormal)
        #expect(s(denormal, 500).bitPattern == 0)
        #expect(s(-denormal, 500).bitPattern == 0, "a negative denormal must flush to +0")
        #expect(s(1, 500, gain: .nan) == 0)
    }

    @Test("I1 the buffer is the span at the requested level: exact gain, exact length, fades, mono → both channels at unity")
    func makeBufferLevelLengthAndChannelMap() throws {
        let dir = try I1Signals.tempDir("reader-level")
        let url = dir.appendingPathComponent("mono.wav")
        let source = I1Signals.tone(pieces: [(1.0, 220)], amplitude: 0.5)
        try I1Signals.write([source], sampleRate: 48_000, to: url)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))

        let buffer = try ClipSpanAuditionReader.makeBuffer(
            request(url, start: 0.25, end: 0.45, gain: 0.25), outputFormat: format)
        let out = I1Signals.planar(buffer)
        #expect(buffer.format == format)
        try #require(out.count == 2)
        try #require(out[0].count == 9_600, "0.2 s at 48 kHz, got \(out[0].count)")
        // Both channels carry the mono source at unity, bit for bit.
        let channelsIdentical = zip(out[0], out[1]).allSatisfy { $0.bitPattern == $1.bitPattern }
        #expect(channelsIdentical)
        // Silent edges, exact level in the fade-free middle.
        #expect(out[0].first == 0 && out[0].last == 0)
        for frame in 240..<(9_600 - 240) {
            #expect(out[0][frame] == source[12_000 + frame] * 0.25,
                    "frame \(frame) is not the source × 0.25")
        }
        print("[measured] I1 reader: 0.2 s span → \(out[0].count) frames, middle RMS "
              + "\(I1Signals.rms(out[0][240..<9_360])) (source × 0.25 ⇒ 0.0884)")
    }

    @Test("I1 a 44.1 kHz file is converted to the graph rate: the length scales and the tone keeps its pitch")
    func makeBufferConvertsTheSampleRate() throws {
        let dir = try I1Signals.tempDir("reader-src")
        let url = dir.appendingPathComponent("tone44.wav")
        let tone = I1Signals.tone(pieces: [(1.5, 220)], sampleRate: 44_100)
        try I1Signals.write([tone, tone], sampleRate: 44_100, to: url)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))

        let buffer = try ClipSpanAuditionReader.makeBuffer(request(url, start: 0.5, end: 1.0),
                                                           outputFormat: format)
        let out = I1Signals.planar(buffer)
        #expect(buffer.format.sampleRate == 48_000)
        #expect(abs(out[0].count - 24_000) <= 2, "0.5 s at 48 kHz, got \(out[0].count)")
        let hz = try #require(I1Signals.medianYinHz(out[0][2_000..<22_000], sampleRate: 48_000,
                                                    minHz: 100, maxHz: 500))
        print("[measured] I1 reader SRC 44.1 → 48 kHz: \(out[0].count) frames, YIN \(hz) Hz "
              + "(\(I1Signals.cents(hz, from: 220)) c from 220)")
        #expect(abs(I1Signals.cents(hz, from: 220)) < 5)
    }

    @Test("I1 a span wholly past the file's end throws instead of playing silence")
    func makeBufferRefusesAnEmptySpan() throws {
        let dir = try I1Signals.tempDir("reader-empty")
        let url = dir.appendingPathComponent("short.wav")
        try I1Signals.write([I1Signals.tone(pieces: [(0.5, 220)])], sampleRate: 48_000, to: url)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        #expect(throws: ClipSpanAuditionError.emptySpan) {
            _ = try ClipSpanAuditionReader.makeBuffer(request(url, start: 2, end: 3),
                                                      outputFormat: format)
        }
    }

    @Test("I1 a NaN or a denormal in the file never reaches the voice")
    func makeBufferScrubsNaNAndDenormals() throws {
        let dir = try I1Signals.tempDir("reader-nan")
        let url = dir.appendingPathComponent("nan.wav")
        var samples = I1Signals.tone(pieces: [(0.5, 220)])
        samples[12_000] = .nan
        samples[12_001] = .infinity
        samples[12_002] = Float.leastNormalMagnitude / 16   // a subnormal
        try I1Signals.write([samples], sampleRate: 48_000, to: url)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))

        let out = I1Signals.planar(try ClipSpanAuditionReader.makeBuffer(
            request(url, start: 0.2, end: 0.3), outputFormat: format))
        // Control: the planted samples really are inside the span read.
        try #require(out[0].count == 4_800)
        for channel in out {
            let allFinite = channel.allSatisfy { $0.isFinite }
            let noDenormals = channel.allSatisfy { $0 == 0 || abs($0) >= Float.leastNormalMagnitude }
            #expect(allFinite)
            #expect(noDenormals)
            #expect(channel[2_400] == 0 && channel[2_401] == 0 && channel[2_402].bitPattern == 0)
        }
    }

    // MARK: - The instrument the physics gates lean on

    @Test("I1 the test's YIN reads known tones within 2 cents, and can tell 220 from 246.94 (instrument check)")
    func yinReadsKnownTones() throws {
        for hz in [110.0, 220.0, 246.941_65, 440.0] {
            let tone = I1Signals.tone(pieces: [(0.5, hz)])
            let read = try #require(I1Signals.medianYinHz(tone[...], sampleRate: 48_000,
                                                          minHz: 70, maxHz: 1_000))
            #expect(abs(I1Signals.cents(read, from: hz)) < 2, "YIN read \(read) Hz for \(hz) Hz")
        }
        // Discrimination: a 220 Hz tone must NOT read as the +2 st target.
        let read = try #require(I1Signals.medianYinHz(
            I1Signals.tone(pieces: [(0.5, 220)])[...], sampleRate: 48_000, minHz: 70, maxHz: 1_000))
        #expect(abs(I1Signals.cents(read, from: 246.941_65)) > 150)
        // Silence is unvoiced, never a pitch.
        #expect(I1Signals.medianYinHz([Float](repeating: 0, count: 8_192)[...], sampleRate: 48_000,
                                      minHz: 70, maxHz: 1_000) == nil)
    }
}
