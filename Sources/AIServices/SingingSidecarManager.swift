import CryptoKit
import Darwin
import DAWCore
import Foundation

/// Wire/model type for `sing.sidecarStatus` / `sing.sidecarStart` / `sing.sidecarStop` (item
/// p2-sing-c). A dedicated TWIN of `SidecarStatus`/`VoiceConversionStatus`, not a reuse — the
/// `VoiceConversionStatus` doc's own "twin, not reuse" note applies verbatim: `SidecarState`
/// (`SidecarStatus.swift`) has no `needsUpdate` case, and adding one there would touch a shared
/// enum three other types depend on for a state that is unique to an engine with its own update
/// story (design §2.8's `lockSha256` check).
public enum SingingSidecarState: String, Codable, Sendable, Equatable {
    case notInstalled
    case needsUpdate
    case installedNotRunning
    case starting
    case healthy
    case error
}

extension SingingSidecarState {
    /// The shared `SidecarState` (`SidecarStatus.swift`) has no `needsUpdate` case, so the shared
    /// `SidecarStop` planner — which speaks `SidecarState` — can never produce it either. Every
    /// one of ITS outcomes maps onto one of this type's other five cases one-to-one.
    init(_ shared: SidecarState) {
        switch shared {
        case .notInstalled: self = .notInstalled
        case .installedNotRunning: self = .installedNotRunning
        case .starting: self = .starting
        case .healthy: self = .healthy
        case .error: self = .error
        }
    }
}

public struct SingingSidecarStatus: Codable, Sendable, Equatable {
    public var state: SingingSidecarState
    /// Always present, human-readable and actionable.
    public var message: String
    public var pid: Int32?
    /// Only populated when `state == .starting`.
    public var startingForSeconds: Int?
    /// The rest are only populated when `state == .healthy`, straight off the facade's own
    /// `GET /health` (design §2.4). `ffmpegMajor` is present on the REAL facade only — SB's
    /// measured deviation 2: FFmpeg is a hard runtime requirement `torchcodec` needs, and its
    /// absence must surface in plain words, which is why this field exists at all rather than
    /// being folded into `message` alone.
    public var facadeVersion: Int?
    public var commit: String?
    public var weightsRevision: String?
    public var weightsBytes: UInt64?
    public var device: String?
    public var loadSeconds: Double?
    public var mpsDriverBytes: UInt64?
    public var rendered: Int?
    public var ffmpegMajor: Int?

    public init(
        state: SingingSidecarState, message: String, pid: Int32? = nil,
        startingForSeconds: Int? = nil, facadeVersion: Int? = nil, commit: String? = nil,
        weightsRevision: String? = nil, weightsBytes: UInt64? = nil, device: String? = nil,
        loadSeconds: Double? = nil, mpsDriverBytes: UInt64? = nil, rendered: Int? = nil,
        ffmpegMajor: Int? = nil
    ) {
        self.state = state
        self.message = message
        self.pid = pid
        self.startingForSeconds = startingForSeconds
        self.facadeVersion = facadeVersion
        self.commit = commit
        self.weightsRevision = weightsRevision
        self.weightsBytes = weightsBytes
        self.device = device
        self.loadSeconds = loadSeconds
        self.mpsDriverBytes = mpsDriverBytes
        self.rendered = rendered
        self.ffmpegMajor = ffmpegMajor
    }
}

/// How the last stop of this sidecar happened — the level of "yield vs crash" classification the
/// CURRENT `ModelEvicting` protocol actually permits.
///
/// ⚠️ **It never names WHICH model SoulX yielded to**, unlike design §2.7 R3's
/// `lastStopReason = .yieldedTo(<model>)`. `ModelEvicting.evictWithoutCoordinator()` takes no
/// parameters (confirmed at `ModelLifecycleCoordinator.swift` — `performEviction` KNOWS the
/// `EvictionReason` and does not pass it to the evictor), so this manager genuinely cannot learn
/// who is booting from inside that call. `.evictedByCoordinator` is deliberately generic: it is
/// the honest primitive available at this layer, and it is unambiguous in the one case that
/// matters for a mid-job yield — see `lastStopClassification()`'s doc.
public enum SingingStopReason: Sendable, Equatable {
    /// `stop()` was called directly (`sing.sidecarStop`, or the app quitting through it).
    case explicit
    /// `evictWithoutCoordinator()` ran — the coordinator asked this model to make way. Reached
    /// from admission (another model is booting), an explicit `ai.modelUnload`, an idle timeout,
    /// or app shutdown; the current protocol does not distinguish those from inside this type.
    case evictedByCoordinator
    /// The runaway watchdog killed the tree. **FIX NOW #8 (architect review):** `trigger` is the
    /// structured fact a caller can switch on; `detail` stays the human reason, for messages
    /// only — never parsed back, since `ModelMemory.formatGB` rounds to one decimal in 10^9
    /// units and a footprint just over a binary cap can print a figure that reads back under it.
    case watchdog(trigger: SingingWatchdogTrigger, detail: String)
}

public protocol SingingSidecarManaging: Sendable {
    func status() async -> SingingSidecarStatus
    @discardableResult
    func start() async throws -> SingingSidecarStatus
    @discardableResult
    func stop() async throws -> SingingSidecarStatus
}

/// Lifecycle manager for the local singing-engine sidecar (item p2-sing-c — design
/// `docs/design/2026-09-27-p2-sing-integration.md` §2.6, port 8004). Mirrors
/// `VoiceConversionManager`'s split from `SingingSynthesisClient` (process lifecycle vs. the
/// render call), and reuses the SAME shared stop planner (`SidecarStop`, `SidecarProcessDiscovery`)
/// those two managers already share — `Identity`/`Vocabulary` are built through their general
/// memberwise initialisers rather than new named factories, so nothing in `SidecarStopPlanner.swift`
/// needed to change for a third sidecar to exist.
///
/// ## Two deliberate departures from the `VoiceConversionManager` shape
///
/// 1. **Runtime and scripts are SEPARATE directories**, not one (design §2.3): `scriptsDir`
///    (`scripts/sing/`, read-only, or the bundle's `Contents/Resources/sing/`) vs. `runtimeDir`
///    (`<Application Support>/DAWPro/SingingEngine/`, profile-aware via `AppDirectories`, unlike
///    RVC's own `installedRuntimeDir()`). `resolveLaunchPlan()`'s `run.sh` lives in the former and
///    is handed the latter through `SING_RUNTIME_DIR`.
/// 2. **A runaway watchdog** (`SingingSidecarWatchdog`) is armed on every healthy boot and
///    disarmed on every stop. It is NOT an admission gate (m23-dl's scope cut, restated in that
///    type's own doc) — it only cleans up a sidecar that grew past its cap or that the system
///    reports Critical pressure against.
///
/// ## Why a watchdog kill does not call back into this actor (read before "fixing" this)
///
/// The watchdog's `kill` closure is a plain, synchronous, self-contained SIGKILL
/// (`SingingSidecarWatchdog.killTree`) — it does **not** reach back into this manager to update
/// `lastStopReason`, `runningProcess` or the pidfile. Two reasons, not one:
///   * **it cannot, at construction time.** The closure is built inside `init`, before `self` is
///     fully initialised, and an actor may not capture `self` in an escaping closure before `init`
///     completes;
///   * **it does not need to.** `SingingSidecarWatchdog` already records `lastKillReason` itself
///     (actor-isolated, so two concurrent samples can never race writing it), and this manager's
///     bookkeeping only has to be honest the NEXT time anything calls into it — exactly the
///     existing `bootProgress()` pattern (`if let runningProcess, !runningProcess.isRunning { … }`
///     already reconciles a crash lazily, on the next read, rather than being pushed a
///     notification the instant the process dies). `lastStopClassification()` below does the same
///     reconciliation for a watchdog kill: it prefers an explicit `lastStopReason`, then falls back
///     to the watchdog's own record, then reports "unclassified" (which reads as a crash from the
///     outside — it is, structurally, the same "we found it dead and don't know why" case).
public actor SingingSidecarManager: SingingSidecarManaging {
    public let config: Configuration

    private var startedAt: Date?
    private var runningProcess: Process?
    private var lastTerminationOutcome: SidecarStop.TerminationOutcome?
    private var flightTicket: ModelLifecycleCoordinator.Ticket?
    /// Set only by `performStop`'s two callers (`stop()`, `evictWithoutCoordinator()`) — see the
    /// type doc for why the watchdog's OWN kill never writes here directly.
    private var lastStopReason: SingingStopReason?

    private let watchdog: SingingSidecarWatchdog
    /// Owned only when the configuration did not inject its own pressure reader. FIX NOW #6
    /// (architect review): this was previously true only by ACCIDENT for most tests and FALSE
    /// for `underCapNeverKills` specifically (it never injected one, so it owned a REAL
    /// `MemoryPressureObserver`, exposed to genuine system memory pressure, same as the shipped
    /// app) — every `SingingSidecarManagerTests` test now gets `{ false }` injected by its
    /// shared `testConfiguration` helper, overridden explicitly where a test wants real pressure
    /// behavior. See `MemoryPressureObserver`'s doc for why it is UNVERIFIED against genuine
    /// Critical pressure.
    private let pressureObserver: MemoryPressureObserver?

    public init(configuration: Configuration = .resolved()) {
        self.config = configuration
        let observer: MemoryPressureObserver?
        if configuration.watchdogReadMemoryPressureCritical == nil {
            observer = MemoryPressureObserver()
        } else {
            observer = nil
        }
        self.pressureObserver = observer
        self.watchdog = SingingSidecarWatchdog(configuration: SingingSidecarWatchdog.Configuration(
            capBytes: configuration.watchdogCapBytes,
            pollIntervalSeconds: configuration.watchdogPollIntervalSeconds,
            sampleFootprintBytes: configuration.watchdogSampleFootprintBytes
                ?? SingingSidecarWatchdog.liveFootprintBytes,
            readMemoryPressureCritical: configuration.watchdogReadMemoryPressureCritical
                ?? { observer?.readCritical() ?? false },
            sleepSeconds: configuration.watchdogSleepSeconds,
            // FIX NOW #4: the real `killTree` must re-check identity before it signals anything.
            identity: SingingSidecarManager.stopIdentity(scriptsDir: configuration.scriptsDir)))
    }

    // MARK: - Status

    public func status() async -> SingingSidecarStatus {
        switch await probeHealth() {
        case .ready(let info):
            startedAt = nil
            await releaseFlightTicket(healthy: true)
            if let pid = runningProcess?.processIdentifier ?? readPidfile() {
                await armWatchdog(rootPid: pid)
            }
            return SingingSidecarStatus(
                state: .healthy,
                message: Self.healthyMessage(ffmpegMajor: info.ffmpegMajor),
                pid: runningProcess?.processIdentifier ?? readPidfile(),
                facadeVersion: info.facadeVersion, commit: info.commit,
                weightsRevision: info.weightsRevision, weightsBytes: info.weightsBytes,
                device: info.device, loadSeconds: info.loadSeconds,
                mpsDriverBytes: info.mpsDriverBytes, rendered: info.rendered,
                ffmpegMajor: info.ffmpegMajor)
        case .loading:
            return startingStatus()
        case .modelError(let detail):
            return SingingSidecarStatus(
                state: .error,
                message: "The singing engine failed to load: \(detail). Check "
                    + "\(config.logFileURL?.path ?? "its log"), then call sing.sidecarStart to retry.")
        case .malformed:
            return SingingSidecarStatus(
                state: .error,
                message: "The singing engine responded, but its /health reply could not be "
                    + "parsed — check \(config.logFileURL?.path ?? "its log").")
        case .unreachable:
            switch bootProgress() {
            case .inProgress(let since, let pid):
                let elapsed = Self.elapsedSeconds(since: since)
                return SingingSidecarStatus(
                    state: .starting,
                    message: Self.startingMessage(elapsedSeconds: elapsed),
                    pid: pid, startingForSeconds: elapsed)
            case .failedBoot:
                await releaseFlightTicket(healthy: false)
                return SingingSidecarStatus(
                    state: .installedNotRunning,
                    message: "The singing engine isn't responding and its process appears to "
                        + "have exited while starting — check \(config.logFileURL?.path ?? "its log"), "
                        + "then call sing.sidecarStart to retry.")
            case .notStarting:
                return installedStateStatus()
            }
        }
    }

    private func startingStatus() -> SingingSidecarStatus {
        switch bootProgress() {
        case .inProgress(let since, let pid):
            let elapsed = Self.elapsedSeconds(since: since)
            return SingingSidecarStatus(
                state: .starting, message: Self.startingMessage(elapsedSeconds: elapsed),
                pid: pid, startingForSeconds: elapsed)
        case .failedBoot, .notStarting:
            // The health probe just told us something IS running (loading), even though this
            // instance's own bootProgress bookkeeping does not (yet) agree — e.g. a fresh manager
            // attached to a boot another instance started. Report honestly rather than inventing
            // an elapsed time we do not have.
            return SingingSidecarStatus(
                state: .starting,
                message: "The singing engine is starting (loading the model) \u{2014} poll "
                    + "sing.sidecarStatus again shortly.",
                pid: readPidfile())
        }
    }

    private static func startingMessage(elapsedSeconds: Int) -> String {
        "The singing engine is starting (\(elapsedSeconds)s so far) \u{2014} poll "
            + "sing.sidecarStatus again shortly."
    }

    private static func elapsedSeconds(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt).rounded()))
    }

    private static func healthyMessage(ffmpegMajor: Int?) -> String {
        guard ffmpegMajor != nil else {
            return "The singing engine is running and ready."
        }
        return "The singing engine is running and ready (FFmpeg \(ffmpegMajor!))."
    }

    private func installedStateStatus() -> SingingSidecarStatus {
        // Stale pidfile cleanup (design §2.8.7): a pidfile naming a dead pid is removed here,
        // not just left for `run.sh`'s own next-start check to clear.
        if let pid = readPidfile(), !processAlive(pid) {
            removePidfile()
        }
        guard let marker = config.installMarkerURL,
              FileManager.default.fileExists(atPath: marker.path)
        else {
            return SingingSidecarStatus(
                state: .notInstalled,
                message: "The singing engine is not installed. Call sing.installEngine to start "
                    + "the one-time download (about 7 GB) \u{2014} it asks first; nothing "
                    + "downloads until you say yes.")
        }
        if isOutOfDate() {
            return SingingSidecarStatus(
                state: .needsUpdate,
                message: "The singing engine needs an update \u{2014} call sing.installEngine to "
                    + "bring it current.")
        }
        return SingingSidecarStatus(
            state: .installedNotRunning,
            message: "The singing engine is installed but not running \u{2014} call "
                + "sing.sidecarStart.")
    }

    /// `true` only when BOTH the marker and the shipped lock can be read and hashed and they
    /// DISAGREE. Anything unreadable reports `false` rather than inventing an update nobody can
    /// act on — the same "cannot verify, do not warn" rule `VoiceConversionManager`'s mitigation
    /// probe uses for its own tri-state.
    private func isOutOfDate() -> Bool {
        guard let marker = config.installMarkerURL,
              let scriptsDir = config.scriptsDir,
              let markerData = try? Data(contentsOf: marker),
              let markerJSON = (try? JSONSerialization.jsonObject(with: markerData)) as? [String: Any],
              let installedLockSha = markerJSON["lockSha256"] as? String
        else { return false }
        let lockURL = scriptsDir.appendingPathComponent("requirements.lock")
        guard let shippedLockSha = try? Self.sha256Hex(ofFileAt: lockURL) else { return false }
        return installedLockSha.lowercased() != shippedLockSha.lowercased()
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Boot progress (mirrors VoiceConversionManager's M10-b design; own copy — see that
    // type's doc comment for why this is not shared across managers)

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

    /// Pure — no I/O.
    static func classifyFallbackBoot(pid: Int32, modifiedAt: Date, isAlive: Bool) -> BootProgress {
        isAlive ? .inProgress(startedAt: modifiedAt, pid: pid) : .failedBoot
    }

    // MARK: - Start

    @discardableResult
    public func start() async throws -> SingingSidecarStatus {
        let current = await status()
        if current.state == .healthy { return current }

        let plan = try config.resolveLaunchPlan()
        // BEFORE admission: a doomed boot (something foreign already on the port) must never
        // evict ACE/RVC for nothing (design §2.8.6).
        try checkPortNotForeign()

        let admission = await config.lifecycle.resolveAdmission(.soulxSinger)
        if config.dryRun {
            return SingingSidecarStatus(
                state: admission.isAdmitted ? .starting : .error,
                message: await config.lifecycle.dryRunDescription(
                    admission, for: .soulxSinger, launch: plan.commandLine))
        }

        let ticket = try await config.lifecycle.commitAdmission(admission, for: .soulxSinger)
        flightTicket = ticket
        lastStopReason = nil
        await watchdog.clearLastKillReason()
        do {
            return try await spawnAndPoll(plan)
        } catch {
            await releaseFlightTicket(healthy: false)
            throw error
        }
    }

    /// A foreign listener on the target port would make `run.sh` spawn and exit 3 (double-start
    /// guard) — but only AFTER commitAdmission already evicted whatever else was resident. Caught
    /// here, before that, so a doomed boot costs nothing. `nil` when our OWN pidfile already names
    /// the listener (nothing foreign).
    private func checkPortNotForeign() throws {
        guard let port = SidecarProcessDiscovery.port(of: config.baseURL) else { return }
        guard case .listeners(let pids) = SidecarProcessDiscovery.listeners(onPort: port) else {
            return
        }
        let ours = readPidfile()
        let foreign = pids.filter { $0 != ours }
        guard !foreign.isEmpty else { return }
        let detail = foreign.map { pid in
            "pid \(pid) (\(SidecarProcessDiscovery.args(ofPid: pid) ?? "command line unavailable"))"
        }.joined(separator: ", ")
        throw SidecarError.launchFailed(
            "port \(port) is already in use by something that is not the singing engine: "
                + "\(detail). Stop it, or set SING_API_URL to point at a different port.")
    }

    private func spawnAndPoll(_ plan: SidecarLaunchPlan) async throws -> SingingSidecarStatus {
        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.currentDirectoryURL = plan.workingDirectory
        process.environment = config.spawnEnvironment(base: ProcessInfo.processInfo.environment)

        do {
            try process.run()
        } catch {
            throw SidecarError.launchFailed(
                "failed to launch \(plan.commandLine): \(error.localizedDescription)")
        }
        let bootStartedAt = Date()
        startedAt = bootStartedAt
        runningProcess = process
        if let flightTicket {
            await config.lifecycle.recordBootPid(flightTicket, pid: process.processIdentifier)
        }
        // FIX NOW #3 (architect review): arm at SPAWN, not only once `.healthy` — otherwise the
        // watchdog cannot see a runaway during the LOAD window (design R6: SoulX's load landing
        // on top of a busy ACE). Safe to call unconditionally thanks to `arm`'s own idempotence
        // for the same pid: every later `.ready` probe inside the poll loop below re-arms this
        // exact pid and is a no-op.
        await armWatchdog(rootPid: process.processIdentifier)

        let deadline = bootStartedAt.addingTimeInterval(config.startupTimeoutSeconds)
        while Date() < deadline {
            if !process.isRunning {
                startedAt = nil
                runningProcess = nil
                throw SidecarError.launchFailed(
                    "the singing engine's process exited during startup \u{2014} check "
                        + "\(config.logFileURL?.path ?? "its log").")
            }
            let probed = await status()
            if probed.state == .healthy {
                await armWatchdog(rootPid: process.processIdentifier)
                return probed
            }
            if probed.state == .error {
                // The process is up and answering, but the model failed to load — nothing more
                // to poll for; surface it now rather than spinning until the timeout.
                return probed
            }
            try? await Task.sleep(nanoseconds: UInt64(config.healthPollIntervalSeconds * 1_000_000_000))
        }
        let elapsed = Self.elapsedSeconds(since: bootStartedAt)
        return SingingSidecarStatus(
            state: .starting,
            message: "The singing engine did not report ready within "
                + "\(Int(config.startupTimeoutSeconds))s \u{2014} it's likely still loading the "
                + "model (\(elapsed)s so far); poll sing.sidecarStatus again, or check "
                + "\(config.logFileURL?.path ?? "its log")",
            pid: process.processIdentifier, startingForSeconds: elapsed)
    }

    private func armWatchdog(rootPid: Int32) async {
        pressureObserver?.start()
        await watchdog.arm(rootPid: rootPid)
    }

    private func releaseFlightTicket(healthy: Bool) async {
        guard let ticket = flightTicket else { return }
        flightTicket = nil
        await config.lifecycle.admitted(ticket, healthy: healthy)
    }

    // MARK: - Stop

    /// ⚠️ `scripts/sing/run.sh` `exec`s the venv (or, for tests, system) python — no
    /// `run.sh`-then-child split, so the pidfile's pid IS the listener, and the shared planner's
    /// descendant capture has nothing to reap for THIS process. It still runs (cheaply) because
    /// the facade may itself have spawned something, and because the identical rule for RVC (which
    /// also has no such split) is what makes it safe to reuse this planner verbatim.
    private var stopIdentity: SidecarStop.Identity {
        Self.stopIdentity(scriptsDir: config.scriptsDir)
    }

    /// Static so `init` can build the watchdog's `Configuration.identity` (FIX NOW #4) before
    /// `self` is fully initialized — `stopIdentity` (above) stays the instance-facing name every
    /// other call site already uses.
    static func stopIdentity(scriptsDir: URL?) -> SidecarStop.Identity {
        SidecarStop.Identity(
            argsPattern: #"(^|/)sing/(server|stub_server)\.py(\s|$)"#,
            directoryPath: scriptsDir?.path)
    }

    private static let stopVocabulary = SidecarStop.Vocabulary(
        subject: "Singing voice sidecar",
        identityName: "the singing voice sidecar",
        directoryEnvVar: "DAWPRO_SING_SCRIPTS_DIR",
        stopVerb: "sing.sidecarStop")

    @discardableResult
    public func stop() async throws -> SingingSidecarStatus {
        try await performStop(classification: .explicit)
    }

    /// The ONE home for actually stopping this sidecar — `stop()` and `evictWithoutCoordinator()`
    /// both call it, differing only in the classification they record. See the type doc for why
    /// the watchdog's OWN kill does not also go through here.
    private func performStop(classification: SingingStopReason) async throws -> SingingSidecarStatus {
        guard config.pidfileURL != nil else {
            return SingingSidecarStatus(
                state: .notInstalled,
                message: "The singing engine's runtime directory is not resolvable \u{2014} "
                    + "nothing to stop.")
        }

        let plan = await resolvedStopPlan()

        if config.dryRun {
            let report = SidecarStop.dryRunReport(
                for: plan, isInstalled: isInstalled(), vocabulary: Self.stopVocabulary,
                baseURL: config.baseURL, pidfilePath: config.pidfileURL?.path)
            return SingingSidecarStatus(
                state: SingingSidecarState(report.state), message: report.message, pid: report.pid)
        }

        switch plan {
        case .notRunning(let reason):
            if reason.removesPidfile { removePidfile() }
            runningProcess = nil
            startedAt = nil
            flightTicket = nil
            lastTerminationOutcome = nil
            lastStopReason = classification
            await watchdog.disarm()
            return SingingSidecarStatus(
                state: SingingSidecarState(
                    SidecarStop.notRunningState(reason, isInstalled: isInstalled())),
                message: SidecarStop.notRunningMessage(reason, vocabulary: Self.stopVocabulary),
                pid: reason.pid)

        case .refuse(let refusal):
            // Nothing was signalled and nothing changed — do not record a classified stop for a
            // stop that did not happen.
            throw SidecarError.stopFailed(SidecarStop.refusalMessage(
                refusal, vocabulary: Self.stopVocabulary, baseURL: config.baseURL,
                pidfilePath: config.pidfileURL?.path))

        case .terminate(let pid, let discovery):
            // FIX NOW #1 (architect review): recorded BEFORE the signal goes out, not after
            // `terminateTree` returns -- the manager actor is free for that whole `await`
            // (`terminateTree` is a nonisolated `static … async`), so a caller that reads
            // `lastStopClassification()` the instant the process dies must never see `nil` and
            // read that as an unrequested crash. `.refused` mutates nothing (SidecarStop invariant
            // 2), so it restores the previous value.
            let previousStopReason = lastStopReason
            lastStopReason = classification
            let outcome: SidecarStop.TerminationOutcome
            switch await SidecarStop.terminateTree(
                target: pid, discovery: discovery, identity: stopIdentity,
                stopTimeoutSeconds: config.stopTimeoutSeconds
            ) {
            case .refused(let refusal):
                lastStopReason = previousStopReason
                throw SidecarError.stopFailed(SidecarStop.refusalMessage(
                    refusal, vocabulary: Self.stopVocabulary, baseURL: config.baseURL,
                    pidfilePath: config.pidfileURL?.path))
            case .done(let done):
                outcome = done
            }
            removePidfile()
            runningProcess = nil
            startedAt = nil
            flightTicket = nil
            lastTerminationOutcome = outcome
            await watchdog.disarm()

            // FIX NOW #7 (architect review, Q3): decide "still up" from the PROBE directly, not
            // from the derived `SingingSidecarState` -- SoulX's probe has a `.loading` case that
            // `status()` maps to `.starting` (neither `.healthy` nor `.error`), so the old check
            // let `stop()` report success while something still answered "loading" on the port.
            // Also check `outcome.targetSurvived`: a target that survived SIGKILL (stuck in an
            // uninterruptible wait) and no longer answers HTTP must not be reported "stopped".
            let answering: Bool
            let probed = await probeHealth()
            switch probed {
            case .unreachable: answering = false
            case .ready, .loading, .modelError, .malformed: answering = true
            }
            if answering || outcome.targetSurvived {
                throw SidecarError.stopFailed(SidecarStop.stillAnsweringMessage(
                    outcome: outcome, baseURL: config.baseURL, vocabulary: Self.stopVocabulary))
            }
            return SingingSidecarStatus(
                state: .installedNotRunning,
                message: SidecarStop.stoppedMessage(
                    outcome: outcome, discovery: discovery, vocabulary: Self.stopVocabulary),
                pid: pid)
        }
    }

    /// PURE FACTS, IMPURE GATHERING — the health probe is ALWAYS consulted (the m23-bb rule).
    /// Not `private`: tests call this directly to assert the exact resolved plan.
    func resolvedStopPlan() async -> SidecarStop.Plan {
        let probe: SidecarStop.Probe
        switch await probeHealth() {
        case .ready, .loading, .modelError: probe = .healthy
        case .malformed: probe = .respondingButUnparsable
        case .unreachable: probe = .unreachable
        }
        let pidfilePid = readPidfile()
        return SidecarStop.resolvePlan(SidecarStop.gatherFacts(
            probe: probe, pidfilePid: pidfilePid,
            pidfilePidAlive: pidfilePid.map { processAlive($0) } ?? false,
            baseURL: config.baseURL, identity: stopIdentity))
    }

    /// The classification of the last stop THIS manager instance knows about.
    ///
    /// `nil` means "unclassified" — nobody here ever asked for a stop, and the watchdog never
    /// killed anything, yet the process is (or was found to be) not running. From the outside
    /// that reads as a crash, and the type deliberately does not invent a `.crashed` case to say
    /// so more loudly than the evidence supports: "we did not do this on purpose" is all that is
    /// actually known.
    ///
    /// Order matters: an explicit classification (set by `performStop`) always wins over the
    /// watchdog's own record, because a redundant watchdog sample landing during a graceful stop
    /// (SIGTERM already sent, grace period still running) must never relabel a deliberate stop as
    /// a runaway kill.
    public func lastStopClassification() async -> SingingStopReason? {
        if let lastStopReason { return lastStopReason }
        if let trigger = await watchdog.lastKillTrigger, let reason = await watchdog.lastKillReason {
            return .watchdog(trigger: trigger, detail: reason)
        }
        return nil
    }

    /// FIX NOW #6 (architect review): lets a test prove the watchdog's loop actually RAN, not
    /// just that nothing happened because nothing looked — the `disarmBeforeFirstSamplePrevents
    /// Sampling` test is the existing "a control sits at the input of the stage it controls"
    /// precedent this reuses rather than duplicates: that test proves 0 samples when disarmed
    /// before the first poll; this accessor lets OTHER tests assert `> 0` when armed normally.
    func watchdogSamplesTaken() async -> UInt64 {
        await watchdog.samplesTaken
    }

    // MARK: - Health probe

    private struct HealthInfo: Sendable {
        var facadeVersion: Int?
        var commit: String?
        var weightsRevision: String?
        var weightsBytes: UInt64?
        var device: String?
        var loadSeconds: Double?
        var mpsDriverBytes: UInt64?
        var rendered: Int?
        var ffmpegMajor: Int?
    }

    private enum HealthProbe: Sendable {
        case ready(HealthInfo)
        case loading(HealthInfo)
        case modelError(String)
        case malformed
        case unreachable
    }

    /// The facade's own `GET /health` (`scripts/sing/server.py`/`stub_server.py`, both through
    /// `singlib/http.py`). ⚠️ UNLIKE ACE-Step/RVC there is NO `{"data": {...}}` envelope — the
    /// health dict IS the top-level body (verified against `singlib/http.py`'s
    /// `self._send(200, self.server.backend.health())`).
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
              let status = top["status"] as? String
        else {
            return .malformed
        }
        let engine = top["engine"] as? [String: Any]
        let info = HealthInfo(
            facadeVersion: (top["facadeVersion"] as? NSNumber)?.intValue,
            commit: engine?["commit"] as? String,
            weightsRevision: engine?["weightsRevision"] as? String,
            weightsBytes: (engine?["weightsBytes"] as? NSNumber)?.uint64Value,
            device: top["device"] as? String,
            loadSeconds: (top["loadSeconds"] as? NSNumber)?.doubleValue,
            mpsDriverBytes: (top["mpsDriverBytes"] as? NSNumber)?.uint64Value,
            rendered: (top["rendered"] as? NSNumber)?.intValue,
            ffmpegMajor: (top["ffmpegMajor"] as? NSNumber)?.intValue)
        switch status {
        case "ready": return .ready(info)
        case "loading": return .loading(info)
        case "error": return .modelError((top["error"] as? String) ?? "unknown error")
        default: return .malformed
        }
    }

    private func isInstalled() -> Bool {
        guard let marker = config.installMarkerURL else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    // MARK: - Pidfile

    private func readPidfile() -> Int32? {
        guard let url = config.pidfileURL,
              let contents = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
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

extension SingingSidecarManager: ModelEvicting {
    public nonisolated var modelID: ModelID { .soulxSinger }

    /// ⚠️⚠️ MUST NOT call `resolveAdmission`/`commitAdmission`/`admitted`/`unload`/`noteJob*` —
    /// `ModelEvicting`'s own rule (F7): this runs INSIDE the coordinator's `performEviction`, and
    /// re-entering it here would observe residency state half-updated.
    public func evictWithoutCoordinator() async throws -> ModelStopEvidence {
        let status = try await performStop(classification: .evictedByCoordinator)
        let answering: Bool
        switch await probeHealth() {
        case .unreachable: answering = false
        case .ready, .loading, .modelError, .malformed: answering = true
        }
        return ModelStopEvidence.gather(
            baseURL: config.baseURL, probeAnswering: answering,
            capturedTreePids: ModelStopEvidence.capturedTreePids(lastTerminationOutcome),
            detail: status.message)
    }
}

// MARK: - sing.sidecarStop's evidence (p2-sing-e part 2)

extension SingingSidecarManager {
    /// `sing.sidecarStop` (design §6 row 3): an explicit `stop()` (classified `.explicit`, never as an eviction),
    /// then the SAME three authority limbs `evictWithoutCoordinator()` gathers — the port, the health probe, and
    /// the pre-kill captured tree — so the wire's reply is evidence, not a claim.
    public func stopReportingEvidence() async throws -> SingingStopReport {
        let status = try await performStop(classification: .explicit)
        let answering: Bool
        switch await probeHealth() {
        case .unreachable: answering = false
        case .ready, .loading, .modelError, .malformed: answering = true
        }
        let evidence = ModelStopEvidence.gather(
            baseURL: config.baseURL, probeAnswering: answering,
            capturedTreePids: ModelStopEvidence.capturedTreePids(lastTerminationOutcome),
            detail: status.message)
        return SingingStopReport(status: status, evidence: evidence)
    }
}

// MARK: - Configuration

extension SingingSidecarManager {
    public struct Configuration: Sendable {
        public var baseURL: URL
        /// `scripts/sing/` — read-only text (`run.sh`, `server.py`, `stub_server.py`,
        /// `requirements.lock`, …). `nil` when unresolvable, mirroring `VoiceConversionManager`'s
        /// `rvcDir`.
        public var scriptsDir: URL?
        /// `<Application Support>/DAWPro/SingingEngine/` — the writable runtime (design §2.3),
        /// profile-aware via `AppDirectories` (unlike RVC's own hand-rolled
        /// `installedRuntimeDir()`).
        public var runtimeDir: URL?
        /// The user's singing-voice references (`AppDirectories.singingVoices`) — added to
        /// `SING_ALLOWED_ROOTS` so an own-voice request's `referencePath`/`outputPath` can resolve.
        public var voicesDir: URL?
        /// The rendered-phrase cache (`AppDirectories.singingCache`) — added to
        /// `SING_ALLOWED_ROOTS` for the same reason.
        public var cacheDir: URL?
        /// 120 s (design §2.6): measured cold start is 13.7-20 s under load, and this is a wide
        /// margin above that, not a tight one.
        public var startupTimeoutSeconds: Double
        public var healthPollIntervalSeconds: Double
        public var healthProbeTimeoutSeconds: Double
        public var stopTimeoutSeconds: Double
        public var dryRun: Bool
        public var lifecycle: ModelLifecycleCoordinator
        public var logFileURL: URL?

        /// 16 GiB in production (design §2.6: about twice the measured 60 s peak of 8.32 GiB).
        /// **INJECTABLE** — this is the field the design's own gate names explicitly; tests use a
        /// 512 MB cap against the stub's 600 MB `balloon` fault.
        public var watchdogCapBytes: UInt64
        public var watchdogPollIntervalSeconds: Double
        /// `nil` (the shipped default) means "use `SingingSidecarWatchdog.liveFootprintBytes`" —
        /// resolved in `SingingSidecarManager.init`'s body, never here: that real default is an
        /// internal symbol, and an internal symbol cannot appear in a `public init`'s default
        /// argument VALUE (only the type `internal actor SingingSidecarWatchdog` is internal; this
        /// closure's own type, `@Sendable (Int32) -> UInt64?`, is perfectly public). A test that
        /// provides a closure here is exercising the pure `decide` loop against a scripted
        /// footprint, never the real `ModelMemory.treeUsage` sampler.
        public var watchdogSampleFootprintBytes: (@Sendable (Int32) -> UInt64?)?
        /// `nil` (the shipped default) means "use the manager's own long-lived
        /// `MemoryPressureObserver`". A test that provides a closure here is exercising the PURE
        /// decision and the actor loop; it never touches the real, unverified observer.
        public var watchdogReadMemoryPressureCritical: (@Sendable () -> Bool)?
        public var watchdogSleepSeconds: @Sendable (Double) async -> Void

        /// TEST-ONLY passthrough, merged onto the child's environment LAST. Production code must
        /// never populate this — it exists solely so a test can ask `run.sh` for
        /// `SING_USE_STUB=1` / `SING_STUB_*` / `SING_TEST_HOOKS=1` without a second spawn path.
        public var testExtraEnvironment: [String: String]

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:8004")!,
            scriptsDir: URL?,
            runtimeDir: URL?,
            voicesDir: URL? = nil,
            cacheDir: URL? = nil,
            startupTimeoutSeconds: Double = 120,
            healthPollIntervalSeconds: Double = 0.5,
            healthProbeTimeoutSeconds: Double = 2.0,
            stopTimeoutSeconds: Double = 5.0,
            dryRun: Bool = false,
            lifecycle: ModelLifecycleCoordinator = .shared,
            logFileURL: URL? = nil,
            watchdogCapBytes: UInt64 = 16 * 1_073_741_824,
            watchdogPollIntervalSeconds: Double = 0.25,
            watchdogSampleFootprintBytes: (@Sendable (Int32) -> UInt64?)? = nil,
            watchdogReadMemoryPressureCritical: (@Sendable () -> Bool)? = nil,
            watchdogSleepSeconds: (@Sendable (Double) async -> Void)? = nil,
            testExtraEnvironment: [String: String] = [:]
        ) {
            self.baseURL = baseURL
            self.scriptsDir = scriptsDir
            self.runtimeDir = runtimeDir
            self.voicesDir = voicesDir
            self.cacheDir = cacheDir
            self.startupTimeoutSeconds = startupTimeoutSeconds
            self.healthPollIntervalSeconds = healthPollIntervalSeconds
            self.healthProbeTimeoutSeconds = healthProbeTimeoutSeconds
            self.stopTimeoutSeconds = stopTimeoutSeconds
            self.dryRun = dryRun
            self.lifecycle = lifecycle
            self.logFileURL = logFileURL ?? Self.defaultLogFileURL()
            self.watchdogCapBytes = watchdogCapBytes
            self.watchdogPollIntervalSeconds = watchdogPollIntervalSeconds
            self.watchdogSampleFootprintBytes = watchdogSampleFootprintBytes
            self.watchdogReadMemoryPressureCritical = watchdogReadMemoryPressureCritical
            // `nil` = the real sleep, supplied HERE and never as the default argument (an async
            // default-argument closure miscompiles across modules in Swift 6.3.3; see
            // `ModelLifecycleCoordinator.init` and `scripts/gates/async-default-dup.py`).
            self.watchdogSleepSeconds = watchdogSleepSeconds ?? { seconds in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            }
            self.testExtraEnvironment = testExtraEnvironment
        }

        public var pidfileURL: URL? { runtimeDir?.appendingPathComponent("run/sing.pid") }
        public var installMarkerURL: URL? { runtimeDir?.appendingPathComponent("install.json") }

        public static func defaultLogFileURL() -> URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DAWPro/sing-sidecar.log")
        }

        /// PURE. The child environment `run.sh` needs from the caller (everything else — cache
        /// redirects, `HF_HUB_OFFLINE`, unsetting `PYTHONPATH`/`PYTHONHOME` — `run.sh` sets
        /// itself; unlike RVC's `run.sh`, it does not rely on the Swift side for hermeticity).
        static func childEnvironment(
            base: [String: String], runtimeDir: String, port: UInt16, allowedRoots: String,
            logFile: String?, extra: [String: String]
        ) -> [String: String] {
            var environment = base
            environment["SING_RUNTIME_DIR"] = runtimeDir
            environment["SING_PORT"] = String(port)
            if !allowedRoots.isEmpty { environment["SING_ALLOWED_ROOTS"] = allowedRoots }
            if let logFile, !logFile.isEmpty { environment["SING_LOG_FILE"] = logFile }
            // The scripts run from a code-signed, read-only bundle: a `__pycache__` written into
            // `Contents/Resources/sing/singlib/` would break the seal (same rule as RVC).
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            for (key, value) in extra { environment[key] = value }
            return environment
        }

        func spawnEnvironment(base: [String: String]) -> [String: String] {
            let port = SidecarProcessDiscovery.port(of: baseURL) ?? 8004
            let roots = [voicesDir?.path, cacheDir?.path].compactMap { $0 }.joined(separator: ":")
            return Self.childEnvironment(
                base: base, runtimeDir: runtimeDir?.path ?? "", port: port, allowedRoots: roots,
                logFile: logFileURL?.path, extra: testExtraEnvironment)
        }

        public func resolveLaunchPlan() throws -> SidecarLaunchPlan {
            guard let scriptsDir else {
                throw SidecarError.notInstalled(
                    "the singing engine's scripts could not be found \u{2014} set "
                        + "DAWPRO_SING_SCRIPTS_DIR, or run the app from inside the daw-pro repo "
                        + "checkout (expects scripts/sing/run.sh).")
            }
            let runScript = scriptsDir.appendingPathComponent("run.sh")
            guard FileManager.default.fileExists(atPath: runScript.path) else {
                throw SidecarError.notInstalled(
                    "run.sh not found at \(runScript.path) \u{2014} the singing engine's scripts "
                        + "are missing or the checkout is incomplete.")
            }
            guard runtimeDir != nil else {
                throw SidecarError.notInstalled(
                    "the singing engine's runtime directory could not be resolved.")
            }
            return SidecarLaunchPlan(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [runScript.path],
                workingDirectory: scriptsDir)
        }

        /// `DAWPRO_SING_SCRIPTS_DIR` wins; else walk up from a repo-relative anchor looking for
        /// `Package.swift` and use `<repo>/scripts/sing`; else the app bundle's
        /// `Contents/Resources/sing` (`bundle.sh` copies it there before `codesign`, design §2.3).
        public static func resolveScriptsDir(environment: [String: String]) -> URL? {
            resolveScriptsDir(
                environment: environment,
                anchors: [
                    URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                    CommandLine.arguments.first.map {
                        URL(fileURLWithPath: $0).resolvingSymlinksInPath().deletingLastPathComponent()
                    },
                ].compactMap { $0 },
                bundleResourceURLs: [
                    Bundle.main.resourceURL,
                    Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
                ].compactMap { $0 })
        }

        /// The seam behind `resolveScriptsDir(environment:)` (W8-BSG): the anchors and bundle
        /// resource directories are parameters so a test can pass a temp tree. Order: override
        /// env, then the repo walk-up from each anchor, then each bundle `Resources/sing`.
        static func resolveScriptsDir(
            environment: [String: String], anchors: [URL], bundleResourceURLs: [URL]
        ) -> URL? {
            if let override = environment["DAWPRO_SING_SCRIPTS_DIR"], !override.isEmpty {
                return URL(fileURLWithPath: override).standardizedFileURL
            }
            for anchor in anchors {
                if let found = walkUpForScriptsDir(from: anchor) { return found }
            }
            for base in bundleResourceURLs {
                let candidate = base.appendingPathComponent("sing")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            return nil
        }

        private static func walkUpForScriptsDir(from start: URL) -> URL? {
            var dir = start
            for _ in 0..<8 {
                if FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("Package.swift").path
                ) {
                    return dir.appendingPathComponent("scripts/sing")
                }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
            return nil
        }

        /// `DAWPRO_SING_RUNTIME_DIR` wins; else `AppDirectories.applicationSupport(.singingEngine)`
        /// — already profile-aware (design §8 F17: a staging E2E that exercises uninstall can
        /// never delete the user's real install), so unlike `resolveScriptsDir` there is no
        /// separate "installed" fallback to invent.
        public static func resolveRuntimeDir(environment: [String: String]) -> URL? {
            if let override = environment["DAWPRO_SING_RUNTIME_DIR"], !override.isEmpty {
                return URL(fileURLWithPath: override).standardizedFileURL
            }
            return AppDirectories.applicationSupport(.singingEngine)
        }

        public static func resolved(
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Configuration {
            var config = Configuration(
                scriptsDir: resolveScriptsDir(environment: environment),
                runtimeDir: resolveRuntimeDir(environment: environment),
                voicesDir: AppDirectories.applicationSupport(.singingVoices),
                cacheDir: AppDirectories.applicationSupport(.singingCache))
            if let override = environment["SING_API_URL"], let url = URL(string: override) {
                config.baseURL = url
            }
            return config
        }
    }
}
