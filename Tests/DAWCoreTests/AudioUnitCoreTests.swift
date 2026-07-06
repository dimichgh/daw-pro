import Foundation
import Testing
@testable import DAWCore

/// M3 (vi-a) Audio Unit domain model + persistence + store semantics —
/// headless, no engine, no AVFoundation.
@MainActor
@Suite("Audio Unit — domain & persistence")
struct AudioUnitCoreTests {
    private static let dls = AudioUnitComponentID(subType: "dls ", manufacturer: "appl")

    private func bundleEncoder() -> JSONEncoder {
        // Mirrors ProjectBundle.write exactly (prettyPrinted + sortedKeys +
        // iso8601) so byte-identity claims here hold for real saves.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func bundleDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test("FourCC init clamps to exactly four ASCII characters")
    func fourCCNormalizationClampsToFourASCII() {
        // Right-pad with spaces.
        #expect(AudioUnitComponentID(subType: "dls", manufacturer: "appl").subType == "dls ")
        // Truncate to 4.
        #expect(AudioUnitComponentID(subType: "abcdef", manufacturer: "appl").subType == "abcd")
        // Non-ASCII scalars → "?".
        #expect(AudioUnitComponentID(subType: "dls\u{00E9}", manufacturer: "appl").subType == "dls?")
        #expect(AudioUnitComponentID(subType: "a\u{1F600}", manufacturer: "appl").subType == "a?  ")
        // Empty → four spaces; type defaults to "aumu".
        let id = AudioUnitComponentID(subType: "", manufacturer: "ÄÖÜÉ")
        #expect(id.subType == "    ")
        #expect(id.manufacturer == "????")
        #expect(id.type == "aumu")
        // Decoding routes through the same normalization.
        let decoded = try? JSONDecoder().decode(
            AudioUnitComponentID.self,
            from: Data(#"{"subType":"dl","manufacturer":"appleton"}"#.utf8))
        #expect(decoded == AudioUnitComponentID(subType: "dl  ", manufacturer: "appl"))
    }

    @Test("AU config (component + inline base64 state) round-trips through the document")
    func auStateRoundTripsThroughDocument() throws {
        let config = AudioUnitConfig(component: Self.dls, name: "DLSMusicDevice",
                                     manufacturerName: "Apple",
                                     stateData: Data([1, 2, 3, 4]))
        let track = Track(name: "AU", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .audioUnit, audioUnit: config))
        let document = ProjectDocument(name: "t", transport: TransportState(),
                                       tracks: [track], masterVolume: 1, mediaRefs: [:])
        let data = try bundleEncoder().encode(document)
        // stateData rides inline as base64 (Codable's Data default).
        #expect(String(data: data, encoding: .utf8)!.contains("AQIDBA=="))

        let decoded = try bundleDecoder().decode(ProjectDocument.self, from: data)
        let runtime = decoded.runtimeState(bundleURL: URL(fileURLWithPath: "/tmp/x.dawproj"))
        let restored = try #require(runtime.tracks.first?.instrument)
        #expect(restored.kind == .audioUnit)
        #expect(restored.audioUnit == config)  // component, names, AND state intact
        #expect(runtime.warnings.isEmpty)
    }

    @Test("a project without AU instruments never gains an audioUnit key (byte-identical round trip)")
    func noAudioUnitProjectByteIdentity() throws {
        let tracks = [
            Track(name: "A", kind: .audio,
                  clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4)]),
            Track(name: "Keys", kind: .instrument,
                  instrument: InstrumentDescriptor(kind: .polySynth)),
        ]
        let document = ProjectDocument(name: "t", transport: TransportState(),
                                       tracks: tracks, masterVolume: 1,
                                       mediaRefs: [:])
        let encoder = bundleEncoder()
        let first = try encoder.encode(document)
        #expect(!String(data: first, encoding: .utf8)!.contains("audioUnit"))
        // Decode → re-encode is byte-identical: the additive field costs a
        // pre-AU project nothing.
        let decoded = try bundleDecoder().decode(ProjectDocument.self, from: first)
        let second = try encoder.encode(decoded)
        #expect(first == second)
    }

    @Test("setInstrument audioUnit replaces wholesale, implies kind, and is undoable")
    func setInstrumentAudioUnitIsWholesaleAndUndoable() throws {
        let store = ProjectStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        let track = store.addTrack(kind: .instrument)

        let configA = AudioUnitConfig(component: Self.dls, name: "DLSMusicDevice",
                                      manufacturerName: "Apple",
                                      stateData: Data([7, 7, 7]))
        clock = clock.advanced(by: .seconds(2))  // defeat same-key coalescing
        let first = try store.setInstrument(id: track.id, audioUnit: configA)
        // Providing audioUnit implies kind .audioUnit when kind is omitted.
        #expect(first?.kind == .audioUnit)
        #expect(store.tracks[0].instrument?.audioUnit == configA)

        // Wholesale replacement: B carries no stateData, and none survives.
        let configB = AudioUnitConfig(
            component: AudioUnitComponentID(subType: "msyn", manufacturer: "appl"),
            name: "AUMIDISynth", manufacturerName: "Apple")
        clock = clock.advanced(by: .seconds(2))
        let second = try store.setInstrument(id: track.id, audioUnit: configB)
        #expect(second?.audioUnit == configB)
        #expect(store.tracks[0].instrument?.audioUnit?.stateData == nil)
        // The poly-synth params survive kind switches (carried like sampler).
        #expect(second?.polySynth == PolySynthParams())

        try store.undo()
        #expect(store.tracks[0].instrument?.audioUnit == configA)
        #expect(store.tracks[0].instrument?.kind == .audioUnit)
        try store.undo()
        #expect(store.tracks[0].instrument == nil)

        // Non-instrument tracks still refuse, config or not.
        let audio = store.addTrack(kind: .audio)
        #expect(throws: ProjectError.self) {
            try store.setInstrument(id: audio.id, audioUnit: configA)
        }
    }
}
