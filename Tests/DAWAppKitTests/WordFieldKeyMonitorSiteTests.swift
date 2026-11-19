import Foundation
import Testing

/// p2-sing-pr-words — THE WIRING of Return's key-monitor route (the sixth key class), which `DAWApp` (no test target)
/// is the only home of. `WordFieldKeyMonitorRoutingTests` owns the RULE; this owns that the app ASKS it, in the
/// right place, swallows only a key it handed to the roll, and routes on the OPEN roll's reported facts — never focus.
/// Design 2026-10-12 §6.2: "add a Return-branch order pin beside them" (`DeleteKeySiteTests` /
/// `EscapeKeyMonitorSiteTests`).
///
/// ⭐ A SOURCE-SHAPE GATE, USED ONLY WHERE NO SPY SEAM EXISTS. Assertions run on COMMENT-STRIPPED source.
/// ⚠️ NOT `@MainActor`: reading files needs no actor.
@Suite("Return rides the key monitor — the app's wiring (p2-sing-pr-words)")
struct WordFieldKeyMonitorSiteTests {

    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    /// The file's code with `//` and `///` comments stripped.
    private static func code(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// The INSIDE of the first braced block that opens at or after the start of `marker`, by brace matching.
    private static func block(after marker: String, in code: String) -> String? {
        guard let start = code.range(of: marker) else { return nil }
        guard let open = code[start.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 1
        var out = ""
        var index = code.index(after: open)
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
            out.append(ch)
            index = code.index(after: index)
        }
        return nil
    }

    private static let appPath = "DAWApp/DAWProApp.swift"

    private static func required(_ marker: String, in code: String) -> String {
        guard let body = block(after: marker, in: code) else {
            Issue.record("could not find `\(marker)` in \(appPath) — if it moved, move this test with it")
            return ""
        }
        return body
    }

    @Test("the reader reaches real code and strips comments (positive control)")
    func readerWorks() throws {
        let app = Self.code(Self.appPath)
        #expect(app.count > 100_000, "DAWProApp.swift came back suspiciously short: \(app.count) chars")
        #expect(app.contains("func handleKeyDownEvent(_ event: NSEvent) -> NSEvent? {"))
        let phrase = "THE SIXTH KEY CLASS: with notes selected"
        let raw = try String(contentsOf: Self.sourcesDir().appendingPathComponent(Self.appPath), encoding: .utf8)
        #expect(raw.contains(phrase), "the control phrase is gone from the raw file — pick another comment-only phrase")
        #expect(!app.contains(phrase), "the stripper left a comment in")
    }

    @Test("⭐ the monitor asks the Return predicate AFTER Escape's branch and BEFORE the space bar's, counts every Return, and swallows only a key it handed over")
    func theMonitorBranch() {
        let app = Self.code(Self.appPath)
        let monitor = Self.required("func handleKeyDownEvent(_ event: NSEvent) -> NSEvent? {", in: app)
        #expect(monitor.contains("WordFieldKeyMonitorRouting.decide("), "the monitor never asks the Return predicate")
        #expect(monitor.contains("if wordFieldDecision.refusedBy != .otherKey {"))
        #expect(monitor.contains("wordFieldKeyMonitorSeq += 1"))
        #expect(monitor.contains("wordFieldKeyMonitorRefusedBy = wordFieldDecision.refusedBy"))
        #expect(monitor.contains("guard wordFieldDecision.eligible else { return event }"),
                "a refused Return (a text field, another window, a chord, a repeat) is not passed on untouched")
        // ⛔ A monitor that swallowed every eligible Return would eat the default button of everything on screen.
        #expect(monitor.contains("return handleReturnFromKeyMonitor() ? nil : event"))
        // ORDER: Escape's branch, then Return's, then the space bar's — documentation, since the sets are disjoint
        // (`returnIsDisjointFromEveryOtherMonitorKey`), but the order this file's doc comment promises.
        let escape = monitor.range(of: "EscapeKeyMonitorRouting.decide(")
        let ret = monitor.range(of: "WordFieldKeyMonitorRouting.decide(")
        let space = monitor.range(of: "TransportKeyRouting.decide(")
        let typing = monitor.range(of: "return handleMusicalTypingKeyDown(event)")
        if let escape, let ret, let space, let typing {
            #expect(escape.lowerBound < ret.lowerBound, "Return's branch must come after Escape's")
            #expect(ret.lowerBound < space.lowerBound, "Return's branch must come before the space bar's")
            #expect(space.lowerBound < typing.lowerBound, "musical typing stays last")
        } else {
            Issue.record("a branch marker is missing: escape \(escape != nil) return \(ret != nil) space \(space != nil) typing \(typing != nil)")
        }
    }

    @Test("the hand-off routes on the OPEN roll, its reported selection and lane, and Escape's ONE blocked term — never focus")
    func theHandOff() {
        let app = Self.code(Self.appPath)
        let handOff = Self.required("func handleReturnFromKeyMonitor() -> Bool {", in: app)
        #expect(handOff.contains("WordFieldKeyMonitorRouting.route("))
        #expect(handOff.contains("open: openEditorSurface.reason,"))
        #expect(handOff.contains("rollHasSelection: pianoRollNoteSelection.hasSelection,"))
        #expect(handOff.contains("rollShowsWords: pianoRollNoteSelection.wordsShown,"))
        #expect(handOff.contains("blocked: escapeIsOwnedElsewhere)"))
        #expect(handOff.contains("pianoRollNoteSelection.requestWordField()"), "the roll is never handed the key")
        for forbidden in ["activeEditorSurface", "openEditorClip", "pianoRollEditorFocused", "KeyPressProbe"] {
            #expect(!handOff.contains(forbidden), "the hand-off reads `\(forbidden)` — a second route rule")
        }
    }
}
