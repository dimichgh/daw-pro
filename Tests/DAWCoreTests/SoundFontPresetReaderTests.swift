import Foundation
import Testing
@testable import DAWCore

/// m10-n-2 SF2 phdr parser + the SoundBankLibrary wBank→MSB/LSB mapping. No
/// binary fixtures exist on this machine (§2.3), so every test SYNTHESIZES a
/// minimal valid `.sf2` byte stream programmatically: a RIFF `sfbk` container
/// holding a `LIST pdta` with a single `phdr` chunk of 38-byte records
/// (achPresetName[20] + wPreset + wBank + …), terminated by the spec's EOP
/// record. Malformed/truncated inputs must yield [] (or the generic fallback),
/// never a crash.
@Suite("SoundFont preset reader (m10-n-2)")
struct SoundFontPresetReaderTests {
    // MARK: - Byte-level fixture synthesis

    private func u16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private func u32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private func fourCC(_ tag: String) -> [UInt8] {
        precondition(tag.utf8.count == 4)
        return Array(tag.utf8)
    }

    /// A 20-byte, null-padded `achPresetName`.
    private func nameField(_ name: String) -> [UInt8] {
        var field = Array(name.utf8.prefix(20))
        while field.count < 20 { field.append(0) }
        return field
    }

    /// One 38-byte phdr record.
    private func phdrRecord(name: String, preset: Int, bank: Int) -> [UInt8] {
        var record = nameField(name)   // achPresetName[20]
        record += u16(preset)          // wPreset
        record += u16(bank)            // wBank
        record += u16(0)               // wPresetBagNdx
        record += u32(0)               // dwLibrary
        record += u32(0)               // dwGenre
        record += u32(0)               // dwMorphology
        precondition(record.count == 38)
        return record
    }

    /// Wraps a fourCC + payload in a RIFF chunk (`id | size | data`).
    private func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
        fourCC(id) + u32(payload.count) + payload
    }

    /// A complete minimal `.sf2` (RIFF sfbk → LIST pdta → phdr), including the
    /// terminal EOP record.
    private func makeSF2(_ presets: [(name: String, preset: Int, bank: Int)]) -> Data {
        var records: [UInt8] = []
        for preset in presets {
            records += phdrRecord(name: preset.name, preset: preset.preset, bank: preset.bank)
        }
        records += phdrRecord(name: "EOP", preset: 0, bank: 0)  // terminal sentinel

        let phdr = chunk("phdr", records)
        let pdta = fourCC("pdta") + phdr           // LIST body: form type + subchunks
        let list = chunk("LIST", pdta)
        let sfbk = fourCC("sfbk") + list           // RIFF body: form type + chunks
        return Data(chunk("RIFF", sfbk))
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf2-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Parser

    // 1.
    @Test("a 2-preset file parses names + raw bank/preset numbers; the EOP record is dropped")
    func parsesNamesAndNumbers() {
        let data = makeSF2([("Grand Piano", 0, 0), ("Jazz Kit", 0, 128)])
        let presets = SoundFontPresetReader.presets(from: data)
        #expect(presets.count == 2)  // EOP dropped
        #expect(presets[0] == .init(name: "Grand Piano", wBank: 0, wPreset: 0))
        #expect(presets[1] == .init(name: "Jazz Kit", wBank: 128, wPreset: 0))
    }

    // 2.
    @Test("wBank→MSB/LSB mapping: 128 → percussion (120), else melodic (121) LSB=wBank")
    func bankMapping() {
        let data = makeSF2([
            ("Piano", 0, 0),      // melodic bank 0
            ("Choir", 52, 2),     // melodic bank 2 → LSB 2
            ("Drums", 0, 128),    // percussion
        ])
        let programs = SoundFontPresetReader.presets(from: data)
            .map(SoundBankLibrary.program(from:))

        #expect(programs[0].program == 0)
        #expect(programs[0].bankMSB == 121 && programs[0].bankLSB == 0)
        #expect(programs[0].category == "")

        #expect(programs[1].program == 52)
        #expect(programs[1].bankMSB == 121 && programs[1].bankLSB == 2)  // LSB = wBank

        #expect(programs[2].program == 0)
        #expect(programs[2].bankMSB == 120 && programs[2].bankLSB == 0)  // percussion
        #expect(programs[2].category == "Drum Kits")
    }

    // 3.
    @Test("malformed inputs never crash: non-RIFF, empty, and a header-only file all yield []")
    func malformedYieldsEmpty() {
        #expect(SoundFontPresetReader.presets(from: Data("not a soundfont".utf8)).isEmpty)
        #expect(SoundFontPresetReader.presets(from: Data()).isEmpty)
        // A truncated phdr (only the EOP record, or fewer than a full record).
        #expect(SoundFontPresetReader.presets(from: makeSF2([])).isEmpty)
        // RIFF header claiming a huge size but with no body.
        var lying = fourCC("RIFF") + u32(0xFFFF) + fourCC("sfbk")
        lying += fourCC("LIST") + u32(0xFFFF)  // truncated list
        #expect(SoundFontPresetReader.presets(from: Data(lying)).isEmpty)
    }

    // MARK: - SoundBankLibrary.programs(for:) integration

    // 4.
    @Test("library.programs parses a real on-disk .sf2 with namesParsed:true")
    func libraryParsesOnDiskSF2() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("Vintage.sf2")
        try makeSF2([("EP Rhodes", 4, 0), ("808 Kit", 0, 128)]).write(to: url)

        let library = SoundBankLibrary()
        let (programs, namesParsed) = try library.programs(for: .file(path: url.path))
        #expect(namesParsed)
        #expect(programs.count == 2)
        #expect(programs[0].name == "EP Rhodes")
        #expect(programs[0].program == 4)
        #expect(programs[1].name == "808 Kit")
        #expect(programs[1].bankMSB == 120)  // percussion mapping
    }

    // 5.
    @Test("library.programs falls back to generic 0…127 (namesParsed:false) for a truncated .sf2")
    func libraryFallsBackOnTruncatedSF2() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("Broken.sf2")
        try Data("RIFFxxxxsfbk-truncated".utf8).write(to: url)

        let library = SoundBankLibrary()
        let (programs, namesParsed) = try library.programs(for: .file(path: url.path))
        #expect(!namesParsed)  // honest: never errors for a file AUSampler might load
        #expect(programs.count == 128)
        #expect(programs.first?.name == "Program 0")
        #expect(programs.allSatisfy { $0.bankMSB == 121 && $0.bankLSB == 0 })
    }

    // 6.
    @Test("library.programs falls back to generic for a non-SF2 (.dls) bank")
    func libraryGenericForDLS() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("kit.dls")
        try Data("not a real dls".utf8).write(to: url)

        let library = SoundBankLibrary()
        let (programs, namesParsed) = try library.programs(for: .file(path: url.path))
        #expect(!namesParsed)
        #expect(programs.count == 128)
    }

    // 7.
    @Test("library.programs(gm) returns the full 129-entry GM listing, namesParsed:true")
    func libraryGMPrograms() throws {
        let library = SoundBankLibrary()
        let (programs, namesParsed) = try library.programs(for: .generalMIDI)
        #expect(namesParsed)
        #expect(programs.count == 129)
        #expect(programs.first?.name == "Acoustic Grand Piano")
        #expect(programs.last?.name == "Standard Drum Kit")
    }
}
