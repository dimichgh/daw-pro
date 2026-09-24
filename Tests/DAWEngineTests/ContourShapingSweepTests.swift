import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// contour-to-render — **WHERE THE NUMBERS IN `PitchRenderContour.shapingVersion`'s
/// DOC COME FROM**, kept so they can be re-derived rather than trusted.
/// Env-gated (it is a measurement, not a gate):
///
///     CONTOUR_SWEEP=1 ./scripts/test.sh --filter ContourShapingSweepTests
///
/// Two questions, two instruments:
///  * **the render** — `vibratoScale: 0` alone against Hard Tune's
///    composition (`driftScale: 0` too) on 5.5 Hz ±45–50-cent vibrato at A3,
///    B3 and C4, through `StretchRenderCache`, read by `PitchWanderMeter`;
///  * **the arithmetic alone** — the same curves evaluated WITHOUT the
///    stretcher (`sung(t) + curve(t)`), plus the detector's own depth ratio,
///    so what the curve does and what the transposer adds are separable.
///
/// Measured 2026-09-24 (render): vibratoScale-0-only cuts 56 % at A3 and
/// 33–34 % at B3; Hard Tune's composition 48–58 % across all of them. The
/// arithmetic alone leaves 2.6–8.2 cents in every case — the renderer's 30 ms
/// hop is most of what remains.
@Suite("contour-to-render — shaping sweep (measurement)", .serialized)
struct ContourShapingSweepTests {
    static let enabled = ProcessInfo.processInfo.environment["CONTOUR_SWEEP"] != nil
    static let sampleRate = 48_000.0

    static func log(_ message: String) { print("contour-sweep| \(message)") }

    /// Segments from the detector's own voiced runs, with the given scales.
    static func set(_ detection: PitchDetectionResult,
                    drift: (Int) -> Double, vibrato: (Int) -> Double) -> PitchEditSet {
        let runs = PitchAutoCorrect.voicedRuns(in: detection.frames,
                                               frameRateHz: detection.frameRateHz)
        // p2-seg §5.2: every fixture here is one steady vibrato note per run, so
        // the note splitter must return each run whole (the same three-note
        // input is gated env-free in `ContourToRenderTests`).
        let invariance = PrePitchNoteSplitReference.invarianceFailures(frames: detection.frames,
                                                                       frameRateHz: detection.frameRateHz)
        #expect(invariance.isEmpty, "\(invariance.prefix(3))")
        return PitchEditSet(segments: runs.enumerated().map { index, run in
            NoteSegment(startSeconds: run.startSeconds, endSeconds: run.endSeconds,
                        detectedHz: run.centreHz, detectedConfidence: run.medianConfidence,
                        driftScale: drift(index), vibratoScale: vibrato(index))
        }, retuneMs: 30)
    }

    static func threeNotes() -> [Float] {
        var input: [Float] = []
        for (i, hz) in [220.0, 246.94, 261.63].enumerated() {
            input += ContourToRenderTests.tone(seconds: 0.9) { t in
                hz * pow(2, 45 * sin(2 * .pi * 5.5 * t) / 1200)
            }
            if i < 2 { input += [Float](repeating: 0, count: Int(0.3 * sampleRate)) }
        }
        return input
    }

    @MainActor
    static func render(_ label: String, input: [Float],
                       makeSet: (PitchDetectionResult) -> PitchEditSet) async throws {
        let dir = try ContourToRenderTests.tempDir("sweep")
        let source = dir.appendingPathComponent("x.wav")
        try ContourToRenderTests.write(input, to: source)
        let set = makeSet(try PitchContourCache.detectWholeFile(source, .product))
        let cache = StretchRenderCache(directory: try ContourToRenderTests.tempDir("sweep-cache"))
        let rendered = try await ContourToRenderTests.productRender(
            Clip(name: "sweep", audioFileURL: source, pitchEdits: set), cache: cache)
        let before = PitchWanderMeter.readNotes(try ContourToRenderTests.uncorrected(input),
                                                sampleRate: sampleRate, segments: set.segments)
        let after = Dictionary(uniqueKeysWithValues: PitchWanderMeter.readNotes(
            rendered.audio, sampleRate: sampleRate, segments: set.segments)
            .map { ($0.segmentID, $0) })
        for (i, b) in before.enumerated() {
            guard let a = after[b.segmentID],
                  let segment = set.segments.first(where: { $0.id == b.segmentID }) else { continue }
            log(String(format: "render %@ note %d (%.1f Hz, drift %.0f vibrato %.0f): %.2f -> %.2f c (%.0f%%)",
                       label as NSString, i + 1, segment.detectedHz, segment.driftScale,
                       segment.vibratoScale, b.spreadCents, a.spreadCents,
                       (1 - a.spreadCents / b.spreadCents) * 100))
        }
    }

    @Test("the render: vibratoScale 0 alone vs Hard Tune's composition", .enabled(if: enabled))
    @MainActor
    func renderSweep() async throws {
        try await Self.render("3 notes, vibrato 0 on all", input: Self.threeNotes()) {
            Self.set($0, drift: { _ in 1 }, vibrato: { _ in 0 })
        }
        try await Self.render("3 notes, drift 0 + vibrato 0 on all", input: Self.threeNotes()) {
            Self.set($0, drift: { _ in 0 }, vibrato: { _ in 0 })
        }
        let b3 = ContourToRenderTests.tone(seconds: 3) { t in
            246.94 * pow(2, 45 * sin(2 * .pi * 5.5 * t) / 1200)
        }
        try await Self.render("3 s B3, vibrato 0", input: b3) {
            Self.set($0, drift: { _ in 1 }, vibrato: { _ in 0 })
        }
        try await Self.render("3 s B3, drift 0 + vibrato 0", input: b3) {
            Self.set($0, drift: { _ in 0 }, vibrato: { _ in 0 })
        }
        let a3 = ContourToRenderTests.vibratoNote()
        try await Self.render("3 s A3+35c, vibrato 0", input: a3) {
            Self.set($0, drift: { _ in 1 }, vibrato: { _ in 0 })
        }
        try await Self.render("3 s A3+35c, drift 0 + vibrato 0", input: a3) {
            Self.set($0, drift: { _ in 0 }, vibrato: { _ in 0 })
        }
    }

    /// `sung(t) + curve(t)` every 1 ms over the note interior — no stretcher —
    /// and the detector's depth ratio (regression of detected cents, placed at
    /// frame centres, on sung cents).
    static func arithmetic(_ label: String, hz: Double, depth: Double,
                           detune: Double = 0, seconds: Double = 3) throws {
        let dir = try ContourToRenderTests.tempDir("sweep-arith")
        let source = dir.appendingPathComponent("x.wav")
        func sung(_ t: Double) -> Double { detune + depth * sin(2 * .pi * 5.5 * t) }
        try ContourToRenderTests.write(ContourToRenderTests.tone(seconds: seconds) { t in
            hz * pow(2, sung(t) / 1200)
        }, to: source)
        let detection = try PitchContourCache.detectWholeFile(source, .product)
        var xs: [Double] = [], ys: [Double] = []
        for frame in detection.frames {
            guard let f = frame.frequencyHz else { continue }
            let t = frame.timeSeconds + 0.5 / detection.frameRateHz
            guard t > 0.1, t < seconds - 0.1 else { continue }
            xs.append(sung(t))
            ys.append(1200 * log2(f / hz))
        }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0
        for (x, y) in zip(xs, ys) { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx) }
        let depthRatio = sxy / sxx
        let contour = PitchRenderContour.detected(detection)
        for (name, drift, vibrato) in [("vibrato 0", 1.0, 0.0), ("drift 0 + vibrato 0", 0.0, 0.0)] {
            let edits = Self.set(detection, drift: { _ in drift }, vibrato: { _ in vibrato })
            let curve = contour.curve(editSet: edits, clipPitchShiftSemitones: 0)
            let segment = edits.segments[0]
            var out: [Double] = []
            var t = segment.startSeconds + 0.1
            while t < segment.endSeconds - 0.1 {
                out.append(sung(t) + 100 * curve.semitones(atSourceSecond: t))
                t += 0.001
            }
            let mean = out.reduce(0, +) / Double(out.count)
            let spread = (out.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(out.count))
                .squareRoot()
            log(String(format: "arithmetic %@ %@: detector reads %.0f%% of the depth | curve alone leaves %.2f c of %.2f c",
                       label as NSString, name as NSString, depthRatio * 100, spread,
                       depth / 2.0.squareRoot()))
        }
    }

    @Test("the arithmetic alone, and the detector's depth, per pitch", .enabled(if: enabled))
    func arithmeticSweep() throws {
        try Self.arithmetic("A3 +35c ±50", hz: 220, depth: 50, detune: 35)
        try Self.arithmetic("A3 ±45", hz: 220, depth: 45)
        try Self.arithmetic("B3 ±45", hz: 246.94, depth: 45)
        try Self.arithmetic("C4 ±45", hz: 261.63, depth: 45)
    }
}
