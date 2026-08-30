import AppKit
import DAWAppKit
import DAWControl
import DAWCore
import SwiftUI

// m23-ct — MUSICAL TYPING's app tier: the `NSEvent` handlers, the stuck-note
// safety net, and the `debug.musicalTyping` staging seam.
//
// Kept OUT of `DAWProApp.swift` on the m23-cq-1 shape (`DefaultsDomainStaging`,
// `EditClipboardStaging`, `MixerStripDragStaging`): that file is ~10.4k lines and
// agents have died to a liveness watchdog reading it. Only four things about this
// feature live over there — the controller property, one branch inside
// `handleKeyDownEvent`, the monitor's event mask, and one `case` line in the
// debug table. Everything else is here.
//
// ⚠️ **EVERYTHING IN THIS FILE IS COMPOSITION AND IS THEREFORE INVISIBLE TO
// `Tests/`** — `DAWApp` is an executable target with no test target. The
// DECIDABLE half lives in `DAWAppKit` (`MusicalTypingRouting`,
// `MusicalTypingController`, `MusicalKeyboardGeometry`) and is unit-tested there;
// the WIRING half is pinned by `MusicalTypingSiteTests`, which reads this source,
// and is DRIVEN by `debug.musicalTyping`, which injects below `NSEvent`.

extension AppModel {

    // MARK: - Bootstrap

    /// Wires the controller to its sink and installs the stuck-note safety net.
    /// Called from `init`, right after the key monitor.
    func installMusicalTyping() {
        // ⚠️ THE TRACK IS RESOLVED PER NOTE, THROUGH A CLOSURE. `activeTrackID` is
        // `ArrangeActiveTrack`'s ONE resolution point (its doc carries an explicit
        // "do not add a second lookup beside this"), and it MOVES while the mode
        // is on — the user clicks another header mid-session. A captured UUID
        // would keep playing the track they left.
        musicalTyping.sink = LivePlayNoteSink(store: store) { [weak self] in
            self?.activeTrackID
        }
        installMusicalTypingSafetyNet()
    }

    /// ⛔⛔ **THE STUCK-NOTE SAFETY NET. Every entry here is a way a key-UP never
    /// arrives, and a note that never stops is the worst failure this feature
    /// has** — it survives the window, the project, and anything else the user
    /// does next.
    ///
    /// `ProjectStore.stopAllAudition()` exists for exactly this and is documented
    /// idempotent, and `MusicalTypingController.releaseAll()` is too, so every
    /// one of these is safe to fire when nothing is held.
    ///
    /// ⚠️ **RESIGN-ACTIVE HAD NO OBSERVER IN THIS TREE BEFORE TODAY.**
    /// `ProjectStore.stopAllAudition`'s own doc says it is "called on the project
    /// boundary and by the app on resign-active" — MEASURED FALSE on 2026-08-29:
    /// `grep -rn 'esignActive' Sources/` returns nothing (positive-controlled
    /// against `willTerminateNotification`, which returns two). The only app-side
    /// caller was the will-terminate observer. The doc described an intention; this
    /// is the first code that makes it true.
    private func installMusicalTypingSafetyNet() {
        musicalTypingResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Both halves, and neither implies the other: the controller's
                // ledger is what the on-screen keyboard draws, the store's is what
                // the engine is holding. Clearing only one leaves a lit key over
                // silence, or a ringing voice with nothing lit.
                self.musicalTyping.releaseAll()
                self.store.stopAllAudition()
            }
        }
    }

    // MARK: - Key events

    /// The MUSICAL TYPING branch of `handleKeyDownEvent`. Returns nil to swallow.
    ///
    /// The predicate's `.perform` and `.swallowRepeat` both swallow; every
    /// `.passThrough` hands the event back untouched, so the ~21 keys this mode
    /// claims are the ONLY keys it can take from anything else.
    func handleMusicalTypingKeyDown(_ event: NSEvent) -> NSEvent? {
        // Refresh the target state on every press, from the pure resolver, so the
        // indicator and the note-on gate read ONE value that is never stale.
        refreshMusicalTypingTarget()
        let decision = musicalTyping.handleKeyDown(
            keyCode: event.keyCode,
            modifiers: Self.transportKeyModifiers(event.modifierFlags),
            isRepeat: event.isARepeat,
            responder: Self.transportKeyResponder(event.window?.firstResponder),
            window: transportKeyWindow(event.window))
        switch decision {
        case .perform, .swallowRepeat: return nil
        case .passThrough: return event
        }
    }

    /// The key-UP body — the live monitor and `debug.musicalTyping {release:…}`
    /// both run exactly this.
    ///
    /// ⛔⛔ **NO GUARDS. GATE THE ONS, NEVER GATE THE OFFS.** Hold `A`, then click
    /// into a rename field: this key-up arrives with `responder == .textEditing`,
    /// possibly in another window, possibly with ⌘ down. Every one of those facts
    /// refuses a note-ON, and applying any of them here strands a note ringing
    /// forever. It is `auditionPitches`' own law — *"Stopping is ALWAYS allowed…
    /// a refusal here would strand a voice."*
    ///
    /// Swallows ONLY when a sounding note was actually released; a key-up for a
    /// key we never sounded passes through, so nothing else loses an event.
    func handleKeyUpEvent(_ event: NSEvent) -> NSEvent? {
        musicalTyping.releaseKey(keyCode: event.keyCode) ? nil : event
    }

    /// A modifier key changed. **Never swallowed** — this branch only ever
    /// releases notes; the event always goes on to whoever wants it.
    ///
    /// ⚠️ **⌘ ENGAGING RELEASES EVERYTHING, and the reason is an ASSERTION THIS
    /// TREE HAS NOT VERIFIED**: Cocoa is widely held to withhold `keyUp` while ⌘
    /// is held. Rather than test that belief and depend on the answer, the design
    /// makes a stuck note impossible EITHER WAY — if the key-ups do arrive they
    /// find nothing held and pass through (`releaseKey` returns false), and if
    /// they do not, this already stopped the notes.
    ///
    /// ⌥/⌃/⇧ deliberately do NOT release: they are not known to eat key-up, and
    /// releasing a chord because a user brushed shift would be worse than the
    /// hazard it guards.
    func handleFlagsChangedEvent(_ event: NSEvent) -> NSEvent? {
        // ⚠️ `.characters` / `.isARepeat` RAISE on this event type. Only
        // `modifierFlags` and `keyCode` are read here, and only the former is used.
        //
        // ⛔⛔ **`holdsAnything` IS LOAD-BEARING — IT IS NOT AN OPTIMISATION.**
        // This handler runs on EVERY ⌘ press in the whole app: ⌘Z, ⌘S, ⌘C, a few
        // hundred times an hour, with Musical Typing OFF. `releaseAll()` pushes
        // `[]` unconditionally by design (a panic path may not trust its own
        // bookkeeping), and that empty set lands in `ProjectStore.auditionPitches`,
        // which stops whatever is holding the SHARED audition — the piano roll's
        // gutter key, or a note drag the user is in the middle of. Without this
        // guard, a ⌘Z during a roll drag cuts the roll's note, through a mode
        // nobody turned on. That is a bug in a feature the user never enabled.
        //
        // It does NOT weaken the coordinator's "⌘-down = releaseAll" rule: when
        // anything IS held here, ⌘ still releases all of it, unconditionally. And
        // it does not touch the real panic paths (mode off, resign-active, record
        // start) — those are rare EVENTS, not a key, and they keep the blind push.
        if musicalTyping.holdsAnything,
           Self.transportKeyModifiers(event.modifierFlags).contains(.command) {
            musicalTyping.releaseAll()
        }
        return event
    }

    /// A key on the on-screen keyboard was pressed WITH THE MOUSE.
    ///
    /// ⛔ **ONE HOME, AND THAT IS THE WHOLE POINT.** `MusicalKeyboardStrip` takes
    /// this as `onPointerPress` and `debug.musicalTyping {pointerPitch:}` calls it
    /// directly, so the gate and the human press the same two lines. The refresh
    /// is not optional: a click can be the FIRST thing that happens after the user
    /// selects a different track, and without it the press would be judged against
    /// the previous track's target state. Typing gets the same refresh inside
    /// `handleMusicalTypingKeyDown`.
    func musicalTypingPointerDown(pitch: Int) {
        refreshMusicalTypingTarget()
        musicalTyping.pointerDown(pitch: pitch)
    }

    /// A CELL on the on-screen CHORD ROW was pressed with the mouse (m23-cv).
    ///
    /// ⛔ **THE SAME ONE-HOME RULE AS `musicalTypingPointerDown`, for the same
    /// measured reason.** `MusicalKeyboardStrip` takes this as `onChordCellPress`
    /// and `debug.musicalTyping {chordCell:}` calls it directly, so a gate and a
    /// human press the same two lines. The refresh is not optional: a click can be
    /// the first thing that happens after the user changed tracks.
    func musicalTypingChordCellDown(cellIndex: Int) {
        refreshMusicalTypingTarget()
        musicalTyping.pointerDown(cellIndex: cellIndex)
    }

    /// Switches between one-key-one-note and one-key-one-chord — THE one funnel,
    /// so the header chips, the strip and `debug.musicalTyping {playMode:}` cannot
    /// disagree.
    func setMusicalTypingPlayMode(_ mode: MusicalTypingPlayMode) {
        musicalTyping.setPlayMode(mode)
        refreshMusicalTypingTarget()
        // The controller has already pushed an empty set; this also clears
        // anything the piano roll's own audition left behind, exactly as
        // `setMusicalTypingEnabled` does on the way out.
        store.stopAllAudition()
    }

    /// Recomputes whether a key press can currently make a sound, from the pure
    /// resolver. Cheap (one track lookup) and called on every press plus whenever
    /// the strip is on screen and the transport changes.
    func refreshMusicalTypingTarget() {
        let track = activeTrackID.flatMap { id in store.tracks.first { $0.id == id } }
        musicalTyping.targetState = MusicalTypingRouting.targetState(
            hasTrack: track != nil,
            isInstrumentTrack: track?.kind == .instrument,
            isRecording: store.transport.isRecording,
            // ⛔ THE ARM FLAG IS WHAT SEPARATES "YOU ARE RECORDING" FROM "YOU
            // WILL LOSE THIS". `playLiveNotes` computes `captureIntoTake` as
            // `isRecording && isArmed && kind == .instrument` — the SAME three
            // facts this resolver has in hand — so the indicator predicts the
            // store's own verdict rather than inventing a second rule. The
            // engine narrows it further and reports back through
            // `LivePlayResult.isRecording`; the echo shows both.
            isArmed: track?.isArmed == true,
            // ⭐ THE APP-WIDE NOTE-PREVIEW SWITCH IS RESPECTED, NOT BYPASSED.
            // `PanelLayoutStore.auditionEnabled` is documented as "ONE value for
            // both audition surfaces"; this is the third, so a second policy here
            // would be a divergence. It defaults ON and today is reachable only
            // through `debug.panelLayout`, so in practice this never bites — and
            // when it does, `TargetState.previewOff` puts it on screen instead of
            // leaving the keys silently dead.
            auditionEnabled: panelLayout.auditionEnabled)
    }

    /// Turns the mode on or off — THE one funnel. The transport-bar chip, the
    /// strip's own TURN OFF button and `debug.musicalTyping {enable:…}` all call
    /// this, so no surface can light while another believes otherwise.
    func setMusicalTypingEnabled(_ enabled: Bool) {
        musicalTyping.setEnabled(enabled)
        refreshMusicalTypingTarget()
        if !enabled {
            // Belt and braces across the seam: the controller has already pushed
            // an empty set, and this also clears anything the piano roll's own
            // audition left behind.
            store.stopAllAudition()
        }
    }

    // MARK: - The staging seam

    /// `debug.musicalTyping {enable?, press?, release?, releaseAll?, pointerPitch?,
    /// pointerUp?, post?, command?, option?, control?, shift?, repeat?, noWindow?}`
    /// — Musical Typing's staging seam (m23-ct). App-level, debug tier ONLY: off
    /// `allCommands`/MCP, ZERO wire growth. The `note.audition` verb already
    /// exposes the CAPABILITY to an agent; this drives the UI path a human uses.
    ///
    /// ⭐⭐ **IT INJECTS BELOW `NSEvent`, AND THAT IS THE WHOLE DESIGN.** The
    /// "m23-g1 law" — an unbundled staging binary does not get real key events
    /// routed to it — means a seam that needed a genuine keystroke would test
    /// nothing. So `{press:"a"}` SYNTHESIZES an event and runs the SAME
    /// `handleMusicalTypingKeyDown` the live monitor runs, exactly as
    /// `debug.keySpace` does for the space bar.
    ///
    ///   - `{}` — pure state read (the `debug.effectEditor` convention).
    ///   - `{enable:true|false}` — the mode, through `setMusicalTypingEnabled`.
    ///   - `{press:"a"}` — synthesize the key-down for the cap wearing that
    ///     legend, resolved through `MusicalTypingRouting.cap(forLabel:)` so the
    ///     gate never hardcodes a second copy of the key codes. Modifier /
    ///     `repeat` / `noWindow` overrides for matrix probing.
    ///   - `{release:"a"}` — the key-up, through the same handler.
    ///   - `{releaseAll:true}` — the panic path.
    ///   - `{pointerPitch:60}` / `{pointerUp:true}` — the ON-SCREEN keyboard's
    ///     press path, so a gate can prove BOTH surfaces write ONE held ledger.
    ///   - **m23-cv** `{playMode:"chords"|"notes"}`, `{chordKey:7, chordMode:"minor"}`,
    ///     `{voicingPreset:"pad"}`, `{progression:"four-chords"}` (`""` clears the
    ///     lights), `{chordCell:0}` — chord mode's pickers and its on-screen row,
    ///     each through the same app-tier funnel the UI drives. The echo carries
    ///     `chordCells`, the app's OWN projection of what every key says and
    ///     whether it is sounding.
    ///   - `{press:…, post:true}` — post through the REAL queue instead
    ///     (`NSApp.postEvent`), so a passed-through key genuinely reaches the
    ///     responder chain. Asynchronous — settle, then read `{}`.
    ///
    /// ⭐ **READING THE ANSWER: THE CAPTURE QUESTION HAS TWO INSTRUMENTS AND
    /// THEY ARE BOTH REPORTED.** `targetIsCapturing` is the APP'S PREDICTION
    /// (`isRecording && isArmed && kind == .instrument`, resolved by
    /// `MusicalTypingRouting`); `sinkIsRecording` is the ENGINE'S ANSWER, off
    /// the `LivePlayResult` the store handed back, and only IT can see whether a
    /// capture session actually exists. A gate that read either one alone would
    /// be satisfied by a pipe that agreed with itself.
    ///
    /// ⚠️ **`sinkCapturedEdges` IS "THE LAST CALL'S", NOT "SINCE YOU LAST
    /// ASKED" — AND THE DIFFERENCE HAS ALREADY MISLED ONE GATE.** A swallowed
    /// auto-repeat never reaches the sink at all, so the field still holds the
    /// previous press's count; asserting `== 0` after a repeat fails against
    /// correct behaviour. Compare it against the value you read BEFORE the call,
    /// or read `decision` instead.
    func musicalTypingDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if let enable = params["enable"]?.boolValue {
            setMusicalTypingEnabled(enable)
            return musicalTypingStateResponse()
        }
        if params["releaseAll"]?.boolValue == true {
            musicalTyping.releaseAll()
            store.stopAllAudition()
            return musicalTypingStateResponse()
        }
        if params["pointerUp"]?.boolValue == true {
            musicalTyping.pointerUp()
            return musicalTypingStateResponse()
        }
        if let raw = params["pointerPitch"]?.doubleValue {
            musicalTypingPointerDown(pitch: Int(raw))
            return musicalTypingStateResponse()
        }
        // ── m23-cv: chord mode's controls, all through the app-tier funnels. ──
        if let raw = params["playMode"]?.stringValue {
            guard let mode = MusicalTypingPlayMode(rawValue: raw) else {
                throw DebugError("'\(raw)' is not a play mode — one of "
                    + MusicalTypingPlayMode.allCases.map(\.rawValue).joined(separator: " "))
            }
            setMusicalTypingPlayMode(mode)
            return musicalTypingStateResponse()
        }
        if params["chordKey"] != nil || params["chordMode"] != nil {
            var keyMode: KeyMode?
            if let raw = params["chordMode"]?.stringValue {
                guard let parsed = KeyMode(rawValue: raw) else {
                    throw DebugError("'\(raw)' is not a scale — one of "
                        + KeyMode.allCases.map(\.rawValue).joined(separator: " "))
                }
                keyMode = parsed
            }
            let pitchClass = params["chordKey"]?.doubleValue.map { Int($0) }
                ?? musicalTyping.chordKey
            musicalTyping.setChordKey(pitchClass, mode: keyMode)
            return musicalTypingStateResponse()
        }
        if let raw = params["voicingPreset"]?.stringValue {
            guard let kind = VoicingPresetKind(rawValue: raw) else {
                throw DebugError("'\(raw)' is not a voicing preset — one of "
                    + VoicingPresetKind.allCases.map(\.rawValue).joined(separator: " "))
            }
            musicalTyping.setVoicingPreset(kind)
            return musicalTypingStateResponse()
        }
        if let raw = params["progression"]?.stringValue {
            // "" clears the lights, which is a real state and not a missing one.
            guard raw.isEmpty || ChordProgressionLibrary.preset(id: raw) != nil else {
                throw DebugError("'\(raw)' is not a progression — one of "
                    + ChordProgressionLibrary.all.map(\.id).joined(separator: " "))
            }
            musicalTyping.setProgression(raw.isEmpty
                                         ? nil : ChordProgressionLibrary.preset(id: raw))
            return musicalTypingStateResponse()
        }
        if let raw = params["chordCell"]?.doubleValue {
            musicalTypingChordCellDown(cellIndex: Int(raw))
            return musicalTypingStateResponse()
        }
        if let label = params["release"]?.stringValue {
            guard let cap = MusicalTypingRouting.cap(forLabel: label) else {
                throw DebugError("'\(label)' is not a Musical Typing key — "
                    + "one of \(MusicalTypingRouting.allCaps.map(\.label).joined(separator: " "))")
            }
            guard let event = try synthesizeMusicalTypingEvent(
                cap: cap, type: .keyUp, params: params) else {
                throw DebugError("failed to synthesize the key-up event for '\(cap.label)'")
            }
            if params["post"]?.boolValue == true {
                NSApplication.shared.postEvent(event, atStart: false)
                return musicalTypingStateResponse(extra: ["posted": .bool(true)])
            }
            let passed = handleKeyUpEvent(event)
            return musicalTypingStateResponse(extra: ["swallowed": .bool(passed == nil)])
        }
        guard let label = params["press"]?.stringValue else {
            return musicalTypingStateResponse()
        }
        guard let cap = MusicalTypingRouting.cap(forLabel: label) else {
            throw DebugError("'\(label)' is not a Musical Typing key — "
                + "one of \(MusicalTypingRouting.allCaps.map(\.label).joined(separator: " "))")
        }
        guard let event = try synthesizeMusicalTypingEvent(
            cap: cap, type: .keyDown, params: params) else {
            throw DebugError("failed to synthesize the key-down event for '\(cap.label)'")
        }
        if params["post"]?.boolValue == true {
            NSApplication.shared.postEvent(event, atStart: false)
            return musicalTypingStateResponse(extra: ["posted": .bool(true)])
        }
        // ⚠️ THROUGH `handleKeyDownEvent`, NOT `handleMusicalTypingKeyDown` — the
        // FULL body, so the seam also proves the delete and space branches let a
        // note key past. A seam that entered halfway would agree with itself while
        // the live monitor swallowed the key upstream.
        let passed = handleKeyDownEvent(event)
        return musicalTypingStateResponse(extra: [
            "swallowed": .bool(passed == nil),
            "decision": .string(musicalTypingDecisionLabel(passed: passed)),
        ])
    }

    /// ⚠️ **READS THE DECISION, DOES NOT INFER IT.** This used to answer from
    /// whether the monitor swallowed the event — and a swallowed auto-repeat is
    /// indistinguishable from a performed note by that test, so it reported
    /// `performed` for a repeat that sounded nothing. Measured on staging
    /// 2026-08-29 by `_m23ct-musical-typing-smoke.mjs`, which printed the label
    /// instead of asserting a guessed one. `passed` is still taken so the caller's
    /// swallow decision stays visible in the same response.
    private func musicalTypingDecisionLabel(passed: NSEvent?) -> String {
        if case .swallowRepeat = musicalTyping.lastDecision { return "swallowed-repeat" }
        guard passed == nil else {
            return "pass-through:" + (musicalTyping.lastRefusal?.rawValue ?? "other")
        }
        return musicalTyping.lastSilencedBy.map { "silenced:" + $0.rawValue } ?? "performed"
    }

    private func synthesizeMusicalTypingEvent(cap: MusicalTypingKeyCap,
                                              type: NSEvent.EventType,
                                              params: [String: JSONValue]) throws -> NSEvent? {
        var flags: NSEvent.ModifierFlags = []
        if params["command"]?.boolValue == true { flags.insert(.command) }
        if params["option"]?.boolValue == true { flags.insert(.option) }
        if params["control"]?.boolValue == true { flags.insert(.control) }
        if params["shift"]?.boolValue == true { flags.insert(.shift) }
        // `characters` must be non-nil for `NSEvent.keyEvent` to build. It is the
        // US-ANSI legend and is DISPLAY-ONLY — nothing downstream matches on it
        // (the m23-fi lesson: this app's key routing reads key CODES).
        let characters = cap.label.lowercased()
        return NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: params["noWindow"]?.boolValue == true
                ? 0 : (contentWindow?.windowNumber ?? 0),
            context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: type == .keyDown ? (params["repeat"]?.boolValue ?? false) : false,
            keyCode: cap.keyCode)
    }

    /// The state echo: ground truth read FRESH from the controller, the store and
    /// the sink — never the seam's own input (the `arrangeHScrollReported` honesty
    /// rule).
    ///
    /// ⭐ **THREE INSTRUMENTS, DELIBERATELY.** `sounding` is what the on-screen
    /// keyboard DRAWS, `storeHeldPitches` is what `AuditionController` believes is
    /// ringing, and `sinkRequestedPitches` is what the sink last ASKED for. A gate
    /// that could only read one of them would agree with itself through a dead
    /// pipe; two of these disagreeing is the signal.
    func musicalTypingStateResponse(extra: [String: JSONValue] = [:]) -> JSONValue {
        let sink = musicalTyping.sink as? LivePlayNoteSink
        var fields: [String: JSONValue] = [
            "enabled": .bool(musicalTyping.isEnabled),
            "monitorInstalled": .bool(keyDownMonitor != nil),
            "baseOctave": .number(Double(musicalTyping.baseOctave)),
            "baseNote": .number(Double(musicalTyping.baseNote)),
            "baseNoteName": .string(Fundamental.noteName(midiNote: musicalTyping.baseNote)),
            "velocity": .number(Double(musicalTyping.velocity)),
            "targetState": .string(musicalTyping.targetState.rawValue),
            "targetTrackId": activeTrackID.map { .string($0.uuidString) } ?? .null,
            // WHAT THE VIEW DRAWS.
            "sounding": .array(musicalTyping.soundingPitches.map { .number(Double($0)) }),
            "soundingNames": .array(musicalTyping.soundingPitches.map {
                .string(Fundamental.noteName(midiNote: $0))
            }),
            // WHAT THE STORE BELIEVES — a second instrument on the same question.
            // ⚠️ READS `livePlay`, NOT `audition`, SINCE THE SINK WAS SWAPPED.
            // Left pointing at `audition.heldPitches` this would have reported an
            // eternally-empty set while notes played perfectly — a gate failing
            // for a reason that has nothing to do with the feature. `audition`
            // is kept below so the ARBITRATION (starting one stops the other) is
            // visible rather than inferred.
            "storeHeldPitches": .array(store.livePlay.heldPitches.map { .number(Double($0)) }),
            "storeHeldVelocity": .number(Double(store.livePlay.heldVelocity)),
            "storeAuditionHeldPitches": .array(
                store.audition.heldPitches.map { .number(Double($0)) }),
            // WHAT THE SINK LAST ASKED FOR, and why it did not land if it did not.
            "sinkRequestedPitches": .array(
                (sink?.lastRequestedPitches ?? []).map { .number(Double($0)) }),
            "sinkRefusal": sink?.lastRefusal.map { .string($0) } ?? .null,
            // ⭐ THE ENGINE'S OWN ANSWER to "is this being kept?", beside the
            // resolver's PREDICTION (`targetState == "recording-armed"`). Two
            // instruments on one question; disagreement is the signal, and this
            // is the only one of the two that can see a capture session.
            "sinkIsRecording": sink?.lastIsRecording.map { .bool($0) } ?? .null,
            "sinkCapturedEdges": .number(Double(sink?.lastCapturedEdges ?? 0)),
            "targetIsCapturing": .bool(musicalTyping.targetState.isCapturing),
            "targetCanSound": .bool(musicalTyping.targetState.canSound),
            "trackIsArmed": .bool(
                activeTrackID.flatMap { id in store.tracks.first { $0.id == id } }?.isArmed == true),
            "lastRefusal": musicalTyping.lastRefusal.map { .string($0.rawValue) } ?? .null,
            "lastSilencedBy": musicalTyping.lastSilencedBy.map { .string($0.rawValue) } ?? .null,
            // THE LAYOUT ITSELF, so a gate derives its key names from the app's own
            // table rather than from a second copy (the `ArrangeLaneGeometry`
            // ladder rule).
            "keyLabels": .array(MusicalTypingRouting.allCaps.map { .string($0.label) }),
            "noteKeyCount": .number(Double(MusicalTypingRouting.noteCaps.count)),
            // ── m23-cv: chord mode, and the CELLS as the surface derives them,
            // so a gate reads the app's own projection instead of re-deriving the
            // harmony from a second copy of the table.
            "playMode": .string(musicalTyping.playMode.rawValue),
            "chordKey": .number(Double(musicalTyping.chordKey)),
            "chordMode": .string(musicalTyping.chordKeyMode.rawValue),
            "voicingPreset": .string(musicalTyping.voicingPreset.rawValue),
            "progression": musicalTyping.progression.map { .string($0.id) } ?? .null,
            "chordCells": .array(musicalTyping.chordCells.map { cell in
                .object([
                    "key": .string(cell.keyLabel),
                    "degree": .number(Double(cell.degree)),
                    "octaveShift": .number(Double(cell.octaveShift)),
                    "addsColour": .bool(cell.addsColour),
                    "chord": .string(cell.chordName),
                    "numeral": .string(cell.romanNumeral),
                    "lit": .bool(cell.isLit),
                    "order": cell.progressionOrder.map { .number(Double($0)) } ?? .null,
                    "sounding": .bool(
                        musicalTyping.soundingChordKeyCodes.contains(cell.keyCode)),
                ])
            }),
            "auditionEnabled": .bool(panelLayout.auditionEnabled),
            "isRecording": .bool(store.transport.isRecording),
            "reportSeq": .number(Double(musicalTyping.reportSeq)),
        ]
        for (key, value) in extra { fields[key] = value }
        return .object(fields)
    }
}
