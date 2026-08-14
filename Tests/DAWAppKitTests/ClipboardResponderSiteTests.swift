import Foundation
import Testing

/// m25-f-1 — the SOURCE-SHAPE half of ⌘X / ⌘C / ⌘V.
///
/// **WHY A SITE TEST.** `ClipboardResponderRoutingTests` proves the DECISIONS.
/// It cannot prove that the object AppKit actually talks to asks them — and
/// `DAWApp` has no test target, so this file is the only thing in the repo that
/// can see `ClipboardResponder` at all. Same idiom as `DeleteKeySiteTests` /
/// `EditorSurfaceOwnershipSiteTests`: anchored to the repo via `#filePath`, with
/// comments stripped so prose about a banned token cannot fail an assertion
/// about code.
///
/// ⚠️ **A TOKEN SEARCH FINDS THE TOKEN, NOT THE BEHAVIOUR.** If one of these
/// fails, do not "fix" it by rewording the source. Every assertion names the
/// failure it exists to catch; read that first.
@Suite("⌘X/⌘C/⌘V responder wiring (m25-f-1)")
struct ClipboardResponderSiteTests {

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
        // A pin test that silently finds no files reports the cleanest possible
        // green, which is the most dangerous kind. Say so loudly instead.
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func raw(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content
    }

    /// Comments removed, so prose ABOUT a call cannot satisfy an assertion about
    /// the call. Both files here discuss `.keyboardShortcut` and `delete:` at
    /// length precisely because they must not use them.
    private static func code(_ relativePath: String) -> String {
        raw(relativePath).split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return text.range(of: "//").map { String(text[..<$0.lowerBound]) } ?? text
        }.joined(separator: "\n")
    }

    /// The text BETWEEN the braces of `func <name>`, by brace matching. Comments
    /// stripped first. Nil when the function cannot be found, which every caller
    /// treats as a FAILURE — "renamed" and "clean" must never look the same here.
    private static func body(of name: String, in content: String) -> String? {
        guard let decl = content.range(of: "func \(name)(") else { return nil }
        guard let open = content.range(of: "{", range: decl.upperBound..<content.endIndex) else {
            return nil
        }
        var depth = 0
        var out = ""
        var i = open.lowerBound
        while i < content.endIndex {
            let ch = content[i]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
            if depth >= 1 { out.append(ch) }
            i = content.index(after: i)
        }
        return nil
    }

    /// Comment-stripped code with every run of whitespace collapsed to one
    /// space, so a pin cannot be broken (or satisfied) by where a line wraps.
    private static func normalized(_ content: String) -> String {
        content.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    private static let responderFile = "DAWApp/ClipboardResponder.swift"
    private static let appFile = "DAWApp/DAWProApp.swift"
    private static let editCommandsFile = "DAWApp/EditCommands.swift"

    // MARK: - The conformance that fails silently

    /// ⚠️⚠️ **THE ONE THAT BREAKS WITHOUT A CRASH, A WARNING OR A RED LINE.**
    /// AppKit consults `validateMenuItem(_:)` only on a target that CONFORMS to
    /// `NSMenuItemValidation`. Drop the conformance and keep the method and
    /// AppKit falls back to "the target responds to the selector, therefore
    /// enable it": the native items stop greying out, and ⌘C fires clip-copy in
    /// the Mix console and behind modal panels. Nothing else in this repo can
    /// see that.
    @Test("The responder conforms to NSMenuItemValidation")
    func conformanceIsDeclared() {
        let source = Self.normalized(Self.code(Self.responderFile))
        #expect(source.contains(
            "final class ClipboardResponder: NSResponder, NSMenuItemValidation"),
                "the conformance is what makes validateMenuItem run at all")
    }

    // MARK: - Which selectors are claimed

    /// The claimed set is the clipboard three PLUS `selectAll:`. `delete:` is the
    /// one that matters: claiming it would light a SECOND live Delete row beside
    /// the app's own and put a second route into the ⌫ fix the user confirmed by
    /// hand 2026-08-12.
    ///
    /// ⭐⭐ **3 → 4 AT m25-s, AND THIS PIN IS EXACTLY THE MECHANISM THAT MADE THAT
    /// A DECISION.** `selectAll` moved from the BANNED list to the REQUIRED list
    /// on the user's own request (2026-08-13: *"when in node editor and user uses
    /// keyboard shortcut \"select all\"/cmd+A - it should select all the notes in
    /// the editor"*). `ClipboardResponderRouting.claimedSelectorNames` carries the
    /// full decision, including how the two recorded objections now stand — one
    /// answered structurally and MEASURED for this selector (P4 reproduced:
    /// field editor focused ⇒ target `NSTextView`, our `validateMenuItem` not
    /// called), the other kept as the feature's SCOPE (roll only; no arrange-wide
    /// select-all was invented).
    ///
    /// ⚠️ IF YOU ARE HERE BECAUSE THIS WENT RED AT 5, STOP. A fifth `@objc`
    /// verb is a product decision about a keystroke, not a refactor.
    @Test("Exactly four @objc verbs, and delete: is not among them")
    func claimedSelectorsArePinned() {
        let source = Self.code(Self.responderFile)
        // ⚠️ `selectAll(_:)` IS `override func`, NOT `@objc func`, and the
        // difference is AppKit's not ours: `NSResponder` DECLARES `selectAll:`
        // (informal NSStandardKeyBindingMethods) and does not declare
        // copy:/cut:/paste:, so the compiler REQUIRES `override` here and REJECTS
        // it there. Counting only `@objc func` would silently stop seeing this
        // verb, so both spellings are counted.
        let objcCount = source.components(separatedBy: "@objc func").count - 1
        let overrideCount = source.components(separatedBy: "override func").count - 1
        #expect(objcCount == 3, "expected exactly cut/copy/paste as @objc, found \(objcCount)")
        #expect(overrideCount == 1,
                "expected exactly selectAll as override, found \(overrideCount)")
        for name in ["cut", "copy", "paste"] {
            #expect(source.contains("@objc func \(name)(_ sender: Any?)"),
                    "\(name): must be claimed")
        }
        #expect(source.contains("override func selectAll(_ sender: Any?)"),
                "selectAll: must be claimed (m25-s) — and as an override")
        for banned in ["func delete(_ sender", "func pasteAsPlainText(_ sender"] {
            #expect(!source.contains(banned), "must not claim \(banned)")
        }
        // ⚠️ AN UNRECOGNIZED-SELECTOR CRASH, NOT A NO-OP: `NSResponder` declares
        // `selectAll:` without implementing it (measured — class_getInstanceMethod
        // is nil), so there is nothing to call up to.
        #expect(!source.contains("super.selectAll("),
                "super.selectAll(_:) has no implementation behind it — it would crash")
    }

    // MARK: - ⌘A (m25-s)

    /// ⚠️⚠️ **THE ORDERING BUG THIS FEATURE ALMOST SHIPPED, PINNED.**
    /// `ClipboardResponderRouting.verb(forSelectorName:)` answers nil for
    /// `selectAll:` — it is claimed, but it is not a clipboard verb. The previous
    /// `validateMenuItem` shape resolved the verb FIRST and returned `true` from
    /// its `else`. Leave that order and Select All is PERMANENTLY ENABLED in every
    /// state while its action quietly returns false: a row that never greys and
    /// never does anything.
    @Test("validateMenuItem dispatches selectAll: BEFORE the clipboard-verb lookup")
    func selectAllIsDispatchedBeforeTheVerbLookup() {
        guard let body = Self.body(of: "validateMenuItem",
                                   in: Self.code(Self.responderFile)) else {
            Issue.record("validateMenuItem(_:) not found"); return
        }
        let flat = Self.normalized(body)
        guard let selectAllBranch = flat.range(of: "ClipboardResponderRouting.selectAllSelectorName"),
              let verbLookup = flat.range(of: "ClipboardResponderRouting.verb(forSelectorName:") else {
            Issue.record("both the select-all branch and the verb lookup must be present")
            return
        }
        #expect(selectAllBranch.upperBound <= verbLookup.lowerBound,
                "selectAll: must be handled before the verb lookup that answers nil for it")
        #expect(flat.contains("model.selectAllMenuItem"),
                "the enabled state must come from the policy, never a literal")
    }

    /// The verb is a ROUTE to the app's action, never its own implementation.
    @Test("selectAll: funnels into performMenuSelectAll")
    func selectAllFunnelsIntoTheModel() {
        guard let body = Self.body(of: "selectAll",
                                   in: Self.code(Self.responderFile)) else {
            Issue.record("selectAll(_:) not found in \(Self.responderFile)"); return
        }
        #expect(Self.normalized(body).contains("model?.performMenuSelectAll()"))
    }

    /// ⚠️ **⌘A MUST NOT RIDE THE m23-x DEBUG SEAM.** `stage(selectAll:)` already
    /// selects every note, so routing the keystroke through it would have been the
    /// two-line change — and would have made a user-facing feature depend on a
    /// test affordance that also carries m23-ak's production CLEAR. The app must
    /// reach the roll through the m25-s nonce instead.
    @Test("performMenuSelectAll asks the roll through its OWN nonce, not the staging seam")
    func performMenuSelectAllUsesTheProductionNonce() {
        guard let body = Self.body(of: "performMenuSelectAll",
                                   in: Self.code(Self.appFile)) else {
            Issue.record("performMenuSelectAll() not found in \(Self.appFile)"); return
        }
        let flat = Self.normalized(body)
        #expect(flat.contains("pianoRollNoteSelection.requestSelectAll()"),
                "the roll owns the draft; the app asks")
        #expect(!flat.contains("stage(selectAll:"),
                "a user keystroke must not depend on the m23-x staging seam")
        #expect(flat.contains("selectAllMenuItem.surface"),
                "re-resolved at click time, so what was offered and what runs cannot diverge")
    }

    /// The roll applies the request through the EXTRACTED verb, so the keystroke
    /// and the staging seam can never select different things — and applies it
    /// WITHOUT a commit, because selecting is not editing.
    @Test("the roll routes selectAllNonce into the shared verb, with no commit")
    func rollAppliesSelectAllThroughTheSharedVerb() {
        let roll = Self.normalized(Self.code("DAWApp/PianoRoll/PianoRollView.swift"))
        #expect(roll.contains(".onChange(of: noteSelection.selectAllNonce) { _, _ in model.selectAllNotes() }"),
                "the ⌘A nonce must apply the extracted verb")
        // The staging seam runs the SAME verb rather than a second copy of it.
        #expect(roll.contains("if noteSelection.stagedSelectAll { model.selectAllNotes() }"),
                "the seam must share the verb, not re-spell it")
        #expect(!roll.contains("model.selection = Set(model.draft.map(\\.id))"),
                "the inline expression was extracted at m25-s; a second copy would be free to drift")
    }

    /// Each verb is a ROUTE to the app's existing action, never its own
    /// implementation — the m23-cf rule. A responder that copied clips itself
    /// would be a second policy, and the two would drift.
    @Test("Each verb funnels into the app's existing action")
    func verbsFunnelIntoTheModel() {
        let source = Self.code(Self.responderFile)
        for (verb, action) in [("cut", "performMenuCut"), ("copy", "performMenuCopy"),
                               ("paste", "performMenuPaste")] {
            guard let body = Self.body(of: verb, in: source) else {
                Issue.record("\(verb)(_:) not found in \(Self.responderFile)")
                continue
            }
            #expect(Self.normalized(body).contains("model?.\(action)()"),
                    "\(verb): must call \(action), the same funnel the menu used")
        }
    }

    // MARK: - Validation reads the policy

    /// Title AND enabled state must both come from the resolved policy item. A
    /// hand-built title here is how the menu starts naming a blast radius the
    /// action does not have.
    @Test("validateMenuItem renders the policy, and nothing of its own")
    func validationReadsThePolicy() {
        guard let body = Self.body(of: "validateMenuItem",
                                   in: Self.code(Self.responderFile)) else {
            Issue.record("validateMenuItem(_:) not found"); return
        }
        let flat = Self.normalized(body)
        #expect(flat.contains("ClipboardResponderRouting.verb( forSelectorName:")
                || flat.contains("ClipboardResponderRouting.verb(forSelectorName:"),
                "the selector must be resolved through the routing policy")
        #expect(flat.contains("model.clipboardMenuItem(for: verb)"),
                "the item must come from the same policy the Edit menu used")
        #expect(flat.contains("menuItem.title = presentation.title"),
                "the title must be the policy's, never a literal")
        #expect(flat.contains("return presentation.isEnabled"),
                "enablement must be the policy's, never a literal")
    }

    /// ⚠️⚠️ **THE USER'S 2026-08-12 RULING, PINNED AT ITS ONE LOAD-BEARING LINE:**
    /// *"we do not need to use copy 3 clips."* The policy still RESOLVES a
    /// counted title (the `debug.editClipboard` echo reports it, and the
    /// right-click menus have their own counted titles), so the only thing
    /// standing between the Edit menu and "Copy 3 Clips" is that `presentation`
    /// builds from the VERB and never from `item.title`.
    @Test("The native item's title is built from the verb, never from the policy item")
    func presentationDropsTheCountedTitle() {
        guard let body = Self.body(of: "presentation",
                                   in: Self.code("DAWAppKit/ClipboardResponderRouting.swift")) else {
            Issue.record("presentation(for:) not found"); return
        }
        let flat = Self.normalized(body)
        #expect(flat.contains("title: plainTitle(for: item.verb)"),
                "the title must be the bare macOS word")
        #expect(!flat.contains("title: item.title"),
                "rendering the policy's counted title is what the user ruled out")
        #expect(flat.contains("isEnabled: item.isEnabled"),
                "enablement is still entirely the policy's — that was not the ruling")
    }

    // MARK: - Where the responder sits

    /// ⚠️ THE ORDER OF THE TWO ASSIGNMENTS IS THE WHOLE SAFETY ARGUMENT: the
    /// window's PREVIOUS next responder must be adopted BEFORE the window's slot
    /// is overwritten. Reverse them and the responder points at itself — every
    /// chain walk in the process hangs — while everything behind the window
    /// (the window controller, NSApp, SwiftUI's app delegate) is cut off.
    @Test("Install splices in, preserving the previous next responder")
    func installPreservesTheChain() {
        guard let body = Self.body(of: "installClipboardResponder",
                                   in: Self.code(Self.responderFile)) else {
            Issue.record("installClipboardResponder() not found"); return
        }
        let flat = Self.normalized(body)
        #expect(flat.contains("ClipboardResponderRouting.chainInstall("),
                "idempotency must be decided by the headless policy, not inline")
        guard let adopt = flat.range(of: "responder.nextResponder = window.nextResponder"),
              let overwrite = flat.range(of: "window.nextResponder = responder") else {
            Issue.record("the two chain assignments were not both found"); return
        }
        #expect(adopt.upperBound <= overwrite.lowerBound,
                "the previous next responder must be adopted BEFORE the slot is taken")
    }

    /// Installed against the SAME window identity the space and delete keys
    /// guard, so the key path and the menu path cannot disagree about which
    /// window the app's keyboard belongs to.
    @Test("Install is wired to the content window, from applyWindowFloor")
    func installIsMountedOnTheContentWindow() {
        let responder = Self.normalized(Self.code(Self.responderFile))
        #expect(responder.contains("hasWindow: contentWindow != nil"))
        #expect(responder.contains("windowNextResponderIsOurs: contentWindow?.nextResponder === responder"))

        guard let floor = Self.body(of: "applyWindowFloor", in: Self.code(Self.appFile)) else {
            Issue.record("applyWindowFloor() not found in \(Self.appFile)"); return
        }
        #expect(Self.normalized(floor).contains("installClipboardResponder()"),
                "nothing installs the responder if this call goes missing; ⌘C dies silently")
    }

    // MARK: - The mechanism that must never be used

    /// ⚠️⚠️ **THE REGRESSION THIS ITEM EXISTS TO AVOID.** A `CommandGroup` key
    /// equivalent is checked BEFORE the responder chain, so ⌘C typed into a
    /// rename field would fire CLIP-COPY instead of copying the text — the m17-d
    /// trap, transposed. The user authorised the OUTCOME, not that mechanism.
    @Test("No ⌘C / ⌘X / ⌘V key equivalent anywhere in the app's menus")
    func noPasteboardKeyEquivalents() throws {
        let root = Self.sourcesDir().appendingPathComponent("DAWApp", isDirectory: true)
        let files = FileManager.default.enumerator(atPath: root.path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
        #expect(files.count > 20, "the sweep found suspiciously few files (\(files.count))")
        for file in files {
            let source = Self.normalized(Self.code("DAWApp/\(file)"))
            for letter in ["c", "x", "v"] {
                #expect(!source.contains("keyboardShortcut(\"\(letter)\""),
                        "\(file) declares a ⌘\(letter.uppercased()) key equivalent, which outranks every text field")
            }
        }
    }

    /// ⚠️ THE DUPLICATE ROW PIN. Three `Button`s used to render Cut / Copy /
    /// Paste in the Edit menu; the native items now do it WITH the keystrokes.
    /// Putting them back would restore the measured six-near-identical-rows menu
    /// the user ruled against ("if the most versatile can handle our use-cases,
    /// then we can drop the inferrior ones"). Delete is deliberately still here.
    @Test("EditCommands renders Delete only — no second clipboard row")
    func editMenuHasNoDuplicateClipboardRow() {
        let source = Self.code(Self.editCommandsFile)
        for banned in ["performMenuCut", "performMenuCopy", "performMenuPaste"] {
            #expect(!source.contains(banned),
                    "\(banned) is back in the Edit menu: a second, shortcut-less row for a native verb")
        }
        #expect(source.contains("model.performMenuDelete()"),
                "Delete stays a Button: this app does not claim `delete:`")
    }
}
