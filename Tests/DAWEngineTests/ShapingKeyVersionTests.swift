import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// Natural tuning §3d / §3g **G2** (W7-C3): the contour-shaping version in the
/// render key is PER SET.
///
/// `shaping:1` names the EQUAL-scale arithmetic, which the separator v2 left
/// bit for bit (G1), so every Hard Tune and preset render keeps its key.
/// `shaping:2` (`PitchRenderContour.separatedShapingVersion`) names the v2
/// branch, and a set keys it exactly when some note takes that branch
/// (`PitchEditSet.needsSeparatedShaping`, the one predicate). A later change
/// to v2 bumps only version 2, which re-keys only unequal-scale renders.
///
/// The goldens were captured on the tree BEFORE the v2 edit (runs 1 and 2 of
/// this file's pre-change capture, identical; W7-C3 STATUS). The source file
/// has a FIXED path, size and mtime, and the sets FIXED segment ids, because
/// every one of those is inside the key (`sourceIdentityFields`,
/// `PitchEditSetDigest.hex`). ⚠️ **The goldens are MACHINE-SPECIFIC**: the
/// path is under this account's `temporaryDirectory`, so on another machine
/// or account the first check below names that, and the goldens must be
/// re-captured there; the restated-formula checks are portable. ⚠️ A
/// deliberate bump of ANOTHER key input
/// (`stretchEngineVersion`, `transposeEngineVersion`, the contour's detector
/// fields or layout) moves these goldens too: re-capture them and say which
/// input moved. The restated-formula checks beside each golden keep working
/// through such a bump.
///
/// Plant (run once, recorded in STATUS): `shapingVersion = 2` (a global bump)
/// turns the Hard Tune golden red.
@Suite("Natural tuning §3 G2 — the shaping version in the render key (W7-C3)")
struct ShapingKeyVersionTests {
    static func log(_ message: String) { print("shaping-key| \(message)") }

    // MARK: - The goldens (pre-change, W7-C3 runs 1 and 2)

    static let hardTuneResolvedGolden = "502fa11f87acab61"
    static let hardTuneLegacyGolden = "036fcdfd1aa1a3a9"
    static let equalHalfResolvedGolden = "4e62ea9eb418bc8a"
    /// The unequal (0/1) set's resolved key BEFORE v2. It must NOT be its key
    /// now: a v2 render must never be served from a v1 render's file.
    static let unequalPreChangeResolved = "4edc3ffa4ce1d7f2"
    static let unequalLegacyGolden = "c38c20022a28a32a"
    /// Where the goldens' source lived when they were captured.
    static let capturedSourcePath = "/var/folders/kk/68z493hd0y52bglf0wyk7q8r0000gn/T/daw-pro-w7c3-shaping-key-golden/tone.wav"

    // MARK: - Fixture

    /// A fixed moment, so the key's mtime field never moves between runs.
    static let goldenModificationDate = Date(timeIntervalSinceReferenceDate: 780_000_000)

    /// The golden source: `<temporaryDirectory>/daw-pro-w7c3-shaping-key-golden/tone.wav`,
    /// 0.5 s of a 224 Hz tone, mtime `goldenModificationDate`. Written to a
    /// unique sibling, stamped, then `rename(2)`d over the fixed name, so a run
    /// racing this one (the full suite, say) never stats a half-written file:
    /// it sees the old file or the new one, and both carry the same path, size
    /// and mtime.
    static func goldenSource() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-w7c3-shaping-key-golden", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
        let staging = dir.appendingPathComponent("tone-\(UUID().uuidString).wav")
        try ContourToRenderTests.write(ContourToRenderTests.tone(seconds: 0.5) { _ in 224 },
                                       to: staging)
        try FileManager.default.setAttributes([.modificationDate: goldenModificationDate],
                                              ofItemAtPath: staging.path)
        guard rename(staging.path, url.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    static func note(drift: Double, vibrato: Double, id: String,
                     start: Double = 0.1, end: Double = 0.4) -> NoteSegment {
        NoteSegment(id: UUID(uuidString: id)!, startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: 0.95, pitchOffsetCents: -35,
                    driftScale: drift, vibratoScale: vibrato)
    }

    /// One note, fixed id, the given scales.
    static func set(drift: Double, vibrato: Double, id: String) -> PitchEditSet {
        PitchEditSet(segments: [note(drift: drift, vibrato: vibrato, id: id)], retuneMs: 30)
    }

    static func params(_ edits: PitchEditSet) -> StretchRenderCache.Params {
        StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false, pitchEdits: edits)
    }

    static func keys(_ edits: PitchEditSet, source: URL,
                     separator: PitchCorrectionCurve.Separator = .production) throws
        -> StretchRenderCache.RenderKeys {
        try StretchRenderCache.renderKeys(source: source, params: params(edits), detector: .product,
                                          separator: separator)
    }

    /// The resolved key, restated field by field with a LITERAL shaping field,
    /// so a global bump of the constant cannot hide behind the formula.
    static func restated(_ edits: PitchEditSet, source: URL, shaping: String) throws -> String {
        var fields = try StretchRenderCache.sourceIdentityFields(source: source)
        fields += [String(1.0.bitPattern), String(0.0.bitPattern), "0",
                   String(StretchRenderCache.stretchEngineVersion),
                   "pitch:" + PitchEditSetDigest.hex(edits),
                   "pv:\(StretchRenderCache.transposeEngineVersion)"]
        if StretchCurvePlan.consonantMixActive(params(edits)) {
            fields.append("consonantMix:\(StretchRenderCache.consonantMixVersion)")
        }
        fields.append("contour:" + (try PitchContourCache.key(source: source, detector: .product)))
        fields.append(shaping)
        return StretchRenderCache.keyDigest(fields)
    }

    static let hardTune = ContourToRenderTests.hardTuneSet()
    static let half = set(drift: 0.5, vibrato: 0.5, id: "C3000000-0000-4000-8000-000000000055")
    static let driftOnly = set(drift: 0, vibrato: 1, id: "C3000000-0000-4000-8000-000000000001")
    static let wobbleOnly = set(drift: 1, vibrato: 0, id: "C3000000-0000-4000-8000-000000000001")

    // MARK: - Equal scales keep their keys

    @Test("G2 a Hard Tune set's key is its pre-change golden (shaping:1), resolved and fallback")
    func hardTuneKeyIsItsPreChangeGolden() throws {
        let source = try Self.goldenSource()
        #expect(source.standardizedFileURL.path == Self.capturedSourcePath,
                "the goldens were captured for another temporaryDirectory (machine or account): re-capture them here")
        let keys = try Self.keys(Self.hardTune, source: source)
        Self.log("hardTune resolved \(keys.resolved) legacy \(keys.legacy)")
        #expect(PitchRenderContour.shapingVersion(for: Self.hardTune) == 1)
        #expect(keys.resolved == Self.hardTuneResolvedGolden,
                "the Hard Tune render re-keyed: every cached Hard Tune render on every disk would re-render")
        #expect(keys.legacy == Self.hardTuneLegacyGolden)
        #expect(keys.resolved == (try Self.restated(Self.hardTune, source: source, shaping: "shaping:1")))
    }

    @Test("G2 every equal-scale set keys shaping:1 (0.5/0.5 golden; 1.7/1.7 and a mixed-equal set restated)")
    func equalScaleSetsKeyVersionOne() throws {
        let source = try Self.goldenSource()
        #expect(try Self.keys(Self.half, source: source).resolved == Self.equalHalfResolvedGolden)
        let equalSets = [
            Self.set(drift: 1.7, vibrato: 1.7, id: "C3000000-0000-4000-8000-000000000017"),
            PitchEditSet(segments: [
                Self.note(drift: 0, vibrato: 0, id: "C3000000-0000-4000-8000-0000000000A1", start: 0.05, end: 0.2),
                Self.note(drift: 0.5, vibrato: 0.5, id: "C3000000-0000-4000-8000-0000000000A2", start: 0.2, end: 0.35),
                Self.note(drift: 1, vibrato: 1, id: "C3000000-0000-4000-8000-0000000000A3", start: 0.35, end: 0.45),
            ], retuneMs: 30),
        ]
        for edits in equalSets {
            #expect(!edits.needsSeparatedShaping)
            #expect(try Self.keys(edits, source: source).resolved
                    == (try Self.restated(edits, source: source, shaping: "shaping:1")))
        }
    }

    // MARK: - Unequal scales key version 2

    @Test("G2 an unequal (0/1) set keys shaping:2 and re-keys; its fallback key does not move")
    func unequalSetKeysVersionTwo() throws {
        let source = try Self.goldenSource()
        let keys = try Self.keys(Self.driftOnly, source: source)
        Self.log("driftOnly resolved \(keys.resolved) legacy \(keys.legacy)")
        #expect(PitchRenderContour.shapingVersion(for: Self.driftOnly) == 2)
        #expect(keys.resolved == (try Self.restated(Self.driftOnly, source: source, shaping: "shaping:2")))
        #expect(keys.resolved != (try Self.restated(Self.driftOnly, source: source, shaping: "shaping:1")))
        #expect(keys.resolved != Self.unequalPreChangeResolved,
                "an unequal-scale set kept its pre-v2 key: the v1 render would be served as the fix")
        #expect(keys.legacy == Self.unequalLegacyGolden,
                "the constant-offset FALLBACK key moved; it holds no shaping and must not")
    }

    @Test("G2 one unequal note among equal ones keys the whole set shaping:2")
    func oneUnequalNoteKeysTheSetVersionTwo() throws {
        let source = try Self.goldenSource()
        let mixed = PitchEditSet(segments: [
            Self.note(drift: 0, vibrato: 0, id: "C3000000-0000-4000-8000-0000000000B1", start: 0.05, end: 0.2),
            Self.note(drift: 0, vibrato: 1, id: "C3000000-0000-4000-8000-0000000000B2", start: 0.2, end: 0.35),
            Self.note(drift: 0.5, vibrato: 0.5, id: "C3000000-0000-4000-8000-0000000000B3", start: 0.35, end: 0.45),
        ], retuneMs: 30)
        #expect(mixed.needsSeparatedShaping)
        #expect(try Self.keys(mixed, source: source).resolved
                == (try Self.restated(mixed, source: source, shaping: "shaping:2")))
    }

    @Test("G2 0/1 and 1/0 share version 2 and are told apart by the edit digest")
    func driftOnlyAndWobbleOnlyDifferByDigest() throws {
        let source = try Self.goldenSource()
        #expect(PitchRenderContour.shapingVersion(for: Self.wobbleOnly) == 2)
        let a = try Self.keys(Self.driftOnly, source: source)
        let b = try Self.keys(Self.wobbleOnly, source: source)
        #expect(a.resolved != b.resolved)
        #expect(PitchEditSetDigest.hex(Self.driftOnly) != PitchEditSetDigest.hex(Self.wobbleOnly),
                "the digest does not separate the two scales; only the key's version would")
        #expect(b.resolved == (try Self.restated(Self.wobbleOnly, source: source, shaping: "shaping:2")))
    }

    // MARK: - The test seam never reaches a production key

    @Test("G2 a non-production separator (G3's test seam) keys apart from production; production adds nothing")
    func testSeparatorsNeverShareAProductionKey() throws {
        let source = try Self.goldenSource()
        let production = try Self.keys(Self.driftOnly, source: source)
        var seen: Set<String> = [production.resolved]
        for separator: PitchCorrectionCurve.Separator in [
            .v1Everywhere, .triangular(windowSeconds: 0.2, edge: .reflect), .kernelTaps([0.25, 0.5, 0.25]),
        ] {
            let keys = try Self.keys(Self.driftOnly, source: source, separator: separator)
            #expect(keys.legacy == production.legacy, "\(separator) moved the fallback key")
            #expect(seen.insert(keys.resolved).inserted, "\(separator) shares a resolved key")
        }
        // Production appends no separator field: the Hard Tune golden above is
        // the proof, and so is this restatement.
        #expect(production.resolved == (try Self.restated(Self.driftOnly, source: source, shaping: "shaping:2")))
    }
}
