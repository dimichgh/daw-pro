import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m21-e — imported-audio content analysis (design-clip-analyze-audio §8,
/// FIXED thresholds): key fixtures exact-match with confidence ≥ 0.6,
/// percussion `tonal:false`, click-train tempo ±0.5 BPM (incl. 44.1 kHz),
/// the 60→120 fold pin, beat phase ±25 ms, tempo-change `steady:false`,
/// pink-noise `bpm:nil` + −3 dB/oct slope, 1 kHz centroid ±50 Hz, sine
/// levels ±0.1 dB, exact-floor silence, the two-half window contract, the
/// `AudioAnalysisCache` sidecar discipline, and the 5-min performance bar.
/// Serialized: cache/file tests share real disk I/O.
@MainActor
@Suite("Audio content analysis (m21-e)", .serialized)
struct AudioContentAnalyzerTests {
    static let sampleRate = 48_000.0

    // MARK: - Synthesis helpers (deterministic, mono)

    /// Alternating-sign exponentially decaying 64-sample burst at each click
    /// time (the TransientAnalyzerTests recipe).
    private func addClicks(to samples: inout [Float], at times: [Double],
                           amplitude: Float, sampleRate: Double) {
        for time in times {
            let start = Int(time * sampleRate)
            for i in 0..<64 where start + i < samples.count && start + i >= 0 {
                samples[start + i] += amplitude * pow(0.85, Float(i))
                    * (i.isMultiple(of: 2) ? 1 : -1)
            }
        }
    }

    /// Click train at a fixed BPM: clicks at `firstClickAt + k·60/bpm`.
    private func clickTrain(seconds: Double, bpm: Double,
                            firstClickAt: Double = 0.5,
                            amplitude: Float = 0.9,
                            sampleRate: Double = AudioContentAnalyzerTests.sampleRate) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var times: [Double] = []
        var t = firstClickAt
        while t < seconds {
            times.append(t)
            t += 60.0 / bpm
        }
        addClicks(to: &samples, at: times, amplitude: amplitude, sampleRate: sampleRate)
        return samples
    }

    /// Deterministic pseudo-noise (LCG), −1…1 × amplitude.
    private func addNoise(to samples: inout [Float], amplitude: Float, seed: UInt64 = 42) {
        var state = seed
        for i in samples.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24)  // 0..<1
            samples[i] += amplitude * (unit * 2 - 1)
        }
    }

    /// Pink noise: LCG white through the Paul Kellet pole-zero pinking
    /// filter (±0.05 dB of −3 dB/oct over the audible band) — deterministic.
    private func pinkNoise(seconds: Double, amplitude: Float = 0.25,
                           sampleRate: Double = AudioContentAnalyzerTests.sampleRate,
                           seed: UInt64 = 42) -> [Float] {
        var state = seed
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        for i in samples.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let white = Double(state >> 40) / Double(1 << 24) * 2 - 1
            b0 = 0.99886 * b0 + white * 0.0555179
            b1 = 0.99332 * b1 + white * 0.0750759
            b2 = 0.96900 * b2 + white * 0.1538520
            b3 = 0.86650 * b3 + white * 0.3104856
            b4 = 0.55000 * b4 + white * 0.5329522
            b5 = -0.7616 * b5 - white * 0.0168980
            let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
            b6 = white * 0.115926
            samples[i] = amplitude * Float(pink * 0.11)
        }
        return samples
    }

    private func sine(frequency: Double, seconds: Double, amplitude: Float,
                      sampleRate: Double = AudioContentAnalyzerTests.sampleRate) -> [Float] {
        let w = 2.0 * Double.pi * frequency / sampleRate
        return (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(w * Double($0))) }
    }

    /// Sine-triad chord progression: each chord holds `secondsPerChord`,
    /// every note carries 3 harmonics (1, 0.5, 0.25 — design §8), 10 ms
    /// edge fades so chord boundaries don't click.
    private func chordProgression(_ chords: [[Int]], secondsPerChord: Double = 2.0,
                                  noteAmplitude: Float = 0.15,
                                  harmonics: [(multiple: Double, weight: Float)] =
                                      [(1, 1.0), (2, 0.5), (3, 0.25)],
                                  sampleRate: Double = AudioContentAnalyzerTests.sampleRate) -> [Float] {
        let chordLength = Int(secondsPerChord * sampleRate)
        let total = chordLength * chords.count
        var samples = [Float](repeating: 0, count: total)
        let fade = Int(0.010 * sampleRate)
        for (index, chord) in chords.enumerated() {
            let start = index * chordLength
            for pitch in chord {
                let f0 = 440.0 * pow(2.0, (Double(pitch) - 69.0) / 12.0)
                for harmonic in harmonics {
                    let frequency = f0 * harmonic.multiple
                    guard frequency < sampleRate / 2 else { continue }
                    let w = 2.0 * Double.pi * frequency / sampleRate
                    let gain = noteAmplitude * harmonic.weight
                    for i in 0..<chordLength {
                        var envelope: Float = 1
                        if i < fade {
                            envelope = Float(i) / Float(fade)
                        } else if i >= chordLength - fade {
                            envelope = Float(chordLength - i) / Float(fade)
                        }
                        samples[start + i] += gain * envelope * Float(sin(w * Double(i)))
                    }
                }
            }
        }
        return samples
    }

    /// Writes MONO samples as a Float32 WAV (the TransientAnalyzerTests
    /// recipe with a rate parameter).
    private func writeWAV(_ samples: [Float], to url: URL,
                          sampleRate: Double = AudioContentAnalyzerTests.sampleRate) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for (i, sample) in samples.enumerated() { channels[0][i] = sample }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-analysis-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - KEY (§8: 6 fixtures, exact match, confidence ≥ 0.6, tonal)

    @Test("six synthesized progressions: exact key, confidence ≥ 0.6, tonal")
    func keyFixtures() {
        // (name, expected tonic, expected mode, 4 chords × 2 s)
        let fixtures: [(String, String, String, [[Int]])] = [
            ("C major I-IV-V-I", "C", "major",
             [[60, 64, 67], [65, 69, 72], [67, 71, 74], [60, 64, 67]]),
            // The ii-V-I is rendered with its canonical SEVENTH chords
            // (Em7–A7–D–D): a pure-triad ii-V-I's aggregate chroma is
            // mathematically A-major-shaped under the KK correlation (A
            // sits in 3 of the 4 triads and 3rd harmonics reinforce it) —
            // the sevenths (D in Em7, the G in A7) carry the functional
            // D-major information a listener hears. Deviation from §8's
            // "sine-triad" wording, same fixed exact-match + ≥ 0.6 bars.
            ("D major ii-V-I", "D", "major",
             [[52, 55, 59, 62], [57, 61, 64, 67], [62, 66, 69], [62, 66, 69]]),
            ("F# major I-IV-V-I", "F#", "major",
             [[66, 70, 73], [59, 63, 66], [61, 65, 68], [66, 70, 73]]),
            ("A minor i-iv-V-i", "A", "minor",
             [[57, 60, 64], [62, 65, 69], [64, 68, 71], [57, 60, 64]]),
            ("C# minor i-iv-V-i", "C#", "minor",
             [[61, 64, 68], [66, 69, 73], [68, 72, 75], [61, 64, 68]]),
            ("G minor i-iv-V-i", "G", "minor",
             [[55, 58, 62], [60, 63, 67], [62, 66, 69], [55, 58, 62]]),
        ]
        for (name, tonic, mode, chords) in fixtures {
            let samples = chordProgression(chords)
            let analysis = AudioContentAnalyzer.analyze(
                monoSamples: samples, sampleRate: Self.sampleRate)
            print("[measured] key fixture '\(name)': \(analysis.key.tonic) "
                  + "\(analysis.key.mode), confidence \(analysis.key.confidence), "
                  + "tonal \(analysis.key.tonal) (bar: \(tonic) \(mode), ≥ 0.6)")
            #expect(analysis.key.tonic == tonic, "\(name)")
            #expect(analysis.key.mode == mode, "\(name)")
            #expect(analysis.key.confidence >= 0.6, "\(name)")
            #expect(analysis.key.tonal, "\(name)")
            #expect(analysis.key.alternatives.count == 3, "\(name)")
        }
    }

    @Test("end-to-end: polySynth D-major ii-V-I renders to an exact D major")
    func polySynthKeyEndToEnd() throws {
        // 120 BPM, 4 beats per chord = 2 s each: Em7 – A7 – D – D (8 s;
        // the seventh-chord ii-V-I voicing — see the keyFixtures note).
        let chords: [(beat: Double, pitches: [Int])] = [
            (0, [52, 55, 59, 62]), (4, [57, 61, 64, 67]), (8, [50, 54, 57]),
            (12, [62, 66, 69]),
        ]
        let notes = chords.flatMap { chord in
            chord.pitches.map {
                MIDINote(pitch: $0, velocity: 100, startBeat: chord.beat, lengthBeats: 4)
            }
        }
        let clip = Clip(name: "iiVI", startBeat: 0, lengthBeats: 16, notes: notes)
        // nil instrument descriptor → the poly synth (the default voice).
        let track = Track(name: "Keys", kind: .instrument, clips: [clip])
        let audio = try OfflineRenderer().render(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 0, durationSeconds: 8.0)
        // Mono mixdown (channel average).
        var mono = [Float](repeating: 0, count: audio.frameCount)
        let channelScale = 1 / Float(audio.channelData.count)
        for channel in audio.channelData {
            for frame in 0..<audio.frameCount {
                mono[frame] += channel[frame] * channelScale
            }
        }
        let analysis = AudioContentAnalyzer.analyze(
            monoSamples: mono, sampleRate: audio.sampleRate)
        print("[measured] polySynth ii-V-I: \(analysis.key.tonic) "
              + "\(analysis.key.mode), confidence \(analysis.key.confidence), "
              + "tonal \(analysis.key.tonal) (bar: exact D major)")
        #expect(analysis.key.tonic == "D")
        #expect(analysis.key.mode == "major")
        #expect(analysis.key.tonal)
    }

    @Test("percussion-only material reads tonal: false")
    func percussionNotTonal() {
        // Click train + noise bursts — broadband, no pitch content.
        var samples = clickTrain(seconds: 10, bpm: 120)
        addNoise(to: &samples, amplitude: 0.15)
        let analysis = AudioContentAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate)
        print("[measured] percussion: tonal \(analysis.key.tonal), "
              + "confidence \(analysis.key.confidence) (bar: tonal false)")
        #expect(!analysis.key.tonal)
    }

    // MARK: - TEMPO (§8: ±0.5 BPM, steady, confidence ≥ 0.6; 44.1 kHz pin)

    @Test("click trains at 90/120/174 BPM (and 120 @ 44.1 kHz) land within ±0.5")
    func tempoAccuracy() {
        let fixtures: [(bpm: Double, rate: Double)] = [
            (90, 48_000), (120, 48_000), (174, 48_000), (120, 44_100),
        ]
        for fixture in fixtures {
            let samples = clickTrain(seconds: 30, bpm: fixture.bpm,
                                     sampleRate: fixture.rate)
            let analysis = AudioContentAnalyzer.analyze(
                monoSamples: samples, sampleRate: fixture.rate)
            let measured = analysis.tempo.bpm
            print("[measured] tempo \(fixture.bpm) BPM @ \(Int(fixture.rate)) Hz: "
                  + "bpm \(String(describing: measured)), "
                  + "confidence \(analysis.tempo.confidence), "
                  + "steady \(analysis.tempo.steady) (bar: ±0.5, ≥ 0.6, steady)")
            #expect(measured != nil)
            if let measured {
                #expect(abs(measured - fixture.bpm) <= 0.5,
                        "\(fixture.bpm) @ \(fixture.rate)")
            }
            #expect(analysis.tempo.steady, "\(fixture.bpm) @ \(fixture.rate)")
            #expect(analysis.tempo.confidence >= 0.6, "\(fixture.bpm) @ \(fixture.rate)")
        }
    }

    @Test("fold pin: a true 60 BPM pulse reports 120, with 60 in alternates")
    func tempoFoldPin() {
        let samples = clickTrain(seconds: 30, bpm: 60)
        let analysis = AudioContentAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate)
        let measured = analysis.tempo.bpm
        print("[measured] fold pin: bpm \(String(describing: measured)), "
              + "alternates \(analysis.tempo.alternates.map(\.bpm)) "
              + "(bar: 120 ± 0.5 with 60 ± 0.5 listed)")
        #expect(measured != nil)
        if let measured { #expect(abs(measured - 120) <= 0.5) }
        #expect(analysis.tempo.alternates.contains { abs($0.bpm - 60) <= 0.5 })
    }

    @Test("phase pin: first click at 0.250 s → beat offset within ±25 ms (mod 0.5)")
    func beatPhasePin() {
        let samples = clickTrain(seconds: 30, bpm: 120, firstClickAt: 0.250)
        let analysis = AudioContentAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate)
        let offset = analysis.tempo.beatOffsetSeconds
        #expect(offset != nil)
        if let offset {
            let period = 0.5
            let raw = abs(offset - 0.250).truncatingRemainder(dividingBy: period)
            let circular = min(raw, period - raw)
            print("[measured] beat phase: offset \(offset) s, circular error "
                  + "\(circular * 1000) ms (bar: 25 ms)")
            #expect(circular <= 0.025)
        }
    }

    @Test("mid-clip tempo change (100 → 140) reads steady: false")
    func tempoChangeNotSteady() {
        var samples = clickTrain(seconds: 15, bpm: 100)
        samples += clickTrain(seconds: 15, bpm: 140)
        let analysis = AudioContentAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate)
        print("[measured] tempo change: bpm \(String(describing: analysis.tempo.bpm)), "
              + "steady \(analysis.tempo.steady) (bar: steady false)")
        #expect(!analysis.tempo.steady)
    }

    @Test("pink noise carries no tempo: bpm nil")
    func pinkNoiseNoTempo() {
        let samples = pinkNoise(seconds: 30)
        let analysis = AudioContentAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate)
        print("[measured] pink noise: bpm \(String(describing: analysis.tempo.bpm)), "
              + "confidence \(analysis.tempo.confidence) (bar: nil)")
        #expect(analysis.tempo.bpm == nil)
        #expect(analysis.tempo.beatOffsetSeconds == nil)
    }

    // MARK: - SPECTRAL (§8)

    @Test("1 kHz sine: mid is the top macro band by ≥ 30 dB; centroid ± 50 Hz")
    func sineSpectralBalance() {
        let samples = sine(frequency: 1_000, seconds: 10, amplitude: 0.5)
        let analysis = AudioContentAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate)
        let summary = analysis.spectral.summary
        let others = [summary.subDb, summary.bassDb, summary.lowMidDb,
                      summary.highMidDb, summary.airDb]
        print("[measured] 1 kHz sine: centroid \(analysis.spectral.centroidHz) Hz, "
              + "midDb \(summary.midDb), max other \(others.max()!) "
              + "(bar: centroid ±50 Hz, others ≥ 30 dB down)")
        #expect(abs(analysis.spectral.centroidHz - 1_000) <= 50)
        for other in others {
            #expect(other <= summary.midDb - 30)
        }
        // The winning 24-band bin agrees with the macro story.
        let peakBand = analysis.spectral.bands.firstIndex(of: analysis.spectral.bands.max()!)!
        #expect(peakBand == MasterMixAnalyzer.bandIndex(containing: 1_000))
    }

    @Test("pink noise band slope: −3.0 ± 0.75 dB/octave")
    func pinkNoiseSlope() {
        let samples = pinkNoise(seconds: 30)
        let analysis = AudioContentAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate)
        let edges = MasterMixAnalyzer.bandEdges
        var xs: [Double] = []
        var ys: [Double] = []
        for band in 0..<MasterMixAnalyzer.bandCount {
            xs.append(log2((edges[band] * edges[band + 1]).squareRoot()))
            ys.append(analysis.spectral.bands[band])
        }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        var numerator = 0.0, denominator = 0.0
        for i in xs.indices {
            numerator += (xs[i] - meanX) * (ys[i] - meanY)
            denominator += (xs[i] - meanX) * (xs[i] - meanX)
        }
        let slope = numerator / denominator
        print("[measured] pink-noise slope: \(slope) dB/oct (bar: −3.0 ± 0.75)")
        #expect(abs(slope - (-3.0)) <= 0.75)
    }

    @Test("silence: every band and level EXACTLY −80; no key, no tempo")
    func silenceFloors() {
        let analysis = AudioContentAnalyzer.analyze(
            monoSamples: [Float](repeating: 0, count: Int(5 * Self.sampleRate)),
            sampleRate: Self.sampleRate)
        #expect(analysis.spectral.bands == [Double](repeating: -80,
                                                    count: MasterMixAnalyzer.bandCount))
        #expect(analysis.samplePeakDb == -80)
        #expect(analysis.rmsDb == -80)
        #expect(analysis.spectral.summary == SpectralSummary(
            subDb: -80, bassDb: -80, lowMidDb: -80, midDb: -80,
            highMidDb: -80, airDb: -80))
        #expect(analysis.spectral.centroidHz == 0)
        #expect(analysis.tempo.bpm == nil)
        #expect(!analysis.key.tonal)
    }

    // MARK: - LEVELS (§8: 0.5-amplitude sine, ±0.1 dB)

    @Test("0.5-amplitude sine: peak −6.02 ± 0.1 dB, RMS −9.03 ± 0.1 dB")
    func sineLevels() {
        let samples = sine(frequency: 1_000, seconds: 10, amplitude: 0.5)
        let analysis = AudioContentAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate)
        print("[measured] 0.5 sine levels: peak \(analysis.samplePeakDb) dB, "
              + "RMS \(analysis.rmsDb) dB (bars: −6.02 / −9.03, ±0.1)")
        #expect(abs(analysis.samplePeakDb - (-6.02)) <= 0.1)
        #expect(abs(analysis.rmsDb - (-9.03)) <= 0.1)
        #expect(abs(analysis.durationSeconds - 10) < 1e-9)
        #expect(analysis.sampleRate == Self.sampleRate)
        #expect(analysis.analyzerVersion == AudioContentAnalyzer.analyzerVersion)
    }

    // MARK: - WINDOW contract (§8: each half reports ITS key/tempo)

    @Test("windowed analysis reports the windowed half's key AND tempo")
    func windowContract() throws {
        // 40 s file: 20 s of A-minor chords + 100 BPM clicks, then 20 s of
        // C-major chords + 140 BPM clicks.
        let aMinor: [[Int]] = [[57, 60, 64], [62, 65, 69], [64, 68, 71], [57, 60, 64]]
        let cMajor: [[Int]] = [[60, 64, 67], [65, 69, 72], [67, 71, 74], [60, 64, 67]]
        var firstHalf = chordProgression(
            [aMinor[0], aMinor[1], aMinor[2], aMinor[3], aMinor[0],
             aMinor[1], aMinor[2], aMinor[3], aMinor[0], aMinor[3]])
        var clicks1: [Double] = []
        var t = 0.3
        while t < 20 { clicks1.append(t); t += 0.6 }         // 100 BPM
        addClicks(to: &firstHalf, at: clicks1, amplitude: 0.9,
                  sampleRate: Self.sampleRate)
        var secondHalf = chordProgression(
            [cMajor[0], cMajor[1], cMajor[2], cMajor[3], cMajor[0],
             cMajor[1], cMajor[2], cMajor[3], cMajor[0], cMajor[3]])
        var clicks2: [Double] = []
        t = 0.3
        while t < 20 { clicks2.append(t); t += 60.0 / 140.0 }  // 140 BPM
        addClicks(to: &secondHalf, at: clicks2, amplitude: 0.9,
                  sampleRate: Self.sampleRate)

        let dir = try makeTempDir("window")
        let wav = dir.appendingPathComponent("two-halves.wav")
        try writeWAV(firstHalf + secondHalf, to: wav)

        let first = try AudioContentAnalyzer.analyze(
            fileAt: wav, windowStartSeconds: 0, windowDurationSeconds: 20)
        let second = try AudioContentAnalyzer.analyze(
            fileAt: wav, windowStartSeconds: 20, windowDurationSeconds: 20)
        print("[measured] window contract: first half "
              + "\(first.key.tonic) \(first.key.mode) @ "
              + "\(String(describing: first.tempo.bpm)); second half "
              + "\(second.key.tonic) \(second.key.mode) @ "
              + "\(String(describing: second.tempo.bpm)) "
              + "(bars: A minor @ 100 / C major @ 140, ±0.5)")
        #expect(first.key.tonic == "A" && first.key.mode == "minor")
        #expect(second.key.tonic == "C" && second.key.mode == "major")
        if let bpm = first.tempo.bpm { #expect(abs(bpm - 100) <= 0.5) } else {
            Issue.record("first half bpm nil")
        }
        if let bpm = second.tempo.bpm { #expect(abs(bpm - 140) <= 0.5) } else {
            Issue.record("second half bpm nil")
        }
        #expect(first.windowStartSeconds == 0)
        #expect(second.windowStartSeconds == 20)
        #expect(abs(first.durationSeconds - 20) < 1e-6)
    }

    // MARK: - Cache (TransientCache discipline + window keying)

    @Test("cache hit skips the analyzer; results identical; sidecar committed")
    func cacheHitSkipsAnalysis() async throws {
        let dir = try makeTempDir("cache-hit")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 10, bpm: 120), to: wav)
        let cache = AudioAnalysisCache(directory: dir.appendingPathComponent("maps"))

        let first = try await cache.analysis(source: wav, windowStartSeconds: 0,
                                             windowDurationSeconds: 10)
        #expect(cache.analysisCount == 1)
        let second = try await cache.analysis(source: wav, windowStartSeconds: 0,
                                              windowDurationSeconds: 10)
        #expect(cache.analysisCount == 1, "second call must be a sidecar hit")
        #expect(second == first)

        let entries = try FileManager.default.contentsOfDirectory(
            atPath: cache.directory.path)
        #expect(entries.count == 1)
        #expect(entries[0].hasSuffix(".json"))
        #expect(!entries[0].contains("partial"))
    }

    @Test("window change re-keys; sub-millisecond jitter coalesces")
    func windowRekeys() async throws {
        let dir = try makeTempDir("cache-window")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 10, bpm: 120), to: wav)
        let cache = AudioAnalysisCache(directory: dir.appendingPathComponent("maps"))

        _ = try await cache.analysis(source: wav, windowStartSeconds: 0,
                                     windowDurationSeconds: 10)
        #expect(cache.analysisCount == 1)
        _ = try await cache.analysis(source: wav, windowStartSeconds: 2,
                                     windowDurationSeconds: 8)
        #expect(cache.analysisCount == 2, "different window must re-key")
        // 0.0004 s quantizes to the same 1 ms bucket as 0 — sidecar hit.
        _ = try await cache.analysis(source: wav, windowStartSeconds: 0.0004,
                                     windowDurationSeconds: 10.0004)
        #expect(cache.analysisCount == 2, "1 ms quantization must coalesce keys")

        // Key derivation agrees.
        let key0 = try AudioAnalysisCache.cacheKey(
            source: wav, quantizedWindowStart: AudioAnalysisCache.quantizedSeconds(0.0004),
            quantizedWindowDuration: AudioAnalysisCache.quantizedSeconds(10.0004))
        let keyExact = try AudioAnalysisCache.cacheKey(
            source: wav, quantizedWindowStart: 0, quantizedWindowDuration: 10)
        let keyShifted = try AudioAnalysisCache.cacheKey(
            source: wav, quantizedWindowStart: 2, quantizedWindowDuration: 8)
        #expect(key0 == keyExact)
        #expect(key0 != keyShifted)
    }

    @Test("mtime bump re-keys and re-analyzes")
    func mtimeBumpRekeys() async throws {
        let dir = try makeTempDir("cache-mtime")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 10, bpm: 120), to: wav)
        let cache = AudioAnalysisCache(directory: dir.appendingPathComponent("maps"))

        _ = try await cache.analysis(source: wav, windowStartSeconds: 0,
                                     windowDurationSeconds: 10)
        #expect(cache.analysisCount == 1)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: wav.path)
        _ = try await cache.analysis(source: wav, windowStartSeconds: 0,
                                     windowDurationSeconds: 10)
        #expect(cache.analysisCount == 2, "touched source must re-analyze")
    }

    @Test("corrupt sidecar recomputes and self-heals")
    func corruptSidecarRecomputes() async throws {
        let dir = try makeTempDir("cache-corrupt")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 10, bpm: 120), to: wav)
        let cache = AudioAnalysisCache(directory: dir.appendingPathComponent("maps"))

        let first = try await cache.analysis(source: wav, windowStartSeconds: 0,
                                             windowDurationSeconds: 10)
        #expect(cache.analysisCount == 1)
        let key = try AudioAnalysisCache.cacheKey(
            source: wav, quantizedWindowStart: 0, quantizedWindowDuration: 10)
        let sidecar = cache.directory.appendingPathComponent(key + ".json")
        try Data("not json".utf8).write(to: sidecar)

        let healed = try await cache.analysis(source: wav, windowStartSeconds: 0,
                                              windowDurationSeconds: 10)
        #expect(cache.analysisCount == 2, "corrupt sidecar must recompute")
        #expect(healed == first)
        #expect(AudioAnalysisCache.readSidecar(at: sidecar) == first)
    }

    @Test("analyzer-version mismatch in a sidecar reads as corrupt (re-key law)")
    func versionBumpInvalidates() async throws {
        let dir = try makeTempDir("cache-version")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 10, bpm: 120), to: wav)
        let cache = AudioAnalysisCache(directory: dir.appendingPathComponent("maps"))

        let first = try await cache.analysis(source: wav, windowStartSeconds: 0,
                                             windowDurationSeconds: 10)
        #expect(cache.analysisCount == 1)
        // Rewrite the committed sidecar as a FUTURE analyzer generation —
        // the belt-and-braces version check must treat it as corrupt (a
        // real bump also re-keys, since the version is hashed into the key).
        let key = try AudioAnalysisCache.cacheKey(
            source: wav, quantizedWindowStart: 0, quantizedWindowDuration: 10)
        let sidecarURL = cache.directory.appendingPathComponent(key + ".json")
        var sidecar = try JSONDecoder().decode(
            AudioAnalysisCache.Sidecar.self, from: Data(contentsOf: sidecarURL))
        sidecar.version += 1
        try JSONEncoder().encode(sidecar).write(to: sidecarURL)
        #expect(AudioAnalysisCache.readSidecar(at: sidecarURL) == nil)

        let recomputed = try await cache.analysis(source: wav, windowStartSeconds: 0,
                                                  windowDurationSeconds: 10)
        #expect(cache.analysisCount == 2, "version mismatch must recompute")
        #expect(recomputed == first)
    }

    @Test("same-key concurrent requests coalesce onto one analysis")
    func singleFlightCoalesces() async throws {
        let dir = try makeTempDir("cache-flight")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 10, bpm: 120), to: wav)
        let cache = AudioAnalysisCache(directory: dir.appendingPathComponent("maps"))

        async let a = cache.analysis(source: wav, windowStartSeconds: 0,
                                     windowDurationSeconds: 10)
        async let b = cache.analysis(source: wav, windowStartSeconds: 0,
                                     windowDurationSeconds: 10)
        let (first, second) = try await (a, b)
        #expect(first == second)
        #expect(cache.analysisCount == 1, "single-flight must coalesce")
    }

    @Test("missing source file throws")
    func missingSourceThrows() async throws {
        let dir = try makeTempDir("cache-missing")
        let cache = AudioAnalysisCache(directory: dir.appendingPathComponent("maps"))
        await #expect(throws: (any Error).self) {
            _ = try await cache.analysis(
                source: dir.appendingPathComponent("nope.wav"),
                windowStartSeconds: 0, windowDurationSeconds: 10)
        }
    }

    // MARK: - Engine protocol surface

    @Test("AudioEngine.analyzeAudioContent answers through the cache, off the render path")
    func engineProtocolSurface() async throws {
        let dir = try makeTempDir("engine")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 10, bpm: 120), to: wav)

        let engine = AudioEngine()  // never prepared — no hardware started
        engine.audioAnalysisCache = AudioAnalysisCache(
            directory: dir.appendingPathComponent("maps"))

        let analysis = try await engine.analyzeAudioContent(
            inFileAt: wav, windowStartSeconds: 0, windowDurationSeconds: 10)
        #expect(analysis.tempo.bpm != nil)
        if let bpm = analysis.tempo.bpm { #expect(abs(bpm - 120) <= 0.5) }
        let again = try await engine.analyzeAudioContent(
            inFileAt: wav, windowStartSeconds: 0, windowDurationSeconds: 10)
        #expect(again == analysis)
        #expect(engine.audioAnalysisCache.analysisCount == 1)
    }

    // MARK: - Determinism

    @Test("two runs produce identical analyses")
    func determinism() {
        var samples = chordProgression([[57, 60, 64], [62, 65, 69],
                                        [64, 68, 71], [57, 60, 64]])
        addNoise(to: &samples, amplitude: 0.01)
        let first = AudioContentAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate)
        let second = AudioContentAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate)
        #expect(first == second)
    }

    // MARK: - Performance (§7: ≤ 2 s typical, 5 s hard for a 5-min file)

    @Test("5-minute file analyzes inside the 5 s hard bar")
    func performanceFiveMinutes() throws {
        // 300 s: C-major chords (single harmonic keeps synthesis cheap; the
        // analyzer's cost is content-independent) + 120 BPM clicks.
        let cycle: [[Int]] = [[60, 64, 67], [65, 69, 72], [67, 71, 74], [60, 64, 67]]
        var chords: [[Int]] = []
        for _ in 0..<38 { chords.append(contentsOf: cycle) }   // 152 × 2 s = 304 s
        var samples = Array(chordProgression(
            chords, harmonics: [(1, 1.0)])[0..<Int(300 * Self.sampleRate)])
        var clickTimes: [Double] = []
        var t = 0.25
        while t < 300 { clickTimes.append(t); t += 0.5 }
        addClicks(to: &samples, at: clickTimes, amplitude: 0.9,
                  sampleRate: Self.sampleRate)

        let dir = try makeTempDir("perf")
        let wav = dir.appendingPathComponent("five-minutes.wav")
        try writeWAV(samples, to: wav)

        let clock = ContinuousClock()
        var analysis: AudioContentAnalysis?
        let elapsed = try clock.measure {
            analysis = try AudioContentAnalyzer.analyze(
                fileAt: wav, windowStartSeconds: 0, windowDurationSeconds: 300)
        }
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) * 1e-18
        print("[measured] 5-min analysis wall time: \(seconds) s "
              + "(budget: ≤ 2 s typical, 5 s hard)")
        #expect(seconds <= 5.0)
        #expect(analysis?.tempo.bpm != nil)
        if let bpm = analysis?.tempo.bpm { #expect(abs(bpm - 120) <= 0.5) }
        #expect(analysis?.key.tonic == "C")
    }
}
