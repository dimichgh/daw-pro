import Foundation
import Testing
@testable import DAWCore

/// Headless coverage for track bounce-in-place (m11-e) — the render-and-land
/// vertical over `ProjectStore.bounceTrackInPlace`. Reuses `FakeBufferEngine`
/// (RenderPolicyTests): `renderOffline` returns a controllable buffer,
/// `writeAudioFile` records what would hit disk. Eligibility parity with
/// `render.stems`, the ONE-undo composite (new track+clip land + source mute,
/// reversed together), the muteSource/name knobs, and clip placement/length
/// are all assertable without AVFoundation. Real rendered-audio equivalence
/// vs a direct stem render is proven by the live gate.
@MainActor
@Suite("Track bounce-in-place (m11-e)")
struct BounceInPlaceTests {

    /// A 2 s stereo 997 Hz tone so `Loudness.measure` and the write's duration
    /// carry real numbers (2 s → 4 beats at the default 120 BPM).
    private func tone(seconds: Double = 2.0, sampleRate: Double = 48_000) -> RenderedAudio {
        let frames = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            samples[i] = Float(0.1 * sin(2.0 * Double.pi * 997.0 * Double(i) / sampleRate))
        }
        return RenderedAudio(sampleRate: sampleRate, channelData: [samples, samples])
    }

    private func makeStore(_ engine: FakeBufferEngine) -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        // Keep bounces out of the real Application Support home during tests.
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounce-tests-\(UUID().uuidString)", isDirectory: true)
        return store
    }

    // MARK: - Happy path + one-undo composite

    @Test("bounces a direct track: new audio track lands after the source, source muted, ONE undo")
    func happyPathOneUndo() async throws {
        let engine = FakeBufferEngine()
        engine.stub = tone()
        let store = makeStore(engine)
        let a = store.addTrack(name: "A", kind: .audio)
        let source = store.addTrack(name: "Synth", kind: .instrument)
        let c = store.addTrack(name: "C", kind: .audio)
        let before = store.tracks.count

        let result = try await store.bounceTrackInPlace(trackId: source.id, durationSeconds: 2.0)

        // A new audio track named "<source> (Bounced)" landed DIRECTLY after the source.
        #expect(store.tracks.count == before + 1)
        let insertIndex = try #require(store.tracks.firstIndex(where: { $0.id == result.track.id }))
        let sourceIndex = try #require(store.tracks.firstIndex(where: { $0.id == source.id }))
        #expect(insertIndex == sourceIndex + 1)
        #expect(store.tracks[insertIndex].kind == .audio)
        #expect(result.track.name == "Synth (Bounced)")
        #expect(store.tracks.first(where: { $0.id == a.id }) != nil)   // A/C untouched
        #expect(store.tracks.last?.id == c.id)

        // Exactly one clip on the new track, at fromBeat 0, referencing the file.
        #expect(store.tracks[insertIndex].clips.count == 1)
        let landed = store.tracks[insertIndex].clips[0]
        #expect(landed.id == result.clip.id)
        #expect(landed.startBeat == 0)
        #expect(landed.audioFileURL?.path == result.file)

        // Source muted by default; result echoes it.
        #expect(store.tracks[sourceIndex].isMuted == true)
        #expect(result.sourceMuted == true)
        #expect(result.sourceTrackId == source.id)

        // ONE undo step: label at top, and undo removes the new track AND unmutes.
        #expect(store.undoLabel == "Bounce in Place")
        _ = try store.undo()
        #expect(store.tracks.count == before)
        #expect(store.tracks.first(where: { $0.id == result.track.id }) == nil)
        #expect(store.tracks.first(where: { $0.id == source.id })?.isMuted == false)
    }

    // MARK: - muteSource knob

    @Test("muteSource:false leaves the source audible")
    func muteSourceFalse() async throws {
        let engine = FakeBufferEngine()
        engine.stub = tone()
        let store = makeStore(engine)
        let source = store.addTrack(name: "Bass", kind: .instrument)

        let result = try await store.bounceTrackInPlace(
            trackId: source.id, durationSeconds: 2.0, muteSource: false)
        #expect(result.sourceMuted == false)
        #expect(store.tracks.first(where: { $0.id == source.id })?.isMuted == false)
    }

    @Test("muteSource default is true")
    func muteSourceDefaultTrue() async throws {
        let engine = FakeBufferEngine()
        engine.stub = tone()
        let store = makeStore(engine)
        let source = store.addTrack(name: "Bass", kind: .instrument)
        let result = try await store.bounceTrackInPlace(trackId: source.id, durationSeconds: 2.0)
        #expect(result.sourceMuted == true)
    }

    // MARK: - name default / override

    @Test("name override renames both the track and its clip")
    func nameOverride() async throws {
        let engine = FakeBufferEngine()
        engine.stub = tone()
        let store = makeStore(engine)
        let source = store.addTrack(name: "Lead", kind: .instrument)

        let result = try await store.bounceTrackInPlace(
            trackId: source.id, durationSeconds: 2.0, name: "Committed Lead")
        #expect(result.track.name == "Committed Lead")
        #expect(result.clip.name == "Committed Lead")

        // An empty name falls back to the default.
        let source2 = store.addTrack(name: "Pad", kind: .instrument)
        let result2 = try await store.bounceTrackInPlace(
            trackId: source2.id, durationSeconds: 2.0, name: "")
        #expect(result2.track.name == "Pad (Bounced)")
    }

    // MARK: - clip placement / length

    @Test("clip lands at fromBeat with length measured from the rendered duration")
    func clipPlacementAndLength() async throws {
        let engine = FakeBufferEngine()
        engine.stub = tone(seconds: 3.0)   // 3 s → 6 beats at 120 BPM
        let store = makeStore(engine)
        let source = store.addTrack(name: "Keys", kind: .instrument)

        let result = try await store.bounceTrackInPlace(
            trackId: source.id, fromBeat: 8, durationSeconds: 3.0)
        #expect(result.clip.startBeat == 8)
        let expectedBeats = 3.0 * store.transport.tempoBPM / 60.0
        #expect(abs(result.clip.lengthBeats - expectedBeats) < 1e-6)
    }

    // MARK: - eligibility parity with render.stems

    @Test("a bus-routed source rejects stemNotMasterInput verbatim (render.stems parity)")
    func busRoutedRejection() async throws {
        let engine = FakeBufferEngine()
        engine.stub = tone()
        let store = makeStore(engine)
        let bus = store.addTrack(name: "Drum Bus", kind: .bus)
        let source = store.addTrack(name: "Snare", kind: .audio)
        try store.setTrackOutput(id: source.id, busID: bus.id)

        await #expect(throws: ProjectError.self) {
            try await store.bounceTrackInPlace(trackId: source.id, durationSeconds: 1.0)
        }
        do {
            _ = try await store.bounceTrackInPlace(trackId: source.id, durationSeconds: 1.0)
            Issue.record("expected stemNotMasterInput")
        } catch let error as ProjectError {
            #expect(error.errorDescription
                == "'Snare' is routed to bus 'Drum Bus' — its signal is part of that bus's stem")
        }
        // The rejected bounce never mutated the project.
        #expect(store.tracks.count == 2)
    }

    @Test("a bus bounces successfully (eligibility parity with stems)")
    func busBounces() async throws {
        let engine = FakeBufferEngine()
        engine.stub = tone()
        let store = makeStore(engine)
        let bus = store.addTrack(name: "Group", kind: .bus)
        let src = store.addTrack(name: "Kick", kind: .audio)
        try store.setTrackOutput(id: src.id, busID: bus.id)

        let result = try await store.bounceTrackInPlace(trackId: bus.id, durationSeconds: 1.0)
        #expect(result.track.name == "Group (Bounced)")
        #expect(store.tracks.first(where: { $0.id == result.track.id }) != nil)
    }

    @Test("an unknown track id rejects trackNotFound")
    func unknownTrack() async throws {
        let engine = FakeBufferEngine()
        engine.stub = tone()
        let store = makeStore(engine)
        _ = store.addTrack(name: "A", kind: .audio)
        await #expect(throws: ProjectError.self) {
            try await store.bounceTrackInPlace(trackId: UUID(), durationSeconds: 1.0)
        }
    }

    @Test("empty session (default window, no clips) rejects nothingToRender")
    func nothingToRender() async throws {
        let engine = FakeBufferEngine()
        engine.stub = tone()
        let store = makeStore(engine)
        let source = store.addTrack(name: "Empty", kind: .instrument)
        // No clips anywhere + no explicit duration → the default window has
        // nothing to render, exactly like render.stems.
        do {
            _ = try await store.bounceTrackInPlace(trackId: source.id)
            Issue.record("expected nothingToRender")
        } catch let error as ProjectError {
            #expect(error.errorDescription
                == "nothing to render — no clips found in the render range; "
                + "add clips or pass an explicit durationSeconds")
        }
    }

    // MARK: - headless

    @Test("no engine surfaces engineUnavailable")
    func headless() async throws {
        let store = ProjectStore()   // no engine
        let source = store.addTrack(name: "A", kind: .instrument)
        do {
            _ = try await store.bounceTrackInPlace(trackId: source.id, durationSeconds: 1.0)
            Issue.record("expected engineUnavailable")
        } catch let error as ProjectError {
            #expect(error.errorDescription == "audio engine not available")
        }
    }

    // MARK: - render path parity (forced full-session plan, one pass)

    @Test("renders exactly one offline pass over the requested window")
    func oneRenderPass() async throws {
        let engine = FakeBufferEngine()
        engine.stub = tone()
        let store = makeStore(engine)
        let source = store.addTrack(name: "Synth", kind: .instrument)
        _ = try await store.bounceTrackInPlace(trackId: source.id, fromBeat: 4, durationSeconds: 2.0)
        #expect(engine.renderCalls.count == 1)
        #expect(engine.renderCalls[0].fromBeat == 4)
        #expect(engine.renderCalls[0].duration == 2.0)
        #expect(engine.written.count == 1)   // one WAV written into the media home
    }
}
