import Testing
import Foundation

/// m25-o-2 — DRAGGING THE PLAYHEAD LINE, pinned at the SOURCE.
///
/// ⚠️ **WHY SOURCE-SITE PINS.** This gesture is reachable only with a real
/// pointer in a real window, and m23-g1 established that nothing in this tree can
/// produce one (an unbundled staging binary does not route pointer events, so no
/// `.mjs` gate can see this gesture at all). The POLICY — what is under the
/// pointer, and which target wins — is pinned behaviourally in
/// `PianoRollHoverTests`, where it belongs. What that cannot see is whether the
/// VIEW still asks. A silent unwiring (the `beginGesture` arm dropped, the seek
/// re-pointed, the deselect deleted) would leave every other test in this repo
/// green. This reddens instead.
///
/// ⚠️⚠️ **EVERY ASSERTION RUNS AGAINST COMMENT-STRIPPED, BRACE-MATCHED SOURCE**
/// (the `PianoRollGroupScaleSiteTests` rule): this file's own prose is full of the
/// symbols it asserts on, and this repo has shipped a `contains` that a DIFFERENT
/// symbol satisfied as a prefix.
@Suite("m25-o-2 — the playhead line drag is WIRED")
struct PianoRollPlayheadDragSiteTests {

    // MARK: - Helpers (the house pattern — each site suite carries its own)

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

    /// The text BETWEEN the braces of `func <name>` — or `var <name>` — by brace
    /// matching. nil means "not found", which every caller treats as a FAILURE:
    /// "renamed" and "clean" must never look the same. (The helper that once fell
    /// back to the whole file on nil is why this is spelled out.)
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

    /// The ARGUMENT LIST of a call, by paren matching from `marker` (which must
    /// end in `(`). nil means "not found", never "empty".
    ///
    /// ⚠️⚠️ **THIS EXISTS BECAUSE `body(of:)` SILENTLY WINDOWED THE WRONG
    /// FUNCTION, AND THE FIRST RUN OF `resolverIsFedTheDrawnLine` CAUGHT IT.**
    /// `body(of:)` searches `"func <name>"` and takes the FIRST match; the roll
    /// has TWO `hoverTarget` overloads, and the one-arg one — which merely
    /// delegates — is declared first. The test therefore asserted against a
    /// two-line body that never mentions the playhead and could never have
    /// passed. **A window aimed at the wrong declaration fails loudly here only
    /// because the needle was absent from it; had the needle been present for an
    /// unrelated reason it would have passed vacuously forever.** Windowing on
    /// the CALL is both narrower and the thing actually being asserted.
    private static func callArgs(of marker: String, in content: String) -> String? {
        let code = codeOnly(content)
        guard marker.hasSuffix("("), let found = code.range(of: marker) else { return nil }
        var depth = 0
        var index = code.index(before: found.upperBound)   // the `(` itself
        while index < code.endIndex {
            let ch = code[index]
            if ch == "(" { depth += 1 }
            if ch == ")" {
                depth -= 1
                if depth == 0 {
                    return String(code[found.upperBound..<index])
                }
            }
            index = code.index(after: index)
        }
        return nil
    }

    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"

    private func rollBody(_ name: String) -> String {
        let found = Self.body(of: name, in: Self.text(Self.rollPath))
        #expect(found != nil, "`\(name)` not found in \(Self.rollPath) — renamed?")
        #expect(found?.isEmpty == false, "`\(name)` body is empty")
        return found ?? ""
    }

    private func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - The press claims the line

    @Test("beginGesture routes a press on the playhead into its own drag state")
    func pressClaimsThePlayhead() {
        let begin = rollBody("beginGesture")
        #expect(begin.contains("target == .playhead"),
                "the press router no longer recognises the playhead target — the line is not grabbable")
        #expect(begin.contains("activeDrag = .playheadDrag(scrubbing: false)"),
                "the press must enter the playhead drag state, not scrubbing yet")
    }

    /// ⭐ The gate that keeps m25-o byte-identical: under ⌘ the press falls
    /// through to `.click(nil)` and releases into `.positionPlayhead`, so the
    /// modifier still PLACES the playhead rather than grabbing it.
    @Test("⚠️ the grab is gated on !toggling, so ⌘ still places rather than drags")
    func grabIsGatedOnTheChord() {
        let begin = rollBody("beginGesture")
        #expect(begin.contains("if !toggling, target == .playhead"),
                "the playhead grab must be gated on the chord — under ⌘ this press belongs to m25-o's placement arm")
        // Positive control: `toggling` IS the router's chord term, so the needle
        // above is real and not a hopeful string.
        #expect(begin.contains("let toggling = ArrangeClickIntent.intent(for: modifiers)"),
                "positive control failed — the chord term is unfindable, so the gate assertion proves nothing")
    }

    // MARK: - The drag seeks, past the slop

    @Test("advanceGesture seeks per tick through the ONE shared producer")
    func dragSeeksThroughTheSharedProducer() {
        let advance = rollBody("advanceGesture")
        #expect(advance.contains("case .playheadDrag(let scrubbing):"),
                "the drag no longer advances — the line would grab and then not move")
        #expect(advance.contains("placementLocalBeat("),
                "the drag must seek through the same producer the ⌘-click and the ruler scrub use")
        #expect(advance.contains("PianoRollPlayhead.projectBeat("),
                "the seek must resolve a PROJECT beat, which is why the arrange playhead follows for free")
        #expect(advance.contains("snapBypassed: snapBypassHeld"),
                "the drag must carry the ⌥ fine-scrub escape")
        #expect(occurrences("onSeek(", in: advance) == 1,
                "exactly ONE seek in the drag — a second would give the roll two ways to move the playhead")
    }

    /// ⭐⭐ **THE "MUST NOT JUMP" RULE, INHERITED FROM THE ARRANGE.**
    /// `ArrangePointer.scrubSlop`'s own doc: *"grabbing the playhead without
    /// moving must not jump it to a snapped beat."* On a snapping surface a
    /// no-travel press would displace the transport by up to half a grid cell.
    @Test("⚠️ a press that never travelled does not seek — the slop gate")
    func slopGateIsPresent() {
        let advance = rollBody("advanceGesture")
        #expect(advance.contains("PianoRollPlayhead.scrubSlop"),
                "the slop gate is gone — grabbing the playhead would jump it to a snapped beat")
        #expect(advance.contains("guard scrubbing || abs(translation.width) > PianoRollPlayhead.scrubSlop"),
                "the gate must be sticky (`scrubbing ||`), or a drag wandering back inside the slop stops seeking mid-gesture")
    }

    // MARK: - The release, and the thing it must not break

    /// ⭐⭐ **m25-m's CLICK-TO-DESELECT, PRESERVED IN THE STRIPE THIS ITEM CLAIMS.**
    /// The grab band lies over empty grid by construction (notes outrank the
    /// playhead), so before this item every press there was `.click(nil)` and
    /// released into `clearSelection()`. Claiming the press and then doing nothing
    /// on a no-travel release would delete click-to-deselect from an 8 pt moving
    /// stripe — m25-m's bug, which a human confirmed fixed by hand, reintroduced.
    /// MUTANT: delete the `model.clearSelection()` below and this reddens.
    @Test("⚠️ a no-travel grab still DESELECTS — m25-m must not come back in a stripe")
    func noTravelGrabStillDeselects() {
        let end = rollBody("endGesture")
        #expect(end.contains("case .playheadDrag(let scrubbing):"),
                "the release no longer handles the playhead drag")
        #expect(end.contains("if !scrubbing { model.clearSelection() }"),
                "a no-travel grab must clear the selection exactly as a click on empty grid always did")
    }

    /// Moving the playhead is not an edit. The counts here are the same ones
    /// `PianoRollPlayheadPlaceSiteTests` and `EditorSurfaceOwnershipSiteTests`
    /// guard; asserted again from this item's side because THIS is the change
    /// that would have moved them.
    @Test("⚠️ the drag is not an edit — no new commit, no second seek in the release")
    func dragIsNotAnEdit() {
        let end = rollBody("endGesture")
        // Positive control: `commit(` IS findable here (the move/resize arm), so
        // a claim about its count is a real claim.
        #expect(end.contains("commit("),
                "positive control failed — `commit(` is unfindable in `endGesture`, so the count below proves nothing")
        #expect(occurrences("commit(", in: end) == 1,
                "the playhead drag must add no `commit(` — moving the transport edits nothing and owes the undo journal nothing")
        #expect(occurrences("onSeek(", in: end) == 1,
                "the release must not seek again — the seek already happened per tick in `advanceGesture`")
    }

    /// ⚠️ **A DELIBERATE CHANGE TO m25-o's SHIPPED ⌘-CLICK, PINNED BECAUSE
    /// NOTHING ELSE SEES IT.** `placementSnapsOnce` passes whether or not the
    /// placement carries the ⌥ hatch, so without this assertion the uniformity
    /// would be an unpinned accident.
    ///
    /// ⌘⌥-click now places the playhead UNSNAPPED. The alternative — ⌥ honoured
    /// by the drag and the scrub but ignored by the click two pixels away —
    /// would rebuild, inside one feature, exactly the split the user's ruling
    /// closed between the roll and the arrange. The arrange itself applies its
    /// ⌥ bypass to its single-click seek and its scrub through ONE
    /// `pointerBeat(forX:)`, which is the shape being copied.
    @Test("⌥ reaches the ⌘-click placement too, so all three gestures obey one rule")
    func optionEscapeIsUniformAcrossAllThreePlayheadGestures() {
        let end = rollBody("endGesture")
        #expect(end.contains("snapBypassed: snapBypassHeld"),
                "the ⌘-click placement must carry the ⌥ hatch — otherwise the click snaps while the drag beside it does not")
        // ...and the ghost preview must agree, or the preview lies by up to half
        // a grid cell in exactly the case ⌥ exists for.
        let ghost = rollBody("playheadPlaceGhost")
        #expect(ghost.contains("snapBypassed: snapBypassHeld"),
                "the ghost must preview the SAME beat the ⌘⌥-click will land on")
    }

    // MARK: - The line the grab is measured against

    /// ⭐ **YOU CAN ONLY GRAB WHAT YOU CAN SEE.** The view feeds the resolver
    /// `lineX`, which is nil off-clip, so the grab band inherits honest absence
    /// rather than restating it.
    @Test("the hover resolver is fed the DRAWN line's x, so an off-clip transport is ungrabbable")
    func resolverIsFedTheDrawnLine() {
        // The window is the CALL's argument list, not a `func` body — the roll
        // has two `hoverTarget` overloads and `body(of:)` would take the wrong
        // one (see `callArgs`).
        guard let args = Self.callArgs(of: "PianoRollHover.target(",
                                       in: Self.text(Self.rollPath)) else {
            Issue.record("`PianoRollHover.target(` not found in \(Self.rollPath) — the roll no longer asks the ONE hover resolver at all")
            return
        }
        // ANTI-VACUITY: prove this really is the resolver's argument list by
        // asserting contents it has carried since m25-g.
        #expect(args.contains("selectionFrame:") && args.contains("proDensity:"),
                "positive control failed — the window does not contain the resolver's own known arguments, so the assertions below prove nothing")
        #expect(args.contains("playheadX: PianoRollPlayhead.lineX("),
                "the resolver must be fed the DRAWN line's x — a hardcoded or always-present x would offer a grab on a line the roll is not drawing")
        #expect(args.contains("positionBeats"),
                "the line's x must come from the live transport position")
    }

    /// The cursor and the gesture are the same answer, which is this surface's
    /// standing rule (`PianoRollHover`'s one-resolver argument).
    @Test("the drag holds the vertical bar for the whole gesture")
    func dragHoldsTheVerticalBarCursor() {
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(roll.contains("case .playheadDrag: DragCursor.set(.verticalBar)"),
                "the drag must hold a cursor for the whole gesture — SwiftUI suspends hover under a captured pointer, so the rest cursor cannot carry it")
    }
}
