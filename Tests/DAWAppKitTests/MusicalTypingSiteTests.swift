import Foundation
import Testing

/// m23-ct — **THE WIRING IS ACTUALLY THERE.**
///
/// ⚠️⚠️ **THIS SUITE EXISTS BECAUSE `Sources/DAWApp` HAS NO TEST TARGET, AND THE
/// BUG CLASS IT GUARDS HAS ALREADY SHIPPED HERE ONCE.** At m25-l-1 the active-track
/// rail was *declared and never mounted*: the model was right, the view compiled,
/// the suite was green, and the feature was invisible because it *was*.
/// `ArrangeActiveTrackRailSiteTests` is that scar; this is the same shape for a
/// feature whose model is entirely in `DAWAppKit` and whose every connection to a
/// keystroke is in the untestable executable.
///
/// The five things asserted here are the five that, if any one were missing, would
/// leave `MusicalTypingRouting` and `MusicalTypingController` fully unit-tested and
/// the user unable to play a single note.
///
/// Assertions run against a **comment-stripped** source, following
/// `PianoRollScrubRulerSiteTests`' rule and for its reason: **prose must not be
/// able to satisfy a claim about what code CALLS.** Every file below documents its
/// wiring in detail, and those doc comments would satisfy a naive grep — that is
/// precisely how the m25-l-1 defect hid.
@Suite("Musical Typing wiring (m23-ct)")
struct MusicalTypingSiteTests {

    // MARK: - Source access (the `ArrangeActiveTrackRailSiteTests` helpers)

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

    private static let appPath = "DAWApp/DAWProApp.swift"
    private static let stagingPath = "DAWApp/MusicalTypingStaging.swift"
    private static let contentPath = "DAWApp/ContentView.swift"
    private static let transportPath = "DAWApp/TransportBar.swift"
    private static let stripPath = "DAWApp/Components/MusicalKeyboardStrip.swift"

    /// Guard the guard. Every assertion below is "this string is present in
    /// comment-stripped source"; a helper that silently returned "" — a moved
    /// file, a rename, a bad relative path — would make every one of them fail
    /// LOUDLY rather than pass, but a stripper that ate real code would make them
    /// fail for the wrong reason. This proves the stripper keeps code and drops
    /// prose.
    @Test("fixture check: the source reader and the comment stripper both work")
    func harnessWorks() {
        let stripped = Self.codeOnly(Self.text(Self.stagingPath))
        #expect(!stripped.isEmpty, "the staging file read as empty")
        #expect(stripped.contains("func musicalTypingDebug"),
                "the stripper ate a real declaration")
        #expect(!stripped.contains("THE STUCK-NOTE SAFETY NET"),
                "the stripper left prose behind, so every test here could pass on a comment")
    }

    // MARK: - ① The monitor must carry key-UP

    @Test("⛔ the key monitor listens for keyUp and flagsChanged, not just keyDown")
    func monitorMaskCoversReleases() {
        // WITHOUT THIS THE FEATURE HAS NO NOTE-OFF AT ALL. Every note would ring
        // until the 3 s render-side watchdog cut it — and the model tests would
        // all still pass, because they call `releaseKey` directly.
        let app = Self.codeOnly(Self.text(Self.appPath))
        #expect(app.contains("matching: [.keyDown, .keyUp, .flagsChanged]"),
                "the local monitor's event mask no longer covers releases")
        #expect(app.contains("case .keyUp: return self.handleKeyUpEvent(event)"))
        #expect(app.contains("case .flagsChanged: return self.handleFlagsChangedEvent(event)"))
        // ⚠️ AND THE TYPE BRANCH MUST COME FIRST: `.characters` / `.isARepeat`
        // RAISE on a `.flagsChanged` event, so reading one before the switch turns
        // every ⇧ press in the app into a crash.
        guard let switchAt = app.range(of: "switch event.type"),
              let repeatAt = app.range(of: "event.isARepeat") else {
            Issue.record("could not locate the monitor's type switch"); return
        }
        #expect(switchAt.lowerBound < repeatAt.lowerBound,
                "an event property that raises on .flagsChanged is read before the type branch")
    }

    // MARK: - ② The key-down branch must be reached

    @Test("handleKeyDownEvent actually calls the Musical Typing branch")
    func keyDownReachesMusicalTyping() {
        let app = Self.codeOnly(Self.text(Self.appPath))
        #expect(app.contains("return handleMusicalTypingKeyDown(event)"),
                "the note branch is declared but never reached from the monitor")
        // The space bar must still return early on its own grant — a note key
        // must not be able to also toggle the transport.
        #expect(app.contains("toggleTransportFromSpaceKey()"))
    }

    // MARK: - ③ The controller must be wired to a sink

    @Test("the controller is given its sink, and the sink resolves the track per call")
    func controllerIsWired() {
        let app = Self.codeOnly(Self.text(Self.appPath))
        #expect(app.contains("installMusicalTyping()"),
                "the bootstrap never wires Musical Typing")
        let staging = Self.codeOnly(Self.text(Self.stagingPath))
        #expect(staging.contains("musicalTyping.sink = LivePlayNoteSink(store: store)"),
                "the controller has no sink — every note would be silent")
        // Per-call resolution, not a captured UUID: a captured id keeps playing
        // the track the user left.
        #expect(staging.contains("self?.activeTrackID"))
    }

    // MARK: - ④ The stuck-note safety net

    @Test("⛔ resign-active releases held notes — the net that had no observer before m23-ct")
    func resignActiveReleases() {
        // ⚠️ `ProjectStore.stopAllAudition`'s doc claimed the app already did this
        // "on resign-active"; measured 2026-08-29, NO such observer existed
        // (positive-controlled against `willTerminateNotification`, which does).
        // This is the code that makes the claim true, so it is pinned.
        let staging = Self.codeOnly(Self.text(Self.stagingPath))
        #expect(staging.contains("NSApplication.didResignActiveNotification"),
                "nothing releases held notes when the app goes inactive")
        #expect(staging.contains("musicalTyping.releaseAll()"))
        #expect(staging.contains("store.stopAllAudition()"))
        // ⌘ engaging releases too — macOS is ASSERTED (not verified here) to
        // withhold key-up while ⌘ is down.
        #expect(staging.contains("func handleFlagsChangedEvent"))
        #expect(staging.contains(".contains(.command)"))
    }

    @Test("⛔ the release path takes NO responder, window or modifier argument")
    func releaseIsStructurallyUnguarded() {
        // GATE THE ONS, NEVER GATE THE OFFS — expressed as a shape rather than a
        // promise. If someone adds a guard to the key-up path, the signature has
        // to grow to carry the facts, and this fails.
        let staging = Self.codeOnly(Self.text(Self.stagingPath))
        #expect(staging.contains("musicalTyping.releaseKey(keyCode: event.keyCode) ? nil : event"),
                "the key-up handler grew a guard, or stopped passing unclaimed keys through")
    }

    @Test("⛔ record start and track switch both release, from the mounted strip")
    func transportAndTrackChangesRelease() {
        // `ProjectStore.record()` releases the audition engine-side ("a take starts
        // SILENT"). Not mirroring it would leave the strip lighting keys the
        // engine already stopped.
        let content = Self.codeOnly(Self.text(Self.contentPath))
        #expect(content.contains("onChange(of: store.transport.isRecording)"),
                "nothing releases held notes when a take begins")
        #expect(content.contains("onChange(of: model.activeTrackID)"),
                "nothing releases held notes when the target track changes")
    }

    // MARK: - ⑤ The surfaces must be MOUNTED

    @Test("the on-screen keyboard is actually mounted in the window")
    func stripIsMounted() {
        // THE m25-l-1 PIN: a `@ViewBuilder` property nothing references is dead
        // code that looks like a feature, and Swift will not warn.
        let content = Self.codeOnly(Self.text(Self.contentPath))
        #expect(content.contains("MusicalKeyboardStrip("),
                "the keyboard view is never constructed")
        #expect(content.contains("musicalKeyboardStrip"),
                "the strip property is declared but never placed in the body")
        // Referenced at least twice: once declared, once used.
        let mentions = content.components(separatedBy: "musicalKeyboardStrip").count - 1
        #expect(mentions >= 2, "the strip property is declared and never referenced")
    }

    @Test("the mode toggle is mounted in the transport bar and drives the ONE funnel")
    func toggleIsMounted() {
        let bar = Self.codeOnly(Self.text(Self.transportPath))
        #expect(bar.contains("musicalTypingToggle"), "the KEYS chip is not in the bar")
        let mentions = bar.components(separatedBy: "musicalTypingToggle").count - 1
        #expect(mentions >= 2, "the toggle is declared and never placed")
        #expect(bar.contains("appModel.setMusicalTypingEnabled("),
                "the chip does not go through the one mode funnel")
        // NOT gated on Pro density: the only performance surface this user has
        // must not be hidden from a beginner (Rule 6).
        #expect(!bar.contains("if isPro {\n                musicalTypingToggle"))
    }

    @Test("the staging seam is registered on the debug router")
    func debugSeamIsRegistered() {
        // A handler nobody dispatches to is the same dead-code shape as an
        // unmounted view, and it is how a gate would silently test nothing.
        let app = Self.codeOnly(Self.text(Self.appPath))
        #expect(app.contains("case \"debug.musicalTyping\":"),
                "debug.musicalTyping is not in the app's verb table")
        #expect(app.contains("return try self.musicalTypingDebug(params)"))
    }

    @Test("⭐ the seam runs the FULL key-down body, not just the note branch")
    func seamEntersAtTheTop() {
        // A seam that entered halfway would agree with itself while the live
        // monitor swallowed the key upstream (the m23-o2 `widthSource` failure).
        let staging = Self.codeOnly(Self.text(Self.stagingPath))
        #expect(staging.contains("let passed = handleKeyDownEvent(event)"),
                "the press seam bypasses the delete/space branches")
        // …and it resolves key names through the layout table rather than
        // hardcoding a second copy of the key codes.
        #expect(staging.contains("MusicalTypingRouting.cap(forLabel: label)"))
    }

    // MARK: - The design contract

    @Test("the strip carries no raw hex and reuses the gutter's measured key inks")
    func stripUsesThemeTokens() {
        // docs/DESIGN-LANGUAGE.md: no raw hex in views — Theme owns colour. And
        // m23-b's real rule: a LIGHT surface earns its own measured ink and never
        // borrows the dark hierarchy.
        let strip = Self.codeOnly(Self.text(Self.stripPath))
        #expect(strip.contains("DAWTheme.keyWhite"))
        #expect(strip.contains("DAWTheme.keyBlack"))
        #expect(strip.contains("DAWTheme.keyLabelOnWhite"))
        #expect(strip.contains("DAWTheme.keyEdgeOnWhite"))
        // The held-key legend's polarity is DERIVED from the measured crossover,
        // never picked — the app's one home for that question.
        #expect(strip.contains("NotePillInk.prefersDarkInk"))
        // No raw hex LITERAL anywhere in the code (comments stripped).
        //
        // ⚠️ The assertion is a regex for `0xRRGGBB` and NOT `!contains("0x")`
        // or `!contains("Color(hex:")`, both of which I tried and both of which
        // are wrong here: `SRGBColor(hex: DAWTheme.playbackHex)` contains the
        // substring `Color(hex:` while being exactly the correct thing to write —
        // reading a Theme token. What the rule forbids is a colour DECIDED in the
        // view, and a six-digit literal is what that looks like.
        let literal = try! NSRegularExpression(pattern: "0x[0-9A-Fa-f]{6}")
        let range = NSRange(strip.startIndex..., in: strip)
        #expect(literal.firstMatch(in: strip, range: range) == nil,
                "the strip carries a raw hex colour literal")
        // Guard the guard: the matcher must fire on a real literal, and must not
        // fire on the token-reading form the strip actually uses.
        let bad = "Color(hex: 0xD9D5CA)"
        #expect(literal.firstMatch(in: bad, range: NSRange(bad.startIndex..., in: bad)) != nil)
        let good = "SRGBColor(hex: DAWTheme.keyWhiteHex)"
        #expect(literal.firstMatch(in: good, range: NSRange(good.startIndex..., in: good)) == nil)
    }

    @Test("the keyboard is Canvas-drawn and snapshots its inputs (the m16-a contract)")
    func stripHonoursTheCanvasContract() {
        let strip = Self.codeOnly(Self.text(Self.stripPath))
        #expect(strip.contains("Canvas { @Sendable context, size in"),
                "the renderer closure is not the @Sendable form the m16-a contract requires")
        // The sounding set and the span are read into values BEFORE the closure.
        #expect(strip.contains("let sounding = controller.soundingPitchSet"))
        #expect(strip.contains("let span = controller.pitchSpan"))
    }

    @Test("the layout table has exactly ONE home — the strip does not re-list the keys")
    func stripReadsTheOneLayoutTable() {
        // The divergence `KeyboardSidebar.keyLabel` spends a paragraph preventing
        // for note NAMES, applied to key LEGENDS: a second table here would let
        // the strip disagree with the keyboard about which letter plays what.
        let strip = Self.codeOnly(Self.text(Self.stripPath))
        #expect(strip.contains("MusicalTypingRouting.noteCaps"))
        #expect(!strip.contains("\"W\""), "the strip hardcodes a key legend")
        #expect(!strip.contains("\"A\""), "the strip hardcodes a key legend")
    }

    @Test("the gutter's black-key table now forwards rather than duplicating")
    func gutterForwardsToTheOneTable() {
        // ONE home for the five accidentals. A second copy here would be free to
        // disagree with the strip about what a black key is.
        let sidebar = Self.codeOnly(Self.text("DAWApp/PianoRoll/KeyboardSidebar.swift"))
        #expect(sidebar.contains("MusicalKeyboardGeometry.isBlackKey(pitch)"))
        #expect(!sidebar.contains("[1, 3, 6, 8, 10]"),
                "the gutter still carries its own copy of the accidental table")
    }

    // MARK: - ⑥ The two paths that reach OTHER features

    @Test("⛔ the ⌘ release path cannot fire when this controller holds nothing")
    func commandReleaseIsGuardedByHolds() {
        // ⛔⛔ THE BUG THIS PINS IS IN ANOTHER FEATURE. `handleFlagsChangedEvent`
        // runs on every ⌘ press in the app, with Musical Typing OFF, and
        // `releaseAll()` pushes an empty set that stops the SHARED audition — the
        // piano roll's gutter, or a note drag in progress. Unguarded, ⌘Z during a
        // roll drag cuts the roll's note. The guard must be on the SAME statement
        // as the release, so a later edit cannot separate them silently.
        let staging = Self.codeOnly(Self.text(Self.stagingPath))
        #expect(staging.contains("if musicalTyping.holdsAnything,"),
                "the ⌘ path lost its holds-anything guard: it now stops the piano roll's audition on every ⌘Z")
        guard let flags = staging.range(of: "func handleFlagsChangedEvent") else {
            Issue.record("handleFlagsChangedEvent is gone"); return
        }
        let body = String(staging[flags.lowerBound...].prefix(600))
        let guardAt = body.range(of: "holdsAnything")
        let releaseAt = body.range(of: "musicalTyping.releaseAll()")
        #expect(guardAt != nil && releaseAt != nil
                && guardAt!.lowerBound < releaseAt!.lowerBound,
                "the ⌘ handler releases before it checks whether it holds anything")
    }

    // MARK: - ⑦ The join to the engine half

    @Test("⛔ the sink pushes at playLiveNotes — the audition ceiling is not still wired")
    func sinkTargetsTheRecordablePath() {
        // ⛔⛔ THE ONE-LINE REGRESSION THIS GUARDS: reverting `playLiveNotes` to
        // `auditionPitches` restores a feature that PLAYS perfectly and records
        // nothing, and every unit test above it would stay green because the
        // controller cannot see which store method its sink calls.
        let sink = Self.codeOnly(Self.text("DAWAppKit/LiveNoteSink.swift"))
        #expect(sink.contains("store.playLiveNotes(trackID: trackID, pitches: pitches,"),
                "the live-note sink no longer pushes at the recordable path")
        #expect(!sink.contains("store.auditionPitches("),
                "the sink still calls auditionPitches, which refuses mid-take")
        #expect(sink.contains("lastIsRecording = result.isRecording"),
                "the engine's capture verdict is not being read back")
    }

    @Test("the arm flag reaches the target resolver, and arming refreshes the indicator")
    func armFlagIsWired() {
        // Two halves, and BOTH are needed. The resolver must be TOLD (staging),
        // and something must tell it AGAIN when the user arms the track while the
        // strip is up — which is precisely the fix the un-armed line asks for.
        let staging = Self.codeOnly(Self.text(Self.stagingPath))
        #expect(staging.contains("isArmed: track?.isArmed == true"),
                "the target resolver cannot tell an armed take from an un-armed one")

        let content = Self.codeOnly(Self.text(Self.contentPath))
        #expect(content.contains("?.isArmed) { _, _ in"),
                "arming the track while the strip is up updates nothing")
        // ⛔ AND IT MUST NOT RELEASE. Arming is not a boundary; cutting a held
        // note as a reward for fixing the problem would be its own defect.
        guard let armAt = content.range(of: "?.isArmed) { _, _ in") else {
            Issue.record("the arm observer is gone"); return
        }
        let body = String(content[armAt.lowerBound...].prefix(160))
        #expect(!body.contains("releaseAll()"),
                "arming the track cuts the note the user is holding")
        #expect(body.contains("refreshMusicalTypingTarget()"))
    }

    @Test("⛔ the honesty light renders from the resolved state, never from the mode flag")
    func honestyLightIsWired() {
        // A "RECORDING" badge driven by `isEnabled`, or by the transport alone,
        // would read ON over an un-armed track — the one state in the app where
        // everything looks and SOUNDS right while the take keeps nothing.
        let strip = Self.codeOnly(Self.text(Self.stripPath))
        #expect(strip.contains("if isCapturing {"),
                "the RECORDING badge is not gated on the capture verdict")
        #expect(strip.contains("controller.targetState.isCapturing"),
                "isCapturing is computed locally instead of read from the one resolver")
        #expect(strip.contains("case .recordingUnarmed:"),
                "the un-armed-during-a-take case has no status line of its own")
        // The keys must not be dimmed as if refused while they are sounding.
        #expect(strip.contains("controller.targetState.canSound"),
                "the strip still asks == .ready, which reads as refused while recording")
    }

    @Test("the seam echoes the ENGINE's capture verdict, not only the app's prediction")
    func seamEchoesBothCaptureInstruments() {
        // Three instruments on one question is this feature's pattern; for
        // "is this being kept?" only ONE of them can see a capture session.
        let staging = Self.codeOnly(Self.text(Self.stagingPath))
        #expect(staging.contains("\"sinkIsRecording\""),
                "a gate cannot read the engine's own capture answer")
        #expect(staging.contains("\"targetIsCapturing\""),
                "a gate cannot read the app's prediction to compare against")
        #expect(staging.contains("store.livePlay.heldPitches"),
                "the echo still reports the AUDITION ledger, which the sink no longer writes")
    }

    @Test("the mouse and the staging seam press a key through the SAME function")
    func pointerPathIsShared() {
        // The m23-an class in miniature: a seam that drives a slightly different
        // path than the human is a gate that is green on code nobody runs. The
        // refresh before the press is the part that would diverge — a click can be
        // the first event after a track switch.
        let strip = Self.codeOnly(Self.text(Self.stripPath))
        #expect(strip.contains("onPointerPress(pitch)"),
                "the on-screen keyboard bypasses the app's shared press path")
        #expect(!strip.contains("controller.pointerDown("),
                "the view still calls pointerDown directly, so the mouse skips refreshMusicalTypingTarget() and the seam does not")

        let content = Self.codeOnly(Self.text(Self.contentPath))
        #expect(content.contains("onPointerPress: { model.musicalTypingPointerDown(pitch: $0) }"),
                "the mounted strip is not wired to the shared press path")

        let staging = Self.codeOnly(Self.text(Self.stagingPath))
        #expect(staging.contains("musicalTypingPointerDown(pitch: Int(raw))"),
                "debug.musicalTyping no longer presses through the shared path")
        // The shared path owns the refresh, so neither caller can forget it.
        guard let fn = staging.range(of: "func musicalTypingPointerDown") else {
            Issue.record("the shared pointer entry point is gone"); return
        }
        let body = String(staging[fn.lowerBound...].prefix(240))
        #expect(body.contains("refreshMusicalTypingTarget()"),
                "the shared press path stopped refreshing the target state")
    }
}
