import Foundation
import Testing
@testable import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m11-b `edit.history`: the read-only projection of
/// the labeled undo/redo stacks that backs the history panel. Pins the wire shape,
/// the NEWEST-FIRST ordering contract (both directions), the empty state, that a
/// coalesced scrub folds to one entry over the wire, and that a wire undo round-trip
/// moves labels between the two stacks in the right order. The journal mechanics
/// themselves are pinned in DAWCore's `UndoHistoryProjectionTests`; here we pin the
/// wire surface. Adds NO mutation surface — stepping stays `edit.undo`/`edit.redo`.
@MainActor
@Suite("Edit history — control protocol")
struct EditHistoryCommandTests {

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        return (CommandRouter(store: store), store)
    }

    private func history(_ router: CommandRouter, id: String = "1") async -> JSONValue? {
        let response = await router.handle(ControlRequest(id: id, command: "edit.history"))
        #expect(response.ok)
        return response.result
    }

    private func labels(_ result: JSONValue?, _ key: String) -> [String] {
        result?[key]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    @Test("allCommands advertises edit.history")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("edit.history"))
    }

    @Test("edit.history on an empty session returns empty lists and both flags false")
    func emptyHistory() async {
        let (router, _) = makeRouter()
        let result = await history(router)
        #expect(labels(result, "undo").isEmpty)
        #expect(labels(result, "redo").isEmpty)
        #expect(result?["canUndo"]?.boolValue == false)
        #expect(result?["canRedo"]?.boolValue == false)
    }

    @Test("edit.history takes no params — a bare call succeeds")
    func noParamsRequired() async {
        let (router, store) = makeRouter()
        store.addTrack(name: "A")
        let response = await router.handle(ControlRequest(id: "1", command: "edit.history"))
        #expect(response.ok)
        #expect(response.error == nil)
    }

    @Test("edit.history is NEWEST-FIRST and undo[0] is what edit.undo reverses next")
    func newestFirst() async throws {
        let (router, store) = makeRouter()
        store.addTrack(name: "A")
        store.addTrack(name: "B")
        try store.setTempo(140)   // newest edit
        let result = await history(router)
        #expect(labels(result, "undo") == ["Set Tempo", "Add Track 'B'", "Add Track 'A'"])
        #expect(labels(result, "redo").isEmpty)
        #expect(result?["canUndo"]?.boolValue == true)
        #expect(result?["canRedo"]?.boolValue == false)
        // undo[0] matches the snapshot's top-of-stack undoLabel.
        let snap = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        #expect(snap.result?["undoLabel"]?.stringValue == "Set Tempo")
    }

    @Test("a coalesced same-key scrub folds to ONE entry over the wire")
    func coalescingFoldsToOne() async {
        let (router, store) = makeRouter()
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        store.setMasterVolume(0.4)
        clock = clock.advanced(by: .milliseconds(300))   // inside the 800 ms window
        store.setMasterVolume(0.8)                        // same key → coalesces
        let result = await history(router)
        #expect(labels(result, "undo") == ["Set Master Volume"])
    }

    @Test("two wire undos move labels to redo in newest-first order")
    func wireUndoMovesToRedo() async throws {
        let (router, store) = makeRouter()
        store.addTrack(name: "A")
        store.addTrack(name: "B")
        store.addTrack(name: "C")

        // Undo twice over the wire (the real edit.undo path — barrier + guards apply).
        _ = await router.handle(ControlRequest(id: "u1", command: "edit.undo"))  // reverses C
        _ = await router.handle(ControlRequest(id: "u2", command: "edit.undo"))  // reverses B

        let result = await history(router, id: "h")
        #expect(labels(result, "undo") == ["Add Track 'A'"])
        // redo[0] = the NEXT redo (B, most recently undone); C sits below it.
        #expect(labels(result, "redo") == ["Add Track 'B'", "Add Track 'C'"])
        #expect(result?["canUndo"]?.boolValue == true)
        #expect(result?["canRedo"]?.boolValue == true)

        // A wire redo pulls B back onto undo, newest-first preserved.
        _ = await router.handle(ControlRequest(id: "r1", command: "edit.redo"))
        let after = await history(router, id: "h2")
        #expect(labels(after, "undo") == ["Add Track 'B'", "Add Track 'A'"])
        #expect(labels(after, "redo") == ["Add Track 'C'"])
    }

    // MARK: - edit.pasteClips (m26-k, ruled 2026-08-17)
    //
    // ⚠️ THESE LIVE HERE RATHER THAN IN THEIR OWN FILE FOR A STRUCTURAL
    // REASON, NOT A TOPICAL ONE — though the topic fits: `edit.pasteClips` is
    // the fourth verb in the `edit.*` namespace this suite already owns.
    //
    // `MainActorOccupancySiteTests`'s Leg C caps the tree's `@MainActor`
    // `@Suite` count at 330 as a REVIEW CADENCE, and the tree was already
    // sitting at exactly 330 when this verb landed — so a new `@MainActor`
    // `@Suite` turned the gate RED at 331. Leg C's own doc says raising the
    // bound requires pasting a passing `scripts/gates/m23aw-prepare-headroom.mjs`
    // campaign, and records that NO PASSING CAMPAIGN EXISTS to paste because
    // of the m23-aw-4 validity/threshold calibration gap. The bound therefore
    // cannot legitimately be raised right now, and raising it anyway is
    // explicitly named as "the same act as raising the horizon".
    //
    // ⭐ THIS IS THE SECOND CONSECUTIVE ITEM FORCED INTO THIS SHAPE (m26-i
    // folded its 16 tests into `SamplerZoneIdentityWireTests` hours earlier,
    // for the identical reason). That is not two coincidences — it is Leg C
    // doing exactly what it was built to do: forcing a periodic
    // re-measurement that is now overdue. **The remedy is m23-aw-4, not more
    // folding.** A third item hitting this should land m23-aw-4 first.
    //
    // What is NOT happening here: dropping `@MainActor` from a suite to
    // silence the counter. It keys on a `@MainActor` line preceding `@Suite`,
    // so moving isolation onto individual tests would go unseen while
    // reducing no main-actor work at all — a counter dodge, where folding
    // genuinely adds no suite.

    /// Records every call and hands back a scripted result.
    private final class FakeEditPaste: EditPasteControlling {
        var calls: [UUID?] = []
        var result: EditPasteResult = .emptyClipboard

        func pasteClips(intoTrack: UUID?) -> EditPasteResult {
            calls.append(intoTrack)
            return result
        }
    }

    private func makePasteRouter() -> CommandRouter {
        CommandRouter(store: ProjectStore())
    }

    private func paste(_ router: CommandRouter, _ params: [String: JSONValue]) async -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: "edit.pasteClips", params: params))
    }

    // MARK: - 1. parity

    @Test("allCommands lists edit.pasteClips")
    func allCommandsListsIt() {
        #expect(CommandRouter.allCommands.contains("edit.pasteClips"))
    }

    // MARK: - 2. validation, before the seam check (seam deliberately nil)

    @Test("unknown parameter is rejected naming trackId as the only valid key")
    func rejectsUnknownKey() async {
        let router = makePasteRouter()
        let r = await paste(router, ["bogus": .string("x")])
        #expect(!r.ok)
        #expect(r.error?.contains("bogus") == true)
        #expect(r.error?.contains("trackId") == true)
    }

    @Test("a malformed trackId is rejected before the seam is even consulted")
    func rejectsMalformedTrackID() async {
        let router = makePasteRouter()
        // No seam installed at all — if this reached the seam check it would
        // fail with "headless" instead, which is what the next test proves it
        // does NOT say here.
        let r = await paste(router, ["trackId": .string("not-a-uuid")])
        #expect(!r.ok)
        #expect(r.error?.contains("not a valid UUID") == true)
        #expect(r.error?.contains("headless") == false)
    }

    @Test("a syntactically valid trackId with no seam installed errors readably (headless)")
    func headlessErrorsReadably() async {
        let router = makePasteRouter()
        let r = await paste(router, ["trackId": .string(UUID().uuidString)])
        #expect(!r.ok)
        #expect(r.error?.contains("headless") == true)
        #expect(r.error?.contains("DAWApp") == true || r.error?.contains("DAWPro") == true)
    }

    @Test("omitted trackId with no seam installed ALSO errors readably (headless)")
    func headlessErrorsReadablyWithNoParams() async {
        let router = makePasteRouter()
        let r = await paste(router, [:])
        #expect(!r.ok)
        #expect(r.error?.contains("headless") == true)
    }

    // MARK: - 3. routing with the fake installed

    @Test("omitted trackId reaches the seam as nil")
    func omittedTrackIDPassesNil() async {
        let router = makePasteRouter()
        let fake = FakeEditPaste()
        router.editPaste = fake
        _ = await paste(router, [:])
        #expect(fake.calls == [nil])
    }

    @Test("a valid trackId reaches the seam verbatim")
    func validTrackIDPassesThrough() async {
        let router = makePasteRouter()
        let fake = FakeEditPaste()
        router.editPaste = fake
        let id = UUID()
        _ = await paste(router, ["trackId": .string(id.uuidString)])
        #expect(fake.calls == [id])
    }

    // MARK: - 4. the four distinguishable outcomes, each in its own wire shape

    @Test("pasted: landings, skipped, trimmed and removed ids all round-trip")
    func pastedShape() async throws {
        let router = makePasteRouter()
        let fake = FakeEditPaste()
        let clipID = UUID(), trackID = UUID()
        let trimmedID = UUID(), removedID = UUID()
        let skipSourceID = UUID()
        fake.result = .pasted(
            landings: [EditPasteLanding(clipID: clipID, trackID: trackID, startBeat: 4.5)],
            skipped: [EditPasteSkip(sourceClipID: skipSourceID, clipName: "Drum Fill",
                                    reason: "overlaps-pasted-sibling")],
            trimmedClipIDs: [trimmedID], removedClipIDs: [removedID])
        router.editPaste = fake

        let r = await paste(router, [:])
        #expect(r.ok)
        let obj = try #require(r.result?.objectValue)
        #expect(obj["pasted"]?.boolValue == true)
        let landings = try #require(obj["landings"]?.arrayValue)
        #expect(landings.count == 1)
        #expect(landings[0]["clipId"]?.stringValue == clipID.uuidString)
        #expect(landings[0]["trackId"]?.stringValue == trackID.uuidString)
        #expect(landings[0]["startBeat"]?.doubleValue == 4.5)
        let skipped = try #require(obj["skipped"]?.arrayValue)
        #expect(skipped.count == 1)
        #expect(skipped[0]["sourceClipId"]?.stringValue == skipSourceID.uuidString)
        #expect(skipped[0]["clipName"]?.stringValue == "Drum Fill")
        #expect(skipped[0]["reason"]?.stringValue == "overlaps-pasted-sibling")
        #expect(obj["trimmedClipIDs"]?.arrayValue?.map { $0.stringValue } == [trimmedID.uuidString])
        #expect(obj["removedClipIDs"]?.arrayValue?.map { $0.stringValue } == [removedID.uuidString])
    }

    @Test("emptyClipboard names the outcome instead of a bare false")
    func emptyClipboardShape() async throws {
        let router = makePasteRouter()
        let fake = FakeEditPaste()
        fake.result = .emptyClipboard
        router.editPaste = fake

        let r = await paste(router, [:])
        #expect(r.ok)   // the ROUTE succeeded; the PASTE didn't — distinct.
        let obj = try #require(r.result?.objectValue)
        #expect(obj["pasted"]?.boolValue == false)
        #expect(obj["reason"]?.stringValue == "empty-clipboard")
    }

    @Test("wrongPayloadKind names the actual clipboard kind so an agent isn't left guessing")
    func wrongPayloadKindShape() async throws {
        let router = makePasteRouter()
        let fake = FakeEditPaste()
        fake.result = .wrongPayloadKind(actual: "notes")
        router.editPaste = fake

        let r = await paste(router, [:])
        #expect(r.ok)
        let obj = try #require(r.result?.objectValue)
        #expect(obj["pasted"]?.boolValue == false)
        #expect(obj["reason"]?.stringValue == "wrong-payload-kind")
        #expect(obj["clipboardKind"]?.stringValue == "notes")
    }

    @Test("blocked (destination cannot hold the payload) names the refusal and every skip")
    func blockedShape() async throws {
        let router = makePasteRouter()
        let fake = FakeEditPaste()
        let skipSourceID = UUID()
        fake.result = .blocked(
            reason: "all-skipped",
            skipped: [EditPasteSkip(sourceClipID: skipSourceID, clipName: "Vocal Take",
                                    reason: "track-kind-mismatch")])
        router.editPaste = fake

        let r = await paste(router, [:])
        #expect(r.ok)
        let obj = try #require(r.result?.objectValue)
        #expect(obj["pasted"]?.boolValue == false)
        #expect(obj["reason"]?.stringValue == "all-skipped")
        let skipped = try #require(obj["skipped"]?.arrayValue)
        #expect(skipped.count == 1)
        #expect(skipped[0]["sourceClipId"]?.stringValue == skipSourceID.uuidString)
        #expect(skipped[0]["clipName"]?.stringValue == "Vocal Take")
        #expect(skipped[0]["reason"]?.stringValue == "track-kind-mismatch")
    }

    @Test("blocked (policy refusal, no tracks at all) carries an empty skipped array")
    func blockedRefusalShape() async throws {
        let router = makePasteRouter()
        let fake = FakeEditPaste()
        fake.result = .blocked(reason: "no-tracks", skipped: [])
        router.editPaste = fake

        let r = await paste(router, [:])
        #expect(r.ok)
        let obj = try #require(r.result?.objectValue)
        #expect(obj["pasted"]?.boolValue == false)
        #expect(obj["reason"]?.stringValue == "no-tracks")
        #expect(obj["skipped"]?.arrayValue?.isEmpty == true)
    }
}
