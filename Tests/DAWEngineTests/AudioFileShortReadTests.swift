import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m32-h — SILENT DATA LOSS: a single `AVAudioFile.read(into:)` short-reads
// every MONO file whose frame count is not a multiple of 1024.
//
// ⭐⭐ THE POSITIVE CONTROL IS STRUCTURAL, NOT OPTIONAL. Every gate here runs
// the SAME assertion against a STEREO file of the SAME length. Stereo reads
// fully at all of these lengths, so a green stereo leg beside a red mono leg
// localises the fault to the READER. Without it, a harness that read nothing
// at all — or a fixture writer that silently wrote short — would pass a
// mono-only test by producing the "expected" small number.
//
// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor` — for the reason
// MEASURED under m32-d (see the header of `SamplerReverseZoneTests.swift`):
// the main actor is ONE serialization point for the whole test process, and
// hosting offline renders inside a `@MainActor` suite pushed an unrelated AU
// stress test from 0.0438 s to 3.2067 s and reddened it. Nothing here needs
// the main actor. ⛔ Do not add `@MainActor`, and do not fold this into an
// existing `@MainActor` suite.
//
// ⚠️ Fixture caches are global `let`s (initialised under `swift_once`), NOT
// `nonisolated(unsafe) var` check-then-fill. The latter is thread-safe only
// under main-actor serialization, which this suite deliberately gives up.

// MARK: - File-local fixtures

/// The six lengths from the m32-h probe table. 22 528 = 22 × 1024 is the
/// aligned control: it read fully even before the fix, so it is the one length
/// that must NOT change behaviour.
private let probeLengths = [22_050, 22_016, 44_100, 66_150, 88_200, 22_528]

/// Ramp fixture where **a frame's VALUE IS ITS FRAME INDEX** (channel 0) and
/// its negation (channel 1). That makes a length check into a placement check
/// for free: a buffer that is the right LENGTH but zero-filled, or assembled
/// out of order, or with a channel swapped, fails on content. Float32 holds
/// integers exactly to 2^24, far above these lengths.
private func writeRampWAV(frames: Int, channels: AVAudioChannelCount,
                          rate: Double = 44_100, to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: Int(channels),
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                     channels: channels, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(frames)),
          let data = buffer.floatChannelData else {
        throw SamplerM32FixtureError.bufferAllocationFailed
    }
    for frame in 0..<frames {
        data[0][frame] = Float(frame)
        if channels >= 2 { data[1][frame] = -Float(frame) }
    }
    buffer.frameLength = AVAudioFrameCount(frames)
    try file.write(from: buffer)
}

/// Marker fixture for the SAMPLER gate: 66 150 frames at the graph rate, whose
/// last 614 frames — exactly the span a single read drops (65 536 = 64 × 1024)
/// — carry a LOUD marker over a quiet body. The pre-fix loader stops at 65 536
/// and the voice frees there, so that window renders SILENT; post-fix the
/// marker sounds. The gate is on RENDERED AUDIO, not on a frame count read
/// back out of the loader.
private let markerFrames = 66_150
private let markerTailStart = 65_536
private let markerBodyLevel: Float = 0.20
private let markerTailLevel: Float = 0.90

private func writeMarkerWAV(channels: AVAudioChannelCount, to url: URL) throws {
    let rate = SamplerM32Identity.graphRate
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: Int(channels),
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                     channels: channels, interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                        frameCapacity: AVAudioFrameCount(markerFrames)),
          let data = buffer.floatChannelData else {
        throw SamplerM32FixtureError.bufferAllocationFailed
    }
    for frame in 0..<markerFrames {
        // DC-free 4 kHz square-ish alternation, so "is there signal here?" is a
        // peak question with no zero-crossing luck involved.
        let level = frame >= markerTailStart ? markerTailLevel : markerBodyLevel
        let value = frame.isMultiple(of: 2) ? level : -level
        for channel in 0..<Int(channels) { data[channel][frame] = value }
    }
    buffer.frameLength = AVAudioFrameCount(markerFrames)
    try file.write(from: buffer)
}

private struct ShortReadFixtures {
    let dir: URL
    /// Probe-table files, keyed `"<frames>-<channels>"`.
    let ramps: [String: URL]
    let markerMono: URL
    let markerStereo: URL
    /// 44 100 frames mono at 48 kHz — the fade-bake source (43 × 1024 = 44 032,
    /// so a whole-file single read loses 68 frames off the end).
    let fadeMono: URL
    let fadeStereo: URL

    func ramp(frames: Int, channels: Int) throws -> URL {
        guard let url = ramps["\(frames)-\(channels)"] else {
            throw SamplerM32FixtureError.bufferAllocationFailed
        }
        return url
    }
}

private let cachedFixtures: Result<ShortReadFixtures, any Error> = {
    do {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32h-shortread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var ramps: [String: URL] = [:]
        for frames in probeLengths {
            for channels in [1, 2] {
                let url = dir.appendingPathComponent("ramp_\(frames)_\(channels)ch.wav")
                try writeRampWAV(frames: frames,
                                 channels: AVAudioChannelCount(channels), to: url)
                ramps["\(frames)-\(channels)"] = url
            }
        }
        let markerMono = dir.appendingPathComponent("marker_mono_66150.wav")
        let markerStereo = dir.appendingPathComponent("marker_stereo_66150.wav")
        try writeMarkerWAV(channels: 1, to: markerMono)
        try writeMarkerWAV(channels: 2, to: markerStereo)
        let fadeMono = dir.appendingPathComponent("fade_mono_44100.wav")
        let fadeStereo = dir.appendingPathComponent("fade_stereo_44100.wav")
        try writeRampWAV(frames: 44_100, channels: 1, rate: 48_000, to: fadeMono)
        try writeRampWAV(frames: 44_100, channels: 2, rate: 48_000, to: fadeStereo)
        return .success(ShortReadFixtures(dir: dir, ramps: ramps,
                                          markerMono: markerMono, markerStereo: markerStereo,
                                          fadeMono: fadeMono, fadeStereo: fadeStereo))
    } catch {
        return .failure(error)
    }
}()

private func fixtures() throws -> ShortReadFixtures { try cachedFixtures.get() }

/// Peak magnitude over a half-open frame range, clamped to the array.
private func peak(_ samples: [Float], in range: Range<Int>) -> Float {
    let lo = max(0, range.lowerBound)
    let hi = min(samples.count, range.upperBound)
    guard lo < hi else { return 0 }
    var best: Float = 0
    for frame in lo..<hi { best = max(best, abs(samples[frame])) }
    return best
}

// MARK: - The suite

@Suite("AVAudioFile mono short read (m32-h)", .serialized)
struct AudioFileShortReadTests {

    // MARK: - Gate (a): the probe table itself

    /// ⭐⭐ THE GATE m32-h EXISTS FOR — the reproduction table, asserted.
    ///
    /// For each of the six measured lengths, the reader must deliver EXACTLY
    /// the file's frame count, for mono AND for stereo, with every frame in
    /// its right place. Pre-fix the mono legs return 21 504 / 21 504 / 44 032 /
    /// 65 536 / 88 064 / 22 528; the stereo legs were already exact, which is
    /// what makes them a control rather than a duplicate.
    @Test("m32-h GATE: every probe-table length reads FULLY — mono, with stereo as the control")
    func probeTableReadsFully() throws {
        let fixtures = try fixtures()
        var report: [String] = []
        for frames in probeLengths {
            for channels in [1, 2] {
                let url = try fixtures.ramp(frames: frames, channels: channels)
                let file = try AVAudioFile(forReading: url)
                #expect(Int(file.length) == frames,
                        "fixture writer is at fault, not the reader: \(url.lastPathComponent)")
                let wholeFile = try AudioFileFullRead.readWholeFile(file)
                let buffer = try #require(wholeFile)
                let got = Int(buffer.frameLength)
                let label = channels == 1 ? "mono" : "stereo"
                report.append("\(frames) \(label): \(got)")
                #expect(got == frames,
                        "\(label) \(frames) frames read as \(got) — lost \(frames - got)")

                // Content, not just length: value == frame index on ch0 and its
                // negation on ch1. Catches a right-sized buffer that is
                // zero-filled, mis-ordered, or channel-swapped.
                let data = try #require(buffer.floatChannelData)
                var firstWrong = -1
                for frame in 0..<got where data[0][frame] != Float(frame) {
                    firstWrong = frame
                    break
                }
                let held = firstWrong >= 0 ? data[0][firstWrong] : 0
                #expect(firstWrong == -1,
                        "\(label) \(frames): frame \(firstWrong) holds \(held), not its own index")
                if channels == 2 {
                    var firstWrongRight = -1
                    for frame in 0..<got where data[1][frame] != -Float(frame) {
                        firstWrongRight = frame
                        break
                    }
                    #expect(firstWrongRight == -1,
                            "stereo \(frames): right channel wrong at \(firstWrongRight)")
                }
            }
        }
        print("[measured] m32-h probe table (asked == got everywhere): "
              + report.joined(separator: ", "))
    }

    /// The defect itself, pinned as a NEGATIVE control so the gate above cannot
    /// go vacuous. If Apple ever fixes the short read, this reddens and the
    /// whole item can be revisited — it does not silently become untested.
    ///
    /// It also documents the second, nastier half of the measurement: a second
    /// `read(into:)` does NOT append. It rewrites the buffer from frame 0 and
    /// resets `frameLength` to that call's count, which is why looping on
    /// `frameLength` (the intuitive fix) would leave 0 frames.
    @Test("m32-h mechanism: one bare read() still truncates mono, and a second read does NOT append")
    func bareSingleReadStillTruncatesMono() throws {
        let fixtures = try fixtures()
        let file = try AVAudioFile(forReading: try fixtures.ramp(frames: 22_050, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: 22_050))
        try file.read(into: buffer)
        let firstRead = Int(buffer.frameLength)
        #expect(firstRead < 22_050,
                "the short read is GONE — m32-h's workaround may no longer be needed")
        #expect(firstRead.isMultiple(of: 1_024), "truncation is to a 1024-frame boundary")

        try file.read(into: buffer)
        let secondRead = Int(buffer.frameLength)
        let data = try #require(buffer.floatChannelData)
        // NOT cumulative: the count is this call's alone, and frame 0 now holds
        // the file frame the FIRST read stopped at.
        #expect(secondRead == 22_050 - firstRead)
        #expect(data[0][0] == Float(firstRead),
                "a second read appends — if this ever becomes true the helper can be simplified")
        print("[measured] bare read #1 got \(firstRead) of 22050; read #2 got \(secondRead) "
              + "and rewrote frame 0 with file frame \(data[0][0])")
    }

    // MARK: - Gate (b): the sampler, on RENDERED AUDIO

    /// ⭐⭐ THE GATE THAT MATTERS TO A USER. A mono one-shot's last 614 frames
    /// carry a loud marker. `SamplerInstrument` loads the file, a held note
    /// plays it at `rootPitch` (fixture rate == graph rate, so the increment is
    /// exactly 1.0 and output frame N is source frame N), and the marker must
    /// SOUND.
    ///
    /// Pre-fix the loader stops at 65 536 and the voice frees at `idx >=
    /// frameCount`, so [65 536, 66 150) renders SILENT — a decay that stops
    /// early, which is exactly the reported symptom. The stereo twin renders
    /// the marker either way and is the control.
    ///
    /// The third window is the point of the whole thing: past the file's true
    /// end the voice must be gone. A fix that over-read would show signal
    /// there, so this cannot be passed by simply reading "more".
    @Test("m32-h GATE: a mono sample's last 614 frames REACH THE RENDER — stereo twin as control")
    func samplerRendersTheWholeMonoTail() throws {
        let fixtures = try fixtures()
        var measured: [String] = []
        for (label, url) in [("mono", fixtures.markerMono), ("stereo", fixtures.markerStereo)] {
            let zone = SamplerZone(audioFileURL: url, rootPitch: 60,
                                   minPitch: 60, maxPitch: 60, gain: 1.0)
            let params = SamplerParams(zones: [zone], oneShot: true,
                                       attack: 0.001, release: 0.05, gain: 1.0)
            let instrument = SamplerInstrument(params: params,
                                               sampleRate: SamplerM32Identity.graphRate,
                                               randomSeed: 0x4D33_3268)
            instrument.prepare(sampleRate: SamplerM32Identity.graphRate,
                               maxFramesPerQuantum: 512, channelCount: 2)
            let events = SamplerM32Identity.note(on: 0, off: 500_000, pitch: 60, id: 1)
            let out = try SamplerM32Identity.renderQuanta(
                instrument, events: events, frames: 67_584).left

            let body = peak(out, in: 40_000..<(markerTailStart - 1_024))
            let tail = peak(out, in: markerTailStart..<markerFrames)
            let past = peak(out, in: (markerFrames + 64)..<67_584)
            measured.append("\(label) body \(body) tail \(tail) past-end \(past)")

            #expect(body > 0.15, "\(label): the body is missing — the render is vacuous")
            #expect(tail > 0.5,
                    "\(label): frames \(markerTailStart)..<\(markerFrames) are SILENT (peak \(tail)) — the loader truncated the file's tail")
            #expect(past < 1e-4,
                    "\(label): signal PAST the file's true end (peak \(past)) — over-read")
            #expect(!instrument.zoneLoadNotes.contains { $0.contains("loaded short") },
                    "\(label): loader reported a short load: \(instrument.zoneLoadNotes)")
        }
        print("[measured] m32-h sampler tail gate — " + measured.joined(separator: " | "))
    }

    // MARK: - Gate (c): the fade bake

    /// The SECOND production site the audit found. `ClipFadeBake.bakePiece`
    /// used a bare `read(into:frameCount:)`, which short-reads mono as well —
    /// and from a NON-ZERO `framePosition` too, because the truncation is to a
    /// 1024-aligned absolute FILE POSITION, not to an aligned count (measured:
    /// start 1000 + 21 528 frames = 22 528). A short fade piece is a fade whose
    /// tail is simply missing.
    ///
    /// The clip carries no fades and no gain envelope, so `envelopeGain` is
    /// exactly 1 and the baked content must equal the source ramp frame for
    /// frame — which pins placement, not just length.
    @Test("m32-h: bakePiece fills a MONO fade piece completely, from a non-zero start")
    func bakePieceFillsMonoCompletely() throws {
        let fixtures = try fixtures()
        let clip = Clip(name: "m32h", startBeat: 0, lengthBeats: 16,
                        audioFileURL: fixtures.fadeMono)
        var measured: [String] = []
        for (label, url) in [("mono", fixtures.fadeMono), ("stereo", fixtures.fadeStereo)] {
            for (start, count) in [(Int64(0), Int64(22_050)), (Int64(1_000), Int64(22_050))] {
                let file = try AVAudioFile(forReading: url)
                let baked = try ClipFadeBake.bakePiece(
                    file: file, sourceStartFrame: start, frameCount: count,
                    clip: clip, clipRelativeStartFrame: 0,
                    tempoMap: TempoMap(constantBPM: 120))
                let got = Int(baked.frameLength)
                measured.append("\(label) start \(start): \(got)/\(count)")
                #expect(got == Int(count),
                        "\(label) start \(start): baked \(got) of \(count) frames")
                let data = try #require(baked.floatChannelData)
                var firstWrong = -1
                for frame in 0..<got where data[0][frame] != Float(Int(start) + frame) {
                    firstWrong = frame
                    break
                }
                let expectedSource = Int(start) + max(0, firstWrong)
                #expect(firstWrong == -1,
                        "\(label) start \(start): frame \(firstWrong) is not source frame \(expectedSource)")
            }
        }
        print("[measured] m32-h bakePiece — " + measured.joined(separator: ", "))
    }

    // MARK: - Gate (d): termination

    /// A genuinely short/corrupt source must TERMINATE, not spin.
    ///
    /// ⚠️ Measured first rather than assumed, and the measurement changed the
    /// test: byte-truncating a WAV does NOT leave `AVAudioFile` believing the
    /// header. It CLAMPS `.length` at open to the frames actually present
    /// (22 050-frame header, 2 000 frames of data removed → `.length` reports
    /// 20 050). So the realistic corrupt file terminates on the ordinary
    /// end-of-data path.
    ///
    /// ⚠️ AND THE SECOND LEG'S MECHANISM IS NOT WHAT IT FIRST LOOKED LIKE. An
    /// over-ask does NOT walk off the end returning zero frames until a
    /// no-progress guard stops it — a read AT end-of-file **throws**
    /// (`_GenericObjCError.nilError`, no message, no code). So the loop must
    /// stop BEFORE that read, and it does: on the `remaining > 0` gate derived
    /// from `framePosition` vs `length`. The `got > 0` no-progress guard is
    /// real but is now defence-in-depth — with `.length` clamped at open and
    /// the EOF gate in front of every read, no ordinary file reaches it. That
    /// is stated plainly rather than left implied, because a gate whose
    /// mechanism is described wrongly is a gate nobody can reason about.
    ///
    /// `.timeLimit` makes "terminates" an assertion rather than a hope — an
    /// infinite loop fails this test instead of hanging the run.
    @Test("m32-h: a truncated file and an over-long request both TERMINATE",
          .timeLimit(.minutes(1)))
    func shortAndOverAskedReadsTerminate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32h-trunc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Leg 1: a byte-truncated WAV. Header still claims 22 050 frames; 8 000
        // bytes (2 000 mono float32 frames) of data are gone.
        let url = dir.appendingPathComponent("truncated.wav")
        try writeRampWAV(frames: 22_050, channels: 1, to: url)
        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count - 8_000).write(to: url)

        let truncated = try AVAudioFile(forReading: url)
        let clampedLength = Int(truncated.length)
        #expect(clampedLength == 20_050,
                "AVAudioFile no longer clamps .length to the data present (got \(clampedLength)) — re-measure this test's premise")
        let truncatedRead = try AudioFileFullRead.readWholeFile(truncated)
        let buffer = try #require(truncatedRead, "readWholeFile returned nil")
        #expect(Int(buffer.frameLength) == clampedLength)
        let data = try #require(buffer.floatChannelData, "floatChannelData nil")
        #expect(data[0][clampedLength - 1] == Float(clampedLength - 1),
                "the surviving frames are the file's own, in order")

        // Leg 2: OVER-ASK — request ~10x the frames the file holds.
        //
        // ⚠️ This leg caught a real defect in the first draft of the helper and
        // is the reason it exists. Reading when `framePosition == length` does
        // NOT return zero frames: it fails by returning NO **without setting an
        // NSError**, which Swift surfaces as `_GenericObjCError.nilError` — an
        // exception with no message and no code. A helper that loops on a frame
        // count alone therefore turns "you asked for more than I have" into a
        // blank throw, which is a WORSE failure than the short read being
        // fixed. The gate is that an over-ask returns what exists, quietly.
        // ⛔ If this ever reddens with a thrown error rather than a wrong
        // count, the EOF gate in `AudioFileFullRead.fill` has been removed.
        let over = try AVAudioFile(forReading: url)
        let big = try #require(AVAudioPCMBuffer(pcmFormat: over.processingFormat,
                                                frameCapacity: 200_000),
                               "over-ask buffer allocation nil")
        let filled = try AudioFileFullRead.fill(big, from: over, frameCount: 200_000)
        #expect(Int(filled) == clampedLength,
                "over-asking must return what exists (\(clampedLength)), not \(filled)")
        #expect(big.frameLength == filled)

        // Leg 3: an EMPTY buffer request is a no-op, not a spin.
        let zeroAsk = try AudioFileFullRead.fill(big, from: over, frameCount: 0)
        #expect(zeroAsk == 0)
        #expect(big.frameLength == 0)
        print("[measured] m32-h termination — truncated .length \(clampedLength) "
              + "(header claimed 22050), over-ask of 200000 returned \(filled)")
    }
}
