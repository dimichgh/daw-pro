import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m12-g S-3 RELEASE-BLOCKING equivalence gates (design
/// docs/research/design-m11f-sidechain.md §9 S-3, §10 condition 3): re-run the
/// m11-d/m11-e machinery WITH an ACTIVE sidechain. A keyed session must satisfy
/// all three or the feature does not ship:
///
///   (a) `render.stems includeMixdown` — Σ stems ≡ mixdown, peak residual
///       ≤ 1e-4. Proves the keyed effect's gain-reduction curve is IDENTICAL
///       in every solo pass and the full mixdown (the StemPlan key-source
///       silent-dummy-bus closure at work) — otherwise a stem would render its
///       compressor WITHOUT the key and drift.
///   (b) `track.bounceInPlace` of the KEYED track is BYTE-IDENTICAL to its
///       single-track `render.stems` (both reuse `StemPlan.passTracks`, so a
///       keyed bounce carries the key exactly as its stem does — the m11-e
///       byte-identity property survives keying).
///   (c) loudness honesty — `measureLoudness` on the keyed session reports a
///       finite, sane integrated loudness (the keyed compressor never produces
///       NaN/±inf or a gate-collapsed measurement).
///
/// These are PERMANENT gates: the m12-f suite proved keyed Σ-stems once by
/// construction; this suite locks the whole S-3 contract so keyed stem/bounce
/// drift can never land silently.
@MainActor
@Suite("Sidechain equivalence gates (m12-g S-3)", .serialized)
struct SidechainEquivalenceTests {

    /// A kick→pad session: a key track (cosine, drives the detector) and a
    /// destination track whose FIRST insert is a compressor keyed off the key
    /// track — so the whole render carries an ACTIVE sidechain. Both tracks are
    /// direct-to-master audio (eligible bounce/stem targets). 120 BPM, 2.0 s.
    /// Returns the `engine` too: `ProjectStore.engine` is a WEAK reference, so
    /// the caller must hold it for the render's lifetime (else `.engineUnavailable`).
    private func keyedStore() throws -> (store: ProjectStore, engine: AudioEngine,
                                         keyID: UUID, padID: UUID) {
        let fixtures = try TestSignals.fixtures()
        let key = Track(name: "Kick", kind: .audio, clips: [
            Clip(name: "kick", startBeat: 0, lengthBeats: 4, audioFileURL: fixtures.cos1k48)])
        var pad = Track(name: "Pad", kind: .audio, clips: [
            Clip(name: "pad", startBeat: 0, lengthBeats: 4, audioFileURL: fixtures.cos1k48)])
        // Threshold −20 / ratio 4 / fast attack — a compressor that genuinely
        // ducks the pad off the kick throughout the render (an ACTIVE key).
        pad.effects = [EffectDescriptor(
            kind: .compressor,
            compressor: CompressorParams(thresholdDb: -20, ratio: 4, attackMs: 0.1,
                                         releaseMs: 5, kneeDb: 0, makeupDb: 0))]
        pad.effects[0].sidechainSourceTrackID = key.id

        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        store.tracks = [key, pad]
        return (store, engine, key.id, pad.id)
    }

    // MARK: - Gate (a): Σ stems ≡ mixdown with an active sidechain

    @Test("(a) Σ stems ≡ mixdown ≤ 1e-4 residual with an ACTIVE sidechain")
    func keyedStemsEqualMixdown() async throws {
        let (store, engine, _, _) = try keyedStore()
        _ = engine  // hold the weak-referenced engine alive for the render
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m12g-stems-\(UUID().uuidString)")

        let result = try await store.renderStems(
            toDirectory: dir.path, trackIds: nil, fromBeat: 0,
            durationSeconds: 2.0, includeMixdown: true)
        let mixdown = try #require(result.mixdown)
        #expect(result.stems.count == 2)

        var sum: [[Float]] = []
        for stem in result.stems {
            let channels = try TestSignals.readFile(URL(fileURLWithPath: stem.path))
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
        let reference = try TestSignals.readFile(URL(fileURLWithPath: mixdown.path))
        var residual: Float = 0
        for channel in 0..<min(sum.count, reference.count) {
            for frame in 0..<min(sum[channel].count, reference[channel].count) {
                residual = max(residual, abs(sum[channel][frame] - reference[channel][frame]))
            }
        }
        print("[measured] m12g S-3(a): keyed Σ-stems residual peak \(residual) (gate 1e-4)")
        #expect(residual <= 1e-4)
    }

    // MARK: - Gate (b): keyed bounce byte-identical to its single-track stem

    @Test("(b) bounceInPlace of the KEYED track is byte-identical to its single-track stem")
    func keyedBounceEqualsStem() async throws {
        let (store, engine, _, padID) = try keyedStore()
        _ = engine  // hold the weak-referenced engine alive for the render

        // The single-track stem of the keyed pad (no store mutation).
        let stemDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m12g-stem-\(UUID().uuidString)")
        let stemResult = try await store.renderStems(
            toDirectory: stemDir.path, trackIds: [padID], fromBeat: 0,
            durationSeconds: 2.0, includeMixdown: false)
        let stem = try #require(stemResult.stems.first)
        let stemBytes = try Data(contentsOf: URL(fileURLWithPath: stem.path))

        // Bounce the keyed pad in place over the SAME window (muteSource:false so
        // the render sees the identical session; the render precedes the edit).
        let bounce = try await store.bounceTrackInPlace(
            trackId: padID, fromBeat: 0, durationSeconds: 2.0, muteSource: false)
        let bounceBytes = try Data(contentsOf: URL(fileURLWithPath: bounce.file))

        let identical = stemBytes == bounceBytes
        print("[measured] m12g S-3(b): keyed bounce == single-track stem \(identical) "
              + "(\(bounceBytes.count) vs \(stemBytes.count) bytes)")
        #expect(identical)
        #expect(bounceBytes.count == stemBytes.count)
    }

    // MARK: - Gate (c): loudness honesty on the keyed session

    @Test("(c) measureLoudness on the keyed session is finite and sane")
    func keyedLoudnessHonesty() async throws {
        let (store, engine, _, _) = try keyedStore()
        _ = engine  // hold the weak-referenced engine alive for the render
        let measured = try await store.measureLoudness(fromBeat: 0, durationSeconds: 2.0)
        let integrated = try #require(measured.measurement.integratedLufs,
                                      "a real keyed program must report an integrated loudness")
        print("[measured] m12g S-3(c): keyed integrated loudness \(integrated) LUFS, "
              + "duration \(measured.durationSeconds) s")
        // Finite (no NaN/±inf from the keyed detector math) and inside the sane
        // program-loudness band (above the −70 gate, below full scale).
        #expect(integrated.isFinite)
        #expect(integrated > -70 && integrated < 0)
        #expect(measured.durationSeconds > 0)
    }
}
