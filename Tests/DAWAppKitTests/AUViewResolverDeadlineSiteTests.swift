import Foundation
import Testing

/// m23-au — the SOURCE-SHAPE pin for `AUViewResolver`'s deadline conversion.
///
/// `Sources/DAWApp/PluginUI/AUViewResolver.swift` used to hold the LAST
/// hand-rolled `Task.sleep`-plus-resume race in `Sources/`, complete with its own
/// duplicate `@MainActor ResumeGate`. Its "timeout" was main-actor-bound, so the
/// sleeper had to RE-ACQUIRE the main actor to fire — it could not fire while the
/// actor was contended, which is the exact case it existed for. m23-at removed the
/// same defect from `AUHostRegistry` and created `DAWCore.DeadlineRace`; m23-au
/// converted this file and deleted its gate. These legs stop that from coming back.
///
/// **WHY A SITE PIN AND NOT A BEHAVIOURAL TEST.** After the conversion there is
/// nothing left here to test that is not already tested: the adapter is a `switch`
/// over three enum cases around one call to an already-covered primitive, and
/// `Tests/DAWCoreTests/DeadlineRaceTests.swift` covers the behaviour (deadline
/// fires under main-actor contention; it does not fire spuriously; the once-gate
/// holds across executors). Inventing a `DAWAppKit` bridge type purely to have
/// something to instantiate would create exactly the second race implementation
/// this item exists to eliminate. Same idiom as `EditorSurfaceOwnershipSiteTests`,
/// `PollDisciplinePinTests`, `CanvasContractPinTests`, and the
/// `StartAnchorPolicySiteTests` / `RenderClockTrustSiteTests` pair in
/// `Tests/DAWEngineTests/`.
///
/// ⚠️ **A TOKEN SEARCH FINDS THE TOKEN, NOT THE BEHAVIOUR.** If one of these fails,
/// do not "fix" it by rewording the source. Every assertion names the failure it
/// exists to catch; read that first.
///
/// ⚠️ **THE 0-WARNING BUILD IS A MUCH WEAKER CHECK THAN IT LOOKS — MEASURED.** The
/// design's leg **B0** rests on `consider using asynchronous alternative function`.
/// Both shapes were measured on this toolchain:
///
///  · a DIRECT `au.requestViewController { … }` call in an `async` function
///    → the warning fires, and the 0-warning build rejects it;
///  · the SAME call nested inside `withCheckedContinuation`'s **non-async** closure
///    — which is precisely the shape that shipped here before m23-au — emits
///    **NO warning at all**. That is why this repo built 0-warning for months with
///    the defect in it.
///
/// So B0 catches only a careless direct call. It cannot catch a regression back to
/// the shape this item removed, and it cannot catch design alternative (A) (the
/// payload-free-enum + bridge form). **`S4` is the leg that guards the realistic
/// regression.** Do not let a green build stand in for it.
///
/// ⚠️ **S1 IS FILE-SCOPED ON PURPOSE — DO NOT GENERALISE IT.** `Task.sleep` appears
/// in ~20 files under `Sources/` (SwiftUI animation delays, sidecar poll loops,
/// retry backoff, `TransportBroadcaster`, and `DeadlineRace` itself). A tree-wide
/// sleep ban would be red on arrival for twenty legitimate uses. The property being
/// pinned is *"this file has no local deadline"*, not *"the tree has no sleeps"*.
/// The tree-wide leg is **S5**, which keys on `*ResumeGate` — measured unique.
///
/// **ANTI-VACUITY.** Every leg here asserts absence or presence in a file located at
/// run time, and a pin that silently finds no file is the cleanest possible green
/// and the most dangerous kind. `sourcesDir()`/`text(_:)` `Issue.record` when they
/// come up empty, `resolverCode()` additionally asserts the positive anchor
/// `enum AUViewResolver`, and S5 pins a floor on the number of files its walk
/// visited. Deleting `AUViewResolver.swift` outright must not pass this suite.
///
/// Anchored to the repo via `#filePath`, so it runs headless with no bundle
/// resources. The `sourcesDir()` / `text(_:)` / `codeOnly(_:)` / `body(of:in:)`
/// quartet is copied VERBATIM from `EditorSurfaceOwnershipSiteTests.swift`
/// (`:36`, `:53`, `:67`, `:85`) rather than re-derived — a second comment stripper
/// that drifted from the first would be its own small one-home violation.
@Suite("AUViewResolver deadline — the one-home source pins (m23-au)")
struct AUViewResolverDeadlineSiteTests {

    // MARK: - Locating the tree (verbatim from EditorSurfaceOwnershipSiteTests)

    /// Locate `<repo>/Sources` by walking up from this test file.
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
        // A pin test that silently finds no files reports the cleanest possible
        // green, which is the most dangerous kind. Say so loudly instead.
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

    /// Every line with comments removed: comment-only lines become empty, and a
    /// trailing `// …` is cut. THIS IS WHAT MAKES "ZERO" AN ASSERTABLE NUMBER —
    /// this suite's own doc comment and `AUViewResolver`'s new one both NAME
    /// `Task.sleep`, `ResumeGate` and `withCheckedContinuation` in order to explain
    /// what is forbidden, and that prose must SURVIVE without reddening anything.
    private static func codeOnly(_ content: String) -> [String] {
        content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }
    }

    /// The text BETWEEN the braces of `func <name>`, by brace matching from the
    /// declaration. Comments are stripped first, so a body's own prose cannot
    /// satisfy or violate an assertion about what it CALLS.
    ///
    /// Returns nil when the function cannot be found — which every caller treats
    /// as a FAILURE rather than as a vacuous pass, because "the function was
    /// renamed" and "the function is clean" must never look the same here.
    private static func body(of name: String, in content: String) -> String? {
        let code = codeOnly(content).joined(separator: "\n")
        guard let declRange = code.range(of: "func \(name)(") else { return nil }
        guard let openBrace = code.range(of: "{", range: declRange.upperBound..<code.endIndex) else {
            return nil
        }
        var depth = 0
        var out = ""
        var index = openBrace.lowerBound
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
            if depth >= 1 { out.append(ch) }
            index = code.index(after: index)
        }
        return nil
    }

    // MARK: - Local helpers

    private static let resolverPath = "DAWApp/PluginUI/AUViewResolver.swift"

    /// The adapter this item converted, and the name every leg brace-matches on.
    private static let adapter = "requestViewControllerOnMain"

    /// Comments-stripped source of `AUViewResolver.swift`, WITH the anti-vacuity
    /// anchor asserted on every read. Without the anchor, deleting the file would
    /// make every absence leg trivially true.
    private static func resolverCode() -> String {
        let code = codeOnly(text(resolverPath)).joined(separator: "\n")
        let anchor = "`enum AUViewResolver` is not in the code of \(resolverPath). Every leg in "
            + "this suite asserts the ABSENCE of something, so a missing or renamed file would "
            + "pass all of them at once. If the type moved, move this anchor with it."
        #expect(code.contains("enum AUViewResolver"), "\(anchor)")
        return code
    }

    private static func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The text of one `switch` arm: from `case <label>:` up to the next `case `
    /// or the end of the body. Returns nil when the arm is absent, which every
    /// caller reports rather than skipping.
    ///
    /// ⚠️ KNOWN FRAGILITY, recorded rather than fixed: it cuts at the FIRST
    /// `case ` in the remainder, so an arm whose body itself contains `if case …`
    /// or a nested `switch` would be truncated and could produce a FALSE RED. Not
    /// hypothetical — `if case .value(let n) = outcome` is idiomatic here. If you
    /// are adding one, extend this to brace/`case`-depth tracking; do not "fix" the
    /// production code to keep the string search happy.
    private static func arm(_ label: String, in switchBody: String) -> String? {
        guard let start = switchBody.range(of: "case \(label):") else { return nil }
        let rest = switchBody[start.upperBound...]
        if let next = rest.range(of: "case ") {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    /// Does this (already comments-stripped) source DECLARE a type whose name ends
    /// in `ResumeGate`? Token-based rather than substring-based, so that USING the
    /// keeper — `let gate = DeadlineResumeGate<T>(continuation)` — is not mistaken
    /// for declaring a rival one.
    private static func declaresResumeGateType(_ code: String) -> Bool {
        let keywords: Set<String> = ["class", "struct", "actor", "enum", "protocol", "typealias"]
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let tokens = line
                .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
                .map(String.init)
            for (i, token) in tokens.enumerated() where keywords.contains(token) {
                if i + 1 < tokens.count, tokens[i + 1].hasSuffix("ResumeGate") { return true }
            }
        }
        return false
    }

    // MARK: - S1: no local deadline

    @Test("S1 — AUViewResolver has no `Task.sleep`: the m23-au defect, by name")
    func noLocalTaskSleep() {
        let code = Self.resolverCode()
        let note = "\(Self.resolverPath) contains `Task.sleep`. A local sleep here IS the m23-au "
            + "defect: `Task { @MainActor in try? await Task.sleep(for: timeout) }` has to "
            + "RE-ACQUIRE the main actor to fire, so it is a sleep plus an unbounded queueing "
            + "delay and it cannot fire while the actor is contended — which is the only case a "
            + "plug-in-view timeout exists for. The deadline belongs on `DeadlineRace`'s "
            + "`Task.detached`, not here."
        #expect(!code.contains("Task.sleep"), "\(note)")
    }

    // MARK: - S2: no second once-gate in this file

    @Test("S2 — AUViewResolver declares no `ResumeGate` of its own")
    func noLocalResumeGate() {
        let code = Self.resolverCode()
        let classNote = "\(Self.resolverPath) declares `class ResumeGate` again. m23-au deleted "
            + "it precisely so the tree has ONE once-gate. `DeadlineResumeGate` in "
            + "`DAWCore/DeadlineRace.swift` is the keeper; it is NSLock-guarded because its two "
            + "resumers live on different executors, which a `@MainActor` copy here can never be."
        #expect(!code.contains("class ResumeGate"), "\(classNote)")
        // The broader form: any identifier ENDING in `ResumeGate`, so renaming the
        // copy `ViewRequestResumeGate` does not slip past the line above.
        let anyNote = "\(Self.resolverPath) mentions an identifier ending in `ResumeGate` in "
            + "CODE. Renaming a rival gate does not make it one home. See S5 for the tree-wide "
            + "version of this rule."
        #expect(!code.contains("ResumeGate"), "\(anyNote)")
    }

    // MARK: - S3: exactly one race, and it is inside the adapter

    @Test("S3 — exactly one `DeadlineRace.run(`, inside `requestViewControllerOnMain`")
    func exactlyOneDeadlineRaceInsideTheAdapter() {
        let code = Self.resolverCode()
        let fileCount = Self.occurrences("DeadlineRace.run(", in: code)
        // 0 means somebody deleted the call and hand-rolled a race again; 2 means a
        // SECOND racing decision appeared in this file, which is the same one-home
        // violation wearing the right type.
        let countNote = "expected exactly 1 `DeadlineRace.run(` in \(Self.resolverPath), found "
            + "\(fileCount). 0 = the conversion was undone; 2+ = a second racing decision now "
            + "lives in this file."
        #expect(fileCount == 1, "\(countNote)")

        guard let adapterBody = Self.body(of: Self.adapter, in: Self.text(Self.resolverPath))
        else {
            // A missing function must never read as a clean pass on this assertion.
            let missing = "could not find `func \(Self.adapter)(` in \(Self.resolverPath) — if "
                + "it was renamed, RENAME IT HERE TOO"
            Issue.record("\(missing)")
            return
        }
        let insideNote = "`\(Self.adapter)`'s own body does not call `DeadlineRace.run(`. The "
            + "race must be IN the adapter: hoisting it to a caller puts the deadline decision "
            + "somewhere this suite cannot see it, which is how the last one survived."
        #expect(Self.occurrences("DeadlineRace.run(", in: adapterBody) == 1, "\(insideNote)")
    }

    // MARK: - S4: the one-home leg

    @Test("S4 — AUViewResolver hand-rolls no continuation (the leg the 0-warning build cannot be)")
    func noHandRolledContinuation() {
        let code = Self.resolverCode()
        // ⚠️ THIS IS THE LEG THAT MATTERS. The shape m23-au removed — a
        // completion-handler call nested in `withCheckedContinuation`'s non-async
        // closure — emits NO compiler warning (measured). The build gated nothing;
        // this does.
        let checkedNote = "\(Self.resolverPath) uses `withCheckedContinuation`. That is how the "
            + "pre-m23-au race was built, and it is WARNING-FREE — measured: the completion "
            + "handler call only warns when it sits DIRECTLY in an `async` function, not when it "
            + "is wrapped in a continuation's non-async closure. So the 0-warning build cannot "
            + "catch this and this assertion is the only thing that can. Use the SDK's async "
            + "import, `await au.requestViewController()`, through `DeadlineRace`."
        #expect(!code.contains("withCheckedContinuation"), "\(checkedNote)")
        let unsafeNote = "\(Self.resolverPath) uses `withUnsafeContinuation` — the same rebuild "
            + "as above with the checking turned off, which is strictly worse: an orphaned "
            + "unsafe continuation does not even log."
        #expect(!code.contains("withUnsafeContinuation"), "\(unsafeNote)")
    }

    // MARK: - S5: tree-wide — one `*ResumeGate` declaration, and it is DeadlineRace's

    @Test("S5 — the ONLY `*ResumeGate` type declared under Sources/ is DeadlineRace's")
    func resumeGateDeclarationsAreUniqueToDeadlineRace() {
        let root = Self.sourcesDir()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate \(root.path)")
            return
        }
        // ⚠️ SCOPED TO Sources/ DELIBERATELY: this suite's own prose says
        // `ResumeGate` several times, so a walk that reached Tests/ would redden
        // itself.
        let prefix = root.standardizedFileURL.path + "/"
        var visited = 0
        var declaring: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            visited += 1
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("could not read \(url.path)")
                continue
            }
            guard Self.declaresResumeGateType(Self.codeOnly(content).joined(separator: "\n"))
            else { continue }
            let path = url.standardizedFileURL.path
            declaring.insert(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
        }

        // ANTI-VACUITY: a walk that found nothing reports an empty set, and an
        // empty set passes any one-sided "nobody else declares one" phrasing. Pin
        // the visit count too. MEASURED 2026-08-03: 320 `.swift` files under
        // Sources/. The floor is loose on purpose — it is a broken-walk detector,
        // not a file census.
        let floorNote = "the Sources/ walk visited \(visited) Swift files; expected at least "
            + "200 (320 measured 2026-08-03). A walk that finds nothing passes this leg's real "
            + "assertion for free, so the count is part of the test."
        #expect(visited >= 200, "\(floorNote)")

        // BOTH DIRECTIONS. `==` and not `⊆`: the keeper must still be there (a
        // deleted `DeadlineResumeGate` would otherwise satisfy a ban), and nobody
        // else may have one.
        let setNote = "files under Sources/ declaring a `*ResumeGate` type: "
            + "\(declaring.sorted().joined(separator: ", ")) — expected exactly "
            + "DAWCore/DeadlineRace.swift. A NEW one is the next hand-rolled gate: route the "
            + "work through `DAWCore.DeadlineRace` instead. A MISSING one means the keeper was "
            + "deleted or renamed, and every ban in this suite just became vacuous."
        #expect(declaring == ["DAWCore/DeadlineRace.swift"], "\(setNote)")
    }

    // MARK: - S6: resolve's three branches (the PRE-EXISTING half of the distinction)

    @Test("S6 — `resolve` still distinguishes vc / nil / timedOut as three branches")
    func resolveKeepsThreeDistinctBranches() {
        _ = Self.resolverCode()   // anti-vacuity anchor
        guard let resolveBody = Self.body(of: "resolve", in: Self.text(Self.resolverPath)) else {
            let missing = "could not find `func resolve(` in \(Self.resolverPath) — a missing "
                + "function must never read as a clean pass here"
            Issue.record("\(missing)")
            return
        }
        // Brace-matched on purpose: the ADAPTER's body legitimately contains
        // `case .timedOut:` and `.viewController(nil)`, so a whole-file `contains`
        // would stay green through exactly the collapse this leg exists to catch.
        for token in ["case .viewController(let vc?)",
                      "case .viewController(nil)",
                      "case .timedOut"] {
            let note = "`resolve` no longer has a distinct `\(token)` branch. The three outcomes "
                + "are NOT interchangeable: a v2 unit legitimately returns nil and must fall "
                + "through to the CocoaUI/generic ladder SILENTLY, while a timeout must fall "
                + "through carrying the user-facing \"custom view request timed out after 5s\" "
                + "warning. Collapsing them either invents a warning nobody should see or "
                + "deletes one somebody needs."
            #expect(resolveBody.contains(token), "\(note)")
        }
    }

    // MARK: - S8: the adapter's arms (the half m23-au INTRODUCED)

    @Test("S8 — the adapter maps each DeadlineOutcome to its OWN RequestOutcome case")
    func adapterMapsEachOutcomeToItsOwnCase() {
        _ = Self.resolverCode()   // anti-vacuity anchor
        guard let adapterBody = Self.body(of: Self.adapter, in: Self.text(Self.resolverPath))
        else {
            let missing = "could not find `func \(Self.adapter)(` in \(Self.resolverPath)"
            Issue.record("\(missing)")
            return
        }
        // WHY THIS LEG EXISTS AND S6 IS NOT ENOUGH: swapping an arm here — say
        // `case .timedOut: return .viewController(nil)` — leaves S1–S6 green and
        // the build clean, while silently deleting the timeout warning for every
        // timeout that ever fires. S6 pins the half of the distinction that
        // pre-dates m23-au (inside `resolve`); this pins the half m23-au created.
        guard let timedOutArm = Self.arm(".timedOut", in: adapterBody) else {
            let missing = "`\(Self.adapter)` has no `case .timedOut:` arm — the deadline outcome "
                + "must be handled explicitly, never folded into a `default`"
            Issue.record("\(missing)")
            return
        }
        let timedOutNote = "`\(Self.adapter)`'s `.timedOut` arm does not `return .timedOut`. A "
            + "deadline that reports itself as \"no custom view\" is INVISIBLE: `resolve` falls "
            + "through to the generic body with NO warning, so a stalled plug-in looks exactly "
            + "like a plain v2 unit and the 5 s the user waited is never explained."
        #expect(timedOutArm.contains("return .timedOut"), "\(timedOutNote)")
        let leakNote = "`\(Self.adapter)`'s `.timedOut` arm mentions `.viewController` — that is "
            + "the swap this leg exists to catch, in the direction that loses the warning."
        #expect(!timedOutArm.contains(".viewController"), "\(leakNote)")

        guard let valueArm = Self.arm(".value(let vc)", in: adapterBody) else {
            let missing = "`\(Self.adapter)` has no `case .value(let vc):` arm — the work result "
                + "must be forwarded, and the binding name is what this leg reads"
            Issue.record("\(missing)")
            return
        }
        let valueNote = "`\(Self.adapter)`'s `.value` arm does not `return .viewController(vc)`. "
            + "The nil-ness of the VC is load-bearing all the way to `resolve`: `.value(nil)` is "
            + "a unit with no custom v3 view (normal, silent) and must NOT be reported as a "
            + "timeout, which would put a false \"timed out after 5s\" warning on every v2 unit."
        #expect(valueArm.contains("return .viewController(vc)"), "\(valueNote)")
        let swapNote = "`\(Self.adapter)`'s `.value` arm returns `.timedOut` — the swap in the "
            + "other direction, which warns about a timeout that never happened."
        #expect(!valueArm.contains("return .timedOut"), "\(swapNote)")
    }
}
