import AVFAudio
@testable import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// Per-clip voice conversion through the REAL store and the REAL engine
/// (m24-m leg A / m24-o).
///
/// ⭐ **Why this suite exists separately from `DAWCoreTests`.** That suite
/// spies on the render REQUEST — which window, which clip geometry — and a
/// spy gate is the right instrument for plumbing. But the m24-o defect was
/// *wrong audio*: the converter was handed a clip's FULL BACKING RECORDING
/// instead of the region the clip presents. Only a real render can show that
/// the bytes now on disk are the right bytes, so that is what this asserts,
/// sample-exact, against the source file — plus a NEGATIVE control that the
/// extraction is NOT the head of the recording, which is exactly what the
/// defect produced.
///
/// No sidecar, no voice model, no network: the converter is an injected
/// closure and this one is the identity (it hands the extraction straight
/// back), so what lands on the timeline is provably the audio that was
/// extracted.
@MainActor
@Suite("Per-clip voice conversion — real render (m24-m leg A / m24-o)", .serialized)
struct ClipVoiceConversionRenderTests {

    // MARK: - Fixtures

    private func fixtureDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-vc-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 2 s ramp, 48 kHz stereo: sample i = Float(i) * 1e-4. Bit-exact content
    /// addressing — the same fixture shape `ClipEnvelopeRenderTests` uses for
    /// its own `startOffsetSeconds` proof, so a frame index IS an assertion.
    private func rampFixture() throws -> URL {
        let url = try fixtureDir().appendingPathComponent("ramp.wav")
        let samples = (0..<96_000).map { Float($0) * 1e-4 }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48_000, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for (index, value) in samples.enumerated() {
            channels[0][index] = value
            channels[1][index] = value
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
        return url
    }

    /// ⚠️ The engine is RETURNED and must be held: `ProjectStore.engine` is
    /// `weak`, so a temporary `AudioEngine()` deallocates before the render
    /// and every call throws `engineUnavailable`.
    private func makeSession() throws -> (ProjectStore, AudioEngine, URL) {
        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        store.media = AudioFileImporter()            // the REAL durations
        store.generationImportsDirectory = try fixtureDir()
        try store.setTempo(120)                      // 1 beat = 0.5 s
        return (store, engine, try rampFixture())
    }

    // MARK: - The defect gate, on real samples

    @Test("extraction is bit-exact the region the clip presents, and NOT the head of the file")
    func extractionIsTheClipsOwnRegion() async throws {
        let (store, engine, ramp) = try makeSession()
        // A trimmed clip: 2 beats (1.0 s) of material starting 0.5 s
        // (24_000 frames) into the 2 s recording, parked at beat 4.
        let clip = Clip(name: "verse", startBeat: 4, lengthBeats: 2,
                        audioFileURL: ramp, startOffsetSeconds: 0.5)
        store.tracks.append(Track(name: "Lead Vox", kind: .audio, clips: [clip]))

        let source = try await store.extractClipAudioForConversion(clipId: clip.id)
        let extracted = try TestSignals.readFile(source.url)[0]
        let original = try TestSignals.readFile(ramp)[0]

        #expect(extracted.count == 48_000,
                "1.0 s at 48 kHz — the clip's own window, with no tail: \(extracted.count)")

        var diffs = 0
        for frame in 0..<48_000 where extracted[frame] != original[24_000 + frame] {
            diffs += 1
        }
        print("[measured] extraction differing frames: \(diffs) of 48_000 "
              + "(first extracted = \(extracted[0]), expected \(original[24_000]))")
        #expect(diffs == 0, "the extraction must be the clip's own 0.5–1.5 s region, bit-exact")

        // ⭐ NEGATIVE CONTROL — this is the defect's signature. Before m24-o
        // the converter got the recording from frame 0. If that ever returns,
        // the positive assertion above and this one flip together.
        var headDiffs = 0
        for frame in 0..<48_000 where extracted[frame] != original[frame] {
            headDiffs += 1
        }
        #expect(headDiffs > 0,
                "the extraction must NOT be the head of the backing recording")
        _ = engine
    }

    @Test("a stretched clip extracts its TIMELINE window, and the material really is stretched")
    func stretchedClipExtractsTimelineWindow() async throws {
        let (store, engine, ramp) = try makeSession()
        // stretchRatio 2 = twice as long: 2 timeline beats (1.0 s) consume
        // 0.5 s of source. The extraction is 1.0 s long — the timeline window
        // — and its content is the source SLOWED, not a 1.0 s straight copy.
        let clip = Clip(name: "slow", startBeat: 0, lengthBeats: 2,
                        audioFileURL: ramp, startOffsetSeconds: 0.5, stretchRatio: 2)
        store.tracks.append(Track(name: "Lead Vox", kind: .audio, clips: [clip]))

        let source = try await store.extractClipAudioForConversion(clipId: clip.id)
        let extracted = try TestSignals.readFile(source.url)[0]
        #expect(extracted.count == 48_000, "the TIMELINE window, 1.0 s: \(extracted.count)")

        // A ramp stretched 2x still rises monotonically but at HALF the slope,
        // so it must not match the unstretched region frame for frame.
        let original = try TestSignals.readFile(ramp)[0]
        var straightCopyDiffs = 0
        for frame in 0..<48_000 where extracted[frame] != original[24_000 + frame] {
            straightCopyDiffs += 1
        }
        #expect(straightCopyDiffs > 0,
                "a 2x stretch must not extract as an unstretched copy of the same window")
        _ = engine
    }

    // MARK: - End to end: what lands on the timeline is what was extracted

    @Test("the landed clip's audio IS the converted extraction, at the source's own beats")
    func landedAudioIsTheExtraction() async throws {
        let (store, engine, ramp) = try makeSession()
        let a = Clip(name: "verse", startBeat: 4, lengthBeats: 2,
                     audioFileURL: ramp, startOffsetSeconds: 0.5)
        let b = Clip(name: "chorus", startBeat: 8, lengthBeats: 2,
                     audioFileURL: ramp, startOffsetSeconds: 1.0)
        store.tracks.append(Track(name: "Lead Vox", kind: .audio, clips: [a, b]))
        let tracksBefore = store.tracks.count

        // The IDENTITY converter: hands the extraction straight back, so
        // whatever lands is provably the audio that was extracted. A real RVC
        // call is a black box; this one is not, which is the point.
        let result = try await store.convertClipsToVoice(
            clipIds: [b.id, a.id], trackName: "Voice: ada"
        ) { _, source in source.url }

        #expect(store.tracks.count == tracksBefore + 1)
        let landed = try #require(store.tracks.last)
        #expect(landed.clips.map(\.startBeat) == [4, 8], "the arrangement is preserved")
        #expect(landed.clips.map(\.lengthBeats) == [2, 2])
        #expect(result.warnings.isEmpty,
                "an identity conversion changes no length: \(result.warnings)")

        let original = try TestSignals.readFile(ramp)[0]
        for (index, offsetFrames) in [24_000, 48_000].enumerated() {
            let url = try #require(landed.clips[index].audioFileURL)
            let bytes = try TestSignals.readFile(url)[0]
            #expect(bytes.count == 48_000)
            var diffs = 0
            for frame in 0..<48_000 where bytes[frame] != original[offsetFrames + frame] {
                diffs += 1
            }
            print("[measured] landed clip \(index) differing frames: \(diffs) of 48_000")
            #expect(diffs == 0,
                    "converted clip \(index) must carry its own source region, bit-exact")
        }
        _ = engine
    }

    @Test("level shaping is NOT baked into what the converter hears — it rides the landed clip")
    func levelShapingIsNotBaked() async throws {
        let (store, engine, ramp) = try makeSession()
        // A fade-in over the whole clip plus −12 dB: if either were baked, the
        // extraction's first frames would be near silence and every frame
        // would be attenuated. The converter's pitch estimator gets neither.
        let clip = Clip(name: "faded", startBeat: 0, lengthBeats: 2,
                        audioFileURL: ramp, startOffsetSeconds: 0.5,
                        gainDb: -12, fadeInBeats: 2,
                        fadeInCurve: .equalPower)
        store.tracks.append(Track(name: "Lead Vox", kind: .audio, clips: [clip]))

        let source = try await store.extractClipAudioForConversion(clipId: clip.id)
        let extracted = try TestSignals.readFile(source.url)[0]
        let original = try TestSignals.readFile(ramp)[0]
        var diffs = 0
        for frame in 0..<48_000 where extracted[frame] != original[24_000 + frame] {
            diffs += 1
        }
        print("[measured] level-shaping differing frames: \(diffs) of 48_000 "
              + "(first extracted = \(extracted[0]), unfaded source = \(original[24_000]))")
        #expect(diffs == 0, "neither the fade nor the clip gain may reach the converter")

        // ...and it is carried, not discarded: the landed clip wears it.
        let result = try await store.convertClipsToVoice(
            clipIds: [clip.id], trackName: "Voice: ada"
        ) { _, extraction in extraction.url }
        let landedClip = try #require(store.tracks.last?.clips.first)
        #expect(landedClip.gainDb == -12)
        #expect(landedClip.fadeInBeats == 2)
        #expect(landedClip.fadeInCurve == .equalPower)
        #expect(result.clips.count == 1)
        _ = engine
    }
}
