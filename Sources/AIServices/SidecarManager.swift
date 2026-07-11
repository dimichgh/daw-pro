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

    /// Wall-clock time THIS actor's own `start()` spawned a boot that hasn't
    /// yet reached healthy (M10-b). Set once, right after `process.run()`
    /// succeeds, and — unlike the old `startingSince`, which was scoped to
    /// the duration of one blocking `start()` call via `defer` — cleared ONLY
    /// when (a) a `status()` probe observes healthy, (b) the tracked
    /// `runningProcess` is found dead, or (c) `stop()` runs. That's the fix
    /// for the beta report ("did not report healthy within 30s" then every
    /// later poll misreported `installedNotRunning`): model loads can
    /// legitimately take ~1 min cold, well past the 30s window `start()`
    /// itself blocks for, so a `status()` call made AFTER `start()` times out
    /// must still see this and report `.starting` honestly.
    private var startedAt: Date?
    /// The `Process` this actor itself spawned — nil for a fresh actor
    /// instance that never called `start()` (e.g. a fresh app launch that
    /// finds a boot already in flight from a previous run; see
    /// `bootProgress()`'s pidfile fallback). `.isRunning` is the liveness
    /// check backing `startedAt`'s clearing rule (b) above; also how `stop()`
    /// avoids re-reading the pidfile for a process this actor spawned.
    private var runningProcess: Process?

    public init(configuration: Configuration = .resolved()) {
        self.config = configuration
    }

    // MARK: - Status

    public func status() async -> SidecarStatus {
        switch await probeHealth() {
        case .healthy(let info):
            // Clearing rule (a): a healthy probe always ends a tracked boot,
            // whether it was this actor's own `start()` or a fallback picked
            // up from a pidfile after a relaunch.
            startedAt = nil
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
            switch bootProgress() {
            case .inProgress(let startedAt, let pid):
                let elapsed = Self.elapsedSeconds(since: startedAt)
                let phase = readLogTail().flatMap(SidecarStartPhase.classify(logTail:))
                return SidecarStatus(
                    state: .starting,
                    message: Self.startingStatusMessage(elapsedSeconds: elapsed, phase: phase),
                    pid: pid,
                    phase: phase,
                    startingForSeconds: elapsed
                )
            case .failedBoot:
                return SidecarStatus(
                    state: .installedNotRunning,
                    message: "ACE-Step sidecar isn't responding and its process appears to have "
                        + "exited while starting — the boot likely failed; check "
                        + "\(config.logFileURL.path), then call ai.sidecarStart to retry."
                )
            case .notStarting:
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
    }

    // MARK: - Boot progress (M10-b)

    /// The three ways an unreachable health probe can be explained, beyond a
    /// bare "not running": a boot genuinely in flight (never `.installedNot-
    /// Running`, per the M10-b fix), a boot that started but whose process
    /// has since died (a lingering pidfile — reported distinctly so the
    /// message can say the boot failed, not just "not running yet"), or
    /// nothing tracked at all (the pre-existing notInstalled/installedNot-
    /// Running split via `isInstalled()`).
    // Not `private`: `classifyFallbackBoot(...)` below returns this type and
    // is (default `internal`) access so headless tests (`@testable import
    // AIServices`) can call it directly without spawning a process.
    enum BootProgress: Sendable, Equatable {
        case inProgress(startedAt: Date, pid: Int32?)
        case failedBoot
        case notStarting
    }

    /// Resolves which of the three `BootProgress` cases applies, preferring
    /// this actor's own in-memory `startedAt` (set by `start()`) and falling
    /// back to the pidfile (requirement 1's relaunch-mid-boot case: a fresh
    /// `SidecarManager` — e.g. after an app relaunch — has no in-memory
    /// record even though a previously-spawned process may still be booting).
    /// The pid-liveness CHECK itself (real I/O, `kill(pid, 0)`/`Process.
    /// isRunning`) happens here; the actual verdict from that check is a pure,
    /// separately-testable decision (`Self.classifyFallbackBoot`).
    private func bootProgress() -> BootProgress {
        if let startedAt {
            if let runningProcess, !runningProcess.isRunning {
                // Clearing rule (b): our own child died without ever going
                // healthy.
                self.startedAt = nil
                self.runningProcess = nil
                return .failedBoot
            }
            return .inProgress(startedAt: startedAt, pid: runningProcess?.processIdentifier)
        }
        guard let pidfileURL = config.pidfileURL,
              let pid = readPidfile(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: pidfileURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date
        else {
            return .notStarting
        }
        return Self.classifyFallbackBoot(pid: pid, modifiedAt: modifiedAt, isAlive: processAlive(pid))
    }

    /// Pure — no I/O — decision for the pidfile-fallback case: given a
    /// pidfile's pid, its file-modification date (used as an approximation of
    /// "when this boot started", since `start()` writes the pidfile
    /// immediately after spawning — see `writePidfile`), and a liveness check
    /// the caller already performed, decides whether that pidfile represents
    /// a boot still in progress or one that has died. Kept `static` + pure so
    /// it's directly headless-testable, matching the `resolveLaunchPlan()`/
    /// `resolveAcestepDir()` testability convention in this file.
    static func classifyFallbackBoot(pid: Int32, modifiedAt: Date, isAlive: Bool) -> BootProgress {
        isAlive ? .inProgress(startedAt: modifiedAt, pid: pid) : .failedBoot
    }

    private static func elapsedSeconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt).rounded()))
    }

    private static func startingStatusMessage(elapsedSeconds: Int, phase: String?) -> String {
        if let phase {
            return "ACE-Step sidecar is starting — \(phase) (\(elapsedSeconds)s so far). Poll "
                + "ai.sidecarStatus again shortly."
        }
        return "ACE-Step sidecar is starting (\(elapsedSeconds)s so far) — poll ai.sidecarStatus "
            + "again shortly."
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

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw SidecarError.launchFailed(
                "failed to launch \(plan.commandLine): \(error.localizedDescription)")
        }
        // Tracked from here across the WHOLE boot (M10-b) — NOT cleared when
        // this call returns; only by the three rules on `startedAt`'s own doc
        // comment. This is what lets a `status()` poll made after the loop
        // below times out still honestly report `.starting`.
        let bootStartedAt = Date()
        startedAt = bootStartedAt
        runningProcess = process
        writePidfile(process.processIdentifier)

        let deadline = bootStartedAt.addingTimeInterval(config.startupTimeoutSeconds)
        while Date() < deadline {
            if !process.isRunning {
                // Clearing rule (b), inline: the boot has already failed, so
                // don't leave a dead `startedAt` around for the next poll to
                // trip over.
                startedAt = nil
                runningProcess = nil
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
        // Still not healthy after the blocking window — this is NOT an error
        // (`ai.sidecarStart`'s own 30s blocking wait is unchanged), but the
        // message is now health-aware: it names the elapsed time (not just
        // the timeout), the current log phase when recognizable, and the log
        // path — and, critically, every LATER `ai.sidecarStatus` poll will
        // keep reporting `.starting` with a truthfully increasing counter
        // instead of misreporting `installedNotRunning` (the M10-b bug).
        let elapsed = Self.elapsedSeconds(since: bootStartedAt)
        let phase = readLogTail().flatMap(SidecarStartPhase.classify(logTail:))
        return SidecarStatus(
            state: .starting,
            message: Self.startupTimeoutMessage(
                timeoutSeconds: Int(config.startupTimeoutSeconds), elapsedSeconds: elapsed,
                phase: phase, logPath: config.logFileURL.path),
            pid: process.processIdentifier,
            phase: phase,
            startingForSeconds: elapsed
        )
    }

    private static func startupTimeoutMessage(
        timeoutSeconds: Int, elapsedSeconds: Int, phase: String?, logPath: String
    ) -> String {
        let phaseClause = phase.map { " (\($0))" } ?? ""
        return "ACE-Step sidecar did not report healthy within \(timeoutSeconds)s\(phaseClause) — "
            + "it's likely still booting (\(elapsedSeconds)s so far — models can take a while to "
            + "load on a cold start); the panel will update as it boots, so poll ai.sidecarStatus "
            + "again, or check \(logPath)."
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
            startedAt = nil   // clearing rule (c), even on this early "nothing to stop" path
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
            startedAt = nil   // clearing rule (c)
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
        startedAt = nil   // clearing rule (c): stop() always ends a tracked boot

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

    // MARK: - Log tail (M10-b progress phase)

    /// Bytes of `config.logFileURL` read from the end for `SidecarStartPhase`
    /// classification — enough to span the marker lines a real boot writes
    /// per phase without reading the whole (potentially many-MB, appended-
    /// forever-across-restarts) file on every `.starting` poll.
    private static let logTailByteLimit = 4096

    /// Reads the last ~4 KB of the sidecar log as text, or nil when the file
    /// doesn't exist yet / can't be decoded as UTF-8 (a fresh boot before any
    /// output has been flushed) — `status()`/`start()` treat that as "no
    /// phase classifiable", never an error.
    private func readLogTail() -> String? {
        guard let handle = try? FileHandle(forReadingFrom: config.logFileURL) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let tailStart = size > UInt64(Self.logTailByteLimit) ? size - UInt64(Self.logTailByteLimit) : 0
            try handle.seek(toOffset: tailStart)
            guard let data = try handle.readToEnd() else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
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
