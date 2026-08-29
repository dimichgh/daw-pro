import Foundation
import DAWCore
import AIServices

public struct ControlRequest: Codable, Sendable {
    public var id: String
    public var command: String
    public var params: [String: JSONValue]?

    public init(id: String, command: String, params: [String: JSONValue]? = nil) {
        self.id = id
        self.command = command
        self.params = params
    }
}

public struct ControlResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: String?

    public static func success(_ id: String, _ result: JSONValue? = nil) -> ControlResponse {
        ControlResponse(id: id, ok: true, result: result, error: nil)
    }

    public static func failure(_ id: String, _ message: String) -> ControlResponse {
        ControlResponse(id: id, ok: false, result: nil, error: message)
    }
}

/// Read-only description of the live control endpoint (beta m10-l), threaded into
/// the router at construction. The `ControlServer` OWNS the router, so the router
/// can't ask the server for its port — the app resolves the port once
/// (`ControlPortConfig` in DAWAppKit) and hands the answer in here (the value-type
/// equivalent of the `copilotEngine` weak-backref: information in, no cycle). Powers
/// `app.connectionInfo` so an agent can introspect the URL/port it reached the app
/// on and whether an operator has customized it. Endpoint description ONLY — never
/// any key material.
public struct ControlConnectionInfo: Sendable, Equatable {
    /// The live bound port (env override > in-app setting > default 17600).
    public var port: UInt16
    /// Where `port` came from: "environment" | "settings" | "default" (the
    /// `ControlPortSource` raw value).
    public var source: String
    /// The built-in default port (17600) — so a client can tell whether the
    /// endpoint has been customized.
    public var defaultPort: UInt16

    public init(port: UInt16 = 17600, source: String = "default", defaultPort: UInt16 = 17600) {
        self.port = port
        self.source = source
        self.defaultPort = defaultPort
    }

    /// The loopback WebSocket URL agents connect to.
    public var url: String { "ws://127.0.0.1:\(port)" }
}

/// Routes control-protocol commands onto ProjectStore. This is the canonical
/// command list — mcp-server/src/index.ts must expose a matching tool for every
/// entry in `allCommands` (see /mcp-verify skill).
@MainActor
public final class CommandRouter {
    private let store: ProjectStore
    /// Local ACE-Step sidecar lifecycle (M6 i) — process management only, no
    /// AI keys involved (fully local). Defaults to the real `SidecarManager`
    /// resolving `scripts/ace-step/` relative to the repo/executable (see
    /// `SidecarManager.Configuration.resolved()`); tests inject a fake
    /// conforming to `SidecarManaging` instead.
    private let sidecarManager: SidecarManaging

    /// Local RVC voice-conversion sidecar lifecycle (m10-p-3) — the
    /// `sidecarManager` twin for the SECOND local sidecar (127.0.0.1:8002,
    /// `scripts/rvc/`). Process management only — kept separate from
    /// `voiceConverting` below (convert/train calls), same split as
    /// `sidecarManager`/`songGenerator`. Defaults to the real
    /// `VoiceConversionManager` resolving `scripts/rvc/` relative to the
    /// repo/executable; tests inject a fake conforming to
    /// `VoiceConversionManaging` instead.
    private let voiceConversionManager: VoiceConversionManaging

    /// `vc.convertVocals`/`vc.trainVoice` (m10-p-4) — the RVC facade's typed
    /// convert/train calls, kept separate from `voiceConversionManager`
    /// (process lifecycle vs. conversion calls, the `songGenerator`/
    /// `sidecarManager` split precedent). Defaults to the real
    /// `VoiceConversionClient` talking to the same local sidecar; tests
    /// inject a fake conforming to `VoiceConverting` instead.
    private let voiceConverting: VoiceConverting

    /// Song generation (M6 ii) — defaults to the real `ACEStepClient` talking
    /// to the local sidecar's job-queue REST API; tests inject a fake
    /// conforming to `SongGenerating` instead. Kept separate from
    /// `sidecarManager` (different concerns: process lifecycle vs.
    /// generation jobs) even though both ultimately talk to the same
    /// sidecar process.
    private let songGenerator: SongGenerating

    /// The model-lifecycle coordinator (m23-dl): residency bookkeeping, the
    /// global single-flight, unload-before-load, and the ten-minute idle unload.
    ///
    /// ⚠️ A coordinator with **nothing registered is entirely inert** — it writes
    /// no files and books nothing — so the shared default is safe for the many
    /// tests that construct a router without a model lifecycle in mind.
    /// Registration happens once, in `DAWProApp`.
    private let modelLifecycle: ModelLifecycleCoordinator

    /// On-device speech-to-text (m23-n2b) — `clip.transcribe`'s engine,
    /// held ONE PER ROUTER (not constructed per call), exactly why
    /// `WhisperTranscriber`'s own doc comment holds one for the whole
    /// process: the first call on a machine pays a one-time ~90 s CoreML
    /// ANE compile that the OS then caches, so a fresh instance per call
    /// would pay it every time. Defaults to the real actor resolving
    /// weights through `WhisperModelCatalog.resolved()`; tests inject one
    /// pointed at a custom catalog/variant the same way `WhisperTranscriberTests`
    /// (AIServicesTests) already do.
    private let transcriber: WhisperTranscriber

    /// `ai.installSpeechModel`/`ai.speechModelInstallStatus`'s engine (m23-n3b)
    /// — held ONE PER ROUTER (the `transcriber` precedent, immediately above),
    /// so every poll of `ai.speechModelInstallStatus` sees the SAME in-flight
    /// state a prior `ai.installSpeechModel` call started, rather than a fresh
    /// coordinator with no memory of it. `WhisperModelInstaller` (m23-n3a) is
    /// a plain unisolated struct; this actor is what makes "start, then poll"
    /// safe against two overlapping installs (see its own doc). Defaults to
    /// the real installer via `WhisperModelInstallCoordinator.liveInstallFunction`;
    /// tests inject one constructed with a fake `InstallFunction`.
    private let installCoordinator: WhisperModelInstallCoordinator

    /// `fx.spectrum`'s control-plane TTL lease (m23-r4, design D2) — held
    /// ONE PER ROUTER (the `transcriber`/`installCoordinator` precedent,
    /// immediately above), so "arm, then poll" sees the same lease state.
    /// Defaults to the real injectable-but-production continuous clock;
    /// tests construct their own `InsertSpectrumLeases(now:)` with a fake
    /// clock and inject it here.
    private let insertSpectrumLeases: InsertSpectrumLeases

    /// Read-only API-key store for `ai.providerStatus` (M6). Defaults to the
    /// real Keychain; tests inject an in-memory store. This is STATUS-ONLY —
    /// there is deliberately NO command to SET a key (see `ai.providerStatus`):
    /// key values would otherwise transit the agent-logged control plane, which
    /// the house directive forbids. Keys enter the app only via env vars or the
    /// Settings UI → Keychain.
    private let keyStore: APIKeyStoring
    /// The environment consulted for env-provided keys when reporting status
    /// (env wins over Keychain). Injectable for tests/captures.
    private let keyEnvironment: [String: String]

    /// Read-only description of the live control endpoint (beta m10-l), for
    /// `app.connectionInfo`. Threaded in at construction because the server owns
    /// the router (see `ControlConnectionInfo`); defaults to the built-in
    /// default-port description so a bare/headless router still answers honestly.
    private let connectionInfo: ControlConnectionInfo

    /// Yields a configured lyrics writer for `ai.writeLyrics`, or THROWS the
    /// actionable no-provider error. Defaults to `resolveLyricsWriter` over the
    /// SAME key chain `ai.providerStatus` reports (Anthropic preferred, OpenAI
    /// fallback); tests inject a fake writer instead. Resolved per call so a key
    /// added mid-session takes effect without a restart. Never logs key material.
    private let lyricsWriterProvider: @MainActor () throws -> any LyricsGenerating

    /// `vc.importVoiceModel` (m23-di-2a) — the RVC voice store's target
    /// directory. Pure filesystem copy, no HTTP/sidecar dependency, so unlike
    /// `voiceConverting` above this needs no protocol seam — just an
    /// injectable destination (the `store.generationImportsDirectory`
    /// precedent: `ProjectStore+Generation.swift`). Defaults to
    /// `VoiceModelImport.voicesDirectory` (the SAME path
    /// `VoiceConversionManager.spawnAndPoll` hands the sidecar as
    /// `RVC_VOICES_DIR`); tests inject a scratch temp directory instead so a
    /// test run never writes into the real Application Support tree.
    private let voiceModelImportDirectory: URL

    /// App-layer command extension hook. DAWApp installs this to serve `debug.*`
    /// commands (e.g. `debug.captureUI`) that render the live SwiftUI hierarchy —
    /// inherently main-actor, UI-runtime work with no headless equivalent.
    /// Consulted by `route(_:)` in its default case BEFORE the unknown-command
    /// error: a non-nil return wraps as success; nil falls through to the error.
    ///
    /// `@MainActor` on the closure type is load-bearing: the handler touches the
    /// view hierarchy and must run on the main actor. `debug.*` is deliberately
    /// EXCLUDED from `allCommands` / MCP parity — it's a developer/verification
    /// surface, not an agent-facing capability, so it stays out of the canonical
    /// list by convention.
    public var appCommandHandler: (
        @MainActor (_ command: String, _ params: [String: JSONValue]) throws -> JSONValue?
    )?

    /// The in-app AI Copilot (M6 rail-c) — weak because the app retains the
    /// engine and hands the router only a dispatch closure (`{ await
    /// router.handle($0) }`), the SAME two-phase, no-retain-cycle pattern as
    /// `appCommandHandler`. `ai.copilot*` commands route through this and
    /// throw an actionable "not wired" error when nil (app startup
    /// incomplete — every other command path is unaffected).
    public weak var copilotEngine: CopilotEngine?

    /// Plugin-UI-window seam (M3 vi-b) — the typed, async app-layer surface the
    /// `plugin.*` commands route through, installed by DAWApp
    /// (`PluginWindowManager`). Weak: AppModel owns the manager (the
    /// `copilotEngine` precedent). Nil in a headless control session — open/close
    /// then fail with a readable error, `listOpenUIs` answers `{available:false}`.
    public weak var pluginUI: (any PluginUIControlling)?

    /// Arrange-clip-paste seam (m26-k) — the typed, sync app-layer surface
    /// `edit.pasteClips` routes through, installed by DAWApp (`AppModel`
    /// itself; see `EditPasteSurface.swift`). Weak: `AppModel` is retained by
    /// `DAWProApp`'s own `@State`, the same non-retaining-router precedent as
    /// `pluginUI`/`copilotEngine`. Nil in a headless control session — the
    /// route then fails with a readable error rather than crashing.
    public weak var editPaste: (any EditPasteControlling)?

    public static let allCommands: [String] = [
        "transport.play",
        "transport.stop",
        "transport.seek",
        "transport.setTempo",
        "transport.setLoop",
        "transport.setPunch",
        "transport.setMetronome",
        "tempo.map",
        "tempo.setMap",
        "marker.add",
        "marker.remove",
        "marker.rename",
        "marker.move",
        "marker.list",
        "track.add",
        "track.remove",
        "track.rename",
        "track.setVolume",
        "track.setPan",
        "track.setMute",
        "track.setSolo",
        "track.setOutput",
        "track.addSend",
        "track.setSend",
        "track.removeSend",
        "track.setInstrument",
        "track.bounceInPlace",
        "fx.add",
        "fx.remove",
        "fx.reorder",
        "fx.setBypass",
        "fx.setParam",
        "fx.setSidechain",
        "fx.describe",
        "fx.listAudioUnits",
        "instrument.listAudioUnits",
        "instrument.listSoundBanks",
        "instrument.listSoundBankPrograms",
        "instrument.importSoundBank",
        "instrument.importSampleLibrary",
        "instrument.describeSampler",
        "instrument.probeLiveness",
        "mixer.setMasterVolume",
        "mixer.applyPreset",
        "mixer.masterAnalysis",
        "engine.performanceStats",
        "engine.watchdogStatus",
        "engine.auPrepareStats",
        "macro.songSkeleton",
        "automation.addLane",
        "automation.removeLane",
        "automation.setPoints",
        "automation.setLaneEnabled",
        "clip.addAudio",
        "clip.addMIDI",
        "clip.setNotes",
        "clip.getNotes",
        "clip.remove",
        "clip.split",
        "clip.trim",
        "clip.move",
        "clip.duplicate",
        "clip.setGain",
        "clip.setGainEnvelope",
        "clip.setControllerLane",
        "clip.removeControllerLane",
        // m27 leg D: generate a realistic breath contour over a MIDI clip's
        // notes — the correlated expression swell plus delayed vibrato and
        // micro-sharpening that legs A and C made audible. The authoring
        // primitive ABOVE the two verbs directly here; they stay the raw
        // wholesale-replace / delete pair. NOTE: no quoted string in this
        // comment, deliberately (the m25-d rule).
        //
        // ⚠️ Placed HERE, next to its siblings, and NOT at the tail — the
        // clip.getNotes / instrument.describeSampler precedent, which
        // `FXSpectrumCommandTests.registeredAtEndOfAllCommands` records
        // explicitly ("landed elsewhere in the array, next to their siblings,
        // not at the tail — this chain is unaffected by either"). The
        // additive-at-end law exists so the tail-chain pins stay meaningful;
        // an insertion 117 elements from the end leaves every end-relative
        // assertion in the tree (46 `dropLast` sites across 8 files, plus
        // three `suffix(19)`/`suffix(21)` windows) true by construction, so
        // only the explicit count pins move. ⚠️ THAT PIN COUNT HAS BEEN WRONG
        // IN THIS COMMENT AND IN ARCHITECTURE.md: both said "16" (and
        // ARCHITECTURE.md said "across 15 files"). MEASURED 2026-08-19 at the
        // breath-pad P1 close: **19 lines across 18 files**, because three
        // spell it `all.count == N` rather than `allCommands.count == N`.
        // GREP THE LITERAL VALUE, NOT THE IDIOM — a brief built on "16" sent
        // an agent looking for three sites. (A bare `.count ==` sweep returns
        // 21/20: two are unrelated local arrays in AuditionRenderTests and
        // LiveThruRenderTests. 19 is the number that moves.)
        // Verified before moving it:
        // there is not one absolute `allCommands[i]` index anywhere in
        // Tests/ or Sources/ (0 hits, positive-controlled against the 46
        // dropLast hits with the same command shape).
        "clip.applyBreathContour",
        // Breath pad P1: pick one NAMED effort shape (messa di voce, a hairpin,
        // sforzando-piano...) and apply it through the verb above. Placed HERE,
        // immediately after the sibling whose machinery it reuses, for exactly
        // the reason recorded on that line — an insertion this far from the end
        // leaves every end-relative assertion in the tree true by construction,
        // so only the explicit count pins move. NOTE: no quoted string in this
        // comment, deliberately (the m25-d rule).
        "clip.applyEffortShape",
        "clip.setFades",
        "clip.crossfade",
        "clip.setStretch",
        "clip.stretchToLength",
        "clip.deleteTimeRange",
        "clip.insertTimeRange",
        "clip.quantize",
        "clip.humanize",
        "clip.detectTransients",
        "clip.quantizeAudio",
        "arrange.insertBars",
        "arrange.deleteBars",
        "take.group",
        "take.setComp",
        "take.select",
        "take.removeLane",
        "take.flatten",
        "take.move",
        "take.setCrossfade",
        "take.autoAlign",
        "groove.extract",
        "groove.list",
        "groove.remove",
        "render.mixdown",
        "render.measureLoudness",
        "render.bounce",
        "render.stems",
        "ai.sidecarStatus",
        "ai.sidecarStart",
        "ai.sidecarStop",
        "ai.generateSong",
        "ai.generationStatus",
        "ai.importGeneration",
        "ai.extractStems",
        "ai.legoGenerate",
        "ai.importGeneratedStems",
        "ai.repaintAudio",
        "ai.fixClipRegion",
        "ai.importClipFix",
        "ai.providerStatus",
        "ai.writeLyrics",
        "project.snapshot",
        "project.overview",
        "input.listDevices",
        "input.setDevice",
        // m20-j: registered HERE, next to the input pair and BEFORE
        // transport.record, on purpose — the all-commands routing loop in
        // ControlTests walks this array IN ORDER and is mid-take by the time
        // it reaches the verbs below, and output.setDevice is refused while
        // recording (bouncing the output engine would strand a rolling take).
        "output.listDevices",
        "output.setDevice",
        "midi.listInputs",
        // m28-knob: the CC→target mapping trio, registered HERE next to
        // midi.listInputs (their only sibling on this surface) and BEFORE
        // transport.record — the ControlTests routing loop walks this array in
        // order and is mid-take from transport.record onwards. NOT at the tail.
        "midi.getControlMap",
        "midi.setControlMap",
        "midi.learnControl",
        "transport.record",
        "track.setArm",
        "project.save",
        "project.open",
        "project.new",
        "project.recoveryStatus",
        "project.recoveryBundles",
        "project.recover",
        "edit.undo",
        "edit.redo",
        "edit.history",
        "ai.copilotSend",
        "ai.copilotState",
        "ai.copilotReset",
        "ai.copilotGetModel",
        "ai.copilotSetModel",
        "ai.copilotChats",
        "ai.copilotResumeChat",
        "ai.copilotDeleteChat",
        "ai.copilotRenameChat",
        "app.feedbackBundle",
        "app.connectionInfo",
        "plugin.openUI",
        "plugin.closeUI",
        "plugin.listOpenUIs",
        "vc.sidecarStatus",
        "vc.sidecarStart",
        "vc.sidecarStop",
        "vc.convertVocals",
        "vc.trainVoice",
        "vc.listVoices",
        "au.describeParams",
        "au.setParam",
        "clip.fitToContent",
        "clip.analyzeAudio",
        "mixer.liveLoudness",
        "reference.import",
        "reference.remove",
        "reference.status",
        "reference.analyze",
        "reference.setMonitor",
        "reference.setOffset",
        "reference.setTrim",
        "reference.compare",
        // m23-d: note audition — sound notes NOW on an instrument track,
        // outside the timeline. Additive at the END (the additive-at-end law).
        "note.audition",
        // Breath pad P6: the live drag preview — stream ONE controller value to
        // an instrument track while a pad gesture is in progress. Placed HERE,
        // immediately after the verb whose machinery and whose contract it
        // shares (both "sound something NOW, outside the timeline, not an
        // edit", both ride the same per-renderer audition ring, and neither is
        // ever the record), for the reason recorded on the
        // clip.applyBreathContour line ~120 entries below: an insertion this
        // far from the END leaves every end-relative assertion in the tree
        // (46 dropLast sites across 8 files, plus the suffix windows) true by
        // construction, so only the explicit count pins move. A TAIL APPEND
        // BROKE 80 ASSERTIONS ACROSS 22 TESTS AT m27 LEG D and every FILTERED
        // run stayed green. ⚠️ Those pins are 19 LINES ACROSS 18 FILES — grep
        // the LITERAL count, not the idiom, since three spell it
        // `all.count == N`. NOTE: no quoted string in this comment,
        // deliberately (the m25-d rule).
        "pad.previewEffort",
        // m23-h: the ONE track-ordering verb (arrange headers drag onto it;
        // the mixer follows in m23-z). Additive at the END (the same law).
        "track.reorder",
        // m23-k3: Standard MIDI File import. Both APPENDED AT THE END (the
        // additive-at-end law) — no live command renamed or reordered.
        "project.importMIDI",
        "clip.importMIDI",
        // m23-k4a: Standard MIDI File export. Both APPENDED AT THE END (the
        // additive-at-end law) — no live command renamed or reordered, so
        // HEAD's list stays an exact PREFIX of this one.
        "project.exportMIDI",
        "track.exportMIDI",
        // m23-n2b: exposes the m23-n2a WhisperTranscriber engine — on-device
        // speech-to-text with word/segment timings mapped onto the clip's
        // project beats. APPENDED AT THE END (the additive-at-end law).
        "clip.transcribe",
        // m23-n3b: exposes the m23-n3a WhisperModelInstaller through the new
        // WhisperModelInstallCoordinator — start (returns immediately) +
        // poll, the stretch-render precedent for a locally-owned long job.
        // Both APPENDED AT THE END (the additive-at-end law).
        "ai.installSpeechModel",
        "ai.speechModelInstallStatus",
        // m23-r4: fx.spectrum — a control-plane TTL-leased read of the
        // per-insert spectrum tap r1-r3 built (named-owner arm sharing with
        // the UI's own EQ-card arm, so wire polling and an open card never
        // stomp each other). APPENDED AT THE END (the additive-at-end law).
        "fx.spectrum",
        // m23-o1: frequency.reference — the instrument frequency reference
        // table (design-m23o1-instrument-frequency-reference.md §6): family
        // fundamentals, cited presence/problem bands, and an HP/LP
        // recommendation the copilot can hand straight to fx.setParam.
        // APPENDED AT THE END (the additive-at-end law).
        "frequency.reference",
        // m23-w: clip.removeMany / clip.moveMany — the wire half of m23-g1's
        // group delete and m23-g2's group drag, both of which shipped their
        // store side (ProjectStore.removeClips(ids:)/moveClips(ids:byBeats:))
        // under a zero-wire-growth preference. STRICTLY ADDITIVE — clip.remove
        // / clip.move are unchanged. APPENDED AT THE END (the additive-at-end
        // law).
        "clip.removeMany",
        "clip.moveMany",
        // m23-af PANIC. Appended at the end per the additive-at-end law; the
        // `transport.` prefix is where a user looks for a transport-bar
        // control, NOT a claim that this touches the transport (it must not —
        // see the verb's case below).
        "transport.panic",
        // m23-aj-2: the WIRE half of m23-aj-1's cross-track group move
        // (ProjectStore.moveClips(ids:byTracks:byBeats:) /
        // moveClips(ids:toTrackId:byBeats:)) — the vertical twins of
        // clip.moveMany above. Two commands, not one either/or param (design
        // §1.2: neither wire schema surface can express "exactly one of
        // byTracks/toTrackId"). STRICTLY ADDITIVE. Appended at the end per
        // the additive-at-end law.
        "clip.moveManyByTracks",
        "clip.moveManyToTrack",
        // m23-dl model lifecycle. STRICTLY ADDITIVE, appended at the end per the
        // additive-at-end law. NOTE what is deliberately NOT here: no `force` on
        // `ai.sidecarStart`/`vc.sidecarStart`, because the memory admission gate
        // those would have overridden was cut by the user on 2026-08-05. Adding
        // `force` to a start verb later would also collide with
        // `WireHardeningM16ETests`, which uses `force` as its stray-param probe
        // against `ai.sidecarStop`.
        "ai.modelResidency",
        "ai.modelUnload",
        // m23-di-2a: third-party RVC voice-model IMPORT — a local filesystem
        // copy into the app-owned voice store (VoiceModelImport.swift), no
        // sidecar HTTP call. STRICTLY ADDITIVE, appended at the end per the
        // additive-at-end law.
        "vc.importVoiceModel",
        // m25-d: the end-of-content stop preference — stop the transport when
        // the playhead reaches the point past which there are no more clips.
        // A SESSION preference (ON by default), never project data, so it is a
        // verb of its own rather than a field on transport.setLoop/setPunch.
        // NOTE: no quoted string in this comment, deliberately — the array body
        // already costs the naive quoted-string count one false positive
        // (docs/ARCHITECTURE.md), and a second would compound the trap.
        // STRICTLY ADDITIVE, appended at the end per the additive-at-end law.
        "transport.setStopAtContentEnd",
        // m25-z: windowed peak/RMS file profile — what is the peak level
        // between 53s and 54s of a WAV, a WINDOWING question, deliberately
        // NOT a second copy of the BS.1770 loudness path (render.measureLoudness/
        // reference.analyze already own program loudness; m23-ch keeps the
        // ebur128 cross-check external on purpose). Read-only: never touches the
        // project reference slot or the References library.
        // NOTE: no quoted string in this comment, deliberately (the m25-d rule).
        // STRICTLY ADDITIVE, appended at the end per the additive-at-end law.
        "audio.profileFile",
        // m23-ap-3: per-frame pitch detection over an audio clip's current
        // source window, wiring m23-ap-2b's PitchTracker/SwiftF0PitchTracker
        // seam onto the wire for the first time. Read-only; NOT result-cached
        // (see ClipPitchAnalyzer's header for why).
        // NOTE: no quoted string in this comment, deliberately (the m25-d rule).
        // STRICTLY ADDITIVE, appended at the end per the additive-at-end law.
        "clip.detectPitch",
        // m26-k: the wire route the menu paste (Cmd-V) and debug.editClipboard
        // already exercise in-app — a headless control session and every MCP
        // agent had no way to reach it at all until now. Rides the SAME
        // targeting logic verbatim (no new behaviour), through a typed seam
        // (EditPasteSurface.swift), the plugin.* precedent. NOTE: no quoted
        // string in this comment, deliberately (the m25-d rule). STRICTLY
        // ADDITIVE, appended at the end per the additive-at-end law.
        "edit.pasteClips",
    ]

    public init(
        store: ProjectStore,
        sidecarManager: SidecarManaging = SidecarManager(),
        voiceConversionManager: VoiceConversionManaging = VoiceConversionManager(),
        voiceConverting: VoiceConverting = VoiceConversionClient(),
        songGenerator: SongGenerating = ACEStepClient(),
        transcriber: WhisperTranscriber = WhisperTranscriber(),
        installCoordinator: WhisperModelInstallCoordinator = WhisperModelInstallCoordinator(),
        insertSpectrumLeases: InsertSpectrumLeases = InsertSpectrumLeases(),
        keyStore: APIKeyStoring = KeychainKeyStore(),
        keyEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        connectionInfo: ControlConnectionInfo = ControlConnectionInfo(),
        lyricsWriter: (@MainActor () throws -> any LyricsGenerating)? = nil,
        importGenerator: SongGenerating? = nil,
        modelLifecycle: ModelLifecycleCoordinator = .shared,
        voiceModelImportDirectory: URL = VoiceModelImport.voicesDirectory
    ) {
        self.store = store
        self.sidecarManager = sidecarManager
        self.voiceConversionManager = voiceConversionManager
        self.voiceConverting = voiceConverting
        self.songGenerator = songGenerator
        self.transcriber = transcriber
        self.installCoordinator = installCoordinator
        self.insertSpectrumLeases = insertSpectrumLeases
        self.keyStore = keyStore
        self.keyEnvironment = keyEnvironment
        self.connectionInfo = connectionInfo
        self.modelLifecycle = modelLifecycle
        self.voiceModelImportDirectory = voiceModelImportDirectory
        // Default: resolve a writer from the shared key chain on each call.
        // `ai.writeLyrics` uses the APP's keys + live project context — the MCP
        // server's own legacy `generate_lyrics` calls a provider directly with its
        // OWN process env instead.
        self.lyricsWriterProvider = lyricsWriter ?? {
            try resolveLyricsWriter(environment: keyEnvironment, store: keyStore)
        }
        // Wire the store's generation-import seam over the SAME song generator
        // (M6 iii-a) so `ai.importGeneration` reaches finished audio + metas by
        // jobId. One source of truth: tests injecting a fake generator get the
        // adapter for free; the app wires the real ACEStepClient once.
        // `importGenerator` (m17-h, optional) lets the app hand the seam its
        // OWN origin-tagged observing wrapper around that same client — so an
        // import-path job lands on the unified progress card tagged "import"
        // instead of "wire". nil (every test / headless construction) keeps
        // the pre-m17-h behavior byte-identical.
        store.generationSource = SongGenerationImportSource(
            generator: importGenerator ?? songGenerator)
    }

    /// Async because `render.mixdown` awaits offline Audio Unit preparation;
    /// every other command completes synchronously on the main actor.
    public func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            return try await route(request)
        } catch let error as ControlError {
            return .failure(request.id, error.message)
        } catch let error as LocalizedError where error.errorDescription != nil {
            // ProjectError and friends carry a client-readable message — surface
            // that, not the Swift value dump.
            return .failure(request.id, error.errorDescription!)
        } catch {
            return .failure(request.id, "internal error: \(error)")
        }
    }

    private func route(_ request: ControlRequest) async throws -> ControlResponse {
        let params = request.params ?? [:]
        switch request.command {
        case "transport.play":
            // No params (m16-e, audit F5 survey: closes the zero-param gap).
            try params.rejectUnknownKeys([], verb: "transport.play")
            store.play()
            return .success(request.id)

        case "transport.stop":
            // No params (m16-e, audit F5 survey).
            try params.rejectUnknownKeys([], verb: "transport.stop")
            store.stop()
            return .success(request.id)

        case "transport.panic":
            // PANIC / all-notes-off (m23-af). No params, like transport.stop.
            //
            // ⚠️ THIS MUST NOT CALL `store.stop()`, now or in any future
            // "simplification". `stop()` early-returns unless the transport is
            // playing or recording, so routing panic through it would make the
            // verb a no-op in the ONE situation it exists for: a note left
            // stuck by a lost note-off while the transport sits idle. Pinned by
            // a test that panics while stopped and by one that asserts the
            // transport is still playing afterwards.
            try params.rejectUnknownKeys([], verb: "transport.panic")
            let flushed = store.panic()
            return .success(request.id, .object(["tracksFlushed": .number(Double(flushed))]))

        case "transport.seek":
            // Two ways to name the destination (m11-c): the absolute `beats`
            // (original behavior, unchanged) OR a `marker` — a marker id OR its
            // exact name — that resolves to that marker's beat. PRECEDENCE: passing
            // BOTH is rejected (ambiguous intent), so a caller states one clearly;
            // an unknown/ambiguous marker is a field-named error. `beats` stays
            // required whenever `marker` is absent.
            try params.rejectUnknownKeys(
                ["beats", "marker"], verb: "transport.seek")
            if let marker = params["marker"]?.stringValue {
                if params["beats"] != nil {
                    throw ControlError("pass either 'beats' or 'marker', not both — they name the seek destination two different ways")
                }
                let beat = try resolveMarkerBeat(marker)
                try store.seek(toBeats: beat)
                return .success(request.id)
            }
            let beats = try params.require("beats", \.doubleValue)
            // transportBusy while recording surfaces via LocalizedError mapping.
            try store.seek(toBeats: beats)
            return .success(request.id)

        case "marker.add":
            // params: name (optional — empty/absent auto-names "Marker N"),
            // beat (required, >= 0). Returns the created marker {id,name,beat}.
            try params.rejectUnknownKeys(
                ["name", "beat"], verb: "marker.add")
            let beat = try params.require("beat", \.doubleValue)
            guard beat >= 0 else { throw ControlError("'beat' must be >= 0") }
            let name = params["name"]?.stringValue
            let marker = store.addMarker(name: name, beat: beat)
            return .success(request.id, Self.markerJSON(marker))

        case "marker.remove":
            // params: markerId (required). markerNotFound surfaces via the
            // LocalizedError mapping. Returns {removed: true}.
            try params.rejectUnknownKeys(
                ["markerId"], verb: "marker.remove")
            let markerID = try params.requireMarkerID()
            try store.removeMarker(id: markerID)
            return .success(request.id, .object(["removed": .bool(true)]))

        case "marker.rename":
            // params: markerId (required), name (required, non-empty). A trimmed,
            // changed name commits one undo step; empty/unchanged is a no-op.
            // Returns the resulting marker.
            try params.rejectUnknownKeys(
                ["markerId", "name"], verb: "marker.rename")
            let markerID = try params.requireMarkerID()
            let name = try params.require("name", \.stringValue)
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ControlError("'name' must not be empty")
            }
            let marker = try store.renameMarker(id: markerID, name: name)
            return .success(request.id, Self.markerJSON(marker))

        case "marker.move":
            // params: markerId (required), beat (required, >= 0). Coalesces a live
            // scrub into one undo step. Returns the moved marker.
            try params.rejectUnknownKeys(
                ["markerId", "beat"], verb: "marker.move")
            let markerID = try params.requireMarkerID()
            let beat = try params.require("beat", \.doubleValue)
            guard beat >= 0 else { throw ControlError("'beat' must be >= 0") }
            let marker = try store.moveMarker(id: markerID, beat: beat)
            return .success(request.id, Self.markerJSON(marker))

        case "marker.list":
            // No params. Returns {markers: [{id,name,beat}]} sorted by beat.
            try params.rejectUnknownKeys([], verb: "marker.list")
            let markers = store.markers.map(Self.markerJSON)
            return .success(request.id, .object(["markers": .array(markers)]))

        case "transport.setTempo":
            // The single-segment FAST PATH (m12-d). Sets one project-wide tempo;
            // the store REJECTS with a teaching error pointing at tempo.setMap on
            // a project that carries a multi-segment tempo map (surfaces via the
            // LocalizedError mapping — .tempoMapMultiSegment).
            try params.rejectUnknownKeys(
                ["bpm"], verb: "transport.setTempo")
            let bpm = try params.require("bpm", \.doubleValue)
            try store.setTempo(bpm)
            return .success(request.id, .number(store.transport.tempoBPM))

        case "tempo.map":
            // No params. Reads the RESOLVED tempo + meter maps (always >= 1 entry
            // each — a single-tempo project reports its synthesized single
            // segment/change) plus the monotonic mapRevision. The omit-when-
            // trivial mirror rides project.snapshot's tempoMap/meterChanges.
            try params.rejectUnknownKeys([], verb: "tempo.map")
            return .success(request.id, Self.tempoMapJSON(store))

        case "tempo.setMap":
            // Full-map REPLACE (m12-d, design §3.6). params: segments (required,
            // >= 1, each {beat, bpm}; segment 0 MUST be at beat 0), meterChanges
            // (optional; omit to leave the current meter map untouched). Validated
            // with field-named teaching errors. ONE undoable step (coalescing key
            // "tempo.map"); a single-segment map collapses to the scalar tempo.
            // transportBusy while recording surfaces via the LocalizedError map.
            try params.rejectUnknownKeys(
                ["segments", "meterChanges"], verb: "tempo.setMap")
            let tempoMap = try Self.parseTempoMap(params)
            let meterMap = try Self.parseMeterMap(params)
            try store.setTempoMap(tempoMap, meterMap: meterMap)
            return .success(request.id, Self.tempoMapJSON(store))

        case "transport.record":
            // No params. Starts one take on every armed audio AND instrument
            // track (track.setArm works on both). Punch windows trim AUDIO
            // capture only — MIDI notes record across the full roll (v0;
            // notes are individually editable after the fact). Microphone
            // permission gates apply only when audio tracks are armed.
            // LOOP-CYCLE TAKES (m15-b, design-m15b-loop-record): with the
            // loop enabled, record SEEKS to the loop start first (visible
            // in this response's positionBeats), loops for real (no silent
            // linear roll), and lands one take lane per loop pass on the
            // SAME take group at stop — newest lane comped, an honest
            // partial last lane on a mid-cycle stop. No behavior flag; loop
            // state alone decides (disable the loop first for a plain
            // linear take). Refuses with a teaching error when punch is
            // ALSO enabled (loop × punch is unsupported in v1) or when the
            // loop is shorter than TakeGroup.minLoopRecordCycleSeconds
            // (1 s/cycle). noArmedTracks/recordPermissionDenied/
            // recordPermissionPending/transportBusy/invalidPunchRange/
            // invalidLoopRange surface via the LocalizedError mapping.
            try params.rejectUnknownKeys([], verb: "transport.record")
            try store.record()
            return .success(request.id, try JSONValue(encoding: store.transport))

        case "transport.setLoop":
            // params: enabled bool (required), startBeat number (optional,
            // >= 0, kept if omitted), endBeat number (optional, > startBeat,
            // kept if omitted) — omitting a beat lets the UI toggle looping
            // without re-stating the range. Refused mid-record (m15-b):
            // "cannot change the loop while recording — stop first" — a
            // rolling take's loop window is frozen at record start, so a
            // mid-take bounds edit would restart the engine's scheduled loop
            // and kill the capture writer's anchor. transportBusy/
            // invalidLoopRange surface via the LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["enabled", "startBeat", "endBeat"], verb: "transport.setLoop")
            let enabled = try params.require("enabled", \.boolValue)
            let startBeat = params["startBeat"]?.doubleValue
            let endBeat = params["endBeat"]?.doubleValue
            try store.setLoop(enabled: enabled, startBeat: startBeat, endBeat: endBeat)
            return .success(request.id, try JSONValue(encoding: store.transport))

        case "transport.setPunch":
            // params: enabled bool (required), inBeat number >= 0 (optional,
            // clamped), outBeat number (optional). Omitted beats keep the
            // current window. transportBusy while recording and
            // invalidPunchRange surface via the LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["enabled", "inBeat", "outBeat"], verb: "transport.setPunch")
            let punchEnabled = try params.require("enabled", \.boolValue)
            let inBeat = params["inBeat"]?.doubleValue
            let outBeat = params["outBeat"]?.doubleValue
            try store.setPunch(enabled: punchEnabled, inBeat: inBeat, outBeat: outBeat)
            return .success(request.id, try JSONValue(encoding: store.transport))

        case "transport.setMetronome":
            // params: enabled bool (required), countInBars int (optional,
            // clamped 0...4; omitted keeps the current value). Allowed while
            // playing (the store restarts via seek so the click audibly
            // starts/stops — v0 costs a ~60 ms seam); refused while recording
            // (transportBusy surfaces via the LocalizedError mapping).
            try params.rejectUnknownKeys(
                ["enabled", "countInBars"], verb: "transport.setMetronome")
            let metronomeEnabled = try params.require("enabled", \.boolValue)
            let countInBars = params["countInBars"]?.doubleValue.map { Int($0) }
            try store.setMetronome(enabled: metronomeEnabled, countInBars: countInBars)
            return .success(request.id, try JSONValue(encoding: store.transport))

        case "transport.setStopAtContentEnd":
            // m25-d. params: enabled bool (required). Allowed in every
            // transport state — including mid-record, where it is inert by
            // construction (a take NEVER stops at content end) rather than
            // refused, so an agent flipping a preference can't fail a call for
            // reasons that have nothing to do with the preference.
            //
            // Returns BOTH the preference and the measured `contentEndBeat`
            // (0 for a project with no clips), because the second is what makes
            // the first legible: an agent can see where the stop will land.
            try params.rejectUnknownKeys(
                ["enabled"], verb: "transport.setStopAtContentEnd")
            let stopAtEnd = try params.require("enabled", \.boolValue)
            store.setStopAtContentEnd(stopAtEnd)
            return .success(request.id, JSONValue.object([
                "stopAtContentEnd": .bool(store.stopAtContentEnd),
                "contentEndBeat": .number(store.contentEndBeat),
            ]))

        case "track.add":
            // F5 HARDENING (m16-e, audit F5): the audit's measured wrong-object-
            // created trap — {type:"instrument"} silently ignored (the real key is
            // `kind`) and the omitted `kind` default (audio) created the WRONG kind
            // of track while returning ok:true. Unknown keys are REJECTED first, so
            // a typo'd `type` can never masquerade as an accepted "default to audio".
            try params.rejectUnknownKeys(
                ["name", "kind"], verb: "track.add",
                hint: "the track kind param is 'kind' (audio|instrument|bus), not "
                    + "'type' — omitting 'kind' defaults to an audio track")
            let name = params["name"]?.stringValue
            let kindRaw = params["kind"]?.stringValue ?? TrackKind.audio.rawValue
            guard let kind = TrackKind(rawValue: kindRaw) else {
                throw ControlError("unknown track kind '\(kindRaw)' — use audio|instrument|bus")
            }
            let track = store.addTrack(name: name, kind: kind)
            return .success(request.id, try JSONValue(encoding: track))

        case "track.remove":
            try params.rejectUnknownKeys(
                ["trackId"], verb: "track.remove")
            let id = try params.requireTrackID()
            // When the target is a bus, its deletion reroutes every source that
            // fed it (outputs → master, sends dropped). Count from the PRE-removal
            // state so the result tells agents exactly what moved.
            let reroutedCounts: (outputs: Int, sends: Int)?
            if let target = store.tracks.first(where: { $0.id == id }), target.kind == .bus {
                let outputs = store.tracks.filter { $0.outputBusID == id }.count
                let sends = store.tracks.reduce(0) {
                    $0 + $1.sends.filter { $0.destinationBusID == id }.count
                }
                reroutedCounts = (outputs, sends)
            } else {
                reroutedCounts = nil
            }
            guard try store.removeTrack(id: id) else { throw ControlError.noTrack(id) }
            if let reroutedCounts {
                return .success(request.id, .object(["rerouted": .object([
                    "outputs": .number(Double(reroutedCounts.outputs)),
                    "sends": .number(Double(reroutedCounts.sends)),
                ])]))
            }
            return .success(request.id)

        case "track.rename":
            try params.rejectUnknownKeys(
                ["trackId", "name"], verb: "track.rename")
            let id = try params.requireTrackID()
            let name = try params.require("name", \.stringValue)
            guard store.renameTrack(id: id, name: name) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "track.reorder":
            // params: trackId (required), index (required int). m23-h.
            //
            // `index` is the FINAL index the track lands at — the `fx.reorder`
            // convention verb for verb, so the program has ONE reorder
            // semantics: it clamps into 0 ..< trackCount and the track ends up
            // AT that index in BOTH directions. (NOT SwiftUI's `onMove`
            // pre-removal offset, where a down-by-one would be `from + 2`.)
            // trackNotFound surfaces via the LocalizedError mapping.
            //
            // The result echoes GROUND TRUTH read back off the store: the index
            // the track actually landed at, plus the whole resulting order, so a
            // caller never has to re-derive it from its own request.
            try params.rejectUnknownKeys(
                ["trackId", "index"], verb: "track.reorder",
                hint: "'index' is the FINAL position the track lands at "
                    + "(0 = top), clamped into range")
            let reorderTrackID = try params.requireTrackID()
            let reorderIndex = try params.require("index", \.doubleValue)
            let reorderLanded = try store.reorderTrack(
                id: reorderTrackID, toIndex: Int(reorderIndex))
            return .success(request.id, .object([
                "index": .number(Double(reorderLanded)),
                "order": .array(store.tracks.map { .string($0.id.uuidString) }),
            ]))

        case "track.setVolume":
            try params.rejectUnknownKeys(
                ["trackId", "volume"], verb: "track.setVolume")
            let id = try params.requireTrackID()
            let volume = try params.require("volume", \.doubleValue)
            guard store.setTrackVolume(id: id, volume: volume) else { throw ControlError.noTrack(id) }
            // m26-o: the write ALWAYS lands (it is stored, undoable, moves the
            // fader, and rules again the moment the lane goes inactive) — but
            // while an active volume lane exists the lane, not this value,
            // governs what is heard and what renders. Before this reply the
            // payload was a bare `{id, ok:true}`: an agent set a level, saw
            // success, and had no way to learn the level it set was inaudible
            // (2026-08-17 field report, N2). `activeLane` is DAWCore's single
            // definition of "automation replaces the manual control" — the
            // same predicate the render path uses, so this annotation cannot
            // disagree with what is actually heard.
            //
            // OMITTED WHEN THERE IS NO LANE (the disk rule this file follows
            // everywhere): the annotation appears exactly when it is
            // actionable, so `track.setVolume` stays a void-result "ok" verb
            // in the ordinary case — which also keeps it a valid subject for
            // the bug-1 void-result regression guard. An absent key means
            // "nothing is overriding you", which is what a caller assumes
            // anyway; a present one is a fact they must act on.
            guard let volumeLane = store.tracks.first(where: { $0.id == id })?
                .automation.activeLane(for: .volume)
            else { return .success(request.id) }
            return .success(request.id, .object([
                "automationControlled": .bool(true),
                "automationPointCount": .number(Double(volumeLane.points.count)),
            ]))

        case "track.setPan":
            try params.rejectUnknownKeys(
                ["trackId", "pan"], verb: "track.setPan")
            let id = try params.requireTrackID()
            let pan = try params.require("pan", \.doubleValue)
            guard store.setTrackPan(id: id, pan: pan) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "track.setMute":
            try params.rejectUnknownKeys(
                ["trackId", "muted"], verb: "track.setMute")
            let id = try params.requireTrackID()
            let muted = try params.require("muted", \.boolValue)
            guard store.setTrackMute(id: id, muted: muted) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "track.setSolo":
            try params.rejectUnknownKeys(
                ["trackId", "soloed"], verb: "track.setSolo")
            let id = try params.requireTrackID()
            let soloed = try params.require("soloed", \.boolValue)
            guard store.setTrackSolo(id: id, soloed: soloed) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "track.setOutput":
            // params: trackId (required), busId string|null|omitted (null/omitted
            // = master — exact input.setDevice pattern; non-string/non-null →
            // 'busId' must be a string or null). busRoutingFixed/notABus/
            // trackNotFound surface via the LocalizedError mapping.
            //
            // F5 HARDENING (m15-d): this is an "omit = destructive default" verb —
            // omitting `busId` UN-ROUTES the track to master. So a typo'd key
            // (the audit's measured `{output: <busId>}`) would silently un-route
            // and return ok. Unknown keys are REJECTED with a teaching error
            // before anything runs, so a typo can never masquerade as an un-route.
            try params.rejectUnknownKeys(
                ["trackId", "busId"], verb: "track.setOutput",
                hint: "omit 'busId' (or pass it null) to route the track to master")
            let outTrackID = try params.requireTrackID()
            let outBusID: UUID?
            switch params["busId"] {
            case .none, .some(.null):
                outBusID = nil
            case .some(.string(let raw)):
                guard let parsed = UUID(uuidString: raw) else {
                    throw ControlError("'busId' is not a valid UUID: \(raw)")
                }
                outBusID = parsed
            case .some:
                throw ControlError("'busId' must be a string or null")
            }
            try store.setTrackOutput(id: outTrackID, busID: outBusID)
            return .success(request.id, routingResult(trackID: outTrackID))

        case "track.addSend":
            // params: trackId (required), busId (required UUID), level? (number,
            // clamps silently like setVolume). duplicateSend/notABus/busRoutingFixed/
            // trackNotFound surface via the LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["trackId", "busId", "level"], verb: "track.addSend")
            let addTrackID = try params.requireTrackID()
            let rawBus = try params.require("busId", \.stringValue)
            guard let addBusID = UUID(uuidString: rawBus) else {
                throw ControlError("'busId' is not a valid UUID: \(rawBus)")
            }
            let addSend = try store.addSend(
                toTrack: addTrackID, busID: addBusID, level: params["level"]?.doubleValue ?? 1
            )
            return .success(request.id, routingResult(trackID: addTrackID, sendID: addSend.id))

        case "track.setSend":
            // params: trackId (required), sendId (required UUID), level (required
            // number). sendNotFound/busRoutingFixed/trackNotFound surface via the
            // LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["trackId", "sendId", "level"], verb: "track.setSend")
            let setSendTrackID = try params.requireTrackID()
            let setSendID = try params.requireSendID()
            let sendLevel = try params.require("level", \.doubleValue)
            _ = try store.setSendLevel(trackID: setSendTrackID, sendID: setSendID, level: sendLevel)
            return .success(request.id, routingResult(trackID: setSendTrackID))

        case "track.removeSend":
            // params: trackId (required), sendId (required UUID). sendNotFound/
            // busRoutingFixed/trackNotFound surface via the LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["trackId", "sendId"], verb: "track.removeSend")
            let remSendTrackID = try params.requireTrackID()
            let remSendID = try params.requireSendID()
            try store.removeSend(trackID: remSendTrackID, sendID: remSendID)
            return .success(request.id, routingResult(trackID: remSendTrackID))

        case "track.setInstrument":
            // params: trackId (required). Optional kind ("testTone"|"polySynth"|
            // "sampler") and waveform ("saw"|"square"|"triangle"|"sine") validated
            // against the enum rawValues; optional attack/decay/sustain/release/
            // cutoffHz/resonance/gain numbers clamp silently through the model
            // ranges (like track.setVolume). Optional `sampler` object is now a
            // PARTIAL update like everything else here — see parseSampler; a
            // nonexistent zone file surfaces the MediaImporting-style error. PARTIAL
            // update otherwise: omitted fields keep the track's current descriptor
            // (or .default when it has none). A non-instrument track surfaces
            // instrumentRequiresInstrumentTrack via the LocalizedError mapping;
            // unknown id → noTrack. Response is the resolved instrument object
            // {kind, polySynth:{...}, sampler:{zones:[{id,path,…}], sourcePath?,
            // name?, …}}.
            //
            // m26-g: the sampler object takes EXACTLY ONE of `zones` (wholesale
            // replace; [] deliberately clears) or `zonePatches` (merge by zone
            // id, every field but `id` optional, unnamed zones untouched). Zone
            // ids now survive a write on both paths — see parseSampler.
            // m26-h: `sampler.sourcePath` / `sampler.name` are READ-ONLY
            // provenance recorded by instrument.importSampleLibrary; they are
            // emitted, preserved across edits, and ignored on input.
            //
            // m30-a: a zone `path` accepts a BUNDLED SAMPLE NAME as well as a
            // filesystem path — `builtin:test-tone-a4`, a 0.35 s A4 one-shot
            // the app ships, whose root pitch is 69. This is the ONLY way to
            // make the Sampler produce a sound on a machine with no sample
            // library, and therefore the only way to smoke-test a sampler
            // feature (bend range, voice mode, zone mapping) out of the box.
            // The name resolves at the wire boundary, so the response and the
            // model both carry the real absolute path; an UNKNOWN builtin name
            // is refused, naming the known ones, rather than stored as a
            // nonsense path that would answer success and play silence. Same
            // one-string-two-forms idiom as soundBank's "gm" sentinel; purely
            // additive, since no real path begins with "builtin:".
            // Catalog + resolver: `BundledSamples` (Sources/DAWCore).
            //
            // DONE (m30-a, MCP, 2026-08-23): the `builtin:` name is taught in
            // the shared `samplerZoneSchema.path` description — which
            // `samplerZonePatchSchema` reuses via `.shape.path`, so one edit
            // covers both `track_set_instrument` and
            // `instrument_set_sampler_zones` — plus `instrument_describe_
            // sampler`'s refusal text and the daw-wire-reference skill. No new
            // tool was needed: this rides the existing path string, so the
            // command/tool bijection in mcp-server/test/audit-tools.test.ts is
            // unaffected and `allCommands` stays at 186.
            //
            // TODO(m26-g/m26-h, MCP): expose over MCP as
            // `instrument_set_sampler_zones` (the `zonePatches` merge path) and
            // surface `sourcePath`/`name` in `instrument_describe_sampler`;
            // `instrument_set_sampler_param` covers the single-global write.
            // See ROADMAP m26-i for the agreed tool names.
            try params.rejectUnknownKeys(
                ["trackId", "kind", "waveform", "sampler", "attack", "decay", "sustain",
                    "release", "cutoffHz", "resonance", "gain", "audioUnit", "soundBank"], verb: "track.setInstrument")
            let instTrackID = try params.requireTrackID()
            let kind = try parseInstrumentKind(params["kind"])
            let waveform = try parseWaveform(params["waveform"])
            // The sampler object overlays onto the track's CURRENT sampler
            // config, so `{sampler: {release: 0.4}}` changes one global and
            // leaves a 309-zone imported library standing. Before this, an
            // omitted `zones` key meant an EMPTY zone array, and since the
            // store swaps the sampler wholesale, tuning one envelope value
            // SILENTLY DELETED every zone — the instrument went quiet with no
            // error, and the only way to avoid it was to resend all 309 zones
            // read back from a ~1 MB project.snapshot. Reported 2026-08-17 by
            // an agent driving the app end-to-end (finding 12).
            let instCurrentSampler = store.tracks
                .first(where: { $0.id == instTrackID })?.instrument?.sampler
            // `remintedZoneIDs` (m26-g): ids the caller sent on the `zones`
            // path that name no zone here. Copying one track's map onto another
            // is the shape that produces these, and it must keep WORKING (it
            // did before m26-g) — but not silently. See `UnknownZoneID`.
            var instRemintedZoneIDs: [String] = []
            let sampler = try parseSampler(params["sampler"], current: instCurrentSampler,
                                           reminted: &instRemintedZoneIDs)
            // Optional `audioUnit: {type?, subType, manufacturer}` (type
            // defaults "aumu"): STRICT selection — resolved against the
            // installed list, unknown components error readably. Providing it
            // implies kind audioUnit when kind is omitted.
            let audioUnit = try parseAudioUnit(params["audioUnit"])
            // Optional `soundBank: {source, program?, bankMSB?, bankLSB?}`
            // (m10-n §6.1): STRICT source (like parseAudioUnit), defaults
            // program 0 / bankMSB 121 / bankLSB 0 clamped through the model, a
            // SERVER-derived displayName. Providing it implies kind soundBank
            // when kind is omitted; soundBank + audioUnit in one call throws
            // ambiguousInstrumentSelection at the store boundary.
            let soundBank = try parseSoundBank(params["soundBank"])
            guard let descriptor = try store.setInstrument(
                id: instTrackID,
                kind: kind,
                waveform: waveform,
                attack: params["attack"]?.doubleValue,
                decay: params["decay"]?.doubleValue,
                sustain: params["sustain"]?.doubleValue,
                release: params["release"]?.doubleValue,
                cutoffHz: params["cutoffHz"]?.doubleValue,
                resonance: params["resonance"]?.doubleValue,
                gain: params["gain"]?.doubleValue,
                sampler: sampler,
                audioUnit: audioUnit,
                soundBank: soundBank
            ) else { throw ControlError.noTrack(instTrackID) }
            var instPayload = instrumentJSON(descriptor, trackID: instTrackID)
            // ONLY when non-empty: an always-present empty array would read as
            // a field worth checking on all 178 other calls, and the ordinary
            // case is that nothing was substituted.
            if !instRemintedZoneIDs.isEmpty, case .object(var instObj) = instPayload {
                instObj["remintedZoneIDs"] = .array(instRemintedZoneIDs.map { .string($0) })
                instPayload = .object(instObj)
            }
            return .success(request.id, instPayload)

        case "track.bounceInPlace":
            // Renders ONE track offline and lands the result as a new audio
            // track + clip in ONE undo step (m11-e) — the render-and-land
            // pattern, reusing render.stems' render machinery. params: trackId
            // (required), fromBeat >= 0 (default 0), durationSeconds > 0 (same
            // broader default as render.stems: whole-session extent + a 2 s
            // tail, computed once), muteSource? (default TRUE — silences the
            // source so the bounce replaces it in the mix), name? (overrides
            // the default "<source> (Bounced)" track/clip name).
            //
            // Eligibility is IDENTICAL to render.stems for one track: the
            // target must be a master input (a direct-to-master audio/
            // instrument track, or a bus). A bus-ROUTED source track rejects
            // stemNotMasterInput verbatim (its signal is part of the
            // destination bus's stem); an unknown id → trackNotFound; a session
            // with no clips in the window → nothingToRender — all via the
            // LocalizedError mapping. The bounced audio is NEVER normalized and
            // is byte-identical to render.stems {trackIds:[trackId]} for the
            // same window (same forced full-session PDC plan, same post-fader
            // pass).
            //
            // UNDO CONTRACT: one "Bounce in Place" edit — undo removes the new
            // track+clip AND restores the source's prior mute together. The
            // rendered FILE stays on disk after undo (import semantics: undo
            // un-references media but never deletes it — a redo or a later save
            // fold still needs it). Response: the model's own BounceInPlaceResult
            // Codable — {track, clip, file, sourceTrackId, sourceMuted,
            // measurement} where measurement is the same un-normalized
            // LoudnessMeasurement a render.stems stem file carries.
            try params.rejectUnknownKeys(
                ["trackId", "fromBeat", "durationSeconds", "muteSource", "name"], verb: "track.bounceInPlace")
            let bounceTrackID = try params.requireTrackID()
            let bounceFromBeat = params["fromBeat"]?.doubleValue ?? 0
            guard bounceFromBeat >= 0 else {
                throw ControlError("'fromBeat' must be >= 0")
            }
            let bounceDurationSeconds = params["durationSeconds"]?.doubleValue
            if let bounceDurationSeconds, bounceDurationSeconds <= 0 {
                throw ControlError("'durationSeconds' must be > 0")
            }
            let bounceMuteSource = params["muteSource"]?.boolValue ?? true
            let bounceName = params["name"]?.stringValue
            let bounceInPlaceResult = try await store.bounceTrackInPlace(
                trackId: bounceTrackID, fromBeat: bounceFromBeat,
                durationSeconds: bounceDurationSeconds,
                muteSource: bounceMuteSource, name: bounceName)
            return .success(request.id, try JSONValue(encoding: bounceInPlaceResult))

        case "instrument.listAudioUnits":
            // No params. Every installed Audio Unit music device ('aumu'),
            // via the store's engine forwarder (DAWControl stays engine-free).
            try params.rejectUnknownKeys([], verb: "instrument.listAudioUnits")
            return .success(request.id, .object([
                "audioUnits": .array(store.availableAudioUnits().map { info in
                    .object([
                        "name": .string(info.name),
                        "manufacturerName": .string(info.manufacturerName),
                        "type": .string(info.component.type),
                        "subType": .string(info.component.subType),
                        "manufacturer": .string(info.component.manufacturer),
                        "version": .string(info.versionString),
                        "isV3": .bool(info.isV3),
                    ])
                }),
            ]))

        case "instrument.listSoundBanks":
            // No params. GM first, then each scanned dir's *.sf2/*.dls (§6.2)
            // AND any *.sf3, which is listed with supported:false plus an
            // unsupportedReason instead of being dropped in silence (m31-g);
            // every selection gate still refuses it. Never errors — an
            // unreadable scan dir is skipped silently. Pure file discovery
            // through the store's injected SoundBankLibrary.
            try params.rejectUnknownKeys([], verb: "instrument.listSoundBanks")
            return .success(request.id, .object([
                "banks": .array(store.availableSoundBanks().map(soundBankInfoJSON)),
            ]))

        case "instrument.listSoundBankPrograms":
            // params: source (required, "gm" or an absolute .sf2/.dls path —
            // STRICTLY validated, naming instrument.listSoundBanks). Response
            // {source, namesParsed, programs:[{program, bankMSB, bankLSB, name,
            // category}]}: the GM table for "gm", parsed SF2 names for a .sf2,
            // generic 0…127 (namesParsed:false) otherwise (§6.3).
            try params.rejectUnknownKeys(["source"], verb: "instrument.listSoundBankPrograms")
            let programsSource = try parseSoundBankSource(params["source"])
            let listing = try store.soundBankPrograms(source: programsSource)
            return .success(request.id, .object([
                "source": .string(programsSource.rawString),
                "namesParsed": .bool(listing.namesParsed),
                "programs": .array(listing.programs.map(soundBankProgramJSON)),
            ]))

        case "instrument.importSoundBank":
            // params: path (required, absolute .sf2/.dls). Copies into the
            // central library (collision-uniquified), NEVER moving/deleting the
            // source; the project is untouched. Response {bank: <SoundBankInfo>}
            // (§6.4). Extension/existence/readability errors surface in the
            // MediaImporting "Audio import failed: …" tone.
            try params.rejectUnknownKeys(
                ["path"], verb: "instrument.importSoundBank")
            let importRawPath = try params.require("path", \.stringValue)
            guard importRawPath.hasPrefix("/") else {
                throw ControlError("'path' must be an absolute path")
            }
            let importedBank = try store.importSoundBank(
                from: URL(fileURLWithPath: importRawPath))
            return .success(request.id, .object(["bank": soundBankInfoJSON(importedBank)]))

        case "instrument.importSampleLibrary":
            // params: trackId (required, an INSTRUMENT track), path (required,
            // absolute or ~-prefixed; .sfz or .dspreset), dryRun? (default false:
            // parse + map + full report, project untouched), force? (default
            // false: overrides the 4 GB sample-size refusal; the 500 MB
            // warning always reports). Imports a sample LIBRARY onto the
            // track's built-in Sampler — deliberately unlike the library-only
            // instrument.importSoundBank above, this IS a project mutation:
            // ONE journaled "Change Instrument" edit (edit.undo restores the
            // previous instrument). Copy law: imports .sfz (documented
            // subset) and .dspreset sample-library files; the §2.3
            // degradation policy is REPORTED (skippedRegions/ignoredOpcodes/
            // degradations), never silently applied. Response {report:
            // <SampleLibraryImportReport as JSON>, applied: bool}. Errors via
            // the LocalizedError mapping: wrong extension (.dslibrary carries
            // the unzip hint), missing file, preprocessor aborts (missing/
            // cyclic #include, undefined $VAR), malformed .dspreset XML /
            // wrong root element, zero-zones-on-apply (skip summary in the
            // message), size refusal (names the flag).
            // MCP twin: `instrument_import_sample_library` (mcp-server).
            try params.rejectUnknownKeys(
                ["trackId", "path", "dryRun", "force"],
                verb: "instrument.importSampleLibrary")
            let sampleLibTrackID = try params.requireTrackID()
            let sampleLibRawPath = try params.require("path", \.stringValue)
            let sampleLibPath = (sampleLibRawPath as NSString).expandingTildeInPath
            guard sampleLibPath.hasPrefix("/") else {
                throw ControlError("'path' must be an absolute path")
            }
            let sampleLibDryRun = params["dryRun"]?.boolValue ?? false
            let sampleLibForce = params["force"]?.boolValue ?? false
            let sampleLibReport = try store.importSampleLibrary(
                trackID: sampleLibTrackID, path: sampleLibPath,
                dryRun: sampleLibDryRun, force: sampleLibForce)
            return .success(request.id, .object([
                "report": try JSONValue(encoding: sampleLibReport),
                "applied": .bool(!sampleLibDryRun),
            ]))

        case "instrument.describeSampler":
            // Read-only sibling of au.describeParams for the built-in
            // Sampler (m26-i): answers "which library is loaded and how is
            // it mapped" without paying for project.snapshot's whole-project
            // cost (measured 296,809 bytes on the user's real song).
            // params: trackId (required), offset?/limit? — providing EITHER
            // requests a PAGED zone list (mirrors au.describeParams' offset/
            // maxParams paging); omitting BOTH returns the summary only,
            // with no `zones` key at all, since the whole point of this verb
            // is to answer without the megabyte.
            //
            // Refusals mirror track.setInstrument's OWN guards, so an agent
            // gets the same explanation from both verbs for the same track:
            // instrumentRequiresInstrumentTrack for an audio/bus track (the
            // exact wording track.setInstrument already throws), a
            // describeSampler-only message when the track IS an instrument
            // track but has never had a sampler configured
            // (`instrument?.sampler == nil` — distinct from a sampler
            // present with zero zones, which is the documented `zones: []`
            // clear and answers SUCCESS with `zoneSummary.count: 0`), and
            // noTrack for an unknown id. Deliberately does NOT require the
            // ACTIVE kind to be "sampler" — sampler config, like
            // audioUnit/soundBank, is carried across kind switches
            // (InstrumentDescriptor's own contract) and
            // track.setInstrument's partial-update overlay reads `current`
            // the same way, so a read that refused where the write succeeds
            // would be the inconsistency. The response's own `kind` field is
            // how a caller tells whether this sampler is the one actually
            // sounding.
            //
            // zoneSummary's pitch/velocity coverage is the UNION of zone
            // ranges, not a naive min/max — a naive envelope reports
            // "0-127, fully covered" for a library with a hole in the
            // middle, hiding exactly the field report's own failure mode (a
            // bass silent below MIDI 35, a library silent above 45). `gaps`
            // lists the uncovered sub-ranges INSIDE the envelope; omitted
            // (rather than an always-present empty array) when there are
            // none, the A-imp-1 idiom. Velocity ranges default nil -> the
            // FULL 0-127 span (SamplerZone's own documented default), not 0.
            //
            // Response: {trackId, kind, oneShot, attack, release, gain,
            // sourcePath?, displayName?, zoneSummary:{count,
            // pitchCoverage?:{min,max,gaps?}, velocityCoverage?:{min,max,
            // gaps?}, groupCount, distinctSampleFiles}, offset?, limit?,
            // truncated?, returnedZones?, zones?}. `zones` (when paged in)
            // use the EXACT samplerZoneJSON shape track.setInstrument's
            // response already emits (id included), so a caller can read one
            // page and round-trip an id into instrument_set_sampler_zones.
            try params.rejectUnknownKeys(
                ["trackId", "offset", "limit"], verb: "instrument.describeSampler")
            let describeSamplerTrackID = try params.requireTrackID()
            guard let describeSamplerTrack = store.tracks.first(where: {
                $0.id == describeSamplerTrackID
            }) else {
                throw ControlError.noTrack(describeSamplerTrackID)
            }
            guard describeSamplerTrack.kind == .instrument else {
                throw ProjectError.instrumentRequiresInstrumentTrack(describeSamplerTrack.kind)
            }
            guard let describeSamplerInstrument = describeSamplerTrack.instrument,
                  let describeSamplerParams = describeSamplerInstrument.sampler
            else {
                throw ControlError(
                    "track '\(describeSamplerTrackID.uuidString)' has no sampler configured yet"
                        + " — import a library with instrument.importSampleLibrary, or build one"
                        + " by hand with track.setInstrument {kind: \"sampler\","
                        + " sampler: {zones: [...]}}."
                        // m30-a: the app ships no sample audio, so an agent
                        // with no library of its own had no way to make this
                        // instrument sound at all. Name the bundled one-shot
                        // HERE, because this is where a caller asking "why is
                        // my sampler silent" actually arrives.
                        + " With no sample files of your own, mount the bundled test"
                        + " one-shot: zones: [{path: \"\(BundledSamples.namePrefix)"
                        + "\(BundledSamples.catalog[0].name)\", rootPitch:"
                        + " \(BundledSamples.catalog[0].rootPitch)}] — it sounds"
                        + " \(BundledSamples.catalog[0].frequencyHz) Hz at that root pitch.")
            }
            var describeSamplerResult: [String: JSONValue] = [
                "trackId": .string(describeSamplerTrackID.uuidString),
                "kind": .string(describeSamplerInstrument.kind.rawValue),
                "oneShot": .bool(describeSamplerParams.oneShot),
                "attack": .number(describeSamplerParams.attack),
                "release": .number(describeSamplerParams.release),
                "gain": .number(describeSamplerParams.gain),
                "zoneSummary": Self.samplerZoneSummaryJSON(describeSamplerParams.zones),
            ]
            // The `release`/`attack`/`oneShot` above are the STORED globals.
            // Whether the engine ever reads them depends on the zones, and a
            // global every zone overrides is a number that looks exactly like
            // a valid answer while being inert (field report 2026-08-20: a
            // global release of 3.4465 s on an instrument that decayed in
            // 0.5 s, because the imported SFZ authored ampeg_release on every
            // region). Omitted for a zero-zone sampler, the same rule
            // pitchCoverage/velocityCoverage already follow — there is no
            // inheritance to describe without zones.
            //
            // Defect D (2026-08-20 sax-team round): the stored scalars above
            // stay exactly as they were — additive-only, and round-trip
            // fidelity for a caller reading one back and writing it forward —
            // but that means a caller who reads ONLY the top level (never
            // descends into `effectiveGlobals`) saw nothing to warn them one
            // was inert. `warnings` (only-when-nonempty, the A-imp-1 idiom
            // used elsewhere on this same verb family — see reference.import)
            // is the sibling top-level key that makes it impossible to miss:
            // each entry names both the stored number and what the engine
            // actually applies, so a caller never has to descend to learn the
            // scalar is wrong.
            if !describeSamplerParams.zones.isEmpty {
                let (effectiveGlobals, warnings) =
                    Self.samplerEffectiveGlobalsJSON(describeSamplerParams)
                describeSamplerResult["effectiveGlobals"] = effectiveGlobals
                if !warnings.isEmpty {
                    describeSamplerResult["warnings"] = .array(warnings.map(JSONValue.string))
                }
            }
            if let sourcePath = describeSamplerParams.sourcePath {
                describeSamplerResult["sourcePath"] = .string(sourcePath)
            }
            if let displayName = describeSamplerParams.displayName {
                describeSamplerResult["displayName"] = .string(displayName)
            }
            // m27: only-when-SET, so a sampler that never opted in keeps its
            // pre-m27 wire shape. Settable-but-unreadable would be the same
            // silent discard this round exists to end.
            if let modDepth = describeSamplerParams.expressionModDepth {
                describeSamplerResult["expressionModDepth"] = .number(modDepth)
            }
            if let filterDepth = describeSamplerParams.expressionFilterDepth {
                describeSamplerResult["expressionFilterDepth"] = .number(filterDepth)
            }
            if let filterCC = describeSamplerParams.expressionFilterCC {
                describeSamplerResult["expressionFilterCC"] = .number(Double(filterCC))
            }
            // Bend range + voice mode: settable-but-unreadable would be the
            // same silent discard the line above exists to end. Only-when-SET,
            // so an untouched sampler's shape is unchanged.
            if let bendRange = describeSamplerParams.bendRangeSemitones {
                describeSamplerResult["bendRangeSemitones"] = .number(bendRange)
            }
            if let voiceMode = describeSamplerParams.voiceMode {
                describeSamplerResult["voiceMode"] = .string(voiceMode.rawValue)
            }
            if params["offset"] != nil || params["limit"] != nil {
                let describeSamplerOffset = try Self.parseZonePageOffset(params)
                let describeSamplerLimit = try Self.parseZonePageLimit(params)
                let describeSamplerAllZones = describeSamplerParams.zones
                let describeSamplerPageEnd = min(
                    describeSamplerAllZones.count, describeSamplerOffset + describeSamplerLimit)
                let describeSamplerPage = describeSamplerOffset < describeSamplerAllZones.count
                    ? Array(describeSamplerAllZones[describeSamplerOffset..<describeSamplerPageEnd])
                    : []
                describeSamplerResult["offset"] = .number(Double(describeSamplerOffset))
                describeSamplerResult["limit"] = .number(Double(describeSamplerLimit))
                describeSamplerResult["returnedZones"] = .number(Double(describeSamplerPage.count))
                describeSamplerResult["truncated"] = .bool(
                    describeSamplerOffset + describeSamplerPage.count < describeSamplerAllZones.count)
                describeSamplerResult["zones"] = .array(describeSamplerPage.map(Self.samplerZoneJSON))
            }
            return .success(request.id, .object(describeSamplerResult))

        case "instrument.probeLiveness":
            // m31-f ② — "does this instrument have more than one timbre?", as
            // a measurement an agent that cannot hear can act on.
            //
            // Renders a VELOCITY LADDER on the track (same pitch, one note per
            // velocity, ascending) and reports how far the spectral CENTROID
            // moved against how far the RMS moved. A big level spread with a
            // flat centroid is a single-sample patch: velocity is a volume
            // knob, and it reads as a toy on any exposed melodic part. That is
            // the exact complaint a user made about an M31 dogfood render while
            // three cycles of green tests said nothing.
            //
            // Named `instrument.probeLiveness` for sibling consistency with the
            // existing read-only `instrument.*` verbs (`describeSampler`,
            // `listSoundBanks`) — it asks a question about the INSTRUMENT on a
            // track, not about the render, so `render.*` would have filed it
            // next to the wrong neighbours. The mechanical MCP rule maps it to
            // `instrument_probe_liveness` with no exception-table entry.
            //
            // params: trackId (required), pitch? (default 57 = A3 — the pitch
            // the shipped calibration figures were measured at), velocities?
            // (default [25, 60, 95, 127], ascending, >= 2), noteSeconds?
            // (default 1.0, the shell probe's geometry).
            //
            // NOT an edit: the ladder is rendered from a synthetic one-track
            // copy built and thrown away inside the store. Nothing is inserted,
            // no undo entry is pushed, `store.tracks` is untouched. There is
            // deliberately no `fromBeat`: a windowed render DROPS every MIDI
            // note whose note-on precedes the window and would report silence
            // for material that is fine from the top.
            //
            // Response: `TimbreLiveness.Result` threaded through its own
            // Codable (can-never-drift) — {trackId, instrumentKind,
            // instrumentDetail?, pitch, noteSeconds, sampleRate, selfCheck,
            // ladder:[{velocity, rmsDb, centroidHz?, timbreGroup?}],
            // rmsSpreadDb?, centroidSpreadPercent?, distinctTimbreCount,
            // verdict, summary, thresholds, caveats}.
            //
            // ⭐ THREE THINGS THE SHAPE IS LOAD-BEARING ABOUT:
            //
            //  1. `selfCheck` rides in EVERY response, and a FAILED self-check
            //     is an ERROR, never a verdict. A flat centroid is exactly the
            //     shape a broken measurement produces, so a meter that cannot
            //     tell 440 Hz from 1760 Hz is not allowed to report deadness —
            //     that failure would be indistinguishable from a true finding.
            //  2. `verdict: "silent"` is a DISTINCT answer from `"static"`:
            //     "never measured anything" and "measured and found it flat"
            //     must not produce the same output (this tree's characteristic
            //     failure mode).
            //  3. `ladder` is the evidence and `thresholds.calibrated` is
            //     false on purpose. The 5 %/6 dB numbers are a HYPOTHESIS from
            //     one instrument family; a caller is expected to be able to
            //     disagree with the verdict from the raw table rather than
            //     inherit an uncalibrated rule silently. `distinctTimbreCount`
            //     — the layer count, a LOWER BOUND at these velocities — is
            //     the more informative number than the min-to-max percentage,
            //     because layered banks step between plateaus and need not be
            //     monotonic.
            try params.rejectUnknownKeys(
                ["trackId", "pitch", "velocities", "noteSeconds"],
                verb: "instrument.probeLiveness")
            let livenessTrackID = try params.requireTrackID()
            let livenessPitch = params["pitch"]?.doubleValue.map { Int($0.rounded()) }
                ?? ProjectStore.livenessDefaultPitch
            var livenessVelocities = ProjectStore.livenessDefaultVelocities
            if let raw = params["velocities"] {
                guard let array = raw.arrayValue else {
                    throw ControlError("`velocities` must be an array of MIDI velocities"
                        + " (1-127), ascending — e.g."
                        + " \(ProjectStore.livenessDefaultVelocities).")
                }
                let parsed = array.compactMap { $0.doubleValue.map { Int($0.rounded()) } }
                guard parsed.count == array.count else {
                    throw ControlError("`velocities` must contain only numbers.")
                }
                guard parsed.count >= 2 else {
                    throw ControlError("a velocity ladder needs at least two velocities —"
                        + " one rung cannot show whether the timbre moves.")
                }
                livenessVelocities = parsed
            }
            let livenessNoteSeconds = params["noteSeconds"]?.doubleValue
                ?? ProjectStore.livenessNoteSeconds
            let livenessResult = try await store.probeInstrumentLiveness(
                trackId: livenessTrackID, pitch: livenessPitch,
                velocities: livenessVelocities, noteSeconds: livenessNoteSeconds)
            return .success(request.id, try JSONValue(encoding: livenessResult))

        case "project.importMIDI":
            // params: path (required, absolute or ~-prefixed; .mid/.midi),
            // atBeat? (default 0, clamped >= 0 — the TIMELINE beat that file
            // tick 0 lands on; every created clip starts there and notes stay
            // clip-relative), tempoPolicy? ("auto" default | "adopt" |
            // "ignore"), instruments? ("none" default | "gm"), parts? (array of
            // ints indexing the report's `parts` array — which lists EVERY part,
            // including skipped ones, so an index means the same thing in a dry
            // run and a real one; omit for all), dryRun? (default false: full
            // report, project untouched, no undo entry), force? (default false:
            // overrides the 32-track refusal). m23-k3.
            //
            // Imports a Standard MIDI File as new instrument tracks + one MIDI
            // clip each. ONE journaled "Import MIDI File" edit — tempo/meter
            // adoption folds into it, so a single edit.undo restores the tempo
            // AND removes every track.
            //
            // tempoPolicy: "auto" adopts the file's tempo/meter maps only when
            // the project has no clips yet (so the first import sets the grid
            // and a later one never silently moves everything); "adopt" always
            // replaces them; "ignore" never does. The notes land on the SAME
            // beats either way — a MIDI file's beats come from its ticks, not
            // from its tempo. "ask" is deliberately not a value: a UI dialog
            // chooses between "adopt" and "ignore", it is not a third policy.
            // "adopt" with a non-zero atBeat is a refusal (the maps are
            // absolute, so there is no honest offset adoption).
            //
            // instruments: "gm" (THE DEFAULT since m23-k5) assigns General MIDI
            // sound-bank programs from the file's program changes (channel 10 =
            // the standard drum kit), so an imported file sounds like the
            // instruments it names; "none" is the explicit opt-out and leaves
            // the tracks on the default instrument. The program each part ASKS
            // for is reported either way. The flip is MEASURED, not assumed: on
            // a 13-part file the import call costs the same either way (26 ms)
            // and all 13 banks report `ready` in engine.auPrepareStats 161 ms
            // after a COLD import, with no main-actor cost above the "none"
            // control — the prepares are async, off the caller's edit.
            //
            // Each imported part reports BOTH names: `name` is the file's
            // LITERAL spelling and `trackName` is what the track was actually
            // called. They differ whenever the file's own name does not
            // distinguish the parts — a format-0 file carries ONE chunk name for
            // every channel, so `name` can be the song title 13 times while
            // `trackName` reads "Acoustic Grand Piano", "Standard Drum Kit",
            // "Distortion Guitar (ch 9)"… Read `trackName` to find a track.
            //
            // The recommended agent workflow is dryRun: true first — read the
            // report's `parts` array and the resolved tempo policy, then call
            // again for real with `parts` narrowed. Every fidelity loss is
            // REPORTED (clamped tempos, dropped meter changes, controller-lane
            // caps, dropped release velocities…), never silently applied.
            // Response {report: <MIDIImportReport as JSON>, applied: bool}.
            // Errors via the LocalizedError mapping: wrong extension, missing
            // file, any SMF decode error verbatim, recording (transportBusy),
            // "adopt" + atBeat, the 32-track limit (names force), and a file
            // whose import would do literally nothing.
            // TODO(m23-k3, mcp): expose this as the MCP tool `project_import_midi`
            // in mcp-server/src/server.ts — snake_case mirror, NO `daw_` prefix, so
            // the `audit-tools` command↔tool bijection stays green (157 -> 159).
            // The description must name the tempoPolicy values AND the
            // dryRun -> parts workflow: an agent that cannot discover `parts`
            // will import 64 tracks.
            try params.rejectUnknownKeys(
                ["path", "atBeat", "tempoPolicy", "instruments", "parts", "dryRun", "force"],
                verb: "project.importMIDI",
                hint: "run with dryRun: true first to see the file's parts, then "
                    + "narrow with 'parts'")
            let midiImportPath = try params.requireAbsolutePath("path")
            let midiImportAtBeat = params["atBeat"]?.doubleValue ?? 0
            let midiImportPolicy = try Self.parseMIDITempoPolicy(params["tempoPolicy"])
            let midiImportInstruments = try Self.parseMIDIImportInstruments(params["instruments"])
            let midiImportParts = try Self.parseMIDIPartIndices(params["parts"])
            let midiImportDryRun = params["dryRun"]?.boolValue ?? false
            let midiImportForce = params["force"]?.boolValue ?? false
            let midiImportReport = try store.importMIDIFile(
                path: midiImportPath, atBeat: midiImportAtBeat,
                tempoPolicy: midiImportPolicy, instruments: midiImportInstruments,
                parts: midiImportParts, dryRun: midiImportDryRun, force: midiImportForce)
            return .success(request.id, .object([
                "report": try JSONValue(encoding: midiImportReport),
                "applied": .bool(!midiImportDryRun),
            ]))

        case "clip.importMIDI":
            // params: clipId (required, an existing MIDI clip), path (required,
            // absolute or ~-prefixed), part? (int indexing the report's `parts`
            // array; default = the lowest-indexed part with notes, else the
            // lowest with controller data), atBeat? (default 0 — a CLIP-RELATIVE
            // offset for the imported content, NOT a timeline beat), dryRun?
            // (default false). m23-k3.
            //
            // Replaces the clip's notes AND controller lanes wholesale with the
            // selected part's content (the clip.setNotes whole-array shape). ONE
            // journaled "Import MIDI into Clip" edit.
            //
            // Deliberately narrow, in two ways worth knowing before you call it:
            // it NEVER touches the project's tempo or time signature (that is
            // project.importMIDI's job — a clip-level import must not move the
            // grid, so there is no tempoPolicy param), and it NEVER changes the
            // clip's length. Content past the clip end is imported and reported
            // as notesPastClipEnd / controllerPointsPastClipEnd; compose with
            // clip.fitToContent to grow the clip.
            // Response {report: <MIDIImportReport as JSON>, applied: bool}.
            // Errors: clipNotFound, notAMIDIClip, a comp member (flatten
            // first), wrong extension, missing file, SMF decode errors verbatim,
            // recording, an out-of-range part, and a part with no content.
            // TODO(m23-k3, mcp): expose this as the MCP tool `clip_import_midi`
            // in mcp-server/src/server.ts — snake_case mirror, NO `daw_` prefix
            // (the `audit-tools` bijection). The description must say that
            // `atBeat` is CLIP-relative here, or an agent will pass a timeline
            // beat and wonder where its notes went.
            try params.rejectUnknownKeys(
                ["clipId", "path", "part", "atBeat", "dryRun"],
                verb: "clip.importMIDI",
                hint: "'atBeat' here is an offset INSIDE the clip; use "
                    + "project.importMIDI to place content on the timeline")
            let clipMIDIClipID = try params.requireClipID()
            let clipMIDIPath = try params.requireAbsolutePath("path")
            let clipMIDIPart = params["part"]?.doubleValue.map { Int($0) }
            let clipMIDIAtBeat = params["atBeat"]?.doubleValue ?? 0
            let clipMIDIDryRun = params["dryRun"]?.boolValue ?? false
            let clipMIDIReport = try store.importMIDIIntoClip(
                clipID: clipMIDIClipID, path: clipMIDIPath, part: clipMIDIPart,
                atBeat: clipMIDIAtBeat, dryRun: clipMIDIDryRun)
            return .success(request.id, .object([
                "report": try JSONValue(encoding: clipMIDIReport),
                "applied": .bool(!clipMIDIDryRun),
            ]))

        case "project.exportMIDI":
            // params: path? (absolute or ~-prefixed; ".mid" appended unless the
            // path already ends in .mid/.midi; parents created; an existing file
            // is OVERWRITTEN; omit for a unique file under the temp directory),
            // trackIds? (array of track id strings; omit for every track — the
            // selection is always written in PROJECT order), division? (ticks
            // per quarter note, 1…32767, default 9600), format? (1 default | 0),
            // dryRun? (default false: full report, nothing written). m23-k4a.
            //
            // Writes the project out as a Standard MIDI File. It SERIALISES the
            // model; it does not RENDER it — which is why it is project.* and
            // not render.* (every render.* command runs the audio engine
            // offline; this one never touches it, opens no edit, and leaves no
            // undo entry). Two consequences an agent must know before calling:
            // MUTED AND SOLOED TRACKS ARE BOTH EXPORTED (pass trackIds for the
            // audible subset — do not re-implement mute filtering client-side),
            // and notes past a clip's end are exported at their authored
            // positions. Both are reported, neither is honoured.
            //
            // division defaults to 9600 because it is DERIVED, not conventional:
            // it is the smallest division that is exact for every dyadic
            // subdivision to 1/128 beat, every triplet and quintuplet, every
            // swing preset DAW Pro's own quantizer produces, and content native
            // to every common source division up to 960 — so a file imported
            // with project.importMIDI re-exports bit-exactly. 480 and 960 lose
            // swing. Set 480 if a receiving program insists on the industry
            // header; anything that then quantizes is named in the report.
            //
            // KNOWN GAP, stated rather than smuggled: the exported bytes carry
            // NO program-change events, so a receiving program uses its own
            // default sound per part. The GM instrument each track asks for is
            // in the report's per-track `program`/`programName`, and the count
            // rides `programChangesNotWritten`.
            // Response {report: <MIDIExportReport as JSON>, written: bool}.
            // Errors: a non-absolute path, division/format out of contract
            // range, an unknown trackId, a project with no instrument track at
            // all, content past the tick ceiling (names a smaller division), a
            // failed write, and any SMF encode error verbatim.
            // TODO(m23-k4a, mcp): expose this as the MCP tool
            // `project_export_midi` in mcp-server/src/server.ts — snake_case
            // mirror, NO `daw_` prefix, so the `audit-tools` command↔tool
            // bijection stays green (159 -> 161). The description MUST name the
            // 9600 default and why, the dryRun workflow, and the fact that muted
            // tracks are exported — an agent that does not know the last one
            // will re-implement mute filtering client-side.
            try params.rejectUnknownKeys(
                ["path", "trackIds", "division", "format", "dryRun"],
                verb: "project.exportMIDI",
                hint: "run with dryRun: true first to see the per-track ledger and "
                    + "every fidelity loss before anything is written")
            let midiExportPath = try Self.parseOptionalAbsolutePath(params["path"],
                                                                    key: "path")
            let midiExportTrackIDs = try parseOptionalTrackIDs(params["trackIds"])
            let midiExportDivision = try Self.parseMIDIExportDivision(params["division"])
            let midiExportFormat = try Self.parseMIDIExportFormat(params["format"])
            let midiExportDryRun = params["dryRun"]?.boolValue ?? false
            let midiExportReport = try store.exportMIDIFile(
                path: midiExportPath, trackIDs: midiExportTrackIDs,
                ticksPerQuarterNote: midiExportDivision, format: midiExportFormat,
                dryRun: midiExportDryRun)
            return .success(request.id, .object([
                "report": try JSONValue(encoding: midiExportReport),
                "written": .bool(midiExportReport.written),
            ]))

        case "track.exportMIDI":
            // params: trackId (required — an INSTRUMENT track), path?,
            // division?, format?, dryRun? — all exactly as project.exportMIDI.
            // m23-k4a.
            //
            // Identical file shape to project.exportMIDI with trackIds: [that
            // one]: a conductor chunk carrying the project name and the whole
            // tempo/meter map, plus one track chunk. The two verbs differ only
            // in selection.
            //
            // Unlike the project verb, this one REFUSES an audio or bus track
            // instead of skipping it — naming a track that cannot carry MIDI in
            // an explicit single-track request is a mistake worth saying out
            // loud, and the alternative is writing a file with no notes in it.
            // Response {report: <MIDIExportReport as JSON>, written: bool}.
            // TODO(m23-k4a, mcp): expose this as the MCP tool `track_export_midi`
            // in mcp-server/src/server.ts — snake_case mirror, NO `daw_` prefix
            // (the `audit-tools` bijection). The description must say that the
            // file still carries the project's tempo and meter map, or an agent
            // will assume a single-track export is grid-less.
            try params.rejectUnknownKeys(
                ["trackId", "path", "division", "format", "dryRun"],
                verb: "track.exportMIDI",
                hint: "use project.exportMIDI with 'trackIds' to export several "
                    + "tracks into one file")
            let trackExportID = try params.requireTrackID()
            let trackExportPath = try Self.parseOptionalAbsolutePath(params["path"],
                                                                     key: "path")
            let trackExportDivision = try Self.parseMIDIExportDivision(params["division"])
            let trackExportFormat = try Self.parseMIDIExportFormat(params["format"])
            let trackExportDryRun = params["dryRun"]?.boolValue ?? false
            let trackExportReport = try store.exportTrackMIDIFile(
                trackID: trackExportID, path: trackExportPath,
                ticksPerQuarterNote: trackExportDivision, format: trackExportFormat,
                dryRun: trackExportDryRun)
            return .success(request.id, .object([
                "report": try JSONValue(encoding: trackExportReport),
                "written": .bool(trackExportReport.written),
            ]))

        case "fx.add":
            // params: trackId (required — a track/bus UUID or the "master"
            // sentinel, m13-d), kind (required, one of the effect kinds), index?
            // (int, clamps into [0, chain length]), params? (object of
            // name:value, clamped silently via EffectParamSpec — an unknown name
            // errors before anything is added). Returns {effectId, effects}.
            // Unknown kind lists valid kinds; chainFull/trackNotFound surface via
            // the LocalizedError mapping. On the MASTER chain only built-in kinds
            // are legal (kind "audioUnit" → masterChainBuiltInOnly via the store).
            try params.rejectUnknownKeys(
                ["trackId", "kind", "index", "params", "audioUnit"], verb: "fx.add")
            let fxAddTarget = try params.parseFXTarget()
            let fxKind = try parseEffectKind(params["kind"])
            let fxIndex = params["index"]?.doubleValue.map { Int($0) }
            // Pre-validate any initial param names against the kind's schema so a
            // bad one fails BEFORE the effect is added (nothing changes on error).
            var fxInitialParams: [(String, Double)] = []
            if case .object(let paramObj)? = params["params"] {
                let specs = EffectParamSpec.specs(for: fxKind)
                let valid = Set(specs.map(\.name))
                for (name, value) in paramObj {
                    guard valid.contains(name) else {
                        let names = specs.map(\.name).joined(separator: ", ")
                        throw ControlError("unknown parameter '\(name)' for \(fxKind.rawValue) effect — valid: \(names)")
                    }
                    if let number = value.doubleValue { fxInitialParams.append((name, number)) }
                }
            }
            switch fxAddTarget {
            case .track(let fxAddTrackID):
                // kind "audioUnit" additionally takes audioUnit {type?, subType,
                // manufacturer} (type defaults "aufx"), resolved STRICTLY against
                // the installed effect components — unknown component errors and
                // nothing is added. Omitting audioUnit for this kind errors at
                // the store boundary (audioUnitEffectRequiresComponent).
                var fxAudioUnit: AudioUnitConfig?
                if fxKind == .audioUnit {
                    fxAudioUnit = try parseAudioUnit(
                        params["audioUnit"], defaultType: "aufx",
                        candidates: store.availableAudioUnitEffects(),
                        listCommand: "fx.listAudioUnits")
                }
                let fxDescriptor = try store.addEffect(toTrack: fxAddTrackID, kind: fxKind,
                                                       at: fxIndex, audioUnit: fxAudioUnit)
                for (name, value) in fxInitialParams {
                    _ = try store.setEffectParam(trackID: fxAddTrackID, effectID: fxDescriptor.id,
                                                 name: name, value: value)
                }
                return .success(request.id, fxResult(trackID: fxAddTrackID, effectID: fxDescriptor.id))
            case .master:
                // Master hosts built-in effects only in v1 (design D4a): the
                // store throws masterChainBuiltInOnly for kind "audioUnit"
                // BEFORE anything changes, so no AU component is parsed here.
                let fxDescriptor = try store.addMasterEffect(kind: fxKind, at: fxIndex)
                for (name, value) in fxInitialParams {
                    _ = try store.setMasterEffectParam(effectID: fxDescriptor.id,
                                                       name: name, value: value)
                }
                return .success(request.id, masterFxResult(effectID: fxDescriptor.id))
            }

        case "fx.remove":
            // params: trackId (required — a track UUID or "master", m13-d),
            // effectId (required UUID). effectNotFound/trackNotFound surface via
            // the LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["trackId", "effectId"], verb: "fx.remove")
            let fxRemEffectID = try params.requireEffectID()
            switch try params.parseFXTarget() {
            case .track(let fxRemTrackID):
                try store.removeEffect(trackID: fxRemTrackID, effectID: fxRemEffectID)
                return .success(request.id, fxResult(trackID: fxRemTrackID))
            case .master:
                try store.removeMasterEffect(effectID: fxRemEffectID)
                return .success(request.id, masterFxResult())
            }

        case "fx.reorder":
            // params: trackId (required — a track UUID or "master", m13-d),
            // effectId (required UUID), index (required int, clamps into the
            // valid range). effectNotFound/trackNotFound surface via the
            // LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["trackId", "effectId", "index"], verb: "fx.reorder")
            let fxReoEffectID = try params.requireEffectID()
            let fxReoIndex = try params.require("index", \.doubleValue)
            switch try params.parseFXTarget() {
            case .track(let fxReoTrackID):
                try store.reorderEffect(trackID: fxReoTrackID, effectID: fxReoEffectID,
                                        toIndex: Int(fxReoIndex))
                return .success(request.id, fxResult(trackID: fxReoTrackID))
            case .master:
                try store.reorderMasterEffect(effectID: fxReoEffectID, toIndex: Int(fxReoIndex))
                return .success(request.id, masterFxResult())
            }

        case "fx.setBypass":
            // params: trackId (required — a track UUID or "master", m13-d),
            // effectId (required UUID), bypassed (required bool). effectNotFound/
            // trackNotFound surface via the LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["trackId", "effectId", "bypassed"], verb: "fx.setBypass")
            let fxBypEffectID = try params.requireEffectID()
            let fxBypassed = try params.require("bypassed", \.boolValue)
            switch try params.parseFXTarget() {
            case .track(let fxBypTrackID):
                try store.setEffectBypassed(trackID: fxBypTrackID, effectID: fxBypEffectID,
                                            bypassed: fxBypassed)
                return .success(request.id, fxResult(trackID: fxBypTrackID))
            case .master:
                try store.setMasterEffectBypassed(effectID: fxBypEffectID, bypassed: fxBypassed)
                return .success(request.id, masterFxResult())
            }

        case "fx.setParam":
            // params: trackId (required — a track UUID or "master", m13-d),
            // effectId (required UUID), name (required string), value (required
            // number, clamps silently through the spec range like
            // track.setVolume). An unknown name surfaces unknownEffectParam
            // (listing the valid names); effectNotFound/trackNotFound also
            // surface via the LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["trackId", "effectId", "name", "value"], verb: "fx.setParam")
            let fxParEffectID = try params.requireEffectID()
            let fxParName = try params.require("name", \.stringValue)
            let fxParValue = try params.require("value", \.doubleValue)
            switch try params.parseFXTarget() {
            case .track(let fxParTrackID):
                let fxParDescriptor = try store.setEffectParam(
                    trackID: fxParTrackID, effectID: fxParEffectID, name: fxParName, value: fxParValue)
                return .success(request.id, fxResult(trackID: fxParTrackID, effectID: fxParDescriptor.id))
            case .master:
                let fxParDescriptor = try store.setMasterEffectParam(
                    effectID: fxParEffectID, name: fxParName, value: fxParValue)
                return .success(request.id, masterFxResult(effectID: fxParDescriptor.id))
            }

        case "fx.setSidechain":
            // params: trackId (required), effectId (required UUID), sourceTrackId
            // (nullable/optional — ABSENT or `null` CLEARS the key). Keys a
            // built-in compressor/gate off another track's post-fader signal
            // (m12-g S-4; replaces the retired app-tier staging seam).
            // The store validates and throws the four field-named teaching errors
            // verbatim (sidechainUnsupportedEffect on a non-compressor/gate incl.
            // hosted AUs; sidechainUnsupportedTrack on an instrument destination;
            // sidechainUnsupportedSource on a bus key source; sidechainWouldCreate-
            // Cycle naming the → path; sidechainOneSourcePerStrip) plus
            // trackNotFound/effectNotFound via the LocalizedError mapping.
            // Returns the track's resolved insert chain (the fx.* convention —
            // the keyed effect carries `sidechainSourceTrackId`) PLUS
            // `sidechainSkewSamples` (the honest key-tap PDC skew, parity with
            // the retired seam).
            // The master chain cannot host a sidechain-keyed effect (m13-d,
            // design §4): reject `trackId:"master"` with the NAMED teaching
            // error rather than the generic UUID-parse error.
            try params.rejectUnknownKeys(
                ["trackId", "effectId", "sourceTrackId"], verb: "fx.setSidechain")
            guard case .track(let fxScTrackID) = try params.parseFXTarget() else {
                throw ProjectError.sidechainMasterUnsupported
            }
            let fxScEffectID = try params.requireEffectID()
            // sourceTrackId absent → nil (clear); explicit null → nil (clear); a
            // non-null value must be a valid UUID (field-named on a bad value).
            // The "master" sentinel is rejected here too (wire-level, m13-d): the
            // master output cannot be a key SOURCE — this upgrades the raw
            // UUID-parse error that "master" used to hit at this site.
            var fxScSource: UUID?
            switch params["sourceTrackId"] {
            case .string(let raw)?:
                if raw == "master" {
                    throw ControlError("the master output cannot be a sidechain key source")
                }
                guard let parsed = UUID(uuidString: raw) else {
                    throw ControlError("'sourceTrackId' is not a valid UUID: \(raw)")
                }
                fxScSource = parsed
            case .null?, nil:
                fxScSource = nil
            default:
                throw ControlError("'sourceTrackId' must be a track id string or null")
            }
            _ = try store.setSidechain(trackID: fxScTrackID, effectID: fxScEffectID,
                                       sourceTrackID: fxScSource)
            let fxScSkew = store.pdcReport()?.strips[fxScTrackID]?.sidechainSkewSamples ?? 0
            var fxScResult = fxResult(trackID: fxScTrackID, effectID: fxScEffectID)
            if case .object(var obj) = fxScResult {
                obj["sidechainSkewSamples"] = .number(Double(fxScSkew))
                fxScResult = .object(obj)
            }
            return .success(request.id, fxScResult)

        case "fx.describe":
            // params: kind? (omit for every kind). Returns the parameter schemas
            // from EffectParamSpec — MCP discoverability. Unknown kind lists valid
            // kinds. Wire shape: {"kinds": [{"kind", "params": [{name, min, max,
            // default, unit, note?}]}]}. `note` (m22-a, additive) teaches the
            // semantics a bare range can't: the EQ's nil-means-off HP/LP corners,
            // 12/24 slope snapping, and 0/1 per-band bypass.
            try params.rejectUnknownKeys(["kind"], verb: "fx.describe")
            let fxKinds: [EffectDescriptor.Kind]
            if let rawKind = params["kind"]?.stringValue {
                guard let resolved = EffectDescriptor.Kind(rawValue: rawKind) else {
                    let valid = EffectDescriptor.Kind.allCases.map(\.rawValue).joined(separator: "|")
                    throw ControlError("unknown effect kind '\(rawKind)' — use \(valid)")
                }
                fxKinds = [resolved]
            } else {
                fxKinds = EffectDescriptor.Kind.allCases
            }
            return .success(request.id, .object([
                "kinds": .array(fxKinds.map { kind in
                    .object([
                        "kind": .string(kind.rawValue),
                        "params": .array(EffectParamSpec.specs(for: kind).map { spec in
                            var paramObj: [String: JSONValue] = [
                                "name": .string(spec.name),
                                "min": .number(spec.range.lowerBound),
                                "max": .number(spec.range.upperBound),
                                "default": .number(spec.defaultValue),
                                "unit": .string(spec.unit),
                            ]
                            // Omitted when nil (additive m22-a teaching line).
                            if let note = spec.note { paramObj["note"] = .string(note) }
                            return .object(paramObj)
                        }),
                    ])
                }),
            ]))

        case "fx.listAudioUnits":
            // No params. Every installed Audio Unit effect ('aufx') — the
            // instrument.listAudioUnits mirror, same wire shape.
            try params.rejectUnknownKeys([], verb: "fx.listAudioUnits")
            return .success(request.id, .object([
                "audioUnits": .array(store.availableAudioUnitEffects().map { info in
                    .object([
                        "name": .string(info.name),
                        "manufacturerName": .string(info.manufacturerName),
                        "type": .string(info.component.type),
                        "subType": .string(info.component.subType),
                        "manufacturer": .string(info.component.manufacturer),
                        "version": .string(info.versionString),
                        "isV3": .bool(info.isV3),
                    ])
                }),
            ]))

        case "track.setArm":
            try params.rejectUnknownKeys(
                ["trackId", "armed"], verb: "track.setArm")
            let id = try params.requireTrackID()
            let armed = try params.require("armed", \.boolValue)
            guard try store.setTrackArm(id: id, armed: armed) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "mixer.setMasterVolume":
            try params.rejectUnknownKeys(
                ["volume"], verb: "mixer.setMasterVolume")
            let volume = try params.require("volume", \.doubleValue)
            store.setMasterVolume(volume)
            // m26-q: the same annotation `track.setVolume` grew in m26-o, for
            // the same defect one level up. `ProjectStore.masterAutomation`'s
            // own contract says the lane REPLACES the fader, and the render
            // path gates on exactly this predicate — so without the annotation
            // an agent sets the master level, is told `{masterVolume: 0.8}`,
            // and has no way to learn that a master volume lane, not that
            // value, decides what is heard and what renders.
            //
            // ADDITIVE and OMIT-WHEN-ABSENT, both load-bearing: `masterVolume`
            // is still ALWAYS present (this verb was never void-result, so
            // dropping it to copy `track.setVolume` literally would break every
            // existing caller), and the two annotation keys appear ONLY when a
            // lane actually governs. An always-present flag is what broke the
            // bug-1 void-result regression guard once already; here it would
            // also read as a warning on every ordinary call.
            //
            // `activeLane` is DAWCore's ONE definition of "automation replaces
            // the manual control" — the same predicate the schedule build uses,
            // so this annotation cannot disagree with what is actually heard. An
            // EMPTY lane is inert by that definition (the vii-a contract), and
            // so is a DISABLED one; neither is annotated.
            var masterVolumePayload: [String: JSONValue] = [
                "masterVolume": .number(store.masterVolume),
            ]
            if let masterVolumeLane = store.masterAutomation.activeLane(for: .volume) {
                masterVolumePayload["automationControlled"] = .bool(true)
                masterVolumePayload["automationPointCount"] =
                    .number(Double(masterVolumeLane.points.count))
            }
            return .success(request.id, .object(masterVolumePayload))

        case "mixer.applyPreset":
            // params: trackId (required), preset (required string — one of the
            // curated MixerPresetCatalog names). The preset's insert chain
            // REPLACES the strip's current chain as ONE undoable edit
            // ("Apply Preset '<DisplayName>'"); volume/pan/sends are untouched.
            // Works on audio, instrument, and bus tracks. An unknown preset
            // errors with a message listing every valid name; trackNotFound
            // surfaces via the LocalizedError mapping. Returns the resulting
            // chain in the shared fx-mutation result shape ({trackId, effects})
            // so the agent sees the effects the preset laid down, in order.
            try params.rejectUnknownKeys(
                ["trackId", "preset"], verb: "mixer.applyPreset")
            let presetTrackID = try params.requireTrackID()
            let presetName = try params.require("preset", \.stringValue)
            _ = try store.applyMixerPreset(trackID: presetTrackID, presetName: presetName)
            return .success(request.id, fxResult(trackID: presetTrackID))

        case "mixer.masterAnalysis":
            // No params. Latest master-mix analysis snapshot (M8 vm-a, the
            // session vibe meter's data source), measured POST-master-fader:
            // {bands: [24 dB values, 40 Hz → 16 kHz log-spaced, floor −80],
            // levelDB (short-term RMS — NOT LUFS; use render.measureLoudness
            // for that), peakDB, centroidHz ("brightness"), flux (0–1
            // "energy movement")}. Poll-based (refreshed ~30–60 Hz while the
            // engine runs); every field is finite by contract — stopped or
            // silent sessions decay to the floors, never an error. Headless
            // (no engine) reads the floor snapshot.
            // m22-d ADDITIVE stereo-image keys on the same response (~300 ms
            // integration, floors when stopped/silent/mono/headless):
            // correlation (−1…+1; +1 = mono-safe, 0 = decorrelated, −1 = the
            // mix CANCELS when summed to mono; floor +1 — silence/mono holds
            // nothing out of phase; a dead channel, i.e. hard-panned mono,
            // also reads +1), width (0…1 side-vs-mid energy S²/(M²+S²); 0 =
            // mono, 0.5 = uncorrelated or hard-panned, 1 = pure anti-phase;
            // floor 0), balance (−1…+1 L/R energy balance, −1 = all left,
            // +1 = all right; floor 0). The goniometer's raw sample pairs
            // deliberately do NOT ride this always-on payload — they stay on
            // the app-side engine accessor (MasterScopeFrame).
            try params.rejectUnknownKeys([], verb: "mixer.masterAnalysis")
            return .success(request.id, try JSONValue(encoding: store.masterAnalysis()))

        case "mixer.liveLoudness":
            // params: reset? (bool, default false). Live master-bus loudness
            // (m22-c): streaming BS.1770-4 measured POST-master-fader on the
            // same tap as mixer.masterAnalysis. Response =
            // LiveLoudnessSnapshot verbatim: {momentaryLufs (current 400 ms),
            // shortTermLufs (current 3 s), maxMomentaryLufs,
            // maxShortTermLufs, integratedLufs (running gated),
            // loudnessRangeLu (running EBU 3342 LRA), truePeakDbtp (running
            // 4× true peak), dcOffset, crestFactorDb, secondsAnalyzed}. nil
            // fields are OMITTED and mean NOT ENOUGH AUDIO YET (momentary
            // needs 400 ms, short-term 3 s, integrated/LRA gated evidence;
            // sub-−200 dB float noise — an idle engine's denormal tails —
            // also reads as nil, never a −3000 LUFS absurdity) — honest
            // no-evidence, never 0. Transport-independent running
            // measurement (stop/start does not restart it); reset=true
            // restarts THEN returns the fresh snapshot. Headless (no engine)
            // or a fake without live metering surfaces the engineUnavailable
            // teaching error — a live meter cannot be faked with floors.
            try params.rejectUnknownKeys(["reset"], verb: "mixer.liveLoudness")
            let loudnessReset = params["reset"]?.boolValue ?? false
            return .success(request.id,
                            try JSONValue(encoding: store.liveLoudness(reset: loudnessReset)))

        case "reference.import":
            // params: path (required — absolute path of an audio file; ~
            // expands), name? (display name, defaults to the file's
            // basename). Imports the file as THE project reference (m22-g):
            // COPIES it into the app-support References/ home (import
            // copies, never moves; a save later folds it into the bundle's
            // media/), probes it, and runs the one-time analysis — loudness
            // (integrated/max-momentary/max-short-term LUFS, true peak dBTP,
            // LRA — the same BS.1770 math as render.measureLoudness), the
            // 24-band average spectrum, and whole-file stereo
            // width/correlation/balance. Sets the slot in ONE undoable edit,
            // REPLACING any existing reference (one undo restores the prior
            // slot, analysis included). Legal mid-play and mid-record.
            // Response: the slot verbatim {id, name, path, offsetSeconds,
            // trimDb, analysis?} — `analysis` omitted plus a `warnings`
            // array naming the cause when analysis failed (the slot still
            // lands; reference.analyze retries). A missing/unreadable file
            // refuses with the importer's own message; headless import
            // lands the slot un-analyzed with a warning.
            try params.rejectUnknownKeys(["path", "name"], verb: "reference.import")
            let referencePath = try params.require("path", \.stringValue)
            let referenceName = params["name"]?.stringValue
            let importOutcome = try await store.importReference(
                path: referencePath, name: referenceName)
            var importResult = try JSONValue(encoding: importOutcome.slot)
            if !importOutcome.warnings.isEmpty, case .object(var obj) = importResult {
                obj["warnings"] = .array(importOutcome.warnings.map { .string($0) })
                importResult = .object(obj)
            }
            return .success(request.id, importResult)

        case "reference.remove":
            // No params. Clears the reference slot in ONE undoable edit
            // ("Remove Reference" — undo restores the slot, analysis
            // included); the imported copy stays on disk (no GC, the
            // undo-resurrection rule). Empty slot → the referenceNotSet
            // teaching error verbatim. Response: {removed: true, name}.
            try params.rejectUnknownKeys([], verb: "reference.remove")
            let removedSlot = try store.removeReference()
            return .success(request.id, .object([
                "removed": .bool(true),
                "name": .string(removedSlot.name),
            ]))

        case "reference.status":
            // No params. Read-only, never throws: {reference?, monitoring,
            // wouldMatchGainDb?} — `reference` (the slot verbatim, with its
            // stored analysis) omitted when no reference is loaded;
            // `monitoring` is the transient A/B state (false until the P2
            // monitor lane lands; never persisted, never in
            // project.snapshot); `wouldMatchGainDb` previews the exact
            // level-match law (mix live integrated — or the −14 LUFS
            // fallback when the mix has no reading — minus the reference's
            // integrated, plus trim, clamped to the −1 dBTP ceiling)
            // whenever the slot carries a computable analysis. The live
            // matchGainDb/matchBasis/ceilingLimited fields ride only while
            // monitoring (P2).
            try params.rejectUnknownKeys([], verb: "reference.status")
            return .success(request.id, try JSONValue(encoding: store.referenceStatus()))

        case "reference.analyze":
            // No params. Re-runs the one-time reference analysis on demand
            // (missing/failed/analyzer-version-bumped analysis) and stores
            // the fresh result in the slot as ONE undoable edit. Refusals,
            // verbatim: no slot → referenceNotSet; file gone from disk →
            // referenceFileMissing (naming the path); headless / an engine
            // without the capability → engineUnavailable (an analysis is
            // never fabricated). Response: the fresh ReferenceAnalysis
            // verbatim {integratedLufs?, maxMomentaryLufs?,
            // maxShortTermLufs?, truePeakDbtp?, loudnessRangeLu?, bandsDb
            // [24, dB, floor −80], correlation, width, balance,
            // durationSeconds, sampleRateHz, analyzerVersion} — nil loudness
            // fields are OMITTED and mean a gated-silent/too-short program
            // (honest absence, never 0).
            try params.rejectUnknownKeys([], verb: "reference.analyze")
            return .success(request.id,
                            try JSONValue(encoding: try await store.analyzeReference()))

        case "reference.setMonitor":
            // params: on (required bool). The A/B monitor toggle (m22-g P2):
            // on=true gates the MIX (post-master-chain) and auditions the
            // reference level-matched — the match gain is computed ONCE at
            // toggle-ON from the mix's live gated integrated (or the −14
            // LUFS fallback when the mix has no reading) minus the
            // reference's integrated, plus trim, clamped so the reference's
            // true peak never exceeds −1 dBTP — and SNAPSHOTTED (it never
            // chases the evolving reading mid-audition; toggle again to
            // re-match). The reference follows the timeline (offset-mapped,
            // PDC-aligned); toggling mid-play re-anchors the reference
            // player only — the transport and the mix are never interrupted.
            // Master meters / live loudness KEEP reading the MIX while
            // auditioning (the tap sits upstream of the gate). on=false ends
            // the audition (idempotent, never refuses). Transient state:
            // never persisted, never undoable, never in project.snapshot.
            // Response: {monitoring, matchGainDb?, matchBasis?
            // ("liveIntegrated"|"fallbackTarget"), mixIntegratedLufs?,
            // referenceIntegratedLufs?, ceilingLimited?} — match fields only
            // when on. Refusals verbatim (teaching errors): no slot →
            // referenceNotSet; not analyzed → referenceNotAnalyzed;
            // gated-silent reference → referenceSilent; file gone →
            // referenceFileMissing; headless → engineUnavailable (a monitor
            // is never faked).
            try params.rejectUnknownKeys(["on"], verb: "reference.setMonitor")
            let monitorOn = try params.require("on", \.boolValue)
            return .success(request.id,
                            try JSONValue(encoding: store.setReferenceMonitor(on: monitorOn)))

        case "reference.setOffset":
            // params: seconds (required number). Sets the timeline↔file
            // offset: reference file time = timeline seconds +
            // offsetSeconds (negative = the reference starts later than the
            // timeline; use it to line the reference's chorus up with
            // yours). ONE coalesced undoable edit (key reference.offset).
            // While monitoring during playback the reference player
            // re-anchors at the newly mapped position (player-local — the
            // transport never moves). Response: the slot verbatim {id,
            // name, path, offsetSeconds, trimDb, analysis?}. Empty slot →
            // referenceNotSet verbatim.
            try params.rejectUnknownKeys(["seconds"], verb: "reference.setOffset")
            let offsetSeconds = try params.require("seconds", \.doubleValue)
            return .success(request.id,
                            try JSONValue(encoding: try store.setReferenceOffset(
                                seconds: offsetSeconds)))

        case "reference.setTrim":
            // params: db (required number, clamped ±24). User trim on top
            // of the level-match law. ONE coalesced undoable edit (key
            // reference.trim). While monitoring the law recomputes against
            // the SNAPSHOTTED toggle-ON basis (never the evolving live
            // reading) and only the gain re-applies — no re-anchor, no
            // dropout. Response: the slot verbatim plus {matchGainDb} (the
            // re-applied gain) when monitoring; the slot echo's trimDb
            // reveals the clamp. Empty slot → referenceNotSet verbatim.
            try params.rejectUnknownKeys(["db"], verb: "reference.setTrim")
            let trimDb = try params.require("db", \.doubleValue)
            let trimOutcome = try store.setReferenceTrim(db: trimDb)
            var trimResult = try JSONValue(encoding: trimOutcome.slot)
            if let matchGainDb = trimOutcome.matchGainDb,
               case .object(var obj) = trimResult {
                obj["matchGainDb"] = .number(matchGainDb)
                trimResult = .object(obj)
            }
            return .success(request.id, trimResult)

        case "reference.compare":
            // No params. The mix-vs-reference comparison (m22-g P2):
            // {mix: {integratedLufs?, maxTruePeakDbtp?, loudnessRangeLu?,
            // width?, correlation?, bandsDb?}, reference: {…the stored
            // whole-file analysis verbatim…}, delta: {lufs?, truePeakDb?,
            // lra?, width?, correlation?, bandsDb?}} — delta = reference −
            // mix per field, each omitted when either side lacks evidence
            // (honest nils, the m22-c omission law; negative delta.lufs =
            // your mix is LOUDER than the reference). The mix loudness
            // fields are the live running measurement (mixer.liveLoudness);
            // mix bandsDb/width/correlation are the RECENT LIVE (ballistic)
            // master-analyzer reading, not a whole-program average — poll
            // during steady playback of a representative section. Refusals
            // verbatim: no slot → referenceNotSet; not analyzed →
            // referenceNotAnalyzed; headless / no live meter →
            // engineUnavailable (floors would fake deltas).
            try params.rejectUnknownKeys([], verb: "reference.compare")
            return .success(request.id,
                            try JSONValue(encoding: try store.referenceCompare()))

        case "audio.profileFile":
            // params: path (required — absolute/~-prefixed path to ANY
            // audio file on disk; not a track, not a clip, not the project
            // reference), windowSeconds > 0 (required), fromSeconds >= 0
            // (default 0), durationSeconds > 0 (default: rest of the file
            // from fromSeconds). m25-z: the missing "what is the peak level
            // between 53s and 54s of this WAV" surface — a windowing
            // question, deliberately NOT a second copy of the BS.1770
            // loudness path (render.measureLoudness/reference.analyze
            // already answer program-loudness questions; m23-ch keeps the
            // ebur128 cross-check external on purpose, since a single
            // meter cannot detect its own miscount).
            // Read-only: never writes, never copies, and the project's
            // reference slot / References library are UNTOUCHED (unlike
            // reference.import, this never occupies the one reference slot
            // and never copies the file anywhere).
            // Response: {durationSeconds, sampleRateHz, channelCount,
            // bitDepth?, isFloat?, windows: [{startSeconds, durationSeconds,
            // peakDb?, rmsDb?}]}. durationSeconds in the header is the
            // WHOLE file (the ffprobe readback); each window's own
            // durationSeconds is usually windowSeconds, except the LAST
            // window of the profiled range, which truncates at EOF (or at
            // fromSeconds+durationSeconds) and reads shorter. peakDb is
            // SAMPLE peak (raw inter-sample max) — NOT the 4x-oversampled
            // BS.1770 true peak render.measureLoudness/reference.analyze
            // report as truePeakDbtp; a window can read under 0 dBFS here
            // and still exceed 0 dBTP true peak. rmsDb combines all
            // channels (the live-meter convention: max-abs peak across
            // channels, combined-channel RMS — never a mono downmix
            // first, which would under-report anti-phase content). A
            // digitally-silent window OMITS peakDb/rmsDb (honest absence —
            // JSON has no -inf; never a fabricated 0). Refusals verbatim:
            // no file at path -> audioFileNotFound (names the path);
            // headless / no engine -> engineUnavailable (a profile is
            // never fabricated).
            try params.rejectUnknownKeys(
                ["path", "windowSeconds", "fromSeconds", "durationSeconds"],
                verb: "audio.profileFile")
            let profilePath = try params.requireAbsolutePath("path")
            let profileWindowSeconds = try params.require("windowSeconds", \.doubleValue)
            guard profileWindowSeconds > 0 else {
                throw ControlError("'windowSeconds' must be > 0")
            }
            let profileFromSeconds = params["fromSeconds"]?.doubleValue ?? 0
            guard profileFromSeconds >= 0 else {
                throw ControlError("'fromSeconds' must be >= 0")
            }
            let profileDurationSeconds = params["durationSeconds"]?.doubleValue
            if let profileDurationSeconds, profileDurationSeconds <= 0 {
                throw ControlError("'durationSeconds' must be > 0")
            }
            let profileResult = try await store.profileFile(
                path: profilePath, windowSeconds: profileWindowSeconds,
                fromSeconds: profileFromSeconds, durationSeconds: profileDurationSeconds)
            return .success(request.id, try JSONValue(encoding: profileResult))

        case "engine.performanceStats":
            // params: reset? (bool, default false). Render-load / overrun
            // telemetry (M9 perf-b) stamped per render callback by the
            // engine's two instrumented Tier-1 blocks (instrument source
            // nodes + per-strip chain hosts); live playback AND offline
            // renders both count. Response = EnginePerformanceStats verbatim:
            // {callbackCount, renderedFrames, renderTimeNs, peakCallbackNs,
            // overrunCount (budget-overrun proxy — NOT a CoreAudio xrun
            // count), averageLoad (0…, fraction of the per-callback RT
            // budget consumed), recentLoad (~1 s EMA), sampleRate,
            // quantumFrames, sinceResetSeconds}. All fields finite by
            // contract; a stopped engine freezes the counters but stays
            // readable; headless (no engine) reads the all-zero window.
            // reset=true returns the CLOSING window and starts a fresh one
            // (read-then-reset — the windowed-profiling idiom: call with
            // reset=true, do the work, call again to read exactly that
            // window).
            try params.rejectUnknownKeys(["reset"], verb: "engine.performanceStats")
            let statsReset = params["reset"]?.boolValue ?? false
            return .success(request.id,
                            try JSONValue(encoding: store.performanceStats(reset: statsReset)))

        case "engine.watchdogStatus":
            // No params. Engine watchdog state (M9 crash-c): the stall
            // detector that watches the perf-b telemetry heartbeat — while
            // the engine claims to run, the lifetime render-callback count
            // must advance every ~2 s check; frozen across 2 checks = the
            // render side is dead (silent HAL stall, device death without a
            // config-change notification), and the watchdog drives the SAME
            // auto-restart recovery the config-change path uses. Response =
            // EngineWatchdogStatus verbatim: {state ("idle" = engine
            // intentionally stopped or no signal expected — never a stall;
            // "ok" = heartbeat advancing; "recovering" = stall declared,
            // restart in flight/retrying; "failed" = 3 consecutive restart
            // failures, watchdog stood down until the next successful engine
            // start — manual intervention), restartCount (lifetime
            // successful self-heals — nonzero means the engine died and
            // recovered), consecutiveFailures, lastHeartbeat, engineRunning}.
            // Read-only, never throws, headless-safe: no engine reads the
            // zero/idle status.
            //
            // ADDITIVE (m18-b, wire-lawful — the discardedRecovery precedent):
            // `mainActor: {responsive: true}` rides every response produced
            // HERE — self-evidently true, since this handler runs ON the main
            // actor. During a main-actor WEDGE this handler can't run at all;
            // the ControlServer's queue tier answers instead with `mainActor:
            // {responsive: false, wedgedForSeconds}` and the engine fields
            // omitted (they're produced on the main actor — see
            // ControlServer.wedgeIntercept). Same verb, one discoverable
            // surface, zero new commands.
            try params.rejectUnknownKeys([], verb: "engine.watchdogStatus")
            var watchdogPayload = try JSONValue(encoding: store.watchdogStatus())
            if case .object(var watchdogFields) = watchdogPayload {
                watchdogFields["mainActor"] = .object(["responsive": .bool(true)])
                watchdogPayload = .object(watchdogFields)
            }
            return .success(request.id, watchdogPayload)

        case "engine.auPrepareStats":
            // No params. Hosted-Audio-Unit PREPARE BOOKKEEPING for the live
            // graph (m23-br-1) — the registry's own ledger, read-only.
            // Response = EngineAUPrepareStats verbatim: {instrumentPrepares,
            // instrumentReleases, effectPrepares, effectReleases, tracks:
            // [{trackId, keyDigest?, status?}], effects: [{effectId,
            // keyDigest?, status?}]}.
            //
            // WHAT THE COUNTERS COUNT, because a caller SUBTRACTS them:
            // `*Prepares` counts prepare bodies that were NOT short-circuited
            // by the registry's idempotency guard — NOT successful
            // instantiations, so a re-prepare that ends `.missing`/`.failed`
            // still counts (it is still real re-prepare work, and a
            // storm of failing prepares is the worst storm there is).
            // `*Releases` counts only releases that removed a REAL live
            // instance, never a bookkeeping-only no-op. A config-change
            // re-prepare therefore bumps BOTH; a first prepare bumps only
            // the prepare counter. Two independent numbers is what lets a
            // caller tell "nothing happened" apart from "the counters broke".
            //
            // MONOTONE, and there is NO reset param — deliberately unlike
            // engine.performanceStats(reset:). Read before, read after,
            // subtract. The engine's AU registry is a `let`, so the counters
            // survive an engine rebuild/recovery (device change, watchdog
            // self-heal) for the lifetime of the engine object; only the LIVE
            // graph is counted, since offline renders build their own
            // registry per bounce.
            //
            // `keyDigest` is a stable 16-hex-char SHA256 digest of the LAST
            // ATTEMPTED prepare key (component + sample rate + saved plugin
            // state + sound-bank address) — i.e. the exact value the
            // idempotency guard compares against, so it is what CHANGES when
            // a re-prepare genuinely fires. Opaque: compare it across two
            // reads, never parse it. The raw key can NOT go on the wire (the
            // saved state is an arbitrary, possibly large, possibly private
            // plugin blob), and the digest is SHA256 rather than a Swift hash
            // precisely so it stays comparable across processes and runs.
            // Omitted when nothing has been attempted for that slot; `status`
            // ("pending"/"ready"/"missing"/"failed: <reason>") is omitted when
            // the registry holds no status for it.
            //
            // `inFlight` (m23-av) is the prepare bodies that have ARMED a
            // deadline race and not yet published an outcome: [{slot
            // ("instrument"/"effect"), id, component?, startedSecondsAgo,
            // deadlineSeconds, overdue}], sorted by (slot, id). It answers the
            // question `status` structurally cannot, because `status` is
            // written by the main actor and a wedged plugin is holding it.
            // `overdue` is DERIVED at read time (startedSecondsAgo >
            // deadlineSeconds), so it is never a second publisher of the
            // timeout verdict.
            //
            // ⚠️ `overdue` does NOT mean "the AU failed" (the work runs to
            // completion after a timeout), does NOT mean "the main actor is
            // wedged" (read `mainActor` for that — a prepare can be overdue on
            // a responsive machine under load), and says NOTHING about audio:
            // the render thread runs straight through a main-actor wedge, so
            // sound already playing keeps playing. An ABSENT slot means "no
            // prepare is between arming and publication", not "that slot is
            // fine". See `EngineAUPrepareStats.InFlightEntry`.
            //
            // ADDITIVE (m23-av, the m18-b watchdog precedent): `mainActor:
            // {responsive: true}` rides every response produced HERE —
            // self-evidently true, since this handler runs ON the main actor.
            // During a wedge this handler cannot run at all; the ControlServer's
            // queue tier answers instead with `mainActor: {responsive: false,
            // wedgedForSeconds}` plus `inFlight`, and the counters/tracks/effects
            // OMITTED (they are main-actor-produced — see
            // ControlServer.wedgeIntercept). The always-present `mainActor`
            // field is how a client tells the two forms apart. Same verb, one
            // discoverable surface, zero new commands.
            //
            // Read-only, never throws, headless-safe: no engine reads all
            // zeros with empty arrays. Arrays are sorted by id so two reads
            // diff positionally.
            try params.rejectUnknownKeys([], verb: "engine.auPrepareStats")
            var preparePayload = try JSONValue(encoding: store.auPrepareStats())
            if case .object(var prepareFields) = preparePayload {
                prepareFields["mainActor"] = .object(["responsive": .bool(true)])
                preparePayload = .object(prepareFields)
            }
            return .success(request.id, preparePayload)

        case "macro.songSkeleton":
            // params: genre (required — a SongSkeletonCatalog kebab name),
            // tempoBPM? (20-400; default = genre's), sections? (array of
            // {name, bars} — default = genre's layout), tracks? (array of
            // {name, kind, mixerPreset?} — default = genre's roster).
            // Scaffolds the whole
            // session (tempo, a genre track roster with mixer presets applied,
            // an "Arrangement" guide track of named empty MIDI clips, a real
            // SESSION MARKER at every section start — so `marker.list` returns
            // the beat map immediately and no caller has to re-derive it — and
            // the loop region) as ONE undoable edit — ADDITIVE, never wiping the
            // project (markers already present survive, merged into beat order).
            // Unknown genre → an error listing every valid name;
            // bad tempo/sections → field-named errors. Both surface via the
            // LocalizedError mapping. Response carries the full scaffold with
            // real, actionable ids (see `songSkeletonResult`).
            //
            // F8 FIX (m16-e, audit F8c): the store's OWN unknown-genre error
            // already lists every valid name — the gap the audit measured was the
            // OMITTED-genre case, where `params.require` threw the generic
            // "missing or invalid required param 'genre'" with no enumeration, so
            // a caller who omitted `genre` learned the valid values only after a
            // SECOND round trip (passing any string to trigger the store's own
            // teaching error). Naming the valid genres here too closes that gap.
            //
            // `tracks` (additive optional param — NOT a new verb) overrides the
            // GENRE ROSTER ONLY. The "Arrangement" guide track is still appended
            // LAST with its per-section clips and markers: the beat map is what
            // the macro exists for, so no override can suppress or displace it.
            // `genre` stays REQUIRED even with a full roster override — it
            // supplies the default tempo and keeps the enum discoverable.
            try params.rejectUnknownKeys(
                ["genre", "tempoBPM", "sections", "tracks"], verb: "macro.songSkeleton")
            guard let genre = params["genre"]?.stringValue else {
                let valid = SongSkeletonCatalog.names.joined(separator: ", ")
                throw ControlError("missing or invalid required param 'genre' — valid: \(valid)")
            }
            let skeletonTempo = params["tempoBPM"]?.doubleValue
            let skeletonSections = try parseSkeletonSections(params["sections"])
            let skeletonTracks = try parseSkeletonTracks(params["tracks"])
            let skeleton = try store.applySongSkeleton(
                genre: genre, tempoBPM: skeletonTempo, sections: skeletonSections,
                tracks: skeletonTracks)
            return .success(request.id, songSkeletonResult(skeleton))

        case "automation.addLane":
            // params: trackId (required — a track UUID, or the "master"
            // sentinel, m15-c), target (required) — the SAME
            // {type: "volume"|"pan"|"sendLevel"|"effectParam", sendId?,
            // effectId?, param?} shape AutomationTarget itself reads/writes on
            // the wire and on disk (see parseAutomationTarget — no hand-parsed
            // duplicate of that shape here). Idempotent per target: a repeat
            // call for a target that already has a lane on this track returns
            // the EXISTING lane unchanged (no new edit/undo step). v0 rejects
            // `.sendLevel` and `.effectParam` on an Audio Unit effect
            // (automationTargetNotSupported — an honest deferral, not a silent
            // no-op); any other unresolvable target (unknown send/effect id, or
            // an unknown/empty effect param name) → automationTargetUnresolvable;
            // unknown track → trackNotFound. trackId:"master" (m15-c) targets
            // the project-level MASTER VOLUME lane — {type:"volume"} ONLY; any
            // other target → masterAutomationVolumeOnly, a teaching error
            // naming where those lanes live. All surface via the
            // LocalizedError mapping. Response: {"lane": {id, target, points,
            // isEnabled}} either way.
            try params.rejectUnknownKeys(
                ["trackId", "target"], verb: "automation.addLane")
            let addLaneTarget = try parseAutomationTarget(params["target"])
            switch try params.parseFXTarget() {
            case .track(let addLaneTrackID):
                let addedLane = try store.addAutomationLane(
                    trackID: addLaneTrackID, target: addLaneTarget)
                return .success(request.id, .object(["lane": try JSONValue(encoding: addedLane)]))
            case .master:
                let addedLane = try store.addMasterAutomationLane(target: addLaneTarget)
                return .success(request.id, .object(["lane": try JSONValue(encoding: addedLane)]))
            }

        case "automation.removeLane":
            // params: trackId (required — a track UUID or "master", m15-c),
            // laneId (required UUID). automationLaneNotFound/trackNotFound
            // surface via the LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["trackId", "laneId"], verb: "automation.removeLane")
            let removeLaneID = try params.requireLaneID()
            switch try params.parseFXTarget() {
            case .track(let removeLaneTrackID):
                try store.removeAutomationLane(trackID: removeLaneTrackID, laneID: removeLaneID)
            case .master:
                try store.removeMasterAutomationLane(laneID: removeLaneID)
            }
            return .success(request.id)

        case "automation.setPoints":
            // params: trackId (required — a track UUID or "master", m15-c),
            // laneId (required UUID), points (required array of {beat >= 0,
            // value, curve?} — see parseAutomationPoints, which decodes each
            // element through AutomationPoint's OWN Codable so a malformed
            // entry names its index; an omitted curve defaults "linear").
            // WHOLE-ARRAY replace (the clip-notes precedent) — the store
            // re-canonicalizes (sorted by beat, equal-beat dedupe last-wins),
            // clamps every value to the target's live range (master: the
            // masterVolume range 0...2), and trims silently to the newest 4096
            // points when the array is over cap. automationLaneNotFound/
            // trackNotFound surface via the LocalizedError mapping. Response:
            // {"lane": {id, target, points, isEnabled}}.
            try params.rejectUnknownKeys(
                ["trackId", "laneId", "points"], verb: "automation.setPoints")
            let setPointsLaneID = try params.requireLaneID()
            guard let rawPoints = params["points"] else {
                throw ControlError("missing or invalid required param 'points'")
            }
            let parsedPoints = try parseAutomationPoints(rawPoints)
            let pointedLane: AutomationLane
            switch try params.parseFXTarget() {
            case .track(let setPointsTrackID):
                pointedLane = try store.setAutomationPoints(
                    trackID: setPointsTrackID, laneID: setPointsLaneID, points: parsedPoints)
            case .master:
                pointedLane = try store.setMasterAutomationPoints(
                    laneID: setPointsLaneID, points: parsedPoints)
            }
            return .success(request.id, .object(["lane": try JSONValue(encoding: pointedLane)]))

        case "automation.setLaneEnabled":
            // params: trackId (required — a track UUID or "master", m15-c),
            // laneId (required UUID), enabled (required bool) — toggles the
            // lane between read (drawn curve) and manual (fader/knob) without
            // touching its points. automationLaneNotFound/trackNotFound
            // surface via the LocalizedError mapping. Response: {"lane": {...}}.
            try params.rejectUnknownKeys(
                ["trackId", "laneId", "enabled"], verb: "automation.setLaneEnabled")
            let setEnabledLaneID = try params.requireLaneID()
            let laneEnabled = try params.require("enabled", \.boolValue)
            let enabledLane: AutomationLane
            switch try params.parseFXTarget() {
            case .track(let setEnabledTrackID):
                enabledLane = try store.setAutomationLaneEnabled(
                    trackID: setEnabledTrackID, laneID: setEnabledLaneID, laneEnabled)
            case .master:
                enabledLane = try store.setMasterAutomationLaneEnabled(
                    laneID: setEnabledLaneID, laneEnabled)
            }
            return .success(request.id, .object(["lane": try JSONValue(encoding: enabledLane)]))

        case "clip.addAudio":
            try params.rejectUnknownKeys(
                ["trackId", "path", "atBeat"], verb: "clip.addAudio")
            let id = try params.requireTrackID()
            let rawPath = try params.require("path", \.stringValue)
            let path = (rawPath as NSString).expandingTildeInPath
            let atBeat = params["atBeat"]?.doubleValue
            let clip = try store.importAudio(
                url: URL(fileURLWithPath: path), toTrack: id, atBeat: atBeat
            )
            return .success(request.id, try JSONValue(encoding: clip))

        case "clip.addMIDI":
            // params: trackId (required, must be an instrument track), name?,
            // atBeat? (>= 0), lengthBeats? (> 0), notes? (array — see parseNotes;
            // omitted/[] = an empty clip). trackNotFound/
            // midiClipsRequireInstrumentTrack surface via the LocalizedError map.
            try params.rejectUnknownKeys(
                ["trackId", "name", "atBeat", "lengthBeats", "notes"], verb: "clip.addMIDI")
            let midiTrackID = try params.requireTrackID()
            let midiName = params["name"]?.stringValue
            let midiAtBeat = params["atBeat"]?.doubleValue
            if let midiAtBeat, midiAtBeat < 0 {
                throw ControlError("'atBeat' must be >= 0")
            }
            let midiLength = params["lengthBeats"]?.doubleValue
            if let midiLength, midiLength <= 0 {
                throw ControlError("'lengthBeats' must be > 0")
            }
            let midiNotes = try params["notes"].map { try parseNotes($0) } ?? []
            let midiClip = try store.addMIDIClip(
                toTrack: midiTrackID, name: midiName, atBeat: midiAtBeat,
                lengthBeats: midiLength, notes: midiNotes
            )
            return .success(request.id, try JSONValue(encoding: midiClip))

        case "clip.setNotes":
            // params: clipId (required UUID), notes (required array, may be []).
            // clipNotFound/notAMIDIClip surface via the LocalizedError mapping.
            //
            // ⭐ THE CLIP ID SURVIVES (m26-o). This verb addresses the clip BY
            // id and edits its notes in place — it never creates a replacement
            // — so every id a caller is holding stays valid across a full
            // replace, as does the clip's start/length and every other field.
            // Worth stating because the whole-array semantics read as
            // destructive: an agent in the 2026-08-17 field report correctly
            // refused to edit velocities when `clip.getNotes` was unavailable,
            // reasoning that writing without reading could silently drop
            // notes. That caution is right in general, and the supported
            // fallback is RE-AUTHORING the clip in full when you are the
            // source of its content — the ids downstream work depends on do
            // not move.
            try params.rejectUnknownKeys(
                ["clipId", "notes"], verb: "clip.setNotes")
            let setClipID = try params.requireClipID()
            guard let setNotesValue = params["notes"] else {
                throw ControlError("missing or invalid required param 'notes'")
            }
            let setNotes = try parseNotes(setNotesValue)
            let updatedClip = try store.setClipNotes(clipID: setClipID, notes: setNotes)
            return .success(request.id, try JSONValue(encoding: updatedClip))

        case "clip.getNotes":
            // params: clipId (required UUID). fromBeat/toBeat? — CLIP-RELATIVE
            // beats (same frame as a note's startBeat: 0 = the clip's own
            // start, NOT the timeline). A note is included when its startBeat
            // is >= fromBeat and < toBeat (HALF-OPEN on the beat range).
            // pitchMin/pitchMax? — integers 0...127, INCLUSIVE both ends.
            // fromBeat > toBeat or pitchMin > pitchMax is a field-named error.
            //
            // STRICTLY READ-ONLY (the point of this verb): no performEdit, no
            // engine call, no undo entry, no dirty flag, no coalescing — reads
            // `store.tracks` directly, the note.audition precedent. Contrast
            // with the old "peek" workaround, clip.humanize {timingBeats:0,
            // velocityRange:0}: `ProjectStore.performEdit` skips the undo
            // journal entry there too (its `captureEditState() != before`
            // guard sees a byte-identical clip when both jitter axes are
            // exactly zero), but it STILL runs `markDirty()` and
            // `engine?.tracksDidChange(tracks)` unconditionally inside the
            // same call — real, wasted work this verb performs none of.
            // clipNotFound/notAMIDIClip surface via the LocalizedError
            // mapping (same messages clip.setNotes gives).
            //
            // Response: {clipId, trackId, clipName, clipStartBeat,
            // clipLengthBeats, totalNotes, returnedNotes, notes}. `totalNotes`
            // is the clip's UNFILTERED count (load-bearing: it's the only way
            // a caller notices it filtered before a later whole-array
            // clip.setNotes would silently drop the notes it never saw).
            // `notes` are ordered by startBeat then pitch and use the EXACT
            // clip.setNotes/clip.addMIDI shape (id, pitch, velocity,
            // startBeat, lengthBeats) via the same MIDINote Codable encoder,
            // so get -> edit -> clip.setNotes round-trips byte-for-byte.
            try params.rejectUnknownKeys(
                ["clipId", "fromBeat", "toBeat", "pitchMin", "pitchMax"], verb: "clip.getNotes")
            let getNotesClipID = try params.requireClipID()
            // `optionalNumber`, NOT a bare `?.doubleValue`: a wrong-typed
            // fromBeat/toBeat (`"8"`) must be a field-named error, never a
            // silently DROPPED filter. Dropping one is the worst failure this
            // verb has — the caller reads `returnedNotes` as "what matched my
            // range" and gets the whole clip, then whole-array-replaces from a
            // window it never actually asked for.
            let getNotesFromBeat = try Self.optionalNumber(params["fromBeat"], "'fromBeat'")
            let getNotesToBeat = try Self.optionalNumber(params["toBeat"], "'toBeat'")
            if let getNotesFromBeat, let getNotesToBeat, getNotesFromBeat > getNotesToBeat {
                throw ControlError("'fromBeat' must be <= 'toBeat'")
            }
            let getNotesPitchMin = try Self.optionalPitch(params["pitchMin"], "'pitchMin'")
            let getNotesPitchMax = try Self.optionalPitch(params["pitchMax"], "'pitchMax'")
            if let getNotesPitchMin, let getNotesPitchMax, getNotesPitchMin > getNotesPitchMax {
                throw ControlError("'pitchMin' must be <= 'pitchMax'")
            }
            guard let getNotesTrack = store.tracks.first(where: { track in
                track.clips.contains(where: { $0.id == getNotesClipID })
            }) else {
                throw ProjectError.clipNotFound(getNotesClipID)
            }
            guard let getNotesClip = getNotesTrack.clips.first(where: { $0.id == getNotesClipID }) else {
                throw ProjectError.clipNotFound(getNotesClipID)
            }
            guard let getNotesAllNotes = getNotesClip.notes else {
                throw ProjectError.notAMIDIClip(getNotesClipID, verb: "clip.getNotes")
            }
            var getNotesFiltered = getNotesAllNotes
            if let getNotesFromBeat {
                getNotesFiltered = getNotesFiltered.filter { $0.startBeat >= getNotesFromBeat }
            }
            if let getNotesToBeat {
                getNotesFiltered = getNotesFiltered.filter { $0.startBeat < getNotesToBeat }
            }
            if let getNotesPitchMin {
                getNotesFiltered = getNotesFiltered.filter { $0.pitch >= getNotesPitchMin }
            }
            if let getNotesPitchMax {
                getNotesFiltered = getNotesFiltered.filter { $0.pitch <= getNotesPitchMax }
            }
            let getNotesOrdered = MIDINote.canonicallyOrdered(getNotesFiltered)
            return .success(request.id, .object([
                "clipId": .string(getNotesClip.id.uuidString),
                "trackId": .string(getNotesTrack.id.uuidString),
                "clipName": .string(getNotesClip.name),
                "clipStartBeat": .number(getNotesClip.startBeat),
                "clipLengthBeats": .number(getNotesClip.lengthBeats),
                "totalNotes": .number(Double(getNotesAllNotes.count)),
                "returnedNotes": .number(Double(getNotesOrdered.count)),
                "notes": try JSONValue(encoding: getNotesOrdered),
            ]))

        case "clip.remove":
            // params: clipId (required UUID). Removes an audio or MIDI clip.
            // clipNotFound surfaces via the LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["clipId"], verb: "clip.remove")
            let removeClipID = try params.requireClipID()
            let removedClip = try store.removeClip(id: removeClipID)
            return .success(request.id, try JSONValue(encoding: removedClip))

        case "clip.split":
            // params: trackId (required), clipId (required), atBeat (required)
            // — a TIMELINE beat that must fall STRICTLY inside the clip
            // (invalidClipEdit otherwise, naming the clip and its span).
            // The left half keeps the clip's id; the right half is a fresh
            // clip (new id) inserted right after it. One undo step, no
            // coalescing. trackNotFound/clipNotFound surface via the
            // LocalizedError mapping. Response: {"first": {...clip...},
            // "second": {...clip...}}.
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "atBeat"], verb: "clip.split")
            let splitTrackID = try params.requireTrackID()
            let splitClipID = try params.requireClipID()
            let splitAtBeat = try params.require("atBeat", \.doubleValue)
            let (splitFirst, splitSecond) = try store.splitClip(
                trackId: splitTrackID, clipId: splitClipID, atBeat: splitAtBeat)
            return .success(request.id, .object([
                "first": try JSONValue(encoding: splitFirst),
                "second": try JSONValue(encoding: splitSecond),
            ]))

        case "clip.trim":
            // params: trackId (required), clipId (required), newStartBeat
            // (required, clamped >= 0), newLengthBeats (required, clamped >=
            // ProjectStore.minClipLengthBeats). The clip's CONTENT stays fixed
            // on the timeline — only the visible window moves; MIDI notes
            // outside the new window are dropped/truncated and fades
            // re-clamp. Coalesces under clip.trim:<clipId> so a drag of the
            // edge is one undo step. trackNotFound/clipNotFound surface via
            // the LocalizedError mapping. Response: the updated clip.
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "newStartBeat", "newLengthBeats"], verb: "clip.trim")
            let trimTrackID = try params.requireTrackID()
            let trimClipID = try params.requireClipID()
            let trimNewStartBeat = try params.require("newStartBeat", \.doubleValue)
            let trimNewLengthBeats = try params.require("newLengthBeats", \.doubleValue)
            let trimmedClip = try store.trimClip(
                trackId: trimTrackID, clipId: trimClipID,
                newStartBeat: trimNewStartBeat, newLengthBeats: trimNewLengthBeats)
            return .success(request.id, try JSONValue(encoding: trimmedClip))

        case "clip.fitToContent":
            // params: trackId (required), clipId (required). Trims the clip's
            // TRAILING edge to the end of its actual content (m21-d) — MIDI: the
            // last note's end beat (an empty clip is an honest no-op); audio:
            // the source file's remaining duration from the clip's current
            // startOffsetSeconds, tempo-map- and stretch-aware. The leading edge
            // never moves; length floors at ProjectStore.minClipLengthBeats.
            // Comp members are rejected (clipInTakeGroup). trackNotFound/
            // clipNotFound surface via the LocalizedError mapping. Response: the
            // updated clip's fields PLUS a `changed` flag (false when the clip
            // already fit its content exactly — nothing edited, no undo entry).
            try params.rejectUnknownKeys(
                ["trackId", "clipId"], verb: "clip.fitToContent")
            let fitTrackID = try params.requireTrackID()
            let fitClipID = try params.requireClipID()
            let fitResult = try store.fitClipToContent(trackId: fitTrackID, clipId: fitClipID)
            var fitObject = try JSONValue(encoding: fitResult.clip).objectValue ?? [:]
            fitObject["changed"] = .bool(fitResult.changed)
            return .success(request.id, .object(fitObject))

        case "clip.move":
            // params: trackId (required), clipId (required), toStartBeat
            // (required, clamped >= 0). Same-track only in v0. Coalesces
            // under clip.move:<clipId> so a drag is one undo step.
            //
            // OVERLAP POLICY (m11-d — the settled "no SILENT overlap of ordinary
            // same-track clips" invariant): when the moved clip lands over an
            // ordinary same-track clip, the STATIONARY clip yields the covered
            // region (trim-window semantics — audio source offset advances, MIDI
            // notes drop/truncate; a move landing strictly inside trims the
            // stationary clip's tail; a fully-covered or sub-minimum remnant is
            // REMOVED). Take-group / comp members are exempt. A
            // previously-crossfaded clip carries NO special bookkeeping — the
            // trim runs against current boundaries and any surviving fades stay
            // as plain per-clip fades. All of it rides the move's single undo
            // step. trackNotFound/clipNotFound surface via the LocalizedError
            // mapping. Response: the updated clip's fields PLUS additive
            // `trimmed:[clipId…]` and `removed:[clipId…]` arrays naming the
            // stationary clips the policy edited (empty when the move hit free
            // space).
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "toStartBeat"], verb: "clip.move")
            let moveTrackID = try params.requireTrackID()
            let moveClipID = try params.requireClipID()
            let moveToStartBeat = try params.require("toStartBeat", \.doubleValue)
            let moveResult = try store.moveClip(
                trackId: moveTrackID, clipId: moveClipID, toStartBeat: moveToStartBeat)
            var moveObject = try JSONValue(encoding: moveResult.clip).objectValue ?? [:]
            moveObject["trimmed"] = .array(moveResult.trimmedClipIDs.map { .string($0.uuidString) })
            moveObject["removed"] = .array(moveResult.removedClipIDs.map { .string($0.uuidString) })
            return .success(request.id, .object(moveObject))

        case "clip.duplicate":
            // params: clipId (required). toStartBeat? (>= 0) — omitted appends
            // FLUSH after the source clip's tail; toTrackId? — omitted duplicates
            // onto the source's own track, else a value-copy lands on that track
            // (type-checked by content: a MIDI clip needs an instrument track, an
            // audio clip an audio track). VALUE-COPIES everything (media/notes,
            // gain, fades + curves, gain envelope, stretch/pitch, AI flag) under a
            // fresh id; the source may not be a take/comp member.
            //
            // OVERLAP POLICY (m13-b): the new clip lands through the ONE
            // no-silent-overlap choke point as the active window — a duplicate
            // dropped onto an occupied region TRIMS the ordinary residents it
            // covers (never a silent +6 dB overlap); take members stack (exempt).
            // ONE undo. clipNotFound/trackNotFound/midiClipsRequireInstrumentTrack/
            // trackKindUnsupported surface via the LocalizedError mapping.
            // Response: the NEW clip's fields (the track.add/clip.addMIDI unwrapped
            // convention) PLUS additive `trimmed:[clipId…]` / `removed:[clipId…]`
            // arrays naming the residents the overlap policy edited (the clip.move
            // shape).
            try params.rejectUnknownKeys(
                ["clipId", "toStartBeat", "toTrackId"], verb: "clip.duplicate")
            let dupClipID = try params.requireClipID()
            let dupToStartBeat = params["toStartBeat"]?.doubleValue
            if let dupToStartBeat, dupToStartBeat < 0 {
                throw ControlError("'toStartBeat' must be >= 0")
            }
            let dupToTrackID: UUID?
            switch params["toTrackId"] {
            case .none:
                dupToTrackID = nil
            case .some(.string(let raw)):
                guard let parsed = UUID(uuidString: raw) else {
                    throw ControlError("'toTrackId' is not a valid UUID: \(raw)")
                }
                dupToTrackID = parsed
            case .some:
                throw ControlError("'toTrackId' must be a string")
            }
            let dupResult = try store.duplicateClip(
                clipId: dupClipID, toStartBeat: dupToStartBeat, toTrackId: dupToTrackID)
            var dupObject = try JSONValue(encoding: dupResult.clip).objectValue ?? [:]
            dupObject["trimmed"] = .array(dupResult.trimmedClipIDs.map { .string($0.uuidString) })
            dupObject["removed"] = .array(dupResult.removedClipIDs.map { .string($0.uuidString) })
            return .success(request.id, .object(dupObject))

        case "clip.crossfade":
            // params: trackId (required), clipId (required), otherClipId
            // (required), lengthBeats (required, > 0). Crossfades two AUDIO clips
            // on ONE track — the explicit tool that SANCTIONS a same-track
            // overlap (every other path upholds clip.move's no-silent-overlap
            // invariant). The two ids may be given in either order; the
            // earlier-starting clip is the left (fade-OUT) side, the later is the
            // right (fade-IN) side. The clips must be ADJACENT (right.start ==
            // left.end) OR already overlapping by ≤ lengthBeats (an eligibility
            // error names why otherwise). ADJACENT → the overlap is created of
            // exactly lengthBeats, split symmetrically by extending the left
            // clip's tail and the right clip's head into their surrounding source
            // audio (time-aligned, so the equal-power sum reconstructs the
            // original); if either side lacks material, crossfadeNeedsMaterial
            // names that clip/side. ALREADY OVERLAPPING → the existing overlap is
            // KEPT and only the fades are applied (legacy-overlap normalization).
            // Both fades are FadeCurve.equalPower (summing to unit power) spanning
            // EXACTLY the final overlap; each clip's OTHER fade is preserved. ONE
            // undo step ("Crossfade Clips"). Audio only, comp members rejected.
            // Response: {left: clip, right: clip, overlapBeats: Number}.
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "otherClipId", "lengthBeats"], verb: "clip.crossfade")
            let xfTrackID = try params.requireTrackID()
            let xfClipID = try params.requireClipID()
            let xfOtherClipID = try params.requireUUID("otherClipId")
            let xfLengthBeats = try params.require("lengthBeats", \.doubleValue)
            let xfResult = try store.crossfadeClips(
                trackId: xfTrackID, clipId: xfClipID,
                otherClipId: xfOtherClipID, lengthBeats: xfLengthBeats)
            return .success(request.id, .object([
                "left": try JSONValue(encoding: xfResult.left),
                "right": try JSONValue(encoding: xfResult.right),
                "overlapBeats": .number(xfResult.overlapBeats),
            ]))

        case "clip.setGain":
            // params: trackId (required), clipId (required), gainDb
            // (required, clamped to Clip.gainDbRange -72...24). Coalesces
            // under clip.gain:<clipId> so a knob scrub is one undo step.
            // trackNotFound/clipNotFound surface via the LocalizedError
            // mapping. Response: the updated clip.
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "gainDb"], verb: "clip.setGain")
            let gainTrackID = try params.requireTrackID()
            let gainClipID = try params.requireClipID()
            let gainDb = try params.require("gainDb", \.doubleValue)
            let gainedClip = try store.setClipGain(
                trackId: gainTrackID, clipId: gainClipID, gainDb: gainDb)
            return .success(request.id, try JSONValue(encoding: gainedClip))

        case "clip.setGainEnvelope":
            // params: trackId (required), clipId (required), points (optional
            // array of {beat, gainDb}). An OMITTED or EMPTY `points` CLEARS the
            // envelope (back to static-gain-plus-fades). Each `beat` is
            // CLIP-RELATIVE (>= 0, clamped into [0, lengthBeats]); each `gainDb`
            // is clamped to Clip.gainDbRange -72..24. Points must be sorted
            // strictly ASCENDING by beat with no duplicates (a teaching error
            // names the offending index otherwise). The envelope MULTIPLIES on
            // top of the static gain and fades. Audio clips only — a MIDI clip
            // surfaces invalidClipEdit ("…gain envelopes apply to audio clips
            // only") verbatim. Coalesces under clip.gainEnv:<clipId> so a
            // breakpoint drag is one undo step. trackNotFound/clipNotFound
            // surface via the LocalizedError mapping. Response: the updated clip
            // (its stored, canonicalized envelope echoes back in gainEnvelope).
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "points"], verb: "clip.setGainEnvelope")
            let envTrackID = try params.requireTrackID()
            let envClipID = try params.requireClipID()
            let envPoints = try parseGainEnvelope(params["points"])
            let envelopedClip = try store.setClipGainEnvelope(
                trackId: envTrackID, clipId: envClipID, points: envPoints)
            return .success(request.id, try JSONValue(encoding: envelopedClip))

        // TODO(m16-b2 phase 3, mcp-integration-engineer): expose these two verbs
        // as MCP tools `clip_set_controller_lane` + `clip_remove_controller_lane`
        // (flat zod schema, no unions — the m15-c prose-sentinel law; teach
        // stepwise semantics, bend center 8192, built-ins honour bend+sustain
        // only, chase behaviour, poly-aftertouch deferred). See design-m16b §10.
        case "clip.setControllerLane":
            // params: clipId (required), type ("cc"|"pitchBend"|"channelPressure",
            // required), controller (required integer 0-127 IFF type=="cc"),
            // points (required non-empty array of {beat, value}). Creates or
            // REPLACES the clip's lane of that type WHOLESALE. `value` is RAW MIDI
            // — 0-16383 for pitchBend (8192 = center), 0-127 otherwise; STEPWISE
            // (a value holds until the next point, a ramp is a dense point run).
            // Pass an empty array is REJECTED (use clip.removeControllerLane to
            // delete a lane). Caps: <= 16384 points/lane, <= 16 lanes/clip (the
            // store's teaching errors). rejectUnknownKeys from day one (a creation
            // verb). MIDI clips only — an audio clip surfaces notAMIDIClip.
            // Coalesces under clip.controllerLane:<clipId>:<typeKey>. Response: the
            // updated clip (its stored lanes echo back in controllerLanes).
            try params.rejectUnknownKeys(
                ["clipId", "type", "controller", "points"], verb: "clip.setControllerLane")
            let laneClipID = try params.requireClipID()
            let laneType = try parseControllerType(params, requireController: true)
            let lanePoints = try parseControllerPoints(params["points"], type: laneType)
            let lanedClip = try store.setControllerLane(
                clipID: laneClipID, type: laneType, points: lanePoints)
            // m27: a lane the track's instrument will NOT consume comes back
            // with a `warnings` sentence naming the controller and the reason
            // (the media-import idiom above). The lane is still stored and the
            // call still succeeds — but accepting data we discard, silently,
            // is exactly the defect that produced seven inert CC11 lanes.
            var lanedResult = try JSONValue(encoding: lanedClip)
            if let laneWarning = store.controllerLaneWarning(
                clipID: laneClipID, type: laneType),
               case .object(var lanedObject) = lanedResult {
                lanedObject["warnings"] = .array([.string(laneWarning)])
                lanedResult = .object(lanedObject)
            }
            return .success(request.id, lanedResult)

        case "clip.removeControllerLane":
            // params: clipId (required), type ("cc"|"pitchBend"|"channelPressure",
            // required), controller (required integer 0-127 IFF type=="cc").
            // Removes the clip's lane of that type; an unknown lane surfaces a
            // teaching error listing the clip's existing lanes. rejectUnknownKeys
            // from day one. MIDI clips only. Response: the updated clip.
            try params.rejectUnknownKeys(
                ["clipId", "type", "controller"], verb: "clip.removeControllerLane")
            let rmClipID = try params.requireClipID()
            let rmType = try parseControllerType(params, requireController: true)
            let rmClip = try store.removeControllerLane(clipID: rmClipID, type: rmType)
            return .success(request.id, try JSONValue(encoding: rmClip))

        case "clip.setFades":
            // params: trackId (required), clipId (required), fadeInBeats
            // (required), fadeOutBeats (required), fadeInCurve?/
            // fadeOutCurve? ("linear"|"equalPower", default "linear" — see
            // parseFadeCurve, which names the OFFENDING FIELD on a bad
            // string). WHOLESALE replace of both fades (the
            // automation.setPoints precedent): the store clamps each to
            // [0, lengthBeats] and proportionally reduces both when their sum
            // exceeds the clip length. Coalesces under clip.fades:<clipId> so
            // a fade-handle drag is one undo step. trackNotFound/clipNotFound
            // surface via the LocalizedError mapping. Response: the updated
            // clip.
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "fadeInBeats", "fadeOutBeats", "fadeInCurve",
                    "fadeOutCurve"], verb: "clip.setFades")
            let fadesTrackID = try params.requireTrackID()
            let fadesClipID = try params.requireClipID()
            let fadeInBeats = try params.require("fadeInBeats", \.doubleValue)
            let fadeOutBeats = try params.require("fadeOutBeats", \.doubleValue)
            let fadeInCurve = try parseFadeCurve(params["fadeInCurve"], field: "fadeInCurve")
            let fadeOutCurve = try parseFadeCurve(params["fadeOutCurve"], field: "fadeOutCurve")
            let fadedClip = try store.setClipFades(
                trackId: fadesTrackID, clipId: fadesClipID,
                fadeInBeats: fadeInBeats, fadeOutBeats: fadeOutBeats,
                fadeInCurve: fadeInCurve, fadeOutCurve: fadeOutCurve)
            return .success(request.id, try JSONValue(encoding: fadedClip))

        case "clip.setStretch":
            // params: trackId (required), clipId (required), ratio?/semitones?/
            // formantPreserve? — each OPTIONAL, an omitted field KEEPS the
            // clip's current value (the store's nil = keep-current agent
            // surface). `ratio` (absolute, tempo-independent) clamps to
            // Clip.stretchRatioRange 0.25...4; `semitones` clamps to ±24.
            // Audio clips only — a MIDI clip surfaces invalidClipEdit verbatim.
            // Coalesces under clip.stretch:<clipId>. trackNotFound/clipNotFound
            // surface via the LocalizedError mapping. Response: the updated clip
            // (the stretch fields ride Clip's Codable when non-default).
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "ratio", "semitones", "formantPreserve"], verb: "clip.setStretch")
            let stretchTrackID = try params.requireTrackID()
            let stretchClipID = try params.requireClipID()
            let stretchRatio = params["ratio"]?.doubleValue
            let stretchSemitones = params["semitones"]?.doubleValue
            let stretchFormant = params["formantPreserve"]?.boolValue
            let stretchedClip = try store.setClipStretch(
                trackId: stretchTrackID, clipId: stretchClipID,
                ratio: stretchRatio, semitones: stretchSemitones,
                formantPreserve: stretchFormant)
            return .success(request.id, try JSONValue(encoding: stretchedClip))

        case "clip.stretchToLength":
            // params: trackId (required), clipId (required), lengthBeats
            // (required) — the stretch-HANDLE compound: retargets the clip to
            // the new timeline length (floored at ProjectStore.minClipLengthBeats)
            // while HOLDING the source window constant (stretchRatio scales by
            // the length change; on ratio clamp the length re-derives so the
            // window survives). Fades re-clamp. Audio clips only (MIDI surfaces
            // invalidClipEdit). Coalesces under the SAME clip.stretch:<clipId>
            // key as clip.setStretch. Response: the updated clip.
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "lengthBeats"], verb: "clip.stretchToLength")
            let stretchLenTrackID = try params.requireTrackID()
            let stretchLenClipID = try params.requireClipID()
            let stretchToLength = try params.require("lengthBeats", \.doubleValue)
            let stretchedToLenClip = try store.stretchClip(
                trackId: stretchLenTrackID, clipId: stretchLenClipID,
                toLengthBeats: stretchToLength)
            return .success(request.id, try JSONValue(encoding: stretchedToLenClip))

        case "clip.deleteTimeRange":
            // params: clipId (required), startBeat (required), lengthBeats
            // (required). CLIP-LOCAL beats (note space, consistent with
            // clip.setNotes) — NOT timeline beats. Excises [startBeat,
            // startBeat+lengthBeats) from a MIDI clip and closes the gap: notes
            // after shift left, notes whose onset is inside are dropped, a note
            // crossing in from before keeps its head (its overlap spliced out).
            // The clip's lengthBeats shrinks by the excised amount (floored at one
            // beat / the last remaining note's extent). ONE undo step. MIDI clips
            // only. clipNotFound/notAMIDIClip/invalidClipEdit (non-positive length
            // or startBeat outside [0, lengthBeats)) surface via the LocalizedError
            // mapping. Response: the updated clip.
            try params.rejectUnknownKeys(
                ["clipId", "startBeat", "lengthBeats"], verb: "clip.deleteTimeRange")
            let delRangeClipID = try params.requireClipID()
            let delRangeStart = try params.require("startBeat", \.doubleValue)
            let delRangeLength = try params.require("lengthBeats", \.doubleValue)
            let delRangeClip = try store.deleteTimeRange(
                clipID: delRangeClipID, startBeat: delRangeStart, lengthBeats: delRangeLength)
            return .success(request.id, try JSONValue(encoding: delRangeClip))

        case "clip.insertTimeRange":
            // params: clipId (required), atBeat (required), lengthBeats (required).
            // CLIP-LOCAL beats (note space, consistent with clip.setNotes) — NOT
            // timeline beats. Inserts `lengthBeats` of silence at `atBeat` in a
            // MIDI clip: notes at/after atBeat shift right; a note crossing atBeat
            // keeps its start and length (silence lands after its onset). The clip
            // grows by lengthBeats. ONE undo step. MIDI clips only. clipNotFound/
            // notAMIDIClip/invalidClipEdit (non-positive length or atBeat outside
            // [0, lengthBeats]) surface via the LocalizedError mapping. Response:
            // the updated clip.
            try params.rejectUnknownKeys(
                ["clipId", "atBeat", "lengthBeats"], verb: "clip.insertTimeRange")
            let insRangeClipID = try params.requireClipID()
            let insRangeAt = try params.require("atBeat", \.doubleValue)
            let insRangeLength = try params.require("lengthBeats", \.doubleValue)
            let insRangeClip = try store.insertTimeRange(
                clipID: insRangeClipID, atBeat: insRangeAt, lengthBeats: insRangeLength)
            return .success(request.id, try JSONValue(encoding: insRangeClip))

        case "clip.quantize":
            // params: clipId (required), gridBeats (required, > 0 — grid in beats:
            // 1 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16), strength? (0...1, default 1 —
            // lerp toward the grid: 1 snaps fully, 0.5 halfway, 0 leaves notes),
            // swing? (50...75, default 50 — MPC swing: 50 straight, 75 max shuffle,
            // delays offbeat slots), quantizeEnds? (bool, default false — also snap
            // note ends). MIDI clips ONLY in v0 — an audio clip surfaces
            // quantizeRequiresMIDIClip verbatim (audio quantize is a later op); a
            // comp member surfaces clipInTakeGroup. Coalesces under
            // clip.quantize:<clipId> so a strength-slider scrub is one undo step.
            // clipNotFound surfaces via the LocalizedError mapping. Response: the
            // updated clip.
            //
            // groove? (M5 iii-g): optional ref — a built-in swing name
            // ("swing8:66"), a saved template id, or a saved template name —
            // resolved to QuantizeSettings.groove (parseQuantizeSettings →
            // resolveGrooveParam). When set it REPLACES the swing grid targets
            // (groove wins); an unknown ref is a field-named 'groove' error.
            try params.rejectUnknownKeys(
                ["clipId", "gridBeats", "strength", "swing", "quantizeEnds", "groove"], verb: "clip.quantize")
            let quantizeClipID = try params.requireClipID()
            let quantizeSettings = try parseQuantizeSettings(params)
            let quantizedClip = try store.quantizeClipNotes(
                clipId: quantizeClipID, settings: quantizeSettings)
            return .success(request.id, try JSONValue(encoding: quantizedClip))

        case "clip.humanize":
            // params: clipId (required), timingBeats? (0...0.25, default 0.02 —
            // max independent onset jitter in beats, ±this), velocityRange?
            // (0...64 integer, default 8 — max independent velocity jitter, ±this),
            // seed? (non-negative integer < 2^53 — omit to draw one),
            // legatoOverlapBeats? (0...0.25, default 0 = OFF) and maxGapBeats?
            // (0...4, default 0.125). Seeded, DETERMINISTIC "human feel": each
            // note's onset shifts by a uniform amount in [−timingBeats,
            // +timingBeats] (clamped inside the clip) and its velocity by a
            // uniform integer in [−velocityRange, +velocityRange] (clamped
            // 1...127); ids and array order are ALWAYS preserved, and so are
            // LENGTHS unless legatoOverlapBeats > 0 (m27-o ⓑ).
            //
            // The legato pass (RNG-free, so a seeded result is unchanged when it
            // is off): a note followed within maxGapBeats is lengthened to end
            // legatoOverlapBeats past the following onset — gaps close, joins
            // overlap. A LARGER gap is a rest (a breath) and is left untouched;
            // notes that already overlap are left untouched (the pass only ever
            // extends); the last onset is never extended; nothing is extended
            // past the clip end. ⚠️ It MASKS each note's fresh attack transient
            // under the previous note's tail — the engine has no legato-hold
            // mode, so every retrigger still happens (see the store method).
            // maxGapBeats WITHOUT a positive legatoOverlapBeats does nothing: it
            // is a ceiling on a pass that is not running.
            //
            // ONE undoable step ("Humanize"). MIDI clips ONLY — an audio clip
            // surfaces notAMIDIClip verbatim; clipNotFound via the LocalizedError
            // mapping. Response: the updated clip fields PLUS `seedUsed` (the
            // seed actually used — replay it, or a nil `seed`, to reproduce or
            // re-roll the take).
            try params.rejectUnknownKeys(
                ["clipId", "timingBeats", "velocityRange", "seed",
                 "legatoOverlapBeats", "maxGapBeats"], verb: "clip.humanize")
            let humanizeClipID = try params.requireClipID()
            let humanizeTiming = params["timingBeats"]?.doubleValue ?? 0.02
            guard (0...0.25).contains(humanizeTiming) else {
                throw ControlError("'timingBeats' must be between 0 and 0.25 (default 0.02 — max ± onset jitter in beats)")
            }
            let humanizeVelRaw = params["velocityRange"]?.doubleValue ?? 8
            guard (0...64).contains(humanizeVelRaw), humanizeVelRaw == humanizeVelRaw.rounded() else {
                throw ControlError("'velocityRange' must be an integer between 0 and 64 (default 8 — max ± velocity jitter)")
            }
            // Bounds VERBATIM in HumanizeModel.legatoBounds / legatoMaxGapBounds
            // (the panel must not be able to build a value this rejects), and the
            // default gap ceiling has ONE home in DAWCore.
            let humanizeLegato = params["legatoOverlapBeats"]?.doubleValue ?? 0
            guard (0...0.25).contains(humanizeLegato) else {
                throw ControlError("'legatoOverlapBeats' must be between 0 and 0.25 (default 0 = off — how far each note extends PAST the next note's start)")
            }
            let humanizeMaxGap = params["maxGapBeats"]?.doubleValue ?? HumanizeLegato.defaultMaxGapBeats
            guard (0...4).contains(humanizeMaxGap) else {
                throw ControlError("'maxGapBeats' must be between 0 and 4 (default 0.125 — a gap larger than this is a rest and is left alone)")
            }
            let humanizeSeed: UInt64?
            if let seedValue = params["seed"] {
                guard let seedDouble = seedValue.doubleValue,
                      seedDouble >= 0, seedDouble < 9_007_199_254_740_992,
                      seedDouble == seedDouble.rounded() else {
                    throw ControlError("'seed' must be a non-negative integer below 2^53 (omit to draw a random seed)")
                }
                humanizeSeed = UInt64(seedDouble)
            } else {
                humanizeSeed = nil
            }
            let humanized = try store.humanizeClipNotes(
                clipID: humanizeClipID,
                timingBeats: humanizeTiming,
                velocityRange: Int(humanizeVelRaw),
                seed: humanizeSeed,
                legatoOverlapBeats: humanizeLegato,
                maxGapBeats: humanizeMaxGap)
            var humanizeObj = try JSONValue(encoding: humanized.clip).objectValue ?? [:]
            humanizeObj["seedUsed"] = .number(Double(humanized.seedUsed))
            return .success(request.id, .object(humanizeObj))

        case "clip.detectTransients":
            // params: clipId (required), sensitivity? (0...1, default 0.5 —
            // higher finds more onsets). Offline spectral-flux transient
            // analysis of an AUDIO clip's SOURCE FILE (M5 iii-e), content-key
            // cached by the engine — geometry-free, so trims/splits never
            // re-analyze; repeat calls are sidecar hits. Read-only: no edit,
            // no undo entry, nothing persisted or snapshotted (pull-only).
            // Response: {transients: [{sourceSeconds, beat, strength}],
            // count} — window-filtered to the clip and beat-mapped at the
            // current tempo/stretch. A MIDI clip surfaces
            // transientsRequireAudioClip verbatim; headless surfaces
            // engineUnavailable; clipNotFound via the LocalizedError mapping.
            try params.rejectUnknownKeys(["clipId", "sensitivity"], verb: "clip.detectTransients")
            let transientClipID = try params.requireClipID()
            let transientSensitivity = params["sensitivity"]?.doubleValue ?? 0.5
            guard (0...1).contains(transientSensitivity) else {
                throw ControlError("'sensitivity' must be between 0 and 1 (0.5 = default; higher finds more onsets)")
            }
            let clipTransients = try await store.detectClipTransients(
                clipId: transientClipID, sensitivity: transientSensitivity)
            return .success(request.id, .object([
                "transients": try JSONValue(encoding: clipTransients),
                "count": .number(Double(clipTransients.count)),
            ]))

        case "clip.analyzeAudio":
            // params: clipId (required). Offline key/tempo/spectral-balance/
            // level analysis of an AUDIO clip's CURRENT SOURCE WINDOW
            // [startOffsetSeconds, +sourceWindowSeconds) (m21-e,
            // design-clip-analyze-audio §4-5), content-key cached by the
            // engine on (source path, window, analyzer version) — a trim
            // re-analyzes, a repeat call on the same window is a sidecar hit.
            // Read-only: no edit, no undo entry, nothing persisted or
            // snapshotted (pull-only, the detectTransients idiom). Results
            // are SOURCE-domain (before this clip's stretch/pitch); the
            // response echoes stretchRatio/pitchShiftSemitones and adds a
            // derived `playback {bpm, keyTonic, keyMode}` block ONLY for a
            // non-identity clip (omitted for stretch 1 / pitch 0). Honest
            // uncertainty throughout: `key.confidence`/`key.tonal` are NOT a
            // guarantee (percussion/atonal material reads tonal:false with
            // ranked guesses still attached); `tempo.bpm` is folded into the
            // 70-180 BPM lattice and is null when there's no periodic
            // evidence or the window is under 6 s; `tempo.steady` says
            // whether a single fixed project tempo can match the clip.
            // A MIDI clip surfaces analysisRequiresAudioClip verbatim; a
            // window under 1 s surfaces a teaching invalidClipEdit;
            // clipNotFound/engineUnavailable via the LocalizedError mapping.
            // Response: the store's ClipAudioAnalysisResult encoded verbatim
            // ({analysis: {...}, stretchRatio, pitchShiftSemitones,
            // playback?}).
            try params.rejectUnknownKeys(["clipId"], verb: "clip.analyzeAudio")
            let analyzeClipID = try params.requireClipID()
            let clipAnalysis = try await store.analyzeClipAudio(clipId: analyzeClipID)
            return .success(request.id, try JSONValue(encoding: clipAnalysis))

        case "clip.quantizeAudio":
            // params: trackId (required), clipId (required), gridBeats (required,
            // > 0), strength? (0...1, default 1), swing? (50...75, default 50),
            // sensitivity? (0...1, default 0.5 — detector knob), crossfadeMs?
            // (0...50 ms, default 10 — join crossfade width). Audio quantize v0
            // (M5 iii-f): detect the clip's transients on the engine (content-key
            // cached, off the render thread), slice at them, nudge each slice
            // toward the grid, and replace the clip with the slices in ONE
            // undo step — NO per-slice time-stretch. An audio clip ONLY: a MIDI
            // clip surfaces quantizeRequiresAudioClip verbatim; a non-identity
            // stretch surfaces audioQuantizeStretchUnsupported; a comp member
            // surfaces clipInTakeGroup; fewer than 2 usable transients surface
            // audioQuantizeNoTransients (nothing changes); headless surfaces
            // engineUnavailable; clipNotFound/trackNotFound via the LocalizedError
            // mapping. Response: {"clips": [...slices...]}.
            //
            // groove? (M5 iii-g): optional ref (built-in swing name, saved
            // template id, or name) resolved to settings.groove
            // (parseAudioQuantizeSettings → resolveGrooveParam); when set it
            // REPLACES the swing grid targets through the same QuantizeTarget the
            // MIDI path uses; an unknown ref is a field-named 'groove' error.
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "gridBeats", "strength", "swing", "sensitivity",
                    "crossfadeMs", "groove"], verb: "clip.quantizeAudio")
            let aqTrackID = try params.requireTrackID()
            let aqClipID = try params.requireClipID()
            let aqSettings = try parseAudioQuantizeSettings(params)
            let aqSlices = try await store.quantizeAudioClip(
                trackId: aqTrackID, clipId: aqClipID, settings: aqSettings)
            return .success(request.id, .object(["clips": try JSONValue(encoding: aqSlices)]))

        case "clip.detectPitch":
            // params: clipId (required). fromSeconds?/durationSeconds?
            // (SOURCE-FILE-absolute seconds — the clip.detectTransients/
            // clip.analyzeAudio domain; omitted fromSeconds defaults to the
            // clip's own window start, omitted durationSeconds defaults to
            // the rest of the clip's current window — see
            // ProjectStore.detectClipPitch's doc for the full contract and
            // the payload-arithmetic reasoning, PitchDetectionResult's doc
            // for why the default is deliberately unbounded).
            // confidenceThreshold? (0...1, default 0.9 —
            // PitchDetectionDefaults.defaultConfidenceThreshold, DUPLICATED
            // from DAWEngine's PitchAnalysisOptions since DAWCore cannot
            // import DAWEngine — kept in lockstep by
            // PitchDetectionDefaultsMatchTrackerTests).
            // silenceFloorDbfs? (default -75 dBFS — UNTUNED against real
            // vocal material; exposed specifically so a listening pass can
            // retune it without a code change, since judging pitch accuracy
            // BY EAR against a real recording is this item's open question).
            //
            // Wires m23-ap-2b's PitchTracker/SwiftF0PitchTracker seam (the
            // PROTOCOL, not the backend — nothing here names SwiftF0).
            // Read-only: no edit, no undo entry, nothing persisted (the
            // detectTransients/analyzeAudio idiom). NOT result-cached (see
            // ClipPitchAnalyzer's header for why — unlike
            // analyzeAudioContent's few-KB aggregates, a cached pitch result
            // can be hundreds of KB, a materially bigger caching commitment
            // this item does not make).
            //
            // HONEST ABSENCE ACROSS THE WIRE: each frame in the response is
            // {timeSeconds, frequencyHz?, confidence, levelDbfs?, absence?}
            // — an unvoiced frame OMITS frequencyHz (never 0, never a
            // sentinel) and CARRIES absence ("belowConfidence" |
            // "belowLevel" | "outOfRange") plus the measured
            // confidence/level that produced it. Frames are never dropped —
            // the uniform time grid is the point (segmentation reads holes
            // as signal, m23-ap-2b design §5.6.6).
            //
            // Registered via the strict-schema MCP wrapper despite being
            // read-only — the audio.profileFile precedent (real windowing
            // params worth typo-catching), not the clip.detectTransients
            // one (a single sensitivity knob).
            //
            // Response: {pitch: {frames: [...], frameCount, voicedFrameCount,
            // voicedFraction, frameRateHz, analysisSampleRateHz,
            // sourceSampleRateHz, windowStartSeconds, windowDurationSeconds,
            // confidenceThreshold, silenceFloorDbfs, minFrequencyHz,
            // maxFrequencyHz}, clipWindowDurationSeconds, stretchRatio,
            // pitchShiftSemitones}. stretchRatio/pitchShiftSemitones echo the
            // clip's state (SOURCE-domain numbers, before either — the
            // analyzeAudio precedent); no derived "playback" pitch curve is
            // computed (out of this item's scope — see ClipPitchDetection's
            // doc).
            //
            // m23-q §7.7 names clip.detectPitch as its own future Phase-1
            // verb ("runs detection, stores the segment set"): THIS response
            // is the raw per-frame contour, not a segment set. A future
            // segment-set field is an ADDITIVE field on this same response,
            // never a re-contract (see PitchDetectionResult's doc).
            //
            // Errors: clipNotFound / pitchDetectionRequiresAudioClip /
            // engineUnavailable surface via the LocalizedError mapping in
            // handle(_:); a missing backing file or a fromSeconds outside
            // the clip's current window are both a teaching invalidClipEdit.
            try params.rejectUnknownKeys(
                ["clipId", "fromSeconds", "durationSeconds", "confidenceThreshold",
                    "silenceFloorDbfs"], verb: "clip.detectPitch")
            let pitchClipID = try params.requireClipID()
            let pitchFromSeconds = params["fromSeconds"]?.doubleValue
            if let pitchFromSeconds, pitchFromSeconds < 0 {
                throw ControlError("'fromSeconds' must be >= 0")
            }
            let pitchDurationSeconds = params["durationSeconds"]?.doubleValue
            if let pitchDurationSeconds, pitchDurationSeconds <= 0 {
                throw ControlError("'durationSeconds' must be > 0")
            }
            let pitchConfidenceThreshold = params["confidenceThreshold"]?.doubleValue
                ?? PitchDetectionDefaults.defaultConfidenceThreshold
            guard (0...1).contains(pitchConfidenceThreshold) else {
                throw ControlError("'confidenceThreshold' must be between 0 and 1 (default 0.9)")
            }
            let pitchSilenceFloorDbfs = params["silenceFloorDbfs"]?.doubleValue
                ?? PitchDetectionDefaults.defaultSilenceFloorDbfs
            guard pitchSilenceFloorDbfs.isFinite else {
                throw ControlError("'silenceFloorDbfs' must be a finite number (default -75)")
            }
            let pitchResult = try await store.detectClipPitch(
                clipId: pitchClipID, fromSeconds: pitchFromSeconds,
                durationSeconds: pitchDurationSeconds,
                confidenceThreshold: pitchConfidenceThreshold,
                silenceFloorDbfs: pitchSilenceFloorDbfs)
            return .success(request.id, try JSONValue(encoding: pitchResult))

        case "arrange.insertBars":
            // params: atBar (required int >= 1, 1-BASED — bar 1 is the first bar,
            // beat 0), count (required int >= 1). PROJECT-WIDE: inserts `count`
            // empty METER-AWARE bars before atBar and shifts everything from that
            // barline rightward in ONE undo — every track's clips (a clip
            // straddling the point SPLITS), markers, the tempo AND meter maps,
            // automation, and the loop/punch regions. The inserted bars continue
            // the meter of the bar before the insertion point (a 6/8 region
            // inserts 6-beat bars). Refused mid-record and across a take group
            // (invalidArrangeEdit → flatten first) via the LocalizedError mapping.
            // Response: {atBeat, insertedBeats, beatsPerBar}.
            try params.rejectUnknownKeys(
                ["atBar", "count"], verb: "arrange.insertBars")
            let insAtBar = Int(try params.require("atBar", \.doubleValue))
            let insCount = Int(try params.require("count", \.doubleValue))
            let insResult = try store.insertBars(atBar: insAtBar, count: insCount)
            return .success(request.id, .object([
                "atBeat": .number(insResult.atBeat),
                "insertedBeats": .number(insResult.insertedBeats),
                "beatsPerBar": .number(Double(insResult.beatsPerBar)),
            ]))

        case "arrange.deleteBars":
            // params: fromBar (required int >= 1, 1-BASED), count (required int
            // >= 1). PROJECT-WIDE: removes `count` METER-AWARE bars starting at
            // fromBar and closes the gap in ONE undo. Clips fully inside are
            // removed (ids in `removedClipIds`); straddling clips are trimmed or
            // split-and-closed; markers inside the range are removed (ids in
            // `removedMarkerIds`); tempo/meter changes inside the range are
            // removed and the rest pull left; a loop/punch region swallowed by the
            // delete is disabled at the splice. A delete that would leave a meter
            // change off its barline is refused with a teaching error. Refused
            // mid-record and across a take group (invalidArrangeEdit) via the
            // LocalizedError mapping. Response: {fromBeat, deletedBeats,
            // removedClipIds, removedMarkerIds}.
            try params.rejectUnknownKeys(
                ["fromBar", "count"], verb: "arrange.deleteBars")
            let delFromBar = Int(try params.require("fromBar", \.doubleValue))
            let delCount = Int(try params.require("count", \.doubleValue))
            let delResult = try store.deleteBars(fromBar: delFromBar, count: delCount)
            return .success(request.id, .object([
                "fromBeat": .number(delResult.fromBeat),
                "deletedBeats": .number(delResult.deletedBeats),
                "removedClipIds": .array(delResult.removedClipIDs.map { .string($0.uuidString) }),
                "removedMarkerIds": .array(delResult.removedMarkerIDs.map { .string($0.uuidString) }),
            ]))

        case "take.group":
            // params: trackId (required), clipIds (required array of >= 2 clip id
            // strings), name? (string). Forms a take group from EXISTING
            // OVERLAPPING clips on the track (all audio or all MIDI, mixed
            // rejected) — the source clips are consumed into lanes (oldest =
            // lane 0) and removed from track.clips; the comp defaults to the
            // newest lane across the full range (newest wins). cannotGroup/
            // clipNotFound/trackNotFound surface via the LocalizedError mapping.
            // Response: {"group": {...}}.
            try params.rejectUnknownKeys(
                ["trackId", "clipIds", "name"], verb: "take.group")
            let groupTrackID = try params.requireTrackID()
            let groupClipIDs = try parseClipIDs(params["clipIds"])
            let groupName = params["name"]?.stringValue
            let group = try store.groupTakes(
                trackId: groupTrackID, clipIds: groupClipIDs, name: groupName)
            return .success(request.id, .object(["group": try JSONValue(encoding: group)]))

        case "take.setComp":
            // params: trackId (required), groupId (required), segments (required
            // array of {laneId, startBeat, endBeat} — see parseCompSegments,
            // which round-trips each element through CompSegment's OWN Codable so
            // the wire shape never drifts from persistence; a malformed element
            // names its index). WHOLESALE replace of the comp (the setClipNotes
            // precedent); the store validates lane ids/ordering/non-overlap,
            // clamps to the group range, and rebuilds the member clips.
            // Coalesces under take.comp:<groupId> so a comp-paint drag is one
            // undo step. invalidComp/takeGroupNotFound/trackNotFound surface via
            // the LocalizedError mapping. Response: {"group": {...}, "clips": [...]}
            // — the freshly rebuilt members (clips churn ids on every rebuild;
            // see spec §2 ASSUMPTION).
            try params.rejectUnknownKeys(
                ["trackId", "groupId", "segments"], verb: "take.setComp")
            let compTrackID = try params.requireTrackID()
            let compGroupID = try params.requireGroupID()
            let compSegments = try parseCompSegments(params["segments"])
            let compGroup = try store.setCompSegments(
                trackId: compTrackID, groupId: compGroupID, segments: compSegments)
            return .success(request.id, .object([
                "group": try JSONValue(encoding: compGroup),
                "clips": try memberClipsJSON(trackID: compTrackID, groupID: compGroupID),
            ]))

        case "take.select":
            // params: trackId (required), groupId (required), laneId (required)
            // — sugar for "comp = one full-range segment on this lane" (a quick
            // take swap). Shares take.setComp's take.comp:<groupId> coalescing
            // key. laneNotFound/takeGroupNotFound/trackNotFound surface via the
            // LocalizedError mapping. Response: {"group": {...}, "clips": [...]}.
            try params.rejectUnknownKeys(
                ["trackId", "groupId", "laneId"], verb: "take.select")
            let selectTrackID = try params.requireTrackID()
            let selectGroupID = try params.requireGroupID()
            let selectLaneID = try params.requireLaneID()
            let selectGroup = try store.selectTake(
                trackId: selectTrackID, groupId: selectGroupID, laneId: selectLaneID)
            return .success(request.id, .object([
                "group": try JSONValue(encoding: selectGroup),
                "clips": try memberClipsJSON(trackID: selectTrackID, groupID: selectGroupID),
            ]))

        case "take.removeLane":
            // params: trackId (required), groupId (required), laneId (required)
            // — deletes a take. Rejected while any comp segment references the
            // lane (laneInUse — change the comp first) and when it is the last
            // lane in the group (invalidComp — flatten to dissolve instead).
            // laneNotFound/takeGroupNotFound/trackNotFound surface via the
            // LocalizedError mapping. Response: {"group": {...}}.
            try params.rejectUnknownKeys(
                ["trackId", "groupId", "laneId"], verb: "take.removeLane")
            let removeLaneTrackID = try params.requireTrackID()
            let removeLaneGroupID = try params.requireGroupID()
            let removeLaneLaneID = try params.requireLaneID()
            let removeLaneGroup = try store.removeTakeLane(
                trackId: removeLaneTrackID, groupId: removeLaneGroupID, laneId: removeLaneLaneID)
            return .success(request.id, .object(["group": try JSONValue(encoding: removeLaneGroup)]))

        case "take.flatten":
            // params: trackId (required), groupId (required) — dissolves the
            // group: its CURRENT members stay as ordinary clips (takeGroupID
            // cleared, full editability restored — the escape hatch out of
            // member protection); non-comped lane material is discarded (files
            // remain on disk). takeGroupNotFound/trackNotFound surface via the
            // LocalizedError mapping. Response: {"clips": [...freed clips...]}.
            try params.rejectUnknownKeys(
                ["trackId", "groupId"], verb: "take.flatten")
            let flattenTrackID = try params.requireTrackID()
            let flattenGroupID = try params.requireGroupID()
            let flattenedClips = try store.flattenTakeGroup(
                trackId: flattenTrackID, groupId: flattenGroupID)
            return .success(request.id, .object(["clips": try JSONValue(encoding: flattenedClips)]))

        case "take.move":
            // params: trackId (required), groupId (required), toStartBeat
            // (required, clamped >= 0) — shifts the WHOLE group (lanes + comp +
            // members) so its range starts there. Coalesces under
            // take.move:<groupId> so a drag is one undo step. takeGroupNotFound/
            // trackNotFound surface via the LocalizedError mapping. Response:
            // {"group": {...}, "clips": [...]}.
            try params.rejectUnknownKeys(
                ["trackId", "groupId", "toStartBeat"], verb: "take.move")
            let moveGroupTrackID = try params.requireTrackID()
            let moveGroupID = try params.requireGroupID()
            let moveToStartBeat = try params.require("toStartBeat", \.doubleValue)
            let movedGroup = try store.moveTakeGroup(
                trackId: moveGroupTrackID, groupId: moveGroupID, toStartBeat: moveToStartBeat)
            return .success(request.id, .object([
                "group": try JSONValue(encoding: movedGroup),
                "clips": try memberClipsJSON(trackID: moveGroupTrackID, groupID: moveGroupID),
            ]))

        case "take.setCrossfade":
            // params: trackId (required), groupId (required), seconds (required,
            // clamped to TakeGroup.crossfadeSecondsRange 0...0.2) — the join
            // crossfade width at comp segment boundaries; rebuilds members.
            // Coalesces under take.xf:<groupId>. takeGroupNotFound/trackNotFound
            // surface via the LocalizedError mapping. Response: {"group": {...},
            // "clips": [...]}.
            try params.rejectUnknownKeys(
                ["trackId", "groupId", "seconds"], verb: "take.setCrossfade")
            let xfTrackID = try params.requireTrackID()
            let xfGroupID = try params.requireGroupID()
            let xfSeconds = try params.require("seconds", \.doubleValue)
            let xfGroup = try store.setTakeCrossfade(
                trackId: xfTrackID, groupId: xfGroupID, seconds: xfSeconds)
            return .success(request.id, .object([
                "group": try JSONValue(encoding: xfGroup),
                "clips": try memberClipsJSON(trackID: xfTrackID, groupID: xfGroupID),
            ]))

        case "take.autoAlign":
            // params: trackId (required), groupId (required), laneId (required),
            // searchWindowMs? (10...500, default 150 — field-named error out of
            // range), apply? (bool, default true). Onset-based micro-alignment
            // (M6 v-d): detects onsets in the group's FIRST lane (the reference
            // — the original material; AI Fix groups are built that way) and in
            // the target take on the SHARED engine detector (content-key
            // cached, the clip.detectTransients/clip.quantizeAudio detector),
            // over the OVERLAP of the two lanes' spans, then grid-searches
            // ±searchWindowMs at 1 ms steps and median-refines the winning
            // offset (sub-millisecond). apply → the take moves by −offset (its
            // onsets land ON the reference) in ONE undo step ("Align Take", the
            // take.move lane machinery); apply:false previews without mutating.
            // Aligning lane 0 against itself or a MIDI lane surfaces
            // invalidComp; fewer than 2 matched onsets (or no overlap) surfaces
            // alignmentInconclusive (counts + what to try next) — the aligner
            // never guesses; an apply whose earlier-move exceeds the lane's
            // headroom before beat 0 surfaces alignmentWouldCrossTimelineStart
            // (required move + headroom + take.move advice) — NEVER a silent
            // clamp, applied:true always means the take now sits aligned;
            // laneNotFound/takeGroupNotFound/trackNotFound/engineUnavailable
            // via the LocalizedError mapping. Response: the report —
            // {offsetMs, offsetBeats, matchedOnsets, referenceOnsets,
            // candidateOnsets, confidence, applied}.
            try params.rejectUnknownKeys(
                ["trackId", "groupId", "laneId", "searchWindowMs", "apply"], verb: "take.autoAlign")
            let alignTrackID = try params.requireTrackID()
            let alignGroupID = try params.requireGroupID()
            let alignLaneID = try params.requireLaneID()
            let alignWindowMs = params["searchWindowMs"]?.doubleValue ?? 150
            guard (10...500).contains(alignWindowMs) else {
                throw ControlError(
                    "'searchWindowMs' must be between 10 and 500 (milliseconds of ± search around the take's current position)")
            }
            let alignApply = params["apply"]?.boolValue ?? true
            let alignReport = try await store.autoAlignTake(
                trackID: alignTrackID, groupID: alignGroupID, laneID: alignLaneID,
                searchWindowMs: alignWindowMs, apply: alignApply)
            return .success(request.id, try JSONValue(encoding: alignReport))

        case "groove.extract":
            // params: clipId (required), name (required), gridBeats? (> 0,
            // default 0.25 = 1/16), cycleBeats? (> 0, default 4 = one bar at
            // x/4). Extracts a GROOVE (per-slot timing-offset table, M5 iii-g)
            // from a clip's onsets — a MIDI clip's note onsets, or an AUDIO
            // clip's detected transients (engine, content-key cached) — and
            // appends it to the project palette (one undo step). Onsets fold into
            // the cycle and per-slot deviations average; empty slots read 0.
            // clipNotFound / engineUnavailable (audio, headless) / invalidClipEdit
            // (non-positive grid/cycle) surface via the LocalizedError mapping.
            // Response: {"groove": {...}}.
            try params.rejectUnknownKeys(
                ["clipId", "name", "gridBeats", "cycleBeats"], verb: "groove.extract")
            let extractClipID = try params.requireClipID()
            let extractName = try params.require("name", \.stringValue)
            let extractGrid = params["gridBeats"]?.doubleValue ?? 0.25
            guard extractGrid > 0 else {
                throw ControlError("'gridBeats' must be greater than 0 (beats: 0.25 = 1/16, 0.5 = 1/8)")
            }
            let extractCycle = params["cycleBeats"]?.doubleValue ?? 4
            guard extractCycle > 0 else {
                throw ControlError("'cycleBeats' must be greater than 0 (beats: 4 = one bar at x/4)")
            }
            let extractedGroove = try await store.extractGroove(
                fromClipId: extractClipID, name: extractName,
                gridBeats: extractGrid, cycleBeats: extractCycle)
            return .success(request.id, .object(["groove": try JSONValue(encoding: extractedGroove)]))

        case "groove.list":
            // no params. Lists the project's SAVED groove templates plus the
            // built-in MPC swing presets (computed on demand, never persisted).
            // Response: {"templates": [...saved...], "builtins": [...swing8/16...]}.
            // Built-in ids are deterministic (a pure function of the preset name,
            // stable across calls and processes) and every built-in id is DISTINCT.
            // NOTE (m11-g): the built-in id derivation changed ONCE — the old fold
            // collided the whole swing8 family onto a single id; the current ids
            // differ from any cached before that fix. This is safe: built-in ids
            // are derived and NEVER persisted in a project (only saved-template ids
            // are stored, and those are untouched), so nothing on disk references
            // them — resolve a built-in by NAME ("swing8:66") for a stable handle.
            try params.rejectUnknownKeys([], verb: "groove.list")
            let builtins = GrooveTemplate.builtinNames.compactMap { GrooveTemplate.builtin(named: $0) }
            return .success(request.id, .object([
                "templates": try JSONValue(encoding: store.grooveTemplates),
                "builtins": try JSONValue(encoding: builtins),
            ]))

        case "groove.remove":
            // params: grooveId (required). Removes a SAVED template by id (one
            // undo step). Built-in swings aren't stored, so they're never
            // removable. An unknown id surfaces grooveNotFound verbatim. A groove
            // already applied to a past quantize keeps working (applied by value).
            // Response: {"removed": true}.
            try params.rejectUnknownKeys(
                ["grooveId"], verb: "groove.remove")
            let removeGrooveID = try params.requireGrooveID()
            try store.removeGrooveTemplate(id: removeGrooveID)
            return .success(request.id, .object(["removed": .bool(true)]))

        case "render.mixdown":
            // path optional (absolute or ~-prefixed .wav destination; the store
            // supplies a temp-dir default), fromBeat >= 0, durationSeconds > 0.
            // durationSeconds omitted → the SHARED all-clips default window
            // (m16-d/F4): the extent of every clip past fromBeat — audio AND
            // instrument — plus a 2.0 s tail, byte-for-byte the window
            // render.bounce / render.measureLoudness / render.stems default to
            // (was an audio-only extent + 0.5 s tail, which falsely refused
            // MIDI-only songs). No clips past fromBeat → nothingToRender,
            // surfaced verbatim. excludeTrackIds? (m23-m1) renders the full
            // session with those tracks SILENCED for this render only — the
            // instrumental/minus-vocal path — WITHOUT touching the project's
            // own mute flags, dirty flag or undo stack (that non-mutation is
            // the whole reason the param exists instead of "mute it by hand,
            // bounce, un-mute"). An excluded track takes its SENDS with it —
            // its reverb/delay tail leaves too, which is what makes the result
            // a genuinely clean instrumental and equally means this param
            // CANNOT express "instrumental but keep the vocal's reverb" — and
            // it takes its sidechain key contribution with it, so a ducker
            // keyed off an excluded vocal stops ducking. Its solo flag leaves
            // with it too, so excluding the only soloed track yields the
            // instrumental rather than silence. An unknown id rejects
            // trackNotFound before anything renders; the render LENGTH still
            // comes from the whole session. Response: {path, durationSeconds,
            // sampleRate, channels, excludedTracks?, bitDepth?, container?,
            // ditherApplied?}.
            // bitDepth? / container? (m23-m2) pick the OUTPUT FORMAT: bitDepth
            // 16 | 24 | 32 (integer PCM) — omit for the 32-bit FLOAT default,
            // which is lossless and preserves > 0 dBFS peaks; container "wav" |
            // "aiff" — omit for "wav". The FILE EXTENSION is load-bearing (it is
            // what selects the container), so `path`'s extension is made to
            // agree with `container` and the returned `path` is where the file
            // actually landed. Integer depths CLAMP at full scale while the
            // response's loudness numbers describe the pre-quantization buffer,
            // so a > 0 dBFS render written at 16-bit is clipped on disk and the
            // report will not say so — normalize it or keep the default.
            // Quantization is undithered in v0 and says so (ditherApplied
            // false). Echo fields are OMITTED when they are the default, so
            // pre-m23-m2 responses are byte-identical.
            try params.rejectUnknownKeys(
                ["path", "fromBeat", "durationSeconds", "excludeTrackIds",
                    "bitDepth", "container"],
                verb: "render.mixdown")
            let path = params["path"]?.stringValue
            let fromBeat = params["fromBeat"]?.doubleValue ?? 0
            guard fromBeat >= 0 else {
                throw ControlError("'fromBeat' must be >= 0")
            }
            let durationSeconds = params["durationSeconds"]?.doubleValue
            if let durationSeconds, durationSeconds <= 0 {
                throw ControlError("'durationSeconds' must be > 0")
            }
            let mixdownExcludeIDs = try parseOptionalTrackIDs(
                params["excludeTrackIds"], field: "excludeTrackIds")
            let mixdownFormat = try parseOutputFormat(params)
            let result = try await store.renderMixdown(
                toPath: path, fromBeat: fromBeat, durationSeconds: durationSeconds,
                excludeTrackIds: mixdownExcludeIDs,
                bitDepth: mixdownFormat.bitDepth, container: mixdownFormat.container
            )
            return .success(request.id, try JSONValue(encoding: result))

        case "render.measureLoudness":
            // params: fromBeat >= 0 (default 0), durationSeconds > 0 (default:
            // extent of ALL tracks' clips — audio AND instrument — plus a
            // 2.0 s bus-reverb/release tail, spec §4.3; the SAME shared window
            // render.mixdown/render.bounce/render.stems default to since m16-d).
            // Renders OFFLINE and
            // measures (BS.1770-4 integrated + max momentary/short-term + 4×
            // oversampled true peak) — NOTHING is written to disk, unlike
            // render.bounce. nil measurement fields mean the program sits below
            // the -70 LUFS gate (JSON has no -inf; nil is the honest encoding).
            // nothingToRender/engineUnavailable surface via the LocalizedError
            // mapping. Response: the model's own LoudnessMeasureResult Codable
            // — {measurement: {integratedLufs?, truePeakDbtp?,
            // maxMomentaryLufs?, maxShortTermLufs?}, durationSeconds, sampleRate}.
            try params.rejectUnknownKeys(
                ["fromBeat", "durationSeconds"], verb: "render.measureLoudness")
            let measureFromBeat = params["fromBeat"]?.doubleValue ?? 0
            guard measureFromBeat >= 0 else {
                throw ControlError("'fromBeat' must be >= 0")
            }
            let measureDurationSeconds = params["durationSeconds"]?.doubleValue
            if let measureDurationSeconds, measureDurationSeconds <= 0 {
                throw ControlError("'durationSeconds' must be > 0")
            }
            let measureResult = try await store.measureLoudness(
                fromBeat: measureFromBeat, durationSeconds: measureDurationSeconds)
            return .success(request.id, try JSONValue(encoding: measureResult))

        case "render.bounce":
            // params: path? (abs/~-prefixed .wav destination; temp-dir default,
            // the render.mixdown precedent), fromBeat >= 0, durationSeconds > 0
            // (same broader default as render.measureLoudness), lufsTarget?
            // (-70...0 LUFS — omit for a measured, UN-normalized bounce; -14 is
            // the streaming convention, -23 EBU R128 broadcast), truePeakCeilingDb?
            // (-20...0 dBTP, default -1.0). Normalization (spec §4.1): a single
            // STATIC gain toward lufsTarget, CLAMPED so the true peak never
            // exceeds the ceiling — NO limiter in v0, so report.limitedByCeiling
            // says honestly when the clamp bit and report.output is the loudness
            // actually achieved (an agent can add the built-in bus limiter and
            // re-bounce to close the gap). Output is RE-MEASURED from the gained
            // buffer, never derived. bounceSilent (gated-silent program + a
            // requested target)/nothingToRender surface via the LocalizedError
            // mapping. excludeTrackIds? (m23-m1) renders the full session with
            // those tracks SILENCED for this render only — the
            // instrumental/minus-vocal path — WITHOUT touching the project's
            // own mute flags, dirty flag or undo stack (that non-mutation is
            // the whole reason the param exists instead of "mute it by hand,
            // bounce, un-mute"). An excluded track takes its SENDS with it —
            // its reverb/delay tail leaves too, which is what makes the result
            // a genuinely clean instrumental and equally means this param
            // CANNOT express "instrumental but keep the vocal's reverb" — and
            // it takes its sidechain key contribution with it, so a ducker
            // keyed off an excluded vocal stops ducking. Its solo flag leaves
            // with it too, so excluding the only soloed track yields the
            // instrumental rather than silence. An unknown id rejects
            // trackNotFound before anything renders; the render LENGTH still
            // comes from the whole session, so an instrumental is exactly as
            // long as the mix. Loudness normalization measures the EXCLUDED
            // render, so an instrumental normalized to -14 LUFS is -14 on its
            // own program, not on the full mix's. Response: the model's own
            // BounceResult Codable — {path, durationSeconds, sampleRate,
            // channels, report: {input, output, appliedGainDb, lufsTarget?,
            // truePeakCeilingDbtp, limitedByCeiling}, excludedTracks?,
            // bitDepth?, container?, ditherApplied?}.
            // bitDepth? / container? (m23-m2) pick the OUTPUT FORMAT: bitDepth
            // 16 | 24 | 32 (integer PCM) — omit for the 32-bit FLOAT default,
            // which is lossless and preserves > 0 dBFS peaks; container "wav" |
            // "aiff" — omit for "wav". The FILE EXTENSION is load-bearing (it is
            // what selects the container), so `path`'s extension is made to
            // agree with `container` and the returned `path` is where the file
            // actually landed. Integer depths CLAMP at full scale while the
            // response's loudness numbers describe the pre-quantization buffer,
            // so a > 0 dBFS render written at 16-bit is clipped on disk and the
            // report will not say so — normalize it or keep the default.
            // Quantization is undithered in v0 and says so (ditherApplied
            // false). Echo fields are OMITTED when they are the default, so
            // pre-m23-m2 responses are byte-identical.
            try params.rejectUnknownKeys(
                ["path", "fromBeat", "durationSeconds", "lufsTarget",
                    "truePeakCeilingDb", "excludeTrackIds",
                    "bitDepth", "container"], verb: "render.bounce")
            let bouncePath = params["path"]?.stringValue
            let bounceFromBeat = params["fromBeat"]?.doubleValue ?? 0
            guard bounceFromBeat >= 0 else {
                throw ControlError("'fromBeat' must be >= 0")
            }
            let bounceDurationSeconds = params["durationSeconds"]?.doubleValue
            if let bounceDurationSeconds, bounceDurationSeconds <= 0 {
                throw ControlError("'durationSeconds' must be > 0")
            }
            let lufsTarget = params["lufsTarget"]?.doubleValue
            if let lufsTarget, !(-70...0).contains(lufsTarget) {
                throw ControlError(
                    "'lufsTarget' must be between -70 and 0 LUFS (-14 = streaming "
                    + "convention, -23 = EBU R128 broadcast; omit for a measured, "
                    + "un-normalized bounce)")
            }
            let truePeakCeilingDb = params["truePeakCeilingDb"]?.doubleValue ?? -1.0
            guard (-20...0).contains(truePeakCeilingDb) else {
                throw ControlError("'truePeakCeilingDb' must be between -20 and 0 dBTP (default -1.0)")
            }
            let bounceExcludeIDs = try parseOptionalTrackIDs(
                params["excludeTrackIds"], field: "excludeTrackIds")
            let bounceFormat = try parseOutputFormat(params)
            let bounceResult = try await store.renderBounce(
                toPath: bouncePath, fromBeat: bounceFromBeat,
                durationSeconds: bounceDurationSeconds,
                lufsTarget: lufsTarget, truePeakCeilingDb: truePeakCeilingDb,
                excludeTrackIds: bounceExcludeIDs,
                bitDepth: bounceFormat.bitDepth, container: bounceFormat.container)
            return .success(request.id, try JSONValue(encoding: bounceResult))

        case "render.stems":
            // params: trackIds? (master-input ids — a direct-to-master track or
            // a bus; omit = every master input), directory? (abs/~ destination;
            // temp-dir default), fromBeat >= 0, durationSeconds > 0 (same
            // broader default as render.measureLoudness — every stem file gets
            // the SAME length, computed once, since summation requires it),
            // includeMixdown? (default false — adds a "00 Mixdown.wav" reference
            // pass under the SAME forced full-session PDC targets as every
            // stem). Stems are NEVER normalized (spec §4.1) — independent gains
            // would destroy inter-stem balance and the Σ-stems-≡-mixdown
            // invariant; each file instead carries its own full
            // LoudnessMeasurement (> 0 dBFS overshoots stay visible, never
            // clipped or gain-baked). A bus-routed trackId rejects
            // stemNotMasterInput verbatim (its signal lives in the destination
            // bus's stem); an unknown id rejects trackNotFound; an empty
            // selection or a project with no clips in the window rejects
            // nothingToRender — all via the LocalizedError mapping.
            // includeMasteredMixdown? (default false, m23-m1) adds a SECOND,
            // independent file "00 Mastered Mix.wav" — the real MASTERED mix,
            // rendered exactly the way render.bounce renders (full session,
            // real master chain, real master automation lane, real master
            // volume), optionally normalized via masteredLufsTarget
            // (-70...0 LUFS) / masteredTruePeakCeilingDb (-20...0 dBTP,
            // default -1.0) through the same gain-only policy render.bounce
            // uses. It is a SIBLING of the stems, never a transformation of
            // them: for a nonlinear master chain M, Σ M(sᵢ) ≠ M(Σ sᵢ), so
            // printing the shared chain onto each stem would NOT add back up
            // to this file (S-3′; research m23-l §4.3). Stems therefore stay
            // chain-EXCLUDED and keep nulling against "00 Mixdown.wav" —
            // includeMixdown and includeMasteredMixdown are INDEPENDENT flags
            // for two different files with non-overlapping meanings, and both
            // may be requested at once. The mastered pass runs LAST, so a
            // masteredLufsTarget on a gated-silent program surfaces
            // bounceSilent AFTER the stem files have already landed. Response:
            // the model's own StemExportResult Codable — {directory,
            // sampleRate, durationSeconds, channels, stems: [{trackId, name,
            // kind: "track"|"bus", path, measurement}], mixdown?: {path,
            // measurement}, masterChain?, masteredMixdown?: {path, report},
            // bitDepth?, container?, ditherApplied?}.
            // bitDepth? / container? (m23-m2) pick the OUTPUT FORMAT: bitDepth
            // 16 | 24 | 32 (integer PCM) — omit for the 32-bit FLOAT default,
            // which is lossless and preserves > 0 dBFS peaks; container "wav" |
            // "aiff" — omit for "wav". The FILE EXTENSION is load-bearing (it is
            // what selects the container), so `path`'s extension is made to
            // agree with `container` and the returned `path` is where the file
            // actually landed. Integer depths CLAMP at full scale while the
            // response's loudness numbers describe the pre-quantization buffer,
            // so a > 0 dBFS render written at 16-bit is clipped on disk and the
            // report will not say so — normalize it or keep the default.
            // Quantization is undithered in v0 and says so (ditherApplied
            // false). Echo fields are OMITTED when they are the default, so
            // pre-m23-m2 responses are byte-identical.
            // Every file of the set shares ONE format — they have to sum.
            try params.rejectUnknownKeys(
                ["trackIds", "directory", "fromBeat", "durationSeconds",
                    "includeMixdown", "includeMasteredMixdown",
                    "masteredLufsTarget", "masteredTruePeakCeilingDb",
                    "bitDepth", "container"],
                verb: "render.stems")
            let stemsTrackIDs = try parseOptionalTrackIDs(params["trackIds"])
            let stemsDirectory = params["directory"]?.stringValue
            let stemsFromBeat = params["fromBeat"]?.doubleValue ?? 0
            guard stemsFromBeat >= 0 else {
                throw ControlError("'fromBeat' must be >= 0")
            }
            let stemsDurationSeconds = params["durationSeconds"]?.doubleValue
            if let stemsDurationSeconds, stemsDurationSeconds <= 0 {
                throw ControlError("'durationSeconds' must be > 0")
            }
            let includeMixdown = params["includeMixdown"]?.boolValue ?? false
            let includeMasteredMixdown = params["includeMasteredMixdown"]?.boolValue ?? false
            let masteredLufsTarget = params["masteredLufsTarget"]?.doubleValue
            if let masteredLufsTarget, !(-70...0).contains(masteredLufsTarget) {
                throw ControlError(
                    "'masteredLufsTarget' must be between -70 and 0 LUFS (-14 = streaming "
                    + "convention, -23 = EBU R128 broadcast; omit for a measured, "
                    + "un-normalized mastered mix)")
            }
            let masteredTruePeakCeilingDb =
                params["masteredTruePeakCeilingDb"]?.doubleValue ?? -1.0
            guard (-20...0).contains(masteredTruePeakCeilingDb) else {
                throw ControlError(
                    "'masteredTruePeakCeilingDb' must be between -20 and 0 dBTP (default -1.0)")
            }
            // A normalization param without the file it normalizes would do
            // nothing, silently — reject it by name instead (the iv-d
            // field-named contract). Stems themselves are NEVER normalized.
            if !includeMasteredMixdown {
                if params["masteredLufsTarget"] != nil {
                    throw ControlError(
                        "'masteredLufsTarget' applies to the mastered mix — pass "
                        + "'includeMasteredMixdown': true (stems are never normalized)")
                }
                if params["masteredTruePeakCeilingDb"] != nil {
                    throw ControlError(
                        "'masteredTruePeakCeilingDb' applies to the mastered mix — pass "
                        + "'includeMasteredMixdown': true (stems are never normalized)")
                }
            }
            let stemsFormat = try parseOutputFormat(params)
            let stemsResult = try await store.renderStems(
                toDirectory: stemsDirectory, trackIds: stemsTrackIDs,
                fromBeat: stemsFromBeat, durationSeconds: stemsDurationSeconds,
                includeMixdown: includeMixdown,
                includeMasteredMixdown: includeMasteredMixdown,
                masteredLufsTarget: masteredLufsTarget,
                masteredTruePeakCeilingDb: masteredTruePeakCeilingDb,
                bitDepth: stemsFormat.bitDepth, container: stemsFormat.container)
            return .success(request.id, try JSONValue(encoding: stemsResult))

        case "ai.sidecarStatus":
            // No params. Health-probes the local ACE-Step-1.5 sidecar (GET
            // /health on 127.0.0.1:8001, loopback only) and reports which of
            // notInstalled/installedNotRunning/starting/healthy/error applies
            // — never a bare connection-failure error, so a client can tell
            // "run scripts/ace-step/install.sh" apart from "call
            // ai.sidecarStart" without guessing. `message` is always a
            // human-actionable string; `version`/`ditModel`/`lmModel` are
            // populated only when healthy. (M10-b) `phase`/`startingForSeconds`
            // are populated only when `state == "starting"`: `phase` is a
            // human hint classified from the sidecar log's tail ("preparing
            // environment…"/"starting server…"/"loading models…", or nil when
            // unrecognizable — see `SidecarStartPhase`), and
            // `startingForSeconds` is whole seconds since the boot began,
            // TRACKED ACROSS THE WHOLE BOOT (not just one blocking
            // `ai.sidecarStart` call) — including across an app relaunch
            // mid-boot, via a pidfile-liveness fallback — so a poll made long
            // after `ai.sidecarStart` timed out still honestly reports
            // "starting", never misreporting `installedNotRunning` (the beta
            // "loaded-but-not-started" bug). Response: the model's own
            // SidecarStatus Codable (AIServices) — {state, message, version?,
            // ditModel?, lmModel?, pid?, phase?, startingForSeconds?}. This is
            // process-lifecycle management only — the generation client/tools
            // arrive in a later roadmap item.
            try params.rejectUnknownKeys([], verb: "ai.sidecarStatus")
            let sidecarStatus = await sidecarManager.status()
            return .success(request.id, try JSONValue(encoding: sidecarStatus))

        case "ai.sidecarStart":
            // No params. Spawns scripts/ace-step/run.sh (loopback-only
            // FastAPI server) if not already healthy, then polls /health up
            // to a startup timeout (still ~30s, blocking — UNCHANGED by
            // M10-b). Throws notInstalled (verbatim, points at install.sh) if
            // the sidecar was never installed, or a launch error if the
            // process exits during startup. A timeout without reaching
            // healthy is NOT an error — it returns state "starting" with a
            // health-aware message (names elapsed time, the current log
            // phase when recognizable, and the log path — "it's likely still
            // booting… the panel will update as it boots"), and — the M10-b
            // fix — every LATER ai.sidecarStatus poll keeps reporting
            // "starting" with a truthfully increasing startingForSeconds
            // instead of losing track of the boot. Response: SidecarStatus
            // (see ai.sidecarStatus for the phase/startingForSeconds fields).
            try params.rejectUnknownKeys([], verb: "ai.sidecarStart")
            let startedStatus = try await sidecarManager.start()
            return .success(request.id, try JSONValue(encoding: startedStatus))

        case "ai.sidecarStop":
            // No params (m16-e, audit F5 survey). Graceful stop (SIGTERM,
            // escalating to SIGKILL if it doesn't exit in time) of a running
            // sidecar, together with the child process it spawned — that
            // child is what holds the loaded models' memory. The target comes
            // from the pidfile when that points at a live process, and
            // otherwise from whichever process holds the listening socket on
            // the sidecar's port (m23-bb: a stale pidfile used to make this
            // verb report "was not running" while the sidecar kept running).
            // A no-op success (not an error) if it genuinely wasn't running.
            // ERRORS (SidecarError.stopFailed) rather than reporting success
            // when the sidecar is still answering afterwards, or when the only
            // process on its port can't be identified as ACE-Step — which is
            // never signalled. Response: SidecarStatus (state settles to
            // installedNotRunning/notInstalled).
            try params.rejectUnknownKeys([], verb: "ai.sidecarStop")
            let stoppedStatus = try await sidecarManager.stop()
            // Reconcile the lifecycle bookkeeping AFTER a stop that succeeded
            // (a failed one throws above and the model is still up, so residency
            // must stay). Deliberately NOT re-routed through
            // `modelLifecycle.unload`, which the design suggested: that would
            // change this verb's response type and its m23-bb stop-honesty
            // error. Called from the ROUTER, never from the manager — a
            // manager-side call would arrive from inside the coordinator's own
            // eviction and violate F7.
            await modelLifecycle.noteStoppedExternally(.aceStep)
            return .success(request.id, try JSONValue(encoding: stoppedStatus))

        case "ai.modelResidency":
            // m23-dl. WHICH LOCAL MODELS ARE LOADED RIGHT NOW, what each is
            // holding, and what would happen if you booted one. This is the read
            // that makes every other lifecycle verb checkable.
            //
            // params: includeProcessDetail (optional bool, default false).
            // ⚠️ It defaults FALSE on purpose: the per-process figures come from
            // a `/bin/ps` fork and `portBusy` from an `lsof` fork — tens of
            // milliseconds each. The obvious next feature is "show the resident
            // model in the status bar", and a 1 Hz poll with this true would fork
            // two helpers every second forever. With it false those fields are
            // served from the last cached snapshot and carry
            // processDetailAgeSeconds; `memory` is always fresh (one mach trap).
            //
            // Response: {generation, sampledAt, memory {physicalBytes, usedBytes
            // (= Activity Monitor "Memory Used"), availableBytes, freeBytes,
            // externalBytes, compressorBytes, wiredBytes, vmStatFreeBytes, …},
            // policy, inFlight?, processDetailAgeSeconds?, models: [{modelId,
            // displayName, port?, resident, holdBytes, holdConfidence,
            // holdProvenance, estimatedHoldBytes, activeJobs, admittedAt?,
            // idleForSeconds?, idleUnloadSeconds?, idleUnloadAt?,
            // nextBootWouldUnload, nextBootProtectedByJobs, nextBootPlan,
            // treeFootprintBytes?, treeResidentBytes?, pids?, portBusy?}]}.
            //
            // ⚠️ `generation` is the m23-ah nonce: two reads with the same value
            // describe the same world, and an unload that did not bump it did not
            // happen. ⚠️ `holdBytes` is CORROBORATION, never a gate — DAW Pro
            // does not check memory before loading a model (user decision
            // 2026-08-05), so this figure only ever grades whether an unload
            // actually returned what it was supposed to. ⚠️ `resident` means
            // "booted and tracked by this app"; a sidecar you started by hand
            // reads resident:false while holding its memory, which is what
            // `portBusy` is for.
            try params.rejectUnknownKeys(["includeProcessDetail"], verb: "ai.modelResidency")
            let residencyIncludeDetail = params["includeProcessDetail"]?.boolValue ?? false
            let residencyReport = await modelLifecycle.residency(
                includeProcessDetail: residencyIncludeDetail)
            return .success(request.id, try JSONValue(encoding: residencyReport))

        case "ai.modelUnload":
            // m23-dl. Unloads a local model sidecar and REPORTS EVIDENCE that it
            // actually stopped. params: exactly ONE of modelId (e.g. "ace-step",
            // "rvc") or all (bool true). Both or neither is a teaching error
            // naming the valid ids.
            //
            // "Unloaded" has three AUTHORITY limbs, and any one of them false
            // means the unload FAILED: the model's port is free, its health probe
            // is unreachable, and no pid from the PRE-KILL captured process tree
            // is still alive. (The tree is captured before signalling because a
            // child whose parent exits is reparented to pid 1 and the linkage is
            // gone. Checking the pidfile pid alone is wrong for ACE-Step: run.sh
            // ends in `exec uv run …`, so the pidfile pid is the `uv` supervisor
            // while the python child holds the ~80 GB.)
            //
            // memoryReturnedBytes/memoryVerdict are CORROBORATION and never fail
            // the verb: system-available memory is a shared, noisy counter and a
            // memory-gated verdict reports failed unloads that did not fail.
            //
            // Response: {generation, models: [EvictionReport {modelId, reason,
            // stopped, detail, evidence {portFree, portLookupDetail?,
            // probeUnreachable, treePidsAliveAfter, availableBeforeBytes,
            // availableAfterBytes, memoryReturnedBytes, memoryVerdict,
            // expectedHoldBytes?, generationBefore, generationAfter}}]}. `ok` is
            // false when any model failed to stop.
            try params.rejectUnknownKeys(["modelId", "all"], verb: "ai.modelUnload")
            let unloadAll = params["all"]?.boolValue ?? false
            let unloadModelID = params["modelId"]?.stringValue
            let unloadValidIDs = await modelLifecycle.registeredModelIDs()
            if unloadAll && unloadModelID != nil {
                throw ControlError(
                    "ai.modelUnload takes exactly one of 'modelId' or 'all', not both. Send "
                        + "{\"all\": true} to unload every local model, or {\"modelId\": \"<id>\"} "
                        + "for one of: "
                        + unloadValidIDs.map(\.rawValue).joined(separator: ", ") + ".")
            }
            var unloadReports: [EvictionReport]
            if unloadAll {
                unloadReports = await modelLifecycle.unloadAll(reason: .explicit)
            } else if let unloadModelID {
                let id = ModelID(rawValue: unloadModelID)
                guard await modelLifecycle.isRegistered(id) else {
                    throw ControlError(await ModelAdmission.unknownModelMessage(
                        unloadModelID, valid: unloadValidIDs,
                        generation: modelLifecycle.currentGeneration()))
                }
                unloadReports = [await modelLifecycle.unload(id, reason: .explicit)]
            } else {
                throw ControlError(
                    "ai.modelUnload needs exactly one of 'modelId' or 'all'. Send {\"all\": true} "
                        + "to unload every local model, or {\"modelId\": \"<id>\"} for one of: "
                        + unloadValidIDs.map(\.rawValue).joined(separator: ", ") + ".")
            }
            let unloadGeneration = await modelLifecycle.currentGeneration()
            let unloadFailures = unloadReports.filter { !$0.stopped }
            guard unloadFailures.isEmpty else {
                // Never a success-shaped response to a stop that did not stop
                // (m23-bb / m23-ah). The evidence is still reachable through
                // ai.modelResidency, whose generation has moved either way.
                throw ControlError(
                    "Unload FAILED for "
                        + unloadFailures.map(\.modelID.rawValue).joined(separator: ", ")
                        + " — " + unloadFailures.map(\.detail).joined(separator: " | ")
                        + " Poll ai.modelResidency (generation \(unloadGeneration)) to see what is "
                        + "still holding a port.")
            }
            return .success(request.id, try JSONValue(encoding: ModelUnloadResponse(
                generation: unloadGeneration, models: unloadReports)))

        case "ai.providerStatus":
            // No params. Reports, per key-backed provider (anthropic/openai/
            // suno — ACE-Step is the LOCAL, KEYLESS sidecar and is intentionally
            // absent), whether a key is available and from where:
            // {providers: [{provider, configured, source}]} where source is
            // "env" | "keychain" | "none". env wins over keychain.
            //
            // STATUS-ONLY BY DESIGN: this surface carries booleans + the source
            // enum, NEVER a key value and NEVER a length. There is deliberately
            // NO companion "set key" command anywhere in the control protocol or
            // MCP — key values must not transit the control plane, whose traffic
            // is logged in agents' conversations (house directive: never log key
            // values). Keys are entered only via environment variables or the
            // app's Settings panel (→ system Keychain).
            try params.rejectUnknownKeys([], verb: "ai.providerStatus")
            let statuses = providerStatuses(environment: keyEnvironment, store: keyStore)
            return .success(request.id, try JSONValue(encoding: ["providers": statuses]))

        case "ai.writeLyrics":
            // Writes (or REFINES) bracketed-structure lyrics for ACE-Step using
            // the APP's configured provider (Anthropic preferred, OpenAI
            // fallback — the ai.providerStatus chain) and the LIVE project
            // context. params: prompt (required — the theme/what the song is
            // about). style (optional — genre/feel). structure (optional — a
            // non-empty array of section tags, default
            // ["verse","chorus","verse","chorus","bridge","chorus"]). context
            // (optional object {keyScale?, tempoBPM?, timeSignature?, genre?});
            // ANY field omitted defaults from the current project (tempoBPM /
            // timeSignature from the transport), so a bare call still weaves in
            // the session's tempo/meter. existingLyrics + instruction (optional
            // — providing existingLyrics switches to REFINE mode: revise those
            // lyrics per `instruction`). Response: {lyrics, provider} where
            // provider is "anthropic"|"openai". When NEITHER provider has a key
            // this fails with an actionable message naming the Settings panel
            // (⌘,) and ai.providerStatus — never a key value (keys never cross
            // this plane; see ai.providerStatus).
            try params.rejectUnknownKeys(
                ["prompt", "style", "structure", "context", "existingLyrics",
                    "instruction"], verb: "ai.writeLyrics")
            let lyricsTheme = try params.require("prompt", \.stringValue)
            var writeRequest = LyricsWriteRequest(prompt: lyricsTheme)
            if let style = params["style"]?.stringValue { writeRequest.style = style }
            if let structureValue = params["structure"] {
                writeRequest.structure = try parseLyricsStructure(structureValue)
            }
            writeRequest.context = try parseLyricsContext(params["context"])
            if let existing = params["existingLyrics"]?.stringValue {
                writeRequest.existingLyrics = existing
            }
            if let instruction = params["instruction"]?.stringValue {
                writeRequest.instruction = instruction
            }
            let writer = try lyricsWriterProvider()
            let writeResult = try await writer.writeLyrics(writeRequest)
            return .success(request.id, .object([
                "lyrics": .string(writeResult.lyrics),
                "provider": .string(writeResult.provider),
            ]))

        case "ai.generateSong":
            // Submits an async song-generation job to the local ACE-Step
            // sidecar (POST /release_task) and returns immediately — poll
            // ai.generationStatus with the returned jobId, this does NOT
            // wait for the song to finish (that commonly takes minutes).
            // params: prompt (required — style/caption text, e.g. "80s
            // synth-pop, anthemic"). lyrics (optional — bracketed-structure
            // format, e.g. "[Verse 1]\n...\n[Chorus]\n..."; omit/blank for an
            // instrumental). durationSeconds, seed, bpm, keyScale,
            // timeSignature, vocalLanguage, guidanceScale, inferenceSteps —
            // all optional generation knobs, see SongGenerationRequest
            // (AIServices) for units/defaults. Response: SongGenerationSubmission
            // {jobId, state, queuePosition?} — state is always "queued" on a
            // fresh submission. Throws the SidecarManager's own
            // state-specific actionable message (not a bare connection
            // error) when the sidecar isn't reachable.
            try params.rejectUnknownKeys(
                ["prompt", "lyrics", "durationSeconds", "seed", "bpm", "keyScale",
                    "timeSignature", "vocalLanguage", "guidanceScale", "inferenceSteps"], verb: "ai.generateSong")
            let genPrompt = try params.require("prompt", \.stringValue)
            var genRequest = SongGenerationRequest(prompt: genPrompt)
            genRequest.lyrics = params["lyrics"]?.stringValue
            genRequest.durationSeconds = params["durationSeconds"]?.doubleValue
            if let seedValue = params["seed"]?.doubleValue { genRequest.seed = Int(seedValue) }
            if let bpmValue = params["bpm"]?.doubleValue { genRequest.bpm = Int(bpmValue) }
            genRequest.keyScale = params["keyScale"]?.stringValue
            genRequest.timeSignature = params["timeSignature"]?.stringValue
            if let vocalLanguage = params["vocalLanguage"]?.stringValue {
                genRequest.vocalLanguage = vocalLanguage
            }
            genRequest.guidanceScale = params["guidanceScale"]?.doubleValue
            if let stepsValue = params["inferenceSteps"]?.doubleValue {
                genRequest.inferenceSteps = Int(stepsValue)
            }
            do {
                let submission = try await songGenerator.generateSong(genRequest)
                await noteACEJobStarted(submission.jobID)
                return .success(request.id, try JSONValue(encoding: submission))
            } catch {
                throw await translateSongGeneratorError(error)
            }

        case "ai.generationStatus":
            // jobId required (from ai.generateSong). Polls the sidecar
            // (POST /query_result). Response: SongGenerationStatus {jobId,
            // state ("queued"|"running"|"succeeded"), progress?, stage?,
            // statusText?, audioPath?} — audioPath is populated the FIRST
            // time this observes state == "succeeded" (the client fetches
            // the finished audio to a local file at that point and caches
            // it; later polls of the same job reuse the cached path rather
            // than re-downloading). A job that FAILED upstream surfaces as
            // an error response here (never a "failed" state value), so a
            // non-ok response with an unrecognized jobId/failure message
            // means exactly that. Once audioPath is present, import it with
            // clip.addAudio.
            try params.rejectUnknownKeys(["jobId"], verb: "ai.generationStatus")
            let statusJobID = try params.require("jobId", \.stringValue)
            do {
                let status = try await songGenerator.generationStatus(jobID: statusJobID)
                // The ONE place a job is closed (m23-dl). Idempotent by job id,
                // which matters because this verb is polled in a loop and every
                // poll after the first sees the same terminal state.
                if status.state == .succeeded || status.state == .failed {
                    await modelLifecycle.noteJobEnded(.aceStep, jobID: statusJobID)
                }
                return .success(request.id, try JSONValue(encoding: status))
            } catch {
                // A job that failed upstream surfaces here as a thrown error
                // rather than a `.failed` state, so this is the only place that
                // kind of failure can close the job.
                //
                // ⚠️⚠️ **BUT ONLY FOR ERRORS THAT PROVE THE JOB IS OVER.** This
                // used to close the job on ANY thrown error, which inverted F8:
                // the success path is careful (terminal states only, `.running`
                // keeps the job open) while "I could not ask" — one dropped
                // connection or one HTTP timeout mid-render — dropped
                // `activeJobs` to 0 and let the next boot SIGTERM ACE in the
                // middle of the render it was protecting. That is precisely the
                // failure mode F8 exists to prevent, introduced by the hook
                // written to enforce it.
                //
                // A transient error now leaves the job OPEN and lets
                // `jobLeaseSeconds` self-heal it. That is the deliberate
                // trade: the lease exists for a job nobody closed, so leaking
                // protection for an hour is the cheap side and evicting a live
                // render is the expensive one.
                if Self.errorProvesJobIsOver(error) {
                    await modelLifecycle.noteJobEnded(.aceStep, jobID: statusJobID)
                }
                throw await translateSongGeneratorError(error)
            }

        case "ai.importGeneration":
            // Turns a FINISHED generation job into project material (M6 iii-a):
            // a new AI-flagged audio track + clip (violet in the UI) at the
            // target beat, plus optional project-tempo adoption from the
            // generation's metas.bpm — all as ONE undoable "Import Generation"
            // edit. params: jobId (required — from ai.generateSong; the job
            // must have reached state "succeeded", i.e. ai.generationStatus
            // reports an audioPath). trackName (optional — defaults to "AI:
            // <first words of the prompt>"). atBeat (optional, default 0).
            // setProjectTempo (optional bool — omit to auto-adopt ONLY when the
            // project has no other clips; true forces adoption, false forbids
            // it; adoption also needs metas.bpm present). Response: {trackId,
            // clipId, adoptedTempoBPM?} (adoptedTempoBPM omitted when tempo was
            // left unchanged). A still-running job / unknown (expired) jobId
            // surface as actionable errors pointing back at ai.generationStatus.
            try params.rejectUnknownKeys(
                ["jobId", "trackName", "atBeat", "setProjectTempo"], verb: "ai.importGeneration")
            let importJobID = try params.require("jobId", \.stringValue)
            let importTrackName = params["trackName"]?.stringValue
            let importAtBeat = params["atBeat"]?.doubleValue
            let importSetTempo = params["setProjectTempo"]?.boolValue
            do {
                let (trackID, clipID, adoptedBPM) = try await store.importGeneration(
                    jobID: importJobID,
                    trackName: importTrackName,
                    atBeat: importAtBeat,
                    setProjectTempo: importSetTempo)
                var result: [String: JSONValue] = [
                    "trackId": .string(trackID.uuidString),
                    "clipId": .string(clipID.uuidString),
                ]
                if let adoptedBPM {
                    result["adoptedTempoBPM"] = .number(adoptedBPM)
                }
                return .success(request.id, .object(result))
            } catch {
                throw await translateSongGeneratorError(error)
            }

        case "ai.extractStems":
            // Separates an EXISTING audio file into named stems (M6 iii-c,
            // ACE-Step task_type "extract"). params: sourceAudioPath
            // (required — local filesystem path to the existing mixed-down
            // audio to separate; the client stages a COPY of it inside the
            // sidecar's own temp-dir allowlist, so any readable local path
            // works). trackNames (required — non-empty array of stem names,
            // e.g. ["vocals", "drums", "bass"]; ACE-Step's fixed vocabulary
            // is woodwinds/brass/fx/synth/strings/percussion/keyboard/
            // guitar/bass/drums/backing_vocals/vocals, not re-validated
            // here — the sidecar rejects an unknown name with its own
            // error). model (optional — DiT model name; extract/lego are
            // BASE-model-only capabilities, and the sidecar's default
            // ai.sidecarStart load is the turbo tier, which does NOT serve
            // them). LEAVE THIS OMITTED for the normal case (M6
            // iii-c-real): omitting it does NOT hit turbo — the client
            // defaults to its own stems model (currently
            // "acestep-v15-xl-sft") and, before submitting, checks the
            // sidecar's model inventory and auto-loads that model into
            // handler slot 2 if it isn't already resident (this can take
            // MINUTES the first time, a multi-GB checkpoint load — the
            // submission call blocks until it's done or fails). Pass an
            // explicit `model` only to request a different DiT model than
            // that default. If the sidecar was started before
            // scripts/ace-step/run.sh began exporting ACESTEP_CONFIG_PATH2,
            // slot 2 doesn't exist and the auto-load fails with an
            // actionable error naming ai.sidecarStop/ai.sidecarStart to
            // restart it. Submits ONE upstream job per track name against
            // the SAME source audio and returns a single COMPOSITE jobId
            // grouping them — poll it with ai.generationStatus exactly like
            // ai.generateSong (one status surface, not a parallel one); a
            // succeeded poll's `stems` array carries every named result.
            // Response: {jobId, state, trackNames}.
            try params.rejectUnknownKeys(
                ["sourceAudioPath", "trackNames", "model"], verb: "ai.extractStems")
            let extractSourceAudioPath = try params.require("sourceAudioPath", \.stringValue)
            let extractTrackNames = try parseTrackNames(params["trackNames"])
            let extractModel = params["model"]?.stringValue
            do {
                let submission = try await songGenerator.extractStems(StemExtractionRequest(
                    sourceAudioPath: extractSourceAudioPath, trackNames: extractTrackNames, model: extractModel))
                await noteACEJobStarted(submission.jobID)
                return .success(request.id, try JSONValue(encoding: submission))
            } catch {
                throw await translateSongGeneratorError(error)
            }

        case "ai.legoGenerate":
            // Generates NEW tracks that fit an existing source audio's
            // musical context (M6 iii-c, ACE-Step task_type "lego" — build a
            // song up one instrument layer at a time). params:
            // sourceAudioPath (required — same staging semantics as
            // ai.extractStems). globalCaption (required — shared song-level
            // description, e.g. "warm lofi hip-hop, 90 bpm"). tracks
            // (required — non-empty array of {trackName (required), prompt
            // (optional — that track's OWN local description, e.g. "round
            // sub bass, laid back")}). model (optional, same default-model +
            // auto-load-into-slot-2 behavior as ai.extractStems — see its
            // doc). Same one-upstream-job-per-track / composite-jobId /
            // shared-status-surface shape as ai.extractStems. Response:
            // {jobId, state, trackNames}.
            try params.rejectUnknownKeys(
                ["sourceAudioPath", "globalCaption", "tracks", "model"], verb: "ai.legoGenerate")
            let legoSourceAudioPath = try params.require("sourceAudioPath", \.stringValue)
            let legoGlobalCaption = try params.require("globalCaption", \.stringValue)
            let legoTracks = try parseLegoTracks(params["tracks"])
            let legoModel = params["model"]?.stringValue
            do {
                let submission = try await songGenerator.generateLegoTracks(LegoGenerationRequest(
                    sourceAudioPath: legoSourceAudioPath, globalCaption: legoGlobalCaption,
                    tracks: legoTracks, model: legoModel))
                await noteACEJobStarted(submission.jobID)
                return .success(request.id, try JSONValue(encoding: submission))
            } catch {
                throw await translateSongGeneratorError(error)
            }

        case "ai.importGeneratedStems":
            // Turns a FINISHED stems/Lego composite job into project
            // material (M6 iii-c): N new AI-flagged audio tracks + clips
            // (violet in the UI), one per named result, all at the SAME
            // target beat, plus optional project-tempo adoption from the
            // first track (in submission order) that reports a bpm — all as
            // ONE undoable "Import Generated Stems" edit (a single undo
            // removes EVERY imported track, together with any tempo change).
            // params: jobId (required — from ai.extractStems/
            // ai.legoGenerate; every underlying track must have reached
            // "succeeded", i.e. ai.generationStatus reports a non-empty
            // `stems` array). atBeat (optional, default 0). setProjectTempo
            // (optional bool — same semantics as ai.importGeneration).
            // Response: {tracks: [{trackId, clipId, trackName}, ...],
            // adoptedTempoBPM?}. A still-running job / unknown (expired)
            // jobId / any missing stem file surface as actionable errors —
            // reuses ai.importGeneration's exact rejection wording
            // (generationNotReady points back at ai.generationStatus).
            try params.rejectUnknownKeys(
                ["jobId", "atBeat", "setProjectTempo"], verb: "ai.importGeneratedStems")
            let importStemsJobID = try params.require("jobId", \.stringValue)
            let importStemsAtBeat = params["atBeat"]?.doubleValue
            let importStemsSetTempo = params["setProjectTempo"]?.boolValue
            do {
                let (imported, adoptedBPM) = try await store.importGeneratedStems(
                    jobID: importStemsJobID, atBeat: importStemsAtBeat, setProjectTempo: importStemsSetTempo)
                var result: [String: JSONValue] = [
                    "tracks": .array(imported.map {
                        .object([
                            "trackId": .string($0.trackID.uuidString),
                            "clipId": .string($0.clipID.uuidString),
                            "trackName": .string($0.trackName),
                        ])
                    }),
                ]
                if let adoptedBPM {
                    result["adoptedTempoBPM"] = .number(adoptedBPM)
                }
                return .success(request.id, .object(result))
            } catch {
                throw await translateSongGeneratorError(error)
            }

        case "ai.repaintAudio":
            // Re-renders a WINDOW of an EXISTING audio file in place (M6
            // v-a, ACE-Step task_type "repaint" — a "part swap"/inpainting
            // job; works on BOTH the sidecar's turbo (primary, the default
            // load) and sft tiers, unlike ai.extractStems/ai.legoGenerate,
            // which are base-model-only). params: sourcePath (required —
            // local filesystem path to the existing audio file on THIS
            // machine; checked to exist before submitting, then the client
            // stages a COPY of it inside the sidecar's own temp-dir
            // allowlist, same staging as ai.extractStems). start (required
            // — seconds from the top of the file where the repainted
            // window begins, >= 0). end (optional — seconds where the
            // window ends, must be > start; omit to repaint from start to
            // the end of the file). prompt/lyrics (optional — style/
            // caption and section-labeled lyrics guiding the repainted
            // window; omit to keep the source's own musical context). mode
            // (optional — "conservative"|"balanced"|"aggressive", default
            // "balanced"). strength (optional, 0-1 — only consulted
            // upstream in "balanced" mode). wavCrossfadeSec (optional,
            // >= 0 — crossfade at the window edges in the rendered WAV;
            // omit for upstream's own 0.0 default). seed (optional integer
            // — a fresh random seed each call when omitted; call again
            // WITHOUT seed on the SAME window for a RETAKE — there is no
            // separate retake command). model (optional — DiT model
            // override; omit for the sidecar's primary handler, unlike
            // ai.extractStems/ai.legoGenerate's stems-default
            // substitution/auto-load). Response: SongGenerationSubmission
            // {jobId, state, queuePosition?} — a SINGLE (not composite) job
            // id, polled via ai.generationStatus exactly like
            // ai.generateSong.
            try params.rejectUnknownKeys(
                ["sourcePath", "start", "end", "prompt", "lyrics", "mode", "strength",
                    "wavCrossfadeSec", "seed", "model"], verb: "ai.repaintAudio")
            let repaintSourcePath = try parseRepaintSourcePath(params["sourcePath"])
            let repaintStart = try params.require("start", \.doubleValue)
            guard repaintStart >= 0 else {
                throw ControlError("'start' must be >= 0 (seconds)")
            }
            var repaintRequest = RepaintRequest(srcAudioPath: repaintSourcePath, startSeconds: repaintStart)
            if let endValue = params["end"] {
                guard let end = endValue.doubleValue else {
                    throw ControlError("'end' must be a number (seconds)")
                }
                guard end > repaintStart else {
                    throw ControlError("'end' must be greater than 'start'")
                }
                repaintRequest.endSeconds = end
            }
            repaintRequest.prompt = params["prompt"]?.stringValue
            repaintRequest.lyrics = params["lyrics"]?.stringValue
            if let modeValue = params["mode"] {
                repaintRequest.mode = try parseRepaintMode(modeValue)
            }
            if let strengthValue = params["strength"] {
                guard let strength = strengthValue.doubleValue, (0...1).contains(strength) else {
                    throw ControlError("'strength' must be a number between 0 and 1")
                }
                repaintRequest.strength = strength
            }
            if let crossfadeValue = params["wavCrossfadeSec"] {
                guard let crossfade = crossfadeValue.doubleValue, crossfade >= 0 else {
                    throw ControlError("'wavCrossfadeSec' must be a number >= 0")
                }
                repaintRequest.wavCrossfadeSec = crossfade
            }
            if let seedValue = params["seed"]?.doubleValue { repaintRequest.seed = Int(seedValue) }
            repaintRequest.model = params["model"]?.stringValue
            do {
                let submission = try await songGenerator.repaintAudio(repaintRequest)
                await noteACEJobStarted(submission.jobID)
                return .success(request.id, try JSONValue(encoding: submission))
            } catch {
                throw await translateSongGeneratorError(error)
            }

        case "ai.fixClipRegion":
            // Submits an AI repaint of a REGION of an existing timeline clip
            // (M6 v-b) — the "fix this phrase with AI" flow. SUBMIT-ONLY: this
            // bounces a dry, as-heard window of the target material (region +/-
            // context, clamped), submits it to the LOCAL ACE-Step sidecar, and
            // returns immediately — it does NOT mutate the project. Poll
            // ai.generationStatus with the returned jobId, THEN ai.importClipFix
            // to land the result as a violet take LANE comped in over exactly
            // the region. params: trackId (required), clipId (required — an
            // AUDIO clip on that track; a MIDI clip is rejected). startBeat/
            // endBeat (required numbers — ABSOLUTE timeline beats, endBeat >
            // startBeat, the region must lie inside the target's span). prompt/
            // lyrics (optional — guide the repainted window; omit to keep the
            // source's own context). mode (optional —
            // "conservative"|"balanced"|"aggressive", default "balanced").
            // strength (optional, 0-1 — only consulted upstream in "balanced"
            // mode). seed (optional integer — omit for a fresh random seed; a
            // RETAKE is this command again with the SAME region and no seed).
            // contextSeconds (optional, 1-60, default 10 — padding rendered each
            // side of the region for boundary continuity). model (optional — DiT
            // override; omit for the sidecar's primary handler). Response: the
            // placement echo {jobId, state, queuePosition?, windowStartBeat,
            // windowEndBeat, regionStartBeat, regionEndBeat, repaintStartSeconds,
            // repaintEndSeconds, bouncePath}. A pending fix does NOT survive an
            // app restart or a project switch.
            try params.rejectUnknownKeys(
                ["trackId", "clipId", "startBeat", "endBeat", "prompt", "lyrics",
                    "mode", "strength", "seed", "contextSeconds", "model"], verb: "ai.fixClipRegion")
            let fixTrackID = try params.requireTrackID()
            let fixClipID = try params.requireClipID()
            let fixStartBeat = try params.require("startBeat", \.doubleValue)
            let fixEndBeat = try params.require("endBeat", \.doubleValue)
            guard fixEndBeat > fixStartBeat else {
                throw ControlError("'endBeat' must be greater than 'startBeat'")
            }
            let fixMode = try params["mode"].map { try parseClipFixMode($0) } ?? .balanced
            var fixStrength: Double?
            if let strengthValue = params["strength"] {
                guard let strength = strengthValue.doubleValue, (0...1).contains(strength) else {
                    throw ControlError("'strength' must be a number between 0 and 1")
                }
                fixStrength = strength
            }
            var fixContextSeconds = 10.0
            if let contextValue = params["contextSeconds"] {
                guard let context = contextValue.doubleValue, (1...60).contains(context) else {
                    throw ControlError("'contextSeconds' must be a number between 1 and 60")
                }
                fixContextSeconds = context
            }
            let fixSeed = params["seed"]?.doubleValue.map { Int($0) }
            do {
                let submission = try await store.fixClipRegion(
                    trackId: fixTrackID, clipId: fixClipID,
                    startBeat: fixStartBeat, endBeat: fixEndBeat,
                    prompt: params["prompt"]?.stringValue,
                    lyrics: params["lyrics"]?.stringValue,
                    mode: fixMode, strength: fixStrength, seed: fixSeed,
                    contextSeconds: fixContextSeconds,
                    model: params["model"]?.stringValue)
                await noteACEJobStarted(submission.jobID)
                return .success(request.id, try JSONValue(encoding: submission))
            } catch {
                throw await translateSongGeneratorError(error)
            }

        case "ai.importClipFix":
            // Lands a FINISHED clip fix (M6 v-b) as a violet take LANE comped in
            // over exactly the region requested by ai.fixClipRegion — the
            // original audio is NEVER replaced, and the comp elsewhere is
            // untouched. One undoable "AI Fix Take" edit (edit.undo restores the
            // plain clip / previous comp). params: jobId (required — the id from
            // ai.fixClipRegion; the job must have reached state "succeeded", i.e.
            // ai.generationStatus reports an audioPath). Comp between the takes
            // afterwards with the take.* commands. Response: {trackId, groupId,
            // laneId, laneName ("AI Fix N"), group: <TakeGroup>}. A
            // still-running/unknown job surfaces an actionable error
            // (clipFixJobNotFound points back at ai.fixClipRegion; a target that
            // drifted beyond a pure move surfaces clipFixStale).
            try params.rejectUnknownKeys(
                ["jobId"], verb: "ai.importClipFix")
            let importFixJobID = try params.require("jobId", \.stringValue)
            do {
                let result = try await store.importClipFix(jobID: importFixJobID)
                var payload: [String: JSONValue] = [
                    "trackId": .string(result.trackID.uuidString),
                    "groupId": .string(result.groupID.uuidString),
                    "laneId": .string(result.laneID.uuidString),
                    "laneName": .string(result.laneName),
                ]
                // Return the group (the take.group response precedent) so agents
                // see lanes + comp without a snapshot round-trip.
                if let group = store.tracks.first(where: { $0.id == result.trackID })?
                    .takeGroups.first(where: { $0.id == result.groupID }) {
                    payload["group"] = try JSONValue(encoding: group)
                }
                return .success(request.id, .object(payload))
            } catch {
                throw await translateSongGeneratorError(error)
            }

        case "input.listDevices":
            try params.rejectUnknownKeys([], verb: "input.listDevices")
            return .success(request.id, try inputDeviceList())

        case "input.setDevice":
            // uid: string | null | omitted — null/omitted = system default.
            //
            // F5 HARDENING (m15-d): same "omit = destructive default" shape as
            // track.setOutput — omitting `uid` RESETS the recording source to the
            // system default, so a typo'd key would silently reset it and return
            // ok. Unknown keys are rejected with a teaching error first.
            try params.rejectUnknownKeys(
                ["uid"], verb: "input.setDevice",
                hint: "omit 'uid' (or pass it null) to select the system-default input")
            let uid: String?
            switch params["uid"] {
            case .none, .some(.null):
                uid = nil
            case .some(.string(let value)):
                uid = value
            case .some:
                throw ControlError("'uid' must be a string or null")
            }
            // Selection applies first; the returned list reflects it.
            try store.selectInputDevice(uid: uid)
            return .success(request.id, try inputDeviceList())

        case "output.listDevices":
            try params.rejectUnknownKeys([], verb: "output.listDevices")
            return .success(request.id, try outputDeviceList())

        case "output.setDevice":
            // uid: string | null | omitted — null/omitted = follow the system
            // default output.
            //
            // F5 HARDENING (m15-d shape, copied deliberately — see
            // input.setDevice): this is the same "omit = destructive default"
            // class, and MORE so, because resetting the output is immediately
            // audible (sound jumps back to the laptop speakers mid-session).
            // A typo'd key must never be the thing that does that, so unknown
            // keys are rejected with a teaching error first.
            try params.rejectUnknownKeys(
                ["uid"], verb: "output.setDevice",
                hint: "omit 'uid' (or pass it null) to select the system-default output")
            let outputUID: String?
            switch params["uid"] {
            case .none, .some(.null):
                outputUID = nil
            case .some(.string(let value)):
                outputUID = value
            case .some:
                throw ControlError("'uid' must be a string or null")
            }
            // Selection applies first; the returned list reflects it (the
            // caller reads the new pin straight off `isSelected`).
            try store.selectOutputDevice(uid: outputUID)
            return .success(request.id, try outputDeviceList())

        case "midi.listInputs":
            // No params. MIDI input sources as CoreMIDI enumerates them
            // (hot-plug refreshes the list; the first call may lazily create
            // the engine's MIDI client). Wire shape:
            // {"inputs": [{uniqueID, name, isVirtual, isOnline}, ...]}.
            try params.rejectUnknownKeys([], verb: "midi.listInputs")
            return .success(request.id, .object([
                "inputs": try JSONValue(encoding: store.listMIDIInputs()),
            ]))

        case "midi.getControlMap":
            // m28-knob. No params. Reads the CC→target mapping table, the
            // catalogue of things a control CAN drive, and the last controller
            // change seen.
            //
            // ⚠️ PASSIVE ON PURPOSE — unlike midi.listInputs this does NOT bring
            // the CoreMIDI client up, because reading a table must not open the
            // user's MIDI devices. `midi.learnControl` is the verb that does.
            try params.rejectUnknownKeys([], verb: "midi.getControlMap")
            return .success(request.id, midiControlMapPayload())

        case "midi.setControlMap":
            // m28-knob. Replaces the WHOLE table: {"bindings": [...]}, and
            // `[]` clears it. A full SET rather than add/remove actions — an
            // agent reads the map and writes it back, idempotently, and there is
            // one shape on the wire instead of an action discriminator.
            try params.rejectUnknownKeys(["bindings"], verb: "midi.setControlMap",
                                         hint: "'bindings' is the WHOLE table — [] clears it")
            guard let rawBindings = params["bindings"]?.arrayValue else {
                throw ControlError(
                    "'bindings' must be an array of {target, controller, channel?, sourceId?, "
                    + "inverted?} — it replaces the whole table, and [] clears it")
            }
            var newBindings: [MIDIControlBinding] = []
            for (index, raw) in rawBindings.enumerated() {
                guard let entry = raw.objectValue else {
                    throw ControlError("bindings[\(index)] must be an object")
                }
                guard let targetRaw = entry["target"]?.stringValue,
                      let target = MIDIControlTarget(rawValue: targetRaw) else {
                    throw ControlError(
                        "bindings[\(index)].target must be one of "
                        + MIDIControlTarget.allCases.map(\.rawValue).joined(separator: ", "))
                }
                guard let controller = try Self.optionalInteger(
                        entry["controller"], "bindings[\(index)].controller"),
                      (0...127).contains(controller) else {
                    throw ControlError("bindings[\(index)].controller must be 0…127")
                }
                var channel: Int?
                if let raw = entry["channel"], raw != .null {
                    guard let value = try Self.optionalInteger(
                            raw, "bindings[\(index)].channel"),
                          (0...15).contains(value) else {
                        throw ControlError(
                            "bindings[\(index)].channel must be 0…15, or omitted for omni")
                    }
                    channel = value
                }
                var sourceID: Int32?
                if let raw = entry["sourceId"], raw != .null {
                    guard let value = try Self.optionalInteger(
                            raw, "bindings[\(index)].sourceId"),
                          let narrowed = Int32(exactly: value) else {
                        throw ControlError(
                            "bindings[\(index)].sourceId must be a MIDI source uniqueID (see "
                            + "midi.listInputs), or omitted to accept any device")
                    }
                    sourceID = narrowed
                }
                newBindings.append(
                    MIDIControlBinding(target: target, controller: controller,
                                       channel: channel, sourceID: sourceID,
                                       inverted: entry["inverted"]?.boolValue ?? false))
            }
            store.setMIDIControlBindings(newBindings)
            return .success(request.id, midiControlMapPayload())

        case "midi.learnControl":
            // m28-knob. Arms MIDI learn — {"target": "..."} — so the NEXT
            // controller change binds to that target. {"cancel": true} disarms.
            //
            // ⭐ ARMING BRINGS THE MIDI CLIENT UP, and that is the whole reason
            // this is its own verb rather than a field on setControlMap: the
            // client is created lazily (first armed instrument track, or the
            // first midi.listInputs), so a learn armed against a client that
            // never existed hears nothing at all — and "turn the knob, nothing
            // happens" is indistinguishable from a broken mapping. The response
            // carries the inputs the engine can see so the caller can say "no
            // MIDI inputs are connected" instead of waiting forever.
            try params.rejectUnknownKeys(["target", "cancel"], verb: "midi.learnControl",
                                         hint: "either 'target' to arm, or 'cancel': true")
            if params["cancel"]?.boolValue == true {
                store.cancelMIDIControlLearn()
                return .success(request.id, midiControlMapPayload())
            }
            guard let learnRaw = params["target"]?.stringValue,
                  let learnTarget = MIDIControlTarget(rawValue: learnRaw) else {
                throw ControlError(
                    "'target' must be one of "
                    + MIDIControlTarget.allCases.map(\.rawValue).joined(separator: ", ")
                    + " — or pass 'cancel': true to disarm")
            }
            let learnInputs = store.armMIDIControlLearn(target: learnTarget)
            var learnPayload = midiControlMapPayload().objectValue ?? [:]
            learnPayload["inputs"] = try JSONValue(encoding: learnInputs)
            if learnInputs.filter(\.isOnline).isEmpty {
                learnPayload["hint"] = .string(
                    "Learn is armed, but the engine sees no ONLINE MIDI input — nothing can be "
                    + "learned until a controller is connected. Check midi.listInputs.")
            } else {
                learnPayload["hint"] = .string(
                    "Learn is armed. Turn the knob you want on \(learnTarget.displayName); the "
                    + "first controller change binds to it.")
            }
            return .success(request.id, .object(learnPayload))

        case "note.audition":
            // Sounds notes NOW on an instrument track, outside the timeline
            // (m23-d). Not an edit: nothing is written to any clip. Works with
            // the transport stopped AND while playing — scheduled notes keep
            // sounding untouched, because audition rides its own per-renderer
            // ring and its own overflow policy.
            //
            // Auto-releases after `durationMs` (an agent has no mouse-up), and
            // the render side runs a 3 s liveness watchdog under that, so no
            // call can leave a stuck note. There is deliberately NO
            // `note.auditionStop` verb and no `pitch` singular alias.
            try params.rejectUnknownKeys(
                ["trackId", "pitches", "velocity", "durationMs"], verb: "note.audition",
                hint: "'pitches' is an array of MIDI note numbers (1…8 of them, each 0…127)")
            let auditionTrackID = try params.requireTrackID()
            guard case .some(.array(let rawPitches)) = params["pitches"] else {
                throw ControlError("'pitches' must be an array of MIDI note numbers (0…127)")
            }
            var auditionPitches: [Int] = []
            for entry in rawPitches {
                guard let number = entry.doubleValue, Self.isInteger(number) else {
                    throw ControlError("every entry in 'pitches' must be an integer 0…127")
                }
                auditionPitches.append(Int(number))
            }
            let auditionVelocity = try Self.optionalInteger(params["velocity"], "'velocity'")
                ?? AuditionController.defaultVelocity
            let auditionDuration = try Self.optionalInteger(params["durationMs"], "'durationMs'")
                ?? AuditionController.defaultDurationMs
            let auditionResult = try store.auditionNote(
                trackID: auditionTrackID, pitches: auditionPitches,
                velocity: auditionVelocity, durationMs: auditionDuration)
            var auditionPayload: [String: JSONValue] = [
                "trackId": .string(auditionResult.trackID.uuidString),
                "pitches": .array(auditionResult.pitches.map { .number(Double($0)) }),
                "velocity": .number(Double(auditionResult.velocity)),
                "durationMs": .number(Double(auditionResult.durationMs)),
                "audible": .bool(auditionResult.isAudible),
            ]
            if let reason = Self.auditionReason(auditionResult.outcome) {
                // A real answer, not an error: the notes WERE delivered in
                // every inaudible* case — the strip is silent for a reason the
                // caller can act on.
                auditionPayload["reason"] = .string(reason)
            }
            // The instrument's LOAD status rides the reply for the two kinds
            // whose readiness can lag the call — `soundBank` and `audioUnit`
            // share the one registry slot (§6.1), and a patch set moments ago
            // may still be preparing. `audible` and this field read the registry
            // through DIFFERENT questions ("is there a prepared instrument?" vs
            // "what status did the engine record?"), so they can legitimately
            // disagree for an instant: an agent that saw `audible:true` next to
            // `"pending"` learns to retry instead of concluding the patch it
            // just set is what sounded. Reported for those two kinds ONLY —
            // `polySynth`/`sampler`/`testTone` hold no registry slot, so the
            // default-`pending` fallback would read as a stall that cannot
            // happen (`SamplerInstrument` loads its zones synchronously).
            if let auditionKind = store.tracks.first(where: { $0.id == auditionTrackID })?
                .instrument?.kind, auditionKind == .audioUnit || auditionKind == .soundBank {
                auditionPayload["instrumentStatus"] =
                    .string(instrumentStatusString(auditionTrackID))
            }
            return .success(request.id, .object(auditionPayload))

        case "pad.previewEffort":
            // Breath pad P6 — the LIVE DRAG PREVIEW. Streams one effort value
            // (0…1) to the track's instrument as a controller, right now,
            // outside the timeline. Sibling of note.audition above: same
            // per-renderer ring, same "sounds but is not the record" contract.
            //
            // ⛔ GESTURE-SCOPED ON THE WIRE, NOT ONLY IN THE UI. A move with no
            // begin is REFUSED. That refusal is what makes the design's rule
            // ("the pad NEVER streams while the transport merely rolls") a
            // property of the protocol rather than of one view's code: with no
            // gesture ever opened, what sounds is the committed lane and nothing
            // else, so playback, replay and a bounce agree sample-for-sample.
            //
            // ⛔ end DOES NOT PARK THE LAST VALUE — it restores the controller's
            // neutral default (127 for CC 11). A CC is sticky and nothing takes
            // it back, so parking one would make the next playback quieter than
            // a fresh bounce of the same project. See PadPreviewController.
            // ⚠️ Neutral is not the same as the track's COMMITTED lane, and on a
            // track that has one it measurably is not — the scope, the direction
            // of the error and the shared-merge fix are in that type's "THE
            // LIMIT OF RULE 3" (roadmap m28-p6b).
            //
            // No undo entry, no clip mutation: the record is the controller lane
            // that the effort-shape verb writes.
            try params.rejectUnknownKeys(
                ["trackId", "value", "gesture", "expressionCC"], verb: "pad.previewEffort",
                hint: "'gesture' is one of begin/move/end — the pad streams ONLY between a "
                    + "begin and its end")
            let padTrackID = try params.requireTrackID()
            guard let padGestureRaw = params["gesture"]?.stringValue else {
                throw ControlError(
                    "'gesture' must be one of "
                    + PadPreviewPhase.allCases.map(\.rawValue).joined(separator: ", "))
            }
            guard let padPhase = PadPreviewPhase(rawValue: padGestureRaw) else {
                throw ControlError(
                    "'gesture' must be one of "
                    + PadPreviewPhase.allCases.map(\.rawValue).joined(separator: ", ")
                    + " — got '\(padGestureRaw)'")
            }
            // `end` carries no effort by construction (it restores neutral), so
            // omitting `value` there is legal and 0 is a placeholder that is
            // never read.
            let padValue: Double
            if padPhase == .end {
                padValue = params["value"]?.doubleValue ?? 0
            } else {
                guard let asked = params["value"]?.doubleValue else {
                    throw ControlError("'value' must be a number 0…1 (the pad's effort scale)")
                }
                padValue = asked
            }
            // Mirrors the option of the same name on the effort-shape verb, so a
            // caller that commits to a non-default lane can preview THAT lane
            // instead of previewing one nothing on the track reads.
            let padCC = try Self.optionalInteger(params["expressionCC"], "'expressionCC'")
                ?? PadPreviewController.defaultExpressionCC
            let padResult = try store.previewEffort(
                trackID: padTrackID, value: padValue, phase: padPhase, expressionCC: padCC)
            var padPayload: [String: JSONValue] = [
                "trackId": .string(padResult.trackID.uuidString),
                "gesture": .string(padResult.phase.rawValue),
                "controller": .number(Double(padResult.controller)),
                "controllerValue": .number(Double(padResult.controllerValue)),
                "streaming": .bool(padResult.streaming),
                "delivered": .bool(padResult.delivered),
                "audible": .bool(padResult.isAudible),
            ]
            if let padEffort = padResult.effort {
                padPayload["value"] = .number(padEffort)
            }
            if let reason = Self.auditionReason(padResult.outcome) {
                // A real answer, not an error — the same contract note.audition
                // carries: the controller WAS delivered in every inaudible*
                // case, the strip is just silent for a reason worth acting on.
                padPayload["reason"] = .string(reason)
            }
            return .success(request.id, .object(padPayload))

        case "project.snapshot":
            try params.rejectUnknownKeys([], verb: "project.snapshot")
            return .success(request.id, try snapshotJSON())

        case "project.overview":
            // No params. Agent-facing summary projection (M7): the same
            // session `project.snapshot` reports at full fidelity, but
            // counts-not-lists everywhere a list can grow unbounded (note
            // counts instead of notes, point counts instead of points) and
            // no file paths — a few KB an agent can afford to re-read on
            // every turn to re-orient. Wire shape mirrors `ProjectOverview`
            // directly (no wrapping key): {transport, master, tracks: [...]}.
            try params.rejectUnknownKeys([], verb: "project.overview")
            return .success(request.id, try JSONValue(encoding: store.overview()))

        // in mcp-server/src/index.ts (see /mcp-verify) — matching these routes.
        case "project.save":
            // path optional: absolute or ~-prefixed .dawproj destination; omit
            // to save in place (an untitled session throws projectPathRequired).
            // transportBusy/saveFailed surface via the LocalizedError mapping.
            //
            // RECOVERY HONESTY (m16-e, audit F3): saveProject() unconditionally
            // invalidates any pending crash-recovery offer (a titled save supersedes
            // it — the work is now safely on disk where the user put it). Before
            // this fix that consumption was SILENT; the response now carries
            // `discardedRecovery` (the offer's own facts — see
            // `discardedRecoveryField`) whenever this call is the one that cleared
            // an offer that was still available beforehand. Absent when there was
            // nothing to discard (the common case).
            try params.rejectUnknownKeys(
                ["path"], verb: "project.save")
            let savePath = params["path"]?.stringValue
            let pendingBeforeSave = store.recoveryStatus()
            let result = try store.saveProject(to: savePath)
            var saveResult = try JSONValue(encoding: result).objectValue ?? [:]
            if let discarded = try discardedRecoveryField(before: pendingBeforeSave) {
                saveResult["discardedRecovery"] = discarded
            }
            return .success(request.id, .object(saveResult))

        case "project.open":
            // path required. discardChanges (default false) abandons unsaved
            // edits instead of flushing them first. Returns the media warnings
            // plus the full post-open snapshot. transportBusy/openFailed/
            // malformedProject/newerProjectVersion/unsavedChanges surface via the
            // LocalizedError mapping.
            //
            // RECOVERY HONESTY (m16-e, audit F3): same `discardedRecovery` honesty
            // as project.save/project.new — opening another project supersedes a
            // pending crash offer via the SAME `invalidateCrashRecovery()` call.
            try params.rejectUnknownKeys(
                ["path", "discardChanges"], verb: "project.open")
            let openPath = try params.require("path", \.stringValue)
            let discard = params["discardChanges"]?.boolValue ?? false
            let pendingBeforeOpen = store.recoveryStatus()
            let warnings = try store.openProject(at: openPath, discardChanges: discard)
            var openResult: [String: JSONValue] = [
                "warnings": .array(warnings.map(JSONValue.string)),
                "snapshot": try snapshotJSON(),
            ]
            if let discarded = try discardedRecoveryField(before: pendingBeforeOpen) {
                openResult["discardedRecovery"] = discarded
            }
            return .success(request.id, .object(openResult))

        case "project.new":
            // discardChanges (default false) abandons unsaved edits instead of
            // flushing them first. transportBusy/unsavedChanges surface via the
            // LocalizedError mapping.
            //
            // RECOVERY HONESTY (m16-e, audit F3): this is the audit's LIVED case —
            // the staging-normalization law every agent follows opens a session
            // with `project.new`, which silently ran `AutosaveManager.invalidate()`
            // and destroyed a real crash's recovery offer with no signal in the
            // response. DESIGN DECISION (chosen over a refuse-once `discardRecovery:
            // true` gate): an honesty FIELD, not a refusal — refusing every
            // new/open/save whenever an unconsumed offer exists would put friction
            // on the ordinary "I don't want to recover, start fresh" flow (the
            // common case right after any crash-adjacent launch), and no existing
            // caller breaks. The response instead carries `discardedRecovery:
            // {savedAt, sourcePath?, editCount}` — the exact offer that was just
            // superseded — whenever this call is the one that cleared it (checked
            // by comparing `store.recoveryStatus()` before/after; absent when
            // nothing was on offer). `project.recover` is UNCHANGED — its own
            // `recovered`/`discarded` fields already say honestly that the offer
            // was consumed on purpose, so it does not also carry this field.
            try params.rejectUnknownKeys(
                ["discardChanges"], verb: "project.new")
            let discardNew = params["discardChanges"]?.boolValue ?? false
            let pendingBeforeNew = store.recoveryStatus()
            try store.newProject(discardChanges: discardNew)
            var newResult = try snapshotJSON().objectValue ?? [:]
            if let discarded = try discardedRecoveryField(before: pendingBeforeNew) {
                newResult["discardedRecovery"] = discarded
            }
            return .success(request.id, .object(newResult))

        case "project.recoveryStatus":
            // No params. Crash-recovery offer (M9 crash-b): whether the LAST
            // session ended unexpectedly (a crash / SIGKILL left its lock) AND a
            // rolling autosave snapshot is on disk to restore. Response =
            // AutosaveRecoveryStatus verbatim: {available, savedAt?, sourcePath?,
            // editCount?} — `savedAt` is ISO-8601 (m16-e, audit F8a; was raw
            // Apple-epoch seconds). Readable anytime; headless-safe — a session
            // that never ran crash detection, or no Autosave dir, reads
            // {available:false}.
            try params.rejectUnknownKeys([], verb: "project.recoveryStatus")
            return .success(request.id, try JSONValue(encoding: store.recoveryStatus()))

        case "project.recoveryBundles":
            // No params. Wire-discoverable listing of the PER-SLUG untitled-
            // recovery bundles (m16-e, audit F3) — distinct from the single
            // rolling crash-recovery snapshot `project.recoveryStatus` describes.
            // Every dirty UNTITLED session flushed via new/open (`flushForTransition`)
            // writes one `Untitled-<slug8>.dawproj` under the Autosave directory;
            // up to `pruneUntitledRecoveryBundles`'s grace window these accumulate
            // invisibly on disk with no wire path to find them (the audit's own
            // "softener" — the 41-track session's flush landed one of these, but no
            // verb could list or open it). Each is a REGULAR `.dawproj` bundle —
            // `project.open {path}` already opens one directly, so this is a listing
            // seam only, not a new open primitive. Response: {"bundles":
            // [{path, savedAt (ISO-8601 file modification time), isCurrentSession}]},
            // newest-first (mirrors `pruneUntitledRecoveryBundles`'s own ordering).
            // `isCurrentSession` flags THIS store's own slug (the file it would
            // write on its next flush) so an agent doesn't try to recover its own
            // live session's safety copy. Never throws — an unreadable/missing
            // Autosave directory reads an empty list.
            try params.rejectUnknownKeys([], verb: "project.recoveryBundles")
            let recoveryBundleFormatter = ISO8601DateFormatter()
            return .success(request.id, .object([
                "bundles": .array(store.untitledRecoveryBundles().map { entry in
                    .object([
                        "path": .string(entry.path),
                        "savedAt": .string(recoveryBundleFormatter.string(from: entry.savedAt)),
                        "isCurrentSession": .bool(entry.isCurrentSession),
                    ])
                }),
            ]))

        case "project.recover":
            // params: accept (required bool). accept:true loads the autosave INTO
            // the store (the project becomes the recovered content, kept DIRTY,
            // sourcePath restored so a later save lands on the original file), then
            // drops the snapshot → {recovered:true, warnings:[...], snapshot}.
            // accept:false drops the snapshot + clears the offer → {discarded:true}.
            // No offer available + accept:true → noRecoveryAvailable via the
            // LocalizedError mapping.
            try params.rejectUnknownKeys(
                ["accept"], verb: "project.recover")
            let accept = try params.require("accept", \.boolValue)
            switch try store.recoverFromAutosave(accept: accept) {
            case .recovered(let warnings):
                return .success(request.id, .object([
                    "recovered": .bool(true),
                    "warnings": .array(warnings.map(JSONValue.string)),
                    "snapshot": try snapshotJSON(),
                ]))
            case .discarded:
                return .success(request.id, .object(["discarded": .bool(true)]))
            }

        case "app.feedbackBundle":
            // params: includeProject? (bool, default false). Writes ONE local
            // diagnostics FOLDER (M9 beta) — `feedback-<timestamp>/` under
            // ~/Library/Application Support/DAWPro/Feedback/ — that makes a bug
            // report actionable: a manifest (app/OS/build/hardware, NO key
            // material), engine.json (the M9 watchdog + performance snapshots),
            // overview.json (the counts-only project projection — no note content,
            // no media paths), a crashes/ copy of recent DAWApp*.ips reports, and,
            // ONLY when includeProject:true, the full project.dawproject snapshot.
            // Everything LOCAL — nothing phones home. Response =
            // FeedbackBundleSummary verbatim: {path, fileCount, byteCount,
            // crashReportCount, includesProject}. Never throws except a real
            // filesystem failure (DiagnosticsError.writeFailed via the
            // LocalizedError mapping); headless-safe (engine snapshots read idle).
            try params.rejectUnknownKeys(
                ["includeProject"], verb: "app.feedbackBundle")
            let includeProject = params["includeProject"]?.boolValue ?? false
            return .success(request.id,
                            try JSONValue(encoding: store.writeFeedbackBundle(includeProject: includeProject)))

        case "app.connectionInfo":
            // No params. Read-only description of THIS control endpoint (beta
            // m10-l): the loopback WebSocket URL + bound port the agent reached the
            // app on, where the port came from ("environment" = the
            // DAW_CONTROL_PORT override, "settings" = the in-app port field,
            // "default" = the built-in 17600), and that built-in default for
            // reference. Endpoint description ONLY — no key material. The port is
            // deliberately READ-only on the wire: changing it can sever the caller's
            // own connection, so it stays a human decision in Settings (the
            // API-key-entry split precedent). Never throws. Response: {url, port,
            // source, defaultPort}.
            try params.rejectUnknownKeys([], verb: "app.connectionInfo")
            return .success(request.id, .object([
                "url": .string(connectionInfo.url),
                "port": .number(Double(connectionInfo.port)),
                "source": .string(connectionInfo.source),
                "defaultPort": .number(Double(connectionInfo.defaultPort)),
            ]))

        case "ai.copilotSend":
            // Starts a new in-app Copilot turn (M6 rail-c) — the copilot drives
            // the SAME command surface as this router, in-process, through its
            // own curated tool catalog (CopilotToolCatalog; excludes ai.copilot*
            // itself, so recursion is impossible by construction). params:
            // message (required, non-empty — the user's instruction). Returns
            // immediately: {turnId, status: "running"}; the turn runs
            // asynchronously — poll ai.copilotState with the returned turnId.
            // Throws if a turn is already running (poll/reset first), if no AI
            // provider is configured (actionable Settings ⌘, message — never a
            // key value), or if the engine isn't wired yet.
            //
            // Optional param `maxRounds` (number, beta m10-m): a per-turn override of
            // the tool-round budget, outranking the app setting for THIS turn only. It
            // is clamped into CopilotLimits.validRange (1–32) — 0 → 1, 99 → 32 — so it
            // never errors; omit it to honor the app's configured value. Existing
            // callers that don't pass it behave exactly as before.
            try params.rejectUnknownKeys(
                ["message", "maxRounds"], verb: "ai.copilotSend")
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            let copilotMessage = try params.require("message", \.stringValue)
            guard !copilotMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ControlError("'message' must not be empty")
            }
            let copilotMaxRoundsOverride = params["maxRounds"]?.doubleValue.map { Int($0) }
            let copilotTurnID = try copilotEngine.send(copilotMessage, maxRoundsOverride: copilotMaxRoundsOverride)
            return .success(request.id, .object([
                "turnId": .string(copilotTurnID),
                "status": .string("running"),
            ]))

        case "ai.copilotState":
            // Polls the Copilot's session state (the ai.generateSong/
            // ai.generationStatus poll precedent). params: turnId (optional —
            // filters the transcript to one turn; omit for the whole session).
            // Response: {status, currentTurnId?, transcript: [{id, turnId, kind,
            // text?, command?, ok?, summary?}], limits: {maxRounds,
            // defaultMaxRounds, validMin, validMax}}. The `limits` object (beta
            // m10-m) echoes the effective per-turn round budget + fixed policy so a
            // client can surface/respect it. An UNKNOWN turnId is not an error: it
            // returns the engine's current status with an empty filtered transcript
            // (poller-friendly).
            try params.rejectUnknownKeys(["turnId"], verb: "ai.copilotState")
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            let stateTurnID = params["turnId"]?.stringValue
            return .success(request.id, copilotEngine.stateJSON(turnID: stateTurnID))

        case "ai.copilotReset":
            // Cancels any in-flight turn and ARCHIVES the conversation into the
            // project's saved chat history (chat-persist design §1/§6.5, m16-e
            // seeded the no-params shape) — reset() is "archive and start
            // fresh", never destructive; the one destructive verb is
            // ai.copilotDeleteChat (L5). No params. Response gains additive
            // {archivedChatId?, evictedChatId?}: archivedChatId is present when
            // the conversation held at least one entry (nothing to archive on
            // an already-empty chat); evictedChatId is present only when
            // archiving pushed the project's archive past its cap
            // (CopilotChatLimits.maxArchivedChats) and the oldest archived chat
            // was dropped to make room — never silent (§7.1). Both absent when
            // nothing was archived/evicted, so a caller that ignores the
            // result sees identical behavior modulo the chat list growing.
            try params.rejectUnknownKeys([], verb: "ai.copilotReset")
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            let resetResult = copilotEngine.reset()
            var resetFields: [String: JSONValue] = [:]
            if let archivedChatId = resetResult.archivedChatId {
                resetFields["archivedChatId"] = .string(archivedChatId.uuidString)
            }
            if let evictedChatId = resetResult.evictedChatId {
                resetFields["evictedChatId"] = .string(evictedChatId.uuidString)
            }
            return .success(request.id, resetFields.isEmpty ? nil : .object(resetFields))

        case "ai.copilotGetModel":
            // Reads the copilot's currently effective Anthropic model plus
            // the curated picker (M10-p-6). No params. Response: {model,
            // catalog: [{id, name, note}]} — `catalog` is
            // `AnthropicModelCatalog.curated` (the SAME table
            // `ai.copilotSetModel`'s validation and the per-model
            // max-output/thinking-config behavior read — see
            // `AnthropicModelCatalog`), so the picker can never drift from
            // what the engine actually does. A future UI phase renders this
            // directly; this command exists so an agent/tester can drive
            // model selection without one.
            try params.rejectUnknownKeys([], verb: "ai.copilotGetModel")
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            return .success(request.id, .object([
                "model": .string(copilotEngine.currentModel),
                "catalog": .array(AnthropicModelCatalog.curated.map { info in
                    .object([
                        "id": .string(info.id),
                        "name": .string(info.name ?? info.id),
                        "note": .string(info.note ?? ""),
                    ])
                }),
            ]))

        case "ai.copilotSetModel":
            // Sets the copilot's model for subsequent turns (M10-p-6).
            // params: model (required — a curated id from
            // ai.copilotGetModel's `catalog`, e.g. "claude-sonnet-5").
            // Unknown/uncurated ids throw a teaching error listing every
            // valid id rather than silently falling back — the same
            // "actionable, never silent" contract as every other copilot
            // command. Takes effect on the NEXT turn (no need to reject
            // mid-turn: an in-flight turn already resolved its provider).
            // Response echoes the now-effective model: {model}.
            try params.rejectUnknownKeys(["model"], verb: "ai.copilotSetModel")
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            let requestedModel = try params.require("model", \.stringValue)
            guard AnthropicModelCatalog.curated.contains(where: { $0.id == requestedModel }) else {
                let validIDs = AnthropicModelCatalog.curated.map(\.id).joined(separator: ", ")
                throw ControlError("unknown copilot model '\(requestedModel)' — valid ids: \(validIDs)")
            }
            copilotEngine.setModel(requestedModel)
            return .success(request.id, .object(["model": .string(requestedModel)]))

        case "ai.copilotChats":
            // Lists every saved copilot conversation in the OPEN project
            // (chat-persist design §6.1): every ARCHIVED chat
            // (`store.copilotChats`) plus the ACTIVE conversation, but only
            // when it holds at least one entry (a fresh empty chat is not
            // noise-listed — `persistableChatSnapshot()` already returns nil
            // for one, so that single call doubles as the presence check).
            // No params. Response: {chats: [{chatId, title, createdAt,
            // updatedAt, entryCount, model?, active?, droppedEntries?}],
            // activeChatId}. Sorted by `updatedAt` descending — the store
            // keeps its archive unsorted (it doesn't need order internally;
            // `copilotChatsForPersistence()` sorts ASCENDING for disk, a
            // different, save-path concern), so this is the one sort point
            // for the wire. `active: true` is present only on the engine's
            // current chat (the `partial` absent-when-false precedent);
            // `model`/`droppedEntries` are present only when set/> 0.
            // `activeChatId` is always present, even when the active chat
            // isn't listed (empty). Never throws beyond the engine-wired
            // guard.
            try params.rejectUnknownKeys([], verb: "ai.copilotChats")
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            let chatsFormatter = ISO8601DateFormatter()
            var chatRows: [(chat: CopilotChatDocument, isActive: Bool)] =
                store.copilotChats.map { ($0, false) }
            if let activeSnapshot = copilotEngine.persistableChatSnapshot() {
                chatRows.append((activeSnapshot, true))
            }
            chatRows.sort { $0.chat.updatedAt > $1.chat.updatedAt }
            let chatsJSON: [JSONValue] = chatRows.map { row in
                var object: [String: JSONValue] = [
                    "chatId": .string(row.chat.id.uuidString),
                    "title": .string(row.chat.title),
                    "createdAt": .string(chatsFormatter.string(from: row.chat.createdAt)),
                    "updatedAt": .string(chatsFormatter.string(from: row.chat.updatedAt)),
                    "entryCount": .number(Double(row.chat.transcript.count)),
                ]
                if let model = row.chat.model {
                    object["model"] = .string(model)
                }
                if row.isActive {
                    object["active"] = .bool(true)
                }
                if let dropped = row.chat.droppedEntries, dropped > 0 {
                    object["droppedEntries"] = .number(Double(dropped))
                }
                return .object(object)
            }
            return .success(request.id, .object([
                "chats": .array(chatsJSON),
                "activeChatId": .string(copilotEngine.currentChatID.uuidString),
            ]))

        case "ai.copilotResumeChat":
            // Resumes an archived chat so it can be continued with
            // ai.copilotSend (chat-persist design §6.2): archives the
            // CURRENT non-empty conversation first (L5 — never lost; its id
            // rides back additively as "archivedChatId" when that
            // happened), then restores the chosen chat's transcript and
            // SANITIZED provider history. Safe after a model switch by
            // construction — persisted history never carries thinking
            // blocks (L1), so any curated model can continue the
            // conversation. params: chatId (required, the FULL UUID from
            // ai.copilotChats — chat ids are not in the copilot's 8-char
            // idMap). Response: {chatId, title, entryCount, droppedEntries?,
            // status: "idle", archivedChatId?} (droppedEntries only when >
            // 0). Throws while a turn is running ("a copilot turn is
            // already running — wait for it (poll ai.copilotState) or
            // ai.copilotReset to cancel and archive it first"), for an
            // unknown id ("unknown chatId '<value>' — list chats with
            // ai.copilotChats"), or for a malformed chatId ("'chatId' must
            // be a UUID (from ai.copilotChats)").
            try params.rejectUnknownKeys(["chatId"], verb: "ai.copilotResumeChat")
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            let resumeChatIdRaw = try params.require("chatId", \.stringValue)
            guard let resumeChatId = UUID(uuidString: resumeChatIdRaw) else {
                throw ControlError("'chatId' must be a UUID (from ai.copilotChats)")
            }
            let resumeResult = try copilotEngine.resumeChat(id: resumeChatId)
            var resumeFields: [String: JSONValue] = [
                "chatId": .string(copilotEngine.currentChatID.uuidString),
                "title": .string(copilotEngine.chatTitle ?? ""),
                "entryCount": .number(Double(copilotEngine.transcript.count)),
                "status": .string(copilotEngine.status.rawValue),
            ]
            if copilotEngine.chatDroppedEntries > 0 {
                resumeFields["droppedEntries"] = .number(Double(copilotEngine.chatDroppedEntries))
            }
            if let archivedChatId = resumeResult.archivedChatId {
                resumeFields["archivedChatId"] = .string(archivedChatId.uuidString)
            }
            return .success(request.id, .object(resumeFields))

        case "ai.copilotDeleteChat":
            // Permanently deletes a chat — the ONE destructive chat verb
            // (chat-persist design §6.3, L5). Deleting the ACTIVE chat is
            // allowed only while no turn is running: it drops the
            // conversation permanently and mints a fresh empty chat
            // (wasActive: true in the response). Deleting an ARCHIVED chat
            // is allowed any time. params: chatId (required, full UUID).
            // Response: {deleted: true, chatId, wasActive}. Throws for an
            // unknown id ("unknown chatId '<value>' — list chats with
            // ai.copilotChats"), a malformed chatId ("'chatId' must be a
            // UUID (from ai.copilotChats)"), or deleting the active chat
            // while a turn is running ("chat '<id>' is the active
            // conversation and a turn is running — cancel it first
            // (ai.copilotReset) or wait").
            try params.rejectUnknownKeys(["chatId"], verb: "ai.copilotDeleteChat")
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            let deleteChatIdRaw = try params.require("chatId", \.stringValue)
            guard let deleteChatId = UUID(uuidString: deleteChatIdRaw) else {
                throw ControlError("'chatId' must be a UUID (from ai.copilotChats)")
            }
            let wasActive = try copilotEngine.deleteChat(id: deleteChatId)
            return .success(request.id, .object([
                "deleted": .bool(true),
                "chatId": .string(deleteChatId.uuidString),
                "wasActive": .bool(wasActive),
            ]))

        case "ai.copilotRenameChat":
            // Renames a chat, active or archived (chat-persist design §6.4).
            // params: chatId (required, full UUID), title (required,
            // non-empty after trimming whitespace — the ai.copilotSend
            // empty-message precedent). Over-length titles are CLAMPED to
            // CopilotChatLimits.maxTitleLength (never an error) — the clamp
            // is computed here identically to CopilotEngine.renameChat's own
            // clamp, so the echoed title always matches what was actually
            // stored. Response: {chatId, title} (the stored, possibly
            // clamped title). Throws for an unknown id ("unknown chatId
            // '<value>' — list chats with ai.copilotChats"), a malformed
            // chatId ("'chatId' must be a UUID (from ai.copilotChats)"), or
            // an empty title ("'title' must not be empty").
            try params.rejectUnknownKeys(["chatId", "title"], verb: "ai.copilotRenameChat")
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            let renameChatIdRaw = try params.require("chatId", \.stringValue)
            guard let renameChatId = UUID(uuidString: renameChatIdRaw) else {
                throw ControlError("'chatId' must be a UUID (from ai.copilotChats)")
            }
            let renameTitle = try params.require("title", \.stringValue)
            guard !renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ControlError("'title' must not be empty")
            }
            try copilotEngine.renameChat(id: renameChatId, title: renameTitle)
            let clampedRenameTitle = String(renameTitle.prefix(CopilotChatLimits.maxTitleLength))
            return .success(request.id, .object([
                "chatId": .string(renameChatId.uuidString),
                "title": .string(clampedRenameTitle),
            ]))

        case "edit.undo":
            // No params (m16-e, audit F5 survey). Reverses the last edit.
            // nothingToUndo/transportBusy surface via the LocalizedError
            // mapping. Result carries the reversed label plus the full
            // post-undo snapshot so agents re-orient in one round trip.
            try params.rejectUnknownKeys([], verb: "edit.undo")
            let label = try store.undo()
            return .success(request.id, .object([
                "undone": .string(label),
                "snapshot": try snapshotJSON(),
            ]))

        case "edit.redo":
            // No params (m16-e, audit F5 survey). Reapplies the last undone
            // edit; mirror of edit.undo.
            try params.rejectUnknownKeys([], verb: "edit.redo")
            let label = try store.redo()
            return .success(request.id, .object([
                "redone": .string(label),
                "snapshot": try snapshotJSON(),
            ]))

        case "edit.history":
            // Read-only projection of the labeled undo/redo stacks (m11-b) — the
            // backing for the history panel. Adds NO mutation surface: stepping
            // through history is still repeated edit.undo/edit.redo (which keep the
            // coalescing barrier + mid-take transportBusy guard). No params.
            //
            // Result: {undo: [String], redo: [String], canUndo: Bool, canRedo:
            // Bool}. Both lists are NEWEST-FIRST: undo[0] is the label edit.undo
            // reverses NEXT (then progressively OLDER edits); redo[0] is the label
            // edit.redo reapplies NEXT (then edits undone EARLIER). Empty lists
            // mirror canUndo/canRedo == false, matching project.snapshot's
            // undoLabel/redoLabel top-of-stack fields.
            try params.rejectUnknownKeys([], verb: "edit.history")
            let history = store.undoHistory()
            return .success(request.id, .object([
                "undo": .array(history.undo.map { JSONValue.string($0) }),
                "redo": .array(history.redo.map { JSONValue.string($0) }),
                "canUndo": .bool(history.canUndo),
                "canRedo": .bool(history.canRedo),
            ]))

        case "edit.pasteClips":
            // Pastes the APP'S clipboard — whatever the user last copied with
            // Cmd-C in the arrange (m26-k). No agent can populate this
            // clipboard over the wire; this route only fires it. params:
            // trackId? (UUID — omit to use the resolved active track, exactly
            // what Cmd-V uses; a value overrides it for THIS paste only,
            // without moving the stored cursor), atBeat? (Double, project
            // beats — omit for the transport playhead, exactly what Cmd-V
            // uses; a value anchors THIS paste there without moving the
            // playhead. Added ADDITIVELY at m25-f-4 for the empty-lane
            // right-click Paste; a negative slides the whole group to beat 0
            // rather than erroring). Rides
            // `AppModel.pasteClipsFromClipboard(intoTrack:)`'s targeting
            // verbatim through the typed `editPaste` seam (the plugin.*
            // precedent) — a headless control session (no app UI) errors
            // readably. Result names WHICH of four outcomes happened rather
            // than a bare ok: {pasted:true, landings:[{clipId,trackId,
            // startBeat}], skipped:[...], trimmedClipIDs, removedClipIDs} on
            // success; {pasted:false, reason:"empty-clipboard"} when there was
            // nothing to paste; {pasted:false, reason:"wrong-payload-kind",
            // clipboardKind} when the clipboard holds NOTES, not clips (paste
            // those with clip.getNotes + clip.setNotes instead — there is no
            // note-paste wire route); {pasted:false, reason:<refusal>,
            // skipped:[...]} when nothing could land (no tracks, no track can
            // hold the payload, or every member individually mismatched its
            // destination — e.g. a MIDI clip pasted onto an audio track).
            try params.rejectUnknownKeys(["trackId", "atBeat"], verb: "edit.pasteClips")
            var pasteIntoTrack: UUID?
            if let raw = params["trackId"]?.stringValue {
                guard let id = UUID(uuidString: raw) else {
                    throw ControlError("'trackId' is not a valid UUID: \(raw)")
                }
                pasteIntoTrack = id
            } else if params["trackId"] != nil {
                throw ControlError("'trackId' must be a string")
            }
            // m25-f-4 — the ANCHOR override. ADDITIVE on a live verb: omit it
            // and this route behaves exactly as it did before (the playhead).
            // NOT clamped or validated here: `PasteAnchorPolicy.resolveClipPaste`
            // owns the `max(0, anchor)` GROUP clamp and is the ONE home for it,
            // so a negative beat slides the group rigidly to 0 rather than
            // erroring — the same answer the empty-lane right-click gets.
            var pasteAtBeat: Double?
            if let raw = params["atBeat"] {
                guard let beat = raw.doubleValue else {
                    throw ControlError("'atBeat' must be a number")
                }
                pasteAtBeat = beat
            }
            guard let editPaste else {
                throw ControlError(
                    "edit paste unavailable — this control session has no app UI (headless). Launch DAWApp/DAWPro.app and retry.")
            }
            let pasteResult = editPaste.pasteClips(intoTrack: pasteIntoTrack,
                                                   atBeat: pasteAtBeat)
            return .success(request.id, editPasteResultJSON(pasteResult))

        case "clip.applyBreathContour":
            // m27 leg D. params: clipId (required), noteIds? (array of note
            // UUIDs — omit to shape EVERY note in the clip), plus the fifteen
            // contour options, every one optional and bounded below. Generates
            // the correlated performance contour a wind/bowed player puts on a
            // held note — an expression (CC) swell that moves LOUDNESS and (when
            // the sampler's expressionFilterDepth is on) BRIGHTNESS together,
            // plus DELAYED vibrato and micro-sharpening on the pitch-bend lane.
            //
            // The two lanes are MERGED, not replaced: points outside every
            // touched note's span survive exactly as authored, so this composes
            // with a hand-drawn shape and accumulates across per-note calls.
            // That is the difference from clip.setControllerLane, which is the
            // raw wholesale-replace primitive and stays unchanged.
            //
            // Notes too short for the straight opening plus one vibrato cycle
            // get the expression contour ONLY and no bend lane at all — the
            // result says how many, and it is the intended shape, not an error.
            // ONE undoable step ("Breath Contour"). MIDI clips ONLY — an audio
            // clip surfaces notAMIDIClip verbatim; clipNotFound via the
            // LocalizedError mapping. Response: the updated clip fields PLUS
            // notesTouched, notesWithVibrato, expressionPointCount,
            // pitchBendPointCount, perNotePointBudget and `warnings` — read the
            // warnings, they are how a half-audible result announces itself.
            try params.rejectUnknownKeys(
                ["clipId", "noteIds", "depth", "peakValue", "peakPosition",
                 "attackSettleSeconds", "expressionCC", "expressionSpacingSeconds",
                 "vibratoOnsetSeconds", "vibratoRateHz", "vibratoDepthCents",
                 "vibratoBloomSeconds", "vibratoReleaseSeconds", "sharpenCents",
                 "bendSpacingSeconds", "bendRangeSemitones"],
                verb: "clip.applyBreathContour")
            let breathClipID = try params.requireClipID()
            let breathNoteIDs = params["noteIds"] == nil
                ? nil
                : try parseClipIDs(params["noteIds"], field: "noteIds",
                                   requirement: " (the notes to shape — omit to shape every note)")
            // Every bound below is the SAME domain `BreathContour.Options
            // .sanitized()` heals to, stated here so the wire REFUSES a bad
            // value with a teaching sentence instead of silently clamping it —
            // an agent that asked for a 40 Hz vibrato and got 20 would have no
            // way to find out (m23's silent-discard defect class).
            var breath = BreathContour.Options()
            breath.depth = try boundedOption(params, "depth", 0, 1, breath.depth,
                                             "how far the swell falls below its peak, as a fraction of peakValue")
            breath.peakValue = try boundedIntOption(params, "peakValue", 0, 127, breath.peakValue,
                                                    "the CC value at the top of the swell; 127 = the lane's neutral, so the peak is as loud as no lane at all")
            breath.peakPosition = try boundedOption(params, "peakPosition", 0.05, 0.95, breath.peakPosition,
                                                    "where the peak sits, as a fraction of the note's length")
            breath.attackSettleSeconds = try boundedOption(params, "attackSettleSeconds", 0, 1, breath.attackSettleSeconds,
                                                           "seconds from the attack to the settling dip; clamped to a quarter of a short note")
            breath.expressionCC = try boundedIntOption(params, "expressionCC", 0, 127, breath.expressionCC,
                                                       "which CC carries the swell; 11 is the one the built-in sampler routes to amplitude with no opt-in")
            breath.expressionSpacingSeconds = try boundedOption(params, "expressionSpacingSeconds", 0.001, 1, breath.expressionSpacingSeconds,
                                                                 "seconds between expression points; controller lanes are STEPWISE, so this is what makes a swell instead of a staircase")
            breath.vibratoOnsetSeconds = try boundedOption(params, "vibratoOnsetSeconds", 0, 10, breath.vibratoOnsetSeconds,
                                                            "seconds of STRAIGHT playing before vibrato starts; a note too short for this plus one cycle gets no vibrato at all")
            breath.vibratoRateHz = try boundedOption(params, "vibratoRateHz", 0.2, 20, breath.vibratoRateHz,
                                                      "vibrato rate in Hz")
            breath.vibratoDepthCents = try boundedOption(params, "vibratoDepthCents", 0, 200, breath.vibratoDepthCents,
                                                          "peak vibrato width in cents (a ± figure); 0 turns vibrato off")
            breath.vibratoBloomSeconds = try boundedOption(params, "vibratoBloomSeconds", 0, 10, breath.vibratoBloomSeconds,
                                                            "seconds for the vibrato to widen from nothing to full depth")
            breath.vibratoReleaseSeconds = try boundedOption(params, "vibratoReleaseSeconds", 0, 10, breath.vibratoReleaseSeconds,
                                                              "seconds before the note's end over which vibrato relaxes back to centre")
            breath.sharpenCents = try boundedOption(params, "sharpenCents", -200, 200, breath.sharpenCents,
                                                     "peak micro-sharpening in cents at the top of the swell, resolving as it falls")
            breath.bendSpacingSeconds = try boundedOption(params, "bendSpacingSeconds", 0.001, 1, breath.bendSpacingSeconds,
                                                           "seconds between pitch-bend points; the bend run IS the vibrato waveform, so this is its sample rate")
            breath.bendRangeSemitones = try boundedOption(params, "bendRangeSemitones", 0.01, 48, breath.bendRangeSemitones,
                                                           "the instrument's pitch-bend range in semitones for a full deflection; the built-in sampler is exactly 2")
            let breathResult = try store.applyBreathContour(
                clipID: breathClipID, noteIDs: breathNoteIDs, options: breath)
            var breathObj = try JSONValue(encoding: breathResult.clip).objectValue ?? [:]
            breathObj["notesTouched"] = .number(Double(breathResult.notesTouched))
            breathObj["notesWithVibrato"] = .number(Double(breathResult.notesWithVibrato))
            breathObj["expressionPointCount"] = .number(Double(breathResult.expressionPointCount))
            breathObj["pitchBendPointCount"] = .number(Double(breathResult.pitchBendPointCount))
            breathObj["perNotePointBudget"] = .number(Double(breathResult.perNotePointBudget))
            if !breathResult.warnings.isEmpty {
                breathObj["warnings"] = .array(breathResult.warnings.map { .string($0) })
            }
            return .success(request.id, .object(breathObj))

        case "clip.applyEffortShape":
            // Breath pad P1. params: clipId (required), pattern (required — one
            // of the eight library ids, case-insensitive), noteIds? (omit to
            // shape EVERY note), amount? (0-1, how strongly the shape is
            // applied), maxGapBeats? (the gap above which a rest counts as a
            // BREATH and splits the phrase), loudnessDepth?/swellDepth? (how
            // far a phrase-scoped shape may pull a note down), plus the leg D
            // contour options that the PATTERN does not own.
            //
            // ⚠️ depth / peakPosition / onsetLevel / releaseLevel are NOT
            // accepted here and that is deliberate, not an oversight: those four
            // ARE the pattern. Accepting them would give one visible outcome two
            // controls, and would collide with the leg D meaning of the name
            // depth. Use clip.applyBreathContour for hand-authored shapes.
            //
            // ⛔ On a track hosting an Audio Unit (every sound-bank track,
            // including the GM sax) bend VIBRATO is suppressed and said so in
            // warnings: it was MEASURED on 2026-08-19 to alias in bounces. The
            // warning names the route that works. Nothing here promises
            // brightness on that path either — CC11 there is exactly a gain.
            //
            // ONE undoable step, named for itself. MIDI clips only. Response:
            // the updated clip fields PLUS patternId, patternName, scope,
            // notesTouched, phraseCount, notesWithVibrato, expressionPointCount,
            // pitchBendPointCount, perNotePointBudget, minEffort, maxEffort and
            // warnings. Read minEffort/maxEffort: equal values mean the shape
            // ran and varied nothing.
            //
            // ⭐ P2 ADDS THE RING — additively. `ringAngle` (DEGREES, 0-360)
            // says where the dot sits on a circle of patterns; `ringRadius`
            // (0-1) how far out; `ring` optionally replaces the eight-pattern
            // default with your own order. `ringAngle` is what SELECTS the ring
            // form — passing `ringRadius` or `ring` without it is refused rather
            // than defaulted, because a dot position nobody stated is a gesture
            // nobody asked for. Response then also carries `ring:{angleDegrees,
            // radius, patternIds, weights, noteWeight, phraseWeight}`, and
            // `patternId` names the NEAREST pattern, not the only one.
            //
            // ⚠️ `ringRadius` and `amount` are not independent: both scale the
            // same thing and only their product survives.
            //
            // ⭐ P3 ADDS THE DOT'S PATH — still additively, still no new verb.
            // `path` is `fixed` (the default, P2's behaviour), `orbit` (a steady
            // revolution round the ring) or `drift` (a seeded wander that flows
            // from one gesture into the next). `ringAngle`/`ringRadius` stop
            // being where the dot IS and become where the hand PUT it: the path
            // is an offset from that origin. The dot is read ONCE PER NOTE, at
            // the note's start, in CLIP-RELATIVE beats — so a looped clip takes
            // the same path on every cycle, and a path that moves faster than
            // the notes arrive earns a warning instead of aliasing quietly.
            // Response then also carries `path:{pathId, seed, angleSweepDegrees,
            // startAngleDegrees, endAngleDegrees, minRadius, maxRadius,
            // patternIds, moved, outrunsNotes}`. Read `moved` and `patternIds`:
            // a wander that never left one gesture ran and did nothing.
            //
            // ⭐ P4 ADDS THE AIR BUDGET — additively, still no new verb. A wind
            // player has a finite lungful; `airEnforced` makes a phrase that
            // runs past it SAG rather than hold. ⛔ It DEFAULTS TO FALSE (a user
            // ruling, 2026-08-19): a model that overrides what the composer
            // wrote is opted into, once, visibly. `airCapacitySeconds`,
            // `airConsumptionExponent`, `airRefillSecondsPerSecond`,
            // `airMinBreathSeconds` and `airReserveFraction` tune it — every one
            // is an exposed ESTIMATE, which is why they are exposed.
            //
            // ⭐ THE RESPONSE ALWAYS CARRIES `air`, enforced or not, because
            // that is the surface that answers "why did this get quiet?".
            // `air.applied` says whether the lane was actually changed;
            // `air.constrainedNoteCount` how many notes lost something; and when
            // anything was constrained, `air.phrases[].constrainedNotes` names
            // each one with `effortRequested` beside `effortAllowed` and the dB
            // between them. A phrase can also get quiet because the composer
            // chose a diminuendo — only the budget produces
            // `effortAllowed < effortRequested`, which is why "air runs out" is
            // deliberately not one of the selectable patterns.
            //
            // ⚠️ §9.1's `referenceEffort` is NOT accepted, and its absence is
            // algebra: `(e/ref)^k / cap` is `e^k / (ref^k · cap)`, so `ref` and
            // `airCapacitySeconds` are one axis and only their combination is
            // observable. Capacity is quoted at the AS-AUTHORED level.
            //
            // ⭐ P5 ADDS PHYSIOLOGICAL HUMANISATION — additively, still no new
            // verb. `driftDepth` is a slow 1/f sag in the baseline (DOWNWARD
            // ONLY: effort 1 means "as authored", so it is a ceiling, and a
            // symmetric drift would be half-rectified against it); `tremorDepth`
            // is a 4–8 Hz micro-tremor inside each note.
            //
            // ⛔⛔ **BOTH DEFAULT TO 0, AND THAT IS THE POINT.** Design §13.5
            // requires the rendered bytes at the default to be identical to the
            // pre-P5 tree, which is what makes each knob individually declinable
            // after the fact. §10.1/§10.2's suggested 0.03/0.05 are quoted in the
            // descriptions as starting values, not shipped as defaults.
            //
            // ⛔ **THE TREMOR IS SUPPRESSED ON HOSTED-AU TRACKS (every
            // `.soundBank`, so the GM sax) AND THE RESPONSE SAYS SO.** MEASURED
            // 2026-08-19: our own offline renderer feeds a hosted AU MIDI in
            // 4096-frame blocks — an 11.719 Hz sampler — so a tremor comes back
            // with a sample-and-hold image at |11.719 − rate| Hz whose relative
            // depth is exactly `rate / (11.719 − rate)`. At 8 Hz that image is
            // 2.14× LOUDER than the tremor (measured, CC 11, stock GM alto sax);
            // even at 4 Hz, the BOTTOM of the physiological band, it is 52 %.
            // The whole band is compromised there, so the tremor is suppressed
            // rather than retuned into a band it is not named for. It lands
            // normally on a built-in Sampler track, and the drift — three orders
            // of magnitude slower — lands everywhere.
            try params.rejectUnknownKeys(
                ["clipId", "pattern", "ring", "ringAngle", "ringRadius",
                 "path", "pathSeed", "revolutionBeats", "pathDirection",
                 "scaleBeats", "octaves", "momentum", "angleSwing", "radiusSwing",
                 "noteIds", "amount", "maxGapBeats",
                 "airEnforced", "airCapacitySeconds", "airConsumptionExponent",
                 "airRefillSecondsPerSecond", "airMinBreathSeconds", "airReserveFraction",
                 "driftDepth", "driftScaleBeats", "driftOctaves",
                 "tremorDepth", "tremorRateHz", "tremorEffortExponent",
                 "loudnessDepth", "swellDepth", "peakValue", "expressionCC",
                 "attackSettleSeconds", "expressionSpacingSeconds",
                 "vibratoOnsetSeconds", "vibratoRateHz", "vibratoDepthCents",
                 "vibratoBloomSeconds", "vibratoReleaseSeconds", "sharpenCents",
                 "bendSpacingSeconds", "bendRangeSemitones"],
                verb: "clip.applyEffortShape")
            let effortClipID = try params.requireClipID()

            // --- Which FORM: one named pattern, or a dot on the ring? --------
            //
            // Every combination that is not exactly one of the two is refused
            // with a sentence naming the fix. Quietly preferring one over the
            // other would return success and write a gesture the caller did not
            // choose — the silent-default failure this round exists to end.
            let effortRingAngleValue = params["ringAngle"]
            let effortRingRadiusValue = params["ringRadius"]
            let effortRingListValue = params["ring"]
            let effortPatternValue = params["pattern"]
            if effortPatternValue != nil,
               effortRingAngleValue != nil || effortRingRadiusValue != nil
                || effortRingListValue != nil {
                throw ControlError(
                    "pass EITHER 'pattern' (one named gesture) OR the ring controls "
                    + "('ringAngle', with optional 'ringRadius'/'ring') — not both. They are two "
                    + "ways to choose the same thing, and honouring one would silently ignore the "
                    + "other. To sit exactly ON a pattern, use ringAngle: each of the 8 default "
                    + "patterns is 45° apart starting at 0 for '"
                    + (EffortPattern.libraryIDs.first ?? "flat") + "'")
            }
            if effortRingAngleValue == nil,
               effortRingRadiusValue != nil || effortRingListValue != nil {
                throw ControlError(
                    "'ringRadius'/'ring' only mean something together with 'ringAngle' — say "
                    + "WHERE the dot is. Add ringAngle (degrees, 0-360), or use 'pattern' to name "
                    + "one gesture instead")
            }
            if effortPatternValue == nil, effortRingAngleValue == nil {
                throw ControlError(
                    "say which gesture: either 'pattern' (one of "
                    + EffortPattern.libraryIDs.joined(separator: ", ")
                    + ") or 'ringAngle' (degrees, 0-360 — a dot on the ring, blending the two "
                    + "patterns it sits between)")
            }

            // --- P3: the dot's PATH ------------------------------------------
            //
            // Every parameter here belongs to exactly one path, and passing one
            // that belongs to another is REFUSED rather than ignored. That is
            // the whole point of the round: `revolutionBeats` accepted and
            // silently dropped on a drift would be a call that succeeded, wrote
            // a lane, and did something else.
            let effortPathKeys = ["path", "pathSeed", "revolutionBeats", "pathDirection",
                                  "scaleBeats", "octaves", "momentum", "angleSwing",
                                  "radiusSwing"]
            let effortPathAsked = effortPathKeys.filter { params[$0] != nil }
            if !effortPathAsked.isEmpty, effortRingAngleValue == nil {
                throw ControlError(
                    "\(effortPathAsked.sorted().joined(separator: ", ")) describe how the DOT "
                    + "MOVES, so they need a dot: add 'ringAngle' (degrees, 0-360 — where the "
                    + "hand puts it, and the path is an offset from there). The 'pattern' form "
                    + "names one fixed gesture and has no dot to move")
            }
            var effortPath = DotPath.fixed
            var effortSeed: UInt64 = 0
            if let pathValue = params["path"] {
                guard let name = pathValue.stringValue else {
                    throw ControlError("'path' must be a string — one of: fixed, orbit, drift")
                }
                // Which keys this path can carry. Refusing the others by name is
                // what makes a typo'd or mis-shaped call teach instead of lie.
                let orbitKeys = ["revolutionBeats", "pathDirection"]
                let driftKeys = ["pathSeed", "scaleBeats", "octaves", "momentum",
                                 "angleSwing", "radiusSwing"]
                func refuseKeys(_ keys: [String], _ why: String) throws {
                    let offenders = keys.filter { params[$0] != nil }
                    guard offenders.isEmpty else {
                        throw ControlError(
                            "\(offenders.sorted().joined(separator: ", ")) \(why) — remove "
                            + "\(offenders.count == 1 ? "it" : "them"), or change 'path'")
                    }
                }
                switch name.lowercased() {
                case "fixed":
                    try refuseKeys(orbitKeys + driftKeys,
                                   "only mean something on a MOVING path, and path is 'fixed'")
                    effortPath = .fixed
                case "orbit":
                    try refuseKeys(driftKeys, "belong to path 'drift', not 'orbit'")
                    let revolutionBeats = try boundedOption(
                        params, "revolutionBeats", 0.25, 4096, 16,
                        "how many BEATS one full trip round the ring takes; the dot is read once per note, so a revolution shorter than a few notes is heard as an alias rather than as motion")
                    var direction = DotPath.Direction.clockwise
                    if let value = params["pathDirection"] {
                        guard let raw = value.stringValue,
                              let parsed = DotPath.Direction(rawValue: raw) else {
                            throw ControlError(
                                "'pathDirection' must be 'clockwise' (toward the next pattern in "
                                + "ring order) or 'counterclockwise'")
                        }
                        direction = parsed
                    }
                    effortPath = .orbit(revolutionBeats: revolutionBeats, direction: direction)
                case "drift":
                    try refuseKeys(orbitKeys, "belong to path 'orbit', not 'drift'")
                    let scaleBeats = try boundedOption(
                        params, "scaleBeats", 0.25, 1024, DotPath.defaultScaleBeats,
                        "how many BEATS one unit of the wander spans; bigger is slower and lazier")
                    let octaves = try boundedIntOption(
                        params, "octaves", 1, EffortField.maxOctaves, EffortField.defaultOctaves,
                        "how many layers of detail the wander has; 1 is a single slow sway, 4 adds three progressively faster and quieter layers on top")
                    let momentum = try boundedOption(
                        params, "momentum", 0, 1, DotPath.defaultMomentum,
                        "how LAZY the wander is: 1 is one long unhurried sway, 0 is twitchy, 0.5 is the 1/f middle. It is the spectral tilt, not a stored velocity — there is no state anywhere in this")
                    let angleSwing = try boundedOption(
                        params, "angleSwing", 0, 360, 45,
                        "the furthest the dot ever wanders from ringAngle, in DEGREES either side. This is an exact bound, not a typical value. One pattern spacing is 45 degrees on the default 8-pattern ring, so 45 reaches each neighbour and no further")
                    let radiusSwing = try boundedOption(
                        params, "radiusSwing", 0, 1, DotPath.defaultRadiusSwing,
                        "how far the dot also wanders IN AND OUT, 0-1. Default 0: the wander changes WHICH gesture, not how strongly it is applied, so one control has one visible outcome")
                    // ⚠️ BOUNDED TO 32 BITS, and not for tidiness. A JSON number
                    // is an IEEE double, so a seed above 2^53 does not survive
                    // the trip through JavaScript and back — it would arrive as
                    // a DIFFERENT seed, and "same seed, same performance" would
                    // quietly stop being true for large values only.
                    let seed = try boundedIntOption(
                        params, "pathSeed", 0, 4_294_967_295, 0,
                        "which wander you get, 0-4294967295. The same seed always gives the same performance, at the same clip beats, in playback and in a bounce alike; change it for a different one. Capped at 32 bits because a JSON number is a double and a larger seed would not survive the round trip intact")
                    effortSeed = UInt64(max(0, seed))
                    effortPath = .drift(scaleBeats: scaleBeats, octaves: octaves,
                                        momentum: momentum,
                                        angleSwingRadians: EffortRing.radians(
                                            fromDegrees: angleSwing),
                                        radiusSwing: radiusSwing)
                default:
                    throw ControlError(
                        "unknown path '\(name)' — valid paths are: fixed (the dot stays where you "
                        + "put it), orbit (a steady revolution round the ring), drift (a seeded "
                        + "wander that flows from one gesture into the next)")
                }
            } else if !effortPathAsked.isEmpty {
                throw ControlError(
                    "\(effortPathAsked.sorted().joined(separator: ", ")) only mean something "
                    + "together with 'path' — say HOW the dot moves: 'orbit' (a steady revolution) "
                    + "or 'drift' (a seeded wander)")
            }

            var effortPattern: EffortPattern?
            var effortRing: EffortRing?
            var effortRingAngle = 0.0
            var effortRingRadius = 1.0
            if effortRingAngleValue != nil {
                // ⚠️ BOUNDED here although DAWCore WRAPS. `EffortRing.wrap`
                // takes any real angle because P3's orbit integrates one without
                // limit — but on the wire, 4500 is far likelier to be a typo
                // than a request for twelve and a half turns, so it earns a
                // sentence rather than a silent modulo.
                let degrees = try boundedOption(
                    params, "ringAngle", 0, 360, 0,
                    "where the dot sits, in DEGREES clockwise from the first pattern; the 8 default patterns are 45° apart, so 0=flat, 45=messaDiVoce, 90=lateBloom, 135=hairpinCrescendo, 180=hairpinDiminuendo, 225=terraced, 270=sforzandoPiano, 315=subToneEntry")
                effortRingAngle = EffortRing.radians(fromDegrees: degrees)
                effortRingRadius = try boundedOption(
                    params, "ringRadius", 0, 1, 1,
                    "how far out the dot sits, 0-1; 0 is a true no-op (the shape is not applied at all) and 1 is the full gesture. NOT independent of amount — only the product of the two survives")
                if effortRingListValue != nil {
                    let ids = try parseStringList(effortRingListValue, field: "ring",
                                                  requirement: " (pattern ids in ring order)")
                    do {
                        effortRing = try EffortRing.resolve(ids: ids)
                    } catch let error as EffortRing.ResolveError {
                        throw ControlError(error.message)
                    }
                } else {
                    effortRing = EffortRing.standard
                }
            } else {
                guard let effortPatternName = effortPatternValue?.stringValue else {
                    throw ControlError(
                        "'pattern' must be a string — one of: "
                        + EffortPattern.libraryIDs.joined(separator: ", "))
                }
                // An unknown id is REFUSED naming every valid one — never a
                // silent fallback to a default shape, which would return success
                // for a typo and write a gesture nobody asked for.
                guard let named = EffortPattern.named(effortPatternName) else {
                    throw ControlError(
                        "unknown pattern '\(effortPatternName)' — valid patterns are: "
                        + EffortPattern.libraryIDs.joined(separator: ", "))
                }
                effortPattern = named
            }
            let effortNoteIDs = params["noteIds"] == nil
                ? nil
                : try parseClipIDs(params["noteIds"], field: "noteIds",
                                   requirement: " (the notes to shape — omit to shape every note)")
            let effortAmount = try boundedOption(params, "amount", 0, 1, 1,
                                                 "how strongly the pattern is applied; 0 writes a flat lane")
            let effortMaxGap = try boundedOption(
                params, "maxGapBeats", 0, 16, HumanizeLegato.defaultMaxGapBeats,
                "a gap larger than this counts as a BREATH and splits the phrase; same meaning as in clip.humanize")
            // Presence, not value: an EXPLICIT response is what earns the
            // "these two did nothing" warning on a note-scoped pattern, and
            // `boundedOption` cannot tell an absent key from one that happens
            // to carry the default.
            let effortResponseAsked = params["loudnessDepth"] != nil || params["swellDepth"] != nil
            var effortResponse = EffortPattern.defaultEffortResponse
            effortResponse.loudnessDepth = try boundedOption(
                params, "loudnessDepth", 0, 1, effortResponse.loudnessDepth,
                "how far a phrase-scoped shape may pull a note's peak down; CC11 is a square law, so 0.55 is about 9 dB")
            effortResponse.swellDepth = try boundedOption(
                params, "swellDepth", 0, 1, effortResponse.swellDepth,
                "how much a quiet note's own swell shrinks with it; 0 keeps every note's internal shape identical")
            // The leg D passthrough — the same bounds, stated so the wire
            // REFUSES a bad value with a sentence instead of clamping it.
            var effortOptions = BreathContour.Options()
            effortOptions.peakValue = try boundedIntOption(params, "peakValue", 0, 127, effortOptions.peakValue,
                                                           "the CC value at FULL effort; 127 = the lane's neutral, so the loudest instant is as loud as no lane at all")
            effortOptions.expressionCC = try boundedIntOption(params, "expressionCC", 0, 127, effortOptions.expressionCC,
                                                              "which CC carries the shape; 11 is the one the built-in sampler routes to amplitude with no opt-in")
            effortOptions.attackSettleSeconds = try boundedOption(params, "attackSettleSeconds", 0, 1, effortOptions.attackSettleSeconds,
                                                                  "seconds from the attack to the settling dip; a pattern with its own early dip (sforzandoPiano) overrides this per note")
            effortOptions.expressionSpacingSeconds = try boundedOption(params, "expressionSpacingSeconds", 0.001, 1, effortOptions.expressionSpacingSeconds,
                                                                        "seconds between expression points; controller lanes are STEPWISE, so this is what makes a curve instead of a staircase")
            effortOptions.vibratoOnsetSeconds = try boundedOption(params, "vibratoOnsetSeconds", 0, 10, effortOptions.vibratoOnsetSeconds,
                                                                   "seconds of STRAIGHT playing before vibrato starts")
            effortOptions.vibratoRateHz = try boundedOption(params, "vibratoRateHz", 0.2, 20, effortOptions.vibratoRateHz,
                                                             "vibrato rate in Hz")
            effortOptions.vibratoDepthCents = try boundedOption(params, "vibratoDepthCents", 0, 200, effortOptions.vibratoDepthCents,
                                                                 "peak vibrato width in cents (a ± figure); 0 turns vibrato off")
            effortOptions.vibratoBloomSeconds = try boundedOption(params, "vibratoBloomSeconds", 0, 10, effortOptions.vibratoBloomSeconds,
                                                                   "seconds for the vibrato to widen from nothing to full depth")
            effortOptions.vibratoReleaseSeconds = try boundedOption(params, "vibratoReleaseSeconds", 0, 10, effortOptions.vibratoReleaseSeconds,
                                                                     "seconds before the note's end over which vibrato relaxes back to centre")
            effortOptions.sharpenCents = try boundedOption(params, "sharpenCents", -200, 200, effortOptions.sharpenCents,
                                                            "peak micro-sharpening in cents at full effort, resolving as the shape falls")
            effortOptions.bendSpacingSeconds = try boundedOption(params, "bendSpacingSeconds", 0.001, 1, effortOptions.bendSpacingSeconds,
                                                                  "seconds between pitch-bend points; the bend run IS the vibrato waveform, so this is its sample rate")
            effortOptions.bendRangeSemitones = try boundedOption(params, "bendRangeSemitones", 0.01, 48, effortOptions.bendRangeSemitones,
                                                                  "the instrument's pitch-bend range in semitones for a full deflection; the built-in sampler is exactly 2 and a hosted AUSampler measured 2.0155")
            // --- P4: the air budget ------------------------------------------
            //
            // PRESENCE, not value, is what earns the "it would have" advisory —
            // the same idiom `loudnessDepth`/`swellDepth` use two blocks up, and
            // for the same reason: `boundedOption` returns the default for an
            // absent key and cannot tell the two apart. A caller who never
            // mentioned air still gets the full report in the response; they
            // just are not nagged about a model they did not ask for.
            let effortAirKeys = ["airEnforced", "airCapacitySeconds", "airConsumptionExponent",
                                 "airRefillSecondsPerSecond", "airMinBreathSeconds",
                                 "airReserveFraction"]
            let effortAirAsked = effortAirKeys.contains { params[$0] != nil }
            var effortAir = AirBudget.Settings()
            if let enforcedValue = params["airEnforced"] {
                guard let flag = enforcedValue.boolValue else {
                    throw ControlError(
                        "'airEnforced' must be true or false. It decides whether a phrase that "
                        + "runs past the player's lungful is actually pulled down, or merely "
                        + "REPORTED. It defaults to false on purpose: an air budget overrides what "
                        + "you wrote, so it is opted into rather than assumed")
                }
                effortAir.enforced = flag
            }
            effortAir.capacitySeconds = try boundedOption(
                params, "airCapacitySeconds", 0.25, 3600, effortAir.capacitySeconds,
                "how many SECONDS the player can sustain the part AS AUTHORED before the lungful is gone; every figure in this model is an estimate, which is why it is a parameter")
            effortAir.consumptionExponent = try boundedOption(
                params, "airConsumptionExponent", 0, 8, effortAir.consumptionExponent,
                "how much faster loud playing burns air: rate = effort^this. 1.5 makes a phrase at half the authored level last about 2.8x longer; 0 makes level irrelevant")
            effortAir.refillSecondsPerSecond = try boundedOption(
                params, "airRefillSecondsPerSecond", 0, 100, effortAir.refillSecondsPerSecond,
                "how much of a lungful one second of rest gives back; 0.5 means a 2-second rest refills completely. If the part's rests are shorter than this can keep up with, the sag accumulates and the response says so")
            effortAir.minBreathSeconds = try boundedOption(
                params, "airMinBreathSeconds", 0, 60, effortAir.minBreathSeconds,
                "a rest shorter than this many SECONDS is an articulation, not a breath, and refills nothing. Note this is in seconds while maxGapBeats is in beats, so at a fast tempo a gap can split the phrase and still be too quick to breathe in — the response reports that as breath.kind 'tooShort'")
            effortAir.reserveFraction = try boundedOption(
                params, "airReserveFraction", 0, 1, effortAir.reserveFraction,
                "below this fraction of a lungful the player starts running out and effort is scaled down toward it, so the phrase SAGS instead of stopping. A note is never taken to silence")

            // --- P5: humanisation -------------------------------------------
            var effortHumanisation = EffortField.Humanisation.none
            effortHumanisation.driftDepth = try boundedOption(
                params, "driftDepth", 0, 1, effortHumanisation.driftDepth,
                "how far a slow 1/f drift may pull the effort baseline BELOW what you wrote, as a fraction. 0 (the default) is off and renders byte-identically to not mentioning it; 0.05 is the design's suggested starting value. Downward only: effort 1 means 'as authored', so there is nothing above it to drift into")
            effortHumanisation.driftScaleBeats = try boundedOption(
                params, "driftScaleBeats", 0.01, 4096, effortHumanisation.driftScaleBeats,
                "the drift's period in BEATS (default 8 = two bars of 4/4). Far slower than any note rate on purpose — the effort is sampled once per note, so a fast drift would be aliased by the note grid")
            effortHumanisation.driftOctaves = Int(try boundedOption(
                params, "driftOctaves", 1, 8, Double(effortHumanisation.driftOctaves),
                "how many fBm octaves the drift is built from (default 4, persistence fixed at 0.5, which is the 1/f spectrum). Note: '1/f breath pressure' is a modelling choice this design made, not a measured finding"))
            effortHumanisation.tremorDepth = try boundedOption(
                params, "tremorDepth", 0, 1, effortHumanisation.tremorDepth,
                "peak-to-trough depth of the involuntary micro-tremor INSIDE each note, as a fraction of the contour level it rides on. 0 (the default) is off and renders byte-identically; 0.03 is the design's suggested value and measures about 0.29 dB. MEASURED: 0.0755 dB per CC of peak-to-trough travel on the built-in sampler. SUPPRESSED on hosted-AU tracks (every soundBank) — see the response warnings")
            effortHumanisation.tremorRateHz = try boundedOption(
                params, "tremorRateHz",
                EffortField.Humanisation.minTremorRateHz,
                EffortField.Humanisation.maxTremorRateHz,
                effortHumanisation.tremorRateHz,
                "tremor rate in Hz, 0.2-20 (default 4.565 = the vibrato rate x 0.83, so the two are not one oscillator summing into a single deeper vibrato). At the BOTTOM of the 4-8 Hz physiological band: on a hosted AU an offline bounce re-samples this lane at 93.75 Hz and the alias image is rate/(93.75-rate) as deep as the tremor, so every rate up to 18.75 Hz is written and anything above it is suppressed rather than retuned. The band is the vibrato band, and REJECTING outside it is deliberate: below 0.2 Hz a tremor is a drift (which is driftDepth's job) and clamping instead would silently hand back a different gesture under the name you asked for")
            effortHumanisation.tremorEffortExponent = try boundedOption(
                params, "tremorEffortExponent", 0, 8, effortHumanisation.tremorEffortExponent,
                "how the tremor deepens with effort: depth is scaled by effort^this (default 1, linear). 0 makes the tremor the same depth however hard the player is blowing")

            let effortResult: EffortShapeApplication
            if let effortRing {
                effortResult = try store.applyEffortShape(
                    clipID: effortClipID, noteIDs: effortNoteIDs, ring: effortRing,
                    angleRadians: effortRingAngle, radius: effortRingRadius,
                    path: effortPath, seed: effortSeed,
                    amount: effortAmount, maxGapBeats: effortMaxGap,
                    response: effortResponseAsked ? effortResponse : nil,
                    air: effortAirAsked ? effortAir : nil,
                    humanisation: effortHumanisation, options: effortOptions)
            } else if let effortPattern {
                effortResult = try store.applyEffortShape(
                    clipID: effortClipID, noteIDs: effortNoteIDs, pattern: effortPattern,
                    amount: effortAmount, maxGapBeats: effortMaxGap,
                    response: effortResponseAsked ? effortResponse : nil,
                    air: effortAirAsked ? effortAir : nil,
                    humanisation: effortHumanisation, options: effortOptions)
            } else {
                // Unreachable: the fork above throws on every other combination.
                // Stated rather than force-unwrapped.
                throw ControlError("say which gesture: 'pattern' or 'ringAngle'")
            }
            var effortObj = try JSONValue(encoding: effortResult.clip).objectValue ?? [:]
            effortObj["patternId"] = .string(effortResult.patternID)
            effortObj["patternName"] = .string(effortResult.patternName)
            effortObj["scope"] = .string(effortResult.scope.rawValue)
            effortObj["notesTouched"] = .number(Double(effortResult.notesTouched))
            effortObj["phraseCount"] = .number(Double(effortResult.phraseCount))
            effortObj["notesWithVibrato"] = .number(Double(effortResult.notesWithVibrato))
            effortObj["expressionPointCount"] = .number(Double(effortResult.expressionPointCount))
            effortObj["pitchBendPointCount"] = .number(Double(effortResult.pitchBendPointCount))
            effortObj["perNotePointBudget"] = .number(Double(effortResult.perNotePointBudget))
            effortObj["minEffort"] = .number(effortResult.minEffort)
            effortObj["maxEffort"] = .number(effortResult.maxEffort)
            // Present ONLY for the ring form. A caller who named one pattern
            // never mentioned a ring and should not be answered about one; a
            // caller who moved the dot cannot otherwise tell what it resolved
            // to, since `patternId` alone names only the nearest gesture.
            if let ringReport = effortResult.ring {
                effortObj["ring"] = .object([
                    "angleDegrees": .number(ringReport.angleDegrees),
                    "radius": .number(ringReport.radius),
                    "patternIds": .array(ringReport.patternIDs.map { .string($0) }),
                    "weights": .array(ringReport.weights.map { .number($0) }),
                    "noteWeight": .number(ringReport.noteWeight),
                    "phraseWeight": .number(ringReport.phraseWeight),
                ])
            }
            // Present ONLY when the dot actually had a path (P3). A caller who
            // never moved it should not be answered about travel, and `moved`
            // plus `patternIds` are the two fields that say whether a wander did
            // anything musical or merely ran.
            if let pathReport = effortResult.path {
                effortObj["path"] = .object([
                    "pathId": .string(pathReport.pathID),
                    "seed": .number(Double(pathReport.seed)),
                    "angleSweepDegrees": .number(pathReport.angleSweepDegrees),
                    "startAngleDegrees": .number(pathReport.startAngleDegrees),
                    "endAngleDegrees": .number(pathReport.endAngleDegrees),
                    "minRadius": .number(pathReport.minRadius),
                    "maxRadius": .number(pathReport.maxRadius),
                    "patternIds": .array(pathReport.patternIDs.map { .string($0) }),
                    "moved": .bool(pathReport.moved),
                    "outrunsNotes": .bool(pathReport.outrunsNotes),
                ])
            }
            // ⭐⭐⭐ P4, THE LEGIBILITY SURFACE, LAYER 1. **Always present**, on
            // every call, enforced or not — this is the block that answers "why
            // did this get quiet?". `applied` is the first thing to read: false
            // means the lane was NOT touched and everything here is the
            // prediction of what enforcement would do. The per-phrase detail
            // ships only when something was actually constrained, so an ordinary
            // call is not buried in an empty structure.
            let airReport = effortResult.air
            var airObj: [String: JSONValue] = [
                "applied": .bool(airReport.applied),
                "enforced": .bool(airReport.settings.enforced),
                "notesConsidered": .number(Double(airReport.notesConsidered)),
                "notesShaped": .number(Double(airReport.notesShaped)),
                "constrainedNoteCount": .number(Double(airReport.constrainedNoteCount)),
                "constrainedShapedCount": .number(Double(airReport.constrainedShapedCount)),
                "exhaustedPhraseCount": .number(Double(airReport.exhaustedPhraseCount)),
                "phraseCount": .number(Double(airReport.phrases.count)),
                "lowestAir": .number(airReport.lowestAir),
                "maxAttenuationDb": .number(airReport.maxAttenuationDb),
                "neverRecovered": .bool(airReport.neverRecovered),
                "settings": .object([
                    "capacitySeconds": .number(airReport.settings.capacitySeconds),
                    "consumptionExponent": .number(airReport.settings.consumptionExponent),
                    "refillSecondsPerSecond": .number(airReport.settings.refillSecondsPerSecond),
                    "minBreathSeconds": .number(airReport.settings.minBreathSeconds),
                    "reserveFraction": .number(airReport.settings.reserveFraction),
                ]),
            ]
            if airReport.constrainedAnything {
                airObj["phrases"] = .array(airReport.phrases.map { phrase in
                    var breath: [String: JSONValue] = ["kind": .string(phrase.breath.id)]
                    if let beat = phrase.breath.beat { breath["beat"] = .number(beat) }
                    if let seconds = phrase.breath.seconds {
                        breath["seconds"] = .number(seconds)
                    }
                    var obj: [String: JSONValue] = [
                        "startBeat": .number(phrase.startBeat),
                        "endBeat": .number(phrase.endBeat),
                        "breath": .object(breath),
                        "airAtStart": .number(phrase.airAtStart),
                        "airAtEnd": .number(phrase.airAtEnd),
                        "lowestAir": .number(phrase.lowestAir),
                        "exhausted": .bool(phrase.exhausted),
                        "soundingSeconds": .number(phrase.soundingSeconds),
                        "constrainedNotes": .array(phrase.constrainedNotes.map { note in
                            .object([
                                "noteId": .string(note.noteID.uuidString),
                                "beat": .number(note.beat),
                                "effortRequested": .number(note.effortRequested),
                                "effortAllowed": .number(note.effortAllowed),
                                "airAtNote": .number(note.airAtNote),
                                "peakCCRequested": .number(Double(note.peakCCRequested)),
                                "peakCCAllowed": .number(Double(note.peakCCAllowed)),
                                "attenuationDb": .number(note.attenuationDb),
                                "shaped": .bool(note.shaped),
                            ])
                        }),
                    ]
                    if let after = phrase.exhaustedAfterSeconds {
                        obj["exhaustedAfterSeconds"] = .number(after)
                    }
                    return .object(obj)
                })
            }
            effortObj["air"] = .object(airObj)
            if !effortResult.warnings.isEmpty {
                effortObj["warnings"] = .array(effortResult.warnings.map { .string($0) })
            }
            return .success(request.id, .object(effortObj))

        case "plugin.openUI":
            // Opens (or focuses) the floating window of the LIVE hosted Audio
            // Unit for a track's instrument or one insert effect (M3 vi-b) —
            // edits in the window affect the sounding audio immediately. params:
            // trackId (required), effectId? (UUID — omit for the instrument
            // window), x?/y? (top-left-origin screen points; omit for a
            // deterministic cascade). Plugin windows apply ONLY to Audio Unit
            // instruments/effects — built-in kinds have first-class in-app
            // panels and are rejected readably. A headless control session (no
            // app UI) errors with an actionable message. Response mirrors one
            // listOpenUIs entry: {trackId, effectId?, title, component:{name,
            // manufacturerName, isV3}, body ("generic"|"custom"), alreadyOpen,
            // frame:{x,y,width,height}, warning?}.
            try params.rejectUnknownKeys(
                ["trackId", "effectId", "x", "y"], verb: "plugin.openUI")
            let target = try requirePluginTarget(params)
            guard let pluginUI else {
                throw ControlError(
                    "plugin UI unavailable — this control session has no app UI (headless). Launch DAWApp/DAWPro.app and retry.")
            }
            let opened = try await pluginUI.openUI(target, x: params["x"]?.doubleValue,
                                                   y: params["y"]?.doubleValue)
            return .success(request.id,
                            pluginUIWindowJSON(opened.info, alreadyOpen: opened.alreadyOpen))

        case "plugin.closeUI":
            // Closes the plugin window for a target (M3 vi-b). Validates UUID
            // SYNTAX only — no store lookup, because the target may have just
            // been removed and idempotent close is the agent-friendly contract.
            // params: trackId (required), effectId? (UUID — omit for the
            // instrument window). Headless (no app UI) errors like plugin.openUI.
            // Response: {closed: true|false} (false = honest no-op, the window
            // was not open).
            try params.rejectUnknownKeys(
                ["trackId", "effectId"], verb: "plugin.closeUI")
            let closeTarget = try pluginCloseTarget(params)
            guard let pluginUI else {
                throw ControlError(
                    "plugin UI unavailable — this control session has no app UI (headless). Launch DAWApp/DAWPro.app and retry.")
            }
            return .success(request.id, .object(["closed": .bool(pluginUI.closeUI(closeTarget))]))

        case "plugin.listOpenUIs":
            // Lists every open plugin window (M3 vi-b). No params, never errors.
            // Response: {available: bool, windows: [...openUI result objects...]}.
            // `available:false, windows:[]` is the honest answer for a headless
            // control session (the app has no UI to open windows in).
            try params.rejectUnknownKeys([], verb: "plugin.listOpenUIs")
            guard let pluginUI else {
                return .success(request.id, .object([
                    "available": .bool(false),
                    "windows": .array([]),
                ]))
            }
            return .success(request.id, .object([
                "available": .bool(true),
                "windows": .array(pluginUI.listOpenUIs().map { pluginUIWindowJSON($0) }),
            ]))

        case "au.describeParams":
            // Reads the live AUParameterTree of the hosted Audio Unit behind
            // a track slot (design-au-parameter-surface): effectId names an
            // .audioUnit insert on that track; OMIT it for the track's
            // .audioUnit instrument (the plugin.openUI target model).
            // Addresses are per-instance UInt64s carried as DECIMAL STRINGS
            // (JSON doubles lose exactness past 2^53) — opaque, never guessed
            // or reused across instances. Paging: offset (int ≥ 0, default 0)
            // + maxParams (int, default 512, silently clamped into 1…4096),
            // with totalCount + an honest truncated flag. `addresses` (array
            // of decimal-string addresses) is an exact-get filter instead —
            // mutually exclusive with offset/maxParams; misses land in
            // unknownAddresses, never an error. An AU that publishes NO tree
            // answers hasParameterTree:false, totalCount:0 — SUCCESS, never
            // an error (opaque-state units are healthy hosts; edit them via
            // plugin.openUI). The master chain hosts built-in effects only
            // (design-m13d D4a), so trackId:"master" rejects readably; a
            // not-.ready instance names its status (pending/missing/failed
            // reason). Response: {trackId, effectId?, componentName,
            // hasParameterTree, totalCount, offset, truncated, parameters:
            // [{address, identifier, displayName, keyPath, unit, unitName,
            // minValue, maxValue, value, writable, readable, valueStrings}],
            // unknownAddresses}.
            try params.rejectUnknownKeys(
                ["trackId", "effectId", "offset", "maxParams", "addresses"],
                verb: "au.describeParams")
            let target = try Self.requireHostedAUTarget(params)
            let addressFilter = try Self.parseAUAddressFilter(params)
            if addressFilter != nil, params["offset"] != nil || params["maxParams"] != nil {
                throw ControlError(
                    "'addresses' is an exact-get filter — pass it OR offset/maxParams paging, not both")
            }
            let described = try store.describeAudioUnitParams(
                trackID: target.trackID, effectID: target.effectID,
                offset: try Self.parseAUOffset(params),
                maxParams: try Self.parseAUMaxParams(params),
                addresses: addressFilter)
            var describeResult: [String: JSONValue] = [
                "trackId": .string(target.trackID.uuidString),
                "componentName": .string(described.componentName),
                "hasParameterTree": .bool(described.page.hasParameterTree),
                "totalCount": .number(Double(described.page.totalCount)),
                "offset": .number(Double(described.page.offset)),
                "truncated": .bool(described.page.truncated),
                "parameters": .array(described.page.parameters.map(Self.auParameterJSON)),
                "unknownAddresses": .array(
                    described.page.unknownAddresses.map { .string($0) }),
            ]
            if let effectID = target.effectID {
                describeResult["effectId"] = .string(effectID.uuidString)
            }
            return .success(request.id, .object(describeResult))

        case "au.setParam":
            // Sets ONE parameter of the hosted AU by its decimal-string
            // address (au.describeParams lists them). params: trackId
            // (required; "master" rejects — the master chain cannot host
            // AUs), effectId? (omit ⇒ the track's AU instrument), address
            // (required — the decimal STRING is canonical; an exactly-
            // integral JSON number ≤ 2^53 is tolerated), value (required
            // finite number — NaN/Inf reject readably). Out-of-range values
            // clamp SILENTLY to [minValue, maxValue] (the fx.setParam
            // precedent); the response's parameter.value is the AU's
            // post-set READ-BACK, so quantizing/stepping units answer
            // honestly. Deliberately NO undo step (parity with edits made in
            // the vendor window via plugin.openUI); the value persists via
            // save-time fullStateForDocument capture. Response: {trackId,
            // effectId?, parameter: {…refreshed info…}}.
            try params.rejectUnknownKeys(
                ["trackId", "effectId", "address", "value"], verb: "au.setParam")
            let setTarget = try Self.requireHostedAUTarget(params)
            let address = try Self.requireAUAddress(params)
            let value = try params.require("value", \.doubleValue)
            guard value.isFinite else {
                throw ControlError("'value' must be a finite number")
            }
            let parameter = try store.setAudioUnitParam(
                trackID: setTarget.trackID, effectID: setTarget.effectID,
                address: address, value: value)
            var setResult: [String: JSONValue] = [
                "trackId": .string(setTarget.trackID.uuidString),
                "parameter": Self.auParameterJSON(parameter),
            ]
            if let effectID = setTarget.effectID {
                setResult["effectId"] = .string(effectID.uuidString)
            }
            return .success(request.id, .object(setResult))

        case "vc.sidecarStatus":
            // No params. Health-probes the local RVC voice-conversion sidecar
            // (GET /health on 127.0.0.1:8002, loopback only — see
            // scripts/rvc/README.md) and reports which of notInstalled/
            // installedNotRunning/starting/healthy/error applies — never a
            // bare connection-failure error, so a client can tell "run
            // scripts/rvc/install.sh" apart from "call vc.sidecarStart"
            // without guessing. `message` is always a human-actionable
            // string; `version`/`engine`/`baseModelPresent`/`voiceCount` are
            // populated only when healthy (`voiceCount` is 0 until training
            // ships — a later roadmap item — and never counts the reserved
            // "base" smoke-target model). `phase` is deliberately always nil
            // for this sidecar (see `VoiceConversionStatus.phase`'s doc — no
            // phase classifier exists yet, unlike ai.sidecarStatus's ACE-Step
            // one); `startingForSeconds` behaves identically to
            // ai.sidecarStatus's M10-b tracking. Response: the model's own
            // VoiceConversionStatus Codable (AIServices) — {state, message,
            // version?, engine?, baseModelPresent?, voiceCount?, pid?,
            // phase?, startingForSeconds?, mitigationActive?,
            // mitigationDetail?}.
            //
            // m23-fo-2 — `mitigationActive` is TRI-STATE and only populated
            // when healthy: `true` the facade runs `mx.clear_cache()` before
            // every conversion; `false` a POSITIVE answer that it does NOT
            // (either no hook at all — typically a `run.sh` started by hand
            // outside the app — or a hook whose engine patch failed); `null`
            // the probe itself did not complete. `false` and `null` are NOT
            // interchangeable: only `false` means "we know you are
            // unprotected", and only `false` puts the m23-fo warning in
            // `message`. Additive and independent of
            // ai.sidecarStatus — this is a SECOND, separate local sidecar.
            // This is process-lifecycle management only — voice-conversion/
            // training tools arrive in a later roadmap item.
            try params.rejectUnknownKeys([], verb: "vc.sidecarStatus")
            let vcStatus = await voiceConversionManager.status()
            return .success(request.id, try JSONValue(encoding: vcStatus))

        case "vc.sidecarStart":
            // No params. Spawns scripts/rvc/run.sh (loopback-only FastAPI
            // facade) if not already healthy, then polls /health up to a
            // startup timeout (~30s, blocking). Throws notInstalled
            // (verbatim, points at scripts/rvc/install.sh) if the sidecar
            // was never installed, or a launch error if the process exits
            // during startup. A timeout without reaching healthy is NOT an
            // error — it returns state "starting" with an honest message
            // naming elapsed time and the log path; every LATER
            // vc.sidecarStatus poll keeps reporting "starting" with a
            // truthfully increasing startingForSeconds (the same M10-b
            // discipline ai.sidecarStart applies). Response:
            // VoiceConversionStatus (see vc.sidecarStatus for field shape).
            try params.rejectUnknownKeys([], verb: "vc.sidecarStart")
            let startedVCStatus = try await voiceConversionManager.start()
            return .success(request.id, try JSONValue(encoding: startedVCStatus))

        case "vc.sidecarStop":
            // No params. Graceful stop (SIGTERM, escalating to SIGKILL if it
            // doesn't exit in time) of a running sidecar. The target comes
            // from the pidfile when that points at a live process, and
            // otherwise from whichever process holds the listening socket on
            // the sidecar's port (m23-bb-1: a stale pidfile used to make this
            // verb report "was not running" while the sidecar kept running —
            // the same defect m23-bb fixed for ai.sidecarStop, and the
            // planning/identity/termination logic is now literally shared with
            // it, see Sources/AIServices/SidecarStopPlanner.swift).
            // A no-op success (not an error) if it genuinely wasn't running.
            // ERRORS (SidecarError.stopFailed) rather than reporting success
            // when the sidecar is still answering afterwards, or when the only
            // process on its port can't be identified as the RVC facade —
            // which is never signalled. Response: VoiceConversionStatus (state
            // settles to installedNotRunning/notInstalled).
            try params.rejectUnknownKeys([], verb: "vc.sidecarStop")
            let stoppedVCStatus = try await voiceConversionManager.stop()
            await modelLifecycle.noteStoppedExternally(.rvc)   // see ai.sidecarStop
            return .success(request.id, try JSONValue(encoding: stoppedVCStatus))

        case "vc.convertVocals":
            // BLOCKING (m10-p-4) — the facade's POST /v1/voice/convert is
            // synchronous and runs at roughly 37x real time (m10-p-2
            // measurement) plus a cold-engine load, so this call can
            // legitimately take minutes on a real multi-minute source clip;
            // this is a render.mixdown-class call, not an ai.generateSong-
            // class async job (no job registry here). VoiceConversionClient
            // gives ONLY this one call its own long timeout
            // (config.convertTimeoutSeconds, default 300s) — health/list/
            // status/train stay on the fast default.
            //
            // params: EXACTLY ONE of clipId (an existing AUDIO clip — its
            // FULL backing recording is what gets converted; clip trims/
            // stretch are NOT applied to the source audio fed to the
            // converter, only to how the RESULT is later placed) or path
            // (absolute or ~-expanded local audio file). voiceId (required —
            // a trained voice's id, or the reserved "base" smoke target,
            // which exercises the full pipeline honestly WITHOUT a real
            // trained voice — its result always carries realConversion:false
            // plus a note explaining why). pitchSemitones (optional int,
            // -24..24 — NOT re-validated here; an out-of-range value reaches
            // the wire as the facade's own pitchOutOfRange teaching error,
            // verbatim). trackName (optional — defaults to "Voice:
            // <voiceId>"). atBeat (optional — defaults to the source clip's
            // own start beat when clipId was given, else 0).
            //
            // Always imports the result as a NEW AI-flagged audio track +
            // clip (violet in the UI) in ONE undoable "Import Converted
            // Voice" edit — there is no separate ai.importGeneration-style
            // second step (a blocking call already has the finished file in
            // hand). Response: {trackId, clipId, outputPath, realConversion,
            // inputSeconds, inferSeconds, rtf?, sampleRate, note?}.
            //
            // Rights-responsibility policy (m23-n2d — the user WITHDREW the
            // old own-voice-only prohibition): third-party voice models are
            // supported, and the user owns provenance/licensing for whatever
            // voice they train or convert with. Throws the SidecarManager-style
            // actionable guidance (pointing at vc.sidecarStart, or
            // scripts/rvc/install.sh if never installed) when the sidecar
            // isn't reachable, instead of a bare connection error.
            try params.rejectUnknownKeys(
                ["clipId", "path", "voiceId", "pitchSemitones", "trackName", "atBeat"],
                verb: "vc.convertVocals")
            let vcVoiceId = try params.require("voiceId", \.stringValue)
            let vcClipIdRaw = params["clipId"]?.stringValue
            let vcPathRaw = params["path"]?.stringValue
            if vcClipIdRaw != nil, vcPathRaw != nil {
                throw ControlError(
                    "vc.convertVocals: pass either 'clipId' or 'path', not both — "
                        + "they name the source audio two different ways")
            }
            let vcInputPath: String
            let vcDefaultAtBeat: Double
            if let vcClipIdRaw {
                guard let vcClipId = UUID(uuidString: vcClipIdRaw) else {
                    throw ControlError("'clipId' is not a valid UUID: \(vcClipIdRaw)")
                }
                let vcSource = try store.voiceConversionSource(clipId: vcClipId)
                vcInputPath = vcSource.url.path
                vcDefaultAtBeat = vcSource.startBeat
            } else if let vcPathRaw {
                let vcExpandedPath = (vcPathRaw as NSString).expandingTildeInPath
                guard vcExpandedPath.hasPrefix("/") else {
                    throw ControlError("'path' must be an absolute path")
                }
                vcInputPath = vcExpandedPath
                vcDefaultAtBeat = 0
            } else {
                throw ControlError("vc.convertVocals: pass either 'clipId' or 'path' naming the source audio")
            }
            let vcPitchSemitones = params["pitchSemitones"]?.doubleValue.map { Int($0) } ?? 0
            let vcTrackNameRaw = params["trackName"]?.stringValue
            let vcAtBeat = params["atBeat"]?.doubleValue ?? vcDefaultAtBeat
            do {
                let vcResult = try await voiceConverting.convert(VoiceConvertRequest(
                    inputPath: vcInputPath, voiceId: vcVoiceId, pitchSemitones: vcPitchSemitones))
                let vcResolvedTrackName = (vcTrackNameRaw?.isEmpty == false) ? vcTrackNameRaw! : "Voice: \(vcVoiceId)"
                let (vcTrackID, vcClipID) = try store.importConvertedVoice(
                    fileURL: URL(fileURLWithPath: vcResult.outputPath),
                    trackName: vcResolvedTrackName,
                    atBeat: vcAtBeat)
                var vcResponse: [String: JSONValue] = [
                    "trackId": .string(vcTrackID.uuidString),
                    "clipId": .string(vcClipID.uuidString),
                    "outputPath": .string(vcResult.outputPath),
                    "realConversion": .bool(vcResult.realConversion),
                    "inputSeconds": .number(vcResult.inputSeconds),
                    "inferSeconds": .number(vcResult.inferSeconds),
                    "sampleRate": .number(Double(vcResult.sampleRate)),
                ]
                if let rtf = vcResult.rtf { vcResponse["rtf"] = .number(rtf) }
                if let note = vcResult.note { vcResponse["note"] = .string(note) }
                return .success(request.id, .object(vcResponse))
            } catch {
                throw await translateVoiceConversionError(error)
            }

        case "vc.listVoices":
            // No params (m10-p-5 — the Voice panel made voice-listing
            // user-facing, so the CLAUDE.md convention requires the wire
            // command). Returns every voice a vc.convertVocals voiceId can
            // name: {voices: [{id, name, state, hasIndex?, createdAt?,
            // kind?, trained?, note?}, ...]} — the reserved "base" smoke
            // target FIRST (kind "builtin", trained false, plus its note; a
            // real conversion target that proves the pipeline without a
            // trained voice — see vc.convertVocals), then every real
            // user-trained voice. Composed by VoiceConverting
            // .availableVoiceTargets — the facade's /v1/voice/list is
            // real-voices-only BY ITS OWN DESIGN, so base is fetched from
            // its own /v1/voice/base/status endpoint; descriptor CONTENTS
            // are the facade's own, verbatim (nothing invented or edited).
            // The SAME helper feeds the Voice panel, so UI and wire can
            // never diverge. Real voices appear once training ships
            // (m10-p-6). Unreachable sidecar → the manager's state-specific
            // actionable message (never a bare connection error), via
            // translateVoiceConversionError — the vc.convertVocals/
            // vc.trainVoice precedent. Rights-responsibility policy
            // (m23-n2d): voices listed here may be user-trained OR
            // user-supplied third-party models; provenance is the user's.
            try params.rejectUnknownKeys([], verb: "vc.listVoices")
            do {
                let vlDescriptors = try await voiceConverting.availableVoiceTargets()
                return .success(request.id, .object([
                    "voices": try JSONValue(encoding: vlDescriptors),
                ]))
            } catch {
                throw await translateVoiceConversionError(error)
            }

        case "vc.trainVoice":
            // params: name (required — the new voice's display name).
            // datasetDir (required — absolute or ~-expanded local directory
            // of clean dry vocal recordings the user has the rights to use;
            // m23-n2d — third-party voices permitted, provenance is the
            // user's). voiceId (optional — a
            // specific id for the new voice; omit to let the facade derive
            // one from name). epochs (optional — training-length override).
            // Today the facade validates shape then ALWAYS answers a
            // structured 501 trainingNotYetAvailable (contract-reserved —
            // training ships with the Voice panel, m10-p-5/p-6) — that
            // teaching error reaches the wire VERBATIM via the LocalizedError
            // mapping in `handle(_:)`; this handler does not rewrite it. A
            // future 2xx response's raw JSON body passes through unchanged
            // rather than inventing a response schema now (see
            // `VoiceConversionClient.train`'s own doc comment).
            try params.rejectUnknownKeys(
                ["name", "datasetDir", "voiceId", "epochs"], verb: "vc.trainVoice")
            let vtName = try params.require("name", \.stringValue)
            let vtDatasetDirRaw = try params.require("datasetDir", \.stringValue)
            let vtDatasetDir = (vtDatasetDirRaw as NSString).expandingTildeInPath
            guard vtDatasetDir.hasPrefix("/") else {
                throw ControlError("'datasetDir' must be an absolute path")
            }
            let vtVoiceId = params["voiceId"]?.stringValue
            let vtEpochs = params["epochs"]?.doubleValue.map { Int($0) }
            do {
                let vtData = try await voiceConverting.train(VoiceTrainRequest(
                    name: vtName, datasetDir: vtDatasetDir, voiceId: vtVoiceId, epochs: vtEpochs))
                guard let vtValue = try? JSONDecoder().decode(JSONValue.self, from: vtData) else {
                    throw ControlError(
                        "vc.trainVoice: sidecar responded 2xx but the body could not be parsed as JSON")
                }
                return .success(request.id, vtValue)
            } catch {
                throw await translateVoiceConversionError(error)
            }

        case "vc.importVoiceModel":
            // Third-party RVC voice-model IMPORT (m23-di-2a) — the "drop a
            // model folder in" case scripts/rvc/server.py:141's own comment
            // names, wired up. params: modelPath (required — absolute or
            // ~-expanded local path to a third-party RVC .pth checkpoint).
            // indexPath (optional — absolute/~-expanded path to its
            // companion FAISS .index; raises conversion quality when
            // present, server.py's hasIndex field). voiceId (optional — the
            // store id this voice is listed under; derived from 'name' or
            // the model file's own stem when omitted, sanitised to
            // [A-Za-z0-9-_]; the reserved smoke-test id "base" is refused).
            // name (optional display name written into a voice.json
            // alongside the model — defaults to the same stem voiceId
            // derives from). overwrite (optional bool, default false —
            // replace an existing voice at that id instead of refusing, the
            // ai.installSpeechModel precedent).
            //
            // PURE LOCAL FILESYSTEM COPY into VoiceModelImport.voicesDirectory
            // (<Application Support>/DAWPro/VoiceModels — never inside the
            // read-only scripts/rvc/ checkout). Needs no running sidecar:
            // the facade's own _scan_voices() (server.py:177) is a plain
            // directory scan, and RVC_VOICES_DIR now points HERE at every
            // vc.sidecarStart (VoiceConversionManager.spawnAndPoll), so a
            // voice imported before OR after the sidecar's first boot is
            // found either way — confirm with vc.listVoices once the
            // sidecar is healthy. Never converts .pth -> .npz (m23-di-2b,
            // blocked on the user's word — no sidecar route exists for it,
            // and adding one would mean editing scripts/rvc/server.py,
            // which is forbidden): the voice lands honestly in
            // "needsConversion" state, the same state vc.listVoices/the
            // Voice panel's "NEEDS PREP" chip already render for a
            // partially-prepared voice.
            //
            // Rights-responsibility policy (m23-n2d — the user WITHDREW the
            // old own-voice-only prohibition): third-party/celebrity voice
            // models are supported; provenance and licensing are the
            // user's, not this command's concern.
            try params.rejectUnknownKeys(
                ["modelPath", "indexPath", "voiceId", "name", "overwrite"],
                verb: "vc.importVoiceModel")
            let vimModelPathRaw = try params.require("modelPath", \.stringValue)
            let vimModelPath = (vimModelPathRaw as NSString).expandingTildeInPath
            guard vimModelPath.hasPrefix("/") else {
                throw ControlError("'modelPath' must be an absolute path")
            }
            var vimIndexPath: String?
            if let vimIndexPathRaw = params["indexPath"]?.stringValue {
                let expanded = (vimIndexPathRaw as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/") else {
                    throw ControlError("'indexPath' must be an absolute path")
                }
                vimIndexPath = expanded
            }
            let vimResult = try VoiceModelImport.importModel(
                modelPath: vimModelPath,
                indexPath: vimIndexPath,
                voiceId: params["voiceId"]?.stringValue,
                name: params["name"]?.stringValue,
                overwrite: params["overwrite"]?.boolValue ?? false,
                voicesDirectory: voiceModelImportDirectory)
            return .success(request.id, .object([
                "voiceId": .string(vimResult.voiceId),
                "name": .string(vimResult.name),
                "hasIndex": .bool(vimResult.hasIndex),
                "state": .string("needsConversion"),
                "directoryPath": .string(vimResult.directoryPath),
            ]))

        case "clip.transcribe":
            // BLOCKING (m23-n2b) — the render.mixdown-class precedent stated
            // verbatim at vc.convertVocals above: there is NO in-app job
            // registry (ai.generateSong's job lives in the ACE-Step
            // SIDECAR), so inventing one here would be new infrastructure
            // for a call that, like vc.convertVocals, can simply await its
            // answer. On-device WhisperKit (m23-n2a); nothing leaves the
            // machine. `transcriber` is held ONE PER ROUTER (see its own
            // property doc): the FIRST call on a machine pays a one-time
            // ~90 s CoreML ANE compile (measured 93.7 s cold vs 1.15 s
            // warm, 2026-07-27) that the OS then caches, so every later
            // call is ~1 s. `mcp-server/src/bridge.ts` gives this command
            // its own timeout tier (CLIP_TRANSCRIBE_TIMEOUT_MS) sized for
            // that cold-compile-plus-transcribe shape — see that file's
            // comment for why VOICE_CONVERT_TIMEOUT_MS's 330 s (sized for a
            // DIFFERENT, real-time-factor-bound cost model) isn't reused.
            //
            // params: clipId (required — an existing AUDIO clip; a MIDI
            // clip has no audioFileURL and is refused with
            // transcriptionRequiresAudioClip). language (optional
            // BCP-47-ish code like "en" — omitted lets the recogniser
            // decide, exactly as WhisperTranscriptionRequest does).
            //
            // The clip -> request mapping has ONE home:
            // Clip.sourceWindowSeconds(tempoMap:) (Model.swift), the single
            // evaluator of how much of the source file a clip reads.
            // audioURL/startSeconds/endSeconds/anchorBeat all come from
            // ProjectStore.transcriptionSource(clipId:)
            // (ProjectStore+Transcription.swift), which calls it verbatim
            // rather than re-deriving it.
            //
            // stretchRatio != 1 is REFUSED
            // (transcriptionRequiresUnstretchedClip), never silently wrong:
            // WhisperKit's word timings come back in SOURCE seconds, and
            // the beat mapper (m23-n2a, stretch-unaware by construction)
            // maps elapsed SOURCE seconds straight onto the timeline —
            // correct only when one source second equals one timeline
            // second, i.e. exactly stretchRatio == 1. The engine itself
            // ignores stretch until M5 ii-d, so refusing here is the
            // honest interim rather than placing a word at the wrong beat
            // by exactly that factor.
            //
            // Response: the Transcription value verbatim — {text, language,
            // modelVariantDirectoryName, rangeStartSeconds, anchorBeat,
            // supportsWordTimestamps, wordTimestampSupport,
            // wordTimestampsUnavailable?, wordTimestampsUnverified?, segments:
            // [{text, startSeconds, endSeconds, startBeat, endBeat, words:
            // [{text, startSeconds, endSeconds, startBeat, endBeat,
            // confidence}]}]}.
            //
            // m23-n3f — the word-timestamp fields are ADDITIVE FIELDS on this
            // existing response, not a new verb: WhisperKit's word timings come
            // from a CoreML `alignment_heads_weights` decoder output that some
            // compiled variants simply do not have, and without it the word
            // branch is skipped with no else and no error, so every `words`
            // array comes back empty. `supportsWordTimestamps` is a property
            // of the resolved MODEL (never inferred from `words.isEmpty` —
            // an instrumental clip has no words either), and when it is false
            // `wordTimestampsUnavailable` carries the teaching text naming the
            // variant, the decoder path inspected, and what to install
            // instead. The job still SUCCEEDS: the text and the SEGMENT beats
            // are correct regardless, so this reports rather than refuses.
            //
            // m23-ef — `wordTimestampSupport` ("supported" | "unsupported" |
            // "unknown") is the ADDITIVE third state, and the field to read
            // when an empty `words` array has to be explained. n3f could only
            // say yes-or-no, so a variant whose capability could not be read at
            // all (the `.mlpackage` layout carries no `metadata.json` to ask)
            // was reported identically to one that declared the output. That
            // optimism is deliberate and UNCHANGED — `supportsWordTimestamps`
            // still reads `true` for "unknown", because saying no at every
            // `.mlpackage`, capable ones included, teaches callers to ignore
            // the warning — but it is no longer LOSSY. The two message fields
            // are mutually exclusive and each is OMITTED (never null) when it
            // does not apply: `wordTimestampsUnavailable` is the VERDICT, present
            // only for "unsupported"; `wordTimestampsUnverified` is a hedged
            // CAUTION, present only when the state is "unknown" AND this run
            // returned at least one segment but not one word — the shape where
            // an unreadable capability is genuinely the suspect. It stays silent
            // on a run that produced words (nothing to apologise for) and on one
            // that heard nothing at all (silence and instrumentals are wordless
            // for reasons that have nothing to do with the weights). ⚠️ That
            // emptiness gates the CAUTION only; the CAPABILITY itself is never
            // inferred from `words.isEmpty`.
            // Errors: clipNotFound /
            // transcriptionRequiresAudioClip /
            // transcriptionRequiresUnstretchedClip surface via the
            // LocalizedError mapping in handle(_:); WhisperModelError
            // surfaces the catalog's own teaching text verbatim when no
            // model is installed.
            try params.rejectUnknownKeys(["clipId", "language"], verb: "clip.transcribe")
            let transcribeClipID = try params.requireClipID()
            let transcribeLanguage = params["language"]?.stringValue
            let transcribeSource = try store.transcriptionSource(clipId: transcribeClipID)
            let transcription = try await transcriber.transcribe(WhisperTranscriptionRequest(
                audioURL: transcribeSource.audioURL,
                startSeconds: transcribeSource.startSeconds,
                endSeconds: transcribeSource.endSeconds,
                anchorBeat: transcribeSource.anchorBeat,
                tempoMap: transcribeSource.tempoMap,
                language: transcribeLanguage))
            return .success(request.id, try JSONValue(encoding: transcription))

        case "ai.installSpeechModel":
            // Starts a WhisperKit model download/install (m23-n3b, on top of
            // the m23-n3a installer) and RETURNS IMMEDIATELY — never waits
            // for the transfer. Poll ai.speechModelInstallStatus for
            // progress and the terminal outcome. Chosen over a blocking call
            // (clip.transcribe/vc.convertVocals's shape) because a
            // multi-hundred-MB-to-multi-GB fetch is a fundamentally
            // different cost model from either of those; the in-tree
            // precedent for a locally-owned long job with PULL-based status
            // is the stretch render (AudioEngine.clipStretchStatus), not a
            // blocking call.
            //
            // params: variant (required — a WhisperKit size like "tiny.en"
            // or a full on-disk directory name like
            // "openai_whisper-tiny.en"). overwrite (optional bool, default
            // false — replaces an existing install of the SAME variant;
            // omitting it on an already-installed variant is a FAST failure,
            // discoverable only by polling, same as every other failure this
            // starts — see installCoordinator's own doc for why this command
            // never pre-checks). repo/token are NOT exposed here: the
            // default public repo needs neither, and a Hugging Face token is
            // exactly the kind of secret the house key policy keeps off the
            // agent-logged control plane (ai.providerStatus's rationale,
            // verbatim) even though it isn't one of the three provider keys
            // that policy was written for.
            //
            // ONE install in flight at a time, enforced by
            // WhisperModelInstallCoordinator (held ONE PER ROUTER, the
            // transcriber precedent): a second call while one is running is
            // REFUSED — never queued, never coalesced — naming the variant
            // already installing.
            //
            // Response / ai.speechModelInstallStatus's response (SAME
            // shape): {state: "idle"|"installing"|"succeeded"|"failed",
            // variantDirectoryNameRequested?, progress?: {phase,
            // variantDirectoryName, phaseFraction, completedUnitCount,
            // totalUnitCount}, descriptor?: {variantDirectoryName,
            // displayName, modelFolder, tokenizerFolder, modelSizeBytes,
            // tokenizerSizeBytes, hasContextPrefill, supportsWordTimestamps,
            // wordTimestampSupport}, errorMessage?}.
            // `supportsWordTimestamps` is m23-n3f's additive descriptor field:
            // false means the installed variant's decoder declares no
            // `alignment_heads_weights` output, so clip.transcribe will return
            // segments but never words. Reported here so that is knowable at
            // INSTALL time rather than after a transcription comes back empty.
            // `wordTimestampSupport` ("supported" | "unsupported" | "unknown")
            // is m23-ef's additive third state, and the one to branch on: the
            // Bool above reads TRUE for "unknown" on purpose (see
            // clip.transcribe), so it cannot distinguish a variant that declared
            // the output from one whose capability could not be read at all.
            // ⚠️ `totalSizeBytes` / `formattedTotalSize` were listed here and in
            // the MCP tool description until m23-ef and were NEVER encoded —
            // they are computed properties of `WhisperModelDescriptor` and the
            // payload has always omitted them. The docs were corrected rather
            // than the payload grown (an additive wire change nobody asked for
            // is still a wire change); `WhisperModelCatalogEncodingTests`
            // asserts the exact key set, so this list can now be checked.
            try params.rejectUnknownKeys(["variant", "overwrite"], verb: "ai.installSpeechModel")
            let installVariant = try params.require("variant", \.stringValue)
            let installOverwrite = params["overwrite"]?.boolValue ?? false
            let installStatus = try await installCoordinator.start(
                variant: installVariant, overwrite: installOverwrite)
            return .success(request.id, try JSONValue(encoding: installStatus))

        case "ai.speechModelInstallStatus":
            // No params — this coordinator tracks exactly one install slot
            // (in flight, or the most recently finished one), so there is
            // nothing to disambiguate. Response: see ai.installSpeechModel.
            try params.rejectUnknownKeys([], verb: "ai.speechModelInstallStatus")
            let pollStatus = await installCoordinator.status()
            return .success(request.id, try JSONValue(encoding: pollStatus))

        case "fx.spectrum":
            // params: trackId (required — a track/bus UUID or the exact
            // string "master"), effectId (required UUID), arm? (bool,
            // default true). m23-r4 (design-m23r4-fx-spectrum-lease.md): a
            // control-plane 3-second TTL LEASE on top of the per-insert
            // spectrum tap r1-r3 built. `arm:true` (the default) arms-or-
            // renews the lease then reads; `arm:false` reads once more and
            // releases. There is no peek mode — those are the only two
            // states.
            //
            // The lease is swept lazily HERE, and ONLY here (before params
            // are even parsed, so an expired lease from a PRIOR call is
            // always reaped before this call's own cap check runs).
            // `armed` in the response means "the CONTROL-PLANE lease is
            // held as of this response" — NOT "the engine tap is armed"
            // (which can be true anyway because the UI's own EQ card holds
            // it): `ProjectStore`'s named-owner set (`InsertAnalysisOwner`)
            // means the wire and the UI can never stomp each other's arm.
            //
            // Response = the SAME MasterAnalysisSnapshot encoding
            // mixer.masterAnalysis uses (bands/levelDB/peakDB/centroidHz/
            // flux/correlation/width/balance) PLUS armed, tapPoint
            // ("postInsertPreFader" | "postInsertPostFader" — a strip
            // insert reads BEFORE that track's own fader, a master insert
            // reads AFTER the master fader), leaseSeconds (the full TTL).
            // A refusal never carries floor bands — an unarmed tap must
            // never masquerade as a live silent meter. At most
            // `AudioEngineControlling.maxArmedInsertAnalysis` inserts
            // total — shared first-come-first-served with any open UI EQ
            // card — can be measured at once; the 9th is refused, never
            // evicted (spectrumTapsFull, naming the cap). On `arm:false`
            // with nothing armed, the analysis fields are simply OMITTED
            // (armed:false + tapPoint + leaseSeconds ride alone) — that is
            // a benign success, not an error, mirroring the engine's own
            // "disarming always reports true".
            insertSpectrumLeases.sweep { target in
                store.setInsertAnalysisArmed(trackID: target.trackID, effectID: target.effectID,
                                             armed: false, owner: .control)
            }
            try params.rejectUnknownKeys(["trackId", "effectId", "arm"], verb: "fx.spectrum")
            let fxSpecTrackID: UUID?
            switch try params.parseFXTarget() {
            case .track(let id): fxSpecTrackID = id
            case .master: fxSpecTrackID = nil
            }
            let fxSpecEffectID = try params.requireEffectID()
            let fxSpecArm = params["arm"]?.boolValue ?? true
            let fxSpecTapPoint = InsertSpectrumTapPoint.forInsert(trackID: fxSpecTrackID)
            let fxSpecTarget = InsertAnalysisTarget(trackID: fxSpecTrackID, effectID: fxSpecEffectID)

            func fxSpecResponse(armed: Bool, snapshot: MasterAnalysisSnapshot?) throws -> JSONValue {
                var obj: [String: JSONValue] = [
                    "armed": .bool(armed),
                    "tapPoint": .string(fxSpecTapPoint.wireValue),
                    "leaseSeconds": .number(InsertSpectrumLeases.defaultTTLSeconds),
                ]
                if let snapshot, case .object(let snapObj) = try JSONValue(encoding: snapshot) {
                    for (snapKey, snapValue) in snapObj { obj[snapKey] = snapValue }
                }
                return .object(obj)
            }

            if fxSpecArm {
                switch store.setInsertAnalysisArmed(trackID: fxSpecTrackID, effectID: fxSpecEffectID,
                                                    armed: true, owner: .control) {
                case .armed:
                    insertSpectrumLeases.renew(fxSpecTarget)
                    // A nil reading here is a can't-happen: the arm just
                    // succeeded. Throw rather than fabricate a floor.
                    guard let snapshot = store.insertAnalysis(trackID: fxSpecTrackID,
                                                              effectID: fxSpecEffectID) else {
                        throw ProjectError.engineUnavailable
                    }
                    return .success(request.id, try fxSpecResponse(armed: true, snapshot: snapshot))
                case .trackNotFound(let id):
                    throw ProjectError.trackNotFound(id)
                case .effectNotFound(let id):
                    throw ProjectError.effectNotFound(id)
                case .unavailableHeadless, .unsupported:
                    throw ProjectError.engineUnavailable
                case .refusedCapFull(let cap):
                    throw ProjectError.spectrumTapsFull(cap)
                case .released:
                    throw ControlError("internal error: fx.spectrum arm returned .released")
                }
            } else {
                // Read WHILE still armed (if it is), THEN validate+release:
                // reading after release could observe the engine's own tap
                // already torn down (the owner set emptying disarms it),
                // which would turn every arm:false read into a false nil.
                let fxSpecReading = store.insertAnalysis(trackID: fxSpecTrackID,
                                                         effectID: fxSpecEffectID)
                switch store.setInsertAnalysisArmed(trackID: fxSpecTrackID, effectID: fxSpecEffectID,
                                                    armed: false, owner: .control) {
                case .released:
                    insertSpectrumLeases.release(fxSpecTarget)
                    return .success(request.id,
                                    try fxSpecResponse(armed: false, snapshot: fxSpecReading))
                case .trackNotFound(let id):
                    throw ProjectError.trackNotFound(id)
                case .effectNotFound(let id):
                    throw ProjectError.effectNotFound(id)
                case .unavailableHeadless, .unsupported:
                    throw ProjectError.engineUnavailable
                case .armed, .refusedCapFull:
                    throw ControlError("internal error: fx.spectrum release returned an arm outcome")
                }
            }

        case "frequency.reference":
            // m23-o1 (design-m23o1-instrument-frequency-reference.md §6): the
            // instrument frequency reference — cited fundamentals, presence/
            // problem bands, and an HP/LP recommendation the copilot can hand
            // straight to fx.setParam (highPassFreq/highPassSlopeDbPerOct).
            //
            // params: family? (a InstrumentFamily raw value), trackId?
            // (a track UUID — NO "master" sentinel; a bus has no instrument
            // identity and resolves trackIsNotAnInstrumentOrAudioTrack),
            // note? (GM percussion note, 0…127). ALL OPTIONAL — zero params
            // is legal and returns resolution:"index" with the family
            // vocabulary alone, which is how an agent learns the ids.
            //
            // The four-rung ladder (design §3): `family` (rung 1, handled
            // HERE — it WINS over `trackId` outright, and the response says
            // resolvedFrom:"argument" so the override is never silent) →
            // InstrumentFamilyResolver's own GM-program / GM-percussion-note
            // rungs (resolvedFrom:"gmProgram"|"gmPercussionNote") →
            // unresolved(reason) — a first-class, self-remedying failure:
            // every unresolved response carries reason/explanation/remedy
            // AND the same `families` index a resolved one does, so a typo'd
            // guess or a genuine gap costs the caller nothing extra.
            // `family` + `note` together is rejected (two keys that could
            // disagree). `note` against a MELODIC-bank track is NOT
            // rejected (an agent cannot know the bank before asking) — the
            // program resolves normally and the response adds
            // noteIgnored:true plus a one-line explanation; Silent ignore is
            // the thing this design refuses everywhere else. An unknown
            // `family` value is a NAMED error listing the valid ids — a typo
            // must never read as "not covered". A drumKit track queried with
            // no `note` returns resolution:"drumKit" + coveredNotes (the
            // notes this table knows); with an uncovered note, `unresolved`
            // still carries `coveredNotes` so "no data" never reads where
            // the truth is "not this one, but here are the ones I do have".
            try params.rejectUnknownKeys(["family", "trackId", "note"], verb: "frequency.reference")
            let freqFamilyRaw = try Self.optionalString(params["family"], "'family'")
            let freqTrackIdRaw = try Self.optionalString(params["trackId"], "'trackId'")
            let freqNote = try Self.optionalInteger(params["note"], "'note'")
            if let freqNote, !(0...127).contains(freqNote) {
                throw ControlError("'note' must be a MIDI note number 0…127")
            }
            if freqFamilyRaw != nil, freqNote != nil {
                throw ControlError(
                    "'family' and 'note' cannot both be passed — a named family already "
                        + "answers the question, and 'note' could disagree with it")
            }

            if let freqFamilyRaw {
                guard let freqFamily = InstrumentFamily(rawValue: freqFamilyRaw) else {
                    let validFamilies = InstrumentFamily.allCases.map(\.rawValue)
                        .sorted().joined(separator: ", ")
                    throw ControlError(
                        "unknown 'family' value '\(freqFamilyRaw)' — valid ids are \(validFamilies)")
                }
                return .success(request.id, Self.frequencyReferenceJSON(
                    resolution: .resolved(freqFamily, source: .argument), noteIgnored: false))
            }

            guard let freqTrackIdRaw else {
                return .success(request.id,
                                Self.frequencyReferenceJSON(resolution: nil, noteIgnored: false))
            }
            guard let freqTrackID = UUID(uuidString: freqTrackIdRaw) else {
                throw ControlError("'trackId' is not a valid UUID: \(freqTrackIdRaw)")
            }
            guard let freqTrack = store.tracks.first(where: { $0.id == freqTrackID }) else {
                throw ControlError.noTrack(freqTrackID)
            }
            let freqResolution = InstrumentFamilyResolver.resolve(
                trackKind: freqTrack.kind, instrument: freqTrack.instrument,
                percussionNote: freqNote)
            var freqNoteIgnored = false
            if freqNote != nil, case .resolved(_, let freqSource) = freqResolution,
               freqSource == .gmProgram {
                freqNoteIgnored = true
            }
            return .success(request.id, Self.frequencyReferenceJSON(
                resolution: freqResolution, noteIgnored: freqNoteIgnored))

        case "clip.removeMany":
            // params: ids (required array of clip id strings; may be empty).
            // The wire half of ProjectStore.removeClips(ids:) (m23-g1/m23-w) —
            // removes SEVERAL clips as ONE undoable edit, the group-delete verb
            // behind the arrange's multi-selection. ALL-OR-NOTHING: every id
            // must resolve to a live clip and clear requireNotCompMember
            // BEFORE anything is removed — an unknown id or a take-group
            // member refuses WHOLE and leaves the project untouched, with the
            // SAME clipNotFound/clipInTakeGroup errors clip.remove gives via
            // the LocalizedError mapping. Duplicate ids collapse. An empty
            // 'ids' is a no-op — {"clips": []}, no undo entry journaled
            // (mirrors ProjectStore.removeClips([])). Response: {"clips":
            // [...]} — the removed clips, wrapped (not a bare top-level
            // array, so an agent has one consistent shape to parse across
            // this verb and clip.moveMany below).
            try params.rejectUnknownKeys(["ids"], verb: "clip.removeMany")
            let removeManyIDs = try parseClipIDs(params["ids"], field: "ids", requirement: "")
            let removedClips = try store.removeClips(ids: removeManyIDs)
            return .success(request.id, .object([
                "clips": try JSONValue(encoding: removedClips),
            ]))

        case "clip.moveMany":
            // params: ids (required array of clip id strings; may be empty),
            // byBeats (required Double — signed; positive moves later,
            // negative earlier). The wire half of
            // ProjectStore.moveClips(ids:byBeats:) (m23-g2/m23-w) — translates
            // SEVERAL clips RIGIDLY by the same delta as ONE undoable edit,
            // the group-move verb behind the arrange's multi-selection drag.
            // ALL-OR-NOTHING like clip.removeMany (same clipNotFound/
            // clipInTakeGroup errors). WHOLE-GROUP BEAT-0 CLAMP: the
            // effective delta is reduced (never per-clip) so the group's
            // leftmost clip never crosses beat 0 — every other clip's offset
            // from it survives intact even when clamped. Response surfaces
            // the clamp instead of a bare ok, because a group move can
            // legitimately deliver LESS than requested and an agent that
            // cannot see that will compound the shortfall on its next call:
            // {"requestedDeltaBeats", "effectiveDeltaBeats", "clamped",
            // "trimmedClipIDs", "removedClipIDs", "clips"}. An empty 'ids',
            // or a delta the clamp reduces to exactly 0, is a no-op — no undo
            // entry journaled (mirrors ProjectStore.moveClips's own early
            // returns).
            try params.rejectUnknownKeys(["ids", "byBeats"], verb: "clip.moveMany")
            let moveManyIDs = try parseClipIDs(params["ids"], field: "ids", requirement: "")
            let moveManyDelta = try params.require("byBeats", \.doubleValue)
            let moveManyResult = try store.moveClips(ids: moveManyIDs, byBeats: moveManyDelta)
            return .success(request.id, .object([
                "requestedDeltaBeats": .number(moveManyResult.requestedDeltaBeats),
                "effectiveDeltaBeats": .number(moveManyResult.effectiveDeltaBeats),
                "clamped": .bool(moveManyResult.clamped),
                "trimmedClipIDs": .array(moveManyResult.trimmedClipIDs.map { .string($0.uuidString) }),
                "removedClipIDs": .array(moveManyResult.removedClipIDs.map { .string($0.uuidString) }),
                "clips": try JSONValue(encoding: moveManyResult.clips),
            ]))

        case "clip.moveManyByTracks":
            // params: ids (required array of clip id strings; may be empty),
            // byTracks (required, a signed WHOLE number of tracks — negative
            // = up the track list, positive = down), byBeats (optional,
            // default 0 — signed beat delta applied at the same time, so one
            // call can move down AND along in ONE undo step). The wire half
            // of ProjectStore.moveClips(ids:byTracks:byBeats:) (m23-aj) — the
            // VERTICAL twin of clip.moveMany: every listed clip moves the
            // SAME number of tracks, so a selection spanning several tracks
            // keeps its shape.
            //
            // ⚠️ byTracks is REFUSED, never truncated, when it carries a
            // fractional part. The design doc's §9.1 floated parsing it
            // "through the existing integer-parameter path (arrange.
            // insertBars's atBar/count, track.reorder's index)" — MEASURED
            // FALSE: both of those do `Int(double)`, which silently
            // truncates 1.9 to 1. Silently discarding the caller's fraction
            // is exactly the defect class parseOutputFormat's bitDepth guard
            // exists to avoid, so byTracks gets its own integrality check
            // (`isInteger(_:)`, the pitch/velocity/controller precedent)
            // BEFORE the `Int(...)` conversion, not after.
            //
            // WHOLE-GROUP CLAMP: running off the top or bottom of the track
            // list reduces the effective delta (never per clip, never a
            // throw) — read clampedTracks/effectiveTrackDelta rather than
            // assuming byTracks fully applied. A landing that cannot hold a
            // mover's clip kind (including a bus) REFUSES THE WHOLE MOVE
            // with the same midiClipsRequireInstrumentTrack/
            // trackKindUnsupported errors clip.duplicate already throws.
            //
            // Response is the shared ClipsTrackMoveResult shape (see
            // clipsTrackMoveResultJSON below): "requestedTrackDelta" and
            // "effectiveTrackDelta" are ALWAYS present here (non-nil for the
            // byTracks shape) — contrast clip.moveManyToTrack, which omits
            // both.
            try params.rejectUnknownKeys(["ids", "byTracks", "byBeats"], verb: "clip.moveManyByTracks")
            let byTracksIDs = try parseClipIDs(params["ids"], field: "ids", requirement: "")
            let byTracksRaw = try params.require("byTracks", \.doubleValue)
            guard Self.isInteger(byTracksRaw) else {
                throw ControlError(
                    "'byTracks' must be a whole number of tracks (e.g. -1, 0, 2) — "
                    + "\(byTracksRaw) has a fractional part and would be silently "
                    + "truncated rather than honored")
            }
            let byTracksDelta = Int(byTracksRaw)
            let byTracksBeats = try Self.optionalNumber(params["byBeats"], "'byBeats'") ?? 0
            let byTracksResult = try store.moveClips(
                ids: byTracksIDs, byTracks: byTracksDelta, byBeats: byTracksBeats)
            return .success(request.id, try Self.clipsTrackMoveResultJSON(byTracksResult))

        case "clip.moveManyToTrack":
            // params: ids (required array of clip id strings; may be empty),
            // toTrackId (required uuid string — unknown id throws
            // trackNotFound EVEN WHEN ids IS EMPTY, an agent that typo'd a
            // track id must learn immediately rather than get a silent
            // success), byBeats (optional, default 0). The wire half of
            // ProjectStore.moveClips(ids:toTrackId:byBeats:) (m23-aj) — the
            // DESTINATION-shaped twin of clip.moveManyByTracks: every listed
            // clip lands on the SAME named track, which COLLAPSES a
            // multi-track selection by construction (relative BEAT offsets
            // survive, relative TRACK offsets do not).
            //
            // A landing that cannot hold a mover's clip kind (including a
            // bus) REFUSES THE WHOLE MOVE, same errors as
            // clip.moveManyByTracks. Because this shape can COLLAPSE several
            // source tracks onto one, two movers from DIFFERENT source
            // tracks can be asked to occupy the same destination beats — a
            // collision this verb itself MANUFACTURED, not a pre-existing
            // one. That is refused with
            // ProjectError.clipsWouldOverlapOnDestination, surfaced VERBATIM
            // by the blanket LocalizedError arm above (no wire-side mapping
            // — the exact wording is contract, pinned byte-exact by
            // ClipCrossTrackMoveCommandTests).
            //
            // Response is the shared ClipsTrackMoveResult shape
            // (clipsTrackMoveResultJSON below) with "requestedTrackDelta"/
            // "effectiveTrackDelta" OMITTED (not null) — a destination-
            // shaped move has no delta, and a synthesized 0 would be
            // indistinguishable from "the clamp reduced the request to
            // nothing" (design §6/§9.2).
            try params.rejectUnknownKeys(["ids", "toTrackId", "byBeats"], verb: "clip.moveManyToTrack")
            let toTrackIDs = try parseClipIDs(params["ids"], field: "ids", requirement: "")
            let toTrackDestination = try params.requireUUID("toTrackId")
            let toTrackBeats = try Self.optionalNumber(params["byBeats"], "'byBeats'") ?? 0
            let toTrackResult = try store.moveClips(
                ids: toTrackIDs, toTrackId: toTrackDestination, byBeats: toTrackBeats)
            return .success(request.id, try Self.clipsTrackMoveResultJSON(toTrackResult))

        default:
            // App-installed surface (see `appCommandHandler`): a non-nil return
            // wraps as success; nil (or no handler) falls through to the
            // unknown-command error. debug.* lives here, off the allCommands /
            // MCP-parity list by convention.
            if let handler = appCommandHandler,
               let result = try handler(request.command, params) {
                return .success(request.id, result)
            }
            throw ControlError(
                "unknown command '\(request.command)' — known: \(Self.allCommands.joined(separator: ", "))"
            )
        }
    }

    /// Opens an ACE-Step job against the model-lifecycle coordinator (m23-dl).
    ///
    /// ⚠️⚠️ **This is what makes F8 real in production.** `activeJobs > 0` is an
    /// absolute veto on eviction, and unload-before-load is now unconditional —
    /// so without these hooks, starting RVC while ACE is rendering would SIGTERM
    /// ACE mid-generation, and the idle timer would fire ten minutes into a long
    /// render. The job is closed by `ai.generationStatus` on a terminal state,
    /// and by `policy.jobLeaseSeconds` if nobody ever polls.
    ///
    /// Inert when the coordinator has no ACE descriptor registered, which is
    /// every headless test.
    private func noteACEJobStarted(_ jobID: String) async {
        await modelLifecycle.noteJobStarted(.aceStep, jobID: jobID)
    }

    /// Does this `ai.generationStatus` failure PROVE the job is over, or does it
    /// only prove we could not ask?
    ///
    /// Only the first kind may close a job (F8). The split is deliberately
    /// asymmetric — an error has to earn its way into the "close it" list:
    ///
    /// - `.jobFailed` — the sidecar itself reported this job terminal. Over.
    /// - `.jobNotFound` — the sidecar has no such job. Over (and re-protecting
    ///   a job the sidecar has forgotten would pin the model for a full lease
    ///   with nothing rendering).
    /// - everything else — `.sidecarUnreachable` (dropped connection),
    ///   `.requestFailed` (any HTTP status, including a proxy 504 during a long
    ///   render), `.malformedResponse`, `.modelSlotUnavailable`, and any
    ///   non-`ACEStepError` thrown by a different provider — say nothing about
    ///   the job. Leave it open; the lease self-heals.
    ///
    /// ⚠️ The `default` deliberately returns false, so a NEW error case added to
    /// `ACEStepError` later is treated as transient until someone decides
    /// otherwise. The safe direction for an unknown error is to keep protecting
    /// the render.
    static func errorProvesJobIsOver(_ error: Error) -> Bool {
        guard let aceError = error as? ACEStepError else { return false }
        switch aceError {
        case .jobFailed, .jobNotFound:
            return true
        case .sidecarUnreachable, .requestFailed, .malformedResponse, .modelSlotUnavailable:
            return false
        }
    }

    /// Translates a `songGenerator` failure into the message actually
    /// surfaced to the control-protocol client. `ACEStepError
    /// .sidecarUnreachable` is special-cased: rather than the client's own
    /// generic connection-error text, we re-probe `sidecarManager.status()`
    /// and surface ITS message instead, so callers get the precise
    /// state-specific next step (`run install.sh` vs. `call
    /// ai.sidecarStart` vs. `poll ai.sidecarStatus again`) instead of a bare
    /// "could not connect". Every other case already carries an actionable
    /// `LocalizedError` message (job-failed, malformed response, etc.) and
    /// passes through verbatim, matching the rest of this router's error
    /// handling (see `handle(_:)`).
    private func translateSongGeneratorError(_ error: Error) async -> Error {
        if case ACEStepError.sidecarUnreachable = error {
            let status = await sidecarManager.status()
            return ControlError(status.message)
        }
        return error
    }

    /// The `translateSongGeneratorError` precedent for the RVC voice-
    /// conversion sidecar (m10-p-4): a bare connection failure is replaced
    /// with `VoiceConversionManager`'s own state-specific actionable message
    /// (notInstalled vs. installedNotRunning vs. still-starting), so
    /// `vc.convertVocals`/`vc.trainVoice` never surface a raw "connection
    /// refused" — everything else (including the facade's own teaching
    /// errors, e.g. voiceNotReady/pitchOutOfRange/trainingNotYetAvailable)
    /// passes through UNCHANGED, verbatim.
    private func translateVoiceConversionError(_ error: Error) async -> Error {
        if case VoiceConversionError.sidecarUnreachable = error {
            let status = await voiceConversionManager.status()
            return ControlError(status.message)
        }
        return error
    }

    /// Wire shape shared by input.listDevices and input.setDevice:
    /// {"devices": [{uid, name, sampleRate, channelCount, isDefault}, ...]}.
    private func inputDeviceList() throws -> JSONValue {
        .object(["devices": try JSONValue(encoding: store.listInputDevices())])
    }

    /// Wire shape shared by output.listDevices and output.setDevice (m20-j):
    /// {"devices": [{uid, name, sampleRate, channelCount, isDefault,
    /// isSelected}, ...]}.
    ///
    /// The input twin's five fields plus `isSelected`, which the input side
    /// does not have and the output side needs: a picker has to be able to
    /// read back WHICH device this app is pinned to, and that is not
    /// `isDefault` (the system's choice). Following the system default is the
    /// state where NO device reports `isSelected` — distinct from having
    /// explicitly pinned the device that is currently the default.
    private func outputDeviceList() throws -> JSONValue {
        .object(["devices": try JSONValue(encoding: store.listOutputDevices())])
    }

    /// Shared result shape for all three m28-knob mapping verbs, so an agent
    /// re-orients in one round trip whichever one it called:
    ///
    /// ```
    /// {"bindings": [{"target","controller","channel"?,"sourceId"?,"inverted"}],
    ///  "targets":  [{"id","name","summary","controller"?,"sourceId"?}],
    ///  "learningTarget": "…"?,      // present only while learn is armed
    ///  "lastControlChange": {"sourceId","channel","controller","value"}?,
    ///  "subscribed": bool}
    /// ```
    ///
    /// `targets` is the CATALOGUE — every thing a control can drive, each with
    /// the binding that currently drives it. An agent that only reads
    /// `bindings` cannot discover what it is allowed to bind TO; publishing the
    /// catalogue in the same payload is what makes the table self-describing.
    ///
    /// ⭐ `lastControlChange` is the diagnostic that separates "your knob is not
    /// mapped" from "your knob is not sending" — the two failures look identical
    /// from the outside, and only one of them is our bug. It is non-destructive:
    /// reading it never steals an event from the delivery pump.
    private func midiControlMapPayload() -> JSONValue {
        let map = store.midiControlMap
        func encode(_ binding: MIDIControlBinding) -> JSONValue {
            var out: [String: JSONValue] = [
                "target": .string(binding.target.rawValue),
                "controller": .number(Double(binding.controller)),
                "inverted": .bool(binding.inverted),
            ]
            if let channel = binding.channel { out["channel"] = .number(Double(channel)) }
            if let sourceID = binding.sourceID {
                out["sourceId"] = .number(Double(sourceID))
            }
            return .object(out)
        }
        var payload: [String: JSONValue] = [
            "bindings": .array(map.bindings.map(encode)),
            "targets": .array(MIDIControlTarget.allCases.map { target in
                var entry: [String: JSONValue] = [
                    "id": .string(target.rawValue),
                    "name": .string(target.displayName),
                    "summary": .string(target.summary),
                ]
                if let binding = map.binding(for: target) {
                    entry["controller"] = .number(Double(binding.controller))
                    if let sourceID = binding.sourceID {
                        entry["sourceId"] = .number(Double(sourceID))
                    }
                }
                return .object(entry)
            }),
            "subscribed": .bool(store.midiControl.isSubscribed),
        ]
        if let learning = map.learningTarget {
            payload["learningTarget"] = .string(learning.rawValue)
        }
        if let event = map.lastEvent {
            payload["lastControlChange"] = .object([
                "sourceId": .number(Double(event.sourceID)),
                "channel": .number(Double(event.channel)),
                "controller": .number(Double(event.controller)),
                "value": .number(Double(event.value)),
            ])
        }
        return .object(payload)
    }

    /// Shared result shape for all four routing commands so an agent re-orients
    /// in one round trip: `{"trackId", "outputBusId": <uuid>|null, "sends":
    /// [{"id","busId","level"}]}`. `track.addSend` also carries the new `"sendId"`.
    /// `outputBusId` is explicit `null` when routed to master (never omitted).
    private func routingResult(trackID: UUID, sendID: UUID? = nil) -> JSONValue {
        guard let track = store.tracks.first(where: { $0.id == trackID }) else {
            // The mutation just succeeded, so the track is present; this is only a
            // belt-and-suspenders fallback.
            return .object(["trackId": .string(trackID.uuidString)])
        }
        var obj: [String: JSONValue] = [
            "trackId": .string(trackID.uuidString),
            "outputBusId": track.outputBusID.map { JSONValue.string($0.uuidString) } ?? .null,
            "sends": .array(track.sends.map { send in
                .object([
                    "id": .string(send.id.uuidString),
                    "busId": .string(send.destinationBusID.uuidString),
                    "level": .number(send.level),
                ])
            }),
        ]
        if let sendID { obj["sendId"] = .string(sendID.uuidString) }
        return .object(obj)
    }

    /// Resolves a REQUIRED `kind` param to `EffectDescriptor.Kind`. Absent →
    /// missing-param error; a present-but-invalid string names the valid values
    /// verbatim (the "unknown … — use …" pattern).
    private func parseEffectKind(_ value: JSONValue?) throws -> EffectDescriptor.Kind {
        guard let raw = value?.stringValue else {
            throw ControlError("missing or invalid required param 'kind'")
        }
        guard let kind = EffectDescriptor.Kind(rawValue: raw) else {
            let valid = EffectDescriptor.Kind.allCases.map(\.rawValue).joined(separator: "|")
            throw ControlError("unknown effect kind '\(raw)' — use \(valid)")
        }
        return kind
    }

    /// Shared result shape for the fx mutation commands so an agent re-orients in
    /// one round trip: `{"trackId", "effects": [<resolved effect>]}`. `fx.add`
    /// and `fx.setParam` also carry `"effectId"`. Effects use the same resolved
    /// shape as the snapshot (see `effectsJSON`).
    private func fxResult(trackID: UUID, effectID: UUID? = nil) -> JSONValue {
        let effects = store.tracks.first(where: { $0.id == trackID })?.effects ?? []
        var obj: [String: JSONValue] = [
            "trackId": .string(trackID.uuidString),
            "effects": effectsJSON(effects, trackID: trackID),
        ]
        if let effectID { obj["effectId"] = .string(effectID.uuidString) }
        return .object(obj)
    }

    /// `fxResult` twin for the MASTER chain (m13-d): echoes the `trackId:
    /// "master"` sentinel so an agent re-orients, plus the resolved master
    /// insert chain (same `effectsJSON` shape as the snapshot's top-level
    /// `masterEffects`, with the master per-effect latency resolver).
    private func masterFxResult(effectID: UUID? = nil) -> JSONValue {
        var obj: [String: JSONValue] = [
            "trackId": .string("master"),
            "effects": masterEffectsJSON(),
        ]
        if let effectID { obj["effectId"] = .string(effectID.uuidString) }
        return .object(obj)
    }

    /// Resolved wire JSON for the project master insert chain — the per-track
    /// `effectsJSON` shape with MASTER latency + gain-reduction resolvers
    /// (the limiter's 240 @ 48 kHz and a master compressor's live
    /// `gainReductionDb` surface here just as they do per strip; 0 / omitted
    /// headless). Shared by `masterFxResult` and the snapshot's top-level
    /// `masterEffects`.
    private func masterEffectsJSON() -> JSONValue {
        Self.effectsJSON(
            store.masterEffects,
            latencyFor: { store.masterEffectLatencySamples(effectID: $0) },
            gainReductionFor: { store.masterEffectGainReductionDb(effectID: $0) })
    }

    // MARK: - plugin.* helpers (M3 vi-b)

    /// Full validation for `plugin.openUI` (§5.3), performed BEFORE the seam
    /// (`pluginUI`) check so the taxonomy is headless-testable: track exists,
    /// and either the named effect is an Audio Unit insert, or the track hosts
    /// an Audio Unit instrument. A built-in kind is rejected readably — plugin
    /// windows apply only to Audio Units (built-ins have in-app panels).
    /// The wire shape of one marker: `{id, name, beat}`. Shared by `marker.add/
    /// rename/move` (single) and `marker.list` (array), so the shape never drifts.
    private static func markerJSON(_ marker: Marker) -> JSONValue {
        .object([
            "id": .string(marker.id.uuidString),
            "name": .string(marker.name),
            "beat": .number(marker.beat),
        ])
    }

    /// The wire shape of a tempo/meter map read (m12-d) — shared by `tempo.map`
    /// and the `tempo.setMap` echo so the shape never drifts. Reports the
    /// RESOLVED maps (always >= 1 entry each; a single-tempo project reports its
    /// synthesized single segment/change) plus the monotonic `mapRevision`.
    private static func tempoMapJSON(_ store: ProjectStore) -> JSONValue {
        let map = store.transport.tempoMap
        let meter = store.transport.meterMap
        // `startBeat` is the beat key everywhere (the model/persist/snapshot
        // Codable shape + the MIDI-note `startBeat` wire convention), so a map
        // read from project.snapshot copies straight into tempo.setMap.
        return .object([
            "segments": .array(map.segments.map {
                .object(["startBeat": .number($0.startBeat), "bpm": .number($0.bpm)])
            }),
            "meterChanges": .array(meter.changes.map {
                .object(["startBeat": .number($0.startBeat),
                         "beatsPerBar": .number(Double($0.beatsPerBar)),
                         "beatUnit": .number(Double($0.beatUnit))])
            }),
            "mapRevision": .number(Double(store.mapRevision)),
        ])
    }

    /// Parses + validates `tempo.setMap`'s required `segments` into a `TempoMap`,
    /// mapping the type's field-named `ValidationError`s to teaching strings.
    private static func parseTempoMap(_ params: [String: JSONValue]) throws -> TempoMap {
        guard let raw = params["segments"]?.arrayValue else {
            throw ControlError("'segments' is required — an array of {startBeat, bpm}; segment 0 must start at beat 0")
        }
        guard !raw.isEmpty else {
            throw ControlError("'segments' must have at least one entry — the base tempo at beat 0")
        }
        var segments: [TempoMap.Segment] = []
        for (index, entry) in raw.enumerated() {
            guard let object = entry.objectValue,
                  let startBeat = object["startBeat"]?.doubleValue,
                  let bpm = object["bpm"]?.doubleValue else {
                throw ControlError("segments[\(index)] must be {startBeat: number, bpm: number}")
            }
            segments.append(TempoMap.Segment(startBeat: startBeat, bpm: bpm))
        }
        do {
            return try TempoMap(segments: segments)
        } catch let error as TempoMap.ValidationError {
            throw ControlError(Self.tempoMapValidationMessage(error))
        }
    }

    private static func tempoMapValidationMessage(_ error: TempoMap.ValidationError) -> String {
        switch error {
        case .emptySegments:
            return "'segments' must have at least one entry — the base tempo at beat 0"
        case .firstSegmentNotAtZero(let startBeat):
            return "segments[0] must start at beat 0 (the base tempo) — got beat \(startBeat)"
        case .unsortedOrDuplicateStartBeat(let index):
            return "segments[\(index)] must have a beat strictly greater than the previous segment's — segments must be sorted by beat with no duplicates"
        }
    }

    /// Parses `tempo.setMap`'s OPTIONAL `meterChanges`. Absent ⇒ nil (leave the
    /// current meter map untouched); present-but-empty is a field-named error.
    private static func parseMeterMap(_ params: [String: JSONValue]) throws -> MeterMap? {
        guard let raw = params["meterChanges"]?.arrayValue else { return nil }
        guard !raw.isEmpty else {
            throw ControlError("'meterChanges' must have at least one entry (change 0 at beat 0) — omit the field entirely to leave the meter map unchanged")
        }
        var changes: [MeterMap.Change] = []
        for (index, entry) in raw.enumerated() {
            guard let object = entry.objectValue,
                  let startBeat = object["startBeat"]?.doubleValue,
                  let beatsPerBar = object["beatsPerBar"]?.doubleValue,
                  let beatUnit = object["beatUnit"]?.doubleValue else {
                throw ControlError("meterChanges[\(index)] must be {startBeat: number, beatsPerBar: number, beatUnit: number}")
            }
            changes.append(MeterMap.Change(startBeat: startBeat,
                                           beatsPerBar: Int(beatsPerBar), beatUnit: Int(beatUnit)))
        }
        do {
            return try MeterMap(changes: changes)
        } catch let error as MeterMap.ValidationError {
            throw ControlError(Self.meterMapValidationMessage(error))
        }
    }

    private static func meterMapValidationMessage(_ error: MeterMap.ValidationError) -> String {
        switch error {
        case .emptyChanges:
            return "'meterChanges' must have at least one entry — change 0 at beat 0"
        case .firstChangeNotAtZero(let startBeat):
            return "meterChanges[0] must start at beat 0 (the project meter) — got beat \(startBeat)"
        case .unsortedOrDuplicateStartBeat(let index):
            return "meterChanges[\(index)] must have a beat strictly greater than the previous change's — changes must be sorted by beat with no duplicates"
        case .changeOffBarline(let index):
            return "meterChanges[\(index)] must fall on a barline of the meter before it — its beat isn't a whole number of bars past the previous change"
        }
    }

    // MARK: - MIDI file export parsing (m23-k4a)

    /// An OPTIONAL path that must still be absolute when present. Absent is a
    /// legitimate request ("put it wherever you put things"), which is why this
    /// cannot reuse `requireAbsolutePath`, but a PRESENT relative path is a
    /// mistake worth naming rather than resolving against whatever directory the
    /// app happened to launch from.
    private static func parseOptionalAbsolutePath(_ value: JSONValue?,
                                                  key: String) throws -> String? {
        guard let raw = value?.stringValue else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ControlError("'\(key)' must be an absolute path")
        }
        return expanded
    }

    /// Contract-range check on `division`, reading `MIDIExportOptions`' own
    /// constants so this message and the store's guard can never disagree about
    /// what is legal (the iv-d contract-range idiom). A clamp is deliberately
    /// NOT used: silently exporting at 32767 when the caller asked for 100000
    /// produces a file whose grid is not the one they asked for.
    private static func parseMIDIExportDivision(_ value: JSONValue?) throws -> Int {
        guard let raw = value?.doubleValue else {
            return MIDIExportOptions.defaultTicksPerQuarterNote
        }
        let range = MIDIExportOptions.ticksPerQuarterNoteRange
        let rounded = Int(raw.rounded())
        guard Double(rounded) == raw, range.contains(rounded) else {
            throw ControlError(
                "'division' must be a whole number of ticks per quarter note between "
                + "\(range.lowerBound) and \(range.upperBound) — got \(raw). The default "
                + "\(MIDIExportOptions.defaultTicksPerQuarterNote) is exact for every grid "
                + "DAW Pro can produce, including swing; 480 is the industry default and "
                + "quantizes swung material.")
        }
        return rounded
    }

    private static func parseMIDIExportFormat(_ value: JSONValue?) throws -> Int {
        guard let raw = value?.doubleValue else { return 1 }
        let rounded = Int(raw.rounded())
        guard Double(rounded) == raw,
              MIDIExportOptions.legalFormatValues.contains(rounded) else {
            throw ControlError(
                "'format' must be 0 (everything merged into one track, which can carry "
                + "only one track name) or 1 (one track per part, the default) — got \(raw)")
        }
        return rounded
    }

    // MARK: - MIDI file import parsing (m23-k3)

    /// Parses `project.importMIDI`'s optional `tempoPolicy`. An unknown value is
    /// a teaching error LISTING the legal ones — never a silent fallback to the
    /// default, which is how an agent's typo becomes "why did my tempo change".
    private static func parseMIDITempoPolicy(_ value: JSONValue?) throws -> MIDITempoPolicy {
        guard let raw = value?.stringValue else { return .auto }
        guard let policy = MIDITempoPolicy(rawValue: raw) else {
            let legal = MIDITempoPolicy.allCases.map { "\"\($0.rawValue)\"" }
                .joined(separator: ", ")
            throw ControlError(
                "'tempoPolicy' must be one of \(legal) — got \"\(raw)\". \"auto\" adopts the "
                + "file's tempo map only when the project has no clips yet; there is no \"ask\" "
                + "(a UI dialog chooses between \"adopt\" and \"ignore\")")
        }
        return policy
    }

    /// Parses `project.importMIDI`'s optional `instruments`, same rule.
    ///
    /// ABSENT ⇒ `.gm` since m23-k5 (it was `.none` in k3, which is why every
    /// human import landed on the default poly synth). The default lives in
    /// `MIDIImportInstruments`; it is REPEATED here rather than deferred to
    /// `store.importMIDIFile`'s own default because this parser must return a
    /// value, and the two are pinned together by a test.
    private static func parseMIDIImportInstruments(_ value: JSONValue?) throws
        -> MIDIImportInstruments {
        guard let raw = value?.stringValue else { return .gm }
        guard let mode = MIDIImportInstruments(rawValue: raw) else {
            let legal = MIDIImportInstruments.allCases.map { "\"\($0.rawValue)\"" }
                .joined(separator: ", ")
            throw ControlError(
                "'instruments' must be one of \(legal) — got \"\(raw)\". \"gm\" (the default) "
                + "assigns General MIDI sound-bank programs from the file's program changes; "
                + "\"none\" leaves the new tracks on the default instrument")
        }
        return mode
    }

    /// Parses `project.importMIDI`'s optional `parts`. Absent ⇒ nil (import
    /// every part). An EXPLICIT empty array selects nothing and is left to the
    /// store's zero-effect refusal to explain — the plain reading of an explicit
    /// list, and the only one that keeps `parts` idempotent.
    private static func parseMIDIPartIndices(_ value: JSONValue?) throws -> [Int]? {
        guard let value else { return nil }
        guard let raw = value.arrayValue else {
            throw ControlError(
                "'parts' must be an array of part indices (run with dryRun: true to see them)")
        }
        return try raw.enumerated().map { index, entry in
            guard let number = entry.doubleValue, number == number.rounded() else {
                throw ControlError("parts[\(index)] must be a whole-number part index")
            }
            return Int(number)
        }
    }

    /// Resolves a `transport.seek {marker}` token to its beat (m11-c). The token
    /// is a marker id (UUID string) OR its EXACT name. An id wins when it parses
    /// and matches; otherwise an exact-name match is used, and a name shared by
    /// more than one marker is `markerAmbiguous` (seek by id instead). Nothing
    /// matched → `markerNotFound`-shaped error naming the field.
    private func resolveMarkerBeat(_ token: String) throws -> Double {
        if let id = UUID(uuidString: token), let m = store.markers.first(where: { $0.id == id }) {
            return m.beat
        }
        let named = store.markers.filter { $0.name == token }
        if named.count > 1 { throw ProjectError.markerAmbiguous(token) }
        guard let m = named.first else {
            throw ControlError("no marker matching 'marker' value '\(token)' — pass a marker id or exact name (marker.list has both)")
        }
        return m.beat
    }

    private func requirePluginTarget(_ params: [String: JSONValue]) throws -> PluginUITarget {
        let trackID = try params.requireTrackID()
        guard let track = store.tracks.first(where: { $0.id == trackID }) else {
            throw ControlError.noTrack(trackID)
        }
        if params["effectId"] != nil {
            let effectID = try params.requireEffectID()
            guard let effect = track.effects.first(where: { $0.id == effectID }) else {
                throw ControlError("no effect with id \(effectID.uuidString) on track \(trackID.uuidString)")
            }
            guard effect.kind == .audioUnit else {
                throw ControlError(
                    "effect '\(effectID.uuidString)' is a built-in \(effect.kind.rawValue) — plugin windows apply only to Audio Unit effects")
            }
            return .effect(trackID: trackID, effectID: effectID)
        }
        guard track.kind == .instrument else {
            throw ControlError(
                "track '\(trackID.uuidString)' is a \(track.kind.rawValue) track — plugin windows apply only to Audio Unit instruments")
        }
        let instrumentKind = (track.instrument ?? .default).kind
        guard instrumentKind == .audioUnit else {
            if instrumentKind == .soundBank {
                throw ControlError(
                    "track '\(trackID.uuidString)' uses a sound-bank instrument — sound banks have no plugin window; choose programs with instrument.listSoundBankPrograms + track.setInstrument, or the in-app instrument picker. Plugin windows apply only to Audio Unit instruments")
            }
            throw ControlError(
                "track '\(trackID.uuidString)' uses the built-in \(instrumentKind.rawValue) instrument — plugin windows apply only to Audio Unit instruments")
        }
        return .instrument(trackID: trackID)
    }

    // MARK: - au.* helpers (hosted-AU parameter surface)

    /// Target params for the `au.*` pair: trackId (required UUID — the EXACT
    /// string "master" rejects with a teaching error, since the master chain
    /// is built-in-only by design-m13d D4a and can never host an AU) plus
    /// optional effectId. KIND validation deliberately lives in ONE place —
    /// `ProjectStore.resolveHostedAUTarget` (the requirePluginTarget taxonomy
    /// with AU-parameters wording) — and is NOT duplicated here.
    private static func requireHostedAUTarget(_ params: [String: JSONValue]) throws
        -> (trackID: UUID, effectID: UUID?) {
        if params["trackId"]?.stringValue == "master" {
            throw ControlError(
                "the master chain hosts built-in effects only — AU parameters apply to track inserts")
        }
        let trackID = try params.requireTrackID()
        let effectID: UUID? = params["effectId"] != nil ? try params.requireEffectID() : nil
        return (trackID, effectID)
    }

    /// `offset` (int ≥ 0, default 0). Rejects non-integers/negatives
    /// readably; absurdly large offsets are capped in the Double domain
    /// BEFORE the Int conversion (no trap) — they just page past the tree
    /// and return an empty, untruncated page.
    private static func parseAUOffset(_ params: [String: JSONValue]) throws -> Int {
        guard let raw = params["offset"] else { return 0 }
        guard let value = raw.doubleValue, value >= 0,
              value == value.rounded(.towardZero) else {
            throw ControlError("'offset' must be an integer >= 0")
        }
        return Int(min(value, 1_000_000_000))
    }

    /// `maxParams` (default 512) — out-of-range values silently CLAMP into
    /// 1…4096 (the frozen paging decision); non-integers reject readably.
    private static func parseAUMaxParams(_ params: [String: JSONValue]) throws -> Int {
        guard let raw = params["maxParams"] else { return 512 }
        guard let value = raw.doubleValue, value == value.rounded(.towardZero) else {
            throw ControlError(
                "'maxParams' must be an integer (default 512; values clamp into 1…4096)")
        }
        return Int(min(max(value, 1), 4_096))
    }

    /// `addresses` — the exact-get filter: an array of decimal-string
    /// addresses from au.describeParams. Entry TYPE errors reject readably;
    /// addresses that don't resolve are reported in `unknownAddresses` by
    /// the engine, never an error.
    private static func parseAUAddressFilter(_ params: [String: JSONValue]) throws -> [String]? {
        guard let raw = params["addresses"] else { return nil }
        guard let array = raw.arrayValue else {
            throw ControlError(
                "'addresses' must be an array of decimal address strings (see au.describeParams results)")
        }
        return try array.enumerated().map { index, entry in
            guard let string = entry.stringValue else {
                throw ControlError(
                    "addresses[\(index)] must be a decimal address string from au.describeParams")
            }
            return string
        }
    }

    /// `address` (required): the decimal STRING is canonical; an
    /// exactly-integral JSON number ≤ 2^53 is tolerated (a larger double
    /// cannot represent the address exactly, so it rejects).
    private static func requireAUAddress(_ params: [String: JSONValue]) throws -> String {
        guard let raw = params["address"] else {
            throw ControlError(
                "'address' is required — the decimal address string from au.describeParams")
        }
        if let string = raw.stringValue { return string }
        if let number = raw.doubleValue,
           number.isFinite, number >= 0, number <= 9_007_199_254_740_992,
           number == number.rounded(.towardZero) {
            return String(UInt64(number))
        }
        throw ControlError(
            "'address' must be the decimal string form of the parameter address (see au.describeParams)")
    }

    /// Wire shape of one hosted-AU parameter (shared by `au.describeParams`
    /// rows and the `au.setParam` echo so the shape never drifts). `unitName`
    /// and `valueStrings` are explicit nulls when absent, per the design's
    /// response shape.
    private static func auParameterJSON(_ info: HostedAUParameterInfo) -> JSONValue {
        .object([
            "address": .string(info.address),
            "identifier": .string(info.identifier),
            "displayName": .string(info.displayName),
            "keyPath": .string(info.keyPath),
            "unit": .string(info.unit),
            "unitName": info.unitName.map { JSONValue.string($0) } ?? .null,
            "minValue": .number(info.minValue),
            "maxValue": .number(info.maxValue),
            "value": .number(info.value),
            "writable": .bool(info.writable),
            "readable": .bool(info.readable),
            "valueStrings": info.valueStrings.map { strings in
                JSONValue.array(strings.map { .string($0) })
            } ?? .null,
        ])
    }

    /// Syntax-only target for `plugin.closeUI`: trackId (required) + optional
    /// effectId, both validated for UUID SHAPE only. No store lookup — the
    /// target may have just been removed, and idempotent close is the agent-
    /// friendly contract.
    private func pluginCloseTarget(_ params: [String: JSONValue]) throws -> PluginUITarget {
        let trackID = try params.requireTrackID()
        if params["effectId"] != nil {
            return .effect(trackID: trackID, effectID: try params.requireEffectID())
        }
        return .instrument(trackID: trackID)
    }

    /// Wire shape for one plugin window (shared by `plugin.openUI` and each
    /// `plugin.listOpenUIs` entry). `alreadyOpen` is emitted only for the
    /// open-result flavor.
    private func pluginUIWindowJSON(_ info: PluginUIWindowInfo,
                                    alreadyOpen: Bool? = nil) -> JSONValue {
        var obj: [String: JSONValue] = [
            "trackId": .string(info.trackID.uuidString),
            "title": .string(info.title),
            "component": .object([
                "name": .string(info.componentName),
                "manufacturerName": .string(info.manufacturerName),
                "isV3": .bool(info.isV3),
            ]),
            "body": .string(info.body.rawValue),
            "frame": .object([
                "x": .number(info.frame.x),
                "y": .number(info.frame.y),
                "width": .number(info.frame.width),
                "height": .number(info.frame.height),
            ]),
        ]
        if let effectID = info.effectID { obj["effectId"] = .string(effectID.uuidString) }
        if let alreadyOpen { obj["alreadyOpen"] = .bool(alreadyOpen) }
        if let warning = info.warning { obj["warning"] = .string(warning) }
        return .object(obj)
    }

    /// Wire shape for one `EditPasteSkip` — `{sourceClipId, clipName, reason}`.
    private func editPasteSkipJSON(_ skip: EditPasteSkip) -> JSONValue {
        .object([
            "sourceClipId": .string(skip.sourceClipID.uuidString),
            "clipName": .string(skip.clipName),
            "reason": .string(skip.reason),
        ])
    }

    /// Wire shape for `edit.pasteClips`'s result — see the case arm's own doc
    /// comment for the four distinguishable outcomes this encodes.
    private func editPasteResultJSON(_ result: EditPasteResult) -> JSONValue {
        switch result {
        case .pasted(let landings, let skipped, let trimmedClipIDs, let removedClipIDs):
            return .object([
                "pasted": .bool(true),
                "landings": .array(landings.map {
                    .object([
                        "clipId": .string($0.clipID.uuidString),
                        "trackId": .string($0.trackID.uuidString),
                        "startBeat": .number($0.startBeat),
                    ])
                }),
                "skipped": .array(skipped.map(editPasteSkipJSON)),
                "trimmedClipIDs": .array(trimmedClipIDs.map { .string($0.uuidString) }),
                "removedClipIDs": .array(removedClipIDs.map { .string($0.uuidString) }),
            ])
        case .emptyClipboard:
            return .object([
                "pasted": .bool(false),
                "reason": .string("empty-clipboard"),
            ])
        case .wrongPayloadKind(let actual):
            return .object([
                "pasted": .bool(false),
                "reason": .string("wrong-payload-kind"),
                "clipboardKind": .string(actual),
            ])
        case .blocked(let reason, let skipped):
            return .object([
                "pasted": .bool(false),
                "reason": .string(reason),
                "skipped": .array(skipped.map(editPasteSkipJSON)),
            ])
        }
    }

    /// Wire shape for `macro.songSkeleton`'s result: the whole scaffold with
    /// real, actionable ids — `{genre, tempoBPM, tracks: [{id, name}],
    /// sectionClips: [{name, startBeat, lengthBeats}],
    /// markers: [{id, name, beat}], loopStart, loopEnd, arrangementTrackId}`.
    /// `tracks` lists EVERY created track (the genre roster then the Arrangement
    /// guide track LAST, whose id is also surfaced as `arrangementTrackId`).
    /// `markers` (ADDITIVE) is the session beat map the scaffold just dropped —
    /// one per section, at that section's start, in section order, named exactly
    /// like the matching `sectionClips` entry (repeats are NOT auto-numbered;
    /// disambiguate by `beat`). Each id is a REAL marker addressable by
    /// `marker.rename`/`marker.move`/`marker.remove` and listed by `marker.list`
    /// — which returns the whole project's markers, so it also carries any that
    /// pre-dated this call. The per-marker shape routes through the SAME
    /// `markerJSON` the marker verbs use, so the two can never drift.
    private func songSkeletonResult(_ result: SongSkeletonResult) -> JSONValue {
        .object([
            "genre": .string(result.genre),
            "tempoBPM": .number(result.tempoBPM),
            "tracks": .array(result.tracks.map { .object([
                "id": .string($0.id.uuidString),
                "name": .string($0.name),
            ]) }),
            "sectionClips": .array(result.sectionClips.map { .object([
                "name": .string($0.name),
                "startBeat": .number($0.startBeat),
                "lengthBeats": .number($0.lengthBeats),
            ]) }),
            "markers": .array(result.markers.map {
                Self.markerJSON(Marker(id: $0.id, name: $0.name, beat: $0.beat))
            }),
            "loopStart": .number(result.loopStart),
            "loopEnd": .number(result.loopEnd),
            "arrangementTrackId": .string(result.arrangementTrackID.uuidString),
        ])
    }

    /// Resolved wire JSON for one track's insert chain: `[{id, kind,
    /// isBypassed, params: {name:value}, latencySamples, gainReductionDb?}]`.
    /// Params are RESOLVED (nil structs emit their defaults, the
    /// instrument-snapshot rule). `latencySamples` is the live per-effect
    /// engine value forwarded through the store (the `availableAudioUnits`
    /// precedent — DAWControl itself stays engine-free): 240 @ 48 kHz for
    /// the limiter's lookahead, 0 for the other built-ins or when running
    /// headless. `gainReductionDb` (m22-e, ADDITIVE) is the live held-peak
    /// gain reduction of the built-in dynamics kinds — POSITIVE dB, 0 =
    /// untouched, −20 dB/s release — riding the SAME poll path an agent
    /// already orients from (project.snapshot + every fx mutation result);
    /// the key is OMITTED for kinds that don't measure GR and when headless,
    /// so its presence itself teaches which effects report it.
    private func effectsJSON(_ effects: [EffectDescriptor], trackID: UUID) -> JSONValue {
        Self.effectsJSON(
            effects,
            latencyFor: { store.effectLatencySamples(trackID: trackID, effectID: $0) },
            gainReductionFor: { store.effectGainReductionDb(trackID: trackID, effectID: $0) })
    }

    /// Shape helper for the above; `latencyFor` supplies each effect's live
    /// latency in samples, `gainReductionFor` its live held-peak gain
    /// reduction in positive dB (nil ⇒ key omitted — no fabricated meters).
    static func effectsJSON(_ effects: [EffectDescriptor],
                            latencyFor: (UUID) -> Int,
                            gainReductionFor: (UUID) -> Double? = { _ in nil }) -> JSONValue {
        .array(effects.map { effect in
            var obj: [String: JSONValue] = [
                "id": .string(effect.id.uuidString),
                "kind": .string(effect.kind.rawValue),
                "isBypassed": .bool(effect.isBypassed),
                "params": effectParamsJSON(effect),
                "latencySamples": .number(Double(latencyFor(effect.id))),
            ]
            // Omitted when nil (the disk rule): a keyed compressor/gate
            // surfaces its sidechain source so snapshots stay honest.
            if let key = effect.sidechainSourceTrackID {
                obj["sidechainSourceTrackId"] = .string(key.uuidString)
            }
            // Omitted when nil (m22-e): only live dynamics instances carry a
            // gain-reduction reading.
            if let gainReduction = gainReductionFor(effect.id) {
                obj["gainReductionDb"] = .number(gainReduction)
            }
            return .object(obj)
        })
    }

    /// The resolved `{name: value}` param object for one effect — the single
    /// place model fields map onto their wire names. New kinds (iv) extend
    /// this switch. Names match `EffectParamSpec` exactly.
    static func effectParamsJSON(_ effect: EffectDescriptor) -> JSONValue {
        switch effect.kind {
        case .gain:
            return .object(["gainLinear": .number(effect.resolvedGain.gainLinear)])
        case .eq:
            let eq = effect.resolvedEQ
            return .object([
                "lowShelfFreq": .number(eq.lowShelfFreq),
                "lowShelfGainDb": .number(eq.lowShelfGainDb),
                "peak1Freq": .number(eq.peak1Freq),
                "peak1GainDb": .number(eq.peak1GainDb),
                "peak1Q": .number(eq.peak1Q),
                "peak2Freq": .number(eq.peak2Freq),
                "peak2GainDb": .number(eq.peak2GainDb),
                "peak2Q": .number(eq.peak2Q),
                "highShelfFreq": .number(eq.highShelfFreq),
                "highShelfGainDb": .number(eq.highShelfGainDb),
                // m22-a EQ v2 — RESOLVED like everything else (nil semantics
                // live in EQParams' resolved accessors): an off HP/LP reads
                // enabled 0 with its corner parked at the range edge; the
                // `*Enabled` binaries ride as 0/1 numbers (pingPong precedent).
                "highPassFreq": .number(eq.resolvedHighPassFreq),
                "highPassSlopeDbPerOct": .number(Double(eq.resolvedHighPassSlope)),
                "highPassEnabled": .number(eq.resolvedHighPassEnabled ? 1 : 0),
                "lowShelfQ": .number(eq.resolvedLowShelfQ),
                "lowShelfEnabled": .number(eq.resolvedLowShelfEnabled ? 1 : 0),
                "peak1Enabled": .number(eq.resolvedPeak1Enabled ? 1 : 0),
                "peak2Enabled": .number(eq.resolvedPeak2Enabled ? 1 : 0),
                "highShelfQ": .number(eq.resolvedHighShelfQ),
                "highShelfEnabled": .number(eq.resolvedHighShelfEnabled ? 1 : 0),
                "lowPassFreq": .number(eq.resolvedLowPassFreq),
                "lowPassSlopeDbPerOct": .number(Double(eq.resolvedLowPassSlope)),
                "lowPassEnabled": .number(eq.resolvedLowPassEnabled ? 1 : 0),
            ])
        case .compressor:
            let comp = effect.resolvedCompressor
            return .object([
                "thresholdDb": .number(comp.thresholdDb),
                "ratio": .number(comp.ratio),
                "attackMs": .number(comp.attackMs),
                "releaseMs": .number(comp.releaseMs),
                "kneeDb": .number(comp.kneeDb),
                "makeupDb": .number(comp.makeupDb),
                "mix": .number(comp.mix),
            ])
        case .limiter:
            let limiter = effect.resolvedLimiter
            return .object([
                "ceilingDb": .number(limiter.ceilingDb),
                "releaseMs": .number(limiter.releaseMs),
                "truePeak": .number(limiter.truePeak ? 1 : 0),
            ])
        case .reverb:
            let reverb = effect.resolvedReverb
            return .object([
                "roomSize": .number(reverb.roomSize),
                "damping": .number(reverb.damping),
                "mix": .number(reverb.mix),
                "preDelayMs": .number(reverb.preDelayMs),
                "width": .number(reverb.width),
            ])
        case .delay:
            let delay = effect.resolvedDelay
            return .object([
                "timeMs": .number(delay.timeMs),
                "feedback": .number(delay.feedback),
                "mix": .number(delay.mix),
                "pingPong": .number(delay.pingPong),
                "highCutHz": .number(delay.highCutHz),
                // m22-f tempo sync — RESOLVED like the EQ v2 fields (nil
                // semantics live in DelayParams' resolved accessors): sync
                // rides as 0/1, division as its length in beats (the
                // fx.setParam surface), and divisionLabel as the human token
                // ("1/8d") so agents never reverse-map beats by hand.
                "sync": .number(delay.resolvedSync ? 1 : 0),
                "division": .number(delay.resolvedDivision.beats),
                "divisionLabel": .string(delay.resolvedDivision.rawValue),
            ])
        case .saturator:
            let saturator = effect.resolvedSaturator
            return .object([
                "driveDb": .number(saturator.driveDb),
                "mix": .number(saturator.mix),
                "outputDb": .number(saturator.outputDb),
            ])
        case .gate:
            let gate = effect.resolvedGate
            return .object([
                "thresholdDb": .number(gate.thresholdDb),
                "attackMs": .number(gate.attackMs),
                "holdMs": .number(gate.holdMs),
                "releaseMs": .number(gate.releaseMs),
            ])
        case .chorus:
            let chorus = effect.resolvedChorus
            return .object([
                "rateHz": .number(chorus.rateHz),
                "depthMs": .number(chorus.depthMs),
                "mix": .number(chorus.mix),
            ])
        case .bassEnhancer:
            let bass = effect.resolvedBassEnhancer
            return .object([
                "crossoverHz": .number(bass.crossoverHz),
                "amount": .number(bass.amount),
                "mix": .number(bass.mix),
            ])
        case .audioUnit:
            // Hosted AU: the component triple + display name. AU parameters
            // are not on the generic surface in v0, and captured state never
            // travels the wire (it rides only in the saved project).
            guard let config = effect.audioUnit else { return .object([:]) }
            return .object([
                "type": .string(config.component.type),
                "subType": .string(config.component.subType),
                "manufacturer": .string(config.component.manufacturer),
                "name": .string(config.name),
            ])
        }
    }

    /// Cap on notes per clip — a hard guard so a runaway agent request can't
    /// balloon a clip. Matches the message emitted below.
    private static let maxNotesPerClip = 4096

    /// Parses a JSON `notes` array into `[MIDINote]`, with exact, actionable
    /// errors keyed by index. Shared by clip.addMIDI and clip.setNotes. Times
    /// are beats relative to the clip start. `velocity` (default 100) and
    /// `lengthBeats` (default 1.0) are optional; `id` (a UUID) is optional and
    /// minted when absent. Integer fields must be whole numbers.
    private func parseNotes(_ value: JSONValue) throws -> [MIDINote] {
        guard let array = value.arrayValue else {
            throw ControlError("'notes' must be an array of {pitch, startBeat, velocity?, lengthBeats?, id?}")
        }
        guard array.count <= Self.maxNotesPerClip else {
            throw ControlError("'notes' exceeds the 4096-notes-per-clip limit (got \(array.count))")
        }
        var notes: [MIDINote] = []
        notes.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let pitchValue = element["pitch"]?.doubleValue,
                  Self.isInteger(pitchValue), pitchValue >= 0, pitchValue <= 127 else {
                throw ControlError("notes[\(i)].pitch must be an integer 0-127")
            }
            guard let startBeat = element["startBeat"]?.doubleValue, startBeat >= 0 else {
                throw ControlError("notes[\(i)].startBeat must be a number >= 0 (beats, relative to the clip start)")
            }
            let velocity: Int
            if let velocityValue = element["velocity"]?.doubleValue {
                guard Self.isInteger(velocityValue), velocityValue >= 1, velocityValue <= 127 else {
                    throw ControlError("notes[\(i)].velocity must be an integer 1-127 (0 is note-off; omit for the default 100)")
                }
                velocity = Int(velocityValue)
            } else {
                velocity = 100
            }
            let lengthBeats: Double
            if let lengthValue = element["lengthBeats"]?.doubleValue {
                guard lengthValue > 0 else {
                    throw ControlError("notes[\(i)].lengthBeats must be > 0")
                }
                lengthBeats = lengthValue
            } else {
                lengthBeats = 1.0
            }
            let id: UUID
            if let rawID = element["id"]?.stringValue {
                guard let parsed = UUID(uuidString: rawID) else {
                    throw ControlError("notes[\(i)].id is not a valid UUID: \(rawID)")
                }
                id = parsed
            } else {
                id = UUID()
            }
            notes.append(MIDINote(id: id, pitch: Int(pitchValue), velocity: velocity,
                                  startBeat: startBeat, lengthBeats: lengthBeats))
        }
        return notes
    }

    /// Parses a `points` param into `[ClipGainPoint]` for clip.setGainEnvelope.
    /// nil (omitted) or an empty array both mean CLEAR the envelope. Each element
    /// is `{beat, gainDb}`; `beat` must be a number >= 0 and the beats must be
    /// strictly ASCENDING (a duplicate or out-of-order beat is a teaching error
    /// naming the offending index — the store canonicalizes, but agents get a
    /// clear signal). `gainDb` is any number (the store clamps to -72..24).
    private func parseGainEnvelope(_ value: JSONValue?) throws -> [ClipGainPoint] {
        guard let value else { return [] }
        if case .null = value { return [] }
        guard let array = value.arrayValue else {
            throw ControlError("'points' must be an array of {beat, gainDb} (omit or pass [] to clear the envelope)")
        }
        var points: [ClipGainPoint] = []
        points.reserveCapacity(array.count)
        var previousBeat: Double?
        for (i, element) in array.enumerated() {
            guard let beat = element["beat"]?.doubleValue, beat >= 0 else {
                throw ControlError("points[\(i)].beat must be a number >= 0 (beats, relative to the clip start)")
            }
            guard let gainDb = element["gainDb"]?.doubleValue else {
                throw ControlError("points[\(i)].gainDb must be a number (decibels; clamped to -72..24)")
            }
            if let previousBeat {
                guard beat > previousBeat else {
                    throw ControlError("points[\(i)].beat (\(beat)) must be strictly greater than the previous point's beat (\(previousBeat)) — envelope points must be sorted ascending with no duplicate beats")
                }
            }
            previousBeat = beat
            points.append(ClipGainPoint(beat: beat, gainDb: gainDb))
        }
        return points
    }

    /// True when `value` is a finite whole number (no fractional part) — the
    /// integer check for pitch and velocity, since JSON carries them as doubles.
    private static func isInteger(_ value: Double) -> Bool {
        value.isFinite && value.rounded() == value
    }

    /// Parses the `type` (+ `controller` for cc) params into a
    /// `MIDIControllerType` for clip.setControllerLane / clip.removeControllerLane
    /// (m16-b). A bad `type` string names the valid types; `type=="cc"` REQUIRES
    /// an integer `controller` 0-127 (the teaching error names the mod/sustain
    /// hints). `requireController` is always true here — both verbs address a
    /// specific lane — but kept explicit for the contract.
    private func parseControllerType(_ params: [String: JSONValue],
                                     requireController: Bool) throws -> MIDIControllerType {
        guard let raw = params["type"]?.stringValue else {
            throw ControlError("'type' must be one of \"cc\", \"pitchBend\", \"channelPressure\"")
        }
        switch raw {
        case "pitchBend": return .pitchBend
        case "channelPressure": return .channelPressure
        case "cc":
            guard let controllerValue = params["controller"]?.doubleValue,
                  Self.isInteger(controllerValue), controllerValue >= 0, controllerValue <= 127 else {
                throw ControlError(
                    "'controller' is required when type is \"cc\" — an integer 0-127 (1 = mod wheel, 64 = sustain)")
            }
            return .cc(controller: Int(controllerValue))
        default:
            throw ControlError(
                "'type' must be one of \"cc\", \"pitchBend\", \"channelPressure\" — got \"\(raw)\"")
        }
    }

    /// Parses a `points` param into `[MIDIControllerPoint]` for
    /// clip.setControllerLane (m16-b). REQUIRED and NON-EMPTY (an empty lane is
    /// deleted via clip.removeControllerLane, not set). Each element is
    /// `{beat, value}`; `beat` must be a number >= 0; `value` must be an integer
    /// in the type's RAW MIDI domain — 0-16383 for pitchBend (8192 = center),
    /// 0-127 otherwise — with a per-index teaching error naming the domain. The
    /// store applies the 16384-point cap and canonicalizes; this shapes + domain-
    /// checks the array.
    private func parseControllerPoints(_ value: JSONValue?,
                                       type: MIDIControllerType) throws -> [MIDIControllerPoint] {
        guard let value, let array = value.arrayValue else {
            throw ControlError("'points' must be an array of {beat, value}")
        }
        guard !array.isEmpty else {
            throw ControlError(
                "'points' must be non-empty — use clip.removeControllerLane to delete a lane")
        }
        let range = type.valueRange
        var points: [MIDIControllerPoint] = []
        points.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let beat = element["beat"]?.doubleValue, beat >= 0 else {
                throw ControlError("points[\(i)].beat must be a number >= 0 (beats, relative to the clip start)")
            }
            guard let value = element["value"]?.doubleValue, Self.isInteger(value),
                  Int(value) >= range.lowerBound, Int(value) <= range.upperBound else {
                switch type {
                case .pitchBend:
                    throw ControlError("points[\(i)].value must be 0-16383 for pitchBend (8192 = center)")
                default:
                    throw ControlError("points[\(i)].value must be 0-127")
                }
            }
            points.append(MIDIControllerPoint(beat: beat, value: Int(value)))
        }
        return points
    }

    /// Parses a `target` param into `AutomationTarget` by round-tripping
    /// through its OWN Codable — the exact `{type: "volume"|"pan"|
    /// "sendLevel"|"effectParam", sendId?, effectId?, param?}` wire shape it
    /// already reads/writes on disk and everywhere else, so this file carries
    /// no hand-parsed duplicate of that shape. A missing/malformed target is a
    /// readable error naming the expected shape.
    private func parseAutomationTarget(_ value: JSONValue?) throws -> AutomationTarget {
        guard let value else {
            throw ControlError("missing or invalid required param 'target'")
        }
        do {
            return try JSONDecoder().decode(AutomationTarget.self, from: JSONEncoder().encode(value))
        } catch {
            throw ControlError(
                "'target' must be {type: \"volume\"|\"pan\"|\"sendLevel\"|\"effectParam\", "
                + "sendId?, effectId?, param?} — \(Self.decodingMessage(error))")
        }
    }

    /// Parses a `points` param into `[AutomationPoint]`, decoding each element
    /// through `AutomationPoint`'s OWN Codable (so `beat` clamps to >= 0 and an
    /// omitted `curve` defaults `"linear"` for free) with per-index errors
    /// naming the offending element — the clip-notes `parseNotes` precedent.
    /// The store applies the 4096-point cap and value clamping; this only
    /// shapes the array.
    private func parseAutomationPoints(_ value: JSONValue) throws -> [AutomationPoint] {
        guard let array = value.arrayValue else {
            throw ControlError("'points' must be an array of {beat, value, curve?}")
        }
        var points: [AutomationPoint] = []
        points.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            do {
                points.append(
                    try JSONDecoder().decode(AutomationPoint.self, from: JSONEncoder().encode(element)))
            } catch {
                throw ControlError(
                    "points[\(i)] must be {beat: number >= 0, value: number, "
                    + "curve?: \"linear\"|\"hold\"} — \(Self.decodingMessage(error))")
            }
        }
        return points
    }

    /// Parses an array-of-clip-id param into `[UUID]`, with a per-index error
    /// naming the offending element — the `parseNotes`/`parseAutomationPoints`
    /// precedent. Shared by `take.group` (`clipIds`) and `clip.removeMany` /
    /// `clip.moveMany` (`ids`, m23-w) — `field` names the parameter in both
    /// error messages (the `parseOptionalTrackIDs(_:field:)` precedent) and
    /// `requirement` is an appended clause on the "must be an array" message,
    /// so `take.group`'s wording stays BYTE-IDENTICAL through its defaults
    /// while `clip.removeMany`/`clip.moveMany` get their own honest text (no
    /// take-group minimum applies to them). Does not itself enforce any
    /// minimum count — `take.group`'s `cannotGroup` message owns the >= 2
    /// requirement so it stays a single source of truth; `clip.removeMany`/
    /// `clip.moveMany` have no minimum at all (an empty `ids` is a legal
    /// no-op, mirroring `ProjectStore.removeClips`/`moveClips`).
    /// One optional, RANGE-CHECKED numeric option for `clip.applyBreathContour`
    /// (m27 leg D). Fifteen of them share this rather than fifteen hand-written
    /// guards: the `what` clause carries the parameter's own meaning so the
    /// error still teaches, and one shape means one place for the bounds to be
    /// wrong.
    ///
    /// REFUSES rather than clamps. `BreathContour.Options.sanitized()` heals
    /// the same domains defensively, but healing at the wire would mean an
    /// agent that asked for a 40 Hz vibrato silently got 20 — the accept-and-
    /// discard shape this whole round exists to end.
    private func boundedOption(_ params: [String: JSONValue], _ key: String,
                               _ low: Double, _ high: Double,
                               _ fallback: Double, _ what: String) throws -> Double {
        guard let raw = params[key] else { return fallback }
        guard let value = raw.doubleValue, (low...high).contains(value) else {
            throw ControlError(
                "'\(key)' must be a number between \(low) and \(high) "
                + "(default \(fallback) — \(what))")
        }
        return value
    }

    /// The integer twin of `boundedOption`: rejects a fractional value outright
    /// rather than truncating it (the m23-aj-2 finding that the ordinary
    /// `Int(double)` path truncates silently).
    private func boundedIntOption(_ params: [String: JSONValue], _ key: String,
                                  _ low: Int, _ high: Int,
                                  _ fallback: Int, _ what: String) throws -> Int {
        guard let raw = params[key] else { return fallback }
        guard let value = raw.doubleValue, value == value.rounded(),
              (Double(low)...Double(high)).contains(value) else {
            throw ControlError(
                "'\(key)' must be a whole number between \(low) and \(high) "
                + "(default \(fallback) — \(what))")
        }
        return Int(value)
    }

    private func parseClipIDs(
        _ value: JSONValue?, field: String = "clipIds",
        requirement: String = " (at least 2, to form a take group)"
    ) throws -> [UUID] {
        guard let array = value?.arrayValue else {
            throw ControlError("'\(field)' must be an array of clip id strings\(requirement)")
        }
        var ids: [UUID] = []
        ids.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let raw = element.stringValue, let id = UUID(uuidString: raw) else {
                throw ControlError("\(field)[\(i)] is not a valid UUID")
            }
            ids.append(id)
        }
        return ids
    }

    /// An array of plain strings, refused element by element so the error names
    /// the index that is wrong rather than the whole array (breath pad P2's
    /// `ring`). Deliberately NOT `parseClipIDs` — these are catalog ids, not
    /// UUIDs, and validating them as UUIDs would reject every valid one.
    private func parseStringList(
        _ value: JSONValue?, field: String, requirement: String
    ) throws -> [String] {
        guard let array = value?.arrayValue else {
            throw ControlError("'\(field)' must be an array of strings\(requirement)")
        }
        var out: [String] = []
        out.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let raw = element.stringValue else {
                throw ControlError("\(field)[\(i)] is not a string\(requirement)")
            }
            out.append(raw)
        }
        return out
    }

    /// Shared JSON encoder for `ClipsTrackMoveResult` (m23-aj-2) — ONE
    /// function so `clip.moveManyByTracks` and `clip.moveManyToTrack` cannot
    /// diverge on key casing.
    ///
    /// `requestedTrackDelta`/`effectiveTrackDelta` are OMITTED entirely
    /// (never encoded as `null`) whenever the store's own result carries
    /// them as `nil` — which is always and only the `.toTrack` shape
    /// (`ProjectStore.moveClips(ids:toTrackId:byBeats:)` never sets them,
    /// design §6/§9.2): a synthesized `0` would be indistinguishable from
    /// "the clamp reduced the request to nothing", the one vertical fact a
    /// caller most needs to tell apart.
    ///
    /// `trimmedClipIDs`/`removedClipIDs` keep the capital "IDs" the live
    /// `clip.moveMany` response already emits (`Commands.swift` above) — a
    /// live key is never renamed. `landings` uses lower-case "Id"
    /// (`clipId`/`fromTrackId`/`toTrackId`) because that is the PARAMETER
    /// convention (`trackId`, `clipId`, `toTrackId`). The inconsistency is
    /// inherited and deliberate — design §9.3 says explicitly not to
    /// "fix" it.
    private static func clipsTrackMoveResultJSON(_ result: ClipsTrackMoveResult) throws -> JSONValue {
        var obj: [String: JSONValue] = [
            "clampedTracks": .bool(result.clampedTracks),
            "requestedDeltaBeats": .number(result.requestedDeltaBeats),
            "effectiveDeltaBeats": .number(result.effectiveDeltaBeats),
            "clamped": .bool(result.clamped),
            "landings": .array(result.landings.map { landing in
                .object([
                    "clipId": .string(landing.clipID.uuidString),
                    "fromTrackId": .string(landing.fromTrackID.uuidString),
                    "toTrackId": .string(landing.toTrackID.uuidString),
                ])
            }),
            "trimmedClipIDs": .array(result.trimmedClipIDs.map { .string($0.uuidString) }),
            "removedClipIDs": .array(result.removedClipIDs.map { .string($0.uuidString) }),
            "clips": try JSONValue(encoding: result.clips),
        ]
        if let requestedTrackDelta = result.requestedTrackDelta {
            obj["requestedTrackDelta"] = .number(Double(requestedTrackDelta))
        }
        if let effectiveTrackDelta = result.effectiveTrackDelta {
            obj["effectiveTrackDelta"] = .number(Double(effectiveTrackDelta))
        }
        return .object(obj)
    }

    /// Parses the optional `sections` param for `macro.songSkeleton` into
    /// `[SkeletonSection]?` — nil (omitted) tells the store to use the genre's
    /// default layout. Present-but-malformed is a per-index error naming the
    /// offending element (the `parseNotes` precedent). Only SHAPE is checked
    /// here (name is a string, bars is an integer); the store owns the range
    /// validation (count 1-16, name length, bars 1-64) as the single source of
    /// truth, surfacing field-named `invalidSongSkeleton` errors.
    private func parseSkeletonSections(_ value: JSONValue?) throws -> [SkeletonSection]? {
        guard let value else { return nil }
        guard let array = value.arrayValue else {
            throw ControlError("'sections' must be an array of {name: string, bars: integer}")
        }
        var sections: [SkeletonSection] = []
        sections.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let name = element["name"]?.stringValue else {
                throw ControlError("sections[\(i)].name must be a string")
            }
            guard let barsValue = element["bars"]?.doubleValue, Self.isInteger(barsValue) else {
                throw ControlError("sections[\(i)].bars must be an integer (number of bars)")
            }
            sections.append(SkeletonSection(name: name, bars: Int(barsValue)))
        }
        return sections
    }

    /// Parses the optional `tracks` param for `macro.songSkeleton` into
    /// `[SongSkeletonTrack]?` — nil (omitted) tells the store to use the genre's
    /// default roster. Present-but-malformed is a per-index error naming the
    /// offending element (the `parseSkeletonSections` precedent).
    ///
    /// Only SHAPE is checked here (name is a string, kind maps to a `TrackKind`,
    /// mixerPreset is a string when present); the store owns the CONTRACT (count
    /// 1-24, name length, instrument/audio only, the preset resolving) as the
    /// single source of truth, surfacing field-named `invalidSongSkeleton`
    /// errors. That split is why `"bus"` parses cleanly HERE and is rejected
    /// THERE: a caller who sends it gets the store's teaching error, the same
    /// one a direct `applySongSkeleton` caller gets, rather than two different
    /// wordings of the same rule.
    private func parseSkeletonTracks(_ value: JSONValue?) throws -> [SongSkeletonTrack]? {
        guard let value else { return nil }
        guard let array = value.arrayValue else {
            throw ControlError(
                "'tracks' must be an array of "
                + "{name: string, kind: \"instrument\"|\"audio\", mixerPreset?: string}")
        }
        var specs: [SongSkeletonTrack] = []
        specs.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let name = element["name"]?.stringValue else {
                throw ControlError("tracks[\(i)].name must be a string")
            }
            guard let rawKind = element["kind"]?.stringValue else {
                throw ControlError(
                    "tracks[\(i)].kind must be \"instrument\" or \"audio\"")
            }
            guard let kind = TrackKind(rawValue: rawKind) else {
                throw ControlError(
                    "tracks[\(i)].kind is not a track kind: '\(rawKind)' — "
                    + "skeletons take \"instrument\" or \"audio\"")
            }
            // Absent and explicit-null both mean "no preset" — an agent that
            // spells the empty case as `null` gets the same empty chain as one
            // that omits the key, rather than a type error on a value that
            // already says what it means.
            var preset: String?
            if let raw = element["mixerPreset"], raw != .null {
                guard let presetName = raw.stringValue else {
                    throw ControlError(
                        "tracks[\(i)].mixerPreset must be a mixer-preset name (string), "
                        + "or omitted for no preset")
                }
                preset = presetName
            }
            specs.append(SongSkeletonTrack(name: name, kind: kind, mixerPreset: preset))
        }
        return specs
    }

    /// Parses the optional `trackIds` param (`render.stems`) into `[UUID]?` —
    /// absent → nil ("every master input"); present validates each element
    /// with a per-index error naming the offending element (the `parseClipIDs`
    /// precedent). A present-but-empty array passes through as `Optional([])`
    /// (distinct from nil): the store's `StemPlan.descriptors` then selects
    /// zero stems and `renderStems` surfaces `nothingToRender`, the same
    /// single source of truth as a project with no clips.
    /// `field` names the parameter in both error messages, defaulted so
    /// `render.stems`' pinned wording is byte-identical; `render.bounce` /
    /// `render.mixdown` pass "excludeTrackIds" (m23-m1) so a bad element names
    /// the field the caller actually sent, never `trackIds`.
    private func parseOptionalTrackIDs(_ value: JSONValue?,
                                       field: String = "trackIds") throws -> [UUID]? {
        guard let value else { return nil }
        guard let array = value.arrayValue else {
            throw ControlError("'\(field)' must be an array of track id strings")
        }
        var ids: [UUID] = []
        ids.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let raw = element.stringValue, let id = UUID(uuidString: raw) else {
                throw ControlError("\(field)[\(i)] is not a valid UUID")
            }
            ids.append(id)
        }
        return ids
    }

    /// Parses the optional `bitDepth` / `container` output-format params
    /// (m23-m2), shared by `render.bounce` / `render.mixdown` / `render.stems`
    /// so the three verbs can never diverge on what they accept.
    ///
    /// Only TYPE and presence are checked here; the VALUE contract (16/24/32,
    /// wav/aiff) lives in `DeliveryFormat.resolve` — one home, so the store
    /// API the export UI will drive rejects exactly what the wire rejects
    /// instead of silently ignoring it. A present-but-wrong-typed value is
    /// rejected BY NAME rather than parsed to nil: silently falling back to
    /// Float32 WAV after being asked for 24-bit AIFF is the very defect class
    /// this item closes.
    private func parseOutputFormat(_ params: [String: JSONValue])
        throws -> (bitDepth: Int?, container: String?) {
        var bitDepth: Int?
        if let raw = params["bitDepth"] {
            guard let number = raw.doubleValue, number == number.rounded() else {
                throw ControlError("'bitDepth' must be an integer — 16, 24 or 32")
            }
            bitDepth = Int(number)
        }
        var container: String?
        if let raw = params["container"] {
            guard let text = raw.stringValue else {
                throw ControlError("'container' must be a string — 'wav' or 'aiff'")
            }
            container = text
        }
        return (bitDepth, container)
    }

    /// Parses the required `trackNames` param (`ai.extractStems`) into
    /// `[String]` — a per-index error naming the offending element (the
    /// `parseClipIDs` precedent). Upstream's own fixed vocabulary
    /// (`TRACK_NAMES` in `acestep/constants.py`) is NOT re-validated here —
    /// the sidecar is authoritative and rejects an unknown name with its
    /// own error, which surfaces verbatim.
    /// Parses the optional `structure` param (`ai.writeLyrics`) into a non-empty
    /// list of section tags — a non-empty array of non-empty strings, with a
    /// per-index error naming the offending element (the `parseTrackNames`
    /// precedent).
    private func parseLyricsStructure(_ value: JSONValue) throws -> [String] {
        guard let array = value.arrayValue, !array.isEmpty else {
            throw ControlError(
                "'structure' must be a non-empty array of section tags, e.g. [\"verse\", \"chorus\"]")
        }
        var tags: [String] = []
        tags.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let tag = element.stringValue, !tag.isEmpty else {
                throw ControlError("structure[\(i)] must be a non-empty string")
            }
            tags.append(tag)
        }
        return tags
    }

    /// Parses the optional `context` param (`ai.writeLyrics`) into a
    /// `LyricsWriteContext`, DEFAULTING each unset field from the current project:
    /// `tempoBPM` / `timeSignature` come from the transport when the caller omits
    /// them, so a bare call still fits the session. An explicitly provided value
    /// always wins; a wrong TYPE is a field-named error. `keyScale`/`genre` have
    /// no project source, so they stay nil unless provided.
    private func parseLyricsContext(_ value: JSONValue?) throws -> LyricsWriteContext {
        // A present `context` must be an object.
        if let value, value.objectValue == nil, value != .null {
            throw ControlError("'context' must be an object {keyScale?, tempoBPM?, timeSignature?, genre?}")
        }
        let object = value?.objectValue
        var context = LyricsWriteContext()

        if let keyScaleValue = object?["keyScale"] {
            guard let keyScale = keyScaleValue.stringValue else {
                throw ControlError("'context.keyScale' must be a string")
            }
            context.keyScale = keyScale
        }
        if let genreValue = object?["genre"] {
            guard let genre = genreValue.stringValue else {
                throw ControlError("'context.genre' must be a string")
            }
            context.genre = genre
        }
        if let tempoValue = object?["tempoBPM"] {
            guard let tempo = tempoValue.doubleValue else {
                throw ControlError("'context.tempoBPM' must be a number")
            }
            context.tempoBPM = tempo
        } else {
            context.tempoBPM = store.transport.tempoBPM
        }
        if let sigValue = object?["timeSignature"] {
            guard let sig = sigValue.stringValue else {
                throw ControlError("'context.timeSignature' must be a string")
            }
            context.timeSignature = sig
        } else {
            let sig = store.transport.timeSignature
            context.timeSignature = "\(sig.beatsPerBar)/\(sig.beatUnit)"
        }
        return context
    }

    /// Resolves the required `sourcePath` param (`ai.repaintAudio`) with a
    /// field-named error, and — unlike `ai.extractStems`/`ai.legoGenerate`'s
    /// `sourceAudioPath` (whose existence is only proven when the REAL
    /// client stages it) — checks the file actually exists ON THIS MACHINE
    /// before submitting: repaint is a single job with no per-track fallback,
    /// so failing fast here beats a round trip to the sidecar for a typo'd path.
    private func parseRepaintSourcePath(_ value: JSONValue?) throws -> String {
        guard let path = value?.stringValue, !path.isEmpty else {
            throw ControlError("missing or invalid required param 'sourcePath'")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw ControlError("'sourcePath' does not exist: \(path)")
        }
        return path
    }

    /// Resolves the optional `mode` param (`ai.repaintAudio`) to a
    /// `RepaintMode`; a present-but-invalid string names the valid values
    /// verbatim (the `parseEffectKind` precedent).
    private func parseRepaintMode(_ value: JSONValue) throws -> RepaintMode {
        guard let raw = value.stringValue else {
            throw ControlError("'mode' must be a string")
        }
        guard let mode = RepaintMode(rawValue: raw) else {
            let valid = RepaintMode.allCases.map(\.rawValue).joined(separator: "|")
            throw ControlError("unknown repaint mode '\(raw)' — use \(valid)")
        }
        return mode
    }

    /// Resolves the optional `mode` param (`ai.fixClipRegion`) to a DAWCore
    /// `ClipFixMode`; a present-but-invalid string names the valid values
    /// verbatim (the `parseRepaintMode` precedent). Distinct from
    /// `parseRepaintMode` — that one produces the AIServices `RepaintMode`; the
    /// clip-fix flow speaks the DAWCore type (the store owns the AI hop).
    private func parseClipFixMode(_ value: JSONValue) throws -> ClipFixMode {
        guard let raw = value.stringValue else {
            throw ControlError("'mode' must be a string")
        }
        guard let mode = ClipFixMode(rawValue: raw) else {
            let valid = ClipFixMode.allCases.map(\.rawValue).joined(separator: "|")
            throw ControlError("unknown clip-fix mode '\(raw)' — use \(valid)")
        }
        return mode
    }

    private func parseTrackNames(_ value: JSONValue?) throws -> [String] {
        guard let array = value?.arrayValue, !array.isEmpty else {
            throw ControlError(
                "'trackNames' must be a non-empty array of stem names, e.g. [\"vocals\", \"drums\"]")
        }
        var names: [String] = []
        names.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let name = element.stringValue, !name.isEmpty else {
                throw ControlError("trackNames[\(i)] must be a non-empty string")
            }
            names.append(name)
        }
        return names
    }

    /// Parses the required `tracks` param (`ai.legoGenerate`) into
    /// `[StemTrackRequest]` — each element `{trackName (required), prompt
    /// (optional — that track's own local description)}`, with a per-index
    /// error naming the offending element (the `parseClipIDs` precedent).
    private func parseLegoTracks(_ value: JSONValue?) throws -> [StemTrackRequest] {
        guard let array = value?.arrayValue, !array.isEmpty else {
            throw ControlError(
                "'tracks' must be a non-empty array of {trackName, prompt?}, e.g. [{\"trackName\": \"bass\"}]")
        }
        var tracks: [StemTrackRequest] = []
        tracks.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let object = element.objectValue,
                  let name = object["trackName"]?.stringValue, !name.isEmpty
            else {
                throw ControlError("tracks[\(i)].trackName must be a non-empty string")
            }
            tracks.append(StemTrackRequest(trackName: name, localPrompt: object["prompt"]?.stringValue))
        }
        return tracks
    }

    /// Parses a `segments` param into `[CompSegment]`, decoding each element
    /// through `CompSegment`'s OWN Codable (so the wire shape `{laneId,
    /// startBeat, endBeat}` never drifts from persistence) with a per-index
    /// error naming the offending element — the `parseAutomationPoints`
    /// precedent. Shared by `take.setComp`. Ordering/overlap/range validation
    /// stays in the store (the single source of truth for those rules).
    private func parseCompSegments(_ value: JSONValue?) throws -> [CompSegment] {
        guard let array = value?.arrayValue else {
            throw ControlError("'segments' must be an array of {laneId, startBeat, endBeat}")
        }
        var segments: [CompSegment] = []
        segments.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            do {
                segments.append(
                    try JSONDecoder().decode(CompSegment.self, from: JSONEncoder().encode(element)))
            } catch {
                throw ControlError(
                    "segments[\(i)] must be {laneId: uuid, startBeat: number, "
                    + "endBeat: number > startBeat} — \(Self.decodingMessage(error))")
            }
        }
        return segments
    }

    /// Shared result shape for the take.* commands that report a group
    /// alongside its CURRENT member clips (`{group, clips}` — take.setComp,
    /// take.select, take.move, take.setCrossfade): `track.clips` filtered by
    /// `takeGroupID`, in track order. Members churn ids on every comp rebuild
    /// (spec §2 ASSUMPTION), so this always reflects the freshly rebuilt set.
    private func memberClipsJSON(trackID: UUID, groupID: UUID) throws -> JSONValue {
        let members = store.tracks.first(where: { $0.id == trackID })?
            .clips.filter { $0.takeGroupID == groupID } ?? []
        return try JSONValue(encoding: members)
    }

    /// Renders a `DecodingError` as a short, actionable phrase (its
    /// `debugDescription`, or the missing key's name) instead of Swift's
    /// generic localized text — shared by the automation target/point parsers.
    private static func decodingMessage(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        switch decodingError {
        case .keyNotFound(let key, let context):
            let detail = context.debugDescription
            return "missing '\(key.stringValue)'\(detail.isEmpty ? "" : " (\(detail))")"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    /// Resolves an optional `kind` param to `InstrumentDescriptor.Kind`. Absent →
    /// nil (keep the current value); a present-but-invalid string names the valid
    /// values verbatim, matching the "must be one of …" pattern.
    private func parseInstrumentKind(_ value: JSONValue?) throws -> InstrumentDescriptor.Kind? {
        guard let raw = value?.stringValue else { return nil }
        guard let kind = InstrumentDescriptor.Kind(rawValue: raw) else {
            let valid = InstrumentDescriptor.Kind.allCases.map(\.rawValue).joined(separator: "|")
            throw ControlError("kind must be one of \(valid)")
        }
        return kind
    }

    /// Resolves an optional `waveform` param to `PolySynthParams.Waveform`. Absent
    /// → nil (keep the current value); a present-but-invalid string names the
    /// valid values verbatim.
    private func parseWaveform(_ value: JSONValue?) throws -> PolySynthParams.Waveform? {
        guard let raw = value?.stringValue else { return nil }
        guard let waveform = PolySynthParams.Waveform(rawValue: raw) else {
            let valid = PolySynthParams.Waveform.allCases.map(\.rawValue).joined(separator: "|")
            throw ControlError("waveform must be one of \(valid)")
        }
        return waveform
    }

    /// Resolves an optional clip fade-curve param (`fadeInCurve`/`fadeOutCurve`,
    /// "linear"|"equalPower") to `FadeCurve`. Absent → `.linear` (the model
    /// default). A present-but-invalid string names the OFFENDING FIELD (not
    /// just "curve") since `clip.setFades` takes two independently — an agent
    /// passing a bad `fadeOutCurve` shouldn't have to guess which one broke.
    private func parseFadeCurve(_ value: JSONValue?, field: String) throws -> FadeCurve {
        guard let raw = value?.stringValue else { return .linear }
        guard let curve = FadeCurve(rawValue: raw) else {
            let valid = FadeCurve.allCases.map(\.rawValue).joined(separator: "|")
            throw ControlError("'\(field)' must be one of \(valid)")
        }
        return curve
    }

    /// Builds a `QuantizeSettings` from the `clip.quantize` params with
    /// field-named range validation (the parseFadeCurve style): `gridBeats`
    /// (required, > 0), `strength` (optional, 0...1, default 1), `swing`
    /// (optional, 50...75, default 50 — the wire name for `swingPercent`),
    /// `quantizeEnds` (optional bool, default false). Shared shape iii-f's audio
    /// quantize and iii-g's groove ref (resolved to `settings.groove`) extend.
    ///
    /// DUAL-ERROR FIX (m16-e, audit F8b): every field is validated and every
    /// problem COLLECTED — not just the first `guard` hit — so a call broken in
    /// two ways (the audit's measured case: no `gridBeats` + an unknown `groove`
    /// name) reports BOTH in one round trip instead of costing the caller a
    /// second one to discover the groove typo after fixing gridBeats. A single
    /// problem still throws its own plain message (every existing single-error
    /// test keeps matching); 2+ problems join into one numbered message via
    /// `combinedFieldProblems`.
    private func parseQuantizeSettings(_ params: [String: JSONValue]) throws -> QuantizeSettings {
        var problems: [String] = []

        var gridBeats = 0.0
        if let raw = params["gridBeats"]?.doubleValue {
            if raw > 0 {
                gridBeats = raw
            } else {
                problems.append("'gridBeats' must be greater than 0 (beats: 1 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16)")
            }
        } else {
            problems.append("missing or invalid required param 'gridBeats'")
        }

        let strength = params["strength"]?.doubleValue ?? 1
        if !(0...1).contains(strength) {
            problems.append("'strength' must be between 0 and 1 (1 = snap fully, 0.5 = halfway, 0 = leave notes)")
        }

        let swing = params["swing"]?.doubleValue ?? 50
        if !(50...75).contains(swing) {
            problems.append("'swing' must be between 50 and 75 (50 = straight, 75 = max MPC shuffle)")
        }

        let quantizeEnds = params["quantizeEnds"]?.boolValue ?? false
        var groove: GrooveTemplate?
        do {
            groove = try resolveGrooveParam(params["groove"])
        } catch let error as ControlError {
            problems.append(error.message)
        }

        guard problems.isEmpty else {
            throw combinedFieldProblems(problems, verb: "clip.quantize")
        }
        return QuantizeSettings(gridBeats: gridBeats, strength: strength,
                                swingPercent: swing, quantizeEnds: quantizeEnds,
                                groove: groove)
    }

    /// Joins 2+ field-validation problems into ONE teaching error (m16-e, audit
    /// F8b) instead of surfacing only the first — a compound mistake (e.g. a
    /// missing required param AND an unknown enum value elsewhere in the same
    /// call) otherwise costs the caller one round trip per problem. A single
    /// problem is returned VERBATIM (unchanged from the pre-m16-e single-`guard`
    /// wording) so every existing single-error test keeps matching exactly.
    private func combinedFieldProblems(_ problems: [String], verb: String) -> ControlError {
        guard problems.count > 1 else {
            return ControlError(problems.first ?? "\(verb): invalid parameters")
        }
        let numbered = problems.enumerated()
            .map { "(\($0.offset + 1)) \($0.element)" }
            .joined(separator: "; ")
        return ControlError("\(verb): \(problems.count) problems — \(numbered)")
    }

    /// Resolves the optional `groove` param (M5 iii-g) — a reserved built-in
    /// swing name (`"swing8:66"`), a stored template id, or a stored template
    /// name — to a `GrooveTemplate` via `store.resolveGroove`. Absent → nil (the
    /// straight/swing grid). A present-but-unknown ref names the OFFENDING FIELD
    /// (the parseFadeCurve style) so an agent knows exactly which param broke.
    /// The resolved groove travels BY VALUE on the settings, so it keeps working
    /// even if the template is later deleted.
    private func resolveGrooveParam(_ value: JSONValue?) throws -> GrooveTemplate? {
        guard let raw = value?.stringValue else { return nil }
        guard let groove = store.resolveGroove(raw) else {
            throw ControlError(
                "'groove' is not a known groove — pass a saved template id/name (see groove.list) "
                + "or a built-in swing (\(GrooveTemplate.builtinNames.joined(separator: "|")))")
        }
        return groove
    }

    /// Builds an `AudioQuantizeSettings` from the `clip.quantizeAudio` params
    /// (M5 iii-f), reusing the shared `gridBeats`/`strength`/`swing` validation
    /// shape and adding `sensitivity` (0...1, default 0.5) and `crossfadeMs`
    /// (0...50 ms, default 10 — the model clamps to 0...0.05 s). `groove?` is the
    /// iii-g seam. Same dual-error collection as `parseQuantizeSettings` (m16-e,
    /// audit F8b) — every field validates independently and every problem is
    /// reported together via `combinedFieldProblems`.
    private func parseAudioQuantizeSettings(_ params: [String: JSONValue]) throws -> AudioQuantizeSettings {
        var problems: [String] = []

        var gridBeats = 0.0
        if let raw = params["gridBeats"]?.doubleValue {
            if raw > 0 {
                gridBeats = raw
            } else {
                problems.append("'gridBeats' must be greater than 0 (beats: 1 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16)")
            }
        } else {
            problems.append("missing or invalid required param 'gridBeats'")
        }

        let strength = params["strength"]?.doubleValue ?? 1
        if !(0...1).contains(strength) {
            problems.append("'strength' must be between 0 and 1 (1 = snap fully, 0.5 = halfway, 0 = leave slices)")
        }

        let swing = params["swing"]?.doubleValue ?? 50
        if !(50...75).contains(swing) {
            problems.append("'swing' must be between 50 and 75 (50 = straight, 75 = max MPC shuffle)")
        }

        let sensitivity = params["sensitivity"]?.doubleValue ?? 0.5
        if !(0...1).contains(sensitivity) {
            problems.append("'sensitivity' must be between 0 and 1 (0.5 = default; higher finds more onsets)")
        }

        let crossfadeMs = params["crossfadeMs"]?.doubleValue ?? 10
        if !(0...50).contains(crossfadeMs) {
            problems.append("'crossfadeMs' must be between 0 and 50 (default 10 — join crossfade width in milliseconds)")
        }

        var groove: GrooveTemplate?
        do {
            groove = try resolveGrooveParam(params["groove"])
        } catch let error as ControlError {
            problems.append(error.message)
        }

        guard problems.isEmpty else {
            throw combinedFieldProblems(problems, verb: "clip.quantizeAudio")
        }
        return AudioQuantizeSettings(
            gridBeats: gridBeats, strength: strength, swingPercent: swing,
            groove: groove, sensitivity: sensitivity,
            crossfadeSeconds: crossfadeMs / 1000.0)
    }

    /// Parses an optional `sampler` object into a `SamplerParams` — a WHOLESALE
    /// replacement (absent → nil, keep the current config). Every top-level field
    /// and every zone field except `path` is optional (the model defaults fill
    /// in); values clamp silently through the model inits (like track.setVolume).
    /// Errors are field-path'd in the notes[i] style, e.g.
    /// `sampler.zones[0].path is required`. `path` expands a leading `~`. Zone
    /// files are validated (existence + readability) later, in the store.
    /// m19-a selection fields ride along per zone (minVelocity/maxVelocity/
    /// group/seqLength/seqPosition/randMin/randMax) — all optional; omitted =
    /// nil = the pre-m19 pitch-only first-match behavior.
    /// m19-b playback scalars ride along the same way (tuneCents/pan/
    /// ampVelTrack/oneShot/startFrame/endFrame/attack/decay/sustain/release);
    /// omitted = nil = the pre-m19-b playback law. Zone `gain` now reaches
    /// 2.0 (+6 dB, amendment A5); range clamping stays the model init's job.
    /// m20-g loop fields ride along too (loopMode "sustain"/"continuous",
    /// loopStart/loopEnd source frames, end exclusive); omitted = nil = no
    /// loop. loopMode wins over oneShot on a looping zone (engine law).
    ///
    /// PARTIAL, against `current` (the track's existing sampler config, nil on a
    /// track that has none): every key the caller omits keeps the value it
    /// already had, `zones` INCLUDED. This is the m26 fix for field-report
    /// finding 12 — the sampler object used to be the one carve-out from
    /// `track.setInstrument`'s own "omitted fields keep their current value"
    /// contract, and because the store swaps the sampler wholesale, an omitted
    /// `zones` key silently deleted every zone of an imported library. Tuning
    /// `release` on a 309-zone upright bass emptied it, with no error and no
    /// way to notice except silence. Note the asymmetry that remains and is
    /// deliberate: a PRESENT `zones` array still REPLACES the zone list rather
    /// than merging into it, because a wire zone carries no id the parser
    /// honours (ids are emitted in snapshots but re-minted on every set), so
    /// there is nothing to merge BY. Zone-level patching is m26-g.
    /// Every per-zone field a `sampler.zones[i]` object may carry, PARSED but
    /// not yet resolved: nil means the caller did not mention the key. One
    /// parse, shared by the wholesale `zones` path and (m26-g) the merge-by-id
    /// `zonePatches` path, so a new zone field is added in exactly one place
    /// and the two paths cannot drift apart.
    ///
    /// Resolution differs between the two and only there: `zones` resolves an
    /// absent key to the MODEL DEFAULT (a fresh zone), `zonePatches` resolves
    /// it to the zone's CURRENT value (a partial edit).
    private struct ParsedZoneFields {
        var path: String?
        var rootPitch: Int?
        var minPitch: Int?
        var maxPitch: Int?
        var gain: Double?
        var minVelocity: Int?
        var maxVelocity: Int?
        var group: Int?
        var seqLength: Int?
        var seqPosition: Int?
        var randMin: Double?
        var randMax: Double?
        var tuneCents: Double?
        var pan: Double?
        var ampVelTrack: Double?
        var oneShot: Bool?
        var startFrame: Int?
        var endFrame: Int?
        var attack: Double?
        var decay: Double?
        var sustain: Double?
        var release: Double?
        var loopMode: SamplerLoopMode?
        var loopStart: Int?
        var loopEnd: Int?
        var crossfade: SamplerCrossfade?
    }

    /// Parses one zone object's fields. `label` is the wire path prefix
    /// ("sampler.zones[0]" / "sampler.zonePatches[0]") so every error names the
    /// key the caller actually sent. `id` and `path` requiredness are the
    /// CALLER's business — they differ between the two zone paths.
    /// The ONE place a sampler zone's `path` string is turned into a real
    /// filesystem path — called by BOTH the wholesale `zones` branch and the
    /// `zonePatches` merge branch, so the two can never drift on what a path
    /// means.
    ///
    /// Two accepted forms, the `SoundBankSource` `"gm"` idiom applied to sample
    /// content (m30-a): a real path (tilde-expanded, as it always was), or
    /// `builtin:<name>` naming a sample the app SHIPS — which is the only way
    /// to make the Sampler produce a sound on a machine that has no sample
    /// library, and therefore the only way to smoke-test it out of the box.
    /// No real path has ever begun with `builtin:`, so this is purely additive
    /// and no existing caller can change meaning.
    ///
    /// ⚠️ An unresolvable `builtin:` name FAILS LOUD, and that is the whole
    /// design of this branch. Falling through to
    /// `URL(fileURLWithPath: "builtin:nope")` would store a nonsense path, the
    /// verb would answer SUCCESS, and the track would simply be silent — this
    /// tree's characteristic failure mode (three of M27's four blockers
    /// returned something that looked like a valid answer). It is also what a
    /// packaged .app would hit today, since scripts/bundle.sh does not yet copy
    /// `daw-pro_DAWCore.bundle` (see `BundledSamples.url(for:)`).
    static func resolveZonePath(_ raw: String, label: String) throws -> String {
        guard BundledSamples.isBundledName(raw) else {
            return (raw as NSString).expandingTildeInPath
        }
        do {
            return try BundledSamples.resolve(raw).path
        } catch {
            throw ControlError(
                "\(label): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }

    private static func parseZoneFields(
        _ zone: [String: JSONValue], _ label: String
    ) throws -> ParsedZoneFields {
        var f = ParsedZoneFields()
        // Resolved here so both zone paths agree on what a `path` means — a
        // tilde expands, and a `builtin:` catalog name becomes the shipped
        // file's absolute path (m30-a). The wholesale path re-checks
        // requiredness itself (and does so BEFORE this call, to keep its
        // "path is required" error ahead of every field-type error, as it has
        // always been).
        f.path = try zone["path"]?.stringValue.map {
            try resolveZonePath($0, label: "\(label).path")
        }
        f.rootPitch = try optionalPitch(zone["rootPitch"], "\(label).rootPitch")
        f.minPitch = try optionalPitch(zone["minPitch"], "\(label).minPitch")
        f.maxPitch = try optionalPitch(zone["maxPitch"], "\(label).maxPitch")
        f.gain = try optionalNumber(zone["gain"], "\(label).gain")
        f.minVelocity = try optionalPitch(zone["minVelocity"], "\(label).minVelocity")
        f.maxVelocity = try optionalPitch(zone["maxVelocity"], "\(label).maxVelocity")
        f.group = try optionalInteger(zone["group"], "\(label).group")
        f.seqLength = try optionalInteger(zone["seqLength"], "\(label).seqLength")
        f.seqPosition = try optionalInteger(zone["seqPosition"], "\(label).seqPosition")
        f.randMin = try optionalNumber(zone["randMin"], "\(label).randMin")
        f.randMax = try optionalNumber(zone["randMax"], "\(label).randMax")
        f.tuneCents = try optionalNumber(zone["tuneCents"], "\(label).tuneCents")
        f.pan = try optionalNumber(zone["pan"], "\(label).pan")
        f.ampVelTrack = try optionalNumber(zone["ampVelTrack"], "\(label).ampVelTrack")
        f.oneShot = try optionalBool(zone["oneShot"], "\(label).oneShot")
        f.startFrame = try optionalInteger(zone["startFrame"], "\(label).startFrame")
        f.endFrame = try optionalInteger(zone["endFrame"], "\(label).endFrame")
        f.attack = try optionalNumber(zone["attack"], "\(label).attack")
        f.decay = try optionalNumber(zone["decay"], "\(label).decay")
        f.sustain = try optionalNumber(zone["sustain"], "\(label).sustain")
        f.release = try optionalNumber(zone["release"], "\(label).release")
        if let loopModeValue = zone["loopMode"] {
            guard let raw = loopModeValue.stringValue,
                  let mode = SamplerLoopMode(rawValue: raw) else {
                throw ControlError(
                    "\(label).loopMode must be \"sustain\" or \"continuous\"")
            }
            f.loopMode = mode
        }
        f.loopStart = try optionalInteger(zone["loopStart"], "\(label).loopStart")
        f.loopEnd = try optionalInteger(zone["loopEnd"], "\(label).loopEnd")
        f.crossfade = try parseCrossfade(zone["crossfade"], "\(label).crossfade")
        return f
    }

    /// Resolves a zone's identity (m26-g). ABSENT → a fresh id, which is how a
    /// caller authors a brand-new zone map without knowing any ids. PRESENT →
    /// the id is honoured, but only if it is well-formed AND already names a
    /// zone on this track; anything else is a teaching error naming the field
    /// and the offending value, never a silent insert and never a silent
    /// re-mint.
    ///
    /// `seen` rejects the SAME id twice in one call. That is not pedantry: the
    /// project document keys its per-zone media references by zone id
    /// (`SamplerDocument.init(from:mediaRefs:)`), so two zones sharing an id
    /// would collide there and one sample file would silently stand in for
    /// both on the next save.
    /// What a zone id that names no zone on THIS track means, which differs by
    /// path because the two paths ask different questions of it.
    ///
    /// ⭐ ORCHESTRATOR RULING 2026-08-17, overriding the brief this landed
    /// under. The implementing agent applied `.reject` to BOTH paths and
    /// flagged the consequence honestly: an agent could previously read track
    /// A's zones from a snapshot and send them to track B, which SUCCEEDED
    /// (ids were silently re-minted), and under a blanket reject that call
    /// starts erroring. That is a live behaviour change on a shipped verb,
    /// against this repo's additive-only wire rule.
    ///
    /// **The tell is where the hazard comes from.** Honouring ids at all is
    /// what makes a cross-track copy dangerous — zone ids must be globally
    /// unique because `ProjectDocument` keys every zone's sample-file
    /// reference out of ONE project-wide `mediaRefs` dictionary by zone id
    /// (`ProjectDocument.swift:893`), so two tracks holding the same zone id
    /// would make one sample file stand in for both at save time. The old
    /// re-mint was SAFE. A blanket reject therefore charges existing callers
    /// for a hazard this feature introduced.
    ///
    /// So: `.mintUnknown` on the REPLACE path (`zones`) — an id we recognise
    /// is honoured, which is the whole point of m26-g, and anything else gets
    /// a fresh id exactly as it did before this item, with the substitution
    /// REPORTED rather than silent. `.reject` on the MERGE path
    /// (`zonePatches`) — a patch that names no zone has nothing to merge into,
    /// minting there would silently convert an edit into an insert, and the
    /// key is new so no caller can be relying on it.
    private enum UnknownZoneID {
        case mintUnknown
        case reject
    }

    private static func parseZoneID(_ value: JSONValue?, label: String,
                                    known: [SamplerZone],
                                    onUnknown: UnknownZoneID,
                                    seen: inout Set<UUID>,
                                    reminted: inout [String]) throws -> UUID {
        guard let value else { return UUID() }
        guard let raw = value.stringValue else {
            throw ControlError(
                "\(label).id must be a UUID string — the value project.snapshot emits as "
                    + "this zone's 'id'. Omit 'id' entirely to create a NEW zone.")
        }
        guard let id = UUID(uuidString: raw) else {
            throw ControlError(
                "\(label).id is not a valid UUID: \"\(raw)\". Send the id project.snapshot "
                    + "emitted for this zone, or omit 'id' to create a NEW zone.")
        }
        guard known.contains(where: { $0.id == id }) else {
            switch onUnknown {
            case .reject:
                throw ControlError(
                    "\(label).id \"\(raw)\" names no zone on this track. Ids are per-track: omit "
                        + "'id' on every zone to author a new map or to copy one onto a DIFFERENT "
                        + "track, or re-read the current ids from project.snapshot's "
                        + "instrument.sampler.zones[].id.")
            case .mintUnknown:
                // Pre-m26-g behaviour, preserved deliberately: this is the call
                // shape that copies one track's map onto another, and it used
                // to work. `remintedZoneIDs` in the reply is what keeps it from
                // being SILENT — a caller that believed it was preserving ids
                // is told, by id, that it was not.
                reminted.append(raw)
                return UUID()
            }
        }
        guard seen.insert(id).inserted else {
            throw ControlError(
                "\(label).id \"\(raw)\" appears more than once in this call. Zone ids are "
                    + "unique — the project file keys each zone's sample-file reference by id, "
                    + "so duplicates would make two zones share one sample. Omit 'id' on the "
                    + "copy to make it a new zone.")
        }
        return id
    }

    /// A PARTIAL edit of an existing zone (m26-g `zonePatches`): every field
    /// the patch does not mention keeps the zone's current value — including
    /// its NIL-ness, since an absent `pan` is not the same thing as an explicit
    /// 0 (see `SamplerZone.pan`).
    ///
    /// The merged zone goes back through `SamplerZone.init`, so it clamps and
    /// swaps under exactly the same law as the wholesale path: patching
    /// `maxPitch` below the zone's current `minPitch` SWAPS the span rather
    /// than collapsing it, and an `endFrame` at or below `startFrame` RAISES
    /// rather than swapping. Deliberate — a patch must not be able to reach a
    /// state the wholesale path cannot.
    ///
    /// Known limit, stated so it is not rediscovered as a bug: a patch cannot
    /// CLEAR an optional field back to nil, because an omitted key already
    /// means "keep". Send the whole map as `zones` for that.
    private static func merge(_ f: ParsedZoneFields, into base: SamplerZone) -> SamplerZone {
        SamplerZone(
            id: base.id,
            audioFileURL: f.path.map { URL(fileURLWithPath: $0) } ?? base.audioFileURL,
            rootPitch: f.rootPitch ?? base.rootPitch,
            minPitch: f.minPitch ?? base.minPitch,
            maxPitch: f.maxPitch ?? base.maxPitch,
            gain: f.gain ?? base.gain,
            minVelocity: f.minVelocity ?? base.minVelocity,
            maxVelocity: f.maxVelocity ?? base.maxVelocity,
            group: f.group ?? base.group,
            seqLength: f.seqLength ?? base.seqLength,
            seqPosition: f.seqPosition ?? base.seqPosition,
            randMin: f.randMin ?? base.randMin,
            randMax: f.randMax ?? base.randMax,
            tuneCents: f.tuneCents ?? base.tuneCents,
            pan: f.pan ?? base.pan,
            ampVelTrack: f.ampVelTrack ?? base.ampVelTrack,
            oneShot: f.oneShot ?? base.oneShot,
            startFrame: f.startFrame ?? base.startFrame,
            endFrame: f.endFrame ?? base.endFrame,
            attack: f.attack ?? base.attack,
            decay: f.decay ?? base.decay,
            sustain: f.sustain ?? base.sustain,
            release: f.release ?? base.release,
            loopMode: f.loopMode ?? base.loopMode,
            loopStart: f.loopStart ?? base.loopStart,
            loopEnd: f.loopEnd ?? base.loopEnd,
            crossfade: f.crossfade ?? base.crossfade)
    }

    /// A brand-new zone: every unmentioned field resolves to the MODEL DEFAULT.
    /// The four literals here (60/0/127/1) are the wire's documented defaults
    /// and predate m26-g — they are reproduced, not re-decided.
    private static func makeZone(_ f: ParsedZoneFields, id: UUID, path: String) -> SamplerZone {
        SamplerZone(
            id: id,
            audioFileURL: URL(fileURLWithPath: path),
            rootPitch: f.rootPitch ?? 60,
            minPitch: f.minPitch ?? 0,
            maxPitch: f.maxPitch ?? 127,
            gain: f.gain ?? 1,
            minVelocity: f.minVelocity,
            maxVelocity: f.maxVelocity,
            group: f.group,
            seqLength: f.seqLength,
            seqPosition: f.seqPosition,
            randMin: f.randMin,
            randMax: f.randMax,
            tuneCents: f.tuneCents,
            pan: f.pan,
            ampVelTrack: f.ampVelTrack,
            oneShot: f.oneShot,
            startFrame: f.startFrame,
            endFrame: f.endFrame,
            attack: f.attack,
            decay: f.decay,
            sustain: f.sustain,
            release: f.release,
            loopMode: f.loopMode,
            loopStart: f.loopStart,
            loopEnd: f.loopEnd,
            crossfade: f.crossfade)
    }

    /// Parses a zone's optional `crossfade` object (m27 leg B). Absent → nil.
    /// Present-but-not-an-object, or a non-integer member, is a field-path
    /// error naming the offender — the `parseZoneFields` convention. Ranges
    /// are left to the model's clamping init. An object whose members are all
    /// absent resolves to nil through `SamplerCrossfade.isNoOp`, so an empty
    /// `{}` is a no-op rather than an inert stored object.
    private static func parseCrossfade(_ value: JSONValue?,
                                       _ label: String) throws -> SamplerCrossfade? {
        guard let value else { return nil }
        guard case .object(let obj) = value else {
            throw ControlError("\(label) must be an object")
        }
        return SamplerCrossfade(
            controller: try optionalInteger(obj["controller"], "\(label).controller"),
            ccInLo: try optionalInteger(obj["ccInLo"], "\(label).ccInLo"),
            ccInHi: try optionalInteger(obj["ccInHi"], "\(label).ccInHi"),
            ccOutLo: try optionalInteger(obj["ccOutLo"], "\(label).ccOutLo"),
            ccOutHi: try optionalInteger(obj["ccOutHi"], "\(label).ccOutHi"),
            velInLo: try optionalInteger(obj["velInLo"], "\(label).velInLo"),
            velInHi: try optionalInteger(obj["velInHi"], "\(label).velInHi"),
            velOutLo: try optionalInteger(obj["velOutLo"], "\(label).velOutLo"),
            velOutHi: try optionalInteger(obj["velOutHi"], "\(label).velOutHi"))
    }

    /// - Parameter reminted: OUT — the ids the caller SENT on the `zones` path
    ///   that named no zone here and were therefore replaced with fresh ones.
    ///   Empty on every other path. Surfaced as `remintedZoneIDs` so the
    ///   substitution is reported rather than silent (see `UnknownZoneID`).
    private func parseSampler(_ value: JSONValue?,
                              current: SamplerParams? = nil,
                              reminted: inout [String]) throws -> SamplerParams? {
        guard let value else { return nil }
        guard case .object(let obj) = value else {
            throw ControlError("sampler must be an object {zones, oneShot?, attack?, release?, gain?}")
        }
        // m26-g: `zones` and `zonePatches` are mutually exclusive. They say
        // OPPOSITE things about the zones the caller did not mention — `zones`
        // drops them, `zonePatches` keeps them — so a payload carrying both
        // cannot be read, only guessed at. Same shape as ai.modelUnload's
        // modelId-vs-all.
        if obj["zones"] != nil, obj["zonePatches"] != nil {
            throw ControlError(
                "sampler takes exactly one of 'zones' or 'zonePatches', not both. 'zones' "
                    + "REPLACES the whole keyzone map (and [] deliberately clears it); "
                    + "'zonePatches' edits the zones you name by id and leaves every other "
                    + "zone standing.")
        }
        let currentZones = current?.zones ?? []
        var zones: [SamplerZone] = currentZones
        if let zonesValue = obj["zones"] {
            zones = []
            guard case .array(let array) = zonesValue else {
                throw ControlError("sampler.zones must be an array")
            }
            var seen: Set<UUID> = []
            for (i, element) in array.enumerated() {
                guard case .object(let zone) = element else {
                    throw ControlError("sampler.zones[\(i)] must be an object")
                }
                let label = "sampler.zones[\(i)]"
                guard let rawPath = zone["path"]?.stringValue else {
                    throw ControlError("\(label).path is required")
                }
                let path = try Self.resolveZonePath(rawPath, label: "\(label).path")
                // m26-g: a PRESENT id is honoured, so snapshot → setInstrument
                // stops renumbering the map; an ABSENT id mints a fresh one, so
                // authoring a brand-new map still needs no ids at all.
                let id = try Self.parseZoneID(zone["id"], label: label,
                                              known: currentZones, onUnknown: .mintUnknown,
                                              seen: &seen, reminted: &reminted)
                let fields = try Self.parseZoneFields(zone, label)
                zones.append(Self.makeZone(fields, id: id, path: path))
            }
        } else if let patchesValue = obj["zonePatches"] {
            // m26-g merge-by-id: edit the zones named here, leave the rest
            // alone. This is the ONLY way to touch one zone of a 309-zone
            // imported library without resending all 309.
            guard case .array(let array) = patchesValue else {
                throw ControlError("sampler.zonePatches must be an array")
            }
            var seen: Set<UUID> = []
            var patches: [UUID: ParsedZoneFields] = [:]
            for (i, element) in array.enumerated() {
                guard case .object(let patch) = element else {
                    throw ControlError("sampler.zonePatches[\(i)] must be an object")
                }
                let label = "sampler.zonePatches[\(i)]"
                guard let idValue = patch["id"] else {
                    throw ControlError(
                        "\(label).id is required — a patch names the zone it edits. Read the "
                            + "ids from project.snapshot's instrument.sampler.zones[].id, or "
                            + "send the whole map as 'zones' to author new zones.")
                }
                let id = try Self.parseZoneID(idValue, label: label,
                                              known: currentZones, onUnknown: .reject,
                                              seen: &seen, reminted: &reminted)
                patches[id] = try Self.parseZoneFields(patch, label)
            }
            // IN PLACE, by index. Zone ORDER is load-bearing — on an overlap
            // the FIRST zone whose span contains the pitch wins — so a patch
            // replaces its zone where it sits and never appends or re-sorts.
            // Rebuilding the array from a dictionary would silently change
            // which zone plays, a worse bug than the one m26-g fixes.
            for index in zones.indices {
                guard let fields = patches[zones[index].id] else { continue }
                zones[index] = Self.merge(fields, into: zones[index])
            }
        }
        // Each global falls back to the CURRENT value, then to the model
        // default on a track that has no sampler config yet — so tuning one
        // knob never quietly resets the other three.
        let fallback = current ?? SamplerParams()
        let oneShot: Bool
        switch obj["oneShot"] {
        case .none: oneShot = fallback.oneShot
        case .some(.bool(let b)): oneShot = b
        case .some: throw ControlError("sampler.oneShot must be a boolean")
        }
        return SamplerParams(
            zones: zones,
            oneShot: oneShot,
            attack: try Self.optionalNumber(obj["attack"], "sampler.attack") ?? fallback.attack,
            release: try Self.optionalNumber(obj["release"], "sampler.release") ?? fallback.release,
            gain: try Self.optionalNumber(obj["gain"], "sampler.gain") ?? fallback.gain,
            // m26-h: provenance is SET BY THE IMPORTER and never read off the
            // wire — parity with `SoundBankConfig.displayName`, which is
            // likewise server-derived. It rides through here so that a partial
            // update (or a wholesale zone edit) does not erase it; a caller who
            // echoes `sourcePath`/`name` back from project.snapshot gets the
            // right answer for the right reason, because the value came from
            // `current`, not from their payload. Unknown keys inside `sampler`
            // stay IGNORED rather than rejected, precisely so that echo cannot
            // become an error.
            sourcePath: fallback.sourcePath,
            displayName: fallback.displayName,
            // m27 continuous expression: same fall-back-to-current rule as the
            // four scalars above, so tuning one knob never resets this one.
            expressionModDepth: try Self.optionalNumber(
                obj["expressionModDepth"], "sampler.expressionModDepth")
                ?? fallback.expressionModDepth,
            expressionFilterDepth: try Self.optionalNumber(
                obj["expressionFilterDepth"], "sampler.expressionFilterDepth")
                ?? fallback.expressionFilterDepth,
            expressionFilterCC: try Self.optionalInteger(
                obj["expressionFilterCC"], "sampler.expressionFilterCC")
                ?? fallback.expressionFilterCC,
            // Bend range + voice mode: the SAME fall-back-to-current rule, so
            // tuning any other knob never quietly resets these two either.
            // Both REFUSE a bad value rather than clamping it — an agent that
            // asked for a 60-semitone range and silently got 48 has no way to
            // find out (the m23 silent-discard defect class).
            bendRangeSemitones: try Self.optionalBoundedNumber(
                obj["bendRangeSemitones"], "sampler.bendRangeSemitones",
                SamplerParams.bendRangeSemitonesRange,
                "how many semitones a FULL pitch-bend deflection moves the note; omit for the "
                    + "General MIDI default of 2, which is what every already-authored bend lane "
                    + "was written against")
                ?? fallback.bendRangeSemitones,
            voiceMode: try Self.optionalSamplerVoiceMode(obj["voiceMode"])
                ?? fallback.voiceMode
        )
    }

    /// One optional, RANGE-CHECKED number inside the `sampler` object. Refuses
    /// out-of-range rather than clamping, and says what the field MEANS in the
    /// same breath — the `boundedOption` idiom, applied inside a nested object
    /// where that helper (which reads top-level params) cannot reach.
    private static func optionalBoundedNumber(
        _ value: JSONValue?, _ name: String,
        _ bounds: ClosedRange<Double>, _ meaning: String
    ) throws -> Double? {
        guard let number = try Self.optionalNumber(value, name) else { return nil }
        guard number.isFinite, bounds.contains(number) else {
            throw ControlError("\(name) must be between \(bounds.lowerBound) and "
                               + "\(bounds.upperBound) — \(meaning)")
        }
        return number
    }

    /// `"poly"` / `"mono"`, or nil when the key is absent. An unrecognised
    /// string is REFUSED and lists the two legal values: a typo silently
    /// falling back to poly would be a sampler that ignores the mode it was
    /// told to use, reported as success.
    private static func optionalSamplerVoiceMode(_ value: JSONValue?) throws -> SamplerVoiceMode? {
        switch value {
        case .none, .some(.null): return nil
        case .some(.string(let raw)):
            guard let mode = SamplerVoiceMode(rawValue: raw.lowercased()) else {
                throw ControlError("sampler.voiceMode must be \"poly\" or \"mono\" — mono is "
                                   + "LAST-NOTE priority, so a new note always takes over from "
                                   + "the one sounding")
            }
            return mode
        case .some:
            throw ControlError("sampler.voiceMode must be a string (\"poly\" or \"mono\")")
        }
    }

    /// Wire wording for an inaudible audition (m23-d). The events were still
    /// delivered — this names WHY the strip will be silent so an agent can fix
    /// it (unmute, wait for the plugin, start the transport) instead of retrying
    /// blindly. `.sounded` never reaches here.
    /// `nil` for `.sounded` — an audible answer carries no reason. Note that
    /// mute and solo-exclusion share one word here because they share one
    /// outcome: `AuditionOutcome.inaudibleMuted` is deliberately the single
    /// "the strip's fader is gated" case (design §7.1), so there is no separate
    /// `soloExcluded` spelling to report.
    private static func auditionReason(_ outcome: AuditionOutcome) -> String? {
        switch outcome {
        case .sounded: return nil
        case .inaudibleMuted: return "trackMuted"
        case .inaudibleNotReady: return "instrumentNotReady"
        case .inaudibleEngineStopped: return "engineStopped"
        case .noRenderer: return "engineRebuilding"
        case .unsupported: return "engineStopped"
        }
    }

    /// An optional integer pitch field: absent → nil; present-but-not-a-whole-
    /// number → a field-path error. Range is left to the model's clamping init.
    private static func optionalPitch(_ value: JSONValue?, _ field: String) throws -> Int? {
        guard let value else { return nil }
        guard let number = value.doubleValue, isInteger(number) else {
            throw ControlError("\(field) must be an integer 0-127")
        }
        return Int(number)
    }

    /// An optional plain-integer field (zone group / round-robin indices):
    /// absent → nil; present-but-not-a-whole-number → a field-path error.
    /// Range is left to the model's clamping init.
    private static func optionalInteger(_ value: JSONValue?, _ field: String) throws -> Int? {
        guard let value else { return nil }
        guard let number = value.doubleValue, isInteger(number) else {
            throw ControlError("\(field) must be an integer")
        }
        return Int(number)
    }

    /// An optional boolean field (m19-b zone oneShot): absent → nil (inherit);
    /// present-but-not-a-bool → a field-path error.
    private static func optionalBool(_ value: JSONValue?, _ field: String) throws -> Bool? {
        guard let value else { return nil }
        guard case .bool(let flag) = value else {
            throw ControlError("\(field) must be a boolean")
        }
        return flag
    }

    /// An optional string field (m23-o1 `frequency.reference`'s `family`/
    /// `trackId`): absent → nil; present-but-not-a-string → a field-path
    /// error, so a wrong-typed value never silently reads as "not passed".
    private static func optionalString(_ value: JSONValue?, _ field: String) throws -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else {
            throw ControlError("\(field) must be a string")
        }
        return string
    }

    /// An optional numeric field: absent → nil; present-but-not-a-number → a
    /// field-path error. Range is left to the model's clamping init.
    private static func optionalNumber(_ value: JSONValue?, _ field: String) throws -> Double? {
        guard let value else { return nil }
        guard let number = value.doubleValue else {
            throw ControlError("\(field) must be a number")
        }
        return number
    }

    /// Parses an optional `audioUnit` object `{type?, subType, manufacturer}`
    /// (type defaults `defaultType`) and resolves it STRICTLY against
    /// `candidates`: no match → a readable error naming the FourCCs and the
    /// listing command. A match fills the config's display name/manufacturer;
    /// stateData starts nil. Defaults cover the instrument path ('aumu'
    /// against the installed music devices); `fx.add` passes the effect
    /// component list ('aufx') and `fx.listAudioUnits`.
    private func parseAudioUnit(_ value: JSONValue?, defaultType: String = "aumu",
                                candidates: [AudioUnitComponentInfo]? = nil,
                                listCommand: String = "instrument.listAudioUnits")
        throws -> AudioUnitConfig? {
        guard let value else { return nil }
        guard case .object(let obj) = value else {
            throw ControlError("audioUnit must be an object {type?, subType, manufacturer}")
        }
        guard let subType = obj["subType"]?.stringValue else {
            throw ControlError("audioUnit.subType is required")
        }
        guard let manufacturer = obj["manufacturer"]?.stringValue else {
            throw ControlError("audioUnit.manufacturer is required")
        }
        let component = AudioUnitComponentID(
            type: obj["type"]?.stringValue ?? defaultType,
            subType: subType,
            manufacturer: manufacturer
        )
        guard let match = (candidates ?? store.availableAudioUnits())
            .first(where: { $0.component == component }) else {
            throw ControlError(
                "no installed Audio Unit matches \(component.type)/\(component.subType)/\(component.manufacturer) — see \(listCommand)")
        }
        return AudioUnitConfig(component: match.component, name: match.name,
                               manufacturerName: match.manufacturerName, stateData: nil)
    }

    // MARK: - Sound banks (m10-n)

    /// Resolves a REQUIRED sound-bank `source` string to `SoundBankSource`,
    /// STRICTLY validating a `.file` source (existing, `.sf2`/`.dls`) BEFORE any
    /// store edit — the `parseAudioUnit` discipline (§6.1/§6.3). Every error
    /// names `instrument.listSoundBanks` so an agent knows where to discover a
    /// valid source. `"gm"` is always accepted (resolved to the system bank at
    /// use time).
    private func parseSoundBankSource(_ value: JSONValue?) throws -> SoundBankSource {
        guard let raw = value?.stringValue else {
            throw ControlError("'source' is required (\"gm\" or an absolute .sf2/.dls path)")
        }
        if raw == "gm" { return .generalMIDI }
        guard raw.hasPrefix("/") else {
            throw ControlError(
                "sound bank source must be \"gm\" or an absolute path — see instrument.listSoundBanks")
        }
        let url = URL(fileURLWithPath: raw)
        guard FileManager.default.fileExists(atPath: raw) else {
            throw ControlError("no sound bank file at \(raw) — see instrument.listSoundBanks")
        }
        let ext = url.pathExtension.lowercased()
        // ⛔ m31-g: the wire gate that keeps a listed-but-unsupported bank
        // (`.sf3`) unselectable. Rejects by extension, independently of
        // `SoundBankInfo.unsupportedReason`.
        guard SoundBankLibrary.isSupportedExtension(ext) else {
            throw ControlError(
                "sound bank must be a .sf2 or .dls file — got \(url.lastPathComponent) (see instrument.listSoundBanks)")
        }
        return .file(path: raw)
    }

    /// Parses the optional `soundBank` object on `track.setInstrument` into a
    /// `SoundBankConfig` (§6.1). Absent → nil (keep the current descriptor). The
    /// `source` is STRICT (`parseSoundBankSource`); `program`/`bankMSB`/`bankLSB`
    /// default 0/121/0 and re-clamp through the model init (the
    /// `track.setVolume` silent-clamp convention); `displayName` is
    /// SERVER-derived, never a wire input.
    private func parseSoundBank(_ value: JSONValue?) throws -> SoundBankConfig? {
        guard let value else { return nil }
        guard case .object(let obj) = value else {
            throw ControlError("soundBank must be an object {source, program?, bankMSB?, bankLSB?}")
        }
        let source = try parseSoundBankSource(obj["source"])
        let program = obj["program"]?.doubleValue.map { Int($0) } ?? 0
        let bankMSB = obj["bankMSB"]?.doubleValue.map { Int($0) } ?? 121
        let bankLSB = obj["bankLSB"]?.doubleValue.map { Int($0) } ?? 0
        let displayName = deriveSoundBankName(
            source: source, program: program, bankMSB: bankMSB, bankLSB: bankLSB)
        return SoundBankConfig(source: source, program: program,
                               bankMSB: bankMSB, bankLSB: bankLSB, displayName: displayName)
    }

    /// Derives the display name captured in a `SoundBankConfig` (§6.1): a named
    /// program from the source's own program list ("<name> — <suffix>", e.g.
    /// "Trumpet — General MIDI") when the address matches a parsed name, else
    /// the honest "<suffix> · P<n>" fallback (odd address, or an unparsed .dls).
    /// The suffix is "General MIDI" for `"gm"`, the file stem for a `.file`.
    private func deriveSoundBankName(source: SoundBankSource, program: Int,
                                     bankMSB: Int, bankLSB: Int) -> String {
        let suffix: String
        switch source {
        case .generalMIDI:
            suffix = "General MIDI"
        case .file(let path):
            suffix = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        if let listing = try? store.soundBankPrograms(source: source), listing.namesParsed,
           let match = listing.programs.first(where: {
               $0.program == program && $0.bankMSB == bankMSB && $0.bankLSB == bankLSB
           }), !match.name.isEmpty {
            return "\(match.name) — \(suffix)"
        }
        return "\(suffix) · P\(program)"
    }

    /// Wire JSON for a `SoundBankInfo` (§6.2/§6.4 shape). `supported` and
    /// `unsupportedReason` are ADDITIVE (m31-g): every pre-existing key keeps
    /// its meaning, and a loadable bank reads `supported: true,
    /// unsupportedReason: null` exactly as before it had them.
    private func soundBankInfoJSON(_ info: SoundBankInfo) -> JSONValue {
        .object([
            "source": .string(info.source.rawString),
            "name": .string(info.name),
            "path": .string(info.path),
            "format": .string(info.format),
            "builtin": .bool(info.builtin),
            "sizeBytes": .number(Double(info.sizeBytes)),
            "supported": .bool(info.supported),
            "unsupportedReason": info.unsupportedReason.map { JSONValue.string($0) } ?? .null,
        ])
    }

    /// Wire JSON for a `SoundBankProgram` (§6.3 shape).
    private func soundBankProgramJSON(_ program: SoundBankProgram) -> JSONValue {
        .object([
            "program": .number(Double(program.program)),
            "bankMSB": .number(Double(program.bankMSB)),
            "bankLSB": .number(Double(program.bankLSB)),
            "name": .string(program.name),
            "category": .string(program.category),
        ])
    }

    /// Encodes the whole snapshot for the wire, replacing each instrument track's
    /// `instrument` with its resolved wire form so sampler zones carry `path`
    /// (a filesystem path string) instead of the model's URL, and attaching every
    /// track's RESOLVED insert chain (`{id, kind, isBypassed, params,
    /// latencySamples, gainReductionDb?}` — the m22-e GR meter rides here, and
    /// on `masterEffects`, because this snapshot IS the poll path that already
    /// carries per-strip meter state). Audio/bus tracks keep their (omitted)
    /// instrument.
    private func snapshotJSON() throws -> JSONValue {
        let snapshot = store.snapshot()
        let encoded = try JSONValue(encoding: snapshot)
        guard case .object(var root) = encoded,
              case .array(var trackArray)? = root["tracks"] else { return encoded }
        // PDC report (M4 viii-c, spec §6): additive per-strip + project-level
        // fields, engine-derived through the store. nil (headless) reads as
        // all-zero — honest, since no rings exist without an engine.
        let pdc = store.pdcReport()
        for (i, track) in snapshot.tracks.enumerated() where i < trackArray.count {
            guard case .object(var trackObject) = trackArray[i] else { continue }
            if track.kind == .instrument, let descriptor = track.instrument {
                trackObject["instrument"] = instrumentJSON(descriptor, trackID: track.id)
            }
            // Every track kind carries the resolved insert chain (M4 ii),
            // with live per-effect latency from the engine via the store.
            trackObject["effects"] = effectsJSON(track.effects, trackID: track.id)
            // Transient per-clip stretch render state (M5 ii-d): engine-
            // sourced at snapshot-build time, never persisted.
            // `stretchRendering: true` while the render job runs (the clip is
            // scheduled as silence until it lands); `stretchError` carries a
            // readable reason on failure. Both omit-when-default; identity
            // clips are never queried (they never render).
            if track.kind == .audio,
               track.clips.contains(where: { !$0.isStretchIdentity }),
               case .array(var clipArray)? = trackObject["clips"] {
                for (j, clip) in track.clips.enumerated()
                where j < clipArray.count && !clip.isStretchIdentity {
                    guard case .object(var clipObject) = clipArray[j] else { continue }
                    switch store.clipStretchStatus(trackID: track.id, clipID: clip.id) {
                    case .rendering?:
                        clipObject["stretchRendering"] = .bool(true)
                    case .failed(let reason)?:
                        clipObject["stretchError"] = .string(reason)
                    case .idle?, nil:
                        break
                    }
                    clipArray[j] = .object(clipObject)
                }
                trackObject["clips"] = .array(clipArray)
            }
            // Per-strip PDC fields: the stable all-effects chain total and
            // the applied ring target always; the honesty flags only when
            // they say something (clamped / the documented §2 skew case).
            let strip = pdc?.strips[track.id]
            trackObject["chainLatencySamples"] =
                .number(Double(strip?.chainLatencySamples ?? 0))
            trackObject["compensationSamples"] =
                .number(Double(strip?.compensationSamples ?? 0))
            if let strip, strip.clamped {
                trackObject["compensationClamped"] = .bool(true)
            }
            if let strip, strip.skewSamples != 0 {
                trackObject["compensationSkewSamples"] = .number(Double(strip.skewSamples))
            }
            trackArray[i] = .object(trackObject)
        }
        root["tracks"] = .array(trackArray)
        // The project MASTER insert chain (m13-d), post-fader — ALWAYS present
        // (an empty array when the chain is empty), mirroring the per-track
        // `effects` field. Resolved through the same `effectsJSON` shape with a
        // master latency resolver (a limiter's 240 @ 48 kHz surfaces here).
        root["masterEffects"] = masterEffectsJSON()
        // Project-level totals: stage maxima, the global path latency, and the
        // ruler-to-speaker output latency (= maxPath + the ACTIVE master-chain
        // latency; m13-d made the master chain real, so the two diverge when a
        // latent master effect — e.g. a limiter — is active).
        root["pdc"] = .object([
            "trackStageSamples": .number(Double(pdc?.trackStageSamples ?? 0)),
            "busStageSamples": .number(Double(pdc?.busStageSamples ?? 0)),
            "maxPathLatencySamples": .number(Double(pdc?.maxPathLatencySamples ?? 0)),
            "masterChainLatencySamples": .number(Double(pdc?.masterChainLatencySamples ?? 0)),
            "outputLatencySamples": .number(Double(pdc?.outputLatencySamples ?? 0)),
        ])
        return .object(root)
    }

    /// The `discardedRecovery` honesty echo (m16-e, audit F3) for
    /// project.new/open/save, each of which routes through
    /// `ProjectStore.invalidateCrashRecovery()` as a SIDE EFFECT of an
    /// unrelated transition. `before` is the offer status captured immediately
    /// before the mutating store call; this compares it against the CURRENT
    /// status and, only when an offer that was available is now gone, echoes
    /// the offer's own facts back (minus the now-redundant `available: true`)
    /// so the response says "you just lost this" instead of staying silent.
    /// Returns nil when there was nothing to discard (the common case, and
    /// also true when the call THREW before reaching this point).
    private func discardedRecoveryField(before: AutosaveRecoveryStatus) throws -> JSONValue? {
        guard before.available, !store.recoveryStatus().available else { return nil }
        var obj = try JSONValue(encoding: before).objectValue ?? [:]
        obj.removeValue(forKey: "available")
        return .object(obj)
    }

    /// The base instrument wire JSON plus, for kind audioUnit, the resolved
    /// "audioUnit" object {type, subType, manufacturer, name, manufacturerName,
    /// status}. `status` comes from the store's engine forwarder ("pending"
    /// until the engine reports); stateData NEVER travels on the wire.
    private func instrumentJSON(_ d: InstrumentDescriptor, trackID: UUID) -> JSONValue {
        guard case .object(var obj) = Self.instrumentJSON(d) else {
            return Self.instrumentJSON(d)
        }
        if d.kind == .audioUnit, let config = d.audioUnit {
            obj["audioUnit"] = .object([
                "type": .string(config.component.type),
                "subType": .string(config.component.subType),
                "manufacturer": .string(config.component.manufacturer),
                "name": .string(config.name),
                "manufacturerName": .string(config.manufacturerName),
                "status": .string(instrumentStatusString(trackID)),
            ])
        } else if d.kind == .soundBank, let config = d.soundBank {
            // The `path` is the RESOLVED transparency field; `source` is the
            // persistable sentinel/path (LAW L4). `status` reads the SAME
            // registry slot as plain AU hosting (§6.1 — pending in headless).
            let resolvedPath: String
            switch config.source {
            case .generalMIDI: resolvedPath = SoundBankLibrary.systemGMBankPath
            case .file(let path): resolvedPath = path
            }
            obj["soundBank"] = .object([
                "source": .string(config.source.rawString),
                "path": .string(resolvedPath),
                "program": .number(Double(config.program)),
                "bankMSB": .number(Double(config.bankMSB)),
                "bankLSB": .number(Double(config.bankLSB)),
                "name": .string(config.displayName),
                "status": .string(instrumentStatusString(trackID)),
            ])
        }
        return .object(obj)
    }

    /// The hosted-instrument lifecycle status string, SHARED by the `.audioUnit`
    /// and `.soundBank` instrument objects (both ride the same registry slot,
    /// §6.1): "pending" until the engine reports (the headless default),
    /// "ready", "missing", or "failed: <reason>".
    ///
    /// m23-br-1: the four-case rendering itself moved to
    /// `AudioUnitTrackStatus.wireLabel` (DAWCore) so `engine.auPrepareStats`'
    /// per-slot `status` cannot spell "failed" differently from this one. The
    /// nil handling stays HERE and is NOT shared — a snapshot's instrument
    /// object always carries a status, defaulting to "pending" when the engine
    /// has not reported yet, whereas the prepare-stats payload omits the field
    /// entirely for a slot the registry holds no status for. Different
    /// questions, deliberately different answers.
    private func instrumentStatusString(_ trackID: UUID) -> String {
        (store.audioUnitStatus(forTrack: trackID) ?? .pending).wireLabel
    }

    /// Wire JSON for a resolved instrument descriptor: `polySynth` verbatim plus
    /// the resolved `sampler` (always present on an instrument track), whose zones
    /// emit `path` (a filesystem path string, the same convention as clip audio)
    /// instead of the model's `audioFileURL` URL.
    static func instrumentJSON(_ d: InstrumentDescriptor) -> JSONValue {
        let poly = d.polySynth
        let sampler = d.resolvedSampler
        // m26-h: provenance rides NEXT TO `zones`, only when set — the same
        // only-when-SET idiom as every zone field, so a hand-built sampler's
        // wire shape stays byte-identical to pre-m26-h. Shaped after the
        // `soundBank` sibling's {path, name}; there is no `source` (a sampler
        // has no sentinel) and no `status` (the built-in sampler does not ride
        // the AU registry slot those two share).
        var samplerObject: [String: JSONValue] = [
            "zones": .array(sampler.zones.map(samplerZoneJSON)),
            "oneShot": .bool(sampler.oneShot),
            "attack": .number(sampler.attack),
            "release": .number(sampler.release),
            "gain": .number(sampler.gain),
        ]
        // m27 expression, all only-when-SET so a sampler that never opted in
        // keeps its pre-m27 wire shape byte-for-byte.
        if let modDepth = sampler.expressionModDepth {
            samplerObject["expressionModDepth"] = .number(modDepth)
        }
        if let filterDepth = sampler.expressionFilterDepth {
            samplerObject["expressionFilterDepth"] = .number(filterDepth)
        }
        if let filterCC = sampler.expressionFilterCC {
            samplerObject["expressionFilterCC"] = .number(Double(filterCC))
        }
        // Bend range + voice mode, same only-when-SET rule: an untouched
        // sampler's wire shape does not grow two keys, and "unset" stays
        // distinguishable from "explicitly the default" on a round trip.
        if let bendRange = sampler.bendRangeSemitones {
            samplerObject["bendRangeSemitones"] = .number(bendRange)
        }
        if let voiceMode = sampler.voiceMode {
            samplerObject["voiceMode"] = .string(voiceMode.rawValue)
        }
        if let sourcePath = sampler.sourcePath {
            samplerObject["sourcePath"] = .string(sourcePath)
        }
        if let displayName = sampler.displayName {
            samplerObject["name"] = .string(displayName)
        }
        return .object([
            "kind": .string(d.kind.rawValue),
            "polySynth": .object([
                "waveform": .string(poly.waveform.rawValue),
                "attack": .number(poly.attack),
                "decay": .number(poly.decay),
                "sustain": .number(poly.sustain),
                "release": .number(poly.release),
                "cutoffHz": .number(poly.cutoffHz),
                "resonance": .number(poly.resonance),
                "gain": .number(poly.gain),
            ]),
            "sampler": .object(samplerObject),
        ])
    }

    /// Wire JSON for ONE sampler zone. Split out of `instrumentJSON` at m26-h
    /// only so the sampler object could gain two sibling keys; the emission
    /// rules below are unchanged.
    private static func samplerZoneJSON(_ zone: SamplerZone) -> JSONValue {
        // m19-a selection fields are emitted only when SET, so a legacy zone's
        // wire shape is byte-identical to pre-m19 (and agents read back exactly
        // what they configured).
        var object: [String: JSONValue] = [
            "id": .string(zone.id.uuidString),
            "path": .string(zone.audioFileURL.path),
            "rootPitch": .number(Double(zone.rootPitch)),
            "minPitch": .number(Double(zone.minPitch)),
            "maxPitch": .number(Double(zone.maxPitch)),
            "gain": .number(zone.gain),
        ]
        if let minVelocity = zone.minVelocity {
            object["minVelocity"] = .number(Double(minVelocity))
        }
        if let maxVelocity = zone.maxVelocity {
            object["maxVelocity"] = .number(Double(maxVelocity))
        }
        if let group = zone.group { object["group"] = .number(Double(group)) }
        if let seqLength = zone.seqLength {
            object["seqLength"] = .number(Double(seqLength))
        }
        if let seqPosition = zone.seqPosition {
            object["seqPosition"] = .number(Double(seqPosition))
        }
        if let randMin = zone.randMin { object["randMin"] = .number(randMin) }
        if let randMax = zone.randMax { object["randMax"] = .number(randMax) }
        // m19-b playback scalars: same only-when-SET emission
        // (A-imp-1 idiom) — a legacy zone's wire shape stays
        // byte-identical.
        if let tuneCents = zone.tuneCents {
            object["tuneCents"] = .number(tuneCents)
        }
        if let pan = zone.pan { object["pan"] = .number(pan) }
        if let ampVelTrack = zone.ampVelTrack {
            object["ampVelTrack"] = .number(ampVelTrack)
        }
        if let oneShot = zone.oneShot { object["oneShot"] = .bool(oneShot) }
        if let startFrame = zone.startFrame {
            object["startFrame"] = .number(Double(startFrame))
        }
        if let endFrame = zone.endFrame {
            object["endFrame"] = .number(Double(endFrame))
        }
        if let attack = zone.attack { object["attack"] = .number(attack) }
        if let decay = zone.decay { object["decay"] = .number(decay) }
        if let sustain = zone.sustain { object["sustain"] = .number(sustain) }
        if let release = zone.release { object["release"] = .number(release) }
        // m20-g loop fields: same only-when-SET emission.
        if let loopMode = zone.loopMode {
            object["loopMode"] = .string(loopMode.rawValue)
        }
        if let loopStart = zone.loopStart {
            object["loopStart"] = .number(Double(loopStart))
        }
        if let loopEnd = zone.loopEnd {
            object["loopEnd"] = .number(Double(loopEnd))
        }
        if let crossfade = zone.crossfade {
            var xf: [String: JSONValue] = [:]
            if let v = crossfade.controller { xf["controller"] = .number(Double(v)) }
            if let v = crossfade.ccInLo { xf["ccInLo"] = .number(Double(v)) }
            if let v = crossfade.ccInHi { xf["ccInHi"] = .number(Double(v)) }
            if let v = crossfade.ccOutLo { xf["ccOutLo"] = .number(Double(v)) }
            if let v = crossfade.ccOutHi { xf["ccOutHi"] = .number(Double(v)) }
            if let v = crossfade.velInLo { xf["velInLo"] = .number(Double(v)) }
            if let v = crossfade.velInHi { xf["velInHi"] = .number(Double(v)) }
            if let v = crossfade.velOutLo { xf["velOutLo"] = .number(Double(v)) }
            if let v = crossfade.velOutHi { xf["velOutHi"] = .number(Double(v)) }
            object["crossfade"] = .object(xf)
        }
        return .object(object)
    }

    /// `instrument.describeSampler`'s zone summary (m26-i): count, pitch/
    /// velocity COVERAGE (the union of zone ranges, not a naive min/max —
    /// see `zoneCoverage`), group count (nil group = implicit group 0, the
    /// model's own default), and distinct sample-file count. Empty zones
    /// (the documented `zones: []` clear) is a legal, describable state:
    /// every field below answers honestly for it (count 0, no coverage
    /// keys, group/file counts 0) rather than being reachable only through
    /// an error.
    private static func samplerZoneSummaryJSON(_ zones: [SamplerZone]) -> JSONValue {
        var obj: [String: JSONValue] = ["count": .number(Double(zones.count))]
        if let pitch = SamplerZoneCoverage.pitchCoverage(of: zones) {
            obj["pitchCoverage"] = Self.coverageJSON(pitch)
        }
        // minVelocity/maxVelocity nil means the FULL 0...127 span (the
        // model's own documented default), never 0 — folding nil to 0 here
        // would silently report a velocity hole that does not exist. That fold
        // lives in `SamplerZoneCoverage.velocityCoverage` so the editor UI
        // reads it the same way.
        if let velocity = SamplerZoneCoverage.velocityCoverage(of: zones) {
            obj["velocityCoverage"] = Self.coverageJSON(velocity)
        }
        let groups = Set(zones.map { $0.group ?? 0 })
        obj["groupCount"] = .number(Double(groups.count))
        let files = Set(zones.map { $0.audioFileURL.path })
        obj["distinctSampleFiles"] = .number(Double(files.count))
        return .object(obj)
    }

    /// `instrument.describeSampler`'s `effectiveGlobals` (2026-08-20 field
    /// report): for each global scalar a zone is allowed to override, what the
    /// ENGINE will actually apply.
    ///
    /// The response's top-level `release`/`attack`/`oneShot` are the STORED
    /// globals and stay exactly as they were (additive-only; `project.snapshot`
    /// and `track.setInstrument` keep echoing the model unchanged). What was
    /// missing is the second half of the sentence: a zone's own value WINS, so
    /// a library that authors the field on every zone — which is what an SFZ
    /// with `ampeg_release` in `<global>` produces — leaves the stored global
    /// unreachable. `globalIsInert` is the flag that says so in one boolean,
    /// and `note` says it in one sentence for a caller that reads prose.
    ///
    /// `effectiveValues` is the answer to "then what WILL I hear": the distinct
    /// values across every zone, ascending. It is present in the MIXED case
    /// too, which is the case that matters most and the one a bare boolean
    /// cannot describe — some zones on 0.5 s, the rest still tracking the
    /// global. `effectiveMin`/`effectiveMax` stay exact even when the list
    /// truncates.
    ///
    /// The COMPUTATION lives in `DAWCore.SamplerGlobalUse` so the sampler
    /// editor reads the same rule (the `SamplerZoneCoverage` precedent); only
    /// this shaping is here.
    /// Builds `effectiveGlobals` (the JSON) and, alongside it, the plain-English
    /// `warnings` a caller reading only the response's TOP LEVEL (release/
    /// attack/oneShot scalars, never descending into `effectiveGlobals`) will
    /// still see (2026-08-20 sax-team defect D): the stored scalars stay the
    /// AUTHORED value on purpose (round-trip fidelity — a caller reading one
    /// back and writing it forward must get what the user configured, not a
    /// collapsed "effective" number that is ill-defined once zones disagree
    /// with EACH OTHER, not just with the global), so the only way to make an
    /// inert global impossible to miss for that caller is a sibling top-level
    /// key naming it.
    private static func samplerEffectiveGlobalsJSON(
        _ params: SamplerParams
    ) -> (json: JSONValue, warnings: [String]) {
        var warnings: [String] = []
        // Defect C (2026-08-20 sax-team round): a per-zone override is the
        // ordinary cause of an inert global regardless of how the sampler was
        // built — hand-authored over the wire, imported from a `.dspreset`, or
        // imported from an SFZ. Only an SFZ import gives that override a fixed
        // OPCODE name worth quoting — `.dspreset` spells the very same field
        // `attack`/`release` with no `ampeg_` prefix at all (DSPresetParser.swift)
        // — so naming `ampeg_release` for a hand-built or `.dspreset`-sourced
        // sampler would be inventing provenance that isn't there. Gated on the
        // source file's own extension, not merely on `sourcePath` being set.
        let isSFZSource = params.sourcePath.map { $0.lowercased().hasSuffix(".sfz") } ?? false

        func formattedEffectiveValues(_ use: SamplerGlobalUse) -> String {
            let values = use.effectiveValues.map { "\($0)" }.joined(separator: ", ")
            return use.valuesTruncated ? "\(values), …" : values
        }

        func numericField(_ use: SamplerGlobalUse, _ name: String, sfzOpcode: String) -> JSONValue {
            var obj: [String: JSONValue] = [
                "global": .number(use.global),
                "zonesOverriding": .number(Double(use.zonesOverriding)),
                "zonesInheriting": .number(Double(use.zonesInheriting)),
                "globalIsInert": .bool(use.globalIsInert),
                "effectiveValues": .array(use.effectiveValues.map { .number($0) }),
            ]
            if let min = use.effectiveMin { obj["effectiveMin"] = .number(min) }
            if let max = use.effectiveMax { obj["effectiveMax"] = .number(max) }
            // Only-when-true (the A-imp-1 idiom): an always-present false adds
            // a key to every response to say nothing happened.
            if use.valuesTruncated { obj["effectiveValuesTruncated"] = .bool(true) }
            if use.globalIsInert {
                let opcodeClause = isSFZSource
                    ? " (authored per zone as SFZ's `\(sfzOpcode)`)" : ""
                // Defect A (2026-08-20 sax-team round): this string is read by
                // TWO audiences — a raw control-protocol caller (for whom
                // `sampler.zonePatches` is a real, working merge path) and an
                // MCP-connected agent, whose `track_set_instrument` schema does
                // NOT expose `zonePatches` at all; the only MCP tool that
                // reaches it is `instrument_set_sampler_zones`. A note that
                // named only the raw form sent an MCP caller into a silent
                // no-op (the exact defect this field exists to end, one layer
                // out) — so name the MCP tool FIRST and keep the raw form as a
                // parenthetical, since either reader must be able to follow
                // this sentence and succeed.
                obj["note"] = .string(
                    "every zone sets its own \(name)\(opcodeClause), so the stored global"
                        + " \(use.global) is NOT used — the engine applies the value(s) in"
                        + " effectiveValues. Change what you hear per zone with"
                        + " instrument_set_sampler_zones (patch [{id, \(name)}]) — or, over the"
                        + " raw control protocol, track.setInstrument's sampler.zonePatches"
                        + " [{id, \(name)}]; changing the global will do nothing.")
                warnings.append(
                    "\(name): the stored global (\(use.global)) is NOT what you'll hear — every"
                        + " zone overrides it; the engine actually applies"
                        + " \(formattedEffectiveValues(use)). See effectiveGlobals.\(name).")
            }
            return .object(obj)
        }
        let oneShotUse = SamplerOneShotUse.oneShot(of: params)
        var oneShot: [String: JSONValue] = [
            "global": .bool(oneShotUse.global),
            "zonesOverriding": .number(Double(oneShotUse.zonesOverriding)),
            "zonesInheriting": .number(Double(oneShotUse.zonesInheriting)),
            "globalIsInert": .bool(oneShotUse.globalIsInert),
        ]
        // Reported, never folded into the counts above: loop mode wins over
        // one-shot in the engine, but only for a loop whose bounds survive the
        // load-time check against the real audio file, which this layer cannot
        // see. Saying so is honest; guessing would swap one confidently wrong
        // number for another.
        if oneShotUse.zonesWithLoopMode > 0 {
            oneShot["zonesWithLoopMode"] = .number(Double(oneShotUse.zonesWithLoopMode))
            oneShot["note"] = .string(
                "\(oneShotUse.zonesWithLoopMode) zone(s) author a loop mode; a looping voice is"
                    + " never one-shot regardless of this field, provided its loop bounds are"
                    + " valid for the loaded sample.")
        }
        if oneShotUse.globalIsInert, oneShot["note"] == nil {
            // No SFZ opcode named here (unlike release/attack): the SFZ
            // analogue of a per-zone one-shot override is `loop_mode=one_shot`,
            // not an `ampeg_*` field, so there is no single opcode to quote.
            oneShot["note"] = .string(
                "every zone sets its own oneShot, so the stored global"
                    + " \(oneShotUse.global) is NOT used — the engine applies each zone's own"
                    + " flag. Change what you hear per zone with instrument_set_sampler_zones"
                    + " (patch [{id, oneShot}]) — or, over the raw control protocol,"
                    + " track.setInstrument's sampler.zonePatches [{id, oneShot}]; changing the"
                    + " global will do nothing.")
        }
        if oneShotUse.globalIsInert {
            warnings.append(
                "oneShot: the stored global (\(oneShotUse.global)) is NOT what happens — every"
                    + " zone sets its own flag. See effectiveGlobals.oneShot.")
        }
        let json = JSONValue.object([
            "release": numericField(SamplerGlobalUse.release(of: params), "release", sfzOpcode: "ampeg_release"),
            "attack": numericField(SamplerGlobalUse.attack(of: params), "attack", sfzOpcode: "ampeg_attack"),
            "oneShot": .object(oneShot),
        ])
        return (json, warnings)
    }

    /// The JSON shaping for one coverage envelope. The COMPUTATION moved to
    /// `DAWCore.SamplerZoneCoverage` at m26-i's UI half so the built-in Sampler
    /// editor (in DAWAppKit, which cannot see DAWControl) reports the same
    /// gaps this verb does; only this wire shaping stayed here.
    private static func coverageJSON(_ coverage: SamplerZoneCoverage) -> JSONValue {
        var obj: [String: JSONValue] = [
            "min": .number(Double(coverage.lowerBound)),
            "max": .number(Double(coverage.upperBound)),
        ]
        if !coverage.gaps.isEmpty {
            obj["gaps"] = .array(coverage.gaps.map {
                .object(["min": .number(Double($0.lowerBound)), "max": .number(Double($0.upperBound))])
            })
        }
        return .object(obj)
    }

    /// `offset` (int >= 0, default 0) for `instrument.describeSampler`'s
    /// zone page — same law as `au.describeParams`' offset
    /// (`parseAUOffset`): non-integers/negatives reject readably, absurdly
    /// large values cap in the Double domain before the Int conversion (no
    /// trap) and just page past the end, returning an empty, untruncated
    /// page.
    private static func parseZonePageOffset(_ params: [String: JSONValue]) throws -> Int {
        guard let raw = params["offset"] else { return 0 }
        guard let value = raw.doubleValue, value >= 0,
              value == value.rounded(.towardZero) else {
            throw ControlError("'offset' must be an integer >= 0")
        }
        return Int(min(value, 1_000_000_000))
    }

    /// `limit` (default 500) — out-of-range values silently CLAMP into
    /// 1...5000 (a sampler zone's wire JSON is far lighter than an AU
    /// parameter, so the ceiling sits higher than `au.describeParams`'
    /// `maxParams`); non-integers reject readably.
    private static func parseZonePageLimit(_ params: [String: JSONValue]) throws -> Int {
        guard let raw = params["limit"] else { return 500 }
        guard let value = raw.doubleValue, value == value.rounded(.towardZero) else {
            throw ControlError(
                "'limit' must be an integer (default 500; values clamp into 1…5000)")
        }
        return Int(min(max(value, 1), 5_000))
    }

    // MARK: - frequency.reference helpers (m23-o1 Step 3, design §6)

    /// The full `frequency.reference` wire payload. `resolution == nil` means
    /// the caller passed neither `family` nor `trackId` — the zero-param
    /// "teach me the vocabulary" call, which reads `resolution:"index"` with
    /// `families` alone. `families` is ALWAYS present, including on
    /// `unresolved` (design D2) — an unresolved answer is self-remedying in
    /// one round trip because the same vocabulary rides every response.
    private static func frequencyReferenceJSON(
        resolution: InstrumentFamilyResolution?,
        noteIgnored: Bool
    ) -> JSONValue {
        var payload: [String: JSONValue] = [:]
        switch resolution {
        case nil:
            payload["resolution"] = .string("index")
        case .resolved(let family, let source):
            payload["resolution"] = .string("family")
            payload["resolvedFrom"] = .string(source.rawValue)
            payload["reference"] = Self.frequencyReferenceRowJSON(
                InstrumentFrequencyTable.reference(for: family))
            if noteIgnored {
                payload["explanation"] = .string(
                    "The 'note' parameter is only meaningful when the track's sound bank "
                        + "addresses the General MIDI percussion kit (bank 120); this "
                        + "track's bank is melodic, so 'note' was ignored and the family "
                        + "was resolved from its General MIDI program instead.")
            }
        case .drumKit(let coveredNotes):
            payload["resolution"] = .string("drumKit")
            payload["coveredNotes"] = .array(Self.frequencyCoveredNotesJSON(coveredNotes))
        case .unresolved(let reason):
            payload["resolution"] = .string("unresolved")
            payload["reason"] = .string(reason.rawValue)
            payload["explanation"] = .string(reason.explanation)
            payload["remedy"] = .string(reason.remedy)
            if reason == .percussionNoteNotCoveredInV1 {
                // Never "no data" where the truth is "not this one, but here
                // are the ones I do have" (design D3).
                payload["coveredNotes"] = .array(Self.frequencyCoveredNotesJSON(
                    InstrumentFamilyResolver.coveredPercussionNotes))
            }
        }
        if noteIgnored { payload["noteIgnored"] = .bool(true) }
        payload["families"] = .array(Self.frequencyFamilyIndexJSON())
        return .object(payload)
    }

    /// One resolved reference row (design §6's `"reference"` object): family,
    /// displayName, fundamental (with its own citation), the two filter
    /// recommendations, and the cited bands.
    private static func frequencyReferenceRowJSON(_ row: InstrumentFrequencyReference) -> JSONValue {
        .object([
            "family": .string(row.family.rawValue),
            "displayName": .string(row.displayName),
            "fundamental": Self.frequencyFundamentalJSON(
                row.fundamental, citation: row.fundamentalCitation),
            "recommendedHighPass": Self.frequencyFilterRecommendationJSON(row.recommendedHighPass),
            "recommendedLowPass": Self.frequencyFilterRecommendationJSON(row.recommendedLowPass),
            "bands": .array(row.bands.map(Self.frequencyBandJSON)),
        ])
    }

    /// `.pitched` carries both MIDI notes AND their Hz/note-name derivations
    /// (`Fundamental.hz`/`.noteName` — the ONLY Hz source, design §5);
    /// `.inharmonic` carries `reason` and no range at all — never a fake one.
    private static func frequencyFundamentalJSON(
        _ fundamental: Fundamental, citation: FrequencyCitation
    ) -> JSONValue {
        switch fundamental {
        case .pitched(let lowest, let highest):
            return .object([
                "kind": .string("pitched"),
                "lowestMidiNote": .number(Double(lowest)),
                "highestMidiNote": .number(Double(highest)),
                "lowestHz": .number(Fundamental.hz(midiNote: lowest)),
                "highestHz": .number(Fundamental.hz(midiNote: highest)),
                "lowestNoteName": .string(Fundamental.noteName(midiNote: lowest)),
                "highestNoteName": .string(Fundamental.noteName(midiNote: highest)),
                "citation": Self.frequencyCitationJSON(citation),
            ])
        case .inharmonic(let reason):
            return .object([
                "kind": .string("inharmonic"),
                "reason": .string(reason),
                "citation": Self.frequencyCitationJSON(citation),
            ])
        }
    }

    private static func frequencyFilterRecommendationJSON(
        _ recommendation: FilterRecommendation
    ) -> JSONValue {
        switch recommendation {
        case .corner(let hz, let slope, let rationale, let citation):
            return .object([
                "kind": .string("corner"),
                "hz": .number(hz),
                "slopeDbPerOct": .number(Double(slope)),
                "rationale": .string(rationale),
                "citation": Self.frequencyCitationJSON(citation),
            ])
        case .noneRecommended(let reason, let explanation):
            return .object([
                "kind": .string("noneRecommended"),
                "reason": .string(reason.rawValue),
                "explanation": .string(explanation),
            ])
        }
    }

    private static func frequencyBandJSON(_ band: FrequencyBand) -> JSONValue {
        .object([
            "role": .string(band.role.rawValue),
            "lowHz": .number(band.lowHz),
            "highHz": .number(band.highHz),
            "effect": .string(band.effect),
            "citation": Self.frequencyCitationJSON(band.citation),
        ])
    }

    private static func frequencyCitationJSON(_ citation: FrequencyCitation) -> JSONValue {
        .object([
            "source": .string(citation.source),
            "url": .string(citation.url),
            "quote": .string(citation.quote),
            "retrieved": .string(citation.retrieved),
        ])
    }

    /// `[{note, name, family}]` for a set of covered GM percussion notes —
    /// UNCOVERED notes ship no name (design D3): GM's own names for them are
    /// spec data this table did not author, and inventing them would be the
    /// same class of error one level down. `compactMap` rather than a force
    /// unwrap so a note this function is never called with (there is none in
    /// practice — every caller passes covered notes) fails silently rather
    /// than crashing the control server.
    private static func frequencyCoveredNotesJSON(_ notes: [Int]) -> [JSONValue] {
        notes.compactMap { (note: Int) -> JSONValue? in
            guard let covered = InstrumentFamilyResolver.percussionNote(note) else { return nil }
            return .object([
                "note": .number(Double(covered.note)),
                "name": .string(covered.gmName),
                "family": .string(covered.family.rawValue),
            ])
        }
    }

    /// The `families` index every response carries (design §6): id,
    /// displayName, and — for note-keyed (percussion) families only — the
    /// covered notes. `notes` is omitted for every non-percussion family
    /// (the repo's nil-means-no-evidence convention) rather than shipping an
    /// empty array on every one of the other rows.
    private static func frequencyFamilyIndexJSON() -> [JSONValue] {
        InstrumentFamily.allCases.map { family in
            let row = InstrumentFrequencyTable.reference(for: family)
            let notes = InstrumentFamilyResolver.percussionNotes(for: family)
            var entry: [String: JSONValue] = [
                "family": .string(family.rawValue),
                "displayName": .string(row.displayName),
            ]
            if !notes.isEmpty {
                entry["notes"] = .array(notes.map { .number(Double($0)) })
            }
            return .object(entry)
        }
    }
}

/// The addressing target of a master-capable verb (m13-d, design §4): a
/// track/bus by id, or the project-level MASTER (the `trackId:"master"`
/// sentinel). Resolved by `parseFXTarget()` and used by EXACTLY the five
/// chain verbs (`fx.add`/`fx.remove`/`fx.reorder`/`fx.setBypass`/
/// `fx.setParam`) plus — m15-c — the four `automation.*` verbs (master
/// VOLUME lane only; other targets throw the named teaching error).
/// `fx.setSidechain` also parses it, only to REJECT `.master` with a named
/// error (master cannot host a keyed effect).
enum FXTarget: Equatable {
    case track(UUID)
    case master
}

struct ControlError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    static func noTrack(_ id: UUID) -> ControlError {
        ControlError("no track with id \(id.uuidString)")
    }
}

/// `LocalizedError` so in-process UI callers (the copilot rail's chat-list
/// refusal strip, its send-error strip) surface the teaching message
/// VERBATIM through `localizedDescription` — the refusal-bubble
/// one-vocabulary law: the human reads the same words an agent gets over
/// the wire, never Foundation's generic "operation couldn't be completed"
/// dump. The router's own `catch let error as ControlError` branch matches
/// FIRST, so wire behavior is byte-identical.
extension ControlError: LocalizedError {
    var errorDescription: String? { message }
}

extension [String: JSONValue] {
    func require<T>(_ key: String, _ path: KeyPath<JSONValue, T?>) throws -> T {
        guard let value = self[key]?[keyPath: path] else {
            throw ControlError("missing or invalid required param '\(key)'")
        }
        return value
    }

    /// Rejects any parameter key not in `allowed` with a teaching error naming
    /// the offending key(s) and the valid ones (m15-d, audit F5 hardening).
    ///
    /// m15-d scoped this to only the two "omit = destructive default" verbs
    /// (`track.setOutput`/`input.setDevice`), reasoning that an ignored typo on a
    /// partial-update verb (omission keeps the CURRENT value) is a harmless no-op.
    /// audit-m16 F5 disproved the generalization: `track.add {type:"instrument"}`
    /// silently ignored the typo'd key (the real key is `kind`) and the omitted
    /// `kind`'s default (audio) created the WRONG OBJECT KIND, not a no-op — a
    /// class the old scoping missed entirely. m16-e widens this to essentially
    /// every mutating verb: an unrecognized key is ALWAYS worth surfacing, whether
    /// the param it collides with is destructive-default, wrong-object-created, or
    /// truly a no-op — the agent typo'd something, and the cheapest possible
    /// response is a same-round-trip teaching error instead of silent divergence
    /// from what the agent asked for. This call does NOT change omit semantics:
    /// a verb whose optional param legitimately keeps the current value on
    /// OMISSION still does — this only rejects keys that aren't recognized at all.
    /// `allowed` is sorted for a deterministic, contract-stable message.
    ///
    /// m23-n2e: for a zero-param verb (`allowed.isEmpty`), "valid keys are"
    /// followed by nothing was a dangling, non-teaching sentence — measured
    /// live on staging (`vc.listVoices`, `transport.play`). The honest
    /// message for those 18 verbs is that the verb takes no parameters at
    /// all; every verb with at least one real key keeps the original,
    /// byte-identical "valid keys are …" sentence.
    func rejectUnknownKeys(_ allowed: Set<String>, verb: String, hint: String? = nil) throws {
        let unknown = keys.filter { !allowed.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }
        let named = unknown.map { "'\($0)'" }.joined(separator: ", ")
        var message: String
        if allowed.isEmpty {
            message = "\(verb): unknown parameter\(unknown.count > 1 ? "s" : "") \(named) — \(verb) takes no parameters"
        } else {
            let valid = allowed.sorted().map { "'\($0)'" }.joined(separator: ", ")
            message = "\(verb): unknown parameter\(unknown.count > 1 ? "s" : "") \(named) — valid keys are \(valid)"
        }
        if let hint { message += ". \(hint)" }
        throw ControlError(message)
    }

    func requireTrackID() throws -> UUID {
        let raw = try require("trackId", \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'trackId' is not a valid UUID: \(raw)")
        }
        return id
    }

    /// Resolves the `trackId` param of a master-capable verb into an
    /// `FXTarget` (m13-d, design §4): the EXACT lowercase string `"master"`
    /// (nothing fuzzy) targets the project master, any other value must be a
    /// track UUID. Kept DELIBERATELY separate from `requireTrackID` so the
    /// sentinel never leaks into the dozens of other verbs where "master" must
    /// stay an invalid track id — used by only the five chain verbs, the four
    /// `automation.*` verbs (m15-c), and `fx.setSidechain` (which parses it
    /// solely to reject master).
    func parseFXTarget() throws -> FXTarget {
        let raw = try require("trackId", \.stringValue)
        if raw == "master" { return .master }
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'trackId' is not a valid UUID: \(raw)")
        }
        return .track(id)
    }

    /// A required filesystem path param: `~`-expanded, and refused unless it is
    /// absolute. The message is the one every path-taking verb already gives
    /// (`instrument.importSoundBank`, `instrument.importSampleLibrary`), lifted
    /// here so the two MIDI-import verbs cannot drift from it.
    func requireAbsolutePath(_ key: String) throws -> String {
        let expanded = (try require(key, \.stringValue) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ControlError("'\(key)' must be an absolute path")
        }
        return expanded
    }

    func requireClipID() throws -> UUID {
        let raw = try require("clipId", \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'clipId' is not a valid UUID: \(raw)")
        }
        return id
    }

    /// Requires a UUID-valued param under an arbitrary key (e.g. clip.crossfade's
    /// `otherClipId`), naming the offending field on a bad value.
    func requireUUID(_ key: String) throws -> UUID {
        let raw = try require(key, \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'\(key)' is not a valid UUID: \(raw)")
        }
        return id
    }

    func requireSendID() throws -> UUID {
        let raw = try require("sendId", \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'sendId' is not a valid UUID: \(raw)")
        }
        return id
    }

    func requireEffectID() throws -> UUID {
        let raw = try require("effectId", \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'effectId' is not a valid UUID: \(raw)")
        }
        return id
    }

    func requireLaneID() throws -> UUID {
        let raw = try require("laneId", \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'laneId' is not a valid UUID: \(raw)")
        }
        return id
    }

    func requireGroupID() throws -> UUID {
        let raw = try require("groupId", \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'groupId' is not a valid UUID: \(raw)")
        }
        return id
    }

    func requireGrooveID() throws -> UUID {
        let raw = try require("grooveId", \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'grooveId' is not a valid UUID: \(raw)")
        }
        return id
    }

    func requireMarkerID() throws -> UUID {
        let raw = try require("markerId", \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'markerId' is not a valid UUID: \(raw)")
        }
        return id
    }
}
