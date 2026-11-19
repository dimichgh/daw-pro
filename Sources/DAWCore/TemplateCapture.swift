import Foundation

// m39-tpl-5 — CAPTURE, THE CANONICAL FORM, AND THE CANONICAL JSON
// (docs/design/2026-09-27-multi-instrument-templates.md §4.6, §5.7, §8.3).
//
// `capture` turns tracks that already exist in a song into a template: the
// chosen tracks, plus every bus they play or send into. `canonical` turns any
// template into the ONE form two equal sound setups share. `canonicalJSON`
// writes that form as the bytes `template.save`, `template.export` and (TPL-6)
// `template.describe` emit. Pure: Foundation only, nonisolated, no store, no
// engine, no file system.
//
// ⭐ THE INVARIANT (§4.6): `canonical(capture(apply(T))) == canonical(T)` for
// every template, stated on NAMED READINGS, not bytes. So the canonical form:
//   · re-derives every KEY (tracks from their names, lowercased and hyphenated,
//     `-2`/`-3` for repeats; an insert gets a key only when a route targets it,
//     from its kind; a modulation source from its name). Keys are local to one
//     file, so this is naming, never matching. It is NOT optional: the built-in
//     files' own keys are not their names' keys ("vocal" for "Lead Vocal").
//   · expands `mixerPreset` into the inserts it builds and drops the name;
//   · writes an effect setting only when its READING differs from a brand-new
//     effect's (`EffectDescriptor.newlyAdded(kind:)` — NOT the spec default: a
//     new clipper carries an explicit 1 while an old one reads 4), then PROVES
//     it by rebuilding fresh + those settings and comparing every reading,
//     adding any setting a coupled partner moved (the EQ's filters switch on
//     when a corner exists, so `highPassEnabled: 0` beside a corner must be
//     written even though 0 is a fresh EQ's reading). The reading is the proof;
//   · keeps only the ACTIVE instrument's block, writes the Poly Synth and the
//     drum kit as their named differences from a fresh one, and never writes a
//     display name (a sound bank's is derived; an Audio Unit's and a Sampler's
//     are not part of the sound);
//   · omits defaults: volume 1, pan 0, bypassed false, output to the master,
//     send level 1, route enabled, a source's own default name.
//
// ⭐ WHAT CAPTURE NEVER READS (§5.7): automation, clips, mute, solo, arm, the
// AI-made flag, take groups and provenance. The code below never touches those
// fields; `TemplateCaptureTests` proves it by capturing two tracks that differ
// only in them.
//
// TODO(TPL-6): `template.describe` replies with `canonicalJSON`'s object and
// `template.save` with `ProjectStore.saveTemplate` (ProjectStore+TemplateLibrary.swift).
// TODO(TPL-7): MCP tools `template_describe` / `template_save` in mcp-server/src/server.ts.

public enum TemplateCapture {
    /// A captured template and what capture had to work around, each
    /// `{code, path, message}` with a sentence a novice can read.
    public struct Result: Sendable, Equatable {
        public var template: TrackSetTemplate
        public var warnings: [TemplateWarning]

        public init(template: TrackSetTemplate, warnings: [TemplateWarning]) {
            self.template = template
            self.warnings = warnings
        }
    }

    // MARK: - Capture (§5.7)

    /// The template that would set up `selected` again, in a new song or this
    /// one: those tracks, in song order, plus every bus they play or send into
    /// (`busIncluded`). A sidechain that listens to a track you did not choose
    /// is dropped with `sidechainDropped`; the source track is NOT pulled in.
    ///
    /// Throws `TemplateRefusal` for: no tracks chosen, an id that is not in
    /// `tracks`, more than 24 tracks once the buses are added, and a template
    /// name, summary, song style or id the codec would refuse.
    public static func capture(tracks: [Track], selected: [UUID], name: String,
                               id: String = "", summary: String? = nil,
                               songForm: String? = nil,
                               genres: [String] = []) throws -> Result {
        try checkLabels(name: name, id: id, summary: summary, songForm: songForm, genres: genres)
        guard !selected.isEmpty else {
            throw TemplateRefusal(code: .missingKey, path: "trackIds",
                                  message: "Choose at least one track to save as a template.")
        }
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen: Set<UUID> = []
        for (position, trackID) in selected.enumerated() {
            guard byID[trackID] != nil else {
                throw TemplateRefusal(
                    code: .invalidValue, path: "trackIds[\(position)]",
                    message: "There's no track with the id '\(trackID.uuidString)' in this song.")
            }
            chosen.insert(trackID)
        }

        // The buses the chosen tracks play or send into, each reported once,
        // naming the first chosen track (in song order) that needs it.
        var warnings: [TemplateWarning] = []
        var included = chosen
        for track in tracks where chosen.contains(track.id) {
            var needs: [(UUID, String)] = []
            if let bus = track.outputBusID { needs.append((bus, "plays into it")) }
            for send in track.sends { needs.append((send.destinationBusID, "sends to it")) }
            for (busID, why) in needs where !included.contains(busID) {
                guard let bus = byID[busID], bus.kind == .bus else { continue }
                included.insert(busID)
                warnings.append(TemplateWarning(
                    code: .busIncluded, path: "tracks",
                    message: "The bus '\(bus.name)' was saved too, because '\(track.name)' "
                        + "\(why)."))
            }
        }
        let ordered = tracks.filter { included.contains($0.id) }
        let range = TrackSetTemplateCodec.trackCountRange
        guard ordered.count <= range.upperBound else {
            let buses = ordered.count - chosen.count
            throw TemplateRefusal(
                code: .outOfRange, path: "trackIds",
                message: "A template can hold at most \(range.upperBound) tracks, and this one "
                    + "would hold \(ordered.count): the \(chosen.count) you chose"
                    + (buses > 0 ? " plus \(buses) bus\(buses == 1 ? "" : "es") they play or "
                        + "send into" : "") + ".")
        }

        let keys = uniqueKeys(ordered.map(\.name), fallback: "track")
        var keyByID: [UUID: String] = [:]
        for (index, track) in ordered.enumerated() { keyByID[track.id] = keys[index] }

        var captured: [TemplateTrack] = []
        for (index, track) in ordered.enumerated() {
            let path = "tracks[\(index)]"
            captured.append(captureTrack(track, key: keys[index], path: path,
                                         keyByID: keyByID, byID: byID,
                                         warnings: &warnings))
        }
        let template = TrackSetTemplate(id: id, name: name, summary: summary,
                                        songForm: songForm, genres: genres, tracks: captured)
        return Result(template: template, warnings: warnings)
    }

    /// The template-level labels, judged exactly as the codec judges a file's.
    static func checkLabels(name: String, id: String, summary: String?, songForm: String?,
                            genres: [String]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TemplateRefusal(code: .invalidValue, path: "name",
                                  message: "A template's name can't be blank.")
        }
        guard name.count <= TrackSetTemplateCodec.maxNameLength else {
            throw TemplateRefusal(
                code: .outOfRange, path: "name",
                message: "A template's name can be at most \(TrackSetTemplateCodec.maxNameLength) "
                    + "characters; this one has \(name.count).")
        }
        if !id.isEmpty, !TemplateReader.isValidID(id) {
            throw TemplateRefusal(
                code: .invalidValue, path: "id",
                message: "an id is 1 to \(TrackSetTemplateCodec.maxIDLength) letters, digits and "
                    + "hyphens, like \"lofi-chill\".")
        }
        if let summary {
            guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TemplateRefusal(code: .invalidValue, path: "summary",
                                      message: "A template's summary can't be blank.")
            }
            guard summary.count <= TrackSetTemplateCodec.maxSummaryLength else {
                throw TemplateRefusal(
                    code: .outOfRange, path: "summary",
                    message: "A template's summary can be at most "
                        + "\(TrackSetTemplateCodec.maxSummaryLength) characters; this one has "
                        + "\(summary.count).")
            }
        }
        var styles: [(path: String, genre: String)] = []
        if let songForm { styles.append((path: "songForm", genre: songForm)) }
        for (position, genre) in genres.enumerated() {
            styles.append((path: "genres[\(position)]", genre: genre))
        }
        for (path, genre) in styles where SongSkeletonCatalog.genre(named: genre) == nil {
            throw TemplateRefusal(
                code: .unknownKind, path: path,
                message: "there is no song style called '\(genre)'. The styles are: "
                    + "\(SongSkeletonCatalog.names.joined(separator: ", ")).")
        }
    }

    /// One track as a template track. Reads ONLY: name, kind, volume, pan,
    /// instrument, effects, output, sends, modulation sources and routes.
    static func captureTrack(_ track: Track, key: String, path: String,
                             keyByID: [UUID: String], byID: [UUID: Track],
                             warnings: inout [TemplateWarning]) -> TemplateTrack {
        var spec = TemplateTrack(key: key, name: label(track.name, fallback: "Track",
                                                       path: "\(path).name", warnings: &warnings),
                                 kind: track.kind, volume: track.volume, pan: track.pan)
        if track.kind == .instrument {
            spec.instrument = normalizedInstrument(track.instrument ?? .default)
            // m39-tpl-5b: a slice kit's MARK is set by Chop to Sampler and never
            // read off the wire, so a template cannot carry it (§4.6: no
            // template-only side channel). Dropped in words, never silently: it
            // is what keeps a key change from moving the kit's notes.
            if let instrument = track.instrument, instrument.kind == .sampler,
               instrument.sampler?.isSliceKit == true {
                warnings.append(TemplateWarning(
                    code: .valueChanged, path: "\(path).instrument.sampler",
                    message: "'\(track.name)' was made by Chop to Sampler. The template keeps its "
                        + "slices but not that mark, so changing the song's key will move this "
                        + "track's notes too."))
            }
        }

        // Effects: settings by named reading, sidechain keys by track key.
        for (position, effect) in track.effects.enumerated() {
            let insertPath = "\(path).inserts[\(position)]"
            let settings = settings(of: effect)
            for name in settings.unexpressible {
                warnings.append(TemplateWarning(
                    code: .valueChanged, path: "\(insertPath).params.\(name)",
                    message: "The \(effectNoun(effect.kind)) on '\(track.name)' has a "
                        + "'\(name)' setting this template can't hold exactly, so it may "
                        + "come back slightly different."))
            }
            var insert = TemplateInsert(kind: effect.kind, bypassed: effect.isBypassed,
                                        params: settings.params,
                                        audioUnit: effect.kind == .audioUnit
                                            ? effect.audioUnit.map(normalizedAudioUnit) : nil)
            if let sourceID = effect.sidechainSourceTrackID {
                if let sourceKey = keyByID[sourceID] {
                    insert.sidechainSource = sourceKey
                } else {
                    let follows = effect.kind == .gate
                        ? "so it will not open and close with it"
                        : "so it will not duck"
                    // §5.7's sentence, word for word: "The Keys Duck compressor
                    // listened to Drums, which you didn't save, so it will not duck."
                    let sourceName = byID[sourceID]?.name
                        ?? "a track that is no longer in the song"
                    warnings.append(TemplateWarning(
                        code: .sidechainDropped, path: "\(insertPath).sidechainSource",
                        message: "The \(track.name) \(effectNoun(effect.kind)) listened to "
                            + "\(sourceName), which you didn't save, \(follows)."))
                }
            }
            spec.inserts.append(insert)
        }

        if let busID = track.outputBusID {
            if let busKey = keyByID[busID], byID[busID]?.kind == .bus {
                spec.output = busKey
            } else {
                warnings.append(TemplateWarning(
                    code: .valueChanged, path: "\(path).output",
                    message: "'\(track.name)' played into a bus that is no longer in the song, "
                        + "so the template plays it straight to the main output."))
            }
        }
        for (position, send) in track.sends.enumerated() {
            guard let busKey = keyByID[send.destinationBusID],
                  byID[send.destinationBusID]?.kind == .bus else {
                warnings.append(TemplateWarning(
                    code: .valueChanged, path: "\(path).sends[\(position)]",
                    message: "'\(track.name)' sent to a bus that is no longer in the song, so "
                        + "that send was left out."))
                continue
            }
            spec.sends.append(TemplateSend(bus: busKey, level: send.level))
        }

        // Modulation: sources keyed from their names, routes by key.
        let sourceKeys = uniqueKeys(track.modulationSources.map(\.name),
                                    fallbacks: track.modulationSources.map {
                                        insertKey(forKind: $0.kind.rawValue)
                                    })
        var sourceKeyByID: [UUID: String] = [:]
        for (index, source) in track.modulationSources.enumerated() {
            sourceKeyByID[source.id] = sourceKeys[index]
            spec.modulationSources.append(TemplateModSource(
                key: sourceKeys[index], kind: source.kind,
                name: sourceName(source.name, kind: source.kind,
                                 path: "\(path).modulation.sources[\(index)].name",
                                 warnings: &warnings),
                params: normalizedSourceParams(source.params)))
        }
        var targeted: Set<Int> = []
        var pending: [(source: String, effectIndex: Int?, target: TemplateTarget, route: ModulationRoute)] = []
        for (position, route) in track.modulationRoutes.enumerated() {
            let routePath = "\(path).modulation.routes[\(position)]"
            guard let sourceKey = sourceKeyByID[route.sourceID] else {
                warnings.append(TemplateWarning(
                    code: .unknownModulationSkipped, path: routePath,
                    message: "A modulation route on '\(track.name)' followed a source that is "
                        + "no longer there, so it was left out."))
                continue
            }
            switch route.target {
            case .volume:
                pending.append((sourceKey, nil, .volume, route))
            case .pan:
                pending.append((sourceKey, nil, .pan, route))
            case .instrumentParam(let param):
                pending.append((sourceKey, nil, .instrumentParam(param: param), route))
            case .effectParam(let effectID, let param):
                guard let effectIndex = track.effects.firstIndex(where: { $0.id == effectID }) else {
                    warnings.append(TemplateWarning(
                        code: .unknownModulationSkipped, path: routePath,
                        message: "A modulation route on '\(track.name)' moved an effect that is "
                            + "no longer there, so it was left out."))
                    continue
                }
                targeted.insert(effectIndex)
                pending.append((sourceKey, effectIndex, .effectParam(insert: "", param: param), route))
            case .sendLevel:
                warnings.append(TemplateWarning(
                    code: .unknownModulationSkipped, path: routePath,
                    message: "A modulation route on '\(track.name)' moved a send level, which "
                        + "modulation can't do, so it was left out."))
            }
        }
        let insertKeys = targetedInsertKeys(kinds: spec.inserts.map(\.kind), targeted: targeted)
        for (index, key) in insertKeys { spec.inserts[index].key = key }
        for item in pending {
            var target = item.target
            if let effectIndex = item.effectIndex, case .effectParam(_, let param) = target {
                target = .effectParam(insert: insertKeys[effectIndex] ?? "", param: param)
            }
            spec.modulationRoutes.append(TemplateModRoute(source: item.source, target: target,
                                                          depth: item.route.depth,
                                                          enabled: item.route.enabled))
        }
        return spec
    }

    /// A track or source label the codec accepts: not blank, at most 40
    /// characters. A longer one is shortened, and said so.
    static func label(_ text: String, fallback: String, path: String,
                      warnings: inout [TemplateWarning]) -> String {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append(TemplateWarning(code: .valueChanged, path: path,
                                            message: "A track with no name is saved as '\(fallback)'."))
            return fallback
        }
        let limit = TrackSetTemplateCodec.maxNameLength
        guard text.count > limit else { return text }
        let short = String(text.prefix(limit))
        warnings.append(TemplateWarning(
            code: .valueChanged, path: path,
            message: "The name '\(text)' is longer than \(limit) characters, so the template "
                + "calls it '\(short)'."))
        return short
    }

    static func sourceName(_ name: String, kind: ModulationSourceKind, path: String,
                           warnings: inout [TemplateWarning]) -> String? {
        let text = label(name, fallback: kind.defaultName, path: path, warnings: &warnings)
        return text == kind.defaultName ? nil : text
    }

    /// "compressor", "dj filter", "hall reverb": an effect kind in words.
    static func effectNoun(_ kind: EffectDescriptor.Kind) -> String {
        insertKey(forKind: kind.rawValue).replacingOccurrences(of: "-", with: " ")
    }

    // MARK: - Keys

    /// A track's key from its name: lowercased, accents folded, every run of
    /// anything that is not a letter or a digit becomes one hyphen, at most 32
    /// characters. Empty when the name has no letters or digits at all.
    public static func key(fromName name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive,
                                            .widthInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var key = ""
        var gap = false
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if gap, !key.isEmpty { key.append("-") }
                gap = false
                key.unicodeScalars.append(scalar)
            } else {
                gap = true
            }
        }
        return trimmed(key, to: TrackSetTemplateCodec.maxKeyLength)
    }

    /// `name`'s key, made unique in order: the second "Drums" is `drums-2`.
    static func uniqueKeys(_ names: [String], fallback: String) -> [String] {
        uniqueKeys(names, fallbacks: names.map { _ in fallback })
    }

    static func uniqueKeys(_ names: [String], fallbacks: [String]) -> [String] {
        var used: Set<String> = []
        var keys: [String] = []
        for (index, name) in names.enumerated() {
            var base = key(fromName: name)
            if base.isEmpty { base = fallbacks[index] }
            keys.append(claim(base, in: &used))
        }
        return keys
    }

    /// `base`, or `base-2`, `base-3`… — the first one not yet used.
    static func claim(_ base: String, in used: inout Set<String>) -> String {
        var candidate = base
        var number = 2
        while used.contains(candidate) {
            let suffix = "-\(number)"
            candidate = trimmed(base, to: TrackSetTemplateCodec.maxKeyLength - suffix.count) + suffix
            number += 1
        }
        used.insert(candidate)
        return candidate
    }

    static func trimmed(_ key: String, to length: Int) -> String {
        guard key.count > length else { return key }
        var short = String(key.prefix(length))
        while short.hasSuffix("-") { short.removeLast() }
        return short
    }

    /// `hallReverb` → `hall-reverb`: an insert's (or a source kind's) key.
    static func insertKey(forKind raw: String) -> String {
        var key = ""
        for character in raw {
            if character.isUppercase, !key.isEmpty { key.append("-") }
            key.append(contentsOf: character.lowercased())
        }
        return key
    }

    /// Keys for the inserts a route targets, by chain position, from their kind.
    static func targetedInsertKeys(kinds: [EffectDescriptor.Kind],
                                   targeted: Set<Int>) -> [Int: String] {
        var used: Set<String> = []
        var keys: [Int: String] = [:]
        for index in kinds.indices where targeted.contains(index) {
            keys[index] = claim(insertKey(forKind: kinds[index].rawValue), in: &used)
        }
        return keys
    }

    // MARK: - Settings by named reading

    /// An effect's settings, sparse against a BRAND-NEW effect of its kind, and
    /// PROVEN: fresh + these settings, written in `specs(for:)` order through
    /// the one writer (clamped first, as `fx.setParam` does), must read back
    /// every one of the effect's readings. A setting a coupled partner moves is
    /// added explicitly. `unexpressible` names any reading the named surface
    /// cannot reproduce at all (expected empty; reported, never hidden).
    static func settings(of effect: EffectDescriptor)
        -> (params: [String: Double], unexpressible: [String]) {
        let specs = EffectParamSpec.specs(for: effect.kind)
        var target: [String: Double] = [:]
        for spec in specs {
            if let value = effect.paramValue(spec.name), value.isFinite {
                target[spec.name] = value.clamped(to: spec.range)
            }
        }
        let fresh = EffectDescriptor.newlyAdded(kind: effect.kind)
        var params: [String: Double] = [:]
        for spec in specs {
            if let value = target[spec.name], fresh.paramValue(spec.name) != value {
                params[spec.name] = value
            }
        }
        for _ in 0...specs.count {
            let built = built(effect.kind, params)
            let wrong = specs.filter { spec in
                guard let value = target[spec.name] else { return false }
                return built.paramValue(spec.name) != value
            }
            if wrong.isEmpty { return (params, []) }
            var added = false
            for spec in wrong where params[spec.name] != target[spec.name] {
                params[spec.name] = target[spec.name]
                added = true
            }
            if !added { return (params, wrong.map(\.name)) }
        }
        return (params, [])
    }

    /// A brand-new effect of `kind` with `params` written the builder's way.
    static func built(_ kind: EffectDescriptor.Kind, _ params: [String: Double]) -> EffectDescriptor {
        var effect = EffectDescriptor.newlyAdded(kind: kind)
        for spec in EffectParamSpec.specs(for: kind) {
            if let value = params[spec.name] { effect.applySetting(spec.name, value.clamped(to: spec.range)) }
        }
        return effect
    }

    // MARK: - Instruments

    /// Only the ACTIVE kind's block, named settings over a fresh value, no
    /// display names. Nil for the default Poly Synth with every setting at its
    /// default: an instrument track with no instrument plays exactly that.
    static func normalizedInstrument(_ descriptor: InstrumentDescriptor) -> InstrumentDescriptor? {
        switch descriptor.kind {
        case .testTone:
            return InstrumentDescriptor(kind: .testTone)
        case .polySynth:
            let synth = normalizedSynth(descriptor.polySynth)
            return synth == PolySynthParams() ? nil : InstrumentDescriptor(kind: .polySynth,
                                                                           polySynth: synth)
        case .drumSynth:
            // W9-DRUMDEF: ALWAYS an explicit kit — the one this drum machine
            // PLAYS (`resolvedDrumKit`), folded to the factory kit's spelling.
            // A template drum machine with no kit is read as a NEW drum machine
            // (the user's picks), so a captured never-edited one (nil, which
            // plays the factory kit) must name the kit it plays to come back as
            // itself.
            return InstrumentDescriptor(kind: .drumSynth,
                                        drumKit: normalizedKit(descriptor.resolvedDrumKit)
                                            ?? DrumKitParams())
        case .soundBank:
            return InstrumentDescriptor(kind: .soundBank,
                                        soundBank: descriptor.soundBank.map(normalizedBank))
        case .sampler:
            return InstrumentDescriptor(kind: .sampler,
                                        sampler: descriptor.sampler.flatMap(normalizedSampler))
        case .audioUnit:
            return InstrumentDescriptor(kind: .audioUnit,
                                        audioUnit: descriptor.audioUnit.map(normalizedAudioUnit))
        }
    }

    /// The Poly Synth as its 24 named settings over `PolySynthParams()`.
    static func normalizedSynth(_ synth: PolySynthParams) -> PolySynthParams {
        var fresh = PolySynthParams()
        for name in PolySynthParams.settingNames {
            switch PolySynthParams.settingKind(named: name) {
            case .waveform:
                if let value = synth.settingWaveform(name), value != fresh.settingWaveform(name) {
                    fresh.setSetting(name, waveform: value)
                }
            case .number(let range):
                if let value = synth.settingNumber(name), value != fresh.settingNumber(name) {
                    fresh.setSetting(name, number: value.clamped(to: range))
                }
            case .integer(let range):
                if let value = synth.settingNumber(name), value != fresh.settingNumber(name) {
                    let whole = value.rounded().clamped(to: Double(range.lowerBound)...Double(range.upperBound))
                    fresh.setSetting(name, number: whole)
                }
            case nil:
                break
            }
        }
        return fresh
    }

    /// The drum kit as its named settings, choke groups and note layout over
    /// the factory kit. Nil when that is the factory kit.
    static func normalizedKit(_ kit: DrumKitParams) -> DrumKitParams? {
        var fresh = DrumKitParams()
        for spec in DrumKitParams.paramSpecs {
            if let value = kit.value(forParamName: spec.name),
               value != fresh.value(forParamName: spec.name) {
                fresh.setValue(value, forParamName: spec.name)
            }
        }
        for voice in DrumVoice.allCases where kit[voice].chokeGroup != fresh[voice].chokeGroup {
            fresh[voice].chokeGroup = kit[voice].chokeGroup.map {
                $0.clamped(to: SamplerZone.chokeGroupRange)
            }
        }
        fresh.noteLayout = kit.noteLayout
        return fresh == DrumKitParams() ? nil : fresh
    }

    /// A Sampler as the codec reads it back (m39-tpl-5b): no provenance
    /// (`sourcePath`, `displayName`, `sliceKit` — set by an import or a chop,
    /// never by the wire, so no template can carry them), each zone under its
    /// PLACEHOLDER id with its file URL rebuilt from its path (the codec's
    /// `URL(fileURLWithPath:)`), so the same setup is the same value whether it
    /// came from a song or a file. Nil for a Sampler with nothing set.
    static func normalizedSampler(_ sampler: SamplerParams) -> SamplerParams? {
        var sampler = sampler
        sampler.sourcePath = nil
        sampler.displayName = nil
        sampler.sliceKit = nil
        sampler.zones = sampler.zones.enumerated().map { index, zone in
            TemplateReader.samplerZone(zone, id: TemplateReader.samplerZoneID(index),
                                       audioFileURL: URL(fileURLWithPath: zone.audioFileURL.path))
        }
        return sampler == SamplerParams() ? nil : sampler
    }

    /// A sound bank with its display name DERIVED, the codec's way (§4.6).
    static func normalizedBank(_ bank: SoundBankConfig) -> SoundBankConfig {
        var bank = bank
        bank.displayName = TemplateReader.soundBankDisplayName(
            source: bank.source, program: bank.program, bankMSB: bank.bankMSB,
            bankLSB: bank.bankLSB)
        return bank
    }

    /// An Audio Unit by its component and its saved sound; the display names
    /// are not part of the sound and a template never writes them.
    static func normalizedAudioUnit(_ unit: AudioUnitConfig) -> AudioUnitConfig {
        AudioUnitConfig(component: unit.component, stateData: unit.stateData)
    }

    // MARK: - The canonical form (§4.6)

    /// The ONE form two equal sound setups share. See the file header for every
    /// rule. Throws only for a `mixerPreset` this build does not know.
    public static func canonical(_ template: TrackSetTemplate) throws -> TrackSetTemplate {
        let trackKeys = uniqueKeys(template.tracks.map(\.name), fallback: "track")
        var keyMap: [String: String] = [:]
        for (index, track) in template.tracks.enumerated() where keyMap[track.key] == nil {
            keyMap[track.key] = trackKeys[index]
        }
        var tracks: [TemplateTrack] = []
        for (index, track) in template.tracks.enumerated() {
            tracks.append(try canonicalTrack(track, key: trackKeys[index], keyMap: keyMap,
                                             path: "tracks[\(index)]"))
        }
        return TrackSetTemplate(formatVersion: TrackSetTemplate.currentFormatVersion,
                                minReaderVersion: 1, id: template.id, name: template.name,
                                summary: template.summary, songForm: template.songForm,
                                genres: template.genres, tracks: tracks)
    }

    static func canonicalTrack(_ track: TemplateTrack, key: String, keyMap: [String: String],
                               path: String) throws -> TemplateTrack {
        var spec = TemplateTrack(key: key, name: track.name, kind: track.kind,
                                 volume: track.volume, pan: track.pan)
        if track.kind == .instrument {
            spec.instrument = normalizedInstrument(track.instrument ?? .default)
        }
        // The mixer preset's chain first, then the template's own inserts.
        var oldInsertIndex: [String: Int] = [:]
        if let presetName = track.mixerPreset {
            guard let preset = MixerPresetCatalog.preset(named: presetName) else {
                throw TemplateRefusal(
                    code: .unknownKind, path: "\(path).mixerPreset",
                    message: "there is no mixer preset called '\(presetName)'. The presets are: "
                        + "\(MixerPresetCatalog.names.joined(separator: ", ")).")
            }
            for effect in preset.freshChain() {
                spec.inserts.append(TemplateInsert(
                    kind: effect.kind, bypassed: effect.isBypassed,
                    params: settings(of: effect).params,
                    audioUnit: effect.kind == .audioUnit
                        ? effect.audioUnit.map(normalizedAudioUnit) : nil))
            }
        }
        for insert in track.inserts {
            if let key = insert.key, oldInsertIndex[key] == nil {
                oldInsertIndex[key] = spec.inserts.count
            }
            var effect = EffectDescriptor.newlyAdded(
                kind: insert.kind, audioUnit: insert.kind == .audioUnit ? insert.audioUnit : nil)
            for setting in EffectParamSpec.specs(for: insert.kind) {
                if let value = insert.params[setting.name] {
                    effect.applySetting(setting.name, value.clamped(to: setting.range))
                }
            }
            spec.inserts.append(TemplateInsert(
                kind: insert.kind, bypassed: insert.bypassed, params: settings(of: effect).params,
                sidechainSource: insert.sidechainSource.map { keyMap[$0] ?? $0 },
                audioUnit: insert.kind == .audioUnit ? insert.audioUnit.map(normalizedAudioUnit) : nil))
        }
        spec.output = track.output.map { keyMap[$0] ?? $0 }
        spec.sends = track.sends.map { TemplateSend(bus: keyMap[$0.bus] ?? $0.bus, level: $0.level) }

        let sourceKeys = uniqueKeys(track.modulationSources.map { $0.name ?? $0.kind.defaultName },
                                    fallbacks: track.modulationSources.map {
                                        insertKey(forKind: $0.kind.rawValue)
                                    })
        var sourceMap: [String: String] = [:]
        for (index, source) in track.modulationSources.enumerated() {
            if sourceMap[source.key] == nil { sourceMap[source.key] = sourceKeys[index] }
            let name = source.name ?? source.kind.defaultName
            spec.modulationSources.append(TemplateModSource(
                key: sourceKeys[index], kind: source.kind,
                name: name == source.kind.defaultName ? nil : name,
                params: normalizedSourceParams(source.params)))
        }
        var targeted: Set<Int> = []
        for route in track.modulationRoutes {
            if case .effectParam(let insert, _) = route.target, let index = oldInsertIndex[insert] {
                targeted.insert(index)
            }
        }
        let insertKeys = targetedInsertKeys(kinds: spec.inserts.map(\.kind), targeted: targeted)
        for (index, key) in insertKeys { spec.inserts[index].key = key }
        for route in track.modulationRoutes {
            var target = route.target
            if case .effectParam(let insert, let param) = route.target {
                let newKey = oldInsertIndex[insert].flatMap { insertKeys[$0] } ?? insert
                target = .effectParam(insert: newKey, param: param)
            }
            spec.modulationRoutes.append(TemplateModRoute(
                source: sourceMap[route.source] ?? route.source, target: target,
                depth: route.depth, enabled: route.enabled))
        }
        return spec
    }

    // MARK: - The canonical JSON (§4.3, §7.3)

    /// `template`'s canonical form as UTF-8 JSON: sorted keys (so `"format"`
    /// comes first), defaults omitted, two-space indentation, a final newline.
    /// The same bytes for the same sound setup, on every run. Throws
    /// `TemplateRefusal` only for a `mixerPreset` this build does not know
    /// (`canonical`). A Sampler with its sound files is written since m39-tpl-5b
    /// (`TemplateReader.samplerObject`).
    public static func canonicalJSON(_ template: TrackSetTemplate) throws -> Data {
        let form = try canonical(template)
        var text = ""
        write(try object(form), indent: 0, into: &text)
        text.append("\n")
        return Data(text.utf8)
    }

    /// The canonical form as a JSON tree (what `template.describe` replies with).
    static func object(_ template: TrackSetTemplate) throws -> TemplateJSON {
        var root: [String: TemplateJSON] = [
            "format": .string(TrackSetTemplateCodec.format),
            "formatVersion": .number(Double(template.formatVersion)),
            "minReaderVersion": .number(Double(template.minReaderVersion)),
            "name": .string(template.name),
            "tracks": .array(try template.tracks.enumerated().map { index, track in
                try trackObject(track, path: "tracks[\(index)]")
            }),
        ]
        if !template.id.isEmpty { root["id"] = .string(template.id) }
        if let summary = template.summary { root["summary"] = .string(summary) }
        if let songForm = template.songForm { root["songForm"] = .string(songForm) }
        if !template.genres.isEmpty { root["genres"] = .array(template.genres.map { .string($0) }) }
        return .object(root)
    }

    static func trackObject(_ track: TemplateTrack, path: String) throws -> TemplateJSON {
        var object: [String: TemplateJSON] = [
            "key": .string(track.key),
            "name": .string(track.name),
            "kind": .string(track.kind.rawValue),
        ]
        if track.volume != 1 { object["volume"] = .number(track.volume) }
        if track.pan != 0 { object["pan"] = .number(track.pan) }
        if let instrument = track.instrument {
            object["instrument"] = try instrumentObject(instrument, path: "\(path).instrument")
        }
        if let preset = track.mixerPreset { object["mixerPreset"] = .string(preset) }
        if !track.inserts.isEmpty { object["inserts"] = .array(track.inserts.map(insertObject)) }
        if let output = track.output { object["output"] = .string(output) }
        if !track.sends.isEmpty {
            object["sends"] = .array(track.sends.map { send in
                var entry: [String: TemplateJSON] = ["bus": .string(send.bus)]
                if send.level != 1 { entry["level"] = .number(send.level) }
                return .object(entry)
            })
        }
        if !track.modulationSources.isEmpty || !track.modulationRoutes.isEmpty {
            var modulation: [String: TemplateJSON] = [:]
            if !track.modulationSources.isEmpty {
                modulation["sources"] = .array(track.modulationSources.map(sourceObject))
            }
            if !track.modulationRoutes.isEmpty {
                modulation["routes"] = .array(track.modulationRoutes.map(routeObject))
            }
            object["modulation"] = .object(modulation)
        }
        return .object(object)
    }

    static func instrumentObject(_ instrument: InstrumentDescriptor,
                                 path: String) throws -> TemplateJSON {
        var object: [String: TemplateJSON] = ["kind": .string(instrument.kind.rawValue)]
        switch instrument.kind {
        case .testTone:
            break
        case .polySynth:
            let fresh = PolySynthParams()
            let synth = instrument.polySynth
            for name in PolySynthParams.settingNames {
                if let value = synth.settingWaveform(name), value != fresh.settingWaveform(name) {
                    object[name] = .string(value.rawValue)
                } else if let value = synth.settingNumber(name), value != fresh.settingNumber(name) {
                    object[name] = .number(value)
                }
            }
        case .drumSynth:
            // W9-DRUMDEF: ALWAYS written — `{}` for the factory kit. A template
            // drum machine with neither `drumKit` nor `drumPreset` reads as a NEW
            // drum machine (the user's picks), so a captured factory kit (a saved
            // song's never-edited drum machine, which `normalizedKit` folds to
            // nil) must name itself to come back as itself.
            object["drumKit"] = drumKitObject(instrument.drumKit ?? DrumKitParams())
        case .soundBank:
            if let bank = instrument.soundBank {
                var entry: [String: TemplateJSON] = [
                    "source": .string(bank.source.rawString),
                    "program": .number(Double(bank.program)),
                ]
                if bank.bankMSB != GMProgramCatalog.melodicBankMSB {
                    entry["bankMSB"] = .number(Double(bank.bankMSB))
                }
                if bank.bankLSB != GMProgramCatalog.bankLSB {
                    entry["bankLSB"] = .number(Double(bank.bankLSB))
                }
                object["soundBank"] = .object(entry)
            }
        case .sampler:
            // m39-tpl-5b: the codec's own writer, beside its reader (one table).
            if let sampler = instrument.sampler, sampler != SamplerParams() {
                object["sampler"] = TemplateReader.samplerObject(sampler)
            }
        case .audioUnit:
            if let unit = instrument.audioUnit { object["audioUnit"] = audioUnitObject(unit) }
        }
        return .object(object)
    }

    static func drumKitObject(_ kit: DrumKitParams) -> TemplateJSON {
        let fresh = DrumKitParams()
        var root: [String: TemplateJSON] = [:]
        var voices: [String: [String: TemplateJSON]] = [:]
        for spec in DrumKitParams.paramSpecs {
            guard let value = kit.value(forParamName: spec.name),
                  value != fresh.value(forParamName: spec.name) else { continue }
            let parts = spec.name.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "kit" {
                root[parts[1]] = .number(value)
            } else {
                voices[parts[0], default: [:]][parts[1]] = .number(value)
            }
        }
        for voice in DrumVoice.allCases where kit[voice].chokeGroup != fresh[voice].chokeGroup {
            let group: TemplateJSON = kit[voice].chokeGroup.map { TemplateJSON.number(Double($0)) }
                ?? TemplateJSON.null
            voices[voice.rawValue, default: [:]]["chokeGroup"] = group
        }
        for (voice, leaves) in voices { root[voice] = .object(leaves) }
        if kit.noteLayout != fresh.noteLayout {
            root[DrumKitParams.noteLayoutKey] = .string(kit.noteLayout.rawValue)
        }
        return .object(root)
    }

    static func audioUnitObject(_ unit: AudioUnitConfig) -> TemplateJSON {
        var object: [String: TemplateJSON] = [
            "type": .string(unit.component.type),
            "subType": .string(unit.component.subType),
            "manufacturer": .string(unit.component.manufacturer),
        ]
        if let state = unit.stateData { object["state"] = .string(state.base64EncodedString()) }
        return .object(object)
    }

    static func insertObject(_ insert: TemplateInsert) -> TemplateJSON {
        var object: [String: TemplateJSON] = ["kind": .string(insert.kind.rawValue)]
        if let key = insert.key { object["key"] = .string(key) }
        if insert.bypassed { object["bypassed"] = .bool(true) }
        if !insert.params.isEmpty { object["params"] = .object(insert.params.mapValues { .number($0) }) }
        if let source = insert.sidechainSource { object["sidechainSource"] = .string(source) }
        if let unit = insert.audioUnit { object["audioUnit"] = audioUnitObject(unit) }
        return .object(object)
    }

    /// What a template keeps of a source's settings: a step sequencer locked to a
    /// note division drops its unused `rateHz` back to the default (see
    /// `sourceParams`), and a division string the app does not know — which runs
    /// free — is dropped. Every other source is unchanged.
    static func normalizedSourceParams(_ params: ModulationSourceParams) -> ModulationSourceParams {
        guard case .stepSequencer(var step) = params else { return params }
        if step.syncedDivision != nil {
            step.rateHz = StepSequencerSourceParams().rateHz
        } else {
            step.stepDivision = nil
        }
        return .stepSequencer(step)
    }

    static func sourceObject(_ source: TemplateModSource) -> TemplateJSON {
        var object: [String: TemplateJSON] = [
            "key": .string(source.key),
            "kind": .string(source.kind.rawValue),
        ]
        if let name = source.name { object["name"] = .string(name) }
        let params = sourceParams(source.params)
        if !params.isEmpty { object["params"] = .object(params) }
        return .object(object)
    }

    /// A source's settings that differ from its kind's defaults, by the names
    /// `ModulationSourceParams.apply(_:to:)` reads. A step sequencer's
    /// `stepDivision` IS written (a synced source must come back synced). Its
    /// `rateHz` is then NOT written: a synced source ignores it, and writing both
    /// would make every read of the template warn that the rate is unused. The
    /// cost, stated: clearing the sync later falls back to the default 4 steps
    /// a second, not the unused rate the source held. The LFO's `syncDivision`
    /// is never written (an LFO cannot sync).
    static func sourceParams(_ params: ModulationSourceParams) -> [String: TemplateJSON] {
        var out: [String: TemplateJSON] = [:]
        func number(_ name: String, _ value: Double, _ fresh: Double) {
            if value != fresh { out[name] = .number(value) }
        }
        switch (params, ModulationSourceParams.defaults(for: params.kind)) {
        case (.lfo(let p), .lfo(let d)):
            if p.waveform != d.waveform { out["waveform"] = .string(p.waveform.rawValue) }
            number("rateHz", p.rateHz, d.rateHz)
            number("phaseDeg", p.phaseDeg, d.phaseDeg)
            number("pulseWidth", p.pulseWidth, d.pulseWidth)
            number("edgeMs", p.edgeMs, d.edgeMs)
            if p.bipolar != d.bipolar { out["bipolar"] = .bool(p.bipolar) }
            number("seed", Double(p.seed), Double(d.seed))
        case (.stepSequencer(let p), .stepSequencer(let d)):
            if p.steps != d.steps { out["steps"] = .array(p.steps.map { .number($0) }) }
            if let division = p.syncedDivision {
                out["stepDivision"] = .string(division.rawValue)
            } else {
                number("rateHz", p.rateHz, d.rateHz)
            }
            number("edgeMs", p.edgeMs, d.edgeMs)
        case (.envelopeFollower(let p), .envelopeFollower(let d)):
            if p.detector != d.detector { out["detector"] = .string(p.detector.rawValue) }
            number("attackMs", p.attackMs, d.attackMs)
            number("releaseMs", p.releaseMs, d.releaseMs)
            number("floorDb", p.floorDb, d.floorDb)
            number("gainDb", p.gainDb, d.gainDb)
        case (.macro(let p), .macro(let d)):
            number("value", p.value, d.value)
        default:
            break
        }
        return out
    }

    static func routeObject(_ route: TemplateModRoute) -> TemplateJSON {
        var target: [String: TemplateJSON]
        switch route.target {
        case .volume: target = ["type": .string("volume")]
        case .pan: target = ["type": .string("pan")]
        case .instrumentParam(let param):
            target = ["type": .string("instrumentParam"), "param": .string(param)]
        case .effectParam(let insert, let param):
            target = ["type": .string("effectParam"), "insert": .string(insert),
                      "param": .string(param)]
        }
        var object: [String: TemplateJSON] = [
            "source": .string(route.source),
            "target": .object(target),
            "depth": .number(route.depth),
        ]
        if !route.enabled { object["enabled"] = .bool(false) }
        return .object(object)
    }

    // MARK: - Writing JSON

    /// Pretty JSON with SORTED keys. A whole number is written without a
    /// fraction; any other number in Swift's shortest form that reads back as
    /// the same `Double`.
    static func write(_ value: TemplateJSON, indent: Int, into text: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch value {
        case .null:
            text += "null"
        case .bool(let flag):
            text += flag ? "true" : "false"
        case .number(let number):
            text += numberText(number)
        case .string(let string):
            text += quoted(string)
        case .array(let items):
            if items.isEmpty { text += "[]"; return }
            let scalars = items.allSatisfy {
                if case .number = $0 { return true }
                if case .string = $0 { return true }
                return false
            }
            if scalars {
                text += "["
                for (index, item) in items.enumerated() {
                    if index > 0 { text += ", " }
                    write(item, indent: indent + 1, into: &text)
                }
                text += "]"
                return
            }
            text += "[\n"
            for (index, item) in items.enumerated() {
                text += inner
                write(item, indent: indent + 1, into: &text)
                text += index == items.count - 1 ? "\n" : ",\n"
            }
            text += pad + "]"
        case .object(let members):
            if members.isEmpty { text += "{}"; return }
            text += "{\n"
            let keys = members.keys.sorted()
            for (index, key) in keys.enumerated() {
                text += inner + quoted(key) + ": "
                write(members[key]!, indent: indent + 1, into: &text)
                text += index == keys.count - 1 ? "\n" : ",\n"
            }
            text += pad + "}"
        }
    }

    static func numberText(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 {
            return String(Int64(number))
        }
        return "\(number)"
    }

    static func quoted(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
