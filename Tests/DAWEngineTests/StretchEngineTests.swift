import AVFAudio
import CryptoKit
@testable import DAWCore  // C2-0 physics test builds its track directly (`tracks` is internal(set))
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

    /// I7a/U-C (interaction-batch design §10, ruled in §17), END TO END
    /// THROUGH THE REAL CACHE. An UNSTRETCHED clip whose only edit is a
    /// cleared note is exactly the case the identity bypass could swallow:
    /// if a clear digested to nothing, `renderIfNeeded` would hand back the
    /// SOURCE and the note would play. The render must happen, the note must
    /// be exact zeros between its ramps, and everything else must keep the
    /// source's bytes (the level-only path runs no stretcher).
    /// `NoteLevelRenderTests` pins the physics in depth; this pins the door.
    /// It lives in this existing suite so the `@MainActor` suite count does
    /// not move.
    @Test("I7a: a clip whose only edit is a cleared note renders through the cache, not the bypass, and plays exact zeros there")
    func clearedNoteRendersThroughTheCache() async throws {
        let dir = try makeTempDir("i7a-src")
        let source = dir.appendingPathComponent("tone.wav")
        try writeSine(to: source, frequency: 220.625, seconds: 1.0)
        let cache = StretchRenderCache(directory: try makeTempDir("i7a-cache"))
        var note = NoteSegment(startSeconds: 0.40, endSeconds: 0.60, detectedHz: 220.625,
                               detectedConfidence: 0.9)

        // CONTROL: the same note, not cleared, takes the bypass. So a render
        // below is caused by the flag, not by the table.
        let untouched = Clip(name: "c", audioFileURL: source,
                             pitchEdits: PitchEditSet(segments: [note]))
        let bypassed = try await cache.renderIfNeeded(clipID: UUID(), source: source,
                                                      params: .init(clip: untouched))
        #expect(bypassed == source)
        #expect(cache.renderCount == 0)

        note.isCleared = true
        let cleared = Clip(name: "c", audioFileURL: source,
                           pitchEdits: PitchEditSet(segments: [note]))
        #expect(cleared.stretchRatio == 1 && cleared.pitchShiftSemitones == 0,
                "unstretched on purpose: the bypass is what is under test")
        #expect(cleared.hasPitchEdits && StretchRenderCache.needsRender(cleared))
        let url = try await cache.renderIfNeeded(clipID: UUID(), source: source,
                                                 params: .init(clip: cleared))
        #expect(url != source, "a cleared note took the identity bypass and plays the source")
        #expect(cache.renderCount == 1)

        let rendered = try TestSignals.readFile(url)
        let original = try TestSignals.readFile(source)
        #expect(rendered.map(\.count) == original.map(\.count))
        let plateau = 19_681..<28_319  // source 0.41..0.59 s at 48 kHz, one frame trimmed each end
        var nonZero = 0
        for channel in rendered.indices {
            for frame in plateau where rendered[channel][frame] != 0 { nonZero += 1 }
        }
        #expect(nonZero == 0, "\(nonZero) non-zero samples between the cleared note's ramps")
        var moved = 0
        for channel in rendered.indices {
            for frame in Array(0..<19_199) + Array(28_801..<original[channel].count)
            where rendered[channel][frame].bitPattern != original[channel][frame].bitPattern {
                moved += 1
            }
        }
        #expect(moved == 0, "\(moved) samples outside the cleared note left the source's bytes")
    }

    // MARK: - p2-ren Stage A, G4: an unedited project's offline render (env-gated)

    /// G4 of `docs/design/2026-09-25-incremental-note-render.md` §12: an
    /// unedited project's offline render is byte-identical before and after
    /// the bridge. ENV-GATED: it writes ONE mixdown WAV to
    /// `REN_A_G4_OUT/unedited-<REN_A_G4_LABEL>.wav`; two labels are compared
    /// with `cmp` outside the test. The project holds every clip kind the
    /// bridge touches (identity with fades and an offset, stretched and
    /// transposed, tuned, a cleared note), is OPENED in a live engine first
    /// and waits until every render has reached its node, so the resolver and
    /// the file-opened memo both run before the bounce. Nothing plays.
    @Test("p2-ren Stage A G4: an unedited project's offline render, written for a before/after byte compare (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["REN_A_G4_OUT"] != nil))
    func uneditedProjectRenderForByteCompare() async throws {
        let env = ProcessInfo.processInfo.environment
        let out = URL(fileURLWithPath: try #require(env["REN_A_G4_OUT"]))
        let label = env["REN_A_G4_LABEL"] ?? "run"
        let work = out.appendingPathComponent("work-\(label)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let plainSource = work.appendingPathComponent("plain.wav")
        try writeRampedSine(to: plainSource, frequency: 330, seconds: 2.0)
        let stretchSource = work.appendingPathComponent("stretch.wav")
        try writeSine(to: stretchSource, frequency: 440, seconds: 1.5)
        let tunedSource = work.appendingPathComponent("tuned.wav")
        try writeSine(to: tunedSource, frequency: 220, seconds: 2.0)
        var cleared = NoteSegment(startSeconds: 1.2, endSeconds: 1.5, detectedHz: 220,
                                  detectedConfidence: 0.9)
        cleared.isCleared = true
        let clips = [
            Clip(name: "plain", startBeat: 0, lengthBeats: 3.5, audioFileURL: plainSource,
                 startOffsetSeconds: 0.25, fadeInBeats: 0.5, fadeOutBeats: 0.5),
            Clip(name: "stretched", startBeat: 0, lengthBeats: 4.5, audioFileURL: stretchSource,
                 stretchRatio: 1.5, pitchShiftSemitones: 2),
            Clip(name: "tuned", startBeat: 0, lengthBeats: 4, audioFileURL: tunedSource,
                 pitchEdits: PitchEditSet(segments: [
                     NoteSegment(startSeconds: 0.2, endSeconds: 0.8, detectedHz: 220,
                                 detectedConfidence: 0.9, pitchOffsetCents: 100),
                     cleared,
                 ])),
        ]
        let tracks = clips.map { Track(name: $0.name, kind: .audio, clips: [$0]) }
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: work.appendingPathComponent("cache"))
        engine.tracksDidChange(tracks)
        // Every render reaches its node in the live graph before the bounce.
        let deadline = Date().addingTimeInterval(60)
        func landed() -> Bool {
            clips.allSatisfy { clip in
                guard StretchRenderCache.needsRender(clip) else { return true }
                guard let played = engine.graph.clipFileURLForTesting(clipID: clip.id),
                      let source = clip.audioFileURL,
                      let committed = engine.stretchCache.cachedURL(
                          source: source, params: StretchRenderCache.Params(clip: clip))
                else { return false }
                return played.standardizedFileURL == committed.standardizedFileURL
            }
        }
        while !landed(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(landed(), "the project's renders never reached their nodes")
        let wav = out.appendingPathComponent("unedited-\(label).wav")
        try? FileManager.default.removeItem(at: wav)
        _ = try await engine.renderMixdown(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 3.0, to: wav)
        let written = try TestSignals.readFile(wav)
        let rms = TestSignals.rms(written[0], in: 0..<(3 * 48_000))
        print("[measured] p2-ren G4 unedited render '\(label)': \(wav.path), "
              + "\(written[0].count) frames, RMS \(rms)")
        #expect(rms > 0.1, "the unedited render is not audible: RMS \(rms)")
        #expect(!engine.isRunning, "the G4 harness started the audio hardware")
    }

    // MARK: - p2-ren Stage A: THE BRIDGE (design 2026-09-25-incremental-note-render §11)
    //
    // While an edit's render is pending, a clip whose new render has the SAME
    // time base as the file it last played keeps playing that file instead of
    // going silent. Every test here runs the REAL engine with no hardware
    // (nothing calls `prepare`) and asserts what the clip PLAYS, as rendered
    // audio, not merely which URL a node holds.

    private static let bridgeNoteID = UUID()

    /// One note, 0.1–0.9 s of a 1 s tone, at `cents` (and a timing delta).
    private static func bridgeNote(cents: Double, timing: Double = 0) -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(id: bridgeNoteID, startSeconds: 0.1, endSeconds: 0.9, detectedHz: 440,
                        detectedConfidence: 0.9, pitchOffsetCents: cents,
                        timeStartDeltaSeconds: timing)
        ])
    }

    /// A 1 s amplitude-RAMPED 440 Hz tone (48 000 frames): position in the
    /// file is observable from level, so a bridge played at the wrong place
    /// or speed cannot match by coincidence.
    private func bridgeSource(_ label: String) throws -> URL {
        let url = try makeTempDir("bridge-\(label)-src").appendingPathComponent("tone.wav")
        try writeRampedSine(to: url, frequency: 440, seconds: 1.0)
        return url
    }

    private func bridgeEngine(_ label: String) throws -> AudioEngine {
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: try makeTempDir("bridge-\(label)-cache"))
        return engine
    }

    /// True once the clip's node plays what it should play for `clip` as it
    /// now stands: the committed render, or the source for an identity clip.
    private func committedPlays(_ engine: AudioEngine, _ clip: Clip) -> Bool {
        guard let played = engine.graph.clipFileURLForTesting(clipID: clip.id),
              let source = clip.audioFileURL else { return false }
        let expected = StretchRenderCache.needsRender(clip)
            ? engine.stretchCache.cachedURL(source: source, params: StretchRenderCache.Params(clip: clip))
            : source
        guard let expected else { return false }
        return played.standardizedFileURL == expected.standardizedFileURL
    }

    /// A HANG GUARD (`HangGuard`), never a latency claim: the Stage A
    /// events (a render landing, a failure on record, a bridge ending) each
    /// need main-actor turns, which the full suite hands out slowly.
    private func waitUntil(_ seconds: Double = HangGuard.seconds, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// WHAT THE CLIP PLAYS RIGHT NOW, as audio: an offline render handed the
    /// file the clip's LIVE node opened (a render, a bridge or a source), and
    /// nothing when the clip has no node. No resolver call: looking must not
    /// change what plays.
    private func livePlays(_ engine: AudioEngine, _ clip: Clip, seconds: Double = 1.2) throws -> [[Float]] {
        let file = engine.graph.clipFileURLForTesting(clipID: clip.id)
        let renderer = OfflineRenderer()
        renderer.stretchedFileProvider = { asked in asked.id == clip.id ? file : nil }
        return try renderer.render(tracks: [audioTrack(clip)], tempoMap: TempoMap(constantBPM: 120),
                                   fromBeat: clip.startBeat, durationSeconds: seconds,
                                   masterVolume: 1).channelData
    }

    private static func differingSamples(_ a: [[Float]], _ b: [[Float]]) -> Int {
        guard a.count == b.count else { return Int.max }
        var count = 0
        for (x, y) in zip(a, b) {
            guard x.count == y.count else { return Int.max }
            for index in x.indices where x[index].bitPattern != y[index].bitPattern { count += 1 }
        }
        return count
    }

    /// Pitch inside the note (0.35–0.65 s, clear of the retune ramps).
    private static func notePitch(_ audio: [[Float]]) -> Double {
        TestSignals.dominantFrequency(byZeroCrossings: audio[0], sampleRate: 48_000,
                                      in: 16_800..<31_200)
    }

    private static func isPitch(_ hz: Double, cents: Double) -> Bool {
        let target = 440 * pow(2, cents / 1200)
        return abs(hz - target) <= target * 0.015
    }

    /// Opens `clip` alone on `engine` and waits until it plays as set.
    private func openLanded(_ engine: AudioEngine, _ clip: Clip) async throws -> Track {
        let track = audioTrack(clip)
        engine.tracksDidChange([track])
        try #require(try await waitUntil { committedPlays(engine, clip) },
                     "the clip's first render never reached its node")
        return track
    }

    @Test("p2-ren Stage A: while a pitch-only edit's render is pending the clip plays its PREVIOUS render, byte for byte what played before the edit (the old pitch, same place, same speed); the note audition refuses it; then the new render plays")
    func pitchEditBridgesOnThePreviousRender() async throws {
        let source = try bridgeSource("pitch")
        let engine = try bridgeEngine("pitch")
        let before = Clip(name: "v", startBeat: 0, lengthBeats: 2, audioFileURL: source,
                          pitchEdits: Self.bridgeNote(cents: 100))
        var track = try await openLanded(engine, before)
        let previous = try #require(engine.graph.clipFileURLForTesting(clipID: before.id))
        let heardBefore = try livePlays(engine, before)
        #expect(Self.isPitch(Self.notePitch(heardBefore), cents: 100), "premise: +100 c before the edit")

        var after = before
        after.pitchEdits = Self.bridgeNote(cents: 300)
        track.clips = [after]
        engine.tracksDidChange([track])
        #expect(engine.graph.isPlayingBridge(clipID: after.id), "the pitch edit did not bridge")
        #expect(engine.graph.clipFileURLForTesting(clipID: after.id)?.standardizedFileURL
                == previous.standardizedFileURL)
        #expect(engine.bridgeResolutionCountForTesting == 1)
        // The note audition plays the note AS EDITED or nothing: never the bridge.
        #expect(engine.planClipSpanAudition(trackID: track.id, clipID: after.id,
                                            startSourceSeconds: 0.3, endSourceSeconds: 0.6)
                == .refused(.inaudibleNotReady))

        let heardBridge = try livePlays(engine, after)
        let differing = Self.differingSamples(heardBridge, heardBefore)
        let bridgeHz = Self.notePitch(heardBridge)
        let tail = TestSignals.rms(heardBridge[0], in: Int(1.02 * 48_000)..<Int(1.15 * 48_000))
        let late = TestSignals.rms(heardBridge[0], in: Int(0.85 * 48_000)..<Int(0.95 * 48_000))
        let early = TestSignals.rms(heardBridge[0], in: Int(0.05 * 48_000)..<Int(0.15 * 48_000))
        print("[measured] p2-ren bridge (pitch edit): \(differing) samples differ from the pre-edit "
              + "playback; note pitch \(bridgeHz) Hz; RMS early \(early), late \(late), past the clip \(tail)")
        #expect(differing == 0, "the bridge is not what played before the edit")
        #expect(Self.isPitch(bridgeHz, cents: 100), "the bridge plays \(bridgeHz) Hz, not the previous +100 c")
        #expect(late > 3 * early, "the source's level ramp is not where it should be")
        #expect(tail < 1e-4, "audio past the clip's 1 s: the bridge plays at the wrong speed")

        try #require(try await waitUntil { committedPlays(engine, after) }, "the +300 c render never landed")
        #expect(!engine.graph.isPlayingBridge(clipID: after.id))
        let heardAfter = try livePlays(engine, after)
        #expect(Self.isPitch(Self.notePitch(heardAfter), cents: 300),
                "after the landing: \(Self.notePitch(heardAfter)) Hz")
        #expect(engine.planClipSpanAudition(trackID: track.id, clipID: after.id,
                                            startSourceSeconds: 0.3, endSourceSeconds: 0.6)
                != .refused(.inaudibleNotReady))
        #expect(!engine.isRunning)
    }

    @Test("p2-ren Stage A: an untouched clip's first pitch edit bridges on its SOURCE, byte for byte what played before; the new pitch arrives with the render")
    func identityClipFirstEditBridgesOnItsSource() async throws {
        let source = try bridgeSource("identity")
        let engine = try bridgeEngine("identity")
        let before = Clip(name: "v", startBeat: 0, lengthBeats: 2, audioFileURL: source,
                          pitchEdits: Self.bridgeNote(cents: 0))
        #expect(!StretchRenderCache.needsRender(before), "premise: a note table alone is identity")
        var track = try await openLanded(engine, before)
        #expect(engine.lastPlayedForTesting(clipID: before.id)?.fileURL.standardizedFileURL
                == source.standardizedFileURL, "the memo must follow identity clips too")
        let heardBefore = try livePlays(engine, before)

        var after = before
        after.pitchEdits = Self.bridgeNote(cents: 200)
        track.clips = [after]
        engine.tracksDidChange([track])
        #expect(engine.graph.isPlayingBridge(clipID: after.id))
        #expect(engine.graph.clipFileURLForTesting(clipID: after.id)?.standardizedFileURL
                == source.standardizedFileURL)
        let heardBridge = try livePlays(engine, after)
        let differing = Self.differingSamples(heardBridge, heardBefore)
        print("[measured] p2-ren bridge (identity → first edit): \(differing) samples differ; "
              + "note pitch \(Self.notePitch(heardBridge)) Hz")
        #expect(differing == 0)
        #expect(Self.isPitch(Self.notePitch(heardBridge), cents: 0))

        try #require(try await waitUntil { committedPlays(engine, after) }, "the +200 c render never landed")
        #expect(Self.isPitch(Self.notePitch(try livePlays(engine, after)), cents: 200))
        #expect(!engine.isRunning)
    }

    @Test("p2-ren Stage A: a ratio edit never bridges, not even one whose render has the previous file's exact length (ratio 1 → 1.00001 on 48000 frames): the time base refuses before the frame count could agree")
    func ratioEditNeverBridges() async throws {
        // (a) An ordinary ratio edit on a rendered clip.
        let tunedSource = try bridgeSource("ratio-a")
        let engine = try bridgeEngine("ratio")
        let tuned = Clip(name: "t", startBeat: 0, lengthBeats: 2, audioFileURL: tunedSource,
                         pitchEdits: Self.bridgeNote(cents: 100))
        var tunedTrack = try await openLanded(engine, tuned)
        var slowed = tuned
        slowed.stretchRatio = 1.25
        tunedTrack.clips = [slowed]
        engine.tracksDidChange([tunedTrack])
        #expect(engine.graph.clipFileURLForTesting(clipID: slowed.id) == nil,
                "a ratio edit bridged: the previous file plays at the wrong speed")
        #expect(engine.bridgeResolutionCountForTesting == 0)
        try #require(try await waitUntil { committedPlays(engine, slowed) })

        // (b) The length-preserving ratio edit on an untouched clip.
        let plainSource = try makeTempDir("bridge-ratio-b-src").appendingPathComponent("tone.wav")
        try writeSine(to: plainSource, frequency: 440, seconds: 1.0)
        let plain = Clip(name: "p", startBeat: 0, lengthBeats: 2, audioFileURL: plainSource)
        var plainTrack = try await openLanded(engine, plain)
        let memo = try #require(engine.lastPlayedForTesting(clipID: plain.id))
        var nudged = plain
        nudged.stretchRatio = 1.00001
        let nudgedBase = try RenderTimeBase.of(source: plainSource, clip: nudged)
        #expect(memo.frameCount == 48_000)
        #expect(nudgedBase.expectedFrames(sourceFrames: 48_000) == memo.frameCount,
                "premise: the frame count alone cannot tell these apart")
        #expect(nudgedBase != memo.timeBase, "premise: the time base can")
        plainTrack.clips = [nudged]
        engine.tracksDidChange([plainTrack])
        #expect(engine.graph.clipFileURLForTesting(clipID: nudged.id) == nil,
                "a length-preserving ratio edit bridged")
        #expect(engine.bridgeResolutionCountForTesting == 0)
        try #require(try await waitUntil { committedPlays(engine, nudged) })
        #expect(!engine.isRunning)
    }

    @Test("p2-ren Stage A: the render time base is the source's identity, the ratio's bits and (only once the render reads it) the time warp; never pitch, transpose, formant or level")
    func renderTimeBaseIsTimeOnly() throws {
        let dir = try makeTempDir("timebase-src")
        let source = dir.appendingPathComponent("tone.wav")
        try writeSine(to: source, frequency: 440, seconds: 0.25)
        let base = Clip(name: "c", startBeat: 0, lengthBeats: 1, audioFileURL: source,
                        pitchEdits: Self.bridgeNote(cents: 100))
        let timeBase = try RenderTimeBase.of(source: source, clip: base)
        func of(_ change: (inout Clip) -> Void, readsTimeWarp: Bool = StretchCurvePlan.readsTimeWarp)
            throws -> RenderTimeBase {
            var clip = base
            change(&clip)
            return try RenderTimeBase.of(source: source, clip: clip, readsTimeWarp: readsTimeWarp)
        }
        // What a file SOUNDS like never changes its time base.
        #expect(try of { $0.pitchEdits = Self.bridgeNote(cents: 700) } == timeBase)
        #expect(try of { $0.pitchShiftSemitones = 3 } == timeBase)
        #expect(try of { $0.formantPreserve = true } == timeBase)
        #expect(try of { $0.gainDb = -6 } == timeBase)
        #expect(try of { clip in
            var edits = Self.bridgeNote(cents: 100)
            edits.segments[0].amplitudeDb = -6
            edits.segments[0].formantOffsetSemitones = 2
            clip.pitchEdits = edits
        } == timeBase)
        // Which source frame plays when: the ratio, to the last bit…
        #expect(try of { $0.stretchRatio = 1.25 } != timeBase)
        #expect(try of { $0.stretchRatio = (1.0).nextUp } != timeBase)
        // …and the source's identity (a rewrite moves the mtime; a copy moves the path).
        let copy = try makeTempDir("timebase-copy").appendingPathComponent("tone.wav")
        try FileManager.default.copyItem(at: source, to: copy)
        var copied = base
        copied.audioFileURL = copy
        #expect(try RenderTimeBase.of(source: copy, clip: copied) != timeBase)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(9)], ofItemAtPath: source.path)
        #expect(try RenderTimeBase.of(source: source, clip: base) != timeBase)
        // A timing-only edit: invisible while the render ignores W, a different
        // time base the moment it reads it (C2-3's flip, same diff).
        #expect(StretchCurvePlan.readsTimeWarp == false,
                "C2-3 flips readsTimeWarp in the SAME diff that makes the render read W")
        let now = try RenderTimeBase.of(source: source, clip: base)
        #expect(try of { $0.pitchEdits = Self.bridgeNote(cents: 100, timing: 0.05) } == now)
        let warped = try of({ $0.pitchEdits = Self.bridgeNote(cents: 100, timing: 0.05) },
                            readsTimeWarp: true)
        let unwarped = try of({ _ in }, readsTimeWarp: true)
        #expect(warped != unwarped, "once the render reads W a timing edit must not bridge")
        #expect(try of({ $0.pitchEdits = Self.bridgeNote(cents: 500) }, readsTimeWarp: true) == unwarped,
                "a pitch edit keeps its time base when W is read")
        // The length every file of a time base has: OfflineStretcher's contract.
        #expect(timeBase.expectedFrames(sourceFrames: 48_000) == 48_000)
        #expect(try of { $0.stretchRatio = 1.25 }.expectedFrames(sourceFrames: 48_000) == 60_000)
    }

    @Test("p2-ren Stage A: a render that FAILS ends the bridge: the clip goes silent with the failure on record, and the previous version never outlives it; the next edit renders again")
    func failedRenderEndsTheBridge() async throws {
        let source = try bridgeSource("fail")
        let engine = try bridgeEngine("fail")
        let before = Clip(name: "v", startBeat: 0, lengthBeats: 2, audioFileURL: source,
                          pitchEdits: Self.bridgeNote(cents: 100))
        var track = try await openLanded(engine, before)
        var after = before
        after.pitchEdits = Self.bridgeNote(cents: 300)
        track.clips = [after]
        engine.tracksDidChange([track])
        // The render will fail: its folder turns read-only before it writes.
        let cacheDir = engine.stretchCache.directory
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cacheDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheDir.path)
        }
        #expect(engine.graph.isPlayingBridge(clipID: after.id), "premise: the edit bridged")
        let failed = try await waitUntil {
            if case .failed = engine.stretchCache.status(forClip: after.id) { return true }
            return false
        }
        try #require(failed, "the injected render failure never happened")
        let ended = try await waitUntil { !engine.graph.isPlayingBridge(clipID: after.id) }
        try #require(ended, "the render failed and the previous version kept playing")
        #expect(engine.graph.clipFileURLForTesting(clipID: after.id) == nil)
        let heard = try livePlays(engine, after)
        #expect(TestSignals.peak(heard[0], in: 0..<heard[0].count) == 0, "a failed render must play silence")
        // A later pass keeps it silent: the failure is sticky for this key.
        engine.tracksDidChange([track])
        #expect(engine.graph.clipFileURLForTesting(clipID: after.id) == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheDir.path)
        var next = after
        next.pitchEdits = Self.bridgeNote(cents: 500)
        track.clips = [next]
        engine.tracksDidChange([track])
        // Its first resolve still reads the failed job's status (the kick is
        // async), so it errs toward silence rather than bridging.
        #expect(engine.graph.clipFileURLForTesting(clipID: next.id) == nil)
        try #require(try await waitUntil { committedPlays(engine, next) }, "the next edit never rendered")
        #expect(Self.isPitch(Self.notePitch(try livePlays(engine, next)), cents: 500))
        #expect(!engine.isRunning)
    }

    @Test("p2-ren Stage A: a render CANCELLED by a newer edit does not end the bridge: the same player keeps the previous version and the cancellation changes no schedule")
    func cancelledRenderKeepsTheBridge() async throws {
        let source = try bridgeSource("cancel")
        let engine = try bridgeEngine("cancel")
        let before = Clip(name: "v", startBeat: 0, lengthBeats: 2, audioFileURL: source,
                          pitchEdits: Self.bridgeNote(cents: 100))
        var track = try await openLanded(engine, before)
        let previous = try #require(engine.graph.clipFileURLForTesting(clipID: before.id))
        let rendersBefore = engine.stretchCache.renderCount

        var first = before
        first.pitchEdits = Self.bridgeNote(cents: 200)
        track.clips = [first]
        engine.tracksDidChange([track])
        #expect(engine.graph.isPlayingBridge(clipID: first.id))
        try await Task.sleep(for: .milliseconds(60))   // the +200 c job sits in its debounce

        var second = first
        second.pitchEdits = Self.bridgeNote(cents: 300)
        track.clips = [second]
        engine.tracksDidChange([track])
        let bridgePlayer = try #require(engine.graph.clipPlayerForTesting(clipID: second.id))
        #expect(engine.graph.isPlayingBridge(clipID: second.id))
        #expect(engine.graph.clipFileURLForTesting(clipID: second.id)?.standardizedFileURL
                == previous.standardizedFileURL, "the second bridge is not the file the clip played")
        let passes = engine.scheduleChangingPassCountForTesting
        // The +300 c job starts and cancels the +200 c one, still inside its own debounce.
        try await Task.sleep(for: .milliseconds(120))
        #expect(engine.stretchCache.status(forClip: second.id) == .rendering)
        #expect(engine.graph.clipPlayerForTesting(clipID: second.id) === bridgePlayer,
                "the cancellation rebuilt the clip's node")
        #expect(engine.graph.isPlayingBridge(clipID: second.id), "the cancellation ended the bridge")
        #expect(engine.scheduleChangingPassCountForTesting == passes,
                "the cancellation changed the schedule")

        try #require(try await waitUntil { committedPlays(engine, second) }, "the +300 c render never landed")
        #expect(engine.stretchCache.renderCount == rendersBefore + 1,
                "the cancelled job rendered anyway")
        #expect(Self.isPitch(Self.notePitch(try livePlays(engine, second)), cents: 300))
        #expect(!engine.isRunning)
    }

    @Test("p2-ren Stage A: when the file the clip played is gone (a purged cache), an edit cannot bridge on it and is silent until its render lands")
    func deletedPreviousFileCannotBridge() async throws {
        let source = try bridgeSource("deleted")
        let engine = try bridgeEngine("deleted")
        let before = Clip(name: "v", startBeat: 0, lengthBeats: 2, audioFileURL: source,
                          pitchEdits: Self.bridgeNote(cents: 100))
        var track = try await openLanded(engine, before)
        let previous = try #require(engine.graph.clipFileURLForTesting(clipID: before.id))
        try FileManager.default.removeItem(at: previous)
        #expect(engine.lastPlayedForTesting(clipID: before.id)?.fileURL.standardizedFileURL
                == previous.standardizedFileURL, "premise: the memo still names the deleted file")
        var after = before
        after.pitchEdits = Self.bridgeNote(cents: 300)
        track.clips = [after]
        engine.tracksDidChange([track])
        #expect(engine.graph.clipFileURLForTesting(clipID: after.id) == nil)
        #expect(engine.bridgeResolutionCountForTesting == 0)
        try #require(try await waitUntil { committedPlays(engine, after) })
        #expect(Self.isPitch(Self.notePitch(try livePlays(engine, after)), cents: 300))
        #expect(!engine.isRunning)
    }

    @Test("p2-ren Stage A: a previous file whose length is not the new render's never bridges (a damaged render planted at the old key), while a sound one beside it does")
    func wrongLengthPreviousFileCannotBridge() async throws {
        let engine = try bridgeEngine("length")
        let soundSource = try bridgeSource("length-sound")
        let damagedSource = try bridgeSource("length-damaged")
        let sound = Clip(name: "sound", startBeat: 0, lengthBeats: 2, audioFileURL: soundSource,
                         pitchEdits: Self.bridgeNote(cents: 100))
        let damaged = Clip(name: "damaged", startBeat: 0, lengthBeats: 2, audioFileURL: damagedSource,
                           pitchEdits: Self.bridgeNote(cents: 100))
        // The damage: half the frames, committed at the damaged clip's key
        // before the engine ever resolves it.
        let key = try StretchRenderCache.cacheKey(
            source: damagedSource, params: StretchRenderCache.Params(clip: damaged))
        let planted = engine.stretchCache.directory.appendingPathComponent(key + ".caf")
        try writeSine(to: planted, frequency: 440, seconds: 0.5)
        var tracks = [audioTrack(sound), audioTrack(damaged)]
        engine.tracksDidChange(tracks)
        try #require(try await waitUntil { committedPlays(engine, sound) && committedPlays(engine, damaged) })
        #expect(engine.graph.clipFileURLForTesting(clipID: damaged.id)?.standardizedFileURL
                == planted.standardizedFileURL, "premise: the damaged render is what the clip opened")
        #expect(engine.lastPlayedForTesting(clipID: damaged.id)?.frameCount == 24_000)
        #expect(engine.lastPlayedForTesting(clipID: sound.id)?.frameCount == 48_000)

        var soundEdited = sound
        soundEdited.pitchEdits = Self.bridgeNote(cents: 300)
        var damagedEdited = damaged
        damagedEdited.pitchEdits = Self.bridgeNote(cents: 300)
        tracks[0].clips = [soundEdited]
        tracks[1].clips = [damagedEdited]
        engine.tracksDidChange(tracks)
        #expect(engine.graph.isPlayingBridge(clipID: soundEdited.id), "positive control: a sound file bridges")
        #expect(engine.graph.clipFileURLForTesting(clipID: damagedEdited.id) == nil,
                "a file of the wrong length bridged")
        #expect(engine.bridgeResolutionCountForTesting == 1)
        try #require(try await waitUntil { committedPlays(engine, soundEdited) && committedPlays(engine, damagedEdited) })
        #expect(!engine.isRunning)
    }

    @Test("p2-ren Stage A: a bounce taken while a bridge plays WAITS for the render and bounces the final version, byte for byte the bounce taken after it landed, never the previous version")
    func bounceNeverTakesTheBridge() async throws {
        let source = try bridgeSource("bounce")
        let engine = try bridgeEngine("bounce")
        let before = Clip(name: "v", startBeat: 0, lengthBeats: 2, audioFileURL: source,
                          pitchEdits: Self.bridgeNote(cents: 100))
        var track = try await openLanded(engine, before)
        let tempo = TempoMap(constantBPM: 120)
        func bounce(_ clip: Clip) async throws -> [[Float]] {
            try await engine.renderOffline(tracks: [audioTrack(clip)], tempoMap: tempo, masterVolume: 1,
                                           fromBeat: 0, durationSeconds: 1.2,
                                           forcedCompensationTargets: nil).channelData
        }
        let previousVersion = try await bounce(before)

        var after = before
        after.pitchEdits = Self.bridgeNote(cents: 300)
        track.clips = [after]
        engine.tracksDidChange([track])
        try #require(engine.graph.isPlayingBridge(clipID: after.id), "premise: a bridge plays")
        let whilePending = try await bounce(after)
        try #require(try await waitUntil { committedPlays(engine, after) })
        let afterLanding = try await bounce(after)

        let vsFinal = Self.differingSamples(whilePending, afterLanding)
        let vsPrevious = Self.differingSamples(whilePending, previousVersion)
        print("[measured] p2-ren bounce while bridged: \(vsFinal) samples differ from the final version's "
              + "bounce, \(vsPrevious) from the previous version's; note pitch "
              + "\(Self.notePitch(whilePending)) Hz")
        #expect(vsFinal == 0, "the bounce did not wait for the final version")
        #expect(vsPrevious > 10_000, "positive control: the previous version must be tellable from the final")
        #expect(Self.isPitch(Self.notePitch(whilePending), cents: 300))
        #expect(engine.bridgeResolutionCountForTesting == 1, "only the edit's own resolve bridged")
        #expect(!engine.isRunning)
    }

    @Test("p2-ren Stage A G4: an unedited session (open, play, seek, stop, a save that repoints its media) resolves NO bridge; one edit then resolves exactly one")
    func uneditedSessionResolvesNoBridge() async throws {
        let dir = try makeTempDir("g4spy-src")
        let plainSource = dir.appendingPathComponent("plain.wav")
        try writeRampedSine(to: plainSource, frequency: 330, seconds: 2.0)
        let stretchSource = dir.appendingPathComponent("stretch.wav")
        try writeSine(to: stretchSource, frequency: 440, seconds: 1.5)
        let tunedSource = dir.appendingPathComponent("tuned.wav")
        try writeSine(to: tunedSource, frequency: 220, seconds: 2.0)
        var clips = [
            Clip(name: "plain", startBeat: 0, lengthBeats: 3.5, audioFileURL: plainSource,
                 startOffsetSeconds: 0.25, fadeInBeats: 0.5, fadeOutBeats: 0.5),
            Clip(name: "stretched", startBeat: 0, lengthBeats: 4.5, audioFileURL: stretchSource,
                 stretchRatio: 1.5, pitchShiftSemitones: 2),
            Clip(name: "tuned", startBeat: 0, lengthBeats: 4, audioFileURL: tunedSource,
                 pitchEdits: Self.editedEdits(cents: 100)),
        ]
        var tracks = clips.map { audioTrack($0) }
        let engine = try bridgeEngine("g4spy")
        let tempo = TempoMap(constantBPM: 120)
        func allPlay() -> Bool { clips.allSatisfy { committedPlays(engine, $0) } }
        engine.tracksDidChange(tracks)                                   // open
        try #require(try await waitUntil { allPlay() }, "the session's renders never landed")
        engine.graph.stopAllPlayers()
        engine.graph.scheduleAll(fromBeat: 0, tempoMap: tempo)           // play
        engine.graph.stopAllPlayers()
        engine.graph.scheduleAll(fromBeat: 2.5, tempoMap: tempo)         // seek
        engine.graph.stopAllPlayers()                                    // stop
        tracks[0].volume = 0.5
        engine.tracksDidChange(tracks)                                   // a mixer move
        // The first save copies every file into the project and repoints it.
        let media = try makeTempDir("g4spy-media")
        for index in clips.indices {
            let old = try #require(clips[index].audioFileURL)
            let copy = media.appendingPathComponent(old.lastPathComponent)
            try FileManager.default.copyItem(at: old, to: copy)
            clips[index].audioFileURL = copy
            tracks[index].clips = [clips[index]]
        }
        engine.tracksDidChange(tracks)
        try #require(try await waitUntil { allPlay() }, "the repointed session never played again")
        engine.graph.stopAllPlayers()
        engine.graph.scheduleAll(fromBeat: 0, tempoMap: tempo)
        #expect(engine.bridgeResolutionCountForTesting == 0, "an unedited session resolved a bridge")

        // POSITIVE CONTROL: the spy counts a real bridge.
        clips[2].pitchEdits = Self.editedEdits(cents: 300)
        tracks[2].clips = [clips[2]]
        engine.tracksDidChange(tracks)
        #expect(engine.bridgeResolutionCountForTesting == 1)
        #expect(engine.graph.isPlayingBridge(clipID: clips[2].id))
        try #require(try await waitUntil { allPlay() })
        #expect(!engine.isRunning)
    }

    @Test("p2-ren Stage A G6: an edit and its landing are exactly two schedule-changing passes (each would restart a rolling transport) with the bridge on or vetoed; a failure adds the one pass that ends a bridge")
    func bridgeRestartsPerEdit() async throws {
        var counts: [String: [String: Int]] = [:]
        for bridge in [true, false] {
            let mode = bridge ? "bridge" : "vetoed"
            let source = try bridgeSource("g6-\(mode)")
            let engine = try bridgeEngine("g6-\(mode)")
            engine.bridgeEnabled = bridge
            var clip = Clip(name: "v", startBeat: 0, lengthBeats: 2, audioFileURL: source,
                            pitchEdits: Self.bridgeNote(cents: 100))
            var track = try await openLanded(engine, clip)
            var perEdit: [String: Int] = [:]
            func edit(_ change: (inout Clip) -> Void) {
                change(&clip)
                track.clips = [clip]
                engine.tracksDidChange([track])
            }
            func measure(_ label: String, _ body: () async throws -> Void) async throws {
                let base = engine.scheduleChangingPassCountForTesting
                try await body()
                try await Task.sleep(for: .milliseconds(150))   // nothing else trickles in
                perEdit[label] = engine.scheduleChangingPassCountForTesting - base
            }
            try await measure("pitch") {
                edit { $0.pitchEdits = Self.bridgeNote(cents: 200) }
                try #require(try await waitUntil { committedPlays(engine, clip) })
            }
            try await measure("timing-only") {
                edit { $0.pitchEdits = Self.bridgeNote(cents: 200, timing: 0.05) }
                try #require(try await waitUntil { committedPlays(engine, clip) })
            }
            try await measure("ratio") {
                edit { $0.stretchRatio = 1.25 }
                try #require(try await waitUntil { committedPlays(engine, clip) })
            }
            try await measure("two quick edits") {
                edit { $0.pitchEdits = Self.bridgeNote(cents: 300) }
                try await Task.sleep(for: .milliseconds(60))
                edit { $0.pitchEdits = Self.bridgeNote(cents: 400) }
                try #require(try await waitUntil { committedPlays(engine, clip) })
            }
            let cacheDir = engine.stretchCache.directory
            try await measure("failure") {
                edit { $0.pitchEdits = Self.bridgeNote(cents: 500) }
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cacheDir.path)
                defer {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                           ofItemAtPath: cacheDir.path)
                }
                try #require(try await waitUntil {
                    if case .failed = engine.stretchCache.status(forClip: clip.id) { return true }
                    return false
                }, "the injected failure never happened")
                _ = try await waitUntil { !engine.graph.isPlayingBridge(clipID: clip.id) }
                try await Task.sleep(for: .milliseconds(200))
            }
            counts[mode] = perEdit
            #expect(!engine.isRunning)
        }
        print("[measured] p2-ren G6 schedule-changing passes per edit: \(counts)")
        for mode in ["bridge", "vetoed"] {
            #expect(counts[mode]?["pitch"] == 2, "\(mode): \(counts[mode] ?? [:])")
            #expect(counts[mode]?["timing-only"] == 2, "\(mode): \(counts[mode] ?? [:])")
            #expect(counts[mode]?["ratio"] == 2, "\(mode): \(counts[mode] ?? [:])")
            #expect(counts[mode]?["two quick edits"] == 3, "\(mode): \(counts[mode] ?? [:])")
        }
        // Ending a bridge IS a schedule change; with no bridge there is nothing to end.
        #expect(counts["bridge"]?["failure"] == 2)
        #expect(counts["vetoed"]?["failure"] == 1)
    }

    // MARK: - p2-ren Stage A G1: edit → the clip sounding again (env-gated harness)

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    private static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads
    }

    /// A JSON number, or null for nil / NaN / ±inf (JSONSerialization raises
    /// an Objective-C exception on a non-finite Double).
    private static func jsonNumber(_ x: Double?) -> Any {
        if let x, x.isFinite { return x }
        return NSNull()
    }

    /// Nearest-rank percentile.
    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    /// G1 of design §12, ENV-GATED (nothing runs in a normal `./scripts/test.sh`):
    ///
    ///     REN_A_G1_TAKE=<wav> REN_A_G1_OUT=<dir> [REN_A_G1_MANIFEST=<i1lt manifest.json>] \
    ///       [REN_A_G1_EDITS=50] [REN_A_G1_BASELINE=6] [REN_A_G1_LABEL=run] \
    ///       ./scripts/test.sh --filter bridgeLatencyHarness
    ///
    /// The take is read in place, never copied. Its note table is the
    /// manifest's known spans (a synthetic take) or the product's detector (the
    /// user's take). Per edit, a single note gets a new offset through the
    /// STORE, the path I1 timed. Edits come ~1 s apart, so the renders are
    /// always in flight; every tenth waits for its render to land, so later
    /// edits bridge on a render as well as on the source.
    ///
    /// No audio hardware runs here, so "sounding again while rolling" is a
    /// COMPOSITE, each term named in the JSON:
    ///  * `commitMs`: the store edit, whose `tracksDidChange` runs the reconcile
    ///    that resolves the bridge and opens its node (MEASURED);
    ///  * `scheduleMs`: the rolling restart's schedule pass, `stopAllPlayers` +
    ///    `scheduleAll` from near the edited note (MEASURED, headless; the
    ///    restart's `prepareAllPlayers` pre-read is not in it);
    ///  * `leadMs`: `StartAnchorBudget.lead(1)`, the anchor lead the restart
    ///    adds (INFERRED: it is a constant, and no hardware is here to show it).
    /// The vetoed engine (today) is silent from the commit until the render
    /// lands, so its composite adds that wait instead.
    @Test("p2-ren Stage A G1: edit → the clip sounds again while rolling, ≥50 single-note edits ~1 s apart with renders in flight, bridge on, and today's (vetoed) baseline (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["REN_A_G1_OUT"] != nil))
    func bridgeLatencyHarness() async throws {
        let env = ProcessInfo.processInfo.environment
        let take = URL(fileURLWithPath: try #require(env["REN_A_G1_TAKE"]))
        let out = URL(fileURLWithPath: try #require(env["REN_A_G1_OUT"]))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let edits = max(50, Int(env["REN_A_G1_EDITS"] ?? "") ?? 50)
        let baselineEdits = max(3, Int(env["REN_A_G1_BASELINE"] ?? "") ?? 6)
        let label = env["REN_A_G1_LABEL"] ?? "run"

        struct Manifest: Decodable {
            struct Note: Decodable { let start: Double; let end: Double; let hz: Double }
            struct Take: Decodable { let path: String; let notes: [Note] }
            let takes: [Take]
        }
        let table: PitchEditSet
        let tableSource: String
        if let manifestPath = env["REN_A_G1_MANIFEST"] {
            let manifest = try JSONDecoder().decode(
                Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
            let entry = try #require(manifest.takes.first {
                URL(fileURLWithPath: $0.path).standardizedFileURL == take.standardizedFileURL
            }, "the take is not in the manifest")
            table = PitchEditSet(segments: entry.notes.map {
                NoteSegment(startSeconds: $0.start, endSeconds: $0.end, detectedHz: $0.hz,
                            detectedConfidence: 0.95)
            })
            tableSource = "manifest"
        } else {
            table = PitchNoteTable.detected(from: try PitchContourCache.detectWholeFile(take, .product))
            tableSource = "detected (product detector)"
        }
        let file = try AVAudioFile(forReading: take)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let candidates = table.segments.filter { $0.durationSeconds >= 0.30 && $0.detectedHz > 0 }
        try #require(candidates.count >= 5, "only \(candidates.count) notes ≥ 0.30 s")
        print("[measured] p2-ren G1 '\(label)': \(take.lastPathComponent), \(duration) s, "
              + "\(file.processingFormat.channelCount) ch, \(table.segments.count) notes (\(tableSource)), "
              + "\(candidates.count) candidates")

        var report: [String: Any] = [
            "label": label, "take": take.path, "seconds": duration,
            "channels": Int(file.processingFormat.channelCount), "sourceFrames": Int(file.length),
            "notes": table.segments.count, "noteTable": tableSource,
            "leadMs": StartAnchorBudget.lead(forStartablePlayerCount: 1).seconds * 1_000,
            "debounceMs": StretchRenderCache.debounceMilliseconds,
        ]
        for (mode, count) in [("bridge", edits), ("vetoed", baselineEdits)] {
            report[mode] = try await g1Run(bridge: mode == "bridge", edits: count, take: take,
                                           table: table, candidates: candidates, duration: duration,
                                           out: out, label: "\(label)-\(mode)")
        }
        let json = out.appendingPathComponent("g1-\(label).json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: json)
        print("[measured] p2-ren G1 wrote \(json.path)")
    }

    private func g1Run(bridge: Bool, edits: Int, take: URL, table: PitchEditSet,
                       candidates: [NoteSegment], duration: Double, out: URL,
                       label: String) async throws -> [String: Any] {
        let clip = Clip(name: "take", startBeat: 0, lengthBeats: (duration * 2).rounded(.up),
                        audioFileURL: take, pitchEdits: table)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = AudioEngine()
        engine.bridgeEnabled = bridge
        let cacheDir = out.appendingPathComponent("cache-\(label)", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        engine.stretchCache = StretchRenderCache(directory: cacheDir)
        store.engine = engine
        engine.tracksDidChange(store.tracks)
        try #require(committedPlays(engine, clip), "the untouched take does not play its source")
        let tempo = TempoMap(constantBPM: 120)
        let leadMs = StartAnchorBudget.lead(forStartablePlayerCount: 1).seconds * 1_000
        let loadAtStart = Self.loadAverage()
        let started = ContinuousClock.now

        var rows: [[String: Any]] = []
        var fromBefore: [Double] = []
        var fromReturn: [Double] = []
        var bridged = 0
        for index in 0..<edits {
            let note = candidates[(index * 7) % candidates.count]
            let cents = 100 + Double(index)
            let memoKind = engine.lastPlayedForTesting(clipID: clip.id).map {
                $0.fileURL.standardizedFileURL == take.standardizedFileURL ? "source" : "render"
            } ?? "none"
            let inFlight = engine.stretchCache.status(forClip: clip.id) == .rendering
            let load = Self.loadAverage()[0]
            let t0 = ContinuousClock.now
            _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: note.id, offsetCents: cents)
            let t1 = ContinuousClock.now
            let isBridge = engine.graph.isPlayingBridge(clipID: clip.id)
            let hasNode = engine.graph.clipFileURLForTesting(clipID: clip.id) != nil
            if isBridge { bridged += 1 }
            let edited = store.tracks[0].clips[0]
            let waitsForLanding = !bridge || index % 10 == 9
            var landedMs: Double?
            if waitsForLanding {
                let landed = try await waitUntil(240) { committedPlays(engine, edited) }
                landedMs = landed ? Self.ms(ContinuousClock.now - t0) : nil
            }
            // The rolling restart's schedule pass, from 1 s before the note.
            let playheadBeat = max(0, note.startSeconds - 1) * 2
            let r0 = ContinuousClock.now
            engine.graph.stopAllPlayers()
            engine.graph.scheduleAll(fromBeat: playheadBeat, tempoMap: tempo)
            let scheduleMs = Self.ms(ContinuousClock.now - r0)
            let commitMs = Self.ms(t1 - t0)
            // When the clip sounds again: at the commit's own restart with a
            // bridge; at the landing's restart without one.
            let soundsAgainFromBefore: Double?
            let soundsAgainFromReturn: Double?
            if hasNode {
                soundsAgainFromBefore = commitMs + scheduleMs + leadMs
                soundsAgainFromReturn = scheduleMs + leadMs
            } else if let landedMs {
                soundsAgainFromBefore = landedMs + scheduleMs + leadMs
                soundsAgainFromReturn = landedMs - commitMs + scheduleMs + leadMs
            } else {
                soundsAgainFromBefore = nil
                soundsAgainFromReturn = nil
            }
            if let soundsAgainFromBefore, let soundsAgainFromReturn {
                fromBefore.append(soundsAgainFromBefore)
                fromReturn.append(soundsAgainFromReturn)
            }
            rows.append([
                "edit": index, "noteStart": note.startSeconds, "noteEnd": note.endSeconds,
                "cents": cents, "memo": memoKind, "renderInFlightAtCommit": inFlight,
                "bridged": isBridge, "nodeAfterCommit": hasNode, "commitMs": commitMs,
                "scheduleMs": scheduleMs, "landedMs": Self.jsonNumber(landedMs),
                "soundsAgainFromBeforeMs": Self.jsonNumber(soundsAgainFromBefore),
                "soundsAgainFromReturnMs": Self.jsonNumber(soundsAgainFromReturn),
                "loadAtCommit": load,
            ])
            if !waitsForLanding {
                try await Task.sleep(for: .seconds(1))
            }
        }
        let loadAtEnd = Self.loadAverage()
        // Let the last job settle before the cache folder goes.
        _ = try await waitUntil(240) { engine.stretchCache.status(forClip: clip.id) != .rendering }
        try? FileManager.default.removeItem(at: cacheDir)
        #expect(!engine.isRunning, "the G1 harness started the audio hardware")
        let summary: [String: Any] = [
            "edits": edits, "bridged": bridged, "soundedCount": fromBefore.count,
            "p50FromBeforeMs": Self.jsonNumber(Self.percentile(fromBefore, 50)),
            "p95FromBeforeMs": Self.jsonNumber(Self.percentile(fromBefore, 95)),
            "maxFromBeforeMs": Self.jsonNumber(fromBefore.max()),
            "p50FromReturnMs": Self.jsonNumber(Self.percentile(fromReturn, 50)),
            "p95FromReturnMs": Self.jsonNumber(Self.percentile(fromReturn, 95)),
            "maxFromReturnMs": Self.jsonNumber(fromReturn.max()),
        ]
        print("[measured] p2-ren G1 \(label): \(summary); load start \(loadAtStart) end \(loadAtEnd)")
        return [
            "bridgeEnabled": bridge, "loadAverageAtStart": loadAtStart, "loadAverageAtEnd": loadAtEnd,
            "elapsedMs": Self.ms(ContinuousClock.now - started), "summary": summary, "rows": rows,
        ]
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

    // MARK: - C2-0 (F13) physics: A SPLIT MUST NOT CHANGE THE SOUND
    //
    // `ProjectStoreClipStretchTests` (DAWCoreTests) pins the split/trim offsets
    // against an oracle written in the same terms as the source, so on its own
    // it could restate a wrong assumption. This test asks the question in a
    // different form: it renders a stretched clip WHOLE through the real engine,
    // splits it through the real store, renders again, and compares the audio.
    //  - BEFORE the split point the renders must be identical: the left half is
    //    untouched. That is the invariance control.
    //  - AFTER it they must match too. Both halves read the SAME stretched
    //    render (`StretchRenderCache`'s key has no clip id), so a correct split
    //    is sample-exact by construction.
    //
    // It MEASURES any displacement rather than assuming one: a bounded search
    // finds the lag at which the split render's first post-split 100 ms appear
    // in the whole render. The undivided offset math predicts
    // `splitSeconds × (ratio − 1)`: +1 s at ratio 2 (stretched audio SKIPPED),
    // −0.25 s at ratio 0.5 (REPEATED).
    //
    // The source is a linear CHIRP, not a sine. A periodic tone matches itself
    // at every multiple of its period, so a displaced read could pass a sample
    // diff by coincidence. A chirp's content is different at every position.
    //
    // It lives in THIS suite (beside `startOffsetMapsThroughRatio`, the read
    // side of the same offset) rather than a new one, which keeps the
    // `@MainActor` suite count (`MainActorOccupancySiteTests` Leg C) unmoved.

    struct SplitCase: Sendable, CustomTestStringConvertible {
        let ratio: Double
        /// SOURCE seconds.
        let startOffsetSeconds: Double
        /// Sized so the clip plays exactly to the end of the stretched render.
        let lengthBeats: Double
        let splitBeat: Double
        var testDescription: String { "ratio \(ratio)" }
    }

    static let splitSampleRate = 48_000.0
    static let splitSourceSeconds = 3.0
    static let splitBPM = 120.0  // 1 beat = 0.5 s

    /// `nonisolated`: the `@Test(arguments:)` macro reads it off the main actor.
    nonisolated static let splitCases: [SplitCase] = [
        // 3 s × 2 = a 6 s render. Offset 0.25 s of source = render 0.5 s, so the
        // clip plays render [0.5, 6.0) = 5.5 s = 11 beats. Split 1 s in: the
        // right half must read render 1.5 s; the undivided math reads 2.5 s, which
        // also stays inside the file, so the error is a displacement, not silence.
        SplitCase(ratio: 2, startOffsetSeconds: 0.25, lengthBeats: 11, splitBeat: 2),
        // 3 s × 0.5 = a 1.5 s render. Offset 0.25 s of source = render 0.125 s,
        // so the clip plays render [0.125, 1.5) = 1.375 s = 2.75 beats. Split
        // 0.5 s in: the right half must read render 0.625 s; the undivided math
        // reads 0.375 s.
        SplitCase(ratio: 0.5, startOffsetSeconds: 0.25, lengthBeats: 2.75, splitBeat: 1),
    ]

    @Test("splitting a stretched clip renders identically to the unsplit clip",
          arguments: splitCases)
    func splitIsInaudible(_ c: SplitCase) async throws {
        let dir = try makeTempDir("c2-0-split")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("chirp.wav")
        try Self.writeChirp(to: source)

        // A private cache directory: never the user's real stretch cache.
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: dir.appendingPathComponent("cache"))

        let store = ProjectStore()
        try store.setTempo(Self.splitBPM)
        let clip = Clip(name: "Chirp", startBeat: 0, lengthBeats: c.lengthBeats,
                        audioFileURL: source, startOffsetSeconds: c.startOffsetSeconds,
                        stretchRatio: c.ratio)
        // Built directly (`tracks` is internal(set), hence `@testable import
        // DAWCore`): an offset set through the store would need a trim, which
        // is another C2-0 site, and this test must exercise the split ALONE.
        store.tracks.append(Track(name: "Vox", kind: .audio, clips: [clip]))
        let map = store.transport.tempoMap
        let clipSeconds = map.seconds(from: 0, to: c.lengthBeats)
        let duration = clipSeconds + 0.25

        let whole = try await engine.renderOffline(
            tracks: store.tracks, tempoMap: map, masterVolume: 1,
            fromBeat: 0, durationSeconds: duration, forcedCompensationTargets: nil)
        let (_, right) = try store.splitClip(trackId: store.tracks[0].id, clipId: clip.id,
                                             atBeat: c.splitBeat)
        #expect(store.tracks[0].clips.count == 2)
        let split = try await engine.renderOffline(
            tracks: store.tracks, tempoMap: map, masterVolume: 1,
            fromBeat: 0, durationSeconds: duration, forcedCompensationTargets: nil)

        let w = whole.channelData[0]
        let s = split.channelData[0]
        let splitSeconds = map.seconds(from: 0, to: c.splitBeat)
        let splitFrame = Int((splitSeconds * Self.splitSampleRate).rounded())
        let endFrame = Int((clipSeconds * Self.splitSampleRate).rounded())
        try #require(w.count >= endFrame && s.count >= endFrame)

        // Audibility control: a diff over silence proves nothing.
        let postRMS = TestSignals.rms(w, in: splitFrame..<endFrame)
        #expect(postRMS > 0.1, "the whole render must be audible after the split: RMS \(postRMS)")

        let preDiff = Self.maxAbsDiff(s, w, in: 0..<splitFrame)
        let postDiff = Self.maxAbsDiff(s, w, in: splitFrame..<endFrame)
        let (lag, residual) = Self.bestLag(of: s, in: w, probeStart: splitFrame,
                                           probeLength: 4_800, validEnd: endFrame)
        let predictedUndividedLag = Int((splitSeconds * (c.ratio - 1) * Self.splitSampleRate).rounded())
        let lastHalfSecond = max(splitFrame, endFrame - 24_000)..<endFrame
        let splitTailRMS = TestSignals.rms(s, in: lastHalfSecond)
        let wholeTailRMS = TestSignals.rms(w, in: lastHalfSecond)
        print("[measured] C2-0 physics ratio \(c.ratio): right-half offset \(right.startOffsetSeconds) s; "
              + "max|split − whole| before the split \(preDiff), after it \(postDiff); "
              + "measured lag \(lag) frames = \(Double(lag) / Self.splitSampleRate) s "
              + "(probe residual \(residual)); undivided-math prediction \(predictedUndividedLag) frames; "
              + "last-0.5 s RMS split \(splitTailRMS) vs whole \(wholeTailRMS)")

        #expect(preDiff == 0, "the left half must render bit-identically: max diff \(preDiff)")
        #expect(postDiff <= 1e-6,
                "after the split point the audio must not change: max diff \(postDiff)")
        #expect(lag == 0,
                "the right half is displaced by \(lag) frames (\(Double(lag) / Self.splitSampleRate) s)")
        #expect(residual <= 1e-6, "the post-split probe must match the whole render exactly somewhere")
    }

    /// Stereo Float32 WAV at 48 kHz, identical channels: a linear chirp
    /// 200 → 2 000 Hz at amplitude 0.5 across `splitSourceSeconds`.
    private static func writeChirp(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: splitSampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(splitSourceSeconds * splitSampleRate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: splitSampleRate, channels: 2,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        let f0 = 200.0
        let f1 = 2_000.0
        for frame in 0..<frames {
            let t = Double(frame) / splitSampleRate
            let phase = 2 * Double.pi * (f0 * t + (f1 - f0) * t * t / (2 * splitSourceSeconds))
            let value = Float(0.5 * sin(phase))
            channels[0][frame] = value
            channels[1][frame] = value
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    private static func maxAbsDiff(_ a: [Float], _ b: [Float], in range: Range<Int>) -> Float {
        var worst: Float = 0
        for frame in range {
            worst = max(worst, abs(a[frame] - b[frame]))
        }
        return worst
    }

    /// The lag `k` minimising `max |a[p + i] − b[p + i + k]|` over the probe
    /// `i ∈ [0, probeLength)`, searched over EVERY `k` that keeps `b`'s index
    /// inside `[0, validEnd)`. Nothing about the expected answer is assumed.
    /// Early exit keeps it cheap: a candidate stops as soon as its running max
    /// exceeds the best so far.
    private static func bestLag(of a: [Float], in b: [Float], probeStart p: Int,
                                probeLength n: Int, validEnd: Int) -> (lag: Int, residual: Float) {
        var bestLag = 0
        var best = Float.infinity
        for k in (-p)...(validEnd - n - p) {
            var worst: Float = 0
            var i = 0
            while i < n {
                worst = max(worst, abs(a[p + i] - b[p + i + k]))
                if worst >= best { break }
                i += 1
            }
            if worst < best {
                best = worst
                bestLag = k
            }
        }
        return (bestLag, best)
    }
}
