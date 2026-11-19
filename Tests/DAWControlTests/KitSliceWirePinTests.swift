import Foundation
import Testing
import DAWCore
@testable import DAWControl

// m39-w4-6 — design `docs/design/2026-10-07-loop-drum-depth.md` §9.2 C1, ON THE WIRE.
//
// `clip.sliceToSampler` WITHOUT `mapping` must reply, and leave pads that describe, byte-for-byte as it did
// before m39-w4-6. The two goldens below were captured by THIS test (`W46_RECORD_DIR` set) from the tree as it
// stood before m39-w4-6 touched a line of Sources (W8-W46, 2026-10-07), and pasted in verbatim. UUIDs are
// replaced by `<uuid-N>` in order of first appearance, so the shape is pinned and the fresh ids are not.
//
// An EXTENSION of the existing @MainActor suite (the router and the store are main-actor), not a new suite.
extension SliceToSamplerCommandTests {

    /// Sorted-key JSON of `value` with every UUID replaced by `<uuid-N>`, N in order of first appearance.
    static func w46Normalised(_ value: JSONValue?) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try encoder.encode(value ?? .null), as: UTF8.self)
        let pattern = try NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
        var seen: [String: Int] = [:]
        var out = ""
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let id = text[range].uppercased()
            let n = seen[id] ?? (seen.count + 1)
            seen[id] = n
            out += text[cursor..<range.lowerBound] + "<uuid-\(n)>"
            cursor = range.upperBound
        }
        return out + text[cursor...]
    }

    /// One chop through the real router on a fresh store, then `instrument.describeSampler` on the pads track.
    func w46ChopAndDescribe(_ extra: [String: JSONValue]) async throws -> String {
        let engine = FakeTransientEngine()
        engine.stubMarkers = [
            TransientMarker(timeSeconds: 0.5, strength: 1.0),
            TransientMarker(timeSeconds: 1.0, strength: 0.4),
            TransientMarker(timeSeconds: 1.5, strength: 0.8),
        ]
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let router = CommandRouter(store: store)
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/w46-pin/Loop.wav"),
                     "atBeat": .number(0)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        var params: [String: JSONValue] = ["clipId": .string(clipID)]
        params.merge(extra) { _, new in new }
        let reply = await router.handle(ControlRequest(
            id: "x", command: "clip.sliceToSampler", params: params))
        #expect(reply.ok, "\(reply.error ?? "")")
        let padsID = try #require(reply.result?["trackId"]?.stringValue)
        let describe = await router.handle(ControlRequest(
            id: "d", command: "instrument.describeSampler", params: ["trackId": .string(padsID)]))
        #expect(describe.ok, "\(describe.error ?? "")")
        return "reply=" + (try Self.w46Normalised(reply.result))
            + "\ndescribe=" + (try Self.w46Normalised(describe.result))
    }

    static let w46WireCases: [(name: String, params: [String: JSONValue])] = [
        ("default", [:]),
        ("divisions", ["mode": .string("divisions"), "divisions": .number(4),
                       "baseNote": .number(48), "muteSourceTrack": .bool(true)]),
    ]

    static let w46WireGolden: [String: String] = [
        "default": #"""
reply={"createdTrackId":"<uuid-1>","frameCount":88200,"headSeconds":0.5,"midiClipId":"<uuid-2>","sampleRate":44100,"sliceCount":3,"slices":[{"beat":1,"endFrame":44100,"index":0,"pitch":36,"residualAmplitude":0,"snapOffsetFrames":0,"sourceSeconds":0.5,"startFrame":22050,"strength":1},{"beat":2,"endFrame":66150,"index":1,"pitch":37,"residualAmplitude":0,"snapOffsetFrames":0,"sourceSeconds":1,"startFrame":44100,"strength":0.4},{"beat":3,"index":2,"pitch":38,"residualAmplitude":0,"snapOffsetFrames":0,"sourceSeconds":1.5,"startFrame":66150,"strength":0.8}],"sourceTrackMuted":false,"trackId":"<uuid-1>","warnings":["0.5 s of audio before the first slice point was discarded (pad 1 starts at the first onset, like an MPC or Recycle). Pass includeHead: true to keep it as pad 1 — worth doing if the detector missed the downbeat"]}
describe={"attack":0.001,"effectiveGlobals":{"attack":{"effectiveMax":0,"effectiveMin":0,"effectiveValues":[0],"global":0.001,"globalIsInert":true,"note":"every zone sets its own attack, so the stored global 0.001 is NOT used — the engine applies the value(s) in effectiveValues. Change what you hear per zone with instrument_set_sampler_zones (patch [{id, attack}]) — or, over the raw control protocol, track.setInstrument's sampler.zonePatches [{id, attack}]; changing the global will do nothing.","zonesInheriting":0,"zonesOverriding":3},"decay":{"effectiveMax":0,"effectiveMin":0,"effectiveValues":[0],"global":0,"globalIsInert":false,"zonesInheriting":3,"zonesOverriding":0},"oneShot":{"global":false,"globalIsInert":false,"zonesInheriting":3,"zonesOverriding":0},"release":{"effectiveMax":0.01,"effectiveMin":0.01,"effectiveValues":[0.01],"global":0.05,"globalIsInert":true,"note":"every zone sets its own release, so the stored global 0.05 is NOT used — the engine applies the value(s) in effectiveValues. Change what you hear per zone with instrument_set_sampler_zones (patch [{id, release}]) — or, over the raw control protocol, track.setInstrument's sampler.zonePatches [{id, release}]; changing the global will do nothing.","zonesInheriting":0,"zonesOverriding":3},"sustain":{"effectiveMax":1,"effectiveMin":1,"effectiveValues":[1],"global":1,"globalIsInert":false,"zonesInheriting":3,"zonesOverriding":0}},"gain":1,"kind":"sampler","oneShot":false,"release":0.05,"trackId":"<uuid-1>","warnings":["release: the stored global (0.05) is NOT what you'll hear — every zone overrides it; the engine actually applies 0.01. See effectiveGlobals.release.","attack: the stored global (0.001) is NOT what you'll hear — every zone overrides it; the engine actually applies 0.0. See effectiveGlobals.attack."],"zoneSummary":{"count":3,"distinctSampleFiles":1,"groupCount":1,"pitchCoverage":{"max":38,"min":36},"velocityCoverage":{"max":127,"min":0}}}
"""#,
        "divisions": #"""
reply={"createdTrackId":"<uuid-1>","frameCount":88200,"headSeconds":0.5,"midiClipId":"<uuid-2>","mutedTrackId":"<uuid-3>","sampleRate":44100,"sliceCount":4,"slices":[{"beat":0,"endFrame":22050,"index":0,"pitch":48,"sourceSeconds":0,"startFrame":0},{"beat":1,"endFrame":44100,"index":1,"pitch":49,"residualAmplitude":0,"snapOffsetFrames":0,"sourceSeconds":0.5,"startFrame":22050},{"beat":2,"endFrame":66150,"index":2,"pitch":50,"residualAmplitude":0,"snapOffsetFrames":0,"sourceSeconds":1,"startFrame":44100},{"beat":3,"index":3,"pitch":51,"residualAmplitude":0,"snapOffsetFrames":0,"sourceSeconds":1.5,"startFrame":66150}],"sourceTrackMuted":true,"trackId":"<uuid-1>","warnings":[]}
describe={"attack":0.001,"effectiveGlobals":{"attack":{"effectiveMax":0,"effectiveMin":0,"effectiveValues":[0],"global":0.001,"globalIsInert":true,"note":"every zone sets its own attack, so the stored global 0.001 is NOT used — the engine applies the value(s) in effectiveValues. Change what you hear per zone with instrument_set_sampler_zones (patch [{id, attack}]) — or, over the raw control protocol, track.setInstrument's sampler.zonePatches [{id, attack}]; changing the global will do nothing.","zonesInheriting":0,"zonesOverriding":4},"decay":{"effectiveMax":0,"effectiveMin":0,"effectiveValues":[0],"global":0,"globalIsInert":false,"zonesInheriting":4,"zonesOverriding":0},"oneShot":{"global":false,"globalIsInert":false,"zonesInheriting":4,"zonesOverriding":0},"release":{"effectiveMax":0.01,"effectiveMin":0.01,"effectiveValues":[0.01],"global":0.05,"globalIsInert":true,"note":"every zone sets its own release, so the stored global 0.05 is NOT used — the engine applies the value(s) in effectiveValues. Change what you hear per zone with instrument_set_sampler_zones (patch [{id, release}]) — or, over the raw control protocol, track.setInstrument's sampler.zonePatches [{id, release}]; changing the global will do nothing.","zonesInheriting":0,"zonesOverriding":4},"sustain":{"effectiveMax":1,"effectiveMin":1,"effectiveValues":[1],"global":1,"globalIsInert":false,"zonesInheriting":4,"zonesOverriding":0}},"gain":1,"kind":"sampler","oneShot":false,"release":0.05,"trackId":"<uuid-1>","warnings":["release: the stored global (0.05) is NOT what you'll hear — every zone overrides it; the engine actually applies 0.01. See effectiveGlobals.release.","attack: the stored global (0.001) is NOT what you'll hear — every zone overrides it; the engine actually applies 0.0. See effectiveGlobals.attack."],"zoneSummary":{"count":4,"distinctSampleFiles":1,"groupCount":1,"pitchCoverage":{"max":51,"min":48},"velocityCoverage":{"max":127,"min":0}}}
"""#,
    ]

    @Test("C1 wire: clip.sliceToSampler without mapping replies and describes its pads exactly as before m39-w4-6",
          arguments: ["default", "divisions"])
    func w46ChromaticWireReplyIsPinned(name: String) async throws {
        let params = try #require(Self.w46WireCases.first { $0.name == name }?.params)
        let actual = try await w46ChopAndDescribe(params)
        #expect(actual.contains("\"startFrame\""), "control: the reply really carries pads")
        if let dir = ProcessInfo.processInfo.environment["W46_RECORD_DIR"] {
            try Data(actual.utf8).write(to: URL(fileURLWithPath: dir).appendingPathComponent("wire-\(name).txt"))
            return
        }
        let expected = try #require(Self.w46WireGolden[name])
        #expect(!expected.hasPrefix("W46_GOLDEN"), "the golden was never pasted in")
        #expect(actual == expected, "C1 wire \(name): got\n\(actual)")
    }
}
