import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for `fx.setSidechain` (m12-g S-4) — the wire
/// command that replaced the retired app-tier staging seam. Drives
/// the kick→pad keying workflow and pins every one of the store's four
/// field-named teaching errors VERBATIM at the wire boundary (the same strings
/// the live gate asserts). Reuses `FakeMedia` from ControlTests.swift.
@MainActor
@Suite("Sidechain key — control protocol (fx.setSidechain)")
struct SidechainCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addTrack(_ router: CommandRouter, name: String, kind: String) async -> UUID {
        let response = await router.handle(ControlRequest(
            id: "add-\(name)", command: "track.add",
            params: ["name": .string(name), "kind": .string(kind)]))
        return UUID(uuidString: response.result?["id"]?.stringValue ?? "")!
    }

    private func addEffect(_ router: CommandRouter, trackID: UUID, kind: String) async -> UUID {
        let response = await router.handle(ControlRequest(
            id: "fx-add-\(kind)", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string(kind)]))
        return UUID(uuidString: response.result?["effectId"]?.stringValue ?? "")!
    }

    private func setSidechain(_ router: CommandRouter, trackID: UUID, effectID: UUID,
                             source: JSONValue?) async -> ControlResponse {
        var params: [String: JSONValue] = [
            "trackId": .string(trackID.uuidString),
            "effectId": .string(effectID.uuidString),
        ]
        if let source { params["sourceTrackId"] = source }
        return await router.handle(ControlRequest(id: "sc", command: "fx.setSidechain", params: params))
    }

    // MARK: - Set / clear

    @Test("fx.setSidechain keys a compressor, returns the chain + source + skew, then clears")
    func setsAndClears() async throws {
        let (router, _) = makeRouter()
        let kick = await addTrack(router, name: "Kick", kind: "audio")
        let pad = await addTrack(router, name: "Pad", kind: "audio")
        let comp = await addEffect(router, trackID: pad, kind: "compressor")

        // Set.
        let set = await setSidechain(router, trackID: pad, effectID: comp,
                                     source: .string(kick.uuidString))
        #expect(set.ok)
        #expect(set.result?["trackId"]?.stringValue == pad.uuidString)
        #expect(set.result?["effectId"]?.stringValue == comp.uuidString)
        let effects = try #require(set.result?["effects"]?.arrayValue)
        #expect(effects.first?["sidechainSourceTrackId"]?.stringValue == kick.uuidString)
        // Skew rides the response for parity with the retired seam (headless
        // store — no engine — reports 0).
        #expect(set.result?["sidechainSkewSamples"]?.doubleValue == 0)

        // Clear via explicit null.
        let clearedNull = await setSidechain(router, trackID: pad, effectID: comp, source: .null)
        #expect(clearedNull.ok)
        #expect(clearedNull.result?["effects"]?.arrayValue?.first?["sidechainSourceTrackId"] == nil)

        // Re-key, then clear by OMITTING sourceTrackId.
        _ = await setSidechain(router, trackID: pad, effectID: comp, source: .string(kick.uuidString))
        let clearedOmit = await setSidechain(router, trackID: pad, effectID: comp, source: nil)
        #expect(clearedOmit.ok)
        #expect(clearedOmit.result?["effects"]?.arrayValue?.first?["sidechainSourceTrackId"] == nil)
    }

    @Test("fx.setSidechain rejects a non-UUID sourceTrackId field-named")
    func rejectsBadSourceUUID() async throws {
        let (router, _) = makeRouter()
        let pad = await addTrack(router, name: "Pad", kind: "audio")
        let comp = await addEffect(router, trackID: pad, kind: "compressor")
        let bad = await setSidechain(router, trackID: pad, effectID: comp, source: .string("not-a-uuid"))
        #expect(!bad.ok)
        #expect(bad.error == "'sourceTrackId' is not a valid UUID: not-a-uuid")
    }

    // MARK: - The four teaching errors (verbatim)

    @Test("error: unsupported effect kind (reverb) — verbatim")
    func unsupportedKind() async throws {
        let (router, _) = makeRouter()
        let kick = await addTrack(router, name: "Kick", kind: "audio")
        let pad = await addTrack(router, name: "Pad", kind: "audio")
        let reverb = await addEffect(router, trackID: pad, kind: "reverb")
        let response = await setSidechain(router, trackID: pad, effectID: reverb,
                                          source: .string(kick.uuidString))
        #expect(!response.ok)
        #expect(response.error == "a reverb effect cannot take a sidechain key — only compressor and gate support sidechain in v1 (hosted Audio Unit sidechain inputs are a later phase)")
    }

    @Test("error: feedback cycle names the → path — verbatim")
    func cycle() async throws {
        let (router, _) = makeRouter()
        let a = await addTrack(router, name: "A", kind: "audio")
        let b = await addTrack(router, name: "B", kind: "audio")
        let compA = await addEffect(router, trackID: a, kind: "compressor")
        let compB = await addEffect(router, trackID: b, kind: "compressor")
        // Key A from B — legal (no path A → … → B yet).
        let first = await setSidechain(router, trackID: a, effectID: compA, source: .string(b.uuidString))
        #expect(first.ok)
        // Key B from A — closes B → A → B.
        let second = await setSidechain(router, trackID: b, effectID: compB, source: .string(a.uuidString))
        #expect(!second.ok)
        #expect(second.error == "sidechain would create a feedback cycle: 'B' already feeds 'A' (B → A → B) — keying it from 'A' closes the loop")
        #expect(second.error?.contains(" → ") == true)
    }

    @Test("error: one sidechain key per strip — verbatim")
    func oneSourcePerStrip() async throws {
        let (router, _) = makeRouter()
        let kick = await addTrack(router, name: "Kick", kind: "audio")
        let snare = await addTrack(router, name: "Snare", kind: "audio")
        let pad = await addTrack(router, name: "Pad", kind: "audio")
        let comp = await addEffect(router, trackID: pad, kind: "compressor")
        let gate = await addEffect(router, trackID: pad, kind: "gate")
        // First key: the compressor off the kick.
        let first = await setSidechain(router, trackID: pad, effectID: comp, source: .string(kick.uuidString))
        #expect(first.ok)
        // Second key on the SAME strip rejects, naming the already-keyed comp.
        let second = await setSidechain(router, trackID: pad, effectID: gate, source: .string(snare.uuidString))
        #expect(!second.ok)
        #expect(second.error == "strip 'Pad' already has a keyed compressor (effect \(comp.uuidString)) — one sidechain key per strip in v1; clear it first")
    }

    @Test("error: bus key source deferred — verbatim")
    func unsupportedSource() async throws {
        let (router, _) = makeRouter()
        let bus = await addTrack(router, name: "Drum Bus", kind: "bus")
        let pad = await addTrack(router, name: "Pad", kind: "audio")
        let comp = await addEffect(router, trackID: pad, kind: "compressor")
        let response = await setSidechain(router, trackID: pad, effectID: comp, source: .string(bus.uuidString))
        #expect(!response.ok)
        #expect(response.error == "'Drum Bus' is a bus — bus key sources are deferred in v1; key from a source track feeding it instead")
    }

    @Test("error: instrument destination deferred — verbatim")
    func unsupportedTrack() async throws {
        let (router, _) = makeRouter()
        let kick = await addTrack(router, name: "Kick", kind: "audio")
        let synth = await addTrack(router, name: "Synth", kind: "instrument")
        let comp = await addEffect(router, trackID: synth, kind: "compressor")
        let response = await setSidechain(router, trackID: synth, effectID: comp, source: .string(kick.uuidString))
        #expect(!response.ok)
        #expect(response.error == "effects on an instrument track cannot take a sidechain key in v1 — route the track to a bus and put the keyed compressor/gate on the bus instead")
    }

    @Test("error: unknown track / effect surface trackNotFound / effectNotFound")
    func notFound() async throws {
        let (router, _) = makeRouter()
        let pad = await addTrack(router, name: "Pad", kind: "audio")
        let ghostTrack = await setSidechain(router, trackID: UUID(), effectID: UUID(), source: nil)
        #expect(!ghostTrack.ok)
        let ghostEffect = await setSidechain(router, trackID: pad, effectID: UUID(), source: nil)
        #expect(!ghostEffect.ok)
    }
}
