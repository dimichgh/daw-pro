import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m15-c — the S-3 family with a MASTER VOLUME LANE ACTIVE, over the real
/// store + engine (the MasterChainRenderTests harness):
///
///  · Σ-stems ≡ the stems' own reference mixdown ≤ 1e-4 (S-3 holds — both
///    exclude the lane, and stems stay a partition of linear material).
///  · The lane does NOT leak into stems: the MASTERED bounce fades to
///    silence while Σ-stems keeps ringing (the discriminating pair — the
///    m13-d C2 idiom with a fade instead of a ceiling).
///  · `track.bounceInPlace` == that track's stem, byte-for-byte, with the
///    lane active (both STEM class — the m11-e law survives m15-c).
///  · STORE-path static equivalence: `mixer.setMasterVolume(0.5)` ==
///    a flat master lane at 0.5, byte-identical mixdown THROUGH the real
///    store wiring (0.5 is a power of two, so per-input accumulation
///    commutes and even the multi-track case is exact).
@MainActor
@Suite("Master automation — stems / S-3 family (m15-c)", .serialized)
struct MasterAutomationStemsTests {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-master-auto-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(tracks: [Track], engine: AudioEngine) -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        store.tracks = tracks
        return store
    }

    private func sumFiles(_ paths: [String]) throws -> [[Float]] {
        var sum: [[Float]] = []
        for path in paths {
            let channels = try TestSignals.readFile(URL(fileURLWithPath: path))
            if sum.isEmpty {
                sum = channels
            } else {
                for channel in 0..<min(channels.count, sum.count) {
                    for frame in 0..<min(channels[channel].count, sum[channel].count) {
                        sum[channel][frame] += channels[channel][frame]
                    }
                }
            }
        }
        return sum
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

    /// Two-track session + a REAL master fade 1→0 over beats 0…2 (1 s @120),
    /// built through the store verbs so the exact production state feeds the
    /// render-class split.
    private func fadeSession() throws -> (ProjectStore, AudioEngine) {
        let fixtures = try TestSignals.fixtures()
        let drums = Track(name: "Drums", kind: .audio, pan: -0.3,
                          clips: [Clip(name: "d", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        let bass = Track(name: "Bass", kind: .audio, volume: 0.7, pan: 0.4,
                         clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        let store = makeStore(tracks: [drums, bass], engine: engine)
        let lane = try store.addMasterAutomationLane(target: .volume)
        _ = try store.setMasterAutomationPoints(laneID: lane.id, points: [
            AutomationPoint(beat: 0, value: 1),
            AutomationPoint(beat: 2, value: 0),
        ])
        return (store, engine)
    }

    @Test("Σ-stems nulls against the reference with a master fade active; the fade never leaks into stems")
    func stemsExcludeMasterFadeAndStillNull() async throws {
        // `ProjectStore.engine` is weak — hold the engine for the test's life.
        let (store, engine) = try fadeSession()
        defer { withExtendedLifetime(engine) {} }
        let dir = try makeTempDir("s3")

        // S-3 with the lane active: Σ-stems ≡ the stems' own reference.
        let result = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("stems").path,
            durationSeconds: 1.0, includeMixdown: true)
        let reference = try TestSignals.readFile(
            URL(fileURLWithPath: try #require(result.mixdown).path))
        let sum = try sumFiles(result.stems.map(\.path))
        let residual = residualPeak(sum, reference)
        print("[measured] Σ-stems vs reference residual peak (master fade active): \(residual)")
        #expect(residual <= 1e-4)

        // The discriminating pair: the MASTERED bounce carries the fade —
        // its last quarter (fade gain ≤ 0.25) collapses — while Σ-stems
        // (lane-excluded) still rings at full level there.
        let bounce = try await store.renderBounce(
            toPath: dir.appendingPathComponent("mastered.wav").path,
            durationSeconds: 1.0)
        let mastered = try TestSignals.readFile(URL(fileURLWithPath: bounce.path))
        let tail = 36_000..<47_500   // 0.75…0.99 s
        let masteredTail = TestSignals.rms(mastered[0], in: tail)
        let stemsTail = TestSignals.rms(sum[0], in: tail)
        let head = 0..<12_000
        let masteredHead = TestSignals.rms(mastered[0], in: head)
        let stemsHead = TestSignals.rms(sum[0], in: head)
        print("[measured] discriminating pair — tail RMS mastered \(masteredTail) vs "
              + "Σ-stems \(stemsTail); head RMS mastered \(masteredHead) vs Σ-stems \(stemsHead)")
        #expect(stemsTail > 0.1)                       // stems did NOT fade
        #expect(masteredTail < stemsTail * 0.25)       // the deliverable DID
        #expect(masteredHead > 0.1)                    // and it is real audio up top
        #expect(stemsHead > 0.1)
    }

    @Test("bounceInPlace == stem, byte-for-byte, with a master fade active (m11-e law survives)")
    func bounceInPlaceStaysByteEqualToStem() async throws {
        // `ProjectStore.engine` is weak — hold the engine for the test's life.
        let (store, engine) = try fadeSession()
        defer { withExtendedLifetime(engine) {} }
        let dir = try makeTempDir("bip")

        let stems = try await store.renderStems(
            toDirectory: dir.path, trackIds: [store.tracks[0].id], durationSeconds: 1.0)
        let stemPath = try #require(stems.stems.first).path
        let bounced = try await store.bounceTrackInPlace(
            trackId: store.tracks[0].id, durationSeconds: 1.0, muteSource: false)

        let stemData = try Data(contentsOf: URL(fileURLWithPath: stemPath))
        let bounceData = try Data(contentsOf: URL(fileURLWithPath: bounced.file))
        print("[measured] bounce==stem with master fade: \(bounceData.count) bytes, "
              + "equal \(bounceData == stemData)")
        #expect(bounceData == stemData)
        #expect(!bounceData.isEmpty)
    }

    @Test("store-path static equivalence: setMasterVolume(0.5) == flat lane at 0.5, byte-identical mixdown")
    func storePathStaticEquivalence() async throws {
        let fixtures = try TestSignals.fixtures()
        func session() -> (ProjectStore, AudioEngine) {
            let a = Track(name: "A", kind: .audio, pan: -0.3,
                          clips: [Clip(name: "a", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
            let b = Track(name: "B", kind: .audio, volume: 0.7, pan: 0.4,
                          clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48Quarter)])
            let engine = AudioEngine()
            return (makeStore(tracks: [a, b], engine: engine), engine)
        }
        let dir = try makeTempDir("static")

        // A: the manual master fader, through the store intent.
        // (`ProjectStore.engine` is weak — hold each engine explicitly.)
        let (manualStore, manualEngine) = session()
        defer { withExtendedLifetime(manualEngine) {} }
        manualStore.setMasterVolume(0.5)
        let manualMix = try await manualStore.renderMixdown(
            toPath: dir.appendingPathComponent("manual.wav").path, durationSeconds: 1.0)

        // B: a flat master lane at 0.5 — with the manual fader parked
        // ELSEWHERE (0.8), so equivalence proves the lane REPLACES it.
        let (laneStore, laneEngine) = session()
        defer { withExtendedLifetime(laneEngine) {} }
        laneStore.setMasterVolume(0.8)
        let lane = try laneStore.addMasterAutomationLane(target: .volume)
        _ = try laneStore.setMasterAutomationPoints(laneID: lane.id, points: [
            AutomationPoint(beat: 0, value: 0.5),
        ])
        let laneMix = try await laneStore.renderMixdown(
            toPath: dir.appendingPathComponent("lane.wav").path, durationSeconds: 1.0)

        let manualData = try Data(contentsOf: URL(fileURLWithPath: manualMix.path))
        let laneData = try Data(contentsOf: URL(fileURLWithPath: laneMix.path))
        print("[measured] store-path static equivalence at 0.5: \(manualData.count) bytes, "
              + "byte-equal \(manualData == laneData)")
        #expect(manualData == laneData)
        // Real audio, not agreeing silences.
        let rendered = try TestSignals.readFile(URL(fileURLWithPath: laneMix.path))
        #expect(TestSignals.rms(rendered[0], in: 0..<24_000) > 0.05)
    }
}
