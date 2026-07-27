import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m23-m1 — `excludeTrackIds` on `render.bounce` / `render.mixdown` against the
/// real offline engine: the instrumental / minus-vocal rung.
///
/// The load-bearing leg is a NULL test built only out of the new parameter:
/// **full mix ≡ (mix minus the vocal) + (vocal alone)**, ≤ 1e-4 — which can
/// only hold if the exclusion removes exactly that track's contribution, adds
/// nothing, and leaves every other strip's plugin-delay compensation on the
/// full-session plan. The fixture carries a **limiter (240-sample lookahead) on
/// one strip** precisely so that last clause has teeth: a subset-shaped
/// implementation (hand the engine a shorter `tracks` array) would re-plan PDC
/// and comb the sum, which is the hazard `render.stems` had to build
/// `forcedCompensationTargets` around. A mute-copy of the FULL array cannot,
/// because the compensation survey is mute-blind.
///
/// The other legs pin the consequences the command's teaching text promises:
/// the excluded track's SEND TAIL leaves with it, its SOLO flag leaves with it,
/// the render length is still the whole session's, and the project itself is
/// never touched.
@MainActor
@Suite("Render exclusion — instrumental / minus-vocal (m23-m1)", .serialized)
struct RenderExclusionRenderTests {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-exclude-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(tracks: [Track], engine: AudioEngine) -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        store.tracks = tracks
        return store
    }

    private func residualPeak(_ a: [[Float]], _ b: [[Float]]) -> Float {
        var peak: Float = 0
        for channel in 0..<min(a.count, b.count) {
            for frame in 0..<min(a[channel].count, b[channel].count) {
                peak = max(peak, abs(a[channel][frame] - b[channel][frame]))
            }
        }
        return peak
    }

    private func sum(_ a: [[Float]], _ b: [[Float]]) -> [[Float]] {
        var out = a
        for channel in 0..<min(out.count, b.count) {
            for frame in 0..<min(out[channel].count, b[channel].count) {
                out[channel][frame] += b[channel][frame]
            }
        }
        return out
    }

    // MARK: - The null test

    @Test("full mix ≡ (mix − vocal) + (vocal alone), ≤ 1e-4, with a PDC-bearing strip in the session")
    func instrumentalPlusVocalReconstructsTheMix() async throws {
        let fixtures = try TestSignals.fixtures()
        // The limiter's 240-sample lookahead makes the full-session PDC plan
        // non-trivial: every other strip is delayed to match it. If any of the
        // three renders below re-planned compensation, the null breaks.
        let drums = Track(name: "Drums", kind: .audio, pan: -0.3,
                          clips: [Clip(name: "d", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)],
                          effects: [EffectDescriptor(kind: .limiter)])
        let bass = Track(name: "Bass", kind: .audio, volume: 0.7, pan: 0.4,
                         clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        let vocal = Track(name: "Vocal", kind: .audio, volume: 0.9, pan: -0.1,
                          clips: [Clip(name: "v", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let store = makeStore(tracks: [drums, bass, vocal], engine: engine)
        let dir = try makeTempDir("null")

        // Context: the session plan really does delay the un-limited strips.
        let targets = await engine.offlineCompensationTargets(tracks: store.tracks)
        #expect(targets[drums.id] == 0)
        #expect(targets[bass.id] == 240)
        #expect(targets[vocal.id] == 240)

        let full = try await store.renderBounce(
            toPath: dir.appendingPathComponent("full.wav").path, durationSeconds: 1.0)
        let instrumental = try await store.renderBounce(
            toPath: dir.appendingPathComponent("instrumental.wav").path,
            durationSeconds: 1.0, excludeTrackIds: [vocal.id])
        let vocalOnly = try await store.renderBounce(
            toPath: dir.appendingPathComponent("vocal.wav").path,
            durationSeconds: 1.0, excludeTrackIds: [drums.id, bass.id])

        // The honesty echo names what left, in session order — and is OMITTED
        // entirely on the un-excluded render.
        #expect(full.excludedTracks == nil)
        #expect(instrumental.excludedTracks == ["Vocal"])
        #expect(vocalOnly.excludedTracks == ["Drums", "Bass"])

        let fullAudio = try TestSignals.readFile(URL(fileURLWithPath: full.path))
        let instrumentalAudio = try TestSignals.readFile(URL(fileURLWithPath: instrumental.path))
        let vocalAudio = try TestSignals.readFile(URL(fileURLWithPath: vocalOnly.path))

        let residual = residualPeak(sum(instrumentalAudio, vocalAudio), fullAudio)
        print("[measured] m23-m1 exclusion null: |(mix−vocal) + vocal − mix| peak \(residual) (gate 1e-4)")
        #expect(residual <= 1e-4)

        // NON-VACUITY: the instrumental is genuinely a different, quieter
        // program — not the full mix returned under a new name.
        let difference = residualPeak(instrumentalAudio, fullAudio)
        print("[measured] m23-m1 exclusion: |mix − instrumental| peak \(difference)")
        #expect(difference > 0.05)
        #expect(TestSignals.rms(instrumentalAudio[0], in: 0..<24_000) > 0.1)
        #expect(TestSignals.rms(vocalAudio[0], in: 0..<24_000) > 0.01)

        // And the excluded track really is SILENT in the instrumental, not
        // merely attenuated: vocal-only is the whole of what was removed.
        let removed = residualPeak(sum(instrumentalAudio, vocalAudio), instrumentalAudio)
        #expect(removed > 0.01, "the removed material is audible on its own")
    }

    // MARK: - What leaves with an excluded track

    @Test("the excluded track's SEND tail leaves with it — the instrumental has no vocal reverb")
    func excludedTrackTakesItsSendTailWithIt() async throws {
        let fixtures = try TestSignals.fixtures()
        let bus = Track(name: "Echo Bus", kind: .bus,
                        effects: [EffectDescriptor(
                            kind: .delay,
                            delay: DelayParams(timeMs: 250, feedback: 0.6, mix: 0.5,
                                               pingPong: 0, highCutHz: 12_000))])
        // ONLY the vocal feeds the echo bus, so the tail window is a clean
        // read on "did the vocal's ambience leave too?".
        let vocal = Track(name: "Vocal", kind: .audio,
                          clips: [Clip(name: "v", startBeat: 0, lengthBeats: 1,
                                       audioFileURL: fixtures.cos1k48)],
                          sends: [Send(destinationBusID: bus.id, level: 0.9)])
        let keys = Track(name: "Keys", kind: .audio,
                         clips: [Clip(name: "k", startBeat: 0, lengthBeats: 1,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let store = makeStore(tracks: [bus, vocal, keys], engine: engine)
        let dir = try makeTempDir("sends")

        let full = try await store.renderBounce(
            toPath: dir.appendingPathComponent("full.wav").path, durationSeconds: 2.0)
        let instrumental = try await store.renderBounce(
            toPath: dir.appendingPathComponent("instrumental.wav").path,
            durationSeconds: 2.0, excludeTrackIds: [vocal.id])

        // Clips end at 0.5 s; 1.0–1.5 s is pure echo-bus tail.
        let tail = 48_000..<72_000
        let fullAudio = try TestSignals.readFile(URL(fileURLWithPath: full.path))
        let instrumentalAudio = try TestSignals.readFile(
            URL(fileURLWithPath: instrumental.path))
        let fullTail = TestSignals.rms(fullAudio[0], in: tail)
        let instrumentalTail = TestSignals.rms(instrumentalAudio[0], in: tail)
        print("[measured] m23-m1 send tail: full-mix tail RMS \(fullTail), "
            + "instrumental tail RMS \(instrumentalTail)")
        #expect(fullTail > 1e-3, "the fixture must actually ring, or this leg is vacuous")
        #expect(instrumentalTail < 1e-5)
        // The instrumental still plays its own material while the clips run.
        #expect(TestSignals.rms(instrumentalAudio[0], in: 0..<20_000) > 0.05)
    }

    @Test("the excluded track's SOLO flag leaves with it — excluding the only soloed track is not silence")
    func excludingTheOnlySoloedTrackYieldsTheInstrumental() async throws {
        let fixtures = try TestSignals.fixtures()
        let vocal = Track(name: "Vocal", kind: .audio, isSoloed: true,
                          clips: [Clip(name: "v", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        let keys = Track(name: "Keys", kind: .audio,
                         clips: [Clip(name: "k", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let store = makeStore(tracks: [vocal, keys], engine: engine)
        let dir = try makeTempDir("solo")

        // Baseline: with the vocal soloed, the full mix is the vocal ALONE —
        // solo is honoured by the offline render, unchanged by m23-m1.
        let soloed = try await store.renderBounce(
            toPath: dir.appendingPathComponent("soloed.wav").path, durationSeconds: 1.0)
        let soloedAudio = try TestSignals.readFile(URL(fileURLWithPath: soloed.path))
        let soloedRMS = TestSignals.rms(soloedAudio[0], in: 0..<24_000)
        #expect(soloedRMS > 0.1)

        let instrumental = try await store.renderBounce(
            toPath: dir.appendingPathComponent("instrumental.wav").path,
            durationSeconds: 1.0, excludeTrackIds: [vocal.id])
        let instrumentalAudio = try TestSignals.readFile(
            URL(fileURLWithPath: instrumental.path))
        let instrumentalRMS = TestSignals.rms(instrumentalAudio[0], in: 0..<24_000)
        print("[measured] m23-m1 solo: soloed-mix RMS \(soloedRMS), "
            + "instrumental RMS \(instrumentalRMS) (silence would be ≈0)")
        // The discriminator: leaving `isSoloed` set on the excluded track would
        // keep `soloActive` true and gate everything else — silence.
        #expect(instrumentalRMS > 0.05)
        // Other tracks' solo state is untouched: the keys track was never
        // soloed and is audible now only because the solo left with the vocal.
        #expect(store.tracks[0].isSoloed, "the project's own solo flag is unchanged")
    }

    // MARK: - Window, non-mutation, rejection

    @Test("the render window still comes from the WHOLE session — excluding the longest track keeps the length")
    func windowIgnoresTheExclusion() async throws {
        let fixtures = try TestSignals.fixtures()
        let short = Track(name: "Short", kind: .audio,
                          clips: [Clip(name: "s", startBeat: 0, lengthBeats: 2,
                                       audioFileURL: fixtures.cos1k48Quarter)])
        let long = Track(name: "Long", kind: .audio,
                         clips: [Clip(name: "l", startBeat: 0, lengthBeats: 8,
                                      audioFileURL: fixtures.cos1k48)])
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let store = makeStore(tracks: [short, long], engine: engine)
        let dir = try makeTempDir("window")

        // No explicit duration: the shared all-clips window + 2 s tail.
        let full = try await store.renderBounce(
            toPath: dir.appendingPathComponent("full.wav").path)
        let withoutLong = try await store.renderBounce(
            toPath: dir.appendingPathComponent("short.wav").path,
            excludeTrackIds: [long.id])
        print("[measured] m23-m1 window: full \(full.durationSeconds) s, "
            + "minus-longest \(withoutLong.durationSeconds) s")
        #expect(withoutLong.durationSeconds == full.durationSeconds)
        #expect(withoutLong.excludedTracks == ["Long"])
    }

    @Test("nothing in the project moves: mute/solo flags, dirty flag and undo stack are untouched")
    func exclusionNeverMutatesTheProject() async throws {
        let fixtures = try TestSignals.fixtures()
        let vocal = Track(name: "Vocal", kind: .audio,
                          clips: [Clip(name: "v", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        let keys = Track(name: "Keys", kind: .audio,
                         clips: [Clip(name: "k", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let store = makeStore(tracks: [vocal, keys], engine: engine)
        let dir = try makeTempDir("nomutate")
        let before = store.tracks
        #expect(!store.isDirty)
        let undoBefore = store.journal.undoLabel

        _ = try await store.renderBounce(
            toPath: dir.appendingPathComponent("a.wav").path,
            durationSeconds: 0.5, excludeTrackIds: [vocal.id])
        _ = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("b.wav").path,
            durationSeconds: 0.5, excludeTrackIds: [vocal.id])

        #expect(store.tracks == before, "the render-local mute-copy leaked into the model")
        #expect(store.tracks.allSatisfy { !$0.isMuted })
        #expect(!store.isDirty, "an exclusion render must not dirty the project")
        #expect(store.journal.undoLabel == undoBefore, "an exclusion render is not an edit")
    }

    @Test("render.mixdown honours the exclusion too, and an unknown id rejects before rendering")
    func mixdownPathAndRejection() async throws {
        let fixtures = try TestSignals.fixtures()
        let vocal = Track(name: "Vocal", kind: .audio,
                          clips: [Clip(name: "v", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        let keys = Track(name: "Keys", kind: .audio,
                         clips: [Clip(name: "k", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let store = makeStore(tracks: [vocal, keys], engine: engine)
        let dir = try makeTempDir("mixdown")

        let full = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("full.wav").path, durationSeconds: 1.0)
        let instrumental = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("instrumental.wav").path,
            durationSeconds: 1.0, excludeTrackIds: [vocal.id])
        #expect(full.excludedTracks == nil)
        #expect(instrumental.excludedTracks == ["Vocal"])
        let fullAudio = try TestSignals.readFile(URL(fileURLWithPath: full.path))
        let instrumentalAudio = try TestSignals.readFile(
            URL(fileURLWithPath: instrumental.path))
        let difference = residualPeak(fullAudio, instrumentalAudio)
        print("[measured] m23-m1 render.mixdown exclusion: |full − instrumental| peak \(difference)")
        #expect(difference > 0.05)

        let stray = UUID()
        do {
            _ = try await store.renderMixdown(
                toPath: dir.appendingPathComponent("bad.wav").path,
                durationSeconds: 1.0, excludeTrackIds: [stray])
            Issue.record("expected trackNotFound")
        } catch let ProjectError.trackNotFound(id) {
            #expect(id == stray)
        }
        #expect(!FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("bad.wav").path),
            "a rejected exclusion must not have written anything")
    }
}
