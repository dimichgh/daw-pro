import Foundation
import Testing
import DAWCore
@testable import DAWControl

// m39-w4-6 — `clip.sliceToSampler`'s opt-in `mapping: "kit"` and `roles`, on the wire.
// Design `docs/design/2026-10-07-loop-drum-depth.md` §5.2. The MCP leg is m39-w4-7, not here.

/// An engine that detects onsets, resolves slice frames AND measures slice timbres from stubs, and records
/// what the store asked it to measure.
@MainActor
final class KitTimbreEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted
    var stubMarkers: [TransientMarker] = []
    /// What `analyzeSliceTimbres` returns. `[]` is an engine that measures nothing.
    var stubTimbres: [SliceTimbre] = []
    var measuredSpans: [SliceFrameSpan]?
    var measureCalls = 0

    func detectTransients(inFileAt url: URL, sensitivity: Double) async throws -> [TransientMarker] {
        stubMarkers
    }

    func resolveSliceBoundaries(inFileAt url: URL, boundarySeconds: [Double],
                                snapWindowSeconds: Double) async throws -> SliceBoundaryGeometry {
        let frames = boundarySeconds.map { Int(($0 * 44_100).rounded()) }
        return SliceBoundaryGeometry(sampleRate: 44_100, frameCount: 88_200, boundaryFrames: frames,
                                     snapOffsetFrames: Array(repeating: 0, count: frames.count),
                                     residualAmplitude: Array(repeating: 0, count: frames.count))
    }

    func analyzeSliceTimbres(inFileAt url: URL,
                             frameRanges: [SliceFrameSpan]) async throws -> [SliceTimbre] {
        measureCalls += 1
        measuredSpans = frameRanges
        return stubTimbres
    }

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func projectWillReplace() {}
    func clipGainChanged(trackID: UUID, clipID: UUID, gainDb: Double) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
}

extension SliceToSamplerCommandTests {

    /// A textbook timbre per role (the same numbers `KitSliceLayoutTests` uses), so the wire tests do not
    /// depend on the classifier's fit beyond "a textbook kick is a kick".
    static func w46Timbre(_ role: KitSliceRole, peak: Double = 0.5) -> SliceTimbre {
        switch role {
        case .kick:
            return SliceTimbre(lowEnergyShare: 0.95, highEnergyShare: 0, attackCentroidHz: 70, decaySeconds: 0.2,
                               decayReachedFloor: true, spectralFlatness: 1e-6, peak: peak, durationSeconds: 0.5)
        case .snare:
            return SliceTimbre(lowEnergyShare: 0.05, highEnergyShare: 0.1, attackCentroidHz: 1_500,
                               decaySeconds: 0.06, decayReachedFloor: true, spectralFlatness: 0.01, peak: peak,
                               durationSeconds: 0.5)
        case .closedHat:
            return SliceTimbre(lowEnergyShare: 0, highEnergyShare: 0.97, attackCentroidHz: 10_000,
                               decaySeconds: 0.02, decayReachedFloor: true, spectralFlatness: 0.03, peak: peak,
                               durationSeconds: 0.5)
        case .openHat:
            return SliceTimbre(lowEnergyShare: 0, highEnergyShare: 0.97, attackCentroidHz: 10_000,
                               decaySeconds: 0.15, decayReachedFloor: true, spectralFlatness: 0.01, peak: peak,
                               durationSeconds: 0.5)
        case .other:
            return SliceTimbre(lowEnergyShare: 0, highEnergyShare: 0, attackCentroidHz: 1_000, decaySeconds: 0.1,
                               decayReachedFloor: true, spectralFlatness: 1e-9, peak: peak, durationSeconds: 0.5)
        }
    }

    /// A store with one 2 s audio clip, an engine with four onsets (0.25 / 0.75 / 1.25 / 1.75 s → four pads)
    /// measuring kick, closed hat, snare, open hat.
    func w46KitRig() async throws -> (router: CommandRouter, store: ProjectStore, engine: KitTimbreEngine,
                                      clipID: String) {
        let engine = KitTimbreEngine()
        engine.stubMarkers = [0.25, 0.75, 1.25, 1.75].map { TransientMarker(timeSeconds: $0, strength: 0.8) }
        engine.stubTimbres = [.kick, .closedHat, .snare, .openHat].map { Self.w46Timbre($0) }
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let router = CommandRouter(store: store)
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/w46-wire/Loop.wav"),
                     "atBeat": .number(0)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (router, store, engine, clipID)
    }

    func w46Chop(_ router: CommandRouter, _ clipID: String, _ extra: [String: JSONValue]) async -> ControlResponse {
        var params: [String: JSONValue] = ["clipId": .string(clipID)]
        params.merge(extra) { _, new in new }
        return await router.handle(ControlRequest(id: "k", command: "clip.sliceToSampler", params: params))
    }

    @Test("mapping kit: hits land on their General MIDI notes, report role + confidence + a summary, hats choke")
    func w46KitMappingSortsTheHits() async throws {
        let rig = try await w46KitRig()
        let reply = await w46Chop(rig.router, rig.clipID, ["mapping": .string("kit")])
        #expect(reply.ok, "\(reply.error ?? "-")")
        let result = try #require(reply.result)
        let slices = try #require(result["slices"]?.arrayValue)
        #expect(slices.compactMap { $0["pitch"]?.doubleValue } == [36, 42, 38, 46])
        #expect(slices.compactMap { $0["role"]?.stringValue } == ["kick", "closedHat", "snare", "openHat"])
        #expect(slices.allSatisfy { ($0["confidence"]?.doubleValue ?? 0) >= 0.5 })
        #expect(result["kitSummary"]?.stringValue
                == "Sorted into 1 kick, 1 snare, 1 closed hat and 1 open hat.")
        // The engine was asked to measure exactly the four pads' frames.
        #expect(rig.engine.measureCalls == 1)
        #expect(rig.engine.measuredSpans?.map(\.start) == slices.compactMap { $0["startFrame"]?.doubleValue }.map { Int($0) })
        // The pads: drum roles stored, hats in choke group 0, nothing else chokes.
        let padsID = try #require(result["trackId"]?.stringValue)
        let pads = try #require(rig.store.tracks.first { $0.id.uuidString == padsID })
        let zones = try #require(pads.instrument?.sampler?.zones)
        #expect(zones.map(\.drumRole) == [.kick, .closedHat, .snare, .openHat])
        #expect(zones.map(\.chokeGroup) == [nil, 0, nil, 0])
        #expect(zones.map(\.rootPitch) == [36, 42, 38, 46])
        // The reconstruction clip plays the same groove at the kit notes.
        let notes = try #require(pads.clips.first?.notes)
        #expect(notes.map(\.pitch) == [36, 42, 38, 46])
        // describeSampler names the drum.
        let described = await rig.router.handle(ControlRequest(
            id: "d", command: "instrument.describeSampler",
            params: ["trackId": .string(padsID), "offset": .number(0), "limit": .number(8)]))
        #expect(described.result?["zones"]?.arrayValue?.compactMap { $0["drumRole"]?.stringValue }
                == ["kick", "closedHat", "snare", "openHat"])
        // The step grid now has drum rows for this sampler.
        #expect(DrumLaneMap.lanes(for: pads.instrument)?.map(\.label) == ["Kick", "Snare", "Closed Hat", "Open Hat"])
    }

    @Test("roles override the classifier (confidence 1); a chromatic chop never asks the engine to measure")
    func w46RolesOverrideAndChromaticNeverMeasures() async throws {
        let rig = try await w46KitRig()
        let reply = await w46Chop(rig.router, rig.clipID, ["mapping": .string("kit"),
                                                           "roles": .object(["0": .string("snare"),
                                                                             "3": .string("other")])])
        #expect(reply.ok, "\(reply.error ?? "-")")
        let slices = try #require(reply.result?["slices"]?.arrayValue)
        #expect(slices.compactMap { $0["role"]?.stringValue } == ["snare", "closedHat", "snare", "other"])
        #expect(slices[0]["confidence"]?.doubleValue == 1 && slices[3]["confidence"]?.doubleValue == 1)
        #expect(slices[3]["pitch"]?.doubleValue == 84, "the forced 'other' hit is on the extras")

        let plain = try await w46KitRig()
        let chromatic = await w46Chop(plain.router, plain.clipID, [:])
        #expect(chromatic.ok)
        #expect(plain.engine.measureCalls == 0, "mapping absent must not pay for the analysis")
        #expect(chromatic.result?["kitSummary"] == nil)
        #expect(chromatic.result?["slices"]?.arrayValue?.allSatisfy { $0["role"] == nil } == true)
    }

    @Test("mapping/roles mistakes are refused with a sentence and change nothing", arguments: [
        "mapping-word", "roles-without-kit", "baseNote-with-kit", "role-word", "role-key", "role-index",
        "engine-measures-nothing",
    ])
    func w46KitRefusals(_ name: String) async throws {
        let rig = try await w46KitRig()
        let before = rig.store.tracks.count
        let kit: [String: JSONValue] = ["mapping": .string("kit")]
        let (params, expected): ([String: JSONValue], String) = {
            switch name {
            case "mapping-word": return (["mapping": .string("drums")], "'mapping' must be 'chromatic'")
            case "roles-without-kit": return (["roles": .object(["0": .string("kick")])],
                                              "'roles' only applies to mapping 'kit'")
            case "baseNote-with-kit": return (kit.merging(["baseNote": .number(36)]) { a, _ in a },
                                              "'baseNote' only applies to mapping 'chromatic'")
            case "role-word": return (kit.merging(["roles": .object(["0": .string("cowbell")])]) { a, _ in a },
                                      "'roles.0' must be one of")
            case "role-key": return (kit.merging(["roles": .object(["first": .string("kick")])]) { a, _ in a },
                                     "'roles' keys are slice indexes")
            case "role-index": return (kit.merging(["roles": .object(["9": .string("kick")])]) { a, _ in a },
                                       "roles names slice 9, but this chop made 4 slices")
            default: return (kit, "the engine measured 0 of the 4 slices")
            }
        }()
        if name == "engine-measures-nothing" { rig.engine.stubTimbres = [] }
        let reply = await w46Chop(rig.router, rig.clipID, params)
        #expect(!reply.ok)
        #expect(reply.error?.contains(expected) == true, "\(name): \(reply.error ?? "-")")
        #expect(rig.store.tracks.count == before, "\(name): a refused chop must change nothing")
    }
}
