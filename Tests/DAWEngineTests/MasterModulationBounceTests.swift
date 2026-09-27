import AVFAudio
import CryptoKit
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m39-e-2 — MASTER-strip modulation must reach every render that carries the
/// master strip, and no other.
///
/// THE DEFECT (measured 2026-09-19, re-confirmed 2026-09-27): an LFO or macro on
/// the MASTER strip moved while the user played and was GONE from every export.
/// `OfflineRenderer` builds its own `PlaybackGraph` and was never handed the
/// master sources/routes, while `AudioEngine.masterModulationChanged` claimed the
/// live and offline passes "agree by construction". TRACK modulation was never
/// affected: it rides inside `Track`, which the renderer always received.
///
/// THE RENDER-CLASS RULE these gates pin. Master modulation is master
/// PERFORMANCE, so it rides the `masterAutomation` class split exactly:
///  · MASTERED renders carry it: `render.mixdown`, `render.bounce`,
///    `render.measureLoudness`, and the stems' "00 Mastered Mix" sibling.
///  · STEM renders never do: every stem, the "00 Mixdown" reference, and
///    `track.bounceInPlace`. A master tremolo baked into a bounced clip would
///    apply TWICE when that clip plays back through the live master LFO (the
///    S-3′ reason the master lane is excluded, verbatim).
///
/// Every gate goes through the REAL store → `AudioEngine` → `OfflineRenderer`
/// chain, because only a real render reaches roll start (the m39-e trap: 24
/// tests passed against a stage while the publication was broken). Every
/// physics assertion is against the closed form the render thread evaluates
/// (`ModulationMath` + `ModulationDepthLaw`), never "the bytes differ".
///
/// Nonisolated suite: the `MainActorOccupancySiteTests` Leg C cap is full, so
/// only the tests that touch the store and engine hop to the main actor.
@Suite("Master modulation reaches the bounce (m39-e-2)", .serialized)
struct MasterModulationBounceTests {
    static let sampleRate = 48_000.0
    static let seconds = 1.0
    static var frames: Int { Int(sampleRate * seconds) }

    /// The master LFO every physics gate uses: a UNIPOLAR sine at 3 Hz under
    /// depth −0.5 (§7.3's attenuation-only idiom; a bipolar source would clip
    /// at the +6.02 dB ceiling), so the master gain sweeps 0 dB … −24 dB three
    /// times a second.
    static let lfoRateHz = 3.0
    static let masterDepth = -0.5

    /// The master gain at project sample `n`, computed with the SAME operations
    /// the render thread performs — `ModulationSnapshotBuilder.resolve` (rate and
    /// phase offset), `ModulationEvaluator.value`/`sum` (phase from position, the
    /// unipolar map, a sum that starts at 0.0) and `ModulationStage.applyVolume`
    /// (a constant base of 1.0 → `volumeGain`) — so a correct render matches it
    /// bit for bit.
    static func expectedMasterGain(atSample n: Int) -> Double {
        let cyclesPerSample = lfoRateHz / sampleRate
        let phaseOffset = (0.0 / 360).truncatingRemainder(dividingBy: 1)
        let raw = Double(n) * cyclesPerSample + phaseOffset
        let phase = ModulationMath.phase(atSample: Int64(n), cyclesPerSample: cyclesPerSample,
                                         phaseOffset: phaseOffset)
        let value = ModulationMath.lfo(waveformCode: LFOWaveform.sine.code, phase: phase,
                                       pulseWidth: 0.5, edgeFraction: 0, seed: 0,
                                       cycleIndex: Int64(floor(raw)))
        var sum = 0.0
        sum += masterDepth * ModulationMath.toUnipolar(value)
        return ModulationDepthLaw.volumeGain(base: 1.0, sum: sum)
    }

    /// How a condition puts modulation on the MASTER strip — always through
    /// the store verbs, so the live engine hears it too (`masterModulationChanged`).
    enum MasterCondition: String, CaseIterable {
        /// No master modulation at all.
        case none
        /// A master LFO with NO route: inert by the m39-e unrouted law.
        case unrouted
        /// That LFO routed to the master fader at depth −0.5.
        case routed
    }

    /// Every file a full export produces, by path, and the render class the
    /// store assigns each one (`ProjectStore+Render.swift`, `+Bounce.swift`).
    static let masteredPaths = ["mixdown", "bounce", "stems.masteredMix"]
    static let stemPaths = ["stems.Drums", "stems.Bass", "stems.referenceMix", "bounceInPlace"]

    // MARK: - Helpers

    private static func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m39e2-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The `MasterAutomationStemsTests` session: a 0.5 cosine panned left and a
    /// 0.25 cosine at 0.7 panned right. `trackModulation` adds a TRACK tremolo
    /// on the first strip, the axis this fix must leave exactly as it was.
    /// `ProjectStore.engine` is weak: callers hold the returned engine.
    @MainActor
    private static func makeSession(trackModulation: Bool) throws -> (ProjectStore, AudioEngine) {
        let fixtures = try TestSignals.fixtures()
        var drums = Track(name: "Drums", kind: .audio, pan: -0.3,
                          clips: [Clip(name: "d", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        let bass = Track(name: "Bass", kind: .audio, volume: 0.7, pan: 0.4,
                         clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        if trackModulation {
            let tremolo = ModulationSource(
                kind: .lfo, name: "Track tremolo",
                params: .lfo(LFOSourceParams(waveform: .triangle, rateHz: 5, bipolar: false)))
            drums.modulationSources = [tremolo]
            drums.modulationRoutes = [ModulationRoute(sourceID: tremolo.id, target: .volume,
                                                      depth: -0.25)]
        }
        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        store.tracks = [drums, bass]
        return (store, engine)
    }

    /// Puts `condition` on the master strip through the production verbs.
    @MainActor
    private static func apply(_ condition: MasterCondition, to store: ProjectStore) throws {
        guard condition != .none else { return }
        let source = try store.addModulationSource(
            on: .master, kind: .lfo,
            params: ["waveform": .string("sine"), "rateHz": .number(lfoRateHz),
                     "bipolar": .bool(false)]).source
        guard condition == .routed else { return }
        try store.addModulationRoute(on: .master, sourceID: source.id, target: .volume,
                                     depth: masterDepth)
    }

    @MainActor
    private static func read(_ path: String) throws -> [[Float]] {
        try TestSignals.readFile(URL(fileURLWithPath: path))
    }

    /// One full export of a fresh session under `condition`: the raw mixdown,
    /// the deliverable bounce, the stem set with BOTH reference mixes, and a
    /// bounce-in-place — every render entry the store has, decoded to samples.
    @MainActor
    private static func renderEverything(trackModulation: Bool, condition: MasterCondition,
                                         in dir: URL) async throws -> [String: [[Float]]] {
        let (store, engine) = try makeSession(trackModulation: trackModulation)
        defer { withExtendedLifetime(engine) {} }
        try apply(condition, to: store)
        let tag = "\(trackModulation ? "trackMod" : "plain")-\(condition.rawValue)"
        var out: [String: [[Float]]] = [:]
        let mix = try await store.renderMixdown(
            toPath: dir.appendingPathComponent("\(tag)-mixdown.wav").path,
            durationSeconds: seconds)
        out["mixdown"] = try read(mix.path)
        let bounce = try await store.renderBounce(
            toPath: dir.appendingPathComponent("\(tag)-bounce.wav").path,
            durationSeconds: seconds)
        out["bounce"] = try read(bounce.path)
        let stems = try await store.renderStems(
            toDirectory: dir.appendingPathComponent("\(tag)-stems").path,
            durationSeconds: seconds, includeMixdown: true, includeMasteredMixdown: true)
        for stem in stems.stems {
            out["stems.\(stem.name)"] = try read(stem.path)
        }
        out["stems.referenceMix"] = try read(try #require(stems.mixdown).path)
        out["stems.masteredMix"] = try read(try #require(stems.masteredMixdown).path)
        // LAST: bounce-in-place edits the project (a new track after the source).
        let landed = try await store.bounceTrackInPlace(
            trackId: store.tracks[0].id, durationSeconds: seconds, muteSource: false)
        out["bounceInPlace"] = try read(landed.file)
        return out
    }

    /// Sample positions whose BIT PATTERNS differ (channels and frames compared
    /// up to the shorter; a length mismatch is reported separately).
    static func bitDiffCount(_ a: [[Float]], _ b: [[Float]]) -> Int {
        var diffs = 0
        for channel in 0..<min(a.count, b.count) {
            for frame in 0..<min(a[channel].count, b[channel].count)
            where a[channel][frame].bitPattern != b[channel][frame].bitPattern {
                diffs += 1
            }
        }
        return diffs
    }

    /// `modulated` against `plain × Float(G(n))`, the exact operation the stage
    /// performs (`data[frame] *= Float(gain)`): mismatching bit patterns and the
    /// largest absolute error.
    static func analyticResidual(modulated: [[Float]], plain: [[Float]],
                                 gain: (Int) -> Double) -> (mismatches: Int, maxError: Float) {
        var mismatches = 0
        var maxError: Float = 0
        for channel in 0..<min(modulated.count, plain.count) {
            for frame in 0..<min(modulated[channel].count, plain[channel].count) {
                let expected = plain[channel][frame] * Float(gain(frame))
                let actual = modulated[channel][frame]
                if actual.bitPattern != expected.bitPattern { mismatches += 1 }
                maxError = max(maxError, abs(actual - expected))
            }
        }
        return (mismatches, maxError)
    }

    static func peak(_ channels: [[Float]]) -> Float {
        channels.flatMap { $0 }.map(abs).max() ?? 0
    }

    /// SHA-256 over every channel's raw Float32 bytes, prefixed by the shape —
    /// the before/after invariance fingerprint.
    static func digest(_ channels: [[Float]]) -> String {
        var hasher = SHA256()
        for channel in channels {
            channel.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(channels.count)x\(channels.first?.count ?? 0) \(hex)"
    }

    /// RMS per `window`-sample block of one channel (whole blocks only).
    static func windowRMS(_ samples: [Float], window: Int) -> [Double] {
        var out: [Double] = []
        var start = 0
        while start + window <= samples.count {
            var sum = 0.0
            for index in start..<(start + window) {
                sum += Double(samples[index]) * Double(samples[index])
            }
            out.append((sum / Double(window)).squareRoot())
            start += window
        }
        return out
    }

    // MARK: - The matrix: every render entry × master condition × track modulation

    /// ⭐ THE GATE. For each of the seven files a full export writes, with a
    /// track tremolo absent and present:
    ///  1. an UNROUTED master source changes nothing (bit-identical to none);
    ///  2. a ROUTED master LFO leaves every STEM-class file bit-identical;
    ///  3. a ROUTED master LFO makes every MASTERED file equal the unmodulated
    ///     render × the closed-form gain, sample for sample.
    /// Leg 3 is the one the pre-fix tree fails (the offline graph never got the
    /// routes, so "modulated" came back equal to "plain").
    ///
    /// With `DAWPRO_ME2_DIGEST_DIR` set, it also writes a SHA-256 of every file
    /// to `<dir>/digests.txt`: run it on two trees and diff the files for the
    /// before/after invariance proof (only the six MASTERED routed files may
    /// differ).
    @Test("matrix: MASTERED renders follow the master LFO sample for sample; STEM renders and unrouted sources stay bit-identical")
    @MainActor
    func renderClassMatrix() async throws {
        let dir = try Self.makeTempDir("matrix")
        defer { try? FileManager.default.removeItem(at: dir) }
        var digestLines: [String] = []
        var unmodulatedByTrackState: [Bool: [String: [[Float]]]] = [:]
        for trackModulation in [false, true] {
            var byCondition: [MasterCondition: [String: [[Float]]]] = [:]
            for condition in MasterCondition.allCases {
                byCondition[condition] = try await Self.renderEverything(
                    trackModulation: trackModulation, condition: condition, in: dir)
            }
            let none = try #require(byCondition[.none])
            let unrouted = try #require(byCondition[.unrouted])
            let routed = try #require(byCondition[.routed])
            let state = trackModulation ? "track tremolo ON" : "track tremolo OFF"

            // The path set is exactly the census — a renamed stem would make
            // every later lookup vacuous.
            let expectedPaths = Set(Self.masteredPaths + Self.stemPaths)
            #expect(Set(none.keys) == expectedPaths, "paths rendered: \(none.keys.sorted())")
            #expect(Set(routed.keys) == expectedPaths)

            for path in (Self.masteredPaths + Self.stemPaths).sorted() {
                let reference = try #require(none[path])
                let inert = try #require(unrouted[path])
                let modulated = try #require(routed[path])
                // POSITIVE CONTROL: real audio of the full window, so a
                // bit-identity below cannot be two agreeing silences.
                #expect(Self.peak(reference) > 0.05, "\(state) \(path): peak \(Self.peak(reference))")
                #expect(reference.first?.count == Self.frames, "\(state) \(path): frames")
                #expect(modulated.first?.count == Self.frames, "\(state) \(path): frames")

                // 1. An unrouted master source is inert everywhere.
                let unroutedDiffs = Self.bitDiffCount(inert, reference)
                #expect(unroutedDiffs == 0, "\(state) \(path): unrouted source moved \(unroutedDiffs) samples")

                if Self.stemPaths.contains(path) {
                    // 2. STEM class: master performance is never baked in.
                    let stemDiffs = Self.bitDiffCount(modulated, reference)
                    print("[measured] m39-e-2 \(state) \(path) (STEM): routed master LFO moved "
                          + "\(stemDiffs) samples (must be 0)")
                    #expect(stemDiffs == 0, "\(state) \(path): a STEM render carried master modulation")
                } else {
                    // 3. MASTERED class: the file follows the LFO exactly.
                    let residual = Self.analyticResidual(modulated: modulated, plain: reference,
                                                         gain: Self.expectedMasterGain(atSample:))
                    let moved = Self.bitDiffCount(modulated, reference)
                    print("[measured] m39-e-2 \(state) \(path) (MASTERED): \(moved) samples moved "
                          + "by the master LFO; vs plain×G(n): \(residual.mismatches) mismatching "
                          + "bit patterns, max |error| \(residual.maxError)")
                    #expect(moved > Self.frames, "\(state) \(path): the master LFO never reached this render")
                    #expect(residual.maxError <= 1e-6, "\(state) \(path): off the closed form by \(residual.maxError)")
                    #expect(residual.mismatches == 0, "\(state) \(path): \(residual.mismatches) samples off the closed form")
                }
            }
            unmodulatedByTrackState[trackModulation] = none
            digestLines.append(trackModulation ? "# track tremolo ON" : "# track tremolo OFF")
            for condition in MasterCondition.allCases {
                let files = try #require(byCondition[condition])
                for path in files.keys.sorted() {
                    digestLines.append("\(trackModulation ? "trackMod" : "plain")|\(condition.rawValue)|\(path) "
                                       + Self.digest(try #require(files[path])))
                }
            }
        }
        // The track axis is REAL: the tremolo on Drums moves the Drums stem and
        // leaves the Bass stem alone — so the "tremolo ON" half of the matrix is
        // not a copy of the "OFF" half, and track modulation is still carried.
        let off = try #require(unmodulatedByTrackState[false])
        let on = try #require(unmodulatedByTrackState[true])
        let tremoloDiffs = Self.bitDiffCount(try #require(on["stems.Drums"]),
                                             try #require(off["stems.Drums"]))
        let bassDiffs = Self.bitDiffCount(try #require(on["stems.Bass"]),
                                          try #require(off["stems.Bass"]))
        print("[measured] m39-e-2 track tremolo: Drums stem moved \(tremoloDiffs) samples, "
              + "Bass stem \(bassDiffs)")
        #expect(tremoloDiffs > Self.frames, "the track tremolo must reach the Drums stem")
        #expect(bassDiffs == 0, "a Drums-only tremolo must not touch the Bass stem")
        if let out = ProcessInfo.processInfo.environment["DAWPRO_ME2_DIGEST_DIR"], !out.isEmpty {
            let outDir = URL(fileURLWithPath: out, isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try (digestLines.joined(separator: "\n") + "\n")
                .write(to: outDir.appendingPathComponent("digests.txt"), atomically: true, encoding: .utf8)
            print("[measured] m39-e-2 wrote \(digestLines.count) digest lines to \(outDir.path)")
        }
    }

    // MARK: - The level in the file follows the LFO

    /// The headline, measured the way a listener would hear it: the level of a
    /// REAL bounce file rises and falls with the master LFO. Both tracks are
    /// steady 1 kHz tones, so the unmodulated bounce is flat (the control) and
    /// every level change in the modulated one is the master LFO's doing. The
    /// 10 ms windows hold exactly ten cycles of the tone, so a window's RMS is
    /// the tone's level with no ripple of its own.
    @Test("a real bounce's level follows a master volume LFO: 24 dB deep, three times a second")
    @MainActor
    func bounceLevelFollowsTheMasterLFO() async throws {
        let dir = try Self.makeTempDir("level")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (plainStore, plainEngine) = try Self.makeSession(trackModulation: false)
        defer { withExtendedLifetime(plainEngine) {} }
        let plainBounce = try await plainStore.renderBounce(
            toPath: dir.appendingPathComponent("plain.wav").path, durationSeconds: Self.seconds)
        let (lfoStore, lfoEngine) = try Self.makeSession(trackModulation: false)
        defer { withExtendedLifetime(lfoEngine) {} }
        try Self.apply(.routed, to: lfoStore)
        let lfoBounce = try await lfoStore.renderBounce(
            toPath: dir.appendingPathComponent("lfo.wav").path, durationSeconds: Self.seconds)

        let plain = try Self.read(plainBounce.path)[0]
        let modulated = try Self.read(lfoBounce.path)[0]
        let window = 480
        let plainLevels = Self.windowRMS(plain, window: window)
        let lfoLevels = Self.windowRMS(modulated, window: window)
        #expect(plainLevels.count == Self.frames / window)
        #expect(lfoLevels.count == plainLevels.count)

        func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }
        // CONTROL: the unmodulated bounce is flat, and loud enough to measure.
        let plainSpread = db(plainLevels.max() ?? 0) - db(plainLevels.min() ?? 0)
        #expect(plainSpread < 0.01, "the unmodulated bounce must be flat, spread \(plainSpread) dB")
        #expect((plainLevels.min() ?? 0) > 0.05)

        // The modulation depth, read from the modulated FILE ALONE.
        let depth = db(lfoLevels.max() ?? 0) - db(lfoLevels.min() ?? 0)
        // Its shape, window by window, against the closed form: the level a
        // window must have is the tone's level × the RMS of G over that window.
        var worstDeviation = 0.0
        var predictedLevelsDb: [Double] = []
        for index in 0..<lfoLevels.count {
            var meanSquare = 0.0
            for n in (index * window)..<((index + 1) * window) {
                let gain = Self.expectedMasterGain(atSample: n)
                meanSquare += gain * gain
            }
            let predictedDb = 10 * log10(meanSquare / Double(window))
            predictedLevelsDb.append(predictedDb)
            let measuredDb = db(lfoLevels[index]) - db(plainLevels[index])
            worstDeviation = max(worstDeviation, abs(measuredDb - predictedDb))
        }
        let predictedDepth = (predictedLevelsDb.max() ?? 0) - (predictedLevelsDb.min() ?? 0)
        // Its rate: the quietest window of each LFO cycle sits at the sine's
        // peak, (0.25 + k) / 3 s, i.e. 83, 417 and 750 ms.
        var troughsMs: [Double] = []
        let cycleWindows = Int((Self.sampleRate / Self.lfoRateHz) / Double(window))
        var start = 0
        while start + cycleWindows <= lfoLevels.count {
            let slice = lfoLevels[start..<(start + cycleWindows)]
            if let quietest = slice.indices.min(by: { lfoLevels[$0] < lfoLevels[$1] }) {
                troughsMs.append((Double(quietest) + 0.5) * Double(window) / Self.sampleRate * 1000)
            }
            start += cycleWindows
        }
        print("[measured] m39-e-2 bounce level: depth \(depth) dB (closed form \(predictedDepth) dB), "
              + "worst window vs closed form \(worstDeviation) dB, troughs at \(troughsMs) ms, "
              + "unmodulated spread \(plainSpread) dB, true peak "
              + "\(lfoBounce.report.output.truePeakDbtp ?? .nan) dBTP (plain "
              + "\(plainBounce.report.output.truePeakDbtp ?? .nan))")
        #expect(predictedDepth > 23.5, "fixture sanity: the closed form sweeps ~24 dB")
        #expect(abs(depth - predictedDepth) < 0.1, "measured depth \(depth) dB vs \(predictedDepth) dB")
        #expect(worstDeviation < 0.1, "the level strays \(worstDeviation) dB from the LFO")
        #expect(troughsMs.count == 3)
        for (index, trough) in troughsMs.enumerated() {
            let expected = (0.25 + Double(index)) / Self.lfoRateHz * 1000
            #expect(abs(trough - expected) < 10, "trough \(index) at \(trough) ms, expected \(expected)")
        }
        // Nothing here clips: attenuation-only modulation of a −6 dBFS mix.
        let truePeak = try #require(lfoBounce.report.output.truePeakDbtp)
        #expect(truePeak < -1, "true peak \(truePeak) dBTP")
    }

    // MARK: - render.measureLoudness measures the program the user hears

    /// `render.measureLoudness` is MASTERED: it measures the program, and a
    /// master tremolo is part of the program. Predicted by measuring the
    /// unmodulated bounce × the closed-form gain with the SAME meter.
    @Test("render.measureLoudness measures the master LFO: equals the meter run on plain × G(n)")
    @MainActor
    func measureLoudnessCarriesTheMasterLFO() async throws {
        let dir = try Self.makeTempDir("loudness")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (plainStore, plainEngine) = try Self.makeSession(trackModulation: false)
        defer { withExtendedLifetime(plainEngine) {} }
        let plainMeasure = try await plainStore.measureLoudness(durationSeconds: Self.seconds)
        let plainBounce = try await plainStore.renderBounce(
            toPath: dir.appendingPathComponent("plain.wav").path, durationSeconds: Self.seconds)

        let (lfoStore, lfoEngine) = try Self.makeSession(trackModulation: false)
        defer { withExtendedLifetime(lfoEngine) {} }
        try Self.apply(.routed, to: lfoStore)
        let lfoMeasure = try await lfoStore.measureLoudness(durationSeconds: Self.seconds)

        var predictedChannels = try Self.read(plainBounce.path)
        for channel in predictedChannels.indices {
            for frame in predictedChannels[channel].indices {
                predictedChannels[channel][frame] *= Float(Self.expectedMasterGain(atSample: frame))
            }
        }
        let predicted = Loudness.measure(RenderedAudio(sampleRate: Self.sampleRate,
                                                       channelData: predictedChannels))
        let plainLufs = try #require(plainMeasure.measurement.integratedLufs)
        let lfoLufs = try #require(lfoMeasure.measurement.integratedLufs)
        let predictedLufs = try #require(predicted.integratedLufs)
        print("[measured] m39-e-2 measureLoudness: plain \(plainLufs) LUFS, master LFO \(lfoLufs) "
              + "LUFS (closed form \(predictedLufs)), drop \(plainLufs - lfoLufs) LU")
        #expect(abs(lfoLufs - predictedLufs) < 0.001)
        #expect(plainLufs - lfoLufs > 3, "the tremolo removes several LU of program")
    }

    // MARK: - Live and offline apply the same master modulation

    /// "The pass runs the same way live and offline" — made TRUE by this fix and
    /// checked here where it can be checked headless. A MACRO is the probe: it
    /// is position-free, so the LIVE graph evaluates it while stopped (§7.8),
    /// whereas an LFO holds neutral there and a rolling live transport needs a
    /// device. The macro goes on through the store, which pushes it to the live
    /// graph (`masterModulationChanged`); the gain the live master stage then
    /// applies must be exactly the gain the bounce carries.
    @Test("live and offline apply the same master macro gain: bounce == plain × the live stage's gain, bit for bit")
    @MainActor
    func liveAndOfflineApplyTheSameMasterMacro() async throws {
        let dir = try Self.makeTempDir("parity")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, engine) = try Self.makeSession(trackModulation: false)
        defer { withExtendedLifetime(engine) {} }
        // The live graph needs its strips (and so its master chain host).
        engine.tracksDidChange(store.tracks)
        let plainBounce = try await store.renderBounce(
            toPath: dir.appendingPathComponent("plain.wav").path, durationSeconds: Self.seconds)

        // 0.625 is exact in Float, so the macro bank stores it losslessly.
        let macroValue = 0.625
        let macro = try store.addModulationSource(
            on: .master, kind: .macro, params: ["value": .number(macroValue)]).source
        try store.addModulationRoute(on: .master, sourceID: macro.id, target: .volume,
                                     depth: Self.masterDepth)

        // LIVE: what the live master stage does to a unity signal right now.
        let renderer = try #require(engine.graph.masterAutomationRendererForTesting())
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate,
                                                channels: 2))
        let unity = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        unity.frameLength = 512
        let data = try #require(unity.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<512 { data[channel][frame] = 1 }
        }
        var stamp = AudioTimeStamp()
        stamp.mSampleTime = 0
        stamp.mFlags = .sampleTimeValid
        renderer.apply(bufferList: unity.mutableAudioBufferList, frameCount: 512, timestamp: &stamp)
        let liveGain = data[0][0]
        let closedForm = Float(ModulationDepthLaw.volumeGain(base: 1, sum: Self.masterDepth * macroValue))
        #expect(liveGain == closedForm, "live stage gain \(liveGain) vs closed form \(closedForm)")
        #expect(data[1][511] == liveGain, "the live stage gain is constant across the buffer")

        // OFFLINE: the bounce of the same project.
        let macroBounce = try await store.renderBounce(
            toPath: dir.appendingPathComponent("macro.wav").path, durationSeconds: Self.seconds)
        let plain = try Self.read(plainBounce.path)
        let bounced = try Self.read(macroBounce.path)
        let residual = Self.analyticResidual(modulated: bounced, plain: plain) { _ in Double(liveGain) }
        print("[measured] m39-e-2 live/offline macro parity: live stage gain \(liveGain) "
              + "(\(20 * log10(Double(liveGain))) dB; closed form \(closedForm)); bounce vs "
              + "plain×live gain: \(residual.mismatches) mismatching bit patterns, max |error| "
              + "\(residual.maxError), plain peak \(Self.peak(plain)), bounce peak \(Self.peak(bounced))")
        #expect(liveGain < 0.25, "the probe must actually cut (−15 dB), or parity proves nothing")
        #expect(Self.peak(plain) > 0.1)
        #expect(residual.mismatches == 0)
        #expect(residual.maxError <= 1e-6)
    }
}
