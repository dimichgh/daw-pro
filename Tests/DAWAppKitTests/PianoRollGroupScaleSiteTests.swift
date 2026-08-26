import Testing
import Foundation

/// m25-g — THE WIRING, pinned at the SOURCE.
///
/// ⚠️ **WHY A SOURCE-SITE PIN AND NOT A BEHAVIOURAL TEST.** This feature is
/// reached only by hovering and then dragging with a real pointer inside a real
/// window, and m23-g1 established that nothing in this tree can produce one: an
/// unbundled staging binary does not route real pointer events, so no `.mjs`
/// gate can see the gesture at all. The POLICY is pinned headlessly
/// (`PianoRollGroupScaleTests`, `PianoRollGroupScaleModelTests`,
/// `PianoRollHoverTests`); what those cannot see is whether the VIEW still calls
/// it. A silent unwiring — the hover reader deleted, the press branch dropped,
/// the commit branch narrowed back to `.move, .resize` — would leave every other
/// test in this repo green. This reddens instead.
///
/// ⚠️⚠️ **EVERY ASSERTION RUNS AGAINST A COMMENT-STRIPPED, BRACE-MATCHED
/// FUNCTION BODY** (`PianoRollEdgeDragSiteTests`' rule, and the reason is that
/// `EditorSurfaceOwnershipSiteTests` once shipped a `contains` assertion a
/// DIFFERENT symbol satisfied as a prefix). Prose cannot satisfy a claim about
/// what code CALLS, and this file is unusually prose-heavy.
@Suite("Piano roll group scale wiring (m25-g)")
struct PianoRollGroupScaleSiteTests {

    // MARK: - Source access

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

    /// Every line with comments removed, so a body's own prose can neither
    /// satisfy nor violate an assertion about what it CALLS.
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

    /// The text BETWEEN the braces of `func <name>` — or of `var <name>` — by
    /// brace matching. nil means "not found", which every caller treats as a
    /// FAILURE: "renamed" and "clean" must never look the same.
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

    private func rollBody(_ name: String) -> String {
        let found = Self.body(of: name, in: Self.text(Self.rollPath))
        #expect(found != nil, "`\(name)` not found in \(Self.rollPath) — renamed?")
        #expect(found?.isEmpty == false, "`\(name)` body is empty")
        return found ?? ""
    }

    private func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The braced block that OPENS at `marker` (which must end in `{`), by brace
    /// matching — i.e. one `if`/`else if` branch, not "everything after it".
    ///
    /// ⚠️⚠️ **THIS EXISTS BECAUSE THE OBVIOUS VERSION SHIPPED VACUOUS AND WAS
    /// CAUGHT BY MUTATION, NOT BY REVIEW.** The first spelling of
    /// `aNoTravelHandlePressStillDeselects` took `components(separatedBy: marker)
    /// .last` — everything from the branch to the END of `endGesture` — and
    /// asserted that it contained `model.clearSelection()`. It does: the
    /// `.click(nil)` branch three lines below has always called exactly that. I
    /// deleted the line the test was written to protect and the test STILL
    /// PASSED. A neighbouring branch satisfying a claim about this one is the
    /// same defect `EditorSurfaceOwnershipSiteTests` hit with a prefix match,
    /// on a different axis.
    private func block(after marker: String, in body: String) -> String? {
        guard let open = body.range(of: marker) else { return nil }
        var depth = 1
        var index = open.upperBound
        while index < body.endIndex {
            let ch = body[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return String(body[open.upperBound..<index]) }
            }
            index = body.index(after: index)
        }
        return nil
    }

    // MARK: - The hover facility: ONE reader

    @Test("the roll has EXACTLY ONE hover reader — build ONE, not three")
    func thereIsExactlyOneHoverReader() {
        // ⭐ THE ROADMAP'S OWN INSTRUCTION, pinned: *"Shares the hover facility
        // with m25-o and m25-g — build ONE, not three."* m25-o (⌘-click empty
        // grid → playhead) and m25-o-2 (drag the playhead line) both want the
        // pointer's position on this surface. When they land they must extend
        // `PianoRollHover.target` and read THIS `hoverPoint`; a second
        // `.onContinuousHover` would mean a second precedence decision, and two
        // precedence tables that disagree is how a cursor comes to promise one
        // thing while the press does another.
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        let readers = occurrences(".onContinuousHover", in: roll)
        #expect(readers == 1, "expected exactly 1 hover reader in the roll, found \(readers)")
        // ⚠️ IT MUST BE `.local`, NOT a named space. The hover has to resolve in
        // the same coordinate space `gridDrag` reports its points in, or the
        // handle is drawn somewhere the press does not start it. A named scroll
        // space would need a `+ gridScrollX` correction the drag path does not
        // apply.
        #expect(roll.contains(".onContinuousHover { phase in"),
                "the hover reader must take the grid's LOCAL space")
        // POSITIVE CONTROL for that negative-shaped claim: the named-space
        // spelling IS used elsewhere in this app, so its absence here is a fact
        // about this reader rather than about a needle that never matches.
        let timeline = Self.text("DAWApp/Timeline/TempoLaneBand.swift")
        #expect(timeline.contains(".onContinuousHover(coordinateSpace:"))
    }

    @Test("the rest cursor and the press router share ONE resolution")
    func cursorAndPressAgree() {
        // The affordance a surface ADVERTISES and the gesture it PERFORMS must
        // be the same answer, not two implementations of the same rule. Before
        // m25-g this file spelled the Pro gate twice — once in `gridCursor`,
        // once in `beginGesture` — which is one rename away from a pointer that
        // promises a resize Simple will refuse.
        let cursor = rollBody("gridCursor")
        // ⭐ m25-o TIGHTENED THIS RATHER THAN RELAXING IT. The needle was
        // `hoverTarget(at: point)` (the one-arg overload, which hit-tests
        // internally); the cursor now hit-tests ONCE and passes the result in,
        // which is the LITERALLY IDENTICAL call `beginGesture` makes. So the
        // affordance and the press no longer merely agree by computing the same
        // thing twice — they are the same expression, and the surface pays one
        // `hitTest` per hover instead of two.
        // ⭐ m25-x WIDENED THE NEEDLE RATHER THAN LOOSENING IT: the resolution is
        // now chord-aware, and the cursor must ask with the chord the POINTER is
        // carrying (`pointerModifiers`, from the flags monitor) — the only chord
        // a hover can know. A cursor resolved with a bare `[]` here would go back
        // to promising an edge drag ⌘ has already taken away.
        // ⚠️ WHITESPACE-RUN-TOLERANT, DELIBERATELY: the call now wraps across two
        // lines, and a needle that encodes one particular wrap reddens on a
        // reformat with a message about `modifiers:` — a test that fails for a
        // reason its own text denies is a test that gets deleted rather than
        // debugged. Splitting on ANY whitespace and rejoining with single spaces
        // collapses newline, indent and space runs identically, so the assertion
        // is about the EXPRESSION and nothing else.
        let squashed = cursor.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        // POSITIVE CONTROL for the squashing itself: another known line of this
        // same body must survive it. Without this, a squash that produced
        // gibberish would look exactly like a missing needle.
        #expect(squashed.contains(
            "if PianoRollGridPress.placesPlayhead(noteID: hit?.id, modifiers: pointerModifiers) {"),
                "positive control failed — the squashed body does not contain a line known to be in it, so the needle below proves nothing")
        #expect(squashed.contains(
            "PianoRollHover.cursor(for: hoverTarget(at: point, hit: hit, modifiers: pointerModifiers))"))
        // ⚠️ AND THE GATE MUST BE GONE FROM HERE. `mode == .pro` living in this
        // body again means the second copy came back.
        #expect(!cursor.contains("mode == .pro"))
        // POSITIVE CONTROL: `mode == .pro` IS findable in this file, so the
        // negative above is about this body.
        #expect(Self.codeOnly(Self.text(Self.rollPath)).contains("mode == .pro"))
        // The resolution itself passes the density through to the ONE place that
        // applies it.
        let target = rollBody("hoverTarget")
        #expect(target.contains("model.hitTest(point)"))
    }

    @Test("the resolver is handed the live selection frame and the live density")
    func hoverTargetIsFullyFed() {
        // A resolver starved of one input answers confidently and wrongly: pass
        // `selectionFrame: nil` and the handle silently never appears; pass
        // `proDensity: true` unconditionally and Simple grows an affordance the
        // density system says it must not have.
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(roll.contains("selectionFrame: model.groupScaleFrame()"))
        #expect(roll.contains("proDensity: mode == .pro"))
        // m25-x — the CHORD is the third input, and it starves the same way: a
        // resolver handed `[]` unconditionally goes back to advertising a group
        // scale ⌘ has already taken away.
        #expect(roll.contains("modifiers: modifiers,"),
                "the resolver must be fed the chord its caller actually knows")
    }

    // MARK: - The chord reaches the resolver, from BOTH callers (m25-x)

    /// ⭐⭐ **THE CALLER-SUPPLIED-TRUTH PIN, AND IT IS AN ANTI-UNIFICATION
    /// GUARD.** `hoverTarget` is asked by two consumers that legitimately know
    /// different chords: the hover path can only know the flags monitor's state,
    /// and the press path must use the chord the gesture was actually delivered
    /// with. A future "cleanup" that pointed `beginGesture` at `pointerModifiers`
    /// would route real clicks by hover state that is stale whenever the pointer
    /// entered the surface with a modifier already down — a bug that reproduces
    /// only on the first press after entering, i.e. one that gets closed as
    /// unreproducible. This reddens instead.
    @Test("hover and the press each pass the chord THEY know, and they differ")
    func eachCallerPassesItsOwnChord() {
        let begin = rollBody("beginGesture")
        #expect(begin.contains("modifiers: modifiers"),
                "`beginGesture` must resolve with the GESTURE's chord, not the hover monitor's")
        #expect(begin.contains("pointerModifiers") == false,
                "the press path must never resolve from the flags monitor — that state is stale on the first press after entering with a modifier down")
        // POSITIVE CONTROL for that negative: `pointerModifiers` IS findable in
        // this file, so its absence from this body is a fact about the body.
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(roll.contains("pointerModifiers"),
                "positive control failed — `pointerModifiers` is unfindable in the roll, so the negative above proves nothing")
        // And the DRAWN bar reads the live monitor, or it would not retract until
        // the mouse moved.
        let bar = rollBody("visibleGroupScaleEdge")
        #expect(bar.contains("modifiers: pointerModifiers"),
                "the drawn handle must resolve with the live chord, or it lingers under ⌘ until the pointer moves")
    }

    /// ⭐ **THE GAP THIS TEST EXISTS TO CLOSE, FOUND BY MUTATING m25-x's OWN
    /// WORK.** Every other pin here is satisfied by a `pointerModifiers` that
    /// composes only ⌘: the monitor still seeds `shiftHeld`, the bar still asks
    /// with `pointerModifiers`, the resolver still applies the intent — and the
    /// ⇧ half of the fix silently does nothing, because the one value that
    /// carries ⇧ to the resolver dropped it. The headless tests cannot see this:
    /// they pass chords directly.
    @Test("⚠️ the hover chord composes BOTH tracked flags, or the ⇧ half is dead")
    func pointerChordCarriesBothFlags() {
        let chord = rollBody("pointerModifiers")
        #expect(chord.contains("commandHeld"), "⌘ must reach the resolver (m25-o)")
        #expect(chord.contains(".command"), "⌘ must be inserted as a chord member")
        #expect(chord.contains("shiftHeld"),
                "⇧ must reach the resolver, or the group handle keeps advertising under ⇧ (m25-x)")
        #expect(chord.contains(".shift"), "⇧ must be inserted as a chord member")
    }

    /// ⭐ **ONE GATE, NOT TWO.** The resolver owns "a toggling chord retracts the
    /// group handle" (`PianoRollHoverTests.theTogglingChordRetractsTheHandle`).
    /// A `!toggling` re-spelled on the branch that consumes it is a second source
    /// of truth for one rule — and a second source of truth is exactly what let
    /// the bar advertise a scale the branch would refuse in the first place.
    @Test("⚠️ the group-scale branch carries NO second `!toggling` gate")
    func theGroupScaleBranchHasNoSecondGate() {
        let begin = rollBody("beginGesture")
        #expect(begin.contains("} else if case .groupScaleHandle(let edge) = target {"),
                "the group-scale branch must consume the resolver's answer unguarded — the resolver already applied the chord")
        #expect(begin.contains("!toggling, case .groupScaleHandle") == false,
                "a second chord gate on this branch is a second source of truth for one rule")
        // POSITIVE CONTROL: `!toggling` IS still findable in this body — it is
        // load-bearing on the `.playhead` and `.note` arms, which the resolver
        // deliberately does NOT gate — so the absence above is about this branch
        // and not about a needle that can never match.
        #expect(begin.contains("!toggling, target == .playhead"),
                "positive control failed — the playhead arm's gate is gone too, which is a different (and real) regression")
    }

    // MARK: - The gesture

    @Test("a press on the handle begins a group scale and changes NO selection")
    func pressRoutesToTheGroupScale() {
        let begin = rollBody("beginGesture")
        #expect(begin.contains("case .groupScaleHandle(let edge) = target"))
        #expect(begin.contains("model.beginGroupScale(edge: edge)"))
        #expect(begin.contains("activeDrag = .groupScale(edge)"))
        // ⚠️ THE PRESS MUST NOT RE-SELECT. Every other branch here calls
        // `selectOnly` when the pressed note was not selected; the handle has no
        // note under it, and a quiet re-selection is the one way this gesture
        // could lose the notes it is about to scale. Pinned as a COUNT because
        // `selectOnly` legitimately appears in the note branches.
        #expect(occurrences("model.selectOnly(", in: begin) == 2,
                "the note branches keep their selectOnly; the handle branch must not gain one")
        // ANTI-VACUITY: this really is the press funnel.
        #expect(begin.contains("model.hitTest(start)"))
        #expect(begin.contains("onEngage()"))
    }

    @Test("the per-tick handler hands the pointer's beat straight to the model")
    func perTickCallIsUnsnapped() {
        let advance = rollBody("advanceGesture")
        // ⭐ THE m23-ek-2 LAW AT THE CALL SITE. The view must pass the RAW beat
        // and let `scaleSelection` perform the gesture's ONE snap; a view that
        // pre-snapped here would be snapping a different quantity than the model
        // clamps, and the two would disagree at the walls.
        #expect(advance.contains(
            "model.scaleSelection(toBeat: model.beat(forX: location.x), resolution: effectiveSnap)"))
        // NEGATIVE + CONTROL: the view must not snap on the way in.
        #expect(!advance.contains("model.scaleSelection(toBeat: model.snap("))
        #expect(Self.codeOnly(Self.text(Self.rollPath)).contains("model.snap("))
    }

    @Test("the release commits through the EXISTING funnel and may grow the clip")
    func releaseCommitsOnce() {
        let end = rollBody("endGesture")
        #expect(end.contains("case .move, .resize, .groupScale:"),
                "a group scale must commit like the other content drags")
        // ⚠️ STILL EXACTLY ONE `commit(` IN THIS FUNCTION.
        // `EditorSurfaceOwnershipSiteTests` pins the file-wide count as its R6
        // false-engage guard, and m25-g deliberately joined the existing branch
        // rather than adding a call.
        #expect(occurrences("commit(", in: end) == 1)
        let ids = rollBody("autoExtendIDs")
        #expect(ids.contains("case .groupScale: return model.scaleIDsStartingAudible()"),
                "only notes audible at press may grow the clip (m25-a's rule, third door)")
        // ⚠️ NOT the whole selection — that is the m18-f latent-note surprise
        // arriving through a new door.
        #expect(!ids.contains("case .groupScale: return model.selection"))
    }

    @Test("a handle press that never travelled still deselects, like the empty grid it is on")
    func aNoTravelHandlePressStillDeselects() {
        // ⭐⭐ THE ONE SHIPPED BEHAVIOUR m25-g DOES CHANGE, named here because
        // `beginGesture`'s own doc demands it: the handle band lies over EMPTY
        // GRID, so before this feature every press there released into
        // `clearSelection()`. Claiming the press for a scale and then doing
        // nothing on a no-travel release would delete click-to-deselect from a
        // 12-pt strip the full height of the selection — m25-m's bug, which a
        // human confirmed fixed days ago, reintroduced in a stripe.
        let end = rollBody("endGesture")
        let marker = "} else if case .groupScale = outgoing {"
        #expect(end.contains(marker))
        // ⚠️ THE BRANCH ITSELF, brace-matched — not "everything after it". See
        // `block(after:in:)`: the loose version passed with the line deleted,
        // because the `.click(nil)` branch below also clears the selection.
        let branch = block(after: marker, in: end)
        #expect(branch != nil, "could not brace-match the no-travel branch")
        let body = branch ?? ""
        // BOTH halves. Restoring without clearing leaves the deselect broken;
        // clearing without restoring leaves an uncommitted deformation on
        // screen with no selection left to fix it with.
        #expect(body.contains("model.cancelGroupScale()"),
                "a sub-slop scale has already deformed the draft; put it back")
        #expect(body.contains("model.clearSelection()"),
                "the band is empty grid, and a click on empty grid deselects")
        // ANTI-VACUITY, both directions: the extracted branch is SHORT and does
        // NOT contain the sibling branches' calls — proof the extractor isolated
        // one branch rather than returning the whole function (which would make
        // the two assertions above satisfiable by `.click`'s own clear).
        #expect(!body.contains("model.selectOnly("))
        #expect(!body.contains("commit("))
        #expect(body.count < 200, "the extracted branch is \(body.count) chars — too big to be one branch")
        // ⚠️ AND STILL EXACTLY ONE `commit(` in this function — the deselect
        // branch must not become a second one.
        #expect(occurrences("commit(", in: end) == 1)
    }

    // MARK: - The handle overlay

    @Test("the handle is drawn from the live gesture as well as from hover")
    func theHandleSurvivesItsOwnGrab() {
        // SwiftUI suspends hover updates under a captured pointer, so a
        // hover-only rule would make the handle vanish the instant the user
        // grabbed it — the affordance disappearing exactly when it is doing
        // something.
        let visible = rollBody("visibleGroupScaleEdge")
        #expect(visible.contains("case .groupScale(let edge) = activeDrag"))
        #expect(visible.contains("hoverPoint"))
    }

    @Test("the handle overlay eats no presses")
    func theHandleIsHitTestInert() {
        // m23-cf MEASURED that this surface's hit region is load-bearing: the
        // grid's `.contentShape(Rectangle())` is the only reason the context
        // menu appears at all. An overlay that took hits would break the context
        // menu and the double-tap add over its own band — and the press it
        // advertises is routed by `beginGesture`, not by itself.
        let handle = rollBody("groupScaleHandleView")
        #expect(handle.contains(".allowsHitTesting(false)"))
        #expect(handle.contains("PianoRollGroupScale.handleRect(frame: frame, edge: edge)"))
        // The bar is drawn in the note's own accent (cyan, or violet for AI
        // material) — docs/DESIGN-LANGUAGE.md's "one meaning, one look".
        #expect(handle.contains("noteColor"))
        // NEGATIVE + CONTROL: no stock gray anywhere in this affordance.
        #expect(!handle.contains("Color.gray"))
        #expect(handle.contains(".glow("))
    }
}
