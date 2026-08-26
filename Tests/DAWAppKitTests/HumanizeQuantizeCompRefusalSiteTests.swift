import Foundation
import Testing

/// m25-c-2 — the SOURCE-SHAPE half of refusing Humanize/Quantize on a take-comp
/// member. `CompMemberApplyRefusalTests` proves the two state machines; it cannot
/// see the three things that actually shipped the bug, all of which live in
/// `DAWApp`, an `executableTarget` with no test target:
///
///   1. the panels being handed the REAL refusal provider (a model wired to
///      nothing refuses nothing, and every model test would still pass),
///   2. `applyHumanize` / `applyQuantize` closing the panel UNCONDITIONALLY —
///      the half of the bug that makes the message a flash at an empty screen,
///   3. the panels rendering the sentence at all.
///
/// ⚠️ **THIS IS A SHAPE PIN, NOT A BEHAVIOURAL MEASUREMENT.** Nothing here sees a
/// pixel or a press. What is asserted is that the wiring is WRITTEN.
///
/// Idiom copied from `HumanizePanelSiteTests`: anchored to the repo via
/// `#filePath`, **comments stripped** so prose about a symbol cannot satisfy an
/// assertion about it — which matters more here than anywhere, because this item
/// wrote long doc comments naming `compRefusal`, `compEditRefusal` and
/// `takeGroupID`, and an unstripped `contains` would pass off the documentation
/// as the implementation. Every extractor carries a POSITIVE CONTROL against a
/// symbol known to be present, because a broken brace matcher and a genuinely
/// clean file produce the identical green.
@Suite("Humanize / Quantize comp refusal — app wiring (m25-c-2)")
struct HumanizeQuantizeCompRefusalSiteTests {

    // MARK: - Locating the tree

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

    /// Comments removed — see the suite note. Without this, every assertion in
    /// this file could be satisfied by the doc comments this item wrote.
    private static func codeOnly(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
        }.joined(separator: "\n")
    }

    private static func code(_ relativePath: String) -> String { codeOnly(text(relativePath)) }

    /// The text between the braces that OPEN at the end of `marker`. Returns nil
    /// when the marker is absent, which every caller treats as a FAILURE:
    /// "renamed" and "correct" must never look the same here.
    private static func bracedBody(after marker: String, in content: String) -> String? {
        guard let markerRange = content.range(of: marker) else { return nil }
        var depth = 1
        var out = ""
        var i = markerRange.upperBound
        while i < content.endIndex {
            let ch = content[i]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
            out.append(ch)
            i = content.index(after: i)
        }
        return nil
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var idx = haystack.startIndex
        while let r = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            count += 1
            idx = r.upperBound
        }
        return count
    }

    /// True when some line, ignoring indentation, is EXACTLY `statement`. Used for
    /// the negative pins: `contains("humanizeModel.apply()")` is satisfied by the
    /// fixed code too, so only a line-exact test can tell the old shape from the
    /// new one.
    private static func hasBareStatement(_ statement: String, in body: String) -> Bool {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.trimmingCharacters(in: .whitespaces) == statement }
    }

    private static let appPath = "DAWApp/DAWProApp.swift"

    // MARK: - Half one: the panel must survive the refusal

    @Test("applyHumanize closes ONLY when the apply actually fired")
    func humanizeClosesOnlyOnSuccess() {
        let app = Self.code(Self.appPath)
        guard let body = Self.bracedBody(after: "func applyHumanize() {", in: app) else {
            Issue.record("could not extract applyHumanize — the signature moved; FIX THE EXTRACTOR, do not assume the guard is fine")
            return
        }
        #expect(body.contains("closeHumanizePanel()"),
                "POSITIVE CONTROL FAILED: the extracted applyHumanize body does not even close the panel, so its verdict on the guard means nothing.")
        #expect(body.contains("guard humanizeModel.apply() else"),
                "applyHumanize does not consult whether the apply fired — a refusal will close the panel out from under its own message.")
        // POSITIVE CONTROL for the line-exact matcher itself: the close IS a bare
        // statement here. A matcher that always answered false would make the
        // negative pin below vacuous, and would look exactly like a pass.
        #expect(Self.hasBareStatement("closeHumanizePanel()", in: body),
                "POSITIVE CONTROL FAILED: the bare-statement matcher cannot see a statement that is plainly there.")
        #expect(!Self.hasBareStatement("humanizeModel.apply()", in: body),
                "applyHumanize still calls apply() as a bare statement, so the close below it is unconditional — the m25-c-2 bug, restored.")
    }

    @Test("applyQuantize closes ONLY when the apply actually fired")
    func quantizeClosesOnlyOnSuccess() {
        let app = Self.code(Self.appPath)
        guard let body = Self.bracedBody(after: "func applyQuantize() {", in: app) else {
            Issue.record("could not extract applyQuantize — the signature moved; FIX THE EXTRACTOR")
            return
        }
        #expect(body.contains("closeQuantizePanel()"),
                "POSITIVE CONTROL FAILED: the extracted applyQuantize body does not even close the panel.")
        #expect(body.contains("guard quantizeModel.apply() else"),
                "applyQuantize does not consult whether the apply fired. Quantize shipped this shape FIRST; a one-sided fix is the two-conventions problem the item exists to avoid.")
        #expect(Self.hasBareStatement("closeQuantizePanel()", in: body),
                "POSITIVE CONTROL FAILED: the bare-statement matcher cannot see a statement that is plainly there.")
        #expect(!Self.hasBareStatement("quantizeModel.apply()", in: body),
                "applyQuantize still calls apply() as a bare statement, so the close below it is unconditional.")
    }

    // MARK: - Half two: both models are handed the REAL provider

    /// A model built without `compRefusal` refuses nothing and every model test
    /// still passes — so this is the assertion that the fix is actually connected.
    /// TWO occurrences is the point: Humanize and Quantize, not one of them.
    @Test("BOTH models are constructed with the store's refusal provider")
    func bothModelsAskTheStore() {
        let app = Self.code(Self.appPath)
        #expect(app.contains("HumanizeModel("),
                "POSITIVE CONTROL FAILED: the app does not construct HumanizeModel at all.")
        #expect(app.contains("QuantizeModel("),
                "POSITIVE CONTROL FAILED: the app does not construct QuantizeModel at all.")
        let wired = Self.occurrences(of: "return store.compEditRefusal(clipID: clipID)", in: app)
        #expect(wired == 2,
                "expected BOTH panels wired to ProjectStore.compEditRefusal, found \(wired) site(s). One is worse than none: it leaves the same bug one menu away and gives one refusal two treatments.")
        #expect(Self.occurrences(of: "compRefusal: { [weak store] clipID in", in: app) == 2)
    }

    // MARK: - Half three: the sentence is rendered, beside a disabled Apply

    @Test("both panels render the store's sentence and dim Apply", arguments: [
        ("DAWApp/Humanize/HumanizePanel.swift", "APPLY HUMANIZE"),
        ("DAWApp/Quantize/QuantizePanel.swift", "APPLY QUANTIZE"),
    ])
    func panelsShowTheReason(path: String, applyLabel: String) {
        let panel = Self.code(path)
        #expect(panel.contains(applyLabel),
                "POSITIVE CONTROL FAILED: \(path) does not contain its own Apply button label, so nothing else asserted here is trustworthy.")
        #expect(panel.contains("if let refusal = model.refusalMessage {"),
                "\(path) never asks for the refusal message, so a disabled Apply has no explanation beside it — worse than the silence this replaces.")
        #expect(panel.contains("PanelRefusalLine(message: refusal)"),
                "\(path) does not render the shared refusal line.")
        #expect(panel.contains(".disabled(!model.canApply)"),
                "\(path) leaves Apply pressable while the store would refuse it.")
    }

    /// The shared component is genuinely shared. A view with one caller is not a
    /// shared convention, it is a moved one — and this item's whole hazard was
    /// growing a THIRD refusal-presentation home.
    @Test("PanelRefusalLine has more than one caller")
    func refusalLineIsShared() {
        let humanize = Self.code("DAWApp/Humanize/HumanizePanel.swift")
        let quantize = Self.code("DAWApp/Quantize/QuantizePanel.swift")
        let component = Self.code("DAWApp/Components/PanelRefusalLine.swift")
        #expect(component.contains("struct PanelRefusalLine: View"),
                "POSITIVE CONTROL FAILED: the component file does not declare the component.")
        #expect(component.contains("DAWTheme.record"),
                "the refusal line must wear the arrange bubble's amber warning token — the edit did not happen and nothing was destroyed.")
        let callers = Self.occurrences(of: "PanelRefusalLine(", in: humanize)
            + Self.occurrences(of: "PanelRefusalLine(", in: quantize)
        #expect(callers == 2, "expected 2 callers, found \(callers)")
    }

    // MARK: - The store query must stay the ASK FORM of the guard

    /// The one way this design rots: someone reimplements the question as
    /// `clip.takeGroupID != nil` and it drifts from the throw it exists to
    /// predict. The doc comment forbidding that is stripped before this runs, so
    /// this is a test of the code and not of its own instructions.
    @Test("compEditRefusal is implemented BY the guard, never by re-testing takeGroupID")
    func askFormCallsTheGuard() {
        let store = Self.code("DAWCore/ProjectStore.swift")
        guard let body = Self.bracedBody(after: "public func compEditRefusal(clipID: UUID) -> ProjectError? {",
                                         in: store) else {
            Issue.record("could not extract compEditRefusal — it was renamed or removed; FIX THE EXTRACTOR")
            return
        }
        #expect(body.contains("locateClip(clipID)"),
                "POSITIVE CONTROL FAILED: the extracted body does not locate the clip, so it is not the body.")
        #expect(body.contains("try requireNotCompMember("),
                "compEditRefusal no longer runs the guard it is supposed to predict.")
        #expect(!body.contains("takeGroupID"),
                "compEditRefusal re-tests takeGroupID itself — a second copy of the question, free to drift from the throw the panels are promising to predict.")
    }
}
