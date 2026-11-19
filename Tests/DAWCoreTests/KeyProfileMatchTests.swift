import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x4: `KeyProfileMatch`, the Krumhansl–Kessler key estimate MOVED from DAWEngine's `KeyEstimator` (design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §4.3). The byte-identity of the move is pinned in DAWEngineTests
/// (`KeyEstimatorLiftPinTests`, the audio path); these are the known-signal and honesty-gate assertions on the DAWCore
/// side, where the harmony planner calls it. Pure values, so NOT `@MainActor`.
@Suite("KeyProfileMatch: the Krumhansl–Kessler key estimate, in DAWCore (p2-sing-x4)")
struct KeyProfileMatchTests {

    /// The 1982 probe-tone profiles, typed here from the published table (not read from the type under test).
    static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func rotated(_ profile: [Double], to tonic: Int) -> [Double] {
        (0..<12).map { profile[(($0 - tonic) % 12 + 12) % 12] }
    }

    @Test("known signal: every rotation of the major profile reads its own key with r = 1 and confidence 1")
    func majorProfileRotations() {
        for tonic in 0..<12 {
            let estimate = KeyProfileMatch.estimate(chroma: Self.rotated(Self.major, to: tonic))
            #expect(estimate.tonic == KeyEstimate.pitchClassesSharp[tonic], "tonic \(tonic)")
            #expect(estimate.mode == "major", "tonic \(tonic)")
            #expect(estimate.confidence == 1, "tonic \(tonic): \(estimate.confidence)")
            #expect(estimate.tonal, "tonic \(tonic)")
            #expect(estimate.alternatives.count == 3)
        }
    }

    @Test("known signal: every rotation of the minor profile ranks its own minor key first")
    func minorProfileRotations() {
        for tonic in 0..<12 {
            let estimate = KeyProfileMatch.estimate(chroma: Self.rotated(Self.minor, to: tonic))
            #expect(estimate.tonic == KeyEstimate.pitchClassesSharp[tonic], "tonic \(tonic)")
            #expect(estimate.mode == "minor", "tonic \(tonic)")
            #expect(estimate.confidence == 1, "tonic \(tonic): \(estimate.confidence)")
        }
    }

    @Test("known signal: equal time on the seven notes of C major reads C major, tonal")
    func cMajorScale() {
        let chroma = (0..<12).map { [0, 2, 4, 5, 7, 9, 11].contains($0) ? 1.0 : 0 }
        let estimate = KeyProfileMatch.estimate(chroma: chroma)
        #expect(estimate.tonic == "C" && estimate.mode == "major" && estimate.tonal)
    }

    @Test("honesty gates: silence, a flat chroma and poisoned values (NaN, ±infinity, denormal) never read tonal")
    func degenerateChromasAreNotTonal() {
        let rows: [(String, [Double])] = [
            ("all zero", [Double](repeating: 0, count: 12)),
            ("flat", [Double](repeating: 1, count: 12)),
            ("flat denormal", [Double](repeating: 1e-310, count: 12)),
            ("NaN", (0..<12).map { $0 == 5 ? .nan : Double($0 % 3) }),
            ("+inf", (0..<12).map { $0 == 7 ? .infinity : Double($0 % 4) }),
            ("-inf", (0..<12).map { $0 == 2 ? -.infinity : 1 }),
        ]
        for (name, chroma) in rows {
            let estimate = KeyProfileMatch.estimate(chroma: chroma)
            #expect(!estimate.tonal, "\(name)")
            #expect(estimate.confidence == 0, "\(name)")
            #expect(estimate.confidence.isFinite && estimate.alternatives.allSatisfy { $0.score.isFinite }, "\(name)")
            // Every correlation reads 0, so the deterministic order puts C major first.
            #expect(estimate.tonic == "C" && estimate.mode == "major", "\(name)")
        }
    }
}
