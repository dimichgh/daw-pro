// DemoRender — the headless engine of `scripts/demos/render-variants.mjs`.
//
// WHY THIS EXISTS: the demo-render harness's job is "turn a JSON spec into a
// set of listenable .wav variants," and that job must survive a night with
// nobody watching. `swift run DAWApp` is a SwiftUI app — it wants a window
// server, and this repo has already seen a GUI-adjacent path wedge the main
// actor for minutes (see the AU-hosting lore). So THIS target renders through
// the exact same offline path `render.mixdown` uses in production
// (`ProjectStore.renderMixdown` -> `AudioEngine.renderMixdown` ->
// `OfflineRenderer` in `.offline` manual-rendering mode) with no control
// port, no WebSocket, no NSApplication — precisely the recipe
// `Tests/DAWCoreTests/MixdownTests.swift` and
// `Tests/DAWEngineTests/FXPack1Tests.swift` already exercise headlessly on
// this machine, hundreds of times, in CI-shaped conditions.
//
// DEPENDENCY FLOOR IS DELIBERATE: this target depends on DAWCore + DAWEngine
// ONLY — never DAWControl, never DAWApp. That is not a convenience choice; it
// is what lets this build while `Sources/DAWControl/Commands.swift` is
// mid-edit by a concurrent agent and does not compile. DAWControl's own
// command vocabulary (`track.add`, `track.setInstrument`, `clip.addMIDI`,
// `fx.add`, `fx.setParam`, `render.mixdown`) is mirrored here by hand against
// `ProjectStore`'s own methods — deliberately a SMALL vocabulary, grown only
// as the demo waves need more of it. If DAWControl's wire semantics for one
// of these verbs changes, mirror the change here too (see
// `docs/ARCHITECTURE.md`'s command table discipline).
//
// SPEC FORMAT: see `scripts/demos/README.md` for the authoritative
// documentation; the shape read here is:
//   { "set": "<name>",
//     "variants": [
//       { "name": "<variant>", "axis": "<one-line, what differs>",
//         "commands": [ { "command": "track.add", "params": {...},
//                          "as": "<bindingName>" }, ... ] } ] }
// `params` values that are strings beginning with "$" are resolved against
// prior `"as"` bindings in the SAME variant (e.g. `"trackId": "$lead"`) —
// the one piece of interpretation state the app-mode harness (which reads
// UUIDs back off real wire responses) and this headless mode (which reads
// UUIDs back off real Swift return values) must agree on byte-for-byte, so
// the SAME spec file drives both paths identically.
//
// OUTPUT: one render per variant, `<outDir>/demo-<set>-<variant>.wav`, plus
// one line of machine-readable JSON on stdout per variant, prefixed
// `RESULT ` so the Node harness can pick it out of ordinary narration lines
// (`#`-prefixed) without a second parser. Exit 0 iff every variant rendered;
// exit 1 if any variant failed (each failure is still reported by name — a
// silent partial run is exactly the failure mode this repo's standing rules
// forbid).

import DAWCore
import DAWEngine
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Small stdout narration helpers

/// Unbuffered stdout: this process can run for tens of seconds per variant
/// (real audio rendering), and a caller watching for a liveness heartbeat
/// must see progress as it happens, not in one flush at exit.
private func setUnbufferedStdout() {
    setvbuf(stdout, nil, _IONBF, 0)
}

private func narrate(_ s: String) {
    print("# \(s)")
}

private func emitResult(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    let line = String(data: data, encoding: .utf8) ?? "{}"
    print("RESULT \(line)")
}

// MARK: - Errors

struct DemoRenderError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

// MARK: - JSON reading helpers (spec is read as loose `Any` — the wire's own
// shape, not a fixed Codable struct, so the spec vocabulary can grow without
// a matching Swift type for every future command).

private func str(_ v: Any?) -> String? { v as? String }
private func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}
/// Integer-valued spec field. JSON has one number type, so `unisonVoices: 8`
/// can arrive as Int, Double or NSNumber depending on the decoder's mood — all
/// three are accepted. A non-integral Double (`8.5` for a voice count) returns
/// nil rather than truncating, so the store's clamp sees "absent" instead of a
/// silently rounded value the author never wrote.
private func int(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let d = v as? Double { return d == d.rounded() ? Int(d) : nil }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}
/// A modulation source param, in the wire's own value vocabulary. `steps` is the
/// reason `.numbers` exists — a step pattern is an array, not a scalar, which is
/// exactly why the design refused to express it as 32 indexed params.
private func modParamValue(_ v: Any?, key: String) throws -> ModulationParamValue {
    // ⛔⛔ ORDER IS NOT THE DISCRIMINATOR HERE, AND BOTH ORDERS ARE WRONG.
    // JSONSerialization hands back `NSNumber` for BOTH JSON numbers and JSON
    // booleans, and the Swift bridge makes each one castable to the other:
    //   · number first → `"bipolar": false` becomes `.number(0)`, refused
    //   · bool first   → `"value": 0` and `"value": 1` become `.bool`, refused
    // I shipped the first bug, "fixed" it by flipping the order, and shipped
    // the second — the two demos that caught them were a month of confusion
    // apart in spirit and twenty minutes apart in fact.
    //
    // ⭐ The real discriminator is the underlying CoreFoundation type: a JSON
    // boolean is a CFBoolean, a JSON number is a CFNumber, and that is exact
    // for every value including 0 and 1. Ask the value what it IS instead of
    // guessing from what it can be cast to.
    if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
        return .bool(n.boolValue)
    }
    if let d = num(v) { return .number(d) }
    if let s = v as? String { return .string(s) }
    if let a = v as? [Any] {
        let ds = a.compactMap { num($0) }
        guard ds.count == a.count else {
            throw DemoRenderError(message: "modulation param '\(key)' has a non-numeric array entry")
        }
        return .numbers(ds)
    }
    if v == nil { return .null }
    throw DemoRenderError(message: "modulation param '\(key)' is not a number, string, bool or number array")
}

/// `trackId` (bound or UUID), or `"strip": "master"`.
private func parseStrip(_ params: [String: Any], bindings: [String: UUID]) throws -> ModulationStrip {
    if let s = str(params["strip"]), s == "master" { return .master }
    return .track(try requireID(params, "trackId", bindings: bindings))
}

/// The route target. Only the cases a render spec can meaningfully address —
/// `sendLevel` is store-deferred, so it is refused here with that reason rather
/// than silently accepted.
private func parseAutomationTarget(_ params: [String: Any],
                                   bindings: [String: UUID]) throws -> AutomationTarget {
    let raw = try requireString(params, "target")
    switch raw {
    case "volume": return .volume
    case "pan": return .pan
    case "effectParam":
        return .effectParam(effectID: try requireID(params, "effectId", bindings: bindings),
                            paramName: try requireString(params, "paramName"))
    case "instrumentParam":
        return .instrumentParam(paramName: try requireString(params, "paramName"))
    case "sendLevel":
        throw DemoRenderError(message: "target 'sendLevel' is deferred at the store — not a harness gap")
    default:
        throw DemoRenderError(message:
            "unknown modulation target '\(raw)' — valid: volume, pan, effectParam, instrumentParam")
    }
}

private func requireString(_ params: [String: Any], _ key: String) throws -> String {
    guard let s = str(params[key]) else {
        throw DemoRenderError(message: "missing required string param '\(key)'")
    }
    return s
}

private func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }
private func arr(_ v: Any?) -> [Any]? { v as? [Any] }

// MARK: - ID binding / substitution

/// Resolves a param value that names an id: either a literal UUID string, or
/// `"$name"` referring to a prior `"as"` binding in this variant.
private func resolveID(_ raw: String, bindings: [String: UUID]) throws -> UUID {
    if raw.hasPrefix("$") {
        let key = String(raw.dropFirst())
        guard let id = bindings[key] else {
            throw DemoRenderError(message: "unbound reference '\(raw)' — no prior command bound '\(key)' via \"as\"")
        }
        return id
    }
    guard let id = UUID(uuidString: raw) else {
        throw DemoRenderError(message: "'\(raw)' is neither a \"$binding\" nor a valid UUID")
    }
    return id
}

private func requireID(_ params: [String: Any], _ key: String, bindings: [String: UUID]) throws -> UUID {
    guard let raw = str(params[key]) else {
        throw DemoRenderError(message: "missing required param '\(key)'")
    }
    return try resolveID(raw, bindings: bindings)
}

// MARK: - Note parsing (mirrors Commands.swift's `parseNotes`)

private func parseNotes(_ value: Any?) throws -> [MIDINote] {
    guard let items = arr(value) else { return [] }
    var notes: [MIDINote] = []
    notes.reserveCapacity(items.count)
    for (i, item) in items.enumerated() {
        guard let d = dict(item), let pitch = num(d["pitch"]) else {
            throw DemoRenderError(message: "notes[\(i)].pitch must be a number 0-127")
        }
        guard let startBeat = num(d["startBeat"]), startBeat >= 0 else {
            throw DemoRenderError(message: "notes[\(i)].startBeat must be a number >= 0")
        }
        let velocity = num(d["velocity"]).map { Int($0) } ?? 100
        let lengthBeats = num(d["lengthBeats"]) ?? 1.0
        notes.append(MIDINote(pitch: Int(pitch), velocity: velocity,
                               startBeat: startBeat, lengthBeats: lengthBeats))
    }
    return notes
}

private func parseWaveform(_ raw: String?) throws -> PolySynthParams.Waveform? {
    guard let raw else { return nil }
    guard let w = PolySynthParams.Waveform(rawValue: raw) else {
        throw DemoRenderError(message: "unknown waveform '\(raw)'")
    }
    return w
}

private func parseInstrumentKind(_ raw: String?) throws -> InstrumentDescriptor.Kind? {
    guard let raw else { return nil }
    guard let k = InstrumentDescriptor.Kind(rawValue: raw) else {
        throw DemoRenderError(message: "unknown instrument kind '\(raw)'")
    }
    return k
}

private func parseEffectKind(_ raw: String) throws -> EffectDescriptor.Kind {
    guard let k = EffectDescriptor.Kind(rawValue: raw) else {
        let valid = EffectDescriptor.Kind.allCases.map(\.rawValue).joined(separator: ", ")
        throw DemoRenderError(message: "unknown effect kind '\(raw)' — valid: \(valid)")
    }
    return k
}

// MARK: - One variant

/// Applies one variant's commands to a fresh, freshly NAMED store (the
/// standing "always name your own test/dogfood project" rule — this store
/// never touches disk, so the name exists only in logs/process state, but it
/// still identifies which render produced which file when several run
/// concurrently in the app-mode harness path).
@MainActor
private func renderVariant(set: String, variant: [String: Any], outDir: URL) async -> [String: Any] {
    guard let name = str(variant["name"]) else {
        return ["variant": "<unnamed>", "ok": false, "error": "variant missing 'name'"]
    }
    let axis = str(variant["axis"]) ?? ""
    let projectName = "demo-\(set)-\(name)"
    narrate("variant '\(name)' (\(projectName)): starting — axis: \(axis)")

    let store = ProjectStore(projectName: projectName)
    // Held STRONGLY for the whole render: `ProjectStore.engine` is `weak`
    // (the live-app precedent — the store never owns the engine's lifetime),
    // so a merely-local `store.engine = AudioEngine()` with no surviving
    // reference would deinit before `renderMixdown` ever ran and the render
    // would fail `engineUnavailable`.
    let engine = AudioEngine()
    store.engine = engine
    // Without this, `clip.addAudio` throws `mediaServiceUnavailable` — the
    // store's `media` is nil by default, exactly as `engine` is. Until 2026-09-19
    // the headless harness could only demo effects on SYNTHESIZED material, so
    // no demo in this tree had ever proved an effect on a real recording.
    // `AudioFileImporter` is stateless, does one-shot header I/O, and never
    // touches the render path.
    store.media = AudioFileImporter()

    var bindings: [String: UUID] = [:]

    do {
        guard let commands = arr(variant["commands"]) else {
            throw DemoRenderError(message: "variant '\(name)' has no 'commands' array")
        }
        for (i, raw) in commands.enumerated() {
            guard let c = dict(raw), let command = str(c["command"]) else {
                throw DemoRenderError(message: "commands[\(i)] missing 'command'")
            }
            let params = dict(c["params"]) ?? [:]
            let bindAs = str(c["as"])

            switch command {
            case "track.add":
                let trackName = str(params["name"])
                let kindRaw = str(params["kind"]) ?? TrackKind.audio.rawValue
                guard let kind = TrackKind(rawValue: kindRaw) else {
                    throw DemoRenderError(message: "unknown track kind '\(kindRaw)'")
                }
                let track = store.addTrack(name: trackName, kind: kind)
                if let bindAs { bindings[bindAs] = track.id }

            case "track.setInstrument":
                let trackID = try requireID(params, "trackId", bindings: bindings)
                let kind = try parseInstrumentKind(str(params["kind"]))
                let waveform = try parseWaveform(str(params["waveform"]))

                // ⛔ REJECT UNKNOWN KEYS. This is not politeness — it is the whole
                // reason this block is trustworthy.
                //
                // Until m39-g this forwarded eight fields and silently DROPPED every
                // other key in the spec. A richness bench authored against the real
                // wire vocabulary rendered four BYTE-IDENTICAL files: the harness had
                // accepted `unisonVoices` and thrown it away, and the only thing that
                // caught it was the audibility guard noticing identical hashes. A
                // parameter accepted and discarded is indistinguishable from a
                // parameter that did not work — the exact failure shape this tree
                // keeps paying for. So an unrecognised key is now a loud error, and
                // this list must be extended whenever the wire gains a parameter.
                let known: Set<String> = [
                    "trackId", "kind", "waveform",
                    "attack", "decay", "sustain", "release",
                    "cutoffHz", "resonance", "gain", "pedalHoldLimit",
                    "unisonVoices", "unisonDetuneCents", "unisonStereoSpread",
                    "subLevel", "subOctave", "subWaveform",
                    "noiseLevel", "noiseColor", "drift", "resonanceBoost", "drive",
                    "velocityToCutoff", "keyToCutoff", "voiceJitter", "envelopeCurve",
                ]
                let unknown = params.keys.filter { !known.contains($0) }.sorted()
                guard unknown.isEmpty else {
                    throw DemoRenderError(message:
                        "track.setInstrument got unknown key(s) \(unknown.joined(separator: ", ")) — "
                        + "the harness would have silently ignored them. Known keys: "
                        + known.sorted().joined(separator: ", "))
                }

                _ = try store.setInstrument(
                    id: trackID, kind: kind, waveform: waveform,
                    attack: num(params["attack"]), decay: num(params["decay"]),
                    sustain: num(params["sustain"]), release: num(params["release"]),
                    cutoffHz: num(params["cutoffHz"]), resonance: num(params["resonance"]),
                    gain: num(params["gain"]),
                    pedalHoldLimit: int(params["pedalHoldLimit"]),
                    unisonVoices: int(params["unisonVoices"]),
                    unisonDetuneCents: num(params["unisonDetuneCents"]),
                    unisonStereoSpread: num(params["unisonStereoSpread"]),
                    subLevel: num(params["subLevel"]),
                    subOctave: int(params["subOctave"]),
                    subWaveform: try parseWaveform(str(params["subWaveform"])),
                    noiseLevel: num(params["noiseLevel"]),
                    noiseColor: num(params["noiseColor"]),
                    drift: num(params["drift"]),
                    resonanceBoost: num(params["resonanceBoost"]),
                    drive: num(params["drive"]),
                    velocityToCutoff: num(params["velocityToCutoff"]),
                    keyToCutoff: num(params["keyToCutoff"]),
                    voiceJitter: num(params["voiceJitter"]),
                    envelopeCurve: num(params["envelopeCurve"])
                )

            // m39-e: modulation. Only the two verbs a demo spec needs to build a
            // gesture — sources and routes. The other seven (`setSource`,
            // `removeRoute`, `setMacro`, the describes…) are wire-surface verbs
            // for a live agent, not things a deterministic render spec does, so
            // they are deliberately absent rather than stubbed.
            case "mod.addSource":
                let strip = try parseStrip(params, bindings: bindings)
                let kindRaw = try requireString(params, "kind")
                guard let kind = ModulationSourceKind(rawValue: kindRaw) else {
                    throw DemoRenderError(message:
                        "unknown modulation source kind '\(kindRaw)' — valid: "
                        + ModulationSourceKind.allCases.map(\.rawValue).sorted().joined(separator: ", "))
                }
                // Everything that is not addressing or naming is a source param.
                var sourceParams: [String: ModulationParamValue] = [:]
                for (key, value) in params where !["trackId", "strip", "kind", "name"].contains(key) {
                    sourceParams[key] = try modParamValue(value, key: key)
                }
                let added = try store.addModulationSource(
                    on: strip, kind: kind, params: sourceParams, name: str(params["name"]))
                for w in added.warnings { print("  # mod.addSource warning: \(w)") }
                if let bindAs { bindings[bindAs] = added.source.id }

            case "mod.addRoute":
                let strip = try parseStrip(params, bindings: bindings)
                let sourceID = try requireID(params, "sourceId", bindings: bindings)
                let target = try parseAutomationTarget(params, bindings: bindings)
                guard let depth = num(params["depth"]) else {
                    throw DemoRenderError(message: "mod.addRoute requires a numeric 'depth'")
                }
                let route = try store.addModulationRoute(
                    on: strip, sourceID: sourceID, target: target, depth: depth)
                for w in route.warnings { print("  # mod.addRoute warning: \(w)") }
                if let bindAs { bindings[bindAs] = route.route.id }

            // ⭐ THE MODULATION DISCRIMINATOR NEEDS THIS, and the reason is
            // worth keeping: at the default volume of 1.0 a volume-modulated
            // strip is INDISTINGUISHABLE from a broken one. `applyParameters`
            // pins the mixer to 1 when a route claims `.volume`
            // (PlaybackGraph.swift:1637) and hands the base level to
            // `ModulationStage`. Pin 1.0 over base 1.0 is a no-op, so "the
            // stage never ran" and "the route never arrived" BOTH render
            // byte-identical to the control. Set the volume to 0.5 and they
            // separate: an inert stage renders ~6 dB LOUDER than the control
            // (pinned to 1, nothing puts the 0.5 back), while a route that
            // never reached the graph leaves the mixer at 0.5 and matches it.
            case "track.setVolume":
                let trackID = try requireID(params, "trackId", bindings: bindings)
                guard let volume = num(params["volume"]) else {
                    throw DemoRenderError(message: "track.setVolume requires a numeric 'volume'")
                }
                // A SETTER'S RETURN IS NOT PROOF IT TOOK — this one reports.
                guard store.setTrackVolume(id: trackID, volume: volume) else {
                    throw DemoRenderError(message:
                        "track.setVolume refused volume \(volume) on \(trackID)")
                }

            case "automation.addLane":
                let trackID = try requireID(params, "trackId", bindings: bindings)
                let target = try parseAutomationTarget(params, bindings: bindings)
                let lane = try store.addAutomationLane(trackID: trackID, target: target)
                if let bindAs { bindings[bindAs] = lane.id }

            case "automation.setPoints":
                let trackID = try requireID(params, "trackId", bindings: bindings)
                let laneID = try requireID(params, "laneId", bindings: bindings)
                guard let rawPoints = params["points"] as? [[String: Any]] else {
                    throw DemoRenderError(message:
                        "automation.setPoints requires 'points' as an array of objects")
                }
                let points: [AutomationPoint] = try rawPoints.map { raw in
                    guard let beat = num(raw["beat"]), let value = num(raw["value"]) else {
                        throw DemoRenderError(message:
                            "each automation point needs numeric 'beat' and 'value'")
                    }
                    return AutomationPoint(beat: beat, value: value)
                }
                _ = try store.setAutomationPoints(trackID: trackID, laneID: laneID, points: points)

            case "clip.addMIDI":
                let trackID = try requireID(params, "trackId", bindings: bindings)
                let notes = try parseNotes(params["notes"])
                let clip = try store.addMIDIClip(
                    toTrack: trackID, name: str(params["name"]),
                    atBeat: num(params["atBeat"]), lengthBeats: num(params["lengthBeats"]),
                    notes: notes
                )
                if let bindAs { bindings[bindAs] = clip.id }

            case "clip.addAudio":
                // Imports a real recording so an effect can be demonstrated on
                // one. ⚠️ The path is resolved against the CURRENT DIRECTORY
                // when relative; the harness runs this binary with cwd = repo
                // root. An absolute path is always unambiguous and is what the
                // vocal specs use.
                //
                // ⛔ Overlap policy is the store's (m33-j): `importAudio`'s
                // default REFUSES a collision with `clipImportWouldOverlap`
                // rather than silently trimming, so a spec that stacks two
                // imports at one beat FAILS LOUDLY instead of quietly losing
                // audio. Do not add an `overwrite` escape here without a demo
                // that needs it.
                let trackID = try requireID(params, "trackId", bindings: bindings)
                guard let rawPath = str(params["path"]) else {
                    throw DemoRenderError(message: "clip.addAudio missing 'path'")
                }
                let audioURL = URL(fileURLWithPath: rawPath)
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    throw DemoRenderError(
                        message: "clip.addAudio: no file at \(audioURL.path)")
                }
                let audioClip = try store.importAudio(
                    url: audioURL, toTrack: trackID, atBeat: num(params["atBeat"]))
                if let bindAs { bindings[bindAs] = audioClip.id }

            case "clip.sliceToSampler":
                // The sample-flip chop (m32-b2): turns an audio clip into a bank
                // of sampler pads, one per MIDI note from `baseNote` up, and by
                // default writes a MIDI clip replaying the ORIGINAL groove.
                //
                // ⚠️ REJECT UNKNOWN KEYS, for the reason `track.setInstrument`
                // spells out above: this harness once accepted `unisonVoices`
                // and silently threw it away, and four "different" variants
                // rendered byte-identical. A chop setting accepted and dropped
                // would look exactly like a chop setting that does not work.
                let sliceKnown: Set<String> = [
                    "clipId", "targetTrackId", "mode", "sensitivity", "divisions",
                    "gridBeats", "minSliceSeconds", "maxSlices", "includeHead",
                    "baseNote", "snapWindowSeconds", "generateMIDI", "atBeat",
                    "velocityFromStrength", "muteSourceTrack",
                ]
                let sliceUnknown = params.keys.filter { !sliceKnown.contains($0) }.sorted()
                guard sliceUnknown.isEmpty else {
                    throw DemoRenderError(message:
                        "clip.sliceToSampler got unknown key(s) "
                        + sliceUnknown.joined(separator: ", ")
                        + " — the harness would have silently ignored them. Known keys: "
                        + sliceKnown.sorted().joined(separator: ", "))
                }
                let sourceClipID = try requireID(params, "clipId", bindings: bindings)
                let sliceMode: SliceBoundaryMode
                switch str(params["mode"]) {
                case nil, "transients": sliceMode = .transients
                case "divisions": sliceMode = .divisions
                case "grid": sliceMode = .grid
                case let other:
                    throw DemoRenderError(message:
                        "clip.sliceToSampler unknown mode '\(other ?? "")' — "
                        + "use transients, divisions or grid")
                }
                var sliceSettings = SliceToSamplerSettings(mode: sliceMode)
                if let v = num(params["sensitivity"]) { sliceSettings.sensitivity = v }
                if let v = num(params["divisions"]) { sliceSettings.divisions = Int(v) }
                if let v = num(params["gridBeats"]) { sliceSettings.gridBeats = v }
                if let v = num(params["minSliceSeconds"]) { sliceSettings.minSliceSeconds = v }
                if let v = num(params["maxSlices"]) { sliceSettings.maxSlices = Int(v) }
                if let v = params["includeHead"] as? Bool { sliceSettings.includeHead = v }
                if let v = num(params["baseNote"]) { sliceSettings.baseNote = Int(v) }
                if let v = num(params["snapWindowSeconds"]) { sliceSettings.snapWindowSeconds = v }
                if let v = params["generateMIDI"] as? Bool { sliceSettings.generateMIDI = v }
                if let v = num(params["atBeat"]) { sliceSettings.atBeat = v }
                if let v = params["velocityFromStrength"] as? Bool {
                    sliceSettings.velocityFromStrength = v
                }
                let sliceTarget: UUID? = params["targetTrackId"] == nil
                    ? nil : try requireID(params, "targetTrackId", bindings: bindings)
                // m39-pads. ⭐ WORTH HAVING IN THE HARNESS PRECISELY BECAUSE OF
                // WHAT IT FIXES: a demo that chops and renders WITHOUT it hears
                // the original under the pads (+6.0 LU, comb-filtered), which
                // is a rendered artefact nobody would attribute to the chop.
                let sliceMute = (params["muteSourceTrack"] as? Bool) ?? false
                let sliceResult = try await store.sliceClipToSampler(
                    clipId: sourceClipID, targetTrackId: sliceTarget,
                    settings: sliceSettings, muteSourceTrack: sliceMute)
                narrate("  # chop: \(sliceResult.sliceCount) slice(s) -> pads from note "
                        + "\(sliceSettings.baseNote)"
                        + (sliceResult.mutedTrackId != nil ? ", source track muted" : ""))
                // Bind the PAD TRACK so later commands can address it: the
                // created track when one was made, else the target it filled.
                if let bindAs {
                    bindings[bindAs] = sliceResult.createdTrackId ?? sliceResult.trackId
                }

            case "instrument.setSamplerParam":
                // The sampler GLOBALS, so a demo can render what the pad grid's
                // LET GO switch does. `oneShot` is the one this exists for: a
                // tap in gate mode is a ~50 ms blip and in one-shot mode is the
                // whole slice, and that difference is the entire point of the
                // control — but it is INAUDIBLE in a spec that cannot set it.
                //
                // ⚠️ REJECT UNKNOWN KEYS — the `clip.sliceToSampler` reason.
                let globalKnown: Set<String> = ["trackId", "oneShot", "attack", "release", "gain"]
                let globalUnknown = params.keys.filter { !globalKnown.contains($0) }.sorted()
                guard globalUnknown.isEmpty else {
                    throw DemoRenderError(message:
                        "instrument.setSamplerParam got unknown key(s) "
                        + globalUnknown.joined(separator: ", ")
                        + " — known keys: " + globalKnown.sorted().joined(separator: ", "))
                }
                let globalTrackID = try requireID(params, "trackId", bindings: bindings)
                guard let globalTrack = store.tracks.first(where: { $0.id == globalTrackID }),
                      let globalInstrument = globalTrack.instrument,
                      globalInstrument.kind == .sampler else {
                    throw DemoRenderError(message:
                        "instrument.setSamplerParam needs a track playing the built-in Sampler")
                }
                var globalParams = globalInstrument.resolvedSampler
                if let v = params["oneShot"] as? Bool { globalParams.oneShot = v }
                if let v = num(params["attack"]) { globalParams.attack = v }
                if let v = num(params["release"]) { globalParams.release = v }
                if let v = num(params["gain"]) { globalParams.gain = v }
                _ = try store.setInstrument(id: globalTrackID, sampler: globalParams)
                narrate("  # sampler: oneShot=\(globalParams.oneShot) "
                        + "release=\(globalParams.release)s")

            case "instrument.spreadSlice":
                // SIXTEEN LEVELS (m39-levels) in the harness, so a demo can
                // RENDER what the LEVELS switch does rather than describe it.
                //
                // ⛔⛔ **IT CALLS `SixteenLevels.zone(from:base:)` — THE PRODUCT'S
                // OWN BUILDER — AND THAT IS THE ONLY REASON THIS COMMAND IS
                // WORTH HAVING.** Hand-rolling a widened zone in the spec JSON
                // would render a sound the app cannot make, and a demo that
                // proves the harness can transpose a sample proves nothing
                // about the feature. (`SixteenLevels` was moved from DAWAppKit
                // to DAWCore for exactly this: this executable links DAWCore +
                // DAWEngine only, never a surface module.)
                //
                // ⚠️ REJECT UNKNOWN KEYS — the `clip.sliceToSampler` reason.
                let spreadKnown: Set<String> = ["trackId", "sliceIndex", "base"]
                let spreadUnknown = params.keys.filter { !spreadKnown.contains($0) }.sorted()
                guard spreadUnknown.isEmpty else {
                    throw DemoRenderError(message:
                        "instrument.spreadSlice got unknown key(s) "
                        + spreadUnknown.joined(separator: ", ")
                        + " — known keys: " + spreadKnown.sorted().joined(separator: ", "))
                }
                let spreadTrackID = try requireID(params, "trackId", bindings: bindings)
                guard let spreadTrack = store.tracks.first(where: { $0.id == spreadTrackID }),
                      let spreadInstrument = spreadTrack.instrument,
                      spreadInstrument.kind == .sampler else {
                    throw DemoRenderError(message:
                        "instrument.spreadSlice needs a track playing the built-in Sampler")
                }
                var spreadParams = spreadInstrument.resolvedSampler
                // 1-based in the spec, because the grid says "slice 3" and a
                // spec that said 2 for that would be a translation the reader
                // has to do every time.
                let sliceOrdinal = Int(num(params["sliceIndex"]) ?? 1)
                let ordered = spreadParams.zones.sorted { $0.rootPitch < $1.rootPitch }
                guard sliceOrdinal >= 1, sliceOrdinal <= ordered.count else {
                    throw DemoRenderError(message:
                        "instrument.spreadSlice sliceIndex \(sliceOrdinal) is outside "
                        + "1…\(ordered.count)")
                }
                let spreadSource = ordered[sliceOrdinal - 1]
                guard let spreadBase = num(params["base"]).map({ Int($0) })
                        ?? SixteenLevels.freeBase(zones: spreadParams.zones) else {
                    throw DemoRenderError(message:
                        "instrument.spreadSlice found no free \(SixteenLevels.span)-key window "
                        + "— this keymap fills the keyboard")
                }
                let spreadZone = SixteenLevels.zone(from: spreadSource, base: spreadBase)
                // ⭐ ADDED, never substituted — the feature's whole design rule.
                // A harness that REPLACED the keymap here would render a demo of
                // a build the app deliberately does not ship.
                spreadParams.zones.append(spreadZone)
                _ = try store.setInstrument(id: spreadTrackID, sampler: spreadParams)
                narrate("  # levels: slice \(sliceOrdinal) spread over notes "
                        + "\(spreadBase)…\(spreadBase + SixteenLevels.span - 1), "
                        + "\(spreadParams.zones.count) zone(s) on the track")

            // m39-dm: the drum machine's two SPEC-SHAPED verbs. Named and keyed
            // to match the real wire exactly (`instrument.loadDrumPreset` takes
            // trackId/name; `instrument.setDrumParam` takes trackId/name/value),
            // so one spec reads the same whichever render path runs it. The
            // other two drum verbs are READS — `describeDrumKit` and
            // `listDrumPresets` — which a deterministic render spec has no use
            // for, so they are deliberately absent rather than stubbed.
            //
            // ⚠️ `drumKit` is NOT added to `track.setInstrument`'s known-key set
            // above, on purpose. A spec that hand-writes 75 numbers is a
            // transcription-error farm, and the loud unknown-key error is the
            // thing that stops one being written by accident.
            case "instrument.loadDrumPreset":
                let presetKnown: Set<String> = ["trackId", "name"]
                let presetUnknown = params.keys.filter { !presetKnown.contains($0) }.sorted()
                guard presetUnknown.isEmpty else {
                    throw DemoRenderError(message:
                        "instrument.loadDrumPreset got unknown key(s) "
                        + presetUnknown.joined(separator: ", ")
                        + " — known keys: " + presetKnown.sorted().joined(separator: ", "))
                }
                let presetTrackID = try requireID(params, "trackId", bindings: bindings)
                let presetName = try requireString(params, "name")
                guard let drumPreset = DrumKitParams.preset(named: presetName) else {
                    throw DemoRenderError(message:
                        "unknown drum preset '\(presetName)' — valid names: "
                        + DrumKitParams.presets.map(\.name).joined(separator: ", "))
                }
                // m39-tpl-0: a preset changes how the drums SOUND, never which
                // note plays which drum — the same one home the wire verb calls.
                let presetCurrentKit = store.tracks.first(where: { $0.id == presetTrackID })?
                    .instrument?.resolvedDrumKit ?? DrumKitParams()
                _ = try store.setInstrument(id: presetTrackID,
                                            drumKit: presetCurrentKit.applyingPreset(drumPreset))
                narrate("  # drum kit: loaded preset '\(drumPreset.name)' "
                        + "(\(DrumKitParams.paramSpecs.count) parameters replaced)")

            case "instrument.setDrumParam":
                let drumKnown: Set<String> = ["trackId", "name", "value"]
                let drumUnknown = params.keys.filter { !drumKnown.contains($0) }.sorted()
                guard drumUnknown.isEmpty else {
                    throw DemoRenderError(message:
                        "instrument.setDrumParam got unknown key(s) "
                        + drumUnknown.joined(separator: ", ")
                        + " — known keys: " + drumKnown.sorted().joined(separator: ", "))
                }
                let drumTrackID = try requireID(params, "trackId", bindings: bindings)
                let drumName = try requireString(params, "name")
                guard let drumValue = num(params["value"]), drumValue.isFinite else {
                    throw DemoRenderError(message:
                        "instrument.setDrumParam 'value' must be a finite number")
                }
                guard DrumKitParams.spec(forParamName: drumName) != nil else {
                    throw DemoRenderError(message:
                        "unknown drum parameter '\(drumName)' — names are dotted, "
                        + "like kick.decay or closedHat.tone")
                }
                _ = try store.setInstrument(id: drumTrackID,
                                            drumParam: (name: drumName, value: drumValue))
                narrate("  # drum param: \(drumName) = \(drumValue)")

            case "fx.add":
                let trackID = try requireID(params, "trackId", bindings: bindings)
                guard let kindRaw = str(params["kind"]) else {
                    throw DemoRenderError(message: "fx.add missing 'kind'")
                }
                let kind = try parseEffectKind(kindRaw)
                let index = num(params["index"]).map { Int($0) }
                let effect = try store.addEffect(toTrack: trackID, kind: kind, at: index)
                if let bindAs { bindings[bindAs] = effect.id }
                if let initial = dict(params["params"]) {
                    for (paramName, paramValue) in initial {
                        guard let v = num(paramValue) else { continue }
                        _ = try store.setEffectParam(
                            trackID: trackID, effectID: effect.id, name: paramName, value: v)
                    }
                }

            case "fx.setParam":
                let trackID = try requireID(params, "trackId", bindings: bindings)
                let effectID = try requireID(params, "effectId", bindings: bindings)
                guard let paramName = str(params["name"]), let value = num(params["value"]) else {
                    throw DemoRenderError(message: "fx.setParam requires 'name' and 'value'")
                }
                _ = try store.setEffectParam(trackID: trackID, effectID: effectID,
                                             name: paramName, value: value)

            case "track.addSend":
                let trackID = try requireID(params, "trackId", bindings: bindings)
                let busID = try requireID(params, "busId", bindings: bindings)
                let send = try store.addSend(toTrack: trackID, busID: busID,
                                             level: num(params["level"]) ?? 1)
                if let bindAs { bindings[bindAs] = send.id }

            case "fx.setSidechain":
                let trackID = try requireID(params, "trackId", bindings: bindings)
                let effectID = try requireID(params, "effectId", bindings: bindings)
                // Wire parity (Commands.swift `fx.setSidechain`): the key absent
                // OR JSON null clears the sidechain; a non-null value (including
                // a "$binding") names the key source.
                let sourceTrackID: UUID?
                if let raw = str(params["sourceTrackId"]) {
                    sourceTrackID = try resolveID(raw, bindings: bindings)
                } else {
                    sourceTrackID = nil
                }
                _ = try store.setSidechain(trackID: trackID, effectID: effectID,
                                           sourceTrackID: sourceTrackID)

            default:
                throw DemoRenderError(message: "unsupported command '\(command)' — "
                    + "DemoRender's headless vocabulary is deliberately small; "
                    + "see Sources/DemoRender/DemoRender.swift to extend it")
            }
        }

        let outPath = outDir.appendingPathComponent("demo-\(set)-\(name).wav")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        narrate("variant '\(name)': applied \(commandCount(variant)) command(s), rendering to \(outPath.path)")
        // ⭐ READ-BACK, not a setter's return. Every command above reported
        // success, and the first modulation demo still rendered byte-identical
        // to its own control — a whole axis that silently did nothing. This
        // prints what the STORE actually holds at the moment of render, so a
        // dropped source/route is visible in the log instead of having to be
        // inferred from the audio. Cheap, and it only speaks when there is
        // modulation to speak about.
        for track in store.tracks {
            guard let state = try? store.modulationState(of: .track(track.id)),
                  !state.sources.isEmpty || !state.routes.isEmpty else { continue }
            narrate("variant '\(name)': track '\(track.name)' volume=\(track.volume) "
                    + "sources=\(state.sources.count) routes=\(state.routes.count)")
            for source in state.sources {
                narrate("    source \(source.kind.rawValue) '\(source.name)' \(source.params)")
            }
            for route in state.routes {
                narrate("    route -> \(route.target) depth=\(route.depth) "
                        + "enabled=\(route.enabled) source=\(route.sourceID)")
            }
        }
        let render = dict(variant["render"]) ?? [:]
        let result = try await store.renderMixdown(
            toPath: outPath.path,
            fromBeat: num(render["fromBeat"]) ?? 0,
            durationSeconds: num(render["durationSeconds"])
        )
        narrate("variant '\(name)': rendered \(result.durationSeconds)s @ \(result.sampleRate)Hz -> \(result.path)")

        var out: [String: Any] = [
            "variant": name, "axis": axis, "ok": true,
            "path": result.path, "durationSeconds": result.durationSeconds,
            "sampleRate": result.sampleRate, "channels": result.channels,
        ]

        // OPTIONAL measurement isolation: `"measureStem": {"trackId": "$x"}`
        // renders x's stem SEPARATELY (pre-master, but WITH its real live
        // sidechain/send processing — `render.stems` reflects the actual
        // keyed-compressor output, per the S-1 StemPlan key-source closure)
        // so a caller can measure one bus/track's own signal free of
        // whatever else is playing directly into the master mix at the same
        // moment. The SHIPPED, listenable file stays the full mixdown above
        // — this is a measurement aid only, written to a sibling directory.
        if let measureStem = dict(variant["measureStem"]),
           let rawStemTrack = str(measureStem["trackId"]) {
            let stemTrackID = try resolveID(rawStemTrack, bindings: bindings)
            let stemsDir = outDir.appendingPathComponent("_stems-\(set)-\(name)", isDirectory: true)
            let stems = try await store.renderStems(
                toDirectory: stemsDir.path, trackIds: [stemTrackID],
                fromBeat: num(render["fromBeat"]) ?? 0,
                durationSeconds: result.durationSeconds
            )
            if let stemFile = stems.stems.first(where: { $0.trackId == stemTrackID }) {
                narrate("variant '\(name)': isolated measurement stem -> \(stemFile.path)")
                out["measureStemPath"] = stemFile.path
            } else {
                narrate("variant '\(name)': measureStem requested but no matching stem came back")
            }
        }

        return out
    } catch {
        let message = (error as? DemoRenderError)?.message
            ?? (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        narrate("variant '\(name)': FAILED — \(message)")
        return ["variant": name, "axis": axis, "ok": false, "error": message]
    }
}

private func commandCount(_ variant: [String: Any]) -> Int { arr(variant["commands"])?.count ?? 0 }

// MARK: - Entry point

@main
struct DemoRenderMain {
    @MainActor
    static func main() async {
        setUnbufferedStdout()
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(
                "usage: DemoRender <specPath.json> <outDir>\n".data(using: .utf8)!)
            exit(2)
        }
        let specPath = args[1]
        let outDir = URL(fileURLWithPath: args[2], isDirectory: true)

        guard let specData = FileManager.default.contents(atPath: specPath) else {
            FileHandle.standardError.write("could not read spec file: \(specPath)\n".data(using: .utf8)!)
            exit(2)
        }
        guard let spec = (try? JSONSerialization.jsonObject(with: specData)) as? [String: Any] else {
            FileHandle.standardError.write("spec file is not a JSON object: \(specPath)\n".data(using: .utf8)!)
            exit(2)
        }
        guard let setName = str(spec["set"]), let variants = arr(spec["variants"]), !variants.isEmpty else {
            FileHandle.standardError.write(
                "spec must have a non-empty string 'set' and a non-empty 'variants' array\n"
                    .data(using: .utf8)!)
            exit(2)
        }

        narrate("set '\(setName)': \(variants.count) variant(s) — headless render via OfflineRenderer, no GUI, no control port")
        var anyFailed = false
        for v in variants {
            guard let variant = dict(v) else {
                emitResult(["variant": "<malformed>", "ok": false, "error": "variant entry is not an object"])
                anyFailed = true
                continue
            }
            let result = await renderVariant(set: setName, variant: variant, outDir: outDir)
            emitResult(result)
            if (result["ok"] as? Bool) != true { anyFailed = true }
        }
        narrate("set '\(setName)': done — \(anyFailed ? "at least one variant FAILED" : "all variants rendered")")
        exit(anyFailed ? 1 : 0)
    }
}
