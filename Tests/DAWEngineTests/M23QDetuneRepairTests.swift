import AVFoundation
import Foundation
import Testing

@testable import DAWCore
@testable import DAWEngine

/// **Break it on purpose, then fix it.** The end-to-end demonstration — and the
/// strongest functional test in this feature, for the same reason.
///
/// ⛔ WHY THIS EXISTS. The first listening test asked a person to distinguish
/// corrections of 8–18 cents across separate 33-second files. They could not,
/// and they were right not to: measured, the singer's note centres sit ~18
/// cents from pitch, so a FULL correction moves them ~18 cents — at the edge of
/// discrimination, and only in direct comparison. **A demo whose effect is
/// below the threshold of the instrument being used to judge it (here, an ear)
/// is not a demo.** I checked the files were loud enough to hear and never
/// checked the DIFFERENCE was large enough to hear.
///
/// ⭐ SO THIS MAKES THE EFFECT LARGE BY MAKING THE PROBLEM LARGE. Detune each
/// detected note by a deterministic ±35–50 cents — audibly sour — then run the
/// corrector on the DETUNED audio and see whether it comes back. That is a
/// round trip through detection, policy, curve and renderer, and it has a
/// property the preset test does not: **a known right answer.** The repaired
/// take should land closer to the scale than the detuned one by roughly the
/// amount that was broken.
///
///     M23Q_E2_SOURCE=/path/to/dry.wav M23Q_E2_OUT=/path/to/outdir ./scripts/test.sh
@Suite("m23-q detune-and-repair round trip")
struct M23QDetuneRepairTests {

    @Test("a deliberately detuned take is measurably repaired by .tight",
          .enabled(if: ProcessInfo.processInfo.environment["M23Q_E2_SOURCE"] != nil
                    && ProcessInfo.processInfo.environment["M23Q_E2_OUT"] != nil))
    func detuneThenRepair() throws {
        let env = ProcessInfo.processInfo.environment
        let sourceURL = URL(fileURLWithPath: try #require(env["M23Q_E2_SOURCE"]))
        let outDir = URL(fileURLWithPath: try #require(env["M23Q_E2_OUT"]))
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let sr = 48000.0, hop = 1440
        let file = try AVAudioFile(forReading: sourceURL)
        let fileSeconds = Double(file.length) / file.fileFormat.sampleRate

        // ---- 1. detect the original
        let orig = try ClipPitchAnalyzer.detect(
            fileAt: sourceURL, fromSeconds: 0, durationSeconds: fileSeconds,
            confidenceThreshold: 0.5, silenceFloorDbfs: -45)
        let runs = PitchAutoCorrect.voicedRuns(
            in: orig.frames, frameRateHz: orig.frameRateHz)
        #expect(!runs.isEmpty)

        // ---- 2. DETUNE. Deterministic, not random: a seeded LCG, so a failure
        //        reproduces. Alternating sign so the take wanders both ways
        //        rather than sitting flat, which a listener hears as "sour"
        //        rather than as "a different key".
        // ⛔ A BLIND ±40 CENT OFFSET DOES NOT WORK, MEASURED: these notes
        // already sit ~19 cents off, so adding 40 pushes them ACROSS the
        // halfway line and they land near the NEXT semitone — barely "out of
        // tune" at all by any nearest-semitone measure, which saturates at 50.
        // First attempt moved the median error 18.8 → 19.9 c and the positive
        // control correctly refused it.
        //
        // ⭐ SO PUSH EACH NOTE AWAY FROM ITS OWN NEAREST SEMITONE, to a fixed
        // 45 cents in the direction it is already leaning. That is maximally
        // sour WITHOUT changing which note it is, which is the sound we want
        // to demonstrate — "flat/sharp", not "wrong note".
        var seed: UInt64 = 0x5EED
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) % 1000) / 1000.0
        }
        var offsets: [(start: Double, end: Double, cents: Double)] = []
        for r in runs {
            let midi = 69 + 12 * log2(r.centreHz / 440.0)
            let dev = (midi - midi.rounded()) * 100          // −50…+50
            let lean: Double = dev >= 0 ? 1 : -1
            let target = lean * (42.0 + next() * 6.0)        // 42…48, same side
            offsets.append((r.startSeconds, r.endSeconds, target - dev))
        }
        func detuneAt(_ second: Double) -> Double {
            for o in offsets where second >= o.start && second < o.end {
                return o.cents / 100.0
            }
            return 0
        }
        let frames = Int(sr * fileSeconds)
        var detuneCurve: [(outputFrame: Int, semitones: Double)] = []
        var f = 0
        while f < frames { detuneCurve.append((f, detuneAt(Double(f) / sr))); f += hop }

        let broken = try M23QComparisonPair.render(
            sourceURL: sourceURL, outputDirectory: outDir,
            constantSemitones: 0, curve: detuneCurve,
            formantPreserve: true, namePrefix: "repair-01-detuned")
        print("detuned \(runs.count) notes by ±35–50 cents -> "
            + broken.curveURL.lastPathComponent)

        // ---- 3. REPAIR: detect the DETUNED audio and correct it. Nothing from
        //        step 1 is reused — that would be cheating, and would test
        //        arithmetic rather than the feature.
        let reDetected = try ClipPitchAnalyzer.detect(
            fileAt: broken.curveURL, fromSeconds: 0, durationSeconds: fileSeconds,
            confidenceThreshold: 0.5, silenceFloorDbfs: -45)
        let set = PitchAutoCorrect.editSet(
            contour: reDetected.frames, frameRateHz: reDetected.frameRateHz,
            options: PitchCorrectionPreset.tight.options())
        let curveObj = PitchCorrectionCurve.make(
            editSet: set, contour: reDetected.frames, clipPitchShiftSemitones: 0)
        var fixCurve: [(outputFrame: Int, semitones: Double)] = []
        f = 0
        while f < frames {
            fixCurve.append((f, curveObj.semitones(atSourceSecond: Double(f) / sr)))
            f += hop
        }
        let fixed = try M23QComparisonPair.render(
            sourceURL: broken.curveURL, outputDirectory: outDir,
            constantSemitones: 0, curve: fixCurve,
            formantPreserve: true, namePrefix: "repair-02-fixed")
        print("repaired with .tight (\(set.segments.count) notes) -> "
            + fixed.curveURL.lastPathComponent)

        // ---- 4. THE ASSERTION WITH A KNOWN RIGHT ANSWER.
        // Distance from the nearest semitone, at NOTE-CENTRE level (a per-frame
        // measure would be dominated by vibrato, which is not error).
        func centreError(_ url: URL) throws -> Double {
            let d = try ClipPitchAnalyzer.detect(
                fileAt: url, fromSeconds: 0, durationSeconds: fileSeconds,
                confidenceThreshold: 0.5, silenceFloorDbfs: -45)
            let rs = PitchAutoCorrect.voicedRuns(in: d.frames, frameRateHz: d.frameRateHz)
            let errs = rs.map { r -> Double in
                let midi = 69 + 12 * log2(r.centreHz / 440.0)
                return abs(midi - midi.rounded()) * 100
            }
            return errs.isEmpty ? .nan : errs.sorted()[errs.count / 2]
        }
        let eOrig = try centreError(sourceURL)
        let eBroken = try centreError(broken.curveURL)
        let eFixed = try centreError(fixed.curveURL)
        print(String(format:
            "median note-centre error — original %.1f c | detuned %.1f c | repaired %.1f c",
            eOrig, eBroken, eFixed))

        // The detune must actually have made it worse, or the repair proves
        // nothing. This is the positive control on the whole experiment.
        #expect(eBroken > eOrig + 15,
                "the detune did not make the take measurably worse, so the repair below is untested")
        // And the repair must recover most of it.
        #expect(eFixed < eBroken - 10,
                "repaired take is no closer to pitch than the detuned one")
    }
}
