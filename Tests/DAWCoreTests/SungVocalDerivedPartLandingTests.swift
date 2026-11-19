import Foundation
import Testing
@testable import DAWCore

// W8-X6F: `ProjectStore.landSungVocals` and the two review findings that live in it (W8-RV6, design
// docs/design/2026-10-06-p2-sing-expansion.md §16).
// - S2: a part DERIVED from the melody (a harmony) is derived again at landing, over the tracks and key as they are
//   then, through `SungVocalDerivedPart.derive`, the ONE derivation submit also uses. Changed chords: it still lands,
//   with a notice that names it. Nothing changed, or a pure transposition: no such notice.
// - N4: a copy or a length read that fails partway removes the copies already made and names them.
//
// Nonisolated on purpose (the tree is at its `@MainActor` suite cap): every store call goes through `MainActor.run`.

/// Reads every file as 2 s; throws on call number `failOnCall` (1-based) when set.
final class X6FCountingMedia: MediaImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let failOnCall: Int?

    struct Unreadable: Error, LocalizedError {
        var errorDescription: String? { "The take could not be read." }
    }

    init(failOnCall: Int? = nil) { self.failOnCall = failOnCall }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func audioFileInfo(at url: URL) throws -> AudioFileInfo {
        lock.lock()
        count += 1
        let n = count
        lock.unlock()
        if let failOnCall, n == failOnCall { throw Unreadable() }
        return AudioFileInfo(durationSeconds: 2, sampleRate: 48_000, channelCount: 1)
    }
}

/// A melody clip with words, a chord track under it, and two finished takes on disk (the lead's and a harmony's).
@MainActor
struct X6FHarmonyFixture {
    static let cMajor = SongKey(tonicPitchClass: 0, mode: .major)
    static let spec = HarmonySpec(interval: .third, direction: .above, chordSource: .otherTracks)
    static let cMajorChord = [48, 52, 55]
    static let fMajorChord = [53, 57, 60]

    let root: URL
    let store: ProjectStore
    let melodyID: UUID
    let chordTrackID: UUID
    let generations: URL

    init(_ label: String, media: X6FCountingMedia = X6FCountingMedia()) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("x6f-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        generations = root.appendingPathComponent("generations", isDirectory: true)
        store = ProjectStore()
        store.media = media
        store.generationImportsDirectory = generations
        let melodyTrack = store.addTrack(kind: .instrument)
        let notes = zip([0.0, 1, 2, 3], [60, 62, 64, 65]).map { MIDINote(pitch: $1, startBeat: $0, lengthBeats: 1) }
        let melody = try store.addMIDIClip(toTrack: melodyTrack.id, name: "Melody", atBeat: 4, lengthBeats: 4,
                                           notes: notes)
        melodyID = melody.id
        for t in store.tracks.indices {
            if let c = store.tracks[t].clips.firstIndex(where: { $0.id == melody.id }) {
                store.tracks[t].clips[c].lyrics = ClipLyrics(text: "one two three four")
            }
        }
        let chordTrack = store.addTrack(kind: .instrument)
        chordTrackID = chordTrack.id
        _ = try store.addMIDIClip(toTrack: chordTrack.id, name: "Chords", atBeat: 0, lengthBeats: 16,
                                  notes: Self.cMajorChord.map { MIDINote(pitch: $0, startBeat: 0, lengthBeats: 16) })
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func melody() throws -> (clip: Clip, track: Track) {
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.id == melodyID }) { return (clip, track) }
        }
        throw ProjectError.clipNotFound(melodyID)
    }

    /// The harmony as the job derives it now (`SungVocalDerivedPart.derive`, the one derivation).
    func deriveNow(key: SongKey = cMajor) throws -> HarmonyPlan {
        let (clip, track) = try melody()
        return try SungVocalDerivedPart.derive(.harmony(Self.spec), givenKey: key, partIndex: 1, clip: clip,
                                               on: track, tracks: store.tracks, tempoMap: store.transport.tempoMap)
    }

    func setChord(_ pitches: [Int]) {
        for t in store.tracks.indices where store.tracks[t].id == chordTrackID {
            store.tracks[t].clips[0].notes = pitches.map { MIDINote(pitch: $0, startBeat: 0, lengthBeats: 16) }
        }
    }

    /// A finished take on disk (`X6FCountingMedia` never reads it).
    func takeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).wav")
        try Data("RIFF-x6f-\(name)".utf8).write(to: url)
        return url
    }

    func record(role: String) -> SungVocalProvenance {
        SungVocalProvenance(
            engineId: "soulx-singer", engineCommit: "abc1234", weightsRevision: "rev-1", facadeVersion: 1,
            voiceId: "builtin-1", voiceName: "Built-in singer", voiceKind: SungVocalProvenance.VoiceKind.builtIn,
            lyricsText: "one two three four", sourceClipId: melodyID, octaveShift: 0, seed: 7, nSteps: 32, cfg: 1.5,
            renderedAt: Date(timeIntervalSince1970: 1_790_000_000), partRole: role)
    }

    /// Plans now (the job's submit): the lead's guard, and the lead + harmony takes carrying the harmony's
    /// planned notes.
    func plan() throws -> (guard: SungVocalLandingGuard, takes: [SungVocalTake]) {
        let planning = try store.planSungVocal(clipId: melodyID, octaveShift: 0)
        let harmony = try deriveNow()
        let derived = SungVocalDerivedPart(rule: .harmony(Self.spec), givenKey: Self.cMajor, partIndex: 1,
                                           name: Self.spec.name, plannedNotes: harmony.partNotes)
        let lead = SungVocalTake(fileURL: try takeFile("lead"), trackName: "Vocals", atBeat: planning.plan.atBeat,
                                 provenance: record(role: "lead"))
        let third = SungVocalTake(fileURL: try takeFile("third"), trackName: "Harmony",
                                  atBeat: planning.plan.atBeat, provenance: record(role: "harmony"), pan: 0.3,
                                  derived: derived)
        return (planning.landingGuard, [lead, third])
    }

    func generationFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: generations.path)) ?? []).sorted()
    }
}

@Suite("landSungVocals: a derived part re-derived at landing; partial copies removed (W8-X6F, §16)")
struct SungVocalDerivedPartLandingTests {

    static let drifted = "The chords changed while 'third above' was being sung, so it may not fit now. Sing it again to match."

    @Test("S2: the chords under a harmony change mid-render: it STILL lands, melodyChanged, a notice naming it; the lead does not")
    func chordsChangedHarmonyLandsWithNotice() async throws {
        try await MainActor.run {
            let f = try X6FHarmonyFixture("s2-chords")
            defer { f.cleanup() }
            let (planned, takes) = try f.plan()
            let before = try f.deriveNow().partNotes
            f.setChord(X6FHarmonyFixture.fMajorChord)
            // The positive control: the chord change DOES move the derivation (or this test could not fail).
            #expect(try f.deriveNow().partNotes.map(\.pitch) != before.map(\.pitch))
            let undo = f.store.undoHistory().undo.count
            let landings = try f.store.landSungVocals(takes, planned: planned)
            #expect(landings.count == 2)
            #expect(landings[0].melodyChanged == false && landings[0].notice == nil)
            #expect(landings[1].melodyChanged == true)
            #expect(landings[1].notice == Self.drifted)
            #expect(landings[1].transposedSemitones == 0)
            #expect(f.store.tracks.contains { $0.id == landings[1].trackID }, "it still landed")
            #expect(f.store.undoHistory().undo.count == undo + 1)
            #expect(try f.store.undo() == "Land Sung Harmony")
        }
    }

    @Test("S2 control: nothing changed: both lines land with no notice")
    func nothingChangedNoNotice() async throws {
        try await MainActor.run {
            let f = try X6FHarmonyFixture("s2-same")
            defer { f.cleanup() }
            let (planned, takes) = try f.plan()
            let landings = try f.store.landSungVocals(takes, planned: planned)
            #expect(landings.map(\.melodyChanged) == [false, false])
            #expect(landings.map(\.notice) == [nil, nil])
            #expect(landings.map(\.transposedSemitones) == [0, 0])
        }
    }

    @Test("S2 control: a pure transposition (+2) moves every line by +2 and names no part (the given key moves too)")
    func transpositionMovesEveryLineNoDriftNotice() async throws {
        try await MainActor.run {
            let f = try X6FHarmonyFixture("s2-transpose")
            defer { f.cleanup() }
            let (planned, takes) = try f.plan()
            _ = try f.store.transposeProject(semitones: 2)
            let landings = try f.store.landSungVocals(takes, planned: planned)
            #expect(landings.map(\.transposedSemitones) == [2, 2])
            #expect(landings.map(\.melodyChanged) == [false, false])
            let moved = ProjectStore.sungVocalTransposedNotice(semitones: 2)
            #expect(landings.map(\.notice) == [moved, moved])
        }
    }

    @Test("N4: a length read that fails on the 2nd take removes BOTH copies made (each take is copied, then read), names them, lands nothing")
    func failedSecondReadRemovesFirstCopy() async throws {
        try await MainActor.run {
            let f = try X6FHarmonyFixture("n4-read", media: X6FCountingMedia(failOnCall: 2))
            defer { f.cleanup() }
            let (planned, takes) = try f.plan()
            let tracks = f.store.tracks
            let undo = f.store.undoHistory().undo.count
            do {
                _ = try f.store.landSungVocals(takes, planned: planned)
                Issue.record("expected a throw")
            } catch let stopped as SungVocalLandingStopped {
                #expect(stopped.removedPaths.count == 2)
                for path in stopped.removedPaths {
                    #expect(path.hasPrefix(f.generations.path))
                    #expect(!FileManager.default.fileExists(atPath: path), "the copy is gone: \(path)")
                    #expect(stopped.errorDescription?.contains(URL(fileURLWithPath: path).lastPathComponent) == true,
                            "the error names it")
                }
                #expect(stopped.cause == "The take could not be read.")
            }
            #expect(f.generationFiles().isEmpty, "\(f.generationFiles())")
            #expect(f.store.tracks == tracks)
            #expect(f.store.undoHistory().undo.count == undo)
        }
    }

    @Test("N4: the FIRST take's length read failing removes its one copy and names it")
    func failedFirstReadRemovesItsCopy() async throws {
        try await MainActor.run {
            let f = try X6FHarmonyFixture("n4-first", media: X6FCountingMedia(failOnCall: 1))
            defer { f.cleanup() }
            let (planned, takes) = try f.plan()
            do {
                _ = try f.store.landSungVocals(takes, planned: planned)
                Issue.record("expected a throw")
            } catch let stopped as SungVocalLandingStopped {
                #expect(stopped.removedPaths.count == 1)
            }
            #expect(f.generationFiles().isEmpty, "the one copy made was removed: \(f.generationFiles())")
        }
    }

    @Test("N4 control: when the very first COPY fails, nothing was made, and the original error is thrown unchanged")
    func failedFirstCopyThrowsTheOriginal() async throws {
        try await MainActor.run {
            let f = try X6FHarmonyFixture("n4-copy")
            defer { f.cleanup() }
            let (planned, takes) = try f.plan()
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: takes[0].fileURL.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: takes[0].fileURL.path) }
            do {
                _ = try f.store.landSungVocals(takes, planned: planned)
                Issue.record("expected a throw")
            } catch {
                #expect(!(error is SungVocalLandingStopped), "nothing to remove, nothing to name: \(error)")
            }
            #expect(f.generationFiles().isEmpty, "\(f.generationFiles())")
        }
    }

    @Test("N4: a different project AND a copy that fails partway: the copies made are removed and named")
    func projectChangedPartialCopyRemoved() async throws {
        try await MainActor.run {
            let f = try X6FHarmonyFixture("n4-project")
            defer { f.cleanup() }
            let (planned, takes) = try f.plan()
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: takes[1].fileURL.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: takes[1].fileURL.path) }
            try f.store.newProject(discardChanges: true)
            do {
                _ = try f.store.landSungVocals(takes, planned: planned)
                Issue.record("expected a throw")
            } catch let stopped as SungVocalLandingStopped {
                #expect(stopped.removedPaths.count == 1)
                #expect(stopped.removedPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
            }
            #expect(f.generationFiles().isEmpty, "\(f.generationFiles())")
        }
    }
}
