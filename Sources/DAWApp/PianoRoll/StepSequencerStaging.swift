import Foundation
import DAWCore
import DAWControl
import DAWAppKit

// Staging + reporting plumbing for the m23-cq-1 step sequencer, in the
// `ArrangeMarqueeStage` tradition: the seam stages a synthetic gesture through
// the SAME view handler a real click runs, and the view reports what it DREW
// back up, so a bare seam call echoes GROUND TRUTH rather than its own input.
//
// ⚠️ IT LIVES IN AN `extension AppModel` IN ITS OWN FILE, and that is a
// deliberate (small) deviation from the house habit of putting every
// `debug.*` handler in DAWProApp.swift. That file is 9 000+ lines and was being
// edited by another agent while this item was built; keeping the footprint there
// to a dispatch line and a stored property is the smallest stale-match surface
// available. Nothing else changes: the handler is still app-tier, still off
// `allCommands`, still off MCP and the Copilot catalog.

extension AppModel {

    /// Spins the main runloop, BOUNDED, until the GRID has run the staged change
    /// and reported back — the `awaitMarqueeApplied` contract (m23-e echo-seam
    /// law). Without it the echo answers with the PREVIOUS call's pattern, which
    /// does not merely fail a gate: a stale echo poisons every diagnosis made
    /// through it. Bounded twice over: it stops the instant the grid reports, and
    /// hard-stops at the deadline when no grid exists to report at all (the Mix
    /// workspace, no clip open, the piano roll showing).
    func awaitStepSequencerApplied(after reportsBefore: Int) {
        let deadline = Date().addingTimeInterval(0.30)
        while stepSequencer.reportSeq == reportsBefore, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// `debug.stepSequencer {mode?, step?, act?, stepIndex?, pitch?}` — the
    /// m23-cq-1 staging seam for the STEP SEQUENCER. App-level, debug tier ONLY
    /// (off `allCommands`/MCP/the Copilot catalog — ZERO wire growth). That is
    /// not a shortcut: the sequencer is a VIEW over existing model data, and the
    /// domain effect of every toggle is a note set `clip.setNotes` already
    /// reads and writes. There is no new capability here to expose.
    ///
    ///   - `{}` — READ-ONLY (the m11-a bare-read law). Answers the GRID a caller
    ///     must compute its fixture from: the lanes in drawn order, the column
    ///     count, and `rowHeight`/`stepWidth`. All four are unknowable from
    ///     outside — the lane set depends on the track's instrument AND on which
    ///     pitches the clip already uses, and the column count on the clip
    ///     length and the picked step size. m23-ap I5-F4 adds `phaseBeats`,
    ///     `firstStepSongBeat` and `barStarts` — where the columns sit on the
    ///     SONG's grid, which an off-grid clip shifts.
    ///   - `{mode:"steps"|"notes"}` — show that editor. A gate MUST be able to
    ///     put the pane in steps mode: on a non-drum track the surface does not
    ///     exist until somebody asks for it.
    ///   - `{step:"sixteenth"}` — pick a step size (the `SnapResolution` raw
    ///     values, the app's ONE grid vocabulary). Inert in Simple density,
    ///     which locks the grid to 1/16 — the echo's `stepBeats` reports what
    ///     was DRAWN, so a caller can see the lock rather than infer it.
    ///   - `{act:"toggle", stepIndex, pitch}` — click that cell. Runs the view's
    ///     own `applyStepToggle`, i.e. the same draft mutation and the same
    ///     `commit()` funnel the mouse runs.
    ///
    /// Echoes GROUND TRUTH throughout: every reported field is what the grid
    /// DREW (reported up from inside the drawing layer), never the seam's input,
    /// and `mode` is `.steps` only while a grid is actually mounted.
    func stepSequencerDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        var mutated = false
        var awaited = false

        if let raw = params["mode"]?.stringValue {
            guard let mode = ClipEditorMode(rawValue: raw) else {
                throw DebugError("unknown mode \"\(raw)\" — expected "
                    + ClipEditorMode.allCases.map(\.rawValue).joined(separator: " or "))
            }
            workspaceMode = .arrange
            stepSequencer.setMode(mode)
            mutated = true
        }

        if let raw = params["step"]?.stringValue {
            guard let resolution = SnapResolution(rawValue: raw),
                  StepSequencerGeometry.pickableResolutions.contains(resolution) else {
                throw DebugError("unknown step \"\(raw)\" — expected one of "
                    + StepSequencerGeometry.pickableResolutions.map(\.rawValue)
                        .joined(separator: ", "))
            }
            stepSequencer.setResolution(resolution)
            mutated = true
        }

        if let act = params["act"]?.stringValue {
            guard act == "toggle" else {
                throw DebugError("unknown act \"\(act)\" — expected \"toggle\"")
            }
            // Apply any mode/step change FIRST and wait for the grid to redraw,
            // so a one-call `{mode:"steps", act:"toggle", …}` addresses the grid
            // it just asked for rather than the previous one's geometry.
            if mutated {
                let before = stepSequencer.reportSeq
                awaitStepSequencerApplied(after: before)
                awaited = true
            }
            guard stepSequencer.reportedMode == .steps else {
                throw DebugError("the step sequencer is not showing — call "
                    + "debug.stepSequencer {mode:\"steps\"} first (a MIDI clip must be open)")
            }
            guard let step = params["stepIndex"]?.doubleValue.map({ Int($0) }),
                  let pitch = params["pitch"]?.doubleValue.map({ Int($0) }) else {
                throw DebugError("act \"toggle\" needs 'stepIndex' and 'pitch' "
                    + "(both from the lanes/stepCount this command echoes)")
            }
            // Validated against what the GRID REPORTED, never against a
            // re-derivation: a probe must not be able to address a cell the
            // mouse could not, and the teaching error names the valid range
            // rather than failing silently (the m23-cy teaching-error rule).
            guard step >= 0, step < stepSequencer.reportedStepCount else {
                throw DebugError("stepIndex \(step) is outside the drawn grid — "
                    + "valid steps are 0…\(max(0, stepSequencer.reportedStepCount - 1))")
            }
            guard stepSequencer.reportedLanes.contains(where: { $0.pitch == pitch }) else {
                throw DebugError("pitch \(pitch) has no lane — drawn lanes are "
                    + stepSequencer.reportedLanes.map { "\($0.pitch)" }.joined(separator: ", "))
            }
            let before = stepSequencer.reportSeq
            stepSequencer.stageToggle(StepCell(step: step, pitch: pitch))
            awaitStepSequencerApplied(after: before)
            awaited = true
        } else if params["stepIndex"] != nil || params["pitch"] != nil {
            throw DebugError("debug.stepSequencer 'stepIndex'/'pitch' need an 'act'")
        }

        // A mode/step change with no toggle still has to be through the view
        // before the echo can describe it. Skipped when the pane is (and stays)
        // in notes mode — nothing will report, so waiting would only spend the
        // deadline.
        if mutated, !awaited,
           params["mode"] != nil || stepSequencer.reportedMode == .steps {
            awaitStepSequencerApplied(after: stepSequencer.reportSeq)
        }

        // Assembled in named pieces rather than as one literal: the whole-object
        // form defeated the type checker outright ("unable to type-check this
        // expression in reasonable time"), which is what a big heterogeneous
        // `[String: JSONValue]` with nested closures costs.
        let lanes: [JSONValue] = stepSequencer.reportedLanes.map { lane in
            .object([
                "pitch": .number(Double(lane.pitch)),
                "label": .string(lane.label),
                // Proves the drum names came from the GM key map rather than
                // from a note-name fallback — the item's "labels must NOT be
                // hardcoded" clause, made observable.
                "namedPercussion": .bool(lane.isNamedPercussion),
            ])
        }
        let filled: [JSONValue] = stepSequencer.reportedFills.map { fill in
            .object([
                "step": .number(Double(fill.cell.step)),
                "pitch": .number(Double(fill.cell.pitch)),
                "velocity": .number(Double(fill.velocity)),
                "latent": .bool(fill.isLatent),
            ])
        }
        let editorClip: Clip? = openEditorClip
        let drumKit: Bool = editorClip.flatMap { clip in
            store.tracks.first { $0.clips.contains { $0.id == clip.id } }
        }.map { SMFProjectExporter.isDrumKit($0) } ?? false

        var object: [String: JSONValue] = [:]
        // WHAT IS ON SCREEN. `.steps` only while a grid is mounted and
        // reporting — the seam never echoes the mode it was asked for.
        object["mode"] = .string(stepSequencer.reportedMode.rawValue)
        object["modeOverride"] = stepSequencer.modeOverride.map { .string($0.rawValue) } ?? .null
        object["pickedStep"] = .string(stepSequencer.pickedResolution.rawValue)
        // The GRID — the ground truth a fixture must be computed FROM.
        object["stepCount"] = .number(Double(stepSequencer.reportedStepCount))
        object["stepBeats"] = .number(stepSequencer.reportedStepBeats)
        object["rowHeight"] = .number(Double(stepSequencer.reportedRowHeight))
        object["stepWidth"] = .number(Double(stepSequencer.reportedStepWidth))
        object["laneCount"] = .number(Double(lanes.count))
        object["lanes"] = .array(lanes)
        // m23-ap I5-F4 — WHERE the drawn columns sit on the song's grid: column
        // k starts at clip-local beat `k · stepBeats − phaseBeats` (song beat
        // `firstStepSongBeat + k · stepBeats`), and `barStarts` are the columns
        // the grid drew as bar lines with their SONG bar numbers. Reported up
        // from the drawing layer like everything else here.
        object["phaseBeats"] = .number(stepSequencer.reportedPhaseBeats)
        object["firstStepSongBeat"] = .number(stepSequencer.reportedFirstStepSongBeat)
        object["barStarts"] = .array(stepSequencer.reportedBarMarks.map { mark in
            .object(["step": .number(Double(mark.step)), "bar": .number(Double(mark.bar))])
        })
        // The PATTERN the grid drew.
        object["filled"] = .array(filled)
        // The clip the editor is ACTUALLY open on — so a red leg reads "no clip
        // is open" instead of "the grid is empty".
        object["editorClipId"] = editorClip.map { .string($0.id.uuidString) } ?? .null
        object["isDrumKit"] = .bool(drumKit)
        object["density"] =
            .string(panelDensity.density(forPanel: PianoRollView.panelID).rawValue)
        object["reportSeq"] = .number(Double(stepSequencer.reportSeq))
        return .object(object)
    }
}
