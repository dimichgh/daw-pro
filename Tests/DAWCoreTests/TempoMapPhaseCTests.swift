import Foundation
import Testing
@testable import DAWCore

/// m12-d Phase C — tempo-map persistence + store mutation + undo (design §9-C).
/// The multi-segment engine math itself is proven in DAWEngineTests; here we
/// exercise the REAL `setTempoMap` mutation, its undo/coalescing behavior, the
/// `transport.setTempo` multi-segment reject, `mapRevision` monotonicity, and
/// the additive persistence round-trip (incl. the null-case byte discipline).
@MainActor
@Suite("Tempo map Phase C — persistence + mutation + undo")
struct TempoMapPhaseCTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m12d-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func multiTempo() throws -> TempoMap {
        try TempoMap(segments: [
            .init(startBeat: 0, bpm: 120),
            .init(startBeat: 8, bpm: 90),
            .init(startBeat: 16, bpm: 140),
        ])
    }

    private func multiMeter() throws -> MeterMap {
        // change at beat 8 falls on a barline of 4/4 (8/4 = 2 bars) → valid.
        try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4),
        ])
    }

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    // MARK: - Mutation installs the map; tempoBPM/timeSignature stay = segment/change 0

    @Test("setTempoMap installs a multi-segment override, keeps scalars = entry 0, bumps mapRevision")
    func setTempoMapInstalls() throws {
        let store = ProjectStore()
        #expect(store.transport.tempoMapOverride == nil)
        #expect(store.mapRevision == 0)

        try store.setTempoMap(multiTempo(), meterMap: multiMeter())

        #expect(store.transport.tempoMapOverride?.segments.count == 3)
        #expect(store.transport.meterMapOverride?.changes.count == 2)
        #expect(store.transport.tempoBPM == 120)                       // segment 0
        #expect(store.transport.timeSignature == TimeSignature(beatsPerBar: 4, beatUnit: 4))
        #expect(store.mapRevision == 1)
        // The resolved map the engine consumes is exactly the authored one.
        #expect(store.transport.tempoMap == (try multiTempo()))
        #expect(store.transport.meterMap == (try multiMeter()))
    }

    @Test("a single-segment map collapses to the scalar fast path (override cleared)")
    func singleSegmentCollapses() throws {
        let store = ProjectStore()
        try store.setTempoMap(TempoMap(segments: [.init(startBeat: 0, bpm: 133)]))
        #expect(store.transport.tempoMapOverride == nil)               // trivial
        #expect(store.transport.tempoBPM == 133)
        #expect(store.transport.tempoMap.segments == [TempoMap.Segment(startBeat: 0, bpm: 133)])
    }

    @Test("omitting meterChanges leaves the current meter map untouched")
    func meterUntouchedWhenOmitted() throws {
        let store = ProjectStore()
        try store.setTempoMap(multiTempo(), meterMap: multiMeter())
        // A second setMap with no meter map keeps the 2-change meter.
        try store.setTempoMap(TempoMap(segments: [
            .init(startBeat: 0, bpm: 100), .init(startBeat: 4, bpm: 80),
        ]))
        #expect(store.transport.meterMapOverride?.changes.count == 2)
        #expect(store.transport.tempoMapOverride?.segments.first?.bpm == 100)
    }

    // MARK: - Undo restores the previous map EXACTLY, in ONE step

    @Test("undo restores the prior map in one step; redo reinstates it")
    func undoRestoresMap() throws {
        let store = ProjectStore()
        try store.setTempoMap(multiTempo(), meterMap: multiMeter())
        #expect(store.transport.tempoMapOverride != nil)

        try store.undo()
        #expect(store.transport.tempoMapOverride == nil)               // back to trivial
        #expect(store.transport.meterMapOverride == nil)
        #expect(store.transport.tempoBPM == 120)

        try store.redo()
        #expect(store.transport.tempoMapOverride?.segments.count == 3)
        #expect(store.transport.meterMapOverride?.changes.count == 2)
    }

    @Test("a burst of setTempoMap calls with the tempo.map key coalesces into ONE undo entry")
    func coalescedDragIsOneUndo() throws {
        let store = ProjectStore()
        // Three rapid map edits (a UI tempo-lane drag) — all share the
        // "tempo.map" coalescing key and land inside the 800 ms window.
        try store.setTempoMap(TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 90)]))
        try store.setTempoMap(TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 95)]))
        try store.setTempoMap(TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 100)]))
        #expect(store.transport.tempoMapOverride?.segments.last?.bpm == 100)

        // ONE undo returns all the way to trivial (the coalesced entry's before).
        try store.undo()
        #expect(store.transport.tempoMapOverride == nil)
        // No second entry — the drag was a single history step.
        #expect(!store.canUndo)
    }

    // MARK: - transport.setTempo fast path / multi-segment reject (pinned message)

    @Test("transport.setTempo rejects on a multi-segment map with a teaching error")
    func setTempoRejectsMultiSegment() throws {
        let store = ProjectStore()
        try store.setTempoMap(multiTempo())
        let error = projectError { try store.setTempo(150) }
        guard case .tempoMapMultiSegment = try #require(error) else {
            Issue.record("expected .tempoMapMultiSegment, got \(String(describing: error))")
            return
        }
        // Exact teaching text is contract (wire + MCP surface it verbatim).
        #expect(error?.errorDescription
            == "this project has a multi-segment tempo map — use tempo.setMap to edit it (transport.setTempo sets a single project-wide tempo and would flatten the map)")
        // The map was not touched by the rejected edit.
        #expect(store.transport.tempoMapOverride?.segments.count == 3)
    }

    @Test("transport.setTempo still works on a trivial project (fast path)")
    func setTempoFastPath() throws {
        let store = ProjectStore()
        try store.setTempo(150)
        #expect(store.transport.tempoBPM == 150)
        #expect(store.transport.tempoMapOverride == nil)
    }

    // MARK: - Recording guard

    @Test("setTempoMap and setTempo are refused while recording")
    func recordingGuard() throws {
        let engine = FakeRecordingEngine()
        engine.recordPermission = .granted
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        #expect(store.transport.isRecording)

        let mapErr = projectError { try store.setTempoMap(multiTempo()) }
        #expect(mapErr?.errorDescription == "cannot change the tempo map while recording — stop first")
        let tempoErr = projectError { try store.setTempo(130) }
        #expect(tempoErr?.errorDescription == "cannot change tempo while recording — stop first")
        store.stop()
    }

    // MARK: - mapRevision monotonicity (Clip-Fix staleness)

    @Test("mapRevision climbs on every map change and NEVER on undo-restore-down")
    func mapRevisionMonotonic() throws {
        let store = ProjectStore()
        #expect(store.mapRevision == 0)
        try store.setTempoMap(multiTempo())
        #expect(store.mapRevision == 1)
        // A scalar tempo edit on a trivial project also bumps the revision.
        let trivial = ProjectStore()
        #expect(trivial.mapRevision == 0)
        try trivial.setTempo(140)
        #expect(trivial.mapRevision == 1)
        try trivial.setTempo(140)              // no change → no bump (coalesced/no-op)
        #expect(trivial.mapRevision == 1)
        // Undo restores the earlier map but the revision only climbs.
        try store.undo()
        #expect(store.transport.tempoMapOverride == nil)
        #expect(store.mapRevision == 2)
    }

    // MARK: - Persistence round-trip (Gate A) + null-case byte discipline (Gate B)

    @Test("save→open restores tempoMap, meterChanges, and mapRevision-continuity")
    func roundTripMap() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()
        try store.setTempoMap(multiTempo(), meterMap: multiMeter())
        let revBefore = store.mapRevision

        let path = dir.appendingPathComponent("Tempo Song").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        try reopened.openProject(at: path)

        #expect(reopened.transport.tempoMapOverride?.segments == (try multiTempo()).segments)
        #expect(reopened.transport.meterMapOverride?.changes == (try multiMeter()).changes)
        #expect(reopened.mapRevision == revBefore)                     // continuity
        #expect(reopened.transport.tempoBPM == 120)
        #expect(reopened.transport.timeSignature == TimeSignature(beatsPerBar: 4, beatUnit: 4))
        // The resolved read-map deep-compares equal across the round trip.
        #expect(reopened.transport.tempoMap == store.transport.tempoMap)
        #expect(reopened.transport.meterMap == store.transport.meterMap)
    }

    @Test("a trivial-map project persists NO tempo/meter keys (byte discipline) and opens with nil fields")
    func trivialProjectByteDiscipline() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()
        _ = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTempo(128)                                        // scalar only

        let path = dir.appendingPathComponent("Plain Song").path
        try store.saveProject(to: path)

        let jsonURL = ProjectBundle.normalizedBundleURL(fromPath: path)
            .appendingPathComponent("project.json")
        let json = try String(contentsOf: jsonURL, encoding: .utf8)
        #expect(!json.contains("tempoMap"))                            // covers tempoMapRevision too
        #expect(!json.contains("meterChanges"))
        #expect(json.contains("tempoBPM"))                             // scalar is authoritative

        // A legacy/trivial project opens with nil overrides + identical scalars.
        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        try reopened.openProject(at: path)
        #expect(reopened.transport.tempoMapOverride == nil)
        #expect(reopened.transport.meterMapOverride == nil)
        #expect(reopened.transport.tempoBPM == 128)
        #expect(reopened.mapRevision == 0)
        // The synthesized read-map is the trivial single segment.
        #expect(reopened.transport.tempoMap.segments == [TempoMap.Segment(startBeat: 0, bpm: 128)])
    }

    // MARK: - Snapshot additive fields

    @Test("snapshot carries tempoMap/meterChanges only for a non-trivial project")
    func snapshotFields() throws {
        let trivial = ProjectStore().snapshot()
        #expect(trivial.tempoMap == nil)
        #expect(trivial.meterChanges == nil)

        let store = ProjectStore()
        try store.setTempoMap(multiTempo(), meterMap: multiMeter())
        let snap = store.snapshot()
        #expect(snap.tempoMap?.count == 3)
        #expect(snap.meterChanges?.count == 2)
        #expect(snap.transport.tempoBPM == 120)
    }
}
