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
            if object["sampler"] != nil {
                // TODO(TPL-5): read the `sampler` object — the same object
                // `track.setInstrument` takes — with a parity test against the
                // wire's `parseSampler`, exactly as the drum kit has one against
                // `parseDrumKit`. Until then it is refused, never half-read.
                throw TemplateRefusal(
                    code: .notSupported, path: Self.join(path, "sampler"),
                    message: "templates can't hold a Sampler's sound files yet. Leave out "
                        + "\"sampler\" to add an empty Sampler you can fill later.")
            }
            return InstrumentDescriptor(kind: .sampler)
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
