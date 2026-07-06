import Foundation
import Testing
@testable import DAWEngine

/// M5 (ii-b) OfflineStretcher facade over vendored signalsmith-stretch —
/// analytic offline-render assertions per the settled seam spec §8: length is
/// checked against round(inputFrames × ratio) within ±1%, pitch via
/// zero-crossing rate over the steady middle 50% within ±3%, plus
/// finiteness (NaN/inf guard), cancellation promptness, and bit-exact
/// determinism (fixed RNG seed). Phase-vocoder output is never bit-compared
/// to a reference — the assertions are signal facts, not golden files.
@Suite("OfflineStretcher (M5 ii-b)")
struct OfflineStretcherTests {
    static let sampleRate = 48_000.0
    static let sineHz = 440.0
    static let seconds = 2.0
    static let inputFrames = Int(sampleRate * seconds) // 96_000

    // MARK: - Helpers

    /// Full-scale-ish mono sine, planar single channel.
    static func sine(
        freq: Double = sineHz, frames: Int = inputFrames,
        rate: Double = sampleRate, amplitude: Float = 0.8
    ) -> [Float] {
        (0..<frames).map { n in
            amplitude * Float(sin(2.0 * .pi * freq * Double(n) / rate))
        }
    }

    /// Fundamental estimate from positive-going zero crossings over the
    /// steady middle 50% of the signal (skips the windowed head/tail).
    /// Hysteresis at 5% of peak so residual phase-vocoder noise near zero
    /// can't double-count.
    static func zeroCrossingHz(_ samples: [Float], rate: Double = sampleRate) -> Double {
        let start = samples.count / 4
        let end = (samples.count * 3) / 4
        let window = samples[start..<end]
        let peak = window.reduce(Float(0)) { max($0, abs($1)) }
        precondition(peak > 0, "silent window")
        let threshold = 0.05 * peak
        var below = false
        var crossings = 0
        for s in window {
            if s < -threshold {
                below = true
            } else if s > threshold, below {
                crossings += 1
                below = false
            }
        }
        return Double(crossings) / (Double(window.count) / rate)
    }

    static func allFinite(_ channels: [[Float]]) -> Bool {
        channels.allSatisfy { channel in channel.allSatisfy(\.isFinite) }
    }

    /// Runs the facade on a stereo 440 Hz sine and returns channel 0 plus the
    /// full output (stereo exercises the planar channel plumbing everywhere).
    static func run(
        ratio: Double, semitones: Double, formantPreserve: Bool = false,
        isCancelled: () -> Bool = { false }
    ) throws -> [[Float]] {
        let mono = sine()
        return try OfflineStretcher.stretch(
            input: [mono, mono], sampleRate: sampleRate, ratio: ratio,
            semitones: semitones, formantPreserve: formantPreserve,
            isCancelled: isCancelled)
    }

    // MARK: - Spec §8 analytic tests

    @Test("ratio 1.5: length ±1%, pitch stays 440 Hz ±3%")
    func stretchLonger() throws {
        let out = try Self.run(ratio: 1.5, semitones: 0)
        let expected = Double(Self.inputFrames) * 1.5 // 144_000
        #expect(out.count == 2)
        for channel in out {
            #expect(abs(Double(channel.count) - expected) <= expected * 0.01)
            let hz = Self.zeroCrossingHz(channel)
            #expect(abs(hz - Self.sineHz) <= Self.sineHz * 0.03, "measured \(hz) Hz")
        }
        #expect(Self.allFinite(out))
    }

    @Test("ratio 0.75: length ±1%, pitch stays 440 Hz ±3%")
    func stretchShorter() throws {
        let out = try Self.run(ratio: 0.75, semitones: 0)
        let expected = Double(Self.inputFrames) * 0.75 // 72_000
        #expect(abs(Double(out[0].count) - expected) <= expected * 0.01)
        let hz = Self.zeroCrossingHz(out[0])
        #expect(abs(hz - Self.sineHz) <= Self.sineHz * 0.03, "measured \(hz) Hz")
        #expect(Self.allFinite(out))
    }

    @Test("+7 semitones at ratio 1.0: length ±1%, pitch ≈ 659.3 Hz ±3%")
    func pitchShiftUp() throws {
        let out = try Self.run(ratio: 1.0, semitones: 7)
        let expectedLength = Double(Self.inputFrames)
        #expect(abs(Double(out[0].count) - expectedLength) <= expectedLength * 0.01)
        let expectedHz = Self.sineHz * pow(2.0, 7.0 / 12.0) // ≈ 659.255
        let hz = Self.zeroCrossingHz(out[0])
        #expect(abs(hz - expectedHz) <= expectedHz * 0.03, "measured \(hz) Hz")
        #expect(Self.allFinite(out))
    }

    /// Identity PARAMETERS through the stretcher are a sanity check only —
    /// the real identity contract is `isIdentity` below: ii-d must bypass the
    /// facade entirely for (1.0, 0) and play the original file.
    @Test("ratio 1.0 + 0 st through the stretcher: sane length and pitch")
    func identityParamsSanity() throws {
        let out = try Self.run(ratio: 1.0, semitones: 0)
        let expectedLength = Double(Self.inputFrames)
        #expect(abs(Double(out[0].count) - expectedLength) <= expectedLength * 0.01)
        let hz = Self.zeroCrossingHz(out[0])
        #expect(abs(hz - Self.sineHz) <= Self.sineHz * 0.03, "measured \(hz) Hz")
        #expect(Self.allFinite(out))
    }

    @Test("formant-preserve path renders (pitch still lands, output finite)")
    func formantPreserveRenders() throws {
        let out = try Self.run(ratio: 1.0, semitones: 7, formantPreserve: true)
        let expectedHz = Self.sineHz * pow(2.0, 7.0 / 12.0)
        let hz = Self.zeroCrossingHz(out[0])
        #expect(abs(hz - expectedHz) <= expectedHz * 0.03, "measured \(hz) Hz")
        #expect(Self.allFinite(out))
    }

    // MARK: - Identity helper (the ii-d bypass contract)

    @Test("isIdentity is true ONLY for exactly (1.0, 0.0)")
    func identityPredicate() {
        #expect(OfflineStretcher.isIdentity(ratio: 1.0, semitones: 0.0))
        #expect(!OfflineStretcher.isIdentity(ratio: 1.0000001, semitones: 0.0))
        #expect(!OfflineStretcher.isIdentity(ratio: 0.9999999, semitones: 0.0))
        #expect(!OfflineStretcher.isIdentity(ratio: 1.0, semitones: 0.01))
        #expect(!OfflineStretcher.isIdentity(ratio: 1.0, semitones: -0.01))
        #expect(!OfflineStretcher.isIdentity(ratio: 1.5, semitones: 0.0))
        #expect(!OfflineStretcher.isIdentity(ratio: 1.0, semitones: 7.0))
        #expect(!OfflineStretcher.isIdentity(ratio: 0.75, semitones: -3.0))
    }

    // MARK: - Cancellation

    @Test("cancel after the first block throws promptly, well short of full input")
    func cancellation() throws {
        // ~35 blocks of 4096 output frames for 2 s at ratio 1.5; the closure
        // is polled once per block (plus once pre-flush), so trip it on the
        // second poll and require the throw within the first few blocks.
        var polls = 0
        let expectedBlocks =
            (Int(Double(Self.inputFrames) * 1.5) + OfflineStretcher.blockFrames - 1)
            / OfflineStretcher.blockFrames
        #expect(expectedBlocks > 30) // the test is meaningless if input is tiny
        var thrown: OfflineStretcherError?
        do {
            _ = try Self.run(ratio: 1.5, semitones: 0) {
                polls += 1
                return polls > 1
            }
        } catch let error as OfflineStretcherError {
            thrown = error
        }
        #expect(thrown == .cancelled)
        #expect(polls == 2, "processed \(polls) blocks, expected to stop at 2")
        #expect(polls < expectedBlocks)
    }

    // MARK: - Determinism

    @Test("two runs are bit-identical (seeded RNG, no random_device)")
    func determinism() throws {
        let a = try Self.run(ratio: 1.5, semitones: 7)
        let b = try Self.run(ratio: 1.5, semitones: 7)
        #expect(a.count == b.count)
        for (chA, chB) in zip(a, b) {
            #expect(chA.count == chB.count)
            #expect(
                zip(chA, chB).allSatisfy { $0.bitPattern == $1.bitPattern },
                "outputs differ bitwise")
        }
    }
}
