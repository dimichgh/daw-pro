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

    // MARK: - p2-sing-e: the song transposed while singing (design §4.5, amended 2026-09-27 10:10)

    /// A landed track's clip, encoded, with its random id and the copy's
    /// job-derived file name taken out: what two landings of the same take
    /// must agree on byte for byte.
    private static func singComparableClip(_ clip: Clip) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var text = String(decoding: try encoder.encode(clip), as: UTF8.self)
        text = text.replacingOccurrences(of: clip.id.uuidString, with: "CLIP-ID")
        if let file = clip.audioFileURL?.lastPathComponent {
            text = text.replacingOccurrences(of: file, with: "FILE")
        }
        return text
    }

    @Test("p2-sing-e landSungVocal: the song moved +3 while singing; the take lands moved +3 in ONE undo step, with its notice")
    func singLandsMovedWithATransposedSong() throws {
        let (store, clip) = try Self.singStore()
        let planning = try store.planSungVocal(clipId: clip.id, octaveShift: 0)
        #expect(planning.landingGuard.plan == planning.plan, "planSungVocal carries the whole plan in the guard")
        try store.transposeProject(semitones: 3)
        let transposed = store.tracks
        let history = store.undoHistory().undo
        let landing = try store.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                              atBeat: planning.plan.atBeat, provenance: Self.singRecord(for: clip),
                                              planned: planning.landingGuard)
        #expect(!landing.melodyChanged)
        #expect(landing.transposedSemitones == 3)
        #expect(landing.notice
                == "The song moved up 3 half-steps while I was singing, so I moved this take up 3 half-steps to match.")
        let take = try #require(store.tracks.first { $0.id == landing.trackID }?.clips.first)
        #expect(take.pitchShiftSemitones == 3, "what project.transpose would have done had it landed first")
        #expect(abs(take.startBeat - planning.plan.atBeat) < 1e-12)
        #expect(store.undoHistory().undo.count == history.count + 1, "the shift is inside the landing's ONE step")
        #expect(try store.undo() == "Land Sung Vocal")
        #expect(store.tracks == transposed, "undo removes the take, shift and all; the song stays transposed")
    }

    @Test("p2-sing-e landSungVocal: down one half-step reads in the singular and shifts −1")
    func singLandsMovedDownOne() throws {
        let (store, clip) = try Self.singStore()
        let planning = try store.planSungVocal(clipId: clip.id, octaveShift: 0)
        try store.transposeProject(semitones: -1)
        let landing = try store.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                              atBeat: planning.plan.atBeat, provenance: Self.singRecord(for: clip),
                                              planned: planning.landingGuard)
        #expect(landing.transposedSemitones == -1)
        #expect(landing.notice
                == "The song moved down 1 half-step while I was singing, so I moved this take down 1 half-step to match.")
        let take = try #require(store.tracks.first { $0.id == landing.trackID }?.clips.first)
        #expect(take.pitchShiftSemitones == -1)
    }

    @Test("p2-sing-e landSungVocal: Δ = 0 lands byte-identical to the landing before p2-sing-e (a guard with no plan)")
    func singUnmovedLandingIsByteIdentical() throws {
        let (store, clip) = try Self.singStore()
        let planning = try store.planSungVocal(clipId: clip.id, octaveShift: 0)
        let record = Self.singRecord(for: clip)
        let withPlan = try store.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                               atBeat: planning.plan.atBeat, provenance: record,
                                               planned: planning.landingGuard)
        let a = try #require(store.tracks.first { $0.id == withPlan.trackID })
        _ = try store.undo()
        let legacy = SungVocalLandingGuard(projectGeneration: planning.landingGuard.projectGeneration,
                                           signature: planning.landingGuard.signature)
        #expect(legacy.plan == nil, "control: the old guard carries no plan")
        let withoutPlan = try store.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                                  atBeat: planning.plan.atBeat, provenance: record, planned: legacy)
        let b = try #require(store.tracks.first { $0.id == withoutPlan.trackID })
        #expect(withPlan.notice == nil && withoutPlan.notice == nil)
        #expect(withPlan.transposedSemitones == 0 && withoutPlan.transposedSemitones == 0)
        #expect(!withPlan.melodyChanged && !withoutPlan.melodyChanged)
        let clipA = try #require(a.clips.first)
        let clipB = try #require(b.clips.first)
        #expect(try Self.singComparableClip(clipA) == Self.singComparableClip(clipB))
        #expect(clipA.id != clipB.id, "control: the comparison really took two different ids out")
        #expect(a.name == b.name && a.kind == b.kind && a.isAIGenerated == b.isAIGenerated)
        #expect(a.sungVocalProvenance == b.sungVocalProvenance)
    }

    @Test("p2-sing-e landSungVocal: a melody edit AND a transposition fall back to 'melody changed', unmoved")
    func singTransposedAndEditedFallsBack() throws {
        let (store, clip) = try Self.singStore()
        let planning = try store.planSungVocal(clipId: clip.id, octaveShift: 0)
        try store.transposeProject(semitones: 3)
        let t = try #require(store.tracks.firstIndex { $0.clips.contains { $0.id == clip.id } })
        let c = try #require(store.tracks[t].clips.firstIndex { $0.id == clip.id })
        store.tracks[t].clips[c].notes![0].pitch += 1               // one note moved alone, after the song moved
        let landing = try store.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                              atBeat: planning.plan.atBeat, provenance: Self.singRecord(for: clip),
                                              planned: planning.landingGuard)
        #expect(landing.melodyChanged)
        #expect(landing.transposedSemitones == 0)
        #expect(landing.notice == ProjectStore.sungVocalMelodyChangedNotice)
        let take = try #require(store.tracks.first { $0.id == landing.trackID }?.clips.first)
        #expect(take.pitchShiftSemitones == 0)
    }

    @Test("p2-sing-e SungVocalReplanComparison: the same plan, a pure transposition, and every change that is not one")
    func singReplanComparison() throws {
        let (store, clip) = try Self.singStore()
        let plan = try store.planSungVocal(clipId: clip.id, octaveShift: 0).plan
        func compare(_ current: SingPlan?) -> SungVocalReplanComparison {
            SungVocalReplanComparison.compare(planned: plan, current: current)
        }
        func moved(_ by: Int) -> SingPlan {
            var p = plan
            for u in p.units.indices {
                for n in p.units[u].notes.indices {
                    p.units[u].notes[n].midi += by
                    p.units[u].notes[n].sourcePitch += by
                }
            }
            p.signature = "moved \(by)"
            return p
        }
        #expect(compare(plan) == .unchanged)
        #expect(compare(nil) == .changed, "the clip is gone")
        #expect(compare(moved(3)) == .transposed(semitones: 3))
        #expect(compare(moved(-24)) == .transposed(semitones: -24), "the edge of Clip.pitchShiftSemitonesRange")
        #expect(compare(moved(25)) == .changed, "past the range Clip.init would clamp it: off-key, so no shift")

        var oneNote = plan
        oneNote.units[0].notes[0].midi += 2
        oneNote.units[0].notes[0].sourcePitch += 2
        oneNote.signature = "one note"
        #expect(compare(oneNote) == .changed, "one note moved alone is an edit")
        var retimed = moved(2)
        retimed.units[0].notes[0].endSeconds += 0.01
        #expect(compare(retimed) == .changed)
        var reworded = moved(2)
        reworded.units[0].words[0].text = "star"
        #expect(compare(reworded) == .changed)
        var reidentified = moved(2)
        reidentified.units[0].notes[0].noteID = UUID()
        #expect(compare(reidentified) == .changed)
        var octave = moved(12)
        octave.octaveShift = 1
        #expect(compare(octave) == .changed, "another octave shift is another plan")
        var sungOnly = plan
        for n in sungOnly.units[0].notes.indices { sungOnly.units[0].notes[n].midi += 2 }
        sungOnly.signature = "sung only"
        #expect(compare(sungOnly) == .changed, "the sung pitch moved but the melody did not")
        var replaced = moved(2)
        replaced.atBeat += 1
        #expect(compare(replaced) == .changed, "the placement moved")
    }

    @Test("p2-sing-e recordSungVocalChecks: writes into the landed record, outside undo; refuses a gone track or another project")
    func singRecordsChecksAfterLanding() throws {
        let (store, clip) = try Self.singStore()
        let planning = try store.planSungVocal(clipId: clip.id, octaveShift: 0)
        let landing = try store.landSungVocal(fileURL: try Self.singTake(), trackName: "Vocals",
                                              atBeat: planning.plan.atBeat, provenance: Self.singRecord(for: clip),
                                              planned: planning.landingGuard)
        let history = store.undoHistory()
        let notes = SungNoteAccuracy(hitRate: 1, meanAbsErrorCents: 4, voicedCoverage: 0.95, inTune: true)
        let words = SungWordCheck(state: SungWordCheck.State.checked, wer: 0, heard: "twinkle little",
                                  verdict: "clear")
        #expect(store.recordSungVocalChecks(trackId: landing.trackID, projectGeneration: store.projectGeneration,
                                            noteAccuracy: notes, wordCheck: words))
        let record = try #require(store.tracks.first { $0.id == landing.trackID }?.sungVocalProvenance)
        #expect(record.noteAccuracy == notes)
        #expect(record.wordCheck == words)
        #expect(store.undoHistory() == history, "not an undo step")

        #expect(!store.recordSungVocalChecks(trackId: landing.trackID, projectGeneration: store.projectGeneration &+ 1,
                                             noteAccuracy: nil, wordCheck: words), "another project")
        #expect(!store.recordSungVocalChecks(trackId: UUID(), projectGeneration: store.projectGeneration,
                                             noteAccuracy: nil, wordCheck: words), "no such track")
        _ = try store.undo()
        #expect(!store.recordSungVocalChecks(trackId: landing.trackID, projectGeneration: store.projectGeneration,
                                             noteAccuracy: nil, wordCheck: words), "undone")
    }
}
