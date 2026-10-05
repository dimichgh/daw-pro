import Foundation
import os
import DAWCore

// MARK: - Status

/// The states a poller of `instrument.soundBankDownloadStatus` can observe.
///
/// `.cancelled` is a state of its own rather than a flavour of `.failed`
/// because the two need different words in front of a user: a failure asks
/// them to check something, a cancellation asks them nothing.
public enum SoundBankDownloadState: String, Sendable, Equatable, Codable {
    case idle
    case downloading
    case succeeded
    case failed
    case cancelled
}

/// The one payload every download verb returns — start, poll and cancel all
/// hand back the SAME shape, so a polling agent learns one response body for
/// one job (the `WhisperModelInstallStatus` decision, restated).
public struct SoundBankDownloadStatus: Sendable, Equatable, Codable {
    public var state: SoundBankDownloadState
    /// The catalog id this status describes.
    public var bankID: String?
    /// Its display name, so a UI or an agent need not re-look-up the catalog to
    /// write a sentence.
    public var bankName: String?
    /// True once `cancel()` has been asked for and the job has not yet
    /// unwound. ⚠️ Cancellation is REQUESTED synchronously and OBSERVED by
    /// polling: `state` stays `.downloading` until the transfer actually
    /// stops, and this flag is what lets a surface say "Cancelling…" honestly
    /// instead of claiming it already stopped.
    public var cancelRequested: Bool
    public var progress: SoundBankDownloadProgress?
    /// Present only on `.succeeded` — the installed bank, an ordinary
    /// `.file(path:)` entry the instrument picker can select immediately.
    public var bank: SoundBankInfo?
    /// Present only on `.failed` / `.cancelled`.
    public var errorMessage: String?

    public init(state: SoundBankDownloadState, bankID: String? = nil,
                bankName: String? = nil, cancelRequested: Bool = false,
                progress: SoundBankDownloadProgress? = nil,
                bank: SoundBankInfo? = nil, errorMessage: String? = nil) {
        self.state = state
        self.bankID = bankID
        self.bankName = bankName
        self.cancelRequested = cancelRequested
        self.progress = progress
        self.bank = bank
        self.errorMessage = errorMessage
    }

    /// Nothing has ever been started on this coordinator.
    public static let idle = SoundBankDownloadStatus(state: .idle)
}

// MARK: - Errors

public enum SoundBankDownloadCoordinatorError: Error, LocalizedError, Equatable {
    /// Refused, never queued and never coalesced — the
    /// `WhisperModelInstallCoordinatorError` decision: queueing would silently
    /// reorder an agent's requests and coalescing would silently drop one, and
    /// either is worse than a same-round-trip refusal naming what is running.
    case downloadAlreadyInFlight(requested: String, inFlight: String)
    /// Nothing to cancel. A refusal rather than a no-op success, so an agent
    /// that thinks it cancelled something learns it did not.
    case nothingInFlight

    public var errorDescription: String? {
        switch self {
        case .downloadAlreadyInFlight(let requested, let inFlight):
            return "Already downloading \"\(inFlight)\" — poll "
                + "instrument.soundBankDownloadStatus and wait for it to reach a terminal "
                + "state (succeeded, failed or cancelled) before starting \"\(requested)\". "
                + "Only one sound-bank download runs at a time."
        case .nothingInFlight:
            return "No sound-bank download is running, so there is nothing to cancel."
        }
    }
}

// MARK: - Offerings

/// One catalog bank plus whether it is ALREADY in the library — what both the
/// wire's `instrument.listDownloadableSoundBanks` and the instrument picker
/// show.
///
/// A struct rather than a tuple because the picker holds a list of these in
/// `@Observable` state and identifies rows by `id`; a tuple would work on the
/// wire and be awkward everywhere else.
public struct SoundBankOffering: Sendable, Equatable, Identifiable {
    public var bank: DownloadableSoundBank
    /// The absolute path it already occupies, or nil when it is not installed.
    /// A non-nil value means a download would be REFUSED, not silently
    /// duplicated.
    public var installedPath: String?

    public var id: String { bank.id }
    public var isInstalled: Bool { installedPath != nil }

    public init(bank: DownloadableSoundBank, installedPath: String?) {
        self.bank = bank
        self.installedPath = installedPath
    }
}

// MARK: - The coordinator

/// Sequences sound-bank downloads for the wire AND the instrument picker
/// (m34-c): AT MOST ONE `SoundBankInstaller.install` in flight, a status
/// snapshot pollers read, and a real cancel.
///
/// ## Why this exists given `SoundBankInstaller.install` already works
///
/// `SoundBankInstaller` is a plain `Sendable` struct with no isolation of its
/// own. Nothing in it stops two callers from both staging under distinct UUIDs
/// and both racing a 206 MB file at the same destination — and there are now
/// TWO callers (the control protocol and the picker's Download button), which
/// makes that a real scenario rather than a theoretical one.
///
/// ## ⚠️ ONE INSTANCE PER APP, and that is load-bearing
///
/// The `WhisperModelInstallCoordinator` this is modelled on is held one per
/// router and never needed more, because nothing in the UI could start a model
/// install. This one has a button behind it. `DAWProApp` constructs exactly one
/// and hands the SAME actor to `CommandRouter` and to `InstrumentPickerModel`;
/// two instances would mean a download started in the UI is invisible to
/// `instrument.soundBankDownloadStatus`, and vice versa — the single-flight
/// guard would guard nothing.
///
/// ## Start-then-poll, not await
///
/// A 206 MB transfer is the stretch-render/`ai.installSpeechModel` shape, not
/// the `clip.transcribe` shape: `start` returns as soon as the request is
/// ACCEPTED, and every outcome — including a fast one like "already installed"
/// — is discoverable only by polling. That keeps exactly one place
/// (`SoundBankInstaller.install`) deciding what counts as a failure.
///
/// ## Cancel
///
/// `cancel()` cancels the in-flight `Task` and returns immediately with
/// `cancelRequested: true`. It does NOT synthesise a terminal state: the job's
/// own unwind path removes the staging directory and reports `.cancelled`, so
/// the moment the status says "cancelled" is the moment nothing is left on
/// disk. Claiming otherwise would be a status that races the filesystem.
public actor SoundBankDownloadCoordinator {

    /// Signature-compatible with `SoundBankInstaller.install`, injected so
    /// tests can script progress ticks and a terminal outcome with no network
    /// and no filesystem at all.
    public typealias InstallFunction = @Sendable (
        _ bank: DownloadableSoundBank,
        _ progress: @escaping @Sendable (SoundBankDownloadProgress) -> Void
    ) async throws -> SoundBankInfo

    /// The real installer, wired with its own defaults — never restated here.
    public static let liveInstallFunction: InstallFunction = { bank, progress in
        try await SoundBankInstaller().install(bank: bank, progress: progress)
    }

    /// Build a live install function against a specific library — what
    /// `DAWProApp` uses so the download lands in the SAME directory
    /// `ProjectStore.availableSoundBanks()` scans.
    public static func liveInstallFunction(
        library: SoundBankLibrary
    ) -> InstallFunction {
        { bank, progress in
            try await SoundBankInstaller(library: library)
                .install(bank: bank, progress: progress)
        }
    }

    private let installFunction: InstallFunction

    /// Written from the installer's own callback thread, read from `status()`
    /// — the `WhisperModelInstallCoordinator` reasoning verbatim: recording
    /// each tick with `Task { await … }` would spawn one unstructured task per
    /// callback with no ordering guarantee between them, so back-to-back ticks
    /// could be recorded out of order. "The latest one wins" is exactly what a
    /// poller wants.
    private let latestProgressBox = OSAllocatedUnfairLock<SoundBankDownloadProgress?>(
        initialState: nil)

    /// Non-nil while a download is running; THE guard.
    private var inFlight: DownloadableSoundBank?
    /// The in-flight job's handle — the whole reason cancel is possible.
    private var inFlightTask: Task<Void, Never>?
    /// Set by `cancel()`, cleared by the next `start`. Reported so a surface
    /// can say "Cancelling…" while the transfer unwinds.
    private var cancelRequested = false
    /// The most recently finished outcome, kept until the next `start`.
    private var lastTerminal: SoundBankDownloadStatus?

    public init(installFunction: @escaping InstallFunction
                = SoundBankDownloadCoordinator.liveInstallFunction) {
        self.installFunction = installFunction
    }

    /// Every bank the catalog offers, annotated with whether it is already in
    /// `library`. Static rather than instance state: the catalog is a
    /// compile-time list and "installed" is a question about the filesystem
    /// right now, so neither belongs in this actor's memory.
    public static func offerings(library: SoundBankLibrary = SoundBankLibrary())
        -> [SoundBankOffering] {
        let existing = library.scan().reduce(into: [String: String]()) { map, info in
            map[URL(fileURLWithPath: info.path).lastPathComponent] = info.path
        }
        return DownloadableSoundBankCatalog.all.map {
            SoundBankOffering(bank: $0, installedPath: existing[$0.fileName])
        }
    }

    // MARK: - Start

    /// Start downloading the catalog bank with this id. Returns as soon as the
    /// request is ACCEPTED — never waits for the transfer.
    ///
    /// - Throws: `unknownBank` for an id that is not in the catalog (a caller
    ///   error worth a same-round-trip refusal, unlike every install-time
    ///   failure, which is poll-discoverable), or `downloadAlreadyInFlight`.
    @discardableResult
    public func start(bankID: String) throws -> SoundBankDownloadStatus {
        guard let bank = DownloadableSoundBankCatalog.bank(id: bankID) else {
            throw SoundBankInstallError.unknownBank(
                requested: bankID, known: DownloadableSoundBankCatalog.all.map(\.id))
        }
        return try start(bank: bank)
    }

    @discardableResult
    public func start(bank: DownloadableSoundBank) throws -> SoundBankDownloadStatus {
        // THE GUARD. No `await` above this line and none below it in this
        // method, so the actor's one-message-at-a-time processing IS the
        // mutual exclusion — the m23-n3b lesson: an assignment made inside the
        // spawned `Task` instead would let two `start` calls both observe
        // `inFlight == nil` before either task body ran.
        if let running = inFlight {
            throw SoundBankDownloadCoordinatorError.downloadAlreadyInFlight(
                requested: bank.name, inFlight: running.name)
        }
        inFlight = bank
        cancelRequested = false
        // Without this a freshly started download reports the PREVIOUS one's
        // fraction until its own first tick lands.
        latestProgressBox.withLock { $0 = nil }
        lastTerminal = nil

        let function = installFunction
        let box = latestProgressBox
        inFlightTask = Task { [weak self] in
            do {
                let info = try await function(bank) { tick in
                    box.withLock { $0 = tick }
                }
                await self?.finish(bank: bank, result: .success(info))
            } catch {
                await self?.finish(bank: bank, result: .failure(error))
            }
        }
        return status()
    }

    /// Reached unconditionally from the spawned `Task` — success, thrown error
    /// or cancellation. No early return and no `try?` swallowing a path, which
    /// is what makes "the guard is cleared on every exit path" true.
    private func finish(bank: DownloadableSoundBank,
                        result: Result<SoundBankInfo, Error>) {
        inFlight = nil
        inFlightTask = nil
        cancelRequested = false
        let progress = latestProgressBox.withLock { $0 }
        switch result {
        case .success(let info):
            lastTerminal = SoundBankDownloadStatus(
                state: .succeeded, bankID: bank.id, bankName: bank.name,
                progress: progress, bank: info)
        case .failure(let error):
            // A cancellation is its own state. `SoundBankInstaller` converts
            // Swift's `CancellationError` into the teaching
            // `.cancelled(name:)`; a bare `CancellationError` is still matched
            // in case a future install function throws one directly.
            let cancelled: Bool
            if case SoundBankInstallError.cancelled = error { cancelled = true }
            else { cancelled = error is CancellationError }
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            lastTerminal = SoundBankDownloadStatus(
                state: cancelled ? .cancelled : .failed,
                bankID: bank.id, bankName: bank.name,
                progress: progress, errorMessage: message)
        }
    }

    // MARK: - Cancel

    /// Ask the in-flight download to stop. Returns the status right after the
    /// request — still `.downloading`, now with `cancelRequested: true`. Poll
    /// until the state is terminal; `.cancelled` means the partial file is
    /// gone, because the installer removes its staging directory on the way
    /// out.
    @discardableResult
    public func cancel() throws -> SoundBankDownloadStatus {
        guard inFlight != nil, let task = inFlightTask else {
            throw SoundBankDownloadCoordinatorError.nothingInFlight
        }
        cancelRequested = true
        task.cancel()
        return status()
    }

    // MARK: - Status

    /// `.downloading` (with the latest tick, which may be nil if nothing has
    /// ticked yet) while a job runs; else the most recent terminal outcome;
    /// else `.idle`.
    public func status() -> SoundBankDownloadStatus {
        if let inFlight {
            return SoundBankDownloadStatus(
                state: .downloading, bankID: inFlight.id, bankName: inFlight.name,
                cancelRequested: cancelRequested,
                progress: latestProgressBox.withLock { $0 })
        }
        return lastTerminal ?? .idle
    }
}
