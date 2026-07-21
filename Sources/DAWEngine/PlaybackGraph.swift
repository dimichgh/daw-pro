import AVFAudio
import DAWCore
import Foundation

/// Owns the multitrack playback node tree under an `AVAudioEngine`:
///
///     clip AVAudioPlayerNode (file format) ─┐
///     clip AVAudioPlayerNode (file format) ─┼─► track AVAudioMixerNode ─► mainMixerNode ─► master chain host ─► output
///                                            (SRC / channel-map to graph rate)             (m13-d §1-B, post-fader)
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
        /// Breakpoint gain envelope (m13-e): part of the SCHEDULE identity — the
        /// envelope bakes into the scheduled buffers (ClipFadeBake), so a change
        /// must remove+re-add the clip node (re-bake), exactly like a fade edit.
        /// A plain `gainDb` edit stays out of the key (it rides `player.volume`);
        /// a time-varying envelope cannot, so it lives here.
        let gainEnvelope: [ClipGainPoint]
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

        // MARK: R1 enqueue ledger (m19-f)

        /// True iff this player has received ≥ 1 `scheduleSegment`/
        /// `scheduleBuffer` since its last stop (equivalently, since node
        /// creation) — the EXACT "schedule-empty" predicate of m19-f R1
        /// (design §2.1): the enqueue ledger itself, never a model-level
        /// re-derivation of the six schedule guards. `startAllPlayers`,
        /// `prepareAllPlayers`, and `stopAllPlayers` skip flag-false nodes:
        /// a started-empty player renders silence, can never receive
        /// soundable content mid-roll (clipPlans exclusion + the
        /// drained-queue freeze, see `topUpLoopCycles`), and pays a ~6 ms
        /// `play(at:)` handshake + ~1 ms `stop()` for nothing. Every path
        /// that later gives the player a schedule routes through a full
        /// re-anchored restart, where the flag is set fresh by the new
        /// enqueues. NOTE: no in-tree consumer reads clip-player
        /// `isPlaying` (grep-verified, design §5) — a skipped player is
        /// externally indistinguishable from a started-empty one.
        private(set) var hasPendingSchedule = false

        /// FUNNEL-ONLY CONVENTION (m19-f R1): these two methods are the ONLY
        /// legal enqueue surface for clip players. A direct
        /// `player.scheduleSegment`/`player.scheduleBuffer` call bypasses
        /// the ledger and births a silently never-started active player —
        /// the grep-zero gate (design §2.4-2) pins zero such calls outside
        /// this class (the metronome owns its own player, out of scope).
        func enqueueSegment(startingFrame: AVAudioFramePosition,
                            frameCount: AVAudioFrameCount, at when: AVAudioTime?) {
            hasPendingSchedule = true
            player.scheduleSegment(file, startingFrame: startingFrame,
                                   frameCount: frameCount, at: when,
                                   completionHandler: nil)
        }

        /// Buffer flavor of the funnel — see `enqueueSegment`.
        func enqueueBuffer(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime?) {
            hasPendingSchedule = true
            player.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
        }

        /// Clears the ledger — call ONLY alongside a queue-clearing
        /// `player.stop()` (the reschedule primitive's contract).
        func noteStopped() { hasPendingSchedule = false }
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
    /// Sidechain key edges (m12-f) are structural too: `sidechainDestinations`
    /// lists every strip whose ChainHostAU input bus 1 this track's mixer
    /// feeds (dest model order) — a key set/clear changes the key and rides
    /// the same quiesce-stop-rewire-resume discipline as a send edit.
    struct RoutingKey: Equatable {
        struct SendKey: Equatable {
            let id: UUID
            let busID: UUID
        }
        /// nil = master.
        let outputBusID: UUID?
        let sends: [SendKey]
        /// Strips this track keys (design-m11f-sidechain §4-A), [] for none.
        var sidechainDestinations: [UUID] = []
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
    /// m20-c (m19-k Phase 1): the graph's processing rate, injected at
    /// construction. Production owners ALWAYS pass one — `AudioEngine`
    /// injects the device rate read at build time, `OfflineRenderer` its own
    /// render rate — so the rate is a build-time fact of the graph, never a
    /// live query: a mid-life device-rate flip can no longer half-update
    /// chain rates through `applyParameters` (the graph stays coherent until
    /// the next full rebuild). nil (headless test graphs only) keeps the
    /// legacy call-time output-node query in `graphFormat()`.
    private let graphRate: Double?
    private var trackNodes: [UUID: TrackNode] = [:]
    private var instrumentNodes: [UUID: InstrumentNode] = [:]
    private var busNodes: [UUID: BusNode] = [:]

    // MARK: Master chain insert (m13-d, design §1-B — the C0 fallback)

    /// The master insert point, ALWAYS installed once per graph lifetime
    /// (live, post-rebuild, and offline):
    ///
    ///     strip mixers ─► mainMixerNode ─► masterChainHost ─► outputNode
    ///                     (sum + master     (ChainHostAU,
    ///                      fader, as ever)   post-fader)
    ///
    /// C0 VERDICT (measured 2026-07-12, MasterSandwichTransparencyTests):
    /// design D1 (pre-fader sandwich, `masterSumMixer → chainHost →
    /// mainMixerNode`) FAILED bit-transparency — `AVAudioMixerNode` applies
    /// its output volume PER INPUT during accumulation, so today's shape is
    /// `a·v + b·v + c·v` while D1's is `(a+b+c)·v`: a 1-ulp float drift
    /// (first diff frame 241, 0x3f172767 vs 0x3f172768) under any non-unity
    /// master fader. The design's explicit fallback §1-B is therefore the
    /// production shape: the chain inserts POST-fader between the untouched
    /// main mixer and the output node — the strip sum and fader math are
    /// byte-identical to pre-m13-d by construction, and the empty chain is
    /// the proven pull-through.
    ///
    /// Consequences (each documented in design §1-B / ARCHITECTURE.md):
    /// - Chain edits stay atomic snapshot publishes into `masterChainState`
    ///   — never topology, never an announce, never a rebuild (the live-add
    ///   gate holds BY CONSTRUCTION, same as D1).
    /// - The master chain is POST-fader (deviates from the strip
    ///   inserts-then-fader convention — the accepted §1-B trade).
    /// - HONEST TAP RELOCATION: the master meter tap + analyzer move from
    ///   `mainMixerNode` (now PRE-chain) to this host's output — see
    ///   `AudioEngine.installMeterTap`; "what you hear is what is analyzed"
    ///   is preserved verbatim.
    /// - Metronome and test tone keep their `mainMixerNode` connections and
    ///   therefore pass THROUGH the master chain (unavoidable under §1-B —
    ///   `outputNode` has a single input bus; documented, revisit only if a
    ///   user complains about a limited click).
    /// - The host's key bus 1 is never armed — `setKeyConnected` is only
    ///   ever called for strip hosts, and the store rejects master
    ///   sidechain outright.
    private(set) var masterChainHost: AVAudioUnitEffect?
    private(set) var masterChainState: EffectChainState?

    /// The project's master insert chain descriptors — pushed by
    /// `AudioEngine.masterEffectsChanged` (live) / `OfflineRenderer.render`
    /// (offline) and synced into `masterChainState` on every
    /// `applyParameters` pass (R6: before the PDC recompute).
    var masterEffects: [EffectDescriptor] = []

    // MARK: Master volume automation (m15-c)

    /// The project's MASTER automation lanes (volume-only in v1, store-
    /// enforced) — pushed by `AudioEngine.masterAutomationChanged` (live) /
    /// `OfflineRenderer.render` (offline), the `masterEffects` twin. An
    /// ACTIVE volume lane REPLACES the master fader under the vii-b override
    /// rule: while rolling `mainMixerNode.outputVolume` pins to 1 and the
    /// master chain host's PRE-walk gain stage supplies the lane value (the
    /// §1-B fader position — mainMixer output ≡ chain-host input); while
    /// stopped the mixer previews `value(atBeat:)` (stopped WYSIWYG).
    var masterAutomation: [AutomationLane] = []

    /// The manual master fader (`mixer.setMasterVolume`), cached so the
    /// override rule can hand the node back when a lane deactivates. Pushed
    /// by AudioEngine (`setManualMasterVolume`, `wireGraphHooks`) and
    /// `OfflineRenderer.render`; the default 1 matches both the store's and
    /// AudioEngine's fresh-session default.
    var manualMasterVolume: Double = 1

    /// True while the master fader is under lane authority (pin or preview),
    /// so `applyMasterVolume` can distinguish "hand back the manual value
    /// once" from "never touch the node" — the NULL PATH (no master lane,
    /// ever) leaves `mainMixerNode.outputVolume` entirely to its pre-m15-c
    /// owners, byte-identical by construction.
    private var masterFaderUnderLaneAuthority = false

    /// The lane behind the currently PUBLISHED master schedule (main-actor
    /// bookkeeping, the `publishedAutomationLanes` twin). Outer `nil` =
    /// nothing published this roll; `.some(nil)` = explicitly unpublished
    /// after a mid-roll lane deactivation.
    private var publishedMasterVolumeLane: AutomationLane??

    /// C0 SPIKE SEAM ONLY (`MasterSandwichTransparencyTests`): `false`
    /// reproduces the pre-m13-d topology (mainMixerNode wired implicitly to
    /// the output, no chain host) so the KEPT bit-transparency gate can
    /// render "today's shape" against the master insert forever. Production
    /// code never touches it — the insert is unconditional (R1).
    var masterSandwichEnabled = true

    // MARK: Reference monitor lane (m22-g P2, design D3/§5.1)

    /// Live-only A/B monitor lane flag, **DEFAULT FALSE** — only the live
    /// `AudioEngine` sets it true (in `wireGraphHooks`, before the first
    /// `ensureMasterSandwich`). `OfflineRenderer` builds its own graphs and
    /// never touches it, so NO reference node ever exists in an offline
    /// render: the m12-b anchor SHAs, byte-identical bounce, and
    /// `Σ stems ≡ mixdown` hold BY CONSTRUCTION, not by filtering
    /// (default-off is the fail-safe direction).
    ///
    /// With the flag TRUE the sandwich grows a post-chain monitor pair:
    ///
    ///     masterChainHost ─► mixMonitorGate ─┐
    ///                        (outputVolume    ├─► monitorSum ─► outputNode
    ///                         1=mix, 0=ref)   │   (unity sum)
    ///     referencePlayer ─► referenceGain ───┘
    ///                        (level-match gain)
    ///
    /// The lane is PERMANENT for the life of a live graph — import/remove/
    /// toggle never mutate topology (nothing here is announce-capable, no
    /// rebuild, legal mid-play and mid-record; the m13-d creation-site pins
    /// extend verbatim). It is NOT a strip: no chain host, no sends, no
    /// solo/automation, no stem identity — monitor furniture in the
    /// metronome-click category, entering DOWNSTREAM of the master chain
    /// because the reference must bypass it (design §5.2). All mutable
    /// state is param-class `outputVolume` writes + control-plane player
    /// schedules — zero new render-thread code.
    var referenceLaneEnabled = false
    /// Post-chain mix gate: outputVolume 1 = hear the mix, 0 = hear the
    /// reference (design D4). nil until the lane builds.
    private(set) var mixMonitorGate: AVAudioMixerNode?
    /// The one summing node in front of `outputNode` (its single input bus
    /// is why a sum exists at all — the `:327` constraint).
    private(set) var monitorSum: AVAudioMixerNode?
    /// The reference file player — scheduled ONLY while monitoring is ON
    /// (the m19-f schedule-gated ledger keeps it cost-free otherwise).
    private(set) var referencePlayer: AVAudioPlayerNode?
    /// Level-match gain stage (linear `outputVolume` = the store-computed
    /// `ReferenceLevelMatch` gain).
    private(set) var referenceGain: AVAudioMixerNode?
    /// m19-f-style enqueue ledger for the reference player: false ⇒ zero
    /// schedules since the last stop ⇒ start/stop are skipped entirely (no
    /// ~6 ms handshakes for a lane nobody is auditioning). Kept TRUE after
    /// a raised `play(at:)` so the next stop still clears the queue (the
    /// clip-player asymmetry, design §2.3).
    private(set) var referenceScheduled = false

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

    /// Engine-notices sink (m15-e, audit F6): one `EngineNoticeEvent` per
    /// schedule-time degradation — the bake-failure fallbacks ("timing wins":
    /// the clip still sounds, on time, unshaped) and the stretch-pending
    /// silence transition. Every post happens inside this @MainActor class's
    /// schedule/reconcile code — control plane only, the render thread gains
    /// nothing. AudioEngine forwards into the store's ring; OFFLINE graphs
    /// (OfflineRenderer, bare test graphs) leave it nil by design — a bounce
    /// surfaces problems through its own error/result path, not as session
    /// diagnostics. Each posting site keeps its stderr line.
    var noticeSink: ((EngineNoticeEvent) -> Void)?

    /// Clip ids whose stretch-pending silence has already been NOTICED
    /// (m15-e): reconcile re-resolves pending clips on every pass, so the
    /// notice posts once per clip per pending EPISODE — a `.ready` resolution
    /// re-arms the gate (a later re-edit back into pending posts again).
    /// Session-bounded; a graph rebuild starts empty and honestly re-posts
    /// clips that are still silent.
    private var stretchPendingNoticed: Set<UUID> = []

    /// Clip ids whose media OPEN failed at graph-build time and have already
    /// posted their `clip-file-missing` notice (m16-c, audit F2): the skipped
    /// clip stays in the signature, so EVERY reconcile pass retries the open
    /// and would otherwise re-post on every edit — one post per clip per
    /// missing EPISODE, the `stretchPendingNoticed` discipline. A successful
    /// open re-arms the gate (a file that heals and later goes missing again
    /// posts again). Session-bounded; a graph rebuild starts empty and
    /// honestly re-posts clips that still cannot open.
    private var fileOpenFailedNoticed: Set<UUID> = []

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
    /// render thread). m13-a: the live engine's hook WINDS ACTIVE PLAYBACK
    /// DOWN (capturing resume state) but no longer stops the engine —
    /// announce-class passes on a once-rendered engine abort into
    /// `needsEngineRebuild`, and `AudioEngine.rebuildEngine` discards the
    /// whole engine and cold-builds a fresh one from the model (the
    /// stop→start-boundary detach poison cannot exist by construction —
    /// docs/research/design-m13a-teardown-crash.md). TRIVIAL wiring (a
    /// fresh node connecting straight to master with no sends — the pre-M4
    /// track add, live-proven) never fires it, so plain track adds keep
    /// recording/capture running. Nil (offline render, tests) = no-op.
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

    init(engine: AVAudioEngine, graphRate: Double? = nil) {
        self.engine = engine
        self.graphRate = graphRate
    }

    // MARK: - Teardown discipline (M9 crash-a → m13-a engine-discard)

    /// True once the LIVE engine has completed a `start()` — set by
    /// AudioEngine. Offline renderers and headless test graphs never set it,
    /// so their stopped-state detaches (the proven-safe cold build order)
    /// stay immediate.
    var engineHasRun = false

    /// m13-a: set when this graph's engine must be DISCARDED and rebuilt
    /// from the model instead of surgically mutated — an announce-class pass
    /// on a once-rendered engine, or any teardown that arrived while a
    /// once-rendered engine sat stopped. Once set, `reconcile` refuses to
    /// mutate this graph any further (the object is about to be dropped);
    /// AudioEngine consumes the flag in `tracksDidChange` via
    /// `rebuildEngine(reason:)`. The flag never resets on this instance —
    /// its only exit is the graph's replacement. Internal-settable:
    /// AudioEngine's `projectWillReplace()` forces it at project boundaries
    /// (design A1, unconditional), and tests pin the refusal behavior.
    var needsEngineRebuild = false

    /// The ONLY sanctioned teardown detach (m13-a, supersedes the M9 retire
    /// bin — docs/research/design-m13a-teardown-crash.md). A RUNNING engine
    /// detaches now: the continuously-running dynamic-reconfig path,
    /// live-proven at 28-strip scale (M9 experiments B/E) and re-confirmed
    /// by C0 (2026-07-12: every recorded crash required a stop→start
    /// boundary; no boundary-free live detach ever faulted). A never-run
    /// engine detaches now too (the offline/test cold build order,
    /// byte-identical to always). A once-rendered engine that is STOPPED
    /// must never detach surgically — nodes that rendered and then sat
    /// attached across a stop→start boundary are already stale in
    /// AVFoundation's internal node vector, and the next detach walks the
    /// stale entry (KERN_INVALID_ADDRESS — the falsified M9 flush). The
    /// node is left ATTACHED (the engine's own attachedNodes set keeps it
    /// alive, so no freed-memory window can exist) and the graph flags
    /// itself for a whole-engine rebuild instead; the discard sweeps every
    /// parked node away with the engine.
    private func teardownDetach(_ node: AVAudioNode) {
        if engine.isRunning || !engineHasRun {
            engine.detach(node)
        } else {
            needsEngineRebuild = true
        }
    }

    // MARK: - Reconcile

    /// Diffs the domain track list against the current node tree, attaching and
    /// detaching nodes as needed. Returns true when the schedule-affecting
    /// signature changed (caller decides whether to stop-reschedule-resume).
    ///
    /// m13-a: an announce-class pass against a once-rendered engine does NOT
    /// run — the graph marks itself `needsEngineRebuild` and returns at the
    /// announce site, before the first routing-topology mutation; the caller
    /// (`AudioEngine.tracksDidChange`) then discards the whole engine and
    /// cold-builds a fresh one from the model.
    @discardableResult
    func reconcile(tracks: [Track]) -> Bool {
        // A graph marked for rebuild is about to be discarded — no further
        // mutation may touch its (once-rendered) engine. Report "changed"
        // so no caller can mistake the refusal for a clean no-op.
        guard !needsEngineRebuild else { return true }
        // Master chain insert FIRST (m13-d R1): in place before the first
        // render. Idempotent, attach-only — never an announce, never a
        // rebuild.
        ensureMasterSandwich()
        // Once-per-pass announcement to `willMutateRoutingTopology`, made
        // immediately before the FIRST routing-topology mutation. m13-a: for
        // a once-rendered engine the announce marks the graph for rebuild —
        // every call site checks `needsEngineRebuild` right after and
        // ABORTS the pass (still before the first topology mutation, so the
        // announce contract holds); the hook itself only winds active
        // playback down (capturing resume state) — it no longer stops the
        // engine, because the rebuild discards it. Never-run engines
        // (offline renders, headless tests, pre-start builds) proceed
        // through the pass exactly as before. (Declared up here since m16-h:
        // the earliest announce site is now strip birth in step 0a below.)
        var announcedRoutingMutation = false
        func announceRoutingMutation() {
            guard !announcedRoutingMutation else { return }
            announcedRoutingMutation = true
            willMutateRoutingTopology?()
            if engineHasRun {
                needsEngineRebuild = true
            }
        }

        // 0. Bus + routing signatures up front — the step ORDER below is
        // load-bearing: bus nodes are added before any source track wires
        // into them, and removed only after every ex-feeder is rewired.
        let newBusSignature = tracks.filter { $0.kind == .bus }.map(\.id)

        // Sidechain key edges (m12-f): derived from the SAME model field the
        // chain walk arms (`Effect.sidechainSourceTrackID`, single source of
        // truth). One key per destination strip (v1; the FIRST keyed effect
        // wins defensively — the store enforces one), destinations limited
        // to strips that own a ChainHostAU (audio/bus), sources to non-bus
        // tracks present in this pass (dangling refs form no edge and the
        // destination degrades to self-keyed — never a broken graph).
        let keySourceTrackIDs = Set(
            tracks.filter { $0.kind != .bus }.map(\.id))
        var keyDestinationsBySource: [UUID: [UUID]] = [:]
        for track in tracks where track.kind == .audio || track.kind == .bus {
            guard let source = track.effects.lazy.compactMap({ effect -> UUID? in
                guard let s = effect.sidechainSourceTrackID,
                      keySourceTrackIDs.contains(s), s != track.id else { return nil }
                return s
            }).first else { continue }
            keyDestinationsBySource[source, default: []].append(track.id)
        }

        var newRoutingSignature: [UUID: RoutingKey] = [:]
        for track in tracks where track.kind != .bus {
            newRoutingSignature[track.id] = RoutingKey(
                outputBusID: track.outputBusID,
                sends: track.sends.map {
                    RoutingKey.SendKey(id: $0.id, busID: $0.destinationBusID)
                },
                sidechainDestinations: keyDestinationsBySource[track.id] ?? [])
        }

        // Strips participating in a PHYSICALLY WIRED key edge per the OLD
        // signature — a removed destination's chainHost detach severs a
        // source's fan-out leg, so its teardown must announce (quiesce)
        // exactly like bus-facing wiring.
        var oldKeyInvolvedStrips: Set<UUID> = []
        for (source, key) in routingSignature where !key.sidechainDestinations.isEmpty {
            oldKeyInvolvedStrips.insert(source)
            oldKeyInvolvedStrips.formUnion(key.sidechainDestinations)
        }

        // 0a. Added bus nodes: the same sandwich as audio tracks (sumMixer →
        // chainHost → busMixer), connected under the main mix at the graph
        // rate, meter tap on the bus mixer only.
        var addedBuses: Set<UUID> = []
        for busID in newBusSignature where busNodes[busID] == nil {
            // m16-h Leg 2: a strip sandwich born on a RUNNING once-rendered
            // engine hosts permanently unstartable players — AVFAudio's
            // running-engine reconfig does not propagate player-start
            // eligibility across a ≥2-deep post-start subtree, while the
            // public connection points report healthy edges (named from a
            // pure-AVFoundation standalone matrix,
            // docs/research/design-m16h-reconfig.md §3). Announce and abort
            // BEFORE any node of the new sandwich attaches; the whole-engine
            // rebuild then cold-builds this strip start-era. Never-run
            // engines (offline renders, headless tests, `rebuildEngine`'s
            // own cold build) attach directly — the proven cold order.
            if engineHasRun && engine.isRunning {
                announceRoutingMutation()
                if needsEngineRebuild { return true }  // m13-a: engine rebuilds instead
            }
            let node = makeStripSandwich(for: busID)
            // m13-d §1-B: strips keep feeding mainMixerNode — the master
            // chain sits POST-fader, downstream of the main mixer.
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

        // A stored key is "trivial" when the node's wiring is the pre-M4,
        // live-proven shape: one connection straight to master, no sends —
        // and (m12-f) no sidechain key edges.
        func isTrivial(_ key: RoutingKey?) -> Bool {
            guard let key else { return true }
            return key.outputBusID == nil && key.sends.isEmpty
                && key.sidechainDestinations.isEmpty
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
                        formantPreserve: $0.formantPreserve,
                        gainEnvelope: $0.gainEnvelope)
            }
        }

        // 1. Removed tracks: stop clip players, remove the meter tap, detach
        // players + mixer + send gain nodes. removeTap is explicit — detaching
        // a node with a live tap leaves the tap block retained against a dead
        // node. Send gains carry no taps.
        for (trackID, node) in trackNodes where newSignature[trackID] == nil {
            if !isTrivial(routingSignature[trackID]) || !node.sendGainNodes.isEmpty
                || oldKeyInvolvedStrips.contains(trackID) {
                announceRoutingMutation()  // tearing down bus/key-facing wiring
                if needsEngineRebuild { return true }  // m13-a: engine rebuilds instead
            }
            for clip in node.clips.values {
                clip.player.stop()
                teardownDetach(clip.player)
            }
            node.mixer.removeTap(onBus: 0)
            teardownDetach(node.mixer)
            teardownDetach(node.chainHost)
            teardownDetach(node.sumMixer)
            for gain in node.sendGainNodes.values {
                teardownDetach(gain)
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
                // m16-h Leg 2: same announce-before-attach as bus birth in
                // step 0a — see the comment there. Clip players joining an
                // EXISTING (start-era) strip below stay zero-cost: a depth-1
                // attach onto a start-era subtree is proven clean (design
                // §2-E9/standalone cell G) and never announces.
                if engineHasRun && engine.isRunning {
                    announceRoutingMutation()
                    if needsEngineRebuild { return true }  // m13-a: engine rebuilds instead
                }
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
                teardownDetach(clipNode.player)
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
                    case .ready(let rendered):
                        stretchPendingNoticed.remove(key.id)
                        fileURL = rendered
                    case .pending, nil:
                        // m15-e (audit F6): the clip is being scheduled as
                        // SILENCE — surface it once per pending episode.
                        if stretchPendingNoticed.insert(key.id).inserted {
                            noticeSink?(EngineNoticeEvent(
                                code: "clip-stretch-pending",
                                message: "'\(domainClip.name)' is still being time-stretched — it plays as silence until the stretch is ready.",
                                beat: key.startBeat))
                        }
                        continue
                    }
                }
                do {
                    let file = try AVAudioFile(forReading: fileURL)
                    let clipNode = ClipNode(file: file, key: key, clip: domainClip)
                    engine.attach(clipNode.player)
                    engine.connect(clipNode.player, to: node.sumMixer, format: file.processingFormat)
                    node.clips[key.id] = clipNode
                    // A clip that opens again healed — re-arm its notice.
                    fileOpenFailedNoticed.remove(key.id)
                } catch {
                    // Skip this clip, keep playing the rest. m16-c (audit F2):
                    // a skipped clip gets NO player node, so the m16-a play
                    // guard (`startAllPlayers` walks existing ClipNodes only)
                    // can never see it — this catch is the ONLY site that
                    // knows, so it posts the honest notice itself.
                    //
                    // CODE DECISION (m16-c): a NEW code `clip-file-missing`
                    // rather than reusing m16-a's `clip-unplayable`. The cause
                    // is KNOWN here (the media file cannot be opened — the
                    // agent's remedy is restore/re-link media), while
                    // `clip-unplayable` is the cause-unknown wiring guard (the
                    // remedy is play again / engine hiccup). Notices coalesce
                    // BY CODE, so folding both into one code would let one
                    // problem's message overwrite the other's — two distinct
                    // problems deserve two ring entries. The open/recover echo
                    // (`ProjectStore.echoMissingMediaNotices`) posts the SAME
                    // `clip-file-missing` code, so open-time and build-time
                    // detections of one missing file coalesce into one entry.
                    FileHandle.standardError.write(
                        Data("PlaybackGraph: cannot open \(fileURL.path): \(error)\n".utf8)
                    )
                    if fileOpenFailedNoticed.insert(key.id).inserted {
                        let missing = !FileManager.default.fileExists(atPath: fileURL.path)
                        noticeSink?(EngineNoticeEvent(
                            code: "clip-file-missing",
                            message: missing
                                ? "'\(domainClip.name)' plays as silence — its audio file is missing (\(fileURL.path)). Restore or re-link the file to hear this clip."
                                : "'\(domainClip.name)' plays as silence — its audio file couldn't be opened (\(fileURL.path)). The file may be damaged or in an unsupported format.",
                            beat: key.startBeat))
                    }
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
            if !isTrivial(routingSignature[trackID]) || !node.sendGainNodes.isEmpty
                || oldKeyInvolvedStrips.contains(trackID) {
                announceRoutingMutation()  // tearing down bus/key-facing wiring
                if needsEngineRebuild { return true }  // m13-a: engine rebuilds instead
            }
            node.renderer.publish(nil)
            node.renderer.requestFlush()
            node.mixer.removeTap(onBus: 0)
            teardownDetach(node.source)
            teardownDetach(node.mixer)
            for gain in node.sendGainNodes.values {
                teardownDetach(gain)
            }
            instrumentNodes.removeValue(forKey: trackID)
        }

        // Added instrument tracks; existing ones refresh their clip copy.
        // m16-h Leg 2 EXCLUSION (deliberate): instrument-strip birth on a
        // running engine does NOT announce. The reconfig defect is
        // player-start-specific — deep post-start `AVAudioSourceNode`
        // subtrees render fine (measured live, design-m16h §2-E6) and
        // instrument strips host no `AVAudioPlayerNode`s. Keeping this path
        // attach-only keeps arming/live-thru bring-up cheap (no rebuild
        // bounce to add an instrument mid-session).
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
                if needsEngineRebuild { return true }  // m13-a: engine rebuilds instead
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
            // m13-d §1-B: master fallback stays the main mixer — the master
            // chain sits POST-fader, downstream of it.
            let destination = key.outputBusID.flatMap { id in
                removedBuses.contains(id) ? nil : busNodes[id]?.sumMixer
            } ?? engine.mainMixerNode
            points.append(AVAudioConnectionPoint(
                node: destination, bus: destination.nextAvailableInputBus))
            // Sidechain key edges (m12-f): one extra fan-out point per keyed
            // destination — that strip's ChainHostAU input bus 1, an EXPLICIT
            // bus index (bus 1 is reserved for the key; never a
            // nextAvailableInputBus query, which could hand out the key bus
            // to ordinary wiring). A real graph edge = same-quantum pull,
            // spike-proven (SidechainBusSpikeTests). Destinations resolve
            // against the post-add node maps; a vanished one is skipped —
            // its flag clears at the tail and the effect self-keys.
            for destID in key.sidechainDestinations {
                guard let host = trackNodes[destID]?.chainHost
                    ?? busNodes[destID]?.chainHost else { continue }
                points.append(AVAudioConnectionPoint(node: host, bus: 1))
            }
            // Every node in the fan-out array is distinct (fresh gain mixers
            // + one output dest + foreign chain hosts), so each point's input
            // bus is settled.
            engine.connect(mixer, to: points, fromBus: 0, format: format)
            setSendGainNodes(gains, forTrack: track.id)
        }

        // 6. Removed bus nodes — last, so every ex-feeder was rewired above
        // and nothing still connects into these mixers. Tap off before detach.
        if !removedBuses.isEmpty {
            announceRoutingMutation()  // covers the unfed-bus removal case
            if needsEngineRebuild { return true }  // m13-a: engine rebuilds instead
        }
        for busID in removedBuses {
            guard let node = busNodes.removeValue(forKey: busID) else { continue }
            node.mixer.removeTap(onBus: 0)
            teardownDetach(node.mixer)
            teardownDetach(node.chainHost)
            teardownDetach(node.sumMixer)
        }

        // 7. Sidechain key-connected flags (m12-f): recomputed every pass
        // from the NEW signature so each destination's ChainHostAU mirrors
        // its physically wired key edge — armed only AFTER the wiring above
        // landed (arm-after-wire), cleared for every strip whose edge
        // vanished this pass (the render block then never touches bus 1 —
        // the bit-exact pre-sidechain path). One atomic store per strip.
        var wiredKeyDestinations: Set<UUID> = []
        for (sourceID, key) in newRoutingSignature
        where !key.sidechainDestinations.isEmpty && sourceMixer(forTrack: sourceID) != nil {
            wiredKeyDestinations.formUnion(key.sidechainDestinations)
        }
        for (trackID, node) in trackNodes {
            ChainHostAU.setKeyConnected(wiredKeyDestinations.contains(trackID),
                                        of: node.chainHost)
        }
        for (busID, node) in busNodes {
            ChainHostAU.setKeyConnected(wiredKeyDestinations.contains(busID),
                                        of: node.chainHost)
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
                teardownDetach(gain)
            }
            trackNodes[id]?.sendGainNodes = [:]
        }
        if let node = instrumentNodes[id] {
            for gain in node.sendGainNodes.values {
                teardownDetach(gain)
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

    /// Fixed latency of ONE live master-chain effect instance (m13-d, 0 when
    /// the id is unknown or the chain is empty) — surfaced through
    /// `AudioEngine.masterEffectLatencySamples(effectID:)`.
    func masterEffectLatencySamples(forEffect effectID: UUID) -> Int {
        masterChainState?.latencySamples(forEffect: effectID) ?? 0
    }

    /// Held-peak gain reduction of ONE live effect instance on a strip
    /// (m22-e; nil = unknown ids or kinds that don't measure GR) — surfaced
    /// through `AudioEngine.effectGainReductionDb(trackID:effectID:)`.
    func effectGainReductionDb(forTrack trackID: UUID, effectID: UUID) -> Double? {
        effectChainState(forTrack: trackID)?.gainReductionDb(forEffect: effectID)
    }

    /// Held-peak gain reduction of ONE live MASTER-chain effect instance
    /// (m22-e), the master twin — surfaced through
    /// `AudioEngine.masterEffectGainReductionDb(effectID:)`.
    func masterEffectGainReductionDb(forEffect effectID: UUID) -> Double? {
        masterChainState?.gainReductionDb(forEffect: effectID)
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
    /// The master strip does not exist as a graph strip (master is the
    /// sandwich into the main mixer) so the plan input is exactly the track +
    /// bus strips — the spec's master exclusion holds by construction; the
    /// master chain (m13-d) feeds `masterChainLatencySamples` in the REPORT
    /// only (design D5: common-path, delays every strip equally, no per-strip
    /// ring could correct it and none tries).
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
        // Sidechain key sources (m12-f) are `hasSends`-class planner inputs:
        // the key is tapped post-fader exactly like a send, so the source
        // pads to stage T deterministically (design-m11f-sidechain §4-A).
        // Single source of truth: the SAME pure helper the store and stem
        // plan read.
        let keySources = SidechainGraph.keySourceTrackIDs(tracks: tracks)
        for track in tracks {
            // Only strips that exist in the node tree participate: a ring
            // target has nowhere to land on a not-yet-reconciled strip, and
            // its latency is unknowable until its chain state exists. The
            // next parameter pass after reconcile picks it up.
            guard let chainState = effectChainState(forTrack: track.id) else { continue }
            let kind: PDCStripKind = track.kind == .bus
                ? .bus
                : .track(outputsToMaster: track.outputBusID == nil,
                         hasSends: !track.sends.isEmpty
                             || keySources.contains(track.id))
            // The strip's keyed effect (first wins, the reconcile rule):
            // report input for the honest `sidechainSkewSamples` — the ACTIVE
            // latency accumulated before the keyed slot is what the main
            // signal has seen when the key (aligned to its source's stage
            // target) arrives.
            var sidechainKey: SidechainKeyInput?
            if track.kind != .instrument {
                var latencyBefore = 0
                for effect in track.effects {
                    if let source = effect.sidechainSourceTrackID,
                       keySources.contains(source), source != track.id {
                        sidechainKey = SidechainKeyInput(
                            sourceID: source,
                            latencyBeforeKeyedEffectSamples: latencyBefore)
                        break
                    }
                    if !effect.isBypassed {
                        latencyBefore += chainState.latencySamples(forEffect: effect.id)
                    }
                }
            }
            let all = chainState.latencySamplesAllEffects
            allByID[track.id] = all
            strips.append(PDCStripInput(
                id: track.id, kind: kind,
                chainLatencyAll: all,
                chainLatencyActive: chainState.latencySamples,
                sidechainKey: sidechainKey))
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
                skewSamples: strip.skewSamples,
                sidechainSkewSamples: strip.sidechainSkewSamples)
        }
        pdcReport = PDCReport(trackStageSamples: plan.trackStage,
                              busStageSamples: plan.busStage,
                              // m13-d (design D5): the master chain's ACTIVE
                              // (non-bypassed) latency sum — report-only.
                              // The master is common-path (delays every strip
                              // equally) and NEVER a plan input; no per-strip
                              // ring could or should correct it. The figure
                              // legitimately moves on a master bypass toggle
                              // (no ring to absorb it — the honest
                              // ruler-to-speaker delay).
                              masterChainLatencySamples:
                                  masterChainState?.latencySamples ?? 0,
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

    /// The MASTER automation read head (m15-c) — schedule/no-restart
    /// assertions for the master-lane tests.
    func masterAutomationRendererForTesting() -> AutomationRenderer? {
        masterAutomationRenderer
    }

    /// The LIVE graph rate exactly as `graphFormat()` resolves it (the
    /// hardware default output device's rate, 48 kHz fallback when the query
    /// answers 0). m19-j: device-rate-derived test expectations read this so
    /// latency pins hold at ANY default-device rate — a 24 kHz Bluetooth
    /// headset in mic mode is a rate every AirPods user's default device
    /// actually runs at.
    var graphSampleRateForTesting: Double { graphFormat().sampleRate }

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
        // Master chain sync (m13-d R6): same pass position as the per-strip
        // sync above — every pass, both sides of every start, and inside
        // OfflineRenderer.render (offline parity for free). An atomic
        // snapshot publish into the master host's processor; never topology.
        // Ordered BEFORE the PDC recompute so the report's
        // masterChainLatencySamples sees post-edit latencies — the recompute
        // funnel's seventh event (master chain edit) with no new site.
        masterChainState?.sync(descriptors: masterEffects, sampleRate: chainRate)
        // Master volume lane (m15-c): the strip override rule mirrored onto
        // the master fader — same pass position, so offline parity and the
        // stopped-WYSIWYG/roll-start pins land exactly where strips' do.
        applyMasterVolume(playheadBeat: playheadBeat)
        // No-restart master republish (the strip rule above, verbatim): a
        // master lane changed under a rolling transport → rebuild ITS
        // schedule against the same anchor/epoch. Never a restart — master
        // automation is in no reconcile signature by construction.
        if rolling {
            let activeMasterLane = masterAutomation.activeLane(for: .volume)
            if let published = publishedMasterVolumeLane {
                if published != activeMasterLane { publishMasterAutomation(activeMasterLane) }
            } else if activeMasterLane != nil {
                publishMasterAutomation(activeMasterLane)
            }
        }
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
    ///
    /// m14-b L-2: under an active loop unroll the build is the LOOP-UNROLLED
    /// one (head window + per-cycle blocks through `scheduledThroughCycle`),
    /// on the roll's shared timelineID — both cycle extensions and mid-roll
    /// lane edits route through here, so they can never disagree about the
    /// unrolled shape. Without a loop the build is the linear one, verbatim.
    private func publishAutomation(
        for trackID: UUID, volume: AutomationLane?, pan: AutomationLane?,
        effectParams: [AutomationSchedule.EffectParamLaneSpec]
    ) {
        guard let context = automationRollContext,
              let renderer = automationRenderer(for: trackID) else { return }
        var schedule: AutomationSchedule?
        if volume != nil || pan != nil || !effectParams.isEmpty {
            schedule = buildRollSchedule(context: context, volume: volume,
                                         pan: pan, effectParams: effectParams)
        }
        renderer.publish(schedule)
        publishedAutomationLanes[trackID] = (volume, pan, effectParams)
    }

    /// ONE schedule build for the current roll, shared by the strip and the
    /// MASTER publishes (m15-c) — under an active loop unroll it is the
    /// loop-unrolled build (head + per-cycle blocks through
    /// `scheduledThroughCycle`, §8.6 containment); otherwise the linear one.
    /// A master lane therefore unrolls across loop cycles EXACTLY like a
    /// track lane, by construction — the two paths cannot disagree.
    private func buildRollSchedule(
        context: (fromBeat: Double, tempoMap: TempoMap, mode: AutomationSchedule.Mode),
        volume: AutomationLane?, pan: AutomationLane?,
        effectParams: [AutomationSchedule.EffectParamLaneSpec]
    ) -> AutomationSchedule? {
        automationGeneration += 1
        if let state = loopUnroll {
            return AutomationSchedule.buildLoopUnrolled(
                volumeLane: volume, panLane: pan, effectParamLanes: effectParams,
                fromBeat: state.fromBeat,
                loopStartBeat: state.loop.startBeat,
                loopEndBeat: state.loop.endBeat,
                headSeconds: state.headSeconds,
                cycleSeconds: state.cycleSeconds,
                // §8.6 containment (m14-d L-4): delivered history below
                // the containment bound is not rebuilt — blocks are
                // self-contained, so every value at/after the bound is
                // identical to the unpruned build (suffix identity).
                fromCycle: state.prunedBelowCycle,
                throughCycle: state.scheduledThroughCycle,
                tempoMap: state.tempoMap,
                sampleRate: graphFormat().sampleRate,
                generation: automationGeneration, mode: context.mode,
                timelineID: automationRollTimelineID)
        }
        return AutomationSchedule.build(
            volumeLane: volume, panLane: pan, effectParamLanes: effectParams,
            fromBeat: context.fromBeat, tempoMap: context.tempoMap,
            sampleRate: graphFormat().sampleRate,
            generation: automationGeneration, mode: context.mode,
            timelineID: automationRollTimelineID)
    }

    // MARK: - Master volume automation (m15-c)

    /// The master chain host's automation read head — the master twin of
    /// `automationRenderer(for:)`. nil until `ensureMasterSandwich` builds
    /// the host (and forever on a spike graph with the sandwich disabled —
    /// every master publish then no-ops, the pre-m15-c behavior).
    private var masterAutomationRenderer: AutomationRenderer? {
        masterChainHost.flatMap { ChainHostAU.automationRenderer(of: $0) }
    }

    /// Builds and publishes the MASTER schedule against the current roll
    /// context (nil lane → unpublish) — `publishAutomation` for the master
    /// owner, same generation counter, same timeline, same (shared) builder.
    private func publishMasterAutomation(_ volumeLane: AutomationLane?) {
        guard let context = automationRollContext,
              let renderer = masterAutomationRenderer else { return }
        var schedule: AutomationSchedule?
        if volumeLane != nil {
            schedule = buildRollSchedule(context: context, volume: volumeLane,
                                         pan: nil, effectParams: [])
        }
        renderer.publish(schedule)
        publishedMasterVolumeLane = .some(volumeLane)
    }

    /// ONE computed write for the master fader under the override rule
    /// (m15-c): an ACTIVE master volume lane pins `mainMixerNode.outputVolume`
    /// to 1 while rolling (the pre-walk stage in the master chain host
    /// supplies the lane gain) and previews `value(atBeat:)` while stopped
    /// (stopped WYSIWYG); a deactivated lane hands the node back to
    /// `manualMasterVolume` ONCE. With no lane history this never touches
    /// the node — the null path's `mainMixerNode.outputVolume` ownership
    /// (AudioEngine/OfflineRenderer) is byte-identical to pre-m15-c.
    private func applyMasterVolume(playheadBeat: Double) {
        if let lane = masterAutomation.activeLane(for: .volume) {
            let gain = automationRollContext != nil
                ? 1.0
                : (lane.value(atBeat: playheadBeat) ?? manualMasterVolume)
            engine.mainMixerNode.outputVolume = Float(gain)
            masterFaderUnderLaneAuthority = true
        } else if masterFaderUnderLaneAuthority {
            engine.mainMixerNode.outputVolume = Float(manualMasterVolume)
            masterFaderUnderLaneAuthority = false
        }
    }

    /// The `mixer.setMasterVolume` intent (m15-c): caches the manual gain
    /// and lands it through the override rule in ONE node write — under lane
    /// authority the lane keeps ruling (a fader move mid-lane never blips
    /// the pin or the preview); with no active lane this is the pre-m15-c
    /// direct write, verbatim.
    func setManualMasterVolume(_ volume: Double, playheadBeat: Double) {
        manualMasterVolume = volume
        if masterAutomation.activeLane(for: .volume) != nil {
            applyMasterVolume(playheadBeat: playheadBeat)
        } else {
            masterFaderUnderLaneAuthority = false
            engine.mainMixerNode.outputVolume = Float(volume)
        }
    }

    /// OFFLINE SEAM: arms the roll context BEFORE the pre-start parameter
    /// pass, so the volume-override pin (mixer gain 1) is in place before
    /// `engine.start()` and never ramps into the bounce head (the measured
    /// post-start outputVolume ramp leak). Live starts don't need this — the
    /// ~60 ms anchor lead-in absorbs the pin before schedule t=0.
    func armOfflineAutomation(fromBeat: Double, tempoMap: TempoMap) {
        automationRollContext = (fromBeat, tempoMap, .offline)
        automationGeneration += 1
        automationRollTimelineID = automationGeneration
    }

    private func addTrackNode(for trackID: UUID) -> TrackNode {
        let node = makeStripSandwich(for: trackID)
        return TrackNode(sumMixer: node.sumMixer, chainHost: node.chainHost,
                         chainState: node.chainState,
                         automation: node.automation, mixer: node.mixer)
    }

    // MARK: - Master chain insert construction (m13-d R1, shape §1-B)

    /// ONE creation site, idempotent, fresh-nodes-only (R1): builds the
    /// post-fader master insert `mainMixerNode → masterChainHost →
    /// outputNode`, once per graph lifetime, before the first render. Runs
    /// at `reconcile` entry and from `AudioEngine.prepare()` (which covers
    /// `rebuildEngine`'s cold build too) before `engine.start()`. It only
    /// ever attaches a fresh node and connects fresh edges (the sole
    /// pre-existing edge it replaces is the IMPLICIT mainMixer → output
    /// wiring, re-routed before the engine ever starts/renders in every
    /// production path) — the track.add-class operation the announce
    /// machinery exempts (m13-c) — so it can NEVER set `needsEngineRebuild`
    /// (pinned by test). There is no teardown path: a rebuild discards the
    /// whole engine (m13-a), and the insert dies with it.
    ///
    /// Kept under the design's `ensureMasterSandwich` name for traceability
    /// to design-m13d §1/§8 even though the C0 verdict made the shape the
    /// §1-B post-fader insert, not the D1 sandwich (see the property docs).
    func ensureMasterSandwich() {
        guard masterSandwichEnabled, masterChainHost == nil else { return }
        let chainHost = ChainHostAU.makeChainHostNode()
        // Telemetry wiring at node creation, before the engine ever renders
        // (the setPerformanceContext boundary contract) — master chain DSP
        // counts into perf-b like any strip.
        ChainHostAU.setPerformanceContext(performance, of: chainHost)
        engine.attach(chainHost)
        let format = graphFormat()
        // EXPLICIT toBus 0 (the m12-f rule): bus 1 is the (never-armed) key
        // bus; the main feed must not ride a nextAvailableInputBus query.
        // Connecting the main mixer's output re-routes the implicit
        // mixer → output edge through the chain host.
        engine.connect(engine.mainMixerNode, to: chainHost, fromBus: 0, toBus: 0,
                       format: format)
        if referenceLaneEnabled {
            // m22-g P2 (design §5.1): the live-only monitor lane —
            // chainHost → mixMonitorGate → monitorSum → outputNode plus
            // referencePlayer → referenceGain → monitorSum. Stock nodes,
            // attached HERE (before the engine ever starts/renders in every
            // production path — the m16-h attach-while-running raise class
            // never applies), fresh-nodes-only like the chain host itself.
            let gate = AVAudioMixerNode()
            let sum = AVAudioMixerNode()
            let player = AVAudioPlayerNode()
            let gain = AVAudioMixerNode()
            engine.attach(gate)
            engine.attach(sum)
            engine.attach(player)
            engine.attach(gain)
            // EXPLICIT toBus on the summing node (the m12-f rule): bus 0 is
            // the mix feed, bus 1 the reference — never a
            // nextAvailableInputBus query.
            engine.connect(chainHost, to: gate, fromBus: 0, toBus: 0, format: format)
            engine.connect(gate, to: sum, fromBus: 0, toBus: 0, format: format)
            // The player edge forms at the GRAPH format; scheduled file
            // segments convert from the file's processing format inside the
            // player (AVAudioPlayerNode's documented file-segment
            // conversion) — keeping the topology fully static, no
            // file-known-time reconnect. (The design's §5.1 wording put SRC
            // on `referenceGain`; the player's own converter is the same
            // audible result with zero mid-life connect calls.)
            engine.connect(player, to: gain, fromBus: 0, toBus: 0, format: format)
            engine.connect(gain, to: sum, fromBus: 0, toBus: 1, format: format)
            engine.connect(sum, to: engine.outputNode, format: format)
            // Defaults: hear the mix, reference at unity until the store
            // pushes a match gain, sum strictly unity (never touched).
            gate.outputVolume = 1
            gain.outputVolume = 1
            sum.outputVolume = 1
            mixMonitorGate = gate
            monitorSum = sum
            referencePlayer = player
            referenceGain = gain
        } else {
            engine.connect(chainHost, to: engine.outputNode, format: format)
        }
        let processor: EffectChainProcessor
        if let hosted = ChainHostAU.chainProcessor(of: chainHost) {
            processor = hosted
        } else {
            // Never expected (in-process subclass by construction — the
            // strip-sandwich fallback verbatim): master inserts go inert,
            // audio passes through.
            FileHandle.standardError.write(Data(
                "PlaybackGraph: master chain host is not ChainHostAU — master inserts disabled\n".utf8))
            processor = EffectChainProcessor()
        }
        let chainState = EffectChainState(processor: processor)
        // Built-ins only on master in v1 (design D4a) — the provider thunk is
        // wired for strip-construction symmetry; no master AU is ever
        // prepared, so a hosted kind would resolve nil → the passthrough
        // placeholder.
        chainState.hostedEffectProvider = { [weak self] id in
            self?.hostedEffectProvider(id)
        }
        // m15-c: the master host's volume-automation stage runs PRE-walk —
        // the §1-B fader position (set at creation, before any render; the
        // setPerformanceContext boundary discipline). Strip hosts keep the
        // post-walk default.
        ChainHostAU.setVolumeStagePreChain(true, of: chainHost)
        masterChainHost = chainHost
        masterChainState = chainState
    }

    // MARK: - Reference monitor lane control (m22-g P2, control plane only)

    /// Post-chain mix gate (design D4): open = hear the mix, closed = hear
    /// the reference. A main-actor param write on a stock mixer — the same
    /// node-level property the strip faders trust.
    func setMixMonitorGate(open: Bool) {
        mixMonitorGate?.outputVolume = open ? 1 : 0
    }

    /// Level-match gain on the reference branch, linear (the store-computed
    /// `ReferenceLevelMatch.linearGain`).
    func setReferenceMonitorGain(linear: Double) {
        referenceGain?.outputVolume = Float(linear)
    }

    /// Schedules ONE monitor engagement of the reference file (design §5.4):
    /// the tail of the file from `fileStartSeconds` (caller-mapped timeline →
    /// file time, ≥ 0), optionally deferred by `playerDelaySeconds` of
    /// player-relative time (the negative-mapped-file-time case: the player
    /// starts on its anchor and the audio begins when file time reaches 0).
    /// Raises the m19-f-style ledger. Returns false when the lane is absent
    /// or nothing remains to play (mapped position past EOF) — the caller
    /// then simply leaves the player idle (honest silence, matching what the
    /// timeline maps to).
    func scheduleReference(file: AVAudioFile, fileStartSeconds: Double,
                           playerDelaySeconds: Double) -> Bool {
        guard let player = referencePlayer else { return false }
        let fileRate = file.processingFormat.sampleRate
        guard fileRate > 0, fileStartSeconds >= 0 else { return false }
        let startFrame = AVAudioFramePosition((fileStartSeconds * fileRate).rounded())
        let remaining = file.length - startFrame
        guard remaining > 0 else { return false }
        var at: AVAudioTime?
        if playerDelaySeconds > 0 {
            // Player-relative sample time (player time 0 ≡ its start
            // anchor — the metronome click-anchor convention). The player's
            // output edge runs at the graph rate.
            let playerRate = player.outputFormat(forBus: 0).sampleRate
            if playerRate > 0 {
                at = AVAudioTime(
                    sampleTime: AVAudioFramePosition(
                        (playerDelaySeconds * playerRate).rounded()),
                    atRate: playerRate)
            }
        }
        player.scheduleSegment(file, startingFrame: startFrame,
                               frameCount: AVAudioFrameCount(remaining), at: at)
        referenceScheduled = true
        return true
    }

    /// Starts the reference player against `anchor` (the caller computes
    /// shared-anchor + PDC delay). Ledger-gated; a raise converts to one
    /// stderr line and a skipped audition — never a crash, and the ledger
    /// stays raised so the next stop clears the queue (the clip asymmetry).
    func startReference(at anchor: AVAudioTime) {
        guard referenceScheduled, let player = referencePlayer else { return }
        do {
            try withObjCExceptionBarrier("reference player start") {
                player.play(at: anchor)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "PlaybackGraph: reference player start raised — audition skipped: \(error)\n".utf8))
        }
    }

    /// Player-local stop (design D6): clears the queue, resets player time
    /// to 0, lowers the ledger. Ledger-gated — an idle lane costs zero
    /// start/stop handshakes (m19-f).
    func stopReference() {
        guard referenceScheduled, let player = referencePlayer else { return }
        player.stop()
        referenceScheduled = false
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
        // EXPLICIT toBus 0 (m12-f): the chain host now declares two input
        // busses — bus 0 is the strip's main audio, bus 1 is reserved for a
        // sidechain key edge. The main feed must never ride a
        // nextAvailableInputBus query that could land on the key bus.
        engine.connect(sumMixer, to: chainHost, fromBus: 0, toBus: 0, format: format)
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
                teardownDetach(clipNode.player)
                trackNodes[trackID]?.clips.removeValue(forKey: clipID)
            }
        }
    }

    /// Tears down ONE instrument track's node (unpublish + flush, tap off,
    /// detach) and drops its signature entry so the next `reconcile` rebuilds
    /// it — the seam AudioEngine uses when an async AU preparation finishes
    /// and the placeholder node must be replaced with the real instrument.
    ///
    /// m13-a: on a once-rendered engine, a strip with bus-facing wiring is
    /// announce-class — the ENGINE is replaced, not the node. The renderer
    /// unpublishes (all-notes-off this quantum), the nodes stay attached,
    /// and the caller's follow-up `tracksDidChange` consumes
    /// `needsEngineRebuild` — the fresh graph builds the strip with the
    /// now-prepared instrument via the provider, so no invalidation state
    /// survives or needs to.
    func invalidateInstrumentNode(trackID: UUID) {
        instrumentSignature.removeValue(forKey: trackID)
        guard let node = instrumentNodes.removeValue(forKey: trackID) else { return }
        let key = routingSignature[trackID]
        if key?.outputBusID != nil || !node.sendGainNodes.isEmpty {
            willMutateRoutingTopology?()
            if engineHasRun {
                needsEngineRebuild = true
                node.renderer.publish(nil)
                node.renderer.requestFlush()
                node.mixer.removeTap(onBus: 0)
                return
            }
        }
        node.renderer.publish(nil)
        node.renderer.requestFlush()
        node.mixer.removeTap(onBus: 0)
        teardownDetach(node.source)
        teardownDetach(node.mixer)
        for gain in node.sendGainNodes.values {
            teardownDetach(gain)
        }
    }

    /// The explicit graph-rate stereo format for every mixer-level
    /// connection. `format: nil` would keep a fresh mixer's default 44.1 kHz
    /// output and force a second SRC in the main mixer, breaking sample
    /// accuracy (measured: 32-frame onset error at 48 kHz). m20-c: the rate
    /// is the INJECTED construction rate — every production owner passes one
    /// (the device rate at build time live, the render rate offline). Only
    /// un-injected graphs (headless test rigs) keep the legacy call-time
    /// query: the output node reports the manual-rendering format offline
    /// and the hardware format live; the 48 kHz fallback covers a
    /// not-yet-configured output.
    private func graphFormat() -> AVAudioFormat {
        let rate: Double
        if let graphRate {
            rate = graphRate
        } else {
            let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            rate = outputRate > 0 ? outputRate : 48_000
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            preconditionFailure("standard \(rate) Hz stereo format must exist")
        }
        return format
    }

    /// The graph's processing rate exactly as `graphFormat()` resolves it —
    /// the ONE value AU prepare keys and the metronome's attach format must
    /// share with every graph edge (m20-c: consumers read the injected
    /// build-time rate here instead of querying the output node live).
    var graphSampleRate: Double { graphFormat().sampleRate }

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

    /// Live loop window for wrap-aware schedule-ahead (m14-a L-1, design
    /// design-m13f-gapless-loop §4 Option A). Passed by the LIVE engine only;
    /// the offline renderer never loops (OfflineRenderer doc — one linear
    /// pass), so `loop: nil` keeps every existing call site byte-identical.
    struct LoopWindow: Equatable {
        let startBeat: Double
        let endBeat: Double
    }

    /// One queueable piece of a clip's full-cycle schedule: either a baked
    /// buffer (fade/envelope shape — baked ONCE, re-enqueued every cycle: the
    /// Metronome "top-ups only enqueue existing buffers" precedent) or a
    /// streamed file segment.
    private enum LoopCycleItem {
        case buffer(AVAudioPCMBuffer)
        case segment(startingFrame: AVAudioFramePosition, frameCount: AVAudioFrameCount)
    }

    /// One clip's contribution to EVERY full loop cycle [loopStart, loopEnd):
    /// identical window each cycle, so the pieces are computed and baked once.
    /// The first item carries the cycle's explicit player-relative anchor
    /// (`round((cycleStartSec + anchorOffsetSeconds) · fileRate)` — an
    /// ABSOLUTE integral per cycle, never `previous + loopFrames`); the rest
    /// queue `at: nil`, contiguous, exactly like the linear piece chain.
    private struct LoopClipPlan {
        let node: ClipNode
        let fileRate: Double
        /// Within-cycle seconds from the loop start to the clip's first
        /// scheduled frame (0 for clips already sounding at the loop start).
        let anchorOffsetSeconds: Double
        let items: [LoopCycleItem]
    }

    /// Loop unroll state (m14-a L-1): set by `scheduleAll(loop:)`, consumed
    /// by `topUpLoopCycles`, cleared by `stopAllPlayers` (every stop / seek /
    /// edit restart) and by any linear `scheduleAll`. Cycle placement derives
    /// from `headSeconds` / `cycleSeconds` — map integrals evaluated ONCE, so
    /// every cycle anchor is the absolute integral (design §8.2).
    private struct LoopUnrollState {
        /// Player-relative seconds at which cycle 1 begins (integral from the
        /// schedule's `fromBeat` to the loop end — the cycle-0 head pass).
        let headSeconds: Double
        /// Exact loop period: the map integral over [startBeat, endBeat).
        let cycleSeconds: Double
        /// Whole unrolled cycles queued so far (0 = only the head pass).
        var scheduledThroughCycle: Int
        let clipPlans: [LoopClipPlan]
        // m14-b L-2: the non-audio unroll builds per-cycle blocks from these.
        let loop: LoopWindow
        let fromBeat: Double
        let tempoMap: TempoMap
        /// Next noteID base per instrument track (schedule-wide uniqueness
        /// across appended cycle blocks — the C2 exactly-once accounting).
        var midiNoteIDBase: [UUID: UInt64] = [:]
        /// §8.6 containment (m14-d L-4): the first cycle whose MIDI events /
        /// automation blocks are still materialized (0 = head retained,
        /// nothing pruned). Advanced by `topUpLoopCycles` under the
        /// suffix-identity law — events strictly below cycle
        /// `prunedBelowCycle`'s absolute-integral start frame are removed
        /// from the staged arrays, and automation rebuilds from this cycle.
        var prunedBelowCycle: Int = 0
    }

    private var loopUnroll: LoopUnrollState?

    /// §8.6 containment threshold (m14-d L-4): once the retained history
    /// spans this many cycles below the containment bound, the next top-up
    /// prunes. The bound itself is `soundingCycle − 1` (one FULL cycle of
    /// margin below the control thread's render-clock snapshot, which
    /// lower-bounds the render side's delivered watermark — the suffix-
    /// identity law's safety condition). Retained history is therefore
    /// bounded at ~(threshold + margin + eager/coverage lookahead) cycles of
    /// events forever, regardless of total cycles played. Internal (not
    /// private) so the containment soak can pin the trigger arithmetic.
    static let loopPruneThresholdCycles = 8

    /// One MIDI timeline per roll (m14-b L-2): minted by `startAllPlayers`
    /// from the same monotonic `scheduleGeneration` counter (so it can never
    /// collide with a default `timelineID == generation` schedule), cleared
    /// by `stopAllPlayers`. Loop-cycle extension republishes reuse BOTH the
    /// id and the anchor `mode` — the render side then re-seeks instead of
    /// resetting, and voices persist across the wrap (design §5, §9-C2).
    private var midiRollContext: (timelineID: UInt64, mode: MIDIEventSchedule.Mode)?

    /// The automation timeline of the current roll (same contract), minted
    /// wherever `automationRollContext` is armed — extension and lane-edit
    /// republishes share it, so the renderer keeps its latched offline epoch.
    private var automationRollTimelineID: UInt64 = 0

    /// Test seam: how many full cycles are currently queued (nil = no loop
    /// unroll active). Read by the C6 horizon-law gate.
    var loopScheduledThroughCycle: Int? { loopUnroll?.scheduledThroughCycle }

    /// Test seam (m14-d L-4): the first still-materialized cycle (§8.6
    /// containment; 0 = nothing pruned, nil = no loop unroll active). The
    /// containment soak counts its transitions and pins the bound.
    var loopPrunedBelowCycle: Int? { loopUnroll?.prunedBelowCycle }

    /// Test seam (m19-f R1): one clip player's enqueue-ledger flag — nil
    /// when the clip has no node (missing media, stretch pending, unknown
    /// id). Read by IdlePlayerSkipTests T1/T3–T5.
    func clipHasPendingSchedule(clipID: UUID) -> Bool? {
        clipNode(for: clipID)?.hasPendingSchedule
    }

    /// Test seam (m19-f R1): one clip's player node, for `isPlaying`
    /// observation in the skip gates. Never used by production code — no
    /// in-tree consumer reads clip-player state (design §5 invariant).
    func clipPlayerForTesting(clipID: UUID) -> AVAudioPlayerNode? {
        clipNode(for: clipID)?.player
    }

    private func clipNode(for clipID: UUID) -> ClipNode? {
        for node in trackNodes.values {
            if let clip = node.clips[clipID] { return clip }
        }
        return nil
    }

    /// Schedules every clip player-relative: player sample time 0 ≡ transport
    /// position `fromBeat`. All math is in file-rate frames. m12-b: clip
    /// boundaries convert through the tempo-map integral (signed for pre-roll
    /// clips) — bit-identical to the old fixed `secondsPerBeat` for the
    /// Phase-A trivial map. Audio never time-stretches with tempo; the region
    /// window truncates or under-fills the file.
    ///
    /// m14-a L-1: a non-nil `loop` additionally truncates every clip region
    /// at the loop END (content past the boundary is never queued — cycle
    /// N+1 is scheduled explicitly at its own anchor, so unwindowed content
    /// would both overshoot the wrap and collide with the next cycle's
    /// anchors) and builds the per-clip full-cycle plans that
    /// `topUpLoopCycles` unrolls. With `loop == nil` (offline render, linear
    /// live playback, recording) the schedule is byte-identical to pre-m14-a.
    func scheduleAll(fromBeat startBeats: Double, tempoMap: TempoMap,
                     loop: LoopWindow? = nil) {
        loopUnroll = nil
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
            var clipLengthFrames = AVAudioFramePosition((regionSec * fileRate).rounded())
            // m14-a L-1: under a live loop the region ALSO truncates at the
            // loop end (same integral-then-round convention). Clips at/past
            // the loop end fall out through the frameCount guard below.
            if let loop {
                let windowSec = tempoMap.seconds(from: clip.key.startBeat, to: loop.endBeat)
                clipLengthFrames = min(clipLengthFrames,
                                       AVAudioFramePosition((windowSec * fileRate).rounded()))
            }
            let sourceStart = fileOffsetFrames + segStart
            guard sourceStart < fileLength else { return }
            let sourceEnd = min(fileLength, fileOffsetFrames + clipLengthFrames)
            let frameCount = sourceEnd - sourceStart
            guard frameCount > 0 else { return }

            let whenSample = AVAudioFramePosition((max(0, clipStartSec) * fileRate).rounded())
            let when = AVAudioTime(sampleTime: whenSample, atRate: fileRate)

            // Gain envelope (m13-e → m13-h2): an enveloped clip takes the
            // PIECEWISE plan — only the spans the envelope (or a fade) shapes
            // are baked; provably-unity spans stream straight off the file,
            // bit-identical to the old full-region bake's `× 1.0` there.
            // MEASURED (m13-h2, 10-min stereo 48 k clip, 4-beat dip): the old
            // whole-region bake cost ~155 ms + ~230 MB at EVERY scheduleAll;
            // piecewise bakes only the shaped frames. The EMPTY-envelope path
            // below is byte-untouched (the null-case gate).
            if !clip.clip.gainEnvelope.isEmpty {
                scheduleEnvelopedPieces(
                    clip: clip, tempoMap: tempoMap,
                    fileOffsetFrames: fileOffsetFrames,
                    segmentStart: segStart, frameCount: frameCount, at: when)
                return
            }

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
                clip.enqueueSegment(
                    startingFrame: sourceStart,
                    frameCount: AVAudioFrameCount(frameCount),
                    at: when
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
                // m15-e (audit F6): timing won, shape was dropped — tell the
                // session, not just stderr.
                noticeSink?(EngineNoticeEvent(
                    code: "clip-fades-skipped",
                    message: "Fades on '\(clip.clip.name)' couldn't be applied this pass — the clip played on time, without its fades.",
                    beat: clip.key.startBeat))
                clip.enqueueSegment(
                    startingFrame: sourceStart,
                    frameCount: AVAudioFrameCount(frameCount),
                    at: when)
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
                clip.enqueueBuffer(fadeInBuffer, at: takeAnchor())
            }
            if plan.middleFrames > 0 {
                clip.enqueueSegment(
                    startingFrame: fileOffsetFrames + plan.fadeInEnd,
                    frameCount: AVAudioFrameCount(plan.middleFrames),
                    at: takeAnchor())
            }
            if let fadeOutBuffer {
                clip.enqueueBuffer(fadeOutBuffer, at: takeAnchor())
            }
        }

        if let loop {
            buildLoopUnroll(fromBeat: startBeats, tempoMap: tempoMap, loop: loop)
        }

        // Instrument tracks: stage the merged, sorted event build for each
        // track's schedule (published by startAllPlayers). Pure math on the
        // main actor — microseconds, never render-thread work. Fixed MAP
        // per schedule (m12-b); setTempo (and any future map edit) restarts
        // → rebuilds.
        //
        // m14-b L-2: under a MATERIALIZED loop unroll the head build windows
        // its note-ONS at the loop end (cycle blocks own everything past it —
        // unwindowed ons would collide with cycle 1's), while note-OFFS still
        // land at their natural times, past the boundary if the note
        // straddles it (tails ring through the seam, design §5). Cycles are
        // appended by `topUpLoopCycles` → `extendLoopMIDI`, append-only from
        // this same anchor. With no loop the build is byte-identical to
        // pre-m14 (`onsetEndBeat: nil`).
        let onsetWindowEnd = loopUnroll != nil ? loop?.endBeat : nil
        for (trackID, node) in instrumentNodes {
            let build = MIDIEventSchedule.buildEvents(
                clips: node.clips, fromBeat: startBeats, tempoMap: tempoMap,
                sampleRate: node.renderer.sampleRate,
                onsetEndBeat: onsetWindowEnd
            )
            node.pendingEvents = build.events
            if onsetWindowEnd != nil {
                // m16-b2 (design-m16b §4.2, C5): the next noteID comes from
                // the build itself. The old `count / 2` derivation assumed
                // every event is half of an on/off pair — controller events
                // (kinds 2/3/4, chase prefixes included) break that and would
                // double-book IDs across appended cycle blocks.
                loopUnroll?.midiNoteIDBase[trackID] = build.nextNoteID
            }
        }
    }

    // MARK: - Loop cycle unroll (m14-a L-1, design-m13f-gapless-loop §4-A)

    /// Computes the loop timing constants and every clip's full-cycle plan
    /// (fade/envelope buffers baked ONCE here — a wrap costs zero allocation
    /// after this). No plans (MIDI-only loop, clips outside the window) still
    /// records the state: cycle bookkeeping is what the top-up drives.
    private func buildLoopUnroll(fromBeat: Double, tempoMap: TempoMap, loop: LoopWindow) {
        let cycleSeconds = tempoMap.seconds(from: loop.startBeat, to: loop.endBeat)
        let headSeconds = tempoMap.seconds(from: fromBeat, to: loop.endBeat)
        guard cycleSeconds > 0, headSeconds > 0 else { return }
        var plans: [LoopClipPlan] = []
        forEachClip { clip in
            if let plan = buildCyclePlan(clip: clip, tempoMap: tempoMap, loop: loop) {
                plans.append(plan)
            }
        }
        loopUnroll = LoopUnrollState(headSeconds: headSeconds, cycleSeconds: cycleSeconds,
                                     scheduledThroughCycle: 0, clipPlans: plans,
                                     loop: loop, fromBeat: fromBeat, tempoMap: tempoMap)
    }

    /// One clip's schedule for a FULL cycle [loopStart, loopEnd) — the same
    /// per-clip math as the linear pass in `scheduleAll`, with the window
    /// origin at the loop start (clips beginning before the loop start enter
    /// mid-file; clips past the loop end contribute nothing). Fade/envelope
    /// pieces mirror the linear discipline exactly: bake everything FIRST, a
    /// read failure falls back to the single plain segment (timing wins).
    private func buildCyclePlan(clip: ClipNode, tempoMap: TempoMap,
                                loop: LoopWindow) -> LoopClipPlan? {
        let fileRate = clip.file.processingFormat.sampleRate
        let fileLength = clip.file.length

        let clipStartSec = tempoMap.seconds(from: loop.startBeat, to: clip.key.startBeat)
        let regionSec = tempoMap.seconds(
            from: clip.key.startBeat,
            to: clip.key.startBeat + clip.key.lengthBeats)
        let offsetSec = max(0, -clipStartSec)
        let fileOffsetFrames = AVAudioFramePosition(
            (clip.clip.startOffsetSeconds * clip.clip.stretchRatio * fileRate).rounded())
        let segStart = AVAudioFramePosition((offsetSec * fileRate).rounded())
        let windowSec = tempoMap.seconds(from: clip.key.startBeat, to: loop.endBeat)
        let clipLengthFrames = min(
            AVAudioFramePosition((regionSec * fileRate).rounded()),
            AVAudioFramePosition((windowSec * fileRate).rounded()))
        let sourceStart = fileOffsetFrames + segStart
        guard sourceStart < fileLength else { return nil }
        let sourceEnd = min(fileLength, fileOffsetFrames + clipLengthFrames)
        let frameCount = sourceEnd - sourceStart
        guard frameCount > 0 else { return nil }
        let anchorOffsetSeconds = max(0, clipStartSec)

        let plainSegment = LoopCycleItem.segment(
            startingFrame: sourceStart, frameCount: AVAudioFrameCount(frameCount))

        if !clip.clip.gainEnvelope.isEmpty {
            let pieces = ClipFadeBake.envelopedPiecePlan(
                clip: clip.clip, tempoMap: tempoMap, fileRate: fileRate,
                segmentStart: segStart, segmentFrameCount: frameCount)
            var items: [LoopCycleItem] = []
            do {
                let reader = try clip.bakeReader()
                for piece in pieces {
                    if piece.bake {
                        items.append(.buffer(try ClipFadeBake.bakePiece(
                            file: reader,
                            sourceStartFrame: fileOffsetFrames + piece.start,
                            frameCount: piece.frameCount,
                            clip: clip.clip,
                            clipRelativeStartFrame: piece.start,
                            tempoMap: tempoMap)))
                    } else {
                        items.append(.segment(
                            startingFrame: fileOffsetFrames + piece.start,
                            frameCount: AVAudioFrameCount(piece.frameCount)))
                    }
                }
            } catch {
                FileHandle.standardError.write(Data(
                    "PlaybackGraph: loop-cycle envelope bake failed for \(clip.file.url.lastPathComponent) — cycles schedule WITHOUT envelope or fades (timing wins): \(error)\n".utf8))
                // m15-e (audit F6): same code as the linear envelope drop —
                // one degradation family, coalesced by code in the store.
                noticeSink?(EngineNoticeEvent(
                    code: "clip-envelope-skipped",
                    message: "The gain envelope on '\(clip.clip.name)' couldn't be applied to its looped repeats — they play on time, without the envelope or fades.",
                    beat: clip.key.startBeat))
                items = [plainSegment]
            }
            return LoopClipPlan(node: clip, fileRate: fileRate,
                                anchorOffsetSeconds: anchorOffsetSeconds, items: items)
        }

        let plan = ClipFadeBake.piecePlan(
            clip: clip.clip, tempoMap: tempoMap, fileRate: fileRate,
            segmentStart: segStart, segmentFrameCount: frameCount)
        guard plan.needsBake else {
            return LoopClipPlan(node: clip, fileRate: fileRate,
                                anchorOffsetSeconds: anchorOffsetSeconds,
                                items: [plainSegment])
        }
        var items: [LoopCycleItem] = []
        do {
            let reader = try clip.bakeReader()
            if plan.fadeInFrames > 0 {
                items.append(.buffer(try ClipFadeBake.bakePiece(
                    file: reader,
                    sourceStartFrame: fileOffsetFrames + plan.segmentStart,
                    frameCount: plan.fadeInFrames,
                    clip: clip.clip,
                    clipRelativeStartFrame: plan.segmentStart,
                    tempoMap: tempoMap)))
            }
            if plan.middleFrames > 0 {
                items.append(.segment(
                    startingFrame: fileOffsetFrames + plan.fadeInEnd,
                    frameCount: AVAudioFrameCount(plan.middleFrames)))
            }
            if plan.fadeOutFrames > 0 {
                items.append(.buffer(try ClipFadeBake.bakePiece(
                    file: reader,
                    sourceStartFrame: fileOffsetFrames + plan.fadeOutStart,
                    frameCount: plan.fadeOutFrames,
                    clip: clip.clip,
                    clipRelativeStartFrame: plan.fadeOutStart,
                    tempoMap: tempoMap)))
            }
        } catch {
            FileHandle.standardError.write(Data(
                "PlaybackGraph: loop-cycle fade bake failed for \(clip.file.url.lastPathComponent) — cycles schedule unfaded: \(error)\n".utf8))
            // m15-e (audit F6): same code as the linear fade drop — one
            // degradation family, coalesced by code in the store.
            noticeSink?(EngineNoticeEvent(
                code: "clip-fades-skipped",
                message: "Fades on '\(clip.clip.name)' couldn't be applied to its looped repeats — they play on time, without fades.",
                beat: clip.key.startBeat))
            items = [plainSegment]
        }
        return LoopClipPlan(node: clip, fileRate: fileRate,
                            anchorOffsetSeconds: anchorOffsetSeconds, items: items)
    }

    /// Extends the queued loop cycles. Called by the live playhead task every
    /// tick (control thread) and once at start (`elapsed 0`). No-op without
    /// loop state. Buffers re-enqueue, files re-read from their region start
    /// (both spike-proven, L-0 tests 2–3). The target is the MAX of two laws:
    ///
    ///  · COVERAGE (design C6 horizon law): cycles queued through
    ///    `elapsed + horizon` seconds of player time — multiple cycles per
    ///    call when the loop is short (design §8.3).
    ///  · EAGER +2 (m14-a MEASURED amendment to §4-A's "eagerly, one cycle
    ///    ahead"): ≥ 2 cycles queued beyond the SOUNDING cycle at all times.
    ///    Two offline-measured AVAudioPlayerNode facts force this
    ///    (LoopPrimitiveProbe, 2026-07-12, macOS 26):
    ///      1. a player inside the strip sandwich whose queue fully DRAINS
    ///         (cycle content ends before the loop boundary) freezes — items
    ///         queued after the drain NEVER sound, at any anchor lead (P6
    ///         mid-flight: silent; P6 up-front: exact). Keeping cycle k+1
    ///         queued before cycle k begins means a queue with future
    ///         content is never empty.
    ///      2. mid-flight enqueue needs ≥ ~2.5k frames of anchor lead for a
    ///         bit-exact splice (P3: whole item lost at ≤ 2048, clean at
    ///         ≥ 2496). The +2 rule queues each cycle ≥ one full cycle ahead;
    ///         the coverage law dominates for short cycles — combined, every
    ///         enqueue lands ≥ horizon − tick ahead of its anchor.
    func topUpLoopCycles(elapsedPlayerSeconds: Double, horizonSeconds: Double) {
        guard let state = loopUnroll else { return }
        let soundingCycle = elapsedPlayerSeconds < state.headSeconds
            ? 0
            : 1 + Int(((elapsedPlayerSeconds - state.headSeconds) / state.cycleSeconds)
                .rounded(.down))
        var target = soundingCycle + 2
        // Cycles needed so coverage (head + k·cycle) reaches elapsed + horizon.
        let coverage = elapsedPlayerSeconds + horizonSeconds
        if state.headSeconds + Double(target) * state.cycleSeconds < coverage {
            target = Int(((coverage - state.headSeconds) / state.cycleSeconds)
                .rounded(.up))
        }
        var through = state.scheduledThroughCycle
        while through < target {
            through += 1
            enqueueLoopCycle(through, state: state)
        }
        // §8.6 containment (m14-d L-4, the suffix-identity law): once the
        // retained history spans ≥ threshold cycles below the containment
        // bound, drop staged MIDI events strictly below the bound's absolute-
        // integral frame and rebuild automation from the bound cycle. The
        // bound is `soundingCycle − 1` — one full cycle of margin below the
        // render-clock snapshot that lower-bounds the delivered watermark, so
        // nothing pending (straddling offs included; pruning is time-based,
        // not provenance-based) is ever removed. The pruned arrays ride the
        // SAME republish as the extension below: same timelineID, no flush —
        // the render side's value-based re-seek lands on its own watermark
        // and never notices. Audio player queues need no containment: queued
        // segments are consumed as they play.
        var prunedBelow = state.prunedBelowCycle
        let pruneBound = soundingCycle - 1
        if pruneBound - prunedBelow >= Self.loopPruneThresholdCycles {
            pruneLoopMIDIHistory(belowCycle: pruneBound, state: state)
            prunedBelow = pruneBound
        }
        guard through != state.scheduledThroughCycle
            || prunedBelow != state.prunedBelowCycle else { return }
        loopUnroll?.scheduledThroughCycle = through
        loopUnroll?.prunedBelowCycle = prunedBelow
        // m14-b L-2: the non-audio side unrolls the SAME cycles on the same
        // cadence — append-only blocks against the roll's one anchor,
        // republished in place. No flush, no re-anchor, no per-wrap restart:
        // instrument voices and automation values persist through the seam
        // (design §5); the old `wrapNonAudioSchedules` interim is gone.
        extendLoopMIDI(fromCycle: state.scheduledThroughCycle + 1, throughCycle: through)
        extendLoopAutomation()
    }

    /// §8.6 containment, MIDI side (m14-d L-4): removes every staged event
    /// with `sampleTime <` cycle `pruneBound`'s start frame — the absolute
    /// integral `headSeconds + (pruneBound − 1) · cycleSeconds` at each
    /// track's schedule rate (the one-rounding discipline). Time-based, so a
    /// straddling note-off from an older cycle that lands at/after the bound
    /// survives; everything removed is ≥ one full cycle below the delivered
    /// watermark (delivered by definition). `midiNoteIDBase` is deliberately
    /// untouched — noteIDs stay schedule-wide unique forever (the C2 ledger
    /// keys). Control thread only; the render side sees the result via the
    /// caller's normal same-timeline republish.
    private func pruneLoopMIDIHistory(belowCycle pruneBound: Int, state: LoopUnrollState) {
        guard pruneBound >= 1 else { return }
        let boundSeconds = state.headSeconds + Double(pruneBound - 1) * state.cycleSeconds
        for node in instrumentNodes.values {
            let bound = Int64((boundSeconds * node.renderer.sampleRate).rounded())
            let keepFrom = node.pendingEvents.firstIndex { $0.sampleTime >= bound }
                ?? node.pendingEvents.count
            if keepFrom > 0 {
                node.pendingEvents.removeFirst(keepFrom)
            }
        }
    }

    /// Queues cycle `cycle` (≥ 1) of every clip plan on its existing player.
    /// THE ANCHOR LAW (design §8.2, C3): the cycle start is the absolute
    /// integral `headSeconds + (cycle − 1) · cycleSeconds` — computed fresh
    /// from the state constants every time, never accumulated from a previous
    /// anchor, so rounding cannot drift across cycles.
    private func enqueueLoopCycle(_ cycle: Int, state: LoopUnrollState) {
        let cycleStartSec = state.headSeconds + Double(cycle - 1) * state.cycleSeconds
        for plan in state.clipPlans {
            // R1 anti-freeze tripwire (m19-f design §2.4-6, the §1.3
            // invariant): once the roll has STARTED (`midiRollContext`
            // non-nil — set by `startAllPlayers`, cleared by
            // `stopAllPlayers`), every plan node must already carry a
            // schedule — its flag was raised by the pre-start
            // `topUpLoopCycles(elapsed: 0)` at the latest, so the player
            // was started. A mid-roll enqueue onto a flag-false node means
            // the player was skipped at start and the content would NEVER
            // sound (LoopPrimitiveProbe fact 1: a drained/never-started
            // player ignores later enqueues at any anchor lead). Pre-start
            // calls are exempt: the initial top-up is legitimately the
            // FIRST enqueue for a behind-the-playhead clip inside the loop
            // window (design §2.1 case row 3).
            assert(plan.node.hasPendingSchedule || midiRollContext == nil,
                   "loop cycle enqueue onto a never-scheduled player mid-roll — "
                   + "it would never sound (LoopPrimitiveProbe fact 1)")
            let whenSample = AVAudioFramePosition(
                ((cycleStartSec + plan.anchorOffsetSeconds) * plan.fileRate).rounded())
            // First piece carries the explicit anchor; the rest queue
            // contiguous — the linear piece-chain convention verbatim.
            var anchor: AVAudioTime? = AVAudioTime(sampleTime: whenSample, atRate: plan.fileRate)
            for item in plan.items {
                let at = anchor
                anchor = nil
                switch item {
                case .buffer(let buffer):
                    plan.node.enqueueBuffer(buffer, at: at)
                case .segment(let startingFrame, let frameCount):
                    plan.node.enqueueSegment(startingFrame: startingFrame,
                                             frameCount: frameCount, at: at)
                }
            }
        }
    }

    /// Appends cycles [fromCycle, throughCycle] to every instrument track's
    /// staged event array — per-cycle `buildEvents` from the loop start with
    /// SECOND-DOMAIN offsets (design §4-A "MIDI"), merged in canonical order
    /// (straddling note-offs from earlier cycles interleave with the new
    /// cycle's ons; the merge keeps the delivered prefix untouched) — and,
    /// once the roll has started, republishes each schedule against the SAME
    /// anchor and timelineID with only the generation bumped. The render side
    /// re-seeks to its delivered watermark: no flush, no all-notes-off —
    /// voices persist across the wrap and offs straddling a seam fire at
    /// their natural times (design §5, §9-C2). This replaced the m14-a
    /// `wrapNonAudioSchedules` per-wrap flush+rebuild interim.
    ///
    /// Before `startAllPlayers` (the start-time coverage top-up) only the
    /// staged `pendingEvents` grow — the initial publish then carries the
    /// already-unrolled array.
    ///
    /// `fromCycle > throughCycle` is legal (m14-d L-4): a containment-only
    /// tick (§8.6 — history pruned, no new cycles due) appends nothing but
    /// still republishes, so the render side adopts the pruned array.
    private func extendLoopMIDI(fromCycle: Int, throughCycle: Int) {
        guard let state = loopUnroll else { return }
        for (trackID, node) in instrumentNodes {
            // m16-b2 (C5): the base is the build-returned counter staged by
            // `scheduleAll` and advanced by each block below — never derived
            // from event counts (mixed kinds broke the old `/ 2` pair
            // assumption). The fallback — a node with no staged base, which
            // scheduleAll makes unreachable under a loop — is max-ID + 1:
            // honest even after §8.6 pruning removed early (low-ID) events.
            var base = state.midiNoteIDBase[trackID]
                ?? ((node.pendingEvents.lazy.map(\.noteID).max().map { $0 + 1 }) ?? 0)
            for cycle in stride(from: fromCycle, through: throughCycle, by: 1) {
                // THE ANCHOR LAW (design §8.2, C3): every cycle offset is the
                // absolute integral from the state constants — never
                // `previous + cycleFrames`.
                let cycleStartSec = state.headSeconds
                    + Double(cycle - 1) * state.cycleSeconds
                let block = MIDIEventSchedule.buildEvents(
                    clips: node.clips, fromBeat: state.loop.startBeat,
                    tempoMap: state.tempoMap,
                    sampleRate: node.renderer.sampleRate,
                    onsetEndBeat: state.loop.endBeat,
                    offsetSeconds: cycleStartSec,
                    noteIDBase: base
                )
                base = block.nextNoteID
                node.pendingEvents = MIDIEventSchedule.mergeSorted(node.pendingEvents,
                                                                   block.events)
            }
            loopUnroll?.midiNoteIDBase[trackID] = base
            if let roll = midiRollContext {
                scheduleGeneration += 1
                node.renderer.publish(MIDIEventSchedule(
                    generation: scheduleGeneration,
                    mode: roll.mode,
                    sampleRate: node.renderer.sampleRate,
                    events: node.pendingEvents,
                    timelineID: roll.timelineID
                ))
            }
        }
    }

    /// Republishes every strip with active lanes as the loop-unrolled build
    /// through the (just advanced) `scheduledThroughCycle` — deterministic
    /// blocks appended to the same timeline, so the renderer re-seeks its
    /// cursors and keeps its latched epoch. No-op before the roll starts
    /// (`startAllPlayers` publishes the initial unrolled schedules itself)
    /// and for strips with nothing automated.
    private func extendLoopAutomation() {
        guard automationRollContext != nil else { return }
        for trackID in trackIDs {
            guard let lanes = activeAutomationLanes[trackID],
                  lanes.volume != nil || lanes.pan != nil || !lanes.effectParams.isEmpty
            else { continue }
            publishAutomation(for: trackID, volume: lanes.volume, pan: lanes.pan,
                              effectParams: lanes.effectParams)
        }
        // The master lane extends with the strips (m15-c): same unrolled
        // blocks, same timeline, so its values stay correct across every
        // pre-queued cycle.
        if let lane = masterAutomation.activeLane(for: .volume) {
            publishMasterAutomation(lane)
        }
    }

    /// Schedules one ENVELOPED clip as the alternating baked/streamed pieces
    /// of `ClipFadeBake.envelopedPiecePlan` (m13-h2). Discipline mirrors the
    /// fade three-piece path exactly: ALL buffers bake FIRST (a read failure
    /// falls back to the single plain segment without desyncing piece times —
    /// timing always wins over shape), then the pieces queue in order on the
    /// clip's player, the FIRST carrying the explicit anchor and the rest
    /// `at: nil`, queue-contiguous.
    private func scheduleEnvelopedPieces(
        clip: ClipNode, tempoMap: TempoMap,
        fileOffsetFrames: AVAudioFramePosition,
        segmentStart: Int64, frameCount: Int64, at when: AVAudioTime
    ) {
        let fileRate = clip.file.processingFormat.sampleRate
        let pieces = ClipFadeBake.envelopedPiecePlan(
            clip: clip.clip, tempoMap: tempoMap, fileRate: fileRate,
            segmentStart: segmentStart, segmentFrameCount: frameCount)
        var baked: [Int: AVAudioPCMBuffer] = [:]
        do {
            let reader = try clip.bakeReader()
            for (index, piece) in pieces.enumerated() where piece.bake {
                baked[index] = try ClipFadeBake.bakePiece(
                    file: reader,
                    sourceStartFrame: fileOffsetFrames + piece.start,
                    frameCount: piece.frameCount,
                    clip: clip.clip,
                    clipRelativeStartFrame: piece.start,
                    tempoMap: tempoMap)
            }
        } catch {
            // Deliberate fallback (m13-h2 decision): the clip still SOUNDS,
            // on time, just unshaped — a bake read failure on a file the
            // player opened successfully at reconcile is a transient I/O
            // condition, so timing wins over shape. m15-e (audit F6): the
            // degradation is no longer stderr-only — the notice below is the
            // filed follow-up, surfaced on project.snapshot.
            FileHandle.standardError.write(Data(
                "PlaybackGraph: envelope bake failed for \(clip.file.url.lastPathComponent) — scheduling WITHOUT envelope or fades (timing wins): \(error)\n".utf8))
            noticeSink?(EngineNoticeEvent(
                code: "clip-envelope-skipped",
                message: "The gain envelope on '\(clip.clip.name)' couldn't be applied this pass — the clip played on time, without its envelope or fades.",
                beat: clip.key.startBeat))
            clip.enqueueSegment(
                startingFrame: fileOffsetFrames + segmentStart,
                frameCount: AVAudioFrameCount(frameCount),
                at: when)
            return
        }
        var anchor: AVAudioTime? = when
        func takeAnchor() -> AVAudioTime? {
            defer { anchor = nil }
            return anchor
        }
        for (index, piece) in pieces.enumerated() {
            if let buffer = baked[index] {
                clip.enqueueBuffer(buffer, at: takeAnchor())
            } else {
                clip.enqueueSegment(
                    startingFrame: fileOffsetFrames + piece.start,
                    frameCount: AVAudioFrameCount(piece.frameCount),
                    at: takeAnchor())
            }
        }
    }

    // MARK: - Player control

    /// True when the clip's player can legally receive `prepare`/`play`:
    /// attached to an engine AND holding a live output connection. AVFAudio
    /// raises an ObjC NSException otherwise (proven live, m16-a: "player
    /// started when in a disconnected state"), and an ObjC raise through a
    /// MainActor job frame poisons the runtime — leaked executor-tracking TLS
    /// record, then a crash at the next SE-0423 isolation check or a silent
    /// MainActor wedge (docs/research/design-m16a-canvas-crash.md). The check
    /// is origin-agnostic by design: missing media, reconcile races — m16-c
    /// owns fixing the missing-media CAUSE at open time; this guard makes
    /// play safe regardless of cause. O(clips) once per transport start —
    /// control-plane only, zero render-thread surface. NOTE (m16-h): this
    /// public check can also report a FALSE POSITIVE — a player on a deep
    /// post-start subtree passes here yet still raises (the named reconfig
    /// defect, docs/research/design-m16h-reconfig.md §3). m16-h removed the
    /// paths that create such players; the per-node barrier below catches
    /// any survivor honestly.
    private func isPlayable(_ node: ClipNode) -> Bool {
        guard let host = node.player.engine else { return false }
        return !host.outputConnectionPoints(for: node.player, outputBus: 0).isEmpty
    }

    /// One skipped clip's honesty notice (m16-a Leg 0, the m15-e ring):
    /// names the clip; when the source file is gone from disk, says so.
    /// Deliberately KEEPS the `clip-unplayable` code even in the missing-file
    /// wording — this guard fires for a clip whose node EXISTS but cannot
    /// start (cause unknown at this site); the build-time open catch and the
    /// open/recover echo own the cause-known case under `clip-file-missing`
    /// (m16-c — see the CODE DECISION comment at the reconcile open catch).
    private func postClipUnplayable(_ node: ClipNode) {
        let missing = !FileManager.default.fileExists(atPath: node.file.url.path)
        noticeSink?(EngineNoticeEvent(
            code: "clip-unplayable",
            message: missing
                ? "'\(node.clip.name)' couldn't play — its audio file is missing (moved or deleted). The rest of the project keeps playing."
                : "'\(node.clip.name)' couldn't play this pass — it wasn't connected to the audio output. The rest of the project keeps playing.",
            beat: node.key.startBeat))
    }

    /// Count of clip players the NEXT `startAllPlayers` will actually start
    /// (m19-f R2′ leg 2): nodes whose enqueue ledger is raised — post-R1
    /// that is ACTIVE players only, idle players contribute nothing.
    /// `AudioEngine.startPlayers` reads this AFTER the schedule pass (and
    /// loop top-up) to scale the shared-anchor lead so the serial
    /// `play(at:)` loop finishes before the anchor arrives — a late call
    /// starts SHIFTED-ORIGIN (probe-pinned 2026-07-16: timeline zero = the
    /// actual late start; the player-relative schedule plays late by the
    /// lateness for the rest of the roll, never retroactively re-anchored).
    var startablePlayerCount: Int {
        var count = 0
        forEachClip { if $0.hasPendingSchedule { count += 1 } }
        return count
    }

    /// Preloads render resources so `play(at:)` can honor a near-future anchor.
    /// m16-a Leg 0: the same playability guard + per-node barrier as
    /// `startAllPlayers` — `prepare(withFrameCount:)` on a detached/
    /// disconnected player raises the same NSException family. Deliberately
    /// SILENT here: the immediately following start posts the clip-unplayable
    /// notice, one per skipped clip per transport start, not two.
    func prepareAllPlayers(withFrameCount frameCount: AVAudioFrameCount) {
        forEachClip { node in
            // R1 (m19-f): a schedule-empty player will be skipped by
            // `startAllPlayers` — prepaying its decode would be pure waste.
            guard node.hasPendingSchedule else { return }
            guard isPlayable(node) else { return }
            try? withObjCExceptionBarrier("clip player prepare") {
                node.player.prepare(withFrameCount: frameCount)
            }
        }
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
        // live tails (offline parity, spec §5). The shared flush arm count
        // (m16-f): live starts double-arm — a live start begins from stopped
        // players, so both passes consume on silent (or stale pre-stop, the
        // F6 hazard) input well inside the ~60 ms anchor lead; the offline
        // start stays single-armed (manual rendering serializes control and
        // render — a second pass would wipe the FIRST legitimate quantum out
        // of the ring and break null-era byte-identity).
        armCompensationResets(passes: flushResetPasses)
        // m16-a Leg 0: never hand a detached/disconnected player to AVFAudio
        // — `playAtTime:` raises there (the proven MainActor poisoner; see
        // `isPlayable`). A skipped clip posts one honest notice; every other
        // player starts against the shared anchor exactly as before.
        //
        // The predicate alone is NOT sufficient: AVFAudio's player-start
        // bookkeeping has no public mirror — a player whose path to the
        // pre-existing active render graph crosses ≥2 nodes attached while
        // the engine was RUNNING raises "player started when in a
        // disconnected state" on every pass, permanently, while
        // `outputConnectionPoints` reports healthy edges. The mechanism was
        // NAMED by m16-h from a pure-AVFoundation standalone matrix
        // (docs/research/design-m16h-reconfig.md §3 — formerly m16-a rider
        // R3, resolved there). m16-h removed every in-tree path that births
        // a strip sandwich on a running engine (`rebuildEngine` defers its
        // start; `reconcile` announces strip birth on a running
        // once-rendered engine into a whole-engine rebuild), so the raise
        // class is extinct by construction. The per-node barrier stays as
        // origin-agnostic defense-in-depth: a failing clip converts to the
        // SAME honest notice and every other player still starts — never a
        // crash, never a silent skip.
        forEachClip { node in
            // R1 (m19-f): nothing enqueued since the last stop — nothing to
            // play. No ~6 ms `play(at:)` handshake, and NO notice: a
            // disconnected clip with an EMPTY schedule had nothing to play,
            // so the old `clip-unplayable` there was a false alarm
            // (deliberate behavior delta, design §2.4-3). The player stays
            // stopped — strictly more capable than started-empty (a stopped
            // player can always be scheduled + started fresh next roll).
            guard node.hasPendingSchedule else { return }
            guard isPlayable(node) else {
                postClipUnplayable(node)
                return
            }
            do {
                try withObjCExceptionBarrier("clip player start") {
                    node.player.play(at: anchor)
                }
            } catch {
                // Same stderr + notice pairing as the bake-failure fallback.
                FileHandle.standardError.write(Data(
                    "PlaybackGraph: play raised for \(node.file.url.lastPathComponent) — clip skipped: \(error)\n".utf8))
                postClipUnplayable(node)
            }
        }
        let mode: MIDIEventSchedule.Mode =
            anchor.map { .live(anchorHostTime: $0.hostTime) } ?? .offline
        // m14-b L-2: ONE MIDI timeline per roll, minted from the same
        // monotonic counter as the generations (collision-free by
        // construction). Loop-cycle extension republishes reuse it — the
        // render side then re-seeks instead of resetting (same anchor family).
        scheduleGeneration += 1
        midiRollContext = (timelineID: scheduleGeneration, mode: mode)
        for node in instrumentNodes.values {
            scheduleGeneration += 1
            node.renderer.publish(MIDIEventSchedule(
                generation: scheduleGeneration,
                mode: mode,
                sampleRate: node.renderer.sampleRate,
                events: node.pendingEvents,
                timelineID: midiRollContext?.timelineID
            ))
        }
        // Automation rolls against the SAME anchor (live) / first-pull epoch
        // (offline) as the MIDI schedules — one seam, offline parity free.
        automationRollContext = (
            stagedAutomationStart.fromBeat, stagedAutomationStart.tempoMap,
            anchor.map { .live(anchorHostTime: $0.hostTime) } ?? .offline
        )
        automationGeneration += 1
        automationRollTimelineID = automationGeneration
        for trackID in trackIDs {
            let lanes = activeAutomationLanes[trackID]
            publishAutomation(for: trackID, volume: lanes?.volume, pan: lanes?.pan,
                              effectParams: lanes?.effectParams ?? [])
        }
        // The MASTER lane rolls with the strips (m15-c): same context, same
        // anchor/epoch, same builder.
        publishMasterAutomation(masterAutomation.activeLane(for: .volume))
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
    /// Every stop, seek, tempo change, tracksDidChange restart, and
    /// configuration-change recovery already routes through here, so the
    /// next render quantum resets every instrument (release tails cut —
    /// v0-honest, same as players). A LOOP WRAP does NOT route through here
    /// any more (m14-a L-1): the wrap is pre-queued cycles on rolling
    /// players — the graph never stops at the seam (design §5: tails, PDC
    /// rings, and voices persist BY OMISSION). Loop-bounds edits still do
    /// (the design §4-A restart fallback).
    func stopAllPlayers() {
        loopUnroll = nil
        midiRollContext = nil
        // m22-g P2: the reference player joins every restart-class seam
        // (stop/seek/tempo/loop-bounds edits) — ledger-gated, so sessions
        // that never audition pay nothing. `AudioEngine.startPlayers`
        // re-schedules it in the same pass while monitoring is ON.
        stopReference()
        // R1 (m19-f): the skip predicate is the LEDGER FLAG, never "was
        // started" — flag false ⇒ zero enqueues since the last stop ⇒ the
        // queue is already empty AND (under R1) play was never called, so
        // `stop()` would be a ~1 ms semantic no-op. The asymmetry is
        // deliberate (design §2.3): a node whose `play(at:)` RAISED under
        // the m16-a barrier (or was isPlayable-skipped) keeps flag=true and
        // a non-empty queue — its `stop()` MUST still run to clear the
        // queue (the reschedule primitive's contract). Teardown paths
        // (reconcile remove/re-key, engine discard) stay unconditional.
        forEachClip { node in
            if node.hasPendingSchedule {
                node.player.stop()
                node.noteStopped()
            }
        }
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
        // The master read head unpublishes with the strips (m15-c); the
        // master fader's stopped-WYSIWYG preview lands on the caller's next
        // parameter pass, like every strip mixer.
        publishedMasterVolumeLane = nil
        masterAutomationRenderer?.publish(nil)
        // Every strip's chain resets on stop: offline determinism, and the
        // tail cut matches the v0-honest instrument flush contract.
        //
        // LIVE double-arm (m15-f — the m14-d edit-seam echo blip): the reset
        // store is visible to the render thread MID-quantum instantly, while
        // the player stops above land only at the next quantum boundary — so
        // one walk can consume the reset at its top (ring wiped) and then
        // process the still-in-flight pre-flush quantum INTO the clean ring;
        // its echo rings out at the delay spacing inside the seam. One reset
        // is structurally insufficient because reset consumption and stale-
        // input delivery happen in the SAME walk, in that order. The second
        // armed pass survives to the next walk — input by then is post-flush
        // silence, and the restart primitive's start lead (~60 ms) keeps any
        // legitimate content far behind it. Manual rendering stays SINGLE-
        // armed: control and render are serialized there (no in-flight
        // quantum exists), and offline content restarts on the very next
        // pull, where a second reset would cut the first legitimate
        // quantum's tail (null-era byte-identity).
        let chainResetPasses = flushResetPasses
        for node in trackNodes.values {
            node.chainState.requestResetAll(passes: chainResetPasses)
        }
        for node in instrumentNodes.values {
            node.chainState.requestResetAll(passes: chainResetPasses)
        }
        for node in busNodes.values {
            node.chainState.requestResetAll(passes: chainResetPasses)
        }
        // The master chain resets with the strips (m13-d): a master
        // reverb/delay tail cuts at stop exactly like a strip's.
        masterChainState?.requestResetAll(passes: chainResetPasses)
        // PDC rings reset alongside the chains (M4 viii-b): stop, seek, and
        // tempo changes all route through here, so no stale delayed tail from
        // the previous position ever ghosts into the next one. The spec's
        // no-flush-on-loop-wrap rule is live as of m14-a L-1: a seamless wrap
        // never calls this method, so rings persist across the seam exactly
        // as the spec anticipated; this flush now fires only for real stops,
        // seeks, and edits. The SAME arm count the chains got above (m16-f
        // symmetry, audit F6): the in-flight-quantum race is identical in
        // shape — only its blast radius differs (one PDC-late replay vs a
        // re-circulating echo).
        armCompensationResets(passes: chainResetPasses)
    }

    /// The flush-family reset arm count, computed in ONE place so chain
    /// rings and PDC compensation rings can never diverge (m15-f law,
    /// m16-f symmetry): LIVE = 2 (the double-arm that kills the in-flight
    /// stale quantum), manual rendering = 1 (control and render are
    /// serialized — no in-flight quantum exists, and a second offline pass
    /// would cut a legitimate quantum's tail and break null-era
    /// byte-identity — the load-bearing m15-f deviation).
    private var flushResetPasses: UInt32 {
        engine.isInManualRenderingMode ? 1 : 2
    }

    /// Arms every strip's compensation-ring reset countdown (track,
    /// instrument, bus) — consumed one pass per ring render quantum
    /// (m16-f). `passes` must be `flushResetPasses` (or a value derived
    /// from it) at every call site — never a divergent recompute.
    ///
    /// The master chain host carries a ring OBJECT structurally (every
    /// ChainHostAU does) but it is plan-excluded by construction (see
    /// `recomputeCompensation` — design D5): its target is never set, its
    /// ring never writes (`historyClean` never clears, `renderInert`
    /// forever), so there is nothing to arm — an arm would only memset an
    /// already-zero 32k ring on the render thread at every stop.
    private func armCompensationResets(passes: UInt32) {
        for node in trackNodes.values {
            ChainHostAU.compensationState(of: node.chainHost)?.armReset(passes: passes)
        }
        for node in busNodes.values {
            ChainHostAU.compensationState(of: node.chainHost)?.armReset(passes: passes)
        }
        for node in instrumentNodes.values {
            node.renderer.compensation.armReset(passes: passes)
        }
    }

    /// Dead code (zero callers — perf-a WATCH item stands), and since m13-a
    /// UNREACHABLE by design for once-rendered engines: teardown of a
    /// once-rendered graph is `AudioEngine.rebuildEngine` (whole-engine
    /// discard), never a surgical mass detach. Unlike `reconcile` this
    /// tears down bus-facing wiring WITHOUT announcing
    /// `willMutateRoutingTopology`; any future caller must add the announce
    /// discipline first. Detaches route through `teardownDetach` so even
    /// this path cannot detach once-rendered nodes against a stopped engine
    /// (it flags the rebuild instead).
    func detachAll() {
        for node in trackNodes.values {
            for clip in node.clips.values {
                clip.player.stop()
                teardownDetach(clip.player)
            }
            node.mixer.removeTap(onBus: 0)
            teardownDetach(node.mixer)
            teardownDetach(node.chainHost)
            teardownDetach(node.sumMixer)
            for gain in node.sendGainNodes.values {
                teardownDetach(gain)
            }
        }
        trackNodes.removeAll()
        signature.removeAll()
        for node in instrumentNodes.values {
            node.renderer.publish(nil)
            node.renderer.requestFlush()
            node.mixer.removeTap(onBus: 0)
            teardownDetach(node.source)
            teardownDetach(node.mixer)
            for gain in node.sendGainNodes.values {
                teardownDetach(gain)
            }
        }
        instrumentNodes.removeAll()
        instrumentSignature.removeAll()
        routingSignature.removeAll()
        for node in busNodes.values {
            node.mixer.removeTap(onBus: 0)
            teardownDetach(node.mixer)
            teardownDetach(node.chainHost)
            teardownDetach(node.sumMixer)
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
