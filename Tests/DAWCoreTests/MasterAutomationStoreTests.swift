import Foundation
import Testing
@testable import DAWCore

/// Headless store-level coverage for m15-c master volume automation: the
/// volume-only v1 policy (teaching error verbatim), idempotent add, clamping
/// to the masterVolume range, undo coalescing, the engine twin push on every
/// mutation AND on undo/redo restore, `.dawproj` persistence (round trip,
/// omit-when-empty byte discipline, load sanitization of hand-edited files),
/// the snapshot mirror, and the project-boundary reset.
@MainActor
@Suite("Master automation — ProjectStore (m15-c)")
struct MasterAutomationStoreTests {

    /// Captures every master-automation push crossing the engine seam — the
    /// twin-push assertions (mutations, undo/redo, project boundaries).
    final class LaneCapturingEngine: AudioEngineControlling {
        var masterAutomationPushes: [[AutomationLane]] = []
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?

        func masterAutomationChanged(_ lanes: [AutomationLane]) {
            masterAutomationPushes.append(lanes)
        }

        func prepare() throws {}
        func shutdown() {}
        func tracksDidChange(_ tracks: [Track]) {}
        func startPlayback(_ transport: TransportState) {}
        func stopPlayback() {}
        func seek(_ transport: TransportState) {}
        func setTempo(_ transport: TransportState) {}
        func loopChanged(_ transport: TransportState) {}
        func masterVolumeChanged(_ volume: Double) {}
        func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                           masterEffects: [EffectDescriptor],
                           masterAutomation: [AutomationLane],
                           fromBeat: Double, durationSeconds: Double,
                           to url: URL) async throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
        }
        var recordPermission: RecordPermission = .granted
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
            completion(true)
        }
        func setInputDevice(uid: String?) throws {}
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
        func stopRecording() {}
    }

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawproj-master-auto-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - CRUD policy

    @Test("addMasterAutomationLane: volume only, idempotent; non-volume targets teach verbatim")
    func addLaneVolumeOnlyAndIdempotent() throws {
        let store = ProjectStore()

        let first = try store.addMasterAutomationLane(target: .volume)
        let depth = store.journal.undoStack.count
        let second = try store.addMasterAutomationLane(target: .volume)
        #expect(first.id == second.id)                      // same lane returned
        #expect(store.masterAutomation.count == 1)
        #expect(store.journal.undoStack.count == depth)     // no new edit recorded

        // Every non-volume target → the SAME named teaching error, verbatim.
        for target: AutomationTarget in [
            .pan,
            .sendLevel(sendID: UUID()),
            .effectParam(effectID: UUID(), paramName: "gainLinear"),
        ] {
            let error = projectError { _ = try store.addMasterAutomationLane(target: target) }
            guard case .masterAutomationVolumeOnly = try #require(error) else {
                Issue.record("expected masterAutomationVolumeOnly for \(target)"); return
            }
            #expect(error?.errorDescription ==
                "master automation supports the volume target only in v1 — pan, sendLevel, and effectParam lanes live on tracks (pass a track UUID)")
        }
        #expect(store.masterAutomation.count == 1)          // nothing leaked in
    }

    @Test("setMasterAutomationPoints clamps to the masterVolume range and canonicalizes")
    func setPointsClampsToMasterVolumeRange() throws {
        let store = ProjectStore()
        let lane = try store.addMasterAutomationLane(target: .volume)

        let updated = try store.setMasterAutomationPoints(laneID: lane.id, points: [
            AutomationPoint(beat: 8, value: 5),     // → 2 (Track.volumeRange, the setMasterVolume clamp)
            AutomationPoint(beat: 0, value: -1),    // → 0
        ])
        #expect(updated.points.map(\.beat) == [0, 8])       // canonical order
        #expect(updated.points.map(\.value) == [0, 2])      // clamped

        // Unknown lane id → automationLaneNotFound, reused verbatim.
        let ghost = UUID()
        let error = projectError {
            _ = try store.setMasterAutomationPoints(laneID: ghost, points: [])
        }
        guard case .automationLaneNotFound(let id) = try #require(error) else {
            Issue.record("expected automationLaneNotFound"); return
        }
        #expect(id == ghost)
    }

    @Test("point scrubs coalesce; ONE undo restores and pushes the engine twin")
    func pointScrubsCoalesceAndUndoPushesTwin() throws {
        let engine = LaneCapturingEngine()
        let store = ProjectStore()
        store.engine = engine
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        let lane = try store.addMasterAutomationLane(target: .volume)
        #expect(engine.masterAutomationPushes.count == 1)   // the add pushed
        let depth = store.journal.undoStack.count

        _ = try store.setMasterAutomationPoints(laneID: lane.id, points: [
            AutomationPoint(beat: 0, value: 1),
        ])
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.setMasterAutomationPoints(laneID: lane.id, points: [
            AutomationPoint(beat: 0, value: 1),
            AutomationPoint(beat: 8, value: 0),
        ])
        // One coalesced step (the fader-drag rule); each write pushed the twin.
        #expect(store.journal.undoStack.count == depth + 1)
        #expect(store.masterAutomation.first?.points.count == 2)
        #expect(engine.masterAutomationPushes.count == 3)

        // ONE undo restores the empty point set AND pushes the twin.
        try store.undo()
        #expect(store.masterAutomation.first?.points.isEmpty == true)
        #expect(engine.masterAutomationPushes.count == 4)
        // Redo replays the coalesced write, twin included.
        try store.redo()
        #expect(store.masterAutomation.first?.points.count == 2)
        #expect(engine.masterAutomationPushes.count == 5)
    }

    @Test("enable toggles coalesce; remove + undo restores the lane with points")
    func enableCoalescesAndRemoveUndoRestores() throws {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        let lane = try store.addMasterAutomationLane(target: .volume)
        _ = try store.setMasterAutomationPoints(laneID: lane.id, points: [
            AutomationPoint(beat: 0, value: 0.5, curve: .hold),
        ])
        let depth = store.journal.undoStack.count

        _ = try store.setMasterAutomationLaneEnabled(laneID: lane.id, false)
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.setMasterAutomationLaneEnabled(laneID: lane.id, true)
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.setMasterAutomationLaneEnabled(laneID: lane.id, false)
        #expect(store.journal.undoStack.count == depth + 1)  // ONE coalesced step
        #expect(store.masterAutomation.first?.isEnabled == false)
        try store.undo()
        #expect(store.masterAutomation.first?.isEnabled == true)

        // Remove, then ONE undo resurrects the lane intact.
        try store.removeMasterAutomationLane(laneID: lane.id)
        #expect(store.masterAutomation.isEmpty)
        try store.undo()
        #expect(store.masterAutomation.first?.id == lane.id)
        #expect(store.masterAutomation.first?.points.first?.value == 0.5)
        #expect(store.masterAutomation.first?.points.first?.curve == .hold)
    }

    // MARK: - Persistence (the m12-f mirror-DTO discipline: disk is the proof)

    @Test("master lane round-trips through a .dawproj bundle")
    func persistenceRoundTripsMasterLane() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let lane = try store.addMasterAutomationLane(target: .volume)
        _ = try store.setMasterAutomationPoints(laneID: lane.id, points: [
            AutomationPoint(beat: 0, value: 1, curve: .linear),
            AutomationPoint(beat: 16, value: 0, curve: .hold),
        ])
        _ = try store.setMasterAutomationLaneEnabled(laneID: lane.id, false)

        let path = dir.appendingPathComponent("Fade").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let reLane = try #require(reopened.masterAutomation.first)
        #expect(reLane.id == lane.id)
        #expect(reLane.target == .volume)
        #expect(reLane.points.map(\.beat) == [0, 16])
        #expect(reLane.points.map(\.value) == [1, 0])
        #expect(reLane.points.map(\.curve) == [.linear, .hold])
        #expect(reLane.isEnabled == false)
    }

    @Test("no master lane ⇒ no masterAutomation key on disk (omit-when-empty)")
    func noLaneOmitsDiskKey() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.addTrack(name: "Vox", kind: .audio)
        let path = dir.appendingPathComponent("Plain").path
        try store.saveProject(to: path)

        let jsonURL = URL(fileURLWithPath: store.projectPath!)
            .appendingPathComponent("project.json")
        let json = try String(contentsOf: jsonURL, encoding: .utf8)
        #expect(!json.contains("masterAutomation"))
    }

    @Test("load sanitizes hand-edited files: non-volume lanes and duplicates drop with warnings")
    func loadSanitizesHandEditedMasterLanes() throws {
        // Build a document DIRECTLY (a hand-edited file the store could never
        // have produced): a pan lane, then TWO volume lanes.
        let volA = AutomationLane(target: .volume,
                                  points: [AutomationPoint(beat: 0, value: 0.5)])
        let volB = AutomationLane(target: .volume)
        let document = ProjectDocument(
            name: "Edited", transport: TransportState(), tracks: [], masterVolume: 1,
            mediaRefs: [:],
            masterAutomation: [AutomationLane(target: .pan), volA, volB])
        let runtime = document.runtimeState(bundleURL: URL(fileURLWithPath: "/tmp"))

        #expect(runtime.masterAutomation.count == 1)
        #expect(runtime.masterAutomation.first?.id == volA.id)  // first volume lane wins
        #expect(runtime.warnings.contains(
            "non-volume master automation lane — dropped (master automation supports the volume target only in v1)"))
        #expect(runtime.warnings.contains(
            "duplicate master volume automation lane — dropped (the master holds one volume lane)"))
    }

    @Test("legacy document without the key loads clean (empty master automation)")
    func legacyDocumentLoadsClean() throws {
        // A pre-m15-c payload: no masterAutomation key anywhere.
        let json = """
        {"schemaVersion": 1, "name": "Old", "masterVolume": 0.8,
         "transport": {"tempoBPM": 120}, "tracks": []}
        """
        let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(json.utf8))
        #expect(document.masterAutomation == nil)
        let runtime = document.runtimeState(bundleURL: URL(fileURLWithPath: "/tmp"))
        #expect(runtime.masterAutomation.isEmpty)
        #expect(runtime.warnings.isEmpty)
    }

    // MARK: - Snapshot mirror + project boundary

    @Test("snapshot surfaces masterAutomation (track lane shape, master owner); omitted when empty")
    func snapshotMirrorsMasterAutomation() throws {
        let store = ProjectStore()

        // Empty → the key is omitted (nil), pre-m15-c snapshots byte-identical.
        #expect(store.snapshot().masterAutomation == nil)
        let emptyJSON = String(decoding: try JSONEncoder().encode(store.snapshot()), as: UTF8.self)
        #expect(!emptyJSON.contains("masterAutomation"))

        let lane = try store.addMasterAutomationLane(target: .volume)
        _ = try store.setMasterAutomationPoints(laneID: lane.id, points: [
            AutomationPoint(beat: 4, value: 0.25),
        ])
        let mirrored = try #require(store.snapshot().masterAutomation)
        #expect(mirrored.count == 1)
        #expect(mirrored.first?.id == lane.id)
        #expect(mirrored.first?.target == .volume)
        #expect(mirrored.first?.points.first?.value == 0.25)
        #expect(mirrored.first?.isEnabled == true)
    }

    @Test("project.new resets the master lane and pushes the empty twin")
    func newProjectResetsMasterAutomation() throws {
        let engine = LaneCapturingEngine()
        let store = ProjectStore()
        store.engine = engine
        _ = try store.addMasterAutomationLane(target: .volume)
        #expect(!store.masterAutomation.isEmpty)

        try store.newProject(discardChanges: true)
        #expect(store.masterAutomation.isEmpty)
        #expect(engine.masterAutomationPushes.last?.isEmpty == true)
    }
}
