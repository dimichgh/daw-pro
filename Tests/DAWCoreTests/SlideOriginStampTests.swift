import Foundation
import Testing
@testable import DAWCore

// UA-2 (unpitched-notes design §1.4 U2, amended by natural tuning R14/§4 and
// R29; F-S2 in §1.10): both note builders stamp `origin: .transition` on every
// segment built from a `.transition` part. `.held` stays `.detected`, and a
// sound stays `.unpitched`. Pure types only, so this suite is NOT
// `@MainActor`. The split leg is in `PitchCorrectionWriterTests`, and the
// RENDER half of "the stamp bends nothing" is `PitchCurveRenderSlideOriginTests`.

@Suite("UA-2: sung slides are stamped .transition by both builders, and the stamp bends nothing")
struct SlideOriginStampTests {

    // MARK: - Fixture

    /// One phrase with a slide in each of the three places one can sit
    /// (p2-seg §3). It has a quiet floor and a breath (a SOUND), then a
    /// 12-frame LEAD-IN into A3 + 20 c and a held note. Next come a 12-frame
    /// LINK up to E4 + 20 c and a second held note. It ends with a 9-frame
    /// TAIL-OFF (one frame over the scoop limit) and the floor again, which
    /// is the splitter's `T H T H T`. The slopes are the splitter suite's own
    /// proven shapes (`PitchNoteSplitterTests`: 58 c and 60 c per frame).
    ///
    /// ⚠️ The tail-off (0.144 s) and the 12-frame slides (0.192 s) are all
    /// shorter than Gentle's 200 ms ramp, so their half-ramps are clamped below
    /// their neighbours'. That is the unequal-ramp case, where an identity
    /// segment that LEFT the curve would move its neighbour's correction
    /// (design §1.6). So the curve-neutrality leg below can fail: stamping a
    /// slide `.unpitched` takes it out of the curve and moves Gentle's curve.
    static func phrase() -> PitchDetectionResult {
        let rate = 62.5
        let baseHz = 220 * pow(2, 20.0 / 1200)
        var frames: [ClipPitchFrame] = []
        func push(_ hz: Double?, confidence: Double, dbfs: Double) {
            frames.append(ClipPitchFrame(timeSeconds: Double(frames.count) / rate, frequencyHz: hz,
                                         confidence: confidence, levelDbfs: dbfs,
                                         absence: hz == nil ? .belowConfidence : nil))
        }
        func floor(_ count: Int) { for _ in 0..<count { push(nil, confidence: 0.2, dbfs: -60) } }
        func sung(_ cents: [Double]) {
            for c in cents { push(baseHz * pow(2, c / 1200), confidence: 0.95, dbfs: -20) }
        }
        floor(40)
        for _ in 0..<8 { push(nil, confidence: 0.5, dbfs: -30) }   // the breath: a sound
        sung((1...12).map { -720 + 58 * Double($0) })              // lead-in
        sung(Array(repeating: 0, count: 30))                       // A3 + 20 c
        sung((1...12).map { 58 * Double($0) })                     // link
        sung(Array(repeating: 700, count: 30))                     // E4 + 20 c
        sung((1...9).map { 700 - 60 * Double($0) })                // tail-off
        floor(50)
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: Double(voiced) / Double(frames.count),
            frameRateHz: rate, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: Double(frames.count) / rate,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

    static func parts(_ result: PitchDetectionResult) -> [NotePart] {
        PitchNoteSplitter.parts(in: result.frames, frameRateHz: result.frameRateHz, onsetSeconds: [])
    }

    /// The origin each segment should carry. It is restated from the design's
    /// words, not called from the product: the kind of the part that starts
    /// where the segment starts, bit for bit (both builders map parts one to
    /// one), or `.unpitched` for a segment no part starts at (a sound).
    static func expectedOrigins(_ set: PitchEditSet, parts: [NotePart]) -> [NoteOrigin] {
        set.segments.map { segment in
            guard let part = parts.first(where: {
                $0.startSeconds.bitPattern == segment.startSeconds.bitPattern
            }) else { return .unpitched }
            switch part.kind {
            case .held: return .detected
            case .transition: return .transition
            }
        }
    }

    /// Every table the two builders make from `result`: the editor seed, and
    /// each preset under each slide shape.
    static func everyBuiltTable(_ result: PitchDetectionResult) -> [(label: String, set: PitchEditSet)] {
        var tables: [(String, PitchEditSet)] = [("editor seed", PitchNoteTable.detected(from: result))]
        for preset in PitchCorrectionPreset.allCases {
            for shape in PitchSlideShape.allCases {
                tables.append(("\(preset.rawValue)/\(shape.rawValue)",
                               PitchAutoCorrect.editSet(from: result, options: preset.options(),
                                                        slideShape: shape)))
            }
        }
        return tables
    }

    /// The same set as the builders wrote it BEFORE UA-2: every `.transition`
    /// read back as `.detected`. `origin` is a `let`, so it is un-stamped by the
    /// type's own `Codable` (the `reidentified` technique): the key is dropped,
    /// and every other field is carried, including one added tomorrow.
    static func unstamped(_ set: PitchEditSet) throws -> PitchEditSet {
        set.withSegments(try set.segments.map { segment in
            guard segment.origin == .transition else { return segment }
            var object = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(segment)) as? [String: Any])
            try #require(object.removeValue(forKey: "origin") as? String == "transition")
            return try JSONDecoder().decode(NoteSegment.self,
                                            from: JSONSerialization.data(withJSONObject: object))
        })
    }

    // MARK: - The stamp

    @Test("both builders stamp .transition on exactly the slide parts: the editor seed, and every preset in every slide shape")
    func bothBuildersStampEverySlide() throws {
        let result = Self.phrase()
        let parts = Self.parts(result)
        // Positive control: the fixture really has a slide in all three places,
        // or every leg below would pass on nothing.
        try #require(parts.map(\.kind) == [.transition, .held, .transition, .held, .transition],
                     "\(parts.map { "\($0.kind)/\($0.frameCount)" })")
        for (label, set) in Self.everyBuiltTable(result) {
            #expect(set.segments.map(\.origin) == Self.expectedOrigins(set, parts: parts),
                    "\(label): \(set.segments.map(\.origin))")
            #expect(set.segments.filter { $0.origin == .transition }.count == 3,
                    "\(label): a slide was not stamped")
            #expect(set.segments.filter { $0.origin == .unpitched }.count == 1,
                    "\(label): positive control, the breath is a sound")
        }
        // The report variants build the same origins as the plain builders.
        #expect(PitchNoteTable.build(from: result).editSet.segments.map(\.origin)
                    == PitchNoteTable.detected(from: result).segments.map(\.origin))
        let options = PitchAutoCorrectOptions()
        #expect(PitchAutoCorrect.build(from: result, options: options).editSet.segments.map(\.origin)
                    == PitchAutoCorrect.editSet(from: result, options: options).segments.map(\.origin))
    }

    // MARK: - origin and partKinds agree (R29)

    @Test("origin agrees with partKinds: the editor seed follows exactly the segments stamped .transition; presets stamp the slide and keep glideFollow 0")
    func originAgreesWithPartKinds() throws {
        let result = Self.phrase()
        let seed = PitchNoteTable.detected(from: result)
        // `partKinds` is transient, so its only trace on a stored table is the
        // `glideFollow` 1 that `seeded` writes on each `.transition` part. That
        // trace and the stored origin must name the same segments.
        try #require(seed.segments.filter { $0.glideFollow == 1 }.count == 3,
                     "positive control: the editor seed follows its three slides")
        for segment in seed.segments {
            #expect((segment.glideFollow == 1) == (segment.origin == .transition),
                    "origin \(segment.origin) with glideFollow \(segment.glideFollow)")
        }
        // Origin is a detection fact, not an edit: the seed still bends nothing.
        #expect(seed.isIdentity && seed.segments.allSatisfy { !$0.isEdited })
        // Presets pass no part kinds (the (a-T) ruling keeps slides AS SUNG), so
        // the stamp is their only mark of a slide.
        for preset in PitchCorrectionPreset.allCases {
            let set = PitchAutoCorrect.editSet(from: result, options: preset.options())
            #expect(set.segments.filter { $0.origin == .transition }.count == 3, "\(preset)")
            #expect(set.segments.allSatisfy { $0.glideFollow == 0 }, "\(preset) tilted a slide")
        }
    }

    // MARK: - The stamp bends nothing (the curve half)

    @Test("the stamp bends nothing: each table's curve is bit-identical with and without it, and origin is the only field it changed")
    func stampIsCurveNeutral() throws {
        let result = Self.phrase()
        var tables = Self.everyBuiltTable(result).filter { $0.label != "editor seed" }
        // The editor seed with one held note moved, so its curve is not flat.
        var seed = PitchNoteTable.detected(from: result)
        let held = try #require(seed.segments.firstIndex {
            $0.origin == .detected && $0.endSeconds - $0.startSeconds > 0.4
        })
        seed.segments[held].pitchOffsetCents = 100
        tables.append(("edited editor seed", seed))
        let end = result.windowDurationSeconds
        for (label, set) in tables {
            let plain = try Self.unstamped(set)
            try #require(set.segments.filter { $0.origin == .transition }.count == 3,
                         "\(label): positive control, there are slides to un-stamp")
            #expect(!plain.segments.contains { $0.origin == .transition })
            // The un-stamp changed origin and nothing else (so the comparison
            // below compares the stamp and only the stamp).
            for (a, b) in zip(set.segments, plain.segments) {
                let d = PrePitchNoteSplitReference.differingFields(a, b)
                #expect(d.compared >= 14, "\(label): only \(d.compared) fields compared")
                let labels = d.differing.map { String($0.prefix { $0 != ":" }) }
                #expect(labels == (a.origin == .transition ? ["origin"] : []), "\(label): \(d.differing)")
            }
            let stampedCurve = PitchCorrectionCurve.make(editSet: set, contour: result.frames)
            let plainCurve = PitchCorrectionCurve.make(editSet: plain, contour: result.frames)
            #expect(stampedCurve == plainCurve, "\(label): the stamp changed the curve")
            // Bit for bit at every millisecond, -0.0 included, and the control:
            // the curve bends somewhere, so equality is not two flat lines.
            var firstMoved: Double?
            var deepest = 0.0
            for ms in 0...Int(end * 1000) {
                let t = Double(ms) / 1000
                let a = stampedCurve.semitones(atSourceSecond: t)
                deepest = max(deepest, abs(a))
                if firstMoved == nil, a.bitPattern != plainCurve.semitones(atSourceSecond: t).bitPattern {
                    firstMoved = t
                }
            }
            #expect(firstMoved == nil, "\(label): the stamp moved the curve at \(firstMoved ?? -1) s")
            #expect(deepest > 0.05, "\(label): control, the curve never bends (\(deepest) st)")
        }
    }

    // MARK: - Codable

    @Test("codable: a stamped slide saves origin \"transition\" and reads back as itself; a detected note still saves no origin key")
    func stampedTableRoundTrips() throws {
        let set = PitchNoteTable.detected(from: Self.phrase())
        let json = String(decoding: try JSONEncoder().encode(set), as: UTF8.self)
        #expect(json.components(separatedBy: #""origin":"transition""#).count - 1 == 3, "\(json)")
        #expect(json.components(separatedBy: #""origin":"unpitched""#).count - 1 == 1)
        #expect(!json.contains(#""origin":"detected""#), "a .detected note must write no origin key")
        let back = try JSONDecoder().decode(PitchEditSet.self, from: Data(json.utf8))
        #expect(back.segments.map(\.origin) == set.segments.map(\.origin))
        #expect(back == set)
    }
}
