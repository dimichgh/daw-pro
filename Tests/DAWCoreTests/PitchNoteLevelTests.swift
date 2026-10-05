import Foundation
import Testing
@testable import DAWCore

// I7a merged with U-C — `PitchEditSet.gain(atSourceSecond:)`, THE ONE LEVEL MASK
// HOME (`Sources/DAWCore/PitchNoteLevel.swift`), and the two predicates it stands
// on (`NoteSegment.isPitchIdentity`, `NoteSegment.hasLevelEdits`). Design:
// `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §10 and §17.
//
// The render-side twin (the mask applied to real audio, through the cache) is
// `NoteLevelRenderTests` in DAWEngineTests. This suite pins the NUMBERS the render
// multiplies by, so a render failure can be told apart from a mask failure.
//
// Not `@MainActor`: pure model arithmetic (the suite cadence census in
// `MainActorOccupancySiteTests` counts isolated suites; this adds none).
@Suite("I7a/U-C — the level mask: a clear is silence, amplitudeDb is a level")
struct PitchNoteLevelTests {

    static let ramp = PitchEditSet.levelRampSeconds

    static func note(_ start: Double, _ end: Double, cleared: Bool = false, db: Double = 0,
                     cents: Double = 0) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: 0.9, pitchOffsetCents: cents,
                    amplitudeDb: db, isCleared: cleared)
    }

    // MARK: - Where the mask is 1

    /// ⭐ THE INVARIANCE CONTROL, and the premise the render relies on when it
    /// skips every frame outside a level-edited note: there the mask is the
    /// LITERAL 1.0, bit for bit. That includes an untouched note that abuts a
    /// cleared one, which is where a ramp placed on the wrong side would show.
    @Test("outside every level-edited note the mask is exactly 1.0, bit for bit")
    func maskIsExactlyOneOutsideLevelEditedNotes() {
        let set = PitchEditSet(segments: [
            Self.note(0.5, 1.0),                    // untouched, abuts the cleared note
            Self.note(1.0, 1.5, cleared: true),
            Self.note(1.5, 2.0),                    // untouched, abuts the cleared note
            Self.note(2.5, 3.0, cents: 40),         // tuned, no level edit
        ])
        let one = (1.0).bitPattern
        var probes: [Double] = [-1, 0, 0.25, 0.5, 1.5, 2.0, 2.25, 2.5, 2.75, 3.0, 10]
        for step in 0..<500 {
            probes.append(0.5 + Double(step) / 1000)   // the whole left neighbour, to its edge
            probes.append(1.5 + Double(step) / 1000)   // the whole right neighbour, from its edge
        }
        probes.append((1.0).nextDown)                     // the last representable second before the clear
        for t in probes {
            let g = set.gain(atSourceSecond: t)
            #expect(g.bitPattern == one, "the mask at \(t) s is \(g), not exactly 1")
        }
        for t in [Double.nan, .infinity, -.infinity] {
            #expect(set.gain(atSourceSecond: t).bitPattern == one, "a non-finite second must change nothing")
        }
        // POSITIVE CONTROL: the probe does see something else inside the clear.
        #expect(set.gain(atSourceSecond: 1.25) == 0)
    }

    // MARK: - A clear is silence

    @Test("a cleared note is exactly 0 between its ramps, and exactly 1 on its outer edges")
    func clearedNoteIsExactZeroBetweenItsRamps() {
        let set = PitchEditSet(segments: [Self.note(1.0, 2.0, cleared: true)])
        #expect(set.gain(atSourceSecond: 1.0).bitPattern == (1.0).bitPattern,
                "the first sample of the note must be untouched: the ramp starts at 1")
        // 1 ns inside each ramp end, so a rounded endpoint cannot land in a ramp.
        let first = 1.0 + Self.ramp + 1e-9, last = 2.0 - Self.ramp - 1e-9
        let steps = 9_800
        var nonZero = 0
        for step in 0...steps {
            let t = first + (last - first) * Double(step) / Double(steps)
            if set.gain(atSourceSecond: t) != 0 { nonZero += 1 }
        }
        #expect(nonZero == 0, "\(nonZero) probes between the ramps were not exactly 0")
        // Inside each ramp the mask is strictly between the two, and monotone.
        var previous = 1.0
        for step in 1..<100 {
            let g = set.gain(atSourceSecond: 1.0 + Self.ramp * Double(step) / 100)
            #expect(g > 0 && g < 1)
            #expect(g < previous, "the start ramp is not monotone at step \(step)")
            previous = g
        }
    }

    @Test("−72 dB is a level, 10^(−72/20) = 2.5e-4, and never silence; a boost is a level too")
    func minus72DbIsALevelNotSilence() {
        let quiet = PitchEditSet(segments: [Self.note(1.0, 2.0, db: -72)])
        let plateau = quiet.gain(atSourceSecond: 1.5)
        #expect(plateau == pow(10, -72.0 / 20))
        #expect(plateau > 0, "−72 dB rendered as silence: that is the flag's job, not the level's")
        #expect(abs(plateau - 2.5118864315095795e-4) < 1e-18)
        // Below the shared floor clamps TO the floor: still −72 dB, still a level.
        let below = PitchEditSet(segments: [Self.note(1.0, 2.0, db: -90)])
        #expect(below.gain(atSourceSecond: 1.5) == pow(10, -72.0 / 20))
        let boost = PitchEditSet(segments: [Self.note(1.0, 2.0, db: 6)])
        #expect(boost.gain(atSourceSecond: 1.5) == pow(10, 6.0 / 20))
    }

    @Test("Restore returns the note's OWN level: clear and level are two fields")
    func restoreReturnsTheOwnLevel() {
        var set = PitchEditSet(segments: [Self.note(1.0, 2.0, db: -6)])
        #expect(set.gain(atSourceSecond: 1.5) == pow(10, -6.0 / 20))
        set.segments[0].isCleared = true
        #expect(set.gain(atSourceSecond: 1.5) == 0, "cleared wins over the level")
        set.segments[0].isCleared = false
        #expect(set.gain(atSourceSecond: 1.5) == pow(10, -6.0 / 20))
    }

    // MARK: - The ramp

    @Test("ONE raised-cosine ramp of levelRampSeconds (10 ms), inside the note, clamped to half a short note")
    func rampShapeAndClamp() {
        #expect(PitchEditSet.levelRampSeconds == 0.010)
        let set = PitchEditSet(segments: [Self.note(1.0, 2.0, cleared: true)])
        // Half-way along the ramp the raised cosine is exactly half-way: 1 → ½.
        #expect(abs(set.gain(atSourceSecond: 1.0 + Self.ramp / 2) - 0.5) < 1e-12)
        let quarter = 0.5 - 0.5 * cos(Double.pi / 4)
        #expect(abs(set.gain(atSourceSecond: 1.0 + Self.ramp / 4) - (1 - quarter)) < 1e-12)
        #expect(abs(set.gain(atSourceSecond: 2.0 - Self.ramp / 4) - (1 - quarter)) < 1e-12,
                "the end ramp must mirror the start ramp")
        // A 12 ms note: each ramp clamps to 6 ms and they meet at the plateau.
        let short = PitchEditSet(segments: [Self.note(1.0, 1.012, cleared: true)])
        #expect(short.gain(atSourceSecond: 1.006) < 1e-9)
        #expect(abs(short.gain(atSourceSecond: 1.003) - 0.5) < 1e-6)
    }

    // MARK: - Abutting notes (the source contradicts the literal per-note rule)

    /// `PitchNoteSplitter` shares interior boundaries BIT FOR BIT, and a split's
    /// halves meet exactly at the cut. Under the literal per-note rule, clearing
    /// two abutting notes ramps both back up to 1 at the shared edge: a 20 ms
    /// burst of the cleared sound, at full level, between two "silent" notes.
    @Test("two abutting cleared notes are silent ACROSS their shared boundary, with no 20 ms burst")
    func abuttingClearedNotesStaySilentAcrossTheJunction() {
        let cut = 1.5
        let set = PitchEditSet(segments: [Self.note(1.0, cut, cleared: true),
                                          Self.note(cut, 2.0, cleared: true)])
        #expect(set.segments[0].endSeconds == set.segments[1].startSeconds,
                "fixture: the two notes must share the boundary bit for bit")
        var leaks: [String] = []
        for step in -200...200 {   // ±20 ms around the junction, 0.1 ms apart
            let t = cut + Double(step) / 10_000
            let g = set.gain(atSourceSecond: t)
            if g != 0 { leaks.append("\(t): \(g)") }
        }
        #expect(leaks.isEmpty, "the junction leaks: \(leaks.prefix(4))")
        // The OUTER edges still ramp to 1: the gaps outside stay untouched.
        #expect(set.gain(atSourceSecond: 1.0) == 1)
        #expect(set.gain(atSourceSecond: 2.0) == 1)
    }

    @Test("a cleared note meets an abutting levelled note at the MIDPOINT, continuously, leaving both plateaus alone")
    func junctionOfTwoLevelsIsTheMidpoint() {
        let g = pow(10, -6.0 / 20)
        let set = PitchEditSet(segments: [Self.note(1.0, 1.5, cleared: true),
                                          Self.note(1.5, 2.0, db: -6)])
        #expect(set.gain(atSourceSecond: 1.5) == g / 2)
        #expect(abs(set.gain(atSourceSecond: (1.5).nextDown) - g / 2) < 1e-9,
                "the mask jumps at the junction")
        #expect(set.gain(atSourceSecond: 1.5 - Self.ramp) == 0)
        #expect(set.gain(atSourceSecond: 1.5 + Self.ramp) == g)
        // An abutting neighbour with NO level edit is never touched: the edited
        // note ramps all the way to 1 inside itself instead.
        let beside = PitchEditSet(segments: [Self.note(1.0, 1.5, cleared: true), Self.note(1.5, 2.0)])
        #expect(beside.gain(atSourceSecond: 1.5).bitPattern == (1.0).bitPattern)
        #expect(beside.gain(atSourceSecond: (1.5).nextDown) > 0.999)
    }

    /// No click: the mask never steps. Its largest change between two
    /// consecutive 48 kHz samples is bounded by the raised cosine's own
    /// steepest slope over the SHORTEST ramp in the set, (π/2)·Δ/(ramp·rate).
    @Test("the mask never steps: its per-sample change is bounded by the ramp's own slope")
    func maskIsContinuousEverywhere() {
        let set = PitchEditSet(segments: [
            Self.note(0.5, 1.0, cleared: true),
            Self.note(1.0, 1.4, db: -12),
            Self.note(1.4, 1.405, cleared: true),   // 5 ms: its ramps clamp to 2.5 ms
            Self.note(1.405, 2.0),
            Self.note(2.2, 2.6, db: 6),
        ])
        let rate = 48_000.0
        var previous = set.gain(atSourceSecond: 0)
        var worst = 0.0
        for frame in 1..<Int(3.0 * rate) {
            let g = set.gain(atSourceSecond: Double(frame) / rate)
            worst = max(worst, abs(g - previous))
            previous = g
        }
        // The steepest swing here is the 5 ms sliver's 0 → 1 over 2.5 ms.
        let bound = (Double.pi / 2) * 1.0 / (0.0025 * rate) * 1.001
        #expect(worst <= bound, "the mask moved by \(worst) in one sample (bound \(bound)): a click")
        #expect(worst > bound / 2, "precondition: the fixture must exercise the steep ramp")
    }

    // MARK: - The predicates

    @Test("isPitchIdentity is isIdentity without its two level terms; hasLevelEdits is exactly those two")
    func pitchIdentityIgnoresOnlyTheLevelTerms() {
        let untouched = Self.note(0, 1)
        let cleared = Self.note(0, 1, cleared: true)
        let levelled = Self.note(0, 1, db: -6)
        let tuned = Self.note(0, 1, cents: 30)
        #expect(untouched.isIdentity && untouched.isPitchIdentity && !untouched.hasLevelEdits)
        #expect(!cleared.isIdentity && cleared.isPitchIdentity && cleared.hasLevelEdits)
        #expect(!levelled.isIdentity && levelled.isPitchIdentity && levelled.hasLevelEdits)
        #expect(!tuned.isIdentity && !tuned.isPitchIdentity && !tuned.hasLevelEdits)
        #expect(!Self.note(0, 1, db: -0.0).hasLevelEdits, "-0.0 dB is no edit")
        #expect(cleared.isEdited, "a cleared note is a touched note for the editor's accent")

        let levelOnly = PitchEditSet(segments: [untouched, Self.note(1, 2, cleared: true)])
        #expect(!levelOnly.isIdentity && levelOnly.isPitchIdentity && levelOnly.hasLevelEdits)
        let mixed = PitchEditSet(segments: [tuned, Self.note(1, 2, cleared: true)])
        #expect(!mixed.isPitchIdentity && mixed.hasLevelEdits)
        #expect(!PitchEditSet(segments: [tuned]).hasLevelEdits)
    }

    /// Design §17.1: "A cleared note KEEPS its place in the pitch curve, so
    /// neighbours render exactly as before." The curve never reads the flag.
    @Test("a cleared note keeps its place in the pitch curve: the curve is equal with and without the flag")
    func clearingLeavesThePitchCurveUnchanged() {
        let withClear = PitchEditSet(segments: [Self.note(0, 1, cents: 25),
                                                Self.note(1, 2, cleared: true),
                                                Self.note(2, 3, cents: -40)])
        var without = withClear
        without.segments[1].isCleared = false
        let a = PitchCorrectionCurve.make(editSet: withClear)
        let b = PitchCorrectionCurve.make(editSet: without)
        #expect(a == b)
        for step in 0...300 {
            let t = Double(step) / 100
            #expect(a.semitones(atSourceSecond: t).bitPattern == b.semitones(atSourceSecond: t).bitPattern)
        }
    }
}
