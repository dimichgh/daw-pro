import Foundation
import os

// MARK: - Status

/// One of four states a poller of `ai.speechModelInstallStatus` can observe.
/// `.idle` and `.installing` never carry `descriptor`/`errorMessage`;
/// `.succeeded`/`.failed` always do. `progress` may be `nil` in ANY state —
/// including `.succeeded` — because a download that never ticked its
/// callback must still reach a terminal state (see
/// `WhisperModelInstallCoordinator`'s type docs).
public enum WhisperModelInstallState: String, Sendable, Equatable, Codable {
    case idle
    case installing
    case succeeded
    case failed
}

/// The one payload both `ai.installSpeechModel` and
/// `ai.speechModelInstallStatus` return — deliberately the SAME shape, so a
/// polling agent does not have to learn two response bodies for one job.
public struct WhisperModelInstallStatus: Sendable, Equatable, Codable {
    public var state: WhisperModelInstallState
    /// What was passed to `start(variant:)` for the install this status
    /// describes — the raw request string (e.g. `"tiny.en"`), NOT necessarily
    /// the canonical on-disk directory name. The canonical name only exists
    /// once `descriptor` does (`descriptor.variantDirectoryName`).
    public var variantDirectoryNameRequested: String?
    public var progress: WhisperModelInstallProgress?
    public var descriptor: WhisperModelDescriptor?
    public var errorMessage: String?

    public init(
        state: WhisperModelInstallState,
        variantDirectoryNameRequested: String? = nil,
        progress: WhisperModelInstallProgress? = nil,
        descriptor: WhisperModelDescriptor? = nil,
        errorMessage: String? = nil
    ) {
        self.state = state
        self.variantDirectoryNameRequested = variantDirectoryNameRequested
        self.progress = progress
        self.descriptor = descriptor
        self.errorMessage = errorMessage
    }

    /// Nothing has ever been started on this coordinator.
    public static let idle = WhisperModelInstallStatus(state: .idle)
}

// MARK: - Errors

public enum WhisperModelInstallCoordinatorError: Error, LocalizedError, Equatable {
    /// Refused, never queued and never coalesced (m23-n3b's decision):
    /// queueing would silently reorder an agent's requests, and coalescing
    /// would silently drop one — either failure mode is worse than a same-
    /// round-trip refusal naming what is already running.
    case installAlreadyInFlight(variantRequested: String, variantInFlight: String)

    public var errorDescription: String? {
        switch self {
        case .installAlreadyInFlight(let requested, let inFlight):
            return "Already installing \"\(inFlight)\" — poll ai.speechModelInstallStatus and "
                + "wait for it to reach a terminal state (succeeded or failed) before starting "
                + "\"\(requested)\". Only one speech-model install runs at a time."
        }
    }
}

// MARK: - The coordinator

/// Coordinates installs of Whisper speech-recognition models for the wire
/// (m23-n3b): AT MOST ONE `WhisperModelInstaller.install` call in flight at a
/// time, plus a status snapshot pollers can read. See that type for the
/// installer itself; this actor only sequences and reports on calls to it.
///
/// ## Why this exists, given `WhisperModelInstaller.install` already works
///
/// `WhisperModelInstaller` (m23-n3a) is a plain `Sendable` STRUCT with no
/// isolation of its own — nothing before this actor stopped two concurrent
/// callers from both observing "not installed yet", both staging under
/// distinct UUIDs, and both moving hundreds of megabytes into the same
/// `Models/<variant>/` destination, with the second `moveItem` landing on a
/// destination the first has already populated. Exposing `install(...)` as a
/// wire verb an AI agent can call twice (once by mistake, once as a retry
/// before it thinks to poll) makes that a REAL scenario, not a theoretical
/// one — so this actor's whole job is: never let a second install start
/// while one is running, and remember what happened for the poller.
///
/// ## Why "start, then poll" and not "await the whole thing"
///
/// `clip.transcribe` (m23-n2b) BLOCKS because its precedent (`vc.convertVocals`)
/// blocks and there is no in-app job registry for it. A multi-hundred-MB model
/// download is a different shape: the in-tree precedent for a LOCALLY-OWNED
/// long job with PULL-based status is the stretch render
/// (`AudioEngine.clipStretchStatus`) — a detached job whose status is read,
/// never awaited. `ai.installSpeechModel` starts the job and returns
/// immediately; `ai.speechModelInstallStatus` polls this actor's `status()`.
///
/// ## The guard: why it must be synchronous, and why "it's an actor" is not enough
///
/// `start(variant:)` sets `variantInFlight` **before its own first (and only)
/// suspension point** — i.e. before the `Task {}` below is even created. That
/// ordering IS the guard. This is the m23-n2a lesson, restated because it is
/// the same trap: an actor method releases isolation at every `await`, so if
/// the assignment lived inside the spawned `Task` instead of in `start`
/// itself, two `start` calls could both observe `variantInFlight == nil`
/// before either task's body ran — the actor would not have saved them,
/// because by the time either task's body executed the race would already be
/// over. Because `start` performs its guard check-and-set with NO `await` in
/// between (and none before it), the actor's ordinary one-message-at-a-time
/// processing is sufficient BY ITSELF: whichever call the actor processes
/// first sets the flag, and the second necessarily observes it set, no matter
/// how the two calls were scheduled by the caller.
/// `WhisperModelInstallCoordinatorTests` proves this discriminates: deleting
/// the guard clause reddens "only one install is ever in flight, and the
/// underlying installer is only ever called once", restored byte-exact
/// afterward (`shasum -c`).
///
/// ## Why progress does not go through the actor's mailbox
///
/// `WhisperModelInstaller.install`'s `progress` callback is a plain,
/// synchronous, non-`async` closure — "called on WhisperKit's own callback
/// thread, repeatedly" (its own doc comment). Recording each tick with
/// `Task { await self.recordProgress(tick) }` would spawn one unstructured
/// `Task` per callback with NO ordering guarantee relative to one another, so
/// back-to-back ticks could be recorded out of order — a real risk, not a
/// theoretical one, since unstructured tasks queue onto a shared concurrent
/// executor. Instead the latest tick lives in an `OSAllocatedUnfairLock` (the
/// `InMemoryKeyStore` precedent, `Sources/AIServices/KeyStore.swift`),
/// written synchronously from the callback's own thread and read
/// synchronously from `status()` — no actor hop, no reordering risk, and
/// "the latest one wins" is exactly the semantics a poller wants (it does not
/// need every intermediate tick, only the current one).
///
/// ## What a silent download still guarantees
///
/// `finish(variant:result:)` runs off the `Task`'s `do`/`catch` — success,
/// thrown error, or a `CancellationError` all reach it, unconditionally, with
/// no early return and no `try?` swallowing a path. So a download that never
/// calls `progress` even once (untested boundary, per `WhisperModelInstaller`'s
/// own notes — the real network leg has run zero times in this sandbox) still
/// reaches `.succeeded` or `.failed`; `progress` on that terminal `Status` is
/// simply `nil`.
public actor WhisperModelInstallCoordinator {

    /// Signature-compatible with `WhisperModelInstaller.install`, injected so
    /// tests can script a progress sequence and a terminal outcome with no
    /// network at all — the real fetch has never executed once in this
    /// sandbox (`WhisperModelInstaller`'s own doc: a real attempt died at
    /// `NSURLErrorDomain -1001` after 61.6s with zero bytes moved), so this
    /// seam is the ONLY way `ai.speechModelInstallStatus` can be exercised
    /// against real progress ticks.
    public typealias InstallFunction = @Sendable (
        _ variant: String,
        _ overwrite: Bool,
        _ repo: String,
        _ token: String?,
        _ progress: @escaping @Sendable (WhisperModelInstallProgress) -> Void
    ) async throws -> WhisperModelDescriptor

    /// The real installer, wired with its own defaults — never restated here.
    public static let liveInstallFunction: InstallFunction = { variant, overwrite, repo, token, progress in
        try await WhisperModelInstaller().install(
            variant: variant, overwrite: overwrite, repo: repo, token: token, progress: progress)
    }

    private let installFunction: InstallFunction

    /// See the type docs' "why progress does not go through the actor's
    /// mailbox" — written from the (possibly non-actor) callback thread, read
    /// from `status()`. Nothing else touches this lock's contents from
    /// inside actor-isolated code except through `withLock`.
    private let latestProgressBox = OSAllocatedUnfairLock<WhisperModelInstallProgress?>(initialState: nil)

    /// Non-nil while an install is running; THE guard (see type docs).
    private var variantInFlight: String?
    /// The most recently finished install's outcome, kept until the next
    /// `start` replaces it. `nil` before anything has ever finished.
    private var lastTerminal: WhisperModelInstallStatus?

    public init(installFunction: @escaping InstallFunction = WhisperModelInstallCoordinator.liveInstallFunction) {
        self.installFunction = installFunction
    }

    // MARK: - Start

    /// Start installing `variant`. Returns as soon as the request is
    /// ACCEPTED — never waits for the download. Poll `status()` for progress
    /// and the terminal outcome, including a FAST failure (an unrecognised
    /// variant name, or "already installed" without `overwrite`): those are
    /// only discoverable by polling too, deliberately, so there is exactly
    /// ONE place — `WhisperModelInstaller.install` — that decides what counts
    /// as a failure, and this coordinator never second-guesses it with a
    /// synchronous pre-check of its own.
    ///
    /// - Returns: The status snapshot immediately after acceptance —
    ///   `.installing` with the requested variant name and no progress yet.
    /// - Throws: `WhisperModelInstallCoordinatorError.installAlreadyInFlight`
    ///   when another install is already running. Never queues, never
    ///   coalesces.
    @discardableResult
    public func start(
        variant: String,
        overwrite: Bool = false,
        repo: String = WhisperModelInstaller.whisperKitRepoID,
        token: String? = nil
    ) throws -> WhisperModelInstallStatus {
        // THE GUARD. No `await` above this line, and none below it in this
        // method — see the type docs' "why it must be synchronous".
        if let alreadyInFlight = variantInFlight {
            throw WhisperModelInstallCoordinatorError.installAlreadyInFlight(
                variantRequested: variant, variantInFlight: alreadyInFlight)
        }
        variantInFlight = variant
        // LOAD-BEARING, and pinned by `secondInstallDoesNotInheritStaleProgress`:
        // without it a freshly started multi-GB download reports the PREVIOUS
        // install's fraction until its own first tick lands.
        latestProgressBox.withLock { $0 = nil }
        // DEFENSIVE, not observable: `status()` returns early on
        // `variantInFlight` above, and `finish()` always overwrites
        // `lastTerminal`, so no caller can read a stale terminal record.
        // Removing this line ALONE leaves the whole suite green (verified by
        // mutation, m23-n3b) — it is kept so both fields are reset together
        // rather than relying on that reasoning surviving the next edit.
        // Do not "pin" it with a test that only restates this assignment.
        lastTerminal = nil

        let function = installFunction
        let box = latestProgressBox
        Task { [weak self] in
            do {
                let descriptor = try await function(variant, overwrite, repo, token) { tick in
                    box.withLock { $0 = tick }
                }
                await self?.finish(variant: variant, result: .success(descriptor))
            } catch {
                await self?.finish(variant: variant, result: .failure(error))
            }
        }
        return status()
    }

    /// Reached unconditionally from the spawned `Task` — success, thrown
    /// error, or cancellation. No early return, no `try?` swallowing a path:
    /// that is what makes "the guard is cleared on every exit path" true.
    private func finish(variant: String, result: Result<WhisperModelDescriptor, Error>) {
        variantInFlight = nil
        let progress = latestProgressBox.withLock { $0 }
        switch result {
        case .success(let descriptor):
            lastTerminal = WhisperModelInstallStatus(
                state: .succeeded, variantDirectoryNameRequested: variant,
                progress: progress, descriptor: descriptor)
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastTerminal = WhisperModelInstallStatus(
                state: .failed, variantDirectoryNameRequested: variant,
                progress: progress, errorMessage: message)
        }
    }

    // MARK: - Status

    /// The current status: `.installing` (with the latest progress, which may
    /// be `nil` if nothing has ticked yet) while a job is running; else the
    /// most recent terminal outcome; else `.idle` if nothing has ever run.
    public func status() -> WhisperModelInstallStatus {
        if let variantInFlight {
            return WhisperModelInstallStatus(
                state: .installing, variantDirectoryNameRequested: variantInFlight,
                progress: latestProgressBox.withLock { $0 })
        }
        return lastTerminal ?? .idle
    }
}
