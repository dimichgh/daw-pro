import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// m23-ap C5b-1/C5b-2 (design `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md`
/// §5): the DRAWN pitch shape, heard through the product render.
///
/// Deliberately NOT `@MainActor`: everything here is a pure value or the
/// offline render body.
@Suite("C5b — the drawn pitch shape: model, digest slot 4, render proof")
struct NoteShapeRenderTests {
    static let sampleRate = 48_000.0

    // MARK: - Shape-free fixtures (the byte gates' material)

    static let idA = UUID(uuidString: "C5B00000-0000-4000-8000-00000000000A")!
    static let idB = UUID(uuidString: "C5B00000-0000-4000-8000-00000000000B")!
    static let idC = UUID(uuidString: "C5B00000-0000-4000-8000-00000000000C")!

    /// Every shape-free feature this build has, on three notes: a generator
    /// with a fade and a phase anchor, a retimed note, a level and a clear, a
    /// moved sound, a Voice offset, a join width and a follow, a soft-join
    /// slope and a formant amount.
    static func richShapeFreeSet() -> PitchEditSet {
        PitchEditSet(analysisVersion: 1, segments: [
            NoteSegment(id: idA, startSeconds: 0.25, endSeconds: 0.9,
                        detectedHz: 220, detectedConfidence: 0.9,
                        pitchOffsetCents: -37.5, driftScale: 0.5, vibratoScale: 0.25,
                        vibratoRateHz: 5.5, vibratoDepthCents: 40, vibratoOnsetSeconds: 0.2,
                        vibratoPhaseAnchorSeconds: 0.5, formantOffsetSemitones: -1.5,
                        amplitudeDb: -3, transitionOutMs: 120),
            NoteSegment(id: idB, startSeconds: 0.9, endSeconds: 1.5,
                        detectedHz: 233.08, detectedConfidence: 0.81,
                        pitchOffsetCents: 22, timeEndDeltaSeconds: 0.05,
                        glideFollow: 1, isCleared: true),
            NoteSegment(id: idC, startSeconds: 1.6, endSeconds: 1.9,
                        detectedHz: 233.08, detectedConfidence: 0.4,
                        pitchOffsetCents: 150, origin: .unpitched),
        ], retuneMs: 45, formantCorrection: 1,
           transitionSlopeCentsPerSecond: PitchEditSet.defaultTransitionSlope)
    }

    /// One moved note: the plainest set that renders through the curve.
    static func offsetSet() -> PitchEditSet {
        PitchEditSet(analysisVersion: 1, segments: [
            NoteSegment(id: idA, startSeconds: 0.2, endSeconds: 1.8,
                        detectedHz: 220, detectedConfidence: 0.9, pitchOffsetCents: 50),
        ], retuneMs: 45)
    }

    /// A generator with a fade and a phase anchor, beside a plain move.
    static func generatorSet() -> PitchEditSet {
        PitchEditSet(analysisVersion: 1, segments: [
            NoteSegment(id: idA, startSeconds: 0.2, endSeconds: 1.0,
                        detectedHz: 220, detectedConfidence: 0.9, pitchOffsetCents: -20,
                        vibratoRateHz: 5.5, vibratoDepthCents: 40, vibratoOnsetSeconds: 0.2,
                        vibratoPhaseAnchorSeconds: 0.6),
            NoteSegment(id: idB, startSeconds: 1.0, endSeconds: 1.8,
                        detectedHz: 220, detectedConfidence: 0.9, pitchOffsetCents: 30),
        ], retuneMs: 45)
    }

    /// Two abutting notes at the editor seed's slope: soft joins (slot 9).
    static func softJoinSet() -> PitchEditSet {
        PitchEditSet(analysisVersion: 1, segments: [
            NoteSegment(id: idA, startSeconds: 0.2, endSeconds: 1.0,
                        detectedHz: 220, detectedConfidence: 0.9, pitchOffsetCents: 100),
            NoteSegment(id: idB, startSeconds: 1.0, endSeconds: 1.8,
                        detectedHz: 220, detectedConfidence: 0.9, pitchOffsetCents: -50,
                        glideFollow: 0.5),
        ], retuneMs: 45, transitionSlopeCentsPerSecond: PitchEditSet.defaultTransitionSlope)
    }

    /// A retimed note (slot 3) and a levelled one (slot 5).
    static func retimedLevelSet() -> PitchEditSet {
        PitchEditSet(analysisVersion: 1, segments: [
            NoteSegment(id: idA, startSeconds: 0.2, endSeconds: 1.0,
                        detectedHz: 220, detectedConfidence: 0.9, pitchOffsetCents: 40,
                        timeEndDeltaSeconds: 0.08),
            NoteSegment(id: idB, startSeconds: 1.1, endSeconds: 1.8,
                        detectedHz: 220, detectedConfidence: 0.9, amplitudeDb: -6),
        ], retuneMs: 45)
    }

    static var namedShapeFreeSets: [(name: String, set: PitchEditSet)] {
        [("rich", richShapeFreeSet()), ("offset", offsetSet()), ("generator", generatorSet()),
         ("soft", softJoinSet()), ("retimedLevel", retimedLevelSet())]
    }

    /// The source every render here reads: 2 s of the physics voice at
    /// f0 220 Hz (`SourceFilterVoice`, a pulse train through formants).
    static func source() -> [Float] {
        SourceFilterVoice.voice(f0Hz: 220, frames: Int(2 * sampleRate), sampleRate: sampleRate)
    }

    /// THE PRODUCT: `StretchRenderCache.renderAudio`, whole file, ratio 1,
    /// no clip transpose, no contour (a shape needs none).
    static func productRender(_ source: [Float], set: PitchEditSet)
        throws -> (samples: [Float], path: StretchRenderCache.RenderPath) {
        var whole = [source]
        let params = StretchRenderCache.Params(ratio: 1, semitones: 0,
                                               formantPreserve: false, pitchEdits: set)
        let out = try StretchRenderCache.renderAudio(
            whole: &whole, window: nil, sampleRate: sampleRate, params: params,
            curveContour: nil, isCancelled: { false })
        return (out.output.planar[0], out.path)
    }

    static func sortedJSON(_ set: PitchEditSet) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(set)
    }

    static func sha(_ bytes: [UInt8]) -> String { PitchCurveRenderTests.c21SHA(bytes) }

    // MARK: - (A) The byte gates: shape-free sets are untouched

    /// CAPTURED FROM THE TREE BEFORE C5b-1 (2026-09-26 00:08, lane C5b12,
    /// `logs/capture-6.log`): a capture-only version of this test, compiled
    /// against `Sources/` with no shape API, printed these. SHA-256 of the
    /// sorted-key JSON, the render digest, and SHA-256 of the product
    /// render's samples (`SpanRenderSignals.sha256`). A transposer change
    /// moves the render rows like every other render golden, and they are
    /// re-pinned the same way; nothing else may move them.
    static let capturedBeforeC5b: [String: String] = [
        "encode rich": "870ba4960b56cca25853f08030e4c9bd732d2e636c02365bdc6f089b58fffa71",
        "digest rich": "f4c753489aaf557a9e84127f6d47afaca4e9bbacf0cd5320b67dc93278106c07",
        "encode offset": "6dc59ba5da0f9e593fadd1558bda701e26b9ab0afa9efdec0e6c85708a1b8572",
        "digest offset": "2ff94169f9efb30152b8089e41e492d7583bd9f065a3e53cbc739ca2019c4329",
        "encode generator": "c7d760e1ef4ca5c2809ac1047e7ef1d483df0a301e0b8021f1bcad07b93b1fb2",
        "digest generator": "89a2b58738fd8a7d11bd107bf34b60875f4aaa773f4a1929a7be20bcc8856de5",
        "encode soft": "a9f62e65fc2f6b72f1bbae6c2201f5ac000ff25973f4d1f868ab646ae629499f",
        "digest soft": "020f5ce8156478a510b36102895cc74836825a688efc2668329383d12ce25600",
        "encode retimedLevel": "48dbb88c93555bebdef01dfc786a2a031be4bb51c678180c7bcc31a28e0c1dbe",
        "digest retimedLevel": "f9f465f0c99c4aadc4694ad0a86e3bfde21c26141367d8a0bbac583c15f5a993",
        "render offset": "f5ca0e3730a11239e364fc027665af43d9795c4a9099bc69fa19c341af5867a0",
        "render generator": "010901d0b99753fcf206fffc0e969da79ac04e2733e0b6588a5245fa494f28bb",
        "render soft": "c6a351158555b471fab70211ca430dfb33c2a33e30fd5a0990a0fc9321aaf36b",
        "render retimedLevel": "b5ceafe80677df31b4d8c03eb3d3a117ea4b8f720654e455fb5dcc1234ce945b",
    ]

    /// NT-F220 (W7-F220I, 2026-09-27): "rich" is the one ENGAGED set above (a
    /// formant amount), so `formantRenderVersion` 2 → 3 re-keyed it. CAPTURED
    /// on the patched tree by W7-F220I's scratch pre-flight (a capture-only
    /// print; `restated == hex` was false for this set at version 2, so the
    /// patch preamble's fallback applies). Never regenerate it: a later bump
    /// captures its own key beside this one.
    static let capturedAtFormantVersion3: [String: String] = [
        "digest rich": "426b5dba4270c6db0eafd97ec4176e84976cec0230cdac796fa6976f15229b7c",
    ]

    /// ⭐ THE BYTE GATE. For every shape-free set, the saved JSON, the render
    /// digest and the product render are the bytes they were before the
    /// shape existed. So every project re-saves byte for byte, every cache
    /// entry on every disk keeps its key, and no clip sounds different.
    @Test("BYTE GATE: shape-free sets encode, digest and render exactly as captured before C5b-1")
    func shapeFreeBytesAreUnchanged() throws {
        let voice = Self.source()
        for (name, set) in Self.namedShapeFreeSets {
            let anyShape = set.segments.contains { $0.hasShape }
            #expect(!anyShape)
            let json = try Self.sortedJSON(set)
            #expect(!String(decoding: json, as: UTF8.self).contains("shape"),
                    "'\(name)' wrote a shape key with no shape")
            #expect(Self.sha(Array(json)) == Self.capturedBeforeC5b["encode \(name)"],
                    "'\(name)' no longer saves the bytes it saved before C5b-1")
            if set.engagesFormantCurve {
                // "rich" carries a formant amount, so NT-F220 (formantRenderVersion 3,
                // vendored patch 0004) re-keyed it through slot 7. The restatement
                // (`NaturalTuningConsonantDigestTests.expectedHex`) does NOT cover this
                // set: measured by W7-F220I on the tree before the bump, it restates
                // 70501ab4… against the key f4c75348…. So both keys are CAPTURES,
                // pinned and never regenerated: version 2 is `capturedBeforeC5b`
                // (re-captured before the bump, equal: the positive control), version
                // 3 is `capturedAtFormantVersion3` (captured after it).
                #expect(PitchEditSet.formantRenderVersion == 3,
                        "'\(name)': its version-3 capture holds only at formantRenderVersion 3")
                #expect(PitchEditSetDigest.hex(set) == Self.capturedAtFormantVersion3["digest \(name)"],
                        "'\(name)' re-keyed, but not to its version-3 capture")
                #expect(PitchEditSetDigest.hex(set) != Self.capturedBeforeC5b["digest \(name)"],
                        "'\(name)' kept its version-2 key: the formant version did not reach slot 7")
            } else {
                #expect(PitchEditSetDigest.hex(set) == Self.capturedBeforeC5b["digest \(name)"],
                        "'\(name)' re-keyed: every cache entry for it is orphaned")
            }
        }
        for (name, set) in Self.namedShapeFreeSets where name != "rich" {
            let render = try Self.productRender(voice, set: set)
            #expect(render.path == .curve)
            #expect(SpanRenderSignals.sha256([render.samples]) == Self.capturedBeforeC5b["render \(name)"],
                    "'\(name)' renders different audio than before C5b-1")
        }
    }

    // MARK: - (B) The digest's shape block, slot 4

    /// The block §5.4 specifies, as the orchestrator's brief amended it (per
    /// SHAPED segment, with its index), restated here rather than read from
    /// `PitchEditSetDigest`: the marker ("S1HAPES" + 01, a literal, because
    /// changing it would re-key every shaped render), the version, the
    /// number of shaped segments, then per shaped segment its index, start,
    /// count and every sample. `version` is a parameter so a bump can be
    /// proven to re-key.
    static func shapeBlock(_ set: PitchEditSet,
                           version: Int = NoteSegment.shapeRenderVersion) -> [UInt8] {
        var bytes: [UInt8] = []
        func putInt(_ value: Int) {
            withUnsafeBytes(of: UInt64(bitPattern: Int64(value)).littleEndian) {
                bytes.append(contentsOf: $0)
            }
        }
        withUnsafeBytes(of: UInt64(0x5331_4841_5045_5301).littleEndian) {
            bytes.append(contentsOf: $0)
        }
        putInt(version)
        let shaped = set.segments.indices.filter { !set.segments[$0].shapeTenthsOfCents.isEmpty }
        putInt(shaped.count)
        for index in shaped {
            let segment = set.segments[index]
            putInt(index)
            putInt(segment.shapeStartIndex)
            putInt(segment.shapeTenthsOfCents.count)
            for sample in segment.shapeTenthsOfCents { putInt(Int(sample)) }
        }
        return bytes
    }

    typealias Legacy = PitchCurveRenderTests

    /// The drawn shape over note A of `offsetSet`: a plateau with ramps.
    static func shapedOffsetSet() -> PitchEditSet {
        var set = offsetSet()
        set.segments[0].shapeStartIndex = 80
        set.segments[0].shapeTenthsOfCents = [0, 100, 250, 250, 250, 100, 0]
        return set
    }

    @Test("digest: a shaped set is keyed by EXACTLY its pre-C5b material plus the shape block")
    func shapeRekeysByExactlyTheBlock() {
        #expect(PitchEditSetDigest.shapeSuffixMarker == 0x5331_4841_5045_5301)
        #expect(NoteSegment.shapeRenderVersion == 1,
                "a version bump re-keys every shaped render: make it on purpose, then move this pin")
        let markers: Set<UInt64> = [
            PitchEditSetDigest.suffixMarker, PitchEditSetDigest.anchorSuffixMarker,
            PitchEditSetDigest.timeWarpSuffixMarker, PitchEditSetDigest.shapeSuffixMarker,
            PitchEditSetDigest.levelSuffixMarker, PitchEditSetDigest.originSuffixMarker,
            PitchEditSetDigest.formantSuffixMarker, PitchEditSetDigest.consonantSuffixMarker,
            PitchEditSetDigest.transitionSuffixMarker,
        ]
        #expect(markers.count == 9, "the shape marker collides with another block's marker")

        let plain = Self.offsetSet()
        let shaped = Self.shapedOffsetSet()
        #expect(PitchEditSetDigest.hex(plain) == Self.capturedBeforeC5b["digest offset"])
        #expect(PitchEditSetDigest.hex(shaped)
                == Self.sha(Legacy.c21PreC2Material(shaped) + Self.shapeBlock(shaped)),
                "a shaped set re-keyed, but not by exactly the shape block")
        #expect(PitchEditSetDigest.hex(shaped) != PitchEditSetDigest.hex(plain))

        // A SHAPE-ONLY set (no offset at all) is keyed too: a shape alone is
        // not identity, so it cannot hash to "".
        var shapeOnly = shaped
        shapeOnly.segments[0].pitchOffsetCents = 0
        #expect(!shapeOnly.isIdentity)
        #expect(PitchEditSetDigest.hex(shapeOnly)
                == Self.sha(Legacy.c21PreC2Material(shapeOnly) + Self.shapeBlock(shapeOnly)))

        // The version sits inside the block: a bump re-keys shaped sets only.
        let version = NoteSegment.shapeRenderVersion
        #expect(PitchEditSetDigest.hex(shaped)
                != Self.sha(Legacy.c21PreC2Material(shaped)
                            + Self.shapeBlock(shaped, version: version + 1)))
        // Restore is exact: removing the shape is the pre-shape key, bit for bit.
        var removed = shaped
        removed.segments[0].shapeTenthsOfCents = []
        removed.segments[0].shapeStartIndex = 0
        #expect(PitchEditSetDigest.hex(removed) == Self.capturedBeforeC5b["digest offset"])
    }

    /// Slot order: generator (inside the material), time warp (3), SHAPE (4),
    /// level (5), origin (6). A block out of its slot re-keys every set that
    /// uses two of these features (the digest banner's rule).
    @Test("digest: the shape block sits in slot 4, after the time-warp block and before the level block")
    func shapeBlockIsInSlotFour() {
        var everything = Legacy.c21Set("generator")
        everything.segments[0].shapeStartIndex = 40
        everything.segments[0].shapeTenthsOfCents = [0, 300, 600, 300, 0]
        everything.segments[1].timeStartDeltaSeconds = 0.02
        everything.segments[1].shapeStartIndex = 150
        everything.segments[1].shapeTenthsOfCents = [-200, -100]
        everything.segments[0].isCleared = true
        everything.segments.append(NoteSegment(
            id: Legacy.uaIdSoundLong, startSeconds: 1.95, endSeconds: 2.2, detectedHz: 220,
            detectedConfidence: 0.4, pitchOffsetCents: 300, origin: .unpitched))
        #expect(everything.hasTimeEdits && everything.hasLevelEdits)
        #expect(!everything.engagesFormantCurve && !everything.usesSoftJoins)
        #expect(PitchEditSetDigest.hex(everything)
                == Self.sha(Legacy.c21PreC2Material(everything) + Legacy.c21WarpBlock()
                            + Self.shapeBlock(everything) + Legacy.i7aLevelBlock(everything)
                            + Legacy.uaOriginBlock(everything)),
                "the shape block is not in slot 4, between the time-warp and level blocks")
    }

    /// Design §5.4 `digestCoversEveryShapeSample`: the census above can see
    /// only LABELS, so this moves the digest by every kind of sample edit on
    /// three shaped notes. Plant (design §5.8, mode 2): hash only the count.
    @Test("digest: every sample, every start and every sample moved between notes re-keys")
    func digestCoversEveryShapeSample() {
        let ids = (1...3).map { UUID(uuidString: "C5B20000-0000-4000-8000-00000000000\($0)")! }
        func set(_ shapes: [(start: Int, samples: [Int16])]) -> PitchEditSet {
            PitchEditSet(segments: (0..<3).map { index in
                NoteSegment(id: ids[index], startSeconds: 0.5 + Double(index) * 0.5,
                            endSeconds: 1.0 + Double(index) * 0.5, detectedHz: 220,
                            detectedConfidence: 0.9, shapeStartIndex: shapes[index].start,
                            shapeTenthsOfCents: shapes[index].samples)
            })
        }
        let base: [(start: Int, samples: [Int16])] = [
            (50, [0, 10, 20, 30, 20, 10, 0]),
            (100, [5, 15, 25, 35, 25, 15, 5]),
            (150, [-7, -17, -27, -37, -27, -17, -7]),
        ]
        let reference = PitchEditSetDigest.hex(set(base))
        #expect(!reference.isEmpty)
        var seen: Set<String> = [reference]
        var edits = 0
        func expectRekeys(_ shapes: [(start: Int, samples: [Int16])], _ what: String) {
            let hex = PitchEditSetDigest.hex(set(shapes))
            #expect(hex != reference, "\(what) left the digest unchanged: stale audio")
            seen.insert(hex)
            edits += 1
        }
        for note in 0..<3 {
            for position in [0, 3, 6] {
                var shapes = base
                shapes[note].samples[position] += 1
                expectRekeys(shapes, "+1 tenth at sample \(position) of note \(note)")
            }
            var moved = base
            moved[note].start += 1
            expectRekeys(moved, "moving note \(note)'s shape by one grid step")
        }
        // One sample moved from note 0's end to note 1's start: the TOTAL
        // count is unchanged, only the boundary between the notes moved.
        var across = base
        let last = across[0].samples.removeLast()
        across[1].samples.insert(last, at: 0)
        across[1].start -= 1
        expectRekeys(across, "moving one sample from note 0 to note 1")
        #expect(seen.count == edits + 1, "two different edits produced the same key")
    }

    // MARK: - (C) The render key and the bypass

    /// A shape needs no contour (§5.2): a shape-only set keys WITHOUT
    /// `contour:`/`shaping:`, so it renders the same whether or not detection
    /// is available, and its resolved key IS its legacy key.
    @Test("key: a shape-only set carries no contour: part; the render takes the curve, not the bypass")
    func shapeKeyCarriesNoContour() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("c5b12-key-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var shapeOnly = Self.shapedOffsetSet()
        shapeOnly.segments[0].pitchOffsetCents = 0
        shapeOnly.analysisVersion = PitchContourCache.Detector.product.analysisVersion
        #expect(!shapeOnly.needsDetectedContour)
        let params = StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false,
                                               pitchEdits: shapeOnly)
        #expect(!params.isIdentity, "a shape-only clip took the identity bypass")
        #expect(params.pitchEditSetHash == PitchEditSetDigest.hex(shapeOnly))
        let keys = try StretchRenderCache.renderKeys(source: url, params: params, detector: .product)
        #expect(keys.resolved == keys.legacy, "a shape-only render keyed on the contour")
        #expect(StretchCurvePlan.make(editSet: shapeOnly, clipPitchShiftSemitones: 0,
                                      sampleRate: Self.sampleRate, ratio: 1) != nil)
        // Positive control: a flattened set DOES key on the contour, so the
        // equality above is a finding, not a key builder that never appends.
        var flattened = shapeOnly
        flattened.segments[0].driftScale = 0
        let flattenedKeys = try StretchRenderCache.renderKeys(
            source: url, params: StretchRenderCache.Params(ratio: 1, semitones: 0,
                                                           formantPreserve: false,
                                                           pitchEdits: flattened),
            detector: .product)
        #expect(flattenedKeys.resolved != flattenedKeys.legacy)
    }

    // MARK: - (D) THE RENDER PROOF (C5b-2)

    /// The shaped note: [0.2, 1.8] s, detected at the source's own 220 Hz, no
    /// offset, and a drawing over its whole grid span (indices 20...179):
    /// 0 outside, a 50 ms ramp up from 0.75 s, +50 c on the plateau
    /// [0.80, 1.20] s, a 50 ms ramp down to 0 at 1.25 s. `plateauTenths` 0
    /// is the TWIN: the same note with an all-zero drawing, which is still a
    /// shape, so both render through the curve and differ ONLY in the term.
    static func renderProofSet(plateauTenths: Int16) -> PitchEditSet {
        let start = 20
        let samples: [Int16] = (start...179).map { index in
            let t = Double(index) / NoteSegment.shapeGridHz
            let rise = ((t - 0.75) / 0.05).clamped(to: 0...1)
            let fall = ((1.25 - t) / 0.05).clamped(to: 0...1)
            return Int16((Double(plateauTenths) * min(rise, fall)).rounded())
        }
        return PitchEditSet(analysisVersion: 1, segments: [
            NoteSegment(id: idA, startSeconds: 0.2, endSeconds: 1.8, detectedHz: 220,
                        detectedConfidence: 0.9, shapeStartIndex: start,
                        shapeTenthsOfCents: samples),
        ], retuneMs: 45)
    }

    /// YIN over a 4096-frame window centred at `second`, Hz.
    static func yin(_ x: [Float], at second: Double) -> Double? {
        let centre = Int(second * sampleRate)
        return I1Signals.yinHz(x[(centre - 2_048)..<(centre + 2_048)],
                               sampleRate: sampleRate, minHz: 80, maxHz: 700)
    }

    static func cents(_ x: [Float], over y: [Float], at second: Double) -> Double {
        guard let a = yin(x, at: second), let b = yin(y, at: second) else { return .nan }
        return 1200 * log2(a / b)
    }

    /// ⭐⭐ THE PROOF THAT A DRAWING IS HEARD. Through THE PRODUCT
    /// (`StretchRenderCache.renderAudio`, as NT-E1b's product gate renders),
    /// a +50 c drawing over [0.80, 1.20] s of one note comes back at
    /// +50 ± 5 c there, measured by an independent YIN against the twin; and
    /// outside the drawing nothing moves: the twin and the shaped render
    /// agree to 1 c at points ≥ 150 ms from the ramps, and every frame before
    /// the first chunk `RenderDiff` says can differ is bit-identical (which is
    /// also the proof that `RenderDiff` sees the term through the plan).
    @Test("RENDER: +50 c drawn over part of a note is heard at +50 ± 5 c there, and nothing moves outside it")
    func drawnShapeIsHeard() throws {
        let voice = Self.source()
        let shapedSet = Self.renderProofSet(plateauTenths: 500)
        let twinSet = Self.renderProofSet(plateauTenths: 0)
        #expect(shapedSet.segments[0].hasShape && twinSet.segments[0].hasShape)
        #expect(shapedSet.segments[0].shapeTenthsOfCents.count == 160)
        let shapedRender = try Self.productRender(voice, set: shapedSet)
        let twinRender = try Self.productRender(voice, set: twinSet)
        #expect(shapedRender.path == .curve && twinRender.path == .curve)

        // The renders go to disk as Float32 WAVs and every measurement below
        // reads them back from the FILES, as a listener's player would.
        let dir = try I1Signals.tempDir("c5b12-drawn-shape")
        defer { try? FileManager.default.removeItem(at: dir) }
        let shapedURL = dir.appendingPathComponent("shaped.wav")
        let twinURL = dir.appendingPathComponent("twin.wav")
        try I1Signals.write([shapedRender.samples], sampleRate: Self.sampleRate, to: shapedURL)
        try I1Signals.write([twinRender.samples], sampleRate: Self.sampleRate, to: twinURL)
        let shapedFile = try I1Signals.read(shapedURL)
        let twinFile = try I1Signals.read(twinURL)
        #expect(shapedFile.sampleRate == Self.sampleRate && twinFile.sampleRate == Self.sampleRate)
        let shaped = try #require(shapedFile.planar.first)
        let twin = try #require(twinFile.planar.first)
        #expect(shaped == shapedRender.samples && twin == twinRender.samples,
                "the WAV files do not hold the renders")
        #expect(shaped.count == voice.count && twin.count == voice.count)
        // NaN, infinity and clipping guards: the drawing must not break the audio.
        let allFinite = shaped.allSatisfy { $0.isFinite }
        #expect(allFinite, "the shaped render carries a NaN or an infinity")
        let peak = shaped.reduce(Float(0)) { max($0, abs($1)) }
        #expect(peak > 0.01 && peak < 1, "the shaped render peaks at \(peak)")

        // Instrument control: the twin (0 c everywhere) reads the source.
        for second in [0.5, 1.0, 1.5] {
            let control = Self.cents(twin, over: voice, at: second)
            #expect(abs(control) < 1, "the twin reads \(control) c off the source at \(second) s")
        }
        var inside: [Double] = []
        for second in [0.9, 1.0, 1.1] {
            let reading = Self.cents(shaped, over: twin, at: second)
            inside.append(reading)
            #expect(abs(reading - 50) <= 5,
                    "at \(second) s the drawing came back at \(reading) c, not +50 ± 5")
        }
        var outside: [Double] = []
        for second in [0.4, 0.55, 1.45, 1.6] {
            let reading = Self.cents(shaped, over: twin, at: second)
            outside.append(reading)
            #expect(abs(reading) < 1, "at \(second) s, outside the drawing, the pitch moved \(reading) c")
        }
        print("C5B12 render proof: inside \(inside) c, outside \(outside) c")

        // RenderDiff, UNEDITED, sees the term (it diffs the evaluated plan).
        func side(_ set: PitchEditSet) -> RenderDiff.Side {
            RenderDiff.Side(params: StretchRenderCache.Params(ratio: 1, semitones: 0,
                                                              formantPreserve: false,
                                                              pitchEdits: set),
                            curveContour: nil)
        }
        let extent = try RenderDiff.extent(old: side(twinSet), new: side(shapedSet),
                                           sourceFrames: voice.count, channels: 1,
                                           sampleRate: Self.sampleRate).get()
        let first = try #require(extent.firstDifferingFrame, "RenderDiff saw no difference")
        #expect(extent.prefixExact)
        #expect(first > Int(0.5 * Self.sampleRate) && first < Int(0.75 * Self.sampleRate),
                "the first differing frame \(first) is not just before the drawing's ramp")
        let last = try #require(extent.pitchRanges.last?.upperBound)
        #expect(last < Int(1.4 * Self.sampleRate),
                "RenderDiff says the transposes differ up to frame \(last), past the drawing")
        let differingPrefix = zip(shaped[..<first], twin[..<first])
            .filter { $0.0.bitPattern != $0.1.bitPattern }.count
        #expect(differingPrefix == 0,
                "\(differingPrefix) frames before RenderDiff's first differing frame \(first) differ")
        print("C5B12 RenderDiff: first differing frame \(first), last pitch frame \(last), "
              + "ranges \(extent.pitchRanges)")
    }
}
