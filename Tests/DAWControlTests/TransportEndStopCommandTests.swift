import Foundation
import Testing
@testable import DAWControl
@testable import DAWCore

/// Control-protocol coverage for m25-d `transport.setStopAtContentEnd` — the
/// wire half of the end-of-content transport stop.
@MainActor
@Suite("transport.setStopAtContentEnd (m25-d)")
struct TransportEndStopCommandTests {

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        return (CommandRouter(store: store), store)
    }

    /// A project whose content ends at `end` beats (MIDI clips need no file).
    private func seed(_ store: ProjectStore, contentEnd: Double) {
        let track = store.addTrack(name: "T", kind: .instrument)
        _ = try! store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: contentEnd)
    }

    // MARK: - Registration (additive-at-end law)

    @Test("the verb is on allCommands exactly once, appended at the END")
    func registeredAdditively() {
        #expect(CommandRouter.allCommands.contains("transport.setStopAtContentEnd"))
        #expect(CommandRouter.allCommands
            .filter { $0 == "transport.setStopAtContentEnd" }.count == 1)
        // m25-z appended `audio.profileFile`, then m23-ap-3 appended
        // `clip.detectPitch`, then m26-k appended `edit.pasteClips`, after
        // this verb (same law), so it is no longer literally last — still
        // contiguous, still unmoved.
        #expect(CommandRouter.allCommands.dropLast(5).last == "transport.setStopAtContentEnd")
        // The verb BEFORE it is untouched — HEAD's list stays an exact prefix.
        #expect(CommandRouter.allCommands.dropLast(6).last == "vc.importVoiceModel")
    }

    @Test("the verb is in the copilot catalog exactly once (m21-b2)")
    func inCopilotCatalog() {
        #expect(CopilotToolCatalog.tool(command: "transport.setStopAtContentEnd") != nil)
        #expect(CopilotToolCatalog.allCommands
            .filter { $0 == "transport.setStopAtContentEnd" }.count == 1)
        #expect(!CopilotToolCatalog.neverInclude.contains("transport.setStopAtContentEnd"))
    }

    // MARK: - Happy path

    @Test("disabling then re-enabling round-trips, returning preference + measured content end")
    func setAndReadBack() async {
        let (router, store) = makeRouter()
        seed(store, contentEnd: 24)

        var response = await router.handle(ControlRequest(
            id: "1", command: "transport.setStopAtContentEnd",
            params: ["enabled": .bool(false)]))
        #expect(response.ok, "failed: \(response.error ?? "?")")
        #expect(response.result?["stopAtContentEnd"]?.boolValue == false)
        #expect(response.result?["contentEndBeat"]?.doubleValue == 24)
        #expect(!store.stopAtContentEnd)

        response = await router.handle(ControlRequest(
            id: "2", command: "transport.setStopAtContentEnd",
            params: ["enabled": .bool(true)]))
        #expect(response.ok)
        #expect(response.result?["stopAtContentEnd"]?.boolValue == true)
        #expect(store.stopAtContentEnd)
    }

    @Test("an empty project reports contentEndBeat 0 rather than omitting it")
    func emptyProjectReportsZero() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setStopAtContentEnd",
            params: ["enabled": .bool(true)]))
        #expect(response.ok)
        #expect(response.result?["contentEndBeat"]?.doubleValue == 0)
    }

    @Test("contentEndBeat is the max across ALL tracks, not the last one added")
    func contentEndSpansTracks() async {
        let (router, store) = makeRouter()
        seed(store, contentEnd: 64)
        seed(store, contentEnd: 8)
        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setStopAtContentEnd",
            params: ["enabled": .bool(true)]))
        #expect(response.result?["contentEndBeat"]?.doubleValue == 64)
    }

    // MARK: - Param hardening (the m16-e F5 shape)

    @Test("'enabled' is required")
    func enabledRequired() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setStopAtContentEnd", params: [:]))
        #expect(!response.ok)
        #expect(response.error?.contains("enabled") == true)
    }

    @Test("an unknown key is REJECTED, not silently ignored")
    func unknownKeyRejected() async {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setStopAtContentEnd",
            params: ["enabled": .bool(false), "stopAtEnd": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("stopAtEnd") == true)
        #expect(store.stopAtContentEnd, "a rejected call must not have taken effect")
    }

    @Test("a non-boolean 'enabled' is rejected")
    func wrongTypeRejected() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setStopAtContentEnd",
            params: ["enabled": .string("yes")]))
        #expect(!response.ok)
    }

    // MARK: - Snapshot mirror

    /// ⚠️ The snapshot key is `runsPastContentEnd` (the OVERRIDE), while the
    /// verb and its response use `stopAtContentEnd` (the preference). That is
    /// deliberate, not drift: omit-at-default is only safe when an ABSENT key
    /// reads true under its own name. "no `runsPastContentEnd`" ⇒ the transport
    /// does not run past the content end ✅. "no `stopAtContentEnd`" would have
    /// read ⇒ it does not stop ❌ — the opposite of the truth.
    @Test("project.snapshot omits runsPastContentEnd at the default, carries true when opted out")
    func snapshotMirror() async {
        let (router, store) = makeRouter()
        seed(store, contentEnd: 16)

        var snapshot = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(snapshot.result?["runsPastContentEnd"] == nil,
                "the default (stops) is omitted — a default session stays byte-identical")
        #expect(snapshot.result?["stopAtContentEnd"] == nil,
                "the preference-polarity name must NOT appear on the snapshot at all")
        #expect(snapshot.result?["contentEndBeat"]?.doubleValue == 16)

        _ = await router.handle(ControlRequest(
            id: "2", command: "transport.setStopAtContentEnd",
            params: ["enabled": .bool(false)]))
        snapshot = await router.handle(ControlRequest(id: "3", command: "project.snapshot"))
        #expect(snapshot.result?["runsPastContentEnd"]?.boolValue == true)
        #expect(snapshot.result?["stopAtContentEnd"] == nil)
    }

    @Test("an empty project's snapshot omits contentEndBeat")
    func snapshotOmitsEmptyContentEnd() async {
        let (router, _) = makeRouter()
        let snapshot = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(snapshot.result?["contentEndBeat"] == nil)
    }

    // MARK: - The preference is not project data

    @Test("the preference is untouched by edit.undo — it is session state")
    func undoLeavesPreferenceAlone() async {
        let (router, store) = makeRouter()
        seed(store, contentEnd: 16)
        _ = await router.handle(ControlRequest(
            id: "1", command: "transport.setStopAtContentEnd",
            params: ["enabled": .bool(false)]))
        _ = await router.handle(ControlRequest(
            id: "2", command: "track.add", params: ["name": .string("Another")]))
        let undo = await router.handle(ControlRequest(id: "3", command: "edit.undo"))
        #expect(undo.ok, "undo failed: \(undo.error ?? "?")")
        #expect(!store.stopAtContentEnd, "undo must not restore a preference")
    }

    @Test("setting the preference does not create an undo step of its own")
    func settingIsNotAnEdit() async {
        let (router, store) = makeRouter()
        seed(store, contentEnd: 16)
        let before = store.snapshot().undoLabel
        _ = await router.handle(ControlRequest(
            id: "1", command: "transport.setStopAtContentEnd",
            params: ["enabled": .bool(false)]))
        #expect(store.snapshot().undoLabel == before)
    }

    @Test("⚠️⚠️ the verb is accepted (and inert) mid-record rather than refused")
    func acceptedMidRecord() async throws {
        let store = ProjectStore()
        let engine = FakeEngine()   // the shared DAWControlTests fake, m25-d-aware
        store.engine = engine
        let router = CommandRouter(store: store)
        seed(store, contentEnd: 16)
        let track = store.addTrack(name: "Rec", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        #expect(store.transport.isRecording)

        engine.clearEndStopPushes()
        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setStopAtContentEnd",
            params: ["enabled": .bool(true)]))
        #expect(response.ok, "a preference toggle must not fail for transport reasons")
        // Inert by construction: the arming predicate refuses while recording.
        #expect(engine.currentEndStop == nil, "a take must never be handed a stop bound")
        #expect(store.transport.isRecording, "the take is still rolling")
    }
}
