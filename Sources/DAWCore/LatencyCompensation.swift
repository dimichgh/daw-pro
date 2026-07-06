import Foundation

// M4 (viii-a) — PDC plan math. Pure, headless, deterministic latency-
// compensation planner per the settled spec (docs/ARCHITECTURE.md "Latency
// compensation (PDC): SETTLED"). The engine (viii-c) maps strip state into
// `PDCInput`, calls `PDCPlan.compute`, and publishes each strip's
// `compensationSamples` as an atomic ring target. No UI, no engine imports.
//
// Alignment rule — staged global-max:
//   T = max over track strips of chainLatencyAll  (track-stage target)
//   B = max over bus strips of chainLatencyAll    (bus-stage target)
//   maxPathLatency = T + B
// Stage maxima use the ALL-effects sums so they are bypass-stable: toggling
// bypass never moves T/B (only effect removal/addition does). Compensation
// subtracts the ACTIVE sum, because bypassed effects add no real delay — the
// strip's own ring absorbs the difference, keeping end-to-end time constant.
//
// The master strip is common-path (delays everything equally) and must NOT be
// passed as an input strip; it is excluded from alignment math by contract.

/// Identifies what a strip is and, for tracks, how it feeds the mix.
/// Buses always output to master and their sends (none exist in the two-level
/// topology) are irrelevant to the plan, so `bus` carries no routing state.
public enum PDCStripKind: Sendable, Hashable {
    /// A track strip. `outputsToMaster` is true when the track's routed
    /// output goes directly to master (no intermediate bus); `hasSends` is
    /// true when the track has at least one send (pre- or post-fader — both
    /// tap downstream of the chain, so they are identical for latency).
    case track(outputsToMaster: Bool, hasSends: Bool)
    /// A bus strip (routes to master; receives track outputs and sends).
    case bus
}

/// Per-strip planner input. Latencies are in samples at the current engine
/// rate. `chainLatencyAll` sums ALL effects in the chain including bypassed
/// ones (the stable, reported total); `chainLatencyActive` sums non-bypassed
/// effects only (the chain's actual signal delay). Invariant:
/// `0 ≤ chainLatencyActive ≤ chainLatencyAll`. Negative values are programmer
/// error; the planner clamps them to 0 (documented policy — clamp, not
/// precondition, so a hostile hosted AU reporting garbage can never crash the
/// main actor).
public struct PDCStripInput: Sendable, Hashable {
    public let id: UUID
    public let kind: PDCStripKind
    public let chainLatencyAll: Int
    public let chainLatencyActive: Int

    public init(id: UUID, kind: PDCStripKind, chainLatencyAll: Int, chainLatencyActive: Int) {
        self.id = id
        self.kind = kind
        self.chainLatencyAll = chainLatencyAll
        self.chainLatencyActive = chainLatencyActive
    }
}

/// The full planner input: every track and bus strip in the project.
/// The master strip is deliberately absent (common-path, see header note).
public struct PDCInput: Sendable, Hashable {
    public let strips: [PDCStripInput]

    public init(strips: [PDCStripInput]) {
        self.strips = strips
    }
}

/// Per-strip plan result.
public struct PDCStripPlan: Sendable, Hashable {
    public let id: UUID
    /// The unclamped planned compensation in samples (stage target minus the
    /// strip's active chain latency, floored at 0).
    public let plannedSamples: Int
    /// The applied ring target: `min(plannedSamples, cap)`. This is what the
    /// engine publishes to the strip's compensation ring.
    public let compensationSamples: Int
    /// True when `plannedSamples` exceeded the cap. The uncompensated
    /// residual is `residualSamples`.
    public let clamped: Bool
    /// Documented v0 skew: nonzero (= B) only for a direct-to-master track
    /// WITH sends while some bus has fixed chain latency (`B > 0`) — its dry
    /// feed arrives `skewSamples` early relative to bus returns. One delay
    /// per strip cannot satisfy both constraints; reported, not hidden.
    public let skewSamples: Int

    /// Uncompensated residual when clamped: `plannedSamples − compensationSamples`.
    public var residualSamples: Int { plannedSamples - compensationSamples }
}

/// The computed compensation plan. Pure value; recomputed on the main actor
/// whenever any latency, bypass, routing, or rate event can move a number.
public struct PDCPlan: Sendable, Hashable {
    /// Ring cap from the settled spec: 16 384 samples (~341 ms @ 48 kHz).
    public static let compensationCap = 16_384

    /// `T` — max over track strips of `chainLatencyAll` (0 with no tracks).
    public let trackStage: Int
    /// `B` — max over bus strips of `chainLatencyAll` (0 with no buses).
    public let busStage: Int
    /// `T + B` — the reported global path latency.
    public let maxPathLatency: Int
    /// Per-strip results in input order (deterministic).
    public let strips: [PDCStripPlan]

    private let indexByID: [UUID: Int]

    /// Result for a given strip, or nil if the strip was not an input.
    public subscript(id: UUID) -> PDCStripPlan? {
        indexByID[id].map { strips[$0] }
    }

    /// Computes the compensation plan for the given strips.
    ///
    /// - Parameters:
    ///   - input: every track and bus strip (NOT the master strip).
    ///   - cap: maximum compensation the ring can apply, in samples.
    ///     Plans above it are clamped with `clamped = true` and the residual
    ///     exposed via `plannedSamples` / `residualSamples`.
    /// - Returns: the deterministic plan. Empty input yields the all-zero plan.
    public static func compute(input: PDCInput, cap: Int = PDCPlan.compensationCap) -> PDCPlan {
        let cap = max(0, cap)

        // Stage maxima over the ALL-effects sums (bypass-stable).
        var trackStage = 0
        var busStage = 0
        for strip in input.strips {
            let all = max(0, strip.chainLatencyAll)
            switch strip.kind {
            case .track: trackStage = max(trackStage, all)
            case .bus: busStage = max(busStage, all)
            }
        }
        let maxPath = trackStage + busStage

        var plans: [PDCStripPlan] = []
        plans.reserveCapacity(input.strips.count)
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(input.strips.count)

        for strip in input.strips {
            let active = max(0, strip.chainLatencyActive)

            let stageTarget: Int
            let skew: Int
            switch strip.kind {
            case .track(let outputsToMaster, let hasSends):
                if hasSends {
                    // Send taps must enter buses at uniform time T, so the
                    // track pads to T regardless of its routed output.
                    stageTarget = trackStage
                    // The one impossible case: dry feed goes straight to
                    // master (arrives at T) while bus returns arrive at T+B.
                    skew = (outputsToMaster && busStage > 0) ? busStage : 0
                } else if outputsToMaster {
                    // Free refinement: no bus-input constraint, so align the
                    // dry feed exactly with bus outputs at master.
                    stageTarget = maxPath
                    skew = 0
                } else {
                    // Routed into a bus: pad to T; the bus stage adds B.
                    stageTarget = trackStage
                    skew = 0
                }
            case .bus:
                stageTarget = busStage
                skew = 0
            }

            // Active sum can only exceed the stage target if the caller broke
            // the active ≤ all invariant; floor at 0 (same clamp policy).
            let planned = max(0, stageTarget - active)
            let applied = min(planned, cap)
            plans.append(PDCStripPlan(
                id: strip.id,
                plannedSamples: planned,
                compensationSamples: applied,
                clamped: planned > cap,
                skewSamples: skew
            ))
            indexByID[strip.id] = plans.count - 1
        }

        return PDCPlan(
            trackStage: trackStage,
            busStage: busStage,
            maxPathLatency: maxPath,
            strips: plans,
            indexByID: indexByID
        )
    }

    private init(trackStage: Int, busStage: Int, maxPathLatency: Int, strips: [PDCStripPlan], indexByID: [UUID: Int]) {
        self.trackStage = trackStage
        self.busStage = busStage
        self.maxPathLatency = maxPathLatency
        self.strips = strips
        self.indexByID = indexByID
    }
}

/// Snapshot-facing PDC report (spec §6) — the engine publishes one after every
/// recompute; ProjectStore forwards it so DAWControl can attach the additive
/// wire fields while staying engine-free (the `effectLatencySamples`
/// precedent). All values are samples at the current engine rate.
public struct PDCReport: Sendable, Equatable {
    /// Per-strip reporting: the stable all-effects chain total plus the
    /// applied ring target and its honesty flags.
    public struct Strip: Sendable, Equatable {
        /// All-effects chain latency INCLUDING bypassed effects (stable under
        /// bypass — the number `T`/`B` are built from).
        public let chainLatencySamples: Int
        /// The applied (possibly clamped) compensation ring target.
        public let compensationSamples: Int
        /// True when the plan exceeded the ring cap (16 384 samples).
        public let clamped: Bool
        /// The documented v0 skew (nonzero only for a direct-to-master track
        /// with sends while some bus carries fixed latency).
        public let skewSamples: Int

        public init(chainLatencySamples: Int, compensationSamples: Int,
                    clamped: Bool, skewSamples: Int) {
            self.chainLatencySamples = chainLatencySamples
            self.compensationSamples = compensationSamples
            self.clamped = clamped
            self.skewSamples = skewSamples
        }
    }

    /// `T` — max all-effects latency over track strips.
    public let trackStageSamples: Int
    /// `B` — max all-effects latency over bus strips.
    public let busStageSamples: Int
    /// `T + B` — the global path latency every strip is padded toward.
    public let maxPathLatencySamples: Int
    /// Ruler-to-speaker figure for output-delayed mode: `T + B` plus the
    /// master strip's own (common-path, uncompensated) chain latency. The
    /// master strip carries no chain today, so this equals `maxPathLatency`;
    /// the term is kept separate so a future master chain adds in here.
    public let outputLatencySamples: Int
    /// Per-strip reports keyed by track/bus id.
    public let strips: [UUID: Strip]

    public init(trackStageSamples: Int, busStageSamples: Int,
                masterChainLatencySamples: Int = 0, strips: [UUID: Strip]) {
        self.trackStageSamples = trackStageSamples
        self.busStageSamples = busStageSamples
        self.maxPathLatencySamples = trackStageSamples + busStageSamples
        self.outputLatencySamples =
            trackStageSamples + busStageSamples + masterChainLatencySamples
        self.strips = strips
    }
}
