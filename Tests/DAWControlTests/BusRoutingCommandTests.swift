import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M4 (i) routing commands: the shared result
/// shape (byte-checked), null-returns-to-master, the add/set/remove send
/// lifecycle, exact domain errors, bus-removal rerouted counts, and allCommands
/// parity. Reuses `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Bus routing & sends — control protocol")
struct BusRoutingCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addTrack(_ router: CommandRouter, name: String, kind: String) async -> UUID {
        let response = await router.handle(ControlRequest(
            id: "add-\(name)", command: "track.add",
            params: ["name": .string(name), "kind": .string(kind)]
        ))
        return UUID(uuidString: response.result?["id"]?.stringValue ?? "")!
    }

    @Test("setOutput round-trips to a bus, and null returns to master")
    func setOutputRoundTripAndNullReturnsToMaster() async throws {
        let (router, _) = makeRouter()
        let busID = await addTrack(router, name: "Reverb", kind: "bus")
        let trackID = await addTrack(router, name: "Gtr", kind: "audio")

        let set = await router.handle(ControlRequest(
            id: "1", command: "track.setOutput",
            params: ["trackId": .string(trackID.uuidString), "busId": .string(busID.uuidString)]
        ))
        #expect(set.ok)
        #expect(set.result?["trackId"]?.stringValue == trackID.uuidString)
        #expect(set.result?["outputBusId"]?.stringValue == busID.uuidString)
        #expect(set.result?["sends"]?.arrayValue?.isEmpty == true)

        let clear = await router.handle(ControlRequest(
            id: "2", command: "track.setOutput",
            params: ["trackId": .string(trackID.uuidString), "busId": .null]
        ))
        #expect(clear.ok)
        // outputBusId is explicit null (never omitted) when routed to master.
        #expect(clear.result?["outputBusId"] == JSONValue.null)
    }

    @Test("add/set/remove send lifecycle produces the shared result shape")
    func sendLifecycleAddSetRemove() async throws {
        let (router, _) = makeRouter()
        let busID = await addTrack(router, name: "Reverb", kind: "bus")
        let trackID = await addTrack(router, name: "Gtr", kind: "audio")

        // Add — result carries the new sendId plus the full sends array.
        let add = await router.handle(ControlRequest(
            id: "1", command: "track.addSend",
            params: ["trackId": .string(trackID.uuidString),
                     "busId": .string(busID.uuidString), "level": .number(0.5)]
        ))
        #expect(add.ok)
        let sendID = try #require(add.result?["sendId"]?.stringValue)
        let addedSend = try #require(add.result?["sends"]?.arrayValue?.first)
        #expect(add.result?["sends"]?.arrayValue?.count == 1)
        #expect(addedSend["id"]?.stringValue == sendID)
        #expect(addedSend["busId"]?.stringValue == busID.uuidString)
        #expect(addedSend["level"]?.doubleValue == 0.5)

        // Set — level updates; no sendId on this result.
        let setL = await router.handle(ControlRequest(
            id: "2", command: "track.setSend",
            params: ["trackId": .string(trackID.uuidString),
                     "sendId": .string(sendID), "level": .number(0.25)]
        ))
        #expect(setL.ok)
        #expect(setL.result?["sends"]?.arrayValue?.first?["level"]?.doubleValue == 0.25)
        #expect(setL.result?["sendId"] == nil)

        // Remove — sends empty afterward.
        let rem = await router.handle(ControlRequest(
            id: "3", command: "track.removeSend",
            params: ["trackId": .string(trackID.uuidString), "sendId": .string(sendID)]
        ))
        #expect(rem.ok)
        #expect(rem.result?["sends"]?.arrayValue?.isEmpty == true)
    }

    @Test("addSend to a non-bus destination reports the exact domain error")
    func addSendToNonBusErrorsExactly() async {
        let (router, _) = makeRouter()
        let notABus = await addTrack(router, name: "Keys", kind: "audio")
        let trackID = await addTrack(router, name: "Gtr", kind: "audio")

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.addSend",
            params: ["trackId": .string(trackID.uuidString), "busId": .string(notABus.uuidString)]
        ))
        #expect(!response.ok)
        #expect(response.error
                == "track \(notABus.uuidString) is not a bus — output and send destinations must be bus tracks")
    }

    @Test("setSend with an unknown send id reports the exact domain error")
    func setSendUnknownIdErrorsExactly() async {
        let (router, _) = makeRouter()
        _ = await addTrack(router, name: "Reverb", kind: "bus")
        let trackID = await addTrack(router, name: "Gtr", kind: "audio")
        let ghost = UUID()

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setSend",
            params: ["trackId": .string(trackID.uuidString),
                     "sendId": .string(ghost.uuidString), "level": .number(0.5)]
        ))
        #expect(!response.ok)
        #expect(response.error == "no send with id \(ghost.uuidString) on that track")
    }

    @Test("removing a bus reports the rerouted counts; a plain track does not")
    func removeBusReportsReroutedCounts() async {
        let (router, _) = makeRouter()
        let busID = await addTrack(router, name: "Reverb", kind: "bus")
        let routed = await addTrack(router, name: "Gtr", kind: "audio")
        let sender = await addTrack(router, name: "Vox", kind: "audio")
        _ = await router.handle(ControlRequest(
            id: "o", command: "track.setOutput",
            params: ["trackId": .string(routed.uuidString), "busId": .string(busID.uuidString)]
        ))
        _ = await router.handle(ControlRequest(
            id: "s", command: "track.addSend",
            params: ["trackId": .string(sender.uuidString), "busId": .string(busID.uuidString)]
        ))

        let removeBus = await router.handle(ControlRequest(
            id: "r", command: "track.remove", params: ["trackId": .string(busID.uuidString)]
        ))
        #expect(removeBus.ok)
        #expect(removeBus.result?["rerouted"]?["outputs"]?.doubleValue == 1)
        #expect(removeBus.result?["rerouted"]?["sends"]?.doubleValue == 1)

        // A non-bus removal has no rerouted payload.
        let plain = await addTrack(router, name: "Plain", kind: "audio")
        let removePlain = await router.handle(ControlRequest(
            id: "rp", command: "track.remove", params: ["trackId": .string(plain.uuidString)]
        ))
        #expect(removePlain.ok)
        #expect(removePlain.result == nil)
    }

    @Test("allCommands advertises the bus-routing commands")
    func advertisesRoutingCommands() {
        #expect(CommandRouter.allCommands.contains("track.setOutput"))
        #expect(CommandRouter.allCommands.contains("track.addSend"))
        #expect(CommandRouter.allCommands.contains("track.setSend"))
        #expect(CommandRouter.allCommands.contains("track.removeSend"))
    }
}
