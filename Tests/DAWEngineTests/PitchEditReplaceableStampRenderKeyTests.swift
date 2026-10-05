import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// W7-NTU ruling 1 (2026-10-04) — THE USER'S OLD-VOCALS RULE, AT THE ENGINE:
/// `PitchEditSet.autoCorrectReplaceableStamp` is provenance (which preset
/// output a later replace question compares against), never render material.
/// A stamp that moved a render key would re-render every vocal it touched and
/// silence it while the render runs.
///
/// The engine keys a render by `StretchRenderCache.cacheKey(source:params:)`:
/// SHA256 over an explicit field list whose only edit-set input is
/// `PitchEditSetDigest.hex`, a byte hash over NAMED fields. Neither can see a
/// new stored property unless someone names it. This suite pins that from the
/// outside, beside `NaturalTuningDigestTests`' census (whose `exempt` row
/// asserts the digest alone).
///
/// Deliberately NOT `@MainActor`: `cacheKey` is `nonisolated static`, and
/// `MainActorOccupancySiteTests` Leg C caps `@MainActor` suites.
@Suite("W7-NTU ruling 1 — the replace stamp moves no render key")
struct PitchEditReplaceableStampRenderKeyTests {

    /// Planted and seen red (W7-NTU P-r1-key, 2026-10-04 window R1W2; the line said "to be planted" until it
    /// has been): `PitchEditSetDigest.hex` hashing the new stamp's length. ⚠️
    /// That plant edits `Sources/DAWEngine/Stretch/StretchCurvePlan.swift`, the
    /// engine token's file: only inside a window that grants it.
    @Test("the replace stamp, alone or beside the preset stamp, leaves the edit digest, the on-disk render key and the shaping version byte-identical on a set that renders; a retune-speed change (control) moves the digest and the key")
    func stampMovesNoRenderKey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w7ntu-r1-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The key reads the source's path, size and mtime only, never its audio.
        let source = dir.appendingPathComponent("take.wav")
        try Data(repeating: 7, count: 4096).write(to: source)
        typealias Params = StretchRenderCache.Params
        func key(_ set: PitchEditSet) throws -> String {
            try StretchRenderCache.cacheKey(
                source: source,
                params: Params(ratio: 1, semitones: 0, formantPreserve: false, pitchEdits: set))
        }

        // A plain corrected note set: the shape every project on disk holds.
        let base = NoteVibratoGeneratorTests.legacyOffsetSet()
        #expect(base.autoCorrectReplaceableStamp == nil, "premise: the fixture predates the field")
        #expect(!PitchEditSetDigest.hex(base).isEmpty,
                "premise: the fixture bends the curve, so it HAS a key that could move")
        let baseKey = try key(base)

        var stamped = base
        stamped.autoCorrectReplaceableStamp = "fedcba9876543210"
        var both = stamped
        both.autoCorrectStamp = "0123456789abcdef"
        #expect(stamped != base, "premise: the sets DIFFER under ==, so equal keys are the key's own doing")

        for (label, set) in [("the replace stamp alone", stamped), ("both stamps, as a preset writes them", both)] {
            #expect(PitchEditSetDigest.hex(set) == PitchEditSetDigest.hex(base),
                    "\(label) moved the edit digest: every vocal carrying it would re-render")
            #expect(try key(set) == baseKey,
                    "\(label) moved the on-disk render key: every vocal carrying it would re-render")
            #expect(PitchRenderContour.shapingVersion(for: set) == PitchRenderContour.shapingVersion(for: base),
                    "\(label) moved the shaping version, which the resolved key appends")
        }

        // Control: this key CAN move, for this set, through the same calls.
        var faster = base
        faster.retuneMs += 10
        #expect(PitchEditSetDigest.hex(faster) != PitchEditSetDigest.hex(base),
                "CONTROL: a retune-speed change must move the digest")
        #expect(try key(faster) != baseKey, "CONTROL: a retune-speed change must move the render key")
    }
}
