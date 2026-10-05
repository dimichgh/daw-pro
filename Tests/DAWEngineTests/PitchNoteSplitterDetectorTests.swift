import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// p2-seg S2 — **THE NOTE SPLITTER ON THE REAL DETECTOR'S FRAMES** (design
/// `docs/design/2026-09-24-pitch-note-splitting.md` §5.3, last bullet).
///
/// The §5.3 fixtures in `PitchNoteSplitterTests` (DAWCoreTests) are hand-built
/// contours quantised to SwiftF0's 25.79 c bins. They model the argmax staircase
/// at its worst, but not what a real voice-like tone does through the product
/// detector: the low-pitch under-read, the edge frames, anything else SwiftF0
/// does (design §10 item 4). This suite synthesises the design point — a
/// ±40 c, 5.5 Hz vibrato — at 106 Hz (this singer's median) and at 220 Hz, runs
/// the PRODUCT detector (`PitchContourCache.detectWholeFile(…, .product)`, the
/// render's and the editor's own entry point), then the splitter. Pass: ONE part
/// each, equal to its `voicedRuns` element, with both note-table builders
/// writing the pre-p2-seg table (the §5.2 legs).
///
/// ⭐ **THE TWIN THAT MUST SPLIT.** The same tone with a 200 c legato step
/// halfway (no gap: the singer never stops) must come out as two held notes,
/// cut at the step. Without it, "ONE part" could be a splitter that never
/// splits on real frames.
///
/// Env-free: it runs in every `./scripts/test.sh`. Pure detector + DAWCore:
/// NOT `@MainActor`, at suite or test level (`MainActorOccupancySiteTests`
/// Leg C counts suite-level isolation; cap 394, census 393).
@Suite("p2-seg S2 — the note splitter on the real detector's frames")
struct PitchNoteSplitterDetectorTests {
    static func log(_ message: String) { print("splitter-detector| \(message)") }

    /// The tone through the product detector.
    static func detect(seconds: Double, hz: @escaping (Double) -> Double,
                       label: String) throws -> PitchDetectionResult {
        let url = try ContourToRenderTests.tempDir("splitter-detector").appendingPathComponent("\(label).wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try ContourToRenderTests.write(ContourToRenderTests.tone(seconds: seconds, hz: hz), to: url)
        return try PitchContourCache.detectWholeFile(url, .product)
    }

    /// Max − min of the voiced frames' cents over `run`, re its own centre: how
    /// much wobble the DETECTOR delivered (a flat line would make "one part"
    /// true for nothing).
    static func spreadCents(_ detection: PitchDetectionResult, _ run: VoicedRun) -> Double {
        let cents = detection.frames.compactMap { frame -> Double? in
            guard let hz = frame.frequencyHz, frame.timeSeconds >= run.startSeconds,
                  frame.timeSeconds < run.endSeconds else { return nil }
            return PitchCorrectionMath.cents(from: run.centreHz, to: hz)
        }
        return (cents.max() ?? 0) - (cents.min() ?? 0)
    }

    @Test("§5.3 a ±40 c, 5.5 Hz vibrato through the product detector is ONE note, equal to voicedRuns",
          arguments: [106.0, 220.0])
    func designPointVibratoIsOneNote(baseHz: Double) throws {
        let detection = try Self.detect(seconds: 2.0, hz: { t in
            baseHz * pow(2, 40 * sin(2 * .pi * 5.5 * t) / 1200)
        }, label: "vibrato-\(Int(baseHz))")
        let runs = PitchAutoCorrect.voicedRuns(in: detection.frames, frameRateHz: detection.frameRateHz)
        let longest = try #require(runs.max { $0.frameCount < $1.frameCount }, "the detector found no note")
        // The fixture must reach the splitter AS A WOBBLE: more than one detector
        // bin of spread (the same 25.79 c bin the §5.3 contours are quantised to).
        let spread = Self.spreadCents(detection, longest)
        let parts = PitchNoteSplitter.parts(in: detection.frames, frameRateHz: detection.frameRateHz)
        Self.log(String(format: "%.0f Hz: %d frames, %d voiced, %d run(s), longest %d frames, detected wobble %.1f c peak-to-peak (sung 80), %d part(s): %@",
                        baseHz, detection.frameCount, detection.voicedFrameCount, runs.count,
                        longest.frameCount, spread, parts.count,
                        parts.map { "\($0.kind == .held ? "H" : "T")\($0.frameCount)" }.joined(separator: " ") as NSString))
        #expect(spread > 25.79, "the detector delivered \(spread) c of wobble: this proves nothing about wobble")
        #expect(longest.frameCount >= 100, "a 2 s tone must be one long run, not \(longest.frameCount) frames")
        // THE PASS CONDITION: one part per run, each the run itself, and the
        // pre-p2-seg table from both builders (design §5.2's three legs).
        #expect(parts.count == runs.count)
        let invariance = PrePitchNoteSplitReference.invarianceFailures(frames: detection.frames,
                                                                       frameRateHz: detection.frameRateHz)
        #expect(invariance.isEmpty, "\(baseHz) Hz: \(invariance.prefix(3))")
    }

    @Test("§5.3 twin: the same vibrato with a 200 c legato step halfway splits into two held notes at the step",
          arguments: [106.0, 220.0])
    func legatoStepThroughTheDetectorSplits(baseHz: Double) throws {
        let detection = try Self.detect(seconds: 2.0, hz: { t in
            baseHz * pow(2, ((t < 1.0 ? 0 : 200) + 40 * sin(2 * .pi * 5.5 * t)) / 1200)
        }, label: "step-\(Int(baseHz))")
        let runs = PitchAutoCorrect.voicedRuns(in: detection.frames, frameRateHz: detection.frameRateHz)
        let longest = try #require(runs.max { $0.frameCount < $1.frameCount }, "the detector found no note")
        try #require(longest.startSeconds < 0.9 && longest.endSeconds > 1.1,
                     "the step must sit inside ONE voiced run, or this twin tests the hole rule instead")
        let parts = PitchNoteSplitter.parts(in: detection.frames, frameRateHz: detection.frameRateHz)
            .filter { $0.startSeconds >= longest.startSeconds && $0.endSeconds <= longest.endSeconds }
        Self.log(String(format: "%.0f Hz + 200 c step at 1.0 s: run %.3f–%.3f s, parts %@",
                        baseHz, longest.startSeconds, longest.endSeconds,
                        parts.map { String(format: "%@%d@%.3f", ($0.kind == .held ? "H" : "T") as NSString,
                                           $0.frameCount, $0.startSeconds) }
                            .joined(separator: " ") as NSString))
        let held = parts.filter { $0.kind == .held }
        try #require(held.count == 2, "\(parts.map(\.kind))")
        // Cut at the step: the second held note starts within 2 frames of 1.0 s
        // (a legato step has no link; the de-glitch and the frame grid allow ±2).
        #expect(abs(held[1].startSeconds - 1.0) <= 2 / detection.frameRateHz + 1e-9,
                "second note starts at \(held[1].startSeconds) s")
        // Each held note is centred on ITS OWN note, ~200 c apart, not on one pitch.
        let step = PitchCorrectionMath.cents(from: held[0].centreHz, to: held[1].centreHz)
        #expect(abs(step - 200) < 25.79, "the two notes are \(step) c apart")
        // And the RUN rule still sees one run across the step (design §0 point 1).
        #expect(runs.filter { $0.startSeconds < 1.0 && $0.endSeconds > 1.0 }.count == 1)
    }
}
