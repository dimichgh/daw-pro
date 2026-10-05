import AVFoundation
import Foundation
import Testing

@testable import DAWCore
@testable import DAWEngine

/// **The four preset actions, rendered on a real voice, so a person can pick.**
///
/// `PitchCorrectionPreset`'s milliseconds are provisional — spaced to be
/// audibly distinct, with nothing about them validated by listening. A project
/// rule says the user's pick IS the feedback and that they should get 3–4
/// options rather than one result. This produces those options.
///
/// ⭐ IT ALSO ASSERTS THE THING A LISTENING TEST CANNOT: that the four presets
/// produced four DIFFERENT corrections. Four identical files are a perfectly
/// pleasant listening experience and a completely broken feature, and this
/// tree's characteristic failure is exactly that — something returns a
/// plausible-looking answer and nothing compares it to the truth.
///
///     M23Q_E2_SOURCE=/path/to/dry.wav M23Q_E2_OUT=/path/to/outdir ./scripts/test.sh
@Suite("m23-q preset listening render")
struct M23QPresetListeningTests {

    @Test("renders all four presets from one detected contour",
          .enabled(if: ProcessInfo.processInfo.environment["M23Q_E2_SOURCE"] != nil
                    && ProcessInfo.processInfo.environment["M23Q_E2_OUT"] != nil))
    func renderPresets() throws {
        let env = ProcessInfo.processInfo.environment
        let sourceURL = URL(fileURLWithPath: try #require(env["M23Q_E2_SOURCE"]))
        let outDir = URL(fileURLWithPath: try #require(env["M23Q_E2_OUT"]))
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // ---- detect ONCE. Every preset is a different reading of the SAME
        //      performance; re-detecting per preset would let detector
        //      nondeterminism masquerade as a preset difference.
        // ⚠️ `durationSeconds: 0` is a ZERO-LENGTH window, not "to the end" —
        // it fails with `.unreadable("empty analysis window")`. Read the real
        // length off the file.
        let file = try AVAudioFile(forReading: sourceURL)
        let fileSeconds = Double(file.length) / file.fileFormat.sampleRate
        let detected = try ClipPitchAnalyzer.detect(
            fileAt: sourceURL, fromSeconds: 0, durationSeconds: fileSeconds,
            confidenceThreshold: 0.5, silenceFloorDbfs: -45)
        print("contour: \(detected.frameCount) frames, "
            + "\(detected.voicedFrameCount) voiced "
            + "(\(Int(detected.voicedFraction * 100))%), "
            + "\(detected.frameRateHz) fps")
        #expect(detected.voicedFrameCount > 0,
                "no voiced frames: every preset is then a no-op and the renders are identical for a reason unrelated to the presets")

        let sr = 48000.0
        let hop = 1440                      // the renderer's own hop
        let durationSeconds = Double(detected.frameCount) / detected.frameRateHz
        let frames = Int(sr * durationSeconds)

        var fingerprints: [PitchCorrectionPreset: [Double]] = [:]

        for preset in PitchCorrectionPreset.allCases {
            let set = PitchAutoCorrect.editSet(
                contour: detected.frames,
                frameRateHz: detected.frameRateHz,
                options: preset.options())
            let pitchCurve = PitchCorrectionCurve.make(
                editSet: set, contour: detected.frames, clipPitchShiftSemitones: 0)

            // Sample the curve onto the renderer's grid. The stretch ratio here
            // is 1, so an output frame and a source frame are the same instant
            // — that identity is what makes this sampling legitimate, and it
            // would NOT hold under a time-stretch.
            var curve: [(outputFrame: Int, semitones: Double)] = []
            var f = 0
            while f < frames {
                curve.append((f, pitchCurve.semitones(atSourceSecond: Double(f) / sr)))
                f += hop
            }
            fingerprints[preset] = curve.map(\.semitones)

            let moved = curve.map { abs($0.semitones) }.filter { $0 > 0.001 }
            let medianCents = moved.isEmpty ? 0
                : moved.sorted()[moved.count / 2] * 100
            print(String(format:
                "%-9@  %2d notes  %4d/%d points moved  median %5.1f cents  "
                + "retune %3.0f ms  vibrato %@",
                preset.rawValue as NSString, set.segments.count,
                moved.count, curve.count, medianCents, set.retuneMs,
                (preset.options().preserveVibrato ? "kept" : "FLATTENED") as NSString))

            let r = try M23QComparisonPair.render(
                sourceURL: sourceURL, outputDirectory: outDir,
                constantSemitones: 0, curve: curve,
                formantPreserve: true, namePrefix: "preset-\(preset.rawValue)")
            print("   -> \(r.curveURL.lastPathComponent)")
        }

        // ---- ⭐ THE ASSERTION A LISTENING TEST CANNOT MAKE.
        // Four files that sound fine and are secretly identical is a broken
        // feature that passes every audibility check. Compare the CURVES, not
        // the bytes: distinct bytes would prove nothing, but two presets
        // producing the same requested correction proves one of them is inert.
        for a in PitchCorrectionPreset.allCases {
            for b in PitchCorrectionPreset.allCases where b.rawValue > a.rawValue {
                let fa = try #require(fingerprints[a]), fb = try #require(fingerprints[b])
                let diff = zip(fa, fb).map { abs($0 - $1) }.max() ?? 0
                #expect(diff > 0.001,
                        "\(a.rawValue) and \(b.rawValue) ask the SAME correction everywhere — one is inert")
            }
        }

        // And the boring invariance control, which is the one that actually
        // catches bugs: strength 0 must collapse to exact identity.
        let none = PitchAutoCorrect.editSet(
            contour: detected.frames, frameRateHz: detected.frameRateHz,
            options: PitchAutoCorrectOptions(strength: 0))
        #expect(none.segments.isEmpty, "strength 0 must produce NO segments at all")
        let flat = PitchCorrectionCurve.make(editSet: none, contour: detected.frames)
        #expect(flat.semitones(atSourceSecond: durationSeconds / 2) == 0,
                "strength 0 must be bit-for-bit the clip's own constant shift")
    }
}
