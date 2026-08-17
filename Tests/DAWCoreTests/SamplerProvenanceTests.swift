import Foundation
import Testing
@testable import DAWCore

// Reuses FakeMedia (ImportTests.swift) from the DAWCoreTests target.

/// m26-h: a sampler track records WHICH library it was imported from.
/// Before this, an imported track read `kind: "sampler"` and nothing else —
/// the snapshot held resolved per-zone sample paths but no source `.sfz`
/// path and no name, so "which bass is this?" was answerable only by dumping
/// a ~1 MB snapshot and eyeballing a zone's directory (field report
/// 2026-08-17, finding 13).
///
/// `sourcePath`/`displayName` are ADDITIVE-OPTIONAL and PERSISTED, which is
/// the one thing in m26-g/h that can damage an existing project file — hence
/// `preM26hDocumentOpensClean`, which opens a document written WITHOUT the
/// fields rather than merely round-tripping through the new writer (a round
/// trip through the new writer always contains them, so it cannot see this
/// class of break at all).
@MainActor
@Suite("Sampler provenance — imported-library identity (m26-h)")
struct SamplerProvenanceTests {
    private func makeStore() -> ProjectStore {
        let store = ProjectStore()
        store.media = FakeMedia()
        return store
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampler-provenance-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A one-region library whose sample is a REAL decodable file, named so
    /// the display-name derivation has something recognisable to strip.
    private func writeLibrary(named name: String = "Upright Bass") throws -> URL {
        let dir = tempDir()
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff"),
            to: dir.appendingPathComponent("ping.aiff"))
        let sfz = dir.appendingPathComponent("\(name).sfz")
        try Data("<region> sample=ping.aiff lokey=28 hikey=52 pitch_keycenter=40\n".utf8)
            .write(to: sfz)
        return sfz
    }

    @Test("importing a library records its path and name; a dryRun records nothing")
    func importRecordsProvenance() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .instrument)
        let sfz = try writeLibrary()

        // dryRun touches NOTHING — including provenance.
        _ = try store.importSampleLibrary(trackID: track.id, path: sfz.path, dryRun: true)
        #expect(store.tracks[0].instrument == nil)

        let report = try store.importSampleLibrary(trackID: track.id, path: sfz.path)
        #expect(report.zonesImported == 1)
        let sampler = try #require(store.tracks[0].instrument?.sampler)
        #expect(sampler.sourcePath == sfz.path)
        #expect(sampler.displayName == "Upright Bass")   // the stem, not the file name
        #expect(sampler.zones.count == 1)

        // Undo restores the previous instrument, provenance and all — an
        // import is ONE journaled edit, not an edit plus a hidden write.
        _ = try store.undo()
        #expect(store.tracks[0].instrument == nil)
    }

    @Test("a hand-built sampler has no provenance and claims none")
    func handBuiltSamplerHasNoProvenance() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .instrument)
        try store.setInstrument(
            id: track.id, kind: .sampler,
            sampler: SamplerParams(zones: [
                SamplerZone(audioFileURL: URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")),
            ]))
        let sampler = try #require(store.tracks[0].instrument?.sampler)
        #expect(sampler.sourcePath == nil)
        #expect(sampler.displayName == nil)
    }

    @Test("provenance survives save → reopen")
    func provenanceSurvivesSaveReopen() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .instrument)
        let sfz = try writeLibrary(named: "Tine Rhodes")
        _ = try store.importSampleLibrary(trackID: track.id, path: sfz.path)

        let path = tempDir().appendingPathComponent("Provenance").path
        _ = try store.saveProject(to: path)

        let reopened = makeStore()
        let warnings = try reopened.openProject(at: path)
        #expect(warnings.isEmpty)
        let sampler = try #require(reopened.tracks[0].instrument?.sampler)
        #expect(sampler.sourcePath == sfz.path)
        #expect(sampler.displayName == "Tine Rhodes")
        #expect(sampler.zones.count == 1)
    }

    /// THE DECODE-TOLERANCE PROOF. A round trip through the NEW writer always
    /// contains the new keys, so it can never demonstrate that their ABSENCE
    /// is tolerated. This saves a real project, then STRIPS both keys out of
    /// `project.json` — producing exactly the bytes a pre-m26-h build wrote —
    /// and opens THAT.
    ///
    /// The strip is positive-controlled: the test asserts both keys were
    /// PRESENT before removing them, so a rename or a silently-dropped key
    /// would fail here rather than leaving the test passing vacuously against
    /// a document that never carried the fields in the first place.
    @Test("a pre-m26-h project.json — no sourcePath, no displayName — opens clean")
    func preM26hDocumentOpensClean() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .instrument)
        let sfz = try writeLibrary(named: "Legacy Bass")
        _ = try store.importSampleLibrary(trackID: track.id, path: sfz.path)
        let bundlePath = tempDir().appendingPathComponent("Legacy").path
        _ = try store.saveProject(to: bundlePath)

        let jsonURL = ProjectBundle.normalizedBundleURL(fromPath: bundlePath)
            .appendingPathComponent("project.json")
        var root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        var tracks = try #require(root["tracks"] as? [[String: Any]])
        var instrument = try #require(tracks[0]["instrument"] as? [String: Any])
        var samplerDocument = try #require(instrument["sampler"] as? [String: Any])

        // POSITIVE CONTROL: the keys are really there, spelled the way the
        // model spells them, before the strip removes them.
        #expect(samplerDocument["sourcePath"] as? String == sfz.path)
        #expect(samplerDocument["displayName"] as? String == "Legacy Bass")
        let zonesBefore = try #require(samplerDocument["zones"] as? [[String: Any]]).count
        #expect(zonesBefore == 1)

        samplerDocument.removeValue(forKey: "sourcePath")
        samplerDocument.removeValue(forKey: "displayName")
        #expect(samplerDocument["sourcePath"] == nil)
        #expect(samplerDocument["displayName"] == nil)
        instrument["sampler"] = samplerDocument
        tracks[0]["instrument"] = instrument
        root["tracks"] = tracks
        try JSONSerialization.data(withJSONObject: root).write(to: jsonURL)

        // …and the pre-m26-h document opens with no warning, no dropped zone,
        // and nil provenance — which is defined to reproduce the original
        // behaviour exactly.
        let reopened = makeStore()
        let warnings = try reopened.openProject(at: bundlePath)
        #expect(warnings.isEmpty)
        let sampler = try #require(reopened.tracks[0].instrument?.sampler)
        #expect(sampler.sourcePath == nil)
        #expect(sampler.displayName == nil)
        #expect(sampler.zones.count == zonesBefore)     // NOT a vacuous pass
        #expect(sampler.zones[0].minPitch == 28)
        #expect(sampler.zones[0].maxPitch == 52)
    }

    @Test("nil provenance never encodes — a hand-built sampler's document shape is unchanged")
    func nilProvenanceNeverEncodes() throws {
        let zone = SamplerZone(
            audioFileURL: URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff"))
        func keys(_ params: SamplerParams) throws -> Set<String> {
            let data = try JSONEncoder().encode(
                SamplerDocument(from: params, mediaRefs: [zone.id: "media/Ping.aiff"]))
            let json = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return Set(json.keys)
        }

        // No provenance → neither key is written, so a pre-m26-h reader sees
        // the shape it has always seen.
        #expect(try keys(SamplerParams(zones: [zone]))
            == ["zones", "oneShot", "attack", "release", "gain"])

        // POSITIVE CONTROL for the assertion above: with provenance set, the
        // same probe DOES find both keys — so the empty result is an absence,
        // not a probe that cannot see.
        #expect(try keys(SamplerParams(zones: [zone], sourcePath: "/l/Bass.sfz",
                                       displayName: "Bass"))
            == ["zones", "oneShot", "attack", "release", "gain",
                "sourcePath", "displayName"])
    }
}
