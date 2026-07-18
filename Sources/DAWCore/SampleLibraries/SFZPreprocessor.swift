import Foundation

/// SFZ preprocessor aborts (m19-c, design §5.4). Every case is a structured,
/// LocalizedError-readable refusal naming the exact file/variable/cycle — a
/// partially macro-expanded file produces garbage zone data, so refusing
/// loudly always beats importing noise (§2.3: never a silent zero-region
/// import).
public enum SFZPreprocessorError: Error, LocalizedError, Equatable {
    /// The file exists but could not be read as text.
    case unreadableFile(path: String)
    /// An `#include` line without a quoted path.
    case malformedInclude(line: String, file: String)
    /// An `#include` whose target does not exist. Carries the raw include
    /// path AND the file that asked for it (main-file-relative resolution
    /// makes "which file wanted this" the actionable fact).
    case includeMissing(path: String, file: String)
    /// Include nesting exceeded `SFZPreprocessor.maxIncludeDepth`.
    case includeDepthExceeded(path: String, depth: Int)
    /// More than `SFZPreprocessor.maxIncludedFiles` total `#include`s.
    case includeCountExceeded(limit: Int)
    /// A file (canonical paths) included itself, directly or indirectly.
    /// Carries the full stack, outermost first, offender last.
    case includeCycle([String])
    /// A `#define` without a `$name` + value pair.
    case malformedDefine(line: String, file: String)
    /// A `$VAR` used (or referenced by a later `#define` value) with no
    /// definition in effect at that point.
    case undefinedVariable(name: String, file: String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let path):
            return "cannot read SFZ text at \(path)"
        case .malformedInclude(let line, let file):
            return "malformed #include (expected #include \"path\") in \(file): \(line)"
        case .includeMissing(let path, let file):
            return "#include \"\(path)\" not found (resolved relative to the main .sfz file's folder) — required by \(file)"
        case .includeDepthExceeded(let path, let depth):
            return "#include nesting exceeds the depth limit (\(depth)) at \(path) — refusing (likely a runaway include chain)"
        case .includeCountExceeded(let limit):
            return "more than \(limit) #include'd files — refusing (likely a runaway include chain)"
        case .includeCycle(let stack):
            return "#include cycle: \(stack.joined(separator: " → "))"
        case .malformedDefine(let line, let file):
            return "malformed #define (expected #define $NAME value) in \(file): \(line)"
        case .undefinedVariable(let name, let file):
            return "undefined SFZ macro \(name) used in \(file) — every $VAR must be #define'd before use"
        }
    }
}

/// The SFZ preprocessor (m19-c, design §5.1/§5.4 — amendment A1 made this a
/// MUST: the flagship Salamander piano's canonical .sfz holds ZERO region
/// opcodes, only `#include`/`#define` scaffolding).
///
/// Two directives, run BEFORE any opcode is parsed:
///  · `#include "relpath"` — resolved relative to the MAIN .sfz file's folder
///    (the ARIA rule, RES §1.5 — NOT the including file's folder). Depth cap
///    16, ≤256 files total, canonical-path cycle detection.
///  · `#define $VAR value` — a `$`-prefixed TEXTUAL substitution applied to
///    every subsequent line (longest-name-first so `$ABC` wins over `$AB`;
///    last definition wins). Any `$IDENT` left after substitution aborts.
///
/// Import-time allocation is fine throughout — nothing here ever touches the
/// render thread (the SoundFontPresetReader headless precedent).
public enum SFZPreprocessor {
    /// Maximum `#include` nesting depth (the main file is depth 0).
    public static let maxIncludeDepth = 16
    /// Maximum total number of `#include`d files per import.
    public static let maxIncludedFiles = 256

    /// Reads and fully expands the main .sfz file: comments stripped, CRLF
    /// normalized, `#include`s inlined, `$VAR`s substituted. The returned
    /// text is ready for `SFZParser.parse`.
    public static func preprocess(fileAt url: URL) throws -> String {
        var state = State(mainDirectory: url.deletingLastPathComponent())
        return try expand(fileAt: url, depth: 0, state: &state)
    }

    // MARK: - Implementation

    private struct State {
        let mainDirectory: URL
        /// `$NAME` (with the `$`) → replacement text. Last definition wins.
        var defines: [String: String] = [:]
        var includedFileCount = 0
        /// Canonical paths currently being expanded (cycle detection).
        var stack: [String] = []
    }

    private static func expand(fileAt url: URL, depth: Int,
                               state: inout State) throws -> String {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        if state.stack.contains(canonical) {
            throw SFZPreprocessorError.includeCycle(state.stack + [canonical])
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw SFZPreprocessorError.unreadableFile(path: url.path)
        }
        // UTF-8 first; Latin-1 fallback (never fails) for legacy-encoded
        // libraries — tolerant-but-honest beats refusing a readable file.
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        state.stack.append(canonical)
        defer { state.stack.removeLast() }

        // Comments are stripped BEFORE directive scanning so a commented-out
        // `// #include "x"` never fires (block comments keep their newlines,
        // preserving the line structure directives depend on).
        let text = SFZSyntax.stripComments(from: raw)
        var output = String()
        output.reserveCapacity(text.count)
        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(lineSub)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#include") {
                let includePath = try parseIncludePath(trimmed, file: url.path)
                guard depth + 1 <= maxIncludeDepth else {
                    throw SFZPreprocessorError.includeDepthExceeded(
                        path: includePath, depth: maxIncludeDepth)
                }
                state.includedFileCount += 1
                guard state.includedFileCount <= maxIncludedFiles else {
                    throw SFZPreprocessorError.includeCountExceeded(limit: maxIncludedFiles)
                }
                // Main-file-relative (RES §1.5), separators normalized so a
                // Windows-authored `#include "Data\file.txt"` resolves.
                let relative = includePath.replacingOccurrences(of: "\\", with: "/")
                let target = URL(fileURLWithPath: relative,
                                 relativeTo: state.mainDirectory).standardizedFileURL
                guard FileManager.default.fileExists(atPath: target.path) else {
                    throw SFZPreprocessorError.includeMissing(
                        path: includePath, file: url.path)
                }
                output += try expand(fileAt: target, depth: depth + 1, state: &state)
                output += "\n"
            } else if trimmed.hasPrefix("#define") {
                try parseDefine(trimmed, file: url.path, state: &state)
            } else {
                output += try substitute(line, file: url.path, defines: state.defines)
                output += "\n"
            }
        }
        return output
    }

    /// `#include "path"` → the quoted path. Anything else aborts.
    private static func parseIncludePath(_ line: String, file: String) throws -> String {
        guard let open = line.firstIndex(of: "\""),
              let close = line[line.index(after: open)...].firstIndex(of: "\""),
              close > open else {
            throw SFZPreprocessorError.malformedInclude(line: line, file: file)
        }
        let path = String(line[line.index(after: open)..<close])
        guard !path.isEmpty else {
            throw SFZPreprocessorError.malformedInclude(line: line, file: file)
        }
        return path
    }

    /// `#define $NAME value` → stores the macro. The value is the first
    /// whitespace-delimited token after the name (the ARIA convention — no
    /// spaces in define values), expanded against the macros already in
    /// effect so chained defines resolve deterministically at definition
    /// time. Last definition wins.
    private static func parseDefine(_ line: String, file: String,
                                    state: inout State) throws {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            .flatMap { $0.split(separator: "\t", omittingEmptySubsequences: true) }
        // parts[0] == "#define"
        guard parts.count >= 3,
              parts[1].hasPrefix("$"), parts[1].count > 1 else {
            throw SFZPreprocessorError.malformedDefine(line: line, file: file)
        }
        let name = String(parts[1])
        let value = try substitute(String(parts[2]), file: file, defines: state.defines)
        state.defines[name] = value
    }

    /// Applies every macro (longest-name-first), then aborts on any `$IDENT`
    /// still standing — the §2.3 undefined-variable refusal.
    private static func substitute(_ line: String, file: String,
                                   defines: [String: String]) throws -> String {
        guard line.contains("$") else { return line }
        var result = line
        // Longest-first so `$ABC` is never half-eaten by a shorter `$AB`;
        // ties broken by name for determinism.
        for name in defines.keys.sorted(by: {
            $0.count != $1.count ? $0.count > $1.count : $0 < $1
        }) {
            if let value = defines[name] {
                result = result.replacingOccurrences(of: name, with: value)
            }
        }
        if let leftover = firstMacroReference(in: result) {
            throw SFZPreprocessorError.undefinedVariable(name: leftover, file: file)
        }
        return result
    }

    /// The first `$IDENT` (identifier: letters/digits/underscore) in `text`,
    /// or nil. A bare `$` with no identifier after it is tolerated (it can
    /// legitimately appear in a file name).
    private static func firstMacroReference(in text: String) -> String? {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if chars[i] == "$" {
                var j = i + 1
                while j < chars.count,
                      chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    j += 1
                }
                if j > i + 1 { return String(chars[i..<j]) }
            }
            i += 1
        }
        return nil
    }
}
