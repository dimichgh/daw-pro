import Foundation

// MARK: - p2-sing-0 — every RVC job registers

/// A `VoiceConverting` decorator that holds an RVC job open with the model
/// lifecycle coordinator for exactly as long as a `convert` or `train` call is
/// running — design `docs/design/2026-09-27-p2-sing-integration.md` §2.7, rule R0.
/// The RVC half of `LifecycleTrackingSongGenerator`; read that type's doc first.
///
/// ## The defect this closes
///
/// Neither call ever registered, so an ACE boot (or, after p2-sing-c, a SoulX boot)
/// during a conversion saw RVC at `activeJobs == 0` and SIGTERMed it mid-convert.
/// That is F1 in the other direction.
///
/// ## Why a bracket, when ACE uses the status surface
///
/// Both calls are single blocking requests: `POST /v1/voice/convert` answers when
/// the conversion is done, and there is no RVC job id or status poll to close on.
/// So the job opens BEFORE the wrapped call and closes on EVERY way out of it: a
/// result, a thrown error, and cancellation, which reaches here as a thrown error
/// (`CancellationError`, or the client's `sidecarUnreachable` for a cancelled
/// request). ⚠️ The close is a `do`/`catch`, not a `defer`: a `defer` body cannot
/// `await` on this toolchain (Swift 6.3.3, measured), and the close is an actor call.
///
/// The job opens before `VoiceConversionClient`'s one-at-a-time convert gate, so a
/// conversion parked behind another one counts as busy too. It is about to use the
/// model, and evicting RVC under it would fail it on arrival.
///
/// ## One id per call
///
/// Every call mints its own job id. Two conversions in flight hold two jobs, so the
/// first to finish cannot un-protect the second: the coordinator's job set is keyed,
/// and a shared id would be closed by whichever call returned first.
///
/// ⚠️ **What stays out of reach, stated rather than hidden:**
/// - `train` is protected only while its POST runs. Today the facade always answers
///   501 `trainingNotYetAvailable` (`VoiceConversionClient.train`'s doc). If
///   m10-p-6 makes training run in the background after a 2xx, this bracket ends
///   at the 2xx, and training needs a poll-based close like ACE's.
/// - As with ACE, `noteJobStarted` is a no-op for a model that is not booked
///   resident, so a call made before RVC's boot was booked is not recorded.
public final class LifecycleTrackingVoiceConverter: VoiceConverting, Sendable {

    private let wrapped: any VoiceConverting
    private let coordinator: ModelLifecycleCoordinator
    /// The model every job opened here runs on. `.rvc` in the product.
    public let modelID: ModelID

    /// Prefixes of the minted job ids, so a job read back from
    /// `ModelLifecycleCoordinator.openJobIDs` says which call holds it.
    static let convertJobPrefix = "vc.convert:"
    static let trainJobPrefix = "vc.train:"

    /// - Parameters:
    ///   - wrapped: the RAW client. Wrap it exactly once and keep no other handle
    ///     on it, or a conversion can reach around the tracker.
    ///   - coordinator: deliberately NO default, for the reason given on
    ///     `LifecycleTrackingSongGenerator.init`.
    ///   - modelID: which registered model the jobs pin.
    public init(
        wrapping wrapped: any VoiceConverting,
        coordinator: ModelLifecycleCoordinator,
        modelID: ModelID = .rvc
    ) {
        self.wrapped = wrapped
        self.coordinator = coordinator
        self.modelID = modelID
    }

    // MARK: - Reads: fast requests, not jobs

    public func listVoices() async throws -> [VoiceDescriptor] {
        try await wrapped.listVoices()
    }

    public func voiceStatus(voiceID: String) async throws -> VoiceDescriptor {
        try await wrapped.voiceStatus(voiceID: voiceID)
    }

    // MARK: - Jobs: bracketed

    public func convert(_ request: VoiceConvertRequest) async throws -> VoiceConvertResult {
        try await bracketed(Self.convertJobPrefix) {
            try await self.wrapped.convert(request)
        }
    }

    @discardableResult
    public func train(_ request: VoiceTrainRequest) async throws -> Data {
        try await bracketed(Self.trainJobPrefix) {
            try await self.wrapped.train(request)
        }
    }

    /// Opens a job, runs `body`, and closes the job on every exit.
    private func bracketed<Value: Sendable>(
        _ prefix: String, _ body: () async throws -> Value
    ) async throws -> Value {
        let jobID = prefix + UUID().uuidString
        await coordinator.noteJobStarted(modelID, jobID: jobID)
        let value: Value
        do {
            value = try await body()
        } catch {
            await coordinator.noteJobEnded(modelID, jobID: jobID)
            throw error
        }
        await coordinator.noteJobEnded(modelID, jobID: jobID)
        return value
    }
}
