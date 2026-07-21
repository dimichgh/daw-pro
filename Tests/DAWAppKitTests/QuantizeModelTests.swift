import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless tests for the Quantize & Groove flow state machine (m11-a): the grid
/// catalog + default, the density-gated `buildSettings` (Simple = grid + strength;
/// Pro adds swing / ends / groove), the GROOVE-WINS honesty (a selected groove
/// governs the grid + makes swing inert, and `buildSettings` uses the groove's own
/// grid), the extract lifecycle (success auto-selects + appears in the palette;
/// failure surfaces inline), and the value-equivalence property the live gate
/// leans on: a groove applied through the model produces the SAME note set as the
/// equivalent `clip.quantize {groove}` settings. Drives `QuantizeModel` against
/// injected closures — no window, no store, no engine (the `InstrumentPickerModel`
/// / `ClipFixModel` precedent).
@MainActor
@Suite struct QuantizeModelTests {

    // MARK: - Fixtures

    /// The canonical built-in swings the app injects (`GrooveTemplate.builtinNames`).
    private static var builtins: [GrooveTemplate] {
        GrooveTemplate.builtinNames.compactMap { GrooveTemplate.builtin(named: $0) }
    }

    /// A recorder for the apply closure + a mutable saved-groove palette + a
    /// scriptable extract closure — the full injected surface.
    @MainActor final class Harness {
        var applied: [(clipID: UUID, settings: QuantizeSettings)] = []
        var saved: [GrooveTemplate] = []
        var extractError: Error?
        /// The template the next extract returns (defaults to a fresh 1/16 groove).
        var nextExtracted: GrooveTemplate?

        func makeModel() -> QuantizeModel {
            QuantizeModel(
                builtinGrooves: QuantizeModelTests.builtins,
                savedGrooves: { self.saved },
                apply: { self.applied.append(($0, $1)) },
                extract: { clipID, name, grid, cycle in
                    if let error = self.extractError { throw error }
                    let template = self.nextExtracted
                        ?? GrooveTemplate(name: name, gridBeats: grid, cycleBeats: cycle,
                                          offsets: [0, 0.05, 0, -0.02])
                    self.saved.append(template)   // the store appends to the palette
                    return template
                })
        }
    }

    struct StubError: LocalizedError { var errorDescription: String? }

    private func offGridNotes() -> [MIDINote] {
        [
            MIDINote(pitch: 60, startBeat: 0.07, lengthBeats: 0.5),
            MIDINote(pitch: 62, startBeat: 0.46, lengthBeats: 0.5),
            MIDINote(pitch: 64, startBeat: 0.98, lengthBeats: 0.5),
            MIDINote(pitch: 65, startBeat: 1.53, lengthBeats: 0.5),
        ]
    }

    // MARK: - Grid catalog

    @Test("the grid catalog maps musical names to the QuantizeSettings beats values")
    func gridCatalog() {
        // The documented QuantizeSettings mapping (quarter = 1 beat) + 2/3 triplets.
        #expect(QuantizeModel.grids.first { $0.label == "1/4" }?.beats == 1.0)
        #expect(QuantizeModel.grids.first { $0.label == "1/8" }?.beats == 0.5)
        #expect(QuantizeModel.grids.first { $0.label == "1/16" }?.beats == 0.25)
        #expect(QuantizeModel.grids.first { $0.label == "1/32" }?.beats == 0.125)
        // m21-c: the quantize catalog covers every piano-roll snap division, so
        // the two grids never diverge — 1/64 landed with the finer snaps.
        #expect(QuantizeModel.grids.first { $0.label == "1/64" }?.beats == 0.0625)
        let triplet8 = QuantizeModel.grids.first { $0.label == "1/8 triplet" }?.beats ?? 0
        #expect(abs(triplet8 - 1.0 / 3.0) < 1e-12)
        // The default grid is 1/16.
        #expect(QuantizeModel.grids[QuantizeModel.defaultGridIndex].label == "1/16")
        // Every snappable piano-roll division has a same-beats quantize grid
        // (Bar/Beat quantize rides 1/4 · strength — the coarse musical moves).
        for snap in SnapResolution.allCases {
            guard let beats = snap.beats, beats <= 1 else { continue }
            #expect(QuantizeModel.grids.contains { abs($0.beats - beats) < 1e-9 },
                    "no quantize grid matches snap \(snap.rawValue) (\(beats) beats)")
        }
    }

    @Test("gridLabel names catalog beats and falls back for an off-catalog value")
    func gridLabel() {
        #expect(QuantizeModel.gridLabel(forBeats: 0.5) == "1/8")
        #expect(QuantizeModel.gridLabel(forBeats: 0.25) == "1/16")
        #expect(QuantizeModel.gridLabel(forBeats: 0.19).contains("beats"))
    }

    // MARK: - Density-gated buildSettings

    @Test("Simple builds grid + strength only — no swing, groove, or end-snap leaks in")
    func simpleBuild() {
        let model = Harness().makeModel()
        model.density = .simple
        model.gridIndex = QuantizeModel.grids.firstIndex { $0.label == "1/8" }!
        model.strength = 0.6
        // Even if these are set, Simple must ignore them (what you see is what applies).
        model.swingPercent = 70
        model.quantizeEnds = true
        model.selectGroove(Self.builtins.first)
        let s = model.buildSettings()
        #expect(s.gridBeats == 0.5)
        #expect(abs(s.strength - 0.6) < 1e-12)
        #expect(s.swingPercent == 50)      // straight
        #expect(s.quantizeEnds == false)
        #expect(s.groove == nil)
    }

    @Test("Pro carries swing + quantize-ends when no groove is selected")
    func proBuild() {
        let model = Harness().makeModel()
        model.density = .pro
        model.gridIndex = QuantizeModel.grids.firstIndex { $0.label == "1/16" }!
        model.strength = 1.0
        model.swingPercent = 66
        model.quantizeEnds = true
        let s = model.buildSettings()
        #expect(s.gridBeats == 0.25)
        #expect(s.swingPercent == 66)
        #expect(s.quantizeEnds == true)
        #expect(s.groove == nil)
    }

    // MARK: - Groove-wins honesty

    @Test("a selected groove governs the grid + makes swing inert, and wins in the build")
    func grooveWins() {
        let model = Harness().makeModel()
        model.density = .pro
        model.gridIndex = QuantizeModel.grids.firstIndex { $0.label == "1/32" }!  // deliberately mismatched
        model.swingPercent = 72
        let swing8_66 = Self.builtins.first { $0.name == "swing8:66" }!
        model.selectGroove(swing8_66)

        #expect(model.gridIsGrooveLocked)
        #expect(model.swingIsInert)
        // The displayed grid follows the groove (1/8), not the picked 1/32.
        #expect(model.effectiveGridBeats == swing8_66.gridBeats)
        #expect(model.effectiveGridLabel == "1/8")

        let s = model.buildSettings()
        #expect(s.groove == swing8_66)               // groove travels by value
        #expect(s.gridBeats == swing8_66.gridBeats)  // groove's grid, not the picked one
        #expect(s.swingPercent == 50)                // swing neutralized (groove wins)
    }

    @Test("deselecting a groove restores the picked grid + swing (no silent loss)")
    func grooveDeselect() {
        let model = Harness().makeModel()
        model.density = .pro
        model.gridIndex = QuantizeModel.grids.firstIndex { $0.label == "1/16" }!
        model.swingPercent = 62
        model.selectGroove(Self.builtins.first)
        model.selectGroove(nil)
        #expect(!model.gridIsGrooveLocked)
        #expect(!model.swingIsInert)
        let s = model.buildSettings()
        #expect(s.groove == nil)
        #expect(s.gridBeats == 0.25)
        #expect(s.swingPercent == 62)
    }

    @Test("isGrooveSelected matches by id; built-in display formats the reserved name")
    func grooveSelectionAndDisplay() {
        let model = Harness().makeModel()
        let swing16_58 = Self.builtins.first { $0.name == "swing16:58" }!
        model.selectGroove(swing16_58)
        #expect(model.isGrooveSelected(swing16_58))
        #expect(!model.isGrooveSelected(Self.builtins.first { $0.name == "swing8:54" }!))
        let display = QuantizeModel.builtinDisplay(swing16_58)
        #expect(display.title == "1/16 Swing")
        #expect(display.detail == "58%")
    }

    @Test("selection distinguishes same-family built-ins even if their ids collide")
    func grooveSelectionByValueNotID() {
        // The built-in swings' deterministic ids can collide within a family (a
        // DAWCore hash quirk that mis-rendered the picker). Value equality must
        // still highlight ONLY the chosen preset, never a sibling.
        let model = Harness().makeModel()
        let swing8_58 = Self.builtins.first { $0.name == "swing8:58" }!
        model.selectGroove(swing8_58)
        for other in Self.builtins where other.name != "swing8:58" {
            #expect(!model.isGrooveSelected(other), "\(other.name) wrongly reads selected")
        }
        #expect(model.isGrooveSelected(swing8_58))
    }

    // MARK: - Clamping

    @Test("the built settings are always valid: strength 0…1, swing 50…75, grid clamped")
    func clamping() {
        let model = Harness().makeModel()
        model.density = .pro
        // Raw out-of-range inputs (e.g. the debug wire) never produce a bad setting.
        model.strength = 1.8
        #expect(model.buildSettings().strength == 1.0)
        model.strength = -0.3
        #expect(model.buildSettings().strength == 0.0)
        model.strength = 0.5
        model.swingPercent = 90
        #expect(model.buildSettings().swingPercent == 75)
        model.swingPercent = 10
        #expect(model.buildSettings().swingPercent == 50)
        // A stray grid index reads clamped (never crashes the view).
        model.gridIndex = 999
        #expect(model.grid.label == QuantizeModel.grids.last?.label)
        model.gridIndex = -5
        #expect(model.grid.label == QuantizeModel.grids.first?.label)
    }

    // MARK: - Apply

    @Test("apply hands buildSettings to the closure once; audio + no-target are no-ops")
    func apply() {
        let harness = Harness()
        let model = harness.makeModel()
        let clipID = UUID()
        // No target yet → no-op.
        model.apply()
        #expect(harness.applied.isEmpty)
        // MIDI target → one apply carrying the built settings.
        model.prepare(clipID: clipID, clipName: "Drums", isMIDI: true)
        model.density = .pro
        model.strength = 0.75
        model.apply()
        #expect(harness.applied.count == 1)
        #expect(harness.applied[0].clipID == clipID)
        #expect(abs(harness.applied[0].settings.strength - 0.75) < 1e-12)
        // Audio target → note quantize doesn't apply (MIDI-only), so no-op.
        model.prepare(clipID: clipID, clipName: "Vox", isMIDI: false)
        model.apply()
        #expect(harness.applied.count == 1)
    }

    // MARK: - Value-equivalence with the wire (the gate's headless proxy)

    @Test("a groove applied through the model equals the equivalent clip.quantize settings")
    func modelMatchesWireForGroove() {
        let harness = Harness()
        let model = harness.makeModel()
        model.prepare(clipID: UUID(), clipName: "Beat", isMIDI: true)
        model.density = .pro
        model.strength = 1.0
        let swing8_66 = Self.builtins.first { $0.name == "swing8:66" }!
        model.selectGroove(swing8_66)
        model.apply()
        let uiSettings = harness.applied[0].settings

        // What the command layer builds for `clip.quantize {gridBeats: 0.5,
        // groove: "swing8:66"}` (parseQuantizeSettings → resolveGroove). The groove
        // resolves to the SAME built-in template (stable id), so the two settings —
        // and therefore the quantized note sets — must be identical.
        let wireGroove = GrooveTemplate.builtin(named: "swing8:66")!
        let wireSettings = QuantizeSettings(gridBeats: swing8_66.gridBeats, strength: 1.0,
                                            swingPercent: 50, quantizeEnds: false, groove: wireGroove)
        let notes = offGridNotes()
        #expect(MIDIQuantizer.quantize(notes, settings: uiSettings)
                == MIDIQuantizer.quantize(notes, settings: wireSettings))
    }

    // MARK: - Extract lifecycle

    @Test("extract appends + auto-selects the new template and collapses the field")
    func extractSuccess() async {
        let harness = Harness()
        let model = harness.makeModel()
        model.prepare(clipID: UUID(), clipName: "Loop", isMIDI: true)
        model.beginExtract()
        #expect(model.isExtractExpanded)
        #expect(model.extractName == "Loop Groove")   // default from the clip name
        #expect(model.canExtract)
        await model.extract()
        #expect(model.extractError == nil)
        #expect(!model.isExtractExpanded)
        #expect(model.isExtracting == false)
        // The new template is in the palette AND selected (its feel now applies).
        #expect(model.savedGrooves.count == 1)
        #expect(model.selectedGroove?.id == model.savedGrooves[0].id)
    }

    @Test("an extract failure surfaces inline and keeps the field open")
    func extractFailure() async {
        let harness = Harness()
        harness.extractError = StubError(errorDescription: "clip has no notes to analyze")
        let model = harness.makeModel()
        model.prepare(clipID: UUID(), clipName: "Empty", isMIDI: true)
        model.beginExtract()
        await model.extract()
        #expect(model.extractError == "clip has no notes to analyze")
        #expect(model.savedGrooves.isEmpty)
        #expect(model.selectedGroove == nil)
    }

    @Test("canExtract requires a target and a non-blank name")
    func canExtractGating() {
        let model = Harness().makeModel()
        model.extractName = "x"
        #expect(!model.canExtract)                     // no target
        model.prepare(clipID: UUID(), clipName: "C", isMIDI: true)
        model.extractName = "   "
        #expect(!model.canExtract)                     // blank name
        model.extractName = "Nice groove"
        #expect(model.canExtract)
    }

    // MARK: - prepare

    @Test("prepare resets navigation but keeps the grid/strength/swing settings")
    func prepareKeepsSettings() {
        let model = Harness().makeModel()
        model.density = .pro
        model.gridIndex = QuantizeModel.grids.firstIndex { $0.label == "1/8" }!
        model.strength = 0.4
        model.swingPercent = 64
        model.selectGroove(Self.builtins.first)
        model.extractName = "old"
        model.isExtractExpanded = true

        model.prepare(clipID: UUID(), clipName: "New", isMIDI: true)
        // Navigation reset…
        #expect(model.selectedGroove == nil)
        #expect(model.extractName == "")
        #expect(!model.isExtractExpanded)
        // …but the feel settings persist across clips (session sticky).
        #expect(model.grid.label == "1/8")
        #expect(abs(model.strength - 0.4) < 1e-12)
        #expect(model.swingPercent == 64)
    }
}
