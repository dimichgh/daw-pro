import Foundation

// m39-tpl-1 — multi-instrument templates, the model
// (docs/design/2026-09-27-multi-instrument-templates.md §4).
//
// A template is a named, versioned SOUND SETUP: a set of new tracks, each with
// its instrument, its insert effects and their settings, its volume and pan,
// where it sends and where it outputs, plus the buses those point at, the
// sidechain keys between them and the modulation on them. It NEVER holds
// notes, audio, tempo, song sections, markers, automation, the master chain or
// colour (§4.9) — the types below cannot even spell them.
//
// ⭐ KEYS, NEVER NAMES. Tracks, inserts and modulation sources refer to each
// other by TEMPLATE-LOCAL keys that must resolve inside the same template. A
// key never matches anything in the song, so the name-matching class of silent
// mismatch cannot arise (§4.4).
//
// Built-in templates, saved `.dawtemplate` files and inline wire templates are
// the SAME JSON, read by ONE codec (`TrackSetTemplateCodec`). Pure value types:
// Foundation only, nonisolated, `Sendable`.

/// A whole template. Decode one with `TrackSetTemplateCodec.decode(_:origin:)`.
public struct TrackSetTemplate: Sendable, Equatable {
    /// The format version this build writes and reads.
    public static let currentFormatVersion = 1

    /// The version of the build that wrote it.
    public var formatVersion: Int
    /// The oldest reader that applies it correctly (§4.7).
    public var minReaderVersion: Int
    /// Built-in: kebab-case (`"lofi-chill"`); saved: `"user-<uuid>"`. Empty for
    /// an inline wire template that carries none.
    public var id: String
    /// 1–40 characters. The undo step is called "Add Template '<name>'".
    public var name: String
    /// One sentence a novice can read, at most 200 characters.
    public var summary: String?
    /// The `SongSkeletonCatalog` genre "Start a song" uses.
    public var songForm: String?
    /// The `SongSkeletonCatalog` genres this template suits.
    public var genres: [String]
    /// 1–24 tracks, in the order they are added.
    public var tracks: [TemplateTrack]

    public init(formatVersion: Int = TrackSetTemplate.currentFormatVersion,
                minReaderVersion: Int = 1, id: String = "", name: String,
                summary: String? = nil, songForm: String? = nil, genres: [String] = [],
                tracks: [TemplateTrack]) {
        self.formatVersion = formatVersion
        self.minReaderVersion = minReaderVersion
        self.id = id
        self.name = name
        self.summary = summary
        self.songForm = songForm
        self.genres = genres
        self.tracks = tracks
    }
}

/// One track a template adds.
public struct TemplateTrack: Sendable, Equatable {
    /// Unique in the template: 1–32 lowercase letters, digits and hyphens.
    public var key: String
    public var name: String
    /// `.instrument`, `.audio` or `.bus`.
    public var kind: TrackKind
    /// `Track.volumeRange`; 1 when the template omits it.
    public var volume: Double
    /// `Track.panRange`; 0 when the template omits it.
    public var pan: Double
    /// RESOLVED, instrument tracks only: an instrument has no identity, so one
    /// resolved value can be applied any number of times.
    public var instrument: InstrumentDescriptor?
    /// A `MixerPresetCatalog` name, built fresh (`freshChain()`) BEFORE `inserts`.
    public var mixerPreset: String?
    public var inserts: [TemplateInsert]
    /// A bus KEY in this template; nil = the master.
    public var output: String?
    public var sends: [TemplateSend]
    /// JSON: `modulation.sources`.
    public var modulationSources: [TemplateModSource]
    /// JSON: `modulation.routes`.
    public var modulationRoutes: [TemplateModRoute]

    public init(key: String, name: String, kind: TrackKind, volume: Double = 1,
                pan: Double = 0, instrument: InstrumentDescriptor? = nil,
                mixerPreset: String? = nil, inserts: [TemplateInsert] = [],
                output: String? = nil, sends: [TemplateSend] = [],
                modulationSources: [TemplateModSource] = [],
                modulationRoutes: [TemplateModRoute] = []) {
        self.key = key
        self.name = name
        self.kind = kind
        self.volume = volume
        self.pan = pan
        self.instrument = instrument
        self.mixerPreset = mixerPreset
        self.inserts = inserts
        self.output = output
        self.sends = sends
        self.modulationSources = modulationSources
        self.modulationRoutes = modulationRoutes
    }
}

/// One insert effect. Stored as a kind plus SPARSE named settings, never as an
/// `EffectDescriptor`: an effect has an identity (`id` is a `let`), so the
/// builder makes each one fresh at apply time with
/// `EffectDescriptor.newlyAdded(kind:)` and the one named writer
/// (`EffectDescriptor.applySetting`), in `EffectParamSpec.specs(for:)` order.
public struct TemplateInsert: Sendable, Equatable {
    /// Needed only when a modulation route targets this insert; unique within
    /// its track.
    public var key: String?
    public var kind: EffectDescriptor.Kind
    public var bypassed: Bool
    /// Sparse; every name is one of `EffectParamSpec.specs(for: kind)`, and
    /// every value reads back as written (§5.3's read-back rule).
    public var params: [String: Double]
    /// A NON-bus track KEY in this template.
    public var sidechainSource: String?
    /// `kind == .audioUnit` only.
    public var audioUnit: AudioUnitConfig?

    public init(key: String? = nil, kind: EffectDescriptor.Kind, bypassed: Bool = false,
                params: [String: Double] = [:], sidechainSource: String? = nil,
                audioUnit: AudioUnitConfig? = nil) {
        self.key = key
        self.kind = kind
        self.bypassed = bypassed
        self.params = params
        self.sidechainSource = sidechainSource
        self.audioUnit = audioUnit
    }
}

/// One post-fader send: all a `Send` is (there is no pre-fader flag).
public struct TemplateSend: Sendable, Equatable {
    /// A bus KEY in this template.
    public var bus: String
    /// `Send.levelRange`; 1 when the template omits it.
    public var level: Double

    public init(bus: String, level: Double = 1) {
        self.bus = bus
        self.level = level
    }
}

/// One modulation source, its settings RESOLVED through
/// `ModulationSourceParams.apply(_:to:)` over the kind's defaults.
public struct TemplateModSource: Sendable, Equatable {
    /// Unique within its track; routes name it.
    public var key: String
    public var kind: ModulationSourceKind
    /// nil = the name `mod.addSource` would give it (`kind.defaultName`).
    public var name: String?
    public var params: ModulationSourceParams

    public init(key: String, kind: ModulationSourceKind, name: String? = nil,
                params: ModulationSourceParams? = nil) {
        self.key = key
        self.kind = kind
        self.name = name
        self.params = params ?? .defaults(for: kind)
    }
}

/// One modulation route on a track.
public struct TemplateModRoute: Sendable, Equatable {
    /// A source KEY on the same track.
    public var source: String
    public var target: TemplateTarget
    /// `ModulationRoute.depthRange`, −1…1.
    public var depth: Double
    public var enabled: Bool

    public init(source: String, target: TemplateTarget, depth: Double, enabled: Bool = true) {
        self.source = source
        self.target = target
        self.depth = depth
        self.enabled = enabled
    }
}

/// Where a route points. `sendLevel` is deliberately NOT a case: modulation
/// refuses it (`sendLevelUnsupported`), so a template cannot even spell it.
public enum TemplateTarget: Sendable, Equatable {
    case volume
    case pan
    case instrumentParam(param: String)
    /// `insert` is an insert KEY on the same track.
    case effectParam(insert: String, param: String)
}

/// A problem the reader or builder worked around, machine-readable (§6.4).
/// Every `message` is a sentence a novice can read.
public struct TemplateWarning: Sendable, Equatable, Codable {
    public enum Code: String, Sendable, Equatable, Codable, CaseIterable {
        // §6.4's codes.
        case unknownKeySkipped
        case unknownEffectSkipped
        case unknownInstrumentSkipped
        case unknownSettingSkipped
        case unknownModulationSkipped
        case valueClamped
        case valueChanged
        case audioUnitMissing
        case audioUnitSlowToLoad
        case busIncluded
        case sidechainDropped
        case modulationTargetWarned
        case duplicateTrackNames
        // Added by TPL-1, each the same rule applied to a name the design's
        // list did not cover: a TRACK kind a newer writer knows (the whole
        // track is skipped, like an unknown instrument kind); a mixer or drum
        // PRESET a newer writer knows; a song GENRE a newer writer knows; and
        // the modulation applier's own notes about a source setting (for
        // example a pulse width on a sine LFO), passed through unchanged.
        case unknownTrackKindSkipped
        case unknownPresetSkipped
        case unknownGenreSkipped
        case modulationSourceWarned
    }

    public var code: Code
    /// Where in the template, e.g. `tracks[2].inserts[0].params.stages`.
    public var path: String
    public var message: String

    public init(code: Code, path: String, message: String) {
        self.code = code
        self.path = path
        self.message = message
    }
}

/// Why a template was refused. Nothing is applied when this is thrown.
public struct TemplateRefusal: Error, LocalizedError, Sendable, Equatable {
    public enum Code: String, Sendable, Equatable, CaseIterable {
        /// The bytes are not JSON (a truncated file lands here).
        case notJSON
        /// JSON, but not a template (`format` wrong or missing, not an object).
        case notATemplate
        /// Over `TrackSetTemplateCodec.maxFileBytes`.
        case tooLarge
        /// `minReaderVersion` is above this build's version.
        case needsNewerVersion
        /// A required key is absent.
        case missingKey
        /// A value of the wrong JSON type (a kind given as a number, `1` for a
        /// switch, a fraction for a whole number).
        case wrongType
        /// A key the format does not have, at any level.
        case unknownKey
        /// An effect, instrument, track or modulation kind, target type, preset
        /// or genre this build does not know.
        case unknownKind
        /// A setting name the kind does not have.
        case unknownSetting
        /// A value outside its range.
        case outOfRange
        /// A value that would not read back as written: it snaps, or a coupled
        /// setting changes it (§5.3).
        case readBack
        /// A value of the right type that is still not usable (an empty name,
        /// a key with capitals, an instrument on a bus).
        case invalidValue
        /// Two tracks, inserts or sources share a key.
        case duplicateKey
        /// A block this build cannot read from a template yet.
        case notSupported
    }

    public var code: Code
    /// Where in the template; empty for the file as a whole.
    public var path: String
    public var message: String

    public init(code: Code, path: String, message: String) {
        self.code = code
        self.path = path
        self.message = message
    }

    public var errorDescription: String? { path.isEmpty ? message : "\(path): \(message)" }
}
