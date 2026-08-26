import Testing
import Foundation

/// m25-a-2 — **THE REFUSAL'S WIRING, PINNED AT THE SOURCE.**
///
/// ⚠️ **WHY A SOURCE-SITE PIN.** `ClipAutoExtendOutcomeTests` proves the outcome
/// is named correctly and that the store reports it. What it cannot see is
/// whether the VIEW asks, or whether `ContentView` still hands the message back.
/// `PianoRollView` lives in the DAWApp EXECUTABLE target, so no test can
/// construct it, and m23-g1 established that an unbundled staging binary routes
/// no real pointer events — so no `.mjs` gate can see this either. A silent
/// unwiring (a `_ =` swallowing the return, one of the two call sites dropped,
/// the store's `lastAutoExtendRefusal` no longer read) would restore the exact
/// reported silence and leave every other test in this repo green. This reddens.
///
/// ⚠️⚠️ **EVERY ASSERTION RUNS AGAINST COMMENT-STRIPPED SOURCE** (the
/// `PianoRollSnapPolicySiteTests` rule). All three files under test carry doc
/// comments naming every symbol asserted on below, so an unstripped `contains`
/// would pass on prose alone.
@Suite("m25-a-2 — the auto-extend refusal is WIRED at both call sites")
struct AutoExtendRefusalSiteTests {

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

    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"
    private static let contentPath = "DAWApp/ContentView.swift"
    private static let storePath = "DAWCore/ProjectStore.swift"

    private static func occurrences(_ needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    // MARK: - The store composes the words; the view never does

    /// ⛔⛔ **THE SWITCH MUST STAY EXHAUSTIVE.** `.notNeeded` is the ORDINARY
    /// case, and a `default:` would quietly fold it in with the refusals —
    /// firing an amber bubble on every note edit inside a clip. No fixture anyone
    /// writes for this function would catch it, because every fixture is a
    /// refusal. The compiler forcing a human to handle `.notNeeded` is the only
    /// instrument that sees this, and it only exists while there is no `default:`.
    @Test("⛔ the refusal-message switch is EXHAUSTIVE — no `default:` clause")
    func theMessageSwitchIsExhaustive() {
        guard let fn = Self.body(of: "autoExtendRefusalMessage", in: Self.text(Self.storePath)) else {
            Issue.record("`autoExtendRefusalMessage` is gone from ProjectStore — renamed or moved?")
            return
        }
        // Positive control: the extracted body IS the right function, so the
        // negative below is an absence and not a broken extractor.
        #expect(fn.contains("case .notNeeded, .grew"),
                "positive control failed — the extracted body does not handle `.notNeeded`, so nothing here proves anything")
        #expect(fn.contains("case .refusedByGrowthCap"))
        #expect(fn.contains("case .refusedByNeighbour"))
        #expect(fn.contains("case .refusedOnsetStillLatent"))
        #expect(fn.contains("default:") == false,
                "a `default:` in the refusal switch reintroduces the trap: it would warn on EVERY ordinary note edit")
    }

    /// The reason is derived in ONE headless home. A view that could switch on
    /// the outcome is one small edit away from composing its own sentence, which
    /// is the second home this item exists to prevent.
    @Test("⚠️ the ROLL never sees the outcome enum — it renders words it is handed")
    func theViewHoldsWordsNotReasons() {
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(Self.occurrences("ExtendOutcome", in: roll) == 0,
                "the roll is reaching for the outcome enum — the reason must be derived in DAWCore, not re-derived here")
        for name in ["refusedByGrowthCap", "refusedByNeighbour", "refusedOnsetStillLatent"] {
            #expect(Self.occurrences(name, in: roll) == 0,
                    "the roll names `\(name)` — a second home for the decision")
        }
        // Positive control: the needles ARE findable in the file that owns them,
        // so the zeros above are absences and not broken patterns.
        let store = Self.codeOnly(Self.text(Self.storePath))
        #expect(store.contains("ExtendOutcome"),
                "positive control failed — `ExtendOutcome` is unfindable in ProjectStore, so the counts above prove nothing")
        #expect(store.contains("refusedByNeighbour"),
                "positive control failed — `refusedByNeighbour` is unfindable in ProjectStore")
    }

    // MARK: - BOTH call sites, and the one that is easiest to leave silent

    /// ⭐ **TWO CALL SITES, AND THE DRAG PATH IS THE ONE THE USER REPORTED.**
    /// `commit(extendToCover:)` is the note-edit funnel (double-click-create AND
    /// m25-f-3's edge drag); the paste route is separate because it must not
    /// coalesce. Wiring only one leaves half the defect shipped.
    @Test("⚠️⚠️ BOTH roll funnels surface the refusal — the note funnel and PASTE")
    func bothFunnelsFlash() {
        let roll = Self.text(Self.rollPath)
        // ⚠️ THE PRECISE NEEDLE, WITH NO `?? body(of: "commit")` FALLBACK.
        // VERIFIED: `func commit(extendToCover:` resolves to the funnel at
        // PianoRollView.swift:1211. A loose `"commit"` fallback would ALSO
        // resolve today (prefix-matching the same declaration, and
        // `commitControllerLane` only at :3690) — which is exactly why it is
        // not here: it would keep this test green by landing on some other
        // `func commit…` the day this one is renamed, and "renamed" must never
        // look the same as "clean".
        guard let commitBody = Self.body(of: "commit(extendToCover:", in: roll) else {
            Issue.record("the `commit(extendToCover:)` funnel is gone from PianoRollView — renamed or moved?")
            return
        }
        // Positive control: the extracted body is the funnel (it engages).
        #expect(commitBody.contains("onEngage()"),
                "positive control failed — the extracted body is not the commit funnel, so the assertion below proves nothing")
        #expect(commitBody.contains("onCommit(") && commitBody.contains("flashAutoExtendNotice"),
                "the note-edit funnel drops the store's refusal on the floor — this is the double-click AND the edge drag")

        let code = Self.codeOnly(roll)
        #expect(code.contains("onPasteNotes(model.buildSubmission(), pastedIDs)"),
                "the paste call site is gone from PianoRollView — renamed or moved?")
        // The paste site must CONSUME the return. `_ = onPasteNotes(…)` or a
        // bare call would compile and be silent, which is the failure mode.
        #expect(code.contains("if let refusal = onPasteNotes("),
                "the PASTE path swallows the refusal — a refused paste is exactly as silent as the double-click was")
        #expect(code.contains("_ = onPasteNotes(") == false,
                "the paste return is being discarded")

        // Both closures must be declared as RETURNING the message, or the two
        // consumers above could not compile — pinned so a revert to `-> Void`
        // names itself.
        #expect(code.contains("var onCommit: (_ notes: [MIDINote], _ extendToCover: Set<UUID>) -> String?"))
        #expect(code.contains("var onPasteNotes: (_ notes: [MIDINote], _ extendToCover: Set<UUID>) -> String?"))
    }

    /// The store hop: `ContentView` returns the store's message VERBATIM from
    /// BOTH closures. Composing a string here instead would be the second home.
    @Test("⚠️ ContentView returns the STORE's message from both closures")
    func contentViewReturnsTheStoreMessage() {
        let content = Self.codeOnly(Self.text(Self.contentPath))
        // Positive control: a known neighbour of the wiring is present.
        #expect(content.contains("store.setClipNotes(clipID: clip.id, notes: notes,"),
                "positive control failed — the `onCommit` store call is unfindable, so nothing below proves anything")
        #expect(Self.occurrences("return store.lastAutoExtendRefusal", in: content) == 2,
                "expected exactly TWO store hops returning the refusal (onCommit + onPasteNotes) — one missing means one silent gesture")
        // And the app must never build the sentence itself.
        for word in ["16 bars", "Move the next clip"] {
            #expect(content.contains(word) == false,
                    "ContentView is composing refusal prose — the words belong to the store")
        }
    }

    // MARK: - The shared refusal component, not a third copy of it

    /// `ArrangeRefusalBubble`'s own doc: *"ONE component, two anchors… the
    /// callers own only the placement."* This is the third anchor, and it must
    /// reuse the component rather than hand-roll the amber chrome again.
    @Test("the roll's auto-extend chip uses the SHARED ArrangeRefusalBubble")
    func theChipReusesTheSharedComponent() {
        guard let bubble = Self.body(of: "autoExtendNoticeBubble", in: Self.text(Self.rollPath)) else {
            Issue.record("`autoExtendNoticeBubble` is gone from PianoRollView")
            return
        }
        #expect(bubble.contains("ArrangeRefusalBubble(message: autoExtendNotice)"),
                "the auto-extend chip must render the shared component, not a third copy of the amber chrome")
        // Transient and non-blocking (DESIGN-LANGUAGE): a modal for a note
        // placement would be worse than the silence.
        guard let flash = Self.body(of: "flashAutoExtendNotice", in: Self.text(Self.rollPath)) else {
            Issue.record("`flashAutoExtendNotice` is gone from PianoRollView")
            return
        }
        #expect(flash.contains("Task.sleep"), "the notice must auto-clear — it is transient chrome")
        #expect(flash.contains("autoExtendNoticeTask?.cancel()"),
                "a second refusal must restart the clock, not be erased by the first one's timer")
        #expect(flash.contains("autoExtendNotice = nil"), "the notice must clear itself")
    }

    /// The bar-ops notice is DELIBERATELY untouched: it predates the shared
    /// component and is tuned for the header cluster it hangs under. Pinned so a
    /// later "tidy-up" that unifies them is a deliberate decision rather than a
    /// silent visual change to a surface this item never examined.
    @Test("the bar-ops notice is left alone — its own chrome, its own anchor")
    func theBarOpsNoticeIsUnchanged() {
        guard let bubble = Self.body(of: "barOpsNoticeBubble", in: Self.text(Self.rollPath)) else {
            Issue.record("`barOpsNoticeBubble` is gone from PianoRollView")
            return
        }
        #expect(bubble.contains("frame(width: 240, alignment: .trailing)"),
                "the bar-ops notice changed shape — m25-a-2 deliberately did not touch it")
        #expect(bubble.contains("ArrangeRefusalBubble") == false,
                "converting the bar-ops notice is a visual change outside m25-a-2 — file it, do not smuggle it")
    }
}
