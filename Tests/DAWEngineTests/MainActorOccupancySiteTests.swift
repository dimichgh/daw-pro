import Foundation
import Testing

// m23-aw — THE MAIN-ACTOR OCCUPANCY SITE PIN.
//
// Design: docs/research/design-m23aw-headroom-tripwire.md §5.2/§6.2/§6.3/§7.2.
// Idiom: `RenderClockTrustSiteTests` verbatim — locate the repo root by
// walking up from `#filePath`, read source as text, strip comment lines,
// scan, print `[measured]`, assert against a written table. No bundle
// resources; runs headless under `./scripts/test.sh`.
//
// ══ THE RULE (design §1.7) — a deliberate main-actor hog is a construct that
// (a) occupies the main actor or blocks the main thread, (b) WITHOUT
// SUSPENDING — `Task.sleep` and every `await` are excluded, (c) for a FIXED
// NOMINAL WALL DURATION that is a constant in the source, (d) inside a
// `@MainActor` context (POSITIVE evidence required — the declaration itself,
// its enclosing type, or a lexically-enclosing `MainActor.run`/
// `MainActor.assumeIsolated` block), and (e) in a test that RUNS BY DEFAULT
// under `./scripts/test.sh` — no `.enabled(if:)`/`.disabled(…)`, directly or
// via the enclosing @Test/@Suite.
//
// Two recognized SHAPES: a clock-deadline busy spin (`let deadline =
// clock.now.advanced(by: DURATION); while clock.now < deadline { … }`, body
// containing no `await`) and a direct blocking sleep (`Thread.sleep
// (forTimeInterval:)` / `usleep(…)`).
//
// Duration resolution is TWO-HOP: if the duration expression is a local
// `let`/`var` binding, resolve it directly (hop 1). If it is instead a
// PARAMETER of the enclosing function (e.g. `spinHoldingMainActor(for
// duration: Duration, …)`), find that function's call site(s) elsewhere in
// the SAME FILE and resolve the argument passed at that label there (hop 2)
// — `DeadlineRaceTests` needs this hop; `AUPrepareInFlightWedgeTests` does
// not (its hog is inline in the same function that defines `hogDuration`).
// A construct that matches shapes (a)-(d) and clears clause (e) but whose
// duration CANNOT be resolved within two hops is NOT silently dropped — see
// `unresolvedMainActorCandidates` and the `#expect` in Leg A that consumes
// it. A bound that silently drops what it cannot parse is not a bound.
//
// ⚠️ KNOWN SCOPE LIMIT, stated rather than hidden (mirrors design §10 point
// 5): this scanner recognizes clock-deadline spins and `Thread.sleep`/
// `usleep`, not `DispatchQueue.main.sync`/`.wait()`/`waitUntilExit()` (the
// design's own audit found zero qualifying sites among those shapes today,
// and a `.wait()`/`waitUntilExit()` block's duration is a child process's,
// not a source constant — clause (c), not an oversight). Widening the
// recognized SLEEP VOCABULARY is future work, NOT m23-aw-3 — m23-aw-3 fixed a
// different gap: clause (d)'s enclosing-type walk was blind to `extension`
// declarations entirely, so an extension's isolation was silently read off
// whatever `struct`/`class`/`actor` happened to appear earlier IN THE SAME
// FILE (a false negative when the true type is declared elsewhere, e.g.
// cross-file, and a false positive waiting to happen when an unrelated
// earlier declaration in the same file happened to be `@MainActor`). Fixed
// via a cross-file type→isolation index built once over `Sources/` + `Tests/`
// and an `extension <Name>` branch in `enclosingTypeIsMainActor` that stops
// the walk at the extension and resolves `<Name>` through that index, rather
// than walking past it. This also resolved design §10 point 5's open item —
// `RecoveryAnchorContinuityGateTests.swift:285/286/307` now correctly
// resolve as main-actor-isolated (see Leg A/B's updated table below and the
// `extensionAwareEnclosingTypeFixtures` regression pin). m23-aw-3 also added
// a second pass over `Sources/` — see Leg E below.
@Suite("Main-actor occupancy — site pin (m23-aw)")
struct MainActorOccupancySiteTests {

    // MARK: - A resolved hog site

    struct HogSite: CustomStringConvertible {
        let file: String
        let line: Int
        let enclosingSymbol: String
        let durationMilliseconds: Int
        var description: String { "\(file):\(line) \(enclosingSymbol) \(durationMilliseconds)ms" }
        var key: String { "\(file)|\(enclosingSymbol)|\(durationMilliseconds)" }
    }

    // MARK: - Source access (the RenderClockTrustSiteTests idiom, generalized to `Tests/`)

    /// Locate `<repo>` by walking up from this test file (`#filePath`),
    /// anchored on the presence of `Sources/DAWEngine` as a repo-root marker
    /// — no bundle resources, runs headless under `./scripts/test.sh`.
    private static func repoRootDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let anchor = dir.appendingPathComponent("Sources/DAWEngine", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: anchor.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate <repo> from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func testsRootDir() -> URL {
        repoRootDir().appendingPathComponent("Tests", isDirectory: true)
    }

    /// The m23-aw-3 widened root (step 4): `Sources/`, scanned by the SAME
    /// pure scanner as `Tests/`, with clause (e) handled per
    /// `hogSitesIgnoringClauseE`'s doc comment.
    private static func sourcesRootDir() -> URL {
        repoRootDir().appendingPathComponent("Sources", isDirectory: true)
    }

    private static func swiftFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate \(root.path)")
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func allTestSwiftFiles() -> [URL] {
        swiftFiles(under: testsRootDir())
    }

    private static func allSourceSwiftFiles() -> [URL] {
        swiftFiles(under: sourcesRootDir())
    }

    private static func lines(ofFileAt url: URL) -> [(number: Int, text: String)] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(url.path)")
            return []
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated().map { ($0.offset + 1, String($0.element)) }
    }

    /// Non-comment lines only, same idiom as `RenderClockTrustSiteTests.codeLines`.
    private static func nonCommentLines(
        _ lines: [(number: Int, text: String)]
    ) -> [(number: Int, text: String)] {
        lines.filter { line in
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            return !(trimmed.hasPrefix("//") || trimmed.hasPrefix("*")
                     || trimmed.hasPrefix("/*") || trimmed.hasPrefix("///"))
        }
    }

    private static func numbered(_ raw: [String]) -> [(number: Int, text: String)] {
        raw.enumerated().map { ($0.offset + 1, $0.element) }
    }

    // MARK: - Text-parsing primitives

    /// Name of the method a source line sits inside — the nearest preceding
    /// declaration at type-body indent (4 spaces). Verbatim idiom from
    /// `RenderClockTrustSiteTests.enclosingMethod`, generalized to return the
    /// declaration's own line number too (needed to inspect its attributes
    /// and parameter list).
    private static func enclosingFunction(
        ofLine line: Int, in code: [(number: Int, text: String)]
    ) -> (name: String, declLine: Int)? {
        var found: (String, Int)?
        for candidate in code where candidate.number < line {
            let text = candidate.text
            guard text.hasPrefix("    ") && !text.hasPrefix("     ") else { continue }
            var trimmed = text.trimmingCharacters(in: .whitespaces)
            for modifier in ["public ", "private ", "internal ", "fileprivate ", "static "] {
                while trimmed.hasPrefix(modifier) { trimmed.removeFirst(modifier.count) }
            }
            guard trimmed.hasPrefix("func ") else { continue }
            trimmed.removeFirst("func ".count)
            let name = String(trimmed.prefix { $0 != "(" && $0 != "<" })
            found = (name, candidate.number)
        }
        return found
    }

    /// Joins a construct that spans lines: from `start`, accumulate until the
    /// FIRST `{`/`}` pair balances back to <= 0 (the `callText` idiom from
    /// `RenderClockTrustSiteTests`, generalized to braces).
    private static func braceBlockText(from start: Int, in code: [(number: Int, text: String)]) -> String {
        var depth = 0
        var started = false
        var joined = ""
        for line in code where line.number >= start {
            joined += " " + line.text
            for character in line.text {
                if character == "{" { depth += 1; started = true }
                if character == "}" { depth -= 1 }
            }
            if started && depth <= 0 { break }
        }
        return joined
    }

    /// Same idea for parentheses (a call, or a parameter list starting at a
    /// `func` declaration line) — verbatim `RenderClockTrustSiteTests.callText`.
    private static func parenBlockText(from start: Int, in code: [(number: Int, text: String)]) -> String {
        var depth = 0
        var started = false
        var joined = ""
        for line in code where line.number >= start {
            joined += " " + line.text
            for character in line.text {
                if character == "(" { depth += 1; started = true }
                if character == ")" { depth -= 1 }
            }
            if started && depth <= 0 { break }
        }
        return joined
    }

    /// The text strictly between the FIRST `(` and its matching `)`.
    private static func innerParenList(_ text: String) -> String {
        guard let firstParen = text.firstIndex(of: "(") else { return "" }
        var depth = 0
        var endIndex: String.Index?
        var idx = firstParen
        while idx < text.endIndex {
            let ch = text[idx]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 { endIndex = idx; break }
            }
            idx = text.index(after: idx)
        }
        guard let end = endIndex else { return "" }
        return String(text[text.index(after: firstParen)..<end])
    }

    /// Splits `text` on `separator` at bracket-depth 0 — a naive comma split
    /// would break on a parameter/argument whose own type or default value
    /// contains a nested `(`/`[`/`<`.
    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for ch in text {
            if ch == "(" || ch == "[" || ch == "<" { depth += 1 }
            if ch == ")" || ch == "]" || ch == ">" { depth -= 1 }
            if ch == separator && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// A `let NAME = RHS` / `var NAME = RHS` binding, name only (type
    /// annotations stripped).
    private static func letBinding(in text: String) -> (name: String, rhs: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for keyword in ["let ", "var "] {
            guard trimmed.hasPrefix(keyword) else { continue }
            let rest = trimmed.dropFirst(keyword.count)
            guard let equals = rest.range(of: "=") else { return nil }
            var name = String(rest[rest.startIndex..<equals.lowerBound])
            if let colon = name.range(of: ":") { name = String(name[name.startIndex..<colon.lowerBound]) }
            let rhs = String(rest[equals.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (name.trimmingCharacters(in: .whitespaces), rhs)
        }
        return nil
    }

    /// `Duration.milliseconds(N)` / `.milliseconds(N)` / `Duration.seconds(N)`
    /// / `.seconds(N)` → whole milliseconds. Underscored numeric literals
    /// (`1_000`) are normalized first.
    private static func millisecondsFromDurationExpression(_ expression: String) -> Int? {
        let cleaned = expression.replacingOccurrences(of: "_", with: "")
        if let range = cleaned.range(of: "milliseconds(") {
            let rest = cleaned[range.upperBound...]
            if let close = rest.firstIndex(of: ")"),
               let n = Int(rest[rest.startIndex..<close].trimmingCharacters(in: .whitespaces)) {
                return n
            }
        }
        if let range = cleaned.range(of: "seconds(") {
            let rest = cleaned[range.upperBound...]
            if let close = rest.firstIndex(of: ")"),
               let n = Double(rest[rest.startIndex..<close].trimmingCharacters(in: .whitespaces)) {
                return Int((n * 1000).rounded())
            }
        }
        return nil
    }

    /// `Thread.sleep(forTimeInterval: X)` (seconds) or `usleep(N)`
    /// (microseconds) → whole milliseconds.
    private static func millisecondsFromSleepCall(_ text: String) -> Int? {
        if let range = text.range(of: "forTimeInterval:") {
            let rest = text[range.upperBound...]
            if let close = rest.firstIndex(where: { $0 == ")" || $0 == "," }),
               let n = Double(rest[rest.startIndex..<close].trimmingCharacters(in: .whitespaces)) {
                return Int((n * 1000).rounded())
            }
        }
        if let range = text.range(of: "usleep(") {
            let rest = text[range.upperBound...]
            if let close = rest.firstIndex(of: ")") {
                let raw = rest[rest.startIndex..<close]
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")
                if let n = Int(raw) { return n / 1000 }
            }
        }
        return nil
    }

    // MARK: - Clause (d): positive main-actor evidence

    private static func hasMainActorAttributeAbove(
        declLine: Int, in code: [(number: Int, text: String)]
    ) -> Bool {
        guard let idx = code.firstIndex(where: { $0.number == declLine }) else { return false }
        var i = idx
        while i > 0 {
            i -= 1
            let t = code[i].text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("@MainActor") { return true }
            if t.hasPrefix("@") { continue }
            break
        }
        return false
    }

    /// Deliberately UNCHANGED by m23-aw-3 (Leg C's `@Suite`/`@MainActor`
    /// forward-search at `structuralCounts()` reads this too, and that
    /// count is pinned) — `struct`/`class`/`actor` ONLY, never `extension`.
    /// The m23-aw-3 fix does not widen this function; it adds a SEPARATE
    /// `extension` branch to `enclosingTypeIsMainActor` below instead, so
    /// this predicate's callers outside clause (d) are untouched.
    private static func isTypeDeclarationLine(_ text: String) -> Bool {
        guard !text.contains("func") else { return false }
        for keyword in ["struct ", "class ", "actor "] {
            guard let range = text.range(of: keyword) else { continue }
            let before = text[text.startIndex..<range.lowerBound]
            let precededByBoundary = before.isEmpty
                || !(before.last!.isLetter || before.last!.isNumber || before.last! == "_")
            let after = text[range.upperBound...]
            let followedByIdentifier = after.first.map { $0.isLetter || $0 == "_" } ?? false
            if precededByBoundary && followedByIdentifier { return true }
        }
        return false
    }

    /// Same boundary logic as `isTypeDeclarationLine`, but for `struct`/
    /// `class`/`actor` it also EXTRACTS the declared name (needed to build
    /// the m23-aw-3 cross-file type→isolation index below).
    private static func typeDeclarationName(in text: String) -> String? {
        guard !text.contains("func") else { return nil }
        for keyword in ["struct ", "class ", "actor "] {
            guard let range = text.range(of: keyword) else { continue }
            let before = text[text.startIndex..<range.lowerBound]
            let precededByBoundary = before.isEmpty
                || !(before.last!.isLetter || before.last!.isNumber || before.last! == "_")
            guard precededByBoundary else { continue }
            let after = text[range.upperBound...]
            let name = after.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty else { continue }
            return String(name)
        }
        return nil
    }

    /// The m23-aw-3 fix's other half of `typeDeclarationName`: the name after
    /// `extension `, boundary-checked the same way (so `"SomeExtensionOfX"`
    /// does not falsely match `extension `'s trailing space inside a longer
    /// identifier, and a genuine `extension Foo {` at column 0 does).
    private static func extensionTypeName(in text: String) -> String? {
        guard let range = text.range(of: "extension ") else { return nil }
        let before = text[text.startIndex..<range.lowerBound]
        let precededByBoundary = before.isEmpty
            || !(before.last!.isLetter || before.last!.isNumber || before.last! == "_")
        guard precededByBoundary else { return nil }
        let after = text[range.upperBound...]
        let name = after.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    /// THE m23-aw-3 FIX: a cross-file type→isolation index (type name → does
    /// ANY declaration site for that name carry positive `@MainActor`
    /// evidence — either directly on a `struct`/`class`/`actor` line, or on
    /// an `@MainActor extension Name { … }` block), built ONCE over the
    /// whole repo (`Sources/` + `Tests/` — an extension in `Tests/` can
    /// legitimately extend a type declared in `Sources/`, so the index must
    /// span both, not just whichever root is currently being scanned). A
    /// Swift `static let` initializer runs exactly once per process, so this
    /// is a genuine first PASS, not a re-scan per candidate.
    private static let mainActorTypeNames: Set<String> = {
        var names: Set<String> = []
        for root in [MainActorOccupancySiteTests.sourcesRootDir(), MainActorOccupancySiteTests.testsRootDir()] {
            for url in MainActorOccupancySiteTests.swiftFiles(under: root) {
                let code = MainActorOccupancySiteTests.nonCommentLines(MainActorOccupancySiteTests.lines(ofFileAt: url))
                for line in code {
                    guard !line.text.hasPrefix("    ") else { continue }  // column 0 only
                    if let name = MainActorOccupancySiteTests.typeDeclarationName(in: line.text) {
                        if MainActorOccupancySiteTests.hasMainActorAttributeAbove(declLine: line.number, in: code) {
                            names.insert(name)
                        }
                    } else if let name = MainActorOccupancySiteTests.extensionTypeName(in: line.text) {
                        if MainActorOccupancySiteTests.hasMainActorAttributeAbove(declLine: line.number, in: code) {
                            names.insert(name)
                        }
                    }
                }
            }
        }
        return names
    }()

    /// D2 — the enclosing TYPE (nearest preceding column-0 `struct`/`class`/
    /// `actor`/`extension` declaration) carries `@MainActor`, DIRECTLY or —
    /// for an `extension <Name>` — via `<Name>`'s isolation resolved through
    /// the cross-file index above.
    ///
    /// ⚠️ m23-aw-3: this walk used to recognize ONLY `struct`/`class`/`actor`
    /// (via `isTypeDeclarationLine`), so it walked STRAIGHT PAST any
    /// `extension` line to whatever type declaration happened to appear
    /// earlier in the file — a false negative when the extended type's real
    /// declaration is elsewhere (this file's own `extension` case, or
    /// cross-file), and a false positive waiting to happen when an unrelated
    /// earlier declaration in the same file happened to be `@MainActor`. The
    /// fix is to STOP the walk at an extension line (checked below) rather
    /// than skip past it, and resolve its target through the index — the
    /// walk's job is "nearest enclosing declaration", not "nearest
    /// struct/class/actor", and an extension IS a declaration.
    private static func enclosingTypeIsMainActor(
        forDeclLine line: Int, in code: [(number: Int, text: String)], mainActorTypeNames: Set<String>
    ) -> Bool {
        guard let idx = code.firstIndex(where: { $0.number == line }) else { return false }
        var i = idx
        while i > 0 {
            i -= 1
            let text = code[i].text
            if text.hasPrefix("    ") { continue }
            if isTypeDeclarationLine(text) {
                return hasMainActorAttributeAbove(declLine: code[i].number, in: code)
            }
            if let extendedName = extensionTypeName(in: text) {
                // `@MainActor extension Name { … }` applies isolation directly,
                // the same way `@MainActor struct`/`class`/`actor` does.
                if hasMainActorAttributeAbove(declLine: code[i].number, in: code) { return true }
                // Otherwise resolve `Name`'s OWN isolation through the index —
                // NOT by continuing the walk past this line, which is exactly
                // the bug this fix removes.
                return mainActorTypeNames.contains(extendedName)
            }
        }
        return false
    }

    /// D3 — the site sits lexically inside an UNCLOSED `MainActor.run {` /
    /// `MainActor.assumeIsolated {` block opened between the enclosing
    /// function's start and the target line.
    private static func isInsideMainActorRunBlock(
        fromFunctionStart start: Int, toLine target: Int, code: [(number: Int, text: String)]
    ) -> Bool {
        var depth = 0
        var open = false
        for line in code where line.number >= start && line.number <= target {
            if line.text.contains("MainActor.run") || line.text.contains("MainActor.assumeIsolated") {
                open = true
                depth = 0
            }
            guard open else { continue }
            for ch in line.text {
                if ch == "{" { depth += 1 }
                if ch == "}" { depth -= 1 }
            }
            if line.number == target { break }
            if depth <= 0 { open = false }
        }
        return open && depth > 0
    }

    private static func passesClauseD(
        enclosingFunc: (name: String, declLine: Int), siteLine: Int, code: [(number: Int, text: String)],
        mainActorTypeNames: Set<String>
    ) -> Bool {
        hasMainActorAttributeAbove(declLine: enclosingFunc.declLine, in: code)
            || enclosingTypeIsMainActor(
                forDeclLine: enclosingFunc.declLine, in: code, mainActorTypeNames: mainActorTypeNames)
            || isInsideMainActorRunBlock(fromFunctionStart: enclosingFunc.declLine, toLine: siteLine, code: code)
    }

    // MARK: - Clause (e): reachable from a default-running @Test

    /// `nil` = the function itself carries no `@Test` attribute (it is a
    /// helper, not a test). `true`/`false` = it does, and is/is not gated.
    private static func testGatingStatus(
        declLine: Int, in code: [(number: Int, text: String)]
    ) -> Bool? {
        guard let idx = code.firstIndex(where: { $0.number == declLine }) else { return nil }
        var i = idx
        var attributeLines: [String] = []
        while i > 0 {
            i -= 1
            let raw = code[i].text
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if t.hasPrefix("@") {
                attributeLines.insert(raw, at: 0)
                continue
            }
            break
        }
        let joined = attributeLines.joined(separator: " ")
        guard joined.contains("@Test") else { return nil }
        return joined.contains(".enabled(if:") || joined.contains(".disabled(")
    }

    private static func callSites(ofFunction name: String, in code: [(number: Int, text: String)]) -> [Int] {
        code.filter { $0.text.contains("\(name)(") && !$0.text.contains("func \(name)(") }.map { $0.number }
    }

    /// Recursion depth is capped: this is a call GRAPH walk over a finite
    /// test file, not a general fixed-point solver.
    private static func passesClauseE(
        enclosingFunc: (name: String, declLine: Int), code: [(number: Int, text: String)], depth: Int = 0
    ) -> Bool {
        guard depth < 6 else { return false }
        if let gated = testGatingStatus(declLine: enclosingFunc.declLine, in: code) {
            return !gated
        }
        for callLine in callSites(ofFunction: enclosingFunc.name, in: code) {
            guard let caller = enclosingFunction(ofLine: callLine, in: code) else { continue }
            if passesClauseE(enclosingFunc: caller, code: code, depth: depth + 1) { return true }
        }
        return false
    }

    // MARK: - Duration resolution (two-hop)

    private static func parameters(
        ofFunctionAt declLine: Int, in code: [(number: Int, text: String)]
    ) -> [(label: String, name: String)] {
        let signature = parenBlockText(from: declLine, in: code)
        let inner = innerParenList(signature)
        return splitTopLevel(inner, separator: ",").compactMap { chunk -> (String, String)? in
            var text = chunk.trimmingCharacters(in: .whitespaces)
            if let eq = text.range(of: "=") { text = String(text[text.startIndex..<eq.lowerBound]) }
            guard let colon = text.range(of: ":") else { return nil }
            let namePart = text[text.startIndex..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            let tokens = namePart.split(separator: " ").map(String.init)
            guard let last = tokens.last else { return nil }
            let label = tokens.count >= 2 ? tokens[0] : tokens[0]
            return (label, tokens.count >= 2 ? tokens[1] : last)
        }
    }

    private static func argument(forLabel label: String, inCall callText: String) -> String? {
        let inner = innerParenList(callText)
        for part in splitTopLevel(inner, separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(label):") {
                return String(trimmed.dropFirst("\(label):".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Two-hop resolution: a local `let`/`var` binding within the enclosing
    /// function (hop 1), or — if `identifier` names a PARAMETER of the
    /// enclosing function instead — the argument passed at that label from a
    /// call site elsewhere in the file, resolved the same way there (hop 2).
    private static func resolveDurationMilliseconds(
        identifier: String, beforeLine: Int,
        enclosingFunc: (name: String, declLine: Int), code: [(number: Int, text: String)], depth: Int = 0
    ) -> Int? {
        guard depth < 4 else { return nil }
        for candidate in code where candidate.number >= enclosingFunc.declLine && candidate.number < beforeLine {
            guard let binding = letBinding(in: candidate.text), binding.name == identifier else { continue }
            if let ms = millisecondsFromDurationExpression(binding.rhs) { return ms }
        }
        guard let param = parameters(ofFunctionAt: enclosingFunc.declLine, in: code)
            .first(where: { $0.name == identifier })
        else { return nil }
        for callLine in callSites(ofFunction: enclosingFunc.name, in: code) {
            guard let caller = enclosingFunction(ofLine: callLine, in: code) else { continue }
            let callText = parenBlockText(from: callLine, in: code)
            guard let arg = argument(forLabel: param.label, inCall: callText) else { continue }
            if let ms = millisecondsFromDurationExpression(arg) { return ms }
            if let ms = resolveDurationMilliseconds(
                identifier: arg, beforeLine: callLine, enclosingFunc: caller, code: code, depth: depth + 1
            ) { return ms }
        }
        return nil
    }

    private static func deadlineVariableName(inWhileLine text: String) -> String? {
        guard let whileRange = text.range(of: "while ") else { return nil }
        let rest = text[whileRange.upperBound...]
        if let lt = rest.range(of: " < ") {
            let lhs = rest[rest.startIndex..<lt.lowerBound]
            if lhs.contains(".now") {
                let name = rest[lt.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { return String(name) }
            }
        }
        if let gt = rest.range(of: " > ") {
            let rhs = rest[gt.upperBound...]
            if rhs.contains(".now") {
                let name = rest[rest.startIndex..<gt.lowerBound].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private static func durationIdentifier(
        forDeadlineVariable name: String, beforeLine: Int,
        enclosingFunc: (name: String, declLine: Int), code: [(number: Int, text: String)]
    ) -> String? {
        for candidate in code where candidate.number >= enclosingFunc.declLine && candidate.number < beforeLine {
            guard let binding = letBinding(in: candidate.text), binding.name == name else { continue }
            guard let byRange = binding.rhs.range(of: "advanced(by:") else { continue }
            let after = binding.rhs[byRange.upperBound...]
            let ident = after.prefix { $0 != ")" }.trimmingCharacters(in: .whitespaces)
            if !ident.isEmpty { return ident }
        }
        return nil
    }

    // MARK: - Candidate detection + evaluation

    private struct Candidate {
        let line: Int
        let deadlineVariable: String?
        let inlineSleepText: String?
        let kind: Kind
        enum Kind { case spin, sleep }
    }

    private static func candidates(in code: [(number: Int, text: String)]) -> [Candidate] {
        var found: [Candidate] = []
        for line in code {
            if let deadlineVar = deadlineVariableName(inWhileLine: line.text) {
                found.append(Candidate(line: line.number, deadlineVariable: deadlineVar,
                                       inlineSleepText: nil, kind: .spin))
            }
            if line.text.contains("Thread.sleep(forTimeInterval:") {
                found.append(Candidate(line: line.number, deadlineVariable: nil,
                                       inlineSleepText: line.text, kind: .sleep))
            }
            if line.text.contains("usleep(") && !line.text.contains("func usleep") {
                found.append(Candidate(line: line.number, deadlineVariable: nil,
                                       inlineSleepText: line.text, kind: .sleep))
            }
        }
        return found
    }

    private enum Outcome {
        case resolved(HogSite)
        case excludedSuspends
        case excludedNotMainActor
        case excludedGated
        case unresolved(String)
        case shapeIncomplete
    }

    private static func evaluate(
        _ candidate: Candidate, code: [(number: Int, text: String)], file: String,
        mainActorTypeNames: Set<String>, requireReachableFromDefaultTest: Bool
    ) -> Outcome {
        guard let enclosingFunc = enclosingFunction(ofLine: candidate.line, in: code) else {
            return .shapeIncomplete
        }
        if candidate.kind == .spin {
            let body = braceBlockText(from: candidate.line, in: code)
            if body.contains("await") { return .excludedSuspends }
        }
        guard passesClauseD(
            enclosingFunc: enclosingFunc, siteLine: candidate.line, code: code,
            mainActorTypeNames: mainActorTypeNames
        ) else {
            return .excludedNotMainActor
        }
        // Clause (e) — "reachable from a default-running @Test" — is a
        // TESTS-ONLY concept (design §1.7(e); no `@Test` exists in
        // `Sources/`). `requireReachableFromDefaultTest` is what lets the
        // m23-aw-3 `Sources/` pass evaluate clauses (a)-(d) only, deliberately
        // — see `hogSitesIgnoringClauseE`'s doc comment for why silently
        // requiring OR silently skipping this clause are both wrong answers.
        if requireReachableFromDefaultTest {
            guard passesClauseE(enclosingFunc: enclosingFunc, code: code) else {
                return .excludedGated
            }
        }
        switch candidate.kind {
        case .spin:
            guard let deadlineVar = candidate.deadlineVariable,
                  let durationIdent = durationIdentifier(
                      forDeadlineVariable: deadlineVar, beforeLine: candidate.line,
                      enclosingFunc: enclosingFunc, code: code)
            else {
                return .shapeIncomplete
            }
            guard let ms = resolveDurationMilliseconds(
                identifier: durationIdent, beforeLine: candidate.line,
                enclosingFunc: enclosingFunc, code: code
            ) else {
                return .unresolved(
                    "\(file):\(candidate.line) in \(enclosingFunc.name) — a clock-deadline spin with "
                    + "main-actor evidence and no gating trait, but duration identifier "
                    + "'\(durationIdent)' could not be resolved within two hops")
            }
            return .resolved(HogSite(file: file, line: candidate.line,
                                     enclosingSymbol: enclosingFunc.name, durationMilliseconds: ms))
        case .sleep:
            guard let ms = millisecondsFromSleepCall(candidate.inlineSleepText ?? "") else {
                return .unresolved(
                    "\(file):\(candidate.line) in \(enclosingFunc.name) — a Thread.sleep/usleep call with "
                    + "main-actor evidence and no gating trait, but its duration argument could not be parsed")
            }
            return .resolved(HogSite(file: file, line: candidate.line,
                                     enclosingSymbol: enclosingFunc.name, durationMilliseconds: ms))
        }
    }

    // MARK: - THE PURE SCANNER (§7.2's factoring requirement)

    /// A pure function over text — no file I/O. `lines` is ONE file's lines
    /// (numbered, comments included — this function strips them itself so
    /// the §7.2 discriminator can feed it a raw literal fixture). This is
    /// what Leg A's set-equality check runs, and what the permanent
    /// discriminator in `scannerRecognizesSyntheticHogsAndRespectsGating`
    /// exercises directly against synthetic text.
    ///
    /// ⚠️ THIS SIGNATURE IS PINNED (design §7.2) — it must keep taking
    /// exactly `(in lines:, file:)` and using the REAL, repo-wide
    /// `mainActorTypeNames` index + REQUIRING clause (e), so every existing
    /// caller (Leg A/B, the permanent discriminator) is unaffected by
    /// m23-aw-3. The extension-aware fix and the injectable index it needed
    /// for fixture testing live in the PRIVATE overload just below instead —
    /// an additive overload, not a change to this one.
    static func hogSites(in lines: [(number: Int, text: String)], file: String) -> [HogSite] {
        hogSites(
            in: lines, file: file,
            mainActorTypeNames: MainActorOccupancySiteTests.mainActorTypeNames,
            requireReachableFromDefaultTest: true)
    }

    /// The m23-aw-3 injection point: same evaluation pipeline as the pinned
    /// overload above, but with the cross-file type→isolation index supplied
    /// by the caller (so the A/B/C/D regression fixtures below can exercise
    /// `extension <Name>` resolution against a SYNTHETIC index, without
    /// writing real files to disk) and clause (e) optionally bypassed (what
    /// the `Sources/` pass needs — see `hogSitesIgnoringClauseE`).
    private static func hogSites(
        in lines: [(number: Int, text: String)], file: String,
        mainActorTypeNames: Set<String>, requireReachableFromDefaultTest: Bool
    ) -> [HogSite] {
        let code = nonCommentLines(lines)
        return candidates(in: code).compactMap { candidate in
            if case .resolved(let site) = evaluate(
                candidate, code: code, file: file, mainActorTypeNames: mainActorTypeNames,
                requireReachableFromDefaultTest: requireReachableFromDefaultTest
            ) { return site }
            return nil
        }
    }

    /// The `Sources/` pass's scanner (m23-aw-3 step 4): identical to
    /// `hogSites(in:file:)` except clause (e) is NOT evaluated. `Sources/`
    /// carries no `@Test` attribute anywhere, so "reachable from a
    /// default-running @Test" is undefined there, not false — and treating
    /// an undefined clause as an automatic EXCLUDE would make an
    /// expected-empty-set assertion vacuous (everything in `Sources/` would
    /// silently pass regardless of whether the extension fix works), while
    /// treating it as an automatic INCLUDE only for the clauses that ARE
    /// answerable (a)-(d) is the deliberate choice made here: a `Sources/`
    /// main-actor blocker is real regardless of what test suite (if any)
    /// happens to exercise it. Verified NOT vacuous by
    /// `sourcesPassDistinguishesFromTestsPassOnAnUntestedFixture` below,
    /// which shows this function finds a hog that the pinned `hogSites`
    /// above (clause (e) required) does NOT.
    private static func hogSitesIgnoringClauseE(
        in lines: [(number: Int, text: String)], file: String, mainActorTypeNames: Set<String>
    ) -> [HogSite] {
        hogSites(
            in: lines, file: file, mainActorTypeNames: mainActorTypeNames,
            requireReachableFromDefaultTest: false)
    }

    /// The loud-failure companion to `hogSites`: main-actor-context,
    /// ungated candidates whose duration could NOT be resolved. Not part of
    /// `hogSites`'s own signature (design §7.2 pins that signature exactly),
    /// but consumed by Leg A so an unresolvable site fails the suite instead
    /// of silently vanishing from the ledger.
    static func unresolvedMainActorCandidates(in lines: [(number: Int, text: String)], file: String) -> [String] {
        unresolvedMainActorCandidates(
            in: lines, file: file,
            mainActorTypeNames: MainActorOccupancySiteTests.mainActorTypeNames,
            requireReachableFromDefaultTest: true)
    }

    private static func unresolvedMainActorCandidates(
        in lines: [(number: Int, text: String)], file: String,
        mainActorTypeNames: Set<String>, requireReachableFromDefaultTest: Bool
    ) -> [String] {
        let code = nonCommentLines(lines)
        return candidates(in: code).compactMap { candidate in
            if case .unresolved(let message) = evaluate(
                candidate, code: code, file: file, mainActorTypeNames: mainActorTypeNames,
                requireReachableFromDefaultTest: requireReachableFromDefaultTest
            ) { return message }
            return nil
        }
    }

    /// The `Sources/` companion to `hogSitesIgnoringClauseE` — surfaces a
    /// shape-matching, main-actor-context candidate whose duration could not
    /// be parsed (e.g. a caller-supplied, not source-constant, sleep length —
    /// clause (c)'s own boundary, not a scanner gap) so it is reported and
    /// pinned rather than silently absent from both channels.
    private static func unresolvedMainActorCandidatesIgnoringClauseE(
        in lines: [(number: Int, text: String)], file: String, mainActorTypeNames: Set<String>
    ) -> [String] {
        unresolvedMainActorCandidates(
            in: lines, file: file, mainActorTypeNames: mainActorTypeNames,
            requireReachableFromDefaultTest: false)
    }

    private static func allHogSites() -> [HogSite] {
        Self.allTestSwiftFiles().flatMap { url in
            Self.hogSites(in: Self.lines(ofFileAt: url), file: url.lastPathComponent)
        }
    }

    private static func allUnresolvedWarnings() -> [String] {
        Self.allTestSwiftFiles().flatMap { url in
            Self.unresolvedMainActorCandidates(in: Self.lines(ofFileAt: url), file: url.lastPathComponent)
        }
    }

    // MARK: - Structural counts (Leg C)

    /// `git grep`-equivalent counting for `@Suite` / `@MainActor`-isolated
    /// `@Suite` — independently re-derived and cross-checked against the
    /// design's own numbers (486 / 298, measured 2026-08-03) rather than
    /// trusted from the doc. `prepareLikeSiteCount` is printed, never
    /// asserted (design §4.3: it is a proxy for the CHANNEL THAT DID NOT
    /// DRIFT, rejected as a ratchet — kept only for trend visibility, and
    /// its exact figure is expected to differ from any single historical
    /// spot-count taken by different ad hoc tooling). ⚠️ ONE KNOWN,
    /// UNFIXED CONTAMINANT (deliberately not worth the `@Suite`/`@MainActor`
    /// `hasPrefix` treatment above, because nothing reads this count as a
    /// pin): this scan is a plain `.contains`-style substring count, not
    /// `hasPrefix`, and this file's OWN source is one of the files it walks
    /// — its two `Self.occurrences(of: ".prepare(", …)` /
    /// `Self.occurrences(of: ".prepareEffect(", …)` call sites just below
    /// are themselves string literals containing `.prepare(` /
    /// `.prepareEffect(`, so every run of this file counts its own two
    /// pattern literals as +2 sites that are not real call sites. That +2
    /// self-match is a specific, known component of "differs from any
    /// historical spot-count" above, not just generic tooling drift.
    private static func structuralCounts() -> (suites: Int, mainActorSuites: Int, prepareLikeSites: Int, files: Int) {
        let files = Self.allTestSwiftFiles()
        var suiteCount = 0
        var mainActorSuiteCount = 0
        var prepareLikeCount = 0
        for url in files {
            let raw = Self.lines(ofFileAt: url)
            for (i, line) in raw.enumerated() {
                let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                // ⚠️ hasPrefix on the TRIMMED line, never `.contains` anywhere
                // in it — a `.contains` scan is self-referential: THIS FILE's
                // own scanner code and its synthetic fixture data are text
                // that legitimately contains the substrings "@Suite" /
                // "@MainActor" (as pattern literals, print messages, and
                // fixture lines) without being real attributes, and a
                // `.contains` version measured 490/299 against a verified
                // 487/298 (486/298 pre-existing + this file's own one real,
                // non-`@MainActor` suite) — a false +3/+1 from its own source.
                // Verified tree-wide: zero real `@Suite`/`@MainActor` site
                // fails to start its own trimmed line, so `hasPrefix` loses
                // no genuine coverage anywhere else in `Tests/`.
                if trimmed.hasPrefix("@Suite") {
                    suiteCount += 1
                    var isMainActor = false
                    var j = i - 1
                    while j >= 0 {
                        let s = raw[j].text.trimmingCharacters(in: .whitespaces)
                        if s.hasPrefix("@MainActor") { isMainActor = true; break }
                        if s.isEmpty || s.hasPrefix("//") || s.hasPrefix("@") { j -= 1; continue }
                        break
                    }
                    if !isMainActor {
                        var k = i
                        while k < raw.count && k < i + 6 {
                            let kTrimmed = raw[k].text.trimmingCharacters(in: .whitespaces)
                            if kTrimmed.hasPrefix("@MainActor") { isMainActor = true; break }
                            if Self.isTypeDeclarationLine(raw[k].text) { break }
                            k += 1
                        }
                    }
                    if isMainActor { mainActorSuiteCount += 1 }
                }
                prepareLikeCount += Self.occurrences(of: ".prepare(", in: line.text)
                prepareLikeCount += Self.occurrences(of: ".prepareEffect(", in: line.text)
            }
        }
        return (suiteCount, mainActorSuiteCount, prepareLikeCount, files.count)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    // MARK: - Leg A — THE LEDGER (set equality, not a count)

    /// The set of deliberate main-actor hogs must equal EXACTLY the measured
    /// table (design §5.2/§1.7). Set equality on (file, symbol, duration) —
    /// deliberately NOT including line numbers, so a benign line shift
    /// elsewhere in a file does not false-fail this pin, while a duration or
    /// symbol swap (the m23-bp lesson: a count pin alone would miss a 1s hog
    /// silently becoming a 5s hog) still does.
    @Test("Leg A — THE LEDGER: deliberate main-actor hogs equal exactly the measured set")
    func ledgerMatchesExactlyTheMeasuredSet() {
        let expectedKeys: Set<String> = [
            "DeadlineRaceTests.swift|spinHoldingMainActor|1000",
            "AUPrepareInFlightWedgeTests.swift|inFlightIsReadableWhileTheActorIsHeld|2000",
            // m23-aw-3: these three were ALWAYS main-actor-isolated occupancy
            // (RecoveryPlayheadTests, the extended type, is `@MainActor` —
            // declared in a DIFFERENT file, RecoveryPlayheadTests.swift) —
            // they did not just land. The pre-fix scanner could not see them
            // because clause (d)'s enclosing-type walk did not recognize
            // `extension` at all; see the header comment and
            // `extensionAwareEnclosingTypeFixtures` below. NOT new hogs, so no
            // scripts/gates/m23aw-prepare-headroom.mjs campaign paste — that
            // ritual attaches to newly-landed occupancy, and the physical
            // quantity this measures did not move, only the measurement did.
            "RecoveryAnchorContinuityGateTests.swift|measureRenderClockLeadSeconds|5",
            "RecoveryAnchorContinuityGateTests.swift|measureRenderClockLeadSeconds|200",
            "RecoveryAnchorContinuityGateTests.swift|measureRenderClockLeadSeconds|3",
        ]
        let found = Self.allHogSites()
        let foundKeys = Set(found.map(\.key))
        let rendered = found.map(\.description).sorted()
        print("[measured] m23-aw occupancy ledger: \(rendered)")

        let why = "the deliberate main-actor occupancy LEDGER moved — a hog was added, removed, or its "
            + "duration/symbol changed (a count pin alone would miss a duration swap — the m23-bp lesson). "
            + "Measured: \(rendered). Re-read design §1.7's audit trail before widening the expected table; "
            + "if this fires because a NEW hog genuinely landed, follow §6.2's re-derivation rule (raise Leg "
            + "B by exactly the new duration and paste a fresh scripts/gates/m23aw-prepare-headroom.mjs "
            + "campaign result into the comment above it) — never respond by raising "
            + "AUHostRegistry.testPrepareTimeout."
        #expect(foundKeys == expectedKeys, "\(why)")

        // The loud-failure path: a main-actor-context, ungated candidate the
        // scanner recognized the SHAPE of but could not resolve a duration
        // for must never vanish silently from the ledger.
        let unresolved = Self.allUnresolvedWarnings()
        #expect(unresolved.isEmpty, """
            \(unresolved.count) blocking construct(s) matched a deliberate-main-actor-hog SHAPE (main-actor \
            context confirmed, no gating trait) but their duration could not be resolved — this ledger \
            cannot claim completeness while that is true: \(unresolved)
            """)
    }

    // MARK: - Leg B — THE BUDGET

    /// Summed nominal hog duration must stay <= 3208 ms — today's measured
    /// total (design §1.7/§6.2, RAISED from 3000 at m23-aw-3). RATCHET, not a
    /// computed capacity.
    ///
    /// ⚠️ m23-aw-3 raised this from 3000 to EXACTLY 3208 (+208 = 5+200+3 ms,
    /// `RecoveryAnchorContinuityGateTests.swift`'s three `usleep`s, now
    /// correctly resolved as main-actor-isolated — see Leg A's table and the
    /// header comment). ⚠️ **NO `scripts/gates/m23aw-prepare-headroom.mjs`
    /// CAMPAIGN WAS PASTED FOR THIS RAISE, DELIBERATELY** — §6.2's campaign
    /// ritual attaches to NEWLY-LANDED main-actor occupancy (a hog that was
    /// not there before and now is), and that is not what happened here: this
    /// occupancy existed on the main actor the whole time, unmeasured because
    /// the scanner could not see through an `extension`. The physical
    /// quantity the campaign would measure (main-actor queue depth under
    /// real load) did not move by this edit; only the LEDGER's accounting of
    /// an already-existing quantity did. A future author raising this bound
    /// for a genuinely NEW hog still owes the full §6.2 ritual — this
    /// carve-out is for a measurement correction, not a precedent for
    /// skipping it.
    ///
    /// ⚠️ Prior to m23-aw-3, as of m23-aw's own close (2026-08-03/04): NO
    /// PASSING `scripts/gates/m23aw-prepare-headroom.mjs` CAMPAIGN EXISTS to
    /// paste for a genuinely new hog — both real 5-run campaigns run at that
    /// item's close FAILED (`THRESHOLD_EXCEEDED`, worst 47.360 s then
    /// 45.925 s), and the second failure's own campaign PASSED the validity
    /// leg (median wall 118.473 s <= 120 s) while still landing T1 at
    /// 45.925 s — see m23-aw-4, a measured calibration gap between the 120 s
    /// validity limit and the 36 s threshold, not yet re-derived. A future
    /// author raising this bound for a NEW hog is stuck at step (3)'s ritual
    /// until either a clean idle-machine campaign passes or m23-aw-4 lands;
    /// do not treat that as licence to skip the paste, and do not tighten
    /// either constant unilaterally to manufacture a pass.
    @Test("Leg B — THE BUDGET: summed deliberate main-actor hog duration stays <= 3208 ms")
    func budgetStaysUnderThreeSeconds() {
        let found = Self.allHogSites()
        let total = found.reduce(0) { $0 + $1.durationMilliseconds }
        print("[measured] m23-aw total deliberate main-actor spin: \(total) ms across \(found.count) site(s)")
        #expect(total <= 3_208, """
            total deliberate main-actor occupancy is \(total) ms, over the 3208 ms budget. Per design §6.2: \
            a new hog may land, but the author must (1) add it to Leg A's expected table, (2) raise this \
            bound by EXACTLY its duration, and (3) run scripts/gates/m23aw-prepare-headroom.mjs and paste \
            the campaign's worst T1 and margin into the comment above this bound — if that gate fails, the \
            hog does not land. Prefer `.enabled(if:)` if the hog's proof survives being conditional \
            (MainActorStarvationGateTests / OutputDeviceLoopbackGateTests precedent — seven 1.5s \
            Thread.sleeps already cost this horizon nothing that way). NEVER respond by raising \
            AUHostRegistry.testPrepareTimeout.
            """)
    }

    // MARK: - Leg C — THE REVIEW CADENCE

    /// `@MainActor`-isolated suite count <= 330 (measured 298, design §6.3).
    /// NOT a physical threshold — `ds/dN` is unmeasured and (per design §4.3)
    /// unmeasurable from existing data; this exists only to force a periodic
    /// re-measurement. Bumping it requires pasting a fresh gate result, same
    /// obligation as Leg B step 3 — raising it without running the gate is
    /// the same act as raising the horizon.
    ///
    /// ⚠️ Same standing caveat as Leg B above: as of m23-aw's own close, no
    /// passing campaign exists to paste — see m23-aw-4 for the measured
    /// validity/threshold calibration gap this surfaced.
    @Test("Leg C — THE REVIEW CADENCE: @MainActor-isolated suite count stays inside the cadence")
    func mainActorSuiteCountStaysInsideCadence() {
        let counts = Self.structuralCounts()
        print("[measured] m23-aw structural counts: @Suite \(counts.suites), "
              + "@MainActor suites \(counts.mainActorSuites), "
              + "prepare/prepareEffect-like sites \(counts.prepareLikeSites) (PRINTED ONLY — design §4.3 "
              + "rejects this as a ratchet channel; it is a proxy for the channel measured NOT to drift), "
              + "files \(counts.files)")
        #expect(counts.mainActorSuites <= 330, """
            @MainActor-isolated suite count is \(counts.mainActorSuites), over the 330 cadence limit \
            (measured 298 at m23-aw). This is a REVIEW CADENCE, not a physical threshold — ds/dN is \
            unmeasured. Bumping this number requires pasting a fresh \
            scripts/gates/m23aw-prepare-headroom.mjs campaign result into the comment above this bound \
            first; raising it without running the gate is the same act as raising the horizon.
            """)
    }

    // MARK: - Leg D — print-continuity (the ADDITIVE-ONLY rule, machine-enforced)

    /// `scripts/gates/m23aw-prepare-headroom.mjs` parses both prefixes; a
    /// reformat of either blinds it silently, and several roadmap items read
    /// past measurements off them (m23-ab-3, m23-at, m23-as-2, m23-aw).
    @Test("Leg D — print-continuity: the two [measured] prefixes the gate parses stay byte-exact")
    func measuredPrintPrefixesStayByteExact() {
        let root = Self.testsRootDir()
        let gmFile = root.appendingPathComponent("DAWEngineTests/SoundBankHostingTests.swift")
        let stressFile = root.appendingPathComponent("DAWEngineTests/AUPrepareRenegotiationStressTests.swift")
        let gmContent = (try? String(contentsOf: gmFile, encoding: .utf8)) ?? ""
        let stressContent = (try? String(contentsOf: stressFile, encoding: .utf8)) ?? ""
        #expect(gmContent.contains("[measured] GM bank prepare-to-ready wall time"), """
            SoundBankHostingTests.swift no longer contains the exact prefix \
            "[measured] GM bank prepare-to-ready wall time" — scripts/gates/m23aw-prepare-headroom.mjs \
            parses this line and would go blind silently.
            """)
        #expect(stressContent.contains("[measured] m19-e contended prepares"), """
            AUPrepareRenegotiationStressTests.swift no longer contains the exact prefix \
            "[measured] m19-e contended prepares" — scripts/gates/m23aw-prepare-headroom.mjs parses this \
            line and would go blind silently.
            """)
    }

    // MARK: - Leg E (m23-aw-3) — extension-aware clause (d), regression fixtures

    /// A/B/C/D from the m23-aw-3 filing, pinned as regression fixtures — same
    /// in-memory-text style as `syntheticFixtureLines` below, injecting the
    /// cross-file index (rather than writing real files to disk) via the
    /// PRIVATE `hogSites(in:file:mainActorTypeNames:requireReachableFromDefaultTest:)`
    /// overload. All four hogs use the same 200 ms `Thread.sleep` shape so
    /// only the enclosing-type SHAPE differs between fixtures — the variable
    /// under test.
    ///
    /// ⚠️ A IS THE POSITIVE CONTROL AND MUST BE CHECKED FIRST (`#require`,
    /// not `#expect`) — the m23-aw-3 filing's own first probe reported 0 for
    /// ALL FOUR cases, including A, because it had written the `@Test`
    /// attribute and `func` on ONE line; `enclosingFunction` requires `func`
    /// to start its OWN trimmed line. Had only B run, that broken instrument
    /// would have "confirmed" the false-negative hypothesis for the wrong
    /// reason. If A fails here, nothing below it means anything either.
    @Test("Leg E (m23-aw-3): extension-aware clause (d) — fixtures A/B/C/D, positive control first")
    func extensionAwareEnclosingTypeFixtures() throws {
        // A — @MainActor struct, POSITIVE CONTROL.
        let fixtureA = Self.numbered([
            "import Foundation",
            "import Testing",
            "",
            "@MainActor",
            "struct FixtureA {",
            "    @Test",
            "    func hog() {",
            "        Thread.sleep(forTimeInterval: 0.2)",
            "    }",
            "}",
        ])
        let sitesA = Self.hogSites(
            in: fixtureA, file: "FixtureA.swift", mainActorTypeNames: [], requireReachableFromDefaultTest: true)
        print("[measured] m23-aw-3 fixture A (positive control, @MainActor struct): \(sitesA.map(\.description))")
        try #require(sitesA.count == 1 && sitesA.first?.durationMilliseconds == 200, """
            POSITIVE CONTROL FAILED — the instrument itself is broken and nothing below this line in this \
            test means anything. Expected exactly 1 site at 200ms for an inline Thread.sleep directly \
            inside a @MainActor struct's own @Test. Found: \(sitesA.map(\.description)).
            """)

        // B — extension, type declared CROSS-FILE (the real-world shape:
        // `RecoveryAnchorContinuityGateTests` extends `RecoveryPlayheadTests`,
        // whose `@MainActor struct` lives in RecoveryPlayheadTests.swift).
        // Injected index simulates that cross-file scan finding `FixtureB`
        // positively isolated. THE PRE-FIX SCANNER REPORTED 0 HERE — this is
        // the false negative.
        let fixtureB = Self.numbered([
            "import Foundation",
            "import Testing",
            "",
            "extension FixtureB {",
            "    @Test",
            "    func hog() {",
            "        Thread.sleep(forTimeInterval: 0.2)",
            "    }",
            "}",
        ])
        let sitesB = Self.hogSites(
            in: fixtureB, file: "FixtureB.swift", mainActorTypeNames: ["FixtureB"],
            requireReachableFromDefaultTest: true)
        print("[measured] m23-aw-3 fixture B (extension, cross-file @MainActor type): \(sitesB.map(\.description))")
        #expect(sitesB.count == 1 && sitesB.first?.durationMilliseconds == 200, """
            the PRE-FIX scanner reported 0 sites here — this is exactly the shape of the missed \
            `RecoveryAnchorContinuityGateTests` regression (extension of a type whose @MainActor \
            declaration lives in a DIFFERENT file, resolved only through the cross-file index). Found: \
            \(sitesB.map(\.description)).
            """)

        // C — extension AFTER a @MainActor DECOY struct in the SAME file.
        // The extended type (`FixtureCD`) itself carries NO positive
        // evidence in the injected index. PRE-FIX, the scanner walked PAST
        // the extension line (never recognized as a type declaration at
        // all) to the nearest preceding struct/class/actor — the decoy —
        // and WRONGLY credited FixtureCD with the decoy's isolation
        // (reported 1 site: a false positive).
        let fixtureC = Self.numbered([
            "import Foundation",
            "import Testing",
            "",
            "@MainActor",
            "struct DecoyIsolated {}",
            "",
            "extension FixtureCD {",
            "    @Test",
            "    func hog() {",
            "        Thread.sleep(forTimeInterval: 0.2)",
            "    }",
            "}",
        ])
        let sitesC = Self.hogSites(
            in: fixtureC, file: "FixtureC.swift", mainActorTypeNames: [], requireReachableFromDefaultTest: true)

        // D — SEMANTICALLY IDENTICAL to C: same `extension FixtureCD`, same
        // true isolation for FixtureCD (absent from the index) — differing
        // ONLY in that the preceding decoy is PLAIN instead of @MainActor.
        // PRE-FIX, a file-layout-dependent scanner reported 0 sites here
        // (coincidentally "correct", but for the wrong reason — it read the
        // decoy's isolation, not FixtureCD's). This is the case that would
        // regress UNNOTICED: it silently disagreed with C, and a scanner
        // that silently disagrees on semantically identical code is not
        // reading the program, it is reading file layout.
        let fixtureD = Self.numbered([
            "import Foundation",
            "import Testing",
            "",
            "struct DecoyPlain {}",
            "",
            "extension FixtureCD {",
            "    @Test",
            "    func hog() {",
            "        Thread.sleep(forTimeInterval: 0.2)",
            "    }",
            "}",
        ])
        let sitesD = Self.hogSites(
            in: fixtureD, file: "FixtureD.swift", mainActorTypeNames: [], requireReachableFromDefaultTest: true)

        print("[measured] m23-aw-3 fixture C (extension after @MainActor decoy): \(sitesC.map(\.description))")
        print("[measured] m23-aw-3 fixture D (extension after plain decoy): \(sitesD.map(\.description))")

        #expect(sitesC.map(\.key).sorted() == sitesD.map(\.key).sorted(), """
            C and D are semantically IDENTICAL (`extension FixtureCD`, same true isolation for FixtureCD, \
            differing only in an UNRELATED preceding decoy struct) — a scanner whose answer depends on \
            file layout rather than program meaning would disagree here, which is exactly the pre-fix \
            m23-aw-3 defect. C: \(sitesC.map(\.description)); D: \(sitesD.map(\.description)).
            """)
        #expect(sitesC.isEmpty, """
            FixtureCD carries no positive @MainActor evidence anywhere in the injected index, so BOTH C \
            and D must report ZERO sites — a nonzero count here (even with C and D agreeing) would mean \
            the decoy is still leaking isolation in through some other path. Found: \
            \(sitesC.map(\.description)).
            """)

        // Optional fifth check (not in the original A-D table, cheap to add):
        // an extension of an index-positive type preceded by a PLAIN decoy —
        // proves the decoy cannot short-circuit the fix in the FALSE-NEGATIVE
        // direction either (a plain decoy must not suppress a real
        // cross-file @MainActor hit the way it used to coincidentally
        // "help" in fixture D above).
        let fixtureBWithPlainDecoy = Self.numbered([
            "import Foundation",
            "import Testing",
            "",
            "struct UnrelatedDecoy {}",
            "",
            "extension FixtureBPrime {",
            "    @Test",
            "    func hog() {",
            "        Thread.sleep(forTimeInterval: 0.2)",
            "    }",
            "}",
        ])
        let sitesBPrime = Self.hogSites(
            in: fixtureBWithPlainDecoy, file: "FixtureBPrime.swift", mainActorTypeNames: ["FixtureBPrime"],
            requireReachableFromDefaultTest: true)
        print("[measured] m23-aw-3 fixture B′ (cross-file @MainActor type, plain decoy precedes): "
              + "\(sitesBPrime.map(\.description))")
        #expect(sitesBPrime.count == 1 && sitesBPrime.first?.durationMilliseconds == 200, """
            a PLAIN decoy preceding the extension must not suppress a real cross-file @MainActor hit \
            (the false-negative mirror of fixture D). Found: \(sitesBPrime.map(\.description)).
            """)
    }

    /// The m23-aw-3 `Sources/` pass (step 4) needs its OWN anti-vacuity leg:
    /// `Sources/` carries no `@Test` anywhere, so the ONLY real Sources/
    /// candidate found by this item's own investigation
    /// (`mainActorWedgeDebug`'s `Thread.sleep`) lands in the UNRESOLVED
    /// channel (its duration is a caller-supplied parameter, not a source
    /// constant), not the resolved one — which means an
    /// `hogSitesIgnoringClauseE(Sources/).isEmpty` assertion would pass even
    /// if clause (e) bypass were silently broken (e.g. accidentally still
    /// requiring it). This fixture closes that gap directly: a `@MainActor`
    /// type with a fixed-duration `Thread.sleep` hog and NO `@Test` anywhere
    /// in the fixture must be found by `hogSitesIgnoringClauseE` (Sources
    /// mode) and MUST NOT be found by `hogSites` (Tests mode, clause (e)
    /// required) — turning the Sources/-pass design decision into an
    /// observed behavior rather than a comment asserting it.
    @Test("Leg E (m23-aw-3) anti-vacuity: Sources-mode (no @Test anywhere) differs from Tests-mode")
    func sourcesPassDistinguishesFromTestsPassOnAnUntestedFixture() {
        let fixture = Self.numbered([
            "import Foundation",
            "",
            "@MainActor",
            "final class ProductionHogFixture {",
            "    func blockingHelper() {",
            "        Thread.sleep(forTimeInterval: 0.2)",
            "    }",
            "}",
        ])
        let testsMode = Self.hogSites(
            in: fixture, file: "ProductionHogFixture.swift", mainActorTypeNames: [],
            requireReachableFromDefaultTest: true)
        let sourcesMode = Self.hogSitesIgnoringClauseE(
            in: fixture, file: "ProductionHogFixture.swift", mainActorTypeNames: [])
        print("[measured] m23-aw-3 anti-vacuity fixture — Tests mode: \(testsMode.map(\.description)), "
              + "Sources mode: \(sourcesMode.map(\.description))")
        #expect(testsMode.isEmpty, """
            a construct reachable from NO @Test anywhere must be excluded under clause (e) when clause (e) \
            is required (Tests mode) — found \(testsMode.map(\.description)) instead.
            """)
        #expect(sourcesMode.count == 1 && sourcesMode.first?.durationMilliseconds == 200, """
            the SAME construct must be found when clause (e) is bypassed (Sources mode) — otherwise the \
            Sources/ pass's expected-empty-set assertion below is vacuous (it would pass even if the \
            bypass were silently broken). Found \(sourcesMode.map(\.description)).
            """)
    }

    /// THE m23-aw-3 `Sources/` PASS ITSELF (step 4 of the filing). Clauses
    /// (a)-(d) only (clause (e) does not apply — see
    /// `hogSitesIgnoringClauseE`'s doc comment for why it is bypassed rather
    /// than silently required or silently skipped, and
    /// `sourcesPassDistinguishesFromTestsPassOnAnUntestedFixture` above for
    /// proof the bypass is not vacuous).
    ///
    /// ⚠️ NOT an unconditional empty-set rubber stamp: `unresolvedSites` is
    /// PINNED to the one real finding this item's own investigation turned
    /// up — `Sources/DAWApp/DAWProApp.swift`'s `mainActorWedgeDebug`, whose
    /// `Thread.sleep(forTimeInterval: clamped)` sits inside `@MainActor final
    /// class AppModel` (clauses (a)-(d) all satisfied) but whose duration is
    /// a CALLER-SUPPLIED parameter (0.5–30 s, clamped from `params["seconds"]`
    /// at the m18-b `debug.mainActorWedge` staging seam for the main-actor
    /// liveness watchdog), not a fixed constant in the source — legitimately
    /// failing clause (c), the same reason a `.wait()`'s child-process
    /// duration fails it (header comment above). That is a REAL, deliberate,
    /// documented main-actor block, disclosed here rather than hidden, and
    /// it is pinned by NAME so a second, different unresolvable Sources/
    /// blocker cannot silently join it unnoticed. `resolvedSites` (a genuine
    /// fixed-duration hog) IS held to a hard empty-set assertion — per this
    /// item's instruction, if that one is ever non-empty this test reports
    /// it rather than "fixing" Sources/ or weakening the assertion.
    @Test("Leg E (m23-aw-3): the Sources/ occupancy scan")
    func sourcesTreeHasNoUnaccountedFixedDurationHog() {
        let mainActorTypeNames = MainActorOccupancySiteTests.mainActorTypeNames
        var resolvedSites: [HogSite] = []
        var unresolvedSites: [String] = []
        for url in Self.allSourceSwiftFiles() {
            let lines = Self.lines(ofFileAt: url)
            resolvedSites += Self.hogSitesIgnoringClauseE(
                in: lines, file: url.lastPathComponent, mainActorTypeNames: mainActorTypeNames)
            unresolvedSites += Self.unresolvedMainActorCandidatesIgnoringClauseE(
                in: lines, file: url.lastPathComponent, mainActorTypeNames: mainActorTypeNames)
        }
        print("[measured] m23-aw-3 Sources/ occupancy scan — resolved (fixed-duration) sites: "
              + "\(resolvedSites.map(\.description).sorted())")
        print("[measured] m23-aw-3 Sources/ occupancy scan — unresolved (shape-matched, "
              + "unparseable-duration) candidates: \(unresolvedSites)")

        #expect(resolvedSites.isEmpty, """
            Sources/ contains \(resolvedSites.count) deliberate, FIXED-duration, main-actor-blocking \
            construct(s) — this is a REAL production finding, not a scanner defect. Report it; do not \
            "fix" Sources/ to make this pass and do not weaken this assertion. Found: \
            \(resolvedSites.map(\.description).sorted()).
            """)

        // Pin on (file, function) rather than the full message text, so a
        // benign rewording of the diagnostic does not false-fail this — the
        // SAME discipline Leg A/B use (`HogSite.key` excludes line number).
        // The message shape is `"<file>:<line> in <function> — ..."`
        // (`evaluate`'s two `.unresolved(...)` branches, both spin and
        // sleep); a message that does not parse into that shape gets its own
        // full-text fingerprint, which will simply fail to match the pinned
        // singleton below — deliberately loud, never silently ignored.
        let unresolvedFingerprints = Set(unresolvedSites.map { message -> String in
            guard let colonIdx = message.firstIndex(of: ":"),
                  let inRange = message.range(of: " in "),
                  let dashRange = message.range(of: " — ")
            else { return message }
            let file = String(message[message.startIndex..<colonIdx])
            let function = String(message[inRange.upperBound..<dashRange.lowerBound])
            return "\(file)|\(function)"
        })
        #expect(unresolvedFingerprints == ["DAWProApp.swift|mainActorWedgeDebug"], """
            the Sources/ pass's UNRESOLVED set moved from the one pinned, disclosed finding \
            (`mainActorWedgeDebug`'s caller-supplied Thread.sleep duration — legitimately unresolvable \
            under clause (c), documented above) — either a new unparseable main-actor blocker appeared in \
            Sources/ (a finding to report, not silence) or the pinned one changed shape. Found: \
            \(unresolvedSites).
            """)
    }

    // MARK: - The permanent discriminator (design §7.2 — no source edit required)

    /// Fixture text for the permanent discriminator: a synthetic file
    /// staging THREE hogs across both recognized duration-resolution paths —
    /// (1) a parameter-hop spin (mirrors `DeadlineRaceTests`), (2) a direct
    /// inline spin (mirrors `AUPrepareInFlightWedgeTests`), and (3) a
    /// `Thread.sleep` hog, whose `@Test` is optionally wrapped in
    /// `.enabled(if:)` — the anti-vacuity leg.
    private static func syntheticFixtureLines(thirdHogGated: Bool) -> [String] {
        let thirdAttribute = thirdHogGated
            ? "@Test(\"hog three — a Thread.sleep shape\", .enabled(if: false))"
            : "@Test(\"hog three — a Thread.sleep shape\")"
        return [
            "import Foundation",
            "import Testing",
            "",
            "final class FixtureWindow {}",
            "",
            "@MainActor",
            "@Suite(\"synthetic m23-aw discriminator fixture\")",
            "struct SyntheticFixtureTests {",
            "    private static func spinHelper(for duration: Duration, window: FixtureWindow) {",
            "        let clock = ContinuousClock()",
            "        let deadline = clock.now.advanced(by: duration)",
            "        while clock.now < deadline { /* spin */ }",
            "    }",
            "",
            "    @Test",
            "    func realHogOne() {",
            "        let hogDuration = Duration.milliseconds(1_000)",
            "        Self.spinHelper(for: hogDuration, window: FixtureWindow())",
            "    }",
            "",
            "    @Test(\"hog two — direct inline\")",
            "    func hogTwo() {",
            "        let clock = ContinuousClock()",
            "        let hogDuration = Duration.milliseconds(750)",
            "        let deadline = clock.now.advanced(by: hogDuration)",
            "        while clock.now < deadline { /* spin */ }",
            "    }",
            "",
            thirdAttribute,
            "    func hogThree() {",
            "        Thread.sleep(forTimeInterval: 2.0)",
            "    }",
            "}",
        ]
    }

    /// §7.2's law, verified rather than asserted-and-hoped: this discriminator
    /// needs NO source edit and re-validates the scanner on EVERY run, not
    /// once at authoring time. Three checks in one `@Test` (keeping the
    /// suite's test-count delta at exactly the pair the design's §8 predicts):
    /// the scanner finds a hog count Leg A's table does NOT contain (proving
    /// it is not hardcoded to 2), the synthetic total trips Leg B's budget
    /// shape, and `.enabled(if:)` makes the third hog — and only it —
    /// invisible again (proving clause (e) is implemented, not merely
    /// counting the word "while").
    @Test("Permanent discriminator (m23-aw §7.2): the scanner sees a NEW hog and respects .enabled(if:)")
    func scannerRecognizesSyntheticHogsAndRespectsGating() {
        let ungated = Self.numbered(Self.syntheticFixtureLines(thirdHogGated: false))
        let gated = Self.numbered(Self.syntheticFixtureLines(thirdHogGated: true))

        let ungatedSites = Self.hogSites(in: ungated, file: "SyntheticFixture.swift")
        let gatedSites = Self.hogSites(in: gated, file: "SyntheticFixture.swift")
        let ungatedTotal = ungatedSites.reduce(0) { $0 + $1.durationMilliseconds }

        print("[measured] m23-aw discriminator: ungated fixture found \(ungatedSites.count) site(s) "
              + "totaling \(ungatedTotal)ms: \(ungatedSites.map(\.description).sorted())")
        print("[measured] m23-aw discriminator: gated fixture found \(gatedSites.count) site(s): "
              + "\(gatedSites.map(\.description).sorted())")

        #expect(ungatedSites.count == 3, """
            the fixture stages exactly 3 hogs (1 parameter-hop, 1 direct-inline, 1 Thread.sleep) — Leg A's \
            set equality against the shipped 2-entry table would fail against this fixture, which is the \
            point: it proves the scanner is not hardcoded to the shipped count. Found \(ungatedSites.count).
            """)
        #expect(ungatedTotal > 3_000, """
            the synthetic total (\(ungatedTotal) ms) must exceed Leg B's 3000 ms budget, proving that leg \
            fires against a real regression shape and not only against today's tree.
            """)
        #expect(gatedSites.count == 2, """
            wrapping the third hog's @Test in .enabled(if:) must remove it — and ONLY it — proving clause \
            (e) is actually implemented rather than the scanner merely counting the word "while". Found \
            \(gatedSites.count).
            """)
        if gatedSites.count == 2 {
            #expect(Set(gatedSites.map(\.key)) == Set(ungatedSites.filter { $0.enclosingSymbol != "hogThree" }.map(\.key)),
                    "gating the third hog must leave the OTHER two sites exactly as found in the ungated fixture")
        }
    }
}
