import Foundation

/// The armed-insert addressing key for the per-insert spectrum tap (m23-r2a),
/// promoted out of `DAWEngine`'s file-private `InsertAnalysisKey` at m23-r4
/// (design-m23r4-fx-spectrum-lease.md §7 S1) so `ProjectStore`'s named-owner
/// bookkeeping (`InsertAnalysisOwner`, below) and `DAWControl`'s TTL lease
/// share ONE key type with the engine instead of each re-deriving an
/// equivalent one. `DAWEngine.InsertAnalysisKey` is now a `typealias` for
/// this type — same memberwise shape, so every existing engine-side call
/// site keeps compiling unchanged. `trackID == nil` addresses the MASTER
/// insert chain (the m22-e track/master split, expressed as one nullable id
/// instead of two parallel surfaces).
public struct InsertAnalysisTarget: Hashable, Sendable {
    public let trackID: UUID?
    public let effectID: UUID

    public init(trackID: UUID?, effectID: UUID) {
        self.trackID = trackID
        self.effectID = effectID
    }
}

/// WHO holds a control-plane arm on one `InsertAnalysisTarget` (m23-r4,
/// design D1): the in-app EQ card (`.ui`) and the wire's `fx.spectrum` TTL
/// lease (`.control`). `ProjectStore` keeps a `Set<InsertAnalysisOwner>` per
/// target rather than a numeric refcount because both parties re-arm
/// IDEMPOTENTLY under normal use — the UI on every card retarget, the wire
/// on every poll — and a plain count underflows or leaks under exactly that
/// call pattern. The owner set gates DISARM ONLY (releasing one owner never
/// touches the other's hold); the engine's own N-tap cap is untouched and
/// stays the sole cap authority. A closed enum: adding a third owner is a
/// compiler-visible event, never a silently-forgotten release path.
public enum InsertAnalysisOwner: Hashable, Sendable {
    case ui
    case control
}

/// Outcome of `ProjectStore.setInsertAnalysisArmed` (m23-r4, design D7) — an
/// enum instead of a bare `Bool` so a cap refusal can NAME the cap, and a
/// model-lookup failure (`trackNotFound`/`effectNotFound`) is distinguishable
/// from the engine's own refusal (a full tap cap) or a headless/incapable
/// engine. Never conflate `.armed` and `.released`: a `switch` accepts a
/// mixed-up case silently, and this whole item exists because of a silent
/// lie in this same API's prior `Bool` contract ("disarming always reports
/// true").
public enum InsertArmOutcome: Equatable, Sendable {
    /// `armed: true` succeeded — freshly armed, or the owner already held it
    /// (idempotent, the `masterAnalysis()`-forwarder-shape precedent).
    case armed
    /// `armed: false` succeeded. A target this owner never held is a BENIGN
    /// success too (mirrors the engine's own "disarming always reports
    /// true"), never an error.
    case released
    case trackNotFound(UUID)
    case effectNotFound(UUID)
    /// The engine's own N-tap cap (`AudioEngineControlling.maxArmedInsertAnalysis`)
    /// is full. Names the cap so the wire's teaching error can too.
    case refusedCapFull(cap: Int)
    /// An engine is present but cannot tap inserts AT ALL
    /// (`maxArmedInsertAnalysis == 0`) — kept distinct from
    /// `.refusedCapFull(cap: 0)` on purpose, so a "not built for this"
    /// engine can never be reported as a temporarily-full one.
    case unsupported
    /// No engine at all (headless control session).
    case unavailableHeadless
}
