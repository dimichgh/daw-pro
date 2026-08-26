import Foundation
import Testing

/// m25-b-2 — the SOURCE-SHAPE half of the piano roll's viewport minimap.
///
/// **WHY THIS EXISTS.** `PianoRollMinimapTests` proves the RULES: what the mapping
/// is, where a press lands, that a jump delivered through the manual-scroll seam
/// suspends follow. It cannot prove any of it is WIRED — that the roll actually
/// mounts the map, that the jump actually travels `scrollExternally` rather than
/// follow's own target path, that the vertical anchor is mounted where the safety
/// argument requires, or that the map reads the scrollers' REPORTED offsets. All of
/// that lives in `DAWApp`, which has **no test target**, so a perfect rule could sit
/// beside a view that never calls it and every suite would stay green. This file is
/// that gap's substitute — the `EditorMaximizeSiteTests` idiom, same harness.
///
/// ⚠️ **A TOKEN SEARCH FINDS THE TOKEN, NOT THE BEHAVIOUR.** If one of these fails,
/// do not "fix" it by rewording the source. Every assertion names the failure it
/// exists to catch; read that first.
@Suite("Viewport minimap — the wiring pins (m25-b-2)")
struct PianoRollMinimapSiteTests {

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

    /// Comments removed, so a doc comment DISCUSSING a call can never satisfy an
    /// assertion about the code MAKING it. Every assertion below runs on this — and
    /// this file is thick with prose about `scrollExternally`, so without the
    /// stripper the central pin would pass on its own explanation.
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

    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"
    private static let mapViewPath = "DAWApp/Components/PianoRollMinimapView.swift"
    private static let appPath = "DAWApp/DAWProApp.swift"

    /// ⭐ THE CONTROL FOR EVERY ASSERTION BELOW. A reader that never looked and a
    /// reader that looked and found nothing produce the same output.
    @Test("the source reader actually reads the three files (the negative control)")
    func readerControl() {
        for path in [Self.rollPath, Self.mapViewPath, Self.appPath] {
            let code = Self.codeOnly(Self.text(path))
            #expect(code.count > 2_000, "\(path) came back suspiciously short: \(code.count) chars")
        }
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(Self.occurrences(of: "gridScrollX", in: roll) > 0)
        #expect(Self.occurrences(of: "zzNotARealToken", in: roll) == 0)
        // And the stripper does its job: this file's own prose is full of the token
        // the central pin searches for, so prove comments really are removed.
        let stripped = Self.codeOnly("// scrollExternally in a comment\nlet x = 1\n")
        #expect(!stripped.contains("scrollExternally"))
    }

    // MARK: - The map is actually mounted

    @Test("The roll mounts the minimap overlay in the editor's corner")
    func mapIsMounted() {
        let code = Self.codeOnly(Self.text(Self.rollPath))
        let note = "the roll no longer mounts `minimapOverlay`; the whole feature is unreachable " +
            "and every PianoRollMinimapTests leg would still pass."
        #expect(code.contains("PianoRollMinimapView("), "\(note)")
        #expect(code.contains(".overlay(alignment: .bottomTrailing) { minimapOverlay }"), "\(note)")
        // The collapsed face has to exist too, or a dismissal is permanent.
        #expect(code.contains("PianoRollMinimapChip("),
                "the map can be collapsed but not brought back — a one-way dismissal.")
    }

    @Test("Visibility comes from the PERSISTED slot, not from view state")
    func visibilityIsPersisted() {
        let code = Self.codeOnly(Self.text(Self.rollPath))
        let note = "minimap visibility is no longer read from `layout.pianoRollMinimap`. The roll " +
            "is mounted `.id(clip.id)`, so a view-local flag resurrects the map on every " +
            "clip switch — the 'I turned this off and it keeps coming back' defect."
        #expect(code.contains("layout.pianoRollMinimap"), "\(note)")
        #expect(code.contains("layout.setPianoRollMinimap(false)"), "\(note)")
        #expect(code.contains("layout.setPianoRollMinimap(true)"), "\(note)")
    }

    // MARK: - ⭐⭐ The follow-playhead precedence decision

    /// **THE CENTRAL PIN.** The whole precedence decision is the choice of seam:
    /// `scrollExternally` is the MANUAL-scroll path, so the landing reads as the
    /// user and follow stands down. Route the jump through `followTargetX`/
    /// `followNonce` directly instead and the feature still appears to work — the
    /// view scrolls — while the follow runtime never learns a user moved it, so the
    /// next transport tick yanks the view back and the chip keeps claiming it is
    /// following. That is a silent tug-of-war, and no unit test can see it.
    @Test("A minimap jump travels the MANUAL-scroll seam")
    func jumpUsesTheManualScrollSeam() {
        let code = Self.codeOnly(Self.text(Self.rollPath))
        let note = "the minimap jump no longer calls `follow.scrollExternally`. Follow then never " +
            "learns the user moved the view, so it will yank the roll back on the next " +
            "transport tick while the chip still shows FOLLOWING."
        #expect(code.contains("follow.scrollExternally(to: target.x)"), "\(note)")
    }

    /// ⚠️ The half the pin above cannot see: that the stand-down was NOT bought by
    /// switching the shared persisted enable off. That flag is read by the arrange
    /// lanes too, so writing it here would stop follow on a surface the user never
    /// touched — and would outlive the gesture by every future session.
    @Test("A jump never writes the shared persisted followPlayhead flag")
    func jumpLeavesTheSharedEnableAlone() {
        let code = Self.codeOnly(Self.text(Self.rollPath))
        let note = "the roll is writing the SHARED follow enable. A piano-roll gesture must not " +
            "stand the arrange's follow down, nor persist a stand-down past the gesture."
        #expect(!code.contains("setFollowPlayhead("), "\(note)")
    }

    // MARK: - The map reads REPORTED offsets, on both axes

    /// The rectangle must be drawn from where the scrollers say they are, never
    /// from a predicted or pointer-derived value — otherwise a clamped scroll (the
    /// ends of the part, the commonest case) draws the box somewhere the editor is
    /// not.
    @Test("The rectangle is fed by the scrollers' own reported offsets")
    func rectangleIsFedByGroundTruth() {
        let code = Self.codeOnly(Self.text(Self.rollPath))
        #expect(code.contains("scrollX: gridScrollX"),
                "the map is no longer fed the grid's reported horizontal offset.")
        #expect(code.contains("scrollY: gridScrollY"),
                "the map is no longer fed the editor's reported vertical offset.")
        #expect(code.contains("gridScrollY = -newValue"),
                "the vertical scroll reader is gone; the rectangle can no longer move in pitch.")
        #expect(code.contains("editorViewportHeight = newValue"),
                "the viewport-height reader is gone; the rectangle's height is a guess.")
    }

    /// The vertical reader must NOT report into the follow runtime. Follow here is
    /// a one-axis mechanism (one offset against one content width), so feeding it
    /// pitch scrolls would make every vertical move look like a manual HORIZONTAL
    /// scroll and suspend follow for a gesture that never contested it.
    @Test("The vertical reader reports to the map only, never into follow")
    func verticalReaderDoesNotFeedFollow() {
        let code = Self.codeOnly(Self.text(Self.rollPath))
        // Exactly one `reportOffset` call site in the roll: the horizontal one.
        let note = "a second `reportOffset` call appeared — if it is the vertical reader, every " +
            "pitch scroll now suspends follow for a fight that never happened."
        #expect(Self.occurrences(of: "follow.reportOffset(", in: code) == 1, "\(note)")
    }

    // MARK: - The vertical anchor's placement IS the safety argument

    /// ⚠️⚠️ A `ScrollViewReader` resolves `scrollTo` against EVERY scroll view
    /// inside its content (`PianoRollView.swift:1598-1606`, measured at m23-c2).
    /// The vertical reader necessarily spans both axes, so what keeps it safe is
    /// that the horizontal scroller cannot resolve this id — the anchor is mounted
    /// on the keyboard gutter, a SIBLING of that scroller. Move it into the grid
    /// and every vertical jump also re-centres the view horizontally.
    @Test("The vertical anchor is mounted on the gutter, outside the horizontal scroller")
    func verticalAnchorIsOutsideTheHorizontalScroller() {
        let source = Self.text(Self.rollPath)
        let code = Self.codeOnly(source)
        #expect(code.contains(".overlay(alignment: .topLeading) { verticalJumpMarker }"),
                "the vertical jump anchor is no longer mounted on the keyboard gutter.")
        // It must be attached to the gutter, not to the grid: the gutter mount has
        // to appear BEFORE the horizontal ScrollView opens.
        guard let markerAt = code.range(of: "{ verticalJumpMarker }"),
              let hScrollAt = code.range(of: "ScrollView(.horizontal") else {
            Issue.record("Could not locate the marker mount and the horizontal scroller.")
            return
        }
        let inside = "the vertical jump anchor moved INSIDE the horizontal scroller. That " +
            "scroller can now resolve the id, so `anchor: .top`'s x = 0.5 will re-centre the " +
            "view horizontally on every vertical jump."
        #expect(markerAt.lowerBound < hScrollAt.lowerBound, "\(inside)")
        let anchored = "the vertical jump lost its `.top` anchor; `.center` would land the " +
            "target in the middle of the viewport rather than where the map's box says it is."
        #expect(code.contains("anchor: .top"), "\(anchored)")
    }

    /// The m17-b durability rule: a `scrollTo` not re-issued on a fresh main-actor
    /// turn moves layout without updating the scroller's internal position, and any
    /// later forced re-render jumps back to the stale value. The horizontal path
    /// already obeys it; the vertical path must too, or a capture/resize undoes the
    /// jump.
    @Test("The vertical jump re-issues its scrollTo on a fresh turn (m17-b durability)")
    func verticalJumpIsDurable() {
        let code = Self.codeOnly(Self.text(Self.rollPath))
        guard let onChange = code.range(of: "onChange(of: verticalNonce)") else {
            Issue.record("The vertical jump's nonce handler is gone.")
            return
        }
        let tail = String(code[onChange.lowerBound...].prefix(400))
        let note = "the vertical jump issues its scrollTo only once. Without the deferred " +
            "re-issue the scroller's internal position stays stale and a later re-render " +
            "jumps back (m17-b, measured)."
        #expect(Self.occurrences(of: "verticalProxy.scrollTo(", in: tail) == 2, "\(note)")
        #expect(tail.contains("Task { @MainActor in"),
                "the deferred re-issue is no longer on a fresh main-actor turn.")
    }

    // MARK: - Draw-path discipline

    /// The map's moving parts must not live inside the note Canvas. The viewport
    /// rectangle moves on every scroll report and the playhead on every transport
    /// tick; drawing either inside the Canvas would re-invoke the note draw closure
    /// — and re-allocate the pill array — at tick rate, on a surface that
    /// previously only redrew on an edit.
    @Test("The moving parts are OFFSET views, not Canvas redraws")
    func movingPartsAreOffsetViews() {
        let code = Self.codeOnly(Self.text(Self.mapViewPath))
        // ⚠️ Pinned on `Canvas(opaque:`, NOT on `Canvas(` — the latter is a
        // SUBSTRING of `MinimapNotesCanvas(`, so it counted the call site as a
        // second Canvas and failed on correct code. A `contains`/`components`
        // assertion over source is a substring test unless the needle is anchored.
        #expect(Self.occurrences(of: "Canvas(opaque:", in: code) == 1,
                "the map has more than one Canvas; the moving parts belong in offset views.")
        // The notes Canvas takes no closures and no scroll offsets — that is what
        // lets SwiftUI skip it entirely on a tick.
        guard let canvasStruct = code.range(of: "private struct MinimapNotesCanvas") else {
            Issue.record("The notes Canvas is no longer its own struct — a tick now redraws it.")
            return
        }
        let tail = String(code[canvasStruct.lowerBound...])
        for banned in ["scrollX", "scrollY", "playhead", "isDragging"] {
            let note = "`\(banned)` reached the notes Canvas. Its inputs must stay TICK-STABLE, " +
                "or the pill array is rebuilt on every scroll report and every transport tick."
            #expect(!tail.contains(banned), "\(note)")
        }
    }

    // MARK: - The wire decision

    /// Visibility rides `debug.panelLayout`, the documented non-invokable window
    /// preference (`docs/DESIGN-LANGUAGE.md`). A new `allCommands` entry would
    /// break the wire-count pins to buy an agent control over where a human is
    /// looking.
    @Test("Visibility is staged on debug.panelLayout and adds no wire surface")
    func stagedOnTheDebugTier() {
        let code = Self.codeOnly(Self.text(Self.appPath))
        #expect(code.contains("panelLayout.setPianoRollMinimap("),
                "`debug.panelLayout` no longer stages the map — a capture cannot pin its state.")
        #expect(code.contains("\"pianoRollMinimap\": .bool(panelLayout.pianoRollMinimap)"),
                "the echo dropped `pianoRollMinimap`; staging it becomes unverifiable.")
    }
}
