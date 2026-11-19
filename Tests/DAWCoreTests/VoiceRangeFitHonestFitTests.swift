import CryptoKit
import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x9-f5 (W8-X9F5): the key proposal (`VoiceRangeFit.propose`, what `sing.proposeKey`, the Sing sheet's height
/// line and `sing.render`'s "auto" line read) said "Fits your voice." for a melody 4.6 semitones out of band: when no
/// key change does better, `kind` falls back to the octave route even though it does not fit, and the octave-0
/// sentence was fixed text. The same held for "— right where you sing." on a key change that does not fit.
///
/// Now `KeyProposal.fits` says whether the recommendation fits (out-of-band term ≤ `octaveOnlyAcceptOutOfBand`, or no
/// note outside at all), and a recommendation that does not fit reads a sentence that says so and where. Every
/// proposal that fits is unchanged, byte for byte.
///
/// The proof runs over the key-proposal pin's own fixtures (`VoiceRangeFitProposeKeyPinTests`: 6 melodies x 181
/// voices). "Legacy bytes" = the whole proposal encoded with sorted keys, the one new `fits` key taken out: exactly
/// what HEAD (`e7e4d24`) encoded. The BEFORE literals below were captured on the tree's `VoiceRangeFit.swift` before
/// this edit (sha256 35b74919…, 2026-10-07 10:01, `$S/w8/X9F5/before.log`), whose `propose` and sentences are HEAD's
/// (its diff from HEAD is `KeyFitWeights`' harmony fields only). Nonisolated (pure DAWCore).
@Suite("VoiceRangeFit: the key proposal says a melody fits only when it does (p2-sing-x9-f5)")
struct VoiceRangeFitHonestFitTests {
    typealias Pin = VoiceRangeFitProposeKeyPinTests

    static let acceptOutOfBand = KeyFitWeights.provisional.octaveOnlyAcceptOutOfBand

    /// The rule, restated here so the test does not read it back from the code under test.
    static func fitsByRule(_ c: KeyFitCandidate, accept: Double = acceptOutOfBand) -> Bool {
        c.outOfBandSemitones <= accept || c.outOfBandSemitones == 0
    }

    static func legacyBytes(_ proposal: KeyProposal,
                            blankSentence: Bool = false) throws -> (bytes: Data, removed: Int) {
        var proposal = proposal
        if blankSentence { proposal.sentence = "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var text = String(decoding: try encoder.encode(proposal), as: UTF8.self)
        var removed = 0
        for key in [#""fits":true,"#, #""fits":false,"#] {
            let parts = text.components(separatedBy: key)
            removed += parts.count - 1
            text = parts.joined()
        }
        return (Data(text.utf8), removed)
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    struct Row {
        var name: String
        var index: Int
        var voice: VoiceRange
        var fits: Bool
        var proposal: KeyProposal
    }

    struct Census {
        var fittingDigest: String
        var blankDigest: String
        var fitting: Int
        var notFitting: Int
        var removed: Int
        var rows: [Row]
    }

    /// Every pin fixture, in the pin's order. `encode: false` skips the (slow) encodings: the digests are then empty.
    /// With `X9F5_ROWS=1` in the environment, one line per row.
    static func census(encode: Bool = true) throws -> Census {
        var fittingHasher = SHA256()
        var blankHasher = SHA256()
        var fitting = 0, notFitting = 0, removed = 0
        var rows: [Row] = []
        let printRows = encode && ProcessInfo.processInfo.environment["X9F5_ROWS"] == "1"
        for (name, notes) in try Pin.melodies() {
            for (index, voice) in Pin.voices().enumerated() {
                let proposal = try #require(VoiceRangeFit.propose(melody: notes, voice: voice))
                let fits = fitsByRule(proposal.recommendation)
                if fits { fitting += 1 } else { notFitting += 1 }
                rows.append(Row(name: name, index: index, voice: voice, fits: fits, proposal: proposal))
                guard encode else { continue }
                let legacy = try legacyBytes(proposal)
                let blank = try legacyBytes(proposal, blankSentence: true)
                removed += legacy.removed
                if fits { fittingHasher.update(data: legacy.bytes) }
                blankHasher.update(data: blank.bytes)
                if printRows {
                    let r = proposal.recommendation
                    print(String(format: "X9F5-ROW|%@|%d|%@|%@|t%+d o%+d|oob %.4f|below %.4f|above %.4f|%@|%@|%@",
                                 name, index, fits ? "fit" : "NOFIT", proposal.kind.rawValue, r.songTranspose,
                                 r.octaveShift, r.outOfBandSemitones, r.fractionBelowBand, r.fractionAboveBand,
                                 hex(SHA256.hash(data: legacy.bytes)), hex(SHA256.hash(data: blank.bytes)),
                                 proposal.sentence))
                }
            }
        }
        return Census(fittingDigest: hex(fittingHasher.finalize()), blankDigest: hex(blankHasher.finalize()),
                      fitting: fitting, notFitting: notFitting, removed: removed, rows: rows)
    }

    /// Captured on HEAD's code (BEFORE run): the legacy bytes of every FITTING row, hashed in order; the legacy bytes
    /// of EVERY row with its sentence blanked; and the split.
    static let beforeFittingDigest = "4189142fa2a89972b51f8fbd616c29edde41666765751ac1c0dbf3a2e4b4de2d"
    static let beforeBlankDigest = "50ae8ef98d9242d1d54c129a181535442d336816644be08c161f9239d20dadc0"
    static let beforeFitting = 659
    static let beforeNotFitting = 427

    @Test("every proposal that fits is byte for byte what HEAD shipped; where one does not, only its sentence moved")
    func onlyTheSentencesThatDoNotFitMoved() throws {
        let c = try Self.census()
        print("X9F5-CENSUS|fitting \(c.fitting)|notFitting \(c.notFitting)|fittingDigest \(c.fittingDigest)"
              + "|blankDigest \(c.blankDigest)|removed \(c.removed)")
        // Exactly one `fits` key per proposal, so the legacy bytes really are HEAD's encoding.
        #expect(c.removed == c.rows.count)
        #expect(c.fitting == Self.beforeFitting)
        #expect(c.notFitting == Self.beforeNotFitting)
        #expect(c.fittingDigest == Self.beforeFittingDigest)
        #expect(c.blankDigest == Self.beforeBlankDigest)
    }

    /// HEAD `e7e4d24`'s `VoiceRangeFit.sentence(kind:recommendation:voiceIsLower:)`, same strings: what was shown.
    static func headSentence(kind: KeyProposal.Kind, recommendation r: KeyFitCandidate, voiceIsLower: Bool) -> String {
        switch kind {
        case .octave:
            if r.octaveShift == 0 { return "Fits your voice." }
            let lower = r.octaveShift < 0
            return "Your voice sits \(lower ? "lower" : "higher") than this tune. I'll sing it "
                + "\(VoiceRangeFit.octaveWords(r.octaveShift)) \(lower ? "lower" : "higher") — it stays in tune with "
                + "the rest of the song."
        case .songKey:
            let steps = abs(r.songTranspose)
            let move = "move the whole song \(r.songTranspose > 0 ? "up" : "down") \(steps) "
                + (steps == 1 ? "half-step" : "half-steps")
            let sing = r.octaveShift == 0
                ? ""
                : " and I'll sing it \(VoiceRangeFit.octaveWords(r.octaveShift)) "
                    + (r.octaveShift < 0 ? "lower" : "higher")
            return "This tune is much \(voiceIsLower ? "higher" : "lower") than your voice. Best: \(move)\(sing) — "
                + "right where you sing."
        }
    }

    /// The side words, restated: both edges crossed → both named; one edge → that one.
    static func outsideByRule(_ r: KeyFitCandidate) -> String? {
        switch (r.fractionBelowBand > 0, r.fractionAboveBand > 0) {
        case (true, true): "some notes will be above and some below where you usually sing"
        case (true, false): "some low notes will be below where you usually sing"
        case (false, true): "some high notes will be above where you usually sing"
        case (false, false): nil
        }
    }

    /// What a row that does not fit must read: HEAD's sentence with its claim of a fit replaced.
    static func expectedNotFitting(_ row: Row) -> String? {
        let p = row.proposal, r = p.recommendation
        guard let outside = outsideByRule(r) else { return nil }
        if p.kind == .octave, r.octaveShift == 0 { return "This tune doesn't fully fit your voice: \(outside)." }
        let head = headSentence(kind: p.kind, recommendation: r,
                                voiceIsLower: row.voice.medianMidi < p.melodyMedianMidi)
        let claim = p.kind == .octave ? "." : " — right where you sing."
        guard head.hasSuffix(claim) else { return nil }
        return String(head.dropLast(claim.count)) + ", though \(outside)."
    }

    @Test("`fits` is the rule on every fixture; a row that fits reads HEAD's sentence, one that does not never does")
    func fitsAndSentencesAgreeOnEveryFixture() throws {
        let c = try Self.census(encode: false)
        var wrongFits: [String] = [], movedWhileFitting: [String] = [], wrongNotFitting: [String] = []
        var categories: [String: Int] = [:]
        for row in c.rows {
            let p = row.proposal, r = p.recommendation
            let label = "\(row.name)#\(row.index)"
            if p.fits != row.fits { wrongFits.append(label) }
            let head = Self.headSentence(kind: p.kind, recommendation: r,
                                         voiceIsLower: row.voice.medianMidi < p.melodyMedianMidi)
            if row.fits {
                if p.sentence != head { movedWhileFitting.append("\(label): \(p.sentence)") }
                continue
            }
            let side = r.fractionBelowBand > 0 && r.fractionAboveBand > 0 ? "both"
                : r.fractionBelowBand > 0 ? "below" : "above"
            categories["\(p.kind.rawValue)|\(r.octaveShift == 0 ? "o0" : "oN")|\(side)", default: 0] += 1
            if p.sentence == head || p.sentence == "Fits your voice." || p.sentence.contains("right where you sing")
                || p.sentence != Self.expectedNotFitting(row) {
                wrongNotFitting.append("\(label): \(p.sentence)")
            }
        }
        let census = categories.keys.sorted().map { "\($0) \(categories[$0] ?? 0)" }
        print("X9F5-CATEGORIES|" + census.joined(separator: "|"))
        #expect(wrongFits.isEmpty, "\(wrongFits.count) rows where `fits` is not the rule: \(wrongFits.prefix(5))")
        #expect(movedWhileFitting.isEmpty,
                "\(movedWhileFitting.count) fitting rows moved: \(movedWhileFitting.prefix(3))")
        #expect(wrongNotFitting.isEmpty,
                "\(wrongNotFitting.count) rows that do not fit read a wrong line: \(wrongNotFitting.prefix(3))")
        // Every branch is exercised: the written height, a moved octave and a key change, each side.
        #expect(c.notFitting > 0)
        for key in ["octave|o0|both", "octave|o0|below", "octave|oN|both", "octave|oN|below", "songKey|o0|both",
                    "songKey|o0|below", "songKey|oN|both", "songKey|oN|below", "songKey|oN|above"] {
            #expect((categories[key] ?? 0) > 0, "no fixture in \(key)")
        }
    }

    static let builtIn = Pin.literalVoices[0]

    @Test("the wide arpeggio on the built-in singer, 4.6 semitones out of band, no longer reads 'Fits your voice.'")
    func wideArpeggioOnTheBuiltInSinger() throws {
        let wide = Pin.melody([48, 55, 60, 64, 67, 72, 76, 79])
        let p = try #require(VoiceRangeFit.propose(melody: wide, voice: Self.builtIn))
        #expect(p.kind == .octave && p.recommendation.songTranspose == 0 && p.recommendation.octaveShift == 0)
        #expect(abs(p.recommendation.outOfBandSemitones - 4.625) < 1e-9, "\(p.recommendation.outOfBandSemitones)")
        #expect(p.recommendation.fractionBelowBand == 0.375 && p.recommendation.fractionAboveBand == 0.375)
        #expect(p.fits == false)
        #expect(p.sentence == "This tune doesn't fully fit your voice: some notes will be above and some below where "
                + "you usually sing.")
        #expect(p.alternative == nil && p.alternativeSentence == nil)
    }

    @Test("neither route fits (a held high note, built-in singer): a key change no longer reads 'right where you sing'")
    func neitherRouteFits() throws {
        let held = Pin.melody([60, 62, 64, 65, 74], beats: [1, 1, 1, 1, 6])
        let p = try #require(VoiceRangeFit.propose(melody: held, voice: Self.builtIn))
        #expect(p.kind == .songKey && p.recommendation.songTranspose == -3 && p.recommendation.octaveShift == 0)
        #expect(p.fits == false)
        #expect(!Self.fitsByRule(p.bestOctaveOnly), "the octave route fits after all: \(p.bestOctaveOnly)")
        #expect(p.sentence == "This tune is much higher than your voice. Best: move the whole song down 3 half-steps, "
                + "though some notes will be above and some below where you usually sing.")
        // "Keep the key" was already true (it always names an edge) and is unchanged.
        #expect(p.alternativeSentence == "Keep the song as it is and I'll sing it as written (some high notes will be "
                + "above where you usually sing).")
    }

    /// (melody, voice, the exact line). Hand-written from the rule; each one is a branch of the copy.
    static let lines: [(name: String, notes: [VoiceRangeFit.MelodyNote], voice: VoiceRange, line: String)] = [
        ("written height, low notes below", Pin.melody([60, 62, 64, 65, 74], beats: [1, 1, 1, 1, 6]),
         VoiceRange(p10Midi: 66, medianMidi: 69.5, p90Midi: 73),
         "This tune doesn't fully fit your voice: some low notes will be below where you usually sing."),
        ("written height, high notes above", Pin.melody([62, 64, 65, 67, 77]), builtIn,
         "This tune doesn't fully fit your voice: some high notes will be above where you usually sing."),
        ("two octaves lower, low notes below", Pin.melody([60, 62, 64, 65, 74], beats: [1, 1, 1, 1, 6]),
         VoiceRange(p10Midi: 40.5, medianMidi: 44, p90Midi: 53.6),
         "Your voice sits lower than this tune. I'll sing it two octaves lower — it stays in tune with the rest of the "
            + "song, though some low notes will be below where you usually sing."),
        ("key change and two octaves lower, low notes below", Pin.melody([60, 62, 64, 65, 67]),
         VoiceRange(p10Midi: 40.5, medianMidi: 42.5, p90Midi: 44.5),
         "This tune is much higher than your voice. Best: move the whole song up 2 half-steps and I'll sing it two "
            + "octaves lower, though some low notes will be below where you usually sing."),
    ]

    @Test("each side and each route reads its own line when it does not fit")
    func eachBranchReadsItsLine() throws {
        for fixture in Self.lines {
            let p = try #require(VoiceRangeFit.propose(melody: fixture.notes, voice: fixture.voice), "\(fixture.name)")
            #expect(p.fits == false, "\(fixture.name)")
            #expect(p.sentence == fixture.line, "\(fixture.name)")
        }
    }

    @Test("`fits` reads the weights the proposal was made with, and a melody that fits keeps 'Fits your voice.'")
    func fitsFollowsTheWeights() throws {
        let wide = Pin.melody([48, 55, 60, 64, 67, 72, 76, 79])
        var loose = KeyFitWeights.provisional
        loose.octaveOnlyAcceptOutOfBand = 5
        let p = try #require(VoiceRangeFit.propose(melody: wide, voice: Self.builtIn, weights: loose))
        #expect(p.fits == true && p.kind == .octave && p.recommendation.octaveShift == 0)
        #expect(p.sentence == "Fits your voice.")
        let five = try #require(VoiceRangeFit.propose(melody: Pin.melody([60, 62, 64, 65, 67]), voice: Self.builtIn))
        #expect(five.fits == true && five.sentence == "Fits your voice.")
    }
}
