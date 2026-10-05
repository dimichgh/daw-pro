import Foundation
import Testing
@testable import DAWCore

/// m33-j — `importAudio`'s OVERLAP POLICY, the store half.
///
/// ⛔ THE DEFECT THIS SUITE EXISTS FOR, measured 2026-08-29 through the live
/// `clip.addAudio` router before any change: two imports at `atBeat: 0` on one
/// audio track left **ONE** clip, the first clip's id dead, and BOTH calls
/// returned a normal success with an id. A third import at beat 40 left two, so
/// the count was reading correctly and the deletion was specifically the
/// overlap path. No refusal, no warning, no trim report — the verb ran the
/// m11-d/m13-b overlap policy and threw its report away. That is data loss, and
/// it landed on the resample loop `claude-plugin/skills/sample-flip/SKILL.md`
/// §8 ships as central craft (bounce, re-import, chop the print, repeat).
///
/// The policy now: REFUSE, naming the resident — the
/// `clipsWouldOverlapOnDestination` convention for a collision the verb itself
/// manufactured — with `overwrite: true` as the explicit opt-in to the old
/// trim/remove (the `vc.importVoiceModel` precedent), which then RETURNS what
/// it did in `trimmedClipIDs`/`removedClipIDs` (the `clip.moveMany` receipt).
///
/// ⭐ THE LOAD-BEARING TEST IS `twoOverlappingImportsNeverReduceTheClipCount`.
/// Everything else can be re-negotiated; that one is the defect.
@MainActor
@Suite("Audio import overlap policy (m33-j)")
struct AudioImportOverlapTests {
    /// 2.0 s at 120 BPM = 4 beats, the same fixture shape the batch suite uses.
    private struct Media2s: MediaImporting {
        func audioFileInfo(at url: URL) throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: 2.0, sampleRate: 44100, channelCount: 2)
        }
    }

    private func makeStore() throws -> (ProjectStore, Track) {
        let store = ProjectStore()
        store.media = Media2s()
        try store.setTempo(120)
        let track = store.addTrack(kind: .audio)
        return (store, track)
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).wav") }

    // MARK: - The regression

    @Test("REGRESSION: two overlapping imports never reduce the clip count, and the first id stays alive")
    func twoOverlappingImportsNeverReduceTheClipCount() throws {
        let (store, track) = try makeStore()
        let first = try store.importAudio(url: url("print1"), toTrack: track.id, atBeat: 0)
        #expect(store.tracks[0].clips.count == 1)

        #expect(throws: ProjectError.self) {
            _ = try store.importAudio(url: url("print2"), toTrack: track.id, atBeat: 0)
        }

        // The two facts the defect violated: the count did not shrink, and the
        // id the caller was handed is still addressable.
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips.contains { $0.id == first.id })
        #expect(store.tracks[0].clips[0].audioFileURL == url("print1"))

        // POSITIVE CONTROL, kept in the test rather than in a comment: the
        // count DOES move when the import lands clear. A regression test whose
        // subject is "a number failed to change" is worthless without one.
        _ = try store.importAudio(url: url("print3"), toTrack: track.id, atBeat: 40)
        #expect(store.tracks[0].clips.count == 2)
    }

    @Test("a PARTIAL overlap is refused too — the resident's geometry is untouched")
    func partialOverlapRefused() throws {
        let (store, track) = try makeStore()
        _ = try store.importAudio(url: url("resident"), toTrack: track.id, atBeat: 40)
        // 40→44; land at 42 so only the tail is covered. Pre-m33-j this trimmed
        // the resident from 4 beats to 2 and said nothing.
        #expect(throws: ProjectError.self) {
            _ = try store.importAudio(url: url("late"), toTrack: track.id, atBeat: 42)
        }
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].startBeat == 40)
        #expect(store.tracks[0].clips[0].lengthBeats == 4)
    }

    @Test("a refused import journals nothing — no stray undo entry")
    func refusalJournalsNothing() throws {
        let (store, track) = try makeStore()
        _ = try store.importAudio(url: url("resident"), toTrack: track.id, atBeat: 0)
        // Depth, not `canUndo` — the track add journals an entry of its own, so
        // a boolean cannot tell "the refusal added nothing" from "something is
        // still on the stack". Compare the LABEL LIST across the refusal.
        let before = store.undoHistory().undo

        #expect(throws: ProjectError.self) {
            _ = try store.importAudio(url: url("collider"), toTrack: track.id, atBeat: 0)
        }

        #expect(store.undoHistory().undo == before)
        _ = try store.undo()
        #expect(store.tracks[0].clips.isEmpty)
    }

    // MARK: - The escapes

    @Test("omitting atBeat appends past everything and can never collide")
    func appendEscapeNeverCollides() throws {
        let (store, track) = try makeStore()
        for _ in 0..<4 {
            _ = try store.importAudio(url: url("pass"), toTrack: track.id)
        }
        #expect(store.tracks[0].clips.count == 4)
        #expect(store.tracks[0].clips.map(\.startBeat) == [0, 4, 8, 12])
    }

    @Test("overwrite:true restores the trim/remove AND reports it")
    func overwriteReportsWhatItDid() throws {
        let (store, track) = try makeStore()
        let victim = try store.importAudio(url: url("old"), toTrack: track.id, atBeat: 0)
        let result = try store.importAudio(
            url: url("new"), toTrack: track.id, atBeat: 0, overwrite: true)

        #expect(store.tracks[0].clips.count == 1)
        #expect(result.removedClipIDs == [victim.id])
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(store.tracks[0].clips[0].id == result.clip.id)
    }

    @Test("overwrite:true on a PARTIAL overlap reports a trim, not a removal")
    func overwriteReportsATrim() throws {
        let (store, track) = try makeStore()
        let resident = try store.importAudio(url: url("resident"), toTrack: track.id, atBeat: 40)
        let result = try store.importAudio(
            url: url("late"), toTrack: track.id, atBeat: 42, overwrite: true)

        #expect(result.trimmedClipIDs == [resident.id])
        #expect(result.removedClipIDs.isEmpty)
        #expect(store.tracks[0].clips.count == 2)
        let trimmed = try #require(store.tracks[0].clips.first { $0.id == resident.id })
        #expect(trimmed.startBeat == 40)
        #expect(trimmed.lengthBeats == 2)
    }

    @Test("a clear landing reports two empty arrays, whether or not overwrite was asked for")
    func clearLandingReportsEmptyArrays() throws {
        let (store, track) = try makeStore()
        _ = try store.importAudio(url: url("a"), toTrack: track.id, atBeat: 0)
        let clear = try store.importAudio(
            url: url("b"), toTrack: track.id, atBeat: 8, overwrite: true)
        #expect(clear.trimmedClipIDs.isEmpty)
        #expect(clear.removedClipIDs.isEmpty)
        #expect(store.tracks[0].clips.count == 2)
    }

    @Test("clips that merely TOUCH at a shared edge are adjacent, not overlapping")
    func adjacencyIsNotOverlap() throws {
        let (store, track) = try makeStore()
        _ = try store.importAudio(url: url("a"), toTrack: track.id, atBeat: 0)   // 0→4
        _ = try store.importAudio(url: url("b"), toTrack: track.id, atBeat: 4)   // 4→8
        #expect(store.tracks[0].clips.count == 2)
    }

    // MARK: - What the refusal must NOT catch

    @Test("a take stack is NOT a collision — take members stack legally and still do")
    func takeStackStillAccepted() throws {
        // The oracle is `resolvingOverlaps` itself, not a geometric intersection
        // test, precisely so this case keeps working: take/comp members are
        // EXEMPT from trimming, so an import over them destroys nothing and must
        // not be refused. A hand-rolled "does anything intersect [start,end)?"
        // predicate would have broken this previously-working, non-destructive
        // call — the false-positive half of the fix.
        // Built by construction rather than by importing twice: the stack is two
        // clips at the SAME beats, which is exactly what the new refusal
        // prevents an import from producing. (The `compMemberRejected`
        // precedent in ClipFitToContentCommandTests builds its take group the
        // same way.)
        let a = Clip(name: "take1", startBeat: 0, lengthBeats: 4,
                     audioFileURL: url("take1"))
        let b = Clip(name: "take2", startBeat: 0, lengthBeats: 4,
                     audioFileURL: url("take2"))
        let store = ProjectStore(tracks: [Track(name: "Vox", kind: .audio, clips: [a, b])])
        store.media = Media2s()
        try store.setTempo(120)
        let track = store.tracks[0]
        _ = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        #expect(store.tracks[0].clips.allSatisfy { $0.takeGroupID != nil })
        // `groupTakes` REBUILDS its members (and two fully-stacked takes comp
        // down to ONE member covering the range), so the surviving ids to watch
        // are the post-grouping ones, not `a.id`/`b.id` and not necessarily two.
        let memberIDs = Set(store.tracks[0].clips.map(\.id))
        #expect(!memberIDs.isEmpty)

        let landed = try store.importAudio(url: url("import"), toTrack: track.id, atBeat: 0)
        #expect(store.tracks[0].clips.count == memberIDs.count + 1)
        #expect(store.tracks[0].clips.contains { $0.id == landed.id })
        #expect(memberIDs.isSubset(of: Set(store.tracks[0].clips.map(\.id))))
    }

    @Test("an import onto a DIFFERENT track is never refused by another track's clips")
    func otherTracksAreIrrelevant() throws {
        let (store, first) = try makeStore()
        let second = store.addTrack(kind: .audio)
        _ = try store.importAudio(url: url("a"), toTrack: first.id, atBeat: 0)
        _ = try store.importAudio(url: url("b"), toTrack: second.id, atBeat: 0)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[1].clips.count == 1)
    }

    // MARK: - The message

    @Test("the refusal names the resident by id AND name, and offers the append beat")
    func refusalNamesTheResident() throws {
        let (store, track) = try makeStore()
        let resident = try store.importAudio(url: url("flip-pass"), toTrack: track.id, atBeat: 0)
        var captured: (any Error)?
        do {
            _ = try store.importAudio(url: url("flip-pass"), toTrack: track.id, atBeat: 2)
        } catch { captured = error }
        let error = try #require(captured as? ProjectError)
        let message = try #require(error.errorDescription)
        #expect(message.contains(resident.id.uuidString))
        #expect(message.contains("'flip-pass'"))
        #expect(message.contains("beat 4"))          // whole beats print without ".0"
        #expect(message.contains("overwrite: true"))
        // The refusal anchors on the RESIDENT — a clip still in the project, so
        // the app's amber bubble has a block to land on (m23-am).
        #expect(error.refusalAnchorClipID == resident.id)
    }
}
