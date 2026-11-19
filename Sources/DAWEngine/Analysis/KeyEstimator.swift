import DAWCore
import Foundation

/// Krumhansl-Schmuckler key estimation over a 12-bin chroma vector (m21-e,
/// design-clip-analyze-audio §3a). The chroma itself is accumulated by
/// `AudioContentAnalyzer`'s STFT pass; this type hands it to the ONE home of
/// the key math.
///
/// ⭐ **THE MATH LIVES IN DAWCore NOW (p2-sing-x4):** the profiles, the
/// Pearson ranking, the flatness and the honesty gates moved VERBATIM to
/// `KeyProfileMatch` (`Sources/DAWCore/KeyProfileMatch.swift`), so the harmony
/// planner can reach them; this forwards. The audio path's `KeyEstimate`s are
/// pinned byte-identical across the move (`KeyEstimatorLiftPinTests`). A
/// tuning change there still bumps `AudioContentAnalyzer.analyzerVersion`.
///
/// REAL-TIME SAFETY: never referenced from the render path — offline analysis
/// only, inside the cache's detached task.
enum KeyEstimator {

    /// Ranks all 24 keys against the chroma and applies the confidence /
    /// tonal gates (`KeyProfileMatch.estimate(chroma:)`).
    static func estimate(chroma: [Double]) -> KeyEstimate {
        KeyProfileMatch.estimate(chroma: chroma)
    }
}
