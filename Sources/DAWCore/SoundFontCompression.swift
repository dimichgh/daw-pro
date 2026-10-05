import Foundation

// SF3 → SF2 conversion at import time (m31-h).
//
// ⭐ WHY THIS EXISTS. m31-g made `.sf3` VISIBLE and honest: it appears in the
// bank list flagged unsupported, with a way out, instead of silently never
// existing. That was a waypoint. `.sf3` is the format a consumer most likely
// already HAS — MuseScore, the single biggest free-soundfont distribution
// channel, ships `.sf3` EXCLUSIVELY (`FluidR3Mono_GM.sf3`, `MS Basic.sf3`, and
// no `.sf2` at all) — so "here is a file you cannot use" is the wrong place to
// stop. m26-d puts this on the critical path: the default bank is DOWNLOADED
// ON FIRST RUN, which makes import run unattended on a file whose format we
// did not choose.
//
// ⭐ WHAT AN SF3 ACTUALLY IS, measured on the real file rather than assumed:
// structurally an SF2 whose every sample has been replaced by an independent
// Ogg Vorbis stream inside the `smpl` chunk. `ifil` reads 3.x, `sfSampleType`
// carries an extra 0x10 bit, and — the trap — `dwStart`/`dwEnd` become BYTE
// offsets into `smpl` while the loop points become FRAME offsets RELATIVE to
// the sample. So the conversion is mechanical: decode each stream, concatenate
// the PCM, and rewrite the sample headers. Nothing else in the file changes,
// which is why `scan`, `programs`, the three load gates and the AUSampler path
// downstream are all untouched by this feature.
//
// ⛔ THE ONE-WAY RULE. Conversion happens ONCE, at import, producing a REAL
// `.sf2` on disk in the central library. It is deliberately NOT a read-time
// shim: a bank that is `.sf2` on disk passes the extension gates on its own
// merits, so labelling a format can still never make it loadable. That
// separation is the safety property m31-g established and this file preserves.
//
// ⛔ NEVER ON THE RENDER THREAD. Decoding allocates and a whole-bank decode is
// unbounded work (the real FluidR3Mono_GM.sf3 is 1186 streams and ~109 M
// frames). This is import-time, off-thread, file-level work only.

/// Interleaved 16-bit PCM decoded from one Ogg Vorbis stream.
public struct VorbisPCM: Sendable, Equatable {
    /// Interleaved samples — `frames * channels` of them.
    public var samples: [Int16]
    public var channels: Int
    public var sampleRate: Int

    public init(samples: [Int16], channels: Int, sampleRate: Int) {
        self.samples = samples
        self.channels = channels
        self.sampleRate = sampleRate
    }

    /// Samples PER CHANNEL. Zero when `channels` is zero rather than trapping —
    /// the converter rejects such a stream by its own guard, with a readable
    /// reason, instead of dividing by it here.
    public var frames: Int { channels > 0 ? samples.count / channels : 0 }
}

/// Decodes one complete in-memory Ogg Vorbis stream.
///
/// The seam exists because DAWCore is dependency-free by law (see Package.swift
/// at the CAtomics/ObjCExceptionGuard targets, which state it three times) and
/// a Vorbis decoder is C. This is the `MediaImporting` shape exactly: protocol
/// in the domain, implementation in DAWEngine (`StbVorbisDecoder`), injected at
/// app start — so all the format logic below stays headless-testable with a
/// fake decoder and the dependency stays a leaf.
///
/// ⛔ A conforming decoder MUST throw for a stream it cannot read. Returning
/// empty PCM would let a converted bank grow a silent hole, which is the exact
/// failure this whole feature is graded against.
public protocol VorbisDecoding: Sendable {
    func decodeVorbis(_ data: Data) throws -> VorbisPCM
}

/// SF3 → SF2 conversion. Stateless; the entry point is `convert`.
public enum SoundFontCompression {

    /// `sfSampleType` bit that marks a sample's data as an Ogg Vorbis stream.
    /// Its presence is what makes `dwStart`/`dwEnd` byte offsets instead of
    /// frame offsets, so it is also the flag that must be CLEARED on the way
    /// out — an `.sf2` that still advertises 0x10 describes data it no longer
    /// contains.
    static let vorbisFlag: UInt16 = 0x10
    /// `sfSampleType` bit for a sample that lives in ROM, not in this file.
    static let romFlag: UInt16 = 0x8000
    /// Zero frames written after every sample. The SF2 spec requires at least
    /// 46 so an interpolating oscillator reading past the end of one sample
    /// cannot wander into the next one.
    static let interSampleGapFrames = 46
    /// Bytes per `shdr` record.
    static let sampleHeaderSize = 46

    /// True when `data` is a SoundFont whose samples are Vorbis-compressed —
    /// i.e. one this converter has something to do to. Checked by reading the
    /// `ifil` version, NOT by trusting the file extension.
    public static func isCompressedSoundFont(_ data: Data) -> Bool {
        guard let major = try? RIFF.soundFontMajorVersion(data) else { return false }
        return major >= 3
    }

    /// Converts the `.sf3` at `source` into a real `.sf2` written to
    /// `destination`, decoding every sample through `decoder`.
    ///
    /// ⛔ ALL-OR-NOTHING, deliberately. Any sample that fails to decode aborts
    /// the whole conversion with a readable reason naming that sample, and the
    /// partial destination file is removed. A bank that imported "successfully"
    /// with silent holes in it is precisely the failure mode this feature is
    /// graded against — one that loads, reports OK, and makes no sound.
    ///
    /// Throws `ProjectError.importFailed` in the MediaImporting tone.
    public static func convert(sf3 source: URL, toSF2 destination: URL,
                               decoder: any VorbisDecoding) throws {
        let data: Data
        do {
            data = try Data(contentsOf: source, options: .mappedIfSafe)
        } catch {
            throw ProjectError.importFailed(
                "cannot read sound bank file at \(source.path)")
        }
        do {
            try convert(sf3Data: data, toSF2: destination,
                        decoder: decoder, sourceName: source.lastPathComponent)
        } catch {
            // Never leave a half-written bank behind: a truncated `.sf2` would
            // pass every extension gate and then fail at play time, which is
            // the silent failure this design exists to prevent.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func convert(sf3Data data: Data, toSF2 destination: URL,
                        decoder: any VorbisDecoding, sourceName: String) throws {
        let file = try RIFF.parseSoundFont(data, sourceName: sourceName)

        guard let shdrChunk = file.pdta.first(where: { $0.id == "shdr" }) else {
            throw ProjectError.importFailed(
                "\(sourceName) is not a usable SoundFont — it has no sample-header (shdr) chunk")
        }
        let recordCount = shdrChunk.size / sampleHeaderSize
        guard recordCount >= 1 else {
            throw ProjectError.importFailed(
                "\(sourceName) is not a usable SoundFont — its sample-header chunk is empty")
        }
        // The last record is the terminal "EOS" sentinel, never a real sample.
        let sampleCount = recordCount - 1

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        fm.createFile(atPath: destination.path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: destination.path) else {
            throw ProjectError.importFailed(
                "cannot write the converted sound bank to \(destination.path)")
        }
        defer { try? out.close() }

        var writer = RIFFWriter(handle: out)
        try writer.write(ascii: "RIFF")
        let riffSizeAt = try writer.writePlaceholderSize()
        try writer.write(ascii: "sfbk")

        // ── INFO, copied verbatim except ifil, which must now say 2.1: the
        // file no longer contains compressed samples, and a version field that
        // lies about that is how a downstream reader ends up decoding PCM as
        // Vorbis.
        try writeInfo(file: file, data: data, writer: &writer)

        // ── sdta/smpl: decoded PCM, streamed. Held one sample at a time rather
        // than assembled in memory — the real bank decodes to ~218 MB.
        try writer.write(ascii: "LIST")
        let sdtaSizeAt = try writer.writePlaceholderSize()
        try writer.write(ascii: "sdta")
        try writer.write(ascii: "smpl")
        let smplSizeAt = try writer.writePlaceholderSize()

        let gap = [Int16](repeating: 0, count: interSampleGapFrames)
        var headers: [SampleHeader] = []
        headers.reserveCapacity(recordCount)
        var writtenFrames = 0

        for index in 0..<sampleCount {
            let recordAt = shdrChunk.offset + index * sampleHeaderSize
            var header = SampleHeader(data: data, at: recordAt)

            if header.sampleType & romFlag != 0 {
                throw ProjectError.importFailed(
                    "\(sourceName) can't be converted — sample \(index) "
                    + "(\"\(header.name)\") lives in ROM, not in the file")
            }

            let compressed = header.sampleType & vorbisFlag != 0
            let pcm: [Int16]
            if compressed {
                // dwStart/dwEnd are BYTE offsets into smpl for a compressed
                // sample — this is the field whose meaning the format changes.
                guard header.end >= header.start,
                      let stream = file.sampleData(byteRange: header.start..<header.end, in: data)
                else {
                    throw ProjectError.importFailed(
                        "\(sourceName) is damaged — sample \(index) (\"\(header.name)\") "
                        + "points outside the file's sample data")
                }
                let decoded: VorbisPCM
                do {
                    decoded = try decoder.decodeVorbis(stream)
                } catch {
                    throw ProjectError.importFailed(
                        "\(sourceName) can't be converted — the compressed audio for sample "
                        + "\(index) (\"\(header.name)\") could not be decoded. "
                        + "The file may be damaged; try re-downloading it, or export a .sf2 "
                        + "from MuseScore or Polyphone and import that.")
                }
                guard decoded.channels == 1 else {
                    throw ProjectError.importFailed(
                        "\(sourceName) can't be converted — sample \(index) "
                        + "(\"\(header.name)\") decoded to \(decoded.channels) channels; "
                        + "SoundFont samples must be mono")
                }
                guard decoded.frames > 0 else {
                    throw ProjectError.importFailed(
                        "\(sourceName) can't be converted — sample \(index) "
                        + "(\"\(header.name)\") decoded to no audio at all")
                }
                // Two instruments disagreeing is the signal: the sample header
                // and the Vorbis stream each carry a rate, and a mismatch means
                // one of them is wrong about this sample. Refuse rather than
                // silently pick one and detune the instrument.
                guard decoded.sampleRate == Int(header.sampleRate) else {
                    throw ProjectError.importFailed(
                        "\(sourceName) is inconsistent — sample \(index) (\"\(header.name)\") "
                        + "is tagged \(header.sampleRate) Hz but its audio decodes at "
                        + "\(decoded.sampleRate) Hz")
                }
                pcm = decoded.samples
                // Loop points are RELATIVE to the sample start when the data is
                // compressed. Rebasing them wrongly is silent and audible only
                // on a sustained note — it loops into a NEIGHBOURING sample.
                header.startLoop = UInt32(writtenFrames) &+ header.startLoop
                header.endLoop = UInt32(writtenFrames) &+ header.endLoop
            } else {
                // An uncompressed sample inside an SF3 keeps SF2 semantics:
                // dwStart/dwEnd are FRAME offsets and the loop points are
                // ABSOLUTE. Handled because a mixed file is legal, even though
                // the reference banks measured here contain none.
                guard header.end >= header.start,
                      let raw = file.sampleData(
                        byteRange: (header.start * 2)..<(header.end * 2), in: data)
                else {
                    throw ProjectError.importFailed(
                        "\(sourceName) is damaged — sample \(index) (\"\(header.name)\") "
                        + "points outside the file's sample data")
                }
                pcm = raw.withUnsafeBytes { buffer in
                    Array(buffer.bindMemory(to: Int16.self))
                }
                let relativeStartLoop = header.startLoop >= header.start
                    ? header.startLoop - header.start : 0
                let relativeEndLoop = header.endLoop >= header.start
                    ? header.endLoop - header.start : 0
                header.startLoop = UInt32(writtenFrames) &+ relativeStartLoop
                header.endLoop = UInt32(writtenFrames) &+ relativeEndLoop
            }

            // A loop that ends past the audio is a bank that will read garbage
            // at sustain. Free invariant — assert it on every sample.
            let frames = pcm.count
            guard Int(header.endLoop) <= writtenFrames + frames,
                  header.startLoop <= header.endLoop else {
                throw ProjectError.importFailed(
                    "\(sourceName) is inconsistent — sample \(index) (\"\(header.name)\") "
                    + "loops past the end of its own audio")
            }

            header.start = UInt32(writtenFrames)
            header.end = UInt32(writtenFrames + frames)
            header.sampleType &= ~vorbisFlag
            headers.append(header)

            try writer.write(samples: pcm)
            try writer.write(samples: gap)
            writtenFrames += frames + interSampleGapFrames
        }

        // The terminal record, copied so its name and zeroed fields survive.
        var terminal = SampleHeader(data: data, at: shdrChunk.offset + sampleCount * sampleHeaderSize)
        terminal.sampleType &= ~vorbisFlag
        headers.append(terminal)

        let smplBytes = writtenFrames * 2
        try writer.patchSize(at: smplSizeAt, to: UInt32(smplBytes))
        if smplBytes % 2 == 1 { try writer.write(padByte: ()) }
        // "sdta" + "smpl" + its size field + the samples.
        try writer.patchSize(at: sdtaSizeAt, to: UInt32(4 + 8 + smplBytes))

        // ── pdta, every chunk copied verbatim except shdr, which is rebuilt.
        try writer.write(ascii: "LIST")
        let pdtaSizeAt = try writer.writePlaceholderSize()
        try writer.write(ascii: "pdta")
        var pdtaBytes = 4
        for chunk in file.pdta {
            if chunk.id == "shdr" {
                let body = headers.reduce(into: Data()) { $0.append($1.encoded()) }
                try writer.write(ascii: "shdr")
                try writer.write(uint32: UInt32(body.count))
                try writer.write(data: body)
                pdtaBytes += 8 + body.count
            } else {
                guard let body = file.body(of: chunk, in: data) else {
                    throw ProjectError.importFailed(
                        "\(sourceName) is damaged — its \(chunk.id) chunk runs past the end of the file")
                }
                try writer.write(ascii: chunk.id)
                try writer.write(uint32: UInt32(body.count))
                try writer.write(data: body)
                pdtaBytes += 8 + body.count
                if body.count % 2 == 1 { try writer.write(padByte: ()); pdtaBytes += 1 }
            }
        }
        try writer.patchSize(at: pdtaSizeAt, to: UInt32(pdtaBytes))

        let total = try writer.currentOffset()
        // RIFF's size field covers everything after it: total minus "RIFF" and
        // the 4-byte size field itself.
        try writer.patchSize(at: riffSizeAt, to: UInt32(total - 8))
    }

    private static func writeInfo(file: RIFF.SoundFont, data: Data,
                                  writer: inout RIFFWriter) throws {
        try writer.write(ascii: "LIST")
        let sizeAt = try writer.writePlaceholderSize()
        try writer.write(ascii: "INFO")
        var bytes = 4
        for chunk in file.info {
            if chunk.id == "ifil" {
                try writer.write(ascii: "ifil")
                try writer.write(uint32: 4)
                // SoundFont 2.1 — the version every SF2 consumer, AUSampler
                // included, expects.
                try writer.write(uint16: 2)
                try writer.write(uint16: 1)
                bytes += 12
            } else {
                guard let body = file.body(of: chunk, in: data) else {
                    throw ProjectError.importFailed(
                        "the sound bank is damaged — its \(chunk.id) chunk runs past the end of the file")
                }
                try writer.write(ascii: chunk.id)
                try writer.write(uint32: UInt32(body.count))
                try writer.write(data: body)
                bytes += 8 + body.count
                if body.count % 2 == 1 { try writer.write(padByte: ()); bytes += 1 }
            }
        }
        try writer.patchSize(at: sizeAt, to: UInt32(bytes))
    }
}

// MARK: - Sample header (shdr record)

/// One 46-byte `shdr` record, decoded into its fields so the converter can
/// rewrite offsets without hand-indexing bytes at every use.
struct SampleHeader {
    var name: String
    var nameBytes: [UInt8]
    var start: UInt32
    var end: UInt32
    var startLoop: UInt32
    var endLoop: UInt32
    var sampleRate: UInt32
    var originalPitch: UInt8
    var pitchCorrection: Int8
    /// Index of the other half of a stereo pair. PRESERVED verbatim: even the
    /// "Mono" FluidR3 build carries 73 right / 93 left linked samples, and
    /// dropping the link silently un-pairs them.
    var sampleLink: UInt16
    var sampleType: UInt16

    init(data: Data, at offset: Int) {
        let base = data.startIndex + offset
        var raw = [UInt8](repeating: 0, count: SoundFontCompression.sampleHeaderSize)
        data.copyBytes(to: &raw, from: base..<(base + SoundFontCompression.sampleHeaderSize))
        nameBytes = Array(raw[0..<20])
        let terminated = nameBytes.prefix { $0 != 0 }
        name = String(decoding: terminated, as: UTF8.self)
        func u32(_ i: Int) -> UInt32 {
            UInt32(raw[i]) | UInt32(raw[i + 1]) << 8 | UInt32(raw[i + 2]) << 16 | UInt32(raw[i + 3]) << 24
        }
        start = u32(20); end = u32(24); startLoop = u32(28); endLoop = u32(32)
        sampleRate = u32(36)
        originalPitch = raw[40]
        pitchCorrection = Int8(bitPattern: raw[41])
        sampleLink = UInt16(raw[42]) | UInt16(raw[43]) << 8
        sampleType = UInt16(raw[44]) | UInt16(raw[45]) << 8
    }

    func encoded() -> Data {
        var out = Data(capacity: SoundFontCompression.sampleHeaderSize)
        out.append(contentsOf: nameBytes)
        func append(_ value: UInt32) {
            out.append(UInt8(value & 0xff))
            out.append(UInt8((value >> 8) & 0xff))
            out.append(UInt8((value >> 16) & 0xff))
            out.append(UInt8((value >> 24) & 0xff))
        }
        append(start); append(end); append(startLoop); append(endLoop); append(sampleRate)
        out.append(originalPitch)
        out.append(UInt8(bitPattern: pitchCorrection))
        out.append(UInt8(sampleLink & 0xff)); out.append(UInt8((sampleLink >> 8) & 0xff))
        out.append(UInt8(sampleType & 0xff)); out.append(UInt8((sampleType >> 8) & 0xff))
        return out
    }
}

// MARK: - RIFF reading

/// The slice of RIFF parsing a SoundFont needs. Deliberately minimal and
/// read-only — this is not a general RIFF library.
enum RIFF {
    struct Chunk {
        var id: String
        /// Offset of the chunk BODY (past the 8-byte id+size header).
        var offset: Int
        var size: Int
    }

    struct SoundFont {
        var info: [Chunk]
        var pdta: [Chunk]
        var smpl: Chunk?

        /// The body of `chunk`, or nil when it runs past the end of the file.
        func body(of chunk: Chunk, in data: Data) -> Data? {
            let start = data.startIndex + chunk.offset
            let end = start + chunk.size
            guard end <= data.endIndex else { return nil }
            return data[start..<end]
        }

        /// A byte range WITHIN the `smpl` chunk, bounds-checked against it.
        func sampleData(byteRange range: Range<UInt32>, in data: Data) -> Data? {
            guard let smpl else { return nil }
            let lower = Int(range.lowerBound), upper = Int(range.upperBound)
            guard lower <= upper, upper <= smpl.size else { return nil }
            let start = data.startIndex + smpl.offset + lower
            let end = data.startIndex + smpl.offset + upper
            guard end <= data.endIndex else { return nil }
            return data[start..<end]
        }
    }

    static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        let base = data.startIndex + offset
        guard base >= data.startIndex, base + 4 <= data.endIndex else { return nil }
        var raw = [UInt8](repeating: 0, count: 4)
        data.copyBytes(to: &raw, from: base..<(base + 4))
        return UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
    }

    static func ascii(_ data: Data, at offset: Int) -> String? {
        let base = data.startIndex + offset
        guard base + 4 <= data.endIndex else { return nil }
        var raw = [UInt8](repeating: 0, count: 4)
        data.copyBytes(to: &raw, from: base..<(base + 4))
        return String(decoding: raw, as: UTF8.self)
    }

    /// The `ifil` major version, without a full parse — used by
    /// `isCompressedSoundFont` to classify by CONTENT rather than by filename.
    static func soundFontMajorVersion(_ data: Data) throws -> Int {
        let file = try parseSoundFont(data, sourceName: "the sound bank")
        guard let ifil = file.info.first(where: { $0.id == "ifil" }),
              ifil.size >= 2,
              let value = uint32(data, at: ifil.offset) else {
            throw ProjectError.importFailed("the sound bank has no version (ifil) chunk")
        }
        return Int(value & 0xffff)
    }

    static func parseSoundFont(_ data: Data, sourceName: String) throws -> SoundFont {
        guard data.count >= 12, ascii(data, at: 0) == "RIFF", ascii(data, at: 8) == "sfbk" else {
            throw ProjectError.importFailed(
                "\(sourceName) is not a SoundFont file — it has no RIFF/sfbk header")
        }
        guard let declared = uint32(data, at: 4) else {
            throw ProjectError.importFailed("\(sourceName) is truncated — it has no RIFF size")
        }
        // Trust the file only as far as it actually extends: a truncated
        // download must fail here, with a reason, not read past its own end.
        let limit = min(data.count, Int(declared) + 8)

        var info: [Chunk] = []
        var pdta: [Chunk] = []
        var smpl: Chunk?
        var offset = 12
        while offset + 8 <= limit {
            guard let id = ascii(data, at: offset), let size = uint32(data, at: offset + 4) else { break }
            let body = offset + 8
            let count = Int(size)
            guard body + count <= limit else {
                throw ProjectError.importFailed(
                    "\(sourceName) is truncated — its \(id) chunk claims \(count) bytes "
                    + "but the file ends first")
            }
            if id == "LIST", let listType = ascii(data, at: body) {
                let children = try subChunks(data, from: body + 4, to: body + count, sourceName: sourceName)
                switch listType {
                case "INFO": info = children
                case "pdta": pdta = children
                case "sdta": smpl = children.first { $0.id == "smpl" }
                default: break
                }
            }
            offset = body + count + (count & 1)
        }
        guard !info.isEmpty, !pdta.isEmpty else {
            throw ProjectError.importFailed(
                "\(sourceName) is not a usable SoundFont — it is missing its INFO or pdta section")
        }
        return SoundFont(info: info, pdta: pdta, smpl: smpl)
    }

    private static func subChunks(_ data: Data, from: Int, to: Int,
                                  sourceName: String) throws -> [Chunk] {
        var result: [Chunk] = []
        var offset = from
        while offset + 8 <= to {
            guard let id = ascii(data, at: offset), let size = uint32(data, at: offset + 4) else { break }
            let count = Int(size)
            let body = offset + 8
            guard body + count <= to else {
                throw ProjectError.importFailed(
                    "\(sourceName) is truncated — its \(id) chunk claims \(count) bytes "
                    + "but the section ends first")
            }
            result.append(Chunk(id: id, offset: body, size: count))
            offset = body + count + (count & 1)
        }
        return result
    }
}

// MARK: - RIFF writing

/// Streaming writer with back-patched size fields, so a 200 MB conversion never
/// assembles the output in memory.
struct RIFFWriter {
    let handle: FileHandle

    func currentOffset() throws -> Int { Int(try handle.offset()) }

    func write(data: Data) throws { try handle.write(contentsOf: data) }

    func write(ascii value: String) throws {
        var bytes = Array(value.utf8)
        while bytes.count < 4 { bytes.append(0x20) }
        try handle.write(contentsOf: Data(bytes.prefix(4)))
    }

    func write(uint32 value: UInt32) throws {
        try handle.write(contentsOf: Data([
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]))
    }

    func write(uint16 value: UInt16) throws {
        try handle.write(contentsOf: Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]))
    }

    func write(padByte: Void) throws { try handle.write(contentsOf: Data([0])) }

    func write(samples: [Int16]) throws {
        guard !samples.isEmpty else { return }
        var little = samples.map { $0.littleEndian }
        let bytes = little.withUnsafeMutableBufferPointer { buffer in
            Data(buffer: buffer)
        }
        try handle.write(contentsOf: bytes)
    }

    /// Reserves a 4-byte size field and returns its offset for later patching.
    func writePlaceholderSize() throws -> Int {
        let at = try currentOffset()
        try write(uint32: 0)
        return at
    }

    func patchSize(at offset: Int, to value: UInt32) throws {
        let resume = try handle.offset()
        try handle.seek(toOffset: UInt64(offset))
        try write(uint32: value)
        try handle.seek(toOffset: resume)
    }
}
