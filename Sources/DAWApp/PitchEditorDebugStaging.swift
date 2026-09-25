import DAWAppKit
import DAWControl
import DAWCore
import Foundation

// The `debug.pitchEditor` handler (m23-ap Phase 2, item p2-c) — the
// PianoRollMarqueeStaging / DefaultsDomainStaging tradition: app-tier,
// deliberately off `allCommands`, off MCP, and out of `DAWProApp.swift`
// itself (the m23-cq-1 shape — that file is 13 000+ lines and a standing
// merge magnet; the footprint there is the one dispatch line in
// `installDebugCommands()`).
//
// ═══════════════════════════════════════════════════════════════════════════
// WHAT THIS ECHOES, AND THE ONE THING IT CANNOT
// ═══════════════════════════════════════════════════════════════════════════
//
// Design `docs/design/2026-09-22-pitch-editor-ui.md` §12.4: "a spy gate beats
// a source-shape gate." `PitchEditorChromeLedger` (`PitchEditorView.swift`) IS
// that spy — the view writes the very strings and counts it drew, from inside
// the drawing arguments, into `AppModel.pitchEditorChrome`, and this handler
// reads that ledger back rather than re-deriving anything the view already
// computed. Both halves are echoed VERBATIM:
//   - the CHROME half — `statusKey`/`statusText`/`captionText`/`presetLabels`/
//     `presetSummaries`/`noteCount`/`tuningApplied`/`notesEdited`/
//     `clipBadgeText`/`ticks` (the last three: the header's one clip badge as
//     drawn, I7b-2).
//   - the INTERACTION half (m23-ap Increment C) — `toolKey`/`paletteLabels`/
//     `toolHelp`/`dragReadout`/`refusalText`/`commitCount`/`interactionTicks`.
//   - the interaction batch's I3/I6a fields — `cutPreview` (the cut line as
//     drawn), `maximizeToggle` (the header toggle's drawn face) beside the
//     STORE's `maximized`, and `escapeMountHits` (the pane's Escape mount).
//
// ⚠️ **`interaction.toolKey` (and the top-level `tool` mirror of it) READS ""
// UNTIL THE PALETTE HAS DRAWN AT LEAST ONCE.** The ledger is written DURING
// `body`, so a `view.openPitchEditor` immediately followed by `debug.pitchEditor`
// with no SwiftUI pump in between can race the first paint. `view.capture`
// (which flushes pending updates, `ViewUIWireSurface.flushPendingViewUpdates`)
// or a short `RunLoop.main.run` between the two calls settles it — a caller
// that reads "" here has not necessarily hit a bug.
//
// ═══════════════════════════════════════════════════════════════════════════
// "NOTES AS DRAWN" — WHY THIS COMES FROM THE STORE, NOT FROM THE VIEW
// ═══════════════════════════════════════════════════════════════════════════
//
// The view's actual on-screen blobs come from `PitchEditorModel.noteTable`
// (`storedTable ?? seedTable`), and `seedTable` — the live, UNSAVED detection
// a freshly-opened pane draws before any edit — lives only in that model's
// `@State`, private to `PitchEditorView`. There is no reachable spy for it
// (extending the ledger to carry it needs a change in
// `Sources/DAWApp/PitchEditor/*`, out of this item's lane), and there must
// not be one on principle either: m23-q condition 4/F11 and this milestone's
// own writers (`ProjectStore+PitchNoteEdits.swift`'s banner) are explicit
// that **there is no pitch detection on the wire path** — the seed is an
// in-process-editor-only shortcut. So `notes` below is `clip.pitchEdits`, the
// STORED table — exactly what `clip.getPitchEdits` would answer, and exactly
// what a note MUST carry before `clip.setNotePitch`/`clip.splitNote` can
// address it.
//
// ⭐ **THIS MEANS `notes.count` AND `chrome.noteCount` CAN LEGITIMATELY
// DISAGREE, AND THAT DISAGREEMENT IS THE SIGNAL, NOT A BUG.** On a clip that
// has never been auto-corrected, the pane draws its live seed
// (`chrome.noteCount` > 0) while the store carries nothing (`notes` empty) —
// two instruments disagreeing, and the honest reading is "the screen is
// showing an unsaved detection." Call `clip.autoCorrectPitch` first (this
// milestone's own round-trip recipe) and the two converge: once a stored
// table exists, `PitchEditorModel.noteTable` prefers it unconditionally
// (`syncStoredNoteTable`'s doc: "the store is the truth the moment it has
// one"), so `notes` becomes exactly what is drawn.
//
// Filtered to the clip's CURRENT source window — `rebuildBlobs`'s own OVERLAP
// rule, mirrored here from the one home (`Clip.sourceWindowSeconds(tempoMap:)`)
// rather than re-derived: a trimmed clip keeps every segment it ever carried
// (they are source-absolute and deliberately never re-anchored), and drawing
// ones outside the current window would echo blobs the view does not.
//
// ═══════════════════════════════════════════════════════════════════════════
// C-0 (design 2026-09-24 §4.4) — THE PLAYED LINE, AS DRAWN
// ═══════════════════════════════════════════════════════════════════════════
//
// `clipPitchShiftSemitones` and `playedLine` are the LEDGER's — the transpose
// the surface drew at and the line it stroked, reported by the view from the
// values it drew with (`PitchEditorView.recordPlayedLine`). Each note's
// `playedMidi` is its DRAWN centre, through the one DAWAppKit function the
// view itself places blobs with (`PitchEditorGeometry.drawnMidi`), at the
// ledger's transpose — so a pane that missed a transpose shows up here as
// `playedMidi` disagreeing with `editedMidi` plus the clip's own shift. Like
// `tool`, these read their empty values until the pane has drawn once. This is
// dogfood, not the gate (the gate is the in-process equality test,
// `PitchEditorDisplayMatchesRenderTests`).
//
// ═══════════════════════════════════════════════════════════════════════════
// INTERACTION BATCH I0 — THE STAGED STEPS, AND THE SURFACE AS MEASURED
// ═══════════════════════════════════════════════════════════════════════════
//
// `{act, …}` stages ONE step into the open pane through
// `PitchEditorInteractionBridge`, which the pane applies through the SAME
// callbacks a real event runs, then echoes. Nothing in this tree can drive a
// real pointer (m23-g1), so this is how a gate hovers, presses and scrolls the
// LIVE pane. Coordinates are the surface's CONTENT space: take them from
// `notesAsDrawn` (the rects the Canvas filled), never from a guessed scale.
//
//   {act:"hover", x, y}          the hover reader's own write (the cut line)
//   {act:"hoverEnd"}             the pointer left the surface
//   {act:"press", x, y, chord?}  mouse down — the gesture's first tick, which
//                                ROUTES the press (the echo's `press.kind`)
//   {act:"drag", x, y, chord?}   a later tick of the staged press
//   {act:"release", x, y, chord?} mouse up (the echo's `lastRelease`)
//   {act:"tool", tool}           a palette slot: "pointer"/"move" or
//                                "scissors"/"split"
//   {act:"scroll", x?, y?}       the pane's scroll WRITERS (clamped)
//   {act:"escape"}               the pane's Escape path, no keystroke
//   {act:"selectAll"}            I4 — Edit ▸ Select All's route into the pane
//                                (the bridge nonce ⌘A pulls), no keystroke
//   {act:"clearSelection"}       I4 — clear the pane's note selection
//   {act:"noteMenu", action, x?, y?}
//                                I7b — choose "clear" or "restore" from the
//                                right-click menu: the menu's OWN function
//                                (`runNoteMenu`), with the right-click's point
//                                when x/y are given (an unselected note there
//                                is selected first) and the selection as it
//                                stands when they are not. A synthetic event
//                                cannot open a context menu (m23-g1).
//
// I7b — each `notesAsDrawn` entry carries the note's `cleared` flag, its
// `levelDb` and the `levelReadout` the surface draws for it (null for none),
// read from the pane's MODEL; `noteMenu` is the right-click menu's items
// `{action, title, enabled}` as the pane would build them at its hover point;
// `notes` (the STORE) carries `cleared` and `amplitudeDb` too, so the two
// instruments can be compared. The refusal line is `interaction.refusalText`.
//
// I4 — `selection {ids, count, token, summary}` is the MODEL's selection as the
// pane reported it (`PitchEditorSelectionReport`, never re-derived here), and
// `band {x, y, width, height, hits, additive}` the rubber band in flight, or
// null. A band is staged with the SAME press → drag → release steps: a press on
// empty surface that travels past the slop becomes one (I0's router).
//
// `chord` is `shift`/`command`/`option` booleans, carried on EVERY step of a
// chorded gesture: each decision reads the chord at its own instant (the router
// at press, the click table at release, ⌥ per tick), and a synthesized step has
// no `NSEvent.modifierFlags` — the `debug.pianoRollMarquee` lesson, MEASURED
// there. An unbalanced gesture (press while one is in flight; drag/release or
// tool with none/one in flight) is an ERROR, never a plausible no-op.
//
// `viewport {offsetX, offsetY, viewportW, viewportH, contentW, contentH}` is the
// bridge's report of what the pane's readers MEASURED — never re-derived here.
// m23-ap I6c: `pitchWindow {low, high, rows, fittedLow, fittedHigh, rowHeight,
// availableHeight}` is the pitch window the pane LAID OUT (the notes' window
// filled to the pane), from its model, the same way.
//
// ═══════════════════════════════════════════════════════════════════════════
// m23-ap I1 UI HOOKS — HEARING THE NOTE: `audition`, AND ONE KNOB
// ═══════════════════════════════════════════════════════════════════════════
//
// `audition` echoes three instruments that must agree, never a re-derivation:
//   • `switch` — the STORE of the switch (`panelLayout.auditionEnabled`), and
//     `toggle {on, symbol, help}` — the header's HEAR switch AS DRAWN (ledger);
//   • `line {text, kind}` — the state row's audition line AS DRAWN (ledger),
//     beside `routerLine`, the router's value;
//   • `router {presses, dragSteps, releases, silentCommits, stops, refusals,
//     lastRequest, lastReason, lastSource, lastOutcome, lastError, waiting}` —
//     what the pane ASKED (`PitchEditorAuditionRouter`), and `store {presses,
//     dragSteps, releases, stops, engineRequests, droppedWaits, lastSpanLatencyMs,
//     lastSpanDelivery, waitingForRender, queuedDraft, spanRendersDisabled}` —
//     what the store's controller DID (`ClipNoteAuditionCounts`, diagnostics).
//     A stop door is proven by BOTH `stops` moving by one.
//
//   {act:"auditionSpanRender", enabled}
//                                ⚠️ DEBUG TIER ONLY — `enabled:false` makes every
//                                span render answer `.unsupported` without asking
//                                the engine (`ClipNoteAuditionController
//                                .spanRendersDisabledForStaging`), so a release
//                                WAITS for the whole-file render as on an engine
//                                without span renders: the only way to put
//                                "Preparing your note…" and the 8 s drop on
//                                screen, since the live engine always answers.
//                                `enabled:true` restores it. Needs no open pane.
extension AppModel {

    /// `debug.pitchEditor {}` — the read-only echo; `{act, …}` stages one step
    /// into the open pane first (see this file's I0 banner). See this file's
    /// header for what each field means and the one place a wire-only caller
    /// cannot reach (the live, unsaved detection seed).
    func pitchEditorDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        var stage: JSONValue?
        if let act = params["act"]?.stringValue, act == "auditionSpanRender" {
            stage = try stageAuditionSpanRender(params)
        } else if let act = params["act"]?.stringValue {
            stage = try stagePitchEditorStep(act: act, params: params)
        } else if let stray = params.keys.sorted().first {
            throw DebugError(
                "debug.pitchEditor '\(stray)' needs an 'act' — {} alone is the read-only echo; "
                + "acts: hover, hoverEnd, press, drag, release, tool, scroll, escape, "
                + "selectAll, clearSelection, noteMenu, auditionSpanRender")
        }
        var echo = pitchEditorEcho()
        if case .object(var fields) = echo, let stage {
            fields["stage"] = stage
            echo = .object(fields)
        }
        return echo
    }

    /// `{act:"auditionSpanRender", enabled}` — the staging knob (this file's I1
    /// UI hooks banner). Validated like every act: `enabled` is required, and
    /// no other key is accepted.
    private func stageAuditionSpanRender(_ params: [String: JSONValue]) throws -> JSONValue {
        if let unknown = params.keys.sorted().first(where: { !["act", "enabled"].contains($0) }) {
            throw DebugError("debug.pitchEditor auditionSpanRender: unknown key '\(unknown)' "
                             + "(allowed: act, enabled)")
        }
        guard let enabled = params["enabled"]?.boolValue else {
            throw DebugError("act \"auditionSpanRender\" needs enabled: true (span renders on, the "
                             + "product) or false (a release waits for the whole-file render)")
        }
        store.clipNoteAudition.spanRendersDisabledForStaging = !enabled
        return .object(["act": .string("auditionSpanRender"),
                        "spanRendersEnabled": .bool(!store.clipNoteAudition.spanRendersDisabledForStaging)])
    }

    /// One staged step: validated, handed to the bridge, and WAITED FOR (bounded)
    /// until the pane has applied it — then what it drew, on a second clock.
    private func stagePitchEditorStep(act: String, params: [String: JSONValue]) throws -> JSONValue {
        let allowed: Set<String> = ["act", "x", "y", "shift", "command", "option", "tool",
                                    "action"]
        if let unknown = params.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw DebugError("debug.pitchEditor: unknown key '\(unknown)' (allowed: "
                             + allowed.sorted().joined(separator: ", ") + ")")
        }
        guard openPitchEditorClip != nil else {
            throw DebugError(
                "the note editor is not open — open it with view.openPitchEditor {clipId} first "
                + "(a staged step with no pane would succeed at nothing)")
        }
        let bridge = pitchEditorInteraction
        let chord = PitchEditorChord(shift: params["shift"]?.boolValue == true,
                                     command: params["command"]?.boolValue == true,
                                     option: params["option"]?.boolValue == true)
        func point() throws -> CGPoint {
            guard let x = params["x"]?.doubleValue, let y = params["y"]?.doubleValue,
                  x.isFinite, y.isFinite else {
                throw DebugError(
                    "act \"\(act)\" needs content-space x and y — take them from `notesAsDrawn` "
                    + "(the rects the surface drew), never from a guessed scale")
            }
            return CGPoint(x: x, y: y)
        }
        let inFlight = bridge.surface.press != nil
        let step: PitchEditorStagedStep
        switch act {
        case "hover":
            step = .hover(try point())
        case "hoverEnd":
            step = .hoverEnd
        case "press":
            guard !inFlight else {
                throw DebugError(
                    "a press is already in flight — send {act:\"release\", x, y} first. Every "
                    + "staged gesture is balanced press → drag* → release; an unbalanced one "
                    + "would silently continue the previous press")
            }
            step = .press(try point(), chord)
        case "drag", "release":
            guard inFlight else {
                throw DebugError("no press is in flight — send {act:\"press\", x, y} first")
            }
            step = act == "drag" ? .drag(try point(), chord) : .release(try point(), chord)
        case "tool":
            guard !inFlight else {
                throw DebugError("a press is in flight — release it before switching tools "
                                 + "(no hand can press a palette slot mid-gesture)")
            }
            let raw = params["tool"]?.stringValue?.lowercased() ?? ""
            guard let tool = PitchEditorTool(rawValue: raw)
                    ?? PitchEditorTool.allCases.first(where: { $0.label.lowercased() == raw }) else {
                throw DebugError("act \"tool\" needs tool: \"pointer\" (Move) or \"scissors\" (Split)")
            }
            step = .tool(tool)
        case "scroll":
            let x = params["x"]?.doubleValue
            let y = params["y"]?.doubleValue
            guard x != nil || y != nil else {
                throw DebugError("act \"scroll\" needs x and/or y (content-space offsets)")
            }
            step = .scroll(x: x.map { CGFloat($0) }, y: y.map { CGFloat($0) })
        case "escape":
            // Not a staged gesture step: the pane's Escape request (a nonce the
            // pane watches). Nothing acknowledges it; the echo shows its effect
            // (`maximized`).
            bridge.requestEscape()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            return .object(["act": .string(act), "applied": .null])
        case "selectAll", "clearSelection":
            // I4 — not a gesture step either: the SAME nonce Edit ▸ Select All
            // (`SelectAllSurface.pitchEditorNotes`) pulls, or the clear the
            // pane's Escape rung runs. Refused mid-press, like `tool`: no hand
            // reaches the menu with the mouse button held on the surface.
            guard !inFlight else {
                throw DebugError("a press is in flight — release it before \(act) "
                                 + "(no hand reaches the menu mid-gesture)")
            }
            let seqBefore = bridge.surfaceSeq
            if act == "selectAll" { bridge.requestSelectAll() } else { bridge.requestClearSelection() }
            // Bounded: a selection that did not CHANGE (select-all with all
            // selected) re-mints no token and reports nothing, and that is a
            // true answer — the echo's `selection` says what is selected.
            let deadline = Date().addingTimeInterval(0.3)
            while bridge.surfaceSeq == seqBefore, Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            }
            return .object(["act": .string(act),
                            "applied": .null,
                            "reported": .bool(bridge.surfaceSeq != seqBefore)])
        case "noteMenu":
            // I7b — a right-click menu item, chosen. Refused mid-press like
            // `tool`: no hand opens a context menu with the button held down.
            guard !inFlight else {
                throw DebugError("a press is in flight — release it before choosing from the "
                                 + "right-click menu")
            }
            let raw = params["action"]?.stringValue ?? ""
            guard let action = PitchEditorNoteMenu.Action(rawValue: raw) else {
                throw DebugError("act \"noteMenu\" needs action: \"clear\" or \"restore\"")
            }
            let hasX = params["x"] != nil
            let hasY = params["y"] != nil
            guard hasX == hasY else {
                throw DebugError("act \"noteMenu\" takes BOTH x and y (the right-click's point, "
                                 + "from `notesAsDrawn`) or neither (the selection as it stands)")
            }
            step = .noteMenu(action, hasX ? try point() : nil)
        default:
            throw DebugError(
                "unknown act \"\(act)\" — expected hover, hoverEnd, press, drag, release, tool, "
                + "scroll, escape, selectAll, clearSelection or noteMenu")
        }
        // The pane exists only in the arrange workspace (`debug.pianoRollMarquee`
        // puts the workspace right the same way; it never opens an editor).
        workspaceMode = .arrange
        let ackBefore = bridge.stageAckSeq
        let cutTicksBefore = pitchEditorChrome.cutLineTicks
        let interactionTicksBefore = pitchEditorChrome.interactionTicks
        bridge.stage(step)
        // FIRST CLOCK — the pane applied the step (it acknowledges after running
        // it). Without this the echo answers with the PREVIOUS step's state.
        let deadline = Date().addingTimeInterval(1.0)
        while bridge.stageAckSeq == ackBefore, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard bridge.stageAckSeq != ackBefore else {
            throw DebugError(
                "the note editor did not apply the staged \"\(act)\" within 1 s — is its pane on "
                + "screen? (It mounts only in the arrange workspace, with the clip still selected.)")
        }
        // SECOND CLOCK — what the step DREW lands one body pass after it was
        // applied: the cut line is recorded from `.onChange(of: cutLine)`, the
        // palette's readout from `.onChange(of: model.drag)`, a scroll's landing
        // through the readers. Stop on the first of them to move; bounded, because
        // a step that changes none of them (a second identical hover) moves none.
        let surfaceSeqAtAck = bridge.surfaceSeq
        let drawDeadline = Date().addingTimeInterval(0.3)
        while pitchEditorChrome.cutLineTicks == cutTicksBefore,
              pitchEditorChrome.interactionTicks == interactionTicksBefore,
              bridge.surfaceSeq == surfaceSeqAtAck,
              Date() < drawDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        return .object([
            "act": .string(step.key),
            "applied": .bool(true),
            "ackSeq": .number(Double(bridge.stageAckSeq)),
        ])
    }

    /// The echo itself — read-only, the same keys whether or not a pane is open.
    private func pitchEditorEcho() -> JSONValue {
        guard let clip = openPitchEditorClip else {
            return .object([
                "open": .bool(false),
                "clipId": .null,
                "trackId": .null,
                "tool": .string(pitchEditorChrome.toolKey),
                "zoom": Self.pitchEditorZoomJSON(self),
                "notes": .array([]),
                "chrome": Self.pitchEditorChromeJSON(pitchEditorChrome),
                "interaction": Self.pitchEditorInteractionJSON(pitchEditorChrome),
                "clipPitchShiftSemitones": .number(pitchEditorChrome.clipPitchShiftSemitones),
                "playedLine": Self.pitchEditorPlayedLineJSON(pitchEditorChrome),
                "cutPreview": Self.pitchEditorCutPreviewJSON(pitchEditorChrome),
                "maximized": .bool(panelLayout.editorMaximized),
                "maximizeToggle": Self.pitchEditorMaximizeToggleJSON(pitchEditorChrome),
                "escapeMountHits": .number(Double(pitchEditorChrome.escapeMountHits)),
                "viewport": Self.pitchEditorViewportJSON(pitchEditorInteraction.surface.viewport),
                "pitchWindow": Self.pitchEditorWindowJSON(pitchEditorInteraction.surface.pitchWindow),
                "notesAsDrawn": Self.pitchEditorNoteRectsJSON(pitchEditorInteraction.surface.noteRects),
                "press": Self.pitchEditorPressJSON(pitchEditorInteraction.surface.press),
                "lastRelease": Self.pitchEditorReleaseJSON(pitchEditorInteraction.surface.lastRelease),
                "hasNoteSelection": .bool(pitchEditorInteraction.hasNoteSelection),
                "selection": Self.pitchEditorSelectionJSON(pitchEditorInteraction.surface.selection),
                "band": Self.pitchEditorBandJSON(pitchEditorInteraction.surface.band),
                "noteMenu": Self.pitchEditorNoteMenuJSON(pitchEditorInteraction.surface.noteMenu),
                "audition": pitchEditorAuditionJSON(),
            ])
        }
        let trackID = store.tracks.first(where: { track in
            track.clips.contains { $0.id == clip.id }
        })?.id

        let windowStart = clip.startOffsetSeconds
        let windowEnd = windowStart + clip.sourceWindowSeconds(tempoMap: store.transport.tempoMap)
        let segments = (clip.pitchEdits?.segments ?? []).filter { segment in
            segment.endSeconds > windowStart && segment.startSeconds < windowEnd
        }

        return .object([
            "open": .bool(true),
            "clipId": .string(clip.id.uuidString),
            "trackId": trackID.map { JSONValue.string($0.uuidString) } ?? .null,
            "tool": .string(pitchEditorChrome.toolKey),
            "zoom": Self.pitchEditorZoomJSON(self),
            "notes": .array(segments.map { segment in
                Self.pitchEditorNoteJSON(
                    segment,
                    drawnShiftSemitones: pitchEditorChrome.clipPitchShiftSemitones)
            }),
            "chrome": Self.pitchEditorChromeJSON(pitchEditorChrome),
            "interaction": Self.pitchEditorInteractionJSON(pitchEditorChrome),
            "clipPitchShiftSemitones": .number(pitchEditorChrome.clipPitchShiftSemitones),
            "playedLine": Self.pitchEditorPlayedLineJSON(pitchEditorChrome),
            "cutPreview": Self.pitchEditorCutPreviewJSON(pitchEditorChrome),
            "maximized": .bool(panelLayout.editorMaximized),
            "maximizeToggle": Self.pitchEditorMaximizeToggleJSON(pitchEditorChrome),
            "escapeMountHits": .number(Double(pitchEditorChrome.escapeMountHits)),
            "viewport": Self.pitchEditorViewportJSON(pitchEditorInteraction.surface.viewport),
            "pitchWindow": Self.pitchEditorWindowJSON(pitchEditorInteraction.surface.pitchWindow),
            "notesAsDrawn": Self.pitchEditorNoteRectsJSON(pitchEditorInteraction.surface.noteRects),
            "press": Self.pitchEditorPressJSON(pitchEditorInteraction.surface.press),
            "lastRelease": Self.pitchEditorReleaseJSON(pitchEditorInteraction.surface.lastRelease),
            "hasNoteSelection": .bool(pitchEditorInteraction.hasNoteSelection),
            "selection": Self.pitchEditorSelectionJSON(pitchEditorInteraction.surface.selection),
            "band": Self.pitchEditorBandJSON(pitchEditorInteraction.surface.band),
            "noteMenu": Self.pitchEditorNoteMenuJSON(pitchEditorInteraction.surface.noteMenu),
            "audition": pitchEditorAuditionJSON(),
        ])
    }

    /// m23-ap I1 UI hooks — hearing the note, three instruments (this file's
    /// banner): the switch as STORED and as DRAWN, the line as DRAWN and as the
    /// router holds it, and the counts on both sides of the store's doors.
    private func pitchEditorAuditionJSON() -> JSONValue {
        let router = pitchEditorAudition
        let controller = store.clipNoteAudition
        let counts = controller.counts
        func string(_ value: String?) -> JSONValue { value.map { .string($0) } ?? .null }
        let latencyMs: JSONValue = controller.lastSpanLatency.map { latency in
            let parts = latency.components
            return .number(Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15)
        } ?? .null
        return .object([
            "switch": .bool(panelLayout.auditionEnabled),
            "toggle": .object([
                "on": .bool(pitchEditorChrome.auditionToggleOn),
                "symbol": .string(pitchEditorChrome.auditionToggleSymbol),
                "help": .string(pitchEditorChrome.auditionToggleHelp),
            ]),
            "line": .object([
                "text": .string(pitchEditorChrome.auditionLineText),
                "kind": .string(pitchEditorChrome.auditionLineKind),
                "ticks": .number(Double(pitchEditorChrome.auditionLineTicks)),
            ]),
            "routerLine": .object([
                "text": .string(router.line?.text ?? ""),
                "kind": .string(router.line?.kind.rawValue ?? ""),
            ]),
            "router": .object([
                "presses": .number(Double(router.counts.presses)),
                "dragSteps": .number(Double(router.counts.dragSteps)),
                "releases": .number(Double(router.counts.releases)),
                "silentCommits": .number(Double(router.counts.silentCommits)),
                "stops": .number(Double(router.counts.stops)),
                "refusals": .number(Double(router.counts.refusals)),
                "lastRequest": .string(router.lastRequestKey),
                "lastReason": string(router.lastResult?.reason?.rawValue),
                "lastSource": string(router.lastResult?.source.rawValue),
                "lastOutcome": string(router.lastResult?.outcome?.rawValue),
                "lastError": string(router.lastError),
                "waiting": .bool(router.waitingSerial != nil),
            ]),
            "store": .object([
                "presses": .number(Double(counts.presses)),
                "dragSteps": .number(Double(counts.dragSteps)),
                "releases": .number(Double(counts.releases)),
                "stops": .number(Double(counts.stops)),
                "engineRequests": .number(Double(counts.engineRequests)),
                "droppedWaits": .number(Double(counts.droppedWaits)),
                "lastSpanLatencyMs": latencyMs,
                "lastSpanDelivery": string(controller.lastSpanDelivery.map { String(describing: $0) }),
                "waitingForRender": .bool(controller.isWaitingForRender),
                "queuedDraft": .bool(controller.hasQueuedDraft),
                "spanRendersDisabled": .bool(controller.spanRendersDisabledForStaging),
            ]),
        ])
    }

    /// I7b — the right-click menu as the pane would build it at its hover point
    /// (`PitchEditorModel.noteMenu(at:)`, reported with the surface): each
    /// item's `action`, the `title` a person would read, and `enabled`.
    private static func pitchEditorNoteMenuJSON(_ items: [PitchEditorNoteMenu.Item]) -> JSONValue {
        .array(items.map { item in
            .object([
                "action": .string(item.action.rawValue),
                "title": .string(item.title),
                "enabled": .bool(item.isEnabled),
            ])
        })
    }

    /// I4 — the pane's note selection, as its MODEL holds it (the pane's
    /// surface report, `PitchEditorSelectionReport`): `ids` sorted for a stable
    /// echo, `count`, the selection's `token` (re-minted on every real change),
    /// and the status line's `summary` words, verbatim.
    private static func pitchEditorSelectionJSON(_ selection: PitchEditorSelectionReport) -> JSONValue {
        .object([
            "ids": .array(selection.ids.map(\.uuidString).sorted().map { .string($0) }),
            "count": .number(Double(selection.ids.count)),
            "token": selection.token.map { JSONValue.string($0.uuidString) } ?? .null,
            "summary": selection.summary.map { JSONValue.string($0) } ?? .null,
        ])
    }

    /// I4 — the rubber band in flight (content space), or null: the model's
    /// own rect and hits, never re-derived here.
    private static func pitchEditorBandJSON(_ band: PitchEditorBandReport?) -> JSONValue {
        guard let band else { return .null }
        return .object([
            "x": .number(Double(band.rect.minX)),
            "y": .number(Double(band.rect.minY)),
            "width": .number(Double(band.rect.width)),
            "height": .number(Double(band.rect.height)),
            "hits": .array(band.hits.map(\.uuidString).sorted().map { .string($0) }),
            "additive": .bool(band.additive),
        ])
    }

    /// I0 — `{offsetX, offsetY, viewportW, viewportH, contentW, contentH}`, the
    /// bridge's report of what the pane's readers MEASURED (design §3), verbatim.
    /// All zero until a pane has been laid out.
    private static func pitchEditorViewportJSON(_ viewport: PitchEditorViewport) -> JSONValue {
        .object([
            "offsetX": .number(Double(viewport.offset.x)),
            "offsetY": .number(Double(viewport.offset.y)),
            "viewportW": .number(Double(viewport.viewportSize.width)),
            "viewportH": .number(Double(viewport.viewportSize.height)),
            "contentW": .number(Double(viewport.contentSize.width)),
            "contentH": .number(Double(viewport.contentSize.height)),
        ])
    }

    /// m23-ap I6c — `{low, high, rows, fittedLow, fittedHigh, rowHeight,
    /// availableHeight}`: the pitch window as the pane LAID IT OUT (the rows it
    /// drew, filled to the pane), the notes' own window it was grown from, and
    /// the height it was filled to — the bridge's report, verbatim. `null` until
    /// a pane has reported.
    private static func pitchEditorWindowJSON(_ window: PitchEditorWindowReport?) -> JSONValue {
        guard let window else { return .null }
        return .object([
            "low": .number(window.laidOut.lowerBound),
            "high": .number(window.laidOut.upperBound),
            "rows": .number(window.laidOut.upperBound - window.laidOut.lowerBound + 1),
            "fittedLow": .number(window.fitted.lowerBound),
            "fittedHigh": .number(window.fitted.upperBound),
            "rowHeight": .number(Double(window.rowHeight)),
            "availableHeight": .number(Double(window.availableHeight)),
        ])
    }

    /// I0 — every note as the surface DREW it, content space: the targets a
    /// staged hover or press is aimed at.
    private static func pitchEditorNoteRectsJSON(_ rects: [PitchEditorNoteRect]) -> JSONValue {
        .array(rects.map { note in
            .object([
                "id": .string(note.id.uuidString),
                "x": .number(Double(note.rect.minX)),
                "y": .number(Double(note.rect.minY)),
                "width": .number(Double(note.rect.width)),
                "height": .number(Double(note.rect.height)),
                // I7b — from the pane's MODEL (the blob the Canvas drew), never
                // re-derived here.
                "cleared": .bool(note.cleared),
                "levelDb": .number(note.levelDb),
                "levelReadout": note.levelReadout.map { JSONValue.string($0) } ?? .null,
            ])
        })
    }

    /// I0 — the press in flight: the kind the router decided at its first tick
    /// (`PitchEditorPressKind.key`), the note it is on, where it began, and
    /// whether it has travelled past the slop.
    private static func pitchEditorPressJSON(_ press: PitchEditorPress?) -> JSONValue {
        guard let press else {
            return .object([
                "inFlight": .bool(false), "kind": .null, "noteId": .null,
                "originX": .null, "originY": .null, "promoted": .null,
            ])
        }
        return .object([
            "inFlight": .bool(true),
            "kind": .string(press.kind.key),
            "noteId": press.kind.noteID.map { JSONValue.string($0.uuidString) } ?? .null,
            "originX": .number(Double(press.origin.x)),
            "originY": .number(Double(press.origin.y)),
            "promoted": .bool(press.isPromoted),
        ])
    }

    /// I0 — what the LAST release did (`PitchEditorReleaseAction.key`), or null
    /// before any: `endNoteDrag` (a pitch drag committed through the model),
    /// `cut` at the press point, `click` with the house click table's answer
    /// (nothing acts on a click until I4/I5), `endBand`, `nothing`.
    private static func pitchEditorReleaseJSON(_ action: PitchEditorReleaseAction?) -> JSONValue {
        guard let action else { return .null }
        var fields: [String: JSONValue] = ["action": .string(action.key)]
        switch action {
        case .endNoteDrag(let id):
            fields["noteId"] = .string(id.uuidString)
        case .cut(let point):
            fields["x"] = .number(Double(point.x))
            fields["y"] = .number(Double(point.y))
        case .click(let release):
            switch release {
            case .selectOnly(let id):
                fields["click"] = .string("selectOnly")
                fields["noteId"] = .string(id.uuidString)
            case .toggle(let id):
                fields["click"] = .string("toggle")
                fields["noteId"] = .string(id.uuidString)
            case .deselect: fields["click"] = .string("deselect")
            case .positionPlayhead: fields["click"] = .string("positionPlayhead")
            case .doNothing: fields["click"] = .string("doNothing")
            }
        case .endBand, .nothing:
            break
        }
        return .object(fields)
    }

    /// m23-ap interaction batch I3 — the cut line AS DRAWN, verbatim from
    /// `PitchEditorChromeLedger.recordCutLine` (the very value handed to
    /// `PitchEditorCutPreview`): `{visible, x, sourceSecond, verdict}` per design
    /// §6, plus the drawn `label` and the verdict's own numbers. `verdict` is
    /// `PitchEditorCutVerdict.key` — "cut" / "tooCloseToEdge" / "noNote" — and
    /// every field but `visible` and `ticks` is null while no line is drawn.
    ///
    /// ⭐ **SINCE I0 A GATE CAN DRIVE IT:** `{act:"hover", x, y}` writes the
    /// pane's hover point through the bridge — the same `@State` the real
    /// `.onContinuousHover` writes — and the line recorded here is the one the
    /// view then drew. Without a staged (or real) hover this reads
    /// `visible:false`, which is a true statement, not a failure.
    private static func pitchEditorCutPreviewJSON(_ chrome: PitchEditorChromeLedger) -> JSONValue {
        let ticks = JSONValue.number(Double(chrome.cutLineTicks))
        guard let line = chrome.cutLine else {
            return .object([
                "visible": .bool(false), "x": .null, "sourceSecond": .null, "verdict": .null,
                "label": .null, "segmentId": .null, "leftMs": .null, "rightMs": .null,
                "minimumMs": .null, "ticks": ticks,
            ])
        }
        var leftMs = JSONValue.null
        var rightMs = JSONValue.null
        var minimumMs = JSONValue.null
        switch line.verdict {
        case .cut(_, _, let left, let right):
            leftMs = .number(left)
            rightMs = .number(right)
        case .tooCloseToEdge(_, _, let minimum):
            minimumMs = .number(minimum)
        case .noNote:
            break
        }
        return .object([
            "visible": .bool(true),
            "x": .number(Double(line.x)),
            "sourceSecond": .number(line.sourceSecond),
            "verdict": .string(line.verdict.key),
            "label": line.verdict.label.map { JSONValue.string($0) } ?? .null,
            "segmentId": line.verdict.segmentID.map { JSONValue.string($0.uuidString) } ?? .null,
            "leftMs": leftMs,
            "rightMs": rightMs,
            "minimumMs": minimumMs,
            "ticks": ticks,
        ])
    }

    /// m23-ap interaction batch I6a — the header's MAXIMIZE toggle AS DRAWN
    /// (`PitchEditorChromeLedger.recordMaximizeToggle`). The top-level
    /// `maximized` beside it is the STORE's slot (`PanelLayoutStore
    /// .editorMaximized`, the one `view.panelLayout` sets); the two must agree
    /// once the pane has drawn, and a disagreement is the signal.
    private static func pitchEditorMaximizeToggleJSON(_ chrome: PitchEditorChromeLedger) -> JSONValue {
        .object([
            "maximized": .bool(chrome.maximizeToggleMaximized),
            "symbol": .string(chrome.maximizeToggleSymbol),
        ])
    }

    /// `{pixelsPerBeat, rowHeight}` — `PitchEditorGeometry`'s own horizontal/
    /// vertical scale, read from the ONE home (design §5.8: `debug.panelLayout`
    /// tier, not `view.panelLayout` — this changes what an eye prefers, not
    /// what exists to be seen). `PitchEditorView` constructs its model from
    /// exactly these two properties (`layout.pitchEditorPPB`/
    /// `layout.pitchEditorRowHeight`), so this is the value the view draws
    /// at, not a second guess at it.
    private static func pitchEditorZoomJSON(_ model: AppModel) -> JSONValue {
        .object([
            "pixelsPerBeat": .number(Double(model.panelLayout.pitchEditorPPB)),
            "rowHeight": .number(Double(model.panelLayout.pitchEditorRowHeight)),
        ])
    }

    /// One stored note — `id`, SOURCE-FILE `startSeconds`/`endSeconds`, the
    /// measurement (`detectedHz`, and `sungMidi` through
    /// `PitchCorrectionMath.midi(fromHz:)`, the SAME conversion
    /// `DAWAppKit.NoteBlob.centreMidi` uses) and the edit (`pitchOffsetCents`,
    /// `editedMidi` = `sungMidi + pitchOffsetCents / 100`, and — C-0 —
    /// `playedMidi`, the DRAWN centre: `editedMidi` plus the transpose the
    /// surface drew at, through `PitchEditorGeometry.drawnMidi`, the function
    /// the view places the blob with). `edited` is `NoteSegment.isEdited` —
    /// ANY per-note field off its default, not `pitchOffsetCents` alone, so a
    /// note whose only edit is its wobble or its drift reads as edited
    /// (`NoteBlob.hasEdits` is built from the same predicate).
    private static func pitchEditorNoteJSON(_ segment: NoteSegment,
                                            drawnShiftSemitones: Double) -> JSONValue {
        let sungMidi = PitchCorrectionMath.midi(fromHz: segment.detectedHz)
        return .object([
            "id": .string(segment.id.uuidString),
            "startSeconds": .number(segment.startSeconds),
            "endSeconds": .number(segment.endSeconds),
            "detectedHz": .number(segment.detectedHz),
            "sungMidi": .number(sungMidi),
            "pitchOffsetCents": .number(segment.pitchOffsetCents),
            "editedMidi": .number(sungMidi + segment.pitchOffsetCents / 100),
            "playedMidi": .number(PitchEditorGeometry.drawnMidi(
                centreMidi: sungMidi, offsetCents: segment.pitchOffsetCents,
                clipPitchShiftSemitones: drawnShiftSemitones)),
            "edited": .bool(segment.isEdited),
            // I7b — the STORE's own two level fields, beside `notesAsDrawn`'s
            // (the model's): two instruments that must agree.
            "cleared": .bool(segment.isCleared),
            "amplitudeDb": .number(segment.amplitudeDb),
        ])
    }

    /// C-0 — the played line, verbatim from `PitchEditorChromeLedger.recordPlayedLine`:
    /// `basis` (`"render"` / `"estimate"`, "" before the first report),
    /// `reason` (why it is an estimate, else null), the notes drawn with the
    /// amber outline, and per drawn note the line's min / median / max midi
    /// (null for a note the line has no points in).
    private static func pitchEditorPlayedLineJSON(_ chrome: PitchEditorChromeLedger) -> JSONValue {
        func midi(_ value: Double?) -> JSONValue { value.map { .number($0) } ?? .null }
        return .object([
            "basis": .string(chrome.lineBasisKey),
            "reason": chrome.lineReason.map { .string($0) } ?? .null,
            "captionText": .string(chrome.lineCaptionText),
            "captionKind": .string(chrome.lineCaptionKind),
            "unresolvedNoteIds": .array(chrome.unresolvedNoteIDs.map { .string($0.uuidString) }),
            "perNote": .array(chrome.perNote.map { note in
                .object([
                    "id": .string(note.id.uuidString),
                    "minMidi": midi(note.minMidi),
                    "medianMidi": midi(note.medianMidi),
                    "maxMidi": midi(note.maxMidi),
                ])
            }),
            "lineTicks": .number(Double(chrome.lineTicks)),
        ])
    }

    /// The chrome half, verbatim — `PitchEditorChromeLedger.record`'s fields.
    private static func pitchEditorChromeJSON(_ chrome: PitchEditorChromeLedger) -> JSONValue {
        .object([
            "statusKey": .string(chrome.statusKey),
            "statusText": .string(chrome.statusText),
            "captionText": .string(chrome.captionText),
            "presetLabels": .array(chrome.presetLabels.map { .string($0) }),
            "presetSummaries": .array(chrome.presetSummaries.map { .string($0) }),
            "noteCount": .number(Double(chrome.noteCount)),
            // The header's ONE clip badge, as DRAWN (I7b-2): at most one of the
            // two is true, and `clipBadgeText` is the capsule's words ("" = none).
            "tuningApplied": .bool(chrome.tuningApplied),
            "notesEdited": .bool(chrome.notesEdited),
            "clipBadgeText": .string(chrome.clipBadgeText),
            "ticks": .number(Double(chrome.ticks)),
        ])
    }

    /// The interaction half, verbatim — `PitchEditorChromeLedger.recordInteraction`'s
    /// fields (m23-ap Increment C).
    private static func pitchEditorInteractionJSON(_ chrome: PitchEditorChromeLedger) -> JSONValue {
        .object([
            "toolKey": .string(chrome.toolKey),
            "paletteLabels": .array(chrome.paletteLabels.map { .string($0) }),
            "toolHelp": .string(chrome.toolHelp),
            "dragReadout": .string(chrome.dragReadout),
            "refusalText": .string(chrome.refusalText),
            "commitCount": .number(Double(chrome.commitCount)),
            "interactionTicks": .number(Double(chrome.interactionTicks)),
        ])
    }
}
