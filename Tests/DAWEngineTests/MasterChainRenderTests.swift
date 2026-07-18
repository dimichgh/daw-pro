import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m13-d master insert chain — the render-contract gates over the REAL
/// offline engine (design-m13d §2/§5, gate form §8):
///
///  · C2 — analytic master-limiter ceiling: the MASTERED program obeys the
///    ceiling while Σ-stems exceeds it (one discriminating pair proving
///    stems are pre-chain and the mastered path is post-chain).
///  · C3 — the restated stems contract S-3′: with a master chain ACTIVE,
///    Σ-stems ≡ the chain-excluded "00 Mixdown.wav" reference (≤ 1e-4
///    residual), `render.stems` carries `masterChain:"excluded"`,
///    bounce-in-place stays byte==stem, and a linear-unity master chain
///    (gain @ 0 dB, zero latency) leaves the MASTERED mixdown ≡ the
///    empty-chain mixdown.
///  · C7 — PDC: a master limiter moves ONLY the report's
///    `masterChainLatencySamples` / `outputLatencySamples` (ACTIVE-sum
///    rule under bypass); per-strip `compensationSamples` are provably
///    unaffected (the common-path proof, design D5).
@MainActor
@Suite("Master chain render contract (m13-d C2/C3/C7)", .serialized)
struct MasterChainRenderTests {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-masterchain-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(tracks: [Track], engine: AudioEngine) -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        store.tracks = tracks
        return store
    }

    /// Two full-amp-sum cosine tracks: the mix's sample peak is ~1.0, far
    /// above any test ceiling — the program that MUST limit. The envelope is
    /// what makes C2 ANALYTIC (measured, not hand-waved):
    ///
    ///  · 1-beat fade-in (0.5 s @ 120): the limiter's gain tracks a slow
    ///    envelope (−10 dB over ~0.3 s, ~0.03 dB per 1 kHz cycle) instead of
    ///    hard-clamping cycles — steady state is a CLEAN sine at the ceiling
    ///    (measured interior true peak −10.002 dBTP for C = −10). A
    ///    from-frame-0 hot program flat-tops the attack cycles and the
    ///    band-limited reconstruction overshoots ~1 dB — clipping physics,
    ///    not a routing fact.
    ///  · 0.5-beat fade-out with the clip ENDING INSIDE the render window:
    ///    `Loudness.truePeakLinear` zero-pads beyond the buffer ("exact for
    ///    rendered material, which starts and ends at rest") — truncating a
    ///    full-amplitude sine at the file end makes the edge convolution
    ///    windows ring ~+0.95 dB (measured at frame N−2 of the cut). The
    ///    program must genuinely END AT REST for dBTP to be analytic.
    private func hotSession() throws -> [Track] {
        let fixtures = try TestSignals.fixtures()
        return [
            Track(name: "Hot A", kind: .audio,
                  clips: [Clip(name: "a", startBeat: 0, lengthBeats: 2,
                               audioFileURL: fixtures.cos1k48,
                               fadeInBeats: 1, fadeOutBeats: 0.5)]),
            Track(name: "Hot B", kind: .audio,
                  clips: [Clip(name: "b", startBeat: 0, lengthBeats: 2,
                               audioFileURL: fixtures.cos1k48,
                               fadeInBeats: 1, fadeOutBeats: 0.5)]),
        ]
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

    private func samplePeak(_ channels: [[Float]]) -> Float {
        var peak: Float = 0
        for channel in channels {
            for sample in channel { peak = max(peak, abs(sample)) }
        }
        return peak
    }

    // MARK: - C2: analytic master-limiter ceiling

    @Test("C2: mastered bounce obeys the master limiter ceiling; Σ-stems exceeds it (pre-chain proof)")
    func masteredCeilingVersusStems() async throws {
        let engine = AudioEngine()
        let store = makeStore(tracks: try hotSession(), engine: engine)
        let dir = try makeTempDir("c2")

        // Master chain: neutral EQ + limiter at −10 dB (design's audit
        // recipe, EQ then limiter), built through the STORE methods so the
        // exact production state feeds the render class split.
        _ = try store.addMasterEffect(kind: .eq)
        let limiter = try store.addMasterEffect(kind: .limiter)
        _ = try store.setMasterEffectParam(effectID: limiter.id,
                                           name: "ceilingDb", value: -10)
        let ceilingLinear = Float(pow(10.0, -10.0 / 20.0))

        // MASTERED class: render.bounce (no lufsTarget → no static gain).
        let bounce = try await store.renderBounce(
            toPath: dir.appendingPathComponent("mastered.wav").path,
            durationSeconds: 1.0)
        let mastered = try TestSignals.readFile(URL(fileURLWithPath: bounce.path))
        let masteredPeak = samplePeak(mastered)

        // STEM class: Σ-stems is the chain-excluded material.
        let stems = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("stems").path,
            durationSeconds: 1.0)
        let stemSumPeak = samplePeak(try sumFiles(stems.stems.map(\.path)))

        let reportedTruePeak = bounce.report.input.truePeakDbtp
        print("[measured] C2: mastered sample peak \(masteredPeak) vs ceiling "
              + "\(ceilingLinear) (reported true peak \(String(describing: reportedTruePeak)) dBTP); "
              + "Σ-stems sample peak \(stemSumPeak)")
        // Hard limiter guarantee: every mastered sample ≤ ceiling (+1 ulp
        // headroom, the FXPack1 precedent); true peak ≤ C + ε where ε covers
        // interpolation-filter ripple ONLY (0.1 dB; the analytic program is
        // a clean at-ceiling sine that starts and ends at rest — measured
        // −10.002 dBTP, see `hotSession`).
        #expect(masteredPeak <= ceilingLinear + 1e-6)
        let truePeak = try #require(reportedTruePeak)
        #expect(truePeak <= -10.0 + 0.1)
        // The discriminating half: the pre-chain material is LOUDER than the
        // ceiling — stems did NOT pass through the master limiter.
        #expect(stemSumPeak > ceilingLinear * 2)
        // It actually limited (not muted).
        #expect(masteredPeak > ceilingLinear * 0.9)
    }

    // MARK: - C3: the S-3′ stems contract

    @Test("C3: chain ACTIVE — Σ-stems ≡ chain-excluded reference; masterChain:'excluded'; bounce==stem; linear-unity ≡ empty chain")
    func stemsContractS3Prime() async throws {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        let bus = Track(id: busID, name: "FXBus", kind: .bus,
                        effects: [EffectDescriptor(
                            kind: .delay,
                            delay: DelayParams(timeMs: 200, feedback: 0.4, mix: 0.5,
                                               pingPong: 0, highCutHz: 10_000))])
        let keys = Track(name: "Keys", kind: .audio,
                         clips: [Clip(name: "k", startBeat: 0, lengthBeats: 2,
                                      audioFileURL: fixtures.cos1k48)],
                         sends: [Send(destinationBusID: busID, level: 0.5)])
        let dry = Track(name: "Dry", kind: .audio, volume: 0.7,
                        clips: [Clip(name: "d", startBeat: 0, lengthBeats: 2,
                                     audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        let store = makeStore(tracks: [bus, keys, dry], engine: engine)
        let dir = try makeTempDir("c3")

        // Empty chain first: the honesty field is ABSENT (nil → key omitted).
        let cleanStems = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("clean").path,
            durationSeconds: 1.0)
        #expect(cleanStems.masterChain == nil)

        // Activate a latent, nonlinear master chain (EQ + limiter −6).
        _ = try store.addMasterEffect(kind: .eq)
        let limiter = try store.addMasterEffect(kind: .limiter)
        _ = try store.setMasterEffectParam(effectID: limiter.id,
                                           name: "ceilingDb", value: -6)

        // S-3′: Σ-stems ≡ the stems' own chain-excluded reference render.
        let result = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("stems").path,
            durationSeconds: 1.0, includeMixdown: true)
        #expect(result.masterChain == "excluded")
        let reference = try TestSignals.readFile(
            URL(fileURLWithPath: try #require(result.mixdown).path))
        let sum = try sumFiles(result.stems.map(\.path))
        let residual = residualPeak(sum, reference)
        print("[measured] C3 S-3′: Σ-stems vs chain-excluded reference residual peak \(residual)")
        #expect(residual <= 1e-4)
        // Real audio, not agreeing silences.
        #expect(TestSignals.rms(reference[0], in: 0..<24_000) > 0.1)

        // bounceTrackInPlace == that track's stem, byte-for-byte (both STEM
        // class; the m11-e law survives the master chain).
        let keysStem = try #require(result.stems.first { $0.name == "Keys" })
        let bounced = try await store.bounceTrackInPlace(
            trackId: keys.id, durationSeconds: 1.0, muteSource: false)
        let stemData = try Data(contentsOf: URL(fileURLWithPath: keysStem.path))
        let bounceData = try Data(contentsOf: URL(fileURLWithPath: bounced.file))
        print("[measured] C3 bounce==stem: \(bounceData.count) bytes, equal \(bounceData == stemData)")
        #expect(bounceData == stemData)

        // Linear-unity check: replace the chain with gain @ unity (zero
        // latency, linear) — the MASTERED mixdown ≡ the empty-chain mixdown
        // (sample-wise comparison is valid only because the chain is
        // zero-latency).
        try store.removeMasterEffect(effectID: limiter.id)
        for effect in store.masterEffects {
            try store.removeMasterEffect(effectID: effect.id)
        }
        let emptyMix = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("empty-chain.wav").path,
            durationSeconds: 1.0)
        _ = try store.addMasterEffect(kind: .gain)  // gainLinear default = 1 (0 dB)
        let unityMix = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("unity-chain.wav").path,
            durationSeconds: 1.0)
        let empty = try TestSignals.readFile(URL(fileURLWithPath: emptyMix.path))
        let unity = try TestSignals.readFile(URL(fileURLWithPath: unityMix.path))
        let unityResidual = residualPeak(empty, unity)
        print("[measured] C3 linear-unity: mastered(gain@0dB) vs empty-chain residual peak \(unityResidual)")
        #expect(unityResidual <= 1e-4)
    }

    // MARK: - C7: PDC — report-only, common-path

    @Test("C7: master limiter feeds outputLatency (ACTIVE sum, bypass reverts); per-strip compensation byte-equal")
    func pdcMasterChainReportOnly() throws {
        let limited = Track(name: "Lim", kind: .audio,
                            effects: [EffectDescriptor(kind: .limiter)])
        let dry = Track(name: "Dry", kind: .audio)
        let engine = AudioEngine()
        engine.tracksDidChange([limited, dry])

        // m19-j: the LIVE graph rate follows the hardware default output
        // device (a Bluetooth headset in mic mode really runs at 24 kHz), so
        // the limiter's 5 ms lookahead is DERIVED from the engine's actual
        // rate — 240 was only ever the 48 kHz value. Same formula as
        // LimiterEffect.prepare.
        let rate = engine.graph.graphSampleRateForTesting
        let lookahead = Int((LimiterParams.lookaheadSeconds * rate).rounded())
        #expect(lookahead > 0)  // a degenerate device rate must fail loudly, never vacuously

        let before = try #require(engine.pdcReport())
        #expect(before.trackStageSamples == lookahead)
        #expect(before.masterChainLatencySamples == 0)
        #expect(before.outputLatencySamples == before.maxPathLatencySamples)
        let compBefore = before.strips.mapValues(\.compensationSamples)

        // Master limiter lands (the live fx.add path): REPORT moves, rings
        // don't.
        let masterLimiter = EffectDescriptor(kind: .limiter)
        engine.masterEffectsChanged([masterLimiter])
        let with = try #require(engine.pdcReport())
        print("[measured] C7: outputLatency \(before.outputLatencySamples) → "
              + "\(with.outputLatencySamples) (masterChain \(with.masterChainLatencySamples)); "
              + "per-strip comp unchanged "
              + "\(with.strips.mapValues(\.compensationSamples) == compBefore)")
        #expect(with.masterChainLatencySamples == lookahead)
        #expect(with.outputLatencySamples == with.maxPathLatencySamples + lookahead)
        #expect(with.trackStageSamples == before.trackStageSamples)
        #expect(with.busStageSamples == before.busStageSamples)
        // The common-path proof: every strip's ring target is byte-equal.
        #expect(with.strips.mapValues(\.compensationSamples) == compBefore)

        // ACTIVE-sum rule: bypassing the master limiter drops the figure
        // back to maxPath (no ring absorbs it — the honest delay).
        var bypassed = masterLimiter
        bypassed.isBypassed = true
        engine.masterEffectsChanged([bypassed])
        let after = try #require(engine.pdcReport())
        #expect(after.masterChainLatencySamples == 0)
        #expect(after.outputLatencySamples == after.maxPathLatencySamples)
        #expect(after.strips.mapValues(\.compensationSamples) == compBefore)
        engine.shutdown()
    }
}
