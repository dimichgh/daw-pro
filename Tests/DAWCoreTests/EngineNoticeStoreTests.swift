import Foundation
import Testing
@testable import DAWCore

/// m15-e store-side coverage: the engine-notices ring on `ProjectStore` —
/// handler installation on engine attach (the `playheadHandler` shape),
/// coalescing BY CODE (count/lastAt/message/beat refresh, never a second
/// entry), the 16-entry bound with stalest-first eviction, project-boundary
/// clears (`project.new`/`project.open`) including the `lastAt` sequence
/// reset, undo leaving diagnostics alone, no dirty-flag side effect, and the
/// snapshot mirror with the omit-when-empty byte discipline (the
/// masterAutomation rule).
@MainActor
@Suite("Engine notices — ProjectStore ring (m15-e)")
struct EngineNoticeStoreTests {

    /// Minimal engine: stores the handler the store installs, so tests post
    /// through the REAL installation path.
    final class NoticePostingEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var engineNoticeHandler: ((EngineNoticeEvent) -> Void)?

        func prepare() throws {}
        func shutdown() {}
        func tracksDidChange(_ tracks: [Track]) {}
        func startPlayback(_ transport: TransportState) {}
        func stopPlayback() {}
        func seek(_ transport: TransportState) {}
        func setTempo(_ transport: TransportState) {}
        func loopChanged(_ transport: TransportState) {}
        func masterVolumeChanged(_ volume: Double) {}
        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL) async throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
        }
        var recordPermission: RecordPermission = .granted
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
            completion(true)
        }
        func setInputDevice(uid: String?) throws {}
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
        func stopRecording() {}
    }

    private func makeStore() -> (ProjectStore, NoticePostingEngine) {
        let store = ProjectStore()
        let engine = NoticePostingEngine()
        store.engine = engine
        return (store, engine)
    }

    private func post(_ engine: NoticePostingEngine, code: String,
                      message: String = "something degraded", beat: Double? = nil) {
        engine.engineNoticeHandler?(EngineNoticeEvent(code: code, message: message, beat: beat))
    }

    // MARK: - Installation + basic post

    @Test("attaching an engine installs the notice handler; a post lands in the ring")
    func handlerInstalledAndPosts() throws {
        let (store, engine) = makeStore()
        #expect(engine.engineNoticeHandler != nil)
        #expect(store.engineNotices.isEmpty)

        post(engine, code: "clip-fades-skipped",
             message: "Fades on 'Gtr' couldn't be applied this pass — the clip played on time, without its fades.",
             beat: 3)

        #expect(store.engineNotices.count == 1)
        let notice = try #require(store.engineNotices.first)
        #expect(notice.code == "clip-fades-skipped")
        #expect(notice.message.contains("Gtr"))
        #expect(notice.beat == 3)
        #expect(notice.count == 1)
        #expect(notice.lastAt == 1)
        // Diagnostics never dirty the project.
        #expect(!store.isDirty)
    }

    // MARK: - Coalescing

    @Test("repeat of a code coalesces: count grows, message/beat/lastAt refresh, length stays 1")
    func coalescingByCode() throws {
        let (store, engine) = makeStore()
        post(engine, code: "clip-envelope-skipped", message: "first message", beat: 0)
        post(engine, code: "clip-envelope-skipped", message: "second message", beat: 8)

        #expect(store.engineNotices.count == 1)
        let notice = try #require(store.engineNotices.first)
        #expect(notice.count == 2)
        #expect(notice.message == "second message")  // latest wins
        #expect(notice.beat == 8)
        #expect(notice.lastAt == 2)

        // A different code appends, in first-post order.
        post(engine, code: "clip-stretch-pending", message: "third")
        #expect(store.engineNotices.map(\.code) ==
                ["clip-envelope-skipped", "clip-stretch-pending"])
        #expect(store.engineNotices.last?.lastAt == 3)
    }

    // MARK: - Ring bound

    @Test("cap+1 distinct codes evict the STALEST entry (a refreshed old code survives)")
    func ringBoundEvictsStalest() throws {
        let (store, engine) = makeStore()
        let cap = ProjectStore.engineNoticeCap
        #expect(cap == 16)  // documented bound — a change here is a design decision

        for index in 0..<cap {
            post(engine, code: "notice-\(index)")
        }
        #expect(store.engineNotices.count == cap)

        // Refresh code 0 so it is no longer the stalest…
        post(engine, code: "notice-0")
        // …then overflow: notice-1 (now the smallest lastAt) is evicted.
        post(engine, code: "notice-\(cap)")

        #expect(store.engineNotices.count == cap)
        let codes = store.engineNotices.map(\.code)
        #expect(!codes.contains("notice-1"))
        #expect(codes.contains("notice-0"))
        #expect(codes.contains("notice-\(cap)"))
    }

    // MARK: - Project boundaries

    @Test("project.new clears the ring AND resets the lastAt sequence")
    func newProjectClears() throws {
        let (store, engine) = makeStore()
        post(engine, code: "clip-fades-skipped")
        post(engine, code: "clip-stretch-pending")
        #expect(store.engineNotices.count == 2)

        try store.newProject()
        #expect(store.engineNotices.isEmpty)

        // The sequence restarts with the session.
        post(engine, code: "clip-fades-skipped")
        #expect(store.engineNotices.first?.lastAt == 1)
    }

    @Test("project.open clears the ring")
    func openProjectClears() throws {
        let (store, engine) = makeStore()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-notice-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Session.dawproj").path
        _ = try store.saveProject(to: path)

        post(engine, code: "clip-envelope-skipped")
        #expect(store.engineNotices.count == 1)

        try store.openProject(at: path)
        #expect(store.engineNotices.isEmpty)
    }

    // MARK: - Undo does not touch notices

    @Test("undo/redo leave the ring alone — notices are diagnostics, not project state")
    func undoLeavesNotices() throws {
        let (store, engine) = makeStore()
        _ = store.addTrack(name: "Keys", kind: .instrument)
        post(engine, code: "clip-stretch-pending")
        #expect(store.engineNotices.count == 1)

        _ = try store.undo()
        #expect(store.tracks.isEmpty)
        #expect(store.engineNotices.count == 1)  // un-editing does not un-happen playback
        _ = try store.redo()
        #expect(store.engineNotices.count == 1)
    }

    // MARK: - Snapshot mirror

    @Test("snapshot mirrors the ring; an empty ring omits the key entirely (byte-level)")
    func snapshotMirrorAndOmitWhenEmpty() throws {
        let (store, engine) = makeStore()

        // Null case: no key, not even an empty array — byte-level.
        let cleanSnapshot = store.snapshot()
        #expect(cleanSnapshot.engineNotices == nil)
        let cleanBytes = try JSONEncoder().encode(cleanSnapshot)
        let cleanJSON = try #require(String(data: cleanBytes, encoding: .utf8))
        #expect(!cleanJSON.contains("engineNotices"))

        post(engine, code: "clip-fades-skipped", message: "Fades on 'A' couldn't be applied", beat: 2)
        post(engine, code: "clip-fades-skipped", message: "Fades on 'A' couldn't be applied", beat: 2)

        let snapshot = store.snapshot()
        let notices = try #require(snapshot.engineNotices)
        #expect(notices.count == 1)
        #expect(notices.first?.code == "clip-fades-skipped")
        #expect(notices.first?.count == 2)
        #expect(notices.first?.lastAt == 2)
    }
}
