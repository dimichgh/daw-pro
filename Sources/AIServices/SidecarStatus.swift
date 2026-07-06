import Foundation

/// Lifecycle states of the local ACE-Step-1.5 song-generation sidecar (M6 i).
/// `installedNotRunning` and `notInstalled` are distinguished so a client can
/// tell "needs `ai.sidecarStart`" apart from "needs `scripts/ace-step/install.sh`
/// first" without guessing from a bare connection failure.
public enum SidecarState: String, Codable, Sendable, Equatable {
    case notInstalled
    case installedNotRunning
    case starting
    case healthy
    case error
}

/// Wire/model type for `ai.sidecarStatus` / `ai.sidecarStart` / `ai.sidecarStop`
/// — the control protocol and MCP both thread this Codable onto the wire
/// verbatim (house "wire never drifts" convention), so it lives here in
/// AIServices rather than being hand-duplicated at each call site.
public struct SidecarStatus: Codable, Sendable, Equatable {
    public var state: SidecarState
    /// Always present, human-readable, and actionable — e.g. what command to
    /// run next — never a bare "false"/error code.
    public var message: String
    /// Only populated when `state == .healthy` (from the sidecar's own
    /// `GET /health`): the ACE-Step API version and the DiT/LM checkpoints it
    /// currently has loaded.
    public var version: String?
    public var ditModel: String?
    public var lmModel: String?
    /// Process id of the spawned sidecar, when known (set by `start()`/
    /// tracked via the pidfile; nil when not running or unknown).
    public var pid: Int32?

    public init(
        state: SidecarState,
        message: String,
        version: String? = nil,
        ditModel: String? = nil,
        lmModel: String? = nil,
        pid: Int32? = nil
    ) {
        self.state = state
        self.message = message
        self.version = version
        self.ditModel = ditModel
        self.lmModel = lmModel
        self.pid = pid
    }
}

/// What `SidecarManager.resolveLaunchPlan()` would spawn — surfaced so
/// `start()` can run in a dry-run mode that never actually launches a
/// process (headless test seam) while still exercising the real
/// path-resolution logic.
public struct SidecarLaunchPlan: Sendable, Equatable {
    public var executableURL: URL
    public var arguments: [String]
    public var workingDirectory: URL

    public init(executableURL: URL, arguments: [String], workingDirectory: URL) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    /// The command line a human would type to reproduce this launch, for
    /// dry-run messages and log lines.
    public var commandLine: String {
        (([executableURL.path] + arguments).joined(separator: " "))
            + " (cwd: \(workingDirectory.path))"
    }
}

public enum SidecarError: Error, LocalizedError, Equatable {
    case notInstalled(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let message), .launchFailed(let message):
            return message
        }
    }
}

/// Capability protocol so `CommandRouter` (DAWControl) can depend on an
/// abstraction and tests can inject a fake/stub without touching the real
/// process-spawning `SidecarManager`.
public protocol SidecarManaging: Sendable {
    func status() async -> SidecarStatus
    @discardableResult
    func start() async throws -> SidecarStatus
    @discardableResult
    func stop() async throws -> SidecarStatus
}
