import Foundation
import Testing
@testable import DAWCore

/// m20-g §8.1: the RIFF `smpl`-chunk reader, proven against hand-built WAV
/// bytes (the GenerationImportTests le32/le16 builder idiom). The reader
/// never throws and never reads sample data; every structural surprise
/// yields nil.
@Suite("WAV smpl loops — the m20-g loop-point fallback reader")
struct WAVSampleLoopsTests {
    // MARK: byte builders

    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// One RIFF chunk: 4-byte id + UInt32-LE size + body (+ the spec's pad
    /// byte when the body is odd-sized, unless the fixture deliberately lies).
    private func chunk(_ id: String, _ body: Data, pad: Bool = true) -> Data {
        var data = Data(id.utf8)
        data.append(le32(UInt32(body.count)))
        data.append(body)
        if pad && body.count % 2 != 0 { data.append(0) }
        return data
    }

    /// A 16-byte PCM `fmt ` body (mono, 48 kHz, 16-bit).
    private var fmtBody: Data {
        var data = Data()
        data.append(le16(1)); data.append(le16(1))
        data.append(le32(48_000)); data.append(le32(96_000))
        data.append(le16(2)); data.append(le16(16))
        return data
    }

    /// A `smpl` chunk body: the fixed 36-byte header (cSampleLoops at offset
    /// 28) followed by 24-byte loop records (dwType, dwStart, dwEnd).
    private func smplBody(loops: [(type: UInt32, start: UInt32, end: UInt32)],
                          claimedCount: UInt32? = nil) -> Data {
        var data = Data()
        for _ in 0..<7 { data.append(le32(0)) }          // dwManufacturer...dwSMPTEOffset
        data.append(le32(claimedCount ?? UInt32(loops.count)))  // cSampleLoops
        data.append(le32(0))                             // cbSamplerData
        for (index, loop) in loops.enumerated() {
            data.append(le32(UInt32(index)))             // dwIdentifier
            data.append(le32(loop.type))                 // dwType
            data.append(le32(loop.start))                // dwStart
            data.append(le32(loop.end))                  // dwEnd
            data.append(le32(0))                         // dwFraction
            data.append(le32(0))                         // dwPlayCount
        }
        return data
    }

    /// Assembles `RIFF` + chunks into a temp .wav file.
    private func writeWAV(chunks: [Data], magic: String = "RIFF",
                          form: String = "WAVE") throws -> URL {
        var body = Data(form.utf8)
        for c in chunks { body.append(c) }
        var data = Data(magic.utf8)
        data.append(le32(UInt32(body.count)))
        data.append(body)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-smpl-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    private var tinyData: Data { chunk("data", Data(repeating: 0, count: 16)) }

    // MARK: §8.1 cases

    // 1. A forward loop parses with the exact dwStart/dwEnd (inclusive, D4).
    @Test("forward loop parsed with exact dwStart/dwEnd")
    func forwardLoopParsed() throws {
        let url = try writeWAV(chunks: [
            chunk("fmt ", fmtBody),
            chunk("smpl", smplBody(loops: [(type: 0, start: 4_410, end: 48_509)])),
            tinyData,
        ])
        let loop = try #require(WAVSampleLoops.firstForwardLoop(in: url))
        #expect(loop.startFrame == 4_410)
        #expect(loop.endFrameInclusive == 48_509)
    }

    // 2. `smpl` AFTER `data` (the common layout) is still found — the walk
    //    seeks over non-matching chunk bodies.
    @Test("smpl chunk after data is found")
    func smplAfterData() throws {
        let url = try writeWAV(chunks: [
            chunk("fmt ", fmtBody),
            tinyData,
            chunk("smpl", smplBody(loops: [(type: 0, start: 100, end: 200)])),
        ])
        #expect(WAVSampleLoops.firstForwardLoop(in: url)
                == WAVSampleLoops.Loop(startFrame: 100, endFrameInclusive: 200))
    }

    // 3. An odd-sized chunk before `smpl` — the RIFF pad byte is honored, so
    //    the walk stays aligned.
    @Test("odd-sized chunk before smpl — pad byte honored")
    func oddChunkPadding() throws {
        let url = try writeWAV(chunks: [
            chunk("fmt ", fmtBody),
            chunk("LIST", Data(repeating: 0x41, count: 7)),  // odd body → 1 pad byte
            chunk("smpl", smplBody(loops: [(type: 0, start: 5, end: 9)])),
        ])
        #expect(WAVSampleLoops.firstForwardLoop(in: url)
                == WAVSampleLoops.Loop(startFrame: 5, endFrameInclusive: 9))
    }

    // 4. Two loops, first ping-pong (dwType 1), second forward (dwType 0) —
    //    the forward one wins; non-forward types are skipped, not fatal.
    @Test("first forward loop wins over a preceding ping-pong record")
    func forwardWinsOverPingPong() throws {
        let url = try writeWAV(chunks: [
            chunk("fmt ", fmtBody),
            chunk("smpl", smplBody(loops: [
                (type: 1, start: 10, end: 20),      // ping-pong — skipped
                (type: 0, start: 300, end: 900),    // forward — returned
            ])),
            tinyData,
        ])
        #expect(WAVSampleLoops.firstForwardLoop(in: url)
                == WAVSampleLoops.Loop(startFrame: 300, endFrameInclusive: 900))
    }

    // 5. `cSampleLoops` lies high — record iteration is bounded by what the
    //    chunk size can hold; no crash, the one real record still parses.
    @Test("lying cSampleLoops is bounded by the chunk size")
    func lyingLoopCountBounded() throws {
        let url = try writeWAV(chunks: [
            chunk("fmt ", fmtBody),
            chunk("smpl", smplBody(loops: [(type: 0, start: 7, end: 70)],
                                   claimedCount: 1_000_000)),
            tinyData,
        ])
        #expect(WAVSampleLoops.firstForwardLoop(in: url)
                == WAVSampleLoops.Loop(startFrame: 7, endFrameInclusive: 70))
    }

    // 6. A truncated `smpl` chunk (header claims more than the file holds) → nil.
    @Test("truncated smpl chunk yields nil")
    func truncatedSmpl() throws {
        var body = smplBody(loops: [(type: 0, start: 1, end: 2)])
        body = body.prefix(20)  // less than the 36-byte fixed header
        // Hand-build the chunk with the LYING full size so the read comes up short.
        var smpl = Data("smpl".utf8)
        smpl.append(le32(60))   // claims a full header + one record
        smpl.append(body)
        let url = try writeWAV(chunks: [chunk("fmt ", fmtBody), smpl])
        #expect(WAVSampleLoops.firstForwardLoop(in: url) == nil)
    }

    // 7. `dwEnd < dwStart` — the inverted record is rejected → nil (no other
    //    qualifying record).
    @Test("inverted record (dwEnd < dwStart) is rejected")
    func invertedRecordRejected() throws {
        let url = try writeWAV(chunks: [
            chunk("fmt ", fmtBody),
            chunk("smpl", smplBody(loops: [(type: 0, start: 500, end: 100)])),
            tinyData,
        ])
        #expect(WAVSampleLoops.firstForwardLoop(in: url) == nil)
    }

    // 8. Non-RIFF, non-WAVE, and empty files → nil, never a throw.
    @Test("non-RIFF / non-WAVE / empty files yield nil")
    func nonWAVFiles() throws {
        let notRIFF = try writeWAV(
            chunks: [chunk("smpl", smplBody(loops: [(type: 0, start: 1, end: 2)]))],
            magic: "FORM")
        #expect(WAVSampleLoops.firstForwardLoop(in: notRIFF) == nil)

        let notWAVE = try writeWAV(
            chunks: [chunk("smpl", smplBody(loops: [(type: 0, start: 1, end: 2)]))],
            form: "AVI ")
        #expect(WAVSampleLoops.firstForwardLoop(in: notWAVE) == nil)

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-smpl-empty-\(UUID().uuidString).wav")
        try Data().write(to: empty)
        #expect(WAVSampleLoops.firstForwardLoop(in: empty) == nil)

        let missing = URL(fileURLWithPath: "/nonexistent/ghost-\(UUID().uuidString).wav")
        #expect(WAVSampleLoops.firstForwardLoop(in: missing) == nil)
    }

    // 9. A perfectly valid WAV with no `smpl` chunk → nil.
    @Test("no smpl chunk yields nil")
    func noSmplChunk() throws {
        let url = try writeWAV(chunks: [chunk("fmt ", fmtBody), tinyData])
        #expect(WAVSampleLoops.firstForwardLoop(in: url) == nil)
    }
}
