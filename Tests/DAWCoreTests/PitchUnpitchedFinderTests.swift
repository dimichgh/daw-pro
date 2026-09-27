import Foundation
import Testing
@testable import DAWCore

// UA-1 (the finder part) — `PitchUnpitchedFinder` and `NoteOrigin`
// (`Sources/DAWCore/PitchUnpitchedFinder.swift`). Design
// `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §1.3 (U1), §1.4
// (U2), §1.5 (U3), §1.10 (the tests this suite owes).
//
// Not `@MainActor`: the finder is pure DAWCore, and `MainActorOccupancySiteTests`
// Leg C counts suite-level `@MainActor` against its cap.
//
// ═══ ON FIXTURES ═══
// Every fixture is a DETECTED CONTOUR, never audio: frames at the detector's 62.5 fps
// (one fixture at 50 fps, so the 1-second boundary is a whole frame count), with levels
// in dBFS chosen so every answer is known by construction. The notes are the REAL
// splitter's parts (`PitchNoteSplitter.parts` → `Note(part:)`), the exact input the
// two builders will pass, except where a case needs a STORED segment's shape (an edge
// off the frame grid, a note that lends no pitch), which the merge verb will pass.
// Floor noise is seeded (SplitMix64), so every run sees the same numbers.
//
// ═══ ON PLANTS ═══
// Threshold pins carry an in-test negative control: the SAME fixture under a PLANTED
// `PitchUnpitchedFinder.Rule` (one constant moved) must come out the other way (the
// `PitchNoteSplitterTests` idiom). Every gate was also planted in an ISOLATED copy of
// the source (a scratch package holding 813c415's DAWCore) and shown RED, then GREEN
// on the real code; the L1c report lists each plant with both outputs.

// MARK: - Fixtures

private typealias Finder = PitchUnpitchedFinder

/// SplitMix64: a fixed seed gives the same floor noise on every run and machine.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A take built left to right, one detector frame per slot. Frame `i` sits at
/// `i × period` seconds, the product's own arithmetic (`SwiftF0PitchTracker`:
/// `Double(index) * frameSeconds`), so the last-bit behaviour at note edges is the
/// product's too.
private struct Take {
    var rate: Double = 62.5
    private(set) var frames: [ClipPitchFrame] = []
    /// The next frame slot. `skip` advances it without writing a frame.
    private(set) var slot = 0
    private var random = SeededRandom(seed: 0x00A1_0C5E)

    init(rate: Double = 62.5, seed: UInt64 = 0x00A1_0C5E) {
        self.rate = rate
        self.random = SeededRandom(seed: seed)
    }

    var period: Double { 1 / rate }
    func time(_ slot: Int) -> Double { Double(slot) * period }

    /// `count` voiced frames at `hz` and `db`: a note, once the splitter reads it.
    mutating func sing(_ count: Int, hz: Double = 220, db: Double = -20,
                       confidence: Double = 0.97) {
        for _ in 0..<count {
            frames.append(ClipPitchFrame(timeSeconds: time(slot), frequencyHz: hz,
                                         confidence: confidence, levelDbfs: db, absence: nil))
            slot += 1
        }
    }

    /// Unvoiced frames, one per level; `nil` is exact digital silence.
    mutating func quiet(_ levels: [Double?], confidence: Double = 0.3) {
        for db in levels {
            frames.append(ClipPitchFrame(timeSeconds: time(slot), frequencyHz: nil,
                                         confidence: confidence, levelDbfs: db,
                                         absence: db == nil ? .belowLevel : .belowConfidence))
            slot += 1
        }
    }

    mutating func quiet(_ count: Int, db: Double?, confidence: Double = 0.3) {
        quiet(Array(repeating: db, count: count), confidence: confidence)
    }

    /// `count` unvoiced frames of floor noise, uniform in `db ± spread` dB.
    mutating func noise(_ count: Int, db: Double = -50, spread: Double = 1.5) {
        let levels: [Double?] = (0..<count).map { _ in
            db + Double.random(in: -spread...spread, using: &random)
        }
        quiet(levels)
    }

    /// `count` unvoiced frames loud enough to hear: a breath or a consonant.
    mutating func sound(_ count: Int, db: Double = -34, confidence: Double = 0.6) {
        quiet(count, db: db, confidence: confidence)
    }

    /// An analysis gap: `count` slots with no frame at all.
    mutating func skip(_ count: Int) { slot += count }

    /// The splitter's parts, as the builders will pass them.
    var notes: [Finder.Note] {
        PitchNoteSplitter.parts(in: frames, frameRateHz: rate).map(Finder.Note.init(part:))
    }

    /// The same frames, every level moved by `db`.
    func shifted(by db: Double) -> [ClipPitchFrame] {
        frames.map {
            ClipPitchFrame(timeSeconds: $0.timeSeconds, frequencyHz: $0.frequencyHz,
                           confidence: $0.confidence, levelDbfs: $0.levelDbfs.map { $0 + db },
                           absence: $0.absence)
        }
    }

    func find(notes: [Finder.Note]? = nil, marginDb: Double = Finder.defaultMarginDb,
              rule: Finder.Rule = .product) -> Finder.Result {
        Finder.sounds(in: frames, frameRateHz: rate, notes: notes ?? self.notes,
                      marginDb: marginDb, rule: rule)
    }
}

/// What one sound should be, in frame slots.
private struct Expected {
    let first: Int
    let last: Int
    let side: Finder.Side
    let lender: Int
}

/// Spans to 1e-12 s (a frame is 0.016 s); everything else exactly.
private func matches(_ sounds: [Finder.Sound], _ expected: [Expected], in take: Take,
                     notes: [Finder.Note]? = nil) -> Bool {
    let notes = notes ?? take.notes
    guard sounds.count == expected.count else { return false }
    return zip(sounds, expected).allSatisfy { sound, want in
        abs(sound.startSeconds - take.time(want.first)) < 1e-12
            && abs(sound.endSeconds - (take.time(want.last) + take.period)) < 1e-12
            && sound.frameCount == want.last - want.first + 1
            && sound.borrowedFrom == want.side
            && sound.lenderIndex == want.lender
            && sound.anchorHz == notes[want.lender].hz
    }
}

/// The builders' promise (design §1.6: "sounds lie outside every part, so `canonical`
/// heals nothing"): the notes plus one segment per sound, through
/// `PitchEditSet.canonical`, come out with every span exactly as it went in.
private func canonicalHealsNothing(notes: [Finder.Note], sounds: [Finder.Sound]) -> Bool {
    let spans = (notes.map { ($0.startSeconds, $0.endSeconds, $0.hz) }
        + sounds.map { ($0.startSeconds, $0.endSeconds, $0.anchorHz) })
        .sorted { $0.0 < $1.0 }
    let table = spans.map {
        NoteSegment(startSeconds: $0.0, endSeconds: $0.1, detectedHz: $0.2, detectedConfidence: 0.9)
    }
    let healed = PitchEditSet.canonical(table)
    return healed.count == table.count
        && zip(healed, table).allSatisfy {
            $0.startSeconds == $1.startSeconds && $0.endSeconds == $1.endSeconds
        }
}

/// A readable line for a failing `#expect`.
private func describe(_ sounds: [Finder.Sound], in take: Take) -> String {
    sounds.map { s in
        let first = (s.startSeconds * take.rate).rounded()
        let last = (s.endSeconds * take.rate).rounded() - 1
        return "[\(Int(first))…\(Int(last)) \(s.borrowedFrom.rawValue) #\(s.lenderIndex)]"
    }.joined(separator: " ")
}

// MARK: - The suite

@Suite("PitchUnpitchedFinder — sounds with no detected note (UA-1)")
struct PitchUnpitchedFinderTests {

    // MARK: Wire values

    @Test("NoteOrigin: the raw strings are wire values, and a missing or unknown one reads as detected")
    func originRawValuesAreWireValues() throws {
        #expect(NoteOrigin.allCases.map(\.rawValue) == ["detected", "transition", "unpitched"])
        #expect(NoteOrigin(storedValue: nil) == .detected)
        #expect(NoteOrigin(storedValue: "detected") == .detected)
        #expect(NoteOrigin(storedValue: "transition") == .transition)
        #expect(NoteOrigin(storedValue: "unpitched") == .unpitched)
        // A case a newer build added, an empty string, and a wrong case all heal.
        #expect(NoteOrigin(storedValue: "breath") == .detected)
        #expect(NoteOrigin(storedValue: "") == .detected)
        #expect(NoteOrigin(storedValue: "Unpitched") == .detected)
        let data = try JSONEncoder().encode([NoteOrigin.unpitched, .transition])
        #expect(String(decoding: data, as: UTF8.self) == #"["unpitched","transition"]"#)
        #expect(try JSONDecoder().decode([NoteOrigin].self, from: data) == [.unpitched, .transition])
    }

    @Test("the skip reasons and sides are wire strings too")
    func skipReasonsAndSidesAreWireStrings() {
        #expect(Finder.SkipReason.allCases.map(\.rawValue) == ["notEnoughQuiet", "tooNoisy", "noNotes"])
        #expect(Finder.Side.allCases.map(\.rawValue) == ["previous", "following"])
    }

    @Test("the product rule is the named constants, and nothing else")
    func productRuleIsTheNamedConstants() {
        #expect(Finder.defaultMarginDb == 9)
        #expect(Finder.floorPercentile == 0.10)
        #expect(Finder.maximumBridgedDipFrames == 2)
        #expect(Finder.minimumQuietSeconds == 1)
        #expect(Finder.minimumHeadroomDb == 12)
        #expect(Finder.Rule.product == Finder.Rule(
            floorPercentile: 0.10, maximumBridgedDipFrames: 2,
            minimumSoundSeconds: PitchAutoCorrect.minimumNoteSeconds,
            minimumQuietSeconds: 1, minimumHeadroomDb: 12))
    }

    // MARK: Known-dB events

    /// Notes at −20 dBFS over floor noise at −50 ± 1.5 dB, and sounds at −30…−35 dB
    /// placed where each answer is known.
    private static func knownTake() -> (take: Take, expected: [Expected]) {
        var take = Take()
        take.noise(40)                  //   0…39
        take.sound(8, db: -35)          //  40…47   a breath into the first note (a clip edge)
        take.sing(30, hz: 220)          //  48…77   note 0
        take.sound(6, db: -34)          //  78…83   a release consonant: touches note 0 only
        take.noise(30)                  //  84…113
        take.sound(3, db: -30)          // 114…116  3 frames = 48 ms: too short, dropped
        take.noise(30)                  // 117…146
        take.sing(25, hz: 330)          // 147…171  note 1
        take.noise(10)                  // 172…181
        take.sound(10, db: -32)         // 182…191  after the last note (§1.5 case 1)
        take.noise(30)                  // 192…221
        return (take, [
            Expected(first: 40, last: 47, side: .following, lender: 0),
            Expected(first: 78, last: 83, side: .previous, lender: 0),
            Expected(first: 182, last: 191, side: .previous, lender: 1),
        ])
    }

    @Test("known-dB events: the three sounds, where they are, and whom they borrow from")
    func knownDbEventsAreFound() throws {
        let (take, expected) = Self.knownTake()
        #expect(take.notes.count == 2)
        let found = take.find()
        #expect(found.skipped == nil)
        #expect(matches(found.sounds, expected, in: take), "\(describe(found.sounds, in: take))")
        let floor = try #require(found.floorDbfs)
        #expect(floor > -51.5 && floor < -48.5, "F = \(floor) must lie in the noise")
        #expect(found.thresholdDbfs == floor + 9)
        #expect(found.marginDb == 9)
        #expect(found.singingDbfs == -20)
        #expect(found.sounds.allSatisfy { $0.medianConfidence == 0.6 })
        // Negative control: the same take at a 20 dB margin hears none of them.
        #expect(take.find(marginDb: 20).sounds.isEmpty)
    }

    // MARK: Level-shift invariance (U1)

    /// Random structure over a random floor: 12 notes of random length and pitch, and
    /// gaps of floor noise holding 0…2 sounds each at NON-DYADIC levels 12…25 dB
    /// above the floor. No frame lies within 4 dB of the audible line.
    private static func randomTake(seed: UInt64) -> Take {
        var random = SeededRandom(seed: seed)
        var take = Take(seed: seed &+ 1)
        let floor = Double.random(in: -62 ... -38, using: &random)
        for _ in 0..<12 {
            take.noise(Int.random(in: 6...30, using: &random), db: floor, spread: 2)
            for _ in 0..<Int.random(in: 0...2, using: &random) {
                take.sound(Int.random(in: 2...12, using: &random),
                           db: floor + Double.random(in: 12...25, using: &random))
                take.noise(Int.random(in: 1...8, using: &random), db: floor, spread: 2)
            }
            take.sing(Int.random(in: 8...40, using: &random),
                      hz: Double.random(in: 150...500, using: &random), db: floor + 25)
        }
        take.noise(20, db: floor, spread: 2)
        return take
    }

    /// −21.5 dB is the user's own m4a against the normalised take (design §1.2).
    @Test("the whole take ±N dB finds the same sounds: relative to the floor, never absolute",
          arguments: [-21.5, -20, 20, 7.3])
    func levelShiftFindsTheSameSounds(shift: Double) throws {
        for take in [Self.knownTake().take, Self.randomTake(seed: 1), Self.randomTake(seed: 2)] {
            let base = take.find()
            let movedFrames = take.shifted(by: shift)
            let movedNotes = PitchNoteSplitter.parts(in: movedFrames, frameRateHz: take.rate)
                .map(Finder.Note.init(part:))
            let moved = Finder.sounds(in: movedFrames, frameRateHz: take.rate, notes: movedNotes)
            #expect(base.skipped == nil)
            #expect(!base.sounds.isEmpty)
            #expect(moved.skipped == base.skipped)
            #expect(moved.sounds == base.sounds,
                    "\(describe(moved.sounds, in: take)) vs \(describe(base.sounds, in: take))")
            let floor = try #require(base.floorDbfs)
            #expect(moved.floorDbfs == floor + shift)
            let singing = try #require(base.singingDbfs)
            let movedSinging = try #require(moved.singingDbfs)
            #expect(abs(movedSinging - (singing + shift)) < 1e-9)
            // The fixture can tell the rules apart: an ABSOLUTE line at the base's
            // threshold hears a different set of frames once the take moves.
            let line = try #require(base.thresholdDbfs)
            let heardBefore = take.frames.filter { ($0.levelDbfs ?? -.infinity) >= line }.count
            let heardAfter = movedFrames.filter { ($0.levelDbfs ?? -.infinity) >= line }.count
            #expect(heardBefore != heardAfter)
        }
    }

    // MARK: The three guards (§1.3)

    /// At 50 fps one second is exactly 50 frames: 49 unvoiced frames with a level are
    /// not enough to measure F, 50 are.
    @Test("notEnoughQuiet: F needs one second of unvoiced frames with a level (50 fps: 49 vs 50)")
    func notEnoughQuietAtOneSecond() {
        func take(quietFrames: Int) -> Take {
            var take = Take(rate: 50)
            take.sing(40, hz: 200)              // a note
            take.sound(6, db: -30)              // a consonant after it
            take.noise(quietFrames - 6)         // the rest of the quiet
            return take
        }
        let short = take(quietFrames: 49).find()
        #expect(short.skipped == .notEnoughQuiet)
        #expect(short.sounds.isEmpty)
        #expect(short.floor == nil && short.floorDbfs == nil && short.thresholdDbfs == nil)
        #expect(short.singingDbfs == -20)

        let enough = take(quietFrames: 50).find()
        #expect(enough.skipped == nil)
        #expect(enough.sounds.count == 1)
        #expect(enough.floorDbfs != nil)

        // Digital silence has no level, so it is not quiet F can be measured on.
        var silent = take(quietFrames: 49)
        silent.quiet(200, db: nil)
        #expect(silent.find().skipped == .notEnoughQuiet)

        // No usable frame rate: one second cannot be counted.
        let frames = take(quietFrames: 50).frames
        let notes = take(quietFrames: 50).notes
        for rate in [0, -50, Double.nan, .infinity] {
            #expect(Finder.sounds(in: frames, frameRateHz: rate, notes: notes).skipped == .notEnoughQuiet)
        }
        #expect(Finder.sounds(in: [], frameRateHz: 50, notes: notes).skipped == .notEnoughQuiet)

        // Negative control: a planted 0.9 s requirement lets the 49-frame take through.
        var planted = Finder.Rule.product
        planted.minimumQuietSeconds = 0.9
        #expect(take(quietFrames: 49).find(rule: planted).skipped == nil)
    }

    /// F is exactly −40 dBFS (the floor frames all sit there), so the headroom is the
    /// singing level + 40, exactly.
    @Test("tooNoisy: the singing must stand 12 dB above the floor (12.00 passes, 11.99 does not)")
    func tooNoisyAtTwelveDb() throws {
        func take(singingDb: Double) -> Take {
            var take = Take()
            take.quiet(80, db: -40)             //   0…79
            take.sing(30, db: singingDb)        //  80…109
            take.sound(6, db: -31)              // 110…115: exactly F + 9, which IS audible (≥)
            take.quiet(20, db: -40)             // 116…135
            return take
        }
        let clear = take(singingDb: -28).find()
        #expect(clear.skipped == nil)
        #expect(clear.floorDbfs == -40)
        #expect(clear.singingDbfs == -28)
        #expect(matches(clear.sounds, [Expected(first: 110, last: 115, side: .previous, lender: 0)],
                        in: take(singingDb: -28)))

        let noisy = take(singingDb: -28.01).find()
        #expect(noisy.skipped == .tooNoisy)
        #expect(noisy.sounds.isEmpty)
        #expect(noisy.floorDbfs == -40, "F is still reported when the guard fires")
        #expect(noisy.thresholdDbfs == -31)

        // Negative controls: a planted 11.9 dB guard lets the noisy take through, and a
        // margin a hair over 9 dB loses the sound that sits exactly on the line.
        var planted = Finder.Rule.product
        planted.minimumHeadroomDb = 11.9
        #expect(take(singingDb: -28.01).find(rule: planted).skipped == nil)
        #expect(take(singingDb: -28).find(marginDb: 9.001).sounds.isEmpty)
    }

    @Test("noNotes: with nothing that lends a pitch there is nothing to anchor a sound")
    func noNotesWhenNothingLendsAPitch() throws {
        let (take, expected) = Self.knownTake()
        let notes = take.notes
        let none = take.find(notes: [])
        #expect(none.skipped == .noNotes)
        #expect(none.sounds.isEmpty)
        #expect(none.floorDbfs != nil, "F is still reported when the guard fires")

        let covering = notes.map {
            Finder.Note(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, hz: $0.hz,
                        lendsPitch: false)
        }
        #expect(take.find(notes: covering).skipped == .noNotes)
        for hz in [0, -220, Double.nan, .infinity] {
            let unusable = notes.map {
                Finder.Note(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds, hz: hz)
            }
            #expect(take.find(notes: unusable).skipped == .noNotes, "hz \(hz) lends nothing")
        }
        // One lending note is enough: every sound borrows from it.
        let one = [covering[0], notes[1]]
        let found = take.find(notes: one)
        #expect(found.skipped == nil)
        #expect(found.sounds.count == expected.count)
        #expect(found.sounds.allSatisfy { $0.lenderIndex == 1 && $0.anchorHz == notes[1].hz })
        #expect(abs(notes[1].hz - 330) < 1e-9)
    }

    @Test("the guards fire in the design's order: notEnoughQuiet, then tooNoisy, then noNotes")
    func guardsFireInOrder() {
        var loudAndShort = Take()
        loudAndShort.quiet(30, db: -40)
        loudAndShort.sing(30, db: -35)          // too noisy AND under a second of quiet
        #expect(loudAndShort.find(notes: []).skipped == .notEnoughQuiet)

        var loud = Take()
        loud.quiet(80, db: -40)
        loud.sing(30, db: -35)                  // too noisy, enough quiet, and no notes
        #expect(loud.find(notes: []).skipped == .tooNoisy)
        #expect(loud.find().skipped == .tooNoisy)

        // No voiced frame has a level, so V does not exist and tooNoisy is not
        // evaluated (never invented): a STORED note still anchors the sound.
        var unvoiced = Take()
        unvoiced.noise(80)                      //   0…79
        unvoiced.sound(6, db: -30)              //  80…85
        unvoiced.noise(20)                      //  86…105
        let stored = [Finder.Note(startSeconds: unvoiced.time(40), endSeconds: unvoiced.time(60), hz: 220)]
        let found = unvoiced.find(notes: stored)
        #expect(found.singingDbfs == nil)
        #expect(found.skipped == nil)
        #expect(matches(found.sounds, [Expected(first: 80, last: 85, side: .previous, lender: 0)],
                        in: unvoiced, notes: stored))
    }

    // MARK: Bridging and duration (§1.3)

    @Test("bridging: a dip of 2 frames stays inside the sound, a dip of 3 ends it")
    func bridgesDipsOfTwoFrames() {
        var take = Take()
        take.noise(60)                          //   0…59
        take.sing(30, hz: 220)                  //  60…89   note 0
        take.noise(20)                          //  90…109
        take.sound(3); take.noise(2); take.sound(3)     // 110…117: ONE sound
        take.noise(20)                          // 118…137
        take.sound(4); take.noise(3); take.sound(4)     // 138…148: TWO sounds
        take.noise(20)                          // 149…168
        take.sing(30, hz: 330)                  // 169…198  note 1
        take.noise(40)                          // 199…238
        let expected = [
            Expected(first: 110, last: 117, side: .previous, lender: 0),
            Expected(first: 138, last: 141, side: .following, lender: 1),
            Expected(first: 145, last: 148, side: .following, lender: 1),
        ]
        let found = take.find()
        #expect(matches(found.sounds, expected, in: take), "\(describe(found.sounds, in: take))")
        // The bridged frames count toward the sound's own frames and confidence.
        #expect(found.sounds.first?.frameCount == 8)
        #expect(found.sounds.first?.medianConfidence == 0.6)

        // A digital-silence frame is a dip like any quiet frame.
        var gated = Take()
        gated.noise(60); gated.sing(30, hz: 220); gated.noise(20)
        gated.sound(3); gated.quiet(2, db: nil); gated.sound(3)          // 110…117
        gated.noise(40); gated.sing(30, hz: 330); gated.noise(40)
        #expect(matches(gated.find().sounds, [Expected(first: 110, last: 117, side: .previous, lender: 0)],
                        in: gated))

        // Negative controls: bridge 3 joins the pair; bridge 1 cuts the first sound into
        // two 3-frame pieces, both too short to keep.
        var three = Finder.Rule.product
        three.maximumBridgedDipFrames = 3
        #expect(take.find(rule: three).sounds.count == 2)
        var one = Finder.Rule.product
        one.maximumBridgedDipFrames = 1
        #expect(take.find(rule: one).sounds.count == 2)
        #expect(take.find(rule: one).sounds.first?.startSeconds == take.time(138))
    }

    @Test("bridging never crosses a note, even a stored one narrower than a frame")
    func bridgingNeverCrossesANote() throws {
        var take = Take()
        take.noise(60)                          //   0…59
        take.sing(30, hz: 220)                  //  60…89   note 0
        take.sound(12)                          //  90…101  one sound, touching note 0
        take.noise(40)                          // 102…141
        take.sing(30, hz: 330)                  // 142…171  note 1
        take.noise(40)                          // 172…211
        let notes = take.notes
        #expect(matches(take.find().sounds, [Expected(first: 90, last: 101, side: .previous, lender: 0)],
                        in: take))

        // A stored note over frames 95…96 (the merge verb passes stored segments) cuts it.
        let stored = notes + [Finder.Note(startSeconds: take.time(95), endSeconds: take.time(97), hz: 250)]
        let cut = take.find(notes: stored)
        #expect(matches(cut.sounds, [
            Expected(first: 90, last: 94, side: .following, lender: 2),    // touches both: tie
            Expected(first: 97, last: 101, side: .previous, lender: 2),
        ], in: take, notes: stored), "\(describe(cut.sounds, in: take))")

        // A sliver between frame 95's midpoint (+8 ms) and frame 96's: no frame lies in
        // it, and it still ends the sound; the first piece is clamped to its start.
        let sliverStart = take.time(95) + 0.009
        let sliver = notes + [Finder.Note(startSeconds: sliverStart, endSeconds: take.time(95) + 0.012,
                                          hz: 250)]
        let split = take.find(notes: sliver).sounds
        #expect(split.count == 2)
        #expect(abs((split.first?.startSeconds ?? .nan) - take.time(90)) < 1e-12)
        #expect(split.first?.endSeconds == sliverStart)
        #expect(split.first?.frameCount == 6)
        #expect(split.last?.startSeconds == take.time(96))
        #expect(split.last?.frameCount == 6)
    }

    @Test("a gap in the analysis ends a sound: nothing was measured, so nothing is bridged")
    func analysisGapEndsASound() {
        func take(missing: Bool) -> Take {
            var take = Take()
            take.noise(60)                      //   0…59
            take.sing(30, hz: 220)              //  60…89
            take.noise(20)                      //  90…109
            take.sound(5)                       // 110…114
            if missing { take.skip(1) } else { take.quiet(1, db: -50) }   // 115
            take.sound(5)                       // 116…120
            take.noise(40)
            take.sing(30, hz: 330)
            take.noise(40)
            return take
        }
        let whole = take(missing: false)
        #expect(matches(whole.find().sounds, [Expected(first: 110, last: 120, side: .previous, lender: 0)],
                        in: whole))
        let holed = take(missing: true)
        #expect(matches(holed.find().sounds, [
            Expected(first: 110, last: 114, side: .previous, lender: 0),
            Expected(first: 116, last: 120, side: .previous, lender: 0),
        ], in: holed), "\(describe(holed.find().sounds, in: holed))")
    }

    @Test("a sound is kept at 4 frames (64 ms ≥ 60 ms) and dropped at 3, bridged dips counted")
    func keepsSoundsOfSixtyMilliseconds() {
        var take = Take()
        take.noise(60)                          //   0…59
        take.sing(30, hz: 220)                  //  60…89   note 0
        take.noise(20)                          //  90…109
        take.sound(4)                           // 110…113  kept
        take.noise(20)                          // 114…133
        take.sound(3)                           // 134…136  dropped
        take.noise(20)                          // 137…156
        take.sound(1); take.noise(2); take.sound(1)     // 157…160: 4 frames once bridged, kept
        take.noise(20)                          // 161…180
        take.sing(30, hz: 330)                  // 181…210  note 1
        take.noise(40)
        let expected = [
            Expected(first: 110, last: 113, side: .previous, lender: 0),
            Expected(first: 157, last: 160, side: .following, lender: 1),
        ]
        #expect(matches(take.find().sounds, expected, in: take), "\(describe(take.find().sounds, in: take))")
        // Negative controls: 65 ms drops both 4-frame sounds; 45 ms keeps the 3-frame one.
        var longer = Finder.Rule.product
        longer.minimumSoundSeconds = 0.065
        #expect(take.find(rule: longer).sounds.isEmpty)
        var shorter = Finder.Rule.product
        shorter.minimumSoundSeconds = 0.045
        #expect(take.find(rule: shorter).sounds.count == 3)
    }

    // MARK: Silence is never cut up (the user's words; §1.2)

    /// The take's own shape (§1.2): singing at −19.7 dBFS, and gaps that are NOT
    /// silent, uniform in −40…−33 dBFS (hum). V − 20 = −39.7 lies inside the hum and
    /// hears almost all of it; F + 9 ≈ −30.3 lies above it.
    private static func humTake(events: Bool) -> Take {
        var take = Take(seed: 0x5117_E0CE)
        for note in 0..<8 {
            take.noise(45, db: -36.5, spread: 3.5)
            if events && note.isMultiple(of: 3) {
                take.sound(8, db: -25)
                take.noise(20, db: -36.5, spread: 3.5)
            }
            take.sing(35, hz: 180 + 20 * Double(note), db: -19.7)
        }
        take.noise(45, db: -36.5, spread: 3.5)
        return take
    }

    @Test("hum between the notes is not a sound: F + 9 finds none, and does find what is there")
    func silenceIsNeverCutUp() throws {
        let hum = Self.humTake(events: false)
        let found = hum.find()
        #expect(found.skipped == nil)
        #expect(found.sounds.isEmpty, "\(describe(found.sounds, in: hum))")
        let floor = try #require(found.floorDbfs)
        #expect(floor >= -40 && floor < -38.5)

        // Positive control: three real sounds in the same hum are found, and only they.
        let withEvents = Self.humTake(events: true)
        let heard = withEvents.find().sounds
        #expect(heard.count == 3, "\(describe(heard, in: withEvents))")
        #expect(heard.allSatisfy { $0.frameCount == 8 })

        // The rule the design rejected: "20 dB below the singing" (V − 20) sits under
        // the hum's top, so it cuts the silence into pieces covering most of each gap.
        let singing = try #require(found.singingDbfs)
        let vMinus20 = hum.find(marginDb: (singing - 20) - floor).sounds
        let gapFrames = hum.frames.filter { $0.frequencyHz == nil }.count
        let cutFrames = vMinus20.reduce(0) { $0 + $1.frameCount }
        #expect(vMinus20.count >= 8)
        #expect(Double(cutFrames) > 0.8 * Double(gapFrames))
    }

    // MARK: Which note a sound borrows (U3, §1.5)

    /// Six notes, and one sound for each anchor case. Gaps are in frames.
    private static func anchorTake() -> (take: Take, expected: [Expected]) {
        var take = Take()
        take.noise(60)                                  //   0…59
        take.sound(6)                                   //  60…65   before the first note: a clip edge
        take.noise(10)                                  //  66…75
        take.sing(30, hz: 200)                          //  76…105  note 0
        take.sound(6)                                   // 106…111  touches note 0 only (§1.5 case 2)
        take.noise(40)                                  // 112…151
        take.sing(30, hz: 300)                          // 152…181  note 1
        take.noise(6)                                   // 182…187
        take.sound(6)                                   // 188…193  6 after vs 43 before: nearer the previous (case 3)
        take.noise(43)                                  // 194…236
        take.sing(30, hz: 400)                          // 237…266  note 2
        take.sound(6, confidence: 0.59)                 // 267…272  touches notes 2 AND 3 (case 4): a tie
        take.sing(30, hz: 450)                          // 273…302  note 3
        take.noise(12)                                  // 303…314
        take.sound(6)                                   // 315…320  12 before, 12 after: equal, a tie
        take.noise(12)                                  // 321…332
        take.sing(30, hz: 500)                          // 333…362  note 4
        take.noise(1)                                   // 363
        take.sound(6)                                   // 364…369  1 before, 2 after: touches both, a tie
        take.noise(2)                                   // 370…371
        take.sing(30, hz: 550)                          // 372…401  note 5
        take.noise(20)                                  // 402…421
        take.sound(6)                                   // 422…427  after the last note (case 1)
        take.noise(40)                                  // 428…467
        return (take, [
            Expected(first: 60, last: 65, side: .following, lender: 0),
            Expected(first: 106, last: 111, side: .previous, lender: 0),
            Expected(first: 188, last: 193, side: .previous, lender: 1),
            Expected(first: 267, last: 272, side: .following, lender: 3),
            Expected(first: 315, last: 320, side: .following, lender: 4),
            Expected(first: 364, last: 369, side: .following, lender: 5),
            Expected(first: 422, last: 427, side: .previous, lender: 5),
        ])
    }

    @Test("the nearer note lends, a tie goes to the following note, and a clip edge uses its only neighbour")
    func nearerNoteLendsAndTiesGoToTheFollowingNote() {
        let (take, expected) = Self.anchorTake()
        #expect(take.notes.count == 6)
        let found = take.find()
        #expect(matches(found.sounds, expected, in: take), "\(describe(found.sounds, in: take))")
        // §1.5 case 4: the missed piece of a sung note borrows the FOLLOWING note even
        // when the previous one is its real pitch. No neighbour rule fixes that (U-F3);
        // this pins U3 as the user confirmed it, and its own confidence rides along.
        // (A part's `centreHz` is a log-domain median: 450.0000000000001, not 450.)
        #expect(abs(found.sounds[3].anchorHz - 450) < 1e-9)
        #expect(found.sounds[3].anchorHz == take.notes[3].hz)
        #expect(found.sounds[3].medianConfidence == 0.59)
        // A sound touching one side and near the other is not a tie: nearer wins.
        var nearFollowing = Take()
        nearFollowing.noise(60); nearFollowing.sing(30, hz: 200); nearFollowing.noise(30)   // note 0 60…89
        nearFollowing.sound(6); nearFollowing.noise(4); nearFollowing.sing(30, hz: 300)     // sound 120…125
        nearFollowing.noise(40)
        #expect(matches(nearFollowing.find().sounds,
                        [Expected(first: 120, last: 125, side: .following, lender: 1)], in: nearFollowing))
    }

    @Test("stored notes: equal gaps are judged at frame resolution, and lenderIndex is the caller's order")
    func storedNotesJudgedAtFrameResolution() {
        var take = Take()
        take.noise(60)                                  //   0…59
        take.sing(30, hz: 200)                          //  60…89   note A
        take.noise(20)                                  //  90…109
        take.sound(12)                                  // 110…121  20 frames after A, 20 before B
        take.noise(20)                                  // 122…141
        take.sing(30, hz: 300)                          // 142…171  note B
        take.noise(40)
        let parts = take.notes
        // Passed B first: the lender index is the caller's, not the time order.
        let reversed = [parts[1], parts[0]]
        #expect(matches(take.find(notes: reversed).sounds,
                        [Expected(first: 110, last: 121, side: .following, lender: 0)],
                        in: take, notes: reversed))
        // B moved later by 0.3 of a frame (a stored edge off the grid): still equal at
        // frame resolution, so still a tie. By 0.6 of a frame, A is nearer.
        func movedB(by frames: Double) -> [Finder.Note] {
            [parts[0], Finder.Note(startSeconds: parts[1].startSeconds + frames * take.period,
                                   endSeconds: parts[1].endSeconds, hz: parts[1].hz)]
        }
        #expect(take.find(notes: movedB(by: 0.3)).sounds.first?.borrowedFrom == .following)
        #expect(take.find(notes: movedB(by: 0.6)).sounds.first?.borrowedFrom == .previous)
        #expect(take.find(notes: movedB(by: -0.3)).sounds.first?.borrowedFrom == .following)
        #expect(take.find(notes: movedB(by: -0.6)).sounds.first?.borrowedFrom == .following)
    }

    @Test("a stored note that lends no pitch still covers its time, and the sound borrows past it")
    func coveredButNotLending() {
        var take = Take()
        take.noise(60)                                  //   0…59
        take.sing(30, hz: 200)                          //  60…89   note A
        take.noise(20)                                  //  90…109
        take.sound(12)                                  // 110…121
        take.noise(20)                                  // 122…141
        take.sing(30, hz: 300)                          // 142…171  note B
        take.noise(40)
        let parts = take.notes
        // A stored `.unpitched` segment over 110…113: covered, never a lender.
        let storedSound = Finder.Note(startSeconds: take.time(110), endSeconds: take.time(114),
                                      hz: 999, lendsPitch: false)
        let notes = parts + [storedSound]
        let found = take.find(notes: notes).sounds
        #expect(matches(found, [Expected(first: 114, last: 121, side: .following, lender: 1)],
                        in: take, notes: notes), "\(describe(found, in: take))")
        // Control: had it lent, the sound would touch it and borrow its 999 Hz.
        let lending = parts + [Finder.Note(startSeconds: take.time(110), endSeconds: take.time(114),
                                           hz: 999)]
        #expect(take.find(notes: lending).sounds.first?.anchorHz == 999)
    }

    @Test("an edge off the frame grid clamps the sound, so it never overlaps the note")
    func offGridEdgeClampsTheSound() {
        var take = Take()
        take.noise(60)
        take.sing(30, hz: 200)                          //  60…89   note A
        take.noise(20)                                  //  90…109
        take.sound(12)                                  // 110…121
        take.noise(20)
        take.sing(30, hz: 300)                          // 142…171  note B
        take.noise(40)
        let parts = take.notes
        // A's end moved 5 ms into frame 110 (a user split off the grid): the frame's
        // midpoint (+8 ms) is still outside A, so the frame is in the sound, which
        // then starts exactly where A ends.
        let edge = take.time(110) + 0.005
        let notes = [Finder.Note(startSeconds: parts[0].startSeconds, endSeconds: edge, hz: parts[0].hz),
                     parts[1]]
        let sound = take.find(notes: notes).sounds
        #expect(sound.count == 1)
        #expect(sound.first?.startSeconds == edge)
        #expect(sound.first?.endSeconds == take.time(121) + take.period)
        #expect(sound.first?.frameCount == 12)
        // And the mirror at the far end: B starting 5 ms before frame 122 ends it there.
        let early = take.time(122) - 0.005
        let tailNotes = [parts[0], Finder.Note(startSeconds: early, endSeconds: parts[1].endSeconds,
                                               hz: parts[1].hz)]
        let clipped = take.find(notes: tailNotes).sounds
        #expect(clipped.first?.endSeconds == early)
        #expect(clipped.first?.startSeconds == take.time(110))
    }

    // MARK: Digital silence (a hard-gated take)

    /// A decision the design leaves implicit (§1.3 "a nil level ranks below
    /// everything"): when a tenth of the quiet is exact digital silence, F IS silence,
    /// every frame with any level is audible, and the silence itself never is.
    @Test("a hard-gated take: F is digital silence, any level is a sound, silence never is")
    func digitalSilenceFloor() {
        var take = Take()
        take.sing(30, hz: 200)                          //   0…29   note 0
        take.quiet(40, db: nil)                         //  30…69   the gate is shut
        take.sound(70, db: -60)                         //  70…139  a gate-open tail
        take.quiet(40, db: nil)                         // 140…179
        take.sing(30, hz: 300)                          // 180…209  note 1
        take.quiet(30, db: nil)                         // 210…239
        let found = take.find()
        #expect(found.skipped == nil)
        #expect(found.floor == .digitalSilence)
        #expect(found.floorDbfs == nil && found.thresholdDbfs == nil)
        // 40 frames either side: equal gaps, so the following note lends.
        #expect(matches(found.sounds, [Expected(first: 70, last: 139, side: .following, lender: 1)],
                        in: take), "\(describe(found.sounds, in: take))")
        // Control: under a planted 90th percentile the same take's floor is a level.
        var high = Finder.Rule.product
        high.floorPercentile = 0.9
        #expect(take.find(rule: high).floor == .level(-60))
    }

    // MARK: NaN and infinity

    @Test("NaN and infinity in any field never reach an output")
    func nonFiniteInputsAreGuarded() throws {
        let (take, _) = Self.knownTake()
        let notes = take.notes
        let clean = take.find()

        // Frames with no finite time are dropped.
        var frames = take.frames
        for time in [Double.nan, .infinity, -.infinity] {
            frames.append(ClipPitchFrame(timeSeconds: time, frequencyHz: nil, confidence: 0.5,
                                         levelDbfs: -30, absence: .belowConfidence))
        }
        #expect(Finder.sounds(in: frames, frameRateHz: take.rate, notes: notes) == clean)

        // A non-finite level is no level: the same answer as digital silence there.
        // Six floor frames and one frame inside a sound (a bridged dip either way).
        let poisoned = [5, 9, 20, 90, 100, 200, 44]
        func relevel(_ value: Double?) -> [ClipPitchFrame] {
            take.frames.enumerated().map { index, frame in
                guard poisoned.contains(index) else { return frame }
                return ClipPitchFrame(timeSeconds: frame.timeSeconds, frequencyHz: frame.frequencyHz,
                                      confidence: frame.confidence, levelDbfs: value, absence: frame.absence)
            }
        }
        let silent = Finder.sounds(in: relevel(nil), frameRateHz: take.rate, notes: notes)
        #expect(silent.floorDbfs != clean.floorDbfs, "the fixture moves the floor rank")
        for value in [Double.nan, .infinity, -.infinity] {
            let found = Finder.sounds(in: relevel(value), frameRateHz: take.rate, notes: notes)
            #expect(found == silent, "level \(value)")
            #expect(found.floorDbfs?.isFinite == true)
        }

        // A non-finite confidence is left out of the median.
        let doubted = take.frames.enumerated().map { index, frame in
            index == 41 ? ClipPitchFrame(timeSeconds: frame.timeSeconds, frequencyHz: nil,
                                         confidence: .nan, levelDbfs: frame.levelDbfs,
                                         absence: frame.absence) : frame
        }
        let confident = Finder.sounds(in: doubted, frameRateHz: take.rate, notes: notes)
        #expect(confident.sounds.allSatisfy { $0.medianConfidence == 0.6 })

        // Notes without a finite, positive-length span are ignored; a non-finite margin
        // heals to 9 dB.
        let junk = notes + [
            Finder.Note(startSeconds: .nan, endSeconds: 1, hz: 300),
            Finder.Note(startSeconds: 1, endSeconds: .infinity, hz: 300),
            Finder.Note(startSeconds: 2, endSeconds: 1, hz: 300),
        ]
        #expect(take.find(notes: junk).sounds == clean.sounds)
        for margin in [Double.nan, .infinity, -.infinity] {
            let healed = take.find(marginDb: margin)
            #expect(healed.marginDb == 9)
            #expect(healed.sounds == clean.sounds)
        }
    }

    // MARK: Invariants over random takes

    @Test("over 40 random takes: sounds are in order, apart, outside every note, long enough, and need no healing")
    func invariantsHoldOnRandomTakes() throws {
        var total = 0
        for seed in UInt64(1)...40 {
            let take = Self.randomTake(seed: seed)
            let notes = take.notes
            let found = take.find()
            #expect(found.skipped == nil)
            #expect(canonicalHealsNothing(notes: notes, sounds: found.sounds), "seed \(seed)")
            total += found.sounds.count
            for (index, sound) in found.sounds.enumerated() {
                #expect(sound.endSeconds - sound.startSeconds >= PitchAutoCorrect.minimumNoteSeconds)
                #expect(sound.startSeconds.isFinite && sound.endSeconds.isFinite)
                if index > 0 { #expect(found.sounds[index - 1].endSeconds <= sound.startSeconds) }
                #expect(notes.allSatisfy { $0.endSeconds <= sound.startSeconds || $0.startSeconds >= sound.endSeconds },
                        "seed \(seed): a sound overlaps a note")
                let lender = notes[sound.lenderIndex]
                #expect(sound.anchorHz == lender.hz && lender.hz > 0)
                switch sound.borrowedFrom {
                case .previous: #expect(lender.endSeconds <= sound.startSeconds)
                case .following: #expect(lender.startSeconds >= sound.endSeconds)
                }
                // Its frames are exactly the frames whose midpoints it spans. (Midpoints:
                // a clamp to a note's edge may move `startSeconds` by the last bit.)
                let inside = take.frames.filter {
                    let middle = $0.timeSeconds + take.period / 2
                    return middle >= sound.startSeconds && middle < sound.endSeconds
                }
                #expect(inside.count == sound.frameCount)
            }
        }
        #expect(total > 100, "the random takes must actually hold sounds (found \(total))")
    }

    // MARK: The user's take (env-gated port check)

    /// `UNPITCHED_REAL_TAKE_DETECTPITCH` = the product's own `clip.detectPitch` response
    /// on the user's take (`DUR/product/s1-detectpitch.json`, design §1.2). A PORT
    /// CHECK, not a pin: the design measured 38 sounds, 6.19 s, F = −37.4 dBFS, with
    /// its own replica. QA owns the real-take gate (UAB.json item QA).
    static let realTake = ProcessInfo.processInfo.environment["UNPITCHED_REAL_TAKE_DETECTPITCH"]

    /// The wire envelope `{id, ok, result}` around a `clip.detectPitch` response.
    private struct DetectPitchEnvelope: Decodable {
        let result: ClipPitchDetection
    }

    @Test("port check: the user's take finds about 38 sounds at F + 9 (design §1.2)",
          .enabled(if: realTake != nil))
    func realTakePortCheck() throws {
        let path = try #require(Self.realTake)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try JSONDecoder().decode(DetectPitchEnvelope.self, from: data).result.pitch
        let parts = PitchNoteSplitter.parts(in: result.frames, frameRateHz: result.frameRateHz)
        let notes = parts.map(Finder.Note.init(part:))
        let found = Finder.sounds(in: result, notes: notes)
        let floor = try #require(found.floorDbfs)
        let seconds = found.sounds.reduce(0) { $0 + ($1.endSeconds - $1.startSeconds) }
        let following = found.sounds.filter { $0.borrowedFrom == .following }.count
        print("unpitched-port| frames=\(result.frames.count) parts=\(parts.count) "
              + "F=\(floor) threshold=\(found.thresholdDbfs ?? .nan) V=\(found.singingDbfs ?? .nan) "
              + "sounds=\(found.sounds.count) seconds=\(seconds) following=\(following) "
              + "previous=\(found.sounds.count - following)")
        for sound in found.sounds {
            print("unpitched-port-sound| \(sound.startSeconds) \(sound.endSeconds) "
                  + "\(sound.borrowedFrom.rawValue) \(sound.anchorHz) \(sound.medianConfidence)")
        }
        #expect(found.skipped == nil)
        #expect(abs(floor + 37.4) < 0.1)
        #expect((36...40).contains(found.sounds.count))
        #expect(canonicalHealsNothing(notes: notes, sounds: found.sounds))
        // Level invariance on real material: the m4a is 21.5 dB quieter.
        var quieter = result
        quieter.frames = result.frames.map {
            ClipPitchFrame(timeSeconds: $0.timeSeconds, frequencyHz: $0.frequencyHz,
                           confidence: $0.confidence, levelDbfs: $0.levelDbfs.map { $0 - 21.5 },
                           absence: $0.absence)
        }
        #expect(Finder.sounds(in: quieter, notes: notes).sounds == found.sounds)
    }
}
