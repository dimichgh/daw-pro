import Foundation

/// How many syllables a typed English lyric word has, ESTIMATED from its
/// spelling (p2-sing-d1, design §3.3 "Syllables").
///
/// A pure vowel-group heuristic: no dictionary, no model, no engine. It runs
/// while the singing engine is down, so the lyric preview is instant. Its
/// only job is to share SPARE notes (`LyricNoteAssigner` rule 5): a miscount
/// changes which word holds a spare note, never whether a word is sung, and a
/// typed `+` or hyphen overrides it.
///
/// ## Measured, not assumed
///
/// Design §3.3 sets the bar at 90% exact on a 1,000-word fixture derived from
/// CMUdict. `Tests/DAWCoreTests/Fixtures/EnglishSyllables/cmudict-1000.tsv`
/// is that fixture; its header states the sampling rule, fixed before any of
/// these rules existed, and the two input hashes. The rules were tuned only on
/// words OUTSIDE it, and `EnglishSyllablesTests` prints the measured figure
/// on every run (97.3% when this was written, W7-SD1 2026-09-27).
///
/// Where it is knowingly wrong: a middle e that a word swallows in speech
/// (werewolf, foreshadowed, whatsoever), "-ire" words that CMUdict splits in
/// two (tires, umpires), and loanwords that keep a sung final e (protege).
public enum EnglishSyllables {

    /// The estimated syllable count of one word.
    ///
    /// - Letters are counted by vowel groups with English spelling rules on top.
    /// - Digits are read the way the singing engine's text front end reads them
    ///   (`"99"` is "ninety-nine", 3 syllables).
    /// - Apostrophes and a few contractions are handled (`"didn't"` is 2).
    /// - Hyphen parts are counted separately and summed.
    ///
    /// Returns 0 only for a string with no letters or digits at all; any real
    /// word is at least 1.
    public static func estimate(_ word: String) -> Int {
        var total = 0
        for part in word.split(separator: "-") {
            total += estimatePart(part)
        }
        return total
    }

    // MARK: - One hyphen-free part: runs of letters, digits and decimal points

    private enum Run {
        case letters([UInt8])
        case digits([UInt8])
        case point
    }

    private static func estimatePart(_ part: Substring) -> Int {
        let scalars = Array(part.unicodeScalars).map(\.value)
        func isLetter(_ v: UInt32) -> Bool { (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v) }
        func isDigit(_ v: UInt32) -> Bool { (0x30...0x39).contains(v) }
        func isApostrophe(_ v: UInt32) -> Bool { v == 0x27 || v == 0x2019 || v == 0x2018 || v == 0x2BC }

        var runs: [Run] = []
        var k = 0
        while k < scalars.count {
            let v = scalars[k]
            if isLetter(v) {
                var bytes: [UInt8] = []
                while k < scalars.count, isLetter(scalars[k]) || isApostrophe(scalars[k]) {
                    bytes.append(isApostrophe(scalars[k]) ? 0x27 : UInt8(scalars[k] | 0x20))
                    k += 1
                }
                runs.append(.letters(bytes))
            } else if isDigit(v) {
                var bytes: [UInt8] = []
                while k < scalars.count {
                    if isDigit(scalars[k]) {
                        bytes.append(UInt8(scalars[k])); k += 1
                    } else if scalars[k] == 0x2C, k + 1 < scalars.count, isDigit(scalars[k + 1]) {
                        k += 1                                         // 1,000
                    } else if scalars[k] == 0x2E, k + 1 < scalars.count, isDigit(scalars[k + 1]) {
                        runs.append(.digits(bytes)); runs.append(.point)   // 3.5 = "three point five"
                        bytes = []; k += 1
                    } else {
                        break
                    }
                }
                runs.append(.digits(bytes))
            } else {
                k += 1
            }
        }

        var total = 0
        var r = 0
        while r < runs.count {
            switch runs[r] {
            case .point:
                total += 1
            case .digits(let digits):
                if r + 1 < runs.count, case .letters(let suffix) = runs[r + 1], ordinalSuffixes.contains(suffix) {
                    total += SpokenNumbers.ordinalSyllables(digits: digits)        // 2nd, 21st
                    r += 1
                } else if r + 1 < runs.count, case .letters(let suffix) = runs[r + 1], suffix == pluralS {
                    total += SpokenNumbers.syllables(digits: digits)               // 1900s, 90's: the plural
                    r += 1                                                         // adds no syllable
                } else {
                    total += SpokenNumbers.syllables(digits: digits)
                }
            case .letters(let letters):
                total += wordSyllables(letters)
            }
            r += 1
        }
        return total
    }

    private static let ordinalSuffixes: Set<[UInt8]> = [Array("st".utf8), Array("nd".utf8), Array("rd".utf8), Array("th".utf8)]
    private static let pluralS: [UInt8] = Array("s".utf8)

    // MARK: - Letters

    private static let a: UInt8 = 0x61, c: UInt8 = 0x63, d: UInt8 = 0x64, e: UInt8 = 0x65
    private static let g: UInt8 = 0x67, h: UInt8 = 0x68, i: UInt8 = 0x69, l: UInt8 = 0x6C
    private static let m: UInt8 = 0x6D, n: UInt8 = 0x6E, o: UInt8 = 0x6F, p: UInt8 = 0x70
    private static let q: UInt8 = 0x71, r: UInt8 = 0x72, s: UInt8 = 0x73, t: UInt8 = 0x74
    private static let u: UInt8 = 0x75, v: UInt8 = 0x76, x: UInt8 = 0x78, y: UInt8 = 0x79, z: UInt8 = 0x7A
    /// The letter w (`w` names the word being counted).
    private static let letterW: UInt8 = 0x77
    private static let apostrophe: UInt8 = 0x27

    @inline(__always) private static func isAEIOU(_ ch: UInt8) -> Bool {
        ch == a || ch == e || ch == i || ch == o || ch == u
    }

    /// Does `w` hold `text` starting at `at`?
    private static func has(_ w: [UInt8], _ at: Int, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard at >= 0, at + bytes.count <= w.count else { return false }
        return w[at..<(at + bytes.count)].elementsEqual(bytes)
    }

    private static func hasSuffix(_ w: [UInt8], _ text: String) -> Bool {
        has(w, w.count - text.utf8.count, text)
    }

    /// A word of lowercase ASCII letters, possibly with apostrophes.
    private static func wordSyllables(_ raw: [UInt8]) -> Int {
        var w = raw
        while w.first == apostrophe { w.removeFirst() }     // 'cause
        while w.last == apostrophe { w.removeLast() }       // lovin'
        guard !w.isEmpty else { return 0 }
        if let ap = w.lastIndex(of: apostrophe) {
            let base = Array(w[..<ap]).filter { $0 != apostrophe }
            let tail = Array(w[(ap + 1)...])
            return contraction(base: base, tail: tail)
        }
        if let known = irregular[w] { return known }
        return withSuffixes(w)
    }

    /// Common lyric words whose spelling misleads every rule above (a silent
    /// middle vowel, or a sung final e). Deliberately tiny: typed markup
    /// corrects any miscount, and this is not a dictionary.
    private static let irregular: [[UInt8]: Int] = [
        "maybe": 2, "evening": 2, "evenings": 2, "business": 2, "businesses": 3,
        "chocolate": 2, "chocolates": 2,
    ].reduce(into: [:]) { $0[Array($1.key.utf8)] = $1.value }

    /// `base'tail`: n't, 's, 'll, 'd, 've, 're, 'm.
    private static func contraction(base: [UInt8], tail: [UInt8]) -> Int {
        guard !base.isEmpty else { return withSuffixes(tail) }
        let tailString = String(decoding: tail, as: UTF8.self)
        if tailString == "t", base.last == n {
            // didn't, couldn't, isn't, haven't: a consonant sound before the
            // n't makes it a syllable. don't, can't, won't, ain't: no.
            let stem = Array(base.dropLast())
            guard !stem.isEmpty else { return 1 }
            let stemCount = max(1, withSuffixes(stem))
            let last = stem[stem.count - 1]
            let consonantSound = (!isAEIOU(last) && last != y)
                || (last == e && stem.count >= 2 && !isAEIOU(stem[stem.count - 2]) && stem != Array("were".utf8))
            return stemCount + (consonantSound ? 1 : 0)
        }
        let baseCount = max(1, withSuffixes(base))
        let last = base[base.count - 1]
        switch tailString {
        case "s":
            // boss's, judge's: a sibilant before 's adds a syllable.
            let sibilant = last == s || last == z || last == x
                || ["ch", "sh", "ce", "ge", "se", "ze"].contains { hasSuffix(base, $0) }
            return baseCount + (sibilant ? 1 : 0)
        case "m":
            return baseCount                                                // I'm
        case "ll", "d", "ve", "re":
            // it'll, that'd, could've: a consonant before adds a weak syllable.
            return baseCount + ((!isAEIOU(last) && last != y) ? 1 : 0)
        default:
            return baseCount + withSuffixes(tail)
        }
    }

    // MARK: Suffixes and compounds with a silent e before them

    /// Consonant-initial endings after which a stem's final e stays silent
    /// (hope|ful, late|ness, home|ward, note|book, some|times), with each
    /// ending's own syllable count. The stem is counted on its own, so its
    /// silent-e rule applies, and the ending adds its fixed count.
    ///
    /// Two groups: English derivational suffixes, then the commonest second
    /// halves of compound words. Neither list is a dictionary of words; each
    /// entry only ever SPLITS a word whose first part ends in e.
    private static let silentEEndings: [([UInt8], Int)] = [
        ("ly", 1), ("ful", 1), ("fully", 2), ("fulness", 2), ("less", 1), ("lessly", 2), ("lessness", 2),
        ("ness", 1), ("nesses", 2), ("ment", 1), ("ments", 1), ("some", 1), ("wise", 1), ("ward", 1),
        ("wards", 1), ("ty", 1), ("liness", 2), ("lier", 2), ("liest", 2), ("lihood", 2), ("hood", 1),
        ("let", 1), ("lets", 1),
        ("work", 1), ("works", 1), ("worker", 2), ("workers", 2), ("ware", 1), ("wares", 1), ("man", 1),
        ("men", 1), ("woman", 2), ("women", 2), ("book", 1), ("books", 1), ("stone", 1), ("stones", 1),
        ("head", 1), ("heads", 1), ("hand", 1), ("hands", 1), ("land", 1), ("lands", 1), ("line", 1),
        ("lines", 1), ("side", 1), ("sides", 1), ("time", 1), ("times", 1), ("way", 1), ("ways", 1),
        ("where", 1), ("how", 1), ("body", 2), ("thing", 1), ("things", 1), ("one", 1), ("yard", 1), ("yards", 1),
        ("wood", 1), ("woods", 1), ("room", 1), ("rooms", 1), ("house", 1), ("houses", 2), ("light", 1),
        ("lights", 1), ("fish", 1), ("field", 1), ("fields", 1), ("board", 1), ("boards", 1), ("boat", 1),
        ("boats", 1), ("ship", 1), ("ships", 1), ("shop", 1), ("shops", 1), ("town", 1), ("towns", 1),
        ("tail", 1), ("tails", 1), ("sale", 1), ("sales", 1), ("wear", 1), ("brow", 1), ("brows", 1),
        ("sore", 1), ("stack", 1), ("stacks", 1), ("craft", 1), ("crafts", 1), ("cat", 1), ("cats", 1),
        ("print", 1), ("prints", 1), ("place", 1), ("places", 2), ("life", 1), ("like", 1), ("hold", 1),
        ("holds", 1), ("holder", 2), ("holders", 2), ("keeper", 2), ("keepers", 2), ("maker", 2),
        ("makers", 2), ("writer", 2), ("writers", 2), ("cutter", 2), ("cutters", 2), ("mark", 1),
        ("marks", 1), ("mate", 1), ("mates", 1), ("piece", 1), ("pieces", 2), ("point", 1), ("points", 1),
        ("post", 1), ("posts", 1), ("road", 1), ("roads", 1), ("shot", 1), ("shots", 1), ("show", 1),
        ("shows", 1), ("stand", 1), ("stands", 1), ("step", 1), ("steps", 1), ("store", 1), ("stores", 1),
        ("table", 2), ("tables", 2), ("tree", 1), ("trees", 1), ("wall", 1), ("walls", 1), ("wind", 1),
        ("wing", 1), ("wings", 1), ("word", 1), ("words", 1), ("wash", 1), ("washed", 1), ("walk", 1),
        ("walks", 1), ("ball", 1), ("balls", 1), ("bird", 1), ("birds", 1), ("cake", 1), ("cakes", 1),
        ("door", 1), ("doors", 1), ("fall", 1), ("falls", 1), ("ground", 1), ("grounds", 1), ("hole", 1),
        ("holes", 1), ("lock", 1), ("locks", 1), ("path", 1), ("paths", 1), ("rail", 1), ("rails", 1),
        ("rock", 1), ("rocks", 1), ("song", 1), ("songs", 1), ("wheel", 1), ("wheels", 1), ("worm", 1),
        ("worms", 1), ("finger", 2), ("fingers", 2), ("stead", 1), ("person", 2), ("people", 2),
    ].map { (Array($0.0.utf8), $0.1) }

    private static func withSuffixes(_ w: [UInt8]) -> Int {
        for (ending, syllables) in silentEEndings
        where w.count >= ending.count + 3 && w.suffix(ending.count).elementsEqual(ending) {
            let stem = Array(w.dropLast(ending.count))
            if stemEndsInE(stem) {
                return max(1, withSuffixes(stem)) + syllables
            }
        }
        return core(w)
    }

    /// home, whole, hedge, eye, unique, blue, agree, spokes: a stem that ends
    /// in e (or the e of a silent -es). After a consonant the e must have a
    /// vowel before it (so a lone "the" is never a stem); after a vowel it is
    /// part of that vowel (blue, agree), and the stem always counts.
    private static func stemEndsInE(_ stem: [UInt8]) -> Bool {
        var k = stem.count - 1
        if stem[k] == s, k >= 1, stem[k - 1] == e { k -= 1 }         // spokes|man
        guard stem[k] == e, k >= 1 else { return false }
        let before = stem[k - 1]
        if before == u || before == e || before == o { return true }  // blue, agree, unique, shoe
        if isAEIOU(before) { return false }                           // socie|ty is not a stem
        return stem[..<(k - 1)].contains(where: { isAEIOU($0) || $0 == y })
    }

    // MARK: The core count

    /// Is `w[k]` a vowel? a/e/i/o/u always. `y` is a consonant at the start
    /// of a word and between two vowels (yes, player, beyond); anywhere else
    /// it is a vowel (happy, they, flying, canyon).
    private static func vowelFlags(_ w: [UInt8]) -> [Bool] {
        let len = w.count
        var isV = [Bool](repeating: false, count: len)
        for k in 0..<len {
            if isAEIOU(w[k]) {
                isV[k] = true
            } else if w[k] == y {
                let betweenVowels = k > 0 && isAEIOU(w[k - 1]) && k + 1 < len && isAEIOU(w[k + 1])
                isV[k] = k > 0 && !betweenVowels
            }
        }
        return isV
    }

    /// Vowel groups plus the English spelling rules, on lowercase letters only.
    private static func core(_ w: [UInt8]) -> Int {
        let len = w.count
        guard len > 0 else { return 0 }
        let isV = vowelFlags(w)

        var count = 0
        var k = 0
        while k < len {
            if isV[k] {
                count += 1
                var j = k + 1
                while j < len && isV[j] {
                    if splitsHiatus(w, j) { count += 1 }
                    j += 1
                }
                k = j
            } else {
                k += 1
            }
        }
        guard count > 0 else { return spelledLetters(w) }

        count += prefixAdjustment(w)
        count += endingAdjustment(w, isV: isV, count: count)
        return max(1, count)
    }

    /// True when `w[j-1]` and `w[j]`, two adjacent vowel letters, belong to
    /// different syllables.
    private static func splitsHiatus(_ w: [UInt8], _ j: Int) -> Bool {
        let len = w.count
        let prev = w[j - 1], cur = w[j]
        let before: UInt8? = j >= 2 ? w[j - 2] : nil
        let after: UInt8? = j + 1 < len ? w[j + 1] : nil
        let rest = j + 1
        let atEnd = rest == len
        func restIs(_ text: String) -> Bool { rest + text.utf8.count == len && has(w, rest, text) }
        func restStarts(_ text: String) -> Bool { has(w, rest, text) }
        let earlierVowel = w[..<(j - 1)].contains(where: isAEIOU)
        /// A single consonant after an earlier vowel: u|n|ion, be|h|av|ior.
        let singleConsonantAfterVowel = j >= 3 && isAEIOU(w[j - 3])

        // being, going, seeing, flying: the i of a final -ing after a vowel.
        if cur == i, restIs("ng") || restIs("ngs") { return true }
        // zoology, sociology, embryology: -log- after a vowel starts a syllable.
        if restStarts("log") { return true }
        // atheist, egoism, jingoism, enthusiast: -ist/-ism after a vowel.
        if earlierVowel, (cur == i && (restStarts("st") || restStarts("sm"))) || (cur == a && restStarts("st")) {
            return true
        }

        switch (prev, cur) {
        case (i, a), (i, o), (i, u):
            if let b = before, b == c || b == t || b == s || b == x || b == g
                || (b == h && j >= 3 && (w[j - 3] == s || w[j - 3] == c)) {
                // After c/t/s/x/g/sh the i softens the consonant (nation,
                // special, region, anxious, fashion, sociable) unless the vowel
                // starts a syllable of its own (appreciate, axiom, speciality).
                if b == g && j == 2 { return true }                              // giant
                guard let a2 = after else { return false }                        // militia, Asia
                if a2 == l, restStarts("lit") { return true }                     // speciality
                if a2 == n || a2 == l || a2 == s || a2 == b { return false }     // nation, special, sociable
                if cur == o && a2 == u { return false }                           // -cious, -gious
                return true
            }
            if let b = before, b == l, j >= 3, w[j - 3] == l { return false }   // million, brilliant
            // A y-glide after one consonant: union, opinion, battalion,
            // behavior, junior, familiar, civilian.
            if let b = before, singleConsonantAfterVowel {
                if cur == o, b == n || b == l, restIs("n") || restIs("ns") { return false }
                if cur == o, b == n || b == v, restIs("r") || restIs("rs") { return false }
                if cur == a, b == l, restIs("n") || restIs("ns") || restIs("r") || restIs("rs") { return false }
            }
            return true
        case (i, e):
            // happier, happiest, quiet, society, client, science: split.
            // piece, field, tie, friend, patient: one vowel.
            if atEnd { return false }
            if restIs("r") || restIs("rs") {
                // pier, tier: a one-vowel word with a one-consonant onset is
                // one syllable; flier, crier (two consonants) are two.
                if !earlierVowel && j <= 2 { return false }
                return true
            }
            if restIs("st") { return earlierVowel }                                 // happiest; priest
            if after == t { return true }
            if after == n, rest + 1 < len, w[rest + 1] == t || w[rest + 1] == c {
                if j == 3, has(w, 0, "sci") { return true }                          // science
                if let b = before, b == c || b == t || b == s || b == x { return false }   // patient
                return true
            }
            return false
        case (e, o):
            // video, theory, geology: split. gorgeous, pigeon, people: one.
            if let b = before, b == g || b == c, after == u || after == n { return false }
            if after == p, j == 2, let b = before, b == p || b == l || b == 0x6A { return false } // people, leopard, jeopardy
            if let b = before, b == g, j == 2, after == r { return false }
            return true
        case (e, a):
            // idea, area (a final -ea after another vowel); create, creation,
            // creative, creator; malleable, agreeable. Not treat, defeated,
            // eater: those are one vowel.
            if atEnd { return earlierVowel }
            if before == e { return true }
            if j >= 3, w[j - 2] == r, w[j - 3] == c, restStarts("t"), !restStarts("tur") { return true } // create
            if restIs("te") || restIs("tes") || restStarts("tion") || restStarts("tiv") || restStarts("tor") {
                return true
            }
            if restStarts("b"), let b = before, b != c && b != g { return true }
            return false
        case (e, u):
            // museum, nucleus: split before a final m or s.
            return restIs("m") || restIs("s") || restIs("ms")
        case (e, i):
            // deity: split before -ty.
            return restStarts("ty")
        case (o, a):
            // radioactive, retroactive.
            return restStarts("ct")
        case (u, a), (u, e), (u, i), (u, o):
            // actual, cruel, fluid, duo, ambiguity: split after a consonant.
            // After q or g the u is a glide (equal, guess, guide). A final
            // -ue/-ues/-ued is one vowel (blue, values, argued); fruit, suit,
            // juice, build too.
            guard let b = before, !isAEIOU(b) else { return false }
            if b == q || b == g { return false }
            if cur == e, atEnd || restIs("s") || restIs("d") { return false }
            if cur == i, let a2 = after, a2 == t || a2 == c || a2 == l || a2 == s {
                return a2 == t && (restIs("ty") || restStarts("ties") || restStarts("tous"))
            }
            return true
        case (o, e):
            // poem, poet, goers: split before m, t or r (not a final -oes).
            if atEnd || restIs("s") || restIs("d") { return false }
            return after == m || after == t || after == r
        case (y, i):
            // bullying, worrying: a vowel y before an i.
            return true
        case (a, o):
            // chaos, chaotic.
            return before == h
        case (y, o):
            // anyone, everyone: -y|one. Not canyon.
            return restIs("ne")
        case (y, e):
            // flyer, dryer: a vowel y before a final -er. Not lawyer.
            if let b = before, b != letterW, restIs("r") || restIs("rs") { return true }
            return false
        default:
            return false
        }
    }

    /// re-, pre-, de-, co- before a vowel: reunion, reinforce, react. (A re-
    /// or pre- before o needs no rule: the eo split already counts it.)
    private static func prefixAdjustment(_ w: [UInt8]) -> Int {
        let len = w.count
        if len >= 5, has(w, 0, "re"), isAEIOU(w[2]) {
            switch w[2] {
            case u:
                return 1
            case i:
                if has(w, 3, "t") || has(w, 3, "m") { return 1 }
                if has(w, 3, "n"), len > 4, Array("fstvcj".utf8).contains(w[4]) { return 1 }
                return 0
            case a:
                let splitters = ["ct", "ff", "ss", "pp", "rr", "dj", "dm", "cq", "lig", "lit", "lis", "nal", "wak", "uth", "rm"]
                return splitters.contains { has(w, 3, $0) } ? 1 : 0
            default:
                return 0
            }
        }
        // everything, everybody, everyone: "every" is sung "ev-ry" inside a compound.
        if len > 5, has(w, 0, "every") { return -1 }
        if len >= 6, has(w, 0, "pre"), w[3] == e { return 1 }
        if len >= 6, has(w, 0, "dea"), has(w, 3, "ct") { return 1 }
        if len >= 5, has(w, 0, "coe") { return 1 }
        return 0
    }

    /// The word-final spelling rules: silent e, -ed, -es, syllabic -le,
    /// -gue/-que, -sm/-thm, -ically.
    private static func endingAdjustment(_ w: [UInt8], isV: [Bool], count: Int) -> Int {
        let len = w.count
        guard len >= 3 else { return 0 }
        func consonantAt(_ k: Int) -> Bool { k >= 0 && k < len && !isV[k] }
        var adjust = 0

        // chasm, realism, rhythm (+s): a final -sm/-thm after a vowel is a syllable.
        var end = len
        if w[end - 1] == s && w[end - 2] == m { end -= 1 }
        if end >= 3 && w[end - 1] == m {
            if w[end - 2] == s, isV[end - 3] { adjust += 1 }
            else if end >= 4, w[end - 2] == h, w[end - 3] == t, isV[end - 4] { adjust += 1 }
        }
        // -ically: the a is silent (basically, drastically).
        if hasSuffix(w, "ically") { adjust -= 1 }

        guard count > 1 else { return adjust }

        // vogue, plagued, fatiguing, unique, critiquing: the u(e) after a
        // final -gu/-qu is silent. After r it is sung: argue, argued, arguing.
        for tail in ["gue", "gues", "gued", "guing", "que", "ques", "qued", "quing"] where hasSuffix(w, tail) {
            let g = len - tail.utf8.count
            if w[g] == q || (g >= 1 && (isAEIOU(w[g - 1]) || w[g - 1] == n)) { return adjust - 1 }
        }
        // Final lone e after a consonant: silent (make, time), except the
        // syllabic -le/-re after another consonant (little, acre).
        if w[len - 1] == e && consonantAt(len - 2) {
            if (w[len - 2] == l || w[len - 2] == r) && consonantAt(len - 3) && w[len - 3] != l && w[len - 3] != r
                && w[len - 3] != letterW {
                return adjust
            }
            return adjust - 1
        }
        // Final -ed: silent after anything but t and d (walked, loved; wanted).
        if w[len - 2] == e && w[len - 1] == d && consonantAt(len - 3) {
            let ch = w[len - 3]
            if ch == t || ch == d { return adjust }
            if ch == l && consonantAt(len - 4) && w[len - 4] != l && w[len - 4] != r && w[len - 4] != letterW {
                return adjust                                                       // tabled; not crawled
            }
            return adjust - 1
        }
        // Final -es: silent unless the e makes a syllable after a sibilant
        // (roses, boxes, wishes, places, changes) or a syllabic l (tables).
        if w[len - 2] == e && w[len - 1] == s && consonantAt(len - 3) {
            let ch = w[len - 3]
            if ch == s || ch == z || ch == x || ch == c || ch == g { return adjust }
            if ch == h && len >= 4 && (w[len - 4] == c || w[len - 4] == s) { return adjust }
            if (ch == l || ch == r) && consonantAt(len - 4) && w[len - 4] != l && w[len - 4] != r
                && w[len - 4] != letterW {
                return adjust
            }
            return adjust - 1
        }
        return adjust
    }

    /// A vowel-less run. A hum or a hush (hmm, mmm, shh, psst, brr: a
    /// doubled letter, or only h/m/s) is one syllable; anything else is read
    /// letter by letter ("tv", "dj"), and w is "double-u".
    private static func spelledLetters(_ w: [UInt8]) -> Int {
        let doubled = zip(w, w.dropFirst()).contains { $0 == $1 }
        if doubled || w.allSatisfy({ $0 == h || $0 == m || $0 == s }) { return 1 }
        return w.reduce(0) { $0 + ($1 == letterW ? 3 : 1) }
    }
}

/// Numbers, counted in the syllables the singing facade actually SINGS for
/// them. The facade (`scripts/sing/singlib/phonemes.py`) expands a word with
/// g2p_en's own `normalize_numbers`, turns hyphens into spaces, and sings the
/// whole expansion across the word's notes. That expansion reads:
///
/// - cardinals without "and" ("one hundred one"), and 1001-2999 as years
///   ("nineteen oh five", "two thousand five", "twenty ten");
/// - ordinals through inflect, which is NEVER the year reading and DOES say
///   "and" ("1999th" is "one thousand, nine hundred and ninety-ninth");
/// - a decimal point as "point", each side its own number ("10.01" is
///   "ten point one");
/// - a plural "s" as part of the last word ("1900s" is "nineteen hundreds").
///
/// `Tests/DAWCoreTests/Fixtures/EnglishSyllables/g2p-en-numbers.tsv` holds
/// g2p_en's REAL output for every shape above, and `EnglishSyllablesTests`
/// checks this type against it row by row. Mixed tokens like "4ever" or "b4"
/// reach g2p_en's neural guesser, so no table can pin them.
fileprivate enum SpokenNumbers {
    private static let ones = [2, 1, 1, 1, 1, 1, 1, 2, 1, 1]            // zero..nine
    private static let teens = [1, 3, 1, 2, 2, 2, 2, 3, 2, 2]           // ten..nineteen
    private static let tens = [0, 0, 2, 2, 2, 2, 2, 3, 2, 2]            // -, -, twenty..ninety

    /// Syllables of a run of ASCII digits read as a cardinal number.
    static func syllables(digits: [UInt8]) -> Int {
        guard !digits.isEmpty else { return 0 }
        let trimmed = digits.drop { $0 == 0x30 }
        if trimmed.isEmpty { return ones[0] }
        guard trimmed.count <= 15, let value = UInt64(String(decoding: trimmed, as: UTF8.self)) else {
            return digits.reduce(0) { $0 + ones[Int($1 - 0x30)] }
        }
        if value > 1000 && value < 3000 { return year(value) }
        return cardinal(value)
    }

    /// "1st", "22nd", "101st": inflect's ordinal, which is the cardinal
    /// (never the year reading), plus "and" before a last part under a
    /// hundred, plus one for "second" and for "-ieth".
    static func ordinalSyllables(digits: [UInt8]) -> Int {
        let trimmed = digits.drop { $0 == 0x30 }
        guard !trimmed.isEmpty, trimmed.count <= 15,
              let value = UInt64(String(decoding: trimmed, as: UTF8.self)) else {
            return syllables(digits: digits)                                   // "0th": zeroth
        }
        var total = cardinal(value)
        if value >= 100, value % 100 != 0 { total += 1 }                      // "one hundred AND first"
        if value % 10 == 2, value % 100 != 12 { total += 1 }                  // "second" for "two"
        if value % 100 >= 20, value % 10 == 0 { total += 1 }                  // "twentieth"
        return total
    }

    /// 1001-2999 read as a year: "nineteen ninety-nine", "two thousand five".
    private static func year(_ v: UInt64) -> Int {
        if v == 2000 { return 1 + 2 }
        if v > 2000 && v < 2010 { return 1 + 2 + cardinal(v % 100) }
        if v % 100 == 0 { return cardinal(v / 100) + 2 }
        let hi = v / 100, lo = v % 100
        return cardinal(hi) + (lo < 10 ? 1 + cardinal(lo) : cardinal(lo))   // "oh five"
    }

    static func cardinal(_ v: UInt64) -> Int {
        if v < 10 { return ones[Int(v)] }
        if v < 20 { return teens[Int(v - 10)] }
        if v < 100 { return tens[Int(v / 10)] + (v % 10 == 0 ? 0 : ones[Int(v % 10)]) }
        if v < 1000 { return ones[Int(v / 100)] + 2 + (v % 100 == 0 ? 0 : cardinal(v % 100)) }
        let scales: [(UInt64, Int)] = [(1_000_000_000_000, 2), (1_000_000_000, 2), (1_000_000, 2), (1_000, 2)]
        for (scale, word) in scales where v >= scale {
            return cardinal(v / scale) + word + (v % scale == 0 ? 0 : cardinal(v % scale))
        }
        return 0
    }
}
