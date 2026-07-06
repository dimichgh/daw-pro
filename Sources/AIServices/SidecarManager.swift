import Darwin
import Foundation

/// Lifecycle manager for the local ACE-Step-1.5 song-generation sidecar
/// (M6 i — see docs/research/2026-07-05-ace-step-local-song-generation.md).
/// Scope of THIS type is process management only: install detection, health
/// probing, start/stop. The generation client (`ACEStepClient: SongGenerating`
/// against the sidecar's job-queue REST API) is a separate, later type.
///
/// An actor (not @MainActor) because it does no UI/model-store work and its
/// state (in-flight start/stop bookkeeping) is only ever touched from async
/// contexts — matching the house rule that only UI/model mutation needs
/// `@MainActor`.
public actor SidecarManager: SidecarManaging {
    public let config: Configuration

    /// Set for the duration of an in-flight `start()` call (before any
    /// `await`) so a concurrent `status()` can honestly report `.starting`
    /// instead of guessing from a bare connection failure.
    private var startingSince: Date?
    /// Kept only so this process's own `start()` can see the child is alive
    /// without re-reading the pidfile; the pidfile remains the source of
    /// truth across process/app relaunches (see `stop()`).
    private var runningProcess: Process?

    public init(configuration: Configuration = .resolved()) {
        self.config = configuration
    }

    // MARK: - Status

    public func status() async -> SidecarStatus {
        switch await probeHealth() {
        case .healthy(let info):
            return SidecarStatus(
                state: .healthy,
                message: "ACE-Step sidecar is running and healthy.",
                version: info.version,
                ditModel: info.ditModel,
                lmModel: info.lmModel,
                pid: readPidfile()
            )
        case .malformed:
            return SidecarStatus(
                state: .error,
                message: "ACE-Step sidecar responded, but its /health response could not be "
                    + "parsed as ACE-Step's JSON envelope — check \(config.logFileURL.path)."
            )
        case .unreachable:
            if startingSince != nil {
                return SidecarStatus(
                    state: .starting,
                    message: "ACE-Step sidecar is starting — poll ai.sidecarStatus again shortly."
                )
            }
            if isInstalled() {
                return SidecarStatus(
                    state: .installedNotRunning,
                    message: "ACE-Step is installed but not running — call ai.sidecarStart."
                )
            }
            return SidecarStatus(
                state: .notInstalled,
                message: "ACE-Step sidecar is not installed — run scripts/ace-step/install.sh "
                    + "first (downloads the XL-turbo/XL-sft DiT + 4B LM tier, ~55-70 GB; see "
                    + "docs/research/2026-07-05-ace-step-local-song-generation.md). Generation "
                    + "tools (generate_song et al.) arrive once ACEStepClient lands — this is "
                    + "process lifecycle management only."
            )
        }
    }

    // MARK: - Start

    @discardableResult
    public func start() async throws -> SidecarStatus {
        let current = await status()
        if current.state == .healthy { return current }

        let plan = try config.resolveLaunchPlan()

        if config.dryRun {
            return SidecarStatus(state: .starting, message: "[dry-run] would spawn: \(plan.commandLine)")
        }

        let logDirectory = config.logFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: config.logFileURL.path) {
            FileManager.default.createFile(atPath: config.logFileURL.path, contents: nil)
        }
        let logHandle: FileHandle
        do {
            logHandle = try FileHandle(forWritingTo: config.logFileURL)
        } catch {
            throw SidecarError.launchFailed(
                "could not open log file \(config.logFileURL.path): \(error.localizedDescription)")
        }
        logHandle.seekToEndOfFile()

        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory
        process.standardOutput = logHandle
        process.standardError = logHandle

        startingSince = Date()
        defer { startingSince = nil }

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw SidecarError.launchFailed(
                "failed to launch \(plan.commandLine): \(error.localizedDescription)")
        }
        runningProcess = process
        writePidfile(process.processIdentifier)

        let deadline = Date().addingTimeInterval(config.startupTimeoutSeconds)
        while Date() < deadline {
            if !process.isRunning {
                throw SidecarError.launchFailed(
                    "ACE-Step sidecar process exited during startup — check "
                        + "\(config.logFileURL.path).")
            }
            let probed = await status()
            if probed.state == .healthy {
                return probed
            }
            try? await Task.sleep(nanoseconds: UInt64(config.healthPollIntervalSeconds * 1_000_000_000))
        }
        return SidecarStatus(
            state: .starting,
            message: "ACE-Step sidecar did not report healthy within "
                + "\(Int(config.startupTimeoutSeconds))s — it may still be loading models; poll "
                + "ai.sidecarStatus again, or check \(config.logFileURL.path).",
            pid: process.processIdentifier
        )
    }

    // MARK: - Stop

    @discardableResult
    public func stop() async throws -> SidecarStatus {
        guard config.pidfileURL != nil else {
            return SidecarStatus(
                state: .notInstalled,
                message: "ACE-Step sidecar directory is not resolvable — nothing to stop."
            )
        }
        guard let pid = readPidfile() else {
            return SidecarStatus(
                state: isInstalled() ? .installedNotRunning : .notInstalled,
                message: "ACE-Step sidecar is not running (no pidfile found)."
            )
        }
        if config.dryRun {
            return SidecarStatus(
                state: .installedNotRunning, message: "[dry-run] would stop pid \(pid).", pid: pid)
        }
        guard processAlive(pid) else {
            removePidfile()
            runningProcess = nil
            return SidecarStatus(
                state: .installedNotRunning,
                message: "ACE-Step sidecar was not running (stale pidfile removed)."
            )
        }

        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(config.stopTimeoutSeconds)
        while Date() < deadline, processAlive(pid) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if processAlive(pid) {
            kill(pid, SIGKILL)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        removePidfile()
        runningProcess = nil

        let after = await status()
        if after.state == .healthy {
            // Never lie about a sidecar that's somehow still answering.
            return after
        }
        return SidecarStatus(state: .installedNotRunning, message: "ACE-Step sidecar stopped.")
    }

    // MARK: - Health probe

    private struct HealthInfo: Sendable {
        var version: String?
        var ditModel: String?
        var lmModel: String?
    }

    private enum HealthProbe: Sendable {
        case healthy(HealthInfo)
        case malformed
        case unreachable
    }

    /// ACE-Step's own `GET /health` (verified against `acestep/api/http/model_service_routes.py`)
    /// wraps its payload in `{"data": {...}, "code", "error", ...}`; the fields
    /// we read (`version`, `loaded_model`, `loaded_lm_model`) live under `data`.
    private func probeHealth() async -> HealthProbe {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.timeoutInterval = config.healthProbeTimeoutSeconds

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .unreachable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return .unreachable
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let top = parsed as? [String: Any],
              let inner = top["data"] as? [String: Any] else {
            return .malformed
        }
        return .healthy(
            HealthInfo(
                version: inner["version"] as? String,
                ditModel: inner["loaded_model"] as? String,
                lmModel: inner["loaded_lm_model"] as? String
            )
        )
    }

    private func isInstalled() -> Bool {
        guard let marker = config.installMarkerURL else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    // MARK: - Pidfile

    private func writePidfile(_ pid: Int32) {
        guard let url = config.pidfileURL else { return }
        try? "\(pid)".write(to: url, atomically: true, encoding: .utf8)
    }

    private func readPidfile() -> Int32? {
        guard let url = config.pidfileURL,
              let contents = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    private func removePidfile() {
        guard let url = config.pidfileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}

extension SidecarManager {
    /// Everything needed to locate/launch the sidecar. A plain (non-actor)
    /// value type so path resolution (`resolveLaunchPlan()`) is directly
    /// unit-testable headless, with no actor hop and no I/O beyond
    /// `FileManager` existence checks.
    public struct Configuration: Sendable {
        public var baseURL: URL
        /// nil when unresolvable (no env override and not running from
        /// inside a daw-pro checkout) — every operation that needs it then
        /// throws/reports `notInstalled` rather than crashing.
        public var acestepDir: URL?
        public var logFileURL: URL
        public var startupTimeoutSeconds: Double
        public var healthPollIntervalSeconds: Double
        public var healthProbeTimeoutSeconds: Double
        public var stopTimeoutSeconds: Double
        /// Test/dry-run seam: `start()`/`stop()` resolve paths and report
        /// what they WOULD do without spawning/signaling a real process.
        public var dryRun: Bool

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8001")!,
            acestepDir: URL?,
            logFileURL: URL = Configuration.defaultLogFileURL(),
            startupTimeoutSeconds: Double = 30,
            healthPollIntervalSeconds: Double = 0.5,
            healthProbeTimeoutSeconds: Double = 2.0,
            stopTimeoutSeconds: Double = 5.0,
            dryRun: Bool = false
        ) {
            self.baseURL = baseURL
            self.acestepDir = acestepDir
            self.logFileURL = logFileURL
            self.startupTimeoutSeconds = startupTimeoutSeconds
            self.healthPollIntervalSeconds = healthPollIntervalSeconds
            self.healthProbeTimeoutSeconds = healthProbeTimeoutSeconds
            self.stopTimeoutSeconds = stopTimeoutSeconds
            self.dryRun = dryRun
        }

        public var pidfileURL: URL? { acestepDir?.appendingPathComponent(".ace-step.pid") }
        public var installMarkerURL: URL? { acestepDir?.appendingPathComponent(".install-state.json") }

        /// Pure path resolution — no process spawned. Throws `.notInstalled`
        /// (never crashes) when the directory or its `run.sh` can't be found.
        public func resolveLaunchPlan() throws -> SidecarLaunchPlan {
            guard let dir = acestepDir else {
                throw SidecarError.notInstalled(
                    "ACE-Step sidecar directory could not be resolved — set DAWPRO_ACESTEP_DIR, "
                        + "or run the app from inside the daw-pro repo checkout "
                        + "(expects scripts/ace-step/run.sh).")
            }
            let runScript = dir.appendingPathComponent("run.sh")
            guard FileManager.default.fileExists(atPath: runScript.path) else {
                throw SidecarError.notInstalled(
                    "run.sh not found at \(runScript.path) — run scripts/ace-step/install.sh "
                        + "first (see docs/research/2026-07-05-ace-step-local-song-generation.md).")
            }
            return SidecarLaunchPlan(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [runScript.path],
                workingDirectory: dir
            )
        }

        /// Default configuration for the running app: `DAWPRO_ACESTEP_DIR`
        /// wins if set (also how tests/E2E point at a stub sidecar dir
        /// without weights); otherwise walk up from a repo-relative anchor
        /// looking for `Package.swift` and use `<repo>/scripts/ace-step`.
        /// That walk-up is a dev-only heuristic — a packaged `.app` (M9) has
        /// no `Package.swift` anywhere nearby and MUST set
        /// `DAWPRO_ACESTEP_DIR` instead.
        public static func resolved(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Configuration {
            Configuration(
                acestepDir: resolveAcestepDir(environment: environment),
                logFileURL: defaultLogFileURL()
            )
        }

        public static func resolveAcestepDir(environment: [String: String]) -> URL? {
            if let override = environment["DAWPRO_ACESTEP_DIR"], !override.isEmpty {
                return URL(fileURLWithPath: override).standardizedFileURL
            }
            // Two anchors, tried in order: the process's current directory
            // (SwiftPM always runs `swift run`/`swift test` with cwd = the
            // package root, so this is the reliable one under the test
            // runner) and argv[0] (correct for a plain built executable
            // launched directly, e.g. a future packaged dev build — but
            // NOT for `swift test`, whose actual argv[0] is a toolchain-
            // internal helper binary miles from the repo).
            let anchors = [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                CommandLine.arguments.first.map {
                    URL(fileURLWithPath: $0).resolvingSymlinksInPath().deletingLastPathComponent()
                },
            ].compactMap { $0 }
            for anchor in anchors {
                if let found = walkUpForScriptsDir(from: anchor) {
                    return found
                }
            }
            return nil
        }

        private static func walkUpForScriptsDir(from start: URL) -> URL? {
            var dir = start
            for _ in 0..<8 {
                if FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("Package.swift").path
                ) {
                    return dir.appendingPathComponent("scripts/ace-step")
                }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
            return nil
        }

        public static func defaultLogFileURL() -> URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DAWPro/ace-step.log")
        }
    }
}
