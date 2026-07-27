import Foundation
import Testing
@testable import DAWCore

/// m23-k4a Step 1 — the beat→tick INVERSE on `SMFTickClock`.
///
/// Deliberately a NEW file: the discriminator that Step 1 did not disturb the
/// import half is that every existing test in `StandardMIDIFileMapperTests` and
/// the k3 import suites passes UNCHANGED, with no edits to those files. Editing
/// them to accommodate this would destroy exactly the evidence being collected.
@Suite("SMFTickClock — the beat→tick inverse (m23-k4a)")
struct SMFTickClockInverseTests {

    static func metrical(_ t: Int) -> SMFTickClock {
        SMFTickClock(division: .ticksPerQuarterNote(t), tempoMap: TempoMap(constantBPM: 120))
    }

    // MARK: - X1: the rounding rule, pinned by beats that DISCRIMINATE

    /// **G1's arithmetic half.** `round` is pinned uniquely by TWO beats, and one
    /// alone is not enough: 1.00006 separates `round`/`ceil` from
    /// `floor`/`trunc`, and 1.00001 separates `ceil` from the other three.
    ///
    /// **HONEST LIMIT, stated rather than papered over:** `floor` and `trunc` are
    /// PROVABLY indistinguishable here, because every beat in the model is
    /// non-negative (`Clip.init` and `MIDINote.init` both floor at 0). No leg
    /// over this function can separate them, and one that claimed to would be
    /// lying about what it proves.
    @Test("beat -> tick uses round, pinned by two discriminating beats")
    func roundingRuleIsPinned() {
        let clock = Self.metrical(9600)

        // 1.00006 * 9600 = 9600.576 — fractional part 0.576, >= 0.5.
        #expect(clock.ticks(beat: 1.00006) == 9601)
        // 1.00001 * 9600 = 9600.096 — fractional part 0.096, small and non-zero.
        #expect(clock.ticks(beat: 1.00001) == 9600)

        // The fixture DISCRIMINATES, proven rather than asserted: each of the
        // three rejected rules gives a DIFFERENT answer on at least one of the
        // two beats. Without this block the leg above is just two numbers.
        #expect((1.00006 * 9600).rounded(.down) == 9600)     // floor/trunc differ at 1.00006
        #expect((1.00006 * 9600).rounded(.up) == 9601)       // ceil agrees there …
        #expect((1.00001 * 9600).rounded(.up) == 9601)       // … and differs at 1.00001
    }

    /// On-grid beats are exactly where a rounding-rule leg goes VACUOUS: all
    /// four rules agree when `beat · t` is an integer. Asserted here so the fact
    /// is recorded in the suite rather than in a comment somebody deletes.
    @Test("on-grid beats cannot discriminate any rounding rule")
    func onGridBeatsAreVacuous() {
        for beat in [0.0, 1.0, 2.5, 0.25, 1.0 / 3.0 * 3.0] {
            let product = beat * 9600
            #expect(product.rounded() == product.rounded(.down))
            #expect(product.rounded() == product.rounded(.up))
            #expect(product.rounded() == product.rounded(.towardZero))
        }
    }

    @Test("ticks(beats(tick)) == tick across a sweep, at every common division")
    func inverseRecoversEveryTick() {
        for t in [24, 96, 480, 960, 1920, 9600, 15360, 32767] {
            let clock = Self.metrical(t)
            for tick in stride(from: 0, through: 20 * t, by: max(1, t / 7)) {
                #expect(clock.ticks(beat: clock.beats(tick: tick)) == tick,
                        "t=\(t) tick=\(tick)")
            }
        }
    }

    // MARK: - X2: the length rule REVERSES

    /// The pair return is the ONE home for a note's tick geometry, and the form
    /// is ENDPOINT SUBTRACTION — the exact rule k3's R3 forbids on import.
    ///
    /// This leg uses an OFF-GRID start and length on purpose: at on-grid
    /// positions the endpoint and independent forms agree, so an on-grid fixture
    /// proves nothing at all about which one is implemented.
    @Test("noteTicks subtracts endpoints, and the fixture proves it discriminates")
    func noteTicksIsEndpointSubtracted() {
        let clock = Self.metrical(9600)
        let start = 0.3000625      // * 9600 = 2880.6  -> 2881
        let length = 0.7000625     // * 9600 = 6720.6  -> 6721 INDEPENDENTLY

        let (tick, lengthTicks) = clock.noteTicks(startBeat: start, lengthBeats: length)
        #expect(tick == 2881)
        // (start + length) * 9600 = 9601.2 -> 9601 ; 9601 - 2881 = 6720.
        #expect(lengthTicks == 6720)

        // The discriminator, in the leg: the independent form gives 6721 here,
        // so this fixture separates the two rules. A leg with an on-grid length
        // would pass under both and gate nothing (the m23-k3 G2 lesson, which
        // had to move from a dyadic to a triplet length for the same reason).
        #expect(Int((length * 9600).rounded()) == 6721)
    }

    /// The property the endpoint form exists to guarantee: a note's END lands on
    /// the same tick the NEXT note's onset does, so flush legato stays flush.
    /// Measured over the same shape the design sampled 50,000 of.
    @Test("flush legato: note-off tick == next note-on tick, at off-grid boundaries")
    func flushLegatoIsPreserved() {
        let clock = Self.metrical(1200)
        var independentFormBreaks = 0
        var start = 0.0
        for step in 0 ..< 2000 {
            // A deterministic irrational-ish walk, so the starts and lengths are
            // off-grid without depending on a random seed.
            let length = 0.137 + Double(step % 37) * 0.0193
            let (tick, lengthTicks) = clock.noteTicks(startBeat: start, lengthBeats: length)
            let (nextTick, _) = clock.noteTicks(startBeat: start + length, lengthBeats: length)
            #expect(tick + lengthTicks == nextTick, "step \(step) start \(start)")

            if tick + Int((length * 1200).rounded()) != nextTick { independentFormBreaks += 1 }
            start += length
        }
        // The leg is NOT vacuous: the independent form really does break the
        // boundary on this input, on roughly a quarter of the pairs.
        #expect(independentFormBreaks > 100,
                "the fixture must contain pairs the independent form gets wrong")
    }

    @Test("there is no length-only entry point on the clock")
    func lengthOnlyEntryPointDoesNotExist() {
        // Compile-time claim, recorded as a runtime tautology: the ONLY public
        // way to get a length in ticks is `noteTicks`, which requires the onset.
        // A caller who wants `round(lengthBeats * t)` has to destructure
        // `SMFDivision` by hand — which is the D-ONEHOME mechanism, and the
        // reason `division` is the only other thing exposed.
        let clock = Self.metrical(9600)
        #expect(clock.noteTicks(startBeat: 0, lengthBeats: 1).lengthTicks == 9600)
        #expect(clock.division == .ticksPerQuarterNote(9600))
    }

    // MARK: - The SMPTE branch (unreachable from the wire, live and tested here)

    @Test("the SMPTE inverse round-trips through the project's tempo map")
    func smpteInverse() {
        let clock = SMFTickClock(division: .smpte(framesPerSecond: 25, ticksPerFrame: 40),
                                 tempoMap: TempoMap(constantBPM: 120))
        // 25 fps * 40 ticks = 1000 ticks/second; at 120 BPM a beat is 0.5 s.
        #expect(clock.beats(tick: 1000) == 2.0)
        #expect(clock.ticks(beat: 2.0) == 1000)
        for tick in stride(from: 0, through: 8000, by: 137) {
            #expect(clock.ticks(beat: clock.beats(tick: tick)) == tick, "tick \(tick)")
        }
        #expect(clock.division == .smpte(framesPerSecond: 25, ticksPerFrame: 40))
    }

    @Test("a non-constant tempo map moves SMPTE ticks and leaves metrical ones alone")
    func smpteFollowsTempoWhileMetricalDoesNot() throws {
        let map = try TempoMap(segments: [.init(startBeat: 0, bpm: 120),
                                          .init(startBeat: 4, bpm: 60)])
        let absolute = SMFTickClock(division: .smpte(framesPerSecond: 25, ticksPerFrame: 40),
                                    tempoMap: map)
        let metrical = SMFTickClock(division: .ticksPerQuarterNote(9600), tempoMap: map)
        // Beat 8 is 4 beats at 120 (2 s) + 4 beats at 60 (4 s) = 6 s = 6000 ticks.
        #expect(absolute.ticks(beat: 8) == 6000)
        // THE SPINE: no tempo term on the metrical path, so the same beat is the
        // same tick whatever the tempo map says.
        #expect(metrical.ticks(beat: 8) == 76800)
    }

    // MARK: - Refuse, don't trap

    /// `Int(_:)` on an out-of-range `Double` TRAPS. Beats are caller-controlled
    /// (`Clip.startBeat` is floored at 0 but never ceilinged), and a pure
    /// value-level API must refuse rather than crash — the same posture k2
    /// already paid for once with `SMFNote(tick: .max, lengthTicks: 1)`.
    @Test("an absurd beat saturates instead of trapping")
    func absurdBeatsSaturate() {
        let clock = Self.metrical(9600)
        #expect(clock.ticks(beat: 1e300) == Int.max)
        #expect(clock.ticks(beat: -1e300) == Int.min)
        #expect(clock.ticks(beat: .infinity) == Int.max)
        #expect(clock.ticks(beat: .nan) == 0)
        // And the pair form's subtraction saturates rather than wrapping:
        // Int.max - Int.min is not representable, and a wrap here would hand the
        // encoder a NEGATIVE length that reads as a well-formed short note.
        let spanning = clock.noteTicks(startBeat: -1e300, lengthBeats: 2e300)
        #expect(spanning.tick == Int.min)
        #expect(spanning.lengthTicks == Int.max)
    }
}
