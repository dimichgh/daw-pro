import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x9-f3 (W8-X9F3B): a harmony part's OWN fit rule. W8-X9F3 measured the built-in voice on the real engine:
/// a part sung at a duration-weighted mean of 3.86 semitones out of band still came out in tune and failed at 4.73,
/// every single note hit through +7.3 over the band and broke at +8.3, and below every note held down to 8.7 under.
/// The decision (orchestrator, 2026-10-07): a part FITS when its mean is within 3.0 AND every sounding note is within
/// +7.0 / −8.0 of the band's edges (the band `VoiceRangeFit.score` uses: p10 − 1 … p90 + 1). PROVISIONAL for every voice
/// but the built-in one. The key proposal keeps 0.25 (`VoiceRangeFitProposeKeyPinTests`).
///
/// Plants that must redden this suite (PREDICTIONS P3): (c) the per-note caps removed → the +8 / 9-below tests and the
/// side tests; (a) the mean read from `octaveOnlyAcceptOutOfBand` → the mean-boundary test. Nonisolated (pure DAWCore).
@Suite("HarmonyPlanner: a harmony part's own fit tolerance, from the measured curve (p2-sing-x9-f3)")
struct HarmonyPlannerFitToleranceTests {

    static let tempo = TempoMap(constantBPM: 120)
    /// Band 60 … 70 exactly (p10 61 − 1, p90 69 + 1), so a cap is crossed at a whole semitone.
    static let voice = VoiceRange(p10Midi: 61, medianMidi: 65, p90Midi: 69)
    /// `SingVoiceLibrary.builtInRange` (`Sources/AIServices/SingVoiceLibrary.swift:106`), copied: DAWCoreTests cannot
    /// import AIServices. Band 60.7 … 69.7.
    static let builtIn = VoiceRange(p10Midi: 61.7, medianMidi: 65.9, p90Midi: 68.7)

    /// One note a beat (0.5 s at 120 BPM), from beat 0.
    static func notes(_ pitches: [Int]) -> [MIDINote] {
        pitches.enumerated().map {
            MIDINote(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 700 + $0.offset))!,
                     pitch: $0.element, velocity: 100, startBeat: Double($0.offset), lengthBeats: 1)
        }
    }

    /// The fit of a part sung from these notes (`range(ofClipNotes:)` goes through THE fit rule, `range(melody:…)`).
    static func fit(_ pitches: [Int], voice: VoiceRange = HarmonyPlannerFitToleranceTests.voice,
                    weights: KeyFitWeights = VoiceRangeFit.defaultWeights) -> HarmonyRange {
        HarmonyPlanner.range(ofClipNotes: notes(pitches), clipStartBeat: 0, tempoMap: tempo, voice: voice,
                             leadOctaveShift: 0, weights: weights)
    }

    /// Nine notes inside the band, then `last`.
    static func insideThen(_ last: Int) -> [Int] { [62, 64, 65, 67, 68, 66, 64, 63, 65, last] }

    @Test("The values and their homes: 3.0 / +7.0 / −8.0 on the harmony fields; the key proposal's 0.25 untouched")
    func theDecidedValues() {
        let weights = VoiceRangeFit.defaultWeights
        #expect(weights.harmonyAcceptOutOfBand == 3.0)
        #expect(weights.harmonyNoteMaxAboveBand == 7.0)
        #expect(weights.harmonyNoteMaxBelowBand == 8.0)
        #expect(weights.octaveOnlyAcceptOutOfBand == 0.25)
        #expect(weights == KeyFitWeights.provisional)
    }

    @Test("One note 8 semitones over the band's upper edge: does NOT fit; at 7: fits (the mean is small both times)")
    func oneFarNoteAbove() throws {
        let at8 = Self.fit(Self.insideThen(78))
        let at7 = Self.fit(Self.insideThen(77))
        for range in [at8, at7] {
            let fit = try #require(range.fit)
            #expect(range.octaveShift == 0)
            #expect(fit.outOfBandSemitones < 1.0, "the mean alone would pass: \(fit.outOfBandSemitones)")
        }
        #expect(!at8.fits)
        #expect(at8.sentence == "This part goes higher than this voice usually sings.")
        #expect(at7.fits)
        #expect(at7.sentence == "Fits your voice.")
    }

    @Test("One note 8 semitones under the band's lower edge: fits; at 9: does NOT fit (the mean is small both times)")
    func oneFarNoteBelow() throws {
        let at8 = Self.fit(Self.insideThen(52))
        let at9 = Self.fit(Self.insideThen(51))
        for range in [at8, at9] {
            let fit = try #require(range.fit)
            #expect(range.octaveShift == 0)
            #expect(fit.outOfBandSemitones < 1.0, "the mean alone would pass: \(fit.outOfBandSemitones)")
        }
        #expect(at8.fits)
        #expect(at8.sentence == "Fits your voice.")
        #expect(!at9.fits)
        #expect(at9.sentence == "This part goes lower than this voice usually sings.")
    }

    @Test("The mean's own edge: 3.0 semitones out of band on average fits, 3.5 does not (every note within the caps)")
    func theMeanTolerance() throws {
        // Two equal notes, 3 under and 3 over the band: mean 3.0, each note far inside its cap; any other octave is
        // further out, so the part stays where it is written.
        let atEdge = Self.fit([57, 73])
        let over = Self.fit([56, 73])
        #expect(atEdge.octaveShift == 0 && over.octaveShift == 0)
        #expect(abs((atEdge.fit?.outOfBandSemitones ?? 0) - 3.0) < 1e-9)
        #expect(abs((over.fit?.outOfBandSemitones ?? 0) - 3.5) < 1e-9)
        #expect(atEdge.fits)
        #expect(!over.fits)
    }

    @Test("On the built-in singer: one far note fits up to MIDI 76 and down to 53 (77 and 52 are past the caps)")
    func builtInSingerBoundaries() {
        // W8-X9F3 heard MIDI 77 (+7.3) and 52 (8.7 under) sung well; the decided caps (7.0 / 8.0) stop just short of
        // both, so the measured last-good notes are NOT promised.
        #expect(Self.fit(Self.insideThen(76), voice: Self.builtIn).fits)
        #expect(!Self.fit(Self.insideThen(77), voice: Self.builtIn).fits)
        #expect(Self.fit(Self.insideThen(53), voice: Self.builtIn).fits)
        #expect(!Self.fit(Self.insideThen(52), voice: Self.builtIn).fits)
    }

    @Test("A part that misses only by one far note names THAT note's side, even when most of it sits on the other side")
    func theSideFollowsTheCrossedCap() throws {
        // Nine notes 1 under the band and one 9 over: 90% of the time is low, the mean (1.8) passes, the HIGH note fails.
        let high = Self.fit(Array(repeating: 59, count: 9) + [79])
        let highFit = try #require(high.fit)
        #expect(high.octaveShift == 0 && !high.fits)
        #expect(highFit.fractionBelowBand > highFit.fractionAboveBand)
        #expect(high.sentence == "This part goes higher than this voice usually sings.")
        // The mirror: nine notes 1 over, one 9 under.
        let low = Self.fit(Array(repeating: 71, count: 9) + [51])
        let lowFit = try #require(low.fit)
        #expect(low.octaveShift == 0 && !low.fits)
        #expect(lowFit.fractionAboveBand > lowFit.fractionBelowBand)
        #expect(low.sentence == "This part goes lower than this voice usually sings.")
    }

    @Test("A note that does not sound (zero length) is never measured against a cap")
    func silentNotesAreNotSung() {
        var notes = Self.notes(Self.insideThen(65))
        var silent = MIDINote(id: UUID(uuidString: "00000000-0000-0000-0000-000000000799")!, pitch: 90, velocity: 100,
                              startBeat: 10, lengthBeats: 1)
        silent.lengthBeats = 0  // past `init`'s minimum length, as `VoiceRangeFit.score` skips it
        notes.append(silent)
        let range = HarmonyPlanner.range(ofClipNotes: notes, clipStartBeat: 0, tempoMap: Self.tempo, voice: Self.voice,
                                         leadOctaveShift: 0)
        #expect(range.fits)
        // The control: the same note given a length is 20 over the band.
        notes[notes.count - 1].lengthBeats = 1
        #expect(!HarmonyPlanner.range(ofClipNotes: notes, clipStartBeat: 0, tempoMap: Self.tempo, voice: Self.voice,
                                      leadOctaveShift: 0).fits)
    }
}
