import Foundation
import Testing

/// m23-ap Increment C (C1 drag · C3 split · C4 zoom) — **THE WIRING BETWEEN THE
/// PANE AND THE STORE, WHICH NOTHING ELSE CAN SEE.**
///
/// ⚠️⚠️ `Sources/DAWApp` has no test target. `PitchEditorModelTests` owns the
/// half that matters most — the COMMIT CADENCE — and owns it honestly, because
/// the model emits every commit through one injected closure that a test can
/// count. What a test cannot reach is whether the VIEW handed that closure to
/// the model, or quietly called the store itself from a `.onChanged`. Those two
/// are the P7b defect (design §11: the vocal goes SILENT for the whole drag,
/// because a per-tick write re-keys `ClipKey.pitchEditSetHash`, the offline
/// render is never ready, and `StretchResolution.pending` skips the clip), and
/// this suite is the only instrument pointed at them.
///
/// ⭐ **A SOURCE-SHAPE GATE IS THE WEAKER KIND AND IS USED HERE ONLY WHERE NO
/// SPY SEAM EXISTS.** Said out loud so the next person reaches for the ledger
/// first. Assertions run against **comment-stripped** source — this file's
/// subjects document their own rules in prose a naive grep would accept
/// (`PitchEditorView.swift` contains the literal words "commit" and
/// "setClipNotePitchOffset" inside banners warning against them).
///
/// ⚠️ NOT `@MainActor`: reading files needs no actor, and an isolated suite
/// would spend one of the review-cadence slots `MainActorOccupancySiteTests`
/// bounds for nothing.
@Suite("Pitch editor interaction wiring (m23-ap Increment C)")
struct PitchEditorInteractionSiteTests {

    // MARK: - Source access (`PitchTuneDoorSiteTests`' reader, verbatim)

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

    /// The body of `func <name>` by brace matching, or nil.
    /// `EditorSurfaceOwnershipSiteTests`' extractor, same shape.
    private static func body(of name: String, in code: String) -> String? {
        guard let start = code.range(of: "func \(name)(") else { return nil }
        guard let open = code[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var out = ""
        var index = open
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

    private static let viewPath = "DAWApp/PitchEditor/PitchEditorView.swift"
    private static let stagingPath = "DAWApp/PitchCorrectionStaging.swift"
    private static let contentPath = "DAWApp/ContentView.swift"

    /// ⭐ **THE POSITIVE CONTROL FOR THE WHOLE SUITE.** Every assertion below is
    /// a `contains` (or a `!contains`) over stripped source. A path typo, a
    /// stripper that returned "", or a rename would make the NEGATIVE
    /// assertions pass for the wrong reason — an absence that confirms the
    /// hypothesis is the weakest evidence there is. This proves the reader
    /// reaches real code, and that it really does strip comments.
    @Test("the source reader reaches real code and strips comments (positive control)")
    func readerWorks() {
        let view = Self.code(Self.viewPath)
        #expect(view.contains("struct PitchEditorView: View"))
        #expect(view.contains("func dragChanged("))
        #expect(view.count > 5_000)
        // These phrases exist ONLY inside comments in that file, so their
        // ABSENCE here is what proves the stripper ran.
        #expect(!view.contains("the vocal goes silent for the whole drag"))
        #expect(!view.contains("AutomationLaneEditor"))
    }

    // MARK: - P7b: the view cannot commit per tick, because it cannot commit at all

    @Test("⛔ `dragChanged` contains NO commit of any kind — the P7b guard at the view layer")
    func aDragTickCannotReachTheStore() {
        let view = Self.code(Self.viewPath)
        guard let fn = Self.body(of: "dragChanged", in: view) else {
            Issue.record("""
                could not find `func dragChanged(` in \(Self.viewPath) — if it was renamed, \
                RENAME IT HERE TOO. A missing function must never read as a clean pass
                """)
            return
        }
        for banned in ["onCommitNoteEdit", "endPitchDrag", "splitNote", "commitPitchNoteEdit",
                       "setClipNotePitchOffset", "splitClipNoteSegment"] {
            #expect(!fn.contains(banned), """
                `dragChanged` calls `\(banned)`. A pointer tick must never commit: it re-keys \
                ClipKey.pitchEditSetHash at pointer rate, the offline render is never ready, \
                StretchResolution.pending SKIPS the clip, and the vocal goes silent for the whole \
                drag (design §8.2 / §11 P7b). Update a draft; commit on gesture END.
                """)
        }
        // The POSITIVE half: a `dragChanged` that did NOTHING would also pass
        // every ban above. This is what makes it a pin rather than a ban list.
        #expect(fn.contains("updatePitchDrag"),
                "`dragChanged` does not update the draft — the ban above is measuring nothing")
    }

    @Test("the commit closure is installed on the MODEL, and the view never calls it")
    func theViewHandsTheCommitSeamToTheModel() {
        let view = Self.code(Self.viewPath)
        // Installed exactly once, at mount.
        #expect(view.contains("model.onCommit = onCommitNoteEdit"))
        // ⛔ AND CALLED NOWHERE. `onCommitNoteEdit(` with an open paren is the
        // call shape; the assignment above has no paren, so this ban cannot
        // trip on the installation itself.
        #expect(!view.contains("onCommitNoteEdit("), """
            PitchEditorView calls `onCommitNoteEdit(` directly. The model owns the commit \
            cadence (design §8.2) and is the only thing allowed to call it — that is what makes \
            PitchEditorModelTests.aDragTickNeverCommits a gate over the real cadence rather than \
            a grep over a DragGesture closure.
            """)
        // And the pane never reaches the store itself.
        for banned in ["store.setClipNotePitchOffset", "store.splitClipNoteSegment",
                       "store.autoCorrectClipPitch"] {
            #expect(!view.contains(banned), """
                PitchEditorView reaches the store directly via `\(banned)` — every write goes \
                through AppModel's funnel, which is where the read-back lives
                """)
        }
    }

    @Test("`dragEnded` is the ONE gesture path that can produce a write")
    func gestureEndIsTheOnlyCommitPath() {
        let view = Self.code(Self.viewPath)
        guard let fn = Self.body(of: "dragEnded", in: view) else {
            Issue.record("""
                could not find `func dragEnded(` in \(Self.viewPath) — if it was renamed, \
                RENAME IT HERE TOO
                """)
            return
        }
        #expect(fn.contains("endPitchDrag"))
        #expect(fn.contains("splitNote"))
    }

    // MARK: - The read-back, which is the whole point of the funnel

    @Test("⛔ the funnel READS THE FIELD BACK rather than trusting that the call returned")
    func theCommitFunnelReadsTheWriteBack() {
        let staging = Self.code(Self.stagingPath)
        guard let fn = Self.body(of: "commitPitchNoteEdit", in: staging) else {
            Issue.record("could not find `func commitPitchNoteEdit(` in \(Self.stagingPath)")
            return
        }
        #expect(fn.contains("store.setClipNotePitchOffset"))
        #expect(fn.contains("store.splitClipNoteSegment"))
        // ⭐ THE ASSERTION THAT MATTERS: the returned clip is INTERROGATED.
        // "A drag that reports success and writes nothing" is this tree's
        // characteristic failure, and `_ = try store.…` would be exactly it.
        #expect(fn.contains("clip.pitchEdits?.segments"), """
            `commitPitchNoteEdit` does not read `clip.pitchEdits?.segments` back. A setter's \
            return is not proof it took — the write must be interrogated, not assumed.
            """)
        #expect(fn.contains("pitchOffsetCents"))
        #expect(fn.contains("endSeconds"))
        // …and a failed read-back SAYS SO. A silent `return` would be the same
        // defect wearing a guard.
        #expect(fn.contains("presentArrangeSplitRefusal"))
        // ⛔ AND NO `try?`. `tuneVocalFromContextMenu`'s own banner: a `try?`
        // turns a comp-member refusal, a deleted clip and a cut too near an
        // edge into a click that does nothing and says nothing.
        #expect(!fn.contains("try?"), "`commitPitchNoteEdit` swallows an error with `try?`")
    }

    // MARK: - The pane is actually BOUND (the `{ _ in }` default is the quiet failure)

    @Test("ContentView binds the commit funnel and both zoom axes — the default closures do nothing")
    func contentViewBindsTheInteraction() {
        let content = Self.code(Self.contentPath)
        #expect(content.contains("onCommitNoteEdit:"))
        #expect(content.contains("model.commitPitchNoteEdit(clipID: clip.id, commit: commit)"))
        #expect(content.contains("onZoom:"))
        // Both axes, through AppModel's entry points rather than a second
        // ladder spelled at the call site.
        for entry in ["model.zoomPitchEditorIn()", "model.zoomPitchEditorOut()",
                      "model.pitchEditorRowZoomIn()", "model.pitchEditorRowZoomOut()",
                      "model.zoomPitchEditorReset()", "model.pitchEditorRowZoomReset()"] {
            #expect(content.contains(entry), "ContentView does not bind `\(entry)`")
        }
    }

    @Test("the pane re-reads the clip's stored notes, so what is on screen is what was SAVED")
    func thePaneReadsTheStoredTableBack() {
        let view = Self.code(Self.viewPath)
        #expect(view.contains("onChange(of: clip.pitchEdits)"))
        #expect(view.contains("model.syncStoredNoteTable(table)"))
        // ⚠️ And the draft is dropped when the pane goes away: SwiftUI's
        // `DragGesture.onEnded` does not fire on a window resigning key.
        #expect(view.contains("onDisappear { model.cancelDrag() }"))
    }

    // MARK: - C4: the vertical axis exists and is persisted like every other dimension

    @Test("the pitch editor's row height is a real persisted slot, echoed on the debug tier")
    func verticalZoomIsAPersistedSlot() {
        let store = Self.code("DAWAppKit/PanelLayoutModel.swift")
        #expect(store.contains("pitchEditorRowHeightKey"))
        #expect(store.contains("func setPitchEditorRowHeight("))
        #expect(store.contains("setPitchEditorRowHeight(Self.defaultPitchEditorRowHeight)"),
                "the new slot is missing from `PanelLayoutStore.reset()`")
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("params[\"pitchEditorRowHeight\"]?.doubleValue"))
        #expect(app.contains("\"pitchEditorRowHeight\": .number(Double(panelLayout.pitchEditorRowHeight))"))
        // The pane reads the ONE slot rather than keeping its own number.
        let view = Self.code(Self.viewPath)
        #expect(view.contains("rowHeight: layout.pitchEditorRowHeight"))
        #expect(view.contains("onChange(of: layout.pitchEditorRowHeight)"))
    }

    @Test("⚠️ the zoom cluster asks the APP, never `PanelLayoutStore` directly")
    func theZoomClusterUsesTheOneLadder() {
        let view = Self.code(Self.viewPath)
        for banned in ["layout.setPitchEditorPPB", "layout.setPitchEditorRowHeight",
                       "PianoRollZoom.zoomedIn", "PianoRollZoom.tallerRow"] {
            #expect(!view.contains(banned), """
                PitchEditorView writes the zoom slot directly via `\(banned)`. AppModel's \
                zoomPitchEditor*/pitchEditorRowZoom* entry points are the one home for the \
                ladder, shared with ⌘+/⌘−/⌘0 through EditorSurfaceRouter; a second ladder here \
                would disagree with the keyboard about what "one step" means.
                """)
        }
        #expect(view.contains("onZoom(.timeIn)"))
        #expect(view.contains("onZoom(.pitchIn)"))
        #expect(view.contains("onZoom(.reset)"))
    }

    // MARK: - The palette draws its prose, because a tooltip is invisible to a capture

    @Test("the palette DRAWS the active tool's help and reports what it drew")
    func thePaletteDrawsItsProse() {
        let view = Self.code(Self.viewPath)
        #expect(view.contains("Text(tool.help)"), """
            The palette does not DRAW the active tool's help. A `.help()` tooltip is invisible to \
            `view.capture`, so a captured gate cannot tell a correct caption from a missing one — \
            the EQCurveEditor.help lesson, verbatim.
            """)
        // And it reports the strings it drew to the ledger, from the same values.
        #expect(view.contains("chrome?.recordInteraction("))
        #expect(view.contains("toolHelp: model.tool.help"))
        #expect(view.contains("commitCount: model.commitCount"))
    }
}
