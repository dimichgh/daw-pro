import Foundation
import Testing
@testable import DAWCore

// m39-tpl-3 — THE SKELETON GOLDEN GATE (docs/design/2026-09-27-multi-instrument-templates.md §8.4).
//
// Recorded BEFORE TPL-3 changed a line of `SongSkeleton.swift`: for each of the 14 genres, with the genre's own
// roster and with one fixed `tracks` override, the project file a save would write after `applySongSkeleton` on a
// fresh store. TPL-3 then re-pointed the skeleton through `TemplateBuilder`, and every one of these 28 files had to
// stay BYTE-IDENTICAL. Since then: `rock-default.json` changed by D3 (rock's "Drums" and "Bass" got the instruments
// every other band genre already had); its diff added exactly two `instrument` blocks. Then m27-e (2026-10-07)
// changed ALL 28 by exactly one line each: the "Arrangement" guide track (the LAST track, so the LAST `"isMuted"`
// line) went from `"isMuted" : false` to `true`, checked line by line and field by field before acceptance. The
// pre-m27-e `pop-default`/`pop-override` live on, verbatim, in `Fixtures/SkeletonGuideBefore/` (the open test).
//
// The bytes are the real save path's (`ProjectBundle.write`: pretty-printed, sorted keys, ISO-8601 dates, via
// `ProjectDocumentFidelityTests.bundleBytes`), with `savedAt` pinned and every UUID replaced by `UUID-<n>` in order
// of first appearance — ids are random per run; everything else must not be.
//
// ⚠️ WHEN ONE GOES RED. The test writes what it got to `$TMPDIR/dawpro-tpl3-skeleton-golden-actual/<name>.json`
// and names the first differing line. A change you MEANT (a deliberate roster change, a reviewed save-format
// change) is accepted by copying that file over the fixture — and the `diff -u` of the two must show ONLY what you
// meant. A change you did not mean is the regression this gate exists for. Never regenerate without the diff.
//
// ⚠️ An EXTENSION of the existing `@MainActor` suite `SongSkeletonTests`, not a new suite: the Leg C cap on
// `@MainActor` suites (393 of 394 used). Helpers carry a `tpl3` prefix.

extension SongSkeletonTests {
    // MARK: - Helpers

    /// One roster for every genre's override fixture, covering every shape a `SongSkeletonTrack` can take: a
    /// program and a preset, a program only, a preset only, neither, an audio track with and without a preset,
    /// the General MIDI drum kit, and a roster track NAMED "Arrangement" (the real guide track still lands last).
    static let tpl3OverrideRoster: [SongSkeletonTrack] = [
        SongSkeletonTrack(name: "Kit", kind: .instrument, mixerPreset: "drum-bus-glue",
                          program: GMProgramCatalog.standardDrumKit),
        SongSkeletonTrack(name: "Upright", kind: .instrument, program: GMProgramCatalog.melodic(32)),
        SongSkeletonTrack(name: "Synth Lead", kind: .instrument, mixerPreset: "warm-keys"),
        SongSkeletonTrack(name: "Pad", kind: .instrument),
        SongSkeletonTrack(name: "Lead Vocal", kind: .audio, mixerPreset: "vocal-presence"),
        SongSkeletonTrack(name: "Room Mic", kind: .audio),
        SongSkeletonTrack(name: "Arrangement", kind: .instrument, mixerPreset: "horn-section",
                          program: GMProgramCatalog.melodic(61)),
    ]

    static let tpl3UUIDPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

    /// Every UUID replaced by `UUID-<n>`, numbered by first appearance. Returns how many occurrences were
    /// replaced and how many distinct ids there were.
    static func tpl3Normalize(_ text: String) -> (text: String, replaced: Int, distinct: Int) {
        let regex = try! NSRegularExpression(pattern: tpl3UUIDPattern)
        let source = text as NSString
        var tokens: [String: String] = [:]
        var output = ""
        var cursor = 0
        var replaced = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor,
                                                     length: match.range.location - cursor))
            let id = source.substring(with: match.range).uppercased()
            let token = tokens[id] ?? String(format: "UUID-%03d", tokens.count + 1)
            tokens[id] = token
            output += token
            replaced += 1
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return (output, replaced, tokens.count)
    }

    static func tpl3UUIDCount(_ text: String) -> Int {
        let regex = try! NSRegularExpression(pattern: tpl3UUIDPattern)
        return regex.numberOfMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    /// The save path's bytes for a fresh store after one skeleton call, `savedAt` pinned, before normalising.
    func tpl3RawSkeletonText(_ genre: String, override: Bool) throws -> String {
        let store = ProjectStore()
        _ = try store.applySongSkeleton(genre: genre, tracks: override ? Self.tpl3OverrideRoster : nil)
        var document = store.buildAutosaveDocument(includeChats: false)
        document.savedAt = Date(timeIntervalSince1970: 0)
        return String(decoding: try ProjectDocumentFidelityTests.bundleBytes(of: document), as: UTF8.self)
    }

    func tpl3SkeletonBytes(_ genre: String, override: Bool) throws -> Data {
        Data(Self.tpl3Normalize(try tpl3RawSkeletonText(genre, override: override)).text.utf8)
    }

    static func tpl3FixtureName(_ genre: String, override: Bool) -> String {
        "\(genre)-\(override ? "override" : "default")"
    }

    static var tpl3ActualDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-tpl3-skeleton-golden-actual", isDirectory: true)
    }

    /// Compares one skeleton against its fixture. A missing fixture FAILS (it must never read as a match), and
    /// any mismatch writes what was produced, so a reviewer can `diff -u` it against the fixture.
    func tpl3AssertGolden(_ genre: String, override: Bool) throws {
        let name = Self.tpl3FixtureName(genre, override: override)
        let actual = try tpl3SkeletonBytes(genre, override: override)
        let url = Bundle.module.url(forResource: name, withExtension: "json",
                                    subdirectory: "Fixtures/SkeletonGolden")
        let expected = try url.map { try Data(contentsOf: $0) }
        guard expected != actual else { return }
        let directory = Self.tpl3ActualDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let written = directory.appendingPathComponent("\(name).json")
        try actual.write(to: written)
        guard let expected else {
            Issue.record("""
                TPL-3 golden \(name): the fixture Fixtures/SkeletonGolden/\(name).json is not in the test \
                bundle. What this build produced is at \(written.path).
                """)
            return
        }
        Issue.record("""
            TPL-3 golden \(name): the skeleton no longer writes the bytes it wrote before TPL-3 \
            (\(actual.count) vs \(expected.count) bytes). First difference — \
            \(ProjectDocumentFidelityTests.firstDifference(actual, expected)). What this build produced is at \
            \(written.path); `diff -u` it against the fixture. Only a change you meant may be accepted, and the \
            diff must show nothing else.
            """)
    }

    // MARK: - Controls (they keep the 28 comparisons honest)

    @Test("m39-tpl-3 golden control: the normaliser replaces every id the skeleton made, and leaves none")
    func tpl3GoldenNormaliserReplacesEveryID() throws {
        let store = ProjectStore()
        let result = try store.applySongSkeleton(genre: "pop")
        var document = store.buildAutosaveDocument(includeChats: false)
        document.savedAt = Date(timeIntervalSince1970: 0)
        let raw = String(decoding: try ProjectDocumentFidelityTests.bundleBytes(of: document), as: UTF8.self)
        // Every id the call returned is really in the file, so the normaliser had real ids to replace.
        let returned = result.tracks.map(\.id) + result.markers.map(\.id)
        for id in returned {
            #expect(raw.contains(id.uuidString), "id \(id) is not in the saved file")
        }
        let normalised = Self.tpl3Normalize(raw)
        #expect(normalised.distinct >= returned.count + result.sectionClips.count,
                "expected at least one id per track, marker and guide clip; saw \(normalised.distinct)")
        #expect(normalised.replaced >= normalised.distinct)
        #expect(Self.tpl3UUIDCount(normalised.text) == 0, "a UUID survived normalising")
        // The residual counter can count: a real UUID is found, in either case.
        #expect(Self.tpl3UUIDCount("a \(UUID().uuidString) b \(UUID().uuidString.lowercased()) c") == 2)
        #expect(normalised.text.contains("\"UUID-001\""))
    }

    @Test("m39-tpl-3 golden control: two fresh stores write the same normalised bytes")
    func tpl3GoldenBytesAreDeterministic() throws {
        for (genre, override) in [("pop", false), ("jazz", true), ("lo-fi", false)] {
            let first = try tpl3SkeletonBytes(genre, override: override)
            let second = try tpl3SkeletonBytes(genre, override: override)
            #expect(first == second, "\(genre) override=\(override): two runs in one process differ")
            #expect(first.count > 2_000, "\(genre): implausibly small (\(first.count) bytes)")
        }
    }

    @Test("m39-tpl-3 golden control: exactly one default and one override fixture per catalog genre")
    func tpl3GoldenFixtureInventory() {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json",
                                      subdirectory: "Fixtures/SkeletonGolden") ?? []
        let found = Set(urls.map { $0.deletingPathExtension().lastPathComponent })
        let expected = Set(SongSkeletonCatalog.names.flatMap { genre in
            [Self.tpl3FixtureName(genre, override: false), Self.tpl3FixtureName(genre, override: true)]
        })
        #expect(expected.count == 28)
        #expect(found == expected, """
            fixtures missing: \(expected.subtracting(found).sorted()); \
            fixtures with no genre: \(found.subtracting(expected).sorted())
            """)
    }

    // MARK: - The 28 (one test each, so a red names its fixture)

    @Test("m39-tpl-3 golden: pop") func goldenPopDefault() throws { try tpl3AssertGolden("pop", override: false) }
    @Test("m39-tpl-3 golden: pop, override") func goldenPopOverride() throws { try tpl3AssertGolden("pop", override: true) }
    @Test("m39-tpl-3 golden: house") func goldenHouseDefault() throws { try tpl3AssertGolden("house", override: false) }
    @Test("m39-tpl-3 golden: house, override") func goldenHouseOverride() throws { try tpl3AssertGolden("house", override: true) }
    @Test("m39-tpl-3 golden: hip-hop") func goldenHipHopDefault() throws { try tpl3AssertGolden("hip-hop", override: false) }
    @Test("m39-tpl-3 golden: hip-hop, override") func goldenHipHopOverride() throws { try tpl3AssertGolden("hip-hop", override: true) }
    @Test("m39-tpl-3 golden: rock") func goldenRockDefault() throws { try tpl3AssertGolden("rock", override: false) }
    @Test("m39-tpl-3 golden: rock, override") func goldenRockOverride() throws { try tpl3AssertGolden("rock", override: true) }
    @Test("m39-tpl-3 golden: ballad") func goldenBalladDefault() throws { try tpl3AssertGolden("ballad", override: false) }
    @Test("m39-tpl-3 golden: ballad, override") func goldenBalladOverride() throws { try tpl3AssertGolden("ballad", override: true) }
    @Test("m39-tpl-3 golden: blues") func goldenBluesDefault() throws { try tpl3AssertGolden("blues", override: false) }
    @Test("m39-tpl-3 golden: blues, override") func goldenBluesOverride() throws { try tpl3AssertGolden("blues", override: true) }
    @Test("m39-tpl-3 golden: jazz") func goldenJazzDefault() throws { try tpl3AssertGolden("jazz", override: false) }
    @Test("m39-tpl-3 golden: jazz, override") func goldenJazzOverride() throws { try tpl3AssertGolden("jazz", override: true) }
    @Test("m39-tpl-3 golden: country") func goldenCountryDefault() throws { try tpl3AssertGolden("country", override: false) }
    @Test("m39-tpl-3 golden: country, override") func goldenCountryOverride() throws { try tpl3AssertGolden("country", override: true) }
    @Test("m39-tpl-3 golden: r-and-b") func goldenRAndBDefault() throws { try tpl3AssertGolden("r-and-b", override: false) }
    @Test("m39-tpl-3 golden: r-and-b, override") func goldenRAndBOverride() throws { try tpl3AssertGolden("r-and-b", override: true) }
    @Test("m39-tpl-3 golden: funk") func goldenFunkDefault() throws { try tpl3AssertGolden("funk", override: false) }
    @Test("m39-tpl-3 golden: funk, override") func goldenFunkOverride() throws { try tpl3AssertGolden("funk", override: true) }
    @Test("m39-tpl-3 golden: metal") func goldenMetalDefault() throws { try tpl3AssertGolden("metal", override: false) }
    @Test("m39-tpl-3 golden: metal, override") func goldenMetalOverride() throws { try tpl3AssertGolden("metal", override: true) }
    @Test("m39-tpl-3 golden: folk") func goldenFolkDefault() throws { try tpl3AssertGolden("folk", override: false) }
    @Test("m39-tpl-3 golden: folk, override") func goldenFolkOverride() throws { try tpl3AssertGolden("folk", override: true) }
    @Test("m39-tpl-3 golden: reggae") func goldenReggaeDefault() throws { try tpl3AssertGolden("reggae", override: false) }
    @Test("m39-tpl-3 golden: reggae, override") func goldenReggaeOverride() throws { try tpl3AssertGolden("reggae", override: true) }
    @Test("m39-tpl-3 golden: lo-fi") func goldenLoFiDefault() throws { try tpl3AssertGolden("lo-fi", override: false) }
    @Test("m39-tpl-3 golden: lo-fi, override") func goldenLoFiOverride() throws { try tpl3AssertGolden("lo-fi", override: true) }
}
