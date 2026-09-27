import Foundation
import Testing
@testable import DAWCore

// m39-tpl-1 — the effect writer moved to ONE home, `EffectDescriptor.applySetting`
// (formerly `ProjectStore.applyEffectParam`; docs/design/2026-09-27-multi-instrument-templates.md §5.2).
//
// Two gates, deliberately different in kind:
// - AGREEMENT (the `EffectChainStoreTests` extension): the live verbs'
//   store methods, `setEffectParam` and `setMasterEffectParam`, against the
//   pure writer driven by hand from `EffectDescriptor.newlyAdded(kind:)` with
//   the store's clamp. If a store method ever stops routing through the one
//   writer, or writes something the writer would not, this goes red. It reuses
//   the golden fixtures in `TemplateMovedRulesTests.swift`.
// - THE WRITER'S OWN PROMISES (the nonisolated suite): an unknown name is a
//   no-op on every kind, the EQ's coupled pair lands the same in both orders,
//   and a phaser's stage count snaps. The template codec's read-back rule
//   depends on all three.

/// A descriptor's content with its `id` removed, as sorted-key JSON, so a
/// store-made insert and a hand-made one can be compared field for field.
func tpl1EffectShape(_ effect: EffectDescriptor) -> String {
    guard let data = try? JSONEncoder().encode(effect),
          var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return "<unencodable>" }
    object["id"] = nil
    guard let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    else { return "<unencodable>" }
    return String(decoding: sorted, as: UTF8.self)
}

extension EffectChainStoreTests {
    @Test("m39-tpl-1: fx.setParam's store method writes exactly what the one writer writes, fresh and preconditioned")
    func tpl1StoreEffectWriterAgreesWithThePureWriter() throws {
        var cases = 0
        var disagreements: [String] = []
        for kind in TPL1Golden.builtInKinds {
            let store = ProjectStore()
            let trackID = store.addTrack(kind: .audio).id
            let specs = EffectParamSpec.specs(for: kind)
            for preconditioned in [false, true] {
                for spec in specs {
                    for value in TPL1Golden.effectValues(spec) {
                        let effect = try store.addEffect(toTrack: trackID, kind: kind)
                        // The pure side starts where every new insert starts.
                        var pure = EffectDescriptor.newlyAdded(kind: kind)
                        if tpl1EffectShape(effect) != tpl1EffectShape(pure) {
                            disagreements.append("\(kind.rawValue): the store's new insert is not newlyAdded(kind:)")
                        }
                        if preconditioned {
                            for other in specs {
                                let moved = TPL1Golden.preconditionValue(other)
                                _ = try store.setEffectParam(trackID: trackID, effectID: effect.id,
                                                             name: other.name, value: moved)
                                pure.applySetting(other.name, moved.clamped(to: other.range))
                            }
                        }
                        let stored = try store.setEffectParam(trackID: trackID, effectID: effect.id,
                                                              name: spec.name, value: value)
                        pure.applySetting(spec.name, value.clamped(to: spec.range))
                        cases += 1
                        if tpl1EffectShape(stored) != tpl1EffectShape(pure) {
                            disagreements.append("\(kind.rawValue).\(spec.name) "
                                + "\(preconditioned ? "pre" : "fresh") \(value): store "
                                + "\(tpl1EffectShape(stored)) vs writer \(tpl1EffectShape(pure))")
                        }
                        try store.removeEffect(trackID: trackID, effectID: effect.id)
                    }
                }
            }
        }
        print("TPL1-MEASURE effect agreement: \(cases) cases, \(disagreements.count) disagreements")
        #expect(cases > 1000, "positive control: the table must drive every setting of every kind")
        #expect(disagreements.isEmpty,
                "\(disagreements.count) disagreements, first: \(disagreements.prefix(3))")
    }

    @Test("m39-tpl-1: the master chain's setter writes exactly what the one writer writes")
    func tpl1MasterEffectWriterAgreesWithThePureWriter() throws {
        var cases = 0
        var disagreements: [String] = []
        let store = ProjectStore()
        for kind in TPL1Golden.builtInKinds {
            for spec in EffectParamSpec.specs(for: kind) {
                let lo = spec.range.lowerBound, hi = spec.range.upperBound
                for value in [lo, hi, lo + (hi - lo) * 0.41, hi + 1 + abs(hi)] {
                    let effect = try store.addMasterEffect(kind: kind)
                    var pure = effect
                    let stored = try store.setMasterEffectParam(
                        effectID: effect.id, name: spec.name, value: value)
                    pure.applySetting(spec.name, value.clamped(to: spec.range))
                    cases += 1
                    if stored != pure {
                        disagreements.append("master \(kind.rawValue).\(spec.name) \(value)")
                    }
                    try store.removeMasterEffect(effectID: effect.id)
                }
            }
        }
        print("TPL1-MEASURE master effect agreement: \(cases) cases, \(disagreements.count) disagreements")
        #expect(cases > 500, "positive control")
        #expect(disagreements.isEmpty, "\(disagreements.prefix(5))")
    }
}

@Suite("m39-tpl-1: the one effect writer — its own promises")
struct EffectSettingRulesTests {
    static var builtInKinds: [EffectDescriptor.Kind] {
        EffectDescriptor.Kind.allCases.filter { $0 != .audioUnit }
    }

    @Test("an unknown name changes nothing, on every kind, fresh or dialled")
    func unknownNameIsANoOp() {
        var kinds = 0
        for kind in Self.builtInKinds {
            var effect = EffectDescriptor.newlyAdded(kind: kind)
            let fresh = effect
            effect.applySetting("zzNotASetting", 1)
            #expect(effect == fresh, "\(kind.rawValue): fresh")
            for spec in EffectParamSpec.specs(for: kind) {
                let lo = spec.range.lowerBound, hi = spec.range.upperBound
                effect.applySetting(spec.name, lo + (hi - lo) * 0.63)
            }
            let dialled = effect
            effect.applySetting("zzNotASetting", 1)
            effect.applySetting("", 0.5)
            #expect(effect == dialled, "\(kind.rawValue): dialled")
            // Control: the dialled descriptor really did move off the fresh one.
            #expect(dialled != fresh || EffectParamSpec.specs(for: kind).isEmpty,
                    "\(kind.rawValue): the control write changed nothing")
            kinds += 1
        }
        #expect(kinds == Self.builtInKinds.count && kinds >= 20)
    }

    @Test("every setting the specs list is one the writer writes (it reads back off the default)")
    func everySpecIsWritten() throws {
        var silent: [String] = []
        for kind in Self.builtInKinds {
            for spec in EffectParamSpec.specs(for: kind) {
                var effect = EffectDescriptor.newlyAdded(kind: kind)
                let lo = spec.range.lowerBound, hi = spec.range.upperBound
                // Whichever bound is further from the default: a write that
                // lands must move the reading.
                let target = abs(hi - spec.defaultValue) >= abs(spec.defaultValue - lo) ? hi : lo
                effect.applySetting(spec.name, target)
                let read = try #require(effect.paramValue(spec.name), "\(kind.rawValue).\(spec.name)")
                if read == spec.defaultValue { silent.append("\(kind.rawValue).\(spec.name)") }
            }
        }
        #expect(silent.isEmpty, "settings the writer ignores: \(silent)")
    }

    @Test("the EQ's coupled pair: enabling and setting a high-pass land the same in either order")
    func eqCouplingIsOrderFree() {
        var enableFirst = EffectDescriptor.newlyAdded(kind: .eq)
        enableFirst.applySetting("highPassEnabled", 1)
        #expect(enableFirst.paramValue("highPassFreq") == EQParams.highPassFreqRange.lowerBound,
                "enabling with no corner materialises the lowest corner")
        enableFirst.applySetting("highPassFreq", 120)
        var frequencyFirst = EffectDescriptor.newlyAdded(kind: .eq)
        frequencyFirst.applySetting("highPassFreq", 120)
        frequencyFirst.applySetting("highPassEnabled", 1)
        #expect(tpl1EffectShape(enableFirst) == tpl1EffectShape(frequencyFirst))
        #expect(enableFirst.paramValue("highPassEnabled") == 1)
        #expect(enableFirst.paramValue("highPassFreq") == 120)
    }

    @Test("a phaser's stage count snaps to what the render uses: 5 reads back 6, 8 reads back 8")
    func phaserStagesSnap() {
        var effect = EffectDescriptor.newlyAdded(kind: .phaser)
        effect.applySetting("stages", 5)
        #expect(effect.paramValue("stages") == 6)
        effect.applySetting("stages", 8)
        #expect(effect.paramValue("stages") == 8)
    }
}
