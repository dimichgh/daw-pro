import AVFAudio
import CryptoKit
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

    // MARK: - m23-q: pitch edits in the cache's identity

    /// ⭐⭐ **THE INVARIANCE CONTROL, AND IT IS THE FIRST THING HERE ON
    /// PURPOSE.** Adding a field to the key is how every stretched render on
    /// every machine gets orphaned by a feature that changed none of their
    /// audio. The gate is a GOLDEN REIMPLEMENTATION of the pre-m23-q formula,
    /// written out below: an edit-free clip must still key to exactly that, and
    /// an edited one must not.
    @Test("an edit-free clip keys exactly as it did before pitch edits existed")
    func editFreeClipKeyIsUnchanged() throws {
        let dir = try makeTempDir("key-src")
        let source = dir.appendingPathComponent("tone.wav")
        try writeSine(to: source, frequency: 440, seconds: 0.25)

        /// The field list as it stood before m23-q, verbatim.
        func legacyKey(ratio: Double, semitones: Double, formant: Bool) throws -> String {
            let path = source.standardizedFileURL.path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (attributes[.modificationDate] as? Date)?
                .timeIntervalSinceReferenceDate ?? 0
            var hasher = SHA256()
            for field in [
                path, String(size), String(mtime.bitPattern),
                String(ratio.bitPattern), String(semitones.bitPattern),
                formant ? "1" : "0",
                String(StretchRenderCache.stretchEngineVersion),
            ] {
                hasher.update(data: Data(field.utf8))
                hasher.update(data: Data([0]))
            }
            return String(hasher.finalize().map { String(format: "%02x", $0) }
                .joined().prefix(16))
        }

        let plain = Clip(name: "c", audioFileURL: source, stretchRatio: 1.5,
                         pitchShiftSemitones: 2, formantPreserve: true)
        let detectedOnly = Clip(name: "c", audioFileURL: source, stretchRatio: 1.5,
                                pitchShiftSemitones: 2, formantPreserve: true,
                                pitchEdits: Self.detectedOnlyEdits())
        let edited = Clip(name: "c", audioFileURL: source, stretchRatio: 1.5,
                          pitchShiftSemitones: 2, formantPreserve: true,
                          pitchEdits: Self.editedEdits(cents: 25))

        let legacy = try legacyKey(ratio: 1.5, semitones: 2, formant: true)
        let plainKey = try StretchRenderCache.cacheKey(
            source: source, params: .init(clip: plain))
        let detectedKey = try StretchRenderCache.cacheKey(
            source: source, params: .init(clip: detectedOnly))
        let editedKey = try StretchRenderCache.cacheKey(
            source: source, params: .init(clip: edited))

        #expect(plainKey == legacy,
                "the key moved for a clip with no pitch edits — every cached render is orphaned")
        #expect(detectedKey == legacy,
                "a DETECTED-but-unedited note table re-keyed the cache; it renders as nothing")
        // ⭐ The control: the gate above must be able to fail.
        #expect(editedKey != legacy, "an edited clip must NOT share the edit-free key")
        // And two different edit sets must not collide.
        let other = Clip(name: "c", audioFileURL: source, stretchRatio: 1.5,
                         pitchShiftSemitones: 2, formantPreserve: true,
                         pitchEdits: Self.editedEdits(cents: 26))
        #expect(try StretchRenderCache.cacheKey(source: source, params: .init(clip: other))
            != editedKey, "a one-cent edit did not re-key the render")
    }

    /// §6.4's "never bypass the identity path": an unstretched clip carrying a
    /// detected-but-unedited note table still plays its SOURCE FILE, and one
    /// carrying a real edit does not.
    @Test("identity bypass survives a note table and ends at a real edit")
    func identityBypassAndItsControl() async throws {
        let dir = try makeTempDir("bypass-src")
        let source = dir.appendingPathComponent("tone.wav")
        try writeSine(to: source, frequency: 220, seconds: 0.5)
        let cache = StretchRenderCache(directory: try makeTempDir("bypass-cache"))
        let clipID = UUID()

        let bypassed = try await cache.renderIfNeeded(
            clipID: clipID, source: source,
            params: .init(clip: Clip(name: "c", audioFileURL: source,
                                     pitchEdits: Self.detectedOnlyEdits())))
        #expect(bypassed == source, "a note table that bends nothing must not force a render")
        #expect(cache.renderCount == 0)

        let rendered = try await cache.renderIfNeeded(
            clipID: clipID, source: source,
            params: .init(clip: Clip(name: "c", audioFileURL: source,
                                     pitchEdits: Self.editedEdits(cents: 50))))
        #expect(rendered != source, "a real pitch edit on an unstretched clip must render")
        #expect(rendered.pathExtension == "caf")
        #expect(cache.renderCount == 1)
    }

    /// The byte gate under the branch: taking the curve path for edited clips
    /// must leave the EDIT-FREE render exactly where it was. Not "similar" —
    /// sample-for-sample, against the facade call the cache used to make
    /// unconditionally.
    @Test("an edit-free render is byte-identical to the constant facade call")
    func editFreeRenderIsByteIdenticalToTheConstantCall() async throws {
        let dir = try makeTempDir("bytes-src")
        let source = dir.appendingPathComponent("tone.wav")
        try writeSine(to: source, frequency: 330, seconds: 0.75)
        let cache = StretchRenderCache(directory: try makeTempDir("bytes-cache"))
        let url = try await cache.renderIfNeeded(
            clipID: UUID(), source: source,
            params: .init(ratio: 1.5, semitones: 2, formantPreserve: false))
        let throughCache = try TestSignals.readFile(url)
        let direct = try OfflineStretcher.stretch(
            input: try TestSignals.readFile(source), sampleRate: 48_000,
            ratio: 1.5, semitones: 2, formantPreserve: false)
        #expect(throughCache.count == direct.count)
        var differing = 0
        for channel in 0..<min(throughCache.count, direct.count) {
            #expect(throughCache[channel].count == direct[channel].count)
            for (a, b) in zip(throughCache[channel], direct[channel]) where a != b {
                differing += 1
            }
        }
        #expect(differing == 0,
                "\(differing) samples moved in an edit-free render — the curve branch leaked")
    }

    /// A render that exists is not a render that is HEARD: the playback graph
    /// re-opens a clip's file only when its `ClipKey` changes. An edit that
    /// re-keyed the cache but not the schedule would render correctly and play
    /// the old file.
    @Test("a pitch edit changes the clip's schedule identity, not just its cache key")
    func pitchEditChangesScheduleIdentity() throws {
        let fixtures = try TestSignals.fixtures()
        func key(_ edits: PitchEditSet?) -> PlaybackGraph.ClipKey {
            let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4,
                            audioFileURL: fixtures.cos1k48, pitchEdits: edits)
            return PlaybackGraph.ClipKey(
                id: clip.id, startBeat: clip.startBeat, lengthBeats: clip.lengthBeats,
                url: clip.audioFileURL, startOffsetSeconds: clip.startOffsetSeconds,
                fadeInBeats: clip.fadeInBeats, fadeOutBeats: clip.fadeOutBeats,
                fadeInCurve: clip.fadeInCurve, fadeOutCurve: clip.fadeOutCurve,
                stretchRatio: clip.stretchRatio,
                pitchShiftSemitones: clip.pitchShiftSemitones,
                formantPreserve: clip.formantPreserve, gainEnvelope: clip.gainEnvelope,
                pitchEditSetHash: PitchEditSetDigest.hex(clip.pitchEdits))
        }
        #expect(key(nil).pitchEditSetHash == key(Self.detectedOnlyEdits()).pitchEditSetHash,
                "a note table that renders as nothing must not force a re-schedule")
        #expect(key(nil).pitchEditSetHash != key(Self.editedEdits(cents: 25)).pitchEditSetHash)
        #expect(key(Self.editedEdits(cents: 25)).pitchEditSetHash
            != key(Self.editedEdits(cents: 26)).pitchEditSetHash)
    }

    /// m23-ap Phase 2, design §6.4 — **THE INVARIANCE HALF OF THE PRESET
    /// DOOR'S GATE, END TO END THROUGH THE REAL CACHE.**
    ///
    /// The menu's *Remove Tuning* calls `ProjectStore.clearClipPitchEdits`,
    /// which writes `nil` and never `PitchEditSet.empty`
    /// (`PitchCorrectionWriterTests.clearClipPitchEditsWritesNilAndIsIdempotent`
    /// pins that half). This is the other half: a clip that HAS been tuned and
    /// then cleared must render **sample-for-sample** as if it had never been
    /// tuned — same cache key, same bytes — so undoing a tuning is genuinely
    /// undoing it and not "close enough".
    ///
    /// ⭐ The positive control is the point: every assertion here is an
    /// equality, and equalities pass beautifully against a render path that
    /// ignores `pitchEdits` entirely. The tuned render must DIFFER, or the
    /// identity claims below are claims about nothing.
    @Test("a tuned-then-cleared clip renders byte-identically to one that was never tuned")
    func clearedSetRendersAsNeverTuned() async throws {
        let dir = try makeTempDir("cleared-src")
        let source = dir.appendingPathComponent("tone.wav")
        try writeSine(to: source, frequency: 330, seconds: 0.75)

        // Stretched on purpose: an unstretched, edit-free clip takes the
        // IDENTITY BYPASS and never renders at all, so a byte comparison there
        // would be comparing the source file to itself and could not fail.
        func clip(_ edits: PitchEditSet?) -> Clip {
            Clip(name: "c", audioFileURL: source, stretchRatio: 1.5,
                 pitchShiftSemitones: 2, formantPreserve: false, pitchEdits: edits)
        }
        let neverTuned = clip(nil)
        let tuned = clip(Self.editedEdits(cents: 50))
        // Cleared the way the store clears it: the tuned clip with the field put
        // back to nil, not a separately-typed clip that happens to look like one.
        var cleared = tuned
        cleared.pitchEdits = nil

        func render(_ c: Clip, _ label: String) async throws -> [[Float]] {
            let cache = StretchRenderCache(directory: try makeTempDir("cleared-\(label)"))
            let url = try await cache.renderIfNeeded(
                clipID: UUID(), source: source, params: .init(clip: c))
            #expect(cache.renderCount == 1,
                    "\(label) did not actually render — a byte comparison against a bypass proves nothing")
            return try TestSignals.readFile(url)
        }

        let never = try await render(neverTuned, "never")
        let after = try await render(cleared, "cleared")
        let withEdits = try await render(tuned, "tuned")

        // ⭐ THE POSITIVE CONTROL, FIRST, so a render path that ignores pitch
        // edits fails here rather than passing the two identities below.
        var tunedDiffering = 0
        for channel in 0..<min(never.count, withEdits.count) {
            for (a, b) in zip(never[channel], withEdits[channel]) where a != b { tunedDiffering += 1 }
        }
        #expect(tunedDiffering > 0,
                "POSITIVE CONTROL FAILED: a 50-cent tuning changed not one sample, so the byte identity asserted below is an identity between two renders that ignore pitch edits")

        #expect(never.count == after.count)
        var differing = 0
        for channel in 0..<min(never.count, after.count) {
            #expect(never[channel].count == after[channel].count)
            for (a, b) in zip(never[channel], after[channel]) where a != b { differing += 1 }
        }
        #expect(differing == 0,
                "\(differing) samples moved after a tuning was cleared — Remove Tuning does not return the audio to where it started")

        // And the key, because bytes that match under a key that moved still
        // cost a pointless re-render and a pointless re-schedule.
        #expect(try StretchRenderCache.cacheKey(source: source, params: .init(clip: cleared))
            == (try StretchRenderCache.cacheKey(source: source, params: .init(clip: neverTuned))),
                "a cleared clip does not share the never-tuned cache key")
        #expect(try StretchRenderCache.cacheKey(source: source, params: .init(clip: tuned))
            != (try StretchRenderCache.cacheKey(source: source, params: .init(clip: neverTuned))),
                "POSITIVE CONTROL FAILED: a tuned clip shares the never-tuned key, so the key equality above proves nothing")
    }

    static func detectedOnlyEdits() -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.1, endSeconds: 0.4, detectedHz: 220,
                        detectedConfidence: 0.9)
        ])
    }

    static func editedEdits(cents: Double) -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.1, endSeconds: 0.4, detectedHz: 220,
                        detectedConfidence: 0.9, pitchOffsetCents: cents)
        ])
    }
}
