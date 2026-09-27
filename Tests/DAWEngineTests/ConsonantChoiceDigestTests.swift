import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// NT-C2-F1 and natural tuning §1(e) (lane W7-D2): **THE RENDER-DIGEST HALF.**
///
/// W7-D2 made the consonant field's stored state three cases
/// (`PitchEditSet.consonantProtection`: off by default, on, off by choice) so a
/// preset re-run can keep a chosen OFF, and gave `PitchAutoCorrectOptions` an
/// optional voice size. Neither may move a render key it has no business
/// moving:
///  * the CHOICE is not render material (the `autoCorrectStamp` precedent):
///    an OFF somebody chose keys exactly like an OFF nobody chose;
///  * every set saved before the record keys exactly as before;
///  * an auto-correct pass that names no voice size keys exactly as before.
/// `PitchEditSetDigest` is internal to DAWEngine, which DAWCoreTests cannot
/// import, so these pins live here. The encodings, stamps and store paths are
/// DAWCoreTests' `ConsonantChoiceTests`, `VoiceSizeOverrideTests` and
/// `PitchCorrectionWriterTests`.
///
/// ⚠️ Named so it can never match `NaturalTuning*` (another lane's glob).
/// Deliberately NOT `@MainActor` (digest arithmetic; `MainActorOccupancySiteTests`
/// Leg C caps `@MainActor` suites).
@Suite("NT-C2-F1 / §1(e) — the consonant choice and an unnamed voice size key no render (W7-D2)")
struct ConsonantChoiceDigestTests {

    static let idA = UUID(uuidString: "D2D2D2D2-0000-4000-8000-00000000000A")!
    static let idB = UUID(uuidString: "D2D2D2D2-0000-4000-8000-00000000000B")!
    static let idS = UUID(uuidString: "D2D2D2D2-0000-4000-8000-00000000005D")!
    static let idC = UUID(uuidString: "D2D2D2D2-0000-4000-8000-00000000000C")!

    static func notes() -> [NoteSegment] {
        [NoteSegment(id: idA, startSeconds: 0.2, endSeconds: 0.6, detectedHz: 220,
                     detectedConfidence: 0.9, pitchOffsetCents: 150),
         NoteSegment(id: idB, startSeconds: 0.6, endSeconds: 0.95, detectedHz: 240,
                     detectedConfidence: 0.9),
         NoteSegment(id: idS, startSeconds: 0.95, endSeconds: 1.05, detectedHz: 240,
                     detectedConfidence: 0.3, origin: .unpitched),
         NoteSegment(id: idC, startSeconds: 1.1, endSeconds: 1.5, detectedHz: 260,
                     detectedConfidence: 0.9, pitchOffsetCents: -40)]
    }

    /// Each golden rebuilt by today's code, the way it was built at capture.
    static func rebuilt(_ name: String) -> PitchEditSet? {
        let legacy = PitchEditSet(segments: notes(), retuneMs: 80)
        switch name {
        case "legacy": return legacy
        case "presetNatural":
            return PitchEditSet.seeded(analysisVersion: 1, segments: notes(), retuneMs: 110,
                                       partKinds: [:], seedPolicy: .preset)
                .stampedAsAutoCorrectOutput()
        case "upgraded": return legacy.upgradedToNaturalTuning()
        case "legacyConsonantsOn":
            var set = legacy
            set.keepsConsonantsUntuned = true
            return set
        case "voiceSizeOnly":
            var set = legacy
            set.formantCorrection = 0.5
            return set
        default: return nil
        }
    }

    /// The contour the auto-correct digests were captured over (DAWCoreTests'
    /// `VoiceSizeOverrideTests.contour()`, frame for frame).
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

    static func options() -> [(String, PitchAutoCorrectOptions)] {
        [("default", PitchAutoCorrectOptions())]
            + PitchCorrectionPreset.allCases.map { ($0.rawValue, $0.options()) }
            + [("gMinor", PitchAutoCorrectOptions(scale: PitchCorrectionScale(tonicPitchClass: 7,
                                                                             mode: .minor),
                                                 strength: 0.7, retuneMs: 90,
                                                 preserveVibrato: false))]
    }

    // MARK: - The goldens

    // ⛔ FROZEN: captured by W7-D2 on the tree BEFORE any W7-D2 edit (2026-09-27 04:35,
    // `scratchpad/w7/D2/golden-capture.txt`). Never regenerate them from the current code,
    // or the gate compares the code with itself.
    static let goldenDigests: [String: String] = [
        "legacy": "05e651e301fc88d16d203ebf5b3649141afa6bd23a882684219ff53de06847ad",
        "presetNatural": "ecdb98033a6ea593373f63e9aa4faf20142886c913c27c27ba228c3ec1baf427",
        "upgraded": "92a215320071eedbe6d536ca87f33355530aa9b4c55ff7348a16be6b4006bb03",
        "legacyConsonantsOn": "09f4b93d18c8c153bac3f4c116c45ce22a11825990643cdde65f771161b7e67e",
        "voiceSizeOnly": "5ac5ca9ce9b382d4827fc3c4f6c871b2a71a1616e4c724009b0672105f6e4083",
    ]
    static let goldenJSON: [String: String] = [
        "legacy": #"{"analysisVersion":1,"retuneMs":80,"segments":[{"detectedConfidence":0.9,"detectedHz":220,"endSeconds":0.6,"id":"D2D2D2D2-0000-4000-8000-00000000000A","pitchOffsetCents":150,"startSeconds":0.2},{"detectedConfidence":0.9,"detectedHz":240,"endSeconds":0.95,"id":"D2D2D2D2-0000-4000-8000-00000000000B","startSeconds":0.6},{"detectedConfidence":0.3,"detectedHz":240,"endSeconds":1.05,"id":"D2D2D2D2-0000-4000-8000-00000000005D","origin":"unpitched","startSeconds":0.95},{"detectedConfidence":0.9,"detectedHz":260,"endSeconds":1.5,"id":"D2D2D2D2-0000-4000-8000-00000000000C","pitchOffsetCents":-40,"startSeconds":1.1}]}"#,
        "presetNatural": #"{"analysisVersion":1,"autoCorrectStamp":"12da63bde6b83a8b","formantCorrection":1,"keepsConsonantsUntuned":true,"retuneMs":110,"segments":[{"detectedConfidence":0.9,"detectedHz":220,"endSeconds":0.6,"id":"D2D2D2D2-0000-4000-8000-00000000000A","pitchOffsetCents":150,"startSeconds":0.2},{"detectedConfidence":0.9,"detectedHz":240,"endSeconds":0.95,"id":"D2D2D2D2-0000-4000-8000-00000000000B","startSeconds":0.6},{"detectedConfidence":0.3,"detectedHz":240,"endSeconds":1.05,"id":"D2D2D2D2-0000-4000-8000-00000000005D","origin":"unpitched","startSeconds":0.95},{"detectedConfidence":0.9,"detectedHz":260,"endSeconds":1.5,"id":"D2D2D2D2-0000-4000-8000-00000000000C","pitchOffsetCents":-40,"startSeconds":1.1}],"transitionSlope":3000}"#,
        "upgraded": #"{"analysisVersion":1,"formantCorrection":1,"keepsConsonantsUntuned":true,"retuneMs":80,"segments":[{"detectedConfidence":0.9,"detectedHz":220,"endSeconds":0.6,"id":"D2D2D2D2-0000-4000-8000-00000000000A","pitchOffsetCents":150,"startSeconds":0.2},{"detectedConfidence":0.9,"detectedHz":240,"endSeconds":0.95,"id":"D2D2D2D2-0000-4000-8000-00000000000B","startSeconds":0.6},{"detectedConfidence":0.3,"detectedHz":240,"endSeconds":1.05,"id":"D2D2D2D2-0000-4000-8000-00000000005D","origin":"unpitched","startSeconds":0.95},{"detectedConfidence":0.9,"detectedHz":260,"endSeconds":1.5,"id":"D2D2D2D2-0000-4000-8000-00000000000C","pitchOffsetCents":-40,"startSeconds":1.1}],"transitionSlope":3000}"#,
        "legacyConsonantsOn": #"{"analysisVersion":1,"keepsConsonantsUntuned":true,"retuneMs":80,"segments":[{"detectedConfidence":0.9,"detectedHz":220,"endSeconds":0.6,"id":"D2D2D2D2-0000-4000-8000-00000000000A","pitchOffsetCents":150,"startSeconds":0.2},{"detectedConfidence":0.9,"detectedHz":240,"endSeconds":0.95,"id":"D2D2D2D2-0000-4000-8000-00000000000B","startSeconds":0.6},{"detectedConfidence":0.3,"detectedHz":240,"endSeconds":1.05,"id":"D2D2D2D2-0000-4000-8000-00000000005D","origin":"unpitched","startSeconds":0.95},{"detectedConfidence":0.9,"detectedHz":260,"endSeconds":1.5,"id":"D2D2D2D2-0000-4000-8000-00000000000C","pitchOffsetCents":-40,"startSeconds":1.1}]}"#,
        "voiceSizeOnly": #"{"analysisVersion":1,"formantCorrection":0.5,"retuneMs":80,"segments":[{"detectedConfidence":0.9,"detectedHz":220,"endSeconds":0.6,"id":"D2D2D2D2-0000-4000-8000-00000000000A","pitchOffsetCents":150,"startSeconds":0.2},{"detectedConfidence":0.9,"detectedHz":240,"endSeconds":0.95,"id":"D2D2D2D2-0000-4000-8000-00000000000B","startSeconds":0.6},{"detectedConfidence":0.3,"detectedHz":240,"endSeconds":1.05,"id":"D2D2D2D2-0000-4000-8000-00000000005D","origin":"unpitched","startSeconds":0.95},{"detectedConfidence":0.9,"detectedHz":260,"endSeconds":1.5,"id":"D2D2D2D2-0000-4000-8000-00000000000C","pitchOffsetCents":-40,"startSeconds":1.1}]}"#,
    ]
    static let autoCorrectDigests: [String: String] = [
        "default": "231fb3cdc551aba5f61f26927fabf6119c8050057a503004abcf7b1ae28e802e",
        "gentle": "f70425857ec92c9ad4eaa3780d46893c66f6d06811e682eae0fa164113ebb5fd",
        "natural": "d8619801a1019e2da856ee1032d3dde6d7f384dabdf967b251df7f93a402eb6f",
        "tight": "a89c85c77ad7c4d2b360bc670f6a77901e7be9e8688c3c23d9619fc22fff582f",
        "hardTune": "4a2ca9b90aebb83c4ca9dd7236697bc9fd86c54d629fce8dd8c55bfdc47a2764",
        "gMinor": "816454366325f268f571cffcfe997d3f9c7972e3592792f07a251da9e31e8182",
    ]

    /// The `formantRenderVersion` every golden above was captured under
    /// (2026-09-27 04:35). NT-F220 (3, vendored patch 0004) re-keyed each
    /// ENGAGED golden by exactly its slot-7 version, on purpose: those renders
    /// changed. The frozen hexes stay frozen; an engaged set is checked as
    /// "the restatement at THIS version is the capture, and today's key is the
    /// restatement at the current version".
    static let capturedFormantVersion = 2

    /// `set`'s key must be `frozen`, or, for an engaged set, `frozen` moved by
    /// exactly its formant version (NaturalTuningConsonantDigestTests' restatement).
    static func expectKeyed(_ set: PitchEditSet, as frozen: String?, _ label: String) {
        guard set.engagesFormantCurve else {
            #expect(PitchEditSetDigest.hex(set) == frozen, "\(label): its render key moved")
            return
        }
        #expect(NaturalTuningConsonantDigestTests.expectedHex(set, formantVersion: Self.capturedFormantVersion) == frozen,
                "\(label): the restatement at formant version \(Self.capturedFormantVersion) does not reproduce the capture")
        #expect(PitchEditSetDigest.hex(set) == NaturalTuningConsonantDigestTests.expectedHex(set),
                "\(label): re-keyed, but not by exactly the formant version")
        #expect(PitchEditSetDigest.hex(set) != frozen, "\(label): an engaged set kept its version-2 key")
    }

    @Test("NT-C2-F1 (b): every golden saved before the record keys its render exactly as it did")
    func goldenDigestsUnchanged() throws {
        #expect(Self.goldenJSON.count == 5 && Set(Self.goldenJSON.keys) == Set(Self.goldenDigests.keys))
        for (name, json) in Self.goldenJSON {
            let frozen = try #require(Self.goldenDigests[name])
            #expect(frozen.count == 64, "control: \(name) was captured as a real digest")
            let decoded = try JSONDecoder().decode(PitchEditSet.self, from: Data(json.utf8))
            Self.expectKeyed(decoded, as: frozen, name)
            let rebuilt = try #require(Self.rebuilt(name))
            Self.expectKeyed(rebuilt, as: frozen, "\(name) (rebuilt by today's code)")
        }
    }

    @Test("NT-C2-F1 (b): an OFF somebody chose keys its render exactly like an OFF nobody chose")
    func choiceIsNotRenderMaterial() throws {
        for name in ["legacy", "voiceSizeOnly"] {
            let unchosen = try JSONDecoder().decode(
                PitchEditSet.self, from: Data(try #require(Self.goldenJSON[name]).utf8))
            #expect(unchosen.consonantProtection == .offByDefault, "precondition: \(name) is an unchosen OFF")
            #expect(!unchosen.isIdentity, "control: \(name) bends pitch, so it has a key to move")
            var chosen = unchosen
            chosen.consonantProtection = .offByChoice
            #expect(chosen != unchosen, "control: the two are different STORED states")
            #expect(PitchEditSetDigest.hex(chosen) == PitchEditSetDigest.hex(unchosen),
                    "\(name): the consonant CHOICE re-keyed the render; it is not render material")
            Self.expectKeyed(chosen, as: Self.goldenDigests[name], "\(name) (chosen OFF)")
            // Positive control: the instrument sees slot 8 when the flag really moves.
            var on = unchosen
            on.keepsConsonantsUntuned = true
            #expect(PitchEditSetDigest.hex(on) != PitchEditSetDigest.hex(unchosen),
                    "control: switching consonants ON must re-key (slot 8)")
        }
    }

    @Test("§1(e): an auto-correct pass that names no voice size keys every preset's result as before the field")
    func noOverrideKeepsEveryAutoCorrectDigest() throws {
        let result = Self.contour()
        #expect(Self.autoCorrectDigests.count == 6)
        for (name, value) in Self.options() {
            let set = try Self.reIdentified(PitchAutoCorrect.build(from: result, options: value).editSet)
            Self.expectKeyed(set, as: Self.autoCorrectDigests[name], name)
        }
    }

    @Test("§1(e): a named voice size re-keys through the voice size alone (slot 7), exactly as the same amount set by hand")
    func namedVoiceSizeKeysLikeTheAmount() throws {
        let result = Self.contour()
        for (name, value) in Self.options() where value.strength > 0 {
            var named = value
            named.formantCorrection = 0.35
            let withOverride = try Self.reIdentified(PitchAutoCorrect.build(from: result, options: named).editSet)
            var byHand = try Self.reIdentified(PitchAutoCorrect.build(from: result, options: value).editSet)
            #expect(PitchEditSetDigest.hex(withOverride) != PitchEditSetDigest.hex(byHand),
                    "control: \(name)'s override moved nothing")
            byHand.formantCorrection = 0.35
            #expect(PitchEditSetDigest.hex(withOverride) == PitchEditSetDigest.hex(byHand),
                    "\(name): the override moved more than the voice size")
        }
    }
}
