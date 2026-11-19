import Foundation
import Testing

/// m34-k — THE WIRING of Escape's key-monitor route, which `DAWApp` (no test
/// target) is the only home of. `EscapeKeyMonitorRoutingTests` owns the RULE;
/// this owns that the app ASKS it, hands the key to the pane that owns the
/// effect, passes everything else on, and keeps the two Escape consumers that
/// answer through a KEY EQUIVALENT out of reach of BOTH routes — the monitor
/// and the `.onKeyPress` mounts each see a plain Escape before a key equivalent
/// does (measured, m23-ap I7b-2 A/B).
///
/// ⭐ A SOURCE-SHAPE GATE, USED ONLY WHERE NO SPY SEAM EXISTS — the staging
/// probe reads the editors' STATE for every verdict; this pins the shape that
/// makes those verdicts reproducible. Assertions run on COMMENT-STRIPPED source,
/// for `PitchEditorInteractionSiteTests`' reason: these files document their
/// own rules in prose a naive grep would accept.
///
/// ⚠️ NOT `@MainActor`: reading files needs no actor.
@Suite("Escape rides the key monitor — the app's wiring (m34-k)")
struct EscapeKeyMonitorSiteTests {

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

    /// The INSIDE of the first braced block that opens at or after the START of
    /// `marker` (so a marker may end with its own `{`), by brace matching, or
    /// nil. The braces themselves are not included, so the first non-empty line
    /// is the block's first statement.
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
    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"
    private static let panePath = "DAWApp/PitchEditor/PitchEditorView.swift"
    private static let contentPath = "DAWApp/ContentView.swift"

    private static func required(_ marker: String, in code: String, _ path: String) -> String {
        guard let body = block(after: marker, in: code) else {
            Issue.record("could not find `\(marker)` in \(path) — if it moved, move this test with it")
            return ""
        }
        return body
    }

    @Test("the reader reaches real code and strips comments (positive control)")
    func readerWorks() throws {
        let app = Self.code(Self.appPath)
        #expect(app.count > 100_000, "DAWProApp.swift came back suspiciously short: \(app.count) chars")
        #expect(app.contains("func handleKeyDownEvent(_ event: NSEvent) -> NSEvent? {"))
        // A phrase that exists ONLY in a comment: present in the raw file, gone
        // from the stripped one — so every `!contains` below is a real negative.
        let phrase = "THE FOURTH KEY RESCUED FROM SwiftUI FOCUS, AND THE"
        let raw = try String(contentsOf: Self.sourcesDir().appendingPathComponent(Self.appPath), encoding: .utf8)
        #expect(raw.contains(phrase), "the control phrase is gone from the raw file — pick another comment-only phrase")
        #expect(!app.contains(phrase), "the stripper left a comment in")
    }

    @Test("the key monitor asks the Escape predicate, counts every Escape, and swallows ONLY a key it handed over")
    func theMonitorBranch() {
        let app = Self.code(Self.appPath)
        let monitor = Self.required("func handleKeyDownEvent(_ event: NSEvent) -> NSEvent? {", in: app, Self.appPath)
        #expect(monitor.contains("EscapeKeyMonitorRouting.decide("), "the monitor never asks the Escape predicate")
        #expect(monitor.contains("isRepeat: event.isARepeat,"), "the predicate is not told about repeats — a held Escape walks the ladder")
        #expect(monitor.contains("if escapeDecision.refusedBy != .otherKey {"))
        #expect(monitor.contains("escapeKeyMonitorSeq += 1"))
        #expect(monitor.contains("guard escapeDecision.eligible else { return event }"),
                "a refused Escape (a text field, another window, a chord, a repeat) is not passed on untouched")
        // ⛔ THE PLANT THIS CATCHES: a monitor that swallows every eligible Escape
        // would eat a sheet's, a popover's and the explain mode's dismissal.
        #expect(monitor.contains("return handleEscapeFromKeyMonitor() ? nil : event"),
                "the monitor no longer passes Escape on when nothing open would take it")
    }

    @Test("the hand-off routes on the OPEN pane and its reported selection — never engagement, never focus — and hands the key to the pane's own Escape path")
    func theHandOff() {
        let app = Self.code(Self.appPath)
        let handOff = Self.required("func handleEscapeFromKeyMonitor() -> Bool {", in: app, Self.appPath)
        #expect(handOff.contains("EscapeKeyMonitorRouting.route("))
        #expect(handOff.contains("open: openEditorSurface.reason,"))
        #expect(handOff.contains("rollHasSelection: pianoRollNoteSelection.hasSelection,"))
        #expect(handOff.contains("pitchEditorHasSelection: pitchEditorInteraction.hasNoteSelection,"))
        #expect(handOff.contains("blocked: escapeIsOwnedElsewhere)"))
        #expect(handOff.contains("pianoRollNoteSelection.requestEscape()"), "the roll is never handed the key")
        #expect(handOff.contains("pitchEditorInteraction.requestEscape()"), "the note editor pane is never handed the key")
        #expect(handOff.contains("case nil: return false"))
        for forbidden in ["activeEditorSurface", "openEditorClip", "pianoRollEditorFocused", "KeyPressProbe"] {
            #expect(!handOff.contains(forbidden), "the hand-off reads `\(forbidden)` — a second route rule")
        }
        // The hand-off applies NO rung itself: the pane re-asks the one ladder.
        #expect(!handOff.contains("setEditorMaximized"), "the hand-off applies a rung the pane should apply")
    }

    @Test("ONE `blocked` term for both routes: a modal, a live text field and the explain mode own Escape")
    func oneBlockedTerm() {
        let app = Self.code(Self.appPath)
        let owned = Self.required("var escapeIsOwnedElsewhere: Bool {", in: app, Self.appPath)
        #expect(owned.contains("isModalPresented"))
        #expect(owned.contains("isArrangeTextEditingFocused"))
        #expect(owned.contains("explain.isActive"),
                "the explain mode's Escape (a key equivalent) is not protected — the monitor AND the mounts run before key equivalents")
        let mount = Self.required("func handleEditorEscape(gestureLive: Bool, hasSelection: Bool) -> EditorEscapeRung {",
                                  in: app, Self.appPath)
        #expect(mount.contains("blocked: escapeIsOwnedElsewhere)"), "the mount route and the monitor route ask different blocked terms")
    }

    @Test("the \"Replace your hand edits?\" card is a BLOCKING modal — Escape cancels it, and ⌫ cannot reach behind it")
    func thePresetCardIsAModal() {
        let app = Self.code(Self.appPath)
        let modal = Self.required("var isModalPresented: Bool {", in: app, Self.appPath)
        #expect(modal.contains("quantizePanelClipID"), "POSITIVE CONTROL: the extractor cannot see a modal that was already listed")
        #expect(modal.contains("pitchPresetReplaceGate.pending != nil"),
                "the preset card is not in isModalPresented — the key monitor would eat its Escape")
        #expect(!modal.contains("showEngineNotices"), "NEGATIVE CONTROL: the passive banner is excluded on purpose")
    }

    /// m23-ap I1 UI hooks, item 8 (found by I7b-2). The crash-recovery offer is
    /// the OUTERMOST scrimmed modal and was never listed, so Escape with it up
    /// went to the editor behind it. The decision on what Escape does to the
    /// sheet itself: NOTHING — its two buttons (Discard, Restore) carry no key
    /// equivalent and it mounts no Escape handler, so with the offer listed the
    /// monitor passes the key, the ladder refuses it (`blocked`), and nothing
    /// claims it. Escape never means "discard the recovered work".
    @Test("I1 UI hooks item 8 — the crash-recovery offer is a BLOCKING modal, and Escape never picks Discard: the sheet claims no key at all")
    func theRecoveryOfferIsAModal() {
        let app = Self.code(Self.appPath)
        let modal = Self.required("var isModalPresented: Bool {", in: app, Self.appPath)
        #expect(modal.contains("recoveryOffer != nil"),
                "the recovery offer is not in isModalPresented — Escape and ⌫ reach the editor behind it")
        let sheetPath = "DAWApp/RecoveryOfferView.swift"
        let sheet = Self.code(sheetPath)
        // POSITIVE CONTROL: the reader reaches the sheet and both of its buttons.
        #expect(sheet.contains("Button(action: onDiscard)"))
        #expect(sheet.contains("Button(action: onRestore)"))
        for claim in [".keyboardShortcut", ".onKeyPress", ".onExitCommand", ".cancelAction", ".defaultAction"] {
            #expect(!sheet.contains(claim),
                    "the recovery sheet claims a key through `\(claim)` — decide what Escape does to it first: it must never mean Discard")
        }
    }

    @Test("every `.cancelAction` key equivalent in the app is one `escapeIsOwnedElsewhere` names — a new one must be added there")
    func everyKeyEquivalentEscapeIsNamed() throws {
        let fm = FileManager.default
        let root = Self.sourcesDir().appendingPathComponent("DAWApp")
        let files = try #require(fm.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
        #expect(files.count > 50, "POSITIVE CONTROL: the enumerator saw only \(files.count) files")
        var hits: [String] = []
        for url in files {
            let rel = String(url.path.dropFirst(Self.sourcesDir().path.count + 1))
            let text = Self.code(rel)
            let n = text.components(separatedBy: ".keyboardShortcut(.cancelAction)").count - 1
            if n > 0 { hits.append("\(url.lastPathComponent)×\(n)") }
        }
        // MEASURED 2026-09-25: the explain mode's hidden button (ContentView)
        // and the preset card's Cancel. Both are covered: explain by
        // `escapeIsOwnedElsewhere`, the card by `isModalPresented`.
        // p2-sing-f (2026-10-07): the Sing cards' shared header ✕
        // (`SingCardChrome.swift`, used ONLY by the Sing sheet, the voice recorder
        // and the singing-engine consent card) — all three listed in
        // `isModalPresented` (`singSheet.isOpen`, `singRecorder.isOpen`,
        // `singConsent.isOpen`); a card under another is `.disabled`
        // (`SingCardMount`), so only the top card's ✕ is live.
        #expect(hits.sorted() == ["ContentView.swift×1", "PresetReplaceConfirmCard.swift×1", "SingCardChrome.swift×1"],
                "a `.cancelAction` Escape consumer appeared or vanished (\(hits.sorted())) — the key monitor AND the `.onKeyPress` mounts run BEFORE a key equivalent (measured, I7b-2 A/B), so a new one must be named in `escapeIsOwnedElsewhere` (or be a listed modal) or either route will eat its Escape")
        // The Sing cards' ✕ is covered only because all three cards are listed modals: pin that half too.
        let modal = Self.required("var isModalPresented: Bool {", in: Self.code(Self.appPath), Self.appPath)
        for term in ["singSheet.isOpen", "singRecorder.isOpen", "singConsent.isOpen"] {
            #expect(modal.contains(term), "a Sing card's ✕ consumes Escape, but `\(term)` is not in isModalPresented")
        }
    }

    /// The CENSUS of every SwiftUI Escape consumer, by the METHOD, not a
    /// remembered number: comment-stripped `Sources/DAWApp`, every spelling a
    /// view can use to take Escape — `.onKeyPress(.escape)`, a key SET holding
    /// `.escape`, and `.onExitCommand` (the responder chain's `cancelOperation:`,
    /// which a grep for `.onKeyPress` never sees — it is how I7b-2's first census
    /// missed the Copilot rename field). Key equivalents are the test above.
    ///
    /// Why a new one must stop here: the key monitor runs BEFORE every one of
    /// them and SWALLOWS an Escape whenever the open editor has something to take
    /// down. A consumer is safe only if it is one of the three mounts that ask
    /// the app's ladder, or it lives in a TEXT FIELD — the monitor refuses
    /// `.textEditing` (`transportKeyResponder`: any `NSText`/`NSTextInputClient`
    /// first responder) and passes the key on. MEASURED for the marker rename
    /// field (m23-ap I7b-2 probe, legs T/TM); the track and Copilot rename fields
    /// have no staging seam and rest on that same refusal — unverified in staging.
    @Test("every Escape consumer a view mounts is accounted for — five `.onKeyPress(.escape)` and one `.onExitCommand` in a text field; a new one must be reviewed against the key monitor")
    func everyEscapeMountIsAccountedFor() throws {
        let fm = FileManager.default
        let root = Self.sourcesDir().appendingPathComponent("DAWApp")
        let files = try #require(fm.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
        #expect(files.count > 50, "POSITIVE CONTROL: the enumerator saw only \(files.count) files")
        var mounts: [String] = []
        var exits: [String] = []
        var keySetLines = 0
        var keySetsWithEscape: [String] = []
        for url in files {
            let rel = String(url.path.dropFirst(Self.sourcesDir().path.count + 1))
            let text = Self.code(rel)
            let m = text.components(separatedBy: ".onKeyPress(.escape)").count - 1
            if m > 0 { mounts.append("\(url.lastPathComponent)×\(m)") }
            let e = text.components(separatedBy: ".onExitCommand").count - 1
            if e > 0 { exits.append("\(url.lastPathComponent)×\(e)") }
            for line in text.split(separator: "\n") where line.contains(".onKeyPress(keys:") {
                keySetLines += 1
                if line.contains(".escape") { keySetsWithEscape.append(url.lastPathComponent) }
            }
        }
        // POSITIVE CONTROL for the key-set check: the arrows' and ⌫'s key-set
        // mounts are seen, so an empty `keySetsWithEscape` is a real negative.
        #expect(keySetLines >= 4, "the scan saw only \(keySetLines) `.onKeyPress(keys:` lines — it cannot vouch that none holds Escape")
        #expect(keySetsWithEscape.isEmpty, "a key SET now takes Escape (\(keySetsWithEscape)) — review it against the key monitor and add it to this census")
        // MEASURED 2026-09-25: the roll, the note editor pane and the arrange
        // backstop (all three ask `AppModel.handleEditorEscape`), and the marker
        // and track rename fields (text fields: cancel the rename, `.handled`).
        #expect(mounts.sorted() == ["ContentView.swift×1", "PianoRollView.swift×1", "PitchEditorView.swift×1",
                                    "TimelineLanesView.swift×1", "TrackListView.swift×1"],
                "an `.onKeyPress(.escape)` mount appeared or vanished (\(mounts.sorted())) — the key monitor runs FIRST and swallows Escape whenever the open editor has something to take down, so a new mount must either ask the app's ladder or live in a text field")
        #expect(exits.sorted() == ["CopilotChatListView.swift×1"],
                "an `.onExitCommand` appeared or vanished (\(exits.sorted())) — it is an Escape consumer the key monitor runs before; review it the same way")
        // The one `.onExitCommand` sits ON the Copilot chat list's rename
        // TextField, so a live rename is always a text-editing first responder.
        let copilotPath = "DAWApp/Copilot/CopilotChatListView.swift"
        let field = Self.required("private var renameField: some View {", in: Self.code(copilotPath), copilotPath)
        #expect(field.contains("TextField("), "the Copilot rename field is no longer a TextField")
        #expect(field.contains(".onExitCommand { ui.cancelRename() }"),
                "the Copilot rename's Escape moved off its TextField — off a text field, the key monitor can eat it")
    }

    @Test("the roll runs ONE Escape body from both routes, and its mount counts its own deliveries first")
    func theRollsTwoRoutes() {
        let roll = Self.code(Self.rollPath)
        let body = Self.required("private func handleEscape() -> KeyPress.Result {", in: roll, Self.rollPath)
        #expect(body.contains("let rung = onEscape(escapeGestureLive, !model.selection.isEmpty)"))
        let watcher = Self.required(".onChange(of: noteSelection.escapeNonce)", in: roll, Self.rollPath)
        #expect(watcher.contains("handleEscape()"), "the monitor's hand-off reaches nothing in the roll")
        let mount = Self.required(".onKeyPress(.escape)", in: roll, Self.rollPath)
        let first = mount.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        #expect(first == "KeyPressProbe.pianoRollEscape += 1", "the roll's mount counter is not its first statement: \(first ?? "nil")")
        #expect(mount.contains("return handleEscape()"))
    }

    @Test("the note editor pane's hand-off runs the pane's own Escape path; the backstop counts its own deliveries first")
    func thePaneAndTheBackstop() {
        let pane = Self.code(Self.panePath)
        let watcher = Self.required(".onChange(of: interaction?.escapeNonce)", in: pane, Self.panePath)
        #expect(watcher.contains("model.handleEscapeKey(appDecision: onEscape)"))
        let content = Self.code(Self.contentPath)
        let backstop = Self.required(".onKeyPress(.escape)", in: content, Self.contentPath)
        let first = backstop.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        #expect(first == "KeyPressProbe.arrangeEscapeBackstop += 1", "the backstop's counter is not its first statement: \(first ?? "nil")")
        #expect(backstop.contains("return model.handleEditorEscape() ? .handled : .ignored"))
    }

    @Test("the monitor's tier and the two new mount counters are echoed")
    func theEchoes() {
        let app = Self.code(Self.appPath)
        for key in ["\"escapeKeyMonitorSeq\"", "\"escapeKeyMonitorRefusedBy\"", "\"escapeKeyMonitorTarget\""] {
            #expect(app.contains(key), "\(key) is not echoed")
        }
        let probe = Self.code("DAWApp/KeyPressProbe.swift")
        #expect(probe.contains("\"pianoRollEscape\": .number(Double(pianoRollEscape))"))
        #expect(probe.contains("\"arrangeEscapeBackstop\": .number(Double(arrangeEscapeBackstop))"))
    }
}
