import Foundation
import Testing
@testable import DAWCore

// Reuses fakes already defined in the DAWCoreTests target:
//   FakeMedia (ImportTests.swift), FakeEngine (CoreTests.swift).
//
// Fixtures use the system alert sounds under /System/Library/Sounds — real,
// readable audio files that exist on every macOS install, so the store's
// existence check (and the media service's readability read) pass for real.

@MainActor
@Suite("Sampler — configuration, validation, persistence")
struct SamplerTests {
    private let ping = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
    private let tink = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
    private let glass = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")

    private func zone(_ url: URL, root: Int = 60, lo: Int = 0, hi: Int = 127,
                      gain: Double = 1) -> SamplerZone {
        SamplerZone(audioFileURL: url, rootPitch: root, minPitch: lo, maxPitch: hi, gain: gain)
    }

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampler-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // 1. Wholesale replace (zones are not merged) + undo/redo restores the prior zones.
    @Test("a sampler config replaces the prior one wholesale; undo/redo restores it")
    func wholesaleReplaceAndUndoRedo() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let inst = store.addTrack(kind: .instrument)

        // Deterministic clock so the two edits don't time-coalesce into one step.
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        let z1 = zone(ping, root: 60)
        try store.setInstrument(id: inst.id, kind: .sampler,
                                sampler: SamplerParams(zones: [z1], oneShot: true, gain: 0.5))
        #expect(store.tracks[0].instrument?.kind == .sampler)
        #expect(store.tracks[0].instrument?.sampler?.zones == [z1])
        #expect(store.tracks[0].instrument?.sampler?.oneShot == true)

        clock = clock.advanced(by: .seconds(30))
        let z2 = zone(tink, root: 48)
        let z3 = zone(glass, root: 72)
        // Only `sampler` is passed — kind stays .sampler; the zones REPLACE (not
        // merge) the single prior zone.
        try store.setInstrument(id: inst.id, sampler: SamplerParams(zones: [z2, z3]))
        #expect(store.tracks[0].instrument?.sampler?.zones == [z2, z3])
        #expect(store.undoLabel == "Change Instrument")

        try store.undo()
        #expect(store.tracks[0].instrument?.sampler?.zones == [z1])  // prior zones restored

        try store.redo()
        #expect(store.tracks[0].instrument?.sampler?.zones == [z2, z3])
    }

    // 2. An empty zones array is legal (silent sampler) and needs no media.
    @Test("an empty zones array is a legal, silent sampler")
    func emptyZonesLegal() throws {
        let store = ProjectStore()  // no media service wired
        let inst = store.addTrack(kind: .instrument)
        let resolved = try #require(try store.setInstrument(
            id: inst.id, kind: .sampler, sampler: SamplerParams(zones: [])))
        #expect(resolved.kind == .sampler)
        #expect(resolved.sampler?.zones.isEmpty == true)
        #expect(store.tracks[0].instrument?.sampler?.zones.isEmpty == true)
    }

    // 3. A nonexistent zone file throws the MediaImporting-style error verbatim,
    //    changing nothing and recording no undo entry.
    @Test("a nonexistent zone file throws importFailed verbatim and stores nothing")
    func missingZoneFileRejected() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let inst = store.addTrack(kind: .instrument)
        let ghost = URL(fileURLWithPath: "/nonexistent/Ghost.aiff")

        let error = projectError {
            _ = try store.setInstrument(id: inst.id, kind: .sampler,
                                        sampler: SamplerParams(zones: [zone(ghost)]))
        }
        guard case .importFailed? = error else {
            Issue.record("expected importFailed, got \(String(describing: error))"); return
        }
        #expect(error?.errorDescription == "Audio import failed: no file at /nonexistent/Ghost.aiff")
        // Nothing stored; the failed edit recorded no history.
        #expect(store.tracks[0].instrument == nil)
        #expect(store.undoLabel == "Add Track 'Inst 1'")
    }

    // 4. Non-empty zones with no media service throws mediaServiceUnavailable,
    //    exactly like an import attempt.
    @Test("configuring zones without a media service throws mediaServiceUnavailable")
    func zonesNeedMediaService() throws {
        let store = ProjectStore()  // no media
        let inst = store.addTrack(kind: .instrument)
        let error = projectError {
            _ = try store.setInstrument(id: inst.id, kind: .sampler,
                                        sampler: SamplerParams(zones: [zone(ping)]))
        }
        guard case .mediaServiceUnavailable? = error else {
            Issue.record("expected mediaServiceUnavailable, got \(String(describing: error))"); return
        }
        #expect(store.tracks[0].instrument == nil)
    }

    // 5. Persistence: mediaFilesCopied counts zone files; reopen rewrites zone
    //    URLs into the bundle's media/.
    @Test("save copies zone media and reopen resolves zones into the bundle")
    func zonePersistenceRoundTrip() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()
        let inst = store.addTrack(name: "Drums", kind: .instrument)
        try store.setInstrument(
            id: inst.id, kind: .sampler,
            sampler: SamplerParams(zones: [zone(ping, root: 60), zone(tink, root: 48)],
                                   oneShot: true, attack: 0.002, release: 0.1, gain: 0.7))

        let path = dir.appendingPathComponent("Kit Song").path
        let result = try store.saveProject(to: path)
        #expect(result.mediaFilesCopied == 2)
        #expect(result.warnings.isEmpty)

        // Live zone URLs were rewritten into the bundle's media/.
        let liveZones = try #require(store.tracks[0].instrument?.sampler?.zones)
        #expect(liveZones.count == 2)
        for z in liveZones {
            #expect(z.audioFileURL.deletingLastPathComponent().lastPathComponent == "media")
            #expect(FileManager.default.fileExists(atPath: z.audioFileURL.path))
        }

        // Reopen: zones resolve to the copied files, params preserved.
        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        let warnings = try reopened.openProject(at: path)
        #expect(warnings.isEmpty)
        let sampler = try #require(reopened.tracks.first { $0.name == "Drums" }?.instrument?.sampler)
        #expect(sampler.zones.count == 2)
        #expect(sampler.oneShot == true)
        #expect(sampler.attack == 0.002)
        #expect(sampler.release == 0.1)
        #expect(sampler.gain == 0.7)
        #expect(sampler.zones[0].rootPitch == 60)
        #expect(sampler.zones[1].rootPitch == 48)
        #expect(sampler.zones.allSatisfy {
            $0.audioFileURL.deletingLastPathComponent().lastPathComponent == "media"
            && FileManager.default.fileExists(atPath: $0.audioFileURL.path)
        })
    }

    // 6. Dedupe: two zones sharing one source (and a clip sharing it too) copy once.
    @Test("zones sharing a source — and a clip sharing it — copy once")
    func zoneAndClipDedupe() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.media = FakeMedia()

        let audio = store.addTrack(kind: .audio)
        try store.importAudio(url: ping, toTrack: audio.id)  // clip on ping

        let inst = store.addTrack(kind: .instrument)
        try store.setInstrument(
            id: inst.id, kind: .sampler,
            sampler: SamplerParams(zones: [zone(ping, root: 60), zone(ping, root: 72)]))

        let path = dir.appendingPathComponent("Dedupe").path
        let result = try store.saveProject(to: path)
        // One physical copy shared by the clip and both zones.
        #expect(result.mediaFilesCopied == 1)

        let mediaDir = URL(fileURLWithPath: store.projectPath!).appendingPathComponent("media")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: mediaDir, includingPropertiesForKeys: nil))?.map(\.lastPathComponent) ?? []
        #expect(Set(files) == ["Ping.aiff"])
        let zones = try #require(store.tracks[1].instrument?.sampler?.zones)
        #expect(zones[0].audioFileURL.path == zones[1].audioFileURL.path)
        #expect(store.tracks[0].clips[0].audioFileURL?.path == zones[0].audioFileURL.path)
    }

    // 7. Missing external source at save → warning + saved without media (same
    //    policy as clips); the unresolvable zone is dropped on reopen.
    @Test("a zone whose source vanishes before save is saved without media, with a warning")
    func missingZoneSourceAtSaveWarns() throws {
        let dir = tempDir()
        let scratch = dir.appendingPathComponent("Zone.aiff")
        try Data([0x52, 0x49, 0x46, 0x46, 0x00]).write(to: scratch)

        let store = ProjectStore()
        store.media = FakeMedia()
        let inst = store.addTrack(name: "S", kind: .instrument)
        // Validates while the file exists...
        try store.setInstrument(id: inst.id, kind: .sampler,
                                sampler: SamplerParams(zones: [zone(scratch)]))
        // ...then the source disappears out from under the session.
        try FileManager.default.removeItem(at: scratch)

        let path = dir.appendingPathComponent("Song").path
        let result = try store.saveProject(to: path)
        #expect(result.mediaFilesCopied == 0)
        #expect(result.warnings == [
            "missing source file \(scratch.standardizedFileURL.path) — sampler zone on track 'S' saved without media"
        ])

        // Reopen: the zone had no media ref → it's dropped (a zone can't exist
        // without a file); the sampler survives with an empty zone list.
        let reopened = ProjectStore()
        let warnings = try reopened.openProject(at: path)
        #expect(warnings.isEmpty)
        let sampler = try #require(reopened.tracks[0].instrument?.sampler)
        #expect(sampler.zones.isEmpty)
        #expect(reopened.tracks[0].instrument?.kind == .sampler)
    }

    // 8. Legacy decode: a project.json instrument WITHOUT the sampler field opens
    //    with sampler == nil (resolving to an empty SamplerParams).
    @Test("an instrument without the sampler field decodes with sampler == nil")
    func legacyInstrumentDecodesWithoutSampler() throws {
        let dir = tempDir()
        let trackID = UUID().uuidString
        let json = """
        {
          "schemaVersion": 1,
          "name": "Legacy",
          "masterVolume": 1,
          "tracks": [
            { "id": "\(trackID)", "name": "Synth", "kind": "instrument", "clips": [],
              "instrument": { "kind": "polySynth",
                "polySynth": { "waveform": "saw", "attack": 0.005, "decay": 0.08,
                  "sustain": 0.7, "release": 0.15, "cutoffHz": 8000, "resonance": 0.1, "gain": 0.8 } } }
          ]
        }
        """
        let bundleURL = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Legacy").path)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: bundleURL.appendingPathComponent("project.json"))

        let store = ProjectStore()
        try store.openProject(at: bundleURL.path)
        let descriptor = try #require(store.tracks[0].instrument)
        #expect(descriptor.kind == .polySynth)
        #expect(descriptor.sampler == nil)                    // additive field absent
        #expect(descriptor.resolvedSampler == SamplerParams())  // resolves to silent default
    }

    // 9. TrackDocument round-trips a sampler descriptor through the doc types.
    @Test("SamplerZoneDocument decodes without pitch/gain keys (additive-optional)")
    func zoneDocumentAdditiveDecode() throws {
        let json = """
        { "id": "\(UUID().uuidString)", "media": "media/Ping.aiff" }
        """
        let zd = try JSONDecoder().decode(SamplerZoneDocument.self, from: Data(json.utf8))
        #expect(zd.media == "media/Ping.aiff")
        #expect(zd.rootPitch == 60)
        #expect(zd.minPitch == 0)
        #expect(zd.maxPitch == 127)
        #expect(zd.gain == 1)
    }
}
