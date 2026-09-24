import Foundation
import Testing

/// m39-pads — **THE PAD GRID IS ACTUALLY MOUNTED, AND ACTUALLY BOUND.**
///
/// ⚠️⚠️ `Sources/DAWApp` has no test target, and this feature's failure mode is
/// worse than "invisible": an unmounted grid shows nothing, but an **unbound**
/// one shows sixteen dim squares over a sampler holding 53 slices, with
/// `loadedCount: 0` and every headless reading agreeing with the picture. That
/// is this tree's characteristic failure — a plausible-looking valid answer —
/// rendered in pixels.
///
/// `MusicalTypingSiteTests`' shape verbatim, including the rule that matters
/// most here: assertions run against **comment-stripped** source, because every
/// file below documents its own wiring in prose that would satisfy a naive grep.
/// That is exactly how the m25-l-1 defect (a rail declared and never mounted,
/// suite green) hid.
@Suite("Pad grid wiring (m39-pads)")
struct PadGridSiteTests {

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

    /// ⭐ **THE POSITIVE CONTROL FOR THE WHOLE SUITE.** Every assertion below is
    /// a `contains` over stripped source, and a stripper that returned "" would
    /// make each of them fail loudly — but a PATH typo would too, and for a
    /// different reason. This proves the reader reaches real code first.
    @Test("the source reader reaches real code (positive control)")
    func readerWorks() {
        let strip = Self.code("DAWApp/PadGridStaging.swift")
        #expect(strip.contains("extension AppModel"))
        #expect(strip.isEmpty == false)
        // And it really does strip: this phrase exists ONLY in a comment there.
        #expect(strip.contains("liveness watchdog") == false)
        // Negative control on the path itself — a file that does not exist must
        // NOT quietly read as an empty string that satisfies nothing.
        #expect(Self.code("DAWApp/PadGridStaging.swift").count > 500)
    }

    // MARK: - The five things that must exist

    @Test("⛔ the pad grid is BOUND to the app — installPadGrid is declared AND called")
    func theGridIsBound() {
        // The failure this pins: `padGrid` is constructed INERT in `AppModel.init`
        // (it cannot capture `self` there), so without this call it draws an
        // empty kit forever and says nothing about it.
        let staging = Self.code("DAWApp/PadGridStaging.swift")
        #expect(staging.contains("func installPadGrid()"))
        #expect(staging.contains("padGrid.rebind("))
        #expect(staging.contains("self.padGridZones()"))
        #expect(staging.contains("store.sliceClipToSampler("))

        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("installPadGrid()"))
        // ⭐ AND IT IS NOT MERELY DECLARED: the call sits beside the one whose
        // absence has an identical shape, so a reader sees both together.
        #expect(app.contains("installMusicalTyping()"))
        #expect(app.contains("var padGrid = PadGridModel("))
        // ⛔ AND IT IS REPLACED WHOLE, not merely rebound: the placeholder holds
        // a THROWAWAY controller, so a `rebind`-only install would leave the
        // pads pushing at a sink nothing else can see.
        #expect(staging.contains("padGrid = PadGridModel(typing: musicalTyping"))

        // ⛔⛔ **THE LET GO INJECTORS, AND THEY ARE PINNED FOR THE SAME REASON AS
        // THE REST OF THIS TEST** (m39-pads-2). `rebind`'s `oneShot:` and
        // `setOneShot:` both DEFAULT — delete these two lines and the package
        // still compiles, every `PadGridTests` case still passes (they inject
        // their own), and the LET GO row draws dimmed as "not a sampler" over a
        // sampler holding 53 slices. Self-consistent, dead, and shaped exactly
        // like the legitimate non-sampler state. A default is a silent failure
        // with a compiler-shaped alibi.
        #expect(staging.contains("oneShot: { [unowned self] in self.padGridOneShot() }"))
        #expect(staging.contains("setOneShot: { [unowned self] on in self.padGridSetOneShot(on) }"))
        // …and the write goes to the SAME one home the sampler card uses, not a
        // second mutation path of its own.
        #expect(staging.contains("store.setInstrument(id: id, sampler: params)"))
    }

    /// ⚠️ The same-track mute guard cannot be reached behaviourally — see
    /// `SliceToSamplerCommandTests.muteWorksOntoAnExistingTarget` for the
    /// measurement. This is the only instrument that can see it at all.
    @Test("⛔ the same-track mute guard EXISTS (it is unreachable, not absent)")
    func sameTrackMuteGuardExists() {
        let store = Self.code("DAWCore/ProjectStore+SliceToSampler.swift")
        #expect(store.contains("sourceTrackID != destinationID"))
        #expect(store.contains("sourceTrackID == destinationID"))
        // And the honest second reading it feeds.
        #expect(store.contains("sourceTrackMuted:"))
    }

    @Test("⛔ the PADS chip exists and the third face is MOUNTED")
    func theThirdFaceIsMounted() {
        let strip = Self.code("DAWApp/Components/MusicalKeyboardStrip.swift")
        // The chip that reaches the mode at all.
        #expect(strip.contains("onSetPlayMode(.pads)"))
        // The face it reveals — and the grid view inside it.
        #expect(strip.contains("isPadMode"))
        #expect(strip.contains("padFace"))
        #expect(strip.contains("PadGridView("))
        // ⭐ DRAWN FROM THE MODEL, NOT THE CONTROLLER. Only the model knows
        // which pads carry a slice; a grid fed from `soundingPitches` alone
        // would draw sixteen identical squares.
        #expect(strip.contains("padGrid.pads"))
        #expect(strip.contains("padGrid.loadedCount"))
    }

    @Test("⛔ the strip's pad callbacks are WIRED in ContentView, through AppModel funnels")
    func contentViewWiresThePads() {
        let strip = Self.code("DAWApp/ContentView.swift")
        #expect(strip.contains("padGrid: model.padGrid"))
        // ⭐ THROUGH THE FUNNEL, never `controller.pointerDown` — the funnel
        // refreshes the target state first, so the mouse and `debug.padGrid`
        // run one path (the m23-an defect class).
        #expect(strip.contains("model.padGridDown(index:"))
        #expect(strip.contains("model.padGridUp()"))
        #expect(strip.contains("model.openChopToPads()"))
        // And the chop card itself is mounted in the WINDOW CONTENT, so
        // `debug.captureUI` can photograph it (the captureUI law).
        #expect(strip.contains("ChopToPadsPanel("))
        #expect(strip.contains("model.chopToPadsOpen"))
    }

    /// m33-d. `PadGridModel.chopWarningsForHumans` is unit-tested; this pins that
    /// the strip DRAWS it. A strip still drawing `notice.warnings` would show
    /// "Pass includeHead: true…" to a person with every model test green.
    @Test("⛔ the chop notice DRAWS the human warnings; the lead-in toggle dims on the domain rule")
    func chopNoticeDrawsTheHumanText() {
        let strip = Self.code("DAWApp/Components/MusicalKeyboardStrip.swift")
        #expect(strip.contains("ForEach(notice.warningsForHumans"))
        // NON-VACUITY: the wire's sentences are drawn nowhere on the strip.
        #expect(strip.contains("notice.warnings,") == false)
        #expect(strip.contains("notice.warnings)") == false)

        let card = Self.code("DAWApp/Instrument/ChopToPadsPanel.swift")
        // Dimmed on the model's reading of the DOMAIN rule — not hidden, not disabled.
        #expect(card.contains("dimmed: !model.chop.leadInIsEffective"))
        #expect(card.contains("model.chop.leadInInertNote"))
        #expect(card.contains(".disabled(!model.chop.leadInIsEffective") == false)
        // The label has ONE home, so the notice names the box the card draws.
        #expect(card.contains("label: PadChopSettings.leadInLabel"))
        #expect(card.contains("\"Keep the lead-in as pad 1\"") == false)
    }

    @Test("⛔ the CHOP goes through the store method the WIRE calls — no parallel path")
    func chopUsesTheWiresOwnFunnel() {
        let staging = Self.code("DAWApp/PadGridStaging.swift")
        #expect(staging.contains("store.sliceClipToSampler("))
        #expect(staging.contains("muteSourceTrack: mute"))
        // ⚠️ NON-VACUITY: the app must NOT be building zones itself. A second
        // chop implementation in the UI is the drift this asserts against.
        #expect(staging.contains("SliceToSamplerPlan") == false)
        #expect(staging.contains("SamplerZone(") == false)
    }

    @Test("⛔ debug.padGrid is registered, and stays OFF the public command table")
    func stagingSeamIsAppTier() {
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("case \"debug.padGrid\""))
        #expect(app.contains("padGridDebug(params)"))

        // ⭐ AND IT IS NOT PUBLIC. A debug verb that joined `allCommands` would
        // move the wire count and hand an agent a view-shaped route to things
        // it already reaches properly.
        let commands = Self.code("DAWControl/Commands.swift")
        #expect(commands.contains("debug.padGrid") == false)
        #expect(commands.contains("padGrid") == false)
        // Positive control for that negative: the file really is the command
        // table, and it really does list the verb this feature DID extend.
        #expect(commands.contains("\"clip.sliceToSampler\""))
    }

    @Test("⛔ the CHOP card is registered as a blocking modal")
    func chopCardBlocksDelete() {
        // Its stated maintenance obligation: the card is open with an AUDIO
        // CLIP SELECTED by construction, which is exactly the state where an
        // unguarded DELETE destroys the clip the card is about to chop.
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("|| chopToPadsOpen"))
    }

    @Test("⛔ the additive wire parameter reaches every parser that must know it")
    func muteParamReachesEveryParser() {
        // Three independent parsers accept `clip.sliceToSampler` payloads, and
        // two of them REJECT unknown keys. A parameter added to one and not the
        // others is accepted in one place and refused in another.
        let commands = Self.code("DAWControl/Commands.swift")
        #expect(commands.contains("\"muteSourceTrack\""))
        #expect(commands.contains("muteSourceTrack: chopMuteSource"))

        let demo = Self.code("DemoRender/DemoRender.swift")
        #expect(demo.contains("\"muteSourceTrack\""))
        #expect(demo.contains("muteSourceTrack: sliceMute"))
    }

    @Test("⛔ the chopper has a SECOND route, and it is not Pro-gated")
    func chopIsReachableFromTheArrangeMenu() {
        // ⭐ ONE ROUTE IS HOW AN OPERATION GOES MISSING (m23-cf). Before this
        // entry the chopper lived three gestures deep behind a strip that is
        // OFF by default — reachable, and undiscoverable. The menu entry is the
        // beginner's route, so the interesting assertion is not that it exists
        // but WHERE it sits.
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        #expect(lanes.contains("Button(\"Chop to Pads…\") { onChopToPads() }"))
        #expect(lanes.contains("onChopToPads: { onChopToPads(clip) }"))

        // AUDIO ONLY — a MIDI clip has no recording to cut, and the entry is
        // hidden rather than offered-then-errored.
        #expect(lanes.contains("if !clip.isMIDI, clip.audioFileURL != nil {"))

        // ⛔ THE LOAD-BEARING ONE: the entry must sit BEFORE the `if pro {`
        // block, or it vanishes in the density built for beginners — the exact
        // shape of the bug m23-cf fixed for Delete.
        // ⚠️ Anchored INSIDE `contextMenu`. `if pro {` appears several times in
        // this 4k-line view; comparing against the first one in the file
        // measured a position in an unrelated builder and "passed" nothing.
        let menuStart = try! #require(
            lanes.range(of: "private var contextMenu: some View {"))
        let menu = String(lanes[menuStart.upperBound...])
        let entry = try! #require(menu.range(of: "Button(\"Chop to Pads…\")"))
        let proBlock = try! #require(menu.range(of: "\n        if pro {"))
        #expect(entry.lowerBound < proBlock.lowerBound,
                "Chop to Pads… fell inside the Pro-only block — invisible in Simple")

        // The menu selects the clip it named before opening the card, or the
        // card would resolve a DIFFERENT clip than the one right-clicked.
        let content = Self.code("DAWApp/ContentView.swift")
        #expect(content.contains("model.openChopToPads(clipID: clip.id)"))
        let staging = Self.code("DAWApp/PadGridStaging.swift")
        #expect(staging.contains("func openChopToPads(clipID: UUID)"))
        #expect(staging.contains("_ = clickClip(id: clipID, modifiers: .none)"))
    }

    /// m39-levels-2 — the UP / CENTRED toggle. The model is tested headless in
    /// `PadGridTests`; what only a site test can see is that the chips are
    /// MOUNTED beside LEVELS, that a click reaches the model, and that the
    /// staging seam can drive and read it. A toggle declared and never placed,
    /// or placed and wired to nothing, would pass every model test.
    @Test("⛔ the UP/CENTRED toggle is mounted beside LEVELS, wired, and drivable from staging")
    func spreadDirectionToggleIsWired() {
        let view = Self.code("DAWApp/Components/PadGridView.swift")
        // MOUNTED, beside the button it qualifies — not merely declared.
        let row = try! #require(view.range(of: "HStack(spacing: 6) {"))
        let rowBody = String(view[row.upperBound...].prefix(160))
        #expect(rowBody.contains("spreadDirectionToggle"))
        #expect(rowBody.contains("levelsButton"))
        // One chip per direction, and a click calls the callback.
        #expect(view.contains("ForEach(SixteenLevels.Direction.allCases"))
        #expect(view.contains("Button { onSetSpreadDirection(value) }"))
        // Dead exactly when LEVELS is, and it says why.
        #expect(view.contains(".disabled(spreadDirectionUnavailableReason != nil)"))

        // The strip hands the view the MODEL's reading and the MODEL's setter.
        let strip = Self.code("DAWApp/Components/MusicalKeyboardStrip.swift")
        #expect(strip.contains("spreadDirection: padGrid.spreadDirection,"))
        #expect(strip.contains(
            "spreadDirectionUnavailableReason: padGrid.spreadDirectionUnavailableReason"))
        #expect(strip.contains("onSetSpreadDirection: { padGrid.setSpreadDirection($0) }"))

        // Staging parses it, refuses an unknown word, and reports it back.
        let staging = Self.code("DAWApp/PadGridStaging.swift")
        #expect(staging.contains("params[\"spreadDirection\"]?.stringValue"))
        #expect(staging.contains("SixteenLevels.Direction(rawValue: raw)"))
        #expect(staging.contains("padGrid.setSpreadDirection(value)"))
        #expect(staging.contains("\"spreadDirection\": .string(padGrid.spreadDirection.rawValue)"))
        // ⚠️ ORDER: the direction is applied BEFORE `levels`/`levelsFromPad`,
        // so one call can choose CENTRED and make the spread in that direction.
        let direction = try! #require(staging.range(of: "params[\"spreadDirection\"]"))
        let levels = try! #require(staging.range(of: "params[\"levels\"]"))
        let fromPad = try! #require(staging.range(of: "params[\"levelsFromPad\"]"))
        #expect(direction.lowerBound < levels.lowerBound)
        #expect(direction.lowerBound < fromPad.lowerBound)
    }

    @Test("⛔ the panel's refusal is DERIVED, never a stored copy that can go stale")
    func panelRefusalHasNoStoredMirror() {
        // A stored `refusal` existed, was written by `runChop`, and was read by
        // nothing — while the card and the wire both asked `blockingRefusal`.
        // Two answers to one question, one of which goes stale the moment the
        // selection changes.
        let model = Self.code("DAWAppKit/PadGridModel.swift")
        #expect(!model.contains("var refusal: PadChopRefusal?"))
        #expect(model.contains("public var blockingRefusal: PadChopRefusal?"))
        // The STORE's sentence is kept, because it cannot be recomputed.
        #expect(model.contains("public private(set) var lastRefusal: String?"))
    }
}
