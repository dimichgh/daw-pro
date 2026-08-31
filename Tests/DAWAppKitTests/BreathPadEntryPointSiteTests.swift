import Foundation
import Testing

/// m28-p7 — the SOURCE-SHAPE half of the breath pad: is it REACHABLE, and is it
/// BLOCKING?
///
/// **WHY THIS FILE EXISTS, AND WHY IT WAS ADDED LAST.** The render probe
/// (`scripts/gates/_m28p7-breath-pad-probe.mjs`) drives the pad through
/// `debug.breathPad`, which calls `openBreathPad(clipID:)` **directly**. Every
/// one of its five PNGs therefore proves the *panel* and proves **nothing at all
/// about the route a human takes to it**. The two human routes — a BREATH chip
/// in the piano-roll header and a "Breath Pad…" entry in the arrange clip menu —
/// were never in frame. A chip that is defined but never mounted compiles,
/// ships, and is unclickable; that is the precise defect `m25-c` was filed for,
/// and the probe as written could not see it.
///
/// The chip half now *is* rendered (the probe opens the roll at two window
/// widths and captures the header). The menu half cannot be: an `NSMenu` is a
/// separate window and `debug.captureUI`'s `cacheDisplay` sees only the main
/// one. So for the menu this file is the ONLY instrument there is.
///
/// ⚠️ **A SHAPE PIN, NOT A BEHAVIOURAL MEASUREMENT** — the `HumanizePanelSiteTests`
/// caveat applies verbatim. `DAWApp` is an `executableTarget` with no test
/// target; this reads its source. Comments are stripped so prose *about* a
/// symbol cannot satisfy an assertion about code, and every extractor is
/// POSITIVE-CONTROLLED against a symbol known to be present, because a broken
/// brace matcher and a genuinely clean file produce the identical green.
@Suite("Breath pad — reachable, and blocking (m28-p7)")
struct BreathPadEntryPointSiteTests {

    // MARK: - Locating the tree (the HumanizePanelSiteTests idiom, verbatim)

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

    private static func codeOnly(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
        }.joined(separator: "\n")
    }

    private static func code(_ relativePath: String) -> String {
        codeOnly(text(relativePath))
    }

    /// The text between the braces that OPEN at the end of `marker`. Returns nil
    /// when the marker is absent, which every caller treats as a FAILURE:
    /// "renamed" and "correct" must never look the same here.
    private static func bracedBody(after marker: String, in content: String) -> String? {
        guard let markerRange = content.range(of: marker) else { return nil }
        var depth = 1          // the marker's own trailing `{`
        var out = ""
        var i = markerRange.upperBound
        while i < content.endIndex {
            let ch = content[i]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
            out.append(ch)
            i = content.index(after: i)
        }
        return nil
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var idx = haystack.startIndex
        while let r = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            count += 1
            idx = r.upperBound
        }
        return count
    }

    private static let appPath = "DAWApp/DAWProApp.swift"

    // MARK: - THE TRAP: the pad must scrim DELETE

    /// `breathPadClipID` must be INSIDE the `isModalPresented` body — not merely
    /// somewhere in the file, which it unavoidably is (it is declared there).
    /// What this prevents is a DELETE keypress destroying the arrange selection
    /// behind a scrim the user is looking at.
    @Test("the breath pad is a BLOCKING modal — DELETE cannot reach the clips behind it")
    func breathPadIsInTheModalList() {
        let app = Self.code(Self.appPath)
        guard let body = Self.bracedBody(after: "var isModalPresented: Bool {", in: app) else {
            Issue.record("could not extract the isModalPresented body — the marker moved; FIX THE EXTRACTOR, do not assume the guard is fine")
            return
        }
        #expect(body.contains("quantizePanelClipID"),
                "POSITIVE CONTROL FAILED: the extractor cannot even see a modal that was already listed, so its verdict on the breath pad means nothing.")
        #expect(body.contains("breathPadClipID"),
                "the breath pad is NOT in isModalPresented — a DELETE keypress while it is open will destroy the arrange selection behind its scrim.")
        #expect(!body.contains("showEngineNotices"),
                "NEGATIVE CONTROL FAILED: showEngineNotices is excluded on purpose (a passive banner, not a scrimmed modal).")
    }

    // MARK: - The AppModel half

    /// State, opener, closer — and the closer's one non-obvious duty.
    ///
    /// ⛔ **Dismissing mid-gesture must not commit.** The pad's whole cadence law
    /// is "preview while dragging, commit ONCE on release" (m25-k: *a correct
    /// policy at the wrong cadence looks exactly like a correct policy*). A close
    /// that fell through to `endGesture()` would write an edit the user
    /// cancelled, and an Escape key would silently spend an undo step.
    @Test("AppModel owns the pad state, and closing it cannot commit")
    func appModelWiring() {
        let app = Self.code(Self.appPath)
        #expect(app.contains("var breathPadClipID: UUID?"))
        #expect(app.contains("let breathPad: BreathPadModel"))
        #expect(app.contains("func openBreathPad(clipID: UUID)"))
        guard let close = Self.bracedBody(after: "func closeBreathPad() {", in: app) else {
            Issue.record("closeBreathPad is missing — the panel cannot be dismissed")
            return
        }
        #expect(close.contains("endGestureWithoutCommitting"),
                "closing the pad does not cancel an open gesture — dismissing mid-drag would COMMIT an edit the user was in the middle of abandoning.")
        #expect(!close.contains("endGesture()"),
                "closeBreathPad calls the COMMITTING end — that is the cadence bug this pad exists to avoid.")
    }

    // MARK: - The presentation half, and BOTH routes

    /// The overlay, plus the exact number of openers. Counting them is the
    /// point: the pad has two entry points by design (piano roll + arrange), and
    /// "one of them silently lost its closure" is the failure mode a `contains`
    /// check cannot see.
    @Test("ContentView presents the pad and wires BOTH entry points")
    func contentViewPresentsAndWiresBothRoutes() {
        let content = Self.code("DAWApp/ContentView.swift")
        #expect(content.contains("model.breathPadClipID != nil"))
        #expect(content.contains("BreathPadView("))
        #expect(content.contains("model.breathPad"))
        #expect(content.contains("model.closeBreathPad()"))
        let openers = Self.occurrences(of: "model.openBreathPad(clipID:", in: content)
        #expect(openers == 2,
                "expected exactly 2 openBreathPad call sites in ContentView (piano roll + arrange); found \(openers). A route that lost its closure ships a visible, dead affordance.")
    }

    /// The piano-roll half — a chip that is DEFINED and actually MOUNTED.
    @Test("the piano-roll header mounts a BREATH chip")
    func pianoRollChipIsMounted() {
        let roll = Self.code("DAWApp/PianoRoll/PianoRollView.swift")
        #expect(roll.contains("var onOpenBreathPad: () -> Void"))
        guard let chip = Self.bracedBody(after: "private var breathPadChip: some View {", in: roll) else {
            Issue.record("breathPadChip is not defined in PianoRollView")
            return
        }
        #expect(chip.contains("onOpenBreathPad"), "the chip does not call its own closure")
        #expect(chip.contains("BREATH"), "the chip has no readable label")

        guard let header = Self.bracedBody(after: "private var header: some View {", in: roll) else {
            Issue.record("could not extract the piano-roll header — the marker moved; FIX THE EXTRACTOR")
            return
        }
        #expect(header.contains("humanizeChip"),
                "POSITIVE CONTROL FAILED: the extracted header does not contain a chip that was already there.")
        #expect(header.contains("breathPadChip"),
                "breathPadChip is defined but never mounted — it ships unclickable, which is exactly the m25-c defect.")
    }

    /// The arrange half — a "Breath Pad…" entry INSIDE the MIDI-only branch.
    /// `applyEffortShape` throws `notAMIDIClip` on audio, so the entry must not
    /// exist there: hidden, never offered-then-errored (the sibling "Quantize…" /
    /// "Humanize…" rule in this same menu).
    ///
    /// This is the one assertion with NO pixel backing anywhere in the tree — a
    /// context menu lives in its own window and `cacheDisplay` cannot see it.
    @Test("the arrange clip menu offers the Breath Pad on MIDI clips only")
    func arrangeMenuEntryIsMIDIOnly() {
        let timeline = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        #expect(timeline.contains("var onOpenBreathPad:"))
        #expect(timeline.contains("onOpenBreathPad: { onOpenBreathPad(clip) }"),
                "the ClipBlock closure is not threaded from the lane view — the menu entry would call an empty default and do nothing")

        guard let midiOnly = Self.bracedBody(after: "if clip.isMIDI {", in: timeline) else {
            Issue.record("could not extract the MIDI-only menu branch — FIX THE EXTRACTOR")
            return
        }
        #expect(midiOnly.contains("Humanize…"),
                "POSITIVE CONTROL FAILED: the extracted MIDI-only branch does not contain the entry known to live there.")
        #expect(midiOnly.contains("Breath Pad…"),
                "the Breath Pad entry is outside the MIDI-only branch — on an audio clip it would be offered and then throw notAMIDIClip.")
    }

    // MARK: - The wire decision, asserted rather than remembered

    /// m28-p7 is UI-ONLY. `clip.applyEffortShape` ALREADY exists on the wire and
    /// in MCP — the missing half was the human-clickable one. So the panel adds
    /// NO command, and `debug.breathPad` is app-tier (a `debug.*` verb, off
    /// `allCommands` and off MCP, the m23-cq-1 shape). The wire-count pins
    /// elsewhere are what would break; this says WHY they must not.
    @Test("the pad adds no wire surface — the capability already had one")
    func staysOffTheWire() {
        let control = Self.text("DAWControl/Commands.swift")
        #expect(control.count > 10_000, "Commands.swift came back short: \(control.count) chars")
        #expect(control.contains("\"clip.applyEffortShape\""),
                "POSITIVE CONTROL FAILED: clip.applyEffortShape is not in Commands.swift, so an absence check there proves nothing.")
        for banned in ["breathPad", "BreathPad", "breath.pad"] {
            #expect(!control.contains(banned),
                    "\(banned) reached DAWControl — the PANEL is view chrome; the capability it drives already has clip.applyEffortShape, and a new entry breaks the wire-count pins.")
        }
        // The debug seam exists, and lives where every other debug verb does.
        let app = Self.code(Self.appPath)
        #expect(app.contains("case \"debug.breathPad\":"),
                "the debug seam is gone — nothing headless can open the pad, and the render probe (the only instrument that has ever caught a defect in this panel) stops working.")
    }

    // MARK: - m34-f step ① — the pressure surface
    //
    // ⚠️⚠️ **THE WEAKEST INSTRUMENT IN THIS ITEM, AND SAID SO PLAINLY.** `DAWApp`
    // is an `executableTarget` with no test target, so an `NSPressureConfiguration`
    // built at runtime cannot be constructed and inspected from any suite here —
    // this reads the source instead. A spy would be better and is not available.
    // What these legs genuinely rule out is the class of regression that has
    // actually bitten this panel: a symbol that exists but is never mounted, and
    // a configuration silently reverting to the system default.
    //
    // ⛔ **WHAT THEY DO NOT AND CANNOT PROVE: that a real `NSEventTypePressure`
    // ever arrives, that the Force Click detent is genuinely suppressed, or that
    // the AppKit y-flip is right.** All three need a human hand on a trackpad.

    private static let padViewPath = "DAWApp/BreathPad/BreathPadView.swift"
    private static let pressurePath = "DAWApp/BreathPad/PadPressureSurface.swift"

    @Test("the pressure surface is MOUNTED on the dial, not merely defined")
    func thePressureSurfaceIsMounted() {
        let dial = Self.code(Self.padViewPath)
        #expect(dial.count > 5_000, "BreathPadView.swift came back short: \(dial.count) chars")
        // POSITIVE CONTROL: the extractor must find something known to be there,
        // or an absence assertion below proves nothing.
        #expect(dial.contains("BreathPadGeometry"),
                "POSITIVE CONTROL FAILED: BreathPadGeometry is not in BreathPadView.swift, so the reads below are meaningless.")
        #expect(dial.contains("PadPressureSurface(model: model"),
                "a surface that is defined but never mounted compiles, ships, and is dead — the precise defect m25-c was filed for.")
    }

    @Test("⛔ the dial has exactly ONE pointer path — the old DragGesture is GONE, not doubled")
    func thereIsOnlyOneInputPath() {
        // Two input paths onto one model would double every `beginDrag`, and the
        // pad's commit is gated on "the dot moved" — so one click would spend
        // TWO undo steps. This is the assertion that keeps the swap a swap.
        let dial = Self.code(Self.padViewPath)
        #expect(dial.contains("PadPressureSurface"))
        #expect(!dial.contains("DragGesture"),
                "a DragGesture is back on the dial alongside the NSView — one press would open two gestures.")
    }

    @Test("⚠️ the pressure behaviour is .primaryGeneric — NOT the actuated system default")
    func theConfigurationIsTheMusicalOne() {
        // ⛔ `.primaryDeepClick` (the system default) is TWO-STAGE and ACTUATED:
        // crossing into stage 2 fires the Force Click haptic. A physical click
        // transient in the middle of a breath swell reads as a mixing artefact,
        // not as expression. Only `.primaryGeneric` is one stage, unactuated,
        // full-range — Apple's own header calls it the one for "drawing and
        // general pressure use".
        let surface = Self.code(Self.pressurePath)
        #expect(surface.count > 1_000, "PadPressureSurface.swift came back short: \(surface.count) chars")
        #expect(surface.contains("NSPressureConfiguration(pressureBehavior: .primaryGeneric)"))
        #expect(surface.contains("pressureConfiguration = Self.musicalPressure"),
                "a configuration that is built and never installed leaves the gesture on the system default.")
        for banned in [".primaryDeepClick", ".primaryDeepDrag", ".primaryAccelerator"] {
            #expect(!surface.contains(banned),
                    "\(banned) would put a haptic detent or a speed curve through a breath swell.")
        }
    }

    @Test("the coordinate space is FLIPPED, and the pressure event reaches the model")
    func theSurfaceIsWiredEndToEnd() {
        // ⚠️ AppKit is y-UP and `BreathPadGeometry` was written for SwiftUI's
        // y-DOWN. Without `isFlipped` every press lands mirrored about the
        // horizontal axis — invisible to every synthetic leg in this item (they
        // all call the model directly) and obvious to a human in one second.
        let surface = Self.code(Self.pressurePath)
        #expect(surface.contains("override var isFlipped: Bool { true }"))
        #expect(surface.contains("override func pressureChange(with event: NSEvent)"))
        #expect(surface.contains("model?.pressureChanged(Double(event.pressure))"),
                "the pressure event must reach the model, or the axis is decorative.")
        // The three model calls the old DragGesture made, in the new home.
        for call in ["model.beginDrag(at:", "model.drag(to:", "model.endDrag()"] {
            #expect(surface.contains(call),
                    "\(call) is missing — the NSView must make the SAME three calls the gesture did.")
        }
    }
}
