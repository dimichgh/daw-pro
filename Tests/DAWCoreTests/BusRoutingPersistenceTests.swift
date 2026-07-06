import Foundation
import Testing
@testable import DAWCore

/// Persistence coverage for M4 (i) routing: `.dawproj` round trip, byte-identity
/// for pre-routing projects (no `sends`/`outputBusId` keys), and load-time
/// sanitization of dangling references with exact warning strings.
@MainActor
@Suite("Bus routing & sends — persistence")
struct BusRoutingPersistenceTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawproj-routing-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("output routing and sends survive a save/open round trip")
    func routingRoundTripsThroughDawproj() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let busA = store.addTrack(name: "Reverb", kind: .bus)
        let busB = store.addTrack(name: "Delay", kind: .bus)
        let source = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTrackOutput(id: source.id, busID: busA.id)
        let send = try store.addSend(toTrack: source.id, busID: busB.id, level: 0.5)

        let path = dir.appendingPathComponent("Routed").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let reTrack = try #require(reopened.tracks.first(where: { $0.name == "Gtr" }))
        #expect(reTrack.outputBusID == busA.id)
        #expect(reTrack.sends.count == 1)
        #expect(reTrack.sends[0].id == send.id)
        #expect(reTrack.sends[0].destinationBusID == busB.id)
        #expect(reTrack.sends[0].level == 0.5)
    }

    @Test("a project with no routing carries no sends/outputBusId keys")
    func preRoutingProjectStaysByteIdentical() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.addTrack(name: "Gtr", kind: .audio)          // default routing (master, no sends)
        let path = dir.appendingPathComponent("Plain").path
        try store.saveProject(to: path)

        let jsonURL = URL(fileURLWithPath: store.projectPath!)
            .appendingPathComponent("project.json")
        let json = try String(contentsOf: jsonURL, encoding: .utf8)
        #expect(!json.contains("sends"))
        #expect(!json.contains("outputBusId"))
    }

    @Test("load drops dangling routes and strips bus routing, each with a warning")
    func loadDropsDanglingRoutesWithWarnings() throws {
        let dir = tempDir()
        let realBus = Track(name: "Reverb", kind: .bus)
        let ghostBusID = UUID()
        let validSend = Send(destinationBusID: realBus.id, level: 0.7)
        let ghostSend = Send(destinationBusID: ghostBusID, level: 0.5)
        // Source track routed to a bus that doesn't exist, with one valid and one
        // dangling send.
        let routed = Track(name: "Gtr", kind: .audio,
                           outputBusID: ghostBusID, sends: [validSend, ghostSend])
        // A bus carrying illegal routing fields (buses output to master, no sends).
        let dirtyBus = Track(name: "SubBus", kind: .bus,
                             outputBusID: realBus.id, sends: [Send(destinationBusID: realBus.id)])

        let document = ProjectDocument(
            name: "Dangling", transport: TransportState(),
            tracks: [realBus, routed, dirtyBus], masterVolume: 1, mediaRefs: [:]
        )
        let bundleURL = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Dangling").path)
        try ProjectBundle.write(
            document: document,
            plan: ProjectBundle.MediaPlan(copies: [], refs: [:], warnings: []),
            to: bundleURL
        )

        let store = ProjectStore()
        let warnings = try store.openProject(at: bundleURL.path)

        let gtr = try #require(store.tracks.first(where: { $0.name == "Gtr" }))
        #expect(gtr.outputBusID == nil)                              // dangling output → master
        #expect(gtr.sends.count == 1)                               // ghost send dropped
        #expect(gtr.sends[0].destinationBusID == realBus.id)
        #expect(warnings.contains("unknown output bus for track 'Gtr' — routed to master"))
        #expect(warnings.contains("unknown send bus for track 'Gtr' — send dropped"))

        let sub = try #require(store.tracks.first(where: { $0.name == "SubBus" }))
        #expect(sub.outputBusID == nil)                             // bus routing stripped
        #expect(sub.sends.isEmpty)
        #expect(warnings.contains("routing fields on bus track 'SubBus' — stripped (buses output to master in v0)"))
    }
}
