import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M5 ii-d — the stretch engine wire: `StretchRenderCache` (key, hit/miss,
/// debounce, latest-wins), the scheduleAll swap + offset mapping, fade bake
/// against the stretched timeline, and the mixdown WYSIWYG wait. Spec tests
/// 4–6 of the seam memo. Serialized: several tests share real disk I/O and
/// wall-clock debounce windows.
@MainActor
@Suite("Stretch engine wire (M5 ii-d)", .serialized)
struct StretchEngineTests {
    // MARK: - Fixtures

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-stretch-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stereo Float32 WAV, identical channels — the TestSignals recipe, local
    /// so these tests own the file's mtime (cache-key invalidation bumps it).
    private func writeSine(to url: URL, frequency: Double, seconds: Double,
                           sampleRate: Double = 48_000, amplitude: Float = 0.5) throws {
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
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2.0 * .pi * frequency * Double(frame) / sampleRate))
            channels[0][frame] = value
            channels[1][frame] = value
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    /// Sine whose amplitude ramps 0 → 0.8 across the file — position in the
    /// file is observable from level, unlike a periodic constant-amp tone.
    private func writeRampedSine(to url: URL, frequency: Double, seconds: Double,
                                 sampleRate: Double = 48_000) throws {
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
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for frame in 0..<frames {
            let ramp = 0.8 * Float(frame) / Float(frames)
            let value = ramp * Float(sin(2.0 * .pi * frequency * Double(frame) / sampleRate))
            channels[0][frame] = value
            channels[1][frame] = value
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    /// Deterministic reference render through the same facade the cache uses
    /// (fixed-seed stretcher → bit-identical to the cache's CAF content).
    private func referenceStretch(source: URL, ratio: Double,
                                  semitones: Double = 0) throws -> [[Float]] {
        let planar = try TestSignals.readFile(source)
        return try OfflineStretcher.stretch(
            input: planar, sampleRate: 48_000, ratio: ratio,
            semitones: semitones, formantPreserve: false)
    }

    private func audioTrack(_ clip: Clip) -> Track {
        Track(name: "T", kind: .audio, clips: [clip])
    }

    // MARK: - Identity bypass (the null test)

    @Test("identity clips never consult the resolver and render bit-identical")
    func identityBypassIsExact() throws {
        let fixtures = try TestSignals.fixtures()
        // Fades + a source offset exercise the interesting schedule paths.
        let clip = Clip(name: "id", startBeat: 0, lengthBeats: 3,
                        audioFileURL: fixtures.cos1k48,
                        startOffsetSeconds: 0.25, fadeInBeats: 1, fadeOutBeats: 1)
        let track = audioTrack(clip)

        let plain = try OfflineRenderer().render(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0,
            durationSeconds: 1.5, masterVolume: 1)

        let spied = OfflineRenderer()
        var resolves = 0
        spied.stretchedFileProvider = { _ in
            resolves += 1
            return nil  // would silence the clip if ever consulted
        }
        let withSpy = try spied.render(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0,
            durationSeconds: 1.5, masterVolume: 1)

        #expect(resolves == 0)  // identity clips bypass the resolver entirely
        var maxDiff: Float = 0
        for channel in 0..<plain.channelData.count {
            #expect(plain.channelData[channel].count == withSpy.channelData[channel].count)
            for frame in 0..<plain.channelData[channel].count {
                maxDiff = max(maxDiff, abs(
                    plain.channelData[channel][frame] - withSpy.channelData[channel][frame]))
            }
        }
        print("[measured] identity null test max |plain − spied|: \(maxDiff)")
        #expect(maxDiff == 0)
        // And the render is real audio, not accidental silence.
        #expect(TestSignals.rms(plain.channelData[0], in: 12_000..<24_000) > 0.2)
    }

    @Test("identity mixdown through AudioEngine touches no cache")
    func identityMixdownTouchesNoCache() async throws {
        let fixtures = try TestSignals.fixtures()
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-stretch-nocache-\(UUID().uuidString)")
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: cacheDir)

        let clip = Clip(name: "id", startBeat: 0, lengthBeats: 2,
                        audioFileURL: fixtures.cos1k48)
        let out = try makeTempDir("id-mix").appendingPathComponent("mix.wav")
        _ = try await engine.renderMixdown(
            tracks: [audioTrack(clip)], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0, to: out)

        // The cache directory was never even created — no render, no entry.
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path))
        let written = try TestSignals.readFile(out)
        #expect(TestSignals.rms(written[0], in: 0..<48_000) > 0.2)
    }

    // MARK: - Cache: miss renders, hit reuses, key invalidation

    @Test("miss renders a CAF; hit reuses it; param or mtime change re-keys")
    func cacheMissHitAndInvalidation() async throws {
        let sourceDir = try makeTempDir("cache-src")
        let source = sourceDir.appendingPathComponent("tone.wav")
        try writeSine(to: source, frequency: 440, seconds: 1.0)
        let cache = StretchRenderCache(directory: try makeTempDir("cache"))
        let clipID = UUID()
        let params = StretchRenderCache.Params(ratio: 1.5, semitones: 0, formantPreserve: false)

        // Miss → renders and commits <key>.caf.
        let first = try await cache.renderIfNeeded(clipID: clipID, source: source, params: params)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(first.pathExtension == "caf")
        #expect(cache.renderCount == 1)
        // Float32 CAF at the source rate, stretched to ratio × length ±1%.
        let rendered = try AVAudioFile(forReading: first)
        #expect(rendered.processingFormat.sampleRate == 48_000)
        #expect(rendered.processingFormat.channelCount == 2)
        let expectedFrames = 1.5 * 48_000.0
        let frameError = abs(Double(rendered.length) - expectedFrames)
        #expect(frameError <= expectedFrames * 0.01)

        // Hit → same URL, no re-render.
        let second = try await cache.renderIfNeeded(clipID: clipID, source: source, params: params)
        #expect(second == first)
        #expect(cache.renderCount == 1)
        #expect(cache.status(forClip: clipID) == .idle)

        // Param change → different key, second entry.
        let pitched = StretchRenderCache.Params(ratio: 1.5, semitones: 3, formantPreserve: false)
        let third = try await cache.renderIfNeeded(clipID: clipID, source: source, params: pitched)
        #expect(third != first)
        #expect(cache.renderCount == 2)

        // Source mtime bump → different key again (same params as `first`).
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(7)], ofItemAtPath: source.path)
        let fourth = try await cache.renderIfNeeded(clipID: clipID, source: source, params: params)
        #expect(fourth != first)
        #expect(cache.renderCount == 3)
    }

    // MARK: - Stretched mixdown end to end (swap + wait, spec §4/§5)

    @Test("mixdown WAITS for a cold stretch render and bounces stretched audio")
    func stretchedMixdownEndToEnd() async throws {
        let sourceDir = try makeTempDir("e2e-src")
        let source = sourceDir.appendingPathComponent("tone440.wav")
        try writeSine(to: source, frequency: 440, seconds: 2.0)
        let cacheDir = try makeTempDir("e2e-cache")
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: cacheDir)

        // Ratio 1.5 over a 2 s source → 3 s of stretched material; lengthBeats
        // 6 @ 120 BPM = 3 s, so the clip window covers it exactly
        // (lengthBeats stays the timeline authority).
        let clip = Clip(name: "s", startBeat: 0, lengthBeats: 6,
                        audioFileURL: source, stretchRatio: 1.5)
        let out = try makeTempDir("e2e-out").appendingPathComponent("mix.wav")
        // Immediate mixdown with a COLD cache — this is the WYSIWYG wait:
        // without it the bounce would be silence.
        let info = try await engine.renderMixdown(
            tracks: [audioTrack(clip)], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 3.5, to: out)
        #expect(abs(info.durationSeconds - 3.5) < 0.001)

        let written = try TestSignals.readFile(out)
        let samples = written[0]
        // Audible well past the original 2 s source end — the stretch made it
        // 3 s long (amp 0.5 sine ⇒ RMS ≈ 0.35).
        let lateRMS = TestSignals.rms(samples, in: Int(2.2 * 48_000)..<Int(2.8 * 48_000))
        // Pitch unchanged by a pure time-stretch: ~440 Hz in the stretched window.
        let freq = TestSignals.dominantFrequency(
            byZeroCrossings: samples, sampleRate: 48_000,
            in: Int(0.5 * 48_000)..<Int(2.5 * 48_000))
        // Silence after the clip window ends at 3.0 s.
        let tailRMS = TestSignals.rms(samples, in: Int(3.05 * 48_000)..<Int(3.45 * 48_000))
        print("[measured] stretched mixdown: freq \(freq) Hz, late RMS \(lateRMS), tail RMS \(tailRMS)")
        #expect(lateRMS > 0.2)
        #expect(abs(freq - 440) <= 440 * 0.03)
        #expect(tailRMS < 0.01)
        // Exactly one committed cache entry, no partial leftovers.
        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(entries.filter { $0.hasSuffix(".caf") }.count == 1)
        #expect(!entries.contains { $0.contains(".partial-") })
    }

    // MARK: - startOffset mapping (offset × ratio, spec §4 amendment)

    @Test("startOffsetSeconds maps through the ratio into the stretched file")
    func startOffsetMapsThroughRatio() async throws {
        let sourceDir = try makeTempDir("offset-src")
        let source = sourceDir.appendingPathComponent("tone440.wav")
        // Amplitude-RAMPED sine: a pure sine is periodic (0.5 s = exactly 220
        // periods of 440 Hz), which would make the right and wrong offsets
        // nearly indistinguishable; the ramp makes file position observable.
        try writeRampedSine(to: source, frequency: 440, seconds: 2.0)
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: try makeTempDir("offset-cache"))

        // ratio 2.0, offset 0.5 s → effective file offset 1.0 s = frame 48 000
        // of the stretched render; window = lengthBeats 2 @ 120 = 1 s.
        let clip = Clip(name: "o", startBeat: 0, lengthBeats: 2,
                        audioFileURL: source, startOffsetSeconds: 0.5,
                        stretchRatio: 2.0)
        let out = try makeTempDir("offset-out").appendingPathComponent("mix.wav")
        _ = try await engine.renderMixdown(
            tracks: [audioTrack(clip)], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0, to: out)

        let written = try TestSignals.readFile(out)
        // The facade is deterministic (fixed seed), so this reference equals
        // the cache's CAF content bit for bit.
        let reference = try referenceStretch(source: source, ratio: 2.0)
        let offsetFrames = 48_000  // 0.5 s × 2.0 × 48 kHz
        var maxDiff: Float = 0
        for frame in 0..<40_000 {
            maxDiff = max(maxDiff, abs(written[0][frame] - reference[0][offsetFrames + frame]))
        }
        print("[measured] offset mapping max |mixdown − reference[+48000]|: \(maxDiff)")
        #expect(maxDiff < 1e-3)
        // Sanity: the mapped window is NOT the unmapped one (offset 0.5 s
        // UNscaled would read frame 24 000) — the source ramp puts audibly
        // less level there, so a wrong-offset schedule cannot pass the
        // bit-exact assert above by coincidence.
        var unmappedDiff: Float = 0
        for frame in 0..<4_000 {
            unmappedDiff = max(unmappedDiff, abs(written[0][frame] - reference[0][24_000 + frame]))
        }
        #expect(unmappedDiff > 0.05)
    }

    // MARK: - Fades bake against the stretched timeline (spec §4 ordering)

    @Test("fade-in envelope matches Clip.envelopeGain on the STRETCHED timeline")
    func fadesBakeAgainstStretchedTimeline() async throws {
        let sourceDir = try makeTempDir("fade-src")
        let source = sourceDir.appendingPathComponent("tone440.wav")
        try writeSine(to: source, frequency: 440, seconds: 2.0)
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: try makeTempDir("fade-cache"))

        // ratio 1.5 (stretched material 3 s), window 4 beats @ 120 = 2 s,
        // fade-in 1 beat = 0.5 s = 24 000 frames of the TIMELINE — which is
        // the stretched file's domain, not the source's.
        let clip = Clip(name: "f", startBeat: 0, lengthBeats: 4,
                        audioFileURL: source, fadeInBeats: 1,
                        stretchRatio: 1.5)
        let out = try makeTempDir("fade-out").appendingPathComponent("mix.wav")
        _ = try await engine.renderMixdown(
            tracks: [audioTrack(clip)], tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 2.0, to: out)

        let written = try TestSignals.readFile(out)
        let reference = try referenceStretch(source: source, ratio: 1.5)
        let framesPerBeat = 24_000.0  // 48 000 × 60 / 120
        var maxDiff: Float = 0
        for frame in 0..<30_000 {  // fade window (24 000) + post-fade margin
            let beat = Double(frame) / framesPerBeat
            let expected = reference[0][frame] * Float(clip.envelopeGain(atBeat: beat))
            maxDiff = max(maxDiff, abs(written[0][frame] - expected))
        }
        print("[measured] stretched fade envelope max |mixdown − ref×env|: \(maxDiff)")
        #expect(maxDiff < 2e-3)
        // The fade is real: near-zero at the head, full level after it.
        #expect(TestSignals.peak(written[0], in: 0..<200) < 0.02)
        #expect(TestSignals.rms(written[0], in: 26_000..<30_000) > 0.3)
    }

    // MARK: - Latest-wins cancellation (spec §5 debounce contract)

    @Test("two rapid requests: the first is cancelled, only the second's CAF exists")
    func latestWinsCancelsInFlight() async throws {
        let sourceDir = try makeTempDir("cancel-src")
        let source = sourceDir.appendingPathComponent("tone.wav")
        try writeSine(to: source, frequency: 440, seconds: 1.0)
        let cacheDir = try makeTempDir("cancel-cache")
        let cache = StretchRenderCache(directory: cacheDir)
        let clipID = UUID()
        let paramsA = StretchRenderCache.Params(ratio: 1.5, semitones: 0, formantPreserve: false)
        let paramsB = StretchRenderCache.Params(ratio: 2.0, semitones: 0, formantPreserve: false)

        let first = Task { @MainActor in
            try await cache.renderIfNeeded(clipID: clipID, source: source, params: paramsA)
        }
        // Let the first request register its job — still inside its 250 ms
        // debounce window when the second lands.
        try await Task.sleep(for: .milliseconds(50))
        #expect(cache.status(forClip: clipID) == .rendering)
        let urlB = try await cache.renderIfNeeded(clipID: clipID, source: source, params: paramsB)

        await #expect(throws: (any Error).self) { _ = try await first.value }
        #expect(FileManager.default.fileExists(atPath: urlB.path))
        let keyA = try StretchRenderCache.cacheKey(source: source, params: paramsA)
        #expect(!FileManager.default.fileExists(
            atPath: cacheDir.appendingPathComponent(keyA + ".caf").path))
        // The superseded job died in its debounce — it never rendered.
        #expect(cache.renderCount == 1)
        #expect(cache.status(forClip: clipID) == .idle)
        // No partials left behind.
        let entries = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        #expect(entries == [urlB.lastPathComponent])
    }

    // MARK: - Pending clips schedule as silence (never wrong-speed audio)

    @Test("a non-identity clip with no render bounces silent, not wrong-speed")
    func pendingClipIsSilentOffline() throws {
        let fixtures = try TestSignals.fixtures()
        let clip = Clip(name: "p", startBeat: 0, lengthBeats: 4,
                        audioFileURL: fixtures.cos1k48, stretchRatio: 1.5)
        // No stretchedFileProvider wired → resolver answers .pending.
        let rendered = try OfflineRenderer().render(
            tracks: [audioTrack(clip)], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0,
            durationSeconds: 1.0, masterVolume: 1)
        #expect(TestSignals.peak(rendered.channelData[0], in: 0..<48_000) == 0)
    }
}
