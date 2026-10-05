import Foundation

// m39-tpl-1 — how a template's `instrument` block is read (design §4.5).
//
// A template's instrument must NAME its kind. `track.setInstrument` can infer a
// kind from `soundBank` or `audioUnit`, but not from `drumKit` — sending a kit
// without `kind: "drumSynth"` stores the kit and plays the saw Poly Synth, with
// a success reply. A template takes no inference at all, and a block that
// belongs to another kind is refused with a sentence saying so.
//
// The result is RESOLVED into the model's own `InstrumentDescriptor`, starting
// from the factory values: an instrument has no identity, so one resolved
// value can be applied any number of times.
//
// m39-tpl-5b — the Sampler (saved templates only, §2.2, §4.5, §7.2): the
// `sampler` object `track.setInstrument` takes, read here and WRITTEN here
// (`samplerObject`), zones by absolute path. A Sampler ZONE does have an
// identity (`ProjectDocument` keys each zone's sample file by zone id, one
// project-wide map), so a template carries none: the codec gives each zone a
// PLACEHOLDER id (`samplerZoneID`) and `TemplateBuilder` replaces every one
// with a fresh id from `makeID`. One departure from "no file system" in this
// codec: a `builtin:<name>` zone path resolves through `BundledSamples` (a
// lookup in the app's own resource bundle), exactly as the wire resolves it.

extension TemplateReader {
    /// The blocks an instrument can carry besides `kind`, per kind.
    static let drumKitBlocks = ["drumPreset", "drumKit"]

    static func instrumentKeys(for kind: InstrumentDescriptor.Kind) -> [String] {
        switch kind {
        case .testTone: return ["kind"]
        case .polySynth: return ["kind"] + PolySynthParams.settingNames
        case .drumSynth: return ["kind"] + drumKitBlocks
        case .soundBank: return ["kind", "soundBank"]
        case .sampler: return ["kind", "sampler"]
        case .audioUnit: return ["kind", "audioUnit"]
        }
    }

    /// Every key any instrument kind can carry.
    static var anyInstrumentKey: Set<String> {
        Set(InstrumentDescriptor.Kind.allCases.flatMap { instrumentKeys(for: $0) })
    }

    /// Why `key` cannot sit beside `kind`, in words a novice can act on, or nil
    /// when it can.
    static func misplacedBlock(_ key: String, kind: InstrumentDescriptor.Kind) -> String? {
        guard !instrumentKeys(for: kind).contains(key) else { return nil }
        let isKind = "the instrument's kind is \"\(kind.rawValue)\""
        if drumKitBlocks.contains(key) {
            return "a drum kit needs \"kind\": \"drumSynth\". Without it, the track would play "
                + "a different instrument instead, and \(isKind)."
        }
        if PolySynthParams.settingKind(named: key) != nil {
            return "'\(key)' is a Poly Synth setting, so it needs \"kind\": \"polySynth\", and "
                + "\(isKind)."
        }
        switch key {
        case "soundBank": return "a sound bank needs \"kind\": \"soundBank\", and \(isKind)."
        case "sampler": return "a Sampler setup needs \"kind\": \"sampler\", and \(isKind)."
        case "audioUnit": return "an Audio Unit needs \"kind\": \"audioUnit\", and \(isKind)."
        default: return nil
        }
    }

    /// One instrument block. Returns nil when a LENIENT read skips an
    /// instrument kind this build does not know — the caller then skips the
    /// whole track (never a substitute sound).
    mutating func readInstrument(_ json: TemplateJSON, _ path: String,
                                 trackName: String) throws -> InstrumentDescriptor? {
        var object = try self.object(json, path)
        guard let rawKind = object["kind"] else {
            throw Self.missing(Self.join(path, "kind"),
                               "the instrument's kind, like \"polySynth\" or \"soundBank\"")
        }
        let kindName = try string(rawKind, Self.join(path, "kind"))
        guard let kind = InstrumentDescriptor.Kind(rawValue: kindName) else {
            let known = InstrumentDescriptor.Kind.allCases.map(\.rawValue).joined(separator: ", ")
            try refuseOrSkip(
                TemplateRefusal(code: .unknownKind, path: Self.join(path, "kind"),
                                message: "there is no instrument called '\(kindName)'. The "
                                    + "instruments are: \(known)."),
                .unknownInstrumentSkipped,
                "the track '\(trackName)' uses an instrument this version of DAW Pro doesn't "
                    + "have, so the track was left out.")
            return nil
        }
        // A block that belongs to ANOTHER kind is the author's mistake in any
        // version (a drum kit on a Poly Synth), so it is refused outright; a
        // key no kind has is an unknown key, under the version rule.
        for key in object.keys.sorted() where key != "kind" {
            if let reason = Self.misplacedBlock(key, kind: kind),
               Self.anyInstrumentKey.contains(key) {
                throw TemplateRefusal(code: .invalidValue, path: Self.join(path, key),
                                      message: reason)
            }
        }
        object = try knownKeys(object, Self.instrumentKeys(for: kind), path, "This instrument")

        switch kind {
        case .testTone:
            return InstrumentDescriptor(kind: .testTone)
        case .polySynth:
            return InstrumentDescriptor(kind: .polySynth,
                                        polySynth: try readPolySynth(object, path))
        case .drumSynth:
            return try readDrumMachine(object, path)
        case .soundBank:
            guard let raw = object["soundBank"] else {
                throw Self.missing(Self.join(path, "soundBank"),
                                   "the bank and program to play, like {\"source\": \"gm\", "
                                    + "\"program\": 0}")
            }
            return InstrumentDescriptor(kind: .soundBank,
                                        soundBank: try readSoundBank(raw, Self.join(path, "soundBank")))
        case .sampler:
            guard let raw = object["sampler"] else { return InstrumentDescriptor(kind: .sampler) }
            return InstrumentDescriptor(kind: .sampler,
                                        sampler: try readSampler(raw, Self.join(path, "sampler")))
        case .audioUnit:
            guard let raw = object["audioUnit"] else {
                throw Self.missing(Self.join(path, "audioUnit"),
                                   "the plug-in to load: {\"subType\", \"manufacturer\"}")
            }
            return InstrumentDescriptor(kind: .audioUnit,
                                        audioUnit: try readAudioUnit(
                                            raw, Self.join(path, "audioUnit"), defaultType: "aumu"))
        }
    }

    // MARK: - Poly Synth

    /// The 24 flat names `track.setInstrument` takes, over `PolySynthParams()`.
    /// Every name, range and field comes from the one table
    /// (`PolySynthParams.settingKind(named:)`); the model's own decoder is not
    /// used, because it requires its first eight fields.
    mutating func readPolySynth(_ object: [String: TemplateJSON],
                                _ path: String) throws -> PolySynthParams {
        var params = PolySynthParams()
        for name in PolySynthParams.settingNames {
            guard let raw = object[name], let kind = PolySynthParams.settingKind(named: name)
            else { continue }
            let settingPath = Self.join(path, name)
            switch kind {
            case .waveform:
                let text = try string(raw, settingPath)
                guard let waveform = PolySynthParams.Waveform(rawValue: text) else {
                    let known = PolySynthParams.Waveform.allCases.map(\.rawValue)
                        .joined(separator: ", ")
                    try refuseOrSkip(
                        TemplateRefusal(code: .unknownSetting, path: settingPath,
                                        message: "'\(text)' isn't a waveform. It can be: "
                                            + "\(known)."),
                        .unknownSettingSkipped,
                        "the waveform '\(text)' comes from a newer version of DAW Pro, so "
                            + "\(name) keeps its default.")
                    continue
                }
                params.setSetting(name, waveform: waveform)
                if params.settingWaveform(name) != waveform {
                    throw TemplateRefusal(code: .readBack, path: settingPath,
                                          message: "\(name) did not keep '\(text)'.")
                }
            case .number(let range):
                let value = try ranged(try number(raw, settingPath), range, settingPath, name)
                params.setSetting(name, number: value)
                _ = try readBack(written: value, read: params.settingNumber(name),
                                 settingPath, name)
            case .integer(let range):
                let value = try ranged(try integer(raw, settingPath), range, settingPath, name)
                params.setSetting(name, number: Double(value))
                _ = try readBack(written: Double(value), read: params.settingNumber(name),
                                 settingPath, name)
            }
        }
        return params
    }

    // MARK: - Drum machine

    /// `drumPreset` first — the whole kit of that factory preset, matched
    /// without regard to case — then `drumKit` over it. Neither: the factory
    /// kit, left implicit (`drumKit: nil`), exactly as a fresh drum machine.
    mutating func readDrumMachine(_ object: [String: TemplateJSON],
                                  _ path: String) throws -> InstrumentDescriptor {
        var kit: DrumKitParams?
        if let raw = object["drumPreset"] {
            let presetPath = Self.join(path, "drumPreset")
            let name = try string(raw, presetPath)
            if let preset = DrumKitParams.preset(named: name) {
                kit = preset.params
            } else {
                let known = DrumKitParams.presets.map(\.name).joined(separator: ", ")
                try refuseOrSkip(
                    TemplateRefusal(code: .unknownKind, path: presetPath,
                                    message: "there is no drum kit called '\(name)'. The kits "
                                        + "are: \(known)."),
                    .unknownPresetSkipped,
                    "the drum kit '\(name)' comes from a newer version of DAW Pro, so the "
                        + "drum machine starts from its factory kit.")
            }
        }
        if let raw = object["drumKit"] {
            kit = try readDrumKit(raw, Self.join(path, "drumKit"), base: kit ?? DrumKitParams())
        }
        return InstrumentDescriptor(kind: .drumSynth, drumKit: kit)
    }

    /// The fields of `DrumKitParams` this reader writes: the eight voices and
    /// the four kit-wide settings. `TrackSetTemplateCodecTests` compares this
    /// with the struct's stored properties, so a new field (TPL-0's
    /// `noteLayout`) cannot arrive unread.
    static let drumKitFieldsRead: Set<String> = Set(DrumVoice.allCases.map(\.rawValue))
        .union(["gain", "velocityToTone", "accentThreshold", "accentDepth", "noteLayoutStorage"])

    /// A `drumKit` object, parsed as the overlay `track.setInstrument` parses
    /// it (`CommandRouter.parseDrumKit`): an object per voice of number leaves,
    /// `chokeGroup` a whole number or null, the read-only `note` ignored, and
    /// kit-wide leaves at the top. The NAMES have one home,
    /// `DrumKitParams.spec(forParamName:)` / `setValue(_:forParamName:)`; the
    /// object's grammar is read here and by the wire, and
    /// `TrackSetTemplateWireParityTests` runs one table through both.
    ///
    /// ⚠️ The deliberate differences from the wire, each pinned by that table:
    /// an out-of-range number or choke group is REFUSED here (the wire clamps),
    /// and a fractional choke group is REFUSED here (the wire truncates).
    mutating func readDrumKit(_ json: TemplateJSON, _ path: String,
                              base: DrumKitParams) throws -> DrumKitParams {
        let root = try self.object(json, path)
        var kit = base
        for key in root.keys.sorted() {
            let entry = root[key]!
            let entryPath = Self.join(path, key)
            // TPL-0's `noteLayout` ("pads" | "gm"): the one kit-wide setting
            // whose value is a WORD, so it is matched BEFORE the number branch
            // below, in the same order the wire's `parseDrumKit` matches it.
            if key == DrumKitParams.noteLayoutKey {
                let text = try string(entry, entryPath)
                if let layout = DrumNoteLayout(rawValue: text) {
                    kit.noteLayout = layout
                } else {
                    let known = DrumNoteLayout.allCases.map(\.rawValue).joined(separator: ", ")
                    try refuseOrSkip(
                        TemplateRefusal(code: .unknownSetting, path: entryPath,
                                        message: "a drum kit's note layout is one of: \(known); "
                                            + "'\(text)' is not one."),
                        .unknownSettingSkipped,
                        "the note layout '\(text)' comes from a newer version of DAW Pro, so "
                            + "the drum machine keeps the layout it had.")
                }
                continue
            }
            if let voice = DrumVoice(rawValue: key) {
                guard case .object(let voiceObject) = entry else {
                    throw Self.wrongType(entryPath, "an object of the \(voice.displayName)'s "
                        + "settings", entry)
                }
                for leaf in voiceObject.keys.sorted() {
                    let leafPath = Self.join(entryPath, leaf)
                    let value = voiceObject[leaf]!
                    // `note` is DERIVED and read-only; ignored on input, as the
                    // wire ignores it.
                    if leaf == "note" { continue }
                    if leaf == "chokeGroup" {
                        if case .null = value {
                            kit[voice].chokeGroup = nil
                        } else {
                            let group = try ranged(try integer(value, leafPath),
                                                   SamplerZone.chokeGroupRange, leafPath,
                                                   "chokeGroup")
                            kit[voice].chokeGroup = group
                        }
                        continue
                    }
                    try setDrumParam(&kit, name: "\(key).\(leaf)", value, leafPath)
                }
            } else {
                try setDrumParam(&kit, name: "kit.\(key)", entry, entryPath)
            }
        }
        return kit
    }

    /// One dotted drum parameter, through the one name home.
    mutating func setDrumParam(_ kit: inout DrumKitParams, name: String, _ json: TemplateJSON,
                               _ path: String) throws {
        guard let spec = DrumKitParams.spec(forParamName: name) else {
            let scope = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            let names = DrumKitParams.paramSpecs
                .filter { ($0.voice?.rawValue ?? "kit") == scope }
                .map { String($0.name.dropFirst(scope.count + 1)) }
                .joined(separator: ", ")
            let valid: String
            if scope == "kit" {
                let drums = DrumVoice.allCases.map(\.rawValue).joined(separator: ", ")
                valid = "a drum kit's top level holds the drums (\(drums)) and the kit-wide "
                    + "settings (\(names))"
            } else {
                valid = "the settings of this drum are: \(names)"
            }
            try refuseOrSkip(
                TemplateRefusal(code: .unknownSetting, path: path,
                                message: "the drum machine has no setting called '\(name)'; "
                                    + "\(valid)."),
                .unknownSettingSkipped,
                "the drum setting '\(name)' comes from a newer version of DAW Pro, so it was "
                    + "left out.")
            return
        }
        let value = try ranged(try number(json, path), spec.range, path, name)
        kit.setValue(value, forParamName: name)
        _ = try readBack(written: value, read: kit.value(forParamName: name), path, name)
    }

    // MARK: - Sound bank

    static let soundBankKeys = ["source", "program", "bankMSB", "bankLSB"]

    /// `{source: "gm" | "<absolute path>", program?, bankMSB?, bankLSB?}` — the
    /// object `track.setInstrument` takes, with its defaults (0 / 121 / 0).
    /// Whether a bank FILE exists is the store's check at apply time, not the
    /// codec's. The display name is DERIVED, never read (§4.6).
    mutating func readSoundBank(_ json: TemplateJSON, _ path: String) throws -> SoundBankConfig {
        var object = try self.object(json, path)
        object = try knownKeys(object, Self.soundBankKeys, path, "A sound bank")
        guard let rawSource = object["source"] else {
            throw Self.missing(Self.join(path, "source"),
                               "\"gm\" for the Mac's General MIDI bank, or a bank file's full path")
        }
        let sourceText = try string(rawSource, Self.join(path, "source"))
        let source: SoundBankSource
        if sourceText == "gm" {
            source = .generalMIDI
        } else if sourceText.hasPrefix("/") {
            source = .file(path: sourceText)
        } else {
            throw TemplateRefusal(
                code: .invalidValue, path: Self.join(path, "source"),
                message: "a sound bank's source is \"gm\" (the Mac's General MIDI bank) or a "
                    + "bank file's full path, starting with \"/\".")
        }
        func byte(_ key: String, _ fallback: Int) throws -> Int {
            guard let raw = object[key] else { return fallback }
            let keyPath = Self.join(path, key)
            return try ranged(try integer(raw, keyPath), SoundBankConfig.midiValueRange,
                              keyPath, key)
        }
        let program = try byte("program", 0)
        let bankMSB = try byte("bankMSB", GMProgramCatalog.melodicBankMSB)
        let bankLSB = try byte("bankLSB", GMProgramCatalog.bankLSB)
        return SoundBankConfig(source: source, program: program, bankMSB: bankMSB,
                               bankLSB: bankLSB,
                               displayName: Self.soundBankDisplayName(
                                source: source, program: program, bankMSB: bankMSB,
                                bankLSB: bankLSB))
    }

    /// The skeleton's way for General MIDI (`GMProgramCatalog`: the melodic
    /// program's name, or the Standard Drum Kit), and the wire's own fallback
    /// (`"<bank file name> · P<n>"`) for anything else.
    static func soundBankDisplayName(source: SoundBankSource, program: Int, bankMSB: Int,
                                     bankLSB: Int) -> String {
        switch source {
        case .generalMIDI:
            let kit = GMProgramCatalog.standardDrumKit
            if program == kit.program, bankMSB == kit.bankMSB, bankLSB == kit.bankLSB {
                return kit.name
            }
            if bankMSB == GMProgramCatalog.melodicBankMSB, bankLSB == GMProgramCatalog.bankLSB {
                return GMProgramCatalog.melodic(program).name
            }
            return "General MIDI · P\(program)"
        case .file(let path):
            let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return "\(stem) · P\(program)"
        }
    }

    // MARK: - Audio Unit

    static let audioUnitKeys = ["type", "subType", "manufacturer", "state"]

    /// The wire's `{type?, subType, manufacturer}` plus `state`, the base64 of
    /// the plug-in's saved sound (`AudioUnitConfig.stateData`). Whether the
    /// plug-in is INSTALLED is the store's question at apply time: a missing
    /// one is created with a warning, the way a project with a missing plug-in
    /// opens (§5.4). Display names are filled in then, too.
    mutating func readAudioUnit(_ json: TemplateJSON, _ path: String,
                                defaultType: String) throws -> AudioUnitConfig {
        var object = try self.object(json, path)
        object = try knownKeys(object, Self.audioUnitKeys, path, "An Audio Unit")
        func code(_ key: String) throws -> String? {
            guard let raw = object[key] else { return nil }
            let keyPath = Self.join(path, key)
            let text = try string(raw, keyPath)
            guard text.count == 4, text.unicodeScalars.allSatisfy(\.isASCII) else {
                throw TemplateRefusal(
                    code: .invalidValue, path: keyPath,
                    message: "an Audio Unit code is exactly four plain characters, like "
                        + "\"aumu\"; '\(text)' is not.")
            }
            return text
        }
        guard let subType = try code("subType") else {
            throw Self.missing(Self.join(path, "subType"), "the plug-in's four-character type code")
        }
        guard let manufacturer = try code("manufacturer") else {
            throw Self.missing(Self.join(path, "manufacturer"),
                               "the plug-in maker's four-character code")
        }
        let type = try code("type") ?? defaultType
        var state: Data?
        if let raw = object["state"] {
            let statePath = Self.join(path, "state")
            guard let data = Data(base64Encoded: try string(raw, statePath)) else {
                throw TemplateRefusal(code: .invalidValue, path: statePath,
                                      message: "the plug-in's saved sound is not readable "
                                        + "(it must be base64 text).")
            }
            state = data
        }
        return AudioUnitConfig(
            component: AudioUnitComponentID(type: type, subType: subType,
                                            manufacturer: manufacturer),
            stateData: state)
    }
}

// MARK: - Sampler (m39-tpl-5b)

extension TemplateReader {
    /// The keys of a template's `sampler` object: everything the wire's
    /// `parseSampler` (`track.setInstrument`'s `sampler` object) writes. Not
    /// here, on purpose: `zonePatches` (refused in words: it edits zones a track
    /// already has, and a template's track has none yet) and the wire's
    /// read-only provenance echoes `sourcePath` and `name`, which are unknown
    /// keys to a template. `TemplateSamplerCodecTests` compares this list with
    /// `SamplerParams`' stored properties minus the provenance trio
    /// (`sourcePath`, `displayName`, `sliceKit`: the wire reads none of them), so
    /// a new field cannot arrive unread.
    static let samplerKeys = ["zones", "oneShot", "attack", "release", "gain",
                              "expressionModDepth", "expressionFilterDepth",
                              "expressionFilterCC", "bendRangeSemitones", "voiceMode", "decay",
                              "sustain", "pedalHoldLimit", "glideTime", "glideMode"]

    /// One zone's keys: every `SamplerZone` field but its `id`, with
    /// `audioFileURL` spelled `path`, as the wire spells it.
    static let samplerZoneKeys = ["path", "rootPitch", "minPitch", "maxPitch", "gain",
                                  "minVelocity", "maxVelocity", "group", "seqLength",
                                  "seqPosition", "randMin", "randMax", "tuneCents", "pan",
                                  "ampVelTrack", "oneShot", "startFrame", "endFrame", "attack",
                                  "decay", "sustain", "release", "loopMode", "loopStart",
                                  "loopEnd", "crossfade", "reverse", "chokeGroup"]

    /// A zone's `crossfade` object: every `SamplerCrossfade` field, raw MIDI
    /// values (`SamplerCrossfade.init` clamps each to 0…127).
    static let samplerCrossfadeKeys = ["controller", "ccInLo", "ccInHi", "ccOutLo", "ccOutHi",
                                       "velInLo", "velInHi", "velOutLo", "velOutHi"]

    // MARK: Zone identity

    /// Every placeholder zone id starts with this.
    static let samplerZoneIDPrefix = "7E3D5A11-0000-4000-8000-"

    /// The PLACEHOLDER id a template gives zone `index` of a Sampler. A template
    /// carries no zone identity: `ProjectDocument` keys every zone's sample file
    /// by zone id in ONE project-wide map (`SamplerDocument.init(from:mediaRefs:)`,
    /// filled by `ProjectBundle.planMedia`), so a copy that shared its source's
    /// ids would make one file stand in for both on the next save. The codec and
    /// the canonical form use these, so the same file reads as the same value;
    /// `TemplateBuilder` replaces every one with a fresh id from `makeID`.
    static func samplerZoneID(_ index: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(truncatingIfNeeded: index) & 0xFFFF_FFFF_FFFF)
        return UUID(uuidString: samplerZoneIDPrefix + suffix) ?? UUID()
    }

    static func isSamplerZonePlaceholder(_ id: UUID) -> Bool {
        id.uuidString.hasPrefix(samplerZoneIDPrefix)
    }

    /// `zone` under another id (and, for the canonical form, its file URL
    /// rebuilt from its path), every other field copied. The ONE place a
    /// template re-identifies a zone: the codec's placeholders, the canonical
    /// form and the builder's fresh ids all come through here.
    ///
    /// ⚠️ An explicit initialiser call, so a field added to `SamplerZone` and not
    /// named here would silently fall to its nil default.
    /// `TemplateSamplerCodecTests` fills EVERY field of a fixture (checked by
    /// `Mirror`, not by eye) and compares the copy with it.
    static func samplerZone(_ zone: SamplerZone, id: UUID, audioFileURL: URL? = nil) -> SamplerZone {
        SamplerZone(
            id: id, audioFileURL: audioFileURL ?? zone.audioFileURL, rootPitch: zone.rootPitch,
            minPitch: zone.minPitch, maxPitch: zone.maxPitch, gain: zone.gain,
            minVelocity: zone.minVelocity, maxVelocity: zone.maxVelocity, group: zone.group,
            seqLength: zone.seqLength, seqPosition: zone.seqPosition, randMin: zone.randMin,
            randMax: zone.randMax, tuneCents: zone.tuneCents, pan: zone.pan,
            ampVelTrack: zone.ampVelTrack, oneShot: zone.oneShot, startFrame: zone.startFrame,
            endFrame: zone.endFrame, attack: zone.attack, decay: zone.decay, sustain: zone.sustain,
            release: zone.release, loopMode: zone.loopMode, loopStart: zone.loopStart,
            loopEnd: zone.loopEnd, crossfade: zone.crossfade, reverse: zone.reverse,
            chokeGroup: zone.chokeGroup)
    }

    // MARK: Reading

    /// A `sampler` object over a fresh `SamplerParams()`, the base a track with
    /// no Sampler yet gives the wire. Every number is range-checked (REFUSED
    /// out of range from a same-version file, where the wire clamps most of
    /// them), and every number READS BACK from the built value as written, so a
    /// span written upside down (the model swaps it), an end frame at or before
    /// its start (the model raises it), a round-robin position past its length
    /// or a crossfade that can never change a gain (the model drops it) is
    /// refused rather than stored as something else.
    mutating func readSampler(_ json: TemplateJSON, _ path: String) throws -> SamplerParams {
        var object = try self.object(json, path)
        // A key the wire KNOWS, so it is refused in words in every version, never
        // skipped as unknown (skipping it would drop the zones it carries).
        if object["zonePatches"] != nil {
            throw TemplateRefusal(
                code: .invalidValue, path: Self.join(path, "zonePatches"),
                message: "a template holds a Sampler's whole zone map as \"zones\". \"zonePatches\" "
                    + "changes zones a track already has, and a template's track has none yet.")
        }
        object = try knownKeys(object, Self.samplerKeys, path, "A Sampler setup")
        var zones: [SamplerZone] = []
        if let raw = object["zones"] {
            let zonesPath = Self.join(path, "zones")
            for (position, entry) in try array(raw, zonesPath).enumerated() {
                zones.append(try readSamplerZone(entry, Self.index(zonesPath, position),
                                                 index: position))
            }
        }
        var written: [String: Double] = [:]
        let fresh = SamplerParams()
        let oneShot = try object["oneShot"].map { try bool($0, Self.join(path, "oneShot")) }
        let attack = try samplerNumber(object, "attack", SamplerParams.attackRange, path, &written)
        let release = try samplerNumber(object, "release", SamplerParams.releaseRange, path,
                                        &written)
        let gain = try samplerNumber(object, "gain", SamplerParams.gainRange, path, &written)
        let modDepth = try samplerNumber(object, "expressionModDepth",
                                         SamplerParams.expressionModDepthRange, path, &written)
        let filterDepth = try samplerNumber(object, "expressionFilterDepth",
                                            SamplerParams.expressionFilterDepthRange, path,
                                            &written)
        let filterCC = try samplerInteger(object, "expressionFilterCC",
                                          MIDIControllerType.cc(controller: 0).valueRange, path,
                                          &written)
        let bend = try samplerNumber(object, "bendRangeSemitones",
                                     SamplerParams.bendRangeSemitonesRange, path, &written)
        let voiceMode = try samplerVoiceMode(object["voiceMode"], Self.join(path, "voiceMode"))
        let decay = try samplerNumber(object, "decay", SamplerZone.decayRange, path, &written)
        let sustain = try samplerNumber(object, "sustain", SamplerZone.sustainRange, path,
                                        &written)
        let pedalHoldLimit = try samplerInteger(object, "pedalHoldLimit",
                                                SamplerParams.pedalHoldLimitRange, path, &written)
        let glideTime = try samplerNumber(object, "glideTime", SamplerParams.glideTimeRange, path,
                                          &written)
        let glideMode = try samplerGlideMode(object["glideMode"], Self.join(path, "glideMode"))
        let sampler = SamplerParams(
            zones: zones, oneShot: oneShot ?? fresh.oneShot, attack: attack ?? fresh.attack,
            release: release ?? fresh.release, gain: gain ?? fresh.gain,
            expressionModDepth: modDepth, expressionFilterDepth: filterDepth,
            expressionFilterCC: filterCC, bendRangeSemitones: bend, voiceMode: voiceMode,
            decay: decay, sustain: sustain, pedalHoldLimit: pedalHoldLimit, glideTime: glideTime,
            glideMode: glideMode)
        try samplerReadBack(written, path) { Self.samplerReading(sampler, $0) }
        return sampler
    }

    /// One zone. Its id is the placeholder for `index` (see `samplerZoneID`).
    mutating func readSamplerZone(_ json: TemplateJSON, _ path: String,
                                  index: Int) throws -> SamplerZone {
        var object = try self.object(json, path)
        // The wire honours a zone id only when it already names a zone on THAT
        // track; a template's track is new, so an id could never be kept.
        if object["id"] != nil {
            throw TemplateRefusal(
                code: .invalidValue, path: Self.join(path, "id"),
                message: "a template's Sampler zones get new ids every time the template is "
                    + "added, so a zone can't keep one. Leave out \"id\".")
        }
        object = try knownKeys(object, Self.samplerZoneKeys, path, "A Sampler zone")
        guard let rawPath = object["path"] else {
            throw Self.missing(Self.join(path, "path"),
                               "the zone's sound file, by its full path, like "
                                + "\"/Users/me/Samples/kick.wav\"")
        }
        let file = try samplerFile(rawPath, Self.join(path, "path"))
        var written: [String: Double] = [:]
        let pitch = SamplerZone.pitchRange
        let velocity = SamplerZone.velocityRange
        let rootPitch = try samplerInteger(object, "rootPitch", pitch, path, &written)
        let minPitch = try samplerInteger(object, "minPitch", pitch, path, &written)
        let maxPitch = try samplerInteger(object, "maxPitch", pitch, path, &written)
        let gain = try samplerNumber(object, "gain", SamplerZone.gainRange, path, &written)
        let minVelocity = try samplerInteger(object, "minVelocity", velocity, path, &written)
        let maxVelocity = try samplerInteger(object, "maxVelocity", velocity, path, &written)
        let group = try samplerCount(object, "group", minimum: 0, path, &written)
        let seqLength = try samplerCount(object, "seqLength", minimum: 1, path, &written)
        let seqPosition = try samplerCount(object, "seqPosition", minimum: 1, path, &written)
        let randMin = try samplerNumber(object, "randMin", SamplerZone.randRange, path, &written)
        let randMax = try samplerNumber(object, "randMax", SamplerZone.randRange, path, &written)
        let tuneCents = try samplerNumber(object, "tuneCents", SamplerZone.tuneCentsRange, path,
                                          &written)
        let pan = try samplerNumber(object, "pan", SamplerZone.panRange, path, &written)
        let ampVelTrack = try samplerNumber(object, "ampVelTrack", SamplerZone.ampVelTrackRange,
                                            path, &written)
        let oneShot = try object["oneShot"].map { try bool($0, Self.join(path, "oneShot")) }
        let startFrame = try samplerCount(object, "startFrame", minimum: 0, path, &written)
        let endFrame = try samplerCount(object, "endFrame", minimum: 0, path, &written)
        let attack = try samplerNumber(object, "attack", SamplerParams.attackRange, path, &written)
        let decay = try samplerNumber(object, "decay", SamplerZone.decayRange, path, &written)
        let sustain = try samplerNumber(object, "sustain", SamplerZone.sustainRange, path,
                                        &written)
        let release = try samplerNumber(object, "release", SamplerParams.releaseRange, path,
                                        &written)
        let loopMode = try samplerLoopMode(object["loopMode"], Self.join(path, "loopMode"))
        let loopStart = try samplerCount(object, "loopStart", minimum: 0, path, &written)
        let loopEnd = try samplerCount(object, "loopEnd", minimum: 0, path, &written)
        var crossfadeWritten: [String: Double] = [:]
        let crossfade = try object["crossfade"].map {
            try readSamplerCrossfade($0, Self.join(path, "crossfade"), &crossfadeWritten)
        }
        let reverse = try object["reverse"].map { try bool($0, Self.join(path, "reverse")) }
        let chokeGroup = try samplerInteger(object, "chokeGroup", SamplerZone.chokeGroupRange,
                                            path, &written)
        let fresh = SamplerZone(audioFileURL: URL(fileURLWithPath: file))
        let zone = SamplerZone(
            id: Self.samplerZoneID(index), audioFileURL: URL(fileURLWithPath: file),
            rootPitch: rootPitch ?? fresh.rootPitch, minPitch: minPitch ?? fresh.minPitch,
            maxPitch: maxPitch ?? fresh.maxPitch, gain: gain ?? fresh.gain,
            minVelocity: minVelocity, maxVelocity: maxVelocity, group: group,
            seqLength: seqLength, seqPosition: seqPosition, randMin: randMin, randMax: randMax,
            tuneCents: tuneCents, pan: pan, ampVelTrack: ampVelTrack, oneShot: oneShot,
            startFrame: startFrame, endFrame: endFrame, attack: attack, decay: decay,
            sustain: sustain, release: release, loopMode: loopMode, loopStart: loopStart,
            loopEnd: loopEnd, crossfade: crossfade, reverse: reverse, chokeGroup: chokeGroup)
        try samplerReadBack(written, path) { Self.samplerZoneReading(zone, $0) }
        try samplerReadBack(crossfadeWritten, Self.join(path, "crossfade")) { key in
            Self.samplerCrossfadeReading(zone.crossfade, key).map { .number(Double($0)) }
        }
        return zone
    }

    /// A zone's `crossfade` object. Its written members are recorded for the
    /// zone's read-back: a crossfade that can never change a gain (a CC bound
    /// with no controller) is DROPPED by the model, and that is refused.
    mutating func readSamplerCrossfade(_ json: TemplateJSON, _ path: String,
                                       _ written: inout [String: Double]) throws -> SamplerCrossfade {
        var object = try self.object(json, path)
        object = try knownKeys(object, Self.samplerCrossfadeKeys, path, "A zone's crossfade")
        var values: [String: Int] = [:]
        for key in Self.samplerCrossfadeKeys {
            values[key] = try samplerInteger(object, key, SamplerZone.velocityRange, path, &written)
        }
        return SamplerCrossfade(
            controller: values["controller"], ccInLo: values["ccInLo"], ccInHi: values["ccInHi"],
            ccOutLo: values["ccOutLo"], ccOutHi: values["ccOutHi"], velInLo: values["velInLo"],
            velInHi: values["velInHi"], velOutLo: values["velOutLo"], velOutHi: values["velOutHi"])
    }

    /// A zone's sound file: a full path (`/…`), a path from the home folder
    /// (`~/…`, expanded as the wire expands it), or a sample the app ships
    /// (`builtin:<name>`, resolved by `BundledSamples`, the wire's own resolver).
    /// A relative path is refused: the wire would read it against the app's
    /// working folder. Whether the FILE exists is the store's question at apply
    /// time — a missing one refuses, naming it — never the codec's.
    func samplerFile(_ json: TemplateJSON, _ path: String) throws -> String {
        let text = try string(json, path)
        if BundledSamples.isBundledName(text) {
            guard let entry = BundledSamples.entry(named: text) else {
                throw TemplateRefusal(
                    code: .invalidValue, path: path,
                    message: "there is no sample called '\(text)' in DAW Pro. The samples it comes "
                        + "with are: \(BundledSamples.knownNames.joined(separator: ", ")).")
            }
            guard let url = try? BundledSamples.resolve(entry.wireName) else {
                throw TemplateRefusal(
                    code: .invalidValue, path: path,
                    message: "the sample '\(entry.wireName)' is missing from this copy of DAW Pro.")
            }
            return url.path
        }
        let expanded = (text as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw TemplateRefusal(
                code: .invalidValue, path: path,
                message: "a Sampler zone names its sound file by its full path, starting with \"/\" "
                    + "(or \"~/\" for your home folder); '\(text)' is not one.")
        }
        return expanded
    }

    /// An optional number under `key`, in `range`; remembered for the read-back.
    mutating func samplerNumber(_ object: [String: TemplateJSON], _ key: String,
                                _ range: ClosedRange<Double>, _ path: String,
                                _ written: inout [String: Double]) throws -> Double? {
        guard let raw = object[key] else { return nil }
        let keyPath = Self.join(path, key)
        let value = try ranged(try number(raw, keyPath), range, keyPath, key)
        written[key] = value
        return value
    }

    /// An optional whole number under `key`, in `range`; remembered for the
    /// read-back. A fraction is refused (the wire refuses one too).
    mutating func samplerInteger(_ object: [String: TemplateJSON], _ key: String,
                                 _ range: ClosedRange<Int>, _ path: String,
                                 _ written: inout [String: Double]) throws -> Int? {
        guard let raw = object[key] else { return nil }
        let keyPath = Self.join(path, key)
        let value = try ranged(try integer(raw, keyPath), range, keyPath, key)
        written[key] = Double(value)
        return value
    }

    /// An optional whole number with only a FLOOR (a group, a frame, a
    /// round-robin count); remembered for the read-back.
    mutating func samplerCount(_ object: [String: TemplateJSON], _ key: String, minimum: Int,
                               _ path: String, _ written: inout [String: Double]) throws -> Int? {
        guard let raw = object[key] else { return nil }
        let keyPath = Self.join(path, key)
        var value = try integer(raw, keyPath)
        if value < minimum {
            try refuseOrSkip(
                TemplateRefusal(code: .outOfRange, path: keyPath,
                                message: "\(key) is a whole number from \(minimum) up; \(value) "
                                    + "would become \(minimum)."),
                .valueClamped,
                "\(key) was \(value), below \(minimum), so it was set to \(minimum).")
            value = minimum
        }
        written[key] = Double(value)
        return value
    }

    /// §5.3's read-back over every number written: `reading` gives what the
    /// built value holds under each key.
    mutating func samplerReadBack(_ written: [String: Double], _ path: String,
                                  reading: (String) -> TemplateJSON?) throws {
        for key in written.keys.sorted() {
            guard let value = written[key] else { continue }
            var read: Double?
            if case .number(let number)? = reading(key) { read = number }
            _ = try readBack(written: value, read: read, Self.join(path, key), key)
        }
    }

    /// `"poly"`, `"mono"` or `"legato"`, any case, as the wire takes it; null
    /// means "not set", as on the wire.
    mutating func samplerVoiceMode(_ json: TemplateJSON?, _ path: String) throws -> SamplerVoiceMode? {
        guard let json else { return nil }
        if case .null = json { return nil }
        let text = try string(json, path)
        if let mode = SamplerVoiceMode(rawValue: text.lowercased()) { return mode }
        let known = SamplerVoiceMode.allCases.map(\.rawValue).joined(separator: ", ")
        try refuseOrSkip(
            TemplateRefusal(code: .unknownSetting, path: path,
                            message: "a Sampler's voice mode is one of: \(known); '\(text)' is not "
                                + "one."),
            .unknownSettingSkipped,
            "the voice mode '\(text)' comes from a newer version of DAW Pro, so the Sampler "
                + "keeps its default.")
        return nil
    }

    /// `"constantTime"` or `"constantRate"`, any case, as the wire takes it;
    /// null means "not set".
    mutating func samplerGlideMode(_ json: TemplateJSON?, _ path: String) throws -> SamplerGlideMode? {
        guard let json else { return nil }
        if case .null = json { return nil }
        let text = try string(json, path)
        if let mode = SamplerGlideMode.allCases.first(where: {
            $0.rawValue.lowercased() == text.lowercased()
        }) { return mode }
        let known = SamplerGlideMode.allCases.map(\.rawValue).joined(separator: ", ")
        try refuseOrSkip(
            TemplateRefusal(code: .unknownSetting, path: path,
                            message: "a Sampler's glide mode is one of: \(known); '\(text)' is not "
                                + "one."),
            .unknownSettingSkipped,
            "the glide mode '\(text)' comes from a newer version of DAW Pro, so the Sampler "
                + "keeps its default.")
        return nil
    }

    /// `"sustain"` or `"continuous"`, exactly, as the wire takes it.
    mutating func samplerLoopMode(_ json: TemplateJSON?, _ path: String) throws -> SamplerLoopMode? {
        guard let json else { return nil }
        let text = try string(json, path)
        if let mode = SamplerLoopMode(rawValue: text) { return mode }
        try refuseOrSkip(
            TemplateRefusal(code: .unknownSetting, path: path,
                            message: "a zone's loop mode is \"sustain\" or \"continuous\"; '\(text)' "
                                + "is not one."),
            .unknownSettingSkipped,
            "the loop mode '\(text)' comes from a newer version of DAW Pro, so that zone does "
                + "not loop.")
        return nil
    }

    // MARK: Writing, and the one table the read-back shares

    /// What `sampler` holds under `key`, as the JSON a template writes; nil
    /// when the field is unset. The writer and the reader's read-back both use
    /// this ONE table.
    static func samplerReading(_ sampler: SamplerParams, _ key: String) -> TemplateJSON? {
        func number(_ value: Double?) -> TemplateJSON? { value.map { .number($0) } }
        func whole(_ value: Int?) -> TemplateJSON? { value.map { .number(Double($0)) } }
        switch key {
        case "zones":
            return sampler.zones.isEmpty ? nil : .array(sampler.zones.map(samplerZoneObject))
        case "oneShot": return .bool(sampler.oneShot)
        case "attack": return .number(sampler.attack)
        case "release": return .number(sampler.release)
        case "gain": return .number(sampler.gain)
        case "expressionModDepth": return number(sampler.expressionModDepth)
        case "expressionFilterDepth": return number(sampler.expressionFilterDepth)
        case "expressionFilterCC": return whole(sampler.expressionFilterCC)
        case "bendRangeSemitones": return number(sampler.bendRangeSemitones)
        case "voiceMode": return sampler.voiceMode.map { .string($0.rawValue) }
        case "decay": return number(sampler.decay)
        case "sustain": return number(sampler.sustain)
        case "pedalHoldLimit": return whole(sampler.pedalHoldLimit)
        case "glideTime": return number(sampler.glideTime)
        case "glideMode": return sampler.glideMode.map { .string($0.rawValue) }
        default: return nil
        }
    }

    /// What `zone` holds under `key` (see `samplerReading`).
    static func samplerZoneReading(_ zone: SamplerZone, _ key: String) -> TemplateJSON? {
        func number(_ value: Double?) -> TemplateJSON? { value.map { .number($0) } }
        func whole(_ value: Int?) -> TemplateJSON? { value.map { .number(Double($0)) } }
        func flag(_ value: Bool?) -> TemplateJSON? { value.map { .bool($0) } }
        switch key {
        case "path": return .string(samplerPathText(zone.audioFileURL))
        case "rootPitch": return whole(zone.rootPitch)
        case "minPitch": return whole(zone.minPitch)
        case "maxPitch": return whole(zone.maxPitch)
        case "gain": return number(zone.gain)
        case "minVelocity": return whole(zone.minVelocity)
        case "maxVelocity": return whole(zone.maxVelocity)
        case "group": return whole(zone.group)
        case "seqLength": return whole(zone.seqLength)
        case "seqPosition": return whole(zone.seqPosition)
        case "randMin": return number(zone.randMin)
        case "randMax": return number(zone.randMax)
        case "tuneCents": return number(zone.tuneCents)
        case "pan": return number(zone.pan)
        case "ampVelTrack": return number(zone.ampVelTrack)
        case "oneShot": return flag(zone.oneShot)
        case "startFrame": return whole(zone.startFrame)
        case "endFrame": return whole(zone.endFrame)
        case "attack": return number(zone.attack)
        case "decay": return number(zone.decay)
        case "sustain": return number(zone.sustain)
        case "release": return number(zone.release)
        case "loopMode": return zone.loopMode.map { .string($0.rawValue) }
        case "loopStart": return whole(zone.loopStart)
        case "loopEnd": return whole(zone.loopEnd)
        case "crossfade":
            guard let crossfade = zone.crossfade else { return nil }
            var members: [String: TemplateJSON] = [:]
            for member in samplerCrossfadeKeys {
                if let value = samplerCrossfadeReading(crossfade, member) {
                    members[member] = .number(Double(value))
                }
            }
            return .object(members)
        case "reverse": return flag(zone.reverse)
        case "chokeGroup": return whole(zone.chokeGroup)
        default: return nil
        }
    }

    /// What a zone's crossfade holds under `key`.
    static func samplerCrossfadeReading(_ crossfade: SamplerCrossfade?, _ key: String) -> Int? {
        guard let crossfade else { return nil }
        switch key {
        case "controller": return crossfade.controller
        case "ccInLo": return crossfade.ccInLo
        case "ccInHi": return crossfade.ccInHi
        case "ccOutLo": return crossfade.ccOutLo
        case "ccOutHi": return crossfade.ccOutHi
        case "velInLo": return crossfade.velInLo
        case "velInHi": return crossfade.velInHi
        case "velOutLo": return crossfade.velOutLo
        case "velOutHi": return crossfade.velOutHi
        default: return nil
        }
    }

    /// A Sampler as the template writes it: each setting whose reading differs
    /// from a fresh `SamplerParams()`'s, and every zone. Never written: zone ids
    /// and the provenance trio (`sourcePath`, `displayName`, `sliceKit`).
    static func samplerObject(_ sampler: SamplerParams) -> TemplateJSON {
        let fresh = SamplerParams()
        var object: [String: TemplateJSON] = [:]
        for key in samplerKeys {
            guard let value = samplerReading(sampler, key),
                  value != samplerReading(fresh, key) else { continue }
            object[key] = value
        }
        return .object(object)
    }

    /// One zone as the template writes it: its file, and each field whose
    /// reading differs from a zone made with the wire's defaults (root 60,
    /// span 0…127, gain 1, every optional unset). An optional set to its
    /// "neutral" value is still written: `pan` 0 is the −3 dB centre, not the
    /// unset dual-mono of `nil`.
    static func samplerZoneObject(_ zone: SamplerZone) -> TemplateJSON {
        let fresh = SamplerZone(id: zone.id, audioFileURL: zone.audioFileURL)
        var object: [String: TemplateJSON] = [:]
        for key in samplerZoneKeys {
            guard let value = samplerZoneReading(zone, key) else { continue }
            if key != "path", value == samplerZoneReading(fresh, key) { continue }
            object[key] = value
        }
        return .object(object)
    }

    /// A zone's file as a template writes it: `builtin:<name>` for a sample the
    /// app ships (so the template works wherever the app is installed), else
    /// the full path.
    static func samplerPathText(_ url: URL) -> String {
        let path = url.path
        for entry in BundledSamples.catalog {
            if let bundled = try? BundledSamples.resolve(entry.wireName), bundled.path == path {
                return entry.wireName
            }
        }
        return path
    }
}
