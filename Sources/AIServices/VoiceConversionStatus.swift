import Foundation

/// Wire/model type for `vc.sidecarStatus` / `vc.sidecarStart` / `vc.sidecarStop`
/// (m10-p-3) — the control protocol and MCP both thread this Codable onto the
/// wire verbatim, exactly the `SidecarStatus` "wire never drifts" convention
/// this type intentionally mirrors.
///
/// TWIN, NOT REUSE, of `SidecarStatus` (disclosed choice): `SidecarState`
/// itself (`notInstalled`/`installedNotRunning`/`starting`/`healthy`/`error`)
/// and `SidecarError`/`SidecarLaunchPlan` ARE reused as-is below and by
/// `VoiceConversionManager` — those three are genuinely engine-agnostic. But
/// `SidecarStatus`'s own health-payload fields (`ditModel`, `lmModel`) are
/// ACE-Step-specific names for ACE's DiT/LM checkpoints; the RVC facade's
/// `GET /health` (`scripts/rvc/server.py`) reports a completely different
/// shape (`engine`, `baseModelPresent`, `voiceCount`) that the GATE for this
/// item explicitly requires on the wire (`voiceCount` after a healthy start).
/// Reusing `SidecarStatus` as-is would mean either permanently-nil
/// `ditModel`/`lmModel` fields (silently wrong for a voice-conversion
/// sidecar) or overloading those names to mean something else (worse) — so
/// this dedicated twin exists instead, keeping every other field
/// (`state`/`message`/`version`/`pid`/`phase`/`startingForSeconds`) identical
/// in name and meaning to `SidecarStatus`.
public struct VoiceConversionStatus: Codable, Sendable, Equatable {
    public var state: SidecarState
    /// Always present, human-readable, and actionable — e.g. what command to
    /// run next — never a bare "false"/error code. Mirrors `SidecarStatus`.
    public var message: String
    /// Only populated when `state == .healthy` (from the facade's own
    /// `GET /health` `{"data": {...}}` envelope): the facade's own version
    /// string (`FACADE_VERSION` in `server.py`, e.g. "0.1.0" — NOT the
    /// underlying RVC-MLX engine's version).
    public var version: String?
    /// Only populated when healthy: the underlying voice-conversion engine
    /// identity (`"Acelogic/Retrieval-based-Voice-Conversion-MLX"` per the
    /// facade's pinned fork — see `scripts/rvc/README.md`).
    public var engine: String?
    /// Only populated when healthy: whether the untrained "base" smoke-target
    /// model (`base_f0G40k.npz`, derived by `install.sh`) is present on disk.
    /// `false` here means even the `voiceId: "base"` smoke conversion will
    /// fail with the facade's own `baseModelMissing` error.
    public var baseModelPresent: Bool?
    /// Only populated when healthy: count of REAL user-trained voices in the
    /// voice store (`runtime/voices/`) — always 0 until training ships
    /// (m10-p-5/p-6). Never counts the reserved "base" smoke target.
    public var voiceCount: Int?
    /// Process id of the spawned sidecar, when known. Mirrors `SidecarStatus`
    /// — see `VoiceConversionManager`'s doc comment for the ONE deviation
    /// this field's SOURCE has vs. ACE: `scripts/rvc/run.sh` itself writes
    /// `.rvc.pid` (not `VoiceConversionManager`), so this is read back from
    /// that file / the in-memory spawned `Process`, never written by us.
    public var pid: Int32?
    /// Only populated when `state == .starting`. UNLIKE `SidecarStatus.phase`,
    /// this is ALWAYS nil for v1 — no `SidecarStartPhase`-equivalent
    /// classifier exists for the RVC facade. Disclosed choice: `server.py`'s
    /// own doc comment says engines are "lazy-loaded (keeps boot/health
    /// fast)" — unlike ACE-Step's multi-minute DiT/LM cold load, the RVC
    /// facade's `/health` should answer almost as soon as uvicorn is up, so a
    /// phase hint classified from log text would be low-value guesswork built
    /// on zero observed real boots. If a future real-model gate measures a
    /// meaningfully slow boot, add a `VoiceConversionStartPhase` mirroring
    /// `SidecarStartPhase`'s pattern then — this field stays in the shape now
    /// so that addition would be wire-additive, not a breaking change.
    public var phase: String?
    /// Only populated when `state == .starting`: whole seconds since this
    /// boot attempt began. Mirrors `SidecarStatus.startingForSeconds`
    /// exactly, including the M10-b "tracked across the whole boot" behavior.
    public var startingForSeconds: Int?

    public init(
        state: SidecarState,
        message: String,
        version: String? = nil,
        engine: String? = nil,
        baseModelPresent: Bool? = nil,
        voiceCount: Int? = nil,
        pid: Int32? = nil,
        phase: String? = nil,
        startingForSeconds: Int? = nil
    ) {
        self.state = state
        self.message = message
        self.version = version
        self.engine = engine
        self.baseModelPresent = baseModelPresent
        self.voiceCount = voiceCount
        self.pid = pid
        self.phase = phase
        self.startingForSeconds = startingForSeconds
    }
}

/// Capability protocol so `CommandRouter` (DAWControl) can depend on an
/// abstraction and tests can inject a fake/stub without touching the real
/// process-spawning `VoiceConversionManager` — the `SidecarManaging` twin for
/// the RVC voice-conversion sidecar.
public protocol VoiceConversionManaging: Sendable {
    func status() async -> VoiceConversionStatus
    @discardableResult
    func start() async throws -> VoiceConversionStatus
    @discardableResult
    func stop() async throws -> VoiceConversionStatus
}
