import DAWCore
import Foundation
import Testing
@testable import DAWControl

/// m39-dm — the drum machine's wire surface: `track.setInstrument`'s `drumKit`
/// payload plus the four new verbs.
///
/// ⛔ The refusal rows matter as much as the success rows. A setting that is
/// accepted, stored, echoed back and silent is this tree's characteristic
/// failure, so every one of these verbs either does what it said or says why
/// not — and `describeDrumKit` reports the settings that are stored-but-inert
/// rather than leaving a caller to discover them in a loudness measurement.
@MainActor
@Suite("Drum machine — control verbs", .serialized)
struct DrumKitCommandTests {

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        return (CommandRouter(store: store), store)
    }

    private func drumTrack(_ router: CommandRouter, _ store: ProjectStore) throws -> UUID {
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try store.setInstrument(id: id, kind: .drumSynth)
        return id
    }

    private func call(_ router: CommandRouter, _ verb: String,
                      _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: verb, params: params))
    }

    private func payload(_ response: ControlResponse) throws -> JSONValue {
        guard response.ok, let result = response.result else {
            Issue.record(Comment(rawValue: "expected success, got \(response.error ?? "nil")"))
            throw CancellationError()
        }
        return result
    }

    private func errorText(_ response: ControlResponse) -> String? {
        response.ok ? nil : response.error
    }

    // MARK: - Registration

    @Test("All four drum verbs are registered")
    func verbsAreRegistered() {
        for verb in ["instrument.setDrumParam", "instrument.describeDrumKit",
                     "instrument.listDrumPresets", "instrument.loadDrumPreset"] {
            #expect(CommandRouter.allCommands.contains(verb), "\(verb) is not registered")
        }
    }

    /// ⛔ THE COPILOT'S `kind` LIST IS HAND-WRITTEN AND THE COMPILER CANNOT SEE
    /// IT. A kind missing there is unselectable by the in-app AI while working
    /// perfectly everywhere else. Pinned against `Kind.allCases` so the NEXT
    /// kind cannot repeat it — this list was found stale once already.
    @Test("The copilot catalog offers every instrument kind")
    func copilotCatalogCoversEveryKind() throws {
        let tool = try #require(CopilotToolCatalog.tool(command: "track.setInstrument"))
        let kindSchema = try #require(tool.schema["properties"]?["kind"])
        let values = try #require(kindSchema["enum"]?.arrayValue)
        let offered = Set(values.compactMap { $0.stringValue })
        let all = Set(InstrumentDescriptor.Kind.allCases.map(\.rawValue))
        #expect(offered == all,
                Comment(rawValue: "copilot offers \(offered.sorted()) but the model has "
                    + "\(all.sorted())"))
    }

    // MARK: - setInstrument's drumKit payload

    @Test("setInstrument accepts drumSynth and a partial drumKit overlay")
    func setInstrumentTakesADrumKit() async throws {
        let (router, store) = makeRouter()
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        let selected = await call(router, "track.setInstrument", [
            "trackId": .string(id.uuidString), "kind": .string("drumSynth"),
        ])
        _ = try payload(selected)
        #expect(store.tracks.first { $0.id == id }?.instrument?.kind == .drumSynth)

        // A PARTIAL object must overlay, never reset the other 74.
        _ = await call(router, "track.setInstrument", [
            "trackId": .string(id.uuidString),
            "drumKit": .object(["kick": .object(["decay": .number(1.1)])]),
        ])
        let kit = try #require(store.tracks.first { $0.id == id }?.instrument?.drumKit)
        #expect(kit.kick.decay == 1.1)
        var expected = DrumKitParams()
        expected.setValue(1.1, forParamName: "kick.decay")
        #expect(kit == expected, "a partial drumKit object reset parameters it never mentioned")
    }

    @Test("A drumKit payload round-trips through the response echo")
    func drumKitEchoesBack() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        let response = try payload(await call(router, "track.setInstrument", [
            "trackId": .string(id.uuidString),
            "drumKit": .object([
                "snare": .object(["tune": .number(210), "snap": .number(0.8)]),
                "velocityToTone": .number(0.7),
            ]),
        ]))
        let kit = try #require(response["drumKit"])
        #expect(kit["snare"]?["tune"]?.doubleValue == 210)
        #expect(kit["snare"]?["snap"]?.doubleValue == 0.8)
        #expect(kit["velocityToTone"]?.doubleValue == 0.7)
        // The derived trigger note is emitted so a caller knows what to play.
        #expect(kit["snare"]?["note"]?.doubleValue == Double(DrumVoice.snare.note))
    }

    /// The additive-optional contract: a project that never touched the drum
    /// machine must not grow a `drumKit` key.
    @Test("A non-drum track's instrument echo carries no drumKit key")
    func nonDrumEchoHasNoDrumKit() async throws {
        let (router, store) = makeRouter()
        let id = store.addTrack(name: "Synth", kind: .instrument).id
        let response = try payload(await call(router, "track.setInstrument", [
            "trackId": .string(id.uuidString), "cutoffHz": .number(2000),
        ]))
        #expect(response["drumKit"] == nil)
    }

    @Test("A bad drum name in a drumKit payload is refused and changes nothing")
    func badDrumKitNameIsRefused() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        _ = await call(router, "track.setInstrument", [
            "trackId": .string(id.uuidString),
            "drumKit": .object(["kick": .object(["decay": .number(1.1)])]),
        ])
        let before = store.tracks.first { $0.id == id }?.instrument?.drumKit

        let response = await call(router, "track.setInstrument", [
            "trackId": .string(id.uuidString),
            "drumKit": .object(["kick": .object(["boom": .number(1)])]),
        ])
        let message = try #require(errorText(response))
        #expect(message.contains("kick.boom"))
        // ⭐ It NAMES the valid set rather than only saying "unknown".
        #expect(message.contains("kick.decay"), "the refusal did not list valid names")
        #expect(store.tracks.first { $0.id == id }?.instrument?.drumKit == before,
                "a refused payload still mutated the kit")
    }

    // MARK: - setDrumParam

    @Test("setDrumParam sets one name and echoes the STORED value")
    func setDrumParamWorks() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        let response = try payload(await call(router, "instrument.setDrumParam", [
            "trackId": .string(id.uuidString),
            "name": .string("openHat.decay"), "value": .number(0.9),
        ]))
        #expect(response["value"]?.doubleValue == 0.9)
        #expect(response["name"]?.stringValue == "openHat.decay")
        #expect(response["isActiveInstrument"]?.boolValue == true)
        #expect(store.tracks.first { $0.id == id }?.instrument?.drumKit?.openHat.decay == 0.9)
    }

    /// ⭐ THE ECHO IS THE STORED VALUE, NOT THE REQUEST. They differ whenever a
    /// clamp bit, and echoing the request back would hide the clamp entirely —
    /// a caller would believe it had set 100 000 Hz.
    @Test("setDrumParam reports the clamped value and the requested one separately")
    func setDrumParamReportsClamping() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        let response = try payload(await call(router, "instrument.setDrumParam", [
            "trackId": .string(id.uuidString),
            "name": .string("kick.tune"), "value": .number(100_000),
        ]))
        #expect(response["value"]?.doubleValue == DrumKitParams.kickTuneRange.upperBound)
        #expect(response["requested"]?.doubleValue == 100_000)
    }

    @Test("setDrumParam refuses an unknown name with the valid list")
    func setDrumParamRefusesTypos() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        let typo = await call(router, "instrument.setDrumParam", [
            "trackId": .string(id.uuidString),
            "name": .string("kik.tune"), "value": .number(60),
        ])
        let message = try #require(errorText(typo))
        #expect(message.contains("kik.tune"))
        #expect(message.contains("kick"), "the refusal did not name the valid scopes")

        // A valid scope with a bad leaf lists that scope's names.
        let badLeaf = await call(router, "instrument.setDrumParam", [
            "trackId": .string(id.uuidString),
            "name": .string("kick.wobble"), "value": .number(1),
        ])
        #expect(try #require(errorText(badLeaf)).contains("kick.pitchAmount"))
    }

    /// NaN survives every clamp, and several of these values become sample
    /// counts on the render thread where `Int(nan)` TRAPS.
    @Test("setDrumParam refuses a non-finite value")
    func setDrumParamRefusesNonFinite() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        let response = await call(router, "instrument.setDrumParam", [
            "trackId": .string(id.uuidString),
            "name": .string("kick.decay"), "value": .number(Double.nan),
        ])
        #expect(errorText(response) != nil)
    }

    @Test("setDrumParam refuses an audio track and an unknown id")
    func setDrumParamRefusesWrongTracks() async throws {
        let (router, store) = makeRouter()
        let audio = store.addTrack(name: "Audio", kind: .audio).id
        #expect(errorText(await call(router, "instrument.setDrumParam", [
            "trackId": .string(audio.uuidString),
            "name": .string("kick.decay"), "value": .number(0.5),
        ])) != nil)
        #expect(errorText(await call(router, "instrument.setDrumParam", [
            "trackId": .string(UUID().uuidString),
            "name": .string("kick.decay"), "value": .number(0.5),
        ])) != nil)
    }

    // MARK: - describeDrumKit

    @Test("describeDrumKit reports all 75 names with their schema")
    func describeDrumKitIsComplete() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        let response = try payload(await call(router, "instrument.describeDrumKit", [
            "trackId": .string(id.uuidString),
        ]))
        #expect(response["parameterCount"]?.doubleValue == 75)
        #expect(response["isActiveInstrument"]?.boolValue == true)
        let order = try #require(response["order"]?.arrayValue)
        #expect(order.count == 75)
        #expect(Set(order.compactMap(\.stringValue))
            == Set(DrumKitParams.paramSpecs.map(\.name)))

        let kick = try #require(response["voices"]?["kick"])
        let decay = try #require(kick["parameters"]?["decay"])
        #expect(decay["min"]?.doubleValue == DrumKitParams.kickDecayRange.lowerBound)
        #expect(decay["max"]?.doubleValue == DrumKitParams.kickDecayRange.upperBound)
        #expect(decay["default"]?.doubleValue == DrumKitParams.kickDefault.decay)
        #expect(decay["modulatable"]?.boolValue == true)
        #expect(decay["appliesAtNextNoteOn"]?.boolValue == true)
        #expect(decay["meaning"]?.stringValue?.isEmpty == false)
        #expect(kick["note"]?.doubleValue == 36)

        // level and pan are the two that move a SOUNDING voice.
        #expect(kick["parameters"]?["level"]?["appliesAtNextNoteOn"]?.boolValue == false)
        #expect(kick["parameters"]?["pan"]?["appliesAtNextNoteOn"]?.boolValue == false)

        // ⭐ The 64-route ceiling, visible before it bites.
        #expect(response["routeBudget"]?.doubleValue == Double(ModulationLimits.maxRoutes))
        #expect(response["routesUsed"]?.doubleValue == 0)
        #expect(response["parameterCount"]?.doubleValue ?? 0
            > response["routeBudget"]?.doubleValue ?? 0,
                "the ceiling is only worth reporting because 75 > 64")
    }

    /// The kit is carried across kind switches, so a track can hold a dialled
    /// kit while playing something else. The verb answers either way.
    @Test("describeDrumKit answers for a track playing another instrument")
    func describeDrumKitOnANonDrumTrack() async throws {
        let (router, store) = makeRouter()
        let id = store.addTrack(name: "Synth", kind: .instrument).id
        let response = try payload(await call(router, "instrument.describeDrumKit", [
            "trackId": .string(id.uuidString),
        ]))
        #expect(response["isActiveInstrument"]?.boolValue == false)
        #expect(response["isConfigured"]?.boolValue == false)
        #expect(response["parameterCount"]?.doubleValue == 75)
    }

    /// ⛔ THE GATED SETTINGS. Each is accepted, stored, echoed back and SILENT.
    @Test("describeDrumKit warns about settings that are stored but inert")
    func describeDrumKitWarnsAboutGatedSettings() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        _ = try store.setInstrument(id: id,
                                    drumParam: (name: "kick.pitchAmount", value: 0))
        _ = try store.setInstrument(id: id,
                                    drumParam: (name: "kit.velocityToTone", value: 0))
        let response = try payload(await call(router, "instrument.describeDrumKit", [
            "trackId": .string(id.uuidString),
        ]))
        let warnings = try #require(response["warnings"]?.arrayValue)
        let text = warnings.compactMap(\.stringValue).joined(separator: " | ")
        #expect(text.contains("kick.pitchDecay"),
                "no warning that pitchDecay is inert at pitchAmount 0")
        #expect(text.contains("kit.velocityToTone"),
                "no warning that velocity moves level only")

        // The control: a default kit warns about NONE of these.
        let clean = store.addTrack(name: "Clean", kind: .instrument).id
        _ = try store.setInstrument(id: clean, kind: .drumSynth)
        let cleanResponse = try payload(await call(router, "instrument.describeDrumKit", [
            "trackId": .string(clean.uuidString),
        ]))
        let cleanWarnings = try #require(cleanResponse["warnings"]?.arrayValue)
        #expect(cleanWarnings.isEmpty,
                Comment(rawValue: "a factory kit warned about "
                    + "\(cleanWarnings.compactMap(\.stringValue))"))
    }

    // MARK: - Presets

    @Test("listDrumPresets names the five factory kits with summaries")
    func listDrumPresets() async throws {
        let (router, _) = makeRouter()
        let response = try payload(await call(router, "instrument.listDrumPresets"))
        let presets = try #require(response["presets"]?.arrayValue)
        #expect(presets.count == 5)
        #expect(response["count"]?.doubleValue == 5)
        var names: [String] = []
        for entry in presets {
            names.append(entry["name"]?.stringValue ?? "")
            #expect(entry["summary"]?.stringValue?.isEmpty == false)
        }
        #expect(Set(names) == ["808", "909", "acoustic", "lofi", "trap"])
    }

    @Test("loadDrumPreset replaces the whole kit and says so")
    func loadDrumPreset() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        _ = try store.setInstrument(id: id, drumParam: (name: "kick.decay", value: 2.5))

        let response = try payload(await call(router, "instrument.loadDrumPreset", [
            "trackId": .string(id.uuidString), "name": .string("909"),
        ]))
        #expect(response["name"]?.stringValue == "909")
        #expect(response["replacedAllParameters"]?.boolValue == true)
        #expect(response["parameterCount"]?.doubleValue == 75)
        let nine = try #require(DrumKitParams.preset(named: "909")).params
        #expect(store.tracks.first { $0.id == id }?.instrument?.drumKit == nine)
        // The edit that was NOT asked to survive did not.
        #expect(store.tracks.first { $0.id == id }?.instrument?.drumKit?.kick.decay
            == nine.kick.decay)
    }

    @Test("loadDrumPreset is case-insensitive and refuses an unknown name")
    func loadDrumPresetRefusals() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        _ = try payload(await call(router, "instrument.loadDrumPreset", [
            "trackId": .string(id.uuidString), "name": .string("LOFI"),
        ]))
        #expect(store.tracks.first { $0.id == id }?.instrument?.drumKit
            == DrumKitParams.preset(named: "lofi")?.params)

        let message = try #require(errorText(await call(router, "instrument.loadDrumPreset", [
            "trackId": .string(id.uuidString), "name": .string("nope"),
        ])))
        #expect(message.contains("808"), "the refusal did not list the valid presets")
    }

    @Test("Every drum verb rejects unknown keys")
    func verbsRejectUnknownKeys() async throws {
        let (router, store) = makeRouter()
        let id = try drumTrack(router, store)
        #expect(errorText(await call(router, "instrument.describeDrumKit", [
            "trackId": .string(id.uuidString), "bogus": .number(1),
        ])) != nil)
        #expect(errorText(await call(router, "instrument.listDrumPresets", [
            "bogus": .number(1),
        ])) != nil)
        #expect(errorText(await call(router, "instrument.setDrumParam", [
            "trackId": .string(id.uuidString), "name": .string("kick.decay"),
            "value": .number(0.5), "bogus": .number(1),
        ])) != nil)
    }
}
