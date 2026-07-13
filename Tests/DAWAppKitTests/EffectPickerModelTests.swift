import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Unit tests for the headless mixer AU-effect picker model (m13-g, audit F6): the
/// searchable flat list the modal renders, and the `AudioUnitConfig` construction a
/// selection applies. The SwiftUI modal is thin over this, so exercising it here
/// covers the picker's logic without a display OR a store — and pins that the
/// config it builds MATCHES what the wire's `fx.add kind:"audioUnit"` resolves (the
/// `InstrumentPickerModel.choice(for:)` idiom, UI == wire).
@Suite("EffectPickerModel")
@MainActor
struct EffectPickerModelTests {

    // MARK: - Fixtures (AU EFFECTS — type "aufx")

    private static let reverb = AudioUnitComponentInfo(
        component: AudioUnitComponentID(type: "aufx", subType: "rvb2", manufacturer: "appl"),
        name: "AUReverb2", manufacturerName: "Apple", versionString: "1.0", isV3: false)
    private static let delay = AudioUnitComponentInfo(
        component: AudioUnitComponentID(type: "aufx", subType: "dely", manufacturer: "appl"),
        name: "AUDelay", manufacturerName: "Apple", versionString: "1.0", isV3: false)
    private static let fabPro = AudioUnitComponentInfo(
        component: AudioUnitComponentID(type: "aufx", subType: "prq3", manufacturer: "FbFl"),
        name: "Pro-Q 3", manufacturerName: "FabFilter", versionString: "3.2", isV3: true)

    private static let all = [fabPro, reverb, delay]

    private static func makeModel() -> EffectPickerModel {
        let model = EffectPickerModel(audioUnits: { all })
        model.prepare(trackID: UUID())
        return model
    }

    // MARK: - List + search

    @Test("prepare loads the AU list, sorted by name")
    func prepareLoadsSorted() {
        let model = Self.makeModel()
        #expect(model.audioUnits.count == 3)
        // AUDelay, AUReverb2, Pro-Q 3 — case-insensitive name order.
        #expect(model.filteredAudioUnits.map(\.name) == ["AUDelay", "AUReverb2", "Pro-Q 3"])
    }

    @Test("search filters by name")
    func searchByName() {
        let model = Self.makeModel()
        model.searchText = "reverb"
        #expect(model.filteredAudioUnits.map(\.name) == ["AUReverb2"])
    }

    @Test("search matches the manufacturer too")
    func searchByMaker() {
        let model = Self.makeModel()
        model.searchText = "fabfilter"
        #expect(model.filteredAudioUnits.map(\.name) == ["Pro-Q 3"])
    }

    @Test("empty / whitespace search matches everything")
    func emptySearch() {
        let model = Self.makeModel()
        model.searchText = "   "
        #expect(model.filteredAudioUnits.count == 3)
    }

    @Test("no match yields an empty list (the honest 'none match' state)")
    func noMatch() {
        let model = Self.makeModel()
        model.searchText = "zzz-nope"
        #expect(model.filteredAudioUnits.isEmpty)
    }

    @Test("prepare points the picker at the target track and resets search")
    func prepareResets() {
        let model = Self.makeModel()
        model.searchText = "reverb"
        let track = UUID()
        model.prepare(trackID: track)
        #expect(model.targetTrackID == track)
        #expect(model.searchText.isEmpty)
    }

    // MARK: - Config construction (UI == wire)

    @Test("config carries the component triple + captured display facts, no state")
    func configFields() {
        let model = Self.makeModel()
        let config = model.config(for: Self.fabPro)
        #expect(config.component == Self.fabPro.component)
        #expect(config.name == "Pro-Q 3")
        #expect(config.manufacturerName == "FabFilter")
        #expect(config.stateData == nil)   // a freshly-added insert has no saved state
    }

    @Test("config identity matches the wire's fx.add resolution (component is the key)")
    func matchesWireResolution() {
        // The wire builds an AudioUnitConfig from the SAME installed component (see
        // Commands.parseAudioUnit → AudioUnitConfig(component:…)). Component identity
        // is the equality key the store and a snapshot compare on — so the UI's
        // config and the wire's config address the identical effect.
        let model = Self.makeModel()
        let ui = model.config(for: Self.reverb)
        let wireEquivalent = AudioUnitConfig(
            component: Self.reverb.component, name: Self.reverb.name,
            manufacturerName: Self.reverb.manufacturerName)
        #expect(ui == wireEquivalent)
        #expect(ui.component.type == "aufx")   // an EFFECT component, not "aumu"
    }
}
