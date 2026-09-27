import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d1b, the store half: every edit that rebuilds a melody clip carries
/// its lyrics, one test per rebuild site of W7-SD2's census (split, the trim
/// engine, `reidentified` via duplicate and paste, the overlap trim,
/// `clipAfterInsert`, `clipAfterDelete`, take flatten, and the store's own
/// save and reopen).
///
/// ⚠️ These are APPENDED to the existing `@MainActor` suite
/// `ProjectStoreClipEditTests` (`ClipEditTests.swift`, unmodified) as an
/// extension, because the tree is at its `@MainActor` suite cap: no `@Suite`
/// line here, so no new suite. Helpers carry an `lyric` prefix so they can
/// never collide with the suite's own private helpers.
///
/// There is no lyrics setter yet (p2-sing-e adds `clip.setLyrics`), so each
/// test writes `Clip.lyrics` directly into `store.tracks`, outside any undo
/// step, the way a reopened project arrives.
@MainActor
extension ProjectStoreClipEditTests {

    /// A store with one instrument track holding one melody clip at beat 0:
    /// one-beat notes at `onsets` (a one-beat rest between them makes each its
    /// own breath phrase, so one word lands on each note).
    private static func lyricStore(onsets: [Double] = [0, 2, 4, 6], length: Double = 8,
                                   text: String = "one two three four")
        throws -> (store: ProjectStore, trackID: UUID, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let notes = onsets.map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: 1) }
        let added = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0, lengthBeats: length,
                                          notes: notes)
        let clip = try lyricSet(store, clipID: added.id, text: text)
        return (store, track.id, clip)
    }

    /// Writes `text` onto a clip directly (no setter exists yet) and returns it.
    @discardableResult
    private static func lyricSet(_ store: ProjectStore, clipID: UUID, text: String) throws -> Clip {
        for t in store.tracks.indices {
            if let c = store.tracks[t].clips.firstIndex(where: { $0.id == clipID }) {
                store.tracks[t].clips[c].lyrics = ClipLyrics(text: text)
                return store.tracks[t].clips[c]
            }
        }
        throw ProjectError.clipNotFound(clipID)
    }

    private static func lyricClips(_ store: ProjectStore) -> [Clip] {
        store.tracks.flatMap { $0.clips }.sorted { $0.startBeat < $1.startBeat }
    }

    private static func lyricTexts(_ clips: [Clip]) -> [String?] {
        clips.map { $0.lyrics?.text }
    }

    private static func lyricBytes(_ tracks: [Track]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(tracks)
    }

    // MARK: - Split

    @Test("p2-sing-d1b split: each half keeps the words that START on its notes; undo restores the text exactly")
    func lyricsSplitBothWaysAndUndo() throws {
        let (store, trackID, clip) = try Self.lyricStore()
        let before = store.tracks
        let bytes = try Self.lyricBytes(before)

        let (first, second) = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: 4)
        #expect(first.lyrics == ClipLyrics(text: "one two"))
        #expect(second.lyrics == ClipLyrics(text: "three four"))
        let stored = Self.lyricTexts(Self.lyricClips(store))
        #expect(stored == ["one two", "three four"], "what the store holds is what split returned")

        #expect(try store.undo() == "Split Clip 'Melody'")
        #expect(store.tracks == before)
        #expect(try Self.lyricBytes(store.tracks) == bytes, "the Codable round trip of the restored tracks")

        // The other way: a cut inside "three"'s note leaves "three" on the left.
        let (left, right) = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: 4.5)
        #expect(left.lyrics == ClipLyrics(text: "one two three"))
        #expect(right.lyrics == ClipLyrics(text: "four"))
    }

    @Test("p2-sing-d1b split: text that cannot be placed stays whole on the left half")
    func lyricsUnplaceableTextStaysLeft() throws {
        let (store, trackID, clip) = try Self.lyricStore(text: "one two three four five")   // 5 words, 4 notes
        let (first, second) = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: 4)
        #expect(first.lyrics == ClipLyrics(text: "one two three four five"))
        #expect(second.lyrics == nil)
    }

    // MARK: - One clip in, one clip out: the text is kept exactly

    @Test("p2-sing-d1b trim and fit-to-content (the trim engine) keep the text exactly")
    func lyricsTrimsKeepText() throws {
        let (store, trackID, clip) = try Self.lyricStore()
        let trimmed = try store.trimClip(trackId: trackID, clipId: clip.id, newStartBeat: 3, newLengthBeats: 5)
        #expect(trimmed.notes?.count == 2, "control: the trim dropped two notes")
        #expect(trimmed.lyrics == clip.lyrics)
        let fitted = try store.fitClipToContent(trackId: trackID, clipId: clip.id)
        #expect(fitted.changed, "control: fit moved an edge")
        #expect(fitted.clip.lyrics == clip.lyrics)
    }

    @Test("p2-sing-d1b duplicate and paste (reidentified) copy the text; the source keeps its own")
    func lyricsCopiesKeepText() throws {
        let (store, trackID, clip) = try Self.lyricStore()
        let duplicated = try store.duplicateClip(clipId: clip.id, toStartBeat: 16)
        #expect(duplicated.clip.id != clip.id)
        #expect(duplicated.clip.lyrics == clip.lyrics)
        let outcomes = try store.pasteClips([ClipPasteLanding(clip: clip, targetTrackID: trackID, startBeat: 32)])
        let pasted = try #require(outcomes.first?.clip)
        #expect(pasted.id != clip.id)
        #expect(pasted.lyrics == clip.lyrics)
        let texts = Self.lyricTexts(Self.lyricClips(store))
        #expect(texts == ["one two three four", "one two three four", "one two three four"])
    }

    @Test("p2-sing-d1b a clip trimmed because another clip landed on it (clipTrimmedToWindow) keeps its text")
    func lyricsOverlapTrimKeepsText() throws {
        let (store, trackID, clip) = try Self.lyricStore()
        let other = try store.addMIDIClip(toTrack: trackID, name: "Other", atBeat: 16, lengthBeats: 4,
                                          notes: [MIDINote(pitch: 72, startBeat: 0, lengthBeats: 1)])
        let moved = try store.moveClip(trackId: trackID, clipId: other.id, toStartBeat: 6)
        #expect(moved.trimmedClipIDs == [clip.id], "control: the melody was trimmed")
        let melody = try #require(store.tracks.flatMap { $0.clips }.first { $0.id == clip.id })
        #expect(melody.lengthBeats == 6)
        #expect(melody.lyrics == clip.lyrics)
    }

    // MARK: - Bars inserted or deleted through a clip: a split in disguise

    @Test("p2-sing-d1b insert bars through a clip (clipAfterInsert): head and tail share the words; undo restores")
    func lyricsInsertBarsSplitsText() throws {
        let (store, _, clip) = try Self.lyricStore()
        let before = store.tracks
        try store.insertBars(atBar: 2, count: 1)                    // at beat 4, 4 beats
        let clips = Self.lyricClips(store)
        let starts = clips.map { $0.startBeat }
        #expect(starts == [0, 8], "control: the clip was cut at beat 4 and its tail pushed right")
        #expect(clips.first?.id == clip.id)
        #expect(Self.lyricTexts(clips) == ["one two", "three four"])
        _ = try store.undo()
        #expect(store.tracks == before)
    }

    @Test("p2-sing-d1b delete bars through a clip (clipAfterDelete): the tail keeps the deleted words, as a trim")
    func lyricsDeleteBarsSplitsText() throws {
        let (store, _, clip) = try Self.lyricStore(onsets: [0, 2, 4, 6, 8, 10], length: 12,
                                                   text: "one two three four five six")
        let before = store.tracks
        try store.deleteBars(fromBar: 2, count: 1)                  // beats 4..<8
        let clips = Self.lyricClips(store)
        let notes = clips.map { $0.notes?.count ?? 0 }
        #expect(notes == [2, 2], "control: head and tail both survived")
        // The words sung on the deleted notes go with the tail: the split rule
        // at the delete's start, then the tail's leading edge is a trim, which
        // keeps text (the sing-time W > N refusal says so, nothing is lost).
        #expect(Self.lyricTexts(clips) == ["one two", "three four five six"])
        _ = try store.undo()
        #expect(store.tracks == before)

        // One survivor is a trim: it keeps everything.
        try store.deleteBars(fromBar: 3, count: 1)                  // beats 8..<12: no tail survives
        let only = Self.lyricClips(store)
        #expect(only.count == 1)
        #expect(only.first?.lyrics == clip.lyrics)
    }

    // MARK: - Take comp and flatten

    @Test("p2-sing-d1b take comp and flatten: members carry their own take's words, none twice, none lost")
    func lyricsTakeFlatten() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let t = try #require(store.tracks.firstIndex { $0.id == track.id })
        func takeNotes() -> [MIDINote] { [0.0, 1, 2, 3].map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: 1) } }
        let a = Clip(name: "A", lengthBeats: 4, notes: takeNotes(), lyrics: ClipLyrics(text: "one two three four"))
        let b = Clip(name: "B", lengthBeats: 4, notes: takeNotes(), lyrics: ClipLyrics(text: "uno dos tres cuatro"))
        store.tracks[t].clips = [a, b]                              // two stacked takes, as a loop recording lands them
        let group = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])

        func members() -> [Clip] {
            store.tracks[t].clips.filter { $0.takeGroupID == group.id }.sorted { $0.startBeat < $1.startBeat }
        }
        #expect(Self.lyricTexts(members()) == ["uno dos tres cuatro"], "default comp: the newest take, whole")

        try store.setCompSegments(trackId: track.id, groupId: group.id,
                                  segments: [CompSegment(laneID: group.lanes[0].id, startBeat: 0, endBeat: 2),
                                             CompSegment(laneID: group.lanes[1].id, startBeat: 2, endBeat: 4)])
        #expect(Self.lyricTexts(members()) == ["one two", "tres cuatro"])
        let lanes = store.tracks[t].takeGroups.first?.lanes.map { $0.clip.lyrics?.text }
        #expect(lanes == ["one two three four", "uno dos tres cuatro"], "the lanes keep their whole text")

        let freed = try store.flattenTakeGroup(trackId: track.id, groupId: group.id)
        let freedTexts = Self.lyricTexts(freed.sorted { $0.startBeat < $1.startBeat })
        #expect(freedTexts == ["one two", "tres cuatro"])
        #expect(store.tracks[t].takeGroups.isEmpty)
    }

    // MARK: - The store's own save and reopen

    @Test("p2-sing-d1b + d2: lyrics and a sung-vocal record survive the store's save and reopen")
    func lyricsSaveAndReopen() throws {
        let (store, _, clip) = try Self.lyricStore(text: "twin-kle +\nlit-tle star")
        let vocal = store.addTrack(name: "Vocals — Built-in singer", kind: .audio)
        let record = SungVocalProvenance(
            engineId: "soulx-singer", engineCommit: "abc1234", weightsRevision: "rev-1", facadeVersion: 1,
            voiceId: "builtin-1", voiceName: "Built-in singer", voiceKind: SungVocalProvenance.VoiceKind.builtIn,
            lyricsText: "twin-kle +\nlit-tle star", sourceClipId: clip.id, octaveShift: -1, seed: 7, nSteps: 32,
            cfg: 1.5, renderedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let v = try #require(store.tracks.firstIndex { $0.id == vocal.id })
        store.tracks[v].sungVocalProvenance = record

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd2-lyrics-reopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Sung").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let melody = reopened.tracks.flatMap { $0.clips }.first { $0.id == clip.id }
        #expect(melody?.lyrics == ClipLyrics(text: "twin-kle +\nlit-tle star"))
        let sung = reopened.tracks.first { $0.id == vocal.id }
        #expect(sung?.sungVocalProvenance == record)
    }
}
