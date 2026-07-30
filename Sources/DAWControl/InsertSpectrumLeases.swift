import DAWCore
import Foundation

/// The control-plane TTL lease behind `fx.spectrum` (m23-r4, design D2,
/// design-m23r4-fx-spectrum-lease.md §3). Lives HERE, and ONLY here —
/// DAWCore, DAWEngine and the app UI never see it, and it never appears on
/// `ProjectStore`. Held one-per-router by `CommandRouter` (the
/// `transcriber`/`installCoordinator` slot pattern), so "arm, then poll"
/// sees the same lease state across calls.
///
/// **Swept lazily, at the top of `fx.spectrum` and NOWHERE ELSE.** The
/// purpose of the sweep is to keep the store's cap refusal honest, and the
/// 9th arm is ITSELF an `fx.spectrum` call, so a sweep local to that one
/// command always runs exactly when it matters. Sweeping in
/// `CommandRouter.handle` would only buy "reaps sooner during unrelated
/// work" at the cost of a diff through the path all 162 commands flow —
/// not worth it on a strictly-additive item. Residual, stated plainly: a
/// lease CAN outlive its TTL while no `fx.spectrum` arrives; it is bounded
/// by the engine's N=8 tap cap (costs two `memcpy`s per render block plus
/// ~230 KB per leaked tap), and the next `fx.spectrum` of any kind reaps it.
@MainActor
public final class InsertSpectrumLeases {
    /// The full TTL a successful `arm:true` grants (and every subsequent
    /// `arm:true` on the same target renews it back up to). Pinned against
    /// this LITERAL by its own gate leg (L6), separate from every
    /// behavioural leg — those all drive the injected clock, so a 3 s →
    /// 300 s mutation would pass every one of them without this pin.
    static let defaultTTL: Duration = .seconds(3)

    /// `defaultTTL` expressed as the `Double` seconds the wire's
    /// `leaseSeconds` field carries — derived from the one `Duration`
    /// literal above, never a second hardcoded "3".
    static var defaultTTLSeconds: Double {
        let components = defaultTTL.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Injectable monotonic now-provider — production default: the real
    /// continuous clock. NEVER `Date()`: it is non-monotonic across NTP
    /// steps, and a `Date()`-based lease would force a real 3-second sleep
    /// into the gate. Tests construct their own `InsertSpectrumLeases` with
    /// a fake clock and drive it directly.
    private let now: () -> ContinuousClock.Instant
    private var deadlines: [InsertAnalysisTarget: ContinuousClock.Instant] = [:]

    public init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// Arms (or renews) `target`'s lease for a fresh `defaultTTL` from now.
    func renew(_ target: InsertAnalysisTarget) {
        deadlines[target] = now() + Self.defaultTTL
    }

    /// Drops `target`'s lease outright — the `arm:false` path, which needs
    /// no TTL bookkeeping at all (the release is immediate and explicit).
    func release(_ target: InsertAnalysisTarget) {
        deadlines.removeValue(forKey: target)
    }

    /// True while `target` currently holds an unexpired lease. Exposed for
    /// tests/gates; `fx.spectrum` itself never needs to ask (the sweep plus
    /// the store's own owner set are the only load-bearing state).
    func isHeld(_ target: InsertAnalysisTarget) -> Bool {
        guard let deadline = deadlines[target] else { return false }
        return now() < deadline
    }

    /// Sweeps every EXPIRED lease: for each, calls `release(target)` (the
    /// caller's job — normally releasing the `.control` owner on
    /// `ProjectStore`) and then drops the deadline here. Returns the swept
    /// targets, for tests. Called ONLY at the top of `fx.spectrum` (D2) —
    /// see this type's doc comment for why nowhere else.
    @discardableResult
    func sweep(release: (InsertAnalysisTarget) -> Void) -> [InsertAnalysisTarget] {
        let current = now()
        let expired = deadlines.filter { current >= $0.value }.map(\.key)
        for target in expired {
            deadlines.removeValue(forKey: target)
            release(target)
        }
        return expired
    }
}
