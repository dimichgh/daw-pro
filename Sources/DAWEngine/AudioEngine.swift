import AVFAudio
import AudioToolbox
import DAWCore
import Foundation

/// M1 engine: sample-accurate multitrack playback through a per-track /
/// per-clip node graph, plus master metering and the M0 test tone. All engine
/// capability is exposed through `AudioEngineControlling`; AVFoundation types
/// must not leak out of this module.
///
/// DELIBERATE BOUNDARY EXCEPTION (M3 vi-b): the two
/// `hostedInstrumentAudioUnit(forTrack:)` / `hostedEffectAudioUnit(forEffect:)`
/// accessors return `AUAudioUnit` — the one sanctioned AudioToolbox type on this
/// module's public surface. Plugin-view hosting is definitionally
/// `AUAudioUnit`-shaped, so the app layer needs the live instance to attach a
/// window; the exception is concrete-class-only (NOT on `AudioEngineControlling`)
/// and control-plane-only. DAWApp already links the audio frameworks, so no
/// packaging change follows. Recorded in docs/ARCHITECTURE.md.
@MainActor
public final class AudioEngine: AudioEngineControlling {
    private let engine = AVAudioEngine()
    /// Internal (not private) so engine-level tests can pin graph facts the
    /// recovery paths guarantee (retire-bin drained, strips present) — the
    /// `auRegistry` seam precedent. Never reached from outside the module.
    let graph: PlaybackGraph
    /// Hosted Audio Unit lifecycle for the LIVE graph (offline renders build
    /// their own registry — fresh AU instances per render).
    let auRegistry = AUHostRegistry()
    /// Engine-side idempotency for AU preparation: the config each track's
    /// prepare Task was last spawned for, so repeated `tracksDidChange` passes
    /// never double-spawn while one is in flight.
    private var auDesired: [UUID: AUHostRegistry.PrepareKey] = [:]
    /// The insert-effect mirror of `auDesired`: the config each effect's
    /// prepare Task was last spawned for, keyed by effect id.
    private var auEffectDesired: [UUID: AUHostRegistry.PrepareKey] = [:]
    /// Offline stretch-render cache + job model (M5 ii-d). `var` internal so
    /// tests can point it at a temp directory before use — the resolver and
    /// mixdown paths read it dynamically through self.
    var stretchCache = StretchRenderCache()
    /// The stretch mirror of `auDesired`: the params each clip's render kick
    /// was last spawned for, so repeated reconcile passes never double-spawn
    /// (the cache coalesces same-key jobs anyway; this also dedupes the
    /// completion-restart wrapper) and a FAILED render is not retried until
    /// the params change (spec §5: retry by re-editing).
    private var stretchDesired: [UUID: StretchRenderCache.Params] = [:]
    /// Offline transient-map cache (M5 iii-e). `var` internal so tests can
    /// point it at a temp directory before use — the same seam as
    /// `stretchCache`. Analysis runs in the cache's detached task; nothing
    /// here touches the render thread or the live graph.
    var transientCache = TransientCache()
    private let tonePlayer = AVAudioPlayerNode()
    private var toneBuffer: AVAudioPCMBuffer?
    private var meterTapInstalled = false
    /// Master-mix analyzer (M8 vm-a) — created once alongside the meter tap
    /// (AVFoundation allows ONE tap per bus, so analysis rides inside the
    /// same closure). Its DSP state is touched ONLY on the tap queue; the
    /// produced snapshot VALUE hops to the main actor exactly like
    /// `MeterFrame`s do. `reset()` happens only in `shutdown()`, after the
    /// tap is removed (per its threading contract).
    private var masterAnalyzer: MasterMixAnalyzer?
    /// Main-actor cache of the latest analysis snapshot, refreshed at tap
    /// rate while the engine runs and polled by `masterAnalysis()`.
    private var latestMasterAnalysis: MasterAnalysisSnapshot = .floor
    private var configObserver: (any NSObjectProtocol)?
    /// Render-load telemetry (M9 perf-b): ONE context per engine, wired into
    /// the live graph's nodes at creation and handed to every
    /// `renderOffline` pass (offline bounces count — that is the headless
    /// test seam). Read/reset only here, on the main actor, via
    /// `performanceStats(reset:)`.
    private let performance = EnginePerformanceContext()

    // MARK: Engine watchdog (M9 crash-c)

    /// Stall detector over the telemetry heartbeat. All three readers are
    /// control-plane only: the heartbeat is one load-acquire on the perf
    /// context's lifetime callback cell (the `performanceStats` reader
    /// discipline — never touches render-thread code), the running check is
    /// main-actor bookkeeping AND the graph's instrumented-strip census
    /// (zero strips = no heartbeat producer exists, so a running-but-empty
    /// session is "no signal expected", never a stall), and restart is the
    /// shared config-change recovery. Known accepted imprecision: a
    /// concurrent offline render bumps the same shared context, which can
    /// only DELAY detection — never false-positive.
    private lazy var watchdog = EngineWatchdog(
        heartbeat: { [weak self] in
            self.map { Int(clamping: $0.performance.lifetimeCallbackCount()) } ?? 0
        },
        isEngineRunning: { [weak self] in
            guard let self else { return false }
            return self.isRunning && self.graph.hasInstrumentedStrips
        },
        restart: { [weak self] in try self?.watchdogRestart() }
    )

    /// The watchdog check loop (the `ProjectStore.startCrashAutosave` task
    /// idiom): started idempotently by `prepare()`, cancelled in
    /// `shutdown()`. Nil until the engine first starts.
    private var watchdogTask: Task<Void, Never>?

    /// Check interval — 2 s default ≈ 4 s worst-case stall detection at the
    /// 2-check threshold. Internal so tests could tune it before `prepare()`;
    /// the state machine itself is interval-independent (pure tick logic).
    var watchdogInterval: Duration = .seconds(2)

    // MARK: Transport state machine (idle ⇄ playing)

    /// Set while playing; nil when idle. Beats derive from the output node's
    /// sample clock against this anchor (host clock as fallback).
    private struct PlaybackAnchor {
        let startBeats: Double
        let tempoBPM: Double
        let anchorSampleTime: AVAudioFramePosition
        let anchorHostTime: UInt64
        let outputSampleRate: Double
        /// False when the anchor had to be host-clock-only (no valid
        /// lastRenderTime at start) — derivedBeats then skips the sample path.
        let hasSampleAnchor: Bool
    }

    private var currentAnchor: PlaybackAnchor?
    private var lastKnownBeats: Double = 0
    private var playheadTask: Task<Void, Never>?

    // MARK: Recording state (one take at a time)

    /// Everything a rolling take owns. The engine records at most ONE audio
    /// file (nil for MIDI-only takes) and knows nothing about tracks —
    /// ProjectStore fans the finished take out.
    private struct ActiveTake {
        let writer: RecordingWriter?
        let capture: InputCapture?
        let capturingMIDI: Bool
        let completion: @MainActor (Result<TakeResult, Error>) -> Void
    }

    private var activeTake: ActiveTake?

    // MARK: MIDI input (M3 vii)

    /// Lazily created on the first instrument-track arm or the first
    /// `availableMIDIInputs()` call; disposed in `shutdown()`. Nil until then.
    private var midiInput: MIDIInputManager?
    /// True after a failed CoreMIDI client creation (sandboxed CI) — don't
    /// retry on every snapshot.
    private var midiInputUnavailable = false

    /// Host-tick → seconds factor for the MIDI capture session's beat math
    /// (same conversion the renderers precompute).
    private static let hostTicksToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase.denom == 0
            ? 1e-9
            : Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }()

    /// First-buffer watchdog for the active take: armed by startRecording,
    /// cancelled by stopRecording. A take whose writer never sees a single
    /// tap delivery is dead input plumbing, not silence (silent input still
    /// produces buffers) — abort loudly instead of finalizing a silent empty
    /// take, which is exactly how the 2026-07-05 pinned-device bug hid.
    private var recordingWatchdog: Task<Void, Never>?

    /// How long a take may roll with ZERO tap deliveries before it aborts.
    /// Generous against the measured reality (first buffer lands well under
    /// 200 ms on healthy devices, including across the benign post-pin
    /// reconfigure), tight enough that a dead device fails fast.
    private static let firstBufferWatchdogSeconds = 1.5

    /// UID of the input device pinned for capture; nil = system default.
    /// Survives across takes — every startRecording applies the current
    /// selection to its fresh InputCapture.
    private var selectedInputUID: String?

    // MARK: Loop state (cached from transport intents; read by the playhead task)

    private var loopEnabled = false
    private var loopStartBeat: Double = 0
    private var loopEndBeat: Double = 16

    // MARK: Metronome state (cached from transport intents, like loop state)

    private let metronome = Metronome()
    private var metronomeEnabled = false
    private var beatsPerBar = 4
    private var countInBars = 0

    /// Master output gain 0...2, cached so a value set before the engine first
    /// starts is re-applied in `prepare()`.
    private var masterVolume: Double = 1

    /// Last domain track list, cached because engine.start() (re)initializes
    /// mixer input-bus parameters — a pan set before the first start is
    /// discarded (measured offline: pre-start pan -1 rendered dead center).
    /// Every start path re-applies parameters from this.
    private var lastTracks: [Track] = []

    /// Lead time between "now" and the shared player start anchor: long enough
    /// to cover a render quantum + scheduling jitter, short enough to feel
    /// immediate.
    private static let startLeadSeconds = 0.06

    public private(set) var isRunning = false
    public private(set) var isTonePlaying = false
    /// Latched by the graph's `willMutateRoutingTopology` hook when a
    /// reconcile had to stop the running engine (live routing rewires are
    /// unsafe — see the hook wiring in `init`); consumed by `tracksDidChange`,
    /// which restarts the engine with the double-apply convention.
    private var engineStoppedForRoutingRewire = false
    /// Position + tempo captured when the routing-rewire hook wound down
    /// ACTIVE playback (quiescence-before-stop, see init); consumed by
    /// `tracksDidChange`, which resumes through the cold-start primitive
    /// (`startPlayers` + playhead task) after the engine is back up.
    private var resumeAfterRoutingRewire: (beats: Double, tempoBPM: Double)?
    public var meteringHandler: ((MeterFrame) -> Void)?
    public var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    public var playheadHandler: ((Double) -> Void)?

    public init() {
        graph = PlaybackGraph(engine: engine)
        // Telemetry context first — node creation (reconcile) captures it.
        graph.performance = performance
        // Hosted-AU tracks pull their prepared instrument from the registry;
        // nil (pending/missing/failed) falls back to the silent placeholder.
        graph.audioUnitProvider = { [auRegistry] track in
            auRegistry.preparedInstrument(forTrack: track.id)
        }
        // Hosted-AU insert effects likewise (M4 v): nil (pending/missing/
        // failed) falls back to the passthrough placeholder in the chain.
        graph.hostedEffectProvider = { [auRegistry] effectID in
            auRegistry.preparedEffect(forEffect: effectID)
        }
        // Per-track meter frames arrive here already on the main actor.
        graph.meterSink = { [weak self] trackID, frame in
            self?.trackMeteringHandler?(trackID, frame)
        }
        // Non-identity stretched clips resolve against the render cache at
        // reconcile time (M5 ii-d): cache hit → the CAF replaces the source;
        // miss → the clip schedules as silence and a debounced render job is
        // kicked, whose completion re-enters the tracksDidChange restart seam
        // (the AU async-prepare shape).
        graph.stretchResolver = { [weak self] clip in
            self?.resolveStretch(clip: clip) ?? .pending
        }
        // Routing rewires (fan-out re-issue, send-gain/bus teardown) are not
        // safe against a running AVAudioEngine — measured live: a mid-play
        // send add renders its new gain→bus branch SILENT, and removing a
        // live bus SEGFAULTs the render thread. The graph announces the
        // first such mutation of a pass; the engine leaves the running state
        // so the wiring mutates stopped (the offline renderer's proven build
        // order), and tracksDidChange restarts it right after reconcile with
        // the double-apply convention. Trivial track adds never announce,
        // so recording/capture survives those unchanged.
        //
        // QUIESCENCE FIRST (measured live, second E2E round): stopping the
        // engine mid-render with live schedules still published — then
        // rewiring, restarting, and resuming players inline under the still-
        // set anchor — left the new fan-out leg permanently silent even
        // though the topology was correct (a later plain transport stop/play
        // made the SAME leg audible through the SAME startPlayers code). The
        // two live-proven lifecycles both stop/start the engine around a
        // QUIESCENT graph: cold start (wire → start → startPlayers) and a
        // transport cycle (full stopPlayback, then startPlayers). So active
        // playback winds down exactly like stopPlayback BEFORE the engine
        // stops (position/tempo captured), and tracksDidChange resumes via
        // the same cold-start primitive a transport start uses.
        graph.willMutateRoutingTopology = { [weak self] in
            guard let self, self.engine.isRunning else { return }
            if let anchor = self.currentAnchor {
                self.resumeAfterRoutingRewire =
                    (beats: self.derivedBeats(), tempoBPM: anchor.tempoBPM)
                self.playheadTask?.cancel()
                self.playheadTask = nil
                self.graph.stopAllPlayers()
                self.metronome.stop()
                self.currentAnchor = nil
            }
            self.engine.stop()
            self.engineStoppedForRoutingRewire = true
        }
        // Device switches / sample-rate changes tear down the running graph.
        // @Sendable is load-bearing (same trap as the meter tap): the closure
        // fires on a non-main thread, so hop to the main actor before touching
        // any engine state.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }
    }

    // No deinit: Swift 6 forbids touching the non-Sendable observer token from
    // a nonisolated deinit. The observer is removed in shutdown() (app-exit
    // path); its block captures self weakly, so a never-shut-down test engine
    // leaks only the token, never the engine.

    public func prepare() throws {
        guard !isRunning else { return }
        // Touching mainMixerNode implicitly wires mixer -> output.
        let mixer = engine.mainMixerNode
        installMeterTap(on: mixer)
        // Lazy metronome attach: the player joins the graph once, whether or
        // not the click is enabled — scheduling decides whether it sounds.
        metronome.attach(to: engine)
        engine.prepare()
        try engine.start()
        isRunning = true
        // M9 crash-a: from here on, node detaches against a STOPPED engine
        // are unsafe (once-rendered nodes leave stale entries in
        // AVFoundation's graph bookkeeping — docs/research/
        // fix-teardown-crash.md); the graph defers them to its bin, drained
        // against the running engine after every start.
        graph.engineHasRun = true
        graph.flushRetiredNodes()
        // Mixer parameters land AFTER start(): values set while the engine was
        // stopped (master volume, track pan/volume/mute/solo) must stick.
        mixer.outputVolume = Float(masterVolume)
        graph.applyParameters(tracks: lastTracks, playheadBeat: lastKnownBeats)
        // M9 crash-c: a successful start re-arms a given-up watchdog (the
        // only exit from `.failed`) and starts the check loop (idempotent).
        watchdog.reset()
        startWatchdog()
    }

    public func shutdown() {
        // Watchdog first: teardown is an INTENTIONAL stop, never a stall.
        watchdogTask?.cancel()
        watchdogTask = nil
        stopTestTone()
        if activeTake != nil {
            stopRecording()  // finalizes the take (and stops playback) first
        }
        if currentAnchor != nil {
            stopPlayback()
        }
        midiInput?.dispose()
        midiInput = nil
        metronome.stop()  // idempotent; covers a never-started transport
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if meterTapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            meterTapInstalled = false
        }
        engine.stop()
        isRunning = false
        meteringHandler?(.silence)
        // Tap removed + engine stopped: safe to reset the analyzer (its
        // threading contract), and the published snapshot floors like the
        // meter silence push above.
        masterAnalyzer?.reset()
        latestMasterAnalysis = .floor
    }

    // MARK: - Transport intents

    public func startPlayback(_ transport: TransportState) {
        cacheTransportFlags(from: transport)
        guard currentAnchor == nil else { return }  // already playing
        if !isRunning {
            do {
                try prepare()
            } catch {
                FileHandle.standardError.write(
                    Data("AudioEngine: startPlayback could not start hardware: \(error)\n".utf8)
                )
                return
            }
        }
        startPlayers(fromBeat: transport.positionBeats, tempoBPM: transport.tempoBPM)
        startPlayheadTask()
    }

    public func stopPlayback() {
        guard currentAnchor != nil else { return }
        let beats = derivedBeats()
        lastKnownBeats = beats
        playheadTask?.cancel()
        playheadTask = nil
        graph.stopAllPlayers()
        metronome.stop()
        currentAnchor = nil
        // Meters go dark immediately — the taps stop firing once players stop,
        // so without this push the UI would freeze at the last level.
        for trackID in graph.trackIDs {
            trackMeteringHandler?(trackID, .silence)
        }
        // One final render-derived playhead update so the transport lands
        // exactly where audio stopped.
        playheadHandler?(beats)
        // Stopped WYSIWYG (M4 vii-b): the override pins (gain 1 / pan 0)
        // hand back to lane-value previews at the exact stop position.
        graph.applyParameters(tracks: lastTracks, playheadBeat: beats)
    }

    public func seek(_ transport: TransportState) {
        cacheTransportFlags(from: transport)
        guard currentAnchor != nil else { return }  // stopped: position arrives with next start
        restart(fromBeat: transport.positionBeats, tempoBPM: transport.tempoBPM)
    }

    public func setTempo(_ transport: TransportState) {
        cacheTransportFlags(from: transport)
        guard currentAnchor != nil else { return }
        // Engine-derived beats are authoritative here — the incoming
        // transport.positionBeats can be a display-stale ~33 ms behind.
        let beats = derivedBeats()
        restart(fromBeat: beats, tempoBPM: transport.tempoBPM)
        lastKnownBeats = beats
        playheadHandler?(beats)
    }

    /// Live per-clip gain (M5 i-b): dB → linear onto the clip player's input
    /// gain, in place — no reconcile, no restart, playback never interrupted.
    /// The store follows with `tracksDidChange`, whose parameter pass writes
    /// the same value (same-value volume writes don't ramp) and keeps
    /// `lastTracks` fresh for later restarts.
    public func clipGainChanged(trackID: UUID, clipID: UUID, gainDb: Double) {
        graph.setClipGain(trackID: trackID, clipID: clipID,
                          linear: Float(pow(10.0, gainDb / 20.0)))
    }

    public func tracksDidChange(_ tracks: [Track]) {
        lastTracks = tracks
        // AU sync FIRST: a stale hosted instrument is released before
        // reconcile rebuilds its node, so the provider hands the placeholder
        // (never an instrument for the wrong component) to the fresh node.
        syncAudioUnitInstruments(tracks)
        // Insert-effect AUs too — before applyParameters below syncs chains,
        // so a stale hosted effect is already released/invalidated and the
        // chain installs the placeholder, never the wrong component.
        syncAudioUnitEffects(tracks)
        // Stretch bookkeeping (M5 ii-d): drop render state for clips that
        // left the model or returned to identity, cancelling in-flight jobs.
        // The reconcile below then resolves the survivors (kicking renders
        // for fresh param edits through the graph's stretchResolver).
        syncStretchRenders(tracks)
        let changed = graph.reconcile(tracks: tracks)
        // A routing rewire stopped the engine mid-reconcile (see the hook in
        // init): bring it back with the SAME double-apply order the offline
        // renderer and prepare() use — master volume + all track/send-gain
        // volumes land pre-start (stick from frame 0, no ramp), pan re-lands
        // post-start via the unconditional applyParameters below.
        if engineStoppedForRoutingRewire {
            engineStoppedForRoutingRewire = false
            engine.mainMixerNode.outputVolume = Float(masterVolume)
            graph.applyParameters(tracks: tracks, playheadBeat: lastKnownBeats)
            // reset() re-initializes every node before start, making the
            // bounce maximally cold-start-like — the one live-proven shape
            // for bringing freshly wired fan-out legs up (see the hook
            // rationale in init).
            engine.reset()
            do {
                try engine.start()
                // Nodes torn down while the engine sat stopped mid-pass
                // retire NOW, against the running engine (M9 crash-a — see
                // prepare()).
                graph.flushRetiredNodes()
            } catch {
                isRunning = false
                FileHandle.standardError.write(Data(
                    "AudioEngine: restart after routing rewire failed: \(error)\n".utf8))
            }
        }
        // Parameters land on every invocation: volume/pan/mute/solo changes are
        // mixer-parameter writes that must never interrupt audio, and freshly
        // reconciled nodes need their current parameters too. (Automation
        // lane edits land here too: while rolling this pass republishes the
        // strip's schedule in place — never a restart.)
        graph.applyParameters(tracks: tracks, playheadBeat: lastKnownBeats)
        // MIDI thru fanout AFTER reconcile: armed instrument tracks' renderers
        // exist (or were rebuilt) by now.
        syncMIDIThruFanout(tracks)
        // isRunning guard: if the post-rewire engine restart failed (device
        // gone), players must not be started against a dead engine — the
        // configuration-change path owns recovery.
        if changed, isRunning, let anchor = currentAnchor {
            // Structural change WITHOUT an engine bounce (clip edits etc.):
            // the pre-M4 player-only restart, unchanged.
            restart(fromBeat: derivedBeats(), tempoBPM: anchor.tempoBPM)
        }
        if let resume = resumeAfterRoutingRewire {
            // A routing rewire interrupted active playback (the hook wound
            // the transport down to quiescence before stopping the engine —
            // currentAnchor is nil, so the restart above was skipped).
            // Resume through the SAME primitive a cold transport start uses:
            // schedule + anchor + players + playhead task, against the now
            // freshly started, quiescent engine. renderClockTrusted: false is
            // load-bearing — the just-bounced engine still reports the OLD
            // render session's sample clock (see startPlayers), and anchoring
            // on it froze the playhead for the previous session's length:
            // the actual mechanism behind "a mid-play send stays silent
            // until stop/play" (M4 i, pinned live 2026-07-06).
            resumeAfterRoutingRewire = nil
            if isRunning {
                startPlayers(fromBeat: resume.beats, tempoBPM: resume.tempoBPM,
                             renderClockTrusted: false)
                startPlayheadTask()
            }
        }
    }

    /// Republishes the live-thru fanout with every ARMED instrument track's
    /// renderer (multiple armed tracks all sound — standard layering). Lazily
    /// creates the MIDI input manager on the first armed instrument track.
    /// Every renderer REMOVED from the fanout gets `requestFlush()` (the
    /// all-notes-off contract) — covers disarm, track switch, track removal,
    /// and node rebuilds. A ≤1-quantum straggler event after republish is
    /// accepted (killed by the flush next quantum).
    private func syncMIDIThruFanout(_ tracks: [Track]) {
        let armedRenderers = tracks
            .filter { $0.kind == .instrument && $0.isArmed }
            .compactMap { graph.instrumentRenderer(forTrack: $0.id) }
        if armedRenderers.isEmpty, midiInput == nil { return }  // stay lazy
        guard let midi = ensureMIDIInput() else { return }
        let previous = midi.fanoutRenderers
        let previousIDs = Set(previous.map(ObjectIdentifier.init))
        let nextIDs = Set(armedRenderers.map(ObjectIdentifier.init))
        guard previousIDs != nextIDs else { return }  // no churn on parameter edits
        midi.publishFanout(renderers: armedRenderers)
        for renderer in previous where !nextIDs.contains(ObjectIdentifier(renderer)) {
            renderer.requestFlush()
        }
    }

    /// Lazy MIDI-input bring-up; nil (and remembered) when CoreMIDI is
    /// unavailable — e.g. a sandboxed CI runner without a MIDI server.
    private func ensureMIDIInput() -> MIDIInputManager? {
        if let midiInput { return midiInput }
        guard !midiInputUnavailable else { return nil }
        let manager = MIDIInputManager()
        guard manager.start() else {
            midiInputUnavailable = true
            return nil
        }
        midiInput = manager
        return manager
    }

    // MARK: - MIDI input surface

    public func availableMIDIInputs() -> [MIDIInputDevice] {
        ensureMIDIInput()?.devices ?? []
    }

    public func midiEventCount() -> Int {
        midiInput?.eventCount ?? 0
    }

    /// Reconciles the AU registry with the track list: releases instruments
    /// for tracks that no longer host an AU, and spawns one async prepare Task
    /// per `.audioUnit` track whose configuration isn't already prepared or in
    /// flight. Until a prepare lands, the track renders the silent
    /// placeholder; on success the node is invalidated and `tracksDidChange`
    /// re-enters to rebuild it with the real instrument.
    private func syncAudioUnitInstruments(_ tracks: [Track]) {
        let graphRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = graphRate > 0 ? graphRate : 48_000

        var auTracks: [UUID: Track] = [:]
        for track in tracks
        where track.kind == .instrument && (track.instrument ?? .default).kind == .audioUnit {
            auTracks[track.id] = track
        }

        // Tracks that stopped hosting an AU (removed, kind switch): drop the
        // instrument. Node teardown is reconcile's job (kind/component is in
        // the structural key); a tail render against the deallocated AU is
        // covered by the adapter's error path (zero-fill, no trap).
        for id in auRegistry.knownTrackIDs where auTracks[id] == nil {
            auRegistry.releaseInstrument(forTrack: id)
            auDesired[id] = nil
        }
        auDesired = auDesired.filter { auTracks[$0.key] != nil }

        for (id, track) in auTracks {
            let key = track.instrument?.audioUnit.map {
                AUHostRegistry.PrepareKey(component: $0.component,
                                          sampleRate: sampleRate,
                                          stateData: $0.stateData)
            }
            guard auDesired[id] != key else { continue }  // already prepared or in flight
            auDesired[id] = key
            if auRegistry.needsPrepare(track: track, sampleRate: sampleRate) {
                // Stale instrument (config changed) goes away NOW so the node
                // rebuilt below renders the placeholder, not the old plugin.
                auRegistry.releaseInstrument(forTrack: id)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.auRegistry.prepare(track: track, sampleRate: sampleRate)
                    guard self.auRegistry.preparedInstrument(forTrack: id) != nil,
                          self.auDesired[id] == key else { return }
                    self.graph.invalidateInstrumentNode(trackID: id)
                    self.tracksDidChange(self.lastTracks)
                }
            }
        }
    }

    /// Reconciles the AU registry with every track's insert chain (M4 v):
    /// releases effects that left the model, and spawns one async prepare
    /// Task per `.audioUnit` effect whose configuration isn't already
    /// prepared or in flight. Until a prepare lands, the chain runs the
    /// passthrough placeholder; on success the ONE strip's chain state is
    /// invalidated and re-synced (an atomic snapshot republish) — never a
    /// graph rebuild, never a playback interruption.
    private func syncAudioUnitEffects(_ tracks: [Track]) {
        let graphRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = graphRate > 0 ? graphRate : 48_000

        var auEffects: [UUID: (trackID: UUID, config: AudioUnitConfig)] = [:]
        for track in tracks {
            for effect in track.effects
            where effect.kind == .audioUnit && effect.audioUnit != nil {
                auEffects[effect.id] = (track.id, effect.audioUnit!)
            }
        }

        // Effects that left the model (removed, or track deleted): drop the
        // hosted instance. The chain republish (applyParameters, same pass)
        // stops walking it; a straggler render against the deallocated AU is
        // covered by the adapter's error path (dry passthrough, no trap).
        for id in auRegistry.knownEffectIDs where auEffects[id] == nil {
            auRegistry.releaseEffect(forEffect: id)
            auEffectDesired[id] = nil
        }
        auEffectDesired = auEffectDesired.filter { auEffects[$0.key] != nil }

        for (id, entry) in auEffects {
            let key = AUHostRegistry.PrepareKey(component: entry.config.component,
                                                sampleRate: sampleRate,
                                                stateData: entry.config.stateData)
            guard auEffectDesired[id] != key else { continue }  // prepared or in flight
            auEffectDesired[id] = key
            guard auRegistry.effectNeedsPrepare(effectID: id, config: entry.config,
                                                sampleRate: sampleRate) else { continue }
            // Stale instance (config changed) goes away NOW so the chain
            // re-synced below walks the placeholder, not the old plugin.
            auRegistry.releaseEffect(forEffect: id)
            graph.effectChainState(forTrack: entry.trackID)?.invalidateEffect(id: id)
            let trackID = entry.trackID
            let config = entry.config
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.auRegistry.prepareEffect(effectID: id, config: config,
                                                    sampleRate: sampleRate)
                guard self.auRegistry.preparedEffect(forEffect: id) != nil,
                      self.auEffectDesired[id] == key else { return }
                // Republish the ONE strip: drop the placeholder unit, then a
                // parameters-only pass re-syncs it with the real instance.
                self.graph.effectChainState(forTrack: trackID)?.invalidateEffect(id: id)
                self.graph.applyParameters(tracks: self.lastTracks,
                                           playheadBeat: self.lastKnownBeats)
            }
        }
    }

    // MARK: - Stretch renders (M5 ii-d)

    /// The graph's reconcile-time resolver for one NON-IDENTITY clip:
    /// committed cache entry → `.ready` (the CAF replaces the source file);
    /// otherwise kick (or keep) the render job and answer `.pending` — the
    /// clip schedules as silence, never wrong-speed audio.
    private func resolveStretch(clip: Clip) -> PlaybackGraph.StretchResolution {
        guard let source = clip.audioFileURL else { return .pending }
        let params = StretchRenderCache.Params(clip: clip)
        if let rendered = stretchCache.cachedURL(source: source, params: params) {
            return .ready(rendered)
        }
        kickStretchRender(clipID: clip.id, source: source, params: params)
        return .pending
    }

    /// Fire-and-forget render kick with completion restart (the
    /// `syncAudioUnitInstruments` async-prepare shape): at most one wrapper
    /// per (clip, params) — the guard also stops a FAILED render from
    /// re-spawning every reconcile pass; a param edit (new params) retries.
    private func kickStretchRender(clipID: UUID, source: URL,
                                   params: StretchRenderCache.Params) {
        guard stretchDesired[clipID] != params else { return }
        stretchDesired[clipID] = params
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.stretchCache.renderIfNeeded(
                    clipID: clipID, source: source, params: params)
            } catch {
                return  // superseded or failed — status(forClip:) carries it
            }
            guard self.stretchDesired[clipID] == params else { return }  // stale
            // M3 vi-a precedent: invalidate the clip's schedule entry, then
            // re-enter tracksDidChange — reconcile opens the rendered CAF and
            // the existing restart seam resumes playback with it.
            self.graph.invalidateClipSchedule(clipID: clipID)
            self.tracksDidChange(self.lastTracks)
        }
    }

    /// Prunes per-clip stretch state for clips that no longer exist or are
    /// back to identity params, cancelling their in-flight jobs.
    private func syncStretchRenders(_ tracks: [Track]) {
        guard !stretchDesired.isEmpty else { return }
        var live: Set<UUID> = []
        for track in tracks where track.kind == .audio {
            for clip in track.clips where !clip.isStretchIdentity {
                live.insert(clip.id)
            }
        }
        for clipID in stretchDesired.keys where !live.contains(clipID) {
            stretchDesired[clipID] = nil
            stretchCache.cancelJob(forClip: clipID)
        }
    }

    /// Pull-based stretch status for the control snapshot (spec §5). trackID
    /// is accepted for surface stability; the cache keys jobs per clip.
    public func clipStretchStatus(trackID: UUID, clipID: UUID) -> ClipStretchStatus? {
        stretchCache.status(forClip: clipID)
    }

    /// Offline transient analysis (M5 iii-e): content-key cached spectral-flux
    /// onsets over the WHOLE source file, in source-file seconds. The cache
    /// runs the analyzer in a detached task — zero render-thread involvement,
    /// zero live-graph involvement; playback is untouched whether or not it
    /// is running.
    public func detectTransients(inFileAt url: URL, sensitivity: Double) async throws -> [TransientMarker] {
        try await transientCache.markers(source: url, sensitivity: sensitivity)
    }

    /// Total fixed insert-chain latency for one track's strip, in samples at
    /// the graph rate (non-bypassed effects only) — the M4 (viii) PDC hook.
    public func insertChainLatencySamples(forTrack id: UUID) -> Int {
        graph.chainLatencySamples(forTrack: id)
    }

    /// Fixed latency of ONE live insert-effect instance (240 @ 48 kHz for the
    /// limiter's lookahead, 0 for the other built-ins and unknown ids) — feeds
    /// the per-effect `latencySamples` on the control snapshot.
    public func effectLatencySamples(trackID: UUID, effectID: UUID) -> Int {
        graph.effectLatencySamples(forTrack: trackID, effectID: effectID)
    }

    /// The latest PDC recompute report (M4 viii-c) — rebuilt by the graph at
    /// the tail of every parameter pass; nil until the first pass runs.
    public func pdcReport() -> PDCReport? {
        graph.pdcReport
    }

    public func masterVolumeChanged(_ volume: Double) {
        masterVolume = volume.clamped(to: Track.volumeRange)
        // mainMixerNode exists (and holds parameters) whether or not the
        // engine is running; prepare() re-applies the cached value regardless.
        engine.mainMixerNode.outputVolume = Float(masterVolume)
    }

    public func renderMixdown(tracks: [Track], tempoBPM: Double, masterVolume: Double,
                              fromBeat: Double, durationSeconds: Double,
                              to url: URL) async throws -> AudioFileInfo {
        // Refactored over the M5 iv-b buffer seam: render to memory (the
        // WYSIWYG stretch await and fresh-renderer rules live there), then
        // write — the exact composition `renderToWAV` performed, behavior
        // frozen (the existing mixdown/stretch suites are the proof).
        let audio = try await renderOffline(
            tracks: tracks, tempoBPM: tempoBPM, masterVolume: masterVolume,
            fromBeat: fromBeat, durationSeconds: durationSeconds,
            forcedCompensationTargets: nil
        )
        return try writeAudioFile(audio, to: url)
    }

    public func renderOffline(tracks: [Track], tempoBPM: Double, masterVolume: Double,
                              fromBeat: Double, durationSeconds: Double,
                              forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        // Stretch WYSIWYG (M5 ii-d): a bounce WAITS for pending stretch
        // renders — bouncing silence where the live transport will sound
        // audio moments later would violate what-you-hear-is-what-you-bounce.
        // The synchronous await (debounce included) is acceptable offline,
        // the same v0 stance as the main-actor render stall documented on
        // the protocol. Coalesces with any live in-flight job (same cache);
        // a FAILED render bounces silent, exactly matching live playback.
        for track in tracks where track.kind == .audio {
            for clip in track.clips where !clip.isStretchIdentity {
                guard let source = clip.audioFileURL else { continue }
                _ = try? await stretchCache.renderIfNeeded(
                    clipID: clip.id, source: source,
                    params: StretchRenderCache.Params(clip: clip))
            }
        }
        // A fresh OfflineRenderer builds its own AVAudioEngine + PlaybackGraph
        // AND its own AU registry (fresh AU instances per render); the live
        // graph (hardware clock, players, meter taps, live AU instruments) is
        // never touched, so bouncing is safe whether or not playback is running.
        let renderer = OfflineRenderer()
        // Offline pulls stamp THIS engine's telemetry context (M9 perf-b):
        // a headless bounce is render work and counts in performanceStats.
        renderer.performance = performance
        // Pure cache lookup — every render either committed above or failed
        // (nil → the clip bounces silent; never wrong-speed audio).
        renderer.stretchedFileProvider = { [stretchCache] clip in
            guard let source = clip.audioFileURL else { return nil }
            return stretchCache.cachedURL(
                source: source, params: StretchRenderCache.Params(clip: clip))
        }
        // Non-nil = a stem pass forcing the FULL-SESSION plan (spec §1.1) so
        // subset renders stay sample-aligned with the mix; nil = the always-on
        // automatic plan, exactly what renderMixdown always did.
        renderer.compensationTargets = forcedCompensationTargets
        await renderer.prepareAudioUnits(tracks: tracks)
        return try renderer.render(
            tracks: tracks, tempoBPM: tempoBPM, fromBeat: fromBeat,
            durationSeconds: durationSeconds, masterVolume: masterVolume
        )
    }

    public func offlineCompensationTargets(tracks: [Track]) async -> [UUID: Int] {
        // A planning OfflineRenderer prepares the session's AUs (their hosted
        // latency is part of the plan), then builds the offline graph and runs
        // one parameter pass without rendering — parity with a real render
        // pass by construction (spec §5), asserted by test.
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: tracks)
        return renderer.compensationPlanTargets(tracks: tracks)
    }

    public func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        try OfflineRenderer.writeWAV(audio, to: url)
    }

    // MARK: - Audio Unit hosting surface

    public func availableAudioUnits() -> [AudioUnitComponentInfo] {
        AUHostRegistry.listMusicDevices()
    }

    public func audioUnitStatus(forTrack id: UUID) -> AudioUnitTrackStatus? {
        auRegistry.status[id]
    }

    /// Effect mirror of `audioUnitStatus(forTrack:)` — feeds the plugin-window
    /// open-failure error (pending/missing/failed reason). Additive on
    /// `AudioEngineControlling` with a nil default.
    public func audioUnitEffectStatus(forEffect id: UUID) -> AudioUnitTrackStatus? {
        auRegistry.effectStatus[id]
    }

    public func instrumentState(forTrack id: UUID) -> Data? {
        auRegistry.instrumentState(forTrack: id)
    }

    // MARK: - Plugin-view hosting surface (M3 vi-b, CONTROL-PLANE ONLY)

    /// The live, sounding `AUAudioUnit` for a track's hosted instrument — the
    /// same object whose captured `renderBlock` the graph pulls — or nil unless
    /// the registry reports `.ready`. This accessor (and its effect twin) is the
    /// ONE sanctioned AudioToolbox type on DAWEngine's public surface: plugin-
    /// view hosting is definitionally `AUAudioUnit`-shaped. It is concrete-class-
    /// only (deliberately NOT on `AudioEngineControlling`), a documented
    /// exception to the module-leak rule (see the module doc). Callers MUST stay
    /// on the main actor and MUST NEVER reach the render-thread contract members.
    public func hostedInstrumentAudioUnit(forTrack id: UUID) -> AUAudioUnit? {
        auRegistry.preparedInstrument(forTrack: id)?.auAudioUnit
    }

    /// The effect twin of `hostedInstrumentAudioUnit(forTrack:)` — the live
    /// hosted insert-effect AU, nil unless `.ready`. Same control-plane-only,
    /// main-actor-only contract.
    public func hostedEffectAudioUnit(forEffect id: UUID) -> AUAudioUnit? {
        auRegistry.preparedEffect(forEffect: id)?.auAudioUnit
    }

    /// The registry's `onRelease`, re-exposed for the app (M3 vi-b): fires on the
    /// main actor when a live instance is torn down (effect/track removal,
    /// instrument switch, project open/new, config/sample-rate re-prepare),
    /// BEFORE `deallocateRenderResources`, never for no-op releases. Engine
    /// recovery (`recoverEngine`/`watchdogRestart`) does NOT touch the registry,
    /// so plugin windows survive it. Forwarded straight through so the registry
    /// stays the single invalidation authority.
    public var hostedAUReleased: ((HostedAUEndpoint) -> Void)? {
        get { auRegistry.onRelease }
        set { auRegistry.onRelease = newValue }
    }

    public func availableAudioUnitEffects() -> [AudioUnitComponentInfo] {
        AUHostRegistry.listEffectComponents()
    }

    public func effectState(forEffect id: UUID) -> Data? {
        auRegistry.effectState(forEffect: id)
    }

    public func loopChanged(_ transport: TransportState) {
        // Cached only — the playhead task reads these bounds each tick and wraps
        // via the restart primitive. Enabling a loop whose region already sits
        // behind the playhead is safe: the next tick's `beats >= loopEndBeat`
        // check wraps it. Never touches live scheduling here.
        cacheTransportFlags(from: transport)
    }

    // MARK: - Recording

    public var recordPermission: RecordPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    public func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        // The OS callback arrives on an arbitrary queue — hop to the main
        // actor before handing the decision back.
        AVAudioApplication.requestRecordPermission { @Sendable granted in
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    /// All hardware devices currently offering input streams (CoreAudio
    /// property reads only — nothing starts, nothing blocks).
    public func availableInputDevices() -> [AudioInputDevice] {
        InputDevices.enumerate()
    }

    /// Pin capture to `uid` (validated against the live device list) or nil
    /// for the system default. Applies to the NEXT take — a rolling take is
    /// never re-routed (ProjectStore refuses the switch while recording).
    public func setInputDevice(uid: String?) throws {
        if let uid, InputDevices.deviceID(forUID: uid) == nil {
            throw ProjectError.inputDeviceNotFound(uid)
        }
        selectedInputUID = uid
    }

    /// Legacy audio-only surface: a thin wrapper over `startTake`.
    public func startRecording(_ transport: TransportState, to url: URL,
                               completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        try startTake(transport, audioURL: url, captureMIDI: false) { result in
            completion(result.flatMap { take in
                take.audio.map { .success($0) }
                    ?? .failure(EngineError.recordingFailed("take produced no audio result"))
            })
        }
    }

    public func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                          completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
        // Step order is load-bearing:
        // 1. Refuse while anything rolls — one take at a time, started from a
        //    stopped transport (punch windows trim the take, they don't drop
        //    capture into running playback).
        guard activeTake == nil, currentAnchor == nil else {
            throw EngineError.recordingFailed("already rolling")
        }
        // 2. Audio capture side first (only when the take wants audio): any
        //    input/file failure throws synchronously with no engine state
        //    change. Two-phase capture start: prepare() resolves/pins the
        //    device and returns the post-pin native format (the pinned
        //    device's rate/channels can differ from the system default's),
        //    the writer sizes from THAT, then start(writer:) installs the tap
        //    and starts I/O. MIDI-only takes never touch the microphone.
        var capture: InputCapture?
        var writer: RecordingWriter?
        if let audioURL {
            let audioCapture = InputCapture()
            audioCapture.deviceUID = selectedInputUID
            let inputFormat = try audioCapture.prepare()
            let audioWriter = try RecordingWriter(url: audioURL, inputFormat: inputFormat)
            try audioCapture.start(writer: audioWriter)
            capture = audioCapture
            writer = audioWriter
        }
        // 3. Existing playback path, verbatim.
        cacheTransportFlags(from: transport)
        if !isRunning {
            do {
                try prepare()
            } catch {
                capture?.stop()
                writer?.finalize { _ in }  // zero frames → the empty file is deleted
                throw error
            }
        }
        //    With countInBars > 0 the record anchor (currentAnchor) is DELAYED
        //    by the count-in duration; the metronome fills the gap with clicks
        //    (see startPlayers). Everything below reads the delayed anchor, so
        //    capture trims to the actual take start — the finished take
        //    excludes the count-in and clip placement math is unchanged.
        startPlayers(fromBeat: transport.positionBeats, tempoBPM: transport.tempoBPM,
                     countInBars: transport.countInBars)
        startPlayheadTask()
        // 4. Align the writer to the shared player-start anchor: capture
        //    before this host time is trimmed, so file frame 0 ≈ the moment
        //    playback (and the take) began. startPlayers always sets the anchor.
        //    With punch enabled, the accept window is [punchIn, punchOut]
        //    translated onto the host clock from that same anchor, and the
        //    REFERENCE stays the anchor: startOffsetSeconds then reports the
        //    anchor → punch-in gap, which ProjectStore's fan-out formula
        //    (recordStart + offset × tempo/60) turns into the punch-in beat.
        //    A window-relative offset (≈ 0) would land the clip at the record
        //    position — that was a live-E2E bug. punchOutBeat > positionBeats
        //    is a ProjectStore.record() precondition.
        let anchor = currentAnchor!
        if let writer {
            if transport.isPunchEnabled {
                let secondsPerBeat = 60.0 / transport.tempoBPM
                let startHost = anchor.anchorHostTime + AVAudioTime.hostTime(
                    forSeconds: max(0, transport.punchInBeat - transport.positionBeats) * secondsPerBeat
                )
                let endHost = anchor.anchorHostTime + AVAudioTime.hostTime(
                    forSeconds: (transport.punchOutBeat - transport.positionBeats) * secondsPerBeat
                )
                writer.setAcceptWindow(reference: anchor.anchorHostTime, start: startHost, end: endHost)
            } else {
                writer.setAcceptWindow(reference: anchor.anchorHostTime,
                                       start: anchor.anchorHostTime, end: nil)
            }
        }
        // 4b. MIDI capture rides the SAME anchor the writer aligns to — one
        //     clock for the whole take (count-in delay inherits for free; the
        //     session drops pre-anchor note-ons like the writer's trim). The
        //     punch window deliberately does NOT trim MIDI (v0): notes are
        //     individually editable after the fact. When CoreMIDI is
        //     unavailable the take proceeds without a session — it finalizes
        //     as an empty MIDI capture.
        if captureMIDI, let midi = ensureMIDIInput() {
            midi.drainCaptureRing()  // discard pre-take events queued while idle
            midi.captureSession = MIDICaptureSession(
                anchorHostTime: anchor.anchorHostTime,
                anchorBeats: anchor.startBeats,
                tempoBPM: anchor.tempoBPM,
                ticksToSeconds: Self.hostTicksToSeconds
            )
        }
        // 5. Stash the take; a FATAL input configuration change (device
        //    unplugged — InputCapture already filters out the benign post-pin
        //    reconfigure) ends it cleanly, and the first-buffer watchdog
        //    aborts loudly if the audio input never delivers at all. The
        //    watchdog arms ONLY when audio capture is active — a note-less
        //    MIDI take is legal silence.
        activeTake = ActiveTake(writer: writer, capture: capture,
                                capturingMIDI: captureMIDI, completion: completion)
        capture?.configurationChangeHandler = { [weak self] in
            self?.stopRecording()
        }
        if let writer {
            armFirstBufferWatchdog(for: writer)
        }
    }

    /// Arms the one-shot no-input watchdog for the take that owns `writer`.
    /// Checks buffer ARRIVAL, not content — legitimate silence still delivers
    /// buffers, so it can never trip this. The writer-identity guard makes a
    /// stale (uncancelled-but-late) watchdog firing against a newer take
    /// impossible.
    private func armFirstBufferWatchdog(for writer: RecordingWriter) {
        recordingWatchdog?.cancel()
        recordingWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.firstBufferWatchdogSeconds))
            guard !Task.isCancelled, let self,
                  let take = self.activeTake,
                  take.writer === writer,
                  !writer.hasReceivedAudio else { return }
            self.abortRecordingNoInput(take)
        }
    }

    /// Watchdog fired: the take rolled for `firstBufferWatchdogSeconds` with
    /// zero tap deliveries. Tear the take down like stopRecording, but report
    /// a readable failure instead of finalizing a silent empty take.
    /// One-take semantics: captured MIDI is discarded with the failed audio.
    private func abortRecordingNoInput(_ take: ActiveTake) {
        activeTake = nil
        recordingWatchdog = nil
        take.capture?.configurationChangeHandler = nil
        take.capture?.stop()
        stopPlayback()
        midiInput?.captureSession = nil  // discard the MIDI side too
        // Discard the file: zero frames deletes it inside finalize; the tiny
        // arrival-after-check race leaves at most one buffer, deleted here.
        take.writer?.finalize { @Sendable result in
            if case .success(let take) = result, take.framesWritten > 0 {
                try? FileManager.default.removeItem(at: take.url)
            }
        }
        let device: String
        if let uid = selectedInputUID {
            device = availableInputDevices().first { $0.uid == uid }?.name ?? uid
        } else {
            device = "system default input"
        }
        take.completion(.failure(EngineError.recordingFailed(
            "no audio arrived from input device '\(device)' — device may be unavailable; take aborted"
        )))
    }

    public func stopRecording() {
        guard let take = activeTake else { return }  // no-op when not recording
        activeTake = nil
        recordingWatchdog?.cancel()
        recordingWatchdog = nil
        // Stop beat BEFORE playback teardown — the anchor dies with
        // stopPlayback, and the MIDI session's open notes clamp to this beat.
        let stopBeat = derivedBeats()
        take.capture?.configurationChangeHandler = nil
        take.capture?.stop()
        stopPlayback()
        // MIDI side finishes synchronously on the main actor: drain any tail
        // events still queued, then close the session at the stop beat.
        var midiResult: MIDIRecordingResult?
        if take.capturingMIDI, let midi = midiInput {
            midi.drainCaptureRing()
            if let session = midi.captureSession {
                midiResult = session.finish(atBeat: stopBeat)
                midi.captureSession = nil
            } else {
                // CoreMIDI was unavailable at start: an empty capture, so the
                // caller still sees a MIDI side (zero notes).
                midiResult = MIDIRecordingResult(notes: [], lengthBeats: 1)
            }
        }
        let completion = take.completion
        guard let writer = take.writer else {
            completion(.success(TakeResult(audio: nil, midi: midiResult)))
            return
        }
        let midiSide = midiResult
        writer.finalize { @Sendable result in
            let mapped: Result<TakeResult, Error> = result.map { take in
                TakeResult(
                    audio: RecordingResult(
                        fileURL: take.url,
                        info: AudioFileInfo(
                            durationSeconds: take.sampleRate > 0
                                ? Double(take.framesWritten) / take.sampleRate : 0,
                            sampleRate: take.sampleRate,
                            channelCount: take.channelCount
                        ),
                        startOffsetSeconds: take.startOffsetSeconds
                    ),
                    midi: midiSide
                )
            }
            Task { @MainActor in
                completion(mapped)
            }
        }
    }

    /// Snapshots the loop region AND metronome state from any transport
    /// intent. Called first thing in every intent that receives a
    /// `TransportState`, before its own guards, so restarts that carry no
    /// transport (loop wrap, tracksDidChange, configuration recovery) reuse
    /// the latest values.
    private func cacheTransportFlags(from transport: TransportState) {
        loopEnabled = transport.isLoopEnabled
        loopStartBeat = transport.loopStartBeat
        loopEndBeat = transport.loopEndBeat
        metronomeEnabled = transport.isMetronomeEnabled
        beatsPerBar = transport.timeSignature.beatsPerBar
        countInBars = transport.countInBars
    }

    // MARK: - Playback internals

    /// The single reschedule primitive: stop-all → reschedule-from-beat →
    /// re-anchor → resume. Individual scheduled segments cannot be cancelled;
    /// costs one ~60 ms lead-in gap.
    private func restart(fromBeat beats: Double, tempoBPM: Double) {
        graph.stopAllPlayers()
        currentAnchor = nil
        startPlayers(fromBeat: beats, tempoBPM: tempoBPM)
    }

    /// Schedules every clip from `beats`, then starts all players in lockstep
    /// on a shared anchor `startLeadSeconds` in the future. The metronome
    /// player (re)schedules and starts here too, so the restart primitive
    /// naturally rebuilds the click queue.
    ///
    /// Count-in (record path only, `countInBars > 0`): the clip-player anchor
    /// — and `currentAnchor`, which the recording writer's accept window and
    /// `derivedBeats` read — is DELAYED by the count-in duration, while the
    /// metronome starts at the ORIGINAL anchor and fills the gap with
    /// count-in clicks. Because `derivedBeats` clamps with
    /// `max(anchor.startBeats, …)` (verified below in `derivedBeats`), the
    /// playhead sits exactly at `beats` for the whole count-in instead of
    /// reading negative motion against the delayed anchor.
    ///
    /// `renderClockTrusted: false` forces the host-clock anchor branch. Pass
    /// it when the engine was stopped and restarted moments ago (the routing-
    /// rewire resume): until the new render session's first callback,
    /// `outputNode.lastRenderTime` still reports the PREVIOUS session's clock
    /// with its valid flags set, while the restarted clock begins again near
    /// zero — a sample anchor computed from the stale value makes
    /// `derivedBeats` read negative elapsed time and the `max()` clamp
    /// freezes the playhead at the resume beat for the entire previous
    /// session's length (measured live 2026-07-06: a 2.05 s-old clock stalled
    /// the playhead 2.1 s and pushed the loop-wrap revival to 4.3 s — the
    /// M4 (i) "mid-play send stays silent" defect). The host clock is
    /// monotonic across the bounce, and players start on a hostTime anchor in
    /// both branches, so nothing else changes.
    private func startPlayers(fromBeat beats: Double, tempoBPM: Double, countInBars: Int = 0,
                              renderClockTrusted: Bool = true) {
        metronome.stop()  // clears the click queue; player time resets to 0
        graph.scheduleAll(fromBeat: beats, tempoBPM: tempoBPM)
        graph.prepareAllPlayers(withFrameCount: 8_192)

        let countIn = Metronome.countInPlan(
            countInBars: countInBars, beatsPerBar: beatsPerBar, tempoBPM: tempoBPM
        )
        let output = engine.outputNode
        let hardwareRate = output.outputFormat(forBus: 0).sampleRate
        let leadHostTicks = AVAudioTime.hostTime(forSeconds: Self.startLeadSeconds)
        let countInHostTicks = AVAudioTime.hostTime(forSeconds: countIn.delaySeconds)

        if renderClockTrusted,
           let renderTime = output.lastRenderTime,
           renderTime.isSampleTimeValid, renderTime.isHostTimeValid, hardwareRate > 0 {
            let clickAnchorHost = renderTime.hostTime + leadHostTicks
            let anchorHost = clickAnchorHost + countInHostTicks
            let anchorSample = renderTime.sampleTime + AVAudioFramePosition(
                ((Self.startLeadSeconds + countIn.delaySeconds) * hardwareRate).rounded()
            )
            currentAnchor = PlaybackAnchor(
                startBeats: beats,
                tempoBPM: tempoBPM,
                anchorSampleTime: anchorSample,
                anchorHostTime: anchorHost,
                outputSampleRate: hardwareRate,
                hasSampleAnchor: true
            )
            graph.startAllPlayers(at: AVAudioTime(hostTime: anchorHost))
            startMetronome(fromBeat: beats, tempoBPM: tempoBPM,
                           countInClickBeats: countIn.clickBeats,
                           at: AVAudioTime(hostTime: clickAnchorHost))
        } else {
            // No render clock yet (first callback pending): host-clock anchor
            // and host-clock playhead.
            let clickAnchorHost = mach_absolute_time() + leadHostTicks
            let anchorHost = clickAnchorHost + countInHostTicks
            currentAnchor = PlaybackAnchor(
                startBeats: beats,
                tempoBPM: tempoBPM,
                anchorSampleTime: 0,
                anchorHostTime: anchorHost,
                outputSampleRate: hardwareRate > 0 ? hardwareRate : 48_000,
                hasSampleAnchor: false
            )
            graph.startAllPlayers(at: AVAudioTime(hostTime: anchorHost))
            startMetronome(fromBeat: beats, tempoBPM: tempoBPM,
                           countInClickBeats: countIn.clickBeats,
                           at: AVAudioTime(hostTime: clickAnchorHost))
        }
    }

    /// Metronome side of one start/restart. Count-in clicks occupy player
    /// time 0..<countInClickBeats·spb (they sound even with the metronome
    /// disabled — count-in implies clicks); normal clicks follow with
    /// `playerStartBeat` shifted back by the count-in beats so the shared
    /// player-timeline convention (player time 0 ≡ playerStartBeat) holds
    /// against the ORIGINAL anchor the player starts on. Metronome disabled
    /// and no count-in → the player stays stopped.
    private func startMetronome(fromBeat beats: Double, tempoBPM: Double,
                                countInClickBeats: Int, at anchor: AVAudioTime) {
        guard metronomeEnabled || countInClickBeats > 0 else { return }
        if countInClickBeats > 0 {
            metronome.scheduleCountIn(clickBeats: countInClickBeats,
                                      tempoBPM: tempoBPM, beatsPerBar: beatsPerBar)
        }
        if metronomeEnabled {
            metronome.scheduleClicks(
                fromBeat: beats,
                throughBeat: beats + Metronome.topUpChunkBeats,
                tempoBPM: tempoBPM,
                beatsPerBar: beatsPerBar,
                playerStartBeat: beats - Double(countInClickBeats)
            )
        }
        metronome.start(at: anchor)
    }

    /// Current transport position derived from the output node's render clock
    /// (host clock as fallback). Clamped to the anchor's start beat so the
    /// ~60 ms lead-in never reads as motion — the same `max()` clamp also
    /// pins the playhead to the record-start position for the whole count-in
    /// (the recording anchor is delayed by the count-in duration, so elapsed
    /// time reads negative until the take actually begins).
    private func derivedBeats() -> Double {
        guard let anchor = currentAnchor else { return lastKnownBeats }
        if anchor.hasSampleAnchor,
           let renderTime = engine.outputNode.lastRenderTime, renderTime.isSampleTimeValid {
            let seconds = Double(renderTime.sampleTime - anchor.anchorSampleTime)
                / anchor.outputSampleRate
            return max(anchor.startBeats, anchor.startBeats + seconds * anchor.tempoBPM / 60)
        }
        let now = mach_absolute_time()
        // Signed host-tick delta: during the lead-in `now` is before the anchor.
        let seconds = now >= anchor.anchorHostTime
            ? AVAudioTime.seconds(forHostTime: now - anchor.anchorHostTime)
            : -AVAudioTime.seconds(forHostTime: anchor.anchorHostTime - now)
        return max(anchor.startBeats, anchor.startBeats + seconds * anchor.tempoBPM / 60)
    }

    /// Pushes engine-derived beats to the main actor at ~30 Hz while playing.
    private func startPlayheadTask() {
        playheadTask?.cancel()
        playheadTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !Task.isCancelled, let anchor = self.currentAnchor else { break }
                var beats = self.derivedBeats()
                // Loop wrap: on reaching the loop end, jump back to the loop start
                // through the reschedule primitive. That inherits `restart`'s
                // ~60 ms lead-in gap, so the wrap is audible as a brief seam —
                // v0-honest; sample-accurate looping needs pre-scheduled tails.
                // Suppressed while recording: a take is one linear capture, and
                // wrapping would break the writer's single-anchor alignment.
                if self.activeTake == nil,
                   self.loopEnabled, self.loopEndBeat > self.loopStartBeat,
                   beats >= self.loopEndBeat {
                    self.restart(fromBeat: self.loopStartBeat, tempoBPM: anchor.tempoBPM)
                    beats = self.loopStartBeat
                }
                self.lastKnownBeats = beats
                // Keep the click queue ahead of the playhead (control-thread
                // work; no-op unless an open-ended click run is active).
                self.metronome.topUp(currentBeat: beats)
                self.playheadHandler?(beats)
            }
        }
    }

    /// Best-effort recovery when the device or its format changes under us —
    /// now a plain alias for the shared `recoverEngine()` (M9 crash-c
    /// extraction; behavior byte-identical). Deliberately unchanged for
    /// recording: this is the OUTPUT engine's notification — capture runs on
    /// InputCapture's own engine, and the take stays aligned to the original
    /// player-start anchor (the writer's target host time never moves).
    private func handleConfigurationChange() {
        recoverEngine()
    }

    /// THE engine recovery routine (M9 crash-c: extracted verbatim from
    /// `handleConfigurationChange` so the watchdog drives the SAME code the
    /// config-change path has always used, not a copy): derive beats via the
    /// host clock (the sample timeline just broke), restart the engine, and
    /// resume from there. Not playing (no anchor) → syncs `isRunning` and
    /// returns without touching the engine — the notification path's
    /// original early-out, preserved exactly; the watchdog's restart wrapper
    /// layers the stopped-transport bounce on top (`watchdogRestart`).
    /// Internal (not private) so tests can drive it directly.
    func recoverEngine() {
        isRunning = engine.isRunning
        guard let anchor = currentAnchor else { return }

        let now = mach_absolute_time()
        let seconds = now >= anchor.anchorHostTime
            ? AVAudioTime.seconds(forHostTime: now - anchor.anchorHostTime)
            : 0
        let beats = max(anchor.startBeats, anchor.startBeats + seconds * anchor.tempoBPM / 60)
        lastKnownBeats = beats

        graph.stopAllPlayers()
        currentAnchor = nil
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            isRunning = true
            // Retire any teardown nodes parked while the device was down
            // (M9 crash-a — see prepare()).
            graph.flushRetiredNodes()
            // A fresh start re-initializes mixer parameters — restore the mix.
            engine.mainMixerNode.outputVolume = Float(masterVolume)
            graph.applyParameters(tracks: lastTracks)
            startPlayers(fromBeat: beats, tempoBPM: anchor.tempoBPM)
        } catch {
            playheadTask?.cancel()
            playheadTask = nil
            playheadHandler?(beats)
            FileHandle.standardError.write(
                Data("AudioEngine: configuration-change recovery failed: \(error)\n".utf8)
            )
        }
    }

    // MARK: - Engine watchdog (M9 crash-c)

    /// Starts the periodic watchdog check loop (idempotent — `prepare()`
    /// calls this on every start). Mirrors `ProjectStore.startCrashAutosave`:
    /// a plain sleep-tick task on the engine's actor; the interval is read
    /// once at start (`watchdogInterval`).
    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        let interval = watchdogInterval
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.watchdogTick()
            }
        }
    }

    /// One watchdog check — the loop body, split out so tests can drive
    /// checks directly without the timer.
    func watchdogTick() {
        watchdog.tick()
    }

    /// The watchdog's restart closure: bounce the engine through the SHARED
    /// recovery. A stalled engine may still CLAIM to be running — a silent
    /// HAL stall fires no configuration-change notification, which is
    /// exactly the detection gap the watchdog covers — so stop it first;
    /// `recoverEngine()`'s prepare+start leg then genuinely bounces the
    /// hardware. `recoverEngine()` only restarts mid-playback (its
    /// config-change contract, kept byte-identical), so the
    /// stopped-transport live-thru stall falls through to `prepare()` — the
    /// cold-start primitive (start + retire-bin flush + mixer/parameter
    /// restore). Throwing (a dead device refusing to start) is the
    /// watchdog's failure signal.
    func watchdogRestart() throws {
        engine.stop()
        isRunning = false
        recoverEngine()
        if !isRunning {
            try prepare()
        }
    }

    /// Watchdog state for the wire (`engine.watchdogStatus`). Poll-based,
    /// never throws; `engineRunning` is this engine's own `isRunning` claim.
    public func watchdogStatus() -> EngineWatchdogStatus {
        watchdog.status(engineRunning: isRunning)
    }

    // MARK: - Test tone (verifies the output path is real)

    public func startTestTone(frequency: Double = 440, amplitude: Float = 0.25) throws {
        try prepare()
        guard !isTonePlaying else { return }

        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard let buffer = Self.makeSineBuffer(
            format: format, frequency: frequency, amplitude: amplitude
        ) else { return }
        toneBuffer = buffer

        if tonePlayer.engine == nil {
            engine.attach(tonePlayer)
            engine.connect(tonePlayer, to: engine.mainMixerNode, format: format)
        }
        tonePlayer.scheduleBuffer(buffer, at: nil, options: .loops)
        tonePlayer.play()
        isTonePlaying = true
    }

    public func stopTestTone() {
        guard isTonePlaying else { return }
        tonePlayer.stop()
        isTonePlaying = false
    }

    private static func makeSineBuffer(
        format: AVAudioFormat, frequency: Double, amplitude: Float
    ) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        // Whole number of cycles so the looped buffer is click-free.
        let cycles = max(1, (frequency / 4).rounded())
        let frameCount = AVAudioFrameCount((cycles / frequency) * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let sample = amplitude * Float(sin(2.0 * .pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }
        return buffer
    }

    // MARK: - Metering

    private func installMeterTap(on mixer: AVAudioMixerNode) {
        guard !meterTapInstalled else { return }
        let format = mixer.outputFormat(forBus: 0)
        // Master-mix analysis (M8 vm-a) shares this tap — one tap per bus is
        // an AVFoundation limit. The analyzer preallocates everything here
        // (main actor, init time); the tap closure only feeds it.
        let analyzer = masterAnalyzer ?? MasterMixAnalyzer(sampleRate: format.sampleRate)
        masterAnalyzer = analyzer
        // @Sendable is load-bearing: without it this closure (formed in a
        // @MainActor context) inherits main-actor isolation and the Swift
        // runtime traps when AVFAudio invokes it on its tap queue.
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            // Runs on an audio-adjacent thread: compute scalars here, hop with a
            // Sendable value only. No engine state may be touched from this closure.
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var peak: Float = 0
            var sumSquares: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = channels[channel]
                for frame in 0..<frames {
                    let value = abs(samples[frame])
                    peak = max(peak, value)
                    sumSquares += value * value
                }
            }
            let denominator = Float(frames * Int(buffer.format.channelCount))
            let frame = MeterFrame(peak: peak, rms: (sumSquares / denominator).squareRoot())
            // Post-master-fader analysis: this tap reads mainMixerNode's
            // output, i.e. after `outputVolume` (the master fader) — what
            // you hear is what's analyzed. AVFAudio serializes tap
            // deliveries, so the analyzer is single-threaded by contract;
            // the snapshot VALUE (Sendable) rides the same main-actor hop
            // as the MeterFrame.
            analyzer.processMix(
                channels: channels,
                channelCount: Int(buffer.format.channelCount),
                frameCount: frames)
            let analysis = analyzer.snapshot()
            Task { @MainActor [weak self] in
                self?.meteringHandler?(frame)
                self?.latestMasterAnalysis = analysis
            }
        }
        meterTapInstalled = true
    }

    /// Latest master-mix analysis snapshot (M8 vm-a) — poll-based like
    /// meters. `.floor` until the tap has run (and again after `shutdown`).
    public func masterAnalysis() -> MasterAnalysisSnapshot {
        latestMasterAnalysis
    }

    /// Render-load / overrun telemetry (M9 perf-b): counters stamped by
    /// `InstrumentRenderer.renderQuantum` and `ChainHostAU`'s render block —
    /// live playback AND this engine's offline renders both count. Stopped
    /// engine = frozen counters, snapshot still readable. `reset: true`
    /// returns the closing window and starts a new one (see the context's
    /// read-then-reset ordering notes) — the perf-c windowed-profiling seam.
    public func performanceStats(reset: Bool) -> EnginePerformanceStats {
        reset ? performance.snapshotAndReset() : performance.snapshot()
    }
}
