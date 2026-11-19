import AVFAudio
import Foundation
import Testing
import DAWCore
@testable import DAWEngine

// m27-k: `audio.profileFile {loudness: true}` — the opt-in BS.1770 reading for
// the profiled range. It is THE meter (`Loudness.Stream`, the one
// `ReferenceAnalyzer.analyze` feeds for reference.import/reference.analyze)
// through a second door, so these tests pin it to the other doors EXACTLY
// rather than to a tolerance budget of its own: known-level physics (the
// `LoudnessTests` calibration oracle), exact equality with the reference path,
// <= 1e-9 with `Loudness.measure` (render.measureLoudness's twin, the pinned
// `ReferenceAnalyzerTests` T4 tolerance), the range semantics, gain linearity,
// honest absence, NaN/Inf at the door, and chunk-size invariance.

// MARK: - Fixtures

private func sine(frequency: Double, dbfs: Double, seconds: Double,
                  sampleRate: Double = 48_000, phaseRadians: Double = 0) -> [Float] {
    let amplitude = pow(10.0, dbfs / 20.0)
    let count = Int((seconds * sampleRate).rounded())
    return (0..<count).map {
        Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / sampleRate + phaseRadians))
    }
}

/// Level steps for gating/LRA plus a 12 kHz 45-degree segment for a real
/// inter-sample peak — the m22-c convergence shape (8.0 s, hop-aligned at 48 k).
private func convergenceProgram() -> [Float] {
    sine(frequency: 997, dbfs: -33, seconds: 3)
        + sine(frequency: 440, dbfs: -23, seconds: 3)
        + sine(frequency: 12_000, dbfs: -6, seconds: 2, phaseRadians: .pi / 4)
}

/// Float32 (IEEE) WAV so read-back is BIT-EXACT against the in-memory samples.
private func writeFloat32Wav(_ channels: [[Float]], sampleRate: Double = 48_000) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("m27k-loudness-\(UUID().uuidString.prefix(8)).wav")
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels.count), interleaved: false) else {
        throw AudioContentAnalyzerError.unreadable("format construction failed")
    }
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels.count,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ],
        commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = channels.map(\.count).min() ?? 0
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
        throw AudioContentAnalyzerError.unreadable("buffer allocation failed")
    }
    for (index, channel) in channels.enumerated() {
        channel.withUnsafeBufferPointer {
            buffer.floatChannelData![index].update(from: $0.baseAddress!, count: frames)
        }
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    try file.write(from: buffer)
    return url
}

/// The reference door's five loudness fields, as the `LoudnessMeasurement`
/// shape the profile carries.
private func referenceLoudness(_ url: URL) throws -> LoudnessMeasurement {
    let analysis = try ReferenceAnalyzer.analyze(fileAt: url)
    return LoudnessMeasurement(
        integratedLufs: analysis.integratedLufs, truePeakDbtp: analysis.truePeakDbtp,
        maxMomentaryLufs: analysis.maxMomentaryLufs, maxShortTermLufs: analysis.maxShortTermLufs,
        loudnessRangeLu: analysis.loudnessRangeLu)
}

private func profiledLoudness(_ url: URL, fromSeconds: Double = 0, durationSeconds: Double? = nil,
                              chunkFrames: AVAudioFrameCount = FileProfiler.defaultChunkFrames)
    throws -> LoudnessMeasurement {
    let profile = try FileProfiler.profile(
        fileAt: url, windowSeconds: 1, fromSeconds: fromSeconds, durationSeconds: durationSeconds,
        measuringLoudness: true, chunkFrames: chunkFrames)
    return try #require(profile.loudness, "measuringLoudness: true must always attach a reading")
}

@Suite("audio.profileFile loudness: the one meter through a second door (m27-k)")
struct FileProfileLoudnessTests {

    @Test("m27-k physics: a stereo -20 dBFS 1 kHz sine reads -20.0 LUFS / -20.0 dBTP; the same tone in mono reads -23.0 LUFS")
    func knownLevelPhysics() throws {
        let tone = sine(frequency: 1_000, dbfs: -20, seconds: 10)
        let stereoURL = try writeFloat32Wav([tone, tone])
        let monoURL = try writeFloat32Wav([tone])
        defer {
            try? FileManager.default.removeItem(at: stereoURL)
            try? FileManager.default.removeItem(at: monoURL)
        }

        let stereo = try profiledLoudness(stereoURL)
        let stereoIntegrated = try #require(stereo.integratedLufs)
        let stereoPeak = try #require(stereo.truePeakDbtp)
        print("[measured] m27-k stereo -20 dBFS 1 kHz: integrated \(stereoIntegrated) LUFS, "
              + "true peak \(stereoPeak) dBTP, LRA \(stereo.loudnessRangeLu.map { "\($0)" } ?? "nil") LU")
        // BS.1770 is transparent at 1 kHz and SUMS the channels: -20 dBFS on
        // both channels reads -20.0 (the LoudnessTests -23/-23 calibration).
        #expect(abs(stereoIntegrated - -20.0) <= 0.1)
        #expect(abs(stereoPeak - -20.0) <= 0.1)
        #expect(try #require(stereo.loudnessRangeLu) <= 0.1, "a steady tone has no loudness range")

        let mono = try profiledLoudness(monoURL)
        let monoIntegrated = try #require(mono.integratedLufs)
        print("[measured] m27-k mono -20 dBFS 1 kHz: integrated \(monoIntegrated) LUFS")
        // One channel carries half the summed power: 10*log10(2) = 3.01 LU less.
        #expect(abs(monoIntegrated - -23.0) <= 0.1)
        #expect(abs(try #require(mono.truePeakDbtp) - -20.0) <= 0.1)
    }

    @Test("m27-k one meter, three doors: the profile's reading EQUALS ReferenceAnalyzer.analyze and matches Loudness.measure within 1e-9")
    func oneMeterThreeDoors() throws {
        let program = convergenceProgram()
        let url = try writeFloat32Wav([program, program])
        defer { try? FileManager.default.removeItem(at: url) }

        let profiled = try profiledLoudness(url)
        // Door 2: reference.import / reference.analyze — the SAME Stream, so
        // the numbers are identical, not merely close.
        #expect(profiled == (try referenceLoudness(url)))
        // Door 3: render.measureLoudness's batch twin on the same samples.
        let batch = Loudness.measure(RenderedAudio(sampleRate: 48_000, channelData: [program, program]))
        let pairs: [(Double?, Double?, String)] = [
            (profiled.integratedLufs, batch.integratedLufs, "integrated"),
            (profiled.truePeakDbtp, batch.truePeakDbtp, "truePeak"),
            (profiled.maxMomentaryLufs, batch.maxMomentaryLufs, "maxMomentary"),
            (profiled.maxShortTermLufs, batch.maxShortTermLufs, "maxShortTerm"),
            (profiled.loudnessRangeLu, batch.loudnessRangeLu, "LRA"),
        ]
        for (door1, door3, name) in pairs {
            let a = try #require(door1, "\(name) missing from the profile")
            let b = try #require(door3, "\(name) missing from Loudness.measure")
            #expect(abs(a - b) <= 1e-9, "\(name): profile \(a) vs measure \(b)")
        }
        // Anti-vacuity: the 12 kHz 45-degree segment forces a real inter-sample read.
        #expect(try #require(profiled.truePeakDbtp) > -6.1)
    }

    @Test("m27-k range: fromSeconds into the quiet half reads that half alone, EXACTLY as the half written as its own file")
    func profiledRangeIsItsOwnProgram() throws {
        let loud = sine(frequency: 1_000, dbfs: -20, seconds: 5)
        let quiet = sine(frequency: 1_000, dbfs: -40, seconds: 5)
        let wholeURL = try writeFloat32Wav([loud + quiet, loud + quiet])
        let quietURL = try writeFloat32Wav([quiet, quiet])
        defer {
            try? FileManager.default.removeItem(at: wholeURL)
            try? FileManager.default.removeItem(at: quietURL)
        }

        let ranged = try profiledLoudness(wholeURL, fromSeconds: 5)
        let integrated = try #require(ranged.integratedLufs)
        print("[measured] m27-k range [5 s, EOF) of -20|-40 file: integrated \(integrated) LUFS")
        #expect(abs(integrated - -40.0) <= 0.1)
        #expect(abs(try #require(ranged.truePeakDbtp) - -40.0) <= 0.1)
        // Filters start cold at fromSeconds and the edge is zero-padded at the
        // range end: the same samples as their own file, through the reference door.
        #expect(ranged == (try referenceLoudness(quietURL)))
        // Invariance control: the WHOLE file is NOT what the range reported.
        let whole = try #require(try profiledLoudness(wholeURL).integratedLufs)
        #expect(whole > -21, "the whole file is dominated by its -20 half (the -40 half is relatively gated)")
    }

    @Test("m27-k gain: doubling every sample adds 6.02 LU integrated and 6.02 dB true peak")
    func gainLinearity() throws {
        let tone = sine(frequency: 1_000, dbfs: -26, seconds: 6)
        let doubled = tone.map { $0 * 2 }  // exact in Float
        let baseURL = try writeFloat32Wav([tone, tone])
        let loudURL = try writeFloat32Wav([doubled, doubled])
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: loudURL)
        }
        let base = try profiledLoudness(baseURL)
        let louder = try profiledLoudness(loudURL)
        let sixDb = 20 * log10(2.0)
        #expect(abs((try #require(louder.integratedLufs)) - (try #require(base.integratedLufs)) - sixDb) <= 0.01)
        #expect(abs((try #require(louder.truePeakDbtp)) - (try #require(base.truePeakDbtp)) - sixDb) <= 0.01)
    }

    @Test("m27-k honest absence: under 0.4 s has no integrated reading, digital silence has no reading at all, and nothing is ever NaN")
    func honestAbsence() throws {
        let tone = sine(frequency: 1_000, dbfs: -20, seconds: 2)
        let toneURL = try writeFloat32Wav([tone, tone])
        let silent = [Float](repeating: 0, count: 96_000)
        let silentURL = try writeFloat32Wav([silent, silent])
        defer {
            try? FileManager.default.removeItem(at: toneURL)
            try? FileManager.default.removeItem(at: silentURL)
        }

        let short = try profiledLoudness(toneURL, durationSeconds: 0.3)
        #expect(short.integratedLufs == nil, "0.3 s holds no 400 ms block")
        #expect(short.maxMomentaryLufs == nil)
        #expect(abs(try #require(short.truePeakDbtp) - -20.0) <= 0.1, "a true peak needs no block")

        let silence = try profiledLoudness(silentURL)
        #expect(silence == LoudnessMeasurement(), "digital silence: a reading with every field absent, never a number")
    }

    @Test("m27-k NaN/Inf samples in a float file never reach the reading, and the reference door agrees exactly")
    func poisonedSamplesAreSanitized() throws {
        var tone = sine(frequency: 1_000, dbfs: -20, seconds: 4)
        for index in stride(from: 1_000, to: tone.count, by: 37_000) { tone[index] = .nan }
        tone[50_000] = .infinity
        tone[60_000] = -.infinity
        let url = try writeFloat32Wav([tone, tone])
        defer { try? FileManager.default.removeItem(at: url) }

        let profiled = try profiledLoudness(url)
        for value in [profiled.integratedLufs, profiled.truePeakDbtp, profiled.maxMomentaryLufs,
                      profiled.maxShortTermLufs, profiled.loudnessRangeLu] {
            if let value { #expect(value.isFinite) }
        }
        #expect(abs(try #require(profiled.integratedLufs) - -20.0) <= 0.1, "the tone still reads")
        #expect(profiled == (try referenceLoudness(url)))
    }

    @Test("m27-k no flag: loudness stays nil and the windows are identical to a flagged run's")
    func noFlagLeavesWindowsUntouched() throws {
        let program = convergenceProgram()
        let url = try writeFloat32Wav([program, program])
        defer { try? FileManager.default.removeItem(at: url) }

        let plain = try FileProfiler.profile(fileAt: url, windowSeconds: 0.5, fromSeconds: 1.25)
        let flagged = try FileProfiler.profile(
            fileAt: url, windowSeconds: 0.5, fromSeconds: 1.25, measuringLoudness: true)
        #expect(plain.loudness == nil)
        #expect(flagged.loudness != nil)
        var stripped = flagged
        stripped.loudness = nil
        #expect(stripped == plain, "the flag adds a reading and changes nothing else")
    }

    @Test("m27-k chunk-size invariance: 4 k and 64 k chunks give the identical reading")
    func chunkInvariance() throws {
        let program = convergenceProgram()
        let url = try writeFloat32Wav([program, program])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try profiledLoudness(url, fromSeconds: 0.7, chunkFrames: 4_096)
                == (try profiledLoudness(url, fromSeconds: 0.7, chunkFrames: 65_536)))
    }
}
