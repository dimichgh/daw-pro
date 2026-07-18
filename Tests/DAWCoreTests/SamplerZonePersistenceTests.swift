import Foundation
import Testing
@testable import DAWCore

// Reuses FakeMedia (ImportTests.swift) from the DAWCoreTests target, and the
// always-present system alert sounds as real readable zone media.

/// m19-b persistence gap fix: `SamplerZoneDocument` (the project-bundle wire
/// format) must carry the m19-a selection fields AND the m19-b playback
/// scalars — before this, a saved project silently dropped every one of them
/// on reopen. All 20 fields (17 m19-a/b + 3 m20-g loop keys) are
/// additive-optional and OMITTED when nil (the ClipDocument omit-when-default
/// rule), so a pre-m19 zone document stays byte-identical and pre-m19 project
/// files still open.
@MainActor
@Suite("Sampler zone persistence — m19-a/b fields in the project bundle")
struct SamplerZonePersistenceTests {
    private let ping = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampler-zone-persist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("all 20 m19-a/b + m20-g zone fields survive save → reopen")
    func fullZoneRoundTrip() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()
        let inst = store.addTrack(name: "Kit", kind: .instrument)
        let zone = SamplerZone(
            audioFileURL: ping, rootPitch: 60, minPitch: 36, maxPitch: 84, gain: 1.5,
            minVelocity: 20, maxVelocity: 90, group: 2, seqLength: 4, seqPosition: 3,
            randMin: 0.25, randMax: 0.75,
            tuneCents: -150, pan: 0.5, ampVelTrack: 0.25, oneShot: true,
            startFrame: 100, endFrame: 2_000,
            attack: 0.01, decay: 0.5, sustain: 0.6, release: 0.2,
            loopMode: .sustain, loopStart: 500, loopEnd: 1_500)
        try store.setInstrument(id: inst.id, kind: .sampler,
                                sampler: SamplerParams(zones: [zone]))

        let path = dir.appendingPathComponent("Layered Kit").path
        _ = try store.saveProject(to: path)

        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        let warnings = try reopened.openProject(at: path)
        #expect(warnings.isEmpty)
        let loaded = try #require(reopened.tracks[0].instrument?.sampler?.zones.first)
        // m19-a selection dimension.
        #expect(loaded.minVelocity == 20)
        #expect(loaded.maxVelocity == 90)
        #expect(loaded.group == 2)
        #expect(loaded.seqLength == 4)
        #expect(loaded.seqPosition == 3)
        #expect(loaded.randMin == 0.25)
        #expect(loaded.randMax == 0.75)
        // m19-b playback scalars (incl. the A5 gain relax).
        #expect(loaded.gain == 1.5)
        #expect(loaded.tuneCents == -150)
        #expect(loaded.pan == 0.5)
        #expect(loaded.ampVelTrack == 0.25)
        #expect(loaded.oneShot == true)
        #expect(loaded.startFrame == 100)
        #expect(loaded.endFrame == 2_000)
        #expect(loaded.attack == 0.01)
        #expect(loaded.decay == 0.5)
        #expect(loaded.sustain == 0.6)
        #expect(loaded.release == 0.2)
        // m20-g loop fields.
        #expect(loaded.loopMode == .sustain)
        #expect(loaded.loopStart == 500)
        #expect(loaded.loopEnd == 1_500)
    }

    @Test("a legacy zone document encodes NONE of the 17 optional keys and decodes them as nil")
    func legacyDocumentShapeStable() throws {
        // Encode side: a nil-field zone's document JSON carries only the
        // legacy keys — byte-shape-compatible with a pre-m19 save.
        let legacy = SamplerZone(audioFileURL: ping, rootPitch: 55)
        let document = SamplerZoneDocument(from: legacy, media: "media/Ping.aiff")
        let data = try JSONEncoder().encode(document)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["id", "media", "rootPitch", "minPitch", "maxPitch", "gain"])

        // Decode side: a pre-m19 document (no new keys) reads every new
        // field as nil.
        let decoded = try JSONDecoder().decode(SamplerZoneDocument.self, from: data)
        #expect(decoded.minVelocity == nil)
        #expect(decoded.maxVelocity == nil)
        #expect(decoded.group == nil)
        #expect(decoded.seqLength == nil)
        #expect(decoded.seqPosition == nil)
        #expect(decoded.randMin == nil)
        #expect(decoded.randMax == nil)
        #expect(decoded.tuneCents == nil)
        #expect(decoded.pan == nil)
        #expect(decoded.ampVelTrack == nil)
        #expect(decoded.oneShot == nil)
        #expect(decoded.startFrame == nil)
        #expect(decoded.endFrame == nil)
        #expect(decoded.attack == nil)
        #expect(decoded.decay == nil)
        #expect(decoded.sustain == nil)
        #expect(decoded.release == nil)
    }
}
