import Foundation
import Testing

/// m25-c — the SOURCE-SHAPE half of exposing Humanize in the app UI.
///
/// **WHY A SITE TEST.** `HumanizeModelTests` proves the state machine. It cannot
/// prove the panel is REACHABLE, and — far more important — it cannot prove the
/// panel is listed in `AppModel.isModalPresented`. That list carries an explicit
/// maintenance obligation in its own doc comment (*"a new blocking modal must be
/// added to this list"*) and what it prevents, verbatim, is the **SILENT
/// DESTRUCTION of the user's clips behind a panel they are looking at**: a
/// DELETE keypress while a scrimmed modal is up. A Humanize panel omitted from
/// that list reintroduces exactly that bug, and NO test that merely opens the
/// panel would catch it. `DAWApp` is an `executableTarget` with no test target,
/// so this file is the only thing in the repo that can see any of it.
///
/// ⚠️ **THIS IS A SHAPE PIN, NOT A BEHAVIOURAL MEASUREMENT.** Nothing in this
/// tree can observe a real DELETE keypress landing behind a live scrim — an
/// unbundled staging binary does not route real key events (m23-g1). What is
/// asserted here is that the guard is WRITTEN, and that the delete handler still
/// consults it. A human press remains the only instrument for the rest.
///
/// Same idiom as `DeleteKeySiteTests` / `EditorMaximizeSiteTests`: anchored to
/// the repo via `#filePath`, comments stripped so prose about a symbol cannot
/// satisfy an assertion about code. Every extractor here is POSITIVE-CONTROLLED
/// against a symbol known to be present, because a broken brace-matcher and a
/// genuinely clean file produce the identical green.
@Suite("Humanize panel — reachable, and blocking (m25-c)")
struct HumanizePanelSiteTests {

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

    /// Comments removed, so prose ABOUT a symbol cannot satisfy an assertion
    /// about the symbol. Every file this item touched discusses the modal list
    /// at length; without this, "the panel is in `isModalPresented`" would pass
    /// off a doc comment that merely SAYS so.
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

    private static func code(_ relativePath: String) -> String {
        codeOnly(text(relativePath))
    }

    /// The text between the braces that OPEN at the end of `marker`, by brace
    /// matching. Deliberately marker-based rather than `func`-based:
    /// `isModalPresented` is a computed **var**, which `DeleteKeySiteTests`'
    /// `func \(name)(` extractor cannot find at all — it would return nil and a
    /// careless caller would read that as "clean".
    ///
    /// Returns nil when the marker is absent, which every caller treats as a
    /// FAILURE: "renamed" and "correct" must never look the same here.
    private static func bracedBody(after marker: String, in content: String) -> String? {
        guard let markerRange = content.range(of: marker) else { return nil }
        var depth = 1          // the marker's own trailing `{`
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

    private static let appPath = "DAWApp/DAWProApp.swift"

    // MARK: - THE TRAP: the panel must scrim DELETE

    /// The whole reason this file exists. `humanizePanelClipID` must be INSIDE
    /// the `isModalPresented` body — not merely somewhere in the file, which it
    /// unavoidably is (it is declared there).
    ///
    /// Controls, both required:
    ///   • POSITIVE — the same extraction finds `quantizePanelClipID`, the modal
    ///     that was already in the list. If the brace matcher broke or the
    ///     marker drifted, this fails first and tells you the INSTRUMENT is
    ///     wrong rather than letting a green pass for a missing guard.
    ///   • NEGATIVE — `showEngineNotices` is NOT in the list. Its exclusion is
    ///     deliberate and documented (a passive bottom banner, not a scrimmed
    ///     modal; blocking DELETE under it would be the usability bug). If it
    ///     ever appears, someone read the obligation as "add everything".
    @Test("the humanize panel is a BLOCKING modal — DELETE cannot reach the clips behind it")
    func humanizePanelIsInTheModalList() {
        let app = Self.code(Self.appPath)
        guard let body = Self.bracedBody(after: "var isModalPresented: Bool {", in: app) else {
            Issue.record("could not extract the isModalPresented body — the marker moved; FIX THE EXTRACTOR, do not assume the guard is fine")
            return
        }
        #expect(body.contains("quantizePanelClipID"),
                "POSITIVE CONTROL FAILED: the extractor cannot even see the modal that was already listed, so its verdict on humanize means nothing.")
        #expect(body.contains("humanizePanelClipID"),
                "the Humanize panel is NOT in isModalPresented — a DELETE keypress while it is open will destroy the arrange selection behind its scrim. This is the exact failure that comment names.")
        #expect(!body.contains("showEngineNotices"),
                "NEGATIVE CONTROL FAILED: showEngineNotices is excluded on purpose (a passive banner, not a scrimmed modal).")
    }

    /// The other half of the same guard: the delete handler must still ASK. A
    /// panel correctly listed in a flag nobody consults is not a guard.
    @Test("handleArrangeDeleteKey still consults the modal flag")
    func deleteKeyStillConsultsTheModalFlag() {
        let app = Self.code(Self.appPath)
        guard let body = Self.bracedBody(after: "func handleArrangeDeleteKey() -> Bool {", in: app) else {
            Issue.record("could not extract handleArrangeDeleteKey — the signature moved; FIX THE EXTRACTOR")
            return
        }
        #expect(body.contains("guard !isModalPresented"),
                "the arrange DELETE path no longer consults isModalPresented, so listing a panel there buys nothing.")
        // Positive control: the extractor really did read a populated body.
        #expect(body.contains("arrangeSelection"),
                "POSITIVE CONTROL FAILED: the extracted handleArrangeDeleteKey body does not mention the selection it deletes.")
    }

    // MARK: - Reachability: the six sites

    /// The AppModel half — state, opener, closer, and an apply that closes.
    @Test("AppModel owns the panel state and the open/close/apply trio")
    func appModelWiring() {
        let app = Self.code(Self.appPath)
        #expect(app.contains("var humanizePanelClipID: UUID?"))
        #expect(app.contains("let humanizeModel: HumanizeModel"))
        #expect(app.contains("func openHumanizePanel(clipID: UUID)"))
        #expect(app.contains("func closeHumanizePanel()"))
        guard let apply = Self.bracedBody(after: "func applyHumanize() {", in: app) else {
            Issue.record("applyHumanize is missing — the panel cannot do anything")
            return
        }
        #expect(apply.contains("humanizeModel.apply()"))
        // The panel MUST close on apply. `humanizeClipNotes` does not coalesce
        // and its own doc says a re-run COMPOUNDS the jitter, so a lingering
        // panel invites an accidental second apply that drifts the notes twice
        // as far — this is `applyQuantize`'s reasoning, for the same hazard.
        #expect(apply.contains("closeHumanizePanel()"),
                "the panel does not close on Apply; a second press COMPOUNDS the jitter (the store method does not coalesce).")
    }

    /// The presentation half — an overlay bound to the panel state.
    @Test("ContentView presents the panel over a scrim")
    func contentViewPresents() {
        let content = Self.code("DAWApp/ContentView.swift")
        #expect(content.contains("model.humanizePanelClipID != nil"))
        #expect(content.contains("HumanizePanel("))
        #expect(content.contains("model.applyHumanize()"))
        #expect(content.contains("model.closeHumanizePanel()"))
        // Both entry points are wired from here.
        #expect(content.contains("model.openHumanizePanel(clipID: clip.id)"))
    }

    /// The piano-roll half — a chip that is DEFINED and actually MOUNTED. A
    /// defined-but-unmounted chip compiles, ships, and is unclickable, which is
    /// the precise defect m25-c exists to fix.
    @Test("the piano-roll header mounts a HUMANIZE chip")
    func pianoRollChipIsMounted() {
        let roll = Self.code("DAWApp/PianoRoll/PianoRollView.swift")
        #expect(roll.contains("var onOpenHumanize: () -> Void"))
        guard let chip = Self.bracedBody(after: "private var humanizeChip: some View {", in: roll) else {
            Issue.record("humanizeChip is not defined in PianoRollView")
            return
        }
        #expect(chip.contains("onOpenHumanize"), "the chip does not call its own closure")
        #expect(chip.contains("HUMANIZE"), "the chip has no readable label")

        guard let header = Self.bracedBody(after: "private var header: some View {", in: roll) else {
            Issue.record("could not extract the piano-roll header — the marker moved; FIX THE EXTRACTOR")
            return
        }
        #expect(header.contains("quantizeChip"),
                "POSITIVE CONTROL FAILED: the extracted header does not contain the chip that was already there.")
        #expect(header.contains("humanizeChip"),
                "humanizeChip is defined but never mounted — it ships unclickable, which is the bug m25-c exists to fix.")
    }

    /// The arrange half — a "Humanize…" entry that lives INSIDE the MIDI-only
    /// branch. `humanizeClipNotes` throws `notAMIDIClip` on audio, so the entry
    /// must not exist there: hidden, never offered-then-errored (the sibling
    /// "Quantize…" / "Convert to Voice…" rule in this same menu).
    @Test("the arrange clip menu offers Humanize on MIDI clips only")
    func arrangeMenuEntryIsMIDIOnly() {
        let timeline = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        #expect(timeline.contains("var onOpenHumanize:"))
        #expect(timeline.contains("onOpenHumanize: { onOpenHumanize(clip) }"),
                "the ClipBlock closure is not threaded from the lane view")

        guard let midiOnly = Self.bracedBody(after: "if clip.isMIDI {", in: timeline) else {
            Issue.record("could not extract the MIDI-only menu branch — FIX THE EXTRACTOR")
            return
        }
        #expect(midiOnly.contains("Quantize…"),
                "POSITIVE CONTROL FAILED: the extracted MIDI-only branch does not contain the entry known to live there.")
        #expect(midiOnly.contains("Humanize…"),
                "the Humanize entry is outside the MIDI-only branch — on an audio clip it would be offered and then throw notAMIDIClip.")
    }

    // MARK: - The wire decision, asserted rather than remembered

    /// m25-c is UI-ONLY. `clip.humanize` ALREADY exists on the wire and in MCP —
    /// the missing half was the human-clickable one. So the panel must add NO
    /// command: `allCommands` stays whatever it was before this test landed
    /// (pinned independently by `AUParamCommandTests`, 176 as of m25-z) and
    /// MCP stays in step (179 as of m25-z). Panel visibility is view chrome
    /// and rides the existing `debug.panelLayout` echo, the
    /// `editorEscapeMountHits` precedent.
    @Test("the panel adds no wire surface — the capability already had one")
    func staysOffTheWire() {
        let control = Self.text("DAWControl/Commands.swift")
        // Positive control: the reader really is reading a populated Commands.swift.
        #expect(control.count > 10_000, "Commands.swift came back short: \(control.count) chars")
        #expect(control.contains("\"clip.humanize\""),
                "POSITIVE CONTROL FAILED: clip.humanize is not in Commands.swift, so an absence check there proves nothing.")
        for banned in ["humanizePanel", "HumanizePanel", "humanize.panel"] {
            #expect(!control.contains(banned),
                    "\(banned) reached DAWControl — the PANEL is view chrome; the capability it drives already has clip.humanize, and a new entry breaks the wire-count pins.")
        }
        // The panel's visibility is REPORTED on the existing debug echo.
        //
        // ⚠️ READ HALF ONLY, AND THAT IS NOT A COMPLETE SEAM. The sibling
        // `EditorMaximizeSiteTests` asserts BOTH an echo and a write
        // (`params["editorMaximized"]`); there is no equivalent write here, so
        // nothing can OPEN this panel headlessly and `humanizePanelVisible`
        // reads `false` in every staging flow. This assertion therefore pins
        // only that the reporting key exists — it does NOT establish that any
        // capture can observe the panel. Closing that needs a
        // `debug.panelLayout {humanizePanel}` param (off `allCommands` like
        // every `debug.*` verb); until then a human is the only instrument.
        let app = Self.code(Self.appPath)
        #expect(app.contains("\"humanizePanelVisible\""),
                "the debug echo no longer reports the panel, so even the read half of the capture seam is gone.")
    }
}
