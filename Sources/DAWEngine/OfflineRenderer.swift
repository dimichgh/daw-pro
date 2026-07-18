import AVFAudio
import DAWCore
import Foundation

// `RenderedAudio` (the deinterleaved render-output shape) moved to DAWCore in
// M5 iv-a so pure loudness measurement can consume it engine-free.

public enum EngineError: Error, LocalizedError {
    case renderFailed(String)
    case recordingFailed(String)
    /// An Objective-C exception AVFAudio raised inside a control-plane entry
    /// point, caught by the m16-a exception barrier and converted here so it
    /// surfaces as an ordinary thrown error (the wire's LocalizedError
    /// mapping turns it into a teaching message) instead of unwinding through
    /// a MainActor job frame — the proven poisoner (leaked executor-tracking
    /// TLS record → SE-0423 check crash or silent MainActor wedge; see
    /// docs/research/design-m16a-canvas-crash.md).
    case engineException(name: String, reason: String, context: String)

    public var errorDescription: String? {
        switch self {
        case .renderFailed(let reason):
            return "Offline render failed: \(reason)"
        case .recordingFailed(let reason):
            return "recording failed: \(reason)"
        case .engineException(_, let reason, let context):
            return "the audio engine raised '\(reason)' during \(context) — "
                + "playback was stopped; play again, or reopen the project if it persists"
        }
    }
}

/// Renders a track list through a fresh `AVAudioEngine` in `.offline` manual
/// rendering mode, driving the SAME `PlaybackGraph` (same reconcile code, same
/// scheduling math, same connect formats) as live playback. Players start with
/// a nil anchor before the first pull, so player time 0 ≡ rendered sample 0 —
/// fully deterministic, which is what makes sample-accuracy tests possible.
///
/// Looping is intentionally ignored here: the offline renderer produces one
/// linear pass over `[fromBeat, fromBeat + duration)`. Loop wrapping is a
/// live-transport concern (see `AudioEngine`'s playhead task).
@MainActor
public final class OfflineRenderer {
    private let sampleRate: Double
    private let channelCount: Int
    private let maximumFrameCount: Int

    /// Per-track meter frames from the graph's mixer taps, delivered on the
    /// main actor. Taps fire during manual-rendering pulls, so the hopped
    /// frames land once the caller next suspends — headless meter tests wait
    /// briefly after `render` returns.
    public var meterSink: ((UUID, MeterFrame) -> Void)?

    /// Test seam: overrides the graph's instrument factory (default:
    /// descriptor-resolved built-in instrument — poly synth unless the track
    /// selects `.testTone`) so offline event-timestamp tests can inject
    /// `EventCaptureInstrument`. Internal — tests reach it via @testable.
    var instrumentFactory: (@MainActor (Track) -> any InstrumentRendering)?

    /// Resolves one NON-IDENTITY stretched clip to its rendered CAF (M5
    /// ii-d), nil = not rendered → the clip bounces SILENT, never wrong-speed
    /// audio. `AudioEngine.renderMixdown` wires this to a pure
    /// `StretchRenderCache` lookup after awaiting all pending renders;
    /// identity clips never consult it (the bypass contract). Default nil:
    /// non-identity clips are silent — direct callers must provide renders.
    var stretchedFileProvider: (@MainActor (Clip) -> URL?)?

    /// Test seam (M4 viii-b/-c): nil (default) = always-on plan-driven PDC —
    /// the graph recomputes every strip's target in each parameter pass,
    /// exactly like the live engine. Non-nil forces `targets[id] ?? 0` per
    /// strip (hand-computed or deliberately WRONG targets for ring proofs).
    /// Internal — @testable only.
    var compensationTargets: [UUID: Int]?

    /// This renderer's OWN Audio Unit registry (fresh AU instances per render
    /// at the renderer's rate — never the live engine's instruments). Wired to
    /// the graph's `audioUnitProvider` inside `render`. Internal so hosting
    /// tests can read per-track status via @testable.
    let auRegistry = AUHostRegistry()

    /// C0 SPIKE SEAM ONLY (m13-d, `MasterSandwichTransparencyTests`):
    /// forwarded to the graph so the KEPT bit-transparency gate can render
    /// the pre-m13-d topology against the D1 master sandwich through the
    /// REAL production render loop. Production never touches it.
    var masterSandwichEnabled = true

    /// Render-load telemetry sink (M9 perf-b), handed to the graph before
    /// reconcile so offline pulls stamp the same counters live rendering
    /// does. `AudioEngine.renderOffline` assigns its OWN context here — that
    /// is what makes a headless bounce visible to `engine.performanceStats`.
    /// Default: a private throwaway (direct construction stays isolated).
    var performance = EnginePerformanceContext()

    public init(sampleRate: Double = 48_000, channelCount: Int = 2,
                maximumFrameCount: Int = 4_096) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.maximumFrameCount = maximumFrameCount
    }

    /// Instantiates and prepares a hosted instrument for every `.audioUnit`
    /// and `.soundBank` track (m10-n — the bank loads AGAIN into this
    /// renderer's own registry: fresh AU instances per render, a second
    /// transient RAM copy during a bounce; trivial for GM, documented for
    /// GB-scale SF2s — R9), at the renderer's sample rate. MUST run (and
    /// complete) before `render`/`renderToWAV` for those tracks to sound — a
    /// hosted track without this pre-step renders the silent placeholder with
    /// a stderr warning.
    public func prepareAudioUnits(tracks: [Track]) async {
        for track in tracks
        where track.kind == .instrument
            && [.audioUnit, .soundBank].contains((track.instrument ?? .default).kind) {
            await auRegistry.prepare(track: track, sampleRate: sampleRate)
        }
        // Hosted insert effects too (M4 v) — every strip kind can carry them.
        for track in tracks {
            for effect in track.effects
            where effect.kind == .audioUnit {
                guard let config = effect.audioUnit else { continue }
                await auRegistry.prepareEffect(effectID: effect.id, config: config,
                                               sampleRate: sampleRate,
                                               maxFrames: maximumFrameCount)
            }
        }
    }

    /// `metronomeEnabled` attaches a Metronome to the offline engine and
    /// schedules clicks across the whole render range (`meterMap` — the REAL
    /// meter map, m15-a — shapes the downbeat pattern; before m15-a this took
    /// a `beatsPerBar` scalar and built a constant map, flattening multi-meter
    /// projects offline exactly like the live bug in audit-m15 §2-B1) —
    /// headless, assertion-checkable click output. m12-b (design row 53): the
    /// render window maps through `tempoMap`.
    ///
    /// `masterEffects` (m13-d): the master insert chain this render applies —
    /// `[]` renders the bit-transparent empty sandwich. The CLASS-level
    /// default is deliberate (design §2.1): it keeps the large engine test
    /// surface compiling, while the render-class decision (MASTERED vs STEM,
    /// design §2) lives at the protocol/store layer, which has NO default.
    /// Built-ins only in v1 (design D4a) — `prepareAudioUnits` needs no
    /// master loop.
    ///
    /// `masterAutomation` (m15-c): the master volume lane this render applies
    /// — same class-level-default rationale; `[]` leaves the master fader at
    /// the static `masterVolume`, byte-identical to pre-m15-c.
    public func render(tracks: [Track], tempoMap: TempoMap,
                       fromBeat: Double = 0,
                       durationSeconds: Double,
                       masterVolume: Double = 1,
                       masterEffects: [EffectDescriptor] = [],
                       masterAutomation: [AutomationLane] = [],
                       metronomeEnabled: Bool = false,
                       meterMap: MeterMap = MeterMap(constant: TimeSignature())) throws -> RenderedAudio {
        let session = try beginSession(
            tracks: tracks, tempoMap: tempoMap, fromBeat: fromBeat,
            durationSeconds: durationSeconds, masterVolume: masterVolume,
            masterEffects: masterEffects, masterAutomation: masterAutomation,
            metronomeEnabled: metronomeEnabled, meterMap: meterMap)
        while !session.isComplete {
            try session.pullNextQuantum()
        }
        return session.finish()
    }

    /// m19-j — the COOPERATIVE render: the identical pull sequence to
    /// `render` (same session, same quantum math, bit-identical output), but
    /// the loop yields the main actor between quanta. A long bounce used to
    /// hold the main actor for its whole wall time (measured 5.7 s for the
    /// MCP integration suite's >5 s program on a debug build — past the
    /// 2.5 s m18-b wedge threshold, so every control command failed fast on
    /// the watchdog intercept until the backlog drained; a full-length song
    /// is ~25 s of frozen UI). Yielding every quantum caps the block at ONE
    /// quantum (~85 ms of audio) and lets liveness pongs, meter deliveries,
    /// and control commands interleave. Interleaved commands are safe by
    /// construction: this renderer owns a fresh engine/graph/registry, and
    /// the track list is a value-type snapshot taken at call time (the
    /// bounce renders the project as requested — WYSIWYG).
    ///
    /// The m16-a exception barrier moves INSIDE (it cannot span an await):
    /// every synchronous AVFAudio section runs under the same
    /// "offline render" context `AudioEngine.renderOffline` used to apply
    /// around the whole call — raise conversion is behavior-identical.
    public func renderCooperatively(
        tracks: [Track], tempoMap: TempoMap,
        fromBeat: Double = 0,
        durationSeconds: Double,
        masterVolume: Double = 1,
        masterEffects: [EffectDescriptor] = [],
        masterAutomation: [AutomationLane] = [],
        metronomeEnabled: Bool = false,
        meterMap: MeterMap = MeterMap(constant: TimeSignature())
    ) async throws -> RenderedAudio {
        let session = try withObjCExceptionBarrier("offline render") {
            try beginSession(
                tracks: tracks, tempoMap: tempoMap, fromBeat: fromBeat,
                durationSeconds: durationSeconds, masterVolume: masterVolume,
                masterEffects: masterEffects, masterAutomation: masterAutomation,
                metronomeEnabled: metronomeEnabled, meterMap: meterMap)
        }
        while !session.isComplete {
            try withObjCExceptionBarrier("offline render") {
                try session.pullNextQuantum()
            }
            await Task.yield()
        }
        return try withObjCExceptionBarrier("offline render") {
            session.finish()
        }
    }

    /// The shared setup for both render drivers: builds the offline engine +
    /// graph, schedules everything, starts players, and returns the pull-loop
    /// state. Extracted VERBATIM from the original `render` body (m19-j) —
    /// call order is load-bearing (see the inline measurement notes).
    private func beginSession(tracks: [Track], tempoMap: TempoMap,
                              fromBeat: Double,
                              durationSeconds: Double,
                              masterVolume: Double,
                              masterEffects: [EffectDescriptor],
                              masterAutomation: [AutomationLane],
                              metronomeEnabled: Bool,
                              meterMap: MeterMap) throws -> OfflineRenderSession {
        let engine = AVAudioEngine()
        // m20-c: the graph's rate is injected — the renderer's own rate, the
        // same value `enableManualRenderingMode` below pins on the engine.
        let graph = PlaybackGraph(engine: engine, graphRate: sampleRate)
        graph.meterSink = meterSink
        // Telemetry lands before reconcile — node creation is where the
        // context is captured (renderers at init, chain hosts via setter).
        graph.performance = performance
        // Master chain (m13-d): descriptors land before reconcile builds the
        // sandwich; the parameter passes below sync them (R6). The spike
        // seam rides along (production default: sandwich on).
        graph.masterEffects = masterEffects
        graph.masterSandwichEnabled = masterSandwichEnabled
        // Master volume automation (m15-c): lanes + the manual gain land
        // before the parameter passes, so the pre-start pass pins the master
        // fader (lane active) or leaves the static write below untouched.
        graph.masterAutomation = masterAutomation
        graph.manualMasterVolume = masterVolume.clamped(to: Track.volumeRange)

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount)
        ) else {
            throw EngineError.renderFailed("invalid render format \(sampleRate) Hz × \(channelCount) ch")
        }
        // Manual rendering mode is enabled BEFORE reconcile so the track-mixer
        // connections form at the offline graph rate, not the hardware rate.
        try engine.enableManualRenderingMode(
            .offline, format: format,
            maximumFrameCount: AVAudioFrameCount(maximumFrameCount)
        )
        // Touching mainMixerNode implicitly wires mixer -> output. Without it
        // an empty project leaves the output node inputless and renderOffline
        // crashes (measured: SIGSEGV on the first pull).
        _ = engine.mainMixerNode
        // Instrument factory lands BEFORE reconcile — that's where instrument
        // nodes (and their instruments) are created.
        if let instrumentFactory {
            graph.instrumentFactory = instrumentFactory
        }
        // Stretched-clip resolver likewise (clip nodes open their files in
        // reconcile). Offline resolution is a pure lookup — no job kicks; a
        // missing render answers `.pending` and the clip bounces silent.
        if let stretchedFileProvider {
            graph.stretchResolver = { clip in
                stretchedFileProvider(clip).map(PlaybackGraph.StretchResolution.ready)
                    ?? .pending
            }
        }
        // Hosted AUs come from THIS renderer's registry; a `.audioUnit` track
        // that skipped the async prepareAudioUnits pre-step renders the
        // silent placeholder, loudly.
        graph.audioUnitProvider = { [auRegistry] track in
            auRegistry.preparedInstrument(forTrack: track.id)
        }
        // Hosted insert effects likewise; an unprepared `.audioUnit` effect
        // runs the bit-exact passthrough placeholder, loudly.
        graph.hostedEffectProvider = { [auRegistry] effectID in
            auRegistry.preparedEffect(forEffect: effectID)
        }
        for track in tracks {
            for effect in track.effects
            where effect.kind == .audioUnit
                && auRegistry.preparedEffect(forEffect: effect.id) == nil {
                FileHandle.standardError.write(Data(
                    "OfflineRenderer: Audio Unit effect on track '\(track.name)' is not prepared — passing dry (await prepareAudioUnits(tracks:) first)\n".utf8))
            }
        }
        for track in tracks
        where track.kind == .instrument
            && [.audioUnit, .soundBank].contains((track.instrument ?? .default).kind)
            && auRegistry.preparedInstrument(forTrack: track.id) == nil {
            FileHandle.standardError.write(Data(
                "OfflineRenderer: hosted instrument for track '\(track.name)' is not prepared — rendering silence (await prepareAudioUnits(tracks:) first)\n".utf8))
        }
        // Non-nil seam suppresses the automatic plan for this graph; the
        // parameter passes below then force the given targets each pass.
        graph.compensationOverride = compensationTargets
        graph.reconcile(tracks: tracks)
        // Attached before start(), like the clip nodes, so the connection
        // forms at the offline graph rate.
        let metronome: Metronome?
        if metronomeEnabled {
            let click = Metronome()
            click.attach(to: engine, graphRate: sampleRate)
            metronome = click
        } else {
            metronome = nil
        }

        // Mixer parameters apply TWICE, around engine.start() — measured
        // AUMultiChannelMixer behavior demands both:
        //   pre-start:  volumes stick and take effect from frame 0 with no
        //               parameter ramp (a post-start 1→0 ramp leaked ~0.5 peak
        //               into a muted render); pan set here is DISCARDED.
        //   post-start: start() re-initializes the mixer input buses, so pan
        //               only holds when set now. Volumes re-set to identical
        //               values don't move, so nothing ramps.
        engine.mainMixerNode.outputVolume = Float(masterVolume.clamped(to: Track.volumeRange))
        // Automation (M4 vii-b) arms BEFORE the pre-start pass so a
        // volume-lane strip pins its mixer to (gated ? 0 : 1) pre-start —
        // in place from frame 0, no ramp — and the render stage owns the
        // lane gain for the whole bounce (.offline first-pull epoch).
        graph.armOfflineAutomation(fromBeat: fromBeat, tempoMap: tempoMap)
        graph.applyParameters(tracks: tracks, playheadBeat: fromBeat)
        try engine.start()
        graph.applyParameters(tracks: tracks, playheadBeat: fromBeat)
        graph.scheduleAll(fromBeat: fromBeat, tempoMap: tempoMap)
        if let metronome {
            // One click per integer beat across the render range (the window
            // end is the inverse integral of the render duration — m12-b,
            // design row 52); nil anchor = player time 0 ≡ rendered sample 0,
            // same as the clip players.
            metronome.scheduleClicks(
                fromBeat: fromBeat,
                throughBeat: tempoMap.beat(from: fromBeat, elapsedSeconds: durationSeconds),
                tempoMap: tempoMap,
                meterMap: meterMap,
                playerStartBeat: fromBeat
            )
            metronome.start(at: nil)
        }
        graph.startAllPlayers(at: nil)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(maximumFrameCount)
        ) else {
            throw EngineError.renderFailed("could not allocate render buffer")
        }

        return OfflineRenderSession(
            engine: engine, graph: graph, metronome: metronome, buffer: buffer,
            sampleRate: sampleRate, channelCount: channelCount,
            maximumFrameCount: maximumFrameCount,
            totalFrames: Int((durationSeconds * sampleRate).rounded()))
    }

    /// One in-flight offline render's pull-loop state (m19-j): the started
    /// engine, the graph and metronome KEPT ALIVE for the render's duration
    /// (nodes, taps, and click players die with them), the reusable pull
    /// buffer, and the accumulated channel data. Both drivers — `render`
    /// (synchronous, tests and planners) and `renderCooperatively` (yields
    /// between quanta) — run the byte-identical pull sequence through here.
    @MainActor
    final class OfflineRenderSession {
        private let engine: AVAudioEngine
        private let graph: PlaybackGraph
        private let metronome: Metronome?
        private let buffer: AVAudioPCMBuffer
        private let sampleRate: Double
        private let channelCount: Int
        private let maximumFrameCount: Int
        private let totalFrames: Int
        private var channelData: [[Float]]
        private var renderedFrames = 0

        init(engine: AVAudioEngine, graph: PlaybackGraph, metronome: Metronome?,
             buffer: AVAudioPCMBuffer, sampleRate: Double, channelCount: Int,
             maximumFrameCount: Int, totalFrames: Int) {
            self.engine = engine
            self.graph = graph
            self.metronome = metronome
            self.buffer = buffer
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.maximumFrameCount = maximumFrameCount
            self.totalFrames = totalFrames
            channelData = [[Float]](repeating: [], count: channelCount)
            for channel in 0..<channelCount {
                channelData[channel].reserveCapacity(totalFrames)
            }
        }

        var isComplete: Bool { renderedFrames >= totalFrames }

        /// Renders one quantum and appends it — the original loop body,
        /// verbatim. Failure stops the engine and throws, exactly as before.
        func pullNextQuantum() throws {
            let request = AVAudioFrameCount(min(totalFrames - renderedFrames, maximumFrameCount))
            let status = try engine.renderOffline(request, to: buffer)
            switch status {
            case .success:
                guard let source = buffer.floatChannelData else {
                    throw EngineError.renderFailed("render buffer has no float channel data")
                }
                let frames = Int(buffer.frameLength)
                for channel in 0..<channelCount {
                    channelData[channel].append(
                        contentsOf: UnsafeBufferPointer(start: source[channel], count: frames)
                    )
                }
                renderedFrames += frames
            default:
                engine.stop()
                throw EngineError.renderFailed("renderOffline returned status \(status.rawValue)")
            }
        }

        /// Stops the engine and hands the accumulated audio over.
        func finish() -> RenderedAudio {
            engine.stop()
            return RenderedAudio(sampleRate: sampleRate, channelData: channelData)
        }
    }

    /// The full-session per-strip compensation targets EXACTLY as the
    /// automatic plan of a real render pass would apply them (M5 iv-b, spec
    /// §5): builds the offline graph — manual-rendering mode, reconcile, one
    /// pre-start parameter pass, which is the recompute choke point `render`
    /// itself runs — and reads the graph's plan. No frames are rendered and
    /// the engine never starts. Hosted-AU latency requires
    /// `prepareAudioUnits(tracks:)` to have completed first (the `render`
    /// rule). Empty when the graph can't form (no strips, format failure).
    func compensationPlanTargets(tracks: [Track]) -> [UUID: Int] {
        let engine = AVAudioEngine()
        // m20-c: injected rate, same rule as `beginSession` — and no longer
        // dependent on `enableManualRenderingMode` landing before the first
        // `graphFormat()` call.
        let graph = PlaybackGraph(engine: engine, graphRate: sampleRate)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount)
        ), (try? engine.enableManualRenderingMode(
            .offline, format: format,
            maximumFrameCount: AVAudioFrameCount(maximumFrameCount))) != nil else {
            return [:]
        }
        // Same implicit mixer→output wiring rule as `render`.
        _ = engine.mainMixerNode
        graph.audioUnitProvider = { [auRegistry] track in
            auRegistry.preparedInstrument(forTrack: track.id)
        }
        graph.hostedEffectProvider = { [auRegistry] effectID in
            auRegistry.preparedEffect(forEffect: effectID)
        }
        graph.reconcile(tracks: tracks)
        graph.applyParameters(tracks: tracks, playheadBeat: 0)
        guard let report = graph.pdcReport else { return [:] }
        return report.strips.mapValues(\.compensationSamples)
    }

    /// Renders via `render(...)` and writes the result to `url` as a Float32
    /// WAV (parent directories are created recursively). Returns the facts of
    /// the written file. The write is frame-exact: the file holds exactly the
    /// samples `render` produced, bit for bit.
    public func renderToWAV(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                            masterEffects: [EffectDescriptor] = [],
                            masterAutomation: [AutomationLane] = [],
                            fromBeat: Double, durationSeconds: Double,
                            to url: URL) throws -> AudioFileInfo {
        let audio = try render(
            tracks: tracks, tempoMap: tempoMap, fromBeat: fromBeat,
            durationSeconds: durationSeconds, masterVolume: masterVolume,
            masterEffects: masterEffects,
            masterAutomation: masterAutomation
        )
        return try Self.writeWAV(audio, to: url)
    }

    /// The WAV writer, split out of `renderToWAV` (M5 iv-b, spec §5) so the
    /// engine seam can persist any `RenderedAudio` — gained bounces, stem
    /// buffers — with the exact same frame-exact Float32 semantics.
    static func writeWAV(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: audio.sampleRate,
            channels: AVAudioChannelCount(audio.channelData.count)
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, audio.frameCount))
        ), let destination = buffer.floatChannelData else {
            throw EngineError.renderFailed(
                "could not allocate a \(audio.frameCount)-frame write buffer"
            )
        }
        for channel in 0..<audio.channelData.count {
            audio.channelData[channel].withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    destination[channel].update(from: base, count: source.count)
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(audio.frameCount)

        // File settings come straight from the manual-rendering format
        // (Float32 linear PCM); WAV payloads are interleaved on disk, so that
        // single key is overridden.
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Scoped so the AVAudioFile deallocates (flushes and closes)
            // before anyone reads the file back.
            let file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch {
            throw EngineError.renderFailed(
                "could not write WAV to \(url.path): \(error.localizedDescription)"
            )
        }

        return AudioFileInfo(
            durationSeconds: Double(audio.frameCount) / audio.sampleRate,
            sampleRate: audio.sampleRate,
            channelCount: audio.channelData.count
        )
    }
}
