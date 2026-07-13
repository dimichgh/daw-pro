import Foundation
import Testing
@testable import DAWCore

/// m13-d master insert chain — the DAWCore store surface (design §4) plus
/// the C5 persistence/mirror-DTO gate (design §8):
///
///  · Five verbs mirroring the track chain: labels, guards OUTSIDE edit
///    bodies, param-scrub coalescing under the master-sentinel key, the
///    SHARED 16-slot cap, and the v1 built-ins-only invariant with its
///    exact teaching error.
///  · Engine publish discipline: `masterEffectsChanged` fires inside EVERY
///    mutating edit body AND at every restore-funnel crossing (undo/redo,
///    project.new, open) — and never for chain-irrelevant edits.
///  · C5: save→reopen deep-equal; `snapshot().masterEffects` mirror (the
///    m12-f MIRROR-DTO discipline — three surfaces, disk goes through
///    ProjectDocument DTOs); empty chain writes NO `masterEffects` key; a
///    hand-edited document with `audioUnit`-kind / keyed / unknown-kind
///    master entries loads SANITIZED with the exact warnings.
@MainActor
@Suite("Master insert chain — ProjectStore (m13-d, C5)")
struct MasterChainStoreTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawproj-masterfx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Verbs

    @Test("addMasterEffect appends, inserts at index, labels, and pushes the chain")
    func addAppendsInsertsAndPushes() throws {
        let store = ProjectStore()
        let engine = FakeEngine()
        store.engine = engine

        let eq = try store.addMasterEffect(kind: .eq)
        #expect(store.undoLabel == "Add EQ to Master")
        let limiter = try store.addMasterEffect(kind: .limiter)
        // Head insert — order becomes [gain, eq, limiter].
        let gain = try store.addMasterEffect(kind: .gain, at: 0)
        #expect(store.undoLabel == "Add Gain to Master")

        #expect(store.masterEffects.map(\.id) == [gain.id, eq.id, limiter.id])
        // One publish per mutation, each carrying the full post-edit chain.
        #expect(engine.masterEffectsPushes.count == 3)
        #expect(engine.masterEffectsPushes.last == store.masterEffects)
    }

    @Test("v1 invariant: .audioUnit throws masterChainBuiltInOnly with the exact teaching string")
    func builtInOnlyTeachingError() throws {
        let store = ProjectStore()
        let error = projectError { _ = try store.addMasterEffect(kind: .audioUnit) }
        guard case .masterChainBuiltInOnly = try #require(error) else {
            Issue.record("expected masterChainBuiltInOnly, got \(String(describing: error))")
            return
        }
        #expect(error?.errorDescription
                == "the master chain hosts built-in effects only in v1 — pick one of gain|eq|compressor|limiter|reverb|delay|saturator|gate|chorus")
        #expect(store.masterEffects.isEmpty)
        #expect(store.undoLabel == nil)  // guard sits OUTSIDE the edit body
    }

    @Test("the master chain shares the 16-slot cap (chainFull, no journal entry)")
    func sharedChainCap() throws {
        let store = ProjectStore()
        for _ in 0..<ProjectStore.maxEffectsPerChain {
            _ = try store.addMasterEffect(kind: .gain)
        }
        #expect(store.masterEffects.count == 16)

        let depth = store.journal.undoStack.count
        let error = projectError { _ = try store.addMasterEffect(kind: .gain) }
        guard case .chainFull(let cap) = try #require(error) else {
            Issue.record("expected chainFull, got \(String(describing: error))"); return
        }
        #expect(cap == 16)
        #expect(store.masterEffects.count == 16)
        #expect(store.journal.undoStack.count == depth)
    }

    @Test("remove/reorder/bypass: labels, final-index semantics, effectNotFound uniformity")
    func removeReorderBypassVerbs() throws {
        let store = ProjectStore()
        let engine = FakeEngine()
        store.engine = engine
        let a = try store.addMasterEffect(kind: .gain)
        let b = try store.addMasterEffect(kind: .eq)
        let c = try store.addMasterEffect(kind: .compressor)
        let pushesAfterAdds = engine.masterEffectsPushes.count

        // Reorder: a (index 0) to the tail — [b, c, a]; over-large index clamps.
        try store.reorderMasterEffect(effectID: a.id, toIndex: 99)
        #expect(store.masterEffects.map(\.id) == [b.id, c.id, a.id])
        #expect(store.undoLabel == "Reorder Master Effects")

        // Bypass / unbypass — atomic flag steps, two SEPARATE undo entries.
        try store.setMasterEffectBypassed(effectID: b.id, bypassed: true)
        #expect(store.undoLabel == "Bypass EQ on Master")
        #expect(store.masterEffects.first?.isBypassed == true)
        try store.setMasterEffectBypassed(effectID: b.id, bypassed: false)
        #expect(store.undoLabel == "Unbypass EQ on Master")
        #expect(store.masterEffects.first?.isBypassed == false)

        try store.removeMasterEffect(effectID: c.id)
        #expect(store.masterEffects.map(\.id) == [b.id, a.id])
        #expect(store.undoLabel == "Remove Compressor from Master")

        // Every verb pushed exactly once.
        #expect(engine.masterEffectsPushes.count == pushesAfterAdds + 4)

        // Unknown id → effectNotFound from every id-taking verb; no journal entry.
        let ghost = UUID()
        let depth = store.journal.undoStack.count
        let errors: [ProjectError?] = [
            projectError { try store.removeMasterEffect(effectID: ghost) },
            projectError { try store.reorderMasterEffect(effectID: ghost, toIndex: 0) },
            projectError { try store.setMasterEffectBypassed(effectID: ghost, bypassed: true) },
            projectError { _ = try store.setMasterEffectParam(effectID: ghost, name: "gainLinear", value: 1) },
        ]
        for error in errors {
            guard case .effectNotFound(let id) = try #require(error) else {
                Issue.record("expected effectNotFound, got \(String(describing: error))")
                return
            }
            #expect(id == ghost)
        }
        #expect(store.journal.undoStack.count == depth)
    }

    @Test("setMasterEffectParam: spec-validated name, silent clamp, per-(effect,name) coalescing")
    func paramValidationClampAndCoalescing() throws {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        let limiter = try store.addMasterEffect(kind: .limiter)

        // Unknown name → teaching error listing the valid names.
        let error = projectError {
            _ = try store.setMasterEffectParam(effectID: limiter.id, name: "threshold", value: -6)
        }
        guard case .unknownEffectParam(let message) = try #require(error) else {
            Issue.record("expected unknownEffectParam, got \(String(describing: error))")
            return
        }
        #expect(message == "unknown parameter 'threshold' for limiter effect — valid: ceilingDb, releaseMs")

        // Silent clamp to the spec range (ceilingDb ∈ −24…0).
        let clamped = try store.setMasterEffectParam(
            effectID: limiter.id, name: "ceilingDb", value: -500)
        #expect(clamped.resolvedLimiter.ceilingDb == -24)
        #expect(store.undoLabel == "Set Limiter Parameter")

        // A scrub on ONE (effect, name) coalesces to one undo step...
        let depth = store.journal.undoStack.count
        _ = try store.setMasterEffectParam(effectID: limiter.id, name: "ceilingDb", value: -3)
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.setMasterEffectParam(effectID: limiter.id, name: "ceilingDb", value: -6)
        #expect(store.journal.undoStack.count == depth)  // folded into the clamp entry above
        #expect(store.masterEffects.first?.resolvedLimiter.ceilingDb == -6)

        // ...while a DIFFERENT name opens its own entry (per-name key).
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.setMasterEffectParam(effectID: limiter.id, name: "releaseMs", value: 100)
        #expect(store.journal.undoStack.count == depth + 1)

        // One undo per key: releaseMs back to default, then the whole
        // ceiling scrub back to default in a single step.
        try store.undo()
        #expect(store.masterEffects.first?.resolvedLimiter.releaseMs == LimiterParams().releaseMs)
        try store.undo()
        #expect(store.masterEffects.first?.resolvedLimiter.ceilingDb == LimiterParams().ceilingDb)
    }

    // MARK: - Engine publish discipline (restore funnel)

    @Test("undo/redo re-publish the chain exactly when it changed; unrelated edits never push")
    func restoreFunnelPushes() throws {
        let store = ProjectStore()
        let engine = FakeEngine()
        store.engine = engine

        let fx = try store.addMasterEffect(kind: .compressor)
        #expect(engine.masterEffectsPushes.count == 1)

        // A chain-irrelevant edit + its undo cross the funnel WITHOUT a push
        // (restore computes masterFXChanged and skips the twin).
        _ = store.addTrack(name: "T", kind: .audio)
        try store.undo()
        #expect(engine.masterEffectsPushes.count == 1)

        try store.undo()  // undo the master add
        #expect(store.masterEffects.isEmpty)
        #expect(engine.masterEffectsPushes.count == 2)
        #expect(engine.masterEffectsPushes.last == [])

        try store.redo()
        #expect(store.masterEffects.map(\.id) == [fx.id])
        #expect(engine.masterEffectsPushes.count == 3)
        #expect(engine.masterEffectsPushes.last == store.masterEffects)
    }

    @Test("project.new resets the master chain and publishes the empty chain")
    func newProjectResets() throws {
        let store = ProjectStore()
        let engine = FakeEngine()
        store.engine = engine
        _ = try store.addMasterEffect(kind: .limiter)
        #expect(!store.masterEffects.isEmpty)

        try store.newProject(discardChanges: true)
        #expect(store.masterEffects.isEmpty)
        #expect(engine.masterEffectsPushes.last == [])
    }

    // MARK: - C5: persistence / mirror-DTO

    @Test("C5: save then reopen restores the chain deep-equal; snapshot mirrors it; open publishes")
    func saveReopenDeepEqualAndSnapshotMirror() throws {
        let dir = tempDir()
        let store = ProjectStore()
        // Edited params + one bypassed entry — the C5 recipe.
        let gain = try store.addMasterEffect(kind: .gain)
        _ = try store.setMasterEffectParam(effectID: gain.id, name: "gainLinear", value: 0.5)
        let limiter = try store.addMasterEffect(kind: .limiter)
        _ = try store.setMasterEffectParam(effectID: limiter.id, name: "ceilingDb", value: -6)
        let eq = try store.addMasterEffect(kind: .eq)
        try store.setMasterEffectBypassed(effectID: eq.id, bypassed: true)
        let saved = store.masterEffects

        // Snapshot mirror (m12-f second surface).
        #expect(store.snapshot().masterEffects == saved)

        let path = dir.appendingPathComponent("Mastered").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        let engine = FakeEngine()
        reopened.engine = engine
        let warnings = try reopened.openProject(at: path)
        #expect(warnings.isEmpty)
        // Deep-equal INCLUDING ids, params, bypass flags (disk surface —
        // the ProjectDocument DTO, not descriptor Codable).
        #expect(reopened.masterEffects == saved)
        #expect(reopened.masterEffects[1].resolvedLimiter.ceilingDb == -6)
        #expect(reopened.masterEffects[2].isBypassed)
        // Open crossed the funnel: the chain was published to the engine.
        #expect(engine.masterEffectsPushes.last == saved)
        // Third mirror check after the round trip.
        #expect(reopened.snapshot().masterEffects == saved)
    }

    @Test("C5: an empty master chain writes NO masterEffects key (omit-when-empty)")
    func emptyChainOmitsKey() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.addTrack()
        try store.saveProject(to: dir.appendingPathComponent("Clean").path)

        let json = try String(
            contentsOf: URL(fileURLWithPath: store.projectPath!)
                .appendingPathComponent("project.json"),
            encoding: .utf8)
        #expect(!json.contains("masterEffects"))
    }

    @Test("C5: hand-edited audioUnit-kind / keyed / unknown-kind master entries load SANITIZED with exact warnings")
    func handEditedDocumentSanitizes() throws {
        let dir = tempDir()

        // Entries the store could never have produced (hand-edited file).
        var auEntry = EffectDocument(from: EffectDescriptor(kind: .compressor))
        auEntry.kind = "audioUnit"
        let keySource = UUID()
        let keyedEntry = EffectDocument(from: EffectDescriptor(
            kind: .compressor, sidechainSourceTrackID: keySource))
        var unknownEntry = EffectDocument(from: EffectDescriptor(kind: .gain))
        unknownEntry.kind = "vocoder"
        let validEntry = EffectDocument(from: EffectDescriptor(
            kind: .limiter, limiter: LimiterParams(ceilingDb: -3)))

        var document = ProjectDocument(
            name: "Edited", transport: TransportState(),
            tracks: [Track(name: "T", kind: .audio)], masterVolume: 1,
            mediaRefs: [:])
        document.masterEffects = [auEntry, keyedEntry, unknownEntry, validEntry]
        let bundleURL = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Edited").path)
        try ProjectBundle.write(
            document: document,
            plan: ProjectBundle.MediaPlan(copies: [], refs: [:], warnings: []),
            to: bundleURL)

        let store = ProjectStore()
        let warnings = try store.openProject(at: bundleURL.path)
        #expect(warnings.contains(
            "audioUnit effect on the master chain — dropped (the master chain hosts built-in effects only in v1)"))
        #expect(warnings.contains(
            "sidechain key on master compressor effect — cleared (the master chain cannot host a sidechain-keyed effect)"))
        #expect(warnings.contains(
            "unknown effect kind 'vocoder' on the master chain — effect dropped"))

        // Survivors in order: the keyed compressor (key CLEARED) + the valid
        // limiter, params intact.
        #expect(store.masterEffects.map(\.id) == [keyedEntry.id, validEntry.id])
        #expect(store.masterEffects[0].kind == .compressor)
        #expect(store.masterEffects[0].sidechainSourceTrackID == nil)
        #expect(store.masterEffects[1].resolvedLimiter.ceilingDb == -3)
    }
}
