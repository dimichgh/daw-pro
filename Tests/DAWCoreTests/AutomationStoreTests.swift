import Foundation
import Testing
@testable import DAWCore

/// Headless store-level coverage for M4 (vii-a) automation CRUD: idempotent lane
/// add, the v0 rejections (send-level, AU-effect param, unknown effect id),
/// value clamping + undo coalescing on point/enable edits, the remove-effect
/// cascade in a single undo step, and `.dawproj` persistence (round trip plus
/// pre-automation byte-identity).
@MainActor
@Suite("Automation — ProjectStore")
struct AutomationStoreTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func track(_ store: ProjectStore, _ id: UUID) -> Track {
        store.tracks.first(where: { $0.id == id })!
    }

    private func lane(_ store: ProjectStore, _ trackID: UUID, _ laneID: UUID) -> AutomationLane {
        track(store, trackID).automation.first(where: { $0.id == laneID })!
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawproj-automation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("addAutomationLane is idempotent per target")
    func addLaneIsIdempotentPerTarget() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)

        let first = try store.addAutomationLane(trackID: t.id, target: .volume)
        let depth = store.journal.undoStack.count
        let second = try store.addAutomationLane(trackID: t.id, target: .volume)

        #expect(first.id == second.id)                          // same lane returned
        #expect(track(store, t.id).automation.count == 1)
        #expect(store.journal.undoStack.count == depth)         // no new edit recorded
    }

    @Test("addAutomationLane rejects send-level targets in v0")
    func addLaneRejectsSendLevelInV0() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let bus = store.addTrack(name: "Reverb Bus", kind: .bus)
        let send = try store.addSend(toTrack: t.id, busID: bus.id)

        let error = projectError {
            _ = try store.addAutomationLane(trackID: t.id, target: .sendLevel(sendID: send.id))
        }
        guard case .automationTargetNotSupported = try #require(error) else {
            Issue.record("expected automationTargetNotSupported, got \(String(describing: error))"); return
        }
        #expect(track(store, t.id).automation.isEmpty)
    }

    @Test("addAutomationLane rejects an AU effect-param target")
    func addLaneRejectsAUEffectParam() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let au = try store.addEffect(
            toTrack: t.id, kind: .audioUnit,
            audioUnit: AudioUnitConfig(component: AudioUnitComponentID(
                type: "aufx", subType: "dcmp", manufacturer: "acme")))

        let error = projectError {
            _ = try store.addAutomationLane(
                trackID: t.id, target: .effectParam(effectID: au.id, paramName: "gain"))
        }
        guard case .automationTargetNotSupported = try #require(error) else {
            Issue.record("expected automationTargetNotSupported, got \(String(describing: error))"); return
        }
        #expect(track(store, t.id).automation.isEmpty)
    }

    @Test("addAutomationLane rejects an unknown effect id")
    func addLaneRejectsUnknownEffectID() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let ghost = UUID()

        let error = projectError {
            _ = try store.addAutomationLane(
                trackID: t.id, target: .effectParam(effectID: ghost, paramName: "gainLinear"))
        }
        guard case .automationTargetUnresolvable = try #require(error) else {
            Issue.record("expected automationTargetUnresolvable, got \(String(describing: error))"); return
        }
        #expect(track(store, t.id).automation.isEmpty)
    }

    @Test("setAutomationPoints clamps every value to the target range")
    func setPointsClampsValuesToTargetRange() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)

        // Volume lane clamps to 0...2.
        let volLane = try store.addAutomationLane(trackID: t.id, target: .volume)
        let vol = try store.setAutomationPoints(trackID: t.id, laneID: volLane.id, points: [
            AutomationPoint(beat: 0, value: -1),   // → 0
            AutomationPoint(beat: 4, value: 5),    // → 2
        ])
        #expect(vol.points.map(\.value) == [0, 2])

        // Pan lane clamps to -1...1.
        let panLane = try store.addAutomationLane(trackID: t.id, target: .pan)
        let pan = try store.setAutomationPoints(trackID: t.id, laneID: panLane.id, points: [
            AutomationPoint(beat: 0, value: -3),   // → -1
            AutomationPoint(beat: 2, value: 3),    // → 1
        ])
        #expect(pan.points.map(\.value) == [-1, 1])
    }

    @Test("point scrubs inside the window coalesce under one undo key")
    func setPointsCoalescesUnderOneUndoKey() throws {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        let t = store.addTrack(name: "Vox", kind: .audio)
        let l = try store.addAutomationLane(trackID: t.id, target: .volume)
        let depth = store.journal.undoStack.count

        _ = try store.setAutomationPoints(trackID: t.id, laneID: l.id, points: [
            AutomationPoint(beat: 0, value: 0.5),
        ])
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.setAutomationPoints(trackID: t.id, laneID: l.id, points: [
            AutomationPoint(beat: 0, value: 0.5),
            AutomationPoint(beat: 4, value: 1.5),
        ])

        // One coalesced step; current state is the last write.
        #expect(store.journal.undoStack.count == depth + 1)
        #expect(lane(store, t.id, l.id).points.count == 2)

        // A single undo restores the ORIGINAL (empty) point set.
        try store.undo()
        #expect(lane(store, t.id, l.id).points.isEmpty)
    }

    @Test("removeEffect drops the effect's automation lanes in the same undo step")
    func removeEffectDropsItsLanesInSameUndoStep() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let fx = try store.addEffect(toTrack: t.id, kind: .gain)
        let l = try store.addAutomationLane(
            trackID: t.id, target: .effectParam(effectID: fx.id, paramName: "gainLinear"))
        _ = try store.setAutomationPoints(trackID: t.id, laneID: l.id, points: [
            AutomationPoint(beat: 0, value: 2),
        ])
        let depth = store.journal.undoStack.count

        try store.removeEffect(trackID: t.id, effectID: fx.id)
        // The effect AND its lane vanish together, as ONE undo step.
        #expect(track(store, t.id).effects.isEmpty)
        #expect(track(store, t.id).automation.isEmpty)
        #expect(store.journal.undoStack.count == depth + 1)

        // A single undo restores BOTH the effect and its lane (with its points).
        try store.undo()
        #expect(track(store, t.id).effects.count == 1)
        #expect(track(store, t.id).automation.count == 1)
        #expect(track(store, t.id).automation.first?.points.first?.value == 2)
    }

    @Test("lane enable toggles and coalesces under one undo key")
    func laneEnableTogglesAndCoalesces() throws {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        let t = store.addTrack(name: "Vox", kind: .audio)
        let l = try store.addAutomationLane(trackID: t.id, target: .volume)
        #expect(lane(store, t.id, l.id).isEnabled == true)
        let depth = store.journal.undoStack.count

        _ = try store.setAutomationLaneEnabled(trackID: t.id, laneID: l.id, false)
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.setAutomationLaneEnabled(trackID: t.id, laneID: l.id, true)
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.setAutomationLaneEnabled(trackID: t.id, laneID: l.id, false)

        // Three toggles inside the window collapse to ONE undo step.
        #expect(store.journal.undoStack.count == depth + 1)
        #expect(lane(store, t.id, l.id).isEnabled == false)

        // A single undo restores the ORIGINAL enabled state.
        try store.undo()
        #expect(lane(store, t.id, l.id).isEnabled == true)
    }

    @Test("automation lanes round-trip through a .dawproj bundle")
    func persistenceRoundTripsLanes() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)

        let volLane = try store.addAutomationLane(trackID: t.id, target: .volume)
        _ = try store.setAutomationPoints(trackID: t.id, laneID: volLane.id, points: [
            AutomationPoint(beat: 0, value: 0.5, curve: .hold),
            AutomationPoint(beat: 4, value: 1.5, curve: .linear),
        ])
        let eq = try store.addEffect(toTrack: t.id, kind: .eq)
        let fxLane = try store.addAutomationLane(
            trackID: t.id, target: .effectParam(effectID: eq.id, paramName: "peak1GainDb"))
        _ = try store.setAutomationPoints(trackID: t.id, laneID: fxLane.id, points: [
            AutomationPoint(beat: 2, value: 6),
        ])
        _ = try store.setAutomationLaneEnabled(trackID: t.id, laneID: fxLane.id, false)

        let path = dir.appendingPathComponent("Autom").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let reTrack = try #require(reopened.tracks.first(where: { $0.name == "Vox" }))
        #expect(reTrack.automation.count == 2)

        let reVol = try #require(reTrack.automation.first(where: { $0.target == .volume }))
        #expect(reVol.points.count == 2)
        #expect(reVol.points[0].value == 0.5)
        #expect(reVol.points[0].curve == .hold)
        #expect(reVol.points[1].value == 1.5)
        #expect(reVol.isEnabled == true)

        let reFx = try #require(reTrack.automation.first(where: {
            $0.target == .effectParam(effectID: eq.id, paramName: "peak1GainDb")
        }))
        #expect(reFx.isEnabled == false)
        #expect(reFx.points.first?.value == 6)
    }

    @Test("a project with no automation carries no automation key")
    func preAutomationProjectSavesByteIdentical() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.addTrack(name: "Vox", kind: .audio)          // no automation
        let path = dir.appendingPathComponent("Plain").path
        try store.saveProject(to: path)

        let jsonURL = URL(fileURLWithPath: store.projectPath!)
            .appendingPathComponent("project.json")
        let json = try String(contentsOf: jsonURL, encoding: .utf8)
        #expect(!json.contains("automation"))
    }
}
