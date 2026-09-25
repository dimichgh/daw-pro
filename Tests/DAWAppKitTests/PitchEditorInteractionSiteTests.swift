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
/// are the P7b defect (design §11: a per-tick write re-keys
/// `ClipKey.pitchEditSetHash`, so the offline render is never ready, and the
/// vocal is not heard as edited for the whole drag — since p2-ren Stage A it
/// plays its PREVIOUS version (`StretchResolution.bridge`); the design's
/// "silent" is now only a stretch change's or a failed render's fate,
/// `StretchResolution.pending`), and this suite is the only instrument pointed
/// at them.
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

    /// The braced block that follows `marker` (a computed property's body, say
    /// `private var header: some View`), by the same brace matching, or nil.
    private static func block(after marker: String, in code: String) -> String? {
        guard let start = code.range(of: marker) else { return nil }
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
        // ABSENCE here is what proves the stripper ran. (The first moved with
        // the comment it quotes when p2-ren Stage A made "the vocal goes
        // silent" false; the raw-file check below keeps it from ever passing
        // against a phrase that is simply gone.)
        let controlPhrase = "stale version of the vocal for the whole drag"
        let raw = (try? String(contentsOf: Self.sourcesDir().appendingPathComponent(Self.viewPath),
                               encoding: .utf8)) ?? ""
        #expect(raw.contains(controlPhrase), "the control phrase left the raw file — pick another comment-only phrase")
        #expect(!view.contains(controlPhrase))
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
                and the vocal plays STALE for the whole drag — its previous version \
                (StretchResolution.bridge, p2-ren Stage A), or silence after a stretch change \
                (design §8.2 / §11 P7b). Update a draft; commit on gesture END.
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
                       "store.autoCorrectClipPitch", "store.setClipNotesCleared"] {
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
        // The paren pins the ONE-note call itself: since I4 the bare name is
        // also a prefix of the group call below, so without it this line would
        // stay green with the one-note route deleted.
        #expect(fn.contains("store.setClipNotePitchOffset("))
        #expect(fn.contains("store.splitClipNoteSegment"))
        // m23-ap I4 — the GROUP drag reaches the store through the same funnel,
        // under the SELECTION's undo key (UI design §8.4), never `structuralKey`.
        #expect(fn.contains("store.setClipNotePitchOffsets("))
        #expect(fn.contains("PitchCorrectionUndoKey.group(clipID: clipID"))
        #expect(fn.contains("offsets.allSatisfy"),
                "the group route does not read EVERY named note back — one note that did not land would pass")
        // m23-ap I7b — a CLEAR / RESTORE reaches the store through the same
        // funnel as ONE call ("Clear Notes" / "Restore Notes"), and EVERY named
        // note is read back for the flag it was asked to carry.
        #expect(fn.contains("store.setClipNotesCleared("),
                "the Clear/Restore commit never reaches the store")
        #expect(fn.contains("segmentIDs.allSatisfy"),
                "the clear route does not read EVERY named note back — one note that did not clear would pass")
        #expect(fn.contains("isCleared"),
                "the clear route reads nothing back about the flag it wrote")
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

    // MARK: - m23-ap I4 — the selection, wired both ways and drawn

    /// `PitchEditorModelTests` proves the selection's RULES headless (the click
    /// table, the band, the group drag, the ladder's two pane rungs). What no
    /// model test can see is whether the VIEW hands those answers on: that ⌘A,
    /// the debug clear and the notes' ⌫ reach the model, that the two facts the
    /// app's key policies read are reported out, that a drag on a note drags
    /// the SELECTION, and that a selected note looks selected. Each leg names
    /// the one omission it catches.
    ///
    /// ⚠️ RENAMED AND REWRITTEN at m23-ap I7b from "I4 — the pane is wired to
    /// the selection both ways, drags the selection, and draws it"
    /// (`thePaneIsWiredToTheSelection`). Two legs changed on purpose: ⌫ now
    /// reaches the model's ONE Clear action (it was I4's refusal line,
    /// `refuseDeleteWithNotesSelected`, retired), and the selected look is no
    /// longer I4's `signal` 14 % wash — on a TUNED clip every note already wears
    /// `signal`, and the orchestrator measured three selected notes out of
    /// forty reading as "slightly brighter". It is now its own signal: a white
    /// wash and a glowing white ring, drawn ONCE over every selected note.
    @Test("I7b — the pane is wired to the selection both ways, ⌫ CLEARS it, and a selection is drawn in its own glowing ring")
    func thePaneIsWiredToTheSelectionAndClearsIt() {
        let view = Self.code(Self.viewPath)
        // IN — each request reaches the model's named writer.
        #expect(view.contains(".onChange(of: interaction?.selectAllNonce) { _, _ in model.selectAll() }"),
                "⌘A would be routed to the pane and select nothing")
        #expect(view.contains(".onChange(of: interaction?.clearSelectionNonce) { _, _ in model.clearSelection() }"))
        #expect(view.contains(".onChange(of: interaction?.deleteNonce) { _, _ in model.performNoteAction(.clear) }"),
                "a ⌫ routed to the notes would not clear them — the one action behind ⌫, Edit ▸ Delete and the menu")
        #expect(!view.contains("refuseDeleteWithNotesSelected"),
                "I4's interim refusal line is still wired to ⌫")
        // OUT — the two facts the ⌫ and ⌘A policies read, from the model.
        #expect(view.contains("interaction?.report(hasNoteSelection: !empty)"))
        #expect(view.contains("interaction?.report(drawnNoteCount: count)"))
        #expect(view.contains(".onChange(of: model.selection.isEmpty, initial: true)"))
        #expect(view.contains(".onChange(of: model.blobs.count, initial: true)"))
        // …and the wiring is actually APPLIED to the pane's body.
        #expect(view.contains(".modifier(PitchEditorSelectionWiring("),
                "the selection wiring exists but is attached to nothing")
        // A note drag drags the SELECTION (the model decides who rides along).
        guard let changed = Self.body(of: "dragChanged", in: view) else {
            Issue.record("could not find `func dragChanged(` in \(Self.viewPath)")
            return
        }
        #expect(changed.contains("model.beginSelectionPitchDrag(on: blob)"),
                "the drag begins on the pressed note ALONE — a selection would never move together")
        #expect(!changed.contains("model.beginPitchDrag(on: blob)"))
        // DRAWN: the selection, every moving note lifted, the band, the count.
        #expect(view.contains("selectedIDs: model.selection,"))
        #expect(view.contains("ctx.selectedIDs.contains(blob.id)"))
        // ⭐ THE SELECTED LOOK IS ITS OWN SIGNAL (I7b). Not the tuned note's
        // `signal` again: a white wash over the note and a glowing white ring,
        // the roll's "selected note" grammar (brighter, a `textPrimary`
        // hairline, a bloom) pushed to read at forty notes.
        #expect(view.contains("DAWTheme.textPrimary.opacity(Self.selectedWashOpacity)"),
                "a selected note is not washed brighter")
        guard let glow = Self.body(of: "drawSelectionGlow", in: view) else {
            Issue.record("could not find `func drawSelectionGlow(` in \(Self.viewPath) — the selected ring is not drawn")
            return
        }
        #expect(glow.contains("addFilter(.shadow("), "the selected ring does not glow")
        #expect(glow.contains("DAWTheme.textPrimary"), "the selected ring is not the white selection ink")
        guard let blobs = Self.body(of: "drawBlobs", in: view) else {
            Issue.record("could not find `func drawBlobs(` in \(Self.viewPath)")
            return
        }
        #expect(blobs.contains("Self.drawSelectionGlow(&context"),
                "the selected ring is built and never drawn")
        // Scoped to the NOTE drawing: the same token is the palette's active
        // slot and the TUNING APPLIED badge elsewhere in the file, which the
        // old whole-file pin could not tell apart from a selection.
        #expect(!blobs.contains("DAWTheme.signal.opacity(0.14)"),
                "the selection still wears I4's signal wash — the colour every TUNED note already wears")
        #expect(view.contains("PitchEditorBandView(rect: band.rect)"))
        #expect(view.contains("for member in draft.members"), "a group drag's other notes would vanish mid-drag")
        #expect(view.contains("if let selected = model.selectionSummary"))
        // The echo reads the MODEL's selection, never a re-derivation.
        #expect(view.contains("PitchEditorSelectionReport(ids: model.selection,"))
    }

    // MARK: - m23-ap I7b — clear a note: ONE action, the menu, the look

    /// `PitchEditorModelTests` proves the ACTION headless (one commit carrying
    /// exactly the notes that change, the already-cleared line, the menu's
    /// titles, the played line hidden over a cleared note). What no model test
    /// can see is the VIEW's half: that the right-click menu, ⌫ and the debug
    /// tier's staged step all reach that ONE action and nothing else, that a
    /// right-click selects the note under the pointer first, and that a cleared
    /// note is drawn as a cleared note. Each leg names the one failure it
    /// catches.
    @Test("I7b — the right-click menu, ⌫ and the staged step reach ONE action; a cleared note is drawn hollow, dashed, labelled, over a dimmed waveform")
    func theClearIsOneActionAndDrawn() {
        let view = Self.code(Self.viewPath)
        // 1. THE MENU EXISTS, on the surface that already declares its content
        // shape (a `Canvas` contributes no hit region — the m23-cf law).
        #expect(view.contains(".contextMenu { noteContextMenu(noteMenu, at: hoverPoint) }"),
                "the note editor has no right-click menu")
        guard let menu = Self.body(of: "noteContextMenu", in: view) else {
            Issue.record("could not find `func noteContextMenu(` in \(Self.viewPath)")
            return
        }
        // Its titles and enabled states are the MODEL's (`noteMenu(at:)` →
        // `PitchEditorNoteMenu`), never spelled here…
        #expect(menu.contains("Button(item.title"))
        #expect(menu.contains(".disabled(!item.isEnabled)"))
        #expect(view.contains("let noteMenu = model.noteMenu(at: hoverPoint)"))
        // …and EVERY item runs the one function. ⛔ THE PLANT THIS CATCHES: the
        // menu calling anything other than what ⌫ reaches.
        #expect(menu.contains("runNoteMenu(item.action, at: point)"),
                "the menu's items do not run `runNoteMenu` — the menu and ⌫ would be two actions")
        #expect(!menu.contains("model."),
                "the menu reaches the model directly — every item must go through `runNoteMenu`")
        guard let run = Self.body(of: "runNoteMenu", in: view) else {
            Issue.record("could not find `func runNoteMenu(` in \(Self.viewPath)")
            return
        }
        // 2. THE ONE ACTION. `runNoteMenu` is the menu's right-click half (select
        // the note under the pointer first) plus the SAME model call ⌫ makes.
        #expect(run.contains("model.selectForContextMenu(at: point)"),
                "a right-click on an unselected note would act on the old selection")
        #expect(run.contains("model.performNoteAction(action)"))
        // ⌫ reaches the same model function (the selection wiring, above), and
        // nothing else in the view calls it: exactly two call sites.
        #expect(view.components(separatedBy: "model.performNoteAction(").count - 1 == 2,
                "`model.performNoteAction(` must have exactly two call sites in the view — ⌫'s wiring and `runNoteMenu`")
        // 3. THE STAGED STEP IS THE MENU'S OWN FUNCTION (a synthetic event
        // cannot open a context menu — the m23-g1 law).
        guard let staged = Self.body(of: "applyStagedStep", in: view) else {
            Issue.record("could not find `func applyStagedStep(` in \(Self.viewPath)")
            return
        }
        #expect(staged.contains("case .noteMenu(let action, let point):"))
        #expect(staged.contains("runNoteMenu(action, at: point)"))
        // 4. A REAL RIGHT-CLICK SELECTS FIRST: the catcher hands the press point
        // to the model's own rule before the menu opens, and claims nothing.
        #expect(view.contains("PitchEditorContextClickCatcher(onContextClick: { model.selectForContextMenu(at: $0) })"))
        #expect(view.contains("override func hitTest(_ point: NSPoint) -> NSView? { nil }"),
                "the right-click catcher claims mouse events — it would eat the surface's gestures")
        // 5. THE CLEARED LOOK: hollow, dashed, labelled in the menu's own word,
        // its waveform dimmed.
        guard let blobs = Self.body(of: "drawBlobs", in: view) else {
            Issue.record("could not find `func drawBlobs(` in \(Self.viewPath)")
            return
        }
        #expect(blobs.contains("if blob.isCleared"), "a cleared note is drawn like any other")
        #expect(blobs.contains("Self.clearedDash"), "a cleared note's outline is not dashed")
        guard let labels = Self.body(of: "drawBlobLabels", in: view) else {
            Issue.record("could not find `func drawBlobLabels(` in \(Self.viewPath)")
            return
        }
        #expect(labels.contains("PitchEditorNoteMenu.clearedLabel"), "a cleared note carries no \"cleared\" label")
        #expect(labels.contains("blob.levelReadout"), "a note's level is never drawn")
        guard let wave = Self.body(of: "drawWaveform", in: view) else {
            Issue.record("could not find `func drawWaveform(` in \(Self.viewPath)")
            return
        }
        #expect(wave.contains("isCleared"), "the waveform under a cleared note is not dimmed")
        // 6. THE LINE: the view keeps asking the model for the line as drawn —
        // the model is what hides a cleared stretch (`PitchEditorModelTests`).
        #expect(view.contains("playedSegments = model.playedLineSegments(excludingAll: model.draftSpans)"))
        // 7. THE ECHO reads each drawn note's clear and level from the model.
        #expect(view.contains("cleared: $0.isCleared"))
        #expect(view.contains("levelDb: $0.amplitudeDb"))
    }

    /// Remove Tuning wipes the whole note table — cleared notes included — so
    /// it brings every cleared note back. Both of its doors (the clip menu's
    /// item and the note editor's own button) must say so, from ONE sentence.
    @Test("I7b — both Remove Tuning doors carry ONE help line that counts the cleared notes it brings back")
    func removeTuningSaysItRestoresClearedNotes() {
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        let view = Self.code(Self.viewPath)
        #expect(lanes.contains(".help(PitchEditorNoteMenu.removeTuningHelp("),
                "the clip menu's Remove Tuning says nothing about the cleared notes it brings back")
        #expect(view.contains(".help(PitchEditorNoteMenu.removeTuningHelp("),
                "the note editor's Remove tuning says nothing about the cleared notes it brings back")
        // The words themselves are `PitchEditorNoteMenuTests`' (this suite reads
        // source and imports no module).
    }

    /// I7b-2 — the header's clip badge follows the PITCH half only.
    /// `PitchEditorClipBadgeTests` owns the rule (a clears-only clip reads
    /// NOTES EDITED). What only the source can show is the VIEW's half: that
    /// the capsule draws the resolver's value and not a predicate of its own,
    /// that the spy is handed that same value, and that the report re-fires
    /// when the FACE changes — `hasPitchEdits` stays true across NOTES EDITED →
    /// TUNING APPLIED, so a trigger on it would leave the spy reporting a face
    /// that is gone.
    @Test("I7b-2 — the header draws its clip badge from ONE resolved value, hands the spy that value, and re-reports when the face changes")
    func theClipBadgeIsResolvedOnce() {
        let view = Self.code(Self.viewPath)
        guard let header = Self.block(after: "private var header: some View", in: view) else {
            Issue.record("could not find `private var header: some View` in \(Self.viewPath)")
            return
        }
        #expect(header.contains("let badge = PitchEditorClipBadge.resolve(clip)"),
                "the header does not resolve its badge through `PitchEditorClipBadge`")
        #expect(header.contains("if let badge {"))
        #expect(header.contains("clipBadge(badge)"), "the resolved badge is never drawn")
        // ⛔ THE PLANT THIS CATCHES: the badge gated on `hasPitchEdits` again,
        // so a clip that was only cleared reads TUNING APPLIED.
        #expect(!header.contains("hasPitchEdits"),
                "the header reads `hasPitchEdits` — a clip that was only cleared or levelled would say TUNING APPLIED")
        #expect(!header.contains("\"TUNING APPLIED\""), "the badge's words are spelled in the view again")
        // The spy is handed the value the capsule drew, on every trigger, and
        // the second trigger is the FACE.
        #expect(header.contains("presets: presets, badge: badge)"))
        #expect(header.contains(".onChange(of: badge) { _, now in"),
                "the badge report does not re-fire when the face changes")
        #expect(header.contains("presets: presets, badge: now)"))
        guard let face = Self.body(of: "clipBadge", in: view) else {
            Issue.record("could not find `func clipBadge(` in \(Self.viewPath)")
            return
        }
        #expect(face.contains("Text(badge.title)"), "the capsule does not draw the resolver's words")
        guard let record = Self.body(of: "recordChrome", in: view) else {
            Issue.record("could not find `func recordChrome(` in \(Self.viewPath)")
            return
        }
        #expect(record.contains("badge: badge)"), "the ledger is not handed the drawn badge")
        // Green is this pane's "tuned" colour: only the tuning face earns it.
        guard let ink = Self.body(of: "clipBadgeInk", in: view) else {
            Issue.record("could not find `func clipBadgeInk(` in \(Self.viewPath)")
            return
        }
        #expect(ink.contains("case .tuningApplied: DAWTheme.signal"))
        #expect(ink.contains("case .notesEdited: DAWTheme.textSecondary"),
                "NOTES EDITED is not in the neutral ink")
    }

    /// `SelectAllMenuPolicyTests` proves the RULE (the open note editor's ⌘A is
    /// live on the openness verdict, refused by name when it draws nothing).
    /// This proves the APP feeds it the pane's drawn count and routes the item
    /// to the pane's bridge — a keystroke, never the debug staging nonce.
    @Test("I4 — ⌘A reaches the note editor through its bridge, counted from what the pane DRAWS")
    func selectAllReachesThePane() {
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("pitchEditorNoteCount: pitchEditorInteraction.drawnNoteCount"),
                "⌘A's item is not fed the pane's drawn-note count — it could never tell an empty pane from a full one")
        guard let perform = Self.body(of: "performMenuSelectAll", in: app) else {
            Issue.record("could not find `func performMenuSelectAll(` in DAWApp/DAWProApp.swift")
            return
        }
        #expect(perform.contains("case .pitchEditorNotes:"))
        #expect(perform.contains("pitchEditorInteraction.requestSelectAll()"),
                "Edit ▸ Select All resolves to the note editor and asks nothing of it")
        #expect(!perform.contains("pitchEditorInteraction.stage("),
                "a user keystroke rides the DEBUG staging seam")
    }

    // MARK: - m23-ap I1 UI hooks — hearing the note

    /// `PitchEditorModelTests` counts the audition CADENCE through the model's
    /// seam. What only the source shows is that the VIEW handed the model that
    /// seam and never called a door itself — a `.onChanged` that auditioned per
    /// pointer tick would pass every model test — and that the two stop doors
    /// that are view events are wired, each in its own right place.
    @Test("I1 UI hooks — the audition seam is installed on the MODEL and never called by the view; no pointer tick reaches an audition door; the pane going away and the switch turning off each stop it")
    func theAuditionSeamIsTheModels() {
        let view = Self.code(Self.viewPath)
        #expect(view.contains("model.onAudition = onAudition"), "the audition seam is never installed")
        #expect(!view.contains("onAudition("), "the view calls the audition seam itself")
        guard let fn = Self.body(of: "dragChanged", in: view) else {
            Issue.record("could not find `func dragChanged(` in \(Self.viewPath)")
            return
        }
        for banned in ["onAudition", "auditionClipNotes", "previewClipNotePitchDraft",
                       "routePitchEditorAudition", "stopClipNoteAudition", "stopAudition"] {
            #expect(!fn.contains(banned), "`dragChanged` reaches `\(banned)` — the cadence is the model's")
        }
        #expect(fn.contains("model.trackPress("), "POSITIVE CONTROL: `dragChanged` no longer drives the press")
        for banned in ["store.auditionClipNotes", "store.previewClipNotePitchDraft",
                       "store.stopClipNoteAudition", "store.auditionClipNotesAfterEdit"] {
            #expect(!view.contains(banned), "the pane reaches the store's audition door `\(banned)` directly")
        }
        // H5 — the pane going away and the switch turning off: their own
        // modifier, never folded into `cancelDrag` (a click's release runs
        // that, and must not silence the note its press just played).
        guard let wiring = Self.block(after: "private struct PitchEditorAuditionWiring: ViewModifier", in: view) else {
            Issue.record("could not find `PitchEditorAuditionWiring` in \(Self.viewPath)")
            return
        }
        #expect(wiring.contains(".onDisappear { model.stopAudition() }"),
                "closing the editor or switching its clip leaves a note sounding")
        #expect(wiring.contains("if !on { model.stopAudition() }"),
                "turning the switch off leaves a note sounding")
        #expect(view.contains(".modifier(PitchEditorAuditionWiring(model: model, auditionEnabled: layout.auditionEnabled))"),
                "the audition wiring is never applied to the pane")
        #expect(view.contains(".onDisappear { model.cancelDrag() }"),
                "the teardown's draft cancel went missing")
        guard let cancel = Self.body(of: "cancelDrag", in: Self.code("DAWAppKit/PitchEditorModel.swift")) else {
            Issue.record("could not find `func cancelDrag(` in PitchEditorModel.swift")
            return
        }
        #expect(!cancel.contains("stop"), "`cancelDrag` stops the audition — every click's release would silence its note")
    }

    @Test("I1 UI hooks — ContentView binds the seam to the app's router and draws its line; the release is heard only AFTER the funnel's read-back; every door is handed the switch")
    func theAuditionIsRoutedThroughTheApp() {
        let content = Self.code(Self.contentPath)
        #expect(content.contains("model.routePitchEditorAudition(request, clipID: clip.id)"),
                "the pane's audition requests go nowhere — the default closure does nothing")
        #expect(content.contains("auditionLine: model.pitchEditorAudition.line"),
                "the router's waiting words are never handed to the pane")
        let staging = Self.code(Self.stagingPath)
        guard let route = Self.body(of: "routePitchEditorAudition", in: staging) else {
            Issue.record("could not find `func routePitchEditorAudition(` in \(Self.stagingPath)")
            return
        }
        #expect(route.contains("enabled: panelLayout.auditionEnabled"), "a press or a drag step ignores the switch")
        guard let funnel = Self.body(of: "commitPitchNoteEdit", in: staging) else {
            Issue.record("could not find `func commitPitchNoteEdit(` in \(Self.stagingPath)")
            return
        }
        let landed = "pitchEditorAudition.commitLanded(commit, clipID: clipID,"
        #expect(funnel.contains(landed), "a landed commit is never heard")
        #expect(funnel.contains("enabled: panelLayout.auditionEnabled)"), "the release ignores the switch")
        // AFTER every read-back: the last refusal of a write that did not take
        // comes before it, and the `catch` after it.
        if let heard = funnel.range(of: landed),
           let lastRefusal = funnel.range(of: "presentArrangeSplitRefusal(PitchNoteEditDidNotTake()",
                                          options: .backwards),
           let caught = funnel.range(of: "} catch {") {
            #expect(lastRefusal.upperBound < heard.lowerBound,
                    "the release is heard before a read-back — a write that did not take would still play")
            #expect(heard.upperBound < caught.lowerBound, "the release is heard on the refusal path")
        } else {
            Issue.record("the funnel's shape moved — re-find the read-backs and the catch")
        }
    }

    @Test("I1 UI hooks — the HEAR switch writes the ONE switch, carries its one-switch help, and reports the face it drew; the audition line is drawn on the state row and reported")
    func theHearSwitchAndTheLine() {
        let view = Self.code(Self.viewPath)
        guard let toggle = Self.block(after: "private var auditionToggle: some View", in: view) else {
            Issue.record("could not find `private var auditionToggle: some View` in \(Self.viewPath)")
            return
        }
        #expect(toggle.contains("layout.setAuditionEnabled(!on)"), "the switch writes something other than the ONE switch")
        #expect(toggle.contains(".help(PitchEditorAuditionToggle.help(on: on))"), "the switch carries no help")
        #expect(toggle.contains("PitchEditorAuditionToggle.symbol(on: on)"))
        #expect(toggle.contains("recordAuditionToggle"), "the spy never hears the face the switch drew")
        #expect(!toggle.contains("\"HEAR\""), "the switch's words are spelled in the view")
        guard let header = Self.block(after: "private var header: some View", in: view) else {
            Issue.record("could not find `private var header: some View` in \(Self.viewPath)")
            return
        }
        #expect(header.contains("auditionToggle"), "the switch is never drawn")
        #expect(header.contains("if let auditionLine {"), "the waiting words are never drawn")
        #expect(header.contains("auditionLineView(auditionLine)"))
        #expect(header.contains("chrome?.recordAuditionLine(now)"), "the spy never hears the line that was drawn")
        guard let line = Self.body(of: "auditionLineView", in: view) else {
            Issue.record("could not find `func auditionLineView(` in \(Self.viewPath)")
            return
        }
        // Progress is a spinner WITH words; a shortfall is the refusal line.
        #expect(line.contains("case .shortfall:") && line.contains("PanelRefusalLine(message: line.text)"))
        #expect(line.contains("ProgressView()") && line.contains("Text(line.text)"))
    }

    /// Item 7 — `PitchEditorModelTests.tunedColourFollowsThePitchHalf` owns the
    /// PREDICATE; this owns that the surface's two colour decisions ask it.
    @Test("I1 UI hooks item 7 — the tuned green asks `isPitchEdited` at both of its sites; no colour decision reads `isEdited`")
    func theTunedGreenAsksThePitchHalf() {
        let view = Self.code(Self.viewPath)
        #expect(view.contains("let ink = blob.isPitchEdited ? DAWTheme.signal : DAWTheme.textDim"),
                "the note's body does not ask the pitch half")
        #expect(view.contains(".foregroundColor(blob.isPitchEdited ? DAWTheme.signal : DAWTheme.textSecondary)"),
                "the note's name does not ask the pitch half")
        #expect(!view.contains("blob.isEdited ?"),
                "a colour decision reads `isEdited` — a note that was only turned down would draw tuned")
        // POSITIVE CONTROL: the stripped file still holds the cleared note's
        // own look, so the absence above is the file talking.
        #expect(view.contains("if blob.isCleared"))
    }
}
