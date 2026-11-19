import Foundation

// m39-tpl-1 — how a track's `modulation` block is read (design §4.2, §4.5).
//
// Sources go through `ModulationSourceParams.apply(_:to:)` over the kind's
// defaults: already pure, already refuses unknown names, already clamps and
// warns. Its warnings pass through — except `modulationParamClamped`, which is
// a value out of range and is treated like one (refused under a strict read).
// Its valid NAMES are read from its own refusal, never copied here.
//
// Routes are read for their shape and names only. Whether a target may be
// modulated at all (discrete, hosted, a send level) and the 64-slot budget are
// `ModulationRules`, which the builder runs on the built track.

extension TemplateReader {
    static let modulationKeys = ["sources", "routes"]
    static let modSourceKeys = ["key", "kind", "name", "params"]
    static let modRouteKeys = ["source", "target", "depth", "enabled"]
    /// The keys each target type takes. `sendLevel` is deliberately absent.
    static let modTargetKeys: [String: [String]] = [
        "volume": ["type"],
        "pan": ["type"],
        "instrumentParam": ["type", "param"],
        "effectParam": ["type", "insert", "param"],
    ]

    /// The setting names `ModulationSourceParams.apply(_:to:)` accepts for
    /// `kind`, read from the applier's OWN refusal of a name no kind has, so
    /// the lists live in one place. The applier checks names before anything
    /// else, for every kind; `TrackSetTemplateCodecTests` positive-controls it
    /// (an LFO has eight).
    static func modulationSettingNames(for kind: ModulationSourceKind) -> [String] {
        do {
            _ = try ModulationSourceParams.apply(["\u{1}probe": .null], to: .defaults(for: kind))
        } catch let ModulationError.unknownModulationParam(_, _, valid) {
            return valid
        } catch {
            return []
        }
        return []
    }

    mutating func readModulation(_ json: TemplateJSON, _ path: String, track: TemplateTrack,
                                 skippedInserts: Set<String>)
        throws -> (sources: [TemplateModSource], routes: [TemplateModRoute]) {
        var object = try self.object(json, path)
        object = try knownKeys(object, Self.modulationKeys, path, "A track's modulation")
        var sources: [TemplateModSource] = []
        var sourceKeys: Set<String> = []
        var skippedSources: Set<String> = []
        if let raw = object["sources"] {
            let sourcesPath = Self.join(path, "sources")
            for (position, entry) in try array(raw, sourcesPath).enumerated() {
                let sourcePath = Self.index(sourcesPath, position)
                let (key, source) = try readModSource(entry, sourcePath)
                guard sourceKeys.insert(key).inserted else {
                    throw TemplateRefusal(
                        code: .duplicateKey, path: Self.join(sourcePath, "key"),
                        message: "another modulation source on this track already uses the "
                            + "key '\(key)'.")
                }
                if let source { sources.append(source) } else { skippedSources.insert(key) }
            }
        }
        var routes: [TemplateModRoute] = []
        if let raw = object["routes"] {
            let routesPath = Self.join(path, "routes")
            for (position, entry) in try array(raw, routesPath).enumerated() {
                if let route = try readModRoute(entry, Self.index(routesPath, position),
                                                track: track, skippedSources: skippedSources,
                                                skippedInserts: skippedInserts) {
                    routes.append(route)
                }
            }
        }
        return (sources, routes)
    }

    // MARK: - Sources

    /// One source. Returns its key, and nil for the source when a lenient read
    /// skips a source kind this build does not know.
    mutating func readModSource(_ json: TemplateJSON, _ path: String)
        throws -> (key: String, source: TemplateModSource?) {
        var object = try self.object(json, path)
        object = try knownKeys(object, Self.modSourceKeys, path, "A modulation source")
        guard let rawKey = object["key"] else {
            throw Self.missing(Self.join(path, "key"), "the source's key, which routes use")
        }
        let key = try self.key(rawKey, Self.join(path, "key"))
        guard let rawKind = object["kind"] else {
            throw Self.missing(Self.join(path, "kind"), "the source's kind, like \"lfo\"")
        }
        let kindName = try string(rawKind, Self.join(path, "kind"))
        guard let kind = ModulationSourceKind(rawValue: kindName) else {
            let known = ModulationSourceKind.allCases.map(\.rawValue).joined(separator: ", ")
            try refuseOrSkip(
                TemplateRefusal(code: .unknownKind, path: Self.join(path, "kind"),
                                message: "there is no modulation source called '\(kindName)'. "
                                    + "The sources are: \(known)."),
                .unknownModulationSkipped,
                "the modulation source '\(kindName)' comes from a newer version of DAW Pro, so "
                    + "it was left out, with every route that followed it.")
            return (key, nil)
        }
        let name = try object["name"].map {
            try label($0, Self.join(path, "name"), max: TrackSetTemplateCodec.maxNameLength,
                      "A modulation source's name")
        }
        var values: [String: ModulationParamValue] = [:]
        let paramsPath = Self.join(path, "params")
        if let raw = object["params"] {
            let params = try self.object(raw, paramsPath)
            let valid = Self.modulationSettingNames(for: kind)
            for setting in params.keys.sorted() {
                let settingPath = Self.join(paramsPath, setting)
                guard valid.contains(setting) else {
                    try refuseOrSkip(
                        TemplateRefusal(code: .unknownSetting, path: settingPath,
                                        message: "a \(kind.rawValue) source has no setting "
                                            + "called '\(setting)'; its settings are: "
                                            + "\(valid.joined(separator: ", "))."),
                        .unknownSettingSkipped,
                        "the setting '\(setting)' comes from a newer version of DAW Pro, so it "
                            + "was left out.")
                    continue
                }
                values[setting] = try modulationValue(params[setting]!, settingPath)
            }
        }
        let applied: (params: ModulationSourceParams, warnings: [String])
        do {
            applied = try ModulationSourceParams.apply(values, to: .defaults(for: kind))
        } catch {
            throw TemplateRefusal(code: .invalidValue, path: paramsPath,
                                  message: (error as? LocalizedError)?.errorDescription
                                    ?? String(describing: error))
        }
        // W9-W45: `apply` tells a caller who sets `stepDivision` that `rateHz` is
        // unused. A template that names NO `rateHz` set no such value, so that
        // sentence would only be noise on every read of a synced source; one
        // that DOES carry both still hears it.
        let unusedRateNote = values["rateHz"] == nil
            ? TempoSync.inertRateNote(for: applied.params) : nil
        for warning in applied.warnings {
            let (code, sentence) = Self.splitModulationWarning(warning)
            if code == ModulationWarning.paramIgnored, sentence == unusedRateNote { continue }
            if code == ModulationWarning.paramClamped {
                try refuseOrSkip(
                    TemplateRefusal(code: .outOfRange, path: paramsPath,
                                    message: "a setting is outside what it accepts, and a "
                                        + "template refuses rather than clamps: \(sentence)"),
                    .valueClamped, sentence)
            } else {
                warn(.modulationSourceWarned, paramsPath, sentence)
            }
        }
        return (key, TemplateModSource(key: key, kind: kind, name: name, params: applied.params))
    }

    /// `"modulationParamClamped: rateHz was clamped …"` → the code and the
    /// sentence. A warning with no code is all sentence.
    static func splitModulationWarning(_ warning: String) -> (code: String, sentence: String) {
        guard let colon = warning.range(of: ": ") else { return ("", warning) }
        return (String(warning[..<colon.lowerBound]), String(warning[colon.upperBound...]))
    }

    /// A JSON value as the applier's own value type.
    func modulationValue(_ json: TemplateJSON, _ path: String) throws -> ModulationParamValue {
        switch json {
        case .number(let number): return .number(number)
        case .string(let text): return .string(text)
        case .bool(let flag): return .bool(flag)
        case .null: return .null
        case .array(let items):
            var numbers: [Double] = []
            for (position, item) in items.enumerated() {
                numbers.append(try number(item, Self.index(path, position)))
            }
            return .numbers(numbers)
        case .object:
            throw Self.wrongType(path, "a number, text, true or false, or a list of numbers",
                                 json)
        }
    }

    // MARK: - Routes

    /// One route. Nil when a lenient read skips it: an unknown target type, an
    /// unknown setting name, or a source or effect that was itself skipped.
    mutating func readModRoute(_ json: TemplateJSON, _ path: String, track: TemplateTrack,
                               skippedSources: Set<String>,
                               skippedInserts: Set<String>) throws -> TemplateModRoute? {
        var object = try self.object(json, path)
        object = try knownKeys(object, Self.modRouteKeys, path, "A modulation route")
        guard let rawSource = object["source"] else {
            throw Self.missing(Self.join(path, "source"), "the key of the source it follows")
        }
        let source = try key(rawSource, Self.join(path, "source"))
        let targetPath = Self.join(path, "target")
        guard let rawTarget = object["target"] else {
            throw Self.missing(targetPath, "what it moves, like {\"type\": \"volume\"}")
        }
        var targetObject = try self.object(rawTarget, targetPath)
        let typePath = Self.join(targetPath, "type")
        guard let rawType = targetObject["type"] else {
            throw Self.missing(typePath, "\"volume\", \"pan\", \"instrumentParam\" or "
                + "\"effectParam\"")
        }
        let type = try string(rawType, typePath)
        guard let allowed = Self.modTargetKeys[type] else {
            let message = type == "sendLevel"
                ? "a send level can't be modulated. Modulate the track's volume instead."
                : "there is no modulation target called '\(type)'. A route moves \"volume\", "
                    + "\"pan\", an \"instrumentParam\" or an \"effectParam\"."
            try refuseOrSkip(
                TemplateRefusal(code: .unknownKind, path: typePath, message: message),
                .unknownModulationSkipped,
                "this route moves something only a newer version of DAW Pro can modulate, so "
                    + "it was left out.")
            return nil
        }
        targetObject = try knownKeys(targetObject, allowed, targetPath, "This target")
        let depthPath = Self.join(path, "depth")
        guard let rawDepth = object["depth"] else {
            throw Self.missing(depthPath, "how far it moves, from -1 to 1")
        }
        let depth = try ranged(try number(rawDepth, depthPath), ModulationRoute.depthRange,
                               depthPath, "depth")
        let enabled = try object["enabled"].map { try bool($0, Self.join(path, "enabled")) }
            ?? true
        if skippedSources.contains(source) {
            warn(.unknownModulationSkipped, Self.join(path, "source"),
                 "this route followed '\(source)', which this version of DAW Pro can't add, "
                    + "so it was left out.")
            return nil
        }
        let target: TemplateTarget
        switch type {
        case "volume":
            target = .volume
        case "pan":
            target = .pan
        case "instrumentParam":
            let param = try settingName(targetObject["param"], Self.join(targetPath, "param"))
            guard try knownInstrumentParam(param, track: track, Self.join(targetPath, "param"))
            else { return nil }
            target = .instrumentParam(param: param)
        default:
            let insertPath = Self.join(targetPath, "insert")
            guard let rawInsert = targetObject["insert"] else {
                throw Self.missing(insertPath, "the key of the effect whose setting it moves")
            }
            let insertKey = try key(rawInsert, insertPath)
            let param = try settingName(targetObject["param"], Self.join(targetPath, "param"))
            if skippedInserts.contains(insertKey) {
                warn(.unknownEffectSkipped, insertPath,
                     "this route moved a setting of '\(insertKey)', which this version of DAW "
                        + "Pro can't add, so it was left out.")
                return nil
            }
            // An insert key that resolves: the setting must be one the effect
            // has. A key that does NOT resolve is the builder's refusal.
            if let insert = track.inserts.first(where: { $0.key == insertKey }) {
                let specs = EffectParamSpec.specs(for: insert.kind)
                if !specs.contains(where: { $0.name == param }) {
                    let names = specs.map(\.name).joined(separator: ", ")
                    try refuseOrSkip(
                        TemplateRefusal(code: .unknownSetting,
                                        path: Self.join(targetPath, "param"),
                                        message: "a \(insert.kind.rawValue) effect has no "
                                            + "setting called '\(param)'; its settings are: "
                                            + "\(names)."),
                        .unknownSettingSkipped,
                        "this route moved the setting '\(param)', which comes from a newer "
                            + "version of DAW Pro, so it was left out.")
                    return nil
                }
            }
            target = .effectParam(insert: insertKey, param: param)
        }
        return TemplateModRoute(source: source, target: target, depth: depth, enabled: enabled)
    }

    /// A route's `param`: required, and not blank.
    func settingName(_ value: TemplateJSON?, _ path: String) throws -> String {
        guard let value else {
            throw Self.missing(path, "the name of the setting it moves")
        }
        let text = try string(value, path)
        guard !text.isEmpty else {
            throw TemplateRefusal(code: .invalidValue, path: path,
                                  message: "the setting's name can't be blank.")
        }
        return text
    }

    /// Whether an instrument-parameter route names a parameter the track's
    /// instrument HAS (modulatable or discrete). Only judged where the track
    /// has a built-in instrument: a missing or hosted instrument is refused by
    /// `ModulationRules` in the builder, with its own reason.
    mutating func knownInstrumentParam(_ param: String, track: TemplateTrack,
                                       _ path: String) throws -> Bool {
        guard track.kind == .instrument else { return true }
        let kind = (track.instrument ?? .default).kind
        guard !InstrumentParamSpec.isHosted(kind) else { return true }
        let modulatable = InstrumentParamSpec.specs(for: kind).map(\.name)
        let discrete = InstrumentParamSpec.discreteParamNames(for: kind)
        guard !modulatable.contains(param), !discrete.contains(param) else { return true }
        let names = modulatable.isEmpty
            ? "it has none that can be modulated"
            : "the ones that can be modulated are: \(modulatable.joined(separator: ", "))"
        try refuseOrSkip(
            TemplateRefusal(code: .unknownSetting, path: path,
                            message: "the \(kind.rawValue) instrument has no setting called "
                                + "'\(param)'; \(names)."),
            .unknownSettingSkipped,
            "this route moved the instrument setting '\(param)', which comes from a newer "
                + "version of DAW Pro, so it was left out.")
        return false
    }
}
