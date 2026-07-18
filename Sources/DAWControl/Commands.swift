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
    /// `scripts/rvc/`). Process management only, same split as
    /// `sidecarManager`/`songGenerator`: `vc.convertVocals`/`vc.trainVoice`
    /// (a later roadmap item) will get their own `VoiceConversionClient`
    /// dependency, kept separate from this one. Defaults to the real
    /// `VoiceConversionManager` resolving `scripts/rvc/` relative to the
    /// repo/executable; tests inject a fake conforming to
    /// `VoiceConversionManaging` instead.
    private let voiceConversionManager: VoiceConversionManaging

    /// Song generation (M6 ii) — defaults to the real `ACEStepClient` talking
    /// to the local sidecar's job-queue REST API; tests inject a fake
    /// conforming to `SongGenerating` instead. Kept separate from
    /// `sidecarManager` (different concerns: process lifecycle vs.
    /// generation jobs) even though both ultimately talk to the same
    /// sidecar process.
    private let songGenerator: SongGenerating

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
        "mixer.setMasterVolume",
        "mixer.applyPreset",
        "mixer.masterAnalysis",
        "engine.performanceStats",
        "engine.watchdogStatus",
        "macro.songSkeleton",
        "automation.addLane",
        "automation.removeLane",
        "automation.setPoints",
        "automation.setLaneEnabled",
        "clip.addAudio",
        "clip.addMIDI",
        "clip.setNotes",
        "clip.remove",
        "clip.split",
        "clip.trim",
        "clip.move",
        "clip.duplicate",
        "clip.setGain",
        "clip.setGainEnvelope",
        "clip.setControllerLane",
        "clip.removeControllerLane",
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
        "midi.listInputs",
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
        "app.feedbackBundle",
        "app.connectionInfo",
        "plugin.openUI",
        "plugin.closeUI",
        "plugin.listOpenUIs",
        "vc.sidecarStatus",
        "vc.sidecarStart",
        "vc.sidecarStop",
    ]

    public init(
        store: ProjectStore,
        sidecarManager: SidecarManaging = SidecarManager(),
        voiceConversionManager: VoiceConversionManaging = VoiceConversionManager(),
        songGenerator: SongGenerating = ACEStepClient(),
        keyStore: APIKeyStoring = KeychainKeyStore(),
        keyEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        connectionInfo: ControlConnectionInfo = ControlConnectionInfo(),
        lyricsWriter: (@MainActor () throws -> any LyricsGenerating)? = nil,
        importGenerator: SongGenerating? = nil
    ) {
        self.store = store
        self.sidecarManager = sidecarManager
        self.voiceConversionManager = voiceConversionManager
        self.songGenerator = songGenerator
        self.keyStore = keyStore
        self.keyEnvironment = keyEnvironment
        self.connectionInfo = connectionInfo
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

        case "track.setVolume":
            try params.rejectUnknownKeys(
                ["trackId", "volume"], verb: "track.setVolume")
            let id = try params.requireTrackID()
            let volume = try params.require("volume", \.doubleValue)
            guard store.setTrackVolume(id: id, volume: volume) else { throw ControlError.noTrack(id) }
            return .success(request.id)

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
            // ranges (like track.setVolume). Optional `sampler` object is a
            // WHOLESALE replacement of the sampler config — see parseSampler; a
            // nonexistent zone file surfaces the MediaImporting-style error. PARTIAL
            // update otherwise: omitted fields keep the track's current descriptor
            // (or .default when it has none). A non-instrument track surfaces
            // instrumentRequiresInstrumentTrack via the LocalizedError mapping;
            // unknown id → noTrack. Response is the resolved instrument object
            // {kind, polySynth:{...}, sampler:{zones:[{path,…}],…}}.
            try params.rejectUnknownKeys(
                ["trackId", "kind", "waveform", "sampler", "attack", "decay", "sustain",
                    "release", "cutoffHz", "resonance", "gain", "audioUnit", "soundBank"], verb: "track.setInstrument")
            let instTrackID = try params.requireTrackID()
            let kind = try parseInstrumentKind(params["kind"])
            let waveform = try parseWaveform(params["waveform"])
            let sampler = try parseSampler(params["sampler"])
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
            return .success(request.id, instrumentJSON(descriptor, trackID: instTrackID))

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
            // No params. GM first, then each scanned dir's *.sf2/*.dls (§6.2).
            // Never errors — an unreadable scan dir is skipped silently. Pure
            // file discovery through the store's injected SoundBankLibrary.
            return .success(request.id, .object([
                "banks": .array(store.availableSoundBanks().map(soundBankInfoJSON)),
            ]))

        case "instrument.listSoundBankPrograms":
            // params: source (required, "gm" or an absolute .sf2/.dls path —
            // STRICTLY validated, naming instrument.listSoundBanks). Response
            // {source, namesParsed, programs:[{program, bankMSB, bankLSB, name,
            // category}]}: the GM table for "gm", parsed SF2 names for a .sf2,
            // generic 0…127 (namesParsed:false) otherwise (§6.3).
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
            // default, unit}]}]}.
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
                            .object([
                                "name": .string(spec.name),
                                "min": .number(spec.range.lowerBound),
                                "max": .number(spec.range.upperBound),
                                "default": .number(spec.defaultValue),
                                "unit": .string(spec.unit),
                            ])
                        }),
                    ])
                }),
            ]))

        case "fx.listAudioUnits":
            // No params. Every installed Audio Unit effect ('aufx') — the
            // instrument.listAudioUnits mirror, same wire shape.
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
            return .success(request.id, .object(["masterVolume": .number(store.masterVolume)]))

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
            return .success(request.id, try JSONValue(encoding: store.masterAnalysis()))

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
            var watchdogPayload = try JSONValue(encoding: store.watchdogStatus())
            if case .object(var watchdogFields) = watchdogPayload {
                watchdogFields["mainActor"] = .object(["responsive": .bool(true)])
                watchdogPayload = .object(watchdogFields)
            }
            return .success(request.id, watchdogPayload)

        case "macro.songSkeleton":
            // params: genre (required — a SongSkeletonCatalog kebab name),
            // tempoBPM? (20-400; default = genre's), sections? (array of
            // {name, bars} — default = genre's layout). Scaffolds the whole
            // session (tempo, a genre track roster with mixer presets applied,
            // an "Arrangement" guide track of named empty MIDI clips, and the
            // loop region) as ONE undoable edit — ADDITIVE, never wiping the
            // project. Unknown genre → an error listing every valid name;
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
            try params.rejectUnknownKeys(
                ["genre", "tempoBPM", "sections"], verb: "macro.songSkeleton")
            guard let genre = params["genre"]?.stringValue else {
                let valid = SongSkeletonCatalog.names.joined(separator: ", ")
                throw ControlError("missing or invalid required param 'genre' — valid: \(valid)")
            }
            let skeletonTempo = params["tempoBPM"]?.doubleValue
            let skeletonSections = try parseSkeletonSections(params["sections"])
            let skeleton = try store.applySongSkeleton(
                genre: genre, tempoBPM: skeletonTempo, sections: skeletonSections)
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
            try params.rejectUnknownKeys(
                ["clipId", "notes"], verb: "clip.setNotes")
            let setClipID = try params.requireClipID()
            guard let setNotesValue = params["notes"] else {
                throw ControlError("missing or invalid required param 'notes'")
            }
            let setNotes = try parseNotes(setNotesValue)
            let updatedClip = try store.setClipNotes(clipID: setClipID, notes: setNotes)
            return .success(request.id, try JSONValue(encoding: updatedClip))

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
            return .success(request.id, try JSONValue(encoding: lanedClip))

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
            // seed? (non-negative integer < 2^53 — omit to draw one). Seeded,
            // DETERMINISTIC "human feel": each note's onset shifts by a uniform
            // amount in [−timingBeats, +timingBeats] (clamped inside the clip) and
            // its velocity by a uniform integer in [−velocityRange, +velocityRange]
            // (clamped 1...127); lengths, ids, and array order are preserved. ONE
            // undoable step ("Humanize"). MIDI clips ONLY — an audio clip surfaces
            // notAMIDIClip verbatim; clipNotFound via the LocalizedError mapping.
            // Response: the updated clip fields PLUS `seedUsed` (the seed actually
            // used — replay it, or a nil `seed`, to reproduce/re-roll the take).
            try params.rejectUnknownKeys(
                ["clipId", "timingBeats", "velocityRange", "seed"], verb: "clip.humanize")
            let humanizeClipID = try params.requireClipID()
            let humanizeTiming = params["timingBeats"]?.doubleValue ?? 0.02
            guard (0...0.25).contains(humanizeTiming) else {
                throw ControlError("'timingBeats' must be between 0 and 0.25 (default 0.02 — max ± onset jitter in beats)")
            }
            let humanizeVelRaw = params["velocityRange"]?.doubleValue ?? 8
            guard (0...64).contains(humanizeVelRaw), humanizeVelRaw == humanizeVelRaw.rounded() else {
                throw ControlError("'velocityRange' must be an integer between 0 and 64 (default 8 — max ± velocity jitter)")
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
                seed: humanizeSeed)
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
            // surfaced verbatim. Response: {path, durationSeconds, sampleRate,
            // channels}.
            try params.rejectUnknownKeys(
                ["path", "fromBeat", "durationSeconds"], verb: "render.mixdown")
            let path = params["path"]?.stringValue
            let fromBeat = params["fromBeat"]?.doubleValue ?? 0
            guard fromBeat >= 0 else {
                throw ControlError("'fromBeat' must be >= 0")
            }
            let durationSeconds = params["durationSeconds"]?.doubleValue
            if let durationSeconds, durationSeconds <= 0 {
                throw ControlError("'durationSeconds' must be > 0")
            }
            let result = try await store.renderMixdown(
                toPath: path, fromBeat: fromBeat, durationSeconds: durationSeconds
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
            // mapping. Response: the model's own BounceResult Codable —
            // {path, durationSeconds, sampleRate, channels, report: {input,
            // output, appliedGainDb, lufsTarget?, truePeakCeilingDbtp,
            // limitedByCeiling}}.
            try params.rejectUnknownKeys(
                ["path", "fromBeat", "durationSeconds", "lufsTarget",
                    "truePeakCeilingDb"], verb: "render.bounce")
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
            let bounceResult = try await store.renderBounce(
                toPath: bouncePath, fromBeat: bounceFromBeat,
                durationSeconds: bounceDurationSeconds,
                lufsTarget: lufsTarget, truePeakCeilingDb: truePeakCeilingDb)
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
            // nothingToRender — all via the LocalizedError mapping. Response:
            // the model's own StemExportResult Codable — {directory,
            // sampleRate, durationSeconds, channels, stems: [{trackId, name,
            // kind: "track"|"bus", path, measurement}], mixdown?: {path,
            // measurement}}.
            try params.rejectUnknownKeys(
                ["trackIds", "directory", "fromBeat", "durationSeconds",
                    "includeMixdown"], verb: "render.stems")
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
            let stemsResult = try await store.renderStems(
                toDirectory: stemsDirectory, trackIds: stemsTrackIDs,
                fromBeat: stemsFromBeat, durationSeconds: stemsDurationSeconds,
                includeMixdown: includeMixdown)
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
            // No params (m16-e, audit F5 survey). Graceful stop (SIGTERM via
            // the pidfile, escalating to SIGKILL if it doesn't exit in time)
            // of a running sidecar; a no-op success (not an error) if it
            // wasn't running. Response: SidecarStatus (state settles to
            // installedNotRunning/notInstalled).
            try params.rejectUnknownKeys([], verb: "ai.sidecarStop")
            let stoppedStatus = try await sidecarManager.stop()
            return .success(request.id, try JSONValue(encoding: stoppedStatus))

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
            let statusJobID = try params.require("jobId", \.stringValue)
            do {
                let status = try await songGenerator.generationStatus(jobID: statusJobID)
                return .success(request.id, try JSONValue(encoding: status))
            } catch {
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

        case "midi.listInputs":
            // No params. MIDI input sources as CoreMIDI enumerates them
            // (hot-plug refreshes the list; the first call may lazily create
            // the engine's MIDI client). Wire shape:
            // {"inputs": [{uniqueID, name, isVirtual, isOnline}, ...]}.
            return .success(request.id, .object([
                "inputs": try JSONValue(encoding: store.listMIDIInputs()),
            ]))

        case "project.snapshot":
            return .success(request.id, try snapshotJSON())

        case "project.overview":
            // No params. Agent-facing summary projection (M7): the same
            // session `project.snapshot` reports at full fidelity, but
            // counts-not-lists everywhere a list can grow unbounded (note
            // counts instead of notes, point counts instead of points) and
            // no file paths — a few KB an agent can afford to re-read on
            // every turn to re-orient. Wire shape mirrors `ProjectOverview`
            // directly (no wrapping key): {transport, master, tracks: [...]}.
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
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            let stateTurnID = params["turnId"]?.stringValue
            return .success(request.id, copilotEngine.stateJSON(turnID: stateTurnID))

        case "ai.copilotReset":
            // Cancels any in-flight turn and clears the transcript/history back
            // to idle. No params (m16-e, audit F5 survey).
            try params.rejectUnknownKeys([], verb: "ai.copilotReset")
            guard let copilotEngine else {
                throw ControlError("copilot engine not wired — app startup incomplete")
            }
            copilotEngine.reset()
            return .success(request.id)

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
            let history = store.undoHistory()
            return .success(request.id, .object([
                "undo": .array(history.undo.map { JSONValue.string($0) }),
                "redo": .array(history.redo.map { JSONValue.string($0) }),
                "canUndo": .bool(history.canUndo),
                "canRedo": .bool(history.canRedo),
            ]))

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
            // phase?, startingForSeconds?}. Additive and independent of
            // ai.sidecarStatus — this is a SECOND, separate local sidecar.
            // This is process-lifecycle management only — voice-conversion/
            // training tools arrive in a later roadmap item.
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
            // No params. Graceful stop (SIGTERM via the pidfile, escalating
            // to SIGKILL if it doesn't exit in time) of a running sidecar; a
            // no-op success (not an error) if it wasn't running. Response:
            // VoiceConversionStatus (state settles to installedNotRunning/
            // notInstalled).
            try params.rejectUnknownKeys([], verb: "vc.sidecarStop")
            let stoppedVCStatus = try await voiceConversionManager.stop()
            return .success(request.id, try JSONValue(encoding: stoppedVCStatus))

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

    /// Wire shape shared by input.listDevices and input.setDevice:
    /// {"devices": [{uid, name, sampleRate, channelCount, isDefault}, ...]}.
    private func inputDeviceList() throws -> JSONValue {
        .object(["devices": try JSONValue(encoding: store.listInputDevices())])
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
    /// `effectsJSON` shape with a MASTER latency resolver (the limiter's 240 @
    /// 48 kHz surfaces here just as it does per strip; 0 headless). Shared by
    /// `masterFxResult` and the snapshot's top-level `masterEffects`.
    private func masterEffectsJSON() -> JSONValue {
        Self.effectsJSON(store.masterEffects) { effectID in
            store.masterEffectLatencySamples(effectID: effectID)
        }
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

    /// Wire shape for `macro.songSkeleton`'s result: the whole scaffold with
    /// real, actionable ids — `{genre, tempoBPM, tracks: [{id, name}],
    /// sectionClips: [{name, startBeat, lengthBeats}], loopStart, loopEnd,
    /// arrangementTrackId}`. `tracks` lists EVERY created track (the genre
    /// roster then the Arrangement guide track LAST, whose id is also surfaced
    /// as `arrangementTrackId`).
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
            "loopStart": .number(result.loopStart),
            "loopEnd": .number(result.loopEnd),
            "arrangementTrackId": .string(result.arrangementTrackID.uuidString),
        ])
    }

    /// Resolved wire JSON for one track's insert chain: `[{id, kind,
    /// isBypassed, params: {name:value}, latencySamples}]`. Params are
    /// RESOLVED (nil structs emit their defaults, the instrument-snapshot
    /// rule). `latencySamples` is the live per-effect engine value forwarded
    /// through the store (the `availableAudioUnits` precedent — DAWControl
    /// itself stays engine-free): 240 @ 48 kHz for the limiter's lookahead,
    /// 0 for the other built-ins or when running headless.
    private func effectsJSON(_ effects: [EffectDescriptor], trackID: UUID) -> JSONValue {
        Self.effectsJSON(effects) { effectID in
            store.effectLatencySamples(trackID: trackID, effectID: effectID)
        }
    }

    /// Shape helper for the above; `latencyFor` supplies each effect's live
    /// latency in samples.
    static func effectsJSON(_ effects: [EffectDescriptor],
                            latencyFor: (UUID) -> Int) -> JSONValue {
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
            ])
        case .limiter:
            let limiter = effect.resolvedLimiter
            return .object([
                "ceilingDb": .number(limiter.ceilingDb),
                "releaseMs": .number(limiter.releaseMs),
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

    /// Parses a `clipIds` param into `[UUID]`, with a per-index error naming the
    /// offending element — the `parseNotes`/`parseAutomationPoints` precedent.
    /// Shared by `take.group`. Does not itself enforce the >= 2 minimum (the
    /// store's `cannotGroup` message owns that so it stays a single source of
    /// truth).
    private func parseClipIDs(_ value: JSONValue?) throws -> [UUID] {
        guard let array = value?.arrayValue else {
            throw ControlError("'clipIds' must be an array of clip id strings (at least 2, to form a take group)")
        }
        var ids: [UUID] = []
        ids.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let raw = element.stringValue, let id = UUID(uuidString: raw) else {
                throw ControlError("clipIds[\(i)] is not a valid UUID")
            }
            ids.append(id)
        }
        return ids
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

    /// Parses the optional `trackIds` param (`render.stems`) into `[UUID]?` —
    /// absent → nil ("every master input"); present validates each element
    /// with a per-index error naming the offending element (the `parseClipIDs`
    /// precedent). A present-but-empty array passes through as `Optional([])`
    /// (distinct from nil): the store's `StemPlan.descriptors` then selects
    /// zero stems and `renderStems` surfaces `nothingToRender`, the same
    /// single source of truth as a project with no clips.
    private func parseOptionalTrackIDs(_ value: JSONValue?) throws -> [UUID]? {
        guard let value else { return nil }
        guard let array = value.arrayValue else {
            throw ControlError("'trackIds' must be an array of track id strings")
        }
        var ids: [UUID] = []
        ids.reserveCapacity(array.count)
        for (i, element) in array.enumerated() {
            guard let raw = element.stringValue, let id = UUID(uuidString: raw) else {
                throw ControlError("trackIds[\(i)] is not a valid UUID")
            }
            ids.append(id)
        }
        return ids
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
    private func parseSampler(_ value: JSONValue?) throws -> SamplerParams? {
        guard let value else { return nil }
        guard case .object(let obj) = value else {
            throw ControlError("sampler must be an object {zones, oneShot?, attack?, release?, gain?}")
        }
        var zones: [SamplerZone] = []
        if let zonesValue = obj["zones"] {
            guard case .array(let array) = zonesValue else {
                throw ControlError("sampler.zones must be an array")
            }
            for (i, element) in array.enumerated() {
                guard case .object(let zone) = element else {
                    throw ControlError("sampler.zones[\(i)] must be an object")
                }
                guard let rawPath = zone["path"]?.stringValue else {
                    throw ControlError("sampler.zones[\(i)].path is required")
                }
                let path = (rawPath as NSString).expandingTildeInPath
                let root = try Self.optionalPitch(zone["rootPitch"], "sampler.zones[\(i)].rootPitch")
                let lo = try Self.optionalPitch(zone["minPitch"], "sampler.zones[\(i)].minPitch")
                let hi = try Self.optionalPitch(zone["maxPitch"], "sampler.zones[\(i)].maxPitch")
                let zoneGain = try Self.optionalNumber(zone["gain"], "sampler.zones[\(i)].gain")
                let minVel = try Self.optionalPitch(
                    zone["minVelocity"], "sampler.zones[\(i)].minVelocity")
                let maxVel = try Self.optionalPitch(
                    zone["maxVelocity"], "sampler.zones[\(i)].maxVelocity")
                let group = try Self.optionalInteger(zone["group"], "sampler.zones[\(i)].group")
                let seqLength = try Self.optionalInteger(
                    zone["seqLength"], "sampler.zones[\(i)].seqLength")
                let seqPosition = try Self.optionalInteger(
                    zone["seqPosition"], "sampler.zones[\(i)].seqPosition")
                let randMin = try Self.optionalNumber(
                    zone["randMin"], "sampler.zones[\(i)].randMin")
                let randMax = try Self.optionalNumber(
                    zone["randMax"], "sampler.zones[\(i)].randMax")
                let tuneCents = try Self.optionalNumber(
                    zone["tuneCents"], "sampler.zones[\(i)].tuneCents")
                let pan = try Self.optionalNumber(zone["pan"], "sampler.zones[\(i)].pan")
                let ampVelTrack = try Self.optionalNumber(
                    zone["ampVelTrack"], "sampler.zones[\(i)].ampVelTrack")
                let zoneOneShot = try Self.optionalBool(
                    zone["oneShot"], "sampler.zones[\(i)].oneShot")
                let startFrame = try Self.optionalInteger(
                    zone["startFrame"], "sampler.zones[\(i)].startFrame")
                let endFrame = try Self.optionalInteger(
                    zone["endFrame"], "sampler.zones[\(i)].endFrame")
                let zoneAttack = try Self.optionalNumber(
                    zone["attack"], "sampler.zones[\(i)].attack")
                let zoneDecay = try Self.optionalNumber(
                    zone["decay"], "sampler.zones[\(i)].decay")
                let zoneSustain = try Self.optionalNumber(
                    zone["sustain"], "sampler.zones[\(i)].sustain")
                let zoneRelease = try Self.optionalNumber(
                    zone["release"], "sampler.zones[\(i)].release")
                var loopMode: SamplerLoopMode?
                if let loopModeValue = zone["loopMode"] {
                    guard let raw = loopModeValue.stringValue,
                          let mode = SamplerLoopMode(rawValue: raw) else {
                        throw ControlError(
                            "sampler.zones[\(i)].loopMode must be \"sustain\" or \"continuous\"")
                    }
                    loopMode = mode
                }
                let loopStart = try Self.optionalInteger(
                    zone["loopStart"], "sampler.zones[\(i)].loopStart")
                let loopEnd = try Self.optionalInteger(
                    zone["loopEnd"], "sampler.zones[\(i)].loopEnd")
                zones.append(SamplerZone(
                    audioFileURL: URL(fileURLWithPath: path),
                    rootPitch: root ?? 60,
                    minPitch: lo ?? 0,
                    maxPitch: hi ?? 127,
                    gain: zoneGain ?? 1,
                    minVelocity: minVel,
                    maxVelocity: maxVel,
                    group: group,
                    seqLength: seqLength,
                    seqPosition: seqPosition,
                    randMin: randMin,
                    randMax: randMax,
                    tuneCents: tuneCents,
                    pan: pan,
                    ampVelTrack: ampVelTrack,
                    oneShot: zoneOneShot,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    attack: zoneAttack,
                    decay: zoneDecay,
                    sustain: zoneSustain,
                    release: zoneRelease,
                    loopMode: loopMode,
                    loopStart: loopStart,
                    loopEnd: loopEnd
                ))
            }
        }
        let oneShot: Bool
        switch obj["oneShot"] {
        case .none: oneShot = false
        case .some(.bool(let b)): oneShot = b
        case .some: throw ControlError("sampler.oneShot must be a boolean")
        }
        return SamplerParams(
            zones: zones,
            oneShot: oneShot,
            attack: try Self.optionalNumber(obj["attack"], "sampler.attack") ?? 0.001,
            release: try Self.optionalNumber(obj["release"], "sampler.release") ?? 0.05,
            gain: try Self.optionalNumber(obj["gain"], "sampler.gain") ?? 0.8
        )
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
        guard ext == "sf2" || ext == "dls" else {
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

    /// Wire JSON for a `SoundBankInfo` (§6.2/§6.4 shape).
    private func soundBankInfoJSON(_ info: SoundBankInfo) -> JSONValue {
        .object([
            "source": .string(info.source.rawString),
            "name": .string(info.name),
            "path": .string(info.path),
            "format": .string(info.format),
            "builtin": .bool(info.builtin),
            "sizeBytes": .number(Double(info.sizeBytes)),
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
    /// track's RESOLVED insert chain (`{id, kind, isBypassed, params, latencySamples}`).
    /// Audio/bus tracks keep their (omitted) instrument.
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
    private func instrumentStatusString(_ trackID: UUID) -> String {
        switch store.audioUnitStatus(forTrack: trackID) ?? .pending {
        case .pending: return "pending"
        case .ready: return "ready"
        case .missing: return "missing"
        case .failed(let reason): return "failed: \(reason)"
        }
    }

    /// Wire JSON for a resolved instrument descriptor: `polySynth` verbatim plus
    /// the resolved `sampler` (always present on an instrument track), whose zones
    /// emit `path` (a filesystem path string, the same convention as clip audio)
    /// instead of the model's `audioFileURL` URL.
    static func instrumentJSON(_ d: InstrumentDescriptor) -> JSONValue {
        let poly = d.polySynth
        let sampler = d.resolvedSampler
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
            "sampler": .object([
                "zones": .array(sampler.zones.map { zone -> JSONValue in
                    // m19-a selection fields are emitted only when SET, so a
                    // legacy zone's wire shape is byte-identical to pre-m19
                    // (and agents read back exactly what they configured).
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
                    return .object(object)
                }),
                "oneShot": .bool(sampler.oneShot),
                "attack": .number(sampler.attack),
                "release": .number(sampler.release),
                "gain": .number(sampler.gain),
            ]),
        ])
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
    func rejectUnknownKeys(_ allowed: Set<String>, verb: String, hint: String? = nil) throws {
        let unknown = keys.filter { !allowed.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }
        let named = unknown.map { "'\($0)'" }.joined(separator: ", ")
        let valid = allowed.sorted().map { "'\($0)'" }.joined(separator: ", ")
        var message = "\(verb): unknown parameter\(unknown.count > 1 ? "s" : "") \(named) — valid keys are \(valid)"
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
