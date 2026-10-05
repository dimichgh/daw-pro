import Foundation
import Testing
@testable import DAWCore

// Natural tuning §1(e) (W7-D2): `clip.autoCorrectPitch`'s optional voice-size
// override, the DAWCore half. `PitchAutoCorrectOptions.formantCorrection`:
// nil is today's rule (seed a new set, or carry the clip's own amount); a
// number is clamped to 0...1 and wins over BOTH; a non-finite number is
// refused by the store in words before detection runs.
//
// Pure and nonisolated (`MainActorOccupancySiteTests` Leg C caps `@MainActor`
// suites). The store half (beats the carry, one undo, the refusal) is
// `PitchCorrectionWriterTests`' §1(e) block; the digest half is DAWEngineTests'
// `ConsonantChoiceDigestTests`.
@Suite("Natural tuning §1(e) — auto-correct's voice-size override (W7-D2)")
struct VoiceSizeOverrideTests {

    /// Two held notes joined by a 0.3 s glide, a hole, a quiet breath, a
    /// third held note: five segments under every preset (four notes and one
    /// sound). Frame for frame the contour the goldens were captured from.
    static func contour() -> PitchDetectionResult {
        let rate = 62.5
        var frames: [ClipPitchFrame] = []
        var t = 0.0
        func push(_ hz: Double?, _ seconds: Double, level: Double = -12) {
            for _ in 0..<Int((seconds * rate).rounded()) {
                frames.append(ClipPitchFrame(timeSeconds: t, frequencyHz: hz,
                                             confidence: hz == nil ? 0.1 : 0.95,
                                             levelDbfs: hz == nil ? level : -12,
                                             absence: hz == nil ? .belowConfidence : nil))
                t += 1 / rate
            }
        }
        push(nil, 1.2, level: -80)
        push(223, 0.6)
        let glide = Int((0.3 * rate).rounded())
        for i in 0..<glide {
            let u = Double(i + 1) / Double(glide + 1)
            frames.append(ClipPitchFrame(timeSeconds: t, frequencyHz: 223 * pow(1.5, u),
                                         confidence: 0.95, levelDbfs: -12, absence: nil))
            t += 1 / rate
        }
        push(327, 0.6)
        push(nil, 0.3, level: -80)
        push(nil, 0.2, level: -30)
        push(nil, 0.2, level: -80)
        push(199, 0.5)
        push(nil, 1.2, level: -80)
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count,
            voicedFrameCount: frames.filter { $0.frequencyHz != nil }.count,
            voicedFraction: 0.5, frameRateHz: rate, analysisSampleRateHz: 16_000,
            sourceSampleRateHz: 44_100, windowStartSeconds: 0,
            windowDurationSeconds: t, confidenceThreshold: 0.9,
            silenceFloorDbfs: -75, minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

    /// `set` with segment k's id replaced by a fixed one, every other field
    /// carried by the type's own `Codable` (the policy mints fresh ids).
    static func reIdentified(_ set: PitchEditSet) throws -> PitchEditSet {
        var copy = set
        for index in copy.segments.indices {
            let data = try JSONEncoder().encode(copy.segments[index])
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.coderInvalidValue)
            }
            object["id"] = String(format: "D2D2D2D2-0000-4000-8000-%012d", index)
            copy.segments[index] = try JSONDecoder().decode(
                NoteSegment.self, from: try JSONSerialization.data(withJSONObject: object))
        }
        return copy
    }

    /// The captured option sets: the default, every preset, and a custom pass.
    static func options() -> [(String, PitchAutoCorrectOptions)] {
        [("default", PitchAutoCorrectOptions())]
            + PitchCorrectionPreset.allCases.map { ($0.rawValue, $0.options()) }
            + [("gMinor", PitchAutoCorrectOptions(scale: PitchCorrectionScale(tonicPitchClass: 7,
                                                                             mode: .minor),
                                                 strength: 0.7, retuneMs: 90,
                                                 preserveVibrato: false))]
    }

    static func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: - The goldens

    // ⛔ FROZEN: captured by W7-D2 on the tree BEFORE any W7-D2 edit (2026-09-27 04:35,
    // `scratchpad/w7/D2/golden-capture.txt`). Never regenerate them from the current code,
    // or the gate compares the code with itself.
    static let optionsJSON: [String: String] = [
        "default": #"{"preserveVibrato":true,"retuneMs":30,"scale":{"mode":"chromatic","tonicPitchClass":0},"strength":1}"#,
        "gentle": #"{"preserveVibrato":true,"retuneMs":200,"scale":{"mode":"chromatic","tonicPitchClass":0},"strength":0.5}"#,
        "natural": #"{"preserveVibrato":true,"retuneMs":110,"scale":{"mode":"chromatic","tonicPitchClass":0},"strength":0.85}"#,
        "tight": #"{"preserveVibrato":true,"retuneMs":40,"scale":{"mode":"chromatic","tonicPitchClass":0},"strength":1}"#,
        "hardTune": #"{"preserveVibrato":false,"retuneMs":30,"scale":{"mode":"chromatic","tonicPitchClass":0},"strength":1}"#,
        "gMinor": #"{"preserveVibrato":false,"retuneMs":90,"scale":{"mode":"minor","tonicPitchClass":7},"strength":0.7}"#,
    ]
    static let autoCorrectResults: [String: (segments: Int, json: String, stamp: String)] = [
        "default": (5, #"{"analysisVersion":1,"formantCorrection":1,"keepsConsonantsUntuned":true,"segments":[{"detectedConfidence":0.95,"detectedHz":223,"endSeconds":1.8240000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000000","pitchOffsetCents":-23.44822367477377,"startSeconds":1.2000000000000008},{"detectedConfidence":0.95,"detectedHz":270.363594076,"endSeconds":2.0800000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000001","origin":"transition","startSeconds":1.8240000000000014},{"detectedConfidence":0.95,"detectedHz":327.0000000000001,"endSeconds":2.720000000000002,"id":"D2D2D2D2-0000-4000-8000-000000000002","pitchOffsetCents":13.855465631891661,"startSeconds":2.0800000000000014},{"detectedConfidence":0.1,"detectedHz":199,"endSeconds":3.2320000000000024,"id":"D2D2D2D2-0000-4000-8000-000000000003","origin":"unpitched","startSeconds":3.0240000000000022},{"detectedConfidence":0.95,"detectedHz":199,"endSeconds":3.936000000000003,"id":"D2D2D2D2-0000-4000-8000-000000000004","pitchOffsetCents":-26.31788842278695,"startSeconds":3.4400000000000026}],"transitionSlope":3000}"#,
                 "53831f5e3635e47a"),
        "gentle": (5, #"{"analysisVersion":1,"formantCorrection":1,"keepsConsonantsUntuned":true,"retuneMs":200,"segments":[{"detectedConfidence":0.95,"detectedHz":223,"endSeconds":1.8240000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000000","pitchOffsetCents":-11.724111837386886,"startSeconds":1.2000000000000008},{"detectedConfidence":0.95,"detectedHz":270.363594076,"endSeconds":2.0800000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000001","origin":"transition","startSeconds":1.8240000000000014},{"detectedConfidence":0.95,"detectedHz":327.0000000000001,"endSeconds":2.720000000000002,"id":"D2D2D2D2-0000-4000-8000-000000000002","pitchOffsetCents":6.927732815945831,"startSeconds":2.0800000000000014},{"detectedConfidence":0.1,"detectedHz":199,"endSeconds":3.2320000000000024,"id":"D2D2D2D2-0000-4000-8000-000000000003","origin":"unpitched","startSeconds":3.0240000000000022},{"detectedConfidence":0.95,"detectedHz":199,"endSeconds":3.936000000000003,"id":"D2D2D2D2-0000-4000-8000-000000000004","pitchOffsetCents":-13.158944211393475,"startSeconds":3.4400000000000026}],"transitionSlope":3000}"#,
                 "2a88979b65735830"),
        "natural": (5, #"{"analysisVersion":1,"formantCorrection":1,"keepsConsonantsUntuned":true,"retuneMs":110,"segments":[{"detectedConfidence":0.95,"detectedHz":223,"endSeconds":1.8240000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000000","pitchOffsetCents":-19.930990123557706,"startSeconds":1.2000000000000008},{"detectedConfidence":0.95,"detectedHz":270.363594076,"endSeconds":2.0800000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000001","origin":"transition","startSeconds":1.8240000000000014},{"detectedConfidence":0.95,"detectedHz":327.0000000000001,"endSeconds":2.720000000000002,"id":"D2D2D2D2-0000-4000-8000-000000000002","pitchOffsetCents":11.777145787107912,"startSeconds":2.0800000000000014},{"detectedConfidence":0.1,"detectedHz":199,"endSeconds":3.2320000000000024,"id":"D2D2D2D2-0000-4000-8000-000000000003","origin":"unpitched","startSeconds":3.0240000000000022},{"detectedConfidence":0.95,"detectedHz":199,"endSeconds":3.936000000000003,"id":"D2D2D2D2-0000-4000-8000-000000000004","pitchOffsetCents":-22.370205159368908,"startSeconds":3.4400000000000026}],"transitionSlope":3000}"#,
                 "adbc4bdf4355e4a0"),
        "tight": (5, #"{"analysisVersion":1,"formantCorrection":1,"keepsConsonantsUntuned":true,"retuneMs":40,"segments":[{"detectedConfidence":0.95,"detectedHz":223,"endSeconds":1.8240000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000000","pitchOffsetCents":-23.44822367477377,"startSeconds":1.2000000000000008},{"detectedConfidence":0.95,"detectedHz":270.363594076,"endSeconds":2.0800000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000001","origin":"transition","startSeconds":1.8240000000000014},{"detectedConfidence":0.95,"detectedHz":327.0000000000001,"endSeconds":2.720000000000002,"id":"D2D2D2D2-0000-4000-8000-000000000002","pitchOffsetCents":13.855465631891661,"startSeconds":2.0800000000000014},{"detectedConfidence":0.1,"detectedHz":199,"endSeconds":3.2320000000000024,"id":"D2D2D2D2-0000-4000-8000-000000000003","origin":"unpitched","startSeconds":3.0240000000000022},{"detectedConfidence":0.95,"detectedHz":199,"endSeconds":3.936000000000003,"id":"D2D2D2D2-0000-4000-8000-000000000004","pitchOffsetCents":-26.31788842278695,"startSeconds":3.4400000000000026}],"transitionSlope":3000}"#,
                 "6be141756be4c273"),
        "hardTune": (5, #"{"analysisVersion":1,"formantCorrection":1,"keepsConsonantsUntuned":true,"segments":[{"detectedConfidence":0.95,"detectedHz":223,"driftScale":0,"endSeconds":1.8240000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000000","pitchOffsetCents":-23.44822367477377,"startSeconds":1.2000000000000008,"vibratoScale":0},{"detectedConfidence":0.95,"detectedHz":270.363594076,"endSeconds":2.0800000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000001","origin":"transition","startSeconds":1.8240000000000014},{"detectedConfidence":0.95,"detectedHz":327.0000000000001,"driftScale":0,"endSeconds":2.720000000000002,"id":"D2D2D2D2-0000-4000-8000-000000000002","pitchOffsetCents":13.855465631891661,"startSeconds":2.0800000000000014,"vibratoScale":0},{"detectedConfidence":0.1,"detectedHz":199,"endSeconds":3.2320000000000024,"id":"D2D2D2D2-0000-4000-8000-000000000003","origin":"unpitched","startSeconds":3.0240000000000022},{"detectedConfidence":0.95,"detectedHz":199,"driftScale":0,"endSeconds":3.936000000000003,"id":"D2D2D2D2-0000-4000-8000-000000000004","pitchOffsetCents":-26.31788842278695,"startSeconds":3.4400000000000026,"vibratoScale":0}],"transitionSlope":3000}"#,
                 "3addb3900a30f28e"),
        "gMinor": (5, #"{"analysisVersion":1,"formantCorrection":1,"keepsConsonantsUntuned":true,"retuneMs":90,"segments":[{"detectedConfidence":0.95,"detectedHz":223,"driftScale":0.30000000000000004,"endSeconds":1.8240000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000000","pitchOffsetCents":-16.41375657234164,"startSeconds":1.2000000000000008,"vibratoScale":0.30000000000000004},{"detectedConfidence":0.95,"detectedHz":270.363594076,"endSeconds":2.0800000000000014,"id":"D2D2D2D2-0000-4000-8000-000000000001","origin":"transition","startSeconds":1.8240000000000014},{"detectedConfidence":0.95,"detectedHz":327.0000000000001,"driftScale":0.30000000000000004,"endSeconds":2.720000000000002,"id":"D2D2D2D2-0000-4000-8000-000000000002","pitchOffsetCents":-60.30117405767583,"startSeconds":2.0800000000000014,"vibratoScale":0.30000000000000004},{"detectedConfidence":0.1,"detectedHz":199,"endSeconds":3.2320000000000024,"id":"D2D2D2D2-0000-4000-8000-000000000003","origin":"unpitched","startSeconds":3.0240000000000022},{"detectedConfidence":0.95,"detectedHz":199,"driftScale":0.30000000000000004,"endSeconds":3.936000000000003,"id":"D2D2D2D2-0000-4000-8000-000000000004","pitchOffsetCents":-18.422521895950865,"startSeconds":3.4400000000000026,"vibratoScale":0.30000000000000004}],"transitionSlope":3000}"#,
                 "877e4ba7c69a2017"),
    ]

    // MARK: - nil changes nothing: the options' bytes and every auto-correct result

    @Test("§1(e) options: naming no voice size encodes every preset's and a custom pass's options byte for byte as before the field")
    func optionsEncodeAsBeforeWithNoOverride() throws {
        let encoder = Self.sortedEncoder()
        #expect(Self.optionsJSON.count == 6 && Self.options().count == 6)
        for (name, value) in Self.options() {
            #expect(value.formantCorrection == nil, "\(name) names a voice size: no preset may")
            let frozen = try #require(Self.optionsJSON[name], "no golden for \(name)")
            #expect(try encoder.encode(value) == Data(frozen.utf8), "\(name) encodes differently")
            // A payload written before the field decodes to "no override".
            let back = try JSONDecoder().decode(PitchAutoCorrectOptions.self, from: Data(frozen.utf8))
            #expect(back == value && back.formantCorrection == nil)
        }
        // Positive control: a named amount IS written, and round-trips.
        var named = PitchCorrectionPreset.natural.options()
        named.formantCorrection = 0.3
        let text = String(decoding: try encoder.encode(named), as: UTF8.self)
        #expect(text.contains(#""formantCorrection":0.3"#))
        #expect(try JSONDecoder().decode(PitchAutoCorrectOptions.self, from: Data(text.utf8)) == named)
    }

    @Test("§1(e) nil: every preset's auto-correct result is byte for byte what it was before the field, stamp and all")
    func noOverrideKeepsEveryAutoCorrectResult() throws {
        let encoder = Self.sortedEncoder()
        let result = Self.contour()
        #expect(Self.autoCorrectResults.count == 6)
        for (name, value) in Self.options() {
            let frozen = try #require(Self.autoCorrectResults[name], "no golden for \(name)")
            let set = try Self.reIdentified(PitchAutoCorrect.build(from: result, options: value).editSet)
            #expect(set.segments.count == frozen.segments, "\(name): the contour segments differently")
            #expect(set.segments.contains { $0.origin == .unpitched }, "control: \(name) has a sound")
            #expect(try encoder.encode(set) == Data(frozen.json.utf8), "\(name): the pass builds a different set")
            let stamped = set.stampedAsAutoCorrectOutput()
            #expect(stamped.autoCorrectStamp == frozen.stamp, "\(name): its stamp moved")
            #expect(stamped.hasHandEditsSinceAutoCorrect == false)
        }
    }

    // MARK: - The options value

    @Test("§1(e) options: init clamps a number to 0...1 (0 stays 0, never legacy) and KEEPS a non-finite one for the store to refuse")
    func initClampsAndKeepsNonFinite() {
        #expect(PitchAutoCorrectOptions().formantCorrection == nil)
        #expect(PitchAutoCorrectOptions(formantCorrection: 0.4).formantCorrection == 0.4)
        #expect(PitchAutoCorrectOptions(formantCorrection: 1.7).formantCorrection == 1)
        #expect(PitchAutoCorrectOptions(formantCorrection: -0.5).formantCorrection == 0)
        #expect(PitchAutoCorrectOptions(formantCorrection: 0).formantCorrection == 0)
        for bad in [Double.nan, .infinity, -.infinity] {
            let kept = PitchAutoCorrectOptions(formantCorrection: bad).formantCorrection
            #expect(kept != nil && kept?.isFinite == false, "\(bad) was healed, so the store cannot refuse it")
            #expect(PitchAutoCorrectOptions(formantCorrection: bad).formantCorrectionOverride == nil)
        }
        // The one reading clamps a DIRECT write, which bypasses init.
        var direct = PitchAutoCorrectOptions()
        direct.formantCorrection = 3
        #expect(direct.formantCorrectionOverride == 1)
        direct.formantCorrection = -1
        #expect(direct.formantCorrectionOverride == 0)
        direct.formantCorrection = nil
        #expect(direct.formantCorrectionOverride == nil)
    }

    // MARK: - The policy

    @Test("§1(e) policy: a named voice size beats the seed in both of build's tables; nil and non-finite keep the seed; strength 0 stays .empty")
    func policyOverrideBeatsTheSeed() {
        let result = Self.contour()
        for preset in PitchCorrectionPreset.allCases {
            var options = preset.options()
            let seeded = PitchAutoCorrect.editSet(from: result, options: options)
            #expect(seeded.formantCorrection == PitchEditSet.newSetFormantCorrection, "control: \(preset) seeds")
            options.formantCorrection = 0.35
            let named = PitchAutoCorrect.editSet(from: result, options: options)
            #expect(named.formantCorrection == 0.35, "\(preset): the override lost to the seed")
            // ONLY the amount moved: the notes and every other set-level field are the seed's.
            var expected = seeded.withSegments(named.segments)
            expected.formantCorrection = 0.35
            #expect(named == expected, "\(preset): the override moved more than the voice size")
            #expect(named.segments.count == seeded.segments.count)
            options.formantCorrection = 0
            #expect(PitchAutoCorrect.editSet(from: result, options: options).formantCorrection == 0,
                    "\(preset): an override of 0 is an engaged amount, not the seed and not legacy")
            options.formantCorrection = .nan
            #expect(PitchAutoCorrect.editSet(from: result, options: options).formantCorrection
                        == PitchEditSet.newSetFormantCorrection, "\(preset): a NaN was stored")
        }
        // The empty table (no voiced notes) takes it too.
        var silent = PitchAutoCorrectOptions(formantCorrection: 0.6)
        let quiet = PitchAutoCorrect.editSet(contour: [], frameRateHz: 62.5, options: silent)
        #expect(quiet.isEmpty && quiet.formantCorrection == 0.6)
        // Strength 0 is the structural identity and stays `.empty` (legacy).
        silent.strength = 0
        #expect(PitchAutoCorrect.editSet(from: result, options: silent) == .empty)
    }
}
