import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m23-m1 — `render.stems` `includeMasteredMixdown`, against the real offline
/// engine. Two distinct legs, because the shipped shape makes the roadmap's
/// original "Σ mastered stems ≡ mastered mixdown" test meaningless:
///
///  1. **Σ raw stems ≡ "00 Mixdown.wav" ≤ 1e-4 still holds** while the
///     mastered sibling is being written in the SAME call — the shipped
///     invariant (`StemNullTests.swift:8`, `MasterAutomationStemsTests.swift:10`,
///     tolerance INHERITED, not re-chosen) is not disturbed by the addition.
///     The stem files are additionally proven BYTE-IDENTICAL with and without
///     the flag.
///  2. **Σ raw stems does NOT null against "00 Mastered Mix.wav"** — and the
///     leg is built so that difference can only be the chain:
///     · the master insert is a **saturator (tanh waveshaper) at 30 dB drive**
///       — genuinely NONLINEAR, so `Σᵢ M(sᵢ) ≠ M(Σᵢ sᵢ)` (S-3′, research
///       §4.3) — and **memoryless/zero-latency**, so no timing shift can be
///       mistaken for nonlinearity (a limiter's 5 ms lookahead would have
///       muddied exactly that);
///     · the mastered pass runs under the same forced full-session PDC targets
///       as every stem, removing alignment as a confound;
///     · a POSITIVE CONTROL renders the identical project with an EMPTY master
///       chain and shows the same comparison DOES null ≤ 1e-4 — proving the
///       leg measures the chain and not noise. **Without that control this
///       whole leg is vacuous**: with no chain (or a gain-only one) the two
///       files agree, so a fixture without a real nonlinearity proves nothing.
///
/// Plus: the mastered file carries a real `BounceLoudnessReport` measured on
/// what actually hit disk (the `render.bounce` machinery, one home).
@MainActor
@Suite("Mastered mixdown sibling — S-3′ legs (m23-m1)", .serialized)
struct MasteredMixdownStemsTests {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-mastered-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(tracks: [Track], engine: AudioEngine) -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        store.tracks = tracks
        return store
    }

    /// Distinct levels + pans so Σ stems is a real superposition, not two
    /// identical signals agreeing by luck (the `StemNullTests` fixture idiom).
    private func fixtureTracks() throws -> [Track] {
        let fixtures = try TestSignals.fixtures()
        let drums = Track(name: "Drums", kind: .audio, pan: -0.3,
                          clips: [Clip(name: "d", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        let bass = Track(name: "Bass", kind: .audio, volume: 0.7, pan: 0.4,
                         clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        return [drums, bass]
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

    private func filePeak(_ path: String) throws -> Float {
        let channels = try TestSignals.readFile(URL(fileURLWithPath: path))
        var peak: Float = 0
        for channel in channels {
            for sample in channel { peak = max(peak, abs(sample)) }
        }
        return peak
    }

    // MARK: - Legs 1 + 2 + the positive control

    @Test("Σ stems still nulls against 00 Mixdown.wav, does NOT null against 00 Mastered Mix.wav, and DOES with an empty chain")
    func stemsNullAnchorHoldsAndMasteredDiffersByTheChain() async throws {
        // `ProjectStore.engine` is weak — hold the engine for the test's life.
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let store = makeStore(tracks: try fixtureTracks(), engine: engine)
        let dir = try makeTempDir("s3prime")

        // ── POSITIVE CONTROL first, on the SAME project with NO master chain,
        // no master automation lane and no normalization: the mastered pass is
        // then linear-identical to the chain-excluded one, so Σ stems MUST
        // null against the mastered file too. This is what proves the main leg
        // below is measuring the chain rather than render noise or a bug.
        #expect(store.masterEffects.isEmpty)
        #expect(store.masterAutomation.isEmpty)
        let control = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("control").path,
            durationSeconds: 1.0, includeMixdown: true, includeMasteredMixdown: true)
        let controlMastered = try TestSignals.readFile(
            URL(fileURLWithPath: try #require(control.masteredMixdown).path))
        let controlSum = try sumFiles(control.stems.map(\.path))
        let controlResidual = residualPeak(controlSum, controlMastered)
        print("[measured] m23-m1 POSITIVE CONTROL (empty master chain): "
            + "Σ-stems vs 00 Mastered Mix.wav residual peak \(controlResidual)")
        #expect(controlResidual <= 1e-4)
        // …and it is real audio agreeing, not two silences.
        #expect(TestSignals.rms(controlMastered[0], in: 0..<24_000) > 0.1)

        // ── Now the nonlinearity. Saturator = tanh waveshaper, MEMORYLESS and
        // zero-latency (no oversampling in v0), driven hard at 30 dB so the
        // bend is unmistakable — the one property this leg depends on.
        let saturator = try store.addMasterEffect(kind: .saturator)
        _ = try store.setMasterEffectParam(effectID: saturator.id,
                                           name: "driveDb", value: 30)
        _ = try store.setMasterEffectParam(effectID: saturator.id,
                                           name: "mix", value: 1)
        #expect(store.masterEffects.count == 1)
        #expect(store.masterEffects[0].kind == .saturator)

        let result = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("chain").path,
            durationSeconds: 1.0, includeMixdown: true, includeMasteredMixdown: true)

        // Both files exist and are DIFFERENT files with different meanings.
        let mixdownPath = try #require(result.mixdown).path
        let masteredPath = try #require(result.masteredMixdown).path
        #expect(mixdownPath.hasSuffix("00 Mixdown.wav"))
        #expect(masteredPath.hasSuffix("00 Mastered Mix.wav"))
        #expect(mixdownPath != masteredPath)
        #expect(FileManager.default.fileExists(atPath: masteredPath))
        // The stems are still advertised as chain-EXCLUDED — m23-m1 does not
        // touch that live honesty string.
        #expect(result.masterChain == "excluded")

        let stemSum = try sumFiles(result.stems.map(\.path))

        // ── LEG 1: the shipped invariant survives the addition, at the
        // INHERITED 1e-4 tolerance.
        let mixdown = try TestSignals.readFile(URL(fileURLWithPath: mixdownPath))
        let anchorResidual = residualPeak(stemSum, mixdown)
        print("[measured] m23-m1 LEG 1: Σ-stems vs 00 Mixdown.wav residual peak "
            + "\(anchorResidual) (gate 1e-4)")
        #expect(anchorResidual <= 1e-4)
        #expect(TestSignals.rms(mixdown[0], in: 0..<24_000) > 0.1)

        // ── LEG 2: Σ-stems does NOT null against the MASTERED file, by orders
        // of magnitude — and the saturator really bent the signal (the
        // mastered peak is far above the pre-master sum's).
        let mastered = try TestSignals.readFile(URL(fileURLWithPath: masteredPath))
        let masteredResidual = residualPeak(stemSum, mastered)
        print("[measured] m23-m1 LEG 2: Σ-stems vs 00 Mastered Mix.wav residual peak "
            + "\(masteredResidual) — the NONLINEAR (tanh, 30 dB drive) master chain")
        #expect(masteredResidual > 0.05)
        // The contrast IS the proof: the same sum nulls against one file and
        // misses the other by orders of magnitude.
        #expect(masteredResidual > anchorResidual * 100)
        #expect(masteredResidual > controlResidual * 100)
        // WHAT the chain did, measured as SHAPE rather than level — the
        // saturator applies a −driveDb/2 makeup (wet = tanh(g·x)·g^(−1/2)), so
        // a level comparison alone would be ambiguous. Crest factor is not:
        // the pre-master sum is a sinusoid (RMS/peak ≈ 0.707) while a hard-
        // driven tanh squashes it toward a square (RMS/peak → 1). That
        // collapse is the nonlinearity itself, and it is what the stems can
        // never reproduce by summation.
        let masteredPeak = try filePeak(masteredPath)
        let window = 0..<24_000
        let sumCrest = TestSignals.rms(mixdown[0], in: window)
            / TestSignals.peak(mixdown[0], in: window)
        let masteredCrest = TestSignals.rms(mastered[0], in: window)
            / TestSignals.peak(mastered[0], in: window)
        print("[measured] m23-m1 LEG 2: RMS/peak — pre-master sum \(sumCrest) (sinusoid ≈0.707), "
            + "mastered \(masteredCrest) (square ≈1.0); mastered peak \(masteredPeak)")
        #expect(sumCrest < 0.75)
        #expect(masteredCrest > 0.9)
        #expect(masteredPeak <= 1.0)   // tanh is bounded — it cannot clip past full scale

        // ── The stems themselves are UNTOUCHED by the flag: same call shape
        // without `includeMasteredMixdown`, byte-identical stem files.
        let withoutMastered = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("nomaster").path,
            durationSeconds: 1.0, includeMixdown: true)
        #expect(withoutMastered.masteredMixdown == nil)
        for (index, stem) in result.stems.enumerated() {
            let a = try Data(contentsOf: URL(fileURLWithPath: stem.path))
            let b = try Data(contentsOf: URL(fileURLWithPath: withoutMastered.stems[index].path))
            #expect(a == b, "stem '\(stem.name)' changed when the mastered sibling was requested")
        }
        let anchorA = try Data(contentsOf: URL(fileURLWithPath: mixdownPath))
        let anchorB = try Data(contentsOf: URL(
            fileURLWithPath: try #require(withoutMastered.mixdown).path))
        #expect(anchorA == anchorB, "00 Mixdown.wav changed when the mastered sibling was requested")
    }

    // MARK: - Leg 4: loudness / true peak measured on the mastered output

    @Test("masteredLufsTarget normalizes the mastered file only; the report describes what hit disk")
    func masteredNormalizationRidesTheBounceMachinery() async throws {
        // `ProjectStore.engine` is weak — hold the engine for the test's life.
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let store = makeStore(tracks: try fixtureTracks(), engine: engine)
        let dir = try makeTempDir("loudness")
        let saturator = try store.addMasterEffect(kind: .saturator)
        _ = try store.setMasterEffectParam(effectID: saturator.id,
                                           name: "driveDb", value: 30)

        // Un-normalized first — the reference the gain is measured against.
        let plain = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("plain").path,
            durationSeconds: 1.0, includeMasteredMixdown: true)
        let plainMastered = try #require(plain.masteredMixdown)
        #expect(plainMastered.report.appliedGainDb == 0)
        #expect(plainMastered.report.lufsTarget == nil)
        #expect(plainMastered.report.limitedByCeiling == false)
        let plainIntegrated = try #require(plainMastered.report.input.integratedLufs)
        #expect(plainMastered.report.output.integratedLufs == plainIntegrated)
        let plainPeak = try filePeak(plainMastered.path)

        // Normalized to -16 LUFS through the SAME gain-only policy
        // `render.bounce` runs (one home — `deliveryNormalized`).
        let target = -16.0
        let normalized = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("normalized").path,
            durationSeconds: 1.0, includeMasteredMixdown: true,
            masteredLufsTarget: target)
        let file = try #require(normalized.masteredMixdown)
        #expect(file.report.lufsTarget == target)
        let achieved = try #require(file.report.output.integratedLufs)
        let gain = file.report.appliedGainDb
        let truePeak = try #require(file.report.output.truePeakDbtp)
        print("[measured] m23-m1 LEG 4: mastered input \(plainIntegrated) LUFS → "
            + "gain \(gain) dB → output \(achieved) LUFS, true peak \(truePeak) dBTP "
            + "(target \(target), ceiling -1.0, clamped \(file.report.limitedByCeiling))")
        #expect(!file.report.limitedByCeiling)
        #expect(abs(achieved - target) < 0.5)
        #expect(truePeak <= -1.0 + 0.01)
        #expect(abs(gain - (target - plainIntegrated)) < 0.01)

        // The report describes the FILE, not an intention: the on-disk peak
        // moved by exactly the reported gain.
        let normalizedPeak = try filePeak(file.path)
        let expectedPeak = plainPeak * Float(pow(10.0, gain / 20.0))
        print("[measured] m23-m1 LEG 4: on-disk peak \(plainPeak) → \(normalizedPeak) "
            + "(expected \(expectedPeak))")
        #expect(abs(normalizedPeak - expectedPeak) <= expectedPeak * 0.01)

        // Stems are NEVER normalized — the target reached the mastered file
        // and nothing else (byte-identical stem files across the two calls).
        for (index, stem) in plain.stems.enumerated() {
            let a = try Data(contentsOf: URL(fileURLWithPath: stem.path))
            let b = try Data(contentsOf: URL(fileURLWithPath: normalized.stems[index].path))
            #expect(a == b, "stem '\(stem.name)' was affected by masteredLufsTarget")
        }
    }

    // MARK: - The lane rides the mastered file (m15-c class check)

    @Test("The master volume LANE lands in the mastered file and stays out of the stems' anchor")
    func masterAutomationLaneRidesTheMasteredFile() async throws {
        // `ProjectStore.engine` is weak — hold the engine for the test's life.
        let engine = AudioEngine()
        defer { withExtendedLifetime(engine) {} }
        let store = makeStore(tracks: try fixtureTracks(), engine: engine)
        let dir = try makeTempDir("lane")
        // A hard fade to silence over the rendered second: MASTERED material
        // (m15-c) — it must be audible in the mastered sibling and absent from
        // the chain-excluded anchor, exactly like `render.bounce` vs stems.
        let lane = try store.addMasterAutomationLane(target: .volume)
        _ = try store.setMasterAutomationPoints(laneID: lane.id, points: [
            AutomationPoint(beat: 0, value: 1),
            AutomationPoint(beat: 2, value: 0),
        ])

        let result = try await store.renderStems(
            toDirectory: dir.path, durationSeconds: 1.0,
            includeMixdown: true, includeMasteredMixdown: true)
        let anchor = try TestSignals.readFile(
            URL(fileURLWithPath: try #require(result.mixdown).path))
        let mastered = try TestSignals.readFile(
            URL(fileURLWithPath: try #require(result.masteredMixdown).path))
        // Late window: the lane has faded the mastered file far down while the
        // stems' anchor still rings at full level.
        let late = 40_000..<47_000
        let anchorLate = TestSignals.rms(anchor[0], in: late)
        let masteredLate = TestSignals.rms(mastered[0], in: late)
        print("[measured] m23-m1 lane: anchor late RMS \(anchorLate), mastered late RMS \(masteredLate)")
        #expect(anchorLate > 0.1)
        #expect(masteredLate < anchorLate * 0.25)
        // Σ stems still nulls against the anchor with a lane active (m15-c).
        let sum = try sumFiles(result.stems.map(\.path))
        let residual = residualPeak(sum, anchor)
        print("[measured] m23-m1 lane: Σ-stems vs anchor residual peak \(residual)")
        #expect(residual <= 1e-4)
    }
}
