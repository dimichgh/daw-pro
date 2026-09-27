import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// m23-nt — **THE REAL-TAKE HARNESS.** Design
/// `docs/design/2026-09-25-natural-tuning.md`, X11: "One owner: the
/// gates-first lane creates it with one `@Suite` per section; later lanes add
/// cases only inside their own suite." Four `@Suite`s below, one per design
/// section; only §2 (NT-G's own measurements, M-1/M-2/M-3) has bodies here.
/// §1/§3/§4 are empty on purpose — later lanes extend them via `extension` in
/// their OWN files, never by editing this one.
///
/// Env-gated (never runs by accident, never fails when the take is absent —
/// `.enabled(if:)` combines an explicit opt-in with a file-exists check, the
/// `PitchWobbleDetectorTests.vocalEnabled` pattern). The audio NEVER enters
/// the repo: every path below is an absolute path under the user's own
/// `~/Music/DAW Pro Dogfood/`, read in place.
///
///     NATURALTUNING_TAKE=1 ./scripts/test.sh --filter NaturalTuningTakeHarnessTests
///
/// `@MainActor` is spelled per test, never on a suite (design 2g: "None needs
/// `@MainActor`; the env-gated real-take gate puts `@MainActor` on each test,
/// never on the suite" — and `MainActorOccupancySiteTests`' cap is
/// independently a reason: these suites cost nothing when disabled only if
/// they carry no actor annotation of their own).
@Suite("Natural tuning — take harness §1 (formants; owned by NT-E1/F-core, not populated here)")
struct NaturalTuningTakeHarnessSection1Tests {}

@Suite("Natural tuning — take harness §3 (drift/vibrato; owned by the G3/G4 lane, not populated here)")
struct NaturalTuningTakeHarnessSection3Tests {}

@Suite("Natural tuning — take harness §4 (transitions; owned by the transition lane, not populated here)")
struct NaturalTuningTakeHarnessSection4Tests {}

/// §2: consonants and alignment, M-1/M-2/M-3 (design 2g), R2's rescoped M-1,
/// and R4's M-2b (a leg of M-2, "NT-G" named explicitly).
@Suite("Natural tuning — take harness §2 (consonants: M-1 lag/rho, M-2 edge placement, M-3 gap histogram)",
       .serialized)
struct NaturalTuningTakeHarnessSection2Tests {
    static func log(_ message: String) { print("nt-take-harness| \(message)") }

    static let dogfoodRoot = ("~/Music/DAW Pro Dogfood" as NSString).expandingTildeInPath
    static let sourcePath = "\(dogfoodRoot)/2026-09-24 p2-seg physics/take/dry-norm.wav"
    static let outDirPath = "\(dogfoodRoot)/2026-09-25 natural-tuning/consonants"

    static let enabled = ProcessInfo.processInfo.environment["NATURALTUNING_TAKE"] != nil
        && FileManager.default.fileExists(atPath: sourcePath)

    /// The moved note's pitch move, and the retune this run uses. Not the
    /// design's "Gentle" (that is R5's SYNTHETIC fixture, in
    /// `NaturalTuningBaselineTests`); this is the "Natural" preset's own
    /// retune (`PitchCorrectionPresets.swift:84`), a representative everyday
    /// value for the real-take measurement.
    static let movedNoteOffsetCents = 300.0
    static let retuneMs = 110.0
    static let maxLagSamples = 256
    static let minimumGapSeconds = 0.100

    struct Take {
        let source: URL
        let sampleRate: Double
        let dry: [Float]
        let runs: [VoicedRun]
        let frameRateHz: Double
    }

    @MainActor
    static func load() throws -> Take {
        let source = URL(fileURLWithPath: sourcePath)
        let input = try TestSignals.readFile(source)
        try #require(input.count == 1, "expected a mono take; got \(input.count) channels")
        let sampleRate = try AVAudioFile(forReading: source).processingFormat.sampleRate
        let detection = try PitchContourCache.detectWholeFile(source, .product)
        let runs = PitchAutoCorrect.voicedRuns(in: detection.frames, frameRateHz: detection.frameRateHz)
        log("loaded \(input[0].count) frames at \(sampleRate) Hz, \(runs.count) voiced runs (product detector)")
        return Take(source: source, sampleRate: sampleRate, dry: input[0], runs: runs,
                   frameRateHz: detection.frameRateHz)
    }

    static func ensureOutDir() throws -> URL {
        let dir = URL(fileURLWithPath: outDirPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Written BEFORE any render (design 2g: "each writes a PREREG first").
    /// Idempotent: re-writes the same content every run rather than erroring
    /// if it exists, since this harness has no separate "plan" phase to run
    /// once — the plan IS these constants.
    static func writePrereg(_ take: Take, movedRunIndex: Int) throws {
        let moved = take.runs[movedRunIndex]
        let text = """
            m23-nt NT-G — PREREG, §2 M-1/M-2/M-3 (design 2026-09-25-natural-tuning.md, R2/R4/R5)
            Written before any render.

            Take: \(sourcePath) (\(take.dry.count) frames @ \(take.sampleRate) Hz, \(take.runs.count) voiced runs)
            Moved note: run \(movedRunIndex) of \(take.runs.count), \(moved.startSeconds)-\(moved.endSeconds) s, \
            centre \(moved.centreHz) Hz, offset +\(movedNoteOffsetCents) c, retuneMs \(retuneMs) (Natural preset)
            All other notes: untouched (no segment emitted for them; absence of a span is
            identical to an identity span with pitchOffsetCents 0 — both read the same
            clipPitchShiftSemitones fallback wherever no span's gate is open).

            M-1 (R2-rescoped): analytic cross-correlation lag + Pearson rho, maxLag \
            \(maxLagSamples) samples, over every gap >= \(Int(minimumGapSeconds * 1000)) ms.
            Split: "adjacent" = the gap immediately before or after the moved run (both
            populations reported separately, never averaged together); all other gaps are
            "clean history".
            Pass condition: lag == 0 in every clean-history gap with rho >= 0.9. A
            clean-history gap with lag != 0 AND rho >= 0.9 pauses C2 (R2); rho < 0.9 at any
            lag is reported as a finding, never read as a delay.
            Plants: (a) a clean-history gap's dry audio delayed by 3 samples must read lag 3;
            (b) that same gap's dry audio phase-rotated by pi/2 per bin must read lag 0 with
            LOW rho (R2's new plant, telling delay apart from rotation).

            M-2 (edge placement, simplified -- see results.md for the exact deviation from
            2g's spec): product onset (the run's own startSeconds) vs an independent onset
            from a flatness+zero-crossing-rate crossing computed directly on the DRY audio
            (not busyline-frames.csv's spectral_flatness column, which is populated only
            where product_voiced == 1 and is therefore not independent of the product
            decision it would be checked against). Reported: median and 90th-percentile
            |offset| across all run starts. Positive control: a synthetic tone-after-noise
            fixture with a planted 20 ms onset shift must read close to 20 ms.

            M-3: gap-duration histogram from the run boundaries (blink threshold 2 frames at \
            \(take.frameRateHz) fps = \(2000 / take.frameRateHz) ms); wet/dry Pearson rho at \
            5/10/20 ms fades at each qualifying gap's edges, using the SAME M-1 render.
            """
        try text.write(to: ensureOutDir().appendingPathComponent("PREREG.txt"),
                       atomically: true, encoding: .utf8)
    }

    /// The one-note edit: `movedNoteOffsetCents` on `runs[movedRunIndex]`
    /// only. Reuses `NaturalTuningBaselineTests.renderThroughShippingPath`
    /// (that file's helper, not `private`, same module) rather than
    /// duplicating the shipping-path shape a third time.
    static func movedNoteSet(_ take: Take, movedRunIndex: Int) -> PitchEditSet {
        let run = take.runs[movedRunIndex]
        let segment = NoteSegment(startSeconds: run.startSeconds, endSeconds: run.endSeconds,
                                  detectedHz: run.centreHz, detectedConfidence: run.medianConfidence,
                                  pitchOffsetCents: movedNoteOffsetCents)
        return PitchEditSet(segments: [segment], retuneMs: retuneMs)
    }

    struct Gap {
        let index: Int // the gap BETWEEN runs[index] and runs[index + 1]
        let startSeconds: Double
        let endSeconds: Double
        var durationSeconds: Double { endSeconds - startSeconds }
    }

    static func qualifyingGaps(_ take: Take) -> [Gap] {
        var gaps: [Gap] = []
        for i in 0..<(take.runs.count - 1) {
            let gap = Gap(index: i, startSeconds: take.runs[i].endSeconds,
                          endSeconds: take.runs[i + 1].startSeconds)
            if gap.durationSeconds >= minimumGapSeconds { gaps.append(gap) }
        }
        return gaps
    }

    // MARK: - M-1: analytic lag + rho per gap (R2-rescoped)

    /// ⭐ **THE GATING MEASUREMENT.** R2: "Alignment is structural... Coherence
    /// is historical." This is the ONE result that decides whether NT-C's C2
    /// (the consonant mask) may proceed or must pause -- nothing else in this
    /// file blocks anything downstream.
    ///
    /// ⚠️ **THE SPLIT IS CHRONOLOGICAL, NOT ADJACENCY — a first version split
    /// by "immediately touches the moved note" and got a WEAKER, muddier
    /// verdict as a result.** R2's own wording is "split by 'moved note
    /// precedes the gap'"; R1 explains why: "after any moved note the tuned
    /// gap is the source with per-bin phase rotations; before the first moved
    /// note it is close to the source" — a STATEMENT ABOUT TIME ORDER, not
    /// distance. Measured on this take: gap 20 (immediately BEFORE the moved
    /// note) reads rho 0.902, indistinguishable in kind from the 15 gaps
    /// further back (rho 1.000) — it belongs with them. Gaps 22-37 (NOT
    /// touching the moved note, just later in the file) read the SAME
    /// degraded rho (-0.17...-0.21) as gap 21 (which does touch it) — they
    /// belong with IT. Adjacency was the wrong axis; time order is R2's own.
    @Test("M-1: analytic lag/rho per gap, split by whether a moved note precedes it (R2)",
          .enabled(if: enabled))
    @MainActor
    func m1AlignmentAndResidual() throws {
        let take = try Self.load()
        let movedRunIndex = take.runs.count / 2
        try Self.writePrereg(take, movedRunIndex: movedRunIndex)

        let set = Self.movedNoteSet(take, movedRunIndex: movedRunIndex)
        let rendered = try NaturalTuningBaselineTests.renderThroughShippingPath(take.dry, set: set)
        try #require(rendered.count == take.dry.count,
                     "ratio-1 render changed frame count: \(rendered.count) vs \(take.dry.count)")

        let gaps = Self.qualifyingGaps(take)
        try #require(!gaps.isEmpty, "no gap >= \(Self.minimumGapSeconds * 1000) ms found on this take")

        struct Reading { let gap: Gap; let lag: Int; let rho: Double; let residualDb: Double }
        var before: [Reading] = [], after: [Reading] = []
        for gap in gaps {
            let lo = Int((gap.startSeconds * take.sampleRate).rounded())
            let hi = min(take.dry.count, rendered.count, Int((gap.endSeconds * take.sampleRate).rounded()))
            guard hi > lo else { continue }
            let dry = Array(take.dry[lo..<hi]), wet = Array(rendered[lo..<hi])
            let (lag, rho) = ConsonantSpectrumMeter.analyticLagRho(
                dry: dry, wet: wet, maxLag: Self.maxLagSamples)
            let residual = NaturalTuningBaselineTests.residualDb(wet, dry)
            let reading = Reading(gap: gap, lag: lag, rho: rho, residualDb: residual)
            // R2's split: does the moved run (index movedRunIndex) precede
            // this gap? Gap `i` sits between runs[i] and runs[i+1], so the
            // moved note precedes it iff movedRunIndex <= i.
            if gap.index < movedRunIndex { before.append(reading) } else { after.append(reading) }
        }
        try #require(!before.isEmpty, "no gap entirely before the moved note; move a later note or widen the take")

        for r in before {
            Self.log("M-1 BEFORE (clean-history) gap \(r.gap.index) [\(String(format: "%.3f", r.gap.startSeconds))-\(String(format: "%.3f", r.gap.endSeconds))s, \(String(format: "%.0f", r.gap.durationSeconds * 1000))ms]: lag=\(r.lag) rho=\(String(format: "%.3f", r.rho)) residual=\(String(format: "%.1f", r.residualDb))dB")
        }
        for r in after {
            Self.log("M-1 AFTER (reported, feeds R1/R5, never a stop) gap \(r.gap.index) [\(String(format: "%.3f", r.gap.startSeconds))-\(String(format: "%.3f", r.gap.endSeconds))s, \(String(format: "%.0f", r.gap.durationSeconds * 1000))ms]: lag=\(r.lag) rho=\(String(format: "%.3f", r.rho)) residual=\(String(format: "%.1f", r.residualDb))dB")
        }

        let realLagFound = before.filter { $0.lag != 0 && $0.rho >= 0.9 }
        let lowRhoAtNonzeroLag = before.filter { $0.lag != 0 && $0.rho < 0.9 }
        let verdict: String
        if !realLagFound.isEmpty {
            verdict = "C2 PAUSES (R2): \(realLagFound.count) clean-history (before) gap(s) show a real non-zero lag at rho >= 0.9 — needs the constant-integer-compensation fallback, re-reviewed by daw-architect before C2 resumes"
        } else if !lowRhoAtNonzeroLag.isEmpty {
            verdict = "C2 MAY PROCEED, but \(lowRhoAtNonzeroLag.count) clean-history (before) gap(s) read a non-zero lag at LOW rho — reported as a finding, never read as a delay per R2"
        } else {
            verdict = "C2 MAY PROCEED: every clean-history (before-the-move) gap read lag 0 at rho >= 0.9"
        }
        Self.log("M-1 VERDICT: \(verdict)")
        if let worstAfterResidual = after.map(\.residualDb).max() {
            Self.log("M-1 R5 note: pre-registered red threshold for G-C3's waveform-residual leg, from the AFTER population's residual dB, is ~\(String(format: "%.1f", after.map(\.residualDb).reduce(0, +) / Double(after.count))) dB (range \(String(format: "%.1f", after.map(\.residualDb).min() ?? .nan)) to \(String(format: "%.1f", worstAfterResidual)) dB over \(after.count) gaps); flag-on target is -inf beyond the fade")
        }
        #expect(before.allSatisfy { $0.lag.magnitude <= Self.maxLagSamples })
    }

    /// The two PREREG'd plants, run on a REAL clean-history gap's own dry
    /// audio (not the synthetic fixture — `ConsonantLagRhoKnownAnswerTests`
    /// already proves the instrument on synthetic material; this proves it
    /// still works on THIS take's actual spectral content, which
    /// `NaturalTuningBaselineTests`' fricative fixture measured to be much
    /// less self-coherent than a real voice recording's breath/room tone).
    @Test("M-1 plants: a real 3-sample delay reads 3; a pi/2 phase rotation reads lag 0 with low rho (R2)",
          .enabled(if: enabled))
    @MainActor
    func m1Plants() throws {
        let take = try Self.load()
        let movedRunIndex = take.runs.count / 2
        let gaps = Self.qualifyingGaps(take).filter { $0.index < movedRunIndex } // R2: before the moved note
        let gap = try #require(gaps.max { $0.durationSeconds < $1.durationSeconds },
                               "no clean-history gap available for the plants")
        let lo = Int((gap.startSeconds * take.sampleRate).rounded())
        let hi = min(take.dry.count, Int((gap.endSeconds * take.sampleRate).rounded()))
        let dry = Array(take.dry[lo..<hi])

        let delayed = [Float](repeating: 0, count: 3) + dry.dropLast(3)
        let (delayLag, delayRho) = ConsonantSpectrumMeter.analyticLagRho(
            dry: dry, wet: delayed, maxLag: Self.maxLagSamples)
        Self.log("M-1 plant (real delay=3, gap \(gap.index)): lag=\(delayLag) rho=\(String(format: "%.3f", delayRho))")
        #expect(delayLag == 3, "the instrument must read a real 3-sample delay as 3 on THIS take's own material")
        #expect(delayRho > 0.9)

        let rotated = ConsonantLagRhoKnownAnswerTests.phaseRotatedQuarterTurn(dry)
        let (rotationLag, rotationRho) = ConsonantSpectrumMeter.analyticLagRho(
            dry: dry, wet: rotated, maxLag: Self.maxLagSamples)
        Self.log("M-1 plant (pi/2 rotation, gap \(gap.index)): lag=\(rotationLag) rho=\(String(format: "%.3f", rotationRho))")
        #expect(rotationLag == 0, "a pure phase rotation must read lag 0, never a fractional delay")
        #expect(abs(rotationRho) < 0.3, "a pure phase rotation must read LOW rho, telling it apart from a real delay")
    }

    // MARK: - M-3: gap histogram, fade-length correlation

    /// Gap-duration histogram (pure arithmetic on `VoicedRun` boundaries) plus
    /// wet/dry Pearson rho at 5/10/20 ms candidate fades, reusing the SAME
    /// M-1 render (a second `renderThroughShippingPath` call — deterministic,
    /// so this is a correctness convenience, not a second measurement).
    @Test("M-3: gap-duration histogram and wet/dry fade-length correlation",
          .enabled(if: enabled))
    @MainActor
    func m3GapHistogramAndFadeCorrelation() throws {
        let take = try Self.load()
        let blinkThresholdSeconds = 2 / take.frameRateHz
        var allGaps: [Double] = []
        for i in 0..<(take.runs.count - 1) {
            allGaps.append(take.runs[i + 1].startSeconds - take.runs[i].endSeconds)
        }
        let blinks = allGaps.filter { $0 <= blinkThresholdSeconds }
        let buckets: [(String, ClosedRange<Double>)] = [
            ("<=blink", 0...blinkThresholdSeconds),
            ("blink-32ms", blinkThresholdSeconds...0.032),
            ("32-64ms", 0.032...0.064), ("64-128ms", 0.064...0.128),
            ("128-256ms", 0.128...0.256), ("256-512ms", 0.256...0.512),
            (">512ms", 0.512...Double.infinity),
        ]
        for (label, range) in buckets {
            let count = allGaps.filter { range.contains($0) }.count
            Self.log("M-3 histogram \(label): \(count) of \(allGaps.count) gaps")
        }
        Self.log("M-3 blink threshold = \(String(format: "%.1f", blinkThresholdSeconds * 1000)) ms " +
                "(2 frames @ \(take.frameRateHz) fps): \(blinks.count) blinks of \(allGaps.count) total gaps")
        #expect(!allGaps.isEmpty)

        let movedRunIndex = take.runs.count / 2
        let set = Self.movedNoteSet(take, movedRunIndex: movedRunIndex)
        let rendered = try NaturalTuningBaselineTests.renderThroughShippingPath(take.dry, set: set)
        let gaps = Self.qualifyingGaps(take)
        for fadeMs in [5.0, 10.0, 20.0] {
            let fadeFrames = Int((fadeMs / 1000 * take.sampleRate).rounded())
            var rhos: [Double] = []
            for gap in gaps {
                let startFrame = Int((gap.startSeconds * take.sampleRate).rounded())
                let endFrame = Int((gap.endSeconds * take.sampleRate).rounded())
                for edge in [startFrame, max(startFrame, endFrame - fadeFrames)] {
                    let lo = max(0, edge), hi = min(take.dry.count, rendered.count, edge + fadeFrames)
                    guard hi - lo == fadeFrames else { continue }
                    let dry = Array(take.dry[lo..<hi]), wet = Array(rendered[lo..<hi])
                    rhos.append(ConsonantSpectrumMeter.pearsonAtLag(dry: dry, wet: wet, lag: 0))
                }
            }
            let passing = rhos.filter { $0 >= 0.9 }.count
            Self.log("M-3 fade \(Int(fadeMs)) ms: \(passing) of \(rhos.count) edges read rho >= 0.9 " +
                    "(median \(String(format: "%.3f", Self.median(rhos) ?? .nan)))")
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
        return sorted[idx]
    }

    // MARK: - M-2: edge placement (simplified independent-onset leg)

    static func zeroCrossingRate(_ x: [Float]) -> Double {
        guard x.count > 1 else { return 0 }
        var crossings = 0
        for i in 1..<x.count where (x[i - 1] < 0) != (x[i] < 0) { crossings += 1 }
        return Double(crossings) / Double(x.count - 1)
    }

    /// Spectral flatness (geometric mean / arithmetic mean of the power
    /// spectrum): near 0 for a tonal/periodic signal, near 1 for white noise.
    /// Reuses `ConsonantSpectrumMeter.powerSpectrum` (already tested,
    /// zero-pads short windows) rather than a fresh FFT.
    ///
    /// ⚠️ **MEASURED, NOT GUESSED: restricted to 300 Hz-8 kHz with a
    /// RELATIVE floor, not the whole spectrum with an absolute one.** A
    /// first version used every bin (0-24 kHz) with a `1e-20` absolute floor
    /// and read ~0.000 for BOTH voiced and unvoiced material on the real
    /// take — a handful of near-null bins from a short, zero-padded window
    /// (many bins sit at or below machine noise) drag a geometric mean to
    /// zero regardless of the signal's real shape. Limiting to the band
    /// where voice/fricative energy actually lives, and flooring each bin at
    /// a FRACTION of that window's own peak (not an absolute constant),
    /// fixed it — re-checked against the same take (see results.md).
    static func flatness(_ x: [Float], sampleRate: Double) -> Double? {
        guard let (bins, binHz) = ConsonantSpectrumMeter.powerSpectrum(x, sampleRate: sampleRate) else { return nil }
        let lo = max(0, Int((300.0 / binHz).rounded()))
        let hi = min(bins.count - 1, Int((8000.0 / binHz).rounded()))
        guard hi > lo else { return nil }
        let band = bins[lo...hi]
        let peak = band.max() ?? 0
        guard peak > 0 else { return nil }
        let floor = peak * 1e-6
        var logSum = 0.0, sum = 0.0, n = 0
        for p in band {
            let clamped = max(p, floor)
            logSum += Foundation.log(clamped); sum += clamped; n += 1
        }
        guard n > 0, sum > 0 else { return nil }
        return exp(logSum / Double(n)) / (sum / Double(n))
    }

    /// The independent onset: scans forward through
    /// `[max(searchCenter - radius, earliestSeconds), searchCenter + radius]`
    /// in `hopSeconds` hops and returns the first hop whose flatness AND
    /// zero-crossing rate are both below their thresholds -- two cues that
    /// never read the product's own voicing decision, unlike
    /// `busyline-frames.csv`'s `spectral_flatness` column (populated only
    /// where `product_voiced == 1`, which would make an "independent" check
    /// circular).
    ///
    /// ⚠️ **`earliestSeconds` IS LOAD-BEARING, MEASURED.** A first version
    /// with no floor searched blindly 150 ms back from every run's start and
    /// read `150.0 ms` for ALL 42 runs on the real take — plainly wrong,
    /// found by noticing every single reading hit the search radius exactly.
    /// Cause: many of this take's gaps are SHORTER than 150 ms (M-3's own
    /// histogram: 12 of 41 gaps are under 128 ms), so the backward scan ran
    /// straight through the gap and into the tail of the PREVIOUS note,
    /// which is voiced-like by construction and satisfies the threshold on
    /// the very first window checked. Clamping the scan to never cross the
    /// previous run's own end fixes it.
    ///
    /// ⚠️⚠️ **A SECOND BUG, SAME SYMPTOM: this returned the first VOICED-LIKE
    /// window, not a CROSSING.** Even after the fix above, real material at
    /// the clamped start (the previous run's OWN declared end) can still be
    /// acoustically voiced-like for a few more ms than the product's
    /// frame-quantized decision says (voices decay, they do not cut), so the
    /// very first window checked was often already "voiced-like" again,
    /// reproducing the same `earliestSeconds`-boundary reading with a new
    /// cause. Fixed by requiring at least one genuinely unvoiced-like window
    /// BEFORE accepting a voiced-like one — i.e. the low→high edge, not mere
    /// presence.
    static func independentOnsetSeconds(
        _ audio: [Float], sampleRate: Double, searchCenterSeconds: Double, searchRadiusSeconds: Double,
        earliestSeconds: Double = 0, flatnessThreshold: Double, zcrThreshold: Double,
        windowSeconds: Double = 0.020, hopSeconds: Double = 0.004
    ) -> Double? {
        let windowFrames = Int((windowSeconds * sampleRate).rounded())
        let hopFrames = max(1, Int((hopSeconds * sampleRate).rounded()))
        let centerFrame = Int((searchCenterSeconds * sampleRate).rounded())
        let radiusFrames = Int((searchRadiusSeconds * sampleRate).rounded())
        let earliestFrame = Int((earliestSeconds * sampleRate).rounded())
        var frame = max(0, earliestFrame, centerFrame - radiusFrames)
        let endFrame = min(audio.count - windowFrames, centerFrame + radiusFrames)
        guard endFrame > frame else { return nil }
        var sawUnvoicedLike = false
        while frame <= endFrame {
            let window = Array(audio[frame..<(frame + windowFrames)])
            let voicedLike = flatness(window, sampleRate: sampleRate)
                .map { $0 < flatnessThreshold && zeroCrossingRate(window) < zcrThreshold } ?? false
            if voicedLike, sawUnvoicedLike {
                return Double(frame) / sampleRate
            }
            if !voicedLike { sawUnvoicedLike = true }
            frame += hopFrames
        }
        return nil
    }

    /// ⚠️ **SIMPLIFIED FROM 2g's SPEC — see results.md.** 2g restricts M-2 to
    /// "the 19 audible no-note sounds that touch the following note"
    /// (unpitched design :90-126) and uses librosa; this measures the offset
    /// at EVERY run boundary on this take instead, with a from-scratch
    /// flatness+ZCR detector calibrated on this take's own voiced/unvoiced
    /// levels. It answers the same QUESTION (how far off is the product's
    /// onset from an independent one) with a documented, honest reduction in
    /// scope, not a silent one.
    @Test("M-2: edge placement, product onset vs an independent flatness+ZCR onset (simplified)",
          .enabled(if: enabled))
    @MainActor
    func m2EdgePlacement() throws {
        let take = try Self.load()

        // Calibrate thresholds on THIS take: sample flatness/ZCR well inside
        // several voiced runs and several unvoiced gaps, and split the
        // difference -- self-calibrating beats a literature constant because
        // this fixture's noise floor and mic are specific to one recording.
        func sample(_ ranges: [(Double, Double)]) -> (flatness: Double, zcr: Double)? {
            var flatnesses: [Double] = [], zcrs: [Double] = []
            for (start, end) in ranges {
                let mid = (start + end) / 2
                let lo = Int((mid * take.sampleRate).rounded())
                let hi = min(take.dry.count, lo + Int(0.020 * take.sampleRate))
                guard hi > lo else { continue }
                let window = Array(take.dry[lo..<hi])
                if let f = Self.flatness(window, sampleRate: take.sampleRate) {
                    flatnesses.append(f)
                    zcrs.append(Self.zeroCrossingRate(window))
                }
            }
            guard !flatnesses.isEmpty else { return nil }
            return (flatnesses.reduce(0, +) / Double(flatnesses.count),
                    zcrs.reduce(0, +) / Double(zcrs.count))
        }
        let voicedSample = sample(take.runs.prefix(10).map { ($0.startSeconds, $0.endSeconds) })
        let gaps = Self.qualifyingGaps(take)
        let unvoicedSample = sample(gaps.prefix(10).map { ($0.startSeconds, $0.endSeconds) })
        guard let voiced = voicedSample, let unvoiced = unvoicedSample else {
            Self.log("M-2: could not calibrate (not enough voiced/unvoiced material) -- skipping")
            return
        }
        let flatnessThreshold = (voiced.flatness + unvoiced.flatness) / 2
        let zcrThreshold = (voiced.zcr + unvoiced.zcr) / 2
        Self.log("M-2 calibration: voiced flatness=\(String(format: "%.3f", voiced.flatness)) zcr=\(String(format: "%.4f", voiced.zcr)); unvoiced flatness=\(String(format: "%.3f", unvoiced.flatness)) zcr=\(String(format: "%.4f", unvoiced.zcr)); thresholds flatness<\(String(format: "%.3f", flatnessThreshold)) zcr<\(String(format: "%.4f", zcrThreshold))")

        var offsetsMs: [Double] = []
        for (i, run) in take.runs.enumerated() {
            let earliest = i > 0 ? take.runs[i - 1].endSeconds : 0
            guard let independent = Self.independentOnsetSeconds(
                take.dry, sampleRate: take.sampleRate, searchCenterSeconds: run.startSeconds,
                searchRadiusSeconds: 0.150, earliestSeconds: earliest,
                flatnessThreshold: flatnessThreshold, zcrThreshold: zcrThreshold)
            else { continue }
            offsetsMs.append((run.startSeconds - independent) * 1000)
        }
        let absOffsets = offsetsMs.map(abs)
        Self.log("M-2: \(absOffsets.count) of \(take.runs.count) run starts matched an independent onset within +-150 ms; median |offset| = \(String(format: "%.1f", Self.median(absOffsets) ?? .nan)) ms, p90 = \(String(format: "%.1f", Self.percentile(absOffsets, 0.9) ?? .nan)) ms")
        #expect(!absOffsets.isEmpty, "the independent detector found nothing on this take; the calibration or the search radius needs revisiting before this number means anything")
        // ⚠️ **DO NOT TRUST THIS MEDIAN AS "THE" M-2 ANSWER.** After three
        // fixes (restrict flatness to 300 Hz-8 kHz; clamp the backward scan
        // at the previous run's own end; require an unvoiced->voiced EDGE,
        // not mere voiced-like presence) the numbers moved from a degenerate
        // 42/42 at exactly the 150 ms boundary to 32/42, median 66.0 ms,
        // p90 138.0 ms -- no longer degenerate, but still a large median for
        // something that should land within a frame or two if the two onset
        // notions truly agreed. Most likely: the two-cue (flatness + ZCR)
        // threshold, calibrated on this take's OWN average voiced/unvoiced
        // levels, still isn't as sharp on real breath/room-tone material as
        // it is on the synthetic noise-then-tone control below (which passes
        // cleanly at 20 ms). Reported as an HONEST NON-RESULT, not as M-2's
        // real number: a
        // librosa-based detector (2g's original spec) or a PER-GAP adaptive
        // threshold is needed before this leg can be trusted. See results.md.
        Self.log("M-2 CAVEAT: the on-take numbers above are NOT a trustworthy independent-onset measurement (see the doc comment above this line) -- only the synthetic positive control below is validated")

        // Positive control: a SYNTHETIC noise-then-tone fixture with a KNOWN
        // onset, and the SAME onset shifted by a planted 20 ms -- proves the
        // detector (not just arithmetic) is sensitive to a 20 ms shift.
        let sr = take.sampleRate
        func noiseThenTone(onsetSeconds: Double) -> [Float] {
            var generator = SplitMix64(seed: 0xED9E)
            var out = [Float](repeating: 0, count: Int(0.6 * sr))
            for i in 0..<out.count { out[i] = (generator.nextUnit() * 2 - 1) * 0.3 }
            let onsetFrame = Int(onsetSeconds * sr)
            for i in onsetFrame..<out.count {
                out[i] = 0.5 * Float(sin(2 * .pi * 220 * Double(i) / sr))
            }
            return out
        }
        let base = noiseThenTone(onsetSeconds: 0.300)
        let shifted = noiseThenTone(onsetSeconds: 0.320) // +20 ms
        let baseOnset = try #require(Self.independentOnsetSeconds(
            base, sampleRate: sr, searchCenterSeconds: 0.300, searchRadiusSeconds: 0.100,
            flatnessThreshold: 0.5, zcrThreshold: 0.15))
        let shiftedOnset = try #require(Self.independentOnsetSeconds(
            shifted, sampleRate: sr, searchCenterSeconds: 0.320, searchRadiusSeconds: 0.100,
            flatnessThreshold: 0.5, zcrThreshold: 0.15))
        let plantedShiftMs = (shiftedOnset - baseOnset) * 1000
        Self.log("M-2 positive control: planted 20 ms onset shift reads \(String(format: "%.1f", plantedShiftMs)) ms")
        #expect(abs(plantedShiftMs - 20) < 8,
                "the detector failed to read a planted 20 ms onset shift; the M-2 numbers above cannot be trusted")
    }
}
