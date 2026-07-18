import Foundation

/// Shared SFZ text-level syntax helpers (comments, note names, numbers) —
/// used by both `SFZPreprocessor` (comment stripping must run before
/// directive scanning) and `SFZParser` (which also strips defensively so it
/// can be driven directly in tests without the preprocessor).
enum SFZSyntax {
    /// Normalizes CRLF/CR to LF and strips `//` line comments and `/* */`
    /// block comments. Block comments keep their newlines so the line
    /// structure (which `#include`/`#define` scanning depends on) survives.
    static func stripComments(from text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var output = String()
        output.reserveCapacity(normalized.count)
        let chars = Array(normalized)
        var i = 0
        var inLine = false
        var inBlock = false
        while i < chars.count {
            let c = chars[i]
            if inLine {
                if c == "\n" { inLine = false; output.append("\n") }
            } else if inBlock {
                if c == "\n" { output.append("\n") }
                if c == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                    inBlock = false
                    i += 1
                }
            } else if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                inLine = true
                i += 1
            } else if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                inBlock = true
                i += 1
            } else {
                output.append(c)
            }
            i += 1
        }
        return output
    }

    /// Parses a pitch value: a plain MIDI integer, or a note name
    /// (`c4`, `a#3`, `db2`, `c-1` … `g9`, case-insensitive; C-1 = 0, so the
    /// full name range spans exactly MIDI 0…127). nil = unparseable.
    static func midiPitch(from raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = Int(s) { return n }
        let semitones: [Character: Int] = ["c": 0, "d": 2, "e": 4, "f": 5,
                                           "g": 7, "a": 9, "b": 11]
        guard let letter = s.first, let semi = semitones[letter] else { return nil }
        var rest = s.dropFirst()
        var accidental = 0
        // `b3` is the note B3 (the letter consumed the b); `bb3`/`db4` carry
        // a flat, `a#3` a sharp — the accidental char is only read AFTER the
        // letter, so the ambiguity resolves itself.
        if let mark = rest.first {
            if mark == "#" { accidental = 1; rest = rest.dropFirst() }
            else if mark == "b" { accidental = -1; rest = rest.dropFirst() }
        }
        guard let octave = Int(rest) else { return nil }
        let midi = (octave + 1) * 12 + semi + accidental
        return (0...127).contains(midi) ? midi : nil
    }

    /// Parses a numeric value, optionally tolerating a `dB`/`db` suffix
    /// (the `volume` wart — SFZ volume is dB-valued and some authors write
    /// the unit out).
    static func number(from raw: String, allowDBSuffix: Bool = false) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if allowDBSuffix, s.lowercased().hasSuffix("db") {
            s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        return Double(s)
    }

    /// Parses an integer value (tolerating a float spelling like `4.0`).
    static func integer(from raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Int(s) { return n }
        if let d = Double(s), d == d.rounded() { return Int(d) }
        return nil
    }
}

/// The SFZ tokenizer + header-inheritance parser (m19-c, design §5.1).
/// Input is (normally preprocessed) SFZ text; output is the format-neutral
/// `SampleLibraryIR` that `SampleLibraryMapper` consumes. TOLERANT by
/// design: it never throws — malformed fragments are skipped, unknown
/// headers are counted, unparseable recognized values degrade to the
/// region's `ignored` list. All ABORTS live in the preprocessor (§5.4).
///
/// Tokenizer warts owned here, each with a first-class test (§7):
///  · `//` line and `/* */` block comments, CRLF line endings;
///  · `opcode=value` where `sample`/`default_path` values contain SPACES —
///    a value extends to the next `word=` token, `<header>`, or end of line
///    (the sfizz rule, applied to every opcode);
///  · note-name pitch values (`c4`, `a#3`, case-insensitive, C-1…G9);
///  · dB-suffixed `volume` values.
///
/// Inheritance: effective region opcodes = `<control>` → `<global>` →
/// `<master>` → `<group>` → `<region>` dictionary merge (RES §1.1), each
/// header RESETTING the scopes below it (`<global>` clears master+group,
/// `<master>` clears group). Opcodes before any header land in the global
/// scope (tolerance; real files always open with a header).
public enum SFZParser {
    /// Parses SFZ text into the IR. `baseDirectory` is the main file's
    /// folder — carried through so the mapper can resolve sample paths.
    public static func parse(text: String, baseDirectory: URL) -> SampleLibraryIR {
        var control: [String: String] = [:]
        var global: [String: String] = [:]
        var master: [String: String] = [:]
        var group: [String: String] = [:]
        var regionOpcodes: [String: String]?
        var groupOrdinal = -1
        var currentGroupIndex: Int?
        var regionGroupIndex: Int?
        var regions: [SampleLibraryIR.Region] = []
        var ignoredHeaders: [String: Int] = [:]

        enum Scope { case control, global, master, group, region, ignored }
        var scope: Scope = .global

        func finalizeRegion() {
            guard let opcodes = regionOpcodes else { return }
            // Later scopes override earlier ones — the §1.1 precedence chain.
            var merged = control
            merged.merge(global) { _, new in new }
            merged.merge(master) { _, new in new }
            merged.merge(group) { _, new in new }
            merged.merge(opcodes) { _, new in new }
            regions.append(makeRegion(from: merged, groupIndex: regionGroupIndex))
            regionOpcodes = nil
        }

        let stripped = SFZSyntax.stripComments(from: text)
        for line in stripped.split(separator: "\n", omittingEmptySubsequences: true) {
            for token in tokenize(line: line) {
                switch token {
                case .header(let name):
                    finalizeRegion()
                    switch name {
                    case "control":
                        control = [:]
                        scope = .control
                    case "global":
                        global = [:]; master = [:]; group = [:]
                        currentGroupIndex = nil
                        scope = .global
                    case "master":
                        master = [:]; group = [:]
                        currentGroupIndex = nil
                        scope = .master
                    case "group":
                        group = [:]
                        groupOrdinal += 1
                        currentGroupIndex = groupOrdinal
                        scope = .group
                    case "region":
                        regionOpcodes = [:]
                        regionGroupIndex = currentGroupIndex
                        scope = .region
                    default:
                        // <curve>, <effect>, <sample> (SFZ v2 embedded data),
                        // … — skipped wholesale but COUNTED (§2.3: surface
                        // degradation, never silently lie).
                        ignoredHeaders["<\(name)>", default: 0] += 1
                        scope = .ignored
                    }
                case .opcode(let name, let value):
                    switch scope {
                    case .control: control[name] = value
                    case .global: global[name] = value
                    case .master: master[name] = value
                    case .group: group[name] = value
                    case .region: regionOpcodes?[name] = value
                    case .ignored: break
                    }
                }
            }
        }
        finalizeRegion()
        return SampleLibraryIR(format: .sfz, baseDirectory: baseDirectory,
                               regions: regions, ignoredHeaders: ignoredHeaders)
    }

    // MARK: - Tokenizer

    enum Token: Equatable {
        case header(String)
        case opcode(name: String, value: String)
    }

    /// Tokenizes one line into headers + opcodes. The sfizz value rule: an
    /// opcode's value runs from after `=` to the next `word=` token, the
    /// next `<`, or end of line — so `sample=Kick 1.wav lokey=36` yields the
    /// full spaced path. Stray words that are neither are skipped.
    static func tokenize(line: Substring) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(line)
        let n = chars.count
        var i = 0

        func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" }

        while i < n {
            while i < n, isSpace(chars[i]) { i += 1 }
            guard i < n else { break }
            if chars[i] == "<" {
                guard let close = (i..<n).first(where: { chars[$0] == ">" }) else {
                    break  // malformed trailing header — tolerated, dropped
                }
                let name = String(chars[(i + 1)..<close])
                    .trimmingCharacters(in: .whitespaces).lowercased()
                tokens.append(.header(name))
                i = close + 1
                continue
            }
            // A word: opcode name candidate (up to '=', space, or '<').
            let wordStart = i
            while i < n, chars[i] != "=", chars[i] != "<", !isSpace(chars[i]) { i += 1 }
            guard i < n, chars[i] == "=" else {
                // Stray junk word — skip it (tolerant tokenizer).
                if i == wordStart { i += 1 }  // lone '<'-less char, ensure progress
                continue
            }
            let name = String(chars[wordStart..<i]).lowercased()
            i += 1  // past '='
            // Value: scan forward for the boundary.
            let valueStart = i
            var boundary = n
            var scan = i
            while scan < n {
                if chars[scan] == "<" { boundary = scan; break }
                if isSpace(chars[scan]) {
                    // Peek the next word: if it contains '=' before its own
                    // end (or is a header), the value stops HERE.
                    var w = scan
                    while w < n, isSpace(chars[w]) { w += 1 }
                    if w < n, chars[w] == "<" { boundary = scan; break }
                    var x = w
                    var wordIsOpcode = false
                    while x < n, !isSpace(chars[x]), chars[x] != "<" {
                        if chars[x] == "=" { wordIsOpcode = true; break }
                        x += 1
                    }
                    if wordIsOpcode { boundary = scan; break }
                    scan = x  // spaced word joins the value (the sfizz rule)
                } else {
                    scan += 1
                }
            }
            let value = String(chars[valueStart..<boundary])
                .trimmingCharacters(in: .whitespaces)
            tokens.append(.opcode(name: name, value: value))
            i = boundary
        }
        return tokens
    }

    // MARK: - Effective region → IR

    /// Opcodes consumed into typed IR fields; everything else lands in the
    /// region's `ignored` list for the mapper's tally.
    private static func makeRegion(from merged: [String: String],
                                   groupIndex: Int?) -> SampleLibraryIR.Region {
        var region = SampleLibraryIR.Region(groupIndex: groupIndex)
        var ignored: [String] = []

        /// Consumes `name` with `parse`; an unparseable value degrades to
        /// the ignored list (tolerant-but-reporting, §7 risk 3).
        func take<T>(_ name: String, _ parse: (String) -> T?,
                     into keyPath: WritableKeyPath<SampleLibraryIR.Region, T?>) {
            guard let raw = merged[name] else { return }
            if let value = parse(raw) {
                region[keyPath: keyPath] = value
            } else {
                ignored.append(name)
            }
        }

        region.samplePath = merged["sample"]
        region.defaultPath = merged["default_path"]

        // `key` shorthand: lokey = hikey = pitch_keycenter = key; explicit
        // opcodes override it (the merged dict has no textual order left, so
        // explicit-wins is the deterministic reading).
        if let raw = merged["key"] {
            if let key = SFZSyntax.midiPitch(from: raw) {
                region.loKey = key
                region.hiKey = key
                region.keyCenter = key
            } else {
                ignored.append("key")
            }
        }
        take("lokey", SFZSyntax.midiPitch, into: \.loKey)
        take("hikey", SFZSyntax.midiPitch, into: \.hiKey)
        take("pitch_keycenter", SFZSyntax.midiPitch, into: \.keyCenter)
        take("lovel", SFZSyntax.integer, into: \.loVel)
        take("hivel", SFZSyntax.integer, into: \.hiVel)
        take("seq_length", SFZSyntax.integer, into: \.seqLength)
        take("seq_position", SFZSyntax.integer, into: \.seqPosition)
        take("lorand", { SFZSyntax.number(from: $0) }, into: \.randLo)
        take("hirand", { SFZSyntax.number(from: $0) }, into: \.randHi)
        take("volume", { SFZSyntax.number(from: $0, allowDBSuffix: true) }, into: \.volumeDB)
        take("pan", { SFZSyntax.number(from: $0) }, into: \.pan)
        take("tune", { SFZSyntax.number(from: $0) }, into: \.tuneCents)
        take("transpose", SFZSyntax.integer, into: \.transposeSemitones)
        take("amp_veltrack", { SFZSyntax.number(from: $0) }, into: \.ampVelTrackPercent)
        take("offset", SFZSyntax.integer, into: \.offsetFrames)
        take("end", SFZSyntax.integer, into: \.endFrame)
        take("ampeg_attack", { SFZSyntax.number(from: $0) }, into: \.attackSeconds)
        take("ampeg_decay", { SFZSyntax.number(from: $0) }, into: \.decaySeconds)
        take("ampeg_sustain", { SFZSyntax.number(from: $0) }, into: \.sustainPercent)
        take("ampeg_release", { SFZSyntax.number(from: $0) }, into: \.releaseSeconds)
        take("sw_last", SFZSyntax.midiPitch, into: \.swLast)
        take("sw_default", SFZSyntax.midiPitch, into: \.swDefault)
        // `loopmode` is the documented SFZ v1 alias of `loop_mode`.
        if let mode = merged["loop_mode"] ?? merged["loopmode"] {
            region.loopMode = mode.lowercased()
        }
        // m20-g loop points: the v1 alias take runs FIRST so the canonical
        // underscore spelling overwrites when both appear (the same
        // canonical-wins order as the `loop_mode` ?? `loopmode` line above).
        take("loopstart", SFZSyntax.integer, into: \.loopStartFrame)   // v1 spelling
        take("loop_start", SFZSyntax.integer, into: \.loopStartFrame)
        take("loopend", SFZSyntax.integer, into: \.loopEndFrame)       // v1 spelling
        take("loop_end", SFZSyntax.integer, into: \.loopEndFrame)
        if let trigger = merged["trigger"] {
            region.trigger = trigger.lowercased()
        }

        let consumed: Set<String> = [
            "sample", "default_path", "key", "lokey", "hikey",
            "pitch_keycenter", "lovel", "hivel", "seq_length", "seq_position",
            "lorand", "hirand", "volume", "pan", "tune", "transpose",
            "amp_veltrack", "offset", "end", "ampeg_attack", "ampeg_decay",
            "ampeg_sustain", "ampeg_release", "sw_last", "sw_default",
            "loop_mode", "loopmode", "trigger",
            "loop_start", "loopstart", "loop_end", "loopend",
        ]
        for name in merged.keys where !consumed.contains(name) {
            // CC-triggered regions (`on_loccN`/`on_hiccN`) are a §2.3 SKIP
            // input, consumed by the mapper — not an "ignored" opcode.
            if name.hasPrefix("on_locc") || name.hasPrefix("on_hicc") {
                region.ccTriggered = true
            } else {
                ignored.append(name)
            }
        }
        region.ignored = ignored.sorted()
        return region
    }
}
