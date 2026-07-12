import Foundation
import Testing
@testable import DAWCore

/// Media stand-in whose duration + failure is chosen per URL, so the batch's
/// per-file success/error handling is exercised deterministically. A URL in
/// `failing` throws; everything else reads `defaultInfo`. Sendable via immutable
/// storage.
private struct MapMedia: MediaImporting {
    var defaultInfo = AudioFileInfo(durationSeconds: 2.0, sampleRate: 44100, channelCount: 2)
    var failing: Set<String> = []

    func audioFileInfo(at url: URL) throws -> AudioFileInfo {
        if failing.contains(url.lastPathComponent) {
            throw ProjectError.importFailed("unreadable test file")
        }
        return defaultInfo
    }
}

@MainActor
@Suite("Audio import batch")
struct AudioImportBatchTests {
    private func makeStore(media: (any MediaImporting)? = MapMedia()) -> ProjectStore {
        let store = ProjectStore()
        store.media = media
        return store
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    @Test("multi-file batch creates one track per file, all at the same beat")
    func multiNewTracks() throws {
        let store = makeStore()
        try store.setTempo(120)  // 2.0s → 4 beats
        let requests = [
            AudioImportRequest(url: url("drums.wav"), destination: .newTrack(name: "drums"), startBeat: 8),
            AudioImportRequest(url: url("bass.wav"), destination: .newTrack(name: "bass"), startBeat: 8),
            AudioImportRequest(url: url("vox.wav"), destination: .newTrack(name: "vox"), startBeat: 8),
        ]
        let outcomes = try store.importAudioBatch(requests)

        #expect(store.tracks.count == 3)
        #expect(store.tracks.map(\.name) == ["drums", "bass", "vox"])
        for track in store.tracks {
            #expect(track.kind == .audio)
            #expect(track.clips.count == 1)
            #expect(track.clips[0].startBeat == 8)
            #expect(track.clips[0].lengthBeats == 4)
        }
        // Outcomes carry the resolved clip + track ids.
        #expect(outcomes.count == 3)
        #expect(outcomes.allSatisfy { $0.error == nil && $0.clip != nil && $0.trackID != nil })
        #expect(outcomes[0].trackName == "drums")
    }

    @Test("the whole multi-file import is ONE undo step")
    func oneUndoStep() throws {
        let store = makeStore()
        let requests = (0..<4).map { i in
            AudioImportRequest(url: url("stem\(i).wav"), destination: .newTrack(name: "stem\(i)"), startBeat: 0)
        }
        _ = try store.importAudioBatch(requests)
        #expect(store.tracks.count == 4)
        #expect(store.undoLabel == "Import 4 Files")

        // A single undo removes every track + clip the batch added.
        try store.undo()
        #expect(store.tracks.isEmpty)
        // And one redo restores them all.
        try store.redo()
        #expect(store.tracks.count == 4)
        #expect(store.tracks.allSatisfy { $0.clips.count == 1 })
    }

    @Test("a single-file batch labels the undo with the clip name")
    func singleFileLabel() throws {
        let store = makeStore()
        _ = try store.importAudioBatch([
            AudioImportRequest(url: url("Kick Loop.wav"), destination: .newTrack(name: "Kick Loop"), startBeat: 0)
        ])
        #expect(store.undoLabel == "Import 'Kick Loop'")
    }

    @Test("existing-track destination appends to that lane")
    func existingTrack() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .audio)
        let outcomes = try store.importAudioBatch([
            AudioImportRequest(url: url("a.wav"), destination: .existingTrack(track.id), startBeat: 2)
        ])
        #expect(store.tracks.count == 1)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].startBeat == 2)
        #expect(outcomes[0].trackID == track.id)
        #expect(outcomes[0].trackName == store.tracks[0].name)
    }

    @Test("a bad file is reported and skipped; good files still import in one step")
    func partialFailureOneStep() throws {
        let store = makeStore(media: MapMedia(failing: ["bad.wav"]))
        let requests = [
            AudioImportRequest(url: url("good1.wav"), destination: .newTrack(name: "good1"), startBeat: 0),
            AudioImportRequest(url: url("bad.wav"), destination: .newTrack(name: "bad"), startBeat: 0),
            AudioImportRequest(url: url("good2.wav"), destination: .newTrack(name: "good2"), startBeat: 0),
        ]
        let outcomes = try store.importAudioBatch(requests)

        // Only the two good files created tracks.
        #expect(store.tracks.map(\.name) == ["good1", "good2"])
        #expect(outcomes.count == 3)
        #expect(outcomes[0].error == nil && outcomes[0].clip != nil)
        #expect(outcomes[1].error != nil && outcomes[1].clip == nil)  // the bad one
        #expect(outcomes[1].error?.contains("Audio import failed") == true)
        #expect(outcomes[2].error == nil && outcomes[2].clip != nil)
        // Still ONE undo step for the two successes.
        #expect(store.undoLabel == "Import 2 Files")
        try store.undo()
        #expect(store.tracks.isEmpty)
    }

    @Test("all files failing → no mutation, no undo entry")
    func allFailNoEdit() throws {
        let store = makeStore(media: MapMedia(failing: ["a.wav", "b.wav"]))
        let outcomes = try store.importAudioBatch([
            AudioImportRequest(url: url("a.wav"), destination: .newTrack(name: "a"), startBeat: 0),
            AudioImportRequest(url: url("b.wav"), destination: .newTrack(name: "b"), startBeat: 0),
        ])
        #expect(store.tracks.isEmpty)
        #expect(store.canUndo == false)  // no stray edit
        #expect(outcomes.allSatisfy { $0.error != nil })
    }

    @Test("existing-track that vanished / isn't audio → per-file error, skipped")
    func badExistingTarget() throws {
        let store = makeStore()
        let bus = store.addTrack(kind: .bus)
        let missing = UUID()
        let outcomes = try store.importAudioBatch([
            AudioImportRequest(url: url("a.wav"), destination: .existingTrack(missing), startBeat: 0),
            AudioImportRequest(url: url("b.wav"), destination: .existingTrack(bus.id), startBeat: 0),
        ])
        #expect(outcomes[0].error != nil)  // trackNotFound
        #expect(outcomes[1].error != nil)  // trackKindUnsupported
        #expect(store.tracks.count == 1)   // still just the bus, no clips
        #expect(store.tracks[0].clips.isEmpty)
    }

    @Test("no media service throws before any per-file work")
    func noMediaThrows() throws {
        let store = makeStore(media: nil)
        #expect(throws: ProjectError.self) {
            try store.importAudioBatch([
                AudioImportRequest(url: url("a.wav"), destination: .newTrack(name: "a"), startBeat: 0)
            ])
        }
    }

    @Test("empty requests → empty result, no edit")
    func emptyRequests() throws {
        let store = makeStore()
        let outcomes = try store.importAudioBatch([])
        #expect(outcomes.isEmpty)
        #expect(store.canUndo == false)
    }
}
