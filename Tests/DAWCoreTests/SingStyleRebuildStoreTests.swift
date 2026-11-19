import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x5, the store half: every edit that rebuilds a melody clip carries its singing style, one test per row
/// of W8-X5M's census (split, the trim engine, `reidentified` via duplicate and paste, the overlap trim,
/// `clipAfterInsert`, `clipAfterDelete`, take comp and flatten, a move, the store's own save and reopen, and the
/// looper's re-tile, the one site with no old→new note map). Plus `landSungVocal(pitchEdits:)` and the dirty mark
/// `recordSungVocalChecks` now sets.
///
/// THE RULE (design §5.3, `SingStyle`'s note): each clip that comes out keeps the clip-wide choices and the
/// per-note choices of exactly the notes it holds. Every rebuild site keeps note ids, so a choice goes with its
/// note; a site that dropped the per-note choices silently would leave a healthy-looking clip-wide style behind,
/// which is why each test checks the per-note half by id.
///
/// ⚠️ APPENDED to the existing `@MainActor` suite `ProjectStoreClipEditTests` (`ClipEditTests.swift`,
/// unmodified) as an extension: the tree is at its `@MainActor` suite cap, and this adds no `@Suite`. Helpers
/// carry an `x5` prefix so they can never collide with the suite's own. There is no style setter yet (x7's
/// `clip.setSingStyle`), so each test writes `Clip.singStyle` directly into `store.tracks`, outside any undo step,
/// the way a reopened project arrives.
@MainActor
extension ProjectStoreClipEditTests {

    private static func x5ID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    /// The style every site test starts from: a clip-wide choice in each field, and a per-note choice on every
    /// note (note k: vibrato wide or straight, air k/10, so note 0's choice is an explicit air of 0).
    private static func x5Style(_ noteIDs: [UUID]) -> SingStyle {
        var choices: [UUID: NoteSingStyle] = [:]
        for (k, id) in noteIDs.enumerated() {
            choices[id] = NoteSingStyle(vibrato: k.isMultiple(of: 2) ? .wide : .straight, air: Double(k) / 10)
        }
        return SingStyle(vibrato: .gentle, air: 0.25, followVelocity: true, notes: choices)
    }

    /// What a piece holding the notes `held` must carry: `full` with only those notes' choices. Built by filtering
    /// the map here, NOT through `SingStyle.keepingOverrides`, so a bug there cannot agree with itself.
    private static func x5Expected(_ full: SingStyle, holding held: [UUID]) -> SingStyle? {
        var out = full
        let kept = (full.notes ?? [:]).filter { held.contains($0.key) }
        out.notes = kept.isEmpty ? nil : kept
        return out
    }

    /// A store with one instrument track holding one styled melody clip at beat 0; note k is `x5ID(100 + k)`.
    private static func x5Store(onsets: [Double] = [0, 2, 4, 6], length: Double = 8, lengths: Double = 1)
        throws -> (store: ProjectStore, trackID: UUID, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let notes = onsets.enumerated().map {
            MIDINote(id: x5ID(100 + $0.offset), pitch: 60 + $0.offset, startBeat: $0.element, lengthBeats: lengths)
        }
        let added = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0, lengthBeats: length,
                                          notes: notes)
        let t = try #require(store.tracks.firstIndex { $0.id == track.id })
        let c = try #require(store.tracks[t].clips.firstIndex { $0.id == added.id })
        #expect(store.tracks[t].clips[c].notes?.map(\.id) == notes.map(\.id), "control: the store kept the note ids")
        store.tracks[t].clips[c].singStyle = x5Style(notes.map(\.id))
        return (store, track.id, store.tracks[t].clips[c])
    }

    private static func x5Clips(_ store: ProjectStore) -> [Clip] {
        store.tracks.flatMap { $0.clips }.sorted { $0.startBeat < $1.startBeat }
    }

    private static func x5Held(_ clip: Clip) -> [UUID] { (clip.notes ?? []).map(\.id) }

    // MARK: - Split: one clip in, two out

    @Test("p2-sing-x5 split: each half keeps the clip-wide style and its OWN notes' choices; undo restores exactly")
    func x5SplitPartitionsChoices() throws {
        let (store, trackID, clip) = try Self.x5Store()
        let full = try #require(clip.singStyle)
        let before = store.tracks

        let (first, second) = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: 4)
        #expect(Self.x5Held(first) == [Self.x5ID(100), Self.x5ID(101)], "control: ids survive the split")
        #expect(Self.x5Held(second) == [Self.x5ID(102), Self.x5ID(103)])
        #expect(first.singStyle == Self.x5Expected(full, holding: Self.x5Held(first)))
        #expect(second.singStyle == Self.x5Expected(full, holding: Self.x5Held(second)))
        #expect(first.singStyle?.orphanedNoteIDs(in: first.notes) == [], "no half reports its sibling's notes")
        #expect(second.singStyle?.orphanedNoteIDs(in: second.notes) == [])
        #expect(Self.x5Clips(store).map(\.singStyle) == [first.singStyle, second.singStyle],
                "what the store holds is what split returned")
        _ = try store.undo()
        #expect(store.tracks == before)

        // A cut inside a note: the note stays left (truncated), and its choice goes with it.
        let (left, right) = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: 4.5)
        #expect(Self.x5Held(left) == [Self.x5ID(100), Self.x5ID(101), Self.x5ID(102)])
        #expect(left.singStyle == Self.x5Expected(full, holding: Self.x5Held(left)))
        #expect(right.singStyle == Self.x5Expected(full, holding: [Self.x5ID(103)]))
    }

    // MARK: - One clip in, one out: the notes it still holds keep their choices

    @Test("p2-sing-x5 trim and fit-to-content (the trim engine): surviving notes keep their choices; a dropped note's goes with it")
    func x5TrimsKeepSurvivingChoices() throws {
        let (store, trackID, clip) = try Self.x5Store()
        let full = try #require(clip.singStyle)
        let trimmed = try store.trimClip(trackId: trackID, clipId: clip.id, newStartBeat: 3, newLengthBeats: 5)
        #expect(Self.x5Held(trimmed) == [Self.x5ID(102), Self.x5ID(103)], "control: the trim dropped two notes")
        #expect(trimmed.singStyle == Self.x5Expected(full, holding: Self.x5Held(trimmed)))
        _ = try store.undo()
        #expect(Self.x5Clips(store).first?.singStyle == full, "undo brings the dropped notes' choices back")

        let (wide, wideTrack, wideClip) = try Self.x5Store(length: 16)
        let fitted = try wide.fitClipToContent(trackId: wideTrack, clipId: wideClip.id)
        #expect(fitted.changed, "control: fit moved an edge")
        #expect(fitted.clip.singStyle == wideClip.singStyle, "every note survived, so every choice did")
    }

    @Test("p2-sing-x5 duplicate and paste (reidentified): the copy keeps the whole style, its notes keep their ids")
    func x5CopiesKeepTheStyle() throws {
        let (store, trackID, clip) = try Self.x5Store()
        let duplicated = try store.duplicateClip(clipId: clip.id, toStartBeat: 16)
        #expect(duplicated.clip.id != clip.id)
        #expect(Self.x5Held(duplicated.clip) == Self.x5Held(clip), "control: a copy's notes keep their ids")
        #expect(duplicated.clip.singStyle == clip.singStyle)
        let outcomes = try store.pasteClips([ClipPasteLanding(clip: clip, targetTrackID: trackID, startBeat: 32)])
        let pasted = try #require(outcomes.first?.clip)
        #expect(pasted.id != clip.id)
        #expect(pasted.singStyle == clip.singStyle)
        #expect(Self.x5Clips(store).map(\.singStyle) == [clip.singStyle, clip.singStyle, clip.singStyle])
    }

    @Test("p2-sing-x5 a clip trimmed because another clip landed on it (clipTrimmedToWindow) keeps its notes' choices")
    func x5OverlapTrimKeepsChoices() throws {
        let (store, trackID, clip) = try Self.x5Store()
        let full = try #require(clip.singStyle)
        let other = try store.addMIDIClip(toTrack: trackID, name: "Other", atBeat: 16, lengthBeats: 4,
                                          notes: [MIDINote(pitch: 72, startBeat: 0, lengthBeats: 1)])
        let moved = try store.moveClip(trackId: trackID, clipId: other.id, toStartBeat: 6)
        #expect(moved.trimmedClipIDs == [clip.id], "control: the melody was trimmed")
        let melody = try #require(store.tracks.flatMap { $0.clips }.first { $0.id == clip.id })
        #expect(Self.x5Held(melody) == [Self.x5ID(100), Self.x5ID(101), Self.x5ID(102)])
        #expect(melody.singStyle == Self.x5Expected(full, holding: Self.x5Held(melody)))
    }

    @Test("p2-sing-x5 a moved clip (a value copy, no rebuild) keeps its style, along the timeline and across tracks")
    func x5MoveKeepsTheStyle() throws {
        let (store, trackID, clip) = try Self.x5Store()
        let other = store.addTrack(kind: .instrument)
        let along = try store.moveClip(trackId: trackID, clipId: clip.id, toStartBeat: 12)
        #expect(along.clip.singStyle == clip.singStyle)
        _ = try store.moveClips(ids: [clip.id], toTrackId: other.id)
        let landed = try #require(store.tracks.first { $0.id == other.id }?.clips.first)
        #expect(landed.id == clip.id, "control: it moved tracks")
        #expect(landed.singStyle == clip.singStyle)
    }

    // MARK: - Bars inserted or deleted through a clip: a split in disguise

    @Test("p2-sing-x5 insert bars through a clip (clipAfterInsert): head and tail each keep their own notes' choices")
    func x5InsertBarsPartitionsChoices() throws {
        let (store, _, clip) = try Self.x5Store()
        let full = try #require(clip.singStyle)
        let before = store.tracks
        try store.insertBars(atBar: 2, count: 1)                    // at beat 4, 4 beats
        let clips = Self.x5Clips(store)
        #expect(clips.map(\.startBeat) == [0, 8], "control: the clip was cut at beat 4 and its tail pushed right")
        #expect(clips.map(Self.x5Held) == [[Self.x5ID(100), Self.x5ID(101)], [Self.x5ID(102), Self.x5ID(103)]])
        #expect(clips.map(\.singStyle) == clips.map { Self.x5Expected(full, holding: Self.x5Held($0)) })
        _ = try store.undo()
        #expect(store.tracks == before)
    }

    @Test("p2-sing-x5 insert bars: a note the pivot cuts sits in BOTH pieces under one id, and both keep its choice")
    func x5InsertBarsStraddlingNoteKeepsItsChoiceInBoth() throws {
        let (store, _, clip) = try Self.x5Store(onsets: [0, 2, 3.5, 6])   // note 102 spans beats 3.5..<4.5
        let full = try #require(clip.singStyle)
        try store.insertBars(atBar: 2, count: 1)
        let clips = Self.x5Clips(store)
        #expect(clips.count == 2)
        #expect(clips.map(Self.x5Held) == [[Self.x5ID(100), Self.x5ID(101), Self.x5ID(102)],
                                          [Self.x5ID(102), Self.x5ID(103)]], "control: 102 is in both pieces")
        #expect(clips.allSatisfy { $0.singStyle?.notes?[Self.x5ID(102)] == full.notes?[Self.x5ID(102)] })
        #expect(clips.map(\.singStyle) == clips.map { Self.x5Expected(full, holding: Self.x5Held($0)) })
    }

    @Test("p2-sing-x5 delete bars through a clip (clipAfterDelete): head and tail keep their notes' choices; the deleted notes' go, in the same undo step")
    func x5DeleteBarsPartitionsChoices() throws {
        let (store, _, clip) = try Self.x5Store(onsets: [0, 2, 4, 6, 8, 10], length: 12)
        let full = try #require(clip.singStyle)
        let before = store.tracks
        let history = store.undoHistory().undo
        try store.deleteBars(fromBar: 2, count: 1)                  // beats 4..<8: notes 102 and 103
        let clips = Self.x5Clips(store)
        #expect(clips.map(Self.x5Held) == [[Self.x5ID(100), Self.x5ID(101)], [Self.x5ID(104), Self.x5ID(105)]])
        #expect(clips.map(\.singStyle) == clips.map { Self.x5Expected(full, holding: Self.x5Held($0)) })
        #expect(store.undoHistory().undo.count == history.count + 1, "ONE undo step")
        _ = try store.undo()
        #expect(store.tracks == before, "undo brings every choice back")

        // Only the tail survives: it keeps the clip's id and its own notes' choices.
        try store.deleteBars(fromBar: 1, count: 1)                  // beats 0..<4
        let tail = Self.x5Clips(store)
        #expect(tail.map(\.id) == [clip.id])
        #expect(tail.first?.singStyle == Self.x5Expected(full, holding: Self.x5Held(try #require(tail.first))))
    }

    // MARK: - Take comp and flatten

    @Test("p2-sing-x5 take comp and flatten: members carry their own take's style for their window; lanes keep it whole")
    func x5TakeCompAndFlatten() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let t = try #require(store.tracks.firstIndex { $0.id == track.id })
        func takeNotes(_ base: Int) -> [MIDINote] {
            [0.0, 1, 2, 3].enumerated().map {
                MIDINote(id: Self.x5ID(base + $0.offset), pitch: 60, startBeat: $0.element, lengthBeats: 1)
            }
        }
        let styleA = Self.x5Style(takeNotes(200).map(\.id))
        let styleB = SingStyle(vibrato: .straight, notes: [Self.x5ID(302): NoteSingStyle(air: 1)])
        let a = Clip(name: "A", lengthBeats: 4, notes: takeNotes(200), singStyle: styleA)
        let b = Clip(name: "B", lengthBeats: 4, notes: takeNotes(300), singStyle: styleB)
        store.tracks[t].clips = [a, b]                              // two stacked takes, as a loop recording lands them
        let group = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        func members() -> [Clip] {
            store.tracks[t].clips.filter { $0.takeGroupID == group.id }.sorted { $0.startBeat < $1.startBeat }
        }
        #expect(members().map(\.singStyle) == [styleB], "default comp: the newest take, whole")

        try store.setCompSegments(trackId: track.id, groupId: group.id,
                                  segments: [CompSegment(laneID: group.lanes[0].id, startBeat: 0, endBeat: 2),
                                             CompSegment(laneID: group.lanes[1].id, startBeat: 2, endBeat: 4)])
        let comped = members()
        #expect(comped.map(Self.x5Held) == [[Self.x5ID(200), Self.x5ID(201)], [Self.x5ID(302), Self.x5ID(303)]])
        #expect(comped.map(\.singStyle) == [Self.x5Expected(styleA, holding: [Self.x5ID(200), Self.x5ID(201)]),
                                            styleB])
        let lanes = store.tracks[t].takeGroups.first?.lanes.map { $0.clip.singStyle }
        #expect(lanes == [styleA, styleB], "the lanes keep their whole style")

        let freed = try store.flattenTakeGroup(trackId: track.id, groupId: group.id)
        #expect(freed.sorted { $0.startBeat < $1.startBeat }.map(\.singStyle) == comped.map(\.singStyle))
    }

    // MARK: - The store's own save and reopen

    @Test("p2-sing-x5 a style survives the store's save and reopen, on a timeline clip and on a take lane")
    func x5SaveAndReopen() throws {
        let (store, trackID, clip) = try Self.x5Store()
        let laneNotes = [MIDINote(id: Self.x5ID(500), pitch: 64, startBeat: 0, lengthBeats: 2)]
        let laneStyle = SingStyle(air: 0.75, notes: [Self.x5ID(500): NoteSingStyle(vibrato: .asSung)])
        let one = Clip(name: "Take 1", startBeat: 20, lengthBeats: 4, notes: laneNotes, singStyle: laneStyle)
        let two = Clip(name: "Take 2", startBeat: 20, lengthBeats: 4, notes: laneNotes)
        let t = try #require(store.tracks.firstIndex { $0.id == trackID })
        store.tracks[t].clips += [one, two]
        let group = try store.groupTakes(trackId: trackID, clipIds: [one.id, two.id])

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x5-style-reopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Styled").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let melody = reopened.tracks.flatMap { $0.clips }.first { $0.id == clip.id }
        #expect(melody?.singStyle == clip.singStyle)
        let lanes = reopened.tracks.flatMap { $0.takeGroups }.first { $0.id == group.id }?.lanes
        #expect(lanes?.map { $0.clip.singStyle } == [laneStyle, nil])
    }

    // MARK: - The looper: the one site that RE-MINTS note ids, with no map

    @Test("p2-sing-x5 the looper's re-tile keeps the clip-wide style; its fresh note ids leave per-note choices orphaned, and reported")
    func x5LooperRetileOrphansPerNoteChoices() throws {
        let engine = FakeDeckEngine()
        let store = ProjectStore(projectName: "x5 deck")
        store.engine = engine
        let track = store.addTrack(name: "Lead", kind: .instrument)
        store.play()
        engine.playheadHandler?(0)
        _ = try store.beginLoopDeck(bars: 1, horizonCycles: 4)
        // One pass, the `LoopDeckStoreTests.recordLayer` steps (arm, start, finish, close, land).
        _ = try store.armLoopLayer(trackID: track.id)
        let launch = try #require(store.loopDeckStatus?.pendingLaunchBeat)
        let armBeat = try #require(store.loopDeck?.pending?.armBeat)
        engine.playheadHandler?(armBeat)
        store.applyDueDeckActions()
        let cycle = try #require(store.loopDeck?.cycleBeats)
        engine.playheadHandler?(launch + cycle - 0.5)
        _ = try store.finishLoopLayer()
        let close = try #require(store.loopDeck?.pending?.closeBeat)
        engine.playheadHandler?(close)
        store.applyDueDeckActions()
        engine.landLayer(notes: [MIDINote(pitch: 60, velocity: 100, startBeat: launch - armBeat, lengthBeats: 0.5)])

        let t = try #require(store.tracks.firstIndex { $0.id == track.id })
        let first = try #require(store.tracks[t].clips.first)
        let firstNote = try #require(first.notes?.first?.id)
        store.tracks[t].clips[0].singStyle = SingStyle(vibrato: .wide,
                                                       notes: [firstNote: NoteSingStyle(vibrato: .straight)])

        engine.playheadHandler?(4 + 3 * 4.0)                       // the runway extends: the layer is re-tiled
        store.applyDueDeckActions()
        let after = try #require(store.tracks[t].clips.first)
        #expect(after.id == first.id, "the same clip, rewritten in place")
        #expect((after.notes?.count ?? 0) > (first.notes?.count ?? 0), "control: it was re-tiled")
        #expect(Set(Self.x5Held(after)).isDisjoint(with: Self.x5Held(first)), "every note id was re-minted")
        #expect(after.singStyle?.vibrato == .wide, "the clip-wide choice survives (the value is edited in place)")
        #expect(after.singStyle?.orphanedNoteIDs(in: after.notes) == [firstNote],
                "the per-note choice is orphaned: inert, and reported by orphanedNoteIDs (x7's orphanedNoteIds)")
    }

    // MARK: - landSungVocal(pitchEdits:)

    /// The landed track as JSON with its random ids and copy URL taken out — the shape PB1 captured.
    private static func x5ComparableLanding(_ landed: Track, landing: SungVocalLanding,
                                            sourceClipID: UUID) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var text = String(decoding: try encoder.encode(landed), as: UTF8.self)
        let url = try #require(landed.clips.first?.audioFileURL)
        let urlJSON = String(decoding: try encoder.encode([url]), as: UTF8.self).dropFirst().dropLast()
        text = text.replacingOccurrences(of: String(urlJSON), with: "\"FILE\"")
        text = text.replacingOccurrences(of: landed.id.uuidString, with: "TRACK-ID")
        text = text.replacingOccurrences(of: landing.clipID.uuidString, with: "CLIP-ID")
        text = text.replacingOccurrences(of: sourceClipID.uuidString, with: "SOURCE-CLIP-ID")
        return text
    }

    /// PIN-BEFORE: captured by W8-X5M at 2026-10-06 19:24 PDT (run PB1, heavy-1) on the tree BEFORE
    /// `landSungVocal` had a `pitchEdits` parameter (sha256 a07ee941…, 690 bytes): the track `x5LandingStore`'s
    /// take lands as, normalised by `x5ComparableLanding`.
    static let x5LandingPin = #"{"automation":[],"clips":[{"audioFileURL":"FILE","id":"CLIP-ID","isAIGenerated":true,"lengthBeats":6,"name":"Vocals — Built-in singer","startBeat":3.52}],"effects":[],"id":"TRACK-ID","isAIGenerated":true,"isArmed":false,"isMuted":false,"isSoloed":false,"kind":"audio","name":"Vocals — Built-in singer","pan":0,"sends":[],"sungVocalProvenance":{"cfg":1.5,"engineCommit":"abc1234","engineId":"soulx-singer","facadeVersion":1,"lyricsText":"twin-kle lit-tle","nSteps":32,"octaveShift":0,"renderedAt":811692800,"seed":7,"songTransposeSemitones":0,"sourceClipId":"SOURCE-CLIP-ID","voiceId":"builtin-1","voiceKind":"builtIn","voiceName":"Built-in singer","weightsRevision":"rev-1"},"volume":1}"#

    /// The PB1 capture's store: a stand-in media reader (3 s), a temp Generations folder, a melody with lyrics at
    /// beat 4, a take file, its record, and the plan.
    private static func x5LandingStore() throws
        -> (store: ProjectStore, clip: Clip, take: URL, record: SungVocalProvenance, planning: SungVocalPlanning) {
        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(durationSeconds: 3.0, sampleRate: 48_000, channelCount: 1))
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("x5-sing-dest-\(UUID().uuidString)")
        let track = store.addTrack(kind: .instrument)
        let notes = [0.0, 1, 2, 3].map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: 1) }
        _ = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 4, lengthBeats: 4, notes: notes)
        let t = try #require(store.tracks.firstIndex { $0.id == track.id })
        store.tracks[t].clips[0].lyrics = ClipLyrics(text: "twin-kle lit-tle")
        let clip = store.tracks[t].clips[0]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("x5-sing-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let take = dir.appendingPathComponent("take.wav")
        try Data("RIFF".utf8).write(to: take)
        let record = SungVocalProvenance(
            engineId: "soulx-singer", engineCommit: "abc1234", weightsRevision: "rev-1", facadeVersion: 1,
            voiceId: "builtin-1", voiceName: "Built-in singer", voiceKind: SungVocalProvenance.VoiceKind.builtIn,
            lyricsText: "twin-kle lit-tle", sourceClipId: clip.id, octaveShift: 0,
            seed: 7, nSteps: 32, cfg: 1.5, renderedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let planning = try store.planSungVocal(clipId: clip.id, octaveShift: 0)
        return (store, clip, take, record, planning)
    }

    @Test("p2-sing-x5 landSungVocal with pitchEdits nil (or omitted) lands byte-identical to the pin-before landing")
    func x5LandingWithoutPitchEditsIsByteIdentical() throws {
        let (store, clip, take, record, planning) = try Self.x5LandingStore()
        let omitted = try store.landSungVocal(fileURL: take, trackName: "Vocals — Built-in singer",
                                              atBeat: planning.plan.atBeat, provenance: record,
                                              planned: planning.landingGuard)
        let a = try #require(store.tracks.first { $0.id == omitted.trackID })
        #expect(try Self.x5ComparableLanding(a, landing: omitted, sourceClipID: clip.id) == Self.x5LandingPin)
        _ = try store.undo()
        let explicit = try store.landSungVocal(fileURL: take, trackName: "Vocals — Built-in singer",
                                               atBeat: planning.plan.atBeat, provenance: record,
                                               planned: planning.landingGuard, pitchEdits: nil)
        let b = try #require(store.tracks.first { $0.id == explicit.trackID })
        #expect(try Self.x5ComparableLanding(b, landing: explicit, sourceClipID: clip.id) == Self.x5LandingPin)
        #expect(b.clips.first?.pitchEdits == nil)
        // An EMPTY set is no set (Clip.init's one spelling), so it lands byte-identical too.
        _ = try store.undo()
        let empty = try store.landSungVocal(fileURL: take, trackName: "Vocals — Built-in singer",
                                            atBeat: planning.plan.atBeat, provenance: record,
                                            planned: planning.landingGuard, pitchEdits: .empty)
        let c = try #require(store.tracks.first { $0.id == empty.trackID })
        #expect(try Self.x5ComparableLanding(c, landing: empty, sourceClipID: clip.id) == Self.x5LandingPin)
    }

    @Test("p2-sing-x5 landSungVocal with pitchEdits: the take lands carrying them in ONE undo step, and the engine hears them in that step")
    func x5LandingWithPitchEditsIsOneUndoStep() throws {
        let (store, clip, take, record, planning) = try Self.x5LandingStore()
        // ⭐ The detector for "set INSIDE the same performEdit" (W8-X5M plant 3, measured in rehearsal): undo/redo
        // CANNOT tell, because `undo` snapshots the CURRENT state as the redo entry, so edits written after the
        // edit come back on redo anyway. What can tell is the engine: the landing's ONE `tracksDidChange` must
        // already carry the edits, or the take plays untuned until some later edit happens to re-send the tracks.
        let engine = X5EngineSpy()
        store.engine = engine
        let edits = PitchEditSet(segments: [NoteSegment(id: Self.x5ID(900), startSeconds: 0.5, endSeconds: 1.0,
                                                        detectedHz: 220, detectedConfidence: 0.9,
                                                        pitchOffsetCents: 0, vibratoScale: 0)],
                                 retuneMs: 80)
        #expect(!edits.isEmpty, "control: a real set")
        let before = store.tracks
        let history = store.undoHistory().undo
        let landing = try store.landSungVocal(fileURL: take, trackName: "Vocals", atBeat: planning.plan.atBeat,
                                              provenance: record, planned: planning.landingGuard, pitchEdits: edits)
        let landed = try #require(store.tracks.first { $0.id == landing.trackID }?.clips.first)
        #expect(landed.id == landing.clipID)
        #expect(landed.pitchEdits == edits)
        #expect(store.undoHistory().undo.count == history.count + 1, "exactly ONE new undo step")
        let heard = engine.lastTracks.first { $0.id == landing.trackID }?.clips.first
        #expect(heard?.id == landed.id, "control: the engine was told about the take")
        #expect(heard?.pitchEdits == edits, "the engine heard the take WITH its edits, in the landing's own step")
        #expect(engine.tracksDidChangeCount == 1, "one landing, one engine update")
        #expect(try store.undo() == "Land Sung Vocal")
        #expect(store.tracks == before, "undo removes the take, edits and all")
        #expect(try store.redo() == "Land Sung Vocal")
        let redone = try #require(store.tracks.first { $0.id == landing.trackID }?.clips.first)
        #expect(redone.pitchEdits == edits, "the edits are INSIDE the landing's step: redo brings them back")
        #expect(clip.id != landed.id, "control: the melody is not the take")
    }

    // MARK: - recordSungVocalChecks marks the project dirty (W8-SE1's report)

    @Test("p2-sing-x5 recordSungVocalChecks: a check that lands after a save marks the project dirty (no undo step), and the next save keeps it")
    func x5RecordedChecksMarkTheProjectDirty() throws {
        let (store, _, take, record, planning) = try Self.x5LandingStore()
        let landing = try store.landSungVocal(fileURL: take, trackName: "Vocals", atBeat: planning.plan.atBeat,
                                              provenance: record, planned: planning.landingGuard)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x5-checks-dirty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Checks").path
        try store.saveProject(to: path)
        #expect(!store.isDirty, "control: a genuinely clean project after the save")
        let history = store.undoHistory()

        // A no-op (nothing to write) leaves it clean.
        #expect(store.recordSungVocalChecks(trackId: landing.trackID, projectGeneration: store.projectGeneration,
                                            noteAccuracy: nil, wordCheck: nil))
        #expect(!store.isDirty, "nothing changed, so nothing is unsaved")

        let words = SungWordCheck(state: SungWordCheck.State.checked, wer: 0, heard: "twinkle little",
                                  verdict: "clear")
        #expect(store.recordSungVocalChecks(trackId: landing.trackID, projectGeneration: store.projectGeneration,
                                            noteAccuracy: nil, wordCheck: words))
        #expect(store.isDirty, "the check result is an unsaved change")
        #expect(store.undoHistory() == history, "and still not an undo step")

        try store.saveProject(to: path)
        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let saved = reopened.tracks.first { $0.id == landing.trackID }?.sungVocalProvenance
        #expect(saved?.wordCheck == words, "the save after the check kept it")
    }
}

/// Records the tracks the store hands the audio engine (W8-X5M): the landing test asks whether the ONE
/// `tracksDidChange` of "Land Sung Vocal" already carries the take's pitch edits.
@MainActor
final class X5EngineSpy: AudioEngineControlling {
    private(set) var lastTracks: [Track] = []
    private(set) var tracksDidChangeCount = 0
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    func tracksDidChange(_ tracks: [Track]) {
        lastTracks = tracks
        tracksDidChangeCount += 1
    }
    func prepare() throws {}
    func shutdown() {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double, to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) { completion(true) }
    func setInputDevice(uid: String?) throws {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
}
