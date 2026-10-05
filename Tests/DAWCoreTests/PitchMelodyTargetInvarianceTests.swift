import Foundation
import Testing
@testable import DAWCore

// Tune to Melody M1 — the INVARIANCE gate and the structural properties of
// `PitchMelodyTarget.plan` (design `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md`
// §3.6). Not `@MainActor` (pure DAWCore; the suite cap is nearly used up).
//
// ⭐ **INVARIANCE (§3.6):** a melody whose notes are each held part's own scale note,
// spanning the part exactly, must reproduce the scale pass's table — every row's span,
// detected pitch, confidence, origin and offset, bit for bit (ids excluded), and the same
// sounds. M1 compares the plan's rows to `PitchAutoCorrect.build`'s segments; phase 2 adds
// `editSet(melody:)` against `editSet` itself.
//
// The take is synthetic but detector-shaped: readings QUANTISED to SwiftF0's 25.79 c bins,
// with vibrato, a legato step, a slow glide (a `.transition`), a short note, a breath and a
// quiet floor (so the unpitched finder finds a sound). The test first checks that the
// splitter really made those structures, so a fixture that stopped exercising an axis fails.

enum MelodyTake {
    static let rate: Double = 62.5
    static let period: Double = 1 / 62.5
    static let bin: Double = 25.79
    static let baseHz: Double = 110

    /// A reading at fractional MIDI `midi`, snapped to the detector's bin grid.
    static func quantisedHz(_ midi: Double) -> Double {
        let cents = (midi - 45) * 100      // 110 Hz is MIDI 45
        let snapped = ((cents - 7) / bin).rounded(.toNearestOrEven) * bin + 7
        return baseHz * pow(2, snapped / 1200)
    }

    static func voiced(_ i: Int, midi: Double) -> ClipPitchFrame {
        ClipPitchFrame(timeSeconds: Double(i) * period, frequencyHz: quantisedHz(midi),
                       confidence: 0.9 + 0.001 * Double(i % 7), levelDbfs: -18, absence: nil)
    }

    static func quiet(_ i: Int, level: Double = -60) -> ClipPitchFrame {
        ClipPitchFrame(timeSeconds: Double(i) * period, frequencyHz: nil, confidence: 0.05,
                       levelDbfs: level, absence: .belowConfidence)
    }

    /// ±37 c of 5.5 Hz vibrato at frame i.
    static func wobble(_ i: Int) -> Double { 0.37 * sin(2 * .pi * 5.5 * Double(i) * period) }

    /// 1.5 s of quiet; a 6-frame breath; a legato step A3 → B3 with vibrato; a gap; C4, a
    /// 25-frame glide up a fourth, F4; a gap; a short D4 + 30 c; quiet to the end.
    static func frames() -> [ClipPitchFrame] {
        var out: [ClipPitchFrame] = []
        out += (0 ..< 94).map { quiet($0) }
        out += (94 ..< 100).map { quiet($0, level: -30) }
        out += (100 ..< 140).map { voiced($0, midi: 57 + wobble($0)) }
        out += (140 ..< 175).map { voiced($0, midi: 59 + wobble($0)) }
        out += (175 ..< 182).map { quiet($0) }
        out += (182 ..< 207).map { voiced($0, midi: 60 + 0.3 * wobble($0)) }
        out += (207 ..< 232).map { voiced($0, midi: 60 + 5 * Double($0 - 206) / 26) }
        out += (232 ..< 260).map { voiced($0, midi: 65 + 0.3 * wobble($0)) }
        out += (260 ..< 267).map { quiet($0) }
        out += (267 ..< 281).map { voiced($0, midi: 62.3) }
        out += (281 ..< 301).map { quiet($0) }
        return out
    }
}

/// SplitMix64: a seeded, platform-stable generator for the structural sweep.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Tune to Melody M1: invariance and structure (PitchMelodyTarget)")
struct PitchMelodyTargetInvarianceTests {

    static let shifts: [Double] = [0, 3, -2.3, 3.5, -0.5]

    static let scales: [PitchCorrectionScale] = [
        .chromatic, PitchCorrectionScale(tonicPitchClass: 0, mode: .major),
        PitchCorrectionScale(tonicPitchClass: 9, mode: .minor)
    ]

    /// Natural-like, Hard Tune and a gentle pass: the preset sets only strength and shape.
    static let presets: [(strength: Double, preserveVibrato: Bool)] = [
        (0.85, true), (1, false), (0.6, true)
    ]

    /// Every row of `plan` against every non-sound segment of `build`, field by field; `""`
    /// when they agree.
    static func mismatches(_ plan: PitchMelodyTarget.Plan, _ table: [NoteSegment]) -> [String] {
        guard plan.pieces.count == table.count else {
            return ["rows \(plan.pieces.count) vs segments \(table.count)"]
        }
        var out: [String] = []
        for (i, (piece, segment)) in zip(plan.pieces, table).enumerated() {
            if piece.startSeconds.bitPattern != segment.startSeconds.bitPattern
                || piece.endSeconds.bitPattern != segment.endSeconds.bitPattern {
                out.append("row \(i): span \(piece.startSeconds)–\(piece.endSeconds) vs \(segment.startSeconds)–\(segment.endSeconds)")
            }
            if piece.centreHz.bitPattern != segment.detectedHz.bitPattern {
                out.append("row \(i): detected \(piece.centreHz) vs \(segment.detectedHz)")
            }
            if piece.medianConfidence != segment.detectedConfidence {
                out.append("row \(i): confidence \(piece.medianConfidence) vs \(segment.detectedConfidence)")
            }
            let origin: NoteOrigin = piece.role == .transition ? .transition : .detected
            if origin != segment.origin { out.append("row \(i): origin \(origin) vs \(segment.origin)") }
            switch piece.role {
            case .matched:
                if piece.offsetCents?.bitPattern != segment.pitchOffsetCents.bitPattern {
                    out.append("row \(i): offset \(String(describing: piece.offsetCents)) vs \(segment.pitchOffsetCents)")
                }
            case .transition:
                // Identity under every preserve-vibrato preset and Hard Tune's (a-T).
                if segment.pitchOffsetCents != 0 { out.append("row \(i): slide offset \(segment.pitchOffsetCents)") }
            case .unmatched:
                out.append("row \(i): unmatched, but every held part has its own note")
            }
        }
        return out
    }

    /// The invariance on one contour, over every scale, preset, octave rule and the shift.
    static func invarianceFailures(_ frames: [ClipPitchFrame], rate: Double, shift: Double) -> [String] {
        let parts = PitchNoteSplitter.parts(in: frames, frameRateHz: rate)
        let whole = PitchAutoCorrect.splitClipShift(shift).whole
        var failures: [String] = []
        for scale in scales {
            let melody = parts.filter { $0.kind == .held }.map {
                PitchMelodyTarget.MelodyNote(
                    startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                    midi: Int(scale.nearestAllowedMidi(to: PitchCorrectionMath.midi(fromHz: $0.centreHz) + whole)))
            }
            for preset in presets {
                let options = PitchAutoCorrectOptions(scale: scale, strength: preset.strength,
                                                      preserveVibrato: preset.preserveVibrato)
                let built = PitchAutoCorrect.build(contour: frames, frameRateHz: rate, options: options,
                                                   clipShiftSemitones: shift)
                let table = built.editSet.segments.filter { $0.origin != .unpitched }
                for match in PitchMelodyTarget.OctaveMatch.allCases {
                    let label = "\(scale.displayName) s\(preset.strength) pv\(preset.preserveVibrato) \(match) shift \(shift)"
                    let plan = PitchMelodyTarget.plan(parts: parts, frames: frames, frameRateHz: rate,
                                                      melody: melody, octaveMatch: match,
                                                      strength: options.strength, clipShiftSemitones: shift)
                    failures += mismatches(plan, table).map { "\(label): \($0)" }
                    if !(plan.cutsAdded.isEmpty && plan.unmatchedParts.isEmpty && plan.unsungNotes.isEmpty
                         && plan.outvotedNotes.isEmpty && plan.chordsReduced.isEmpty
                         && plan.octaveFolded.isEmpty && plan.invalidNotes.isEmpty
                         && plan.partsWithoutFrames.isEmpty) {
                        failures.append("\(label): a report is not empty")
                    }
                    if plan.notesUsed != Array(melody.indices) { failures.append("\(label): notes used") }
                    // The sounds a melody pass would add: the finder over the plan's rows.
                    let sounds = PitchUnpitchedFinder.sounds(
                        in: frames, frameRateHz: rate,
                        notes: plan.pieces.map {
                            PitchUnpitchedFinder.Note(startSeconds: $0.startSeconds,
                                                      endSeconds: $0.endSeconds, hz: $0.centreHz)
                        })
                    if sounds != built.unpitched { failures.append("\(label): the finder disagrees") }
                }
            }
        }
        return failures
    }

    @Test("invariance: a melody of each held part's own scale note reproduces the scale pass",
          arguments: Self.shifts)
    func invariance(shift: Double) {
        let frames = MelodyTake.frames()
        let parts = PitchNoteSplitter.parts(in: frames, frameRateHz: MelodyTake.rate)
        // The fixture must exercise every axis it was written for.
        #expect(parts.filter { $0.kind == .held }.count >= 4, "\(parts.map(\.kind))")
        #expect(parts.contains { $0.kind == .transition }, "\(parts.map(\.kind))")
        let found = PitchUnpitchedFinder.sounds(in: frames, frameRateHz: MelodyTake.rate,
                                                notes: parts.map(PitchUnpitchedFinder.Note.init(part:)))
        #expect(!found.sounds.isEmpty, "no sound: \(String(describing: found.skipped))")
        let failures = Self.invarianceFailures(frames, rate: MelodyTake.rate, shift: shift)
        #expect(failures.isEmpty, "\(failures.prefix(8))")
    }

    /// D14 by hand: a part sung at 59.6 in a clip shifted +3.3 plays at 62.9 (+ the kept
    /// 0.3). Melody E♭4 (63): matched at sung + whole = 62.6 → 63 (exact and nearest agree);
    /// the recording goes to 63 − 3 = 60 → +40 c; it PLAYS 60 + 3.3 = 63.3, the written note
    /// plus the clip's own 30 c detune, as the scale rule plays a fractional shift.
    @Test("D14: the melody is matched at what PLAYS; the shift's fraction stays a detune")
    func clipShiftComposes() throws {
        let frames = MelodyFx.held(59.6, from: 0, count: 40)
        let part = try MelodyFx.unsplit(frames)
        let plan = PitchMelodyTarget.plan(parts: [part], frames: frames, frameRateHz: MelodyFx.rate,
                                          melody: [MelodyFx.note(0, 40, 63)], clipShiftSemitones: 3.3)
        #expect(plan.pieces.first?.targetMidi == 63)
        #expect(abs((plan.pieces.first?.offsetCents ?? .nan) - 40) < 1e-6)
        #expect(plan.octaveFolded.isEmpty)
        // Without the shift the same melody is a 340 c move: far.
        let unshifted = PitchMelodyTarget.plan(parts: [part], frames: frames, frameRateHz: MelodyFx.rate,
                                               melody: [MelodyFx.note(0, 40, 63)])
        #expect(abs((unshifted.pieces.first?.offsetCents ?? .nan) - 340) < 1e-6)
        #expect(unshifted.farMoves.count == 1)
    }

    /// 300 seeded random melodies (chords, overlaps, rests, notes under 60 ms) over the take,
    /// under both octave rules and the shifts. Every plan must keep the structure M2 relies on.
    @Test("structure: rows tile their part, cuts stay near their boundary, notes are accounted")
    func structureOverRandomMelodies() throws {
        let frames = MelodyTake.frames()
        let rate = MelodyTake.rate
        let parts = PitchNoteSplitter.parts(in: frames, frameRateHz: rate)
        let counts = try #require(PitchNoteSplitter.frameCounts(frameRateHz: rate))
        var generator = SplitMix64(state: 0x5EED_1004)
        var failures: [String] = []
        var cuts = 0, folds = 0, chords = 0, crossings = 0
        for trial in 0 ..< 300 {
            var melody: [PitchMelodyTarget.MelodyNote] = []
            for _ in 0 ..< Int.random(in: 3 ... 25, using: &generator) {
                let start = Double.random(in: 1.4 ... 4.6, using: &generator)
                let length = Double.random(in: 0.03 ... 0.8, using: &generator)
                let midi = Int.random(in: 48 ... 79, using: &generator)
                melody.append(.init(startSeconds: start, endSeconds: start + length, midi: midi))
                if Int.random(in: 0 ..< 6, using: &generator) == 0 {   // a chord tone
                    melody.append(.init(startSeconds: start, endSeconds: start + length,
                                        midi: midi + Int.random(in: -7 ... 7, using: &generator)))
                }
            }
            let match = trial % 2 == 0 ? PitchMelodyTarget.OctaveMatch.nearestOctave : .exact
            let shift = Self.shifts[trial % Self.shifts.count]
            let whole = PitchAutoCorrect.splitClipShift(shift).whole
            let plan = PitchMelodyTarget.plan(parts: parts, frames: frames, frameRateHz: rate,
                                              melody: melody, octaveMatch: match,
                                              strength: 1, clipShiftSemitones: shift)
            cuts += plan.cutsAdded.count
            crossings += plan.cutsAdded.filter { $0.placement == .crossing }.count
            folds += plan.octaveFolded.count
            chords += plan.chordsReduced.count
            func fail(_ message: String) { failures.append("trial \(trial): \(message)") }
            for (index, part) in parts.enumerated() {
                let rows = plan.pieces.filter { $0.partIndex == index }
                guard let first = rows.first, let last = rows.last else { fail("part \(index) has no row"); continue }
                if first.startSeconds.bitPattern != part.startSeconds.bitPattern
                    || last.endSeconds.bitPattern != part.endSeconds.bitPattern { fail("part \(index) edges") }
                for (a, b) in zip(rows, rows.dropFirst()) where a.endSeconds.bitPattern != b.startSeconds.bitPattern {
                    fail("part \(index) rows do not abut")
                }
                if rows.map(\.frameCount).reduce(0, +) != part.frameCount { fail("part \(index) frame counts") }
                if rows.count > 1, rows.contains(where: { $0.frameCount < counts.minimumNote }) {
                    fail("part \(index): a cut row shorter than a note \(rows.map(\.frameCount))")
                }
                if part.kind == .transition, rows.count != 1 || first.role != .transition { fail("slide \(index)") }
            }
            for cut in plan.cutsAdded where abs(cut.seconds - cut.melodyBoundarySeconds) > Double(counts.scoopLimit + 1) * MelodyTake.period {
                fail("cut \(cut.seconds) far from its boundary \(cut.melodyBoundarySeconds)")
            }
            for piece in plan.pieces {
                guard piece.role == .matched else {
                    if piece.offsetCents != nil { fail("an unmatched row has an offset") }
                    continue
                }
                guard let offset = piece.offsetCents, offset.isFinite,
                      let target = piece.targetMidi, let source = piece.melodyIndex else {
                    fail("a matched row without its numbers"); continue
                }
                let written = melody[source].midi
                if (target - written) % 12 != 0 || piece.octaveShift != (target - written) / 12 { fail("fold arithmetic") }
                let plays = PitchCorrectionMath.midi(fromHz: piece.centreHz) + whole
                if match == .exact, target != written { fail("exact moved the note") }
                if match == .nearestOctave, abs(Double(target) - plays) > 6 + 1e-9 { fail("fold not nearest") }
            }
            let valid = Set(melody.indices.filter { melody[$0].isValid })
            let used = Set(plan.notesUsed), unsung = Set(plan.unsungNotes), outvoted = Set(plan.outvotedNotes)
            if !used.isDisjoint(with: unsung) || !used.isDisjoint(with: outvoted) || !unsung.isDisjoint(with: outvoted)
                || used.union(unsung).union(outvoted) != valid {
                fail("notes are not partitioned")
            }
            if !Set(plan.chordsReduced).isSubset(of: valid) { fail("a reduced note is not valid") }
        }
        print("melody-structure| trials=300 cuts=\(cuts) crossings=\(crossings) folds=\(folds) chords=\(chords) failures=\(failures.count)")
        #expect(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(8))")
        // The sweep must actually exercise cuts, crossings, folds and chords.
        #expect(cuts > 20 && crossings > 0 && folds > 20 && chords > 20,
                "cuts \(cuts) crossings \(crossings) folds \(folds) chords \(chords)")
    }

    // MARK: The user's take (env-gated, read-only)

    /// `UNPITCHED_REAL_TAKE_DETECTPITCH` = the product's own `clip.detectPitch` response on
    /// the user's take (the finder suite's port check uses the same file). Read only.
    static let realTake = ProcessInfo.processInfo.environment["UNPITCHED_REAL_TAKE_DETECTPITCH"]

    private struct DetectPitchEnvelope: Decodable {
        let result: ClipPitchDetection
    }

    @Test("invariance on the user's take (env-gated)", .enabled(if: realTake != nil))
    func realTakeInvariance() throws {
        let path = try #require(Self.realTake)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try JSONDecoder().decode(DetectPitchEnvelope.self, from: data).result.pitch
        let parts = PitchNoteSplitter.parts(in: result.frames, frameRateHz: result.frameRateHz)
        var total = 0
        for shift in [0.0, 3, -2.3] {
            let failures = Self.invarianceFailures(result.frames, rate: result.frameRateHz, shift: shift)
            total += failures.count
            #expect(failures.isEmpty, "shift \(shift): \(failures.prefix(8))")
        }
        print("melody-invariance-real| frames=\(result.frames.count) parts=\(parts.count) "
              + "held=\(parts.filter { $0.kind == .held }.count) "
              + "transitions=\(parts.filter { $0.kind == .transition }.count) failures=\(total)")
    }
}
