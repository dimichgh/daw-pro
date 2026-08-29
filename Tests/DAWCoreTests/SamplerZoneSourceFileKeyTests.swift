import DAWCore
import Foundation
import Testing

/// m32-a — `SamplerZone.sourceFileKey` is the ONE HOME for the "do these two
/// zones share a source file?" question.
///
/// ⚠️ THE POINT OF THIS SUITE: two consumers read this key — the sampler
/// loader's buffer dedup (`SamplerInstrument.init`, DAWEngine) and
/// `ProjectBundle.planMedia`'s media-copy dedup (here). If they ever
/// disagreed, a project would PLAY one way and RELOAD another: zones the
/// loader treated as one file would be saved as two `media/` copies (or the
/// reverse), which is this tree's characteristic failure — a plausible-looking
/// valid answer from two instruments that were never compared. This suite
/// compares them.
@Suite("Sampler zone source-file key (m32-a)")
struct SamplerZoneSourceFileKeyTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32a-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// planMedia only needs the file to EXIST (it stats, it does not decode),
    /// so a byte stub is a sufficient fixture here.
    private func writeStub(_ url: URL) throws {
        try Data("RIFF-stub".utf8).write(to: url)
    }

    @Test("the key is exactly audioFileURL.standardizedFileURL.path")
    func keyIsStandardizedPath() {
        let raw = URL(fileURLWithPath: "/tmp/a/b/../x.wav")
        let zone = SamplerZone(audioFileURL: raw)
        #expect(zone.sourceFileKey == "/tmp/a/x.wav")
        // Positive control on the premise: the RAW path differs, so the
        // standardization is doing real work and not the URL initializer.
        #expect(raw.path != zone.sourceFileKey)
    }

    @Test("⚠️ known limitation: a symlink is NOT resolved (two zones, two copies)")
    func symlinkIsDeliberatelyNotResolved() throws {
        let dir = try tempDir()
        let real = dir.appendingPathComponent("real.wav")
        try writeStub(real)
        let link = dir.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Deliberate, and pinned so nobody "improves" it silently: adding
        // `resolvingSymlinksInPath` would change which `media/` BASENAMES a
        // save produces, a live behaviour change on a shipped path. A missed
        // alias only costs memory (today's behaviour).
        #expect(SamplerZone(audioFileURL: real).sourceFileKey
                != SamplerZone(audioFileURL: link).sourceFileKey)
        #expect(real.resolvingSymlinksInPath().path == link.resolvingSymlinksInPath().path)
    }

    @Test("planMedia groups zones by EXACTLY the same key")
    func planMediaAgreesWithSourceFileKey() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let one = dir.appendingPathComponent("one.wav")
        let two = dir.appendingPathComponent("two.wav")
        try writeStub(one)
        try writeStub(two)

        // Four zones, three spellings, TWO distinct source files:
        //   0: one.wav                1: sub/../one.wav (same file, other spelling)
        //   2: one.wav (again)        3: two.wav        (genuinely different)
        let urls = [
            one,
            URL(fileURLWithPath: dir.path + "/sub/../one.wav"),
            one,
            two,
        ]
        let zones = urls.map { SamplerZone(audioFileURL: $0, rootPitch: 60) }
        let track = Track(name: "Chops", kind: .instrument,
                          instrument: InstrumentDescriptor(
                            kind: .sampler, sampler: SamplerParams(zones: zones)))

        let plan = ProjectBundle.planMedia(
            tracks: [track], bundleURL: dir.appendingPathComponent("Song.dawproj"))
        #expect(plan.warnings.isEmpty)

        // The ledger under test: zone id → the media basename planMedia assigned.
        var refByZone: [UUID: String] = [:]
        for zone in zones {
            refByZone[zone.id] = try #require(plan.refs[zone.id] ?? nil)
        }

        // ⭐ THE AGREEMENT ASSERTION, both directions:
        //   same sourceFileKey  ⇒  same media ref
        //   different key       ⇒  different media ref
        for (i, a) in zones.enumerated() {
            for b in zones[(i + 1)...] {
                if a.sourceFileKey == b.sourceFileKey {
                    #expect(refByZone[a.id] == refByZone[b.id])
                } else {
                    #expect(refByZone[a.id] != refByZone[b.id])
                }
            }
        }

        // POSITIVE CONTROL: the loop above must actually exercise BOTH arms.
        // A four-zone set that happened to collapse to one key would satisfy
        // it vacuously.
        let distinctKeys = Set(zones.map(\.sourceFileKey))
        #expect(distinctKeys.count == 2)
        #expect(Set(refByZone.values).count == 2)
        // …and planMedia planned exactly two copies, not four.
        #expect(plan.copies.count == 2)
        #expect(Set(plan.copies.map(\.source.lastPathComponent)) == ["one.wav", "two.wav"])
    }
}
