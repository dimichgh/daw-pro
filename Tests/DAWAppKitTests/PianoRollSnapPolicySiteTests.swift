import Testing
import Foundation

/// m25-ab — **THE WIRING, PINNED AT THE SOURCE.**
///
/// ⚠️ **WHY A SOURCE-SITE PIN.** `PianoRollSnapPolicyTests` proves the policy is
/// right. What it cannot see is whether the VIEW asks it, or whether
/// `ContentView` still hands it the app-level snap. That leg is reached only by
/// clicking a real chip in a real window, and m23-g1 established that nothing in
/// this tree can produce one: an unbundled staging binary does not route real
/// pointer or key events, so no `.mjs` gate can see this at all. A silent
/// unwiring — the `appSnap:` argument dropped at the call site, `effectiveSnap`
/// re-inlined as a ternary, the roll reading `snap` directly again — would restore
/// the exact reported bug and leave every other test in this repo green. This
/// reddens instead.
///
/// ⚠️⚠️ **EVERY ASSERTION RUNS AGAINST COMMENT-STRIPPED, BRACE/PAREN-MATCHED
/// SOURCE** (the `PianoRollPlayheadPlaceSiteTests` rule). Both files under test
/// now carry doc comments that name every symbol asserted on below, so an
/// unstripped `contains` would pass on prose alone.
@Suite("m25-ab — the note editor's snap is WIRED to the app-level snap")
struct PianoRollSnapPolicySiteTests {

    // MARK: - Helpers (the house pattern — each site suite carries its own)

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

    private static func text(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content
    }

    private static func codeOnly(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// The text BETWEEN the braces of `func <name>` — or `var <name>` — by brace
    /// matching. nil means "not found", which every caller treats as a FAILURE:
    /// "renamed" and "clean" must never look the same.
    private static func body(of name: String, in content: String) -> String? {
        let code = codeOnly(content)
        guard let decl = code.range(of: "func \(name)")
                ?? code.range(of: "var \(name)") else { return nil }
        guard let open = code.range(of: "{", range: decl.upperBound..<code.endIndex) else {
            return nil
        }
        var depth = 0
        var index = open.lowerBound
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(code[code.index(after: open.lowerBound)..<index])
                }
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// The ARGUMENT LIST of the call that opens at `marker` (which must end in
    /// `(`), by paren matching. `body(of:)`'s sibling for a call expression, which
    /// is not a declaration and has no braces of its own to match.
    ///
    /// ⚠️ Nested closures in the argument list contain braces AND parens; only
    /// parens are counted, and every `(` inside a nested closure is balanced by
    /// its own `)`, so the depth returns to zero exactly at the call's own close.
    private static func callArguments(openingAt marker: String, in content: String) -> String? {
        let code = codeOnly(content)
        guard marker.hasSuffix("("), let found = code.range(of: marker) else { return nil }
        var depth = 0
        var index = code.index(before: found.upperBound)   // the `(` itself
        while index < code.endIndex {
            let ch = code[index]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 {
                    return String(code[found.upperBound..<index])
                }
            }
            index = code.index(after: index)
        }
        return nil
    }

    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"
    private static let contentPath = "DAWApp/ContentView.swift"
    private static let policyPath = "DAWAppKit/PianoRollModel.swift"

    private func rollBody(_ name: String) -> String {
        let found = Self.body(of: name, in: Self.text(Self.rollPath))
        #expect(found != nil, "`\(name)` not found in \(Self.rollPath) — renamed?")
        #expect(found?.isEmpty == false, "`\(name)` body is empty")
        return found ?? ""
    }

    private func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - The view asks the policy, and asks nothing else

    @Test("⚠️ effectiveSnap is a thin read of SnapResolution.effective — not a second home")
    func effectiveSnapDelegatesToThePolicy() {
        let effective = rollBody("effectiveSnap")
        #expect(effective.contains("SnapResolution.effective("),
                "the roll must route through the ONE policy — an inline rule here IS the duplicated source of truth m25-ab exists to remove")
        for argument in ["appSnap:", "density:", "picked:"] {
            #expect(effective.contains(argument),
                    "`effectiveSnap` no longer passes `\(argument)` — an input silently dropped changes the answer without failing to compile")
        }
        // ⚠️ THE MUTANT THIS CATCHES: `appSnap == .off ? .off : (mode == .simple ...)`.
        // It behaves correctly TODAY and rebuilds the second home the moment the
        // policy changes — which is precisely how this bug was born.
        #expect(effective.contains(".simple") == false,
                "the density lock belongs to `SnapResolution.effective`, never here")
        #expect(effective.contains(".off") == false,
                "the OFF override belongs to `SnapResolution.effective`, never here")
    }

    @Test("⚠️⚠️ the app-level snap reaches the view as an INPUT, and the raw picker never does")
    func theViewDeclaresTheAppSnapInput() {
        let code = Self.codeOnly(Self.text(Self.rollPath))
        #expect(code.contains("var appSnap: ClipSnap"),
                "`PianoRollView` no longer accepts the app-level snap — the roll is back to being an island")
        // ⭐ THE ORIGINAL MEASUREMENT, KEPT AS A PIN. `grep -c clipSnap
        // PianoRollView.swift` was 0 and that WAS the bug; it must stay 0 for the
        // opposite reason. The roll takes the value in force through `appSnap`; a
        // `clipSnap` in here would mean it had reached past `ContentView` for the
        // RAW picker, re-deriving "is the app-level snap in force" as a third home.
        #expect(occurrences("clipSnap", in: code) == 0,
                "the roll must not reach for the raw `clipSnap` — it receives `effectiveClipSnap` as `appSnap`")
        // Positive control: the needle is a real one — it IS findable in the file
        // that owns it, so the zero above is an absence and not a broken pattern.
        #expect(Self.codeOnly(Self.text(Self.contentPath)).contains("clipSnap"),
                "positive control failed — `clipSnap` is unfindable in ContentView, so the count above proves nothing")
    }

    @Test("every snap consumer in the roll reads effectiveSnap, never the raw pick")
    func consumersReadTheEffectiveGrid() {
        // The placement producer is the user's reported gesture; the others are
        // the sites that would drift into a different grid if one were re-pointed.
        for name in ["placementLocalBeat"] {
            let text = rollBody(name)
            #expect(text.contains("effectiveSnap"),
                    "`\(name)` must apply the EFFECTIVE grid")
        }
        let code = Self.codeOnly(Self.text(Self.rollPath))
        // `snap` alone is the PICK and has exactly two legitimate readers: the
        // policy call and the menu's checkmark. Everything else goes through
        // `effectiveSnap`.
        #expect(code.contains("picked: snap"),
                "the policy call must pass the roll's own pick")
        #expect(code.contains("resolution: snap") == false,
                "a gesture reading the raw pick would bypass the OFF override — the reported bug, restored")
        #expect(code.contains("snap: snap") == false,
                "a band drawn from the raw pick would disagree with the gesture applied over it")
    }

    // MARK: - The chip cannot lie about the grid in force

    @Test("⚠️ the roll's SNAP chip renders the EFFECTIVE grid, while the checkmark marks the pick")
    func theChipReportsWhatIsInForce() {
        let picker = rollBody("snapPicker")
        #expect(picker.contains("SNAP: \\(effectiveSnap.label)"),
                "the chip must announce the grid actually in force — 'SNAP: 1/16' while nothing snaps is the duplicated-promise defect, reintroduced by its own fix")
        #expect(picker.contains("if snap == resolution"),
                "the checkmark must stay on the USER'S pick — it is intact and returns the moment the app-level snap comes back")
        #expect(picker.contains("snap = resolution"),
                "the menu must still write the roll's own resolution")
    }

    // MARK: - The app hands over the value IN FORCE, not the raw picker

    @Test("⚠️⚠️ ContentView passes effectiveClipSnap — the in-force value, not the raw picker")
    func contentViewFeedsTheInForceSnap() {
        let call = Self.callArguments(openingAt: "PianoRollView(",
                                      in: Self.text(Self.contentPath))
        #expect(call != nil, "the `PianoRollView(` call site is gone from ContentView — renamed or moved?")
        let args = call ?? ""
        // Positive control: a neighbouring argument IS in the extracted window, so
        // an assertion about what else is in it is a real assertion. Without this
        // a paren-matcher that returned "" would pass every negative below.
        #expect(args.contains("densityStore: model.panelDensity"),
                "positive control failed — the extracted argument list does not contain a known neighbour, so nothing below proves anything")
        #expect(args.contains("appSnap: model.effectiveClipSnap"),
                "the note editor is no longer told what snap is in force — this IS the m25-ab bug")
        // ⚠️ THE SUBTLE WRONG WIRING: the RAW picker. The toolbar chip renders only
        // when the arrange is Pro, so `clipSnap` can hold an `.off` the user cannot
        // see and does not have in force — a hidden preference silently unsnapping
        // the note editor. `effectiveClipSnap` is `.off` exactly when OFF is on screen.
        #expect(args.contains("appSnap: model.clipSnap") == false,
                "must pass `effectiveClipSnap`, not the raw picker — an invisible OFF would unsnap the roll at a distance")
    }

    // MARK: - The policy lives in the headless module, beside its precedent

    @Test("the policy is a pure static in DAWAppKit, the ClipSnap.effective precedent")
    func thePolicyLivesInTheHeadlessModule() {
        let policy = Self.codeOnly(Self.text(Self.policyPath))
        #expect(policy.contains("public static func effective(appSnap: ClipSnap, density: PanelDensity,"),
                "`SnapResolution.effective` is not where it belongs — the rule must stay headless-testable and UI-free")
        // It must not have grown a view/store dependency on the way in.
        #expect(policy.contains("import SwiftUI") == false,
                "DAWAppKit is SwiftUI-free by construction")
    }
}
