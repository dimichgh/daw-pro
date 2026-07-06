import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M5 iii-e — transient detection (comping/quantize spec §5a, §9):
/// synthetic-click accuracy within ±5 ms, no spurious extras, decaying-pad
/// negative case, min-separation merging, sensitivity monotonicity,
/// determinism, and the TransientCache sidecar discipline (hit skips the
/// analyzer, mtime/sensitivity re-key, corrupt sidecar self-heals) plus the
/// engine-protocol surface. Serialized: cache tests share real disk I/O.
@MainActor
@Suite("Transient detection (M5 iii-e)", .serialized)
struct TransientAnalyzerTests {
    static let sampleRate = 48_000.0

    // MARK: - Synthesis helpers (deterministic, mono)

    /// Alternating-sign exponentially decaying 64-sample burst at each click
    /// time — broadband energy with a sharp attack, the drum-hit shape the
    /// detector is for.
    private func clickTrain(seconds: Double, clickTimes: [Double],
                            amplitude: Float = 0.9) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * Self.sampleRate))
        addClicks(to: &samples, at: clickTimes, amplitude: amplitude)
        return samples
    }

    private func addClicks(to samples: inout [Float], at times: [Double], amplitude: Float) {
        for time in times {
            let start = Int(time * Self.sampleRate)
            for i in 0..<64 where start + i < samples.count {
                samples[start + i] += amplitude * pow(0.85, Float(i))
                    * (i.isMultiple(of: 2) ? 1 : -1)
            }
        }
    }

    /// Deterministic pseudo-noise (LCG) — a reproducible background bed.
    private func addNoise(to samples: inout [Float], amplitude: Float, seed: UInt64 = 42) {
        var state = seed
        for i in samples.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24)  // 0..<1
            samples[i] += amplitude * (unit * 2 - 1)
        }
    }

    /// Writes MONO samples as a Float32 WAV (the TestSignals recipe, mono
    /// variant — these tests own the file's mtime for cache re-key checks).
    private func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate, channels: 1,
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
            .appendingPathComponent("daw-pro-transients-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Accuracy (spec §9: clicks at known positions, ±5 ms)

    @Test("click train: every onset found within ±5 ms, no spurious extras")
    func clickTrainAccuracy() {
        // Deliberately NOT hop/block-aligned times.
        let clickTimes = [0.500, 0.983, 1.510, 2.007, 2.499]
        let samples = clickTrain(seconds: 3.0, clickTimes: clickTimes)
        let markers = TransientAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate, sensitivity: 0.5)

        #expect(markers.count == clickTimes.count)
        var maxErrorMs = 0.0
        for (marker, expected) in zip(markers, clickTimes) {
            maxErrorMs = max(maxErrorMs, abs(marker.timeSeconds - expected) * 1000)
            #expect(abs(marker.timeSeconds - expected) <= 0.005,
                    "onset \(marker.timeSeconds) vs expected \(expected)")
        }
        print("[measured] click-train onset max |error|: \(maxErrorMs) ms (bar: 5 ms)")
        // Strengths are normalized: all in 0...1 with the strongest at 1.
        #expect(markers.allSatisfy { (0...1).contains($0.strength) })
        #expect(markers.map(\.strength).max() == 1.0)
        // Sorted output.
        #expect(markers.map(\.timeSeconds) == markers.map(\.timeSeconds).sorted())
    }

    @Test("clicks over a noise bed still land within ±5 ms")
    func clicksOverNoise() {
        let clickTimes = [0.4, 1.1, 1.8, 2.6]
        var samples = clickTrain(seconds: 3.0, clickTimes: clickTimes)
        addNoise(to: &samples, amplitude: 0.02)
        let markers = TransientAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate, sensitivity: 0.5)

        #expect(markers.count == clickTimes.count)
        for (marker, expected) in zip(markers, clickTimes) {
            #expect(abs(marker.timeSeconds - expected) <= 0.005,
                    "onset \(marker.timeSeconds) vs expected \(expected)")
        }
    }

    @Test("decaying pad: one onset at the attack, none in the tail")
    func decayingPadNoTailOnsets() {
        // 0.5 s silence, then a 5 ms attack ramp into a 220 Hz pad decaying
        // over 2 s — steady decay has ~zero POSITIVE flux by construction.
        let seconds = 2.5
        var samples = [Float](repeating: 0, count: Int(seconds * Self.sampleRate))
        let attackTime = 0.5
        for i in samples.indices {
            let t = Double(i) / Self.sampleRate
            guard t >= attackTime else { continue }
            let since = t - attackTime
            let attack = min(1.0, since / 0.005)
            let envelope = attack * exp(-2.0 * since)
            samples[i] = Float(0.6 * envelope * sin(2 * .pi * 220 * t))
        }
        let markers = TransientAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate, sensitivity: 0.5)

        #expect(markers.count == 1)
        if let onset = markers.first {
            #expect(abs(onset.timeSeconds - attackTime) <= 0.010)
        }
        #expect(!markers.contains { $0.timeSeconds > attackTime + 0.1 },
                "no onsets past the attack: \(markers)")
    }

    @Test("silence and empty input yield no markers")
    func silenceYieldsNothing() {
        let silence = [Float](repeating: 0, count: 48_000)
        #expect(TransientAnalyzer.analyze(
            monoSamples: silence, sampleRate: Self.sampleRate, sensitivity: 1.0).isEmpty)
        #expect(TransientAnalyzer.analyze(
            monoSamples: [], sampleRate: Self.sampleRate, sensitivity: 1.0).isEmpty)
        #expect(TransientAnalyzer.analyze(
            monoSamples: [Float](repeating: 0, count: 100),  // < one window
            sampleRate: Self.sampleRate, sensitivity: 1.0).isEmpty)
    }

    // MARK: - Min separation + sensitivity

    @Test("onsets closer than 30 ms merge into one")
    func minSeparationMerging() {
        // 12 ms apart — inside the 30 ms floor; the pair must merge.
        let samples = clickTrain(seconds: 2.0, clickTimes: [0.5, 0.512, 1.5])
        let markers = TransientAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate, sensitivity: 1.0)
        #expect(markers.count == 2)
        // Every surviving pair respects the separation floor.
        for (a, b) in zip(markers, markers.dropFirst()) {
            #expect(b.timeSeconds - a.timeSeconds >= 0.030)
        }
    }

    @Test("higher sensitivity never finds fewer onsets (superset-ish ordering)")
    func sensitivityMonotonicity() {
        // Strong clicks + weak clicks over a noise bed: low sensitivity should
        // keep the strong ones; raising it can only add.
        var samples = clickTrain(seconds: 3.0, clickTimes: [0.5, 1.5], amplitude: 0.9)
        addClicks(to: &samples, at: [1.0, 2.0, 2.5], amplitude: 0.10)
        addNoise(to: &samples, amplitude: 0.03)

        let counts = [0.0, 0.5, 1.0].map { sensitivity in
            TransientAnalyzer.analyze(monoSamples: samples,
                                      sampleRate: Self.sampleRate,
                                      sensitivity: sensitivity).count
        }
        #expect(counts[0] <= counts[1] && counts[1] <= counts[2],
                "counts not monotone: \(counts)")
        #expect(counts[0] >= 2, "strong clicks must survive the strictest threshold")
    }

    @Test("sensitivity maps 0→k=3.0, 1→k=1.2 linearly and clamps")
    func sensitivityMapping() {
        #expect(TransientAnalyzer.thresholdMultiplier(forSensitivity: 0) == 3.0)
        #expect(abs(TransientAnalyzer.thresholdMultiplier(forSensitivity: 1) - 1.2) < 1e-12)
        #expect(abs(TransientAnalyzer.thresholdMultiplier(forSensitivity: 0.5) - 2.1) < 1e-12)
        #expect(TransientAnalyzer.thresholdMultiplier(forSensitivity: -5) == 3.0)
        #expect(abs(TransientAnalyzer.thresholdMultiplier(forSensitivity: 7) - 1.2) < 1e-12)
    }

    @Test("determinism: two runs produce identical markers")
    func determinism() throws {
        var samples = clickTrain(seconds: 3.0, clickTimes: [0.4, 1.1, 1.8, 2.6])
        addNoise(to: &samples, amplitude: 0.02)
        let first = TransientAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate, sensitivity: 0.5)
        let second = TransientAnalyzer.analyze(
            monoSamples: samples, sampleRate: Self.sampleRate, sensitivity: 0.5)
        #expect(first == second)
        #expect(!first.isEmpty)

        // File path too: read → mono mix → identical to the in-memory run.
        let dir = try makeTempDir("determinism")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(samples, to: wav)
        let fromFile = try TransientAnalyzer.analyze(fileAt: wav, sensitivity: 0.5)
        #expect(fromFile == first)
    }

    // MARK: - Cache (StretchRenderCache discipline)

    @Test("cache hit skips the analyzer; results identical; sidecar committed")
    func cacheHitSkipsAnalysis() async throws {
        let dir = try makeTempDir("hit")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 2.0, clickTimes: [0.5, 1.0, 1.5]), to: wav)
        let cache = TransientCache(directory: dir.appendingPathComponent("maps"))

        let first = try await cache.markers(source: wav, sensitivity: 0.5)
        #expect(cache.analysisCount == 1)
        #expect(first.count == 3)

        let second = try await cache.markers(source: wav, sensitivity: 0.5)
        #expect(cache.analysisCount == 1, "second call must be a sidecar hit")
        #expect(second == first)

        // Exactly one committed sidecar, no leftover partials.
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: cache.directory.path)
        #expect(entries.count == 1)
        #expect(entries[0].hasSuffix(".json"))
        #expect(!entries[0].contains("partial"))
    }

    @Test("mtime bump re-keys and re-analyzes")
    func mtimeBumpRekeys() async throws {
        let dir = try makeTempDir("mtime")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 2.0, clickTimes: [0.5, 1.0]), to: wav)
        let cache = TransientCache(directory: dir.appendingPathComponent("maps"))

        _ = try await cache.markers(source: wav, sensitivity: 0.5)
        #expect(cache.analysisCount == 1)

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: wav.path)
        let after = try await cache.markers(source: wav, sensitivity: 0.5)
        #expect(cache.analysisCount == 2, "touched source must re-analyze")
        #expect(after.count == 2)
    }

    @Test("sensitivity re-keys — but only past the 0.05 quantization step")
    func sensitivityRekeys() async throws {
        let dir = try makeTempDir("sensitivity")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 2.0, clickTimes: [0.5, 1.0]), to: wav)
        let cache = TransientCache(directory: dir.appendingPathComponent("maps"))

        _ = try await cache.markers(source: wav, sensitivity: 0.3)
        #expect(cache.analysisCount == 1)
        _ = try await cache.markers(source: wav, sensitivity: 0.8)
        #expect(cache.analysisCount == 2, "different sensitivity must re-key")
        // 0.51 and 0.49 both quantize to 0.5 — same key, no third analysis
        // after a 0.5 entry exists.
        _ = try await cache.markers(source: wav, sensitivity: 0.5)
        #expect(cache.analysisCount == 3)
        _ = try await cache.markers(source: wav, sensitivity: 0.51)
        _ = try await cache.markers(source: wav, sensitivity: 0.49)
        #expect(cache.analysisCount == 3, "0.05-step quantization must coalesce keys")

        // Key derivation agrees.
        let key49 = try TransientCache.cacheKey(
            source: wav, quantizedSensitivity: TransientCache.quantizedSensitivity(0.49))
        let key51 = try TransientCache.cacheKey(
            source: wav, quantizedSensitivity: TransientCache.quantizedSensitivity(0.51))
        let key80 = try TransientCache.cacheKey(
            source: wav, quantizedSensitivity: TransientCache.quantizedSensitivity(0.8))
        #expect(key49 == key51)
        #expect(key49 != key80)
    }

    @Test("corrupt sidecar recomputes and self-heals")
    func corruptSidecarRecomputes() async throws {
        let dir = try makeTempDir("corrupt")
        let wav = dir.appendingPathComponent("clicks.wav")
        try writeWAV(clickTrain(seconds: 2.0, clickTimes: [0.5, 1.0]), to: wav)
        let cache = TransientCache(directory: dir.appendingPathComponent("maps"))

        let first = try await cache.markers(source: wav, sensitivity: 0.5)
        #expect(cache.analysisCount == 1)

        // Corrupt the committed sidecar in place.
        let key = try TransientCache.cacheKey(
            source: wav, quantizedSensitivity: TransientCache.quantizedSensitivity(0.5))
        let sidecar = cache.directory.appendingPathComponent(key + ".json")
        try Data("not json".utf8).write(to: sidecar)

        let healed = try await cache.markers(source: wav, sensitivity: 0.5)
        #expect(cache.analysisCount == 2, "corrupt sidecar must recompute")
        #expect(healed == first)
        // And the sidecar is valid again.
        #expect(TransientCache.readSidecar(at: sidecar) == first)
    }

    @Test("missing source file throws")
    func missingSourceThrows() async throws {
        let dir = try makeTempDir("missing")
        let cache = TransientCache(directory: dir.appendingPathComponent("maps"))
        await #expect(throws: (any Error).self) {
            _ = try await cache.markers(
                source: dir.appendingPathComponent("nope.wav"), sensitivity: 0.5)
        }
    }

    // MARK: - Engine protocol surface

    @Test("AudioEngine.detectTransients answers through the cache, off the render path")
    func engineProtocolSurface() async throws {
        let dir = try makeTempDir("engine")
        let wav = dir.appendingPathComponent("clicks.wav")
        let clickTimes = [0.5, 1.0, 1.5]
        try writeWAV(clickTrain(seconds: 2.0, clickTimes: clickTimes), to: wav)

        let engine = AudioEngine()  // never prepared — no hardware started
        engine.transientCache = TransientCache(directory: dir.appendingPathComponent("maps"))

        let markers = try await engine.detectTransients(inFileAt: wav, sensitivity: 0.5)
        #expect(markers.count == 3)
        for (marker, expected) in zip(markers, clickTimes) {
            #expect(abs(marker.timeSeconds - expected) <= 0.005)
        }
        // Second call: sidecar hit, identical.
        let again = try await engine.detectTransients(inFileAt: wav, sensitivity: 0.5)
        #expect(again == markers)
        #expect(engine.transientCache.analysisCount == 1)
    }
}
