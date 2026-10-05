import Foundation
import Testing
@testable import DAWCore

// Tune to Melody, phase 2 — THE `melody: nil` BYTE-IDENTITY GOLDEN (lane W7-TTM).
//
// The melody parameter on `PitchAutoCorrect` must leave every melody-less pass exactly as it
// was. This suite renders a corpus of contours through the policy under every preset, three
// scales, three clip shifts and all four slide shapes, and writes or checks one normalised
// text per contour: the set's JSON with sorted keys (each segment id replaced by its order
// of first appearance; ids are random per build) plus the unpitched finder's result.
//
// ENV-GATED and read-only outside its own folder:
//  * `TTM_GOLDEN_WRITE=<dir>` writes the golden (captured from the code BEFORE the melody edit);
//  * `TTM_GOLDEN_CHECK=<dir>` recomputes and compares byte for byte;
//  * `TTM_REAL_TAKES=<path>[:<path>…]` adds the product's own `clip.detectPitch` responses.
// Not `@MainActor` (pure DAWCore).

enum MelodyGolden {
    static let write = ProcessInfo.processInfo.environment["TTM_GOLDEN_WRITE"]
    static let check = ProcessInfo.processInfo.environment["TTM_GOLDEN_CHECK"]
    static let realTakes = ProcessInfo.processInfo.environment["TTM_REAL_TAKES"]?
        .split(separator: ":").map(String.init) ?? []

    struct Contour {
        let name: String
        let frames: [ClipPitchFrame]
        let rate: Double
    }

    private struct Envelope: Decodable { let result: ClipPitchDetection }

    /// Synthetic contours (detector-shaped) plus every real take named in the environment,
    /// whole and in three windows.
    static func corpus() throws -> [Contour] {
        var out: [Contour] = [Contour(name: "synthetic-take", frames: MelodyTake.frames(), rate: MelodyTake.rate)]
        // The take again at a shifted bin grid and a different vibrato phase.
        out.append(Contour(name: "synthetic-take-late", frames: MelodyTake.frames().map {
            ClipPitchFrame(timeSeconds: $0.timeSeconds + 0.008, frequencyHz: $0.frequencyHz.map { $0 * 1.0123 },
                           confidence: $0.confidence, levelDbfs: $0.levelDbfs, absence: $0.absence)
        }, rate: MelodyTake.rate))
        // Three notes 40 c flat with gaps; a step inside one run; a glide.
        out.append(Contour(name: "flat-three", frames: MelodyFx.gap(from: 0, count: 70)
            + MelodyFx.held(59.6, from: 70, count: 40) + MelodyFx.gap(from: 110, count: 6)
            + MelodyFx.held(61.6, from: 116, count: 40) + MelodyFx.gap(from: 156, count: 6)
            + MelodyFx.held(63.6, from: 162, count: 40), rate: MelodyFx.rate))
        out.append(Contour(name: "step-and-glide", frames: MelodyFx.held(59.6, from: 0, count: 30)
            + MelodyFx.held(60.4, from: 30, count: 15) + MelodyFx.gap(from: 45, count: 8)
            + MelodyFx.held(57, from: 53, count: 30)
            + MelodyFx.line((83 ..< 108).map { 57 + 5 * Double($0 - 82) / 26 }, from: 83)
            + MelodyFx.held(62, from: 108, count: 30), rate: MelodyFx.rate))
        for path in realTakes {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let pitch = try JSONDecoder().decode(Envelope.self, from: data).result.pitch
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            out.append(Contour(name: "real-\(name)", frames: pitch.frames, rate: pitch.frameRateHz))
            let n = pitch.frames.count
            for (k, range) in [0 ..< n / 3, n / 3 ..< 2 * n / 3, 2 * n / 3 ..< n].enumerated() {
                out.append(Contour(name: "real-\(name)-w\(k)", frames: Array(pitch.frames[range]),
                                   rate: pitch.frameRateHz))
            }
        }
        return out
    }

    static let presets: [PitchCorrectionPreset] = [.gentle, .natural, .tight, .hardTune]
    static let scales: [PitchCorrectionScale] = [
        .chromatic, PitchCorrectionScale(tonicPitchClass: 0, mode: .major),
        PitchCorrectionScale(tonicPitchClass: 9, mode: .minor)
    ]
    static let shifts: [Double] = [0, 3, -2.3]

    /// Segment ids replaced by their order of first appearance.
    static func normalised(_ json: String) -> String {
        let pattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return json }
        let ns = json as NSString
        var ids: [String: Int] = [:]
        var out = ""
        var cursor = 0
        for match in regex.matches(in: json, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let id = ns.substring(with: match.range)
            let ordinal = ids[id] ?? ids.count
            ids[id] = ordinal
            out += "ID\(ordinal)"
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// THE CALL UNDER TEST: the policy with `melody: nil` passed EXPLICITLY (phase 2). The
    /// golden was written by this same text with the parameter absent, before it existed.
    static func build(_ contour: Contour, _ options: PitchAutoCorrectOptions, shape: PitchSlideShape,
                      shift: Double) -> PitchNoteTableBuild {
        PitchAutoCorrect.build(contour: contour.frames, frameRateHz: contour.rate, options: options,
                               slideShape: shape, clipShiftSemitones: shift, melody: nil)
    }

    static func editSet(_ contour: Contour, _ options: PitchAutoCorrectOptions,
                        shape: PitchSlideShape) -> PitchEditSet {
        PitchAutoCorrect.editSet(contour: contour.frames, frameRateHz: contour.rate, options: options,
                                 slideShape: shape, melody: nil)
    }

    /// The normalised text of one contour under every configuration.
    static func text(_ contour: Contour) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var out = ""
        for preset in presets {
            for scale in scales {
                let options = preset.options(scale: scale)
                for shape in PitchSlideShape.allCases {
                    for shift in shifts {
                        let built = build(contour, options, shape: shape, shift: shift)
                        let json = String(decoding: try encoder.encode(built.editSet), as: UTF8.self)
                        out += "\(preset.rawValue) \(scale.displayName) \(shape.rawValue) \(shift)\n"
                        out += normalised(json) + "\n"
                        out += String(describing: built.unpitched) + "\n"
                    }
                    let plain = String(decoding: try encoder.encode(editSet(contour, options, shape: shape)), as: UTF8.self)
                    out += "editSet \(preset.rawValue) \(scale.displayName) \(shape.rawValue)\n" + normalised(plain) + "\n"
                }
            }
        }
        return out
    }
}

@Suite("Tune to Melody phase 2: melody nil is byte-identical (golden, env-gated)")
struct PitchMelodyTargetGoldenTests {

    @Test("golden: write the melody-less policy's output for the corpus",
          .enabled(if: MelodyGolden.write != nil))
    func writeGolden() throws {
        let dir = try #require(MelodyGolden.write)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        for contour in try MelodyGolden.corpus() {
            let text = try MelodyGolden.text(contour)
            try text.write(toFile: "\(dir)/\(contour.name).txt", atomically: true, encoding: .utf8)
            lines.append("\(contour.name) bytes=\(text.utf8.count) segments=\(text.components(separatedBy: "\"detectedHz\"").count - 1)")
        }
        print("melody-golden-write| \(lines.joined(separator: " | "))")
        #expect(lines.count >= 4)
    }

    @Test("golden: the melody-less policy still writes exactly the golden",
          .enabled(if: MelodyGolden.check != nil))
    func checkGolden() throws {
        let dir = try #require(MelodyGolden.check)
        var checked = 0
        for contour in try MelodyGolden.corpus() {
            let golden = try String(contentsOfFile: "\(dir)/\(contour.name).txt", encoding: .utf8)
            let text = try MelodyGolden.text(contour)
            #expect(text == golden, "\(contour.name) differs from the golden")
            checked += 1
        }
        print("melody-golden-check| contours=\(checked)")
        #expect(checked >= 4)
    }
}
