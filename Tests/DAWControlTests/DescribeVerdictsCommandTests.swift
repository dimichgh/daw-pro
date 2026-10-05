import Foundation
import Testing
import DAWCore
@testable import DAWControl
@testable import DAWEngine

/// m39-f-3 — wire truthfulness for `fx.describe`'s `modulatable` verdict, AND
/// m39-f-2 — wire truthfulness for `instrument.describeSynth`'s `curve`.
///
/// **m39-f-3.** `mod.describeKinds`'s own `targets.effectParam` prose has told
/// agents "Per-parameter honesty is in fx.describe's modulatable verdict"
/// since m39-e. Before m39-f-3 that was a FALSE claim on the wire:
/// `fx.describe`'s `paramObj` never emitted a `modulatable` key for any kind
/// (the only `"modulatable"` key anywhere in `Commands.swift` was
/// `instrument.describeDrumKit`'s). This suite is deliberately NOT a
/// source-string check ("does the JSON carry the right label") — every test
/// here also drives a REAL `mod.addRoute` against the exact same parameter
/// and asserts the wire verdict predicts what actually happens: `yes` routes
/// clean, `warned` routes with a warning, `refused` throws.
/// `EffectParamSpec.modulatable` is the ONE table both `fx.describe` and
/// `ProjectStore+Modulation.swift`'s `validate(target:on:)` (the function
/// `mod.addRoute` calls) read, so this is a same-source guarantee, not a
/// coincidence to be re-verified by hand every time a param's verdict changes.
///
/// **m39-f-2.** `instrument.describeSynth` now reports `curve` for the 7
/// Poly Synth params `InstrumentParamSpec` declares (never the other 17,
/// which have no declared curve). The orchestrator's ruling (2026-09-27):
/// report what MODULATION does, since a census (`@testable import DAWEngine`
/// below) found `InstrumentParamSpec.curve` has exactly TWO consumers, and
/// they agree: `ModulationSnapshotBuilder.resolveTarget`'s `.instrumentParam`
/// branch (the live render-thread path) and `Commands.swift`'s own
/// `modulatedValue` (the `mod.describe` read-path preview of the same law) —
/// automation reads the same spec table for its value RANGE only
/// (`Sources/DAWCore/Automation.swift:158`), never `.curve`. So `attack`/
/// `decay`/`release` report `logarithmic` (what a real route applies today),
/// NOT the on-screen knob's `linear` travel (a separate, hand-declared table
/// this verb cannot reach) — m39-a-2 (whether the KNOB should change) stays
/// open and untouched; the three envelope params additionally carry a `note`
/// saying the knob and the modulation law disagree today. The behavioural
/// pin below constructs a REAL `ModulationSnapshotBuilder.Strip` and checks
/// the render-thread `curveCode` it resolves for `instrumentParam.attack`
/// against what the wire reports — the same "wire equals real behaviour"
/// shape as the m39-f-3 tests, one layer down (DAWEngine, not just
/// DAWControl's own validation).
///
/// ⚠️ Deliberately NOT a `@MainActor` suite — the tree's `@MainActor` suite
/// budget is nearly spent, so isolation rides each test individually (the
/// `PadPreviewCommandTests` shape), never the `@Suite` declaration itself.
@Suite("fx.describe's modulatable verdict + instrument.describeSynth's curve (m39-f-3 / m39-f-2)")
struct DescribeVerdictsCommandTests {

    @MainActor
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addTrack(_ router: CommandRouter, name: String, kind: String) async -> UUID {
        let response = await router.handle(ControlRequest(
            id: "add-\(name)", command: "track.add",
            params: ["name": .string(name), "kind": .string(kind)]))
        return UUID(uuidString: response.result?["id"]?.stringValue ?? "")!
    }

    private func addEffect(_ router: CommandRouter, trackID: UUID, kind: String) async -> UUID {
        let response = await router.handle(ControlRequest(
            id: "fx-add-\(kind)", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string(kind)]))
        return UUID(uuidString: response.result?["effectId"]?.stringValue ?? "")!
    }

    private func addLFOSource(_ router: CommandRouter, trackID: UUID) async -> String {
        let response = await router.handle(ControlRequest(
            id: "mod-add-source", command: "mod.addSource",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("lfo")]))
        return response.result?["sourceId"]?.stringValue ?? ""
    }

    /// A macro, not an LFO — deliberately, for the `yes` test below. An LFO's
    /// default `rateHz` risks tripping the SEPARATE per-quantum-aliasing
    /// warning (`ModulationWarning.targetSteps`'s own sibling, keyed off rate
    /// rather than off `modulatable`), which would make that test's "no
    /// warnings" assertion depend on a rate default it never checked. A macro
    /// has no rate at all, so a 'yes' verdict's warning-free route is proven
    /// by `modulatable` alone.
    private func addMacroSource(_ router: CommandRouter, trackID: UUID) async -> String {
        let response = await router.handle(ControlRequest(
            id: "mod-add-source", command: "mod.addSource",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("macro")]))
        return response.result?["sourceId"]?.stringValue ?? ""
    }

    private func addRoute(_ router: CommandRouter, trackID: UUID, sourceID: String,
                          effectID: UUID, param: String) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "mod-add-route", command: "mod.addRoute",
            params: ["trackId": .string(trackID.uuidString), "sourceId": .string(sourceID),
                     "target": .object(["type": .string("effectParam"),
                                        "effectId": .string(effectID.uuidString),
                                        "param": .string(param)]),
                     "depth": .number(0.5)]))
    }

    private func describeFX(_ router: CommandRouter, kind: String) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "fx-describe", command: "fx.describe", params: ["kind": .string(kind)]))
    }

    // MARK: - The three verdicts, each checked against a REAL mod.addRoute

    @Test("m39-f-3: a YES verdict on the wire matches a real mod.addRoute succeeding cleanly")
    @MainActor
    func yesVerdictMatchesARealRouteSucceeding() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID, kind: "gain")
        let sourceID = await addMacroSource(router, trackID: trackID)

        let described = await describeFX(router, kind: "gain")
        #expect(described.ok)
        let params = try #require(described.result?["kinds"]?.arrayValue?.first?["params"]?.arrayValue)
        let gainLinear = try #require(params.first { $0["name"]?.stringValue == "gainLinear" })
        #expect(gainLinear["modulatable"]?.stringValue == "yes")

        let route = await addRoute(router, trackID: trackID, sourceID: sourceID,
                                   effectID: effectID, param: "gainLinear")
        #expect(route.ok, "the wire said 'yes' for gainLinear — a real mod.addRoute against it must succeed")
        let warnings = route.result?["warnings"]?.arrayValue ?? []
        #expect(warnings.isEmpty, "a 'yes' verdict must not also carry the 'warned' artefact notice")
    }

    @Test("m39-f-3: a REFUSED verdict on the wire matches a real mod.addRoute throwing")
    @MainActor
    func refusedVerdictMatchesARealRouteThrowing() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID, kind: "gain")
        let sourceID = await addLFOSource(router, trackID: trackID)

        let described = await describeFX(router, kind: "gain")
        #expect(described.ok)
        let params = try #require(described.result?["kinds"]?.arrayValue?.first?["params"]?.arrayValue)
        let invertPolarity = try #require(params.first { $0["name"]?.stringValue == "invertPolarity" })
        #expect(invertPolarity["modulatable"]?.stringValue == "refused")

        let route = await addRoute(router, trackID: trackID, sourceID: sourceID,
                                   effectID: effectID, param: "invertPolarity")
        #expect(!route.ok,
                "the wire said 'refused' for invertPolarity — a real mod.addRoute against it must throw")
        #expect(route.error?.contains("discrete") == true,
                "invertPolarity is refused because it is discrete, not for some other reason")
    }

    @Test("m39-f-3: a WARNED verdict on the wire matches a real mod.addRoute's own warning")
    @MainActor
    func warnedVerdictMatchesARealRouteWarning() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Pad", kind: "audio")
        let effectID = await addEffect(router, trackID: trackID, kind: "eq")
        let sourceID = await addLFOSource(router, trackID: trackID)

        let described = await describeFX(router, kind: "eq")
        #expect(described.ok)
        let params = try #require(described.result?["kinds"]?.arrayValue?.first?["params"]?.arrayValue)
        let lowShelfFreq = try #require(params.first { $0["name"]?.stringValue == "lowShelfFreq" })
        #expect(lowShelfFreq["modulatable"]?.stringValue == "warned")

        let route = await addRoute(router, trackID: trackID, sourceID: sourceID,
                                   effectID: effectID, param: "lowShelfFreq")
        #expect(route.ok,
                "'warned' is PERMITTED, not refused — a real mod.addRoute against lowShelfFreq must succeed")
        let warnings = route.result?["warnings"]?.arrayValue ?? []
        #expect(!warnings.isEmpty,
                "'warned' means mod.addRoute's OWN response must carry the artefact notice, not just the wire label")
    }

    // MARK: - Every kind's params carry a legal verdict string

    @Test("m39-f-3: every fx.describe param, every kind, carries a modulatable value from {yes, warned, refused}")
    @MainActor
    func everyParamCarriesALegalVerdict() async throws {
        let (router, _) = makeRouter()
        let described = await router.handle(ControlRequest(id: "1", command: "fx.describe"))
        #expect(described.ok)
        let kinds = try #require(described.result?["kinds"]?.arrayValue)
        #expect(!kinds.isEmpty)
        let legal: Set<String> = ["yes", "warned", "refused"]
        for kind in kinds {
            let kindName = kind["kind"]?.stringValue ?? "?"
            let params = kind["params"]?.arrayValue ?? []
            for param in params {
                let name = param["name"]?.stringValue ?? "?"
                let verdict = param["modulatable"]?.stringValue
                #expect(verdict != nil, "\(kindName).\(name) has no modulatable key on the wire")
                if let verdict {
                    #expect(legal.contains(verdict),
                            "\(kindName).\(name) reports modulatable '\(verdict)', not one of {yes, warned, refused}")
                }
            }
        }
    }

    // MARK: - m39-f-2: instrument.describeSynth's `curve`

    private func describeSynth(_ router: CommandRouter, trackID: UUID) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "instrument-describe-synth", command: "instrument.describeSynth",
            params: ["trackId": .string(trackID.uuidString)]))
    }

    @Test("m39-f-2: cutoffHz reports logarithmic")
    @MainActor
    func cutoffHzReportsLogarithmic() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Synth", kind: "instrument")
        let described = await describeSynth(router, trackID: trackID)
        #expect(described.ok)
        let cutoffHz = try #require(described.result?["parameters"]?.objectValue?["cutoffHz"]?.objectValue)
        #expect(cutoffHz["curve"]?.stringValue == "logarithmic")
    }

    @Test("m39-f-2: attack reports logarithmic AND a note about the on-screen knob disagreeing")
    @MainActor
    func attackReportsLogarithmicWithItsNote() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Synth", kind: "instrument")
        let described = await describeSynth(router, trackID: trackID)
        #expect(described.ok)
        for name in ["attack", "decay", "release"] {
            let param = try #require(described.result?["parameters"]?.objectValue?[name]?.objectValue,
                                     "no parameter object for \(name)")
            #expect(param["curve"]?.stringValue == "logarithmic",
                    "\(name) must report logarithmic — that is what a real mod.addRoute applies today")
            let note = try #require(param["note"]?.stringValue, "\(name) is missing its disagreement note")
            #expect(note.contains("odulation"), "\(name)'s note must say modulation uses this curve")
            #expect(note.lowercased().contains("knob"),
                    "\(name)'s note must mention the on-screen knob, which disagrees today")
        }
        // resonance/gain/sustain are ALSO declared (`.linear`) but do NOT
        // disagree with the knob, so they must NOT carry the envelope note —
        // the note is specific to the three params where the two curves
        // actually disagree, not a blanket addition to every declared param.
        for name in ["resonance", "gain", "sustain"] {
            let param = try #require(described.result?["parameters"]?.objectValue?[name]?.objectValue)
            #expect(param["curve"]?.stringValue == "linear")
            #expect(param["note"] == nil,
                    "\(name) has no curve disagreement — it must not carry the envelope-knob note")
        }
    }

    @Test("m39-f-2: a parameter with no declared ParamCurve has no curve key at all — never a fabricated linear")
    @MainActor
    func undeclaredParamHasNoCurveKey() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Synth", kind: "instrument")
        let described = await describeSynth(router, trackID: trackID)
        #expect(described.ok)
        let parameters = try #require(described.result?["parameters"]?.objectValue)
        #expect(parameters.count == 24, "instrument.describeSynth's own parameter count moved — re-check this list")
        // The 17 m39-g/legacy-discrete params with NO ParamCurve declared
        // anywhere (checked against both InstrumentParamSpec and
        // PolySynthEditorModel.PolySynthParamSpec — neither covers them).
        let undeclared = ["waveform", "pedalHoldLimit", "unisonVoices", "unisonDetuneCents",
                          "unisonStereoSpread", "subLevel", "subOctave", "subWaveform",
                          "noiseLevel", "noiseColor", "drift", "resonanceBoost", "drive",
                          "velocityToCutoff", "keyToCutoff", "voiceJitter", "envelopeCurve"]
        #expect(undeclared.count == 17)
        for name in undeclared {
            let param = try #require(parameters[name]?.objectValue, "no parameter object for \(name)")
            #expect(param["curve"] == nil,
                    "\(name) has no declared ParamCurve — reporting one here would be a fabrication")
        }
    }

    @Test("m39-f-2: the wire's curve for attack equals what ModulationSnapshotBuilder resolves for a REAL route")
    @MainActor
    func attackCurveMatchesTheRealModulationResolution() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Synth", kind: "instrument")
        let described = await describeSynth(router, trackID: trackID)
        #expect(described.ok)
        let wireCurve = try #require(
            described.result?["parameters"]?.objectValue?["attack"]?.objectValue?["curve"]?.stringValue)

        // The exact render-thread resolution a wire `mod.addRoute` against
        // `{type:"instrumentParam", param:"attack"}` on a polySynth track
        // would publish — built directly, at the DAWEngine layer, rather than
        // trusted from the source read in the comment above.
        let source = ModulationSource(kind: .lfo)
        let route = ModulationRoute(sourceID: source.id,
                                    target: .instrumentParam(paramName: "attack"), depth: 0.5)
        let strip = ModulationSnapshotBuilder.Strip(
            sources: [source], routes: [route], effects: [],
            instrument: InstrumentDescriptor(kind: .polySynth), isInstrumentTrack: true,
            baseVolume: 1, basePan: 0)
        let snapshot = try #require(ModulationSnapshotBuilder.build(
            strip: strip, generation: 1, timelineID: 1, sampleRate: 48_000,
            originSample: 0, positionValid: true))
        #expect(snapshot.targets.count == 1)
        let resolvedCurveCode = snapshot.targets[0].curveCode
        let wireCurveCode = wireCurve == "logarithmic" ? ModulationEvaluator.code(for: .logarithmic)
            : wireCurve == "linear" ? ModulationEvaluator.code(for: .linear)
            : ModulationEvaluator.code(for: .decibel)
        #expect(resolvedCurveCode == wireCurveCode, Comment(rawValue:
            "instrument.describeSynth reported '\(wireCurve)' for attack (code \(wireCurveCode)), but "
            + "ModulationSnapshotBuilder resolved code \(resolvedCurveCode) for a REAL route on the same "
            + "parameter — the wire and real behaviour disagree"))
        #expect(resolvedCurveCode == ModulationEvaluator.code(for: .logarithmic))
    }
}
