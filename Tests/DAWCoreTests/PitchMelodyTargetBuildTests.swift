import Foundation
import Testing
@testable import DAWCore

// Tune to Melody, phase 2 — THE `melody` PARAMETER ON `PitchAutoCorrect` (lane W7-TTM).
// Design `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §3.2, §3.3, §3.6.
// `melody: nil` is the old path (the env-gated golden proves it byte for byte against code
// captured before the edit; the always-on test here keeps it so). A melody makes one segment
// per ROW of `PitchMelodyTarget.plan` (`PitchAutoCorrect.melodyBuild`).
// Not `@MainActor` (pure DAWCore).

enum MelodyBuildFx {
    static func json(_ set: PitchEditSet) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return MelodyGolden.normalised(String(decoding: (try? encoder.encode(set)) ?? Data(), as: UTF8.self))
    }

    static func json(_ segments: [NoteSegment]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return MelodyGolden.normalised(String(decoding: (try? encoder.encode(segments)) ?? Data(), as: UTF8.self))
    }

    static func result(_ frames: [ClipPitchFrame], rate: Double) -> PitchDetectionResult {
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: Double(voiced) / Double(max(1, frames.count)), frameRateHz: rate,
            analysisSampleRateHz: 16_000, sourceSampleRateHz: 48_000, windowStartSeconds: 0,
            windowDurationSeconds: Double(frames.count) / rate, confidenceThreshold: 0.9,
            silenceFloorDbfs: -70, minFrequencyHz: 46.875, maxFrequencyHz: 2093.75)
    }

    /// Each held part's own scale note, spanning the part exactly (§3.6's invariance melody).
    static func ownNotes(_ frames: [ClipPitchFrame], rate: Double, scale: PitchCorrectionScale,
                         shift: Double) -> [PitchMelodyTarget.MelodyNote] {
        let whole = PitchAutoCorrect.splitClipShift(shift).whole
        return PitchNoteSplitter.parts(in: frames, frameRateHz: rate).filter { $0.kind == .held }.map {
            PitchMelodyTarget.MelodyNote(
                startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                midi: Int(scale.nearestAllowedMidi(to: PitchCorrectionMath.midi(fromHz: $0.centreHz) + whole)))
        }
    }

    /// The step-in-one-part fixture (`stepInsideOnePartCutsAtTheCrossing`) after 70 quiet
    /// frames, then a 6-frame breath (−30 dB, unvoiced) and quiet to frame 200.
    static func stepWithBreath() -> [ClipPitchFrame] {
        MelodyFx.gap(from: 0, count: 70) + MelodyFx.held(59.6, from: 70, count: 30)
            + MelodyFx.held(60.4, from: 100, count: 15) + MelodyFx.gap(from: 115, count: 6, level: -30)
            + MelodyFx.gap(from: 121, count: 80)
    }

    static let stepMelody = PitchMelodyTarget.Request(notes: [MelodyFx.note(70, 105, 59),
                                                              MelodyFx.note(105, 130, 61)])
}

@Suite("Tune to Melody phase 2: the melody parameter on PitchAutoCorrect")
struct PitchMelodyTargetBuildTests {

    static var synthetic: [MelodyGolden.Contour] {
        ((try? MelodyGolden.corpus()) ?? []).filter { !$0.name.hasPrefix("real-") }
    }

    /// `melody: nil` and an omitted `melody` are one path: same table, same sounds, no
    /// `melody` on the result. (The golden compares that path with the code BEFORE the edit.)
    @Test("melody nil is the melody-less pass, field for field")
    func melodyNilIsTheOldPath() {
        let contours = Self.synthetic
        #expect(contours.count == 4)
        for contour in contours {
            for preset in MelodyGolden.presets {
                for shift in MelodyGolden.shifts {
                    let options = preset.options()
                    let omitted = PitchAutoCorrect.build(contour: contour.frames, frameRateHz: contour.rate,
                                                         options: options, clipShiftSemitones: shift)
                    let explicit = PitchAutoCorrect.build(contour: contour.frames, frameRateHz: contour.rate,
                                                          options: options, clipShiftSemitones: shift,
                                                          melody: nil)
                    #expect(MelodyBuildFx.json(omitted.editSet) == MelodyBuildFx.json(explicit.editSet))
                    #expect(omitted.unpitched == explicit.unpitched)
                    #expect(explicit.melody == nil)
                }
            }
        }
    }

    /// §3.6's invariance, on the WHOLE table this time (sounds and set fields included): a
    /// melody of each held part's own scale note makes exactly the scale pass's set, ids
    /// excluded, under every preset with the product's slide shape, three scales, both
    /// octave rules and three clip shifts. The applied plan reports nothing, and its segment
    /// ids are the set's note ids in order.
    @Test("invariance: the melody pass of each part's own scale note IS the scale pass")
    func fullTableInvariance() {
        var compared = 0
        for contour in Self.synthetic {
            for scale in MelodyGolden.scales {
                for shift in MelodyGolden.shifts {
                    let notes = MelodyBuildFx.ownNotes(contour.frames, rate: contour.rate, scale: scale, shift: shift)
                    for preset in MelodyGolden.presets {
                        let options = preset.options(scale: scale)
                        let plain = PitchAutoCorrect.build(contour: contour.frames, frameRateHz: contour.rate,
                                                           options: options, clipShiftSemitones: shift)
                        for match in PitchMelodyTarget.OctaveMatch.allCases {
                            let tuned = PitchAutoCorrect.build(
                                contour: contour.frames, frameRateHz: contour.rate, options: options,
                                clipShiftSemitones: shift,
                                melody: .init(notes: notes, octaveMatch: match))
                            let label = "\(contour.name) \(scale.displayName) \(preset.rawValue) \(match) \(shift)"
                            #expect(MelodyBuildFx.json(tuned.editSet) == MelodyBuildFx.json(plain.editSet), "\(label)")
                            #expect(tuned.unpitched == plain.unpitched, "\(label)")
                            let applied = tuned.melody
                            #expect(applied?.plan.cutsAdded.isEmpty == true && applied?.plan.unmatchedParts.isEmpty == true
                                    && applied?.plan.outvotedNotes.isEmpty == true, "\(label)")
                            let noteIDs = tuned.editSet.segments.filter { $0.origin != .unpitched }.map(\.id)
                            #expect(applied?.segmentIDs == noteIDs, "\(label)")
                            compared += 1
                        }
                    }
                }
            }
        }
        #expect(compared == 4 * 3 * 3 * 4 * 2)
    }

    /// The step fixture (one part "H45", sung 59.6 then 60.4) against A = 59, B = 61: the
    /// melody cuts it at the sung step (frame 100 here). By hand, Natural (strength 0.85):
    /// 0.85 × −60 = −51 c and 0.85 × +60 = +51 c, both scales 1. Hard Tune (strength 1):
    /// −60 c and +60 c, both scales 0. Two `.detected` notes, abutting at t100, and the
    /// applied ids are those two notes'.
    @Test("a melody pass cuts one sung part into two notes at the sung step")
    func melodyModeCutsOnePart() throws {
        let frames = MelodyBuildFx.stepWithBreath()
        #expect(MelodyFx.kinds(MelodyFx.parts(frames)) == "H45")
        for (preset, cents, scale) in [(PitchCorrectionPreset.natural, 51.0, 1.0), (.hardTune, 60.0, 0.0)] {
            let built = PitchAutoCorrect.build(contour: frames, frameRateHz: MelodyFx.rate,
                                               options: preset.options(), melody: MelodyBuildFx.stepMelody)
            let notes = built.editSet.segments.filter { $0.origin != .unpitched }
            #expect(notes.count == 2, "\(preset)")
            guard notes.count == 2 else { continue }
            #expect(abs(notes[0].pitchOffsetCents + cents) < 1e-6 && abs(notes[1].pitchOffsetCents - cents) < 1e-6,
                    "\(preset): \(notes.map(\.pitchOffsetCents))")
            #expect(notes.allSatisfy { $0.driftScale == scale && $0.vibratoScale == scale && $0.origin == .detected })
            #expect(notes[0].endSeconds == MelodyFx.t(100) && notes[1].startSeconds == MelodyFx.t(100))
            #expect(built.melody?.segmentIDs == notes.map(\.id))
            #expect(built.melody?.plan.cutsAdded.map(\.placement) == [.crossing])
        }
    }

    /// Two runs at 60.3 and 62.3, a melody over the first only, Hard Tune. The second part is
    /// unmatched: `.asSung` leaves it identity (offset 0, both scales 1, even under Hard
    /// Tune); `.toScale` gives it exactly the melody-less pass's segment (−30 c, scales 0).
    @Test("§3.3 row 1: a part under a rest stays as sung, or goes to the scale when asked")
    func unmatchedAsSungVersusToScale() throws {
        let frames = MelodyFx.held(60.3, from: 0, count: 40) + MelodyFx.gap(from: 40, count: 20)
            + MelodyFx.held(62.3, from: 60, count: 40)
        let options = PitchCorrectionPreset.hardTune.options()
        let notes = [MelodyFx.note(0, 40, 60)]
        let plain = PitchAutoCorrect.build(contour: frames, frameRateHz: MelodyFx.rate, options: options)
        let second = plain.editSet.segments.filter { $0.origin != .unpitched && $0.startSeconds == MelodyFx.t(60) }
        #expect(second.count == 1)
        let sung = PitchAutoCorrect.build(contour: frames, frameRateHz: MelodyFx.rate, options: options,
                                          melody: .init(notes: notes, unmatched: .asSung))
        let sungSecond = sung.editSet.segments.filter { $0.origin != .unpitched && $0.startSeconds == MelodyFx.t(60) }
        #expect(sungSecond.count == 1)
        #expect(sungSecond.first.map { $0.pitchOffsetCents == 0 && $0.driftScale == 1 && $0.vibratoScale == 1 } == true)
        #expect(sung.melody?.plan.unmatchedParts == [1])
        let scaled = PitchAutoCorrect.build(contour: frames, frameRateHz: MelodyFx.rate, options: options,
                                            melody: .init(notes: notes, unmatched: .toScale))
        let scaledSecond = scaled.editSet.segments.filter { $0.origin != .unpitched && $0.startSeconds == MelodyFx.t(60) }
        #expect(MelodyBuildFx.json(scaledSecond) == MelodyBuildFx.json(second))
        #expect(scaledSecond.first.map { abs($0.pitchOffsetCents + 30) < 1e-6 } == true)
    }

    /// Strength 0 is the structural identity whatever the target: `.empty`, no sounds, no plan.
    @Test("strength 0 with a melody is still the empty set")
    func strengthZeroIsEmpty() {
        let frames = MelodyBuildFx.stepWithBreath()
        let built = PitchAutoCorrect.build(contour: frames, frameRateHz: MelodyFx.rate,
                                           options: PitchAutoCorrectOptions(strength: 0),
                                           melody: MelodyBuildFx.stepMelody)
        #expect(built.editSet == .empty)
        #expect(built.unpitched == nil && built.melody == nil)
    }

    /// Every entry point carries the melody: `build(from:)`, `editSet(contour:)` and
    /// `editSet(from:)` make `build(contour:)`'s melody table, which differs from the
    /// melody-less one (so a dropped forward cannot pass).
    @Test("build(from:), editSet(contour:) and editSet(from:) forward the melody")
    func entryPointsForwardTheMelody() {
        let frames = MelodyBuildFx.stepWithBreath()
        let result = MelodyBuildFx.result(frames, rate: MelodyFx.rate)
        let options = PitchCorrectionPreset.natural.options()
        let melody = MelodyBuildFx.stepMelody
        let reference = MelodyBuildFx.json(PitchAutoCorrect.build(contour: frames, frameRateHz: MelodyFx.rate,
                                                                  options: options, melody: melody).editSet)
        #expect(reference != MelodyBuildFx.json(PitchAutoCorrect.build(contour: frames, frameRateHz: MelodyFx.rate,
                                                                       options: options).editSet))
        let fromResult = PitchAutoCorrect.build(from: result, options: options, melody: melody)
        #expect(MelodyBuildFx.json(fromResult.editSet) == reference)
        #expect(fromResult.melody != nil)
        #expect(MelodyBuildFx.json(PitchAutoCorrect.editSet(contour: frames, frameRateHz: MelodyFx.rate,
                                                            options: options, melody: melody)) == reference)
        #expect(MelodyBuildFx.json(PitchAutoCorrect.editSet(from: result, options: options, melody: melody)) == reference)
    }

    /// A breath right after the cut part borrows the NEARER ROW: the second piece, sung at
    /// 60.4, not the whole part's median (59.6). By hand: its anchor is hz(60.4) under the
    /// melody and hz(59.6) without one, and the `.unpitched` segment is drawn there.
    @Test("a sound borrows the row drawn beside it, not the whole part")
    func soundsBorrowTheRowBesideThem() throws {
        let frames = MelodyBuildFx.stepWithBreath()
        let options = PitchCorrectionPreset.natural.options()
        let tuned = PitchAutoCorrect.build(contour: frames, frameRateHz: MelodyFx.rate, options: options,
                                           melody: MelodyBuildFx.stepMelody)
        let plain = PitchAutoCorrect.build(contour: frames, frameRateHz: MelodyFx.rate, options: options)
        let tunedSound = try #require(tuned.unpitched?.sounds.first)
        let plainSound = try #require(plain.unpitched?.sounds.first)
        let lastRow = try #require(tuned.melody?.plan.pieces.last)
        // The finder clamps a sound to its neighbour's edge (t114 + 1/62.5 may differ from t115 by an ulp).
        #expect(abs(tunedSound.startSeconds - MelodyFx.t(115)) < 1e-9)
        #expect(tunedSound.anchorHz.bitPattern == lastRow.centreHz.bitPattern)
        #expect(abs(PitchCorrectionMath.midi(fromHz: tunedSound.anchorHz) - 60.4) < 1e-9)
        #expect(abs(PitchCorrectionMath.midi(fromHz: plainSound.anchorHz) - 59.6) < 1e-9)
        let drawn = tuned.editSet.segments.filter { $0.origin == .unpitched }
        #expect(drawn.map(\.detectedHz) == [tunedSound.anchorHz])
    }
}
