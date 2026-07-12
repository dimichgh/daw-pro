import AVFAudio
import DAWCore
import Foundation

/// Owns the multitrack playback node tree under an `AVAudioEngine`:
///
///     clip AVAudioPlayerNode (file format) ─┐
///     clip AVAudioPlayerNode (file format) ─┼─► track AVAudioMixerNode ─► mainMixerNode
///                                            (SRC / channel-map to graph rate)
///
/// One player + one `AVAudioFile` per clip; one mixer per audio track. Players
/// connect at the file's `processingFormat`, so all schedule math stays in
/// file-rate frames — exact, with no cross-rate rounding in our code. The same
/// type drives the live `AudioEngine` and the `OfflineRenderer` so scheduling
/// behaves identically in both.
@MainActor
final class PlaybackGraph {
    /// Schedule-affecting identity of one clip. Parameter fields (volume, pan,
    /// mute, solo, name — and clip GAIN, which is a live `player.volume`
    /// write, M5 i-b) are deliberately NOT part of the signature — changing
    /// them must never trigger a stop-reschedule-resume. Fades and the source
    /// start offset ARE schedule-affecting: they re-bake windows / move the
    /// file read region, so their edits ride the existing `tracksDidChange`
    /// restart seam exactly like a clip move/resize. The three stretch fields
    /// (M5 ii-d) are schedule-affecting too — they change which FILE the node
    /// opens (the rendered CAF vs the source) and every frame position.
    struct ClipKey: Equatable {
        let id: UUID
        let startBeat: Double
        let lengthBeats: Double
        let url: URL?
        let startOffsetSeconds: Double
        let fadeInBeats: Double
        let fadeOutBeats: Double
        let fadeInCurve: FadeCurve
        let fadeOutCurve: FadeCurve
        let stretchRatio: Double
        let pitchShiftSemitones: Double
        let formantPreserve: Bool
    }

    /// Resolution of one NON-IDENTITY stretched clip at reconcile time.
    /// Identity clips (`Clip.isStretchIdentity`) never reach the resolver —
    /// the bypass contract: their schedule is byte-identical to pre-ii-d.
    enum StretchResolution {
        /// The rendered CAF exists — open THIS file instead of the source.
        /// The CAF is timeline-domain audio, so all downstream beat→frame
        /// math (fade bake, piece plans) is already correct.
        case ready(URL)
        /// Render in flight (or failed): the clip is SKIPPED — honest
        /// silence, never wrong-speed audio (spec §5). The engine's
        /// render-completion hook re-resolves through the restart seam.
        case pending
    }

    private final class ClipNode {
        let player = AVAudioPlayerNode()
        let file: AVAudioFile
        let key: ClipKey
        /// Main-actor domain copy for schedule-time work (fade bake evaluates
        /// `Clip.envelopeGain`); refreshed every reconcile pass so parameter
        /// edits (gainDb) stay current without a rebuild.
        var clip: Clip
        /// Bake-owned second reader for fade-window reads, opened lazily on
        /// the first bake. NEVER the player's `file`: `scheduleSegment`
        /// streams from that instance on its own thread, and AVAudioFile's
        /// read position is stateful — sharing it would race.
        private var bakeFile: AVAudioFile?

        init(file: AVAudioFile, key: ClipKey, clip: Clip) {
            self.file = file
            self.key = key
            self.clip = clip
        }

        func bakeReader() throws -> AVAudioFile {
            if let bakeFile { return bakeFile }
            let reader = try AVAudioFile(forReading: file.url)
            bakeFile = reader
            return reader
        }
    }

    /// One audio track's strip (M4 ii sandwich):
    ///
    ///     clip players → sumMixer (SRC/sum only, unity, no tap)
    ///                  → chainHost (permanent insert point)
    ///                  → mixer (fader/pan/mute, meter tap, fan-out source)
    ///
    /// Inserts are pre-fader; meters read post-FX; post-fader sends carry
    /// insert FX. Chain edits publish snapshots into `chainState` and NEVER
    /// touch these nodes — the sandwich is wired once per strip lifetime.
    private struct TrackNode {
        let sumMixer: AVAudioMixerNode
        let chainHost: AVAudioUnitEffect
        let chainState: EffectChainState
        /// Automation read head living inside `chainHost` (M4 vii-b) — the
        /// gain/pan stage runs post-chain-walk in its render block.
        let automation: AutomationRenderer
        let mixer: AVAudioMixerNode
        var clips: [UUID: ClipNode] = [:]
        /// One dedicated gain mixer per send (keyed by send id) — its
        /// `outputVolume` IS the send level, the only per-send gain surface
        /// with proven parameter conventions (see RoutingKey).
        var sendGainNodes: [UUID: AVAudioMixerNode] = [:]
    }

    /// Structural identity of one source track's routing: the output
    /// destination plus the identity + destination of every send, in model
    /// order. Send LEVEL is deliberately excluded — levels apply in place via
    /// `sendGain.outputVolume` in `applyParameters` and must never trigger a
    /// stop-reschedule-resume (same rule as ClipKey parameter fields).
    struct RoutingKey: Equatable {
        struct SendKey: Equatable {
            let id: UUID
            let busID: UUID
        }
        /// nil = master.
        let outputBusID: UUID?
        let sends: [SendKey]
    }

    /// One bus strip, same sandwich as audio tracks: feeder fan-outs target
    /// `sumMixer`; `mixer` keeps its existing role (bus gain/mute, meter tap,
    /// connection to the main mix).
    private struct BusNode {
        let sumMixer: AVAudioMixerNode
        let chainHost: AVAudioUnitEffect
        let chainState: EffectChainState
        /// Automation read head living inside `chainHost` (M4 vii-b).
        let automation: AutomationRenderer
        let mixer: AVAudioMixerNode
    }

    /// Schedule-affecting identity of one MIDI clip. The WHOLE notes array is
    /// in the key (value-type Equatable), so any note edit flips the signature
    /// and reschedules through the existing `tracksDidChange` restart, while
    /// volume/pan/mute/solo/name stay outside and never interrupt audio —
    /// same rule as `ClipKey`.
    struct MIDIClipKey: Equatable {
        let id: UUID
        let startBeat: Double
        let lengthBeats: Double
        let notes: [MIDINote]
    }

    /// Schedule-affecting identity of one instrument TRACK: the instrument
    /// KIND (kind change → rebuild the node with the new instrument +
    /// reschedule) plus every clip's `MIDIClipKey`. Descriptor PARAMETERS
    /// stay outside deliberately — they flow through `applyParameters` →
    /// `PolySynthInstrument.apply(params:)` / `SamplerInstrument.apply(params:)`
    /// in place, with no rebuild, no flush, and no restart (same rule as
    /// mixer volume/pan).
    ///
    /// EXCEPTION — sampler zones are STRUCTURAL: zone audio lives in
    /// immutable buffers loaded at instrument init, so any change to the
    /// zones array (files, spans, roots) must rebuild the node. The whole
    /// `SamplerZone` value is in the key, which means per-zone GAIN edits
    /// also rebuild — accepted for v0 (zone gain is an infrequent mapping
    /// edit, not a performance control; the in-place path covers the master
    /// `SamplerParams.gain`). `samplerZones` is nil for non-sampler kinds so
    /// other instruments never rebuild on sampler edits.
    /// Audio Unit COMPONENT identity is structural too (switching plugins
    /// rebuilds the node); stateData/name are deliberately NOT in the key —
    /// preset tweaks never tear the node down.
    /// Sound-bank ADDRESS (m10-n) is structural the same way: a
    /// source/program/MSB/LSB change rebuilds the node (release → prepare →
    /// reconcile, the AU-component swap machinery verbatim); the cosmetic
    /// `displayName` is excluded by construction and never rebuilds (LAW L8).
    struct InstrumentTrackKey: Equatable {
        let kind: InstrumentDescriptor.Kind
        let samplerZones: [SamplerZone]?
        let audioUnitComponent: AudioUnitComponentID?
        let soundBank: SoundBankConfig.Address?
        let clips: [MIDIClipKey]
    }

    /// One instrument track's nodes: source (the MIDI clock) → mixer → main
    /// mix. One source node per TRACK — its schedule merges all the track's
    /// clips. `clips` is the last reconciled clip list (main-actor copy for
    /// event building); `pendingEvents` is the build staged by `scheduleAll`
    /// and published by `startAllPlayers`.
    private final class InstrumentNode {
        let kind: InstrumentDescriptor.Kind
        /// Structural sampler payload the node was built with (nil for other
        /// kinds) — compared against the incoming signature to decide rebuild.
        let samplerZones: [SamplerZone]?
        /// Structural Audio Unit component the node was built with (nil for
        /// non-AU kinds) — same rebuild rule as sampler zones.
        let audioUnitComponent: AudioUnitComponentID?
        /// Structural sound-bank address the node was built with (nil for
        /// other kinds, m10-n) — same rebuild rule as the AU component.
        let soundBankAddress: SoundBankConfig.Address?
        let mixer: AVAudioMixerNode
        let source: AVAudioSourceNode
        let renderer: InstrumentRenderer
        let instrument: any InstrumentRendering
        /// Chain sync half for this strip (M4 ii); the processor lives inside
        /// `renderer` — the walk runs in `renderQuantum`, zero extra nodes.
        let chainState: EffectChainState
        var clips: [Clip] = []
        var pendingEvents: [ScheduledMIDIEvent] = []
        /// Same per-send gain mixers as TrackNode — instrument tracks route
        /// and send identically to audio tracks.
        var sendGainNodes: [UUID: AVAudioMixerNode] = [:]

        init(kind: InstrumentDescriptor.Kind, samplerZones: [SamplerZone]?,
             audioUnitComponent: AudioUnitComponentID?,
             soundBankAddress: SoundBankConfig.Address?,
             mixer: AVAudioMixerNode, source: AVAudioSourceNode,
             renderer: InstrumentRenderer, instrument: any InstrumentRendering,
             chainState: EffectChainState) {
            self.kind = kind
            self.samplerZones = samplerZones
            self.audioUnitComponent = audioUnitComponent
            self.soundBankAddress = soundBankAddress
            self.mixer = mixer
            self.source = source
            self.renderer = renderer
            self.instrument = instrument
            self.chainState = chainState
        }
    }

    private let engine: AVAudioEngine
    private var trackNodes: [UUID: TrackNode] = [:]
    private var instrumentNodes: [UUID: InstrumentNode] = [:]
    private var busNodes: [UUID: BusNode] = [:]
    private(set) var signature: [UUID: [ClipKey]] = [:]
    private(set) var instrumentSignature: [UUID: InstrumentTrackKey] = [:]
    /// Structural routing identity per source (audio + instrument) track.
    private(set) var routingSignature: [UUID: RoutingKey] = [:]
    /// Bus track ids, model order.
    private(set) var busSignature: [UUID] = []
    /// Monotonic schedule generation — the render side resets its event
    /// cursor (and offline epoch) whenever it changes.
    private var scheduleGeneration: UInt64 = 0

    // MARK: Automation state (M4 vii-b)

    /// Monotonic automation-schedule generation — SEPARATE from the player
    /// `scheduleGeneration` by construction: a point edit during playback
    /// republishes automation WITHOUT touching any player schedule (the
    /// no-restart rule; automation appears in no reconcile signature).
    private var automationGeneration: UInt64 = 0
    /// Roll context: non-nil while players roll (set by `startAllPlayers`,
    /// cleared by `stopAllPlayers`, armed early by `armOfflineAutomation`).
    /// The override rule keys off it, and the stored mapping lets a
    /// mid-playback point edit republish against the SAME timeline (same
    /// anchor/epoch — the render cursors just re-seek).
    private var automationRollContext:
        (fromBeat: Double, tempoMap: TempoMap, mode: AutomationSchedule.Mode)?
    /// Timeline mapping staged by `scheduleAll` for the next `startAllPlayers`
    /// (the `pendingEvents` convention).
    private var stagedAutomationStart: (fromBeat: Double, tempoMap: TempoMap) =
        (0, TempoMap(constantBPM: 120))
    /// ACTIVE (enabled, non-empty) volume/pan lanes per strip plus the
    /// RESOLVED effect-param lane specs (M4 vii-c), recorded by
    /// `applyParameters` from the SAME tracks pass that writes the mixers —
    /// the publish source for `startAllPlayers` and the change detector for
    /// the no-restart republish.
    private var activeAutomationLanes:
        [UUID: (volume: AutomationLane?, pan: AutomationLane?,
                effectParams: [AutomationSchedule.EffectParamLaneSpec])] = [:]
    /// Lanes behind each strip's currently PUBLISHED schedule (main-actor
    /// bookkeeping only).
    private var publishedAutomationLanes:
        [UUID: (volume: AutomationLane?, pan: AutomationLane?,
                effectParams: [AutomationSchedule.EffectParamLaneSpec])] = [:]
    /// The last tracks `applyParameters` saw — `startAllPlayers` re-runs the
    /// parameter pass with them so the override pin lands at roll start.
    private var lastParameterTracks: [Track] = []

    /// Supplies the prepared hosted-AU instrument for a `.audioUnit` track,
    /// or nil while preparation is pending/missing/failed (→ silent
    /// placeholder). AudioEngine and OfflineRenderer point this at their
    /// respective `AUHostRegistry`.
    var audioUnitProvider: @MainActor (Track) -> (any InstrumentRendering)? = { _ in nil }

    /// The prepared hosted AU EFFECT for one insert-effect id (M4 v), read by
    /// every strip's `EffectChainState` at sync time (through a weak-graph
    /// thunk, so it always sees the CURRENT provider). nil → the passthrough
    /// placeholder. AudioEngine/OfflineRenderer point this at their registry.
    var hostedEffectProvider: @MainActor (UUID) -> (any EffectRendering)? = { _ in nil }

    /// Builds the instrument for a new instrument track by resolving its
    /// descriptor: nil ⇒ `.default` ⇒ the built-in poly synth (M3 iv);
    /// `.testTone` keeps the bare sine engine-test instrument; `.audioUnit`
    /// asks `audioUnitProvider` and falls back to the silent placeholder.
    /// Internal seam so tests (@testable) can inject `EventCaptureInstrument`.
    lazy var instrumentFactory: @MainActor (Track) -> any InstrumentRendering = { [unowned self] track in
        let descriptor = track.instrument ?? .default
        switch descriptor.kind {
        case .testTone: return TestToneInstrument()
        case .polySynth: return PolySynthInstrument(params: descriptor.polySynth)
        case .sampler: return SamplerInstrument(params: descriptor.resolvedSampler)
        case .audioUnit: return self.audioUnitProvider(track) ?? SilentPlaceholderInstrument()
        // The provider consults the registry BY TRACK ID, so the hosted
        // AUSampler for a sound-bank track (m10-n) arrives through the same
        // seam — no new provider needed. Pending/failed/missing → silence.
        case .soundBank: return self.audioUnitProvider(track) ?? SilentPlaceholderInstrument()
        }
    }

    /// Resolves the stretched render for one NON-IDENTITY clip (M5 ii-d).
    /// AudioEngine points this at its `StretchRenderCache` (a `.pending`
    /// answer also KICKS the render job there); OfflineRenderer wires a pure
    /// cache lookup after the mixdown wait. nil (default, tests) means every
    /// non-identity clip is pending — silence, never wrong-speed audio.
    var stretchResolver: (@MainActor (Clip) -> StretchResolution)?

    /// Per-track meter frames, called on the main actor. Fed by a tap on each
    /// track mixer; drives both the live engine's handler and offline tests.
    var meterSink: ((UUID, MeterFrame) -> Void)?

    /// Render-load telemetry context (M9 perf-b) wired into every strip's
    /// chain host and every instrument renderer AT NODE CREATION — so it
    /// must be assigned right after init, before the first `reconcile`
    /// (AudioEngine passes its own; OfflineRenderer passes the one
    /// `AudioEngine.renderOffline` hands it, which is how offline bounces
    /// count into `engine.performanceStats`). Default: a private throwaway
    /// so direct-graph tests stay isolated.
    var performance = EnginePerformanceContext()

    /// Fired at most ONCE per reconcile pass (and by
    /// `invalidateInstrumentNode`), synchronously, immediately BEFORE the
    /// first routing-topology mutation: a fan-out rewire, send-gain teardown,
    /// bus removal, or the teardown of a source node with non-trivial
    /// routing. Routing rewires are NOT safe against a running AVAudioEngine
    /// (measured live: a mid-play send add leaves its new gain→bus branch
    /// silent until the engine restarts; removing a live bus SEGFAULTs the
    /// render thread), so the live engine stops itself in this hook — the
    /// wiring then mutates in the stopped state, the exact build order the
    /// offline renderer uses — and restarts after reconcile with the
    /// double-apply convention. TRIVIAL wiring (a fresh node connecting
    /// straight to master with no sends — the pre-M4 track add, live-proven)
    /// never fires it, so plain track adds keep recording/capture running.
    /// Nil (offline render, tests) = no-op.
    var willMutateRoutingTopology: (() -> Void)?

    /// IDs of every track currently in the node tree (audio + instrument +
    /// bus) — bus inclusion gives buses the stop-time meter-silence push for
    /// free.
    var trackIDs: [UUID] {
        Array(trackNodes.keys) + Array(instrumentNodes.keys) + Array(busNodes.keys)
    }

    /// True when at least one strip carrying an instrumented render block
    /// exists — the crash-c watchdog's arming condition. EVERY strip kind
    /// qualifies: audio and bus strips render through their permanent
    /// `ChainHostAU` sandwich, instrument strips through their
    /// `InstrumentRenderer` source node, and both stamp the telemetry
    /// heartbeat once per pulled quantum. With ZERO strips the heartbeat has
    /// no producer by construction, so a running-but-empty session must read
    /// as "no signal expected", never as a stall.
    var hasInstrumentedStrips: Bool {
        !trackNodes.isEmpty || !instrumentNodes.isEmpty || !busNodes.isEmpty
    }

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    // MARK: - Node retirement (M9 crash-a)

    /// True once the LIVE engine has completed a `start()` — set by
    /// AudioEngine. Offline renderers and headless test graphs never set it,
    /// so their stopped-state detaches (the proven-safe cold build order)
    /// stay immediate.
    var engineHasRun = false

    /// Teardown detaches that arrived while the engine was STOPPED after
    /// having run — the root cause of the M9 teardown crash
    /// (docs/research/fix-teardown-crash.md): AVFoundation completes a
    /// detach's internal graph bookkeeping only when it can synchronize with
    /// a running engine. Detaching a once-rendered node while stopped leaves
    /// a stale raw node pointer in `AVAudioEngineGraph`'s internal list (it
    /// survives `reset()` + `start()`; explicit disconnects don't purge it
    /// either — both measured), and the next `connect` against the running
    /// engine walks it: use-after-free. Nodes parked here stay attached AND
    /// strongly held — no freed-memory window can exist — until
    /// `flushRetiredNodes()` detaches them against a running engine. FIFO,
    /// so the reconcile edge order (feeders before buses) survives deferral.
    private(set) var pendingDetachNodes: [AVAudioNode] = []

    /// The ONLY sanctioned detach for teardown paths. Engine running →
    /// detach now (AVFoundation's dynamic-reconfig path, live-proven at
    /// 28-strip scale). Stopped after having run → park in the bin. Never
    /// ran → detach now (offline/test build order, behavior unchanged).
    private func retireNode(_ node: AVAudioNode) {
        if engine.isRunning || !engineHasRun {
            engine.detach(node)
        } else {
            pendingDetachNodes.append(node)
        }
    }

    /// Drains the pending-detach bin against a RUNNING engine. AudioEngine
    /// calls this after every successful `engine.start()` (prepare, the
    /// routing-rewire bounce, configuration-change recovery); `reconcile`
    /// also flushes defensively on entry. No-op while stopped — the bin
    /// keeps holding the nodes until the engine is next up.
    func flushRetiredNodes() {
        guard !pendingDetachNodes.isEmpty, engine.isRunning else { return }
        for node in pendingDetachNodes {
            engine.detach(node)
        }
        pendingDetachNodes.removeAll()
    }

    // MARK: - Reconcile

    /// Diffs the domain track list against the current node tree, attaching and
    /// detaching nodes as needed. Returns true when the schedule-affecting
    /// signature changed (caller decides whether to stop-reschedule-resume).
    @discardableResult
    func reconcile(tracks: [Track]) -> Bool {
        // Nodes parked across a stopped window retire before new wiring
        // lands (no-op unless the engine is running and the bin is
        // non-empty; the primary flush points live in AudioEngine's
        // post-start seams).
        flushRetiredNodes()
        // 0. Bus + routing signatures up front — the step ORDER below is
        // load-bearing: bus nodes are added before any source track wires
        // into them, and removed only after every ex-feeder is rewired.
        let newBusSignature = tracks.filter { $0.kind == .bus }.map(\.id)
        var newRoutingSignature: [UUID: RoutingKey] = [:]
        for track in tracks where track.kind != .bus {
            newRoutingSignature[track.id] = RoutingKey(
                outputBusID: track.outputBusID,
                sends: track.sends.map {
                    RoutingKey.SendKey(id: $0.id, busID: $0.destinationBusID)
                })
        }

        // 0a. Added bus nodes: the same sandwich as audio tracks (sumMixer →
        // chainHost → busMixer), connected under the main mix at the graph
        // rate, meter tap on the bus mixer only.
        var addedBuses: Set<UUID> = []
        for busID in newBusSignature where busNodes[busID] == nil {
            let node = makeStripSandwich(for: busID)
            engine.connect(node.mixer, to: engine.mainMixerNode, format: graphFormat())
            busNodes[busID] = BusNode(sumMixer: node.sumMixer, chainHost: node.chainHost,
                                      chainState: node.chainState,
                                      automation: node.automation, mixer: node.mixer)
            addedBuses.insert(busID)
        }
        let removedBuses = Set(busNodes.keys).subtracting(newBusSignature)

        // Source nodes created THIS pass — they exist but have no output
        // connection yet; the routing step below must wire them even when
        // their RoutingKey matches the stored signature.
        var freshSourceNodes: Set<UUID> = []

        // Once-per-pass announcement to `willMutateRoutingTopology`, made
        // immediately before the FIRST routing-topology mutation so the live
        // engine can leave the running state before any rewiring happens.
        var announcedRoutingMutation = false
        func announceRoutingMutation() {
            guard !announcedRoutingMutation else { return }
            announcedRoutingMutation = true
            willMutateRoutingTopology?()
        }
        // A stored key is "trivial" when the node's wiring is the pre-M4,
        // live-proven shape: one connection straight to master, no sends.
        func isTrivial(_ key: RoutingKey?) -> Bool {
            guard let key else { return true }
            return key.outputBusID == nil && key.sends.isEmpty
        }

        let audioTracks = tracks.filter { $0.kind == .audio }
        var newSignature: [UUID: [ClipKey]] = [:]
        for track in audioTracks {
            newSignature[track.id] = track.clips.map {
                ClipKey(id: $0.id, startBeat: $0.startBeat,
                        lengthBeats: $0.lengthBeats, url: $0.audioFileURL,
                        startOffsetSeconds: $0.startOffsetSeconds,
                        fadeInBeats: $0.fadeInBeats, fadeOutBeats: $0.fadeOutBeats,
                        fadeInCurve: $0.fadeInCurve, fadeOutCurve: $0.fadeOutCurve,
                        stretchRatio: $0.stretchRatio,
                        pitchShiftSemitones: $0.pitchShiftSemitones,
                        formantPreserve: $0.formantPreserve)
            }
        }

        // 1. Removed tracks: stop clip players, remove the meter tap, detach
        // players + mixer + send gain nodes. removeTap is explicit — detaching
        // a node with a live tap leaves the tap block retained against a dead
        // node. Send gains carry no taps.
        for (trackID, node) in trackNodes where newSignature[trackID] == nil {
            if !isTrivial(routingSignature[trackID]) || !node.sendGainNodes.isEmpty {
                announceRoutingMutation()  // tearing down bus-facing wiring
            }
            for clip in node.clips.values {
                clip.player.stop()
                retireNode(clip.player)
            }
            node.mixer.removeTap(onBus: 0)
            retireNode(node.mixer)
            retireNode(node.chainHost)
            retireNode(node.sumMixer)
            for gain in node.sendGainNodes.values {
                retireNode(gain)
            }
            trackNodes.removeValue(forKey: trackID)
        }

        // 2 + 3. Added tracks, then per-track clip diffs by ClipKey.
        for track in audioTracks {
            let keys = newSignature[track.id] ?? []
            var node: TrackNode
            if let existing = trackNodes[track.id] {
                node = existing
            } else {
                node = addTrackNode(for: track.id)
                freshSourceNodes.insert(track.id)
            }
            let keyByID = Dictionary(keys.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
            let clipByID = Dictionary(track.clips.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })

            // Removed clips, and clips whose schedule key changed (remove + re-add).
            for (clipID, clipNode) in node.clips {
                if let newKey = keyByID[clipID], newKey == clipNode.key {
                    // Same schedule identity — refresh the domain copy so
                    // parameter fields (gainDb) stay current for the next
                    // schedule/bake pass without a rebuild.
                    if let domainClip = clipByID[clipID] { clipNode.clip = domainClip }
                    continue
                }
                clipNode.player.stop()
                retireNode(clipNode.player)
                node.clips.removeValue(forKey: clipID)
            }

            // Added clips: open the file, attach a player at the file's
            // format, into the strip's sum mixer (pre-chain).
            for key in keys where node.clips[key.id] == nil {
                guard let url = key.url else { continue }  // no media (MIDI lands in M3)
                guard let domainClip = clipByID[key.id] else { continue }
                // Stretch swap (M5 ii-d): a non-identity clip opens its
                // rendered CAF instead of the source; while the render is
                // pending the clip gets NO node — silence, never wrong-speed
                // audio. The pending clip stays in `signature`, so this loop
                // re-resolves on every reconcile pass and the engine's
                // render-completion restart lands the CAF. Identity clips
                // never invoke the resolver (the bypass contract).
                var fileURL = url
                if !domainClip.isStretchIdentity {
                    switch stretchResolver?(domainClip) {
                    case .ready(let rendered): fileURL = rendered
                    case .pending, nil: continue
                    }
                }
                do {
                    let file = try AVAudioFile(forReading: fileURL)
                    let clipNode = ClipNode(file: file, key: key, clip: domainClip)
                    engine.attach(clipNode.player)
                    engine.connect(clipNode.player, to: node.sumMixer, format: file.processingFormat)
                    node.clips[key.id] = clipNode
                } catch {
                    // Skip this clip, keep playing the rest.
                    FileHandle.standardError.write(
                        Data("PlaybackGraph: cannot open \(fileURL.path): \(error)\n".utf8)
                    )
                }
            }

            trackNodes[track.id] = node
        }

        // 4. Instrument tracks: one source node (the MIDI clock) + mixer per
        // track. Note edits change the signature (reschedule via restart) but
        // never rebuild nodes — events rebuild in scheduleAll.
        let instrumentTracks = tracks.filter { $0.kind == .instrument }
        var newInstrumentSignature: [UUID: InstrumentTrackKey] = [:]
        for track in instrumentTracks {
            let descriptor = track.instrument ?? .default
            newInstrumentSignature[track.id] = InstrumentTrackKey(
                kind: descriptor.kind,
                samplerZones: descriptor.kind == .sampler
                    ? descriptor.resolvedSampler.zones : nil,
                audioUnitComponent: descriptor.kind == .audioUnit
                    ? descriptor.audioUnit?.component : nil,
                soundBank: descriptor.kind == .soundBank
                    ? descriptor.soundBank?.address : nil,
                clips: track.clips.map {
                    MIDIClipKey(id: $0.id, startBeat: $0.startBeat,
                                lengthBeats: $0.lengthBeats, notes: $0.notes ?? [])
                })
        }

        // Removed instrument tracks — and tracks whose instrument KIND,
        // sampler ZONES, AU COMPONENT, or sound-bank ADDRESS changed (torn
        // down here, rebuilt below with the new instrument; a fresh
        // SamplerInstrument reloads the zone files): unpublish + flush
        // (all-notes-off), then tap removal before detach — same rule as
        // audio tracks.
        for (trackID, node) in instrumentNodes
        where newInstrumentSignature[trackID]?.kind != node.kind
            || newInstrumentSignature[trackID]?.samplerZones != node.samplerZones
            || newInstrumentSignature[trackID]?.audioUnitComponent != node.audioUnitComponent
            || newInstrumentSignature[trackID]?.soundBank != node.soundBankAddress {
            if !isTrivial(routingSignature[trackID]) || !node.sendGainNodes.isEmpty {
                announceRoutingMutation()  // tearing down bus-facing wiring
            }
            node.renderer.publish(nil)
            node.renderer.requestFlush()
            node.mixer.removeTap(onBus: 0)
            retireNode(node.source)
            retireNode(node.mixer)
            for gain in node.sendGainNodes.values {
                retireNode(gain)
            }
            instrumentNodes.removeValue(forKey: trackID)
        }

        // Added instrument tracks; existing ones refresh their clip copy.
        for track in instrumentTracks {
            if let node = instrumentNodes[track.id] {
                node.clips = track.clips
            } else {
                instrumentNodes[track.id] = addInstrumentNode(for: track)
                freshSourceNodes.insert(track.id)
            }
        }

        // 5. Routing wiring: ONE fan-out connect per source track whose node
        // is fresh, whose RoutingKey changed, or whose referenced buses just
        // appeared/disappeared (defensive — ProjectStore clears dangling refs
        // inside the bus-removal edit, but a stale ref must not be rewired
        // into a mixer that step 6 is about to detach). Send LEVELS are
        // excluded by construction: they land in applyParameters.
        let churnedBuses = addedBuses.union(removedBuses)
        for track in tracks where track.kind != .bus {
            guard let key = newRoutingSignature[track.id],
                  let mixer = sourceMixer(forTrack: track.id) else { continue }
            let referencedBuses = key.sends.map(\.busID)
                + (key.outputBusID.map { [$0] } ?? [])
            let needsWiring = freshSourceNodes.contains(track.id)
                || routingSignature[track.id] != key
                || referencedBuses.contains(where: churnedBuses.contains)
            guard needsWiring else { continue }

            // A fresh node wiring trivially (master out, no sends — the
            // pre-M4 track add) is the ONE live-proven case; everything else
            // announces so the live engine has already left the running
            // state before the wiring below mutates.
            if !(isTrivial(routingSignature[track.id]) && isTrivial(key)) {
                announceRoutingMutation()
            }

            // Sever the mixer's ENTIRE old fan-out first — no moment may
            // exist where its connections reference a node being detached
            // (old send gains here, removed bus mixers in the step below).
            engine.disconnectNodeOutput(mixer)
            // Old send gains next; detach severs their gain→bus legs.
            detachSendGainNodes(forTrack: track.id)

            // Destinations resolve against the NEW bus set — a bus leaving
            // this pass, or a genuinely dangling id, falls back to the main
            // mix (output) or is skipped (send). Send gains connect into
            // their buses FIRST: the output destination's
            // nextAvailableInputBus is only accurate after every gain→bus
            // connection has landed (output and a send may target the SAME
            // bus — querying first hands out an input bus the gain connect
            // then steals, and the fan-out connect aborts; measured).
            let format = graphFormat()
            var points: [AVAudioConnectionPoint] = []
            var gains: [UUID: AVAudioMixerNode] = [:]
            for send in key.sends {
                // Feeder fan-outs target the bus's SUM mixer (pre-chain), so
                // send returns pass through the bus's insert chain.
                guard !removedBuses.contains(send.busID),
                      let busSum = busNodes[send.busID]?.sumMixer else { continue }
                let gain = AVAudioMixerNode()
                engine.attach(gain)
                engine.connect(gain, to: busSum, format: format)
                points.append(AVAudioConnectionPoint(
                    node: gain, bus: gain.nextAvailableInputBus))
                gains[send.id] = gain
            }
            let destination = key.outputBusID.flatMap { id in
                removedBuses.contains(id) ? nil : busNodes[id]?.sumMixer
            } ?? engine.mainMixerNode
            points.append(AVAudioConnectionPoint(
                node: destination, bus: destination.nextAvailableInputBus))
            // Every node in the fan-out array is distinct (fresh gain mixers
            // + one output dest), so each point's input bus is settled.
            engine.connect(mixer, to: points, fromBus: 0, format: format)
            setSendGainNodes(gains, forTrack: track.id)
        }

        // 6. Removed bus nodes — last, so every ex-feeder was rewired above
        // and nothing still connects into these mixers. Tap off before detach.
        if !removedBuses.isEmpty {
            announceRoutingMutation()  // covers the unfed-bus removal case
        }
        for busID in removedBuses {
            guard let node = busNodes.removeValue(forKey: busID) else { continue }
            node.mixer.removeTap(onBus: 0)
            retireNode(node.mixer)
            retireNode(node.chainHost)
            retireNode(node.sumMixer)
        }

        let changed = newSignature != signature
            || newInstrumentSignature != instrumentSignature
            || newRoutingSignature != routingSignature
            || newBusSignature != busSignature
        signature = newSignature
        instrumentSignature = newInstrumentSignature
        routingSignature = newRoutingSignature
        busSignature = newBusSignature
        return changed
    }

    /// The mixer feeding a source (audio or instrument) track's routing
    /// fan-out; nil for unknown ids and buses.
    private func sourceMixer(forTrack id: UUID) -> AVAudioMixerNode? {
        trackNodes[id]?.mixer ?? instrumentNodes[id]?.mixer
    }

    private func detachSendGainNodes(forTrack id: UUID) {
        if let node = trackNodes[id] {
            for gain in node.sendGainNodes.values {
                retireNode(gain)
            }
            trackNodes[id]?.sendGainNodes = [:]
        }
        if let node = instrumentNodes[id] {
            for gain in node.sendGainNodes.values {
                retireNode(gain)
            }
            node.sendGainNodes = [:]
        }
    }

    private func setSendGainNodes(_ gains: [UUID: AVAudioMixerNode], forTrack id: UUID) {
        if trackNodes[id] != nil {
            trackNodes[id]?.sendGainNodes = gains
        } else if let node = instrumentNodes[id] {
            node.sendGainNodes = gains
        }
    }

    // MARK: - Test seams (@testable)

    /// The live gain node behind one send — identity assertions in the
    /// structural-vs-in-place tests compare instances across a reconcile.
    func sendGainNode(forTrack trackID: UUID, sendID: UUID) -> AVAudioMixerNode? {
        trackNodes[trackID]?.sendGainNodes[sendID]
            ?? instrumentNodes[trackID]?.sendGainNodes[sendID]
    }

    /// The live mixer node behind one bus track.
    func busMixerNode(forBus busID: UUID) -> AVAudioMixerNode? {
        busNodes[busID]?.mixer
    }

    /// The live mixer node behind one source track — connection-inspection
    /// tests walk its outputConnectionPoints after structural rewires.
    func sourceMixerNode(forTrack trackID: UUID) -> AVAudioMixerNode? {
        sourceMixer(forTrack: trackID)
    }

    /// The permanent chain-host node of one audio/bus strip — identity
    /// assertions prove chain edits never rebuild the sandwich. Nil for
    /// instrument tracks (their chain lives inside the renderer, no node).
    func chainHostNode(forTrack trackID: UUID) -> AVAudioUnitEffect? {
        trackNodes[trackID]?.chainHost ?? busNodes[trackID]?.chainHost
    }

    /// The chain sync state of any strip kind (audio / instrument / bus).
    func effectChainState(forTrack trackID: UUID) -> EffectChainState? {
        trackNodes[trackID]?.chainState
            ?? instrumentNodes[trackID]?.chainState
            ?? busNodes[trackID]?.chainState
    }

    /// Total fixed insert-chain latency for one strip, in samples at the
    /// graph rate (non-bypassed effects only) — the M4 (viii) PDC hook,
    /// surfaced through `AudioEngine.insertChainLatencySamples(forTrack:)`.
    func chainLatencySamples(forTrack trackID: UUID) -> Int {
        effectChainState(forTrack: trackID)?.latencySamples ?? 0
    }

    /// Fixed latency of ONE live effect instance on a strip (0 when the
    /// track or effect is unknown) — surfaced through
    /// `AudioEngine.effectLatencySamples(trackID:effectID:)`.
    func effectLatencySamples(forTrack trackID: UUID, effectID: UUID) -> Int {
        effectChainState(forTrack: trackID)?.latencySamples(forEffect: effectID) ?? 0
    }

    /// All-effects chain latency for one strip (bypassed effects INCLUDED —
    /// `chainLatencyAll`, spec §1): the stable reported total and the stage-
    /// maxima input. 0 for unknown ids.
    func chainLatencyAllSamples(forTrack trackID: UUID) -> Int {
        effectChainState(forTrack: trackID)?.latencySamplesAllEffects ?? 0
    }

    /// The PDC compensation ring of any strip kind (M4 viii-b): audio and
    /// bus strips carry it inside their ChainHostAU; instrument strips inside
    /// their renderer. Nil for unknown ids.
    func compensationState(forStrip stripID: UUID) -> CompensationDelayState? {
        if let node = trackNodes[stripID] {
            return ChainHostAU.compensationState(of: node.chainHost)
        }
        if let node = busNodes[stripID] {
            return ChainHostAU.compensationState(of: node.chainHost)
        }
        return instrumentNodes[stripID]?.renderer.compensation
    }

    /// Publishes one strip's compensation target in samples (M4 viii-b) —
    /// one atomic u32 store, never a snapshot republish, never a structural
    /// mutation; playback keeps rolling. The viii-c recompute wiring calls
    /// this from the `PDCPlan` apply path; tests call it directly.
    func setCompensationTarget(_ samples: Int, forStrip stripID: UUID) {
        compensationState(forStrip: stripID)?.setTarget(samples)
    }

    // MARK: - PDC recompute (M4 viii-c)

    /// TEST SEAM: when non-nil, the automatic plan is suppressed and every
    /// strip's ring target is forced to `override[id] ?? 0` on each parameter
    /// pass — how the viii-b render tests pin hand-computed (including
    /// deliberately WRONG) targets. nil = always-on plan-driven PDC.
    var compensationOverride: [UUID: Int]?

    /// The report behind the last automatic recompute (nil before the first
    /// pass or under `compensationOverride`) — the snapshot-reporting source,
    /// surfaced through `AudioEngine.pdcReport()`.
    private(set) var pdcReport: PDCReport?

    /// Recomputes the PDC plan from the CURRENT strip latencies and pushes
    /// every strip's ring target — one atomic u32 store per strip, never a
    /// structural mutation, playback keeps rolling. Runs at the tail of every
    /// `applyParameters` pass, which is the single funnel for all six events
    /// that can move a number (spec §4): chain descriptor sync and bypass
    /// happen in the SAME pass just above (chainState.sync), hosted-AU
    /// latency capture ends in an applyParameters call, routing/rate/cold-
    /// start paths all re-run it, and OfflineRenderer.render calls it on both
    /// sides of engine start (offline parity by construction).
    ///
    /// The master strip does not exist as a graph strip (master is the main
    /// mixer, chain-free today) so the plan input is exactly the track + bus
    /// strips — the spec's master exclusion holds by construction; a future
    /// master chain feeds `masterChainLatencySamples` in the report only.
    private func recomputeCompensation(tracks: [Track]) {
        if let override = compensationOverride {
            for stripID in trackIDs {
                setCompensationTarget(override[stripID] ?? 0, forStrip: stripID)
            }
            pdcReport = nil
            return
        }

        var strips: [PDCStripInput] = []
        var allByID: [UUID: Int] = [:]
        strips.reserveCapacity(tracks.count)
        for track in tracks {
            // Only strips that exist in the node tree participate: a ring
            // target has nowhere to land on a not-yet-reconciled strip, and
            // its latency is unknowable until its chain state exists. The
            // next parameter pass after reconcile picks it up.
            guard let chainState = effectChainState(forTrack: track.id) else { continue }
            let kind: PDCStripKind = track.kind == .bus
                ? .bus
                : .track(outputsToMaster: track.outputBusID == nil,
                         hasSends: !track.sends.isEmpty)
            let all = chainState.latencySamplesAllEffects
            allByID[track.id] = all
            strips.append(PDCStripInput(
                id: track.id, kind: kind,
                chainLatencyAll: all,
                chainLatencyActive: chainState.latencySamples))
        }

        let plan = PDCPlan.compute(input: PDCInput(strips: strips))
        var report: [UUID: PDCReport.Strip] = [:]
        report.reserveCapacity(plan.strips.count)
        for strip in plan.strips {
            setCompensationTarget(strip.compensationSamples, forStrip: strip.id)
            report[strip.id] = PDCReport.Strip(
                chainLatencySamples: allByID[strip.id] ?? 0,
                compensationSamples: strip.compensationSamples,
                clamped: strip.clamped,
                skewSamples: strip.skewSamples)
        }
        pdcReport = PDCReport(trackStageSamples: plan.trackStage,
                              busStageSamples: plan.busStage,
                              masterChainLatencySamples: 0,
                              strips: report)
    }

    // MARK: - Test seams (@testable)

    /// The strip mixer node carrying one track's fader/pan — the automation
    /// override-rule and stopped-WYSIWYG tests read it.
    func stripMixer(forTrack trackID: UUID) -> AVAudioMixerNode? {
        trackNodes[trackID]?.mixer
            ?? instrumentNodes[trackID]?.mixer
            ?? busNodes[trackID]?.mixer
    }

    /// One strip's automation read head (audio / instrument / bus) — schedule
    /// generation assertions for the no-restart republish tests.
    func automationRenderer(forTrack trackID: UUID) -> AutomationRenderer? {
        automationRenderer(for: trackID)
    }

    // MARK: - Parameters

    /// Applies volume/pan/mute/solo to each audio and instrument track's mixer
    /// node, and poly-synth descriptor parameters to each instrument track's
    /// synth. Parameter writes only — never touches players, schedules, or
    /// the flush flag, so this is safe on every reconcile pass without
    /// triggering a stop-reschedule-resume (parameter fields are deliberately
    /// outside `ClipKey` / `MIDIClipKey` / `InstrumentTrackKey`, and synth
    /// params land atomically without cutting held notes).
    ///
    /// Solo semantics span ALL kinds (M4): any soloed track — bus included —
    /// activates solo. A source (audio/instrument) track stays audible under
    /// active solo iff it is soloed itself OR it feeds a soloed bus (output
    /// routing or any send) — solo-in-place. Bus mixers are NEVER solo-gated
    /// (bus gain = muted ? 0 : volume): a soloed track's send returns keep
    /// sounding, and a soloed bus is exactly "solo everything that feeds it"
    /// (feeders' direct outs included; an unfed soloed bus silences all).
    /// Mute always wins for its own track, and post-fader sends mean a
    /// muted/solo-silenced track is equally silent on its sends.
    ///
    /// Ordering (measured AUMultiChannelMixer behavior): a pan set BEFORE
    /// engine.start() is discarded when start() re-initializes the mixer input
    /// buses, while volume set post-start RAMPS from its old value (a 1→0 mute
    /// ramp leaked ~0.5 peak into a render's first buffers). Volumes therefore
    /// want to be in place before start and pan re-applied after — callers run
    /// this on both sides of every start. Re-setting an unchanged volume does
    /// not ramp. See AudioEngine.prepare() / OfflineRenderer.render().
    /// AUTOMATION OVERRIDE (M4 vii-b): an ACTIVE (enabled, non-empty) volume
    /// lane REPLACES the fader — while rolling the mixer's `outputVolume`
    /// pins to (gated ? 0 : 1) and the render stage supplies the lane gain,
    /// so mute/solo gating stays on the mixer node and no mixer property
    /// moves during playback; an active pan lane pins `mixer.pan` to 0
    /// likewise. While STOPPED the mixer previews `value(atBeat:
    /// playheadBeat)` — stopped WYSIWYG. Disabled/empty lanes leave the mixer
    /// behaving exactly as before. Lane CHANGES observed while rolling
    /// republish that strip's automation schedule in place — never a restart
    /// (automation is in no reconcile signature by construction).
    func applyParameters(tracks: [Track], playheadBeat: Double = 0) {
        let soloActive = tracks.contains(where: \.isSoloed)
        let soloedBusIDs = Set(tracks.filter { $0.kind == .bus && $0.isSoloed }.map(\.id))
        let chainRate = graphFormat().sampleRate
        let rolling = automationRollContext != nil
        var newActiveLanes:
            [UUID: (volume: AutomationLane?, pan: AutomationLane?,
                    effectParams: [AutomationSchedule.EffectParamLaneSpec])] = [:]
        for track in tracks {
            let mixer: AVAudioMixerNode?
            switch track.kind {
            case .audio: mixer = trackNodes[track.id]?.mixer
            case .instrument: mixer = instrumentNodes[track.id]?.mixer
            case .bus: mixer = busNodes[track.id]?.mixer
            }
            guard let mixer else { continue }
            // Insert-chain sync (M4 ii): diffed here — identical placement to
            // instrument-param apply, so it runs on every pass, both sides of
            // every start, and automatically inside OfflineRenderer.render
            // (offline parity for free). Chain edits are atomic publishes
            // into the strip's processor; they NEVER touch graph topology and
            // appear in no reconcile signature.
            effectChainState(forTrack: track.id)?
                .sync(descriptors: track.effects, sampleRate: chainRate)
            let volumeLane = track.automation.activeLane(for: .volume)
            let panLane = track.automation.activeLane(for: .pan)
            // Effect-param lanes resolve to (effectID, paramSlot) HERE, on
            // the main actor, against the SAME effects list the chain sync
            // above just applied (M4 vii-c) — unresolvable lanes (deleted
            // effect, `.audioUnit`, unknown param) drop out and stay inert.
            // While STOPPED the knobs rule (no schedule → no render stores),
            // and a lane disabled/removed while ROLLING reverts the effect
            // to its knob params render-side on the next quantum.
            let effectParams = AutomationSchedule.resolveEffectParamLanes(
                automation: track.automation, effects: track.effects)
            newActiveLanes[track.id] = (volumeLane, panLane, effectParams)
            var pan = Float(track.pan)
            if let panLane {
                // Override rule: rolling → the render stage pans, the mixer
                // sits at center; stopped → WYSIWYG preview of the lane.
                pan = rolling ? 0 : Float(panLane.value(atBeat: playheadBeat) ?? track.pan)
            }
            // Same-value pan writes are swallowed by the property cache even
            // when engine.start() has just reset the underlying AU parameter
            // to 0 (measured) — route through the adjacent float so the write
            // always reaches the AU. Center (0) matches the reset value, so a
            // swallowed write is harmless there.
            if mixer.pan == pan, pan != 0 {
                mixer.pan = pan > 0 ? pan.nextDown : pan.nextUp
            }
            mixer.pan = pan
            let gated: Bool
            if track.kind == .bus {
                // Never solo-gated — a bus's silence under solo falls out of
                // its feeders' gains. Bus mute kills routed audio AND every
                // send into it (this is the bus's own output gain).
                gated = track.isMuted
            } else {
                let feedsSoloedBus = !soloedBusIDs.isEmpty
                    && (track.outputBusID.map(soloedBusIDs.contains) ?? false
                        || track.sends.contains { soloedBusIDs.contains($0.destinationBusID) })
                let audibleUnderSolo = track.isSoloed || feedsSoloedBus
                gated = track.isMuted || (soloActive && !audibleUnderSolo)
            }
            var gain: Double = gated ? 0 : track.volume
            if let volumeLane, !gated {
                // Override rule: rolling → gain pins to 1 (the render stage
                // supplies the lane gain); stopped → WYSIWYG lane preview.
                gain = rolling ? 1 : (volumeLane.value(atBeat: playheadBeat) ?? track.volume)
            }
            mixer.outputVolume = Float(gain)
            // No-restart republish: lanes changed under a rolling transport →
            // rebuild THIS strip's schedule against the same anchor/epoch.
            // Player schedules and reconcile signatures are untouched.
            if rolling, let published = publishedAutomationLanes[track.id],
               published.volume != volumeLane || published.pan != panLane
                   || published.effectParams != effectParams {
                publishAutomation(for: track.id, volume: volumeLane, pan: panLane,
                                  effectParams: effectParams)
            } else if rolling, publishedAutomationLanes[track.id] == nil,
                      volumeLane != nil || panLane != nil || !effectParams.isEmpty {
                publishAutomation(for: track.id, volume: volumeLane, pan: panLane,
                                  effectParams: effectParams)
            }
            // Send levels land in place on the dedicated gain nodes — never
            // structural (level is excluded from RoutingKey by design). Pan
            // on send nodes is never touched: start() resets it to 0, which
            // is exactly the stereo pass-through we want.
            if track.kind != .bus, !track.sends.isEmpty {
                let sendGains = trackNodes[track.id]?.sendGainNodes
                    ?? instrumentNodes[track.id]?.sendGainNodes
                    ?? [:]
                for send in track.sends {
                    sendGains[send.id]?.outputVolume = Float(send.level)
                }
            }
            // Per-clip gain (M5 i-b): dB → linear onto the clip player's
            // volume — the player's AVAudioMixing input gain into the strip
            // sumMixer. A parameter write like fader volume: gainDb is in no
            // reconcile signature, so a gain edit never restarts; and volume
            // sits downstream of the baked fade buffers, so gain applies to
            // the WHOLE clip (fade regions included) and never forces a
            // re-bake. Audio clips only in v0 — MIDI clips have no per-clip
            // player (instrument strips render per track).
            if track.kind == .audio, let node = trackNodes[track.id] {
                for domainClip in track.clips {
                    node.clips[domainClip.id]?.player.volume =
                        Float(pow(10.0, domainClip.gainDb / 20.0))
                }
            }
            // Instrument descriptor parameters land in place: an atomic
            // publish the render thread adopts at its next quantum. Held
            // notes keep sounding; no node rebuild, no flush. No-ops when
            // the params are unchanged (apply dedupes). Sampler ZONES are
            // structural and never travel this path — see InstrumentTrackKey.
            if track.kind == .instrument {
                switch instrumentNodes[track.id]?.instrument {
                case let synth as PolySynthInstrument:
                    synth.apply(params: (track.instrument ?? .default).polySynth)
                case let sampler as SamplerInstrument:
                    sampler.apply(params: (track.instrument ?? .default).resolvedSampler)
                default:
                    break
                }
            }
        }
        activeAutomationLanes = newActiveLanes
        lastParameterTracks = tracks
        // PDC recompute (M4 viii-c) — AFTER every strip's chain sync above,
        // so the plan sees post-edit latencies (including a hosted AU that
        // just swapped in, or a rate re-prepare). Atomic target stores only.
        recomputeCompensation(tracks: tracks)
    }

    /// Live per-clip gain (M5 i-b): ONE player-volume write, no reconcile, no
    /// restart — the mixer input ramps internally, so mid-play gain edits are
    /// zipper-free. Unknown ids (including MIDI clips, which have no per-clip
    /// player in v0) are a documented no-op, never a crash.
    func setClipGain(trackID: UUID, clipID: UUID, linear: Float) {
        trackNodes[trackID]?.clips[clipID]?.player.volume = linear
    }

    // MARK: - Automation publish (M4 vii-b)

    /// One strip's automation read head (audio / instrument / bus).
    private func automationRenderer(for trackID: UUID) -> AutomationRenderer? {
        trackNodes[trackID]?.automation
            ?? instrumentNodes[trackID]?.renderer.automation
            ?? busNodes[trackID]?.automation
    }

    /// Builds and publishes ONE strip's schedule against the current roll
    /// context (no active lanes → unpublish). Bumps ONLY
    /// `automationGeneration`; the render side re-seeks its cursors by binary
    /// search on the generation change. No-op while stopped.
    private func publishAutomation(
        for trackID: UUID, volume: AutomationLane?, pan: AutomationLane?,
        effectParams: [AutomationSchedule.EffectParamLaneSpec]
    ) {
        guard let context = automationRollContext,
              let renderer = automationRenderer(for: trackID) else { return }
        var schedule: AutomationSchedule?
        if volume != nil || pan != nil || !effectParams.isEmpty {
            automationGeneration += 1
            schedule = AutomationSchedule.build(
                volumeLane: volume, panLane: pan, effectParamLanes: effectParams,
                fromBeat: context.fromBeat, tempoMap: context.tempoMap,
                sampleRate: graphFormat().sampleRate,
                generation: automationGeneration, mode: context.mode)
        }
        renderer.publish(schedule)
        publishedAutomationLanes[trackID] = (volume, pan, effectParams)
    }

    /// OFFLINE SEAM: arms the roll context BEFORE the pre-start parameter
    /// pass, so the volume-override pin (mixer gain 1) is in place before
    /// `engine.start()` and never ramps into the bounce head (the measured
    /// post-start outputVolume ramp leak). Live starts don't need this — the
    /// ~60 ms anchor lead-in absorbs the pin before schedule t=0.
    func armOfflineAutomation(fromBeat: Double, tempoMap: TempoMap) {
        automationRollContext = (fromBeat, tempoMap, .offline)
    }

    private func addTrackNode(for trackID: UUID) -> TrackNode {
        let node = makeStripSandwich(for: trackID)
        return TrackNode(sumMixer: node.sumMixer, chainHost: node.chainHost,
                         chainState: node.chainState,
                         automation: node.automation, mixer: node.mixer)
    }

    /// One strip's permanent insert sandwich (audio tracks and buses alike):
    /// `sumMixer → chainHost → mixer`, all at the graph rate. The sum mixer
    /// is SRC/sum only (unity, pan 0, no tap, parameters never touched); the
    /// chain host is the M4 (ii) insert point whose processor the strip's
    /// `EffectChainState` publishes into; `mixer` keeps every pre-existing
    /// role (fader/pan/mute writes, meter tap, fan-out source). The mixer's
    /// OUTPUT wiring remains the caller's job, exactly as with `makeMixer`.
    private func makeStripSandwich(
        for trackID: UUID
    ) -> (sumMixer: AVAudioMixerNode, chainHost: AVAudioUnitEffect,
          chainState: EffectChainState, automation: AutomationRenderer,
          mixer: AVAudioMixerNode) {
        let mixer = makeMixer(for: trackID)
        let sumMixer = AVAudioMixerNode()
        engine.attach(sumMixer)
        let chainHost = ChainHostAU.makeChainHostNode()
        // Telemetry wiring happens HERE, at node creation before the engine
        // ever renders (the setPerformanceContext boundary contract).
        ChainHostAU.setPerformanceContext(performance, of: chainHost)
        engine.attach(chainHost)
        let format = graphFormat()
        engine.connect(sumMixer, to: chainHost, format: format)
        engine.connect(chainHost, to: mixer, format: format)
        let processor: EffectChainProcessor
        if let hosted = ChainHostAU.chainProcessor(of: chainHost) {
            processor = hosted
        } else {
            // Never expected (the node is our in-process subclass by
            // construction — pinned by the spike test). A detached processor
            // keeps the strip playing through with chains inert.
            FileHandle.standardError.write(Data(
                "PlaybackGraph: chain host for \(trackID) is not ChainHostAU — inserts disabled on this strip\n".utf8))
            processor = EffectChainProcessor()
        }
        let chainState = EffectChainState(processor: processor)
        chainState.hostedEffectProvider = { [weak self] id in
            self?.hostedEffectProvider(id)
        }
        // The read head inside the chain host (structural time only, one per
        // strip lifetime). The detached fallback keeps automation inert but
        // safe on the never-expected foreign-AU strip.
        let automation = ChainHostAU.automationRenderer(of: chainHost) ?? AutomationRenderer()
        return (sumMixer, chainHost, chainState, automation, mixer)
    }

    /// Instrument track: instrument (prepared on the main actor, before any
    /// render) + renderer (the MIDI clock) + source node, connected under the
    /// track mixer at the explicit graph-rate format — same rule as clip
    /// players and the metronome.
    private func addInstrumentNode(for track: Track) -> InstrumentNode {
        let mixer = makeMixer(for: track.id)
        let format = graphFormat()
        let graphRate = format.sampleRate
        let instrument = instrumentFactory(track)
        instrument.prepare(sampleRate: graphRate, maxFramesPerQuantum: 8_192, channelCount: 2)
        let renderer = InstrumentRenderer(instrument: instrument, sampleRate: graphRate,
                                          performance: performance)
        let source = renderer.makeSourceNode(format: format)
        engine.attach(source)
        engine.connect(source, to: mixer, format: format)
        let descriptor = track.instrument ?? .default
        let chainState = EffectChainState(processor: renderer.chain)
        chainState.hostedEffectProvider = { [weak self] id in
            self?.hostedEffectProvider(id)
        }
        let node = InstrumentNode(kind: descriptor.kind,
                                  samplerZones: descriptor.kind == .sampler
                                      ? descriptor.resolvedSampler.zones : nil,
                                  audioUnitComponent: descriptor.kind == .audioUnit
                                      ? descriptor.audioUnit?.component : nil,
                                  soundBankAddress: descriptor.kind == .soundBank
                                      ? descriptor.soundBank?.address : nil,
                                  mixer: mixer, source: source,
                                  renderer: renderer, instrument: instrument,
                                  chainState: chainState)
        node.clips = track.clips
        return node
    }

    /// The live renderer for one instrument track — the MIDI-thru fanout
    /// target. Nil for unknown ids, audio/bus tracks, or mid-rebuild gaps
    /// (the fanout republish on the next `tracksDidChange` pass closes them).
    func instrumentRenderer(forTrack id: UUID) -> InstrumentRenderer? {
        instrumentNodes[id]?.renderer
    }

    /// Drops ONE audio clip's signature entry (and its node, if any) so the
    /// next `reconcile` reports a change and re-adds it — the seam
    /// AudioEngine uses when an async stretch render finishes and the silent
    /// pending gap must be replaced with the rendered CAF (the
    /// `invalidateInstrumentNode` / M3 vi-a precedent). Player detach is
    /// live-safe: it is exactly the changed-ClipKey teardown reconcile does.
    func invalidateClipSchedule(clipID: UUID) {
        for (trackID, keys) in signature {
            guard let index = keys.firstIndex(where: { $0.id == clipID }) else { continue }
            signature[trackID]?.remove(at: index)
            if let clipNode = trackNodes[trackID]?.clips[clipID] {
                clipNode.player.stop()
                retireNode(clipNode.player)
                trackNodes[trackID]?.clips.removeValue(forKey: clipID)
            }
        }
    }

    /// Tears down ONE instrument track's node (unpublish + flush, tap off,
    /// detach) and drops its signature entry so the next `reconcile` rebuilds
    /// it — the seam AudioEngine uses when an async AU preparation finishes
    /// and the placeholder node must be replaced with the real instrument.
    func invalidateInstrumentNode(trackID: UUID) {
        instrumentSignature.removeValue(forKey: trackID)
        guard let node = instrumentNodes.removeValue(forKey: trackID) else { return }
        // Same live-safety rule as reconcile: tearing down bus-facing wiring
        // (send gains, a bus output) must not happen against a running
        // engine. The caller's next tracksDidChange restarts it.
        let key = routingSignature[trackID]
        if key?.outputBusID != nil || !node.sendGainNodes.isEmpty {
            willMutateRoutingTopology?()
        }
        node.renderer.publish(nil)
        node.renderer.requestFlush()
        node.mixer.removeTap(onBus: 0)
        retireNode(node.source)
        retireNode(node.mixer)
        for gain in node.sendGainNodes.values {
            retireNode(gain)
        }
    }

    /// The explicit graph-rate stereo format for every mixer-level
    /// connection. `format: nil` would keep a fresh mixer's default 44.1 kHz
    /// output and force a second SRC in the main mixer, breaking sample
    /// accuracy (measured: 32-frame onset error at 48 kHz). The output node
    /// reports the manual-rendering format offline and the hardware format
    /// live; the 48 kHz fallback covers a not-yet-configured output.
    private func graphFormat() -> AVAudioFormat {
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let graphRate = outputRate > 0 ? outputRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: graphRate, channels: 2) else {
            preconditionFailure("standard \(graphRate) Hz stereo format must exist")
        }
        return format
    }

    /// One mixer node (attach + meter tap, NO output connect) — shared by
    /// source tracks and buses. Output wiring is the reconcile routing step's
    /// job: source tracks fan out to their destinations; buses connect
    /// straight to the main mix. Meter taps live on the node, not on a
    /// connection, so later output re-wiring never disturbs them.
    private func makeMixer(for trackID: UUID) -> AVAudioMixerNode {
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        installMeterTap(on: mixer, trackID: trackID)
        return mixer
    }

    /// Per-track meter tap on the track mixer's output. The track UUID is
    /// captured by value — the tap outlives any dictionary lookup we could do.
    private func installMeterTap(on mixer: AVAudioMixerNode, trackID: UUID) {
        // The tap installs BEFORE the mixer's output connection forms.
        // Passing the graph format applies it to the still-unconnected output
        // bus (documented AVAudioNode.installTap behavior), so tap buffers
        // and the later connect share one format — no SRC, no mismatch.
        let format = graphFormat()
        // @Sendable is load-bearing: without it this closure (formed in a
        // @MainActor context) inherits main-actor isolation and the Swift
        // runtime traps when AVFAudio invokes it on its tap queue.
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            // Runs on an audio-adjacent thread (or inside an offline pull):
            // compute scalars here, hop with Sendable values only. No graph
            // state may be touched from this closure. The hop captures self
            // strongly so frames queued during an offline render still deliver
            // after the graph's owner returns.
            guard let self, let channels = buffer.floatChannelData else { return }
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
            Task { @MainActor in
                self.meterSink?(trackID, frame)
            }
        }
    }

    // MARK: - Scheduling

    /// Schedules every clip player-relative: player sample time 0 ≡ transport
    /// position `fromBeat`. All math is in file-rate frames. m12-b: clip
    /// boundaries convert through the tempo-map integral (signed for pre-roll
    /// clips) — bit-identical to the old fixed `secondsPerBeat` for the
    /// Phase-A trivial map. Audio never time-stretches with tempo; the region
    /// window truncates or under-fills the file.
    func scheduleAll(fromBeat startBeats: Double, tempoMap: TempoMap) {
        // Stage the timeline mapping the next startAllPlayers rolls
        // automation with (the pendingEvents convention).
        stagedAutomationStart = (startBeats, tempoMap)
        forEachClip { clip in
            let fileRate = clip.file.processingFormat.sampleRate
            let fileLength = clip.file.length

            // may be < 0 — seconds(from:to:) is signed
            let clipStartSec = tempoMap.seconds(from: startBeats, to: clip.key.startBeat)
            let regionSec = tempoMap.seconds(
                from: clip.key.startBeat,
                to: clip.key.startBeat + clip.key.lengthBeats)
            let offsetSec = max(0, -clipStartSec)

            // M5 i-b: the clip sounds its source starting `startOffsetSeconds`
            // into the file (split/trim advance it) — every FILE read position
            // shifts by this; the envelope timeline (clip-relative frames)
            // does not.
            // M5 ii-d: for a stretched clip `clip.file` IS the rendered CAF
            // (timeline-domain audio), so the offset maps through the ratio:
            // effectiveOffset = startOffsetSeconds × stretchRatio. Identity
            // clips multiply by exactly 1.0 — bit-identical to the pre-ii-d
            // math (the bypass contract). Clip-end truncation at the CAF's
            // end replaces truncation at the source's end structurally.
            let fileOffsetFrames = AVAudioFramePosition(
                (clip.clip.startOffsetSeconds * clip.clip.stretchRatio * fileRate).rounded())

            // Clip-relative frames: where in the clip playback starts, and the
            // clip's full length. Same `.rounded()` convention as ever.
            let segStart = AVAudioFramePosition((offsetSec * fileRate).rounded())
            let clipLengthFrames = AVAudioFramePosition((regionSec * fileRate).rounded())
            let sourceStart = fileOffsetFrames + segStart
            guard sourceStart < fileLength else { return }
            let sourceEnd = min(fileLength, fileOffsetFrames + clipLengthFrames)
            let frameCount = sourceEnd - sourceStart
            guard frameCount > 0 else { return }

            let whenSample = AVAudioFramePosition((max(0, clipStartSec) * fileRate).rounded())
            let when = AVAudioTime(sampleTime: whenSample, atRate: fileRate)

            // Fade windows intersected with the scheduled region — all three
            // boundaries derive from the same integers, so the pieces are
            // exactly contiguous (in + mid + out == frameCount). A playhead
            // inside a fade yields a partial piece whose envelope starts at
            // the analytic value for that clip-relative frame.
            let plan = ClipFadeBake.piecePlan(
                clip: clip.clip, tempoMap: tempoMap, fileRate: fileRate,
                segmentStart: segStart, segmentFrameCount: frameCount)

            // completionHandler stays nil by design — callbacks fire on
            // non-main threads and stopping a player from one can deadlock; we
            // never need end-of-segment signals (no auto-stop; offline length
            // is arithmetic). If ever added: @Sendable + Task { @MainActor … },
            // never call player API inline.
            guard plan.needsBake else {
                // No fades → the pre-i-b single streamed segment, byte for byte.
                clip.player.scheduleSegment(
                    clip.file,
                    startingFrame: sourceStart,
                    frameCount: AVAudioFrameCount(frameCount),
                    at: when,
                    completionHandler: nil
                )
                return
            }

            // Three-piece path: bake BOTH windows first (main-actor file
            // reads through the bake-owned reader), so a read failure can
            // fall back to the plain unfaded segment without desyncing piece
            // times — timing always wins over shape.
            var fadeInBuffer: AVAudioPCMBuffer?
            var fadeOutBuffer: AVAudioPCMBuffer?
            do {
                let reader = try clip.bakeReader()
                if plan.fadeInFrames > 0 {
                    fadeInBuffer = try ClipFadeBake.bakePiece(
                        file: reader,
                        sourceStartFrame: fileOffsetFrames + plan.segmentStart,
                        frameCount: plan.fadeInFrames,
                        clip: clip.clip,
                        clipRelativeStartFrame: plan.segmentStart,
                        tempoMap: tempoMap)
                }
                if plan.fadeOutFrames > 0 {
                    fadeOutBuffer = try ClipFadeBake.bakePiece(
                        file: reader,
                        sourceStartFrame: fileOffsetFrames + plan.fadeOutStart,
                        frameCount: plan.fadeOutFrames,
                        clip: clip.clip,
                        clipRelativeStartFrame: plan.fadeOutStart,
                        tempoMap: tempoMap)
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "PlaybackGraph: fade bake failed for \(clip.file.url.lastPathComponent) — scheduling unfaded: \(error)\n".utf8))
                clip.player.scheduleSegment(
                    clip.file, startingFrame: sourceStart,
                    frameCount: AVAudioFrameCount(frameCount),
                    at: when, completionHandler: nil)
                return
            }

            // Queue the pieces in order on the clip's existing player: the
            // FIRST piece carries the explicit anchor time; the rest schedule
            // `at: nil`, queue-contiguous — no overlapping-time ambiguity on
            // one player. Contiguity guarantees the anchored piece's first
            // frame is exactly `segStart`.
            var anchor: AVAudioTime? = when
            func takeAnchor() -> AVAudioTime? {
                defer { anchor = nil }
                return anchor
            }
            if let fadeInBuffer {
                clip.player.scheduleBuffer(fadeInBuffer, at: takeAnchor(),
                                           options: [], completionHandler: nil)
            }
            if plan.middleFrames > 0 {
                clip.player.scheduleSegment(
                    clip.file,
                    startingFrame: fileOffsetFrames + plan.fadeInEnd,
                    frameCount: AVAudioFrameCount(plan.middleFrames),
                    at: takeAnchor(),
                    completionHandler: nil)
            }
            if let fadeOutBuffer {
                clip.player.scheduleBuffer(fadeOutBuffer, at: takeAnchor(),
                                           options: [], completionHandler: nil)
            }
        }

        // Instrument tracks: stage the merged, sorted event build for each
        // track's schedule (published by startAllPlayers). Pure math on the
        // main actor — microseconds, never render-thread work. Fixed MAP
        // per schedule (m12-b); setTempo (and any future map edit) restarts
        // → rebuilds.
        for node in instrumentNodes.values {
            node.pendingEvents = MIDIEventSchedule.buildEvents(
                clips: node.clips, fromBeat: startBeats, tempoMap: tempoMap,
                sampleRate: node.renderer.sampleRate
            )
        }
    }

    // MARK: - Player control

    /// Preloads render resources so `play(at:)` can honor a near-future anchor.
    func prepareAllPlayers(withFrameCount frameCount: AVAudioFrameCount) {
        forEachClip { $0.player.prepare(withFrameCount: frameCount) }
    }

    /// Starts every player against one shared anchor (lockstep). Pass nil for
    /// manual rendering: player time 0 ≡ the first rendered sample.
    ///
    /// Instrument tracks: publishes each staged event build as an immutable
    /// schedule against the SAME anchor — live, event t=0 sounds at the
    /// anchor host time (count-in delays inherit for free); nil anchor →
    /// offline mode, where the render side latches the first pulled
    /// `mSampleTime` as its epoch (schedule t=0 ≡ rendered sample 0, the
    /// nil-anchor player convention).
    func startAllPlayers(at anchor: AVAudioTime?) {
        // PDC rings reset at every transport (re)start — including engine
        // cold start and offline-render start, where `stopAllPlayers` never
        // ran (the offline renderer calls this with a nil anchor as its
        // render-session start). Zero rings + snap to target, no crossfade:
        // a start is already a discontinuity, and a bounce must never carry
        // live tails (offline parity, spec §5).
        armCompensationResets()
        forEachClip { $0.player.play(at: anchor) }
        let mode: MIDIEventSchedule.Mode =
            anchor.map { .live(anchorHostTime: $0.hostTime) } ?? .offline
        for node in instrumentNodes.values {
            scheduleGeneration += 1
            node.renderer.publish(MIDIEventSchedule(
                generation: scheduleGeneration,
                mode: mode,
                sampleRate: node.renderer.sampleRate,
                events: node.pendingEvents
            ))
        }
        // Automation rolls against the SAME anchor (live) / first-pull epoch
        // (offline) as the MIDI schedules — one seam, offline parity free.
        automationRollContext = (
            stagedAutomationStart.fromBeat, stagedAutomationStart.tempoMap,
            anchor.map { .live(anchorHostTime: $0.hostTime) } ?? .offline
        )
        for trackID in trackIDs {
            let lanes = activeAutomationLanes[trackID]
            publishAutomation(for: trackID, volume: lanes?.volume, pan: lanes?.pan,
                              effectParams: lanes?.effectParams ?? [])
        }
        // Re-run the parameter pass so the override pins (gain 1 / pan 0)
        // land now that the context is rolling. Live, the anchor lead-in
        // absorbs the mixer's internal ramp before schedule t=0; offline,
        // `armOfflineAutomation` already pinned pre-start so these writes
        // are same-value no-ops.
        if !lastParameterTracks.isEmpty {
            applyParameters(tracks: lastParameterTracks,
                            playheadBeat: stagedAutomationStart.fromBeat)
        }
    }

    /// Stops every player, clearing their queues and resetting player time
    /// to 0 — the single reschedule primitive relies on this.
    ///
    /// Instrument tracks: unpublish + flush is THE all-notes-off contract.
    /// Every stop, seek, tempo change, loop wrap, tracksDidChange restart,
    /// and configuration-change recovery already routes through here, so the
    /// next render quantum resets every instrument (release tails cut —
    /// v0-honest, same as players).
    func stopAllPlayers() {
        forEachClip { $0.player.stop() }
        for node in instrumentNodes.values {
            node.renderer.publish(nil)
            node.renderer.requestFlush()
        }
        // Automation unpublishes alongside the MIDI flush: the mixer node
        // resumes full fader/pan authority (the stopped-WYSIWYG values land
        // on the caller's next parameter pass).
        automationRollContext = nil
        publishedAutomationLanes.removeAll()
        for trackID in trackIDs {
            automationRenderer(for: trackID)?.publish(nil)
        }
        // Every strip's chain resets on stop: offline determinism, and the
        // tail cut matches the v0-honest instrument flush contract.
        for node in trackNodes.values { node.chainState.requestResetAll() }
        for node in instrumentNodes.values { node.chainState.requestResetAll() }
        for node in busNodes.values { node.chainState.requestResetAll() }
        // PDC rings reset alongside the chains (M4 viii-b): stop, seek, and
        // tempo changes all route through here, so no stale delayed tail from
        // the previous position ever ghosts into the next one. NOTE on loop
        // wrap: the spec keeps rings across a seamless wrap, but this v0
        // transport implements the wrap AS the restart primitive (players
        // stop, chains reset, ~60 ms reschedule gap) — flushing the rings
        // there matches the chains' existing tail-cut behavior; the no-flush
        // rule becomes meaningful only when a seamless wrap lands.
        armCompensationResets()
    }

    /// Arms every strip's compensation-ring reset (track, instrument, bus) —
    /// consumed at the top of each ring's next render quantum.
    private func armCompensationResets() {
        for node in trackNodes.values {
            ChainHostAU.compensationState(of: node.chainHost)?.armReset()
        }
        for node in busNodes.values {
            ChainHostAU.compensationState(of: node.chainHost)?.armReset()
        }
        for node in instrumentNodes.values {
            node.renderer.compensation.armReset()
        }
    }

    /// Dead code (zero callers — perf-a WATCH item stands): unlike
    /// `reconcile` it tears down bus-facing wiring WITHOUT announcing
    /// `willMutateRoutingTopology`. Any future caller must add the announce
    /// discipline first. Detaches route through `retireNode` (M9 crash-a) so
    /// even this path cannot detach once-rendered nodes against a stopped
    /// engine.
    func detachAll() {
        for node in trackNodes.values {
            for clip in node.clips.values {
                clip.player.stop()
                retireNode(clip.player)
            }
            node.mixer.removeTap(onBus: 0)
            retireNode(node.mixer)
            retireNode(node.chainHost)
            retireNode(node.sumMixer)
            for gain in node.sendGainNodes.values {
                retireNode(gain)
            }
        }
        trackNodes.removeAll()
        signature.removeAll()
        for node in instrumentNodes.values {
            node.renderer.publish(nil)
            node.renderer.requestFlush()
            node.mixer.removeTap(onBus: 0)
            retireNode(node.source)
            retireNode(node.mixer)
            for gain in node.sendGainNodes.values {
                retireNode(gain)
            }
        }
        instrumentNodes.removeAll()
        instrumentSignature.removeAll()
        routingSignature.removeAll()
        for node in busNodes.values {
            node.mixer.removeTap(onBus: 0)
            retireNode(node.mixer)
            retireNode(node.chainHost)
            retireNode(node.sumMixer)
        }
        busNodes.removeAll()
        busSignature.removeAll()
    }

    private func forEachClip(_ body: (ClipNode) -> Void) {
        for node in trackNodes.values {
            for clip in node.clips.values {
                body(clip)
            }
        }
    }
}
