import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// Natural tuning §3g **G3** (W7-C3): drift/wobble SEPARATION PHYSICS, measured
/// on audio rendered through the SHIPPING path (`StretchRenderCache.renderIfNeeded`).
///
/// ⭐ **PRE-REGISTERED.** Every threshold, fixture and definition here is from
/// the W7-C3 lane's PREREG-G3 (written 2026-09-27 05:54:12 PDT, 1 h 21 min
/// before the first G3 render; section numbers §1-§11 below are its). Nothing
/// was moved after data: a threshold the product fails is still here, asserted,
/// inside `withKnownIssue` (`knownFailures`), with the reason.
///
/// ⭐ **THE VERDICT (2026-09-27): FAIL → KEEP COUPLING.** No kernel L passed
/// every cell at 110 Hz: (1,0) kept 0.211 (L = 0.16 s) to 0.237 (0.25 s) of the
/// sung wobble against ≤ 0.2. The shipped kernel, L = 0.16 s truncate, is the
/// pre-registered FALLBACK pick (the separator's own legs). At 220 Hz the
/// renderer, not the separator, leaves 0.572 of the wobble in (the curve alone
/// leaves 0.146). The separator's own legs pass at every pitch: (0,1) keeps
/// the wobble within 1 % of ideal and removes ≥ 76 % of the drift, and
/// nothing inverts.
///
/// **What is measured.** A synthetic tone (`ContourToRenderTests.tone`, 12
/// partials at 1/k) with a known slow DRIFT (0.5 Hz, ±30 c) and a known fast
/// WOBBLE (5.5 Hz, ±40 c) is tuned with a (driftScale, vibratoScale) cell, rendered
/// by the product, tracked with `M23QToneTracker` at 4096/480 (not the product's
/// detector: an instrument grading its own output is a closed loop), and fitted
/// by least squares at the two known rates. Each figure is quoted against
/// an **IdealReading**: the same tracker and fit on an ideal tone, from the same
/// synthesiser, whose pitch follows the PHYSICALLY ideal separation (the true
/// drift and wobble, scaled by the cell). The instrument's own smoothing sits on
/// both sides of every ratio.
///
/// **Controls that must come out the other way.** The v1 separator (today's
/// boxcar, `Separator.v1Everywhere`) and a kernel with a deliberate negative lobe
/// (`Separator.kernelTaps`, parameter-injected, not a source plant) render the
/// same cells and must FAIL them. The separator is a `StretchRenderCache`
/// instance parameter, never a global switch, because tests render in parallel.
///
/// Env-gated extras: `NT_DRIFT_SWEEP=1` runs the L × edge sweep, the short-note
/// ladder per kernel, the scoop cell and every REPORTED attribution leg (§7-§10)
/// and prints the table; `NT_DRIFT_OUT=<dir>` also writes it there as markdown.
///
/// Deliberately NOT `@MainActor`, at suite level (`MainActorOccupancySiteTests`
/// Leg C counts suites) or per test: a test hops to the main actor only to
/// build a cache and to await its renders (`cache`, `renderAll`), and does
/// every tracker read and fit OFF the main actor, so a long reading never
/// holds up the main-actor tests that run beside it.
@Suite("Natural tuning §3 G3 — drift/wobble separation physics (W7-C3)")
struct NaturalTuningDriftVibratoTests {
    static func log(_ message: String) { print("nt-drift| \(message)") }

    static let sweepEnabled = ProcessInfo.processInfo.environment["NT_DRIFT_SWEEP"] != nil
    static let outputDirectory = ProcessInfo.processInfo.environment["NT_DRIFT_OUT"]

    // MARK: - PREREG §1: the fixture

    static let sampleRate = 48_000.0
    static let padSeconds = 0.30
    static let longSeconds = 4.0
    static let driftHz = 0.5
    static let driftCents = 30.0
    static let wobbleHz = 5.5
    static let wobbleCents = 40.0
    static let scoopSeconds = 0.08
    static let scoopCents = 100.0
    static let shortLadder: [Double] = [0.2, 0.3, 0.4, 0.5, 0.8]
    static let shortExtension: [Double] = [1.0, 1.2, 1.6]
    static let scoopNoteSeconds = 0.8

    /// One synthetic note between two 0.30 s silences. Times are FILE seconds.
    struct Fixture: Sendable, Hashable, CustomStringConvertible {
        enum Kind: String, Sendable, Hashable { case long, short, scoop }
        let kind: Kind
        let hz: Double
        let noteSeconds: Double
        var wobbleHz: Double = NaturalTuningDriftVibratoTests.wobbleHz

        var ts: Double { NaturalTuningDriftVibratoTests.padSeconds }
        var te: Double { ts + noteSeconds }
        var tc: Double { ts + noteSeconds / 2 }
        var description: String {
            "\(kind.rawValue) \(String(format: "%.2f", hz)) Hz \(String(format: "%.1f", noteSeconds)) s"
                + (wobbleHz == NaturalTuningDriftVibratoTests.wobbleHz ? "" : " wobble \(wobbleHz) Hz")
        }

        static func long(_ hz: Double, wobbleHz: Double = NaturalTuningDriftVibratoTests.wobbleHz) -> Fixture {
            Fixture(kind: .long, hz: hz, noteSeconds: NaturalTuningDriftVibratoTests.longSeconds,
                    wobbleHz: wobbleHz)
        }
        static func short(_ hz: Double, _ seconds: Double) -> Fixture {
            Fixture(kind: .short, hz: hz, noteSeconds: seconds)
        }
        static func scoop(_ hz: Double) -> Fixture {
            Fixture(kind: .scoop, hz: hz, noteSeconds: NaturalTuningDriftVibratoTests.scoopNoteSeconds)
        }

        /// D(t): the slow drift. A long note starts on a rising zero-crossing; a
        /// short note is CENTRED on one (maximum slope); the scoop note has none.
        func drift(_ t: Double) -> Double {
            switch kind {
            case .long: return NaturalTuningDriftVibratoTests.driftCents
                * sin(2 * .pi * NaturalTuningDriftVibratoTests.driftHz * (t - ts))
            case .short: return NaturalTuningDriftVibratoTests.driftCents
                * sin(2 * .pi * NaturalTuningDriftVibratoTests.driftHz * (t - tc))
            case .scoop: return 0
            }
        }
        /// V(t): the wobble, phase 0 at the note start.
        func wobble(_ t: Double) -> Double {
            NaturalTuningDriftVibratoTests.wobbleCents * sin(2 * .pi * wobbleHz * (t - ts))
        }
        /// S(t): the onset scoop (scoop fixture only), a raised cosine from −100 c up to 0 over 80 ms.
        func scoop(_ t: Double) -> Double {
            guard kind == .scoop else { return 0 }
            let u = t - ts
            guard u >= 0, u < NaturalTuningDriftVibratoTests.scoopSeconds else { return 0 }
            return -NaturalTuningDriftVibratoTests.scoopCents
                * (1 + cos(.pi * u / NaturalTuningDriftVibratoTests.scoopSeconds)) / 2
        }

        /// The note, padded, whose pitch (cents above `hz`) is `cents(t)` at file second t.
        func audio(_ cents: @escaping (Double) -> Double) -> [Float] {
            let pad = [Float](repeating: 0, count: Int(NaturalTuningDriftVibratoTests.padSeconds
                                                            * NaturalTuningDriftVibratoTests.sampleRate))
            let start = ts
            let f = hz
            let note = ContourToRenderTests.tone(seconds: noteSeconds) { u in
                f * pow(2, cents(start + u) / 1200)
            }
            return pad + note + pad
        }

        /// The source ("as sung"), and every ideal tone: drift × d, wobble × v, scoop × s.
        func audio(drift d: Double, wobble v: Double, scoop s: Double = 1) -> [Float] {
            let fixture = self
            return audio { t in d * fixture.drift(t) + v * fixture.wobble(t) + s * fixture.scoop(t) }
        }

        /// PREREG §2: the measured window, the known bounds trimmed 10 % of T each end.
        var window: ClosedRange<Double> { (ts + 0.1 * noteSeconds)...(te - 0.1 * noteSeconds) }
    }

    // MARK: - PREREG §2: the instrument

    typealias Series = WobbleOnsetListeningTests.Reader.Series

    /// `M23QToneTracker` at 4096 / 480, estimates every 240 samples, band
    /// [0.7F, 1.3F], cents vs F, timed at the estimate CENTRE.
    static func track(_ audio: [Float], _ fx: Fixture, within window: ClosedRange<Double>) -> Series {
        WobbleOnsetListeningTests.Reader.tracked(audio, sampleRate: sampleRate, hz: fx.hz,
                                                  within: window)
    }

    /// Ordinary least squares, normal equations, Gaussian elimination with
    /// partial pivoting. `nil` when too few samples or the system is singular.
    static func leastSquares(_ rows: [[Double]], _ y: [Double]) -> [Double]? {
        guard let p = rows.first?.count, rows.count >= p + 2 else { return nil }
        var a = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        var b = [Double](repeating: 0, count: p)
        for (row, value) in zip(rows, y) {
            for i in 0..<p {
                b[i] += row[i] * value
                for j in 0..<p { a[i][j] += row[i] * row[j] }
            }
        }
        for col in 0..<p {
            var pivot = col
            for r in col..<p where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            guard abs(a[pivot][col]) > 1e-12 else { return nil }
            a.swapAt(col, pivot)
            b.swapAt(col, pivot)
            for r in 0..<p where r != col {
                let factor = a[r][col] / a[col][col]
                if factor == 0 { continue }
                for c in col..<p { a[r][c] -= factor * a[col][c] }
                b[r] -= factor * b[col]
            }
        }
        return (0..<p).map { b[$0] / a[$0][$0] }
    }

    /// One reading of one note: PREREG §2's fit for the fixture's kind.
    struct Reading: Sendable {
        let count: Int
        /// Wobble amplitude at the fixture's wobble rate, tracker cents.
        let wobble: Double
        /// `v ≈ A·sin(ωv(t − ts) + φ)`: the wobble's phase, radians.
        let phase: Double
        /// LONG: the 0.5 Hz pair's amplitude. SHORT/SCOOP: the RMS of the slope +
        /// curvature part (the constant excluded: re-centring is not steadying).
        let drift: Double
        /// LONG only: `drift ≈ Dr·sin(ωd(t − ts) + driftPhase)`; 0 otherwise.
        var driftPhase: Double = 0
        /// `PitchWobbleEstimate.refit` depth on the untrimmed series (second instrument).
        let refitDepth: Double?
        let series: Series
    }

    static func read(_ audio: [Float], _ fx: Fixture) -> Reading? {
        fit(track(audio, fx, within: fx.ts...fx.te), fx)
    }

    /// PREREG §2's fit of a series (tracked, or evaluated arithmetic) over the
    /// fixture's trimmed window.
    static func fit(_ full: Series, _ fx: Fixture) -> Reading? {
        var t: [Double] = [], v: [Double] = []
        for (time, value) in zip(full.t, full.v) where fx.window.contains(time) && value.isFinite {
            t.append(time)
            v.append(value)
        }
        guard t.count >= 12 else { return nil }
        let wv = 2 * Double.pi * fx.wobbleHz
        let wd = 2 * Double.pi * driftHz
        let refit = PitchWobbleEstimate.refit(times: full.t, cents: full.v, rateHz: fx.wobbleHz)?.depthCents
        switch fx.kind {
        case .long:
            let rows = t.map { time -> [Double] in
                let u = time - fx.ts
                return [1, sin(wd * u), cos(wd * u), sin(wv * u), cos(wv * u)]
            }
            guard let x = leastSquares(rows, v) else { return nil }
            return Reading(count: t.count, wobble: hypot(x[3], x[4]), phase: atan2(x[4], x[3]),
                           drift: hypot(x[1], x[2]), driftPhase: atan2(x[2], x[1]),
                           refitDepth: refit, series: Series(t: t, v: v))
        case .short, .scoop:
            let meanTau2 = t.map { ($0 - fx.tc) * ($0 - fx.tc) }.reduce(0, +) / Double(t.count)
            let rows = t.map { time -> [Double] in
                let tau = time - fx.tc
                let u = time - fx.ts
                return [1, tau, tau * tau - meanTau2, sin(wv * u), cos(wv * u)]
            }
            guard let x = leastSquares(rows, v) else { return nil }
            let slow = t.map { time -> Double in
                let tau = time - fx.tc
                return x[1] * tau + x[2] * (tau * tau - meanTau2)
            }
            let rms = (slow.map { $0 * $0 }.reduce(0, +) / Double(slow.count)).squareRoot()
            return Reading(count: t.count, wobble: hypot(x[3], x[4]), phase: atan2(x[4], x[3]),
                           drift: rms, refitDepth: refit, series: Series(t: t, v: v))
        }
    }

    /// The signed area, cents·seconds, of `x − ref` over PREREG §9's scoop
    /// window, [ts − 0.05, ts + 0.20] (`start` moves its left edge; only the
    /// scoop cell's POST-HOC line does).
    static func scoopArea(_ x: [Float], _ reference: [Float], _ fx: Fixture,
                          from start: Double = -0.05) -> Double? {
        let window = (fx.ts + start)...(fx.ts + 0.20)
        let a = track(x, fx, within: window)
        let b = track(reference, fx, within: window)
        let difference = WobbleOnsetListeningTests.Reader.subtract(a, b)
        guard difference.t.count >= 12 else { return nil }
        let dt = 240.0 / sampleRate
        return difference.v.reduce(0, +) * dt
    }
}

// MARK: - Rendering a cell through the shipping path (PREREG §1)

extension NaturalTuningDriftVibratoTests {
    typealias Separator = PitchCorrectionCurve.Separator

    /// A written source, its product detection and the one voiced run the cell
    /// needs. PREREG §1: a cell is INVALID unless exactly one run overlaps the
    /// note and it covers ≥ 90 % of it.
    struct Source: Sendable {
        let fixture: Fixture
        let url: URL
        let audio: [Float]
        let detection: PitchDetectionResult
        let run: VoicedRun?
        let invalidReason: String?
    }

    static func source(_ fx: Fixture, in dir: URL) throws -> Source {
        let audio = fx.audio(drift: 1, wobble: 1)
        let url = dir.appendingPathComponent("src-\(fx.kind.rawValue)-\(Int(fx.hz * 100))-\(Int(fx.noteSeconds * 1000))-\(Int(fx.wobbleHz * 10)).wav")
        try ContourToRenderTests.write(audio, to: url)
        let detection = try PitchContourCache.detectWholeFile(url, .product)
        let runs = PitchAutoCorrect.voicedRuns(in: detection.frames, frameRateHz: detection.frameRateHz)
        let overlapping = runs.filter { $0.endSeconds > fx.ts && $0.startSeconds < fx.te }
        var reason: String?
        if overlapping.count != 1 {
            reason = "\(overlapping.count) voiced runs overlap the note"
        } else {
            let run = overlapping[0]
            let covered = min(run.endSeconds, fx.te) - max(run.startSeconds, fx.ts)
            if covered < 0.9 * fx.noteSeconds {
                reason = String(format: "the one run covers %.0f %% of the note", 100 * covered / fx.noteSeconds)
            }
        }
        return Source(fixture: fx, url: url, audio: audio, detection: detection,
                      run: overlapping.count == 1 ? overlapping[0] : nil, invalidReason: reason)
    }

    /// The cell's edit set: the product's own run, the cell's scales.
    static func editSet(_ source: Source, drift d: Double, vibrato v: Double) -> PitchEditSet? {
        guard let run = source.run, source.invalidReason == nil else { return nil }
        return PitchEditSet(segments: [
            NoteSegment(startSeconds: run.startSeconds, endSeconds: run.endSeconds,
                        detectedHz: run.centreHz, detectedConfidence: run.medianConfidence,
                        driftScale: d, vibratoScale: v)
        ], retuneMs: 30)
    }

    /// Renders one cell through `StretchRenderCache.renderIfNeeded` with the
    /// cache's own separator. (1,1) is identity, so the product returns the
    /// source file itself; the caller checks that.
    @MainActor
    static func render(_ source: Source, drift d: Double, vibrato v: Double,
                       cache: StretchRenderCache) async throws -> (audio: [Float], url: URL)? {
        guard let set = editSet(source, drift: d, vibrato: v) else { return nil }
        return try await ContourToRenderTests.productRender(
            Clip(name: "g3", audioFileURL: source.url, pitchEdits: set), cache: cache)
    }

    /// One scored cell: delivered, as sung, and the physically ideal reading.
    struct Cell: Sendable {
        let fixture: Fixture
        let drift: Double
        let vibrato: Double
        let separator: String
        let delivered: Reading
        let asSung: Reading
        let ideal: Reading

        /// W / W(I): the wobble against the ideal separation.
        var wobbleVsIdeal: Double { delivered.wobble / ideal.wobble }
        /// W / W(A) and Dr / Dr(A): against the note as sung.
        var wobbleVsSung: Double { delivered.wobble / asSung.wobble }
        var driftVsSung: Double { delivered.drift / asSung.drift }
        /// Real cents: reading ÷ as-sung reading × the true amplitude.
        var wobbleRealCents: Double { wobbleVsSung * NaturalTuningDriftVibratoTests.wobbleCents }
        /// cos(φ − φ(A)) < 0: the remaining wobble moves AGAINST the sung one.
        var phaseCosine: Double { cos(delivered.phase - asSung.phase) }
        /// PREREG §4: inverted := real depth ≥ 5 c AND cos Δφ < 0.
        var inverted: Bool { wobbleRealCents >= 5 && phaseCosine < 0 }

        var summary: String {
            String(format: "%@ (%g,%g) %@: W/W(I) %.3f  W/W(A) %.3f  Dr/Dr(A) %.3f  real %.1f c  cosΔφ %+.2f%@  refit %@ c  n=%d",
                   fixture.description as NSString, drift, vibrato, separator as NSString,
                   wobbleVsIdeal, wobbleVsSung, driftVsSung, wobbleRealCents, phaseCosine,
                   (inverted ? " INVERTED" : "") as NSString,
                   (delivered.refitDepth.map { String(format: "%.1f", $0) } ?? "nil") as NSString,
                   delivered.count)
        }
    }

    /// The as-sung and ideal readings of one test, each computed once: they
    /// depend only on (fixture, d, v), and every separator shares them. One per
    /// test, never shared between tests.
    final class ReadingMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [String: Reading] = [:]
        func reading(_ key: String, _ make: () -> Reading?) -> Reading? {
            lock.lock()
            if let known = readings[key] { lock.unlock(); return known }
            lock.unlock()
            guard let made = make() else { return nil }
            lock.lock()
            readings[key] = made
            lock.unlock()
            return made
        }
    }

    /// Scores `audio` as cell (d, v) of `source`.
    static func score(_ audio: [Float], _ source: Source, drift d: Double, vibrato v: Double,
                      separator: String, memo: ReadingMemo = ReadingMemo()) -> Cell? {
        let fx = source.fixture
        guard let delivered = read(audio, fx),
              let asSung = memo.reading("\(fx) as sung", { read(source.audio, fx) }),
              let ideal = memo.reading("\(fx) ideal \(d)/\(v)", { read(fx.audio(drift: d, wobble: v), fx) })
        else { return nil }
        return Cell(fixture: fx, drift: d, vibrato: v, separator: separator,
                    delivered: delivered, asSung: asSung, ideal: ideal)
    }

    /// PREREG §4's asserted thresholds for one cell (nil = the cell has none).
    static func verdict(_ cell: Cell) -> (passes: Bool, why: String)? {
        switch (cell.drift, cell.vibrato) {
        case (0, 1):
            let ok = (0.9...1.1).contains(cell.wobbleVsIdeal) && cell.driftVsSung <= 0.3
            return (ok, String(format: "(0,1) W/W(I) %.3f ∈ [0.9,1.1], Dr/Dr(A) %.3f ≤ 0.3",
                               cell.wobbleVsIdeal, cell.driftVsSung))
        case (1, 0):
            let ok = cell.wobbleVsSung <= 0.2 && !cell.inverted
            return (ok, String(format: "(1,0) W/W(A) %.3f ≤ 0.2, not inverted (real %.1f c, cosΔφ %+.2f)",
                               cell.wobbleVsSung, cell.wobbleRealCents, cell.phaseCosine))
        case (0.5, 0.5):
            let ok = (0.4...0.6).contains(cell.wobbleVsSung) && (0.4...0.6).contains(cell.driftVsSung)
            return (ok, String(format: "(0.5,0.5) W/W(A) %.3f, Dr/Dr(A) %.3f ∈ [0.4,0.6]",
                               cell.wobbleVsSung, cell.driftVsSung))
        default:
            return nil
        }
    }

    /// PREREG §7's separator-attributable legs: (0,1) both legs; (1,0) the
    /// NO-inversion leg only.
    static func separatorLegs(_ cell: Cell) -> Bool? {
        switch (cell.drift, cell.vibrato) {
        case (0, 1): return verdict(cell)?.passes
        case (1, 0): return !cell.inverted
        default: return nil
        }
    }

    /// PREREG §8: pass(T) for a short note's (0,1) cell.
    static func shortPasses(_ cell: Cell) -> Bool {
        (0.8...1.2).contains(cell.wobbleVsIdeal) && 1 - cell.driftVsSung >= 0.5
    }

    /// PREREG §8: the shortest tested T such that it AND every longer tested T pass.
    static func minimumSeparable(_ passes: [(seconds: Double, passes: Bool)]) -> Double? {
        let ordered = passes.sorted { $0.seconds < $1.seconds }
        guard let last = ordered.last, last.passes else { return nil }
        var answer = last.seconds
        for entry in ordered.reversed() {
            guard entry.passes else { break }
            answer = entry.seconds
        }
        return answer
    }

    /// PREREG §5: the negative-lobe plant. The v2 L = 0.25 s triangle at the
    /// 16 ms frame step (33 taps), −0.2046 added at ±11 frames, renormalised to
    /// unit DC: H(5.5 Hz) = −0.600 (kernel arithmetic, `kernels.py`).
    static let negativeLobeTaps: [Double] = {
        let m = 17
        var taps = (-(m - 1)...(m - 1)).map { Double(m - abs($0)) / Double(m * m) }
        let centre = m - 1
        taps[centre - 11] -= 0.2046
        taps[centre + 11] -= 0.2046
        let sum = taps.reduce(0, +)
        return taps.map { $0 / sum }
    }()
}

// MARK: - Rendering helpers

extension NaturalTuningDriftVibratoTests {
    /// A cache for `separator` rendering into `dir` (shared with the other
    /// separators: the contour sidecar is detected once, and a non-production
    /// separator's renders carry their own key field). No debounce: the gate
    /// renders once per cell and never supersedes itself.
    @MainActor
    static func cache(_ dir: URL, _ separator: Separator) -> StretchRenderCache {
        let cache = StretchRenderCache(directory: dir, contourDetector: .product,
                                       shapingSeparator: separator)
        cache.debounceMillisecondsForInstance = 0
        return cache
    }

    /// Renders every (separator, cell) job, one after another: each render
    /// runs detached inside the cache (the main actor only waits). Sequential
    /// on purpose: the machine is shared, and a task-group fan-out of
    /// main-actor closures trips the region-based isolation checker
    /// ("pattern … does not understand", Swift 6, W7-C3 install2 07:11).
    @MainActor
    static func renderAll(_ jobs: [(key: String, source: Source, drift: Double, vibrato: Double,
                                    cache: StretchRenderCache)]) async throws -> [String: (audio: [Float], url: URL)] {
        var out: [String: (audio: [Float], url: URL)] = [:]
        for job in jobs {
            if let result = try await render(job.source, drift: job.drift, vibrato: job.vibrato,
                                             cache: job.cache) {
                out[job.key] = result
            }
        }
        return out
    }

    /// PREREG §6: the tracker's known answer at 80 Hz, no render. The ideal
    /// as-sung tone at 80 Hz read against the same tone at 220 Hz.
    static func knownAnswerAt80Hz() -> (passes: Bool, wobbleRatio: Double, driftRatio: Double)? {
        let low = Fixture.long(80), high = Fixture.long(220)
        guard let a = read(low.audio(drift: 1, wobble: 1), low),
              let b = read(high.audio(drift: 1, wobble: 1), high) else { return nil }
        let w = a.wobble / b.wobble, d = a.drift / b.drift
        return ((0.9...1.1).contains(w) && (0.9...1.1).contains(d), w, d)
    }

}

extension NaturalTuningDriftVibratoTests {
    // MARK: - The asserted gate (normal suite)

    /// ⭐ **THE VERDICT IS FAIL → KEEP COUPLING** (W7-C3, 2026-09-27). These are
    /// the PREREG §4/§5 checks the one sweep (07:15 PDT) recorded as FAILING
    /// with the shipped kernel (L = 0.16 s, truncate). Each is still asserted
    /// with its pre-registered threshold, inside `withKnownIssue`: the suite
    /// stays usable, the failure stays visible in every run, and a check here
    /// that starts to PASS turns the test red ("known issue was not recorded"),
    /// which is the day to re-read the verdict. Renders are deterministic, so
    /// an entry passing is a real change (a renderer, detector or separator
    /// change), never noise.
    ///
    /// ⛔ NEVER add the gate's own validity here: the plant must fail, v1 must
    /// not pass (0,1) (> 1.10), and (1,1) must take the identity bypass.
    static let knownFailures: [String: String] = [
        "82 (1,0)": "production W/W(A) 0.443 > 0.2 (detector α_v 0.54 at 82 Hz)",
        "110 (1,0)": "production W/W(A) 0.211 > 0.2 (every kernel 0.211-0.237)",
        "220 (1,0)": "production W/W(A) 0.572 > 0.2 (RENDERER: the curve alone leaves 0.146)",
        "82 (0.5,0.5)": "production W/W(A) 0.713 outside [0.4, 0.6]",
        "220 (0.5,0.5)": "production W/W(A) 0.654 outside [0.4, 0.6] (RENDERER, as 220 Hz (1,0))",
        "220 v1 inverted": "v1 (1,0) remainder cosΔφ +0.06: the renderer's residual hides the inversion",
    ]

    /// One pre-registered check at `hz`: a plain `#expect`, or the same
    /// `#expect` inside `withKnownIssue` when `knownFailures` records it.
    static func expectPrereg(_ condition: Bool, hz: Double, check: String, _ message: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        if let reason = knownFailures["\(Int(hz)) \(check)"] {
            withKnownIssue("G3 PREREG FAIL, W7-C3 2026-09-27: \(reason)",
                           sourceLocation: sourceLocation) {
                #expect(condition, Comment(rawValue: message), sourceLocation: sourceLocation)
            }
        } else {
            #expect(condition, Comment(rawValue: message), sourceLocation: sourceLocation)
        }
    }

    @Test("§6 the tracker's known answer at 80 Hz (decides whether the 82 Hz cells are asserted)")
    func trackerKnownAnswerAt80Hz() throws {
        let answer = try #require(Self.knownAnswerAt80Hz(), "no reading of the ideal tones")
        Self.log(String(format: "80 Hz known answer: wobble %.3f, drift %.3f of the 220 Hz reading -> %@",
                        answer.wobbleRatio, answer.driftRatio,
                        (answer.passes ? "PASS (82 Hz asserted)" : "FAIL (82 Hz reported only)") as NSString))
        #expect(answer.wobbleRatio.isFinite && answer.driftRatio.isFinite)
    }

    /// PREREG §4 + §5 at one pitch: the production cells, the v1 negative
    /// control and the negative-lobe plant, through the shipping render path.
    /// §5 pre-registers the v1 control and the plant at 110 and 220 Hz only; at
    /// 82 Hz (asserted by §6 for §4's cells) they are logged, not asserted.
    ///
    /// ⚠️ The tightest plain assertion in this file is v1's (1,0) inversion at
    /// 110 Hz: a 6.6 c remainder at cosΔφ −0.12 (2026-09-27). A renderer or
    /// detector change that moves it will turn this red; that is the gate
    /// losing a leg of its negative control, not noise.
    @Test("§4-§5 the separator's cells through the product render, with the v1 control and the plant",
          arguments: [110.0, 220.0, 82.0])
    func separationCells(hz: Double) async throws {
        let asserted = hz != 82 || (Self.knownAnswerAt80Hz()?.passes ?? false)
        let dir = try ContourToRenderTests.tempDir("g3-\(Int(hz))")
        let fx = Fixture.long(hz)
        let source = try Self.source(fx, in: dir)
        if let reason = source.invalidReason {
            Self.log("\(fx): INVALID cell (\(reason))")
            if asserted { Issue.record("\(fx): the product detection did not give one note (\(reason))") }
            return
        }
        let production = await Self.cache(dir, .production)
        let v1 = await Self.cache(dir, .v1Everywhere)
        let plant = await Self.cache(dir, .kernelTaps(Self.negativeLobeTaps))
        var jobs: [(key: String, source: Source, drift: Double, vibrato: Double, cache: StretchRenderCache)] = []
        for (d, v) in [(0.0, 1.0), (1.0, 0.0), (0.5, 0.5), (0.0, 0.0), (1.0, 1.0)] {
            jobs.append(("production \(d)/\(v)", source, d, v, production))
        }
        for (d, v) in [(0.0, 1.0), (1.0, 0.0)] {
            jobs.append(("v1 \(d)/\(v)", source, d, v, v1))
            jobs.append(("plant \(d)/\(v)", source, d, v, plant))
        }
        let rendered = try await Self.renderAll(jobs)
        let memo = ReadingMemo()
        func cell(_ key: String, _ d: Double, _ v: Double, _ name: String) throws -> Cell {
            let audio = try #require(rendered[key]?.audio, "\(fx) \(key): no render")
            return try #require(Self.score(audio, source, drift: d, vibrato: v, separator: name, memo: memo),
                                "\(fx) \(key): unmeasurable")
        }

        // (1,1) is identity: the product hands back the SOURCE FILE, no render.
        #expect(rendered["production 1.0/1.0"]?.url.standardizedFileURL == source.url.standardizedFileURL,
                "(1,1) did not take the identity bypass")

        let p01 = try cell("production 0.0/1.0", 0, 1, "production")
        let p10 = try cell("production 1.0/0.0", 1, 0, "production")
        let p55 = try cell("production 0.5/0.5", 0.5, 0.5, "production")
        let p00 = try cell("production 0.0/0.0", 0, 0, "production")
        let v01 = try cell("v1 0.0/1.0", 0, 1, "v1")
        let v10 = try cell("v1 1.0/0.0", 1, 0, "v1")
        let x01 = try cell("plant 0.0/1.0", 0, 1, "plant")
        let x10 = try cell("plant 1.0/0.0", 1, 0, "plant")
        for c in [p01, p10, p55, p00, v01, v10, x01, x10] { Self.log(c.summary) }

        // PREREG §4: the asserted cells, literally.
        for (c, check) in [(p01, "(0,1)"), (p10, "(1,0)"), (p55, "(0.5,0.5)")] {
            guard let verdict = Self.verdict(c) else { continue }
            Self.log("\(fx) VERDICT \(verdict.passes ? "PASS" : "FAIL"): \(verdict.why)")
            if asserted {
                Self.expectPrereg(verdict.passes, hz: hz, check: check, "\(fx) production \(verdict.why)")
            }
        }
        // PREREG §5: the v1 negative control must FAIL, as specified.
        let v1Widening = v01.wobbleVsIdeal
        Self.log(String(format: "%@ v1 control: (0,1) W/W(I) %.3f (must be ≥ 1.15; ≤ 1.10 = blind), (1,0) inverted %@",
                        fx.description as NSString, v1Widening, (v10.inverted ? "YES" : "NO") as NSString))
        let controlsAsserted = hz == 110 || hz == 220
        if controlsAsserted {
            // Validity: never a known issue.
            #expect(v1Widening > 1.10, "\(fx) v1 PASSES (0,1): the gate is blind (\(v1Widening))")
            Self.expectPrereg(v1Widening >= 1.15, hz: hz, check: "v1 >= 1.15",
                              "\(fx) v1 (0,1) widening \(v1Widening) is weaker than the pre-registered 1.15")
            Self.expectPrereg(v10.inverted, hz: hz, check: "v1 inverted",
                              "\(fx) v1 (1,0) shows no inverted remainder (real \(v10.wobbleRealCents) c, cosΔφ \(v10.phaseCosine))")
        }
        // PREREG §5: the negative-lobe plant must FAIL. Validity: never a known issue.
        let plantFails = !(0.9...1.1).contains(x01.wobbleVsIdeal) || x10.inverted
        Self.log(String(format: "%@ plant: (0,1) W/W(I) %.3f, (1,0) inverted %@ -> %@",
                        fx.description as NSString, x01.wobbleVsIdeal, (x10.inverted ? "YES" : "NO") as NSString,
                        (plantFails ? "FAILS (as it must)" : "PASSES (the gate cannot see a negative lobe)") as NSString))
        if controlsAsserted { #expect(plantFails, "\(fx): the negative-lobe kernel passed G3") }
    }

    /// PREREG §8: the short-note ladder at 110 Hz with the shipped separator
    /// sets `PitchCorrectionCurve.minimumSeparableSeconds`.
    @Test("§8 minimumSeparableSeconds is the pre-registered short-note rule's answer")
    func shortNotesSetMinimumSeparableSeconds() async throws {
        let dir = try ContourToRenderTests.tempDir("g3-short")
        let production = await Self.cache(dir, .production)
        var ladder = Self.shortLadder
        var passes: [(seconds: Double, passes: Bool)] = []
        for extend in [false, true] {
            if extend {
                guard passes.first(where: { $0.seconds == 0.8 })?.passes == false else { break }
                ladder = Self.shortExtension
            }
            var sources: [Double: Source] = [:]
            var jobs: [(key: String, source: Source, drift: Double, vibrato: Double, cache: StretchRenderCache)] = []
            for seconds in ladder {
                let source = try Self.source(Fixture.short(110, seconds), in: dir)
                sources[seconds] = source
                if source.invalidReason == nil { jobs.append(("\(seconds)", source, 0, 1, production)) }
            }
            let rendered = try await Self.renderAll(jobs)
            for seconds in ladder {
                let source = try #require(sources[seconds])
                guard let audio = rendered["\(seconds)"]?.audio,
                      let cell = Self.score(audio, source, drift: 0, vibrato: 1, separator: "production")
                else {
                    Self.log("short \(seconds) s: \(source.invalidReason ?? "unmeasurable") -> fail")
                    passes.append((seconds, false))
                    continue
                }
                let ok = Self.shortPasses(cell)
                Self.log("short " + cell.summary + (ok ? "  PASS" : "  FAIL")
                         + String(format: "  (removed %.0f %% of the drift)", 100 * (1 - cell.driftVsSung)))
                passes.append((seconds, ok))
            }
        }
        let derived = Self.minimumSeparable(passes)
        Self.log("minimumSeparableSeconds by the rule: \(derived.map { "\($0)" } ?? "none") "
                 + "(constant: \(PitchCorrectionCurve.minimumSeparableSeconds))")
        #expect(derived == PitchCorrectionCurve.minimumSeparableSeconds,
                "the short-note rule now answers \(String(describing: derived)); re-derive the constant")
    }

    /// PREREG §9: the scoop cell. REPORTED; its (0,0) control decides only
    /// whether the (0,1) number may be quoted.
    ///
    /// ⚠️ **NOT QUOTABLE (W7-C3, 2026-09-27).** The pre-registered control is
    /// one-sided (kept(0,0) ≤ 0.2) and passed on kept(0,0) = −4.47, outside the
    /// metric's physical range: the area over [ts − 0.05, ts + 0.20] is
    /// dominated by estimates whose 85 ms tracker window reaches back before the
    /// onset, where the ideal reference is digital silence and a render is not.
    /// The POST-HOC line (window from ts + 0.043, half the tracker window, NOT
    /// pre-registered) is logged beside it to test that explanation.
    @Test("§9 the onset scoop through Drift (reported, with the (0,0) visibility control)")
    func scoopCell() async throws {
        let dir = try ContourToRenderTests.tempDir("g3-scoop")
        let fx = Fixture.scoop(110)
        let source = try Self.source(fx, in: dir)
        guard source.invalidReason == nil else {
            Self.log("scoop: INVALID (\(source.invalidReason ?? ""))")
            return
        }
        let production = await Self.cache(dir, .production)
        let rendered = try await Self.renderAll([("0/1", source, 0, 1, production),
                                                 ("0/0", source, 0, 0, production)])
        for (label, start) in [("PREREG §9 window [ts-0.050, ts+0.20]", -0.05),
                               ("POST-HOC window [ts+0.043, ts+0.20], not pre-registered", 0.043)] {
            let sung = try #require(Self.scoopArea(source.audio, fx.audio(drift: 1, wobble: 1, scoop: 0), fx,
                                                   from: start))
            func kept(_ key: String, wobble v: Double) -> Double? {
                guard let audio = rendered[key]?.audio,
                      let area = Self.scoopArea(audio, fx.audio(drift: 0, wobble: v, scoop: 0), fx, from: start)
                else { return nil }
                return area / sung
            }
            let drift0 = kept("0/1", wobble: 1)
            let flat = kept("0/0", wobble: 0)
            let control = (flat.map { $0 <= 0.2 }) ?? false
            Self.log(String(format: "scoop %@: as-sung area %.3f c·s; (0,1) keeps %@ of it; (0,0) keeps %@ -> one-sided control %@",
                            label as NSString, sung,
                            (drift0.map { String(format: "%.2f", $0) } ?? "nil") as NSString,
                            (flat.map { String(format: "%.2f", $0) } ?? "nil") as NSString,
                            (control ? "PASS" : "FAIL") as NSString))
            #expect(sung < 0, "\(label): the scoop fixture has no negative area as sung")
        }
    }
}

// MARK: - The sweep and the attribution legs (NT_DRIFT_SWEEP, PREREG §7-§10)

extension NaturalTuningDriftVibratoTests {
    /// PREREG §7's six kernels, in pick order (L ascending, truncate first).
    static let sweepKernels: [(name: String, window: Double, edge: PitchCorrectionMath.AverageEdge)] = [
        ("L0.16 truncate", 0.16, .truncate), ("L0.16 reflect", 0.16, .reflect),
        ("L0.20 truncate", 0.20, .truncate), ("L0.20 reflect", 0.20, .reflect),
        ("L0.25 truncate", 0.25, .truncate), ("L0.25 reflect", 0.25, .reflect),
    ]

    /// PREREG §10: the product detector's own reading of a fixture (frame
    /// centres, cents vs F), through the same fit as the tracker's.
    static func detectorReading(_ source: Source) -> Reading? {
        let d = source.detection
        var s = Series()
        for frame in d.frames {
            guard let f = frame.frequencyHz else { continue }
            s.t.append(frame.timeSeconds + 0.5 / d.frameRateHz)
            s.v.append(1200 * log2(f / source.fixture.hz))
        }
        return fit(s, source.fixture)
    }

    /// PREREG §10: `D + V + 100·curve(t)` at the tracker's estimate times on
    /// the source (`times`), no renderer.
    static func arithmeticReading(_ source: Source, times: [Double], drift d: Double, vibrato v: Double,
                                  separator: Separator) -> Reading? {
        guard let set = editSet(source, drift: d, vibrato: v) else { return nil }
        let fx = source.fixture
        let curve = PitchRenderContour.detected(source.detection)
            .curve(editSet: set, clipPitchShiftSemitones: 0, separator: separator)
        var s = Series()
        for t in times {
            s.t.append(t)
            s.v.append(fx.drift(t) + fx.wobble(t) + 100 * curve.semitones(atSourceSecond: t))
        }
        return fit(s, fx)
    }

    /// PREREG §10: the detection-aware ideal I′(d, v): the true pitch plus
    /// (d−1)·D_det + (v−1)·V_det, D_det/V_det the detected contour's fitted
    /// 0.5 Hz and 5.5 Hz sinusoids.
    static func detectionAwareIdeal(_ source: Source, _ detected: Reading,
                                    drift d: Double, vibrato v: Double) -> Reading? {
        let fx = source.fixture
        let wd = 2 * Double.pi * driftHz, wv = 2 * Double.pi * fx.wobbleHz
        let audio = fx.audio { t in
            let u = t - fx.ts
            return fx.drift(t) + fx.wobble(t)
                + (d - 1) * detected.drift * sin(wd * u + detected.driftPhase)
                + (v - 1) * detected.wobble * sin(wv * u + detected.phase)
        }
        return read(audio, fx)
    }

    static func f3(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "—" }

    @Test("§7-§10 the L × edge sweep, the short-note ladders, the scoop and the attribution legs",
          .enabled(if: sweepEnabled))
    func sweep() async throws {
        let dir = try ContourToRenderTests.tempDir("g3-sweep")
        var md: [String] = ["# G3 sweep (W7-C3), \(Date())", ""]
        func emit(_ line: String) { Self.log(line); md.append(line) }

        // Sources: the three pitches, B3 (the inversion instrument's control)
        // and the 4 Hz wobble at 220 Hz.
        let pitches = [82.0, 110.0, 220.0]
        var long: [Double: Source] = [:]
        for hz in pitches + [246.94] { long[hz] = try Self.source(.long(hz), in: dir) }
        let fourHz = try Self.source(.long(220, wobbleHz: 4.0), in: dir)
        for (hz, s) in long.sorted(by: { $0.key < $1.key }) {
            emit("source \(s.fixture): \(s.invalidReason ?? "valid, one run") (\(Int(hz)) Hz)")
        }
        emit("source \(fourHz.fixture): \(fourHz.invalidReason ?? "valid, one run")")

        // Caches: one per separator, one shared directory.
        var caches: [String: StretchRenderCache] = [
            "production": await Self.cache(dir, .production), "v1": await Self.cache(dir, .v1Everywhere),
            "plant": await Self.cache(dir, .kernelTaps(Self.negativeLobeTaps)),
        ]
        var separators: [String: Separator] = [
            "production": .production, "v1": .v1Everywhere, "plant": .kernelTaps(Self.negativeLobeTaps),
        ]
        for k in Self.sweepKernels {
            separators[k.name] = .triangular(windowSeconds: k.window, edge: k.edge)
            caches[k.name] = await Self.cache(dir, .triangular(windowSeconds: k.window, edge: k.edge))
        }
        let unequalNames = Self.sweepKernels.map { $0.name } + ["v1", "production", "plant"]

        // Render everything once.
        var jobs: [(key: String, source: Source, drift: Double, vibrato: Double, cache: StretchRenderCache)] = []
        for hz in pitches {
            guard let s = long[hz], s.invalidReason == nil else { continue }
            for (d, v) in [(0.5, 0.5), (0.0, 0.0), (1.0, 1.0)] {
                jobs.append(("\(hz) production \(d)/\(v)", s, d, v, caches["production"]!))
            }
            for name in unequalNames {
                for (d, v) in [(0.0, 1.0), (1.0, 0.0)] {
                    jobs.append(("\(hz) \(name) \(d)/\(v)", s, d, v, caches[name]!))
                }
            }
        }
        if let b3 = long[246.94], b3.invalidReason == nil {
            for name in ["v1", "production"] { jobs.append(("B3 \(name) 1.0/0.0", b3, 1, 0, caches[name]!)) }
        }
        if fourHz.invalidReason == nil {
            for name in unequalNames { jobs.append(("4Hz \(name) 0.0/1.0", fourHz, 0, 1, caches[name]!)) }
        }
        let known = Self.knownAnswerAt80Hz()
        emit(String(format: "PREREG §6 80 Hz known answer: wobble %@, drift %@ of the 220 Hz reading -> %@",
                    Self.f3(known?.wobbleRatio) as NSString, Self.f3(known?.driftRatio) as NSString,
                    ((known?.passes ?? false) ? "PASS (82 Hz cells ASSERTED)" : "FAIL (82 Hz cells REPORTED only)") as NSString))
        emit("rendering \(jobs.count) cells through StretchRenderCache.renderIfNeeded ...")
        let clock = ContinuousClock()
        let renderStart = clock.now
        let rendered = try await Self.renderAll(jobs)
        emit("rendered \(rendered.count) of \(jobs.count) in \(clock.now - renderStart) (elapsed, unasserted)")

        let memo = ReadingMemo()
        func scored(_ key: String, _ source: Source, _ d: Double, _ v: Double, _ name: String) -> Cell? {
            guard let audio = rendered[key]?.audio else { return nil }
            return Self.score(audio, source, drift: d, vibrato: v, separator: name, memo: memo)
        }

        // PREREG §10: α, the floors.
        emit("")
        emit("## Detector and floors (REPORTED)")
        var detected: [Double: Reading] = [:]
        for hz in pitches + [246.94] {
            guard let s = long[hz], s.invalidReason == nil, let r = Self.detectorReading(s) else { continue }
            detected[hz] = r
            let stretch0 = try? ContourToRenderTests.uncorrected(s.audio)
            let floor = stretch0.flatMap { Self.score($0, s, drift: 1, vibrato: 1, separator: "stretch@0", memo: memo) }
            emit(String(format: "%@: detector α_v %.3f α_d %.3f (wobble lag %+.1f ms) | stretcher@0 W/W(A) %@ Dr/Dr(A) %@",
                        s.fixture.description as NSString, r.wobble / Self.wobbleCents, r.drift / Self.driftCents,
                        (r.phase / (2 * .pi * Self.wobbleHz)) * -1000,
                        Self.f3(floor?.wobbleVsSung) as NSString, Self.f3(floor?.driftVsSung) as NSString))
        }

        // The equal-scale cells (kernel-independent).
        emit("")
        emit("## Equal-scale cells (production, never reach the separator)")
        var equalPass: [Double: Bool] = [:]
        for hz in pitches {
            guard let s = long[hz], s.invalidReason == nil else { continue }
            for (d, v) in [(0.5, 0.5), (0.0, 0.0)] {
                guard let c = scored("\(hz) production \(d)/\(v)", s, d, v, "production") else {
                    emit("\(s.fixture) (\(d),\(v)): no reading")
                    continue
                }
                let verdict = Self.verdict(c)
                if d == 0.5 { equalPass[hz] = verdict?.passes ?? false }
                emit(c.summary + (verdict.map { "  -> \($0.passes ? "PASS" : "FAIL")" } ?? "  (reported)"))
            }
            let identity = rendered["\(hz) production 1.0/1.0"]?.url.standardizedFileURL
                == s.url.standardizedFileURL
            emit("\(s.fixture) (1,1): identity bypass \(identity ? "YES" : "NO")")
        }

        // The table: per kernel, per pitch, (0,1) and (1,0), render + arithmetic + I′.
        emit("")
        emit("## Sweep table: (0,1) and (1,0) per separator and pitch")
        emit("| separator | Hz | (0,1) W/W(I) | (0,1) Dr/Dr(A) | (1,0) W/W(A) | (1,0) real c | (1,0) cosΔφ | cells | sep legs | arith (0,1) W/40 | arith (1,0) W/40 | (0,1) W/W(I′) | (1,0) W/W(I′) |")
        emit("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        var passAll110: [String: Bool] = [:]
        var legs110: [String: Bool] = [:]
        for name in unequalNames {
            for hz in pitches {
                guard let s = long[hz], s.invalidReason == nil,
                      let c01 = scored("\(hz) \(name) 0.0/1.0", s, 0, 1, name),
                      let c10 = scored("\(hz) \(name) 1.0/0.0", s, 1, 0, name) else {
                    emit("| \(name) | \(Int(hz)) | no reading | | | | | | | | | | |")
                    continue
                }
                let cellsPass = (Self.verdict(c01)?.passes ?? false) && (Self.verdict(c10)?.passes ?? false)
                    && (equalPass[hz] ?? false)
                let legs = (Self.separatorLegs(c01) ?? false) && (Self.separatorLegs(c10) ?? false)
                if hz == 110 { passAll110[name] = cellsPass; legs110[name] = legs }
                let times = Self.track(s.audio, s.fixture, within: s.fixture.ts...s.fixture.te).t
                let a01 = Self.arithmeticReading(s, times: times, drift: 0, vibrato: 1, separator: separators[name]!)
                let a10 = Self.arithmeticReading(s, times: times, drift: 1, vibrato: 0, separator: separators[name]!)
                let i01 = detected[hz].flatMap { Self.detectionAwareIdeal(s, $0, drift: 0, vibrato: 1) }
                let i10 = detected[hz].flatMap { Self.detectionAwareIdeal(s, $0, drift: 1, vibrato: 0) }
                var row: [String] = [name, "\(Int(hz))"]
                row.append(Self.f3(c01.wobbleVsIdeal))
                row.append(Self.f3(c01.driftVsSung))
                row.append(Self.f3(c10.wobbleVsSung))
                row.append(String(format: "%.1f", c10.wobbleRealCents))
                row.append(String(format: "%+.2f", c10.phaseCosine))
                row.append(cellsPass ? "PASS" : "FAIL")
                row.append(legs ? "pass" : "fail")
                row.append(Self.f3(a01.map { $0.wobble / Self.wobbleCents }))
                row.append(Self.f3(a10.map { $0.wobble / Self.wobbleCents }))
                row.append(Self.f3(i01.map { c01.delivered.wobble / $0.wobble }))
                row.append(Self.f3(i10.map { c10.delivered.wobble / $0.wobble }))
                emit("| " + row.joined(separator: " | ") + " |")
            }
        }

        // PREREG §7: the pick.
        emit("")
        emit("## The pick (PREREG §7)")
        func pick(_ table: [String: Bool]) -> (name: String, window: Double, edge: PitchCorrectionMath.AverageEdge)? {
            for window in [0.16, 0.20, 0.25] {
                for edge in [PitchCorrectionMath.AverageEdge.truncate, .reflect] {
                    let name = String(format: "L%.2f ", window) + edge.rawValue
                    if table[name] == true { return (name, window, edge) }
                }
            }
            return nil
        }
        let primary = pick(passAll110)
        let fallback = pick(legs110)
        let picked = primary ?? fallback
        emit("primary rule (every asserted cell at 110 Hz): \(primary?.name ?? "NO L PASSES")")
        emit("fallback rule (separator legs at 110 Hz): \(fallback?.name ?? "none")")
        emit("PICKED: \(picked.map { $0.name + (primary == nil ? " (FALLBACK)" : "") } ?? "none")")

        // PREREG §8: the short-note ladder per kernel at 110 Hz, and at 220 Hz for the pick.
        emit("")
        emit("## Short notes (PREREG §8): (0,1) per length; pass = W/W(I) ∈ [0.8,1.2] and ≥ 50 % of the drift removed")
        // Each short source is written and detected ONCE, then shared by every
        // ladder (a rewrite would change its mtime, re-key it and re-detect it).
        var shortSources: [String: Source] = [:]
        func shortSource(_ hz: Double, _ seconds: Double) throws -> Source {
            let key = "\(hz)-\(seconds)"
            if let existing = shortSources[key] { return existing }
            let made = try Self.source(.short(hz, seconds), in: dir)
            shortSources[key] = made
            return made
        }
        var ladders: [(label: String, hz: Double, name: String)] = []
        for kernel in Self.sweepKernels { ladders.append(("110 Hz " + kernel.name, 110.0, kernel.name)) }
        ladders.append(("110 Hz v1", 110.0, "v1"))
        if let picked { ladders.append(("220 Hz \(picked.name) (picked)", 220, picked.name)) }
        for ladder in ladders {
            var passes: [(seconds: Double, passes: Bool)] = []
            var cellsText: [String] = []
            for lengths in [Self.shortLadder, Self.shortExtension] {
                if lengths == Self.shortExtension,
                   passes.first(where: { $0.seconds == 0.8 })?.passes != false { break }
                var sources: [Double: Source] = [:]
                var shortJobs: [(key: String, source: Source, drift: Double, vibrato: Double, cache: StretchRenderCache)] = []
                for seconds in lengths {
                    let s = try shortSource(ladder.hz, seconds)
                    sources[seconds] = s
                    if s.invalidReason == nil { shortJobs.append(("\(seconds)", s, 0, 1, caches[ladder.name]!)) }
                }
                let out = try await Self.renderAll(shortJobs)
                for seconds in lengths {
                    guard let s = sources[seconds], let audio = out["\(seconds)"]?.audio,
                          let c = Self.score(audio, s, drift: 0, vibrato: 1, separator: ladder.name,
                                             memo: memo) else {
                        passes.append((seconds, false))
                        cellsText.append("\(seconds)s: \(sources[seconds]?.invalidReason ?? "unmeasurable")")
                        continue
                    }
                    let ok = Self.shortPasses(c)
                    passes.append((seconds, ok))
                    cellsText.append(String(format: "%.1fs W/W(I) %.2f removed %.0f%% %@", seconds, c.wobbleVsIdeal,
                                            100 * (1 - c.driftVsSung), (ok ? "PASS" : "fail") as NSString))
                }
            }
            emit("\(ladder.label): minimumSeparableSeconds = \(Self.minimumSeparable(passes).map { "\($0)" } ?? "none") | "
                 + cellsText.joined(separator: " | "))
        }

        // PREREG §9: the scoop per separator.
        emit("")
        emit("## Scoop (PREREG §9, REPORTED)")
        let scoop = try Self.source(.scoop(110), in: dir)
        if scoop.invalidReason == nil {
            var scoopJobs: [(key: String, source: Source, drift: Double, vibrato: Double, cache: StretchRenderCache)] =
                [("0/0", scoop, 0, 0, caches["production"]!)]
            for name in unequalNames { scoopJobs.append((name, scoop, 0, 1, caches[name]!)) }
            let out = try await Self.renderAll(scoopJobs)
            let fx = scoop.fixture
            if let sung = Self.scoopArea(scoop.audio, fx.audio(drift: 1, wobble: 1, scoop: 0), fx) {
                let flat = out["0/0"].flatMap { Self.scoopArea($0.audio, fx.audio(drift: 0, wobble: 0, scoop: 0), fx) }
                emit(String(format: "as-sung area %.3f c·s; (0,0) keeps %@ -> control %@", sung,
                            Self.f3(flat.map { $0 / sung }) as NSString,
                            ((flat.map { $0 / sung <= 0.2 } ?? false) ? "PASS" : "FAIL") as NSString))
                for name in unequalNames {
                    let kept = out[name].flatMap { Self.scoopArea($0.audio, fx.audio(drift: 0, wobble: 1, scoop: 0), fx) }
                    emit("(0,1) \(name): keeps \(Self.f3(kept.map { $0 / sung })) of the scoop's area")
                }
            }
        } else {
            emit("scoop source INVALID: \(scoop.invalidReason ?? "")")
        }

        // PREREG §10: B3 and the 4 Hz wobble.
        emit("")
        emit("## Inversion instrument control at B3, and the 4 Hz wobble at 220 Hz (REPORTED)")
        if let b3 = long[246.94], b3.invalidReason == nil {
            for name in ["v1", "production"] {
                if let c = scored("B3 \(name) 1.0/0.0", b3, 1, 0, name) { emit(c.summary) }
            }
        }
        if fourHz.invalidReason == nil {
            for name in unequalNames {
                if let c = scored("4Hz \(name) 0.0/1.0", fourHz, 0, 1, name) { emit(c.summary) }
            }
        }

        emit("sweep total \(clock.now - renderStart) after the first render (elapsed, unasserted)")
        if let out = Self.outputDirectory {
            let url = URL(fileURLWithPath: out).appendingPathComponent("g3-sweep.md")
            try md.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            Self.log("wrote \(url.path)")
        }
        #expect(!rendered.isEmpty, "the sweep rendered nothing")
    }
}
