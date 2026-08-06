import Testing
import Foundation
@testable import DAWAppKit

/// m23-dd — File ▸ Export Audio…, the menu route to bouncing a song.
///
/// `DAWApp` has no test target, so the whole point of `ExportMenuPolicy` is that
/// the decisions (what the item says, when it is greyed) are testable here while
/// `FileCommands` keeps only the mount. The second half of this file is a SOURCE
/// pin over that mount — the one-home property ("the menu calls the same
/// function the transport chip does") and the deliberate absence of a keyboard
/// shortcut live in a file no unit test can otherwise reach.
///
/// WHAT THESE CANNOT REACH, recorded rather than implied by a green suite:
/// whether the `Button` actually appears in the running app's File menu, and
/// whether clicking it opens the dialog. That is a live exercise —
/// `debug.exportDialog` already reports `visible`, so a staging gate or the user
/// can observe it without any new wire.
@Suite("Export menu policy (m23-dd)")
struct ExportMenuPolicyTests {

    // MARK: - The enabled rule

    @Test("an empty project cannot render — the item is there, greyed, and says so")
    func emptyProjectRefuses() {
        let item = ExportMenuPolicy.fileMenuItem(trackCount: 0)
        #expect(item.isEnabled == false)
        // NAMED, not just false. A bare `isEnabled == false` cannot tell this
        // test apart from a policy that refuses everything, which is exactly how
        // a dead policy passes a refusal-only suite (`DeleteMenuRefusal`'s
        // argument, applied to a one-guard policy while it is still cheap).
        #expect(item.refusedBy == .emptyProject)
        // THE ITEM STILL EXISTS AND STILL READS THE SAME. A menu that vanishes
        // teaches nothing; a greyed "Export Audio…" teaches that the operation
        // is here and wants some music first — the discovery the missing item
        // denied.
        #expect(item.title == ExportMenuPolicy.title)
    }

    @Test("one track is enough — the item comes alive")
    func oneTrackEnables() {
        let item = ExportMenuPolicy.fileMenuItem(trackCount: 1)
        #expect(item.isEnabled)
        #expect(item.refusedBy == nil)
        #expect(item.title == ExportMenuPolicy.title)
    }

    @Test("the boundary is at ONE track, and above it nothing changes")
    func enabledAcrossPopulatedProjects() {
        // ANTI-VACUITY for the guard itself: a policy hardcoded to "disabled"
        // passes the empty case, and one hardcoded to "enabled" passes the
        // single-track case. Both must be measured, and the second must hold for
        // every larger session rather than for the one number a test happened to
        // pick.
        for count in [1, 2, 7, 64, 512] {
            let item = ExportMenuPolicy.fileMenuItem(trackCount: count)
            #expect(item.isEnabled, "a \(count)-track project has something to render")
            #expect(item.refusedBy == nil)
        }
    }

    @Test("a negative count degrades to greyed, never to an open dialog")
    func negativeCountDegradesSafely() {
        // Unrepresentable from `[Track].count`; resolved rather than trusted so
        // a future caller bug greys the item instead of opening an Export dialog
        // over a session it cannot describe.
        for count in [-1, -512] {
            let item = ExportMenuPolicy.fileMenuItem(trackCount: count)
            #expect(item.isEnabled == false)
            #expect(item.refusedBy == .emptyProject)
        }
    }

    @Test("enabled and refusedBy are complements — never both, never neither")
    func enabledIsDerivedFromRefusal() {
        for count in [-3, 0, 1, 2, 40] {
            let item = ExportMenuPolicy.fileMenuItem(trackCount: count)
            // A live item carrying a refusal, or a dead one without, would each
            // make the reported reason meaningless. `isEnabled` is derived from
            // `refusedBy` precisely so no caller can see them disagree.
            #expect(item.isEnabled == (item.refusedBy == nil))
        }
    }

    @Test("every refusal case is reachable — no case is dead")
    func everyRefusalIsReachable() {
        var seen: Set<ExportMenuRefusal> = []
        for count in [-1, 0, 1, 9] {
            if let refusal = ExportMenuPolicy.fileMenuItem(trackCount: count).refusedBy {
                seen.insert(refusal)
            }
        }
        // A second guard added to `fileMenuItem` without a term this loop can
        // produce fails here rather than shipping as an unreachable branch.
        #expect(seen == Set(ExportMenuRefusal.allCases))
    }

    // MARK: - The title

    @Test("the title does not collide with the File menu's OTHER export")
    func titleDoesNotCollideWithMIDIExport() {
        // The File menu already carries "Export MIDI…" (m23-k4b), so a bare
        // "Export…" beside it would ask the user to guess which one is audio.
        // ⚠️ This is the only assertion here about how the item reads NEXT TO
        // something else, and it is invisible to every other test in this file:
        // each of those passes just as happily with "Export…".
        #expect(ExportMenuPolicy.title == "Export Audio…")
        #expect(ExportMenuPolicy.title != "Export…")
        #expect(ExportMenuPolicy.title != "Export MIDI…")
        // Names its medium, like the two imports directly above it.
        #expect(ExportMenuPolicy.title.contains("Audio"))
    }

    @Test("the ellipsis is the CHARACTER, and it promises a dialog")
    func titleUsesTheEllipsisCharacter() {
        // macOS uses the trailing ellipsis to promise that an item opens
        // something to confirm rather than acting immediately — true here (the
        // item opens the Export dialog; the save panel comes from the dialog's
        // own button). Three periods is a different string that renders wrong
        // beside the menu's other items.
        #expect(ExportMenuPolicy.title.hasSuffix("…"))
        #expect(ExportMenuPolicy.title.hasSuffix("...") == false)
    }

    @Test("one title for both states — a disabled export promises nothing extra")
    func titleIsStableAcrossStates() {
        // Unlike `DeleteMenuPolicy`, which needs a separate inert title because
        // its live titles name a blast radius ("Delete 3 Clips"). This item
        // names no quantity and destroys nothing, so the greyed and live titles
        // are the same string — pinned so a future "Export Audio (0 tracks)…"
        // cannot creep in.
        #expect(ExportMenuPolicy.fileMenuItem(trackCount: 0).title
                == ExportMenuPolicy.fileMenuItem(trackCount: 5).title)
    }

    // MARK: - The mount: source pins over `Sources/DAWApp/FileCommands.swift`
    //
    // ⚠️ A TOKEN SEARCH FINDS THE TOKEN, NOT THE BEHAVIOUR. If one of these
    // fails, do not "fix" it by rewording the source — each names the failure it
    // exists to catch. Same idiom as `EditorSurfaceOwnershipSiteTests`, anchored
    // via `#filePath` so it runs headless with no bundle resources.

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
        // A pin that silently finds no files reports the cleanest possible
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

    /// Every line with comments removed: a comment-only line becomes empty and a
    /// trailing `// …` is cut. THIS IS WHAT MAKES "ZERO" AN ASSERTABLE NUMBER —
    /// `openExportSheet` and `.keyboardShortcut` are both legitimately DISCUSSED
    /// in the prose of the very item these pins guard, and that prose must
    /// survive.
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

    private static var fileCommandsCode: [String] { codeOnly(text("DAWApp/FileCommands.swift")) }

    @Test("the menu item calls exportSong() — the SAME entry point the transport chip uses")
    func menuCallsTheOneEntryPoint() {
        let code = Self.fileCommandsCode
        // The action must be the bare call, inline on the `Button`, so there is
        // no private helper in this file for a save panel to grow inside.
        let actionLines = code.filter { $0.contains("exportSong()") }
        #expect(actionLines.count == 1,
                "expected exactly one exportSong() call in FileCommands, found \(actionLines.count)")
        #expect(actionLines.first?.contains("Button(") == true,
                "the export action must be inline on the Button, not delegated to a helper")
        #expect(actionLines.first?.contains("model.exportSong()") == true)
    }

    @Test("the menu does NOT reach past exportSong() into the dialog's internals")
    func menuDoesNotBypassTheEntryPoint() {
        // `AppModel.openExportSheet` has exactly two callers — `exportSong()`
        // and the `debug.exportDialog {open}` seam — both inside `DAWProApp`.
        // A third here would be a parallel path: `exportSong` is the documented
        // one home, and the transport chip, the onboarding tour and this menu
        // must not be able to drift in what "export" means.
        let code = Self.fileCommandsCode
        #expect(code.contains { $0.contains("openExportSheet") } == false)
        #expect(code.contains { $0.contains("showExportSheet") } == false)
        // And it must not re-ship the pre-m23-m3 export: a bare save panel
        // straight into `renderBounce` with every format parameter defaulted,
        // which is exactly the hardcoded-`.wav` bug m23-m2/m3 removed.
        #expect(code.contains { $0.contains("renderBounce") } == false)
        #expect(code.contains { $0.contains("exportDialog") } == false)
    }

    @Test("the Export Audio item carries NO keyboard shortcut (m23-g1, m23-cf)")
    func exportItemHasNoKeyEquivalent() {
        // ⚠️ THE POINT OF THIS PIN. A shortcut here cannot be verified from
        // staging — m23-g1: an unbundled binary does not route real key events —
        // and m23-cf is open on an undiagnosed DELETE-key routing defect, so a
        // second key path into the app would make both harder to diagnose. It is
        // an easy, plausible-looking "improvement"; this is what notices it.
        //
        // Scoped to the item's own statement: from the `exportSong()` line up to
        // the next `Button(`, so the shortcuts on New / Open / Import / Save
        // (which are shipped and correct) are untouched.
        let code = Self.fileCommandsCode
        guard let start = code.firstIndex(where: { $0.contains("exportSong()") }) else {
            Issue.record("no exportSong() call found in FileCommands — the menu item is gone")
            return
        }
        for line in code[start...].dropFirst() {
            if line.contains("Button(") { break }
            #expect(line.contains("keyboardShortcut") == false,
                    "the Export Audio item must ship without a key equivalent: \(line)")
        }
        #expect(code[start].contains("keyboardShortcut") == false)
    }

    @Test("the title is not duplicated in DAWApp — the policy owns the string")
    func titleIsNotRespelledAtTheMount() {
        // The mount reads `exportAudio.title`; a literal here would be a second
        // home for the one string this policy exists to decide, free to drift
        // from the collision reasoning above.
        let code = Self.fileCommandsCode
        #expect(code.contains { $0.contains("Export Audio") } == false)
        #expect(code.contains { $0.contains("ExportMenuPolicy") })
        // Placed with the other export rather than orphaned at the bottom of the
        // menu: the audio export and the MIDI export must be ADJACENT, so a user
        // hunting for one finds the other.
        //
        // Stated as "no other item between them" rather than as a line distance,
        // which is the property that actually matters and the only one that
        // survives a modifier being added to either Button — a `<= 2` line gap
        // was MEASURED to break on exactly that (it failed at 3 during this
        // suite's own mutation check).
        guard let audio = code.firstIndex(where: { $0.contains("exportSong()") }),
              let midi = code.firstIndex(where: { $0.contains("Button(\"Export MIDI") }) else {
            Issue.record("could not locate both export items in FileCommands")
            return
        }
        let between = code[min(audio, midi)..<max(audio, midi)].dropFirst()
        #expect(between.contains { $0.contains("Button(") || $0.contains("Divider()") } == false,
                "nothing may come between the two export items in the File menu")
    }
}
