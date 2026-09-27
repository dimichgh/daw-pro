import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// p2-sing-d3 — the two bundled guide tunes, RE-GATED on the shipped bytes (design §5.4 step 1): −18.0 LUFS, true peak
/// −9.5 and −9.1 dBTP (SING-6's measurements [M]) with `Loudness`, and every note within ±10 c of P1 by SwiftF0 —
/// `ClipPitchAnalyzer.detect`, the whole body of `AudioEngine.detectPitch(inFileAt:)` (`AudioEngine.swift:3366`).
/// NEGATIVE CONTROL: the same bytes declared 12 c sharp must FAIL the ±10 c bar, so the bar can fail.
@Suite("Sing guide files re-gated: Loudness and SwiftF0 (p2-sing-d3, design §5.4)", .serialized)
struct SingGuideFileGateTests {

    /// Decode through AVAudioFile, the engine's decoder, with the engine's full read (`AudioFileFullRead`, m32-h: a
    /// single `read(into:)` short-reads a mono file to a 1024-frame boundary — 96 frames of these 405 600).
    static func decode(_ url: URL) throws -> RenderedAudio {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = try AudioFileFullRead.readWholeFile(file), let data = buffer.floatChannelData else {
            throw EngineError.renderFailed("decode: an empty file, or the buffer could not be allocated")
        }
        let n = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        return RenderedAudio(sampleRate: buffer.format.sampleRate, channelData: channels)
    }

    /// Cents of each P1 note in `guide`'s file: SwiftF0's median f0 over the middle 50% of the note's window (the §1.7
    /// statistic), against the written pitch. `rateScale` re-declares the file's rate (1.0 = as shipped).
    static func noteCents(_ guide: SingGuideLine.Guide, rateScale: Double = 1) throws -> [Double?] {
        let url = try #require(SingGuideLine.url(for: guide))
        var analysed = url
        var dir: URL?
        if rateScale != 1 {
            // The negative control: the same samples, declared at rate × scale, so every pitch moves by 1200·log2(scale).
            let audio = try decode(url)
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("daw-pro-sd3-guide-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            dir = temp
            analysed = temp.appendingPathComponent(guide.fileName)
            let rate = audio.sampleRate * rateScale
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
            let file = try AVAudioFile(forWriting: analysed, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.frameCount)))
            for (i, s) in audio.channelData[0].enumerated() { buffer.floatChannelData![0][i] = s }
            buffer.frameLength = AVAudioFrameCount(audio.frameCount)
            try file.write(from: buffer)
        }
        defer { if let dir { try? FileManager.default.removeItem(at: dir) } }
        let frames = try ClipPitchAnalyzer.detect(
            fileAt: analysed, fromSeconds: 0, durationSeconds: 9,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs).frames
        return SingGuideLine.notesInGuideFile(guide).map { note in
            let start = note.startSeconds / rateScale
            let end = note.endSeconds / rateScale
            let lo = start + 0.25 * (end - start)
            let hi = start + 0.75 * (end - start)
            let f0 = frames.filter { $0.timeSeconds >= lo && $0.timeSeconds < hi }.compactMap(\.frequencyHz).sorted()
            guard !f0.isEmpty else { return nil }
            let median = f0.count % 2 == 1 ? f0[f0.count / 2] : (f0[f0.count / 2 - 1] + f0[f0.count / 2]) / 2
            return 1200 * log2(median / (440 * pow(2, (Double(note.midi) - 69) / 12)))
        }
    }

    @Test("Loudness: each shipped guide measures -18.0 LUFS integrated and its SING-6 true peak (-9.5 / -9.1 dBTP)",
          arguments: SingGuideLine.Guide.allCases)
    func loudnessAndTruePeak(guide: SingGuideLine.Guide) throws {
        let audio = try Self.decode(try #require(SingGuideLine.url(for: guide)))
        let measured = Loudness.measure(audio)
        let lufs = try #require(measured.integratedLufs)
        let tp = try #require(measured.truePeakDbtp)
        print(String(format: "[measured] %@ guide: %.2f LUFS, TP %.2f dBTP (SING-6: -18.0 LUFS, %.1f dBTP)", guide.rawValue,
                     lufs, tp, guide.measuredTruePeakDbtp))
        #expect(abs(lufs - SingGuideLine.guideIntegratedLufs) <= 0.1, "\(guide): \(lufs) LUFS")
        #expect(abs(tp - guide.measuredTruePeakDbtp) <= 0.1, "\(guide): \(tp) dBTP")
        // The AVAudioFile decode and DAWCore's own PCM16 reader agree on the samples.
        let own = try SingGuideLine.loadGuide(guide)
        #expect(own.frameCount == audio.frameCount)
        let worst = zip(own.channelData[0], audio.channelData[0]).map { abs($0 - $1) }.max() ?? 1
        #expect(worst <= 1.0 / 32768, "decoders disagree by \(worst)")
    }

    @Test("SwiftF0: every P1 note in each shipped guide is within ±10 c of its written pitch",
          arguments: SingGuideLine.Guide.allCases)
    func everyNoteWithinTenCents(guide: SingGuideLine.Guide) throws {
        let cents = try Self.noteCents(guide)
        print("[measured] \(guide.rawValue) guide cents per note: \(cents.map { $0.map { ($0 * 100).rounded() / 100 } })")
        #expect(cents.count == 10)
        for (k, c) in cents.enumerated() {
            let value = try #require(c, "note \(k) had no confident SwiftF0 frame")
            #expect(abs(value) <= 10, "note \(k): \(value) c")
        }
    }

    @Test("NEGATIVE CONTROL: the higher guide declared 12 c sharp FAILS the ±10 c gate")
    func detunedGuideFails() throws {
        let cents = try Self.noteCents(.high, rateScale: pow(2, 12.0 / 1200))
        print("[measured] high guide +12 c control, cents per note: \(cents.map { $0.map { ($0 * 100).rounded() / 100 } })")
        let read = cents.compactMap { $0 }
        #expect(read.count == 10)
        let outside = read.filter { abs($0) > 10 }.count
        print("[measured] +12 c control: \(outside)/10 notes outside ±10 c")
        // The gate (every note within ±10 c) must go red. It does NOT go red on every note: SwiftF0's reading moved by
        // +0.4 c (C4: −2.05 → −1.67) up to +26.7 c (G4) for the same +12 c, so its error on these tones reaches ~14 c —
        // the ±10 c bar sits at the instrument's own resolution (a p2-sing-d3 finding, first run 2026-09-27).
        #expect(outside >= 1, "the +12 c control must fail the gate")
    }
}
