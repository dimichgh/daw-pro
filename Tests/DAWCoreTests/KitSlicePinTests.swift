import Foundation
import Testing
@testable import DAWCore

// m39-w4-6 — design `docs/design/2026-10-07-loop-drum-depth.md` §9.2, gates C1 and C7.
//
// THE CHROMATIC CHOP IS PINNED, BEFORE KIT MAPPING EXISTED. The four plan goldens in
// `Fixtures/KitSliceBefore/` were written by THIS file (`W46_RECORD_DIR` set) from the tree as it stood
// before m39-w4-6 touched a line of Sources (W8-W46, 2026-10-07). A byte difference here means a call
// that does not name `mapping` no longer gets what it got yesterday: the additive-only law.
//
// NOT `@MainActor`: the planner and the project document codec are pure.
@Suite("Kit slicing — the chromatic chop is pinned (m39-w4-6 C1/C7)")
struct KitSlicePinTests {

    static let url = URL(fileURLWithPath: "/tmp/w46-pin/break.wav")
    static let tempo = TempoMap(constantBPM: 120)
    static let fixtureNames = ["transients", "transients-options", "divisions", "grid"]

    /// One chop's inputs: the clip, the geometry the engine would resolve, the detector strengths.
    static func inputs(_ name: String) -> (clip: Clip, geometry: SliceBoundaryGeometry,
                                           strengths: [Double], settings: SliceToSamplerSettings) {
        switch name {
        case "transients":
            // The default call: the head is discarded (and warned about), snaps moved, strengths vary.
            return (Clip(name: "Break", startBeat: 2, lengthBeats: 4, audioFileURL: url),
                    SliceBoundaryGeometry(sampleRate: 44_100, frameCount: 88_200,
                                          boundaryFrames: [11_030, 22_051, 44_098, 66_150],
                                          snapOffsetFrames: [5, 1, -2, 0],
                                          residualAmplitude: [0.0003, 0.001, 0.0002, 0]),
                    [0.9, 0.35, 1.0, 0.6],
                    SliceToSamplerSettings())
        case "transients-options":
            return (Clip(name: "Break", startBeat: 0, lengthBeats: 4, audioFileURL: url),
                    SliceBoundaryGeometry(sampleRate: 44_100, frameCount: 88_200,
                                          boundaryFrames: [11_030, 22_051, 44_098, 66_150],
                                          snapOffsetFrames: [5, 1, -2, 0],
                                          residualAmplitude: [0.0003, 0.001, 0.0002, 0]),
                    [0.9, 0.35, 1.0, 0.6],
                    SliceToSamplerSettings(includeHead: true, baseNote: 60, atBeat: 8,
                                           velocityFromStrength: true))
        case "divisions":
            return (Clip(name: "Loop", startBeat: 0, lengthBeats: 4, audioFileURL: url),
                    SliceBoundaryGeometry(sampleRate: 48_000, frameCount: 96_000,
                                          boundaryFrames: (1...7).map { $0 * 12_000 },
                                          snapOffsetFrames: Array(repeating: 0, count: 7),
                                          residualAmplitude: Array(repeating: 0, count: 7)),
                    [],
                    SliceToSamplerSettings(mode: .divisions, divisions: 8, atBeat: 16))
        default:
            // "grid": a TRIMMED window (offset 0.25 s, 3 beats = 1.5 s), so the last pad ends at the
            // window, not the file.
            return (Clip(name: "Groove", startBeat: 1, lengthBeats: 3, audioFileURL: url,
                         startOffsetSeconds: 0.25),
                    SliceBoundaryGeometry(sampleRate: 44_100, frameCount: 88_200,
                                          boundaryFrames: [22_050, 33_075, 44_100, 55_125, 66_150],
                                          snapOffsetFrames: Array(repeating: 0, count: 5),
                                          residualAmplitude: Array(repeating: 0, count: 5)),
                    [],
                    SliceToSamplerSettings(mode: .grid, gridBeats: 0.5, maxSlices: 16,
                                           baseNote: 48, snapWindowSeconds: 0))
        }
    }

    static func plan(_ name: String) throws -> SliceToSamplerPlan.Result {
        let input = inputs(name)
        return try SliceToSamplerPlan.compute(clip: input.clip, geometry: input.geometry,
                                              strengths: input.strengths, settings: input.settings,
                                              tempoMap: tempo)
    }

    /// The plan as sorted-key JSON, zone and note ids left out (they are fresh UUIDs every run).
    static func snapshot(_ plan: SliceToSamplerPlan.Result) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func withoutIDs(_ data: Data) throws -> [[String: Any]] {
            let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            return array.map { object in
                var copy = object
                copy.removeValue(forKey: "id")
                return copy
            }
        }
        let root: [String: Any] = [
            "zones": try withoutIDs(encoder.encode(plan.zones)),
            "notes": try withoutIDs(encoder.encode(plan.notes)),
            "slices": try JSONSerialization.jsonObject(with: encoder.encode(plan.slices)),
            "midiClipStartBeat": plan.midiClipStartBeat,
            "midiClipLengthBeats": plan.midiClipLengthBeats,
            "headSeconds": plan.headSeconds,
            "warnings": plan.warnings,
        ]
        return try JSONSerialization.data(withJSONObject: root,
                                          options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    static func firstDifference(_ a: Data, _ b: Data) -> String {
        let x = [UInt8](a), y = [UInt8](b)
        guard let i = zip(x, y).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
                ?? (x.count == y.count ? nil : min(x.count, y.count)) else { return "none" }
        let lo = max(0, i - 60)
        return "byte \(i): got …\(String(decoding: x[lo..<min(x.count, i + 60)], as: UTF8.self))… "
            + "want …\(String(decoding: y[lo..<min(y.count, i + 60)], as: UTF8.self))…"
    }

    // MARK: - C1: `mapping` absent is the pre-w4-6 plan, byte for byte

    @Test("C1: a chop that does not name a mapping plans byte-identically to the pre-w4-6 golden",
          arguments: KitSlicePinTests.fixtureNames)
    func chromaticPlanMatchesThePreChangeGolden(name: String) throws {
        let plan = try Self.plan(name)
        #expect(plan.zones.count >= 4, "control: the fixture really chops (\(plan.zones.count) pads)")
        #expect(plan.zones.allSatisfy { $0.chokeGroup == nil }, "a chromatic chop never chokes")
        #expect(plan.zones.allSatisfy { $0.drumRole == nil }, "a chromatic chop names no drum")
        let actual = try Self.snapshot(plan)
        if let dir = ProcessInfo.processInfo.environment["W46_RECORD_DIR"] {
            try actual.write(to: URL(fileURLWithPath: dir).appendingPathComponent("plan-\(name).json"))
            return
        }
        let golden = try #require(
            Bundle.module.url(forResource: "plan-\(name)", withExtension: "json",
                              subdirectory: "Fixtures/KitSliceBefore"),
            "the golden plan-\(name).json is not in the test bundle — a missing file must not read as a match")
        let expected = try Data(contentsOf: golden)
        #expect(expected.count > 400, "the golden is implausibly small (\(expected.count) bytes)")
        #expect(actual == expected, "C1 \(name): \(Self.firstDifference(actual, expected))")
    }

    // MARK: - C7: a file that never heard of drumRole

    static func tempBundle(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("w46-\(label)-\(UUID().uuidString).dawproj", isDirectory: true)
    }

    /// The fidelity suite's kitchen-sink golden was written before `drumRole` existed, and its one sampler
    /// zone sets every other zone field. Decode it and save it again: the bytes must not move.
    @Test("C7: the kitchen-sink golden, which has no drumRole key, re-saves byte-identically after a decode")
    func preDrumRoleFileResavesIdentically() throws {
        let golden = try #require(
            Bundle.module.url(forResource: "kitchen-sink", withExtension: "json",
                              subdirectory: "Fixtures/ProjectDocumentFidelity"))
        let bytes = try Data(contentsOf: golden)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("drumRole"),
                "control: the fixture must OMIT the key")
        let inBundle = Self.tempBundle("c7-in")
        let outBundle = Self.tempBundle("c7-out")
        defer {
            try? FileManager.default.removeItem(at: inBundle)
            try? FileManager.default.removeItem(at: outBundle)
        }
        try FileManager.default.createDirectory(at: inBundle, withIntermediateDirectories: true)
        try bytes.write(to: inBundle.appendingPathComponent("project.json"))
        let document = try ProjectBundle.read(from: inBundle)
        let zones = document.runtimeState(bundleURL: inBundle).tracks
            .compactMap { $0.instrument?.sampler?.zones }.flatMap { $0 }
        #expect(zones.count == 1, "control: the kitchen sink's sampler zone was decoded")
        #expect(zones.first?.chokeGroup == 5, "control: a neighbouring optional zone field decoded")
        #expect(zones.first?.drumRole == nil, "C7: an absent drumRole decodes to nil")
        try ProjectBundle.write(document: document,
                                plan: ProjectBundle.MediaPlan(copies: [], refs: [:], warnings: []),
                                to: outBundle)
        let resaved = try Data(contentsOf: outBundle.appendingPathComponent("project.json"))
        #expect(resaved == bytes, "C7: \(Self.firstDifference(resaved, bytes))")
    }
}
