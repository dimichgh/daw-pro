import Foundation
import Testing
@testable import DAWCore

// m39-tpl-1 — THE GOLDEN TABLES for the three store rules TPL-1 moved into pure
// DAWCore functions (docs/design/2026-09-27-multi-instrument-templates.md §5.2):
// the effect writer (`EffectDescriptor.applySetting`, formerly
// `ProjectStore.applyEffectParam`), the modulation target rules and 64-slot
// budget (`ModulationRules`), and the sidechain rules (`SidechainRules`).
//
// Every table drives ONLY the live store verbs (`setEffectParam`,
// `setMasterEffectParam`, `validate(target:on:)`, `addModulationRoute`,
// `setSidechain`), so this file compiled and ran unchanged against the code
// BEFORE the move and AFTER it. With `TPL1_GOLDEN_DIR` set, the test writes one
// line per case to `<dir>/<table>.txt`; the before and after directories were
// compared byte for byte (the TPL-1 lane log records the `cmp`). Without the
// variable it only checks each table is big enough to prove anything.
//
// The agreement tests that pair each store outcome with the pure rule's live in
// `EffectSettingRulesTests`, `ModulationRulesTests` and `SidechainRulesTests`,
// and reuse the fixtures below.
//
// ⚠️ An EXTENSION of the existing `@MainActor` suite `EffectChainStoreTests`, not
// a new suite: the `MainActorOccupancySiteTests` cap on `@MainActor` suites (the
// `PolySynthRichnessWireTests` precedent). Helpers carry a `tpl1` prefix.

extension EffectChainStoreTests {
    @Test("m39-tpl-1: the moved rules' golden tables run through the live store verbs")
    func tpl1GoldenTablesThroughTheStore() throws {
        let tables = TPL1Golden.allTables()
        for (name, lines) in tables {
            #expect(lines.count >= 20, "table \(name) has \(lines.count) cases; too few to prove anything")
            // The missing-track strip refuses every target the same way (the
            // track is missing, whatever the target), so its lines repeat by
            // design; every other line must identify its case.
            let identified = lines.filter { !$0.hasPrefix("missing-track ") }
            #expect(Set(identified).count == identified.count || name == "budget",
                    "table \(name) repeats a case line, so a case is not identified by its line")
        }
        if let dir = ProcessInfo.processInfo.environment["TPL1_GOLDEN_DIR"], !dir.isEmpty {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            for (name, lines) in tables {
                try (lines.joined(separator: "\n") + "\n")
                    .write(toFile: dir + "/" + name + ".txt", atomically: true, encoding: .utf8)
            }
        }
    }
}

/// Deterministic tokens for UUIDs, by first appearance, so a table line never
/// carries a per-run id.
@MainActor
final class TPL1Tokens {
    private var map: [String: String] = [:]
    private let pattern = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")

    func scrub(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let id = ns.substring(with: match.range).uppercased()
            if map[id] == nil { map[id] = "#\(map.count + 1)" }
            out += map[id]!
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}

@MainActor
enum TPL1Golden {
    static func allTables() -> [(String, [String])] {
        [
            ("effects", effectTable()),
            ("master-effects", masterEffectTable()),
            ("modulation", modulationTable()),
            ("budget", budgetTable()),
            ("sidechain", sidechainTable()),
        ]
    }

    // MARK: - Shared formatting

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "<unencodable>" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The full, stable description of a thrown error: its case and payload,
    /// plus the sentence a caller reads.
    static func describe(_ error: any Error) -> String {
        let sentence = (error as? LocalizedError)?.errorDescription ?? "-"
        return "ERR \(String(reflecting: error)) | \(sentence)"
    }

    // MARK: - Effects (`fx.setParam` → `setEffectParam` → the moved writer)

    /// The values each setting is driven to: both bounds, the default, two
    /// interior points, one past each bound (the store clamps first), and the
    /// switch / snap probes wherever they are in range.
    static func effectValues(_ spec: EffectParamSpec) -> [Double] {
        let lo = spec.range.lowerBound, hi = spec.range.upperBound, span = hi - lo
        var values = [lo, hi, spec.defaultValue, lo + span * 0.5, lo + span * 0.37,
                      lo - 1 - abs(lo) * 0.5, hi + 1 + abs(hi) * 0.5]
        for extra in [0.49, 0.5, 0.7, 5, 7, 17] where spec.range.contains(extra) {
            values.append(extra)
        }
        return values
    }

    /// The preconditioning value: every setting moved off its default first,
    /// so read-modify-write arms (the delay's `pingPong` rebuild, the gain's
    /// polarity) are exercised with non-default neighbours.
    static func preconditionValue(_ spec: EffectParamSpec) -> Double {
        spec.range.lowerBound + (spec.range.upperBound - spec.range.lowerBound) * 0.63
    }

    static var builtInKinds: [EffectDescriptor.Kind] {
        EffectDescriptor.Kind.allCases.filter { $0 != .audioUnit }
    }

    /// One case: add a fresh insert, optionally precondition every setting,
    /// then drive ONE setting through `setEffectParam`. Returns the insert as
    /// stored (or the refusal) and removes it again.
    static func storeEffectOutcome(store: ProjectStore, trackID: UUID,
                                   kind: EffectDescriptor.Kind, name: String,
                                   value: Double, preconditioned: Bool) -> EffectDescriptor? {
        guard let effect = try? store.addEffect(toTrack: trackID, kind: kind) else { return nil }
        defer { try? store.removeEffect(trackID: trackID, effectID: effect.id) }
        if preconditioned {
            for spec in EffectParamSpec.specs(for: kind) {
                _ = try? store.setEffectParam(trackID: trackID, effectID: effect.id,
                                              name: spec.name, value: preconditionValue(spec))
            }
        }
        _ = try? store.setEffectParam(trackID: trackID, effectID: effect.id,
                                      name: name, value: value)
        return store.tracks.first { $0.id == trackID }?.effects.first { $0.id == effect.id }
    }

    static func effectTable() -> [String] {
        let tokens = TPL1Tokens()
        var lines: [String] = []
        for kind in builtInKinds {
            let store = ProjectStore()
            let trackID = store.addTrack(kind: .audio).id
            for preconditioned in [false, true] {
                for spec in EffectParamSpec.specs(for: kind) {
                    for value in effectValues(spec) {
                        let stored = storeEffectOutcome(
                            store: store, trackID: trackID, kind: kind, name: spec.name,
                            value: value, preconditioned: preconditioned)
                        let state = preconditioned ? "pre" : "fresh"
                        let result: String = stored.map { json($0) } ?? "nil"
                        let line = "\(kind.rawValue).\(spec.name) \(state) \(value) -> \(result)"
                        lines.append(tokens.scrub(line))
                    }
                }
            }
            // An unknown name: the store refuses it before the writer runs.
            if let effect = try? store.addEffect(toTrack: trackID, kind: kind) {
                do {
                    _ = try store.setEffectParam(trackID: trackID, effectID: effect.id,
                                                 name: "zzUnknown", value: 1)
                    lines.append("\(kind.rawValue).zzUnknown -> accepted")
                } catch {
                    lines.append(tokens.scrub("\(kind.rawValue).zzUnknown -> \(describe(error))"))
                }
            }
        }
        return lines
    }

    // MARK: - Master effects (`setMasterEffectParam`, the writer's second call site)

    static func masterEffectTable() -> [String] {
        let tokens = TPL1Tokens()
        var lines: [String] = []
        for kind in builtInKinds {
            let store = ProjectStore()
            for spec in EffectParamSpec.specs(for: kind) {
                let lo = spec.range.lowerBound, hi = spec.range.upperBound
                for value in [lo, hi, lo + (hi - lo) * 0.41, hi + 1 + abs(hi)] {
                    guard let effect = try? store.addMasterEffect(kind: kind) else {
                        lines.append("\(kind.rawValue) add refused")
                        continue
                    }
                    let stored = try? store.setMasterEffectParam(
                        effectID: effect.id, name: spec.name, value: value)
                    let result: String = stored.map { json($0) } ?? "nil"
                    lines.append(tokens.scrub(
                        "master \(kind.rawValue).\(spec.name) \(value) -> \(result)"))
                    try? store.removeMasterEffect(effectID: effect.id)
                }
            }
        }
        return lines
    }

    // MARK: - Modulation targets (`validate(target:on:)`)

    /// A fixture with every strip shape the target rules distinguish: the
    /// master chain; an audio track with a chain that covers every verdict
    /// (yes / warned / refused / controlPlaneOnly / an Audio Unit insert); an
    /// instrument track of every instrument kind (and one with no instrument
    /// set); and a bus.
    struct ModulationFixture {
        let store: ProjectStore
        let strips: [(label: String, strip: ModulationStrip)]
        let targets: [(label: String, target: AutomationTarget)]
    }

    static let missingTrackID = UUID(uuidString: "0000FEED-0000-0000-0000-000000000001")!
    static let missingEffectID = UUID(uuidString: "0000FEED-0000-0000-0000-000000000002")!
    static let missingSendID = UUID(uuidString: "0000FEED-0000-0000-0000-000000000003")!

    static func modulationFixture() -> ModulationFixture {
        let store = ProjectStore()
        var effects: [EffectDescriptor] = []
        let audio = store.addTrack(name: "Audio", kind: .audio)
        for kind in builtInKinds {
            if let effect = try? store.addEffect(toTrack: audio.id, kind: kind) {
                effects.append(effect)
            }
        }
        let unit = AudioUnitConfig(component: AudioUnitComponentID(
            type: "aufx", subType: "tpl1", manufacturer: "Test"))
        if let effect = try? store.addEffect(toTrack: audio.id, kind: .audioUnit, audioUnit: unit) {
            effects.append(effect)
        }
        var masterEffects: [EffectDescriptor] = []
        for kind in [EffectDescriptor.Kind.eq, .delay, .compressor, .reverb, .bitCrusher] {
            if let effect = try? store.addMasterEffect(kind: kind) { masterEffects.append(effect) }
        }
        var strips: [(label: String, strip: ModulationStrip)] = [
            (label: "master", strip: .master), (label: "audio", strip: .track(audio.id))]
        let bare = store.addTrack(name: "No Instrument", kind: .instrument)
        strips.append((label: "instrument-unset", strip: .track(bare.id)))
        for kind in InstrumentDescriptor.Kind.allCases {
            let track = store.addTrack(name: "Inst \(kind.rawValue)", kind: .instrument)
            _ = try? store.setInstrument(id: track.id, kind: kind)
            strips.append((label: "instrument-\(kind.rawValue)", strip: .track(track.id)))
        }
        let bus = store.addTrack(name: "Bus", kind: .bus)
        strips.append((label: "bus", strip: .track(bus.id)))
        strips.append((label: "missing-track", strip: .track(missingTrackID)))

        var targets: [(label: String, target: AutomationTarget)] = [
            (label: "volume", target: .volume), (label: "pan", target: .pan),
            (label: "sendLevel", target: .sendLevel(sendID: missingSendID)),
            (label: "effectParam-missing",
             target: .effectParam(effectID: missingEffectID, paramName: "mix")),
        ]
        for effect in effects + masterEffects {
            for spec in EffectParamSpec.specs(for: effect.kind) {
                targets.append((label: "fx.\(effect.kind.rawValue).\(spec.name)",
                                target: .effectParam(effectID: effect.id, paramName: spec.name)))
            }
            targets.append((label: "fx.\(effect.kind.rawValue).zzUnknown",
                            target: .effectParam(effectID: effect.id, paramName: "zzUnknown")))
        }
        var instrumentNames: Set<String> = ["zzUnknown"]
        for kind in InstrumentDescriptor.Kind.allCases {
            instrumentNames.formUnion(InstrumentParamSpec.specs(for: kind).map(\.name))
            instrumentNames.formUnion(InstrumentParamSpec.discreteParamNames(for: kind))
        }
        for name in instrumentNames.sorted() {
            targets.append((label: "inst.\(name)", target: .instrumentParam(paramName: name)))
        }
        return ModulationFixture(store: store, strips: strips, targets: targets)
    }

    static func storeValidateOutcome(_ store: ProjectStore, _ target: AutomationTarget,
                                     _ strip: ModulationStrip) -> String {
        do {
            let warnings = try store.validate(target: target, on: strip)
            return "OK \(warnings)"
        } catch {
            return describe(error)
        }
    }

    static func modulationTable() -> [String] {
        let tokens = TPL1Tokens()
        let fixture = modulationFixture()
        var lines: [String] = []
        for (stripLabel, strip) in fixture.strips {
            for (targetLabel, target) in fixture.targets {
                lines.append(tokens.scrub("\(stripLabel) \(targetLabel) -> "
                    + storeValidateOutcome(fixture.store, target, strip)))
            }
        }
        return lines
    }

    // MARK: - The shared 64-slot budget (`addModulationRoute`)

    /// Adds routes one by one to distinct effect settings until the store
    /// refuses, on a track with and without automation lanes, and re-routes an
    /// already-modulated setting (costs no slot). One line per attempt.
    static func budgetTable() -> [String] {
        let tokens = TPL1Tokens()
        var lines: [String] = []
        for laneCount in [0, 3] {
            let store = ProjectStore()
            let track = store.addTrack(name: "Budget", kind: .audio)
            var targets: [AutomationTarget] = []
            for kind in [EffectDescriptor.Kind.dynamicEQ, .dynamicEQ, .hallReverb, .eq] {
                guard let effect = try? store.addEffect(toTrack: track.id, kind: kind) else { continue }
                for spec in EffectParamSpec.specs(for: kind) where spec.modulatable != .refused {
                    targets.append(.effectParam(effectID: effect.id, paramName: spec.name))
                }
            }
            // Automation lanes on the LAST settings, so a lane and a route can
            // share a setting only where this table says so.
            for target in targets.suffix(laneCount) {
                if let lane = try? store.addAutomationLane(trackID: track.id, target: target) {
                    _ = try? store.setAutomationPoints(
                        trackID: track.id, laneID: lane.id,
                        points: [AutomationPoint(beat: 0, value: 0.5)])
                }
            }
            guard let source = try? store.addModulationSource(on: .track(track.id), kind: .lfo)
            else {
                lines.append("lanes \(laneCount): source refused")
                continue
            }
            for (index, target) in targets.enumerated() {
                let outcome: String
                do {
                    _ = try store.addModulationRoute(on: .track(track.id), sourceID: source.source.id,
                                                     target: target, depth: 0.1)
                    outcome = "OK"
                } catch {
                    outcome = describe(error)
                }
                lines.append(tokens.scrub("lanes \(laneCount) route \(index) -> \(outcome)"))
                if outcome != "OK" { break }
            }
            // A second route to an already-modulated setting costs no slot.
            if let first = targets.first {
                do {
                    _ = try store.addModulationRoute(on: .track(track.id), sourceID: source.source.id,
                                                     target: first, depth: 0.2)
                    lines.append("lanes \(laneCount) re-route first -> OK")
                } catch {
                    lines.append(tokens.scrub("lanes \(laneCount) re-route first -> \(describe(error))"))
                }
            }
        }
        // The master strip is never budget-checked.
        let store = ProjectStore()
        if let eq = try? store.addMasterEffect(kind: .eq),
           let source = try? store.addModulationSource(on: .master, kind: .lfo) {
            for spec in EffectParamSpec.specs(for: .eq) where spec.modulatable != .refused {
                do {
                    _ = try store.addModulationRoute(
                        on: .master, sourceID: source.source.id,
                        target: .effectParam(effectID: eq.id, paramName: spec.name), depth: 0.1)
                    lines.append("master \(spec.name) -> OK")
                } catch {
                    lines.append(tokens.scrub("master \(spec.name) -> \(describe(error))"))
                }
            }
        }
        return lines
    }

    // MARK: - Sidechain (`setSidechain`)

    /// Fixed, role-named ids, so a table line names its tracks by role.
    enum Role {
        static let audioA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        static let audioB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
        static let audioC = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
        static let bus = UUID(uuidString: "00000000-0000-0000-0000-00000000B005")!
        static let keys = UUID(uuidString: "00000000-0000-0000-0000-00000000CE75")!
        static let compA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
        static let gateA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
        static let eqA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
        static let compB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        static let compC = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
        static let compBus = UUID(uuidString: "00000000-0000-0000-0000-00000000B006")!
        static let compKeys = UUID(uuidString: "00000000-0000-0000-0000-00000000CE76")!
        static let missing = UUID(uuidString: "00000000-0000-0000-0000-00000000DEAD")!
        static let tracks = [audioA, audioB, audioC, bus, keys]
    }

    /// Three audio tracks (A, B, C — C outputs into the bus), a bus and an
    /// instrument track, each with the inserts the rules distinguish. Built
    /// from values, so a recording transport needs no engine.
    static func sidechainTracks() -> [Track] {
        [
            Track(id: Role.audioA, name: "Audio A", kind: .audio, effects: [
                EffectDescriptor(id: Role.compA, kind: .compressor),
                EffectDescriptor(id: Role.gateA, kind: .gate),
                EffectDescriptor(id: Role.eqA, kind: .eq)]),
            Track(id: Role.audioB, name: "Audio B", kind: .audio, effects: [
                EffectDescriptor(id: Role.compB, kind: .compressor)]),
            Track(id: Role.audioC, name: "Audio C", kind: .audio, outputBusID: Role.bus,
                  effects: [EffectDescriptor(id: Role.compC, kind: .compressor)]),
            Track(id: Role.bus, name: "Bus", kind: .bus, effects: [
                EffectDescriptor(id: Role.compBus, kind: .compressor)]),
            Track(id: Role.keys, name: "Keys", kind: .instrument, effects: [
                EffectDescriptor(id: Role.compKeys, kind: .compressor)]),
        ]
    }

    /// One scenario: keys set up first (track, effect, source), then the call.
    struct SidechainScenario {
        let label: String
        let recording: Bool
        let setup: [(UUID, UUID, UUID?)]
        let call: (trackID: UUID, effectID: UUID, sourceID: UUID?)
    }

    static var sidechainScenarios: [SidechainScenario] {
        typealias R = Role
        return [
            .init(label: "unknown-track", recording: false, setup: [],
                  call: (R.missing, R.compA, R.audioB)),
            .init(label: "unknown-effect", recording: false, setup: [],
                  call: (R.audioA, R.missing, R.audioB)),
            .init(label: "eq-with-source", recording: false, setup: [],
                  call: (R.audioA, R.eqA, R.audioB)),
            .init(label: "eq-clearing", recording: false, setup: [],
                  call: (R.audioA, R.eqA, nil)),
            .init(label: "effect-of-another-track", recording: false, setup: [],
                  call: (R.audioA, R.compB, R.audioC)),
            .init(label: "instrument-destination", recording: false, setup: [],
                  call: (R.keys, R.compKeys, R.audioB)),
            .init(label: "instrument-destination-clearing", recording: false, setup: [],
                  call: (R.keys, R.compKeys, nil)),
            .init(label: "missing-source", recording: false, setup: [],
                  call: (R.audioA, R.compA, R.missing)),
            .init(label: "compressor-keyed", recording: false, setup: [],
                  call: (R.audioA, R.compA, R.audioB)),
            .init(label: "bus-destination", recording: false, setup: [],
                  call: (R.bus, R.compBus, R.audioB)),
            .init(label: "second-key-same-strip", recording: false,
                  setup: [(R.audioA, R.compA, R.audioB)],
                  call: (R.audioA, R.gateA, R.audioC)),
            .init(label: "rekey-same-effect", recording: false,
                  setup: [(R.audioA, R.compA, R.audioB)],
                  call: (R.audioA, R.compA, R.audioC)),
            .init(label: "clear-key", recording: false,
                  setup: [(R.audioA, R.compA, R.audioB)],
                  call: (R.audioA, R.compA, nil)),
            .init(label: "self-key", recording: false, setup: [],
                  call: (R.audioA, R.compA, R.audioA)),
            .init(label: "mutual-keys", recording: false,
                  setup: [(R.audioA, R.compA, R.audioB)],
                  call: (R.audioB, R.compB, R.audioA)),
            .init(label: "three-strip-loop", recording: false,
                  setup: [(R.audioA, R.compA, R.audioB), (R.audioB, R.compB, R.audioC)],
                  call: (R.audioC, R.compC, R.audioA)),
            .init(label: "bus-keyed-from-its-feeder", recording: false, setup: [],
                  call: (R.bus, R.compBus, R.audioC)),
            .init(label: "feeder-keyed-from-a-bus-keyer", recording: false,
                  setup: [(R.bus, R.compBus, R.audioA)],
                  call: (R.audioA, R.compA, R.audioC)),
            .init(label: "recording", recording: true, setup: [],
                  call: (R.audioA, R.compA, R.audioB)),
            .init(label: "recording-unknown-track", recording: true, setup: [],
                  call: (R.missing, R.compA, R.audioB)),
        ]
    }

    /// The scenario's store with its setup keys applied.
    static func prepare(_ scenario: SidechainScenario) -> ProjectStore {
        let store = ProjectStore(tracks: sidechainTracks())
        for (track, effect, source) in scenario.setup {
            _ = try? store.setSidechain(trackID: track, effectID: effect, sourceTrackID: source)
        }
        if scenario.recording {
            var transport = TransportState()
            transport.isRecording = true
            return ProjectStore(tracks: store.tracks, transport: transport)
        }
        return store
    }

    static func storeSidechainOutcome(_ store: ProjectStore, trackID: UUID, effectID: UUID,
                                      sourceID: UUID?) -> String {
        do {
            let effect = try store.setSidechain(trackID: trackID, effectID: effectID,
                                                sourceTrackID: sourceID)
            return "OK key=\(effect.sidechainSourceTrackID?.uuidString ?? "none")"
        } catch {
            return describe(error)
        }
    }

    /// Every scenario as written, then the same call with the source swept
    /// across every track and a missing id (a wide sweep of the source rules).
    static func sidechainTable() -> [String] {
        var lines: [String] = []
        for scenario in sidechainScenarios {
            let call = scenario.call
            lines.append("\(scenario.label) -> " + storeSidechainOutcome(
                prepare(scenario), trackID: call.trackID, effectID: call.effectID,
                sourceID: call.sourceID))
            for source in Role.tracks + [Role.missing] {
                lines.append("\(scenario.label) source=\(source.uuidString.suffix(4)) -> "
                    + storeSidechainOutcome(prepare(scenario), trackID: call.trackID,
                                            effectID: call.effectID, sourceID: source))
            }
        }
        return lines
    }
}
