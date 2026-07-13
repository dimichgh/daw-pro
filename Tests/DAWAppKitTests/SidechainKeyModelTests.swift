import Foundation
import Testing
@testable import DAWCore
@testable import DAWAppKit

/// m12-g S-4. The pure sidechain KEY candidate filter (`SidechainKeyPicker`) and
/// the headless `SidechainKeyModel` orchestration (candidate/current reads,
/// set/clear funneled through the injected apply, teaching-error surfacing). The
/// SwiftUI KEY picker is thin over these — proving UI == wire by construction
/// (the `TempoLaneModel`/`QuantizeModel` precedent).
@MainActor
@Suite("Sidechain key model (m12-g S-4)")
struct SidechainKeyModelTests {

    // MARK: - Candidate filter (SidechainKeyPicker.eligibleSources)

    @Test("eligible sources are audio tracks only, self excluded, in project order")
    func candidateFilter() {
        let kick = Track(name: "Kick", kind: .audio)
        let snare = Track(name: "Snare", kind: .audio)
        let synth = Track(name: "Synth", kind: .instrument)
        let bus = Track(name: "Drum Bus", kind: .bus)
        var pad = Track(name: "Pad", kind: .audio)
        pad.effects = [EffectDescriptor(kind: .compressor)]
        let tracks = [kick, snare, synth, bus, pad]

        // For a compressor on the pad: kick + snare qualify; the instrument, the
        // bus, and the pad itself do NOT.
        let sources = SidechainKeyPicker.eligibleSources(
            destinationTrackID: pad.id, tracks: tracks)
        #expect(sources.map(\.id) == [kick.id, snare.id])
        #expect(sources.map(\.name) == ["Kick", "Snare"])
    }

    @Test("a bus destination still offers only audio sources (never itself)")
    func candidateFilterBusDestination() {
        let kick = Track(name: "Kick", kind: .audio)
        var bus = Track(name: "Drum Bus", kind: .bus)
        bus.effects = [EffectDescriptor(kind: .gate)]
        let tracks = [kick, bus]
        let sources = SidechainKeyPicker.eligibleSources(
            destinationTrackID: bus.id, tracks: tracks)
        #expect(sources.map(\.id) == [kick.id])
    }

    // MARK: - Model reads + apply

    @Test("model reports candidates, keyed state, and current key name from the providers")
    func modelReads() {
        let kick = SidechainKeySource(id: UUID(), name: "Kick")
        var current: UUID?
        let model = SidechainKeyModel(
            sources: { [kick] },
            current: { current },
            nameForTrack: { $0 == kick.id ? "Kick" : nil },
            apply: { current = $0 }
        )
        #expect(model.candidates.map(\.id) == [kick.id])
        #expect(model.isKeyed == false)
        #expect(model.currentKeyName == nil)

        model.setKey(kick.id)
        #expect(current == kick.id)
        #expect(model.isKeyed == true)
        #expect(model.currentKeyID == kick.id)
        #expect(model.currentKeyName == "Kick")
        #expect(model.lastErrorMessage == nil)

        model.clear()
        #expect(current == nil)
        #expect(model.isKeyed == false)
    }

    @Test("a store rejection surfaces its teaching error and touches nothing")
    func modelSurfacesError() {
        struct KeyError: LocalizedError {
            var errorDescription: String? {
                "a reverb effect cannot take a sidechain key — only compressor and gate support sidechain in v1 (hosted Audio Unit sidechain inputs are a later phase)"
            }
        }
        var applied: [UUID?] = []
        let model = SidechainKeyModel(
            sources: { [] },
            current: { nil },
            nameForTrack: { _ in nil },
            apply: { sourceID in
                applied.append(sourceID)
                throw KeyError()
            }
        )
        let bogus = UUID()
        model.setKey(bogus)
        #expect(applied == [bogus])   // the model DID funnel through apply…
        #expect(model.lastErrorMessage?.contains("only compressor and gate") == true)
        #expect(model.isKeyed == false)  // …and nothing changed (current still nil)

        // A subsequent successful clear wipes the error.
        var cleared = false
        let ok = SidechainKeyModel(
            sources: { [] }, current: { nil }, nameForTrack: { _ in nil },
            apply: { _ in cleared = true })
        ok.setKey(bogus)
        ok.clear()
        #expect(cleared)
        #expect(ok.lastErrorMessage == nil)
    }
}
