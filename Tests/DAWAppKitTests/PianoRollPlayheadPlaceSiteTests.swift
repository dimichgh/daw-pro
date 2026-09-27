import Testing
import Foundation

/// m25-o — THE WIRING, pinned at the SOURCE.
///
/// ⚠️ **WHY A SOURCE-SITE PIN AND NOT A BEHAVIOURAL TEST.** This feature is
/// reached only by holding ⌘ and clicking with a real pointer inside a real
/// window, and m23-g1 established that nothing in this tree can produce either:
/// an unbundled staging binary does not route real key or pointer events, so no
/// `.mjs` gate can see this gesture at all. The POLICY is pinned headlessly
/// (`PianoRollGridReleaseTests`); what that cannot see is whether the VIEW still
/// calls it. A silent unwiring — the `switch` arm dropped, the seek re-pointed at
/// the store, the monitor never started — would leave every other test in this
/// repo green. This reddens instead.
///
/// ⚠️⚠️ **EVERY ASSERTION RUNS AGAINST COMMENT-STRIPPED, BRACE-MATCHED SOURCE**
/// (the `PianoRollGroupScaleSiteTests` rule): this file's own prose is full of the
/// symbols it asserts on, and `EditorSurfaceOwnershipSiteTests` once shipped a
/// `contains` that a DIFFERENT symbol satisfied as a prefix.
@Suite("m25-o — ⌘-click playhead placement is WIRED")
struct PianoRollPlayheadPlaceSiteTests {

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
    /// "renamed" and "clean" must never look the same.
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

    /// The braced block that OPENS at `marker` (which must END in `{`), by brace
    /// matching — for SwiftUI modifier closures, which are not declarations and so
    /// are invisible to `body(of:)`.
    ///
    /// ⚠️⚠️ **THIS EXISTS BECAUSE THE OBVIOUS SPELLING WAS VACUOUS, AND THE
    /// MUTANT CAUGHT IT.** The first version of `flagsMonitorTornDown` asked
    /// `body(of: "onDisappear")` — which finds `func onDisappear` / `var
    /// onDisappear`, neither of which exists — and fell back to the WHOLE FILE on
    /// nil. It therefore passed as long as `stopFlagsMonitor()` appeared anywhere
    /// at all, including in its own definition. Deleting the teardown call left
    /// the suite GREEN (mutant M10). A window that swallows the line it protects
    /// is not a test.
    private static func block(openingAt marker: String, in content: String) -> String? {
        let code = codeOnly(content)
        guard marker.hasSuffix("{"), let found = code.range(of: marker) else { return nil }
        var depth = 0
        var index = code.index(before: found.upperBound)   // the `{` itself
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(code[code.index(after: found.upperBound)..<index])
                }
            }
            index = code.index(after: index)
        }
        return nil
    }

    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"
    private static let cursorPath = "DAWApp/Components/HoverCursor.swift"

    private func rollBody(_ name: String) -> String {
        let found = Self.body(of: name, in: Self.text(Self.rollPath))
        #expect(found != nil, "`\(name)` not found in \(Self.rollPath) — renamed?")
        #expect(found?.isEmpty == false, "`\(name)` body is empty")
        return found ?? ""
    }

    private func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - The release routes through the headless resolver

    @Test("endGesture routes the click release through PianoRollGridPress, exhaustively")
    func releaseRoutesThroughResolver() {
        let end = rollBody("endGesture")
        #expect(end.contains("PianoRollGridPress.release("),
                "the grid release no longer asks the headless resolver — the four-arm table has grown a second home")
        // All five arms handled HERE. A `switch` cannot compile with one missing,
        // but it CAN compile with one folded into a `default` that silently
        // swallows the playhead arm — which is exactly how this feature would
        // disappear without a red test.
        for arm in ["case .selectOnly", "case .toggle", "case .deselect",
                    "case .positionPlayhead", "case .doNothing"] {
            #expect(end.contains(arm), "`endGesture` no longer handles `\(arm)`")
        }
        #expect(end.contains("default:") == false,
                "a `default` in this switch would swallow a future arm — the exhaustiveness IS the guard")
    }

    @Test("⚠️ the placement seeks through onSeek and NOTHING else")
    func placementUsesTheOneSeekPath() {
        let end = rollBody("endGesture")
        #expect(end.contains("onSeek("),
                "the playhead arm no longer seeks")
        #expect(occurrences("onSeek(", in: end) == 1,
                "exactly ONE seek in the grid release — a second would give the roll two ways to move the playhead")
        // The roll is deliberately store-free (the `onCommit`/`onSeek` precedent).
        // A direct store call here is the drift this pins against.
        #expect(end.contains("store.seek") == false,
                "the roll must not reach the store directly")
    }

    @Test("⚠️ placing the playhead is NOT an edit — no commit, no undo entry")
    func placementDoesNotCommit() {
        let end = rollBody("endGesture")
        // Positive control: `commit(` IS findable in this body (the move/resize
        // auto-extend arm), so a claim about WHERE it is not is a real claim.
        #expect(end.contains("commit("),
                "positive control failed — `commit(` is unfindable in `endGesture`, so the count below proves nothing")
        // Exactly one, and it belongs to the move/resize/groupScale arm.
        #expect(occurrences("commit(", in: end) == 1,
                "`endGesture` must still commit exactly once (the move/resize arm). Placing the playhead edits nothing and owes the undo journal nothing — and `EditorSurfaceOwnershipSiteTests` pins this file's total at 7.")
    }

    // MARK: - Snap, in the one place it belongs

    /// ⭐ **RESTATED BY m23-ap I5-F2.** This pinned the snap in CLIP-LOCAL space
    /// through `model.snap(`, because the roll's grid, bar emphasis and ruler all
    /// counted from the clip's first beat. They now count the SONG's bars, so the
    /// snap runs on the song's grid through the headless
    /// `PianoRollSongGrid.placementLocalBeat` (unit-tested in
    /// `PianoRollSongGridTests`); the "once, in one place, with the gesture's
    /// grid" legs are unchanged.
    @Test("the placement beat is snapped ONCE, on the SONG's grid, through the headless producer")
    func placementSnapsOnce() {
        let producer = rollBody("placementLocalBeat")
        #expect(producer.contains("PianoRollSongGrid.placementLocalBeat("),
                "snapping must go through the headless song-grid producer")
        #expect(producer.contains("effectiveSnap"),
                "the gesture's snap resolution, not a hardcoded grid")
        #expect(occurrences("PianoRollSongGrid.placementLocalBeat(", in: producer) == 1,
                "snap is a property of the GESTURE (m23-g2) — exactly once")
        #expect(producer.contains("model.snap(") == false,
                "a clip-local `model.snap(` here is the pre-I5-F2 grid coming back")
        #expect(producer.contains("meterMap: meterMap") && producer.contains("clipStartBeat: clip.startBeat"),
                "the song's grid needs the clip's start and the song's meter map")
        // ⚠️ The coordinate-space trap: `gridDrag` and `.onContinuousHover` report
        // in grid CONTENT space already. Adding the scroll offset here would put
        // the playhead a viewport-width off at any scrolled position.
        #expect(producer.contains("gridScrollX") == false,
                "grid points are already content-space — `gridScrollX` is the scrub STRIP's correction and must not appear here")

        // ⚠️⚠️ **AND THE RELEASE ITSELF MUST NOT SNAP.** `PianoRollGridReleaseTests`
        // shows the correct COMPOSITION (snap, then clamp, then offset), but it
        // cannot see a view that composes it wrongly. A second snap wrapped around
        // `projectBeat`'s result would snap AFTER the clamp, so a clip edge that
        // sits off the grid would be pushed off the clip. ⭐ Restated by m23-ap
        // I5-F2: this used to say the danger was snapping in PROJECT space at all.
        // The grid, the ruler and "BAR n" now count the song's bars, so the one
        // snap is on the song's grid (`placementLocalBeat`), and the release must
        // still add none of its own.
        let end = rollBody("endGesture")
        #expect(end.contains("model.snap(") == false,
                "the release must not snap — the snap belongs to `placementLocalBeat` (the song's grid, then the clamp), before the project offset")
        // Positive control: `model.` IS findable in `endGesture`, so the absence
        // above is a real absence and not a broken needle.
        #expect(end.contains("model."),
                "positive control failed — `model.` is unfindable in `endGesture`, so the negative above proves nothing")
    }

    @Test("the ghost preview and the seek come from the SAME producer")
    func previewAndActionAgree() {
        // A preview computed by different arithmetic than the action is a preview
        // that lies — on a snapping surface, by up to half a grid cell.
        let ghost = rollBody("playheadPlaceGhost")
        let end = rollBody("endGesture")
        #expect(ghost.contains("placementLocalBeat("),
                "the ghost line no longer derives its x from the placement producer")
        #expect(end.contains("placementLocalBeat("),
                "the seek no longer derives its beat from the placement producer")
        // And the ghost obeys the same gate the click does.
        #expect(ghost.contains("PianoRollGridPress.placesPlayhead("),
                "the ghost must appear exactly when the click would act")
        #expect(ghost.contains("activeDrag == .none"),
                "a preview during a live gesture is stale by definition")
        #expect(ghost.contains(".allowsHitTesting(false)"),
                "every overlay on this surface is hit-test inert — one that ate presses would break the context menu and the double-tap add")
        // ⚠️ NO GLOW, NOT CYAN: glow is earned by transport state and cyan IS the
        // transport in this view, so a glowing cyan preview would be
        // pixel-indistinguishable from the real playhead — i.e. it would claim the
        // transport had already moved.
        #expect(ghost.contains(".glow(") == false,
                "the hover ghost line must never glow — it would be confusable with the playhead it is only predicting")
        #expect(ghost.contains("DAWTheme.textSecondary"),
                "the hover ghost line is neutral by docs/DESIGN-LANGUAGE.md")
    }

    // MARK: - The cursor affordance and its monitor

    @Test("the cursor asks the SAME resolver the release obeys")
    func cursorAgreesWithPress() {
        let cursor = rollBody("gridCursor")
        #expect(cursor.contains("PianoRollGridPress.placesPlayhead("),
                "the cursor no longer asks the shared resolver — the affordance and the gesture can now disagree")
        #expect(cursor.contains(".verticalBar"),
                "the ⌘ affordance no longer resolves the playhead-place cursor")
    }

    @Test("⌘ is tracked by a flags monitor, because hover cannot see a key press")
    func flagsMonitorExists() {
        let start = rollBody("startFlagsMonitor")
        #expect(start.contains("NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)"),
                "the ⌘ affordance needs a flags-changed monitor: `.onContinuousHover` and the tracking area are both movement-driven and cannot see a modifier")
        // The precedent's first line, and it is not decoration: entering the grid
        // with ⌘ ALREADY down produces no `.flagsChanged` event at all, so without
        // this seed the affordance appears only after a release-and-re-press.
        #expect(start.contains("NSEvent.modifierFlags.contains(.command)"),
                "the monitor must seed from the CURRENT flags, or entering with ⌘ held shows no affordance")
        #expect(start.contains("guard flagsMonitor == nil"),
                "start must be idempotent — a doubled start orphans the first monitor behind an overwritten handle")
        // m25-x — ⇧ IS TRACKED FROM THE SAME MONITOR, and it must be both SEEDED
        // and READ. ⇧ is a toggling chord, so `PianoRollHover.target` retracts the
        // group-scale handle under it; drop this flag and the glowing bar goes
        // back to advertising a scale ⇧-click refuses. Seeding matters for the
        // identical reason ⌘'s does: entering the grid with ⇧ already down
        // produces no `.flagsChanged` event at all.
        #expect(start.contains("shiftHeld = NSEvent.modifierFlags.contains(.shift)"),
                "⇧ must be seeded from the CURRENT flags, or entering with ⇧ held leaves the group handle advertising")
        #expect(start.contains("shiftHeld = event.modifierFlags.contains(.shift)"),
                "⇧ must be read from the monitor's own event, not re-read from the global flags")
    }

    /// ⭐ **THE TOKEN IS THE CHORD, NOT A ⌘ BIT (m25-x).** The cursor comes from
    /// an `NSTrackingArea`, which re-resolves on pointer MOVEMENT and nothing
    /// else; `refresh` is the only thing that makes it re-ask with the mouse
    /// still. A `commandHeld ? 1 : 0` token cannot flip on a bare ⇧, so the
    /// cursor would stay stale over the group-scale band while the drawn bar
    /// (plain `@State`) retracted — the two affordances disagreeing with each
    /// other, which is this item's own defect surviving in the caching layer.
    @Test("the cursor's re-resolution token covers the WHOLE chord, not just ⌘")
    func refreshTokenTracksTheWholeChord() {
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(roll.contains("refresh: pointerModifiers.rawValue"),
                "the token must be derived from the same chord `gridCursor` reasons about")
        #expect(roll.contains("refresh: commandHeld ? 1 : 0") == false,
                "a ⌘-only token leaves the cursor stale on a bare ⇧")
        // POSITIVE CONTROL: `commandHeld` IS still findable in the roll (it feeds
        // `pointerModifiers` and the ghost line's short-circuit), so the negative
        // above is about the token and not about a vanished symbol.
        #expect(roll.contains("commandHeld"),
                "positive control failed — `commandHeld` is unfindable, so the negative above proves nothing")
    }

    @Test("⚠️ the monitor is torn down on BOTH exits — a local monitor that outlives its view is a leak")
    func flagsMonitorTornDown() {
        let stop = rollBody("stopFlagsMonitor")
        #expect(stop.contains("NSEvent.removeMonitor("), "the monitor is never removed")
        #expect(stop.contains("flagsMonitor = nil"), "the handle must be cleared")
        #expect(stop.contains("commandHeld = false"),
                "stopping must drop the affordance too, or the cursor sticks")
        // m25-x — the same for ⇧, and for a sharper reason: a ⇧ that stayed
        // `true` after teardown would leave the group-scale handle permanently
        // retracted, i.e. the feature silently gone rather than merely stale.
        #expect(stop.contains("shiftHeld = false"),
                "a stranded ⇧ flag would suppress the group handle forever")

        let roll = Self.codeOnly(Self.text(Self.rollPath))
        // Path 1 — the pointer leaves the grid.
        #expect(roll.contains("if overGrid { startFlagsMonitor() } else { stopFlagsMonitor() }"),
                "the monitor's lifetime must follow the hover")
        // Path 2 — the view goes away. A clip switch recreates this view
        // (`.id(clip.id)`) and hover-exit is NOT guaranteed for a view torn down
        // under the pointer, so this is the teardown that actually holds.
        guard let disappear = Self.block(openingAt: ".onDisappear {",
                                         in: Self.text(Self.rollPath)) else {
            Issue.record("`.onDisappear {` not found in \(Self.rollPath) — renamed or restructured?")
            return
        }
        // Anti-vacuity: the window must be the CLOSURE, not the file. Prove it is
        // a real window by asserting something only that closure contains.
        #expect(disappear.contains("noteSelection.clear()"),
                "positive control failed — the `.onDisappear` window does not contain its own known contents, so the assertion below proves nothing")
        #expect(disappear.contains("stopFlagsMonitor()"),
                "teardown must stop the monitor — a clip switch under the pointer would otherwise strand one per switch")
        // EXACTLY three: the definition, the hover-exit call, the teardown call.
        // Pinned exactly rather than `>=` because a `>=` pin is satisfied by the
        // definition plus ONE call, which is precisely the state a deleted
        // teardown leaves behind.
        #expect(occurrences("stopFlagsMonitor()", in: roll) == 3,
                "expected 3 occurrences of `stopFlagsMonitor()` (definition + hover exit + onDisappear)")
    }

    @Test("the roll still has exactly ONE hover reader — the m25-g pin, re-asserted here")
    func stillOneHoverReader() {
        // m25-o consumes the hover facility; it must not grow a second one. Pinned
        // in this suite as well as m25-g's because THIS is the item that would be
        // tempted (a modifier-aware cursor looks like it wants its own reader).
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(occurrences(".onContinuousHover", in: roll) == 1,
                "exactly one hover reader on this surface")
    }

    // MARK: - The cursor image itself

    @Test("the refresh token is opt-in, so every other hover surface is untouched")
    func refreshTokenIsOptIn() {
        let glue = Self.codeOnly(Self.text(Self.cursorPath))
        #expect(glue.contains("refresh: Int = 0"),
                "the re-resolution token must be defaulted — an unconditional re-apply would let overlapping tracking areas fight over the cursor")
        // Store the closure BEFORE re-applying, or the affordance answers with the
        // previous body's closure and lags exactly one modifier press.
        guard let update = Self.body(of: "updateNSView", in: Self.text(Self.cursorPath)) else {
            Issue.record("updateNSView not found in \(Self.cursorPath)")
            return
        }
        let resolveAt = update.range(of: "view.resolve = resolve")
        let reapplyAt = update.range(of: "reapplyAtPointer()")
        #expect(resolveAt != nil && reapplyAt != nil,
                "updateNSView no longer both stores the closure and re-applies")
        if let resolveAt, let reapplyAt {
            #expect(resolveAt.lowerBound < reapplyAt.lowerBound,
                    "the fresh closure must be stored BEFORE the re-apply, or the cursor lags one modifier press")
        }
    }

    @Test("⚠️ the pointer location is read LIVE on re-apply, never remembered")
    func reapplyReadsPointerLive() {
        guard let reapply = Self.body(of: "reapplyAtPointer",
                                      in: Self.text(Self.cursorPath)) else {
            Issue.record("reapplyAtPointer not found")
            return
        }
        // A cached "last local point" goes stale in exactly the situation this
        // exists for: content can scroll under a motionless pointer.
        #expect(reapply.contains("mouseLocationOutsideOfEventStream"),
                "the re-apply must read the pointer's CURRENT location")
        #expect(reapply.contains("bounds.contains("),
                "a re-apply must never force a cursor when the pointer is elsewhere")
        #expect(reapply.contains("isKeyWindow"),
                "a background window must never set the cursor")
    }
}
