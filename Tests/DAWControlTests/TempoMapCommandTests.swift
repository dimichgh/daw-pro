import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for the m12-d tempo-map wire surface:
/// `tempo.map` (read) / `tempo.setMap` (write, full-replace, undoable),
/// `transport.setTempo`'s multi-segment reject, and the additive snapshot
/// fields. Store-op semantics are pinned in DAWCore's TempoMapPhaseCTests;
/// here we assert the wire shape, read-back agreement, and error surface.
@MainActor
@Suite("Tempo map — control protocol")
struct TempoMapCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func setMap(_ router: CommandRouter,
                        _ segments: [(Double, Double)],
                        meter: [(Double, Int, Int)]? = nil) async -> ControlResponse {
        var params: [String: JSONValue] = [
            "segments": .array(segments.map { .object(["startBeat": .number($0.0), "bpm": .number($0.1)]) }),
        ]
        if let meter {
            params["meterChanges"] = .array(meter.map {
                .object(["startBeat": .number($0.0),
                         "beatsPerBar": .number(Double($0.1)),
                         "beatUnit": .number(Double($0.2))])
            })
        }
        return await router.handle(ControlRequest(id: "sm", command: "tempo.setMap", params: params))
    }

    // MARK: - setMap → map read-back + snapshot agreement

    @Test("tempo.setMap installs a multi-segment map; tempo.map + snapshot agree")
    func setMapReadBack() async throws {
        let (router, store) = makeRouter()
        let write = await setMap(router,
                                 [(0, 120), (8, 90), (16, 140)],
                                 meter: [(0, 4, 4), (8, 3, 4)])
        #expect(write.ok)

        // Echo === the tempo.map read.
        let read = await router.handle(ControlRequest(id: "r", command: "tempo.map"))
        #expect(read.ok)
        let segs = try #require(read.result?["segments"]?.arrayValue)
        #expect(segs.count == 3)
        #expect(segs.map { $0["bpm"]?.doubleValue } == [120, 90, 140])
        #expect(segs.map { $0["startBeat"]?.doubleValue } == [0, 8, 16])
        let meters = try #require(read.result?["meterChanges"]?.arrayValue)
        #expect(meters.count == 2)
        #expect(meters[1]["beatsPerBar"]?.doubleValue == 3)
        #expect(read.result?["mapRevision"]?.doubleValue == 1)
        // Write echo matches the read exactly (shared JSON builder).
        #expect(write.result == read.result)

        // Snapshot carries the additive fields; transport.tempoBPM = segment 0.
        let snap = await router.handle(ControlRequest(id: "s", command: "project.snapshot"))
        let doc = snap.result
        #expect(doc?["tempoMap"]?.arrayValue?.count == 3)
        #expect(doc?["meterChanges"]?.arrayValue?.count == 2)
        #expect(doc?["transport"]?.objectValue?["tempoBPM"]?.doubleValue == 120)
        #expect(store.transport.tempoMapOverride != nil)
    }

    @Test("a single-segment setMap collapses to the scalar; snapshot omits the fields")
    func singleSegmentCollapses() async throws {
        let (router, _) = makeRouter()
        #expect(await setMap(router, [(0, 128)]).ok)

        let read = await router.handle(ControlRequest(id: "r", command: "tempo.map"))
        #expect(read.result?["segments"]?.arrayValue?.count == 1)
        // Trivial project → snapshot omits the map fields (byte hygiene).
        let snap = await router.handle(ControlRequest(id: "s", command: "project.snapshot"))
        #expect(snap.result?["tempoMap"] == nil)
        #expect(snap.result?["meterChanges"] == nil)
    }

    // MARK: - undo restores the prior map in ONE step

    @Test("one edit.undo restores the previous map (verified via tempo.map)")
    func undoRestoresMap() async throws {
        let (router, _) = makeRouter()
        _ = await setMap(router, [(0, 120), (8, 90), (16, 140)])

        let undo = await router.handle(ControlRequest(id: "u", command: "edit.undo"))
        #expect(undo.ok)
        let read = await router.handle(ControlRequest(id: "r", command: "tempo.map"))
        // Back to the trivial single segment at the base tempo.
        #expect(read.result?["segments"]?.arrayValue?.count == 1)
        #expect(read.result?["segments"]?.arrayValue?.first?["bpm"]?.doubleValue == 120)

        let redo = await router.handle(ControlRequest(id: "d", command: "edit.redo"))
        #expect(redo.ok)
        let read2 = await router.handle(ControlRequest(id: "r2", command: "tempo.map"))
        #expect(read2.result?["segments"]?.arrayValue?.count == 3)
    }

    // MARK: - transport.setTempo reject on a multi-segment map (pinned message)

    @Test("transport.setTempo rejects on a multi-segment map with the teaching error")
    func setTempoRejectsMultiSegment() async throws {
        let (router, _) = makeRouter()
        _ = await setMap(router, [(0, 120), (8, 90)])
        let response = await router.handle(ControlRequest(
            id: "t", command: "transport.setTempo", params: ["bpm": .number(150)]))
        #expect(!response.ok)
        #expect(response.error
            == "this project has a multi-segment tempo map — use tempo.setMap to edit it (transport.setTempo sets a single project-wide tempo and would flatten the map)")

        // On a trivial project it still works (fast path).
        let (router2, _) = makeRouter()
        let ok = await router2.handle(ControlRequest(
            id: "t2", command: "transport.setTempo", params: ["bpm": .number(140)]))
        #expect(ok.ok)
        #expect(ok.result?.doubleValue == 140)
    }

    // MARK: - validation surfaces field-named teaching strings

    @Test("tempo.setMap validation errors surface verbatim")
    func validationErrors() async throws {
        let (router, _) = makeRouter()
        // Segment 0 not at beat 0.
        let notZero = await setMap(router, [(2, 120), (8, 90)])
        #expect(!notZero.ok)
        #expect(notZero.error?.contains("segments[0] must start at beat 0") == true)

        // Unsorted / duplicate beats.
        let dup = await setMap(router, [(0, 120), (4, 90), (4, 100)])
        #expect(!dup.ok)
        #expect(dup.error?.contains("strictly greater") == true)

        // Empty segments.
        let empty = await router.handle(ControlRequest(
            id: "e", command: "tempo.setMap", params: ["segments": .array([])]))
        #expect(!empty.ok)
        #expect(empty.error?.contains("at least one entry") == true)

        // Meter change off a barline (beat 5 is not a whole bar of 4/4).
        let offbar = await setMap(router, [(0, 120)], meter: [(0, 4, 4), (5, 3, 4)])
        #expect(!offbar.ok)
        #expect(offbar.error?.contains("barline") == true)
    }
}
