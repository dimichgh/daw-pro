import Foundation

// m39-tpl-1 — the reader behind `TrackSetTemplateCodec.decode`: the template,
// its tracks, inserts and sends. Instruments are in
// `TrackSetTemplateCodecInstruments.swift`, modulation in
// `TrackSetTemplateCodecModulation.swift`. See `TrackSetTemplateCodec` for the
// rules every reader here follows.

/// One decode. Carries whether the file is read strictly (its
/// `formatVersion` is this build's, or omitted) or leniently (a newer
/// writer's), and the warnings a lenient read collects.
struct TemplateReader {
    let origin: TrackSetTemplateCodec.Origin
    /// True for a file whose `formatVersion` is NEWER than this build's: a
    /// problem the reader can blame on a newer writer is skipped with a coded
    /// warning instead of refused (§4.7).
    private(set) var lenient = false
    private(set) var warnings: [TemplateWarning] = []
    /// Each kept insert's position in the FILE, per track path, so a warning
    /// about an insert names it where the author wrote it even after an
    /// earlier insert was skipped.
    private var insertFilePositions: [String: [Int]] = [:]

    init(origin: TrackSetTemplateCodec.Origin) {
        self.origin = origin
    }

    // MARK: - The version rule

    /// Refuses under a strict read. Under a lenient read, records `code` with
    /// `message` at the refusal's path and returns, so the caller skips.
    mutating func refuseOrSkip(_ refusal: TemplateRefusal, _ code: TemplateWarning.Code,
                               _ message: String) throws {
        guard lenient else { throw refusal }
        warnings.append(TemplateWarning(code: code, path: refusal.path, message: message))
    }

    mutating func warn(_ code: TemplateWarning.Code, _ path: String, _ message: String) {
        warnings.append(TemplateWarning(code: code, path: path, message: message))
    }

    // MARK: - Paths

    static func join(_ base: String, _ key: String) -> String {
        base.isEmpty ? key : "\(base).\(key)"
    }

    static func index(_ base: String, _ position: Int) -> String {
        "\(base)[\(position)]"
    }

    // MARK: - Typed reads (a wrong JSON type is refused in BOTH modes)

    static func wrongType(_ path: String, _ expected: String, _ got: TemplateJSON) -> TemplateRefusal {
        TemplateRefusal(code: .wrongType, path: path,
                        message: "this must be \(expected), not \(got.typeName).")
    }

    static func missing(_ path: String, _ what: String) -> TemplateRefusal {
        TemplateRefusal(code: .missingKey, path: path, message: "this is required: \(what).")
    }

    func object(_ value: TemplateJSON, _ path: String) throws -> [String: TemplateJSON] {
        guard case .object(let object) = value else {
            throw Self.wrongType(path, "an object", value)
        }
        return object
    }

    func array(_ value: TemplateJSON, _ path: String) throws -> [TemplateJSON] {
        guard case .array(let array) = value else {
            throw Self.wrongType(path, "a list", value)
        }
        return array
    }

    func string(_ value: TemplateJSON, _ path: String) throws -> String {
        guard case .string(let text) = value else {
            throw Self.wrongType(path, "text", value)
        }
        return text
    }

    func number(_ value: TemplateJSON, _ path: String) throws -> Double {
        guard case .number(let number) = value, number.isFinite else {
            throw Self.wrongType(path, "a number", value)
        }
        return number
    }

    /// A whole number. A fraction is refused outright rather than truncated:
    /// `Int(2.9)` is 2, silently.
    func integer(_ value: TemplateJSON, _ path: String) throws -> Int {
        let number = try self.number(value, path)
        guard number.rounded() == number, let whole = Int(exactly: number) else {
            throw TemplateRefusal(
                code: .wrongType, path: path,
                message: "this must be a whole number; \(ClampNotice.number(number)) is not one.")
        }
        return whole
    }

    func bool(_ value: TemplateJSON, _ path: String) throws -> Bool {
        guard case .bool(let flag) = value else {
            throw Self.wrongType(path, "true or false", value)
        }
        return flag
    }

    // MARK: - Unknown keys

    /// Returns `object` without its unknown keys. Strict: the first unknown key
    /// (alphabetically) is refused, naming the valid ones. Lenient: each is
    /// dropped with `unknownKeySkipped`.
    mutating func knownKeys(_ object: [String: TemplateJSON], _ allowed: [String],
                            _ path: String, _ what: String) throws -> [String: TemplateJSON] {
        var kept = object
        for key in object.keys.sorted() where !allowed.contains(key) {
            let keyPath = Self.join(path, key)
            try refuseOrSkip(
                TemplateRefusal(code: .unknownKey, path: keyPath,
                                message: "\(what) has no key called '\(key)'. The keys it can "
                                    + "have are: \(allowed.joined(separator: ", "))."),
                .unknownKeySkipped,
                "'\(key)' was written by a newer version of DAW Pro; this version doesn't "
                    + "know it and ignored it.")
            kept[key] = nil
        }
        return kept
    }

    // MARK: - Ranges

    /// A number checked against `range`. Strict: out of range is REFUSED,
    /// naming the range and what the value would have become. Lenient: clamped
    /// with `valueClamped` (a newer writer may have widened the range).
    mutating func ranged(_ value: Double, _ range: ClosedRange<Double>,
                         _ path: String, _ name: String) throws -> Double {
        guard !range.contains(value) else { return value }
        let clamped = value.clamped(to: range)
        let accepted = "\(ClampNotice.number(range.lowerBound)) to "
            + "\(ClampNotice.number(range.upperBound))"
        try refuseOrSkip(
            TemplateRefusal(code: .outOfRange, path: path,
                            message: "\(name) accepts \(accepted); "
                                + "\(ClampNotice.number(value)) would become "
                                + "\(ClampNotice.number(clamped))."),
            .valueClamped,
            ClampNotice.sentence(control: name, requested: value, stored: clamped, range: range)
                ?? "\(name) was clamped to \(ClampNotice.number(clamped)).")
        return clamped
    }

    mutating func ranged(_ value: Int, _ range: ClosedRange<Int>,
                         _ path: String, _ name: String) throws -> Int {
        let wide = try ranged(Double(value),
                              Double(range.lowerBound)...Double(range.upperBound), path, name)
        return Int(wide)
    }

    /// §5.3's read-back rule: what was written must read back within
    /// `TrackSetTemplateCodec.readBackTolerance` (relative above 1, absolute
    /// below). A value that snaps (`phaser.stages` stores 6 when asked for 5)
    /// or that a coupled setting changes is REFUSED under a strict read, with
    /// the value it would have become; under a lenient read it becomes that
    /// value, with `valueChanged`. A setter's return is not proof it took; the
    /// reading is. Returns the value to keep.
    mutating func readBack(written: Double, read: Double?, _ path: String,
                           _ name: String) throws -> Double {
        let tolerance = TrackSetTemplateCodec.readBackTolerance * max(1, abs(written))
        if let read, abs(read - written) <= tolerance { return written }
        let became = read.map { ClampNotice.number($0) } ?? "nothing"
        try refuseOrSkip(
            TemplateRefusal(code: .readBack, path: path,
                            message: "\(name) can't hold \(ClampNotice.number(written)); "
                                + "it would become \(became)."),
            .valueChanged,
            "\(name) can't hold \(ClampNotice.number(written)) in this version of DAW Pro, "
                + "so it was set to \(became).")
        return read ?? written
    }

    // MARK: - Labels and keys

    /// A name or summary: text, not blank, at most `max` characters (counted
    /// as a person counts them). Too long: refused (strict) or shortened with
    /// `valueClamped` (lenient: a newer version may allow longer names).
    mutating func label(_ value: TemplateJSON, _ path: String, max: Int,
                        _ what: String) throws -> String {
        let text = try string(value, path)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TemplateRefusal(code: .invalidValue, path: path,
                                  message: "\(what) can't be blank.")
        }
        guard text.count > max else { return text }
        try refuseOrSkip(
            TemplateRefusal(code: .outOfRange, path: path,
                            message: "\(what) can be at most \(max) characters; this one has "
                                + "\(text.count)."),
            .valueClamped,
            "\(what) was longer than this version of DAW Pro allows, so it was shortened to "
                + "\(max) characters.")
        return String(text.prefix(max))
    }

    /// A template-local key: 1–32 lowercase letters, digits and hyphens.
    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= TrackSetTemplateCodec.maxKeyLength
            && key.unicodeScalars.allSatisfy { scalar in
                ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
            }
    }

    func key(_ value: TemplateJSON, _ path: String) throws -> String {
        let text = try string(value, path)
        guard Self.isValidKey(text) else {
            throw TemplateRefusal(
                code: .invalidValue, path: path,
                message: "a key is 1 to \(TrackSetTemplateCodec.maxKeyLength) lowercase "
                    + "letters, digits and hyphens, like \"drum-bus\"; '\(text)' is not one.")
        }
        return text
    }

    static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= TrackSetTemplateCodec.maxIDLength
            && id.unicodeScalars.allSatisfy { scalar in
                ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                    || ("0"..."9").contains(scalar) || scalar == "-"
            }
    }

    // MARK: - The template

    static let templateKeys = ["format", "formatVersion", "minReaderVersion", "id", "name",
                               "summary", "songForm", "genres", "tracks"]

    /// A version number: a whole number, at least 1.
    func version(_ value: TemplateJSON?, _ path: String) throws -> Int? {
        guard let value else { return nil }
        let version = try integer(value, path)
        guard version >= 1 else {
            throw TemplateRefusal(code: .invalidValue, path: path,
                                  message: "a version is a whole number from 1 up.")
        }
        return version
    }

    mutating func readTemplate(_ json: TemplateJSON) throws -> TrackSetTemplate {
        guard case .object(var root) = json else {
            throw TemplateRefusal(
                code: .notATemplate, path: "",
                message: "This isn't a DAW Pro template: a template is a JSON object that "
                    + "starts with \"format\": \"\(TrackSetTemplateCodec.format)\".")
        }
        // 1. It must BE a template before anything else is judged.
        if let format = root["format"] {
            guard case .string(let text) = format, text == TrackSetTemplateCodec.format else {
                throw TemplateRefusal(
                    code: .notATemplate, path: "format",
                    message: "This isn't a DAW Pro template: \"format\" must be "
                        + "\"\(TrackSetTemplateCodec.format)\".")
            }
        } else if origin == .file {
            throw TemplateRefusal(
                code: .notATemplate, path: "format",
                message: "This isn't a DAW Pro template: the file has no \"format\": "
                    + "\"\(TrackSetTemplateCodec.format)\".")
        }
        // 2. The versions decide strict or lenient, so they are read FIRST.
        let formatVersion = try version(root["formatVersion"], "formatVersion")
        let minReaderVersion = try version(root["minReaderVersion"], "minReaderVersion")
        if origin == .file {
            if formatVersion == nil {
                throw Self.missing("formatVersion", "the template format version that wrote "
                    + "the file")
            }
            if minReaderVersion == nil {
                throw Self.missing("minReaderVersion", "the oldest template format version "
                    + "that can read the file")
            }
        }
        let current = TrackSetTemplate.currentFormatVersion
        let needs = minReaderVersion ?? 1
        guard needs <= current else {
            throw TemplateRefusal(code: .needsNewerVersion, path: "",
                                  message: "This template needs a newer version of DAW Pro.")
        }
        let writtenBy = formatVersion ?? current
        lenient = writtenBy > current
        // 3. Keys.
        root = try knownKeys(root, Self.templateKeys, "", "A template")
        var id = ""
        if let raw = root["id"] {
            let text = try string(raw, "id")
            guard Self.isValidID(text) else {
                throw TemplateRefusal(
                    code: .invalidValue, path: "id",
                    message: "an id is 1 to \(TrackSetTemplateCodec.maxIDLength) letters, "
                        + "digits and hyphens, like \"lofi-chill\".")
            }
            id = text
        } else if origin == .file {
            throw Self.missing("id", "the template's id, like \"lofi-chill\"")
        }
        guard let rawName = root["name"] else {
            throw Self.missing("name", "the template's name, like \"Lo-Fi Chill\"")
        }
        let name = try label(rawName, "name", max: TrackSetTemplateCodec.maxNameLength,
                             "A template's name")
        let summary = try root["summary"].map {
            try label($0, "summary", max: TrackSetTemplateCodec.maxSummaryLength,
                      "A template's summary")
        }
        var songForm: String?
        if let raw = root["songForm"] {
            let genre = try string(raw, "songForm")
            if try knownGenre(genre, "songForm") { songForm = genre }
        }
        var genres: [String] = []
        if let raw = root["genres"] {
            for (position, entry) in try array(raw, "genres").enumerated() {
                let entryPath = Self.index("genres", position)
                let genre = try string(entry, entryPath)
                if try knownGenre(genre, entryPath) { genres.append(genre) }
            }
        }
        guard let rawTracks = root["tracks"] else {
            throw Self.missing("tracks", "the list of tracks the template adds")
        }
        let tracks = try readTracks(rawTracks)
        return TrackSetTemplate(formatVersion: writtenBy, minReaderVersion: needs, id: id,
                                name: name, summary: summary, songForm: songForm,
                                genres: genres, tracks: tracks)
    }

    /// A song genre must be one `macro.songSkeleton` knows. Unknown: refused
    /// (strict) or dropped with `unknownGenreSkipped` (lenient).
    mutating func knownGenre(_ genre: String, _ path: String) throws -> Bool {
        guard SongSkeletonCatalog.genre(named: genre) == nil else { return true }
        try refuseOrSkip(
            TemplateRefusal(code: .unknownKind, path: path,
                            message: "there is no song style called '\(genre)'. The styles "
                                + "are: \(SongSkeletonCatalog.names.joined(separator: ", "))."),
            .unknownGenreSkipped,
            "the song style '\(genre)' comes from a newer version of DAW Pro, so it was left "
                + "out.")
        return false
    }

    // MARK: - Tracks

    /// Every track, then the cascade: whatever referred to a track a lenient
    /// read skipped (an output, a send, a sidechain key) is skipped too, with
    /// the same code, so nothing points at a track that will not exist.
    mutating func readTracks(_ json: TemplateJSON) throws -> [TemplateTrack] {
        let entries = try array(json, "tracks")
        let range = TrackSetTemplateCodec.trackCountRange
        guard range.contains(entries.count) else {
            throw TemplateRefusal(
                code: .outOfRange, path: "tracks",
                message: "a template has \(range.lowerBound) to \(range.upperBound) tracks; "
                    + "this one has \(entries.count).")
        }
        var kept: [TemplateTrack] = []
        var keptPositions: [Int] = []
        var keys: Set<String> = []
        var skipped: [String: TemplateWarning.Code] = [:]
        for (position, entry) in entries.enumerated() {
            let path = Self.index("tracks", position)
            let (key, track, skipCode) = try readTrack(entry, path)
            guard keys.insert(key).inserted else {
                throw TemplateRefusal(
                    code: .duplicateKey, path: Self.join(path, "key"),
                    message: "another track already uses the key '\(key)'. Every track "
                        + "needs its own key.")
            }
            if let track {
                kept.append(track)
                keptPositions.append(position)
            } else if let skipCode {
                skipped[key] = skipCode
            }
        }
        if !skipped.isEmpty {
            // Paths name each track's position in the FILE, not in what is kept.
            for index in kept.indices {
                kept[index] = cascade(kept[index], skipped: skipped,
                                      path: Self.index("tracks", keptPositions[index]))
            }
        }
        guard !kept.isEmpty else {
            throw TemplateRefusal(
                code: .needsNewerVersion, path: "tracks",
                message: "This template needs a newer version of DAW Pro: this version can't "
                    + "add any of its tracks.")
        }
        return kept
    }

    /// Drops every reference `track` makes to a skipped track.
    mutating func cascade(_ track: TemplateTrack, skipped: [String: TemplateWarning.Code],
                          path: String) -> TemplateTrack {
        var track = track
        if let output = track.output, let code = skipped[output] {
            warn(code, Self.join(path, "output"),
                 "'\(track.name)' played into '\(output)', which this version of DAW Pro "
                    + "can't add, so it plays straight to the main output instead.")
            track.output = nil
        }
        var keptSends: [TemplateSend] = []
        for (position, send) in track.sends.enumerated() {
            guard let code = skipped[send.bus] else {
                keptSends.append(send)
                continue
            }
            warn(code, Self.join(Self.index(Self.join(path, "sends"), position), "bus"),
                 "'\(track.name)' sent to '\(send.bus)', which this version of DAW Pro can't "
                    + "add, so that send was left out.")
        }
        track.sends = keptSends
        let filePositions = insertFilePositions[path] ?? Array(track.inserts.indices)
        for index in track.inserts.indices {
            if let source = track.inserts[index].sidechainSource, let code = skipped[source] {
                let position = index < filePositions.count ? filePositions[index] : index
                warn(code, Self.join(Self.index(Self.join(path, "inserts"), position),
                                     "sidechainSource"),
                     "an effect on '\(track.name)' listened to '\(source)', which this "
                        + "version of DAW Pro can't add, so it listens to its own track "
                        + "instead.")
                track.inserts[index].sidechainSource = nil
            }
        }
        return track
    }

    static let trackKeys = ["key", "name", "kind", "volume", "pan", "instrument",
                            "mixerPreset", "inserts", "output", "sends", "modulation"]

    /// One track. Returns its key, the track, or — when a lenient read skips
    /// the whole track — nil and the code that skipped it.
    mutating func readTrack(_ json: TemplateJSON, _ path: String)
        throws -> (key: String, track: TemplateTrack?, skipCode: TemplateWarning.Code?) {
        var object = try self.object(json, path)
        object = try knownKeys(object, Self.trackKeys, path, "A track")
        guard let rawKey = object["key"] else {
            throw Self.missing(Self.join(path, "key"),
                               "the track's key, which other tracks use to refer to it")
        }
        let key = try self.key(rawKey, Self.join(path, "key"))
        guard let rawName = object["name"] else {
            throw Self.missing(Self.join(path, "name"), "the track's name, like \"Drums\"")
        }
        let name = try label(rawName, Self.join(path, "name"),
                             max: TrackSetTemplateCodec.maxNameLength, "A track's name")
        guard let rawKind = object["kind"] else {
            throw Self.missing(Self.join(path, "kind"), "\"instrument\", \"audio\" or \"bus\"")
        }
        let kindName = try string(rawKind, Self.join(path, "kind"))
        guard let kind = TrackKind(rawValue: kindName) else {
            try refuseOrSkip(
                TemplateRefusal(code: .unknownKind, path: Self.join(path, "kind"),
                                message: "there is no track kind called '\(kindName)'. A track "
                                    + "is \"instrument\", \"audio\" or \"bus\"."),
                .unknownTrackKindSkipped,
                "the track '\(name)' is a kind of track this version of DAW Pro can't add, "
                    + "so it was left out.")
            return (key, nil, .unknownTrackKindSkipped)
        }
        var track = TemplateTrack(key: key, name: name, kind: kind)
        if let raw = object["volume"] {
            track.volume = try ranged(try number(raw, Self.join(path, "volume")),
                                      Track.volumeRange, Self.join(path, "volume"), "volume")
        }
        if let raw = object["pan"] {
            track.pan = try ranged(try number(raw, Self.join(path, "pan")),
                                   Track.panRange, Self.join(path, "pan"), "pan")
        }
        if let raw = object["instrument"] {
            let instrumentPath = Self.join(path, "instrument")
            guard kind == .instrument else {
                throw TemplateRefusal(
                    code: .invalidValue, path: instrumentPath,
                    message: "only an instrument track can have an instrument, and this "
                        + "track is \(kind == .bus ? "a bus" : "an audio track").")
            }
            guard let instrument = try readInstrument(raw, instrumentPath, trackName: name)
            else { return (key, nil, .unknownInstrumentSkipped) }
            track.instrument = instrument
        }
        if let raw = object["mixerPreset"] {
            let presetPath = Self.join(path, "mixerPreset")
            let preset = try string(raw, presetPath)
            if MixerPresetCatalog.preset(named: preset) != nil {
                track.mixerPreset = preset
            } else {
                try refuseOrSkip(
                    TemplateRefusal(code: .unknownKind, path: presetPath,
                                    message: "there is no mixer preset called '\(preset)'. The "
                                        + "presets are: "
                                        + "\(MixerPresetCatalog.names.joined(separator: ", "))."),
                    .unknownPresetSkipped,
                    "the mixer preset '\(preset)' comes from a newer version of DAW Pro, so "
                        + "'\(name)' starts without it.")
            }
        }
        var skippedInserts: Set<String> = []
        if let raw = object["inserts"] {
            let insertsPath = Self.join(path, "inserts")
            var insertKeys: Set<String> = []
            var keptPositions: [Int] = []
            defer { insertFilePositions[path] = keptPositions }
            for (position, entry) in try array(raw, insertsPath).enumerated() {
                let insertPath = Self.index(insertsPath, position)
                let (insertKey, insert) = try readInsert(entry, insertPath)
                if let insertKey, !insertKeys.insert(insertKey).inserted {
                    throw TemplateRefusal(
                        code: .duplicateKey, path: Self.join(insertPath, "key"),
                        message: "another effect on this track already uses the key "
                            + "'\(insertKey)'.")
                }
                if let insert {
                    track.inserts.append(insert)
                    keptPositions.append(position)
                } else if let insertKey {
                    skippedInserts.insert(insertKey)
                }
            }
        }
        if let raw = object["output"] {
            track.output = try self.key(raw, Self.join(path, "output"))
        }
        if let raw = object["sends"] {
            let sendsPath = Self.join(path, "sends")
            for (position, entry) in try array(raw, sendsPath).enumerated() {
                track.sends.append(try readSend(entry, Self.index(sendsPath, position)))
            }
        }
        if let raw = object["modulation"] {
            let (sources, routes) = try readModulation(
                raw, Self.join(path, "modulation"), track: track,
                skippedInserts: skippedInserts)
            track.modulationSources = sources
            track.modulationRoutes = routes
        }
        return (key, track, nil)
    }

    // MARK: - Inserts

    static let insertKeys = ["key", "kind", "bypassed", "params", "sidechainSource",
                             "audioUnit"]

    /// One insert effect. Returns its key and the insert, or nil when a
    /// lenient read skips an effect kind this build does not know.
    mutating func readInsert(_ json: TemplateJSON, _ path: String)
        throws -> (key: String?, insert: TemplateInsert?) {
        var object = try self.object(json, path)
        object = try knownKeys(object, Self.insertKeys, path, "An effect")
        let insertKey = try object["key"].map { try self.key($0, Self.join(path, "key")) }
        guard let rawKind = object["kind"] else {
            throw Self.missing(Self.join(path, "kind"), "the effect's kind, like \"compressor\"")
        }
        let kindName = try string(rawKind, Self.join(path, "kind"))
        guard let kind = EffectDescriptor.Kind(rawValue: kindName) else {
            let known = EffectDescriptor.Kind.allCases.map(\.rawValue).joined(separator: ", ")
            try refuseOrSkip(
                TemplateRefusal(code: .unknownKind, path: Self.join(path, "kind"),
                                message: "there is no effect called '\(kindName)'. The effects "
                                    + "are: \(known)."),
                .unknownEffectSkipped,
                "the effect '\(kindName)' comes from a newer version of DAW Pro, so it was "
                    + "left out.")
            return (insertKey, nil)
        }
        var insert = TemplateInsert(key: insertKey, kind: kind)
        if let raw = object["bypassed"] {
            insert.bypassed = try bool(raw, Self.join(path, "bypassed"))
        }
        if let raw = object["audioUnit"] {
            guard kind == .audioUnit else {
                throw TemplateRefusal(
                    code: .invalidValue, path: Self.join(path, "audioUnit"),
                    message: "only an effect whose kind is \"audioUnit\" can name an Audio "
                        + "Unit.")
            }
            insert.audioUnit = try readAudioUnit(raw, Self.join(path, "audioUnit"),
                                                 defaultType: "aufx")
        } else if kind == .audioUnit {
            throw Self.missing(Self.join(path, "audioUnit"),
                               "the plug-in to load: {\"subType\", \"manufacturer\"}")
        }
        if let raw = object["params"] {
            insert.params = try readEffectSettings(raw, Self.join(path, "params"), kind: kind)
        }
        if let raw = object["sidechainSource"] {
            insert.sidechainSource = try self.key(raw, Self.join(path, "sidechainSource"))
        }
        return (insertKey, insert)
    }

    /// An insert's `params`: every name must be one of
    /// `EffectParamSpec.specs(for: kind)`, every value in its range, and every
    /// value must READ BACK as written once all of them are written, in
    /// `specs(for:)` order, through the ONE writer onto a brand-new insert.
    mutating func readEffectSettings(_ json: TemplateJSON, _ path: String,
                                     kind: EffectDescriptor.Kind) throws -> [String: Double] {
        let object = try self.object(json, path)
        let specs = EffectParamSpec.specs(for: kind)
        var values: [String: Double] = [:]
        for name in object.keys.sorted() {
            let settingPath = Self.join(path, name)
            let value = try number(object[name]!, settingPath)
            guard let spec = specs.first(where: { $0.name == name }) else {
                let valid = specs.isEmpty
                    ? "this effect has no settings you can set by name"
                    : "its settings are: \(specs.map(\.name).joined(separator: ", "))"
                try refuseOrSkip(
                    TemplateRefusal(code: .unknownSetting, path: settingPath,
                                    message: "a \(kind.rawValue) effect has no setting called "
                                        + "'\(name)'; \(valid)."),
                    .unknownSettingSkipped,
                    "the setting '\(name)' comes from a newer version of DAW Pro, so it was "
                        + "left out.")
                continue
            }
            values[name] = try ranged(value, spec.range, settingPath, name)
        }
        // The read-back: write every setting, THEN read every one, so a later
        // write that changes an earlier one (a coupled pair) is caught too.
        var effect = EffectDescriptor.newlyAdded(kind: kind)
        for spec in specs {
            if let value = values[spec.name] { effect.applySetting(spec.name, value) }
        }
        for spec in specs {
            guard let written = values[spec.name] else { continue }
            values[spec.name] = try readBack(written: written, read: effect.paramValue(spec.name),
                                             Self.join(path, spec.name), spec.name)
        }
        return values
    }

    // MARK: - Sends

    static let sendKeys = ["bus", "level"]

    mutating func readSend(_ json: TemplateJSON, _ path: String) throws -> TemplateSend {
        var object = try self.object(json, path)
        object = try knownKeys(object, Self.sendKeys, path, "A send")
        guard let rawBus = object["bus"] else {
            throw Self.missing(Self.join(path, "bus"), "the key of the bus it sends to")
        }
        var send = TemplateSend(bus: try key(rawBus, Self.join(path, "bus")))
        if let raw = object["level"] {
            send.level = try ranged(try number(raw, Self.join(path, "level")), Send.levelRange,
                                    Self.join(path, "level"), "level")
        }
        return send
    }
}
