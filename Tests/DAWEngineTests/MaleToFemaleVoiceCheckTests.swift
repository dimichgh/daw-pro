import Foundation
import Testing

@testable import AIServices
@testable import DAWCore
@testable import DAWEngine

// W9-MF phase 1 (a male singing voice made from the films' SYNTHETIC narrator): every candidate recording through
// THE PRODUCT'S OWN voice check, `SingVoicePreparation.prepare` (what `sing.addVoice` runs), into a TEST voice library.
// It is the gate of record; a candidate's full `VoiceClipCheck` result (alignment r, coverage, levels, true peak) is
// written beside it so a refusal comes with its numbers.
//
// ⛔ ENV-GATED: runs ONLY with `MF_VOICE_CHECK=1`. `MF_CANDIDATES` = a folder of WAVs, `MF_VOICES` = the test library
// root (refused unless it is under the lane's scratch folder: never the user's Application Support voices),
// `MF_OUT` = the JSON report path. Files whose name starts with `control-` are positive controls and must pass.
// Deliberately NOT `@MainActor` (the suite cap); nothing here touches the main actor.

@Suite("W9-MF: narrator takes through the product's voice check (MF_VOICE_CHECK=1 only)")
struct MaleToFemaleVoiceCheckTests {

    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["MF_VOICE_CHECK"] == "1"

    static func json<T: Encodable>(_ value: T) -> Any {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }

    @Test("W9-MF: every candidate through SingVoicePreparation.prepare, with its full VoiceClipCheck result",
          .enabled(if: MaleToFemaleVoiceCheckTests.enabled))
    func voiceCheck() async throws {
        guard let candidatesPath = Self.env["MF_CANDIDATES"], let rootPath = Self.env["MF_VOICES"],
              let outPath = Self.env["MF_OUT"] else {
            Issue.record("MF_CANDIDATES, MF_VOICES and MF_OUT must be set")
            return
        }
        guard rootPath.hasPrefix("/private/tmp/claude-501/"), !rootPath.contains("Application Support") else {
            Issue.record("refusing voice library root \(rootPath): tests inject their own scratch root")
            return
        }
        let fm = FileManager.default
        let library = SingVoiceLibrary(root: URL(fileURLWithPath: rootPath, isDirectory: true))
        let files = try fm.contentsOfDirectory(at: URL(fileURLWithPath: candidatesPath, isDirectory: true),
                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let detect: @Sendable (URL, Double) async throws -> [ClipPitchFrame] = { url, seconds in
            // The app's `singPitch` (`DAWProApp`): `AudioEngine.detectPitch(inFileAt:…)`'s body.
            try await Task.detached(priority: .userInitiated) {
                try ClipPitchAnalyzer.detect(
                    fileAt: url, fromSeconds: 0, durationSeconds: seconds,
                    confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
                    silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs).frames
            }.value
        }
        var rows: [[String: Any]] = []
        var controlFailures: [String] = []
        var passed: [String] = []
        for file in files {
            let name = file.lastPathComponent
            var row: [String: Any] = ["file": name, "path": file.path]
            let seconds = try SingVoiceAudioDecoder.durationSeconds(of: file)
            let audio = try SingVoiceAudioDecoder.decode(file, startSeconds: 0, durationSeconds: seconds)
            let frames = try await detect(file, seconds)
            let check = VoiceClipCheck.run(recording: audio, pitchFrames: frames)
            row["check"] = Self.json(check)
            let confident = frames.filter {
                $0.frequencyHz != nil && $0.confidence >= PitchDetectionDefaults.defaultConfidenceThreshold
            }
            row["frames"] = frames.count
            row["confidentFrames"] = confident.count
            do {
                let record = try await SingVoicePreparation.prepare(
                    source: file, name: "W9-MF \(name)", kind: .file, sourceName: name, library: library,
                    detectPitch: detect)
                row["prepare"] = "passed"
                row["voiceId"] = record.id
                row["range"] = Self.json(record.range)
                row["labelsVerdict"] = record.labels.verdict.rawValue
                row["referenceSha256"] = record.referenceSha256
                passed.append(name)
            } catch let refusal as SingVoiceAddRefusal {
                row["prepare"] = "refused"
                row["code"] = refusal.code
                row["sentence"] = refusal.sentence
            }
            let ok = row["prepare"] as? String == "passed"
            if name.hasPrefix("control-"), !ok { controlFailures.append(name) }
            let a = check.alignment
            print("mf| \(name): prepare \(row["prepare"] ?? "-") \(row["code"] ?? "") | tau \(a.tauSeconds.map { "\($0)" } ?? "nil") "
                  + "r \(a.r.map { "\($0)" } ?? "nil") coverage \(a.coverage) | first failure "
                  + "\(check.firstFailure?.rawValue ?? "none") | failed \(check.failed.map(\.rawValue))")
            rows.append(row)
            let report: [String: Any] = ["rows": rows, "passed": passed, "controlFailures": controlFailures,
                                         "libraryRoot": rootPath]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: outPath))
        }
        print("mf| passed: \(passed.count) of \(files.count): \(passed); control failures: \(controlFailures)")
        #expect(controlFailures.isEmpty, "a positive control did not pass the product's voice check: \(controlFailures)")
        #expect(files.contains { $0.lastPathComponent.hasPrefix("control-") }, "no positive control was supplied")
    }
}
