import Foundation

// MARK: - p2-sing-0 — every ACE job registers, whoever submitted it

/// A `SongGenerating` decorator that makes **every** ACE-Step job visible to the
/// model lifecycle coordinator, whichever part of the app submitted it — design
/// `docs/design/2026-09-27-p2-sing-integration.md` §2.7, rule R0 (failure mode F1).
///
/// ## The defect this closes
///
/// `activeJobs > 0` is an ABSOLUTE veto on eviction (F8, `ModelLifecycleCoordinator`
/// `// MARK: - Jobs`), but until this type existed only the wire's `ai.*` verbs
/// opened a job (`CommandRouter.noteACEJobStarted`). The Sketchpad and the import
/// seam submit through their own `GenerationObservingGenerator` wrappers of the ONE
/// raw client and never registered. So an RVC boot during a Sketchpad generation
/// saw ACE at `activeJobs == 0`, planned it into `evicting`, and SIGTERMed the
/// user's song mid-render. A SoulX boot (p2-sing-c) would do the same.
///
/// ## Where it sits — below everything, exactly once
///
/// The app wraps the raw `ACEStepClient` in ONE of these, and every other handle on
/// the generator is built over it: the three origin observers (sketchpad, wire,
/// import), the presence poll, and the clip-fix status poll. No handle on the raw
/// client survives the wrap, so every submission and every status poll, from every
/// origin, passes through here.
///
/// ## What it does, and nothing else
///
/// - **Opens** a job (`noteJobStarted`) on every ACCEPTED submission, keyed by the
///   submission's own `jobID`: the string the wire registers and every poller polls
///   with. All four submitting requirements do it: `generateSong`, `extractStems`,
///   `generateLegoTracks`, `repaintAudio`. A submission that throws was never
///   accepted and opens nothing.
/// - **Closes** it (`noteJobEnded`) on the first terminal state or terminal error
///   that ANY poller sees. Later observations are no-ops, because the coordinator
///   keys jobs by id. For the same reason the wire's own `noteJobStarted` /
///   `noteJobEnded` calls for the same id (they stay, nothing is renamed) change
///   nothing: double registration is harmless by construction.
///
/// ⚠️⚠️ **It observes nothing and reports to no one — so the presence poll may read
/// through it.** The presence poll's comment in `DAWProApp` ("never a decorator — no
/// self-observation loop") guards against an OBSERVING decorator, one that feeds
/// every status into `GenerationPresenceModel.apply`: a presence poll read through
/// one would report each poll back into the model that issued it. This type cannot
/// do that even by accident. It lives in `AIServices`, which `DAWAppKit` depends on
/// (`Package.swift`), so naming `GenerationPresenceModel` here would be a dependency
/// cycle SwiftPM refuses to build. Its only outbound calls are the wrapped generator,
/// exactly once per call, and the coordinator's two job hooks; and the coordinator
/// holds no generator to call back into.
///
/// ⚠️ **What stays out of reach, stated rather than hidden:**
/// - A job accepted while its model is not booked resident is not recorded:
///   `noteJobStarted` is a no-op for a non-resident model. A sidecar the user
///   started by hand is never resident, so nothing evicts it through admission
///   either. The wire's hook has the same property.
/// - A stems/Lego submission that fails part-way (track 1 accepted, track 2's
///   `/release_task` throws) returns no composite id, so the accepted track runs
///   unregistered. The wire's hook has the same property.
/// - The job lease (`ModelLifecyclePolicy.jobLeaseSeconds`, 1 h) is the backstop
///   for a job nobody polls to a terminal state.
public final class LifecycleTrackingSongGenerator: SongGenerating, Sendable {

    private let wrapped: any SongGenerating
    private let coordinator: ModelLifecycleCoordinator
    /// The model every job opened here runs on. `.aceStep` in the product.
    public let modelID: ModelID

    /// - Parameters:
    ///   - wrapped: the RAW client. Wrap it exactly once and keep no other handle
    ///     on it, or a submission can reach around the tracker.
    ///   - coordinator: deliberately NO default. The app passes `.shared`; a
    ///     default would let a test that forgot the argument reach the process-wide
    ///     instance, which `ModelLifecycleCoordinator.shared`'s own doc forbids.
    ///   - modelID: which registered model the jobs pin.
    public init(
        wrapping wrapped: any SongGenerating,
        coordinator: ModelLifecycleCoordinator,
        modelID: ModelID = .aceStep
    ) {
        self.wrapped = wrapped
        self.coordinator = coordinator
        self.modelID = modelID
    }

    // MARK: - Submissions: every accepted one opens a job

    public func generateSong(_ request: SongGenerationRequest) async throws -> SongGenerationSubmission {
        let submission = try await wrapped.generateSong(request)
        await coordinator.noteJobStarted(modelID, jobID: submission.jobID)
        return submission
    }

    /// The composite `stems:<uuid>` id is what every poller polls with, so it is
    /// the id that opens the job.
    public func extractStems(_ request: StemExtractionRequest) async throws -> StemGenerationSubmission {
        let submission = try await wrapped.extractStems(request)
        await coordinator.noteJobStarted(modelID, jobID: submission.jobID)
        return submission
    }

    public func generateLegoTracks(_ request: LegoGenerationRequest) async throws -> StemGenerationSubmission {
        let submission = try await wrapped.generateLegoTracks(request)
        await coordinator.noteJobStarted(modelID, jobID: submission.jobID)
        return submission
    }

    /// ⚠️ Declared here on purpose. `repaintAudio` has a protocol-extension default
    /// (the "unsupported" throw in `Providers.swift`); without this override the
    /// tracker would inherit that default and every clip fix would fail instead of
    /// reaching ACE.
    public func repaintAudio(_ request: RepaintRequest) async throws -> SongGenerationSubmission {
        let submission = try await wrapped.repaintAudio(request)
        await coordinator.noteJobStarted(modelID, jobID: submission.jobID)
        return submission
    }

    // MARK: - The status surface: the first terminal observation closes the job

    /// Closes on the POLLED id, which is the string the wire's own close uses.
    ///
    /// ⚠️ Only a terminal state, or an error that PROVES the job is over, may close
    /// it. "I could not ask" (a dropped connection, an HTTP timeout, a cancelled
    /// poll) leaves the job open: evicting a live render is the expensive mistake,
    /// and the lease repairs the cheap one.
    public func generationStatus(jobID: String) async throws -> SongGenerationStatus {
        let status: SongGenerationStatus
        do {
            status = try await wrapped.generationStatus(jobID: jobID)
        } catch {
            if Self.errorProvesJobIsOver(error) {
                await coordinator.noteJobEnded(modelID, jobID: jobID)
            }
            throw error
        }
        if Self.stateIsTerminal(status.state) {
            await coordinator.noteJobEnded(modelID, jobID: jobID)
        }
        return status
    }

    // MARK: - The terminal rule (pure)

    /// `.succeeded` and `.failed` end a job; `.queued` and `.running` do not.
    /// `ACEStepClient` never RETURNS `.failed` (it throws `jobFailed`), but the
    /// protocol allows a provider to, and the wire closes on it too.
    public static func stateIsTerminal(_ state: SongGenerationState) -> Bool {
        switch state {
        case .succeeded, .failed: return true
        case .queued, .running: return false
        }
    }

    /// Does this status failure PROVE the job is over, or only that we could not
    /// ask?
    ///
    /// The same asymmetric split as the wire's `CommandRouter.errorProvesJobIsOver`
    /// and the presence card's `GenerationPresenceModel.terminalFailureReason`:
    /// `.jobFailed` (the sidecar reported it terminal) and `.jobNotFound` (the
    /// sidecar has no such job) close it; everything else leaves it open. That
    /// includes a cancelled poll: `ACEStepClient` maps it to `.sidecarUnreachable`,
    /// and ACE-Step has no abort route, so the render goes on without the poller.
    ///
    /// ⚠️ The switch is exhaustive with NO `default`, so a new `ACEStepError` case
    /// fails the build here until someone decides which side it belongs on. A
    /// non-`ACEStepError` (another provider, a bare `CancellationError`) says
    /// nothing about the job, and the safe direction for an unknown error is to keep
    /// protecting the render.
    public static func errorProvesJobIsOver(_ error: any Error) -> Bool {
        guard let aceError = error as? ACEStepError else { return false }
        switch aceError {
        case .jobFailed, .jobNotFound:
            return true
        case .sidecarUnreachable, .requestFailed, .malformedResponse, .modelSlotUnavailable:
            return false
        }
    }
}
