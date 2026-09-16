import Foundation
import Testing

/// m25-b-1 — the SOURCE-SHAPE half of the maximized note editor.
///
/// **WHY THIS EXISTS.** `EditorMaximizeTests` proves the RULE: what fraction, what
/// sliver, when Escape exits. It cannot prove the rule is WIRED — that
/// `ContentView` actually multiplies by `effectiveFraction`, that the arrange row
/// is actually pinned, that the splitter actually leaves the mode, that the toggle
/// actually writes the store, or that Escape has exactly the two mounts the design
/// argument depends on. All of that lives in `DAWApp`, which has **no test
/// target**, so a perfect rule could sit beside a view that never calls it and
/// every suite would stay green. This file is that gap's substitute — the
/// `DeleteKeySiteTests` / `EditorSurfaceOwnershipSiteTests` idiom, same tree, same
/// anchoring.
///
/// ⚠️ **A TOKEN SEARCH FINDS THE TOKEN, NOT THE BEHAVIOUR.** If one of these fails,
/// do not "fix" it by rewording the source. Every assertion names the failure it
/// exists to catch; read that first.
///
/// Anchored to the repo via `#filePath`, so it runs headless with no bundle
/// resources.
@Suite("Maximized note editor — the wiring pins (m25-b-1)")
struct EditorMaximizeSiteTests {

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

    private static func text(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content
    }

    /// Comments removed, so a doc comment DISCUSSING a call can never satisfy an
    /// assertion about the code MAKING it. Every count below runs on this.
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

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private static let contentViewPath = "DAWApp/ContentView.swift"
    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"
    private static let appPath = "DAWApp/DAWProApp.swift"

    /// ⭐ THE CONTROL FOR EVERY ABSENCE ASSERTED BELOW. A grep that never looked
    /// and a grep that looked and found nothing produce the same output, so this
    /// proves the reader is reading the files it thinks it is.
    @Test("the source reader actually reads the three files (the negative control)")
    func readerControl() {
        for path in [Self.contentViewPath, Self.rollPath, Self.appPath] {
            let code = Self.codeOnly(Self.text(path))
            #expect(code.count > 5_000, "\(path) came back suspiciously short: \(code.count) chars")
        }
        // A token that IS there, so an always-zero counter fails here first.
        #expect(Self.occurrences(of: "editorFraction", in: Self.codeOnly(Self.text(Self.contentViewPath))) > 0)
        // A token that is NOT, so an always-positive counter fails here.
        #expect(Self.occurrences(of: "zzNotARealToken", in: Self.codeOnly(Self.text(Self.contentViewPath))) == 0)
    }

    // MARK: - The rule is actually applied

    /// The pane height must come from `EditorMaximize`, not from a second copy of
    /// the arithmetic. If someone inlines `editorFraction` back into the `.frame`,
    /// the whole mode becomes dead code that still passes `EditorMaximizeTests`.
    @Test("ContentView lays the pane out through EditorMaximize.effectiveFraction")
    func paneUsesTheRule() {
        let code = Self.codeOnly(Self.text(Self.contentViewPath))
        let note1 = "the editor pane no longer asks EditorMaximize for its height — the maximize " + "mode is dead code, and every EditorMaximizeTests leg would still pass."
        #expect(code.contains("EditorMaximize.effectiveFraction"), "\(note1)")
        let note2 = "the pane's height expression changed shape; check it still multiplies the " + "window height by the EFFECTIVE fraction and not by the stored one."
        #expect(code.contains("editorPaneFraction(geoHeight:"), "\(note2)")
    }

    /// The arrange row must be PINNED while maximized. Left flexible, SwiftUI can
    /// lay it out past the frame when the pane over-commits — an overflow no gate
    /// in this repo can see, which is exactly why it is asserted structurally.
    @Test("ContentView pins the arrange row through EditorMaximize.arrangeHeight")
    func arrangeRowIsPinned() {
        let code = Self.codeOnly(Self.text(Self.contentViewPath))
        let note3 = "the arrange row is no longer pinned while maximized; the pane's fixed height " + "can then over-commit the window VStack and overflow invisibly."
        #expect(code.contains("EditorMaximize.arrangeHeight"), "\(note3)")
        // The sliver must be composed from the REAL geometry, never from
        // `EditorMaximize`'s preview default — those two can drift, and the ruler
        // block is `.frame(height: rulerHeight)`-pinned, so an under-reserve makes
        // it draw on top of the editor.
        let note4 = "the maximized arrange sliver is no longer composed from the live ruler-block " + "geometry; a stale constant here starves the pinned block."
        #expect(code.contains("TimelineLanesView.rulerHeight + arrangeBlockGap"), "\(note4)")
        #expect(!code.contains("EditorMaximize.defaultArrangeSliverHeight"),
                "ContentView is using the PREVIEW default sliver instead of the real geometry.")
    }

    // MARK: - The three exits

    /// ⭐⭐ TWO MOUNTS, ONE DECISION — the m23-cf lesson. Focus arbitration in this
    /// tree was MEASURED to be a coin flip, so a key whose meaning depends on who
    /// holds focus is a defect waiting to be reported. Both Escape mounts must ask
    /// the SAME app-side question; if either one grows its own rule, this fails.
    @Test("Escape has exactly TWO mounts and both route to the one app decision")
    func escapeHasTwoMountsOneDecision() {
        let contentView = Self.codeOnly(Self.text(Self.contentViewPath))
        let roll = Self.codeOnly(Self.text(Self.rollPath))

        // Mount 1: the roll's own, through its `onEscape` value input.
        #expect(roll.contains(".onKeyPress(.escape)"),
                "the piano roll no longer claims Escape — the maximized mode loses its primary exit.")
        let note5 = "the roll's Escape no longer reports handled/ignored from the app decision; " + "an unconditional .handled would swallow Escape outside the mode."
        #expect(roll.contains("onEscape() ? .handled : .ignored"), "\(note5)")

        // Mount 2: the arrange workspace's key scope (the ArrangeDeleteKey modifier).
        let note6 = "the arrange workspace's backstop Escape mount is gone — Escape then only works " + "when the roll itself holds focus, which this tree measured to be unreliable."
        #expect(contentView.contains(".onKeyPress(.escape)"), "\(note6)")

        // ONE decision, asked by both. Two call sites of `handleEditorEscape`:
        // the roll's `onEscape:` wiring and the workspace mount, both in ContentView.
        let calls = Self.occurrences(of: "model.handleEditorEscape()", in: contentView)
        let note7 = "expected exactly 2 `model.handleEditorEscape()` call sites in ContentView (the " + "roll's onEscape wiring and the arrange workspace's backstop mount), found " + "\(calls). More means a third claimant; fewer means a mount grew its own rule."
        #expect(calls == 2, "\(note7)")

        // The decision itself must consult the headless rule, not re-spell it.
        let app = Self.codeOnly(Self.text(Self.appPath))
        let note8 = "handleEditorEscape no longer asks EditorMaximize — the modal / rename-field " + "refusals are then unpinned by any test."
        #expect(app.contains("EditorMaximize.escapeExits("), "\(note8)")
        // SET, never toggle: a double-delivered press must not re-maximize.
        let note9 = "the Escape route no longer SETS the mode off; a toggle here makes correctness " + "depend on SwiftUI delivering the press exactly once."
        #expect(app.contains("panelLayout.setEditorMaximized(false)"), "\(note9)")
    }

    /// The toggle is the OTHER way out, and the item's constraint is that there
    /// are two. If the header button disappears, Escape becomes the only exit and
    /// a user who never discovers it is stranded in a window-filling mode.
    @Test("the roll header carries the MAXIMIZE toggle and it writes the shared store")
    func toggleExists() {
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(roll.contains("maximizeToggle"),
                "the header's MAXIMIZE toggle is gone — Escape would be the mode's only exit.")
        #expect(roll.contains("layout.setEditorMaximized("),
                "the toggle no longer writes the shared PanelLayoutStore slot.")
        let note10 = "the toggle no longer takes its two faces from the tested rule, so 'you can tell " + "at a glance which state you are in' is no longer pinned by anything."
        #expect(roll.contains("EditorMaximize.toggleSymbol("), "\(note10)")
    }

    /// The third exit, the one a user reaches for by reflex. Dragging the splitter
    /// while maximized must leave the mode — otherwise the drag writes a clamped
    /// fraction that the still-active override hides, and the splitter appears dead.
    @Test("dragging the editor splitter leaves the maximized mode")
    func splitterExits() {
        let code = Self.codeOnly(Self.text(Self.contentViewPath))
        guard let splitter = code.range(of: "func editorSplitter(") else {
            Issue.record("editorSplitter was renamed; re-point this pin at it")
            return
        }
        // A generous window past the declaration — the function is ~15 lines.
        let end = code.index(splitter.upperBound, offsetBy: 1_200, limitedBy: code.endIndex)
            ?? code.endIndex
        let body = String(code[splitter.upperBound..<end])
        let note11 = "the splitter drag no longer leaves the maximized mode: the drag would write a " + "clamped fraction that the live override hides, so the splitter reads as dead."
        #expect(body.contains("setEditorMaximized(false)"), "\(note11)")
        let note12 = "the drag origin is no longer seeded from the EFFECTIVE fraction, so a drag that " + "starts on a maximized splitter jumps by the whole override."
        #expect(body.contains("editorPaneFraction(geoHeight:"), "\(note12)")
    }

    // MARK: - What must NOT be there

    /// ⭐ THE RESTORE MECHANISM, ASSERTED AS AN ABSENCE. Maximize restores to the
    /// user's own height *because nothing stashes it* — the mode is a render-time
    /// override and `editorFraction` is never written. A `previousFraction`-style
    /// slot creeping back in would reintroduce the two-values-that-can-disagree
    /// problem this design exists to avoid, and would be clamped to 0.55 on the
    /// way in, silently changing the user's layout.
    @Test("no 'previous fraction' stash was reintroduced anywhere")
    func noPreviousFractionStash() {
        for path in [Self.contentViewPath, Self.rollPath, Self.appPath] {
            let code = Self.codeOnly(Self.text(path))
            for banned in ["previousEditorFraction", "priorEditorFraction",
                           "savedEditorFraction", "preMaximizeFraction"] {
                let note13 = "\(path) reintroduced a maximize stash (\(banned)); the restore is the " + "UNTOUCHED editorFraction slot, and a second copy of it can disagree."
                #expect(!code.contains(banned), "\(note13)")
            }
        }
    }

    /// The wire decision, asserted rather than remembered.
    ///
    /// ⚠️⚠️ **THIS TEST WAS INVERTED AT M35, AND THE INVERSION IS THE RECORD OF A
    /// RULING, NOT A RELAXATION.** It used to assert `editorMaximized` NEVER
    /// reaches DAWControl. `docs/DESIGN-LANGUAGE.md` still records adjustable
    /// layout as a non-invokable window preference, and every other slot still
    /// obeys it — but M35 narrowed that rule to TWO NAMED EXCEPTIONS, because
    /// M35 also shipped `view.capture`: the workspace mode and the editor
    /// maximize are the two controls that decide WHAT A CAPTURE CAN SEE, so an
    /// agent that can photograph the app and cannot frame it has half a
    /// capability. m25-b-1's "no project byte, no sound" argument was not
    /// overturned; a different question reached the same control.
    ///
    /// So the assertion flips shape rather than disappearing: the mode must be
    /// on the wire through `view.panelLayout` and NOWHERE ELSE, and the debug
    /// seam must still stage it. An absence-test that simply deleted itself here
    /// would leave the FENCE — the thing actually worth protecting — unguarded.
    @Test("the maximize mode is on the wire through view.panelLayout ONLY (M35 narrowed the rule)")
    func onlyReachableThroughViewPanelLayout() {
        let control = Self.text("DAWControl/Commands.swift")
        // Positive control FIRST: the reader really is reading a populated
        // Commands.swift, so an absence below cannot be "the file never loaded".
        #expect(control.count > 10_000, "Commands.swift came back short: \(control.count) chars")
        #expect(control.contains("\"view.panelLayout\""),
                "view.panelLayout is gone from DAWControl — the M35 exception vanished.")
        #expect(control.contains("editorMaximized"),
                "`editorMaximized` no longer reaches DAWControl; view.panelLayout cannot expose it.")

        // ⛔ THE FENCE. Every OTHER PanelLayoutStore slot must stay debug-tier.
        // A key listed here reaching Commands.swift's CODE means the narrowed
        // rule got widened by accident — which is exactly how a "two named
        // exceptions" rule rots into "layout is invokable".
        //
        // ⚠️ COMMENTS ARE STRIPPED FIRST, and that is not a convenience: the
        // `view.panelLayout` arm NAMES every one of these keys in prose, to say
        // it refuses them. A raw `contains` would read that refusal as a
        // violation and redden on the very text that documents the fence.
        let controlCode = Self.codeOnly(control)
        for banned in ["sidebarWidth", "pianoRollPPB", "pianoRollRowHeight",
                       "pianoRollMinimap", "pianoRollCenterPitch", "mixerInsertsCollapsed",
                       "waveformNormalize", "waveformVerticalZoom", "auditionEnabled"] {
            let note14 = "`\(banned)` reached DAWControl — M35 narrowed the non-invokable-layout rule "
                + "to workspace + editorMaximized ONLY (DESIGN-LANGUAGE.md); everything else is "
                + "debug-tier chrome and belongs to debug.panelLayout."
            #expect(!controlCode.contains(banned), "\(note14)")
        }
        // `editorFraction` is the one key NOT in that list, and its absence from
        // it is deliberate: it IS in DAWControl, as a READ-ONLY echo beside
        // `editorMaximized` (the m25-b-1 restore contract — the two are
        // independent, so one round trip proves it). It must never become
        // SETTABLE, which is a claim about the accepted-key array, not about the
        // file.
        let note15 = "view.panelLayout's accepted-key array changed shape — re-check that " + "editorFraction did not become settable."
        #expect(controlCode.contains("[\"workspace\", \"editorMaximized\"]"), "\(note15)")

        // And it IS still reachable through the debug seam, so a capture can stage it.
        let app = Self.codeOnly(Self.text(Self.appPath))
        #expect(app.contains("params[\"editorMaximized\"]"),
                "the debug.panelLayout seam no longer stages the mode, so no capture can drive it.")
    }
}
