import Foundation
import Testing
@testable import DAWCore

/// Deterministic stand-in for the AVAudioFile-backed importer so import math is
/// exercised without touching the filesystem. Sendable via immutable storage.
struct FakeMedia: MediaImporting {
    var info: AudioFileInfo = AudioFileInfo(durationSeconds: 2.0, sampleRate: 44100, channelCount: 2)

    func audioFileInfo(at url: URL) throws -> AudioFileInfo { info }
}

@MainActor
@Suite("Audio import")
struct AudioImportTests {
    private func makeStore(media: (any MediaImporting)? = FakeMedia()) -> ProjectStore {
        let store = ProjectStore()
        store.media = media
        return store
    }

    private let url = URL(fileURLWithPath: "/tmp/Kick Loop.wav")

    @Test("import maps seconds to beats and names the clip from the file")
    func importBasics() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .audio)
        try store.setTempo(120)

        let clip = try store.importAudio(url: url, toTrack: track.id)
        // 2.0s at 120 BPM = 4 beats.
        #expect(clip.lengthBeats == 4)
        #expect(clip.name == "Kick Loop")
        #expect(clip.audioFileURL == url)
        #expect(clip.startBeat == 0)
        #expect(store.tracks[0].clips.count == 1)
    }

    @Test("default startBeat appends after the last clip")
    func appendsSequentially() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .audio)
        try store.setTempo(120)

        let first = try store.importAudio(url: url, toTrack: track.id)
        let second = try store.importAudio(url: url, toTrack: track.id)
        #expect(first.startBeat == 0)
        #expect(second.startBeat == first.lengthBeats)
        #expect(store.tracks[0].clips.count == 2)
    }

    @Test("explicit atBeat is honored")
    func explicitPosition() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: url, toTrack: track.id, atBeat: 16)
        #expect(clip.startBeat == 16)
    }

    @Test("negative atBeat clamps to zero")
    func negativeClamps() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: url, toTrack: track.id, atBeat: -8)
        #expect(clip.startBeat == 0)
    }

    @Test("missing media service throws")
    func noMediaService() throws {
        let store = makeStore(media: nil)
        let track = store.addTrack(kind: .audio)
        #expect(throws: ProjectError.self) {
            try store.importAudio(url: url, toTrack: track.id)
        }
        do {
            _ = try store.importAudio(url: url, toTrack: track.id)
            Issue.record("expected throw")
        } catch let error as ProjectError {
            guard case .mediaServiceUnavailable = error else {
                Issue.record("wrong case: \(error)")
                return
            }
        }
    }

    @Test("unknown track throws trackNotFound")
    func unknownTrack() {
        let store = makeStore()
        let bogus = UUID()
        do {
            _ = try store.importAudio(url: url, toTrack: bogus)
            Issue.record("expected throw")
        } catch let error as ProjectError {
            guard case .trackNotFound(let id) = error, id == bogus else {
                Issue.record("wrong case: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("bus track rejects audio clips")
    func busUnsupported() {
        let store = makeStore()
        let bus = store.addTrack(kind: .bus)
        do {
            _ = try store.importAudio(url: url, toTrack: bus.id)
            Issue.record("expected throw")
        } catch let error as ProjectError {
            guard case .trackKindUnsupported(let kind) = error, kind == .bus else {
                Issue.record("wrong case: \(error)")
                return
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
