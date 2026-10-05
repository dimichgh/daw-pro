import Foundation

// m39-dm — THE DRUM MACHINE'S MODEL, AND THE ONE HOME FOR ITS 75 NAMES.
//
// ⚠️⚠️ NAME-ADDRESSED, NEVER POSITIONAL. `InstrumentParams.swift:18-24` forbids
// positional addressing for instrument parameters in those words, and a drum
// machine is the first thing that tempts someone to break it: a
// `pads: [DrumVoiceParams]` array IS an index. So the voices are STRUCT FIELDS
// WITH NAMES (`kick`, `snare`, …) and every parameter is addressed by a dotted
// `<scope>.<param>` string end to end. These rows may be reordered freely.
//
// ⭐ THE TABLE AT `DrumKitParams.paramSpecs` IS THE SINGLE SOURCE OF TRUTH for:
//   · `InstrumentParamSpec.specs(for: .drumSynth)` — the modulation/describe schema
//   · `value(forParamName:)` / `setValue(_:forParamName:)` — the wire setter
//   · `InstrumentParamSpec.currentValue(of:in:)` — the modulation base value
//   · Codable — encode AND decode are driven off it (see `init(from:)`)
//   · the render-side packed `code`
// Five consumers, one list. The `.dynamicEQ` precedent (`ProjectStore.swift`'s
// `params.setValue(value, forParamName:)`) rather than five hand-copied switches.
//
// ⛔ DECODE CONTRACT, AND IT IS THE HALF A BYTE GATE CANNOT SEE.
// `init(from:)` starts from `DrumKitParams()` — every voice already at ITS OWN
// defaults — and then overwrites ONLY the keys the JSON actually carries. So a
// project saved before a parameter existed decodes to that parameter's default,
// which is by construction the old behaviour. This is structural, not a
// hand-maintained list of `decodeIfPresent ?? default` lines that a 76th
// parameter could be left out of.
//
// ⛔⛔ `chokeGroup` IS THE ONE FIELD THAT DOES **NOT** FALL BACK, AND THE
// ASYMMETRY IS DELIBERATE. The hats default to group 0, so a user who
// deliberately CLEARS the hat choke stores nil; `encodeIfPresent` then omits
// the key; and a fallback-to-default decode would silently restore the choke on
// reopen — the user's edit undone by the loader, with no error. Omitted
// `chokeGroup` therefore decodes to **nil, full stop**, and
// `DrumKitTests.clearedChokeGroupSurvivesAReopen` pins it with a JSON fixture
// that OMITS THE KEY. An initialiser default cannot pin that; only a fixture can.
//
// m39-tpl-0 — WHICH NOTE PLAYS WHICH DRUM is the kit's `noteLayout` (`pads`, the
// default, or `gm`, the General MIDI drum map): a STRUCTURAL setting stored
// inside the kit so it rides every path the kit already travels, including the
// render instance's own copy. ONE HOME for the map: `DrumVoice.voice(forNote:
// layout:)`. `docs/design/2026-09-27-multi-instrument-templates.md` §3.

/// WHICH MIDI NOTE PLAYS WHICH DRUM (m39-tpl-0).
///
/// `pads` is the drum machine's own order: notes 36–43 play kick, snare,
/// closed hat, open hat, clap, tom, rim and cymbal, one note each — the
/// pad-grid base. `gm` is the General MIDI drum map, the layout every
/// AI-written beat, imported MIDI file and step-sequenced drum clip speaks.
/// On a `pads` kit a General MIDI beat plays the WRONG drums: GM 38 (snare) is
/// our closed hat, GM 42 (closed hat) our rim, and GM 46/49/51 play nothing.
///
/// ⛔ STRUCTURAL, NOT A SOUND PARAMETER — the `chokeGroup` precedent. It is not
/// one of the 75 names, so `instrument.setDrumParam` and modulation both refuse
/// it, and a PRESET NEVER CHANGES IT (`DrumKitParams.applyingPreset(_:)`).
public enum DrumNoteLayout: String, Sendable, Equatable, Codable, CaseIterable {
    /// Notes 36–43 in voice order. What every kit saved before this setting
    /// existed decodes to, bit for bit.
    case pads
    /// The General MIDI Level 1 drum map (`DrumVoice.voice(forNote:layout:)`).
    case gm

    /// The General MIDI Level 1 percussion keys: 35 (Acoustic Bass Drum) to 81
    /// (Open Triangle). Computed, not a `static let`, so it is never a lazily
    /// initialised global.
    public static var generalMIDIPercussionNotes: ClosedRange<UInt8> { 35...81 }

    /// The General MIDI drum notes that play NOTHING in this layout, ascending.
    /// DERIVED from `DrumVoice.voice(forNote:layout:)`, never a second table.
    /// Builds an array: never call it on the render thread.
    public var silentGMNotes: [UInt8] {
        Self.generalMIDIPercussionNotes.filter { DrumVoice.voice(forNote: $0, layout: self) == nil }
    }

    /// One beginner-readable sentence, for `instrument.describeDrumKit`. It
    /// states the honest limits rather than leaving them to be discovered.
    public var summary: String {
        switch self {
        case .pads:
            return "Pad order: notes 36 to 43 play kick, snare, closed hat, open hat, clap, "
                + "tom, rim and cymbal, one note each. A beat written for General MIDI plays "
                + "the wrong drums in this layout."
        case .gm:
            return "General MIDI drum notes, so a beat written for General MIDI plays the "
                + "right drums. All six tom notes play the one tom at one tuning, crashes and "
                + "rides share the one cymbal, and the other General MIDI drum notes "
                + "(tambourine, cowbell, congas and the rest) play nothing."
        }
    }
}

/// The eight fixed, named, monophonic one-shot voices. An enum of NAMES, not an
/// index into anything — `rawValue` is the dotted scope and is persisted inside
/// parameter names, so these cases are append-only *as spellings* even though
/// the spec rows they generate are freely reorderable.
public enum DrumVoice: String, Sendable, Equatable, Codable, CaseIterable {
    case kick, snare, closedHat, openHat, clap, tom, rim, cymbal

    /// The render-side voice slot. Stable, and packed into the modulation
    /// `code` — wire-local, never persisted (`InstrumentParams.swift:69-72`).
    public var slot: Int32 {
        switch self {
        case .kick: return 0
        case .snare: return 1
        case .closedHat: return 2
        case .openHat: return 3
        case .clap: return 4
        case .tom: return 5
        case .rim: return 6
        case .cymbal: return 7
        }
    }

    /// Beginner-readable label (`docs/DESIGN-LANGUAGE.md`: labels a novice reads).
    public var displayName: String {
        switch self {
        case .kick: return "Kick"
        case .snare: return "Snare"
        case .closedHat: return "Closed Hat"
        case .openHat: return "Open Hat"
        case .clap: return "Clap"
        case .tom: return "Tom"
        case .rim: return "Rim"
        case .cymbal: return "Cymbal"
        }
    }

    /// The MIDI note that triggers this voice in the `pads` layout. 36–43, the
    /// MPC/Ableton Drum Rack base (`PadGridGeometry.swift` lays C1 = 36 at the
    /// bottom-left square), so the kit maps one-to-one onto the existing 4×4 pad
    /// grid when wave item (4) extends it. GM percussion scatters these eight
    /// across 35–59, which is why it is the OTHER layout (`gm`) rather than
    /// this one. In `gm` a voice answers several notes: `notes(in:)`.
    public var note: UInt8 { UInt8(36 + Int(slot)) }

    /// The voice a MIDI note triggers in the `pads` layout, or nil outside
    /// 36…43. Kept for its callers; it IS `voice(forNote:layout: .pads)`.
    public static func voice(forNote note: UInt8) -> DrumVoice? {
        voice(forNote: note, layout: .pads)
    }

    /// ⭐ THE ONE HOME for which note plays which drum, in both layouts. The
    /// describe verb's `voiceNotes` and `silentGMNotes`, `notes(in:)` and the
    /// render all read THIS, so none of them can disagree with what plays.
    ///
    /// ⛔ RENDER THREAD. `DrumSynthInstrument.handle` calls this at every
    /// note-on, so it stays a plain `switch` of integer and enum comparisons:
    /// no `static let` table, dictionary or array (a lazily initialised global
    /// is allocated, behind `swift_once`, on its FIRST touch — which could be
    /// the render thread), and no `allCases` scan. F-4, measured 2026-09-27
    /// (`DrumNoteLayoutRenderTests`): the `allCases.first` scan this replaced
    /// raised 20 malloc events a call in the debug test build; the shipped
    /// release build had folded it into loads from a constant table. A
    /// `switch` has no such dependence on the optimiser.
    ///
    /// The `gm` column is the design's table (§3.3), GM names in the comments.
    public static func voice(forNote note: UInt8, layout: DrumNoteLayout) -> DrumVoice? {
        switch layout {
        case .pads:
            switch note {
            case 36: return .kick
            case 37: return .snare
            case 38: return .closedHat
            case 39: return .openHat
            case 40: return .clap
            case 41: return .tom
            case 42: return .rim
            case 43: return .cymbal
            default: return nil
            }
        case .gm:
            switch note {
            case 35, 36: return .kick                        // Acoustic Bass Drum, Bass Drum 1
            case 37: return .rim                             // Side Stick
            case 38, 40: return .snare                       // Acoustic Snare, Electric Snare
            case 39: return .clap                            // Hand Clap
            case 42, 44: return .closedHat                   // Closed Hi-Hat, Pedal Hi-Hat
            case 46: return .openHat                         // Open Hi-Hat
            case 41, 43, 45, 47, 48, 50: return .tom         // the six toms, one voice
            case 49, 51, 52, 53, 55, 57, 59: return .cymbal  // crashes, rides, China, bell, splash
            default: return nil
            }
        }
    }

    /// Every note that plays this voice in `layout`, ascending. DERIVED by
    /// asking `voice(forNote:layout:)` about all 128 notes, so it cannot
    /// disagree with the render. Builds an array: never on the render thread.
    public func notes(in layout: DrumNoteLayout) -> [UInt8] {
        (UInt8(0)...UInt8(127)).filter { Self.voice(forNote: $0, layout: layout) == self }
    }
}

/// The leaf half of a dotted parameter name. Its `slot` is packed into the
/// render `code` beside the voice slot; like `DrumVoice.slot` it is wire-local.
public enum DrumLeafParam: String, Sendable, Equatable, Codable, CaseIterable {
    // The core eight, present on every voice.
    case tune, decay, tone, snap, drive, level, pan, velocity
    // Per-voice extras.
    case pitchAmount, pitchDecay, partial2Ratio, noiseTone, spread, band
    // Kit-scope.
    case gain, velocityToTone, accentThreshold, accentDepth

    public var slot: Int32 {
        switch self {
        case .tune: return 0
        case .decay: return 1
        case .tone: return 2
        case .snap: return 3
        case .drive: return 4
        case .level: return 5
        case .pan: return 6
        case .velocity: return 7
        case .pitchAmount: return 8
        case .pitchDecay: return 9
        case .partial2Ratio: return 10
        case .noiseTone: return 11
        case .spread: return 12
        case .band: return 13
        case .gain: return 14
        case .velocityToTone: return 15
        case .accentThreshold: return 16
        case .accentDepth: return 17
        }
    }
}

/// One drum voice's continuous parameters.
///
/// ⚠️ **Every voice carries every field, but only the fields the SPEC TABLE
/// lists for that voice are addressable, persisted or rendered.** A `band` on
/// the kick is unreachable by name (`setValue` refuses it), never encoded
/// (Codable is table-driven) and never read by the kick's synthesis. The
/// uniform struct exists so the ONE HOME table can be a flat list of
/// `WritableKeyPath<DrumKitParams, Double>` rather than eight heterogeneous
/// ones; `DrumKitTests.onlyTableNamesAreAddressable` pins that the inert fields
/// stay unreachable.
public struct DrumVoiceParams: Sendable, Equatable {
    // Core eight.
    public var tune: Double
    public var decay: Double
    public var tone: Double
    public var snap: Double
    public var drive: Double
    public var level: Double
    public var pan: Double
    public var velocity: Double
    // Extras (see the note above — meaningful only on the voices whose spec
    // rows list them).
    public var pitchAmount: Double
    public var pitchDecay: Double
    public var partial2Ratio: Double
    public var noiseTone: Double
    public var spread: Double
    public var band: Double

    /// Mutual-cut group, 0…63, or nil for "chokes nothing and is choked by
    /// nothing". STRUCTURAL, not continuous — deliberately NOT one of the 75
    /// modulation names, because exposing it would give this instrument its
    /// only discrete parameter. Clamped through `SamplerZone.chokeGroupRange`
    /// so the sampler and the drum machine can never disagree about what 63
    /// means — ONE HOME for the number, and the only thing the two share.
    public var chokeGroup: Int?

    public init(tune: Double = 100, decay: Double = 0.3, tone: Double = 0.5,
                snap: Double = 0.5, drive: Double = 0, level: Double = 0.8,
                pan: Double = 0, velocity: Double = 0.7,
                pitchAmount: Double = 0, pitchDecay: Double = 0.03,
                partial2Ratio: Double = 1.83, noiseTone: Double = 2200,
                spread: Double = 0.011, band: Double = 3440,
                chokeGroup: Int? = nil) {
        self.tune = tune
        self.decay = decay
        self.tone = tone
        self.snap = snap
        self.drive = drive
        self.level = level
        self.pan = pan
        self.velocity = velocity
        self.pitchAmount = pitchAmount
        self.pitchDecay = pitchDecay
        self.partial2Ratio = partial2Ratio
        self.noiseTone = noiseTone
        self.spread = spread
        self.band = band
        self.chokeGroup = chokeGroup.map { $0.clamped(to: SamplerZone.chokeGroupRange) }
    }

    /// The choke group resolved to a shift-safe Int8 in −1…63, exactly as
    /// `SamplerInstrument` resolves its own at load: `1 << chokeGroup` must
    /// never shift out of range on the render thread, and −1 means "no group".
    public var resolvedChokeGroup: Int8 {
        guard let chokeGroup else { return -1 }
        return Int8(min(max(chokeGroup, 0), 63))
    }
}

/// One addressable drum parameter: its dotted name, where it lives, what it
/// means, and its render-side code.
///
/// ⚠️ `@unchecked Sendable`, and the reason is narrow enough to state exactly.
/// `WritableKeyPath` is not `Sendable` under Swift 6 strict concurrency — in
/// general a key path can capture arbitrary non-Sendable values through a
/// subscript index. THESE key paths capture nothing: every one is a chain of
/// stored-property accesses on `DrumKitParams`/`DrumVoiceParams`, both of which
/// are frozen-shape `Sendable` value types with no subscript components. The
/// table is a `let`, built once, never mutated. So the object graph shared
/// across isolation domains is immutable and value-typed.
///
/// ⛔ THE ONE THING THAT WOULD MAKE THIS UNSOUND: adding a key path with a
/// SUBSCRIPT component (`\.voices[3].tune`). That is also precisely the
/// positional addressing the file header forbids, so the two rules guard each
/// other — but if this struct ever gains a non-key-path reference field, this
/// conformance must be re-argued rather than inherited.
public struct DrumParamSpec: @unchecked Sendable {
    /// The dotted `<scope>.<param>` name — the whole string, never split on the
    /// render thread.
    public let name: String
    /// nil for the four `kit.*` parameters.
    public let voice: DrumVoice?
    public let leaf: DrumLeafParam
    public let keyPath: WritableKeyPath<DrumKitParams, Double>
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    public let unit: String
    public let curve: ParamCurve
    public let note: String?
    /// Whether the value is latched when a note starts. True for everything
    /// except `level` and `pan`, which are the voice's OUTPUT stage and move
    /// continuously on a sounding voice.
    public let appliesAtNextNoteOn: Bool

    /// Packed render-side identity: `0x1000 | (voiceSlot << 8) | leafSlot`,
    /// with the `kit` scope at voice slot 8.
    ///
    /// ⚠️ The `0x1000` bias is not decoration. Without it the kick's `tune`
    /// would carry code 0, which is ALSO `InstrumentParamID.cutoffHz.code`. A
    /// strip has exactly one instrument so the two can never appear in one
    /// snapshot — but a lookup that is only correct because of an invariant
    /// elsewhere is the shape this tree keeps getting bitten by, so the codes
    /// are made disjoint outright. Wire-local; nothing on disk ever sees it.
    public var code: Int32 { 0x1000 | ((voice?.slot ?? 8) << 8) | leaf.slot }
}

/// The synthesised drum kit: eight named voices plus four kit-wide parameters.
public struct DrumKitParams: Sendable, Equatable {
    public var kick: DrumVoiceParams
    public var snare: DrumVoiceParams
    public var closedHat: DrumVoiceParams
    public var openHat: DrumVoiceParams
    public var clap: DrumVoiceParams
    public var tom: DrumVoiceParams
    public var rim: DrumVoiceParams
    public var cymbal: DrumVoiceParams

    /// Kit output gain, applied after every voice sums.
    public var gain: Double
    /// How much of a voice's `velocity` response is TIMBRE rather than level.
    /// A real drum struck harder is brighter, not merely louder; amplitude
    /// alone is what makes a programmed kit "tick".
    public var velocityToTone: Double
    /// MIDI velocity at or above which a hit is ACCENTED (the 808's accent is a
    /// step property, not a continuous dynamic).
    public var accentThreshold: Double
    /// Extra level (and half-share of tone shift) an accented hit receives.
    public var accentDepth: Double

    /// m39-tpl-0 — the note layout. ⛔ STORED AS AN OPTIONAL, nil meaning
    /// `.pads`, and NEVER stored as `.pads`: the setter of `noteLayout` writes
    /// nil for it. Both halves are load-bearing:
    ///   · SAVED BYTES. `encode` writes the key only when this is non-nil, so
    ///     every kit saved before the layout existed, and every kit left at
    ///     `pads`, saves exactly the bytes it saved before.
    ///   · EQUALITY. Synthesised `==` compares this storage, so an explicit
    ///     `.pads` and an absent layout are the same kit (they render the
    ///     same), while a `.gm` kit differs from its `.pads` twin. That is what
    ///     makes `DrumSynthInstrument.apply(params:)`'s `!=` dedupe PUBLISH a
    ///     layout-only change instead of swallowing it.
    private var noteLayoutStorage: DrumNoteLayout?

    /// Which MIDI note plays which voice (`DrumVoice.voice(forNote:layout:)`).
    /// Read on the render thread at note-on from the render's own copy of the
    /// kit: a plain optional check, no allocation.
    public var noteLayout: DrumNoteLayout {
        get {
            guard let stored = noteLayoutStorage else { return .pads }
            return stored
        }
        set { noteLayoutStorage = newValue == .pads ? nil : newValue }
    }

    /// The wire and file key. ONE spelling, shared with `parseDrumKit`.
    public static var noteLayoutKey: String { "noteLayout" }

    // MARK: - Ranges (ONE HOME; the wire, the UI and the spec table clamp here)

    public static let toneRange: ClosedRange<Double> = 0...1
    public static let snapRange: ClosedRange<Double> = 0...1
    public static let driveRange: ClosedRange<Double> = 0...1
    public static let levelRange: ClosedRange<Double> = 0...1
    public static let panRange: ClosedRange<Double> = -1...1
    public static let velocityRange: ClosedRange<Double> = 0...1

    public static let kickTuneRange: ClosedRange<Double> = 20...200
    public static let kickDecayRange: ClosedRange<Double> = 0.05...3.0
    public static let kickPitchAmountRange: ClosedRange<Double> = 0...12
    public static let kickPitchDecayRange: ClosedRange<Double> = 0.002...0.3

    public static let snareTuneRange: ClosedRange<Double> = 80...600
    public static let snareDecayRange: ClosedRange<Double> = 0.03...1.0
    public static let snarePartial2RatioRange: ClosedRange<Double> = 1.05...4.0
    public static let snareNoiseToneRange: ClosedRange<Double> = 300...12_000

    /// The hats and the cymbal `tune` a SIX-OSCILLATOR BANK by a scale factor,
    /// not to a pitch in Hz — the 808 hat circuit has no single fundamental.
    public static let bankTuneRange: ClosedRange<Double> = 0.25...4.0
    public static let closedHatDecayRange: ClosedRange<Double> = 0.01...0.4
    public static let openHatDecayRange: ClosedRange<Double> = 0.05...1.5

    public static let clapTuneRange: ClosedRange<Double> = 300...4_000
    public static let clapDecayRange: ClosedRange<Double> = 0.05...1.5
    public static let clapSpreadRange: ClosedRange<Double> = 0.002...0.06

    public static let tomTuneRange: ClosedRange<Double> = 50...400
    public static let tomDecayRange: ClosedRange<Double> = 0.05...2.0
    public static let tomPitchAmountRange: ClosedRange<Double> = 0...4

    public static let rimTuneRange: ClosedRange<Double> = 400...4_000
    public static let rimDecayRange: ClosedRange<Double> = 0.005...0.5

    public static let cymbalDecayRange: ClosedRange<Double> = 0.1...4.0
    public static let cymbalBandRange: ClosedRange<Double> = 800...12_000

    public static let gainRange: ClosedRange<Double> = 0...2
    public static let velocityToToneRange: ClosedRange<Double> = 0...1
    public static let accentThresholdRange: ClosedRange<Double> = 1...127
    public static let accentDepthRange: ClosedRange<Double> = 0...1

    /// The tom's pitch-envelope decay is DERIVED, not addressable: `0.18 ×
    /// decay`, which holds the tom at nine names.
    ///
    /// ⚠️ THE DESIGN DOC CONTRADICTS ITSELF HERE and this line resolves it.
    /// `docs/design/2026-09-20-drum-machine.md` §2.6 lists `pitchDecay` 0.08 s
    /// among the tom's defaults and then, four lines later, says it "is fixed at
    /// `0.18 × decay` for the tom to hold the voice at 9 names". Both cannot be
    /// true. The derived form is the one the parameter COUNT depends on (75, and
    /// `describeDrumKit` publishes that number), so the derived form wins; at the
    /// default `decay` 0.38 it yields 0.0684 s, which is what the 0.08 s figure
    /// was approximating anyway. Exposing it later is purely additive.
    public static func tomPitchDecay(forDecay decay: Double) -> Double {
        (0.18 * decay).clamped(to: kickPitchDecayRange)
    }

    // MARK: - Per-voice defaults

    /// 808 kick: 52 Hz settling from ≈218 Hz, a 0.62 s boom, a light beater.
    public static let kickDefault = DrumVoiceParams(
        tune: 52, decay: 0.62, tone: 0.5, snap: 0.18, drive: 0.12,
        level: 0.9, pan: 0, velocity: 0.55, pitchAmount: 3.2, pitchDecay: 0.045)

    /// 909-lineage snare: two drumhead modes plus gated noise.
    public static let snareDefault = DrumVoiceParams(
        tune: 180, decay: 0.19, tone: 0.5, snap: 0.55, drive: 0.10,
        level: 0.8, pan: 0, velocity: 0.85,
        partial2Ratio: 1.83, noiseTone: 2200)

    /// 808 closed hat: the sourced 50 ms hardware decay. Group 0 with the open
    /// hat — one circuit in the hardware, so either cuts the other.
    public static let closedHatDefault = DrumVoiceParams(
        tune: 1.0, decay: 0.05, tone: 0.5, snap: 0.5, drive: 0,
        level: 0.7, pan: 0.1, velocity: 0.75, chokeGroup: 0)

    /// 808 open hat: mid of the sourced 90–600 ms range.
    public static let openHatDefault = DrumVoiceParams(
        tune: 1.0, decay: 0.32, tone: 0.5, snap: 0.5, drive: 0,
        level: 0.7, pan: 0.1, velocity: 0.7, chokeGroup: 0)

    /// 808 clap: the four-pulse retrigger at the sourced 11 ms spacing.
    public static let clapDefault = DrumVoiceParams(
        tune: 1000, decay: 0.28, tone: 0.55, snap: 0.5, drive: 0.05,
        level: 0.75, pan: -0.15, velocity: 0.6, spread: 0.011)

    /// 808 tom: the kick topology at a shallower sweep.
    public static let tomDefault = DrumVoiceParams(
        tune: 120, decay: 0.38, tone: 0.5, snap: 0.25, drive: 0.05,
        level: 0.8, pan: -0.25, velocity: 0.8, pitchAmount: 0.45)

    /// 808 rim: one very short ring.
    public static let rimDefault = DrumVoiceParams(
        tune: 1700, decay: 0.028, tone: 0.3, snap: 0.4, drive: 0,
        level: 0.6, pan: 0.3, velocity: 0.7)

    /// 808 cymbal: the same six-oscillator bank through the LOWER 3440 Hz band.
    public static let cymbalDefault = DrumVoiceParams(
        tune: 1.0, decay: 1.1, tone: 0.45, snap: 0.5, drive: 0,
        level: 0.55, pan: -0.2, velocity: 0.8, band: 3440)

    public init(kick: DrumVoiceParams = DrumKitParams.kickDefault,
                snare: DrumVoiceParams = DrumKitParams.snareDefault,
                closedHat: DrumVoiceParams = DrumKitParams.closedHatDefault,
                openHat: DrumVoiceParams = DrumKitParams.openHatDefault,
                clap: DrumVoiceParams = DrumKitParams.clapDefault,
                tom: DrumVoiceParams = DrumKitParams.tomDefault,
                rim: DrumVoiceParams = DrumKitParams.rimDefault,
                cymbal: DrumVoiceParams = DrumKitParams.cymbalDefault,
                gain: Double = 1.0, velocityToTone: Double = 0.4,
                accentThreshold: Double = 100, accentDepth: Double = 0.25,
                noteLayout: DrumNoteLayout = .pads) {
        self.kick = kick
        self.snare = snare
        self.closedHat = closedHat
        self.openHat = openHat
        self.clap = clap
        self.tom = tom
        self.rim = rim
        self.cymbal = cymbal
        self.gain = gain
        self.velocityToTone = velocityToTone
        self.accentThreshold = accentThreshold
        self.accentDepth = accentDepth
        self.noteLayoutStorage = noteLayout == .pads ? nil : noteLayout
    }

    // MARK: - Voice access by name (never by index)

    public static func voiceKeyPath(for voice: DrumVoice)
        -> WritableKeyPath<DrumKitParams, DrumVoiceParams> {
        switch voice {
        case .kick: return \.kick
        case .snare: return \.snare
        case .closedHat: return \.closedHat
        case .openHat: return \.openHat
        case .clap: return \.clap
        case .tom: return \.tom
        case .rim: return \.rim
        case .cymbal: return \.cymbal
        }
    }

    public subscript(voice: DrumVoice) -> DrumVoiceParams {
        get { self[keyPath: Self.voiceKeyPath(for: voice)] }
        set { self[keyPath: Self.voiceKeyPath(for: voice)] = newValue }
    }

    public static func leafKeyPath(for leaf: DrumLeafParam)
        -> WritableKeyPath<DrumVoiceParams, Double>? {
        switch leaf {
        case .tune: return \.tune
        case .decay: return \.decay
        case .tone: return \.tone
        case .snap: return \.snap
        case .drive: return \.drive
        case .level: return \.level
        case .pan: return \.pan
        case .velocity: return \.velocity
        case .pitchAmount: return \.pitchAmount
        case .pitchDecay: return \.pitchDecay
        case .partial2Ratio: return \.partial2Ratio
        case .noiseTone: return \.noiseTone
        case .spread: return \.spread
        case .band: return \.band
        case .gain, .velocityToTone, .accentThreshold, .accentDepth: return nil
        }
    }
}

// MARK: - The spec table: 75 names

public extension DrumKitParams {
    /// The dotted name for a scope/leaf pair. ONE spelling rule, one place.
    static func paramName(_ voice: DrumVoice?, _ leaf: DrumLeafParam) -> String {
        "\(voice?.rawValue ?? "kit").\(leaf.rawValue)"
    }

    private static func row(_ voice: DrumVoice, _ leaf: DrumLeafParam,
                            _ range: ClosedRange<Double>, _ defaultValue: Double,
                            _ unit: String, _ curve: ParamCurve,
                            _ note: String? = nil) -> DrumParamSpec {
        // `leafKeyPath` returns non-nil for every voice leaf; the four kit
        // leaves use `kitRow` instead and never reach here.
        let leafPath = leafKeyPath(for: leaf) ?? \DrumVoiceParams.tune
        return DrumParamSpec(
            name: paramName(voice, leaf), voice: voice, leaf: leaf,
            keyPath: voiceKeyPath(for: voice).appending(path: leafPath),
            range: range, defaultValue: defaultValue, unit: unit, curve: curve,
            note: note,
            // ⭐ THE ONE-SHOT CONTRACT: a percussive voice latches its whole
            // topology at trigger, because that is what a one-shot IS. `level`
            // and `pan` are the voice's OUTPUT stage rather than its topology,
            // so they move continuously on a sounding voice.
            appliesAtNextNoteOn: leaf != .level && leaf != .pan)
    }

    private static func kitRow(_ leaf: DrumLeafParam,
                               _ keyPath: WritableKeyPath<DrumKitParams, Double>,
                               _ range: ClosedRange<Double>, _ defaultValue: Double,
                               _ unit: String, _ curve: ParamCurve,
                               _ note: String) -> DrumParamSpec {
        DrumParamSpec(name: paramName(nil, leaf), voice: nil, leaf: leaf,
                      keyPath: keyPath, range: range, defaultValue: defaultValue,
                      unit: unit, curve: curve, note: note,
                      appliesAtNextNoteOn: true)
    }

    /// The five core parameters whose range, curve and meaning are IDENTICAL on
    /// every voice. `tune`, `decay` and `snap` are not here: their ranges differ
    /// per voice, and `snap` means something different on each.
    private static func uniformCore(_ voice: DrumVoice, _ d: DrumVoiceParams,
                                    driveNote: String?) -> [DrumParamSpec] {
        [
            row(voice, .tone, toneRange, d.tone, "", .linear,
                "Duller to brighter. Tilts this voice's filter."),
            row(voice, .drive, driveRange, d.drive, "", .linear,
                driveNote ?? "Saturation into the voice's output. Adds harmonics "
                    + "rather than level. Takes effect at the next note-on."),
            row(voice, .level, levelRange, d.level, "level", .linear,
                "Output level. Applied per sample, so it moves a SOUNDING voice "
                    + "— one of only two parameters that does."),
            row(voice, .pan, panRange, d.pan, "", .linear,
                "Stereo position. Applied per sample, so it moves a SOUNDING "
                    + "voice — one of only two parameters that does."),
            row(voice, .velocity, velocityRange, d.velocity, "", .linear,
                "How much a note's MIDI velocity moves this voice. At 0 every "
                    + "hit is identical, which is correct for a machine-even "
                    + "pattern. Splits between level and brightness per "
                    + "`kit.velocityToTone`. Takes effect at the next note-on."),
        ]
    }

    /// ⭐ THE 75 NAMES. Reorderable by construction — see the file header.
    static var paramSpecs: [DrumParamSpec] { Self.cachedParamSpecs }

    // Built once. The table is pure and immutable; rebuilding it per call would
    // put 75 allocations on every `describeDrumKit` and every route validation.
    private static let cachedParamSpecs: [DrumParamSpec] = {
        var specs: [DrumParamSpec] = []

        // ── kick (10) ── 808 lineage: sine + two independent exponential
        // envelopes, one on pitch (fast) and one on amplitude (slow).
        let k = kickDefault
        specs += [
            row(.kick, .tune, kickTuneRange, k.tune, "Hz", .logarithmic,
                "The pitch the kick SETTLES to. It starts higher by "
                    + "`kick.pitchAmount` and falls. Takes effect at the next note-on."),
            row(.kick, .decay, kickDecayRange, k.decay, "s", .logarithmic,
                "How long the boom lasts — the time to fall 60 dB, exactly. "
                    + "Takes effect at the next note-on."),
            row(.kick, .snap, snapRange, k.snap, "", .linear,
                "CLICK LEVEL — the beater, not the boom. A short high-passed "
                    + "noise burst at the very start. Takes effect at the next note-on."),
        ]
        specs += uniformCore(.kick, k, driveNote: nil)
        specs += [
            row(.kick, .pitchAmount, kickPitchAmountRange, k.pitchAmount, "×", .linear,
                "How far above `kick.tune` the pitch starts, as a multiple. At "
                    + "3.2 a 52 Hz kick starts near 218 Hz. At 0 the kick does not "
                    + "sweep at all and `kick.pitchDecay` does nothing. Takes "
                    + "effect at the next note-on."),
            row(.kick, .pitchDecay, kickPitchDecayRange, k.pitchDecay, "s", .logarithmic,
                "How fast the pitch falls. Short reads as impact; long reads as "
                    + "a tom. Does nothing while `kick.pitchAmount` is 0. Takes "
                    + "effect at the next note-on."),
        ]

        // ── snare (10) ── two drumhead modes plus a gated noise band.
        let s = snareDefault
        specs += [
            row(.snare, .tune, snareTuneRange, s.tune, "Hz", .logarithmic,
                "The first drumhead mode. The second sits at "
                    + "`snare.partial2Ratio` times this. Takes effect at the next note-on."),
            row(.snare, .decay, snareDecayRange, s.decay, "s", .logarithmic,
                "Time to fall 60 dB. Takes effect at the next note-on."),
            row(.snare, .snap, snapRange, s.snap, "", .linear,
                "SNAPPY — the balance between the drumhead tone and the wire "
                    + "noise. The 909 panel's third knob. Takes effect at the "
                    + "next note-on."),
        ]
        specs += uniformCore(.snare, s, driveNote: nil)
        specs += [
            row(.snare, .partial2Ratio, snarePartial2RatioRange, s.partial2Ratio,
                "×", .linear,
                "Where the second drumhead mode sits, as a multiple of "
                    + "`snare.tune`. Inharmonic ratios read as a real head; 2.0 "
                    + "reads as a tuned drum. Takes effect at the next note-on."),
            row(.snare, .noiseTone, snareNoiseToneRange, s.noiseTone, "Hz", .logarithmic,
                "Centre of the wire-noise band. Takes effect at the next note-on."),
        ]

        // ── closed hat (8) / open hat (8) ── one six-square 808 bank, two
        // decay pots, chocked against each other.
        for (voice, d, decayRange) in [
            (DrumVoice.closedHat, closedHatDefault, closedHatDecayRange),
            (DrumVoice.openHat, openHatDefault, openHatDecayRange),
        ] {
            specs += [
                row(voice, .tune, bankTuneRange, d.tune, "×", .logarithmic,
                    "Scales all SIX oscillators of the 808 hat bank together. "
                        + "This is a bank scale factor, not a pitch — the circuit "
                        + "has no single fundamental. Takes effect at the next note-on."),
                row(voice, .decay, decayRange, d.decay, "s", .logarithmic,
                    "Time to fall 60 dB. The closed and open hats are the same "
                        + "circuit behind two decay pots. Takes effect at the next note-on."),
                // ⚠️ The two hats share a topology, so it is tempting to share
                // this line too — but `snap` is the instrument's one polysemous
                // name and `note` is the ONLY thing that disambiguates it.
                // A teaching line that does not name its own voice teaches
                // nothing, so each hat names itself.
                row(voice, .snap, snapRange, d.snap, "", .linear,
                    "ATTACK SHARPNESS — how abruptly the gate opens on the "
                        + "\(voice.displayName.lowercased()). Takes effect at "
                        + "the next note-on."),
            ]
            specs += uniformCore(voice, d, driveNote: nil)
        }

        // ── clap (9) ── the four-pulse retrigger IS the sound.
        let c = clapDefault
        specs += [
            row(.clap, .tune, clapTuneRange, c.tune, "Hz", .logarithmic,
                "Centre of the noise band. Takes effect at the next note-on."),
            row(.clap, .decay, clapDecayRange, c.decay, "s", .logarithmic,
                "Length of the diffuse TAIL after the three fast pulses. Takes "
                    + "effect at the next note-on."),
            row(.clap, .snap, snapRange, c.snap, "", .linear,
                "BURST VERSUS TAIL — at 1 the tail dominates and the individual "
                    + "hand-claps blur. Takes effect at the next note-on."),
        ]
        specs += uniformCore(.clap, c, driveNote: nil)
        specs += [
            row(.clap, .spread, clapSpreadRange, c.spread, "s", .logarithmic,
                "Time between the retriggered pulses. 11 ms is the hardware "
                    + "figure and is what makes a clap read as several hands "
                    + "rather than one noise burst. Takes effect at the next note-on."),
        ]

        // ── tom (9) ──
        let t = tomDefault
        specs += [
            row(.tom, .tune, tomTuneRange, t.tune, "Hz", .logarithmic,
                "The tom's pitch. Takes effect at the next note-on."),
            row(.tom, .decay, tomDecayRange, t.decay, "s", .logarithmic,
                "Time to fall 60 dB. Also sets the pitch-envelope time, which is "
                    + "0.18 of it. Takes effect at the next note-on."),
            row(.tom, .snap, snapRange, t.snap, "", .linear,
                "STICK NOISE — the transient of the beater on the head. Takes "
                    + "effect at the next note-on."),
        ]
        specs += uniformCore(.tom, t, driveNote: nil)
        specs += [
            row(.tom, .pitchAmount, tomPitchAmountRange, t.pitchAmount, "×", .linear,
                "How far above `tom.tune` the pitch starts. This is the whole "
                    + "difference between a tom and a kick: 0.45 here against the "
                    + "kick's 3.2. Takes effect at the next note-on."),
        ]

        // ── rim (8) ──
        let r = rimDefault
        specs += [
            row(.rim, .tune, rimTuneRange, r.tune, "Hz", .logarithmic,
                "The ring frequency. Takes effect at the next note-on."),
            row(.rim, .decay, rimDecayRange, r.decay, "s", .logarithmic,
                "Time to fall 60 dB. 0.028 s is a rimshot; 0.11 s with "
                    + "`rim.tone` near 0 is a clave. Takes effect at the next note-on."),
            row(.rim, .snap, snapRange, r.snap, "", .linear,
                "THE CLICK at the head of the ring. Takes effect at the next note-on."),
        ]
        specs += uniformCore(.rim, r, driveNote: nil)

        // ── cymbal (9) ── the hat bank through the OTHER bandpass.
        let y = cymbalDefault
        specs += [
            row(.cymbal, .tune, bankTuneRange, y.tune, "×", .logarithmic,
                "Scales all six oscillators of the bank together, as on the "
                    + "hats. Takes effect at the next note-on."),
            row(.cymbal, .decay, cymbalDecayRange, y.decay, "s", .logarithmic,
                "Time to fall 60 dB. In the hardware this pot controls the "
                    + "LOWER band only, which is what makes a cymbal rather than "
                    + "a very long hat. Takes effect at the next note-on."),
            row(.cymbal, .snap, snapRange, y.snap, "", .linear,
                "ATTACK SHARPNESS. Takes effect at the next note-on."),
        ]
        specs += uniformCore(.cymbal, y, driveNote: nil)
        specs += [
            row(.cymbal, .band, cymbalBandRange, y.band, "Hz", .logarithmic,
                "Centre of the LOWER band — the one the decay applies to. Keep "
                    + "it well below the hats' 7100 Hz band or the cymbal becomes "
                    + "a long hat. Takes effect at the next note-on."),
        ]

        // ── kit (4) ──
        specs += [
            kitRow(.gain, \.gain, gainRange, 1.0, "level", .linear,
                   "Output gain for the whole kit, after every voice sums."),
            kitRow(.velocityToTone, \.velocityToTone, velocityToToneRange, 0.4, "", .linear,
                   "How much of each voice's velocity response is BRIGHTNESS "
                       + "rather than level. A real drum struck harder is brighter, "
                       + "not merely louder. At 0 velocity moves level only — which "
                       + "is what makes a programmed kit tick rather than groove."),
            kitRow(.accentThreshold, \.accentThreshold, accentThresholdRange, 100,
                   "velocity", .linear,
                   "MIDI velocity at or above which a hit counts as ACCENTED. "
                       + "The 808's accent is a step property, so a pattern that "
                       + "sends 110 on accented steps and 80 elsewhere is "
                       + "hardware-correct with no knowledge of the velocity curve."),
            kitRow(.accentDepth, \.accentDepth, accentDepthRange, 0.25, "", .linear,
                   "Extra level (and half a share of extra brightness) an "
                       + "accented hit receives, on every voice."),
        ]
        return specs
    }()

    /// Name → table index. Built once; `setValue` and `value(forParamName:)`
    /// are O(1) rather than a 75-row linear scan on every wire call.
    private static let specIndexByName: [String: Int] = {
        var map: [String: Int] = [:]
        for (index, spec) in cachedParamSpecs.enumerated() { map[spec.name] = index }
        return map
    }()

    static func spec(forParamName name: String) -> DrumParamSpec? {
        specIndexByName[name].map { cachedParamSpecs[$0] }
    }

    /// Every addressable name, in table order. `describeDrumKit`'s `order`.
    static var paramNames: [String] { cachedParamSpecs.map(\.name) }

    // MARK: - Name-addressed access (the wire's only per-parameter path)

    /// The current value of one dotted name, or nil when the name is unknown.
    func value(forParamName name: String) -> Double? {
        guard let spec = Self.spec(forParamName: name) else { return nil }
        return self[keyPath: spec.keyPath]
    }

    /// Sets one dotted name, clamping through the spec's own range. Returns
    /// false — and changes NOTHING — for an unknown name.
    ///
    /// ⚠️ A non-finite value is REFUSED rather than clamped. `Double.nan`
    /// survives `min`/`max` unchanged (every comparison with NaN is false), so
    /// clamping cannot stop it, and the render thread turns several of these
    /// into sample counts with `Int(...)`, which TRAPS on NaN.
    @discardableResult
    mutating func setValue(_ value: Double, forParamName name: String) -> Bool {
        guard let spec = Self.spec(forParamName: name), value.isFinite else { return false }
        self[keyPath: spec.keyPath] = value.clamped(to: spec.range)
        return true
    }

    /// Re-clamps every addressable parameter through its spec range. Called on
    /// decode and on wholesale replacement, so a payload assembled by hand (or
    /// by an older build with wider ranges) cannot put an out-of-range number
    /// in front of the render thread.
    mutating func clampAll() {
        for spec in Self.cachedParamSpecs {
            let current = self[keyPath: spec.keyPath]
            self[keyPath: spec.keyPath] = current.isFinite
                ? current.clamped(to: spec.range)
                : spec.defaultValue
        }
        for voice in DrumVoice.allCases {
            let path = Self.voiceKeyPath(for: voice)
            if let group = self[keyPath: path].chokeGroup {
                self[keyPath: path].chokeGroup = group.clamped(to: SamplerZone.chokeGroupRange)
            }
        }
    }
}

// MARK: - Codable, driven off the table

extension DrumKitParams: Codable {
    /// Dynamic key so the encoder and decoder can walk the spec table rather
    /// than duplicating 75 names in a `CodingKeys` enum that would rot.
    private struct NameKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let chokeGroupKey = "chokeGroup"

    public init(from decoder: any Decoder) throws {
        // ⭐ START FROM THE DEFAULTS, THEN OVERWRITE ONLY WHAT IS PRESENT.
        // This is the whole forward-compatibility story and it is structural: a
        // project saved before a parameter existed simply has no key, so the
        // parameter keeps its default, which IS the old behaviour. There is no
        // per-field `?? default` list for a 76th parameter to be left out of.
        self.init()
        let container = try decoder.container(keyedBy: NameKey.self)

        for voice in DrumVoice.allCases {
            guard container.contains(NameKey(voice.rawValue)) else { continue }
            let voiceBox = try container.nestedContainer(
                keyedBy: NameKey.self, forKey: NameKey(voice.rawValue))
            for spec in Self.cachedParamSpecs where spec.voice == voice {
                if let value = try voiceBox.decodeIfPresent(
                    Double.self, forKey: NameKey(spec.leaf.rawValue)) {
                    self[keyPath: spec.keyPath] = value
                }
            }
            // ⛔ NO FALLBACK. See the file header: the hats default to group 0,
            // so a `?? default` here would silently UNDO a user's deliberate
            // clearing of the hat choke on every reopen.
            self[keyPath: Self.voiceKeyPath(for: voice)].chokeGroup =
                try voiceBox.decodeIfPresent(Int.self, forKey: NameKey(Self.chokeGroupKey))
        }
        for spec in Self.cachedParamSpecs where spec.voice == nil {
            if let value = try container.decodeIfPresent(
                Double.self, forKey: NameKey(spec.leaf.rawValue)) {
                self[keyPath: spec.keyPath] = value
            }
        }
        // m39-tpl-0 — the note layout. ABSENT (every kit saved before TPL-0,
        // and every `pads` kit since) stays nil, which IS `.pads` — today's
        // behaviour, bit for bit. An UNKNOWN string (a newer build's layout)
        // also reads as `.pads` rather than failing the whole project open:
        // an unknown instrument kind failing the open is the F-1 defect
        // (`docs/design/2026-09-27-multi-instrument-templates.md` §16), and a
        // layout must not copy it. A NON-STRING throws, like every other
        // malformed field in this decoder.
        if let raw = try container.decodeIfPresent(
            String.self, forKey: NameKey(Self.noteLayoutKey)) {
            noteLayout = DrumNoteLayout(rawValue: raw) ?? .pads
        }
        clampAll()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: NameKey.self)
        for voice in DrumVoice.allCases {
            var voiceBox = container.nestedContainer(
                keyedBy: NameKey.self, forKey: NameKey(voice.rawValue))
            for spec in Self.cachedParamSpecs where spec.voice == voice {
                try voiceBox.encode(self[keyPath: spec.keyPath],
                                    forKey: NameKey(spec.leaf.rawValue))
            }
            try voiceBox.encodeIfPresent(self[voice].chokeGroup,
                                         forKey: NameKey(Self.chokeGroupKey))
        }
        for spec in Self.cachedParamSpecs where spec.voice == nil {
            try container.encode(self[keyPath: spec.keyPath],
                                 forKey: NameKey(spec.leaf.rawValue))
        }
        // Only when set, which means only `gm` (the storage is never `.pads`):
        // a `pads` kit writes exactly the bytes it wrote before TPL-0.
        try container.encodeIfPresent(noteLayoutStorage?.rawValue,
                                      forKey: NameKey(Self.noteLayoutKey))
    }
}

// MARK: - Presets

/// A named factory kit. 808 and 909 are the two LINEAGES, and they differ in
/// NUMBERS rather than topology — which is why there is no `character` enum and
/// why this instrument has zero discrete parameters.
public struct DrumKitPreset: Sendable, Equatable {
    public let name: String
    public let summary: String
    public let params: DrumKitParams
}

public extension DrumKitParams {
    /// The factory kits, in menu order.
    static let presets: [DrumKitPreset] = [
        DrumKitPreset(
            name: "808",
            summary: "The long boom. Deep sub kick with a slow fall, loose hats, "
                + "a snare that sits back. The defaults.",
            params: DrumKitParams()),
        DrumKitPreset(
            name: "909",
            summary: "The hard click. Faster and deeper pitch sweep on the kick, "
                + "a much shorter body, a brighter snappier snare.",
            params: nineOhNine),
        DrumKitPreset(
            name: "acoustic",
            summary: "Longer, less saturated and less synthetic: no drive, "
                + "inharmonic snare modes, a wider kit image.",
            params: acoustic),
        DrumKitPreset(
            name: "lofi",
            summary: "Dull and driven. Everything darker, the kick saturated, "
                + "the hats short and closed down.",
            params: lofi),
        DrumKitPreset(
            name: "trap",
            summary: "A very long sub kick, a tight clap-forward snare and fast "
                + "bright hats built for rolls.",
            params: trap),
    ]

    static func preset(named name: String) -> DrumKitPreset? {
        presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// This kit with `preset`'s SOUND and this kit's NOTE LAYOUT (m39-tpl-0).
    ///
    /// ⭐ A PRESET CHANGES HOW THE DRUMS SOUND, NEVER WHICH KEY PLAYS WHICH
    /// DRUM. Every factory preset carries the default layout, so replacing a
    /// `gm` kit with `preset.params` wholesale would silently move every drum
    /// back to the pad keys, and every General MIDI beat on the track would
    /// play the wrong drums. ONE HOME: `instrument.loadDrumPreset` and
    /// `DemoRender` both call this, and `matchingPreset` is defined through it.
    func applyingPreset(_ preset: DrumKitPreset) -> DrumKitParams {
        var result = preset.params
        result.noteLayout = noteLayout
        return result
    }

    /// The factory preset whose SOUND this kit is, whatever its note layout,
    /// or nil for a custom kit. Defined as "loading this preset would change
    /// nothing", so it ignores the layout by construction rather than by a
    /// second, hand-written equality that could drift from `applyingPreset`.
    var matchingPreset: DrumKitPreset? {
        Self.presets.first { applyingPreset($0) == self }
    }

    /// 909: the same three blocks per voice, different numbers (design §2.1).
    private static var nineOhNine: DrumKitParams {
        var p = DrumKitParams()
        p.kick.tune = 58
        p.kick.decay = 0.26
        p.kick.pitchAmount = 7.5
        p.kick.pitchDecay = 0.014
        p.kick.snap = 0.55
        p.kick.drive = 0.30
        p.snare.tune = 200
        p.snare.decay = 0.14
        p.snare.snap = 0.7
        p.snare.noiseTone = 3200
        p.snare.partial2Ratio = 1.65
        p.closedHat.decay = 0.042
        p.closedHat.tune = 1.15
        p.openHat.decay = 0.26
        p.openHat.tune = 1.15
        p.tom.decay = 0.3
        p.cymbal.decay = 0.9
        p.velocityToTone = 0.3
        p.accentDepth = 0.32
        p.clampAll()
        return p
    }

    private static var acoustic: DrumKitParams {
        var p = DrumKitParams()
        p.kick.tune = 62
        p.kick.decay = 0.42
        p.kick.pitchAmount = 1.6
        p.kick.pitchDecay = 0.03
        p.kick.snap = 0.42
        p.kick.drive = 0
        p.snare.tune = 205
        p.snare.partial2Ratio = 2.31
        p.snare.decay = 0.26
        p.snare.snap = 0.48
        p.snare.drive = 0
        p.closedHat.decay = 0.07
        p.openHat.decay = 0.45
        p.tom.tune = 145
        p.tom.decay = 0.55
        p.tom.pan = -0.45
        p.rim.decay = 0.05
        p.cymbal.decay = 2.2
        p.cymbal.pan = -0.35
        p.closedHat.pan = 0.3
        p.openHat.pan = 0.3
        p.velocityToTone = 0.55
        p.clampAll()
        return p
    }

    private static var lofi: DrumKitParams {
        var p = DrumKitParams()
        p.kick.tune = 48
        p.kick.decay = 0.5
        p.kick.tone = 0.18
        p.kick.drive = 0.55
        p.kick.snap = 0.1
        p.snare.tone = 0.2
        p.snare.noiseTone = 1100
        p.snare.decay = 0.15
        p.snare.drive = 0.4
        p.closedHat.tone = 0.15
        p.closedHat.decay = 0.035
        p.openHat.tone = 0.15
        p.openHat.decay = 0.2
        p.cymbal.tone = 0.15
        p.cymbal.band = 2200
        p.cymbal.decay = 0.7
        p.clap.tone = 0.25
        p.clap.tune = 780
        p.velocityToTone = 0.2
        p.gain = 0.9
        p.clampAll()
        return p
    }

    private static var trap: DrumKitParams {
        var p = DrumKitParams()
        p.kick.tune = 42
        p.kick.decay = 1.45
        p.kick.pitchAmount = 5.0
        p.kick.pitchDecay = 0.02
        p.kick.drive = 0.22
        p.kick.snap = 0.3
        p.snare.tune = 230
        p.snare.decay = 0.11
        p.snare.snap = 0.78
        p.snare.noiseTone = 3600
        p.clap.decay = 0.2
        p.clap.snap = 0.3
        p.clap.level = 0.85
        p.closedHat.decay = 0.028
        p.closedHat.tune = 1.35
        p.closedHat.velocity = 0.9
        p.openHat.decay = 0.16
        p.openHat.tune = 1.35
        p.cymbal.decay = 0.6
        p.velocityToTone = 0.5
        p.accentDepth = 0.35
        p.clampAll()
        return p
    }
}
