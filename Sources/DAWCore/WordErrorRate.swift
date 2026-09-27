import Foundation

/// Word error rate between the words that were sung and the words a
/// transcriber heard (p2-sing-d2, design `docs/design/2026-09-27-p2-sing-integration.md`
/// §4.6 "Words").
///
/// ## A port, not a new metric
///
/// This is the spike's `code/wer.py` (sha256 `3cfa55e9…`), which scored every
/// take the user listened to, so the app's number means what the spike's
/// number meant:
///
/// 1. lowercase (Python's `str.lower()`: the full Unicode lowercase mapping,
///    so the Kelvin sign becomes `k` and `İ` becomes `i` plus a combining dot);
/// 2. every character outside `a-z`, `0-9`, `'` and space becomes a space.
///    This runs on Unicode SCALARS, as Python's regex does on code points: a
///    decomposed `é` keeps its `e`, a precomposed `é` is dropped whole;
/// 3. split on spaces;
/// 4. word-level Levenshtein distance (substitution, insertion, deletion all
///    cost 1), divided by the number of REFERENCE words. A reference with no
///    words has no rate (`wer.py`'s `None`), and a rate can exceed 1.
///
/// `Tests/DAWCoreTests/Fixtures/WordErrorRate/wer-py-reference.json` holds
/// `wer.py`'s own outputs for 346 inputs, produced by running the spike's
/// interpreter on the spike's file, read-only; the tests compare against it.
///
/// ## One documented addition: curly apostrophes
///
/// Before step 1, the three characters `LyricTokenizer` straightens
/// (`LyricTokenizer.curlyApostrophes`: U+2019, U+2018, U+02BC) become `'`.
/// `wer.py` treats them as separators, so "don’t" scored as two wrong words
/// against "don't" (design §4.6). The consequence, the same as `wer.py`'s own
/// handling of straight quotes: a word wrapped in curly single quotes keeps
/// them ("‘hello’" reads `'hello'`, not `hello`).
///
/// Pure: Foundation only, no state, safe from any thread.
public enum WordErrorRate {

    /// The score for one reference/hypothesis pair: `wer.py`'s dictionary.
    public struct Result: Equatable, Sendable {
        /// `edits / referenceWords`; nil when the reference has no words.
        public var wer: Double?
        /// The word-level edit distance.
        public var edits: Int
        public var referenceWords: Int
        public var hypothesisWords: Int

        public init(wer: Double?, edits: Int, referenceWords: Int, hypothesisWords: Int) {
            self.wer = wer
            self.edits = edits
            self.referenceWords = referenceWords
            self.hypothesisWords = hypothesisWords
        }
    }

    /// Scores `hypothesis` against `reference`.
    public static func measure(reference: String, hypothesis: String) -> Result {
        measure(reference: reference, hypothesis: hypothesis, mapsCurlyApostrophes: true)
    }

    /// The words `measure` compares: `wer.py`'s `norm`, after the curly map.
    public static func words(_ text: String) -> [String] {
        words(text, mapsCurlyApostrophes: true)
    }

    /// The reference text for a sung take: each lyric word ONCE, as sung, no
    /// matter how many notes it holds across (design §4.6, the spike's
    /// `ref_from_meta`, which reads only a word's first note).
    public static func reference(for assignment: LyricAssignment) -> String {
        assignment.words.map(\.word.sung).joined(separator: " ")
    }

    // MARK: - The port

    /// `mapsCurlyApostrophes: false` is `wer.py` exactly, with no addition.
    /// Internal: it exists so the parity tests can compare against `wer.py`'s
    /// raw outputs and the curly map is tested on its own.
    static func measure(reference: String, hypothesis: String, mapsCurlyApostrophes: Bool) -> Result {
        let r = words(reference, mapsCurlyApostrophes: mapsCurlyApostrophes)
        let h = words(hypothesis, mapsCurlyApostrophes: mapsCurlyApostrophes)
        // wer.py's single-row Levenshtein, transcribed: `d[j]` is the distance
        // from the first i reference words to the first j hypothesis words.
        var d = Array(0...h.count)
        if !r.isEmpty {
            for i in 1...r.count {
                var previous = d[0]
                d[0] = i
                if !h.isEmpty {
                    for j in 1...h.count {
                        let current = min(d[j] + 1, d[j - 1] + 1, previous + (r[i - 1] == h[j - 1] ? 0 : 1))
                        previous = d[j]
                        d[j] = current
                    }
                }
            }
        }
        let edits = d[h.count]
        return Result(wer: r.isEmpty ? nil : Double(edits) / Double(r.count),
                      edits: edits, referenceWords: r.count, hypothesisWords: h.count)
    }

    static func words(_ text: String, mapsCurlyApostrophes: Bool) -> [String] {
        var input = text
        if mapsCurlyApostrophes {
            input = String(String.UnicodeScalarView(text.unicodeScalars.map {
                LyricTokenizer.curlyApostrophes.contains($0) ? "'" : $0
            }))
        }
        var kept = String.UnicodeScalarView()
        for scalar in input.lowercased().unicodeScalars {
            kept.append(isKept(scalar) ? scalar : " ")
        }
        return String(kept).split(separator: " ").map(String.init)
    }

    /// `[a-z0-9' ]`, ASCII only, exactly `wer.py`'s character class.
    private static func isKept(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x61...0x7A, 0x30...0x39, 0x27, 0x20: return true
        default: return false
        }
    }
}
