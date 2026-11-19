import AIServices
import DAWCore
import Foundation
import Observation

/// What one sing job's row says (§5.5 progress, §5.6 results). Pure, from the coordinator's status: every stage
/// sentence is the coordinator's own (`SingJobStatus.stageText`, `SingJobCoordinator.Copy`).
public struct SingTakeRowText: Equatable, Sendable {
    public enum Tone: String, Equatable, Sendable {
        /// Still singing.
        case working
        /// §5.6 Green: "In tune · Words clear".
        case green
        /// §5.6 Amber: a notes or words notice.
        case amber
        /// Landed, nothing to praise or warn (the word check skipped, say).
        case plain
        case failed
        case stopped
    }

    public var stage: String
    /// "42%" (SF Mono).
    public var percent: String?
    public var fraction: Double?
    /// "about 1:05 left" (SF Mono).
    public var eta: String?
    /// [Cancel], which becomes "Stopping after this line…" (§5.5); nil once nothing can be stopped.
    public var cancelTitle: String?
    public var cancelEnabled: Bool
    /// §5.7 "Results" (`SingJobCoordinator.Copy.results`), once a check has an answer.
    public var resultLine: String?
    public var tone: Tone
    /// The plan's warnings and the take's notices, in their own words.
    public var notices: [String]
    /// The failure, in the coordinator's words.
    public var failure: String?
    /// [▶ Play from here] [Try another take] [Choose a different voice] (§5.6): once the take is in the song.
    public var showsResultButtons: Bool

    public init(status: SingJobStatus) {
        let phase = status.phase
        notices = status.warnings + status.notices
        failure = nil
        resultLine = nil
        percent = nil
        fraction = nil
        eta = nil
        cancelTitle = nil
        cancelEnabled = false
        showsResultButtons = phase.hasLanded
        switch phase {
        case .queued, .waitingForModel, .startingEngine, .preparingVoice, .singing, .finishing:
            stage = status.stageText
            tone = .working
            fraction = min(1, max(0, status.progress))
            percent = "\(Int((min(1, max(0, status.progress)) * 100).rounded()))%"
            eta = status.etaSeconds.map(SingCopy.eta(seconds:))
            cancelTitle = status.cancelRequested ? SingJobCoordinator.Copy.stopping : SingCopy.cancel
            cancelEnabled = !status.cancelRequested
        case .landed, .checking:
            // §5.5: "After landing: 'Checking the notes…' and 'Checking the words…', then the result chips."
            let result = status.result
            stage = result?.noteAccuracy == nil ? SingCopy.checkingNotes : SingJobCoordinator.Copy.checkingWords
            tone = .working
            fraction = 1
        case .done:
            stage = status.stageText
            let result = status.result
            let line = SingJobCoordinator.Copy.results(notes: result?.noteAccuracy, words: result?.wordCheck)
            resultLine = line.isEmpty ? nil : line
            tone = Self.tone(notes: result?.noteAccuracy, words: result?.wordCheck)
            fraction = 1
        case .failed:
            stage = status.stageText
            failure = status.error?.message ?? status.stageText
            tone = .failed
        case .cancelled:
            stage = status.stageText
            tone = .stopped
        }
    }

    /// Green only for "In tune · Words clear"; amber for a notes or words notice; plain otherwise.
    static func tone(notes: SungNoteAccuracy?, words: SungWordCheck?) -> Tone {
        let notesOff = notes.map { !$0.inTune } ?? false
        let wordsVerdict = words?.state == SungWordCheck.State.checked ? words?.verdict : nil
        let wordsUnclear = wordsVerdict == SingWordCheck.Verdict.someUnclear
            || wordsVerdict == SingWordCheck.Verdict.unclear
        if notesOff || wordsUnclear { return .amber }
        if notes?.inTune == true, wordsVerdict == SingWordCheck.Verdict.clear { return .green }
        return .plain
    }
}

/// The results card for the takes sung from the sheet (§5.6), and the job calls behind its buttons. Progress
/// lives on the unified progress card (§5.5); this card appears once the take is in the song.
///
/// Every button is a call the wire makes: [Try another take] is `SingJobCoordinator.submit` with a new seed
/// (`sing.render {seed}`), and `cancel` is `SingJobCoordinator.cancel` (`sing.cancelJob`).
/// ⚠️ §5.5's [Cancel] belongs on the unified progress card (`GenerationPresenceCard.swift`, not this lane's file):
/// that row should call `SingTakeModel.cancel()` (or `SingJobCoordinator.cancel(jobID:)` with the row's job id).
@MainActor
@Observable
public final class SingTakeModel {
    private let jobs: any SingSheetJobs

    public private(set) var status: SingJobStatus?
    public private(set) var request: SingJobRequest?
    /// A refusal in its own words (a refused new take, a poll that failed, a play that could not start).
    public private(set) var refusal: String?
    /// §5.6: "A tip after the first take." True on the first take that lands in this session.
    public private(set) var showsTip = false
    private var tipShown = false

    /// [▶ Play from here]: seek to the landed clip and play (the app's transport).
    public var onPlayFrom: (@MainActor (_ trackID: UUID, _ clipID: UUID) throws -> Void)?
    /// [Choose a different voice]: open the sheet on the melody clip again.
    public var onChooseVoice: (@MainActor (_ melodyClipID: UUID) -> Void)?
    /// A new take was accepted (the progress card registers it).
    public var onSubmitted: (@MainActor (SingJobStatus, SingJobRequest) -> Void)?

    public init(jobs: any SingSheetJobs) { self.jobs = jobs }

    public var row: SingTakeRowText? { status.map(SingTakeRowText.init(status:)) }

    /// The card shows once the take is in the song, and stays until dismissed.
    public var isVisible: Bool { status?.phase.hasLanded == true }

    /// True while the job can still change (the mount's poll gate).
    public var needsPolling: Bool { status.map { !$0.phase.isTerminal } ?? false }

    public func track(_ status: SingJobStatus, request: SingJobRequest) {
        self.status = status
        self.request = request
        refusal = nil
        showsTip = false
    }

    public func poll() async {
        guard let jobID = status?.jobID else { return }
        do {
            let fresh = try await jobs.status(jobID: jobID)
            guard status?.jobID == jobID else { return }
            status = fresh
            if fresh.phase == .done, !tipShown {
                tipShown = true
                showsTip = true
            }
        } catch {
            refusal = Self.words(error)
        }
    }

    /// §5.5 [Cancel] for this card's take: `cancel(jobID:)` on its job.
    public func cancel() async {
        guard let jobID = status?.jobID else { return }
        await cancel(jobID: jobID)
    }

    // MARK: The unified progress card's sing rows (§5.5: an ETA and [Cancel]) — p2-sing-x8

    /// The latest status of every sing job on the progress card (SING and AGENT alike), read with
    /// `SingJobCoordinator.status` (what `sing.jobStatus` calls) on the card's own 1 s poll.
    public private(set) var liveStatuses: [String: SingJobStatus] = [:]
    /// A refused [Cancel], per job, in its own words (since the §16 errata a cancel after landing has started is
    /// refused with `jobFinished`: "…has already finished or landed, so there is nothing to stop…").
    public private(set) var cancelRefusals: [String: String] = [:]

    /// Reads `jobIDs` (the card's sing rows) and forgets every other job. A read that fails keeps the last status;
    /// the card's own row already says what the bridge read.
    public func refreshLive(jobIDs: [String]) async {
        let wanted = Set(jobIDs.filter(SingPresenceBridge.isSingJob))
        for jobID in wanted {
            do {
                liveStatuses[jobID] = try await jobs.status(jobID: jobID)
            } catch {
                continue   // a failed read keeps the last status: the card's row already shows the bridge's words
            }
        }
        liveStatuses = liveStatuses.filter { wanted.contains($0.key) }
        cancelRefusals = cancelRefusals.filter { wanted.contains($0.key) }
    }

    /// The row text the card draws under a sing row: the ETA ("about 1:05 left") and [Cancel] / "Stopping after this
    /// line…" (`SingTakeRowText`, the same text the results card reads).
    public func liveRow(jobID: String) -> SingTakeRowText? {
        if let tracked = status, tracked.jobID == jobID { return SingTakeRowText(status: tracked) }
        return liveStatuses[jobID].map(SingTakeRowText.init(status:))
    }

    /// [Cancel] on any sing job: `SingJobCoordinator.cancel(jobID:)` (`sing.cancelJob`). A refusal is kept in its own
    /// words for that row (and on this card when it is this card's take).
    public func cancel(jobID: String) async {
        do {
            let fresh = try await jobs.cancel(jobID: jobID)
            liveStatuses[jobID] = fresh
            cancelRefusals[jobID] = nil
            if status?.jobID == jobID { status = fresh }
        } catch {
            let words = Self.words(error)
            cancelRefusals[jobID] = words
            if status?.jobID == jobID { refusal = words }
        }
    }

    /// §14 "After a styled take": asked of the app (is the melody clip styled?) once the take is in the song.
    public var styleProbe: (@MainActor (_ melodyClipID: UUID) -> Bool)?

    /// Does a take sung from a melody clip with this style carry a wobble or air to fine-tune? Asks the SAME question
    /// the singer asks (`SungExpressionPlanner.isNoOp`), so a clip with no style (sung with the default vibrato) says
    /// yes and only a clip that really asks for nothing says no.
    public static func styleIsHeard(_ style: SingStyle?) -> Bool {
        !SungExpressionPlanner.isNoOp(style: style)
    }

    /// "You can fine-tune the wobble on any note in the pitch editor." once a STYLED take is in the song.
    public var styledTakeTip: String? {
        guard isVisible, let clipID = request?.clipID ?? status?.clipID, styleProbe?(clipID) == true else { return nil }
        return SingCopy.afterStyledTake
    }

    /// §5.6 [Try another take]: the same request with a new seed (design §4.4).
    public func tryAnotherTake() async {
        guard var next = request else { return }
        next.seed = SingJobRequestBuilder.anotherTakeSeed()
        refusal = nil
        do {
            let accepted = try await jobs.submit(next)
            onSubmitted?(accepted, next)
            track(accepted, request: next)
        } catch {
            refusal = Self.words(error)
        }
    }

    /// §5.6 [▶ Play from here].
    public func playFromHere() {
        guard let result = status?.result else { return }
        do {
            try onPlayFrom?(result.trackID, result.clipID)
        } catch {
            refusal = Self.words(error)
        }
    }

    /// §5.6 [Choose a different voice].
    public func chooseDifferentVoice() {
        guard let clipID = request?.clipID else { return }
        onChooseVoice?(clipID)
    }

    public func dismiss() {
        status = nil
        request = nil
        refusal = nil
        showsTip = false
    }

    /// A screenshot-only status (`debug.singScreens`).
    public func stageForCapture(_ status: SingJobStatus, request: SingJobRequest?) {
        self.status = status
        self.request = request
        showsTip = status.phase == .done
    }

    static func words(_ error: any Error) -> String { SingScreenWords.sentence(error) }
}

// MARK: - Staging (screenshots and tests)

/// Builds a `SingJobStatus` for a screenshot (`debug.singScreens`) or a test, through the type's OWN `Codable`
/// shape (its memberwise initializer is internal to AIServices), so a staged card can only show a status the
/// coordinator could really send.
public enum SingStaging {
    public static func status(phase: SingJobPhase, stageText: String, jobID: String = "sing-staged",
                              clipID: UUID = UUID(), unitIndex: Int? = nil, unitCount: Int = 1,
                              progress: Double = 0, etaSeconds: Double? = nil, cancelRequested: Bool = false,
                              fromAgent: Bool = false, warnings: [String] = [], notices: [String] = [],
                              landedTrackID: UUID? = nil, landedClipID: UUID? = nil,
                              noteAccuracy: SungNoteAccuracy? = nil, wordCheck: SungWordCheck? = nil,
                              failure: SingJobFailure? = nil) throws -> SingJobStatus {
        var object: [String: Any] = [
            "jobID": jobID, "clipID": clipID.uuidString, "phase": phase.rawValue, "stageText": stageText,
            "unitCount": unitCount, "progress": progress, "cancelRequested": cancelRequested,
            "seed": Int(SingJobRequestBuilder.firstTakeSeed), "retriedUnits": [Int](), "cachedUnits": 0,
            "renderedUnits": 0, "yields": 0, "engineRestarts": 0, "warnings": warnings, "notices": notices,
            "fromAgent": fromAgent, "submittedAt": 0.0,
        ]
        if let unitIndex { object["unitIndex"] = unitIndex }
        if let etaSeconds { object["etaSeconds"] = etaSeconds }
        if let failure { object["error"] = try jsonObject(failure) }
        if let landedTrackID, let landedClipID {
            var result: [String: Any] = [
                "trackID": landedTrackID.uuidString, "clipID": landedClipID.uuidString, "melodyChanged": false,
                "transposedSemitones": 0,
                "gates": ["failed": [String](), "lengthSeconds": 0.0, "plannedSeconds": 0.0, "allFinite": true,
                          "voicedCoverage": 1.0, "quieterThanUsual": false] as [String: Any],
            ]
            if let noteAccuracy { result["noteAccuracy"] = try jsonObject(noteAccuracy) }
            if let wordCheck { result["wordCheck"] = try jsonObject(wordCheck) }
            object["result"] = result
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(SingJobStatus.self, from: data)
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }
}
