import Foundation
import Testing
@testable import DAWCore

// m39-tpl-1 — the sidechain key rules moved to ONE home, `SidechainRules.check`
// (formerly inline in `ProjectStore.setSidechain`;
// docs/design/2026-09-27-multi-instrument-templates.md §5.2).
//
// - AGREEMENT (the `SidechainCoreTests` extension): every scenario of the
//   golden fixture, with the source swept over every track, judged by the
//   store verb and by the pure rule over the same tracks. The one thing only
//   the store does — refusing while recording — is pinned as a row.
// - THE RULE ON A TEMPLATE'S TRACKS (the nonisolated suite): values that
//   never lived in a store, shaped like the design's §4.3 example.

extension SidechainCoreTests {
    @Test("m39-tpl-1: setSidechain's verdict IS SidechainRules.check's, scenario by scenario and source by source")
    func tpl1StoreSidechainAgreesWithTheRule() {
        var cases = 0
        var accepted = 0
        var disagreements: [String] = []
        for scenario in TPL1Golden.sidechainScenarios where !scenario.recording {
            let call = scenario.call
            for source in [call.sourceID] + TPL1Golden.Role.tracks.map(Optional.some)
                + [TPL1Golden.Role.missing, nil] {
                let store = TPL1Golden.prepare(scenario)
                let before = store.tracks
                let viaRule: String
                do {
                    try SidechainRules.check(keying: call.trackID, effect: call.effectID,
                                             from: source, in: before)
                    viaRule = "OK"
                } catch {
                    viaRule = TPL1Golden.describe(error)
                }
                let viaStore = TPL1Golden.storeSidechainOutcome(
                    store, trackID: call.trackID, effectID: call.effectID, sourceID: source)
                cases += 1
                if viaStore.hasPrefix("OK") { accepted += 1 }
                let storeVerdict = viaStore.hasPrefix("OK") ? "OK" : viaStore
                if storeVerdict != viaRule {
                    disagreements.append("\(scenario.label) source=\(source?.uuidString.suffix(4) ?? "nil"): store \(viaStore) / rule \(viaRule)")
                }
            }
        }
        print("TPL1-MEASURE sidechain agreement: \(cases) cases, \(accepted) accepted, "
              + "\(disagreements.count) disagreements")
        #expect(cases >= 100 && accepted > 5 && accepted < cases,
                "positive control: both verdicts must occur")
        #expect(disagreements.isEmpty, "\(disagreements.prefix(3))")
    }

    @Test("m39-tpl-1: only the store refuses while recording; the rule's verdict is the same as when idle")
    func tpl1RecordingIsTheStoresRefusalAlone() {
        for scenario in TPL1Golden.sidechainScenarios where scenario.recording {
            let store = TPL1Golden.prepare(scenario)
            let call = scenario.call
            let viaStore = TPL1Golden.storeSidechainOutcome(
                store, trackID: call.trackID, effectID: call.effectID, sourceID: call.sourceID)
            #expect(viaStore.contains("transportBusy"), "\(scenario.label): \(viaStore)")
            let idle = ProjectStore(tracks: store.tracks)
            let viaIdleStore = TPL1Golden.storeSidechainOutcome(
                idle, trackID: call.trackID, effectID: call.effectID, sourceID: call.sourceID)
            let viaRule: String
            do {
                try SidechainRules.check(keying: call.trackID, effect: call.effectID,
                                         from: call.sourceID, in: store.tracks)
                viaRule = "OK"
            } catch {
                viaRule = TPL1Golden.describe(error)
            }
            #expect((viaIdleStore.hasPrefix("OK") ? "OK" : viaIdleStore) == viaRule,
                    "\(scenario.label): idle store \(viaIdleStore) / rule \(viaRule)")
        }
    }
}

@Suite("m39-tpl-1: SidechainRules on a template's tracks")
struct SidechainRulesTests {
    struct Kit {
        let drums = Track(name: "Drums", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .drumSynth))
        let keys: Track
        let duck: Track
        let room = Track(name: "Tape Room", kind: .bus,
                         effects: [EffectDescriptor.newlyAdded(kind: .hallReverb)])
        let duckCompressor = EffectDescriptor.newlyAdded(kind: .compressor)

        init() {
            duck = Track(name: "Keys Duck", kind: .bus, effects: [duckCompressor])
            keys = Track(name: "Keys", kind: .instrument, outputBusID: duck.id)
        }

        var tracks: [Track] { [drums, keys, duck, room] }
    }

    @Test("the §4.3 shape: a ducking bus keyed from the drums passes")
    func duckingBusKeyedFromDrums() throws {
        let kit = Kit()
        try SidechainRules.check(keying: kit.duck.id, effect: kit.duckCompressor.id,
                                 from: kit.drums.id, in: kit.tracks)
        try SidechainRules.check(keying: kit.duck.id, effect: kit.duckCompressor.id,
                                 from: nil, in: kit.tracks)
    }

    /// The refusal a check gives, as its case name (`ProjectError` is not
    /// Equatable), or "OK".
    static func verdict(_ check: () throws -> Void) -> String {
        do {
            try check()
            return "OK"
        } catch let error as ProjectError {
            return String(String(reflecting: error).split(separator: "(").first ?? "")
        } catch {
            return "other: \(error)"
        }
    }

    @Test("a template's broken keys are refused, each with its own error")
    func brokenKeys() {
        let kit = Kit()
        let reverb = kit.room.effects[0]
        #expect(Self.verdict {
            try SidechainRules.check(keying: kit.room.id, effect: reverb.id,
                                     from: kit.drums.id, in: kit.tracks)
        }.hasSuffix("sidechainUnsupportedEffect"))
        let keyedSynth = EffectDescriptor.newlyAdded(kind: .compressor)
        var keys = kit.keys
        keys.effects = [keyedSynth]
        #expect(Self.verdict {
            try SidechainRules.check(keying: keys.id, effect: keyedSynth.id, from: kit.drums.id,
                                     in: [kit.drums, keys, kit.duck, kit.room])
        }.hasSuffix("sidechainUnsupportedTrack"))
        #expect(Self.verdict {
            try SidechainRules.check(keying: kit.duck.id, effect: kit.duckCompressor.id,
                                     from: kit.room.id, in: kit.tracks)
        }.hasSuffix("sidechainUnsupportedSource"))
        // A bus keyed from ITSELF is refused as a bus source first: the rules
        // run in their fixed order, and the source rule comes before the loop.
        #expect(Self.verdict {
            try SidechainRules.check(keying: kit.duck.id, effect: kit.duckCompressor.id,
                                     from: kit.duck.id, in: kit.tracks)
        }.hasSuffix("sidechainUnsupportedSource"))
        // An audio strip keying itself closes a loop.
        let selfCompressor = EffectDescriptor.newlyAdded(kind: .compressor)
        let vocal = Track(name: "Vocal", kind: .audio, effects: [selfCompressor])
        #expect(Self.verdict {
            try SidechainRules.check(keying: vocal.id, effect: selfCompressor.id, from: vocal.id,
                                     in: [vocal])
        }.hasSuffix("sidechainWouldCreateCycle"))
        // Two strips keying each other close a loop: X is keyed from Y
        // already, so keying Y from X is refused.
        let yCompressor = EffectDescriptor.newlyAdded(kind: .compressor)
        let y = Track(name: "Y", kind: .audio, effects: [yCompressor])
        let x = Track(name: "X", kind: .audio, effects: [EffectDescriptor(
            kind: .compressor, sidechainSourceTrackID: y.id)])
        #expect(Self.verdict {
            try SidechainRules.check(keying: y.id, effect: yCompressor.id, from: x.id, in: [x, y])
        }.hasSuffix("sidechainWouldCreateCycle"))
        // Control: the same key with X unkeyed passes.
        let freeX = Track(id: x.id, name: "X", kind: .audio,
                          effects: [EffectDescriptor.newlyAdded(kind: .compressor)])
        #expect(Self.verdict {
            try SidechainRules.check(keying: y.id, effect: yCompressor.id, from: x.id,
                                     in: [freeX, y])
        } == "OK")
        #expect(Self.verdict {
            try SidechainRules.check(keying: kit.duck.id, effect: kit.duckCompressor.id,
                                     from: kit.drums.id, in: [kit.duck])
        }.hasSuffix("trackNotFound"))
    }
}
