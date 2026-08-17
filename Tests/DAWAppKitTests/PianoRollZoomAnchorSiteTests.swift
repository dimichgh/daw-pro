import Foundation
import Testing

/// m25-b-3 — the SOURCE-SHAPE half of "zooming the note editor keeps the beat
/// under the cursor still".
///
/// **WHY THIS EXISTS.** `PianoRollZoomTests` proves the RULES: what the anchor is,
/// that the beat under it survives a rescale, that off-clip falls back to the
/// shared centre. It cannot prove any of it is WIRED — that the roll actually
/// re-pins on a zoom, that the pinch anchors on the POINTER, that the compensating
/// offset is measured in the OLD scale, or that the ⌘± router still reaches the
/// rule. All of that lives in `DAWApp`, which has **no test target**, so a perfect
/// rule could sit beside a view that never calls it and every suite would stay
/// green. This file is that gap's substitute — the `PianoRollEdgeDragSiteTests`
/// idiom, same harness.
///
/// ⚠️ **A TOKEN SEARCH FINDS THE TOKEN, NOT THE BEHAVIOUR.** Nothing in this tree
/// can see a scroll position or a pixel, so none of these assertions proves the
/// content actually holds still — they prove the shape that makes it possible, and
/// that the specific mistakes this item nearly shipped are absent. If one fails, do
/// not "fix" it by rewording the source: every assertion names the failure it
/// exists to catch.
@Suite("Piano-roll zoom anchor — the wiring pins (m25-b-3)")
struct PianoRollZoomAnchorSiteTests {

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
        // Loud, never silent: a reader that cannot find the tree would pass every
        // "does not contain" assertion below, which is the most dangerous green.
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

    /// Every line with comments removed, so a body's own prose can neither satisfy
    /// nor violate an assertion about what it CALLS. Load-bearing here: this item
    /// wrote long doc comments naming `scrollExternally`, `bandViewportWidth / 2`
    /// and `playheadLineX`, and half the pins below are ABSENCE assertions that
    /// those comments would otherwise break.
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

    /// The text BETWEEN the braces of `func <name>` — or of `var <name>`, since half
    /// the things worth pinning in a SwiftUI view are computed properties — by brace
    /// matching. Returns nil when the declaration cannot be found, and every caller
    /// treats that as a FAILURE: "renamed" and "clean" must never look the same.
    private static func body(of name: String, in content: String) -> String? {
        let code = codeOnly(content)
        guard let decl = code.range(of: "func \(name)")
                ?? code.range(of: "var \(name)") else { return nil }
        guard let open = code.range(of: "{", range: decl.upperBound..<code.endIndex) else {
            return nil
        }
        var depth = 0
        var index = open.lowerBound
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(code[code.index(after: open.lowerBound)..<index])
                }
            }
            index = code.index(after: index)
        }
        return nil
    }

    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"
    private static let appPath = "DAWApp/DAWProApp.swift"
    private static let rollDir = "DAWApp/PianoRoll"

    private func rollBody(_ name: String) -> String {
        let found = Self.body(of: name, in: Self.text(Self.rollPath))
        #expect(found != nil, "`\(name)` not found in \(Self.rollPath) — renamed?")
        #expect(found?.isEmpty == false, "`\(name)` body is empty")
        return found ?? ""
    }

    private func appBody(_ name: String) -> String {
        let found = Self.body(of: name, in: Self.text(Self.appPath))
        #expect(found != nil, "`\(name)` not found in \(Self.appPath) — renamed?")
        return found ?? ""
    }

    private func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - Controls

    @Test("the reader reads, the stripper strips, and the extractor can fail (controls)")
    func harnessControls() {
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(roll.count > 2_000, "\(Self.rollPath) came back suspiciously short: \(roll.count)")
        #expect(occurrences("gridScrollX", in: roll) > 0)          // positive
        #expect(occurrences("zzNotARealToken", in: roll) == 0)     // negative
        // The stripper really removes comments — this whole suite's absence pins
        // depend on it, and the source it reads is thick with prose naming the very
        // tokens they forbid.
        let stripped = Self.codeOnly("// scrollExternally in a comment\nlet x = 1\n")
        #expect(!stripped.contains("scrollExternally"))
        #expect(stripped.contains("let x = 1"))
        // And the extractor returns nil for something that is not there, so a
        // renamed declaration reddens instead of asserting against "".
        #expect(Self.body(of: "zzNoSuchDeclaration", in: Self.text(Self.rollPath)) == nil)
    }

    // MARK: - The funnel is mounted on the ONE thing every driver shares

    @Test("every zoom re-pins: the rule hangs off the pianoRollPPB change itself")
    func funnelIsMountedOnTheSlot() {
        let code = Self.codeOnly(Self.text(Self.rollPath))
        let note = "the roll no longer re-pins the anchor on a zoom. The pinch, the header ± "
            + "cluster, ⌘+/⌘−/⌘0 and `debug.panelLayout {pianoRollPPB}` all write ONE slot and "
            + "nothing else; if this call is gone, all four go back to sliding the content out "
            + "from under the pointer and every PianoRollZoomTests leg still passes."
        let bindsBoth = note + " (the handler must bind BOTH values — the OLD scale is the "
            + "input the compensating offset is computed from)"
        #expect(code.contains(".onChange(of: layout.pianoRollPPB, initial: true) { oldPPB, ppb in"),
                "\(bindsBoth)")
        #expect(code.contains("repinZoomAnchor(oldPPB: oldPPB, newPPB: ppb)"), "\(note)")
    }

    @Test("⚠️⚠️ the anchor is measured at the OLD scale — the bug this item nearly shipped")
    func anchorIsMeasuredAtTheOldScale() {
        let repin = rollBody("repinZoomAnchor")
        // THE HIGHEST-VALUE PIN IN THE ITEM. The handler assigns
        // `model.pixelsPerBeat = ppb` BEFORE calling this, so the `playheadLineX`
        // PROPERTY (which reads `model.pixelsPerBeat`) would hand back the
        // playhead's content x at the NEW scale, while the anchor being computed is
        // a screen x that must be measured in the OLD one. The result is a
        // plausible number, a wrong anchor, and content that slides by exactly the
        // zoom step — invisible to every rule test, because the rules are right and
        // only the argument is wrong. `setArrangeZoom` passes `positionBeats * old`
        // explicitly for the same reason.
        let note = "repinZoomAnchor must ask for the playhead at the OLD ppb"
        #expect(repin.contains("playheadLineX(atPPB: oldPPB)"), "\(note)")
        // A COUNT, so a bare `playheadLineX` creeping back in beside it fails too.
        #expect(occurrences("playheadLineX", in: repin)
                == occurrences("playheadLineX(atPPB: oldPPB)", in: repin),
                "\(note) — and must not ALSO read the property form, which is the new scale")
        // Same rule from the other side: nothing in here may read the live model
        // scale, which the caller has already advanced.
        #expect(!repin.contains("model.pixelsPerBeat"),
                "\(note) — `model.pixelsPerBeat` is already the NEW value here")
        // And the base's own scale is the old one.
        #expect(repin.contains("ppb: oldPPB"), "the anchor base must be measured at the old scale")
    }

    @Test("the offset arithmetic is REUSED from its one home, never re-derived here")
    func offsetMathIsTheSharedHome() {
        let repin = rollBody("repinZoomAnchor")
        let sharedNote = "the roll must call the shared anchor arithmetic "
            + "(ArrangeZoomModel.swift:53), which `PianoRollZoom` already borrows "
            + "`pixelsPerBeatRange` and `stepFactor` from"
        #expect(repin.contains("ArrangeZoom.offsetPreservingAnchor("), "\(sharedNote)")
        let anchorNote = "the default anchor must be the roll's own shared rule (playhead when a "
            + "line is drawn, else the viewport centre) and not a locally invented point"
        #expect(repin.contains("PianoRollZoom.anchorScreenX("), "\(anchorNote)")
        // ⚠️ WHAT THIS CAN AND CANNOT PROVE: a token search cannot rule out a copy
        // written with different names. It CAN rule out the copy an author actually
        // makes — the one pasted from the shared implementation, which carries its
        // identifiers with it. Scanned over the whole roll DIRECTORY, so a copy in a
        // NEW file is caught too.
        let dir = Self.sourcesDir().appendingPathComponent(Self.rollDir, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let scanNote = "the roll directory scan found \(files.count) files — did the path move? "
            + "An empty scan passes every absence check below for free."
        #expect(files.count >= 3, "\(scanNote)")
        var scanned = 0
        for name in files where name.hasSuffix(".swift") {
            guard let raw = try? String(contentsOf: dir.appendingPathComponent(name),
                                        encoding: .utf8) else { continue }
            scanned += 1
            let code = Self.codeOnly(raw)
            let copyNote = "\(name) re-derives the anchor beat — that formula has ONE home "
                + "(`ArrangeZoom.offsetPreservingAnchor`), and a second copy is the "
                + "duplicated-resolution-path class this project keeps paying for"
            #expect(!code.contains("anchorBeat"), "\(copyNote)")
            #expect(!code.contains("/ oldPPB"), "\(copyNote)")
        }
        #expect(scanned >= 3, "only \(scanned) roll sources were actually read")
    }

    @Test("the guards: no scale change and no laid-out viewport are both no-ops")
    func funnelGuards() {
        let repin = rollBody("repinZoomAnchor")
        // `initial: true` fires with old == new on every mount (and on every clip
        // switch, since the roll is `.id(clip.id)`-mounted); a clamped write at
        // either end of the ladder does too. Without the guard, each of those would
        // issue a scroll — and a mount-time scroll would move a view the user has
        // not touched.
        #expect(repin.contains("abs(newPPB - oldPPB)"),
                "a zoom that did not change the scale must not scroll")
        // A zero viewport is a view that has not been laid out yet: its centre is a
        // fake anchor and its offset is not yet reported.
        #expect(repin.contains("bandViewportWidth > 0"),
                "an unlaid-out viewport has no anchor to hold")
    }

    // MARK: - One writer, and it is not the gesture

    @Test("⚠️ the compensating scroll has exactly ONE writer per zoom")
    func oneScrollWriter() {
        let repin = rollBody("repinZoomAnchor")
        let seamNote = "the zoom must issue exactly one scroll — the roll's programmatic seam "
            + "(m23-c2), the same one the minimap jump and the edge drag take"
        #expect(occurrences("follow.scrollExternally(", in: repin) == 1, "\(seamNote)")
        let pinch = rollBody("gridPinch")
        // ⭐ THE ORDERING TRAP, CLOSED BY SHAPE. An earlier sketch had the pinch
        // call `scrollExternally` itself and let the funnel skip while a pinch was
        // live — which requires the skip to out-race the gesture's own `onEnded`,
        // and nothing in SwiftUI guarantees that. With the gesture writing only the
        // scale there is no race to lose.
        #expect(!pinch.contains("scrollExternally"),
                "the pinch must NOT issue its own scroll; the funnel owns the offset")
        #expect(occurrences("layout.setPianoRollPPB(", in: pinch) == 1,
                "the pinch writes the scale, once, and nothing else")
    }

    @Test("the pinch anchors on the POINTER, captured once, at the gesture-start scale")
    func pinchAnchorsOnThePointer() {
        let pinch = rollBody("gridPinch")
        // The pointer is the thing the user is looking at, and the arrange agrees:
        // `TimelineLanesView` feeds `value.startLocation.x` into `PinchState`.
        // `startLocation` is a CONTENT-space point (this gesture is attached to the
        // grid Canvas inside the horizontal scroller, the same space `gridDrag`
        // feeds straight into `model.hitTest`), so the scroll offset is what turns
        // it into the screen x that must stay put.
        #expect(pinch.contains("value.startLocation.x - gridScrollX"),
                "the pinch must anchor on the pointer's SCREEN x")
        // Captured ONCE. Re-deriving the anchor each tick from a live `gridScrollX`
        // would feed the zoom's own motion back into it — a scroll request that has
        // not landed yet reads as a different anchor beat, and the beat under the
        // pointer wanders through the pinch.
        #expect(pinch.contains("if zoomAnchorBase == nil"),
                "the anchor must be captured on the FIRST tick and held")
        let releaseNote = "the base must be released at the end of the gesture, or the NEXT zoom "
            + "(a stepper press, a ⌘+) would anchor on a stale pointer"
        #expect(pinch.contains("zoomAnchorBase = nil"), "\(releaseNote)")
        // Magnification is cumulative, so each tick rescales off the gesture-START
        // scale — the same memo the anchor rides in, not a second one.
        #expect(pinch.contains("base.ppb * value.magnification"),
                "a pinch tick must rescale from the gesture-start scale")
    }

    // MARK: - The drivers that were NOT edited are still covered

    @Test("the header ± cluster still writes only the slot — so the funnel covers it")
    func stepperButtonsRideTheFunnel() {
        let cluster = rollBody("zoomCluster")
        #expect(cluster.contains("layout.setPianoRollPPB(PianoRollZoom.zoomedOut("))
        #expect(cluster.contains("layout.setPianoRollPPB(PianoRollZoom.zoomedIn("))
        // If a later author "fixes" the steppers by scrolling here too, the zoom
        // gets two writers and they will disagree — this is the pin that says the
        // coverage comes from the funnel and must keep coming from there.
        #expect(!cluster.contains("scrollExternally"),
                "the steppers must not issue their own scroll; the ppb change already does")
    }

    @Test("⌘+/⌘−/⌘0 still route to the same slot — so the keyboard path is anchored too")
    func routerRidesTheFunnel() {
        // The defect was reported as "pinch, or ⌘+/⌘−", and the ⌘ path does NOT go
        // through the roll's header buttons: it goes through the app-level router,
        // which writes the persisted slot from outside the view. It is covered
        // because the funnel hangs off the slot rather than off a driver — and that
        // is exactly what this pin protects.
        for name in ["zoomPianoRollIn", "zoomPianoRollOut", "zoomPianoRollReset"] {
            let fn = appBody(name)
            let routerNote = "\(name) must keep writing the persisted slot — that write IS the "
                + "anchor rule's trigger; a private path around it would silently lose the "
                + "no-jump behaviour"
            #expect(fn.contains("panelLayout.setPianoRollPPB("), "\(routerNote)")
        }
    }

    // MARK: - The pins discriminate (planted mutants, in memory)

    @Test("⭐ every pin above FAILS on the mutation it exists to catch")
    func pinsDiscriminate() {
        // ⚠️⚠️ **A PASSING SOURCE-SHAPE TEST PROVES NOTHING UNTIL IT HAS BEEN SEEN
        // TO FAIL.** This project has already paid for that: `EditorSurfaceOwnership`'s
        // `contains("onCommit: commit")` PREFIX-MATCHED `onCommit: commitControllerLane`
        // and passed whether or not the lane was wired at all (m25-a).
        //
        // The mutants are planted in a COPY OF THE REAL TEXT, in memory — never in
        // the tree. A mutation run that edits shared sources is a mutation run that
        // can be interrupted half-applied, and this file is read by a suite that
        // another agent may be running at the same time.
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        let repin = rollBody("repinZoomAnchor")
        let pinch = rollBody("gridPinch")

        // M1 — the OLD-SCALE bug: someone "simplifies" the explicit overload back to
        // the property. The count-equality pin is what catches it; a plain
        // `contains("playheadLineX")` would NOT, which is why it is a count.
        let m1 = repin.replacingOccurrences(of: "playheadLineX(atPPB: oldPPB)",
                                            with: "playheadLineX")
        #expect(m1 != repin, "M1 did not apply — the needle it mutates has moved")
        #expect(occurrences("playheadLineX", in: m1)
                != occurrences("playheadLineX(atPPB: oldPPB)", in: m1),
                "M1: the old-scale pin passed on a body that reads the NEW scale")

        // M2 — the reuse-not-copy pin: the formula pasted back in locally.
        let m2 = repin + "\n let anchorBeat = (base.offset + anchorScreenX) / oldPPB\n"
        #expect(m2.contains("anchorBeat"), "M2: the copy pin cannot see a planted copy")
        #expect(m2.contains("/ oldPPB"), "M2: the copy pin cannot see a planted divide")
        #expect(!repin.contains("anchorBeat"))   // …and the real body is clean.

        // M3 — two writers: the pinch issues its own scroll again (the ordering trap).
        let m3 = pinch + "\n follow.scrollExternally(to: 0)\n"
        #expect(m3.contains("scrollExternally"), "M3: the one-writer pin cannot see a second writer")
        #expect(!pinch.contains("scrollExternally"))

        // M4 — the funnel unhooked: the handler stops binding the old value, which is
        // the shape a "tidy the unused parameter" edit produces.
        let m4 = roll.replacingOccurrences(
            of: ".onChange(of: layout.pianoRollPPB, initial: true) { oldPPB, ppb in",
            with: ".onChange(of: layout.pianoRollPPB, initial: true) { _, ppb in")
        #expect(m4 != roll, "M4 did not apply — the handler's shape has changed")
        #expect(!m4.contains(".onChange(of: layout.pianoRollPPB, initial: true) { oldPPB, ppb in"),
                "M4: the funnel pin passed on a handler that cannot see the old scale")

        // M5 — the local centre rule reintroduced.
        let m5 = roll + "\n let centre = bandViewportWidth / 2\n"
        #expect(m5.contains("bandViewportWidth / 2"), "M5: the second-centre pin is blind")
        #expect(!roll.contains("bandViewportWidth / 2"))
    }

    @Test("the roll invents no second definition of the viewport centre")
    func noLocalCentreRule() {
        let code = Self.codeOnly(Self.text(Self.rollPath))
        // The centre fallback lives in `ArrangeZoom.anchorScreenX` and the roll
        // reaches it through `PianoRollZoom.anchorScreenX`. A local
        // `bandViewportWidth / 2` would be a second definition that silently keeps
        // the old rule the day the shared one changes.
        #expect(!code.contains("bandViewportWidth / 2"),
                "the viewport centre has one definition and it is not in this file")
    }
}
