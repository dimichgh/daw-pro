import Foundation
import Testing

/// m23-al-1 — the SOURCE-SHAPE half of editor-surface ownership.
///
/// **WHY A SITE TEST AND NOT JUST A TYPE.** `ActiveEditorSurface` has a
/// `fileprivate init`, so the only way to HOLD a verdict is to have called
/// `EditorSurfaceRouter.resolve`. That is real, and it is also LIMITED in a way
/// worth stating plainly rather than trusting: it prevents holding an unresolved
/// verdict, and it does nothing whatsoever about somebody writing
/// `if openEditorClip != nil { zoomPianoRollIn() }` — a divergent boolean that
/// never constructs the type at all. Closing THAT gap is this file's job. The
/// initializer and this suite are a pair; neither is sufficient alone.
///
/// **WHY IT ALSO PINS THINGS A GATE COULD IN PRINCIPLE MEASURE.** The gate
/// (`scripts/gates/m23al-editor-surface.mjs`) drives the seam, and the seam calls
/// `editorEngagement.engage` directly. So the link `real gesture -> engage(...)`
/// — the roll's eight funnels R1–R8 — is invisible to every leg it has, and it
/// records that as a SKIP. This suite is that skip's substitute: it asserts each
/// funnel still exists and that no new gesture has appeared beside them. Same
/// shape as `RenderClockTrustSiteTests` / `StartAnchorPolicySiteTests` in
/// `Tests/DAWEngineTests/`.
///
/// ⚠️ **A TOKEN SEARCH FINDS THE TOKEN, NOT THE BEHAVIOUR.** If one of these
/// fails, do not "fix" it by rewording the source. Every assertion here names the
/// failure it exists to catch; read that first.
///
/// Anchored to the repo via `#filePath` (the `PollDisciplinePinTests` /
/// `CanvasContractPinTests` idiom), so it runs headless with no bundle resources.
@Suite("Editor surface ownership — the reader/no-feedback/gesture pins (m23-al-1)")
struct EditorSurfaceOwnershipSiteTests {

    // MARK: - Locating the tree

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

    /// Every line with comments removed: comment-only lines become empty, and a
    /// trailing `// …` is cut. THIS IS WHAT MAKES "ZERO" AN ASSERTABLE NUMBER —
    /// `pianoRollEditorFocused` is legitimately DISCUSSED in doc comments in
    /// several places, including the nudge guard's *"deliberately not a term
    /// here"* argument, and that prose must SURVIVE.
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

    /// The text BETWEEN the braces of `func <name>`, by brace matching from the
    /// declaration. Comments are stripped first, so a body's own prose cannot
    /// satisfy or violate an assertion about what it CALLS.
    ///
    /// Returns nil when the function cannot be found — which every caller treats
    /// as a FAILURE rather than as a vacuous pass, because "the function was
    /// renamed" and "the function is clean" must never look the same here.
    private static func body(of name: String, in content: String) -> String? {
        let code = codeOnly(content).joined(separator: "\n")
        guard let declRange = code.range(of: "func \(name)(") else { return nil }
        guard let openBrace = code.range(of: "{", range: declRange.upperBound..<code.endIndex) else {
            return nil
        }
        var depth = 0
        var out = ""
        var index = openBrace.lowerBound
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

    private static let appPath = "DAWApp/DAWProApp.swift"
    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"

    /// The three ROUTER entry points — the ones a ⌘ key equivalent lands on.
    private static let routers = ["zoomIn", "zoomOut", "zoomReset"]

    /// Every zoom entry point that must not engage. `setArrangeZoom` is included
    /// because the per-surface helpers funnel through it, so a single engage
    /// there would infect all of them at once.
    private static let zoomEntryPoints = [
        "zoomIn", "zoomOut", "zoomReset",
        "setArrangeZoom",
        "zoomArrangeIn", "zoomArrangeOut", "zoomArrangeReset",
        "zoomPianoRollIn", "zoomPianoRollOut", "zoomPianoRollReset",
    ]

    // MARK: - F1: the router may never read SwiftUI focus again

    @Test("the ⌘ zoom routers do not read `pianoRollEditorFocused` — the m23-al bug, by name")
    func routersDoNotReadTheFocusFlag() {
        let app = Self.text(Self.appPath)
        #expect(!app.isEmpty)
        for name in Self.routers {
            guard let fn = Self.body(of: name, in: app) else {
                let missing = "could not find `func \(name)(` in \(Self.appPath) — if it was "
                    + "renamed, RENAME IT HERE TOO. A missing function must never read as a "
                    + "clean pass on this assertion"
                Issue.record("\(missing)")
                continue
            }
            let banned = "`\(name)` reads `pianoRollEditorFocused`. That flag is a REPORT of "
                + "SwiftUI arbitration between two competing @FocusState owners and is measurably "
                + "non-deterministic (12 clicks on ONE clip: true once, false eleven times). "
                + "Routing on it is the m23-al bug. Read `activeEditorSurface` instead."
            #expect(!fn.contains("pianoRollEditorFocused"), "\(banned)")
            // The positive half: a router that read NOTHING would also pass the
            // assertion above. This is what makes it a pin rather than a ban.
            let required = "`\(name)` does not read `activeEditorSurface` — the router must ask "
                + "the ONE home, not invent a second answer"
            #expect(fn.contains("activeEditorSurface"), "\(required)")
        }
    }

    @Test("`pianoRollEditorFocused` is still FED and ECHOED — demoted to an instrument, not deleted")
    func theOldFlagSurvivesAsAnInstrument() {
        // The counterpart to the ban above, and it is not decoration. Keeping the
        // flag alive beside the new verdict is what makes the DIVERGENCE between
        // "who holds SwiftUI focus" and "which surface is active" observable on
        // the wire — precisely the instrument m23-bw needs, and precisely the
        // thing that was invisible for two cycles. Deleting it would close the
        // bug and blind the next investigation.
        let app = Self.codeOnly(Self.text(Self.appPath)).joined(separator: "\n")
        let view = Self.codeOnly(Self.text("DAWApp/ContentView.swift")).joined(separator: "\n")
        #expect(app.contains("var pianoRollEditorFocused"), "the flag must still exist")
        #expect(view.contains("model.pianoRollEditorFocused = $0"),
                "the roll must still REPORT its focus (ContentView's `onFocusChange:`)")
        #expect(app.contains("\"pianoRollEditorFocused\": .bool(pianoRollEditorFocused)"),
                "the flag must still be ECHOED on the debug seams beside the new verdict")
    }

    // MARK: - F2: no zoom entry point may engage (self-confirming latch)

    @Test("NO zoom entry point calls `engage(` — a router that engaged its own target would latch")
    func noZoomEntryPointEngages() {
        let app = Self.text(Self.appPath)
        for name in Self.zoomEntryPoints {
            guard let fn = Self.body(of: name, in: app) else {
                let missing = "could not find `func \(name)(` in \(Self.appPath) — rename it "
                    + "here too rather than letting a missing function pass silently"
                Issue.record("\(missing)")
                continue
            }
            let note = "`\(name)` calls `engage(`. A router that engages the surface it just "
                + "routed to is SELF-CONFIRMING: the first ⌘+ that reached the roll would latch "
                + "the roll forever, and the arrange could never take the keys back. Engage at "
                + "the BUTTON or the GESTURE, never at the zoom entry point."
            #expect(!fn.contains("engage("), "\(note)")
        }
    }

    @Test("`arrangePinchChanged` DOES engage — it is a gesture, not a router target")
    func theArrangePinchEngages() {
        // The controlled half of the assertion above. Without it, `engage` could
        // be deleted from every arrange gesture and the ban would still pass —
        // "nothing engages anywhere" is not the property being pinned. The pinch
        // is the interesting case: it changes a zoom, so it LOOKS like a router
        // target, but it writes `panelLayout.setArrangePPB` directly and sits on
        // no routed path, which is exactly what makes engaging there legal.
        let app = Self.text(Self.appPath)
        guard let fn = Self.body(of: "arrangePinchChanged", in: app) else {
            Issue.record("could not find `func arrangePinchChanged(` in \(Self.appPath)")
            return
        }
        #expect(fn.contains("editorEngagement.engage(.arrange)"))
        // ...and it must still not route: if it ever started calling the shared
        // `setArrangeZoom`, the ban above would be violated transitively.
        let routed = "`arrangePinchChanged` now routes through `setArrangeZoom`, which it "
            + "engages before — that composition is the self-confirming latch by another route"
        #expect(!fn.contains("setArrangeZoom"), "\(routed)")
    }

    // MARK: - The five ARRANGE engagement funnels

    @Test("every ARRANGE engagement funnel is present — including the two that are easy to miss")
    func arrangeFunnelsArePresent() {
        let app = Self.text(Self.appPath)
        // Named individually, because two of these were nearly dropped in design
        // and a bare count would not have noticed:
        //   • `noteCreatedClip` sets `selectedClipID` DIRECTLY and never goes
        //     through `clickClip`, so the empty-lane create would otherwise leave
        //     the ROLL engaged while opening a brand new clip.
        //   • `applyArrangeMarquee` deliberately does NOT bump the key-focus
        //     nonce, so it is the site most likely to be "left alone by symmetry".
        for name in ["clickClip", "clickTrack", "applyArrangeMarquee",
                     "noteCreatedClip", "arrangePinchChanged"] {
            guard let fn = Self.body(of: name, in: app) else {
                Issue.record("could not find `func \(name)(` in \(Self.appPath)")
                continue
            }
            let note = "`\(name)` no longer engages the arrange — a user gesture in the arrange "
                + "that does not claim the surface leaves ⌘+ aimed wherever it was last"
            #expect(fn.contains("editorEngagement.engage(.arrange)"), "\(note)")
        }
    }

    @Test("the arrange TOOLBAR zoom buttons engage at the BUTTON, not inside the zoom call")
    func arrangeToolbarButtonsEngage() {
        let view = Self.codeOnly(Self.text("DAWApp/ContentView.swift")).joined(separator: "\n")
        // Both buttons, and both must engage: a cluster where only "+" engaged
        // would make ⌘− and the toolbar "−" disagree about which surface is live.
        #expect(view.contains("model.zoomArrangeIn()"))
        #expect(view.contains("model.zoomArrangeOut()"))
        let engagements = view.components(separatedBy: "model.editorEngagement.engage(.arrange)")
            .count - 1
        let note = "expected exactly 2 arrange engagements in ContentView (the toolbar's − and "
            + "+), found \(engagements). A third would most likely be a zoom entry point that "
            + "learned to engage itself."
        #expect(engagements == 2, "\(note)")
        let wired = "the roll's `onEngage:` must still be wired beside `onFocusChange:`"
        #expect(view.contains("onEngage: { model.editorEngagement.engage(.pianoRoll) }"),
                "\(wired)")
    }

    // MARK: - F3/F11: the roll's eight funnels, and the gesture count that guards them

    @Test("all TEN piano-roll engagement funnels R1–R10 are still present")
    func rollFunnelsArePresent() {
        let roll = Self.text(Self.rollPath)
        #expect(!roll.isEmpty)
        // The MARKERS are comments, so they are read from the RAW text. They are
        // the map; the call count below is the territory. Both, because a marker
        // without a call is a lie and a call without a marker is unmaintainable.
        for tag in ["m23-al R1", "m23-al R2", "m23-al R3", "m23-al R4",
                    "m23-al R5", "m23-al R6", "m23-al R7", "m23-al R8",
                    "m23-al R9", "m23-al R10"] {
            let note = "the \(tag) engagement funnel is gone from PianoRollView. Each funnel "
                + "covers a DISTINCT gesture family — R7 in particular is NOT covered by R6, "
                + "because the controller strip carries its own `onCommit` and never calls "
                + "`commit()`."
            #expect(roll.contains(tag), "\(note)")
        }
        // MEASURED against this tree (2026-08-03): R1, R2, R3, R4, R5 ×2 (the
        // header's − and +), R6, R7, R8 = 9 calls. R5 is two because the cluster
        // has two buttons; every other funnel was one site.
        //
        // ⚠️ 9 → 11 AT m23-ek-3, RE-MEASURED: R9, the CLIPBOARD funnel, is TWO
        // sites — the roll's cut and its paste. Both mutate, so both claim the
        // zoom keys exactly as the context-menu delete does through R6. ⚠️ COPY
        // IS THE THIRD CLIPBOARD BRANCH AND IT IS DELIBERATELY NOT A SITE: every
        // funnel here is a gesture that CHANGES something (R6's safety argument
        // is precisely that its callers are edits), and a copy mutates nothing —
        // engaging on a pure read would let it silently re-point ⌘+.
        //
        // ⚠️ 11 → 12 AT m25-b-1, and the pin's own standing instruction ("if this
        // ever reads 12, check whether COPY grew an `onEngage()` before assuming a
        // new gesture landed") WAS FOLLOWED: copy did not. R10 is the header's new
        // MAXIMIZE toggle, and it was held to the rule rather than waved through.
        // Maximizing is not a read — it changes the view, exactly as R5's zoom
        // cluster does, and it is the strongest statement available that the roll
        // is the surface the user is working in. Leaving it out would have aimed
        // ⌘+/⌘−/⌘0 at an arrange collapsed to an 86 pt ruler strip. The
        // counter-example that stays OUT is CLOSE: it ends the surface rather than
        // claiming it, so it has no engagement and should never grow one.
        let calls = Self.codeOnly(roll).joined(separator: "\n")
            .components(separatedBy: "onEngage()").count - 1
        let countNote = "expected 12 `onEngage()` calls in PianoRollView (R1–R10, with R5 and R9 "
            + "each counted twice — the header cluster's two buttons, and the clipboard's cut "
            + "and paste), found \(calls). If a gesture was added, add its engagement and "
            + "update this number; if one was removed, that gesture no longer claims ⌘+."
        #expect(calls == 12, "\(countNote)")
    }

    @Test("R6 `commit()` has no NON-GESTURE caller — the property that makes it safe to engage there")
    func commitHasOnlyGestureCallers() {
        // R6 engages inside `commit()` rather than at its four call sites, and
        // that is only sound while every caller is a user gesture. Recorded here
        // so the next person to add a caller is forced past it: an automatic or
        // lifecycle-driven `commit()` would FALSE-ENGAGE the roll and silently
        // steal ⌘+ from the arrange.
        let roll = Self.codeOnly(Self.text(Self.rollPath)).joined(separator: "\n")
        // ⚠️ THE NEEDLE IS `commit(`, NOT `commit()` — CHANGED 2026-08-13 (m25-a).
        // `commit` now takes `extendToCover:` (defaulted), so a caller can spell
        // itself `commit(extendToCover: […])` and a needle of `commit()` would
        // MISS IT — the pin would have gone quiet on exactly the kind of new
        // caller it exists to catch, while still reading a plausible number.
        // `commit(` catches both spellings. It does NOT collide with the
        // `onCommit(` closure invocation inside the definition (capital C) or
        // with `commitControllerLane(` (no paren after `commit`), both verified
        // against this file's `codeOnly` stripping.
        let callers = roll.components(separatedBy: "commit(").count - 1
        // MEASURED (2026-08-03): the `.onKeyPress(.delete)` handler, the
        // double-tap add, `endGesture` when the note moved, and the definition
        // itself. The velocity lane passes `commit` BY REFERENCE
        // (`onCommit: commit`), so it does not appear as `commit()`.
        //
        // RE-MEASURED 2026-08-04 (m23-cf), 4 -> 6, and BOTH new callers were held
        // to the rule above rather than waved through:
        //   • the NOTE CONTEXT MENU's Delete entry — a right-click on the grid, as
        //     much a user gesture as the double-tap add beside it.
        //   • the `noteSelection.deleteNonce` handler — Edit ▸ Delete. A MENU
        //     CLICK, not a lifecycle event: the nonce's only producer is
        //     `PianoRollNoteSelectionBridge.requestDelete()`, whose only caller is
        //     `AppModel.performMenuDelete()`. No timer, no `.onAppear`, and
        //     deliberately no debug seam. A user who deletes notes from the Edit
        //     menu HAS just acted inside the roll, so engaging it there is
        //     correct, not a false engage.
        // RE-MEASURED 2026-08-09 (m23-cq-1), 6 -> 7, and the new caller was held
        // to the rule above rather than waved through:
        //   • `applyStepToggle` — the STEP SEQUENCER's cell toggle. Its only two
        //     callers are the grid's `SpatialTapGesture` (a click) and the
        //     `stepSequencer.toggleNonce` handler, whose only producer is
        //     `StepSequencerBridge.stageToggle` — i.e. `debug.stepSequencer`,
        //     a deliberate staging seam standing in for that same click. No
        //     timer, no `.onAppear`, no lifecycle path. Clicking a step cell IS
        //     the user acting inside the editor pane, so engaging there is
        //     correct.
        //
        // ⚠️ RE-MEASURED 2026-08-09 (m23-cf, second pass), 7 -> 6 — A CALLER WAS
        // REMOVED, AND THIS IS THE ONE DIRECTION THIS PIN MUST NOT BE "FIXED" BY
        // REFLEX. `.onKeyPress(.delete)` no longer deletes inline: DELETE now
        // goes through `AppModel.handleDeleteKey`, the ONE routing decision all
        // three focus-gated claimants consult, and when it names the roll it
        // bumps `noteSelection.deleteNonce` — which lands in the handler that was
        // ALREADY counted above (Edit ▸ Delete's, since the first m23-cf pass).
        // So the key's delete and the menu's delete became the SAME caller
        // instead of two identical ones. R6 is unaffected in substance: the
        // routed delete still runs `deleteSelection()` + `commit()`, so a key
        // press still engages the roll exactly as it did.
        //   Remaining 5 callers + the definition: the double-tap add, `endGesture`
        //   when the note moved, the note context menu's Delete, the
        //   `deleteNonce` handler (key AND menu), `applyStepToggle`.
        // ⚠️ IF THIS EVER READS 7 AGAIN, CHECK WHETHER A KEY HANDLER WENT BACK TO
        // DELETING INLINE before assuming a new gesture landed — that is the
        // m23-cf regression, and it is INTERMITTENT by nature (it only misbehaves
        // on the presses where SwiftUI focused that particular claimant).
        // ⚠️ RE-MEASURED 2026-08-13 (m25-a), 6 -> 7. **NO NEW GESTURE LANDED.**
        // The count moved for two reasons, and neither is a new caller:
        //   ① The needle changed from `commit()` to `commit(` (see above), which
        //      is what keeps the DOUBLE-TAP ADD counted now that it spells itself
        //      `commit(extendToCover: [note.id])` — auto-extending the clip is
        //      the same gesture it always was, now naming the note that may grow
        //      the clip. Same for the definition itself.
        //   ② The VELOCITY LANE became VISIBLE to this pin. It was always a
        //      caller — the note above says so — but it passed `commit` BY
        //      REFERENCE and therefore never appeared in the count. m25-a gave
        //      `commit` a defaulted parameter, and Swift drops default arguments
        //      when a method is used as a function VALUE, so the reference no
        //      longer type-checks as `() -> Void` and the site is now spelled
        //      `onCommit: { commit() }`. The pin got STRICTER, not looser: a
        //      caller it was previously blind to is now inside the fence.
        //   Full list at 7: the definition, the double-tap add (m25-a spelling),
        //   `endGesture` when the note moved, the note context menu's Delete, the
        //   `deleteNonce` handler (key AND menu), `applyStepToggle`, and the
        //   velocity lane's closure. Every one is a user gesture or an explicit
        //   user menu action, so R6 still cannot false-engage.
        let note = "expected 7 occurrences of `commit(` in PianoRollView (6 gesture/menu callers "
            + "+ the definition), found \(callers). A NEW caller must be checked: if it is not a "
            + "user gesture or an explicit user menu action, R6 now false-engages the roll."
        #expect(callers == 7, "\(note)")
        // ⚠️ THE NEEDLE HERE WAS `onCommit: commit` UNTIL 2026-08-13 (m25-a), AND
        // IT WAS VACUOUS: `onCommit: commitControllerLane` (the controller strip,
        // one screen down) contains that string as a PREFIX, so this expectation
        // passed whether or not the velocity lane was wired to `commit` at all.
        // The m25-a spelling is unambiguous and cannot be prefix-matched by a
        // different symbol.
        let lane = "the velocity lane must still commit through `commit` (that is how R6 covers "
            + "it)"
        #expect(roll.contains("onCommit: { commit() }"), "\(lane)")
    }

    @Test("the gesture-attachment count under Sources/DAWApp/PianoRoll/ is pinned")
    func rollGestureCountIsPinned() {
        // F3: a NEW gesture in the roll that forgets to engage fails silently —
        // that one gesture just never claims ⌘+, and no behavioural test in this
        // repo would notice. This pin reddens instead and forces its author to
        // decide.
        let dir = sourcesDirPianoRoll()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else {
            Issue.record("could not enumerate \(dir.path)")
            return
        }
        let swift = files.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        // ANTI-VACUITY: a walk that found nothing would report a clean 0 and pass
        // any "<= N" assertion. Pin the FILE count too.
        let fileNote = "expected 7 Swift files under Sources/DAWApp/PianoRoll/ "
            + "(ControllerLaneStrip, KeyboardSidebar, PianoRollMarqueeStaging, PianoRollView, "
            + "StepSequencerGrid, StepSequencerStaging, VelocityLane), found \(swift.count)"
        #expect(swift.count == 7, "\(fileNote)")
        var total = 0
        var perFile: [String: Int] = [:]
        for url in swift {
            let code = Self.codeOnly(Self.text("DAWApp/PianoRoll/\(url.lastPathComponent)"))
                .joined(separator: "\n")
            var n = 0
            for needle in [".gesture(", ".simultaneousGesture(", ".onTapGesture"] {
                n += code.components(separatedBy: needle).count - 1
            }
            perFile[url.lastPathComponent] = n
            total += n
        }
        // MEASURED against this tree (2026-08-03), NOT copied from the design —
        // which said "a seventh gesture reddens the test" while itself counting
        // only PianoRollView's four. The whole directory carries SEVEN:
        //   PianoRollView 4 (gridDrag, gridPinch, the double-tap add, scrubDrag)
        //   KeyboardSidebar 1, VelocityLane 1, ControllerLaneStrip 1
        //
        // RE-MEASURED 2026-08-09 (m23-cq-1), 7 -> 8: `StepSequencerGrid` adds
        // ONE — the step grid's `cellTap`, the whole interaction vocabulary of
        // that surface. It engages through `PianoRollView.applyStepToggle` →
        // `commit()` (R6/R9) rather than calling `onEngage` itself, which is
        // the same route the double-tap add takes.
        //
        // ⭐ STILL 8 AFTER m23-ek-1, AND THAT IS THE POINT OF THE ITEM. The roll's
        // rubber band adds NO gesture: it is a PROMOTION inside the existing
        // `gridDrag`, entered from `.click(nil)` once the pointer travels
        // `PianoRollMarquee.dragSlop`. The arrange's `.simultaneousGesture`
        // shape was rejected precisely because a second gesture would race
        // `gridDrag`'s own `clearSelection()` at release, at an ordering this
        // tree cannot observe (m23-bw). If this number ever reaches 9 because
        // somebody "restored consistency with the arrange", that is the
        // regression, not the fix.
        let breakdown: String = perFile.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let note = "gesture attachments under Sources/DAWApp/PianoRoll/ moved from 8 to "
            + "\(total) (\(breakdown)). A NEW gesture in the piano roll must decide whether it "
            + "ENGAGES the roll (call `onEngage()` and add an `m23-al Rn` marker) — otherwise "
            + "that gesture silently fails to claim ⌘+/⌘−/⌘0. Then update this number."
        #expect(total == 8, "\(note)")
    }

    private func sourcesDirPianoRoll() -> URL {
        Self.sourcesDir().appendingPathComponent("DAWApp/PianoRoll", isDirectory: true)
    }

    @Test("the grid's `.contentShape(Rectangle())` survives — m23-cf's measured hit region")
    func gridKeepsItsHitRegion() {
        // m23-ek-1 F8. The band lives on this surface, and the tempting
        // restructure (an underlay that owns the marquee, the arrange's
        // `pointerHoverSurface` analogue) would need this shape shrunk or
        // removed to let a press through — which would silently delete the
        // context menu m23-cf added after MEASURING that a `Canvas` contributes
        // no AppKit hit region of its own. `.gesture` does not care; `.contextMenu`
        // does. Pinned as a SITE because no headless test can see a right-click.
        let roll = Self.codeOnly(Self.text(Self.rollPath)).joined(separator: "\n")
        let note = "the note grid's `.contentShape(Rectangle())` must stay directly above its "
            + "`.contextMenu` — without it the right-click passes through the Canvas and NO "
            + "menu appears (measured live on staging, m23-cf)"
        #expect(roll.contains(".contentShape(Rectangle())\n                        .contextMenu"),
                "\(note)")
    }

    // MARK: - The reader census

    @Test("`activeEditorSurface` is read only by the routers, the seam and the echo")
    func activeEditorSurfaceReaderCensus() {
        let app = Self.codeOnly(Self.text(Self.appPath)).joined(separator: "\n")
        let hits = app.components(separatedBy: "activeEditorSurface").count - 1
        // MEASURED (2026-08-03) — and DECOMPOSED, because the naive reading of
        // this number is wrong by two and I had it wrong first:
        //   1  the accessor's own declaration
        //   3  the three ⌘ routers
        //   1  `viewZoomDebug`'s `let verdict = activeEditorSurface`
        //   4  the two `debug.arrangeSelection` echo lines — TWO EACH, because
        //      the JSON KEY STRINGS `"activeEditorSurface"` and
        //      `"activeEditorSurfaceReason"` both CONTAIN the token alongside the
        //      property read on the same line. A line count says 2 here; an
        //      occurrence count says 4, and this test counts occurrences.
        //   = 9
        // ⭐ 9 → 10 AT m25-s, AND THE ONE ADDED READ IS THE POINT OF THE FEATURE.
        // `selectAllMenuItem` (Edit ▸ Select All / ⌘A) asks
        // `activeEditorSurface.surface` which editor the user is working in.
        //
        // ⚠️ IT IS A NEW SURFACE-SCOPED DECISION AND WAS CONSIDERED AS ONE, which
        // is what this pin exists to force. It does NOT go through the sibling
        // term its two Edit-menu neighbours use: `deleteMenuItem` and
        // `clipboardItem` route on `pianoRollWouldConsumeKey` ("the roll is open
        // AND HOLDS A NOTE SELECTION"), and that term cannot express this
        // question at all — a select-all is pressed precisely when no selection
        // exists yet, so routing it that way would make the feature reachable
        // only once it was unnecessary. Engagement is the honest discriminator
        // here, and this is the home for it. See `SelectAllMenuPolicy`.
        //
        // ⭐⭐ 10 → 9 AT m34-d (2026-08-30) — **THE READ ABOVE WAS REMOVED, AND
        // THE USER IS WHO REMOVED IT.** They reported ⌘A doing nothing on the
        // first press and ruled, verbatim: ***"Make it work whenever the editor
        // is open."*** Engagement was the honest discriminator right up until a
        // human used it: opening a clip is a gesture in the ARRANGE, so
        // `activeEditorSurface` answered `.arrange` for a roll they were looking
        // at. `selectAllMenuItem` now reads the SIBLING verdict
        // (`openEditorSurface` → `EditorSurfaceRouter.openSurface`), which is
        // pinned by its own census below via `openEditorClip`.
        //
        // ⚠️ THIS IS A DECREASE, AND A DECREASE IS EXACTLY AS INTERESTING AS AN
        // INCREASE HERE. A reader that quietly DISAPPEARS means a surface-scoped
        // decision started being made somewhere else — which is what happened,
        // deliberately, and is why the count moved rather than the pin being
        // loosened to a `>=`. ⭐ THE ⌘ ZOOM ROUTERS DID NOT MOVE: the ruling named
        // one keystroke, and 3 of these 9 are still the three routers.
        let note = "expected 9 code mentions of `activeEditorSurface` in DAWProApp.swift (1 "
            + "declaration + 3 routers + 1 debug.viewZoom + 4 from the two echo lines, whose "
            + "JSON KEYS also contain the token; m25-s's `selectAllMenuItem` read was REMOVED "
            + "at m34-d), found \(hits). A new reader is not automatically wrong — but it IS a "
            + "new surface-scoped decision, and m23-al-3 is where those are supposed to be "
            + "considered together rather than one at a time. A reader that VANISHED is the "
            + "same question from the other end: which home took the decision over?"
        #expect(hits == 9, "\(note)")
        // No OTHER file may read it: the whole point is that one accessor answers.
        for path in ["DAWApp/ContentView.swift"] {
            let other = Self.codeOnly(Self.text(path)).joined(separator: "\n")
            let drive = "\(path) reads `activeEditorSurface` — if a view needs the verdict, that "
                + "is a design question (al-3), not a drive-by read"
            #expect(!other.contains("activeEditorSurface"), "\(drive)")
        }
    }

    @Test("`openEditorClip` readers are pinned — the router CONSUMES that home, never forks it")
    func openEditorClipReaderCensus() {
        let app = Self.codeOnly(Self.text(Self.appPath)).joined(separator: "\n")
        let hits = app.components(separatedBy: "openEditorClip").count - 1
        // MEASURED (2026-08-03): the declaration, the nudge guard's fifth term,
        // `activeEditorSurface`'s `rollOpen:`, `act:"engage"`'s unsatisfiable
        // check, `debug.viewZoom`'s `rollOpen`, three `editorClipId` echoes and
        // one `editorOpen` echo = 9 real code reads, PLUS 1 occurrence inside the
        // TEXT of `act:"engage"`'s DebugError message = 10.
        //
        // ⚠️ STILL 10 AFTER m23-cf, BUT ONE OF THEM MOVED — re-measured, not
        // assumed. The nudge guard's fifth term is no longer a raw read: it now
        // says `pianoRollWouldConsumeKey`, and that new property's body carries
        // the raw read instead. Net zero, and the reason this pin did NOT have to
        // be raised is exactly what it is for — m23-cf needed the same predicate
        // in a SECOND place (`deleteMenuItem`, for Edit ▸ Delete), and extracting
        // ONE home was the alternative to spelling the rule twice. A future site
        // that needs it must read that property, not `openEditorClip`.
        //
        // ⚠️ THAT LAST ONE IS PROSE, NOT A READ, AND IT IS A KNOWN FRAGILITY:
        // rewording that error string reddens this pin without any reader having
        // changed. If that is why you are here, drop the number to 9 — do not go
        // looking for a reader that was never added. (The comment-stripper above
        // removes `//` comments; it does not and should not parse Swift string
        // literals.)
        //
        // WHY PIN IT AT ALL: `openEditorClip` is the tree's ONE rule for "is the
        // roll on screen", and the failure this guards against is a new site
        // spelling that rule a SECOND time — `if openEditorClip != nil {
        // zoomPianoRollIn() }` is a divergent router that never constructs
        // `ActiveEditorSurface` and so slips past its `fileprivate init`
        // untouched. That is the honest gap the initializer cannot close.
        // ⚠️ 10 → 11 AT m23-ek-3, AND THE ONE ADDED READ IS DELIBERATE. Edit ▸
        // Paste asks `ClipboardMenuPolicy.pasteMenuItem` for `rollOpen:`, i.e.
        // "is there a roll ON SCREEN to receive these notes". That is neither a
        // ZOOM nor a KEY decision, so the note below does not apply to it, and
        // routing it through `activeEditorSurface` would be WRONG rather than
        // merely unnecessary: engagement answers "which editor did the user last
        // ENGAGE", which comes apart from "is a roll mounted" — paste a note
        // group with the arrange most recently engaged and the roll still open,
        // and an engagement-routed item would refuse a paste that has a perfectly
        // good destination on screen. It is also not the m23-x consume test
        // (`pianoRollWouldConsumeKey`), which additionally requires a NOTE
        // SELECTION: you can paste into a roll holding no selection at all, and
        // reusing that property would have greyed Paste in the commonest case
        // there is. Three distinct questions, three distinct terms; this is the
        // one that genuinely wants the raw read.
        // ⚠️ 11 → 12 AT m25-s, AND IT IS NOT A SECOND "IS THE ROLL ON SCREEN".
        // `selectAllMenuItem` reads `openEditorClip?.notes?.count ?? 0` — a
        // CONTENT read, asking how many notes there are to select. It never
        // spells `openEditorClip != nil`, and the surface question it does ask is
        // routed through `activeEditorSurface`, exactly as the note below
        // demands. This pin counts raw token mentions, so a content read moves it
        // even though the failure it guards against (a divergent boolean that
        // never constructs `ActiveEditorSurface`) has not occurred.
        //
        // WHY NOT ROUTE THE COUNT SOMEWHERE ELSE: the roll's live note count
        // lives on `PianoRollModel.draft`, which is `@State private`, and the
        // bridge's `surface` echo that mirrors it is `@ObservationIgnored` AND one
        // body pass behind (measured). Store truth is the only non-stale source a
        // menu can read; `SelectAllMenuPolicy`'s parameter doc names the single
        // state where the two differ and why it is unreachable outside a live
        // gesture.
        // ⭐⭐ 12 → 13 AT m34-d, AND THE ONE ADDED READ IS THE ROUTER-MEDIATED
        // SHAPE THIS PIN EXISTS TO ASK FOR. `openEditorSurface` — the new sibling
        // accessor behind ⌘A — passes `rollOpen: openEditorClip != nil` into
        // `EditorSurfaceRouter.openSurface`, exactly as `activeEditorSurface`
        // passes it into `.resolve`. It is a raw `!= nil` in the same sense that
        // one is: a TERM handed to the router, not a verdict computed instead of
        // it. The failure this census guards against is `if openEditorClip != nil
        // { zoomPianoRollIn() }` — a boolean that decides something and never
        // constructs a router type. This one constructs `OpenEditorSurface`,
        // whose init is `fileprivate` to the router file.
        //
        // ⚠️ AND `resolve` IS NOW IMPLEMENTED ON TOP OF `openSurface`, so the two
        // accessors are two QUESTIONS asked of one computation rather than two
        // answers to one question. If a future edit makes them diverge, it is
        // `EditorSurfaceRouterTests.theSharedTermsCannotDrift` that reddens —
        // this pin only counts tokens.
        // ⚠️ 13 → 14 AT m34-d TOO, AND THE SECOND ONE IS A CONTENT READ, NOT A
        // SURFACE DECISION — the same shape this census already accepted from
        // m25-s. The `selectAllMenuItem` DEBUG ECHO added alongside the fix
        // reports `openEditorClip?.notes?.count ?? 0` so a gate can see the
        // policy's third input; "the roll is empty" is a real refusal and the
        // arrange `count` beside it is CLIPS, not notes. It never spells
        // `openEditorClip != nil` and decides nothing.
        //
        // ⭐ THIS PIN EARNED ITS KEEP ON THIS VERY ITEM: the echo was added AFTER
        // the fix's own tests were green, and this census is what noticed. It is
        // the only thing in the tree that would have.
        let note = "expected 14 code mentions of `openEditorClip` in DAWProApp.swift, found "
            + "\(hits). If the new one is a ZOOM or KEY decision, it must go through "
            + "`activeEditorSurface` (engagement) or `openEditorSurface` (mount) instead — a "
            + "raw `openEditorClip != nil` that DECIDES something is a second computation of "
            + "'which surface is active' that also silently drops the WORKSPACE term (in the "
            + "Mix console this stays non-nil with no roll mounted)."
        #expect(hits == 14, "\(note)")
    }
}
