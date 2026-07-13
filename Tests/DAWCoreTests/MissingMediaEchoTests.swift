import Foundation
import Testing
@testable import DAWCore

/// m16-c store-side coverage (audit F2): the open/recover missing-media ECHO.
/// `project.open`/`project.recover` have always returned media warnings in
/// their own response — but the notices ring stayed empty, so an agent
/// polling `project.snapshot` AFTER an open saw a healthy session while a
/// clip played as silence. The echo lands the same facts in the ring at open
/// time, derived from the freshly loaded MODEL (which also covers the
/// absolute-ref recovery bundles `resolveMedia` deliberately accepts WITHOUT
/// a warning — the audit §2-B3 recipe). Ordering law: the ring clears on the
/// session replacement FIRST, then the new session's echo posts.
@MainActor
@Suite("Missing-media open/recover echo (m16-c)")
struct MissingMediaEchoTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m16c-echo-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Media byte-content is never parsed on this path (FakeMedia supplies
    /// the import facts) — a stub RIFF header is enough to exist on disk.
    private func writeFakeWav(_ url: URL) {
        try? Data([0x52, 0x49, 0x46, 0x46, 0x00]).write(to: url)
    }

    /// A saved bundle whose media file is then deleted out from under it —
    /// the PersistenceTests §10 idiom. Returns the bundle path and the name
    /// of the clip that will be silent.
    private func makeBundleWithMissingMedia(in dir: URL) throws -> (path: String, clipName: String) {
        let src = dir.appendingPathComponent("Snare.wav")
        writeFakeWav(src)
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: src, toTrack: track.id)
        let path = dir.appendingPathComponent("Song").path
        try store.saveProject(to: path)
        let bundleURL = URL(fileURLWithPath: store.projectPath!)
        try FileManager.default.removeItem(at: bundleURL.appendingPathComponent("media/Snare.wav"))
        return (path, clip.name)
    }

    // MARK: - Open echo

    @Test("project.open with missing media: the warnings' facts land in the ring — code/message/beat honest; project.new clears")
    func openEchoesMissingMedia() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (path, clipName) = try makeBundleWithMissingMedia(in: dir)

        let store = ProjectStore()
        store.media = FakeMedia()
        let warnings = try store.openProject(at: path)

        // The response warning is unchanged (existing behavior)…
        #expect(warnings.contains { $0.hasPrefix("missing media:") })
        // …and the SAME facts now live in the ring for later snapshot polls.
        #expect(store.engineNotices.count == 1)
        let notice = try #require(store.engineNotices.first)
        #expect(notice.code == "clip-file-missing")
        #expect(notice.message.contains(clipName))
        #expect(notice.message.contains("missing"))
        let clip = try #require(store.tracks.first?.clips.first)
        let url = try #require(clip.audioFileURL)
        #expect(notice.message.contains(url.path))     // honest path
        #expect(notice.beat == clip.startBeat)         // honest beat
        #expect(notice.count == 1)
        // Diagnostics never dirty a freshly opened project.
        #expect(!store.isDirty)

        // The m15-e clear law still governs: a project boundary empties it.
        try store.newProject(discardChanges: true)
        #expect(store.engineNotices.isEmpty)
    }

    @Test("clear-then-echo ordering: stale notices from the previous session vanish, the echo posts fresh (lastAt restarts at 1)")
    func clearThenEchoOrdering() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (path, _) = try makeBundleWithMissingMedia(in: dir)

        let store = ProjectStore()
        store.media = FakeMedia()
        let engine = EngineNoticeStoreTests.NoticePostingEngine()
        store.engine = engine
        // A previous session's degradation sits in the ring…
        engine.engineNoticeHandler?(EngineNoticeEvent(
            code: "clip-envelope-skipped", message: "stale, from the old session"))
        #expect(store.engineNotices.count == 1)

        _ = try store.openProject(at: path, discardChanges: true)

        // …the open cleared it FIRST, then echoed the new session's facts:
        // the ring holds ONLY the echo, and the sequence restarted with it.
        #expect(store.engineNotices.map(\.code) == ["clip-file-missing"])
        #expect(store.engineNotices.first?.lastAt == 1)
    }

    @Test("clean open: intact media (plus a MIDI clip) echoes nothing — zero notices, byte-level")
    func cleanOpenZeroNotices() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Kick.wav")
        writeFakeWav(src)
        let builder = ProjectStore()
        builder.media = FakeMedia()
        let audio = builder.addTrack(kind: .audio)
        try builder.importAudio(url: src, toTrack: audio.id)
        let midi = builder.addTrack(kind: .instrument)
        try builder.addMIDIClip(toTrack: midi.id, atBeat: 0, lengthBeats: 4,
                                notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let path = dir.appendingPathComponent("Clean").path
        try builder.saveProject(to: path)

        let store = ProjectStore()
        store.media = FakeMedia()
        let warnings = try store.openProject(at: path)
        #expect(warnings.isEmpty)
        #expect(store.engineNotices.isEmpty)
        // Byte-level (the EngineNoticeStoreTests idiom): no trace of the key.
        let bytes = try JSONEncoder().encode(store.snapshot())
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(!json.contains("engineNotices"))
    }

    // MARK: - Recover echo (the audit B3 recipe, headless)

    @Test("project.recover of a session whose absolute-ref media vanished: warnings stay EMPTY (resolveMedia accepts absolute refs as-is) but the ring is honest")
    func recoverEchoesAbsoluteRefMissingMedia() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("TakeOnDisk.wav")
        writeFakeWav(src)

        // Session 1: edits + autosave, then "crashes" (no endCrashDetection).
        let s1 = ProjectStore()
        s1.media = FakeMedia()
        s1.crashRecovery.directory = dir
        s1.crashRecovery.clock = { Date(timeIntervalSince1970: 1000) }
        _ = s1.beginCrashDetection()
        let track = s1.addTrack(kind: .audio)
        let clip = try s1.importAudio(url: src, toTrack: track.id)
        await s1.autosaveTick()

        // The media file vanishes between the crash and the relaunch.
        try FileManager.default.removeItem(at: src)

        // Session 2 relaunches, detects the crash, recovers.
        let s2 = ProjectStore()
        s2.media = FakeMedia()
        s2.crashRecovery.directory = dir
        #expect(s2.beginCrashDetection())
        let outcome = try s2.recoverFromAutosave(accept: true)

        // The autosave stored an ABSOLUTE ref, which resolveMedia accepts
        // without an existence check — the response carries NO warning…
        #expect(outcome == .recovered(warnings: []))
        // …so the ring echo is the recovered session's ONLY open-time honesty.
        #expect(s2.engineNotices.count == 1)
        let notice = try #require(s2.engineNotices.first)
        #expect(notice.code == "clip-file-missing")
        #expect(notice.message.contains(clip.name))
        // Honest path: the RECOVERED clip's resolved (absolute, nonexistent) URL.
        let recoveredURL = try #require(s2.tracks.first?.clips.first?.audioFileURL)
        #expect(notice.message.contains(recoveredURL.path))
        #expect(notice.beat == clip.startBeat)
        #expect(notice.lastAt == 1)  // recover cleared the ring first (m16-c clear-law extension)
    }
}
