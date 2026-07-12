import Foundation
import Testing
@testable import DAWCore

/// m10-n-2 General MIDI program catalog: 0-based names (the off-by-one trap,
/// R1), the 16 categories of 8, count pins, and the drum-kit group.
@Suite("GM program catalog (m10-n-2)")
struct GMProgramCatalogTests {
    // 1.
    @Test("0-based spot names: Acoustic Grand Piano@0, Trumpet@56, Gunshot@127")
    func spotNames() {
        #expect(GMProgramCatalog.programNames[0] == "Acoustic Grand Piano")
        #expect(GMProgramCatalog.programNames[56] == "Trumpet")
        #expect(GMProgramCatalog.programNames[127] == "Gunshot")
        // The name(forProgram:) accessor agrees and clamps out-of-range.
        #expect(GMProgramCatalog.name(forProgram: 56) == "Trumpet")
        #expect(GMProgramCatalog.name(forProgram: 999) == "Gunshot")
        #expect(GMProgramCatalog.name(forProgram: -5) == "Acoustic Grand Piano")
    }

    // 2.
    @Test("exactly 128 program names, all non-empty and unique")
    func nameCountPin() {
        #expect(GMProgramCatalog.programNames.count == 128)
        #expect(GMProgramCatalog.programNames.allSatisfy { !$0.isEmpty })
        #expect(Set(GMProgramCatalog.programNames).count == 128)  // no duplicates
    }

    // 3.
    @Test("exactly 16 categories of 8, spanning all 128 programs")
    func categoryCountPin() {
        #expect(GMProgramCatalog.categories.count == 16)
        #expect(GMProgramCatalog.categories.count * 8 == 128)
        #expect(GMProgramCatalog.categories.first == "Piano")
        #expect(GMProgramCatalog.categories.last == "Sound Effects")
    }

    // 4.
    @Test("category math: program / 8 maps to its category, with spot checks")
    func categoryMath() {
        #expect(GMProgramCatalog.category(forProgram: 0) == "Piano")           // 0–7
        #expect(GMProgramCatalog.category(forProgram: 7) == "Piano")
        #expect(GMProgramCatalog.category(forProgram: 8) == "Chromatic Percussion")  // 8–15
        #expect(GMProgramCatalog.category(forProgram: 56) == "Brass")          // 56–63
        #expect(GMProgramCatalog.category(forProgram: 127) == "Sound Effects") // 120–127
        // Every program's category is its (program/8) slice.
        for program in 0...127 {
            #expect(GMProgramCatalog.category(forProgram: program)
                    == GMProgramCatalog.categories[program / 8])
        }
        // Out-of-range clamps.
        #expect(GMProgramCatalog.category(forProgram: 999) == "Sound Effects")
        #expect(GMProgramCatalog.category(forProgram: -1) == "Piano")
    }

    // 5.
    @Test("programs listing: 129 entries — 128 melodic (bankMSB 121) + Standard Drum Kit (120)")
    func programsListing() {
        let programs = GMProgramCatalog.programs
        #expect(programs.count == 129)

        // The 128 melodic programs address bankMSB 121, LSB 0, and carry names.
        let melodic = programs.prefix(128)
        #expect(melodic.allSatisfy { $0.bankMSB == 121 && $0.bankLSB == 0 })
        #expect(melodic.enumerated().allSatisfy { $0.offset == $0.element.program })
        let trumpet = programs.first { $0.program == 56 && $0.bankMSB == 121 }
        #expect(trumpet?.name == "Trumpet")
        #expect(trumpet?.category == "Brass")

        // The single v1 percussion entry sits LAST at bankMSB 120, program 0.
        let drum = programs.last
        #expect(drum?.name == "Standard Drum Kit")
        #expect(drum?.bankMSB == 120)
        #expect(drum?.bankLSB == 0)
        #expect(drum?.program == 0)
        #expect(drum?.category == "Drum Kits")
    }

    // 6.
    @Test("bank-select MSB constants match the AUSampler GM conventions")
    func bankConstants() {
        #expect(GMProgramCatalog.melodicBankMSB == 121)     // 0x79
        #expect(GMProgramCatalog.percussionBankMSB == 120)  // 0x78
        #expect(GMProgramCatalog.bankLSB == 0)
    }
}
