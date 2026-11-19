import Foundation
import Testing
@testable import DAWCore

// W7-MODP (2026-10-04) — EVERY SETTING MUST REACH THE FILE.
//
// m39-e's modulation (LFOs, step sequencers, envelope followers, macros, and their routes) shipped in a state
// where a save silently dropped all of it: `Track` carried the arrays and encoded them in its OWN `Codable`,
// every §7.6 test exercised that `Codable`, and `TrackDocument` — the save format — never mentioned them. The
// master strip's arrays lived only in `ProjectStore`, and `ProjectDocument` had no field for them either
// (design `2026-09-19-modulation-layer.md` §16). Nothing failed, because nothing compared the model to the file.
//
// This file is that comparison, in three gates:
//   G1 (in `extension PersistenceTests`, because it drives the @MainActor store — an EXISTING @MainActor suite,
//       so no new one): the store's REAL save → open, crash recovery, New, and undo.
//   G2 byte identity: four modulation-free projects encode to EXACTLY the bytes the pre-fix encoder wrote
//       (goldens captured on the unmodified e6f7a27 DAWCore, `Fixtures/ProjectDocumentFidelity/`).
//   G3 classification: `Mirror` enumerates the stored properties of every mirrored type, and of the store;
//       each one must be classified as saved (under which key) or deliberately not (and why). A property
//       nobody classified FAILS BY NAME — which is what would have caught m39-e on the day it landed.
//
// ⚠️ G3 covers the types with a hand-written document mirror, the modulation param structs (whose encoder is
// hand-written), `ProjectDocument` and `ProjectStore`. It does NOT reach inside types that persist through
// their OWN Codable (`PolySynthParams`, `AutomationLane`, `PitchEditSet`, …); `SamplerParams`' globals are
// classified by `PedalHoldLimitCodableTests` (one home, not two).
@Suite("Project document fidelity — every setting reaches the file (W7-MODP)")
struct ProjectDocumentFidelityTests {

    // MARK: - Helpers

    static func tempBundle(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("modp-\(name)-\(UUID().uuidString).dawproj", isDirectory: true)
    }

    /// `project.json` exactly as a save writes it: through `ProjectBundle.write`, the one encoder the app uses.
    static func bundleBytes(of document: ProjectDocument) throws -> Data {
        let bundle = tempBundle("g2")
        defer { try? FileManager.default.removeItem(at: bundle) }
        try ProjectBundle.write(document: document,
                                plan: ProjectBundle.MediaPlan(copies: [], refs: [:], warnings: []), to: bundle)
        return try Data(contentsOf: bundle.appendingPathComponent("project.json"))
    }

    /// Writes the document as a bundle and reads it back through the real open path's reader.
    static func reopen(_ document: ProjectDocument) throws -> (document: ProjectDocument, bundle: URL, bytes: Data) {
        let bundle = tempBundle("g3")
        try ProjectBundle.write(document: document,
                                plan: ProjectBundle.MediaPlan(copies: [], refs: [:], warnings: []), to: bundle)
        let bytes = try Data(contentsOf: bundle.appendingPathComponent("project.json"))
        return (try ProjectBundle.read(from: bundle), bundle, bytes)
    }

    static func firstDifference(_ actual: Data, _ expected: Data) -> String {
        let a = String(decoding: actual, as: UTF8.self).components(separatedBy: "\n")
        let e = String(decoding: expected, as: UTF8.self).components(separatedBy: "\n")
        for i in 0..<max(a.count, e.count) {
            let got = i < a.count ? a[i] : "<end of file>"
            let want = i < e.count ? e[i] : "<end of file>"
            if got != want { return "line \(i + 1): wrote «\(got)», golden has «\(want)»" }
        }
        return "no line differs"
    }

    /// Every effect kind, non-default in every field — `EffectDocumentMirrorTests`' table, shared (one home).
    static func everyEffectKind() -> [EffectDescriptor] {
        EffectDocumentMirrorTests.fixtures.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value)
    }

    /// The master strip carries every source kind too, routed to a master effect param among others.
    static func masterModulation() -> (sources: [ModulationSource], routes: [ModulationRoute]) {
        (MODPFixture.modulationSources(base: 4_000),
         MODPFixture.modulationRoutes(base: 4_000,
                                      extra: [.effectParam(effectID: MODPFixture.id(90), paramName: "ceilingDb")]))
    }

    /// The kitchen sink, plus every effect kind on the Vox track, plus master modulation: every persisted
    /// setting of every mirrored type is off its default somewhere in here (G3's non-vacuity test proves it).
    static func everythingDocument() throws -> (document: ProjectDocument, tracks: [Track],
                                                transport: TransportState) {
        var tracks = MODPFixture.kitchenSinkTracks(modulated: true)
        tracks[1].effects += everyEffectKind()
        // p2-sing-x5: a singing style off its default in every field, on the Keys melody (notes 401/402), so G3
        // can see `Clip.singStyle` reach the file. Added HERE, not in `MODPFixture`, so the G2 goldens (built from
        // the fixture) keep their pre-x5 bytes.
        tracks[2].clips[0].singStyle = SingStyle(
            vibrato: .wide, air: 0.4, followVelocity: true,
            notes: [MODPFixture.id(401): NoteSingStyle(vibrato: .straight, air: 0),
                    MODPFixture.id(402): NoteSingStyle(air: 0.9)])
        // m39-w4-6: a drum role on the kitchen sink's sampler zone, so G3 can see `SamplerZone.drumRole` reach
        // the file. HERE, not in `MODPFixture`, for the same reason: the G2 goldens keep their pre-w4-6 bytes.
        tracks[2].instrument?.sampler?.zones[0].drumRole = .cymbal
        let transport = try MODPFixture.kitchenSinkTransport()
        let base = try MODPFixture.kitchenSinkDocument(modulated: true, absoluteMedia: true)
        let master = masterModulation()
        var document = ProjectDocument(
            name: base.name, transport: transport, tracks: tracks, masterVolume: base.masterVolume,
            mediaRefs: MODPFixture.mediaRefs(absolute: true), grooveTemplates: base.grooveTemplates ?? [],
            markers: base.markers ?? [], tempoMapRevision: base.tempoMapRevision ?? 0,
            masterEffects: (base.masterEffects ?? []).compactMap { $0.effectDescriptor() },
            masterAutomation: base.masterAutomation ?? [], copilotChats: base.copilotChats ?? [],
            reference: MODPFixture.referenceSlot(),
            masterModulationSources: master.sources, masterModulationRoutes: master.routes,
            // m39-panlaw-new: off its default, so the round trip proves it is saved.
            panLaw: .equalPower)
        document.savedAt = MODPFixture.savedAt
        return (document, tracks, transport)
    }

    // MARK: - G2: a project WITHOUT modulation saves byte-for-byte as it did before the fix

    func assertGolden(_ name: String) throws {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json",
                              subdirectory: "Fixtures/ProjectDocumentFidelity"),
            "the golden \(name).json is not in the test bundle — a missing file must not read as a match")
        let expected = try Data(contentsOf: url)
        #expect(expected.count > 400, "the golden \(name).json is implausibly small (\(expected.count) bytes)")
        let found = try MODPFixture.goldenDocuments().first(where: { $0.name == name })
        let document = try #require(found?.document, "no golden fixture named \(name)")
        let actual = try Self.bundleBytes(of: document)
        #expect(actual == expected, """
            G2 \(name): a modulation-free project no longer saves byte-identically to the pre-fix encoder \
            (\(actual.count) vs \(expected.count) bytes). First difference — \
            \(Self.firstDifference(actual, expected)). An EMPTY array encoded instead of omitted is the \
            usual cause: every additive field must be nil when empty.
            """)
    }

    @Test("G2: an empty project saves byte-identically to the pre-fix encoder")
    func goldenEmptyProjectIsByteIdentical() throws { try assertGolden("empty") }

    @Test("G2: a simple audio + synth project saves byte-identically to the pre-fix encoder")
    func goldenSimpleProjectIsByteIdentical() throws { try assertGolden("simple") }

    @Test("G2: a bus + send project saves byte-identically to the pre-fix encoder")
    func goldenRoutedProjectIsByteIdentical() throws { try assertGolden("routed") }

    @Test("G2: the modulation-free kitchen sink (every other setting changed) saves byte-identically")
    func goldenKitchenSinkIsByteIdentical() throws { try assertGolden("kitchen-sink") }

    /// The control that keeps G2 honest: the same comparison DOES fail when the project carries modulation,
    /// and the modulated file names both new keys — so a G2 green cannot come from an encoder that writes
    /// nothing new at all.
    @Test("G2 control: the byte comparison CAN fail, and a modulated project writes both keys")
    func goldenComparisonCanFail() throws {
        let golden = try #require(
            Bundle.module.url(forResource: "kitchen-sink", withExtension: "json",
                              subdirectory: "Fixtures/ProjectDocumentFidelity"))
        let modulated = try Self.bundleBytes(
            of: try MODPFixture.kitchenSinkDocument(modulated: true, absoluteMedia: false))
        let goldenBytes = try Data(contentsOf: golden)
        #expect(modulated != goldenBytes)
        let text = String(decoding: modulated, as: UTF8.self)
        #expect(text.contains("\"modulationSources\""))
        #expect(text.contains("\"modulationRoutes\""))
        let master = try Self.bundleBytes(of: try Self.everythingDocument().document)
        let masterText = String(decoding: master, as: UTF8.self)
        #expect(masterText.contains("\"masterModulationSources\""))
        #expect(masterText.contains("\"masterModulationRoutes\""))
    }

    // MARK: - G3: every stored property is classified — saved under a key, or deliberately not

    enum Verdict: Sendable, Equatable {
        /// Reaches `project.json`, under this key.
        case saved(String)
        /// Deliberately session-only, and why (the comment or design that says so).
        case notSaved(String)
    }

    static func same(_ names: String...) -> [String: Verdict] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, Verdict.saved($0)) })
    }

    static let trackTable: [String: Verdict] = same(
        "id", "name", "kind", "volume", "pan", "isMuted", "isSoloed", "isArmed", "isAIGenerated", "clips",
        "instrument", "sends", "effects", "automation", "takeGroups", "modulationSources", "modulationRoutes",
        "voiceProvenance", "sungVocalProvenance").merging(["outputBusID": .saved("outputBusId")]) { a, _ in a }

    static let clipTable: [String: Verdict] = same(
        "id", "name", "startBeat", "lengthBeats", "notes", "isAIGenerated", "startOffsetSeconds", "gainDb",
        "fadeInBeats", "fadeOutBeats", "fadeInCurve", "fadeOutCurve", "stretchRatio", "pitchShiftSemitones",
        "formantPreserve", "gainEnvelope", "controllerLanes", "pitchEdits", "lyrics", "singStyle")
        .merging(["audioFileURL": .saved("media"), "takeGroupID": .saved("takeGroupId")]) { a, _ in a }

    static let transportTable: [String: Verdict] = same(
        "positionBeats", "tempoBPM", "timeSignature", "isLoopEnabled", "loopStartBeat", "loopEndBeat",
        "isPunchEnabled", "punchInBeat", "punchOutBeat", "isMetronomeEnabled", "countInBars")
        .merging([
            "tempoMapOverride": .saved("tempoMap"), "meterMapOverride": .saved("meterChanges"),
            "isPlaying": .notSaved("a saved project never reopens rolling: TransportDocument has no such field"),
            "isRecording": .notSaved("a saved project never reopens recording: TransportDocument has no such field"),
        ]) { a, _ in a }

    static let sendTable: [String: Verdict] = same("id", "level")
        .merging(["destinationBusID": .saved("busId")]) { a, _ in a }

    static let effectTable: [String: Verdict] = same(
        "id", "kind", "gain", "eq", "compressor", "limiter", "reverb", "delay", "saturator", "gate", "chorus",
        "bassEnhancer", "bitCrusher", "djFilter", "ringMod", "flanger", "hallReverb", "tapeDelay", "stereoWidth",
        "phaser", "transientShaper", "freqShifter", "clipper", "dynamicEQ", "audioUnit", "sidechainSourceTrackID")
        .merging(["isBypassed": .saved("bypassed")]) { a, _ in a }

    static let instrumentTable: [String: Verdict] = same(
        "kind", "polySynth", "sampler", "audioUnit", "soundBank", "drumKit")

    static let zoneTable: [String: Verdict] = same(
        "id", "rootPitch", "minPitch", "maxPitch", "gain", "minVelocity", "maxVelocity", "group", "seqLength",
        "seqPosition", "randMin", "randMax", "tuneCents", "pan", "ampVelTrack", "oneShot", "startFrame",
        "endFrame", "attack", "decay", "sustain", "release", "loopMode", "loopStart", "loopEnd", "crossfade",
        "reverse", "chokeGroup", "drumRole").merging(["audioFileURL": .saved("media")]) { a, _ in a }

    static let takeGroupTable: [String: Verdict] = same("id", "name", "lanes", "comp", "crossfadeSeconds")
    static let takeLaneTable: [String: Verdict] = same("id", "name", "clip")
    static let referenceTable: [String: Verdict] = same("id", "name", "offsetSeconds", "trimDb", "analysis")
        .merging(["sourcePath": .saved("media")]) { a, _ in a }

    // The modulation types persist through their OWN Codable — whose encoder is HAND-WRITTEN
    // (`ModulationSourceParams.encode`) or keyed by explicit CodingKeys (`ModulationRoute`), so a new stored
    // property compiles and is silently never written. That is why they are here although they have no mirror.
    static let sourceTable: [String: Verdict] = same("id", "kind", "name", "params")
    static let routeTable: [String: Verdict] = same("id", "target", "depth", "enabled")
        .merging(["sourceID": .saved("sourceId")]) { a, _ in a }
    static let lfoTable: [String: Verdict] = same(
        "waveform", "rateHz", "syncDivision", "phaseDeg", "pulseWidth", "edgeMs", "bipolar", "seed")
    static let stepTable: [String: Verdict] = same("steps", "stepDivision", "rateHz", "edgeMs")
    static let followerTable: [String: Verdict] = same(
        "source", "detector", "attackMs", "releaseMs", "floorDb", "gainDb")
    static let macroTable: [String: Verdict] = same("value")

    static let projectDocumentTable: [String: Verdict] = same(
        "schemaVersion", "savedAt", "name", "masterVolume", "transport", "tracks", "grooveTemplates", "markers",
        "tempoMap", "meterChanges", "tempoMapRevision", "masterEffects", "masterAutomation",
        "masterModulationSources", "masterModulationRoutes", "copilotChats", "reference", "panLaw")
        .merging([
            "copilotChatsDroppedOnLoad": .notSaved("a fact about the last DECODE (chats that could not be read); never coded"),
            "referenceDroppedOnLoad": .notSaved("a fact about the last DECODE (a reference that could not be read); never coded"),
            "panLawUnreadOnLoad": .notSaved("a fact about the last DECODE (a pan rule this build cannot read); never coded"),
        ]) { a, _ in a }

    /// One mirrored type: its classification, instances from the kitchen sink, a fresh default instance, and the
    /// keys its save format really has (the DTO's own `Mirror`, or the JSON keys of a type saved by itself).
    struct Mirrored {
        let type: String
        let table: [String: Verdict]
        let samples: [Any]
        let fresh: Any
        let fileKeys: Set<String>
        /// Saved properties no reachable project can move off their default, each with the reason.
        var defaultOnly: [String: String] = [:]
    }

    static func labels(_ value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap { $0.label })
    }

    /// The keys a type that saves itself (its own `Codable`) actually writes, unioned over every sample — an
    /// optional field is written only when set, so one sample is not enough.
    static func jsonKeys(_ values: [some Encodable]) throws -> Set<String> {
        var keys = Set<String>()
        for value in values {
            let parsed = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(value))
            let object = try #require(parsed as? [String: Any], "\(type(of: value)) did not encode as an object")
            keys.formUnion(object.keys)
        }
        return keys
    }

    static func value(_ label: String, of instance: Any) -> Any {
        Mirror(reflecting: instance).children.first { $0.label == label }?.value ?? "<no such property>"
    }

    static func mirroredTypes() throws -> [Mirrored] {
        let built = try everythingDocument()
        let tracks = built.tracks
        let zero = MODPFixture.id(0)
        let clips = tracks.flatMap { $0.clips } + tracks.flatMap { $0.takeGroups }.flatMap { $0.lanes }.map { $0.clip }
        let effects = tracks.flatMap { $0.effects }
        let instrument = try #require(tracks[2].instrument)
        let zone = try #require(instrument.sampler?.zones.first)
        let group = try #require(tracks[1].takeGroups.first)
        let sends = tracks.flatMap { $0.sends }
        let sources = tracks.flatMap { $0.modulationSources } + masterModulation().sources
        let routes = tracks.flatMap { $0.modulationRoutes } + masterModulation().routes
        let lfo: [LFOSourceParams] = sources.compactMap {
            guard case .lfo(let p) = $0.params else { return nil }; return p }
        let step: [StepSequencerSourceParams] = sources.compactMap {
            guard case .stepSequencer(let p) = $0.params else { return nil }; return p }
        let follower: [EnvelopeFollowerSourceParams] = sources.compactMap {
            guard case .envelopeFollower(let p) = $0.params else { return nil }; return p }
        let macro: [MacroSourceParams] = sources.compactMap {
            guard case .macro(let p) = $0.params else { return nil }; return p }
        return [
            Mirrored(type: "Track", table: trackTable, samples: tracks, fresh: Track(id: zero, name: ""),
                     fileKeys: labels(TrackDocument(from: tracks[1], mediaRefs: [:]))),
            Mirrored(type: "Clip", table: clipTable, samples: clips, fresh: Clip(id: zero, name: ""),
                     fileKeys: labels(ClipDocument(from: clips[0], media: nil))),
            Mirrored(type: "TransportState", table: transportTable, samples: [built.transport],
                     fresh: TransportState(),
                     fileKeys: labels(TransportDocument(from: built.transport)).union(labels(built.document))),
            Mirrored(type: "Send", table: sendTable, samples: sends, fresh: Send(id: zero, destinationBusID: zero),
                     fileKeys: labels(SendDocument(from: sends[0]))),
            Mirrored(type: "EffectDescriptor", table: effectTable, samples: effects,
                     fresh: EffectDescriptor(id: zero, kind: .gain), fileKeys: labels(EffectDocument(from: effects[0]))),
            Mirrored(type: "InstrumentDescriptor", table: instrumentTable, samples: [instrument],
                     fresh: InstrumentDescriptor(),
                     fileKeys: labels(InstrumentDocument(from: instrument, mediaRefs: [:]))),
            Mirrored(type: "SamplerZone", table: zoneTable, samples: [zone],
                     fresh: SamplerZone(id: zero, audioFileURL: URL(fileURLWithPath: "/")),
                     fileKeys: labels(SamplerZoneDocument(from: zone, media: nil))),
            Mirrored(type: "TakeGroup", table: takeGroupTable, samples: [group],
                     fresh: TakeGroup(id: zero, name: "", lanes: []),
                     fileKeys: labels(TakeGroupDocument(from: group, mediaRefs: [:]))),
            Mirrored(type: "TakeLane", table: takeLaneTable, samples: group.lanes,
                     fresh: TakeLane(id: zero, name: "", clip: Clip(id: zero, name: "")),
                     fileKeys: labels(TakeLaneDocument(from: group.lanes[0], media: nil))),
            Mirrored(type: "ReferenceSlot", table: referenceTable, samples: [MODPFixture.referenceSlot()],
                     fresh: ReferenceSlot(id: zero, name: "", sourcePath: ""),
                     fileKeys: labels(ReferenceDocument(from: MODPFixture.referenceSlot(), media: nil))),
            Mirrored(type: "ModulationSource", table: sourceTable, samples: sources,
                     fresh: ModulationSource(id: zero, kind: .lfo), fileKeys: try jsonKeys(sources)),
            Mirrored(type: "ModulationRoute", table: routeTable, samples: routes,
                     fresh: ModulationRoute(id: zero, sourceID: zero, target: .volume, depth: 0),
                     fileKeys: try jsonKeys(routes)),
            Mirrored(type: "LFOSourceParams", table: lfoTable, samples: lfo, fresh: LFOSourceParams(),
                     fileKeys: try jsonKeys(lfo.map { ModulationSourceParams.lfo($0) })),
            Mirrored(type: "StepSequencerSourceParams", table: stepTable, samples: step,
                     fresh: StepSequencerSourceParams(),
                     fileKeys: try jsonKeys(step.map { ModulationSourceParams.stepSequencer($0) })),
            Mirrored(type: "EnvelopeFollowerSourceParams", table: followerTable, samples: follower,
                     fresh: EnvelopeFollowerSourceParams(),
                     fileKeys: try jsonKeys(follower.map { ModulationSourceParams.envelopeFollower($0) })),
            Mirrored(type: "MacroSourceParams", table: macroTable, samples: macro, fresh: MacroSourceParams(),
                     fileKeys: try jsonKeys(macro.map { ModulationSourceParams.macro($0) })),
            Mirrored(type: "ProjectDocument", table: projectDocumentTable, samples: [built.document],
                     fresh: ProjectDocument(name: "", transport: TransportState(), tracks: [], masterVolume: 1,
                                            mediaRefs: [:]),
                     fileKeys: try jsonKeys([built.document]),
                     defaultOnly: ["schemaVersion": "the build's constant (ProjectBundle.currentSchemaVersion), not a setting"]),
        ]
    }

    /// ⭐ THE GATE THAT STOPS THE NEXT ONE. A stored property added to any of these types without a row here
    /// fails BY NAME. The remedy is never "add a row": thread the property through the save format and classify
    /// it `.saved(key)` (the round trip below then checks the claim), or classify it `.notSaved(reason)` with
    /// the comment or design that says it is session-only.
    @Test("G3: every stored property of every mirrored type is classified — an unclassified one fails BY NAME")
    func everyStoredPropertyIsClassified() throws {
        let rows = try Self.mirroredTypes()
        #expect(rows.count == 17)
        for row in rows {
            guard let sample = row.samples.first else {
                Issue.record("no \(row.type) in the fixture — G3 cannot classify what it cannot see")
                continue
            }
            let stored = Self.labels(sample)
            #expect(!stored.isEmpty, "control: Mirror saw no stored property on \(row.type)")
            let unclassified = stored.subtracting(row.table.keys).sorted()
            #expect(unclassified.isEmpty, """
                \(row.type) has stored properties nobody classified: \(unclassified). Either thread each one \
                through the save format and classify it .saved(key) in ProjectDocumentFidelityTests, or \
                classify it .notSaved(reason) with the comment or design that says it is session-only.
                """)
            let stale = Set(row.table.keys).subtracting(stored).sorted()
            #expect(stale.isEmpty, "\(row.type)'s table names properties the type no longer has: \(stale)")
            for (label, verdict) in row.table.sorted(by: { $0.key < $1.key }) {
                guard case .saved(let key) = verdict else { continue }
                #expect(row.fileKeys.contains(key), """
                    \(row.type).\(label) is classified as saved under '\(key)', but its save format has no such \
                    key: \(row.fileKeys.sorted()). It would be dropped on save.
                    """)
            }
        }
    }

    /// Non-vacuity: a round trip only proves a field is saved if the field is OFF its default going in.
    @Test("G3 non-vacuity: every saved property is off its default somewhere in the fixture")
    func everySavedPropertyIsExercised() throws {
        for row in try Self.mirroredTypes() {
            for (label, verdict) in row.table.sorted(by: { $0.key < $1.key }) {
                guard case .saved = verdict, row.defaultOnly[label] == nil else { continue }
                let fresh = Self.value(label, of: row.fresh)
                let moved = row.samples.contains { sample in
                    !MODPMirrorDiff.paths(fresh, Self.value(label, of: sample), at: label).isEmpty
                }
                #expect(moved, """
                    \(row.type).\(label) sits at its default in every fixture instance, so the round trip \
                    cannot tell whether it is saved. Give it a non-default value in the MODP fixture.
                    """)
            }
        }
    }

    @Test("G3: a project with EVERY saved setting changed reopens equal — track AND master modulation included")
    func everySavedSettingSurvivesTheBundle() throws {
        let built = try Self.everythingDocument()
        let (reopened, bundle, bytes) = try Self.reopen(built.document)
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(reopened == built.document, "the decoded document differs from the one written")
        let runtime = reopened.runtimeState(bundleURL: bundle)
        let master = reopened.runtimeMasterModulation
        var diffs = MODPMirrorDiff.paths(built.tracks, runtime.tracks, at: "tracks")
        diffs += MODPMirrorDiff.paths(built.transport, runtime.transport, at: "transport")
        diffs += MODPMirrorDiff.paths(Self.masterModulation().sources, master.sources, at: "masterModulationSources")
        diffs += MODPMirrorDiff.paths(Self.masterModulation().routes, master.routes, at: "masterModulationRoutes")
        diffs += MODPMirrorDiff.paths(MODPFixture.referenceSlot(), runtime.reference as Any, at: "reference")
        let expectedEffects = (built.document.masterEffects ?? []).compactMap { $0.effectDescriptor() }
        diffs += MODPMirrorDiff.paths(expectedEffects, runtime.masterEffects, at: "masterEffects")
        // The ONLY difference allowed is the one the format makes on purpose: a project never reopens rolling.
        #expect(diffs == ["transport.isPlaying", "transport.isRecording"], """
            these settings did not survive save → open: \(diffs.filter { !$0.hasPrefix("transport.is") })
            """)
        #expect(runtime.warnings.isEmpty, "\(runtime.warnings)")
        let kinds = Set(runtime.tracks.flatMap { $0.modulationSources }.map { $0.kind })
        #expect(kinds == Set(ModulationSourceKind.allCases), "every source kind on the tracks: \(kinds)")
        let masterKinds = Set(master.sources.map { $0.kind })
        #expect(masterKinds == Set(ModulationSourceKind.allCases), "every source kind on the master: \(masterKinds)")
        let disabled = runtime.tracks.flatMap { $0.modulationRoutes }.filter { !$0.enabled }.count
        #expect(disabled >= 2, "a DISABLED route must come back disabled: \(disabled)")
        #expect(String(decoding: bytes, as: UTF8.self).contains("\"masterModulationRoutes\""))
    }

    /// The master strip's arrays are clamped on load to the caps the render side preallocates, exactly as
    /// `Track.init` clamps a track's — a hand-edited file cannot smuggle in more.
    @Test("G3: master modulation over the caps is clamped on open, the Track.init rule")
    func masterModulationIsClampedOnOpen() throws {
        var document = ProjectDocument(name: "caps", transport: TransportState(), tracks: [], masterVolume: 1,
                                       mediaRefs: [:])
        let source = MODPFixture.modulationSources(base: 5_000)[3]
        document.masterModulationSources = (0..<(ModulationLimits.maxSources + 3)).map { n in
            ModulationSource(id: MODPFixture.id(6_000 + n), kind: .macro, name: "M\(n)", params: source.params)
        }
        document.masterModulationRoutes = (0..<(ModulationLimits.maxRoutes + 2)).map { n in
            ModulationRoute(id: MODPFixture.id(7_000 + n), sourceID: MODPFixture.id(6_000), target: .volume,
                            depth: -0.1)
        }
        let (reopened, bundle, _) = try Self.reopen(document)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let master = reopened.runtimeMasterModulation
        #expect(master.sources.count == ModulationLimits.maxSources)
        #expect(master.routes.count == ModulationLimits.maxRoutes)
        #expect(master.sources.first?.id == MODPFixture.id(6_000), "the clamp keeps the FIRST sources, in order")
    }

    /// The controls that keep G3 honest: the classification DOES report a property its table lacks, and the
    /// diff DOES name the one field that moved.
    @Test("G3 control: an unclassified property and a moved value ARE both reported, by name")
    func classificationAndDiffCanFail() throws {
        var table = Self.trackTable
        table.removeValue(forKey: "modulationRoutes")
        let stored = Self.labels(Track(name: "control"))
        // Relative to the real table, so this control tests the MECHANISM and stays green when the real
        // classification test is the one reporting a new, unclassified property.
        let baseline = stored.subtracting(Self.trackTable.keys)
        #expect(stored.subtracting(table.keys).subtracting(baseline).sorted() == ["modulationRoutes"])
        let original = MODPFixture.kitchenSinkTracks(modulated: true)
        var moved = original
        moved[2].modulationRoutes[0].depth = 0.9
        #expect(MODPMirrorDiff.paths(original, moved, at: "tracks") == ["tracks[2].modulationRoutes[0].depth"])
    }
}

// MARK: - The store's own state, classified

extension ProjectDocumentFidelityTests {
    /// Every stored property of `ProjectStore`, by its `Mirror` label (the @Observable macro keeps a tracked
    /// property's storage under an underscored name; an `@ObservationIgnored` one keeps its own). If the macro's
    /// naming ever changes, this reddens BY NAME too: the remedy is still "save it or say why not".
    static let storeTable: [String: Verdict] = [
        "_projectName": .saved("name"),
        "_tracks": .saved("tracks"),
        "_transport": .saved("transport"),
        "_masterVolume": .saved("masterVolume"),
        "_panLaw": .saved("panLaw"),
        "_masterEffects": .saved("masterEffects"),
        "_masterAutomation": .saved("masterAutomation"),
        "_masterModulationSources": .saved("masterModulationSources"),
        "_masterModulationRoutes": .saved("masterModulationRoutes"),
        "_grooveTemplates": .saved("grooveTemplates"),
        "_markers": .saved("markers"),
        "_reference": .saved("reference"),
        "_mapRevision": .saved("tempoMapRevision"),
        "_copilotChats": .saved("copilotChats"),
        "_masterMeter": .notSaved("a live meter reading"),
        "_lastNonSilentMasterMeter": .notSaved("a live meter reading"),
        "_trackMeters": .notSaved("live meter readings"),
        "_lastNonSilentTrackMeters": .notSaved("live meter readings"),
        "_referenceMonitor": .notSaved("the live A/B readout; the reference itself is saved as `reference`"),
        "_lastRecordingError": .notSaved("the last recording failure, shown once"),
        "_selectedInputDeviceUID": .notSaved("this Mac's audio input, not part of the song"),
        "_selectedOutputDeviceUID": .notSaved("this Mac's audio output, not part of the song"),
        "_projectPath": .notSaved("where the project lives: the bundle's own path"),
        "_isDirty": .notSaved("the unsaved-changes flag; a save clears it"),
        "_chatsDirty": .notSaved("the unsaved-chats flag; a save clears it"),
        "_journal": .notSaved("undo history belongs to the session"),
        "_lastEditEvent": .notSaved("the edit feed observers read"),
        "editEventSeq": .notSaved("the edit feed's counter"),
        "_renderCompletedCount": .notSaved("a counter observers read"),
        "autosaveTask": .notSaved("a background task handle"),
        "crashAutosaveTask": .notSaved("a background task handle"),
        "_playbackTask": .notSaved("a background task handle"),
        "recoverySlug": .notSaved("names this session's recovery folder"),
        "autosaveRecoveryDirectory": .notSaved("a folder on this Mac (a test seam)"),
        "crashRecovery": .notSaved("the crash-recovery manager: it WRITES the autosave, it is not in it"),
        "diagnostics": .notSaved("the diagnostics reporter"),
        "generationImportsDirectory": .notSaved("a folder on this Mac (a test seam)"),
        "referenceImportsDirectory": .notSaved("a folder on this Mac (a test seam)"),
        "voiceStoreDirectory": .notSaved("a folder on this Mac (a test seam)"),
        "soundBankLibrary": .notSaved("the banks installed on this Mac; each track saves the bank it uses"),
        "_recoveryOfferAvailable": .notSaved("whether a crash-recovery offer is waiting"),
        "_engine": .notSaved("the audio engine"),
        "_media": .notSaved("the media importer"),
        "_generationSource": .notSaved("the AI generation client"),
        "_instrumentStateProvider": .notSaved("reads plug-in state AT save time; the state is saved in the track"),
        "_effectStateProvider": .notSaved("reads plug-in state AT save time; the state is saved in the effect"),
        "copilotActiveChatProvider": .notSaved("a hook into the chat panel"),
        "copilotProjectBoundaryHandler": .notSaved("a hook into the chat panel"),
        "_engineNotices": .notSaved("engine messages for this session"),
        "_engineNoticeSequence": .notSaved("engine messages for this session"),
        "_pendingClipFixes": .notSaved("in-flight AI clip fixes: in-memory only, see its declaration"),
        "_chatRevision": .notSaved("a counter observers read"),
        "_projectGeneration": .notSaved("counts project replacements in this session"),
        "pendingTake": .notSaved("a recording in progress"),
        "_liveTakeRegion": .notSaved("a recording in progress: deliberately not part of the project, see its declaration"),
        "recordingSessionGeneration": .notSaved("a recording in progress"),
        "takeCounter": .notSaved("numbers this session's takes"),
        "cachedSessionRecordingDir": .notSaved("a folder on this Mac"),
        "_loopDeck": .notSaved("a live-looping session: deliberately not part of the project, see its declaration"),
        "_stopAtContentEnd": .notSaved("a session preference, deliberately never written, see its declaration"),
        "_armedEndStop": .notSaved("the stop armed for this playback"),
        "_voiceRecorderOpenReason": .notSaved("the app's voice recorder card is open: live UI state the store never saves or clears, see its declaration (p2-sing-f2)"),
        "_insertAnalysisOwners": .notSaved("which live analysers are open"),
        "audition": .notSaved("live preview playback"),
        "livePlay": .notSaved("live keyboard playing"),
        "clipNoteAudition": .notSaved("live preview playback"),
        "padPreview": .notSaved("live preview playback"),
        "midiControl": .notSaved("MIDI controller mapping is this Mac's setup, not the song (MIDIControlMap.swift)"),
        "lastAutoExtendOutcome": .notSaved("the last clip auto-extend result, for the reply"),
        "_$observationRegistrar": .notSaved("Observation machinery"),
    ]

    /// Projects saved before this fix have no modulation keys at all; they must open with none, not fail.
    @Test("G2: a file written by the pre-fix encoder opens with no modulation and no warnings")
    func preFixFileOpensWithoutModulation() throws {
        let golden = try #require(
            Bundle.module.url(forResource: "kitchen-sink", withExtension: "json",
                              subdirectory: "Fixtures/ProjectDocumentFidelity"))
        let bundle = Self.tempBundle("prefix")
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(contentsOf: golden).write(to: bundle.appendingPathComponent("project.json"))
        let document = try ProjectBundle.read(from: bundle)
        #expect(document.tracks.count == 3, "control: the golden really is the kitchen sink")
        #expect(document.masterModulationSources == nil)
        #expect(document.masterModulationRoutes == nil)
        let master = document.runtimeMasterModulation
        #expect(master.sources.isEmpty && master.routes.isEmpty)
        let runtime = document.runtimeState(bundleURL: bundle)
        #expect(runtime.tracks.allSatisfy { $0.modulationSources.isEmpty && $0.modulationRoutes.isEmpty })
    }
}

// MARK: - G1: the store's REAL save, open, crash recovery, New and undo
//
// In `PersistenceTests` — an EXISTING @MainActor suite — because these drive the @MainActor store; a new
// @MainActor suite is over the cadence budget. Every name starts `modpFidelity`, so
// `--filter 'PersistenceTests/modpFidelity'` selects exactly these.

/// Records what the store hands the audio engine for the master strip's modulation.
@MainActor
final class MODPEngineSpy: AudioEngineControlling {
    var masterModulationPushes: [ProjectStore.ModulationStripState] = []
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?

    func masterModulationChanged(sources: [ModulationSource], routes: [ModulationRoute]) {
        masterModulationPushes.append(.init(sources: sources, routes: routes))
    }

    func prepare() throws {}
    func shutdown() {}
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double, to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
    var recordPermission: RecordPermission = .granted
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) { completion(true) }
    func setInputDevice(uid: String?) throws {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
}

@MainActor
enum MODPStore {
    static func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("modp-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store whose every folder seam points inside `dir`: nothing reaches a real folder on this Mac.
    static func make(in dir: URL, tracks: [Track] = []) -> ProjectStore {
        let store = ProjectStore(tracks: tracks)
        store.media = FakeMedia()
        store.crashRecovery.directory = dir.appendingPathComponent("crash", isDirectory: true)
        store.crashRecovery.clock = { Date(timeIntervalSince1970: 1_000) }
        store.autosaveRecoveryDirectory = dir.appendingPathComponent("recovery", isDirectory: true)
        store.voiceStoreDirectory = dir.appendingPathComponent("voices", isDirectory: true)
        store.generationImportsDirectory = dir.appendingPathComponent("generations", isDirectory: true)
        store.referenceImportsDirectory = dir.appendingPathComponent("references", isDirectory: true)
        return store
    }

    /// The kitchen sink's three tracks — every track setting changed, modulation on all three, every source
    /// kind, a disabled route — minus the audio files (a store save copies media; these tests are about the
    /// settings).
    static func tracks() -> [Track] {
        var tracks = MODPFixture.kitchenSinkTracks(modulated: true)
        tracks[1].clips = []
        tracks[1].takeGroups = []
        tracks[2].instrument?.sampler?.zones = []
        return tracks
    }

    /// Master modulation: every source kind and a disabled route, all aimed at the strip's own volume and pan.
    static func master() -> ProjectStore.ModulationStripState {
        .init(sources: MODPFixture.modulationSources(base: 4_000), routes: MODPFixture.modulationRoutes(base: 4_000))
    }

    /// Stale master modulation a previous project left behind — what F1 must not let survive.
    static func leftover() -> [ModulationSource] {
        [MODPFixture.modulationSources(base: 8_000)[3]]
    }

    static func state(_ store: ProjectStore) -> ProjectStore.ModulationStripState {
        .init(sources: store.masterModulationSources, routes: store.masterModulationRoutes)
    }
}

extension PersistenceTests {
    @Test("G1: modulation on tracks AND the master strip survives the store's real save → open")
    func modpFidelityG1SaveOpenKeepsModulation() throws {
        let dir = MODPStore.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracks = MODPStore.tracks()
        let master = MODPStore.master()
        let saver = MODPStore.make(in: dir, tracks: tracks)
        saver.masterModulationSources = master.sources
        saver.masterModulationRoutes = master.routes
        let path = dir.appendingPathComponent("Modulated.dawproj").path
        _ = try saver.saveProject(to: path)

        let opener = MODPStore.make(in: dir)
        let spy = MODPEngineSpy()
        opener.engine = spy
        let warnings = try opener.openProject(at: path, discardChanges: true)
        #expect(warnings.isEmpty, "\(warnings)")
        #expect(opener.tracks.count == tracks.count)
        for (saved, opened) in zip(tracks, opener.tracks) {
            #expect(opened.modulationSources == saved.modulationSources, "track '\(saved.name)' lost its sources")
            #expect(opened.modulationRoutes == saved.modulationRoutes, "track '\(saved.name)' lost its routes")
        }
        #expect(MODPMirrorDiff.paths(tracks, opener.tracks, at: "tracks") == [])
        #expect(MODPStore.state(opener) == master, "the master strip's modulation did not survive save → open")
        #expect(spy.masterModulationPushes.last == master, "the engine must hear the opened master modulation")
        // Non-vacuity: every source kind on the tracks and on the master, and disabled routes on both.
        #expect(Set(opener.tracks.flatMap { $0.modulationSources }.map { $0.kind })
                == Set(ModulationSourceKind.allCases))
        #expect(Set(opener.masterModulationSources.map { $0.kind }) == Set(ModulationSourceKind.allCases))
        #expect(opener.tracks.flatMap { $0.modulationRoutes }.contains { !$0.enabled })
        #expect(opener.masterModulationRoutes.contains { !$0.enabled })
    }

    @Test("G1/F4: crash recovery brings back track AND master modulation — the autosave carries both")
    func modpFidelityG1CrashRecoveryKeepsModulation() async throws {
        let dir = MODPStore.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracks = MODPStore.tracks()
        let master = MODPStore.master()
        let crashed = MODPStore.make(in: dir, tracks: tracks)
        crashed.masterModulationSources = master.sources
        crashed.masterModulationRoutes = master.routes
        _ = crashed.beginCrashDetection()
        crashed.addTrack(name: "Added before the crash")  // an unsaved edit, so the autosave writes
        await crashed.autosaveTick()

        let relaunched = MODPStore.make(in: dir)
        relaunched.masterModulationSources = MODPStore.leftover()
        let spy = MODPEngineSpy()
        relaunched.engine = spy
        #expect(relaunched.beginCrashDetection(), "control: the first session's lock must read as a crash")
        let outcome = try relaunched.recoverFromAutosave(accept: true)
        #expect(outcome == .recovered(warnings: []))
        let recovered = relaunched.tracks.filter { $0.name != "Added before the crash" }
        #expect(relaunched.tracks.count == tracks.count + 1, "control: the unsaved edit came back too")
        #expect(MODPMirrorDiff.paths(tracks, recovered, at: "tracks") == [])
        #expect(MODPStore.state(relaunched) == master, "crash recovery lost the master strip's modulation")
        #expect(spy.masterModulationPushes.last == master, "the engine must hear the recovered master modulation")
    }

    @Test("F1: New Project clears the master strip's modulation, and tells the engine")
    func modpFidelityF1NewClearsMasterModulation() throws {
        let dir = MODPStore.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MODPStore.make(in: dir)
        let spy = MODPEngineSpy()
        store.engine = spy
        store.masterModulationSources = MODPStore.master().sources
        store.masterModulationRoutes = MODPStore.master().routes
        try store.newProject(discardChanges: true)
        #expect(MODPStore.state(store) == .init(sources: [], routes: []),
                "the last project's master modulation leaked into the new one")
        #expect(spy.masterModulationPushes.last == .init(sources: [], routes: []))
    }

    @Test("F1: opening a project replaces the master strip's modulation — with the file's, or with none")
    func modpFidelityF1OpenReplacesMasterModulation() throws {
        let dir = MODPStore.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let master = MODPStore.master()
        let modulated = MODPStore.make(in: dir)
        modulated.masterModulationSources = master.sources
        modulated.masterModulationRoutes = master.routes
        let modulatedPath = dir.appendingPathComponent("With.dawproj").path
        _ = try modulated.saveProject(to: modulatedPath)
        let plain = MODPStore.make(in: dir)
        plain.addTrack(name: "Plain")
        let plainPath = dir.appendingPathComponent("Without.dawproj").path
        _ = try plain.saveProject(to: plainPath)

        let store = MODPStore.make(in: dir)
        let spy = MODPEngineSpy()
        store.engine = spy
        store.masterModulationSources = MODPStore.leftover()
        _ = try store.openProject(at: modulatedPath, discardChanges: true)
        #expect(MODPStore.state(store) == master)
        #expect(spy.masterModulationPushes.last == master)
        _ = try store.openProject(at: plainPath, discardChanges: true)
        #expect(store.tracks.map { $0.name } == ["Plain"], "control: the second open really happened")
        #expect(MODPStore.state(store) == .init(sources: [], routes: []),
                "the previous project's master modulation leaked into a project that has none")
        #expect(spy.masterModulationPushes.last == .init(sources: [], routes: []))
    }

    @Test("F2: a master-strip modulation edit can be undone and redone, and the engine hears both")
    func modpFidelityF2MasterModulationEditsAreUndoable() throws {
        let dir = MODPStore.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MODPStore.make(in: dir)
        let spy = MODPEngineSpy()
        store.engine = spy
        #expect(!store.canUndo, "control: a fresh store has nothing to undo")
        let added = try store.addModulationSource(on: .master, kind: .lfo).source
        #expect(store.canUndo, "adding a master modulation source made no undo step")
        _ = try store.undo()
        #expect(MODPStore.state(store) == .init(sources: [], routes: []))
        #expect(spy.masterModulationPushes.last == .init(sources: [], routes: []))
        _ = try store.redo()
        #expect(MODPStore.state(store) == .init(sources: [added], routes: []))
        #expect(spy.masterModulationPushes.last == .init(sources: [added], routes: []))
    }

    /// ⭐ The store's half of G3. A new stored property on `ProjectStore` fails here BY NAME until it is saved
    /// (`.saved(key)`, and the key must be a real `ProjectDocument` field) or classified `.notSaved(reason)`.
    @Test("G3: every stored property of the store is classified — an unclassified one fails BY NAME")
    func modpFidelityStoreStateIsClassified() throws {
        let stored = ProjectDocumentFidelityTests.labels(ProjectStore())
        #expect(stored.count > 50, "control: Mirror saw only \(stored.count) stored properties on the store")
        let table = ProjectDocumentFidelityTests.storeTable
        let unclassified = stored.subtracting(table.keys).sorted()
        #expect(unclassified.isEmpty, """
            ProjectStore has stored properties nobody classified: \(unclassified). Either save each one (thread \
            it through ProjectDocument and the save, open, autosave and recovery paths, then classify it \
            .saved(key)), or classify it .notSaved(reason) in ProjectDocumentFidelityTests.storeTable.
            """)
        let stale = Set(table.keys).subtracting(stored).sorted()
        #expect(stale.isEmpty, "storeTable names properties the store no longer has: \(stale)")
        let documentKeys = ProjectDocumentFidelityTests.labels(
            ProjectDocument(name: "", transport: TransportState(), tracks: [], masterVolume: 1, mediaRefs: [:]))
        for (label, verdict) in table.sorted(by: { $0.key < $1.key }) {
            guard case .saved(let key) = verdict else { continue }
            #expect(documentKeys.contains(key), "store \(label) is classified as saved under '\(key)', which ProjectDocument does not have")
        }
    }
}

// BEGIN MODP FIXTURE — W7-MODP, 2026-10-04. Compiled VERBATIM into the pre-change census + golden capture
// ($S/w7/MODP/cap, against the UNMODIFIED e6f7a27 DAWCore) and into
// Tests/DAWCoreTests/ProjectDocumentFidelityTests.swift. The G2 goldens in
// Tests/DAWCoreTests/Fixtures/ProjectDocumentFidelity/ were encoded FROM THIS CODE: editing one copy alone
// turns G2 red for a reason that has nothing to do with the encoder.
//
// Only API that existed BEFORE the modulation-persistence fix is used here, so the same text compiles on both
// sides of it. Master-strip modulation (which the old ProjectDocument could not carry at all) is therefore built
// in the tests, outside this region.
enum MODPFixture {

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    /// A WHOLE second: the bundle encoder writes iso8601 at second precision.
    static let savedAt = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: Modulation — one source of EVERY kind, every param off its default and inside its clamp
    // (the follower's `source` is not "self": the edit verbs refuse that today, m39-e-D4, but the file must
    // still carry whatever the model holds, and a default value would let a dropped field pass unseen)

    static func modulationSources(base: Int) -> [ModulationSource] {
        [ModulationSource(id: id(base + 1), kind: .lfo, name: "Wobble",
                          params: .lfo(LFOSourceParams(waveform: .square, rateHz: 6.5, syncDivision: "1/8",
                                                       phaseDeg: 45, pulseWidth: 0.3, edgeMs: 7,
                                                       bipolar: false, seed: 9_001))),
         ModulationSource(id: id(base + 2), kind: .stepSequencer, name: "Gate",
                          params: .stepSequencer(StepSequencerSourceParams(
                            steps: [0, 1, 0.5, -0.25, 1], stepDivision: "1/16", rateHz: 8, edgeMs: 3.5))),
         ModulationSource(id: id(base + 3), kind: .envelopeFollower, name: "Duck",
                          params: .envelopeFollower(EnvelopeFollowerSourceParams(
                            source: "modp-key", detector: .peak, attackMs: 4.5, releaseMs: 250, floorDb: -48,
                            gainDb: 6))),
         ModulationSource(id: id(base + 4), kind: .macro, name: "Brightness",
                          params: .macro(MacroSourceParams(value: 0.62)))]
    }

    /// Routes from those sources: depth signs both ways, one route DISABLED, and the targets a strip can carry.
    static func modulationRoutes(base: Int, extra: [AutomationTarget] = []) -> [ModulationRoute] {
        var routes = [
            ModulationRoute(id: id(base + 11), sourceID: id(base + 1), target: .volume, depth: -0.125),
            ModulationRoute(id: id(base + 12), sourceID: id(base + 2), target: .pan, depth: 0.75,
                            enabled: false),
            ModulationRoute(id: id(base + 13), sourceID: id(base + 4), target: .volume, depth: -0.5),
            ModulationRoute(id: id(base + 14), sourceID: id(base + 3), target: .pan, depth: -0.3),
        ]
        for (offset, target) in extra.enumerated() {
            routes.append(ModulationRoute(id: id(base + 15 + offset), sourceID: id(base + 1 + offset % 4),
                                          target: target, depth: 0.4 - Double(offset) * 0.1))
        }
        return routes
    }

    // MARK: The kitchen sink — every stored property of every mirrored type off its default

    static let mediaNames: [Int: String] = [21: "vox", 23: "take1", 32: "take1", 34: "take2", 71: "zone",
                                            94: "ref"]

    /// `absolute` = the recovery-bundle shape (an absolute path, which `resolveMedia` accepts VERBATIM, so a
    /// clip's URL round-trips exactly); otherwise the titled-save shape `media/<name>.wav`.
    static func mediaRefs(absolute: Bool) -> [UUID: String?] {
        var refs: [UUID: String?] = [:]
        for (n, name) in mediaNames {
            refs[id(n)] = absolute ? "/tmp/modp-census/\(name).wav" : "media/\(name).wav"
        }
        return refs
    }

    static func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/modp-census/\(name).wav") }

    static func eq() -> EQParams {
        var eq = EQParams(lowShelfFreq: 137, lowShelfGainDb: -4.5, peak1Freq: 1_234, peak1GainDb: 6.25,
                          peak1Q: 2.4, peak2Freq: 4_100, peak2GainDb: -3.75, peak2Q: 0.55,
                          highShelfFreq: 7_800, highShelfGainDb: 3.5)
        eq.highPassFreq = 62
        eq.lowShelfEnabled = false
        return eq
    }

    static func busTrack(modulated: Bool) -> Track {
        Track(id: id(1), name: "Echo Bus", kind: .bus, volume: 0.7, pan: -0.3, isMuted: true, isSoloed: true,
              isArmed: true, isAIGenerated: true,
              effects: [EffectDescriptor(id: id(50), kind: .reverb, isBypassed: true,
                                         reverb: ReverbParams(roomSize: 0.73, damping: 0.41, mix: 0.37,
                                                              preDelayMs: 23, width: 0.85))],
              automation: [AutomationLane(id: id(60), target: .volume,
                                          points: [AutomationPoint(beat: 0, value: 0.5),
                                                   AutomationPoint(beat: 8, value: 0.9, curve: .hold)],
                                          isEnabled: false)],
              modulationSources: modulated ? [modulationSources(base: 1_000)[3]] : [],
              modulationRoutes: modulated ? [modulationRoutes(base: 1_000)[2]] : [])
    }

    static func audioTrack(modulated: Bool) -> Track {
        let vox = Clip(id: id(21), name: "Vox", startBeat: 2, lengthBeats: 8, audioFileURL: url("vox"),
                       isAIGenerated: true, startOffsetSeconds: 0.25, gainDb: -3.5, fadeInBeats: 0.5,
                       fadeOutBeats: 0.75, fadeInCurve: .equalPower, fadeOutCurve: .equalPower,
                       stretchRatio: 1.25, pitchShiftSemitones: -2, formantPreserve: true,
                       gainEnvelope: [ClipGainPoint(beat: 1, gainDb: -6), ClipGainPoint(beat: 3, gainDb: 2)],
                       pitchEdits: PitchEditSet(
                        segments: [NoteSegment(id: id(22), startSeconds: 0.5, endSeconds: 1.0, detectedHz: 220,
                                               detectedConfidence: 0.9, pitchOffsetCents: 35)],
                        retuneMs: 80, keepsConsonantsUntuned: true))
        let member = Clip(id: id(23), name: "Vox comp", startBeat: 12, lengthBeats: 4, audioFileURL: url("take1"),
                          takeGroupID: id(30))
        let lanes = [
            TakeLane(id: id(31), name: "Take 1",
                     clip: Clip(id: id(32), name: "Take 1", startBeat: 12, lengthBeats: 4,
                                audioFileURL: url("take1"), gainDb: 1.5)),
            TakeLane(id: id(33), name: "Take 2",
                     clip: Clip(id: id(34), name: "Take 2", startBeat: 12, lengthBeats: 4,
                                audioFileURL: url("take2"),
                                gainEnvelope: [ClipGainPoint(beat: 2, gainDb: -9)])),
        ]
        let group = TakeGroup(id: id(30), name: "Vox takes", lanes: lanes,
                              comp: [CompSegment(laneID: id(31), startBeat: 12, endBeat: 14),
                                     CompSegment(laneID: id(33), startBeat: 14, endBeat: 16)],
                              crossfadeSeconds: 0.02)
        let compressor = EffectDescriptor(
            id: id(51), kind: .compressor,
            compressor: CompressorParams(thresholdDb: -21.5, ratio: 5.5, attackMs: 7.25, releaseMs: 155,
                                         kneeDb: 4.5, makeupDb: 3.25, mix: 0.65, detectorMode: 1,
                                         detectorFreqHz: 7_250, detectorQ: 3.25),
            sidechainSourceTrackID: id(3))
        return Track(
            id: id(2), name: "Vox", kind: .audio, volume: 1.3, pan: 0.25, isMuted: true, isSoloed: true,
            isArmed: true, isAIGenerated: true, clips: [vox, member], outputBusID: id(1),
            sends: [Send(id: id(201), destinationBusID: id(1), level: 0.6)],
            effects: [compressor, EffectDescriptor(id: id(52), kind: .eq, isBypassed: true, eq: eq())],
            automation: [
                AutomationLane(id: id(61), target: .pan,
                               points: [AutomationPoint(beat: 0, value: -0.5),
                                        AutomationPoint(beat: 4, value: 0.5)]),
                AutomationLane(id: id(62), target: .effectParam(effectID: id(51), paramName: "thresholdDb"),
                               points: [AutomationPoint(beat: 1, value: -30)]),
                AutomationLane(id: id(63), target: .sendLevel(sendID: id(201)),
                               points: [AutomationPoint(beat: 2, value: 0.4, curve: .hold)]),
            ],
            takeGroups: [group],
            voiceProvenance: VoiceProvenance(voiceId: "modp-voice", voiceName: "Test Voice", pitchSemitones: 3,
                                             convertedAt: savedAt),
            modulationSources: modulated ? modulationSources(base: 2_000) : [],
            modulationRoutes: modulated
                ? modulationRoutes(base: 2_000,
                                   extra: [.effectParam(effectID: id(51), paramName: "thresholdDb")])
                : [])
    }

    static func instrumentTrack(modulated: Bool) -> Track {
        let melody = Clip(id: id(41), name: "Melody", startBeat: 4, lengthBeats: 4,
                          notes: [MIDINote(id: id(401), pitch: 60, velocity: 90, startBeat: 0, lengthBeats: 1),
                                  MIDINote(id: id(402), pitch: 64, velocity: 70, startBeat: 1, lengthBeats: 0.5)],
                          isAIGenerated: true, gainDb: 1.5, fadeInBeats: 0.25,
                          gainEnvelope: [ClipGainPoint(beat: 0.5, gainDb: -2)],
                          controllerLanes: [
                            MIDIControllerLane(type: .cc(controller: 1),
                                               points: [MIDIControllerPoint(beat: 0, value: 10),
                                                        MIDIControllerPoint(beat: 2, value: 100)]),
                            MIDIControllerLane(type: .pitchBend, points: [MIDIControllerPoint(beat: 1, value: 9_000)]),
                          ],
                          lyrics: ClipLyrics(text: "hel-lo world"))
        let zone = SamplerZone(
            id: id(71), audioFileURL: url("zone"), rootPitch: 62, minPitch: 40, maxPitch: 80, gain: 1.2,
            minVelocity: 10, maxVelocity: 100, group: 2, seqLength: 3, seqPosition: 2, randMin: 0.1, randMax: 0.8,
            tuneCents: 15, pan: -0.4, ampVelTrack: 0.6, oneShot: true, startFrame: 100, endFrame: 50_000,
            attack: 0.01, decay: 0.5, sustain: 0.6, release: 0.3, loopMode: .continuous, loopStart: 1_000,
            loopEnd: 40_000, crossfade: SamplerCrossfade(controller: 1, ccInLo: 0, ccInHi: 64),
            reverse: true, chokeGroup: 5)
        let sampler = SamplerParams(
            zones: [zone], oneShot: true, attack: 0.031, release: 0.61, gain: 0.53, sourcePath: "/tmp/none.sfz",
            displayName: "Test Patch", expressionModDepth: 0.42, expressionFilterDepth: 0.37,
            expressionFilterCC: 2, bendRangeSemitones: 6, voiceMode: .legato, decay: 1.7, sustain: 0.23,
            pedalHoldLimit: 5, glideTime: 0.35, glideMode: .constantRate)
        let synth = PolySynthParams(waveform: .square, attack: 0.02, decay: 0.2, sustain: 0.5, release: 0.4,
                                    cutoffHz: 3_000, resonance: 0.3, gain: 0.6, pedalHoldLimit: 4,
                                    unisonVoices: 3, unisonDetuneCents: 12, subLevel: 0.3,
                                    subWaveform: .square, noiseLevel: 0.1, drift: 0.2, drive: 0.25)
        let instrument = InstrumentDescriptor(
            kind: .sampler, polySynth: synth, sampler: sampler,
            audioUnit: AudioUnitConfig(component: AudioUnitComponentID(type: "aumu", subType: "dls ",
                                                                       manufacturer: "appl"),
                                       name: "DLSMusicDevice", manufacturerName: "Apple",
                                       stateData: Data([1, 2, 3, 4])),
            soundBank: SoundBankConfig(source: .file(path: "/tmp/modp.sf2"), program: 5, bankMSB: 120,
                                       bankLSB: 3, displayName: "Bank"),
            drumKit: DrumKitParams(gain: 0.8, velocityToTone: 0.7, accentThreshold: 90, accentDepth: 0.5))
        return Track(
            id: id(3), name: "Keys", kind: .instrument, volume: 0.9, pan: -0.6, isMuted: true, isSoloed: true,
            isArmed: true, isAIGenerated: true, clips: [melody], instrument: instrument,
            automation: [AutomationLane(id: id(64), target: .instrumentParam(paramName: "cutoffHz"),
                                        points: [AutomationPoint(beat: 0, value: 2_000)])],
            sungVocalProvenance: SungVocalProvenance(
                engineId: "ace-step", engineCommit: "abc123", weightsRevision: "r1", facadeVersion: 2,
                voiceId: "v", voiceName: "Singer", voiceKind: "preset", lyricsText: "hel-lo",
                sourceClipId: id(41), octaveShift: -1, songTransposeSemitones: 2, seed: 42, nSteps: 30,
                cfg: 3.5, renderedAt: savedAt),
            modulationSources: modulated ? Array(modulationSources(base: 3_000).prefix(2)) : [],
            modulationRoutes: modulated
                ? [ModulationRoute(id: id(3_011), sourceID: id(3_001),
                                   target: .instrumentParam(paramName: "cutoffHz"), depth: 0.35),
                   ModulationRoute(id: id(3_012), sourceID: id(3_002), target: .volume, depth: -0.2,
                                   enabled: false)]
                : [])
    }

    static func kitchenSinkTracks(modulated: Bool) -> [Track] {
        [busTrack(modulated: modulated), audioTrack(modulated: modulated), instrumentTrack(modulated: modulated)]
    }

    /// Every transport field off its default — INCLUDING the two runtime-only flags, so the census can see the
    /// document drop them (by design: `TransportDocument` has no such fields).
    static func kitchenSinkTransport() throws -> TransportState {
        var t = TransportState(isPlaying: true, isRecording: true, positionBeats: 7.5, tempoBPM: 97,
                               timeSignature: TimeSignature(beatsPerBar: 7, beatUnit: 8), isLoopEnabled: true,
                               loopStartBeat: 4, loopEndBeat: 12, isPunchEnabled: true, punchInBeat: 2,
                               punchOutBeat: 6, isMetronomeEnabled: true, countInBars: 2)
        t.tempoMapOverride = try TempoMap(segments: [.init(startBeat: 0, bpm: 97), .init(startBeat: 16, bpm: 120)])
        t.meterMapOverride = try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 7, beatUnit: 8),
                                                    .init(startBeat: 14, beatsPerBar: 4, beatUnit: 4)])
        return t
    }

    static func referenceSlot() -> ReferenceSlot {
        ReferenceSlot(id: id(94), name: "Ref", sourcePath: "/tmp/modp-census/ref.wav", offsetSeconds: 0.5,
                      trimDb: -2,
                      analysis: ReferenceAnalysis(integratedLufs: -9, maxMomentaryLufs: -6, maxShortTermLufs: -7,
                                                  truePeakDbtp: -0.8, loudnessRangeLu: 5,
                                                  bandsDb: (0..<24).map { -30 + Double($0) }, correlation: 0.7,
                                                  width: 0.4, balance: 0.05, durationSeconds: 180,
                                                  sampleRateHz: 48_000, analyzerVersion: 1))
    }

    /// The kitchen-sink DOCUMENT, built through the save path's own init. `modulated: false` is the
    /// modulation-free twin the widest G2 golden is encoded from.
    static func kitchenSinkDocument(modulated: Bool, absoluteMedia: Bool) throws -> ProjectDocument {
        var document = ProjectDocument(
            name: "MODP kitchen sink", transport: try kitchenSinkTransport(),
            tracks: kitchenSinkTracks(modulated: modulated), masterVolume: 1.4,
            mediaRefs: mediaRefs(absolute: absoluteMedia),
            grooveTemplates: [GrooveTemplate(id: id(80), name: "Swing 58", gridBeats: 0.5, cycleBeats: 1,
                                             offsets: [0, 0.08])],
            markers: [Marker(id: id(81), name: "Verse", beat: 8), Marker(id: id(82), name: "Chorus", beat: 24)],
            tempoMapRevision: 5,
            masterEffects: [EffectDescriptor(id: id(90), kind: .limiter,
                                             limiter: LimiterParams(ceilingDb: -1.7, releaseMs: 88, truePeak: true)),
                            EffectDescriptor(id: id(91), kind: .eq, isBypassed: true, eq: eq())],
            masterAutomation: [AutomationLane(id: id(92), target: .volume,
                                              points: [AutomationPoint(beat: 0, value: 0.8),
                                                       AutomationPoint(beat: 16, value: 1.1)])],
            copilotChats: [CopilotChatDocument(id: id(93), title: "Mix help", createdAt: savedAt,
                                               updatedAt: savedAt.addingTimeInterval(60), model: "claude",
                                               droppedEntries: 2)],
            reference: referenceSlot())
        document.savedAt = savedAt
        return document
    }

    // MARK: G2 golden fixtures — MODULATION-FREE, encoded through ProjectBundle.write before the fix

    static func goldenDocuments() throws -> [(name: String, document: ProjectDocument)] {
        var empty = ProjectDocument(name: "Empty", transport: TransportState(), tracks: [], masterVolume: 1,
                                    mediaRefs: [:])
        empty.savedAt = savedAt
        let plainAudio = Track(id: id(501), name: "Guitar", kind: .audio,
                               clips: [Clip(id: id(511), name: "Riff", startBeat: 0, lengthBeats: 8,
                                            audioFileURL: url("riff"))])
        let plainSynth = Track(id: id(502), name: "Pad", kind: .instrument,
                               clips: [Clip(id: id(512), name: "Chords", startBeat: 0, lengthBeats: 4,
                                            notes: [MIDINote(id: id(521), pitch: 48, startBeat: 0, lengthBeats: 4)])],
                               instrument: InstrumentDescriptor(kind: .polySynth))
        var simple = ProjectDocument(name: "Simple", transport: TransportState(), tracks: [plainAudio, plainSynth],
                                     masterVolume: 0.9, mediaRefs: [id(511): "media/riff.wav"])
        simple.savedAt = savedAt
        let mixed = try kitchenSinkDocument(modulated: false, absoluteMedia: false)
        let busOnly = Track(id: id(601), name: "Verb", kind: .bus,
                            effects: [EffectDescriptor(id: id(602), kind: .reverb)])
        let sender = Track(id: id(603), name: "Snare", kind: .audio, outputBusID: id(601),
                           sends: [Send(id: id(604), destinationBusID: id(601), level: 0.5)])
        var routed = ProjectDocument(name: "Routed", transport: TransportState(), tracks: [busOnly, sender],
                                     masterVolume: 1, mediaRefs: [:],
                                     markers: [Marker(id: id(605), name: "Intro", beat: 0)])
        routed.savedAt = savedAt
        return [("empty", empty), ("simple", simple), ("routed", routed), ("kitchen-sink", mixed)]
    }
}

/// A recursive `Mirror` diff: every property PATH at which two values differ. Equality is asked of the value
/// itself first (any `Equatable`); only an unequal or non-Equatable value is opened up, so the report names
/// the deepest field that moved rather than the whole struct.
enum MODPMirrorDiff {
    static func paths(_ a: Any, _ b: Any, at path: String) -> [String] {
        var out: [String] = []
        walk(a, b, path, &out)
        return out
    }

    private static func equal(_ a: Any, _ b: Any) -> Bool? {
        guard let lhs = a as? any Equatable else { return nil }
        func open<T: Equatable>(_ x: T) -> Bool { (b as? T) == x }
        return open(lhs)
    }

    private static func walk(_ a: Any, _ b: Any, _ path: String, _ out: inout [String]) {
        let verdict = equal(a, b)
        if verdict == true { return }
        let ma = Mirror(reflecting: a), mb = Mirror(reflecting: b)
        let ca = Array(ma.children), cb = Array(mb.children)
        if ca.isEmpty && cb.isEmpty {
            if verdict == nil, String(reflecting: a) == String(reflecting: b) { return }
            out.append(path)
            return
        }
        if ca.count != cb.count {
            out.append("\(path) (\(ca.count) → \(cb.count) children)")
            return
        }
        if ma.displayStyle == .dictionary || ma.displayStyle == .set {
            out.append(path)  // unordered: only Equatable's verdict is meaningful, and it said no
            return
        }
        let before = out.count
        for (index, pair) in zip(ca, cb).enumerated() {
            if pair.0.label != pair.1.label {
                out.append("\(path) (case \(pair.0.label ?? "?") → \(pair.1.label ?? "?"))")
                return
            }
            let step: String
            if ma.displayStyle == .collection {
                step = "[\(index)]"
            } else if ma.displayStyle == .optional {
                step = ""
            } else {
                step = "." + (pair.0.label ?? "\(index)")
            }
            walk(pair.0.value, pair.1.value, path + step, &out)
        }
        if out.count == before && verdict == false { out.append(path) }  // a difference Mirror cannot see
    }
}
// END MODP FIXTURE

// MARK: - S2 (p2-sing-x5, design docs/design/2026-10-06-p2-sing-expansion.md §9.2): no style, no byte change

extension ProjectDocumentFidelityTests {

    /// The four G2 fixtures AS COMMITTED (captured on e6f7a27, unchanged at e7e4d24; their sha256 values are
    /// pinned in W8-X5M's PREDICTIONS P1, and this round trip was run green on the tree BEFORE any p2-sing-x5
    /// edit, run PB1). They are the pin-before bytes of S2.
    static let s2FixtureNames = ["empty", "simple", "routed", "kitchen-sink"]

    static func s2FixtureBytes(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json",
                              subdirectory: "Fixtures/ProjectDocumentFidelity"),
            "the fixture \(name).json is not in the test bundle — a missing file must not read as a match")
        return try Data(contentsOf: url)
    }

    /// Opens `bytes` through the real open path's reader (`ProjectBundle.read`), from a temp bundle.
    static func s2Open(_ bytes: Data, _ name: String) throws -> ProjectDocument {
        let bundle = tempBundle("s2-\(name)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try bytes.write(to: bundle.appendingPathComponent("project.json"))
        return try ProjectBundle.read(from: bundle)
    }

    @Test("S2: each committed fixture opens with no singing style and no lyric language, and saves to its pin-before bytes")
    func s2FixturesRoundTripToTheirPinBeforeBytes() throws {
        var clipsSeen = 0
        var midiSeen = 0
        var lyricsSeen = 0
        for name in Self.s2FixtureNames {
            let pinned = try Self.s2FixtureBytes(name)
            #expect(pinned.count > 400, "the fixture \(name).json is implausibly small (\(pinned.count) bytes)")
            let text = String(decoding: pinned, as: UTF8.self)
            #expect(!text.contains("\"singStyle\""), "precondition: \(name).json predates the field")
            #expect(!text.contains("\"language\""), "precondition: \(name).json carries no lyric language")
            let document = try Self.s2Open(pinned, name)
            // The file's own clip records (the ClipDocument mirror), timeline and take lanes.
            let records = document.tracks.flatMap { $0.clips }
                + document.tracks.flatMap { $0.takeGroups ?? [] }.flatMap { $0.lanes }.map { $0.clip }
            for record in records {
                #expect(record.singStyle == nil, "S2 \(name): the file record of '\(record.name)' has a style")
            }
            // And the clips the project opens as (both ClipDocument → Clip reconstructions).
            let runtime = document.runtimeState(bundleURL: URL(fileURLWithPath: "/tmp/x5-s2-\(name).dawproj"))
            let clips = runtime.tracks.flatMap { $0.clips }
                + runtime.tracks.flatMap { $0.takeGroups }.flatMap { $0.lanes }.map { $0.clip }
            #expect(clips.count == records.count, "control: every record opened as a clip")
            for clip in clips {
                clipsSeen += 1
                if clip.isMIDI { midiSeen += 1 }
                #expect(clip.singStyle == nil, "S2 \(name): '\(clip.name)' opened with a singing style")
                if let lyrics = clip.lyrics {
                    lyricsSeen += 1
                    #expect(lyrics.language == nil, "S2 \(name): '\(clip.name)' opened with a language")
                }
            }
            let again = try Self.bundleBytes(of: document)
            #expect(again == pinned, "S2 \(name): \(Self.firstDifference(again, pinned))")
        }
        // Positive control on the language read (p2-sing-x3 landed `ClipLyrics.language`; read directly since
        // W8-X3b): a file that HAS a language opens with it.
        let withLanguage = try JSONDecoder().decode(ClipLyrics.self, from: Data(#"{"text":"a","language":"zh"}"#.utf8))
        #expect(withLanguage.language == "zh", "control: a language that is there is read")
        #expect(clipsSeen >= 5, "control: the fixtures hold clips (\(clipsSeen))")
        #expect(midiSeen >= 2, "control: and MIDI clips, the only kind that can carry a style (\(midiSeen))")
        #expect(lyricsSeen >= 1, "control: and a clip with lyrics (\(lyricsSeen))")
    }

    @Test("S2 control: the round trip CAN fail — a changed document, or a styled clip, no longer matches its pin")
    func s2RoundTripCanFail() throws {
        let pinned = try Self.s2FixtureBytes("kitchen-sink")
        var document = try Self.s2Open(pinned, "kitchen-sink")
        document.savedAt = Date(timeIntervalSince1970: 0)
        #expect(try Self.bundleBytes(of: document) != pinned)

        // A style on the one MIDI clip adds exactly one key, and so changes the bytes.
        var tracks = document.runtimeState(bundleURL: URL(fileURLWithPath: "/tmp/x5-s2-ks.dawproj")).tracks
        let t = try #require(tracks.firstIndex { $0.clips.contains { $0.isMIDI } })
        let c = try #require(tracks[t].clips.firstIndex { $0.isMIDI })
        tracks[t].clips[c].singStyle = SingStyle(vibrato: .wide)
        let styled = ClipDocument(from: tracks[t].clips[c], media: nil)
        #expect(styled.singStyle == SingStyle(vibrato: .wide))
        var restyled = try Self.s2Open(pinned, "kitchen-sink")
        let dt = try #require(restyled.tracks.firstIndex { $0.clips.contains { $0.notes != nil } })
        let dc = try #require(restyled.tracks[dt].clips.firstIndex { $0.notes != nil })
        restyled.tracks[dt].clips[dc] = styled
        let bytes = try Self.bundleBytes(of: restyled)
        #expect(bytes != pinned)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.components(separatedBy: "\"singStyle\"").count - 1 == 1)
    }
}
