import Foundation

/// Which on-disk format a sample library was parsed from. Shared by the IR
/// and `SampleLibraryImportReport` (design §5.5's `Format`).
public enum SampleLibraryFormat: String, Codable, Sendable, Equatable {
    case sfz
    case dspreset
}

/// FORMAT-NEUTRAL intermediate representation of a parsed sample library
/// (m19-c, design §5.1): `SFZParser` produces it today; m19-d's
/// `DSPresetParser` targets the SAME shape, so `SampleLibraryMapper` — the
/// single home of the §2.3 degradation policy — never knows which text
/// format it came from.
///
/// Field units are NEUTRAL and documented per field; each PARSER owns the
/// conversion from its format's native units (note names → MIDI ints, the
/// `key` shorthand, dB suffix stripping), the MAPPER owns policy and the
/// model mapping (dB→linear, percent→fraction, group-ID assignment, skips).
/// A `nil` field means "not authored" — the mapper leaves the corresponding
/// model field nil so the Sampler's documented defaults apply.
public struct SampleLibraryIR: Sendable, Equatable {
    public var format: SampleLibraryFormat
    /// The directory sample paths resolve against (the main file's folder).
    public var baseDirectory: URL
    /// Regions in file order (SFZ group contiguity means group members stay
    /// adjacent, so the engine's stable group sort preserves file order).
    public var regions: [Region]
    /// Non-region-scope headers the parser skipped wholesale (`<curve>`,
    /// `<effect>`, …) — header (with angle brackets) → occurrence count. The
    /// mapper folds these into the report's `ignoredOpcodes` so nothing is
    /// dropped silently.
    public var ignoredHeaders: [String: Int]

    public init(format: SampleLibraryFormat, baseDirectory: URL,
                regions: [Region] = [], ignoredHeaders: [String: Int] = [:]) {
        self.format = format
        self.baseDirectory = baseDirectory
        self.regions = regions
        self.ignoredHeaders = ignoredHeaders
    }

    /// One region's EFFECTIVE (post-inheritance) description.
    public struct Region: Sendable, Equatable {
        /// Raw `sample=` value — separators un-normalized, `default_path`
        /// NOT yet prepended (`SampleLibraryPath.resolve` does both).
        public var samplePath: String?
        /// Effective `default_path` (SFZ `<control>` scope), raw.
        public var defaultPath: String?
        /// Ordinal of the `<group>` header this region sits under (0-based,
        /// file order); nil = ungrouped. The MAPPER assigns model group IDs
        /// from this (§5.3) — the parser only records structure.
        public var groupIndex: Int?

        // Selection (MIDI ints; parsers resolve note names).
        public var loKey: Int?
        public var hiKey: Int?
        public var keyCenter: Int?
        public var loVel: Int?
        public var hiVel: Int?
        public var seqLength: Int?
        public var seqPosition: Int?
        public var randLo: Double?
        public var randHi: Double?

        // Playback scalars.
        /// Volume in dB (SFZ `volume`). Mutually exclusive with `gainLinear`.
        public var volumeDB: Double?
        /// Linear gain (m19-d: `.dspreset` linear `volume`). nil for SFZ.
        public var gainLinear: Double?
        /// Pan in the shared −100…+100 authoring range (both formats).
        public var pan: Double?
        /// Fine tune in cents (SFZ `tune`; dspreset `tuning`×100).
        public var tuneCents: Double?
        /// Whole-semitone shift (SFZ `transpose`; nil for `.dspreset`).
        public var transposeSemitones: Int?
        /// Velocity→amplitude depth as a PERCENT (SFZ `amp_veltrack` native).
        public var ampVelTrackPercent: Double?
        /// Playback start offset in source-file frames (SFZ `offset`).
        public var offsetFrames: Int?
        /// INCLUSIVE last sample point (SFZ `end` semantics; −1 = region
        /// disabled). The mapper converts to the model's exclusive endFrame.
        public var endFrame: Int?
        public var attackSeconds: Double?
        public var decaySeconds: Double?
        /// Sustain level as a PERCENT of peak (SFZ `ampeg_sustain` native).
        public var sustainPercent: Double?
        public var releaseSeconds: Double?
        /// Raw loop mode (`no_loop`/`one_shot`/`loop_continuous`/
        /// `loop_sustain`) — parsed so the mapper can honor `one_shot` AND
        /// build real loops (m20-g).
        public var loopMode: String?
        /// Loop start point in source-file frames (SFZ `loop_start`/`loopstart`;
        /// `.dspreset` `loopStart`; `smpl` dwStart). nil = not authored — resolves
        /// to 0 / the smpl point per the §2.3 precedence law.
        public var loopStartFrame: Int?
        /// INCLUSIVE last loop frame (SFZ `loop_end` semantics — "the sample
        /// specified is played as part of the loop"; `smpl` dwEnd, same convention).
        /// The mapper does the +1 to the model's exclusive `loopEnd` — the ONE
        /// shared inclusive→exclusive law (`end` → endFrame + 1).
        public var loopEndFrame: Int?

        // Degradation-policy inputs (§2.3).
        /// Raw `trigger=` value; nil reads as "attack".
        public var trigger: String?
        /// Keyswitch selector (`sw_last`) as a MIDI int, if present.
        public var swLast: Int?
        /// Default keyswitch (`sw_default`) as a MIDI int, if present.
        public var swDefault: Int?
        /// True when any CC-trigger opcode (`on_loccN`/`on_hiccN`) is present.
        public var ccTriggered: Bool
        /// Effective opcodes the parser recognized as PRESENT but out of the
        /// v1 subset (filters, LFOs, EQ, crossfades, `_onccN`, …) — plus any
        /// recognized opcode whose value failed to parse. One entry per name
        /// per region; the mapper tallies across imported regions.
        public var ignored: [String]

        public init(samplePath: String? = nil, defaultPath: String? = nil,
                    groupIndex: Int? = nil,
                    loKey: Int? = nil, hiKey: Int? = nil, keyCenter: Int? = nil,
                    loVel: Int? = nil, hiVel: Int? = nil,
                    seqLength: Int? = nil, seqPosition: Int? = nil,
                    randLo: Double? = nil, randHi: Double? = nil,
                    volumeDB: Double? = nil, gainLinear: Double? = nil,
                    pan: Double? = nil, tuneCents: Double? = nil,
                    transposeSemitones: Int? = nil,
                    ampVelTrackPercent: Double? = nil,
                    offsetFrames: Int? = nil, endFrame: Int? = nil,
                    attackSeconds: Double? = nil, decaySeconds: Double? = nil,
                    sustainPercent: Double? = nil, releaseSeconds: Double? = nil,
                    loopMode: String? = nil,
                    loopStartFrame: Int? = nil, loopEndFrame: Int? = nil,
                    trigger: String? = nil,
                    swLast: Int? = nil, swDefault: Int? = nil,
                    ccTriggered: Bool = false, ignored: [String] = []) {
            self.samplePath = samplePath
            self.defaultPath = defaultPath
            self.groupIndex = groupIndex
            self.loKey = loKey
            self.hiKey = hiKey
            self.keyCenter = keyCenter
            self.loVel = loVel
            self.hiVel = hiVel
            self.seqLength = seqLength
            self.seqPosition = seqPosition
            self.randLo = randLo
            self.randHi = randHi
            self.volumeDB = volumeDB
            self.gainLinear = gainLinear
            self.pan = pan
            self.tuneCents = tuneCents
            self.transposeSemitones = transposeSemitones
            self.ampVelTrackPercent = ampVelTrackPercent
            self.offsetFrames = offsetFrames
            self.endFrame = endFrame
            self.attackSeconds = attackSeconds
            self.decaySeconds = decaySeconds
            self.sustainPercent = sustainPercent
            self.releaseSeconds = releaseSeconds
            self.loopMode = loopMode
            self.loopStartFrame = loopStartFrame
            self.loopEndFrame = loopEndFrame
            self.trigger = trigger
            self.swLast = swLast
            self.swDefault = swDefault
            self.ccTriggered = ccTriggered
            self.ignored = ignored
        }
    }
}
