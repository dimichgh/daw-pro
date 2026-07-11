import Foundation
import Testing
@testable import DAWCore

// Take micro-alignment (M6 v-d): the pure `TakeAligner` (grid search + greedy
// matching + median refinement) and the `autoAlignTake` store op. The store
// suite reuses the shared `FakeEngine` (CoreTests.swift), whose per-URL
// `detectTransientsStubByURL` feeds the reference and candidate lanes
// different onset sets headlessly; real-detector end-to-end coverage (click
// WAVs through TransientAnalyzer) lives in
// Tests/DAWEngineTests/TakeAlignmentEngineTests.swift.

private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

@Suite("TakeAligner — pure alignment core (M6 v-d)")
struct TakeAlignerTests {

    // 1. Exact synthetic offset: +80 ms planted, recovered far inside 1 ms
    //    (median refinement, no grid quantization in the final number).
    @Test("+80 ms planted offset recovered to well under 1 ms")
    func exactOffsetRecovery() throws {
        let reference = [0.5, 1.0, 1.6, 2.2, 2.9]
        let candidate = reference.map { $0 + 0.080 }
        let result = try #require(TakeAligner.align(
            referenceOnsets: reference, candidateOnsets: candidate,
            searchWindowSeconds: 0.150))
        #expect(near(result.offsetSeconds, 0.080))
        #expect(result.matchedOnsets == 5)
        #expect(result.referenceOnsets == 5)
        #expect(result.candidateOnsets == 5)
        #expect(result.confidence == 1.0)
        // Perfectly rigid shift → zero residual after alignment.
        #expect(near(result.meanAbsDeviationSeconds, 0))
    }

    // 2. ±5 ms per-onset jitter on top of a +60 ms shift still recovers.
    @Test("±5 ms onset jitter still recovers the planted shift")
    func jitterTolerance() throws {
        let reference = [0.5, 1.0, 1.5, 2.0, 2.5]
        let jitter = [0.004, -0.005, 0.002, -0.003, 0.005]
        let candidate = zip(reference, jitter).map { $0 + 0.060 + $1 }
        let result = try #require(TakeAligner.align(
            referenceOnsets: reference, candidateOnsets: candidate,
            searchWindowSeconds: 0.150))
        #expect(result.matchedOnsets == 5)
        // Median of the jittered deltas = 0.060 + median(jitter) = 0.062.
        #expect(near(result.offsetSeconds, 0.062))
        #expect(abs(result.offsetSeconds - 0.060) <= 0.005)
        // Residual jitter survives alignment (it isn't a rigid shift).
        #expect(result.meanAbsDeviationSeconds > 0)
        #expect(result.meanAbsDeviationSeconds <= 0.005)
    }

    // 3. Inconclusive → nil, never a guess.
    @Test("disjoint onset sets are inconclusive (nil)")
    func disjointSetsNil() {
        #expect(TakeAligner.align(referenceOnsets: [0.5, 1.0, 1.5],
                                  candidateOnsets: [10.0, 11.0],
                                  searchWindowSeconds: 0.150) == nil)
    }

    @Test("fewer than 2 onsets on either side is inconclusive (nil)")
    func tooFewOnsetsNil() {
        #expect(TakeAligner.align(referenceOnsets: [0.5, 1.0, 1.5],
                                  candidateOnsets: [0.58],
                                  searchWindowSeconds: 0.150) == nil)
        #expect(TakeAligner.align(referenceOnsets: [0.5],
                                  candidateOnsets: [0.5, 1.0],
                                  searchWindowSeconds: 0.150) == nil)
        #expect(TakeAligner.align(referenceOnsets: [], candidateOnsets: [],
                                  searchWindowSeconds: 0.150) == nil)
    }

    @Test("only one matchable pair at the best offset is inconclusive (nil)")
    func singleMatchNil() {
        // Both sides have >= 2 onsets, but no offset can ever line up more
        // than one pair.
        #expect(TakeAligner.align(referenceOnsets: [1.0, 5.0],
                                  candidateOnsets: [1.0, 20.0],
                                  searchWindowSeconds: 0.150) == nil)
    }

    // 4. Tie-break determinism: a whole range of grid offsets shares the same
    //    match count AND mean deviation — the smallest |offset| wins, and the
    //    median refinement lands on 0 exactly. Twice, identically.
    @Test("equal-match, equal-deviation ties break to the smallest |offset|, deterministically")
    func tieBreakDeterminism() throws {
        let reference = [1.0, 2.0]
        let candidate = [1.01, 1.99]   // deltas +0.01 / −0.01: symmetric
        let first = try #require(TakeAligner.align(
            referenceOnsets: reference, candidateOnsets: candidate,
            searchWindowSeconds: 0.050))
        let second = try #require(TakeAligner.align(
            referenceOnsets: reference, candidateOnsets: candidate,
            searchWindowSeconds: 0.050))
        #expect(first == second)
        #expect(first.offsetSeconds == 0)          // median(+0.01, −0.01)
        #expect(first.matchedOnsets == 2)
        #expect(near(first.meanAbsDeviationSeconds, 0.01))
    }

    // 5. Median refinement beats the 1 ms grid: an off-grid planted offset
    //    comes back exactly, not rounded to a grid multiple.
    @Test("off-grid +80.3 ms offset recovered exactly (median beats the 1 ms grid)")
    func medianBeatsGridStep() throws {
        let reference = [0.5, 1.0, 1.5, 2.0]
        let candidate = reference.map { $0 + 0.0803 }
        let result = try #require(TakeAligner.align(
            referenceOnsets: reference, candidateOnsets: candidate,
            searchWindowSeconds: 0.150))
        #expect(near(result.offsetSeconds, 0.0803))
        // Strictly finer than anything the 1 ms grid could produce.
        #expect(abs(result.offsetSeconds - 0.080) > 1e-5)
        #expect(abs(result.offsetSeconds - 0.081) > 1e-5)
    }

    // 6. Confidence = matched / max(1, min(referenceCount, candidateCount)).
    @Test("confidence counts matches against the smaller onset set")
    func confidenceMath() throws {
        // 6 reference onsets, 4 candidate onsets, 1 candidate outlier → 3
        // matches out of min(6, 4) = 4.
        let result = try #require(TakeAligner.align(
            referenceOnsets: [0.5, 1.0, 1.5, 2.0, 2.5, 3.0],
            candidateOnsets: [0.55, 1.05, 1.55, 9.0],
            searchWindowSeconds: 0.150))
        #expect(result.matchedOnsets == 3)
        #expect(result.referenceOnsets == 6)
        #expect(result.candidateOnsets == 4)
        #expect(near(result.confidence, 0.75))
        #expect(near(result.offsetSeconds, 0.05))
    }

    // 7. Each reference onset is consumable ONCE (greedy nearest).
    @Test("a reference onset never matches two candidates")
    func referenceConsumedOnce() throws {
        let result = try #require(TakeAligner.align(
            referenceOnsets: [1.0, 5.0],
            candidateOnsets: [0.995, 1.005, 5.0],
            searchWindowSeconds: 0.050))
        #expect(result.matchedOnsets == 2)          // not 3
        #expect(result.confidence == 1.0)           // 2 / min(2, 3)
    }
}

@MainActor
@Suite("ProjectStore — autoAlignTake (M6 v-d)")
struct AutoAlignTakeStoreTests {

    static let refURL = URL(fileURLWithPath: "/tmp/align-ref.wav")
    static let takeURL = URL(fileURLWithPath: "/tmp/align-take.wav")

    /// Two overlapping 8-beat audio lanes at `laneStartBeat` (default 4, so a
    /// −0.16-beat nudge has headroom; pass 0 to exercise the timeline-start
    /// guard), grouped oldest-first: lane 0 = reference, lane 1 = the take.
    /// The candidate's source onsets are planted +80 ms late relative to the
    /// reference's.
    private func makeAlignedStore(
        candidateSourceOnsets: [Double] = [0.58, 1.08, 1.58, 2.28],
        laneStartBeat: Double = 4
    ) throws -> (store: ProjectStore, engine: FakeEngine, trackID: UUID,
                 groupID: UUID, refLaneID: UUID, takeLaneID: UUID) {
        let ref = Clip(name: "Vocal", startBeat: laneStartBeat, lengthBeats: 8,
                       audioFileURL: Self.refURL)
        let take = Clip(name: "AI Fix 1", startBeat: laneStartBeat, lengthBeats: 8,
                        audioFileURL: Self.takeURL)
        let track = Track(name: "Vox", kind: .audio, clips: [ref, take])
        let store = ProjectStore(tracks: [track])
        let engine = FakeEngine()
        engine.detectTransientsStubByURL = [
            Self.refURL: [0.5, 1.0, 1.5, 2.2].map { TransientMarker(timeSeconds: $0, strength: 1) },
            Self.takeURL: candidateSourceOnsets.map { TransientMarker(timeSeconds: $0, strength: 1) },
        ]
        store.engine = engine
        let group = try store.groupTakes(trackId: track.id, clipIds: [ref.id, take.id])
        return (store, engine, track.id, group.id, group.lanes[0].id, group.lanes[1].id)
    }

    private func lane(_ store: ProjectStore, _ id: UUID) -> TakeLane? {
        store.tracks[0].takeGroups[0].lanes.first { $0.id == id }
    }

    // 1. Happy path: report ≈ the planted +80 ms, lane moved by −offset,
    //    single undo restores it.
    @Test("recovers the planted +80 ms and moves the lane by −offset; one undo restores")
    func applyHappyPath() async throws {
        let (store, engine, trackID, groupID, _, takeLaneID) = try makeAlignedStore()
        let report = try await store.autoAlignTake(
            trackID: trackID, groupID: groupID, laneID: takeLaneID)

        #expect(abs(report.offsetMs - 80.0) < 1e-6)
        #expect(abs(report.offsetBeats - 0.16) < 1e-9)   // 0.08 s @ 120 BPM
        #expect(report.matchedOnsets == 4)
        #expect(report.referenceOnsets == 4)
        #expect(report.candidateOnsets == 4)
        #expect(report.confidence == 1.0)
        #expect(report.applied)

        // The lane moved EARLIER by the offset; the reference never moves.
        #expect(abs((lane(store, takeLaneID)?.clip.startBeat ?? 0) - 3.84) < 1e-9)
        #expect(store.tracks[0].takeGroups[0].lanes[0].clip.startBeat == 4)
        // Members were rebuilt through the usual seam.
        #expect(store.tracks[0].clips.allSatisfy { $0.takeGroupID != nil })
        #expect(engine.calls.contains(.tracksDidChange(count: 1)))

        // ONE undo restores the pre-alignment lane position.
        #expect(try store.undo() == "Align Take")
        #expect(lane(store, takeLaneID)?.clip.startBeat == 4)
    }

    // 2. Detection rides the SHARED engine seam: both lanes' files, 0.5.
    @Test("detects both lanes' files on the shared detector at sensitivity 0.5")
    func sharedDetectorSeam() async throws {
        let (store, engine, trackID, groupID, _, takeLaneID) = try makeAlignedStore()
        _ = try await store.autoAlignTake(trackID: trackID, groupID: groupID, laneID: takeLaneID)
        #expect(engine.detectTransientsCalls.count == 2)
        #expect(engine.detectTransientsCalls.map(\.url) == [Self.refURL, Self.takeURL])
        #expect(engine.detectTransientsCalls.allSatisfy { $0.sensitivity == 0.5 })
    }

    // 3. Dry run: full report, applied false, zero mutation, no undo entry.
    @Test("apply: false previews without mutating (no edit recorded)")
    func dryRun() async throws {
        // Bind the engine: ProjectStore.engine is weak (the app owns the real
        // one) — dropping the strong ref here would nil it mid-test.
        let (store, engine, trackID, groupID, _, takeLaneID) = try makeAlignedStore()
        defer { _ = engine }
        let report = try await store.autoAlignTake(
            trackID: trackID, groupID: groupID, laneID: takeLaneID, apply: false)
        #expect(abs(report.offsetMs - 80.0) < 1e-6)
        #expect(!report.applied)
        #expect(lane(store, takeLaneID)?.clip.startBeat == 4)
        // The newest undo entry is still the grouping — no "Align Take" edit.
        #expect(try store.undo() == "Group Takes")
    }

    // 3b. Regression (v-d verification fix): a positive offset with NO
    //     timeline headroom must THROW, not silently clamp — nothing mutated,
    //     no undo entry, `applied: true` never lies.
    @Test("apply at beat 0 with a positive offset throws alignmentWouldCrossTimelineStart, unmutated")
    func noHeadroomThrows() async throws {
        let (store, engine, trackID, groupID, _, takeLaneID) =
            try makeAlignedStore(laneStartBeat: 0)
        defer { _ = engine }
        do {
            _ = try await store.autoAlignTake(trackID: trackID, groupID: groupID, laneID: takeLaneID)
            Issue.record("expected alignmentWouldCrossTimelineStart")
        } catch let error as ProjectError {
            guard case .alignmentWouldCrossTimelineStart(let message) = error else {
                Issue.record("expected alignmentWouldCrossTimelineStart, got \(error)"); return
            }
            #expect(message.contains("80.0 ms"))          // required move
            #expect(message.contains("0.1600 beats"))
            #expect(message.contains("starts at beat 0.0000"))
            #expect(message.contains("0.0 ms of headroom"))
            #expect(message.contains("take.move"))
        } catch { Issue.record("unexpected error: \(error)") }
        // Project unmutated: lane still at 0, newest undo entry is still the
        // grouping (no "Align Take" edit was recorded).
        #expect(lane(store, takeLaneID)?.clip.startBeat == 0)
        #expect(try store.undo() == "Group Takes")
        // A dry run of the same impossible apply still measures fine.
        _ = try store.redo()
        let preview = try await store.autoAlignTake(
            trackID: trackID, groupID: groupID, laneID: takeLaneID, apply: false)
        #expect(abs(preview.offsetMs - 80.0) < 1e-6)
        #expect(!preview.applied)
    }

    // 3c. Closed loop: after a successful apply, a second dry-run measure
    //     reads ~0 — catches any future mapping bug, not just the clamp.
    @Test("closed loop: apply then re-measure reads ~0 ms")
    func closedLoopResidual() async throws {
        let (store, engine, trackID, groupID, _, takeLaneID) = try makeAlignedStore()
        defer { _ = engine }
        let first = try await store.autoAlignTake(
            trackID: trackID, groupID: groupID, laneID: takeLaneID)
        #expect(abs(first.offsetMs - 80.0) < 1e-6)
        let second = try await store.autoAlignTake(
            trackID: trackID, groupID: groupID, laneID: takeLaneID, apply: false)
        #expect(abs(second.offsetMs) < 3.0)
        #expect(!second.applied)
        // The lane still sits at the aligned position.
        #expect(abs((lane(store, takeLaneID)?.clip.startBeat ?? 0) - 3.84) < 1e-9)
    }

    // 4. Aligning the reference lane against itself is rejected.
    @Test("lane 0 (the reference) rejected with invalidComp")
    func selfAlignRejected() async throws {
        let (store, _, trackID, groupID, refLaneID, _) = try makeAlignedStore()
        await #expect(throws: ProjectError.self) {
            try await store.autoAlignTake(trackID: trackID, groupID: groupID, laneID: refLaneID)
        }
        do {
            _ = try await store.autoAlignTake(trackID: trackID, groupID: groupID, laneID: refLaneID)
        } catch let error as ProjectError {
            guard case .invalidComp(let message) = error else {
                Issue.record("expected invalidComp, got \(error)"); return
            }
            #expect(message.contains("first lane"))
            #expect(message.contains("reference"))
        } catch { Issue.record("unexpected error: \(error)") }
    }

    // 5. Not-found family: track, group, lane.
    @Test("unknown track/group/lane surface the not-found errors")
    func notFoundErrors() async throws {
        let (store, _, trackID, groupID, _, takeLaneID) = try makeAlignedStore()
        do {
            _ = try await store.autoAlignTake(trackID: UUID(), groupID: groupID, laneID: takeLaneID)
            Issue.record("expected trackNotFound")
        } catch let error as ProjectError {
            guard case .trackNotFound = error else { Issue.record("got \(error)"); return }
        }
        do {
            _ = try await store.autoAlignTake(trackID: trackID, groupID: UUID(), laneID: takeLaneID)
            Issue.record("expected takeGroupNotFound")
        } catch let error as ProjectError {
            guard case .takeGroupNotFound = error else { Issue.record("got \(error)"); return }
        }
        do {
            _ = try await store.autoAlignTake(trackID: trackID, groupID: groupID, laneID: UUID())
            Issue.record("expected laneNotFound")
        } catch let error as ProjectError {
            guard case .laneNotFound = error else { Issue.record("got \(error)"); return }
        }
    }

    // 6. Too few matched onsets → alignmentInconclusive with counts + advice.
    @Test("inconclusive alignment throws alignmentInconclusive with onset counts")
    func inconclusiveThrows() async throws {
        // Engine bound: ProjectStore.engine is weak (see dryRun).
        let (store, engine, trackID, groupID, _, takeLaneID) =
            try makeAlignedStore(candidateSourceOnsets: [3.9])   // one lonely onset
        defer { _ = engine }
        do {
            _ = try await store.autoAlignTake(trackID: trackID, groupID: groupID, laneID: takeLaneID)
            Issue.record("expected alignmentInconclusive")
        } catch let error as ProjectError {
            guard case .alignmentInconclusive(let message) = error else {
                Issue.record("expected alignmentInconclusive, got \(error)"); return
            }
            #expect(message.contains("reference lane has 4 onsets"))
            #expect(message.contains("the take has 1"))
            #expect(message.contains("searchWindowMs"))
            #expect(message.contains("take.move"))
            // Nothing changed.
            #expect(lane(store, takeLaneID)?.clip.startBeat == 4)
        } catch { Issue.record("unexpected error: \(error)") }
    }

    // 7. MIDI lanes rejected (audio-only op).
    @Test("MIDI takes rejected with invalidComp")
    func midiRejected() async throws {
        let a = Clip(name: "m1", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 60, startBeat: 0)])
        let b = Clip(name: "m2", startBeat: 2, lengthBeats: 4,
                     notes: [MIDINote(pitch: 62, startBeat: 0)])
        let track = Track(name: "Keys", kind: .instrument, clips: [a, b])
        let store = ProjectStore(tracks: [track])
        store.engine = FakeEngine()
        let group = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        do {
            _ = try await store.autoAlignTake(
                trackID: track.id, groupID: group.id, laneID: group.lanes[1].id)
            Issue.record("expected invalidComp")
        } catch let error as ProjectError {
            guard case .invalidComp(let message) = error else {
                Issue.record("expected invalidComp, got \(error)"); return
            }
            #expect(message.contains("MIDI take"))
        } catch { Issue.record("unexpected error: \(error)") }
    }

    // 8. Headless → engineUnavailable (after the id/lane validation).
    @Test("no engine → engineUnavailable")
    func headless() async throws {
        let ref = Clip(name: "A", startBeat: 0, lengthBeats: 4, audioFileURL: Self.refURL)
        let take = Clip(name: "B", startBeat: 0, lengthBeats: 4, audioFileURL: Self.takeURL)
        let track = Track(name: "Vox", kind: .audio, clips: [ref, take])
        let store = ProjectStore(tracks: [track])   // no engine
        let group = try store.groupTakes(trackId: track.id, clipIds: [ref.id, take.id])
        do {
            _ = try await store.autoAlignTake(
                trackID: track.id, groupID: group.id, laneID: group.lanes[1].id)
            Issue.record("expected engineUnavailable")
        } catch let error as ProjectError {
            guard case .engineUnavailable = error else { Issue.record("got \(error)"); return }
        } catch { Issue.record("unexpected error: \(error)") }
    }

    // 9. Non-positive window → invalidClipEdit before any work.
    @Test("searchWindowMs <= 0 → invalidClipEdit")
    func nonPositiveWindow() async throws {
        let (store, engine, trackID, groupID, _, takeLaneID) = try makeAlignedStore()
        do {
            _ = try await store.autoAlignTake(
                trackID: trackID, groupID: groupID, laneID: takeLaneID, searchWindowMs: 0)
            Issue.record("expected invalidClipEdit")
        } catch let error as ProjectError {
            guard case .invalidClipEdit = error else { Issue.record("got \(error)"); return }
            #expect(engine.detectTransientsCalls.isEmpty)   // failed fast
        } catch { Issue.record("unexpected error: \(error)") }
    }
}
