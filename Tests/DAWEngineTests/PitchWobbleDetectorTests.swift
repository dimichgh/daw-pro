import Foundation
import Testing

@testable import DAWCore
@testable import DAWEngine

/// m23-ap C5a-0b — **THE WOBBLE ESTIMATOR THROUGH THE REAL DETECTOR: THE
/// PRODUCT CHAIN'S OWN BOUNDS** (design
/// `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §18.1.2, §18.1.4,
/// §18.1.6, §18.2; §15 T6). Env-gated, the `ContourShapingSweepTests` pattern:
///
///     WOBBLE_DETECTOR=1 ./scripts/test.sh --filter PitchWobbleDetectorTests
///     WOBBLE_VOCAL=/path/to/dry.wav ./scripts/test.sh --filter PitchWobbleDetectorTests
///
/// Every tone is written to disk and put through THE seam
/// (`PitchContourCache.renderContour`, product detector, committed to and read
/// back from its cache), segmented by `PitchAutoCorrect.voicedRuns`, and read
/// by `PitchWobbleEstimate.sung` — the chain a person's readout comes from.
/// **Anything a person is ever shown must respect THIS suite, never T5**
/// (§18.1.1). The detector is deterministic on fixed fixtures, so a bound a
/// little past a measurement flags a real change, not noise.
///
/// Every bound here is a MEASUREMENT plus headroom, with the plant that must
/// still turn it red (§18.1.2's pattern). The measurements are this suite's
/// own `wobble-detector|` lines.
///
/// **MEASURED 2026-09-24 (C5a-0b), through the seam** — the detector is
/// deterministic, so every run prints the same numbers:
///  * T6 canonical: A3 rate error −0.002 Hz, depth 0.843 of the truth, anchor
///    −1.95 ms; B3 −0.001 Hz, 0.893, −1.61 ms.
///  * The mid grid reproduces C5a-0's measurement EXACTLY: rate p95 0.0483 /
///    0.0455 Hz at 0.6 s and 0.0039–0.0201 Hz at ≥ 1.0 s; share 0.747–0.987,
///    median 0.8775 (±40 c alone 0.845, ±80 c alone 0.893); anchor p95
///    3.10–4.79 ms. The ±20 c band: 36 of 36 `.noWobble`, fitted 3.41–9.04 c.
///  * Under the 20 c report floor, ±25 c is `.noWobble` at A3, B3 and E4, and
///    at E4 so is ±30 c (it fits 18.1 c): the floor's price at E4 is ±30 c,
///    not the ±25 c §18.1.4 states.
///  * §18.1.6's low block: **82.4 Hz and 110.0 Hz hit §18.4's STOP
///    CONDITION** (`response` is `nil` there); 146.8 Hz holds (median 0.834).
///    The low-pitch share falls with the wobble's RATE (110 Hz, 8 partials,
///    ±40 c: 0.775 at 4.5 Hz, 0.472 at 7.5 Hz), so no per-pitch median is
///    exact there.
///  * ⚠️ **SwiftF0's lag is PITCH-DEPENDENT.** The read crossing lands AFTER
///    the true one by +8.3…+13.6 ms at 82.4 Hz, +11.1…+12.4 at 110 Hz and
///    +3.5…+8.1 at 146.8 Hz (signed), against −1.6 / −2.0 ms at mid pitch:
///    the frame-centre offset is right at mid pitch only. At 5.5 Hz, 12 ms is
///    24° of phase — the jump a handoff exists to avoid (C5a-1 / C5a-4).
///
/// **PLANTED DEFECTS**, each applied in an ISOLATED COPY of the tree, seen
/// red, and reverted (C5a-0b, 2026-09-24):
///  * +0.1 Hz on the refined rate → the canonical note (0.098 Hz > 0.03), the
///    mid table (p95 0.120 Hz > 0.07 at 0.6 s), the low block (146.8 Hz:
///    0.111 > 0.03).
///  * depth × 0.85 → the mid table (share 0.684 < 0.70), the low block
///    (146.8 Hz: 0.680 < 0.69), the calibration (median 0.746 vs 0.88).
///  * depth × 1.10 → the mid table (1.021 > 1.02), the low block (12 notes at
///    146.8 Hz past 0.93, and 110 Hz's stop pin: "now fits — re-derive"),
///    the calibration, and the edges (127.1 Hz: 1.19 > 1.1).
///  * anchor + a quarter period → the canonical note (43.5 ms), the mid table
///    (p95 53.5 ms > 6), the low block (146.8 Hz: 62.9 ms > 11).
///  * the TRUE contour fed past the detector → the ±20 c tripwire: all 36
///    fit 20.00 c ≥ 12.90. ⚠️ Only 2 of the 36 read `.wobble`: the exact
///    contour fits 19.99999 c, a hair UNDER the 20 c report floor, so the
///    `.noWobble` half alone would have stayed green on 34 of 36.
///  * `reportFloorCents` back to 12.9 → the A3 sweep (A3 + 14/16/18 c read a
///    wobble, exactly §18.1.4's prediction) and the 110 Hz sweep (5 offsets).
///  * `response` returning 1.0 → the calibration (|1.0 − 0.8775| = 0.12) and
///    the low block's stopped-pitch pins.
///
/// Deliberately NOT `@MainActor` (`MainActorOccupancySiteTests` Leg C is at
/// its cap): `detectWholeFile` is synchronous and the estimator is pure.
@Suite("C5a-0b T6 — the wobble estimator through the real detector (the product chain)", .serialized)
struct PitchWobbleDetectorTests {
    static let detectorEnabled = ProcessInfo.processInfo.environment["WOBBLE_DETECTOR"] != nil
    static let vocalPath = ProcessInfo.processInfo.environment["WOBBLE_VOCAL"]
    static let vocalEnabled = vocalPath.map { FileManager.default.fileExists(atPath: $0) } ?? false

    static func say(_ message: String) { print("wobble-detector| \(message)") }
    static func f(_ x: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", x) }

    /// Nearest-rank 95th percentile.
    static func p95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)]
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    // MARK: - The tones

    /// Which harmonic spectrum a tone carries.
    enum Spectrum: String, CaseIterable, Sendable {
        /// The mid-pitch table's fixture, the one C5a-0 measured it on:
        /// 12 partials at 1/k, peak 0.5 (`ContourToRenderTests.tone`).
        case twelve = "12 partials 1/k"
        /// §18.1.6's two voice-like spectra, the C5a-L instrument's own
        /// (`WobbleOnsetListeningTests.tone`): 8 partials at 1/k, and a
        /// fundamental WEAKER than its second partial.
        case eight = "8 partials 1/k"
        case voiceLike = "voice-like, weak fundamental"

        func samples(seconds: Double, f0: @escaping (Double) -> Double) -> [Float] {
            switch self {
            case .twelve:
                return ContourToRenderTests.tone(seconds: seconds, hz: f0)
            case .eight:
                return WobbleOnsetListeningTests.tone(seconds: seconds, sampleRate: ContourToRenderTests.sampleRate,
                                                      partials: (1...8).map { 1 / Double($0) }, hzAt: f0)
            case .voiceLike:
                return WobbleOnsetListeningTests.tone(seconds: seconds, sampleRate: ContourToRenderTests.sampleRate,
                                                      partials: WobbleOnsetListeningTests.voiceLikePartials, hzAt: f0)
            }
        }
    }

    /// One tone, one detection, one note.
    struct Detected: Sendable {
        let detection: PitchDetectionResult
        let segment: NoteSegment
        let reading: PitchWobbleReading
        let analysis: PitchWobbleEstimate.Analysis?
        /// Voiced frames inside the note.
        let voiced: Int
    }

    /// `baseHz · 2^(depth · sin(2π·rate·t + phase) / 1200)` at sample time
    /// `t`, through the product detector. The note is the longest voiced run.
    static func detect(baseHz: Double, rateHz: Double, depthCents: Double, phase: Double,
                       seconds: Double, spectrum: Spectrum = .twelve) throws -> Detected {
        let samples = spectrum.samples(seconds: seconds) { t in
            baseHz * pow(2, depthCents * sin(2 * .pi * rateHz * t + phase) / 1200)
        }
        let url = try ContourToRenderTests.tempDir("wobble").appendingPathComponent("tone.wav")
        try ContourToRenderTests.write(samples, to: url)
        let detection = try Self.throughTheSeam(url)
        let runs = PitchAutoCorrect.voicedRuns(in: detection.frames, frameRateHz: detection.frameRateHz)
        // p2-seg §5.2 (design 2026-09-24-pitch-note-splitting.md): every tone here
        // is ONE sung note with a wobble, never a note change. A split here is an
        // OVER-SPLIT of a real wobble through the real detector (§8 F-over).
        let invariance = PrePitchNoteSplitReference.invarianceFailures(frames: detection.frames,
                                                                       frameRateHz: detection.frameRateHz)
        let parts = PitchNoteSplitter.parts(in: detection.frames, frameRateHz: detection.frameRateHz)
        let shape = parts.map { "\($0.kind == .held ? "H" : "T")\($0.frameCount)" }.joined(separator: " ")
        let cell = "\(baseHz) Hz, \(rateHz) Hz ±\(depthCents) c, phase \(phase)"
        if depthCents <= 40 {
            // THE DESIGN POINT (a true ±40 c, design §2.1) AND BELOW: every run
            // comes out whole and both builders write the pre-p2-seg table.
            // Measured 2026-09-24 (S2): 0 over-splits in the 132 ±40 c and 36
            // ±20 c grid notes, at 82–381 Hz, 4.5–7.5 Hz, both spectra.
            #expect(invariance.isEmpty, "\(cell): parts \(shape); \(invariance.prefix(1))")
        } else {
            // ⚠️ BEYOND THE DESIGN POINT (±80 c): A RECORDED OVER-SPLIT, NOT A PASS.
            // Measured 2026-09-24 (S2), NEW — the design has no ±80 c row: 27 of the
            // 132 ±80 c grid notes come out as ONE held note plus a lead-in and/or
            // tail-off `.transition` of 9–17 frames (0 of 132 at ±40 c, 0 of 36 at
            // ±20 c). §13.3 measured the nearest known class — ±37 c wobbling
            // RELEASES, tail-offs up to 11 frames — and named the likely mechanism:
            // the SYMMETRIC edge shrink the design ruled on (§11.6, §12 item 6)
            // leaves the edge's wobble in the centre track, and at ±80 c that breaks
            // the 52 c band for more than S frames. Under the SHIPPED slide shape
            // (a-T, the user's pick) every preset stores a `.transition` AS SUNG, so
            // the cost is an uncorrected note edge (144–272 ms), not a wrong note.
            // ⚠️ THAT DEPENDS ON THE DEFAULT: (c) and (d) lock an edge to this run's
            // one note, but (a-N) locks it to the nearest note of ITS OWN median —
            // so the recorded line prints each edge's centre from its held note and
            // flags an edge whose nearest chromatic note differs. What still holds,
            // and is asserted: the splitter never invents a second NOTE — exactly
            // one `.held` part per run, every `.transition` at a run edge, none
            // longer than 20 frames (measured 17, plus headroom).
            let note = { (hz: Double) in PitchCorrectionMath.midi(fromHz: hz).rounded() }
            var edges: [String] = []
            for (run, runParts) in Dictionary(grouping: parts, by: \.runIndex) {
                #expect(runParts.filter { $0.kind == .held }.count == 1,
                        "\(cell): run \(run) holds more than one NOTE: \(shape)")
                let held = runParts.first { $0.kind == .held }
                for (k, part) in runParts.enumerated() where part.kind == .transition {
                    #expect(k == 0 || k == runParts.count - 1, "\(cell): a transition INSIDE one sung note: \(shape)")
                    #expect(part.frameCount <= 20, "\(cell): a \(part.frameCount)-frame edge left as sung: \(shape)")
                    if let held {
                        let cents = 1200 * log2(part.centreHz / held.centreHz)
                        let other = note(part.centreHz) == note(held.centreHz) ? "" : " OTHER-NOTE"
                        edges.append("T\(part.frameCount) \(String(format: "%+.1f", cents)) c\(other)")
                    }
                }
            }
            if !invariance.isEmpty {
                say("p2-seg F-over (recorded, beyond the design point): \(cell): parts \(shape); edges \(edges.joined(separator: ", "))")
            }
        }
        let run = try #require(runs.max { ($0.endSeconds - $0.startSeconds) < ($1.endSeconds - $1.startSeconds) },
                               "no voiced run at \(baseHz) Hz (\(spectrum.rawValue))")
        let segment = NoteSegment(startSeconds: run.startSeconds, endSeconds: run.endSeconds,
                                  detectedHz: run.centreHz, detectedConfidence: run.medianConfidence)
        let contour = PitchRenderContour.detected(detection)
        let reading = try #require(PitchWobbleEstimate.sung(segment, contour: contour))
        let frames = detection.frames.filter {
            $0.frequencyHz != nil && $0.timeSeconds >= segment.startSeconds && $0.timeSeconds < segment.endSeconds
        }
        let analysis = PitchWobbleEstimate.analyse(
            times: frames.map { $0.timeSeconds + contour.frameValueOffsetSeconds },
            cents: frames.map { PitchCorrectionMath.cents(from: segment.detectedHz, to: $0.frequencyHz!) })
        return Detected(detection: detection, segment: segment, reading: reading, analysis: analysis,
                        voiced: frames.count)
    }

    /// THE seam — `PitchContourCache.renderContour`, the function the render
    /// and the editor both reach — with the product detector, into a fresh
    /// cache directory, so the contour read is the one committed to disk.
    static func throughTheSeam(_ url: URL) throws -> PitchDetectionResult {
        let contour = PitchContourCache.renderContour(
            source: url, analysisVersion: PitchEditSet.currentAnalysisVersion,
            renderCacheDirectory: try ContourToRenderTests.tempDir("wobble-cache"), detector: .product)
        return try #require(contour.detection, "the seam did not detect: \(contour)")
    }

    /// The tone's own rising zero crossing nearest `t`: `2π·rate·t + phase = 2πm`.
    static func truthCrossing(near t: Double, rateHz: Double, phase: Double) -> Double {
        let m = ((2 * .pi * rateHz * t + phase) / (2 * .pi)).rounded()
        return (2 * .pi * m - phase) / (2 * .pi * rateHz)
    }

    /// One note of a measured grid.
    struct GridNote: Sendable {
        let name: String
        let hz: Double
        let spectrum: Spectrum
        let rate: Double
        let depth: Double
        let seconds: Double
        let phase: Double
        let detected: Detected

        var label: String { "\(name) \(spectrum.rawValue) \(rate) Hz ±\(Int(depth)) c \(seconds) s" }
        /// The FITTED depth as a share of the truth (from the analysis, so a
        /// note under the report floor still has one); `nil` with no analysis.
        var share: Double? { detected.analysis.map { $0.depthCents / depth } }
        var rateError: Double? { detected.analysis.map { abs($0.rateHz - rate) } }
        var anchorError: Double? {
            detected.analysis.map { a in
                abs(a.anchorSeconds - PitchWobbleDetectorTests.truthCrossing(near: a.anchorSeconds,
                                                                             rateHz: rate, phase: phase))
            }
        }
        var readsAWobble: Bool { if case .wobble = detected.reading { return true }; return false }
    }

    /// A grid measured once per run and shared by the tests that bound it.
    struct Grid: Sendable {
        let notes: [GridNote]
        let failure: String?
    }

    /// The LCG C5a-0's steady grid used, so its phases — and therefore its
    /// measurements — are reproduced exactly.
    struct LCG {
        var state: UInt64
        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }

    // MARK: - T6 (the canonical note)

    @Test("T6 realDetectorReadsTheWobble: 5.5 Hz ±40 c at A3 and B3 through the product detector",
          .enabled(if: detectorEnabled))
    func realDetectorReadsTheWobble() throws {
        for (name, hz, phase) in [("A3", 220.0, 0.9), ("B3", 246.94, 2.3)] {
            let result = try Self.detect(baseHz: hz, rateHz: 5.5, depthCents: 40, phase: phase, seconds: 2.0)
            Self.say("\(name): note \(Self.f(result.segment.startSeconds))–\(Self.f(result.segment.endSeconds)) s, "
                + "\(result.detection.voicedFrameCount)/\(result.detection.frameCount) voiced → \(result.reading)")
            guard case let .wobble(rate, depth, anchor, fit) = result.reading else {
                Issue.record("\(name): the real detector's contour was not read as a wobble: \(result.reading)")
                continue
            }
            let crossing = Self.truthCrossing(near: anchor, rateHz: 5.5, phase: phase)
            Self.say("\(name): rate \(Self.f(rate)) Hz (error \(Self.f(rate - 5.5, 3))), depth \(Self.f(depth, 2)) c "
                + "= \(Self.f(depth / 40, 3)) of the truth, anchor \(Self.f((anchor - crossing) * 1000, 2)) ms "
                + "from the tone's crossing, fit \(Self.f(fit))")
            // §18.1.2's bounds for a note of ≥ 1.0 s.
            #expect(abs(rate - 5.5) <= 0.03, "\(name): rate \(rate) Hz")
            #expect(depth / 40 >= 0.70 && depth / 40 <= 1.02, "\(name): depth \(depth) c is \(depth / 40) of the truth")
            #expect(abs(anchor - crossing) <= 0.006, "\(name): anchor \((anchor - crossing) * 1000) ms off")
        }
    }

    // MARK: - §18.1.2: the mid-pitch grid

    /// C5a-0's steady grid, unchanged: A3, B3, E4 × 4 rates × ±20/±40/±80 c ×
    /// 0.6/1.0/2.0 s, one seeded phase each, the 12-partial tone.
    static let midGrid: Grid = {
        var lcg = LCG(state: 0x5EED_C5A0)
        var notes: [GridNote] = []
        do {
            for (name, hz) in [("A3", 220.0), ("B3", 246.94), ("E4", 329.63)] {
                for rate in [4.5, 5.5, 6.5, 7.5] {
                    for depth in [20.0, 40.0, 80.0] {
                        for seconds in [0.6, 1.0, 2.0] {
                            let phase = 2 * .pi * lcg.unit()
                            let detected = try detect(baseHz: hz, rateHz: rate, depthCents: depth,
                                                      phase: phase, seconds: seconds)
                            notes.append(GridNote(name: name, hz: hz, spectrum: .twelve, rate: rate, depth: depth,
                                                  seconds: seconds, phase: phase, detected: detected))
                        }
                    }
                }
            }
        } catch {
            return Grid(notes: notes, failure: "\(error)")
        }
        return Grid(notes: notes, failure: nil)
    }()

    /// §18.1.2's table. Each bound is a pick with headroom over C5a-0's
    /// measurement (T6:81-86), and each has a plant that turns it red:
    /// rate — a +0.1 Hz bias on the refined rate; share — the depth × 0.85
    /// and × 1.10; anchor — moved by a quarter period.
    @Test("§18.1.2 the mid-pitch table: rate, depth share and anchor of ±40/±80 c notes through the product",
          .enabled(if: detectorEnabled))
    func theMidPitchTable() throws {
        let grid = Self.midGrid
        #expect(grid.failure == nil, "the mid grid did not finish: \(grid.failure ?? "")")
        let deep = grid.notes.filter { $0.depth >= 40 }
        #expect(deep.count == 72, "\(deep.count) of 72 ±40/±80 c notes measured")
        let refused = deep.filter { !$0.readsAWobble }
        for note in refused { Self.say("  mid refused: \(note.label) → \(note.detected.reading)") }
        #expect(refused.isEmpty, "\(refused.count) ±40/±80 c mid-pitch notes did not read as a wobble")
        for seconds in [0.6, 1.0, 2.0] {
            for depth in [40.0, 80.0] {
                let cell = deep.filter { $0.seconds == seconds && $0.depth == depth }
                let rates = cell.compactMap(\.rateError)
                let shares = cell.compactMap(\.share)
                let anchors = cell.compactMap(\.anchorError).map { $0 * 1000 }
                let rateBound = seconds < 1.0 ? 0.07 : 0.03
                Self.say("mid \(seconds) s ±\(Int(depth)) c: n \(cell.count), rate p95 \(Self.f(Self.p95(rates), 4)) Hz "
                    + "(bound \(rateBound)); share \(Self.f(shares.min() ?? .nan, 3))…\(Self.f(shares.max() ?? .nan, 3)) "
                    + "(median \(Self.f(Self.median(shares), 3)); bound [0.70, 1.02]); "
                    + "anchor p95 \(Self.f(Self.p95(anchors), 2)) ms (bound 6)")
                #expect(cell.count == 12)
                #expect(Self.p95(rates) <= rateBound, "mid \(seconds) s ±\(Int(depth)) c: rate p95 \(Self.p95(rates)) Hz")
                for note in cell {
                    let share = try #require(note.share)
                    #expect(share >= 0.70 && share <= 1.02, "\(note.label): share \(share)")
                }
                #expect(Self.p95(anchors) <= 6, "mid \(seconds) s ±\(Int(depth)) c: anchor p95 \(Self.p95(anchors)) ms")
            }
        }
    }

    /// §18.1.2: the ±20 c blind band is PINNED as a tripwire, not a quality
    /// bar. If it turns red the detector has changed, and §18.3's words and
    /// the report floor must be re-derived before anything ships.
    ///
    /// ⚠️ Two assertions, not one. `.noWobble` alone went slack when the
    /// report floor rose to 20 c: a detector that learned to see ±20 c at
    /// 0.95 would still fit under 20 c and read `.noWobble`. So the fitted
    /// depth must also stay under the detector's resolution floor (12.90 c) —
    /// C5a-0 measured 3.4–9.0 c. Plant: feed the TRUE contour past the
    /// detector; ±20 c then fits ≈ 20 c.
    @Test("§18.1.2 tripwire: every ±20 c note of the mid grid is blind — no wobble, fitted under the resolution floor",
          .enabled(if: detectorEnabled))
    func theTwentyCentBlindBand() throws {
        let grid = Self.midGrid
        #expect(grid.failure == nil, "the mid grid did not finish: \(grid.failure ?? "")")
        let shallow = grid.notes.filter { $0.depth == 20 }
        #expect(shallow.count == 36, "\(shallow.count) of 36 ±20 c notes measured")
        let fitted = shallow.compactMap { $0.detected.analysis?.depthCents }
        Self.say("mid ±20 c: \(shallow.filter { $0.detected.reading == .noWobble }.count) of \(shallow.count) read no wobble; "
            + "fitted \(Self.f(fitted.min() ?? .nan, 2))…\(Self.f(fitted.max() ?? .nan, 2)) c")
        for note in shallow {
            #expect(note.detected.reading == .noWobble, "\(note.label): \(note.detected.reading)")
            let depth = try #require(note.detected.analysis?.depthCents, "\(note.label): no analysis")
            #expect(depth < PitchCorrectionMath.detectorResolutionFloorCents, "\(note.label): fitted \(depth) c")
        }
    }

    // MARK: - §18.1.4: the ±8 c sweep and the report floor

    /// A true ±8 c wobble swept across one bin width above A3 (the
    /// configuration C5a-0 measured, T6:27-41). At A3 + 14…18 c it comes back
    /// as a two-level square wave fitting 13.8–15.7 c. Pinned: at most 3 of 14
    /// offsets fit ≥ 12.90 c, NONE fits ≥ 20 c, and so all 14 read
    /// `.noWobble`. Positive control: a true ±30 c at A3 and B3 (read 26.3 /
    /// 25.5 c in C5a-0's transfer) still reads a wobble. Plant:
    /// `reportFloorCents` back to 12.9 — the sweep turns red at A3 + 14/16/18.
    @Test("§18.1.4 the ±8 c sweep stays under the report floor, and a real ±30 c still reads",
          .enabled(if: detectorEnabled))
    func theEightCentSweep() throws {
        var overResolution: [String] = []
        var overReport: [String] = []
        var read: [String] = []
        for step in stride(from: 0, through: 26, by: 2) {
            let hz = 220 * pow(2, Double(step) / 1200)
            let result = try Self.detect(baseHz: hz, rateHz: 5.5, depthCents: 8, phase: 0.4, seconds: 1.0)
            let a = try #require(result.analysis, "A3+\(step) c: no analysis")
            Self.say("±8 c sweep A3+\(step) c: \(result.reading) [fitted \(Self.f(a.depthCents, 2)) c at "
                + "\(Self.f(a.rateHz, 3)) Hz, fit \(Self.f(a.fit, 3)), step \(a.step.rawValue)]")
            if a.depthCents >= PitchCorrectionMath.detectorResolutionFloorCents { overResolution.append("A3+\(step) c") }
            if a.depthCents >= PitchWobbleEstimate.reportFloorCents { overReport.append("A3+\(step) c") }
            if result.reading != .noWobble { read.append("A3+\(step) c: \(result.reading)") }
        }
        Self.say("±8 c sweep: \(overResolution.count) of 14 fit ≥ 12.90 c \(overResolution); "
            + "\(overReport.count) fit ≥ 20 c; \(read.count) read other than no wobble")
        #expect(overResolution.count <= 3, "\(overResolution)")
        #expect(overReport.isEmpty, "\(overReport)")
        #expect(read.isEmpty, "\(read)")
        for (name, hz) in [("A3", 220.0), ("B3", 246.94)] {
            let result = try Self.detect(baseHz: hz, rateHz: 5.5, depthCents: 30, phase: 1.1, seconds: 1.0)
            Self.say("±30 c at \(name): \(result.reading)")
            guard case .wobble = result.reading else {
                Issue.record("±30 c at \(name) does not read as a wobble: \(result.reading)")
                continue
            }
        }
    }

    /// How deep a sung wobble must be before the PRODUCT can see it: the
    /// detector's depth transfer at 5.5 Hz, 1.0 s notes, three pitches.
    @Test("recorded: the detector's depth transfer — how deep a wobble must be to read", .enabled(if: detectorEnabled))
    func depthTransferThroughTheDetector() throws {
        for (name, hz) in [("A3", 220.0), ("B3", 246.94), ("E4", 329.63)] {
            var row: [String] = []
            for depth in [10.0, 15.0, 20.0, 25.0, 30.0, 35.0, 40.0] {
                let result = try Self.detect(baseHz: hz, rateHz: 5.5, depthCents: depth, phase: 1.1, seconds: 1.0)
                let fitted = result.analysis.map { Self.f($0.depthCents, 1) } ?? "–"
                let tag: String
                switch result.reading {
                case .wobble: tag = "wobble"
                case .noWobble: tag = "none"
                case .unmeasurable(let why): tag = why.rawValue
                }
                row.append("±\(Int(depth))→\(fitted) \(tag)")
            }
            Self.say("depth transfer \(name) 5.5 Hz 1.0 s: \(row.joined(separator: " | "))")
        }
    }

    // MARK: - §18.1.6: the low-pitch block

    static let lowPitches: [(name: String, hz: Double)] = [("82.4 Hz", 82.4), ("110.0 Hz", 110.0), ("146.8 Hz", 146.8)]

    /// §18.1.6: 82.4, 110.0 and 146.8 Hz × both voice-like spectra ×
    /// ±40/±80 c × 1.0/2.0 s × 4 rates, one seeded phase each.
    static let lowGrid: Grid = {
        var lcg = LCG(state: 0x10B1_0C5A)
        var notes: [GridNote] = []
        do {
            for (name, hz) in lowPitches {
                for spectrum in [Spectrum.eight, .voiceLike] {
                    for rate in [4.5, 5.5, 6.5, 7.5] {
                        for depth in [40.0, 80.0] {
                            for seconds in [1.0, 2.0] {
                                let phase = 2 * .pi * lcg.unit()
                                let detected = try detect(baseHz: hz, rateHz: rate, depthCents: depth,
                                                          phase: phase, seconds: seconds, spectrum: spectrum)
                                notes.append(GridNote(name: name, hz: hz, spectrum: spectrum, rate: rate, depth: depth,
                                                      seconds: seconds, phase: phase, detected: detected))
                            }
                        }
                    }
                }
            }
        } catch {
            return Grid(notes: notes, failure: "\(error)")
        }
        return Grid(notes: notes, failure: nil)
    }()

    /// One low pitch's bounds, derived from THIS suite's measurement by
    /// §18.1.2's own headroom, the same arithmetic that turns its mid
    /// measurements into its table: share −0.05 / +0.03 around the measured
    /// range, rounded outward to 0.01 (0.75…0.99 → [0.70, 1.02]); rate p95
    /// × 1.5, rounded up to 0.01 Hz (0.0201 → 0.03); anchor p95 × 1.25,
    /// rounded up to a whole ms (4.79 → 6). `held == nil`: §18.4's stop
    /// condition fired — the share cannot be held inside [0.5, 1.1].
    struct LowBound: Sendable {
        struct Held: Sendable {
            let shareBand: ClosedRange<Double>
            let rateP95: Double
            let anchorP95Ms: Double
        }
        let hz: Double
        let held: Held?
    }

    /// MEASURED 2026-09-24 (C5a-0b), `LOW BLOCK` lines:
    ///  * 82.4 Hz — share 0.303…0.827 (median 0.595); 8 of 32 read no wobble
    ///    (8 partials ±40 c: 0.303–0.387 at every rate). STOPPED.
    ///  * 110.0 Hz — share 0.472…0.976 (median 0.873); 8 partials, 7.5 Hz,
    ///    ±40 c reads 0.472 / 0.475 (both durations), under 0.5. STOPPED.
    ///  * 146.8 Hz — share 0.740…0.895 (median 0.834), rate p95 0.0157 Hz,
    ///    anchor p95 8.01 ms (max 8.10: a systematic detector LAG, not
    ///    spread). Held: [0.69, 0.93], 0.03 Hz, 11 ms (8.01 × 1.25 = 10.01).
    static let lowBounds: [LowBound] = [
        LowBound(hz: 82.4, held: nil),
        LowBound(hz: 110.0, held: nil),
        LowBound(hz: 146.8, held: .init(shareBand: 0.69...0.93, rateP95: 0.03, anchorP95Ms: 11)),
    ]

    @Test("§18.1.6 the low-pitch block: depth share, rate and anchor at 82.4, 110.0 and 146.8 Hz",
          .enabled(if: detectorEnabled))
    func theLowPitchBlock() throws {
        let grid = Self.lowGrid
        #expect(grid.failure == nil, "the low grid did not finish: \(grid.failure ?? "")")
        #expect(grid.notes.count == 96, "\(grid.notes.count) of 96 low notes measured")
        for note in grid.notes {
            let a = note.detected.analysis
            Self.say("low \(note.label): \(note.detected.voiced) voiced, "
                + (a.map { "fitted \(Self.f($0.depthCents, 2)) c = \(Self.f($0.depthCents / note.depth, 3)) "
                    + "at \(Self.f($0.rateHz, 3)) Hz, fit \(Self.f($0.fit, 3)), step \($0.step.rawValue), "
                    + "anchor \(Self.f(($0.anchorSeconds - Self.truthCrossing(near: $0.anchorSeconds, rateHz: note.rate, phase: note.phase)) * 1000, 2)) ms (signed)" }
                    ?? "no analysis")
                + " → \(note.detected.reading)")
        }
        for (name, hz) in Self.lowPitches {
            let block = grid.notes.filter { $0.hz == hz }
            let shares = block.compactMap(\.share)
            let unanalysed = block.filter { $0.share == nil }.count
            let rates = block.compactMap(\.rateError)
            let anchors = block.compactMap(\.anchorError).map { $0 * 1000 }
            let wobbles = block.filter(\.readsAWobble).count
            for spectrum in [Spectrum.eight, .voiceLike] {
                for depth in [40.0, 80.0] {
                    let part = block.filter { $0.spectrum == spectrum && $0.depth == depth }.compactMap(\.share)
                    Self.say("low \(name) \(spectrum.rawValue) ±\(Int(depth)) c: share "
                        + "\(Self.f(part.min() ?? .nan, 3))…\(Self.f(part.max() ?? .nan, 3)) (median \(Self.f(Self.median(part), 3)))")
                }
            }
            for seconds in [1.0, 2.0] {
                let r = block.filter { $0.seconds == seconds }.compactMap(\.rateError)
                let an = block.filter { $0.seconds == seconds }.compactMap(\.anchorError).map { $0 * 1000 }
                Self.say("low \(name) \(seconds) s: rate p95 \(Self.f(Self.p95(r), 4)) Hz, anchor p95 \(Self.f(Self.p95(an), 2)) ms")
            }
            let held = unanalysed == 0 && (shares.min() ?? 0) >= 0.5 && (shares.max() ?? 2) <= 1.1
            Self.say("LOW BLOCK \(name): n \(block.count), \(wobbles) read a wobble, \(unanalysed) unanalysed; share "
                + "\(Self.f(shares.min() ?? .nan, 3))…\(Self.f(shares.max() ?? .nan, 3)) (median \(Self.f(Self.median(shares), 3))); "
                + "rate p95 \(Self.f(Self.p95(rates), 4)) Hz; anchor p95 \(Self.f(Self.p95(anchors), 2)) ms, "
                + "max \(Self.f(anchors.max() ?? .nan, 2)); inside [0.5, 1.1]: \(held ? "YES" : "NO — STOP CONDITION")")

            let bound = try #require(Self.lowBounds.first(where: { $0.hz == hz }), "\(name): no bound")
            if let held = bound.held {
                #expect(unanalysed == 0, "\(name): \(unanalysed) notes had no analysis")
                #expect(wobbles == block.count, "\(name): \(block.count - wobbles) notes did not read as a wobble")
                for note in block {
                    let share = try #require(note.share)
                    #expect(held.shareBand.contains(share), "\(note.label): share \(share) outside \(held.shareBand)")
                }
                #expect(Self.p95(rates) <= held.rateP95, "\(name): rate p95 \(Self.p95(rates)) Hz")
                #expect(Self.p95(anchors) <= held.anchorP95Ms, "\(name): anchor p95 \(Self.p95(anchors)) ms")
                #expect(PitchWobbleEstimate.response(pitchHz: hz) != nil, "\(name): held, but response is nil")
            } else {
                // The stop condition fired: the share cannot be held inside
                // [0.5, 1.1]. Pinned, so an improved detector turns this red
                // and the pitch gets re-measured rather than staying `nil`.
                #expect(!held, "\(name): the share now fits [0.5, 1.1] — re-derive this block")
                #expect(PitchWobbleEstimate.response(pitchHz: hz) == nil, "\(name): stopped, but response is not nil")
            }
        }
    }

    /// §18.1.6: does §18.1.4's square-wave artefact exist at 110 Hz? The same
    /// sweep as A3's, one bin width in 2 c steps, both voice-like spectra.
    ///
    /// MEASURED 2026-09-24 (C5a-0b): IT DOES. 5 of 28 fit ≥ 12.90 c (8
    /// partials at 110 + 24/26 c: 14.85 / 14.78; voice-like at 110 + 22/24/26 c:
    /// 14.02 / 15.45 / 12.91), none ≥ 20 c, all 28 `.noWobble`. So §18.1.6's
    /// "lowering the report floor there becomes a measured option" is closed:
    /// the artefact the floor exists for is present at low pitch too. Pinned
    /// like §18.1.4's: at most 5 of 28 over the resolution floor, none over
    /// the report floor. Plant: `reportFloorCents` back to 12.9.
    @Test("§18.1.6 the ±8 c sweep at 110 Hz: whether the artefact exists down there",
          .enabled(if: detectorEnabled))
    func theEightCentSweepAtLowPitch() throws {
        var overResolution: [String] = []
        var overReport: [String] = []
        var read: [String] = []
        for spectrum in [Spectrum.eight, .voiceLike] {
            for step in stride(from: 0, through: 26, by: 2) {
                let hz = 110 * pow(2, Double(step) / 1200)
                let result = try Self.detect(baseHz: hz, rateHz: 5.5, depthCents: 8, phase: 0.4, seconds: 1.0,
                                             spectrum: spectrum)
                let tag = "\(spectrum.rawValue) 110+\(step) c"
                guard let a = result.analysis else {
                    Self.say("±8 c sweep \(tag): \(result.reading), no analysis (\(result.voiced) voiced)")
                    read.append("\(tag): \(result.reading)")
                    continue
                }
                Self.say("±8 c sweep \(tag): \(result.reading) [fitted \(Self.f(a.depthCents, 2)) c at "
                    + "\(Self.f(a.rateHz, 3)) Hz, fit \(Self.f(a.fit, 3)), step \(a.step.rawValue)]")
                if a.depthCents >= PitchCorrectionMath.detectorResolutionFloorCents { overResolution.append(tag) }
                if a.depthCents >= PitchWobbleEstimate.reportFloorCents { overReport.append(tag) }
                if result.reading != .noWobble { read.append("\(tag): \(result.reading)") }
            }
        }
        Self.say("±8 c sweep at 110 Hz: \(overResolution.count) of 28 fit ≥ 12.90 c \(overResolution); "
            + "\(overReport.count) fit ≥ 20 c; \(read.count) read other than no wobble")
        #expect(overResolution.count <= 5, "\(overResolution)")
        #expect(overReport.isEmpty, "\(overReport)")
        #expect(read.isEmpty, "\(read)")
    }

    // MARK: - §18.2: the calibration

    /// `response(pitchHz:)` must be the MEDIAN share this suite measures for
    /// each block, to the table's 0.01 rounding — so the handoff's calibrated
    /// depth, `read ÷ response`, has a median of the truth over the block.
    /// Plant: `response` returning 1.0 everywhere.
    @Test("§18.2 response(pitchHz:) is the median share the product reads in each measured block",
          .enabled(if: detectorEnabled))
    func responseIsTheMeasuredMedian() throws {
        let mid = Self.midGrid, low = Self.lowGrid
        #expect(mid.failure == nil && low.failure == nil)
        var blocks: [(name: String, pitches: [Double], notes: [GridNote])] = [
            ("mid 220–330 Hz", [220.0, 246.94, 329.63], mid.notes.filter { $0.depth >= 40 }),
        ]
        for (name, hz) in Self.lowPitches { blocks.append((name, [hz], low.notes.filter { $0.hz == hz })) }
        for block in blocks {
            let shares = block.notes.compactMap(\.share)
            let median = Self.median(shares)
            // §18.4's stop condition, from the measurement itself: every note
            // analysed and every share inside [0.5, 1.1].
            let held = !block.notes.isEmpty && shares.count == block.notes.count
                && shares.allSatisfy { $0 >= 0.5 && $0 <= 1.1 }
            for hz in block.pitches {
                let response = PitchWobbleEstimate.response(pitchHz: hz)
                Self.say("calibration \(block.name) at \(hz) Hz: measured median share \(Self.f(median, 4)) "
                    + "(n \(shares.count), held \(held)); response \(response.map { Self.f($0, 2) } ?? "nil")")
                guard held else {
                    #expect(response == nil, "\(block.name) at \(hz) Hz: the stop condition fired, response must be nil")
                    continue
                }
                let r = try #require(response, "\(block.name) at \(hz) Hz: held, but response is nil")
                #expect(abs(r - median) <= 0.01, "\(block.name) at \(hz) Hz: response \(r), measured \(median)")
                let calibrated = block.notes.compactMap { note in note.share.map { $0 / r } }
                #expect(abs(Self.median(calibrated) - 1) <= 0.02, "\(block.name): calibrated median \(Self.median(calibrated))")
            }
        }
        for hz in [60.0, 400.0, 1000.0] {
            #expect(PitchWobbleEstimate.response(pitchHz: hz) == nil, "\(hz) Hz lies outside every block")
        }
    }

    /// NOT in §18.4 — added by C5a-0b because `response` makes a claim across
    /// each block's whole band, and WHERE a block applies is [INFERRED]
    /// (nearest measured pitch; `PitchWobbleEstimate.responseBlocks`). The
    /// least that claim needs: at every edge of a block that returns a share,
    /// the product's share is still inside §18.4's stop band [0.5, 1.1] —
    /// otherwise `response` hands out a calibration where none is possible.
    /// Same grid as the low block (both voice-like spectra × 4 rates × ±40/±80
    /// × 1.0/2.0 s).
    ///
    /// MEASURED 2026-09-24 (C5a-0b): 127.1 Hz 0.774…1.084 (median 0.903),
    /// 179.7 Hz 0.795…1.085 (0.890), 380.8 Hz 0.873…0.979 (0.935). Inside the
    /// band everywhere — but the edge medians sit up to 0.07 from their
    /// block's, and some ±40 c notes over-read by 8 %: a calibrated depth is
    /// "about", never a number to print (§18.2).
    @Test("§18.2 the response blocks' inferred edges: the product's share stays inside [0.5, 1.1] there",
          .enabled(if: detectorEnabled))
    func theResponseEdgesHold() throws {
        let held = PitchWobbleEstimate.responseBlocks.filter { $0.medianShare != nil }
        #expect(!held.isEmpty)
        let edges = Set(held.flatMap { [$0.coversHz.lowerBound, $0.coversHz.upperBound] }).sorted()
        var lcg = LCG(state: 0xED6E)
        for hz in edges {
            var shares: [Double] = []
            var unanalysed = 0
            for spectrum in [Spectrum.eight, .voiceLike] {
                for rate in [4.5, 5.5, 6.5, 7.5] {
                    for depth in [40.0, 80.0] {
                        for seconds in [1.0, 2.0] {
                            let phase = 2 * .pi * lcg.unit()
                            let d = try Self.detect(baseHz: hz, rateHz: rate, depthCents: depth, phase: phase,
                                                    seconds: seconds, spectrum: spectrum)
                            guard let a = d.analysis else { unanalysed += 1; continue }
                            shares.append(a.depthCents / depth)
                        }
                    }
                }
            }
            let neighbours = held.filter { $0.coversHz.lowerBound == hz || $0.coversHz.upperBound == hz }
                .map { "\($0.name) \($0.medianShare.map { Self.f($0, 2) } ?? "nil")" }
            Self.say("edge \(Self.f(hz, 2)) Hz: share \(Self.f(shares.min() ?? .nan, 3))…\(Self.f(shares.max() ?? .nan, 3)) "
                + "(median \(Self.f(Self.median(shares), 3)); \(unanalysed) unanalysed); blocks here: \(neighbours)")
            #expect(unanalysed == 0, "edge \(hz) Hz: \(unanalysed) notes had no analysis")
            #expect(shares.allSatisfy { $0 >= 0.5 && $0 <= 1.1 },
                    "edge \(hz) Hz: share \(shares.min() ?? .nan)…\(shares.max() ?? .nan) leaves [0.5, 1.1]")
        }
    }

    // MARK: - §8.5c, the real dry vocal (recorded)

    @Test("§8.5c: every note of the real dry vocal, with its reading", .enabled(if: vocalEnabled))
    func realVocalReadings() throws {
        let url = URL(fileURLWithPath: try #require(Self.vocalPath))
        let detection = try Self.throughTheSeam(url)
        let contour = PitchRenderContour.detected(detection)
        let set = PitchAutoCorrect.editSet(from: detection, options: PitchAutoCorrectOptions())
        Self.say("\(url.lastPathComponent): \(detection.frameCount) frames, \(detection.voicedFrameCount) voiced, "
            + "\(set.segments.count) notes (the product's auto-correct segmentation)")
        let window = 0..<(detection.windowDurationSeconds)
        let line = PitchPlayedLine.make(contour: contour, fallback: nil, editSet: set,
                                        clipPitchShiftSemitones: 0, sourceWindow: window)

        var wobbles: [(rate: Double, depth: Double, fit: Double)] = []
        var none = 0
        var refused: [String: Int] = [:]
        var playedAgrees = 0
        var playedWorst = 0.0
        var covered = 0
        for (index, segment) in set.segments.enumerated() {
            let reading = try #require(PitchWobbleEstimate.sung(segment, contour: contour))
            let frames = detection.frames.filter {
                $0.frequencyHz != nil && $0.timeSeconds >= segment.startSeconds && $0.timeSeconds < segment.endSeconds
            }
            let analysis = PitchWobbleEstimate.analyse(
                times: frames.map { $0.timeSeconds + contour.frameValueOffsetSeconds },
                cents: frames.map { PitchCorrectionMath.cents(from: segment.detectedHz, to: $0.frequencyHz!) })
            let midi = PitchCorrectionMath.midi(fromHz: segment.detectedHz)
            let response = PitchWobbleEstimate.response(pitchHz: segment.detectedHz)
            if response != nil { covered += 1 }
            let why = analysis.map { a in
                "[\(a.step.rawValue): \(Self.f(a.depthCents, 1)) c at \(Self.f(a.rateHz, 2)) Hz, fit \(Self.f(a.fit, 2)), "
                    + "\(a.fitted)/\(a.handedIn) fitted]"
            } ?? "[no analysis]"
            Self.say(String(format: "note %2ld  %6.3f–%6.3f s (%.2f s, %3ld frames)  %.2f Hz = MIDI %.2f, response %@  → ",
                            index + 1, segment.startSeconds, segment.endSeconds, segment.durationSeconds,
                            frames.count, segment.detectedHz, midi,
                            (response.map { Self.f($0, 2) } ?? "nil") as NSString)
                + "\(reading) \(why)")
            switch reading {
            case let .wobble(rate, depth, _, fit): wobbles.append((rate, depth, fit))
            case .noWobble: none += 1
            case let .unmeasurable(why): refused[why.rawValue, default: 0] += 1
            }
            // The played line of the auto-corrected note moves it by a constant:
            // its wobble must read the same.
            let played = PitchWobbleEstimate.played(segment, line: line)
            switch (reading, played) {
            case let (.wobble(r1, d1, _, _), .wobble(r2, d2, _, _)):
                playedWorst = max(playedWorst, abs(r1 - r2) * 10, abs(d1 - d2))
                if abs(r1 - r2) < 0.05, abs(d1 - d2) < 1 { playedAgrees += 1 }
            case (.noWobble, .noWobble), (.unmeasurable, .unmeasurable): playedAgrees += 1
            default: break
            }
        }
        func range(_ xs: [Double]) -> String {
            let s = xs.sorted()
            guard let lo = s.first, let hi = s.last else { return "none" }
            return "\(Self.f(lo, 2))…\(Self.f(hi, 2)) (median \(Self.f(s[s.count / 2], 2)))"
        }
        Self.say("SUMMARY: \(set.segments.count) notes — \(wobbles.count) wobble, \(none) no wobble the app can measure, "
            + "unmeasurable \(refused.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        Self.say("SUMMARY: rate \(range(wobbles.map(\.rate))) Hz; depth \(range(wobbles.map(\.depth))) c; "
            + "fit \(range(wobbles.map(\.fit)))")
        Self.say("SUMMARY: \(covered) of \(set.segments.count) notes lie in a block with a measured response")
        Self.say("SUMMARY: played reading agrees with the sung one on \(playedAgrees) of \(set.segments.count) notes "
            + "(worst: \(Self.f(playedWorst, 3)), rate difference ×10 or depth difference in cents)")
        #expect(!set.segments.isEmpty, "the real vocal produced no notes")
    }
}
