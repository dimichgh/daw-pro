import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d2: `ProjectStore.planSungVocal` and `landSungVocal` (design §4.5).
/// A finished take lands as ONE violet AI track with one clip, in ONE undo step
/// that removes it exactly; a take planned in another project never lands.
///
/// ⚠️ APPENDED to the existing `@MainActor` suite `ProjectStoreClipEditTests`
/// (`ClipEditTests.swift`, unmodified) as an extension: the tree is at its
/// `@MainActor` suite cap, and this adds no `@Suite`. Helpers carry a `sing`
/// prefix so they can never collide with the suite's own.
@MainActor
extension ProjectStoreClipEditTests {

    /// A store with a stand-in media reader (every file reads as 3 s), a temp
    /// Generations folder, and one melody clip with lyrics at beat 4.
    private static func singStore() throws -> (store: ProjectStore, clip: Clip) {
        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(durationSeconds: 3.0, sampleRate: 48_000, channelCount: 1))
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sd2-sing-dest-\(UUID().uuidString)")
        let track = store.addTrack(kind: .instrument)
        let notes = [0.0, 1, 2, 3].map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: 1) }
        let added = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 4, lengthBeats: 4, notes: notes)
        return (store, try singSetLyrics(store, clipID: added.id, text: "twin-kle lit-tle"))
    }

    private static func singSetLyrics(_ store: ProjectStore, clipID: UUID, text: String) throws -> Clip {
        for t in store.tracks.indices {
            if let c = store.tracks[t].clips.firstIndex(where: { $0.id == clipID }) {
                store.tracks[t].clips[c].lyrics = ClipLyrics(text: text)
                return store.tracks[t].clips[c]
            }
        }
        throw ProjectError.clipNotFound(clipID)
    }

    /// A finished take on disk: a minimal valid WAV in a fresh temp folder
    /// (`FakeMedia` never reads it; a real header keeps the fixture honest).
    private static func singTake() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sd2-sing-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("take.wav")
        var data = Data()
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        data.append(Data("RIFF".utf8)); data.append(le32(36 + 16)); data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8)); data.append(le32(16)); data.append(le16(1)); data.append(le16(1))
        data.append(le32(48_000)); data.append(le32(96_000)); data.append(le16(2)); data.append(le16(16))
        data.append(Data("data".utf8)); data.append(le32(16)); data.append(Data(repeating: 0, count: 16))
        try data.write(to: url)
        return url
    }

    private static func singRecord(for clip: Clip, octaveShift: Int = 0) -> SungVocalProvenance {
        SungVocalProvenance(
            engineId: "soulx-singer", engineCommit: "abc1234", weightsRevision: "rev-1", facadeVersion: 1,
            voiceId: "builtin-1", voiceName: "Built-in singer", voiceKind: SungVocalProvenance.VoiceKind.builtIn,
            lyricsText: clip.lyrics?.text ?? "", sourceClipId: clip.id, octaveShift: octaveShift,
            seed: 7, nSteps: 32, cfg: 1.5, renderedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    private static func singBytes(_ tracks: [Track]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(tracks)
    }

    @Test("p2-sing-d2 landSungVocal: ONE violet AI track with one clip at the planned beat, in ONE undo step")
    func singLandsOneTrackInOneUndoStep() throws {
        let (store, clip) = try Self.singStore()
        let planning = try store.planSungVocal(clipId: clip.id, octaveShift: 0)
        #expect(planning.landingGuard.projectGeneration == store.projectGeneration)
        #expect(planning.landingGuard.signature == planning.plan.signature)
        let before = store.tracks
        let bytes = try Self.singBytes(before)
        let history = store.undoHistory().undo

        let name = ProjectStore.sungVocalTrackName(voiceName: "Built-in singer")
        let record = Self.singRecord(for: clip)
        let landing = try store.landSungVocal(fileURL: try Self.singTake(), trackName: name,
                                              atBeat: planning.plan.atBeat, provenance: record,
                                              planned: planning.landingGuard)
        #expect(landing.melodyChanged == false)
        #expect(landing.notice == nil)
        #expect(store.tracks.count == before.count + 1)
        let track = try #require(store.tracks.last)
        #expect(track.id == landing.trackID)
        #expect(track.name == "Vocals — Built-in singer")
        #expect(track.kind == .audio)
        #expect(track.isAIGenerated, "violet always means AI-generated")
        #expect(track.sungVocalProvenance == record)
        #expect(track.clips.count == 1)
        let take = try #require(track.clips.first)
        #expect(take.id == landing.clipID)
        #expect(take.isAIGenerated)
        #expect(abs(take.startBeat - planning.plan.atBeat) < 1e-12)
        #expect(abs(planning.plan.atBeat - 3.52) < 1e-9, "one lead (0.24 s) before the melody at beat 4")
        #expect(abs(take.lengthBeats - 6) < 1e-9, "3 s at 120 BPM")
        let copied = try #require(take.audioFileURL)
        #expect(copied.path.hasPrefix(store.generationImportsDirectory.path), "a stable copy, like a conversion's")
        #expect(FileManager.default.fileExists(atPath: copied.path))

        let after = store.undoHistory().undo
        #expect(after.count == history.count + 1, "exactly ONE new undo step")
        #expect(after.first == "Land Sung Vocal")
        #expect(try store.undo() == "Land Sung Vocal")
        #expect(store.tracks == before, "undo removes the take exactly")
        #expect(try Self.singBytes(store.tracks) == bytes, "and the Codable round trip agrees")
    }

    @Test("p2-sing-d2 landSungVocal: a take planned in another project never lands; it is kept and the error says where")
    func singRefusesAnotherProject() throws {
        let (store, clip) = try Self.singStore()
        let planning = try store.planSungVocal(clipId: clip.id, octaveShift: 0)
        try store.newProject(discardChanges: true)
        #expect(store.projectGeneration != planning.landingGuard.projectGeneration, "control: a new project")
        let before = store.tracks
        let history = store.undoHistory()

        var savedPath: String?
        do {
            try store.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals — Built-in singer",
                                    atBeat: planning.plan.atBeat, provenance: Self.singRecord(for: clip),
                                    planned: planning.landingGuard)
            Issue.record("the take landed in a different project")
        } catch let error as SungVocalLandingError {
            switch error {
            case .projectChanged(let path):
                savedPath = path
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
                #expect(error.errorDescription
                        == "The project was closed before the singing finished. The take is saved in \(folder).")
            }
        }
        #expect(store.tracks == before, "nothing landed")
        #expect(store.undoHistory() == history, "and nothing was journaled")
        let path = try #require(savedPath)
        #expect(FileManager.default.fileExists(atPath: path), "the take is kept")
        #expect(path.hasPrefix(store.generationImportsDirectory.path))
    }

    @Test("p2-sing-d2 landSungVocal: the melody, the words or the tempo changed while singing; it lands with the notice")
    func singNoticesAChangedMelody() throws {
        // A note moved.
        let (store, clip) = try Self.singStore()
        let planning = try store.planSungVocal(clipId: clip.id, octaveShift: 0)
        let t = try #require(store.tracks.firstIndex { $0.clips.contains { $0.id == clip.id } })
        let c = try #require(store.tracks[t].clips.firstIndex { $0.id == clip.id })
        store.tracks[t].clips[c].notes![0].pitch = 62
        let moved = try store.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                            atBeat: planning.plan.atBeat, provenance: Self.singRecord(for: clip),
                                            planned: planning.landingGuard)
        #expect(moved.melodyChanged)
        #expect(moved.notice == "The melody changed while I was singing; this take follows the earlier version.")
        let landed = try #require(store.tracks.first { $0.id == moved.trackID }?.clips.first)
        #expect(abs(landed.startBeat - planning.plan.atBeat) < 1e-12, "it still lands where it was planned")

        // The words changed.
        let (words, wordsClip) = try Self.singStore()
        let wordsPlan = try words.planSungVocal(clipId: wordsClip.id, octaveShift: 0)
        _ = try Self.singSetLyrics(words, clipID: wordsClip.id, text: "twin-kle star +")
        let reworded = try words.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                               atBeat: wordsPlan.plan.atBeat,
                                               provenance: Self.singRecord(for: wordsClip),
                                               planned: wordsPlan.landingGuard)
        #expect(reworded.melodyChanged)

        // The tempo changed.
        let (tempo, tempoClip) = try Self.singStore()
        let tempoPlan = try tempo.planSungVocal(clipId: tempoClip.id, octaveShift: 0)
        try tempo.setTempo(100)
        let retimed = try tempo.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                              atBeat: tempoPlan.plan.atBeat, provenance: Self.singRecord(for: tempoClip),
                                              planned: tempoPlan.landingGuard)
        #expect(retimed.melodyChanged)

        // The melody clip is gone.
        let (gone, goneClip) = try Self.singStore()
        let gonePlan = try gone.planSungVocal(clipId: goneClip.id, octaveShift: 0)
        let g = try #require(gone.tracks.firstIndex { $0.clips.contains { $0.id == goneClip.id } })
        gone.tracks[g].clips.removeAll()
        let orphan = try gone.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                            atBeat: gonePlan.plan.atBeat, provenance: Self.singRecord(for: goneClip),
                                            planned: gonePlan.landingGuard)
        #expect(orphan.melodyChanged)

        // Control: a change the singer cannot hear (velocity) is not a change.
        let (same, sameClip) = try Self.singStore()
        let samePlan = try same.planSungVocal(clipId: sameClip.id, octaveShift: 0)
        let s = try #require(same.tracks.firstIndex { $0.clips.contains { $0.id == sameClip.id } })
        same.tracks[s].clips[0].notes![0].velocity = 20
        let unchanged = try same.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                               atBeat: samePlan.plan.atBeat, provenance: Self.singRecord(for: sameClip),
                                               planned: samePlan.landingGuard)
        #expect(!unchanged.melodyChanged)
        #expect(unchanged.notice == nil)
    }

    @Test("p2-sing-d2 planSungVocal: an unknown clip and the planner's refusals come back as errors, nothing changes")
    func singPlanRefusals() throws {
        let (store, _) = try Self.singStore()
        let before = store.tracks
        let unknown = UUID()
        do {
            _ = try store.planSungVocal(clipId: unknown, octaveShift: 0)
            Issue.record("an unknown clip planned")
        } catch ProjectError.clipNotFound(let id) {
            #expect(id == unknown)
        }
        let drums = store.addTrack(name: "Drums", kind: .instrument)
        let d = try #require(store.tracks.firstIndex { $0.id == drums.id })
        store.tracks[d].instrument = InstrumentDescriptor(kind: .drumSynth)
        let beat = try store.addMIDIClip(toTrack: drums.id, name: "Beat", atBeat: 0, lengthBeats: 4,
                                         notes: [MIDINote(pitch: 36, startBeat: 0, lengthBeats: 1)])
        _ = try Self.singSetLyrics(store, clipID: beat.id, text: "boom")
        #expect(throws: SingPlanRefusal.drumTrack) {
            _ = try store.planSungVocal(clipId: beat.id, octaveShift: 0)
        }
        #expect(store.tracks.count == before.count + 1, "control: only the drum track the test added")
    }
}
