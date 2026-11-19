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

    // MARK: - m27-m: a windowed measure over a HELD note (the level the user meets)

    /// One poly-synth note (A4) on an instrument track; the clip is 16 beats long
    /// either way so a window at beat 8 is always inside the project.
    private func heldNoteStore(noteLengthBeats: Double) -> (store: ProjectStore, engine: AudioEngine) {
        let clip = Clip(name: "held", startBeat: 0, lengthBeats: 16, notes: [
            MIDINote(pitch: 69, velocity: 100, startBeat: 0, lengthBeats: noteLengthBeats)])
        // nil instrument descriptor -> the built-in poly synth (the default voice).
        let track = Track(name: "Held", kind: .instrument, clips: [clip])
        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine   // weak in the store: the caller must hold the engine
        store.tracks = [track]
        return (store, engine)
    }

    @Test("m27-m: a window opening mid-note reads the held note (re-attack), an empty stretch reads silent")
    func windowedMeasureOverHeldNote() async throws {
        // 120 BPM: beat 8 = 4.0 s. The note spans beats 0-16 (0-8 s), so a 2 s window
        // at beat 8 opens 4 s INTO the note and closes 2 s before it ends.
        let (held, heldEngine) = heldNoteStore(noteLengthBeats: 16)
        _ = heldEngine
        let mid = try await held.measureLoudness(fromBeat: 8, durationSeconds: 2.0)
        let fromZero = try await held.measureLoudness(fromBeat: 0, durationSeconds: 2.0)
        // CONTROL: the note ends at beat 4 (2 s); the 2 s window at beat 8 (4-6 s) is
        // past its release, inside the same 16-beat clip.
        let (short, shortEngine) = heldNoteStore(noteLengthBeats: 4)
        _ = shortEngine
        let empty = try await short.measureLoudness(fromBeat: 8, durationSeconds: 2.0)

        print("[measured] m27-m held note: mid-note (beat 8) integrated \(String(describing: mid.measurement.integratedLufs)) "
              + "LUFS / peak \(String(describing: mid.measurement.truePeakDbtp)) dBTP; "
              + "from beat 0 \(String(describing: fromZero.measurement.integratedLufs)) LUFS; "
              + "empty stretch \(String(describing: empty.measurement.integratedLufs)) LUFS / "
              + "peak \(String(describing: empty.measurement.truePeakDbtp)) dBTP")

        // THRESHOLD -50 LUFS integrated / -50 dBTP peak: the absolute gate is -70 LUFS
        // (nil below it) and a poly-synth A4 at velocity 100 renders far louder; -50
        // keeps >20 LU of margin yet is nowhere near silence. A dropped note reads nil.
        let midLufs = try #require(mid.measurement.integratedLufs,
            "a window opening mid-note must re-attack the held note, not read silent (m23-bv)")
        let midPeak = try #require(mid.measurement.truePeakDbtp)
        #expect(midLufs > -50)
        #expect(midPeak > -50)
        // Invariance: the same steady tone from beat 0 is non-silent and the same order.
        let zeroLufs = try #require(fromZero.measurement.integratedLufs)
        #expect(zeroLufs > -50)
        #expect(abs(zeroLufs - midLufs) < 6)
        // Control: past the note's end the window is silent (nil = below the -70 gate).
        #expect((empty.measurement.integratedLufs ?? -.infinity) <= -70)
        #expect((empty.measurement.truePeakDbtp ?? -.infinity) < -80)
    }
}
