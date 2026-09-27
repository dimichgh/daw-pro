import CryptoKit
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// UA-2: THE RENDER HALF OF "THE STAMP BENDS NOTHING" (unpitched-notes design
/// §1.4 U2, brief step 2). `origin` reaches the render in two places, and both
/// admit `.transition` exactly as they admit `.detected`:
/// `NoteSegment.entersPitchCurve` (`origin != .unpitched || …`) and the
/// formant base in `PitchCorrectionCurve.make` (`origin != .unpitched`). So a
/// table's sung slides must render the same bytes whether they are stamped or
/// not. Only the KEY moves: digest slot 6 hashes one byte per note, 1 for a
/// slide where it used to be 0.
///
/// The render is the cache's own entry, `StretchRenderCache.renderAudio`, with
/// the contour handed over exactly when the set asks for it (the
/// `NoteSplitListeningTests.grid` rule). The curve leg covers every preset in
/// every shape, bit for bit each millisecond; it lives in the DAWCore suite
/// `SlideOriginStampTests`. Deliberately NOT `@MainActor`.
@Suite("UA-2: sung slides render the same bytes stamped or not; only the key moves", .serialized)
struct PitchCurveRenderSlideOriginTests {

    static let sampleRate = 48_000.0
    static let frameRate = 62.5
    static let baseHz = 220 * pow(2, 20.0 / 1200)

    /// `SlideOriginStampTests.phrase()` restated, because the test targets share
    /// no support module: floor, a breath, lead-in, A3 + 20 c, link, E4 + 20 c,
    /// tail-off, floor. `nil` cents is an unvoiced frame; `breath` marks the
    /// one audible unvoiced stretch (a sound).
    static let frames: [(cents: Double?, breath: Bool)] = {
        var out: [(cents: Double?, breath: Bool)] = []
        out += Array(repeating: (nil, false), count: 40)
        out += Array(repeating: (nil, true), count: 8)
        out += (1...12).map { (-720 + 58 * Double($0), false) }
        out += Array(repeating: (0, false), count: 30)
        out += (1...12).map { (58 * Double($0), false) }
        out += Array(repeating: (700, false), count: 30)
        out += (1...9).map { (700 - 60 * Double($0), false) }
        out += Array(repeating: (nil, false), count: 50)
        return out
    }()

    static func detection() -> PitchDetectionResult {
        let pitch = frames.enumerated().map { i, f -> ClipPitchFrame in
            ClipPitchFrame(timeSeconds: Double(i) / frameRate,
                           frequencyHz: f.cents.map { baseHz * pow(2, $0 / 1200) },
                           confidence: f.cents != nil ? 0.95 : (f.breath ? 0.5 : 0.2),
                           levelDbfs: f.cents != nil ? -20 : (f.breath ? -30 : -60),
                           absence: f.cents == nil ? .belowConfidence : nil)
        }
        let voiced = pitch.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: pitch, frameCount: pitch.count, voicedFrameCount: voiced,
            voicedFraction: Double(voiced) / Double(pitch.count), frameRateHz: frameRate,
            analysisSampleRateHz: 16_000, sourceSampleRateHz: sampleRate, windowStartSeconds: 0,
            windowDurationSeconds: Double(pitch.count) / frameRate, confidenceThreshold: 0.9,
            silenceFloorDbfs: -75, minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

    /// A harmonic tone that sings the contour. Each unvoiced frame holds the
    /// last sung pitch (A3 + 20 c before the first), so the stretcher has
    /// material under every note.
    static func source() -> [Float] {
        var hz: [Double] = []
        var last = baseHz
        for f in frames {
            if let c = f.cents { last = baseHz * pow(2, c / 1200) }
            hz.append(last)
        }
        return PitchTrackerAccuracyTests.Fixture.tone(
            seconds: Double(frames.count) / frameRate, amplitude: 0.5, partials: 12,
            sampleRate: sampleRate) { t in hz[min(hz.count - 1, max(0, Int(t * frameRate)))] }
    }

    /// The same set as the builders wrote it BEFORE UA-2: every `.transition`
    /// read back as `.detected`, every other field carried by the type's own
    /// `Codable` (the `reidentified` technique; `origin` is a `let`).
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

    /// The contour a render of `set` is handed: the detection exactly when the
    /// set shapes against it.
    static func contour(for set: PitchEditSet, _ detection: PitchDetectionResult) -> PitchRenderContour? {
        set.needsDetectedContour ? .detected(detection) : nil
    }

    /// The render cache's own render of `set` over `input`, mono.
    static func render(_ set: PitchEditSet, _ input: [Float],
                       _ detection: PitchDetectionResult) throws -> [Float] {
        var whole = [input]
        let params = StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false,
                                               pitchEdits: set)
        let out = try StretchRenderCache.renderAudio(
            whole: &whole, window: nil, sampleRate: sampleRate, params: params,
            curveContour: contour(for: set, detection), isCancelled: { false })
        #expect(out.path == .curve)
        return out.output.planar[0]
    }

    static func key(_ set: PitchEditSet) -> String {
        StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false,
                                  pitchEdits: set).pitchEditSetHash
    }

    static func sha256(_ samples: [Float]) -> String {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func firstDifference(_ a: [Float], _ b: [Float]) -> Int? {
        guard a.count == b.count else { return min(a.count, b.count) }
        return a.indices.first { a[$0].bitPattern != b[$0].bitPattern }
    }

    @Test("a table's sung slides render the same bytes stamped or not, and the render key moves by the stamp alone")
    func slidesRenderTheSameStampedOrNot() throws {
        let detection = Self.detection()
        let input = Self.source()
        let parts = PitchNoteSplitter.parts(in: detection.frames, frameRateHz: Self.frameRate,
                                            onsetSeconds: [])
        try #require(parts.map(\.kind) == [.transition, .held, .transition, .held, .transition],
                     "\(parts.map { "\($0.kind)/\($0.frameCount)" })")
        // The editor seed with one held note moved, so it renders at all.
        var seed = PitchNoteTable.detected(from: detection)
        let held = try #require(seed.segments.firstIndex {
            $0.origin == .detected && $0.endSeconds - $0.startSeconds > 0.4
        })
        seed.segments[held].pitchOffsetCents = 100
        let sets: [(label: String, set: PitchEditSet)] = [
            ("gentle", PitchAutoCorrect.editSet(from: detection,
                                                options: PitchCorrectionPreset.gentle.options())),
            ("hard tune", PitchAutoCorrect.editSet(from: detection,
                                                   options: PitchCorrectionPreset.hardTune.options())),
            ("edited editor seed", seed),
        ]
        let untuned = try OfflineStretcher.stretch(input: [input], sampleRate: Self.sampleRate,
                                                   ratio: 1, semitones: 0, formantPreserve: false)[0]
        // Every set is rendered and LOGGED before any assertion. So a run on
        // unstamped code (the "stamp nothing" plant) records each render's
        // hash for the before/after comparison.
        var renders: [[Float]] = []
        for (label, set) in sets {
            let rendered = try Self.render(set, input, detection)
            print("UA2-RENDER \(label): samples \(rendered.count) sha256 \(Self.sha256(rendered)) "
                  + "slides stamped \(set.segments.filter { $0.origin == .transition }.count)")
            renders.append(rendered)
        }
        for ((label, set), stamped) in zip(sets, renders) {
            try #require(set.segments.filter { $0.origin == .transition }.count == 3,
                         "\(label): positive control, the three slides are stamped")
            let plain = try Self.unstamped(set)
            #expect(!plain.segments.contains { $0.origin == .transition })
            for (a, b) in zip(set.segments, plain.segments) {
                let d = PrePitchNoteSplitReference.differingFields(a, b)
                let labels = d.differing.map { String($0.prefix { $0 != ":" }) }
                #expect(d.compared >= 14 && labels == (a.origin == .transition ? ["origin"] : []),
                        "\(label): the un-stamp changed more than origin: \(d.differing)")
            }

            // THE PLAN: the value handed to the stretcher at every output frame.
            let planA = try #require(StretchCurvePlan.make(
                editSet: set, clipPitchShiftSemitones: 0, sampleRate: Self.sampleRate, ratio: 1,
                contour: Self.contour(for: set, detection)))
            let planB = try #require(StretchCurvePlan.make(
                editSet: plain, clipPitchShiftSemitones: 0, sampleRate: Self.sampleRate, ratio: 1,
                contour: Self.contour(for: plain, detection)))
            #expect(planA.engagesFormantCurve == planB.engagesFormantCurve)
            let planMoved = input.indices.first {
                planA.semitones(atOutputFrame: $0).bitPattern
                    != planB.semitones(atOutputFrame: $0).bitPattern
            }
            #expect(planMoved == nil, "\(label): the stamp moved the plan at output frame \(planMoved ?? -1)")

            // THE RENDER, bit for bit, and its control: the tuning did something,
            // so equal bytes are not two renders that ignore the edits.
            let unstampedRender = try Self.render(plain, input, detection)
            let moved = Self.firstDifference(stamped, unstampedRender)
            #expect(moved == nil, "\(label): the stamp moved the render at sample \(moved ?? -1)")
            #expect(Self.firstDifference(stamped, untuned) != nil,
                    "\(label): control, the tuned render equals the untuned one")

            // THE KEY moves, and origin is the only field that differs.
            let stampedKey = Self.key(set), plainKey = Self.key(plain)
            #expect(!stampedKey.isEmpty && !plainKey.isEmpty && stampedKey != plainKey,
                    "\(label): a set that bends pitch and has a slide must re-key (digest slot 6)")
        }

        // An UNEDITED editor seed bends nothing: it keys "" and takes the
        // identity bypass stamped or not, so a fresh editor table keeps its key.
        let fresh = PitchNoteTable.detected(from: detection)
        try #require(fresh.segments.filter { $0.origin == .transition }.count == 3)
        let freshPlain = try Self.unstamped(fresh)
        #expect(Self.key(fresh).isEmpty && Self.key(freshPlain).isEmpty)
        #expect(StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false,
                                          pitchEdits: fresh).isIdentity)
    }
}
