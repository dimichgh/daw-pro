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
// recognized shapes is `m23-aw-3`.
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

    /// Locate `<repo>/Tests` by walking up from this test file (`#filePath`),
    /// anchored on the presence of `Sources/DAWEngine` as a repo-root marker
    /// — no bundle resources, runs headless under `./scripts/test.sh`.
    private static func testsRootDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let anchor = dir.appendingPathComponent("Sources/DAWEngine", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: anchor.path, isDirectory: &isDir), isDir.boolValue {
                return dir.appendingPathComponent("Tests", isDirectory: true)
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate <repo>/Tests from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func allTestSwiftFiles() -> [URL] {
        let root = testsRootDir()
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

    /// D2 — the enclosing TYPE (nearest preceding column-0 struct/class/actor
    /// declaration) carries `@MainActor`.
    private static func enclosingTypeIsMainActor(
        forDeclLine line: Int, in code: [(number: Int, text: String)]
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
        enclosingFunc: (name: String, declLine: Int), siteLine: Int, code: [(number: Int, text: String)]
    ) -> Bool {
        hasMainActorAttributeAbove(declLine: enclosingFunc.declLine, in: code)
            || enclosingTypeIsMainActor(forDeclLine: enclosingFunc.declLine, in: code)
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
        _ candidate: Candidate, code: [(number: Int, text: String)], file: String
    ) -> Outcome {
        guard let enclosingFunc = enclosingFunction(ofLine: candidate.line, in: code) else {
            return .shapeIncomplete
        }
        if candidate.kind == .spin {
            let body = braceBlockText(from: candidate.line, in: code)
            if body.contains("await") { return .excludedSuspends }
        }
        guard passesClauseD(enclosingFunc: enclosingFunc, siteLine: candidate.line, code: code) else {
            return .excludedNotMainActor
        }
        guard passesClauseE(enclosingFunc: enclosingFunc, code: code) else {
            return .excludedGated
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
    static func hogSites(in lines: [(number: Int, text: String)], file: String) -> [HogSite] {
        let code = nonCommentLines(lines)
        return candidates(in: code).compactMap { candidate in
            if case .resolved(let site) = evaluate(candidate, code: code, file: file) { return site }
            return nil
        }
    }

    /// The loud-failure companion to `hogSites`: main-actor-context,
    /// ungated candidates whose duration could NOT be resolved. Not part of
    /// `hogSites`'s own signature (design §7.2 pins that signature exactly),
    /// but consumed by Leg A so an unresolvable site fails the suite instead
    /// of silently vanishing from the ledger.
    static func unresolvedMainActorCandidates(in lines: [(number: Int, text: String)], file: String) -> [String] {
        let code = nonCommentLines(lines)
        return candidates(in: code).compactMap { candidate in
            if case .unresolved(let message) = evaluate(candidate, code: code, file: file) { return message }
            return nil
        }
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

    /// Summed nominal hog duration must stay <= 3000 ms — today's measured
    /// total (design §1.7/§6.2). RATCHET, not a computed capacity.
    ///
    /// ⚠️ As of m23-aw's own close (2026-08-03/04): NO PASSING
    /// `scripts/gates/m23aw-prepare-headroom.mjs` CAMPAIGN EXISTS to paste
    /// per step (3) below — both real 5-run campaigns run at that item's
    /// close FAILED (`THRESHOLD_EXCEEDED`, worst 47.360 s then 45.925 s),
    /// and the second failure's own campaign PASSED the validity leg
    /// (median wall 118.473 s <= 120 s) while still landing T1 at 45.925 s
    /// — see m23-aw-4, a measured calibration gap between the 120 s
    /// validity limit and the 36 s threshold, not yet re-derived. A future
    /// author raising this bound is stuck at step (3)'s ritual until either
    /// a clean idle-machine campaign passes or m23-aw-4 lands; do not treat
    /// that as licence to skip the paste, and do not tighten either
    /// constant unilaterally to manufacture a pass.
    @Test("Leg B — THE BUDGET: summed deliberate main-actor hog duration stays <= 3000 ms")
    func budgetStaysUnderThreeSeconds() {
        let found = Self.allHogSites()
        let total = found.reduce(0) { $0 + $1.durationMilliseconds }
        print("[measured] m23-aw total deliberate main-actor spin: \(total) ms across \(found.count) site(s)")
        #expect(total <= 3_000, """
            total deliberate main-actor occupancy is \(total) ms, over the 3000 ms budget. Per design §6.2: \
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
