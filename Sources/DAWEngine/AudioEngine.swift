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
    /// `var` since m13-a: `rebuildEngine(reason:)` discards and replaces the
    /// whole AVAudioEngine — teardown-class changes never surgically detach
    /// a once-rendered node (docs/research/design-m13a-teardown-crash.md).
    private var engine = AVAudioEngine()
    /// Internal (not private) so engine-level tests can pin graph facts the
    /// recovery paths guarantee (rebuild flag consumed, strips present) —
    /// the `auRegistry` seam precedent. Never reached from outside the
    /// module. `var` since m13-a: replaced together with the engine.
    private(set) var graph: PlaybackGraph
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
    /// The node carrying the master meter/analysis tap — m13-d §1-B honest
    /// tap relocation: the master chain sits POST-fader between
    /// `mainMixerNode` and the output, so the tap lives on the CHAIN HOST's
    /// output (post-fader AND post-chain — what you hear is what is
    /// analyzed; a `mainMixerNode` tap would read pre-chain and never show
    /// the limiter working). Tracked so shutdown/rebuild remove the tap from
    /// the node that actually carries it.
    private var meterTapNode: AVAudioNode?
    /// Armed debug master-bus capture (m14-d C5 live gate; nil = none) — see
    /// `startDebugMasterCapture(toPath:)`.
    private var debugCapture: DebugMasterCapture?
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
    /// m12-b (design row 51): the anchor carries the tempo MAP value (an
    /// immutable copy — the anchor stays a value type); `derivedBeats` is the
    /// map's inverse integral from `startBeats`. The design's `mapRevision`
    /// staleness integer arrives with Phase C's store-side map mutations —
    /// there is no revision producer yet.
    private struct PlaybackAnchor {
        let startBeats: Double
        let tempoMap: TempoMap
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

    /// m14-a L-1 (design-m13f-gapless-loop §4-A): non-nil while the CURRENT
    /// schedule was built with a live loop window — the playhead task then
    /// derives beats MODULARLY (the anchor never moves across wraps), tops up
    /// unrolled audio cycles, and never calls `restart` at the seam. Rebuilt
    /// by every `startPlayers`; nil when playback starts at/past the loop end
    /// (the legacy tick check then wraps ONCE through the restart primitive,
    /// which re-schedules WITH the window). m15-b: RECORDING loops too — the
    /// old "deliberately nil while recording" suppression is lifted (design-
    /// m15b-loop-record §5): the capture writer and MIDI session hang off the
    /// never-moving anchor, so the wrap never touches them, and the store
    /// slices the one linear capture into per-cycle take lanes at stop.
    private struct LoopContext {
        let startBeat: Double
        let endBeat: Double
        /// Player-relative seconds from the anchor start to the FIRST wrap
        /// (map integral `fromBeat → endBeat`).
        let headSeconds: Double
        /// Exact loop period: the map integral over [startBeat, endBeat).
        /// THE TIMELINE LAW (design §4-A): cycle timing derives from THIS —
        /// tempo segments past the loop end never leak into it.
        let cycleSeconds: Double
    }

    private var loopContext: LoopContext?
    /// Transport-elapsed second at which the CLICK player's timeline begins
    /// (m14-c L-3): 0 when the metronome started with the roll, the elapsed
    /// instant an enable-mid-play re-anchored the click player (player time 0
    /// ≡ that instant; design §6), or NEGATIVE under a count-in loop record
    /// (m15-b, design-m15b §5.4a: the click player starts
    /// `countIn.delaySeconds` BEFORE the transport anchor, so its own
    /// timeline is that far AHEAD of transport elapsed — without the negative
    /// offset the click unroll under-feeds by the whole count-in, a real
    /// starvation window against the 0.2 s horizon). `serviceLoop` subtracts
    /// it so the click unroll counts cycles in the CLICK player's OWN
    /// timeline.
    private var metronomeElapsedOffset: Double = 0

    /// Audio schedule-ahead horizon under an active loop: the C6 law demands
    /// ≥ 2 playhead-tick periods (2 × 33 ms); 200 ms adds comfortable margin
    /// for tick jitter while keeping the unroll depth single-digit cycles
    /// even at the 0.25-beat / 400 BPM minimum (design §8.3, §8.6). Internal
    /// (not private) so the C6 gate can pin `horizon ≥ 2 ticks` forever.
    static let loopHorizonSeconds = 0.2

    // MARK: Metronome state (cached from transport intents, like loop state)

    private let metronome = Metronome()
    private var metronomeEnabled = false

    /// Test seam (m14-c, the `PlaybackGraph.loopScheduledThroughCycle` twin):
    /// full click cycles the metronome has queued; nil = no loop-mode click
    /// run armed. Read by the L-3 live toggle smoke.
    var metronomeLoopScheduledThroughCycle: Int? { metronome.loopScheduledThroughCycle }
    /// Test seam (m15-b G7): whether the CURRENT schedule carries a live loop
    /// window — the engine side of the store/engine eligibility-unity pin
    /// (record with a loop must schedule with the window; without one, never).
    var loopContextActiveForTesting: Bool { loopContext != nil }
    /// Test seam (m15-b G6): the click player's timeline offset — negative
    /// exactly by the count-in delay on a count-in loop start (§5.4a).
    var metronomeElapsedOffsetForTesting: Double { metronomeElapsedOffset }
    /// Test seam (m15-b G6): the click loop plan's head — proves the engine
    /// handed the count-in delay to `scheduleLoopClicks` EXPLICITLY (§5.4b:
    /// `delay + integral(recordBeat → loopEnd)`, distinguishable from the
    /// old pre-roll-span integral whenever a tempo boundary sits at or
    /// before the record beat).
    var metronomeLoopHeadSecondsForTesting: Double? { metronome.loopPlanHeadSecondsForTesting }
    /// Test seam (m15-b G4): the live take's MIDI capture session, so the
    /// held-note fixture can inject synthetic events without CoreMIDI
    /// hardware. Control-plane only, like every seam here.
    var midiCaptureSessionForTesting: MIDICaptureSession? { midiInput?.captureSession }
    /// The REAL meter map (m15-a), cached from every transport intent exactly
    /// like the loop window — the downbeat source for every click schedule
    /// and the count-in bar length. Before m15-a this was a `beatsPerBar`
    /// scalar that flattened the project's meter map to a constant grid:
    /// measured live (audit-m15 §2-B1), a 4/4→3/4 change at beat 8 accented
    /// beats 12/16 instead of 11/14/17 — exactly when a musician relies on
    /// the click most. Control-thread only; never crosses into the render
    /// path (C4).
    private var clickMeterMap = MeterMap(constant: TimeSignature())
    /// Test seam (m15-a): the map above, readable so the plumbing pin can
    /// prove intents cache `transport.meterMap` itself, never a constant.
    var clickMeterMapForTesting: MeterMap { clickMeterMap }
    /// Test seam (m15-a): the meter map the `Metronome` API actually RECEIVED
    /// from the last schedule call — the second link of the regression chain
    /// (transport → cache → Metronome; m14-c pins Metronome → clicks).
    var metronomeMeterMapForTesting: MeterMap { metronome.receivedMeterMap }
    private var countInBars = 0

    /// Master output gain 0...2, cached so a value set before the engine first
    /// starts is re-applied in `prepare()`.
    private var masterVolume: Double = 1

    /// The project's master insert chain (m13-d), cached like `masterVolume`
    /// so `rebuildEngine`'s fresh graph republishes it during cold build
    /// (`wireGraphHooks`).
    private var lastMasterEffects: [EffectDescriptor] = []

    /// The project's master volume automation (m15-c), cached like
    /// `lastMasterEffects` for the rebuild republish.
    private var lastMasterAutomation: [AutomationLane] = []

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
    /// Position + tempo map captured when the routing-rewire hook wound down
    /// ACTIVE playback (quiescence before the engine discard, see
    /// `wireGraphHooks`); consumed by `rebuildEngine`, which resumes through
    /// the cold-start primitive (`startPlayers` + playhead task) against the
    /// freshly built engine.
    private var resumeAfterRoutingRewire: (beats: Double, tempoMap: TempoMap)?
    public var meteringHandler: ((MeterFrame) -> Void)?
    public var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    public var playheadHandler: ((Double) -> Void)?
    /// Engine-notices sink (m15-e): schedule-time degradation events forwarded
    /// from the graph's `noticeSink`, always on the main actor (every posting
    /// site is control-side schedule/reconcile code — zero render-thread
    /// surface). The store installs this and owns the coalescing ring.
    public var engineNoticeHandler: ((EngineNoticeEvent) -> Void)?

    public init() {
        graph = PlaybackGraph(engine: engine)
        wireGraphHooks()
        observeConfigurationChanges()
    }

    /// Wires every AudioEngine-owned hook into the CURRENT `graph` — called
    /// from `init` and again by `rebuildEngine` for each fresh graph (m13-a:
    /// the graph is replaced wholesale, so its hook set must be reinstalled
    /// verbatim; extracting this is what keeps the rebuild path and the
    /// cold-start path one implementation).
    private func wireGraphHooks() {
        // Telemetry context first — node creation (reconcile) captures it.
        // The SAME context survives every rebuild, so lifetime counters (the
        // watchdog heartbeat) stay monotonic across engine replacement.
        graph.performance = performance
        // Master chain (m13-d): a fresh (rebuilt) graph republishes the
        // cached descriptors — the masterVolume re-apply twin; the rebuild's
        // parameter passes then sync them into the fresh chain host.
        graph.masterEffects = lastMasterEffects
        // Master volume automation (m15-c): same republish, same reason; the
        // manual gain rides along so the override rule can hand back.
        graph.masterAutomation = lastMasterAutomation
        graph.manualMasterVolume = masterVolume
        // Hosted-AU tracks pull their prepared instrument from the registry;
        // nil (pending/missing/failed) falls back to the silent placeholder.
        // The registry OUTLIVES engine rebuilds — prepared instruments (and
        // their plugin state) are ours, never engine citizens.
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
        // Schedule-time degradation notices (m15-e) forward to the store's
        // ring; a rebuilt graph re-wires here, so posts survive engine
        // replacement.
        graph.noticeSink = { [weak self] event in
            self?.engineNoticeHandler?(event)
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
        // live bus SEGFAULTs the render thread. m13-a: the graph announces
        // the first such mutation of a pass and ABORTS the pass on a
        // once-rendered engine (`needsEngineRebuild`); `tracksDidChange`
        // then discards the whole engine and rebuilds from the model —
        // `rebuildEngine(reason:)`. This hook's only job is QUIESCENCE:
        // wind active playback down exactly like stopPlayback (position/
        // tempo captured for the resume) BEFORE the engine is discarded.
        // It deliberately does NOT stop the engine — the mid-pass
        // stop→restart boundary was precisely what poisoned AVFoundation's
        // node bookkeeping for the old flush-detach path (C0, design §2).
        // Trivial track adds never announce, so recording/capture survives
        // those unchanged.
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
        // playback winds down BEFORE the discard, and rebuildEngine resumes
        // via the same cold-start primitive a transport start uses.
        graph.willMutateRoutingTopology = { [weak self] in
            guard let self, self.engine.isRunning else { return }
            if let anchor = self.currentAnchor {
                self.resumeAfterRoutingRewire =
                    (beats: self.derivedBeats(), tempoMap: anchor.tempoMap)
                self.playheadTask?.cancel()
                self.playheadTask = nil
                self.graph.stopAllPlayers()
                self.metronome.stop()
                self.currentAnchor = nil
            }
        }
    }

    /// (Re)registers for configuration changes of the CURRENT engine object —
    /// the notification is engine-instance-scoped, so `rebuildEngine` must
    /// re-subscribe after every replacement. Device switches / sample-rate
    /// changes tear down the running graph. @Sendable is load-bearing (same
    /// trap as the meter tap): the closure fires on a non-main thread, so
    /// hop to the main actor before touching any engine state.
    private func observeConfigurationChanges() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
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

    // MARK: - ObjC exception armor (m16-a Leg 1)

    /// Posts the `engine-exception` notice for a converted AVFAudio raise.
    /// Fires only for `EngineError.engineException` (the barrier's converted
    /// NSException) — ordinary Swift errors pass silently, their call sites
    /// already handle them. Message = the design note's teaching copy, so the
    /// notices popover and the wire error read the same.
    private func postEngineExceptionNotice(_ error: any Error) {
        guard case let EngineError.engineException(_, reason, context) = error else { return }
        engineNoticeHandler?(EngineNoticeEvent(
            code: "engine-exception",
            message: "The audio engine raised '\(reason)' during \(context) — "
                + "playback was stopped; play again, or reopen the project if it persists."))
    }

    /// Best-effort transport wind-down after a caught AVFAudio raise: players
    /// and metronome stopped inside their own barriers (a raise during
    /// recovery must not escape either), anchor/loop state cleared, meters
    /// pushed dark, one final playhead push — the honest stopped state the
    /// teaching copy promises ("playback was stopped").
    private func windDownAfterException() {
        playheadTask?.cancel()
        playheadTask = nil
        try? withObjCExceptionBarrier("player wind-down") { graph.stopAllPlayers() }
        try? withObjCExceptionBarrier("metronome wind-down") { metronome.stop() }
        loopContext = nil
        metronomeElapsedOffset = 0
        if currentAnchor != nil {
            currentAnchor = nil
            for trackID in graph.trackIDs {
                trackMeteringHandler?(trackID, .silence)
            }
            playheadHandler?(lastKnownBeats)
        }
    }

    /// Runs one NON-THROWING control-plane intent under the ObjC exception
    /// barrier (m16-a Leg 1). The `AudioEngineControlling` transport methods
    /// this guards (`startPlayback`, `stopPlayback`, `seek`, …) are
    /// non-throwing by protocol, so a converted raise cannot rethrow through
    /// them — instead the intent winds the transport down, posts the
    /// `engine-exception` notice, and writes one stderr line. The notice ring
    /// plus the honestly-stopped transport ARE the surfaced truth on this
    /// path; throwing entry points (`prepare`, `startTake`, `renderOffline`)
    /// rethrow the converted error so the wire's LocalizedError mapping
    /// produces the teaching failure. Control-plane only (C8): main-actor
    /// entry points, never render code.
    private func withGuardedEngineIntent(_ context: String, _ body: () -> Void) {
        do {
            try withObjCExceptionBarrier(context) { body() }
        } catch {
            windDownAfterException()
            postEngineExceptionNotice(error)
            FileHandle.standardError.write(Data(
                "AudioEngine: caught ObjC exception during \(context): \(error)\n".utf8))
        }
    }

    public func prepare() throws {
        guard !isRunning else { return }
        do {
            // m16-a Leg 1: hardware start under the exception barrier — an
            // AVFAudio raise converts, posts the notice, and rethrows so the
            // standing LocalizedError mapping surfaces a teaching error
            // wherever this throw lands.
            try withObjCExceptionBarrier("engine start") {
                // Touching mainMixerNode implicitly wires mixer -> output.
                let mixer = engine.mainMixerNode
                // Master chain insert before start (m13-d R1): normally already
                // built by the first reconcile; this covers a prepare with no
                // tracksDidChange yet (test tone on a fresh engine). Idempotent,
                // attach-only — and it must precede the meter tap below, which
                // lives on the chain host (§1-B honest tap relocation).
                graph.ensureMasterSandwich()
                installMeterTap(on: graph.masterChainHost ?? mixer)
                // Lazy metronome attach: the player joins the graph once, whether or
                // not the click is enabled — scheduling decides whether it sounds.
                metronome.attach(to: engine)
                engine.prepare()
                try engine.start()
                isRunning = true
                // m13-a: from here on this engine is ONCE-RENDERED — teardown-class
                // changes must never surgically detach its nodes while it is
                // stopped; the graph flags `needsEngineRebuild` instead and
                // `tracksDidChange` replaces the whole engine
                // (docs/research/design-m13a-teardown-crash.md).
                graph.engineHasRun = true
                // Mixer parameters land AFTER start(): values set while the engine was
                // stopped (master volume, track pan/volume/mute/solo) must stick.
                mixer.outputVolume = Float(masterVolume)
                graph.applyParameters(tracks: lastTracks, playheadBeat: lastKnownBeats)
                // M9 crash-c: a successful start re-arms a given-up watchdog (the
                // only exit from `.failed`) and starts the check loop (idempotent).
                watchdog.reset()
                startWatchdog()
            }
        } catch {
            postEngineExceptionNotice(error)
            throw error
        }
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
            (meterTapNode ?? engine.mainMixerNode).removeTap(onBus: 0)
            meterTapInstalled = false
            meterTapNode = nil
        }
        stopDebugMasterCapture()  // idempotent; closes the file cleanly
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
        // m16-a Leg 1: the proven poisoner path (playAtTime: inside
        // startPlayers) runs under the ObjC exception barrier — see
        // `withGuardedEngineIntent` for why a caught raise cannot rethrow
        // through this non-throwing protocol method.
        withGuardedEngineIntent("transport start") {
            startPlayers(fromBeat: transport.positionBeats, tempoMap: transport.tempoMap)
            startPlayheadTask()
        }
    }

    public func stopPlayback() {
        guard currentAnchor != nil else { return }
        withGuardedEngineIntent("transport stop") {
            let beats = derivedBeats()  // modular under a loop — BEFORE the context clears
            loopContext = nil
            metronomeElapsedOffset = 0
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
    }

    public func seek(_ transport: TransportState) {
        cacheTransportFlags(from: transport)
        guard currentAnchor != nil else { return }  // stopped: position arrives with next start
        withGuardedEngineIntent("transport seek") {
            restart(fromBeat: transport.positionBeats, tempoMap: transport.tempoMap)
        }
    }

    public func setTempo(_ transport: TransportState) {
        cacheTransportFlags(from: transport)
        guard currentAnchor != nil else { return }
        // Engine-derived beats are authoritative here — the incoming
        // transport.positionBeats can be a display-stale ~33 ms behind.
        // m12-b (design row 49): the same restart seam serves any future
        // map edit — the transport's (trivial) map rides in whole.
        withGuardedEngineIntent("tempo change") {
            let beats = derivedBeats()
            restart(fromBeat: beats, tempoMap: transport.tempoMap)
            lastKnownBeats = beats
            playheadHandler?(beats)
        }
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
        // m16-a Leg 1: reconcile + rebuild under the exception barrier — the
        // audit's storm-flavored raises (a player attached-but-not-yet-
        // connected while reconcile churns) and the m13-a cousin family
        // (AVAudioEngineGraph _Connect/RemoveNode) both live on this path.
        withGuardedEngineIntent("track reconcile") {
            tracksDidChangeBody(tracks)
        }
    }

    /// `tracksDidChange`'s body, verbatim (split out so the barrier wrap
    /// keeps the early `return` semantics of the rebuild branch).
    private func tracksDidChangeBody(_ tracks: [Track]) {
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
        // m13-a: an announce-class pass (routing rewire, bus/routed-strip
        // teardown — including project boundaries via projectWillReplace),
        // or any teardown that arrived while a once-rendered engine sat
        // stopped, aborts reconcile and lands here: discard the whole
        // engine and cold-build a fresh one from the model. The rebuild
        // runs its own parameter passes, fanout re-sync and playback
        // resume, so this pass ends here.
        if graph.needsEngineRebuild {
            rebuildEngine(reason: "announce-class reconcile")
            return
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
            restart(fromBeat: derivedBeats(), tempoMap: anchor.tempoMap)
        }
        if let resume = resumeAfterRoutingRewire {
            // Defensive (m13-a): an announce always aborts into the rebuild
            // branch above, which consumes the resume state itself — so this
            // should be unreachable. It stays as a belt-and-braces resume:
            // a transport the hook wound down must never remain silently
            // stopped, whatever future path fires the hook without a
            // rebuild. Same cold-start primitive; renderClockTrusted: false
            // is load-bearing (a just-bounced engine still reports the OLD
            // render session's sample clock — see startPlayers; M4 i,
            // pinned live 2026-07-06).
            resumeAfterRoutingRewire = nil
            if isRunning {
                startPlayers(fromBeat: resume.beats, tempoMap: resume.tempoMap,
                             renderClockTrusted: false)
                startPlayheadTask()
            }
        }
    }

    // MARK: - Engine rebuild (m13-a)

    /// THE teardown primitive for a once-rendered engine
    /// (docs/research/design-m13a-teardown-crash.md §3): discard the whole
    /// `AVAudioEngine` + `PlaybackGraph` and cold-build fresh ones from the
    /// model. No surgical detach of a once-rendered node can occur, by
    /// construction — the falsified alternative (park detaches, flush them
    /// after a stop→reset→start bounce) died 2026-07-12 with six identical
    /// `UpdateGraphAfterReconfig` crash reports across two binaries.
    ///
    /// Reached from `tracksDidChange` when the graph flagged
    /// `needsEngineRebuild`: every announce-class rewire (A2 — send/output/
    /// sidechain-key edits, routed-strip or bus teardown, routed instrument
    /// invalidation) and every project boundary (A1 — `projectWillReplace`,
    /// unconditional once the engine has rendered).
    ///
    /// What survives untouched (design §4): the AU registry and every
    /// prepared instrument/effect INSTANCE incl. hosted-AU state (our
    /// objects, never engine citizens — the fresh graph re-pulls them
    /// through the providers), the input-capture engine, all DAWCore state,
    /// caches, telemetry context (heartbeat stays monotonic), MIDI input.
    /// Everything node-shaped rebuilds from `lastTracks` through the same
    /// cold-build order `prepare()` + the offline renderer use.
    ///
    /// RT-safety (design §5): main-actor only, zero render-thread changes.
    /// The old engine's last reference dies AFTER `stop()` returns (render
    /// callbacks quiesced) — the ordinary dealloc contract.
    ///
    /// m16-h Leg 1: the rebuilt engine STARTS only when something needs a
    /// running engine right now (pending playback resume, armed-instrument
    /// live-thru). Otherwise it is left stopped and never-run — strips and
    /// clips added after a project boundary then attach in the cold regime
    /// instead of onto a running engine, where a deep post-start strip
    /// sandwich could never start its players (the named AVFoundation
    /// reconfig defect, docs/research/design-m16h-reconfig.md).
    private func rebuildEngine(reason: String) {
        // 1. Quiesce: if playback is still anchored (a project boundary can
        //    arrive without the announce hook having wound down), capture
        //    resume state exactly like the hook.
        if let anchor = currentAnchor {
            resumeAfterRoutingRewire = (beats: derivedBeats(), tempoMap: anchor.tempoMap)
            playheadTask?.cancel()
            playheadTask = nil
            graph.stopAllPlayers()
            metronome.stop()
            currentAnchor = nil
        }
        // 2. Detach engine-lifetime fixtures from the DOOMED engine so their
        //    nodes re-attach cleanly to the fresh one (both attach guards
        //    key off `player.engine == nil`, which must not depend on the
        //    old engine's dealloc timing). Safe in both engine states: while
        //    RUNNING this is the boundary-free live detach (clean in every
        //    recorded experiment); while STOPPED the deferred bookkeeping
        //    can never be walked — the engine object is discarded before
        //    any further graph operation exists.
        stopTestTone()
        if tonePlayer.engine != nil {
            engine.detach(tonePlayer)
        }
        metronome.detach()
        // 3. Master tap off, stop, and discard. The analyzer resets only
        //    after the tap is removed and the engine stopped (its threading
        //    contract); the meter/analysis caches refresh on the fresh tap's
        //    first delivery.
        if meterTapInstalled {
            (meterTapNode ?? engine.mainMixerNode).removeTap(onBus: 0)
            meterTapInstalled = false
            meterTapNode = nil
        }
        stopDebugMasterCapture()  // a capture never outlives its engine
        engine.stop()
        isRunning = false
        masterAnalyzer?.reset()
        engine = AVAudioEngine()  // old engine's last reference dies here
        graph = PlaybackGraph(engine: engine)
        wireGraphHooks()
        observeConfigurationChanges()
        // 4. Cold build from the model — the offline renderer's proven
        //    order: graph wiring against the never-started engine, volumes
        //    pre-start (stick from frame 0, no ramp), start, then the
        //    post-start parameter pass (pan re-lands after start()'s mixer
        //    re-initialization — the double-apply convention). The master
        //    chain insert forms first (m13-d R1) so the meter tap can land
        //    on the fresh chain host (§1-B honest tap relocation).
        let mixer = engine.mainMixerNode  // touching it wires mixer → output
        graph.ensureMasterSandwich()
        installMeterTap(on: graph.masterChainHost ?? mixer)
        metronome.attach(to: engine)
        graph.reconcile(tracks: lastTracks)
        mixer.outputVolume = Float(masterVolume)
        graph.applyParameters(tracks: lastTracks, playheadBeat: lastKnownBeats)
        // m16-h Leg 1: DEFER the hardware start unless something needs a
        // running engine RIGHT NOW. On this OS a strip sandwich born on a
        // RUNNING engine hosts permanently unstartable players (the deep
        // post-start reconfig defect — docs/research/design-m16h-reconfig.md
        // §3), so the rebuilt engine stays STOPPED and NEVER-RUN whenever it
        // can: every later strip/clip attach runs the offline/cold regime
        // (`engineHasRun == false`, the fresh-launch shape — the most-proven
        // state in the tree) and the eventual `prepare()` (transport start,
        // record, test tone, watchdog restart — every other consumer starts
        // lazily) brings the hardware up with everything start-era. The two
        // consumers that DO need a running engine here are playback resume
        // (the announce hook wound a live transport down) and
        // armed-instrument live-thru; for those the start block below is
        // today's behavior verbatim.
        let mustStart = resumeAfterRoutingRewire != nil
            || lastTracks.contains { $0.kind == .instrument && $0.isArmed }
        if mustStart {
            engine.prepare()
            do {
                try engine.start()
                isRunning = true
                graph.engineHasRun = true
                graph.applyParameters(tracks: lastTracks, playheadBeat: lastKnownBeats)
                // A successful start re-arms the watchdog exactly like prepare().
                watchdog.reset()
                startWatchdog()
            } catch {
                // Start refused (device gone mid-rebuild): the fresh graph is
                // NEVER-RUN, so every subsequent operation is the offline-safe
                // cold build order; the next prepare() (transport start, config
                // recovery, watchdog restart) brings the hardware back up.
                FileHandle.standardError.write(Data(
                    "AudioEngine: rebuild (\(reason)) could not start hardware: \(error)\n".utf8))
            }
        }
        // 5. The live-thru fanout re-syncs against the REBUILT renderers —
        //    fresh instances; the old ones get the all-notes-off flush.
        syncMIDIThruFanout(lastTracks)
        // 6. Resume interrupted playback through the cold-start primitive.
        //    renderClockTrusted: false — the fresh engine's render clock has
        //    no callbacks yet (see startPlayers).
        if let resume = resumeAfterRoutingRewire {
            resumeAfterRoutingRewire = nil
            if isRunning {
                startPlayers(fromBeat: resume.beats, tempoMap: resume.tempoMap,
                             renderClockTrusted: false)
                startPlayheadTask()
            }
        }
    }

    /// A1 (m13-a): project boundaries (`project.new` / `project.open`)
    /// discard the engine UNCONDITIONALLY once it has rendered — there is
    /// no warm state worth keeping while the whole session is being
    /// replaced, and no per-node teardown of a once-rendered engine is ever
    /// safe to bet on. Marks the graph; the store's immediately following
    /// `tracksDidChange` (with the NEW project's tracks) consumes the flag
    /// via `rebuildEngine`. Never-run engines (fresh app, headless) keep
    /// the plain reconcile path — nothing to protect, no hardware touched.
    public func projectWillReplace() {
        guard graph.engineHasRun else { return }
        graph.needsEngineRebuild = true
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
    /// per hosted (`.audioUnit`/`.soundBank`) track whose configuration isn't
    /// already prepared or in flight. Until a prepare lands, the track renders
    /// the silent placeholder; on success the node is invalidated and
    /// `tracksDidChange` re-enters to rebuild it with the real instrument.
    private func syncAudioUnitInstruments(_ tracks: [Track]) {
        let graphRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = graphRate > 0 ? graphRate : 48_000

        var auTracks: [UUID: Track] = [:]
        for track in tracks
        where track.kind == .instrument
            && [.audioUnit, .soundBank].contains((track.instrument ?? .default).kind) {
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
            // ONE keying authority for both hosted kinds (m10-n §5.5): the
            // registry's own prepareKey — the engine's desired-map can never
            // drift from the registry's idempotency identity.
            let key = AUHostRegistry.prepareKey(track: track, sampleRate: sampleRate)
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
                                                stateData: entry.config.stateData,
                                                soundBankAddress: nil)
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

    /// Fixed latency of ONE live master-chain effect instance (m13-d) — the
    /// per-track `effectLatencySamples` twin on the post-fader master chain,
    /// feeding the wire snapshot's `masterEffects[].latencySamples`.
    public func masterEffectLatencySamples(effectID: UUID) -> Int {
        graph.masterEffectLatencySamples(forEffect: effectID)
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
        // m15-c: the write routes through the graph's override rule — with an
        // ACTIVE master volume lane the lane keeps fader authority (pin while
        // rolling, WYSIWYG preview while stopped); with no lane this is the
        // pre-m15-c direct write, verbatim.
        graph.setManualMasterVolume(masterVolume, playheadBeat: lastKnownBeats)
    }

    /// Master insert chain changed (m13-d): cache (rebuild republish), hand
    /// to the graph, and run ONE parameter pass — the chain sync + PDC
    /// recompute funnel (R6). An atomic snapshot publish into the permanent
    /// master chain host; never topology, never a rebuild, never a
    /// transport interruption (the live-add gate BY CONSTRUCTION).
    public func masterEffectsChanged(_ effects: [EffectDescriptor]) {
        lastMasterEffects = effects
        graph.masterEffects = effects
        graph.applyParameters(tracks: lastTracks, playheadBeat: lastKnownBeats)
    }

    /// Master volume automation changed (m15-c): cache (rebuild republish),
    /// hand to the graph, and run ONE parameter pass — while rolling the
    /// pass republishes the master schedule IN PLACE against the same
    /// anchor/epoch (never a restart; master automation is in no reconcile
    /// signature by construction), while stopped it lands the WYSIWYG lane
    /// preview (or hands the fader back to the manual gain) on the main
    /// mixer. The `masterEffectsChanged` shape, verbatim.
    public func masterAutomationChanged(_ lanes: [AutomationLane]) {
        lastMasterAutomation = lanes
        graph.masterAutomation = lanes
        graph.applyParameters(tracks: lastTracks, playheadBeat: lastKnownBeats)
    }

    /// `masterEffects` defaults `[]` on the CONCRETE class only (the
    /// OfflineRenderer class-level-default rationale, design §2.1): the
    /// render-class decision (MASTERED vs STEM) is forced at the PROTOCOL
    /// layer, which has no default — direct concrete calls are engine-test
    /// plumbing, and their `[]` is exactly the pre-m13-d behavior.
    public func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                              masterEffects: [EffectDescriptor] = [],
                              masterAutomation: [AutomationLane] = [],
                              fromBeat: Double, durationSeconds: Double,
                              to url: URL) async throws -> AudioFileInfo {
        // Refactored over the M5 iv-b buffer seam: render to memory (the
        // WYSIWYG stretch await and fresh-renderer rules live there), then
        // write — the exact composition `renderToWAV` performed, behavior
        // frozen (the existing mixdown/stretch suites are the proof).
        // Internal delegation forwards its own render-class parameter
        // (design §2.1).
        let audio = try await renderOffline(
            tracks: tracks, tempoMap: tempoMap, masterVolume: masterVolume,
            masterEffects: masterEffects,
            masterAutomation: masterAutomation,
            fromBeat: fromBeat, durationSeconds: durationSeconds,
            forcedCompensationTargets: nil
        )
        return try writeAudioFile(audio, to: url)
    }

    /// `masterEffects` / `masterAutomation` concrete-class defaults — see
    /// `renderMixdown`.
    public func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                              masterEffects: [EffectDescriptor] = [],
                              masterAutomation: [AutomationLane] = [],
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
        // m16-a Leg 1: the offline-render entry runs its synchronous AVFAudio
        // work under the exception barrier — a raise converts and rethrows,
        // so `render.mixdown`/bounce commands fail with the teaching error
        // instead of poisoning the MainActor. (AU preparation above is async
        // instantiation with its own internal error handling.)
        do {
            return try withObjCExceptionBarrier("offline render") {
                try renderer.render(
                    tracks: tracks, tempoMap: tempoMap, fromBeat: fromBeat,
                    durationSeconds: durationSeconds, masterVolume: masterVolume,
                    masterEffects: masterEffects,
                    masterAutomation: masterAutomation
                )
            }
        } catch {
            postEngineExceptionNotice(error)
            throw error
        }
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
        let scheduledLoop = loopContext
        cacheTransportFlags(from: transport)
        // ENABLING a loop stays cache-only (never touches live scheduling):
        // the current schedule is linear, and the first tick past the loop
        // end wraps through the restart primitive, which re-schedules WITH
        // the window — one seam at the first wrap, gapless from then on.
        // Enabling a loop whose region already sits behind the playhead is
        // safe the same way (the tick's `beats >= loopEndBeat` check).
        //
        // m14-a L-1: with unrolled cycles ALREADY QUEUED, a bounds change or
        // a disable can no longer be cache-only — queued segments cannot be
        // cancelled (the restart-primitive doc), so stale cycles from the old
        // window would keep sounding. ONE restart seam on the EDIT, exactly
        // the design §4-A fallback (a seam on edit is honest; a seam every
        // cycle was the bug).
        guard let scheduledLoop, let anchor = currentAnchor else { return }
        if !loopEnabled
            || scheduledLoop.startBeat != loopStartBeat
            || scheduledLoop.endBeat != loopEndBeat {
            // m16-a Leg 1: the restart seam reaches the same playAtTime: loop
            // as a transport start — same barrier, same wind-down on a raise.
            withGuardedEngineIntent("loop change") {
                restart(fromBeat: derivedBeats(), tempoMap: anchor.tempoMap)
            }
        }
    }

    /// Metronome toggled (m14-c L-3, design §6): CLICK-PLAYER-LOCAL only —
    /// the transport, clip players, and schedules are NEVER touched, so a
    /// mid-play toggle leaves clip output byte-identical (the ProjectStore
    /// seek/restart fallback is retired). Disable = `metronome.stop()` (its
    /// OWN player; the queue clears, player time resets). Enable mid-play =
    /// re-anchor the click player at "now + startLeadSeconds" and schedule
    /// from that beat (placement jitter = the documented ±1-frame live-anchor
    /// class, InstrumentSourceNode); under an active loop the re-anchored run
    /// unrolls cycles from the current MODULAR position, with
    /// `metronomeElapsedOffset` recording where the new click timeline began.
    /// Stopped transport → cache-only (state is read at the next start);
    /// recording keeps its committed click schedule (the store refuses the
    /// toggle mid-take — this guard is defense in depth).
    public func metronomeChanged(_ transport: TransportState) {
        cacheTransportFlags(from: transport)
        guard let anchor = currentAnchor, activeTake == nil else { return }
        // m16-a Leg 1: the click player's own play(at:) is the same AVFAudio
        // raise family — barrier the click-local work like every other
        // control-plane intent that starts a player.
        withGuardedEngineIntent("metronome toggle") {
            metronomeChangedBody(anchor: anchor)
        }
    }

    /// `metronomeChanged`'s click-local body, verbatim (split out for the
    /// barrier wrap — the inner `guard` return keeps its semantics).
    private func metronomeChangedBody(anchor: PlaybackAnchor) {
        metronome.stop()
        guard metronomeEnabled else { return }
        let elapsed = elapsedSeconds(anchor: anchor)
        let anchorBeat = beat(forElapsedSeconds: elapsed + Self.startLeadSeconds,
                              anchor: anchor)
        if let loop = loopContext {
            metronome.scheduleLoopClicks(
                fromBeat: anchorBeat,
                loopStartBeat: loop.startBeat, loopEndBeat: loop.endBeat,
                tempoMap: anchor.tempoMap, meterMap: clickMeterMap,
                playerStartBeat: anchorBeat
            )
            metronome.topUpLoopCycles(elapsedPlayerSeconds: 0,
                                      horizonSeconds: Self.loopHorizonSeconds)
            metronomeElapsedOffset = elapsed + Self.startLeadSeconds
        } else {
            metronome.scheduleClicks(
                fromBeat: anchorBeat,
                throughBeat: anchorBeat + Metronome.topUpChunkBeats,
                tempoMap: anchor.tempoMap, meterMap: clickMeterMap,
                playerStartBeat: anchorBeat
            )
        }
        metronome.start(at: AVAudioTime(
            hostTime: mach_absolute_time()
                &+ AVAudioTime.hostTime(forSeconds: Self.startLeadSeconds)))
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
        // m16-a Leg 1: the whole record start (input capture, hardware
        // prepare, the startPlayers play loop, writer/MIDI alignment) runs
        // under the exception barrier — startTake already throws, so a
        // converted raise rethrows into the wire's LocalizedError mapping;
        // the catch below first winds down whatever half-started.
        var capture: InputCapture?
        var writer: RecordingWriter?
        do {
            try withObjCExceptionBarrier("record start") {
                try startTakeBody(transport, audioURL: audioURL, captureMIDI: captureMIDI,
                                  capture: &capture, writer: &writer,
                                  completion: completion)
            }
        } catch {
            if case EngineError.engineException = error {
                try? withObjCExceptionBarrier("capture wind-down") { capture?.stop() }
                writer?.finalize { _ in }  // zero/few frames → file deleted
                windDownAfterException()
                activeTake = nil
                recordingWatchdog?.cancel()
                recordingWatchdog = nil
                postEngineExceptionNotice(error)
            }
            throw error
        }
    }

    /// `startTake`'s body from the capture step onward, verbatim (split out
    /// for the barrier wrap; `capture`/`writer` are inout so the catch can
    /// wind down whatever had already started when a raise cut the body
    /// short).
    private func startTakeBody(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                               capture: inout InputCapture?, writer: inout RecordingWriter?,
                               completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {
        // 2. Audio capture side first (only when the take wants audio): any
        //    input/file failure throws synchronously with no engine state
        //    change. Two-phase capture start: prepare() resolves/pins the
        //    device and returns the post-pin native format (the pinned
        //    device's rate/channels can differ from the system default's),
        //    the writer sizes from THAT, then start(writer:) installs the tap
        //    and starts I/O. MIDI-only takes never touch the microphone.
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
        //    m15-b: with a loop enabled this schedules WITH the window like
        //    any playback start (ProjectStore seeks record to the loop start
        //    first, so the window guard below always passes) — playback wraps
        //    gaplessly while the capture stays ONE linear take against the
        //    never-moving anchor; the store slices it per cycle at stop.
        startPlayers(fromBeat: transport.positionBeats, tempoMap: transport.tempoMap,
                     countInBars: transport.countInBars)
        startPlayheadTask()
        // 4. Align the writer to the shared player-start anchor: capture
        //    before this host time is trimmed, so file frame 0 ≈ the moment
        //    playback (and the take) began. startPlayers always sets the anchor.
        //    With punch enabled, the accept window is [punchIn, punchOut]
        //    translated onto the host clock from that same anchor, and the
        //    REFERENCE stays the anchor: startOffsetSeconds then reports the
        //    anchor → punch-in gap, which ProjectStore's fan-out (the inverse
        //    map integral from the record-start beat) turns into the punch-in
        //    beat.
        //    A window-relative offset (≈ 0) would land the clip at the record
        //    position — that was a live-E2E bug. punchOutBeat > positionBeats
        //    is a ProjectStore.record() precondition.
        let anchor = currentAnchor!
        if let writer {
            if transport.isPunchEnabled {
                // Punch window = the map integral from the record position to
                // each punch beat (m12-b, design row 46; signed for the end,
                // clamped >= 0 for the start exactly as before).
                let map = transport.tempoMap
                let startHost = anchor.anchorHostTime + AVAudioTime.hostTime(
                    forSeconds: max(0, map.seconds(from: transport.positionBeats,
                                                   to: transport.punchInBeat))
                )
                let endHost = anchor.anchorHostTime + AVAudioTime.hostTime(
                    forSeconds: map.seconds(from: transport.positionBeats,
                                            to: transport.punchOutBeat)
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
                tempoMap: anchor.tempoMap,
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
        // LINEAR by law (m15-b, design-m15b §5.3): the capture session stamps
        // note beats through the frozen map's LINEAR inverse integral, so the
        // clamp must live in the same domain — `derivedBeats()` is MODULAR
        // under a live loop, and a note held into cycle 3 would clamp to a
        // cycle-1 beat and collapse to the 0.001-beat floor. The playhead
        // keeps the modular read; only the capture clamp is linear.
        let stopBeat = derivedLinearBeats()
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
            completion(.success(TakeResult(audio: nil, midi: midiResult,
                                           stopBeats: stopBeat)))
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
                    midi: midiSide,
                    stopBeats: stopBeat
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
        // m15-a: the WHOLE meter map, not a scalar — `transport.meterMap`
        // synthesizes the trivial map from the base time signature when the
        // project has no meter changes, so the trivial case is byte-identical
        // to the old constant-map arithmetic (the null-era gate).
        clickMeterMap = transport.meterMap
        countInBars = transport.countInBars
    }

    // MARK: - Playback internals

    /// The single reschedule primitive: stop-all → reschedule-from-beat →
    /// re-anchor → resume. Individual scheduled segments cannot be cancelled;
    /// costs one ~60 ms lead-in gap.
    private func restart(fromBeat beats: Double, tempoMap: TempoMap) {
        graph.stopAllPlayers()
        currentAnchor = nil
        startPlayers(fromBeat: beats, tempoMap: tempoMap)
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
    /// m15-b (design-m15b §5.1): the old `scheduleLoop: false` record-path
    /// escape is GONE — recording schedules with the loop window exactly like
    /// playback. The capture side never notices: the writer's accept window
    /// and the MIDI session are anchored ONCE to the never-moving M14 anchor,
    /// and loop unrolling only queues more segments on rolling players.
    private func startPlayers(fromBeat beats: Double, tempoMap: TempoMap, countInBars: Int = 0,
                              renderClockTrusted: Bool = true) {
        metronome.stop()  // clears the click queue; player time resets to 0
        // m14-a L-1: an eligible live loop schedules WITH the window — the
        // wrap is then pre-queued cycles on rolling players, never a restart.
        loopContext = nil
        metronomeElapsedOffset = 0
        var loopWindow: PlaybackGraph.LoopWindow?
        if loopEnabled,
           loopEndBeat > loopStartBeat, beats < loopEndBeat {
            let cycleSeconds = tempoMap.seconds(from: loopStartBeat, to: loopEndBeat)
            let headSeconds = tempoMap.seconds(from: beats, to: loopEndBeat)
            if cycleSeconds > 0, headSeconds > 0 {
                loopWindow = PlaybackGraph.LoopWindow(startBeat: loopStartBeat,
                                                      endBeat: loopEndBeat)
                loopContext = LoopContext(startBeat: loopStartBeat, endBeat: loopEndBeat,
                                          headSeconds: headSeconds, cycleSeconds: cycleSeconds)
            }
        }
        graph.scheduleAll(fromBeat: beats, tempoMap: tempoMap, loop: loopWindow)
        if loopContext != nil {
            // Initial coverage: eager +2 cycles and the C6 horizon — all
            // pre-queued anchored segments, the L-0 spike's proven shape.
            // Later top-ups ride the playhead task.
            graph.topUpLoopCycles(elapsedPlayerSeconds: 0,
                                  horizonSeconds: Self.loopHorizonSeconds)
        }
        graph.prepareAllPlayers(withFrameCount: 8_192)

        let countIn = Metronome.countInPlan(
            countInBars: countInBars, meterMap: clickMeterMap,
            tempoMap: tempoMap, atBeat: beats
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
                tempoMap: tempoMap,
                anchorSampleTime: anchorSample,
                anchorHostTime: anchorHost,
                outputSampleRate: hardwareRate,
                hasSampleAnchor: true
            )
            graph.startAllPlayers(at: AVAudioTime(hostTime: anchorHost))
            startMetronome(fromBeat: beats, tempoMap: tempoMap,
                           countIn: countIn,
                           at: AVAudioTime(hostTime: clickAnchorHost))
        } else {
            // No render clock yet (first callback pending): host-clock anchor
            // and host-clock playhead.
            let clickAnchorHost = mach_absolute_time() + leadHostTicks
            let anchorHost = clickAnchorHost + countInHostTicks
            currentAnchor = PlaybackAnchor(
                startBeats: beats,
                tempoMap: tempoMap,
                anchorSampleTime: 0,
                anchorHostTime: anchorHost,
                outputSampleRate: hardwareRate > 0 ? hardwareRate : 48_000,
                hasSampleAnchor: false
            )
            graph.startAllPlayers(at: AVAudioTime(hostTime: anchorHost))
            startMetronome(fromBeat: beats, tempoMap: tempoMap,
                           countIn: countIn,
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
    private func startMetronome(fromBeat beats: Double, tempoMap: TempoMap,
                                countIn: (delaySeconds: Double, clickBeats: Int),
                                at anchor: AVAudioTime) {
        let countInClickBeats = countIn.clickBeats
        guard metronomeEnabled || countInClickBeats > 0 else { return }
        if countInClickBeats > 0 {
            metronome.scheduleCountIn(clickBeats: countInClickBeats,
                                      tempoMap: tempoMap, atBeat: beats,
                                      meterMap: clickMeterMap)
        }
        if metronomeEnabled {
            if let loop = loopContext {
                // m14-c L-3: loop-mode runs schedule the head pass
                // [beats, loop end) and unroll whole cycles on the playhead
                // cadence — the same absolute-integral anchors as the
                // audio/MIDI unroll (the L-1 per-wrap re-anchor interim, its
                // boundary-click skip, and its short-loop jitter are gone).
                // m15-b (design-m15b §5.4b): a loop-record start CAN carry a
                // count-in now. The pre-roll is a record-beat LOOKUP by
                // policy (countInPlan), NOT a map integral across the
                // pre-roll span — so the count-in delay is passed EXPLICITLY
                // and cycle click anchors land at
                // `delaySeconds + integral(recordBeat → loopEnd) + k·L`,
                // with playerStartBeat == beats (never `beats − clickBeats`,
                // which would integrate the map across the pre-roll).
                metronome.scheduleLoopClicks(
                    fromBeat: beats,
                    loopStartBeat: loop.startBeat, loopEndBeat: loop.endBeat,
                    tempoMap: tempoMap, meterMap: clickMeterMap,
                    playerStartBeat: beats,
                    countInDelaySeconds: countIn.delaySeconds
                )
                // Initial coverage, exactly like the graph's start-time call
                // (elapsed 0 in the CLICK player's own timeline).
                metronome.topUpLoopCycles(elapsedPlayerSeconds: 0,
                                          horizonSeconds: Self.loopHorizonSeconds)
                // §5.4a: the click player's timeline begins delaySeconds
                // BEFORE the transport anchor — serviceLoop's subtraction
                // must ADD the count-in back (0 when no count-in: the null
                // case is arithmetic-identical to m14-c).
                metronomeElapsedOffset = -countIn.delaySeconds
            } else {
                metronome.scheduleClicks(
                    fromBeat: beats,
                    throughBeat: beats + Metronome.topUpChunkBeats,
                    tempoMap: tempoMap, meterMap: clickMeterMap,
                    playerStartBeat: beats - Double(countInClickBeats)
                )
            }
        }
        metronome.start(at: anchor)
    }

    /// Elapsed player-timeline seconds since the anchor — the render clock
    /// when the anchor carries a valid sample epoch, the host clock otherwise.
    /// Signed: negative during the ~60 ms start lead-in.
    private func elapsedSeconds(anchor: PlaybackAnchor) -> Double {
        if anchor.hasSampleAnchor,
           let renderTime = engine.outputNode.lastRenderTime, renderTime.isSampleTimeValid {
            return Double(renderTime.sampleTime - anchor.anchorSampleTime)
                / anchor.outputSampleRate
        }
        let now = mach_absolute_time()
        // Signed host-tick delta: during the lead-in `now` is before the anchor.
        return now >= anchor.anchorHostTime
            ? AVAudioTime.seconds(forHostTime: now - anchor.anchorHostTime)
            : -AVAudioTime.seconds(forHostTime: anchor.anchorHostTime - now)
    }

    /// Beat for `seconds` of elapsed anchor time. Linear (pre-m14-a verbatim,
    /// m12-b row 47: the map's inverse integral with the lead-in/count-in
    /// `max()` clamp) until the first wrap; MODULAR under an active loop
    /// context past `headSeconds` (m14-a L-1): the anchor NEVER moves across
    /// wraps — cycle position is `(elapsed − head) mod cycleSeconds`, and THE
    /// TIMELINE LAW holds by construction: `within < cycleSeconds`, so the
    /// map inverse is only ever evaluated inside [loop.startBeat,
    /// loop.endBeat) — segments past the loop end never leak into cycle
    /// timing.
    private func beat(forElapsedSeconds seconds: Double, anchor: PlaybackAnchor) -> Double {
        if let loop = loopContext, seconds >= loop.headSeconds {
            let within = (seconds - loop.headSeconds)
                .truncatingRemainder(dividingBy: loop.cycleSeconds)
            return min(loop.endBeat,
                       anchor.tempoMap.beat(from: loop.startBeat, elapsedSeconds: within))
        }
        return max(anchor.startBeats,
                   anchor.tempoMap.beat(from: anchor.startBeats, elapsedSeconds: seconds))
    }

    /// Current transport position derived from the output node's render clock
    /// (host clock as fallback). Clamped to the anchor's start beat so the
    /// ~60 ms lead-in never reads as motion — the same `max()` clamp also
    /// pins the playhead to the record-start position for the whole count-in
    /// (the recording anchor is delayed by the count-in duration, so elapsed
    /// time reads negative until the take actually begins). Wraps modularly
    /// under an active loop (m14-a; see `beat(forElapsedSeconds:anchor:)`).
    private func derivedBeats() -> Double {
        guard let anchor = currentAnchor else { return lastKnownBeats }
        return beat(forElapsedSeconds: elapsedSeconds(anchor: anchor), anchor: anchor)
    }

    /// LINEAR transport beat since the anchor — `derivedBeats` WITHOUT the
    /// modular loop branch (m15-b, design-m15b §5.3): the frozen map's
    /// inverse integral with the same lead-in/count-in `max()` clamp, never
    /// wrapping. This is the CAPTURE clock: the MIDI session stamps note
    /// beats linearly through the same map from the same anchor, so the
    /// stop clamp (and the store's per-cycle slicing inversion) must read
    /// this domain. Internal (not private) so the G4 held-note fixture can
    /// pin linear-vs-modular divergence across a live wrap.
    func derivedLinearBeats() -> Double {
        guard let anchor = currentAnchor else { return lastKnownBeats }
        return max(anchor.startBeats,
                   anchor.tempoMap.beat(from: anchor.startBeats,
                                        elapsedSeconds: elapsedSeconds(anchor: anchor)))
    }

    /// Pushes engine-derived beats to the main actor at ~30 Hz while playing.
    private func startPlayheadTask() {
        playheadTask?.cancel()
        playheadTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !Task.isCancelled, let anchor = self.currentAnchor else { break }
                var beats = self.derivedBeats()
                if let loop = self.loopContext {
                    // m14-a L-1 gapless wrap: audio cycles are pre-queued on
                    // the ROLLING players (the graph never stops at the seam;
                    // derivedBeats already wrapped `beats` modularly). Keep
                    // audio/MIDI/automation/click coverage ahead of the
                    // playhead — everything unrolls on this one cadence.
                    self.serviceLoop(loop, anchor: anchor)
                } else {
                    if self.loopEnabled, self.loopEndBeat > self.loopStartBeat,
                       beats >= self.loopEndBeat {
                        // Loop cached but the current schedule is LINEAR
                        // (loop enabled mid-play, or playback started at/past
                        // the loop end): wrap ONCE through the restart
                        // primitive — `startPlayers` re-schedules WITH the
                        // window, so every later wrap is gapless. An
                        // edit-class seam, never per-cycle (design §4-A
                        // fallback). m15-b: unreachable while recording —
                        // record with a loop SEEKS to the loop start first
                        // (so the schedule carries the window and
                        // `loopContext != nil`), and `transport.setLoop` is
                        // refused mid-record, so a rolling take can never
                        // find itself linear-with-a-loop here.
                        self.restart(fromBeat: self.loopStartBeat, tempoMap: anchor.tempoMap)
                        beats = self.loopStartBeat
                    }
                    // Keep the linear click queue ahead of the playhead
                    // (control-thread work; no-op unless an open-ended
                    // linear click run is active — loop runs unroll whole
                    // cycles inside `serviceLoop` instead, m14-c L-3).
                    self.metronome.topUp(currentBeat: beats)
                }
                self.lastKnownBeats = beats
                self.playheadHandler?(beats)
            }
        }
    }

    /// One playhead tick's loop servicing (m14-a L-1, control thread only):
    /// audio + MIDI + automation + CLICK horizon top-up every tick — the
    /// graph's `topUpLoopCycles` unrolls the first three append-only against
    /// the roll's one anchor (m14-b L-2: no per-wrap flush, no re-anchor;
    /// voices and automation values persist through the seam), and the
    /// metronome unrolls clicks the same way on its OWN player (m14-c L-3:
    /// no per-wrap stop/re-anchor — the L-1 boundary-click-skip and
    /// short-loop-jitter classes are dead). The click elapsed subtracts
    /// `metronomeElapsedOffset` because an enable-mid-play re-anchors the
    /// click player's timeline (design §6) while the transport anchor never
    /// moves.
    private func serviceLoop(_ loop: LoopContext, anchor: PlaybackAnchor) {
        let elapsed = elapsedSeconds(anchor: anchor)
        graph.topUpLoopCycles(elapsedPlayerSeconds: elapsed,
                              horizonSeconds: Self.loopHorizonSeconds)
        metronome.topUpLoopCycles(
            elapsedPlayerSeconds: elapsed - metronomeElapsedOffset,
            horizonSeconds: Self.loopHorizonSeconds)
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
        // m12-b (design row 48): same inverse integral + clamp as derivedBeats
        // — and the same modular wrap under a loop (m14-a), so recovery
        // resumes inside the window and re-schedules with it.
        let beats = beat(forElapsedSeconds: seconds, anchor: anchor)
        lastKnownBeats = beats

        graph.stopAllPlayers()
        currentAnchor = nil
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            isRunning = true
            // A fresh start re-initializes mixer parameters — restore the mix.
            engine.mainMixerNode.outputVolume = Float(masterVolume)
            graph.applyParameters(tracks: lastTracks)
            startPlayers(fromBeat: beats, tempoMap: anchor.tempoMap)
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
    /// cold-start primitive (start + mixer/parameter restore). Throwing (a
    /// dead device refusing to start) is the watchdog's failure signal.
    ///
    /// m13-a WATCH (recorded, out of scope by design §6.6): recovery
    /// restarts the SAME engine across a stop→start boundary, so nodes that
    /// rendered before the stall are boundary-crossed afterwards — a later
    /// plain (trivial-strip) teardown detach against the RUNNING recovered
    /// engine is the C0 crash shape; announce-class teardowns rebuild the
    /// engine anyway. C0 never implicated this path (zero recovery events
    /// in every recorded crash); if it ever fires, route recovery through
    /// `rebuildEngine` in a follow-up item rather than widening m13-a.
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
        try prepare()  // carries its own barrier (m16-a Leg 1)
        guard !isTonePlaying else { return }
        // m16-a Leg 1: a literal player play() — barrier + rethrow (this
        // entry already throws, so the wire gets the teaching error).
        do {
            try withObjCExceptionBarrier("test tone start") {
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
        } catch {
            postEngineExceptionNotice(error)
            throw error
        }
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

    /// m13-d §1-B: `node` is the master CHAIN HOST's output in production
    /// (post-fader, post-chain — the honest relocation; `mainMixerNode` only
    /// as a defensive fallback when the insert is absent). Generic over
    /// `AVAudioNode` for exactly that reason.
    private func installMeterTap(on node: AVAudioNode) {
        guard !meterTapInstalled else { return }
        let format = node.outputFormat(forBus: 0)
        // Master-mix analysis (M8 vm-a) shares this tap — one tap per bus is
        // an AVFoundation limit. The analyzer preallocates everything here
        // (main actor, init time); the tap closure only feeds it.
        let analyzer = masterAnalyzer ?? MasterMixAnalyzer(sampleRate: format.sampleRate)
        masterAnalyzer = analyzer
        // @Sendable is load-bearing: without it this closure (formed in a
        // @MainActor context) inherits main-actor isolation and the Swift
        // runtime traps when AVFAudio invokes it on its tap queue.
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
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
            // Post-master-fader, post-master-chain analysis (m13-d §1-B):
            // this tap reads the master chain host's output — after the
            // fader AND the chain — what you hear is what's analyzed (the
            // meters show the limiter working). AVFAudio serializes tap
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
        meterTapNode = node
    }

    /// Latest master-mix analysis snapshot (M8 vm-a) — poll-based like
    /// meters. `.floor` until the tap has run (and again after `shutdown`).
    public func masterAnalysis() -> MasterAnalysisSnapshot {
        latestMasterAnalysis
    }

    // MARK: - Debug master-bus capture (m14-d C5 live gate; app `debug.*` tier)

    /// Starts a sample-level capture of the master summing bus —
    /// `mainMixerNode`'s output (post-strip-chains and strip faders,
    /// pre-master-insert; the meter/analysis tap lives on the master CHAIN
    /// HOST's output, so this bus is tap-free — one tap per bus is the
    /// AVFoundation limit). A DEBUG affordance for verification gates that
    /// need sample-level evidence — C5: a chain tail crossing the live loop
    /// seam and the absence of the old 60 ms zero-run, which the meter tap's
    /// UI-rate scalars cannot carry. Deliberately concrete-class-only (NOT
    /// on `AudioEngineControlling`): the app's debug tier owns the concrete
    /// engine (the `hostedInstrumentAudioUnit` precedent) and this never
    /// becomes an agent-facing capability. One capture at a time. Buffers
    /// cross from AVFoundation's tap queue to a serial writer queue — the
    /// InputCapture/RecordingWriter discipline; nothing here touches the
    /// render thread.
    public func startDebugMasterCapture(toPath path: String) throws {
        guard debugCapture == nil else {
            throw EngineError.renderFailed(
                "debug master capture already running — stop it first")
        }
        guard isRunning else {
            throw EngineError.renderFailed(
                "engine not running — start playback before capturing")
        }
        let node = engine.mainMixerNode
        let format = node.outputFormat(forBus: 0)
        let capture = try DebugMasterCapture(
            node: node, url: URL(fileURLWithPath: path), format: format)
        node.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable buffer, _ in
            capture.append(buffer)
        }
        debugCapture = capture
    }

    /// Stops the debug capture: removes the tap, drains the writer queue,
    /// and closes the file (deallocation flushes the header — the
    /// RecordingWriter convention). Returns frames written; nil when no
    /// capture was armed. Idempotent.
    @discardableResult
    public func stopDebugMasterCapture() -> Int64? {
        guard let capture = debugCapture else { return nil }
        capture.node.removeTap(onBus: 0)
        debugCapture = nil
        return capture.finalize()
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

/// m14-d (C5 live gate): the debug master-bus capture writer — tap
/// deliveries cross onto a serial queue that owns the `AVAudioFile` (the
/// `RecordingWriter` discipline, minimal form: no accept window, no
/// host-time alignment — verification captures analyze relative structure).
/// `@unchecked Sendable` justification: `file`/`frames` are only touched on
/// `queue`; `node` is immutable and only dereferenced on the main actor (the
/// engine's stop path removes the tap from it).
private final class DebugMasterCapture: @unchecked Sendable {
    /// One tap delivery crossing onto the writer queue — the RecordingWriter
    /// `TapDelivery` justification verbatim: the tap hands over a freshly
    /// allocated buffer it never touches again, and exactly one consumer
    /// (the serial queue) reads it.
    private struct TapDelivery: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    /// The tapped node, kept so `stopDebugMasterCapture` removes the tap
    /// from the node that actually carries it (the `meterTapNode` rule).
    let node: AVAudioNode
    private let queue = DispatchQueue(label: "dawpro.debug-master-capture")
    private var file: AVAudioFile?
    private var frames: Int64 = 0

    init(node: AVAudioNode, url: URL, format: AVAudioFormat) throws {
        self.node = node
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Callable from the tap's delivery thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        let delivery = TapDelivery(buffer: buffer)
        queue.async { [self] in
            guard let file else { return }  // finalized or write-failed
            do {
                try file.write(from: delivery.buffer)
                frames += Int64(delivery.buffer.frameLength)
            } catch {
                // First failure stops the capture's writes; the partial file
                // stays readable (header flushed on finalize/dealloc).
                self.file = nil
            }
        }
    }

    /// Drains queued deliveries and closes the file — deallocation flushes
    /// the header (the RecordingWriter convention; the explicit pool keeps
    /// an autoreleased reference from deferring it, because the gate reads
    /// the file immediately). Returns total frames written.
    func finalize() -> Int64 {
        queue.sync {
            autoreleasepool { file = nil }
            return frames
        }
    }
}
