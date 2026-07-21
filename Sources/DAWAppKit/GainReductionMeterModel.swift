import Foundation
import DAWCore

/// Pure scale/semantics behind the **gain-reduction meters** (m22-e phase 2):
/// the GAIN REDUCTION ladder in the compressor/limiter/gate editor cards and
/// the tiny activity bar on a dynamics insert chip. Everything the Canvases
/// draw or the readout prints is derived here so it's unit-tested without a
/// running app (the `StereoScopeModel` precedent) — the SwiftUI views stay
/// thin scalers over these functions.
///
/// Data source: `ProjectStore.effectGainReductionDb(trackID:effectID:)` /
/// `masterEffectGainReductionDb(effectID:)` (m22-e phase 1) — POSITIVE dB of
/// reduction, 0 = untouched, instant attack with a −20 dB/s held-peak release
/// already applied ENGINE-side (the views never re-smooth), capped at
/// `engineCapDb` (a fully closed gate reads exactly 80.0). **nil = the effect
/// doesn't report** (non-dynamics kinds, hosted AUs, headless/no engine) —
/// the chip shows NO bar and the card readout shows the honest "–" dash,
/// never a fabricated 0.
public enum GainReductionMeterModel {

    // MARK: - Which effects meter

    /// The built-in dynamics kinds that report gain reduction — the ONLY
    /// kinds that grow a meter (a reverb chip must never carry a dead bar,
    /// and hosted AUs don't report on the phase-1 tap).
    public static let dynamicsKinds: Set<EffectDescriptor.Kind> =
        [.compressor, .limiter, .gate]

    public static func isDynamicsKind(_ kind: EffectDescriptor.Kind) -> Bool {
        dynamicsKinds.contains(kind)
    }

    // MARK: - Scale (dB → bar fraction)

    /// The engine-side hard cap: a fully closed gate reads exactly 80.0 dB.
    public static let engineCapDb = 80.0

    /// The DISPLAY cap: the visible scale spans 0…24 dB and anything deeper
    /// pins the bar full. 24 dB is already "crushing it" for a compressor /
    /// limiter, and a gate's 80 dB slam must read as a pinned bar + the
    /// "CLOSED" verdict — never a scale 3× wider than the musical region.
    public static let displayCapDb = 24.0

    /// Saturation knee of the display map (dB). `fraction` is the normalized
    /// saturating curve `db/(db+knee)` — most of the travel goes to the
    /// musical 1…6 dB region (3 dB of compression reads at ~42% of the bar,
    /// not the 12.5% a linear 0…24 scale would give), while 12…24 dB
    /// compresses into the top — the "how hard is it working" shape.
    public static let kneeDb = 6.0

    /// Maps positive-dB gain reduction to a 0…1 bar fraction. Exact anchors
    /// (tested): 0 → 0, 3 → 5/12, 6 → 5/8, 12 → 5/6, 24 → 1; anything past
    /// the display cap (e.g. a closed gate's 80) clamps to 1. Non-finite or
    /// negative input reads as 0 (an honest empty bar, never garbage).
    public static func fraction(forDb db: Double) -> Double {
        guard db.isFinite, db > 0 else { return 0 }
        let capped = min(db, displayCapDb)
        let normalizer = displayCapDb / (displayCapDb + kneeDb)
        return (capped / (capped + kneeDb)) / normalizer
    }

    /// The scale marks the card ladder labels: 0 / 3 / 6 / 12 / 24 dB.
    /// Positions come from `fraction(forDb:)` — one mapping, so the ticks
    /// can never drift from the fill.
    public static let tickDbValues: [Double] = [0, 3, 6, 12, 24]

    // MARK: - Zones (how hard is it working)

    /// The ladder's zone semantics — green→amber→red POSITION zones (the
    /// `SegmentMeter` idiom: segments are colored by where they sit on the
    /// scale, lit up to the current value). For a compressor/limiter the
    /// upper zones are a teaching signal ("you're squashing it"); a GATE's
    /// whole job is deep attenuation, so its ladder stays uniformly
    /// signal-green — a closed gate is healthy, never an alarm.
    public enum Zone: Sendable, Equatable {
        /// ≤ 6 dB — gentle, healthy dynamics work (signal green).
        case light
        /// 6…12 dB — firm; deliberate heavy compression (record amber).
        case firm
        /// ≥ 12 dB — crushing (clip red) — on a compressor/limiter only.
        case heavy
    }

    /// Zone boundaries in dB — shared by the card ladder and the chip
    /// mini-bar so the two can never disagree.
    public static let firmDb = 6.0
    public static let heavyDb = 12.0

    /// The zone for a segment sitting at `fraction` of the bar (its upper
    /// edge, the `SegmentMeter` convention). Boundary rule: the strict side
    /// faces the problem (the m22-d `zone(forCorrelation:)` precedent) —
    /// exactly 6 dB is already firm, exactly 12 dB already heavy. A gate is
    /// ALWAYS `.light` (see `Zone`).
    public static func zone(atBarFraction f: Double,
                            kind: EffectDescriptor.Kind) -> Zone {
        guard kind != .gate else { return .light }
        if f >= fraction(forDb: heavyDb) { return .heavy }
        if f >= fraction(forDb: firmDb) { return .firm }
        return .light
    }

    // MARK: - "Closed" (gate) semantics

    /// A GATE reading within this tolerance of the 80 dB engine cap is
    /// CLOSED — fully shut, passing nothing. 0.05 dB under the −20 dB/s
    /// release means the verdict survives ~2.5 ms of reopening, so it flips
    /// honestly the moment the gate actually opens.
    public static let closedToleranceDb = 0.05

    /// True when a GATE's reading means "fully closed". Kind-gated: only the
    /// gate speaks "CLOSED" (a compressor pinned at cap still reads its
    /// number — crushing, not closing).
    public static func isClosed(db: Double, kind: EffectDescriptor.Kind) -> Bool {
        kind == .gate && db >= engineCapDb - closedToleranceDb
    }

    // MARK: - Readout (SF Mono digital voice)

    /// The card readout text. nil (not reporting: hosted AU, headless, no
    /// engine) reads as the honest "–" dash — the LOUDNESS warming
    /// precedent, never a fabricated 0. A closed gate reads the
    /// plain-language "CLOSED" (the app never breaks scale with "80.0");
    /// everything else is the true value to one decimal — past the 24 dB
    /// display cap the BAR pins but the NUMBER stays honest (e.g. "31.4").
    public static func readoutText(forDb db: Double?,
                                   kind: EffectDescriptor.Kind) -> String {
        guard let db, db.isFinite else { return "–" }
        if isClosed(db: db, kind: kind) { return "CLOSED" }
        return String(format: "%.1f", max(db, 0))
    }

    /// Whether the "dB" unit tag renders beside the readout — only when
    /// there is a number (never "– dB" or "CLOSED dB").
    public static func showsUnit(forDb db: Double?,
                                 kind: EffectDescriptor.Kind) -> Bool {
        guard let db, db.isFinite else { return false }
        return !isClosed(db: db, kind: kind)
    }
}

// MARK: - Debug seed (deterministic captures)

/// The `debug.grSeed` payload (the `debug.scopeSeed` precedent): a synthetic
/// gain-reduction reading the GR meters prefer over the live store polls, so
/// a headless capture / E2E shows a working meter deterministically.
/// View-side only — the engine is never touched by seeding. `effectID` nil =
/// a BLANKET seed (every dynamics meter shows `db`); non-nil targets one
/// insert (the others keep their live polls).
public struct GainReductionSeed: Sendable, Equatable {
    /// POSITIVE dB of reduction, already clamped to 0…`engineCapDb` by the
    /// debug command (mirroring the engine's own cap).
    public var db: Double
    /// nil = blanket; non-nil = only the matching insert reads the seed.
    public var effectID: UUID?

    public init(db: Double, effectID: UUID?) {
        self.db = db
        self.effectID = effectID
    }

    /// The seeded reading for one insert — nil when this seed doesn't apply
    /// (a targeted seed for a different effect), letting the caller fall
    /// through to the live poll: `seed?.value(forEffect: id) ?? live()`.
    public func value(forEffect id: UUID) -> Double? {
        (effectID == nil || effectID == id) ? db : nil
    }
}
