import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d2: `WordErrorRate`, a port of the spike's `code/wer.py` (design
/// §4.6 "Words").
///
/// NOT `@MainActor`: a pure function.
///
/// ⭐ The reference is `wer.py` ITSELF: `Fixtures/WordErrorRate/wer-py-reference.json`
/// was produced by running the spike's own interpreter
/// (`~/DAWPro-spikes/sing-soulx/venv-alt`, Python 3.10.20) on the spike's own
/// file (sha256 `3cfa55e9…`, recorded in the fixture), read-only. Each row holds
/// `wer.py`'s `norm` and `wer` for one (ref, hyp) pair, raw and with the curly
/// apostrophes mapped first: 46 hand-written rows (Unicode case mapping,
/// decomposed accents, emoji, CJK, empty texts, rates above 1) and 300 seeded
/// random ones.
@Suite("Word error rate — wer.py's own outputs, and the curly-apostrophe addition (p2-sing-d2)")
struct WordErrorRateTests {

    struct Fixture: Decodable {
        struct Provenance: Decodable {
            var werPySha256: String
            var python: String
            var curlyMappedFirst: [String]
        }
        struct Outcome: Decodable, Equatable {
            var refWords: [String]
            var hypWords: [String]
            var wer: Double?
            var edits: Int
            var refCount: Int
            var hypCount: Int
        }
        struct Case: Decodable {
            var origin: String
            var ref: String
            var hyp: String
            var hasCurly: Bool
            var raw: Outcome
            var mapped: Outcome
        }
        var provenance: Provenance
        var cases: [Case]
    }

    static func fixture() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(forResource: "wer-py-reference", withExtension: "json",
                              subdirectory: "Fixtures/WordErrorRate"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    static func outcome(_ ref: String, _ hyp: String, mapsCurlyApostrophes: Bool) -> Fixture.Outcome {
        let result = WordErrorRate.measure(reference: ref, hypothesis: hyp,
                                           mapsCurlyApostrophes: mapsCurlyApostrophes)
        return Fixture.Outcome(
            refWords: WordErrorRate.words(ref, mapsCurlyApostrophes: mapsCurlyApostrophes),
            hypWords: WordErrorRate.words(hyp, mapsCurlyApostrophes: mapsCurlyApostrophes),
            wer: result.wer, edits: result.edits,
            refCount: result.referenceWords, hypCount: result.hypothesisWords)
    }

    @Test("the fixture is wer.py's, and it is not trivial")
    func fixtureProvenance() throws {
        let fixture = try Self.fixture()
        #expect(fixture.provenance.werPySha256
                == "3cfa55e9e8ab0cbe28593293c1fdcd7251166234aedd06c4c5ae2d64f52dd2f7")
        #expect(fixture.provenance.python.hasSuffix("3.10.20"))
        #expect(fixture.provenance.curlyMappedFirst == ["U+2019", "U+2018", "U+02BC"])
        #expect(fixture.cases.count == 346)
        // Controls on the table itself: rates of 0, between 0 and 1, above 1,
        // and none; and rows where the curly map changes wer.py's answer.
        let rates = fixture.cases.map { $0.raw.wer }
        let hasZero = rates.contains { $0 == 0 }
        let hasPartial = rates.contains { ($0 ?? 0) > 0 && ($0 ?? 0) < 1 }
        let hasAboveOne = rates.contains { ($0 ?? 0) > 1 }
        let hasNone = rates.contains { $0 == nil }
        let mapChanges = fixture.cases.filter { $0.raw != $0.mapped }.count
        let onlyCurlyRowsChange = fixture.cases.allSatisfy { $0.hasCurly || $0.raw == $0.mapped }
        #expect(hasZero)
        #expect(hasPartial)
        #expect(hasAboveOne)
        #expect(hasNone)
        #expect(mapChanges >= 100, "\(mapChanges) rows where the curly map changes the answer")
        #expect(onlyCurlyRowsChange, "a row with no curly apostrophe must be the same raw and mapped")
    }

    @Test("the port without the addition is wer.py exactly: every row, words, edits and rate")
    func rawPortMatchesWerPy() throws {
        var mismatches: [String] = []
        for row in try Self.fixture().cases {
            let got = Self.outcome(row.ref, row.hyp, mapsCurlyApostrophes: false)
            if got != row.raw {
                mismatches.append("\(row.ref.debugDescription) / \(row.hyp.debugDescription): \(got) vs \(row.raw)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) rows differ, first: \(mismatches.prefix(3))")
    }

    @Test("the curly-apostrophe addition: every row matches wer.py run on the mapped text")
    func curlyMapMatchesWerPyOnMappedText() throws {
        let rows = try Self.fixture().cases
        var mismatches: [String] = []
        for row in rows {
            let got = Self.outcome(row.ref, row.hyp, mapsCurlyApostrophes: true)
            if got != row.mapped {
                mismatches.append("\(row.ref.debugDescription) / \(row.hyp.debugDescription): \(got) vs \(row.mapped)")
            }
            // The public entry points are the mapped port.
            if WordErrorRate.measure(reference: row.ref, hypothesis: row.hyp).wer != row.mapped.wer {
                mismatches.append("public measure: \(row.ref.debugDescription)")
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) rows differ, first: \(mismatches.prefix(3))")
        // The case the addition exists for (design §4.6).
        let dont = WordErrorRate.measure(reference: "don\u{2019}t stop", hypothesis: "don't stop")
        #expect(dont == WordErrorRate.Result(wer: 0, edits: 0, referenceWords: 2, hypothesisWords: 2))
        #expect(WordErrorRate.words("I\u{2019}m lovin\u{2019} it \u{02BC}til \u{2018}em") == ["i'm", "lovin'", "it", "'til", "'em"])
        // Control: wer.py alone splits the curly one.
        #expect(WordErrorRate.words("don\u{2019}t", mapsCurlyApostrophes: false) == ["don", "t"])
    }

    @Test("the map is the tokenizer's: the same three characters, one list")
    func oneListOfCurlyApostrophes() {
        #expect(LyricTokenizer.curlyApostrophes == ["\u{2019}", "\u{2018}", "\u{02BC}"])
        for scalar in LyricTokenizer.curlyApostrophes {
            let text = "don\(Character(scalar))t"
            let scored = WordErrorRate.words(text)
            let sung = LyricTokenizer.tokenize(text).words.map { $0.sung }
            #expect(scored == ["don't"])
            #expect(sung == ["don't"])
        }
    }

    @Test("the reference for a take: each lyric word once, as sung, however many notes it holds")
    func referenceIsEachWordOnce() throws {
        let notes = (0..<6).map { MIDINote(pitch: 60 + $0, startBeat: Double($0), lengthBeats: 1) }
        let assignment = try LyricNoteAssigner.assign(
            LyricTokenizer.tokenize("Twin-kle, star +\nhigh"), notes: notes, clipStartBeat: 0,
            tempoMap: TempoMap(constantBPM: 120))
        let held = assignment.words.reduce(0) { $0 + $1.noteIDs.count }
        let reference = WordErrorRate.reference(for: assignment)
        #expect(held == 6, "control: the three words hold six notes")
        #expect(reference == "Twinkle star high", "each word once, as sung (the rate lowercases)")
        #expect(WordErrorRate.measure(reference: reference, hypothesis: "twinkle, star… high!").wer == 0)
    }
}
