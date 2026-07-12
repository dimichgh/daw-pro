import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Wire coverage for the five `marker.*` commands (m11-c) and the additive
/// `transport.seek {marker}` interop — the round-trip result shapes, field-named
/// validation/errors, and the seek-by-id / seek-by-name / ambiguous / unknown /
/// both-given paths.
@MainActor
@Suite("Marker commands (m11-c)")
struct MarkerCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addMarker(_ router: CommandRouter, name: String?, beat: Double) async -> String {
        var params: [String: JSONValue] = ["beat": .number(beat)]
        if let name { params["name"] = .string(name) }
        let r = await router.handle(ControlRequest(id: "add", command: "marker.add", params: params))
        return r.result?["id"]?.stringValue ?? ""
    }

    // MARK: - add / list

    @Test("marker.add returns the created marker and lands it in the store")
    func addReturnsMarker() async {
        let (router, store) = makeRouter()
        let r = await router.handle(ControlRequest(
            id: "1", command: "marker.add", params: ["name": .string("Chorus"), "beat": .number(16)]))
        #expect(r.ok)
        #expect(r.result?["name"]?.stringValue == "Chorus")
        #expect(r.result?["beat"]?.doubleValue == 16)
        #expect(UUID(uuidString: r.result?["id"]?.stringValue ?? "") != nil)
        #expect(store.markers.count == 1)
    }

    @Test("marker.add auto-names when name is absent")
    func addAutoNames() async {
        let (router, _) = makeRouter()
        let r = await router.handle(ControlRequest(
            id: "1", command: "marker.add", params: ["beat": .number(4)]))
        #expect(r.ok)
        #expect(r.result?["name"]?.stringValue == "Marker 1")
    }

    @Test("marker.add rejects a negative beat")
    func addRejectsNegativeBeat() async {
        let (router, _) = makeRouter()
        let r = await router.handle(ControlRequest(
            id: "1", command: "marker.add", params: ["beat": .number(-1)]))
        #expect(!r.ok)
        #expect(r.error == "'beat' must be >= 0")
    }

    @Test("marker.list returns markers sorted by beat")
    func listSorted() async {
        let (router, _) = makeRouter()
        _ = await addMarker(router, name: "Chorus", beat: 16)
        _ = await addMarker(router, name: "Intro", beat: 0)
        _ = await addMarker(router, name: "Verse", beat: 4)
        let r = await router.handle(ControlRequest(id: "l", command: "marker.list"))
        #expect(r.ok)
        let markers = r.result?["markers"]?.arrayValue ?? []
        #expect(markers.map { $0["name"]?.stringValue } == ["Intro", "Verse", "Chorus"])
        #expect(markers.map { $0["beat"]?.doubleValue } == [0, 4, 16])
    }

    // MARK: - rename / move / remove

    @Test("marker.rename updates the marker; empty name is rejected")
    func rename() async {
        let (router, store) = makeRouter()
        let id = await addMarker(router, name: "Bridge", beat: 4)
        let ok = await router.handle(ControlRequest(
            id: "r", command: "marker.rename",
            params: ["markerId": .string(id), "name": .string("Outro")]))
        #expect(ok.ok)
        #expect(ok.result?["name"]?.stringValue == "Outro")
        #expect(store.markers[0].name == "Outro")

        let empty = await router.handle(ControlRequest(
            id: "r2", command: "marker.rename",
            params: ["markerId": .string(id), "name": .string("   ")]))
        #expect(!empty.ok)
        #expect(empty.error == "'name' must not be empty")
    }

    @Test("marker.move moves the marker and rejects a negative beat")
    func move() async {
        let (router, store) = makeRouter()
        let id = await addMarker(router, name: "Drop", beat: 8)
        let ok = await router.handle(ControlRequest(
            id: "m", command: "marker.move",
            params: ["markerId": .string(id), "beat": .number(20)]))
        #expect(ok.ok)
        #expect(ok.result?["beat"]?.doubleValue == 20)
        #expect(store.markers[0].beat == 20)

        let neg = await router.handle(ControlRequest(
            id: "m2", command: "marker.move",
            params: ["markerId": .string(id), "beat": .number(-4)]))
        #expect(!neg.ok)
        #expect(neg.error == "'beat' must be >= 0")
    }

    @Test("marker.remove removes the marker; an unknown id is a field-named error")
    func remove() async {
        let (router, store) = makeRouter()
        let id = await addMarker(router, name: "X", beat: 4)
        let ok = await router.handle(ControlRequest(
            id: "d", command: "marker.remove", params: ["markerId": .string(id)]))
        #expect(ok.ok)
        #expect(ok.result?["removed"]?.boolValue == true)
        #expect(store.markers.isEmpty)

        let ghost = await router.handle(ControlRequest(
            id: "d2", command: "marker.remove", params: ["markerId": .string(UUID().uuidString)]))
        #expect(!ghost.ok)
        #expect(ghost.error?.contains("no marker with id") == true)
    }

    // MARK: - transport.seek interop

    @Test("transport.seek by marker id seeks to its beat")
    func seekByID() async {
        let (router, store) = makeRouter()
        let id = await addMarker(router, name: "Chorus", beat: 12)
        let r = await router.handle(ControlRequest(
            id: "s", command: "transport.seek", params: ["marker": .string(id)]))
        #expect(r.ok)
        #expect(store.transport.positionBeats == 12)
    }

    @Test("transport.seek by exact marker name seeks to its beat")
    func seekByName() async {
        let (router, store) = makeRouter()
        _ = await addMarker(router, name: "Chorus", beat: 24)
        let r = await router.handle(ControlRequest(
            id: "s", command: "transport.seek", params: ["marker": .string("Chorus")]))
        #expect(r.ok)
        #expect(store.transport.positionBeats == 24)
    }

    @Test("transport.seek by beats still works unchanged")
    func seekByBeatsUnchanged() async {
        let (router, store) = makeRouter()
        let r = await router.handle(ControlRequest(
            id: "s", command: "transport.seek", params: ["beats": .number(7)]))
        #expect(r.ok)
        #expect(store.transport.positionBeats == 7)
    }

    @Test("transport.seek rejects both beats and marker together")
    func seekBothRejected() async {
        let (router, _) = makeRouter()
        let id = await addMarker(router, name: "C", beat: 4)
        let r = await router.handle(ControlRequest(
            id: "s", command: "transport.seek",
            params: ["beats": .number(2), "marker": .string(id)]))
        #expect(!r.ok)
        #expect(r.error?.contains("not both") == true)
    }

    @Test("transport.seek with an unknown marker is a field-named error")
    func seekUnknownMarker() async {
        let (router, _) = makeRouter()
        let r = await router.handle(ControlRequest(
            id: "s", command: "transport.seek", params: ["marker": .string("Nope")]))
        #expect(!r.ok)
        #expect(r.error?.contains("no marker matching") == true)
    }

    @Test("transport.seek by an ambiguous name (two markers share it) errors clearly")
    func seekAmbiguous() async {
        let (router, _) = makeRouter()
        _ = await addMarker(router, name: "Chorus", beat: 8)
        _ = await addMarker(router, name: "Chorus", beat: 16)
        let r = await router.handle(ControlRequest(
            id: "s", command: "transport.seek", params: ["marker": .string("Chorus")]))
        #expect(!r.ok)
        #expect(r.error?.contains("more than one marker") == true)
    }

    @Test("allCommands advertises the five marker commands")
    func allCommandsAdvertisesMarkers() {
        let names = Set(CommandRouter.allCommands)
        for c in ["marker.add", "marker.remove", "marker.rename", "marker.move", "marker.list"] {
            #expect(names.contains(c), "\(c) missing from allCommands")
        }
    }
}
