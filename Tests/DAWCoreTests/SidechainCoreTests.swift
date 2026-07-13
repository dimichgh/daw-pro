import Foundation
import Testing
@testable import DAWCore

/// m12-f S-1 headless coverage (design docs/research/design-m11f-sidechain.md):
/// `ProjectStore.setSidechain` semantics (kind check, destination/source
/// scope, cycle validator naming the path, one-per-strip, dangling-clear on
/// track removal), additive Codable (omit-when-nil byte discipline),
/// `StemPlan` key-source inclusion via the silent-dummy-bus mechanism (both
/// `.track` and `.bus` arms, transitive, unkeyed-untouched), and the PDC
/// planner's `hasSends`-class key sources + `sidechainSkewSamples` report.
@MainActor
@Suite("Sidechain S-1 — store, StemPlan, PDC (m12-f)")
struct SidechainCoreTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func track(_ store: ProjectStore, _ id: UUID) -> Track {
        store.tracks.first(where: { $0.id == id })!
    }

    // MARK: - Store semantics (gate F)

    @Test("setSidechain sets and clears the key on a compressor")
    func setAndClear() throws {
        let store = ProjectStore()
        let kick = store.addTrack(name: "Kick", kind: .audio)
        let pad = store.addTrack(name: "Pad", kind: .audio)
        let comp = try store.addEffect(toTrack: pad.id, kind: .compressor)

        let keyed = try store.setSidechain(trackID: pad.id, effectID: comp.id,
                                           sourceTrackID: kick.id)
        #expect(keyed.sidechainSourceTrackID == kick.id)
        #expect(track(store, pad.id).effects[0].sidechainSourceTrackID == kick.id)
        #expect(store.undoLabel == "Set Sidechain on 'Pad'")

        let cleared = try store.setSidechain(trackID: pad.id, effectID: comp.id,
                                             sourceTrackID: nil)
        #expect(cleared.sidechainSourceTrackID == nil)
        #expect(track(store, pad.id).effects[0].sidechainSourceTrackID == nil)
    }

    @Test("gate accepts a key; every other kind rejects with the teaching error")
    func kindCheck() throws {
        let store = ProjectStore()
        let kick = store.addTrack(name: "Kick", kind: .audio)
        let pad = store.addTrack(name: "Pad", kind: .audio)
        let gate = try store.addEffect(toTrack: pad.id, kind: .gate)
        _ = try store.setSidechain(trackID: pad.id, effectID: gate.id,
                                   sourceTrackID: kick.id)
        #expect(track(store, pad.id).effects[0].sidechainSourceTrackID == kick.id)

        let eq = try store.addEffect(toTrack: pad.id, kind: .eq)
        let error = projectError {
            try store.setSidechain(trackID: pad.id, effectID: eq.id,
                                   sourceTrackID: kick.id)
        }
        guard case .sidechainUnsupportedEffect(let kind) = error else {
            Issue.record("expected sidechainUnsupportedEffect, got \(String(describing: error))")
            return
        }
        #expect(kind == .eq)
        #expect(error?.errorDescription?.contains("only compressor and gate") == true)
        // Even clearing (nil) on an unsupported kind rejects — the kind check
        // is unconditional, so the error teaches before anything else.
        #expect(projectError {
            try store.setSidechain(trackID: pad.id, effectID: eq.id, sourceTrackID: nil)
        } != nil)
    }

    @Test("instrument destination strips reject (no ChainHostAU to receive the key)")
    func instrumentDestinationRejects() throws {
        let store = ProjectStore()
        let kick = store.addTrack(name: "Kick", kind: .audio)
        let synth = store.addTrack(name: "Synth", kind: .instrument)
        let comp = try store.addEffect(toTrack: synth.id, kind: .compressor)
        let error = projectError {
            try store.setSidechain(trackID: synth.id, effectID: comp.id,
                                   sourceTrackID: kick.id)
        }
        guard case .sidechainUnsupportedTrack(let kind) = error else {
            Issue.record("expected sidechainUnsupportedTrack, got \(String(describing: error))")
            return
        }
        #expect(kind == .instrument)
        #expect(error?.errorDescription?.contains("route the track to a bus") == true)
        // Clearing on an instrument strip is still legal (kind permitting) —
        // the destination check only guards SETTING a key.
        _ = try store.setSidechain(trackID: synth.id, effectID: comp.id,
                                   sourceTrackID: nil)
    }

    @Test("bus key sources reject with the v1 deferral error")
    func busSourceRejects() throws {
        let store = ProjectStore()
        let bus = store.addTrack(name: "Drum Bus", kind: .bus)
        let pad = store.addTrack(name: "Pad", kind: .audio)
        let comp = try store.addEffect(toTrack: pad.id, kind: .compressor)
        let error = projectError {
            try store.setSidechain(trackID: pad.id, effectID: comp.id,
                                   sourceTrackID: bus.id)
        }
        guard case .sidechainUnsupportedSource(let message) = error else {
            Issue.record("expected sidechainUnsupportedSource, got \(String(describing: error))")
            return
        }
        #expect(message.contains("'Drum Bus'"))
        #expect(message.contains("deferred in v1"))
    }

    @Test("an instrument track is a legal key source; a keyed BUS destination is legal")
    func instrumentSourceAndBusDestination() throws {
        let store = ProjectStore()
        let kick = store.addTrack(name: "Kick Synth", kind: .instrument)
        let bus = store.addTrack(name: "Pad Bus", kind: .bus)
        let comp = try store.addEffect(toTrack: bus.id, kind: .compressor)
        let keyed = try store.setSidechain(trackID: bus.id, effectID: comp.id,
                                           sourceTrackID: kick.id)
        #expect(keyed.sidechainSourceTrackID == kick.id)
    }

    @Test("the classic ducking shape is legal: kick routed INTO the bus it keys")
    func kickIntoKeyedBusIsLegal() throws {
        // Kick → bus (audio) AND kick → bus comp (key) are PARALLEL edges,
        // not a cycle — the everyday Logic/Live ducking workflow must pass.
        let store = ProjectStore()
        let kick = store.addTrack(name: "Kick", kind: .audio)
        let bus = store.addTrack(name: "Mix Bus", kind: .bus)
        try store.setTrackOutput(id: kick.id, busID: bus.id)
        let comp = try store.addEffect(toTrack: bus.id, kind: .compressor)
        let keyed = try store.setSidechain(trackID: bus.id, effectID: comp.id,
                                           sourceTrackID: kick.id)
        #expect(keyed.sidechainSourceTrackID == kick.id)
    }

    @Test("self-keying rejects as a cycle")
    func selfKeyRejects() throws {
        let store = ProjectStore()
        let pad = store.addTrack(name: "Pad", kind: .audio)
        let comp = try store.addEffect(toTrack: pad.id, kind: .compressor)
        let error = projectError {
            try store.setSidechain(trackID: pad.id, effectID: comp.id,
                                   sourceTrackID: pad.id)
        }
        guard case .sidechainWouldCreateCycle(let message) = error else {
            Issue.record("expected sidechainWouldCreateCycle, got \(String(describing: error))")
            return
        }
        #expect(message.contains("cannot key itself"))
        #expect(message.contains("'Pad'"))
    }

    @Test("A keyed by B, then B keyed by A rejects naming the path")
    func twoStripKeyLoopRejects() throws {
        let store = ProjectStore()
        let a = store.addTrack(name: "Alpha", kind: .audio)
        let b = store.addTrack(name: "Beta", kind: .audio)
        let compA = try store.addEffect(toTrack: a.id, kind: .compressor)
        let compB = try store.addEffect(toTrack: b.id, kind: .compressor)
        _ = try store.setSidechain(trackID: a.id, effectID: compA.id, sourceTrackID: b.id)

        let error = projectError {
            try store.setSidechain(trackID: b.id, effectID: compB.id, sourceTrackID: a.id)
        }
        guard case .sidechainWouldCreateCycle(let message) = error else {
            Issue.record("expected sidechainWouldCreateCycle, got \(String(describing: error))")
            return
        }
        // The existing path Beta → Alpha plus the new key edge closes
        // Beta → Alpha → Beta; the message names the whole loop.
        #expect(message.contains("Beta → Alpha → Beta"))
    }

    @Test("three-strip key chain rejects the closing edge, naming the full path")
    func threeStripKeyChainRejects() throws {
        let store = ProjectStore()
        let a = store.addTrack(name: "A", kind: .audio)
        let b = store.addTrack(name: "B", kind: .audio)
        let c = store.addTrack(name: "C", kind: .audio)
        for t in [a, b, c] { _ = try store.addEffect(toTrack: t.id, kind: .compressor) }
        // A keyed by B, B keyed by C — legal chain.
        _ = try store.setSidechain(trackID: a.id, effectID: track(store, a.id).effects[0].id,
                                   sourceTrackID: b.id)
        _ = try store.setSidechain(trackID: b.id, effectID: track(store, b.id).effects[0].id,
                                   sourceTrackID: c.id)
        // C keyed by A closes C → B → A ... → C.
        let error = projectError {
            try store.setSidechain(trackID: c.id, effectID: track(store, c.id).effects[0].id,
                                   sourceTrackID: a.id)
        }
        guard case .sidechainWouldCreateCycle(let message) = error else {
            Issue.record("expected sidechainWouldCreateCycle, got \(String(describing: error))")
            return
        }
        #expect(message.contains("C → B → A → C"))
    }

    @Test("one key source per strip: a second keyed effect rejects naming the first")
    func onePerStripRejects() throws {
        let store = ProjectStore()
        let kick = store.addTrack(name: "Kick", kind: .audio)
        let snare = store.addTrack(name: "Snare", kind: .audio)
        let pad = store.addTrack(name: "Pad", kind: .audio)
        let comp = try store.addEffect(toTrack: pad.id, kind: .compressor)
        let gate = try store.addEffect(toTrack: pad.id, kind: .gate)
        _ = try store.setSidechain(trackID: pad.id, effectID: comp.id, sourceTrackID: kick.id)

        let error = projectError {
            try store.setSidechain(trackID: pad.id, effectID: gate.id, sourceTrackID: snare.id)
        }
        guard case .sidechainOneSourcePerStrip(let message) = error else {
            Issue.record("expected sidechainOneSourcePerStrip, got \(String(describing: error))")
            return
        }
        #expect(message.contains("keyed compressor"))
        #expect(message.contains(comp.id.uuidString))
        // Re-keying the SAME effect to a new source is not a second key.
        let rekeyed = try store.setSidechain(trackID: pad.id, effectID: comp.id,
                                             sourceTrackID: snare.id)
        #expect(rekeyed.sidechainSourceTrackID == snare.id)
        // One source may key MANY strips (the budget is per destination).
        let pad2 = store.addTrack(name: "Pad2", kind: .audio)
        let comp2 = try store.addEffect(toTrack: pad2.id, kind: .compressor)
        _ = try store.setSidechain(trackID: pad2.id, effectID: comp2.id, sourceTrackID: snare.id)
        #expect(track(store, pad2.id).effects[0].sidechainSourceTrackID == snare.id)
    }

    @Test("unknown track / effect / source reject with the standard errors")
    func notFoundErrors() throws {
        let store = ProjectStore()
        let pad = store.addTrack(name: "Pad", kind: .audio)
        let comp = try store.addEffect(toTrack: pad.id, kind: .compressor)
        let ghost = UUID()
        guard case .trackNotFound = projectError({
            try store.setSidechain(trackID: ghost, effectID: comp.id, sourceTrackID: pad.id)
        }) else { Issue.record("expected trackNotFound (track)"); return }
        guard case .effectNotFound = projectError({
            try store.setSidechain(trackID: pad.id, effectID: ghost, sourceTrackID: pad.id)
        }) else { Issue.record("expected effectNotFound"); return }
        guard case .trackNotFound = projectError({
            try store.setSidechain(trackID: pad.id, effectID: comp.id, sourceTrackID: ghost)
        }) else { Issue.record("expected trackNotFound (source)"); return }
    }

    @Test("removing the key source dangling-clears every keyed effect in ONE edit; undo restores both")
    func removeTrackDanglingClears() throws {
        let store = ProjectStore()
        let kick = store.addTrack(name: "Kick", kind: .audio)
        let pad = store.addTrack(name: "Pad", kind: .audio)
        let bus = store.addTrack(name: "Bus", kind: .bus)
        let comp = try store.addEffect(toTrack: pad.id, kind: .compressor)
        let busGate = try store.addEffect(toTrack: bus.id, kind: .gate)
        _ = try store.setSidechain(trackID: pad.id, effectID: comp.id, sourceTrackID: kick.id)
        _ = try store.setSidechain(trackID: bus.id, effectID: busGate.id, sourceTrackID: kick.id)

        #expect(try store.removeTrack(id: kick.id))
        #expect(track(store, pad.id).effects[0].sidechainSourceTrackID == nil)
        #expect(track(store, bus.id).effects[0].sidechainSourceTrackID == nil)

        // ONE undo restores the track AND both keys (same-edit discipline).
        _ = try store.undo()
        #expect(store.tracks.contains { $0.id == kick.id })
        #expect(track(store, pad.id).effects[0].sidechainSourceTrackID == kick.id)
        #expect(track(store, bus.id).effects[0].sidechainSourceTrackID == kick.id)
    }

    // MARK: - Additive Codable (gate F)

    @Test("nil key is OMITTED from the encoded descriptor; non-nil round-trips")
    func codableOmitWhenNil() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = EffectDescriptor(kind: .compressor)
        let plainJSON = String(decoding: try encoder.encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("sidechainSourceTrackID"))

        let source = UUID()
        let keyed = EffectDescriptor(kind: .gate, sidechainSourceTrackID: source)
        let keyedJSON = String(decoding: try encoder.encode(keyed), as: UTF8.self)
        #expect(keyedJSON.contains("sidechainSourceTrackID"))
        let decoded = try JSONDecoder().decode(EffectDescriptor.self,
                                               from: Data(keyedJSON.utf8))
        #expect(decoded.sidechainSourceTrackID == source)
        #expect(decoded == keyed)
    }

    @Test("legacy descriptor JSON (no key field) decodes nil and re-encodes byte-identical")
    func legacyDescriptorBytesStable() throws {
        // A legacy-shaped descriptor as the pre-m12-f encoder wrote it
        // (sorted keys). Decode → re-encode must reproduce the EXACT bytes:
        // the additive field may not perturb legacy documents on disk.
        let legacy = #"{"id":"6F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0","isBypassed":false,"kind":"compressor"}"#
        let decoded = try JSONDecoder().decode(EffectDescriptor.self, from: Data(legacy.utf8))
        #expect(decoded.sidechainSourceTrackID == nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = String(decoding: try encoder.encode(decoded), as: UTF8.self)
        #expect(reencoded == legacy)
    }

    // MARK: - Persistence mirror (EffectDocument)
    // Regression: the descriptor's Codable carried the key, but the DISK
    // path goes through the `EffectDocument` mirror DTO, which dropped it —
    // a saved project silently lost every sidechain key on reopen.

    @Test("EffectDocument mirror carries the key across the disk round trip")
    func documentMirrorCarriesKey() throws {
        let source = UUID()
        let keyed = EffectDescriptor(kind: .gate, sidechainSourceTrackID: source)
        let doc = EffectDocument(from: keyed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(doc), as: UTF8.self)
        #expect(json.contains("sidechainSourceTrackID"))
        let decoded = try JSONDecoder().decode(EffectDocument.self, from: Data(json.utf8))
        #expect(decoded.effectDescriptor()?.sidechainSourceTrackID == source)
    }

    @Test("EffectDocument omits a nil key; legacy {id, kind} decodes nil")
    func documentMirrorOmitsNilKey() throws {
        let plain = EffectDescriptor(kind: .compressor)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(EffectDocument(from: plain)), as: UTF8.self)
        #expect(!json.contains("sidechainSourceTrackID"))
        let legacy = #"{"id":"6F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0","kind":"gate"}"#
        let decoded = try JSONDecoder().decode(EffectDocument.self, from: Data(legacy.utf8))
        #expect(decoded.effectDescriptor()?.sidechainSourceTrackID == nil)
    }

    // MARK: - SidechainGraph helpers

    @Test("keySourceTrackIDs: valid sources only — dangling and bus refs excluded")
    func keySourceHelper() throws {
        let kick = Track(name: "Kick", kind: .audio)
        let bus = Track(name: "Bus", kind: .bus)
        var pad = Track(name: "Pad", kind: .audio)
        var other = Track(name: "Other", kind: .audio)
        var busKeyed = Track(name: "BusKeyed", kind: .audio)
        pad.effects = [EffectDescriptor(kind: .compressor, sidechainSourceTrackID: kick.id)]
        other.effects = [EffectDescriptor(kind: .gate, sidechainSourceTrackID: UUID())] // dangling
        busKeyed.effects = [EffectDescriptor(kind: .compressor, sidechainSourceTrackID: bus.id)]
        let tracks = [kick, bus, pad, other, busKeyed]
        #expect(SidechainGraph.keySourceTrackIDs(tracks: tracks) == [kick.id])
    }

    // MARK: - StemPlan key-source inclusion (S-1 groundwork for S-3)

    @Test("unkeyed sessions: passTracks output is EXACTLY the pre-sidechain shape")
    func stemPassUnkeyedUntouched() throws {
        let fx = Track(name: "FX", kind: .bus)
        var gtr = Track(name: "Gtr", kind: .audio)
        gtr.sends = [Send(destinationBusID: fx.id, level: 0.5)]
        let dry = Track(name: "Dry", kind: .audio)
        let session = [gtr, dry, fx]

        let trackPass = StemPlan.passTracks(
            for: StemDescriptor(id: dry.id, kind: .track, name: "Dry", fileName: "02 Dry.wav"),
            session: session)
        #expect(trackPass.count == 1)
        #expect(trackPass[0].id == dry.id)
        #expect(trackPass[0].sends.isEmpty)

        let busPass = StemPlan.passTracks(
            for: StemDescriptor(id: fx.id, kind: .bus, name: "FX", fileName: "03 FX.wav"),
            session: session)
        // Contributor (send-only, rerouted to the dummy) + the bus + dummy.
        #expect(busPass.count == 3)
        #expect(busPass[0].id == gtr.id)
        #expect(busPass[1].id == fx.id)
        #expect(busPass[2].kind == .bus)
        #expect(busPass[2].volume == 0)
        #expect(busPass[0].outputBusID == busPass[2].id)
    }

    @Test(".track stem with a keyed effect carries the key source routed to the silent dummy")
    func stemTrackArmIncludesKeySource() throws {
        var kick = Track(name: "Kick", kind: .audio)
        kick.sends = [Send(destinationBusID: UUID(), level: 0.3)] // dropped on inclusion
        var pad = Track(name: "Pad", kind: .audio)
        pad.effects = [EffectDescriptor(kind: .compressor, sidechainSourceTrackID: kick.id)]
        let session = [kick, pad]

        let pass = StemPlan.passTracks(
            for: StemDescriptor(id: pad.id, kind: .track, name: "Pad", fileName: "01 Pad.wav"),
            session: session)
        #expect(pass.count == 3)
        #expect(pass[0].id == pad.id)
        #expect(pass[0].sends.isEmpty)
        #expect(pass[1].id == kick.id)
        #expect(pass[1].sends.isEmpty)          // sends dropped — fan-out only
        let dummy = pass[2]
        #expect(dummy.kind == .bus)
        #expect(dummy.volume == 0)
        #expect(dummy.effects.isEmpty)
        #expect(pass[1].outputBusID == dummy.id) // key exists, adds nothing
    }

    @Test(".bus stem: a keyed bus pulls its key source in; a contributor source is not duplicated")
    func stemBusArmIncludesKeySource() throws {
        var kick = Track(name: "Kick", kind: .audio)
        var bus = Track(name: "Mix Bus", kind: .bus)
        var gtr = Track(name: "Gtr", kind: .audio)
        gtr.outputBusID = bus.id
        bus.effects = [EffectDescriptor(kind: .compressor, sidechainSourceTrackID: kick.id)]
        var session = [kick, gtr, bus]

        var pass = StemPlan.passTracks(
            for: StemDescriptor(id: bus.id, kind: .bus, name: "Mix Bus", fileName: "01.wav"),
            session: session)
        // gtr (routes in) + bus + kick (key source → dummy) + dummy.
        #expect(pass.map(\.name) == ["Gtr", "Mix Bus", "Kick", "Stem Dummy"])
        let dummy = pass[3]
        #expect(pass[2].outputBusID == dummy.id)
        #expect(pass[2].sends.isEmpty)

        // When the key source ALREADY contributes (kick routed into the bus),
        // it is not duplicated and no dummy is needed.
        kick.outputBusID = bus.id
        session = [kick, gtr, bus]
        pass = StemPlan.passTracks(
            for: StemDescriptor(id: bus.id, kind: .bus, name: "Mix Bus", fileName: "01.wav"),
            session: session)
        #expect(pass.map(\.name) == ["Kick", "Gtr", "Mix Bus"])
    }

    @Test("key-source closure is transitive and skips bus/dangling sources")
    func stemClosureTransitive() throws {
        var s2 = Track(name: "S2", kind: .audio)
        var s1 = Track(name: "S1", kind: .audio)
        s1.effects = [EffectDescriptor(kind: .gate, sidechainSourceTrackID: s2.id)]
        var pad = Track(name: "Pad", kind: .audio)
        pad.effects = [EffectDescriptor(kind: .compressor, sidechainSourceTrackID: s1.id)]
        // Hostile extras: a bus source and a dangling source never ride along.
        let bus = Track(name: "B", kind: .bus)
        s2.effects = [EffectDescriptor(kind: .compressor, sidechainSourceTrackID: bus.id)]
        let session = [pad, s1, s2, bus]

        let pass = StemPlan.passTracks(
            for: StemDescriptor(id: pad.id, kind: .track, name: "Pad", fileName: "01.wav"),
            session: session)
        #expect(pass.map(\.name) == ["Pad", "S1", "S2", "Stem Dummy"])
        let dummy = pass[3]
        #expect(pass[1].outputBusID == dummy.id)
        #expect(pass[2].outputBusID == dummy.id)
    }

    // MARK: - PDC (hasSends-class sources + sidechainSkewSamples)

    @Test("planner: keyed strip skew = source stage target − latency before the keyed slot")
    func plannerSkewMath() throws {
        let sourceID = UUID()
        let destID = UUID()
        // Source track carries the session's only latency (a limiter, 240)
        // and is hasSends-class (the key-tap rule) → pads to T = 240; the
        // destination's keyed effect sits first in its chain (ℓ_before 0) →
        // the key arrives 240 samples LATE.
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            PDCStripInput(id: sourceID,
                          kind: .track(outputsToMaster: true, hasSends: true),
                          chainLatencyAll: 240, chainLatencyActive: 240),
            PDCStripInput(id: destID,
                          kind: .track(outputsToMaster: true, hasSends: false),
                          chainLatencyAll: 0, chainLatencyActive: 0,
                          sidechainKey: SidechainKeyInput(
                              sourceID: sourceID, latencyBeforeKeyedEffectSamples: 0)),
        ]))
        #expect(plan.trackStage == 240)
        #expect(plan[destID]?.sidechainSkewSamples == 240)
        #expect(plan[sourceID]?.sidechainSkewSamples == 0)

        // Zero-latency session (the typical case): skew is exactly 0.
        let flat = PDCPlan.compute(input: PDCInput(strips: [
            PDCStripInput(id: sourceID,
                          kind: .track(outputsToMaster: true, hasSends: true),
                          chainLatencyAll: 0, chainLatencyActive: 0),
            PDCStripInput(id: destID,
                          kind: .track(outputsToMaster: true, hasSends: false),
                          chainLatencyAll: 0, chainLatencyActive: 0,
                          sidechainKey: SidechainKeyInput(
                              sourceID: sourceID, latencyBeforeKeyedEffectSamples: 0)),
        ]))
        #expect(flat[destID]?.sidechainSkewSamples == 0)

        // Keyed BUS destination whose chain has latency BEFORE the keyed
        // slot: the bus input arrives at T, the main signal at the slot at
        // T + ℓ_before, the key at T → key EARLY by ℓ_before (negative).
        let busID = UUID()
        let busPlan = PDCPlan.compute(input: PDCInput(strips: [
            PDCStripInput(id: sourceID,
                          kind: .track(outputsToMaster: false, hasSends: true),
                          chainLatencyAll: 0, chainLatencyActive: 0),
            PDCStripInput(id: busID, kind: .bus,
                          chainLatencyAll: 240, chainLatencyActive: 240,
                          sidechainKey: SidechainKeyInput(
                              sourceID: sourceID, latencyBeforeKeyedEffectSamples: 240)),
        ]))
        #expect(busPlan[busID]?.sidechainSkewSamples == -240)

        // Unknown source strip → skew honestly 0 (nothing computable).
        let orphan = PDCPlan.compute(input: PDCInput(strips: [
            PDCStripInput(id: destID,
                          kind: .track(outputsToMaster: true, hasSends: false),
                          chainLatencyAll: 0, chainLatencyActive: 0,
                          sidechainKey: SidechainKeyInput(
                              sourceID: UUID(), latencyBeforeKeyedEffectSamples: 0)),
        ]))
        #expect(orphan[destID]?.sidechainSkewSamples == 0)
    }
}
