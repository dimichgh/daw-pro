import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d1: `EnglishSyllables.estimate`, the vowel-group heuristic that
/// shares spare notes (design §3.3 "Syllables").
///
/// NOT `@MainActor`: a pure function, and the tree is at its `@MainActor`
/// suite ceiling.
///
/// The gate is design §3.3's: at least 90% exact on a 1,000-word fixture
/// derived from CMUdict. The fixture's header states its sampling rule (fixed
/// before the heuristic existed) and its inputs' hashes; the heuristic was
/// tuned only on words outside it. Every expectation in the tables below is a
/// CMUdict count (letters) or the documented reading of a number.
@Suite("English syllables — the estimate that shares spare notes (p2-sing-d1)")
struct EnglishSyllablesTests {

    /// Design §3.3's bar. It is not a knob: a heuristic below it blocks
    /// p2-sing-d1, and the figure is reported, never the bar lowered.
    static let bar = 0.90

    private static func fixtureRows() throws -> [(word: String, syllables: Int)] {
        let url = try #require(
            Bundle.module.url(forResource: "cmudict-1000", withExtension: "tsv",
                              subdirectory: "Fixtures/EnglishSyllables"),
            "the fixture is not in the test bundle — check the resources: declaration on DAWCoreTests")
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [(String, Int)] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            try #require(fields.count == 2, "malformed fixture row: \(line)")
            rows.append((String(fields[0]), try #require(Int(fields[1]))))
        }
        return rows
    }

    @Test("at least 90% exact on the 1,000-word CMUdict fixture, measured and printed")
    func fixtureAccuracy() throws {
        let rows = try Self.fixtureRows()
        // A truncated or empty fixture must not pass by being easy.
        #expect(rows.count == 1_000)
        var exact = 0
        var misses: [String] = []
        for row in rows {
            let got = EnglishSyllables.estimate(row.word)
            if got == row.syllables { exact += 1 } else { misses.append("\(row.word) \(row.syllables)→\(got)") }
        }
        let fraction = Double(exact) / Double(max(rows.count, 1))
        print("[measured] EnglishSyllables on cmudict-1000: \(exact)/\(rows.count) = "
              + String(format: "%.1f%%", fraction * 100) + " exact (bar \(Int(Self.bar * 100))%)")
        print("[measured] misses (CMUdict→estimate): " + misses.joined(separator: ", "))
        #expect(fraction >= Self.bar)
    }

    @Test("every real word is at least one syllable; no letters or digits is zero")
    func floorIsOne() throws {
        for row in try Self.fixtureRows() {
            #expect(EnglishSyllables.estimate(row.word) >= 1, "\(row.word)")
        }
        for empty in ["", "...", "!", "—", "  "] {
            #expect(EnglishSyllables.estimate(empty) == 0, "\(empty)")
        }
    }

    @Test("spelling rules: silent e, syllabic -le, -ed, -es, vowel groups, y",
          arguments: [
              ("make", 1), ("time", 1), ("love", 1), ("believe", 2),
              ("little", 2), ("table", 2), ("simple", 2), ("circle", 2),
              ("walked", 1), ("loved", 1), ("played", 1), ("wanted", 2), ("needed", 2),
              ("makes", 1), ("roses", 2), ("wishes", 2), ("places", 2), ("tables", 2),
              ("rain", 1), ("boat", 1), ("house", 1), ("voice", 1), ("tree", 1),
              ("lion", 2), ("piano", 3), ("radio", 3), ("idea", 3), ("quiet", 2),
              ("being", 2), ("going", 2), ("happy", 2), ("yes", 1), ("they", 1),
              ("beyond", 2), ("flying", 2), ("hopeful", 2), ("lonely", 2),
              ("homeward", 2), ("sometimes", 2), ("everything", 3), ("forever", 3),
          ])
    func spellingRules(word: String, syllables: Int) {
        #expect(EnglishSyllables.estimate(word) == syllables)
    }

    @Test("contractions, straight and curly apostrophes",
          arguments: [
              ("didn't", 2), ("didn’t", 2), ("don't", 1), ("don’t", 1), ("can't", 1),
              ("won't", 1), ("couldn't", 2), ("I'm", 1), ("you'll", 1), ("it'll", 2),
              ("lovin'", 2), ("'cause", 1),
          ])
    func contractions(word: String, syllables: Int) {
        #expect(EnglishSyllables.estimate(word) == syllables)
    }

    @Test("numbers are read aloud: cardinals, years, ordinals, decimals, thousands",
          arguments: [
              ("7", 2), ("0", 2), ("99", 3), ("100", 3), ("2nd", 2), ("21st", 3),
              ("1999", 5), ("2005", 4), ("3.5", 3), ("1,000", 3),
              ("42", 3), ("22nd", 4), ("101st", 5), ("1999th", 10), ("1900s", 4), ("90's", 2), ("3 2 1", 3),
          ])
    func numbers(word: String, syllables: Int) {
        #expect(EnglishSyllables.estimate(word) == syllables)
    }

    /// The singing facade sings g2p_en's own expansion of a number ("42" is
    /// "forty two"), so the count must be that expansion's. The fixture holds
    /// g2p_en's REAL output (its header says how it was made), so this pins
    /// what is sung rather than a second hand-written reading of it.
    @Test("numbers count what the singer says: g2p_en's own expansion, row by row")
    func numbersMatchTheSinger() throws {
        let url = try #require(
            Bundle.module.url(forResource: "g2p-en-numbers", withExtension: "tsv",
                              subdirectory: "Fixtures/EnglishSyllables"),
            "the fixture is not in the test bundle — check the resources: declaration on DAWCoreTests")
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows = 0
        var misses: [String] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            try #require(fields.count == 3, "malformed fixture row: \(line)")
            let want = try #require(Int(fields[2]))
            rows += 1
            let got = EnglishSyllables.estimate(String(fields[0]))
            if got != want { misses.append("\(fields[0]) (\(fields[1])) \(want)→\(got)") }
        }
        print("[measured] numbers vs g2p_en's expansion: \(rows - misses.count)/\(rows) exact")
        // A truncated fixture must not pass by being short.
        #expect(rows == 4_442)
        #expect(misses.isEmpty, "\(misses.count) rows differ, first: \(misses.prefix(12).joined(separator: ", "))")
    }

    @Test("hyphen parts are summed; hums are one; letters with no vowel are spelled")
    func partsHumsAndLetters() {
        #expect(EnglishSyllables.estimate("twin-kle") == 2)
        #expect(EnglishSyllables.estimate("well-known") == 2)
        #expect(EnglishSyllables.estimate("hmm") == 1)
        #expect(EnglishSyllables.estimate("shh") == 1)
        #expect(EnglishSyllables.estimate("tv") == 2)
    }

    @Test("case never changes the count")
    func caseInsensitive() {
        for word in ["LOVE", "Twinkle", "DiDn'T", "EVERYTHING"] {
            #expect(EnglishSyllables.estimate(word) == EnglishSyllables.estimate(word.lowercased()), "\(word)")
        }
    }
}
