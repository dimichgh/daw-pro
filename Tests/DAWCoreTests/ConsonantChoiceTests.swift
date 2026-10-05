import Foundation
import Testing
@testable import DAWCore

// NT-C2-F1 (W7-D2): RE-RUNNING A PRESET MUST NOT SWITCH AN EXPLICIT
// CONSONANTS-OFF BACK ON.
//
// `PitchEditSet.keepsConsonantsUntuned` was a plain Bool, so it could not tell
// an OFF somebody CHOSE (`setClipConsonantProtection(enabled: false)`) from an
// OFF nobody chose (a set saved before natural tuning, a memberwise one). A
// preset re-run builds a NEW set, seeded ON, and carried nothing, so a chosen
// OFF came back ON. The stored state is now `PitchEditSet.consonantProtection`
// (three cases, one per encoding), and `ProjectStore.autoCorrectClipPitchReport`
// keeps it unless nobody chose it.
//
// Pure and nonisolated (`MainActorOccupancySiteTests` Leg C caps `@MainActor`
// suites). The store half (the {legacy, natural} x {chosen ON, chosen OFF,
// never chosen} matrix, undo, the update doors) is `PitchCorrectionWriterTests`'
// NT-C2-F1 block; the render-digest half is DAWEngineTests'
// `ConsonantChoiceDigestTests`.
@Suite("NT-C2-F1 — a preset re-run keeps a chosen consonant setting (W7-D2)")
struct ConsonantChoiceTests {

    static let idA = UUID(uuidString: "D2D2D2D2-0000-4000-8000-00000000000A")!
    static let idB = UUID(uuidString: "D2D2D2D2-0000-4000-8000-00000000000B")!
    static let idS = UUID(uuidString: "D2D2D2D2-0000-4000-8000-00000000005D")!
    static let idC = UUID(uuidString: "D2D2D2D2-0000-4000-8000-00000000000C")!

    /// A (+150 c) and B abut (a soft join), an untouched SOUND S, then C
    /// (-40 c) after a gap. The same notes the goldens were captured from.
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

    /// A vocal tuned before natural tuning: every set-level field legacy.
    static func legacy() -> PitchEditSet { PitchEditSet(segments: notes(), retuneMs: 80) }

    /// Each golden rebuilt by TODAY's code, the way it was built at capture.
    /// Its bytes matching the frozen literal is the positive control that the
    /// literal is the set its name says, and that the code still builds it.
    static func rebuilt(_ name: String) -> PitchEditSet? {
        switch name {
        case "legacy": return legacy()
        case "presetNatural":
            // W7-NTU (2026-10-04): today's preset output ALSO writes
            // `autoCorrectReplaceableStamp`, which this frozen literal predates.
            // The ONE key is cleared here, so the bytes below still test every
            // other byte; `PitchEditReplaceableStampTests` pins that the output
            // carries it, and that the literal (without it) decodes to today's
            // whole-set rule.
            var output = PitchEditSet.seeded(analysisVersion: 1, segments: notes(), retuneMs: 110,
                                             partKinds: [:], seedPolicy: .preset)
                .stampedAsAutoCorrectOutput()
            output.autoCorrectReplaceableStamp = nil
            return output
        case "upgraded": return legacy().upgradedToNaturalTuning()
        case "legacyConsonantsOn":
            var set = legacy()
            set.keepsConsonantsUntuned = true
            return set
        case "voiceSizeOnly":
            var set = legacy()
            set.formantCorrection = 0.5
            return set
        default: return nil
        }
    }

    /// What each golden's consonant state decodes to: an OFF in a file saved
    /// before the record is always one nobody chose.
    static let goldenStates: [String: PitchEditSet.ConsonantProtection] = [
        "legacy": .offByDefault, "presetNatural": .on, "upgraded": .on,
        "legacyConsonantsOn": .on, "voiceSizeOnly": .offByDefault,
    ]

    static func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: - The goldens

    // ⛔ FROZEN: captured by W7-D2 on the tree BEFORE any W7-D2 edit (2026-09-27 04:35,
    // `scratchpad/w7/D2/golden-capture.txt`). Never regenerate them from the current code,
    // or the gate compares the code with itself.
    static let goldens: [(name: String, json: String, stamp: String)] = [
        ("legacy", #"{"analysisVersion":1,"retuneMs":80,"segments":[{"detectedConfidence":0.9,"detectedHz":220,"endSeconds":0.6,"id":"D2D2D2D2-0000-4000-8000-00000000000A","pitchOffsetCents":150,"startSeconds":0.2},{"detectedConfidence":0.9,"detectedHz":240,"endSeconds":0.95,"id":"D2D2D2D2-0000-4000-8000-00000000000B","startSeconds":0.6},{"detectedConfidence":0.3,"detectedHz":240,"endSeconds":1.05,"id":"D2D2D2D2-0000-4000-8000-00000000005D","origin":"unpitched","startSeconds":0.95},{"detectedConfidence":0.9,"detectedHz":260,"endSeconds":1.5,"id":"D2D2D2D2-0000-4000-8000-00000000000C","pitchOffsetCents":-40,"startSeconds":1.1}]}"#,
         "60b74b2ed2607b31"),
        ("presetNatural", #"{"analysisVersion":1,"autoCorrectStamp":"12da63bde6b83a8b","formantCorrection":1,"keepsConsonantsUntuned":true,"retuneMs":110,"segments":[{"detectedConfidence":0.9,"detectedHz":220,"endSeconds":0.6,"id":"D2D2D2D2-0000-4000-8000-00000000000A","pitchOffsetCents":150,"startSeconds":0.2},{"detectedConfidence":0.9,"detectedHz":240,"endSeconds":0.95,"id":"D2D2D2D2-0000-4000-8000-00000000000B","startSeconds":0.6},{"detectedConfidence":0.3,"detectedHz":240,"endSeconds":1.05,"id":"D2D2D2D2-0000-4000-8000-00000000005D","origin":"unpitched","startSeconds":0.95},{"detectedConfidence":0.9,"detectedHz":260,"endSeconds":1.5,"id":"D2D2D2D2-0000-4000-8000-00000000000C","pitchOffsetCents":-40,"startSeconds":1.1}],"transitionSlope":3000}"#,
         "12da63bde6b83a8b"),
        ("upgraded", #"{"analysisVersion":1,"formantCorrection":1,"keepsConsonantsUntuned":true,"retuneMs":80,"segments":[{"detectedConfidence":0.9,"detectedHz":220,"endSeconds":0.6,"id":"D2D2D2D2-0000-4000-8000-00000000000A","pitchOffsetCents":150,"startSeconds":0.2},{"detectedConfidence":0.9,"detectedHz":240,"endSeconds":0.95,"id":"D2D2D2D2-0000-4000-8000-00000000000B","startSeconds":0.6},{"detectedConfidence":0.3,"detectedHz":240,"endSeconds":1.05,"id":"D2D2D2D2-0000-4000-8000-00000000005D","origin":"unpitched","startSeconds":0.95},{"detectedConfidence":0.9,"detectedHz":260,"endSeconds":1.5,"id":"D2D2D2D2-0000-4000-8000-00000000000C","pitchOffsetCents":-40,"startSeconds":1.1}],"transitionSlope":3000}"#,
         "a281f342b8d0299b"),
        ("legacyConsonantsOn", #"{"analysisVersion":1,"keepsConsonantsUntuned":true,"retuneMs":80,"segments":[{"detectedConfidence":0.9,"detectedHz":220,"endSeconds":0.6,"id":"D2D2D2D2-0000-4000-8000-00000000000A","pitchOffsetCents":150,"startSeconds":0.2},{"detectedConfidence":0.9,"detectedHz":240,"endSeconds":0.95,"id":"D2D2D2D2-0000-4000-8000-00000000000B","startSeconds":0.6},{"detectedConfidence":0.3,"detectedHz":240,"endSeconds":1.05,"id":"D2D2D2D2-0000-4000-8000-00000000005D","origin":"unpitched","startSeconds":0.95},{"detectedConfidence":0.9,"detectedHz":260,"endSeconds":1.5,"id":"D2D2D2D2-0000-4000-8000-00000000000C","pitchOffsetCents":-40,"startSeconds":1.1}]}"#,
         "d0b884a9fc0b1020"),
        ("voiceSizeOnly", #"{"analysisVersion":1,"formantCorrection":0.5,"retuneMs":80,"segments":[{"detectedConfidence":0.9,"detectedHz":220,"endSeconds":0.6,"id":"D2D2D2D2-0000-4000-8000-00000000000A","pitchOffsetCents":150,"startSeconds":0.2},{"detectedConfidence":0.9,"detectedHz":240,"endSeconds":0.95,"id":"D2D2D2D2-0000-4000-8000-00000000000B","startSeconds":0.6},{"detectedConfidence":0.3,"detectedHz":240,"endSeconds":1.05,"id":"D2D2D2D2-0000-4000-8000-00000000005D","origin":"unpitched","startSeconds":0.95},{"detectedConfidence":0.9,"detectedHz":260,"endSeconds":1.5,"id":"D2D2D2D2-0000-4000-8000-00000000000C","pitchOffsetCents":-40,"startSeconds":1.1}]}"#,
         "b76a160aaf108c57"),
    ]

    // MARK: - (a) Bytes: every set saved before the record re-saves as it was

    @Test("NT-C2-F1 (a) goldens: five sets saved before the record decode and re-save byte for byte, stamps unchanged")
    func goldensReSaveByteIdentical() throws {
        let encoder = Self.sortedEncoder()
        #expect(Self.goldens.count == 5 && Set(Self.goldens.map(\.name)) == Set(Self.goldenStates.keys))
        // Positive control on the literals: three carry the key (as `true`),
        // two do not, and NONE carries an explicit `false`.
        #expect(Self.goldens.filter { $0.json.contains(#""keepsConsonantsUntuned":true"#) }.count == 3)
        #expect(Self.goldens.allSatisfy { !$0.json.contains(#""keepsConsonantsUntuned":false"#) })
        for golden in Self.goldens {
            let bytes = Data(golden.json.utf8)
            #expect(bytes.count > 500 && golden.json.contains(#""segments""#), "\(golden.name): an empty literal")
            let decoded = try JSONDecoder().decode(PitchEditSet.self, from: bytes)
            #expect(try encoder.encode(decoded) == bytes,
                    "\(golden.name) re-saved with different bytes: an omit rule broke")
            #expect(decoded.contentStamp == golden.stamp,
                    "\(golden.name): its content stamp moved, so a reopened preset set would ask again")
            #expect(decoded.consonantProtection == Self.goldenStates[golden.name],
                    "\(golden.name) decoded its consonant state wrongly")
            // Today's code still builds the same bytes from the same notes.
            let rebuilt = try #require(Self.rebuilt(golden.name))
            #expect(try encoder.encode(rebuilt) == bytes, "\(golden.name): the code no longer builds the golden")
            #expect(rebuilt == decoded)
        }
        // The preset's golden still reads as exactly what the preset wrote.
        let preset = try JSONDecoder().decode(
            PitchEditSet.self, from: Data(try #require(Self.goldens.first { $0.name == "presetNatural" }).json.utf8))
        #expect(preset.hasHandEditsSinceAutoCorrect == false)
    }

    @Test("NT-C2-F1 codable: absent is off by default, true is on, an explicit false is off by choice; each re-saves as it was")
    func threeStatesThreeEncodings() throws {
        let encoder = Self.sortedEncoder()
        let legacyJSON = try #require(Self.goldens.first { $0.name == "legacy" }).json
        // An explicit `false` spliced into the legacy golden (keys sorted:
        // it lands between `analysisVersion` and `retuneMs`).
        let chosenJSON = legacyJSON.replacingOccurrences(
            of: #""analysisVersion":1,"retuneMs""#,
            with: #""analysisVersion":1,"keepsConsonantsUntuned":false,"retuneMs""#)
        #expect(chosenJSON != legacyJSON, "control: the splice found its anchor")
        let chosen = try JSONDecoder().decode(PitchEditSet.self, from: Data(chosenJSON.utf8))
        #expect(chosen.consonantProtection == .offByChoice)
        #expect(!chosen.keepsConsonantsUntuned)
        #expect(try encoder.encode(chosen) == Data(chosenJSON.utf8), "a chosen OFF did not re-save as it was")

        var set = Self.legacy()
        for state in PitchEditSet.ConsonantProtection.allCases {
            set.consonantProtection = state
            let text = String(decoding: try encoder.encode(set), as: UTF8.self)
            switch state {
            case .offByDefault: #expect(!text.contains("keepsConsonantsUntuned"))
            case .on: #expect(text.contains(#""keepsConsonantsUntuned":true"#))
            case .offByChoice: #expect(text.contains(#""keepsConsonantsUntuned":false"#))
            }
            #expect(text.contains(#""segments""#), "control: the probe reads the payload")
            let back = try JSONDecoder().decode(PitchEditSet.self, from: Data(text.utf8))
            #expect(back == set, "\(state) did not survive a save")
            #expect(back.consonantProtection == state)
        }
        // The memberwise Bool says on or off, never "chosen".
        #expect(PitchEditSet(segments: Self.notes()).consonantProtection == .offByDefault)
        #expect(PitchEditSet(segments: Self.notes(), keepsConsonantsUntuned: true).consonantProtection == .on)
        #expect(PitchEditSet.empty.consonantProtection == .offByDefault)
    }

    // MARK: - The Bool reading

    @Test("NT-C2-F1 the Bool reading: true is on; false switches an ON off by default, and never records or erases a choice")
    func boolReadingNeverRecordsAChoice() {
        typealias State = PitchEditSet.ConsonantProtection
        let rules: [(start: State, write: Bool, expected: State)] = [
            (.offByDefault, true, .on), (.offByDefault, false, .offByDefault),
            (.on, true, .on), (.on, false, .offByDefault),
            (.offByChoice, true, .on), (.offByChoice, false, .offByChoice),
        ]
        var set = Self.legacy()
        for (start, write, expected) in rules {
            set.consonantProtection = start
            #expect(set.keepsConsonantsUntuned == (start == .on), "\(start) reads wrongly")
            set.keepsConsonantsUntuned = write
            #expect(set.consonantProtection == expected, "\(start) written \(write) became \(set.consonantProtection)")
        }
    }

    // MARK: - Carry: a chosen OFF survives every rebuild (`nonLegacy` exercises only ON)

    @Test("NT-C2-F1 carry: withSegments, the note transforms, a Codable round trip and D4-1 on a new set keep a chosen OFF")
    func chosenOffCarriesThroughRebuilds() throws {
        var set = Self.legacy().upgradedToNaturalTuning()
        set.consonantProtection = .offByChoice
        #expect(!set.predatesNaturalTuning, "precondition: a NEW set, so D4-1 is inert")
        var notes = set.segments
        notes[1].pitchOffsetCents = 120
        #expect(set.withSegments(notes).consonantProtection == .offByChoice)
        let dragged = try set.applyingNotePitchOffsets(
            [NotePitchOffset(segmentId: Self.idB, offsetCents: -80)], clipId: UUID())
        #expect(dragged.segments != set.segments, "control: the drag moved a note")
        #expect(dragged.consonantProtection == .offByChoice, "the drag's transform forgot the choice")
        #expect(try set.applyingTransitionSmoothness(centsPerSecond: 6000).consonantProtection == .offByChoice)
        #expect(try set.applyingNoteTransition(segmentId: Self.idA, widthMs: 120, clipId: UUID())
                    .consonantProtection == .offByChoice)
        #expect(set.afterHandEdit(from: set).consonantProtection == .offByChoice)
        let back = try JSONDecoder().decode(PitchEditSet.self, from: try JSONEncoder().encode(set))
        #expect(back == set && back.consonantProtection == .offByChoice)
        #expect(set.stampedAsAutoCorrectOutput().consonantProtection == .offByChoice)
    }

    // MARK: - The natural-tuning update keeps a chosen OFF (the C4 slope precedent)

    @Test("NT-C2-F1 update: the natural-tuning update keeps a chosen OFF and still switches an unchosen one ON")
    func updateKeepsAChosenOff() throws {
        var chosenOff = Self.legacy()
        chosenOff.consonantProtection = .offByChoice
        #expect(chosenOff.predatesNaturalTuning, "a consonant choice alone does not make a vocal new")
        let updated = chosenOff.upgradedToNaturalTuning()
        #expect(updated.consonantProtection == .offByChoice, "the update switched a chosen OFF back on")
        #expect(updated.formantCorrection == PitchEditSet.newSetFormantCorrection
                    && updated.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope
                    && !updated.predatesNaturalTuning, "the rest of the update did not happen")
        // D4-1's home, on a real first edit: the same update.
        var moved = chosenOff
        moved.segments[1].pitchOffsetCents = 60
        let edited = moved.afterHandEdit(from: chosenOff)
        #expect(edited == moved.upgradedToNaturalTuning())
        #expect(edited.consonantProtection == .offByChoice)
        // Controls: nobody chose -> ON (X4); already ON -> ON.
        #expect(Self.legacy().upgradedToNaturalTuning().consonantProtection == .on)
        var on = Self.legacy()
        on.keepsConsonantsUntuned = true
        #expect(on.upgradedToNaturalTuning().consonantProtection == .on)
    }

    // MARK: - The tripwire the representation rests on

    /// The record remembers only an OFF because ON is the seed: "chosen ON"
    /// and "seeded ON" have one future only while every new set is seeded ON.
    @Test("NT-C2-F1 seed tripwire: every seam that creates a set seeds consonants ON (the record needs no chosen-ON state)")
    func seedIsOnTripwire() {
        let message: Comment = """
            A new set is no longer seeded with consonants ON. `PitchEditSet.ConsonantProtection` \
            records only a chosen OFF because ON was the seed; with this seed a chosen ON and a \
            seeded ON no longer share a future, so the record needs a chosen-ON state (and a new \
            encoding for it) before this seed can ship.
            """
        for policy in [PitchEditSet.SeedPolicy.editor, .preset] {
            #expect(PitchEditSet.seeded(analysisVersion: 1, segments: Self.notes(), retuneMs: 30,
                                        partKinds: [:], seedPolicy: policy).consonantProtection == .on,
                    message)
        }
        let result = NaturalTuningFieldCarryTests.slideResult()
        for preset in PitchCorrectionPreset.allCases {
            #expect(PitchAutoCorrect.editSet(from: result, options: preset.options())
                        .consonantProtection == .on, message)
        }
        #expect(PitchNoteTable.detected(from: result).consonantProtection == .on, message)
    }

    // MARK: - Not render material (the DAWCore half; the digest half is DAWEngineTests')

    @Test("NT-C2-F1 not render material: an OFF somebody chose masks, mixes and bends exactly like an OFF nobody chose")
    func choiceIsNotRenderMaterial() {
        let unchosen = Self.legacy()
        var chosen = unchosen
        chosen.consonantProtection = .offByChoice
        var on = unchosen
        on.keepsConsonantsUntuned = true
        #expect(unchosen != chosen, "control: the two states are different STORED states")
        #expect(!unchosen.isPitchIdentity, "control: the set bends pitch, so the mix could run")
        #expect(chosen.hasConsonantMix == unchosen.hasConsonantMix)
        #expect(chosen.consonantRegions() == unchosen.consonantRegions())
        #expect(on.consonantRegions() != unchosen.consonantRegions(), "control: the regions can differ")
        for second in stride(from: 0.0, through: 1.6, by: 0.01) {
            #expect(chosen.tunedWeight(atSourceSecond: second) == unchosen.tunedWeight(atSourceSecond: second))
        }
        for (ratio, semitones) in [(1.0, 0.0), (1.25, 0.0), (1.0, 2.0)] {
            #expect(chosen.consonantMixIsActive(stretchRatio: ratio, clipSemitones: semitones)
                        == unchosen.consonantMixIsActive(stretchRatio: ratio, clipSemitones: semitones))
            #expect(chosen.consonantMixInactiveReason(stretchRatio: ratio, clipSemitones: semitones)
                        == unchosen.consonantMixInactiveReason(stretchRatio: ratio, clipSemitones: semitones))
        }
        #expect(chosen.isIdentity == unchosen.isIdentity && chosen.isPitchIdentity == unchosen.isPitchIdentity)
        #expect(chosen.engagesFormantCurve == unchosen.engagesFormantCurve
                    && chosen.usesSoftJoins == unchosen.usesSoftJoins
                    && chosen.needsDetectedContour == unchosen.needsDetectedContour
                    && chosen.predatesNaturalTuning == unchosen.predatesNaturalTuning)
    }
}
