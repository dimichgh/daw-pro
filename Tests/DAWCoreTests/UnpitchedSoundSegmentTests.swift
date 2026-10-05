import Foundation
import Testing
@testable import DAWCore

// U-A core (unpitched-notes design §1.4, §1.6; natural-tuning design R21):
// `NoteSegment.origin`, its Codable rule, `entersPitchCurve`, and the two
// builders adding identity sounds. Pure types only, so this suite is NOT
// `@MainActor` (the store leg lives in `PitchCorrectionWriterTests`).
//
// The finder itself is `PitchUnpitchedFinderTests`. The render physics (G-C13)
// and digest slot 6 are `PitchCurveRenderTests` §10. The 813c415 byte gate is
// `NaturalTuningFieldCarryTests.legacyProjectResavesByteIdentical`.

@Suite("U-A: sounds with no detected pitch — the origin field, the curve predicate, the builders")
struct UnpitchedSoundSegmentTests {

    // MARK: - Fixture

    /// Six seconds at 62.5 fps: a −60 dBFS floor, two held notes at −20 and
    /// three −30 dBFS unvoiced SOUNDS (before A, before B, after B). The same
    /// layout as `PitchCorrectionWriterTests.soundsResult`, kept separate so
    /// the two suites do not share a private helper across isolation.
    static func soundsResult() -> PitchDetectionResult {
        let period = 1.0 / 62.5
        let frames = (0..<375).map { i -> ClipPitchFrame in
            let time = Double(i) * period
            switch i {
            case 87..<150:
                return ClipPitchFrame(timeSeconds: time, frequencyHz: 220, confidence: 0.95,
                                      levelDbfs: -20, absence: nil)
            case 218..<281:
                return ClipPitchFrame(timeSeconds: time, frequencyHz: 247, confidence: 0.95,
                                      levelDbfs: -20, absence: nil)
            case 75..<87, 212..<218, 281..<287:
                return ClipPitchFrame(timeSeconds: time, frequencyHz: nil, confidence: 0.5,
                                      levelDbfs: -30, absence: .belowConfidence)
            default:
                return ClipPitchFrame(timeSeconds: time, frequencyHz: nil, confidence: 0.2,
                                      levelDbfs: -60, absence: .belowConfidence)
            }
        }
        return result(frames)
    }

    static func result(_ frames: [ClipPitchFrame]) -> PitchDetectionResult {
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: frames.isEmpty ? 0 : Double(voiced) / Double(frames.count),
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: Double(frames.count) / 62.5,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

    static func withoutSounds(_ set: PitchEditSet) -> PitchEditSet {
        set.withSegments(set.segments.filter { $0.origin != .unpitched })
    }

    // MARK: - Codable (§1.4)

    @Test("codable: a sound writes origin; a detected note writes NO origin key; the raw values are pinned")
    func originIsWrittenOnlyWhenNotDetected() throws {
        #expect(NoteOrigin.allCases.map(\.rawValue) == ["detected", "transition", "unpitched"],
                "the raw strings are wire values: additive-only, never rename")
        let sound = NoteSegment(startSeconds: 1, endSeconds: 1.2, detectedHz: 220,
                                detectedConfidence: 0.5, origin: .unpitched)
        let note = NoteSegment(startSeconds: 1, endSeconds: 1.2, detectedHz: 220,
                               detectedConfidence: 0.5)
        let soundJSON = try #require(String(data: JSONEncoder().encode(sound), encoding: .utf8))
        let noteJSON = try #require(String(data: JSONEncoder().encode(note), encoding: .utf8))
        #expect(soundJSON.contains(#""origin":"unpitched""#), "\(soundJSON)")
        // The negative control on the same encoder: omitted at the default.
        #expect(!noteJSON.contains("origin"), "\(noteJSON)")
        let slide = NoteSegment(startSeconds: 1, endSeconds: 1.2, detectedHz: 220,
                                detectedConfidence: 0.5, origin: .transition)
        for segment in [sound, note, slide] {
            let back = try JSONDecoder().decode(NoteSegment.self,
                                                from: JSONEncoder().encode(segment))
            #expect(back == segment)
            #expect(back.origin == segment.origin)
        }
    }

    @Test("codable: an UNKNOWN or missing origin reads as .detected, and the rest of the note survives")
    func unknownOriginHealsToDetected() throws {
        let id = UUID()
        let unknown = #"""
        {"id":"\#(id.uuidString)","startSeconds":1,"endSeconds":1.5,"detectedHz":220,
         "detectedConfidence":0.8,"pitchOffsetCents":40,"origin":"hummed"}
        """#
        let decoded = try JSONDecoder().decode(NoteSegment.self, from: Data(unknown.utf8))
        #expect(decoded.origin == .detected)
        #expect(decoded.id == id && decoded.pitchOffsetCents == 40 && decoded.endSeconds == 1.5)
        // Healed values re-save as today's bytes: no key at all.
        let resaved = try #require(String(data: JSONEncoder().encode(decoded), encoding: .utf8))
        #expect(!resaved.contains("origin"))
        // A whole SET with one note of an unknown origin still opens: a decode
        // of the enum itself would throw here and lose the project.
        let set = #"""
        {"analysisVersion":1,"segments":[{"id":"\#(id.uuidString)","startSeconds":1,
         "endSeconds":1.5,"detectedHz":220,"detectedConfidence":0.8,"origin":"hummed"}]}
        """#
        let opened = try JSONDecoder().decode(PitchEditSet.self, from: Data(set.utf8))
        #expect(opened.segments.map(\.origin) == [.detected])
        let missing = #"""
        {"id":"\#(id.uuidString)","startSeconds":1,"endSeconds":1.5,"detectedHz":220,
         "detectedConfidence":0.8}
        """#
        #expect(try JSONDecoder().decode(NoteSegment.self, from: Data(missing.utf8)).origin
                == .detected)
    }

    // MARK: - entersPitchCurve (§1.6, R21)

    @Test("entersPitchCurve: every note enters; a sound enters only once something is asked of it (R21)")
    func entersPitchCurveTruthTable() {
        func sound(_ edit: (inout NoteSegment) -> Void = { _ in }) -> NoteSegment {
            var s = NoteSegment(startSeconds: 1, endSeconds: 1.2, detectedHz: 220,
                                detectedConfidence: 0.5, origin: .unpitched)
            edit(&s)
            return s
        }
        let note = NoteSegment(startSeconds: 1, endSeconds: 1.2, detectedHz: 220,
                               detectedConfidence: 0.5)
        let slide = NoteSegment(startSeconds: 1, endSeconds: 1.2, detectedHz: 220,
                                detectedConfidence: 0.5, origin: .transition)
        #expect(note.entersPitchCurve, "an untouched NOTE is in the curve, as before U-A")
        #expect(slide.entersPitchCurve)
        #expect(!sound().entersPitchCurve, "an untouched sound must stay dry")
        #expect(sound { $0.pitchOffsetCents = 300 }.entersPitchCurve, "a moved sound renders moved (R21)")
        #expect(sound { $0.pitchOffsetCents = -1 }.entersPitchCurve)
        #expect(sound { $0.driftScale = 0 }.entersPitchCurve, "a shape on a sound is never a silent no-op")
        #expect(sound { $0.vibratoDepthCents = 20 }.entersPitchCurve)
        // Levels are the mask's business, never the curve's.
        #expect(!sound { $0.isCleared = true }.entersPitchCurve)
        #expect(!sound { $0.amplitudeDb = -6 }.entersPitchCurve)
        // `-0.0` is no edit, as everywhere in this type.
        #expect(!sound { $0.pitchOffsetCents = -0.0 }.entersPitchCurve)
        // Origin is not an edit: a sound is identity like a note.
        #expect(sound().isIdentity && !sound().isEdited)
    }

    @Test("curve: a shaped sound with nothing to shape is NAMED in unresolvedShapingSegmentIDs, never silently dropped")
    func aShapedSoundIsReportedNotDropped() {
        let shaped = NoteSegment(startSeconds: 1, endSeconds: 1.2, detectedHz: 220,
                                 detectedConfidence: 0.5, driftScale: 0, origin: .unpitched)
        let curve = PitchCorrectionCurve.make(editSet: PitchEditSet(segments: [shaped]))
        #expect(curve.unresolvedShapingSegmentIDs == [shaped.id])
    }

    // MARK: - The two builders (§1.6, U4)

    @Test("builders: both add the three sounds as IDENTITY .unpitched segments, drawn at the borrowed note")
    func bothBuildersAddIdentitySounds() throws {
        let result = Self.soundsResult()
        let editor = PitchNoteTable.build(from: result)
        // Ids are minted per build, so the two tables are compared without them.
        #expect(editor.editSet.segments.map(\.startSeconds)
                    == PitchNoteTable.detected(from: result).segments.map(\.startSeconds),
                "the plain builder and its report variant built different tables")
        #expect(editor.editSet.segments.map(\.origin)
                    == PitchNoteTable.detected(from: result).segments.map(\.origin))
        let finder = try #require(editor.unpitched)
        #expect(finder.skipped == nil)
        #expect(finder.sounds.count == 3)

        for build in [editor.editSet,
                      PitchAutoCorrect.editSet(from: result, options: PitchAutoCorrectOptions())] {
            let notes = build.segments.filter { $0.origin == .detected }
            let sounds = build.segments.filter { $0.origin == .unpitched }
            #expect(notes.count == 2, "positive control: the two notes are there")
            #expect(sounds.count == 3)
            #expect(sounds.allSatisfy { $0.isIdentity })
            #expect(sounds.allSatisfy { $0.glideFollow == 0 }, "a sound never follows")
            // Anchors: A (220) for the first, B (247) for the other two.
            #expect(sounds.map(\.detectedHz) == [notes[0].detectedHz, notes[1].detectedHz,
                                                 notes[1].detectedHz])
            // The sounds fill gaps: nothing overlaps (canonical healed nothing).
            for (a, b) in zip(build.segments, build.segments.dropFirst()) {
                #expect(a.endSeconds <= b.startSeconds)
            }
            #expect(sounds.map(\.startSeconds) == finder.sounds.map(\.startSeconds))
            #expect(sounds.map(\.endSeconds) == finder.sounds.map(\.endSeconds))
        }
        #expect(editor.editSet.isIdentity, "a fresh editor table must still bend nothing")
    }

    /// ⭐ RENDER NEUTRALITY AT THE BUILDER: for every preset, the set WITH its
    /// sounds builds the SAME curve (a value, spans and unresolved ids) as the
    /// same set without them, contour and all. Natural's 110 ms ramp beside a
    /// 96 ms sound is the §1.6 normalisation case, so this can fail.
    @Test("builders: every preset's curve is identical with and without its sounds; Hard Tune leaves no sound unresolved")
    func everyPresetRendersAsBeforeSoundsExisted() {
        let result = Self.soundsResult()
        for preset in PitchCorrectionPreset.allCases {
            let build = PitchAutoCorrect.build(from: result, options: preset.options())
            let set = build.editSet
            #expect(set.segments.filter { $0.origin == .unpitched }.count == 3,
                    "\(preset): positive control, the sounds are in the set")
            #expect(set.segments.filter { $0.origin == .unpitched }.allSatisfy { $0.isIdentity },
                    "\(preset) put an edit on a sound")
            let with = PitchCorrectionCurve.make(editSet: set, contour: result.frames)
            let without = PitchCorrectionCurve.make(editSet: Self.withoutSounds(set),
                                                    contour: result.frames)
            #expect(with == without, "\(preset): the sounds changed the curve")
            #expect(with.unresolvedShapingSegmentIDs.isEmpty,
                    "\(preset): a segment could not be shaped (\(with.unresolvedShapingSegmentIDs))")
        }
        // Hard Tune really did shape the notes (the control for "unresolved is empty").
        let hard = PitchAutoCorrect.editSet(from: result,
                                            options: PitchCorrectionPreset.hardTune.options())
        #expect(hard.segments.filter { $0.origin == .detected }.allSatisfy { $0.wantsContourShaping })
    }

    @Test("builders: strength 0 never runs the finder; no notes is reported as noNotes, not silence")
    func theReportNamesWhatHappened() {
        let result = Self.soundsResult()
        let zero = PitchAutoCorrect.build(from: result, options: PitchAutoCorrectOptions(strength: 0))
        #expect(zero.editSet == .empty)
        #expect(zero.unpitched == nil)

        // Two seconds of floor and one loud unvoiced stretch, but no voiced
        // frame at all: nothing to borrow a pitch from.
        let period = 1.0 / 62.5
        let unvoiced = (0..<150).map { i in
            ClipPitchFrame(timeSeconds: Double(i) * period, frequencyHz: nil, confidence: 0.3,
                           levelDbfs: (60..<70).contains(i) ? -30 : -60,
                           absence: .belowConfidence)
        }
        let none = PitchAutoCorrect.build(from: Self.result(unvoiced),
                                          options: PitchAutoCorrectOptions())
        #expect(none.editSet.isEmpty)
        #expect(none.unpitched?.skipped == .noNotes)
        let editor = PitchNoteTable.build(from: Self.result(unvoiced))
        #expect(editor.editSet.isEmpty)
        #expect(editor.unpitched?.skipped == .noNotes)
    }
}
