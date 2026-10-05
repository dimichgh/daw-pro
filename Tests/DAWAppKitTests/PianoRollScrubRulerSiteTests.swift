import Testing
import Foundation

/// m25-f-5 — THE RULER'S WIRING, pinned at the SOURCE.
///
/// ⚠️ **WHY A SOURCE-SITE PIN.** This item is a pure affordance change: the scrub
/// already worked and was invisible. Its whole value is pixels, and m23-g1
/// established that an unbundled staging binary routes no real pointer or key
/// events, so no `.mjs` gate can drive the strip. The GEOMETRY is pinned
/// headlessly (`PianoRollScrubRulerTests`); what that cannot see is whether the
/// view still DRAWS it. A silent unwiring — someone restores `Color.clear`, or
/// drops the handle, or hands the band a project beat where it wants a clip-local
/// axis — would leave every other test in this repo green. This reddens instead.
///
/// ⚠️⚠️ Every assertion runs against a comment-stripped, brace-matched
/// declaration body (`PianoRollEdgeDragSiteTests`' rule and its reason: prose must
/// not be able to satisfy a claim about what code CALLS), and every negative is
/// paired with a positive control proving the needle is findable at all.
@Suite("Piano roll scrub ruler wiring (m25-f-5)")
struct PianoRollScrubRulerSiteTests {

    // MARK: - Source access (the `PianoRollEdgeDragSiteTests` helpers)

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
    private static let bandPath = "DAWApp/Components/PianoRollScrubRulerBand.swift"

    private func declBody(_ name: String, in path: String) -> String {
        declBody(name, source: Self.text(path), label: path)
    }

    /// The same extraction against text already in hand — used to scope an
    /// assertion to ONE type inside a file that holds two.
    private func declBody(_ name: String, source: String, label: String) -> String {
        let found = Self.body(of: name, in: source)
        #expect(found != nil, "`\(name)` not found in \(label) — renamed?")
        #expect(found?.isEmpty == false, "`\(name)` body is empty")
        return found ?? ""
    }

    /// The `RulerCanvas` half of the band file — the type whose inputs must stay
    /// transport-stable.
    ///
    /// ⭐ **The `#if DEBUG` cut is not tidiness.** The first cut of this helper
    /// took everything after the declaration and swept the `#Preview` block in
    /// with it — and the previews legitimately pass `positionBeats:`, so the
    /// "the Canvas never sees the transport" assertion reddened against a preview
    /// rather than against the Canvas. A region extractor that runs past its
    /// type's end asserts something other than what it claims.
    private func rulerCanvasSource() -> String {
        let file = Self.text(Self.bandPath)
        let parts = file.components(separatedBy: "private struct RulerCanvas")
        #expect(parts.count == 2, "`RulerCanvas` declaration not found exactly once")
        let tail = parts.last ?? ""
        guard let previewMarker = tail.range(of: "#if DEBUG") else {
            #expect(Bool(false), "`#if DEBUG` preview fence not found — region would run past the type")
            return tail
        }
        return String(tail[..<previewMarker.lowerBound])
    }

    // MARK: - The strip is no longer blank

    @Test("the scrub strip draws the ruler band")
    func stripDrawsTheBand() {
        let strip = declBody("scrubStrip", in: Self.rollPath)
        #expect(strip.contains("PianoRollScrubRulerBand("),
                "the scrub strip no longer draws the ruler — is it back to Color.clear?")
        // ANTI-VACUITY: this really is the strip, not an empty string that
        // trivially contains nothing.
        #expect(strip.contains("hoverCursor(.resizeLeftRight)"))
        #expect(strip.contains("Self.keyboardWidth"))
    }

    /// ⚠️ **THE RULER IS A BACKGROUND, NOT AN OVERLAY.** A ruler drawn OVER the
    /// hit area would be a decoration that eats the drag it advertises — the
    /// exact failure the empty-lane hint's `.allowsHitTesting(false)` clause
    /// exists to prevent, one surface over.
    @Test("the band sits BEHIND the gesture surface, never over it")
    func bandDoesNotEatTheGesture() {
        let strip = declBody("scrubStrip", in: Self.rollPath)
        #expect(strip.contains(".background {"),
                "the ruler must be a background of the hit area")
        // Positive control: `.overlay {` IS findable elsewhere in this file, so
        // its absence here is a real absence and not a broken needle.
        let whole = Self.codeOnly(Self.text(Self.rollPath))
        #expect(whole.contains(".overlay {") || whole.contains(".overlay(alignment:"),
                "positive control failed — the overlay needle is unfindable, so the negative below proves nothing")
        #expect(strip.contains(".overlay(") == false,
                "the ruler must not be layered over the gesture surface")
    }

    /// The scrub's ONE side effect, and the mapping it seeks through.
    ///
    /// ⚠️⚠️ **RESTATED, NOT DELETED — THE PREMISE CHANGED BY USER RULING ON
    /// 2026-08-13 (m25-o-2).** This test was written for m25-f-5, which promised
    /// *"the LOOK, not the BEHAVIOUR"*, and it pinned `scrubProjectBeat` **by
    /// name** to hold that promise. The user has since ruled that one snap model
    /// governs playhead positioning on both surfaces — *"we have two modes snap
    /// on and off… when I move playhead in track over the clip it would snap it
    /// to the position of the grid when snap is on, and anywhere in clip when it
    /// is [off]. When we implement playhead positioning in node editor, it should
    /// follow the same rules"* — so the roll's scrub now SNAPS, and
    /// `scrubProjectBeat` (which cannot snap) is deliberately no longer its
    /// mapping.
    ///
    /// **What the guard was actually protecting is unchanged and still asserted
    /// here**: exactly ONE seek, through `onSeek`, with the strip's scroll
    /// correction intact. Only the named mapping moved, and it moved to the ONE
    /// producer the ⌘-click and the line drag already share — which is a stronger
    /// version of this test's original "no second seek path" intent, not a
    /// weakening of it. (Precedent for restating rather than deleting a guard
    /// whose premise a ruling changed: `activeTrackDoesNotRedirectAnInPlacePaste`,
    /// restated in m25-l-3.)
    @Test("the gesture still routes through onSeek exactly once, now on the shared snapped producer")
    func gestureUntouched() {
        let drag = declBody("scrubDrag", in: Self.rollPath)
        // UNCHANGED ASSERTIONS — the guard's real content.
        #expect(drag.components(separatedBy: "onSeek(").count - 1 == 1,
                "the scrub must have exactly ONE seek call")
        #expect(drag.contains("gridScrollX"), "the strip still recovers the content beat")
        // CHANGED BY RULING — the mapping is now the shared, snapping producer.
        #expect(drag.contains("placementLocalBeat("),
                "the scrub must seek through the ONE placement producer the ⌘-click and the line drag use")
        #expect(drag.contains("PianoRollPlayhead.projectBeat("),
                "the clip-local → project hand-off is still `PianoRollPlayhead`'s")
        // ⚠️ AND THE OLD FREE MAPPING MUST STAY OUT: re-pointing this gesture at
        // `scrubProjectBeat` would silently re-revert the user's ruling, which is
        // exactly how a superseded default comes back.
        #expect(drag.contains("scrubProjectBeat(") == false,
                "the scrub must not go back to the unsnapped mapping — that is the ruling this item implements")
        // POSITIVE CONTROL for that negative: the needle IS findable in the
        // sources, so its absence from this body is a real absence.
        #expect(Self.codeOnly(Self.text("DAWAppKit/PianoRollPlayhead.swift"))
                    .contains("scrubProjectBeat("),
                "positive control failed — the `scrubProjectBeat(` needle is unfindable, so the negative above proves nothing")
    }

    /// ⭐ The snap itself, at the gesture. The strip scrubbed FREE for four
    /// milestones; this is the assertion that the ruling actually reached the
    /// drag rather than only the doc comments.
    @Test("m25-o-2 — the scrub SNAPS, with ⌥ as the arrange's fine escape")
    func scrubSnapsWithOptionEscape() {
        let drag = declBody("scrubDrag", in: Self.rollPath)
        #expect(drag.contains("snapBypassed: snapBypassHeld"),
                "the scrub must carry the ⌥ escape — snapping a CONTINUOUS drag without it ships a scrub strictly coarser than the arrange's")
        // The producer is where the snap lives. ⭐ RESTATED BY m23-ap I5-F2: it
        // used to snap in clip-local space through `model.snap(`; it now hands the
        // pointer's beat, the clip's start, the song's meter map and the EFFECTIVE
        // grid to the headless `PianoRollSongGrid.placementLocalBeat`, which snaps
        // on the SONG's grid (through `SnapResolution.snapped`, the one home of
        // that arithmetic) and clamps to the clip.
        let producer = declBody("placementLocalBeat", in: Self.rollPath)
        #expect(producer.contains("PianoRollSongGrid.placementLocalBeat("),
                "the shared producer must snap through the headless song-grid producer")
        #expect(producer.contains("model.beat(forX: x)"), "the pointer's clip-local beat")
        #expect(producer.contains("clipStartBeat: clip.startBeat"), "the song phase needs the clip's start")
        #expect(producer.contains("meterMap: meterMap"), "the Bar snap needs the song's meter map")
        #expect(producer.contains("snapBypassed: snapBypassed"),
                "⌥ must reach the producer, which bypasses the snap rather than choosing a different grid")
        let headless = Self.codeOnly(Self.text("DAWAppKit/PianoRollSongGrid.swift"))
        #expect(headless.contains("let local = snapBypassed") && headless.contains("? raw"),
                "⌥ must bypass the snap rather than choosing a different grid")
        // And ⌥ is read live, the way the arrange reads it.
        let hatch = declBody("snapBypassHeld", in: Self.rollPath)
        #expect(hatch.contains("NSEvent.modifierFlags.contains(.option)"),
                "the fine-scrub hatch is ⌥, read live — `TimelineLanesView.pointerBeat(forX:)`'s own spelling")
    }

    // MARK: - m23-ap I5-F2: the roll reads the SONG's bars

    /// Site 1 of I5-F2's four: the strip hands the band the song's meter map, so
    /// the band draws `PitchEditorSongRuler`'s song-numbered canvas instead of
    /// the clip-local one. This is the leg a clip-local revert of the ruler
    /// reddens: the band's numbering is chosen by this one argument, and no
    /// headless function sits between the two.
    @Test("I5-F2 site 1 — the scrub strip hands the band the song's meter map, so the ruler numbers the SONG's bars")
    func stripNumbersTheSongsBars() {
        let strip = declBody("scrubStrip", in: Self.rollPath)
        #expect(strip.contains("songMeter: meterMap"),
                "the roll's ruler is back to clip-local numbering — it would name bars the grid, the header and the transport do not")
        // ANTI-VACUITY: this really is the strip's band call.
        #expect(strip.contains("PianoRollScrubRulerBand("))
        // The meter map is the store's ONE map, handed in by ContentView and
        // never defaulted by the roll.
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(roll.contains("var meterMap: MeterMap\n") && !roll.contains("meterMap: MeterMap ="),
                "the roll's meter map is defaulted — a new call site would get 4/4 with the compiler silent")
        #expect(Self.codeOnly(Self.text("DAWApp/ContentView.swift")).contains("meterMap: store.transport.meterMap,"))
    }

    /// Site 2's wiring: the note grid is handed the clip's start and the song's
    /// meter map (its lines come from `PianoRollSongGrid.forEachLine`), and is
    /// mounted `.equatable()` — the map holds an array rebuilt on every
    /// `transport.meterMap` read, so without its own `==` a transport tick could
    /// redraw the whole grid, notes included.
    @Test("I5-F2 site 2 — the note grid draws the song's lines and stays tick-stable (.equatable())")
    func gridDrawsTheSongsLines() {
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(roll.contains("PianoRollGrid(model: model, clipStartBeat: clip.startBeat, meterMap: meterMap,"),
                "the grid lost the song phase")
        guard let mount = roll.range(of: "PianoRollGrid(model: model,") else {
            Issue.record("the grid mount not found")
            return
        }
        let after = String(roll[mount.upperBound...].prefix(260))
        #expect(after.contains(".equatable()"), "the grid would redraw on every transport tick")
        let lines = declBody("drawGridLines", in: Self.rollPath)
        #expect(lines.contains("PianoRollSongGrid.forEachLine("), "the grid forked its own line arithmetic")
        #expect(lines.contains("s.clipStartBeat") && lines.contains("s.meterMap"))
        #expect(lines.contains("beatsPerBar") == false,
                "a `beatsPerBar` scalar in the painter is the clip-local bar predicate coming back")
        #expect(roll.contains("beatsPerBar"), "positive control — the needle is findable in this file")
    }

    // MARK: - m23-ap I5-F3: every UI snap in the roll on the song's grid

    /// The model's snaps read `songGrid`; `State` keeps the FIRST model it is
    /// handed, so the context must be written at init (the first gesture) AND on
    /// change (a clip moved or a meter changed while the editor is open). The
    /// controller lane gets the same context, and its snap is the one function.
    @Test("I5-F3 — the roll hands its clip's song-grid context to the model (at init AND on change) and to the controller lane, whose snap is the roll's one snap")
    func everySnapGetsTheSongGrid() {
        let roll = Self.codeOnly(Self.text(Self.rollPath))
        #expect(roll.contains("rollModel.songGrid = PianoRollSongGrid.Context(clipStartBeat: clip.startBeat, meterMap: meterMap)"),
                "the first gesture would snap on the clip-local grid")
        #expect(roll.contains("_model = State(initialValue: rollModel)"))
        #expect(roll.contains(".onChange(of: songGridContext, initial: true)") && roll.contains("model.songGrid = context"),
                "a clip moved while the editor is open would keep snapping on its old phase")
        #expect(roll.contains("songGrid: songGridContext,"), "the controller lane snaps on the clip-local grid")
        let strip = declBody("snapped", in: "DAWApp/PianoRoll/ControllerLaneStrip.swift")
        #expect(strip.contains("PianoRollSongGrid.snapLocalBeat("), "the controller lane forked its own grid arithmetic")
        #expect(strip.contains(".rounded()") == false, "a second copy of the rounding is back in the controller lane")
        let model = Self.codeOnly(Self.text("DAWAppKit/PianoRollModel.swift"))
        #expect(model.contains("PianoRollSongGrid.snapLocalBeat(beat, context: songGrid, resolution: resolution)"),
                "the model's snap left the song grid")
        #expect(model.contains("direction: .upward"), "the paste anchor's snap-up left the song grid")
    }

    /// The − button's enabled state, tooltip and pressed notice are ONE string's
    /// presence and text (`PianoRollBarOps.deleteRefusal`) — never a separate
    /// boolean that could enable a button whose notice says it cannot act.
    @Test("I5-F3 — the − button draws the one refusal: enabled, tooltip and notice from PianoRollBarOps.deleteRefusal")
    func deleteButtonDrawsTheOneRefusal() {
        let reason = declBody("deleteBarBlockedReason", in: Self.rollPath)
        #expect(reason.contains("PianoRollBarOps.deleteRefusal("))
        let cluster = declBody("barOpsCluster", in: Self.rollPath)
        #expect(cluster.contains("let refusal = deleteBarBlockedReason"))
        #expect(cluster.contains("enabled: refusal == nil"))
        #expect(cluster.contains("flashBarOpsNotice(refusal)"))
        #expect(cluster.contains("help: refusal"))
        #expect(Self.codeOnly(Self.text(Self.rollPath)).contains("only one bar long") == false,
                "the old one-bar words are back")
    }

    // MARK: - The band's own wiring

    /// The band's pixel axis is CLIP-LOCAL. It is handed `clipStartBeat` for one
    /// purpose only — bridging the PROJECT-space `positionBeats` for the handle —
    /// and the tick/label call must never see it, or the numbers stop naming the
    /// lines under them.
    ///
    /// ⚠️ m23-ap I5-F2: this now pins only the band's `songMeter == nil` path
    /// (`RulerCanvas`, which the previews draw). Both editors pass a song meter,
    /// and the song canvas takes `clipStartBeat` on purpose: its numbers are the
    /// song's, placed on the same clip-local axis (`gridDrawsTheSongsLines` and
    /// `PianoRollSongGridTests` pin that the grid under them agrees).
    @Test("⚠️ ticks are computed WITHOUT clipStartBeat — the axis stays clip-local")
    func ticksAreClipLocal() {
        let canvas = declBody("body", source: rulerCanvasSource(), label: "RulerCanvas")
        #expect(canvas.contains("PianoRollScrubRuler.ticks("),
                "the ruler canvas no longer builds its ticks")
        #expect(canvas.contains("clipStartBeat") == false,
                "the tick canvas must not see clipStartBeat — its axis is clip-local")
        // Positive control: `clipStartBeat` IS findable in the band file, so its
        // absence from the canvas is a real absence.
        #expect(Self.codeOnly(Self.text(Self.bandPath)).contains("clipStartBeat"),
                "positive control failed — needle unfindable")
    }

    /// The handle exists exactly when the playhead line does. Pinned because the
    /// alternative — clamping it to a band edge so it is "always visible" — is
    /// superficially attractive and is the parked-playhead lie m10-e/m23-c1 forbid.
    @Test("the handle is gated on the shared playhead predicate, not a local one")
    func handleGatedOnTheSharedPredicate() {
        let handle = declBody("handle", in: Self.bandPath)
        #expect(handle.contains("PianoRollScrubRuler.handleLeadingX("))
        #expect(handle.contains("if let"), "the handle must be conditional on that value")
        #expect(handle.contains("clamp") == false && handle.contains("max(") == false,
                "a clamped handle is the parked-playhead lie in miniature")
    }

    /// "Offset a view, never a per-frame Canvas redraw" — the arrange playhead's
    /// rule. If the handle were drawn into `RulerCanvas`, every transport tick
    /// would re-run the draw closure AND `PianoRollScrubRuler.ticks`' allocation.
    @Test("the handle is an offset view, never drawn into the ruler Canvas")
    func handleIsNotInTheCanvas() {
        let canvasPart = Self.codeOnly(rulerCanvasSource())
        #expect(canvasPart.contains("positionBeats") == false,
                "the ruler Canvas must not see the transport — it would redraw per tick")
        #expect(canvasPart.contains("Canvas {"), "positive control — this IS the canvas")
        let handle = declBody("handle", in: Self.bandPath)
        #expect(handle.contains(".offset("))
        #expect(handle.contains("Canvas") == false)
    }

    /// ⚠️⚠️ **THE BAND MUST NOT BE SIZED BY ITS CONTENT-SPACE CHILDREN.** This is
    /// the one that shipped broken twice and was caught only by pixels.
    ///
    /// The children are laid out at `contentWidth`, which at any real zoom is
    /// wider than the viewport. A `ZStack` sizes to its widest child, so the band
    /// became content-wide, `.clipped()` clipped nothing, and `.background`
    /// centred the overflow — painting the ruler across the keyboard gutter and,
    /// far worse, sliding content x 0 off the grid's x 0 so **every number was
    /// offset from the line it names**. `.frame(maxWidth: .infinity)` did not
    /// clamp it either. Only `.overlay`, which never changes the size of the view
    /// it decorates, does — with `.topLeading` putting an oversized child's
    /// leading edge on the band's leading edge.
    ///
    /// Pinned at the source because no headless test can see a layout: the
    /// geometry tests below were green through both broken builds.
    @Test("the band carries its scrolling children as topLeading OVERLAYS, never a ZStack")
    func bandIsNotSizedByItsContent() {
        let body = declBody("body", source: Self.text(Self.bandPath), label: Self.bandPath)
        #expect(body.contains("ZStack") == false,
                "a ZStack sizes to its widest child — the band would take the CONTENT width")
        #expect(body.contains(".frame(maxWidth:") == false,
                "`.frame(maxWidth:)` does not clamp an oversized child — measured, m25-f-5")
        #expect(body.components(separatedBy: ".overlay(alignment: .topLeading)").count - 1 == 3,
                "the ruler canvas, the leading-edge cover (m23-ap I5-F3) and the handle must be topLeading overlays")
        #expect(body.contains(".clipped()"))
        // ANTI-VACUITY: this really is the band's body.
        #expect(body.contains("RulerCanvas("))
        #expect(body.contains("handle"))
        // Positive control: `ZStack` IS findable in this file's prose, so the
        // negative above is a claim about CODE and not about the needle.
        #expect(Self.text(Self.bandPath).contains("ZStack"),
                "positive control failed — the ZStack needle is unfindable")
    }

    /// ⛔ **THE MAIN-THREAD FREEZE (WF, 2026-09-25).** Without `.geometryGroup()`
    /// on the scrolled strip, SwiftUI flattened the whole `.clipped()` band into
    /// ONE RenderBox layer that re-rasterized on EVERY Core Animation commit. With
    /// a second commit source (a pending render's shimmer) that was 180–240
    /// re-draws a second. The main thread then waited in
    /// `RB::SurfacePool::wait_image_queue` for seconds: 24 s once, with a `WEDGED`
    /// breadcrumb. The runtime gate is `scripts/gates/wedge-render-pending.mjs`,
    /// which needs a DRAWN window. This pin is the half that runs with the
    /// display off: the group must sit BETWEEN the content-width frame and the
    /// scroll offset, so the offset moves a layer instead of redrawing one.
    @Test("the scrolled strip is its own layer — .geometryGroup() before the scroll offset")
    func scrolledStripIsAGeometryGroup() {
        let scrolling = declBody("scrolling", in: Self.bandPath)
        let group = scrolling.range(of: ".geometryGroup()")
        let offset = scrolling.range(of: ".offset(x: -scrollX)")
        let frame = scrolling.range(of: ".frame(width: max(contentWidth, 1)")
        // ANTI-VACUITY: this is the helper that lays out and slides the strip.
        #expect(offset != nil, "positive control — `scrolling` must still apply the scroll offset")
        #expect(frame != nil, "positive control — `scrolling` must still size the strip to the content")
        #expect(group != nil,
                "`.geometryGroup()` is gone from `scrolling` — the band re-rasterizes on every commit again")
        if let group, let offset, let frame {
            #expect(frame.upperBound <= group.lowerBound && group.upperBound <= offset.lowerBound,
                    "the group must wrap the content-width strip and sit INSIDE the scroll offset")
        }
    }

    /// m23-ap I5-F3 addendum — THE HONEST LEADING EDGE. A label hangs right of
    /// its tick, so the slid strip can leave a label's TAIL at the band's left
    /// edge ("2.3" clipped to a lone "3"). The cover that hides such orphans must
    /// be a VIEWPORT-space overlay (never inside `scrolling`, which would slide
    /// it away with the strip), its own layer (`.geometryGroup()`, WF's freeze
    /// rule), tick-stable (`.equatable()`, no `positionBeats`), and UNDER the
    /// handle so the transport's cap is never covered.
    @Test("I5-F3 — the leading-edge cover is a viewport-space overlay between the strip and the handle: its own layer, tick-stable")
    func leadingEdgeCoverIsMounted() {
        let body = declBody("body", source: Self.text(Self.bandPath), label: Self.bandPath)
        let strip = body.range(of: "SongRulerCanvas(")
        let cover = body.range(of: "RulerLeadingEdge(")
        let handle = body.range(of: "scrolling { handle }")
        #expect(strip != nil && cover != nil && handle != nil,
                "positive control — the band still mounts the strip, the cover and the handle")
        if let strip, let cover, let handle {
            #expect(strip.upperBound <= cover.lowerBound && cover.upperBound <= handle.lowerBound,
                    "the cover sits over the strip and under the handle")
            let mount = String(body[cover.lowerBound..<handle.lowerBound])
            #expect(mount.contains("scrollX: scrollX"), "the cover is placed by the live scroll")
            #expect(mount.contains(".equatable()"), "tick-stable: a transport tick must leave it equal")
            #expect(mount.contains(".geometryGroup()"), "its own layer — never flattened into the band's")
            #expect(mount.contains("scrolling") == false, "viewport space — never slid with the strip")
            #expect(mount.contains("positionBeats") == false, "the cover must not see the transport")
        }
        // The cover's producer is the headless one the edge tests sweep.
        let source = Self.codeOnly(rulerCanvasSource())
        #expect(source.contains("PianoRollScrubRuler.leadingEdgeCover("),
                "the cover must draw what `leadingEdgeCover` returns")
        #expect(source.contains("private struct RulerLeadingEdge: View, Equatable"))
    }

    // MARK: - No wire growth

    /// The whole treatment is view chrome. It must add no control command and no
    /// MCP tool (the m10-c/sp-b pure-view rule, which the m10-e scrub itself and
    /// the m10-g loop ruler both follow).
    @Test("the ruler adds no wire or MCP surface")
    func noWireSurface() {
        let band = Self.text(Self.bandPath)
        let ruler = Self.text("DAWAppKit/PianoRollScrubRuler.swift")
        for (name, source) in [("band", band), ("ruler", ruler)] {
            #expect(source.isEmpty == false, "\(name) source unreadable")
            #expect(Self.codeOnly(source).contains("allCommands") == false)
            #expect(Self.codeOnly(source).contains("DAWControl") == false)
        }
    }
}
