import Foundation
import Testing
@testable import DAWCore

// Natural tuning, NT-C step C0 (m23-nt, design
// `docs/design/2026-09-25-natural-tuning.md`: X2, X3, R16, R28, R29, §1(c),
// §2c, §4.c): THE FIELDS, THE SEED, THE REBUILD AND THE BYTES.
//
// Pure and nonisolated. The store-writer half of X2's carry gate needs a
// `ProjectStore` (main actor), so it lives in the existing
// `PitchCorrectionWriterTests` suite and reuses this file's census helpers.
//
// ⭐ HOW THE CARRY GATE STAYS HONEST WITHOUT READING A FUNCTION BODY (X2 rule 4):
//  1. `setLevelCensus` is a HAND-WRITTEN list, compared with `Mirror` over
//     `PitchEditSet.empty`. A new stored property turns it red.
//  2. `nonLegacy(_:)` must move EVERY census field off its legacy value, which
//     `fixtureDepartsFromLegacyOnEveryField` checks by `Mirror`, so a field
//     added to the census but left at legacy in the fixture turns red there.
//  3. The carry comparisons are `Mirror`-driven (`setLevelFields`), so once
//     1 and 2 are green a dropped field cannot hide.
@Suite("Natural tuning C0: fields, seeds, carry and byte identity (m23-nt)")
struct NaturalTuningFieldCarryTests {

    // MARK: - The census and its fixture

    /// EVERY stored property of `PitchEditSet`, by hand. Update this AND the
    /// fixture below AND check `withSegments` when a field is added.
    /// NT-C2-F1 (W7-D2): the consonant field is stored as
    /// `consonantProtection` (three states); `keepsConsonantsUntuned` is its
    /// computed on/off reading, so it is no longer a stored label.
    static let setLevelCensus: Set<String> = [
        "analysisVersion", "segments", "retuneMs", "autoCorrectStamp",
        // W7-NTU (2026-10-04): what a preset would REPLACE, stamped beside it.
        "autoCorrectReplaceableStamp",
        "formantCorrection", "consonantProtection", "transitionSlopeCentsPerSecond",
        // vf-18 (W9-SLFX, 2026-10-12): which notes a followed slide reads.
        "slideFollowRule",
    ]

    /// Every stored property except `segments`, as text. `String(describing:)`
    /// of a Double is its shortest exact round trip, so equal text is equal bits.
    static func setLevelFields(_ set: PitchEditSet) -> [String: String] {
        var out: [String: String] = [:]
        for child in Mirror(reflecting: set).children {
            guard let label = child.label, label != "segments" else { continue }
            out[label] = String(describing: child.value)
        }
        return out
    }

    /// `set` with every set-level field at a value that is NEITHER legacy NOR
    /// the seed's (formant 0.25, not nil or 1.0; slope 7000, not 0 or 3000), so
    /// a rebuild that re-seeds instead of carrying is caught too. The
    /// consonant state is `.on` here, the seed's; a chosen OFF (neither legacy
    /// nor the seed) has its own carry test, `ConsonantChoiceTests`.
    static func nonLegacy(_ set: PitchEditSet) -> PitchEditSet {
        var out = set
        out.analysisVersion = 7
        out.retuneMs = 80
        out.autoCorrectStamp = "0123456789abcdef"
        out.autoCorrectReplaceableStamp = "fedcba9876543210"
        out.formantCorrection = 0.25
        out.keepsConsonantsUntuned = true
        out.transitionSlopeCentsPerSecond = 7000
        // vf-18: the only non-legacy value (no seed writes it either).
        out.slideFollowRule = .holdAtOpenSide
        return out
    }

    static let idA = UUID(uuidString: "C0C0C0C0-0000-4000-8000-00000000000A")!
    static let idB = UUID(uuidString: "C0C0C0C0-0000-4000-8000-00000000000B")!
    static let idC = UUID(uuidString: "C0C0C0C0-0000-4000-8000-00000000000C")!

    /// Three notes: A and B abut (a soft join), C sits after a hole. A carries
    /// both natural-tuning note fields off their defaults.
    static func notes() -> [NoteSegment] {
        [NoteSegment(id: idA, startSeconds: 0.5, endSeconds: 1.0, detectedHz: 220,
                     detectedConfidence: 0.9, pitchOffsetCents: 40,
                     transitionOutMs: 150, glideFollow: 0.5),
         NoteSegment(id: idB, startSeconds: 1.0, endSeconds: 1.6, detectedHz: 247,
                     detectedConfidence: 0.9),
         NoteSegment(id: idC, startSeconds: 2.0, endSeconds: 2.5, detectedHz: 196,
                     detectedConfidence: 0.9, pitchOffsetCents: -20)]
    }

    static func fixture() -> PitchEditSet { nonLegacy(PitchEditSet(segments: notes())) }

    @Test("census: PitchEditSet's stored properties are exactly the hand-written list")
    func storedPropertiesAreTheCensus() {
        let labels = Mirror(reflecting: PitchEditSet.empty).children.compactMap(\.label)
        #expect(labels.count == Self.setLevelCensus.count)
        #expect(Set(labels) == Self.setLevelCensus,
                """
                PitchEditSet's stored properties changed (\(labels)). Add the field to \
                `setLevelCensus`, give it a non-legacy value in `nonLegacy(_:)`, and \
                check that `withSegments` and every rebuild carry it.
                """)
    }

    @Test("census: the fixture moves EVERY set-level field off its legacy value")
    func fixtureDepartsFromLegacyOnEveryField() {
        let legacy = Self.setLevelFields(.empty)
        let moved = Self.setLevelFields(Self.fixture())
        #expect(Set(moved.keys) == Self.setLevelCensus.subtracting(["segments"]))
        for (label, value) in moved {
            #expect(value != legacy[label],
                    "`\(label)` sits at its legacy value in the fixture, so a writer that drops it passes")
        }
    }

    // MARK: - Carry (X2 rule 2 and 4, the pure writers)

    @Test("carry: withSegments keeps every set-level field, and a memberwise rebuild would not")
    func withSegmentsCarriesEverything() {
        let before = Self.fixture()
        var notes = before.segments
        notes[1].pitchOffsetCents = 300
        let after = before.withSegments(notes.reversed())
        #expect(Self.setLevelFields(after) == Self.setLevelFields(before))
        // canonical, exactly as `init` heals: order restored, edit kept.
        #expect(after.segments.map(\.id) == [Self.idA, Self.idB, Self.idC])
        #expect(after.segments[1].pitchOffsetCents == 300)
        #expect(after.segments[0].transitionOutMs == 150 && after.segments[0].glideFollow == 0.5)
        // ⛔ The instrument can fail: today's rebuild shape (the one
        // `ProjectStore+PitchNoteEdits.swift:161` used before C0) drops fields
        // and this comparison SEES it.
        let memberwise = PitchEditSet(analysisVersion: before.analysisVersion,
                                      segments: notes, retuneMs: before.retuneMs)
        #expect(Self.setLevelFields(memberwise) != Self.setLevelFields(before))
    }

    @Test("carry: applyingNotePitchOffsets (the drag's draft and commit) keeps every set-level field")
    func draftRuleCarriesEverything() throws {
        let before = Self.fixture()
        let after = try before.applyingNotePitchOffsets(
            [NotePitchOffset(segmentId: Self.idB, offsetCents: -150)], clipId: UUID())
        #expect(Self.setLevelFields(after) == Self.setLevelFields(before))
        #expect(after.segments[1].pitchOffsetCents == -150)
        #expect(after.segments[0].transitionOutMs == 150 && after.segments[0].glideFollow == 0.5)
    }

    @Test("carry: a Codable round trip keeps every field, set-level and per-note")
    func codableRoundTripCarriesEverything() throws {
        let before = Self.fixture()
        let after = try JSONDecoder().decode(PitchEditSet.self,
                                             from: try JSONEncoder().encode(before))
        #expect(after == before)
        #expect(Self.setLevelFields(after) == Self.setLevelFields(before))
    }

    // MARK: - Codable rules (§1(b), §2b.1, §4.b.1)

    @Test("codable: every new key is ABSENT at legacy, and absent decodes to legacy")
    func absentIsLegacy() throws {
        let legacy = PitchEditSet(segments: Self.notes().map {
            NoteSegment(id: $0.id, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                        detectedHz: $0.detectedHz, detectedConfidence: $0.detectedConfidence)
        })
        let text = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        for key in ["formantCorrection", "keepsConsonantsUntuned", "transitionSlope",
                    "transitionOut", "glideFollow", "slideFollowRule"] {
            #expect(!text.contains("\"\(key)\""), "a legacy set wrote `\(key)`")
        }
        // Positive control: the same probe FINDS keys that are written.
        #expect(text.contains("\"detectedHz\""))
        let decoded = try JSONDecoder().decode(PitchEditSet.self, from: Data(text.utf8))
        #expect(decoded.formantCorrection == nil)
        #expect(decoded.keepsConsonantsUntuned == false)
        #expect(decoded.transitionSlopeCentsPerSecond == 0)
        #expect(decoded.slideFollowRule == .sungAtOpenSide)
        #expect(decoded.segments.allSatisfy { $0.transitionOutMs == 0 && $0.glideFollow == 0 })
        #expect(decoded.predatesNaturalTuning == false, "an identity set is not a tuned vocal")
    }

    @Test("codable: formantCorrection 0.0 is WRITTEN and reads back 0.0, never legacy nil")
    func zeroFormantIsNotLegacy() throws {
        var set = PitchEditSet(segments: Self.notes())
        set.formantCorrection = 0.0
        let text = String(decoding: try JSONEncoder().encode(set), as: UTF8.self)
        #expect(text.contains("\"formantCorrection\":0"))
        let back = try JSONDecoder().decode(PitchEditSet.self, from: Data(text.utf8))
        #expect(back.formantCorrection == 0.0)
        #expect(back.predatesNaturalTuning == false)
        set.formantCorrection = nil
        #expect(set.predatesNaturalTuning, "a tuned set with no amount predates the feature")
    }

    @Test("clamps: init and decode heal every new field to what applies")
    func clampsHeal() throws {
        func note(_ width: Double, _ follow: Double) -> NoteSegment {
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 220, detectedConfidence: 1,
                        transitionOutMs: width, glideFollow: follow)
        }
        #expect(note(10, 0).transitionOutMs == 30)
        #expect(note(5000, 0).transitionOutMs == 1000)
        #expect(note(-3, 0).transitionOutMs == 0)
        #expect(note(-0.0, 0).transitionOutMs.sign == .plus)
        #expect(note(.nan, 0).transitionOutMs == 0)
        #expect(note(120, 0).transitionOutMs == 120)
        #expect(note(0, 2).glideFollow == 1)
        #expect(note(0, -1).glideFollow == 0)
        #expect(note(0, .infinity).glideFollow == 0)
        func set(_ formant: Double?, _ slope: Double) -> PitchEditSet {
            PitchEditSet(segments: [], formantCorrection: formant,
                         transitionSlopeCentsPerSecond: slope)
        }
        #expect(set(1.5, 0).formantCorrection == 1)
        #expect(set(-0.5, 0).formantCorrection == 0)
        #expect(set(.nan, 0).formantCorrection == nil)
        #expect(set(nil, 100).transitionSlopeCentsPerSecond == 500)
        #expect(set(nil, 1e6).transitionSlopeCentsPerSecond == 20000)
        #expect(set(nil, -5).transitionSlopeCentsPerSecond == 0)
        #expect(set(nil, .nan).transitionSlopeCentsPerSecond == 0)
        // Decode routes THROUGH the clamping init (the `Clip` precedent).
        let json = #"""
        {"analysisVersion":1,"formantCorrection":3,"transitionSlope":100,"segments":[
         {"id":"C0C0C0C0-0000-4000-8000-00000000000A","startSeconds":0,"endSeconds":1,
          "detectedHz":220,"detectedConfidence":1,"transitionOut":10,"glideFollow":9}]}
        """#
        let decoded = try JSONDecoder().decode(PitchEditSet.self, from: Data(json.utf8))
        #expect(decoded.formantCorrection == 1)
        #expect(decoded.transitionSlopeCentsPerSecond == 500)
        #expect(decoded.segments[0].transitionOutMs == 30)
        #expect(decoded.segments[0].glideFollow == 1)
    }

    // MARK: - The seed (X3 as amended by R14, R29)

    /// Two held notes joined by a 0.3 s glide (longer than the splitter's
    /// 0.128 s scoop limit, so it is its own `.transition` part), a hole, and
    /// a third held note.
    static func slideResult() -> PitchDetectionResult {
        let rate = 62.5
        var frames: [ClipPitchFrame] = []
        var t = 0.0
        func push(_ hz: Double?, _ seconds: Double) {
            for _ in 0..<Int((seconds * rate).rounded()) {
                frames.append(ClipPitchFrame(timeSeconds: t, frequencyHz: hz,
                                             confidence: hz == nil ? 0.1 : 0.95,
                                             levelDbfs: hz == nil ? -80 : -12,
                                             absence: hz == nil ? .belowConfidence : nil))
                t += 1 / rate
            }
        }
        push(nil, 0.2)
        push(220, 0.6)
        let glide = Int((0.3 * rate).rounded())
        for i in 0..<glide {
            let u = Double(i + 1) / Double(glide + 1)
            frames.append(ClipPitchFrame(timeSeconds: t, frequencyHz: 220 * pow(1.5, u),
                                         confidence: 0.95, levelDbfs: -12, absence: nil))
            t += 1 / rate
        }
        push(330, 0.6)
        push(nil, 0.3)
        push(196, 0.5)
        push(nil, 0.2)
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count,
            voicedFrameCount: frames.filter { $0.frequencyHz != nil }.count,
            voicedFraction: 0.8, frameRateHz: rate, analysisSampleRateHz: 16_000,
            sourceSampleRateHz: 44_100, windowStartSeconds: 0,
            windowDurationSeconds: t, confidenceThreshold: 0.9,
            silenceFloorDbfs: -75, minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

    /// The splitter's kind at each segment's start. Segments and parts share
    /// start seconds bit for bit (both builders map parts one to one).
    static func kinds(of set: PitchEditSet, in result: PitchDetectionResult) -> [NotePart.Kind] {
        let parts = PitchNoteSplitter.parts(in: result.frames, frameRateHz: result.frameRateHz,
                                            onsetSeconds: [])
        return set.segments.map { segment in
            parts.first(where: { $0.startSeconds == segment.startSeconds })?.kind ?? .held
        }
    }

    @Test("seed, editor: new values on the set, glideFollow 1 on the slide only, and still identity (G-ID)")
    func editorSeed() throws {
        let result = Self.slideResult()
        let table = PitchNoteTable.detected(from: result)
        let kinds = Self.kinds(of: table, in: result)
        // Positive control: the fixture really has a slide part, or the
        // glideFollow leg below would pass on nothing.
        #expect(kinds.filter { $0 == .transition }.count == 1)
        #expect(kinds.filter { $0 == .held }.count == 3)
        #expect(table.formantCorrection == PitchEditSet.newSetFormantCorrection)
        #expect(table.keepsConsonantsUntuned)
        #expect(table.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope)
        for (segment, kind) in zip(table.segments, kinds) {
            #expect(segment.glideFollow == (kind == .transition ? 1 : 0),
                    "\(kind) part seeded glideFollow \(segment.glideFollow)")
            #expect(segment.transitionOutMs == 0)
        }
        // ⛔ §4.b.1: none of the new fields enters an identity predicate, so a
        // fresh editor table still renders as nothing and saves as notes.
        #expect(table.isIdentity && table.isPitchIdentity && !table.isEmpty)
        #expect(table.segments.allSatisfy { !$0.isEdited }, "a seeded slide lit the edited accent")
        #expect(!table.predatesNaturalTuning)
    }

    @Test("seed, preset: the same set-level values, and every slide stays AS SUNG (glideFollow 0)")
    func presetSeed() {
        let result = Self.slideResult()
        for preset in PitchCorrectionPreset.allCases {
            let set = PitchAutoCorrect.editSet(from: result, options: preset.options())
            #expect(set.segments.count == 4, "\(preset)")
            #expect(set.formantCorrection == PitchEditSet.newSetFormantCorrection, "\(preset)")
            #expect(set.keepsConsonantsUntuned, "\(preset)")
            #expect(set.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope,
                    "\(preset)")
            #expect(set.segments.allSatisfy { $0.glideFollow == 0 && $0.transitionOutMs == 0 },
                    "\(preset) tilted a slide")
            #expect(!set.predatesNaturalTuning, "\(preset)")
        }
        // Strength 0 is the structural identity, `.empty`, and stays legacy.
        let none = PitchAutoCorrect.editSet(from: result, options: PitchAutoCorrectOptions(strength: 0))
        #expect(none == .empty)
        #expect(none.formantCorrection == nil && !none.keepsConsonantsUntuned
                    && none.transitionSlopeCentsPerSecond == 0)
    }

    @Test("seed: the POLICY gates glideFollow, so a preset handed part kinds still cannot tilt a slide")
    func seedPolicyGatesTheFollow() {
        let notes = Self.notes()
        let kinds: [UUID: NotePart.Kind] = [Self.idA: .held, Self.idB: .transition, Self.idC: .held]
        let editor = PitchEditSet.seeded(analysisVersion: 1, segments: notes, retuneMs: 30,
                                         partKinds: kinds, seedPolicy: .editor)
        let preset = PitchEditSet.seeded(analysisVersion: 1, segments: notes, retuneMs: 30,
                                         partKinds: kinds, seedPolicy: .preset)
        #expect(editor.segments.map(\.glideFollow) == [0.5, 1, 0])
        #expect(preset.segments.map(\.glideFollow) == [0.5, 0, 0])
        #expect(Self.setLevelFields(editor) == Self.setLevelFields(preset))
    }

    // MARK: - Bytes: a project WRITTEN BY 813c415 (G-FILE, §4.g)

    /// Three contentStamps measured on the 813c415 build when the golden
    /// below was written (the rich hand set, a Hard Tune pass, an editor table
    /// with one edit), in document order.
    static let goldenStamps = ["3e23e7a2beb300ec", "14d6381c32e3871f", "a9cb68cd7f2e1aa4"]

    @Test("bytes: a project.json written by 813c415 re-saves BYTE-IDENTICAL, stamps and all")
    func legacyProjectResavesByteIdentical() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ntc0-bytes-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let golden = Data(Self.golden813c415.utf8)
        let opened = ProjectBundle.normalizedBundleURL(
            fromPath: root.appendingPathComponent("Opened").path)
        try fm.createDirectory(at: opened, withIntermediateDirectories: true)
        try golden.write(to: opened.appendingPathComponent("project.json"))

        // The product's read path, then its write path.
        let document = try ProjectBundle.read(from: opened)
        let saved = ProjectBundle.normalizedBundleURL(
            fromPath: root.appendingPathComponent("Saved").path)
        try ProjectBundle.write(document: document,
                                plan: ProjectBundle.MediaPlan(copies: [], refs: [:], warnings: []),
                                to: saved)
        let resaved = try Data(contentsOf: saved.appendingPathComponent("project.json"))

        // Positive controls first: the literal decoded into the three sets it
        // was written from, so "identical" below is not two empty documents.
        let sets = document.tracks.flatMap(\.clips).compactMap(\.pitchEdits)
        #expect(golden.count > 5000)
        #expect(sets.count == 3)
        #expect(sets.map(\.segments.count) == [3, 4, 4])
        // G-FILE's stamp leg: identical content stamps, so a reopened preset
        // set is still "exactly what the preset wrote" (no spurious confirm).
        #expect(sets.map(\.contentStamp) == Self.goldenStamps)
        #expect(sets.map(\.hasHandEditsSinceAutoCorrect) == [false, false, true])
        // Every new field decoded as legacy.
        for set in sets {
            #expect(set.formantCorrection == nil)
            #expect(!set.keepsConsonantsUntuned)
            #expect(set.transitionSlopeCentsPerSecond == 0)
            #expect(set.segments.allSatisfy { $0.transitionOutMs == 0 && $0.glideFollow == 0 })
            // U-A: no 813c415 note carries an origin key, so every one reads
            // as `.detected` and re-saves without the key (the byte check
            // below is this field's G-FILE gate too).
            #expect(set.segments.allSatisfy { $0.origin == .detected })
        }
        #expect(sets.map(\.predatesNaturalTuning) == [true, true, true])

        #expect(resaved == golden,
                "a project written by 813c415 re-saved with different bytes: an omit rule broke")
    }
}

extension NaturalTuningFieldCarryTests {
    /// `project.json` as `ProjectBundle.write` produced it at git 813c415
    /// (captured 2026-09-25 by a throwaway test on that tree, before any C0
    /// edit). ⛔ FROZEN: never regenerate it from the current code, or the
    /// gate compares the code with itself.
    static let golden813c415 = #"""
{
  "masterVolume" : 1,
  "name" : "NT-C golden",
  "savedAt" : "2026-09-26T00:07:34Z",
  "schemaVersion" : 1,
  "tracks" : [
    {
      "clips" : [
        {
          "id" : "CD5441C3-487A-4CDF-8B3F-560316C701E2",
          "isAIGenerated" : false,
          "lengthBeats" : 8,
          "media" : null,
          "name" : "rich",
          "pitchEdits" : {
            "analysisVersion" : 1,
            "autoCorrectStamp" : "3e23e7a2beb300ec",
            "retuneMs" : 80,
            "segments" : [
              {
                "amplitudeDb" : -3,
                "cleared" : true,
                "detectedConfidence" : 0.93,
                "detectedHz" : 220,
                "driftScale" : 0.5,
                "endSeconds" : 1.2,
                "formantOffsetSemitones" : 1,
                "id" : "C0000000-0000-4000-8000-00000000000A",
                "pitchOffsetCents" : -35,
                "startSeconds" : 0.5,
                "timeEndDeltaSeconds" : -0.01,
                "timeStartDeltaSeconds" : 0.01,
                "vibratoDepthCents" : 20,
                "vibratoOnsetSeconds" : 0.1,
                "vibratoRateHz" : 5.5,
                "vibratoScale" : 0.25
              },
              {
                "detectedConfidence" : 0.95,
                "detectedHz" : 246.9,
                "endSeconds" : 1.9,
                "id" : "C0000000-0000-4000-8000-00000000000B",
                "pitchOffsetCents" : 100,
                "startSeconds" : 1.2
              },
              {
                "detectedConfidence" : 0.9,
                "detectedHz" : 196,
                "endSeconds" : 2.8,
                "id" : "C0000000-0000-4000-8000-00000000000C",
                "startSeconds" : 2.2
              }
            ]
          },
          "startBeat" : 0
        },
        {
          "id" : "28A87BBD-E832-4AC5-A16D-70CE3806A5C6",
          "isAIGenerated" : false,
          "lengthBeats" : 8,
          "media" : null,
          "name" : "hardTune",
          "pitchEdits" : {
            "analysisVersion" : 1,
            "autoCorrectStamp" : "14d6381c32e3871f",
            "segments" : [
              {
                "detectedConfidence" : 0.95,
                "detectedHz" : 220.00000000000006,
                "driftScale" : 0,
                "endSeconds" : 0.8320000000000006,
                "id" : "83483513-B18B-430B-809B-AB03F37DC708",
                "startSeconds" : 0.20800000000000007,
                "vibratoScale" : 0
              },
              {
                "detectedConfidence" : 0.95,
                "detectedHz" : 269.4438717061495,
                "endSeconds" : 1.1040000000000008,
                "id" : "D250DFBA-EE39-4093-B581-8181BD706915",
                "startSeconds" : 0.8320000000000006
              },
              {
                "detectedConfidence" : 0.95,
                "detectedHz" : 330.00000000000006,
                "driftScale" : 0,
                "endSeconds" : 1.7280000000000013,
                "id" : "C1E9DC6F-7751-4C04-9150-F199CC3520B9",
                "pitchOffsetCents" : -1.9550008653880013,
                "startSeconds" : 1.1040000000000008,
                "vibratoScale" : 0
              },
              {
                "detectedConfidence" : 0.95,
                "detectedHz" : 196.00000000000003,
                "driftScale" : 0,
                "endSeconds" : 2.528000000000002,
                "id" : "543CDA6A-3844-4C08-A070-617404F46D84",
                "pitchOffsetCents" : -0.020156708658447542,
                "startSeconds" : 2.0320000000000014,
                "vibratoScale" : 0
              }
            ]
          },
          "startBeat" : 0
        },
        {
          "id" : "5FD5B801-FC31-431D-96EE-35838DADAD9A",
          "isAIGenerated" : false,
          "lengthBeats" : 8,
          "media" : null,
          "name" : "editorTable",
          "pitchEdits" : {
            "analysisVersion" : 1,
            "segments" : [
              {
                "detectedConfidence" : 0.95,
                "detectedHz" : 220.00000000000006,
                "endSeconds" : 0.8320000000000006,
                "id" : "BD3F09E6-75D4-4933-A059-898B84A99BCC",
                "pitchOffsetCents" : 250,
                "startSeconds" : 0.20800000000000007
              },
              {
                "detectedConfidence" : 0.95,
                "detectedHz" : 269.4438717061495,
                "endSeconds" : 1.1040000000000008,
                "id" : "AFF57C82-F5D0-432E-8155-275FCF88F6CE",
                "startSeconds" : 0.8320000000000006
              },
              {
                "detectedConfidence" : 0.95,
                "detectedHz" : 330.00000000000006,
                "endSeconds" : 1.7280000000000013,
                "id" : "6B4D2E35-694C-4AC1-8830-05C61C213F85",
                "startSeconds" : 1.1040000000000008
              },
              {
                "detectedConfidence" : 0.95,
                "detectedHz" : 196.00000000000003,
                "endSeconds" : 2.528000000000002,
                "id" : "83616910-0622-4A6C-8665-66795F42B4BF",
                "startSeconds" : 2.0320000000000014
              }
            ]
          },
          "startBeat" : 0
        },
        {
          "id" : "931681D2-3865-40E7-8AF7-38F49253AD98",
          "isAIGenerated" : false,
          "lengthBeats" : 4,
          "media" : null,
          "name" : "untuned",
          "startBeat" : 8
        }
      ],
      "id" : "4E15F8A3-3415-4473-8AB3-E37B68DC75BC",
      "isAIGenerated" : false,
      "isArmed" : false,
      "isMuted" : false,
      "isSoloed" : false,
      "kind" : "audio",
      "name" : "Vocals",
      "pan" : 0,
      "volume" : 1
    }
  ],
  "transport" : {
    "countInBars" : 1,
    "isLoopEnabled" : false,
    "isMetronomeEnabled" : false,
    "isPunchEnabled" : false,
    "loopEndBeat" : 16,
    "loopStartBeat" : 0,
    "positionBeats" : 0,
    "punchInBeat" : 0,
    "punchOutBeat" : 4,
    "tempoBPM" : 120,
    "timeSignature" : {
      "beatUnit" : 4,
      "beatsPerBar" : 4
    }
  }
}
"""#
}
