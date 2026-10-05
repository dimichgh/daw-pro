import AVFAudio
import CryptoKit
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// C5a-L — "how quickly should a new wobble build up?" (design
/// `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §16 C5a-L, which
/// replaces §9.5's provisional onset). Four renders of ONE note of a real dry
/// vocal, through the PRODUCT render path (`StretchRenderCache.renderIfNeeded`,
/// contour fetched or detected inside the job). The note's own wobble is
/// flattened — `vibratoScale: 0` AND `driftScale: 0`, §5.3, because the
/// vibrato scale alone keeps an inverted 17–22 % — and a new one is added at
/// 5.5 per second and ±40 c, with onsets 0 / 0.15 / 0.3 / 0.6 s. ONE axis:
/// the listener's pick is the feedback. Every other note stays untouched; no
/// clip stretch (ratio 1).
///
/// Env-gated, because the recording is the user's and not in the tree:
///
///     WOBBLE_ONSET_SOURCE=/path/dry.wav WOBBLE_ONSET_OUT=/path/outdir \
///     WOBBLE_ONSET_NOTE_AT=18.1 WOBBLE_ONSET_EXCERPT=15.95,19.75 \
///       ./scripts/test.sh --filter WobbleOnsetListeningTests
///
/// `WOBBLE_ONSET_NOTE_AT` is a source second INSIDE the chosen note; the note
/// itself comes from a fresh product detection (`PitchNoteTable.detected`), so
/// ids and boundaries are the product's, not a survey's.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// ⛔ THE INSTRUMENT: THE PRODUCT DETECTOR CANNOT READ THIS WOBBLE AT THIS PITCH
/// ═══════════════════════════════════════════════════════════════════════════
///
/// §16 asks for the guard "in each render's f0". The product's detector
/// (SwiftF0) was put to its own control first — `productDetectorReadsAKnownWobble`
/// hands it a tone carrying EXACTLY ±40 c at 5.5 per second, no render in the
/// path — and it reads ±16.7 c at 83 Hz (lopsided, −4.5..+29.3 c), ±26.9 at
/// 110, ±32.4 at 147 and ±35.9 at 220 (8 partials at 1/k); ±20.9 / 31.5 /
/// 34.0 / 34.0 for a voice-like spectrum (weak fundamental); ±5.5 for a pure
/// sine at 83 Hz, and a pure sine at 110 Hz or above is not voiced at all
/// (2026-09-24, `instrument/instrument.json`). This take's notes are all
/// 72–145 Hz. A guard on SwiftF0 here would measure the detector's
/// distortion, not the render. SwiftF0's readings are still computed and
/// RECORDED; no claim stands on them.
///
/// The guard's instrument is `M23QToneTracker` (the phase-vocoder tracker
/// `NoteVibratoGeneratorTests` §C measured the chain with) on the note's
/// fundamental band, at a 4096-sample window and a 480-sample phase hop. The
/// configuration was chosen by MEASUREMENT (`trackerConfigurationSweep`): at
/// the 2048 / 32 the §C tests use, a voice-like spectrum (fundamental weaker
/// than its second partial) leaks into the fundamental's bin and the reading
/// jitters ±20 c on a steady tone and ±24 c on the flat voice render — noise
/// that also INFLATED the voice's apparent depth. At 4096 / 480 the jitter is
/// 0.5 c on the tone and 3.4 c on the voice. The price is attenuation: the
/// 85 ms window reads an exact ±40 c at ±34.5 c. So nothing is compared with
/// the raw curve. "What was asked" is the SAME tracker reading an IDEAL tone
/// whose pitch follows the product's own curve exactly (`IdealReading`): the
/// instrument's attenuation and smoothing sit on both sides of every
/// comparison, and depth is quoted as delivered ÷ ideal × 40.
///
/// ═══════════════════════════════════════════════════════════════════════════
/// THE GUARD, AND WHY IT IS NOT THE DESIGN'S LITERAL WORDING
/// ═══════════════════════════════════════════════════════════════════════════
///
/// §16 says "the wobble reaches 90 % of its final depth at the asked onset,
/// within one hop". The generator's fade is `smoothstep((t − start) / onset)`,
/// which reaches 0.9 at 0.8045 × onset — for 0.6 s that is 0.48 s, FOUR hops
/// before "the asked onset". Read literally, the guard fails a correct product;
/// read one-sidedly ("≥ 90 % by the onset") it passes a render whose real onset
/// is 0, i.e. it cannot fail the plant. So the guard here is TWO-SIDED and is
/// taken against the product's OWN curve: the same reader runs on (a) the
/// ideal reading of the ask and (b) the reading of the render, and the two
/// 90 % crossings must agree within one hop (30 ms) in both directions.
/// "Final depth" is each side's ONSET-0 plateau, shared by all four options
/// (the 0.6 s option has no plateau of its own on a short note).
///
/// ONE HOP IS MET ON A CLEAN NOTE, NOT ON THIS VOICE. The synthetic control
/// (a voice-like tone at the chosen note's pitch and times, through the same
/// product path) gates all four options at one hop, on every run. On the
/// real voice two things stop a one-hop reading, both MEASURED, neither a
/// chain defect: the note's attack (`voiceAttackDeadZoneSeconds`) and the
/// voice's swing-to-swing depth scatter, which the smoothstep's slope turns
/// into crossing error (`smoothstepSlopeAt90`). So on the voice an option
/// whose 90 % point lies inside the attack is RECORDED, and every other one
/// is gated two-sided at one hop plus that derived error (`voiceVerdicts`).
/// The one-hop outcome is still logged per option, so the relaxation is
/// visible, never silent.
///
/// THE READER. The generator's phase is `sin(2π · rate · t)` with `t` in
/// absolute SOURCE seconds (no phase-anchor field exists yet — C5a-1), so the
/// carrier is known at every estimate. Each variant's pitch minus the pitch of
/// a FIFTH render (the same note flattened, no generator) isolates the
/// generator's delivered contribution: the flatten, and the singer's leftover
/// movement, are identical in both and cancel. A Hann-weighted fixed-phase
/// least-squares fit with a local offset, over one wobble period, gives the
/// envelope.
///
/// `WOBBLE_ONSET_PLANT=1` renders all four at onset 0 (labels unchanged): the
/// renders must come out byte-identical AND the voice guard must go red on 03
/// and 04 (02's 90 % point lies in the attack, so it is recorded there). The
/// synthetic control runs the same negative control on every run and must
/// flag exactly 02–04.
///
/// Loudness, true peak and MP3 encoding happen outside, on the excerpts
/// written; `remeasureTheWrittenMP3s` then reads the decoded MP3s back.
@Suite("C5a-L — wobble onset listening renders (env-gated)", .serialized)
struct WobbleOnsetListeningTests {
    static func log(_ message: String) { print("wobble-onset| \(message)") }

    static let enabled = ProcessInfo.processInfo.environment["WOBBLE_ONSET_SOURCE"] != nil
        && ProcessInfo.processInfo.environment["WOBBLE_ONSET_OUT"] != nil
        && ProcessInfo.processInfo.environment["WOBBLE_ONSET_NOTE_AT"] != nil
    static let decodedEnabled = ProcessInfo.processInfo.environment["WOBBLE_ONSET_OUT"] != nil
        && ProcessInfo.processInfo.environment["WOBBLE_ONSET_DECODED"] != nil
    static let instrumentEnabled = ProcessInfo.processInfo.environment["WOBBLE_ONSET_OUT"] != nil
    static let planted = ProcessInfo.processInfo.environment["WOBBLE_ONSET_PLANT"] == "1"

    static let rateHz = 5.5
    static let depthCents = 40.0
    /// One render hop: `css_interval_samples` = 1440 frames at 48 kHz
    /// (`NoteVibratoGeneratorTests.hopIsMeasured`). THE guard's tolerance.
    static let hopSeconds = 1440.0 / 48_000.0
    /// `smoothstep(x) = 0.9` ⇒ x = 0.80449…: where the product's fade reaches
    /// 90 %, as a fraction of the onset. Reported beside the reader's figures.
    static let smoothstep90 = 0.804_489

    /// The guard's tracker: see the banner for why these two numbers.
    static let trackerWindow = 4096
    static let trackerPhaseHop = 480
    /// One estimate every 5 ms.
    static let trackerHop = 240
    static var trackerRate: Double { 48_000.0 / Double(trackerHop) }
    /// How far outside a curve change a per-estimate pitch difference may
    /// still show: one hop for the render's landing, plus half the tracker's
    /// span (window + phase hop), plus a margin. A bound on WHERE, stated
    /// rather than tuned.
    static let locationSlackSeconds = hopSeconds
        + Double(trackerWindow + trackerPhaseHop) / 2 / 48_000 + 0.008
    /// A pitch difference counts as "different" from this many cents (in the
    /// tracker's units, where the full wobble reads ~27–35 c).
    static let locationThresholdCents = 8.0
    /// A voice-like spectrum: the fundamental WEAKER than its second partial,
    /// which is the case that defeats a short tracker window.
    static let voiceLikePartials = [0.35, 1.0, 0.8, 0.6, 0.45, 0.35, 0.25, 0.15]

    static let options: [(onset: Double, name: String)] = [
        (0.0, "01-at-once"), (0.15, "02-quick-build"),
        (0.3, "03-medium-build"), (0.6, "04-slow-build"),
    ]

    /// ⛔ **THE VOICE NOTE'S ATTACK IS A MEASUREMENT DEAD ZONE.** The note
    /// opens on a 159 c scoop that the flatten pulls down over its first
    /// 0.24 s. There, the at-once render's variant − flat difference reads its
    /// first two swings (0.024 s and 0.115 s after the start) at 175 % / 176 %
    /// of full width against 98 / 100 asked, and the excess scales with the
    /// generator (the slow-build render, with almost no generator there, shows
    /// none), so it does not cancel between variants either. From 0.205 s the
    /// swings read 88–109 % (2026-09-24). SwiftF0 does not show the excess, so
    /// its attribution — the phase vocoder's non-additivity under a large, fast
    /// correction, or the tracker's attack bias — is UNRESOLVED; either way no
    /// 90 % crossing inside this zone can be read on this note. Options whose
    /// crossing falls here are recorded, and the synthetic control (no scoop)
    /// gates them at one hop.
    static let voiceAttackDeadZoneSeconds = 0.15
    /// Where the smoothstep is 0.9 its slope is 6x(1 − x) = 0.9437 per unit x,
    /// i.e. 0.9437 / onset per second: a depth scatter δ (a fraction of full
    /// width) moves a 90 % crossing by δ · onset / 0.9437. At onset 0.6 a ±10 %
    /// scatter is ±64 ms — no reader of a 90 % crossing meets one hop on a
    /// voice whose swings scatter that much, which is arithmetic, not a defect.
    static let smoothstepSlopeAt90 = 0.943_7

    struct Verdict {
        let name: String
        let gated: Bool
        let tolerance: Double?
        let passes: Bool
        let why: String
    }

    /// The VOICE's per-option guard. An option whose predicted crossing lies
    /// inside the attack dead zone is recorded, not gated. Every other option
    /// is gated TWO-SIDED at one hop plus the crossing error its depth scatter
    /// implies, the scatter measured on the at-once render's swings after the
    /// dead zone and capped at 20 % so the gate cannot dissolve. The planted
    /// 03/04 (measured ≈ 0.01 s against 0.26/0.48) fail it by a wide margin.
    static func voiceVerdicts(_ m: Measurement) -> (scatter: Double, verdicts: [Verdict]) {
        let s = m.note.start
        let zero = m.readings[0]
        let late = zero.swingTimes.indices.filter { zero.swingTimes[$0] >= s + voiceAttackDeadZoneSeconds }
        let scatter = min(0.2, late.compactMap { zero.swingsMeasured[$0] }.map { abs($0 - 1) }.max() ?? 0.2)
        let verdicts = m.readings.map { r -> Verdict in
            guard let predicted = r.crossingPredicted, predicted >= voiceAttackDeadZoneSeconds else {
                return Verdict(
                    name: r.name, gated: false, tolerance: nil, passes: r.passes,
                    why: "its 90 % point lies inside this note's attack dead zone: recorded, not gated (the synthetic control gates it at one hop)")
            }
            let tolerance = hopSeconds + scatter * r.onsetAsked / smoothstepSlopeAt90
            let ok = r.crossingMeasured.map { abs($0 - predicted) <= tolerance } ?? false
            return Verdict(
                name: r.name, gated: true, tolerance: tolerance, passes: ok,
                why: String(format: "gated at one hop + %.0f %% depth scatter x %.2f s / %.4f = %.3f s",
                            scatter * 100, r.onsetAsked, smoothstepSlopeAt90, tolerance))
        }
        return (scatter, verdicts)
    }

    static func logVerdicts(_ tag: String, _ m: Measurement,
                            _ result: (scatter: Double, verdicts: [Verdict])) {
        for (r, v) in zip(m.readings, result.verdicts) {
            log(String(format: "%@ GUARD %@: measured %@ s vs predicted %@ s (difference %@ ms) — %@ — %@",
                       tag as NSString, r.name as NSString, fmt(r.crossingMeasured) as NSString,
                       fmt(r.crossingPredicted) as NSString,
                       fmt(r.crossingMeasured.flatMap { a in r.crossingPredicted.map { (a - $0) * 1000 } },
                           "%+.0f") as NSString,
                       (v.gated ? (v.passes ? "PASS" : "FAIL") : (r.passes ? "within one hop" : "outside one hop"))
                           as NSString, v.why as NSString))
        }
    }

    static func verdictRecord(_ result: (scatter: Double, verdicts: [Verdict])) -> [String: Any] {
        [
            "depthScatter": result.scatter,
            "deadZoneSeconds": voiceAttackDeadZoneSeconds,
            "verdicts": result.verdicts.map {
                ["name": $0.name, "gated": $0.gated, "tolerance": json($0.tolerance),
                 "passes": $0.passes, "why": $0.why] as [String: Any]
            },
        ]
    }

    struct MeasurementError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - The note under test

    /// The chosen note and the edit sets built on it. `table` is the product's
    /// detected note table; every variant changes ONE segment of it.
    struct Note {
        let index: Int
        let table: PitchEditSet
        var segment: NoteSegment { table.segments[index] }
        var start: Double { segment.startSeconds }
        var end: Double { segment.endSeconds }
        /// Where a pitch reading of this note is taken.
        var interior: ClosedRange<Double> { (start + 0.021)...(end - 0.021) }

        /// The chosen note with both scales at 0 and, when `onset` is non-nil,
        /// the generator at 5.5 per second ±40 c with that onset. Built
        /// through `NoteSegment`'s healing `init`, same id, every other field
        /// carried.
        func set(onset: Double?) -> PitchEditSet {
            var segments = table.segments
            let old = segments[index]
            segments[index] = NoteSegment(
                id: old.id, startSeconds: old.startSeconds, endSeconds: old.endSeconds,
                detectedHz: old.detectedHz, detectedConfidence: old.detectedConfidence,
                pitchOffsetCents: old.pitchOffsetCents,
                driftScale: 0, vibratoScale: 0,
                vibratoRateHz: onset == nil ? 0 : WobbleOnsetListeningTests.rateHz,
                vibratoDepthCents: onset == nil ? 0 : WobbleOnsetListeningTests.depthCents,
                vibratoOnsetSeconds: onset ?? 0,
                formantOffsetSemitones: old.formantOffsetSemitones,
                timeStartDeltaSeconds: old.timeStartDeltaSeconds,
                timeEndDeltaSeconds: old.timeEndDeltaSeconds,
                amplitudeDb: old.amplitudeDb)
            return PitchEditSet(analysisVersion: table.analysisVersion,
                                segments: segments, retuneMs: table.retuneMs)
        }

        /// The product's own curve for a variant. No contour is passed, so the
        /// flatten resolves to nothing in BOTH curves of a difference and the
        /// difference is exactly the gated generator term.
        func curve(onset: Double?) -> PitchCorrectionCurve {
            PitchCorrectionCurve.make(editSet: set(onset: onset))
        }
    }

    // MARK: - The reader

    enum Reader {
        struct Series {
            var t: [Double] = []
            var v: [Double] = []
        }

        static let omega = 2 * Double.pi * WobbleOnsetListeningTests.rateHz
        /// The Hann window spans ONE wobble period.
        static let halfWidth = 0.5 / WobbleOnsetListeningTests.rateHz

        /// SwiftF0 `a − b` in cents on frame CENTRES where both are voiced,
        /// `shift` added to the frame times (an excerpt's start, in source
        /// seconds).
        static func difference(_ a: PitchDetectionResult, minus b: PitchDetectionResult,
                               within window: ClosedRange<Double>,
                               shift: Double = 0) -> Series {
            var s = Series()
            let half = 0.5 / a.frameRateHz
            for (x, y) in zip(a.frames, b.frames) {
                guard let fx = x.frequencyHz, let fy = y.frequencyHz else { continue }
                let t = x.timeSeconds + half + shift
                guard window.contains(t) else { continue }
                s.t.append(t)
                s.v.append(1200 * log2(fx / fy))
            }
            return s
        }

        /// SwiftF0 cents relative to `hz` on voiced frame centres.
        static func relative(_ a: PitchDetectionResult, toHz hz: Double,
                             within window: ClosedRange<Double>, shift: Double = 0) -> Series {
            var s = Series()
            let half = 0.5 / a.frameRateHz
            for x in a.frames {
                guard let fx = x.frequencyHz else { continue }
                let t = x.timeSeconds + half + shift
                guard window.contains(t) else { continue }
                s.t.append(t)
                s.v.append(1200 * log2(fx / hz))
            }
            return s
        }

        /// `M23QToneTracker` cents relative to `hz`, on the fundamental's band,
        /// estimates timestamped at their CENTRE. Sample `n` of `samples` is
        /// source second `n / sampleRate + shift`.
        static func tracked(_ samples: [Float], sampleRate: Double, hz: Double,
                            within window: ClosedRange<Double>, shift: Double = 0,
                            windowSize: Int = WobbleOnsetListeningTests.trackerWindow,
                            phaseHop: Int = WobbleOnsetListeningTests.trackerPhaseHop) -> Series {
            let pad = Double(windowSize + phaseHop) / sampleRate
            let lo = max(0, Int(((window.lowerBound - shift) - pad) * sampleRate))
            let hi = min(samples.count, Int(((window.upperBound - shift) + pad) * sampleRate))
            guard hi > lo else { return Series() }
            var s = Series()
            for estimate in M23QToneTracker.track(
                Array(samples[lo..<hi]), sampleRate: sampleRate,
                windowSize: windowSize, phaseHop: phaseHop,
                estimateHop: WobbleOnsetListeningTests.trackerHop,
                band: (hz * 0.7)...(hz * 1.3)) {
                let t = (Double(lo) + estimate.centreFrame) / sampleRate + shift
                guard window.contains(t) else { continue }
                s.t.append(t)
                s.v.append(M23QToneTracker.cents(estimate.hz, above: hz))
            }
            return s
        }

        /// `a − b` at the times both carry (matched to 0.01 ms).
        static func subtract(_ a: Series, _ b: Series) -> Series {
            var lookup: [Int: Double] = [:]
            for (t, v) in zip(b.t, b.v) { lookup[Int((t * 100_000).rounded())] = v }
            var s = Series()
            for (t, v) in zip(a.t, a.v) {
                guard let w = lookup[Int((t * 100_000).rounded())] else { continue }
                s.t.append(t)
                s.v.append(v - w)
            }
            return s
        }

        /// Linear interpolation of `s` at `times` (held at both ends).
        static func interpolate(_ s: Series, at times: [Double]) -> Series {
            guard let first = s.t.first, let last = s.t.last else { return Series() }
            var out = Series()
            var j = 0
            for t in times {
                out.t.append(t)
                if t <= first { out.v.append(s.v[0]); continue }
                if t >= last { out.v.append(s.v[s.v.count - 1]); continue }
                while j + 1 < s.t.count, s.t[j + 1] < t { j += 1 }
                while j > 0, s.t[j] > t { j -= 1 }
                let f = (t - s.t[j]) / (s.t[j + 1] - s.t[j])
                out.v.append(s.v[j] * (1 - f) + s.v[j + 1] * f)
            }
            return out
        }

        /// The generator term of the product's curve, cents, at `times`.
        static func curveTerm(_ note: Note, onset: Double, at times: [Double]) -> Series {
            let variant = note.curve(onset: onset)
            let base = note.curve(onset: nil)
            return Series(t: times, v: times.map {
                100 * (variant.semitones(atSourceSecond: $0) - base.semitones(atSourceSecond: $0))
            })
        }

        struct Fit {
            let amplitude: Double
            /// The carrier's lag behind `sin(2π·rate·t)`, seconds.
            let delaySeconds: Double
            let offset: Double
            let residualRMS: Double
            let count: Int
        }

        /// Least squares `v ≈ a·sin ωt + b·cos ωt + c` over `window`.
        static func fitSinusoid(_ s: Series, over window: ClosedRange<Double>) -> Fit? {
            var m = [[Double]](repeating: [0, 0, 0], count: 3)
            var r = [0.0, 0.0, 0.0]
            var n = 0
            for (t, v) in zip(s.t, s.v) where window.contains(t) {
                let basis = [sin(omega * t), cos(omega * t), 1.0]
                for i in 0..<3 {
                    r[i] += basis[i] * v
                    for j in 0..<3 { m[i][j] += basis[i] * basis[j] }
                }
                n += 1
            }
            guard n >= 6, let x = solve3(m, r) else { return nil }
            var sse = 0.0
            for (t, v) in zip(s.t, s.v) where window.contains(t) {
                let e = v - (x[0] * sin(omega * t) + x[1] * cos(omega * t) + x[2])
                sse += e * e
            }
            // v = A·sin(ωt + φ): A·cos φ = a, A·sin φ = b. A lag τ is
            // sin(ω(t − τ)), i.e. φ = −ωτ.
            let phi = atan2(x[1], x[0])
            return Fit(amplitude: hypot(x[0], x[1]), delaySeconds: -phi / omega,
                       offset: x[2], residualRMS: sqrt(sse / Double(n)), count: n)
        }

        static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
            var m = a
            var y = b
            for col in 0..<3 {
                var pivot = col
                for row in col..<3 where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
                guard abs(m[pivot][col]) > 1e-12 else { return nil }
                m.swapAt(col, pivot)
                y.swapAt(col, pivot)
                for row in 0..<3 where row != col {
                    let f = m[row][col] / m[col][col]
                    for k in 0..<3 { m[row][k] -= f * m[col][k] }
                    y[row] -= f * y[col]
                }
            }
            return (0..<3).map { y[$0] / m[$0][$0] }
        }

        /// Hann-weighted FIXED-PHASE least-squares amplitude at `centre`: the
        /// fit `v ≈ A·u + c`, `u = sin(ω(t − delay))`, with a LOCAL offset `c`.
        ///
        /// ⚠️ The offset term is not decoration. Without it a delivered wobble
        /// that sits a few cents off its base (measured: +10 c on the
        /// synthetic tone) reads `A + c` in a window centred on an upward swing
        /// and `A − c` on a downward one, the envelope ripples at the carrier
        /// rate, and a 90 % crossing can jump by half a period — which is how
        /// the first version of this reader failed the tone's 0.3 s option by
        /// 71 ms. `nil` when the window holds under a quarter of the weight a
        /// fully populated window would.
        static func amplitude(_ s: Series, at centre: Double, delay: Double,
                              sampleRate: Double) -> Double? {
            var suu = 0.0, su = 0.0, s1 = 0.0, svu = 0.0, sv = 0.0
            for (t, v) in zip(s.t, s.v) {
                let x = (t - centre) / halfWidth
                guard abs(x) < 1 else { continue }
                let w = 0.5 * (1 + cos(.pi * x))
                let u = sin(omega * (t - delay))
                suu += w * u * u
                su += w * u
                s1 += w
                svu += w * v * u
                sv += w * v
            }
            let full = 2 * halfWidth * sampleRate * 0.25
            guard suu >= 0.25 * full, s1 > 0 else { return nil }
            let det = suu * s1 - su * su
            guard det > 1e-9 * suu * s1 else { return nil }
            return (svu * s1 - sv * su) / det
        }

        static func envelope(_ s: Series, from: Double, to: Double, delay: Double,
                             sampleRate: Double, step: Double = 0.002) -> [(t: Double, a: Double)] {
            var out: [(t: Double, a: Double)] = []
            var c = from
            while c <= to + 1e-9 {
                if let a = amplitude(s, at: c, delay: delay, sampleRate: sampleRate) {
                    out.append((c, a))
                }
                c += step
            }
            return out
        }

        /// First time the envelope reaches `threshold`, linearly interpolated.
        static func firstCrossing(_ env: [(t: Double, a: Double)], threshold: Double) -> Double? {
            guard let i = env.firstIndex(where: { $0.a >= threshold }) else { return nil }
            guard i > 0 else { return env[0].t }
            let p = env[i - 1]
            let q = env[i]
            return p.t + (threshold - p.a) / (q.a - p.a) * (q.t - p.t)
        }

        static func rms(_ values: [Double]) -> Double {
            values.isEmpty ? 0 : sqrt(values.map { $0 * $0 }.reduce(0, +) / Double(values.count))
        }
    }

    // MARK: - What a perfect render would show the instrument

    /// The tracker's reading of a PERFECT render of an onset: a voice-like
    /// tone at the note's pitch whose pitch follows EXACTLY the product's
    /// generator term, tracked with the guard's configuration, minus the same
    /// tone held steady. Cached per onset; read at any times by interpolation.
    final class IdealReading {
        let note: Note
        let hz: Double
        let sampleRate: Double
        private var cache: [Int: Reader.Series] = [:]
        private var steady: Reader.Series?

        init(note: Note, hz: Double, sampleRate: Double) {
            self.note = note
            self.hz = hz
            self.sampleRate = sampleRate
        }

        private func tracked(onset: Double?) -> Reader.Series {
            let variant = note.curve(onset: onset ?? 0)
            let base = note.curve(onset: nil)
            let first = Int((note.start - 0.4) * sampleRate)
            let last = Int((note.end + 0.4) * sampleRate)
            let partials = WobbleOnsetListeningTests.voiceLikePartials
            let norm = 0.3 / partials.reduce(0, +)
            var samples = [Float](repeating: 0, count: last - first)
            var phase = 0.0
            for i in samples.indices {
                let t = Double(first + i) / sampleRate
                let semitones = onset == nil ? 0
                    : variant.semitones(atSourceSecond: t) - base.semitones(atSourceSecond: t)
                var v = 0.0
                for (k, a) in partials.enumerated() { v += a * sin(Double(k + 1) * phase) }
                samples[i] = Float(norm * v)
                phase += 2 * .pi * hz * pow(2, semitones / 12) / sampleRate
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
            return Reader.tracked(samples, sampleRate: sampleRate, hz: hz, within: note.interior,
                                  shift: Double(first) / sampleRate)
        }

        func series(onset: Double) -> Reader.Series {
            let key = Int((onset * 1_000_000).rounded())
            if let hit = cache[key] { return hit }
            if steady == nil { steady = tracked(onset: nil) }
            let s = Reader.subtract(tracked(onset: onset), steady ?? Reader.Series())
            cache[key] = s
            return s
        }

        func asked(onset: Double, at times: [Double]) -> Reader.Series {
            Reader.interpolate(series(onset: onset), at: times)
        }
    }

    // MARK: - One variant measured against the ask

    struct Reading {
        let name: String
        let onsetAsked: Double
        /// 90 % crossings, seconds AFTER the note start.
        let crossingMeasured: Double?
        let crossingPredicted: Double?
        /// The onset whose predicted crossing equals the measured one.
        let impliedOnset: Double?
        let passes: Bool
        let swingTimes: [Double]
        /// Each swing's width as a FRACTION of the side's own onset-0 plateau
        /// — instrument-independent, so delivered and asked compare directly.
        let swingsMeasured: [Double?]
        let swingsAsked: [Double?]
        let series: Reader.Series
    }

    /// What a perfect chain would show the instrument, for an onset, at the
    /// given times.
    typealias AskedProvider = (_ onset: Double, _ times: [Double]) -> Reader.Series

    /// Everything the guard needs, computed identically for the voice, the
    /// synthetic control and the decoded MP3s.
    struct Measurement {
        let note: Note
        /// Onset-0's plateau fits — delivered, and the ask as the instrument
        /// reads it — and the envelope plateaus each side is normalised by.
        let fit0: Reader.Fit
        let fitAsked: Reader.Fit
        let plateauMeasured: Double
        let plateauAsked: Double
        let readings: [Reading]

        /// Delivered depth in real cents: the instrument's reading of the
        /// render over its reading of the ideal, times the ask.
        var depthDelivered: Double {
            fit0.amplitude / fitAsked.amplitude * WobbleOnsetListeningTests.depthCents
        }

        /// `sampleRate` is the SERIES' rate (estimates per second).
        init(note: Note, sampleRate: Double, delivered: [Reader.Series],
             labels: [(onset: Double, name: String)], asked: @escaping AskedProvider) throws {
            let s = note.start
            let e = note.end
            let rate = WobbleOnsetListeningTests.rateHz
            let plateauWindow = (s + 0.1)...(e - 0.1)
            // labels[0] is always the at-once option.
            let askedZero = asked(labels[0].onset, delivered[0].t)
            guard let fit = Reader.fitSinusoid(delivered[0], over: plateauWindow),
                  let fitA = Reader.fitSinusoid(askedZero, over: plateauWindow) else {
                throw MeasurementError(description: "no plateau fit on the onset-0 series")
            }
            let delay = fit.delaySeconds
            let delayA = fitA.delaySeconds
            func plateau(_ series: Reader.Series, delay: Double) -> Double? {
                let env = Reader.envelope(series, from: s + 0.15, to: e - 0.15,
                                          delay: delay, sampleRate: sampleRate)
                return PitchCorrectionMath.median(env.map(\.a))
            }
            guard let measuredPlateau = plateau(delivered[0], delay: delay),
                  let askedPlateau = plateau(askedZero, delay: delayA),
                  measuredPlateau > 0, askedPlateau > 0 else {
                throw MeasurementError(description: "no envelope plateau")
            }

            // Extremum times of sin(ωt) inside the note: the wobble's swings.
            var swingTimes: [Double] = []
            var k = Int((s * rate * 2).rounded(.down)) - 1
            while true {
                let t = (Double(k) / 2 + 0.25) / rate
                if t > e { break }
                if t >= s { swingTimes.append(t) }
                k += 1
            }

            var readings: [Reading] = []
            for (i, label) in labels.enumerated() {
                let series = delivered[i]
                let envM = Reader.envelope(series, from: s - 0.03, to: e, delay: delay,
                                           sampleRate: sampleRate)
                let measured = Reader.firstCrossing(envM, threshold: 0.9 * measuredPlateau)
                let times = series.t
                func predictedCrossing(_ onset: Double) -> Double? {
                    let env = Reader.envelope(asked(onset, times), from: s - 0.03, to: e,
                                              delay: delayA, sampleRate: sampleRate)
                    return Reader.firstCrossing(env, threshold: 0.9 * askedPlateau)
                }
                let predicted = predictedCrossing(label.onset)
                // Invert by bisection: the onset whose predicted crossing
                // equals the measured one (the prediction rises with the
                // onset). The upper bound is the longest onset that still
                // reaches 90 % inside this note — a 0.9 s onset never does on
                // a 0.656 s note, which is why a fixed bound left this empty.
                var implied: Double?
                if let measured, let c0 = predictedCrossing(0) {
                    if measured <= c0 {
                        implied = 0
                    } else {
                        var hi = 0.9
                        while hi > 0.05, predictedCrossing(hi) == nil { hi -= 0.05 }
                        if let cHi = predictedCrossing(hi), measured <= cHi {
                            var lo = 0.0
                            for _ in 0..<14 {
                                let mid = (lo + hi) / 2
                                if let c = predictedCrossing(mid), c < measured { lo = mid } else { hi = mid }
                            }
                            implied = (lo + hi) / 2
                        }
                    }
                }
                var passes = false
                if let measured, let predicted {
                    passes = abs(measured - predicted) <= WobbleOnsetListeningTests.hopSeconds
                }
                let askedSeries = asked(label.onset, times)
                readings.append(Reading(
                    name: label.name, onsetAsked: label.onset,
                    crossingMeasured: measured.map { $0 - s },
                    crossingPredicted: predicted.map { $0 - s },
                    impliedOnset: implied, passes: passes,
                    swingTimes: swingTimes,
                    swingsMeasured: swingTimes.map {
                        Reader.amplitude(series, at: $0 + delay, delay: delay,
                                         sampleRate: sampleRate).map { $0 / measuredPlateau }
                    },
                    swingsAsked: swingTimes.map {
                        Reader.amplitude(askedSeries, at: $0 + delayA, delay: delayA,
                                         sampleRate: sampleRate).map { $0 / askedPlateau }
                    },
                    series: series))
            }
            self.note = note
            self.fit0 = fit
            self.fitAsked = fitA
            self.plateauMeasured = measuredPlateau
            self.plateauAsked = askedPlateau
            self.readings = readings
        }

        func logReadings(_ tag: String) {
            let s = note.start
            WobbleOnsetListeningTests.log(String(format:
                "%@ plateau: delivered reads ±%.1f c (fit ±%.1f over %d points, offset %+.1f, residual %.1f, carrier lag %+.1f ms); the ideal render of the ask reads ±%.1f c (fit ±%.1f, lag %+.1f ms) ⇒ depth delivered ±%.1f c of ±%.0f asked",
                tag as NSString, plateauMeasured, fit0.amplitude, fit0.count, fit0.offset,
                fit0.residualRMS, fit0.delaySeconds * 1000, plateauAsked, fitAsked.amplitude,
                fitAsked.delaySeconds * 1000, depthDelivered, WobbleOnsetListeningTests.depthCents))
            let raw = zip(readings[0].series.t, readings[0].series.v)
                .enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
                .map { String(format: "%.3f:%+.0f", $0.0 - s, $0.1) }.joined(separator: " ")
            WobbleOnsetListeningTests.log("\(tag) onset-0 delivered series (s after start: c) \(raw)")
            for r in readings {
                WobbleOnsetListeningTests.log(String(format:
                    "%@ %@ onset asked %.2f s | 90%% crossing measured %@ s, predicted %@ s (smoothstep alone %.3f s) | implied onset %@ s | guard %@",
                    tag as NSString, r.name as NSString, r.onsetAsked,
                    WobbleOnsetListeningTests.fmt(r.crossingMeasured) as NSString,
                    WobbleOnsetListeningTests.fmt(r.crossingPredicted) as NSString,
                    WobbleOnsetListeningTests.smoothstep90 * r.onsetAsked,
                    WobbleOnsetListeningTests.fmt(r.impliedOnset) as NSString,
                    (r.passes ? "PASS" : "FAIL") as NSString))
                let swings = r.swingTimes.indices.map { k in
                    String(format: "%.3f:%@/%@", r.swingTimes[k] - s,
                           WobbleOnsetListeningTests.fmt(r.swingsMeasured[k].map { $0 * 100 }, "%.0f") as NSString,
                           WobbleOnsetListeningTests.fmt(r.swingsAsked[k].map { $0 * 100 }, "%.0f") as NSString)
                }.joined(separator: " ")
                WobbleOnsetListeningTests.log(
                    "\(tag) \(r.name) swings (s after start: delivered/asked, % of full width) \(swings)")
            }
        }

        /// The whole reading as a JSON-safe dictionary.
        func record() -> [String: Any] {
            [
                "depthDelivered": depthDelivered,
                "trackerReadsDelivered": fit0.amplitude,
                "trackerReadsIdeal": fitAsked.amplitude,
                "plateauDelivered": plateauMeasured,
                "plateauAsked": plateauAsked,
                "carrierLagMs": fit0.delaySeconds * 1000,
                "idealLagMs": fitAsked.delaySeconds * 1000,
                "offsetCents": fit0.offset,
                "fitResidualCents": fit0.residualRMS,
                "options": readings.map { r in
                    [
                        "name": r.name, "onsetAsked": r.onsetAsked,
                        "crossingMeasured": WobbleOnsetListeningTests.json(r.crossingMeasured),
                        "crossingPredicted": WobbleOnsetListeningTests.json(r.crossingPredicted),
                        "smoothstepAlone90": WobbleOnsetListeningTests.smoothstep90 * r.onsetAsked,
                        "impliedOnset": WobbleOnsetListeningTests.json(r.impliedOnset),
                        "passes": r.passes,
                        "swingTimesAfterStart": r.swingTimes.map { $0 - note.start },
                        "swingsDeliveredFraction": r.swingsMeasured.map { WobbleOnsetListeningTests.json($0) },
                        "swingsAskedFraction": r.swingsAsked.map { WobbleOnsetListeningTests.json($0) },
                    ] as [String: Any]
                },
            ]
        }
    }

    static func fmt(_ value: Double?, _ format: String = "%.3f") -> String {
        value.map { String(format: format, $0) } ?? "none"
    }

    /// A JSON-safe value: `NSNull` for absent, a string for non-finite.
    static func json(_ value: Double?) -> Any {
        guard let value else { return NSNull() }
        return value.isFinite ? value : String(describing: value)
    }

    // MARK: - Rendering and detection

    struct Rendered {
        let url: URL
        let samples: [Float]
        let digest: String
    }

    /// One variant through the PRODUCT path, in a FRESH cache so identical
    /// params are rendered again rather than served from the first render's
    /// file (the plant's "identical" must be a property of the renders, not of
    /// the cache).
    @MainActor
    static func render(_ set: PitchEditSet, label: String, source: URL,
                       root: URL) async throws -> Rendered {
        let cacheDir = root.appendingPathComponent("render-cache-\(label)", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        let cache = StretchRenderCache(directory: cacheDir)
        let clip = Clip(name: "vocal", audioFileURL: source, pitchEdits: set)
        let params = StretchRenderCache.Params(clip: clip)
        #expect(!params.isIdentity, "\(label): the edit set rendered as identity")
        #expect(params.ratio == 1)
        let url = try await cache.renderIfNeeded(clipID: clip.id, source: source, params: params)
        let shortfall = cache.contourShortfall(source: source, params: params)
        #expect(shortfall == nil, "\(label) fell back to the constant-offset render: \(shortfall ?? "")")
        let samples = try TestSignals.readFile(url)[0]
        return Rendered(url: url, samples: samples, digest: digest(samples))
    }

    static func digest(_ samples: [Float]) -> String {
        var hasher = SHA256()
        samples.withUnsafeBufferPointer { hasher.update(bufferPointer: UnsafeRawBufferPointer($0)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func detect(_ url: URL) throws -> PitchDetectionResult {
        try PitchContourCache.detectWholeFile(url, .product)
    }

    static func noteName(_ hz: Double) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let midi = PitchCorrectionMath.midi(fromHz: hz)
        let n = Int(midi.rounded())
        return String(format: "%@%d (%+.0f c)", names[((n % 12) + 12) % 12] as NSString,
                      n / 12 - 1, (midi - Double(n)) * 100)
    }

    /// A phase-continuous tone with the given partial amplitudes whose
    /// frequency follows `hzAt(t)` — constant for a steady tone, or EXACTLY
    /// the asked wobble for the instrument's own control.
    static func tone(seconds: Double, sampleRate: Double, partials: [Double],
                     hzAt: (Double) -> Double) -> [Float] {
        let frames = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: frames)
        var phase = 0.0
        let norm = 0.3 / partials.reduce(0, +)
        for n in 0..<frames {
            var v = 0.0
            for (k, a) in partials.enumerated() { v += a * sin(Double(k + 1) * phase) }
            out[n] = Float(norm * v)
            phase += 2 * .pi * hzAt(Double(n) / sampleRate) / sampleRate
            if phase > 2 * .pi { phase -= 2 * .pi }
        }
        return out
    }

    /// Sample-exact cut with identical 20 ms raised-cosine fades.
    static func excerpt(_ samples: [Float], from: Double, to: Double,
                        sampleRate: Double) -> [Float] {
        let a = max(0, Int((from * sampleRate).rounded()))
        let b = min(samples.count, Int((to * sampleRate).rounded()))
        var out = Array(samples[a..<b])
        let fade = Int(0.02 * sampleRate)
        for i in 0..<min(fade, out.count / 2) {
            let g = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade)))
            out[i] *= g
            out[out.count - 1 - i] *= g
        }
        return out
    }

    static func db(_ x: Double) -> Double { x > 0 ? 20 * log10(x) : -.infinity }

    // MARK: - The instruments, with no render anywhere

    /// A tone carrying EXACTLY the asked wobble (`f0 · 2^(40·sin(2π·5.5·t)/1200)`,
    /// phase-continuous) with no render in the path, read by the product
    /// detector and by the guard's tracker. Any departure from ±40 c here
    /// belongs to the INSTRUMENT, not the chain. The tracker must read the
    /// wobble's SHAPE faithfully (its depth attenuation is a property of its
    /// window, recorded and carried on both sides of every comparison);
    /// SwiftF0's reading is recorded.
    @Test("the instruments reading an EXACT ±40 c 5.5 Hz wobble, no render in the path",
          .enabled(if: instrumentEnabled))
    func productDetectorReadsAKnownWobble() throws {
        let outDir = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["WOBBLE_ONSET_OUT"]))
            .appendingPathComponent("instrument", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let sampleRate = 48_000.0
        var rows: [[String: Any]] = []
        let spectra: [(String, [Double])] = [
            ("8 partials 1/k", (1...8).map { 1 / Double($0) }),
            ("voice-like, weak fundamental", Self.voiceLikePartials),
            ("pure sine", [1]),
        ]
        for hz in [83.24, 110.57, 146.83, 220.0] {
            for (label, partials) in spectra {
                let signal = Self.tone(seconds: 4, sampleRate: sampleRate, partials: partials) {
                    hz * pow(2, Self.depthCents * sin(2 * .pi * Self.rateHz * $0) / 1200)
                }
                let url = outDir.appendingPathComponent(
                    String(format: "fm-%.0fHz-%d.wav", hz, partials.count))
                try M23QComparisonPair.writeWAV([signal], sampleRate: sampleRate, to: url)
                let window = 1.0...3.0
                let swift = Reader.relative(try Self.detect(url), toHz: hz, within: window)
                let tracker = Reader.tracked(signal, sampleRate: sampleRate, hz: hz, within: window)
                let sf = Reader.fitSinusoid(swift, over: window)
                let tf = try #require(Reader.fitSinusoid(tracker, over: window))
                Self.log(String(format:
                    "INSTRUMENT %.2f Hz, %@: SwiftF0 ±%@ c (lag %@ ms, range %+.0f..%+.0f c, %d frames voiced in 2 s) | tracker ±%.1f c (lag %+.1f ms, offset %+.1f c, residual %.1f c)",
                    hz, label as NSString,
                    Self.fmt(sf?.amplitude, "%.1f") as NSString,
                    Self.fmt(sf.map { $0.delaySeconds * 1000 }, "%+.1f") as NSString,
                    swift.v.min() ?? .nan, swift.v.max() ?? .nan, swift.t.count,
                    tf.amplitude, tf.delaySeconds * 1000, tf.offset, tf.residualRMS))
                // The guard's instrument must read the exact wobble's SHAPE:
                // no lag, no offset, nothing left over but a couple of cents.
                #expect(tf.residualRMS < 2, "the tracker's reading of an exact wobble is not a sine at \(hz) Hz (\(label))")
                #expect(abs(tf.delaySeconds) < 0.001)
                #expect(abs(tf.offset) < 1)
                #expect(tf.amplitude > 30 && tf.amplitude < 41)
                rows.append([
                    "hz": hz, "spectrum": label,
                    "swiftF0Fit": Self.json(sf?.amplitude),
                    "swiftF0LagMs": Self.json(sf.map { $0.delaySeconds * 1000 }),
                    "swiftF0Range": [Self.json(swift.v.min()), Self.json(swift.v.max())],
                    "swiftF0VoicedFrames": swift.t.count,
                    "trackerFit": tf.amplitude, "trackerLagMs": tf.delaySeconds * 1000,
                    "trackerResidual": tf.residualRMS,
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
        try data.write(to: outDir.appendingPathComponent("instrument.json"))
    }

    /// How the guard's tracker configuration was chosen (kept runnable, not a
    /// gate): each configuration on an exact ±40 c wobble with a weak
    /// fundamental, on the same tone held steady, and on the real voice's flat
    /// render and onset-0 render (needs a previous run's `full/` files).
    @Test("(exploration) tracker configurations on a weak-fundamental tone and the real voice",
          .enabled(if: ProcessInfo.processInfo.environment["WOBBLE_ONSET_EXPLORE"] != nil))
    @MainActor
    func trackerConfigurationSweep() throws {
        let out = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["WOBBLE_ONSET_OUT"]))
        let sr = 48_000.0
        let hz = 83.24
        let s = 17.84
        let e = 18.496
        let interior = (s + 0.021)...(e - 0.021)
        let plateau = (s + 0.1)...(e - 0.1)
        let flat = try TestSignals.readFile(out.appendingPathComponent("full/zz-flat-no-wobble.wav"))[0]
        let zero = try TestSignals.readFile(out.appendingPathComponent("full/01-at-once.wav"))[0]
        let fm = Self.tone(seconds: 4, sampleRate: sr, partials: Self.voiceLikePartials) {
            hz * pow(2, Self.depthCents * sin(2 * .pi * Self.rateHz * $0) / 1200)
        }
        let steady = Self.tone(seconds: 4, sampleRate: sr, partials: Self.voiceLikePartials) { _ in hz }
        func jitter(_ s: Reader.Series) -> Double {
            guard s.v.count > 2 else { return .nan }
            return Reader.rms(zip(s.v.dropFirst(), s.v).map { $0 - $1 }) / sqrt(2)
        }
        for (w, p) in [(2048, 32), (2048, 256), (4096, 256), (4096, 480), (8192, 480)] {
            let fmFit = Reader.fitSinusoid(
                Reader.tracked(fm, sampleRate: sr, hz: hz, within: 1.0...3.0, windowSize: w, phaseHop: p),
                over: 1.0...3.0)
            let st = Reader.tracked(steady, sampleRate: sr, hz: hz, within: 1.0...3.0,
                                    windowSize: w, phaseHop: p)
            let flatS = Reader.tracked(flat, sampleRate: sr, hz: hz, within: interior,
                                       windowSize: w, phaseHop: p)
            let zeroS = Reader.tracked(zero, sampleRate: sr, hz: hz, within: interior,
                                       windowSize: w, phaseHop: p)
            let dFit = Reader.fitSinusoid(Reader.subtract(zeroS, flatS), over: plateau)
            Self.log(String(format:
                "SWEEP window %d phaseHop %d: exact ±40 (weak fundamental) reads ±%@ c (residual %@) | steady tone jitter %.1f c | voice flat jitter %.1f c | voice 01−flat ±%@ c (residual %@)",
                w, p, Self.fmt(fmFit?.amplitude, "%.1f") as NSString,
                Self.fmt(fmFit?.residualRMS, "%.1f") as NSString, jitter(st), jitter(flatS),
                Self.fmt(dFit?.amplitude, "%.1f") as NSString,
                Self.fmt(dFit?.residualRMS, "%.1f") as NSString))
        }
    }

    // MARK: - The chain and the reader, on a synthetic tone

    /// The reader, the guard and the chain on a synthetic voice-like tone at
    /// the note's pitch and at the note's exact source times (the generator's
    /// phase is anchored at source second 0, so the times ARE the phase),
    /// through the same product path: the four onsets must read back within
    /// one hop, and the plant (every label rendered at onset 0) must be
    /// flagged. SwiftF0's reading of the same renders is recorded.
    @MainActor
    static func syntheticControl(note: Note, outDir: URL,
                                 sampleRate: Double) async throws -> [String: Any] {
        let dir = outDir.appendingPathComponent("control", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hz = note.segment.detectedHz
        let toneURL = dir.appendingPathComponent("tone.wav")
        try M23QComparisonPair.writeWAV(
            [tone(seconds: note.end + 1.5, sampleRate: sampleRate,
                  partials: voiceLikePartials) { _ in hz }],
            sampleRate: sampleRate, to: toneURL)
        let table = PitchEditSet(
            analysisVersion: note.table.analysisVersion,
            segments: [NoteSegment(startSeconds: note.start, endSeconds: note.end,
                                   detectedHz: hz, detectedConfidence: 1)],
            retuneMs: note.table.retuneMs)
        let control = Note(index: 0, table: table)
        let ideal = IdealReading(note: control, hz: hz, sampleRate: sampleRate)
        let flat = try await render(control.set(onset: nil), label: "control-flat",
                                    source: toneURL, root: dir)
        let flatTracked = Reader.tracked(flat.samples, sampleRate: sampleRate, hz: hz,
                                         within: control.interior)
        let flatF0 = try detect(flat.url)
        var tracked: [Reader.Series] = []
        var swift: [Reader.Series] = []
        for option in options {
            let r = try await render(control.set(onset: option.onset),
                                     label: "control-\(option.name)", source: toneURL, root: dir)
            tracked.append(Reader.subtract(
                Reader.tracked(r.samples, sampleRate: sampleRate, hz: hz, within: control.interior),
                flatTracked))
            swift.append(Reader.difference(try detect(r.url), minus: flatF0,
                                           within: control.interior))
        }
        let m = try Measurement(note: control, sampleRate: trackerRate, delivered: tracked,
                                labels: options) { ideal.asked(onset: $0, at: $1) }
        m.logReadings(String(format: "CONTROL(tone %.2f Hz)", hz))
        for r in m.readings {
            #expect(r.passes, """
                the onset reader could not read the synthetic control's \(r.name) back within \
                one hop: measured \(fmt(r.crossingMeasured)), predicted \(fmt(r.crossingPredicted))
                """)
        }
        let ms = try? Measurement(note: control, sampleRate: 62.5, delivered: swift,
                                  labels: options) { Reader.curveTerm(control, onset: $0, at: $1) }
        ms?.logReadings(String(format: "CONTROL(tone %.2f Hz, SwiftF0 against the curve, recorded only)", hz))
        // THE GUARD CAN FAIL: every label rendered at onset 0.
        let plant = try Measurement(note: control, sampleRate: trackerRate,
                                    delivered: Array(repeating: tracked[0], count: options.count),
                                    labels: options) { ideal.asked(onset: $0, at: $1) }
        plant.logReadings("CONTROL-PLANT")
        let flagged = plant.readings.filter { !$0.passes }.map(\.name)
        #expect(flagged == options.dropFirst().map(\.name),
                "the guard did not flag the planted onsets: flagged \(flagged)")
        var out = m.record()
        out["toneHz"] = hz
        out["plantFlagged"] = flagged
        out["swiftF0"] = ms?.record() ?? NSNull()
        return out
    }

    // MARK: - The renders

    @Test("four onsets on one real note through the product path, guarded against the curve",
          .enabled(if: enabled))
    @MainActor
    func renderOnsetOptionsThroughTheProductPath() async throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(env["WOBBLE_ONSET_SOURCE"]))
        let outDir = URL(fileURLWithPath: try #require(env["WOBBLE_ONSET_OUT"]))
        let noteAtText = try #require(env["WOBBLE_ONSET_NOTE_AT"])
        let noteAt = try #require(Double(noteAtText))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let input = try TestSignals.readFile(source)
        let sampleRate = try AVAudioFile(forReading: source).processingFormat.sampleRate
        #expect(sampleRate == 48_000, "the tracker's rate and the hop assume 48 kHz")
        if Self.planted { Self.log("PLANT MODE: every option is rendered at onset 0") }

        // The product's detection and note table — what the pitch editor draws.
        let detection = try Self.detect(source)
        let table = PitchNoteTable.detected(from: detection)
        Self.log("detection: \(detection.frameCount) frames at \(detection.frameRateHz) fps, \(detection.voicedFrameCount) voiced; \(table.segments.count) notes, retune \(table.retuneMs) ms, analysisVersion \(table.analysisVersion)")
        for (i, seg) in table.segments.enumerated() {
            Self.log(String(format: "  note %2d  %7.3f-%7.3f s  %.3f s  %7.2f Hz  %@", i + 1,
                            seg.startSeconds, seg.endSeconds, seg.durationSeconds,
                            seg.detectedHz, Self.noteName(seg.detectedHz) as NSString))
        }
        let index = try #require(table.segments.firstIndex {
            $0.startSeconds <= noteAt && noteAt < $0.endSeconds
        }, "no detected note contains \(noteAt) s")
        let note = Note(index: index, table: table)
        let seg = note.segment
        let s = note.start
        let e = note.end
        let hz = seg.detectedHz
        Self.log(String(format: "CHOSEN note %d of %d: %.3f-%.3f s (%.3f s), %.2f Hz %@",
                        index + 1, table.segments.count, s, e, seg.durationSeconds,
                        hz, Self.noteName(hz) as NSString))
        #expect(seg.durationSeconds >= 0.6, "the note cannot hold a 0.6 s onset")
        // Its neighbours must not reach its ramps, or the curve difference
        // would stop being the generator term alone.
        let ramp = table.retuneMs / 1000
        if index > 0 { #expect(table.segments[index - 1].endSeconds + ramp < s) }
        if index + 1 < table.segments.count {
            #expect(e + ramp < table.segments[index + 1].startSeconds)
        }

        // The chain and the reader first, on a tone at this note's pitch.
        let control = try await Self.syntheticControl(note: note, outDir: outDir,
                                                      sampleRate: sampleRate)

        // ── The voice. A fifth render — flattened, no generator — is the base
        //    every variant's pitch is read against.
        let fullDir = outDir.appendingPathComponent("full", isDirectory: true)
        try FileManager.default.createDirectory(at: fullDir, withIntermediateDirectories: true)
        let flat = try await Self.render(note.set(onset: nil), label: "flat", source: source,
                                         root: outDir)
        let flatF0 = try Self.detect(flat.url)
        let flatTracked = Reader.tracked(flat.samples, sampleRate: sampleRate, hz: hz,
                                         within: note.interior)
        try M23QComparisonPair.writeWAV([flat.samples], sampleRate: sampleRate,
                                        to: fullDir.appendingPathComponent("zz-flat-no-wobble.wav"))
        var renders: [Rendered] = []
        var tracked: [Reader.Series] = []
        var swift: [Reader.Series] = []
        for option in Self.options {
            let onset = Self.planted ? 0 : option.onset
            let r = try await Self.render(note.set(onset: onset), label: option.name,
                                          source: source, root: outDir)
            renders.append(r)
            tracked.append(Reader.subtract(
                Reader.tracked(r.samples, sampleRate: sampleRate, hz: hz, within: note.interior),
                flatTracked))
            swift.append(Reader.difference(try Self.detect(r.url), minus: flatF0,
                                           within: note.interior))
            try M23QComparisonPair.writeWAV([r.samples], sampleRate: sampleRate,
                                            to: fullDir.appendingPathComponent(option.name + ".wav"))
            Self.log("rendered \(option.name) (onset rendered \(onset) s): \(r.samples.count) samples, sha256 \(r.digest)")
        }
        // The reference: the same pitch engine with nothing asked of it (the
        // precedent of `ContourRenderListeningTests`' 00-uncorrected), so it
        // differs from the options by the note's edit alone.
        let reference = try OfflineStretcher.stretchTransposeCurve(
            input: input, sampleRate: sampleRate, ratio: 1,
            semitonesAtOutputFrame: { _ in 0 }, formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate))[0]
        try M23QComparisonPair.writeWAV([reference], sampleRate: sampleRate,
                                        to: fullDir.appendingPathComponent("reference-as-sung.wav"))

        // ── PLANT / IDENTITY: the same ask four times must give the same audio
        //    four times, and distinct asks must give distinct audio.
        let digests = renders.map(\.digest)
        if Self.planted {
            #expect(Set(digests).count == 1, "the planted renders differ: \(digests)")
        } else {
            #expect(Set(digests).count == Self.options.count, "two onsets rendered identically: \(digests)")
        }

        // ── THE GUARD, on the tracker against the ideal reading of the ask.
        let ideal = IdealReading(note: note, hz: hz, sampleRate: sampleRate)
        let m = try Measurement(note: note, sampleRate: Self.trackerRate, delivered: tracked,
                                labels: Self.options) { ideal.asked(onset: $0, at: $1) }
        let tag = Self.planted ? "VOICE-PLANTED" : "VOICE"
        m.logReadings(tag)
        let verdicts = Self.voiceVerdicts(m)
        Self.logVerdicts(tag, m, verdicts)
        for v in verdicts.verdicts where v.gated {
            #expect(v.passes, "\(v.name): the voice's 90 % crossing is outside its derived tolerance (\(v.why))")
        }
        let ms = try? Measurement(note: note, sampleRate: detection.frameRateHz, delivered: swift,
                                  labels: Self.options) { Reader.curveTerm(note, onset: $0, at: $1) }
        ms?.logReadings("VOICE(SwiftF0 against the curve, recorded only)")

        // ── What the flatten left behind (tracker, relative to the detected centre).
        let referenceTracked = Reader.tracked(reference, sampleRate: sampleRate, hz: hz,
                                              within: note.interior)
        func movement(_ series: Reader.Series) -> (rms: Double, median: Double) {
            let inner = zip(series.t, series.v).filter { $0.0 >= s + 0.05 && $0.0 <= e - 0.05 }.map(\.1)
            let median = PitchCorrectionMath.median(inner) ?? 0
            return (Reader.rms(inner.map { $0 - median }), median)
        }
        let sungMovement = movement(referenceTracked)
        let flatMovement = movement(flatTracked)
        Self.log(String(format:
            "movement inside the note (tracker, RMS about the median, %.3f-%.3f s): as sung %.1f c, flattened %.1f c; flattened median %+.1f c from the detected centre",
            s + 0.05, e - 0.05, sungMovement.rms, flatMovement.rms, flatMovement.median))

        // ── AUDIBILITY: how different the four are in the first 0.6 s.
        var pairs: [[String: Any]] = []
        for i in 0..<Self.options.count {
            for j in (i + 1)..<Self.options.count {
                let a = m.readings[i]
                let b = m.readings[j]
                let gap = Reader.subtract(a.series, b.series)
                let first = zip(gap.t, gap.v).filter { $0.0 >= s && $0.0 <= s + 0.6 }.map(\.1)
                let askedGap = Reader.curveTerm(note, onset: Self.options[i].onset, at: gap.t).v
                let askedGapB = Reader.curveTerm(note, onset: Self.options[j].onset, at: gap.t).v
                let askedFirst = zip(gap.t, zip(askedGap, askedGapB))
                    .filter { $0.0 >= s && $0.0 <= s + 0.6 }.map { $0.1.0 - $0.1.1 }
                var swingGaps: [Double] = []
                var askedSwingGaps: [Double] = []
                for k in a.swingTimes.indices {
                    if let x = a.swingsMeasured[k], let y = b.swingsMeasured[k] {
                        swingGaps.append(abs(x - y))
                    }
                    if let x = a.swingsAsked[k], let y = b.swingsAsked[k] {
                        askedSwingGaps.append(abs(x - y))
                    }
                }
                let differing = swingGaps.filter { $0 >= 0.25 }.count
                let askedDiffering = askedSwingGaps.filter { $0 >= 0.25 }.count
                // Tracker units → real cents via the instrument's own ratio.
                let toCents = Self.depthCents / m.fitAsked.amplitude
                Self.log(String(format:
                    "PAIR %@ vs %@: first 0.6 s pitch difference RMS %.1f c, max %.1f c (the curve asks RMS %.1f, max %.1f) | swings differing by >= 25%% of full width: %d delivered (%d asked) of %d | per-swing gaps %@ %% of full width",
                    a.name as NSString, b.name as NSString,
                    Reader.rms(first) * toCents, (first.map(abs).max() ?? 0) * toCents,
                    Reader.rms(askedFirst), askedFirst.map(abs).max() ?? 0,
                    differing, askedDiffering, swingGaps.count,
                    swingGaps.map { String(format: "%.0f", $0 * 100) }.joined(separator: ",") as NSString))
                pairs.append([
                    "a": a.name, "b": b.name,
                    "rmsCents": Reader.rms(first) * toCents,
                    "maxCents": (first.map(abs).max() ?? 0) * toCents,
                    "askedRmsCents": Reader.rms(askedFirst),
                    "askedMaxCents": askedFirst.map(abs).max() ?? 0,
                    "swingsDiffering25pc": differing, "askedSwingsDiffering25pc": askedDiffering,
                    "swingGapsFraction": swingGaps, "askedSwingGapsFraction": askedSwingGaps,
                ])
            }
        }

        // ── WHERE the four differ: in pitch (the claim), and in bytes (the record).
        var locations: [[String: Any]] = []
        for (i, option) in Self.options.enumerated() where i > 0 {
            let gap = Reader.subtract(m.readings[i].series, m.readings[0].series)
            let over = zip(gap.t, gap.v).filter { abs($0.1) >= Self.locationThresholdCents }.map(\.0)
            let a = renders[i].samples
            let b = renders[0].samples
            let firstDiff = zip(a, b).enumerated()
                .first { $0.element.0.bitPattern != $0.element.1.bitPattern }?.offset
            func windowRMS(_ from: Double, _ to: Double, _ x: [Float], _ y: [Float]?) -> Double {
                let lo = max(0, Int(from * sampleRate))
                let hi = min(x.count, Int(to * sampleRate))
                guard hi > lo else { return 0 }
                var sum = 0.0
                for n in lo..<hi {
                    let d = Double(x[n]) - Double(y?[n] ?? 0)
                    sum += d * d
                }
                return sqrt(sum / Double(hi - lo))
            }
            let onsetEnd = s + (Self.planted ? 0 : option.onset)
            let end = Double(a.count) / sampleRate
            let before = windowRMS(0, s - 0.1, a, b)
            let during = windowRMS(s - 0.1, onsetEnd + 0.1, a, b)
            let after = windowRMS(onsetEnd + 0.1, e + 0.3, a, b)
            let rest = windowRMS(e + 0.3, end, a, b)
            let noteLevel = windowRMS(s, e, b, nil)
            let beforeText = before == 0 ? "bit-identical" : String(format: "%.1f dBFS", Self.db(before))
            Self.log(String(format:
                "WHERE %@ differs from 01: pitch by >= %.0f c from %@ to %@ s after the note start (its onset window ends at %.3f s; slack %.3f s) | first differing sample %@ s after the note start | difference RMS before the note %@, %.1f dBFS across the onset window, %.1f dBFS from there to 0.3 s past the note, %.1f dBFS after that (the note itself: %.1f dBFS)",
                option.name as NSString, Self.locationThresholdCents,
                Self.fmt(over.first.map { $0 - s }) as NSString,
                Self.fmt(over.last.map { $0 - s }) as NSString, onsetEnd - s, Self.locationSlackSeconds,
                Self.fmt(firstDiff.map { Double($0) / sampleRate - s }, "%.4f") as NSString,
                beforeText as NSString, Self.db(during), Self.db(after), Self.db(rest),
                Self.db(noteLevel)))
            if !Self.planted {
                let first = try #require(over.first, "\(option.name)'s pitch never differs from 01")
                let last = try #require(over.last)
                #expect(first - s >= -Self.locationSlackSeconds,
                        "\(option.name)'s pitch differs from 01 before the note starts")
                #expect(last - s <= option.onset + Self.locationSlackSeconds,
                        "\(option.name)'s pitch differs from 01 after its onset window ended")
                #expect(before == 0, "\(option.name)'s audio differs from 01 before the note")
            }
            locations.append([
                "name": option.name,
                "pitchDiffersFrom": Self.json(over.first.map { $0 - s }),
                "pitchDiffersTo": Self.json(over.last.map { $0 - s }),
                "firstDifferingSampleAfterStart": Self.json(firstDiff.map { Double($0) / sampleRate - s }),
                "diffBefore": beforeText,
                "diffRmsDbOnsetWindow": Self.json(Self.db(during)),
                "diffRmsDbAfter": Self.json(Self.db(after)),
                "diffRmsDbRest": Self.json(Self.db(rest)),
                "noteRmsDb": Self.json(Self.db(noteLevel)),
            ])
        }

        // ── Excerpts: the same window of every file, sample-exact.
        let bounds = (env["WOBBLE_ONSET_EXCERPT"] ?? "").split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        let ex0 = bounds.count == 2 ? bounds[0] : max(0, s - 1.5)
        let ex1 = bounds.count == 2 ? bounds[1] : min(Double(input[0].count) / sampleRate, e + 1.0)
        var excerpts: [(String, [Float])] = zip(Self.options, renders).map { ($0.0.name, $0.1.samples) }
        excerpts.append(("reference-as-sung", reference))
        excerpts.append(("zz-flat-no-wobble", flat.samples))
        for (name, samples) in excerpts {
            try M23QComparisonPair.writeWAV(
                [Self.excerpt(samples, from: ex0, to: ex1, sampleRate: sampleRate)],
                sampleRate: sampleRate, to: outDir.appendingPathComponent(name + ".wav"))
        }
        Self.log(String(format: "excerpt %.3f-%.3f s (%.3f s); the note starts %.3f s in and ends %.3f s in",
                        ex0, ex1, ex1 - ex0, s - ex0, e - ex0))

        // ── The record.
        var tracker = m.record()
        if var options = tracker["options"] as? [[String: Any]] {
            for k in options.indices {
                options[k]["sha256"] = renders[k].digest
                options[k]["renderedOnset"] = Self.planted ? 0 : Self.options[k].onset
            }
            tracker["options"] = options
        }
        let record: [String: Any] = [
            "planted": Self.planted,
            "source": source.path,
            "note": [
                "number": index + 1, "of": table.segments.count,
                "startSeconds": s, "endSeconds": e, "durationSeconds": seg.durationSeconds,
                "detectedHz": hz, "name": Self.noteName(hz),
                "retuneMs": table.retuneMs, "analysisVersion": table.analysisVersion,
            ] as [String: Any],
            "excerpt": ["startSeconds": ex0, "endSeconds": ex1,
                        "noteStartsAt": s - ex0, "noteEndsAt": e - ex0] as [String: Any],
            "rateHz": Self.rateHz, "depthCents": Self.depthCents, "hopSeconds": Self.hopSeconds,
            "tracker": tracker,
            "voiceGuard": Self.verdictRecord(verdicts),
            "swiftF0": ms?.record() ?? NSNull(),
            "sungMovementRmsCents": sungMovement.rms,
            "flattenedMovementRmsCents": flatMovement.rms,
            "flattenedMedianCents": flatMovement.median,
            "pairs": pairs,
            "locations": locations,
            "control": control,
        ]
        let data = try JSONSerialization.data(withJSONObject: record,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outDir.appendingPathComponent(
            Self.planted ? "measurements-planted.json" : "measurements.json"))
    }

    // MARK: - The files a person plays

    /// Re-reads the MP3s ACTUALLY WRITTEN, decoded back to float WAV
    /// (`ffmpeg -hide_banner -i X.mp3 -c:a pcm_f32le -ar 48000 -ac 1 X.wav`
    /// into `WOBBLE_ONSET_DECODED`, plus `zz-flat-no-wobble.wav` decoded from
    /// an internal MP3 of the flat excerpt as the base), so the onset figures
    /// a README quotes belong to the files a person plays.
    @Test("the written MP3s carry the onsets the renders measured", .enabled(if: decodedEnabled))
    @MainActor
    func remeasureTheWrittenMP3s() throws {
        let env = ProcessInfo.processInfo.environment
        let outDir = URL(fileURLWithPath: try #require(env["WOBBLE_ONSET_OUT"]))
        let dir = URL(fileURLWithPath: try #require(env["WOBBLE_ONSET_DECODED"]))
        let record = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: outDir.appendingPathComponent("measurements.json"))) as? [String: Any])
        let noteRecord = try #require(record["note"] as? [String: Any])
        let excerptRecord = try #require(record["excerpt"] as? [String: Any])
        let s = try #require(noteRecord["startSeconds"] as? Double)
        let e = try #require(noteRecord["endSeconds"] as? Double)
        let hz = try #require(noteRecord["detectedHz"] as? Double)
        let retune = try #require(noteRecord["retuneMs"] as? Double)
        let ex0 = try #require(excerptRecord["startSeconds"] as? Double)

        // The decoded MP3 must sit on the excerpt's own timeline: the lag that
        // best aligns it with the WAV IT was encoded from (scale-free).
        // ⚠️ Its OWN WAV: correlating every decoded file against 01's WAV (the
        // first version) biased the peak by 1–2 samples, because the note
        // region differs between options — and reported four files that are
        // bit-identical before the note as "not sharing one timeline".
        func lag(_ decoded: [Float], _ name: String) throws -> Int {
            let written = try TestSignals.readFile(outDir.appendingPathComponent(name + ".wav"))[0]
            var best = (lag: 0, score: -Double.infinity)
            let n = min(written.count, decoded.count) - 3_000
            for l in -1_500...1_500 {
                var sum = 0.0
                var k = 1_500
                while k < n {
                    sum += Double(written[k]) * Double(decoded[k + l])
                    k += 5
                }
                if sum > best.score { best = (l, sum) }
            }
            return best.lag
        }

        let table = PitchEditSet(
            segments: [NoteSegment(startSeconds: s, endSeconds: e, detectedHz: hz,
                                   detectedConfidence: 1)],
            retuneMs: retune)
        let note = Note(index: 0, table: table)
        let ideal = IdealReading(note: note, hz: hz, sampleRate: 48_000)
        let flatURL = dir.appendingPathComponent("zz-flat-no-wobble.wav")
        let flatDecoded = try TestSignals.readFile(flatURL)[0]
        let rate = try AVAudioFile(forReading: flatURL).processingFormat.sampleRate
        #expect(rate == 48_000)
        let flatLag = try lag(flatDecoded, "zz-flat-no-wobble")
        let shift = ex0 - Double(flatLag) / rate
        let flatTracked = Reader.tracked(flatDecoded, sampleRate: rate, hz: hz,
                                         within: note.interior, shift: shift)
        let flatF0 = try Self.detect(flatURL)
        var tracked: [Reader.Series] = []
        var swift: [Reader.Series] = []
        for option in Self.options {
            let url = dir.appendingPathComponent(option.name + ".wav")
            let decoded = try TestSignals.readFile(url)[0]
            let l = try lag(decoded, option.name)
            Self.log("decoded \(option.name).mp3: lag against the written WAV \(l) samples (flat base \(flatLag))")
            #expect(l == flatLag, "the decoded files do not share one timeline")
            tracked.append(Reader.subtract(
                Reader.tracked(decoded, sampleRate: rate, hz: hz, within: note.interior, shift: shift),
                flatTracked))
            swift.append(Reader.difference(try Self.detect(url), minus: flatF0,
                                           within: note.interior, shift: shift))
        }
        let m = try Measurement(note: note, sampleRate: Self.trackerRate, delivered: tracked,
                                labels: Self.options) { ideal.asked(onset: $0, at: $1) }
        m.logReadings("MP3")
        let verdicts = Self.voiceVerdicts(m)
        Self.logVerdicts("MP3", m, verdicts)
        for v in verdicts.verdicts where v.gated {
            #expect(v.passes, "\(v.name).mp3: the 90 % crossing is outside its derived tolerance (\(v.why))")
        }
        let ms = try? Measurement(note: note, sampleRate: 62.5, delivered: swift,
                                  labels: Self.options) { Reader.curveTerm(note, onset: $0, at: $1) }
        ms?.logReadings("MP3(SwiftF0 against the curve, recorded only)")
        var out = m.record()
        out["voiceGuard"] = Self.verdictRecord(verdicts)
        out["decodeLagSamples"] = flatLag
        out["swiftF0"] = ms?.record() ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("measurements-mp3.json"))
    }
}
