import DAWCore
import Foundation
import Testing
@testable import DAWControl

/// m34-m: the Copilot's `clip.setControllerLane` description once said built-ins
/// honour only bend + CC 64 and "every other CC affects Audio Unit instruments
/// only" — false for the sampler (CC1/2/11) since m27. The sentence now comes
/// from `MIDIControllerRouting.controllerSupportSummary`, DERIVED from the
/// routing sets. Nothing here retypes a CC list.
@Suite("Controller support summary (m34-m)")
struct ControllerLaneSupportSummaryTests {
    private static var catalogDescription: String {
        CopilotToolCatalog.tool(command: "clip.setControllerLane")?.description ?? ""
    }

    @Test("the catalog description contains the derived summary")
    func catalogEmbedsSummary() {
        #expect(!MIDIControllerRouting.controllerSupportSummary.isEmpty)
        #expect(Self.catalogDescription.contains(MIDIControllerRouting.controllerSupportSummary))
    }

    @Test("the summary names every routed CC and pitch bend")
    func summaryNamesEveryRoutedCC() {
        let summary = MIDIControllerRouting.controllerSupportSummary
        for cc in MIDIControllerRouting.samplerRoutedCCs.union(MIDIControllerRouting.polySynthRoutedCCs) {
            let name = MIDIControllerRouting.describe(.cc(controller: cc))
            #expect(summary.contains(name), "summary does not name \(name)")
        }
        #expect(summary.contains("pitch bend"))
        // The depth-gated CCs are a subset of the sampler's set, so none can be dropped.
        #expect(MIDIControllerRouting.samplerDepthGatedCCs.isSubset(of: MIDIControllerRouting.samplerRoutedCCs))
    }

    @Test("the old false claim is gone from the catalog")
    func oldFalseSentenceIsGone() {
        let text = Self.catalogDescription
        #expect(!text.contains("every other CC affects Audio Unit instruments only"))
        #expect(!text.contains("Built-in instruments honor pitch bend and sustain (CC 64)"))
    }

    // MARK: - DK77: the drum machine and the sampler's parameter-routed controllers

    @Test("the summary names the drum machine and its live parameter count")
    func summaryNamesDrumMachine() {
        let summary = MIDIControllerRouting.controllerSupportSummary
        let count = DrumKitParams.paramSpecs.count
        #expect(MIDIControllerRouting.drumParameterCount == count)
        #expect(summary.contains("drum machine"), "\(summary)")
        #expect(summary.contains("\(count) parameters"), "\(summary)")
        #expect(!summary.contains("75 parameters"))
    }

    @Test("the summary names the sampler's descriptor-dependent controllers")
    func summaryNamesSamplerParameterRouting() {
        let summary = MIDIControllerRouting.controllerSupportSummary
        #expect(summary.contains("brightness-filter controller"), "\(summary)")
        #expect(summary.contains("expressionFilterDepth"), "\(summary)")
        #expect(summary.contains("crossfade controller"), "\(summary)")
    }

    @Test("the drum machine's inert reason carries the live count, never a retyped one")
    func drumInertReasonCarriesLiveCount() {
        let drum = InstrumentDescriptor(kind: .drumSynth)
        let routing = MIDIControllerRouting.routing(for: .cc(controller: 1), instrument: drum)
        guard case .inert(let reason) = routing else {
            Issue.record("the drum machine must be inert for every controller; got \(routing)")
            return
        }
        #expect(reason.contains("\(DrumKitParams.paramSpecs.count) parameters"), "\(reason)")
        #expect(!reason.contains("75 parameters"), "\(reason)")
    }

    @Test("the catalog's instrument descriptions carry the live drum count")
    func catalogDrumCount() {
        let setInstrument = CopilotToolCatalog.tool(command: "track.setInstrument")?.description ?? ""
        #expect(setInstrument.contains("its \(DrumKitParams.paramSpecs.count) parameters"), "\(setInstrument)")
        #expect(!setInstrument.contains("75 parameters"))
        #expect(Self.catalogDescription.contains("\(DrumKitParams.paramSpecs.count) parameters"))
        #expect(!Self.catalogDescription.contains("75 parameters"))
    }

    @Test("the app's no-editor-card error quotes the live count (source read; DAWApp is not importable)")
    func appErrorUsesLiveCount() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let src = try String(contentsOf: url.appendingPathComponent("Sources/DAWApp/ViewUIWireSurface.swift"),
                             encoding: .utf8)
        #expect(src.contains("MIDIControllerRouting.drumParameterCount) parameters are on the wire"))
        #expect(!src.contains("its 75 parameters"))
    }
}
