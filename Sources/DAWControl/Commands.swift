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

    /// Song generation (M6 ii) — defaults to the real `ACEStepClient` talking
    /// to the local sidecar's job-queue REST API; tests inject a fake
    /// conforming to `SongGenerating` instead. Kept separate from
    /// `sidecarManager` (different concerns: process lifecycle vs.
    /// generation jobs) even though both ultimately talk to the same
    /// sidecar process.
    private let songGenerator: SongGenerating

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

    public static let allCommands: [String] = [
        "transport.play",
        "transport.stop",
        "transport.seek",
        "transport.setTempo",
        "transport.setLoop",
        "transport.setPunch",
        "transport.setMetronome",
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
        "fx.add",
        "fx.remove",
        "fx.reorder",
        "fx.setBypass",
        "fx.setParam",
        "fx.describe",
        "fx.listAudioUnits",
        "instrument.listAudioUnits",
        "mixer.setMasterVolume",
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
        "clip.setGain",
        "clip.setFades",
        "clip.setStretch",
        "clip.stretchToLength",
        "clip.quantize",
        "clip.detectTransients",
        "clip.quantizeAudio",
        "take.group",
        "take.setComp",
        "take.select",
        "take.removeLane",
        "take.flatten",
        "take.move",
        "take.setCrossfade",
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
        "project.snapshot",
        "input.listDevices",
        "input.setDevice",
        "midi.listInputs",
        "transport.record",
        "track.setArm",
        "project.save",
        "project.open",
        "project.new",
        "edit.undo",
        "edit.redo",
    ]

    public init(
        store: ProjectStore,
        sidecarManager: SidecarManaging = SidecarManager(),
        songGenerator: SongGenerating = ACEStepClient()
    ) {
        self.store = store
        self.sidecarManager = sidecarManager
        self.songGenerator = songGenerator
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
            store.play()
            return .success(request.id)

        case "transport.stop":
            store.stop()
            return .success(request.id)

        case "transport.seek":
            let beats = try params.require("beats", \.doubleValue)
            // transportBusy while recording surfaces via LocalizedError mapping.
            try store.seek(toBeats: beats)
            return .success(request.id)

        case "transport.setTempo":
            let bpm = try params.require("bpm", \.doubleValue)
            try store.setTempo(bpm)
            return .success(request.id, .number(store.transport.tempoBPM))

        case "transport.record":
            // Starts one take on every armed audio AND instrument track
            // (track.setArm works on both). Punch windows trim AUDIO capture
            // only — MIDI notes record across the full roll (v0; notes are
            // individually editable after the fact). Microphone permission
            // gates apply only when audio tracks are armed.
            try store.record()
            return .success(request.id, try JSONValue(encoding: store.transport))

        case "transport.setLoop":
            // (params: enabled bool, startBeat number, endBeat number).
            // Being added in parallel — do not duplicate here.
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
            let metronomeEnabled = try params.require("enabled", \.boolValue)
            let countInBars = params["countInBars"]?.doubleValue.map { Int($0) }
            try store.setMetronome(enabled: metronomeEnabled, countInBars: countInBars)
            return .success(request.id, try JSONValue(encoding: store.transport))

        case "track.add":
            let name = params["name"]?.stringValue
            let kindRaw = params["kind"]?.stringValue ?? TrackKind.audio.rawValue
            guard let kind = TrackKind(rawValue: kindRaw) else {
                throw ControlError("unknown track kind '\(kindRaw)' — use audio|instrument|bus")
            }
            let track = store.addTrack(name: name, kind: kind)
            return .success(request.id, try JSONValue(encoding: track))

        case "track.remove":
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
            guard store.removeTrack(id: id) else { throw ControlError.noTrack(id) }
            if let reroutedCounts {
                return .success(request.id, .object(["rerouted": .object([
                    "outputs": .number(Double(reroutedCounts.outputs)),
                    "sends": .number(Double(reroutedCounts.sends)),
                ])]))
            }
            return .success(request.id)

        case "track.rename":
            let id = try params.requireTrackID()
            let name = try params.require("name", \.stringValue)
            guard store.renameTrack(id: id, name: name) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "track.setVolume":
            let id = try params.requireTrackID()
            let volume = try params.require("volume", \.doubleValue)
            guard store.setTrackVolume(id: id, volume: volume) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "track.setPan":
            let id = try params.requireTrackID()
            let pan = try params.require("pan", \.doubleValue)
            guard store.setTrackPan(id: id, pan: pan) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "track.setMute":
            let id = try params.requireTrackID()
            let muted = try params.require("muted", \.boolValue)
            guard store.setTrackMute(id: id, muted: muted) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "track.setSolo":
            let id = try params.requireTrackID()
            let soloed = try params.require("soloed", \.boolValue)
            guard store.setTrackSolo(id: id, soloed: soloed) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "track.setOutput":
            // params: trackId (required), busId string|null|omitted (null/omitted
            // = master — exact input.setDevice pattern; non-string/non-null →
            // 'busId' must be a string or null). busRoutingFixed/notABus/
            // trackNotFound surface via the LocalizedError mapping.
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
            let setSendTrackID = try params.requireTrackID()
            let setSendID = try params.requireSendID()
            let sendLevel = try params.require("level", \.doubleValue)
            _ = try store.setSendLevel(trackID: setSendTrackID, sendID: setSendID, level: sendLevel)
            return .success(request.id, routingResult(trackID: setSendTrackID))

        case "track.removeSend":
            // params: trackId (required), sendId (required UUID). sendNotFound/
            // busRoutingFixed/trackNotFound surface via the LocalizedError mapping.
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
            let instTrackID = try params.requireTrackID()
            let kind = try parseInstrumentKind(params["kind"])
            let waveform = try parseWaveform(params["waveform"])
            let sampler = try parseSampler(params["sampler"])
            // Optional `audioUnit: {type?, subType, manufacturer}` (type
            // defaults "aumu"): STRICT selection — resolved against the
            // installed list, unknown components error readably. Providing it
            // implies kind audioUnit when kind is omitted.
            let audioUnit = try parseAudioUnit(params["audioUnit"])
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
                audioUnit: audioUnit
            ) else { throw ControlError.noTrack(instTrackID) }
            return .success(request.id, instrumentJSON(descriptor, trackID: instTrackID))

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

        case "fx.add":
            // params: trackId (required), kind (required, one of the effect
            // kinds), index? (int, clamps into [0, chain length]), params?
            // (object of name:value, clamped silently via EffectParamSpec — an
            // unknown name errors before anything is added). Returns {effectId,
            // effects}. Unknown kind lists valid kinds; chainFull/trackNotFound
            // surface via the LocalizedError mapping.
            let fxAddTrackID = try params.requireTrackID()
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

        case "fx.remove":
            // params: trackId (required), effectId (required UUID). effectNotFound/
            // trackNotFound surface via the LocalizedError mapping.
            let fxRemTrackID = try params.requireTrackID()
            let fxRemEffectID = try params.requireEffectID()
            try store.removeEffect(trackID: fxRemTrackID, effectID: fxRemEffectID)
            return .success(request.id, fxResult(trackID: fxRemTrackID))

        case "fx.reorder":
            // params: trackId (required), effectId (required UUID), index
            // (required int, clamps into the valid range). effectNotFound/
            // trackNotFound surface via the LocalizedError mapping.
            let fxReoTrackID = try params.requireTrackID()
            let fxReoEffectID = try params.requireEffectID()
            let fxReoIndex = try params.require("index", \.doubleValue)
            try store.reorderEffect(trackID: fxReoTrackID, effectID: fxReoEffectID,
                                    toIndex: Int(fxReoIndex))
            return .success(request.id, fxResult(trackID: fxReoTrackID))

        case "fx.setBypass":
            // params: trackId (required), effectId (required UUID), bypassed
            // (required bool). effectNotFound/trackNotFound surface via the
            // LocalizedError mapping.
            let fxBypTrackID = try params.requireTrackID()
            let fxBypEffectID = try params.requireEffectID()
            let fxBypassed = try params.require("bypassed", \.boolValue)
            try store.setEffectBypassed(trackID: fxBypTrackID, effectID: fxBypEffectID,
                                        bypassed: fxBypassed)
            return .success(request.id, fxResult(trackID: fxBypTrackID))

        case "fx.setParam":
            // params: trackId (required), effectId (required UUID), name (required
            // string), value (required number, clamps silently through the spec
            // range like track.setVolume). An unknown name surfaces
            // unknownEffectParam (listing the valid names); effectNotFound/
            // trackNotFound also surface via the LocalizedError mapping.
            let fxParTrackID = try params.requireTrackID()
            let fxParEffectID = try params.requireEffectID()
            let fxParName = try params.require("name", \.stringValue)
            let fxParValue = try params.require("value", \.doubleValue)
            let fxParDescriptor = try store.setEffectParam(
                trackID: fxParTrackID, effectID: fxParEffectID, name: fxParName, value: fxParValue)
            return .success(request.id, fxResult(trackID: fxParTrackID, effectID: fxParDescriptor.id))

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
            let id = try params.requireTrackID()
            let armed = try params.require("armed", \.boolValue)
            guard try store.setTrackArm(id: id, armed: armed) else { throw ControlError.noTrack(id) }
            return .success(request.id)

        case "mixer.setMasterVolume":
            let volume = try params.require("volume", \.doubleValue)
            store.setMasterVolume(volume)
            return .success(request.id, .object(["masterVolume": .number(store.masterVolume)]))

        case "automation.addLane":
            // params: trackId (required), target (required) — the SAME
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
            // unknown track → trackNotFound. Both surface via the LocalizedError
            // mapping. Response: {"lane": {id, target, points, isEnabled}}.
            let addLaneTrackID = try params.requireTrackID()
            let addLaneTarget = try parseAutomationTarget(params["target"])
            let addedLane = try store.addAutomationLane(trackID: addLaneTrackID, target: addLaneTarget)
            return .success(request.id, .object(["lane": try JSONValue(encoding: addedLane)]))

        case "automation.removeLane":
            // params: trackId (required), laneId (required UUID).
            // automationLaneNotFound/trackNotFound surface via the
            // LocalizedError mapping.
            let removeLaneTrackID = try params.requireTrackID()
            let removeLaneID = try params.requireLaneID()
            try store.removeAutomationLane(trackID: removeLaneTrackID, laneID: removeLaneID)
            return .success(request.id)

        case "automation.setPoints":
            // params: trackId (required), laneId (required UUID), points
            // (required array of {beat >= 0, value, curve?} — see
            // parseAutomationPoints, which decodes each element through
            // AutomationPoint's OWN Codable so a malformed entry names its
            // index; an omitted curve defaults "linear"). WHOLE-ARRAY replace
            // (the clip-notes precedent) — the store re-canonicalizes (sorted
            // by beat, equal-beat dedupe last-wins), clamps every value to the
            // target's live range, and trims silently to the newest 4096
            // points when the array is over cap. automationLaneNotFound/
            // trackNotFound surface via the LocalizedError mapping. Response:
            // {"lane": {id, target, points, isEnabled}}.
            let setPointsTrackID = try params.requireTrackID()
            let setPointsLaneID = try params.requireLaneID()
            guard let rawPoints = params["points"] else {
                throw ControlError("missing or invalid required param 'points'")
            }
            let parsedPoints = try parseAutomationPoints(rawPoints)
            let pointedLane = try store.setAutomationPoints(
                trackID: setPointsTrackID, laneID: setPointsLaneID, points: parsedPoints)
            return .success(request.id, .object(["lane": try JSONValue(encoding: pointedLane)]))

        case "automation.setLaneEnabled":
            // params: trackId (required), laneId (required UUID), enabled
            // (required bool) — toggles the lane between read (drawn curve)
            // and manual (fader/knob) without touching its points.
            // automationLaneNotFound/trackNotFound surface via the
            // LocalizedError mapping. Response: {"lane": {...}}.
            let setEnabledTrackID = try params.requireTrackID()
            let setEnabledLaneID = try params.requireLaneID()
            let laneEnabled = try params.require("enabled", \.boolValue)
            let enabledLane = try store.setAutomationLaneEnabled(
                trackID: setEnabledTrackID, laneID: setEnabledLaneID, laneEnabled)
            return .success(request.id, .object(["lane": try JSONValue(encoding: enabledLane)]))

        case "clip.addAudio":
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
            // trackNotFound/clipNotFound surface via the LocalizedError
            // mapping. Response: the updated clip.
            let moveTrackID = try params.requireTrackID()
            let moveClipID = try params.requireClipID()
            let moveToStartBeat = try params.require("toStartBeat", \.doubleValue)
            let movedClip = try store.moveClip(
                trackId: moveTrackID, clipId: moveClipID, toStartBeat: moveToStartBeat)
            return .success(request.id, try JSONValue(encoding: movedClip))

        case "clip.setGain":
            // params: trackId (required), clipId (required), gainDb
            // (required, clamped to Clip.gainDbRange -72...24). Coalesces
            // under clip.gain:<clipId> so a knob scrub is one undo step.
            // trackNotFound/clipNotFound surface via the LocalizedError
            // mapping. Response: the updated clip.
            let gainTrackID = try params.requireTrackID()
            let gainClipID = try params.requireClipID()
            let gainDb = try params.require("gainDb", \.doubleValue)
            let gainedClip = try store.setClipGain(
                trackId: gainTrackID, clipId: gainClipID, gainDb: gainDb)
            return .success(request.id, try JSONValue(encoding: gainedClip))

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
            let stretchLenTrackID = try params.requireTrackID()
            let stretchLenClipID = try params.requireClipID()
            let stretchToLength = try params.require("lengthBeats", \.doubleValue)
            let stretchedToLenClip = try store.stretchClip(
                trackId: stretchLenTrackID, clipId: stretchLenClipID,
                toLengthBeats: stretchToLength)
            return .success(request.id, try JSONValue(encoding: stretchedToLenClip))

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
            let quantizeClipID = try params.requireClipID()
            let quantizeSettings = try parseQuantizeSettings(params)
            let quantizedClip = try store.quantizeClipNotes(
                clipId: quantizeClipID, settings: quantizeSettings)
            return .success(request.id, try JSONValue(encoding: quantizedClip))

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
            let aqTrackID = try params.requireTrackID()
            let aqClipID = try params.requireClipID()
            let aqSettings = try parseAudioQuantizeSettings(params)
            let aqSlices = try await store.quantizeAudioClip(
                trackId: aqTrackID, clipId: aqClipID, settings: aqSettings)
            return .success(request.id, .object(["clips": try JSONValue(encoding: aqSlices)]))

        case "take.group":
            // params: trackId (required), clipIds (required array of >= 2 clip id
            // strings), name? (string). Forms a take group from EXISTING
            // OVERLAPPING clips on the track (all audio or all MIDI, mixed
            // rejected) — the source clips are consumed into lanes (oldest =
            // lane 0) and removed from track.clips; the comp defaults to the
            // newest lane across the full range (newest wins). cannotGroup/
            // clipNotFound/trackNotFound surface via the LocalizedError mapping.
            // Response: {"group": {...}}.
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
            let xfTrackID = try params.requireTrackID()
            let xfGroupID = try params.requireGroupID()
            let xfSeconds = try params.require("seconds", \.doubleValue)
            let xfGroup = try store.setTakeCrossfade(
                trackId: xfTrackID, groupId: xfGroupID, seconds: xfSeconds)
            return .success(request.id, .object([
                "group": try JSONValue(encoding: xfGroup),
                "clips": try memberClipsJSON(trackID: xfTrackID, groupID: xfGroupID),
            ]))

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
            let removeGrooveID = try params.requireGrooveID()
            try store.removeGrooveTemplate(id: removeGrooveID)
            return .success(request.id, .object(["removed": .bool(true)]))

        case "render.mixdown":
            // path optional (absolute or ~-prefixed .wav destination; the store
            // supplies a temp-dir default), fromBeat >= 0, durationSeconds > 0.
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
            // extent of ALL tracks' clips — audio AND instrument, deliberately
            // broader than render.mixdown's audio-only legacy default — plus a
            // 2.0 s bus-reverb/release tail, spec §4.3). Renders OFFLINE and
            // measures (BS.1770-4 integrated + max momentary/short-term + 4×
            // oversampled true peak) — NOTHING is written to disk, unlike
            // render.bounce. nil measurement fields mean the program sits below
            // the -70 LUFS gate (JSON has no -inf; nil is the honest encoding).
            // nothingToRender/engineUnavailable surface via the LocalizedError
            // mapping. Response: the model's own LoudnessMeasureResult Codable
            // — {measurement: {integratedLufs?, truePeakDbtp?,
            // maxMomentaryLufs?, maxShortTermLufs?}, durationSeconds, sampleRate}.
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
            // populated only when healthy. Response: the model's own
            // SidecarStatus Codable (AIServices) — {state, message, version?,
            // ditModel?, lmModel?, pid?}. This is process-lifecycle
            // management only — the generation client/tools arrive in a
            // later roadmap item.
            let sidecarStatus = await sidecarManager.status()
            return .success(request.id, try JSONValue(encoding: sidecarStatus))

        case "ai.sidecarStart":
            // No params. Spawns scripts/ace-step/run.sh (loopback-only
            // FastAPI server) if not already healthy, then polls /health up
            // to a startup timeout. Throws notInstalled (verbatim, points at
            // install.sh) if the sidecar was never installed, or a launch
            // error if the process exits during startup. A timeout without
            // reaching healthy is NOT an error — it returns state "starting"
            // (model loading can legitimately take a while); poll
            // ai.sidecarStatus again. Response: SidecarStatus.
            let startedStatus = try await sidecarManager.start()
            return .success(request.id, try JSONValue(encoding: startedStatus))

        case "ai.sidecarStop":
            // No params. Graceful stop (SIGTERM via the pidfile, escalating
            // to SIGKILL if it doesn't exit in time) of a running sidecar;
            // a no-op success (not an error) if it wasn't running. Response:
            // SidecarStatus (state settles to installedNotRunning/notInstalled).
            let stoppedStatus = try await sidecarManager.stop()
            return .success(request.id, try JSONValue(encoding: stoppedStatus))

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

        case "input.listDevices":
            return .success(request.id, try inputDeviceList())

        case "input.setDevice":
            // uid: string | null | omitted — null/omitted = system default.
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

        // in mcp-server/src/index.ts (see /mcp-verify) — matching these routes.
        case "project.save":
            // path optional: absolute or ~-prefixed .dawproj destination; omit
            // to save in place (an untitled session throws projectPathRequired).
            // transportBusy/saveFailed surface via the LocalizedError mapping.
            let savePath = params["path"]?.stringValue
            let result = try store.saveProject(to: savePath)
            return .success(request.id, try JSONValue(encoding: result))

        case "project.open":
            // path required. discardChanges (default false) abandons unsaved
            // edits instead of flushing them first. Returns the media warnings
            // plus the full post-open snapshot. transportBusy/openFailed/
            // malformedProject/newerProjectVersion/unsavedChanges surface via the
            // LocalizedError mapping.
            let openPath = try params.require("path", \.stringValue)
            let discard = params["discardChanges"]?.boolValue ?? false
            let warnings = try store.openProject(at: openPath, discardChanges: discard)
            return .success(request.id, .object([
                "warnings": .array(warnings.map(JSONValue.string)),
                "snapshot": try snapshotJSON(),
            ]))

        case "project.new":
            // discardChanges (default false) abandons unsaved edits instead of
            // flushing them first. transportBusy/unsavedChanges surface via the
            // LocalizedError mapping.
            let discardNew = params["discardChanges"]?.boolValue ?? false
            try store.newProject(discardChanges: discardNew)
            return .success(request.id, try snapshotJSON())

        case "edit.undo":
            // Reverses the last edit. nothingToUndo/transportBusy surface via the
            // LocalizedError mapping. Result carries the reversed label plus the
            // full post-undo snapshot so agents re-orient in one round trip.
            let label = try store.undo()
            return .success(request.id, .object([
                "undone": .string(label),
                "snapshot": try snapshotJSON(),
            ]))

        case "edit.redo":
            // Reapplies the last undone edit; mirror of edit.undo.
            let label = try store.redo()
            return .success(request.id, .object([
                "redone": .string(label),
                "snapshot": try snapshotJSON(),
            ]))

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
            .object([
                "id": .string(effect.id.uuidString),
                "kind": .string(effect.kind.rawValue),
                "isBypassed": .bool(effect.isBypassed),
                "params": effectParamsJSON(effect),
                "latencySamples": .number(Double(latencyFor(effect.id))),
            ])
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

    /// True when `value` is a finite whole number (no fractional part) — the
    /// integer check for pitch and velocity, since JSON carries them as doubles.
    private static func isInteger(_ value: Double) -> Bool {
        value.isFinite && value.rounded() == value
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
    private func parseQuantizeSettings(_ params: [String: JSONValue]) throws -> QuantizeSettings {
        let gridBeats = try params.require("gridBeats", \.doubleValue)
        guard gridBeats > 0 else {
            throw ControlError("'gridBeats' must be greater than 0 (beats: 1 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16)")
        }
        let strength = params["strength"]?.doubleValue ?? 1
        guard (0...1).contains(strength) else {
            throw ControlError("'strength' must be between 0 and 1 (1 = snap fully, 0.5 = halfway, 0 = leave notes)")
        }
        let swing = params["swing"]?.doubleValue ?? 50
        guard (50...75).contains(swing) else {
            throw ControlError("'swing' must be between 50 and 75 (50 = straight, 75 = max MPC shuffle)")
        }
        let quantizeEnds = params["quantizeEnds"]?.boolValue ?? false
        let groove = try resolveGrooveParam(params["groove"])
        return QuantizeSettings(gridBeats: gridBeats, strength: strength,
                                swingPercent: swing, quantizeEnds: quantizeEnds,
                                groove: groove)
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
    /// iii-g seam.
    private func parseAudioQuantizeSettings(_ params: [String: JSONValue]) throws -> AudioQuantizeSettings {
        let gridBeats = try params.require("gridBeats", \.doubleValue)
        guard gridBeats > 0 else {
            throw ControlError("'gridBeats' must be greater than 0 (beats: 1 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16)")
        }
        let strength = params["strength"]?.doubleValue ?? 1
        guard (0...1).contains(strength) else {
            throw ControlError("'strength' must be between 0 and 1 (1 = snap fully, 0.5 = halfway, 0 = leave slices)")
        }
        let swing = params["swing"]?.doubleValue ?? 50
        guard (50...75).contains(swing) else {
            throw ControlError("'swing' must be between 50 and 75 (50 = straight, 75 = max MPC shuffle)")
        }
        let sensitivity = params["sensitivity"]?.doubleValue ?? 0.5
        guard (0...1).contains(sensitivity) else {
            throw ControlError("'sensitivity' must be between 0 and 1 (0.5 = default; higher finds more onsets)")
        }
        let crossfadeMs = params["crossfadeMs"]?.doubleValue ?? 10
        guard (0...50).contains(crossfadeMs) else {
            throw ControlError("'crossfadeMs' must be between 0 and 50 (default 10 — join crossfade width in milliseconds)")
        }
        let groove = try resolveGrooveParam(params["groove"])
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
                zones.append(SamplerZone(
                    audioFileURL: URL(fileURLWithPath: path),
                    rootPitch: root ?? 60,
                    minPitch: lo ?? 0,
                    maxPitch: hi ?? 127,
                    gain: zoneGain ?? 1
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
        // Project-level totals: stage maxima, the global path latency, and
        // the ruler-to-speaker output latency (= maxPath + master chain; the
        // master strip carries no chain today, so the two coincide).
        root["pdc"] = .object([
            "trackStageSamples": .number(Double(pdc?.trackStageSamples ?? 0)),
            "busStageSamples": .number(Double(pdc?.busStageSamples ?? 0)),
            "maxPathLatencySamples": .number(Double(pdc?.maxPathLatencySamples ?? 0)),
            "outputLatencySamples": .number(Double(pdc?.outputLatencySamples ?? 0)),
        ])
        return .object(root)
    }

    /// The base instrument wire JSON plus, for kind audioUnit, the resolved
    /// "audioUnit" object {type, subType, manufacturer, name, manufacturerName,
    /// status}. `status` comes from the store's engine forwarder ("pending"
    /// until the engine reports); stateData NEVER travels on the wire.
    private func instrumentJSON(_ d: InstrumentDescriptor, trackID: UUID) -> JSONValue {
        guard d.kind == .audioUnit, let config = d.audioUnit,
              case .object(var obj) = Self.instrumentJSON(d) else {
            return Self.instrumentJSON(d)
        }
        let status = store.audioUnitStatus(forTrack: trackID) ?? .pending
        let statusString: String
        switch status {
        case .pending: statusString = "pending"
        case .ready: statusString = "ready"
        case .missing: statusString = "missing"
        case .failed(let reason): statusString = "failed: \(reason)"
        }
        obj["audioUnit"] = .object([
            "type": .string(config.component.type),
            "subType": .string(config.component.subType),
            "manufacturer": .string(config.component.manufacturer),
            "name": .string(config.name),
            "manufacturerName": .string(config.manufacturerName),
            "status": .string(statusString),
        ])
        return .object(obj)
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
                "zones": .array(sampler.zones.map { zone in
                    .object([
                        "id": .string(zone.id.uuidString),
                        "path": .string(zone.audioFileURL.path),
                        "rootPitch": .number(Double(zone.rootPitch)),
                        "minPitch": .number(Double(zone.minPitch)),
                        "maxPitch": .number(Double(zone.maxPitch)),
                        "gain": .number(zone.gain),
                    ])
                }),
                "oneShot": .bool(sampler.oneShot),
                "attack": .number(sampler.attack),
                "release": .number(sampler.release),
                "gain": .number(sampler.gain),
            ]),
        ])
    }
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

    func requireTrackID() throws -> UUID {
        let raw = try require("trackId", \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'trackId' is not a valid UUID: \(raw)")
        }
        return id
    }

    func requireClipID() throws -> UUID {
        let raw = try require("clipId", \.stringValue)
        guard let id = UUID(uuidString: raw) else {
            throw ControlError("'clipId' is not a valid UUID: \(raw)")
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
}
