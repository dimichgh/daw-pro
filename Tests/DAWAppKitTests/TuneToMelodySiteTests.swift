import Foundation
import Testing

/// Tune to Melody, M3 (W7-TTM3) — THE WIRING, which `DAWApp` (no test target) is the only home
/// of: the menu item draws the door's answer, ContentView binds it and mounts the card UNDER the
/// replace card, the replace card's answers reach the card's door, the card is a listed modal
/// (⌫ cannot reach the vocal under it), and the seam drives the card's own funnels.
///
/// The behaviour is `TuneToMelodyDoorTests`' (spy tests against a real store); this pins only
/// the shapes no spy can reach. Assertions run on COMMENT-STRIPPED source (the
/// `PitchTuneDoorSiteTests` reader, verbatim), because these files explain their own wiring in
/// prose a naive grep would accept. Each check carries a positive control on its own extract.
///
/// NOT `@MainActor`: reading files needs no actor.
@Suite("Tune to Melody M3 — the app's wiring (W7-TTM3)")
struct TuneToMelodySiteTests {

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

    /// The INSIDE of the first braced block opening at or after `marker`, by brace matching.
    private static func block(after marker: String, in code: String) -> String? {
        guard let start = code.range(of: marker),
              let open = code[start.lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < code.endIndex {
            if code[index] == "{" { depth += 1 }
            if code[index] == "}" {
                depth -= 1
                if depth == 0 { return String(code[code.index(after: open)..<index]) }
            }
            index = code.index(after: index)
        }
        return nil
    }

    @Test("S1 the item sits in the Tune Vocal menu, between the presets and Open Note Editor…, and asks the door's own availability")
    func theMenuItemIsInTheTuneVocalMenu() throws {
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        let menu = try #require(Self.block(after: "Menu(\"Tune Vocal\")", in: lanes))
        // POSITIVE CONTROL: the extract holds the presets the menu is known to draw.
        #expect(menu.contains("ForEach(PitchCorrectionPreset.offeredInUI)"))
        let item = try #require(menu.range(of: "TuneToMelodyMenuItem(availability: tuneToMelodyAvailability,"))
        let presets = try #require(menu.range(of: "ForEach(PitchCorrectionPreset.offeredInUI)"))
        let editor = try #require(menu.range(of: "Button(\"Open Note Editor…\")"))
        #expect(presets.lowerBound < item.lowerBound && item.lowerBound < editor.lowerBound)
        #expect(menu.contains("action: onTuneToMelody)"))
        // The lanes view answers with the door's one function, for THIS clip, from its own
        // tracks and tempo map, and hands the open action the clip.
        #expect(lanes.contains("TuneToMelodyMenu.availability(vocal: clip, tracks: tracks,"))
        #expect(lanes.contains("onTuneToMelody: { onTuneToMelody(clip) },"))
        // The item draws the reason under itself when greyed, and its words are the copy home's.
        let view = Self.code("DAWApp/TuneToMelodyCardView.swift")
        let itemBody = try #require(Self.block(after: "struct TuneToMelodyMenuItem: View {", in: view))
        #expect(itemBody.contains("Button(TuneToMelodyCopy.menuTitle, action: action)"))
        #expect(itemBody.contains(".disabled(!state.isEnabled)"))
        #expect(itemBody.contains("if !state.isEnabled {") && itemBody.contains("Text(state.help)"))
    }

    @Test("S2 ContentView binds the item to the funnel, and mounts the card in pickerOverlays — BEFORE the replace card's mount, so that card draws on top")
    func contentViewBindsAndMountsUnderTheReplaceCard() throws {
        let content = Self.code("DAWApp/ContentView.swift")
        #expect(content.contains("model.openChopToPads(clipID: clip.id)"),
                "POSITIVE CONTROL FAILED: the reader cannot see a binding that exists")
        #expect(content.contains("onTuneToMelody: { clip in model.openTuneToMelody(clipID: clip.id) },"),
                "the menu item draws and does NOTHING without this binding")
        let overlays = try #require(Self.block(after: "private var pickerOverlays: some View {", in: content))
        #expect(overlays.contains("ChopToPadsPanel("), "POSITIVE CONTROL: the extract holds a known card")
        #expect(overlays.contains("TuneToMelodyCardMount(model: model)"))
        // Z-ORDER: `pickerOverlays` is attached to the body before the replace card's mount.
        let pickers = try #require(content.range(of: ".overlay { pickerOverlays }"))
        let replace = try #require(content.range(of: ".presetReplaceConfirmOverlay(model)"))
        #expect(pickers.lowerBound < replace.lowerBound,
                "the replace card would draw UNDER the card whose Apply raised it")
    }

    @Test("S3 the replace card's answers reach the card's door; the preset branch is unchanged; the card's funnels never call the store directly")
    func theReplaceAnswersReachTheDoor() throws {
        let staging = Self.code("DAWApp/PitchCorrectionStaging.swift")
        let confirm = try #require(Self.block(after: "func confirmPresetReplace() {", in: staging))
        #expect(confirm.contains("pitchPresetReplaceGate.confirm()"))
        #expect(confirm.contains("if let run = tuneToMelodyDoor.confirmedRun(held) {")
                && confirm.contains("performTuneToMelody(run)"),
                "\"Replace my edits\" on a Tune to Melody question would apply a plain preset")
        #expect(confirm.contains("applyTuningPreset(clipID: held.clipID, preset: held.preset)"),
                "the preset doors' branch moved")
        let cancel = try #require(Self.block(after: "func cancelPresetReplace() {", in: staging))
        #expect(cancel.contains("pitchPresetReplaceGate.cancel()"))
        #expect(cancel.contains("tuneToMelodyDoor.replaceDeclined()"),
                "Cancel would leave the card frozen under a question nobody is asking")
        #expect(!cancel.contains("performTuneToMelody(") && !cancel.contains("applyTuningPreset("))

        let mine = Self.code("DAWApp/TuneToMelodyStaging.swift")
        let apply = try #require(Self.block(after: "func applyTuneToMelodyFromCard() {", in: mine))
        #expect(apply.contains("tuneToMelodyDoor.apply(gate: pitchPresetReplaceGate, store: store)"),
                "Apply must ask the preset doors' ONE gate")
        let perform = try #require(Self.block(after: "func performTuneToMelody(_ run: TuneToMelodyRun) {", in: mine))
        #expect(perform.contains("tuneToMelodyDoor.perform(run, store: self.store)"))
        #expect(!mine.contains("autoCorrectClipPitch"),
                "the app tier calls the store itself: a second path beside the door's")
        // The ONE store call lives in the door, once.
        let door = Self.code("DAWAppKit/TuneToMelodyDoor.swift")
        #expect(door.components(separatedBy: "store.autoCorrectClipPitchReport(").count - 1 == 1)
        #expect(!door.contains("performEdit"), "the store journals the pass; a second step would be two undos")
        // The gate's question is the preset's, unchanged; the melody only rides along.
        let gate = Self.code("DAWAppKit/PitchPresetReplaceGate.swift")
        #expect(gate.contains("current?.hasHandEditsARerunWouldReplace(preset.options()) == true"))
        #expect(gate.contains("melody: melody)"))
    }

    /// ⌫ with the card up must not delete the clip under it: every reader of
    /// `isModalPresented` (⌫, the arrows, Escape, the Edit menu) must see the card. The
    /// `EscapeKeyMonitorSiteTests.thePresetCardIsAModal` shape, for this card.
    @Test("S4 the card is a BLOCKING modal: isModalPresented lists it, so ⌫ cannot reach the vocal under it")
    func theCardIsAModal() throws {
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("let tuneToMelodyDoor = TuneToMelodyDoor()"))
        let modal = try #require(Self.block(after: "var isModalPresented: Bool {", in: app))
        #expect(modal.contains("quantizePanelClipID"), "POSITIVE CONTROL: the extractor cannot see a listed modal")
        #expect(modal.contains("tuneToMelodyDoor.card != nil"),
                "the Tune to Melody card is not in isModalPresented: ⌫ under it deletes the vocal it is about to tune")
        #expect(!modal.contains("showEngineNotices"), "NEGATIVE CONTROL: the passive banner is excluded on purpose")
    }

    @Test("S5 the card claims no key (no Return, no Escape: the census rule), retypes none of its words, and its chip line holds the tallest chip's height")
    func theCardClaimsNoKeyAndOwnsNoWords() throws {
        let view = Self.code("DAWApp/TuneToMelodyCardView.swift")
        #expect(view.contains("struct TuneToMelodyCardView: View {"), "POSITIVE CONTROL")
        #expect(!view.contains(".keyboardShortcut"),
                "a key equivalent on this card: Return must never retune a vocal, and a new Escape must be named in EscapeKeyMonitorSiteTests' census first")
        for word in ["\"Tune to Melody", "\"APPLY\"", "\"Match octave\"", "\"Add a MIDI melody",
                     "\"Tuned ", "\"Undo (⌘Z)"] {
            #expect(!view.contains(word), "the view retypes \(word): the copy has a second home")
        }
        #expect(view.contains("W.summary(outcome)") && view.contains("W.farMoveNote(outcome)"))
        // The chips' lines wrap to different heights: every one is laid out and only the picked
        // one shown, so clicking a chip cannot make the card jump.
        let sound = try #require(Self.block(after: "private var soundSection: some View {", in: view))
        #expect(sound.contains("Button { onPreset(preset) }"), "POSITIVE CONTROL: the extract holds the chips")
        #expect(sound.contains("Text(W.presetLine(preset))")
                && sound.contains(".opacity(preset == card.preset ? 1 : 0)"),
                "the chip line is laid out for the picked chip only: the card jumps when a chip is clicked")
    }

    @Test("S6 debug.tuneVocal's melody block drives the card's funnels, never the store, and stays off the public table")
    func theSeamDrivesTheCardsFunnels() throws {
        let staging = Self.code("DAWApp/PitchCorrectionStaging.swift")
        let seam = try #require(Self.block(after: "func tuneVocalDebug(_ params: [String: JSONValue]) throws -> JSONValue {",
                                           in: staging))
        #expect(seam.contains("tuneVocalFromContextMenu(clipID: clipID, preset: preset)"), "POSITIVE CONTROL")
        #expect(seam.contains("\"melody\"") && seam.contains("try tuneToMelodyDebug(block, clipID: clipID)"))
        #expect(seam.contains("tuneToMelodyEcho(clipID: clipID)"))
        let mine = Self.code("DAWApp/TuneToMelodyStaging.swift")
        let block = try #require(Self.block(
            after: "func tuneToMelodyDebug(_ params: [String: JSONValue], clipID: UUID?) throws {", in: mine))
        for funnel in ["openTuneToMelody(clipID: clipID)", "tuneToMelodyDoor.select(", "tuneToMelodyDoor.choosePreset(",
                       "tuneToMelodyDoor.setMatchOctave(", "applyTuneToMelodyFromCard()", "closeTuneToMelody()"] {
            #expect(block.contains(funnel), "the seam skips the funnel `\(funnel)`")
        }
        let commands = Self.code("DAWControl/Commands.swift")
        #expect(commands.contains("\"clip.autoCorrectPitch\""), "POSITIVE CONTROL")
        #expect(!commands.contains("tuneToMelody") && !commands.contains("TuneToMelody"),
                "the card added a wire verb: M2's clip.autoCorrectPitch is the one path")
    }
}
