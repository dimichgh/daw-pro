import AppKit
import DAWControl
import DAWCore
import Foundation

// The `view.*` app-layer seam (M35) — the `EditPasteWireSurface.swift` /
// `PluginUIControlling` precedent at the smallest possible footprint:
// `AppModel` already holds every piece of state the four verbs need (the
// capture window, the arrange selection, the workspace mode, the layout store,
// the four editor cards, the plugin-window manager), so it conforms directly
// rather than through a second owned object. This file exists separately from
// `DAWProApp.swift` for the SAME reason `EditPasteWireSurface.swift` and
// `EditClipboardStaging.swift` do (the m23-cq-1 shape): the host file is
// 10 000+ lines and a standing merge magnet, so its footprint stays the one-line
// `router.viewUI = self` at startup.
//
// ⭐ **THE TWO TIERS SHARE ONE IMPLEMENTATION, THEY DO NOT SHARE A COPY.**
// Nothing here reimplements a `debug.*` handler. `captureView` calls
// `captureMainWindowCore(to:)` — the same rasterization `debug.captureUI`'s
// window path calls. `selectClipForView` writes `selectedClipID` and reads
// `openEditorClip`, the tree's ONE rule for "is the roll on screen".
// `applyViewPanelLayout` writes the same `PanelLayoutStore` slots
// `debug.panelLayout` writes. `openViewEditor` calls the same
// `openPolySynthEditor` / `openSamplerEditor` / `openEffectEditor` /
// `pluginWindows.openUI` funnels the cards' own buttons and the `debug.*` seams
// call. `debug.*` is untouched, byte-for-byte — additive-only is a hard rule.
extension AppModel: ViewUIControlling {

    // MARK: - view.capture

    /// Rasterizes the app's real window content (M35 m35-b).
    ///
    /// ⚠️ **NO `ImageRenderer` FALLBACK, AND THE ABSENCE IS THE FEATURE.**
    /// `debug.captureUI` keeps one for its headless edge; this tier throws
    /// instead. `ImageRenderer` cannot draw NSScrollView-backed content, so the
    /// track rows, the timeline clips and the piano-roll grid — everything an
    /// agent asked to SEE — come out blank in a 1280×800 PNG the call reports as
    /// a success. A success that means nothing is exactly this tree's
    /// characteristic failure mode, and it is worse here than an error, because
    /// an agent will go on to reason about the blank image.
    func captureView(path: String?) async throws -> ViewCaptureResult {
        await flushPendingViewUpdates()
        let url = captureDestinationURL(path: path)
        guard let result = try captureMainWindowCore(to: url) else {
            throw DebugError(
                "no drawable app window to capture — the app has no laid-out window yet "
                + "(view.capture never falls back to an offscreen render, because scrollable "
                + "content rasterizes blank there). Retry once the window has displayed.")
        }
        return result
    }

    /// The bounded flush `view.capture` performs before it rasterizes (m35-f).
    /// **A CEILING that is also the whole wait** — see `flushPendingViewUpdates()`
    /// for why it is not adaptive, and for the measurement that sized it.
    private static let viewCaptureFlushSeconds: TimeInterval = 0.2

    /// Lets a SwiftUI update scheduled by an EARLIER wire request actually draw,
    /// before this capture photographs the window (m35-f).
    ///
    /// ⛔ **THE BUG THIS EXISTS FOR, MEASURED ON STAGING 2026-09-04.**
    /// `view.panelLayout {editorMaximized:true}` → `view.selectClip {clipId}`
    /// (which answered `reason: piano-roll-opened, editorOpen: true` — a TRUE
    /// reply) → `view.capture` produced the piano roll at its DEFAULT anchor
    /// with an EMPTY GRID, for a clip written at C1/D1. One more round trip and
    /// the same call framed the notes correctly. **The reply was honest and the
    /// photograph was a lie** — this tree's characteristic failure mode, and the
    /// worst possible place for it, because an agent then reasons about a
    /// picture of the past and nothing tells it so.
    ///
    /// ⭐ **BE PRECISE ABOUT WHAT DOES AND DOES NOT LAND, BECAUSE THE FRAME
    /// SAYS SO.** The stale F1 is not a picture of "before the roll opened": at
    /// 345 862 B against F0's 280 428 B it shows the piano roll MOUNTED, at its
    /// default anchor, with an empty grid. So the first-order update (the
    /// subtree instantiates) had run by then. What had NOT run is the
    /// SECOND-ORDER chain m35-h's focus hangs off — the viewport-geometry
    /// reader's tick, `PanelLayoutStore.requestPianoRollFocus(pitch:)`, and
    /// `PianoRollView.focusPitchAxis(on:)`'s `scrollTo`. Each link needs another
    /// main-actor turn, and the two production verbs are SEPARATE wire requests
    /// with nothing between them that yields enough of them.
    ///
    /// ⚠️⚠️ **WHY THIS IS AN `await` AND NOT A NESTED RUNLOOP SPIN — THE FIRST
    /// FIX I SHIPPED WAS THE WRONG ONE, AND THE ARM WAS POSITIVE-CONTROLLED.**
    /// `RunLoop.main.run(until:)` was the obvious move — it is what
    /// `debug.captureUI` does — and it changed the captured frame by **ZERO
    /// BYTES**: F1's sha came back bit-for-bit identical to the unfixed run's.
    /// ⭐ A spin that never ran and a spin that ran and could not help produce
    /// the SAME output, so the arm was re-run at **2.0 s** with the capture's
    /// wall time instrumented: **2349 ms measured (the spin definitely ran) and
    /// F1 was STILL the stale sha.** Ten times the wait, no effect whatsoever.
    /// The reason is that the caller is *occupying the main actor* while it
    /// spins: the chain above is main-actor work, and main-actor work cannot run
    /// re-entrantly inside a nested runloop held by a main-actor task. Spinning
    /// harder can never fix this; the actor has to be RELEASED, which is exactly
    /// what a suspension does. (Swift agrees, incidentally — `run(until:)` is
    /// `noasync`, so this arm only compiles at all while the verb is sync.)
    /// ⭐ This is also the mechanism behind m35-h's note that
    /// `debug.captureUI {selectClip}` photographs the pre-focus frame DESPITE
    /// its own 0.2 s spin. That path is deliberately left alone: additive-only
    /// is a hard rule and its contract is byte-for-byte.
    ///
    /// ⭐ **WHY IT LIVES HERE AND NOT IN `captureMainWindowCore(to:)`.** Two
    /// reasons, either sufficient:
    ///   • The core's job is "rasterize what is on screen". Waiting for a
    ///     PENDING update is a policy about WHICH MOMENT to photograph — a
    ///     production-tier contract ("show me what the last verb did"), not a
    ///     fact about rasterization.
    ///   • `debug.captureUI` calls that core. A flush there would add a wait to
    ///     every app-tier capture and make that core `async`, changing a shipped
    ///     handler this item has no business changing.
    ///
    /// ⚠️ **BOUNDED, AND DELIBERATELY NOT ADAPTIVE.** A capture that waits for a
    /// layout that will never settle is worse than the bug it fixes: no picture,
    /// no error, no explanation. So the wait is a FIXED
    /// ``viewCaptureFlushSeconds``, which IS the ceiling — it cannot grow,
    /// whatever the app is doing, and **when the ceiling is reached (i.e.
    /// always) the capture simply proceeds and rasterizes whatever is drawn at
    /// that instant.** It never fails and never blocks a second time. A
    /// settle-detecting loop was written and rejected: SwiftUI's update is not
    /// reflected in `contentView.needsLayout` / `window.viewsNeedDisplay` while
    /// it is merely scheduled, so such a loop would exit on its first slice and
    /// be a fixed short wait wearing a settle-detector's costume — adaptivity
    /// never shown to extend, which reads as a guarantee it cannot give.
    ///
    /// **HOW 0.2 s WAS SIZED — MEASURED, NOT INHERITED.** With the flush cut to
    /// **0.02 s** all four legs of `scripts/gates/m35-view-surface-probe.mjs`
    /// still passed, on the deepest known chain (mount → viewport-geometry tick
    /// → `scrollTo`) at 2880×1800. So what the fix actually buys is the
    /// SUSPENSION, and the duration is pure margin: 0.2 s is 10× the
    /// demonstrated-sufficient value, ≈ 12 display refreshes at 60 Hz, and
    /// coincides with the figure `debug.captureUI` has used since m23 — which is
    /// corroboration, not the reason. The gate is what keeps this honest: it
    /// drives a real app and fails if a capture taken immediately after
    /// `view.selectClip` differs from one taken a round trip later.
    ///
    /// ⚠️ Interleaving caveat, the analogue of the one `debug.captureUI` carries
    /// for its spin: suspending here lets other main-actor work run, including
    /// another control request. That is acceptable for the serial control stream
    /// this serves, and it is the unavoidable price of a snapshot of a view tree
    /// that updates asynchronously.
    private func flushPendingViewUpdates() async {
        // `try?`: the only failure is cancellation, and a cancelled flush should
        // still produce a picture rather than an error — the frame it then takes
        // is no worse than the one every pre-m35-f capture took.
        try? await Task.sleep(for: .seconds(Self.viewCaptureFlushSeconds))
    }

    // MARK: - view.selectClip

    /// Focuses one clip and reports, honestly, whether a piano roll opened on it
    /// (M35 m35-c).
    ///
    /// ⭐ **`reason` IS DERIVED FROM `openEditorClip`, NOT FROM `clip.isMIDI`.**
    /// `openEditorClip` is the tree's ONE rule for "the roll is on screen"
    /// (`ContentView`'s editor branch renders exactly when it is non-nil), so
    /// deriving from it is what keeps the reply and the screen from diverging.
    /// Reading `isMIDI` here would be a SECOND computation of the same fact —
    /// the m27 meta-finding's exact shape, where the record says X, the source
    /// says Y, and nothing compares them.
    ///
    /// ⚠️ **IT DELIBERATELY DOES NOT SWITCH THE WORKSPACE FOR YOU.** The roll
    /// mounts in Arrange, so a MIDI clip selected while the Mix console is up is
    /// focused but not visible. Silently flipping the workspace would move a
    /// surface the caller did not ask about (and yank a human's view out from
    /// under them); saying `workspace-is-not-arrange` instead leaves the choice
    /// where it belongs, and `view.panelLayout {workspace:"arrange"}` is the one
    /// call that acts on it.
    func selectClipForView(_ clipID: UUID) throws -> ViewSelectClipResult {
        guard let track = store.tracks.first(where: { track in
            track.clips.contains { $0.id == clipID }
        }), let clip = track.clips.first(where: { $0.id == clipID }) else {
            throw DebugError(
                "clipId is not a known clip in this project: \(clipID.uuidString) — "
                + "list them with project.snapshot.")
        }
        selectedClipID = clipID
        let editorOpen = openEditorClip?.id == clipID && workspaceMode == .arrange
        // m23-ap Phase 2, item p2-c (design §9.2) — `editorOpen`'s sibling for
        // the SECOND bottom pane, the SAME shape: derived from
        // `openPitchEditorClip` (§3.6's one rule for "is the pitch editor on
        // screen"), never from `!clip.isMIDI` directly. The two can never both
        // be true (§3.6: the panes are mutually exclusive by construction),
        // so there is no ordering question between them the way there is
        // between `editorOpen` and the MIDI/workspace checks below.
        let pitchEditorOpen = openPitchEditorClip?.id == clipID && workspaceMode == .arrange
        // ⚠️ THE BRANCH ORDER IS THE CONTRACT: `reason` is decided FROM
        // `editorOpen`/`pitchEditorOpen`, never alongside them. Testing
        // `clip.isMIDI` first would compute the same fact a second way, and
        // the two could disagree — a MIDI clip in Arrange whose
        // `openEditorClip` resolves nil (the focus setter refusing, a stale
        // id, any future filter on that property) would answer
        // `reason: piano-roll-opened, editorOpen: false`, a
        // self-contradicting reply on the one verb whose entire item is
        // honesty. They agree today only because `openEditorClip` happens to
        // filter on `isMIDI` too, and "they agree today" is exactly the m27
        // meta-finding's shape.
        let reason: ViewSelectClipResult.Reason
        if editorOpen {
            reason = .pianoRollOpened
        } else if pitchEditorOpen {
            // m23-ap Phase 2, item p2-c — checked BEFORE the bare
            // `!clip.isMIDI` fallback: an audio clip the pitch editor is
            // already open on is no longer honestly described as "has no
            // editor open on it" (§9.2 — `audioClipHasNoEditor`'s string is
            // now only half true for this clip).
            reason = .pitchEditorOpen
        } else if !clip.isMIDI {
            reason = .audioClipHasNoEditor
        } else if workspaceMode != .arrange {
            reason = .workspaceIsNotArrange
        } else {
            // A MIDI clip, in Arrange, and the roll did NOT mount. There is no
            // honest `reason` for this today, so it FAILS LOUDLY rather than
            // borrowing one of the three — a wrong reason here would be worse
            // than an error, because an agent would act on it.
            throw DebugError(
                "clip \(clipID.uuidString) is a MIDI clip and the workspace is Arrange, but the "
                + "piano roll did not mount on it — this is a bug in the app's focus path, not in "
                + "your call; please report it.")
        }
        return ViewSelectClipResult(
            clipID: clipID,
            trackID: track.id,
            clipKind: clip.isMIDI ? "midi" : "audio",
            editorOpen: editorOpen,
            pitchEditorOpen: pitchEditorOpen,
            reason: reason,
            workspace: workspaceMode.rawValue)
    }

    // MARK: - view.openPitchEditor

    /// Opens the pitch editor on an audio clip (m23-ap Phase 2, item p2-c) —
    /// `selectClipForView`'s sibling for the SECOND bottom pane.
    ///
    /// ⚠️ THE CLIP LOOKUP AND THE MIDI REFUSAL ARE NOT HERE. They live in
    /// `Commands.swift`'s router-side handler for `view.openPitchEditor`,
    /// because `DAWApp` has no test target — a refusal written only in this
    /// file would be untestable, and a planted "accepts a MIDI clip" defect
    /// would fail no test (the `ViewSurfaceCommandTests`
    /// `headlessRefusals`/`unknownKeyRejection` shape only reaches router-side
    /// code). By the time this runs, the router has already confirmed
    /// `clipID` names an existing, non-MIDI clip.
    func openPitchEditorForView(_ clipID: UUID) throws -> ViewOpenPitchEditorResult {
        guard let track = store.tracks.first(where: { track in
            track.clips.contains { $0.id == clipID }
        }) else {
            // Structurally unreachable — the router already found this clip
            // — stated rather than trusted (the `openEffectEditorForView`
            // "master chain hosts built-ins only" precedent).
            throw DebugError(
                "clip \(clipID.uuidString) was not found while opening the pitch editor — this "
                + "is a bug in the app's focus path, not in your call; please report it.")
        }
        openPitchEditor(clipID: clipID)
        guard openPitchEditorClip?.id == clipID else {
            // Also structurally unreachable for an audio clip (the router
            // already excluded MIDI) — the same defensive shape
            // `openInstrumentEditorForView` uses for its own post-condition.
            throw DebugError(
                "the pitch editor refused to open on \"\(track.name)\" — this is a bug in the "
                + "app's focus path, not in your call; please report it.")
        }
        let opened = workspaceMode == .arrange
        return ViewOpenPitchEditorResult(
            clipID: clipID,
            trackID: track.id,
            opened: opened,
            reason: opened ? .pitchEditorOpened : .workspaceIsNotArrange,
            workspace: workspaceMode.rawValue)
    }

    // MARK: - view.panelLayout

    /// Applies the two production-tier layout controls and echoes them (M35
    /// m35-d). A call with both arguments nil is READ-ONLY — the m11-a bare-call
    /// law, which `debug.panelLayout` already obeys.
    ///
    /// `workspace` has already been validated against the vocabulary by the
    /// router, so an unrecognised string cannot reach here; the `?? workspaceMode`
    /// fallback below is a compile-time totality, not a silent tolerance.
    func applyViewPanelLayout(workspace: String?, editorMaximized: Bool?)
        -> ViewPanelLayoutResult {
        if let workspace, let mode = WorkspaceMode(rawValue: workspace) {
            workspaceMode = mode
        }
        if let editorMaximized {
            panelLayout.setEditorMaximized(editorMaximized)
        }
        return ViewPanelLayoutResult(
            workspace: workspaceMode.rawValue,
            editorMaximized: panelLayout.editorMaximized,
            // Echoed BESIDE `editorMaximized` on purpose (m25-b-1): the two are
            // INDEPENDENT — maximize never writes the fraction — so one round
            // trip proves the restore contract.
            editorFraction: Double(panelLayout.editorFraction))
    }

    // MARK: - view.openEditor

    /// Opens the editor for an instrument or an insert effect (M35 m35-e),
    /// dispatching on the target's OWN kind so a caller never has to know which
    /// card a track deserves.
    func openViewEditor(_ target: ViewEditorTarget) async throws -> ViewEditorResult {
        switch target {
        case .instrument(let trackID):
            return try await openInstrumentEditorForView(trackID: trackID)
        case .effect(let trackID, let effectID):
            return try await openEffectEditorForView(trackID: trackID, effectID: effectID)
        }
    }

    /// The instrument half of the dispatch table.
    ///
    /// ⚠️ **THE `switch` IS EXHAUSTIVE WITH NO `default:`, DELIBERATELY.** A new
    /// `InstrumentDescriptor.Kind` must then be routed on purpose or the build
    /// fails — rather than falling into a bucket that hands an agent a success
    /// naming an editor that is not on screen.
    private func openInstrumentEditorForView(trackID: UUID) async throws -> ViewEditorResult {
        guard let track = store.tracks.first(where: { $0.id == trackID }) else {
            throw DebugError("trackId is not a known track UUID: \(trackID.uuidString)")
        }
        guard track.kind == .instrument else {
            throw DebugError(
                "track \"\(track.name)\" is a \(track.kind.rawValue) track and has no instrument "
                + "— only instrument tracks carry one.")
        }
        // A nil instrument on an instrument track IS the default descriptor,
        // which is the poly synth (`openPolySynthEditor`'s own rule, mirrored
        // here rather than re-decided).
        let kind = track.instrument?.kind ?? .polySynth
        switch kind {
        case .polySynth:
            openPolySynthEditor(trackID: trackID)
            guard polySynthEditorTrackID == trackID else {
                throw DebugError("the Poly Synth editor refused to open on \"\(track.name)\"")
            }
            return ViewEditorResult(editor: .polySynth, trackID: trackID, effectID: nil,
                                    title: "Poly Synth on \(track.name)")
        case .sampler:
            openSamplerEditor(trackID: trackID)
            guard samplerEditorTrackID == trackID else {
                throw DebugError("the Sampler editor refused to open on \"\(track.name)\"")
            }
            return ViewEditorResult(editor: .sampler, trackID: trackID, effectID: nil,
                                    title: "Sampler on \(track.name)")
        case .audioUnit:
            // DELEGATED to the shipped `plugin.*` seam — there is exactly one
            // code path in this app that materializes an AU window, and this is
            // not a second one.
            return try await openPluginWindowForView(
                .instrument(trackID: trackID), trackID: trackID, effectID: nil)
        case .soundBank:
            // ⚠️ EVERY VERB NAMED HERE WAS CHECKED AGAINST `allCommands`. An
            // earlier draft of this message pointed at
            // `instrument.setSoundBankProgram`, WHICH DOES NOT EXIST — a
            // fabricated verb handed to the one caller who is already lost.
            throw DebugError(
                "track \"\(track.name)\" plays a sound-bank program, which has no editor card — "
                + "its identity IS the program. List the alternatives with "
                + "instrument.listSoundBankPrograms, then switch with "
                + "track.setInstrument {soundBank:{source, program}}.")
        case .drumSynth:
            // ⚠️ HONEST, AND EVERY VERB NAMED HERE WAS CHECKED AGAINST
            // `allCommands` — the rule this file learned the hard way one case
            // above, where an earlier draft invented a verb that did not exist.
            // The drum machine ships its engine, model and wire in m39-dm; the
            // editor CARD is UI work that has not been built, so this says so
            // rather than opening the wrong panel or failing silently.
            throw DebugError(
                "track \"\(track.name)\" plays the drum machine, which has no editor card yet — "
                + "its \(MIDIControllerRouting.drumParameterCount) parameters are on the wire. Read them with "
                + "instrument.describeDrumKit, set one with "
                + "instrument.setDrumParam {name:\"kick.decay\", value:0.9}, and load a factory "
                + "kit with instrument.loadDrumPreset {name:\"909\"}.")
        case .testTone:
            throw DebugError(
                "track \"\(track.name)\" plays the built-in test tone, which has no editor "
                + "(it is the engine-test instrument and carries no parameters).")
        }
    }

    /// The insert-effect half of the dispatch table. `trackID == nil` addresses
    /// the MASTER chain, which hosts built-ins only — so the AU branch is
    /// unreachable there by construction, and says so rather than crashing.
    private func openEffectEditorForView(trackID: UUID?, effectID: UUID) async throws
        -> ViewEditorResult {
        let effects: [EffectDescriptor]
        let chainLabel: String
        if let trackID {
            guard let track = store.tracks.first(where: { $0.id == trackID }) else {
                throw DebugError("trackId is not a known track UUID: \(trackID.uuidString)")
            }
            effects = track.effects
            chainLabel = track.name
        } else {
            effects = store.masterEffects
            chainLabel = "Master"
        }
        guard let descriptor = effects.first(where: { $0.id == effectID }) else {
            throw DebugError(
                "effectId is not an insert on \(chainLabel)'s chain: \(effectID.uuidString) — "
                + "list the chain with project.snapshot.")
        }
        if descriptor.kind == .audioUnit {
            guard let trackID else {
                // Structurally unreachable today (the master chain rejects AUs
                // at insert time) — stated rather than trusted, because "it
                // cannot happen" is how a crash gets shipped.
                throw DebugError(
                    "the master chain hosts built-in effects only, so this insert cannot be an "
                    + "Audio Unit — this is a bug; please report it.")
            }
            return try await openPluginWindowForView(
                .effect(trackID: trackID, effectID: effectID),
                trackID: trackID, effectID: effectID)
        }
        openEffectEditor(trackID: trackID, effectID: effectID)
        guard effectEditorTarget?.effectID == effectID else {
            throw DebugError(
                "the effect editor refused to open on \(chainLabel)'s \(descriptor.kind.rawValue)")
        }
        // The Mix workspace + Pro density are what make the card VISIBLE — the
        // `debug.effectEditor` open path does exactly this, and a production
        // caller that then captures must see the same thing a human would.
        workspaceMode = .mix
        panelDensity.setDensity(.pro, forPanel: MixerView.panelID)
        return ViewEditorResult(
            editor: .builtInEffect, trackID: trackID, effectID: effectID,
            title: "\(descriptor.kind.rawValue) on \(chainLabel)")
    }

    /// The ONE hosted-Audio-Unit branch: hands the target to the shipped
    /// `plugin.*` window manager and re-wraps its answer. Note this is the SAME
    /// `pluginWindows.openUI` call `plugin.openUI` makes — a not-ready or
    /// wedged unit therefore fails here exactly the way it fails there, with the
    /// same message, instead of growing a second vocabulary for the same
    /// condition.
    private func openPluginWindowForView(_ target: PluginUITarget, trackID: UUID,
                                         effectID: UUID?) async throws -> ViewEditorResult {
        let opened = try await pluginWindows.openUI(target, x: nil, y: nil)
        return ViewEditorResult(
            editor: .pluginWindow,
            trackID: trackID,
            effectID: effectID,
            title: opened.info.title,
            pluginWindow: opened.info,
            alreadyOpen: opened.alreadyOpen)
    }
}
