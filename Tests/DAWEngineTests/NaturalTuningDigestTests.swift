import CryptoKit
import DAWAppKit
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// Natural tuning §1(d), §1(g) G8, X1 (lane NT-E1): **DIGEST SLOT 7, THE
/// FORMANT BLOCK, AND THE SET-LEVEL CENSUS.**
///
/// Every claim is proven against an INDEPENDENT restatement of the digest's
/// layout, the one `PitchCurveRenderTests` (8)-(10) already validates against
/// hexes captured before C2, I7a and U-A existed (`c21PreC2Material` and the
/// three block restatements are reused, not re-derived, so there is one
/// restatement to trust). The formant block is restated here with its marker
/// as a LITERAL: changing the marker would silently re-key every engaged set.
///
/// Deliberately NOT `@MainActor` (digest arithmetic; `MainActorOccupancySiteTests`
/// Leg C caps `@MainActor` suites).
@Suite("Natural tuning §1 — digest slot 7 and the set-level census (NT-E1)")
struct NaturalTuningDigestTests {
    typealias Legacy = PitchCurveRenderTests

    /// The block §1(d) specifies, restated: the marker ("F1ORMAN" + 01, a
    /// literal), the render version, ONE byte for "an amount is set", then the
    /// amount (0 when nil). `version` is a parameter so a bump can be proven
    /// to re-key without editing DAWCore.
    static func formantBlock(_ set: PitchEditSet,
                             version: Int = PitchEditSet.formantRenderVersion) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: UInt64(0x4631_4F52_4D41_4E01).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        withUnsafeBytes(of: UInt64(bitPattern: Int64(version)).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        bytes.append(set.formantCorrection != nil ? 1 : 0)
        withUnsafeBytes(of: (set.formantCorrection ?? 0).bitPattern.littleEndian) {
            bytes.append(contentsOf: $0)
        }
        return bytes
    }

    static func sha(_ bytes: [UInt8]) -> String { Legacy.c21SHA(bytes) }

    /// `set`'s pre-§1 material (inline + generator block) plus every OTHER
    /// block it carries, in slot order, each by the restatement that already
    /// reproduces captured hexes. Slot 7 is appended by the caller.
    static func materialBeforeSlot7(_ set: PitchEditSet) -> [UInt8] {
        var bytes = Legacy.c21PreC2Material(set)
        if set.hasTimeEdits { bytes += Legacy.c21WarpBlock() }
        if set.hasLevelEdits { bytes += Legacy.i7aLevelBlock(set) }
        if set.segments.contains(where: { $0.origin != .detected }) {
            bytes += Legacy.uaOriginBlock(set)
        }
        return bytes
    }

    static func withAmount(_ set: PitchEditSet, _ amount: Double?) -> PitchEditSet {
        var copy = set
        copy.formantCorrection = amount
        return copy
    }

    /// The restatement is trusted only after (a) its pre-C2 half reproduces
    /// the hexes CAPTURED before C2 (every legacy and every timed golden) and
    /// (b) the production digest of each of those sets equals it today.
    static func assertRestatementReproducesCaptures() {
        for golden in Legacy.c21LegacyDigestGoldens + Legacy.c21PreC2TimedHex {
            let set = Legacy.c21Set(golden.set)
            #expect(sha(Legacy.c21PreC2Material(set)) == golden.hex,
                    "the restatement does not reproduce the capture of '\(golden.set)'")
            #expect(PitchEditSetDigest.hex(set) == sha(materialBeforeSlot7(set)),
                    "'\(golden.set)' no longer digests as its pre-§1 blocks")
        }
    }

    // MARK: - G8 (a): legacy sets keep their keys

    /// ⭐ THE LEGACY GATE. A set with no amount and every offset 0 does not
    /// engage, emits no slot 7 and keeps the key it had before §1: the C2-1
    /// goldens, captured before C2, and the §A goldens of the vibrato suite.
    @Test("G8 legacy sets (no amount, no offset) keep their pre-§1 digests, and emit no slot 7")
    func legacySetsKeepTheirKeys() {
        Self.assertRestatementReproducesCaptures()
        #expect(PitchEditSetDigest.formantSuffixMarker == 0x4631_4F52_4D41_4E01)
        // 1 → 2 by NT-E1b, on purpose: the render now reads the curve
        // (`versionTwoRekeysTheCacheKey`). 2 → 3 by NT-F220, on purpose: the
        // library's envelope under an explicit base (vendored patch 0004).
        #expect(PitchEditSet.formantRenderVersion == 3,
                "a version bump re-keys every engaged render: make it on purpose, then move this pin")
        for golden in Legacy.c21LegacyDigestGoldens {
            let set = Legacy.c21Set(golden.set)
            #expect(set.formantCorrection == nil && !set.engagesFormantCurve)
            #expect(PitchEditSetDigest.hex(set) == golden.hex,
                    "the legacy '\(golden.set)' set MOVED: every cache entry for it is orphaned")
        }
        #expect(Legacy.c21LegacyDigestGoldens[0].hex == NoteVibratoGeneratorTests.goldenDigestOffset)
        #expect(Legacy.c21LegacyDigestGoldens[1].hex == NoteVibratoGeneratorTests.goldenDigestShaping)
    }

    // MARK: - G8 (b): an amount re-keys by exactly slot 7

    @Test("G8 an amount re-keys by EXACTLY the formant block; nil, 0.0, 0.5 and 1.0 are four keys")
    func amountRekeysByExactlyTheBlock() {
        Self.assertRestatementReproducesCaptures()
        let legacy = Legacy.c21Set("offset")
        var hexes: Set<String> = [PitchEditSetDigest.hex(legacy)]
        for amount in [0.0, 0.5, 1.0] {
            let set = Self.withAmount(legacy, amount)
            #expect(set.engagesFormantCurve)
            let hex = PitchEditSetDigest.hex(set)
            #expect(hex == Self.sha(Self.materialBeforeSlot7(set) + Self.formantBlock(set)),
                    "amount \(amount) re-keyed, but not by exactly the formant block")
            hexes.insert(hex)
        }
        #expect(hexes.count == 4, "nil, 0.0, 0.5 and 1.0 must be four keys: 0.0 is NOT legacy")
        // Restore is exact: nil again is the legacy key, bit for bit.
        #expect(PitchEditSetDigest.hex(Self.withAmount(Self.withAmount(legacy, 1), nil))
                == Legacy.c21LegacyDigestGoldens[0].hex)
    }

    /// Slot order: generator (inside the material), time warp (3), level (5),
    /// origin (6), then formant (7). A block out of its slot re-keys every set
    /// that uses two features (the banner's rule).
    @Test("G8 the formant block sits in slot 7, after the time-warp, level and origin blocks")
    func formantBlockIsInSlotSeven() {
        var everything = Legacy.c21Set("generator")
        everything.segments[1].timeStartDeltaSeconds = 0.02
        everything.segments[0].isCleared = true
        everything.segments.append(NoteSegment(
            id: Legacy.uaIdSoundLong, startSeconds: 1.95, endSeconds: 2.2, detectedHz: 220,
            detectedConfidence: 0.4, pitchOffsetCents: 300, origin: .unpitched))
        everything.formantCorrection = 0.75
        #expect(everything.hasTimeEdits && everything.hasLevelEdits && everything.engagesFormantCurve)
        #expect(PitchEditSetDigest.hex(everything)
                == Self.sha(Legacy.c21PreC2Material(everything) + Legacy.c21WarpBlock()
                            + Legacy.i7aLevelBlock(everything) + Legacy.uaOriginBlock(everything)
                            + Self.formantBlock(everything)),
                "the formant block is not in slot 7, after slots 3, 5 and 6")
    }

    /// §1(c) row 2, the F7 hazard closed: before §1 a hand-authored offset was
    /// hashed INLINE but IGNORED by the render, so its old key holds unshaped
    /// audio. Engaging must re-key it, by exactly the block with the nil byte.
    /// An offset on an UNTOUCHED SOUND does not engage (C1's ruling), so it
    /// gets no block.
    @Test("G8 a hand-authored offset re-keys (nil amount); an untouched sound's offset does not engage")
    func handAuthoredOffsetRekeys() {
        var offset = Legacy.c21Set("offset")
        offset.segments[0].formantOffsetSemitones = -2
        #expect(offset.formantCorrection == nil && offset.engagesFormantCurve)
        let preSection1Key = Self.sha(Self.materialBeforeSlot7(offset))
        #expect(PitchEditSetDigest.hex(offset) != preSection1Key,
                "a hand-authored offset kept the key its IGNORED render was cached under")
        #expect(PitchEditSetDigest.hex(offset)
                == Self.sha(Self.materialBeforeSlot7(offset) + Self.formantBlock(offset)))

        var sound = Legacy.c21Set("offset")
        sound.segments.append(NoteSegment(
            id: Legacy.uaIdSoundLong, startSeconds: 1.95, endSeconds: 2.2, detectedHz: 220,
            detectedConfidence: 0.4, formantOffsetSemitones: -2, origin: .unpitched))
        #expect(!sound.engagesFormantCurve)
        #expect(PitchEditSetDigest.hex(sound) == Self.sha(Self.materialBeforeSlot7(sound)),
                "an untouched sound's offset emitted a formant block for a value nothing applies")
    }

    /// "Slot 7 is emitted iff the set engages AND is non-identity": `hex`
    /// returns "" for an identity set BEFORE any block, so an amount on a set
    /// with no moved note renders nothing new and keys nothing new. A set that
    /// is non-identity only through a level still carries the amount's block.
    @Test("G8 an amount on an identity set digests to \"\"; on a level-only set it is keyed")
    func identityBeatsSlotSeven() {
        let detected = PitchEditSet(segments: [
            NoteSegment(id: Legacy.c21IdA, startSeconds: 0, endSeconds: 1, detectedHz: 220,
                        detectedConfidence: 0.9)
        ], formantCorrection: 1)
        #expect(detected.engagesFormantCurve && detected.isIdentity)
        #expect(PitchEditSetDigest.hex(detected).isEmpty)
        var levelled = detected
        levelled.segments[0].amplitudeDb = -6
        #expect(PitchEditSetDigest.hex(levelled)
                == Self.sha(Self.materialBeforeSlot7(levelled) + Self.formantBlock(levelled)))
    }

    /// A `formantRenderVersion` bump re-keys ENGAGED sets and no other: the
    /// version is inside the block, and a legacy set has no block.
    @Test("G8 a formantRenderVersion bump re-keys engaged sets only")
    func versionBumpRekeysEngagedOnly() {
        let engaged = Self.withAmount(Legacy.c21Set("offset"), 1)
        let hex = PitchEditSetDigest.hex(engaged)
        let material = Self.materialBeforeSlot7(engaged)
        let v = PitchEditSet.formantRenderVersion
        #expect(hex == Self.sha(material + Self.formantBlock(engaged, version: v)))
        #expect(hex != Self.sha(material + Self.formantBlock(engaged, version: v + 1)),
                "the version is not in the engaged key: a bump would serve stale audio")
        for golden in Legacy.c21LegacyDigestGoldens {
            let set = Legacy.c21Set(golden.set)
            // No block, so no version: the legacy key is the material alone.
            #expect(PitchEditSetDigest.hex(set) == Self.sha(Self.materialBeforeSlot7(set)))
        }
    }

    /// ⭐ **G9 SHAPE, THROUGH THE REAL CACHE KEY (NT-E1b).** Version 2 lands in
    /// the SAME build that makes `StretchRenderCache.renderAudio` read the
    /// formant curve: every render cached under version 1 holds UN-shaped
    /// audio under an engaged key. Through `StretchRenderCache.renderKeys`
    /// (its `pitch:` field is the digest), the `TransposeFractionalReadTests
    /// .scopedRekey` shape, with the field list restated:
    ///  * an ENGAGED set (amount 1, amount 0, a hand-authored offset with
    ///    amount nil; clip flag off and on) has the version-2 key and NOT the
    ///    version-1 key it had before (the block restated at each version,
    ///    the restatement trusted by `assertRestatementReproducesCaptures`);
    ///  * a LEGACY set (amount nil, every offset 0) keeps its key byte for
    ///    byte: the fields around the digest CAPTURED BEFORE C2
    ///    (`c21LegacyDigestGoldens`).
    ///
    /// NT-F220 (version 3, vendored patch 0004) generalised the shape: the key
    /// is the CURRENT version's and none of the older ones', so the next bump
    /// needs no edit here (the pin in `legacySetsKeepTheirKeys` still does).
    @Test("G9 formantRenderVersion re-keys every engaged set's cache key off every older version's key; legacy keys do not move")
    func versionTwoRekeysTheCacheKey() throws {
        Self.assertRestatementReproducesCaptures()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nt-e1b-g9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("take.wav")
        // The key reads only the file's identity (path, size, mtime).
        try Data(repeating: 7, count: 256).write(to: source)

        /// `renderKeys`' legacy field list, restated, around a given digest.
        func legacyKey(_ params: StretchRenderCache.Params, digest: String) throws -> String {
            var fields = try StretchRenderCache.sourceIdentityFields(source: source)
            fields += [String(params.ratio.bitPattern), String(params.semitones.bitPattern),
                       params.formantPreserve ? "1" : "0",
                       String(StretchRenderCache.stretchEngineVersion),
                       "pitch:" + digest, "pv:\(StretchRenderCache.transposeEngineVersion)"]
            return StretchRenderCache.keyDigest(fields)
        }
        func keys(_ params: StretchRenderCache.Params) throws -> StretchRenderCache.RenderKeys {
            try StretchRenderCache.renderKeys(source: source, params: params, detector: .product)
        }

        var offset = Legacy.c21Set("offset")
        offset.segments[0].formantOffsetSemitones = -2
        let engaged: [(String, PitchEditSet)] = [
            ("amount 1", Self.withAmount(Legacy.c21Set("offset"), 1)),
            ("amount 0", Self.withAmount(Legacy.c21Set("offset"), 0)),
            ("a hand-authored offset, amount nil", offset),
        ]
        for (label, set) in engaged {
            #expect(set.engagesFormantCurve, "\(label): fixture")
            let material = Self.materialBeforeSlot7(set)
            for flag in [false, true] {
                let params = StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: flag,
                                                       pitchEdits: set)
                let key = try keys(params)
                let current = PitchEditSet.formantRenderVersion
                let now = try legacyKey(params, digest: Self.sha(material + Self.formantBlock(set, version: current)))
                #expect(!params.shapesAgainstContour(.product) && key.resolved == key.legacy,
                        "\(label): fixture shapes against a contour, so its resolved key is another derivation")
                #expect(key.resolved == now, "\(label), flag \(flag): the cache key is not the version-\(current) key")
                #expect(current >= 3, "control: the loop below must see at least versions 1 and 2")
                for old in 1..<current {
                    let stale = try legacyKey(params, digest: Self.sha(material + Self.formantBlock(set, version: old)))
                    #expect(key.resolved != stale,
                            "\(label), flag \(flag): the cache key is still the version-\(old) key, which holds audio this build does not make (1: UN-shaped; 2: the old envelope)")
                }
            }
        }
        for golden in Legacy.c21LegacyDigestGoldens {
            let set = Legacy.c21Set(golden.set)
            #expect(set.formantCorrection == nil && !set.engagesFormantCurve)
            for flag in [false, true] {
                let params = StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: flag,
                                                       pitchEdits: set)
                #expect(try keys(params).legacy == legacyKey(params, digest: golden.hex),
                        "the legacy '\(golden.set)' cache key MOVED (flag \(flag)): its cached render is orphaned")
            }
        }
    }

    /// 0.0 is an ENGAGED amount (§1(b)): it must survive a save and reopen as
    /// 0.0, not as nil, and keep its key. The digest can tell the two apart
    /// (the control), so a round trip that flipped it would re-key.
    @Test("G8 0.0 round-trips as 0.0 and keeps its key; nil round-trips as nil")
    func zeroAmountRoundTrips() throws {
        let base = Legacy.c21Set("offset")
        #expect(PitchEditSetDigest.hex(Self.withAmount(base, 0))
                != PitchEditSetDigest.hex(Self.withAmount(base, nil)),
                "control: the digest cannot tell 0.0 from nil, so this round trip proves nothing")
        for amount in [0.0, nil, 1.0] as [Double?] {
            let set = Self.withAmount(base, amount)
            let data = try JSONEncoder().encode(set)
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(json.contains("formantCorrection") == (amount != nil),
                    "amount \(String(describing: amount)) encoded as \(json)")
            let back = try JSONDecoder().decode(PitchEditSet.self, from: data)
            #expect(back.formantCorrection?.bitPattern == amount?.bitPattern)
            #expect(PitchEditSetDigest.hex(back) == PitchEditSetDigest.hex(set))
        }
    }

    // MARK: - The set-level census (X1, G8)

    /// Every SET-level stored property of `PitchEditSet`, by name, in one of
    /// three lists. A test cannot read `hex`'s body, so each HASHED name has a
    /// mutation row that must move the digest, each EXEMPT name one that must
    /// not, and each PENDING name one that must not YET: the day its slot
    /// lands, that row turns red and the name moves to `hashed`.
    /// `transitionSlopeCentsPerSecond` moved here from `pending` when NT-C C4
    /// landed slot 9 (its row below turned red, as designed); slot 9's own
    /// block tests are `NaturalTuningTransitionRenderTests`.
    /// `keepsConsonantsUntuned` moved here from `pending` when NT-C C2 landed
    /// slot 8 (its row turned red, as designed); slot 8's own block tests are
    /// `NaturalTuningConsonantDigestTests` below. NT-C2-F1 (W7-D2) made the
    /// consonant field's STORED state `consonantProtection` (`.offByDefault`,
    /// `.on`, `.offByChoice`), so that is the name Mirror lists now;
    /// `keepsConsonantsUntuned` is its computed on/off reading, and that
    /// reading is the ONE thing slot 8 hashes.
    ///
    /// ⚠️ **HASHED THROUGH ITS ON/OFF READING ONLY, ON PURPOSE.** An OFF nobody
    /// chose (`.offByDefault`) and an OFF somebody chose (`.offByChoice`) both
    /// render with the consonant mix off, so they key alike. The choice is a
    /// record the next preset run reads, not render material: the
    /// `autoCorrectStamp` precedent, for one case of a hashed field. The census
    /// proves both halves: the `consonantProtection` row (off by default to ON)
    /// must re-key, and the record checks after the loops must not.
    /// `ConsonantChoiceDigestTests` pins the same against digests captured
    /// before the record existed.
    static let hashed = ["analysisVersion", "segments", "retuneMs", "formantCorrection",
                         "transitionSlopeCentsPerSecond", "consonantProtection"]
    /// `autoCorrectStamp`: provenance, not render material (its own doc,
    /// PitchCorrection.swift, "DELIBERATELY ABSENT FROM `PitchEditSetDigest.hex`").
    static let exempt = ["autoCorrectStamp", "autoCorrectReplaceableStamp"]
    /// A field that exists but whose digest slot has not landed. Empty since
    /// NT-C C2; the mechanism stays for the next set-level field.
    static let pending: [String] = []
    /// vf-18 (W9-SLFX): hashed only where it can render, inside slot 9 (a SOFT
    /// set, `usesSoftJoins`). Its row must NOT re-key the census's non-soft
    /// base and MUST re-key the same base made soft.
    static let hashedWhenSoft = ["slideFollowRule"]

    @Test("G8 census: every set-level field is hashed, exempt, or pending with its owner named")
    func setLevelCensus() {
        let fields = Mirror(reflecting: PitchEditSet.empty).children.compactMap(\.label)
        let listed = Self.hashed + Self.exempt + Self.pending + Self.hashedWhenSoft
        #expect(Set(fields) == Set(listed) && fields.count == listed.count,
                """
                PitchEditSet's set-level fields \(fields) are not exactly the census \
                \(listed). A new field must be hashed in its digest slot (with a \
                mutation row below) or exempted here ON PURPOSE: an unhashed render \
                input is stale audio nobody can explain.
                """)

        // A non-identity base, so `hex` is not "" and every row can move it.
        let base = Self.withAmount(Legacy.c21Set("offset"), 0.5)
        let baseHex = PitchEditSetDigest.hex(base)
        func rekeys(_ mutate: (inout PitchEditSet) -> Void) -> Bool {
            var copy = base
            mutate(&copy)
            return PitchEditSetDigest.hex(copy) != baseHex
        }
        let rows: [String: (inout PitchEditSet) -> Void] = [
            "analysisVersion": { $0.analysisVersion += 1 },
            "segments": { $0.segments[1].pitchOffsetCents += 1 },
            "retuneMs": { $0.retuneMs = 90 },
            "formantCorrection": { $0.formantCorrection = 0.25 },
            "autoCorrectStamp": { $0.autoCorrectStamp = "stamp" },
            "autoCorrectReplaceableStamp": { $0.autoCorrectReplaceableStamp = "stamp" },
            "consonantProtection": { $0.consonantProtection = .on },
            "transitionSlopeCentsPerSecond": { $0.transitionSlopeCentsPerSecond = 3000 },
            "slideFollowRule": { $0.slideFollowRule = .holdAtOpenSide },
        ]
        #expect(Set(rows.keys) == Set(listed), "every listed name needs a mutation row")
        for name in Self.hashed {
            #expect(rows[name].map(rekeys) == true, "'\(name)' is listed as hashed and does not re-key")
        }
        for name in Self.exempt {
            #expect(rows[name].map(rekeys) == false, "'\(name)' is exempt and re-keys")
        }
        for name in Self.pending {
            #expect(rows[name].map(rekeys) == false,
                    """
                    '\(name)' re-keys: its digest slot has landed. Move it to `hashed` \
                    (and its owner's block test is what proves the slot).
                    """)
        }
        // vf-18: the base is not soft, so a slide-follow rule renders nothing
        // there and must not re-key it; the same base made soft must re-key.
        #expect(!base.usesSoftJoins, "premise: the census base is not soft")
        var softBase = base
        softBase.transitionSlopeCentsPerSecond = PitchEditSet.defaultTransitionSlope
        let softBaseHex = PitchEditSetDigest.hex(softBase)
        for name in Self.hashedWhenSoft {
            #expect(rows[name].map(rekeys) == false, "'\(name)' re-keys a set that is not soft")
            var copy = softBase
            rows[name]?(&copy)
            #expect(PitchEditSetDigest.hex(copy) != softBaseHex, "'\(name)' does not re-key a soft set")
        }

        // NT-C2-F1 (W7-D2): `consonantProtection`'s RECORD half must NOT re-key
        // (see `hashed`). The base is a legacy set, so its consonants are off
        // BY DEFAULT; the row above re-keyed it by switching them ON. Here
        // only the record moves: nobody-chose to somebody-chose, and ON to
        // each of the two OFF states.
        #expect(base.consonantProtection == .offByDefault,
                "premise: the census base is a legacy set, off by default")
        #expect(rekeys({ $0.consonantProtection = .offByChoice }) == false,
                "an OFF somebody chose re-keys against an OFF nobody chose: the record reached the digest")
        var consonantsOn = base
        consonantsOn.consonantProtection = .on
        var offByChoice = consonantsOn
        offByChoice.consonantProtection = .offByChoice
        var offByDefault = consonantsOn
        offByDefault.consonantProtection = .offByDefault
        let offByChoiceHex = PitchEditSetDigest.hex(offByChoice)
        #expect(offByChoiceHex == PitchEditSetDigest.hex(offByDefault),
                "switched off from ON, the two OFF states key differently: the record is render material")
        #expect(offByChoiceHex != PitchEditSetDigest.hex(consonantsOn),
                "switching consonants OFF by choice does not re-key: slot 8 stopped reading the flag")
    }
}

// MARK: - Natural tuning §2 (NT-C C2): digest slot 8, the consonant block

/// Natural tuning §2d, §2g G-C7a/b/c, X1 (lane NT-C C2): **DIGEST SLOT 8, THE
/// CONSONANT BLOCK.** Proven like slot 7 above: against the independent
/// restatement (`NaturalTuningDigestTests.materialBeforeSlot7`, trusted only
/// after it reproduces the captures taken before C2) AND against hexes this
/// lane CAPTURED ON THE TREE BEFORE SLOT 8 EXISTED (`capturedBeforeSlot8`).
///
/// Deliberately NOT `@MainActor` (digest arithmetic; `MainActorOccupancySiteTests`
/// Leg C caps `@MainActor` suites).
@Suite("Natural tuning §2 — digest slot 8, the consonant block (NT-C C2)")
struct NaturalTuningConsonantDigestTests {
    typealias Legacy = PitchCurveRenderTests

    static let idA = UUID(uuidString: "C2000000-0000-4000-8000-00000000000A")!
    static let idB = UUID(uuidString: "C2000000-0000-4000-8000-00000000000B")!
    static let idC = UUID(uuidString: "C2000000-0000-4000-8000-00000000000C")!
    static let idD = UUID(uuidString: "C2000000-0000-4000-8000-00000000000D")!
    static let idS = UUID(uuidString: "C2000000-0000-4000-8000-00000000005D")!

    static func withConsonants(_ set: PitchEditSet, _ on: Bool) -> PitchEditSet {
        var copy = set
        copy.keepsConsonantsUntuned = on
        return copy
    }

    /// A table shaped like a NEW set after one edit: the seed's three
    /// set-level values (formant 1.0, slope 3000, consonants on), a moved
    /// note, a sung slide that follows, a levelled note, an untouched SOUND
    /// between notes and a second moved note. It carries slots 5, 6, 7 and 9,
    /// so slot 8 has a neighbour on both sides.
    static func richSet(consonants: Bool) -> PitchEditSet {
        PitchEditSet(analysisVersion: 1, segments: [
            NoteSegment(id: idA, startSeconds: 0.20, endSeconds: 0.80, detectedHz: 220,
                        detectedConfidence: 0.9, pitchOffsetCents: 300),
            NoteSegment(id: idB, startSeconds: 0.80, endSeconds: 1.00, detectedHz: 240,
                        detectedConfidence: 0.9, glideFollow: 1, origin: .transition),
            NoteSegment(id: idC, startSeconds: 1.00, endSeconds: 1.50, detectedHz: 262,
                        detectedConfidence: 0.9, amplitudeDb: -3),
            NoteSegment(id: idS, startSeconds: 1.50, endSeconds: 1.70, detectedHz: 262,
                        detectedConfidence: 0.4, origin: .unpitched),
            NoteSegment(id: idD, startSeconds: 1.70, endSeconds: 2.40, detectedHz: 196,
                        detectedConfidence: 0.9, pitchOffsetCents: -150),
        ], retuneMs: 45, formantCorrection: 1.0, keepsConsonantsUntuned: consonants,
           transitionSlopeCentsPerSecond: 3000)
    }

    /// Detected notes nobody moved, one of them levelled: `isPitchIdentity`
    /// but not `isIdentity`, so it digests (slot 5) and never runs the mix.
    static func levelOnlySet(consonants: Bool) -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(id: idA, startSeconds: 0.2, endSeconds: 0.8, detectedHz: 220,
                        detectedConfidence: 0.9, amplitudeDb: -6),
            NoteSegment(id: idB, startSeconds: 1.0, endSeconds: 1.6, detectedHz: 247,
                        detectedConfidence: 0.9),
        ], keepsConsonantsUntuned: consonants)
    }

    /// Detected notes nobody touched: identity, digest "".
    static func identitySet(consonants: Bool) -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(id: idA, startSeconds: 0.2, endSeconds: 0.8, detectedHz: 220,
                        detectedConfidence: 0.9),
            NoteSegment(id: idS, startSeconds: 0.8, endSeconds: 1.0, detectedHz: 220,
                        detectedConfidence: 0.4, origin: .unpitched),
            NoteSegment(id: idB, startSeconds: 1.0, endSeconds: 1.6, detectedHz: 247,
                        detectedConfidence: 0.9),
        ], keepsConsonantsUntuned: consonants)
    }

    /// Every set the slot-8 gates read, by name, flag off AND on. The c21
    /// sets are the ones whose flag-off keys were captured before C2
    /// (`c21LegacyDigestGoldens`, `c21PreC2TimedHex`).
    static func battery() -> [(name: String, set: PitchEditSet)] {
        var out: [(name: String, set: PitchEditSet)] = []
        for name in ["offset", "shaping", "generator", "delta", "timingOnly", "startDelta"] {
            out.append(("c21 \(name) off", withConsonants(Legacy.c21Set(name), false)))
            out.append(("c21 \(name) on", withConsonants(Legacy.c21Set(name), true)))
        }
        for name in NaturalTuningTransitionRenderTests.legacyJoinSetNames {
            var soft = NaturalTuningTransitionRenderTests.legacyJoinSet(name)
            soft.transitionSlopeCentsPerSecond = PitchEditSet.defaultTransitionSlope
            out.append(("soft \(name) off", withConsonants(soft, false)))
            out.append(("soft \(name) on", withConsonants(soft, true)))
        }
        out.append(("rich off", richSet(consonants: false)))
        out.append(("rich on", richSet(consonants: true)))
        out.append(("levelOnly off", levelOnlySet(consonants: false)))
        out.append(("levelOnly on", levelOnlySet(consonants: true)))
        out.append(("identity off", identitySet(consonants: false)))
        out.append(("identity on", identitySet(consonants: true)))
        return out
    }

    /// ⭐ CAPTURED ON THE TREE BEFORE SLOT 8 EXISTED (2026-09-25 23:42, NT-C
    /// C2): a capture-only test printed `PitchEditSetDigest.hex` of each
    /// `battery()` set, on the tree with slots 7 and 9 landed and no slot 8
    /// (`scratchpad/w6/NTC2/logs/capture-1.log`). Positive control on the
    /// harness: its three c21 flag-off hexes ARE `c21LegacyDigestGoldens`.
    /// Every flag-on hex equals its flag-off twin: the flag was not hashed,
    /// which is the stale-key hazard slot 8 closes. ⛔ FROZEN: never
    /// regenerate from the current code, or the gate compares it with itself.
    static let capturedBeforeSlot8: [String: String] = [
        "c21 offset off": "ec8e1bd8e04e4d8a6861e27ed620ff5772422fee40b8c6fd886e9e712ca77f6a",
        "c21 offset on": "ec8e1bd8e04e4d8a6861e27ed620ff5772422fee40b8c6fd886e9e712ca77f6a",
        "c21 shaping off": "1102f9a9e5bc74e92a449ed9a4a9ee28fe93915fd7e43922ce38bc2318c84a8a",
        "c21 shaping on": "1102f9a9e5bc74e92a449ed9a4a9ee28fe93915fd7e43922ce38bc2318c84a8a",
        "c21 generator off": "1931c6528936e6b607f282d24c1a30dcabefc0f1add0d106bf84e4086d279a7b",
        "c21 generator on": "1931c6528936e6b607f282d24c1a30dcabefc0f1add0d106bf84e4086d279a7b",
        "c21 delta off": "6a0016592a4e5d96751c609d211328a73c1955bc1ba4cc7b0ee99541133aea63",
        "c21 delta on": "6a0016592a4e5d96751c609d211328a73c1955bc1ba4cc7b0ee99541133aea63",
        "c21 timingOnly off": "83010be5c4095e45873596e3551b58d74782a2706ad78dc52cdaefe5b80ea2a2",
        "c21 timingOnly on": "83010be5c4095e45873596e3551b58d74782a2706ad78dc52cdaefe5b80ea2a2",
        "c21 startDelta off": "5b179f90da5ef172f9c311b657869daf0262d88d82fcb2b821eab3b01d36b952",
        "c21 startDelta on": "5b179f90da5ef172f9c311b657869daf0262d88d82fcb2b821eab3b01d36b952",
        "soft bigJump off": "4b002e77ee3c2b627f26f3ed4da06f702c3c63c1bd680fac9effef7e05585df6",
        "soft bigJump on": "4b002e77ee3c2b627f26f3ed4da06f702c3c63c1bd680fac9effef7e05585df6",
        "soft shortNeighbour off": "1ad42ff0c097988114900943f13c5eb0c5f17152fae968ffe6f535c25bb4b644",
        "soft shortNeighbour on": "1ad42ff0c097988114900943f13c5eb0c5f17152fae968ffe6f535c25bb4b644",
        "soft shortHole off": "48be80d1ce7b184b7ea9ba284a75f98cef2847e90d49b0839405a8a4de9c0be9",
        "soft shortHole on": "48be80d1ce7b184b7ea9ba284a75f98cef2847e90d49b0839405a8a4de9c0be9",
        "rich off": "733463c0f1d6c6f292b8d327310fa153445432eeca6a7a2fb9bbb4ad1fe72694",
        "rich on": "733463c0f1d6c6f292b8d327310fa153445432eeca6a7a2fb9bbb4ad1fe72694",
        "levelOnly off": "f6219ad3642ba60e6876fee82b4cf111df0b3f1c12a8160897e2abc395ef0a08",
        "levelOnly on": "f6219ad3642ba60e6876fee82b4cf111df0b3f1c12a8160897e2abc395ef0a08",
        "identity off": "",
        "identity on": "",
    ]

    /// The `formantRenderVersion` the capture above was taken under. Its
    /// ENGAGED sets ("rich off", "rich on") carry slot 7 at THIS version;
    /// since NT-F220 (3, vendored patch 0004) their live keys carry the
    /// current one, so they are compared through the restatement at the
    /// current version, which G-C7b anchors to the capture at this one.
    static let capturedFormantVersion = 2

    /// The block §2d specifies, restated: the marker ("C1ONSON" + 01, a
    /// LITERAL, because changing it would silently re-key every protected
    /// set), then the mask version. `version` is a parameter so a bump can be
    /// shown to re-key without editing DAWCore.
    static func consonantBlock(version: Int = PitchEditSet.consonantMaskVersion) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: UInt64(0x4331_4F4E_534F_4E01).littleEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(bitPattern: Int64(version)).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        return bytes
    }

    /// A set's key by the restatement, in SLOT ORDER: the material through
    /// slot 6, then 7 (formant), 8 (consonant), 9 (transition), each when its
    /// one predicate holds. `slot8: false` is the key the same set had before
    /// slot 8 existed.
    static func expectedHex(_ set: PitchEditSet, slot8: Bool = true,
                            version: Int = PitchEditSet.consonantMaskVersion,
                            formantVersion: Int = PitchEditSet.formantRenderVersion) -> String {
        guard !set.isIdentity else { return "" }
        var bytes = NaturalTuningDigestTests.materialBeforeSlot7(set)
        if set.engagesFormantCurve {
            bytes += NaturalTuningDigestTests.formantBlock(set, version: formantVersion)
        }
        if slot8 && set.hasConsonantMix { bytes += consonantBlock(version: version) }
        if set.usesSoftJoins { bytes += NaturalTuningTransitionRenderTests.transitionBlock(set) }
        return NaturalTuningDigestTests.sha(bytes)
    }

    @Test("G-C7b: the capture is sound, and the restatement reproduces every pre-slot-8 key")
    func captureAndRestatementAgree() {
        NaturalTuningDigestTests.assertRestatementReproducesCaptures()
        let battery = Self.battery()
        #expect(Set(battery.map(\.name)) == Set(Self.capturedBeforeSlot8.keys))
        for golden in Legacy.c21LegacyDigestGoldens {
            #expect(Self.capturedBeforeSlot8["c21 \(golden.set) off"] == golden.hex,
                    "the capture harness does not reproduce the committed '\(golden.set)' golden")
        }
        for (name, set) in battery {
            #expect(Self.expectedHex(set, slot8: false, formantVersion: Self.capturedFormantVersion)
                    == Self.capturedBeforeSlot8[name],
                    "the restatement without slot 8 does not reproduce the capture of '\(name)'")
        }
        // The version parameter is load-bearing for exactly the engaged sets:
        // at the current version their restatement is NOT the capture.
        let engaged = battery.filter { $0.set.engagesFormantCurve }
        #expect(engaged.map(\.name).sorted() == ["rich off", "rich on"],
                "the battery's engaged sets changed: re-read every capture comparison below")
        for (name, set) in engaged {
            #expect(Self.expectedHex(set, slot8: false) != Self.capturedBeforeSlot8[name],
                    "control: '\(name)' at the current formant version equals its version-\(Self.capturedFormantVersion) capture")
        }
    }

    @Test("G-C7b/c: flag off, levels only and identity keep their pre-slot-8 keys byte for byte")
    func unprotectedSetsKeepTheirKeys() {
        #expect(PitchEditSetDigest.consonantSuffixMarker == 0x4331_4F4E_534F_4E01)
        #expect(PitchEditSet.consonantMaskVersion == 1,
                "a version bump re-keys every protected render: make it on purpose, then move this pin")
        var unchanged = 0
        for (name, set) in Self.battery() where !set.hasConsonantMix {
            // An ENGAGED set moved once, by exactly its slot-7 version
            // (NT-F220, 2 → 3); every other set keeps the captured bytes.
            let expected: String? = set.engagesFormantCurve
                ? Self.expectedHex(set, slot8: false) : Self.capturedBeforeSlot8[name]
            #expect(PitchEditSetDigest.hex(set) == expected,
                    "'\(name)' does not ask for the mix and MOVED: every cache entry for it is orphaned")
            unchanged += 1
        }
        // 12 flag-off sets, the levels-only set with the flag on, and the
        // identity set with the flag on (digest "").
        #expect(unchanged == 14)
        #expect(Self.levelOnlySet(consonants: true).keepsConsonantsUntuned
                && !Self.levelOnlySet(consonants: true).hasConsonantMix)
        #expect(PitchEditSetDigest.hex(Self.identitySet(consonants: true)) == "",
                "an identity set with the flag on must stay keyless: it renders the source")
    }

    @Test("G-C7c: a bending set with the flag on re-keys by EXACTLY the consonant block, in slot 8")
    func protectedSetsRekeyByExactlyTheBlock() {
        var moved = 0
        for (name, set) in Self.battery() where set.hasConsonantMix {
            let hex = PitchEditSetDigest.hex(set)
            #expect(hex != Self.capturedBeforeSlot8[name],
                    "'\(name)' kept the key its IGNORED-flag render was cached under")
            #expect(hex == Self.expectedHex(set),
                    "'\(name)' re-keyed, but not by exactly the consonant block in slot 8")
            // Toggling the flag back off restores the pre-slot-8 key exactly
            // (an engaged set's at the current formant version, NT-F220).
            let off = Self.withConsonants(set, false)
            let offKey: String? = off.engagesFormantCurve
                ? Self.expectedHex(off, slot8: false)
                : Self.capturedBeforeSlot8[name.replacingOccurrences(of: " on", with: " off")]
            #expect(PitchEditSetDigest.hex(off) == offKey)
            moved += 1
        }
        #expect(moved == 10, "the battery's ten bending flag-on sets")
    }

    /// Slot order: 7 (formant), 8 (consonant), 9 (transition). The rich set
    /// carries all three plus 5 and 6, so a block placed out of its slot is
    /// a different key.
    @Test("G-C7c: the consonant block sits in slot 8, after slot 7 and before slot 9")
    func consonantBlockIsInSlotEight() {
        let rich = Self.richSet(consonants: true)
        #expect(rich.hasLevelEdits && rich.engagesFormantCurve && rich.hasConsonantMix
                && rich.usesSoftJoins && rich.segments.contains { $0.origin != .detected })
        let material = NaturalTuningDigestTests.materialBeforeSlot7(rich)
        let seven = NaturalTuningDigestTests.formantBlock(rich)
        let eight = Self.consonantBlock()
        let nine = NaturalTuningTransitionRenderTests.transitionBlock(rich)
        let hex = PitchEditSetDigest.hex(rich)
        #expect(hex == NaturalTuningDigestTests.sha(material + seven + eight + nine),
                "the consonant block is not in slot 8")
        // The out-of-order keys are genuinely different keys (the gate can fail).
        #expect(hex != NaturalTuningDigestTests.sha(material + seven + nine + eight))
        #expect(hex != NaturalTuningDigestTests.sha(material + eight + seven + nine))
    }

    @Test("G-C7c: a consonantMaskVersion bump re-keys protected sets only")
    func versionBumpRekeysProtectedOnly() {
        let rich = Self.richSet(consonants: true)
        let v = PitchEditSet.consonantMaskVersion
        #expect(PitchEditSetDigest.hex(rich) == Self.expectedHex(rich, version: v))
        #expect(PitchEditSetDigest.hex(rich) != Self.expectedHex(rich, version: v + 1),
                "the version is not in the protected key: a bump would serve stale audio")
        // No block, so no version: an unprotected key is the same at any version.
        let off = Self.richSet(consonants: false)
        #expect(Self.expectedHex(off, version: v) == Self.expectedHex(off, version: v + 1))
    }

    @Test("marker: the consonant marker is distinct from every other block's")
    func markerIsDistinct() {
        let markers: [UInt64] = [
            PitchEditSetDigest.suffixMarker, PitchEditSetDigest.anchorSuffixMarker,
            PitchEditSetDigest.timeWarpSuffixMarker, PitchEditSetDigest.levelSuffixMarker,
            PitchEditSetDigest.originSuffixMarker, PitchEditSetDigest.formantSuffixMarker,
            PitchEditSetDigest.transitionSuffixMarker,
        ]
        #expect(Set(markers).count == markers.count)
        #expect(!markers.contains(PitchEditSetDigest.consonantSuffixMarker))
    }

    // MARK: - G-C9: inactive reasons and the time-warp tripwire

    /// ⛔ THE TRIPWIRE (G-C9). §2b.5's "time edits" rule is dormant while the
    /// render ignores the time warp. The day C2-3 flips
    /// `StretchCurvePlan.readsTimeWarp`, output frame f stops playing source
    /// frame f, so "the gaps play the untouched take" needs its own mapping.
    @Test("G-C9 tripwire: the render reads no time warp, and DAWCore's copy of that fact agrees")
    func timeWarpTripwire() {
        #expect(StretchCurvePlan.readsTimeWarp == false,
                """
                StretchCurvePlan.readsTimeWarp flipped. RE-DECIDE natural tuning §2b.5: with a \
                warp, the consonant mix's dry read must follow W, or retimed clips must report \
                "time edits". Then update PitchEditSet.consonantMixRenderReadsTimeWarp.
                """)
        #expect(PitchEditSet.consonantMixRenderReadsTimeWarp == StretchCurvePlan.readsTimeWarp,
                "DAWCore's copy of the render's time-warp fact disagrees with the render")
    }

    @Test("G-C9: the render's forwarders read DAWCore's one rule through Params")
    func renderForwardersReadTheOneRule() {
        let rich = Self.richSet(consonants: true)
        func params(_ ratio: Double, _ semitones: Double, _ set: PitchEditSet?) -> StretchRenderCache.Params {
            StretchRenderCache.Params(ratio: ratio, semitones: semitones, formantPreserve: false,
                                      pitchEdits: set)
        }
        #expect(StretchCurvePlan.consonantMixInactiveReason(params(1, 0, rich)) == nil)
        #expect(StretchCurvePlan.consonantMixActive(params(1, 0, rich)))
        #expect(StretchCurvePlan.consonantMixInactiveReason(params(1.25, 0, rich)) == .clipStretched)
        #expect(StretchCurvePlan.consonantMixInactiveReason(params(1, 3, rich)) == .clipTransposed)
        #expect(!StretchCurvePlan.consonantMixActive(params(1, 3, rich)))
        // Every combination agrees with DAWCore's rule, never a local copy.
        for ratio in [1.0, 0.5, 2.0] {
            for semitones in [0.0, -2.0, 7.0] {
                #expect(StretchCurvePlan.consonantMixInactiveReason(params(ratio, semitones, rich))
                        == rich.consonantMixInactiveReason(stretchRatio: ratio, clipSemitones: semitones))
                #expect(StretchCurvePlan.consonantMixActive(params(ratio, semitones, rich))
                        == rich.consonantMixIsActive(stretchRatio: ratio, clipSemitones: semitones))
            }
        }
        // Flag off, and an identity set (Params normalises it to nil): off.
        #expect(!StretchCurvePlan.consonantMixActive(params(1, 0, Self.richSet(consonants: false))))
        #expect(!StretchCurvePlan.consonantMixActive(params(1, 0, Self.identitySet(consonants: true))))
        #expect(StretchCurvePlan.consonantMixInactiveReason(params(1, 3, Self.identitySet(consonants: true))) == nil)
    }

    // MARK: - §2d: the clip's render signature sees the flag

    /// `ClipRenderSignature.Tuning` compares every set-level field through
    /// the set's synthesized `==` (its "everything but the notes" copy), so a
    /// flag flip on a clip whose edits bend is a signature change. Tested
    /// here, not in DAWAppKit (the natural-tuning lane table's ruling).
    @Test("§2d: flipping only keepsConsonantsUntuned changes a bending clip's render signature")
    func renderSignatureSeesTheFlag() {
        // ONE clip (its id keys the signature), with only the flag changed.
        let base = Clip(name: "Vocal", startBeat: 0, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/tmp/nt-c2-signature.wav"))
        func signature(_ set: PitchEditSet) -> ClipRenderSignature {
            var clip = base
            clip.pitchEdits = set
            return ClipRenderSignature(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        }
        let on = Self.richSet(consonants: true)
        let off = Self.richSet(consonants: false)
        #expect(signature(on) == signature(on), "control: the signature is deterministic")
        #expect(signature(off) != signature(Self.richSet(consonants: false).withSegments([])),
                "control: the signature sees a change to the set at all")
        #expect(signature(on) != signature(off), "the render signature cannot see the consonant flag")
    }
}
