import Foundation
import Testing
@testable import DAWAppKit

/// m18-g: the candidate ROW's registry deference — `SketchpadModel
/// .resolvedCandidate(_:registry:)`, the headless mapping the Sketchpad view
/// runs each row through so the row displays the SAME lifecycle facts the
/// canonical generation-progress card renders for the same job. Filed as the
/// m17-h deviation: during a sidecar model load the card said LOADING THE
/// MODEL… while the row still told its own stale QUEUED + amber RECONNECTING
/// story. One story per job, total over every registry phase.
@Suite struct SketchpadRowResolutionTests {

    // MARK: - Helpers

    private func candidate(
        _ state: SketchpadCandidate.State,
        jobID: String = "job-1",
        stale: Bool = false
    ) -> SketchpadCandidate {
        SketchpadCandidate(jobID: jobID, promptSnippet: "warm 80s synth-pop",
                           state: state, isStale: stale)
    }

    private func presenceJob(
        _ phase: GenerationPresencePhase,
        jobID: String? = "job-1",
        stale: Bool = false
    ) -> GenerationPresenceJob {
        GenerationPresenceJob(jobID: jobID, origin: .sketchpad, label: "warm 80s synth-pop",
                              phase: phase, startedAt: Date(timeIntervalSince1970: 0),
                              isStale: stale)
    }

    // MARK: - The filed divergence (the m17-h loading-model window)

    @Test func modelLoadWindowTellsTheCardsStoryNotQueuedReconnecting() {
        // The exact filed frame: the candidate's own tracking says QUEUED and a
        // blipped poll marked it stale (amber RECONNECTING), while the registry
        // — the facts the card renders — says the sidecar is loading the model.
        let row = SketchpadModel.resolvedCandidate(
            candidate(.queued, stale: true),
            registry: [presenceJob(.startingSidecar(detail: "loading models (7.8 GB)…"))])
        #expect(row.state == .running(progress: nil, statusText: "LOADING THE MODEL…"))
        #expect(row.state != .queued)
        #expect(!row.isStale)   // the boot narration IS the story — never RECONNECTING here
    }

    @Test func bootWithoutDetailReadsStartingTheAIGenerator() {
        let row = SketchpadModel.resolvedCandidate(
            candidate(.queued),
            registry: [presenceJob(.startingSidecar(detail: nil))])
        #expect(row.state == .running(progress: nil, statusText: "STARTING THE AI GENERATOR…"))
        #expect(!row.isStale)
    }

    @Test func bootDetailPassesThroughUppercasedVerbatim() {
        // Any other boot phase hint surfaces verbatim (uppercased) — exactly
        // what the card's stage label shows for the same phase.
        let row = SketchpadModel.resolvedCandidate(
            candidate(.queued),
            registry: [presenceJob(.startingSidecar(detail: "preparing environment…"))])
        #expect(row.state == .running(progress: nil, statusText: "PREPARING ENVIRONMENT…"))
    }

    @Test func sidecarReadyMapsToTheCardsReadyLabel() {
        let row = SketchpadModel.resolvedCandidate(
            candidate(.queued, stale: true),
            registry: [presenceJob(.sidecarReady)])
        #expect(row.state == .running(
            progress: nil, statusText: "GENERATOR READY — WAITING FOR THE JOB…"))
        #expect(!row.isStale)
    }

    // MARK: - Queued / running adopt the registry's facts

    @Test func queuedAdoptsTheRegistrysStaleFlagBothWays() {
        // Registry says clean queued — a leftover row-side blip clears.
        let cleaned = SketchpadModel.resolvedCandidate(
            candidate(.queued, stale: true),
            registry: [presenceJob(.queued, stale: false)])
        #expect(cleaned.state == .queued)
        #expect(!cleaned.isStale)

        // Registry says the poll blipped — the row dims WITH the card.
        let dimmed = SketchpadModel.resolvedCandidate(
            candidate(.queued, stale: false),
            registry: [presenceJob(.queued, stale: true)])
        #expect(dimmed.state == .queued)
        #expect(dimmed.isStale)
    }

    @Test func runningAdoptsRegistryProgressAndRichStageTextVerbatim() {
        // The upstream stage is RICH TEXT (m17-h lore) — it must pass through
        // verbatim, never be gated on string equality.
        let stage = "Generating music (batch size: 2)..."
        let row = SketchpadModel.resolvedCandidate(
            candidate(.queued, stale: true),
            registry: [presenceJob(.running(progress: 0.25, stageText: stage), stale: false)])
        #expect(row.state == .running(progress: 0.25, statusText: stage))
        #expect(!row.isStale)
    }

    @Test func runningWithNilStageKeepsTheGenericGeneratingFallback() {
        // nil stage text stays nil — the row's own rendering falls back to
        // GENERATING, the same fallback the card's stage label uses.
        let row = SketchpadModel.resolvedCandidate(
            candidate(.queued),
            registry: [presenceJob(.running(progress: nil, stageText: nil), stale: true)])
        #expect(row.state == .running(progress: nil, statusText: nil))
        #expect(row.isStale)   // a running-phase blip is one shared stale story too
    }

    // MARK: - Terminal registry facts reach the row

    @Test func registrySucceededBeforeTheRowsOwnPollBridgesAsFullBarDone() {
        // The registry saw the finished status first; the row can't offer
        // preview/import until its OWN poll lands the audio path, so it bridges
        // the sub-second gap as a full-bar DONE — never QUEUED under a DONE card.
        let row = SketchpadModel.resolvedCandidate(
            candidate(.queued, stale: true),
            registry: [presenceJob(.succeeded)])
        #expect(row.state == .running(progress: 1, statusText: "DONE"))
        #expect(!row.isStale)
    }

    @Test func registryFailureReachesTheRowVerbatim() {
        // The registry escalates sidecar death mid-job to failed; the row's own
        // transient-stale rule would have read RECONNECTING forever.
        let reason = "AI generation was interrupted — the AI generator stopped mid-job."
        let row = SketchpadModel.resolvedCandidate(
            candidate(.running(progress: 0.6, statusText: "step 5/8"), stale: true),
            registry: [presenceJob(.failed(reason: reason))])
        #expect(row.state == .failed(message: reason))
        #expect(!row.isStale)
    }

    // MARK: - Terminal candidates keep their row-ness

    @Test func terminalSucceededCandidateKeepsItsOwnRiches() {
        // The row owns what the registry doesn't: the preview/import audio
        // path. A late registry story never clobbers a terminal row.
        let succeeded = candidate(.succeeded(audioPath: "/tmp/take.wav", bpm: 120,
                                             durationSeconds: 30))
        let row = SketchpadModel.resolvedCandidate(
            succeeded, registry: [presenceJob(.failed(reason: "late registry story"))])
        #expect(row == succeeded)
    }

    @Test func failedAndImportedCandidatesAreNeverRewritten() {
        let failed = candidate(.failed(message: "worker ran out of memory"))
        #expect(SketchpadModel.resolvedCandidate(
            failed, registry: [presenceJob(.queued)]) == failed)

        let imported = candidate(.imported(trackID: UUID(), trackName: "AI: synth-pop"))
        #expect(SketchpadModel.resolvedCandidate(
            imported, registry: [presenceJob(.running(progress: 0.5, stageText: nil))]) == imported)
    }

    // MARK: - No twin → the candidate's own tracking stands

    @Test func noRegistryTwinLeavesTheCandidatesOwnTracking() {
        // Registry rows clear after their linger (and seeded demo rows have no
        // twin at all) — the row falls back to the only story available.
        let own = candidate(.running(progress: 0.4, statusText: "step 3/8"), stale: true)
        let row = SketchpadModel.resolvedCandidate(own, registry: [])
        #expect(row == own)
    }

    @Test func bootEntriesWithNilJobIDAndEmptyCandidateJobIDsNeverMatch() {
        // A pre-submit boot entry carries a nil jobID — it narrates a job that
        // does not exist upstream yet and must never adopt someone's row.
        let own = candidate(.queued, jobID: "job-1")
        #expect(SketchpadModel.resolvedCandidate(
            own, registry: [presenceJob(.startingSidecar(detail: nil), jobID: nil)]) == own)

        // And an empty candidate jobID (the submit-failure shape) never fishes
        // in the registry either.
        let anonymous = candidate(.queued, jobID: "")
        #expect(SketchpadModel.resolvedCandidate(
            anonymous, registry: [presenceJob(.running(progress: 0.9, stageText: nil), jobID: nil)])
            == anonymous)
    }

    @Test func resolutionMatchesByJobIDAmongManyAndPreservesRowIdentity() {
        let own = candidate(.queued, jobID: "job-2")
        let row = SketchpadModel.resolvedCandidate(own, registry: [
            presenceJob(.failed(reason: "someone else's job"), jobID: "job-1"),
            presenceJob(.running(progress: 0.7, stageText: "decoding audio"), jobID: "job-2"),
            presenceJob(.queued, jobID: "job-3"),
        ])
        #expect(row.state == .running(progress: 0.7, statusText: "decoding audio"))
        // Identity + label + jobID survive resolution — SwiftUI row identity
        // (the SketchpadCandidate stable-id rule) and the actions keyed off it.
        #expect(row.id == own.id)
        #expect(row.jobID == own.jobID)
        #expect(row.promptSnippet == own.promptSnippet)
    }
}
