import Foundation

/// One installed Audio Unit music device as the engine enumerates it —
/// AudioComponent facts mirrored into the domain so DAWCore stays engine-free.
public struct AudioUnitComponentInfo: Sendable, Equatable, Codable {
    public let component: AudioUnitComponentID
    public let name: String
    public let manufacturerName: String
    public let versionString: String
    public let isV3: Bool

    public init(component: AudioUnitComponentID, name: String,
                manufacturerName: String, versionString: String, isV3: Bool) {
        self.component = component
        self.name = name
        self.manufacturerName = manufacturerName
        self.versionString = versionString
        self.isV3 = isV3
    }
}

/// Lifecycle state of one track's hosted Audio Unit instrument, as the engine
/// reports it. `pending` while async preparation runs; `missing` when no
/// installed component matches; `failed` carries a readable reason. Any state
/// other than `ready` renders as the silent placeholder.
public enum AudioUnitTrackStatus: Sendable, Equatable {
    case pending
    case ready
    case missing
    case failed(String)
}

/// Render state of one audio clip's offline stretch render (M5 ii-d), as the
/// engine reports it at snapshot-build time (pull-based — never persisted).
/// `.rendering` = the clip is scheduled as SILENCE until the render lands
/// (honest silence, never wrong-speed audio); `.failed` carries a readable
/// reason (the clip stays silent; re-editing the params retries); `.idle` =
/// nothing pending (identity clips and committed renders alike).
public enum ClipStretchStatus: Sendable, Equatable {
    case idle
    case rendering
    case failed(String)
}

/// One schedule-time degradation as the engine reports it (m15-e, audit F6):
/// playback proceeded, but not exactly as the project describes (a fade/
/// envelope bake failed, a stretched clip is still rendering, …). Posted from
/// CONTROL-side schedule code only — the render thread never produces these.
/// The store coalesces events into its `engineNotices` ring; this event type
/// carries just the facts one occurrence knows.
public struct EngineNoticeEvent: Sendable, Equatable {
    /// Stable machine code (kebab-case) naming the degradation family — the
    /// store's coalescing key. Current codes: `clip-envelope-skipped`,
    /// `clip-fades-skipped`, `clip-stretch-pending`, `clip-unplayable`,
    /// `engine-exception` (m16-a), `clip-file-missing` (m16-c — the
    /// build-time open catch and the store's open/recover echo).
    public var code: String
    /// Beginner-readable description of what the listener actually got
    /// (design-language copy — no wire-speak, names the clip).
    public var message: String
    /// Timeline beat of the affected clip's start, when the site knows one.
    public var beat: Double?

    public init(code: String, message: String, beat: Double? = nil) {
        self.code = code
        self.message = message
        self.beat = beat
    }
}

/// One COALESCED engine notice as surfaced on `project.snapshot` (m15-e):
/// repeat posts of the same `code` increment `count` and refresh
/// `message`/`beat`/`lastAt` instead of appending. Session-transient
/// diagnostics — never persisted to disk, never journaled (undo/redo does
/// not touch notices), cleared on `project.new`/`project.open`/
/// `project.recover` (every session replacement).
public struct EngineNotice: Sendable, Equatable, Codable {
    /// The coalescing key — see `EngineNoticeEvent.code`.
    public var code: String
    /// Latest occurrence's message (latest wins under coalescing).
    public var message: String
    /// Latest occurrence's clip-start beat, when known.
    public var beat: Double?
    /// How many times this code has posted since the ring was last cleared.
    public var count: Int
    /// Session-monotonic post sequence (1 = the first post since the last
    /// clear) — deliberately NOT wall-clock: a scripted scenario produces
    /// byte-identical snapshots on every run (gate scripts diff them), and
    /// relative order across notices stays exactly comparable. It is an
    /// ordering token, not a timestamp.
    public var lastAt: Int

    public init(code: String, message: String, beat: Double? = nil,
                count: Int = 1, lastAt: Int) {
        self.code = code
        self.message = message
        self.beat = beat
        self.count = count
        self.lastAt = lastAt
    }
}

/// One detected onset in an audio SOURCE file (M5 iii-e). `timeSeconds` is the
/// position in source-file seconds — geometry-free by design: clip trims and
/// splits never move it, mirroring the stretch cache's whole-source-file rule.
/// `strength` is 0...1, normalized against the strongest onset found in the
/// same analysis (1 = strongest). Produced by offline analysis, cached
/// content-keyed; regenerable by definition, never persisted in the project.
public struct TransientMarker: Sendable, Equatable, Codable {
    public var timeSeconds: Double
    public var strength: Double

    public init(timeSeconds: Double, strength: Double) {
        self.timeSeconds = timeSeconds
        self.strength = strength
    }
}

/// The MIDI side of one finished take, reported by the engine when the take
/// finalizes. Notes are clip-relative beats, canonically ordered.
public struct MIDIRecordingResult: Sendable, Equatable {
    public var notes: [MIDINote]
    /// Whole-beat clip length covering the take (min 1) — matches
    /// `addMIDIClip` sizing.
    public var lengthBeats: Double
    /// True when the capture ring overflowed mid-take (events were lost).
    public var droppedEvents: Bool
    /// Captured controller streams (m16-b3): CC / pitch bend / channel
    /// pressure as clip-relative lanes (same beat domain as `notes`), already
    /// thinned at ingest per the design-m16b §7 capture law. ADDITIVE with a
    /// `[]` default so fake engines and pre-CC constructions stay valid
    /// unchanged (C12).
    public var controllerLanes: [MIDIControllerLane]

    public init(notes: [MIDINote], lengthBeats: Double, droppedEvents: Bool = false,
                controllerLanes: [MIDIControllerLane] = []) {
        self.notes = notes
        self.lengthBeats = lengthBeats
        self.droppedEvents = droppedEvents
        self.controllerLanes = controllerLanes
    }
}

/// Outcome of one finished take: the audio side (nil for MIDI-only takes) and
/// the MIDI side (nil when MIDI capture was off or unsupported). One-take
/// semantics: if the audio side aborts, the WHOLE take fails and captured
/// MIDI is discarded.
public struct TakeResult: Sendable {
    public var audio: RecordingResult?
    public var midi: MIDIRecordingResult?
    /// LINEAR transport beat at which the take stopped (m15-b): the engine's
    /// capture-clamp beat — the frozen map's inverse integral from the record
    /// anchor, NEVER modular under a loop. Loop-cycle slicing derives the
    /// exact MIDI cycle count from it (`MIDIRecordingResult.lengthBeats` is
    /// rounded UP to whole beats, which would fabricate a phantom cycle at a
    /// wrap). nil from engines/fakes that never derived one — consumers fall
    /// back to the rounded length.
    public var stopBeats: Double?

    public init(audio: RecordingResult? = nil, midi: MIDIRecordingResult? = nil,
                stopBeats: Double? = nil) {
        self.audio = audio
        self.midi = midi
        self.stopBeats = stopBeats
    }
}

/// The contract between the domain layer and the real-time audio engine.
/// DAWCore (and everything above it) never sees AVFoundation types.
@MainActor
public protocol AudioEngineControlling: AnyObject {
    var isRunning: Bool { get }

    /// Build/refresh the graph and start the hardware. Idempotent.
    func prepare() throws
    func shutdown()

    /// Reconcile the engine graph with the domain track list. Called after any
    /// track/clip mutation. Safe while playing: schedule-affecting changes
    /// trigger an internal stop-reschedule-resume from the current position;
    /// parameter-only changes never interrupt audio.
    func tracksDidChange(_ tracks: [Track])

    /// The WHOLE project is about to be replaced (`project.new` /
    /// `project.open`) — called immediately before the `tracksDidChange`
    /// that carries the new session's tracks. m13-a: a real engine that has
    /// rendered discards its entire graph + hardware engine and rebuilds
    /// from the new model (no per-node teardown of a once-rendered engine
    /// is ever attempted — the proven crash class); engines that never ran,
    /// and engines without the capability, ignore it.
    func projectWillReplace()

    /// Per-clip gain edit (M5 i-b): applied LIVE as one input-gain write on
    /// the clip's player — never a stop-reschedule-resume, so mid-play gain
    /// trims are seamless. Audio clips only in v0 (MIDI clips have no
    /// per-clip player); unknown ids are a safe no-op. Callers still follow
    /// with `tracksDidChange` so the engine's cached track state stays fresh
    /// for later restarts (loop wraps re-apply parameters from it).
    func clipGainChanged(trackID: UUID, clipID: UUID, gainDb: Double)

    /// Offline stretch-render state for one clip (M5 ii-d): `.rendering`
    /// while the engine's cache job is in flight (the clip plays silence
    /// until the render lands), `.failed(reason)` after a render error.
    /// Pull-based: the control snapshot queries this at build time and emits
    /// the transient `stretchRendering`/`stretchError` fields. nil/`.idle`
    /// for engines without stretch support.
    func clipStretchStatus(trackID: UUID, clipID: UUID) -> ClipStretchStatus?

    /// Transient onset markers for the audio file at `url` (M5 iii-e):
    /// offline spectral-flux analysis, content-key cached on disk. Times are
    /// SOURCE-FILE seconds (geometry-free — callers map to clip windows and
    /// timeline beats themselves). `sensitivity` 0...1: higher finds more
    /// onsets. Runs in async/detached context only — never touches the
    /// render thread.
    func detectTransients(inFileAt url: URL, sensitivity: Double) async throws -> [TransientMarker]

    /// Begin playback from transport.positionBeats under transport.tempoMap
    /// (m12-b: the map is derived from transport.tempoBPM — trivial until
    /// Phase C). transport.isMetronomeEnabled is read HERE (and on every
    /// seek/restart); a mid-play toggle goes through `metronomeChanged`
    /// (m14-c: click-player-local, never a transport restart).
    func startPlayback(_ transport: TransportState)

    /// Halt sound; keep the engine hot. Pushes one final render-derived
    /// playhead update via playheadHandler before returning.
    func stopPlayback()

    /// Playhead moved; transport.positionBeats is the authoritative target.
    /// If playing, reschedule and resume from there; if stopped, no-op
    /// (position arrives with the next startPlayback).
    func seek(_ transport: TransportState)

    /// Tempo changed. If playing, the engine re-anchors from its OWN derived
    /// current beat position (transport.positionBeats may be ~33 ms
    /// display-stale) and resumes under transport.tempoMap (m12-b; any future
    /// map edit fires this same restart seam — design row 49).
    func setTempo(_ transport: TransportState)

    /// Loop settings changed; engine updates its cached loop state. Never interrupts audio.
    func loopChanged(_ transport: TransportState)

    /// Metronome settings changed (m14-c L-3): engine updates its cached
    /// metronome state and, while playing, starts/stops the CLICK PLAYER
    /// ONLY — clip playback is never interrupted (byte-identical through a
    /// toggle; the pre-m14-c seek/restart fallback is retired). Stopped
    /// engines just cache: the state is read again at the next start.
    func metronomeChanged(_ transport: TransportState)

    /// Master output gain 0...2 (1 = unity). Applied to the main mix bus.
    func masterVolumeChanged(_ volume: Double)

    /// The project's MASTER insert chain changed (m13-d) — the
    /// `masterVolumeChanged` twin. Live engines cache the descriptors, hand
    /// them to the graph, and run one parameter pass (chain sync + PDC
    /// recompute funnel — an atomic snapshot publish into the permanent
    /// master chain host, NEVER a topology change, never a transport
    /// interruption; design-m13d §1-B/D3). Pushed on every master chain
    /// mutation AND every undo/redo/project-boundary restore, exactly like
    /// the master volume.
    func masterEffectsChanged(_ effects: [EffectDescriptor])

    /// The project's MASTER volume automation changed (m15-c) — the
    /// `masterEffectsChanged` twin. Live engines cache the lanes, hand them
    /// to the graph, and run one parameter pass: while rolling the pass
    /// republishes the master schedule IN PLACE against the same anchor
    /// (never a restart — the vii-b no-restart rule); while stopped it lands
    /// the WYSIWYG lane preview on the master fader. Pushed on every master
    /// lane mutation AND every undo/redo/project-boundary restore, exactly
    /// like the master chain.
    func masterAutomationChanged(_ lanes: [AutomationLane])

    /// Bounce the given project state to a WAV file, offline (no hardware).
    /// Async so hosted Audio Unit instruments can be instantiated/prepared for
    /// the offline graph first; the render itself still stalls the main actor
    /// for its duration (v0-accepted for typical song lengths).
    ///
    /// `masterEffects` (m13-d, design D2): the master insert chain applied to
    /// this render — deliberately NO protocol default, so every call site
    /// declares its render class: MASTERED (program renders — mixdown/
    /// bounce/loudness — pass the project chain) vs STEM (material renders —
    /// stem passes, their "00 Mixdown" reference, bounce-in-place, Clip-Fix
    /// regions — pass `[]`; stems are pre-master by contract S-3′).
    ///
    /// `masterAutomation` (m15-c) rides the SAME class split, same no-default
    /// discipline: MASTERED passes the project's master volume lane (the fade
    /// is part of the master performance), STEM passes `[]` — a master fade,
    /// though linear, is performance, not material: baking it into stems or a
    /// bounce-in-place would double-apply on playback and destroy the
    /// re-mixable material (the S-3′ extension). The static `masterVolume`
    /// stays included in BOTH classes, exactly as before m15-c.
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo

    /// Offline-render the given project state to MEMORY (M5 iv-b, spec §5) —
    /// `renderMixdown` minus the file write: same WYSIWYG await of pending
    /// stretch renders, same fresh offline renderer + fresh AU instances per
    /// pass, same accepted main-actor stall for the render's duration.
    /// `forcedCompensationTargets` non-nil forces per-strip PDC ring targets
    /// (stem passes pass the FULL-SESSION plan so subset renders stay
    /// sample-aligned with the mix — spec §1.1); nil = the automatic plan
    /// (mix behavior). `masterEffects` + `masterAutomation` declare the
    /// render class — see `renderMixdown` (m13-d/m15-c: MASTERED passes the
    /// project chain + master lane, STEM passes `[]` for both; no default by
    /// design). Memory: one `RenderedAudio` alive per call (~230 MB for a
    /// 10-min stereo 48 k render) — accepted v0.
    func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio

    /// The full-session per-strip compensation targets EXACTLY as the offline
    /// renderer's automatic plan would apply them (M5 iv-b, spec §5): a
    /// planning pass prepares the session's AUs (hosted latency), reconciles
    /// an offline graph, runs one parameter pass WITHOUT rendering, and reads
    /// the resulting plan — parity with a real render pass by construction.
    /// Stem export (iv-c) forces these into every per-stem subset pass so the
    /// Σ-stems ≡ mix invariant survives PDC.
    func offlineCompensationTargets(tracks: [Track]) async -> [UUID: Int]

    /// Write a rendered buffer to `url` as a Float32 interleaved WAV (the
    /// `renderMixdown` writer, split out — M5 iv-b, spec §5): parent
    /// directories created recursively, existing files overwritten, and the
    /// write is frame-exact — the file holds exactly the samples in `audio`,
    /// bit for bit (Float32 end-to-end keeps the ii-e no-baked-headroom
    /// stance; > 0 dBFS content survives to disk).
    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo

    /// Total fixed algorithmic latency of the track's insert-effect chain, in
    /// samples at the engine rate — the sum of the chain's non-bypassed
    /// effects (e.g. the limiter's 5 ms lookahead = 240 @ 48 kHz); M4 (viii)
    /// plugin-delay compensation consumes this without touching the render
    /// path. 0 for unknown tracks and engines without insert support.
    func insertChainLatencySamples(forTrack id: UUID) -> Int

    /// Fixed algorithmic latency of ONE live insert-effect instance, in
    /// samples at the engine rate, regardless of bypass (it is a property of
    /// the effect; the chain sum above applies the non-bypassed rule). Feeds
    /// the per-effect `latencySamples` on the control snapshot. 0 for unknown
    /// tracks/effects and engines without insert support.
    func effectLatencySamples(trackID: UUID, effectID: UUID) -> Int

    /// Fixed algorithmic latency of ONE live MASTER-chain effect instance
    /// (m13-d), the `effectLatencySamples` twin on the post-fader master chain
    /// — feeds the per-effect `latencySamples` in the wire snapshot's
    /// `masterEffects` array. 0 for unknown effects, an empty chain, and
    /// engines without master-chain support (the default below).
    func masterEffectLatencySamples(effectID: UUID) -> Int

    /// The engine's latest latency-compensation report (M4 viii-c, spec §6):
    /// per-strip all-effects chain latency and applied ring targets plus the
    /// global stage maxima. Feeds the additive PDC snapshot fields. nil until
    /// the engine has run a recompute, or for engines without insert support.
    func pdcReport() -> PDCReport?

    /// All installed Audio Unit music devices ('aumu') available for hosting.
    func availableAudioUnits() -> [AudioUnitComponentInfo]

    /// Lifecycle state of the hosted Audio Unit on the given track; nil when
    /// the engine tracks no AU for that id.
    func audioUnitStatus(forTrack id: UUID) -> AudioUnitTrackStatus?

    /// Effect mirror of `audioUnitStatus(forTrack:)` (M3 vi-b): lifecycle state
    /// of one hosted insert-effect AU, so a plugin-window open-failure can name
    /// pending/missing/failed(reason) readably. nil when the engine tracks no AU
    /// for that effect id, or for engines without AU-effect support.
    func audioUnitEffectStatus(forEffect id: UUID) -> AudioUnitTrackStatus?

    /// Current `fullStateForDocument` of the track's hosted Audio Unit as a
    /// binary plist, for save-time capture; nil when no prepared AU exists.
    func instrumentState(forTrack id: UUID) -> Data?

    /// All installed Audio Unit effects ('aufx') available as inserts (M4 v).
    func availableAudioUnitEffects() -> [AudioUnitComponentInfo]

    /// Current `fullStateForDocument` of one hosted insert-effect AU as a
    /// binary plist, for save-time capture; nil when no prepared AU exists.
    func effectState(forEffect id: UUID) -> Data?

    /// Current microphone permission as the OS reports it.
    var recordPermission: RecordPermission { get }

    /// Fires the system microphone prompt (or resolves immediately when the
    /// decision already exists). Completion lands on the main actor.
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void)

    /// All hardware devices currently offering input streams, with the system
    /// default input flagged. Safe to call any time; never touches the render
    /// path.
    func availableInputDevices() -> [AudioInputDevice]

    /// Pin capture to the device with this UID; nil returns to following the
    /// system default. Takes effect on the NEXT recording — a rolling take is
    /// never re-routed. Throws when no input device carries the UID.
    func setInputDevice(uid: String?) throws

    /// Start capturing the selected input (see `setInputDevice`; the system
    /// default when unset) to `url` AND start playback from
    /// transport.positionBeats — one take, one file; the engine knows nothing
    /// about tracks (ProjectStore fans the file out to armed tracks). The
    /// engine must NOT already be playing. When transport.isPunchEnabled, only
    /// capture inside [punchInBeat, punchOutBeat] (translated from the
    /// record-start position) is kept; the caller must guarantee
    /// punchOutBeat > positionBeats. When transport.countInBars > 0 the take
    /// anchor is delayed by countInBars bars and the gap is filled with
    /// count-in clicks (even when the metronome is disabled — count-in
    /// implies clicks); capture trims to the delayed anchor, so the finished
    /// take excludes the count-in and clip placement math is unchanged.
    /// Throws synchronously on input or
    /// file failure with no state change. `completion` fires exactly once on
    /// the main actor after the take is finalized (via stopRecording or an
    /// engine-initiated stop).
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws

    /// Superset of `startRecording` for one combined take: audio capture to
    /// `audioURL` when non-nil (same contract as `startRecording` — punch
    /// window, count-in, watchdog), plus MIDI capture from all connected
    /// inputs when `captureMIDI` is true (beat math shares the audio take's
    /// anchor; the punch window does NOT trim MIDI — v0). `audioURL == nil`
    /// with `captureMIDI` is a MIDI-only take: no file, no microphone, and
    /// the no-input watchdog stays unarmed (a note-less take is legal
    /// silence). Stopped via the same `stopRecording()`.
    func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                   completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws

    /// Stop capture AND playback, finalize the take file, and fire the
    /// startRecording completion. No-op when not recording.
    func stopRecording()

    /// MIDI input sources as CoreMIDI enumerates them (hot-plug refreshes the
    /// list). First call may lazily create the engine's MIDI client.
    func availableMIDIInputs() -> [MIDIInputDevice]

    /// Monotonic count of live MIDI note events received since the MIDI
    /// client came up (0 before then). Agents poll the delta to detect
    /// activity; the UI reads it as a cheap blinking-LED source.
    func midiEventCount() -> Int

    /// Latest master-mix analysis snapshot (M8 vm-a, session vibe meter):
    /// 24 log-spaced spectral bands (40 Hz → 16 kHz, dB, −80 floor),
    /// short-term RMS level, held peak, spectral centroid, normalized
    /// spectral flux — measured POST-master-fader (what you hear is what is
    /// analyzed). Poll-based like meters: the engine refreshes its cache at
    /// UI rate (~30–60 Hz) while running; when stopped or silent the values
    /// decay to `.floor` — never an error, never NaN/Inf. `.floor` for
    /// engines without analysis support.
    func masterAnalysis() -> MasterAnalysisSnapshot

    /// Render-load / overrun telemetry (M9 perf-b), accumulated per render
    /// callback by the engine's instrumented render blocks — live playback
    /// and the engine's own offline renders both count. Poll-based and
    /// window-scoped: `reset: false` reads the current window; `reset: true`
    /// returns the closing window's stats AND starts a fresh one (windowed
    /// profiling). Every field finite by contract; a stopped engine freezes
    /// the counters but the snapshot stays readable. `.idle` for engines
    /// without telemetry support.
    func performanceStats(reset: Bool) -> EnginePerformanceStats

    /// Engine watchdog state (M9 crash-c): the stall-detector reading the
    /// perf-b telemetry heartbeat — a frozen heartbeat while the engine
    /// claims to be running means the render side is dead, and the watchdog
    /// drives the same auto-restart the configuration-change path uses.
    /// Poll-based and headless-safe: never throws, `.idle` for engines
    /// without watchdog support.
    func watchdogStatus() -> EngineWatchdogStatus

    /// Output metering, delivered on the main actor at ~30-60 Hz while running.
    var meteringHandler: ((MeterFrame) -> Void)? { get set }

    /// Per-track output metering at UI rate while audio renders. Engine pushes
    /// .silence for every known track on stopPlayback.
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)? { get set }

    /// Engine-derived playhead in beats, pushed on the main actor at ~30 Hz
    /// while playing plus once on stop. Source of truth for
    /// transport.positionBeats during playback.
    var playheadHandler: ((Double) -> Void)? { get set }

    /// Engine-notices sink (m15-e): the engine pushes one event per
    /// schedule-time degradation (fade/envelope bake failure, stretch-pending
    /// silence, …), always on the main actor from control-side schedule code
    /// — the render thread gains nothing. Installed by `ProjectStore` (the
    /// `playheadHandler` shape), which owns the coalescing ring the wire and
    /// UI read. Optional capability: the default discards.
    var engineNoticeHandler: ((EngineNoticeEvent) -> Void)? { get set }
}

/// Audio Unit hosting and MIDI input are optional engine capability: defaults
/// keep existing conformers (test fakes, headless engines) compiling unchanged.
extension AudioEngineControlling {
    /// Per-clip gain is optional capability: engines without per-clip players
    /// pick the change up on the next `tracksDidChange` pass.
    public func clipGainChanged(trackID: UUID, clipID: UUID, gainDb: Double) {}

    /// Project-boundary engine replacement is optional capability (m13-a):
    /// fakes and headless engines have no once-rendered hardware graph to
    /// protect, so the default is a no-op.
    public func projectWillReplace() {}

    /// Live click toggling is optional capability (m14-c): engines without a
    /// click player pick the change up from the TransportState handed to the
    /// next start/seek, so the default is a no-op and existing conformers
    /// compile unchanged.
    public func metronomeChanged(_ transport: TransportState) {}

    /// The master insert chain is optional capability (m13-d, the
    /// `projectWillReplace` precedent): fakes and headless engines carry no
    /// master chain host, so the default is a no-op and existing conformers
    /// compile unchanged.
    public func masterEffectsChanged(_ effects: [EffectDescriptor]) {}

    /// Master volume automation is optional capability (m15-c, the
    /// `masterEffectsChanged` precedent): fakes and headless engines have no
    /// master fader to automate, so the default is a no-op and existing
    /// conformers compile unchanged.
    public func masterAutomationChanged(_ lanes: [AutomationLane]) {}

    /// Engine notices are optional capability (m15-e): engines without
    /// schedule-time degradation reporting (fakes, headless) discard the
    /// installed handler, so existing conformers compile unchanged.
    public var engineNoticeHandler: ((EngineNoticeEvent) -> Void)? {
        get { nil }
        set {}
    }

    /// Stretch rendering is optional capability: engines without it (fakes,
    /// headless) report nothing pending.
    public func clipStretchStatus(trackID: UUID, clipID: UUID) -> ClipStretchStatus? { nil }

    /// Transient analysis is optional capability: engines without it (fakes,
    /// headless) report no onsets.
    public func detectTransients(inFileAt url: URL, sensitivity: Double) async throws -> [TransientMarker] { [] }

    /// Insert chains are optional capability: engines without them report
    /// zero latency everywhere.
    public func insertChainLatencySamples(forTrack id: UUID) -> Int { 0 }
    public func effectLatencySamples(trackID: UUID, effectID: UUID) -> Int { 0 }
    public func masterEffectLatencySamples(effectID: UUID) -> Int { 0 }
    public func pdcReport() -> PDCReport? { nil }

    public func availableAudioUnits() -> [AudioUnitComponentInfo] { [] }
    public func audioUnitStatus(forTrack id: UUID) -> AudioUnitTrackStatus? { nil }
    public func audioUnitEffectStatus(forEffect id: UUID) -> AudioUnitTrackStatus? { nil }
    public func instrumentState(forTrack id: UUID) -> Data? { nil }
    public func availableAudioUnitEffects() -> [AudioUnitComponentInfo] { [] }
    public func effectState(forEffect id: UUID) -> Data? { nil }

    /// Default: audio-only engines forward audio takes to the legacy
    /// `startRecording` (midi side nil); a MIDI-only take is unsupported.
    public func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                          completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
        guard let audioURL else {
            throw ProjectError.recordingFailed("MIDI capture unsupported by this engine")
        }
        try startRecording(transport, to: audioURL) { result in
            completion(result.map { TakeResult(audio: $0, midi: nil) })
        }
    }

    public func availableMIDIInputs() -> [MIDIInputDevice] { [] }
    public func midiEventCount() -> Int { 0 }

    /// Master-mix analysis is optional capability: engines without it
    /// (fakes, headless) sit on the floor snapshot.
    public func masterAnalysis() -> MasterAnalysisSnapshot { .floor }

    /// Performance telemetry is optional capability: engines without it
    /// (fakes, headless) report the all-zero window.
    public func performanceStats(reset: Bool) -> EnginePerformanceStats { .idle }

    /// The engine watchdog is optional capability: engines without one
    /// (fakes, headless) report the zero/idle status.
    public func watchdogStatus() -> EngineWatchdogStatus { .idle }

    /// Buffer-out offline rendering is optional capability (M5 iv-b):
    /// engines without it (fakes, headless) refuse readably instead of
    /// pretending a silent render happened.
    public func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                              masterEffects: [EffectDescriptor],
                              masterAutomation: [AutomationLane],
                              fromBeat: Double, durationSeconds: Double,
                              forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        throw ProjectError.engineUnavailable
    }

    /// Engines without insert support have nothing to compensate: the empty
    /// plan (every strip's forced target then reads `[:][id] ?? 0`, correct).
    public func offlineCompensationTargets(tracks: [Track]) async -> [UUID: Int] { [:] }

    /// File writing is optional capability alongside `renderOffline`.
    public func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        throw ProjectError.engineUnavailable
    }
}
