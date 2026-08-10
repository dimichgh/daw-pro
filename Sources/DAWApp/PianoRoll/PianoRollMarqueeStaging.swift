import CoreGraphics
import Foundation
import DAWControl
import DAWAppKit

// The `debug.pianoRollMarquee` handler for the m23-ek-1 rubber band, in the
// `ArrangeMarqueeStaging` / `StepSequencerStaging` tradition: the seam stages a
// synthetic gesture through the SAME view handlers a real mouse drag runs, and
// the view reports what it DREW back up, so a bare seam call echoes GROUND
// TRUTH rather than its own input.
//
// ⚠️ IT LIVES IN AN `extension AppModel` IN ITS OWN FILE — the m23-cq-1
// deviation, for the same reason and with the same limits. DAWProApp.swift is
// 9 000+ lines and is a standing merge magnet; keeping the footprint there to a
// dispatch line is the smallest stale-match surface available. Nothing else
// changes: the handler is app-tier, off `allCommands`, off MCP and off the
// Copilot catalog.
//
// ⚠️ THE STAGE STRUCT ITSELF IS NOT HERE, and cannot be. The m23-ek design doc
// (`docs/research/2026-08-09-group-selection-and-clipboard-design.md`, GS-3)
// places `PianoRollMarqueeStage` in this file; that does not compile.
// `PianoRollNoteSelectionBridge` holds the staged step and lives in DAWAppKit,
// which cannot import DAWApp — so the struct lives beside `PianoRollMarquee`
// there, and this file holds the handler alone.

extension AppModel {

    /// Spins the main runloop, BOUNDED, until the ROLL has run the staged
    /// gesture step and reported back — the `awaitMarqueeApplied` contract
    /// (m23-e echo-seam law). Without it the echo answers with the PREVIOUS
    /// step's band and selection, which does not merely fail a gate: a stale
    /// echo poisons every diagnosis made through it. Bounded twice over: it
    /// stops the instant the roll reports, and hard-stops at the deadline when
    /// no roll exists to report at all (the Mix workspace, no clip open, the
    /// step sequencer showing).
    func awaitPianoRollMarqueeApplied(after reportsBefore: Int) {
        let deadline = Date().addingTimeInterval(0.30)
        while pianoRollNoteSelection.marqueeReportSeq == reportsBefore, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        // ⚠️ SECOND WAIT, ON A DIFFERENT CLOCK. `hasSelection` is NOT written by
        // `reportMarquee` — deliberately, since it gates a keyboard path and must
        // stay transition-reported (`DeleteMenuPolicy.swift:136-143`, and this
        // module's `marqueeReportDoesNotDisturbTheKeyboardGate` test). It is
        // published by the roll's own `.onChange(of: model.selection.isEmpty)`,
        // i.e. on the NEXT body pass — one pass BEHIND the sequence bump above,
        // which happens synchronously inside the handler that mutated the
        // selection. Echoing it without this wait makes the seam INTERMITTENTLY
        // right: it answers correctly whenever a runloop slice happened to flush
        // the pass. Waiting on COHERENCE (rather than on a caller-supplied target
        // as `debug.pianoRollSelection` can) costs nothing in the common case —
        // only empty ↔ non-empty transitions are ever incoherent, and those are
        // exactly the ones worth waiting for.
        let coherenceDeadline = Date().addingTimeInterval(0.30)
        while pianoRollNoteSelection.hasSelection
            != !pianoRollNoteSelection.surface.selection.isEmpty,
            Date() < coherenceDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// `debug.pianoRollMarquee {act?, x?, y?, shift?, command?}` — the m23-ek-1
    /// staging seam for the PIANO ROLL's rubber band. App-level, debug tier ONLY
    /// (off `allCommands`/MCP/the Copilot catalog — ZERO wire growth, matching
    /// `debug.arrangeMarquee`). That is not a shortcut: a marquee's only domain
    /// effect is a SELECTION, which is UI state, and `Commands.swift:170-172`
    /// defines `debug.*` as exactly this developer/verification surface.
    ///
    /// PHASED, not one-shot. A one-shot "select this rect" seam structurally
    /// cannot observe "the band is VISIBLE during the drag" — it would have
    /// begun and ended inside one call, leaving nothing standing to look at:
    ///
    ///   - `{}` — READ-ONLY (the m11-a bare-read law). Answers the SCALES too,
    ///     which is the point: `rowHeight` and `ppb` are what a caller needs to
    ///     compute a band, and both are unknowable from outside (`ppb` is driven
    ///     by the persisted, user-zoomable `PanelLayoutStore.pianoRollPPB`). A
    ///     caller MUST derive its fixture from these, never from 14/32.
    ///   - `{act:"begin", x, y, shift?, command?}` — press. Runs the roll's own
    ///     press handler: empty grid enters the click state a band can be
    ///     promoted out of, a point on a note starts a move/toggle exactly as
    ///     the mouse would. NO band is armed.
    ///   - `{act:"changed", x, y}` — drag. The first one past
    ///     `PianoRollMarquee.dragSlop` from the press point PROMOTES the press
    ///     into a band; the rest re-decide the whole selection from the frozen
    ///     base, so shrinking gives notes back.
    ///   - `{act:"end", x, y}` — release: a promoted gesture applies its final
    ///     band and puts it away; an unpromoted one resolves as the CLICK it
    ///     still is.
    ///
    /// ⚠️⚠️ THE CHORD GOES ON EVERY STEP OF A CHORDED GESTURE, not on `begin`
    /// alone — MEASURED (m23-ek-1 gate, first run: an additive band REPLACED).
    /// The chord is read at the instant each DECISION is made, exactly as the
    /// live gesture reads `NSEvent.modifierFlags`: at PROMOTION, which happens
    /// on a `changed` rather than on the press, and at RELEASE. Carrying it only
    /// on `begin` models a user who pressed shift, released it, and only then
    /// dragged — a real gesture, and a different one. `debug.arrangeMarquee`
    /// takes it at `begin` because over there the band ARMS at press; the m23-ek
    /// design doc copied that clause and it does not hold for a promotion-based
    /// band. Remembering the press chord here was rejected for the same reason:
    /// it would give the seam a behaviour the mouse does not have.
    ///
    /// ⚠️ WHAT THIS SEAM STRUCTURALLY CANNOT TEST, stated so nobody writes a leg
    /// that passes vacuously:
    ///   • a staged `begin`+`end` at one point cannot exercise the promotion
    ///     threshold — it never travels. The threshold is reachable ONLY through
    ///     `changed`: begin → changed WITHIN slop (`bandRect` stays null) →
    ///     changed PAST slop (`bandRect` non-null) is the only honest shape.
    ///   • the live `ArrangeClickModifiers.current` read: a synthesized gesture
    ///     carries no real `NSEvent.modifierFlags`, so the chord is passed
    ///     EXPLICITLY here (the `debug.arrangeSelection` convention) and that one
    ///     line stays unproven, exactly as the arrange records.
    ///   • a coordinate-space mismatch between the live `DragGesture` and the
    ///     drawn band: this seam feeds grid CONTENT points straight in.
    ///
    /// Echoes GROUND TRUTH throughout — `bandRect` is the rect the ROLL is
    /// drawing (its own `@State`, reported up after it is stored), never the
    /// seam's input, and `selectedIds` is the model's own selection.
    func pianoRollMarqueeDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if let act = params["act"]?.stringValue {
            guard let action = PianoRollMarqueeStage.Action(rawValue: act) else {
                throw DebugError(
                    "unknown act \"\(act)\" — expected \"begin\", \"changed\", or \"end\"")
            }
            guard let xv = params["x"]?.doubleValue, let yv = params["y"]?.doubleValue else {
                throw DebugError(
                    "act \"\(act)\" needs note-grid content-space x and y (points; "
                    + "x = beats · ppb, y = (127 − pitch) · rowHeight, both scales echoed "
                    + "by this command)")
            }
            // ⚠️ AN UNBALANCED GESTURE IS AN ERROR, NOT A NO-OP. The roll drops a
            // `begin` that arrives with a gesture already open (the mouse cannot
            // deliver one either) — but it still reports, so without this the seam
            // would answer plausibly while leaving the press point at the PREVIOUS
            // gesture's origin, and the next `changed` would compute its band from
            // there. A wrong answer is worse than a red one. Teaching-error shape
            // (m23-cy): name the state and the way out.
            //
            // ⚠️ IT GUARDS ON A REPORTED PROXY, NOT ON `activeDrag` ITSELF, which
            // this tier cannot see. A LIVE mouse drag reports nothing, so a staged
            // `begin` landing in the middle of one would still slip through to the
            // view's silent `break`. That is a human-at-the-machine-during-a-gate
            // scenario rather than an automated one, and closing it would mean
            // publishing per-tick pointer state to an `@Observable` — exactly what
            // this bridge's `@ObservationIgnored` discipline exists to prevent.
            if action == .begin, pianoRollNoteSelection.marqueeGestureInFlight {
                throw DebugError(
                    "a grid gesture is already in flight — send {act:\"end\", x, y} to "
                    + "release it before starting another. (Every staged gesture must be "
                    + "balanced begin → changed* → end; an unbalanced one would silently "
                    + "reuse the previous press point.)")
            }
            // The roll only exists in the arrange workspace, and only with a MIDI
            // clip open. Putting the workspace right mirrors `debug.arrangeMarquee`;
            // OPENING a clip is deliberately NOT done here — that is
            // `debug.arrangeSelection {act:"click"}`'s job, and a seam that
            // silently opened an editor would be staging two gestures per call.
            workspaceMode = .arrange
            let reportsBefore = pianoRollNoteSelection.marqueeReportSeq
            pianoRollNoteSelection.stageMarquee(PianoRollMarqueeStage(
                action: action, x: CGFloat(xv), y: CGFloat(yv),
                shift: params["shift"]?.boolValue == true,
                command: params["command"]?.boolValue == true,
                nonce: (pianoRollNoteSelection.marqueeStage?.nonce ?? 0) + 1))
            awaitPianoRollMarqueeApplied(after: reportsBefore)
        } else if params["x"] != nil || params["y"] != nil {
            throw DebugError("debug.pianoRollMarquee 'x'/'y' need an 'act'")
        }

        let bridge = pianoRollNoteSelection
        let surface = bridge.surface
        let sortedIds: (Set<UUID>) -> JSONValue = { ids in
            .array(ids.map(\.uuidString).sorted().map { .string($0) })
        }
        var object: [String: JSONValue] = [:]
        // The SCALES — the ground truth a fixture must be computed FROM.
        object["rowHeight"] = .number(Double(surface.rowHeight))
        object["ppb"] = .number(Double(surface.pixelsPerBeat))
        object["clipLengthBeats"] = .number(surface.clipLengthBeats)
        object["noteCount"] = .number(Double(surface.noteCount))
        // The band the ROLL is drawing — null exactly when none is in flight.
        // Non-null mid-drag is the only positive proof the band exists; "gone
        // after" alone passes vacuously against an implementation that never
        // draws one.
        object["bandRect"] = bridge.marqueeBand.map {
            .object([
                "x": .number(Double($0.minX)), "y": .number(Double($0.minY)),
                "width": .number(Double($0.width)), "height": .number(Double($0.height)),
            ])
        } ?? .null
        // What the last reported band TOUCHED — distinct from the selection,
        // which under an additive chord is base ∪ hits.
        object["hitIds"] = sortedIds(bridge.marqueeHits)
        object["selectedIds"] = sortedIds(surface.selection)
        object["count"] = .number(Double(surface.selection.count))
        // Whether the roll would claim DELETE right now — the transition-reported
        // Bool this bridge exists for, echoed beside the ids so a leg can see
        // that it did NOT go count-keyed to feed this seam.
        object["hasSelection"] = .bool(bridge.hasSelection)
        // Whether a gesture is still open — so a caller can SEE the state the
        // `begin` guard above rejects on, instead of discovering it as a throw.
        object["gestureInFlight"] = .bool(bridge.marqueeGestureInFlight)
        // The clip the editor is ACTUALLY open on — so a red leg reads "no clip
        // is open" instead of "the band selected nothing".
        object["editorClipId"] = openEditorClip.map { .string($0.id.uuidString) } ?? .null
        object["reportSeq"] = .number(Double(bridge.marqueeReportSeq))
        return .object(object)
    }
}
