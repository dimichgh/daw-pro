import DAWCore
import Foundation
import Testing

/// m39-dm — the STORE half: the `setInstrument` overlay, and the four sites
/// whose failure mode is a success response.
///
/// ⛔⛔ `unrelatedKnobEditDoesNotDestroyTheKit` WAS WRITTEN BEFORE THE OVERLAY
/// EXISTED AND WATCHED TO FAIL. That is the house rule this whole file follows
/// (`ProjectStore.swift` records that `richnessSurvivesAnUnrelatedKnobEdit` was
/// written first and that all fifteen of its fields reddened, with the
/// `cutoffHz` control passing). A test authored against finished code can only
/// agree with it; a test watched to fail has proved it can.
@MainActor
@Suite("Drum kit — store overlay and data-loss guards")
struct DrumKitStoreTests {

    private func store() -> ProjectStore {
        ProjectStore()
    }

    private func drumTrack(in store: ProjectStore) throws -> UUID {
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try store.setInstrument(id: id, kind: .drumSynth)
        return id
    }

    private func kit(of store: ProjectStore, _ id: UUID) -> DrumKitParams? {
        store.tracks.first { $0.id == id }?.instrument?.drumKit
    }

    /// A kit with every one of the 75 names moved off its default.
    private func dialledKit() -> DrumKitParams {
        var kit = DrumKitParams()
        for spec in DrumKitParams.paramSpecs {
            let lo = spec.range.lowerBound, hi = spec.range.upperBound
            var target = lo + (hi - lo) * 0.41
            if abs(target - spec.defaultValue) < 1e-9 { target = lo + (hi - lo) * 0.67 }
            kit.setValue(target, forParamName: spec.name)
        }
        kit.rim.chokeGroup = 9
        return kit
    }

    // MARK: - The Class B4 catch

    /// ⛔⛔ THE DATA-LOSS GUARD. `setInstrument`'s rebuild is an EXPLICIT
    /// initialiser call, so a payload the rebuild does not name does not
    /// "inherit" the current value — it takes the descriptor's own nil default,
    /// ON EVERY CALL, and the method returns success. A user brightens the
    /// synth filter and their entire drum kit is gone, with an OK response.
    /// That is m33-j's shape exactly (`clip.addAudio` deleted the clips it
    /// overlapped and answered OK).
    ///
    /// WHOLE-STRUCT equality, never field-by-field: field-by-field is what lets
    /// the 76th parameter go missing unnoticed.
    @Test("An unrelated knob edit leaves the drum kit whole-struct identical")
    func unrelatedKnobEditDoesNotDestroyTheKit() throws {
        let store = store()
        let id = try drumTrack(in: store)
        let dialled = dialledKit()
        _ = try store.setInstrument(id: id, drumKit: dialled)
        let stored = try #require(kit(of: store, id))
        #expect(stored == dialled, "the kit did not even land")

        // An edit that has nothing to do with drums.
        _ = try store.setInstrument(id: id, cutoffHz: 3000)
        let after = try #require(kit(of: store, id))
        #expect(after == dialled, "an unrelated knob edit destroyed the drum kit")

        // The control, mirroring `richnessSurvivesAnUnrelatedKnobEdit`'s own:
        // the edit that WAS asked for did take.
        #expect(store.tracks.first { $0.id == id }?.instrument?.polySynth.cutoffHz == 3000)

        // And a second unrelated edit, of a different shape.
        _ = try store.setInstrument(id: id, sampler: SamplerParams(zones: []))
        let after2 = try #require(kit(of: store, id))
        #expect(after2 == dialled, "a sampler edit destroyed the drum kit")
    }

    @Test("Setting the kit wholesale replaces it; omitting it keeps the current one")
    func wholesaleReplaceAndKeep() throws {
        let store = store()
        let id = try drumTrack(in: store)
        let dialled = dialledKit()
        _ = try store.setInstrument(id: id, drumKit: dialled)
        _ = try store.setInstrument(id: id)  // omitted → keep
        #expect(kit(of: store, id) == dialled)

        let nine = try #require(DrumKitParams.preset(named: "909")).params
        _ = try store.setInstrument(id: id, drumKit: nine)
        #expect(kit(of: store, id) == nine)
    }

    // MARK: - The name-addressed setter

    @Test("A single named parameter overlays without disturbing the other 74")
    func singleParamOverlay() throws {
        let store = store()
        let id = try drumTrack(in: store)
        let dialled = dialledKit()
        _ = try store.setInstrument(id: id, drumKit: dialled)

        _ = try store.setInstrument(id: id, drumParam: (name: "kick.decay", value: 1.25))
        let after = try #require(kit(of: store, id))
        #expect(after.kick.decay == 1.25)

        var expected = dialled
        expected.setValue(1.25, forParamName: "kick.decay")
        #expect(after == expected, "setting one name moved something else")
    }

    @Test("A named parameter clamps to its spec range and an unknown name is inert")
    func singleParamClampsAndRefuses() throws {
        let store = store()
        let id = try drumTrack(in: store)
        _ = try store.setInstrument(id: id, drumParam: (name: "kick.tune", value: 100_000))
        #expect(kit(of: store, id)?.kick.tune == DrumKitParams.kickTuneRange.upperBound)

        let before = kit(of: store, id)
        _ = try store.setInstrument(id: id, drumParam: (name: "kik.tune", value: 60))
        #expect(kit(of: store, id) == before, "an unknown name changed the kit")
    }

    // ⚠️ The "a kit edit is legal on a routed strip MID-TAKE" assertion lives in
    // `RecordingStoreTests.setInstrumentConditional`'s file instead, because the
    // rolling-transport harness (`FakeRecordingEngine` + `rolling`) lives there
    // and duplicating it here would give this project two of them.

    // MARK: - Persistence through a real bundle (the Class B7 catch)

    /// ⛔ `InstrumentDocument.CodingKeys` is HAND-WRITTEN. A missing key means
    /// the kit is never written and never read, with no compile error, no
    /// runtime error and no warning — and every in-memory test still passes.
    /// Only a real save/open catches it.
    @Test("All 75 names survive a save and reopen through a project bundle")
    func kitSurvivesASaveAndReopen() throws {
        let store = store()
        let id = try drumTrack(in: store)
        let dialled = dialledKit()
        _ = try store.setInstrument(id: id, drumKit: dialled)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("m39dm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try store.saveProject(
            to: directory.appendingPathComponent("kit").path)
        let reopened = ProjectStore()
        _ = try reopened.openProject(at: result.path)
        let loaded = try #require(
            reopened.tracks.first { $0.name == "Drums" }?.instrument)
        #expect(loaded.kind == .drumSynth)
        #expect(loaded.drumKit == dialled, "the kit did not survive the bundle round trip")
    }

    /// The other half of the two-guard rule at the DOCUMENT level: a project
    /// that never carried a `drumKit` key must open with nil, and nil must read
    /// as the factory kit rather than as silence.
    @Test("An instrument document with no drumKit key decodes to nil and plays the factory kit")
    func absentDrumKitKeyDecodesToNil() throws {
        let json = #"{"kind":"polySynth"}"#
        let document = try JSONDecoder().decode(InstrumentDocument.self,
                                                from: Data(json.utf8))
        #expect(document.drumKit == nil)

        let descriptor = InstrumentDescriptor(kind: .drumSynth)
        #expect(descriptor.drumKit == nil)
        #expect(descriptor.resolvedDrumKit == DrumKitParams(),
                "a nil kit must resolve to the FACTORY kit, not to an empty one")

        // Control: a document WITH the key decodes it.
        var dialled = DrumKitParams()
        dialled.setValue(0.9, forParamName: "kick.decay")
        let withKit = #"{"kind":"drumSynth","drumKit":"#
            + String(decoding: try JSONEncoder().encode(dialled), as: UTF8.self) + "}"
        let back = try JSONDecoder().decode(InstrumentDocument.self,
                                            from: Data(withKit.utf8))
        #expect(back.drumKit == dialled)
        #expect(back.kind == .drumSynth)
    }

    /// A project that never touched the drum machine must stay byte-identical
    /// across a round trip — the additive-optional contract.
    @Test("A non-drum instrument document is byte-identical across a round trip")
    func nonDrumDocumentStaysByteIdentical() throws {
        let json = #"{"kind":"polySynth"}"#
        let document = try JSONDecoder().decode(InstrumentDocument.self,
                                                from: Data(json.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(document)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("drumKit") == false,
                "a poly-synth save now carries a drumKit key it never had")
        let back = try JSONDecoder().decode(InstrumentDocument.self, from: bytes)
        #expect(try encoder.encode(back) == bytes)
    }

    // MARK: - Modulation surface

    /// The generic route validator is UNCHANGED by this item — it resolves
    /// purely through `InstrumentParamSpec`. This asserts the ONE HOME actually
    /// paid out rather than assuming it.
    @Test("Every one of the 75 names validates as a modulation target")
    func everyNameIsAValidModulationTarget() throws {
        let store = store()
        let id = try drumTrack(in: store)
        let lfo = try store.addModulationSource(on: .track(id), kind: .lfo).source
        // ⚠️ `ModulationLimits.maxRoutes` is 64 and this instrument has 75
        // names, so they CANNOT all be routed at once. Each is added and then
        // removed: this row asserts VALIDATION of every name, not capacity.
        // The ceiling itself is real and `describeDrumKit` reports it.
        for spec in DrumKitParams.paramSpecs {
            let route = try store.addModulationRoute(
                on: .track(id), sourceID: lfo.id,
                target: .instrumentParam(paramName: spec.name), depth: 0.5).route
            _ = try store.removeModulationRoute(on: .track(id), routeID: route.id)
        }
        #expect(DrumKitParams.paramSpecs.count > ModulationLimits.maxRoutes)
    }

    @Test("A typo is refused with the valid-name list, not silently accepted")
    func typoIsRefusedWithNames() throws {
        let store = store()
        let id = try drumTrack(in: store)
        let lfo = try store.addModulationSource(on: .track(id), kind: .lfo).source
        #expect(throws: (any Error).self) {
            _ = try store.addModulationRoute(
                on: .track(id), sourceID: lfo.id,
                target: .instrumentParam(paramName: "kik.tune"), depth: 0.5)
        }
    }

    /// ⭐ The first instrument with NO discrete parameters — so no
    /// `modulationTargetUnsupported(.discrete)` refusal exists for it.
    @Test("The drum machine has no discrete parameters and is not hosted")
    func noDiscreteParamsAndNotHosted() {
        #expect(InstrumentParamSpec.discreteParamNames(for: .drumSynth).isEmpty)
        #expect(InstrumentParamSpec.isHosted(.drumSynth) == false)
        #expect(InstrumentParamSpec.specs(for: .drumSynth).count == 75)
        #expect(InstrumentParamSpec.specs(for: .drumSynth).allSatisfy {
            $0.modulatable == .yes
        })
    }

    /// ⛔ Without a `.drumSynth` branch in `currentValue(of:in:)` every drum
    /// route would modulate around the DEFAULT rather than around the value the
    /// user set — audible, wrong, and nothing fails.
    @Test("A route's base value is the user's value, not the default")
    func modulationBaseIsTheUsersValue() throws {
        var kit = DrumKitParams()
        kit.setValue(40, forParamName: "kick.tune")
        let descriptor = InstrumentDescriptor(kind: .drumSynth, drumKit: kit)
        #expect(InstrumentParamSpec.currentValue(of: "kick.tune", in: descriptor) == 40)
        #expect(InstrumentParamSpec.currentValue(of: "kick.tune",
                                                 in: InstrumentDescriptor(kind: .drumSynth))
            == DrumKitParams.kickDefault.tune)
        #expect(InstrumentParamSpec.currentValue(of: "nope", in: descriptor) == nil)
        // The polySynth path is unmoved.
        #expect(InstrumentParamSpec.currentValue(
            of: "cutoffHz", in: InstrumentDescriptor(kind: .polySynth))
            == PolySynthParams().cutoffHz)
    }

    /// `valueRange(in:)` resolves any instrument param by name through the same
    /// table — another site the design says needs zero changes. Asserted, not
    /// assumed.
    @Test("valueRange resolves drum names through the same table")
    func valueRangeResolvesDrumNames() throws {
        let store = store()
        let id = try drumTrack(in: store)
        let track = try #require(store.tracks.first { $0.id == id })
        for spec in DrumKitParams.paramSpecs {
            let range = AutomationTarget.instrumentParam(paramName: spec.name)
                .valueRange(in: track)
            #expect(range == spec.range, "\(spec.name) resolved to \(String(describing: range))")
        }
        #expect(AutomationTarget.instrumentParam(paramName: "kik.tune")
            .valueRange(in: track) == nil)
    }
}
