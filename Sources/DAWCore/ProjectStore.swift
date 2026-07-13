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
    /// The MASTER insert chain (m13-d): project-level effects processing the
    /// whole mix, post-fader between the main mix and the output
    /// (design-m13d §1-B — the C0 verdict). Built-in kinds only in v1
    /// (design D4a: `.audioUnit` is rejected at add and sanitized on load);
    /// a master effect can never carry `sidechainSourceTrackID` (no store
    /// path sets one — `setSidechain` addresses tracks only — and load
    /// sanitization clears strays). Rides `EditState` (undo covers every
    /// mutation) and persists additively, omit-when-empty.
    public private(set) var masterEffects: [EffectDescriptor] = []
    /// MASTER volume automation (m15-c, the M4 vii-f "master lanes" slice):
    /// project-level `AutomationLane`s whose owner is the MASTER, not a track —
    /// at most ONE lane, target `.volume` (every other target is rejected with
    /// `masterAutomationVolumeOnly`; load sanitizes strays). The lane REPLACES
    /// the manual `masterVolume` fader while active (the vii-b override rule,
    /// applied by the engine at the same graph point `setMasterVolume` drives).
    /// Rides `EditState` (undo covers every mutation) and persists additively,
    /// omit-when-empty — the `masterEffects` triple-mirror discipline (store +
    /// snapshot + disk DTO, m12-f).
    public private(set) var masterAutomation: [AutomationLane] = []
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
    /// Monotonic tempo/meter-map revision (m12-d, design row 29). Bumped on
    /// EVERY mutation that changes the effective tempo or meter map — scalar
    /// `setTempo`, `tempo.setMap`, and an undo/redo that swaps the map — and
    /// NEVER decremented, so an in-flight Clip-Fix job that froze an earlier
    /// revision always detects the change (the freeze/compare is one integer,
    /// not a whole-map equality). Deliberately NOT part of `EditState`: undo
    /// restores the map but the revision keeps climbing (staleness is about
    /// "did anything change", not "what is the map now"). Persisted additively
    /// (ProjectDocument.tempoMapRevision) ONLY alongside a non-trivial map, so a
    /// reopened project resumes its count and a trivial project stays
    /// byte-identical.
    public private(set) var mapRevision: UInt64 = 0
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
            // Schedule-time degradations land in the store's coalescing ring
            // (m15-e) — the one source of truth the wire snapshot and the UI
            // chip both read. Always pushed on the main actor.
            engine?.engineNoticeHandler = { [weak self] event in
                self?.recordEngineNotice(event)
            }
        }
    }

    // MARK: Engine notices (m15-e)

    /// Bounded ring of schedule-time degradations, COALESCED BY CODE (a
    /// repeat of an existing code increments its `count` and refreshes
    /// `message`/`beat`/`lastAt`; distinct codes append in first-post order).
    /// Session-transient DIAGNOSTICS, not project state: never persisted to
    /// disk, never journaled — undo/redo deliberately leaves the ring alone
    /// (reverting an edit does not un-happen a degraded playback pass).
    /// Cleared on `project.new`/`project.open`/`project.recover` (every
    /// session replacement — m16-c extended the clear law to recover).
    /// Surfaced on `project.snapshot` as `engineNotices` (key omitted while
    /// empty).
    public private(set) var engineNotices: [EngineNotice] = []

    /// Ring bound: at most this many DISTINCT codes are retained (16 — the
    /// engine currently posts 6 codes, so the cap is generous headroom, and
    /// the popover list stays readable). Overflow evicts the STALEST entry
    /// (smallest `lastAt` — the least-recently-posted code), keeping live
    /// problems visible.
    public static let engineNoticeCap = 16

    /// Session-monotonic post sequence backing `EngineNotice.lastAt`
    /// (deterministic — see that field's doc). Resets with the ring.
    private var engineNoticeSequence = 0

    /// The single ring mutation funnel — installed as the engine's
    /// `engineNoticeHandler` when an engine is attached.
    private func recordEngineNotice(_ event: EngineNoticeEvent) {
        engineNoticeSequence += 1
        if let index = engineNotices.firstIndex(where: { $0.code == event.code }) {
            engineNotices[index].count += 1
            engineNotices[index].message = event.message
            engineNotices[index].beat = event.beat
            engineNotices[index].lastAt = engineNoticeSequence
            return
        }
        engineNotices.append(EngineNotice(
            code: event.code, message: event.message, beat: event.beat,
            count: 1, lastAt: engineNoticeSequence))
        if engineNotices.count > Self.engineNoticeCap,
           let stalest = engineNotices.indices.min(by: {
               engineNotices[$0].lastAt < engineNotices[$1].lastAt
           }) {
            engineNotices.remove(at: stalest)
        }
    }

    /// m16-c (audit F2): the open/recover missing-media ECHO — every audio
    /// clip whose resolved media file is absent on disk lands in the notices
    /// ring AT OPEN TIME, so an agent polling `project.snapshot` after an
    /// open/recover sees the same facts the open response's `warnings` carry
    /// without replaying that response. Derived from the freshly loaded MODEL
    /// (one `fileExists` per audio clip), not by parsing warning strings —
    /// same facts plus an honest beat, and it also covers absolute-ref
    /// recovery bundles, which `ProjectDocument.resolveMedia` deliberately
    /// accepts WITHOUT a warning (the audit-m16 §2-B3 recipe is exactly this
    /// case). Posts the SAME `clip-file-missing` code as the graph's
    /// build-time open catch, so open-time and play-time detections of one
    /// missing file coalesce into a single ring entry. Ordering law (m15-e):
    /// callers clear the ring FIRST (session replacement), then this echo
    /// posts the NEW session's facts. Control-plane, main-actor only — zero
    /// render-thread surface.
    private func echoMissingMediaNotices() {
        for track in tracks {
            for clip in track.clips {
                guard let url = clip.audioFileURL,
                      !FileManager.default.fileExists(atPath: url.path) else { continue }
                recordEngineNotice(EngineNoticeEvent(
                    code: "clip-file-missing",
                    message: "'\(clip.name)' will be silent — its audio file is missing (\(url.path)). Restore or re-link the file to hear this clip.",
                    beat: clip.startBeat))
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
        /// Loop-cycle take window frozen at record start (m15-b, design-m15b
        /// §3/§4): non-nil exactly when the loop was enabled at `record()` —
        /// the take then rolled with the playback loop live (the engine
        /// schedules WITH the window after the seek to the loop start) and
        /// `finishTake` slices the ONE linear capture into per-cycle lanes.
        /// nil = today's linear take, landed verbatim. `transport.setLoop`
        /// refuses mid-record, so the freeze is exact like the map's.
        let loop: LoopTakeWindow?
    }

    /// The frozen loop window of a loop-cycle take (m15-b). `cycleSeconds` is
    /// the SAME map integral the engine's `LoopContext` computes
    /// (`tempoMap.seconds(from:to:)` over the window) — store-side slicing
    /// and engine-side wrapping share one timeline by construction.
    private struct LoopTakeWindow {
        let startBeat: Double
        let endBeat: Double
        let cycleSeconds: Double
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

    /// Sets a single project-wide tempo — the single-segment FAST PATH (m12-d,
    /// design §3.6). Refused while recording, and refused with guidance on a
    /// project that carries a MULTI-SEGMENT tempo map (silently flattening an
    /// authored map is a destructive surprise; the error names `tempo.setMap`).
    /// On a trivial project it behaves byte-identically to the scalar era.
    public func setTempo(_ bpm: Double) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot change tempo while recording — stop first")
        }
        guard transport.tempoMapOverride == nil else {
            throw ProjectError.tempoMapMultiSegment
        }
        performEdit("Set Tempo", key: "transport.tempo") {
            applyTempoChange(bpm)
        }
    }

    /// Replaces the whole tempo map (m12-d, design §3.6) — the full-set,
    /// idempotent, agent-friendly shape (the `take.setComp` precedent). ONE
    /// `performEdit` with the `tempo.map` coalescing key, so a UI tempo-lane
    /// drag folds into a single undo step. `meterMap == nil` leaves the current
    /// meter map untouched (the wire's optional `meterChanges`). Refused while
    /// recording (MIDI capture / take fan-out assume a fixed tempo per take).
    /// Maps arrive already validated (built through their throwing initializers
    /// at the wire/UI boundary). A single-segment map collapses to the scalar
    /// fast path (override cleared) so a trivial project stays byte-identical on
    /// disk and in snapshots.
    public func setTempoMap(_ tempoMap: TempoMap, meterMap: MeterMap? = nil) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot change the tempo map while recording — stop first")
        }
        performEdit("Change Tempo Map", key: "tempo.map") {
            applyTempoMap(tempoMap, meterMap: meterMap)
        }
    }

    /// Sets the transport tempo (clamped), pushes it to the engine, re-flattens
    /// every take group — members were windowed at the previous tempo (their
    /// source offsets are tempo-derived), so this keeps them coherent — and
    /// bumps `mapRevision` when the tempo actually moved (Clip-Fix staleness).
    /// Does NOT open its own `performEdit`: `setTempo` wraps it in one, and
    /// `importGeneration` (M6 iii-a) folds it into the SAME "Import Generation"
    /// edit so a single undo restores the tempo with the track. Kept here (not
    /// an extension) because `transport` has a private setter. m12-d: still the
    /// scalar segment-0 entry point (`importGeneration` bypasses `setTempo`'s
    /// multi-segment guard by design — tempo adoption is an internal fold); the
    /// re-flatten hook flattens through `transport.tempoMap`.
    func applyTempoChange(_ bpm: Double) {
        let previousMap = transport.tempoMap
        transport.tempoBPM = bpm.clamped(to: TransportState.tempoRange)
        if transport.tempoMap != previousMap { mapRevision &+= 1 }
        engine?.setTempo(transport)
        for t in tracks.indices {
            for g in tracks[t].takeGroups.indices {
                rebuildCompMembers(trackIndex: t, groupIndex: g)
            }
        }
    }

    /// The map-mutation core (m12-d). Normalizes the incoming maps onto the
    /// (scalar tempoBPM/timeSignature + optional override) representation so a
    /// trivial map never persists a key, keeps `tempoBPM`/`timeSignature` ==
    /// segment/change 0, bumps `mapRevision` on any effective change, pushes the
    /// tempo change through the SAME `engine.setTempo` restart seam a scalar
    /// change uses (mid-play the engine re-anchors from its OWN derived beats
    /// under the new map), and re-flattens take groups. Does NOT open its own
    /// `performEdit` — `setTempoMap` wraps it. Meter never enters engine
    /// TIMING math (design §3.2), but since m15-a it IS the live click
    /// scheduler's downbeat source, so a meter-only change refreshes the
    /// click run through the click-player-local `metronomeChanged` intent —
    /// clip players and the transport are never touched. A tempo change needs
    /// no extra push: `setTempo`'s restart re-caches and reschedules clicks.
    func applyTempoMap(_ tempoMap: TempoMap, meterMap newMeterMap: MeterMap?) {
        let previousTempoMap = transport.tempoMap
        let previousMeterMap = transport.meterMap
        // Tempo: a single-segment map collapses to the scalar fast path.
        if tempoMap.segments.count == 1 {
            transport.tempoBPM = tempoMap.segments[0].bpm
            transport.tempoMapOverride = nil
        } else {
            transport.tempoBPM = tempoMap.segments[0].bpm
            transport.tempoMapOverride = tempoMap
        }
        // Meter (optional): a single change at beat 0 collapses to the scalar.
        if let newMeterMap {
            let change0 = newMeterMap.changes[0]
            transport.timeSignature = TimeSignature(
                beatsPerBar: change0.beatsPerBar, beatUnit: change0.beatUnit)
            transport.meterMapOverride = newMeterMap.changes.count == 1 ? nil : newMeterMap
        }
        if transport.tempoMap != previousTempoMap || transport.meterMap != previousMeterMap {
            mapRevision &+= 1
        }
        if transport.tempoMap != previousTempoMap {
            engine?.setTempo(transport)
        } else if transport.meterMap != previousMeterMap {
            // m15-a: meter-only change — refresh the click schedule (stopped
            // transport ⇒ the intent is cache-only; state is read at the
            // next start).
            engine?.metronomeChanged(transport)
        }
        for t in tracks.indices {
            for g in tracks[t].takeGroups.indices {
                rebuildCompMembers(trackIndex: t, groupIndex: g)
            }
        }
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
    ///
    /// LOOP-CYCLE TAKES (m15-b, design-m15b-loop-record): with the loop
    /// enabled, record seeks to the loop start, playback wraps gaplessly for
    /// real (no silent linear roll), and stop lands ONE take group with one
    /// lane per loop pass — newest lane comped, mid-cycle stop = an honest
    /// partial last lane. Loop state alone decides (no flag); loop × punch
    /// and sub-1-second cycles refuse with teaching errors; the loop region
    /// itself is frozen for the take (`setLoop` refuses mid-record).
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
        // Loop-cycle take shape gates (m15-b, design-m15b §6) — checked before
        // the audio gates so the transport-shape teaching errors come first.
        // With a loop enabled, record ALWAYS loop-records (seek to the loop
        // start, wrap live, land per-cycle lanes) or refuses — never a silent
        // linear roll (the audit-m15 B2 dishonesty).
        var loopWindow: LoopTakeWindow?
        if transport.isLoopEnabled {
            // (i) Punch × loop is refused in v1: the writer's accept window is
            // single-window machinery; per-cycle punch would be new capture
            // machinery for a rare combination (design-m15b §7).
            guard !transport.isPunchEnabled else {
                throw recordFailure(.invalidPunchRange(
                    "recording with both a loop and a punch window is not supported — disable one: loop-cycle takes (transport.setLoop) or punch (transport.setPunch)"
                ))
            }
            // (ii) Cycle floor: the SAME integral the engine's LoopContext
            // computes — store and engine eligibility agree by construction.
            let cycleSeconds = transport.tempoMap.seconds(
                from: transport.loopStartBeat, to: transport.loopEndBeat)
            guard cycleSeconds >= TakeGroup.minLoopRecordCycleSeconds else {
                throw recordFailure(.invalidLoopRange(
                    "loop is too short for take recording — use a loop of at least 1 second per cycle"
                ))
            }
            loopWindow = LoopTakeWindow(startBeat: transport.loopStartBeat,
                                        endBeat: transport.loopEndBeat,
                                        cycleSeconds: cycleSeconds)
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

        // The §3 seek (m15-b): a loop record starts AT the loop start — the
        // user framed the loop to record over it (the Logic/Live convention),
        // count-in supplies any pickup, and every cycle boundary becomes the
        // uniform absolute integral k·cycleSeconds. Done after every throwing
        // gate above, so a refused record never moves the playhead. Visible
        // in the transport.record response (`positionBeats == loopStartBeat`).
        if let loopWindow {
            transport.positionBeats = loopWindow.startBeat
        }

        // Snapshot destinations and timing NOW: arm toggles mid-take must not
        // change where the finished take lands.
        let take = takeCounter + 1
        let pending = PendingTake(
            armedTrackIDs: armedAudioIDs,
            armedInstrumentTrackIDs: armedInstrumentIDs,
            recordStartBeats: transport.positionBeats,
            tempoMap: transport.tempoMap,
            takeNumber: take,
            loop: loopWindow
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
            // Loop-cycle take (m15-b): the ONE linear capture slices into
            // per-cycle lanes — the linear path below stays byte-identical
            // for every non-loop take (the G3 era pin).
            if let loop = pending.loop {
                finishLoopTake(take, pending: pending, loop: loop)
                return
            }
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

    /// One landed audio lane of a loop take: timeline geometry plus the read
    /// position into the ONE shared take file (m15-b, design-m15b §4 — all
    /// lanes window the same capture at different offsets).
    private struct LoopAudioSlice {
        let startBeat: Double
        let lengthBeats: Double
        let fileOffsetSeconds: Double
    }

    /// Lands a finished LOOP-CYCLE take (m15-b, design-m15b §4): slice the one
    /// linear capture at the absolute integrals `k·cycleSeconds`, fan the audio
    /// slices through `autoGroupRecordedTake` IN CYCLE ORDER (slice 1 lands
    /// plain or joins existing material, slice 2 forms the group, 3..N append
    /// lanes — final comp = newest lane), and land MIDI cycle lanes through the
    /// explicit MIDI lander. Everything inside ONE
    /// `performEdit("Record Take N")`. A take that never reached cycle 2
    /// degrades to EXACTLY the linear landing (same formulas, same names).
    private func finishLoopTake(_ take: TakeResult, pending: PendingTake, loop: LoopTakeWindow) {
        let map = pending.tempoMap
        let L = loop.cycleSeconds

        // ---- Audio: slice the file's elapsed cover [lag, lag + D) at the
        // cycle boundaries. THE INTEGRAL LAW (m12-c / G1): every boundary is
        // the absolute integral (k − 1)·L, never `previous + L`; every map
        // inverse is evaluated INSIDE the loop window (within-cycle seconds
        // < L — the timeline law, segments past the loop end never leak in).
        var audioSlices: [LoopAudioSlice] = []
        if let audio = take.audio, audio.info.durationSeconds > 0 {
            let lag = audio.startOffsetSeconds
            let end = lag + audio.info.durationSeconds
            if end <= L {
                // Stopped inside cycle 1 (N == 1): today's landing formulas
                // VERBATIM — start from the anchor-relative lag, length from
                // the file duration (the two-step inverse integral, not the
                // one-step equivalent, so the arithmetic is bit-identical).
                let startBeat = map.beat(from: loop.startBeat, elapsedSeconds: lag)
                let lengthBeats = map.beat(from: startBeat,
                                           elapsedSeconds: audio.info.durationSeconds) - startBeat
                if lengthBeats > 0 {
                    audioSlices.append(LoopAudioSlice(
                        startBeat: startBeat, lengthBeats: lengthBeats, fileOffsetSeconds: 0))
                }
            } else {
                let cycleCount = Int((end / L).rounded(.up))
                for k in 1...cycleCount {
                    let cycleStart = Double(k - 1) * L   // absolute integral
                    let cycleEnd = Double(k) * L
                    let windowStart = max(lag, cycleStart)
                    let windowEnd = min(end, cycleEnd)
                    guard windowEnd > windowStart else { continue }
                    // Lane k: cycle-relative seconds → beat inside the window;
                    // a full cycle ends AT the loop end exactly (no inverse
                    // round trip); the honest partial last lane inverts only
                    // its remaining seconds.
                    let startBeat = map.beat(from: loop.startBeat,
                                             elapsedSeconds: windowStart - cycleStart)
                    let endBeat = windowEnd == cycleEnd
                        ? loop.endBeat
                        : map.beat(from: loop.startBeat, elapsedSeconds: windowEnd - cycleStart)
                    let lengthBeats = endBeat - startBeat
                    guard lengthBeats > 0 else { continue }
                    audioSlices.append(LoopAudioSlice(
                        startBeat: startBeat, lengthBeats: lengthBeats,
                        fileOffsetSeconds: windowStart - lag))
                }
            }
        }

        // ---- MIDI: slice in the SECONDS domain by EXACT INVERSION of the
        // capture session's linear map conversion (design-m15b §4): the
        // session stamped `beat = map.beat(from: recordStart, elapsed)`, so
        // `elapsed = map.seconds(from: recordStart, to: recordStart + beat)`.
        // A note belongs to its ONSET cycle and clamps at that cycle's end
        // (v1 policy — matches the audio slice exactly at the boundary).
        // Cycle count comes from the engine's LINEAR stop beat
        // (`TakeResult.stopBeats`); the rounded `lengthBeats` is only a
        // legacy fallback (it would fabricate a phantom cycle at a wrap).
        let midiNotes = take.midi?.notes ?? []
        var midiCycles = 1
        var midiLanes: [[MIDINote]] = []
        var midiLaneLengths: [Double] = []
        if let midi = take.midi {
            let stopLinear = take.stopBeats ?? (pending.recordStartBeats + midi.lengthBeats)
            let stopE = max(0, map.seconds(from: pending.recordStartBeats,
                                           to: max(pending.recordStartBeats, stopLinear)))
            midiCycles = max(1, Int((stopE / L).rounded(.up)))
            if midiCycles > 1 {
                let cycleBeats = loop.endBeat - loop.startBeat
                midiLanes = Array(repeating: [], count: midiCycles)
                for note in midiNotes {
                    let onE = map.seconds(from: pending.recordStartBeats,
                                          to: pending.recordStartBeats + note.startBeat)
                    let k = min(max(Int((onE / L).rounded(.down)), 0), midiCycles - 1)
                    let withinOn = onE - Double(k) * L          // absolute integral
                    let offE = map.seconds(from: pending.recordStartBeats,
                                           to: pending.recordStartBeats + note.endBeat)
                    let withinOff = min(offE - Double(k) * L, L)  // onset-cycle clamp
                    let onBeat = map.beat(from: loop.startBeat,
                                          elapsedSeconds: withinOn) - loop.startBeat
                    let offBeat = withinOff >= L
                        ? cycleBeats
                        : map.beat(from: loop.startBeat,
                                   elapsedSeconds: withinOff) - loop.startBeat
                    midiLanes[k].append(MIDINote(
                        id: note.id, pitch: note.pitch, velocity: note.velocity,
                        startBeat: onBeat, lengthBeats: offBeat - onBeat))
                }
                midiLanes = midiLanes.map(MIDINote.canonicallyOrdered)
                // Full cycles span the whole window; the last lane is the
                // honest partial when the stop fell mid-cycle. An empty cycle
                // still lands an empty lane (lane index == cycle index).
                midiLaneLengths = (1...midiCycles).map { k in
                    if k < midiCycles || stopE >= Double(midiCycles) * L { return cycleBeats }
                    let remaining = stopE - Double(midiCycles - 1) * L
                    return map.beat(from: loop.startBeat,
                                    elapsedSeconds: remaining) - loop.startBeat
                }
            }
        }

        let audioLands = !audioSlices.isEmpty
        let midiLands = !midiNotes.isEmpty
        guard audioLands || midiLands else {
            // Same discard surface as the linear path: a take with zero notes
            // overall is discarded exactly as today, however many cycles ran.
            lastRecordingError = take.audio == nil && take.midi != nil
                ? "empty take discarded — no MIDI notes received"
                : "empty take discarded"
            return
        }

        performEdit("Record Take \(pending.takeNumber)") {
            if let audio = take.audio, audioLands {
                for trackID in pending.armedTrackIDs {
                    guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { continue }
                    for (i, slice) in audioSlices.enumerated() {
                        // Lane names "<track> Take <n>.<k>"; a single-cycle
                        // take keeps today's "<track> Take <n>".
                        let name = audioSlices.count == 1
                            ? "\(tracks[index].name) Take \(pending.takeNumber)"
                            : "\(tracks[index].name) Take \(pending.takeNumber).\(i + 1)"
                        let newClip = Clip(
                            name: name,
                            startBeat: slice.startBeat,
                            lengthBeats: slice.lengthBeats,
                            audioFileURL: audio.fileURL,
                            isAIGenerated: false,
                            startOffsetSeconds: slice.fileOffsetSeconds
                        )
                        if !autoGroupRecordedTake(trackIndex: index, newClip: newClip) {
                            tracks[index].clips.append(newClip)
                        }
                    }
                }
            }
            if let midi = take.midi, midiLands {
                for trackID in pending.armedInstrumentTrackIDs {
                    guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { continue }
                    if midiCycles == 1 {
                        // Single cycle: today's landing verbatim.
                        tracks[index].clips.append(Clip(
                            name: "\(tracks[index].name) Take \(pending.takeNumber)",
                            startBeat: pending.recordStartBeats,
                            lengthBeats: midi.lengthBeats,
                            notes: midi.notes
                        ))
                    } else {
                        let laneClips = midiLanes.indices.map { k in
                            Clip(
                                name: "\(tracks[index].name) Take \(pending.takeNumber).\(k + 1)",
                                startBeat: loop.startBeat,
                                lengthBeats: midiLaneLengths[k],
                                notes: midiLanes[k]
                            )
                        }
                        landLoopMIDITakeLanes(trackIndex: index, laneClips: laneClips)
                    }
                }
            }
            engine?.tracksDidChange(tracks)
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
    /// Refused mid-record (m15-b, design-m15b §5.2): a rolling take's slicing
    /// window and the engine's scheduled loop are frozen at record start — a
    /// mid-take bounds edit would reach `loopChanged`'s restart and kill the
    /// capture writer's anchor mid-take. This guard is what keeps the old
    /// record-path loop suppression closed for good (the lift ships WITH it).
    public func setLoop(enabled: Bool, startBeat: Double? = nil, endBeat: Double? = nil) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot change the loop while recording — stop first")
        }
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
    /// is already committed. A change while STOPPED simply applies on the
    /// next start (the engine reads metronome state from the TransportState
    /// handed to each start/restart). While PLAYING, `metronomeChanged`
    /// starts/stops the CLICK PLAYER only — gapless live player scheduling
    /// (m14-c L-3, design-m13f-gapless-loop §6): clip playback is
    /// byte-identical through the toggle. The pre-m14-c seek/restart fallback
    /// (and its ~60 ms lead-in seam) is RETIRED — the v0 "gapless click
    /// toggling needs live player scheduling" tradeoff note resolved exactly
    /// as written.
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
                engine?.metronomeChanged(transport)
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

    // MARK: - Master insert chain (m13-d)
    //
    // The track chain verbs mirrored onto the project-level master chain
    // (design-m13d §4). Every method is a CHAIN PUBLISH engine-side — never
    // topology, never announce-capable, LEGAL mid-recording (design D3; the
    // recording guard is deliberately absent, pinned by
    // `legalVerbsRemainUnguarded`). Guards sit OUTSIDE the edit bodies (the
    // track-chain precedent); every mutation pushes
    // `engine?.masterEffectsChanged(_:)` inside its edit body (the
    // `setMasterVolume` shape), and the undo/redo/project-boundary restore
    // funnel pushes the same twin.

    /// Appends (or inserts at `index`) a new effect on the MASTER chain and
    /// returns its descriptor. Built-in kinds only in v1 (design D4a):
    /// `.audioUnit` throws the named teaching error. Shares the track cap —
    /// a full chain (16) throws `chainFull`. `index` clamps into
    /// `[0, chain length]`; nil appends.
    @discardableResult
    public func addMasterEffect(kind: EffectDescriptor.Kind, at index: Int? = nil)
        throws -> EffectDescriptor {
        guard kind != .audioUnit else {
            throw ProjectError.masterChainBuiltInOnly
        }
        guard masterEffects.count < Self.maxEffectsPerChain else {
            throw ProjectError.chainFull(Self.maxEffectsPerChain)
        }
        let effect = EffectDescriptor(kind: kind)
        let count = masterEffects.count
        let insertAt = min(max(0, index ?? count), count)
        performEdit("Add \(Self.effectDisplayName(kind)) to Master") {
            masterEffects.insert(effect, at: min(insertAt, masterEffects.count))
            engine?.masterEffectsChanged(masterEffects)
        }
        return effect
    }

    /// Removes a master effect by id. Unknown effect → `effectNotFound`. A
    /// master removal is NEVER announce-capable (no master effect can carry
    /// a sidechain key — the keyed-removal guard class cannot arise here).
    public func removeMasterEffect(effectID: UUID) throws {
        guard let ei = masterEffects.firstIndex(where: { $0.id == effectID }) else {
            throw ProjectError.effectNotFound(effectID)
        }
        let kind = masterEffects[ei].kind
        performEdit("Remove \(Self.effectDisplayName(kind)) from Master") {
            masterEffects.removeAll { $0.id == effectID }
            engine?.masterEffectsChanged(masterEffects)
        }
    }

    /// Moves a master effect to a new position (final-index semantics,
    /// clamped) — the `reorderEffect` mirror.
    public func reorderMasterEffect(effectID: UUID, toIndex: Int) throws {
        guard masterEffects.contains(where: { $0.id == effectID }) else {
            throw ProjectError.effectNotFound(effectID)
        }
        let dest = min(max(0, toIndex), masterEffects.count - 1)
        performEdit("Reorder Master Effects") {
            guard let from = masterEffects.firstIndex(where: { $0.id == effectID }) else { return }
            let effect = masterEffects.remove(at: from)
            masterEffects.insert(effect, at: min(dest, masterEffects.count))
            engine?.masterEffectsChanged(masterEffects)
        }
    }

    /// Bypasses (or re-enables) one master effect — an atomic flag toggle,
    /// never coalesced (the track-chain rule: a deliberate on/off is its own
    /// undo step).
    public func setMasterEffectBypassed(effectID: UUID, bypassed: Bool) throws {
        guard let ei = masterEffects.firstIndex(where: { $0.id == effectID }) else {
            throw ProjectError.effectNotFound(effectID)
        }
        let kind = masterEffects[ei].kind
        let verb = bypassed ? "Bypass" : "Unbypass"
        performEdit("\(verb) \(Self.effectDisplayName(kind)) on Master") {
            if let ei = masterEffects.firstIndex(where: { $0.id == effectID }) {
                masterEffects[ei].isBypassed = bypassed
            }
            engine?.masterEffectsChanged(masterEffects)
        }
    }

    /// Sets one named parameter on a master effect — `setEffectParam`
    /// verbatim (spec-validated name, silent range clamp), coalescing per
    /// (effect, name) under the track key shape with the master sentinel in
    /// the trackId slot, so a knob scrub is one undo step. Returns the
    /// updated descriptor.
    @discardableResult
    public func setMasterEffectParam(effectID: UUID, name: String, value: Double)
        throws -> EffectDescriptor {
        guard let ei = masterEffects.firstIndex(where: { $0.id == effectID }) else {
            throw ProjectError.effectNotFound(effectID)
        }
        let kind = masterEffects[ei].kind
        let specs = EffectParamSpec.specs(for: kind)
        guard let spec = specs.first(where: { $0.name == name }) else {
            let valid = specs.map(\.name).joined(separator: ", ")
            throw ProjectError.unknownEffectParam(
                "unknown parameter '\(name)' for \(kind.rawValue) effect — valid: \(valid)")
        }
        let clamped = value.clamped(to: spec.range)
        performEdit("Set \(Self.effectDisplayName(kind)) Parameter",
                    key: "fx.param:master:\(effectID.uuidString):\(name)") {
            if let ei = masterEffects.firstIndex(where: { $0.id == effectID }) {
                Self.applyEffectParam(&masterEffects[ei], name: name, value: clamped)
            }
            engine?.masterEffectsChanged(masterEffects)
        }
        return masterEffects[ei]
    }

    // MARK: - Master volume automation (m15-c)
    //
    // The track automation verbs mirrored onto the project-level master
    // (the m13-d master-chain shape): every method is a parameter-plane
    // publish engine-side — never topology, never announce-capable, LEGAL
    // mid-recording (pinned by `legalVerbsRemainUnguarded`; the capture path
    // is a separate input-only engine, so a master fade can never color a
    // take). Guards sit OUTSIDE the edit bodies; every mutation pushes
    // `engine?.masterAutomationChanged(_:)` inside its edit body (the
    // `masterEffectsChanged` shape), and the undo/redo restore funnel pushes
    // the same twin.

    /// Adds — or returns the EXISTING — master automation lane for `target`.
    /// v1 supports `.volume` ONLY (any other target →
    /// `masterAutomationVolumeOnly`, an honest deferral naming where those
    /// lanes live). Idempotent per target, like `addAutomationLane`.
    @discardableResult
    public func addMasterAutomationLane(target: AutomationTarget) throws -> AutomationLane {
        guard target == .volume else {
            throw ProjectError.masterAutomationVolumeOnly
        }
        if let existing = masterAutomation.first(where: { $0.target == target }) {
            return existing
        }
        let lane = AutomationLane(target: target)
        performEdit("Add Master Automation") {
            masterAutomation.append(lane)
            engine?.masterAutomationChanged(masterAutomation)
        }
        return lane
    }

    /// Removes a master automation lane by id. Unknown lane →
    /// `automationLaneNotFound` (reused verbatim — the m13-d rule of reusing
    /// the track-worded error for master ids, like `effectNotFound`).
    public func removeMasterAutomationLane(laneID: UUID) throws {
        guard masterAutomation.contains(where: { $0.id == laneID }) else {
            throw ProjectError.automationLaneNotFound(laneID)
        }
        performEdit("Remove Master Automation") {
            masterAutomation.removeAll { $0.id == laneID }
            engine?.masterAutomationChanged(masterAutomation)
        }
    }

    /// Replaces a master lane's breakpoints WHOLESALE — `setAutomationPoints`
    /// verbatim: every value clamps to `Track.volumeRange` (the SAME range
    /// `setMasterVolume` clamps through, so a flat lane value can never
    /// diverge from a legal fader value), canonicalize, cap, and coalesce
    /// under the shared `automation.points:<laneID>` key (lane ids are
    /// unique, so the key space never collides with track lanes).
    @discardableResult
    public func setMasterAutomationPoints(laneID: UUID, points: [AutomationPoint])
        throws -> AutomationLane {
        guard let li = masterAutomation.firstIndex(where: { $0.id == laneID }) else {
            throw ProjectError.automationLaneNotFound(laneID)
        }
        let clamped = points.map { point in
            AutomationPoint(beat: point.beat,
                            value: point.value.clamped(to: Track.volumeRange),
                            curve: point.curve)
        }
        var canonical = AutomationLane.canonicalize(clamped)
        if canonical.count > Self.maxAutomationPoints {
            canonical = Array(canonical.suffix(Self.maxAutomationPoints))
        }
        performEdit("Edit Master Automation",
                    key: "automation.points:\(laneID.uuidString)") {
            if let li = masterAutomation.firstIndex(where: { $0.id == laneID }) {
                masterAutomation[li].points = canonical
            }
            engine?.masterAutomationChanged(masterAutomation)
        }
        return masterAutomation[li]
    }

    /// Toggles a master lane between read (enabled) and manual (disabled) —
    /// `setAutomationLaneEnabled` verbatim, under the shared
    /// `automation.enable:<laneID>` coalescing key.
    @discardableResult
    public func setMasterAutomationLaneEnabled(laneID: UUID, _ isEnabled: Bool)
        throws -> AutomationLane {
        guard let li = masterAutomation.firstIndex(where: { $0.id == laneID }) else {
            throw ProjectError.automationLaneNotFound(laneID)
        }
        performEdit(isEnabled ? "Enable Master Automation" : "Disable Master Automation",
                    key: "automation.enable:\(laneID.uuidString)") {
            if let li = masterAutomation.firstIndex(where: { $0.id == laneID }) {
                masterAutomation[li].isEnabled = isEnabled
            }
            engine?.masterAutomationChanged(masterAutomation)
        }
        return masterAutomation[li]
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
    public func removeTrack(id: UUID) throws -> Bool {
        // m13-c: a routed strip's teardown announces (engine rebuild) — refuse
        // mid-take before the not-found check so the class is uniform.
        try requireRoutingMutationAllowed("remove a track")
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
            // Sidechain dangling-clear (m12-f): any effect keyed from the
            // removed track reverts to self-keyed inside this SAME edit (one
            // undo restores the track AND every key that pointed at it) —
            // the dangling-send precedent above, for the key-edge class.
            for i in tracks.indices {
                for ei in tracks[i].effects.indices
                where tracks[i].effects[ei].sidechainSourceTrackID == id {
                    tracks[i].effects[ei].sidechainSourceTrackID = nil
                }
            }
            trackMeters.removeValue(forKey: id)
            engine?.tracksDidChange(tracks)
        }
        return true
    }

    // MARK: - Recording guard for routing-topology mutations (m13-c)

    /// Refuses an announce-class ROUTING mutation while a take is rolling.
    ///
    /// Since m13-a a routing rewire that reaches `PlaybackGraph`'s announce
    /// hook (`announceRoutingMutation` → `willMutateRoutingTopology`) on a
    /// once-rendered engine ABORTS reconcile and drives
    /// `AudioEngine.rebuildEngine(reason:)`, which discards and cold-rebuilds
    /// the WHOLE `AVAudioEngine`. Mid-recording that would tear the engine out
    /// from under the in-flight capture — the take's host-time anchor dies, so
    /// the file truncates/misaligns while `transport.isRecording` still reads
    /// true. So every mutation that CAN announce refuses here with a
    /// `transportBusy` teaching error (the `setPunch`/`setMetronome`/`seek`/
    /// `setTempoMap` precedent — plain-language, names the operation, says stop
    /// first). Param-only edits (volume/pan/mute/solo/send LEVEL, fx param/
    /// bypass, clip edits, transport) never announce and stay legal mid-take.
    ///
    /// GUARDED SET, decided by ANNOUNCE-CAPABILITY (the `PlaybackGraph.reconcile`
    /// announce sites), NOT by verb name:
    ///   • `addSend` / `removeSend` / `setTrackOutput` — mutate a source's
    ///     `RoutingKey` (send or output-bus edge) → the step-5 fan-out
    ///     announces.  → GUARDED (unconditional).
    ///   • `removeTrack` — a routed strip's teardown announces (step 1; a bus
    ///     removal announces at step 6). Guarded UNCONDITIONALLY: the whole
    ///     verb class is topology and mid-take structural removal is
    ///     destructive regardless of the strip's triviality.  → GUARDED.
    ///   • `setSidechain` — sets/clears a key edge → the routing signature
    ///     changes → step 5 announces.  → GUARDED (unconditional).
    ///   • `removeEffect` — CONDITIONAL: only removing a *keyed* effect clears
    ///     a key edge (announce); a plain-chain removal is a param-class chain
    ///     publish and never announces → guarded ONLY when the target effect
    ///     carries `sidechainSourceTrackID`.
    ///   • `setInstrument` — CONDITIONAL: only an instrument-NODE rebuild
    ///     (kind / sampler zones / AU component / sound-bank change — the
    ///     `InstrumentTrackKey` teardown trigger) on a ROUTED strip announces;
    ///     a poly-synth param overlay maps to the SAME node and never
    ///     announces → guarded ONLY when both hold.
    /// LEGAL (never announce, documented — future guards must not overreach):
    ///   • `addTrack` — a fresh strip wires TRIVIALLY to master (no sends, no
    ///     key): the ONE live-proven attach-only case that step 5 skips.
    ///   • `addEffect` — a fresh effect carries no key → chain publish, no
    ///     routing change.
    ///   • `reorderEffect` — reordering leaves the key SOURCE set unchanged →
    ///     chain publish, no routing change.
    private func requireRoutingMutationAllowed(_ action: String) throws {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy(
                "cannot \(action) while recording — stop first")
        }
    }

    /// True when a strip participates in routing beyond the pre-M4 trivial
    /// shape (straight to master, no sends, not a sidechain SOURCE) — i.e. a
    /// change that rebuilds its source node would drive
    /// `PlaybackGraph.announceRoutingMutation`. Mirrors the engine's
    /// `isTrivial` + `oldKeyInvolvedStrips` announce condition (reconcile
    /// step 1 / the instrument-teardown branch). Instrument strips are never
    /// key DESTINATIONS (`setSidechain` rejects them), so only the source case
    /// matters here.
    private func trackHasNonTrivialRouting(_ track: Track) -> Bool {
        if track.outputBusID != nil || !track.sends.isEmpty { return true }
        return tracks.contains { other in
            other.effects.contains { $0.sidechainSourceTrackID == track.id }
        }
    }

    /// True when two instrument descriptors map to DIFFERENT engine nodes —
    /// the `PlaybackGraph` `InstrumentTrackKey` rebuild trigger (kind, sampler
    /// zones, AU component, sound-bank address). A poly-synth/test-tone param
    /// overlay maps to the SAME node (no teardown, no announce).
    private static func instrumentNodeIdentityChanged(
        from a: InstrumentDescriptor, to b: InstrumentDescriptor) -> Bool {
        if a.kind != b.kind { return true }
        switch b.kind {
        case .sampler:   return a.resolvedSampler.zones != b.resolvedSampler.zones
        case .audioUnit: return a.audioUnit?.component != b.audioUnit?.component
        case .soundBank: return a.soundBank?.address != b.soundBank?.address
        case .testTone, .polySynth: return false
        }
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
        try requireRoutingMutationAllowed("change a track's output")  // m13-c
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
        try requireRoutingMutationAllowed("add a send")  // m13-c
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
        try requireRoutingMutationAllowed("remove a send")  // m13-c
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
        // m13-c: removing a KEYED effect clears a sidechain key edge → the
        // source strip's routing signature changes → reconcile announces →
        // engine rebuild. Refuse mid-take. A plain-chain removal never
        // announces (chain-state publish only) and stays legal.
        if tracks[ti].effects[ei].sidechainSourceTrackID != nil {
            try requireRoutingMutationAllowed("remove a sidechain-keyed effect")
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

    /// Sets (or clears, `sourceTrackID` nil) one effect's sidechain key
    /// source (m12-f S-1, design-m11f-sidechain §7). Guards OUTSIDE the edit
    /// body (sends/FX precedent), all teaching (design §7 error surface):
    /// unknown track/effect → `trackNotFound`/`effectNotFound`; a non-
    /// compressor/gate kind → `sidechainUnsupportedEffect`; an instrument
    /// destination strip → `sidechainUnsupportedTrack` (no `ChainHostAU` to
    /// receive the key edge); a bus source → `sidechainUnsupportedSource`
    /// (v1 deferral — bus outputs are hardwired to master, so stem passes
    /// cannot carry a bus key source silently); a feedback loop →
    /// `sidechainWouldCreateCycle` naming the existing path; a second keyed
    /// effect on one strip → `sidechainOneSourcePerStrip` naming the first
    /// (one key input bus per strip in v1, design §5). ONE discrete
    /// `performEdit` ("Set Sidechain" — no coalescing key); the engine edge
    /// rewires through the normal `tracksDidChange` reconcile with the
    /// documented routing-rewire bounce. Returns the updated descriptor.
    @discardableResult
    public func setSidechain(trackID: UUID, effectID: UUID,
                             sourceTrackID: UUID?) throws -> EffectDescriptor {
        try requireRoutingMutationAllowed("change a sidechain")  // m13-c
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let ei = tracks[ti].effects.firstIndex(where: { $0.id == effectID }) else {
            throw ProjectError.effectNotFound(effectID)
        }
        let kind = tracks[ti].effects[ei].kind
        guard kind == .compressor || kind == .gate else {
            throw ProjectError.sidechainUnsupportedEffect(kind)
        }
        if let sourceTrackID {
            // Destination strip must physically own a ChainHostAU insert
            // point (audio/bus sandwich) — instrument strips walk their chain
            // inside the source node, which has no input bus for a key edge.
            guard tracks[ti].kind == .audio || tracks[ti].kind == .bus else {
                throw ProjectError.sidechainUnsupportedTrack(tracks[ti].kind)
            }
            guard let si = tracks.firstIndex(where: { $0.id == sourceTrackID }) else {
                throw ProjectError.trackNotFound(sourceTrackID)
            }
            guard tracks[si].kind != .bus else {
                throw ProjectError.sidechainUnsupportedSource(
                    "'\(tracks[si].name)' is a bus — bus key sources are deferred in v1; key from a source track feeding it instead")
            }
            // One key input per strip (v1): a DIFFERENT effect already keyed
            // on this strip rejects; re-keying the same effect is fine.
            if let taken = tracks[ti].effects.first(where: {
                $0.id != effectID && $0.sidechainSourceTrackID != nil
            }) {
                throw ProjectError.sidechainOneSourcePerStrip(
                    "strip '\(tracks[ti].name)' already has a keyed \(taken.kind.rawValue) (effect \(taken.id.uuidString)) — one sidechain key per strip in v1; clear it first")
            }
            // Cycle validation BEFORE the edit commits: the new key edge
            // source → destination must not close an existing signal path
            // destination → … → source (AVAudioEngine graph cycles are
            // undefined behavior; rejected here, never discovered there).
            if let cycle = SidechainGraph.cyclePath(
                ifKeying: trackID, from: sourceTrackID, tracks: tracks) {
                let names = cycle.map { id in
                    tracks.first(where: { $0.id == id })?.name ?? id.uuidString
                }
                let sourceName = tracks[si].name
                // `names` runs destination → … → source; the new key edge
                // source → destination closes it — show the full loop.
                let path = (names + [tracks[ti].name]).joined(separator: " → ")
                throw ProjectError.sidechainWouldCreateCycle(
                    trackID == sourceTrackID
                        ? "a strip cannot key itself — '\(sourceName)' is the keyed strip"
                        : "sidechain would create a feedback cycle: '\(tracks[ti].name)' already feeds '\(sourceName)' (\(path)) — keying it from '\(sourceName)' closes the loop")
            }
        }
        let name = tracks[ti].name
        editTrack(id: trackID, label: "Set Sidechain on '\(name)'") {
            if let ei = $0.effects.firstIndex(where: { $0.id == effectID }) {
                $0.effects[ei].sidechainSourceTrackID = sourceTrackID
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
        // m13-c: an instrument-NODE rebuild (kind/zones/AU/sound-bank change)
        // on a ROUTED strip tears the node down through the reconcile
        // instrument branch, which announces → engine rebuild — refuse
        // mid-take. A poly-synth param overlay (same node) and a swap on a
        // trivially-routed strip never announce and stay legal.
        if Self.instrumentNodeIdentityChanged(from: current, to: resolved),
           trackHasNonTrivialRouting(tracks[index]) {
            try requireRoutingMutationAllowed("change a routed track's instrument")
        }
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

    /// Fixed latency of ONE live MASTER-chain effect instance (m13-d), as the
    /// engine reports it (240 @ 48 kHz for a limiter's lookahead, 0 otherwise
    /// or when running headless). The `effectLatencySamples` twin — DAWControl
    /// reads this to populate the per-effect `latencySamples` in the wire
    /// snapshot's `masterEffects` array while staying engine-free itself.
    public func masterEffectLatencySamples(effectID: UUID) -> Int {
        engine?.masterEffectLatencySamples(effectID: effectID) ?? 0
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
            // Landing over an occupied region resolves through the ONE
            // no-silent-overlap choke point (m13-b) — the same trim rule the
            // ⌘I import batch and clip.move use — folded into this one edit.
            tracks[index].clips = Self.resolvingOverlaps(
                in: tracks[index].clips, activeIDs: [clip.id],
                start: startBeat, end: startBeat + lengthBeats,
                tempoMap: transport.tempoMap).clips
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
            // Landing over an occupied region resolves through the ONE
            // no-silent-overlap choke point (m13-b): a MIDI resident's covered
            // region trims via the same note drop/truncate window semantics —
            // no double-note scheduling — folded into this one edit.
            tracks[index].clips = Self.resolvingOverlaps(
                in: tracks[index].clips, activeIDs: [clip.id],
                start: startBeat, end: startBeat + length,
                tempoMap: transport.tempoMap).clips
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
        let clipStartBeat = tracks[t].clips[c].startBeat

        performEdit("Insert Time Range") {
            tracks[t].clips[c].notes = ordered
            tracks[t].clips[c].lengthBeats = newClipLength
            // Inserting silence GROWS the clip's trailing edge, which can push it
            // over a same-track neighbour → resolve through the ONE no-silent-
            // overlap choke point (m13-b). Residents removed are strictly to the
            // right of this clip, so it keeps its slot; folded into this one edit.
            tracks[t].clips = Self.resolvingOverlaps(
                in: tracks[t].clips, activeIDs: [clipID],
                start: clipStartBeat, end: clipStartBeat + newClipLength,
                tempoMap: transport.tempoMap).clips
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips.first { $0.id == clipID } ?? tracks[t].clips[c]
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

        // Gain envelope (m13-e): the two halves are the windows [0, relBeat] and
        // [relBeat, length]; both pin an interpolated boundary point at the
        // split seam, so the shared value at the junction is identical by
        // construction — the gain is continuous across the cut. Empty → empty.
        let firstEnv = Clip.windowedGainEnvelope(clip.gainEnvelope, delta: 0, newLength: firstLength)
        let secondEnv = Clip.windowedGainEnvelope(clip.gainEnvelope, delta: relBeat, newLength: secondLength)

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
            formantPreserve: clip.formantPreserve, gainEnvelope: firstEnv)
        let second = Clip(
            id: UUID(), name: clip.name,
            startBeat: clip.startBeat + firstLength, lengthBeats: secondLength,
            audioFileURL: clip.audioFileURL, notes: secondNotes,
            isAIGenerated: clip.isAIGenerated,
            startOffsetSeconds: clip.startOffsetSeconds + splitSeconds, gainDb: clip.gainDb,
            fadeInBeats: secondIn, fadeOutBeats: secondOut,
            fadeInCurve: .linear, fadeOutCurve: clip.fadeOutCurve,
            stretchRatio: clip.stretchRatio, pitchShiftSemitones: clip.pitchShiftSemitones,
            formantPreserve: clip.formantPreserve, gainEnvelope: secondEnv)

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
        // Gain envelope (m13-e): re-window it for the moved head — points outside
        // the new visible span drop, edge boundaries are pinned interpolated so
        // the audible gain is continuous with the pre-trim curve. Empty → empty.
        let newEnv = Clip.windowedGainEnvelope(clip.gainEnvelope, delta: delta, newLength: newLength)
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
            formantPreserve: clip.formantPreserve, gainEnvelope: newEnv)

        performEdit("Trim Clip '\(clip.name)'", key: "clip.trim:\(clipId.uuidString)") {
            tracks[t].clips[c] = rebuilt
            // Extending either edge over a same-track neighbour resolves through
            // the ONE no-silent-overlap choke point (m13-b), folded into this
            // edit so a single undo restores both the trim and any resident trim.
            tracks[t].clips = Self.resolvingOverlaps(
                in: tracks[t].clips, activeIDs: [clipId],
                start: newStart, end: newStart + newLength,
                tempoMap: transport.tempoMap).clips
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips.first { $0.id == clipId } ?? rebuilt
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
            tracks[t].clips[c].startBeat = newStart
            let resolved = Self.resolvingOverlaps(
                in: tracks[t].clips, activeIDs: [clipId],
                start: aStart, end: aEnd, tempoMap: tempoMap)
            tracks[t].clips = resolved.clips
            trimmedIDs = resolved.trimmedIDs
            removedIDs = resolved.removedIDs
            engine?.tracksDidChange(tracks)
        }
        let final = tracks[t].clips.first { $0.id == clipId } ?? moved
        return ClipMoveResult(clip: final, trimmedClipIDs: trimmedIDs, removedClipIDs: removedIDs)
    }

    /// Rebuilds `clip` under a FRESH identity/position, VALUE-COPYING every
    /// content field (media/notes, gain, fades + their curves, gain envelope,
    /// stretch/pitch/formant, AI flag) but never the `takeGroupID` — a
    /// duplicated / split-off piece is always an ORDINARY clip (a comp member's
    /// geometry is store-managed and would be overwritten). Pure, no journaling;
    /// `Clip.init` re-heals notes + envelope to their canonical form. Shared by
    /// `duplicateClip` and the split-off tail pieces `arrange.insertBars` /
    /// `arrange.deleteBars` produce.
    static func reidentified(_ clip: Clip, id: UUID, startBeat: Double) -> Clip {
        Clip(
            id: id, name: clip.name,
            startBeat: startBeat, lengthBeats: clip.lengthBeats,
            audioFileURL: clip.audioFileURL, notes: clip.notes,
            isAIGenerated: clip.isAIGenerated,
            startOffsetSeconds: clip.startOffsetSeconds, gainDb: clip.gainDb,
            fadeInBeats: clip.fadeInBeats, fadeOutBeats: clip.fadeOutBeats,
            fadeInCurve: clip.fadeInCurve, fadeOutCurve: clip.fadeOutCurve,
            stretchRatio: clip.stretchRatio, pitchShiftSemitones: clip.pitchShiftSemitones,
            formantPreserve: clip.formantPreserve, gainEnvelope: clip.gainEnvelope,
            takeGroupID: nil)
    }

    /// Duplicates a clip (m15-d) — a VALUE-COPY of everything (`reidentified`)
    /// under a fresh id, landed at `toStartBeat` (default: appended flush after
    /// the SOURCE clip's tail) on `toTrackId` (default: the source's own track).
    ///
    /// Cross-track duplication type-checks by content, reusing the clip-add
    /// rules: a MIDI clip lands only on an instrument track
    /// (`midiClipsRequireInstrumentTrack`), an audio clip only on an audio track
    /// (`trackKindUnsupported`). The source clip may not be a take/comp member
    /// (`requireNotCompMember` — its geometry is store-managed).
    ///
    /// OVERLAP: the new clip lands through the ONE no-silent-overlap choke point
    /// (`resolvingOverlaps`, m13-b) as the active window's claimant — so a
    /// duplicate dropped onto an occupied region TRIMS the ordinary residents it
    /// covers (audio source offset advances / MIDI notes drop-truncate; a
    /// fully-covered resident is removed), never a silent +6 dB overlap. Take
    /// members on the target track are exempt (they intentionally stack). When
    /// `toStartBeat` is omitted the append point is past the source's tail, so
    /// no overlap arises. ONE `performEdit` ("Duplicate Clip '…'") — a single
    /// undo restores both the new clip AND every resident trim. Returns the new
    /// clip PLUS the `ClipMoveResult` trimmed/removed ids (the clip.move honesty
    /// shape).
    @discardableResult
    public func duplicateClip(clipId: UUID, toStartBeat: Double? = nil,
                              toTrackId: UUID? = nil) throws -> ClipMoveResult {
        guard let (st, sc) = locateClip(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        try requireNotCompMember(trackIndex: st, clipIndex: sc)
        let source = tracks[st].clips[sc]
        // Destination track: named target, else the source's own track.
        let dt: Int
        if let toTrackId {
            guard let index = tracks.firstIndex(where: { $0.id == toTrackId }) else {
                throw ProjectError.trackNotFound(toTrackId)
            }
            dt = index
        } else {
            dt = st
        }
        // Type-check by content against the destination track's kind (the
        // clip-add rules, reused verbatim).
        if source.isMIDI {
            guard tracks[dt].kind == .instrument else {
                throw ProjectError.midiClipsRequireInstrumentTrack(tracks[dt].kind)
            }
        } else {
            guard tracks[dt].kind == .audio else {
                throw ProjectError.trackKindUnsupported(tracks[dt].kind)
            }
        }
        let landing = max(0, toStartBeat ?? (source.startBeat + source.lengthBeats))
        let dup = Self.reidentified(source, id: UUID(), startBeat: landing)
        let tempoMap = transport.tempoMap
        var trimmedIDs: [UUID] = []
        var removedIDs: [UUID] = []
        performEdit("Duplicate Clip '\(dup.name)'") {
            tracks[dt].clips.append(dup)
            let resolved = Self.resolvingOverlaps(
                in: tracks[dt].clips, activeIDs: [dup.id],
                start: landing, end: landing + dup.lengthBeats, tempoMap: tempoMap)
            tracks[dt].clips = resolved.clips
            trimmedIDs = resolved.trimmedIDs
            removedIDs = resolved.removedIDs
            engine?.tracksDidChange(tracks)
        }
        let final = tracks[dt].clips.first { $0.id == dup.id } ?? dup
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
        // Gain envelope (m13-e): the same trim-window semantics as trimClip, so
        // an overlap-trimmed resident keeps its (continuous) envelope instead of
        // silently losing it. Empty → empty.
        let newEnv = Clip.windowedGainEnvelope(clip.gainEnvelope, delta: delta, newLength: newLength)
        return Clip(
            id: clip.id, name: clip.name,
            startBeat: start, lengthBeats: newLength,
            audioFileURL: clip.audioFileURL, notes: newNotes,
            isAIGenerated: clip.isAIGenerated,
            startOffsetSeconds: newOffset, gainDb: clip.gainDb,
            fadeInBeats: fin, fadeOutBeats: fout,
            fadeInCurve: clip.fadeInCurve, fadeOutCurve: clip.fadeOutCurve,
            stretchRatio: clip.stretchRatio, pitchShiftSemitones: clip.pitchShiftSemitones,
            formantPreserve: clip.formantPreserve, gainEnvelope: newEnv)
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

    /// The SINGLE no-silent-overlap policy choke point (m11-d, completed in
    /// m13-b). Rebuilds `clips` so every ORDINARY same-track resident yields
    /// whatever region the active window `[start, end)` silently covers, via
    /// `resolveOverlap` (head/tail edge trim, or removal when the window fully
    /// covers it or the remnant would fall below `minClipLengthBeats`). The
    /// window's claimant(s) — the clip ids in `activeIDs`, i.e. the just-moved /
    /// trimmed / stretched / added / grown clip — and every take/comp member
    /// (`takeGroupID != nil`; takes intentionally STACK) pass through untouched.
    /// Array order is preserved: a trimmed resident keeps its slot, a fully-
    /// covered one drops out. PURE — no journaling; every geometry-committing
    /// verb folds the returned list into its ONE `performEdit`, so a single undo
    /// restores both the geometry change and every resident trim. This is the
    /// ONE site all such verbs route through — the m13 audit takeaway is that the
    /// invariant died verb-by-verb precisely because it had been landed
    /// verb-by-verb.
    static func resolvingOverlaps(in clips: [Clip], activeIDs: Set<UUID>,
                                  start: Double, end: Double, tempoMap: TempoMap)
        -> (clips: [Clip], trimmedIDs: [UUID], removedIDs: [UUID]) {
        var rebuilt: [Clip] = []
        rebuilt.reserveCapacity(clips.count)
        var trimmedIDs: [UUID] = []
        var removedIDs: [UUID] = []
        for existing in clips {
            // The window's claimant(s) and take/comp members are never trimmed.
            if activeIDs.contains(existing.id) || existing.takeGroupID != nil {
                rebuilt.append(existing)
                continue
            }
            let resolved = resolveOverlap(stationary: existing, activeStart: start,
                                          activeEnd: end, tempoMap: tempoMap)
            if resolved.isEmpty {
                removedIDs.append(existing.id)
            } else if resolved != [existing] {
                trimmedIDs.append(existing.id)
            }
            rebuilt.append(contentsOf: resolved)
        }
        return (rebuilt, trimmedIDs, removedIDs)
    }

    // MARK: - Arrangement bars (m15-d)
    //
    // PROJECT-WIDE `insertBars`/`deleteBars`: a RIGID timeline translation of a
    // chunk of the arrangement — every track's clips, the markers, the tempo AND
    // meter maps, per-track + master automation, and the loop/punch regions all
    // shift by the SAME meter-aware bar amount inside ONE `performEdit`, so a
    // single undo restores the whole section op. Because the content AND the
    // tempo/meter maps translate together, every local musical relationship
    // (a clip's beats↔seconds, a note's position, a marker's section) is
    // preserved; content that was governed by tempo T at beat B is still
    // governed by T after it moves to B±delta (its map segment moved with it).
    //
    // BAR NUMBERS ARE 1-BASED on the API surface (bar 1 = the first bar, beat 0)
    // and METER-AWARE: the bar↔beat conversion is the real `MeterMap` (a bar in
    // a 6/8 region is 6 beats), so a delete range that crosses meter changes
    // sums the right number of beats. The no-silent-overlap invariant holds by
    // CONSTRUCTION (a rigid suffix shift never makes one ordinary clip cross
    // another; a clip straddling an edit point SPLITS at that point), so these
    // verbs do not — and need not — route through the `resolvingOverlaps` choke
    // point (which resolves ACTIVE-window overlaps from move/add/import).

    /// Inserts `count` empty bars BEFORE 1-based `atBar`, pushing everything from
    /// that barline rightward (m15-d). The inserted bars CONTINUE the meter
    /// governing the bars just before the insertion point (Option A): a
    /// tempo/meter change sitting exactly at the insertion barline moves right
    /// with the content that follows it, so the empty region stays in the
    /// preceding time signature and `count` × that meter's beats-per-bar beats
    /// are inserted. Policies (each pinned):
    ///  - **Clips**: a clip STARTING at/after the insertion point shifts right
    ///    whole; a clip ENDING at/before it is untouched; a clip STRADDLING it
    ///    SPLITS at the insertion barline (head keeps the clip id + its left
    ///    part, the tail becomes a fresh ordinary clip pushed right — Pro-Tools
    ///    "insert silence").
    ///  - **Markers** at/after the insertion point shift right (a marker stays
    ///    attached to the content it named).
    ///  - **Tempo/meter maps**: segments/changes at/after the insertion point
    ///    shift right by the inserted beats (segment/change 0 at beat 0 is
    ///    pinned); the shifted meter map stays barline-valid by construction.
    ///  - **Loop/punch**: a region wholly at/after shifts; a region STRADDLING
    ///    the point GROWS to include the inserted bars (its exclusive right edge
    ///    extends); a region wholly before is untouched.
    /// Refused mid-record (`transportBusy`) — an insert re-anchors the timeline
    /// under a rolling capture; a take group whose content reaches the insertion
    /// point is refused (`take.flatten` first — v1 does not re-anchor comps).
    /// ONE undo. Returns the insertion beat + inserted beats + the bar length.
    @discardableResult
    public func insertBars(atBar: Int, count: Int) throws -> InsertBarsResult {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot insert bars while recording — stop first")
        }
        guard atBar >= 1 else {
            throw ProjectError.invalidArrangeEdit("'atBar' must be >= 1 (bar 1 is the first bar)")
        }
        guard count >= 1 else {
            throw ProjectError.invalidArrangeEdit("'count' must be >= 1")
        }
        let meterMap = transport.meterMap
        let tempoMap = transport.tempoMap
        let bar0 = atBar - 1
        let pivot = meterMap.beat(ofBar: bar0)
        // Option A: the inserted bars continue the meter of the bar BEFORE the
        // insertion point (== the meter AT the pivot unless a change sits exactly
        // there, in which case that change moves right and the preceding meter
        // governs the empty region).
        let bpb = bar0 == 0
            ? meterMap.beatsPerBar(atBeat: 0)
            : meterMap.beatsPerBar(atBeat: meterMap.beat(ofBar: bar0 - 1))
        let delta = Double(count) * Double(bpb)

        try requireNoTakeGroupsAtOrAfter(pivot, verb: "insert bars")
        // Build + validate the shifted maps OUTSIDE the edit body (a validation
        // failure aborts with no partial mutation — the routing-guard precedent).
        let newTempo = try shiftMapForInsert(tempoMap, pivot: pivot, delta: delta)
        let newMeter = try shiftMeterForInsert(meterMap, pivot: pivot, delta: delta)

        performEdit("Insert \(count) Bar\(count == 1 ? "" : "s")") {
            shiftClipsForInsert(pivot: pivot, delta: delta, tempoMap: tempoMap)
            shiftMarkersForInsert(pivot: pivot, delta: delta)
            shiftRegionsForInsert(pivot: pivot, delta: delta)
            if newTempo != tempoMap || newMeter != meterMap {
                applyTempoMap(newTempo, meterMap: newMeter)
            }
            engine?.tracksDidChange(tracks)
            engine?.loopChanged(transport)
        }
        return InsertBarsResult(atBeat: pivot, insertedBeats: delta, beatsPerBar: bpb)
    }

    /// Deletes `count` bars starting at 1-based `fromBar`, closing the gap
    /// (m15-d). The span is meter-aware (`MeterMap.beat(ofBar:)` walks any meter
    /// changes inside the range). Policies (each pinned):
    ///  - **Clips**: fully inside the range → REMOVED (id listed in the result);
    ///    fully after → shifts left; fully before → untouched; straddling the
    ///    LEFT edge → tail trimmed off at the range start (keeps head); straddling
    ///    the RIGHT edge → head trimmed off, remainder pulled left to the splice;
    ///    straddling BOTH edges → SPLIT-then-close (head keeps the id, the far
    ///    tail becomes a fresh clip abutted at the splice — the excised middle is
    ///    gone).
    ///  - **Markers** inside `[start, end)` → REMOVED (ids listed); markers at/
    ///    after `end` shift left. A marker exactly at the range start is inside
    ///    the half-open window, so it is removed.
    ///  - **Tempo/meter maps**: changes INSIDE the range are REMOVED; changes
    ///    at/after `end` shift left; the surviving content's meter/tempo is
    ///    re-seated at the splice. Tempo (no barline constraint) always splices;
    ///    a meter delete that would leave a change off its barline (a boundary
    ///    the range crosses that can't cleanly rejoin) is REFUSED with a teaching
    ///    error rather than corrupting the grid.
    ///  - **Loop/punch**: each endpoint maps through the splice (before → same;
    ///    inside → the splice point; after → shifted left); a region swallowed
    ///    below its minimum length is DISABLED at the splice point.
    /// Refused mid-record; a take group reaching the range is refused (flatten
    /// first). ONE undo. Returns the range start + deleted beats + removed ids.
    @discardableResult
    public func deleteBars(fromBar: Int, count: Int) throws -> DeleteBarsResult {
        guard !transport.isRecording else {
            throw ProjectError.transportBusy("cannot delete bars while recording — stop first")
        }
        guard fromBar >= 1 else {
            throw ProjectError.invalidArrangeEdit("'fromBar' must be >= 1 (bar 1 is the first bar)")
        }
        guard count >= 1 else {
            throw ProjectError.invalidArrangeEdit("'count' must be >= 1")
        }
        let meterMap = transport.meterMap
        let tempoMap = transport.tempoMap
        let bar0 = fromBar - 1
        let deleteStart = meterMap.beat(ofBar: bar0)
        let deleteEnd = meterMap.beat(ofBar: bar0 + count)
        let delta = deleteEnd - deleteStart
        guard delta > 0 else {
            throw ProjectError.invalidArrangeEdit("delete range is empty")
        }

        try requireNoTakeGroupsAtOrAfter(deleteStart, verb: "delete bars")
        let newTempo = try spliceMapForDelete(tempoMap, start: deleteStart, end: deleteEnd, delta: delta)
        let newMeter = try spliceMeterForDelete(meterMap, start: deleteStart, end: deleteEnd, delta: delta)

        var removedClipIDs: [UUID] = []
        var removedMarkerIDs: [UUID] = []
        performEdit("Delete \(count) Bar\(count == 1 ? "" : "s")") {
            removedClipIDs = deleteClips(start: deleteStart, end: deleteEnd, delta: delta, tempoMap: tempoMap)
            removedMarkerIDs = deleteMarkers(start: deleteStart, end: deleteEnd, delta: delta)
            deleteRegions(start: deleteStart, end: deleteEnd, delta: delta)
            if newTempo != tempoMap || newMeter != meterMap {
                applyTempoMap(newTempo, meterMap: newMeter)
            }
            engine?.tracksDidChange(tracks)
            engine?.loopChanged(transport)
        }
        return DeleteBarsResult(fromBeat: deleteStart, deletedBeats: delta,
                                removedClipIDs: removedClipIDs, removedMarkerIDs: removedMarkerIDs)
    }

    // MARK: Arrangement bars — guards + mutators (m15-d)

    /// A take group whose content reaches the edit point can't be re-anchored in
    /// v1 (its comp geometry is store-managed and rebuilt every comp edit), so
    /// the bar edit is refused with a flatten-first teaching error. Groups wholly
    /// before the edit point (upper extent at/before it) never move and are fine.
    private func requireNoTakeGroupsAtOrAfter(_ editStart: Double, verb: String) throws {
        for track in tracks {
            for group in track.takeGroups where group.rangeBeats.upperBound > editStart {
                throw ProjectError.invalidArrangeEdit(
                    "cannot \(verb) across take group '\(group.name)' on track '\(track.name)' — flatten it first (take.flatten)")
            }
        }
    }

    private func shiftClipsForInsert(pivot: Double, delta: Double, tempoMap: TempoMap) {
        for t in tracks.indices {
            var rebuilt: [Clip] = []
            rebuilt.reserveCapacity(tracks[t].clips.count)
            for clip in tracks[t].clips {
                if clip.takeGroupID != nil { rebuilt.append(clip); continue }  // store-managed comp member
                rebuilt.append(contentsOf: Self.clipAfterInsert(
                    clip, pivot: pivot, delta: delta, tempoMap: tempoMap))
            }
            tracks[t].clips = rebuilt
            tracks[t].automation = Self.shiftedAutomationForInsert(
                tracks[t].automation, pivot: pivot, delta: delta)
        }
        masterAutomation = Self.shiftedAutomationForInsert(masterAutomation, pivot: pivot, delta: delta)
    }

    private func shiftMarkersForInsert(pivot: Double, delta: Double) {
        markers = Self.markersSortedByBeat(markers.map {
            $0.beat >= pivot ? Marker(id: $0.id, name: $0.name, beat: $0.beat + delta) : $0
        })
    }

    private func shiftRegionsForInsert(pivot: Double, delta: Double) {
        // Half-open region math: a START at/after the pivot shifts; an END
        // strictly after it shifts (a region ending exactly at the pivot does not
        // grow — the inserted bars sit outside its exclusive right edge). A region
        // straddling the pivot therefore GROWS to include the inserted bars.
        if transport.loopStartBeat >= pivot { transport.loopStartBeat += delta }
        if transport.loopEndBeat > pivot { transport.loopEndBeat += delta }
        if transport.punchInBeat >= pivot { transport.punchInBeat += delta }
        if transport.punchOutBeat > pivot { transport.punchOutBeat += delta }
    }

    private func deleteClips(start: Double, end: Double, delta: Double, tempoMap: TempoMap) -> [UUID] {
        var removed: [UUID] = []
        for t in tracks.indices {
            var rebuilt: [Clip] = []
            rebuilt.reserveCapacity(tracks[t].clips.count)
            for clip in tracks[t].clips {
                if clip.takeGroupID != nil { rebuilt.append(clip); continue }
                let pieces = Self.clipAfterDelete(
                    clip, deleteStart: start, deleteEnd: end, delta: delta, tempoMap: tempoMap)
                if pieces.isEmpty { removed.append(clip.id) }
                rebuilt.append(contentsOf: pieces)
            }
            tracks[t].clips = rebuilt
            tracks[t].automation = Self.shiftedAutomationForDelete(
                tracks[t].automation, start: start, end: end, delta: delta)
        }
        masterAutomation = Self.shiftedAutomationForDelete(masterAutomation, start: start, end: end, delta: delta)
        return removed
    }

    private func deleteMarkers(start: Double, end: Double, delta: Double) -> [UUID] {
        var removed: [UUID] = []
        let kept = markers.compactMap { m -> Marker? in
            if m.beat < start { return m }
            if m.beat < end { removed.append(m.id); return nil }
            return Marker(id: m.id, name: m.name, beat: m.beat - delta)
        }
        markers = Self.markersSortedByBeat(kept)
        return removed
    }

    private func deleteRegions(start: Double, end: Double, delta: Double) {
        func mapped(_ b: Double) -> Double {
            if b < start { return b }
            if b < end { return start }  // interior collapses to the splice point
            return b - delta
        }
        let ls = mapped(transport.loopStartBeat)
        var le = mapped(transport.loopEndBeat)
        if le - ls < TransportState.minLoopLengthBeats {
            le = ls + TransportState.minLoopLengthBeats
            transport.isLoopEnabled = false  // the loop was swallowed by the delete
        }
        transport.loopStartBeat = ls
        transport.loopEndBeat = le
        let ps = mapped(transport.punchInBeat)
        var pe = mapped(transport.punchOutBeat)
        if pe - ps < TransportState.minPunchLengthBeats {
            pe = ps + TransportState.minPunchLengthBeats
            transport.isPunchEnabled = false
        }
        transport.punchInBeat = ps
        transport.punchOutBeat = pe
    }

    // MARK: Arrangement bars — pure geometry (m15-d)

    /// The 1 or 2 clips that replace `clip` under an insert at `pivot` by
    /// `delta > 0`. Comp members must be filtered by the caller.
    static func clipAfterInsert(_ clip: Clip, pivot: Double, delta: Double,
                                tempoMap: TempoMap) -> [Clip] {
        let start = clip.startBeat
        let end = clip.startBeat + clip.lengthBeats
        if start >= pivot {
            var shifted = clip
            shifted.startBeat = start + delta
            return [shifted]
        }
        if end <= pivot { return [clip] }
        // Straddles → split at the insertion barline; head keeps the id, the tail
        // is a fresh ordinary clip windowed to [pivot, end) and pushed right.
        var pieces: [Clip] = []
        if let head = clipTrimmedToWindow(clip, newStart: start, newLength: pivot - start, tempoMap: tempoMap) {
            pieces.append(head)
        }
        if let tail = clipTrimmedToWindow(clip, newStart: pivot, newLength: end - pivot, tempoMap: tempoMap) {
            pieces.append(reidentified(tail, id: UUID(), startBeat: pivot + delta))
        }
        return pieces
    }

    /// The 0, 1, or 2 clips that replace `clip` under a delete of
    /// `[deleteStart, deleteEnd)` by `delta` (= the range length). Comp members
    /// must be filtered by the caller.
    static func clipAfterDelete(_ clip: Clip, deleteStart: Double, deleteEnd: Double,
                                delta: Double, tempoMap: TempoMap) -> [Clip] {
        let start = clip.startBeat
        let end = clip.startBeat + clip.lengthBeats
        if start >= deleteEnd {
            var shifted = clip
            shifted.startBeat = start - delta
            return [shifted]
        }
        if end <= deleteStart { return [clip] }
        if start >= deleteStart, end <= deleteEnd { return [] }  // fully inside → gone
        var pieces: [Clip] = []
        if start < deleteStart,
           let head = clipTrimmedToWindow(clip, newStart: start, newLength: deleteStart - start, tempoMap: tempoMap) {
            pieces.append(head)  // keeps the id, stays at `start`
        }
        if end > deleteEnd,
           let tail = clipTrimmedToWindow(clip, newStart: deleteEnd, newLength: end - deleteEnd, tempoMap: tempoMap) {
            // Pull left to abut at the splice. If a head also survived, the tail
            // is a fresh clip (a genuine split); otherwise it keeps the clip id.
            let tailID = pieces.isEmpty ? clip.id : UUID()
            pieces.append(reidentified(tail, id: tailID, startBeat: deleteEnd - delta))
        }
        return pieces
    }

    /// Automation-point shift for an insert: a point at/after `pivot` moves right
    /// by `delta`. Rebuilt through `AutomationLane.init` (re-canonicalizes).
    static func shiftedAutomationForInsert(_ lanes: [AutomationLane], pivot: Double,
                                           delta: Double) -> [AutomationLane] {
        lanes.map { lane in
            AutomationLane(id: lane.id, target: lane.target,
                           points: lane.points.map {
                               $0.beat >= pivot
                                   ? AutomationPoint(beat: $0.beat + delta, value: $0.value, curve: $0.curve)
                                   : $0
                           },
                           isEnabled: lane.isEnabled)
        }
    }

    /// Automation-point shift for a delete: points inside `[start, end)` are
    /// dropped, points at/after `end` move left by `delta`.
    static func shiftedAutomationForDelete(_ lanes: [AutomationLane], start: Double,
                                           end: Double, delta: Double) -> [AutomationLane] {
        lanes.map { lane in
            AutomationLane(id: lane.id, target: lane.target,
                           points: lane.points.compactMap { p in
                               if p.beat < start { return p }
                               if p.beat < end { return nil }
                               return AutomationPoint(beat: p.beat - delta, value: p.value, curve: p.curve)
                           },
                           isEnabled: lane.isEnabled)
        }
    }

    // MARK: Arrangement bars — map splicing (m15-d)

    private func shiftMapForInsert(_ map: TempoMap, pivot: Double, delta: Double) throws -> TempoMap {
        let segs = map.segments.map { seg -> TempoMap.Segment in
            (seg.startBeat > 0 && seg.startBeat >= pivot)
                ? TempoMap.Segment(startBeat: seg.startBeat + delta, bpm: seg.bpm) : seg
        }
        do { return try TempoMap(segments: segs) }
        catch { throw ProjectError.invalidArrangeEdit("insert bars would corrupt the tempo map (\(error))") }
    }

    private func shiftMeterForInsert(_ map: MeterMap, pivot: Double, delta: Double) throws -> MeterMap {
        let changes = map.changes.map { ch -> MeterMap.Change in
            (ch.startBeat > 0 && ch.startBeat >= pivot)
                ? MeterMap.Change(startBeat: ch.startBeat + delta, beatsPerBar: ch.beatsPerBar, beatUnit: ch.beatUnit) : ch
        }
        do { return try MeterMap(changes: changes) }
        catch { throw ProjectError.invalidArrangeEdit("insert bars would leave a meter change off its barline (\(error))") }
    }

    private func spliceMapForDelete(_ map: TempoMap, start: Double, end: Double, delta: Double) throws -> TempoMap {
        var segs: [TempoMap.Segment] = map.segments.compactMap { seg in
            if seg.startBeat < start { return seg }
            if seg.startBeat < end { return nil }  // inside → dropped
            return TempoMap.Segment(startBeat: seg.startBeat - delta, bpm: seg.bpm)
        }
        // A delete from bar 1 can drop the original base segment; re-seat the
        // surviving content's tempo at beat 0.
        if segs.first?.startBeat != 0 {
            segs.insert(TempoMap.Segment(startBeat: 0, bpm: map.bpm(atBeat: end)), at: 0)
        }
        do { return try TempoMap(segments: segs) }
        catch { throw ProjectError.invalidArrangeEdit("delete bars would corrupt the tempo map (\(error))") }
    }

    private func spliceMeterForDelete(_ map: MeterMap, start: Double, end: Double, delta: Double) throws -> MeterMap {
        var changes: [MeterMap.Change] = map.changes.compactMap { ch in
            if ch.startBeat < start { return ch }
            if ch.startBeat < end { return nil }
            return MeterMap.Change(startBeat: ch.startBeat - delta, beatsPerBar: ch.beatsPerBar, beatUnit: ch.beatUnit)
        }
        if changes.first?.startBeat != 0 {
            let base = map.changes.last { $0.startBeat <= end } ?? map.changes[0]
            changes.insert(MeterMap.Change(startBeat: 0, beatsPerBar: base.beatsPerBar, beatUnit: base.beatUnit), at: 0)
        }
        do { return try MeterMap(changes: changes) }
        catch {
            throw ProjectError.invalidArrangeEdit(
                "deleting these bars would leave a meter change off its barline — delete within a single time-signature region, or remove the meter change first")
        }
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
            // The right clip's head extends left by `half`, revealing earlier
            // material — its clip-relative gain envelope (m13-e) shifts by +half
            // to stay pinned to the same content. The left clip's tail extends
            // (head fixed), so its envelope needs no shift; both re-canonicalize
            // to the new lengths. Empty → empty.
            if !newRight.gainEnvelope.isEmpty {
                newRight.gainEnvelope = Clip.canonicalGainEnvelope(
                    newRight.gainEnvelope.map {
                        ClipGainPoint(beat: $0.beat + half, gainDb: $0.gainDb)
                    },
                    lengthBeats: newRight.lengthBeats)
            }
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

    /// Sets a clip's breakpoint GAIN ENVELOPE WHOLESALE (m13-e; the
    /// `setClipFades` / `setAutomationPoints` precedent): the given points are
    /// clamped (each `beat` into `[0, lengthBeats]`, each `gainDb` into
    /// `Clip.gainDbRange`) and canonicalized (sorted ascending, equal-beat
    /// duplicates deduped last-wins) through `Clip.canonicalGainEnvelope`. An
    /// EMPTY array CLEARS the envelope (back to today's static-gain-plus-fades
    /// behavior exactly). The envelope MULTIPLIES on top of the static gain and
    /// fades — it does not replace them.
    ///
    /// Audio clips only: the envelope is realized in the offline audio fade-bake
    /// (a MIDI clip has no per-clip player to bake onto, the gain/fades/stretch
    /// family rule) — a MIDI clip throws `invalidClipEdit`. Unlike a plain gain
    /// edit, changing the envelope is a SCHEDULE-key change (it re-bakes), so it
    /// rides `tracksDidChange` (the fades path), not the live `clipGainChanged`
    /// parameter write. Coalesces under `clip.gainEnv:<clipId>` so a breakpoint
    /// drag is one undo step (>800 ms gap = a separate entry, the established
    /// coalescing boundary).
    @discardableResult
    public func setClipGainEnvelope(trackId: UUID, clipId: UUID,
                                    points: [ClipGainPoint]) throws -> Clip {
        let (t, c) = try locateClip(trackID: trackId, clipID: clipId)
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let clip = tracks[t].clips[c]
        guard !clip.isMIDI else {
            throw ProjectError.invalidClipEdit(
                "clip '\(clip.name)' is a MIDI clip — gain envelopes apply to audio clips only")
        }
        let canon = Clip.canonicalGainEnvelope(points, lengthBeats: clip.lengthBeats)
        performEdit("Set Clip Gain Envelope", key: "clip.gainEnv:\(clipId.uuidString)") {
            tracks[t].clips[c].gainEnvelope = canon
            // A ClipKey-affecting edit: the envelope bakes into the scheduled
            // buffers, so the engine must re-schedule (re-bake) — the fade-edit
            // seam (stop-reschedule-resume). tracksDidChange triggers reconcile,
            // and gainEnvelope is in the ClipKey signature so it reschedules.
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
                tracks[t].clips = Self.resolvingOverlaps(
                    in: tracks[t].clips, activeIDs: [clipId],
                    start: clip.startBeat, end: clip.startBeat + targetLength,
                    tempoMap: transport.tempoMap).clips
                engine?.tracksDidChange(tracks)
            }
            return tracks[t].clips.first { $0.id == clipId } ?? clip
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
            // The retarget only ever grows/shrinks the trailing edge — resolve
            // any resulting overlap through the ONE choke point (m13-b).
            tracks[t].clips = Self.resolvingOverlaps(
                in: tracks[t].clips, activeIDs: [clipId],
                start: clip.startBeat, end: clip.startBeat + newLength,
                tempoMap: transport.tempoMap).clips
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips.first { $0.id == clipId } ?? clip
    }

    // MARK: - Mixdown

    /// Bounces the current session to a WAV file through the injected engine's
    /// offline render path. Blocking; v0 accepts the main-actor stall for
    /// typical song lengths.
    ///
    /// `durationSeconds` nil → the SHARED default window (`renderWindowSeconds`,
    /// m16-d): from `fromBeat` to the end of the last clip of ANY kind — audio
    /// AND instrument — at the current tempo, plus the 2.0 s bus-reverb/release
    /// tail. This is byte-for-byte the window `render.bounce`,
    /// `render.measureLoudness`, and `render.stems` default to, so "render my
    /// song" on a MIDI-only project renders the song instead of dead-ending on
    /// a false teaching error. (It USED to be an audio-only extent with a 0.5 s
    /// tail — the "legacy default stays untouched" carve-out audit F4 measured
    /// as the bug; the carve-out is retired, not documented — a defensive
    /// comment dies with the bug it defends.) No clips past `fromBeat` →
    /// `nothingToRender`. Explicit `durationSeconds` renders that exact window,
    /// untouched (era-pinned byte-identity — the extent seam is bypassed).
    public func renderMixdown(
        toPath path: String? = nil,
        fromBeat: Double = 0,
        durationSeconds: Double? = nil
    ) async throws -> MixdownResult {
        guard let engine else { throw ProjectError.engineUnavailable }
        let startBeat = max(0, fromBeat)
        // The ONE default-window seam (m16-d): explicit duration wins untouched;
        // nil → the shared all-clips extent + 2.0 s tail, identical to bounce/
        // stems/measure. No clips past `fromBeat` throws `nothingToRender`.
        let duration = try renderWindowSeconds(fromBeat: startBeat, requested: durationSeconds)

        let url = Self.mixdownDestination(from: path)
        let info = try await engine.renderMixdown(
            tracks: tracks,
            tempoMap: transport.tempoMap,
            masterVolume: masterVolume,
            masterEffects: masterEffects,  // MASTERED class (m13-d, design §2)
            masterAutomation: masterAutomation,  // rides the class (m15-c)
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
        // Tempo/meter map overrides (m12-d) ride the transport here: a
        // `tempo.setMap` mutation is undoable, so — unlike playhead/play state —
        // they are NOT normalized out, and undo/redo restore them exactly.
        return EditState(tracks: tracks, masterVolume: masterVolume, transport: t,
                         grooveTemplates: grooveTemplates, markers: markers,
                         masterEffects: masterEffects,
                         masterAutomation: masterAutomation)
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
        // Master chain (m13-d): the masterVolume twin — restore pushes the
        // engine intent only when the chain actually moved.
        let masterFXChanged = masterEffects != target.masterEffects
        // Master volume automation (m15-c): the masterEffects twin.
        let masterAutoChanged = masterAutomation != target.masterAutomation
        // Tempo/meter map compare (m12-d, design row 36). Both the live
        // transport and the target carry their map overrides (undoable, no
        // normalization), so this catches a `tempo.setMap` undo exactly as it
        // catches a scalar-tempo undo. Meter bumps the revision (Clip-Fix
        // staleness) and — m15-a — refreshes the live click schedule (the
        // meter map is the click scheduler's downbeat source).
        let tempoChanged = transport.tempoMap != target.transport.tempoMap
        let meterChanged = transport.meterMap != target.transport.meterMap
        let loopChanged = transport.isLoopEnabled != target.transport.isLoopEnabled
            || transport.loopStartBeat != target.transport.loopStartBeat
            || transport.loopEndBeat != target.transport.loopEndBeat
        let metronomeChanged = transport.isMetronomeEnabled != target.transport.isMetronomeEnabled
            || transport.countInBars != target.transport.countInBars

        tracks = target.tracks
        masterVolume = target.masterVolume
        masterEffects = target.masterEffects
        masterAutomation = target.masterAutomation
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
        // Tempo/meter map overrides (m12-d) ride `target.transport` — undo/redo
        // restore them with the rest of the persistable transport fields.
        transport = restored

        for id in vanishedTrackIDs {
            trackMeters.removeValue(forKey: id)
        }

        if tracksChanged { engine?.tracksDidChange(tracks) }
        if masterChanged { engine?.masterVolumeChanged(masterVolume) }
        if masterFXChanged { engine?.masterEffectsChanged(masterEffects) }
        if masterAutoChanged { engine?.masterAutomationChanged(masterAutomation) }
        // A map swap by undo/redo counts as a change for Clip-Fix staleness
        // (mapRevision only ever climbs), and re-anchors the engine's tempo.
        if tempoChanged || meterChanged { mapRevision &+= 1 }
        if tempoChanged { engine?.setTempo(transport) }
        if loopChanged { engine?.loopChanged(transport) }
        // m14-c: click-player-local, like the setMetronome intent — an
        // undo/redo of a metronome toggle never restarts the transport.
        // m15-a: a meter-map swap rides the SAME intent (the meter map is the
        // click scheduler's downbeat source) — unless a tempo change already
        // restarted the transport, which re-caches and reschedules clicks.
        if metronomeChanged || (meterChanged && !tempoChanged), transport.isPlaying {
            engine?.metronomeChanged(transport)
        }
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
            markers: markers,
            tempoMapRevision: mapRevision,
            masterEffects: masterEffects,
            masterAutomation: masterAutomation
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
        masterEffects = []  // m13-d: a fresh session carries no master chain
        masterAutomation = []  // m15-c: … and no master automation
        grooveTemplates = []
        markers = []
        // Fresh session → the map is trivial and its revision resets (m12-d).
        mapRevision = 0
        masterMeter = .silence
        trackMeters = [:]
        lastRecordingError = nil
        // Stale pending fixes point into the old project (M6 v-b).
        pendingClipFixes = [:]
        // Engine notices describe the OLD session's playback (m15-e).
        engineNotices = []
        engineNoticeSequence = 0
        resetRecordingScratch()
        // A new session starts with empty history; prior edits no longer apply.
        journal.clear()

        // m13-a (A1): a project boundary retires the engine's whole graph —
        // a once-rendered engine rebuilds from the new (empty) model inside
        // the tracksDidChange below instead of tearing nodes down one by one.
        engine?.projectWillReplace()
        engine?.tracksDidChange(tracks)
        engine?.masterVolumeChanged(masterVolume)
        engine?.masterEffectsChanged(masterEffects)
        engine?.masterAutomationChanged(masterAutomation)
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
        masterEffects = runtime.masterEffects
        masterAutomation = runtime.masterAutomation
        // Resume the persisted map revision (m12-d) so a reopened non-trivial
        // map keeps a stable, monotonic identity; trivial projects load 0.
        mapRevision = document.tempoMapRevision ?? 0
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
        // Engine notices describe the PREVIOUS session's playback (m15-e).
        engineNotices = []
        engineNoticeSequence = 0
        resetRecordingScratch()
        // History belongs to the previous session — the newly loaded one starts
        // fresh (undo must never reach across a load boundary).
        journal.clear()

        // m13-a (A1): a project boundary retires the engine's whole graph —
        // a once-rendered engine rebuilds from the opened model inside the
        // tracksDidChange below instead of tearing nodes down one by one.
        engine?.projectWillReplace()
        engine?.tracksDidChange(tracks)
        engine?.masterVolumeChanged(masterVolume)
        engine?.masterEffectsChanged(masterEffects)
        engine?.masterAutomationChanged(masterAutomation)
        engine?.loopChanged(transport)

        projectPath = bundleURL.path
        isDirty = false
        // Opening another project supersedes any crash-recovery snapshot (crash-b).
        invalidateCrashRecovery()
        // m16-c: AFTER the clear above (and after tracksDidChange, whose graph
        // build may already have posted the same code for the same clips —
        // coalesced by construction), the opened session's missing-media facts
        // land in the ring so the snapshot agrees with the warnings returned.
        echoMissingMediaNotices()
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
            markers: markers,
            tempoMapRevision: mapRevision,
            masterEffects: masterEffects,
            masterAutomation: masterAutomation
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
        masterEffects = runtime.masterEffects
        masterAutomation = runtime.masterAutomation
        // Resume the persisted map revision (m12-d), like the open path.
        mapRevision = document.tempoMapRevision ?? 0
        grooveTemplates = document.grooveTemplates ?? []
        markers = Self.markersSortedByBeat(document.markers ?? [])

        masterMeter = .silence
        trackMeters = [:]
        lastRecordingError = nil
        pendingClipFixes = [:]
        // Engine notices describe the PREVIOUS session's playback (m15-e;
        // m16-c extends the clear law to recover — a recover is a session
        // replacement like open, and the echo below re-posts what still holds).
        engineNotices = []
        engineNoticeSequence = 0
        resetRecordingScratch()
        journal.clear()

        engine?.tracksDidChange(tracks)
        engine?.masterVolumeChanged(masterVolume)
        engine?.masterEffectsChanged(masterEffects)
        engine?.masterAutomationChanged(masterAutomation)
        engine?.loopChanged(transport)

        projectPath = sourcePath
        isDirty = true
        // m16-c: clear-then-echo, the open-path ordering — recovery bundles
        // record ABSOLUTE media refs, which resolveMedia accepts without a
        // warning, so this echo is the ONLY open-time honesty the recovered
        // session gets (the audit §2-B3 recipe).
        echoMissingMediaNotices()
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
            masterEffects: masterEffects,
            masterAutomation: masterAutomation,
            grooveTemplates: grooveTemplates,
            markers: markers,
            tempoMap: transport.tempoMapOverride?.segments,
            meterChanges: transport.meterMapOverride?.changes,
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
            midiEventCount: engine?.midiEventCount(),
            engineNotices: engineNotices
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
