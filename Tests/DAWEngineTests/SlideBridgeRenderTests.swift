import CryptoKit
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// vf-18 leg 1 (W9-SLFX; design `$S/w9/SLRV/REVIEW.md`, "carry + hold"):
/// THE LEGACY RULE STAYS TODAY'S, BIT FOR BIT, AND THE NEW RULE IS KEYED.
///
/// ⭐ **B1, THE RED-FIRST LEG.** Every legacy-rule set below (built through the
/// memberwise init, so `slideFollowRule` is ABSENT = `.sungAtOpenSide`) has
/// followed slides whose curve the HOLD rule would change: one-sided slides
/// beside moved notes, adjacent followed slides, the literal "every note +M"
/// doubling state, slides at the clip edges, plus 160 seeded sets dense in
/// those shapes. Their curve (pitch AND formant, every 0.5 ms, plus every
/// join reading the wire echoes) and their digest were CAPTURED ON THE TREE
/// BEFORE ANY vf-18 SOURCE EDIT (2026-10-12 12:10 and 12:35,
/// `PitchCorrection.swift` sha1 7f14800b…, `StretchCurvePlan.swift` 891616a2…;
/// capture logs `$S/w9/SLFX/logs/capture.log` and `capture2.log`: the second
/// run gave every note a fixed id, which moved no curve bit and made the
/// digests repeatable). ⛔ FROZEN: never regenerate them from the
/// current code, or the gate compares the code with itself.
///
/// Deliberately NOT `@MainActor` (curve and digest arithmetic, offline
/// renders; `MainActorOccupancySiteTests` Leg C caps `@MainActor` suites).
@Suite("vf-18: the legacy slide rule renders and keys as before; the hold rule is keyed (W9-SLFX)")
struct SlideBridgeRenderTests {

    // MARK: - B1 fixtures: LEGACY-RULE sets, built only through the memberwise init

    static func note(_ start: Double, _ end: Double, cents: Double = 0, width: Double = 0,
                     follow: Double = 0, formant: Double = 0,
                     origin: NoteOrigin = .detected) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: 0.9, pitchOffsetCents: cents,
                    formantOffsetSemitones: formant, transitionOutMs: width,
                    glideFollow: follow, origin: origin)
    }

    /// A fixed id for note `index` of set `tag`: the digest hashes every id,
    /// so a fixture with fresh `UUID()`s keys differently on every run.
    static func fixedID(_ tag: Int, _ index: Int) -> UUID {
        UUID(uuidString: String(format: "B1%06X-0000-4000-8000-%012X", tag, index))!
    }

    /// `segments` with fixed ids, every other field carried by the type's own
    /// `Codable` (`NoteSegment.id` is a `let`; a hand-listed copy would drop
    /// the next field added).
    static func identified(_ segments: [NoteSegment], tag: Int) -> [NoteSegment] {
        segments.enumerated().map { index, segment in
            var object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(segment)))
                as? [String: Any] ?? [:]
            object["id"] = fixedID(tag, index).uuidString
            return (try? JSONSerialization.data(withJSONObject: object))
                .flatMap { try? JSONDecoder().decode(NoteSegment.self, from: $0) } ?? segment
        }
    }

    /// `set` with fixed ids (`withSegments` carries every set-level field).
    static func identified(_ set: PitchEditSet, tag: Int) -> PitchEditSet {
        set.withSegments(identified(set.segments, tag: tag))
    }

    /// Named legacy-rule sets with one-sided and adjacent followed slides and
    /// MOVED anchors: every shape whose curve the hold rule would change.
    static func b1Set(_ name: String) -> PitchEditSet {
        identified(b1SetFreshIDs(name), tag: (b1Names.firstIndex(of: name) ?? 999) + 1)
    }

    static func b1SetFreshIDs(_ name: String) -> PitchEditSet {
        switch name {
        case "tailOffMoved":
            // A moved, T a tail-off facing a 200 ms gap, B moved the other way.
            return PitchEditSet(segments: [note(0.5, 1.0, cents: 300),
                                           note(1.0, 1.2, cents: 50, follow: 1, origin: .transition),
                                           note(1.4, 2.0, cents: -200)],
                                transitionSlopeCentsPerSecond: 3000)
        case "leadInMoved":
            // A, a gap, then L a lead-in INTO a moved B, then C abutting B.
            return PitchEditSet(segments: [note(0.3, 0.8, cents: -150),
                                           note(1.0, 1.15, follow: 1, origin: .transition),
                                           note(1.15, 1.9, cents: 400),
                                           note(1.9, 2.4, cents: 100)],
                                transitionSlopeCentsPerSecond: 3000)
        case "adjacentSlides":
            // Two abutting followed slides (a split of one), each reading the
            // other's own offset under today's rule.
            return PitchEditSet(segments: [note(0.5, 1.0, cents: 300),
                                           note(1.0, 1.15, cents: 100, follow: 1, origin: .transition),
                                           note(1.15, 1.3, cents: -50, follow: 0.5, origin: .transition),
                                           note(1.3, 2.0, cents: -200)],
                                transitionSlopeCentsPerSecond: 3000)
        case "uniformLiteralTwoSided":
            // The literal "every note +12" state: today plays 2M on the slide.
            return PitchEditSet(segments: [note(0.5, 1.0, cents: 1200),
                                           note(1.0, 1.2, cents: 1200, follow: 1, origin: .transition),
                                           note(1.2, 2.0, cents: 1200)],
                                transitionSlopeCentsPerSecond: 3000)
        case "uniformLiteralOneSided":
            return PitchEditSet(segments: [note(0.5, 1.0, cents: -500),
                                           note(1.0, 1.2, cents: -500, follow: 1, origin: .transition),
                                           note(1.4, 2.0, cents: -500)],
                                transitionSlopeCentsPerSecond: 3000)
        case "mixed":
            // A short hole (16 ms) into a half-followed slide; an untouched
            // 20 ms sound (soft across it); a MOVED sound beside a slide; an
            // explicit width; formant offsets and a voice amount; retune 80.
            var set = PitchEditSet(segments: [
                note(0.2, 0.6, cents: 233.3, formant: 1),
                note(0.616, 0.76, cents: -41.7, follow: 0.5, origin: .transition),
                note(0.76, 1.3, cents: 87.1, width: 140),
                note(1.3, 1.32, origin: .unpitched),
                note(1.32, 1.5, cents: 12.5, follow: 1, origin: .transition),
                note(1.5, 1.6, cents: -300, origin: .unpitched),
                note(1.6, 1.75, cents: 66.6, follow: 0.75, origin: .transition),
                note(1.75, 2.4, cents: -1.9550008653880013, formant: -2),
            ], retuneMs: 80, transitionSlopeCentsPerSecond: 4500)
            set.formantCorrection = 0.25
            return set
        case "edges":
            // A followed slide at each clip edge (nothing before / after it).
            return PitchEditSet(segments: [note(0.0, 0.2, cents: -80, follow: 1, origin: .transition),
                                           note(0.2, 0.9, cents: 450),
                                           note(0.9, 1.6, cents: -120),
                                           note(1.6, 1.85, cents: 30, follow: 1, origin: .transition)],
                                transitionSlopeCentsPerSecond: 3000)
        case "aloneBetweenGaps":
            return PitchEditSet(segments: [note(0.5, 1.0, cents: 300),
                                           note(1.2, 1.4, cents: 100, follow: 1),
                                           note(1.6, 2.0)],
                                transitionSlopeCentsPerSecond: 3000)
        case "widthOnlySlopeZero":
            // Soft only through an explicit width; the slide's other join keeps
            // its legacy halves (no slope).
            return PitchEditSet(segments: [note(0.5, 1.0, cents: 250, width: 120),
                                           note(1.0, 1.2, cents: -30, follow: 1, origin: .transition),
                                           note(1.2, 2.0, cents: -175)],
                                retuneMs: 45)
        default:
            Issue.record("no B1 set named \(name)")
            return .empty
        }
    }

    static let b1Names = ["tailOffMoved", "leadInMoved", "adjacentSlides", "uniformLiteralTwoSided",
                          "uniformLiteralOneSided", "mixed", "edges", "aloneBetweenGaps",
                          "widthOnlySlopeZero"]

    /// SplitMix64, so the fuzz below needs no other test target's helpers.
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
        mutating func uniform(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
        mutating func chance(_ p: Double) -> Bool { unit() < p }
    }

    /// Seeded LEGACY-RULE soft sets dense in followed slides: abutting runs,
    /// R15 short holes, gaps, sounds (some moved), widths, follows (full and
    /// partial), formant offsets and amounts. No transcendental functions, so
    /// the stream is plain IEEE arithmetic.
    static func b1Fuzz(count: Int) -> [PitchEditSet] {
        var rng = Rng(state: 0x0F18_2026_1012_B100)
        var sets: [PitchEditSet] = []
        for _ in 0..<count {
            let notes = 3 + Int(rng.next() % 8)
            var segments: [NoteSegment] = []
            var cursor = rng.uniform(0, 0.3)
            for _ in 0..<notes {
                let duration = rng.uniform(0.06, 0.6)
                let origin: NoteOrigin = rng.chance(0.12) ? .unpitched : (rng.chance(0.3) ? .transition : .detected)
                var cents = rng.chance(0.3) ? 0 : rng.uniform(-1200, 1200)
                if origin == .unpitched && rng.chance(0.5) { cents = 0 }
                let follow = origin == .unpitched ? 0 : (rng.chance(0.45) ? (rng.chance(0.5) ? 1 : rng.unit()) : 0)
                segments.append(note(cursor, cursor + duration, cents: cents,
                                     width: rng.chance(0.25) ? rng.uniform(30, 400) : 0,
                                     follow: follow,
                                     formant: rng.chance(0.2) ? rng.uniform(-6, 6) : 0,
                                     origin: origin))
                cursor += duration
                let join = rng.unit()
                if join < 0.5 {
                    // abutting: the next start IS this end, the same Double
                } else if join < 0.7 {
                    cursor += rng.uniform(0, PitchEditSet.consonantMinimumGapSeconds * 0.99)
                } else {
                    cursor += rng.uniform(PitchEditSet.consonantMinimumGapSeconds, 0.4)
                }
            }
            var set = PitchEditSet(segments: segments, retuneMs: rng.uniform(30, 300),
                                   transitionSlopeCentsPerSecond: rng.chance(0.85)
                                       ? rng.uniform(500, 20_000) : 0)
            if rng.chance(0.5) { set.formantCorrection = rng.unit() }
            sets.append(identified(set, tag: 0x1000 + sets.count))
        }
        return sets
    }

    static let b1FuzzCount = 160

    /// The bytes B1 hashes for one set: the pitch AND formant curve
    /// (`formantPreserve: false`) at `t = i · 0.5 ms` from 0 to the last end
    /// + 0.25 s (index-built), then every segment's join reading (kind byte,
    /// applied width bits or a sentinel).
    static func curveBytes(_ set: PitchEditSet) -> [UInt8] {
        let curve = PitchCorrectionCurve.make(editSet: set)
        let end = (set.segments.last?.endSeconds ?? 0) + 0.25
        let count = Int((end / 0.0005).rounded(.up))
        var bytes: [UInt8] = []
        bytes.reserveCapacity((count + 1) * 16 + set.segments.count * 9)
        func put(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        for i in 0...count {
            let t = Double(i) * 0.0005
            put(curve.semitones(atSourceSecond: t).bitPattern)
            put(curve.formantSemitones(atSourceSecond: t, formantPreserve: false).bitPattern)
        }
        for index in set.segments.indices {
            let reading = set.joinReading(afterSegmentAt: index)
            switch reading?.kind {
            case nil: bytes.append(0)
            case .soft?: bytes.append(1)
            case .gap?: bytes.append(2)
            case .last?: bytes.append(3)
            }
            put(reading?.appliedWidthMs?.bitPattern ?? 0xFFFF_FFFF_FFFF_FFFF)
        }
        return bytes
    }

    static func sha(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// B1's positive controls, counted on the CURVE notes (`entersPitchCurve`)
    /// with R15's join rule: followed slides with exactly one HELD soft
    /// neighbour whose own offset is non-zero (the shape whose curve the hold
    /// rule changes), and abutting/soft pairs of followed slides (today each
    /// reads the other's own offset). A B1 holding neither is blind to the rule.
    static func shapes(_ set: PitchEditSet) -> (oneSided: Int, adjacentPairs: Int) {
        let notes = set.segments.filter(\.entersPitchCurve)
        guard notes.count > 1 else { return (0, 0) }
        func soft(_ i: Int) -> Bool {
            PitchEditSet.joinKind(leftEndSeconds: notes[i].endSeconds,
                                  rightStartSeconds: notes[i + 1].startSeconds) == .soft
        }
        var oneSided = 0
        var pairs = 0
        for i in notes.indices where notes[i].glideFollow > 0 {
            let prevHeld = i > 0 && soft(i - 1) && notes[i - 1].glideFollow == 0
            let nextHeld = i + 1 < notes.count && soft(i) && notes[i + 1].glideFollow == 0
            if prevHeld != nextHeld {
                let present = prevHeld ? notes[i - 1] : notes[i + 1]
                if present.pitchOffsetCents != 0 { oneSided += 1 }
            }
            if i + 1 < notes.count && soft(i) && notes[i + 1].glideFollow > 0 { pairs += 1 }
        }
        return (oneSided, pairs)
    }

    /// The captures (see the type's banner): curve SHA-256 and digest hex per
    /// named set, and the positive-control shape counts, so a fixture edit
    /// that loses its one-sided or adjacent slides cannot keep B1 green.
    static let b1Goldens: [(set: String, oneSided: Int, adjacentPairs: Int, curve: String, digest: String)] = [
        ("tailOffMoved", 1, 0,
         "a703ff96a46661edc1d59685106d31d958ec894d803cb4aa6d796f2ffbf0f6f2",
         "b10b4b8f3b6a499c526ab9d25544bb5a17151bd7e9d9599f6c64d058bf57458d"),
        ("leadInMoved", 1, 0,
         "5bf001b1c1a554cd0265b92aa6609227c1674052800f513cc000a9282c4a748a",
         "c8081fdef89e7d1ad88addd1e3c47888297cab9929b91939af31b11c75726ba9"),
        ("adjacentSlides", 2, 1,
         "24930d44f715e25b4d053a7b2af555cbe19e94707d353d9db11f2def7786090f",
         "e2e87e83cc0638691f0747d3ee4ea66afc39bdd57a0b7933d7ae31dd3278c355"),
        ("uniformLiteralTwoSided", 0, 0,
         "1a1b2e52d2f654a25c1aa7146a1e7a5e5e36200cb4ae91af5f19afef2dc18332",
         "c7530edd50d20524edd85ccab38fcc5e19972c8b86cfe9759a8a7a48c8007eeb"),
        ("uniformLiteralOneSided", 1, 0,
         "afac1c13cd1140ac5dff9327bca6087540cb103912a7bf67cc664585b24b97a7",
         "b037bd43ad0a6335b8bee2bd33157ecd6bf64e92d04c2ae842334e2aeb2503d5"),
        ("mixed", 0, 0,
         "5e649730d3769f187ff81823cca4d891b3cc0197b5f618195314128672f5e94b",
         "0e059bf9cf20bb5fe7e70454a197e75957f2274eed993b9bb57eb11b3bd304eb"),
        ("edges", 2, 0,
         "2d1715e619a9c68a638b24ec5d86e0bc6bbd0e6b1b1c7addf92f54fed45764d4",
         "eeb1c9ed8f224989f5eb3b5c49edc068f14b58c86b9884df65ad906a017c2100"),
        ("aloneBetweenGaps", 0, 0,
         "1aaf112959795ff244e4016c859cff61f4b541014c82ed94fe2f3cce764c97bc",
         "37e0c86fdb7dc2f30c82fc66e5d57fd6b22f8702dce7d98d374ade27974a3c9e"),
        ("widthOnlySlopeZero", 0, 0,
         "f4236e3667bd598d781959c60235f826d6001316a35cce8b2bf743e1da9c765b",
         "9e75ce4c807f6adf90f43ead6b76bef2964d7c16d997a97b2818c23e6cc95653"),
    ]

    /// The 160-set fuzz, captured the same way: counts, then the SHA-256 over
    /// every set's curve bytes in order, and over every digest (hex + newline).
    static let b1FuzzGolden = (soft: 160, followed: 440, oneSided: 144, adjacentPairs: 112,
                               curve: "ab039527d64fb7f27931adeb768f5a58d4f64d15c1b701dcf810c3077f816720",
                               digest: "cd2a8eaa3c8bbf307784ba15951daeae403fb60bdd2732ab91ca01d5cfaff9e9")

    @Test("B1 legacy-rule sets with one-sided and adjacent followed slides keep their pre-vf-18 curve and key")
    func legacyRuleGoldensHold() {
        #expect(Self.b1Goldens.map(\.set) == Self.b1Names)
        for golden in Self.b1Goldens {
            let set = Self.b1Set(golden.set)
            #expect(set.usesSoftJoins, "'\(golden.set)' must be soft, or it never reaches the bridge")
            #expect(set.segments.allSatisfy { $0.id.uuidString.hasPrefix("B1") },
                    "'\(golden.set)' carries a fresh id: its digest would change on every run")
            let shapes = Self.shapes(set)
            #expect(shapes.oneSided == golden.oneSided && shapes.adjacentPairs == golden.adjacentPairs,
                    "'\(golden.set)' lost its shapes: \(shapes)")
            let curve = Self.sha(Self.curveBytes(set))
            #expect(curve == golden.curve,
                    "the LEGACY-rule '\(golden.set)' curve moved (\(curve)): the hold rule reached a set that never chose it")
            let digest = PitchEditSetDigest.hex(set)
            #expect(digest == golden.digest, "the LEGACY-rule '\(golden.set)' key moved: \(digest)")
        }
        let fuzz = Self.b1Fuzz(count: Self.b1FuzzCount)
        var curves: [UInt8] = []
        var digests: [UInt8] = []
        var followed = 0, soft = 0, oneSided = 0, pairs = 0
        for set in fuzz {
            curves += Self.curveBytes(set)
            digests += Array(PitchEditSetDigest.hex(set).utf8)
            digests.append(0x0A)
            followed += set.segments.filter { $0.glideFollow > 0 }.count
            if set.usesSoftJoins { soft += 1 }
            let shapes = Self.shapes(set)
            oneSided += shapes.oneSided
            pairs += shapes.adjacentPairs
        }
        let golden = Self.b1FuzzGolden
        // Positive controls first: the fuzz still holds the shapes the hold
        // rule changes, so "identical" below is not a fuzz that lost them.
        #expect(soft == golden.soft && followed == golden.followed
                    && oneSided == golden.oneSided && pairs == golden.adjacentPairs,
                "the B1 fuzz changed: soft \(soft), followed \(followed), one-sided \(oneSided), pairs \(pairs)")
        #expect(Self.sha(curves) == golden.curve, "a LEGACY-rule fuzz curve moved: \(Self.sha(curves))")
        #expect(Self.sha(digests) == golden.digest, "a LEGACY-rule fuzz key moved: \(Self.sha(digests))")
    }

    // MARK: - B1s: a corpus that can SEE a rewritten legacy path (plant P6)

    /// Plant P6 routes the legacy branch through the hold helper's arithmetic.
    /// Done EXACTLY (P6a) that is the same IEEE operations in the same order,
    /// so no output gate can see it, and none needs to. Done with a semitone
    /// round trip on the anchors (P6b, `(cents / 100) * 100`) it changes a
    /// join's width only where the SLOPE sets that width (above the retune
    /// floor, under the half-note cap) AND the round trip returns a different
    /// Double: B1's corpus holds few such joins (counted below). B1s is a
    /// corpus where every join beside a slide is slope-set, between offsets
    /// a round trip rarely returns exactly, so a legacy-path rewrite that moves
    /// one bit of a join's width moves its curve. ⚠️ Captured on the legacy
    /// branch as vf-18 left it (the verbatim pre-vf-18 lines; B1 is the
    /// pre-change capture): B1s guards against the NEXT rewrite.
    static func b1sFuzz(count: Int) -> [PitchEditSet] {
        var rng = Rng(state: 0x0F18_2026_1012_B15E)
        var sets: [PitchEditSet] = []
        for _ in 0..<count {
            var segments: [NoteSegment] = []
            var cursor = rng.uniform(0.05, 0.2)
            func add(_ duration: Double, cents: Double, follow: Double, origin: NoteOrigin) {
                segments.append(note(cursor, cursor + duration, cents: cents, follow: follow, origin: origin))
                cursor += duration // abutting: every join is soft
            }
            add(rng.uniform(0.3, 0.6), cents: rng.uniform(-1200, 1200), follow: 0, origin: .detected)
            for _ in 0..<(2 + Int(rng.next() % 3)) {
                for _ in 0..<(rng.chance(0.3) ? 2 : 1) {
                    add(rng.uniform(0.15, 0.3), cents: rng.uniform(-600, 600),
                        follow: rng.chance(0.5) ? 1 : rng.uniform(0.2, 0.9), origin: .transition)
                }
                add(rng.uniform(0.3, 0.6), cents: rng.uniform(-1200, 1200), follow: 0, origin: .detected)
            }
            // Retune at the engine floor (30 ms) and a gentle slope: a join
            // whose two edge values differ by ~100-700 c is set by the slope.
            let set = PitchEditSet(segments: segments, retuneMs: PitchEditSet.engineMinimumRetuneMs,
                                   transitionSlopeCentsPerSecond: rng.uniform(2000, 6000))
            sets.append(identified(set, tag: 0x2000 + sets.count))
        }
        return sets
    }

    /// How many soft joins in `sets` P6b's rewrite re-widths: the public width
    /// rule fed the legacy edge values (each side's own offset plus g × the
    /// OTHER side's own offset) against the same with that offset sent through
    /// semitones and back.
    static func roundTripSensitiveJoins(_ sets: [PitchEditSet]) -> Int {
        var count = 0
        for set in sets {
            let notes = set.segments.filter(\.entersPitchCurve)
            guard notes.count > 1 else { continue }
            for i in 0..<(notes.count - 1)
            where PitchEditSet.joinKind(leftEndSeconds: notes[i].endSeconds,
                                        rightStartSeconds: notes[i + 1].startSeconds) == .soft {
                let left = notes[i], right = notes[i + 1]
                let legacy = PitchEditSet.softJoin(left: left, right: right, retuneMs: set.retuneMs,
                                                   slopeCentsPerSecond: set.transitionSlopeCentsPerSecond)
                let roundTrip = PitchEditSet.softJoin(
                    left: left, right: right,
                    leftEdgeValueCents: PitchEditSet.slideEdgeValueCents(
                        left, anchorCents: (right.pitchOffsetCents / 100) * 100),
                    rightEdgeValueCents: PitchEditSet.slideEdgeValueCents(
                        right, anchorCents: (left.pitchOffsetCents / 100) * 100),
                    retuneMs: set.retuneMs, slopeCentsPerSecond: set.transitionSlopeCentsPerSecond)
                if legacy != roundTrip { count += 1 }
            }
        }
        return count
    }

    static let b1sCount = 200
    /// Captured 2026-10-12 on the legacy branch as vf-18 left it (see above).
    static let b1sGolden = (sensitive: 55,
                            curve: "9b1c09eca304ce33f60c2faf6d2ac86e4a1583ef53d9cf8d871aadffe142a458",
                            digest: "7b8922c4934d03838d63407af135cc50602ae1cbc3a26b2a7208bd3e98be3c3a")

    @Test("B1s a legacy-rule corpus whose slide joins are all set by the slope keeps its curve and key, so a rewrite of the legacy widths that moves one bit is seen")
    func legacyWidthSensitiveGoldensHold() {
        let sets = Self.b1sFuzz(count: Self.b1sCount)
        let sensitive = Self.roundTripSensitiveJoins(sets)
        let b1Sensitive = Self.roundTripSensitiveJoins(Self.b1Fuzz(count: Self.b1FuzzCount)
                                                       + Self.b1Names.map(Self.b1Set))
        var curves: [UInt8] = []
        var digests: [UInt8] = []
        for set in sets {
            #expect(set.slideFollowRule == .sungAtOpenSide && set.usesSoftJoins)
            curves += Self.curveBytes(set)
            digests += Array(PitchEditSetDigest.hex(set).utf8)
            digests.append(0x0A)
        }
        print("SLFX-B1S| \(sets.count) sets: \(sensitive) joins a semitone round trip re-widths "
              + "(B1's corpus: \(b1Sensitive)); curve \(Self.sha(curves)) digest \(Self.sha(digests))")
        let golden = Self.b1sGolden
        // Positive control first: the corpus still holds the joins P6b moves.
        #expect(sensitive == golden.sensitive && sensitive >= 40,
                "B1s lost the slope-set slide joins a rewrite would move: \(sensitive)")
        #expect(Self.sha(curves) == golden.curve, "a LEGACY-rule B1s curve moved: \(Self.sha(curves))")
        #expect(Self.sha(digests) == golden.digest, "a LEGACY-rule B1s key moved: \(Self.sha(digests))")
    }

    // MARK: - Slot 9: the slide-follow marker (REVIEW §3.2)

    static func withRule(_ set: PitchEditSet, _ rule: PitchEditSet.SlideFollowRule) -> PitchEditSet {
        var out = set
        out.slideFollowRule = rule
        return out
    }

    /// The block the marker appends, restated with LITERALS: "F1OLLOW" + 01,
    /// the hold rule's code 1, version 1. A changed marker, code or version
    /// silently re-keys every hold set, so the restatement does not read them
    /// from DAWEngine.
    static func slideFollowBlock() -> [UInt8] {
        var bytes: [UInt8] = []
        func put(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) } }
        put(0x4631_4F4C_4C4F_5701)
        put(UInt64(bitPattern: 1))
        put(UInt64(bitPattern: 1))
        return bytes
    }

    @Test("slot 9: a hold-rule soft set re-keys by EXACTLY the slide-follow block at the end of slot 9; the legacy key is the old key; a set that is not soft or bends nothing does not re-key")
    func holdRuleRekeysByExactlyTheMarker() {
        #expect(PitchEditSetDigest.slideFollowMarker == 0x4631_4F4C_4C4F_5701)
        let markers: [UInt64] = [PitchEditSetDigest.suffixMarker, PitchEditSetDigest.anchorSuffixMarker,
                                 PitchEditSetDigest.timeWarpSuffixMarker, PitchEditSetDigest.shapeSuffixMarker,
                                 PitchEditSetDigest.levelSuffixMarker, PitchEditSetDigest.originSuffixMarker,
                                 PitchEditSetDigest.formantSuffixMarker, PitchEditSetDigest.consonantSuffixMarker,
                                 PitchEditSetDigest.transitionSuffixMarker, PitchEditSetDigest.slideFollowMarker]
        #expect(Set(markers).count == markers.count, "two digest blocks share a marker")
        for golden in Self.b1Goldens {
            let legacy = Self.b1Set(golden.set)
            #expect(legacy.slideFollowRule == .sungAtOpenSide)
            #expect(PitchEditSetDigest.hex(legacy) == golden.digest)
            #expect(PitchEditSetDigest.hex(legacy) == NaturalTuningTransitionRenderTests.expectedHex(legacy),
                    "'\(golden.set)': the restatement does not reproduce the legacy key")
            let hold = Self.withRule(legacy, .holdAtOpenSide)
            var bytes = NaturalTuningDigestTests.materialBeforeSlot7(hold)
            if hold.engagesFormantCurve { bytes += NaturalTuningDigestTests.formantBlock(hold) }
            bytes += NaturalTuningTransitionRenderTests.transitionBlock(hold) + Self.slideFollowBlock()
            #expect(PitchEditSetDigest.hex(hold) == NaturalTuningDigestTests.sha(bytes),
                    "'\(golden.set)': the hold rule did not re-key by exactly the block")
            #expect(PitchEditSetDigest.hex(hold) != golden.digest)
        }
        // Not soft (no slope, width or follow): the rule renders nothing there
        // and keys nothing.
        let notSoft = PitchCurveRenderTests.c21Set("offset")
        #expect(!notSoft.usesSoftJoins)
        #expect(PitchEditSetDigest.hex(Self.withRule(notSoft, .holdAtOpenSide)) == PitchEditSetDigest.hex(notSoft))
        // Bends nothing: keyless under either rule (a fresh table stays keyless).
        let fresh = Self.withRule(PitchEditSet(segments: Self.b1Set("tailOffMoved").segments.map {
            var note = $0
            note.pitchOffsetCents = 0
            return note
        }, transitionSlopeCentsPerSecond: 3000), .holdAtOpenSide)
        #expect(fresh.isPitchIdentity && PitchEditSetDigest.hex(fresh) == "")
    }

    // MARK: - THE REQUIRED GATE: adoption is inaudible (REVIEW §3.4, the brief)

    /// The render cache's own render (`StretchRenderCache.renderAudio`, the
    /// one render loop, ratio 1) of `set` over the UA-2 phrase.
    static func render(_ set: PitchEditSet) throws -> [Float] {
        try PitchCurveRenderSlideOriginTests.render(set, PitchCurveRenderSlideOriginTests.source(),
                                                    PitchCurveRenderSlideOriginTests.detection())
    }

    /// The editor's own seed of the UA-2 phrase (a lead-in after a breath, a
    /// held A3, a LINK slide, a held E4, a tail-off into silence; every slide
    /// followed), and the indices of its three slides and its two held notes.
    static func editorSeed() throws -> (set: PitchEditSet, slides: [Int], held: [Int]) {
        let seed = PitchNoteTable.detected(from: PitchCurveRenderSlideOriginTests.detection())
        let slides = seed.segments.indices.filter { seed.segments[$0].origin == .transition }
        let held = seed.segments.indices.filter {
            seed.segments[$0].origin == .detected && seed.segments[$0].durationSeconds > 0.4
        }
        try #require(slides.count == 3 && held.count == 2, "the UA-2 phrase changed shape: \(slides) \(held)")
        try #require(slides.allSatisfy { seed.segments[$0].glideFollow == 1 }, "the editor seed stopped following")
        return (seed, slides, held)
    }

    @Test("ADOPTION IS INAUDIBLE: an inert editor table renders the SAME SAMPLES under both rules, before and after a real hand edit adopts the hold rule; only its key moves. Control: a non-inert table renders differently")
    func adoptionIsInaudibleInTheRender() throws {
        let (seed, slides, held) = try Self.editorSeed()
        let untuned = try OfflineStretcher.stretch(input: [PitchCurveRenderSlideOriginTests.source()],
                                                   sampleRate: 48_000, ratio: 1, semitones: 0,
                                                   formantPreserve: false)[0]
        // (a) The link slide moved alone: its neighbours are held, so both
        // rules read the same anchors (inert), yet it bends pitch (renders).
        var linkMoved = seed
        linkMoved.segments[slides[1]].pitchOffsetCents = 100
        #expect(linkMoved.slideFollowRule == .sungAtOpenSide && linkMoved.isSlideFollowRuleInert
                    && !linkMoved.isPitchIdentity)
        let legacyRender = try Self.render(linkMoved)
        let holdRender = try Self.render(Self.withRule(linkMoved, .holdAtOpenSide))
        print("SLFX-ADOPT| (a) inert link +100: legacy \(legacyRender.count) samples sha256 "
              + "\(PitchCurveRenderSlideOriginTests.sha256(legacyRender)), hold sha256 "
              + "\(PitchCurveRenderSlideOriginTests.sha256(holdRender))")
        #expect(PitchCurveRenderSlideOriginTests.firstDifference(legacyRender, holdRender) == nil,
                "adopting the hold rule on an INERT table moved a rendered sample")
        #expect(PitchCurveRenderSlideOriginTests.firstDifference(legacyRender, untuned) != nil,
                "control: the tuned render equals the untuned one, so equal bytes prove nothing")
        let legacyKey = PitchCurveRenderSlideOriginTests.key(linkMoved)
        let holdKey = PitchCurveRenderSlideOriginTests.key(Self.withRule(linkMoved, .holdAtOpenSide))
        #expect(!legacyKey.isEmpty && !holdKey.isEmpty && legacyKey != holdKey,
                "the adoption must re-key once (digest slot 9's marker)")

        // (b) A REAL hand edit on that table (the link to +150 through the
        // drag's own transform) adopts the rule; what it stores renders the
        // same samples as the same notes on the legacy rule.
        let edited = try linkMoved.applyingNotePitchOffsets(
            [NotePitchOffset(segmentId: seed.segments[slides[1]].id, offsetCents: 150)], clipId: UUID())
        #expect(edited.slideFollowRule == .holdAtOpenSide, "the hand edit did not adopt the hold rule")
        let adopted = try Self.render(edited)
        let notAdopted = try Self.render(Self.withRule(edited, .sungAtOpenSide))
        print("SLFX-ADOPT| (b) hand edit link → +150, adopted: sha256 "
              + "\(PitchCurveRenderSlideOriginTests.sha256(adopted)) vs legacy rule "
              + "\(PitchCurveRenderSlideOriginTests.sha256(notAdopted))")
        #expect(PitchCurveRenderSlideOriginTests.firstDifference(adopted, notAdopted) == nil,
                "the adopted edit renders differently from the same notes on the legacy rule")
        #expect(PitchCurveRenderSlideOriginTests.firstDifference(adopted, legacyRender) != nil,
                "control: the edit itself must be audible")

        // (c) POSITIVE CONTROL, or the gate is blind: A3 (the note the lead-in
        // leads into) +100 is NOT inert, and the two rules render different
        // samples (the lead-in reads 0 at its open side, or copies +1 st).
        var anchorMoved = seed
        anchorMoved.segments[held[0]].pitchOffsetCents = 100
        #expect(!anchorMoved.isSlideFollowRuleInert)
        let a = try Self.render(anchorMoved)
        let b = try Self.render(Self.withRule(anchorMoved, .holdAtOpenSide))
        let first = PitchCurveRenderSlideOriginTests.firstDifference(a, b)
        let differing = zip(a, b).filter { $0.bitPattern != $1.bitPattern }.count
        print("SLFX-ADOPT| (c) control A3 +100 (not inert): legacy sha256 "
              + "\(PitchCurveRenderSlideOriginTests.sha256(a)), hold sha256 "
              + "\(PitchCurveRenderSlideOriginTests.sha256(b)); first differing sample \(first ?? -1), "
              + "\(differing) of \(a.count) differ")
        #expect(first != nil && differing > 1000, "the render cannot see the rule: the gate above is blind")
    }

    @Test("the render's own curve: every sung note of the editor seed moved +1200 together lands every followed slide at exactly +12 st (lead-in, link, tail-off); sounds stay")
    func uniformMoveOfTheEditorSeedIsExactInThePlan() throws {
        let (seed, slides, _) = try Self.editorSeed()
        let sung = seed.segments.filter { $0.origin != .unpitched }.map(\.id)
        let moved = try seed.applyingGroupPitchMove(segmentIDs: sung, byCents: 1200, clipId: UUID())
        #expect(moved.set.slideFollowRule == .holdAtOpenSide)
        #expect(Set(moved.carriedSlideIDs) == Set(slides.map { seed.segments[$0].id }))
        #expect(seed.segments.indices.filter { seed.segments[$0].origin == .unpitched }
                    .allSatisfy { moved.set.segments[$0].pitchOffsetCents == 0 }, "a sound moved")
        let plan = try #require(StretchCurvePlan.make(editSet: moved.set, clipPitchShiftSemitones: 0,
                                                      sampleRate: 48_000, ratio: 1))
        for index in slides {
            let slide = moved.set.segments[index]
            for u in [0.25, 0.5, 0.75] {
                let t = slide.startSeconds + u * slide.durationSeconds
                let value = plan.semitones(atOutputFrame: Int((t * 48_000).rounded()))
                #expect(abs(value - 12) < 1e-9, "slide \(index) at u \(u): \(value) st, not +12")
            }
        }
    }
}
