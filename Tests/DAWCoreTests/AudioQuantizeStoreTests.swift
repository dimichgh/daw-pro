import Foundation
import Testing
@testable import DAWCore

// Audio-quantize store ops (M5 iii-f, spec §5b): the sync `applyAudioQuantize`
// (plan-driven, one undo step) and the async `quantizeAudioClip` (detect →
// re-locate → apply). Reuses the shared `FakeEngine` (CoreTests.swift), whose
// `detectTransientsStub` supplies onsets headlessly.

private func aqApprox(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

@MainActor
@Suite("ProjectStore — applyAudioQuantize (sync)")
struct ApplyAudioQuantizeTests {

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let e as ProjectError { return e }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func audioStore() -> (ProjectStore, FakeEngine, Track, Clip) {
        let clip = Clip(name: "Loop", startBeat: 0, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/tmp/loop.wav"))
        let track = Track(name: "Drums", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = FakeEngine()
        store.engine = engine
        return (store, engine, track, clip)
    }

    // 1. Happy path: replaces the one clip with head+slices, transients on grid,
    //    one undo restores the single original clip.
    @Test("replaces clip with slices on grid; single undo restores the original")
    func happyPath() throws {
        let (store, engine, track, clip) = audioStore()
        // 120 BPM default → spb 0.5. Onsets at 0.55, 0.95, 1.55 s → beats 1.1/1.9/3.1.
        let slices = try store.applyAudioQuantize(
            trackId: track.id, clipId: clip.id,
            transientsSourceSeconds: [0.55, 0.95, 1.55],
            settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 1))
        #expect(slices.count == 4)
        #expect(store.tracks[0].clips.count == 4)
        // Engine was notified once for the replacement.
        #expect(engine.calls.contains(.tracksDidChange(count: 1)))
        // Transients on grid (slice[1..3] carry the real onsets).
        let spb = 0.5
        let live = store.tracks[0].clips
        #expect(aqApprox(live[1].startBeat + (0.55 - live[1].startOffsetSeconds) / spb, 1.0))
        #expect(aqApprox(live[2].startBeat + (0.95 - live[2].startOffsetSeconds) / spb, 2.0))
        #expect(aqApprox(live[3].startBeat + (1.55 - live[3].startOffsetSeconds) / spb, 3.0))

        // One undo step restores exactly one clip with the original geometry.
        #expect(try store.undo() == "Quantize Audio")
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].id == clip.id)
        #expect(aqApprox(store.tracks[0].clips[0].lengthBeats, 4))
        #expect(store.tracks[0].clips[0].fadeInBeats == 0)
    }

    // 2. MIDI clip rejected (verbatim), nothing changes.
    @Test("MIDI clip rejected with quantizeRequiresAudioClip verbatim")
    func midiRejected() throws {
        let midi = Clip(name: "m", startBeat: 0, lengthBeats: 4,
                        notes: [MIDINote(pitch: 60, startBeat: 0.3)])
        let track = Track(name: "Keys", kind: .instrument, clips: [midi])
        let store = ProjectStore(tracks: [track])
        let err = projectError {
            _ = try store.applyAudioQuantize(
                trackId: track.id, clipId: midi.id,
                transientsSourceSeconds: [0.5, 1.0],
                settings: AudioQuantizeSettings(gridBeats: 1.0))
        }
        guard case .quantizeRequiresAudioClip(let id)? = err, id == midi.id else {
            Issue.record("expected quantizeRequiresAudioClip, got \(String(describing: err))"); return
        }
        #expect(err?.errorDescription
                == "clip \(midi.id.uuidString) is a MIDI clip — clip.quantizeAudio applies only to audio clips; use clip.quantize for MIDI notes")
        #expect(store.tracks[0].clips.count == 1)   // nothing changed
    }

    // 3. Non-identity stretch rejected (verbatim).
    @Test("stretched clip rejected with audioQuantizeStretchUnsupported verbatim")
    func stretchRejected() throws {
        let stretched = Clip(name: "s", startBeat: 0, lengthBeats: 4,
                             audioFileURL: URL(fileURLWithPath: "/tmp/s.wav"),
                             stretchRatio: 2)
        let track = Track(name: "Aud", kind: .audio, clips: [stretched])
        let store = ProjectStore(tracks: [track])
        let err = projectError {
            _ = try store.applyAudioQuantize(
                trackId: track.id, clipId: stretched.id,
                transientsSourceSeconds: [0.5, 1.0, 1.5],
                settings: AudioQuantizeSettings(gridBeats: 1.0))
        }
        guard case .audioQuantizeStretchUnsupported(let id)? = err, id == stretched.id else {
            Issue.record("expected audioQuantizeStretchUnsupported, got \(String(describing: err))"); return
        }
        #expect(err?.errorDescription
                == "clip \(stretched.id.uuidString) has a non-identity time-stretch — un-stretch it (clip.setStretch ratio 1, pitch 0) or bounce it first; elastic audio-quantize (per-slice stretch) lands in a future version")
        #expect(store.tracks[0].clips.count == 1)
    }

    // 4. Comp member rejected (shared guard).
    @Test("comp member rejected with clipInTakeGroup")
    func compMemberRejected() throws {
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4,
                     audioFileURL: URL(fileURLWithPath: "/tmp/a.wav"))
        let b = Clip(name: "B", startBeat: 0, lengthBeats: 4,
                     audioFileURL: URL(fileURLWithPath: "/tmp/b.wav"))
        let track = Track(name: "Aud", kind: .audio, clips: [a, b])
        let store = ProjectStore(tracks: [track])
        _ = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let member = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })
        let err = projectError {
            _ = try store.applyAudioQuantize(
                trackId: track.id, clipId: member.id,
                transientsSourceSeconds: [0.5, 1.0, 1.5],
                settings: AudioQuantizeSettings(gridBeats: 1.0))
        }
        if case .clipInTakeGroup? = err {} else {
            Issue.record("expected clipInTakeGroup, got \(String(describing: err))")
        }
    }

    // 5. Fewer than 2 usable transients rejected; nothing changes.
    @Test("fewer than 2 usable transients rejected with audioQuantizeNoTransients")
    func tooFewTransients() throws {
        let (store, _, track, clip) = audioStore()
        let err = projectError {
            _ = try store.applyAudioQuantize(
                trackId: track.id, clipId: clip.id,
                transientsSourceSeconds: [0.9],   // only one
                settings: AudioQuantizeSettings(gridBeats: 1.0))
        }
        guard case .audioQuantizeNoTransients? = err else {
            Issue.record("expected audioQuantizeNoTransients, got \(String(describing: err))"); return
        }
        #expect(store.tracks[0].clips.count == 1)   // untouched
    }
}

@MainActor
@Suite("ProjectStore — quantizeAudioClip (async)")
struct QuantizeAudioClipAsyncTests {

    private func audioStore(_ onsets: [TransientMarker]) -> (ProjectStore, FakeEngine, Track, Clip) {
        let clip = Clip(name: "Loop", startBeat: 0, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/tmp/loop.wav"))
        let track = Track(name: "Drums", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = FakeEngine()
        engine.detectTransientsStub = onsets
        store.engine = engine
        return (store, engine, track, clip)
    }

    // 6. Detects then quantizes; forwards sensitivity; one undo restores.
    @Test("detects on the engine then quantizes; sensitivity forwarded")
    func detectThenQuantize() async throws {
        let (store, engine, track, clip) = audioStore([
            TransientMarker(timeSeconds: 0.55, strength: 1),
            TransientMarker(timeSeconds: 0.95, strength: 0.9),
            TransientMarker(timeSeconds: 1.55, strength: 0.8),
        ])
        let slices = try await store.quantizeAudioClip(
            trackId: track.id, clipId: clip.id,
            settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 1, sensitivity: 0.7))
        #expect(slices.count == 4)
        #expect(store.tracks[0].clips.count == 4)
        #expect(engine.detectTransientsCalls.count == 1)
        #expect(aqApprox(engine.detectTransientsCalls[0].sensitivity, 0.7))
        #expect(engine.detectTransientsCalls[0].url == clip.audioFileURL)
        #expect(try store.undo() == "Quantize Audio")
        #expect(store.tracks[0].clips.count == 1)
    }

    // 7. Headless (no engine) → engineUnavailable, before any detection.
    @Test("no engine → engineUnavailable")
    func headless() async {
        let clip = Clip(name: "Loop", startBeat: 0, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/tmp/loop.wav"))
        let track = Track(name: "Drums", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])   // no engine
        do {
            _ = try await store.quantizeAudioClip(
                trackId: track.id, clipId: clip.id,
                settings: AudioQuantizeSettings(gridBeats: 1.0))
            Issue.record("expected engineUnavailable")
        } catch let e as ProjectError {
            guard case .engineUnavailable = e else {
                Issue.record("expected engineUnavailable, got \(e)"); return
            }
        } catch { Issue.record("unexpected error: \(error)") }
    }

    // 8. Async MIDI rejection fails BEFORE detection (fast path).
    @Test("MIDI clip rejected before detection runs")
    func midiRejectedFast() async {
        let midi = Clip(name: "m", startBeat: 0, lengthBeats: 4,
                        notes: [MIDINote(pitch: 60, startBeat: 0.3)])
        let track = Track(name: "Keys", kind: .instrument, clips: [midi])
        let store = ProjectStore(tracks: [track])
        let engine = FakeEngine()
        store.engine = engine
        do {
            _ = try await store.quantizeAudioClip(
                trackId: track.id, clipId: midi.id,
                settings: AudioQuantizeSettings(gridBeats: 1.0))
            Issue.record("expected quantizeRequiresAudioClip")
        } catch let e as ProjectError {
            guard case .quantizeRequiresAudioClip = e else {
                Issue.record("expected quantizeRequiresAudioClip, got \(e)"); return
            }
            #expect(engine.detectTransientsCalls.isEmpty)   // never detected
        } catch { Issue.record("unexpected error: \(error)") }
    }
}
