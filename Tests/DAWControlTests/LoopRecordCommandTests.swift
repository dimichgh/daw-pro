import Foundation
import Testing
@testable import DAWControl
@testable import DAWCore

/// m15-b — loop-cycle recording over the WIRE (design-m15b §6): zero new
/// commands, zero new params — loop state alone decides. These pin the wire
/// surface of the three teaching errors VERBATIM (they ride the existing
/// LocalizedError mapping) and the seek-to-loop-start visibility in the
/// existing `transport.record` response shape (G5/G7/G8).
@MainActor
@Suite("Loop-cycle recording — wire (m15-b)")
struct LoopRecordCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore, FakeEngine) {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        return (CommandRouter(store: store), store, engine)
    }

    private func armedRouter() throws -> (CommandRouter, ProjectStore, FakeEngine) {
        let (router, store, engine) = makeRouter()
        let track = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        return (router, store, engine)
    }

    @Test("record with loop enabled seeks to the loop start — visible in the EXISTING response shape")
    func recordResponseShowsSeek() async throws {
        let (router, store, engine) = try armedRouter()
        defer { _ = engine }  // store.engine is weak — keep the fake alive
        try store.setLoop(enabled: true, startBeat: 4, endBeat: 12)
        try store.seek(toBeats: 9.5)

        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.record"))
        #expect(response.ok)
        // The same transport encoding as ever (no new fields): the seek shows
        // as positionBeats == loopStartBeat, and the loop claim is now TRUE
        // while recording — the audit-m15 B2 contradiction is dead.
        #expect(response.result?["positionBeats"]?.doubleValue == 4)
        #expect(response.result?["isRecording"]?.boolValue == true)
        #expect(response.result?["isLoopEnabled"]?.boolValue == true)
    }

    @Test("transport.setLoop mid-record refuses with the exact teaching error")
    func setLoopMidRecordRefuses() async throws {
        let (router, store, engine) = try armedRouter()
        defer { _ = engine }  // store.engine is weak — keep the fake alive
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 8)
        let record = await router.handle(ControlRequest(id: "1", command: "transport.record"))
        #expect(record.ok)

        let response = await router.handle(ControlRequest(
            id: "2", command: "transport.setLoop",
            params: ["enabled": .bool(true), "startBeat": .number(2), "endBeat": .number(6)]
        ))
        #expect(!response.ok)
        #expect(response.error == "cannot change the loop while recording — stop first")
        // The rolling take's window is untouched.
        #expect(store.transport.loopStartBeat == 0)
        #expect(store.transport.loopEndBeat == 8)
    }

    @Test("record with loop AND punch refuses with the exact teaching error")
    func loopPunchRefusesOverWire() async throws {
        let (router, store, engine) = try armedRouter()
        defer { _ = engine }  // store.engine is weak — keep the fake alive
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 8)
        try store.setPunch(enabled: true, inBeat: 2, outBeat: 6)

        let response = await router.handle(ControlRequest(id: "1", command: "transport.record"))
        #expect(!response.ok)
        #expect(response.error == "recording with both a loop and a punch window is not supported — disable one: loop-cycle takes (transport.setLoop) or punch (transport.setPunch)")
        #expect(store.transport.isRecording == false)
    }

    @Test("record with a sub-1-second cycle refuses with the exact teaching error")
    func cycleFloorRefusesOverWire() async throws {
        let (router, store, engine) = try armedRouter()
        defer { _ = engine }  // store.engine is weak — keep the fake alive
        try store.setLoop(enabled: true, startBeat: 0, endBeat: 1)  // 0.5 s @ 120

        let response = await router.handle(ControlRequest(id: "1", command: "transport.record"))
        #expect(!response.ok)
        #expect(response.error == "loop is too short for take recording — use a loop of at least 1 second per cycle")
        #expect(store.transport.isRecording == false)
    }

    @Test("punch-only record (loop off) still starts over the wire — the era's wire face")
    func punchOnlyRecordStillStarts() async throws {
        let (router, store, engine) = try armedRouter()
        defer { _ = engine }  // store.engine is weak — keep the fake alive
        try store.setPunch(enabled: true, inBeat: 2, outBeat: 6)

        let response = await router.handle(ControlRequest(id: "1", command: "transport.record"))
        #expect(response.ok)
        #expect(response.result?["isRecording"]?.boolValue == true)
        // No loop ⇒ no seek: record starts from the playhead exactly as ever.
        #expect(response.result?["positionBeats"]?.doubleValue == 0)
    }
}
