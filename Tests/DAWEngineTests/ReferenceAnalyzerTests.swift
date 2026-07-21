import AVFAudio
import Foundation
import Testing
import DAWCore
@testable import DAWEngine

// m22-g P1 (design-m22g-reference-tracks §4/§9): the whole-file reference
// analyzer — T4 loudness parity with `Loudness.measure` (the ONE-home
// convergence idiom) + chunk-size invariance, T5 band-fold sharing (the
// anti-fork pin) + band sanity, T6 stereo cross-consistency with the live
// `MasterMixAnalyzer` home, plus poison/unreadable honesty.

// MARK: - Fixtures

private func sine(frequency: Double, dbfs: Double, seconds: Double,
                  sampleRate: Double, phaseRadians: Double = 0) -> [Float] {
    let amplitude = pow(10.0, dbfs / 20.0)
    let count = Int((seconds * sampleRate).rounded())
    var out = [Float](repeating: 0, count: count)
    for n in 0..<count {
        out[n] = Float(amplitude * sin(2.0 * .pi * frequency * Double(n) / sampleRate + phaseRadians))
    }
    return out
}

/// Deterministic broadband noise (seeded LCG) in ±amplitude.
private func noise(count: Int, amplitude: Float, seed: UInt64) -> [Float] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Float(state >> 11) / Float(1 << 53)  // 0..<1
        return (unit * 2 - 1) * amplitude
    }
}

/// The m22-c convergence program: level steps for gating/LRA, a 12 kHz
/// 45°-phase segment for inter-sample peaks; 8.0 s = hop-aligned at 48 k.
private func convergenceProgram() -> [Float] {
    var samples = sine(frequency: 997, dbfs: -33, seconds: 3, sampleRate: 48_000)
    samples += sine(frequency: 440, dbfs: -23, seconds: 3, sampleRate: 48_000)
    samples += sine(frequency: 12_000, dbfs: -6, seconds: 2, sampleRate: 48_000,
                    phaseRadians: .pi / 4)
    return samples
}

/// Writes a Float32 (IEEE) WAV so read-back is BIT-EXACT against the
/// in-memory samples — 16-bit quantization would break the ≤1e-9 parity gate.
private func writeFloat32Wav(_ channels: [[Float]], sampleRate: Double) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ref-analyzer-\(UUID().uuidString.prefix(8)).wav")
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

/// Feeds a stereo pair into a `MasterMixAnalyzer` via `processMix` (the
/// deinterleaved `floatChannelData` shape) — the T6 live-home harness.
private func feedMix(_ analyzer: MasterMixAnalyzer, left: [Float], right: [Float]) {
    let frames = min(left.count, right.count)
    var l = left
    var r = right
    l.withUnsafeMutableBufferPointer { lBuf in
        r.withUnsafeMutableBufferPointer { rBuf in
            var channels = [lBuf.baseAddress!, rBuf.baseAddress!]
            channels.withUnsafeMutableBufferPointer { chans in
                analyzer.processMix(channels: chans.baseAddress!,
                                    channelCount: 2, frameCount: frames)
            }
        }
    }
}

@Suite("Reference analyzer — loudness parity, band fold, stereo (m22-g)")
struct ReferenceAnalyzerTests {

    // T4: the loudness numbers are THE SAME MATH as Loudness.measure —
    // fp-identity tolerances (1e-9), not approximation budgets, because the
    // analyzer feeds the same Loudness.Stream the m22-c gate pinned against
    // measure(), including the 31-zero-frame interpolator tail.
    @Test("T4: integrated/maxima/LRA/true-peak equal Loudness.measure on the same samples (≤ 1e-9)")
    func loudnessParity() throws {
        let mono = convergenceProgram()
        let url = try writeFloat32Wav([mono, mono], sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let offline = Loudness.measure(
            RenderedAudio(sampleRate: 48_000, channelData: [mono, mono]))
        let analysis = try ReferenceAnalyzer.analyze(fileAt: url)

        let integrated = try #require(analysis.integratedLufs)
        #expect(abs(integrated - (try #require(offline.integratedLufs))) <= 1e-9)
        let maxMomentary = try #require(analysis.maxMomentaryLufs)
        #expect(abs(maxMomentary - (try #require(offline.maxMomentaryLufs))) <= 1e-9)
        let maxShortTerm = try #require(analysis.maxShortTermLufs)
        #expect(abs(maxShortTerm - (try #require(offline.maxShortTermLufs))) <= 1e-9)
        let range = try #require(analysis.loudnessRangeLu)
        #expect(abs(range - (try #require(offline.loudnessRangeLu))) <= 1e-9)
        let truePeak = try #require(analysis.truePeakDbtp)
        #expect(abs(truePeak - (try #require(offline.truePeakDbtp))) <= 1e-9)
        // Anti-vacuity: the 12 kHz 45° segment guarantees a real
        // inter-sample-peak read.
        #expect(truePeak > -6.1)

        #expect(analysis.durationSeconds == 8.0)
        #expect(analysis.sampleRateHz == 48_000)
        #expect(analysis.analyzerVersion == ReferenceAnalyzer.version)
        #expect(analysis.bandsDb.count == MasterAnalysisSnapshot.bandCount)
        // Mono program: exact stereo identities.
        #expect(analysis.correlation == 1)
        #expect(analysis.width == 0)
        #expect(analysis.balance == 0)
    }

    @Test("T4: chunk-size invariance — 4 k vs 64 k chunks produce the IDENTICAL analysis")
    func chunkInvariance() throws {
        let mono = convergenceProgram()
        let url = try writeFloat32Wav([mono, mono], sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let small = try ReferenceAnalyzer.analyze(fileAt: url, chunkFrames: 4_096)
        let large = try ReferenceAnalyzer.analyze(fileAt: url, chunkFrames: 65_536)
        #expect(small == large)
    }

    // T5a: the DIRECT anti-fork pin — AudioContentAnalyzer's band output IS
    // the shared fold's output, bit-identical, on the same mean-power input.
    @Test("T5: AudioContentAnalyzer bands == SpectrumBandFold on the same spectrum (bit-identical)")
    func sharedFoldPin() {
        let half = AudioContentAnalyzer.fftSize / 2
        // A structured synthetic spectrum: 1/f-ish density + a spike.
        var meanPower = (0..<half).map { 1.0 / Double($0 + 2) }
        meanPower[100] = 3.5
        let viaAnalyzer = AudioContentAnalyzer.spectralBalance(
            meanPower: meanPower, sampleRate: 48_000).bands
        let viaFold = SpectrumBandFold.bandsDb(
            meanPower: meanPower, sampleRate: 48_000,
            fftSize: AudioContentAnalyzer.fftSize,
            floorDb: AudioContentAnalyzer.floorDb)
        #expect(viaAnalyzer == viaFold)
    }

    // T5b: band sanity on the reference analyzer itself — a tone lands in
    // ITS band (the shared MasterMixAnalyzer geometry), far bands floor out.
    @Test("T5: 1 kHz tone peaks in bandIndex(1000); far bands read near the floor")
    func toneBandSanity() throws {
        let tone = sine(frequency: 1_000, dbfs: -12, seconds: 5, sampleRate: 48_000)
        let url = try writeFloat32Wav([tone, tone], sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try ReferenceAnalyzer.analyze(fileAt: url)
        let bands = analysis.bandsDb
        let peakBand = bands.indices.max { bands[$0] < bands[$1] }!
        #expect(peakBand == MasterMixAnalyzer.bandIndex(containing: 1_000))
        // Two octaves away the energy is leakage-only: far below the peak.
        let farBand = MasterMixAnalyzer.bandIndex(containing: 4_000)
        #expect(bands[peakBand] - bands[farBand] > 40)
    }

    // T5c: cross-analyzer consistency on BROADBAND material. Per-bin mean
    // power = PSD × bin width, so the two geometries differ by EXACTLY
    // 10·log10(16384/2048) ≈ 9.03 dB for any stationary broadband program —
    // density physics, not a fork (the bit-identical pin above is the fork
    // detector). Pinning the offset ITSELF is the consistency proof: a
    // forked fold (total-vs-density, bin mapping, normalization) would not
    // land on the analytic constant.
    @Test("T5: broadband noise reads the same PSD through both analyzers (bin-width offset exact)")
    func noiseCrossAnalyzer() throws {
        let mono = noise(count: 5 * 48_000, amplitude: 0.25, seed: 0xDA7A_5EED)
        let url = try writeFloat32Wav([mono, mono], sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let reference = try ReferenceAnalyzer.analyze(fileAt: url).bandsDb
        let content = AudioContentAnalyzer.analyze(
            monoSamples: mono, sampleRate: 48_000).spectral.bands
        let binWidthOffsetDb = 10 * log10(
            Double(AudioContentAnalyzer.fftSize) / Double(ReferenceAnalyzer.fftSize))
        for band in 0..<MasterAnalysisSnapshot.bandCount {
            #expect(abs((reference[band] - content[band]) - binWidthOffsetDb) <= 2.5,
                    "band \(band): reference \(reference[band]) vs content \(content[band])")
        }
    }

    // T5d: LIVE comparability — the whole point of choosing the 2048/1024
    // geometry: on a steady tone the reference's band reading equals the
    // live `MasterMixAnalyzer`'s settled reading (same FFT size, same Hann,
    // same 1/Σw scale, same band mapping incl. the nearest-bin rule).
    @Test("T5: reference bands match MasterMixAnalyzer's settled live bands on a steady tone (± 0.5 dB)")
    func liveGeometryComparability() throws {
        let tone = sine(frequency: 1_000, dbfs: -12, seconds: 5, sampleRate: 48_000)
        let url = try writeFloat32Wav([tone, tone], sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let reference = try ReferenceAnalyzer.analyze(fileAt: url).bandsDb

        let live = MasterMixAnalyzer(sampleRate: 48_000)
        feedMix(live, left: tone, right: tone)
        let settled = live.snapshot().bands

        let band = MasterMixAnalyzer.bandIndex(containing: 1_000)
        #expect(abs(reference[band] - Double(settled[band])) <= 0.5,
                "band \(band): reference \(reference[band]) vs live \(settled[band])")
    }

    // T6: the offline aggregates land on the live home's settled ballistic
    // values for steady signals — two homes, one set of conventions.
    @Test("T6: steady-signal stereo aggregates match MasterMixAnalyzer's settled reading")
    func stereoCrossConsistency() throws {
        let tone = sine(frequency: 440, dbfs: -12, seconds: 5, sampleRate: 48_000)
        let other = sine(frequency: 1_499, dbfs: -12, seconds: 5, sampleRate: 48_000)
        let silence = [Float](repeating: 0, count: tone.count)

        let cases: [(name: String, left: [Float], right: [Float])] = [
            ("mono", tone, tone),
            ("hard-pan L", tone, silence),
            ("decorrelated", tone, other),
        ]
        for testCase in cases {
            let url = try writeFloat32Wav([testCase.left, testCase.right], sampleRate: 48_000)
            defer { try? FileManager.default.removeItem(at: url) }
            let offline = try ReferenceAnalyzer.analyze(fileAt: url)

            let live = MasterMixAnalyzer(sampleRate: 48_000)
            feedMix(live, left: testCase.left, right: testCase.right)
            let settled = live.snapshot()

            #expect(abs(offline.correlation - Double(settled.correlation)) <= 0.02,
                    "\(testCase.name) correlation")
            #expect(abs(offline.width - Double(settled.width)) <= 0.02,
                    "\(testCase.name) width")
            #expect(abs(offline.balance - Double(settled.balance)) <= 0.02,
                    "\(testCase.name) balance")
        }
    }

    @Test("poisoned region: loudness sanitized at the door, bands/stereo stay finite")
    func poisonHonesty() throws {
        var mono = sine(frequency: 440, dbfs: -12, seconds: 2, sampleRate: 48_000)
        mono[10_000] = .nan
        mono[20_000] = .infinity
        let url = try writeFloat32Wav([mono, mono], sampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let analysis = try ReferenceAnalyzer.analyze(fileAt: url)
        for band in analysis.bandsDb { #expect(band.isFinite) }
        #expect(analysis.correlation.isFinite)
        #expect(analysis.width.isFinite)
        #expect(analysis.balance.isFinite)
        for value in [analysis.integratedLufs, analysis.truePeakDbtp,
                      analysis.maxMomentaryLufs, analysis.loudnessRangeLu] {
            if let value { #expect(value.isFinite) }
        }
    }

    @Test("unreadable file throws (never a fabricated analysis)")
    func unreadableThrows() {
        let missing = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).wav")
        #expect(throws: (any Error).self) {
            _ = try ReferenceAnalyzer.analyze(fileAt: missing)
        }
    }
}
