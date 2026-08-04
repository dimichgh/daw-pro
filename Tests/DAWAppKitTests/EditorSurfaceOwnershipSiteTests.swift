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

    @Test("all EIGHT piano-roll engagement funnels R1–R8 are still present")
    func rollFunnelsArePresent() {
        let roll = Self.text(Self.rollPath)
        #expect(!roll.isEmpty)
        // The MARKERS are comments, so they are read from the RAW text. They are
        // the map; the call count below is the territory. Both, because a marker
        // without a call is a lie and a call without a marker is unmaintainable.
        for tag in ["m23-al R1", "m23-al R2", "m23-al R3", "m23-al R4",
                    "m23-al R5", "m23-al R6", "m23-al R7", "m23-al R8"] {
            let note = "the \(tag) engagement funnel is gone from PianoRollView. Each funnel "
                + "covers a DISTINCT gesture family — R7 in particular is NOT covered by R6, "
                + "because the controller strip carries its own `onCommit` and never calls "
                + "`commit()`."
            #expect(roll.contains(tag), "\(note)")
        }
        // MEASURED against this tree (2026-08-03): R1, R2, R3, R4, R5 ×2 (the
        // header's − and +), R6, R7, R8 = 9 calls. R5 is two because the cluster
        // has two buttons; every other funnel is one site.
        let calls = Self.codeOnly(roll).joined(separator: "\n")
            .components(separatedBy: "onEngage()").count - 1
        let countNote = "expected 9 `onEngage()` calls in PianoRollView (R1–R8, with R5 counted "
            + "twice for the header cluster's two buttons), found \(calls). If a gesture was "
            + "added, add its engagement and update this number; if one was removed, that "
            + "gesture no longer claims ⌘+."
        #expect(calls == 9, "\(countNote)")
    }

    @Test("R6 `commit()` has no NON-GESTURE caller — the property that makes it safe to engage there")
    func commitHasOnlyGestureCallers() {
        // R6 engages inside `commit()` rather than at its four call sites, and
        // that is only sound while every caller is a user gesture. Recorded here
        // so the next person to add a caller is forced past it: an automatic or
        // lifecycle-driven `commit()` would FALSE-ENGAGE the roll and silently
        // steal ⌘+ from the arrange.
        let roll = Self.codeOnly(Self.text(Self.rollPath)).joined(separator: "\n")
        let callers = roll.components(separatedBy: "commit()").count - 1
        // MEASURED (2026-08-03): the `.onKeyPress(.delete)` handler, the
        // double-tap add, `endGesture` when the note moved, and the definition
        // itself. The velocity lane passes `commit` BY REFERENCE
        // (`onCommit: commit`), so it does not appear as `commit()`.
        let note = "expected 4 occurrences of `commit()` in PianoRollView (3 gesture callers + "
            + "the definition), found \(callers). A NEW caller must be checked: if it is not a "
            + "user gesture, R6 now false-engages the roll."
        #expect(callers == 4, "\(note)")
        let lane = "the velocity lane must still commit through `commit` (that is how R6 covers "
            + "it)"
        #expect(roll.contains("onCommit: commit"), "\(lane)")
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
        let fileNote = "expected 4 Swift files under Sources/DAWApp/PianoRoll/ "
            + "(ControllerLaneStrip, KeyboardSidebar, PianoRollView, VelocityLane), found "
            + "\(swift.count)"
        #expect(swift.count == 4, "\(fileNote)")
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
        let breakdown: String = perFile.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let note = "gesture attachments under Sources/DAWApp/PianoRoll/ moved from 7 to "
            + "\(total) (\(breakdown)). A NEW gesture in the piano roll must decide whether it "
            + "ENGAGES the roll (call `onEngage()` and add an `m23-al Rn` marker) — otherwise "
            + "that gesture silently fails to claim ⌘+/⌘−/⌘0. Then update this number."
        #expect(total == 7, "\(note)")
    }

    private func sourcesDirPianoRoll() -> URL {
        Self.sourcesDir().appendingPathComponent("DAWApp/PianoRoll", isDirectory: true)
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
        let note = "expected 9 code mentions of `activeEditorSurface` in DAWProApp.swift (1 "
            + "declaration + 3 routers + 1 debug.viewZoom + 4 from the two echo lines, whose "
            + "JSON KEYS also contain the token), found \(hits). A new reader is not "
            + "automatically wrong — but it IS a new surface-scoped decision, and m23-al-3 is "
            + "where those are supposed to be considered together rather than one at a time."
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
        let note = "expected 10 code mentions of `openEditorClip` in DAWProApp.swift, found "
            + "\(hits). If the new one is a ZOOM or KEY decision, it must go through "
            + "`activeEditorSurface` instead — a raw `openEditorClip != nil` is a second "
            + "computation of 'which surface is active' that also silently drops the WORKSPACE "
            + "term (in the Mix console this stays non-nil with no roll mounted)."
        #expect(hits == 10, "\(note)")
    }
}
