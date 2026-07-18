import Darwin
import Foundation

/// Lifecycle manager for the local RVC voice-conversion sidecar (m10-p-3 —
/// see `scripts/rvc/README.md` for the stable v1 HTTP contract this type's
/// sibling, `VoiceConversionClient`, calls once healthy). Scope of THIS type
/// is process management only: install detection, health probing, start/
/// stop — mirroring `SidecarManager`'s split from `ACEStepClient` (process
/// lifecycle vs. generation/conversion calls are different concerns even
/// though both ultimately talk to the same sidecar process).
///
/// An actor (not `@MainActor`), same rationale as `SidecarManager`: no UI/
/// model-store work, state only ever touched from async contexts.
///
/// ## Deviations from `SidecarManager` (disclosed, both traced to
/// `scripts/rvc/run.sh` owning things ACE's `run.sh` leaves to Swift):
///
/// 1. **Pidfile ownership.** ACE's `run.sh` is a thin `exec` wrapper — its
///    own header comment says `SidecarManager.swift` "owns the pidfile/log
///    capture itself". RVC's `run.sh` is different BY ITS OWN DESIGN (see its
///    header comment, m10-p-2): it writes `.rvc.pid` itself (`echo $$ >
///    "$PIDFILE"`) BEFORE it `exec`s into the Python server — because the
///    pidfile needs to exist for plain shell lifecycle
///    (`kill $(cat .rvc.pid)`) even before this client existed. Since `exec`
///    never changes a process's pid, the value `run.sh` writes IS the same
///    pid `Process.processIdentifier` reports to us — so `start()` below
///    deliberately does NOT call a `writePidfile` (unlike `SidecarManager`):
///    doing so would just race harmlessly against `run.sh`'s own write of the
///    identical value. `stop()` still REMOVES the pidfile after signaling
///    (even though it never wrote it) so a subsequent `status()` — ours or a
///    fresh actor's pidfile-fallback read — reports a clean
///    `installedNotRunning` rather than misreading a stale file as a failed
///    boot, and so `run.sh`'s own next start doesn't have to self-heal past
///    stale-pidfile console noise.
/// 2. **Log ownership.** ACE's `SidecarManager` opens/creates the log file
///    itself and pipes the child's stdout/stderr into it
///    (`process.standardOutput = logHandle`). RVC's `run.sh` instead
///    redirects ITS OWN stdout/stderr (`exec >> "$LOG_FILE" 2>&1`) to a path
///    relative to its own runtime dir (`<rvcDir>/runtime/logs/rvc-facade.log`)
///    — that `exec >>` reassigns the process's fd 1/2 regardless of whatever
///    Swift set them to before `process.run()`, so owning a Swift-side log
///    handle here would produce a second, mostly-empty, misleading log file.
///    `start()` therefore does not open/assign a log handle at all;
///    `config.logFileURL` instead points AT `run.sh`'s own real log path
///    (computed from `rvcDir`, unlike `SidecarManager`'s fixed
///    `~/Library/Logs/DAWPro/...` default — see `Configuration.logFileURL`'s
///    own doc).
/// 3. **No `VoiceConversionStartPhase`.** See `VoiceConversionStatus.phase`'s
///    doc — the facade lazy-loads its engine so health should answer almost
///    immediately; a phase classifier would be unmeasured guesswork.
///
/// Everything else (health-envelope parsing shape, install-marker-based
/// notInstalled/installedNotRunning split, the M10-b "track a boot's
/// `startedAt` across the WHOLE boot, cleared only by a healthy probe / a
/// dead tracked pid / `stop()`" honesty fix, and the pidfile-fallback boot
/// classification for a fresh actor instance after a relaunch) mirrors
/// `SidecarManager` intentionally and closely — those lessons were paid for
/// once at ACE and apply here unchanged.
public actor VoiceConversionManager: VoiceConversionManaging {
    public let config: Configuration

    /// See `SidecarManager.startedAt`'s doc — identical semantics, tracked
    /// independently per actor instance (this type never shares state with
    /// `SidecarManager`, even though both may be alive in the same process).
    private var startedAt: Date?
    private var runningProcess: Process?

    public init(configuration: Configuration = .resolved()) {
        self.config = configuration
    }

    // MARK: - Status

    public func status() async -> VoiceConversionStatus {
        switch await probeHealth() {
        case .healthy(let info):
            startedAt = nil
            return VoiceConversionStatus(
                state: .healthy,
                message: "RVC voice-conversion sidecar is running and healthy.",
                version: info.version,
                engine: info.engine,
                baseModelPresent: info.baseModelPresent,
                voiceCount: info.voiceCount,
                pid: readPidfile()
            )
        case .malformed:
            return VoiceConversionStatus(
                state: .error,
                message: "RVC voice-conversion sidecar responded, but its /health response could "
                    + "not be parsed as the facade's expected JSON envelope — check "
                    + "\(config.logFileURL?.path ?? "its runtime/logs/rvc-facade.log")."
            )
        case .unreachable:
            switch bootProgress() {
            case .inProgress(let startedAt, let pid):
                let elapsed = Self.elapsedSeconds(since: startedAt)
                return VoiceConversionStatus(
                    state: .starting,
                    message: Self.startingStatusMessage(elapsedSeconds: elapsed),
                    pid: pid,
                    startingForSeconds: elapsed
                )
            case .failedBoot:
                return VoiceConversionStatus(
                    state: .installedNotRunning,
                    message: "RVC voice-conversion sidecar isn't responding and its process appears "
                        + "to have exited while starting — the boot likely failed; check "
                        + "\(config.logFileURL?.path ?? "its runtime/logs/rvc-facade.log"), then call "
                        + "vc.sidecarStart to retry."
                )
            case .notStarting:
                if isInstalled() {
                    return VoiceConversionStatus(
                        state: .installedNotRunning,
                        message: "RVC voice-conversion sidecar is installed but not running — call "
                            + "vc.sidecarStart."
                    )
                }
                return VoiceConversionStatus(
                    state: .notInstalled,
                    message: "RVC voice-conversion sidecar is not installed — run scripts/rvc/install.sh "
                        + "first (see scripts/rvc/README.md). This is process lifecycle management "
                        + "only — voice conversion/training tools arrive with a later roadmap item."
                )
            }
        }
    }

    // MARK: - Boot progress (mirrors SidecarManager's M10-b design, own copy —
    // see this type's own doc comment for why this isn't literally shared
    // with SidecarManager despite being conceptually identical).

    enum BootProgress: Sendable, Equatable {
        case inProgress(startedAt: Date, pid: Int32?)
        case failedBoot
        case notStarting
    }

    private func bootProgress() -> BootProgress {
        if let startedAt {
            if let runningProcess, !runningProcess.isRunning {
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

    /// Pure — no I/O. See `SidecarManager.classifyFallbackBoot` (identical
    /// rule, kept as this type's own copy rather than a cross-actor call).
    static func classifyFallbackBoot(pid: Int32, modifiedAt: Date, isAlive: Bool) -> BootProgress {
        isAlive ? .inProgress(startedAt: modifiedAt, pid: pid) : .failedBoot
    }

    private static func elapsedSeconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt).rounded()))
    }

    private static func startingStatusMessage(elapsedSeconds: Int) -> String {
        "RVC voice-conversion sidecar is starting (\(elapsedSeconds)s so far) — poll "
            + "vc.sidecarStatus again shortly."
    }

    // MARK: - Start

    @discardableResult
    public func start() async throws -> VoiceConversionStatus {
        let current = await status()
        if current.state == .healthy { return current }

        let plan = try config.resolveLaunchPlan()

        if config.dryRun {
            return VoiceConversionStatus(state: .starting, message: "[dry-run] would spawn: \(plan.commandLine)")
        }

        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory
        // No log-handle assignment — see this type's own doc comment,
        // deviation 2: `run.sh` redirects its own stdout/stderr to
        // `config.logFileURL` internally (`exec >> ... 2>&1`) before it execs
        // into the server, so anything set here would be overridden for
        // everything past its own brief preflight checks anyway.

        do {
            try process.run()
        } catch {
            throw SidecarError.launchFailed(
                "failed to launch \(plan.commandLine): \(error.localizedDescription)")
        }
        // Tracked across the WHOLE boot (M10-b), not cleared when this call
        // returns — see SidecarManager.startedAt's doc for the exact rules;
        // identical here. Deliberately NOT writing the pidfile — see
        // deviation 1: `run.sh` already does, with the same pid value (`exec`
        // never changes it).
        let bootStartedAt = Date()
        startedAt = bootStartedAt
        runningProcess = process

        let deadline = bootStartedAt.addingTimeInterval(config.startupTimeoutSeconds)
        while Date() < deadline {
            if !process.isRunning {
                startedAt = nil
                runningProcess = nil
                throw SidecarError.launchFailed(
                    "RVC voice-conversion sidecar process exited during startup — check "
                        + "\(config.logFileURL?.path ?? "its runtime/logs/rvc-facade.log").")
            }
            let probed = await status()
            if probed.state == .healthy {
                return probed
            }
            try? await Task.sleep(nanoseconds: UInt64(config.healthPollIntervalSeconds * 1_000_000_000))
        }
        let elapsed = Self.elapsedSeconds(since: bootStartedAt)
        return VoiceConversionStatus(
            state: .starting,
            message: Self.startupTimeoutMessage(
                timeoutSeconds: Int(config.startupTimeoutSeconds), elapsedSeconds: elapsed,
                logPath: config.logFileURL?.path ?? "its runtime/logs/rvc-facade.log"),
            pid: process.processIdentifier,
            startingForSeconds: elapsed
        )
    }

    private static func startupTimeoutMessage(
        timeoutSeconds: Int, elapsedSeconds: Int, logPath: String
    ) -> String {
        "RVC voice-conversion sidecar did not report healthy within \(timeoutSeconds)s — it's "
            + "likely still booting (\(elapsedSeconds)s so far); poll vc.sidecarStatus again, or "
            + "check \(logPath)."
    }

    // MARK: - Stop

    @discardableResult
    public func stop() async throws -> VoiceConversionStatus {
        guard config.pidfileURL != nil else {
            return VoiceConversionStatus(
                state: .notInstalled,
                message: "RVC voice-conversion sidecar directory is not resolvable — nothing to stop."
            )
        }
        guard let pid = readPidfile() else {
            startedAt = nil
            return VoiceConversionStatus(
                state: isInstalled() ? .installedNotRunning : .notInstalled,
                message: "RVC voice-conversion sidecar is not running (no pidfile found)."
            )
        }
        if config.dryRun {
            return VoiceConversionStatus(
                state: .installedNotRunning, message: "[dry-run] would stop pid \(pid).", pid: pid)
        }
        guard processAlive(pid) else {
            removePidfile()
            runningProcess = nil
            startedAt = nil
            return VoiceConversionStatus(
                state: .installedNotRunning,
                message: "RVC voice-conversion sidecar was not running (stale pidfile removed)."
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
        // Deviation 1: WE remove the pidfile here even though `run.sh` wrote
        // it — see this type's own doc comment for why (a clean
        // installedNotRunning read afterward, not a stale-file misread).
        removePidfile()
        runningProcess = nil
        startedAt = nil

        let after = await status()
        if after.state == .healthy {
            return after
        }
        return VoiceConversionStatus(state: .installedNotRunning, message: "RVC voice-conversion sidecar stopped.")
    }

    // MARK: - Health probe

    private struct HealthInfo: Sendable {
        var version: String?
        var engine: String?
        var baseModelPresent: Bool?
        var voiceCount: Int?
    }

    private enum HealthProbe: Sendable {
        case healthy(HealthInfo)
        case malformed
        case unreachable
    }

    /// The RVC facade's own `GET /health` (verified against
    /// `scripts/rvc/server.py`) deliberately mirrors ACE-Step's envelope
    /// shape (`{"data": {...}, "code": 0, "error": null}` — the facade's own
    /// doc comment says so) so this probe is structurally identical to
    /// `SidecarManager.probeHealth()`, just reading `engine`/
    /// `baseModelPresent`/`voiceCount` instead of `loaded_model`/
    /// `loaded_lm_model`.
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
                engine: inner["engine"] as? String,
                baseModelPresent: inner["baseModelPresent"] as? Bool,
                voiceCount: (inner["voiceCount"] as? NSNumber)?.intValue ?? (inner["voiceCount"] as? Int)
            )
        )
    }

    private func isInstalled() -> Bool {
        guard let marker = config.installMarkerURL else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    // MARK: - Pidfile

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

extension VoiceConversionManager {
    /// Everything needed to locate/launch the sidecar. Mirrors
    /// `SidecarManager.Configuration`'s shape and role; see this type's own
    /// doc comment for the `pidfileURL`/`logFileURL` ownership deviations.
    public struct Configuration: Sendable {
        public var baseURL: URL
        /// nil when unresolvable (no env override and not running from
        /// inside a daw-pro checkout) — mirrors `SidecarManager`'s
        /// `acestepDir`.
        public var rvcDir: URL?
        public var startupTimeoutSeconds: Double
        public var healthPollIntervalSeconds: Double
        public var healthProbeTimeoutSeconds: Double
        public var stopTimeoutSeconds: Double
        public var dryRun: Bool

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8002")!,
            rvcDir: URL?,
            startupTimeoutSeconds: Double = 30,
            healthPollIntervalSeconds: Double = 0.5,
            healthProbeTimeoutSeconds: Double = 2.0,
            stopTimeoutSeconds: Double = 5.0,
            dryRun: Bool = false
        ) {
            self.baseURL = baseURL
            self.rvcDir = rvcDir
            self.startupTimeoutSeconds = startupTimeoutSeconds
            self.healthPollIntervalSeconds = healthPollIntervalSeconds
            self.healthProbeTimeoutSeconds = healthProbeTimeoutSeconds
            self.stopTimeoutSeconds = stopTimeoutSeconds
            self.dryRun = dryRun
        }

        /// `.rvc.pid` — same filename `scripts/rvc/run.sh` itself writes
        /// (deviation 1: it, not this type, is the writer; see the type doc).
        public var pidfileURL: URL? { rvcDir?.appendingPathComponent(".rvc.pid") }
        /// `.install-state.json` — same filename/convention as ACE's
        /// `installMarkerURL`, written by `scripts/rvc/install.sh`.
        public var installMarkerURL: URL? { rvcDir?.appendingPathComponent(".install-state.json") }
        /// `<rvcDir>/runtime/logs/rvc-facade.log` — `run.sh`'s OWN hardcoded
        /// (relative to its own dir, absent an `RVC_RUNTIME_DIR` override
        /// this spawner does not set) log path, per its header comment
        /// ("Logs go to <runtime>/logs/rvc-facade.log"). Unlike
        /// `SidecarManager.Configuration.logFileURL` (a fixed, Swift-owned
        /// `~/Library/Logs/DAWPro/...` default independent of the install
        /// location), this is COMPUTED from `rvcDir` — nil when `rvcDir`
        /// itself is unresolvable — because `run.sh`, not this type, is the
        /// one actually writing it (deviation 2; see the type doc).
        public var logFileURL: URL? {
            rvcDir?.appendingPathComponent("runtime/logs/rvc-facade.log")
        }

        /// Pure path resolution — no process spawned. Throws `.notInstalled`
        /// (never crashes) when the directory or its `run.sh` can't be found.
        public func resolveLaunchPlan() throws -> SidecarLaunchPlan {
            guard let dir = rvcDir else {
                throw SidecarError.notInstalled(
                    "RVC voice-conversion sidecar directory could not be resolved — set "
                        + "DAWPRO_RVC_DIR, or run the app from inside the daw-pro repo checkout "
                        + "(expects scripts/rvc/run.sh).")
            }
            let runScript = dir.appendingPathComponent("run.sh")
            guard FileManager.default.fileExists(atPath: runScript.path) else {
                throw SidecarError.notInstalled(
                    "run.sh not found at \(runScript.path) — run scripts/rvc/install.sh first "
                        + "(see scripts/rvc/README.md).")
            }
            return SidecarLaunchPlan(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [runScript.path],
                workingDirectory: dir
            )
        }

        /// Default configuration for the running app: `DAWPRO_RVC_DIR` wins
        /// if set (also how tests/E2E point at a stub sidecar dir);
        /// otherwise walk up from a repo-relative anchor looking for
        /// `Package.swift` and use `<repo>/scripts/rvc` — mirrors
        /// `SidecarManager.Configuration.resolveAcestepDir`'s heuristic
        /// exactly, including its dev-only caveat (a packaged `.app`, M9,
        /// must set the env var).
        public static func resolved(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Configuration {
            var config = Configuration(rvcDir: resolveRVCDir(environment: environment))
            if let override = environment["RVC_API_URL"], let url = URL(string: override) {
                config.baseURL = url
            }
            return config
        }

        public static func resolveRVCDir(environment: [String: String]) -> URL? {
            if let override = environment["DAWPRO_RVC_DIR"], !override.isEmpty {
                return URL(fileURLWithPath: override).standardizedFileURL
            }
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
                    return dir.appendingPathComponent("scripts/rvc")
                }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
            return nil
        }
    }
}
