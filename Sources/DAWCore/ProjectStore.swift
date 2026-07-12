import Foundation
import Observation

/// A single journaled edit, surfaced by `ProjectStore.lastEditEvent` (M8 ob-b).
/// Carries just enough for an app-side observer to classify the edit and emit the
/// right onboarding tour signal (`editPerformed` vs `mixerAdjusted`) WITHOUT the
/// tour model ever reading `ProjectStore` (design decision 2 of the onboarding
/// doc). `seq` strictly increases per journaled edit — so coalesced same-key edits
/// still tick and a debounced subscriber never misses one; `label` is the undo
/// label and `key` the coalescing key (nil when the edit doesn't coalesce). Value
/// type, `Equatable`/`Sendable`.
public struct EditEvent: Equatable, Sendable {
    /// Strictly-increasing sequence number (1-based), one per journaled edit.
    public let seq: Int
    /// The edit's undo label (e.g. "Set 'Bass' Volume").
    public let label: String
    /// The edit's coalescing key (e.g. "track.volume:<uuid>"), or nil.
    public let key: String?

    public init(seq: Int, label: String, key: String?) {
        self.seq = seq
        self.label = label
        self.key = key
    }
}

/// The single command surface for session state. UI actions and control-protocol
/// commands both land here; if a capability isn't reachable through ProjectStore,
/// it doesn't exist as far as agents are concerned.
@MainActor
@Observable
public final class ProjectStore {
    public private(set) var projectName: String
    /// The session's tracks. Setter is module-`internal` (not `public`) so
    /// `ProjectStore+*` extension files (e.g. `+Takes`) can mutate the model
    /// inside `performEdit` bodies; external callers still go through the store's
    /// named operations.
    public internal(set) var tracks: [Track]
    public private(set) var transport: TransportState
    public private(set) var masterMeter: MeterFrame = .silence
    /// Master output gain 0...2 (1 = unity), applied to the main mix bus.
    public private(set) var masterVolume: Double = 1
    /// Project-level GROOVE palette (M5 iii-g, spec §6): extracted templates,
    /// referenced BY VALUE at quantize time (so deleting one never dangles a
    /// reference). Default empty; undo covers add/remove (it rides `EditState`).
    /// Setter is module-`internal` so `ProjectStore+Quantize` mutates it inside
    /// `performEdit` bodies. Built-in swing presets are NOT stored here — they
    /// resolve on demand (`GrooveTemplate.builtin`).
    public internal(set) var grooveTemplates: [GrooveTemplate] = []
    /// Session markers (m11-c) — named song-section anchors on the timeline.
    /// Kept SORTED by beat as an invariant (ties stable, insertion order) by every
    /// mutation, so this is directly the ordered exposure `marker.list` / the ruler
    /// consume — no separate raw store. A pure value: no media, no engine
    /// involvement; it rides `EditState` (undo add/remove/rename/move) and persists
    /// additively, exactly like `grooveTemplates`. Setter is module-`internal` so
    /// the mutation helpers below (and the load boundary) can rebuild it inside
    /// `performEdit` bodies while external callers go through the named methods.
    public internal(set) var markers: [Marker] = []
    /// Latest per-track meter frame, keyed by track ID. Entries appear when a
    /// track first meters and are dropped when the track is removed.
    public private(set) var trackMeters: [UUID: MeterFrame] = [:]
    /// Why the last record attempt failed (or why the last take was
    /// discarded); nil after a successful take or a fresh record start.
    public private(set) var lastRecordingError: String?
    /// UID of the input device pinned for recording; nil = system default.
    /// Only updated when the engine accepts the selection.
    public private(set) var selectedInputDeviceUID: String?
    /// Absolute path of the `.dawproj` bundle backing this session; nil until
    /// the first successful save-as (untitled). Adopted on save-as and open.
    public private(set) var projectPath: String?
    /// True when the session has edits not yet written to disk. Set by
    /// `markDirty()` on mutations; cleared on save/open/new.
    public private(set) var isDirty = false

    /// Undo/redo history for the whole session. OBSERVED (not
    /// `@ObservationIgnored`) so menu labels track the top of each stack, and
    /// internal (not private) so the DAWCore suite can inspect the stacks and
    /// inject a deterministic clock. Mutated only through `performEdit`,
    /// `undo`, `redo`, and the load-boundary `clear`.
    var journal = UndoJournal()

    /// True when there is an operation to undo/redo; drives the menu enablement.
    public var canUndo: Bool { journal.undoLabel != nil }
    public var canRedo: Bool { journal.redoLabel != nil }
    /// Label of the next undoable/redoable operation (e.g. "Set Master
    /// Volume"), for the "Undo <label>" / "Redo <label>" menu items.
    public var undoLabel: String? { journal.undoLabel }
    public var redoLabel: String? { journal.redoLabel }

    /// A read-only projection of the whole undo/redo history's LABELS (m11-b) —
    /// the backing for the history panel and the `edit.history` wire command. Both
    /// lists are NEWEST-FIRST: `undo[0]` is what `undo()` reverses next, `redo[0]`
    /// is what `redo()` reapplies next (see `UndoHistory`). A PURE read — it never
    /// mutates the journal and adds NO new mutation surface; the panel steps only
    /// through `undo()`/`redo()`, so the coalescing barrier and the mid-take
    /// `transportBusy` guard always apply. Reads the OBSERVED `journal`, so a
    /// SwiftUI view calling this re-renders when history changes.
    public func undoHistory() -> UndoHistory {
        UndoHistory(undo: journal.undoLabels, redo: journal.redoLabels)
    }

    /// The most recently journaled edit — set inside `performEdit` EXACTLY when a
    /// journal entry actually records (a genuine state change; a no-op edit leaves
    /// it untouched, the humanize zero-jitter precedent). `seq` strictly increases
    /// so coalesced same-key edits still tick. Public/observable so an app-side
    /// observer (the M8 onboarding signal adapter, ob-b) can classify the edit and
    /// emit the matching tour signal WITHOUT the tour model reading `ProjectStore`.
    /// A live session fact, never persisted into the project file.
    public private(set) var lastEditEvent: EditEvent?
    /// Monotonic edit sequence counter behind `lastEditEvent.seq`. Not observed —
    /// only `lastEditEvent` drives the app's observation.
    @ObservationIgnored private var editEventSeq = 0

    /// How many bounces/mixdowns have finished writing a file this session —
    /// incremented on every successful `renderBounce` / `renderMixdown` return
    /// (M8 ob-b). Public/observable so the onboarding signal adapter fires
    /// `renderCompleted` on an increment; `internal(set)` because `renderBounce`
    /// lives in the `ProjectStore+Render` extension file. A monotonic session
    /// counter, never persisted.
    public internal(set) var renderCompletedCount = 0

    /// Background 30-s autosave loop; nil when not running. Not observed.
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// Background 30-s crash-recovery autosave loop (M9 crash-b); nil when not
    /// running. Not observed. Separate from `autosaveTask` — the app runs this one.
    @ObservationIgnored private var crashAutosaveTask: Task<Void, Never>?
    /// Stable slug for THIS store's untitled-recovery bundle so repeated
    /// autosaves overwrite one slot rather than littering. Not observed.
    @ObservationIgnored private let recoverySlug = String(UUID().uuidString.prefix(8))
    /// Base directory for untitled-recovery autosave bundles. Defaults to the
    /// real Application Support location; a test seam points it at a temp dir so
    /// autosave never writes into the user's real profile.
    @ObservationIgnored var autosaveRecoveryDirectory = ProjectStore.defaultAutosaveDirectory()

    /// Whether a launch crash-recovery offer is currently on the table (m10-s).
    /// OBSERVED (not `@ObservationIgnored`) so the launch sheet's host can react
    /// when the offer is resolved by ANY path — the `project.recover` wire command
    /// or a `project.new`/`project.open` transition — not just by the sheet's own
    /// buttons (the m10-s bug: a wire-resolved offer lingered on screen because the
    /// one-shot `AppModel.recoveryOffer` snapshot never observed the store).
    ///
    /// Contract: it goes TRUE only at the single legitimate arm point,
    /// `beginCrashDetection()` (launch), and FALSE at every point the offer stops
    /// being available — both `recoverFromAutosave` branches and every
    /// crash-recovery `invalidate()` (save/new/open supersede), all routed through
    /// `invalidateCrashRecovery()`. It mirrors `crashRecovery.recoveryStatus()
    /// .available`, but as a stored @Observable fact the app can subscribe to.
    /// This is DISTINCT from `AppModel.recoveryOffer`, which the debug-tier
    /// `debug.recoveryOffer` staging still drives directly for captures (that path
    /// leaves this flag false and unchanging, so the app's transition observer
    /// never fires against it).
    public private(set) var recoveryOfferAvailable = false

    /// Crash-recovery autosave engine (M9 crash-b) — the rolling `autosave.dawproject`
    /// snapshot + `manifest.json` + `session.lock` in the Autosave dir, SEPARATE
    /// from `startAutosave`/`autosaveIfNeeded` (which save the user's file in place
    /// or write a per-slug recovery bundle). Never touches the user's project file;
    /// its snapshot is offered back only after a crash. Injected in tests
    /// (`store.crashRecovery.directory` / `.clock`) — the OnboardingStateBacking /
    /// PanelDensity injection idiom.
    @ObservationIgnored public var crashRecovery = AutosaveManager()

    /// Diagnostics-bundle writer (M9 beta) — the headless engine behind
    /// `writeFeedbackBundle`/`app.feedbackBundle`. Injected in tests
    /// (`store.diagnostics.outputDir` / `.crashReportsDir` / `.clock`) so a bundle
    /// never lands in the real profile and never scans the real crash-report store
    /// — the `crashRecovery` idiom. Makes NO network calls and reads NO key
    /// material.
    @ObservationIgnored public var diagnostics = DiagnosticsReporter()

    /// Injected engine; nil in headless tests.
    public weak var engine: (any AudioEngineControlling)? {
        didSet {
            engine?.meteringHandler = { [weak self] frame in
                self?.masterMeter = frame
            }
            engine?.trackMeteringHandler = { [weak self] id, frame in
                self?.trackMeters[id] = frame
            }
            // Engine-derived playhead is the source of truth while playing.
            // This path only assigns display state — it NEVER calls back into
            // the engine, so playhead pushes cannot cause feedback loops.
            engine?.playheadHandler = { [weak self] beats in
                self?.transport.positionBeats = beats
            }
        }
    }

    /// Injected media service that reads audio-file facts at import time;
    /// nil in headless tests unless a fake is provided.
    public var media: (any MediaImporting)?

    /// Sound-bank resolution/discovery (m10-n). Default: the real library
    /// directories; injectable so tests point it at temp dirs. m10-n-1 uses
    /// only `resolve` (set-time validation); the scan/import/program
    /// forwarders arrive with m10-n-2.
    @ObservationIgnored public var soundBankLibrary = SoundBankLibrary()

    /// Injected AI song-generation source (M6 iii-a): resolves a generation
    /// jobId to its finished local audio + metas for `importGeneration`. The
    /// app wires the real `SongGenerating`-backed adapter here (DAWControl);
    /// nil in headless tests unless a fake is provided.
    public var generationSource: (any GenerationImporting)?

    /// Base directory for imported generated audio (M6 iii-a). The sidecar
    /// client downloads finished audio into a VOLATILE temp cache that can be
    /// swept; `importGeneration` copies the WAV here — a stable, project-
    /// adjacent home (sibling of the recordings scratch) that survives until a
    /// save folds it into the `.dawproj` `media/` (planMedia). Defaults to the
    /// real Application Support location; a public seam so tests (and a future
    /// relocation preference) can point it elsewhere.
    @ObservationIgnored public var generationImportsDirectory =
        ProjectStore.defaultGenerationImportsDirectory()

    /// In-flight AI clip fixes, jobId-keyed (M6 v-b). In-memory only: cleared by
    /// project.open/new, not persisted (a pending fix does not survive relaunch
    /// — re-run ai.fixClipRegion). Observed so the future UI can badge it; the
    /// `ProjectStore+ClipFix` extension mutates it inside the module.
    public internal(set) var pendingClipFixes: [String: PendingClipFix] = [:]

    /// Save-time Audio Unit state capture: returns the CURRENT
    /// `fullStateForDocument` (binary plist) for the given track's hosted AU,
    /// or nil to keep whatever stateData the descriptor already carries. The
    /// app wires this to `engine.instrumentState(forTrack:)`; headless tests
    /// leave it nil.
    public var instrumentStateProvider: (@MainActor (UUID) -> Data?)?

    /// The insert-effect mirror (M4 v): returns the CURRENT
    /// `fullStateForDocument` for the given EFFECT id's hosted AU, or nil to
    /// keep whatever stateData the descriptor already carries. The app wires
    /// this to `engine.effectState(forEffect:)`; headless tests leave it nil.
    public var effectStateProvider: (@MainActor (UUID) -> Data?)?

    private var playbackTask: Task<Void, Never>?

    // MARK: Recording state (snapshotted per take)

    /// Destinations and timing captured at record start. Arm toggles mid-take
    /// deliberately do NOT change where the finished take lands.
    private struct PendingTake {
        let armedTrackIDs: [UUID]
        let armedInstrumentTrackIDs: [UUID]
        let recordStartBeats: Double
        /// Map frozen at record start (m12-b; design §3.4 — tempo is fixed
        /// per take, `setTempo` refuses mid-take, so the freeze is exact).
        let tempoMap: TempoMap
        let takeNumber: Int
    }

    @ObservationIgnored private var pendingTake: PendingTake?
    @ObservationIgnored private var takeCounter = 0
    @ObservationIgnored private var cachedSessionRecordingDir: URL?

    /// Lazy per-store session directory:
    /// ~/Library/Application Support/DAWPro/Recordings/session-<uuid8>/.
    /// Only the URL is minted here — the engine's writer creates parent dirs.
    private var sessionRecordingDir: URL {
        if let cachedSessionRecordingDir { return cachedSessionRecordingDir }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent("session-\(UUID().uuidString.prefix(8))", isDirectory: true)
        cachedSessionRecordingDir = dir
        return dir
    }

    /// Discards this session's recording scratch: a fresh session directory is
    /// minted on the next take (new uuid) and take numbering restarts at 1.
    /// Called when the session identity changes (open/new) so takes from the
    /// previous project can't bleed into the new one.
    private func resetRecordingScratch() {
        cachedSessionRecordingDir = nil
        takeCounter = 0
        pendingTake = nil
    }

    public init(
        projectName: String = "Untitled Session",
        tracks: [Track] = [],
        transport: TransportState = TransportState()
    ) {
        self.projectName = projectName
        self.tracks = tracks
        self.transport = transport
    }

    deinit {
        // Task is Sendable and cancel() is nonisolated — safe from a nonisolated
        // deinit even though the store is @MainActor.
        autosaveTask?.cancel()
        crashAutosaveTask?.cancel()
    }

    // MARK: - Transport

    public func play() {
        guard !transport.isPlaying else { return }
        transport.isPlaying = true
        if let engine {
            try? engine.prepare()
            engine.startPlayback(transport)
        } else {
            // Headless (tests, no audio hardware injected): free-running
            // display ticker keeps the playhead honest.
            startPositionTicker()
        }
    }

    public func stop() {
        guard transport.isPlaying || transport.isRecording else { return }
        let wasRecording = transport.isRecording
        transport.isPlaying = false
        transport.isRecording = false
        playbackTask?.cancel()
        playbackTask = nil
        if wasRecording {
            // stopRecording halts playback internally AND finalizes the take —
            // calling stopPlayback here would tear the transport down twice.
            engine?.stopRecording()
        } else {
            engine?.stopPlayback()
        }
        // Meters read as dark the instant transport stops, regardless of what
        // the engine's final pushes were. Keys survive so track rows keep
        // their (silent) bars without re-registration on the next play.
        for key in trackMeters.keys {
            trackMeters[key] = .silence
        }
        masterMeter = .silence
    }

    public func seek(toBeats beats: Double) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot seek while recording — stop first")
        }
        transport.positionBeats = max(0, beats)
        engine?.seek(transport)
    }

    public func returnToZero() throws {
        try seek(toBeats: 0)
    }

    public func setTempo(_ bpm: Double) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot change tempo while recording — stop first")
        }
        performEdit("Set Tempo", key: "transport.tempo") {
            applyTempoChange(bpm)
        }
    }

    /// Sets the transport tempo (clamped), pushes it to the engine, and
    /// re-flattens every take group — members were windowed at the previous
    /// tempo (their source offsets are tempo-derived), so this keeps them
    /// coherent. Does NOT open its own `performEdit`: `setTempo` wraps it in
    /// one, and `importGeneration` (M6 iii-a) folds it into the SAME "Import
    /// Generation" edit so a single undo restores the tempo with the track.
    /// Kept here (not an extension) because `transport` has a private setter.
    /// m12-b (design row 8): still the scalar segment-0 edit — Phase C turns
    /// this into the map-mutation entry point; the re-flatten hook (which now
    /// flattens through `transport.tempoMap`) is retained unchanged.
    func applyTempoChange(_ bpm: Double) {
        transport.tempoBPM = bpm.clamped(to: TransportState.tempoRange)
        engine?.setTempo(transport)
        for t in tracks.indices {
            for g in tracks[t].takeGroups.indices {
                rebuildCompMembers(trackIndex: t, groupIndex: g)
            }
        }
    }

    /// Phase-B staging seam — replaced by tempo.setMap in Phase C. Installs a
    /// session-only multi-segment tempo map (nil ⇒ back to the scalar-derived
    /// trivial map) and pushes it to the engine through the SAME `setTempo`
    /// restart seam a scalar tempo change uses — mid-play the engine restarts
    /// from its OWN derived beats under the new map (the live-gate contract).
    /// Deliberately NOT an edit: no `performEdit`, no undo journal entry, no
    /// dirty mark, never persisted or snapshotted (the override is excluded
    /// from `TransportState.CodingKeys` and normalized out of undo capture),
    /// and it resets with the transport on project open/new. Take-group
    /// re-flattening is NOT triggered (staging-only; Phase C's real map
    /// mutation owns that hook). Refused while recording, like `setTempo`.
    public func installSessionTempoMap(_ map: TempoMap?) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot change the tempo map while recording — stop first")
        }
        transport.sessionTempoMapOverride = map
        engine?.setTempo(transport)
    }

    /// Sets the loop region fields and notifies the engine WITHOUT opening its
    /// own `performEdit` — the mirror of `applyTempoChange` for the loop. The
    /// song-skeleton macro (M7 macro-c) folds this into its single "Song
    /// Skeleton" edit so ONE undo restores the whole scaffold (tempo, tracks,
    /// clips, loop). Kept here (not an extension) because `transport` has a
    /// private setter. Callers own range validity: `end` must sit at least
    /// `TransportState.minLoopLengthBeats` past `start` (the skeleton's total
    /// arrangement length is always >= 4 beats, so this holds).
    func applyLoopRegion(enabled: Bool, startBeat: Double, endBeat: Double) {
        transport.isLoopEnabled = enabled
        transport.loopStartBeat = max(0, startBeat)
        transport.loopEndBeat = endBeat
        engine?.loopChanged(transport)
    }

    // MARK: - Recording

    /// True when at least one audio track is record-armed.
    public var hasArmedAudioTracks: Bool {
        tracks.contains { $0.kind == .audio && $0.isArmed }
    }

    /// True when at least one instrument track is record-armed (MIDI capture).
    public var hasArmedInstrumentTracks: Bool {
        tracks.contains { $0.kind == .instrument && $0.isArmed }
    }

    /// Arms/disarms an audio or instrument track for recording. Returns false
    /// for an unknown id; throws for bus tracks. Arming an AUDIO track while
    /// the microphone decision is still undetermined fires the system prompt
    /// (fire-and-forget) so the answer is usually in place before the first
    /// record(); instrument tracks never touch the microphone. Arming an
    /// INSTRUMENT track warms the engine (`prepare()`) so live MIDI thru
    /// sounds while the transport is stopped.
    @discardableResult
    public func setTrackArm(id: UUID, armed: Bool) throws -> Bool {
        // Kind and permission-prompt guards stay OUTSIDE the edit body.
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return false }
        guard tracks[index].kind == .audio || tracks[index].kind == .instrument else {
            throw ProjectError.trackKindUnsupported(tracks[index].kind)
        }
        let kind = tracks[index].kind
        editTrack(id: id, label: "\(armed ? "Arm" : "Disarm") '\(tracks[index].name)'") { $0.isArmed = armed }
        if armed, kind == .audio, let engine, engine.recordPermission == .undetermined {
            engine.requestRecordPermission { _ in }  // decision lands in the OS; record() re-checks
        }
        if armed, kind == .instrument {
            try? engine?.prepare()  // graph hot: thru sounds before playback ever starts
        }
        return true
    }

    /// Starts recording from the current playhead onto every armed audio AND
    /// instrument track: one capture file per take fanned out as one clip per
    /// armed audio track, plus one MIDI clip per armed instrument track, when
    /// the take finalizes. STOPPED state only. With punch enabled, transport
    /// and capture still start from the current position, but only the AUDIO
    /// inside [punchInBeat, punchOutBeat] is kept — MIDI capture is NOT
    /// trimmed by the punch window (v0: notes are individually editable after
    /// the fact). Microphone permission gates run only when audio tracks are
    /// armed. Every throw also lands in `lastRecordingError`.
    public func record() throws {
        guard let engine else {
            throw recordFailure(.engineUnavailable)
        }
        guard !transport.isPlaying, !transport.isRecording else {
            throw recordFailure(.transportBusy(
                "stop playback before recording — recording starts from a stopped transport (set a punch window to record into a range)"
            ))
        }
        let armedAudioIDs = tracks.filter { $0.kind == .audio && $0.isArmed }.map(\.id)
        let armedInstrumentIDs = tracks.filter { $0.kind == .instrument && $0.isArmed }.map(\.id)
        guard !armedAudioIDs.isEmpty || !armedInstrumentIDs.isEmpty else {
            throw recordFailure(.noArmedTracks)
        }
        // Audio-capture gates apply only when audio tracks are armed — a
        // MIDI-only take needs no punch sanity (punch never trims MIDI) and
        // must never fire the microphone prompt.
        if !armedAudioIDs.isEmpty {
            // Punch sanity before the permission gates (which can fire the
            // system prompt): a window wholly behind the playhead could never
            // capture a single frame — the whole take would be trimmed away.
            if transport.isPunchEnabled, transport.punchOutBeat <= transport.positionBeats {
                throw recordFailure(.invalidPunchRange(
                    "punch window is behind the playhead — seek before punch in or disable punch"
                ))
            }
            switch engine.recordPermission {
            case .denied:
                throw recordFailure(.recordPermissionDenied)
            case .undetermined:
                engine.requestRecordPermission { _ in }
                throw recordFailure(.recordPermissionPending)
            case .granted:
                break
            }
        }

        // Snapshot destinations and timing NOW: arm toggles mid-take must not
        // change where the finished take lands.
        let take = takeCounter + 1
        let pending = PendingTake(
            armedTrackIDs: armedAudioIDs,
            armedInstrumentTrackIDs: armedInstrumentIDs,
            recordStartBeats: transport.positionBeats,
            tempoMap: transport.tempoMap,
            takeNumber: take
        )
        takeCounter = take
        // MIDI-only takes create no capture file at all.
        let url: URL? = armedAudioIDs.isEmpty
            ? nil
            : sessionRecordingDir.appendingPathComponent("take-\(take).wav")

        lastRecordingError = nil
        pendingTake = pending
        transport.isRecording = true
        transport.isPlaying = true
        do {
            try engine.startTake(transport, audioURL: url,
                                 captureMIDI: !armedInstrumentIDs.isEmpty) { [weak self] result in
                self?.finishTake(result)
            }
        } catch {
            transport.isRecording = false
            transport.isPlaying = false
            pendingTake = nil
            lastRecordingError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            throw error
        }
    }

    /// Marks a record() precondition failure in `lastRecordingError` and hands
    /// the error back for throwing. Transport is untouched on these paths.
    private func recordFailure(_ error: ProjectError) -> ProjectError {
        lastRecordingError = error.errorDescription
        return error
    }

    /// Engine completion for one finalized take: turn the capture file into
    /// one clip per (still-existing) armed audio track AND the captured MIDI
    /// into one clip per (still-existing) armed instrument track — all inside
    /// ONE `performEdit("Record Take N")`, so a recorded take is one undo
    /// step. Or surface the failure.
    private func finishTake(_ result: Result<TakeResult, Error>) {
        let pending = pendingTake
        pendingTake = nil
        switch result {
        case .success(let take):
            guard let pending else { return }  // no take in flight — stale completion
            let audio = take.audio
            // Land geometry through the take's FROZEN map (m12-b, design rows
            // 9–10): the clip start is the inverse integral of the writer's
            // anchor-relative offset from the record-start beat, and the
            // length is the inverse integral of the file duration from that
            // start. Start computed FIRST — the length integrates from it.
            let audioStartBeat = audio.map {
                pending.tempoMap.beat(from: pending.recordStartBeats,
                                      elapsedSeconds: $0.startOffsetSeconds)
            } ?? pending.recordStartBeats
            let audioLengthBeats = audio.map {
                pending.tempoMap.beat(from: audioStartBeat,
                                      elapsedSeconds: $0.info.durationSeconds) - audioStartBeat
            } ?? 0
            let audioLands = audio != nil && audioLengthBeats > 0
            let midiLands = !(take.midi?.notes.isEmpty ?? true)
            guard audioLands || midiLands else {
                // Nothing to land. A MIDI-only take with zero notes gets its
                // own readable reason; a mixed take with a landed side never
                // reaches here.
                lastRecordingError = audio == nil && take.midi != nil
                    ? "empty take discarded — no MIDI notes received"
                    : "empty take discarded"
                return
            }
            // Punched takes need NO special casing here: the writer's accept
            // window trims capture to [punchIn, punchOut], so
            // startOffsetSeconds ≈ punch-in − record start (+ capture lag) and
            // durationSeconds ≈ the window's length — this same formula lands
            // the clip at the punch-in point with the window's length. MIDI
            // clips land at the record start: punch does NOT trim MIDI (v0).
            performEdit("Record Take \(pending.takeNumber)") {
                if let audio, audioLands {
                    let startBeat = audioStartBeat
                    for trackID in pending.armedTrackIDs {
                        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { continue }
                        let newClip = Clip(
                            name: "\(tracks[index].name) Take \(pending.takeNumber)",
                            startBeat: startBeat,
                            lengthBeats: audioLengthBeats,
                            audioFileURL: audio.fileURL,
                            isAIGenerated: false
                        )
                        // Take auto-grouping (M5 iii-b, spec §3, AUDIO-ONLY):
                        // re-recording over a region groups instead of stacking
                        // sum-overlap clips. Consumes the clip into a take group
                        // when it lands; falls through to the plain append
                        // (today's behavior) otherwise. Runs inside THIS
                        // performEdit so a grouped take is still one undo step.
                        if !autoGroupRecordedTake(trackIndex: index, newClip: newClip) {
                            tracks[index].clips.append(newClip)
                        }
                    }
                }
                if let midi = take.midi, midiLands {
                    for trackID in pending.armedInstrumentTrackIDs {
                        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { continue }
                        tracks[index].clips.append(Clip(
                            name: "\(tracks[index].name) Take \(pending.takeNumber)",
                            startBeat: pending.recordStartBeats,
                            lengthBeats: midi.lengthBeats,
                            notes: midi.notes
                        ))
                    }
                }
                engine?.tracksDidChange(tracks)
            }
        case .failure(let error):
            lastRecordingError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    // MARK: - Master-mix analysis (M8 vm-a)

    /// Latest master-mix analysis snapshot as the engine reports it —
    /// poll-based like the meters, `.floor` when running headless (no
    /// engine injected) or when the session is stopped/silent.
    public func masterAnalysis() -> MasterAnalysisSnapshot {
        engine?.masterAnalysis() ?? .floor
    }

    // MARK: - Engine performance telemetry (M9 perf-b)

    /// Render-load / overrun counters as the engine reports them —
    /// poll-based like the meters, `.idle` when running headless (no engine
    /// injected). `reset: true` returns the closing profiling window and
    /// starts a fresh one (the windowed-measurement idiom perf-c uses).
    public func performanceStats(reset: Bool = false) -> EnginePerformanceStats {
        engine?.performanceStats(reset: reset) ?? .idle
    }

    // MARK: - Engine watchdog (M9 crash-c)

    /// Engine watchdog state as the engine reports it — poll-based like the
    /// telemetry above, `.idle` when running headless (no engine injected).
    public func watchdogStatus() -> EngineWatchdogStatus {
        engine?.watchdogStatus() ?? .idle
    }

    // MARK: - Input devices

    /// Hardware input devices as the engine sees them; empty when running
    /// headless (no engine injected).
    public func listInputDevices() -> [AudioInputDevice] {
        engine?.availableInputDevices() ?? []
    }

    /// MIDI input sources as the engine sees them; empty when running
    /// headless. First call may lazily create the engine's CoreMIDI client.
    public func listMIDIInputs() -> [MIDIInputDevice] {
        engine?.availableMIDIInputs() ?? []
    }

    /// Pins recording input to the device with `uid`; nil returns to the
    /// system default. Takes effect on the next take — switching mid-take is
    /// refused. `selectedInputDeviceUID` updates only when the engine accepts
    /// the selection (unknown-uid errors pass through untouched).
    public func selectInputDevice(uid: String?) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot switch input device while recording — stop first")
        }
        try engine?.setInputDevice(uid: uid)
        selectedInputDeviceUID = uid
    }

    /// Enables/disables the loop region and optionally moves its bounds. Passing
    /// nil for a beat keeps the current value, so the UI can toggle looping
    /// without re-stating the range. Throws when the resulting region is empty
    /// or inverted; the engine is only notified after validation passes.
    public func setLoop(enabled: Bool, startBeat: Double? = nil, endBeat: Double? = nil) throws {
        let start = max(0, startBeat ?? transport.loopStartBeat)
        let end = endBeat ?? transport.loopEndBeat
        guard end > start else {
            throw ProjectError.invalidLoopRange("loop end must be after loop start")
        }
        performEdit("Change Loop", key: "transport.loop") {
            transport.isLoopEnabled = enabled
            transport.loopStartBeat = start
            transport.loopEndBeat = end
            engine?.loopChanged(transport)
        }
    }

    /// Enables/disables the punch recording window and optionally moves its
    /// bounds. Passing nil for a beat keeps the current value, so the UI can
    /// toggle punch without re-stating the range. No engine intent goes out —
    /// the engine reads the punch fields from the TransportState handed to
    /// startRecording, which is exactly why changes are refused mid-take: they
    /// could never apply to the rolling take.
    public func setPunch(enabled: Bool, inBeat: Double? = nil, outBeat: Double? = nil) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot change punch window while recording — stop first")
        }
        let start = max(0, inBeat ?? transport.punchInBeat)
        let end = outBeat ?? transport.punchOutBeat
        guard end > start else {
            throw ProjectError.invalidPunchRange("punch out must be after punch in")
        }
        performEdit("Change Punch", key: "transport.punch") {
            transport.isPunchEnabled = enabled
            transport.punchInBeat = start
            transport.punchOutBeat = end
        }
    }

    /// Enables/disables the metronome click and optionally sets the count-in
    /// length in bars (clamped to `TransportState.countInBarsRange`; nil keeps
    /// the current value). Refused mid-take: the rolling take's click schedule
    /// is already committed. No dedicated engine intent exists — the engine
    /// reads metronome state from the TransportState handed to each
    /// start/restart, so a change while STOPPED simply applies on the next
    /// start. While PLAYING (not recording) we reuse the existing seek/restart
    /// path so the click audibly starts/stops now: `transport.positionBeats`
    /// is engine-pushed (the authoritative current position), so `seek`
    /// restarts from "here" with the new metronome state. Costs the restart
    /// primitive's ~60 ms lead-in seam — acceptable v0 (documented tradeoff;
    /// gapless click toggling needs live player scheduling).
    public func setMetronome(enabled: Bool, countInBars: Int? = nil) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot change metronome while recording — stop first")
        }
        performEdit("Change Metronome") {
            transport.isMetronomeEnabled = enabled
            if let countInBars {
                transport.countInBars = countInBars.clamped(to: TransportState.countInBarsRange)
            }
            if transport.isPlaying {
                engine?.seek(transport)
            }
        }
    }

    // MARK: - Session markers (m11-c)

    /// Stable sort of markers by beat: ties keep their existing relative order
    /// (Swift's `sorted(by:)` is NOT guaranteed stable, so sort on `(beat, index)`
    /// with the current index as the tiebreak). The single funnel every marker
    /// mutation re-applies so `markers` is always the ordered exposure.
    private static func markersSortedByBeat(_ markers: [Marker]) -> [Marker] {
        markers.enumerated()
            .sorted { a, b in
                a.element.beat != b.element.beat ? a.element.beat < b.element.beat : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Adds a marker at `beat` (clamped >= 0 by `Marker.init`), auto-naming an
    /// empty/nil name "Marker N" (N = the new count, the `addTrack` idiom). ONE
    /// undo step ("Add Marker '<name>'"); the list re-sorts by beat. Returns the
    /// created marker so the wire can echo its id.
    @discardableResult
    public func addMarker(name: String? = nil, beat: Double) -> Marker {
        let resolvedName = name?.isEmpty == false ? name! : "Marker \(markers.count + 1)"
        let marker = Marker(name: resolvedName, beat: beat)
        performEdit("Add Marker '\(marker.name)'") {
            markers = Self.markersSortedByBeat(markers + [marker])
        }
        return marker
    }

    /// Removes the marker with `id`. Throws `markerNotFound` when absent (the
    /// wire maps it to a field-named error). ONE undo step ("Remove Marker
    /// '<name>'").
    public func removeMarker(id: UUID) throws {
        guard let marker = markers.first(where: { $0.id == id }) else {
            throw ProjectError.markerNotFound(id)
        }
        performEdit("Remove Marker '\(marker.name)'") {
            markers.removeAll { $0.id == id }
        }
    }

    /// Renames the marker with `id`. Throws `markerNotFound` when absent. Follows
    /// the `renameTrack` rules the UI's `TrackRename` also enforces: a trimmed,
    /// non-empty, actually-changed name commits ONE undo step ("Rename Marker
    /// '<name>'"); an empty or unchanged name is a no-op (no stray undo entry).
    /// Returns the resulting marker (unchanged on a no-op).
    @discardableResult
    public func renameMarker(id: UUID, name: String) throws -> Marker {
        guard let index = markers.firstIndex(where: { $0.id == id }) else {
            throw ProjectError.markerNotFound(id)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != markers[index].name else { return markers[index] }
        performEdit("Rename Marker '\(trimmed)'") {
            markers[index].name = trimmed
        }
        return markers[index]
    }

    /// Moves the marker with `id` to `beat` (clamped >= 0). Throws
    /// `markerNotFound` when absent. Coalesces under `marker.move:<id>` so a live
    /// drag scrub folds into ONE undo step ("Move Marker '<name>'", the
    /// `clip.quantize` precedent); the list re-sorts by beat. Returns the moved
    /// marker.
    @discardableResult
    public func moveMarker(id: UUID, beat: Double) throws -> Marker {
        guard let marker = markers.first(where: { $0.id == id }) else {
            throw ProjectError.markerNotFound(id)
        }
        performEdit("Move Marker '\(marker.name)'", key: "marker.move:\(id.uuidString)") {
            var updated = marker
            updated.beat = max(0, beat)
            markers = Self.markersSortedByBeat(markers.map { $0.id == id ? updated : $0 })
        }
        // The list re-sorted; return the fresh value (same id).
        return markers.first(where: { $0.id == id }) ?? marker
    }

    // MARK: - Mixer

    /// Sets the master output gain, clamped to `Track.volumeRange` (0...2).
    public func setMasterVolume(_ volume: Double) {
        performEdit("Set Master Volume", key: "mixer.master") {
            masterVolume = volume.clamped(to: Track.volumeRange)
            engine?.masterVolumeChanged(masterVolume)
        }
    }

    // MARK: - Tracks

    @discardableResult
    public func addTrack(name: String? = nil, kind: TrackKind = .audio) -> Track {
        let defaultName = "\(kind == .bus ? "Bus" : kind == .instrument ? "Inst" : "Audio") \(tracks.filter { $0.kind == kind }.count + 1)"
        let track = Track(name: name?.isEmpty == false ? name! : defaultName, kind: kind)
        performEdit("Add Track '\(track.name)'") {
            tracks.append(track)
            engine?.tracksDidChange(tracks)
        }
        return track
    }

    @discardableResult
    public func removeTrack(id: UUID) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return false }
        let name = tracks[index].name
        let isBus = tracks[index].kind == .bus
        performEdit("Remove Track '\(name)'") {
            tracks.remove(at: index)
            // Deleting a bus orphans every route into it. Inside this SAME edit
            // (so one undo restores routing and sends together): tracks that
            // output to the bus fall back to master, and sends targeting it are
            // dropped. Deterministic, silent fallback — the control layer reports
            // the counts from the pre-removal state.
            if isBus {
                for i in tracks.indices {
                    if tracks[i].outputBusID == id { tracks[i].outputBusID = nil }
                    // Capture the sends about to be dropped so their automation
                    // lanes drop in this SAME step (one undo restores all three).
                    let droppedSendIDs = Set(
                        tracks[i].sends.filter { $0.destinationBusID == id }.map(\.id))
                    tracks[i].sends.removeAll { $0.destinationBusID == id }
                    if !droppedSendIDs.isEmpty {
                        tracks[i].automation.removeAll { lane in
                            if case .sendLevel(let sid) = lane.target {
                                return droppedSendIDs.contains(sid)
                            }
                            return false
                        }
                    }
                }
            }
            trackMeters.removeValue(forKey: id)
            engine?.tracksDidChange(tracks)
        }
        return true
    }

    /// Mutation core for every single-track edit: looks up the track, runs the
    /// caller's mutation, re-applies value invariants, reconciles the engine,
    /// and journals the whole thing under one undo `label`/`key`. Callers keep
    /// their own guards (kind checks, permission prompts) OUTSIDE this body.
    @discardableResult
    private func editTrack(id: UUID, label: String, key: String? = nil,
                           _ mutate: (inout Track) -> Void) -> Bool {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return false }
        performEdit(label, key: key) {
            mutate(&tracks[index])
            // Re-apply invariants regardless of what the mutation did.
            tracks[index].volume = tracks[index].volume.clamped(to: Track.volumeRange)
            tracks[index].pan = tracks[index].pan.clamped(to: Track.panRange)
            engine?.tracksDidChange(tracks)
        }
        return true
    }

    @discardableResult
    public func updateTrack(id: UUID, _ mutate: (inout Track) -> Void) -> Bool {
        guard let name = trackName(id) else { return false }
        return editTrack(id: id, label: "Edit Track '\(name)'", mutate)
    }

    @discardableResult
    public func setTrackVolume(id: UUID, volume: Double) -> Bool {
        guard let name = trackName(id) else { return false }
        return editTrack(id: id, label: "Set '\(name)' Volume",
                         key: "track.volume:\(id.uuidString)") { $0.volume = volume }
    }

    @discardableResult
    public func setTrackPan(id: UUID, pan: Double) -> Bool {
        guard let name = trackName(id) else { return false }
        return editTrack(id: id, label: "Set '\(name)' Pan",
                         key: "track.pan:\(id.uuidString)") { $0.pan = pan }
    }

    @discardableResult
    public func setTrackMute(id: UUID, muted: Bool) -> Bool {
        guard let name = trackName(id) else { return false }
        return editTrack(id: id, label: "\(muted ? "Mute" : "Unmute") '\(name)'") { $0.isMuted = muted }
    }

    @discardableResult
    public func setTrackSolo(id: UUID, soloed: Bool) -> Bool {
        guard let name = trackName(id) else { return false }
        return editTrack(id: id, label: "\(soloed ? "Solo" : "Unsolo") '\(name)'") { $0.isSoloed = soloed }
    }

    @discardableResult
    public func renameTrack(id: UUID, name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return editTrack(id: id, label: "Rename Track") { $0.name = name }
    }

    // MARK: - Bus routing & sends (M4 i)

    /// Routes a source (audio/instrument) track's output to a bus, or back to
    /// the master mix when `busID` is nil. Guards live OUTSIDE the edit body
    /// (import/clip family precedent): unknown track → `trackNotFound`; a bus
    /// source → `busRoutingFixed` (buses always output to master in v0); a
    /// missing destination → `trackNotFound`; a non-bus destination → `notABus`.
    public func setTrackOutput(id: UUID, busID: UUID?) throws {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else {
            throw ProjectError.trackNotFound(id)
        }
        guard tracks[index].kind != .bus else { throw ProjectError.busRoutingFixed }
        if let busID {
            guard let destIndex = tracks.firstIndex(where: { $0.id == busID }) else {
                throw ProjectError.trackNotFound(busID)
            }
            guard tracks[destIndex].kind == .bus else { throw ProjectError.notABus(busID) }
        }
        let name = tracks[index].name
        editTrack(id: id, label: "Set '\(name)' Output") { $0.outputBusID = busID }
    }

    /// Adds a post-fader send from a source track into a bus. Guards OUTSIDE the
    /// edit body: unknown track → `trackNotFound`; a bus source → `busRoutingFixed`;
    /// missing destination → `trackNotFound`; non-bus destination → `notABus`; a
    /// second send to the same bus → `duplicateSend` (which also bounds send count
    /// by bus count). `level` clamps to `Send.levelRange` through `Send.init`.
    @discardableResult
    public func addSend(toTrack id: UUID, busID: UUID, level: Double = 1) throws -> Send {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else {
            throw ProjectError.trackNotFound(id)
        }
        guard tracks[index].kind != .bus else { throw ProjectError.busRoutingFixed }
        guard let destIndex = tracks.firstIndex(where: { $0.id == busID }) else {
            throw ProjectError.trackNotFound(busID)
        }
        guard tracks[destIndex].kind == .bus else { throw ProjectError.notABus(busID) }
        guard !tracks[index].sends.contains(where: { $0.destinationBusID == busID }) else {
            throw ProjectError.duplicateSend(busID)
        }
        let send = Send(destinationBusID: busID, level: level)
        let trackName = tracks[index].name
        let busName = tracks[destIndex].name
        editTrack(id: id, label: "Add Send '\(trackName)' → '\(busName)'") { $0.sends.append(send) }
        return send
    }

    /// Sets one send's linear level, clamped to `Send.levelRange`. Coalesces per
    /// (track, send) under the key `track.send:<trackId>:<sendId>` so a fader drag
    /// is a single undo step. Guards OUTSIDE the edit body: unknown track →
    /// `trackNotFound`; a bus source → `busRoutingFixed`; unknown send →
    /// `sendNotFound`. Level is NOT a structural change (see PlaybackGraph).
    @discardableResult
    public func setSendLevel(trackID: UUID, sendID: UUID, level: Double) throws -> Send {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard tracks[index].kind != .bus else { throw ProjectError.busRoutingFixed }
        guard let sendIndex = tracks[index].sends.firstIndex(where: { $0.id == sendID }) else {
            throw ProjectError.sendNotFound(sendID)
        }
        let clamped = level.clamped(to: Send.levelRange)
        editTrack(id: trackID, label: "Set Send Level",
                  key: "track.send:\(trackID.uuidString):\(sendID.uuidString)") {
            if let si = $0.sends.firstIndex(where: { $0.id == sendID }) {
                $0.sends[si].level = clamped
            }
        }
        return tracks[index].sends[sendIndex]
    }

    /// Removes a send by id. Guards OUTSIDE the edit body: unknown track →
    /// `trackNotFound`; a bus source → `busRoutingFixed`; unknown send →
    /// `sendNotFound`.
    public func removeSend(trackID: UUID, sendID: UUID) throws {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard tracks[index].kind != .bus else { throw ProjectError.busRoutingFixed }
        guard let sendIndex = tracks[index].sends.firstIndex(where: { $0.id == sendID }) else {
            throw ProjectError.sendNotFound(sendID)
        }
        let trackName = tracks[index].name
        let busID = tracks[index].sends[sendIndex].destinationBusID
        let busName = tracks.first(where: { $0.id == busID })?.name ?? busID.uuidString
        editTrack(id: trackID, label: "Remove Send '\(trackName)' → '\(busName)'") {
            $0.sends.removeAll { $0.id == sendID }
            // Drop any automation lane targeting the removed send in this SAME
            // step (send-level lanes are v0-deferred at add, but a loaded file
            // may carry one — the cascade keeps the model consistent).
            $0.automation.removeAll { lane in
                if case .sendLevel(let sid) = lane.target { return sid == sendID }
                return false
            }
        }
    }

    // MARK: - Insert-effect chains (M4 ii)

    /// Hard cap on inserts per track chain — bounds the render-thread walk cost
    /// and stops a runaway agent from ballooning a chain.
    public static let maxEffectsPerChain = 16

    /// Human display name for an effect kind, used in undo labels ("Add EQ to
    /// 'Vox'") — matches the granular-verb send labels. Acronyms upper-case
    /// wholesale; everything else title-cases the raw value.
    private static func effectDisplayName(_ kind: EffectDescriptor.Kind) -> String {
        switch kind {
        case .eq: return "EQ"
        default: return kind.rawValue.prefix(1).uppercased() + kind.rawValue.dropFirst()
        }
    }

    /// Appends (or inserts at `index`) a new effect of `kind` to a track's insert
    /// chain and returns its descriptor. Guards OUTSIDE the edit body (sends
    /// precedent): unknown track → `trackNotFound`; a full chain (16) →
    /// `chainFull`. `index` clamps into `[0, chain length]`; nil appends. Adding an
    /// effect is a chain edit, never a structural graph mutation (see PlaybackGraph).
    @discardableResult
    public func addEffect(toTrack id: UUID, kind: EffectDescriptor.Kind, at index: Int? = nil,
                          audioUnit: AudioUnitConfig? = nil)
        throws -> EffectDescriptor {
        guard let ti = tracks.firstIndex(where: { $0.id == id }) else {
            throw ProjectError.trackNotFound(id)
        }
        guard tracks[ti].effects.count < Self.maxEffectsPerChain else {
            throw ProjectError.chainFull(Self.maxEffectsPerChain)
        }
        // Unlike the instrument rule (componentless `.audioUnit` renders the
        // silent placeholder), a componentless audioUnit INSERT is rejected —
        // it would be a permanent no-op in the chain.
        guard kind != .audioUnit || audioUnit != nil else {
            throw ProjectError.audioUnitEffectRequiresComponent
        }
        let effect = EffectDescriptor(kind: kind,
                                      audioUnit: kind == .audioUnit ? audioUnit : nil)
        let name = tracks[ti].name
        let count = tracks[ti].effects.count
        let insertAt = min(max(0, index ?? count), count)
        editTrack(id: id, label: "Add \(Self.effectDisplayName(kind)) to '\(name)'") {
            $0.effects.insert(effect, at: min(insertAt, $0.effects.count))
        }
        return effect
    }

    /// Removes an effect by id from a track's chain. Guards OUTSIDE the edit body:
    /// unknown track → `trackNotFound`; unknown effect → `effectNotFound`.
    public func removeEffect(trackID: UUID, effectID: UUID) throws {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let ei = tracks[ti].effects.firstIndex(where: { $0.id == effectID }) else {
            throw ProjectError.effectNotFound(effectID)
        }
        let kind = tracks[ti].effects[ei].kind
        let name = tracks[ti].name
        editTrack(id: trackID, label: "Remove \(Self.effectDisplayName(kind)) from '\(name)'") {
            $0.effects.removeAll { $0.id == effectID }
            // Drop any automation lane targeting the removed effect in this SAME
            // step, so one undo restores the effect and its lanes together.
            $0.automation.removeAll { lane in
                if case .effectParam(let eid, _) = lane.target { return eid == effectID }
                return false
            }
        }
    }

    /// Moves an effect to a new position in the chain (final-index semantics).
    /// `toIndex` clamps into the valid range. Guards OUTSIDE the edit body:
    /// unknown track → `trackNotFound`; unknown effect → `effectNotFound`.
    /// Reorder republishes chain order only — never a structural graph mutation.
    public func reorderEffect(trackID: UUID, effectID: UUID, toIndex: Int) throws {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard tracks[ti].effects.contains(where: { $0.id == effectID }) else {
            throw ProjectError.effectNotFound(effectID)
        }
        let name = tracks[ti].name
        let dest = min(max(0, toIndex), tracks[ti].effects.count - 1)
        editTrack(id: trackID, label: "Reorder Effects on '\(name)'") {
            guard let from = $0.effects.firstIndex(where: { $0.id == effectID }) else { return }
            let effect = $0.effects.remove(at: from)
            $0.effects.insert(effect, at: min(dest, $0.effects.count))
        }
    }

    /// Bypasses (or re-enables) one effect. Guards OUTSIDE the edit body:
    /// unknown track → `trackNotFound`; unknown effect → `effectNotFound`. Bypass
    /// is an atomic flag toggle, NOT structural, and does NOT coalesce (a
    /// deliberate on/off is its own undo step — the mute precedent).
    public func setEffectBypassed(trackID: UUID, effectID: UUID, bypassed: Bool) throws {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let ei = tracks[ti].effects.firstIndex(where: { $0.id == effectID }) else {
            throw ProjectError.effectNotFound(effectID)
        }
        let kind = tracks[ti].effects[ei].kind
        let name = tracks[ti].name
        let verb = bypassed ? "Bypass" : "Unbypass"
        editTrack(id: trackID, label: "\(verb) \(Self.effectDisplayName(kind)) on '\(name)'") {
            if let ei = $0.effects.firstIndex(where: { $0.id == effectID }) {
                $0.effects[ei].isBypassed = bypassed
            }
        }
    }

    /// Sets one named parameter on an effect, validated against `EffectParamSpec`:
    /// an unknown name throws `unknownEffectParam` (listing the valid names);
    /// the value clamps SILENTLY to the spec range (the `setVolume` precedent).
    /// Guards OUTSIDE the edit body: unknown track → `trackNotFound`; unknown
    /// effect → `effectNotFound`. Coalesces per (track, effect, name) under the
    /// key `fx.param:<trackId>:<effectId>:<name>`, so a knob scrub is one undo
    /// step; a param edit publishes in place and is never structural. Returns the
    /// updated descriptor (so the control layer can echo it).
    @discardableResult
    public func setEffectParam(trackID: UUID, effectID: UUID, name: String, value: Double)
        throws -> EffectDescriptor {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let ei = tracks[ti].effects.firstIndex(where: { $0.id == effectID }) else {
            throw ProjectError.effectNotFound(effectID)
        }
        let kind = tracks[ti].effects[ei].kind
        let specs = EffectParamSpec.specs(for: kind)
        guard let spec = specs.first(where: { $0.name == name }) else {
            let valid = specs.map(\.name).joined(separator: ", ")
            throw ProjectError.unknownEffectParam(
                "unknown parameter '\(name)' for \(kind.rawValue) effect — valid: \(valid)")
        }
        let clamped = value.clamped(to: spec.range)
        editTrack(id: trackID, label: "Set \(Self.effectDisplayName(kind)) Parameter",
                  key: "fx.param:\(trackID.uuidString):\(effectID.uuidString):\(name)") {
            if let ei = $0.effects.firstIndex(where: { $0.id == effectID }) {
                Self.applyEffectParam(&$0.effects[ei], name: name, value: clamped)
            }
        }
        return tracks[ti].effects[ei]
    }

    // MARK: - Automation (M4 vii)

    /// Hard cap on breakpoints per lane — bounds the schedule precompute and
    /// stops a runaway agent from ballooning a lane (the clip-notes precedent).
    public static let maxAutomationPoints = 4096

    /// Adds — or returns the EXISTING — automation lane for `target` on a track.
    /// Idempotent per target: a track holds at most one lane per target, so a
    /// repeat call for the same target returns the existing lane unchanged and
    /// records NO edit. Guards OUTSIDE the edit body (sends/FX precedent):
    /// unknown track → `trackNotFound`; a v0-deferred target →
    /// `automationTargetNotSupported` (`.sendLevel`, and `.effectParam` on an
    /// `.audioUnit` effect — honest deferrals, not silent no-ops); any other
    /// unresolvable target → `automationTargetUnresolvable`.
    @discardableResult
    public func addAutomationLane(trackID: UUID, target: AutomationTarget)
        throws -> AutomationLane {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        // Idempotent: an existing lane for this target is returned as-is.
        if let existing = tracks[ti].automation.first(where: { $0.target == target }) {
            return existing
        }
        // v0 deferrals: reject targets with no render path rather than store a
        // lane that would silently do nothing.
        switch target {
        case .sendLevel:
            throw ProjectError.automationTargetNotSupported(
                "send-level automation is not supported in v0")
        case .effectParam(let effectID, _):
            if tracks[ti].effects.first(where: { $0.id == effectID })?.kind == .audioUnit {
                throw ProjectError.automationTargetNotSupported(
                    "Audio Unit effect-parameter automation is not supported in v0")
            }
        case .volume, .pan:
            break
        }
        // Every remaining target must resolve to a range (known ids, known param).
        guard target.valueRange(in: tracks[ti]) != nil else {
            throw ProjectError.automationTargetUnresolvable(
                "automation target does not resolve on that track")
        }
        let lane = AutomationLane(target: target)
        editTrack(id: trackID, label: "Add Automation") {
            $0.automation.append(lane)
        }
        return lane
    }

    /// Removes an automation lane by id. Guards OUTSIDE the edit body: unknown
    /// track → `trackNotFound`; unknown lane → `automationLaneNotFound`.
    public func removeAutomationLane(trackID: UUID, laneID: UUID) throws {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard tracks[ti].automation.contains(where: { $0.id == laneID }) else {
            throw ProjectError.automationLaneNotFound(laneID)
        }
        editTrack(id: trackID, label: "Remove Automation") {
            $0.automation.removeAll { $0.id == laneID }
        }
    }

    /// Replaces a lane's breakpoints WHOLESALE (the clip-notes precedent): every
    /// value clamps to the target's live range, the array is canonicalized
    /// (sorted, equal-beat dedupe last-wins), and an over-cap array is trimmed to
    /// the latest `maxAutomationPoints`. An unresolvable target (e.g. its effect
    /// was deleted) leaves values unclamped rather than dropping the edit. Guards
    /// OUTSIDE the edit body: unknown track → `trackNotFound`; unknown lane →
    /// `automationLaneNotFound`. Coalesces under `automation.points:<laneID>` so
    /// a draw gesture is one undo step. Returns the updated lane.
    @discardableResult
    public func setAutomationPoints(trackID: UUID, laneID: UUID, points: [AutomationPoint])
        throws -> AutomationLane {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let li = tracks[ti].automation.firstIndex(where: { $0.id == laneID }) else {
            throw ProjectError.automationLaneNotFound(laneID)
        }
        let range = tracks[ti].automation[li].target.valueRange(in: tracks[ti])
        let clamped = points.map { point in
            AutomationPoint(beat: point.beat,
                            value: range.map { point.value.clamped(to: $0) } ?? point.value,
                            curve: point.curve)
        }
        var canonical = AutomationLane.canonicalize(clamped)
        if canonical.count > Self.maxAutomationPoints {
            canonical = Array(canonical.suffix(Self.maxAutomationPoints))
        }
        editTrack(id: trackID, label: "Edit Automation",
                  key: "automation.points:\(laneID.uuidString)") {
            if let li = $0.automation.firstIndex(where: { $0.id == laneID }) {
                $0.automation[li].points = canonical
            }
        }
        return tracks[ti].automation[li]
    }

    /// Toggles a lane between read (enabled) and manual (disabled). Guards
    /// OUTSIDE the edit body: unknown track → `trackNotFound`; unknown lane →
    /// `automationLaneNotFound`. Coalesces under `automation.enable:<laneID>`.
    /// Returns the updated lane.
    @discardableResult
    public func setAutomationLaneEnabled(trackID: UUID, laneID: UUID, _ isEnabled: Bool)
        throws -> AutomationLane {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let li = tracks[ti].automation.firstIndex(where: { $0.id == laneID }) else {
            throw ProjectError.automationLaneNotFound(laneID)
        }
        editTrack(id: trackID,
                  label: isEnabled ? "Enable Automation" : "Disable Automation",
                  key: "automation.enable:\(laneID.uuidString)") {
            if let li = $0.automation.firstIndex(where: { $0.id == laneID }) {
                $0.automation[li].isEnabled = isEnabled
            }
        }
        return tracks[ti].automation[li]
    }

    /// Writes a validated, already-clamped parameter into an effect descriptor.
    /// The per-kind name→field mapping — the single place the control/wire name
    /// resolves onto a model field. New kinds (iv) extend this switch. The value
    /// is already clamped to the spec range, which matches each struct's own
    /// clamping init, so field writes stay in-model-range by construction.
    private static func applyEffectParam(_ effect: inout EffectDescriptor, name: String, value: Double) {
        switch effect.kind {
        case .gain:
            if name == "gainLinear" { effect.gain = GainParams(gainLinear: value) }
        case .eq:
            var params = effect.resolvedEQ
            switch name {
            case "lowShelfFreq": params.lowShelfFreq = value
            case "lowShelfGainDb": params.lowShelfGainDb = value
            case "peak1Freq": params.peak1Freq = value
            case "peak1GainDb": params.peak1GainDb = value
            case "peak1Q": params.peak1Q = value
            case "peak2Freq": params.peak2Freq = value
            case "peak2GainDb": params.peak2GainDb = value
            case "peak2Q": params.peak2Q = value
            case "highShelfFreq": params.highShelfFreq = value
            case "highShelfGainDb": params.highShelfGainDb = value
            default: return
            }
            effect.eq = params
        case .compressor:
            var params = effect.resolvedCompressor
            switch name {
            case "thresholdDb": params.thresholdDb = value
            case "ratio": params.ratio = value
            case "attackMs": params.attackMs = value
            case "releaseMs": params.releaseMs = value
            case "kneeDb": params.kneeDb = value
            case "makeupDb": params.makeupDb = value
            default: return
            }
            effect.compressor = params
        case .limiter:
            var params = effect.resolvedLimiter
            switch name {
            case "ceilingDb": params.ceilingDb = value
            case "releaseMs": params.releaseMs = value
            default: return
            }
            effect.limiter = params
        case .reverb:
            var params = effect.resolvedReverb
            switch name {
            case "roomSize": params.roomSize = value
            case "damping": params.damping = value
            case "mix": params.mix = value
            case "preDelayMs": params.preDelayMs = value
            case "width": params.width = value
            default: return
            }
            effect.reverb = params
        case .delay:
            var params = effect.resolvedDelay
            switch name {
            case "timeMs": params.timeMs = value
            case "feedback": params.feedback = value
            case "mix": params.mix = value
            // pingPong snaps to 0/1 through the clamping init (numeric bool).
            case "pingPong": params = DelayParams(timeMs: params.timeMs,
                                                  feedback: params.feedback,
                                                  mix: params.mix, pingPong: value,
                                                  highCutHz: params.highCutHz)
            case "highCutHz": params.highCutHz = value
            default: return
            }
            effect.delay = params
        case .saturator:
            var params = effect.resolvedSaturator
            switch name {
            case "driveDb": params.driveDb = value
            case "mix": params.mix = value
            case "outputDb": params.outputDb = value
            default: return
            }
            effect.saturator = params
        case .gate:
            var params = effect.resolvedGate
            switch name {
            case "thresholdDb": params.thresholdDb = value
            case "attackMs": params.attackMs = value
            case "holdMs": params.holdMs = value
            case "releaseMs": params.releaseMs = value
            default: return
            }
            effect.gate = params
        case .chorus:
            var params = effect.resolvedChorus
            switch name {
            case "rateHz": params.rateHz = value
            case "depthMs": params.depthMs = value
            case "mix": params.mix = value
            default: return
            }
            effect.chorus = params
        case .audioUnit:
            // Unreachable: specs(for: .audioUnit) is empty, so name validation
            // in setEffectParam rejects every name first. AU params are not
            // on the generic surface in v0.
            return
        }
    }

    /// Sets the built-in instrument for an INSTRUMENT track. PARTIAL update for
    /// the poly-synth knobs: any nil argument keeps the track's current value, so
    /// a single knob edit overlays exactly one field onto the current descriptor
    /// (`.default` when the track has none). All numeric values re-clamp through
    /// `PolySynthParams.init`. The `sampler` argument is a WHOLESALE replacement
    /// (like clip notes): a non-nil `SamplerParams` replaces the descriptor's
    /// whole sampler config; nil keeps the current one. Before committing, every
    /// zone's `audioFileURL` is validated to exist and be a readable audio file
    /// through the injected media service (reusing `importAudio`'s error strings);
    /// an empty zones array is legal (a silent sampler) and needs no media. This
    /// validation happens OUTSIDE the edit body, so a bad zone changes nothing.
    /// `audioUnit` and `soundBank` (m10-n) follow the same wholesale rule —
    /// providing one implies its kind when `kind` is omitted, providing BOTH in
    /// one call throws `ambiguousInstrumentSelection`, and a provided sound
    /// bank is validated (existing `.sf2`/`.dls` file) before the edit runs.
    /// Returns the resolved descriptor (so the control layer can echo it), or nil
    /// for an unknown id — mirroring the other per-track setters. Throws
    /// `instrumentRequiresInstrumentTrack` for an audio or bus track (kind guard
    /// OUTSIDE the edit body, like `setTrackArm`). Coalesces per-track under
    /// "Change Instrument", so dragging a synth knob is one undo step; the engine
    /// sees the change via `tracksDidChange`.
    @discardableResult
    public func setInstrument(
        id: UUID,
        kind: InstrumentDescriptor.Kind? = nil,
        waveform: PolySynthParams.Waveform? = nil,
        attack: Double? = nil,
        decay: Double? = nil,
        sustain: Double? = nil,
        release: Double? = nil,
        cutoffHz: Double? = nil,
        resonance: Double? = nil,
        gain: Double? = nil,
        sampler: SamplerParams? = nil,
        audioUnit: AudioUnitConfig? = nil,
        soundBank: SoundBankConfig? = nil
    ) throws -> InstrumentDescriptor? {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return nil }
        guard tracks[index].kind == .instrument else {
            throw ProjectError.instrumentRequiresInstrumentTrack(tracks[index].kind)
        }
        // One instrument selection per call: `audioUnit` and `soundBank` are
        // mutually exclusive — no silent precedence (m10-n §3.3).
        if audioUnit != nil && soundBank != nil {
            throw ProjectError.ambiguousInstrumentSelection
        }
        // A provided sampler config's zone files are validated NOW, before the
        // edit runs (like importAudio's media read): a bad zone throws and
        // records no undo entry.
        if let sampler { try validateSamplerZones(sampler.zones) }
        // A provided sound-bank config likewise: the source must resolve to an
        // existing .sf2/.dls file BEFORE the edit runs (same no-undo-on-failure
        // rule; no engine involvement — stays headless-testable).
        if let soundBank { try validateSoundBank(soundBank) }
        // Overlay onto the current descriptor (nil ⇒ default). Rebuilding through
        // the inits re-clamps every field, so an out-of-range overlay is caught
        // even though the stored descriptor is already valid. `sampler` swaps
        // wholesale when supplied; otherwise the current sampler config survives
        // (so poly-synth knob edits never disturb it, and vice versa).
        // `audioUnit`/`soundBank` are wholesale like `sampler`, and providing
        // one implies its kind when kind is omitted.
        let current = tracks[index].instrument ?? .default
        let p = current.polySynth
        let resolved = InstrumentDescriptor(
            kind: kind ?? (audioUnit != nil ? .audioUnit
                           : soundBank != nil ? .soundBank : current.kind),
            polySynth: PolySynthParams(
                waveform: waveform ?? p.waveform,
                attack: attack ?? p.attack,
                decay: decay ?? p.decay,
                sustain: sustain ?? p.sustain,
                release: release ?? p.release,
                cutoffHz: cutoffHz ?? p.cutoffHz,
                resonance: resonance ?? p.resonance,
                gain: gain ?? p.gain
            ),
            sampler: sampler ?? current.sampler,
            audioUnit: audioUnit ?? current.audioUnit,
            soundBank: soundBank ?? current.soundBank
        )
        editTrack(id: id, label: "Change Instrument",
                  key: "track.instrument:\(id.uuidString)") { $0.instrument = resolved }
        return resolved
    }

    /// Set-time validation for a sound-bank selection (m10-n §3.3, the
    /// `validateSamplerZones` precedent — runs BEFORE the edit, so a bad bank
    /// throws and records no undo entry): the source must resolve to an
    /// existing file (`SoundBankLibrary.resolve`, shared with the engine's
    /// pre-instantiation check) carrying an `.sf2`/`.dls` extension
    /// (case-insensitive).
    private func validateSoundBank(_ config: SoundBankConfig) throws {
        let url = try soundBankLibrary.resolve(config.source)
        let ext = url.pathExtension.lowercased()
        guard ext == "sf2" || ext == "dls" else {
            throw ProjectError.importFailed(
                "sound bank must be a .sf2 or .dls file — got \(url.lastPathComponent)")
        }
    }

    /// Validates that every sampler zone points at an existing, readable audio
    /// file, delegating to the same media service (and error strings) as
    /// `importAudio`. An empty zones array is a silent sampler — legal, and it
    /// needs no media service. A non-empty array with no media service wired up
    /// throws `mediaServiceUnavailable`, exactly like an import attempt.
    private func validateSamplerZones(_ zones: [SamplerZone]) throws {
        guard !zones.isEmpty else { return }
        guard let media else { throw ProjectError.mediaServiceUnavailable }
        for zone in zones {
            let url = zone.audioFileURL
            // Existence is checked here (DAWCore-owned, stable string) so the
            // missing-file error is testable with any media stand-in; the media
            // service then confirms readability (it throws `importFailed(<reason>)`
            // for a non-audio file). Both surface in the `importFailed` style —
            // "Audio import failed: …" — matching importAudio's conventions.
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ProjectError.importFailed("no file at \(url.path)")
            }
            // Only the validation side effect matters, so the facts are discarded.
            _ = try media.audioFileInfo(at: url)
        }
    }

    /// Current name of the track with `id`, or nil if it's gone — used to build
    /// undo labels before the edit runs.
    private func trackName(_ id: UUID) -> String? {
        tracks.first(where: { $0.id == id })?.name
    }

    // MARK: - Audio Units

    /// Installed Audio Unit music devices as the engine sees them; empty when
    /// running headless (no engine injected). DAWControl's
    /// `instrument.listAudioUnits` resolves against exactly this list.
    public func availableAudioUnits() -> [AudioUnitComponentInfo] {
        engine?.availableAudioUnits() ?? []
    }

    /// The insert-effect mirror ('aufx'); DAWControl's `fx.listAudioUnits`
    /// and `fx.add` (kind audioUnit) resolve against exactly this list.
    public func availableAudioUnitEffects() -> [AudioUnitComponentInfo] {
        engine?.availableAudioUnitEffects() ?? []
    }

    /// Lifecycle status of the hosted Audio Unit on a track (nil when the
    /// engine tracks none) — surfaced in snapshots.
    public func audioUnitStatus(forTrack id: UUID) -> AudioUnitTrackStatus? {
        engine?.audioUnitStatus(forTrack: id)
    }

    // MARK: - Sound banks (m10-n)

    /// Discoverable sound banks — GM first, then each scan dir's `*.sf2`/`*.dls`
    /// (§6.6). Pure file work through the injected `SoundBankLibrary`; NO engine
    /// involvement (unlike `availableAudioUnits`). DAWControl's
    /// `instrument.listSoundBanks` reads exactly this.
    public func availableSoundBanks() -> [SoundBankInfo] {
        soundBankLibrary.scan()
    }

    /// The program list for a bank source — the GM table for `"gm"`, parsed SF2
    /// names for a `.sf2`, generic 0…127 otherwise (`namesParsed` flags which,
    /// §6.6). Throws `importFailed` for a missing file. Backs
    /// `instrument.listSoundBankPrograms`.
    public func soundBankPrograms(source: SoundBankSource) throws
        -> (programs: [SoundBankProgram], namesParsed: Bool) {
        try soundBankLibrary.programs(for: source)
    }

    /// Copies a `.sf2`/`.dls` into the central library and returns its info;
    /// NEVER moves/deletes the source (§6.6). Backs `instrument.importSoundBank`.
    /// Pure file work — the project is untouched, so no undo entry (import is a
    /// library operation, selection is a separate `setInstrument` call).
    @discardableResult
    public func importSoundBank(from url: URL) throws -> SoundBankInfo {
        try soundBankLibrary.importBank(from: url)
    }

    /// Offline stretch-render state for one clip (M5 ii-d, nil when running
    /// headless) — surfaced in snapshots as the transient `stretchRendering`
    /// / `stretchError` fields (the `audioUnitStatus` forwarding precedent).
    public func clipStretchStatus(trackID: UUID, clipID: UUID) -> ClipStretchStatus? {
        engine?.clipStretchStatus(trackID: trackID, clipID: clipID)
    }

    // MARK: - Insert-effect latency (engine forwarders)

    /// Fixed latency of one live insert-effect instance as the engine reports
    /// it (the limiter's 5 ms lookahead = 240 @ 48 kHz; 0 for the other
    /// built-ins, unknown ids, or when running headless). The
    /// `availableAudioUnits` forwarding precedent — DAWControl reads this to
    /// populate per-effect `latencySamples` on the wire while staying
    /// engine-free itself.
    public func effectLatencySamples(trackID: UUID, effectID: UUID) -> Int {
        engine?.effectLatencySamples(trackID: trackID, effectID: effectID) ?? 0
    }

    /// The engine's latest PDC report (M4 viii-c) — per-strip chain latency
    /// + applied compensation plus the global stage maxima; nil when running
    /// headless. DAWControl attaches the additive snapshot fields from this
    /// (the same engine-forwarding pattern as `effectLatencySamples`).
    public func pdcReport() -> PDCReport? {
        engine?.pdcReport()
    }

    // MARK: - Media import

    /// Imports an on-disk audio file as a clip on the given track. The file's
    /// duration is converted to beats at the current tempo; the clip lands at
    /// `atBeat` if given, otherwise appended after the last existing clip.
    @discardableResult
    public func importAudio(url: URL, toTrack id: UUID, atBeat: Double? = nil) throws -> Clip {
        guard let media else { throw ProjectError.mediaServiceUnavailable }
        guard let index = tracks.firstIndex(where: { $0.id == id }) else {
            throw ProjectError.trackNotFound(id)
        }
        guard tracks[index].kind == .audio else {
            throw ProjectError.trackKindUnsupported(tracks[index].kind)
        }

        let info = try media.audioFileInfo(at: url)

        let appendPosition = tracks[index].clips
            .map { $0.startBeat + $0.lengthBeats }
            .max() ?? 0
        let startBeat = max(0, atBeat ?? appendPosition)
        // File duration → beats via the inverse integral FROM the landing
        // beat (m12-b, design row 11) — the placement decides the conversion.
        let lengthBeats = transport.tempoMap.beat(
            from: startBeat, elapsedSeconds: info.durationSeconds) - startBeat

        let name = url.deletingPathExtension().lastPathComponent
        let clip = Clip(
            name: name,
            startBeat: startBeat,
            lengthBeats: lengthBeats,
            audioFileURL: url
        )
        performEdit("Import '\(clip.name)'") {
            tracks[index].clips.append(clip)
            engine?.tracksDidChange(tracks)
        }
        return clip
    }

    // MARK: - MIDI clips

    /// Adds an empty (or note-seeded) MIDI clip to an instrument track. MIDI
    /// clips live ONLY on instrument tracks — an audio or bus target throws
    /// `midiClipsRequireInstrumentTrack`. The clip lands at `atBeat` if given,
    /// otherwise appended after the last existing clip. `lengthBeats` defaults
    /// to 4 beats for an empty clip, else to the smallest whole beat count that
    /// contains every note (min 1). `notes` are clamped and canonically ordered
    /// by `Clip.init`.
    @discardableResult
    public func addMIDIClip(
        toTrack id: UUID,
        name: String? = nil,
        atBeat: Double? = nil,
        lengthBeats: Double? = nil,
        notes: [MIDINote] = []
    ) throws -> Clip {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else {
            throw ProjectError.trackNotFound(id)
        }
        guard tracks[index].kind == .instrument else {
            throw ProjectError.midiClipsRequireInstrumentTrack(tracks[index].kind)
        }

        let appendPosition = tracks[index].clips
            .map { $0.startBeat + $0.lengthBeats }
            .max() ?? 0
        let startBeat = max(0, atBeat ?? appendPosition)

        let length: Double
        if let lengthBeats {
            length = lengthBeats
        } else if notes.isEmpty {
            length = 4
        } else {
            let maxEnd = notes.map(\.endBeat).max() ?? 0
            length = max(1, maxEnd.rounded(.up))
        }

        let clipName = name?.isEmpty == false
            ? name!
            : "MIDI Clip \(tracks[index].clips.count + 1)"
        let clip = Clip(
            name: clipName,
            startBeat: startBeat,
            lengthBeats: length,
            notes: notes
        )
        performEdit("Add MIDI Clip '\(clip.name)'") {
            tracks[index].clips.append(clip)
            engine?.tracksDidChange(tracks)
        }
        return clip
    }

    /// Replaces the entire note list of a MIDI clip (whole-array set — the M3
    /// piano roll edits by re-sending the clip's notes). Throws `clipNotFound`
    /// for an unknown id and `notAMIDIClip` for an audio clip. Notes are
    /// re-clamped and canonically ordered; the edit coalesces per-clip so a
    /// drag of one note is a single undo step. Returns the updated clip.
    @discardableResult
    public func setClipNotes(clipID: UUID, notes: [MIDINote]) throws -> Clip {
        guard let (t, c) = locateClip(clipID) else {
            throw ProjectError.clipNotFound(clipID)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard tracks[t].clips[c].notes != nil else {
            throw ProjectError.notAMIDIClip(clipID)
        }
        // Reconstruct each note through the clamping init before ordering, so a
        // caller that mutated a note's fields out of range can't slip past.
        let reclamped = notes.map {
            MIDINote(id: $0.id, pitch: $0.pitch, velocity: $0.velocity,
                     startBeat: $0.startBeat, lengthBeats: $0.lengthBeats)
        }
        performEdit("Edit Notes", key: "clip.notes:\(clipID.uuidString)") {
            tracks[t].clips[c].notes = MIDINote.canonicallyOrdered(reclamped)
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    // MARK: - MIDI time-range editing (beta m10-h)

    /// Floor on a MIDI clip's length after a `deleteTimeRange` (m10-h): one beat.
    /// A bar delete can shrink a clip but never collapse it below a single beat
    /// (nor below the furthest remaining note — see `deleteTimeRange`). A whole-bar
    /// edit reasons in beats, so its floor is a beat — deliberately coarser than
    /// the finer `minClipLengthBeats` used by a continuous trim drag.
    public static let minTimeRangeClipLengthBeats: Double = 1.0

    /// Excises a clip-local beat range from a MIDI clip and CLOSES THE GAP (beta
    /// m10-h — the "delete a bar" primitive; the piano-roll UI passes one bar =
    /// `beatsPerBar` beats). `startBeat`/`lengthBeats` are CLIP-LOCAL beats — the
    /// same space `notes[].startBeat` lives in, NOT timeline beats. The excised
    /// span is `[startBeat, startBeat + lengthBeats)`, its right edge clamped to
    /// the clip end (a range that runs off the end simply truncates the clip at
    /// `startBeat`). Notes fold by these crossing rules (every case is unit-tested):
    ///
    ///  - **Wholly before** the span (`note.endBeat <= startBeat`): unchanged.
    ///  - **Crosses in from before** (`note.startBeat < startBeat` and
    ///    `note.endBeat > startBeat`): the head is KEPT and the overlapping part is
    ///    spliced out — the note keeps its start and loses exactly the portion
    ///    inside the cut. A note ending inside the span ends at the cut
    ///    (`length = startBeat − note.startBeat`); a note SPANNING the whole span
    ///    rejoins across it (`length −= lengthBeats`) so its head and tail become
    ///    continuous.
    ///  - **Onset inside** the span (`startBeat <= note.startBeat < end`): REMOVED —
    ///    a note whose onset the cut swallows can't be meaningfully placed, so it's
    ///    dropped however far it extends.
    ///  - **At or after** the span end (`note.startBeat >= end`): SHIFTED LEFT by
    ///    `lengthBeats`, closing the gap (length unchanged).
    ///
    /// The clip's `lengthBeats` shrinks by the excised amount, then is clamped up so
    /// it never falls below one beat (`minTimeRangeClipLengthBeats`) OR the furthest
    /// remaining note's end (so no surviving note is stranded past the clip end).
    ///
    /// ONE `performEdit` folds the note edit AND the length change into a single
    /// undo step (the house rule: one journal entry per call — undo restores the
    /// exact prior notes + length). Throws `clipNotFound`, `notAMIDIClip`, or
    /// `invalidClipEdit` (non-positive `lengthBeats`, or `startBeat` outside
    /// `[0, lengthBeats)`).
    @discardableResult
    public func deleteTimeRange(clipID: UUID, startBeat: Double, lengthBeats: Double) throws -> Clip {
        guard let (t, c) = locateClip(clipID) else {
            throw ProjectError.clipNotFound(clipID)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard let notes = tracks[t].clips[c].notes else {
            throw ProjectError.notAMIDIClip(clipID)
        }
        let clipLength = tracks[t].clips[c].lengthBeats
        guard lengthBeats > 0 else {
            throw ProjectError.invalidClipEdit(
                "deleteTimeRange length \(lengthBeats) must be > 0")
        }
        guard startBeat >= 0, startBeat < clipLength else {
            throw ProjectError.invalidClipEdit(
                "deleteTimeRange startBeat \(startBeat) is outside clip '\(tracks[t].clips[c].name)' [0, \(clipLength)) — startBeat must fall within the clip")
        }
        let s = startBeat
        let e = s + lengthBeats
        // Amount actually removed from the timeline: a range running past the clip
        // end truncates the clip at `s` (so the shrink can't exceed what exists).
        let removed = min(e, clipLength) - s

        var kept: [MIDINote] = []
        for note in notes {
            let ns = note.startBeat
            let ne = note.endBeat
            if ne <= s {
                kept.append(note)                                   // wholly before
            } else if ns < s {
                // Crosses in from before: keep the head, splice out the overlap
                // (which is `lengthBeats` when the note spans the whole cut).
                let overlap = min(ne, e) - s
                kept.append(MIDINote(id: note.id, pitch: note.pitch, velocity: note.velocity,
                                     startBeat: ns, lengthBeats: note.lengthBeats - overlap))
            } else if ns < e {
                continue                                            // onset inside — dropped
            } else {
                // At/after the cut: shift left to close the gap.
                kept.append(MIDINote(id: note.id, pitch: note.pitch, velocity: note.velocity,
                                     startBeat: ns - lengthBeats, lengthBeats: note.lengthBeats))
            }
        }

        let noteExtent = kept.map(\.endBeat).max() ?? 0
        let newClipLength = max(clipLength - removed, Self.minTimeRangeClipLengthBeats, noteExtent)
        let ordered = MIDINote.canonicallyOrdered(kept)

        performEdit("Delete Time Range") {
            tracks[t].clips[c].notes = ordered
            tracks[t].clips[c].lengthBeats = newClipLength
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Inserts `lengthBeats` of SILENCE at clip-local `atBeat` in a MIDI clip,
    /// pushing later material right (beta m10-h — the "insert a bar" inverse; the
    /// piano-roll UI passes one bar = `beatsPerBar` beats). `atBeat`/`lengthBeats`
    /// are CLIP-LOCAL beats (note space). Rules (unit-tested):
    ///
    ///  - A note **at or after** `atBeat` (`note.startBeat >= atBeat`) is SHIFTED
    ///    RIGHT by `lengthBeats` (length unchanged).
    ///  - A note **crossing** `atBeat` (`note.startBeat < atBeat`) keeps BOTH its
    ///    start and its length — the inserted silence lands after the note's
    ///    sounding onset, so a note held across the insert point simply sustains
    ///    through the new gap. The simplest predictable rule: no note is split.
    ///
    /// The clip's `lengthBeats` GROWS by `lengthBeats`. ONE `performEdit` folds the
    /// note shift AND the length change into a single undo step. Throws
    /// `clipNotFound`, `notAMIDIClip`, or `invalidClipEdit` (non-positive
    /// `lengthBeats`, or `atBeat` outside `[0, lengthBeats]`).
    @discardableResult
    public func insertTimeRange(clipID: UUID, atBeat: Double, lengthBeats: Double) throws -> Clip {
        guard let (t, c) = locateClip(clipID) else {
            throw ProjectError.clipNotFound(clipID)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard let notes = tracks[t].clips[c].notes else {
            throw ProjectError.notAMIDIClip(clipID)
        }
        let clipLength = tracks[t].clips[c].lengthBeats
        guard lengthBeats > 0 else {
            throw ProjectError.invalidClipEdit(
                "insertTimeRange length \(lengthBeats) must be > 0")
        }
        // `atBeat == lengthBeats` is legal (append silence at the tail).
        guard atBeat >= 0, atBeat <= clipLength else {
            throw ProjectError.invalidClipEdit(
                "insertTimeRange atBeat \(atBeat) is outside clip '\(tracks[t].clips[c].name)' [0, \(clipLength)] — atBeat must fall within the clip")
        }
        let shifted = notes.map { note -> MIDINote in
            guard note.startBeat >= atBeat else { return note }     // crosses/before → unchanged
            return MIDINote(id: note.id, pitch: note.pitch, velocity: note.velocity,
                            startBeat: note.startBeat + lengthBeats, lengthBeats: note.lengthBeats)
        }
        let ordered = MIDINote.canonicallyOrdered(shifted)
        let newClipLength = clipLength + lengthBeats

        performEdit("Insert Time Range") {
            tracks[t].clips[c].notes = ordered
            tracks[t].clips[c].lengthBeats = newClipLength
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Removes a clip (audio or MIDI) by id, from whichever track holds it.
    /// Throws `clipNotFound` for an unknown id. Returns the removed clip.
    @discardableResult
    public func removeClip(id: UUID) throws -> Clip {
        guard let (t, c) = locateClip(id) else {
            throw ProjectError.clipNotFound(id)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let removed = tracks[t].clips[c]
        performEdit("Remove Clip '\(removed.name)'") {
            tracks[t].clips.remove(at: c)
            engine?.tracksDidChange(tracks)
        }
        return removed
    }

    /// Locates a clip by id across every track, returning (track index, clip
    /// index) or nil if no track holds it.
    private func locateClip(_ id: UUID) -> (track: Int, clip: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }

    // MARK: - Clip editing (M5 i-a)

    /// Floor on a clip's length after a trim: 1/32 of a beat (a 128th note in
    /// 4/4). A trimmed clip can never collapse to zero — the MIDI
    /// `minLengthBeats` precedent, one rung up for a whole clip.
    public static let minClipLengthBeats: Double = 1.0 / 32.0

    /// Locates a clip by BOTH its track and its id (the clip-edit ops take an
    /// explicit track, unlike the id-only `locateClip`). Throws `trackNotFound`
    /// for an unknown track and `clipNotFound` when that track holds no such clip.
    private func locateClip(trackID: UUID, clipID: UUID) throws -> (t: Int, c: Int) {
        guard let t = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let c = tracks[t].clips.firstIndex(where: { $0.id == clipID }) else {
            throw ProjectError.clipNotFound(clipID)
        }
        return (t, c)
    }

    /// Rejects an ordinary-clip edit on a comp MEMBER (M5 iii-a, §2): a clip
    /// with `takeGroupID` set is store-managed — its geometry is rebuilt from the
    /// group's comp on every comp edit, so a direct split/trim/move/gain/fade/
    /// stretch/note/remove would be silently overwritten. The escape hatch is
    /// `flattenTakeGroup` (→ ordinary clips). Named guard shared by every
    /// clip-edit op.
    func requireNotCompMember(trackIndex t: Int, clipIndex c: Int) throws {
        guard let gid = tracks[t].clips[c].takeGroupID else { return }
        let name = tracks[t].takeGroups.first(where: { $0.id == gid })?.name
            ?? tracks[t].clips[c].name
        throw ProjectError.clipInTakeGroup(name)
    }

    /// Clamps a fade pair to a clip length. Each fade is first pinned to
    /// `[0, length]`; then, if `fadeIn + fadeOut > length`, BOTH shrink by the
    /// same factor (`length / (fadeIn + fadeOut)`) so their sum lands exactly on
    /// `length` while their RATIO is preserved — proportional reduction on
    /// conflict. A zero-length clip yields `(0, 0)`.
    static func clampedFades(fadeIn: Double, fadeOut: Double, length: Double) -> (Double, Double) {
        guard length > 0 else { return (0, 0) }
        var fin = max(0, fadeIn).clamped(to: 0...length)
        var fout = max(0, fadeOut).clamped(to: 0...length)
        let total = fin + fout
        if total > length, total > 0 {
            let scale = length / total
            fin *= scale
            fout *= scale
        }
        return (fin, fout)
    }

    /// Splits a clip in two at the timeline beat `atBeat`, which must fall
    /// STRICTLY inside the clip (`invalidClipEdit` otherwise). The original clip
    /// becomes the left half (its id preserved); a fresh clip (new UUID) is
    /// inserted right after it as the right half. One undo step, NO coalescing.
    ///
    /// - Audio: the right half's `startOffsetSeconds` advances by the left half's
    ///   duration — the tempo-map integral over [clip.startBeat, atBeat]
    ///   (m12-b; with the Phase-A trivial map this is exactly the old
    ///   `splitBeats · 60 / tempoBPM`).
    /// - MIDI: notes partition by start beat — a note starting before the split
    ///   stays left (truncated to the split boundary if it overhangs); a note at
    ///   or after the split moves right, rebased to the new clip's start.
    /// - Fades: the left half keeps the fade-in and loses the fade-out; the right
    ///   half gains a zero fade-in and keeps the fade-out. Each is re-clamped to
    ///   its new (shorter) length. `gainDb` copies to both.
    @discardableResult
    public func splitClip(trackId: UUID, clipId: UUID, atBeat: Double) throws -> (first: Clip, second: Clip) {
        let (t, c) = try locateClip(trackID: trackId, clipID: clipId)
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let clip = tracks[t].clips[c]
        let relBeat = atBeat - clip.startBeat
        guard relBeat > 0, relBeat < clip.lengthBeats else {
            throw ProjectError.invalidClipEdit(
                "split beat \(atBeat) is outside clip '\(clip.name)' [\(clip.startBeat), \(clip.startBeat + clip.lengthBeats)] — split point must be strictly inside")
        }
        let firstLength = relBeat
        let secondLength = clip.lengthBeats - relBeat
        let splitSeconds = transport.tempoMap.seconds(from: clip.startBeat, to: atBeat)

        // Partition MIDI notes (nil for audio clips stays nil on both sides).
        var firstNotes: [MIDINote]?
        var secondNotes: [MIDINote]?
        if let notes = clip.notes {
            var left: [MIDINote] = []
            var right: [MIDINote] = []
            for note in notes {
                if note.startBeat < relBeat {
                    // Truncate a note that overhangs the split boundary.
                    let overhang = note.endBeat > relBeat
                    let length = overhang ? relBeat - note.startBeat : note.lengthBeats
                    left.append(MIDINote(id: note.id, pitch: note.pitch, velocity: note.velocity,
                                         startBeat: note.startBeat, lengthBeats: length))
                } else {
                    right.append(MIDINote(id: note.id, pitch: note.pitch, velocity: note.velocity,
                                          startBeat: note.startBeat - relBeat, lengthBeats: note.lengthBeats))
                }
            }
            firstNotes = left
            secondNotes = right
        }

        let (firstIn, firstOut) = Self.clampedFades(
            fadeIn: clip.fadeInBeats, fadeOut: 0, length: firstLength)
        let (secondIn, secondOut) = Self.clampedFades(
            fadeIn: 0, fadeOut: clip.fadeOutBeats, length: secondLength)

        // Stretch params (M5 ii-c) copy verbatim to BOTH halves: the engine's
        // render (ii-d) covers the WHOLE source file, so both halves read the
        // same stretched material — the split junction is seamless by
        // construction (spec §3). The offset math above is unchanged; ii-d maps
        // `startOffsetSeconds` through the ratio at schedule time.
        let first = Clip(
            id: clip.id, name: clip.name,
            startBeat: clip.startBeat, lengthBeats: firstLength,
            audioFileURL: clip.audioFileURL, notes: firstNotes,
            isAIGenerated: clip.isAIGenerated,
            startOffsetSeconds: clip.startOffsetSeconds, gainDb: clip.gainDb,
            fadeInBeats: firstIn, fadeOutBeats: firstOut,
            fadeInCurve: clip.fadeInCurve, fadeOutCurve: .linear,
            stretchRatio: clip.stretchRatio, pitchShiftSemitones: clip.pitchShiftSemitones,
            formantPreserve: clip.formantPreserve)
        let second = Clip(
            id: UUID(), name: clip.name,
            startBeat: clip.startBeat + firstLength, lengthBeats: secondLength,
            audioFileURL: clip.audioFileURL, notes: secondNotes,
            isAIGenerated: clip.isAIGenerated,
            startOffsetSeconds: clip.startOffsetSeconds + splitSeconds, gainDb: clip.gainDb,
            fadeInBeats: secondIn, fadeOutBeats: secondOut,
            fadeInCurve: .linear, fadeOutCurve: clip.fadeOutCurve,
            stretchRatio: clip.stretchRatio, pitchShiftSemitones: clip.pitchShiftSemitones,
            formantPreserve: clip.formantPreserve)

        performEdit("Split Clip '\(clip.name)'") {
            tracks[t].clips[c] = first
            tracks[t].clips.insert(second, at: c + 1)
            engine?.tracksDidChange(tracks)
        }
        return (first, second)
    }

    /// Trims a clip to a new timeline window `[newStartBeat, newStartBeat +
    /// newLengthBeats]` (both clamped: start >= 0, length >= `minClipLengthBeats`).
    /// The clip CONTENT stays fixed on the timeline, so only the visible window
    /// moves:
    /// - Leading-edge move: `startOffsetSeconds` advances by the start delta
    ///   converted beats -> seconds at the current tempo (clamped >= 0), so an
    ///   audio clip keeps playing the right region of its source.
    /// - MIDI notes shift by the start delta and are DROPPED when they fall
    ///   wholly outside the new window, or TRUNCATED where they cross either
    ///   edge (a note thinner than `MIDINote.minLengthBeats` after truncation is
    ///   dropped).
    /// - Fades re-clamp to the new length (proportional reduction on conflict).
    /// The clip id is preserved. Coalesces under `clip.trim:<clipId>` so a drag
    /// of the edge is one undo step.
    @discardableResult
    public func trimClip(trackId: UUID, clipId: UUID,
                         newStartBeat: Double, newLengthBeats: Double) throws -> Clip {
        let (t, c) = try locateClip(trackID: trackId, clipID: clipId)
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let clip = tracks[t].clips[c]
        let oldStart = clip.startBeat
        let newStart = max(0, newStartBeat)
        let newLength = max(Self.minClipLengthBeats, newLengthBeats)
        let delta = newStart - oldStart  // > 0 trims the leading edge inward
        // Signed integral over the trimmed span (m12-b, design row 13).
        let newOffset = max(0, clip.startOffsetSeconds
            + transport.tempoMap.seconds(from: oldStart, to: newStart))

        var newNotes: [MIDINote]?
        if let notes = clip.notes {
            newNotes = notes.compactMap { note -> MIDINote? in
                let shiftedStart = note.startBeat - delta
                let shiftedEnd = shiftedStart + note.lengthBeats
                // Wholly before the new leading edge or past the new trailing edge.
                guard shiftedEnd > 0, shiftedStart < newLength else { return nil }
                let clampedStart = max(0, shiftedStart)
                let clampedEnd = min(shiftedEnd, newLength)
                let length = clampedEnd - clampedStart
                guard length >= MIDINote.minLengthBeats else { return nil }
                return MIDINote(id: note.id, pitch: note.pitch, velocity: note.velocity,
                                startBeat: clampedStart, lengthBeats: length)
            }
        }

        let (fin, fout) = Self.clampedFades(
            fadeIn: clip.fadeInBeats, fadeOut: clip.fadeOutBeats, length: newLength)
        let rebuilt = Clip(
            id: clip.id, name: clip.name,
            startBeat: newStart, lengthBeats: newLength,
            audioFileURL: clip.audioFileURL, notes: newNotes,
            isAIGenerated: clip.isAIGenerated,
            startOffsetSeconds: newOffset, gainDb: clip.gainDb,
            fadeInBeats: fin, fadeOutBeats: fout,
            fadeInCurve: clip.fadeInCurve, fadeOutCurve: clip.fadeOutCurve,
            // Trim is geometry-free w.r.t. stretch (spec §1): the ratio/pitch/
            // formant carry through unchanged — only the visible window moves.
            stretchRatio: clip.stretchRatio, pitchShiftSemitones: clip.pitchShiftSemitones,
            formantPreserve: clip.formantPreserve)

        performEdit("Trim Clip '\(clip.name)'", key: "clip.trim:\(clipId.uuidString)") {
            tracks[t].clips[c] = rebuilt
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Moves a clip to a new timeline start (clamped >= 0), then RESOLVES any
    /// overlap the move creates against ordinary same-track clips (m11-d). Same-
    /// track only in v0 — a cross-track move is additive later. Coalesces under
    /// `clip.move:<clipId>` so a drag is one undo step.
    ///
    /// Overlap policy (v0, Logic-default — the settled invariant "no SILENT
    /// overlap of ordinary same-track clips"): when the moved clip lands over an
    /// ordinary same-track clip, the STATIONARY clip yields the overlapping
    /// region using trim-window semantics (audio source offset advances, MIDI
    /// notes drop/truncate at the new edge — the `trimClip` rules):
    ///  - Covered head → the stationary clip's leading edge trims to the moved
    ///    clip's right edge (it keeps its tail).
    ///  - Covered tail OR a moved clip landing strictly inside → the stationary
    ///    clip's trailing edge trims to the moved clip's left edge (it keeps its
    ///    head — a single trim can't punch a hole, so the moved clip wins the
    ///    whole region from its start onward).
    ///  - Fully covered (or a remnant thinner than `minClipLengthBeats`) → the
    ///    stationary clip is REMOVED.
    /// Take-group / comp members are EXEMPT (the `requireNotCompMember`
    /// precedent — their geometry is comp-managed). A previously-crossfaded clip
    /// carries no special bookkeeping: the trim runs against CURRENT boundaries
    /// and any surviving fades stay as plain per-clip fades. All of it rides the
    /// move's single `performEdit`, so ONE undo restores everything. Returns the
    /// moved clip plus the ids that were trimmed / removed.
    @discardableResult
    public func moveClip(trackId: UUID, clipId: UUID, toStartBeat: Double) throws -> ClipMoveResult {
        let (t, c) = try locateClip(trackID: trackId, clipID: clipId)
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let newStart = max(0, toStartBeat)
        let moved = tracks[t].clips[c]
        let name = moved.name
        let tempoMap = transport.tempoMap
        let aStart = newStart
        let aEnd = newStart + moved.lengthBeats
        var trimmedIDs: [UUID] = []
        var removedIDs: [UUID] = []
        performEdit("Move Clip '\(name)'", key: "clip.move:\(clipId.uuidString)") {
            var rebuilt: [Clip] = []
            rebuilt.reserveCapacity(tracks[t].clips.count)
            for existing in tracks[t].clips {
                if existing.id == clipId {
                    var m = existing
                    m.startBeat = newStart
                    rebuilt.append(m)
                    continue
                }
                // Comp members keep their existing guards — never trimmed here.
                if existing.takeGroupID != nil { rebuilt.append(existing); continue }
                let resolved = Self.resolveOverlap(
                    stationary: existing, activeStart: aStart, activeEnd: aEnd, tempoMap: tempoMap)
                if resolved.isEmpty {
                    removedIDs.append(existing.id)
                } else if resolved != [existing] {
                    trimmedIDs.append(existing.id)
                }
                rebuilt.append(contentsOf: resolved)
            }
            tracks[t].clips = rebuilt
            engine?.tracksDidChange(tracks)
        }
        let final = tracks[t].clips.first { $0.id == clipId } ?? moved
        return ClipMoveResult(clip: final, trimmedClipIDs: trimmedIDs, removedClipIDs: removedIDs)
    }

    /// Pure geometry (m11-d): rebuilds `clip` so its visible window becomes
    /// `[newStart, newStart + newLength)`, advancing the audio source offset and
    /// dropping/truncating MIDI notes EXACTLY as `trimClip` does — but WITHOUT
    /// journaling, so the overlap-resolution and import paths can fold their
    /// trims into the caller's single undo step. Returns nil when the remnant is
    /// shorter than `minClipLengthBeats` (a sub-1/32-beat sliver — dropped so the
    /// no-silent-overlap invariant can never leave a re-overlapping crumb).
    static func clipTrimmedToWindow(_ clip: Clip, newStart: Double, newLength: Double,
                                    tempoMap: TempoMap) -> Clip? {
        guard newLength >= minClipLengthBeats else { return nil }
        let start = max(0, newStart)
        let delta = start - clip.startBeat  // > 0 trims the leading edge inward
        // Signed integral over the covered span (m12-b, design row 15).
        let newOffset = max(0, clip.startOffsetSeconds
            + tempoMap.seconds(from: clip.startBeat, to: start))
        var newNotes: [MIDINote]?
        if let notes = clip.notes {
            newNotes = notes.compactMap { note -> MIDINote? in
                let shiftedStart = note.startBeat - delta
                let shiftedEnd = shiftedStart + note.lengthBeats
                guard shiftedEnd > 0, shiftedStart < newLength else { return nil }
                let clampedStart = max(0, shiftedStart)
                let clampedEnd = min(shiftedEnd, newLength)
                let length = clampedEnd - clampedStart
                guard length >= MIDINote.minLengthBeats else { return nil }
                return MIDINote(id: note.id, pitch: note.pitch, velocity: note.velocity,
                                startBeat: clampedStart, lengthBeats: length)
            }
        }
        let (fin, fout) = clampedFades(fadeIn: clip.fadeInBeats, fadeOut: clip.fadeOutBeats, length: newLength)
        return Clip(
            id: clip.id, name: clip.name,
            startBeat: start, lengthBeats: newLength,
            audioFileURL: clip.audioFileURL, notes: newNotes,
            isAIGenerated: clip.isAIGenerated,
            startOffsetSeconds: newOffset, gainDb: clip.gainDb,
            fadeInBeats: fin, fadeOutBeats: fout,
            fadeInCurve: clip.fadeInCurve, fadeOutCurve: clip.fadeOutCurve,
            stretchRatio: clip.stretchRatio, pitchShiftSemitones: clip.pitchShiftSemitones,
            formantPreserve: clip.formantPreserve)
    }

    /// Resolves how one STATIONARY same-track clip must change so it no longer
    /// silently overlaps the active window `[activeStart, activeEnd)` (m11-d).
    /// Returns the clip(s) that replace it: the clip unchanged (no overlap),
    /// edge-trimmed (partial overlap — head or tail), or none (fully covered, or
    /// trimmed below `minClipLengthBeats` → removed). A move landing strictly
    /// inside the stationary clip trims its tail (keeps its head) — a single trim
    /// can't punch a hole, so the moved clip wins the whole region from its start
    /// onward. Comp members are never passed here (the caller exempts them).
    static func resolveOverlap(stationary: Clip, activeStart: Double, activeEnd: Double,
                               tempoMap: TempoMap) -> [Clip] {
        let sStart = stationary.startBeat
        let sEnd = stationary.startBeat + stationary.lengthBeats
        // Disjoint — touching at a shared edge counts as adjacent, not overlap.
        guard activeStart < sEnd, activeEnd > sStart else { return [stationary] }
        // The active window fully covers the stationary clip → remove it.
        if activeStart <= sStart, activeEnd >= sEnd { return [] }
        // Covers the head only → trim the leading edge to the active right edge.
        if activeStart <= sStart {
            return clipTrimmedToWindow(stationary, newStart: activeEnd,
                                       newLength: sEnd - activeEnd, tempoMap: tempoMap).map { [$0] } ?? []
        }
        // Covers the tail, or lands strictly inside → trim the trailing edge to
        // the active left edge (keep the stationary clip's head).
        return clipTrimmedToWindow(stationary, newStart: sStart,
                                   newLength: activeStart - sStart, tempoMap: tempoMap).map { [$0] } ?? []
    }

    /// Crossfades two AUDIO clips on ONE track (m11-d) — the explicit tool that
    /// SANCTIONS an overlap (the only legitimate same-track overlap; every other
    /// path upholds `moveClip`'s no-silent-overlap invariant). The two ids may be
    /// passed in either order; the earlier-starting clip is A (left), the later
    /// is B (right). Preconditions (else `crossfadeNotEligible`): both clips on
    /// the given track, both audio, `lengthBeats > 0`, and the clips ADJACENT
    /// (B.start == A.end) OR already overlapping by `≤ lengthBeats`.
    ///
    /// Geometry:
    ///  - Adjacent → the overlap is CREATED of exactly `lengthBeats`, split
    ///    symmetrically: A's right edge extends `lengthBeats/2` into its trailing
    ///    source material and B's left edge extends `lengthBeats/2` into its
    ///    leading source material — keeping both clips' content time-aligned in
    ///    the overlap, so the equal-power sum reconstructs the original signal.
    ///    If either side lacks the source audio to extend, throws
    ///    `crossfadeNeedsMaterial` NAMING that clip/side.
    ///  - Already overlapping (a legacy pre-fix overlap) → the EXISTING overlap
    ///    is KEPT (no extension, no material needed) and the fades are applied
    ///    over it — "normalize the overlap".
    ///
    /// Then A gets a fade-OUT and B a fade-IN, each `FadeCurve.equalPower` (which
    /// sums to unit power — Model.swift) spanning EXACTLY the final overlap; each
    /// clip's OTHER fade is preserved (only trimmed if it would collide with the
    /// overlap fade — the overlap fade is authoritative). ONE undo step
    /// ("Crossfade Clips"). Comp members are rejected (`requireNotCompMember`).
    /// Returns the two clips (left/right) and the final overlap length.
    @discardableResult
    public func crossfadeClips(trackId: UUID, clipId: UUID, otherClipId: UUID,
                               lengthBeats: Double) throws -> CrossfadeResult {
        guard let ti = tracks.firstIndex(where: { $0.id == trackId }) else {
            throw ProjectError.trackNotFound(trackId)
        }
        guard clipId != otherClipId else {
            throw ProjectError.crossfadeNotEligible(
                "clipId and otherClipId are the same clip — a crossfade needs two different clips")
        }
        guard let i1 = tracks[ti].clips.firstIndex(where: { $0.id == clipId }) else {
            throw ProjectError.clipNotFound(clipId)
        }
        guard let i2 = tracks[ti].clips.firstIndex(where: { $0.id == otherClipId }) else {
            throw ProjectError.clipNotFound(otherClipId)
        }
        try requireNotCompMember(trackIndex: ti, clipIndex: i1)
        try requireNotCompMember(trackIndex: ti, clipIndex: i2)
        let c1 = tracks[ti].clips[i1]
        let c2 = tracks[ti].clips[i2]
        guard !c1.isMIDI else {
            throw ProjectError.crossfadeNotEligible(
                "clip '\(c1.name)' is a MIDI clip — crossfades apply to audio clips only")
        }
        guard !c2.isMIDI else {
            throw ProjectError.crossfadeNotEligible(
                "clip '\(c2.name)' is a MIDI clip — crossfades apply to audio clips only")
        }
        guard lengthBeats > 0 else {
            throw ProjectError.crossfadeNotEligible(
                "crossfade length must be greater than 0 beats")
        }
        guard c1.startBeat != c2.startBeat else {
            throw ProjectError.crossfadeNotEligible(
                "both clips start at the same beat — a crossfade needs an earlier clip and a later one")
        }
        let (left, right) = c1.startBeat < c2.startBeat ? (c1, c2) : (c2, c1)

        let tempoMap = transport.tempoMap
        let eps = 1e-6
        let seam = left.startBeat + left.lengthBeats
        let currentOverlap = seam - right.startBeat
        if currentOverlap < -eps {
            throw ProjectError.crossfadeNotEligible(
                "clips '\(left.name)' and '\(right.name)' are not adjacent — there is a "
                + String(format: "%.3f", -currentOverlap)
                + "-beat gap between them; move them together (clip.move) before crossfading")
        }
        if currentOverlap > lengthBeats + eps {
            throw ProjectError.crossfadeNotEligible(
                "clips '\(left.name)' and '\(right.name)' already overlap by "
                + String(format: "%.3f", currentOverlap)
                + " beats — more than the requested \(lengthBeats)-beat crossfade; pass a longer length")
        }

        var newLeft = left
        var newRight = right
        let finalOverlap: Double
        if currentOverlap > eps {
            // Legacy-overlap normalization: keep the existing overlap, only fade.
            finalOverlap = currentOverlap
        } else {
            // Adjacent: create the overlap symmetrically, extending both source
            // windows so the overlap stays time-aligned.
            let half = lengthBeats / 2
            // Right clip head extension: reveal `half` beats of pre-roll
            // material — the integral over the extension span AT the seam
            // (m12-b, design row 16).
            let rightHeadSource = tempoMap.seconds(from: right.startBeat - half,
                                                   to: right.startBeat) / right.stretchRatio
            guard right.startOffsetSeconds + eps >= rightHeadSource else {
                throw ProjectError.crossfadeNeedsMaterial(
                    "clip '\(right.name)' has no audio before its start to extend into the crossfade "
                    + "— use a shorter crossfade, or move the clips so they already overlap")
            }
            guard right.startBeat + eps >= half else {
                throw ProjectError.crossfadeNeedsMaterial(
                    "clip '\(right.name)' is too close to the start of the timeline to fit a "
                    + "\(lengthBeats)-beat crossfade")
            }
            // Left clip tail extension: needs source material past its window end.
            guard let media else { throw ProjectError.mediaServiceUnavailable }
            guard let url = left.audioFileURL else {
                throw ProjectError.crossfadeNeedsMaterial(
                    "clip '\(left.name)' has no source file to extend past its end into the crossfade")
            }
            let fileDuration = try media.audioFileInfo(at: url).durationSeconds
            // Left tail extension: the integral over [seam, seam + half]
            // (m12-b, design row 17).
            let leftTailSource = tempoMap.seconds(from: seam, to: seam + half)
                / left.stretchRatio
            let leftWindowEnd = left.startOffsetSeconds + left.sourceWindowSeconds(tempoMap: tempoMap)
            guard leftWindowEnd + leftTailSource <= fileDuration + eps else {
                throw ProjectError.crossfadeNeedsMaterial(
                    "clip '\(left.name)' has no audio past its end to extend into the crossfade "
                    + "— use a shorter crossfade, or move the clips so they already overlap")
            }
            newLeft.lengthBeats = left.lengthBeats + half
            newRight.startBeat = right.startBeat - half
            newRight.lengthBeats = right.lengthBeats + half
            newRight.startOffsetSeconds = max(0, right.startOffsetSeconds - rightHeadSource)
            finalOverlap = lengthBeats
        }

        // Complementary equal-power fades spanning EXACTLY the overlap; the
        // overlap fade wins, the opposite fade yields only on a collision.
        let outLen = min(finalOverlap, newLeft.lengthBeats)
        newLeft.fadeOutBeats = outLen
        newLeft.fadeOutCurve = .equalPower
        newLeft.fadeInBeats = min(newLeft.fadeInBeats, max(0, newLeft.lengthBeats - outLen))
        let inLen = min(finalOverlap, newRight.lengthBeats)
        newRight.fadeInBeats = inLen
        newRight.fadeInCurve = .equalPower
        newRight.fadeOutBeats = min(newRight.fadeOutBeats, max(0, newRight.lengthBeats - inLen))

        performEdit("Crossfade Clips") {
            if let i = tracks[ti].clips.firstIndex(where: { $0.id == newLeft.id }) {
                tracks[ti].clips[i] = newLeft
            }
            if let j = tracks[ti].clips.firstIndex(where: { $0.id == newRight.id }) {
                tracks[ti].clips[j] = newRight
            }
            engine?.tracksDidChange(tracks)
        }
        let finalLeft = tracks[ti].clips.first { $0.id == newLeft.id } ?? newLeft
        let finalRight = tracks[ti].clips.first { $0.id == newRight.id } ?? newRight
        return CrossfadeResult(left: finalLeft, right: finalRight, overlapBeats: finalOverlap)
    }

    /// Sets a clip's per-clip gain, clamped to `Clip.gainDbRange`. Coalesces
    /// under `clip.gain:<clipId>` so a knob scrub is one undo step.
    @discardableResult
    public func setClipGain(trackId: UUID, clipId: UUID, gainDb: Double) throws -> Clip {
        let (t, c) = try locateClip(trackID: trackId, clipID: clipId)
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let clamped = gainDb.clamped(to: Clip.gainDbRange)
        performEdit("Set Clip Gain", key: "clip.gain:\(clipId.uuidString)") {
            tracks[t].clips[c].gainDb = clamped
            // Live path first (M5 i-b): one player-volume write, playback
            // never interrupted. tracksDidChange still runs so the engine's
            // cached tracks stay fresh (gainDb is in no reconcile signature,
            // so it never triggers a restart — its parameter pass just
            // re-writes the same volume).
            engine?.clipGainChanged(trackID: trackId, clipID: clipId, gainDb: clamped)
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Sets a clip's fades WHOLESALE (the `setAutomationPoints` precedent): the
    /// two lengths are clamped to `[0, lengthBeats]` and proportionally reduced
    /// when their sum exceeds the clip length; the two curves are set as given.
    /// Coalesces under `clip.fades:<clipId>` so a fade-handle drag is one undo
    /// step.
    @discardableResult
    public func setClipFades(trackId: UUID, clipId: UUID,
                             fadeInBeats: Double, fadeOutBeats: Double,
                             fadeInCurve: FadeCurve, fadeOutCurve: FadeCurve) throws -> Clip {
        let (t, c) = try locateClip(trackID: trackId, clipID: clipId)
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let (fin, fout) = Self.clampedFades(
            fadeIn: fadeInBeats, fadeOut: fadeOutBeats, length: tracks[t].clips[c].lengthBeats)
        performEdit("Set Clip Fades", key: "clip.fades:\(clipId.uuidString)") {
            tracks[t].clips[c].fadeInBeats = fin
            tracks[t].clips[c].fadeOutBeats = fout
            tracks[t].clips[c].fadeInCurve = fadeInCurve
            tracks[t].clips[c].fadeOutCurve = fadeOutCurve
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Sets a clip's time-stretch / pitch-shift parameters DIRECTLY (the agent
    /// surface, M5 ii-c): each argument is optional, and `nil` KEEPS the clip's
    /// current value. `ratio` is the ABSOLUTE, tempo-independent output-time
    /// multiplier (2.0 = twice as long), clamped to `Clip.stretchRatioRange`;
    /// `semitones` clamps to `Clip.pitchShiftSemitonesRange`. Does NOT change
    /// `lengthBeats` (use `stretchClip` for the length-linked handle). Audio
    /// clips only — a MIDI clip throws `invalidClipEdit` (audio-only in v0, the
    /// gain/fades family). Coalesces under `clip.stretch:<clipId>` so a scrub is
    /// one undo step. The engine ignores the fields until ii-d (see spec §4).
    @discardableResult
    public func setClipStretch(trackId: UUID, clipId: UUID,
                               ratio: Double? = nil,
                               semitones: Double? = nil,
                               formantPreserve: Bool? = nil) throws -> Clip {
        let (t, c) = try locateClip(trackID: trackId, clipID: clipId)
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let clip = tracks[t].clips[c]
        guard !clip.isMIDI else {
            throw ProjectError.invalidClipEdit(
                "clip '\(clip.name)' is a MIDI clip — time-stretch/pitch-shift applies to audio clips only")
        }
        let newRatio = (ratio ?? clip.stretchRatio).clamped(to: Clip.stretchRatioRange)
        let newSemitones = (semitones ?? clip.pitchShiftSemitones).clamped(to: Clip.pitchShiftSemitonesRange)
        let newFormant = formantPreserve ?? clip.formantPreserve
        performEdit("Set Clip Stretch", key: "clip.stretch:\(clipId.uuidString)") {
            tracks[t].clips[c].stretchRatio = newRatio
            tracks[t].clips[c].pitchShiftSemitones = newSemitones
            tracks[t].clips[c].formantPreserve = newFormant
            // A ClipKey-affecting edit (ii-d): rides the stop-reschedule-resume
            // seam like a fade edit. Harmless today — the engine ignores the
            // fields until ii-d.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// The stretch-HANDLE op (M5 ii-c): retargets a clip to a new timeline
    /// length while holding the SOURCE WINDOW constant — the compound that
    /// distinguishes a stretch handle from a trim handle (which changes the
    /// window at fixed ratio). Sets `lengthBeats = toLengthBeats` (floored at
    /// `minClipLengthBeats`) AND scales `stretchRatio` by the length change, so
    /// `sourceWindowSeconds` is invariant (equivalently `lengthBeats /
    /// stretchRatio` is held constant, spec §1). If the scaled ratio would
    /// leave `stretchRatioRange`, it clamps and `lengthBeats` is RE-DERIVED from
    /// the clamped ratio so window invariance survives the clamp. Fades
    /// re-clamp to the new length. Audio clips only (MIDI throws
    /// `invalidClipEdit`). Coalesces under the SAME `clip.stretch:<clipId>` key
    /// as `setClipStretch`, so a handle drag interleaving both stays one undo
    /// gesture.
    @discardableResult
    public func stretchClip(trackId: UUID, clipId: UUID,
                            toLengthBeats: Double) throws -> Clip {
        let (t, c) = try locateClip(trackID: trackId, clipID: clipId)
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let clip = tracks[t].clips[c]
        guard !clip.isMIDI else {
            throw ProjectError.invalidClipEdit(
                "clip '\(clip.name)' is a MIDI clip — time-stretch applies to audio clips only")
        }
        let oldLength = clip.lengthBeats
        let oldRatio = clip.stretchRatio
        let targetLength = max(Self.minClipLengthBeats, toLengthBeats)
        // Guard a degenerate zero-length source clip (can't scale a ratio off
        // it): fall back to a plain length set at the current ratio.
        guard oldLength > 0, oldRatio > 0 else {
            let (fin0, fout0) = Self.clampedFades(
                fadeIn: clip.fadeInBeats, fadeOut: clip.fadeOutBeats, length: targetLength)
            performEdit("Stretch Clip '\(clip.name)'", key: "clip.stretch:\(clipId.uuidString)") {
                tracks[t].clips[c].lengthBeats = targetLength
                tracks[t].clips[c].fadeInBeats = fin0
                tracks[t].clips[c].fadeOutBeats = fout0
                engine?.tracksDidChange(tracks)
            }
            return tracks[t].clips[c]
        }
        // Window invariance: lengthBeats / ratio stays constant. Scale the ratio
        // by the length change, then clamp; on clamp, re-derive the length from
        // the (constant) invariant so the source window is preserved exactly.
        let windowInvariant = oldLength / oldRatio  // == lengthBeats / stretchRatio
        let desiredRatio = oldRatio * (targetLength / oldLength)
        let newRatio = desiredRatio.clamped(to: Clip.stretchRatioRange)
        let newLength = newRatio == desiredRatio
            ? targetLength
            : max(Self.minClipLengthBeats, windowInvariant * newRatio)
        let (fin, fout) = Self.clampedFades(
            fadeIn: clip.fadeInBeats, fadeOut: clip.fadeOutBeats, length: newLength)
        performEdit("Stretch Clip '\(clip.name)'", key: "clip.stretch:\(clipId.uuidString)") {
            tracks[t].clips[c].lengthBeats = newLength
            tracks[t].clips[c].stretchRatio = newRatio
            tracks[t].clips[c].fadeInBeats = fin
            tracks[t].clips[c].fadeOutBeats = fout
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    // MARK: - Mixdown

    /// Bounces the current session to a WAV file through the injected engine's
    /// offline render path. Blocking; v0 accepts the main-actor stall for
    /// typical song lengths. When `durationSeconds` is nil, the bounce runs
    /// from `fromBeat` to the last audio clip's end at the current tempo plus
    /// a 0.5 s tail; with no clips (or `fromBeat` past all of them) that
    /// default is meaningless and the call throws `nothingToRender`.
    public func renderMixdown(
        toPath path: String? = nil,
        fromBeat: Double = 0,
        durationSeconds: Double? = nil
    ) async throws -> MixdownResult {
        guard let engine else { throw ProjectError.engineUnavailable }
        let startBeat = max(0, fromBeat)

        let duration: Double
        if let durationSeconds {
            duration = durationSeconds
        } else {
            let clipEnds = tracks.filter { $0.kind == .audio }
                .flatMap(\.clips)
                .map { $0.startBeat + $0.lengthBeats }
            guard let lastEndBeat = clipEnds.max() else {
                throw ProjectError.nothingToRender
            }
            // Default window = the integral over [startBeat, lastEndBeat]
            // (m12-b, design row 18 family — the mixdown's audio-only legacy
            // default; the shared broader default is `renderWindowSeconds`).
            let contentSeconds = transport.tempoMap.seconds(from: startBeat, to: lastEndBeat)
            guard contentSeconds > 0 else { throw ProjectError.nothingToRender }
            duration = contentSeconds + 0.5  // release/reverb tail headroom
        }

        let url = Self.mixdownDestination(from: path)
        let info = try await engine.renderMixdown(
            tracks: tracks,
            tempoMap: transport.tempoMap,
            masterVolume: masterVolume,
            fromBeat: startBeat,
            durationSeconds: duration,
            to: url
        )
        // A file landed on disk — tick the render counter for the onboarding
        // signal adapter (ob-b), which fires `renderCompleted` on an increment.
        renderCompletedCount += 1
        return MixdownResult(
            path: url.path,
            durationSeconds: info.durationSeconds,
            sampleRate: info.sampleRate,
            channels: info.channelCount
        )
    }

    /// Destination resolution: nil → a unique file under
    /// NSTemporaryDirectory()/DAWPro/; otherwise `~` expands and `.wav` is
    /// appended unless the path already carries it (case-insensitive).
    private static func mixdownDestination(from path: String?) -> URL {
        guard let path else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DAWPro", isDirectory: true)
                .appendingPathComponent("mixdown-\(UUID().uuidString.prefix(8)).wav")
        }
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.lowercased().hasSuffix(".wav") {
            expanded += ".wav"
        }
        return URL(fileURLWithPath: expanded)
    }

    // MARK: - Persistence

    /// Marks the session as having unsaved edits. The single dirty funnel —
    /// called only from state-changing session mutations, never from
    /// play/stop/seek, playhead pushes, input-device selection, or metering.
    private func markDirty() { isDirty = true }

    // MARK: - Undo / redo

    /// Reverses the most recent edit. Refused mid-take (`transportBusy`) since a
    /// rolling take mustn't have the ground swapped under it. Throws
    /// `nothingToUndo` when the stack is empty. Restores the pre-edit document
    /// state (preserving the live playhead/play state), reconciles the engine,
    /// marks the session dirty, and returns the reversed operation's label.
    @discardableResult
    public func undo() throws -> String {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot undo while recording — stop first")
        }
        guard let entry = journal.popUndo(current: captureEditState()) else {
            throw ProjectError.nothingToUndo
        }
        restoreEditState(entry.before)
        markDirty()
        return entry.label
    }

    /// Reapplies the most recently undone edit. Mirror of `undo`: refused
    /// mid-take, throws `nothingToRedo` when the redo stack is empty.
    @discardableResult
    public func redo() throws -> String {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot redo while recording — stop first")
        }
        guard let entry = journal.popRedo(current: captureEditState()) else {
            throw ProjectError.nothingToRedo
        }
        restoreEditState(entry.before)
        markDirty()
        return entry.label
    }

    /// Snapshots the undoable document state, normalizing transport transience
    /// out (isPlaying/isRecording/positionBeats) so play, record, and playhead
    /// motion never register as edits.
    private func captureEditState() -> EditState {
        var t = transport
        t.isPlaying = false
        t.isRecording = false
        t.positionBeats = 0
        // Phase-B staging seam — replaced by tempo.setMap in Phase C: the
        // session map override is NON-undoable, so it is normalized out here
        // (installing/clearing it never registers as an edit and journal
        // entries never carry it) and preserved across restore below.
        t.sessionTempoMapOverride = nil
        return EditState(tracks: tracks, masterVolume: masterVolume, transport: t,
                         grooveTemplates: grooveTemplates, markers: markers)
    }

    /// The single funnel every undoable mutation passes through. Captures the
    /// pre-edit state, runs `body`, and journals an undo entry ONLY when the
    /// state actually changed (a no-op still marks dirty but adds no history).
    /// `key` opts the edit into time-coalescing with adjacent same-key edits.
    /// `markDirty()` always fires. Module-`internal` (not `private`) so
    /// `ProjectStore+*` extension files funnel their mutations through the same
    /// undo/dirty seam.
    @discardableResult
    func performEdit<T>(_ label: String, key: String? = nil,
                        _ body: () throws -> T) rethrows -> T {
        let before = captureEditState()
        let result = try body()
        if captureEditState() != before {
            journal.recordEdit(label: label, key: key, before: before)
            // Publish the journaled edit for the onboarding signal adapter (ob-b).
            // Only fires when a journal entry actually records (real change), so a
            // no-op edit stays silent; seq ticks even for coalesced same-key edits.
            editEventSeq += 1
            lastEditEvent = EditEvent(seq: editEventSeq, label: label, key: key)
        }
        markDirty()
        return result
    }

    /// Swaps the document fields of `transport`, `tracks`, and `masterVolume` to
    /// `target`, PRESERVING the live playhead and play state (and forcing
    /// isRecording off — undo/redo is refused mid-take, so this is belt-and-
    /// suspenders). Prunes meters for tracks that vanished, then reconciles the
    /// engine with only the intents whose inputs actually moved.
    private func restoreEditState(_ target: EditState) {
        let vanishedTrackIDs = Set(tracks.map(\.id)).subtracting(target.tracks.map(\.id))

        // Compute what changed BEFORE overwriting, to target engine intents.
        let tracksChanged = tracks != target.tracks
        let masterChanged = masterVolume != target.masterVolume
        // Map compare (m12-b, design row 36). Both sides are compared in
        // captured form (session override normalized out — target already is,
        // by captureEditState), so an installed Phase-B staging map neither
        // masks a real scalar-tempo undo nor forces a spurious restart on
        // every unrelated undo.
        var liveCaptured = transport
        liveCaptured.sessionTempoMapOverride = nil
        let tempoChanged = liveCaptured.tempoMap != target.transport.tempoMap
        let loopChanged = transport.isLoopEnabled != target.transport.isLoopEnabled
            || transport.loopStartBeat != target.transport.loopStartBeat
            || transport.loopEndBeat != target.transport.loopEndBeat
        let metronomeChanged = transport.isMetronomeEnabled != target.transport.isMetronomeEnabled
            || transport.countInBars != target.transport.countInBars

        tracks = target.tracks
        masterVolume = target.masterVolume
        // Groove palette rides the same snapshot (no engine involvement — grooves
        // are pure data applied at quantize time).
        grooveTemplates = target.grooveTemplates
        // Markers ride the same snapshot (pure data — no engine, no media); the
        // captured list is already beat-sorted, so undo/redo preserve the invariant.
        markers = target.markers
        // Keep the live playhead + play state; restore every persistable field.
        var restored = target.transport
        restored.isPlaying = transport.isPlaying
        restored.positionBeats = transport.positionBeats
        restored.isRecording = false
        // Phase-B staging seam — replaced by tempo.setMap in Phase C: the
        // session map override survives undo/redo untouched (non-undoable).
        restored.sessionTempoMapOverride = transport.sessionTempoMapOverride
        transport = restored

        for id in vanishedTrackIDs {
            trackMeters.removeValue(forKey: id)
        }

        if tracksChanged { engine?.tracksDidChange(tracks) }
        if masterChanged { engine?.masterVolumeChanged(masterVolume) }
        if tempoChanged { engine?.setTempo(transport) }
        if loopChanged { engine?.loopChanged(transport) }
        if metronomeChanged, transport.isPlaying { engine?.seek(transport) }
    }

    /// Saves the session to a `.dawproj` bundle.
    ///  - `path == nil`: save in place; an untitled session throws
    ///    `.projectPathRequired`.
    ///  - `path != nil`: save-as — the path is normalized (`~` expanded,
    ///    `.dawproj` appended if absent), then ADOPTED (`projectPath`/
    ///    `projectName` follow the bundle basename).
    /// Media is always copied in (self-contained); after a successful save the
    /// in-memory clip URLs point at the bundle's `media/`. Refused while
    /// recording; allowed while playing. Clears `isDirty` on success.
    @discardableResult
    public func saveProject(to path: String? = nil) throws -> ProjectSaveResult {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot save while recording — stop first")
        }

        let bundleURL: URL
        let adoptName: Bool
        if let path {
            bundleURL = ProjectBundle.normalizedBundleURL(fromPath: path)
            adoptName = true
        } else {
            guard let existing = projectPath else { throw ProjectError.projectPathRequired }
            bundleURL = URL(fileURLWithPath: existing).standardizedFileURL
            adoptName = false
        }

        // Plan (deterministic track/clip order) and build the document before
        // any filesystem mutation. The document is built from a LOCAL COPY of
        // the tracks with each hosted AU's live state captured in — no model
        // mutation, no undo entry, no dirty flip.
        let persistedTracks = tracksWithCapturedAudioUnitState()
        var stateWarnings: [String] = []
        for track in persistedTracks {
            if let byteCount = track.instrument?.audioUnit?.stateData?.count,
               byteCount > Self.audioUnitStateSoftCapBytes {
                stateWarnings.append(
                    "Audio Unit state for track '\(track.name)' is large (\(byteCount / (1024 * 1024)) MiB) — saved anyway")
            }
            for effect in track.effects {
                if let byteCount = effect.audioUnit?.stateData?.count,
                   byteCount > Self.audioUnitStateSoftCapBytes {
                    stateWarnings.append(
                        "Audio Unit effect state on track '\(track.name)' is large (\(byteCount / (1024 * 1024)) MiB) — saved anyway")
                }
            }
        }
        let plan = ProjectBundle.planMedia(tracks: persistedTracks, bundleURL: bundleURL)
        let effectiveName = adoptName
            ? bundleURL.deletingPathExtension().lastPathComponent
            : projectName
        let document = ProjectDocument(
            name: effectiveName,
            transport: transport,
            tracks: persistedTracks,
            masterVolume: masterVolume,
            mediaRefs: plan.refs,
            grooveTemplates: grooveTemplates,
            markers: markers
        )
        do {
            try ProjectBundle.write(document: document, plan: plan, to: bundleURL)
        } catch {
            throw ProjectError.saveFailed(Self.reason(error))
        }

        projectPath = bundleURL.path
        projectName = effectiveName

        // Rewrite in-memory clip URLs to their new bundle paths (only for clips
        // that actually landed in media/; a null-ref clip keeps its original URL
        // so a transiently-missing source isn't destroyed). tracksDidChange
        // fires ONLY if some URL changed — that path costs the engine a
        // stop-reschedule-resume (~60 ms seam), so we don't pay it for no-ops.
        let mediaDir = bundleURL.appendingPathComponent("media", isDirectory: true)
        var anyURLChanged = false
        for t in tracks.indices {
            for c in tracks[t].clips.indices {
                guard let ref = plan.refs[tracks[t].clips[c].id] ?? nil,
                      ref.hasPrefix("media/") else { continue }
                let newURL = mediaDir.appendingPathComponent(String(ref.dropFirst("media/".count)))
                // Compare by path: URL equality also weighs the isDirectory flag,
                // which would flag a spurious change on an idempotent re-save.
                if tracks[t].clips[c].audioFileURL?.path != newURL.path {
                    tracks[t].clips[c].audioFileURL = newURL
                    anyURLChanged = true
                }
            }
            // Sampler zone media rides the same rewrite: a zone whose source was
            // copied in (ref keyed by zone id, "media/…") is repointed at the
            // bundle so the live sampler plays from the self-contained copy.
            guard let zones = tracks[t].instrument?.sampler?.zones else { continue }
            for z in zones.indices {
                guard let ref = plan.refs[zones[z].id] ?? nil,
                      ref.hasPrefix("media/") else { continue }
                let newURL = mediaDir.appendingPathComponent(String(ref.dropFirst("media/".count)))
                if tracks[t].instrument?.sampler?.zones[z].audioFileURL.path != newURL.path {
                    tracks[t].instrument?.sampler?.zones[z].audioFileURL = newURL
                    anyURLChanged = true
                }
            }
        }
        if anyURLChanged { engine?.tracksDidChange(tracks) }

        isDirty = false
        // A titled save supersedes any untitled-recovery bundle.
        deleteRecoveryBundle()
        // A manual save also supersedes the crash-recovery snapshot (crash-b): the
        // work is now on disk where the user put it — never resurrect it as "unsaved".
        invalidateCrashRecovery()

        return ProjectSaveResult(
            path: bundleURL.path,
            mediaFilesCopied: plan.copies.count,
            warnings: plan.warnings + stateWarnings
        )
    }

    /// Soft cap on inlined Audio Unit state (8 MiB): larger states still save,
    /// with a size warning in the save result.
    static let audioUnitStateSoftCapBytes = 8 * 1024 * 1024

    /// A LOCAL COPY of `tracks` with each `.audioUnit` descriptor's
    /// `stateData` refreshed from `instrumentStateProvider` (when wired and
    /// when it has state for the track). The live model is never mutated.
    private func tracksWithCapturedAudioUnitState() -> [Track] {
        var copy = tracks
        if let provider = instrumentStateProvider {
            for index in copy.indices {
                guard copy[index].kind == .instrument,
                      var descriptor = copy[index].instrument,
                      descriptor.kind == .audioUnit,
                      descriptor.audioUnit != nil,
                      let fresh = provider(copy[index].id) else { continue }
                descriptor.audioUnit?.stateData = fresh
                copy[index].instrument = descriptor
            }
        }
        // Insert-effect AU state joins the save the same way (M4 v), keyed
        // by effect id.
        if let effectProvider = effectStateProvider {
            for index in copy.indices {
                for effectIndex in copy[index].effects.indices {
                    guard copy[index].effects[effectIndex].kind == .audioUnit,
                          copy[index].effects[effectIndex].audioUnit != nil,
                          let fresh = effectProvider(copy[index].effects[effectIndex].id)
                    else { continue }
                    copy[index].effects[effectIndex].audioUnit?.stateData = fresh
                }
            }
        }
        return copy
    }

    /// Opens a `.dawproj` bundle, replacing the current session. Refused while
    /// recording. The bundle is read, version-checked, and decoded BEFORE any
    /// mutation; then unsaved edits are flushed (unless `discardChanges`),
    /// playback is stopped, and state is swapped atomically. Returns any media
    /// warnings (missing/invalid references — the clips are kept regardless).
    @discardableResult
    public func openProject(at path: String, discardChanges: Bool = false) throws -> [String] {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot open a project while recording — stop first")
        }
        let bundleURL = ProjectBundle.normalizedBundleURL(fromPath: path)
        // Read/validate/decode first — a bad bundle changes nothing.
        let document = try ProjectBundle.read(from: bundleURL)
        // Flush can throw .unsavedChanges; it too changes nothing on failure.
        if !discardChanges { try flushForTransition() }
        if transport.isPlaying { stop() }
        return applyOpenedState(document, bundleURL: bundleURL)
    }

    /// Starts a fresh, empty, untitled session ("Untitled Session", no tracks,
    /// default transport, unity master, no path, clean). Refused while
    /// recording. Flushes unsaved edits first (unless `discardChanges`).
    public func newProject(discardChanges: Bool = false) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot start a new project while recording — stop first")
        }
        if !discardChanges { try flushForTransition() }
        if transport.isPlaying { stop() }

        projectName = "Untitled Session"
        tracks = []
        transport = TransportState()
        masterVolume = 1
        grooveTemplates = []
        markers = []
        masterMeter = .silence
        trackMeters = [:]
        lastRecordingError = nil
        // Stale pending fixes point into the old project (M6 v-b).
        pendingClipFixes = [:]
        resetRecordingScratch()
        // A new session starts with empty history; prior edits no longer apply.
        journal.clear()

        engine?.tracksDidChange(tracks)
        engine?.masterVolumeChanged(masterVolume)
        engine?.loopChanged(transport)

        projectPath = nil
        isDirty = false
        // A deliberate new session supersedes any crash-recovery snapshot (crash-b).
        invalidateCrashRecovery()
    }

    /// The single state-swap primitive shared by open. Rebuilds runtime state
    /// from `document`, resets transient state and recording scratch, notifies
    /// the engine, and adopts the bundle identity. `selectedInputDeviceUID` is
    /// left untouched (it's a hardware preference, not session content).
    @discardableResult
    private func applyOpenedState(_ document: ProjectDocument, bundleURL: URL) -> [String] {
        let runtime = document.runtimeState(bundleURL: bundleURL)
        // Bundle basename is authoritative for the name (a renamed bundle wins
        // over the stored name).
        projectName = bundleURL.deletingPathExtension().lastPathComponent
        tracks = runtime.tracks
        transport = runtime.transport
        masterVolume = runtime.masterVolume
        // Groove palette (M5 iii-g) restores directly — no media to resolve.
        grooveTemplates = document.grooveTemplates ?? []
        // Markers (m11-c) restore directly — no media; re-sort so a hand-edited
        // (unsorted) file still lands beat-sorted (the store's invariant).
        markers = Self.markersSortedByBeat(document.markers ?? [])

        masterMeter = .silence
        trackMeters = [:]
        lastRecordingError = nil
        // Stale pending fixes point into the previous project (M6 v-b).
        pendingClipFixes = [:]
        resetRecordingScratch()
        // History belongs to the previous session — the newly loaded one starts
        // fresh (undo must never reach across a load boundary).
        journal.clear()

        engine?.tracksDidChange(tracks)
        engine?.masterVolumeChanged(masterVolume)
        engine?.loopChanged(transport)

        projectPath = bundleURL.path
        isDirty = false
        // Opening another project supersedes any crash-recovery snapshot (crash-b).
        invalidateCrashRecovery()
        return runtime.warnings
    }

    /// Flushes unsaved edits before an open/new. Titled → save in place;
    /// untitled → write a recovery bundle. Any failure is wrapped as
    /// `.unsavedChanges` so the transition aborts with nothing changed.
    private func flushForTransition() throws {
        guard isDirty else { return }
        do {
            if projectPath != nil {
                try saveProject(to: nil)
            } else {
                try writeRecoveryBundle()
            }
        } catch {
            throw ProjectError.unsavedChanges(Self.reason(error))
        }
    }

    // MARK: - Autosave

    /// Starts the background autosave loop (idempotent). The app calls this at
    /// launch; tests drive `autosaveIfNeeded()` directly instead.
    public func startAutosave(interval: Duration = .seconds(30)) {
        guard autosaveTask == nil else { return }
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.autosaveIfNeeded()
            }
        }
    }

    /// Stops the autosave loop.
    public func stopAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// One synchronous autosave tick. Saves only when there are unsaved edits
    /// and the transport isn't recording. A titled session saves in place
    /// (clearing dirty, deleting the recovery bundle); an untitled session
    /// writes a JSON-only recovery bundle and STAYS dirty (projectPath
    /// untouched). Failures log to stderr and keep the session dirty so the next
    /// tick retries.
    func autosaveIfNeeded() {
        guard isDirty, !transport.isRecording else { return }
        do {
            if projectPath != nil {
                try saveProject(to: nil)
            } else {
                try writeRecoveryBundle()
            }
        } catch {
            FileHandle.standardError.write(Data("autosave failed: \(Self.reason(error))\n".utf8))
        }
    }

    /// Writes an untitled-recovery bundle: JSON only, ABSOLUTE media paths, zero
    /// copies, no URL rewrite. `projectPath`/`isDirty` are left untouched — this
    /// is a crash-safety snapshot, not a real save.
    private func writeRecoveryBundle() throws {
        try ProjectBundle.write(
            document: buildAutosaveDocument(),
            plan: ProjectBundle.MediaPlan(copies: [], refs: [:], warnings: []),
            to: recoveryBundleURL
        )
    }

    /// Builds a self-contained-but-uncopied snapshot document: the SAME save-time
    /// Audio Unit state capture as a titled save (local copy only, no model
    /// mutation), with every clip / sampler-zone media reference recorded as an
    /// ABSOLUTE path so re-opening resolves media from the originals. Shared by the
    /// legacy untitled-recovery bundle and the crash-recovery autosave (crash-b) —
    /// one serialization path, verbatim to the existing on-disk format.
    func buildAutosaveDocument() -> ProjectDocument {
        let persistedTracks = tracksWithCapturedAudioUnitState()
        var refs: [UUID: String?] = [:]
        for track in persistedTracks {
            for clip in track.clips {
                refs[clip.id] = clip.audioFileURL.map { $0.standardizedFileURL.path } ?? String?.none
            }
            // Sampler zones record ABSOLUTE source paths too, so a recovered
            // session still resolves its zones from the originals.
            for zone in track.instrument?.sampler?.zones ?? [] {
                refs[zone.id] = zone.audioFileURL.standardizedFileURL.path
            }
        }
        return ProjectDocument(
            name: projectName,
            transport: transport,
            tracks: persistedTracks,
            masterVolume: masterVolume,
            mediaRefs: refs,
            grooveTemplates: grooveTemplates,
            markers: markers
        )
    }

    // MARK: - Crash-recovery autosave (M9 crash-b)

    /// The single crash-recovery autosave tick — the app drives it on a 30-s timer;
    /// tests call it directly. No-op unless the session is DIRTY, not recording, and
    /// a NEW journaled edit has landed since the last snapshot (so a quiet tick
    /// rewrites nothing — "2 ticks = 1 file"). Snapshots the CURRENT project to the
    /// rolling `autosave.dawproject` + `manifest.json`, preserving `projectPath` as
    /// the manifest `sourcePath`. Never clears `isDirty` and never touches the
    /// user's file — this is a crash snapshot, not a save. The file write runs off
    /// the main actor inside the manager, so this adds no edit-path latency.
    public func autosaveTick() async {
        guard isDirty, !transport.isRecording else { return }
        // An unresolved crash-recovery offer parks the writer: the rolling
        // snapshot is the crashed session's ONLY copy, and wire edits bypass the
        // launch sheet — overwriting it before the offer is accepted/declined
        // would silently destroy that work. Resolving the offer (recover,
        // discard, or a manual save/new/open) clears it and ticks resume.
        guard !crashRecovery.recoveryStatus().available else { return }
        let seq = lastEditEvent?.seq ?? 0
        guard seq != crashRecovery.lastAutosavedEditSeq else { return }
        await crashRecovery.recordAutosave(
            document: buildAutosaveDocument(), sourcePath: projectPath, editSeq: seq)
    }

    /// Background 30-s crash-recovery autosave loop (idempotent). The app calls
    /// this at launch; tests drive `autosaveTick()` directly instead. Mirrors
    /// `startAutosave`, but drives the rolling `autosave.dawproject` snapshot.
    public func startCrashAutosave(interval: Duration = .seconds(30)) {
        guard crashAutosaveTask == nil else { return }
        crashAutosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.autosaveTick()
            }
        }
    }

    /// Stops the crash-recovery autosave loop.
    public func stopCrashAutosave() {
        crashAutosaveTask?.cancel()
        crashAutosaveTask = nil
    }

    /// The current crash-recovery offer (`project.recoveryStatus`). Headless-safe:
    /// a store that never began a session — or one with no Autosave dir — reports
    /// `.unavailable`, so no false offer ever surfaces.
    public func recoveryStatus() -> AutosaveRecoveryStatus {
        crashRecovery.recoveryStatus()
    }

    // MARK: - Diagnostics / beta feedback bundle (M9 beta)

    /// Writes ONE local diagnostics bundle (`app.feedbackBundle`) and returns its
    /// summary. Gathers the pieces a beta bug report needs and hands them to the
    /// engine-free `DiagnosticsReporter`: host facts (`DiagnosticsHostInfo.current`
    /// — app/OS/build, NO key material), the CURRENT engine watchdog + performance
    /// snapshots (the M9 telemetry payoff — `.idle` when headless), and the
    /// counts-only `overview()` projection (the privacy-lean default). The full
    /// project snapshot is included ONLY when `includeProject` is true, via the
    /// SAME `buildAutosaveDocument()` serialization the crash-recovery autosave
    /// uses (absolute media refs, zero copies, no model mutation). Everything is
    /// LOCAL — nothing phones home. Throws `DiagnosticsError.writeFailed` on a real
    /// filesystem failure.
    public func writeFeedbackBundle(includeProject: Bool) throws -> FeedbackBundleSummary {
        try diagnostics.writeBundle(
            host: .current(),
            engine: EngineDiagnostics(watchdog: watchdogStatus(), performance: performanceStats()),
            overview: overview(),
            projectDocument: includeProject ? buildAutosaveDocument() : nil
        )
    }

    /// The outcome of a `recoverFromAutosave` call — `.recovered` carries the load
    /// warnings (media resolution), `.discarded` means the offer was dropped.
    public enum RecoveryOutcome: Sendable, Equatable {
        case recovered(warnings: [String])
        case discarded
    }

    /// Acts on the crash-recovery offer (`project.recover`).
    ///  - `accept: false` → drop the autosave + manifest, clear the offer, return
    ///    `.discarded`. The live session is untouched (falls through to whatever
    ///    the launch would otherwise show).
    ///  - `accept: true` → load the autosave INTO this store: the project becomes
    ///    the recovered content, kept DIRTY (it is unsaved work), with `projectPath`
    ///    restored from the manifest so a later save lands on the right file. Then
    ///    the autosave is invalidated. Throws `.noRecoveryAvailable` when nothing is
    ///    on offer.
    @discardableResult
    public func recoverFromAutosave(accept: Bool) throws -> RecoveryOutcome {
        guard accept else {
            invalidateCrashRecovery()
            return .discarded
        }
        guard crashRecovery.recoveryStatus().available else {
            throw ProjectError.noRecoveryAvailable
        }
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot recover a project while recording — stop first")
        }
        let (document, sourcePath) = try crashRecovery.readRecoveredDocument()
        if transport.isPlaying { stop() }
        let warnings = applyRecoveredState(document, sourcePath: sourcePath)
        invalidateCrashRecovery()
        return .recovered(warnings: warnings)
    }

    /// Swaps the recovered snapshot in as the live session. Mirrors
    /// `applyOpenedState`, but (1) keeps the document's OWN `name` (the autosave
    /// bundle is literally named "autosave" — its basename must not leak in), (2)
    /// restores `projectPath` from the manifest's `sourcePath` (nil ⇒ untitled),
    /// and (3) leaves the session DIRTY — recovered content is unsaved by
    /// definition, so the next autosave/tick keeps protecting it.
    @discardableResult
    private func applyRecoveredState(_ document: ProjectDocument, sourcePath: String?) -> [String] {
        // Absolute media refs resolve without a bundle root, but pass the autosave
        // bundle URL so any stray relative ref still resolves (belt-and-suspenders).
        let runtime = document.runtimeState(bundleURL: crashRecovery.autosaveBundleURL)
        projectName = document.name
        tracks = runtime.tracks
        transport = runtime.transport
        masterVolume = runtime.masterVolume
        grooveTemplates = document.grooveTemplates ?? []
        markers = Self.markersSortedByBeat(document.markers ?? [])

        masterMeter = .silence
        trackMeters = [:]
        lastRecordingError = nil
        pendingClipFixes = [:]
        resetRecordingScratch()
        journal.clear()

        engine?.tracksDidChange(tracks)
        engine?.masterVolumeChanged(masterVolume)
        engine?.loopChanged(transport)

        projectPath = sourcePath
        isDirty = true
        return runtime.warnings
    }

    /// Launch-time crash detection: latches whether the prior session left its lock
    /// (a crash / SIGKILL) and writes this session's lock. Returns whether a crash
    /// was detected. The app calls this at startup; the recovery offer then gates on
    /// `recoveryStatus().available`.
    @discardableResult
    public func beginCrashDetection() -> Bool {
        let crashed = crashRecovery.beginSession()
        // The single legitimate arm point for `recoveryOfferAvailable` (m10-s):
        // `recoveryStatus()` also confirms a readable manifest+bundle, so a bare
        // lock never over-arms and this stays false when there is nothing to offer.
        recoveryOfferAvailable = crashRecovery.recoveryStatus().available
        return crashed
    }

    /// Drops the rolling crash-recovery snapshot AND lowers the observable offer
    /// flag together (m10-s). Every `crashRecovery.invalidate()` site — the
    /// `recoverFromAutosave` accept/discard branches and the save/new/open
    /// transitions that supersede a snapshot — routes through here so
    /// `recoveryOfferAvailable` can never drift out of lockstep with the on-disk
    /// availability. The flag never re-arms outside `beginCrashDetection`, so once
    /// this lowers it a later autosave can't resurrect the offer.
    private func invalidateCrashRecovery() {
        crashRecovery.invalidate()
        recoveryOfferAvailable = false
    }

    /// Clean-exit path: removes this session's lock so the next launch sees no
    /// crash. The app calls this from `applicationWillTerminate`.
    public func endCrashDetection() {
        crashRecovery.endSession()
    }

    /// The crash-detection lock file URL. Exposed as a `Sendable` `URL` so the
    /// app's `willTerminate` observer can delete the lock on a clean exit without
    /// capturing the (non-Sendable, main-actor) store across the notification's
    /// `@Sendable` boundary.
    public var crashLockURL: URL { crashRecovery.lockURL }

    /// This store's untitled-recovery bundle location:
    /// `<autosaveRecoveryDirectory>/Untitled-<slug8>.dawproj`.
    private var recoveryBundleURL: URL {
        autosaveRecoveryDirectory
            .appendingPathComponent("Untitled-\(recoverySlug).dawproj", isDirectory: true)
    }

    /// Best-effort removal of the recovery bundle once a titled save lands.
    private func deleteRecoveryBundle() {
        try? FileManager.default.removeItem(at: recoveryBundleURL)
    }

    /// Launch-time hygiene for untitled-recovery bundles. `flushForTransition()`
    /// writes one `Untitled-<slug>.dawproj` per dirty untitled session abandoned
    /// via new/open, and `deleteRecoveryBundle()` only ever removes THIS store's
    /// slug — so orphans from past sessions accumulate without bound. Keeps the
    /// `keep` newest (by modification date) as a manual-recovery grace window and
    /// removes the rest, never touching this session's own bundle or any
    /// non-matching file. Returns the number removed.
    @discardableResult
    public func pruneUntitledRecoveryBundles(keep: Int = 5) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: autosaveRecoveryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }
        let bundles = entries
            .filter {
                $0.lastPathComponent.hasPrefix("Untitled-")
                    && $0.pathExtension == "dawproj"
            }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return da > db
            }
        var removed = 0
        for url in bundles.dropFirst(max(0, keep))
        where url.lastPathComponent != recoveryBundleURL.lastPathComponent {
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                // Best-effort: a bundle held open elsewhere just survives this pass.
            }
        }
        return removed
    }

    /// Default autosave/recovery directory:
    /// `~/Library/Application Support/DAWPro/Autosave/`.
    static func defaultAutosaveDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("Autosave", isDirectory: true)
    }

    /// Default home for imported generated audio (M6 iii-a). Sibling of the
    /// recordings scratch under Application Support so it persists across the
    /// volatile sidecar temp cache and undo/redo resurrection.
    static func defaultGenerationImportsDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("Generations", isDirectory: true)
    }

    /// Readable reason from any error (LocalizedError message when present).
    private static func reason(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Snapshot

    public func snapshot() -> ProjectSnapshot {
        ProjectSnapshot(
            name: projectName,
            transport: transport,
            tracks: tracks.map(Self.snapshotResolved),
            masterVolume: masterVolume,
            grooveTemplates: grooveTemplates,
            markers: markers,
            meters: SessionMeters(
                master: masterMeter,
                tracks: Dictionary(uniqueKeysWithValues: trackMeters.map { ($0.key.uuidString, $0.value) })
            ),
            lastRecordingError: lastRecordingError,
            selectedInputDeviceUID: selectedInputDeviceUID,
            projectPath: projectPath,
            isDirty: isDirty,
            undoLabel: journal.undoLabel,
            redoLabel: journal.redoLabel,
            midiInputs: engine?.availableMIDIInputs(),
            midiEventCount: engine?.midiEventCount()
        )
    }

    /// Normalizes a track for the wire snapshot so clients never have to resolve
    /// `nil ⇒ default` themselves: an INSTRUMENT track always carries a resolved
    /// `instrument` object (default when unset), while an audio or bus track
    /// drops the field entirely (the synthesized `Track` encoder omits a nil
    /// optional). Snapshot-only — the live `tracks` model keeps `nil` to mean
    /// "default" and to let legacy projects round-trip unchanged.
    private static func snapshotResolved(_ track: Track) -> Track {
        var resolved = track
        resolved.instrument = track.kind == .instrument
            ? (track.instrument ?? .default)
            : nil
        return resolved
    }

    // MARK: - Position ticker (no-engine fallback only)

    /// Advances the playhead at ~30 Hz when NO engine is injected (headless
    /// tests). With an engine attached this never runs — the engine pushes
    /// render-derived beats through `playheadHandler`, which is the source of
    /// truth for `transport.positionBeats` during playback.
    private func startPositionTicker() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, self.transport.isPlaying else { break }
                let now = ContinuousClock.now
                let elapsed = last.duration(to: now)
                last = now
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                // Inverse integral from the current position (m12-b, design
                // row 19) — advances correctly across future map boundaries.
                self.transport.positionBeats = self.transport.tempoMap.beat(
                    from: self.transport.positionBeats, elapsedSeconds: seconds)
            }
        }
    }
}
