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
    /// The outcome of the most recent `stop()` that actually signalled
    /// something (m23-dl).
    ///
    /// Recorded so `evictWithoutCoordinator()` can answer *"is any pid from the
    /// PRE-KILL captured tree still alive?"* from the **same** capture that did
    /// the signalling. A second `ps` snapshot taken afterwards cannot answer it:
    /// once the parent exits its children are reparented to pid 1 and the
    /// linkage is gone (measured at m23-az-1). Purely observational — nothing
    /// reads it to decide what to signal.
    private var lastTerminationOutcome: SidecarStop.TerminationOutcome?

    /// The model-lifecycle flight ticket for a boot **this actor** started
    /// (m23-dl), or nil when no boot of ours is in flight.
    ///
    /// ⚠️⚠️ **ITS LIFETIME IS NOT `start()`'s SCOPE (F14).** `start()` returns
    /// `.starting` when its ~30 s poll window expires, and a cold model load runs
    /// on well past that; a `defer { release }` would hand the flight slot back
    /// mid-boot and let the next start land on top of an 80 GB load in progress —
    /// precisely the double-load this item exists to prevent. The ticket takes
    /// `startedAt`'s own three clearing rules instead: (a) a healthy probe,
    /// (b) the tracked process found dead, (c) `stop()`. Plus the coordinator's
    /// stale-ticket backstop, which only ever reclaims a ticket whose pid is
    /// dead.
    private var flightTicket: ModelLifecycleCoordinator.Ticket?

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
            await releaseFlightTicket(healthy: true)
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
                // Clearing rule (b), for the ticket as well as `startedAt`.
                // ⚠️ Notified from HERE and not from `bootProgress()`, which is a
                // synchronous `private func` that cannot await the coordinator —
                // and `Task { await … }` inside it would be fire-and-forget,
                // unordered against everything else (F14).
                await releaseFlightTicket(healthy: false)
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

        // ⚠️⚠️ F15, RULE 1 — RESOLVE BEFORE THE `dryRun` BRANCH, COMMIT AFTER IT.
        // `resolveAdmission` is read-only: it signals nothing, mints nothing and
        // takes no memory sample. `commitAdmission` ACTS — it mints the flight
        // ticket and SIGTERMs the models the plan names for unload-before-load.
        // Folding the two into one call placed here would let `dryRun: true`, a
        // mode whose entire contract is "spawn nothing, signal nothing", kill the
        // user's live RVC sidecar. That is MORE dangerous since the scope cut,
        // not less: eviction used to happen only when memory was short, and it is
        // now the normal plan whenever a second model is resident.
        let admission = await config.lifecycle.resolveAdmission(.aceStep)

        if config.dryRun {
            return SidecarStatus(
                state: admission.isAdmitted ? .starting : .error,
                message: await config.lifecycle.dryRunDescription(
                    admission, for: .aceStep, launch: plan.commandLine))
        }

        // ACTS. Throws `admissionRefused` only for single-flight — there is no
        // memory gate and nothing here can refuse a boot for memory.
        let ticket = try await config.lifecycle.commitAdmission(admission, for: .aceStep)
        flightTicket = ticket
        do {
            return try await spawnAndPoll(plan)
        } catch {
            // ⚠️ Every throwing exit AFTER the mint gives the ticket back. A
            // leaked ticket refuses every later boot with `bootInFlight` until
            // the stale-ticket rule reclaims it, and the app-side auto-start
            // callers swallow that with `try?` — so the symptom would be "Start
            // does nothing" for two minutes, with no error anywhere (F14).
            await releaseFlightTicket(healthy: false)
            throw error
        }
    }

    /// The pre-m23-dl body of `start()`, verbatim apart from recording the boot
    /// pid. Split out only so the admission wiring above has one place to catch a
    /// throw and hand the flight ticket back.
    private func spawnAndPoll(_ plan: SidecarLaunchPlan) async throws -> SidecarStatus {
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
        // So the coordinator's stale-ticket rule can tell a slow boot from a dead
        // one: a ticket whose pid is ALIVE is never reclaimed on a timer, however
        // old (the `kill -0`-on-a-zombie trap in a different costume).
        if let flightTicket {
            await config.lifecycle.recordBootPid(flightTicket, pid: process.processIdentifier)
        }

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

    /// The ONE place this actor hands its flight ticket back (m23-dl).
    ///
    /// `healthy: true` books the model as resident and starts its idle clock;
    /// `healthy: false` just releases the slot. Both are no-ops when no ticket is
    /// held, which is every test that never registered a model with the shared
    /// coordinator.
    ///
    /// ⚠️ **NOT called from `stop()`** — `stop()` is reachable from
    /// `evictWithoutCoordinator()`, and calling back into the coordinator from
    /// there is exactly what F7 forbids. Clearing rule (c) is applied by the
    /// coordinator's own `performEviction`, and by `noteStoppedExternally` for
    /// the direct `ai.sidecarStop` path.
    private func releaseFlightTicket(healthy: Bool) async {
        guard let ticket = flightTicket else { return }
        flightTicket = nil
        await config.lifecycle.admitted(ticket, healthy: healthy)
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

    // MARK: - Stop (m23-bb)
    //
    // The DECISION ("what should stop do, and is it safe to signal that
    // process?") is not made here — it lives once in `SidecarStop`, shared with
    // `VoiceConversionManager` (m23-bb-1). Two planners would be two answers to
    // one question, which is the m23-bb defect class itself. What stays here is
    // the ACE-specific identity/wording, the fact gathering, and applying the
    // plan to THIS actor's state.

    /// How this sidecar's own processes are recognised — one of exactly two
    /// ACE-specific inputs to the shared planner.
    private var stopIdentity: SidecarStop.Identity {
        .aceStep(directoryPath: config.acestepDir?.path)
    }

    /// The wording every shared stop message speaks in — the other one.
    static let stopVocabulary = SidecarStop.Vocabulary.aceStep

    @discardableResult
    public func stop() async throws -> SidecarStatus {
        guard config.pidfileURL != nil else {
            return SidecarStatus(
                state: .notInstalled,
                message: "ACE-Step sidecar directory is not resolvable — nothing to stop."
            )
        }

        let plan = await resolvedStopPlan()

        if config.dryRun {
            // The dry-run seam stays a pure no-op: fact-gathering above is
            // read-only (`ps`/`lsof`/an HTTP GET), and nothing below this
            // point runs — no signal, no pidfile removal, no state clearing.
            let report = SidecarStop.dryRunReport(
                for: plan, isInstalled: isInstalled(), vocabulary: Self.stopVocabulary,
                baseURL: config.baseURL, pidfilePath: config.pidfileURL?.path)
            return SidecarStatus(state: report.state, message: report.message, pid: report.pid)
        }

        switch plan {
        case .notRunning(let reason):
            // The ONLY branch allowed to say "not running" — and it is now
            // only reachable when the health probe AGREES the sidecar is not
            // answering (m23-bb's floor rule).
            if reason.removesPidfile { removePidfile() }
            runningProcess = nil
            startedAt = nil   // clearing rule (c), even on this "nothing to stop" path
            // Clearing rule (c) for the flight ticket too. LOCAL state only —
            // `stop()` is reachable from `evictWithoutCoordinator()`, and calling
            // the coordinator from there is what F7 forbids.
            flightTicket = nil
            lastTerminationOutcome = nil   // nothing was signalled, so there is no tree
            return SidecarStatus(
                state: SidecarStop.notRunningState(reason, isInstalled: isInstalled()),
                message: SidecarStop.notRunningMessage(reason, vocabulary: Self.stopVocabulary),
                pid: reason.pid
            )

        case .refuse(let refusal):
            // The sidecar IS answering and we found nothing we are willing to
            // signal. Report the truth and change NOTHING: a failed stop must
            // not quietly delete state on its way out.
            throw SidecarError.stopFailed(SidecarStop.refusalMessage(
                refusal, vocabulary: Self.stopVocabulary, baseURL: config.baseURL,
                pidfilePath: config.pidfileURL?.path))

        case .terminate(let pid, let discovery):
            let outcome: SidecarStop.TerminationOutcome
            switch await SidecarStop.terminateTree(
                target: pid, discovery: discovery, identity: stopIdentity,
                stopTimeoutSeconds: config.stopTimeoutSeconds
            ) {
            case .refused(let refusal):
                // The target stopped being identifiable between planning and
                // signalling — a recycled pid. Refuse, exactly as if it had
                // never identified in the first place.
                throw SidecarError.stopFailed(SidecarStop.refusalMessage(
                    refusal, vocabulary: Self.stopVocabulary, baseURL: config.baseURL,
                    pidfilePath: config.pidfileURL?.path))
            case .done(let done):
                outcome = done
            }
            removePidfile()
            runningProcess = nil
            startedAt = nil   // clearing rule (c): stop() always ends a tracked boot
            // Clearing rule (c) for the flight ticket too. LOCAL state only —
            // `stop()` is reachable from `evictWithoutCoordinator()`, and calling
            // the coordinator from there is what F7 forbids.
            flightTicket = nil
            lastTerminationOutcome = outcome

            let after = await status()
            if after.state == .healthy || after.state == .error {
                // Never report a stop that did not stop. Split on evidence we
                // already hold: a target confirmed dead while the port still
                // answers is a DIFFERENT (and likelier) story — a second
                // instance — than a target that survived SIGKILL.
                throw SidecarError.stopFailed(SidecarStop.stillAnsweringMessage(
                    outcome: outcome, baseURL: config.baseURL, vocabulary: Self.stopVocabulary))
            }
            return SidecarStatus(
                state: .installedNotRunning,
                message: SidecarStop.stoppedMessage(
                    outcome: outcome, discovery: discovery, vocabulary: Self.stopVocabulary),
                pid: pid
            )
        }
    }

    // MARK: - Stop: fact gathering (impure). The pure decision is SidecarStop's.

    /// Gathers the facts `SidecarStop.resolvePlan` reasons over. The health
    /// probe is ALWAYS consulted — that is the whole of m23-bb: `status()` asks
    /// the port and `stop()` used to ask only the pidfile, so the two disagreed
    /// about what "the sidecar" is.
    // Not `private`: headless tests call this directly to assert the EXACT
    // resolved plan against a real listener, rather than inferring the
    // decision from message text.
    func resolvedStopPlan() async -> SidecarStop.Plan {
        // The probe mapping is the one genuinely per-manager step: each manager
        // owns its own health-probe enum. Everything after it — which facts to
        // gather and under what conditions — belongs to SidecarStop.
        let probe: SidecarStop.Probe
        switch await probeHealth() {
        case .healthy: probe = .healthy
        case .malformed: probe = .respondingButUnparsable
        case .unreachable: probe = .unreachable
        }

        let pidfilePid = readPidfile()
        return SidecarStop.resolvePlan(SidecarStop.gatherFacts(
            probe: probe,
            pidfilePid: pidfilePid,
            pidfilePidAlive: pidfilePid.map { processAlive($0) } ?? false,
            baseURL: config.baseURL,
            identity: stopIdentity
        ))
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

// MARK: - Model lifecycle (m23-dl)

/// ACE-Step's `ModelEvicting` conformance.
///
/// ⚠️⚠️ **This method MUST NOT call back into `ModelLifecycleCoordinator`** — see
/// `ModelEvicting` (F7). It performs the raw stop through the existing, unchanged
/// `stop()` and reports evidence; the coordinator mutates residency afterwards.
/// That is also why `stop()` clears `flightTicket` locally instead of telling the
/// coordinator: the call would arrive from inside the coordinator's own eviction.
///
/// This is how the coordinator unloads ACE for all four reasons — the explicit
/// `ai.modelUnload`, unload-before-load, the ten-minute idle timer, and app quit.
extension SidecarManager: ModelEvicting {
    public nonisolated var modelID: ModelID { .aceStep }

    public func evictWithoutCoordinator() async throws -> ModelStopEvidence {
        // The existing stop path, unchanged. It throws `stopFailed` when the
        // sidecar is demonstrably still answering, and the coordinator turns a
        // thrown stop into evidence with every authority limb false.
        let status = try await stop()
        let answering: Bool
        switch await probeHealth() {
        case .unreachable: answering = false
        case .healthy, .malformed: answering = true
        }
        return ModelStopEvidence.gather(
            baseURL: config.baseURL,
            probeAnswering: answering,
            capturedTreePids: ModelStopEvidence.capturedTreePids(lastTerminationOutcome),
            detail: status.message)
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
        /// The model-lifecycle coordinator this manager books its boots with
        /// (m23-dl). Defaults to the process-wide instance.
        ///
        /// ⚠️ A coordinator with **nothing registered is entirely inert** —
        /// `resolveAdmission` admits with an empty plan, `commitAdmission`
        /// returns no ticket, and no file is written. That is what keeps the
        /// shared default safe for the many tests that construct a manager
        /// without ever registering a model (F2): registration happens once, in
        /// the app.
        public var lifecycle: ModelLifecycleCoordinator

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8001")!,
            acestepDir: URL?,
            logFileURL: URL = Configuration.defaultLogFileURL(),
            startupTimeoutSeconds: Double = 30,
            healthPollIntervalSeconds: Double = 0.5,
            healthProbeTimeoutSeconds: Double = 2.0,
            stopTimeoutSeconds: Double = 5.0,
            dryRun: Bool = false,
            lifecycle: ModelLifecycleCoordinator = .shared
        ) {
            self.baseURL = baseURL
            self.acestepDir = acestepDir
            self.logFileURL = logFileURL
            self.startupTimeoutSeconds = startupTimeoutSeconds
            self.healthPollIntervalSeconds = healthPollIntervalSeconds
            self.healthProbeTimeoutSeconds = healthProbeTimeoutSeconds
            self.stopTimeoutSeconds = stopTimeoutSeconds
            self.dryRun = dryRun
            self.lifecycle = lifecycle
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
