import Foundation

/// RIFF `smpl`-chunk reader (m20-g §4.3): the loop-point fallback for WAV
/// samples whose library text authored no loop opcodes. Returns the FIRST
/// forward loop, or nil for anything else — this parser NEVER throws and
/// NEVER reads sample data (bounded header reads only; a 4 GB WAV costs a
/// few seeks).
///
/// Non-goals (documented in docs/SFZ-SUPPORT.md): ping-pong/backward
/// (`dwType` 1/2) and vendor loop types are skipped; only the FIRST forward
/// loop is used; `dwPlayCount` is ignored (all loops treated as infinite);
/// `dwFraction` is ignored; the MIDI unity note is NOT consumed (root pitch
/// stays the text format's business); AIFF `INST`/`MARK` metadata is out of
/// scope. A malformed or absent `smpl` chunk yields nil silently — the
/// absence of a bonus is not a degradation.
enum WAVSampleLoops {
    struct Loop: Equatable, Sendable {
        var startFrame: Int          // dwStart, sample frames
        var endFrameInclusive: Int   // dwEnd, sample frames, INCLUSIVE (D4)
    }

    /// Corrupt-file guard: a well-formed WAV has a handful of chunks; walking
    /// more than this means the size fields are lying in a loop.
    private static let maxChunks = 10_000

    static func firstForwardLoop(in url: URL) -> Loop? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        func read(_ count: Int, at offset: UInt64) -> Data? {
            guard count > 0 else { return nil }
            do {
                try handle.seek(toOffset: offset)
                guard let data = try handle.read(upToCount: count),
                      data.count == count else { return nil }
                return data
            } catch { return nil }
        }
        func le32(_ data: Data, _ offset: Int) -> UInt32 {
            // Data slices keep their parent indices — rebase explicitly.
            let base = data.startIndex + offset
            return UInt32(data[base])
                | UInt32(data[base + 1]) << 8
                | UInt32(data[base + 2]) << 16
                | UInt32(data[base + 3]) << 24
        }

        // 1. RIFF/WAVE signature — 12-byte header. The RIFF size (bytes 4-7)
        //    is read but never trusted.
        guard let header = read(12, at: 0),
              header.prefix(4).elementsEqual("RIFF".utf8),
              header.suffix(4).elementsEqual("WAVE".utf8) else { return nil }

        // 2. Chunk walk from offset 12. `smpl` commonly sits AFTER `data`, so
        //    the walk continues past non-matches — but it only ever SEEKS over
        //    chunk bodies other than `smpl`'s.
        var offset: UInt64 = 12
        for _ in 0..<maxChunks {
            guard let chunkHeader = read(8, at: offset) else { return nil }  // file end / short read
            let ckSize = le32(chunkHeader, 4)
            if chunkHeader.prefix(4).elementsEqual("smpl".utf8) {
                // 3. Need the fixed 36-byte smpl header; cSampleLoops at
                //    chunk-data offset 28.
                guard ckSize >= 36, let smplHeader = read(36, at: offset + 8) else { return nil }
                let cSampleLoops = Int(le32(smplHeader, 28))
                // 4. The lying-header guard: never trust cSampleLoops past
                //    what ckSize can actually hold (24 bytes per record).
                let recordCount = min(cSampleLoops, (Int(ckSize) - 36) / 24)
                for record in 0..<max(0, recordCount) {
                    let recordOffset = offset + 8 + 36 + UInt64(record * 24)
                    guard let bytes = read(24, at: recordOffset) else { return nil }  // truncated
                    let dwType = le32(bytes, 4)
                    guard dwType == 0 else { continue }  // forward loops only
                    guard let start = Int(exactly: le32(bytes, 8)),
                          let end = Int(exactly: le32(bytes, 12)),
                          end >= start else { continue }  // inverted record — skip
                    // dwFraction (16) and dwPlayCount (20) read past, unused.
                    return Loop(startFrame: start, endFrameInclusive: end)
                }
                return nil  // one smpl chunk is the spec shape; no second search
            }
            // RIFF word alignment: odd-sized chunks carry one pad byte.
            offset += 8 + UInt64(ckSize) + UInt64(ckSize & 1)
        }
        return nil
    }
}
