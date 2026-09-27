import Foundation
import os

// MARK: - Status

/// The states a poller of the install leg of `sing.sidecarStatus` can observe (design
/// `docs/design/2026-09-27-p2-sing-integration.md` §9's wire table, row 1 — install progress is
/// folded into the SAME status call as the sidecar's own state, not a separate verb).
///
/// `.cancelled` is its own state rather than a flavour of `.failed` — the
/// `SoundBankDownloadState`/`WhisperModelInstallState` precedent, restated: a failure asks the
/// user to check something (disk space, a network problem), a cancellation asks them nothing.
public enum SingingEngineInstallState: String, Sendable, Equatable, Codable {
    case idle
    case installing
    case succeeded
    case failed
    case cancelled
}

/// The one payload every install verb returns — start, poll and cancel all hand back the SAME
/// shape (the `WhisperModelInstallStatus`/`SoundBankDownloadStatus` decision, restated a third
/// time here on purpose: it is the house rule, not a coincidence twice).
public struct SingingEngineInstallStatus: Sendable, Equatable, Codable {
    public var state: SingingEngineInstallState
    /// True once `cancel()` has been asked for and the job has not yet unwound. Cancellation is
    /// REQUESTED synchronously and OBSERVED by polling — `state` stays `.installing` until
    /// install.sh's own trap actually finishes (staging gone, `@@cancelled` printed), so this flag
    /// is what lets a surface say "Cancelling…" honestly instead of claiming it already stopped.
    public var cancelRequested: Bool
    public var progress: SingingEngineInstallProgress?
    /// Present only on `.succeeded`.
    public var installedBytes: Int64?
    /// Present only on `.failed` / `.cancelled`.
    public var errorMessage: String?

    public init(
        state: SingingEngineInstallState, cancelRequested: Bool = false,
        progress: SingingEngineInstallProgress? = nil, installedBytes: Int64? = nil,
        errorMessage: String? = nil
    ) {
        self.state = state
        self.cancelRequested = cancelRequested
        self.progress = progress
        self.installedBytes = installedBytes
        self.errorMessage = errorMessage
    }

    /// Nothing has ever been started on this coordinator.
    public static let idle = SingingEngineInstallStatus(state: .idle)
}

// MARK: - Errors

public enum SingingEngineInstallCoordinatorError: Error, LocalizedError, Equatable {
    /// Refused, never queued and never coalesced — the `WhisperModelInstallCoordinator`/
    /// `SoundBankDownloadCoordinator` decision: queueing would silently reorder an agent's
    /// requests and coalescing would silently drop one, and either is worse than a same-round-trip
    /// refusal. Unlike those two, there is no variant/bank name to report alongside it: there is
    /// only ever one thing this coordinator can be installing.
    case installAlreadyInFlight
    /// Nothing to cancel. A refusal rather than a no-op success, so an agent that thinks it
    /// cancelled something learns it did not.
    case nothingInFlight

    public var errorDescription: String? {
        switch self {
        case .installAlreadyInFlight:
            return "Already installing the singing engine — poll sing.sidecarStatus and wait for "
                + "it to reach a terminal state (succeeded, failed or cancelled) before starting "
                + "again. Only one singing-engine install runs at a time."
        case .nothingInFlight:
            return "No singing-engine install is running, so there is nothing to cancel."
        }
    }
}

// MARK: - The coordinator

/// Sequences installs of the singing engine for the wire (item p2-sing-c): AT MOST ONE
/// `SingingEngineInstaller.install` in flight, a status snapshot pollers read, and a real cancel.
/// Modelled directly on `SoundBankDownloadCoordinator` (design §2.5's own citation:
/// `SoundBankDownloadCoordinator.swift:142–148` is the cancel rule this type follows) and
/// `WhisperModelInstallCoordinator` before it — see either's type doc for the fuller argument this
/// one does not repeat: why a coordinator must exist at all given the installer already works
/// (two callers could both start staging), why start-then-poll rather than await-the-whole-thing
/// (a 4–5 GB install is the "stretch render" shape, not the "clip.transcribe" shape), and why the
/// single-flight guard's check-and-set must have no `await` on either side of it (the actor's own
/// one-message-at-a-time processing IS the mutual exclusion, but only because of that ordering).
///
/// ## What is deliberately NOT this coordinator's job
///
/// Per the wire table (design §9 row 4), `sing.installEngine` itself is responsible for consent
/// ("`awaitingUserConsent` (from the wire)") and for short-circuiting when nothing needs to
/// happen ("`alreadyInstalled`") — both BEFORE this coordinator's `start()` is ever called. By the
/// time `start()` runs, the user has already said yes. This type has no consent state and no
/// "is it already installed" check of its own; it only ever does what `WhisperModelInstallCoordinator`
/// does — sequence calls to the installer and report on them.
///
/// ## `singDiskFull` / `singUnsupportedMac`, for whoever wires `sing.installEngine`
///
/// Both are `install.sh`'s `preflight` step, and both surface here as the SAME shape —
/// `SingingEngineInstallOutcome.failed(step: "preflight", message: "…")` — because install.sh
/// does not emit a distinct step name per preflight sub-check. Telling the two wire error codes
/// apart means matching on `errorMessage`'s text (it names free space in KB, or a macOS/arm64
/// requirement, in `install.sh`'s own words) — not on `step` alone.
public actor SingingEngineInstallCoordinator {

    /// Signature-compatible with `SingingEngineInstaller.install` — note NOT `throws`, unlike
    /// `WhisperModelInstallCoordinator.InstallFunction`/`SoundBankDownloadCoordinator.InstallFunction`:
    /// see `SingingEngineInstaller`'s own doc, "Why `install` never throws", for why that is a
    /// deliberate difference and not a mismatched copy of the precedent.
    public typealias InstallFunction = @Sendable (
        _ progress: @escaping @Sendable (SingingEngineInstallProgress) -> Void
    ) async -> SingingEngineInstallOutcome

    /// The real installer, wired with its own defaults — never restated here.
    public static let liveInstallFunction: InstallFunction = { progress in
        await SingingEngineInstaller().install(progress: progress)
    }

    private let installFunction: InstallFunction

    /// Written from the installer's own `Pipe` readability-handler thread, read from `status()` —
    /// the `WhisperModelInstallCoordinator` reasoning verbatim: recording each tick with
    /// `Task { await … }` would spawn one unstructured task per tick with no ordering guarantee
    /// between them, so back-to-back ticks could be recorded out of order. "The latest one wins"
    /// is exactly what a poller wants.
    private let latestProgressBox = OSAllocatedUnfairLock<SingingEngineInstallProgress?>(initialState: nil)

    /// `true` while an install is running; THE guard (see type docs).
    private var inFlight = false
    /// The in-flight job's handle — the whole reason cancel is possible.
    private var inFlightTask: Task<Void, Never>?
    /// Set by `cancel()`, cleared by the next `start`. Reported so a surface can say
    /// "Cancelling…" while install.sh's trap unwinds.
    private var cancelRequested = false
    /// The most recently finished install's outcome, kept until the next `start` replaces it.
    private var lastTerminal: SingingEngineInstallStatus?

    public init(installFunction: @escaping InstallFunction
                = SingingEngineInstallCoordinator.liveInstallFunction) {
        self.installFunction = installFunction
    }

    // MARK: - Start

    /// Start installing the singing engine. Returns as soon as the request is ACCEPTED — never
    /// waits for the install. Poll `status()` for progress and the terminal outcome; every
    /// failure shape, including a fast one like `badUsage`, is only discoverable by polling too,
    /// deliberately, so there is exactly one place (`SingingEngineInstaller.install`) deciding
    /// what counts as a failure.
    ///
    /// - Returns: The status snapshot immediately after acceptance — `.installing` with no
    ///   progress yet.
    /// - Throws: `SingingEngineInstallCoordinatorError.installAlreadyInFlight` when another
    ///   install is already running. Never queues, never coalesces.
    @discardableResult
    public func start() throws -> SingingEngineInstallStatus {
        // THE GUARD. No `await` above this line, and none below it in this method — see the type
        // docs' citation of the same rule stated fully in `WhisperModelInstallCoordinator`.
        if inFlight {
            throw SingingEngineInstallCoordinatorError.installAlreadyInFlight
        }
        inFlight = true
        cancelRequested = false
        // LOAD-BEARING (the `secondInstallDoesNotInheritStaleProgress` precedent): without this a
        // freshly started install reports the PREVIOUS one's step/bytes until its own first `@@`
        // line lands.
        latestProgressBox.withLock { $0 = nil }
        lastTerminal = nil

        let function = installFunction
        let box = latestProgressBox
        inFlightTask = Task { [weak self] in
            let outcome = await function { tick in box.withLock { $0 = tick } }
            await self?.finish(outcome: outcome)
        }
        return status()
    }

    /// Reached unconditionally once the spawned `Task`'s single `await` returns —
    /// `SingingEngineInstaller.install` never throws (see its own doc), so unlike
    /// `WhisperModelInstallCoordinator.finish` there is no `catch` path to also cover; every exit
    /// from `install` is a value here, in this one `switch`.
    private func finish(outcome: SingingEngineInstallOutcome) {
        inFlight = false
        inFlightTask = nil
        cancelRequested = false
        let progress = latestProgressBox.withLock { $0 }
        switch outcome {
        case .succeeded(let installedBytes):
            lastTerminal = SingingEngineInstallStatus(
                state: .succeeded, progress: progress, installedBytes: installedBytes)
        case .failed(let step, let message):
            lastTerminal = SingingEngineInstallStatus(
                state: .failed, progress: progress,
                errorMessage: "step '\(step)' failed: \(message)")
        case .alreadyRunning(let pid):
            // Only reachable if something OUTSIDE this coordinator started install.sh directly
            // (a stale run from a previous launch, or a bug) — this coordinator's OWN guard above
            // already refuses a second `start()` before a second install.sh is ever spawned.
            lastTerminal = SingingEngineInstallStatus(
                state: .failed, progress: progress,
                errorMessage: pid.map {
                    "another install.sh is already running outside this app (pid \($0))."
                } ?? "another install.sh is already running outside this app.")
        case .badUsage(let message):
            lastTerminal = SingingEngineInstallStatus(
                state: .failed, progress: progress, errorMessage: message)
        case .cancelled(let step):
            lastTerminal = SingingEngineInstallStatus(
                state: .cancelled, progress: progress,
                errorMessage: step.map { "cancelled during step '\($0)'." })
        case .crashed(let exitCode, let stderrTail):
            lastTerminal = SingingEngineInstallStatus(
                state: .failed, progress: progress,
                errorMessage: "install.sh exited with code \(exitCode), which is not one of its "
                    + "documented outcomes: \(stderrTail)")
        case .cannotLaunch(let reason):
            lastTerminal = SingingEngineInstallStatus(
                state: .failed, progress: progress, errorMessage: reason)
        }
    }

    // MARK: - Cancel

    /// Ask the in-flight install to stop. Returns the status right after the request — still
    /// `.installing`, now with `cancelRequested: true`. Poll until the state is terminal;
    /// `.cancelled` means the staging directory is gone, because `install.sh`'s own trap removes
    /// it before printing `@@cancelled` — `SoundBankDownloadCoordinator.cancel`'s "status races
    /// the filesystem" rule, restated (design §2.5's own citation of that exact doc comment).
    @discardableResult
    public func cancel() throws -> SingingEngineInstallStatus {
        guard inFlight, let task = inFlightTask else {
            throw SingingEngineInstallCoordinatorError.nothingInFlight
        }
        cancelRequested = true
        task.cancel()
        return status()
    }

    // MARK: - Status

    /// `.installing` (with the latest progress, which may be `nil` if nothing has ticked yet)
    /// while a job runs; else the most recent terminal outcome; else `.idle`.
    public func status() -> SingingEngineInstallStatus {
        if inFlight {
            return SingingEngineInstallStatus(
                state: .installing, cancelRequested: cancelRequested,
                progress: latestProgressBox.withLock { $0 })
        }
        return lastTerminal ?? .idle
    }
}
