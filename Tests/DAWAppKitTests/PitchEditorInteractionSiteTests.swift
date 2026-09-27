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
        // C5b-4b — and the brush's release and its store door: a stroke tick
        // that committed would re-render the clip at pointer rate.
        for banned in ["onCommitNoteEdit", "endPitchDrag", "splitNote", "commitPitchNoteEdit",
                       "setClipNotePitchOffset", "splitClipNoteSegment", "endBrush", "setClipNoteShapes"] {
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
                       "store.autoCorrectClipPitch", "store.setClipNotesCleared",
                       "store.setClipNoteShapes"] {
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
        // C5b-4b — the brush's one write is the release's too.
        #expect(fn.contains("_ = model.endBrush()"))
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
                      "model.zoomPitchEditorReset()", "model.pitchEditorRowZoomReset()",
                      // m23-ap I2 — the pinch's scale, through the same door.
                      "model.setPitchEditorTimeScale("] {
            #expect(content.contains(entry), "ContentView does not bind `\(entry)`")
        }
        // m23-ap I5 — the playhead: the seek (whose default `{ _ in }` would place
        // nothing, silently) and the snap IN FORCE, the roll's own input.
        #expect(content.contains("appSnap: model.effectiveClipSnap"),
                "the pitch editor does not get the app's snap in force — its placement would ignore SNAP: Off")
        #expect(content.contains("onSeek: { beats in _ = try? store.seek(toBeats: beats) }"),
                "the pitch editor's seek is not bound — the ruler would place nothing")
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

    // MARK: - m23-ap I2 — the pinch: one path, the one re-pin, drawn help

    /// `PitchEditorViewportTests` proves the pinch's RULES headless (captured
    /// once, cumulative, the pointer's beat holds). What only the source shows
    /// is the VIEW's half: that the trackpad and the staged step reach the SAME
    /// two functions, that those ask the app rather than the slot (the ban
    /// above stays the proof of that), that the anchor reaches the ONE re-pin,
    /// and that the help is drawn. ⚠️ Weak source-shape pins, said out loud:
    /// the staged-pinch spy gate (I2-5) is the real proof of the wiring.
    @Test("I2 — the trackpad and the staged step reach the same two pinch functions, which ask the APP; the anchor reaches the one re-pin; the hint is drawn")
    func thePinchIsOnePathThroughTheApp() {
        let view = Self.code(Self.viewPath)
        // 1. THE GESTURE: one `MagnifyGesture`, whose callbacks only forward.
        #expect(view.components(separatedBy: "MagnifyGesture()").count - 1 == 1,
                "the pane must attach exactly one MagnifyGesture")
        guard let gestureStart = view.range(of: "MagnifyGesture()"),
              let gestureEnd = view.range(of: ".onEnded { _ in pinchEnded() })",
                                          range: gestureStart.upperBound..<view.endIndex) else {
            Issue.record("could not find the MagnifyGesture and its `.onEnded { _ in pinchEnded() })` in \(Self.viewPath)")
            return
        }
        let gesture = String(view[gestureStart.lowerBound..<gestureEnd.upperBound])
        #expect(gesture.contains("pinchChanged(startLocation: value.startLocation,"))
        #expect(gesture.contains("magnification: value.magnification)"))
        #expect(!gesture.contains("onZoom(") && !gesture.contains("layout."),
                "the gesture's closures act themselves — the staged step would drive a different path")
        let beforeGesture = String(view[..<gestureStart.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(beforeGesture.hasSuffix(".simultaneousGesture("),
                "the pinch is not attached as a SIMULTANEOUS gesture — it would steal the drag's routing")
        // 2. THE STAGED STEP runs the same two functions.
        guard let staged = Self.body(of: "applyStagedStep", in: view) else {
            Issue.record("could not find `func applyStagedStep(` in \(Self.viewPath)")
            return
        }
        #expect(staged.contains("case .pinch(let startLocation, let magnification):"))
        #expect(staged.contains("pinchChanged(startLocation: startLocation, magnification: magnification)"))
        #expect(staged.contains("case .pinchEnd:"))
        #expect(staged.contains("pinchEnded()"))
        // 3. THE TICK: the reducer, then the APP — never the slot, never the
        // scroll (the re-pin is the one writer).
        guard let changed = Self.body(of: "pinchChanged", in: view) else {
            Issue.record("could not find `func pinchChanged(` in \(Self.viewPath)")
            return
        }
        #expect(changed.contains("PitchEditorPinch.tick(anchor: pinchAnchor,"),
                "the tick does not hand the reducer the live anchor — it would recapture every tick")
        #expect(changed.contains("pinchAnchor = tick.anchor"))
        #expect(changed.contains("onZoom(.timeScale(tick.ppb))"))
        #expect(changed.contains("onEngage()"), "a pinch would not make ⌘± follow it to this pane")
        #expect(changed.contains("guard model.press.current == nil"),
                "a pinch mid-press would move what is under the press")
        for banned in ["scrollTarget", "horizontalScrollNonce", "scroll(toX:"] {
            #expect(!changed.contains(banned), "`pinchChanged` writes the scroll via `\(banned)` — a second writer")
        }
        guard let ended = Self.body(of: "pinchEnded", in: view) else {
            Issue.record("could not find `func pinchEnded(` in \(Self.viewPath)")
            return
        }
        #expect(ended.contains("pinchAnchor = nil"))
        #expect(view.contains(".onDisappear { pinchEnded() }"), "a dropped onEnded would leave a stale anchor behind")
        // 4. THE ONE RE-PIN is handed the anchor.
        guard let repin = Self.body(of: "repinTimeZoom", in: view) else {
            Issue.record("could not find `func repinTimeZoom(` in \(Self.viewPath)")
            return
        }
        #expect(repin.contains("pointerAnchor: pinchAnchor"), "the pinch's anchor never reaches the re-pin")
        #expect(!repin.contains("pointerAnchor: nil"))
        // 5. THE ECHO reads the same anchor, and re-reports when it changes.
        // (I5 grew the report past this field, so the pin reads the report's own
        // block rather than the call's closing paren.)
        #expect(Self.block(after: "private var surfaceReport: PitchEditorSurfaceReport", in: view)?
            .contains("pinchAnchor: pinchAnchor") == true)
        #expect(view.contains(".onChange(of: pinchAnchor) { _, _ in reportSurface() }"))
        // 6. THE HELP IS DRAWN, from the one constant, and reported as drawn.
        guard let cluster = Self.block(after: "private var zoomCluster: some View", in: view) else {
            Issue.record("could not find `private var zoomCluster: some View` in \(Self.viewPath)")
            return
        }
        #expect(cluster.contains("let pinchHint = PitchEditorZoomHint.pinchTime"))
        #expect(cluster.contains("Text(pinchHint)"), "the pinch help is not drawn")
        #expect(cluster.contains("chrome?.recordZoomHint(pinchHint)"), "the spy never hears the help that was drawn")
        #expect(!cluster.contains(".help(pinchHint"), "the pinch help is hung on a tooltip")
        // 7. THE APP ROUTE: a scale, through the entry point, and the entry
        // point writes the slot (the pane cannot — the ban above).
        let app = Self.code("DAWApp/DAWProApp.swift")
        guard let entry = Self.body(of: "setPitchEditorTimeScale", in: app) else {
            Issue.record("could not find `func setPitchEditorTimeScale(` in DAWApp/DAWProApp.swift")
            return
        }
        #expect(entry.contains("panelLayout.setPitchEditorPPB(ppb)"))
        #expect(Self.code(Self.contentPath).contains("case .timeScale(let ppb): model.setPitchEditorTimeScale(ppb)"))
    }

    // MARK: - I5 — the playhead (interaction batch §8)

    /// The house shape for a seam (the commit and audition pins above): the SEEK
    /// is installed on the MODEL and the view never calls it; the ruler is a
    /// SIBLING ROW above the scrollers; and the scroll offset meets a placement
    /// in exactly one function. ⚠️ Source-shape pins, said out loud — the
    /// staging gate `m23ap-i5-playhead.mjs` reads the transport back over the
    /// wire, which is the real proof.
    @Test("I5 — the seek is installed on the MODEL and the view never calls it; the ruler is a sibling row whose ticks add the scroll offset in ONE place")
    func thePlayheadIsPlacedThroughTheModel() {
        let view = Self.code(Self.viewPath)
        // 1. THE SEAM: installed once, never called by the view.
        #expect(view.contains("model.onSeek = onSeek"))
        #expect(view.contains("model.appSnap = appSnap"))
        #expect(!view.contains("onSeek("), """
            PitchEditorView calls `onSeek(` directly. The model is the only caller (the ruler \
            calls `model.placePlayhead`, the ⌘-click reaches it through `model.releasePress`), \
            which is what makes PitchEditorModelTests' seek spy count the real cadence.
            """)
        #expect(!view.contains("store.seek"), "the pane reaches the store's seek itself")
        // 2. THE ONE PLACE THE OFFSET IS ADDED.
        guard let tick = Self.body(of: "rulerTick", in: view) else {
            Issue.record("could not find `func rulerTick(` in \(Self.viewPath)")
            return
        }
        // The SHOWN offset (`PitchEditorViewport.shownOffsetX`), never the raw
        // reading, which can hold a position the scroller is not at.
        #expect(tick.contains("model.placePlayhead(atContentX: x + viewport.shownOffsetX, snapBypassed: option)"))
        #expect(tick.contains("onEngage()"), "placing the playhead would not engage this pane")
        #expect(view.components(separatedBy: "+ viewport.shownOffsetX").count - 1 == 1,
                "the scroll offset is added to a placement somewhere other than `rulerTick`")
        #expect(!view.contains("+ viewport.offset.x"),
                "a placement adds the RAW measured offset — a stale one lands the playhead late")
        for gesture in ["dragChanged", "dragEnded"] {
            guard let fn = Self.body(of: gesture, in: view) else {
                Issue.record("could not find `func \(gesture)(` in \(Self.viewPath)")
                continue
            }
            #expect(!fn.contains("viewport.offset") && !fn.contains("shownOffsetX"),
                    "`\(gesture)` adds the scroll offset — the surface is already content space")
        }
        guard let ended = Self.body(of: "dragEnded", in: view) else { return }
        #expect(ended.contains("snapBypassed: chord.option"), "the ⌘-click ignores ⌥")
        // 3. THE ROW: the band as the hit area's background, the transport cursor,
        // and every tick through `rulerTick` — never the model or the store directly.
        guard let row = Self.block(after: "private var rulerRow: some View", in: view) else {
            Issue.record("could not find `private var rulerRow: some View` in \(Self.viewPath)")
            return
        }
        #expect(row.contains("PianoRollScrubRulerBand("))
        #expect(row.contains("scrollX: viewport.shownOffsetX"),
                "the ruler draws with an offset other than the one its ticks add")
        #expect(row.contains(".hoverCursor(.verticalBar)"))
        #expect(row.contains("rulerTick(x: value.location.x"))
        #expect(!row.contains("placePlayhead") && !row.contains("+ viewport.shownOffsetX"),
                "the row places the playhead itself instead of through `rulerTick`")
        #expect(row.contains(".onChange(of: appSnap) { _, now in model.appSnap = now }"),
                "the model would place with the snap the pane opened with, forever")
        // 4. A SIBLING ROW, ABOVE the scrollers — never inside them.
        guard let bodyBlock = Self.block(after: "private var editorBody: some View", in: view),
              let scrollers = Self.block(after: "private var editorScrollers: some View", in: view),
              let rowAt = bodyBlock.range(of: "rulerRow"),
              let scrollersAt = bodyBlock.range(of: "editorScrollers") else {
            Issue.record("could not find the editor body stacking `rulerRow` over `editorScrollers`")
            return
        }
        #expect(bodyBlock.contains("VStack(spacing: 0)"))
        #expect(rowAt.lowerBound < scrollersAt.lowerBound, "the ruler is not ABOVE the scrollers")
        #expect(!scrollers.contains("rulerRow"), "the ruler is mounted inside a scroller")
        // 5. THE STAGED STEP runs the same tick.
        guard let staged = Self.body(of: "applyStagedStep", in: view) else {
            Issue.record("could not find `func applyStagedStep(` in \(Self.viewPath)")
            return
        }
        #expect(staged.contains("case .ruler(let x, let chord):"))
        #expect(staged.contains("rulerTick(x: x, option: chord.option)"))
        // 6. THE DEBUG TIER: the act, and the echo placing the TRANSPORT through
        // the pane's geometry.
        let staging = Self.code("DAWApp/PitchEditorDebugStaging.swift")
        #expect(staging.contains("case \"ruler\":"))
        #expect(staging.contains("step = .ruler(x: CGFloat(x), chord)"))
        #expect(staging.contains("\"playhead\": pitchEditorPlayheadJSON()"))
        #expect(staging.contains("geometry.x(forProjectBeat: position)"))
    }

    @Test("I5 — follow: driven from the transport, stands down while a pinch owns the scroll, and the detector reads the SAME predicate; the app runtime is in all three places")
    func thePitchEditorFollowsThePlayhead() {
        let view = Self.code(Self.viewPath)
        guard let drives = Self.block(after: "private var followDrives: Bool", in: view) else {
            Issue.record("could not find `private var followDrives: Bool` in \(Self.viewPath)")
            return
        }
        #expect(drives.contains("layout.followPlayhead"), "follow ignores the ONE persisted flag")
        #expect(drives.contains("followLineX != nil"), "follow would page toward a line that is not drawn")
        #expect(drives.contains("pinchAnchor == nil"), "follow would fight a live pinch for the scroll (design risk 9)")
        guard let tick = Self.body(of: "followTick", in: view) else {
            Issue.record("could not find `func followTick(` in \(Self.viewPath)")
            return
        }
        #expect(tick.contains("isEnabled: followDrives, isPlaying: isPlaying"))
        #expect(tick.contains("scrollTarget.x = target") && tick.contains("horizontalScrollNonce &+= 1"),
                "follow does not write through the pane's one horizontal writer")
        #expect(view.contains(".onChange(of: positionBeats) { _, _ in followTick() }"),
                "follow is not driven from the transport observation path")
        guard let reader = Self.block(after: "private var horizontalScrollReader: some View", in: view) else {
            Issue.record("could not find `private var horizontalScrollReader: some View` in \(Self.viewPath)")
            return
        }
        #expect(reader.contains("follow?.reportOffset(-newValue, isEnabled: followDrives,"),
                "the manual-scroll detector reads a different predicate from the one that drives follow")
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("let pitchEditorFollow = FollowPlayheadModel()"))
        #expect(app.contains("pitchEditorFollow.rearm()"), "pressing play would not re-arm the note editor's follow")
        #expect(app.contains("(panelLayout.followPlayhead && pitchEditorFollow.isSuspended)"),
                "the FOLLOW chip would not show the note editor's paused face")
        #expect(app.contains("case \"pitchEditor\": pitchEditorFollow.scrollExternally(to: CGFloat(raw))"))
        #expect(Self.code(Self.contentPath).contains("follow: model.pitchEditorFollow,"))
    }

    @Test("I2 — debug.pitchEditor stages the pinch, refuses the three unbalanced shapes, and waits for the scroll to land")
    func theDebugTierStagesThePinch() {
        let staging = Self.code("DAWApp/PitchEditorDebugStaging.swift")
        guard let fn = Self.body(of: "stagePitchEditorStep", in: staging) else {
            Issue.record("could not find `func stagePitchEditorStep(` in DAWApp/PitchEditorDebugStaging.swift")
            return
        }
        #expect(fn.contains("\"magnification\""), "the pinch's ratio is not an allowed key")
        #expect(fn.contains("case \"pinch\":") && fn.contains("case \"pinchEnd\":"))
        #expect(fn.contains("step = .pinch(start, CGFloat(ratio))"))
        #expect(fn.contains("ratio.isFinite, ratio > 0"), "a zero, negative or NaN ratio is not refused")
        #expect(fn.contains("guard bridge.surface.pinchAnchor != nil"), "a pinchEnd with no pinch is not refused")
        // The landing wait: stands on the MEASURED offset, only after a scale change.
        #expect(fn.contains("if case .pinch = step {"))
        #expect(fn.contains("while bridge.surface.viewport.offset.x == offsetXBefore"))
        // The echo: the pane's anchor and the drawn help.
        #expect(staging.contains("\"pinch\": Self.pitchEditorPinchJSON(pitchEditorInteraction.surface.pinchAnchor)"))
        #expect(staging.contains("\"hintText\": .string(model.pitchEditorChrome.zoomHintText)"))
    }

    // MARK: - The palette draws its prose, because a tooltip is invisible to a capture

    /// m23-ap C5b-4b — the help is HANDED to the palette now (`help`), because
    /// while ⌘ is held it is the brush's and not the tool's (design §5.6).
    /// Both halves come from ONE model call, `paletteHelp(commandHeld:band:)`:
    /// the palette draws its answer and the ledger reports the same answer.
    @Test("the palette DRAWS the help (the tool's, or the brush's while ⌘ is held) and reports what it drew")
    func thePaletteDrawsItsProse() {
        let view = Self.code(Self.viewPath)
        #expect(view.contains("Text(help)"), """
            The palette does not DRAW the help it is handed. A `.help()` tooltip is invisible to \
            `view.capture`, so a captured gate cannot tell a correct caption from a missing one — \
            the EQCurveEditor.help lesson, verbatim.
            """)
        #expect(!view.contains("Text(tool.help)"), "the palette draws the TOOL's help, never the brush's")
        // The palette and the ledger ask the SAME function.
        #expect(view.contains("let help = model.paletteHelp(commandHeld: commandHeld, band: band)"))
        #expect(view.contains("help: help,"))
        #expect(view.contains("let paletteHelp = model.paletteHelp(commandHeld: commandHeld, band: band)"))
        // And it reports the strings it drew to the ledger, from the same values.
        #expect(view.contains("chrome?.recordInteraction("))
        #expect(view.contains("toolHelp: paletteHelp"))
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
        // UE-2: the cleared branch is `NoteBlob.look`'s `.cleared` case now (one
        // predicate home, cleared › sound › note — `ue2TheLookPrecedence` pins
        // the order headless).
        #expect(blobs.contains("switch blob.look {") && blobs.contains("case .cleared:"),
                "a cleared note is drawn like any other")
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

    /// p2-ren B″ (erratum E9) — the WIRING half of the launch sweep; the
    /// behaviour half (a dead session goes, a live one stays, temp roots only)
    /// is `ProvisionalLaunchSweepTests`. A call in a view would run per mount,
    /// and a call nobody makes is a sweep that silently never happens.
    @Test("B″ — the app sweeps dead provisional sessions ONCE, in AppModel.init where it builds the engine, and no view calls it")
    func theLaunchSweepIsWiredAtEngineConstruction() {
        let app = Self.code("DAWApp/DAWProApp.swift")
        let call = "engine.wipeDeadProvisionalSessions()"
        // The init's span: from the engine's construction to the first
        // assignment of the stored engine, inside `AppModel.init`.
        guard let built = app.range(of: "let engine = AudioEngine()"),
              let stored = app.range(of: "self.engine = engine", range: built.upperBound..<app.endIndex)
        else {
            Issue.record("could not find the engine's construction in DAWApp/DAWProApp.swift")
            return
        }
        let initSpan = String(app[built.upperBound..<stored.lowerBound])
        #expect(initSpan.contains(call), "the launch sweep is not called where the engine is built")
        // POSITIVE CONTROL: the span is the launch block, not an empty slice.
        #expect(initSpan.contains("store.pruneUntitledRecoveryBundles()"))
        #expect(app.components(separatedBy: call).count - 1 == 1, "called more than once in the app")
        // Never from a view: the pane and the content view are rebuilt per mount.
        for path in [Self.viewPath, Self.contentPath] {
            #expect(!Self.code(path).contains("wipeDeadProvisionalSessions"), "\(path) sweeps")
        }
    }

    /// m23-ap I6b S3 — the view's half of autoscroll. The DECISION is the
    /// model's (`PitchEditorModelTests.i6bTheEdgeDecision`, headless); these pin
    /// only where the view calls it, arms the clock, and tears it down — the
    /// roll's `PianoRollEdgeDragSiteTests` shape.
    @Test("I6b S3 — ONLY the live pointer arms the clock, after travel; the edge step runs in the drag funnel before the pitch update; the clock is torn down in dragEnded (first) and on disappear; the tick and the held pointer read the SHOWN offset")
    func autoscrollIsWiredOnTheLivePointerOnly() {
        let view = Self.code(Self.viewPath)
        guard let live = Self.body(of: "liveDragChanged", in: view),
              let changed = Self.body(of: "dragChanged", in: view),
              let ended = Self.body(of: "dragEnded", in: view),
              let staged = Self.body(of: "applyStagedStep", in: view),
              let tick = Self.body(of: "repeatHeldEdge", in: view),
              let step = Self.body(of: "applyEdgeStep", in: view),
              let stop = Self.body(of: "stopEdgeRepeat", in: view) else {
            Issue.record("an I6b function is missing from \(Self.viewPath)")
            return
        }
        // The gesture's onChanged goes through the wrapper; the staged seam never does.
        #expect(view.contains("liveDragChanged(value)"))
        #expect(!staged.contains("liveDragChanged") && !staged.contains("setEdgeRepeat"),
                "a staged step could arm the clock")
        // Armed on the model's axes (empty until the press has travelled with a
        // draft or a band live), and nowhere else with `true`.
        #expect(live.contains("setEdgeRepeat(running: !model.edgePushAxes.isEmpty)"))
        #expect(view.components(separatedBy: "setEdgeRepeat(running:").count - 1 == 3,
                "setEdgeRepeat is called somewhere new (expected: the wrapper, stopEdgeRepeat, the declaration)")
        // The held pointer and every tick read the SHOWN offset, never the raw one.
        #expect(live.contains("currentOffset: viewport.clamped(viewport.offset)"))
        #expect(tick.contains("observedOffset: viewport.clamped(viewport.offset)"))
        #expect(tick.contains("dragChanged(start: held.origin, location: tick.location"))
        #expect(tick.contains("model.edgePushAxes"), "the tick does not gate on the model (Escape)")
        // The edge step runs in the funnel, before the pitch update reads the window.
        guard let edge = changed.range(of: "applyEdgeStep(at: location)"),
              let update = changed.range(of: "model.updatePitchDrag(") else {
            Issue.record("dragChanged lost its edge step or its pitch update")
            return
        }
        #expect(edge.lowerBound < update.lowerBound, "the pitch update reads the window before it grows")
        // A grown BOTTOM is revealed against the NEW content (its own write),
        // a band's x goes through follow.
        #expect(step.contains("scrollTarget.y = y") && step.contains("verticalScrollNonce &+= 1"))
        #expect(step.contains("follow.scrollExternally(to: x)"))
        // Teardowns: dragEnded FIRST, the pane disappearing, and the stop itself.
        // (`body(of:)` keeps the opening brace.)
        #expect(ended.drop { $0 == "{" || $0.isWhitespace }.hasPrefix("stopEdgeRepeat()"),
                "dragEnded does not stop the clock before it acts")
        #expect(view.contains(".onDisappear { stopEdgeRepeat() }"))
        #expect(stop.contains("setEdgeRepeat(running: false)") && stop.contains("heldEdgePoint = nil"))
    }

    // MARK: - UE-1 — sounds with no pitch

    @Test("UE-1 — Find sounds: the header button and the staged step reach ONE function, which asks the MODEL before the app runs the verb and hands the answer back to it; ContentView binds the app funnel; the funnel calls the store's merge verb and shows a refusal verbatim")
    func ue1FindSoundsIsWiredThroughTheModel() {
        let view = Self.code(Self.viewPath)
        let staging = Self.code(Self.stagingPath)
        let content = Self.code(Self.contentPath)
        guard let run = Self.body(of: "runFindSounds", in: view),
              let funnel = Self.body(of: "findUnpitchedSoundsFromEditor", in: staging),
              let staged = Self.body(of: "applyStagedStep", in: view) else {
            Issue.record("runFindSounds / findUnpitchedSoundsFromEditor / applyStagedStep not found")
            return
        }
        // The model decides first; the app runs the verb; the model says the answer.
        guard let begin = run.range(of: "guard model.beginFindSounds() else { return }"),
              let call = run.range(of: "model.finishFindSounds(await find())") else {
            Issue.record("runFindSounds no longer asks the model first, or no longer hands it the answer")
            return
        }
        #expect(begin.lowerBound < call.lowerBound, "the verb runs before the model agreed")
        #expect(run.contains("let find = onFindSounds"))
        // Two doors, one function, and no third caller: the declaration, the
        // button, the staged step.
        // UE-2: the button became a chip (`label:` builds its face), still ONE
        // call of the one function.
        #expect(view.contains("Button { runFindSounds() } label: {"))
        #expect(staged.contains("case .findSounds:") && staged.contains("runFindSounds()"))
        #expect(view.components(separatedBy: "runFindSounds()").count - 1 == 3,
                "runFindSounds is called somewhere new")
        #expect(!view.contains("store.findUnpitchedSounds"), "the view reached the store itself")
        // ContentView binds the funnel (the pane's default closure only refuses).
        #expect(content.contains(
            "onFindSounds: { await model.findUnpitchedSoundsFromEditor(clipID: clip.id) }"))
        // The funnel: the store's ONE merge verb, and a refusal shown verbatim.
        #expect(funnel.contains("try await store.findUnpitchedSounds(clipId: clipID)"))
        #expect(funnel.contains("return .refused(error.localizedDescription)"))
        #expect(!funnel.contains("try?"), "a refusal would be swallowed")
    }

    @Test("UE-1 — the drag overlay draws the DRAFT's label (a sound's sentence, a note's name and cents) and composes none of its own; the debug echo reports each blob's ORIGIN from the model beside the store's, and Find sounds in both echo shapes")
    func ue1OverlayLabelAndOriginEcho() {
        let view = Self.code(Self.viewPath)
        let debug = Self.code("DAWApp/PitchEditorDebugStaging.swift")
        guard let overlay = Self.block(after: "struct PitchEditorDragOverlay", in: view) else {
            Issue.record("PitchEditorDragOverlay not found")
            return
        }
        #expect(overlay.contains("if let text = draft.overlayLabel {"))
        #expect(!overlay.contains("targetNoteName"), "the overlay composes a note name again (a pitch claim over a sound)")
        #expect(view.contains("origin: $0.origin.rawValue"))
        #expect(view.contains("soundReadout: $0.soundReadout"))
        #expect(debug.contains("\"origin\": .string(note.origin)"))
        #expect(debug.contains("\"origin\": .string(segment.origin.rawValue)"))
        #expect(debug.components(separatedBy: "\"findSounds\": Self.pitchEditorFindSoundsJSON(").count - 1 == 2,
                "Find sounds is missing from one of the two echo shapes")
        #expect(debug.contains("step = .findSounds"))
    }

    // MARK: - UE-2 — how a sound looks

    @Test("UE-2 — the surface draws the look it is HANDED: `drawBlobs` switches on `blob.look`; the sound branch never reads confidence, never dashes, wears no warning or AI ink, stripes through ONE clipped layer and keeps the selection ring; the labels name only a note; a moving sound is striped; the palette readout never wraps")
    func ue2SurfaceDrawsTheSoundLook() {
        let view = Self.code(Self.viewPath)
        guard let blobs = Self.body(of: "drawBlobs", in: view),
              let labels = Self.body(of: "drawBlobLabels", in: view),
              let hatch = Self.body(of: "drawHatch", in: view),
              let moving = Self.body(of: "drawMoving", in: view),
              let palette = Self.block(after: "struct PitchEditorToolPalette", in: view),
              let readout = Self.block(after: "if let dragReadout", in: palette) else {
            Issue.record("drawBlobs / drawBlobLabels / drawHatch / drawMoving / the palette readout not found")
            return
        }
        #expect(blobs.contains("switch blob.look {"), "the Canvas re-decides the look instead of reading it")
        guard let soundCase = blobs.range(of: "case .sound:"),
              let noteCase = blobs.range(of: "case .note:"),
              soundCase.upperBound < noteCase.lowerBound else {
            Issue.record("the sound branch is missing, or no longer sits before the note's")
            return
        }
        let sound = String(blobs[soundCase.upperBound..<noteCase.lowerBound])
        #expect(!sound.contains("confidence"),
                "a sound's strength follows its confidence — at ~0.59 it draws as a middling NOTE")
        #expect(!sound.contains("dash"), "a dashed sound reads as a cleared note or a ghost")
        #expect(!sound.contains("DAWTheme.record") && !sound.contains("aiAccent")
                    && !sound.contains("DAWTheme.playback"), "amber, violet or cyan on a sound")
        #expect(sound.contains("Self.addHatch(&soundHatch, in: rect)")
                    && sound.contains("Self.addHatch(&tunedSoundHatch, in: rect)"))
        #expect(sound.contains("selectedRings.addPath(shape)") && !sound.contains("selectedClearedRings"),
                "a selected sound must take the SOLID ring, never the cleared one")
        #expect(blobs.contains("Self.drawHatch(&context, clip: soundShapes, hatch: soundHatch,"))
        #expect(blobs.contains("Self.drawHatch(&context, clip: tunedSoundShapes, hatch: tunedSoundHatch,"))
        #expect(hatch.contains("layer.clip(to: clip)"), "the stripes run past the rounded corners")
        // The labels: a note's name, and only a note's.
        #expect(labels.contains("if rect.width >= 20, blob.look == .note {"))
        #expect(labels.components(separatedBy: "drawnNoteName(for: blob)").count - 1 == 1)
        // The drag: a moving sound and a moving sound MEMBER stay striped.
        #expect(view.contains("Self.drawMoving(&context, rect: live, isSound: draft.isUnpitched)"))
        #expect(view.contains("Self.drawMoving(&context, rect: memberLive, isSound: member.isUnpitched)"))
        #expect(moving.contains("PitchEditorSurface.drawHatch("))
        // The palette's readout slot: one line, first claim on the width.
        #expect(readout.contains(".lineLimit(1)"), "the sentence wraps and the palette grows mid-drag")
        #expect(readout.contains(".layoutPriority(1)") && readout.contains(".truncationMode(.tail)"))
    }

    @Test("UE-2 — the nouns, the legend and the memory reach their doors: both AppModel Delete doors pass the selection's kinds from ONE home, the pane reports them on its selection token (initial), installs the Find-sounds memory, draws the legend from `PitchEditorSoundLook` and records it when it changes, and echoes each note's look")
    func ue2NounsLegendAndMemoryAreWired() {
        let view = Self.code(Self.viewPath)
        let app = Self.code("DAWApp/DAWProApp.swift")
        let debug = Self.code("DAWApp/PitchEditorDebugStaging.swift")
        #expect(app.components(separatedBy: "pitchEditorSelectionKinds: pitchEditorSelectionKinds,").count - 1 == 2,
                "a Delete door prints \"Notes\" over sounds (the parameter is defaulted, so the compiler is silent)")
        guard let home = Self.block(after: "var pitchEditorSelectionKinds: Set<PitchEditorNoteMenu.Kind>", in: app),
              let legend = Self.block(after: "private var confidenceLegend: String", in: view) else {
            Issue.record("AppModel.pitchEditorSelectionKinds or the pane's confidenceLegend not found")
            return
        }
        #expect(home.contains("pitchEditorInteraction.selectionKinds"))
        #expect(view.contains(".onChange(of: model.selectionToken, initial: true) { _, _ in"))
        #expect(view.contains("interaction?.report(selectionKinds: model.selectionKinds)"))
        #expect(view.contains("model.findSoundsMemory = interaction?.findSoundsMemory"))
        #expect(legend.contains("PitchEditorSoundLook.legend("))
        #expect(!view.contains("\"Fainter notes mean"), "a second spelling of the legend")
        #expect(view.contains(".onChange(of: caption) { _, now in"),
                "the ledger reports a legend the Find-sounds merge replaced")
        #expect(view.contains("look: $0.look.rawValue"))
        #expect(debug.contains("\"look\": .string(note.look)"))
        // The chip's row keeps ONE height (seen by looking: it jumped ~6 pt).
        guard let presetRow = Self.body(of: "presetRow", in: view) else {
            Issue.record("presetRow not found")
            return
        }
        #expect(presetRow.contains(".frame(height: Self.tuneRowHeight)"),
                "the Find-sounds chip re-lays the pane when it comes and goes")
    }

    @Test("I5-F1 — the time ruler numbers the SONG's bars: ContentView hands the pane the project's ONE meter map, the ruler row hands it to the band, the band draws the song canvas through the shared renderer as an EQUATABLE view (the map is rebuilt on every read), and the echo reports the band's labels through the same function")
    func theRulerNumbersTheSongsBars() {
        let view = Self.code(Self.viewPath)
        let content = Self.code(Self.contentPath)
        let band = Self.code("DAWApp/Components/PianoRollScrubRulerBand.swift")
        let debug = Self.code("DAWApp/PitchEditorDebugStaging.swift")
        let roll = Self.code("DAWApp/PianoRoll/PianoRollView.swift")
        // The source of truth: the store's map, never one rebuilt at the call site.
        #expect(content.contains("meterMap: store.transport.meterMap,"))
        #expect(!content.contains("meterMap: MeterMap(constant"), "the pane got a hard-coded meter")
        #expect(view.contains("meterMap: MeterMap,") && !view.contains("meterMap: MeterMap ="),
                "the pane's meter is defaulted — a new call site would get 4/4 with the compiler silent")
        guard let row = Self.block(after: "private var rulerRow: some View", in: view) else {
            Issue.record("could not find `private var rulerRow: some View` in \(Self.viewPath)")
            return
        }
        #expect(row.contains("songMeter: meterMap"), "the ruler numbers the clip's bars again")
        // The band: nil keeps the roll's clip-local canvas; set, the song's.
        guard let bandBody = Self.block(after: "var body: some View", in: band) else {
            Issue.record("the band's body not found")
            return
        }
        #expect(bandBody.contains("if let songMeter {"))
        #expect(bandBody.contains("SongRulerCanvas(") && bandBody.contains(".equatable()"),
                "the song canvas would redraw (and re-allocate its ticks) on every transport tick")
        guard let song = Self.block(after: "private struct SongRulerCanvas: View, Equatable", in: band) else {
            Issue.record("SongRulerCanvas: View, Equatable not found")
            return
        }
        #expect(song.contains("PitchEditorSongRuler.ticks("))
        #expect(song.contains("RulerCanvas.draw("), "the song ruler forked its own renderer")
        #expect(!song.contains("positionBeats"), "the song canvas sees the transport")
        // The roll: I5-F1 left it clip-local and reported it; m23-ap I5-F2 moved
        // it to the SONG's bars too (ruler, grid, "BAR n", placement snap), so it
        // now hands the band the same song meter — one song, one set of bars.
        guard let strip = Self.block(after: "private var scrubStrip: some View", in: roll) else {
            Issue.record("the roll's scrubStrip not found")
            return
        }
        #expect(strip.contains("PianoRollScrubRulerBand(") && strip.contains("songMeter: meterMap"),
                "I5-F2: the roll's ruler went back to clip-local numbering")
        // The echo: the same function, the pane's geometry, the store's map.
        #expect(debug.contains("PitchEditorSongRuler.ticks("))
        #expect(debug.contains("meterMap: store.transport.meterMap)"))
        #expect(debug.contains("fields[\"transportReadout\"] = .string(store.transport.barsBeatsDisplay)"))
    }

    @Test("B″(c) — the \"Preview\" caption: ContentView polls ONLY while the pane is open (the pane's own task, cancelled on close or switch) and hands the answer for THIS clip; the poll asks the snapshot's own door, sleeps its interval, and writes only on a CHANGE; the state row draws the caption from ONE function and reports what it drew")
    func thePreviewCaptionIsWired() {
        let view = Self.code(Self.viewPath)
        let content = Self.code(Self.contentPath)
        let app = Self.code("DAWApp/DAWProApp.swift")
        let debug = Self.code("DAWApp/PitchEditorDebugStaging.swift")
        #expect(content.contains(".task(id: clip.id) { await model.pollPitchEditorRenderAudible(clipID: clip.id) }"),
                "the poll is not tied to the pane's life")
        #expect(content.contains("renderAudible: model.pitchEditorRenderAudible(clipID: clip.id)"))
        guard let poll = Self.body(of: "pollPitchEditorRenderAudible", in: app) else {
            Issue.record("AppModel.pollPitchEditorRenderAudible not found")
            return
        }
        #expect(poll.contains("while !Task.isCancelled"))
        #expect(poll.contains("store.renderAudible(trackID: track.id, clipID: clipID)"),
                "the poll asks something other than the snapshot's door")
        #expect(poll.contains("clip.rendersThroughStretchCache"), "the poll asks for clips that never render")
        #expect(poll.contains("try await Task.sleep(for: PitchEditorRenderCaption.pollInterval)"))
        #expect(poll.contains("if next != pitchEditorRenderPoll {"),
                "⛔ an unconditional write re-renders the pane at the poll's rate (@Observable invalidates on assignment)")
        #expect(poll.components(separatedBy: "pitchEditorRenderPoll = ").count - 1 == 2,
                "a write outside the compare-first guard and the stop")
        // No second timer: the pane's task is the only driver.
        #expect(!app.contains("Timer.scheduledTimer(withTimeInterval: PitchEditorRenderCaption"))
        #expect(view.contains("if let renderCaption = PitchEditorRenderCaption.text(for: renderAudible) {"))
        #expect(view.contains("chrome?.recordRenderCaption(PitchEditorRenderCaption.text(for: now))"))
        #expect(view.contains("chrome?.recordRenderCaption(PitchEditorRenderCaption.text(for: renderAudible))"))
        #expect(debug.contains("\"renderCaption\": .string(chrome.renderCaptionText)"))
        #expect(debug.contains("\"renderPoll\": pitchEditorRenderPollJSON()"))
    }
}
