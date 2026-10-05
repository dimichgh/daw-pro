import Foundation
import Testing
@testable import DAWCore

// m39-tpl-1 — the modulation target rules and the shared 64-slot budget moved
// to ONE home, `ModulationRules` (formerly the body of
// `ProjectStore.validate(target:on:)` and `checkCombinedTrackBudget`;
// docs/design/2026-09-27-multi-instrument-templates.md §5.2).
//
// - AGREEMENT (the `AutomationStoreTests` extension): every strip × target of
//   the golden fixture judged by the store and by the pure rule, and the
//   budget predicted by the pure rule BEFORE each `addModulationRoute` the
//   store then accepts or refuses. If the store ever judges a target, or
//   counts a slot, differently from the rule a template is built by, this
//   goes red.
// - THE RULE ON TRACKS THAT DO NOT EXIST YET (the nonisolated suite): what the
//   template builder will ask of it.

extension AutomationStoreTests {
    @Test("m39-tpl-1: the store's target judgement IS ModulationRules.validate, on every strip of the fixture")
    func tpl1StoreValidateAgreesWithTheRule() {
        let fixture = TPL1Golden.modulationFixture()
        let store = fixture.store
        var cases = 0
        var accepted = 0, warned = 0, refused = 0
        var disagreements: [String] = []
        for (label, strip) in fixture.strips {
            let pureStrip: ModulationRules.Strip
            switch strip {
            case .master:
                pureStrip = .master(effects: store.masterEffects)
            case .track(let id):
                // A missing track is the store wrapper's case, not the rule's
                // (the golden table pins it); the rule is judged on real strips.
                guard let track = store.tracks.first(where: { $0.id == id }) else { continue }
                pureStrip = .track(track)
            }
            for (targetLabel, target) in fixture.targets {
                let viaStore = TPL1Golden.storeValidateOutcome(store, target, strip)
                let viaRule: String
                do {
                    viaRule = "OK \(try ModulationRules.validate(target: target, on: pureStrip))"
                } catch {
                    viaRule = TPL1Golden.describe(error)
                }
                cases += 1
                if viaStore == "OK []" {
                    accepted += 1
                } else if viaStore.hasPrefix("OK [\"") {
                    warned += 1
                } else if viaStore.hasPrefix("ERR") {
                    refused += 1
                }
                if viaStore != viaRule {
                    disagreements.append("\(label) \(targetLabel): store \(viaStore) / rule \(viaRule)")
                }
            }
        }
        print("TPL1-MEASURE modulation agreement: \(cases) cases (\(accepted) accepted, \(warned) warned, "
              + "\(refused) refused), \(disagreements.count) disagreements")
        #expect(cases > 1000, "positive control: the fixture must cover the targets")
        #expect(accepted > 0 && warned > 0 && refused > 0 && accepted + warned + refused == cases,
                "positive control: accepted, warned and refused must all occur, and nothing else")
        // A Bool, not the array: a failing `#expect` prints every value it
        // captured in full, and this table holds thousands of cases.
        let agree = disagreements.isEmpty
        #expect(agree, "\(disagreements.count) disagreements, first: \(disagreements.first ?? "")")
    }

    @Test("m39-tpl-1: ModulationRules predicts every addModulationRoute budget verdict before the store gives it")
    func tpl1StoreBudgetAgreesWithTheRule() throws {
        var predictions = 0, refusals = 0
        // At least TWO lanes on every run: `addModulationRoute` checks its
        // separate 64-ROUTES cap before the budget. The budget stops new
        // settings at 64 - lanes routes, and the tail below adds one more
        // (a free re-route), so the route count peaks at 65 - lanes, which
        // must stay under 64 for the budget's own verdict to be the store's.
        for laneCount in [2, 3] {
            let store = ProjectStore()
            let trackID = store.addTrack(name: "Budget", kind: .audio).id
            var targets: [AutomationTarget] = []
            for kind in [EffectDescriptor.Kind.dynamicEQ, .dynamicEQ, .hallReverb, .eq] {
                let effect = try store.addEffect(toTrack: trackID, kind: kind)
                for spec in EffectParamSpec.specs(for: kind) where spec.modulatable != .refused {
                    targets.append(.effectParam(effectID: effect.id, paramName: spec.name))
                }
            }
            for target in targets.suffix(laneCount) {
                let lane = try store.addAutomationLane(trackID: trackID, target: target)
                _ = try store.setAutomationPoints(trackID: trackID, laneID: lane.id,
                                                  points: [AutomationPoint(beat: 0, value: 0.5)])
            }
            let source = try store.addModulationSource(on: .track(trackID), kind: .lfo)
            // The last target again at the end: already automated when lanes
            // exist, so it must cost no slot.
            for target in targets + [targets[0], targets[targets.count - 1]] {
                let track = try #require(store.tracks.first { $0.id == trackID })
                let predicted: String?
                do {
                    try ModulationRules.checkCombinedBudget(on: track, adding: target)
                    predicted = nil
                } catch {
                    predicted = TPL1Golden.describe(error)
                }
                let outcome: String?
                do {
                    _ = try store.addModulationRoute(on: .track(trackID), sourceID: source.source.id,
                                                     target: target, depth: 0.1)
                    outcome = nil
                } catch {
                    outcome = TPL1Golden.describe(error)
                }
                predictions += 1
                #expect(outcome == predicted, "lanes \(laneCount), \(target): store \(String(describing: outcome)) / rule \(String(describing: predicted))")
                if let predicted {
                    refusals += 1
                    #expect(predicted.contains("modulationLimitExceeded"), "\(predicted)")
                    #expect(ModulationRules.slotsUsed(by: track) == ModulationLimits.maxRoutes,
                            "a refusal means the strip is full")
                }
            }
            let final = try #require(store.tracks.first { $0.id == trackID })
            #expect(ModulationRules.slotsUsed(by: final) <= ModulationLimits.maxRoutes)
        }
        print("TPL1-MEASURE budget agreement: \(predictions) predictions, \(refusals) refusals")
        #expect(refusals >= 2, "positive control: both runs must hit the cap")
    }
}

@Suite("m39-tpl-1: ModulationRules on tracks that do not exist yet")
struct ModulationRulesTests {
    static func eqTrack(inserts: Int, kind: TrackKind = .audio) -> Track {
        Track(name: "Template Track", kind: kind,
              effects: (0..<inserts).map { _ in EffectDescriptor.newlyAdded(kind: .eq) })
    }

    /// Every modulatable (effect, setting) target on `track`, in order.
    static func targets(on track: Track) -> [AutomationTarget] {
        track.effects.flatMap { effect in
            EffectParamSpec.specs(for: effect.kind)
                .filter { $0.modulatable != .refused }
                .map { AutomationTarget.effectParam(effectID: effect.id, paramName: $0.name) }
        }
    }

    @Test("targets are judged on a template's track value: allowed, warned, refused, with reasons")
    func validateOnAValue() throws {
        let compressor = EffectDescriptor.newlyAdded(kind: .compressor)
        let eq = EffectDescriptor.newlyAdded(kind: .eq)
        let audio = Track(name: "Vocal", kind: .audio, effects: [compressor, eq])
        #expect(try ModulationRules.validate(target: .volume, on: .track(audio)).isEmpty)
        #expect(try ModulationRules.validate(target: .pan, on: .track(audio)).isEmpty)
        #expect(try ModulationRules.validate(
            target: .effectParam(effectID: compressor.id, paramName: "thresholdDb"),
            on: .track(audio)).isEmpty)
        let warned = try ModulationRules.validate(
            target: .effectParam(effectID: eq.id, paramName: "peak1Freq"), on: .track(audio))
        #expect(warned.count == 1, "\(warned)")
        #expect(warned.first?.hasPrefix("\(ModulationWarning.targetSteps)") == true, "\(warned)")
        #expect(throws: ModulationError.self) {
            try ModulationRules.validate(
                target: .effectParam(effectID: eq.id, paramName: "highPassEnabled"),
                on: .track(audio))
        }
        #expect(throws: ProjectError.self) {
            try ModulationRules.validate(
                target: .effectParam(effectID: UUID(), paramName: "mix"), on: .track(audio))
        }
        #expect(throws: ModulationError.self) {
            try ModulationRules.validate(target: .instrumentParam(paramName: "cutoffHz"),
                                         on: .track(audio))
        }
        #expect(throws: ModulationError.self) {
            try ModulationRules.validate(target: .sendLevel(sendID: UUID()), on: .track(audio))
        }
        let synth = Track(name: "Lead", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .polySynth))
        #expect(try ModulationRules.validate(target: .instrumentParam(paramName: "cutoffHz"),
                                             on: .track(synth)).isEmpty)
        #expect(throws: ModulationError.self) {
            try ModulationRules.validate(target: .instrumentParam(paramName: "cutoffHz"),
                                         on: .master(effects: []))
        }
    }

    @Test("slotsUsed counts lanes with points plus modulated settings that are not automated, once each")
    func slotsUsedCountsEachSettingOnce() throws {
        var track = Self.eqTrack(inserts: 1)
        let targets = Self.targets(on: track)
        try #require(targets.count >= 6)
        let source = UUID()
        track.modulationRoutes = targets.prefix(4).map {
            ModulationRoute(sourceID: source, target: $0, depth: 0.1)
        }
        #expect(ModulationRules.slotsUsed(by: track) == 4)
        // A second route to a modulated setting costs nothing.
        track.modulationRoutes.append(ModulationRoute(sourceID: source, target: targets[0], depth: 0.2))
        #expect(ModulationRules.slotsUsed(by: track) == 4)
        // A disabled route costs nothing.
        track.modulationRoutes.append(
            ModulationRoute(sourceID: source, target: targets[5], depth: 0.2, enabled: false))
        #expect(ModulationRules.slotsUsed(by: track) == 4)
        // A lane with points on a routed setting: the setting still costs one.
        let point = AutomationPoint(beat: 0, value: 0.5)
        track.automation = [AutomationLane(target: targets[0], points: [point])]
        #expect(ModulationRules.slotsUsed(by: track) == 4)
        // A lane with points on an unrouted setting costs one more.
        track.automation.append(AutomationLane(target: targets[4], points: [point]))
        #expect(ModulationRules.slotsUsed(by: track) == 5)
        // A lane with no points, or a disabled one, costs nothing.
        track.automation.append(AutomationLane(target: targets[5]))
        track.automation.append(AutomationLane(target: targets[5], points: [point], isEnabled: false))
        #expect(ModulationRules.slotsUsed(by: track) == 5)
    }

    @Test("the budget: a full strip refuses a NEW setting and accepts one it already modulates")
    func budgetOnAValue() throws {
        var track = Self.eqTrack(inserts: 5)
        let targets = Self.targets(on: track)
        // Positive control, and a guard: the indexing below needs 65 settings.
        try #require(targets.count > ModulationLimits.maxRoutes, "positive control: enough settings")
        let source = UUID()
        track.modulationRoutes = targets.prefix(ModulationLimits.maxRoutes).map {
            ModulationRoute(sourceID: source, target: $0, depth: 0.1)
        }
        #expect(ModulationRules.slotsUsed(by: track) == ModulationLimits.maxRoutes)
        #expect(throws: ModulationError.self) {
            try ModulationRules.checkCombinedBudget(
                on: track, adding: targets[ModulationLimits.maxRoutes])
        }
        try ModulationRules.checkCombinedBudget(on: track, adding: targets[0])
        try ModulationRules.checkCombinedBudget(on: track, adding: .volume)
        // One under the cap: a new setting fits.
        track.modulationRoutes.removeLast()
        try ModulationRules.checkCombinedBudget(on: track,
                                                adding: targets[ModulationLimits.maxRoutes])
    }

    /// ⚠️ A PRE-EXISTING DEFECT, MOVED VERBATIM (TPL-1 had to keep the rule
    /// byte-identical; reported, not fixed). On a full strip, a route to a
    /// setting that is already AUTOMATED would not use a slot — the lane already
    /// pays for it, and `slotsUsed` after the add is unchanged — yet the check
    /// counts the lane AND the new key and refuses. The refusal's own advice
    /// ("modulate a parameter that is already automated — an automated parameter
    /// costs no extra slot") therefore fails when followed. When the rule is
    /// fixed, this known issue stops recording and the test fails: flip it then.
    @Test("KNOWN DEFECT: a full strip refuses a route to an automated setting, though that costs no slot")
    func automatedSettingOnAFullStripIsRefused() throws {
        var track = Self.eqTrack(inserts: 5)
        let targets = Self.targets(on: track)
        try #require(targets.count >= ModulationLimits.maxRoutes, "enough settings to fill a strip")
        let source = UUID()
        let automated = targets[ModulationLimits.maxRoutes - 1]
        track.automation = [AutomationLane(target: automated,
                                           points: [AutomationPoint(beat: 0, value: 0.5)])]
        track.modulationRoutes = targets.prefix(ModulationLimits.maxRoutes - 1).map {
            ModulationRoute(sourceID: source, target: $0, depth: 0.1)
        }
        #expect(ModulationRules.slotsUsed(by: track) == ModulationLimits.maxRoutes)
        var after = track
        after.modulationRoutes.append(ModulationRoute(sourceID: source, target: automated, depth: 0.1))
        #expect(ModulationRules.slotsUsed(by: after) == ModulationLimits.maxRoutes,
                "the route would not use a slot")
        withKnownIssue("checkCombinedBudget counts an automated setting's lane AND its new key") {
            try ModulationRules.checkCombinedBudget(on: track, adding: automated)
        }
    }
}
