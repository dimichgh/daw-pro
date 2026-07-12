import Foundation

// General MIDI program catalog (m10-n). Pure Foundation — DAWCore is the
// dependency-free floor both the wire (`instrument.listSoundBankPrograms`) and
// the picker read from (LAW L9). The table is 0-BASED: program 0 is
// "Acoustic Grand Piano", 56 is "Trumpet". Human GM charts are 1-based; this
// file is the raw MIDI byte throughout (R1 — do not off-by-one it).

/// One addressable program in a sound bank: the SF2/DLS/GM address (0-based
/// MIDI program + bank select MSB/LSB) plus a display name and a grouping
/// category. Shared by `SoundBankLibrary.programs(for:)`, the wire, and the
/// picker.
public struct SoundBankProgram: Codable, Sendable, Equatable, Hashable {
    /// 0-based MIDI program (0…127).
    public var program: Int
    /// Bank select MSB — 121 (0x79) melodic, 120 (0x78) percussion.
    public var bankMSB: Int
    /// Bank select LSB — 0 for GM.
    public var bankLSB: Int
    /// Display name — a GM table name, a parsed SF2 preset name, or a generic
    /// "Program N" fallback.
    public var name: String
    /// Grouping label for the picker — a GM category, "Drum Kits", or "" when
    /// unknown (unparsed SF2/DLS).
    public var category: String

    public init(program: Int, bankMSB: Int, bankLSB: Int, name: String, category: String) {
        self.program = program
        self.bankMSB = bankMSB
        self.bankLSB = bankLSB
        self.name = name
        self.category = category
    }
}

/// The static General MIDI Level 1 program table (0-based) plus the 16
/// canonical categories of 8 and the v1 percussion entry. Both the wire and
/// the picker consume this; it lives in DAWCore because that is the shared,
/// dependency-free floor (NOT DAWAppKit, which DAWControl must never import).
public enum GMProgramCatalog {
    /// Bank select MSB for GM melodic programs (`kAUSampler_DefaultMelodicBankMSB`
    /// = 0x79). Plain Int by LAW L9.
    public static let melodicBankMSB = 121
    /// Bank select MSB for GM percussion kits (`kAUSampler_DefaultPercussionBankMSB`
    /// = 0x78).
    public static let percussionBankMSB = 120
    /// Bank select LSB for GM (`kAUSampler_DefaultBankLSB`).
    public static let bankLSB = 0

    /// The picker group name for percussion kits.
    public static let drumKitCategory = "Drum Kits"

    /// The 16 canonical GM categories, in program order — each spans exactly 8
    /// consecutive programs (0–7 Piano, 8–15 Chromatic Percussion, …).
    public static let categories: [String] = [
        "Piano", "Chromatic Percussion", "Organ", "Guitar",
        "Bass", "Strings", "Ensemble", "Brass",
        "Reed", "Pipe", "Synth Lead", "Synth Pad",
        "Synth Effects", "Ethnic", "Percussive", "Sound Effects",
    ]

    /// The 128 GM Level 1 melodic program names, 0-based (index == MIDI
    /// program byte). `programNames[0] == "Acoustic Grand Piano"`,
    /// `programNames[56] == "Trumpet"`.
    public static let programNames: [String] = [
        // 0–7 Piano
        "Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano",
        "Honky-tonk Piano", "Electric Piano 1", "Electric Piano 2", "Harpsichord",
        "Clavinet",
        // 8–15 Chromatic Percussion
        "Celesta", "Glockenspiel", "Music Box", "Vibraphone", "Marimba",
        "Xylophone", "Tubular Bells", "Dulcimer",
        // 16–23 Organ
        "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ",
        "Reed Organ", "Accordion", "Harmonica", "Tango Accordion",
        // 24–31 Guitar
        "Acoustic Guitar (nylon)", "Acoustic Guitar (steel)", "Electric Guitar (jazz)",
        "Electric Guitar (clean)", "Electric Guitar (muted)", "Overdriven Guitar",
        "Distortion Guitar", "Guitar Harmonics",
        // 32–39 Bass
        "Acoustic Bass", "Electric Bass (finger)", "Electric Bass (pick)",
        "Fretless Bass", "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
        // 40–47 Strings
        "Violin", "Viola", "Cello", "Contrabass", "Tremolo Strings",
        "Pizzicato Strings", "Orchestral Harp", "Timpani",
        // 48–55 Ensemble
        "String Ensemble 1", "String Ensemble 2", "Synth Strings 1", "Synth Strings 2",
        "Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit",
        // 56–63 Brass
        "Trumpet", "Trombone", "Tuba", "Muted Trumpet", "French Horn",
        "Brass Section", "Synth Brass 1", "Synth Brass 2",
        // 64–71 Reed
        "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax", "Oboe",
        "English Horn", "Bassoon", "Clarinet",
        // 72–79 Pipe
        "Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle",
        "Shakuhachi", "Whistle", "Ocarina",
        // 80–87 Synth Lead
        "Lead 1 (square)", "Lead 2 (sawtooth)", "Lead 3 (calliope)", "Lead 4 (chiff)",
        "Lead 5 (charang)", "Lead 6 (voice)", "Lead 7 (fifths)", "Lead 8 (bass + lead)",
        // 88–95 Synth Pad
        "Pad 1 (new age)", "Pad 2 (warm)", "Pad 3 (polysynth)", "Pad 4 (choir)",
        "Pad 5 (bowed)", "Pad 6 (metallic)", "Pad 7 (halo)", "Pad 8 (sweep)",
        // 96–103 Synth Effects
        "FX 1 (rain)", "FX 2 (soundtrack)", "FX 3 (crystal)", "FX 4 (atmosphere)",
        "FX 5 (brightness)", "FX 6 (goblins)", "FX 7 (echoes)", "FX 8 (sci-fi)",
        // 104–111 Ethnic
        "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba", "Bagpipe", "Fiddle",
        "Shanai",
        // 112–119 Percussive
        "Tinkle Bell", "Agogo", "Steel Drums", "Woodblock", "Taiko Drum",
        "Melodic Tom", "Synth Drum", "Reverse Cymbal",
        // 120–127 Sound Effects
        "Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet",
        "Telephone Ring", "Helicopter", "Applause", "Gunshot",
    ]

    /// The v1 percussion entry — one "Standard Drum Kit" at bankMSB 120,
    /// program 0 (§4.4). Individual GM drum-kit variants are out of scope.
    public static let standardDrumKit = SoundBankProgram(
        program: 0, bankMSB: percussionBankMSB, bankLSB: bankLSB,
        name: "Standard Drum Kit", category: drumKitCategory)

    /// The GM category for a 0-based melodic program (`program / 8`), clamped so
    /// an out-of-range program still yields a valid category.
    public static func category(forProgram program: Int) -> String {
        let index = max(0, min(categories.count - 1, program / 8))
        return categories[index]
    }

    /// The GM name for a 0-based melodic program, clamped into 0…127.
    public static func name(forProgram program: Int) -> String {
        let index = max(0, min(programNames.count - 1, program))
        return programNames[index]
    }

    /// The full GM program listing the wire and picker present: the 128
    /// melodic programs (bankMSB 121) with their categories, then the single
    /// v1 percussion entry (bankMSB 120). 129 entries total.
    public static let programs: [SoundBankProgram] =
        programNames.enumerated().map { index, name in
            SoundBankProgram(program: index, bankMSB: melodicBankMSB, bankLSB: bankLSB,
                             name: name, category: category(forProgram: index))
        } + [standardDrumKit]
}
