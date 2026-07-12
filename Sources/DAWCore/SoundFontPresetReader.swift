import Foundation

// SoundFont2 (.sf2) preset-name reader (m10-n §4.5). Pure Foundation Data
// parsing — DAWCore never imports AudioToolbox (LAW L9). A minimal RIFF walk
// pulls the `phdr` (preset header) chunk out of the `pdta` list; every read is
// bounds-checked, so a malformed/truncated/absent file returns [] instead of
// crashing. The caller (`SoundBankLibrary.programs(for:)`) falls back to the
// generic 0…127 list when this yields nothing — listing NEVER errors for a
// file AUSampler might still load.
//
// The reader only cares about NAMES. The load path is format-agnostic
// (`kInstrumentType_SF2Preset == kInstrumentType_DLSPreset`, R5) and lives in
// DAWEngine; nothing here touches AUSampler.
public enum SoundFontPresetReader {
    /// One parsed preset header record: its name plus the raw SF2 bank/preset
    /// numbers. Mapping to AUSampler MSB/LSB addressing is the library's job
    /// (§4.5, R11) — this stays a faithful readout of the bytes.
    public struct Preset: Equatable, Sendable {
        /// `achPresetName` — the 20-byte, null-terminated preset name.
        public let name: String
        /// `wBank` — raw u16. 128 conventionally means percussion (→ MSB 120).
        public let wBank: Int
        /// `wPreset` — raw u16, the MIDI program number.
        public let wPreset: Int

        public init(name: String, wBank: Int, wPreset: Int) {
            self.name = name
            self.wBank = wBank
            self.wPreset = wPreset
        }
    }

    /// Each phdr record is a fixed 38 bytes: achPresetName[20] + wPreset(u16) +
    /// wBank(u16) + wPresetBagNdx(u16) + dwLibrary(u32) + dwGenre(u32) +
    /// dwMorphology(u32).
    private static let recordSize = 38

    /// Parses the presets from an .sf2 file on disk. Absent/unreadable/malformed
    /// → [] (the caller falls back to generic names). KB-scale whole-file read
    /// is acceptable v1 (§4.5); this is control-plane work only.
    public static func presets(at url: URL) -> [Preset] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return presets(from: data)
    }

    /// Parses the presets from in-memory .sf2 bytes (the test-fixture entry —
    /// §9 n-2 synthesizes minimal RIFF bytes; no binary fixtures exist).
    public static func presets(from data: Data) -> [Preset] {
        let bytes = [UInt8](data)
        guard let phdr = findPHDR(in: bytes) else { return [] }
        return parsePHDR(phdr)
    }

    // MARK: - RIFF walk

    /// Walks `RIFF…sfbk` → the `LIST…pdta` chunk → its `phdr` sub-chunk,
    /// returning the phdr record bytes. Returns nil on any structural mismatch
    /// or bounds violation — never traps.
    private static func findPHDR(in bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 12,
              fourCC(bytes, 0) == "RIFF",
              fourCC(bytes, 8) == "sfbk" else { return nil }
        // Top-level chunks start after "RIFF" + size(4) + "sfbk".
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = fourCC(bytes, offset)
            let size = Int(u32LE(bytes, offset + 4))
            let contentStart = offset + 8
            guard size >= 0, contentStart + size <= bytes.count else { break }
            if id == "LIST", size >= 4, fourCC(bytes, contentStart) == "pdta" {
                if let phdr = findPHDRSubchunk(in: bytes,
                                               from: contentStart + 4,
                                               listEnd: contentStart + size) {
                    return phdr
                }
            }
            // RIFF chunks are word-aligned: an odd size carries one pad byte.
            offset = contentStart + size + (size & 1)
        }
        return nil
    }

    /// Walks the `pdta` list's sub-chunks for `phdr`.
    private static func findPHDRSubchunk(in bytes: [UInt8], from start: Int,
                                         listEnd: Int) -> [UInt8]? {
        var sub = start
        while sub + 8 <= listEnd {
            let subID = fourCC(bytes, sub)
            let subSize = Int(u32LE(bytes, sub + 4))
            let subContentStart = sub + 8
            guard subSize >= 0, subContentStart + subSize <= listEnd else { break }
            if subID == "phdr" {
                return Array(bytes[subContentStart ..< subContentStart + subSize])
            }
            sub = subContentStart + subSize + (subSize & 1)
        }
        return nil
    }

    /// Splits the phdr bytes into fixed 38-byte records, dropping the terminal
    /// "EOP" sentinel record (SF2 spec). Fewer than 2 records ⇒ [] (only the
    /// sentinel, or a truncated chunk).
    private static func parsePHDR(_ phdr: [UInt8]) -> [Preset] {
        let count = phdr.count / recordSize
        guard count >= 2 else { return [] }
        var presets: [Preset] = []
        presets.reserveCapacity(count - 1)
        // Drop the last record — the terminal EOP marker.
        for i in 0 ..< (count - 1) {
            let base = i * recordSize
            let name = decodeName(Array(phdr[base ..< base + 20]))
            let wPreset = Int(u16LE(phdr, base + 20))
            let wBank = Int(u16LE(phdr, base + 22))
            presets.append(Preset(name: name, wBank: wBank, wPreset: wPreset))
        }
        return presets
    }

    // MARK: - Byte helpers (bounds-checked)

    private static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return String(decoding: bytes[offset ..< offset + 4], as: UTF8.self)
    }

    private static func u32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func u16LE(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    /// Decodes a fixed-width, null-terminated `achPresetName` field, trimming
    /// trailing whitespace.
    private static func decodeName(_ bytes: [UInt8]) -> String {
        let terminated = Array(bytes.prefix { $0 != 0 })
        return String(decoding: terminated, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }
}
