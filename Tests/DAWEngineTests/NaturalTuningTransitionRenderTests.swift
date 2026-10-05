import CryptoKit
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// Natural tuning §4 (lane NT-C C4): soft joins, the transition digest block
/// (slot 9), and the legacy byte goldens G-BYTE names.
///
/// Deliberately NOT `@MainActor` (curve and digest arithmetic, offline renders;
/// `MainActorOccupancySiteTests` Leg C caps `@MainActor` suites).
@Suite("Natural tuning §4 — soft joins: legacy goldens, slot 9, render physics (NT-C C4)")
struct NaturalTuningTransitionRenderTests {

    // MARK: - The legacy join goldens (G-BYTE, R27)

    static let idA = UUID(uuidString: "C4000000-0000-4000-8000-00000000000A")!
    static let idB = UUID(uuidString: "C4000000-0000-4000-8000-00000000000B")!
    static let idC = UUID(uuidString: "C4000000-0000-4000-8000-00000000000C")!

    static func note(_ id: UUID, _ start: Double, _ end: Double, cents: Double) -> NoteSegment {
        NoteSegment(id: id, startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: 0.9, pitchOffsetCents: cents)
    }

    /// Three LEGACY sets (slope 0, no width, no follow), each with a join the
    /// soft rule would change: a 500 c jump at the 30 ms floor, a 60 ms note
    /// between two long ones at retune 200 (the F12 shape), and a 16 ms hole
    /// (R15's short hole) under a 300 c move.
    static func legacyJoinSet(_ name: String) -> PitchEditSet {
        switch name {
        case "bigJump":
            return PitchEditSet(segments: [note(idA, 0.5, 1.5, cents: 500),
                                           note(idB, 1.5, 2.5, cents: 0)], retuneMs: 30)
        case "shortNeighbour":
            return PitchEditSet(segments: [note(idA, 0.5, 2.0, cents: 300),
                                           note(idB, 2.0, 2.06, cents: 300),
                                           note(idC, 2.06, 3.0, cents: 0)], retuneMs: 200)
        case "shortHole":
            return PitchEditSet(segments: [note(idA, 0.5, 1.5, cents: 300),
                                           note(idB, 1.516, 2.5, cents: 0)], retuneMs: 30)
        default:
            Issue.record("no legacy join set named \(name)")
            return .empty
        }
    }

    static let legacyJoinSetNames = ["bigJump", "shortNeighbour", "shortHole"]

    /// SHA-256 over the bit patterns of the pitch curve AND the formant curve
    /// (`formantPreserve: false`, nil amount, so it follows every move) at
    /// `t = i · 0.5 ms` for i in 0...6400 (index-built, never accumulated).
    static func curveHash(_ set: PitchEditSet) -> String {
        let curve = PitchCorrectionCurve.make(editSet: set)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(6401 * 16)
        for i in 0...6400 {
            let t = Double(i) * 0.0005
            for value in [curve.semitones(atSourceSecond: t),
                          curve.formantSemitones(atSourceSecond: t, formantPreserve: false)] {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
            }
        }
        var hasher = SHA256()
        hasher.update(data: Data(bytes))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// ⭐ CAPTURED ON THE TREE BEFORE C4 TOUCHED `make` (2026-09-25 21:17,
    /// `scratchpad/w5/C4/logs/baseline.log`, a capture-only test that printed
    /// `curveHash` and `PitchEditSetDigest.hex` of each set). These are the
    /// goldens R27's G-BYTE plant NAMES: every other curve and render golden
    /// in the tree is INERT to "force the new-set slope on every set" (their
    /// joins have W ≤ retune and no shorter neighbour, so the soft rule gives
    /// them their legacy halves); these three are not, so the plant turns
    /// all three red.
    static let legacyJoinGoldens: [(set: String, curve: String, digest: String)] = [
        ("bigJump", "532c918ae97f1e674af2dc1fced37d044c8cffe24349f0c48d263317d6c263d0",
         "2c44554e87f46ccdf063ff00fa9c4630f518b98e4867819113773d1681380bb5"),
        ("shortNeighbour", "b048b5c65da55ffcae023d405ebdcad2d155825abb02b21180dc5735a870e329",
         "eb253157ea98cdaa6531eebaf2640c4c590908887210852098f5f40ff93323dc"),
        ("shortHole", "91fdb267c87898fb81be39da3c5c6e43d10f87ee11061f60817c7a97712b382f",
         "458cc08c9d38e90b62baf14ffdceef0e8f358b20e2c006b88c8bf78c1d82f9d9"),
    ]

    /// G-BYTE (R27): each legacy set's curve (pitch AND formant) and key are
    /// the ones captured before C4, and it emits no slot 9.
    @Test("G-BYTE legacy join goldens: the curve and the key are the pre-C4 captures, and no slot 9")
    func legacyJoinGoldensHold() {
        for golden in Self.legacyJoinGoldens {
            let set = Self.legacyJoinSet(golden.set)
            #expect(!set.usesSoftJoins, "'\(golden.set)' must be a LEGACY set")
            let curve = Self.curveHash(set)
            #expect(curve == Self.curveHash(set), "'\(golden.set)': the curve is not deterministic")
            #expect(curve == golden.curve,
                    """
                    the LEGACY '\(golden.set)' curve moved (\(curve)): the soft branch reached a \
                    set that does not use soft joins.
                    """)
            #expect(PitchEditSetDigest.hex(set) == golden.digest,
                    "the LEGACY '\(golden.set)' key moved: \(PitchEditSetDigest.hex(set))")
            #expect(PitchEditSetDigest.hex(set)
                    == NaturalTuningDigestTests.sha(NaturalTuningDigestTests.materialBeforeSlot7(set)))
        }
    }

    // MARK: - Slot 9 (§4.d, X1)

    /// The block §4.d specifies, restated: the marker ("T1RANSI" + 01, a
    /// LITERAL, because changing it would silently re-key every soft set), the
    /// render version, the slope's bits, the note count, then each note's
    /// width and follow bits. `version` is a parameter so a bump can be shown
    /// to re-key without editing DAWCore.
    static func transitionBlock(_ set: PitchEditSet,
                                version: Int = PitchEditSet.transitionRenderVersion) -> [UInt8] {
        var bytes: [UInt8] = []
        func put(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        put(0x5431_5241_4E53_4901)
        put(UInt64(bitPattern: Int64(version)))
        put(set.transitionSlopeCentsPerSecond.bitPattern)
        put(UInt64(bitPattern: Int64(set.segments.count)))
        for segment in set.segments {
            put(segment.transitionOutMs.bitPattern)
            put(segment.glideFollow.bitPattern)
        }
        return bytes
    }

    /// A soft set's key is its legacy material, then slot 7 when it engages
    /// the formant curve, then slot 9: by construction, in slot order.
    static func expectedHex(_ set: PitchEditSet) -> String {
        var bytes = NaturalTuningDigestTests.materialBeforeSlot7(set)
        if set.engagesFormantCurve { bytes += NaturalTuningDigestTests.formantBlock(set) }
        if set.usesSoftJoins { bytes += transitionBlock(set) }
        return NaturalTuningDigestTests.sha(bytes)
    }

    @Test("slot 9: a soft set re-keys by EXACTLY the transition block, after slot 7; legacy keys do not move")
    func softSetsRekeyByExactlyTheBlock() {
        NaturalTuningDigestTests.assertRestatementReproducesCaptures()
        #expect(PitchEditSetDigest.transitionSuffixMarker == 0x5431_5241_4E53_4901)
        for golden in Self.legacyJoinGoldens {
            var soft = Self.legacyJoinSet(golden.set)
            soft.transitionSlopeCentsPerSecond = PitchEditSet.defaultTransitionSlope
            #expect(soft.usesSoftJoins)
            let hex = PitchEditSetDigest.hex(soft)
            #expect(hex != golden.digest, "'\(golden.set)' with a slope kept its legacy key")
            #expect(hex == Self.expectedHex(soft), "'\(golden.set)' re-keyed, but not by exactly slot 9")
            // Slot 9 sits AFTER slot 7 (formant) when both are present.
            var both = soft
            both.formantCorrection = 0.5
            #expect(PitchEditSetDigest.hex(both) == Self.expectedHex(both),
                    "'\(golden.set)': slot 9 is not after slot 7")
        }
        // The c21 legacy sets, whose render goldens other suites pin, emit no slot 9.
        for name in ["offset", "shaping", "generator", "delta", "timingOnly", "startDelta"] {
            #expect(!PitchCurveRenderTests.c21Set(name).usesSoftJoins, "'\(name)' reads as soft")
        }
    }

    @Test("slot 9: the slope, ONE width and ONE follow each re-key; a version bump re-keys soft sets only")
    func eachTransitionFieldRekeys() {
        var base = Self.legacyJoinSet("shortNeighbour")
        base.transitionSlopeCentsPerSecond = 3000
        let reference = PitchEditSetDigest.hex(base)
        var slope = base
        slope.transitionSlopeCentsPerSecond = 4500
        var width = base
        width.segments[1].transitionOutMs = 120
        var follow = base
        follow.segments[1].glideFollow = 0.5
        for (name, set) in [("slope", slope), ("width", width), ("follow", follow)] {
            #expect(PitchEditSetDigest.hex(set) != reference, "changing only the \(name) left the key")
            #expect(PitchEditSetDigest.hex(set) == Self.expectedHex(set))
        }
        // A width alone makes a slope-0 set soft, and keys it.
        var widthOnly = Self.legacyJoinSet("bigJump")
        widthOnly.segments[0].transitionOutMs = 200
        #expect(widthOnly.usesSoftJoins && PitchEditSetDigest.hex(widthOnly) == Self.expectedHex(widthOnly))
        // A version bump moves the soft key (restated at version + 1) and
        // cannot touch a legacy key, which carries no block.
        let bumped = NaturalTuningDigestTests.sha(
            NaturalTuningDigestTests.materialBeforeSlot7(base)
                + Self.transitionBlock(base, version: PitchEditSet.transitionRenderVersion + 1))
        #expect(bumped != reference)
    }

    /// G-ID: a table seeded the way the editor seeds one (a slope, a slide
    /// following, every offset 0) bends nothing: keyless, and no plan.
    @Test("G-ID a seeded-but-unedited soft table is identity: digest \"\" and no curve plan")
    func seededTableStaysKeyless() {
        let set = PitchEditSet(segments: [Self.note(Self.idA, 0.5, 1.0, cents: 0),
                                          NoteSegment(id: Self.idB, startSeconds: 1.0, endSeconds: 1.2,
                                                      detectedHz: 220, detectedConfidence: 0.9,
                                                      glideFollow: 1, origin: .transition),
                                          Self.note(Self.idC, 1.2, 2.0, cents: 0)],
                               transitionSlopeCentsPerSecond: PitchEditSet.defaultTransitionSlope)
        #expect(set.usesSoftJoins && set.isIdentity && set.isPitchIdentity)
        #expect(PitchEditSetDigest.hex(set) == "")
        #expect(StretchCurvePlan.make(editSet: set, clipPitchShiftSemitones: 0,
                                      sampleRate: 48_000, ratio: 1) == nil)
    }

    // MARK: - Render physics on a sine (G-LAND, R10; F12)

    static let sampleRate = 48_000.0

    /// 2 s of a 220 Hz sine through the shipping plan and stretcher
    /// (`PitchCurveRenderTests.c21Render`, ratio 1), tracked.
    static func trackedRender(_ set: PitchEditSet) throws -> [M23QToneEstimate] {
        let rendered = try PitchCurveRenderTests.c21Render(set, ratio: 1)
        #expect(M23QWaveform.isAllFinite(rendered))
        return M23QToneTracker.track(rendered, sampleRate: sampleRate)
    }

    /// The median tracked pitch, cents above 220 Hz, over `seconds`.
    static func cents(_ track: [M23QToneEstimate], _ seconds: ClosedRange<Double>) -> Double? {
        M23QToneTracker.medianHz(track, centreIn: (seconds.lowerBound * sampleRate)
                                    ..< (seconds.upperBound * sampleRate))
            .map { M23QToneTracker.cents($0, above: 220) }
    }

    /// R10: a 400 c move meets an unmoved note at a soft join (3000 c/s:
    /// W = 133 ms, h = 66.7 ms, read from the SAME rule the curve uses).
    /// The tracked pitch is measured where the join has FINISHED: past
    /// `h + half a hop (15 ms) + the tracker's half window (10.7 ms)` on each
    /// side, over 10 ms. Each side must sit within ±10 c of its target.
    /// Positive control: at the join itself the pitch is still between the
    /// two (the render really glides; a legacy 30 ms join would have landed).
    /// − the mirror image (B moved) lands mirrored.
    @Test("G-LAND a 4 st move lands where the soft join has finished, both sides and mirrored (R10)")
    func bigMoveLandsWhereTheJoinFinishes() throws {
        for (a, b) in [(400.0, 0.0), (0.0, 400.0)] {
            let set = PitchEditSet(segments: [Self.note(Self.idA, 0.3, 1.0, cents: a),
                                              Self.note(Self.idB, 1.0, 1.7, cents: b)],
                                   transitionSlopeCentsPerSecond: PitchEditSet.defaultTransitionSlope)
            let width = try #require(set.joinReading(afterSegmentAt: 0)?.appliedWidthMs)
            let h = width / 2000
            let settle = h + 0.015 + 512 / Self.sampleRate
            let track = try Self.trackedRender(set)
            let before = try #require(Self.cents(track, (1.0 - settle - 0.01)...(1.0 - settle)))
            let after = try #require(Self.cents(track, (1.0 + settle)...(1.0 + settle + 0.01)))
            let middle = try #require(Self.cents(track, 0.995...1.005))
            print(String(format: "nt-c4| G-LAND A %+.0f c / B %+.0f c: W %.1f ms; before %+.1f c, "
                         + "at the join %+.1f c, after %+.1f c", a, b, width, before, middle, after))
            #expect(abs(before - a) <= 10, "A has not landed at −\(settle) s: \(before) c vs \(a)")
            #expect(abs(after - b) <= 10, "B has not landed at +\(settle) s: \(after) c vs \(b)")
            #expect(abs(middle - (a + b) / 2) < 100,
                    "at the join the render is not gliding: \(middle) c (a legacy join would sit on one side)")
        }
    }

    /// F12 in the RENDER: NT-G's fixture shape (a long note then a 60 ms
    /// note, both +300 c, retune 200) sags on the legacy rule and does not
    /// once the set is soft. Positive control: the legacy render's sag is
    /// visible to this instrument.
    @Test("F12 render: the legacy join sags, the soft join does not")
    func f12RenderSag() throws {
        let legacy = PitchEditSet(segments: [Self.note(Self.idA, 0.2, 1.5, cents: 300),
                                             Self.note(Self.idB, 1.5, 1.56, cents: 300)],
                                  retuneMs: 200)
        var soft = legacy
        soft.transitionSlopeCentsPerSecond = PitchEditSet.defaultTransitionSlope
        func sag(_ set: PitchEditSet) throws -> Double {
            let track = try Self.trackedRender(set)
            // To 1.51 s: the short note's own fall starts at 1.53 s, and the
            // tracker's window reaches 10.7 ms either side of its centre.
            let low = Int(1.3 * Self.sampleRate), high = Int(1.51 * Self.sampleRate)
            let values = track.filter { $0.centreFrame >= Double(low) && $0.centreFrame <= Double(high) }
                .map { M23QToneTracker.cents($0.hz, above: 220) }
            return 300 - (values.min() ?? .nan)
        }
        let legacySag = try sag(legacy)
        let softSag = try sag(soft)
        print(String(format: "nt-c4| F12 render: legacy sag %.1f c, soft sag %.1f c", legacySag, softSag))
        #expect(legacySag > 30, "the instrument cannot see the legacy dip: \(legacySag) c")
        #expect(softSag < 10, "the soft join still sags \(softSag) c")
    }
}
