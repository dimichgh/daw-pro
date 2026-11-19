import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x9-f1: a harmony part's range line names only what was MEASURED.
///
/// W8-X9R measured, on the real engine, the old FIXED suggestion: "sixth below" (moved up an octave, still too high)
/// was told "Try 'a sixth below' instead", and "fifth above" (moved down an octave) was told to try a third above,
/// which does not fit either. The line now names another §4.1 choice only when that choice, planned from the same
/// melody, key and chords, fits by the same rule; says when the part was moved and, when the move makes it another
/// choice's notes, which one; and otherwise says plainly that none of them fit.
///
/// Plants that must turn this suite red (W8-X9F1 PREDICTIONS P4): restore the fixed suggestion strings; suggest a
/// choice without checking that it fits; drop the moved clause.
///
/// p2-sing-x9-f3 (W8-X9F3B) RE-PINNED this suite. A harmony part now fits by its OWN rule (`KeyFitWeights`: mean out of
/// band ≤ 3.0 semitones and no note more than 7.0 over / 8.0 under the band, measured on the built-in voice by W8-X9F3)
/// instead of the key proposal's 0.25. What moved, and why: on the X9R fixture all four choices now FIT (their means are
/// 0.731 / 0.731 / 0.967 / 1.764, all under 3.0), so their lines are §14's "fits" lines; and every voice below that was
/// chosen to make a part MISS by a fraction of a semitone now lets it fit, so each was moved to a voice that misses
/// under the new rule and reaches the SAME branch with the SAME words (the old voice is checked to fit now, beside it).
/// The voices were found with a model of the rule (`$S/w8/X9F3B/model.py`) that first reproduced every value this
/// suite and `HarmonyPlannerTests` pinned under 0.25. Plant (a) of W8-X9F3B (the mean read from 0.25 again) reddens
/// `x9rTable` and `x9rLines`.
@Suite("HarmonyPlanner: the range line names only measured choices (p2-sing-x9-f1)")
struct HarmonyPlannerRangeLineTests {

    static let tempo = TempoMap(constantBPM: 120)
    static let cMajor = SongKey(tonicPitchClass: 0, mode: .major)
    /// `SingVoiceLibrary.builtInRange` (`Sources/AIServices/SingVoiceLibrary.swift:106`), copied: DAWCoreTests cannot
    /// import AIServices.
    static let builtIn = VoiceRange(p10Midi: 61.7, medianMidi: 65.9, p90Midi: 68.7)

    static let thirdAbove = HarmonySpec(interval: .third, direction: .above, chordSource: .none)
    static let sixthBelow = HarmonySpec(interval: .sixth, direction: .below, chordSource: .none)
    static let thirdBelow = HarmonySpec(interval: .third, direction: .below, chordSource: .none)
    static let fifthAbove = HarmonySpec(interval: .fifth, direction: .above, chordSource: .none)

    static let noneFit = " Try a different voice, or move the song's key."

    /// The rule before p2-sing-x9-f3 (a part fits at ≤ 0.25 semitones out of band, no per-note cap), kept ONLY to show
    /// that the words for a part that misses did not change: the threshold moved, the line did not.
    static let x9f1Rule: KeyFitWeights = {
        var weights = VoiceRangeFit.defaultWeights
        weights.harmonyAcceptOutOfBand = 0.25
        weights.harmonyNoteMaxAboveBand = .infinity
        weights.harmonyNoteMaxBelowBand = .infinity
        return weights
    }()

    static func note(_ pitch: Int, _ start: Double, _ length: Double = 1) -> MIDINote {
        MIDINote(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 500 + Int(start * 4)))!,
                 pitch: pitch, velocity: 100, startBeat: start, lengthBeats: length)
    }

    /// One note a beat (0.5 s at 120 BPM), from beat 0.
    static func melody(_ pitches: [Int]) -> (Track, Clip) {
        let notes = pitches.enumerated().map { note($0.element, Double($0.offset)) }
        let clip = Clip(name: "Melody", startBeat: 0, lengthBeats: Double(pitches.count), notes: notes,
                        lyrics: ClipLyrics(text: Array(repeating: "la", count: pitches.count).joined(separator: " ")))
        return (Track(name: "Lead", kind: .instrument, clips: [clip]), clip)
    }

    /// THE sing path's two calls: the derivation, then the height.
    static func line(_ clip: Clip, on track: Track, tracks: [Track]? = nil, spec: HarmonySpec, voice: VoiceRange,
                     lead: Int = 0, weights: KeyFitWeights = VoiceRangeFit.defaultWeights)
        -> (plan: HarmonyPlan, range: HarmonyRange) {
        let plan = HarmonyPlanner.derivedPart(clip: clip, on: track, tracks: tracks ?? [track], spec: spec,
                                              key: cMajor, partIndex: 1)
        return (plan, HarmonyPlanner.range(of: plan, clipStartBeat: clip.startBeat, tempoMap: tempo, voice: voice,
                                           leadOctaveShift: lead, weights: weights))
    }

    // MARK: - W8-X9R's fixture: the SING-6 line T1T2, C major, no chord snap, the built-in voice, the lead at 0

    @Test("X9R fixture: the measured table (octave, out-of-band, sides, cost, fits) for every choice")
    func x9rTable() throws {
        let clip = try SingPlannerTests.t1t2Clip()
        let track = Track(name: "Lead", kind: .instrument, clips: [clip])
        let weights = VoiceRangeFit.defaultWeights
        // W8-X9R's job statuses (MEASURED on the real engine): 0, +1, 0, −1. The heights did not move (the winner is
        // chosen by cost before `fits` is read); `fits` did (p2-sing-x9-f3): every mean is under 3.0 and every note
        // within the caps, so all four now FIT (they were all false at 0.25). W8-X9R heard all four sung in interval.
        let expected: [(HarmonySpec, Int, Double)] = [(Self.thirdAbove, 0, 0.731), (Self.sixthBelow, 1, 0.731),
                                                      (Self.thirdBelow, 0, 0.967), (Self.fifthAbove, -1, 1.764)]
        for (spec, shift, outOfBand) in expected {
            let (plan, range) = Self.line(clip, on: track, spec: spec, voice: Self.builtIn)
            let fit = try #require(range.fit)
            let sung = plan.notes.map { Double($0.pitch + 12 * range.octaveShift) }
            let over = (sung.max() ?? 0) - (Self.builtIn.p90Midi + weights.bandMarginSemitones)
            let under = (Self.builtIn.p10Midi - weights.bandMarginSemitones) - (sung.min() ?? 0)
            print(String(format: "X9F1-TABLE|%@|%+d|%.3f|%.3f|%.3f|%.3f|%@|over %.2f|under %.2f", spec.name,
                         range.octaveShift, fit.outOfBandSemitones, fit.fractionBelowBand, fit.fractionAboveBand,
                         fit.cost, range.fits ? "true" : "false", over, under))
            #expect(range.octaveShift == shift, "\(spec.name)")
            #expect(abs(fit.outOfBandSemitones - outOfBand) < 0.0005, "\(spec.name): \(fit.outOfBandSemitones)")
            #expect(fit.outOfBandSemitones <= weights.harmonyAcceptOutOfBand, "\(spec.name)")
            #expect(over <= weights.harmonyNoteMaxAboveBand && under <= weights.harmonyNoteMaxBelowBand,
                    "\(spec.name): over \(over), under \(under)")
            #expect(range.fits, "\(spec.name)")
        }
    }

    @Test("X9R fixture: every line, word for word (every choice fits the built-in voice; under 0.25 none did)")
    func x9rLines() throws {
        let clip = try SingPlannerTests.t1t2Clip()
        let track = Track(name: "Lead", kind: .instrument, clips: [clip])
        func sentence(_ spec: HarmonySpec, _ weights: KeyFitWeights = VoiceRangeFit.defaultWeights) -> String? {
            Self.line(clip, on: track, spec: spec, voice: Self.builtIn, weights: weights).range.sentence
        }
        // p2-sing-x9-f3: §14 "Part fits" / "Part moved", VERBATIM (no new words).
        #expect(sentence(Self.thirdAbove) == "Fits your voice.")
        #expect(sentence(Self.sixthBelow) == "I'll sing this part an octave higher.")
        #expect(sentence(Self.thirdBelow) == "Fits your voice.")
        #expect(sentence(Self.fifthAbove) == "I'll sing this part an octave lower.")
        // The same fixture at the old threshold: X9F1's lines, byte for byte (the words for a miss did not change).
        #expect(sentence(Self.thirdAbove, Self.x9f1Rule) == "This part goes higher than this voice usually sings. "
                + "'A sixth below' and 'a third below' don't fit this voice either." + Self.noneFit)
        #expect(sentence(Self.sixthBelow, Self.x9f1Rule) == "I'll sing this part an octave higher, which is the same "
                + "notes as 'a third above'. That's the closest fit, but it still goes higher than this voice usually "
                + "sings. 'A third above' and 'a third below' don't fit this voice either." + Self.noneFit)
        #expect(sentence(Self.thirdBelow, Self.x9f1Rule) == "This part goes lower than this voice usually sings. "
                + "'A third above' and 'a sixth below' don't fit this voice either." + Self.noneFit)
        #expect(sentence(Self.fifthAbove, Self.x9f1Rule) == "I'll sing this part an octave lower. That's the closest "
                + "fit, but it still goes lower than this voice usually sings. 'A third above', 'a sixth below' and "
                + "'a third below' don't fit this voice either." + Self.noneFit)
    }

    @Test("X9R fixture: 'sixth below' never suggests 'a sixth below'; 'fifth above' never suggests a part that misses")
    func x9rNeverSuggestsTheAskedOrAMiss() throws {
        let clip = try SingPlannerTests.t1t2Clip()
        let track = Track(name: "Lead", kind: .instrument, clips: [clip])
        // On the built-in voice every choice now fits (p2-sing-x9-f3), so no line names another one at all.
        for spec in [Self.thirdAbove, Self.sixthBelow, Self.thirdBelow, Self.fifthAbove] {
            let range = Self.line(clip, on: track, spec: spec, voice: Self.builtIn).range
            let line = try #require(range.sentence)
            #expect(range.fits && !line.contains("Try ") && !line.contains("either"), "\(spec.name): \(line)")
        }
        // The property itself, on the same melody, needs a voice where both asked parts miss: D2 to E2 (p2-sing-x9-f3
        // moved it here from the built-in voice; found with W8-X9F3B's model). There 'a third above' misses too and
        // 'a third below' fits, so each half below can fail.
        let narrow = VoiceRange(p10Midi: 38, medianMidi: 39, p90Midi: 40)
        let sixthRange = Self.line(clip, on: track, spec: Self.sixthBelow, voice: narrow).range
        let sixth = try #require(sixthRange.sentence)
        #expect(!sixthRange.fits)
        #expect(!sixth.contains("Try 'a sixth below'"))
        let fifthRange = Self.line(clip, on: track, spec: Self.fifthAbove, voice: narrow).range
        let fifth = try #require(fifthRange.sentence)
        #expect(!fifthRange.fits)
        var missed = 0, fitted = 0
        for other in [Self.thirdAbove, Self.sixthBelow, Self.thirdBelow] {
            // Each one measured on its own: one that misses may not be offered.
            if Self.line(clip, on: track, spec: other, voice: narrow).range.fits {
                fitted += 1
            } else {
                missed += 1
                #expect(!fifth.contains("Try 'a \(other.name)'"), "\(other.name)")
            }
        }
        #expect(missed == 2 && fitted == 1, "missed \(missed) fitted \(fitted)")
        #expect(sixth.hasSuffix(" Try 'a third below' instead."), "\(sixth)")
        #expect(fifth.hasSuffix(" Try 'a third below' instead."), "\(fifth)")
    }

    // MARK: - The line's branches, each pinned word for word (pre-registered, PREDICTIONS P6/P7)

    @Test("A part that fits reads §14 'Part fits' / 'Part moved' VERBATIM")
    func fittingLinesAreUnchanged() {
        let (track, clip) = Self.melody([60, 62, 64, 65, 67])
        let voice = VoiceRange(p10Midi: 60, medianMidi: 66, p90Midi: 72)
        let atZero = Self.line(clip, on: track, spec: Self.thirdAbove, voice: voice).range
        #expect(atZero.fits && atZero.octaveShift == 0)
        #expect(atZero.sentence == "Fits your voice.")
        let moved = Self.line(clip, on: track, spec: Self.sixthBelow, voice: voice).range
        #expect(moved.fits && moved.octaveShift == 1)
        #expect(moved.sentence == "I'll sing this part an octave higher.")
    }

    @Test("At the written octave, a fitting suggestion that happens to be §14's reads §14 'Part out of range' VERBATIM")
    func section14LowRowIsByteIdentical() {
        let (track, clip) = Self.melody([60, 62, 64, 65, 67])
        // p2-sing-x9-f3: moved from 59.5/64.5/69.5 (0.30 out of band: it fits now, checked below) to a voice two
        // semitones wide, where the third below misses by 3.6 on average and the third above still fits.
        let result = Self.line(clip, on: track, spec: Self.thirdBelow,
                               voice: VoiceRange(p10Midi: 65, medianMidi: 66, p90Midi: 67)).range
        #expect(result.octaveShift == 0 && !result.fits)
        #expect(result.sentence == "This part goes lower than this voice usually sings. Try 'a third above' instead.")
        let before = Self.line(clip, on: track, spec: Self.thirdBelow,
                               voice: VoiceRange(p10Midi: 59.5, medianMidi: 64.5, p90Midi: 69.5)).range
        #expect(before.fits && before.sentence == "Fits your voice.")
    }

    @Test("A moved part that is another choice's notes says which, both ways (derived from the notes, no table)")
    func inversionIsNamedBothWays() {
        let (track, clip) = Self.melody([60, 62, 64, 65, 67])
        // p2-sing-x9-f3: both voices keep their medians and narrow from 12 to 3 semitones (the old ones let the moved
        // part fit now: 0.60 out of band each, checked below).
        let up = Self.line(clip, on: track, spec: Self.sixthBelow,
                           voice: VoiceRange(p10Midi: 60, medianMidi: 61.5, p90Midi: 63)).range
        #expect(up.octaveShift == 1 && !up.fits)
        #expect(up.sentence == "I'll sing this part an octave higher, which is the same notes as 'a third above'. "
                + "That's the closest fit, but it still goes higher than this voice usually sings. "
                + "Try 'a third below' instead.")
        let down = Self.line(clip, on: track, spec: Self.thirdAbove,
                             voice: VoiceRange(p10Midi: 48, medianMidi: 49.5, p90Midi: 51)).range
        #expect(down.octaveShift == -1 && !down.fits)
        #expect(down.sentence == "I'll sing this part an octave lower, which is the same notes as 'a sixth below'. "
                + "That's the closest fit, but it still goes higher than this voice usually sings. "
                + "Try 'a third below' instead.")
        let upBefore = Self.line(clip, on: track, spec: Self.sixthBelow,
                                 voice: VoiceRange(p10Midi: 55.5, medianMidi: 61.5, p90Midi: 67.5)).range
        #expect(upBefore.fits && upBefore.sentence == "I'll sing this part an octave higher.")
        let downBefore = Self.line(clip, on: track, spec: Self.thirdAbove,
                                   voice: VoiceRange(p10Midi: 43.5, medianMidi: 49.5, p90Midi: 55.5)).range
        #expect(downBefore.fits && downBefore.sentence == "I'll sing this part an octave lower.")
    }

    @Test("Of the choices that fit, the cheapest is named, not the first in the menu")
    func cheapestFittingChoiceIsNamed() {
        let (track, clip) = Self.melody([55, 57, 59, 60, 62])
        // p2-sing-x9-f3: moved from 48/54/60 (the octave part fit there now, 1.2 out of band) to 51/54/57, same median.
        let voice = VoiceRange(p10Midi: 51, medianMidi: 54, p90Midi: 57)
        let octave = HarmonySpec(interval: .octave, direction: .above, chordSource: .none)
        let result = Self.line(clip, on: track, spec: octave, voice: voice).range
        #expect(result.sentence == "I'll sing this part two octaves lower. That's the closest fit, but it still goes "
                + "lower than this voice usually sings. Try 'a third below' instead.")
        // The control that makes the order matter: 'a third above' (first in the menu) fits too, at a higher cost.
        let first = Self.line(clip, on: track, spec: Self.thirdAbove, voice: voice).range
        let named = Self.line(clip, on: track, spec: Self.thirdBelow, voice: voice).range
        #expect(first.fits && named.fits)
        #expect((first.fit?.cost ?? 0) > (named.fit?.cost ?? .infinity))
    }

    @Test("Nothing measured, nothing named: another clip's notes, and a chord-notes part that needed no key")
    func unmeasuredLinesNameNothing() throws {
        let low = [48, 50, 52, 53, 55].enumerated().map { Self.note($0.element, Double($0.offset)) }
        let other = HarmonyPlanner.range(ofClipNotes: low, clipStartBeat: 0, tempoMap: Self.tempo,
                                         voice: VoiceRange(p10Midi: 84, medianMidi: 88, p90Midi: 92),
                                         leadOctaveShift: 0)
        #expect(other.sentence == "I'll sing this part two octaves higher. That's the closest fit, but it still goes "
                + "lower than this voice usually sings.")
        let five = [60, 62, 64, 65, 67].enumerated().map { Self.note($0.element, Double($0.offset)) }
        // p2-sing-x9-f3: moved from 70/72/74 (it fits there now, 1.4 out of band) to 69/70/71.
        let higher = HarmonyPlanner.range(ofClipNotes: five, clipStartBeat: 0, tempoMap: Self.tempo,
                                          voice: VoiceRange(p10Midi: 69, medianMidi: 70, p90Midi: 71),
                                          leadOctaveShift: 0)
        #expect(higher.sentence == "I'll sing this part an octave higher. That's the closest fit, but it still goes "
                + "higher than this voice usually sings.")
        #expect(HarmonyPlanner.range(ofClipNotes: five, clipStartBeat: 0, tempoMap: Self.tempo,
                                     voice: VoiceRange(p10Midi: 70, medianMidi: 72, p90Midi: 74),
                                     leadOctaveShift: 0).sentence == "I'll sing this part an octave higher.")

        // A chord under every melody note: the chord-notes part never needs its fill, so it has no key.
        let chordNotes = [(72, 67, 64), (72, 67, 64), (76, 72, 67)].enumerated().flatMap { i, chord in
            [chord.0, chord.1, chord.2].enumerated().map { j, pitch in
                MIDINote(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 900 + i * 3 + j))!,
                         pitch: pitch, velocity: 100, startBeat: Double(i), lengthBeats: 1)
            }
        }
        let clip = Clip(name: "Chords", startBeat: 0, lengthBeats: 3, notes: chordNotes,
                        lyrics: ClipLyrics(text: "la la la"))
        let track = Track(name: "Keys", kind: .instrument, clips: [clip])
        let plan = try HarmonyPlanner.chordTonePart(clip: clip, on: track, tracks: [track], rank: .second,
                                                    fillInterval: .third, fillChordSource: .none, key: nil,
                                                    partIndex: 1)
        try #require(plan.key == nil && plan.notes.map(\.pitch) == [67, 67, 72])
        let keyless = HarmonyPlanner.range(of: plan, clipStartBeat: 0, tempoMap: Self.tempo,
                                           voice: VoiceRange(p10Midi: 30, medianMidi: 34, p90Midi: 38),
                                           leadOctaveShift: 0)
        #expect(keyless.sentence == "I'll sing this part two octaves lower. That's the closest fit, but it still goes "
                + "higher than this voice usually sings.")
    }

    // MARK: - The property, over a grid of voices, with and without chords to snap to

    /// Every §4.1 choice the line may name, as specs with `source`.
    static func choices(_ source: HarmonySpec.ChordSource) -> [HarmonySpec] {
        [HarmonySpec(interval: .third, direction: .above, chordSource: source),
         HarmonySpec(interval: .sixth, direction: .below, chordSource: source),
         HarmonySpec(interval: .third, direction: .below, chordSource: source)]
    }

    /// "a third above" in a line → its spec with `source`.
    static func spec(named words: Substring, _ source: HarmonySpec.ChordSource) -> HarmonySpec? {
        let parts = words.split(separator: " ")
        guard parts.count == 3, parts[0].lowercased() == "a",
              let interval = HarmonySpec.Interval(rawValue: String(parts[1])),
              let direction = HarmonySpec.Direction(rawValue: String(parts[2])) else { return nil }
        return HarmonySpec(interval: interval, direction: direction, chordSource: source)
    }

    /// Every quoted name in `text` ("'a third above'" or "'A third above'").
    static func quoted(_ text: Substring) -> [Substring] {
        text.split(separator: "'", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map(\.element)
    }

    /// A keys track under the melody: C, G, C, F, C, then G, Am, C, … one chord a beat (the 5-note melody's
    /// third above snaps on beat 1).
    static func keys(beats: Int) -> Track {
        let triads = [[60, 64, 67], [55, 59, 62], [60, 64, 67], [53, 57, 60], [60, 64, 67], [55, 59, 62],
                      [57, 60, 64], [60, 64, 67]]
        var notes: [MIDINote] = []
        for beat in 0..<beats {
            for (j, pitch) in triads[beat % triads.count].enumerated() {
                notes.append(MIDINote(id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d",
                                                                  beat * 3 + j))!,
                                      pitch: pitch, velocity: 90, startBeat: Double(beat), lengthBeats: 1))
            }
        }
        return Track(name: "Keys", kind: .instrument,
                     clips: [Clip(name: "Keys", startBeat: 0, lengthBeats: Double(beats), notes: notes)])
    }

    /// Over a grid of voices: a named choice is never the asked part and fits when measured on its own; the "don't
    /// fit either" list is exactly the other choices and each one misses; a moved part that misses says it moved.
    ///
    /// p2-sing-x9-f3: at 3.0 / +7 / −8 the two original melodies fit almost every voice of the grid (W8-X9F3B's model:
    /// no "don't fit either" line and no "same notes" line was left), so a third melody joins them: the five-note line
    /// up and back with one leap to G5. Its parts miss on that one far note while their mean is within tolerance (the
    /// per-note cap), and a line that misses ONLY by one cap must name that cap's side.
    @Test("Over a grid of voices, every line agrees with each choice measured on its own")
    func everyLineAgreesWithItsOwnMeasurement() throws {
        let t1t2 = try SingPlannerTests.t1t2Clip()
        let five = Self.melody([60, 62, 64, 65, 67]).1
        var leap = Self.melody([60, 62, 64, 65, 67, 65, 64, 62, 60, 79]).1
        leap.name = "Leap"
        let weights = VoiceRangeFit.defaultWeights
        var tried = 0, named = 0, noneFit = 0, movedMisses = 0, sameNotes = 0, snapped = 0, capOnly = 0
        for clip in [five, t1t2, leap] {
            let lead = Track(name: "Lead", kind: .instrument, clips: [clip])
            let keys = Self.keys(beats: Int(clip.lengthBeats.rounded(.up)) + 1)
            for (source, tracks) in [(HarmonySpec.ChordSource.none, [lead]), (.otherTracks, [lead, keys])] {
                let asked = Self.choices(source) + [
                    HarmonySpec(interval: .fifth, direction: .above, chordSource: source),
                    HarmonySpec(interval: .octave, direction: .above, chordSource: source),
                    HarmonySpec(interval: .octave, direction: .below, chordSource: source)]
                for p10 in stride(from: 40.0, through: 84.0, by: 1.5) {
                    for width in [4.0, 7.0, 10.0] {
                        let voice = VoiceRange(p10Midi: p10, medianMidi: p10 + width / 2, p90Midi: p10 + width)
                        for spec in asked {
                            let (plan, range) = Self.line(clip, on: lead, tracks: tracks, spec: spec, voice: voice)
                            tried += 1
                            if plan.notes.contains(where: { $0.rule == .chordSnap }) { snapped += 1 }
                            let line = try #require(range.sentence)
                            let context = "\(clip.name) \(source) \(spec.name) voice \(p10)+\(width): \(line)"
                            if range.fits {
                                #expect(!line.contains("Try ") && !line.contains("either"), "\(context)")
                                continue
                            }
                            // Missed with the mean within tolerance: a per-note cap did it, and when exactly one cap
                            // was crossed the line names its side (p2-sing-x9-f3).
                            let fit = try #require(range.fit)
                            if fit.outOfBandSemitones <= weights.harmonyAcceptOutOfBand {
                                capOnly += 1
                                let sung = plan.notes.map { Double($0.pitch + 12 * range.octaveShift) }
                                let tooHigh = sung.contains {
                                    $0 - (voice.p90Midi + weights.bandMarginSemitones) > weights.harmonyNoteMaxAboveBand
                                }
                                let tooLow = sung.contains {
                                    (voice.p10Midi - weights.bandMarginSemitones) - $0 > weights.harmonyNoteMaxBelowBand
                                }
                                #expect(tooHigh || tooLow, "a miss within the mean must cross a cap: \(context)")
                                if tooHigh != tooLow {
                                    #expect(line.contains(tooHigh ? "goes higher than" : "goes lower than"),
                                            "the side of the crossed cap: \(context)")
                                }
                            }
                            // A moved part says so, first.
                            if range.octaveShift != 0 {
                                movedMisses += 1
                                let words = range.octaveShift == 1 || range.octaveShift == -1
                                    ? "an octave" : "two octaves"
                                #expect(line.hasPrefix("I'll sing this part \(words) "
                                                       + (range.octaveShift < 0 ? "lower" : "higher")),
                                        "\(context)")
                            }
                            // "the same notes as 'a …'": that choice, derived on its own, IS these notes moved.
                            if let same = line.range(of: "which is the same notes as '") {
                                sameNotes += 1
                                let rest = line[same.upperBound...]
                                let name = try #require(rest.split(separator: "'").first)
                                let other = try #require(Self.spec(named: name, source))
                                let theirs = Self.line(clip, on: lead, tracks: tracks, spec: other, voice: voice).plan
                                #expect(zip(plan.notes, theirs.notes).allSatisfy {
                                    $0.pitch + 12 * range.octaveShift == $1.pitch
                                }, "\(context)")
                            }
                            let others = Self.choices(source).filter {
                                !($0.interval == spec.interval && $0.direction == spec.direction)
                            }
                            if let tryRange = line.range(of: " Try '") {
                                let name = try #require(line[tryRange.upperBound...].split(separator: "'").first)
                                named += 1
                                let other = try #require(Self.spec(named: name, source), "\(context)")
                                #expect(!(other.interval == spec.interval && other.direction == spec.direction),
                                        "never the part that was asked for: \(context)")
                                let own = Self.line(clip, on: lead, tracks: tracks, spec: other, voice: voice).range
                                #expect(own.fits, "the named choice must fit on its own: \(context)")
                            }
                            if let either = line.range(of: " fit this voice either.") {
                                noneFit += 1
                                // The listed names: every quoted name after the side sentence, before "fit".
                                let head = line[..<either.lowerBound]
                                let start = head.range(of: "usually sings. ")?.upperBound ?? head.startIndex
                                let listed = Self.quoted(head[start...]).compactMap { Self.spec(named: $0, source) }
                                #expect(listed == others, "the list is exactly the other choices: \(context)")
                                for other in others {
                                    let own = Self.line(clip, on: lead, tracks: tracks, spec: other, voice: voice)
                                    #expect(!own.range.fits, "\(other.name) must miss on its own: \(context)")
                                }
                                #expect(line.hasSuffix(Self.noneFit), "\(context)")
                            }
                        }
                    }
                }
            }
        }
        // The grid is only evidence if every branch was reached (and the chord path really snapped).
        #expect(tried > 1_000)
        #expect(named > 0)
        #expect(noneFit > 0)
        #expect(movedMisses > 0)
        #expect(sameNotes > 0)
        #expect(snapped > 0)
        #expect(capOnly > 0)
        print("X9F1-GRID|tried \(tried)|named \(named)|noneFit \(noneFit)|movedMisses \(movedMisses)"
              + "|sameNotes \(sameNotes)|snapped \(snapped)|capOnly \(capOnly)")
    }
}
