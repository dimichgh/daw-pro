import Foundation

/// A sing job, as the unified progress card reads it (p2-sing-e part 2, design §5.5).
///
/// The card (`GenerationPresenceModel`, DAWAppKit) polls every row that has a `jobID` through ONE status closure,
/// written for ACE-Step. A sing row is registered with its own `sing-…` id, and the app's closure routes that
/// prefix here instead of to the song generator. Three properties of the mapping are load-bearing:
///
/// - it never answers `.queued`: the card overlays the SONG GENERATOR's boot text on queued rows while ACE is
///   starting (`overlayBootPhaseOnQueuedJobs`), which would put "loading the model" on a vocal;
/// - it never throws: a throw sends the card to `handlePollError`, which asks ACE's sidecar whether the job died
///   with it and posts the "AI generation was interrupted" notice;
/// - a finished take is `.succeeded` WITH a non-empty `audioPath`, else the card reads it as still finishing.
public enum SingPresenceBridge {

    /// Every sing job id starts with this (`SingJobCoordinator.submit`).
    public static let jobIDPrefix = "sing-"

    public static func isSingJob(_ jobID: String) -> Bool { jobID.hasPrefix(jobIDPrefix) }

    /// The card's view of one sing job status.
    public static func generationStatus(_ status: SingJobStatus) -> SongGenerationStatus {
        switch status.phase {
        case .done:
            // The card needs SOME audio marker to call it done; the take itself is a clip in the song.
            let marker = status.result.map { "sing-take:\($0.clipID.uuidString)" } ?? "sing-take"
            return SongGenerationStatus(jobID: status.jobID, state: .succeeded, progress: 1,
                                        stage: status.stageText, statusText: status.stageText, audioPath: marker)
        case .failed:
            return SongGenerationStatus(jobID: status.jobID, state: .failed, progress: status.progress,
                                        stage: status.stageText,
                                        statusText: status.error?.message ?? status.stageText)
        case .cancelled:
            return SongGenerationStatus(jobID: status.jobID, state: .failed, progress: status.progress,
                                        stage: status.stageText, statusText: status.stageText)
        case .queued, .waitingForModel, .startingEngine, .preparingVoice, .singing, .finishing, .landed, .checking:
            return SongGenerationStatus(jobID: status.jobID, state: .running, progress: status.progress,
                                        stage: status.stageText, statusText: status.stageText)
        }
    }

    /// The card's poll for a sing job. Never throws: a job the coordinator no longer knows reads as failed, in
    /// words.
    public static func lookup(jobID: String,
                              status: (String) async throws -> SingJobStatus) async -> SongGenerationStatus {
        do {
            return generationStatus(try await status(jobID))
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "The singing job could not be read."
            return SongGenerationStatus(jobID: jobID, state: .failed, statusText: reason)
        }
    }

    /// The card's label for a sing job. PROVISIONAL (no §5.7 row).
    public static func label(voiceName: String) -> String {
        "Singing — \(voiceName)"
    }
}
