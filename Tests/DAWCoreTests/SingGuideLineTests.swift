import CryptoKit
import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d3 — `SingGuideLine`: Fixture P1 and the two bundled guide tunes (design §5.4 step 1, §3.7 step 8).
/// The loudness and SwiftF0 re-gate of the same files lives in `Tests/DAWEngineTests/SingGuideFileGateTests.swift`.
@Suite("Sing guide line P1 and its bundled tunes (p2-sing-d3)")
struct SingGuideLineTests {

    @Test("P1: 10 notes over 8 beats = 4.8 s at 100 BPM; the words cover every note once; 'gently' spans two notes")
    func p1Facts() {
        #expect(SingGuideLine.notes.count == 10)
        #expect(SingGuideLine.lengthBeats == 8)
        #expect(abs(SingGuideLine.spanSeconds - 4.8) < 1e-12)
        let covered = SingGuideLine.words.flatMap(\.noteIndices)
        #expect(covered == Array(0..<10))
        #expect(SingGuideLine.words.first { $0.text == "gently" }?.noteIndices == [5, 6])
        #expect(SingGuideLine.words.map(\.text).joined(separator: " ").lowercased()
                == SingGuideLine.text.lowercased().replacingOccurrences(of: ",", with: ""))
        // The spike's P1_REL for C4: (start_s, end_s, midi).
        let timed = SingGuideLine.timedNotes(startMidi: 60)
        #expect(timed.map(\.midi) == [60, 60, 60, 62, 64, 64, 62, 64, 65, 67])
        #expect(abs(timed[3].startSeconds - 1.65) < 1e-12 && abs(timed[3].endSeconds - 1.8) < 1e-12)
        #expect(abs(timed[9].endSeconds - 4.8) < 1e-12)
        // Notes tile the line: each starts where the previous ends.
        for i in 1..<timed.count { #expect(abs(timed[i].startSeconds - timed[i - 1].endSeconds) < 1e-12) }
    }

    @Test("both guide tunes resolve from the DAWCore resource bundle and are the published bytes (sha256 pinned)",
          arguments: SingGuideLine.Guide.allCases)
    func guideBytesArePinned(guide: SingGuideLine.Guide) throws {
        let url = try #require(SingGuideLine.url(for: guide), "\(guide.fileName) must ship in daw-pro_DAWCore.bundle")
        let data = try Data(contentsOf: url)
        #expect(data.count == 811_244)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == guide.sha256)
    }

    @Test("guide layout: 48 kHz mono, 8.45 s; silent before the first click at 0.25 s and after the melody ends",
          arguments: SingGuideLine.Guide.allCases)
    func guideLayout(guide: SingGuideLine.Guide) throws {
        let audio = try SingGuideLine.loadGuide(guide)
        #expect(audio.sampleRate == SingGuideLine.guideSampleRate)
        #expect(audio.channelData.count == 1)
        #expect(audio.frameCount == SingGuideLine.guideFrames)
        let x = audio.channelData[0]
        let leadEnd = Int(SingGuideLine.guideLeadSilenceSeconds * audio.sampleRate)
        #expect(x[0..<leadEnd].allSatisfy { $0 == 0 }, "the 0.25 s lead must be digital silence")
        #expect(x[leadEnd..<(leadEnd + 480)].contains { $0 != 0 }, "the first click starts at 0.25 s")
        // The melody's last note ends 45 ms early (make_guides' articulation gap); the file's last 1.0 s is silent.
        let tailStart = SingGuideLine.guideFrames - Int(SingGuideLine.guideTailSilenceSeconds * audio.sampleRate)
        #expect(x[tailStart...].allSatisfy { $0 == 0 })
        #expect(abs(SingGuideLine.guideMelodyStartSeconds - 2.65) < 1e-12)
        let notes = SingGuideLine.notesInGuideFile(guide)
        #expect(notes.first?.midi == guide.startMidi)
        #expect(abs((notes.last?.endSeconds ?? 0) - 7.45) < 1e-12)
        // Every sample is finite and inside full scale (16-bit decode).
        #expect(x.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    @Test("the PCM16 reader refuses what it cannot read, loudly")
    func readerRefusals() {
        #expect(throws: SingGuideLine.GuideError.self) { try SingGuideLine.decodePCM16WAV(Data("not a wav".utf8)) }
        // A float WAV header (format 3): refused, not misread.
        var header = [UInt8]("RIFF".utf8) + [36, 0, 0, 0] + [UInt8]("WAVE".utf8) + [UInt8]("fmt ".utf8)
        header += [16, 0, 0, 0, 3, 0, 1, 0, 0x80, 0xBB, 0, 0, 0, 0xEE, 2, 0, 4, 0, 32, 0]
        header += [UInt8]("data".utf8) + [0, 0, 0, 0]
        #expect(throws: SingGuideLine.GuideError.self) { try SingGuideLine.decodePCM16WAV(Data(header)) }
    }
}
