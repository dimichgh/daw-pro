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

/// m22-d stereo-image gate fixtures: correlation / width / balance from
/// known L/R signals, the documented floors, poison safety, additive JSON
/// compatibility, and the goniometer scope-feed ring. All headless — stereo
/// buffers in via `processMix` (the engine's entry point), snapshot out.
@Suite("Master-mix analyzer — stereo image (m22-d)")
struct MasterStereoImageTests {

    private static let sampleRate = 48_000.0

    private static func sine(
        frequency: Double, amplitude: Float, seconds: Double
    ) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { frame in
            amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
    }

    /// Deterministic uniform noise in (−amplitude, +amplitude): SplitMix64
    /// from a FIXED seed — never the clock, so the decorrelation fixture is
    /// bit-reproducible.
    private static func noise(seed: UInt64, amplitude: Float, count: Int) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let unit = Float(z >> 40) * (1.0 / Float(1 << 24))  // [0, 1)
            return (unit * 2 - 1) * amplitude
        }
    }

    /// Feed a deinterleaved stereo pair through `processMix` in `chunk`-
    /// sized slices (deliberately not hop-aligned by default — the stereo
    /// path is hop-cadenced internally, so chunking must not matter).
    private static func feedStereo(
        _ analyzer: MasterMixAnalyzer,
        left: [Float], right: [Float], chunk: Int = 1_024
    ) {
        precondition(left.count == right.count)
        var leftCopy = left
        var rightCopy = right
        leftCopy.withUnsafeMutableBufferPointer { leftBuffer in
            rightCopy.withUnsafeMutableBufferPointer { rightBuffer in
                var offset = 0
                while offset < leftBuffer.count {
                    let take = min(chunk, leftBuffer.count - offset)
                    let channels = [leftBuffer.baseAddress! + offset,
                                    rightBuffer.baseAddress! + offset]
                    channels.withUnsafeBufferPointer { pointers in
                        analyzer.processMix(channels: pointers.baseAddress!,
                                            channelCount: 2, frameCount: take)
                    }
                    offset += take
                }
            }
        }
    }

    // MARK: - GATE fixtures

    @Test("identical L/R (mono): correlation exactly +1, width exactly 0, balance exactly 0")
    func monoCorrelationIsExactlyOne() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        let signal = Self.sine(frequency: 440, amplitude: 0.5, seconds: 1.0)
        Self.feedStereo(analyzer, left: signal, right: signal, chunk: 333)
        let snapshot = analyzer.snapshot()
        print("[measured] m22-d mono fixture: correlation \(snapshot.correlation), "
              + "width \(snapshot.width), balance \(snapshot.balance)")
        #expect(snapshot.correlation == 1.0)
        #expect(snapshot.width == 0.0)
        #expect(snapshot.balance == 0.0)
    }

    @Test("inverted R = −L: correlation exactly −1, width exactly 1, balance exactly 0")
    func invertedCorrelationIsExactlyMinusOne() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        let left = Self.sine(frequency: 440, amplitude: 0.5, seconds: 1.0)
        let right = left.map { -$0 }
        Self.feedStereo(analyzer, left: left, right: right, chunk: 777)
        let snapshot = analyzer.snapshot()
        print("[measured] m22-d inverted fixture: correlation \(snapshot.correlation), "
              + "width \(snapshot.width), balance \(snapshot.balance)")
        #expect(snapshot.correlation == -1.0)
        #expect(snapshot.width == 1.0)
        #expect(snapshot.balance == 0.0)
    }

    @Test("independent seeded noise: correlation ≈ 0, width ≈ 0.5, balance ≈ 0")
    func decorrelatedNoiseReadsNearZero() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        let count = Int(2.0 * Self.sampleRate)
        let left = Self.noise(seed: 0x5EED_0001, amplitude: 0.25, count: count)
        let right = Self.noise(seed: 0xFACE_0002, amplitude: 0.25, count: count)
        Self.feedStereo(analyzer, left: left, right: right)
        let snapshot = analyzer.snapshot()
        print("[measured] m22-d decorrelated fixture: correlation \(snapshot.correlation), "
              + "width \(snapshot.width), balance \(snapshot.balance)")
        #expect(abs(snapshot.correlation) < 0.1,
                "correlation \(snapshot.correlation) for independent noise")
        #expect(snapshot.width > 0.4 && snapshot.width < 0.6,
                "width \(snapshot.width) for independent noise")
        #expect(abs(snapshot.balance) < 0.1,
                "balance \(snapshot.balance) for equal-energy noise")
    }

    @Test("hard-panned left: balance exactly −1, width exactly 0.5, correlation +1 (dead-channel convention)")
    func hardPanLeft() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        let left = Self.sine(frequency: 440, amplitude: 0.5, seconds: 1.0)
        let right = [Float](repeating: 0, count: left.count)
        Self.feedStereo(analyzer, left: left, right: right)
        let snapshot = analyzer.snapshot()
        // Documented extremes: all the energy on one side. Correlation
        // reads +1 by the dead-channel convention — a hard-panned MONO
        // source loses nothing to cancellation when summed to mono.
        #expect(snapshot.balance == -1.0)
        #expect(snapshot.width == 0.5)
        #expect(snapshot.correlation == 1.0)
    }

    @Test("hard-panned right mirrors: balance exactly +1")
    func hardPanRight() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        let right = Self.sine(frequency: 440, amplitude: 0.5, seconds: 1.0)
        let left = [Float](repeating: 0, count: right.count)
        Self.feedStereo(analyzer, left: left, right: right)
        let snapshot = analyzer.snapshot()
        #expect(snapshot.balance == 1.0)
        #expect(snapshot.width == 0.5)
        #expect(snapshot.correlation == 1.0)
    }

    // MARK: - Floors, mono input, decay

    @Test("fresh analyzer sits exactly on the stereo floors (corr +1, width 0, balance 0)")
    func freshStereoFloors() {
        let snapshot = MasterMixAnalyzer(sampleRate: Self.sampleRate).snapshot()
        #expect(snapshot.correlation == 1.0)
        #expect(snapshot.width == 0.0)
        #expect(snapshot.balance == 0.0)
        #expect(snapshot == .floor)
    }

    @Test("1-channel processMix reads correlation +1 by definition")
    func monoChannelCountReadsPlusOne() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        var mono = Self.sine(frequency: 440, amplitude: 0.5, seconds: 1.0)
        mono.withUnsafeMutableBufferPointer { buffer in
            let channels = [buffer.baseAddress!]
            channels.withUnsafeBufferPointer { pointers in
                analyzer.processMix(channels: pointers.baseAddress!,
                                    channelCount: 1, frameCount: buffer.count)
            }
        }
        let snapshot = analyzer.snapshot()
        #expect(snapshot.correlation == 1.0)
        #expect(snapshot.width == 0.0)
        #expect(snapshot.balance == 0.0)
    }

    @Test("stereo silence decays the image to the exact floors (snap below −80 dB)")
    func silenceDecaysToStereoFloors() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        let left = Self.sine(frequency: 440, amplitude: 0.5, seconds: 1.0)
        let right = left.map { -$0 }
        Self.feedStereo(analyzer, left: left, right: right)
        #expect(analyzer.snapshot().correlation == -1.0)

        let zeros = [Float](repeating: 0, count: Int(7 * Self.sampleRate))
        Self.feedStereo(analyzer, left: zeros, right: zeros)
        let snapshot = analyzer.snapshot()
        // τ 300 ms ⇒ the image decays at ~14.5 dB/s and snaps to zero below
        // the −80 dB house floor — 7 s of silence is comfortably past it.
        #expect(snapshot.correlation == 1.0)
        #expect(snapshot.width == 0.0)
        #expect(snapshot.balance == 0.0)
    }

    @Test("correlation HOLDS its reading through a short silence (energy-ratio ballistics)")
    func correlationHoldsThroughShortSilence() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        let left = Self.sine(frequency: 440, amplitude: 0.5, seconds: 1.0)
        let right = left.map { -$0 }
        Self.feedStereo(analyzer, left: left, right: right)

        let zeros = [Float](repeating: 0, count: Int(0.5 * Self.sampleRate))
        Self.feedStereo(analyzer, left: zeros, right: zeros)
        // All three sums decay by the same factor, so the RATIO — the
        // correlation — holds until the floor snap (standard meter feel).
        #expect(analyzer.snapshot().correlation == -1.0)
    }

    @Test("reset returns the stereo image and the scope ring to the exact floor state")
    func resetClearsStereoState() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        let left = Self.sine(frequency: 440, amplitude: 0.5, seconds: 0.5)
        let right = left.map { -$0 }
        Self.feedStereo(analyzer, left: left, right: right)
        #expect(analyzer.snapshot() != .floor)
        analyzer.reset()
        #expect(analyzer.snapshot() == .floor)
        #expect(analyzer.scopeFrame() == .empty)
    }

    // MARK: - Poison / wire safety

    @Test("NaN/Inf-poisoned stereo hops are skipped whole; fields stay finite and clamped")
    func poisonedStereoInputStaysFinite() throws {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        let tone = Self.sine(frequency: 440, amplitude: 0.5, seconds: 0.5)
        Self.feedStereo(analyzer, left: tone, right: tone)

        var poisonLeft = [Float](repeating: 0, count: 8_192)
        var poisonRight = [Float](repeating: 0, count: 8_192)
        for index in poisonLeft.indices {
            poisonLeft[index] = index.isMultiple(of: 3) ? .nan
                : (index.isMultiple(of: 5) ? .infinity : 1e30)
            poisonRight[index] = index.isMultiple(of: 2) ? -.infinity : 1e25
        }
        Self.feedStereo(analyzer, left: poisonLeft, right: poisonRight)
        Self.feedStereo(analyzer, left: tone, right: tone)

        let snapshot = analyzer.snapshot()
        #expect(snapshot.correlation.isFinite
                && snapshot.correlation >= -1 && snapshot.correlation <= 1)
        #expect(snapshot.width.isFinite && snapshot.width >= 0 && snapshot.width <= 1)
        #expect(snapshot.balance.isFinite
                && snapshot.balance >= -1 && snapshot.balance <= 1)
        // The identical-channel tone still reads mono-safe after recovery.
        #expect(snapshot.correlation == 1.0)

        // Scope ring: write-time finite guard — the frame never carries
        // NaN/Inf even though poisoned samples passed through it.
        let frame = analyzer.scopeFrame()
        for value in frame.left { #expect(value.isFinite) }
        for value in frame.right { #expect(value.isFinite) }

        // Wire contract: JSON (no NaN/Inf) round-trips the whole snapshot.
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(MasterAnalysisSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test("JSON round-trip carries the new keys; legacy JSON without them decodes to floors")
    func additiveJSONCompatibility() throws {
        let snapshot = MasterAnalysisSnapshot(
            bands: [Float](repeating: -30, count: MasterAnalysisSnapshot.bandCount),
            levelDB: -12, peakDB: -6, centroidHz: 2_000, flux: 0.25,
            correlation: -0.5, width: 0.75, balance: 0.125)
        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["correlation"] as? Double == -0.5)
        #expect(object["width"] as? Double == 0.75)
        #expect(object["balance"] as? Double == 0.125)
        let decoded = try JSONDecoder().decode(MasterAnalysisSnapshot.self, from: data)
        #expect(decoded == snapshot)

        // Pre-m22-d JSON (no stereo keys): decodes to the stereo floors
        // instead of throwing — the additive-fields law on the read side.
        let legacy = Data("""
        {"bands": \([Float](repeating: -80, count: 24)), "levelDB": -80,
         "peakDB": -80, "centroidHz": 0, "flux": 0}
        """.utf8)
        let fromLegacy = try JSONDecoder().decode(MasterAnalysisSnapshot.self, from: legacy)
        #expect(fromLegacy.correlation == 1.0)
        #expect(fromLegacy.width == 0.0)
        #expect(fromLegacy.balance == 0.0)
        #expect(fromLegacy == .floor)
    }

    // MARK: - Scope feed (phase-2 seam)

    @Test("fresh analyzer's scope frame is the all-zero .empty")
    func freshScopeIsEmpty() {
        #expect(MasterMixAnalyzer(sampleRate: Self.sampleRate).scopeFrame() == .empty)
    }

    @Test("scope ring: ×8 decimated picks, oldest → newest, chunking-independent")
    func scopeRingOrderAndDecimation() {
        let analyzer = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        // Exactly pairCount × decimation samples of a known ramp: the ring
        // fills exactly once, so frame[i] must be ramp[i × 8] in order.
        let count = MasterScopeFrame.pairCount * MasterMixAnalyzer.scopeDecimation
        let ramp = (0..<count).map { Float($0) / Float(count) }
        let right = ramp.map { -$0 }
        Self.feedStereo(analyzer, left: ramp, right: right, chunk: 333)

        let frame = analyzer.scopeFrame()
        #expect(frame.left.count == MasterScopeFrame.pairCount)
        #expect(frame.right.count == MasterScopeFrame.pairCount)
        for index in 0..<MasterScopeFrame.pairCount {
            let expected = ramp[index * MasterMixAnalyzer.scopeDecimation]
            #expect(frame.left[index] == expected)
            #expect(frame.right[index] == -expected)
        }
    }

    @Test("scope frame mirrors the image: mono ⇒ left == right, hard-pan ⇒ dead side all-zero")
    func scopeReflectsImage() {
        let mono = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        let tone = Self.sine(frequency: 440, amplitude: 0.5, seconds: 0.25)
        Self.feedStereo(mono, left: tone, right: tone)
        let monoFrame = mono.scopeFrame()
        #expect(monoFrame.left == monoFrame.right)
        #expect(monoFrame.left.contains { $0 != 0 })

        let panned = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        Self.feedStereo(panned, left: tone,
                        right: [Float](repeating: 0, count: tone.count))
        let pannedFrame = panned.scopeFrame()
        #expect(pannedFrame.left.contains { $0 != 0 })
        #expect(pannedFrame.right.allSatisfy { $0 == 0 })
    }

    // MARK: - Old-field parity

    @Test("stereo metrics never disturb the mono-summed spectral fields (parity with plain process)")
    func spectralFieldsUnchangedByStereoPath() {
        let signal = Self.sine(frequency: 1_000, amplitude: 0.5, seconds: 0.5)

        let stereo = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        Self.feedStereo(stereo, left: signal, right: signal)

        let mono = MasterMixAnalyzer(sampleRate: Self.sampleRate)
        mono.process(signal)  // identical channels: average == either

        let stereoSnapshot = stereo.snapshot()
        let monoSnapshot = mono.snapshot()
        #expect(stereoSnapshot.bands == monoSnapshot.bands)
        #expect(stereoSnapshot.levelDB == monoSnapshot.levelDB)
        #expect(stereoSnapshot.peakDB == monoSnapshot.peakDB)
        #expect(stereoSnapshot.centroidHz == monoSnapshot.centroidHz)
        #expect(stereoSnapshot.flux == monoSnapshot.flux)
    }
}
