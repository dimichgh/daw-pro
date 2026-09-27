import DAWAppKit
import DAWCore
import Foundation
import Testing

/// m23-ap Phase 2 — **THE PRESET DOOR IS ACTUALLY CLICKABLE, AND ACTUALLY
/// BOUND.**
///
/// The preset actions existed as data (`PitchCorrectionPreset`), as a store op
/// (`ProjectStore.autoCorrectClipPitch`), as a wire verb
/// (`clip.autoCorrectPitch`) and as an MCP tool — and as nothing a person could
/// click. This suite pins the click.
///
/// ⚠️⚠️ `Sources/DAWApp` has no test target, and this door's failure mode is the
/// quiet one: a `Button` wired to a closure whose default is `{ _ in }` draws
/// perfectly, highlights perfectly, dismisses the menu perfectly and does
/// NOTHING — a plausible-looking valid answer, which is this tree's
/// characteristic failure rendered in pixels. Nothing in a build, a warning
/// count or a headless test would say so.
///
/// `PadGridSiteTests`' shape verbatim, including the rule that matters most
/// here: assertions run against **comment-stripped** source, because the menu
/// entry below documents its own wiring in prose that would satisfy a naive
/// grep — including the literal words `allCases` and `offeredInUI`, which one
/// assertion here is specifically about.
/// W7-NTU (W7-D2's item 3) — a `detectPitch` stub, so the replace card's
/// store leg runs the REAL `ProjectStore.autoCorrectClipPitch`: the
/// `ClipRenderSignatureTests` fake (itself `PitchCorrectionWriterTests`'),
/// copied because test files cannot share a private type.
@MainActor
private final class TuneDoorFakeDetectEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    var stubResult: PitchDetectionResult
    var detectCalls = 0

    init(stubResult: PitchDetectionResult) { self.stubResult = stubResult }

    func detectPitch(inFileAt url: URL, fromSeconds: Double, durationSeconds: Double,
                     confidenceThreshold: Double,
                     silenceFloorDbfs: Double) async throws -> PitchDetectionResult {
        detectCalls += 1
        return stubResult
    }

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
}

@Suite("Tune Vocal door wiring (m23-ap Phase 2)")
struct PitchTuneDoorSiteTests {

    // MARK: - Source access (PadGridSiteTests' reader, verbatim)

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
    /// different reason. This proves the reader reaches real code first, and
    /// that it really does strip.
    @Test("the source reader reaches real code (positive control)")
    func readerWorks() {
        let strip = Self.code("DAWApp/PitchCorrectionStaging.swift")
        #expect(strip.contains("extension AppModel"))
        #expect(strip.count > 500)
        // These phrases exist ONLY in comments there.
        #expect(strip.contains("leaves their selection theirs") == false)
        #expect(strip.contains("only the pixels have no room to explain") == false)
        // ⚠️ THIS IS NOT A BAD-PATH PROBE, AND THE `PadGridSiteTests` LINE IT WAS
        // COPIED FROM CLAIMED TO BE ONE WHILE RE-READING THE SAME FILE. A real
        // negative control would read a path that does not exist — which
        // `code(_:)` answers by calling `Issue.record`, i.e. by failing this
        // test, so it cannot be asserted here without `withKnownIssue`. What
        // this second read actually shows is that the reader is deterministic:
        // the same path twice gives the same non-empty answer. Said plainly,
        // because a suite whose whole thesis is that prose lies must not open
        // with prose that does.
        #expect(Self.code("DAWApp/PitchCorrectionStaging.swift").count > 500)
    }

    // MARK: - What the menu draws

    @Test("⛔ the Tune Vocal entry exists, is AUDIO-ONLY, and sits OUTSIDE the Pro block")
    func tuneVocalIsInTheClipMenuAndNotProGated() {
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")

        #expect(lanes.contains("Menu(\"Tune Vocal\")"))
        #expect(lanes.contains("Button(preset.displayName) { onTuneVocal(preset) }"))
        #expect(lanes.contains("onTuneVocal: { preset in onTuneVocal(clip, preset) }"))

        // AUDIO ONLY, and hidden rather than offered-then-errored (design §6.5:
        // "no preset chip on a MIDI clip, even greyed"). It SHARES Chop to Pads'
        // gate, so this is the same literal predicate that entry already had.
        #expect(lanes.contains("if !clip.isMIDI, clip.audioFileURL != nil {"))

        // ⛔ THE LOAD-BEARING ONE: the entry must sit BEFORE the `if pro {`
        // block, or it vanishes in the density built for beginners — the exact
        // shape of the bug m23-cf fixed for Delete, and design §6.2's explicit
        // instruction ("tuning a vocal is not expert chrome").
        // ⚠️ Anchored INSIDE `contextMenu`: `if pro {` appears several times in
        // this 4k-line view, and comparing against the first one in the file
        // measures a position in an unrelated builder and "passes" nothing.
        let menuStart = try! #require(
            lanes.range(of: "private var contextMenu: some View {"))
        let menu = String(lanes[menuStart.upperBound...])
        let entry = try! #require(menu.range(of: "Menu(\"Tune Vocal\")"))
        let proBlock = try! #require(menu.range(of: "\n        if pro {"))
        #expect(entry.lowerBound < proBlock.lowerBound,
                "Tune Vocal fell inside the Pro-only block — invisible in Simple, which is the density the beginner who most needs a one-click tuning is in")
    }

    /// ⛔ **THE NAMED LIST, READ — never `allCases`, never retyped.**
    ///
    /// `PitchCorrectionPreset.offeredInUI` is the one place the rule "offer
    /// only what the render can honour" is enforced. It withheld Hard Tune
    /// while the render built every curve with `contour: []` (the flattening
    /// resolved to nothing — a control whose label promised one result and
    /// whose mechanism delivered another). Since contour-to-render
    /// (2026-09-24) the render shapes against the detected contour, Hard Tune
    /// is measured distinct from Tight on the rendered audio, and the list is
    /// all four. The draw site must STILL read the list: a view drawing
    /// `allCases` would silently re-offer anything the list withholds in
    /// future, and one retyping the names as literals would drift from it.
    ///
    /// `PitchCorrectionPresetTests.uiDoorOffersEveryPresetTheRenderHonours`
    /// pins the VALUE of the list and its reason; this pins that the pixels
    /// read it.
    @Test("⛔ the menu draws offeredInUI — the named list, never allCases")
    func theMenuDrawsOfferedInUINotAllCases() {
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        #expect(lanes.contains("ForEach(PitchCorrectionPreset.offeredInUI)"))
        #expect(lanes.contains("PitchCorrectionPreset.allCases") == false,
                "the clip menu is drawing allCases — it would offer whatever `offeredInUI` withholds, bypassing the one place that rule lives")
        // And no hand-typed twin of the list: the preset names must NOT appear
        // as literal button labels beside the ForEach.
        #expect(lanes.contains("Button(\"Hard Tune\")") == false)
        #expect(lanes.contains("Button(\"Gentle\")") == false,
                "the presets are typed out as literal buttons — the list has a second home and they will disagree")
    }

    @Test("⛔ each preset carries its own novice sentence, and Remove Tuning is offered only when there IS tuning")
    func labelsAndRemoveTuningAreHonest() {
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        // Design §6.1: "use these strings verbatim" — the label is the preset's
        // own `displayName` and the tooltip its own `summary`, never re-worded
        // at the draw site.
        #expect(lanes.contains(".help(preset.summary)"))
        // Offered ONLY when the clip carries edits. A "Remove Tuning" over a
        // never-tuned clip is a control whose only possible outcome is nothing
        // happening — and, until the note view lands, its presence is the one
        // thing on screen that says the tuning took.
        #expect(lanes.contains("if clip.pitchEdits != nil {"))
        #expect(lanes.contains("Button(\"Remove Tuning\") { onClearPitchEdits() }"))
    }

    // MARK: - What the menu calls

    @Test("⛔ the door calls the store method the WIRE calls — no parallel path, no second policy")
    func theDoorUsesTheWiresOwnFunnel() {
        let staging = Self.code("DAWApp/PitchCorrectionStaging.swift")
        #expect(staging.contains("func tuneVocalFromContextMenu(clipID: UUID, preset: PitchCorrectionPreset)"))
        #expect(staging.contains("func clearClipTuningFromContextMenu(clipID: UUID)"))

        // ⭐ ONE STORE METHOD (design §6.2). Not a re-implementation of the
        // policy, not a hand-built PitchAutoCorrectOptions: the preset's OWN
        // `options()`, whose scale defaults to chromatic — which is exactly what
        // `clip.autoCorrectPitch` builds when no key is named.
        #expect(staging.contains("self.store.autoCorrectClipPitch("))
        #expect(staging.contains("options: preset.options()"))
        #expect(staging.contains("store.clearClipPitchEdits(clipId: clipID)"))
        // No second scale resolution in the view tier.
        #expect(staging.contains("PitchCorrectionScale") == false,
                "the app tier is resolving a scale — design §6.2 puts that in the store so all three doors inherit one answer")
        #expect(staging.contains("PitchAutoCorrectOptions(") == false,
                "the app tier is building its own options — the preset's own options() is the only home for those numbers")
    }

    @Test("⛔ a refusal is SHOWN, and a success that did nothing is shown too")
    func refusalsAndSilentSuccessesReachTheUser() {
        let staging = Self.code("DAWApp/PitchCorrectionStaging.swift")
        // `try?` here would turn engineUnavailable, a file that vanished, a comp
        // member and a clip deleted mid-detection into a click that does nothing
        // and says nothing.
        #expect(staging.contains("try? store.") == false)
        #expect(staging.contains("try? self.store.") == false)
        #expect(staging.contains("presentArrangeSplitRefusal(error, clipID: clipID)"))
        // ⛔ AND THE SILENT SUCCESS. `autoCorrectClipPitch` returns normally with
        // `pitchEdits == nil` when the detector found no voiced runs at all. A
        // door that only handled `catch` would show nothing for the single most
        // likely disappointing outcome: tuning an instrumental.
        #expect(staging.contains("if clip.pitchEdits == nil {"),
                "a correction that found nothing to correct returns normally — without this branch the user clicks Natural on an instrumental and the app says nothing at all")
    }

    // MARK: - The binding

    /// ⛔⛔ **THE ASSERTION THE REST OF THIS SUITE CANNOT MAKE: THE BUTTON IS
    /// PLUGGED IN.**
    ///
    /// `TimelineLanesView.onTuneVocal` / `onClearPitchEdits` follow the
    /// `onChopToPads` precedent, which means they default to a no-op closure.
    /// That default is the right shape for previews and headless callers and the
    /// WRONG shape to ship: unbound, the menu entry draws, highlights, dismisses
    /// and does nothing — and every other assertion in this file passes anyway,
    /// because every other assertion is about a file that is not `ContentView`.
    ///
    /// This test was written RED, on purpose, while `ContentView.swift` was
    /// owned by a concurrent agent: the two lines below did not exist yet and
    /// the failure message named them verbatim. They landed. Keep the message
    /// that way — the next person to delete the binding should be handed the
    /// patch, not a diff.
    @Test("⛔ ContentView binds the door to the AppModel funnels — without this the menu entry does nothing")
    func contentViewBindsTheDoor() {
        let content = Self.code("DAWApp/ContentView.swift")
        #expect(content.contains("model.openChopToPads(clipID: clip.id)"),
                "POSITIVE CONTROL FAILED: this reader cannot even see the binding NEXT to the missing one, so the assertions below would fail for the wrong reason")
        #expect(content.contains("model.tuneVocalFromContextMenu(clipID: clip.id, preset: preset)"),
                "ContentView does not bind onTuneVocal — the Tune Vocal menu entry draws and does NOTHING. Add `onTuneVocal: { clip, preset in model.tuneVocalFromContextMenu(clipID: clip.id, preset: preset) },` to the TimelineLanesView( call, beside onChopToPads.")
        #expect(content.contains("model.clearClipTuningFromContextMenu(clipID: clip.id)"),
                "ContentView does not bind onClearPitchEdits — Remove Tuning draws and does NOTHING. Add `onClearPitchEdits: { clip in model.clearClipTuningFromContextMenu(clipID: clip.id) },` to the TimelineLanesView( call, beside onChopToPads.")
        #expect(content.contains("model.openPitchEditor(clipID: clip.id)"),
                "ContentView does not bind onOpenPitchEditor — the note editor pane exists and NOTHING CAN OPEN IT. Add `onOpenPitchEditor: { clip in model.openPitchEditor(clipID: clip.id) },` to the TimelineLanesView( call.")
    }

    // MARK: - C-F3: a preset must ask before it throws away HAND edits (F22)

    /// The text of one member of `extension AppModel`, from its signature to the
    /// next member at the same indent. A `contains` over the WHOLE file cannot
    /// say which function a call sits in — and "the store call is behind the
    /// gate" is a claim about exactly that.
    private static func member(_ signature: String, in source: String) -> String {
        guard let start = source.range(of: signature) else {
            Issue.record("no member `\(signature)` in the source read")
            return ""
        }
        let rest = source[start.upperBound...]
        var end = rest.endIndex
        for ender in ["\n    func ", "\n    private func ", "\n    @discardableResult", "\n}\n"] {
            if let hit = rest.range(of: ender), hit.lowerBound < end { end = hit.lowerBound }
        }
        return String(rest[..<end])
    }

    /// ⛔⛔ **THE DESIGN'S PLANTED DEFECT, WRITTEN RED FIRST: the menu calls the
    /// preset WITHOUT a confirm on a hand-edited set.**
    ///
    /// `autoCorrectClipPitch` REPLACES the clip's whole note table. Before
    /// C-F3 both preset doors (the clip menu's Tune Vocal ▸ <preset> and the
    /// note editor's preset chips) went straight to it, so one click erased
    /// every note the user had moved or split by hand, and said nothing.
    ///
    /// The funnel must ask the gate FIRST, and the store call must be reachable
    /// only through the gate's "apply now" answer or the person's own
    /// "Replace my edits". The no-nag half (a clip holding only a preset's own
    /// output switches presets with no dialog) is behaviour, not shape: it is
    /// pinned by the signal's tests in `PitchCorrectionWriterTests` and by the
    /// gate's spy tests below.
    @Test("⛔ C-F3 — the preset funnel asks the gate before the store, and only a yes reaches autoCorrectClipPitch")
    func presetFunnelAsksBeforeReplacingHandEdits() {
        let staging = Self.code("DAWApp/PitchCorrectionStaging.swift")
        // POSITIVE CONTROL: the reader reaches the funnel it is about to judge.
        #expect(staging.contains("func tuneVocalFromContextMenu(clipID: UUID, preset: PitchCorrectionPreset)"),
                "POSITIVE CONTROL FAILED: the funnel is not where this test looks, so every assertion below would fail for the wrong reason")

        let funnel = Self.member("func tuneVocalFromContextMenu(clipID: UUID, preset: PitchCorrectionPreset)",
                                 in: staging)
        #expect(funnel.contains("pitchPresetReplaceGate.request("),
                "the preset funnel never asks the gate — a preset click over hand edits erases them with no warning (F22)")
        #expect(funnel.contains("autoCorrectClipPitch(") == false,
                "the preset funnel calls the store DIRECTLY — the confirm can be skipped. The store call belongs in `applyTuningPreset`, reached only by `.applyNow` or a confirmed replace")
        #expect(funnel.contains("case .applyNow:") && funnel.contains("applyTuningPreset(clipID: clipID, preset: preset)"),
                "the funnel's apply-now branch does not apply — a clip with no hand edits would stop tuning at all")

        // The ONE place the store is called, and the two doors into it.
        let apply = Self.member("private func applyTuningPreset(clipID: UUID, preset: PitchCorrectionPreset)",
                                in: staging)
        #expect(apply.contains("self.store.autoCorrectClipPitch("))
        let confirm = Self.member("func confirmPresetReplace()", in: staging)
        #expect(confirm.contains("pitchPresetReplaceGate.confirm()") && confirm.contains("applyTuningPreset("),
                "\"Replace my edits\" does not apply the preset it was asked about")
        let cancel = Self.member("func cancelPresetReplace()", in: staging)
        #expect(cancel.contains("pitchPresetReplaceGate.cancel()"))
        #expect(cancel.contains("applyTuningPreset(") == false,
                "Cancel applies the preset — the one outcome Cancel must never have")

        // The gate reads THE signal — the store's own "hand-edited since the last
        // preset" answer, never a second estimate of it.
        let gate = Self.code("DAWAppKit/PitchPresetReplaceGate.swift")
        #expect(gate.contains("hasHandEditsSinceAutoCorrect"),
                "the gate does not consult PitchEditSet.hasHandEditsSinceAutoCorrect — it is deciding on something else")
        // And AppModel owns one gate, so both doors share its one pending request.
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("let pitchPresetReplaceGate = PitchPresetReplaceGate()"))
    }

    /// ⛔ **A GATE THAT HOLDS A REQUEST WITH NOTHING ON SCREEN IS A PRESET CLICK
    /// THAT DOES NOTHING.** The card must be mounted in the WINDOW (an `NSAlert`
    /// or a `.confirmationDialog` is a stock grey panel AND is invisible to
    /// `debug.captureUI`), bound to the pending request, with its two answers
    /// wired to the funnels above.
    ///
    /// The binding lives in the card's own file (`presetReplaceConfirmOverlay`)
    /// because `ContentView.body`'s modifier chain is at the type-checker's
    /// limit: the inline `.overlay { if let … }` this test first asked for made
    /// `swift build` fail with "unable to type-check this expression in
    /// reasonable time". ContentView must still CALL the mount. Without that one
    /// line, every other assertion here passes over a card nothing draws.
    @Test("⛔ C-F3 — ContentView mounts the replace card on the pending request, and both answers are wired")
    func replaceCardIsMountedAndWired() {
        let content = Self.code("DAWApp/ContentView.swift")
        #expect(content.contains("model.openChopToPads(clipID: clip.id)"),
                "POSITIVE CONTROL FAILED: this reader cannot see a binding that exists, so the assertions below would fail for the wrong reason")
        #expect(content.contains(".presetReplaceConfirmOverlay(model)"),
                "ContentView never mounts the replace card — the gate would hold the click and the user would see nothing happen")

        let card = Self.code("DAWApp/PresetReplaceConfirmCard.swift")
        #expect(card.contains("if let request = model.pitchPresetReplaceGate.pending {"),
                "the mount is not bound to the gate's pending request")
        #expect(card.contains("PresetReplaceConfirmCard("))
        #expect(card.contains("onReplace: { model.confirmPresetReplace() }"))
        #expect(card.contains("onCancel: { model.cancelPresetReplace() }"))
        // The words come from ONE home the unit tests read (`PitchPresetReplaceCopy`),
        // never retyped in the view.
        #expect(card.contains("PitchPresetReplaceCopy("))
        #expect(card.contains("copy.confirmLabel") && card.contains("copy.cancelLabel"))
        #expect(card.contains("\"Replace my edits\"") == false,
                "the card retypes its own button label — the copy has a second home and the two will drift")
        // Esc cancels; the DESTRUCTIVE answer is never the default (Return must
        // not erase anybody's work).
        #expect(card.contains(".keyboardShortcut(.cancelAction)"))
        #expect(card.contains(".keyboardShortcut(.defaultAction)") == false)
        #expect(card.contains("role: .destructive"))
    }

    @Test("⛔ C-F3 — debug.tuneVocal drives the MENU'S funnel, never the store, and stays off the public command table")
    func tuneVocalSeamDrivesTheMenuFunnel() {
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("case \"debug.tuneVocal\":"))
        let staging = Self.code("DAWApp/PitchCorrectionStaging.swift")
        let seam = Self.member("func tuneVocalDebug(_ params: [String: JSONValue]) throws -> JSONValue",
                               in: staging)
        #expect(seam.contains("tuneVocalFromContextMenu(clipID: clipID, preset: preset)"))
        #expect(seam.contains("confirmPresetReplace()") && seam.contains("cancelPresetReplace()"))
        #expect(seam.contains("autoCorrectClipPitch(") == false,
                "the seam calls the store directly — a capture through it would photograph a door no person walks through")
        let commands = Self.code("DAWControl/Commands.swift")
        #expect(commands.contains("\"clip.autoCorrectPitch\""),
                "POSITIVE CONTROL FAILED: this reader cannot see a verb that is in the table")
        #expect(commands.contains("debug.tuneVocal") == false,
                "debug.tuneVocal joined the public table — it would move the wire count and hand agents a view-shaped route")
    }

    // MARK: - C-F3: the gate's BEHAVIOUR (spy tests, not greps)
    //
    // `DAWApp` has no test target, so the decision lives in the headless
    // `PitchPresetReplaceGate` and is exercised here. Not a `@MainActor` suite:
    // `MainActorOccupancySiteTests` caps those. Each test is `@MainActor` itself.

    /// A preset's own output, stamped as the store stamps it.
    private static func presetOutput() -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 225,
                        detectedConfidence: 0.9, pitchOffsetCents: -33),
            NoteSegment(startSeconds: 1.2, endSeconds: 2, detectedHz: 250,
                        detectedConfidence: 0.9, pitchOffsetCents: -17),
        ], retuneMs: 110).stampedAsAutoCorrectOutput()
    }

    /// The same set after one note was dragged by hand.
    private static func handEdited() -> PitchEditSet {
        var set = presetOutput()
        set.segments[0].pitchOffsetCents = 12
        return set
    }

    @Test("C-F3 gate: a preset's own output applies NOW — no card, nothing held (the comparison workflow)")
    @MainActor
    func gateLetsPresetSwitchesThrough() {
        let gate = PitchPresetReplaceGate()
        let clip = UUID()
        for preset in PitchCorrectionPreset.offeredInUI {
            #expect(gate.request(preset, clipID: clip, clipName: "Lead",
                                 current: Self.presetOutput()) == .applyNow,
                    "switching to \(preset.displayName) over a preset's own output asked first — the comparison workflow would be nagged on every click")
            #expect(gate.pending == nil)
        }
        // A clip with no tuning has nothing to lose.
        #expect(gate.request(.natural, clipID: clip, clipName: "Lead", current: nil) == .applyNow)
        #expect(gate.pending == nil)
    }

    @Test("C-F3 gate: hand edits HOLD the click, and Replace hands back exactly that request, once")
    @MainActor
    func gateHoldsTheClickAndReplacesOnce() {
        let gate = PitchPresetReplaceGate()
        let clip = UUID()
        #expect(gate.request(.tight, clipID: clip, clipName: "Lead",
                             current: Self.handEdited()) == .askFirst,
                "a preset over hand edits applied without asking (F22)")
        // W7-NTU — the held request carries what the preset will do to the
        // settings, read from the set AT THE CLICK (this fixture is a vocal
        // tuned before natural tuning: all three change).
        let asked = PitchPresetReplaceRequest(clipID: clip, clipName: "Lead", preset: .tight,
                                              settings: PitchPresetReplaceSettings(current: Self.handEdited()))
        #expect(asked.settings.changed.count == 3)
        #expect(gate.pending == asked)
        #expect(gate.confirm() == asked, "Replace applied something other than what the card showed")
        #expect(gate.pending == nil)
        #expect(gate.confirm() == nil, "a second press applied a preset nobody was asked about")
    }

    @Test("C-F3 gate: Cancel applies NOTHING, and a Replace after Cancel applies nothing either")
    @MainActor
    func gateCancelAppliesNothing() {
        let gate = PitchPresetReplaceGate()
        #expect(gate.request(.hardTune, clipID: UUID(), clipName: "Lead",
                             current: Self.handEdited()) == .askFirst)
        gate.cancel()
        #expect(gate.pending == nil)
        #expect(gate.confirm() == nil, "a Replace after Cancel still applied the preset")
    }

    @Test("C-F3 card words: for a novice — the preset, the clip, only the edits that exist, and Undo")
    func replaceCopyIsHonest() {
        let copy = PitchPresetReplaceCopy(
            PitchPresetReplaceRequest(clipID: UUID(), clipName: "Lead Vocal", preset: .natural))
        #expect(copy.title == "Replace your hand edits?")
        #expect(copy.confirmLabel == "Replace my edits")
        #expect(copy.cancelLabel == "Cancel")
        #expect(copy.body.contains("Natural"), "the card does not name the preset that was clicked")
        #expect(copy.body.contains("“Lead Vocal”"))
        #expect(copy.body.contains(PitchPresetReplaceCopy.handEdits))
        #expect(copy.undoNote.contains("Undo (⌘Z)"))
        // W7-NTU (W7-D2's item 3) — every item says "any": the card also asks
        // when only a SETTING changed since the preset, and then "the notes you
        // moved" would claim edits nobody made.
        #expect(PitchPresetReplaceCopy.handEdits
                == "any note you moved or split by hand, any note you made deeper or brighter, "
                + "any wobble you changed and any pitch line you drew")
        #expect(!copy.body.contains("the notes you moved"))
        // ONLY what a hand can do today. A warning that lists losses nobody could
        // have made teaches people to stop reading warnings. No jargon either.
        // C5a-4b — "wobble" left this list when the Wobble tool shipped: a
        // wobble is now a hand edit a preset erases (vibrato-handle V14), named
        // in the palette's own word; "vibrato" stays banned as jargon.
        // C5b-4b (2026-09-27) — "drawn" left this list the same way when ⌘-drag
        // drawing shipped: a drawn pitch line is now a hand edit a preset erases.
        // "shape" stays banned as jargon.
        for word in ["timing", "shape", "vibrato", "segment", "cents", "preset"] {
            #expect(!copy.body.lowercased().contains(word),
                    "the card's sentence says '\(word)' — either an edit nobody can make yet, or a word a non-musician does not know")
        }
        // An unnamed clip gets words, not a pair of empty quotes.
        let unnamed = PitchPresetReplaceCopy(
            PitchPresetReplaceRequest(clipID: UUID(), clipName: "", preset: .gentle))
        #expect(unnamed.body.contains("this clip"))
        #expect(!unnamed.body.contains("“”"))
    }

    /// ⚠️ TRIPWIRE. The card names moves and splits because those are the only
    /// hand edits the note editor can make. When it gains a tool (drawn shapes,
    /// timing), the sentence must grow with it. The signal needs no change,
    /// because any write already reads as a hand edit.
    @Test("C-F3 tripwire: the card names every kind of hand edit the editor's tools make")
    func replaceCopyNamesEveryEditorTool() {
        let tools = PitchEditorTool.allCases.map(\.rawValue)
        #expect(PitchEditorTool.allCases == [.pointer, .scissors, .wobble, .voice],
                """
                The note editor gained a tool (\(tools)). "Replace your hand edits?" \
                still names only moves, splits, wobbles and voices: add the new edit's \
                words to PitchPresetReplaceCopy.handEdits, then update this list.
                """)
        #expect(PitchEditorTool.pointer.label == "Move" && PitchEditorTool.scissors.label == "Split")
        #expect(PitchEditorTool.wobble.label == "Wobble")
        #expect(PitchEditorTool.voice.label == "Voice")
        #expect(PitchPresetReplaceCopy.handEdits.contains("moved"))
        #expect(PitchPresetReplaceCopy.handEdits.contains("split"))
        // C5a-4b — the Wobble tool's edit, in the palette's own word.
        #expect(PitchPresetReplaceCopy.handEdits.contains("wobble"))
        // W7-NTU U3 — the Voice tool's edit, by what it DOES (its help's own
        // words): "voice" alone would read as the header's "Keep voice size",
        // which a preset keeps.
        #expect(PitchPresetReplaceCopy.handEdits.contains("deeper or brighter"))
        #expect(PitchEditorGestureRouter.commandDraws(in: .voice),
                "⌘ no longer draws in Voice: re-read what a preset erases and fix this card and this test")
        // C5b-4b — drawing is a ⌘ MODIFIER, not a palette slot, so the list above
        // cannot see it. Pin it here: while ⌘ draws, the card must name the line.
        #expect(PitchEditorGestureRouter.commandDraws(in: .pointer),
                "⌘ no longer draws in Move: re-read what a preset erases and fix this card and this test")
        #expect(PitchPresetReplaceCopy.handEdits.contains("pitch line you drew"))
    }

    // MARK: - W7-NTU (W7-D2's item 3): the card when only a SETTING changed

    /// A set with the notes of `presetOutput()` and the three settings spelled
    /// out, stamped or not.
    private static func settings(formant: Double?, consonants: PitchEditSet.ConsonantProtection,
                                 slope: Double) -> PitchEditSet {
        var set = presetOutput()
        set.formantCorrection = formant
        set.consonantProtection = consonants
        set.transitionSlopeCentsPerSecond = slope
        return set
    }

    /// Planted and seen red (W7-NTU P-card-keep): a kept voice size read as
    /// "changes to 100%".
    @Test("W7-D2 item 3 — what the card says about each SETTING, read from the set at the click: nothing at the preset's own values; a kept pick is said to stay; Slides back to Smooth; an old vocal's three all change")
    func replaceCardSettingsSentences() {
        let smooth = PitchEditSet.defaultTransitionSlope
        func sentence(_ set: PitchEditSet) -> String {
            PitchPresetReplaceCopy.settingsSentence(PitchPresetReplaceSettings(current: set))
        }
        // A preset's own values: nothing to say.
        #expect(sentence(Self.settings(formant: 1, consonants: .on, slope: smooth)) == "")
        #expect(PitchPresetReplaceSettings(current: nil) == .none)
        // Each kept pick, alone and together.
        #expect(sentence(Self.settings(formant: 0.6, consonants: .on, slope: smooth))
                == "“Keep voice size” stays as it is.")
        #expect(sentence(Self.settings(formant: 1, consonants: .offByChoice, slope: smooth))
                == "“Consonants” stays as it is.")
        #expect(sentence(Self.settings(formant: 0, consonants: .offByChoice, slope: smooth))
                == "“Keep voice size” and “Consonants” stay as they are.")
        // A Slides pick is not carried.
        #expect(sentence(Self.settings(formant: 1, consonants: .on,
                                       slope: PitchEditorSlideStep.quick.centsPerSecond))
                == "“Slides” changes to Smooth.")
        #expect(sentence(Self.settings(formant: 0.6, consonants: .offByChoice,
                                       slope: PitchEditorSlideStep.slow.centsPerSecond))
                == "“Keep voice size” and “Consonants” stay as they are. “Slides” changes to Smooth.")
        // A vocal tuned before natural tuning: the preset seeds all three.
        #expect(sentence(Self.settings(formant: nil, consonants: .offByDefault, slope: 0))
                == "“Keep voice size” changes to 100%, “Consonants” to ON and “Slides” to Smooth.")
        // …and the card carries the sentence after its note list, and no jargon.
        let copy = PitchPresetReplaceCopy(PitchPresetReplaceRequest(
            clipID: UUID(), clipName: "Lead", preset: .natural,
            settings: PitchPresetReplaceSettings(current: Self.settings(
                formant: 0.6, consonants: .on, slope: PitchEditorSlideStep.quick.centsPerSecond))))
        #expect(copy.body.hasSuffix("any pitch line you drew. “Keep voice size” stays as it is. "
                                    + "“Slides” changes to Smooth."))
        for word in ["timing", "shape", "vibrato", "segment", "cents", "preset", "formant"] {
            #expect(!copy.body.lowercased().contains(word), "the card says '\(word)'")
        }
    }

    /// ⚠️ TRIPWIRE for "“Keep voice size” stays as it is": true only while no
    /// preset a person can click names a voice size of its own (§1(e): a named
    /// one beats the carried amount).
    @Test("W7-D2 item 3 tripwire: no preset a person can click names a voice size of its own, so a kept one stays")
    func noOfferedPresetNamesAVoiceSize() {
        for preset in PitchCorrectionPreset.offeredInUI {
            #expect(preset.options().formantCorrection == nil,
                    "\(preset.displayName) now names a voice size: the card's \"stays as it is\" is false for it")
        }
    }

    /// The stub the store's detection returns: two voiced runs, 225 Hz and
    /// 250 Hz (`ClipRenderSignatureTests.twoNotesOffPitch`, copied).
    private static func twoNotesOffPitch() -> PitchDetectionResult {
        var frames: [ClipPitchFrame] = []
        for i in 0..<4 {
            frames.append(ClipPitchFrame(timeSeconds: Double(i) * 0.016, frequencyHz: 225.0,
                                         confidence: 0.95, levelDbfs: -12, absence: nil))
        }
        frames.append(ClipPitchFrame(timeSeconds: 0.064, frequencyHz: nil, confidence: 0.1,
                                     levelDbfs: -70, absence: .belowConfidence))
        for i in 0..<4 {
            frames.append(ClipPitchFrame(timeSeconds: 0.08 + Double(i) * 0.016, frequencyHz: 250.0,
                                         confidence: 0.95, levelDbfs: -12, absence: nil))
        }
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count,
            voicedFrameCount: voiced,
            voicedFraction: Double(voiced) / Double(frames.count),
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: 0.15,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
    }

    /// Planted and seen red (W7-NTU P-card-store): the card's Slides face read
    /// from the CURRENT smoothness ("Quick") instead of the seed's.
    @Test("⭐ W7-D2 item 3 — through the REAL store: settings changed after a preset make the card ask, its words stay true, and the preset then does exactly what the card said; a note made deeper does not survive it")
    @MainActor
    func replaceCardSettingsMatchTheStore() async throws {
        // A REAL file: the preset's detection checks `fileExists` first.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w7ntu-card-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let clip = Clip(name: "Lead", startBeat: 0, lengthBeats: 8, audioFileURL: url)
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let engine = TuneDoorFakeDetectEngine(stubResult: Self.twoNotesOffPitch())
        store.engine = engine
        func stored() throws -> PitchEditSet { try #require(store.tracks[0].clips[0].pitchEdits) }

        // 1. A preset's own output: no card (the comparison workflow).
        _ = try await store.autoCorrectClipPitch(clipId: clip.id,
                                                 options: PitchCorrectionPreset.natural.options())
        let gate = PitchPresetReplaceGate()
        #expect(gate.request(.tight, clipID: clip.id, clipName: "Lead", current: try stored()) == .applyNow)

        // 2. Only the SETTINGS change: no note is touched.
        let notes = try stored().segments
        _ = try store.setClipFormantCorrection(clipId: clip.id, amount: 0.6)
        _ = try store.setClipConsonantProtection(clipId: clip.id, enabled: false)
        _ = try store.setClipPitchTransitionSmoothness(
            clipId: clip.id, centsPerSecond: PitchEditorSlideStep.quick.centsPerSecond)
        #expect(try stored().segments == notes, "a setting moved a note")

        // 3. The card asks (W7-D2's consequence), and every word is true.
        #expect(gate.request(.natural, clipID: clip.id, clipName: "Lead", current: try stored()) == .askFirst)
        let request = try #require(gate.pending)
        #expect(request.settings == PitchPresetReplaceSettings(
            kept: [.voiceSize, .consonants],
            changed: [PitchPresetReplaceSettings.Change(row: .slides, to: "Smooth")]))
        let copy = PitchPresetReplaceCopy(request)
        #expect(copy.body.contains("including any note you moved or split by hand"))
        #expect(copy.body.hasSuffix("“Keep voice size” and “Consonants” stay as they are. "
                                    + "“Slides” changes to Smooth."))

        // 4. "Replace my edits": the REAL preset runs, and the store holds what
        // the card said.
        let held = try #require(gate.confirm())
        _ = try await store.autoCorrectClipPitch(clipId: held.clipID, options: held.preset.options())
        let after = try stored()
        #expect(after.formantCorrection == 0.6, "“Keep voice size” did not stay as it was")
        #expect(after.consonantProtection == .offByChoice, "“Consonants” did not stay as it was")
        let landed = try #require(PitchEditorSlideStep.step(atCentsPerSecond: after.transitionSlopeCentsPerSecond),
                                  "the preset left a smoothness that is no step")
        #expect(request.settings.changed.first { $0.row == .slides }?.to == landed.label,
                "the card said Slides lands on one step and the store landed on \(landed.label)")
        #expect(!after.hasHandEditsSinceAutoCorrect, "the preset's output reads as hand-edited")

        // 5. The list's new item is a real loss: a note made deeper does not
        // survive a preset (the new set's notes are new).
        // A NOTE (a sound has no Voice: the store refuses it).
        let noteID = try #require(after.segments.first { $0.origin != .unpitched }).id
        _ = try store.setClipNoteFormant(clipId: clip.id, segmentIds: [noteID], semitones: -2)
        #expect(try stored().segments.first { $0.id == noteID }?.formantOffsetSemitones == -2)
        #expect(gate.request(.natural, clipID: clip.id, clipName: "Lead", current: try stored()) == .askFirst)
        let again = try #require(gate.confirm())
        _ = try await store.autoCorrectClipPitch(clipId: again.clipID, options: again.preset.options())
        let voices = try stored().segments.map(\.formantOffsetSemitones)
        #expect(!voices.isEmpty)
        #expect(voices.allSatisfy { $0 == 0 }, "a note's Voice survived the preset: the card names a loss that is not one")
        #expect(engine.detectCalls == 3)
    }

    /// ⭐ THE PANE SHIPPED WITH NO WAY IN, AND THAT IS WHY THIS TEST EXISTS.
    /// p2-b built and rendered the whole note-editor surface;
    /// `AppModel.openPitchEditor(clipID:)` was written and waiting; the ONLY
    /// missing piece was one `Button` in a file that agent had been told to
    /// stay out of. **A capability nobody can reach is indistinguishable from
    /// one that was never built** — it reads as "the editor is not done" in
    /// every summary after it, including to the people who built it.
    ///
    /// This walks the whole chain, because a break at ANY link is the same
    /// silent nothing on screen: the menu item, the `ClipBlock` seam, the
    /// outer `TimelineLanesView` parameter, and the pass-through between them.
    @Test("the note editor has a human door, end to end")
    func noteEditorIsReachable() {
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        #expect(lanes.contains("Menu(\"Tune Vocal\")"),
                "POSITIVE CONTROL FAILED: this reader cannot see the menu that holds the item, so the assertions below would fail for the wrong reason")
        #expect(lanes.contains("Button(\"Open Note Editor…\") { onOpenPitchEditor() }"),
                "no menu item opens the note editor — the pane can only be reached by a wire command")
        #expect(lanes.contains("var onOpenPitchEditor: (_ clip: Clip) -> Void = { _ in }"),
                "TimelineLanesView has no onOpenPitchEditor parameter, so ContentView cannot bind one")
        #expect(lanes.contains("onOpenPitchEditor: { onOpenPitchEditor(clip) },"),
                "ClipBlock's onOpenPitchEditor is never passed through from TimelineLanesView — the button draws and does nothing")
    }
}
