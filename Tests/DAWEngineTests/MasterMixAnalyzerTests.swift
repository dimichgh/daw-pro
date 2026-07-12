import Foundation
import Testing
import DAWCore
@testable import DAWEngine

/// Headless DSP-core tests for the master-mix analyzer (M8 vm-a): synthesized
/// buffers in, snapshot assertions out — no audio I/O, no engine, no taps.
@Suite("Master-mix analyzer — vibe meter DSP core")
struct MasterMixAnalyzerTests {

    private static let sampleRate = 48_000.0

    /// `seconds` of a sine at `frequency`/`amplitude`, mono Float32.
    private static func sine(
        frequency: Double, amplitude: Float, seconds: Double
    ) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { frame in
            amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
    }

    // MARK: - Band geometry

    @Test("band edges: 25 geometric edges 40 Hz → 16 kHz, monotonic")
    func bandEdges() {
        let edges = MasterMixAnalyzer.bandEdges
        #expect(edges.count == MasterAnalysisSnapshot.bandCount + 1)
        #expect(abs(edges.first! - 40) < 1e-9)
        #expect(abs(edges.last! - 16_000) < 1e-6)
        for k in 1..<edges.count {
            #expect(edges[k] > edges[k - 1])
        }
        // The ratio between adjacent edges is constant (geometric spacing).
        let ratio = edges[1] / edges[0]
        for k in 1..<edges.count {
            #expect(abs(edges[k] / edges[k - 1] - ratio) < 1e-9)
        }
    }

    @Test("bandIndex(containing:) maps edges and interior points correctly")
    func bandIndexMapping() {
        #expect(MasterMixAnalyzer.bandIndex(containing: 39) == 0)
        #expect(MasterMixAnalyzer.bandIndex(containing: 41) == 0)
        #expect(MasterMixAnalyzer.bandIndex(containing: 1_000) == 12)
        #expect(MasterMixAnalyzer.bandIndex(containing: 15_999) == 23)
        #expect(MasterMixAnalyzer.bandIndex(containing: 20_000) == 23)
        // Every band's geometric center maps back to that band.
        let edges = MasterMixAnalyzer.bandEdges
        for band in 0..<MasterAnalysisSnapshot.bandCount {
            let center = (edges[band] * edges[band + 1]).squareRoot()
            #expect(MasterMixAnalyzer.bandIndex(containing: center) == band)
        }
    }

    // MARK: - Known-signal assertions

    @Test("1 kHz sine: centroid ±15%, band peak in the 1 kHz band, RMS ±1.5 dB")
    func sineOneKilohertz() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        analyzer.process(Self.sine(frequency: 1_000, amplitude: 0.5, seconds: 1.0))
        let snapshot = analyzer.snapshot()

        // Centroid within ±15% of the tone.
        #expect(snapshot.centroidHz > 850 && snapshot.centroidHz < 1_150,
                "centroid \(snapshot.centroidHz) Hz")

        // Band energy peaks in the band containing 1 kHz.
        let expectedBand = MasterMixAnalyzer.bandIndex(containing: 1_000)
        let loudestBand = snapshot.bands.indices.max { snapshot.bands[$0] < snapshot.bands[$1] }
        #expect(loudestBand == expectedBand,
                "loudest band \(String(describing: loudestBand)), expected \(expectedBand)")

        // Short-term level within ±1.5 dB of the analytic sine RMS
        // (A/√2 → 20·log10(0.5/√2) ≈ −9.03 dB).
        let analyticRMSdB = 20 * log10(0.5 / 2.0.squareRoot())
        #expect(abs(Double(snapshot.levelDB) - analyticRMSdB) < 1.5,
                "levelDB \(snapshot.levelDB), analytic \(analyticRMSdB)")

        // Peak within ±1 dB of the sine amplitude (−6.02 dB).
        #expect(abs(snapshot.peakDB - 20 * log10(Float(0.5))) < 1.0)

        // Steady-state: flux has decayed away from the initial onset.
        #expect(snapshot.flux < 0.1)

        // Everything on the wire is finite.
        for value in snapshot.bands { #expect(value.isFinite) }
        #expect(snapshot.levelDB.isFinite && snapshot.peakDB.isFinite
                && snapshot.centroidHz.isFinite && snapshot.flux.isFinite)
    }

    @Test("silence: every field sits exactly on the floor, flux 0, all finite")
    func silenceFloors() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        analyzer.process([Float](repeating: 0, count: 24_000))  // 0.5 s
        let snapshot = analyzer.snapshot()
        #expect(snapshot == .floor)
        for value in snapshot.bands {
            #expect(value == MasterAnalysisSnapshot.floorDB)
        }
        #expect(snapshot.levelDB == MasterAnalysisSnapshot.floorDB)
        #expect(snapshot.peakDB == MasterAnalysisSnapshot.floorDB)
        #expect(snapshot.centroidHz == 0)
        #expect(snapshot.flux == 0)
    }

    @Test("a fresh analyzer (no input at all) reads the floor snapshot")
    func freshIsFloor() {
        #expect(MasterMixAnalyzer(sampleRate: Self.sampleRate).snapshot() == .floor)
    }

    @Test("spectral change (500 Hz → 4 kHz) drives flux > 0; brightness follows")
    func fluxOnSpectralChange() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        analyzer.process(Self.sine(frequency: 500, amplitude: 0.5, seconds: 0.5))
        let settled = analyzer.snapshot()
        #expect(settled.flux < 0.1)  // steady tone: no energy movement

        // Two hops of a brand-new tone: energy appears in new bins.
        analyzer.process(Self.sine(frequency: 4_000, amplitude: 0.5, seconds: 0.05))
        let moving = analyzer.snapshot()
        #expect(moving.flux > 0.1, "flux \(moving.flux) after spectral change")
        #expect(moving.flux <= 1.0)

        // After the new tone settles, brightness has moved up toward 4 kHz.
        analyzer.process(Self.sine(frequency: 4_000, amplitude: 0.5, seconds: 1.0))
        let bright = analyzer.snapshot()
        #expect(bright.centroidHz > settled.centroidHz)
        #expect(bright.flux < 0.1)
    }

    @Test("silence after a tone decays every field back to the floors")
    func decayToFloor() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        analyzer.process(Self.sine(frequency: 1_000, amplitude: 0.9, seconds: 0.5))
        #expect(analyzer.snapshot().levelDB > -20)
        analyzer.process([Float](repeating: 0, count: Int(6 * Self.sampleRate)))
        let snapshot = analyzer.snapshot()
        #expect(snapshot.levelDB == MasterAnalysisSnapshot.floorDB)
        #expect(snapshot.peakDB == MasterAnalysisSnapshot.floorDB)
        for value in snapshot.bands {
            #expect(value == MasterAnalysisSnapshot.floorDB)
        }
        #expect(snapshot.flux == 0)
        #expect(abs(snapshot.centroidHz) < 1)
    }

    // MARK: - Poison / wire safety

    @Test("NaN/Inf-poisoned input never reaches the snapshot; JSON encodes finite")
    func poisonedInputStaysFinite() throws {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        analyzer.process(Self.sine(frequency: 1_000, amplitude: 0.5, seconds: 0.25))
        var poison = [Float](repeating: 0, count: 8_192)
        for index in poison.indices {
            poison[index] = index.isMultiple(of: 3) ? .nan
                : (index.isMultiple(of: 5) ? .infinity : 1e30)
        }
        analyzer.process(poison)
        analyzer.process(Self.sine(frequency: 1_000, amplitude: 0.5, seconds: 0.25))
        let snapshot = analyzer.snapshot()

        for value in snapshot.bands { #expect(value.isFinite) }
        #expect(snapshot.levelDB.isFinite)
        #expect(snapshot.peakDB.isFinite)
        #expect(snapshot.centroidHz.isFinite)
        #expect(snapshot.flux.isFinite && snapshot.flux >= 0 && snapshot.flux <= 1)

        // The wire contract: the snapshot round-trips through JSON (which
        // has no NaN/Inf — a non-finite field would throw here).
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(MasterAnalysisSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.bands.count == MasterAnalysisSnapshot.bandCount)
    }

    @Test("floor snapshot JSON-encodes with 24 bands and all fields finite")
    func floorSnapshotEncodes() throws {
        let data = try JSONEncoder().encode(MasterAnalysisSnapshot.floor)
        let decoded = try JSONDecoder().decode(MasterAnalysisSnapshot.self, from: data)
        #expect(decoded == .floor)
        #expect(decoded.bands.count == 24)
    }

    // MARK: - Feeding shapes

    @Test("chunk size never changes the result (tap-buffer independence)")
    func chunkInvariance() {
        let signal = Self.sine(frequency: 1_000, amplitude: 0.5, seconds: 0.5)

        let wholeAnalyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        wholeAnalyzer.process(signal)

        let chunkedAnalyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        var offset = 0
        let chunks = [512, 1_024, 333, 4_096, 1]
        var chunkIndex = 0
        while offset < signal.count {
            let size = min(chunks[chunkIndex % chunks.count], signal.count - offset)
            chunkedAnalyzer.process(Array(signal[offset..<(offset + size)]))
            offset += size
            chunkIndex += 1
        }
        #expect(wholeAnalyzer.snapshot() == chunkedAnalyzer.snapshot())
    }

    @Test("processMix mono-mixes deinterleaved stereo like a mono average")
    func stereoMixdown() {
        let left = Self.sine(frequency: 1_000, amplitude: 0.5, seconds: 0.5)
        let right = Self.sine(frequency: 1_000, amplitude: 0.5, seconds: 0.5)

        let stereoAnalyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        var leftCopy = left
        var rightCopy = right
        leftCopy.withUnsafeMutableBufferPointer { leftBuffer in
            rightCopy.withUnsafeMutableBufferPointer { rightBuffer in
                let channels = [leftBuffer.baseAddress!, rightBuffer.baseAddress!]
                channels.withUnsafeBufferPointer { pointers in
                    stereoAnalyzer.processMix(
                        channels: pointers.baseAddress!,
                        channelCount: 2,
                        frameCount: left.count)
                }
            }
        }

        let monoAnalyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        monoAnalyzer.process(left)  // identical channels: average == either

        let stereo = stereoAnalyzer.snapshot()
        let mono = monoAnalyzer.snapshot()
        #expect(abs(stereo.levelDB - mono.levelDB) < 0.01)
        #expect(abs(stereo.centroidHz - mono.centroidHz) < 1)
    }

    @Test("reset returns to the exact floor state")
    func resetToFloor() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        analyzer.process(Self.sine(frequency: 1_000, amplitude: 0.9, seconds: 0.5))
        #expect(analyzer.snapshot() != .floor)
        analyzer.reset()
        #expect(analyzer.snapshot() == .floor)
    }

    @Test("degenerate sample rate falls back instead of trapping")
    func degenerateSampleRate() {
        let analyzer = MasterMixAnalyzer(sampleRate: 0)
        analyzer.process(Self.sine(frequency: 1_000, amplitude: 0.5, seconds: 0.25))
        let snapshot = analyzer.snapshot()
        #expect(snapshot.levelDB.isFinite)
        #expect(snapshot.centroidHz.isFinite)
    }
}
