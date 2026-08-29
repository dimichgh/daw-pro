import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m32-b2 — `BoundarySnapper`, the ONE engine seam behind
/// `clip.sliceToSampler`.
///
/// Fixture frequencies are chosen so a zero crossing lands EXACTLY on an
/// integer frame: 441 Hz at 44.1 kHz has a period of exactly 100 samples, so
/// crossings sit at frames 0, 50, 100, … and peaks at 25, 75, …. A "nice"
/// 440 Hz would put every crossing at a fractional frame and the best
/// achievable residual would be ~0.03, which would make the
/// "did we find a real crossing?" assertion untestable rather than merely
/// loose.
///
/// ⚠️ Mono fixture lengths are deliberately mixed: `alignedFrames` is a
/// multiple of 1024 and `raggedFrames` is not. A single
/// `AVAudioFile.read(into:)` SHORT-READS mono files whose frame count is not a
/// multiple of 1024 (m32-h — up to 1023 frames lost, silently). The snapper
/// reads in a loop and is immune; `raggedMonoFileReadsToItsRealEnd` is the
/// test that proves it rather than assuming it.
/// (`@MainActor` for the same reason the m32-a dedup suite is: the fixture
/// cache is a `static var`, and Swift 6 strict concurrency wants it isolated.)
@MainActor
@Suite("BoundarySnapper — boundary snapping (m32-b2)", .serialized)
struct BoundarySnapperTests {

    private static let rate = 44_100.0
    /// 44 × 1024 ≈ 1.022 s @ 44.1 kHz.
    private static let alignedFrames = 45_056
    /// NOT a multiple of 1024 — the m32-h short-read shape.
    private static let raggedFrames = 44_100

    // MARK: - Fixtures

    private struct Fixtures {
        /// Mono 441 Hz, aligned length. Crossings at every 50th frame.
        let sine: URL
        /// Mono 441 Hz, RAGGED length (44 100 frames).
        let raggedSine: URL
        /// Stereo, L = sin, R = cos at 441 Hz — the channels never cross
        /// together, so `max_c |x_c[k]| >= 0.5/√2` everywhere.
        let quadrature: URL
        /// Mono constant +0.5: NO zero crossing anywhere.
        let dc: URL
        /// The same 441 Hz content written at 48 kHz.
        let sine48k: URL
    }

    private static var cached: Fixtures?

    private func fixtures() throws -> Fixtures {
        if let cached = Self.cached { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32b2-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sine = dir.appendingPathComponent("sine441.wav")
        try Self.write(to: sine, rate: Self.rate, frames: Self.alignedFrames, channels: 1) { _, n in
            0.5 * sin(2.0 * .pi * 441.0 * Double(n) / Self.rate)
        }
        let ragged = dir.appendingPathComponent("sine441-ragged.wav")
        try Self.write(to: ragged, rate: Self.rate, frames: Self.raggedFrames, channels: 1) { _, n in
            0.5 * sin(2.0 * .pi * 441.0 * Double(n) / Self.rate)
        }
        let quad = dir.appendingPathComponent("quadrature.wav")
        try Self.write(to: quad, rate: Self.rate, frames: Self.alignedFrames, channels: 2) { c, n in
            let phase = 2.0 * .pi * 441.0 * Double(n) / Self.rate
            return 0.5 * (c == 0 ? sin(phase) : cos(phase))
        }
        let dc = dir.appendingPathComponent("dc.wav")
        try Self.write(to: dc, rate: Self.rate, frames: Self.alignedFrames, channels: 1) { _, _ in 0.5 }
        let sine48k = dir.appendingPathComponent("sine441-48k.wav")
        try Self.write(to: sine48k, rate: 48_000, frames: 49_152, channels: 1) { _, n in
            0.5 * sin(2.0 * .pi * 441.0 * Double(n) / 48_000.0)
        }

        let set = Fixtures(sine: sine, raggedSine: ragged, quadrature: quad,
                           dc: dc, sine48k: sine48k)
        Self.cached = set
        return set
    }

    private static func write(to url: URL, rate: Double, frames: Int,
                              channels channelCount: AVAudioChannelCount,
                              sample: (Int, Int) -> Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: channelCount, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw NSError(domain: "BoundarySnapperTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        for channel in 0..<Int(channelCount) {
            for frame in 0..<frames { data[channel][frame] = Float(sample(channel, frame)) }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    // MARK: - The snap itself

    @Test("a candidate on a PEAK snaps to the nearest exact zero crossing")
    func snapsToCrossing() throws {
        let f = try fixtures()
        // Frame 1025 is a peak (1025 mod 100 == 25). Crossings sit at 1000 and
        // 1050, both 25 frames away and both inside a 3 ms (132-frame) window.
        let g = try BoundarySnapper.resolve(fileAt: f.sine, boundarySeconds: [1025.0 / Self.rate],
                                            snapWindowSeconds: 0.003)
        #expect(g.sampleRate == Self.rate)
        #expect(g.frameCount == Self.alignedFrames)
        let chosen = try #require(g.boundaryFrames.first)
        #expect(chosen % 50 == 0)                       // landed on a crossing
        // The NEAREST crossings are 1000 and 1050. Five crossings sit inside
        // the 132-frame window and all are zero to within float noise, so this
        // is the pin on the tie-break-toward-the-candidate tolerance: a
        // bit-exact `==` tie test picks whichever `sin(kπ)` happened to round
        // smallest and lands 125 frames out.
        #expect(abs(chosen - 1025) <= 25)
        #expect(try #require(g.residualAmplitude.first) < 1e-3)
        #expect(try #require(g.snapOffsetFrames.first) == chosen - 1025)

        // ⭐ POSITIVE CONTROL: the UNSNAPPED frame is loud. Without this the
        // "residual < 1e-3" assertion could be passing on a snapper that
        // returned any frame at all on a quiet file.
        let unsnapped = try BoundarySnapper.resolve(
            fileAt: f.sine, boundarySeconds: [1025.0 / Self.rate], snapWindowSeconds: 0)
        #expect(unsnapped.boundaryFrames == [1025])
        #expect(try #require(unsnapped.residualAmplitude.first) > 0.49)
    }

    @Test("snapWindowSeconds 0 returns the rounded candidates EXACTLY")
    func zeroWindowIsIdentity() throws {
        let f = try fixtures()
        let seconds = [0.25, 0.5, 0.75]
        let g = try BoundarySnapper.resolve(fileAt: f.sine, boundarySeconds: seconds,
                                            snapWindowSeconds: 0)
        #expect(g.boundaryFrames == seconds.map { Int(($0 * Self.rate).rounded()) })
        #expect(g.snapOffsetFrames == [0, 0, 0])
    }

    @Test("a stereo file with NO simultaneous crossing reports an honest residual")
    func stereoResidualIsHonest() throws {
        let f = try fixtures()
        let g = try BoundarySnapper.resolve(fileAt: f.quadrature,
                                            boundarySeconds: [1025.0 / Self.rate],
                                            snapWindowSeconds: 0.003)
        let residual = try #require(g.residualAmplitude.first)
        // sin and cos are never both small: max(|sin|,|cos|) >= 1/√2, so the
        // best achievable here is ~0.5/√2 = 0.354. The snapper must SAY so
        // rather than implying a clean cut.
        #expect(residual > 0.3)
        #expect(residual < 0.4)
        // ⭐ POSITIVE CONTROL: the MONO file, same candidate, same window,
        // reaches ~0 — so this assertion is measuring the material, not a
        // snapper that always reports a big number.
        let mono = try BoundarySnapper.resolve(fileAt: f.sine,
                                               boundarySeconds: [1025.0 / Self.rate],
                                               snapWindowSeconds: 0.003)
        #expect(try #require(mono.residualAmplitude.first) < 1e-3)
    }

    @Test("a DC fixture with no crossings still returns a frame and does NOT throw")
    func dcOffsetDoesNotThrow() throws {
        let f = try fixtures()
        let g = try BoundarySnapper.resolve(fileAt: f.dc, boundarySeconds: [0.5],
                                            snapWindowSeconds: 0.003)
        #expect(g.boundaryFrames.count == 1)
        // Every frame is equally bad, so the tie-break toward the candidate
        // must leave it exactly where it was.
        #expect(g.boundaryFrames == [Int((0.5 * Self.rate).rounded())])
        #expect(g.snapOffsetFrames == [0])
        #expect(abs(try #require(g.residualAmplitude.first) - 0.5) < 1e-5)
    }

    // MARK: - Invariants

    @Test("output is STRICTLY increasing even when the windows overlap")
    func strictlyIncreasing() throws {
        let f = try fixtures()
        // Two candidates 4 frames apart with a 3 ms (132-frame) window: without
        // the defensive floor they would both minimise onto the SAME crossing
        // and collapse to a zero-length pad.
        let g = try BoundarySnapper.resolve(
            fileAt: f.sine,
            boundarySeconds: [1000.0 / Self.rate, 1004.0 / Self.rate],
            snapWindowSeconds: 0.003)
        #expect(g.boundaryFrames.count == 2)
        #expect(g.boundaryFrames[1] > g.boundaryFrames[0])
        // The residual reported for the pushed boundary is measured AT the
        // frame actually chosen, not at the one originally found.
        let pushed = g.boundaryFrames[1]
        let atPushed = try BoundarySnapper.resolve(
            fileAt: f.sine, boundarySeconds: [Double(pushed) / Self.rate],
            snapWindowSeconds: 0)
        #expect(abs(try #require(g.residualAmplitude.last)
                    - (try #require(atPushed.residualAmplitude.first))) < 1e-6)
    }

    @Test("many boundaries stay ascending and inside the file")
    func manyBoundaries() throws {
        let f = try fixtures()
        let seconds = (1...30).map { Double($0) * 0.03 }
        let g = try BoundarySnapper.resolve(fileAt: f.sine, boundarySeconds: seconds,
                                            snapWindowSeconds: 0.003)
        #expect(g.boundaryFrames.count == 30)
        for i in 1..<g.boundaryFrames.count {
            #expect(g.boundaryFrames[i] > g.boundaryFrames[i - 1])
        }
        #expect(g.boundaryFrames.allSatisfy { $0 >= 0 && $0 < Self.alignedFrames })
        // Every one found a real crossing on this fixture.
        #expect(g.residualAmplitude.allSatisfy { $0 < 1e-3 })
    }

    @Test("a candidate past the file end clamps into the file")
    func clampsToFile() throws {
        let f = try fixtures()
        let g = try BoundarySnapper.resolve(fileAt: f.sine, boundarySeconds: [10_000],
                                            snapWindowSeconds: 0.003)
        let chosen = try #require(g.boundaryFrames.first)
        #expect(chosen <= Self.alignedFrames - 1)
    }

    @Test("an empty candidate list still reports the file's real rate and length")
    func emptyCandidates() throws {
        let f = try fixtures()
        let g = try BoundarySnapper.resolve(fileAt: f.sine, boundarySeconds: [],
                                            snapWindowSeconds: 0.003)
        #expect(g.sampleRate == Self.rate)
        #expect(g.frameCount == Self.alignedFrames)
        #expect(g.boundaryFrames.isEmpty)
    }

    @Test("a missing file throws rather than fabricating a geometry")
    func missingFileThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32b2-absent-\(UUID().uuidString).wav")
        #expect(throws: BoundarySnapperError.self) {
            try BoundarySnapper.resolve(fileAt: missing, boundarySeconds: [0.5],
                                        snapWindowSeconds: 0.003)
        }
    }

    // MARK: - The rate, measured from the FILE

    @Test("⭐ the reported rate and frames come from the FILE, not a constant")
    func rateComesFromTheFile() throws {
        let f = try fixtures()
        let at441 = try BoundarySnapper.resolve(fileAt: f.sine, boundarySeconds: [0.5],
                                                snapWindowSeconds: 0)
        let at480 = try BoundarySnapper.resolve(fileAt: f.sine48k, boundarySeconds: [0.5],
                                                snapWindowSeconds: 0)
        #expect(at441.sampleRate == 44_100)
        #expect(at480.sampleRate == 48_000)
        #expect(at441.boundaryFrames == [22_050])
        #expect(at480.boundaryFrames == [24_000])
        // ⭐ POSITIVE CONTROL for a hardcoded 44100 in the seconds→frames
        // conversion: the SAME half-second must be a DIFFERENT frame number.
        #expect(at441.boundaryFrames != at480.boundaryFrames)
        #expect(at441.frameCount != at480.frameCount)
    }

    // MARK: - m32-h immunity

    @Test("a RAGGED-length mono file reads to its real end (m32-h immunity)")
    func raggedMonoFileReadsToItsRealEnd() throws {
        let f = try fixtures()
        // 44 100 frames is not a multiple of 1024: one `read(into:)` would stop
        // at 44 032 and every candidate in the last 68 frames would silently
        // fall off the end of what was read.
        #expect(Self.raggedFrames % 1024 != 0)
        let tail = Self.raggedFrames - 20
        let g = try BoundarySnapper.resolve(
            fileAt: f.raggedSine, boundarySeconds: [Double(tail) / Self.rate],
            snapWindowSeconds: 0)
        #expect(g.frameCount == Self.raggedFrames)
        #expect(g.boundaryFrames == [tail])
        // The residual at that frame is a REAL measurement of the tail, which
        // is only possible if the loop actually read past 44 032.
        let expected = abs(0.5 * sin(2.0 * .pi * 441.0 * Double(tail) / Self.rate))
        #expect(abs(try #require(g.residualAmplitude.first) - expected) < 1e-5)
        #expect(expected > 1e-3)      // the frame is genuinely non-zero
    }
}
