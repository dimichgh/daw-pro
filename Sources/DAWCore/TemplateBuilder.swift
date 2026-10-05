import Foundation

// m39-tpl-2 — THE TEMPLATE BUILDER
// (docs/design/2026-09-27-multi-instrument-templates.md §5.1, §5.3).
//
// Turns a `TrackSetTemplate` (already read by `TrackSetTemplateCodec`, or built
// in Swift, as the song skeleton's rosters will be in TPL-3) into the complete,
// wired `Track` values the store appends in ONE edit. Pure: Foundation only,
// nonisolated, no store, no engine, no file system — so every rule here is
// testable headless, with no main actor (§5.8).
//
// ⭐ IT THROWS BEFORE IT RETURNS ANYTHING. Six steps, in this order, and a
// failure in any of them throws a `TemplateRefusal` naming the path and what
// would be valid; nothing is half-built and nothing reaches the store:
//
//   1. references — every key resolves to the right KIND of thing inside the
//      template (no ids are minted yet: a step-1 refusal calls `makeID` zero
//      times, and a test pins that);
//   2. build — kind, name, volume, pan, the resolved instrument, the mixer
//      preset's fresh chain, then each insert from `newlyAdded(kind:)` with its
//      settings written through the ONE writer in `specs(for:)` order; every
//      send, modulation source and route value is made here too, unattached;
//   3. read-back — every setting step 2 WROTE must READ back as written;
//   4. wiring — outputs and sends through `RoutingRules`, then sidechain keys
//      one at a time through `SidechainRules`, each checked against the
//      template's own tracks with the earlier keys already in place;
//   5. modulation — sources, then each route through `ModulationRules`
//      (target rules, then the shared 64-slot budget);
//   6. resources — every sound bank, sampler zone file and Audio Unit, for the
//      store to check against this Mac before the edit.
//
// ⭐ A SETTER'S RETURN IS NOT PROOF IT TOOK; THE READING IS. `phaser.stages`
// stores 6 when asked for 5, `Track.init` clamps a volume of 3 to 2, and
// `Send.init` clamps a level — each silently. Step 3 reads every one back from
// the value that was actually built and refuses a difference (a newer file's
// difference is kept, with `valueChanged`, the codec's version rule). The
// codec already does this for templates it reads; the builder does it again
// because a template built in Swift never passed through the codec.
//
// ⚠️ WHAT `makeID` DOES NOT REACH: effect ids. A new insert is born in ONE
// home, `EffectDescriptor.newlyAdded(kind:)`, and a mixer preset's chain in
// another, `MixerPreset.freshChain()`; both mint `UUID()` and `id` is a `let`.
// Giving them an injected id would mean a second per-kind field list (the
// compiler-silent `withFreshID()` defect the design names), so effect ids stay
// fresh, which is all "applying twice never collides" needs. `makeID` mints,
// in this order: every track id (template order), then per track its Sampler
// zone ids (m39-tpl-5b), its send ids, its modulation source ids and its route
// ids.
//
// ⭐ m39-tpl-5b — A SAMPLER'S ZONES GET NEW IDS HERE. `ProjectDocument` keys
// every zone's sample file by zone id in ONE project-wide map, so a template's
// Sampler added beside the track it was saved from (or added twice) must not
// share a single zone id with it. A template carries only placeholder ids
// (`TemplateReader.samplerZoneID`); every zone the instrument carries — the
// active Sampler's or an inactive block's, since the project file saves both —
// is re-identified through `TemplateReader.samplerZone(_:id:)`.

/// A file-backed item a template's tracks depend on. The builder LISTS them;
/// the store checks each against this Mac before the edit (§5.4).
public struct TemplateResource: Sendable, Equatable {
    public enum Item: Sendable, Equatable {
        /// A sound-bank instrument: General MIDI (the Mac's own bank file) or
        /// a bank file of the user's.
        case soundBank(SoundBankConfig)
        /// A Sampler's zone files.
        case samplerZones([SamplerZone])
        /// An Audio Unit instrument. A missing one is a WARNING, never a
        /// refusal: the track keeps the plug-in reference, the way a project
        /// with a missing plug-in opens.
        case audioUnitInstrument(AudioUnitConfig)
        /// An Audio Unit insert effect (same rule).
        case audioUnitEffect(AudioUnitConfig)
    }

    /// The key of the track that needs it.
    public var trackKey: String
    /// Where in the template, e.g. `tracks[1].instrument.soundBank`.
    public var path: String
    public var item: Item

    public init(trackKey: String, path: String, item: Item) {
        self.trackKey = trackKey
        self.path = path
        self.item = item
    }
}

/// Everything a template adds, built and wired, before anything is added.
public struct TemplatePlan: Sendable, Equatable {
    /// Complete and wired among themselves, in template order, with fresh ids.
    public var tracks: [Track]
    /// Every template track key → its new track's id.
    public var keyToTrackID: [String: UUID]
    /// What the builder worked around (`modulationTargetWarned`, and
    /// `valueChanged` for a newer file), each `{code, path, message}`.
    public var warnings: [TemplateWarning]
    /// True when any track plays into a bus, sends, or keys a sidechain: the
    /// store refuses such a template while recording.
    public var hasRouting: Bool
    /// File-backed items the store must check first (§5.4 step 2).
    public var resources: [TemplateResource]
    /// Per track key: how many of the strip's 64 effect-setting slots its
    /// modulation uses (a new track has no automation, so this is its count of
    /// distinct modulated effect settings).
    public var slotsUsed: [String: Int]

    public init(tracks: [Track], keyToTrackID: [String: UUID], warnings: [TemplateWarning],
                hasRouting: Bool, resources: [TemplateResource], slotsUsed: [String: Int]) {
        self.tracks = tracks
        self.keyToTrackID = keyToTrackID
        self.warnings = warnings
        self.hasRouting = hasRouting
        self.resources = resources
        self.slotsUsed = slotsUsed
    }
}

public enum TemplateBuilder {
    /// Inserts per track, the mixer preset's chain included. The SAME number
    /// as `ProjectStore.maxEffectsPerChain`, which this nonisolated code
    /// cannot read (a `static let` on a `@MainActor` class);
    /// `SongSkeletonTests.tpl2ChainCapIsTheStores` pins the two equal.
    public static let maxEffectsPerChain = 16

    /// Builds `template` into tracks, or throws `TemplateRefusal` before
    /// returning anything. `makeID` is injected so tests are deterministic;
    /// production uses fresh UUIDs, so applying twice can never collide.
    public static func plan(_ template: TrackSetTemplate,
                            makeID: () -> UUID = UUID.init) throws -> TemplatePlan {
        let lenient = template.formatVersion > TrackSetTemplate.currentFormatVersion
        try checkReferences(template)                                         // 1
        var built = try build(template, makeID: makeID)                       // 2
        var warnings = try readBack(built.probes, lenient: lenient)           // 3
        try wire(template, &built)                                            // 4
        warnings += try addModulation(template, &built)                       // 5
        let resources = listResources(template)                               // 6

        var slotsUsed: [String: Int] = [:]
        for (index, track) in built.tracks.enumerated() {
            slotsUsed[template.tracks[index].key] = ModulationRules.slotsUsed(by: track)
        }
        let hasRouting = built.tracks.contains { track in
            track.outputBusID != nil || !track.sends.isEmpty
                || track.effects.contains { $0.sidechainSourceTrackID != nil }
        }
        return TemplatePlan(tracks: built.tracks, keyToTrackID: built.trackIDs,
                            warnings: warnings, hasRouting: hasRouting,
                            resources: resources, slotsUsed: slotsUsed)
    }

    // MARK: - Paths

    static func trackPath(_ index: Int) -> String { "tracks[\(index)]" }

    // MARK: - Step 1: references

    /// Every key is unique where it must be, and every reference resolves to
    /// the right kind of thing inside the template (§4.4). Nothing is matched
    /// by name, and nothing is matched against the song.
    static func checkReferences(_ template: TrackSetTemplate) throws {
        let range = TrackSetTemplateCodec.trackCountRange
        guard range.contains(template.tracks.count) else {
            throw TemplateRefusal(
                code: .outOfRange, path: "tracks",
                message: "a template has \(range.lowerBound) to \(range.upperBound) tracks; "
                    + "this one has \(template.tracks.count).")
        }
        var kindByKey: [String: TrackKind] = [:]
        for (index, track) in template.tracks.enumerated() {
            guard kindByKey[track.key] == nil else {
                throw TemplateRefusal(
                    code: .duplicateKey, path: "\(trackPath(index)).key",
                    message: "another track already uses the key '\(track.key)'. Every track "
                        + "needs its own key.")
            }
            kindByKey[track.key] = track.kind
        }
        let busKeys = template.tracks.filter { $0.kind == .bus }.map(\.key)
        let busList = busKeys.isEmpty
            ? "This template has no buses."
            : "The buses in this template are: \(busKeys.joined(separator: ", "))."
        let trackList = "The tracks in this template are: "
            + "\(template.tracks.map(\.key).joined(separator: ", "))."

        func requireBus(_ key: String, _ path: String) throws {
            guard let kind = kindByKey[key] else {
                throw TemplateRefusal(code: .invalidValue, path: path,
                                      message: "there is no bus with the key '\(key)'. \(busList)")
            }
            guard kind == .bus else {
                throw TemplateRefusal(
                    code: .invalidValue, path: path,
                    message: "'\(key)' is not a bus, and a track can only play or send into a "
                        + "bus. \(busList)")
            }
        }

        for (index, track) in template.tracks.enumerated() {
            let path = trackPath(index)
            if let output = track.output { try requireBus(output, "\(path).output") }
            for (position, send) in track.sends.enumerated() {
                try requireBus(send.bus, "\(path).sends[\(position)].bus")
            }
            var insertKeys: Set<String> = []
            for (position, insert) in track.inserts.enumerated() {
                let insertPath = "\(path).inserts[\(position)]"
                if let key = insert.key, !insertKeys.insert(key).inserted {
                    throw TemplateRefusal(
                        code: .duplicateKey, path: "\(insertPath).key",
                        message: "another effect on this track already uses the key '\(key)'.")
                }
                guard let source = insert.sidechainSource else { continue }
                let sourcePath = "\(insertPath).sidechainSource"
                guard let kind = kindByKey[source] else {
                    throw TemplateRefusal(code: .invalidValue, path: sourcePath,
                                          message: "there is no track with the key '\(source)'. "
                                            + trackList)
                }
                guard kind != .bus else {
                    throw TemplateRefusal(
                        code: .invalidValue, path: sourcePath,
                        message: "'\(source)' is a bus, and a sidechain listens to a track that "
                            + "plays, not to a bus. Key it from a track that feeds the bus.")
                }
            }
            var sourceKeys: Set<String> = []
            for (position, source) in track.modulationSources.enumerated() {
                guard sourceKeys.insert(source.key).inserted else {
                    throw TemplateRefusal(
                        code: .duplicateKey, path: "\(path).modulation.sources[\(position)].key",
                        message: "another modulation source on this track already uses the key "
                            + "'\(source.key)'.")
                }
            }
            let insertKeyList = track.inserts.compactMap(\.key)
            for (position, route) in track.modulationRoutes.enumerated() {
                let routePath = "\(path).modulation.routes[\(position)]"
                guard sourceKeys.contains(route.source) else {
                    let known = track.modulationSources.map(\.key)
                    throw TemplateRefusal(
                        code: .invalidValue, path: "\(routePath).source",
                        message: "there is no modulation source with the key '\(route.source)' on "
                            + "this track. "
                            + (known.isEmpty
                                ? "This track has no modulation sources."
                                : "Its sources are: \(known.joined(separator: ", "))."))
                }
                if case .effectParam(let insert, _) = route.target, !insertKeys.contains(insert) {
                    throw TemplateRefusal(
                        code: .invalidValue, path: "\(routePath).target.insert",
                        message: "there is no effect with the key '\(insert)' on this track. "
                            + (insertKeyList.isEmpty
                                ? "None of this track's effects has a key."
                                : "Its effects with keys are: "
                                    + "\(insertKeyList.joined(separator: ", "))."))
                }
            }
        }
    }

    // MARK: - Step 2: build

    /// One written setting and what it reads back as.
    struct Probe: Equatable {
        var path: String
        var name: String
        var written: Double
        var read: Double?
    }

    /// The tracks under construction, plus the values steps 4 and 5 attach.
    struct Built {
        /// In template order; `tracks[i]` is `template.tracks[i]`.
        var tracks: [Track] = []
        var trackIDs: [String: UUID] = [:]
        /// Per track: how many effects the mixer preset put BEFORE the
        /// template's inserts, so insert `j` is effect `presetCount + j`.
        var presetCounts: [Int] = []
        /// Per track: insert key → effect id.
        var insertIDs: [[String: UUID]] = []
        /// Per track, in order, not yet attached.
        var sends: [[Send]] = []
        var sources: [[ModulationSource]] = []
        var routes: [[ModulationRoute]] = []
        var probes: [Probe] = []
    }

    static func build(_ template: TrackSetTemplate, makeID: () -> UUID) throws -> Built {
        var built = Built()
        // Track ids first, in template order, so every reference can resolve.
        var orderedIDs: [UUID] = []
        for track in template.tracks {
            let id = makeID()
            orderedIDs.append(id)
            built.trackIDs[track.key] = id
        }
        for (index, spec) in template.tracks.enumerated() {
            let path = trackPath(index)
            if spec.instrument != nil, spec.kind != .instrument {
                throw TemplateRefusal(
                    code: .invalidValue, path: "\(path).instrument",
                    message: "only an instrument track can have an instrument, and this track is "
                        + "\(spec.kind == .bus ? "a bus" : "an audio track").")
            }
            var instrument = spec.kind == .instrument ? spec.instrument : nil
            if var sampler = instrument?.sampler, !sampler.zones.isEmpty {
                sampler.zones = sampler.zones.map { TemplateReader.samplerZone($0, id: makeID()) }
                instrument?.sampler = sampler
            }
            var track = Track(id: orderedIDs[index], name: spec.name, kind: spec.kind,
                              volume: spec.volume, pan: spec.pan, instrument: instrument)
            built.probes.append(Probe(path: "\(path).volume", name: "volume",
                                      written: spec.volume, read: track.volume))
            built.probes.append(Probe(path: "\(path).pan", name: "pan",
                                      written: spec.pan, read: track.pan))

            // The mixer preset's chain FIRST, then the inserts (§4.5).
            var effects: [EffectDescriptor] = []
            if let presetName = spec.mixerPreset {
                guard let preset = MixerPresetCatalog.preset(named: presetName) else {
                    throw TemplateRefusal(
                        code: .unknownKind, path: "\(path).mixerPreset",
                        message: "there is no mixer preset called '\(presetName)'. The presets "
                            + "are: \(MixerPresetCatalog.names.joined(separator: ", ")).")
                }
                effects = preset.freshChain()
            }
            let presetCount = effects.count
            guard presetCount + spec.inserts.count <= maxEffectsPerChain else {
                let preset = presetCount == 0
                    ? ""
                    : " (\(presetCount) from the mixer preset '\(spec.mixerPreset ?? "")')"
                throw TemplateRefusal(
                    code: .outOfRange, path: "\(path).inserts",
                    message: "a track can hold at most \(maxEffectsPerChain) effects, and this one "
                        + "would have \(presetCount + spec.inserts.count)\(preset).")
            }
            var insertIDs: [String: UUID] = [:]
            for (position, insert) in spec.inserts.enumerated() {
                let insertPath = "\(path).inserts[\(position)]"
                let effect = try buildInsert(insert, insertPath, probes: &built.probes)
                if let key = insert.key { insertIDs[key] = effect.id }
                effects.append(effect)
            }
            track.effects = effects

            var sends: [Send] = []
            for (position, send) in spec.sends.enumerated() {
                // Step 1 resolved every bus key, so the lookup cannot miss.
                let busID = built.trackIDs[send.bus] ?? UUID()
                let value = Send(id: makeID(), destinationBusID: busID, level: send.level)
                built.probes.append(Probe(path: "\(path).sends[\(position)].level", name: "level",
                                          written: send.level, read: value.level))
                sends.append(value)
            }

            var sources: [ModulationSource] = []
            var sourceIDs: [String: UUID] = [:]
            for source in spec.modulationSources {
                // The template carries RESOLVED settings (the codec ran them
                // through `ModulationSourceParams.apply`, whose clamp warning
                // it treats as a failed read-back), so they are copied as they
                // are; `name` nil takes the name `mod.addSource` would give it.
                let value = ModulationSource(id: makeID(), kind: source.kind, name: source.name,
                                             params: source.params)
                sourceIDs[source.key] = value.id
                sources.append(value)
            }

            var routes: [ModulationRoute] = []
            for (position, route) in spec.modulationRoutes.enumerated() {
                let target: AutomationTarget
                switch route.target {
                case .volume: target = .volume
                case .pan: target = .pan
                case .instrumentParam(let param): target = .instrumentParam(paramName: param)
                case .effectParam(let insert, let param):
                    target = .effectParam(effectID: insertIDs[insert] ?? UUID(), paramName: param)
                }
                let value = ModulationRoute(id: makeID(), sourceID: sourceIDs[route.source] ?? UUID(),
                                            target: target, depth: route.depth,
                                            enabled: route.enabled)
                built.probes.append(Probe(path: "\(path).modulation.routes[\(position)].depth",
                                          name: "depth", written: route.depth, read: value.depth))
                routes.append(value)
            }

            built.tracks.append(track)
            built.presetCounts.append(presetCount)
            built.insertIDs.append(insertIDs)
            built.sends.append(sends)
            built.sources.append(sources)
            built.routes.append(routes)
        }
        return built
    }

    /// One insert, fresh from `newlyAdded(kind:)`, its settings written
    /// through the one writer in `specs(for:)` order, THEN every one read back
    /// (so a later write that changes an earlier one is caught too).
    static func buildInsert(_ insert: TemplateInsert, _ path: String,
                            probes: inout [Probe]) throws -> EffectDescriptor {
        if insert.kind == .audioUnit, insert.audioUnit == nil {
            throw TemplateRefusal(code: .missingKey, path: "\(path).audioUnit",
                                  message: "this is required: the plug-in to load: "
                                    + "{\"subType\", \"manufacturer\"}.")
        }
        if insert.kind != .audioUnit, insert.audioUnit != nil {
            throw TemplateRefusal(code: .invalidValue, path: "\(path).audioUnit",
                                  message: "only an effect whose kind is \"audioUnit\" can name an "
                                    + "Audio Unit.")
        }
        let specs = EffectParamSpec.specs(for: insert.kind)
        for name in insert.params.keys.sorted() where !specs.contains(where: { $0.name == name }) {
            let valid = specs.isEmpty
                ? "this effect has no settings you can set by name"
                : "its settings are: \(specs.map(\.name).joined(separator: ", "))"
            throw TemplateRefusal(code: .unknownSetting, path: "\(path).params.\(name)",
                                  message: "a \(insert.kind.rawValue) effect has no setting called "
                                    + "'\(name)'; \(valid).")
        }
        var effect = EffectDescriptor.newlyAdded(
            kind: insert.kind, audioUnit: insert.kind == .audioUnit ? insert.audioUnit : nil)
        effect.isBypassed = insert.bypassed
        for spec in specs {
            // ⚠️ Clamped to the spec's range FIRST, exactly as `fx.setParam`
            // does: `applySetting` trusts its caller ("an already-clamped
            // value") and STORES an out-of-range number as given, and
            // `paramValue` reads that number straight back — so without this
            // clamp a ratio of 200 would be written, read back as 200, pass,
            // and sit in the song outside the range every other path enforces
            // (MEASURED: `readBackRefusesAPlantedSnapOrClamp`'s ratio row was
            // planned, not refused, until this line). With it, the reading
            // differs from what was asked and step 3 refuses it.
            if let value = insert.params[spec.name] {
                effect.applySetting(spec.name, value.clamped(to: spec.range))
            }
        }
        for spec in specs {
            guard let written = insert.params[spec.name] else { continue }
            probes.append(Probe(path: "\(path).params.\(spec.name)", name: spec.name,
                                written: written, read: effect.paramValue(spec.name)))
        }
        return effect
    }

    // MARK: - Step 3: read-back

    /// Every written setting must read back as written, within the codec's
    /// tolerance, judged by the codec's own strict reader (one home for the
    /// tolerance and the refusal sentence). A newer file's difference is kept
    /// — the built value already holds what was stored — with `valueChanged`.
    static func readBack(_ probes: [Probe], lenient: Bool) throws -> [TemplateWarning] {
        var warnings: [TemplateWarning] = []
        var reader = TemplateReader(origin: .inline)   // never lenient: readTemplate is not run
        for probe in probes {
            do {
                _ = try reader.readBack(written: probe.written, read: probe.read, probe.path,
                                        probe.name)
            } catch let refusal as TemplateRefusal where lenient {
                let became = probe.read.map { ClampNotice.number($0) } ?? "nothing"
                warnings.append(TemplateWarning(
                    code: .valueChanged, path: refusal.path,
                    message: "\(probe.name) can't hold \(ClampNotice.number(probe.written)) in "
                        + "this version of DAW Pro, so it was set to \(became)."))
            }
        }
        return warnings
    }

    // MARK: - Step 4: wiring

    static func wire(_ template: TrackSetTemplate, _ built: inout Built) throws {
        // Outputs and sends FIRST, for every track, so the sidechain loop check
        // below sees the template's whole signal flow.
        for (index, spec) in template.tracks.enumerated() {
            let path = trackPath(index)
            if let output = spec.output, let busID = built.trackIDs[output] {
                do {
                    try RoutingRules.checkOutput(of: built.tracks[index].id, to: busID,
                                                 in: built.tracks)
                } catch {
                    throw routingRefusal(error, "\(path).output", built.tracks[index].name,
                                         busName: trackName(of: busID, in: built.tracks))
                }
                built.tracks[index].outputBusID = busID
            }
            for (position, send) in built.sends[index].enumerated() {
                do {
                    try RoutingRules.checkSend(from: built.tracks[index].id,
                                               to: send.destinationBusID, in: built.tracks)
                } catch {
                    throw routingRefusal(error, "\(path).sends[\(position)].bus",
                                         built.tracks[index].name,
                                         busName: trackName(of: send.destinationBusID,
                                                            in: built.tracks))
                }
                built.tracks[index].sends.append(send)
            }
        }
        // Then the sidechain keys, one at a time, each judged against the
        // tracks with every earlier key already set.
        for (index, spec) in template.tracks.enumerated() {
            for (position, insert) in spec.inserts.enumerated() {
                guard let sourceKey = insert.sidechainSource,
                      let sourceID = built.trackIDs[sourceKey] else { continue }
                let effectIndex = built.presetCounts[index] + position
                let effectID = built.tracks[index].effects[effectIndex].id
                do {
                    try SidechainRules.check(keying: built.tracks[index].id, effect: effectID,
                                             from: sourceID, in: built.tracks)
                } catch {
                    throw sidechainRefusal(
                        error, "\(trackPath(index)).inserts[\(position)].sidechainSource",
                        trackName: built.tracks[index].name, kind: insert.kind,
                        selfKeyed: sourceID == built.tracks[index].id)
                }
                built.tracks[index].effects[effectIndex].sidechainSourceTrackID = sourceID
            }
        }
    }

    static func trackName(of id: UUID, in tracks: [Track]) -> String {
        tracks.first(where: { $0.id == id })?.name ?? id.uuidString
    }

    /// `RoutingRules`' refusals, in the template's words.
    static func routingRefusal(_ error: any Error, _ path: String, _ trackName: String,
                               busName: String) -> TemplateRefusal {
        switch error as? ProjectError {
        case .busRoutingFixed?:
            return TemplateRefusal(
                code: .invalidValue, path: path,
                message: "'\(trackName)' is a bus, and a bus always plays straight into the main "
                    + "output: it can't play into another bus or send to one.")
        case .duplicateSend?:
            return TemplateRefusal(
                code: .invalidValue, path: path,
                message: "'\(trackName)' already sends to '\(busName)'. A track can send to each "
                    + "bus once; set that send's level instead.")
        default:
            return TemplateRefusal(code: .invalidValue, path: path,
                                   message: error.localizedDescription)
        }
    }

    /// `SidechainRules`' refusals, in the template's words.
    static func sidechainRefusal(_ error: any Error, _ path: String, trackName: String,
                                 kind: EffectDescriptor.Kind, selfKeyed: Bool) -> TemplateRefusal {
        let message: String
        switch error as? ProjectError {
        case .sidechainUnsupportedEffect?:
            message = "a sidechain can only be set on a compressor or a gate, and this effect is "
                + "a \(kind.rawValue)."
        case .sidechainUnsupportedTrack?:
            message = "only an audio track or a bus can listen to a sidechain, and "
                + "'\(trackName)' is an instrument track. Play it into a bus, and put the "
                + "compressor on the bus."
        case .sidechainOneSourcePerStrip?:
            message = "'\(trackName)' already has an effect that listens to a sidechain, and a "
                + "track can listen to only one."
        case .sidechainWouldCreateCycle(let detail)?:
            let prefix = "sidechain would create a feedback cycle: "
            let loop = detail.hasPrefix(prefix) ? String(detail.dropFirst(prefix.count)) : detail
            message = selfKeyed
                ? "a track can't listen to itself: '\(trackName)' would be keyed by its own sound."
                : "this would make a feedback loop: \(loop)."
        default:
            message = error.localizedDescription
        }
        return TemplateRefusal(code: .invalidValue, path: path, message: message)
    }

    // MARK: - Step 5: modulation

    static func addModulation(_ template: TrackSetTemplate,
                              _ built: inout Built) throws -> [TemplateWarning] {
        var warnings: [TemplateWarning] = []
        for index in template.tracks.indices {
            let path = trackPath(index)
            let sources = built.sources[index]
            guard sources.count <= ModulationLimits.maxSources else {
                throw TemplateRefusal(
                    code: .outOfRange, path: "\(path).modulation.sources",
                    message: "a track can have at most \(ModulationLimits.maxSources) modulation "
                        + "sources, and this one has \(sources.count). One source can move many "
                        + "settings, so share one instead.")
            }
            // Assigned, never passed through `Track.init`, which silently keeps
            // only the first 16 sources and 64 routes.
            built.tracks[index].modulationSources = sources
            for (position, route) in built.routes[index].enumerated() {
                let routePath = "\(path).modulation.routes[\(position)]"
                // The target rules, then the shared budget, then the route cap.
                // (`mod.addRoute` checks the cap first; on a template track the
                // budget can only be exceeded by a 65th route, so checking the cap
                // first would make the budget's own refusal — the one that
                // explains the shared 64 slots — unreachable.)
                let notes: [String]
                do {
                    notes = try ModulationRules.validate(target: route.target,
                                                         on: .track(built.tracks[index]))
                } catch let error as ModulationError {
                    var code = TemplateRefusal.Code.invalidValue
                    if case .modulationTargetUnsupported(_, .unknownParam, _) = error {
                        code = .unknownSetting
                    }
                    throw TemplateRefusal(code: code, path: "\(routePath).target",
                                          message: error.localizedDescription)
                } catch {
                    throw TemplateRefusal(code: .invalidValue, path: "\(routePath).target",
                                          message: error.localizedDescription)
                }
                if case .effectParam = route.target {
                    do {
                        try ModulationRules.checkCombinedBudget(on: built.tracks[index],
                                                                adding: route.target)
                    } catch {
                        throw TemplateRefusal(code: .outOfRange, path: routePath,
                                              message: error.localizedDescription)
                    }
                }
                guard built.tracks[index].modulationRoutes.count < ModulationLimits.maxRoutes else {
                    throw TemplateRefusal(
                        code: .outOfRange, path: routePath,
                        message: "a track can have at most \(ModulationLimits.maxRoutes) "
                            + "modulation routes, and this is route \(position + 1).")
                }
                built.tracks[index].modulationRoutes.append(route)
                // A `warned` target (it steps, or aliases) becomes a plan
                // warning, exactly as `mod.addRoute` returns it.
                for note in notes {
                    let (_, sentence) = TemplateReader.splitModulationWarning(note)
                    warnings.append(TemplateWarning(code: .modulationTargetWarned,
                                                    path: "\(routePath).target",
                                                    message: sentence))
                }
            }
        }
        return warnings
    }

    // MARK: - Step 6: resources

    static func listResources(_ template: TrackSetTemplate) -> [TemplateResource] {
        var resources: [TemplateResource] = []
        for (index, track) in template.tracks.enumerated() {
            let path = trackPath(index)
            if track.kind == .instrument, let instrument = track.instrument {
                switch instrument.kind {
                case .soundBank:
                    if let bank = instrument.soundBank {
                        resources.append(TemplateResource(
                            trackKey: track.key, path: "\(path).instrument.soundBank",
                            item: .soundBank(bank)))
                    }
                case .sampler:
                    if let zones = instrument.sampler?.zones, !zones.isEmpty {
                        resources.append(TemplateResource(
                            trackKey: track.key, path: "\(path).instrument.sampler",
                            item: .samplerZones(zones)))
                    }
                case .audioUnit:
                    if let unit = instrument.audioUnit {
                        resources.append(TemplateResource(
                            trackKey: track.key, path: "\(path).instrument.audioUnit",
                            item: .audioUnitInstrument(unit)))
                    }
                case .testTone, .polySynth, .drumSynth:
                    break
                }
            }
            for (position, insert) in track.inserts.enumerated() {
                if insert.kind == .audioUnit, let unit = insert.audioUnit {
                    resources.append(TemplateResource(
                        trackKey: track.key, path: "\(path).inserts[\(position)].audioUnit",
                        item: .audioUnitEffect(unit)))
                }
            }
        }
        return resources
    }
}
