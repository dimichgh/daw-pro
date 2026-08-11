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
    /// See `SidecarManager.lastTerminationOutcome` — identical semantics
    /// (m23-dl). The pre-kill captured tree, kept so post-stop liveness is
    /// answered from the capture that did the signalling rather than from a
    /// second, unreconstructible `ps` snapshot.
    private var lastTerminationOutcome: SidecarStop.TerminationOutcome?
    /// See `SidecarManager.flightTicket` — identical semantics and the identical
    /// F14 rule: the ticket's lifetime is the boot's, never `start()`'s scope.
    private var flightTicket: ModelLifecycleCoordinator.Ticket?

    public init(configuration: Configuration = .resolved()) {
        self.config = configuration
    }

    // MARK: - Status

    public func status() async -> VoiceConversionStatus {
        switch await probeHealth() {
        case .healthy(let info):
            startedAt = nil
            await releaseFlightTicket(healthy: true)   // clearing rule (a)
            let mitigation = await probeMitigation()
            return VoiceConversionStatus(
                state: .healthy,
                message: Self.healthyMessage(mitigationActive: mitigation.active),
                version: info.version,
                engine: info.engine,
                baseModelPresent: info.baseModelPresent,
                voiceCount: info.voiceCount,
                pid: readPidfile(),
                mitigationActive: mitigation.active,
                mitigationDetail: mitigation.detail
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
                // Clearing rule (b) — from `status()`, because `bootProgress()`
                // is synchronous and cannot await the coordinator (F14).
                await releaseFlightTicket(healthy: false)
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

        // ⚠️⚠️ F15, RULE 1 — RESOLVE BEFORE THE `dryRun` BRANCH, COMMIT AFTER IT.
        // The `SidecarManager` twin, and the same hazard: `commitAdmission`
        // SIGTERMs whatever the plan names for unload-before-load, so folding it
        // in here would let a dry run kill the user's live ACE sidecar.
        let admission = await config.lifecycle.resolveAdmission(.rvc)

        if config.dryRun {
            return VoiceConversionStatus(
                state: admission.isAdmitted ? .starting : .error,
                message: await config.lifecycle.dryRunDescription(
                    admission, for: .rvc, launch: plan.commandLine))
        }

        let ticket = try await config.lifecycle.commitAdmission(admission, for: .rvc)
        flightTicket = ticket
        do {
            return try await spawnAndPoll(plan)
        } catch {
            // Every throwing exit after the mint gives the ticket back (F14).
            await releaseFlightTicket(healthy: false)
            throw error
        }
    }

    /// The pre-m23-dl body of `start()`, split out so the admission wiring above
    /// has one place to catch a throw and hand the flight ticket back.
    private func spawnAndPoll(_ plan: SidecarLaunchPlan) async throws -> VoiceConversionStatus {
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory
        // m23-di-2a: redirect the facade's voice store OUT of the read-only
        // scripts/rvc/ checkout. `server.py:66` resolves `VOICES_DIR` from
        // `RVC_VOICES_DIR` (falling back to its own in-checkout
        // `runtime/voices/`), and `run.sh` never sets that var itself (only
        // `RVC_RUNTIME_DIR`/`RVC_API_PORT`) — checked before this landed,
        // nothing else in `Sources/` set it either. MERGE onto the inherited
        // environment (a nil `process.environment` would otherwise inherit
        // it implicitly; setting the dictionary explicitly requires copying
        // the rest across too, or every other env var this process depends
        // on — PATH, HOME, API keys read elsewhere — silently vanishes for
        // the child). `VoiceModelImport.voicesDirectory` is the SAME path an
        // import lands in, so a voice imported before or after this boot is
        // found by the facade's own `_scan_voices()` either way.
        //
        // m23-fo-2: the same merge now also PREPENDS `PYTHONPATH` so the
        // facade picks up our `sitecustomize.py` and wraps `RVC_MLX.infer`
        // with `mx.clear_cache()`. `run.sh` is left completely unchanged (it
        // still owns its pidfile and double-start guard, and
        // `SidecarStop.Identity.rvc` still matches the process it execs) —
        // one environment variable is the entire seam. Built as a pure
        // function so prepend-not-clobber is tested without spawning.
        //
        // m23-fp: the same merge now ALSO sets `RVC_OUT_DIR`. `server.py:67`
        // resolves `OUT_DIR` from it and nothing in `Sources/` set it before,
        // so every shipped conversion wrote its wav into
        // `scripts/rvc/runtime/out/` — inside the read-only fence. This
        // redirects those writes to app-owned storage; it creates nothing
        // under `scripts/rvc/`. Which paths get armed is `spawnEnvironment`'s
        // job (one expression, testable without spawning) precisely so this
        // call site cannot arm the wrong ones.
        process.environment = config.spawnEnvironment(base: ProcessInfo.processInfo.environment)
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
        if let flightTicket {
            await config.lifecycle.recordBootPid(flightTicket, pid: process.processIdentifier)
        }

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

    /// See `SidecarManager.releaseFlightTicket` — identical, including the rule
    /// that `stop()` must NOT call it (F7).
    private func releaseFlightTicket(healthy: Bool) async {
        guard let ticket = flightTicket else { return }
        flightTicket = nil
        await config.lifecycle.admitted(ticket, healthy: healthy)
    }

    private static func startupTimeoutMessage(
        timeoutSeconds: Int, elapsedSeconds: Int, logPath: String
    ) -> String {
        "RVC voice-conversion sidecar did not report healthy within \(timeoutSeconds)s — it's "
            + "likely still booting (\(elapsedSeconds)s so far); poll vc.sidecarStatus again, or "
            + "check \(logPath)."
    }

    // MARK: - Stop (m23-bb-1)
    //
    // ⚠️ THE DEFECT THIS REPLACED, and it was a STRUCTURAL TWIN of m23-bb:
    // `status()` resolved "the sidecar" from the HEALTH PROBE while `stop()`
    // resolved it from the PIDFILE alone, via two early returns that never
    // consulted the probe —
    //
    //     guard let pid = readPidfile() else { …"is not running (no pidfile found)" }
    //     guard processAlive(pid) else { removePidfile(); …"was not running (stale pidfile removed)" }
    //
    // — so a healthy RVC facade on 8002 whose pidfile had gone stale was told
    // it "was not running", its pidfile was deleted, and it kept running.
    //
    // The DECISION is not made here. It lives once in `SidecarStop`, shared
    // verbatim with `SidecarManager`: copying the ACE planner would have
    // recreated the very defect class this fixes (two resolutions of one
    // question, drifting until one lies). Only two things below are
    // RVC-specific — the identity predicate and the wording.

    /// How this sidecar's own processes are recognised.
    ///
    /// ⚠️ `scripts/rvc/run.sh` ends in `exec "$VENV_PY" "$SCRIPT_DIR/server.py"`
    /// — it EXECs, so unlike ACE-Step's `uv run` → python topology there is no
    /// parent/child split: the pid `run.sh` wrote into `.rvc.pid` IS uvicorn.
    /// The shared planner's descendant capture and ancestor climb therefore
    /// find nothing to do here, which costs nothing and defends if that
    /// launcher ever stops `exec`ing.
    private var stopIdentity: SidecarStop.Identity {
        .rvc(directoryPath: config.rvcDir?.path)
    }

    /// The wording every shared stop message speaks in.
    static let stopVocabulary = SidecarStop.Vocabulary.rvc

    @discardableResult
    public func stop() async throws -> VoiceConversionStatus {
        guard config.pidfileURL != nil else {
            return VoiceConversionStatus(
                state: .notInstalled,
                message: "RVC voice-conversion sidecar directory is not resolvable — nothing to stop."
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
            return VoiceConversionStatus(
                state: report.state, message: report.message, pid: report.pid)
        }

        switch plan {
        case .notRunning(let reason):
            // The ONLY branch allowed to say "not running" — and it is
            // reachable only when the health probe AGREES the sidecar is not
            // answering (m23-bb's floor rule, inherited whole).
            //
            // Deviation 1 (see this type's doc comment) is preserved: WE remove
            // the pidfile even though `run.sh` wrote it, so a later `status()`
            // reads a clean installedNotRunning rather than misreading a stale
            // file as a failed boot.
            if reason.removesPidfile { removePidfile() }
            runningProcess = nil
            startedAt = nil
            // Clearing rule (c) for the flight ticket. LOCAL state only — this
            // method is reachable from `evictWithoutCoordinator()`, and calling
            // the coordinator from there is what F7 forbids.
            flightTicket = nil
            lastTerminationOutcome = nil   // nothing was signalled, so there is no tree
            return VoiceConversionStatus(
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
            startedAt = nil
            flightTicket = nil   // clearing rule (c), local only (F7)
            lastTerminationOutcome = outcome

            let after = await status()
            if after.state == .healthy || after.state == .error {
                // Never report a stop that did not stop.
                throw SidecarError.stopFailed(SidecarStop.stillAnsweringMessage(
                    outcome: outcome, baseURL: config.baseURL, vocabulary: Self.stopVocabulary))
            }
            return VoiceConversionStatus(
                state: .installedNotRunning,
                message: SidecarStop.stoppedMessage(
                    outcome: outcome, discovery: discovery, vocabulary: Self.stopVocabulary),
                pid: pid
            )
        }
    }

    // MARK: - Stop: fact gathering (impure). The pure decision is SidecarStop's.

    /// Gathers the facts `SidecarStop.resolvePlan` reasons over. The health
    /// probe is ALWAYS consulted — that is the whole of m23-bb-1.
    // Not `private`: headless tests call this directly to assert the EXACT
    // resolved plan against a real listener, rather than inferring the
    // decision from message text.
    func resolvedStopPlan() async -> SidecarStop.Plan {
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

    // MARK: - m23-fo mitigation probe

    /// PURE — no I/O. Maps one `GET /v1/_dawpro/mitigation` outcome onto the
    /// tri-state. Split out of the probe for the same reason
    /// `classifyFallbackBoot` is: the mapping is the part with the subtle
    /// rule, and it should be testable without a socket.
    ///
    /// `statusCode == nil` means the request never completed (transport error
    /// or timeout).
    ///
    /// ⚠️ **`200` IS NOT AUTOMATICALLY `true`.** The hook is deliberately
    /// fail-safe: it never fails the facade's boot, so it can be loaded and
    /// serving this very route while its engine patch failed (e.g. a future
    /// MLX without `clear_cache` — `gate_m23fo_mechanism.py` phase G
    /// exercises exactly that, and it answers 200 with
    /// `enginePatched: false`). Reporting `true` there would tell a user they
    /// are protected when they are not, which is the one failure this field
    /// exists to prevent. So `true` requires `enginePatched == true`, and
    /// BOTH ways of being unprotected — no route at all, or a route reporting
    /// a failed patch — map to `false` with distinguishing detail.
    ///
    /// Deliberately `internal` (the tests reach it via `@testable import`), for
    /// the same reason as `healthyMessage` above: it is `status()`'s private
    /// classifier, not a seam any other module calls.
    static func classifyMitigation(
        statusCode: Int?, body: Data?
    ) -> (active: Bool?, detail: String?) {
        guard let statusCode else {
            return (nil, "the mitigation probe did not complete (timeout or transport error).")
        }
        if statusCode == 404 {
            return (
                false,
                "this facade has no m23-fo mitigation hook (GET /v1/_dawpro/mitigation "
                + "answered 404) — it was almost certainly started outside the app."
            )
        }
        guard (200..<300).contains(statusCode) else {
            return (nil, "the mitigation probe answered HTTP \(statusCode).")
        }
        guard let body,
              let parsed = try? JSONSerialization.jsonObject(with: body),
              let top = parsed as? [String: Any],
              let data = top["data"] as? [String: Any] else {
            return (nil, "the mitigation route answered, but not in the expected envelope.")
        }
        let patched = (data["enginePatched"] as? NSNumber)?.boolValue
            ?? (data["enginePatched"] as? Bool)
        // ⚠️ ABSENT is not FALSE. An envelope without `enginePatched` is not
        // our route reporting a failed patch — it is something else answering
        // this path, and we do not know. Only an EXPLICIT `false` is a
        // positive report that the user is unprotected; guessing `false` from
        // a missing field would put an accusatory warning in `message` on the
        // strength of an assumption.
        guard let patched else {
            return (nil, "the mitigation route answered without an enginePatched field.")
        }
        if patched {
            let calls = (data["clearCacheCalls"] as? NSNumber)?.intValue
                ?? (data["clearCacheCalls"] as? Int)
            return (
                true,
                "mx.clear_cache() runs before every conversion"
                + (calls.map { " (\($0) so far)" } ?? "") + "."
            )
        }
        let reason = (data["error"] as? String) ?? "no reason reported"
        return (
            false,
            "the m23-fo hook is loaded but its engine patch did NOT apply: \(reason)"
        )
    }

    /// One extra loopback round-trip, on the `.healthy` path only, bounded by
    /// the SAME timeout as the health probe so a hanging route can never make
    /// `status()` cost more than a `/health` timeout already does. Failing
    /// fast into `nil` is the designed behaviour, not a fallback.
    private func probeMitigation() async -> (active: Bool?, detail: String?) {
        var request = URLRequest(
            url: config.baseURL.appendingPathComponent("v1/_dawpro/mitigation"))
        request.httpMethod = "GET"
        request.timeoutInterval = config.healthProbeTimeoutSeconds
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return Self.classifyMitigation(
                statusCode: (response as? HTTPURLResponse)?.statusCode, body: data)
        } catch {
            return Self.classifyMitigation(statusCode: nil, body: nil)
        }
    }

    /// The healthy-state sentence. ⭐ When we KNOW the facade is unprotected
    /// the message has to say so and name the item — this is the only signal
    /// a user gets in the one real hole: `start()` returns early at `:190-191`
    /// when the sidecar is already healthy, so an app attaching to a
    /// hand-started `run.sh` never sets `PYTHONPATH` and nothing else would
    /// ever mention it. `nil` deliberately says nothing: we did not find out,
    /// and inventing a warning from ignorance is its own dishonesty.
    ///
    /// ⚠️ **REACH, MEASURED — THIS SENTENCE IS AGENT-VISIBLE ONLY.** It travels
    /// `vc.sidecarStatus` → MCP fine, but `VoicePanelModel.banner` returns
    /// `nil` for `.healthy` (the panel is ready, so it shows no banner at all),
    /// which means the healthy `message` — warning and all — is never rendered
    /// to a human. Surfacing it in the panel is a UI behaviour change nobody
    /// has approved, so it is deliberately NOT done here; it is filed rather
    /// than silently assumed. Do not cite this string as the user's signal
    /// without changing `VoicePanelModel` first.
    ///
    /// Internal, not `public`, unlike `Configuration.childEnvironment`: this is
    /// copy-shaping consumed only by `status()` and the tests, whereas
    /// `childEnvironment` is a seam the app's spawn path calls across.
    static func healthyMessage(mitigationActive: Bool?) -> String {
        guard mitigationActive == false else {
            return "RVC voice-conversion sidecar is running and healthy."
        }
        return "RVC voice-conversion sidecar is running, but it is NOT protected against "
            + "m23-fo: repeated conversions will degrade to saturated output after a few "
            + "runs. Stop it and start it again from the app (vc.sidecarStop, then "
            + "vc.sidecarStart) so the mitigation is applied."
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

// MARK: - Model lifecycle (m23-dl)

/// RVC's `ModelEvicting` conformance — the `SidecarManager` twin, line for line.
///
/// ⚠️⚠️ **MUST NOT call back into `ModelLifecycleCoordinator`** — see
/// `ModelEvicting` (F7). This is how the coordinator unloads RVC for the
/// explicit verb, for unload-before-load, and on app quit; RVC ships with no
/// idle timer of its own (see `ModelRegistry.rvc`).
extension VoiceConversionManager: ModelEvicting {
    public nonisolated var modelID: ModelID { .rvc }

    public func evictWithoutCoordinator() async throws -> ModelStopEvidence {
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
        /// See `SidecarManager.Configuration.lifecycle` — identical, including
        /// the "nothing registered ⇒ entirely inert" rule that keeps the shared
        /// default safe for tests.
        public var lifecycle: ModelLifecycleCoordinator

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8002")!,
            rvcDir: URL?,
            startupTimeoutSeconds: Double = 30,
            healthPollIntervalSeconds: Double = 0.5,
            healthProbeTimeoutSeconds: Double = 2.0,
            stopTimeoutSeconds: Double = 5.0,
            dryRun: Bool = false,
            lifecycle: ModelLifecycleCoordinator = .shared
        ) {
            self.baseURL = baseURL
            self.rvcDir = rvcDir
            self.startupTimeoutSeconds = startupTimeoutSeconds
            self.healthPollIntervalSeconds = healthPollIntervalSeconds
            self.healthProbeTimeoutSeconds = healthProbeTimeoutSeconds
            self.stopTimeoutSeconds = stopTimeoutSeconds
            self.dryRun = dryRun
            self.lifecycle = lifecycle
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
        /// m23-fo-2 — the directory holding our `sitecustomize.py` mitigation
        /// hook, put on the child's `PYTHONPATH` so the facade wraps
        /// `RVC_MLX.infer` with `mx.clear_cache()` (m23-fo: repeated
        /// conversion otherwise degrades to saturation by about the 4th call).
        ///
        /// `DAWPRO_RVC_MITIGATION_DIR` wins if set; otherwise it is the
        /// SIBLING of `rvcDir` — deliberately derived rather than an
        /// independent default, so the two cannot be misconfigured apart from
        /// each other. `rvcDir` nil ⇒ nil, exactly like `logFileURL`.
        ///
        /// ⚠️ This is a directory WE own. It is not, and must never become, a
        /// path under `scripts/rvc/` — that tree is read-only.
        /// Set by `resolved(environment:)` from `DAWPRO_RVC_MITIGATION_DIR`,
        /// exactly as `baseURL` is set from `RVC_API_URL` — the environment is
        /// read in ONE place (that factory) rather than stored on this struct.
        public var mitigationDirOverride: URL?

        public var mitigationDirURL: URL? {
            if let mitigationDirOverride { return mitigationDirOverride }
            return rvcDir?
                .deletingLastPathComponent()
                .appendingPathComponent("rvc-mitigation")
        }
        /// The hook file itself. ⚠️ `scripts/rvc-mitigation/` holds EXACTLY
        /// ONE file by design — it goes on `sys.path` ahead of site-packages,
        /// so a second module there would shadow a same-named module for the
        /// whole interpreter.
        public var mitigationModuleURL: URL? {
            mitigationDirURL?.appendingPathComponent("sitecustomize.py")
        }

        /// PURE — no process, no I/O. The child environment for the facade,
        /// split out of the spawn site so the one rule that is easy to get
        /// wrong is unit-testable without spawning anything. Mirrors how
        /// `classifyFallbackBoot` and `SidecarStop.resolvePlan` are already
        /// split out of their call sites.
        ///
        /// ⚠️⚠️ **PREPEND, NEVER CLOBBER.** `PYTHONPATH` is not ours: the
        /// inherited value can carry anything the user's shell put there, and
        /// overwriting it would break the child in a way that looks like our
        /// hook misbehaving. Ours goes FIRST (so `sitecustomize` resolves to
        /// our file rather than a same-named module further down the path),
        /// the inherited value follows.
        ///
        /// A nil `mitigationDir` leaves `PYTHONPATH` EXACTLY as inherited —
        /// including the "present but empty string" case, which is a distinct
        /// dictionary state from "absent" and a real shell environment.
        /// Refusing to launch is `resolveLaunchPlan()`'s job and ONLY its job;
        /// one refusal point, not two.
        /// m23-fp adds `outDir` -> `RVC_OUT_DIR`. REQUIRED, no default: a
        /// defaulted parameter is exactly how the m23-fo-2 hook nearly shipped
        /// un-armed ("until this item nothing in the app set the one
        /// environment variable that arms it, so no user reached it"), and the
        /// point of this variable is that the facade stops writing its output
        /// into the read-only `scripts/rvc/` checkout.
        ///
        /// An EMPTY `outDir` leaves `RVC_OUT_DIR` unset rather than setting it
        /// to `""`. That matters: `server.py:67` does `Path(os.environ.get(
        /// "RVC_OUT_DIR", ...))`, and `Path("")` is `.` — the facade's cwd,
        /// which it `chdir`s to `SRC_DIR` INSIDE the fence. Unset means the
        /// facade's own in-checkout default, which is merely the pre-m23-fp
        /// behaviour. Unreachable in practice (the real value comes from
        /// `AppDirectories`), pinned by a test so it stays that way.
        public static func childEnvironment(
            base: [String: String],
            voicesDir: String,
            mitigationDir: String?,
            outDir: String
        ) -> [String: String] {
            var environment = base
            environment["RVC_VOICES_DIR"] = voicesDir
            if !outDir.isEmpty { environment["RVC_OUT_DIR"] = outDir }
            guard let mitigationDir, !mitigationDir.isEmpty else { return environment }
            let inherited = base["PYTHONPATH"] ?? ""
            environment["PYTHONPATH"] =
                [mitigationDir, inherited].filter { !$0.isEmpty }.joined(separator: ":")
            return environment
        }

        /// The environment the spawner actually hands the facade — ONE
        /// expression, so the spawn site has nothing left to get wrong.
        ///
        /// m23-fp built this seam deliberately. Testing `childEnvironment`
        /// alone proves the merge RULE and says nothing about whether the app
        /// arms it with the right values; every one of those assertions can be
        /// green while `spawnAndPoll` passes a path that never leaves the
        /// fence. This closes that gap while staying spawn-free and
        /// write-free (it resolves directory URLs; it creates nothing — the
        /// facade `mkdir`s `RVC_OUT_DIR` itself at `server.py:325`, and
        /// `VoiceConversionOutput.capture` creates the capture home).
        public func spawnEnvironment(base: [String: String]) -> [String: String] {
            Self.childEnvironment(
                base: base,
                voicesDir: VoiceModelImport.voicesDirectory.path,
                mitigationDir: mitigationDirURL?.path,
                outDir: VoiceConversionOutput.sidecarOutputDirectory.path)
        }

        /// Pure path resolution — no process spawned. Throws `.notInstalled`
        /// (never crashes) when the directory, its `run.sh`, or (m23-fo-2) our
        /// mitigation hook can't be found.
        ///
        /// ⚠️ **`SidecarError.notInstalled` is a SEMANTIC STRETCH for the hook
        /// limb and that reuse is deliberate**: the sidecar IS installed; it is
        /// OUR module that is missing. A dedicated case would cost an audit of
        /// every exhaustive `switch` over this public enum, for a condition a
        /// user resolves the same way they resolve the others — by fixing the
        /// checkout. The teaching message names the actual path and the item,
        /// so the message (which is what a human reads) is never wrong even
        /// though the case name is imprecise.
        ///
        /// ⚠️ Called at `start()`'s `:193` — BEFORE the `dryRun` branch — so a
        /// DRY RUN THROWS TOO. That is correct, not an oversight: a dry run
        /// that answers "would launch X" when the real thing would refuse is a
        /// lie, and the whole point of a dry run is to be believed.
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
            // m23-fo-2 — REFUSE TO SPAWN AT ALL without the hook. Booting
            // without it produces a facade that silently saturates from about
            // the 4th conversion (m23-fo), which is far worse for a user than
            // an honest refusal naming the missing file.
            guard let hook = mitigationModuleURL else {
                throw SidecarError.notInstalled(
                    "the m23-fo mitigation hook directory could not be resolved — set "
                    + "DAWPRO_RVC_MITIGATION_DIR, or run the app from inside the daw-pro "
                    + "repo checkout (expects scripts/rvc-mitigation/sitecustomize.py "
                    + "beside scripts/rvc/).")
            }
            guard FileManager.default.fileExists(atPath: hook.path) else {
                throw SidecarError.notInstalled(
                    "the m23-fo mitigation hook is missing at \(hook.path) — without it "
                    + "repeated voice conversion degrades to saturated output by about the "
                    + "4th conversion, so the sidecar is not started. Restore "
                    + "scripts/rvc-mitigation/sitecustomize.py (it is the only file that "
                    + "directory may contain), or set DAWPRO_RVC_MITIGATION_DIR to where "
                    + "it lives.")
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
            // m23-fo-2 — same shape as RVC_API_URL above.
            if let override = environment["DAWPRO_RVC_MITIGATION_DIR"], !override.isEmpty {
                config.mitigationDirOverride =
                    URL(fileURLWithPath: override).standardizedFileURL
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
