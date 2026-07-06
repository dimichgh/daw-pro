import Foundation
import Testing
@testable import DAWCore

/// Headless store-level coverage for M4 (ii) FX insert chains: add/insert/remove/
/// reorder, the chain cap, param-scrub undo coalescing, chain undo without a
/// track rebuild, and `.dawproj` persistence (round trip, pre-FX byte-identity,
/// unknown-kind forward-compat drop with the exact warning string).
@MainActor
@Suite("FX insert chains — ProjectStore")
struct EffectChainStoreTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func track(_ store: ProjectStore, _ id: UUID) -> Track {
        store.tracks.first(where: { $0.id == id })!
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawproj-fx-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("addEffect appends and returns the new descriptor")
    func addEffectAppendsAndReturnsDescriptor() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)

        let effect = try store.addEffect(toTrack: t.id, kind: .gain)
        #expect(effect.kind == .gain)
        #expect(effect.isBypassed == false)
        #expect(track(store, t.id).effects.count == 1)
        #expect(track(store, t.id).effects.first?.id == effect.id)
        // Default gain resolves to unity even though the stored struct is nil.
        #expect(track(store, t.id).effects.first?.resolvedGain.gainLinear == 1)
        #expect(store.undoLabel == "Add Gain to 'Vox'")
    }

    @Test("addEffect at an index inserts rather than appends")
    func addEffectAtIndexInserts() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let a = try store.addEffect(toTrack: t.id, kind: .gain)
        let b = try store.addEffect(toTrack: t.id, kind: .gain)
        // Insert at the head — order becomes [c, a, b].
        let c = try store.addEffect(toTrack: t.id, kind: .gain, at: 0)

        #expect(track(store, t.id).effects.map(\.id) == [c.id, a.id, b.id])
    }

    @Test("removeEffect deletes the named effect")
    func removeEffectDeletes() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let a = try store.addEffect(toTrack: t.id, kind: .gain)
        let b = try store.addEffect(toTrack: t.id, kind: .gain)

        try store.removeEffect(trackID: t.id, effectID: a.id)
        #expect(track(store, t.id).effects.map(\.id) == [b.id])
        #expect(store.undoLabel == "Remove Gain from 'Vox'")

        // An unknown effect id throws effectNotFound and changes nothing.
        let ghost = UUID()
        let depth = store.journal.undoStack.count
        let error = projectError { try store.removeEffect(trackID: t.id, effectID: ghost) }
        guard case .effectNotFound(let id) = try #require(error) else {
            Issue.record("expected effectNotFound, got \(String(describing: error))"); return
        }
        #expect(id == ghost)
        #expect(store.journal.undoStack.count == depth)
    }

    @Test("reorderEffect moves an effect to a new index")
    func reorderEffectMoves() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let a = try store.addEffect(toTrack: t.id, kind: .gain)
        let b = try store.addEffect(toTrack: t.id, kind: .gain)
        let c = try store.addEffect(toTrack: t.id, kind: .gain)

        // Move a (index 0) to the tail — order becomes [b, c, a].
        try store.reorderEffect(trackID: t.id, effectID: a.id, toIndex: 2)
        #expect(track(store, t.id).effects.map(\.id) == [b.id, c.id, a.id])
        #expect(store.undoLabel == "Reorder Effects on 'Vox'")
    }

    @Test("the chain cap rejects a seventeenth effect")
    func chainCapRejectsSeventeenthEffect() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        for _ in 0..<ProjectStore.maxEffectsPerChain {
            _ = try store.addEffect(toTrack: t.id, kind: .gain)
        }
        #expect(track(store, t.id).effects.count == 16)

        let depth = store.journal.undoStack.count
        let error = projectError { _ = try store.addEffect(toTrack: t.id, kind: .gain) }
        guard case .chainFull(let cap) = try #require(error) else {
            Issue.record("expected chainFull, got \(String(describing: error))"); return
        }
        #expect(cap == 16)
        #expect(track(store, t.id).effects.count == 16)     // unchanged
        #expect(store.journal.undoStack.count == depth)      // no journal entry
    }

    @Test("param scrubs inside the window coalesce to one undo step")
    func paramScrubCoalescesToOneUndoStep() throws {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        let t = store.addTrack(name: "Vox", kind: .audio)
        let fx = try store.addEffect(toTrack: t.id, kind: .gain)
        let depth = store.journal.undoStack.count

        _ = try store.setEffectParam(trackID: t.id, effectID: fx.id, name: "gainLinear", value: 0.5)
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.setEffectParam(trackID: t.id, effectID: fx.id, name: "gainLinear", value: 0.25)

        // One coalesced step; current value is the last write.
        #expect(store.journal.undoStack.count == depth + 1)
        #expect(track(store, t.id).effects.first?.resolvedGain.gainLinear == 0.25)

        // A single undo restores the ORIGINAL (default) value, not the plateau.
        try store.undo()
        #expect(track(store, t.id).effects.first?.resolvedGain.gainLinear == 1)
    }

    @Test("undo restores the chain without rebuilding the track")
    func undoRestoresChainWithoutStructuralChange() throws {
        let store = ProjectStore()
        let engine = FakeEngine()
        store.engine = engine
        let t = store.addTrack(name: "Vox", kind: .audio)
        let a = try store.addEffect(toTrack: t.id, kind: .gain)
        _ = try store.addEffect(toTrack: t.id, kind: .gain)
        #expect(track(store, t.id).effects.count == 2)

        // Undo the second add: the chain shrinks but the track KEEPS its identity
        // (same id, same kind) — a chain edit is never a track rebuild.
        try store.undo()
        #expect(track(store, t.id).effects.map(\.id) == [a.id])
        #expect(track(store, t.id).id == t.id)
        #expect(track(store, t.id).kind == .audio)
        // Every chain edit still reconciles the engine (it decides non-structural).
        #expect(engine.calls.contains(.tracksDidChange(count: 1)))
    }

    @Test("setEffectParam maps eq/compressor/limiter names onto their fields")
    func setEffectParamWorksForNewKinds() throws {
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)

        // EQ: two flat names land on two fields; untouched fields keep defaults.
        let eq = try store.addEffect(toTrack: t.id, kind: .eq)
        #expect(store.journal.undoLabel == "Add EQ to 'Vox'")  // kind display name
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "peak1GainDb", value: 12)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "peak1Freq", value: 1_000)
        let eqParams = track(store, t.id).effects[0].resolvedEQ
        #expect(eqParams.peak1GainDb == 12)
        #expect(eqParams.peak1Freq == 1_000)
        #expect(eqParams.lowShelfFreq == 100)   // default untouched
        #expect(eqParams.peak2Freq == 3_000)    // default untouched

        // Compressor: out-of-range value clamps silently to the spec range.
        let comp = try store.addEffect(toTrack: t.id, kind: .compressor)
        _ = try store.setEffectParam(trackID: t.id, effectID: comp.id, name: "ratio", value: 100)
        _ = try store.setEffectParam(trackID: t.id, effectID: comp.id, name: "thresholdDb", value: -24)
        let compParams = track(store, t.id).effects[1].resolvedCompressor
        #expect(compParams.ratio == 20)          // clamped to 1...20
        #expect(compParams.thresholdDb == -24)
        #expect(compParams.attackMs == 10)       // default untouched

        // Limiter: both names; a foreign kind's name errors with the valid list.
        let limiter = try store.addEffect(toTrack: t.id, kind: .limiter)
        _ = try store.setEffectParam(trackID: t.id, effectID: limiter.id, name: "ceilingDb", value: -3)
        #expect(track(store, t.id).effects[2].resolvedLimiter.ceilingDb == -3)
        #expect(track(store, t.id).effects[2].resolvedLimiter.releaseMs == 50)
        let error = projectError {
            _ = try store.setEffectParam(trackID: t.id, effectID: limiter.id,
                                         name: "gainLinear", value: 1)
        }
        guard case .unknownEffectParam(let message) = try #require(error) else {
            Issue.record("expected unknownEffectParam, got \(String(describing: error))"); return
        }
        #expect(message == "unknown parameter 'gainLinear' for limiter effect — valid: ceilingDb, releaseMs")
    }

    @Test("eq/compressor/limiter round-trip through a .dawproj bundle")
    func fxPack1RoundTripsThroughBundle() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let eq = try store.addEffect(toTrack: t.id, kind: .eq)
        _ = try store.setEffectParam(trackID: t.id, effectID: eq.id, name: "highShelfGainDb", value: -6)
        let comp = try store.addEffect(toTrack: t.id, kind: .compressor)
        _ = try store.setEffectParam(trackID: t.id, effectID: comp.id, name: "kneeDb", value: 12)
        let limiter = try store.addEffect(toTrack: t.id, kind: .limiter)
        _ = try store.setEffectParam(trackID: t.id, effectID: limiter.id, name: "releaseMs", value: 80)

        let path = dir.appendingPathComponent("FxPack1").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let reTrack = try #require(reopened.tracks.first(where: { $0.name == "Vox" }))
        #expect(reTrack.effects.map(\.kind) == [.eq, .compressor, .limiter])
        #expect(reTrack.effects[0].id == eq.id)
        #expect(reTrack.effects[0].resolvedEQ.highShelfGainDb == -6)
        #expect(reTrack.effects[0].resolvedEQ.peak1Freq == 500)  // default survives as default
        #expect(reTrack.effects[1].id == comp.id)
        #expect(reTrack.effects[1].resolvedCompressor.kneeDb == 12)
        #expect(reTrack.effects[2].id == limiter.id)
        #expect(reTrack.effects[2].resolvedLimiter.releaseMs == 80)
    }

    @Test("effects round-trip through a .dawproj bundle")
    func effectsRoundTripThroughBundle() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let t = store.addTrack(name: "Vox", kind: .audio)
        let a = try store.addEffect(toTrack: t.id, kind: .gain)
        _ = try store.setEffectParam(trackID: t.id, effectID: a.id, name: "gainLinear", value: 0.5)
        let b = try store.addEffect(toTrack: t.id, kind: .gain)
        try store.setEffectBypassed(trackID: t.id, effectID: b.id, bypassed: true)

        let path = dir.appendingPathComponent("Fx").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let reTrack = try #require(reopened.tracks.first(where: { $0.name == "Vox" }))
        #expect(reTrack.effects.count == 2)
        #expect(reTrack.effects[0].id == a.id)
        #expect(reTrack.effects[0].kind == .gain)
        #expect(reTrack.effects[0].isBypassed == false)
        #expect(reTrack.effects[0].resolvedGain.gainLinear == 0.5)
        #expect(reTrack.effects[1].id == b.id)
        #expect(reTrack.effects[1].isBypassed == true)
    }

    @Test("a project with no effects carries no effects key")
    func preFXProjectStaysByteIdentical() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.addTrack(name: "Vox", kind: .audio)          // no effects
        let path = dir.appendingPathComponent("Plain").path
        try store.saveProject(to: path)

        let jsonURL = URL(fileURLWithPath: store.projectPath!)
            .appendingPathComponent("project.json")
        let json = try String(contentsOf: jsonURL, encoding: .utf8)
        #expect(!json.contains("effects"))
    }

    @Test("an unknown effect kind drops with a readable warning on load")
    func unknownEffectKindDropsWithWarning() throws {
        let dir = tempDir()
        let bundleURL = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Ghost").path)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Hand-authored project.json: one known gain effect plus a `phaser` effect
        // this build doesn't know (a forward-compat file from a later milestone).
        let trackID = UUID()
        let keepID = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "name": "Ghost",
          "masterVolume": 1,
          "transport": {},
          "tracks": [
            {
              "id": "\(trackID.uuidString)",
              "name": "Vox",
              "kind": "audio",
              "clips": [],
              "effects": [
                {"id": "\(keepID.uuidString)", "kind": "gain", "gain": {"gainLinear": 0.5}},
                {"id": "\(UUID().uuidString)", "kind": "phaser"}
              ]
            }
          ]
        }
        """
        try Data(json.utf8).write(
            to: bundleURL.appendingPathComponent("project.json"), options: .atomic)

        let store = ProjectStore()
        let warnings = try store.openProject(at: bundleURL.path)

        let vox = try #require(store.tracks.first(where: { $0.name == "Vox" }))
        // The unknown-kind effect is dropped; the known one survives intact.
        #expect(vox.effects.count == 1)
        #expect(vox.effects.first?.id == keepID)
        #expect(vox.effects.first?.resolvedGain.gainLinear == 0.5)
        #expect(warnings.contains("unknown effect kind 'phaser' on track 'Vox' — effect dropped"))
    }
}
