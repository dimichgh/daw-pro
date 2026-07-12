import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// M5 iv-c stem export against the real offline engine (spec §1, §7). The
/// normative invariant: **Σ stems ≡ the mixdown, null residual peak ≤ 1e-4**
/// — proven on a flat project, a bus-FX project (send tail lives in the BUS
/// stem, source stem is dry), and a PDC project (limiter lookahead), where the
/// null holds ONLY because every pass is forced under the full-session
/// compensation plan. The subset-auto-plan negative control shows the residual
/// without that machinery — large — so the forced-plan mechanism is proven,
/// not assumed.
@MainActor
@Suite("Stem export — Σ stems ≡ mixdown null (M5 iv-c)", .serialized)
struct StemNullTests {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-stems-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(tracks: [Track], engine: AudioEngine) -> ProjectStore {
        let store = ProjectStore()
        store.engine = engine
        store.tracks = tracks
        return store
    }

    /// Per-channel sample sum of a set of equal-shape WAVs.
    private func sumFiles(_ paths: [String]) throws -> [[Float]] {
        var sum: [[Float]] = []
        for path in paths {
            let channels = try TestSignals.readFile(URL(fileURLWithPath: path))
            if sum.isEmpty {
                sum = channels
            } else {
                #expect(channels.count == sum.count)
                for channel in 0..<min(channels.count, sum.count) {
                    #expect(channels[channel].count == sum[channel].count)
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

    // MARK: - Flat project

    @Test("Flat project: Σ stems nulls against the mixdown; files share one shape")
    func flatProjectNull() async throws {
        let fixtures = try TestSignals.fixtures()
        // Distinct levels + pans so the sum is a real superposition, not two
        // identical signals agreeing by luck.
        let drums = Track(name: "Drums", kind: .audio, pan: -0.3,
                          clips: [Clip(name: "d", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        let bass = Track(name: "Bass", kind: .audio, volume: 0.7, pan: 0.4,
                         clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        let store = makeStore(tracks: [drums, bass], engine: engine)
        let dir = try makeTempDir("flat")

        let result = try await store.renderStems(
            toDirectory: dir.path, durationSeconds: 1.0, includeMixdown: true)

        #expect(result.directory == dir.path)
        #expect(result.sampleRate == 48_000)
        #expect(result.channels == 2)
        #expect(abs(result.durationSeconds - 1.0) < 0.001)
        #expect(result.stems.map(\.name) == ["Drums", "Bass"])
        #expect(result.stems.map(\.kind) == [.track, .track])
        #expect(result.stems[0].path.hasSuffix("01 Drums.wav"))
        #expect(result.stems[1].path.hasSuffix("02 Bass.wav"))

        // Stems are measured (never normalized): both carry real loudness.
        for stem in result.stems {
            #expect(stem.measurement.integratedLufs != nil)
            #expect(stem.measurement.truePeakDbtp != nil)
        }

        // Every file the same shape — summation requires it.
        let stemBuffers = try result.stems.map {
            try TestSignals.readFile(URL(fileURLWithPath: $0.path))
        }
        for buffers in stemBuffers {
            #expect(buffers.count == 2)
            #expect(buffers[0].count == 48_000)
        }

        // THE invariant: Σ stems ≡ mixdown, ≤ 1e-4 residual peak.
        let mixdownPath = try #require(result.mixdown).path
        #expect(mixdownPath.hasSuffix("00 Mixdown.wav"))
        let mixdown = try TestSignals.readFile(URL(fileURLWithPath: mixdownPath))
        let sum = try sumFiles(result.stems.map(\.path))
        let residual = residualPeak(sum, mixdown)
        print("[measured] flat-project stems null residual peak: \(residual)")
        #expect(residual <= 1e-4)
        // Real audio, not agreeing silences.
        #expect(TestSignals.rms(mixdown[0], in: 0..<24_000) > 0.1)

        // "00 Mixdown.wav" is the frozen raw bounce, bit-close: same graph,
        // same auto-plan (forcing the plan's own targets is a parity no-op).
        let rawPath = dir.appendingPathComponent("raw-mixdown.wav")
        _ = try await engine.renderMixdown(
            tracks: store.tracks, tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0, to: rawPath)
        let raw = try TestSignals.readFile(rawPath)
        let mixdownParity = residualPeak(mixdown, raw)
        print("[measured] includeMixdown vs renderMixdown residual peak: \(mixdownParity)")
        #expect(mixdownParity <= 1e-6)
    }

    // MARK: - Bus FX project

    @Test("Bus project: null holds; send tail lives in the BUS stem, source stem is dry")
    func busProjectNullAndDrySourceStem() async throws {
        let fixtures = try TestSignals.fixtures()
        // Bus with an audible delay (250 ms repeats): tails keep sounding long
        // after the half-second source clips stop.
        let bus = Track(name: "Echo Bus", kind: .bus,
                        effects: [EffectDescriptor(
                            kind: .delay,
                            delay: DelayParams(timeMs: 250, feedback: 0.6, mix: 0.5,
                                               pingPong: 0, highCutHz: 12_000))])
        // Routed INTO the bus (no stem of its own)…
        let routed = Track(name: "Routed", kind: .audio,
                           clips: [Clip(name: "r", startBeat: 0, lengthBeats: 1,
                                        audioFileURL: fixtures.cos1k48Quarter)],
                           outputBusID: bus.id)
        // …plus a direct track SENDING into it (post-fader fan-out).
        let lead = Track(name: "Lead", kind: .audio,
                         clips: [Clip(name: "l", startBeat: 0, lengthBeats: 1,
                                      audioFileURL: fixtures.cos1k48)],
                         sends: [Send(destinationBusID: bus.id, level: 0.8)])
        let engine = AudioEngine()
        let store = makeStore(tracks: [bus, routed, lead], engine: engine)
        let dir = try makeTempDir("bus")

        let result = try await store.renderStems(
            toDirectory: dir.path, durationSeconds: 2.0, includeMixdown: true)

        // Partition: the bus + the direct track. The routed track has no stem.
        #expect(result.stems.map(\.name) == ["Echo Bus", "Lead"])
        #expect(result.stems.map(\.kind) == [.bus, .track])

        let mixdown = try TestSignals.readFile(
            URL(fileURLWithPath: try #require(result.mixdown).path))
        let sum = try sumFiles(result.stems.map(\.path))
        let residual = residualPeak(sum, mixdown)
        print("[measured] bus-project stems null residual peak: \(residual)")
        #expect(residual <= 1e-4)

        // Clips end at 0.5 s. In the 1.0–1.5 s tail window the LEAD stem is
        // dry silence (its send contribution does NOT fold back in) while the
        // BUS stem still rings with delay repeats — the partition, audibly.
        let tail = 48_000..<72_000
        let busStem = try TestSignals.readFile(
            URL(fileURLWithPath: result.stems[0].path))
        let leadStem = try TestSignals.readFile(
            URL(fileURLWithPath: result.stems[1].path))
        let leadTailRMS = TestSignals.rms(leadStem[0], in: tail)
        let busTailRMS = TestSignals.rms(busStem[0], in: tail)
        print("[measured] tail window RMS — lead (dry) \(leadTailRMS), bus \(busTailRMS)")
        #expect(leadTailRMS < 1e-5)
        #expect(busTailRMS > 1e-3)
        // And the lead stem is loud while its clip plays — dry, not muted.
        #expect(TestSignals.rms(leadStem[0], in: 0..<24_000) > 0.1)
    }

    // MARK: - PDC project + the negative control

    @Test("PDC project: null holds under forced full-session targets; subset auto-plan combs")
    func pdcProjectNullAndNegativeControl() async throws {
        let fixtures = try TestSignals.fixtures()
        // Limiter = 240-sample lookahead @ 48 kHz: the session plan delays the
        // DRY strip by 240 to stay aligned. A solo pass over the dry track
        // would get target 0 — exactly the hazard the forced plan removes.
        let limited = Track(name: "Limited", kind: .audio,
                            clips: [Clip(name: "l", startBeat: 0, lengthBeats: 4,
                                         audioFileURL: fixtures.cos1k48)],
                            effects: [EffectDescriptor(kind: .limiter)])
        let dry = Track(name: "Dry", kind: .audio,
                        clips: [Clip(name: "d", startBeat: 0, lengthBeats: 4,
                                     audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        let store = makeStore(tracks: [limited, dry], engine: engine)
        let dir = try makeTempDir("pdc")

        // Context: the full-session plan really does delay the dry strip.
        let sessionTargets = await engine.offlineCompensationTargets(
            tracks: store.tracks)
        #expect(sessionTargets[limited.id] == 0)
        #expect(sessionTargets[dry.id] == 240)

        let result = try await store.renderStems(
            toDirectory: dir.path, durationSeconds: 1.0, includeMixdown: true)
        let mixdown = try TestSignals.readFile(
            URL(fileURLWithPath: try #require(result.mixdown).path))
        let sum = try sumFiles(result.stems.map(\.path))
        let forcedResidual = residualPeak(sum, mixdown)
        print("[measured] PDC-project stems null residual peak (forced plan): \(forcedResidual)")
        #expect(forcedResidual <= 1e-4)

        // NEGATIVE CONTROL — the same dry-track pass under its own SUBSET
        // auto-plan (forcedCompensationTargets: nil → a lone latency-free
        // strip gets target 0, not the session's 240): the stem lands 240
        // samples early and the sum no longer nulls. This is the documented
        // proof that the forced-plan machinery is load-bearing.
        let dryDescriptor = try #require(
            try StemPlan.descriptors(tracks: store.tracks, including: [dry.id]).first)
        let subsetDry = try await engine.renderOffline(
            tracks: StemPlan.passTracks(for: dryDescriptor, session: store.tracks),
            tempoMap: TempoMap(constantBPM: 120), masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0,
            forcedCompensationTargets: nil)
        let limitedStem = try TestSignals.readFile(
            URL(fileURLWithPath: result.stems[0].path))
        var badSum = limitedStem
        for channel in 0..<min(badSum.count, subsetDry.channelData.count) {
            for frame in 0..<min(badSum[channel].count,
                                 subsetDry.channelData[channel].count) {
                badSum[channel][frame] += subsetDry.channelData[channel][frame]
            }
        }
        let subsetResidual = residualPeak(badSum, mixdown)
        print("[measured] PDC-project residual with SUBSET auto-plan (negative control): \(subsetResidual)")
        #expect(subsetResidual > 0.05)
        // The contrast IS the proof: orders of magnitude apart.
        #expect(subsetResidual > forcedResidual * 100)
    }

    // MARK: - Store-level policy

    @Test("renderStems rejections: bus-routed id verbatim, unknown id, empty selection")
    func storeRejections() async throws {
        let fixtures = try TestSignals.fixtures()
        let bus = Track(name: "Crunch", kind: .bus)
        let gtr = Track(name: "Gtr", kind: .audio,
                        clips: [Clip(name: "g", startBeat: 0, lengthBeats: 4,
                                     audioFileURL: fixtures.cos1k48)],
                        outputBusID: bus.id)
        let engine = AudioEngine()
        let store = makeStore(tracks: [bus, gtr], engine: engine)

        do {
            _ = try await store.renderStems(trackIds: [gtr.id])
            Issue.record("expected stemNotMasterInput")
        } catch let error as ProjectError {
            #expect(error.errorDescription ==
                "'Gtr' is routed to bus 'Crunch' — its signal is part of that bus's stem")
        }

        let stray = UUID()
        do {
            _ = try await store.renderStems(trackIds: [stray])
            Issue.record("expected trackNotFound")
        } catch let ProjectError.trackNotFound(id) {
            #expect(id == stray)
        }

        do {
            _ = try await store.renderStems(trackIds: [])
            Issue.record("expected nothingToRender")
        } catch let error as ProjectError {
            guard case .nothingToRender = error else {
                Issue.record("unexpected ProjectError: \(error)")
                return
            }
        }
    }

    @Test("Duplicate track names land as collision-suffixed files on disk")
    func collisionFileNamesOnDisk() async throws {
        let fixtures = try TestSignals.fixtures()
        let a = Track(name: "Gtr", kind: .audio,
                      clips: [Clip(name: "a", startBeat: 0, lengthBeats: 1,
                                   audioFileURL: fixtures.cos1k48)])
        let b = Track(name: "Gtr", kind: .audio,
                      clips: [Clip(name: "b", startBeat: 0, lengthBeats: 1,
                                   audioFileURL: fixtures.cos1k48Quarter)])
        let engine = AudioEngine()
        let store = makeStore(tracks: [a, b], engine: engine)
        let dir = try makeTempDir("collide")

        let result = try await store.renderStems(
            toDirectory: dir.path, durationSeconds: 0.25)

        #expect(result.mixdown == nil)  // includeMixdown defaults false.
        #expect(result.stems[0].path.hasSuffix("01 Gtr.wav"))
        #expect(result.stems[1].path.hasSuffix("02 Gtr 2.wav"))
        for stem in result.stems {
            #expect(FileManager.default.fileExists(atPath: stem.path))
        }
    }
}
