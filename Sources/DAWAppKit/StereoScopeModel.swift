import Foundation
import DAWCore

/// Pure geometry + semantics behind the master strip's **stereo-image block**
/// (m22-d): the goniometer/vectorscope trail, the mono-safety (correlation)
/// bar, and the width/balance readouts. Everything the Canvas draws or the
/// readout rows print is derived here so it's unit-tested without a running
/// app (the `EQCurveEditorModel` / `VibeMeterModel` precedent) — the SwiftUI
/// views stay thin scalers over these functions.
///
/// Data source: `ProjectStore.masterScopeFrame()` (256 decimated L/R pairs,
/// oldest → newest, finite by contract) + the m22-d stereo scalars on
/// `MasterAnalysisSnapshot` (`correlation` floor +1, `width` floor 0,
/// `balance` floor 0 — τ 300 ms ballistics, so no view-side smoothing).
///
/// **Display convention** (deliberate, tested): the rotation itself is the
/// classic mid/side pair — `x = (L−R)·s`, `y = (L+R)·s`, `s = 1/√2` — but the
/// screen mapping MIRRORS x so a hard-LEFT signal rides the up-LEFT diagonal
/// (the hardware-goniometer convention, and the direction the balance readout
/// and pan knob already speak: left = left). Mono → a vertical line,
/// anti-phase → a horizontal line, hard-pan → one 45° diagonal, wide stereo →
/// a cloud. Full-scale hard-pan lands exactly on the unit circle; louder-than-
/// that mono content clamps to the square edge (scopes clip, honestly).
public enum StereoScopeModel {

    // MARK: - Rotation (the classic 45° Lissajous)

    /// `s = 1/√2` — normalizes the 45° rotation so a full-scale single
    /// channel (L=1, R=0) lands at unit distance along its diagonal.
    public static let rotationScale = 1.0 / 2.0.squareRoot()

    /// The raw rotated pair: `x = (L−R)·s` (the SIDE coordinate), `y =
    /// (L+R)·s` (the MID coordinate, positive up). Unclamped, exact — the
    /// tested rotation contract. `l == r` → x exactly 0 (mono = vertical);
    /// `r == −l` → y exactly 0 (anti-phase = horizontal).
    public static func rotated(left: Double, right: Double) -> (x: Double, y: Double) {
        ((left - right) * rotationScale, (left + right) * rotationScale)
    }

    /// One sample pair mapped into the UNIT scope square — (0,0) top-left,
    /// y down, ready for scaling into any square rect. x is MIRRORED (see the
    /// type comment: hard-L reads up-LEFT, matching balance/pan direction);
    /// +mid maps up. Out-of-range energy clamps to the square edge.
    public static func displayPoint(left: Double, right: Double) -> CGPoint {
        let r = rotated(left: left, right: right)
        let ux = 0.5 - r.x * 0.5
        let uy = 0.5 - r.y * 0.5
        return CGPoint(x: min(max(ux, 0), 1), y: min(max(uy, 0), 1))
    }

    /// The whole frame as unit-square display points, oldest → newest (index
    /// order preserved so `trailTier` fade indexing lines up). An `.empty`
    /// frame maps to 256 center points — the calm dot, never garbage.
    public static func displayPoints(_ frame: MasterScopeFrame) -> [CGPoint] {
        let n = min(frame.left.count, frame.right.count)
        var points = [CGPoint]()
        points.reserveCapacity(n)
        for i in 0..<n {
            points.append(displayPoint(left: Double(frame.left[i]),
                                       right: Double(frame.right[i])))
        }
        return points
    }

    /// The largest centered square inside an arbitrary canvas size — the
    /// scope well. Shared by the static grid canvas and the trail canvas so
    /// the two layers can never drift apart.
    public static func squareRect(in size: CGSize) -> CGRect {
        let side = min(size.width, size.height)
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                      width: side, height: side)
    }

    // MARK: - Trail fade (older pairs dimmer)

    /// Opacity buckets for the trail: 256 segments would mean 256 strokes per
    /// frame, so segments bucket into 8 tiers (oldest dimmest) and each tier
    /// strokes as ONE path — bounded per-frame work at any pair count.
    public static let trailTierCount = 8

    /// Which fade tier a pair at `index` (0 = oldest) of `count` belongs to.
    /// Monotone non-decreasing in `index`; the newest pair is always in the
    /// brightest tier, the oldest in the dimmest.
    public static func trailTier(index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let clamped = min(max(index, 0), count - 1)
        return min(trailTierCount - 1, clamped * trailTierCount / count)
    }

    /// Stroke opacity for a fade tier: 0.08 (oldest, a ghost) → 0.85 (newest,
    /// the hot head of the trail). Strictly increasing across tiers.
    public static func tierOpacity(_ tier: Int) -> Double {
        let t = Double(min(max(tier, 0), trailTierCount - 1))
            / Double(trailTierCount - 1)
        return 0.08 + t * 0.77
    }

    // MARK: - Calm (silence) state

    /// Absolute-sample floor below which the scope reads CALM: ≈ −60 dBFS.
    /// Comfortably above the analyzer's −80 dB dead-snap, so a stopped or
    /// silent session always lands calm; anything audible draws a trail.
    public static let calmFloor: Float = 0.001

    /// True when every pair in the frame is below the calm floor — the view
    /// then draws a single dim center dot in the empty well (silence must
    /// read as calm, never as garbage or a black hole).
    public static func isCalm(_ frame: MasterScopeFrame) -> Bool {
        frame.left.allSatisfy { abs($0) < calmFloor }
            && frame.right.allSatisfy { abs($0) < calmFloor }
    }

    // MARK: - Mono-safety (correlation) semantics

    /// The beginner-readable verdict behind the correlation value — ONE
    /// meaning shared by the bar, the zone word, and the trail tint (green =
    /// mono-safe, amber = caution, red = cancels in mono). Labels live here
    /// so the wording is pinned by tests (never a bare "CORR").
    public enum CorrelationZone: String, CaseIterable, Sendable, Equatable {
        case inPhase, wide, antiPhase

        /// The plain-language verdict word the block shows (Rule 6 voice).
        public var label: String {
            switch self {
            case .inPhase: return "IN PHASE"
            case .wide: return "VERY WIDE"
            case .antiPhase: return "OUT OF PHASE"
            }
        }
    }

    /// Zone boundary: |correlation| below this is the amber "very wide"
    /// caution band. ±0.2 — real stereo mixes live comfortably above +0.2;
    /// hovering near 0 means heavily decorrelated content (worth a mono
    /// check), and negative means actual cancellation.
    public static let wideThreshold = 0.2

    /// Correlation → verdict zone. Exactly +0.2 is still healthy; exactly
    /// −0.2 is already the warning (the strict side faces the problem).
    public static func zone(forCorrelation c: Double) -> CorrelationZone {
        if c >= wideThreshold { return .inPhase }
        if c > -wideThreshold { return .wide }
        return .antiPhase
    }

    /// Marker position 0…1 along the −1…+1 mono-safety bar (clamped).
    public static func barPosition(correlation: Double) -> Double {
        min(max((correlation + 1) / 2, 0), 1)
    }

    // MARK: - Readout formatting (SF Mono digital voice)

    /// Correlation as a signed two-decimal readout: "+0.98", "-0.31"; zero
    /// folds unsigned to "0.00" (the `MixerFormat.dbString` −0.0 rule).
    public static func correlationText(_ c: Double) -> String {
        let rounded = (c * 100).rounded() / 100
        if rounded == 0 { return "0.00" }
        return String(format: "%+.2f", rounded)
    }

    /// Width 0…1 as a percentage — the DESIGN-LANGUAGE rule for 0…1 linear
    /// amount readouts ("42%", never a bare fraction).
    public static func widthText(_ w: Double) -> String {
        "\(Int((min(max(w, 0), 1) * 100).rounded()))%"
    }

    /// Balance −1…+1 in the pan knob's exact voice ("C", "L100", "R50") —
    /// same direction, same formatter, so the two readouts can never disagree.
    public static func balanceText(_ b: Double) -> String {
        MixerFormat.panString(min(max(b, -1), 1))
    }
}

// MARK: - Debug seed (deterministic captures)

/// The `debug.scopeSeed` payload (the `debug.vibeSeed` precedent): a synthetic
/// scope frame plus the three stereo scalars, preferred by the stereo-image
/// block over the live polls so headless captures show deterministic figures.
/// View-side only — the engine is never touched by seeding.
public struct StereoScopeSeed: Sendable, Equatable {
    public var frame: MasterScopeFrame
    public var correlation: Float
    public var width: Float
    public var balance: Float

    public init(frame: MasterScopeFrame, correlation: Float, width: Float, balance: Float) {
        self.frame = frame
        self.correlation = correlation
        self.width = width
        self.balance = balance
    }
}

/// Named deterministic figures for `debug.scopeSeed {preset}` — pure sine
/// constructions (no randomness), so a capture of "mono" or "antiPhase" is
/// bit-identical every run. Scalar defaults match the m22-d analyzer laws
/// (hard-pan: correlation +1 — a dead channel loses nothing to mono summing —
/// width 0.5, balance ±1).
public enum StereoScopePreset: String, CaseIterable, Sendable {
    /// The calm state: an all-zero frame + the exact idle floors.
    case silence
    /// L == R sine — the vertical line, correlation +1.
    case mono
    /// R == −L sine — the horizontal line, correlation −1 (cancels in mono).
    case antiPhase
    /// Two incommensurate sines — the decorrelated Lissajous cloud, corr ≈ 0.
    case cloud
    /// Left-only sine — the up-left 45° diagonal, balance −1.
    case hardLeft
    /// Right-only sine — the up-right 45° diagonal, balance +1.
    case hardRight

    /// The full deterministic seed for this figure.
    public func seed() -> StereoScopeSeed {
        let n = MasterScopeFrame.pairCount
        func sine(cycles: Double, amp: Double, phase: Double = 0) -> [Float] {
            (0..<n).map {
                Float(amp * sin(2 * .pi * cycles * Double($0) / Double(n) + phase))
            }
        }
        let zeros = [Float](repeating: 0, count: n)
        switch self {
        case .silence:
            return StereoScopeSeed(frame: .empty, correlation: 1, width: 0, balance: 0)
        case .mono:
            let s = sine(cycles: 3, amp: 0.8)
            return StereoScopeSeed(frame: MasterScopeFrame(left: s, right: s),
                                   correlation: 1, width: 0, balance: 0)
        case .antiPhase:
            let s = sine(cycles: 3, amp: 0.8)
            return StereoScopeSeed(frame: MasterScopeFrame(left: s, right: s.map { -$0 }),
                                   correlation: -1, width: 1, balance: 0)
        case .cloud:
            return StereoScopeSeed(frame: MasterScopeFrame(left: sine(cycles: 3.7, amp: 0.7),
                                                           right: sine(cycles: 9.1, amp: 0.7, phase: 1.3)),
                                   correlation: 0, width: 0.5, balance: 0)
        case .hardLeft:
            return StereoScopeSeed(frame: MasterScopeFrame(left: sine(cycles: 3, amp: 0.8), right: zeros),
                                   correlation: 1, width: 0.5, balance: -1)
        case .hardRight:
            return StereoScopeSeed(frame: MasterScopeFrame(left: zeros, right: sine(cycles: 3, amp: 0.8)),
                                   correlation: 1, width: 0.5, balance: 1)
        }
    }
}
