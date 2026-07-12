import Foundation
import Testing
@testable import DAWCore

/// ProjectStore.renderMixdown policy tests: default-duration math, destination
/// resolution, and the error contract — all against the recording FakeEngine,
/// no audio I/O. (FakeEngine lives in CoreTests.swift.)
@MainActor
@Suite("Mixdown — ProjectStore policy")
struct MixdownStoreTests {
    /// Store with one audio track holding a 4-beat clip (2.0 s at the default
    /// 120 BPM, ending at beat 4) and the given engine attached. Callers hold
    /// the engine strongly — `ProjectStore.engine` is weak.
    private func makeStore(engine: FakeEngine) -> ProjectStore {
        let track = Track(name: "A", kind: .audio, clips: [
            Clip(name: "c", startBeat: 0, lengthBeats: 4),
        ])
        let store = ProjectStore(tracks: [track])
        store.engine = engine
        return store
    }

    @Test("default duration runs to the last clip end plus a 0.5 s tail")
    func defaultDuration() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine: engine)

        _ = try await store.renderMixdown()

        let request = try #require(engine.mixdownRequests.last)
        // Clip ends at beat 4 → 2.0 s at 120 BPM, + 0.5 s tail.
        #expect(abs(request.durationSeconds - 2.5) < 1e-9)
        #expect(request.fromBeat == 0)
        #expect(request.tempoMap == TempoMap(constantBPM: 120))
        #expect(request.masterVolume == 1)
        #expect(request.tracks.count == 1)
    }

    @Test("fromBeat shortens the default duration")
    func defaultDurationWithFromBeat() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine: engine)

        _ = try await store.renderMixdown(fromBeat: 2)

        let request = try #require(engine.mixdownRequests.last)
        // Beats 2→4 = 1.0 s at 120 BPM, + 0.5 s tail.
        #expect(abs(request.durationSeconds - 1.5) < 1e-9)
        #expect(request.fromBeat == 2)
    }

    @Test("no clips and no explicit duration throws nothingToRender")
    func nothingToRenderWhenEmpty() async {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine

        do {
            _ = try await store.renderMixdown()
            Issue.record("expected throw")
        } catch let error as ProjectError {
            guard case .nothingToRender = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(error.errorDescription == "nothing to render — project has no audio clips")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(engine.mixdownRequests.isEmpty)
    }

    @Test("fromBeat at or past the last clip end throws nothingToRender")
    func nothingToRenderPastContent() async {
        let engine = FakeEngine()
        let store = makeStore(engine: engine)

        for fromBeat in [4.0, 16.0] {  // clip ends at beat 4
            do {
                _ = try await store.renderMixdown(fromBeat: fromBeat)
                Issue.record("expected throw for fromBeat \(fromBeat)")
            } catch let error as ProjectError {
                guard case .nothingToRender = error else {
                    Issue.record("wrong case for fromBeat \(fromBeat): \(error)")
                    return
                }
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(engine.mixdownRequests.isEmpty)
    }

    // MIDI 23a.
    @Test("a MIDI-only project has nothing to render (instrument clips aren't audio)")
    func midiOnlyNothingToRender() async throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let inst = store.addTrack(kind: .instrument)
        _ = try store.addMIDIClip(
            toTrack: inst.id,
            notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 4)]
        )

        do {
            _ = try await store.renderMixdown()  // no explicit duration
            Issue.record("expected nothingToRender for a MIDI-only project")
        } catch let error as ProjectError {
            guard case .nothingToRender = error else {
                Issue.record("wrong case: \(error)"); return
            }
            #expect(error.errorDescription == "nothing to render — project has no audio clips")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(engine.mixdownRequests.isEmpty)
    }

    @Test("explicit duration renders even with no clips")
    func explicitDurationNeedsNoClips() async throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine

        _ = try await store.renderMixdown(durationSeconds: 0.25)

        #expect(engine.mixdownRequests.last?.durationSeconds == 0.25)
    }

    @Test("nil path defaults to a unique .wav under NSTemporaryDirectory()/DAWPro")
    func pathDefaulting() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine: engine)

        let result = try await store.renderMixdown()

        let request = try #require(engine.mixdownRequests.last)
        #expect(result.path == request.url.path)
        let expectedDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DAWPro", isDirectory: true).path
        #expect(request.url.deletingLastPathComponent().path == expectedDir)
        #expect(request.url.lastPathComponent.hasPrefix("mixdown-"))
        #expect(request.url.pathExtension == "wav")
    }

    @Test("~ paths expand to the home directory")
    func tildeExpansion() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine: engine)

        let result = try await store.renderMixdown(toPath: "~/daw-pro-mix-test.wav")

        let request = try #require(engine.mixdownRequests.last)
        #expect(request.url.path == NSHomeDirectory() + "/daw-pro-mix-test.wav")
        #expect(result.path == NSHomeDirectory() + "/daw-pro-mix-test.wav")
    }

    @Test(".wav is appended when missing, never doubled")
    func wavExtensionAppending() async throws {
        let engine = FakeEngine()
        let store = makeStore(engine: engine)

        _ = try await store.renderMixdown(toPath: "/tmp/daw-pro-bounce")
        #expect(engine.mixdownRequests.last?.url.path == "/tmp/daw-pro-bounce.wav")

        // An existing suffix survives untouched (case-insensitive check).
        _ = try await store.renderMixdown(toPath: "/tmp/daw-pro-bounce.WAV")
        #expect(engine.mixdownRequests.last?.url.path == "/tmp/daw-pro-bounce.WAV")
    }

    @Test("nil engine throws engineUnavailable")
    func engineUnavailable() async {
        let store = ProjectStore()  // no engine injected

        do {
            _ = try await store.renderMixdown(durationSeconds: 1)
            Issue.record("expected throw")
        } catch let error as ProjectError {
            guard case .engineUnavailable = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(error.errorDescription == "audio engine not available")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("result mirrors the engine-reported file facts")
    func resultMirrorsEngineFacts() async throws {
        let engine = FakeEngine()
        engine.mixdownStub = AudioFileInfo(
            durationSeconds: 2.5, sampleRate: 44_100, channelCount: 2
        )
        let store = makeStore(engine: engine)

        let result = try await store.renderMixdown()

        #expect(result.durationSeconds == 2.5)
        #expect(result.sampleRate == 44_100)
        #expect(result.channels == 2)
    }
}
