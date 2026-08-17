import Foundation
import Testing
@testable import DAWEngine

/// m23-ap-2b — **the design's §5.5 fixture gate**, plus the honest-absence
/// contract that `PitchObservation` exists to enforce.
///
/// Division of labour with `PitchTrackerInferenceTests` (m23-ap-2a): that suite
/// characterises the RAW artefact — the weights' hash, a real ORT session, the
/// model's argmax on a bare sine. This suite characterises what a CALLER sees:
/// the `PitchTracker` seam, the 48 k → 16 k conditioning, and the voicing
/// policy that decides when there is no pitch at all.
///
/// ⚠️ §7.6: pitch DSP never reaches the render thread, and neither does this
/// suite. Every leg runs synchronously on the test's own thread; nothing here
/// touches `AudioEngine`, an `AVAudioEngine` render callback, or a tap.
///
/// ⚠️⚠️ **EVERY THRESHOLD BELOW WAS MEASURED FIRST AND THEN PINNED WITH A
/// STATED MARGIN.** None is aspirational, and where a measurement misses the
/// design's written bar the test pins the MEASUREMENT and says so — see
/// `theOutputIsQuantisedSoTenCentAccuracyIsUnreachable`. A gate that quietly
/// loosened a bar would bury exactly the finding this item exists to produce.
///
/// ⚠️⚠️ **THE FIXTURES ARE HARMONIC, NOT SINE, AND THAT IS THE HEADLINE.**
/// Every poor number recorded before this item — 88 % octave errors at 220 Hz,
/// +94 cents at 98 Hz — was measured on a PURE SINE, which a spectrogram CNN
/// trained on real audio has nothing to lock onto. The same pitches with eight
/// or more harmonics read 0.5–13 cents at confidence ~1.0. Do not "simplify" a
/// fixture here to a bare sine; it changes what is being measured.
struct PitchTrackerAccuracyTests {

    // MARK: - Fixtures (generated, not committed — a closed form is auditable
    //         and cannot rot, and this keeps `Package.swift` untouched)

    enum Fixture {
        static let rate = SwiftF0PitchTracker.modelSampleRate

        /// A voice-like tone: `partials` harmonics at 1/n amplitude, peak
        /// normalised. `f0` is evaluated per sample and the phase integrated,
        /// so vibrato, glides and leaps all come from this one generator.
        static func tone(seconds: Double,
                         amplitude: Double = 0.5,
                         partials: Int = 12,
                         sampleRate: Double = rate,
                         f0: (Double) -> Double) -> [Float] {
            let n = Int(seconds * sampleRate)
            guard n > 0 else { return [] }
            var phase = 0.0
            var out = [Double](repeating: 0, count: n)
            var maxF = 0.0
            for i in 0..<n { maxF = max(maxF, f0(Double(i) / sampleRate)) }
            let usable = max(1, min(partials, Int((sampleRate / 2) / max(maxF, 1)) ))
            for i in 0..<n {
                let f = f0(Double(i) / sampleRate)
                phase += 2 * .pi * f / sampleRate
                var v = 0.0
                for k in 1...usable { v += (1.0 / Double(k)) * sin(Double(k) * phase) }
                out[i] = v
            }
            let peak = out.map(abs).max() ?? 1
            let gain = peak > 0 ? amplitude / peak : 0
            return out.map { Float($0 * gain) }
        }

        static func steady(_ f: Double,
                           seconds: Double = 0.512,
                           amplitude: Double = 0.5,
                           partials: Int = 12,
                           sampleRate: Double = rate) -> [Float] {
            tone(seconds: seconds, amplitude: amplitude, partials: partials,
                 sampleRate: sampleRate) { _ in f }
        }

        static func silence(seconds: Double, sampleRate: Double = rate) -> [Float] {
            [Float](repeating: 0, count: Int(seconds * sampleRate))
        }

        /// Deterministic pseudo-noise — a seeded LCG, so a failure is
        /// reproducible rather than "sometimes".
        static func noise(seconds: Double, amplitude: Double = 0.3,
                          sampleRate: Double = rate, seed: UInt64 = 0x5EED) -> [Float] {
            var state = seed
            return (0..<Int(seconds * sampleRate)).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let unit = Double(state >> 11) / Double(UInt64(1) << 53)
                return Float((unit * 2 - 1) * amplitude)
            }
        }
    }

    static func cents(_ f: Double, from reference: Double) -> Double {
        1200 * log2(f / reference)
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]
    }

    /// C3…E5 by semitone-ish steps, deliberately OFF the model's ~26-cent
    /// output grid (see the quantisation leg) so the fixtures cannot flatter it.
    static let sungRange: [Double] = [
        164.81, 174.61, 196.00, 220.00, 246.94, 261.63, 293.66,
        329.63, 349.23, 392.00, 440.00, 493.88, 523.25, 587.33, 659.25,
    ]
    static let lowRange: [Double] = [82.41, 87.31, 98.00, 110.00, 123.47, 130.81, 146.83]

    // MARK: - The §5.5 battery, expressed over the PROTOCOL
    //
    // Written against `any PitchTracker` for one reason: so it can be run
    // against a deliberately-wrong tracker and OBSERVED TO FAIL. A gate nobody
    // has seen fail is a gate whose failure mode is unknown, and this is the
    // repo's standing anti-vacuity law applied to a whole battery rather than a
    // single assertion. The seam earned its keep here before it ever had a
    // second real backend.

    struct BatteryReport {
        var failures: [String] = []
        var notes: [String] = []
    }

    static func runBattery(_ tracker: any PitchTracker,
                           label: String) throws -> BatteryReport {
        var report = BatteryReport()

        func measure(_ pitches: [Double],
                     name: String,
                     p95Ceiling: Double,
                     maxCeiling: Double,
                     minVoicedFraction: Double) throws {
            var abs95: [Double] = []
            var octaveFrames = 0
            var voiced = 0
            var total = 0
            for f in pitches {
                let contour = try tracker.analyze(samples: Fixture.steady(f), sampleRate: Fixture.rate)
                total += contour.observations.count
                for o in contour.observations {
                    guard let hz = o.frequencyHz else { continue }
                    voiced += 1
                    let c = cents(hz, from: f)
                    if abs(abs(c) - 1200) <= 150 { octaveFrames += 1 } else { abs95.append(abs(c)) }
                }
            }
            let sorted = abs95.sorted()
            let p95 = percentile(sorted, 0.95)
            let worst = sorted.last ?? .nan
            let fraction = total == 0 ? 0 : Double(voiced) / Double(total)
            report.notes.append(String(
                format: "%@/%@: voiced %d/%d (%.1f%%) med=%.2f¢ p95=%.2f¢ max=%.2f¢ octave=%d",
                label, name, voiced, total, 100 * fraction,
                percentile(sorted, 0.5), p95, worst, octaveFrames))
            if fraction < minVoicedFraction {
                report.failures.append(String(format: "%@: voiced fraction %.3f < %.3f",
                                              name, fraction, minVoicedFraction))
            }
            if !(p95 <= p95Ceiling) {
                report.failures.append(String(format: "%@: p95 |cents| %.2f > %.2f", name, p95, p95Ceiling))
            }
            if !(worst <= maxCeiling) {
                report.failures.append(String(format: "%@: worst |cents| %.2f > %.2f", name, worst, maxCeiling))
            }
            if octaveFrames > 0 {
                report.failures.append("\(name): \(octaveFrames) octave-error frames")
            }
        }

        // Leg 1 — the core sung register. MEASURED on these exact fixtures:
        // median 4.74¢, p95 15.53¢, worst 15.54¢, ZERO octave errors, voiced
        // 443/480 = 92.3 %. Ceilings are those numbers with margin.
        //
        // ⚠️ THE VOICED FRACTION IS 0.90, NOT 0.95, AND THAT IS A FINDING RATHER
        // THAN A LOOSENED BAR. Every one of the 37 declined frames comes from
        // TWO fixtures — 493.88 Hz (0/32) and 440 Hz (27/32) — and the design
        // itself says the 0.9 threshold "produces deliberate gaps where the
        // model declines to commit". Rather than delete those fixtures (which
        // would be tuning the corpus to pass) the trough is pinned by its own
        // leg, `theConfidenceTroughAroundB4IsPresentAndNarrow`. If that leg
        // moves, this number is expected to move with it.
        try measure(sungRange, name: "sung-range",
                    p95Ceiling: 30, maxCeiling: 45, minVoicedFraction: 0.90)
        // Leg 2 — the low register §5.6.5 warned about. Measured p95 29.5¢.
        try measure(lowRange, name: "low-range",
                    p95Ceiling: 35, maxCeiling: 50, minVoicedFraction: 0.95)

        // Leg 3 — silence must produce NO pitch at all. A tracker that reports
        // a pitch here is the phantom-note failure in its purest form.
        let quiet = try tracker.analyze(samples: Fixture.silence(seconds: 0.512),
                                        sampleRate: Fixture.rate)
        let quietVoiced = quiet.voiced.count
        report.notes.append("\(label)/silence: voiced \(quietVoiced)/\(quiet.observations.count)")
        if quietVoiced > 0 {
            report.failures.append("silence: \(quietVoiced) voiced frames")
        }

        // Leg 4 — every value handed back is a real number.
        for contourSamples in [Fixture.steady(220), Fixture.silence(seconds: 0.2), Fixture.noise(seconds: 0.2)] {
            let c = try tracker.analyze(samples: contourSamples, sampleRate: Fixture.rate)
            for o in c.observations {
                if let hz = o.frequencyHz, !(hz.isFinite && hz > 0) {
                    report.failures.append("non-finite or non-positive voiced pitch \(hz)")
                    break
                }
                if !o.confidence.isFinite {
                    report.failures.append("non-finite confidence")
                    break
                }
            }
        }
        return report
    }

    /// A tracker that is right about exactly one pitch and confident about
    /// everything, including silence. THE POSITIVE CONTROL for the battery.
    struct ConstantPitchTracker: PitchTracker {
        var frequency: Double = 220
        var analysisSampleRate: Double { 16_000 }
        var frameRate: Double { 62.5 }
        var detectableRange: ClosedRange<Double> { 46.875...2093.75 }

        func analyze(samples: [Float], sampleRate: Double,
                     options: PitchAnalysisOptions) throws -> PitchContour {
            let hop = SwiftF0PitchTracker.hopLength
            let count = samples.count / hop
            let observations = (0..<count).map { index in
                PitchObservation(timeSeconds: Double(index * hop) / 16_000,
                                 frequencyHz: frequency,
                                 confidence: 1.0,
                                 levelDbfs: -20,
                                 absence: nil)
            }
            return PitchContour(observations: observations, frameRate: 62.5,
                                analysisSampleRate: 16_000, sourceSampleRate: sampleRate,
                                options: options)
        }
    }

    @Test func swiftF0ClearsTheMeasuredAccuracyBar() throws {
        let report = try Self.runBattery(try SwiftF0PitchTracker(), label: "swiftf0")
        for note in report.notes { print("§5.5 \(note)") }
        #expect(report.failures.isEmpty, "\(report.failures)")
    }

    /// THE LEG THAT MAKES THE ONE ABOVE EVIDENCE. Without it, a battery whose
    /// ceilings were accidentally set to infinity would pass identically.
    @Test func aConstantTrackerFailsTheSameBattery() throws {
        let report = try Self.runBattery(ConstantPitchTracker(), label: "constant-220")
        for note in report.notes { print("§5.5 \(note)") }
        #expect(!report.failures.isEmpty, "a constant 220 Hz tracker must not pass the §5.5 battery")
        // …and it must fail for the RIGHT reasons, not incidentally.
        #expect(report.failures.contains { $0.hasPrefix("sung-range: p95") },
                "expected a pitch-accuracy failure, got \(report.failures)")
        #expect(report.failures.contains { $0.hasPrefix("silence:") },
                "expected a silence/voicing failure, got \(report.failures)")
    }

    // MARK: - Honest absence — the contract this item exists to establish

    /// ⛔⛔ THE CENTRAL MEASUREMENT OF m23-ap-2b. **SwiftF0 IS LEVEL-BLIND.**
    ///
    /// A 220 Hz tone at amplitude 1e-7 — about −140 dBFS, i.e. audibly and
    /// practically silence — comes back from the RAW model at confidence
    /// ~0.9999 on essentially every frame. A confidence-only voicing policy
    /// would therefore turn a fade tail, room tone, or the numerically-zero
    /// residue of a filtered band into a full contour of confident notes the
    /// singer never sang.
    ///
    /// This leg asserts BOTH halves, which is what makes it a measurement
    /// rather than an assumption: the raw pathology IS present, and the policy
    /// layer removes it.
    @Test func theModelIsLevelBlindAndThePolicyLayerCompensates() throws {
        let tracker = try SwiftF0PitchTracker()
        let whisper = Fixture.steady(220, amplitude: 1e-7)

        // (a) the pathology, on the raw model — the positive control.
        let raw = try tracker.detect(samples: whisper)
        let confident = raw.filter { $0.confidence >= 0.9 }
        #expect(confident.count > raw.count / 2,
                "the raw model should be confident on a −140 dBFS buffer; got \(confident.count)/\(raw.count)")

        // (b) the policy layer refuses to name a pitch there.
        let contour = try tracker.analyze(samples: whisper, sampleRate: Fixture.rate)
        #expect(contour.observations.count == raw.count)
        #expect(contour.voiced.isEmpty,
                "\(contour.voiced.count) phantom voiced frames at −140 dBFS")
        #expect(contour.observations.allSatisfy { $0.absence == .belowLevel })
        // The confidence is still REPORTED — the hole is readable, not merely present.
        #expect(contour.observations.contains { $0.confidence >= 0.9 })
    }

    /// The control in the other direction, and it is not optional: a level
    /// floor that also eats quiet singing would be a regression dressed as a
    /// fix. −40 dBFS is quiet but unambiguously real.
    @Test func aQuietButRealToneStaysVoiced() throws {
        let tracker = try SwiftF0PitchTracker()
        let contour = try tracker.analyze(samples: Fixture.steady(220, amplitude: 0.01),
                                          sampleRate: Fixture.rate)
        #expect(contour.voicedFraction > 0.95, "voiced fraction \(contour.voicedFraction)")
        let median = contour.voiced.compactMap(\.frequencyHz).sorted()[contour.voiced.count / 2]
        #expect(abs(Self.cents(median, from: 220)) < 15, "read \(median) Hz")
    }

    @Test func digitalSilenceIsAbsenceNotPitch() throws {
        let tracker = try SwiftF0PitchTracker()
        let contour = try tracker.analyze(samples: Fixture.silence(seconds: 0.512),
                                          sampleRate: Fixture.rate)
        #expect(contour.observations.count == 32)
        #expect(contour.voiced.isEmpty)
        // Digital silence has no dB value, and we report that as an absence too
        // rather than a fabricated floor (FileProfile.peakDb's rule).
        #expect(contour.observations.allSatisfy { $0.levelDbfs == nil })
        #expect(contour.observations.allSatisfy { $0.absence == .belowLevel })
        #expect(contour.observations.allSatisfy { $0.confidence.isFinite })
        // The raw model DOES emit a pitch here — 894–1946 Hz — which is exactly
        // the sentinel-shaped hazard the optional removes.
        let raw = try tracker.detect(samples: Fixture.silence(seconds: 0.512))
        #expect(raw.allSatisfy { $0.frequencyHz > 0 })
    }

    @Test func whiteNoiseIsNotVoiced() throws {
        let tracker = try SwiftF0PitchTracker()
        let contour = try tracker.analyze(samples: Fixture.noise(seconds: 0.512),
                                          sampleRate: Fixture.rate)
        // Noise is LOUD, so the level gate does not fire — this is the
        // confidence gate doing its own job, which is why the leg is separate.
        // Read from the constant, not a literal: a change to the default floor
        // must not silently desync this assertion from the policy it checks.
        #expect(contour.observations.allSatisfy {
            ($0.levelDbfs ?? -.infinity) > PitchAnalysisOptions.defaultSilenceFloorDbfs
        })
        #expect(contour.voiced.isEmpty, "\(contour.voiced.count) voiced frames on white noise")
        #expect(contour.observations.allSatisfy { $0.absence == .belowConfidence })
    }

    /// §5.5's "silence/breath gap" fixture. The gap must read as ABSENCE
    /// between two voiced runs — not as a pitch, and not as a missing frame.
    @Test func aBreathGapReadsAsAbsenceBetweenTwoVoicedRuns() throws {
        let tracker = try SwiftF0PitchTracker()
        var samples = Fixture.steady(220, seconds: 0.512)
        samples += Fixture.silence(seconds: 0.512)
        samples += Fixture.steady(330, seconds: 0.512)
        let contour = try tracker.analyze(samples: samples, sampleRate: Fixture.rate)
        #expect(contour.observations.count == 96)

        // The grid is intact: no frame was dropped to represent the gap.
        for (index, o) in contour.observations.enumerated() {
            #expect(abs(o.timeSeconds - Double(index) * 256.0 / 16_000.0) < 1e-9)
        }
        // Interiors only — the level gate and the model's longer analysis
        // window legitimately disagree by a frame at each edge.
        let first = contour.observations[2..<30]
        let gap = contour.observations[34..<62]
        let second = contour.observations[66..<94]
        #expect(first.allSatisfy { $0.isVoiced })
        #expect(gap.allSatisfy { !$0.isVoiced && $0.absence == .belowLevel })
        #expect(second.allSatisfy { $0.isVoiced })
        let firstMedian = first.compactMap(\.frequencyHz).sorted()[first.count / 2]
        let secondMedian = second.compactMap(\.frequencyHz).sorted()[second.count / 2]
        #expect(abs(Self.cents(firstMedian, from: 220)) < 15, "\(firstMedian) Hz")
        #expect(abs(Self.cents(secondMedian, from: 330)) < 15, "\(secondMedian) Hz")
    }

    /// No observation, anywhere in the corpus, carries a sentinel pitch — and
    /// the corpus provably contains BOTH voiced and unvoiced frames, so the
    /// assertion cannot pass by having nothing to check.
    @Test func noObservationEverCarriesASentinelPitch() throws {
        let tracker = try SwiftF0PitchTracker()
        var voicedSeen = 0
        var absentSeen = 0
        let corpus: [[Float]] = [
            Fixture.steady(220), Fixture.steady(98), Fixture.steady(523.25),
            Fixture.silence(seconds: 0.3), Fixture.noise(seconds: 0.3),
            Fixture.steady(440, amplitude: 1e-7),
        ]
        for samples in corpus {
            let contour = try tracker.analyze(samples: samples, sampleRate: Fixture.rate)
            for o in contour.observations {
                #expect((o.frequencyHz == nil) == (o.absence != nil))
                if let hz = o.frequencyHz {
                    voicedSeen += 1
                    #expect(hz.isFinite && hz > 0, "sentinel-shaped pitch \(hz)")
                    #expect(hz != 0 && hz != -1)
                } else {
                    absentSeen += 1
                }
            }
        }
        // Measured: exactly 96 voiced (the three steady tones, 32 frames each)
        // and 68 absent (silence 18, noise 18, the −140 dBFS whisper 32).
        // Pinned with margin — the point is that BOTH populations are large, so
        // the assertions above cannot pass by having nothing to inspect.
        #expect(voicedSeen >= 90, "corpus produced \(voicedSeen) voiced frames")
        #expect(absentSeen >= 60, "corpus produced \(absentSeen) absent frames")
    }

    // MARK: - Musical behaviour (§5.5's named fixtures)

    /// §5.5 asks for vibrato at 4/5/6 Hz. The property that matters is that the
    /// detector FOLLOWS the excursion rather than averaging it into a straight
    /// line — an averaging detector would look excellent on a cents-error
    /// metric and be useless for pitch editing.
    @Test func vibratoIsFollowedRatherThanAveraged() throws {
        let tracker = try SwiftF0PitchTracker()
        for rate in [4.0, 5.0, 6.0] {
            let samples = Fixture.tone(seconds: 1.0) { t in
                220 * pow(2, (60.0 / 1200.0) * sin(2 * .pi * rate * t))
            }
            let contour = try tracker.analyze(samples: samples, sampleRate: Fixture.rate)
            #expect(contour.voicedFraction > 0.95, "\(rate) Hz vibrato: \(contour.voicedFraction)")
            let hz = contour.voiced.compactMap(\.frequencyHz)
            let excursion = Self.cents(hz.max()!, from: hz.min()!)
            // The fixture sweeps ±60 cents = 120 cents peak-to-peak. Anything
            // above 80 proves tracking; a smoothed/averaged contour collapses.
            #expect(excursion > 80, "\(rate) Hz vibrato excursion was \(excursion) cents")
            #expect(excursion < 200, "\(rate) Hz vibrato excursion \(excursion) cents — overshoot")
        }
    }

    @Test func anOctaveLeapIsFollowed() throws {
        let tracker = try SwiftF0PitchTracker()
        let samples = Fixture.tone(seconds: 1.024) { t in t < 0.512 ? 220 : 440 }
        let contour = try tracker.analyze(samples: samples, sampleRate: Fixture.rate)
        let before = contour.observations[2..<30].compactMap(\.frequencyHz)
        let after = contour.observations[34..<62].compactMap(\.frequencyHz)
        #expect(before.count > 25 && after.count > 25)
        #expect(abs(Self.cents(before.sorted()[before.count / 2], from: 220)) < 15)
        #expect(abs(Self.cents(after.sorted()[after.count / 2], from: 440)) < 15)
    }

    @Test func aGlideIsTrackedMonotonically() throws {
        let tracker = try SwiftF0PitchTracker()
        // 200 -> 400 Hz over one second, exponential so it is linear in cents.
        let samples = Fixture.tone(seconds: 1.0) { t in 200 * pow(2, t) }
        let contour = try tracker.analyze(samples: samples, sampleRate: Fixture.rate)
        let hz = contour.observations.compactMap(\.frequencyHz)
        #expect(contour.voicedFraction > 0.9, "\(contour.voicedFraction)")
        // Monotone up to the ~26-cent output grid: no step may fall by more
        // than one grid cell, which is what a real tracking failure looks like.
        var regressions = 0
        for i in 1..<hz.count where Self.cents(hz[i], from: hz[i - 1]) < -35 { regressions += 1 }
        #expect(regressions == 0, "\(regressions) downward steps in a rising glide")
        #expect(abs(Self.cents(hz.first!, from: 200)) < 40, "glide started at \(hz.first!) Hz")
        #expect(abs(Self.cents(hz.last!, from: 400)) < 40, "glide ended at \(hz.last!) Hz")
    }

    // MARK: - Characterisation: what this artefact CANNOT do
    //
    // These legs assert that a DEFECT IS PRESENT and bounded. They redden if
    // the model gets better as well as worse — which is the right shape for a
    // frozen artefact whose runtime is pinned `exact:` and whose weights are
    // pinned by SHA256. If one reddens, the first question is "what did we
    // bump?", not "what did we break?".

    /// ⛔⛔ **§5.5's "≥99 % of voiced frames within ±10 cents" IS UNREACHABLE BY
    /// CONSTRUCTION, AND THIS LEG IS THE PROOF.**
    ///
    /// SwiftF0's output is an argmax over a fixed set of log-spaced frequency
    /// bins (46.875–2093.75 Hz), so the reported pitch is QUANTISED. Sweeping
    /// the input in 10-cent steps produces flat runs and ~26-cent jumps: the
    /// error is a deterministic function of where the input falls between bins,
    /// not noise that averaging or a better fixture could reduce.
    ///
    /// The consequence for the design is recorded rather than resolved here:
    /// the ±10-cent bar was written before anyone had measured the output grid,
    /// and adjudicating it (accept the artefact's real accuracy, or take
    /// §5.6.6's fallback ladder) is not a test's decision to make.
    @Test func theOutputIsQuantisedSoTenCentAccuracyIsUnreachable() throws {
        let tracker = try SwiftF0PitchTracker()
        var detected: [Double] = []
        for step in 0..<24 {
            let f = 200.0 * pow(2, Double(step) * 10.0 / 1200.0)
            let contour = try tracker.analyze(samples: Fixture.steady(f, seconds: 0.256),
                                              sampleRate: Fixture.rate)
            let voiced = contour.voiced.compactMap(\.frequencyHz).sorted()
            guard !voiced.isEmpty else { continue }
            detected.append(voiced[voiced.count / 2])
        }
        #expect(detected.count == 24)
        // The signature of a grid is a CLUSTERED output distribution: inputs a
        // uniform 10 cents apart come back bunched, with near-zero gaps inside
        // a cluster and ~26-cent jumps between clusters. A detector with true
        // sub-bin resolution would return 23 gaps all near 10 cents.
        //
        // MEASURED on these 24 fixtures: 11 of 23 gaps under 3 cents (8 of them
        // under 1 cent), 6 gaps at or above 20 cents, largest 31.59 cents.
        let sorted = detected.sorted()
        var gaps: [Double] = []
        for i in 1..<sorted.count { gaps.append(Self.cents(sorted[i], from: sorted[i - 1])) }
        let tight = gaps.filter { $0 < 3 }.count
        let jumps = gaps.filter { $0 >= 20 }.count
        #expect(tight >= 6, "only \(tight) of \(gaps.count) gaps were under 3 cents — the grid did not show")
        #expect(jumps >= 3, "only \(jumps) gaps of 20+ cents; largest was \(gaps.max() ?? 0)")
        #expect((gaps.max() ?? 0) >= 25,
                "largest inter-cluster jump was \(gaps.max() ?? 0) cents")
    }

    /// §5.6.5's second clause — "no octave-up frame may carry confidence above
    /// the median confidence of correct frames" — **is FALSE for this model**,
    /// and this leg pins the counter-example so nobody re-derives it.
    ///
    /// It is false in a DIFFERENT register than §5.6.5 predicted: the reported
    /// failure was 80–110 Hz weak-fundamental phonation, which measures clean
    /// here (see the next leg). The reproducible case is a four-partial tone
    /// around 233.88 Hz, whose octave-up frames arrive at confidence 0.90–0.99.
    /// **Confidence gates voicing; it does not gate octave correctness.**
    @Test func octaveErrorsSurviveTheConfidenceGate() throws {
        let tracker = try SwiftF0PitchTracker()
        let reference = 233.88
        let contour = try tracker.analyze(
            samples: Fixture.steady(reference, seconds: 0.512, partials: 4),
            sampleRate: Fixture.rate)
        let voiced = contour.voiced
        #expect(!voiced.isEmpty)
        let octaveUp = voiced.filter {
            guard let hz = $0.frequencyHz else { return false }
            return abs(Self.cents(hz, from: reference) - 1200) <= 150
        }
        #expect(!octaveUp.isEmpty,
                "the octave-error case did not reproduce — re-measure before relaxing this")
        #expect(octaveUp.allSatisfy { $0.confidence >= 0.9 },
                "octave-up frames arrive at high confidence; that is the point of this leg")
    }

    /// ⛔ **A CONFIDENCE TROUGH NOBODY HAD RECORDED, AND IT IS NARROW.**
    ///
    /// On a 12-partial voice-like tone every pitch from 82 Hz to 659 Hz reads
    /// at confidence ≥ 0.994 — EXCEPT a narrow band around A4/B4: 440 Hz reads
    /// median 0.952 (min 0.827, so 5 of 32 frames fall under the 0.9 policy
    /// threshold) and **493.88 Hz reads median 0.815 (min 0.509), so ALL 32
    /// frames are declined**. 523.25 Hz is back at 0.998.
    ///
    /// This is why `runBattery`'s sung-range voiced fraction is 0.90 rather
    /// than 0.95: the shortfall is not spread thinly, it is two fixtures. The
    /// trough is asserted here so the battery's number has a named cause, and
    /// so that a weights or runtime change which moves it reddens something
    /// specific instead of quietly shifting a percentage.
    ///
    /// ⚠️ WHAT THIS IS NOT: it is not an accuracy problem. Where the model does
    /// commit near 440 Hz it is within 10 cents. It is a VOICING-RECALL dent,
    /// which is the error class §5.6.1 says matters most ("the user cannot drag
    /// a note that was never proposed"), so it is worth watching on real vocal
    /// material — a sustained B4 is an ordinary thing for a singer to do.
    @Test func theConfidenceTroughAroundB4IsPresentAndNarrow() throws {
        let tracker = try SwiftF0PitchTracker()
        func medianConfidence(_ f: Double) throws -> Double {
            let contour = try tracker.analyze(samples: Fixture.steady(f), sampleRate: Fixture.rate)
            let confs = contour.observations.map(\.confidence).sorted()
            return confs[confs.count / 2]
        }
        // The trough is present…
        let atB4 = try medianConfidence(493.88)
        #expect(atB4 < 0.9, "B4 median confidence \(atB4) — the trough has moved; re-measure the battery")
        // …and it is NARROW: its neighbours a few semitones away are confident.
        for neighbour in [392.0, 523.25, 587.33] {
            let c = try medianConfidence(neighbour)
            #expect(c > 0.95, "\(neighbour) Hz median confidence \(c) — the trough has widened")
        }
        // …and it is a voicing dent, not an accuracy one: the frames the model
        // DOES commit to near the trough are still right.
        let contour = try tracker.analyze(samples: Fixture.steady(440), sampleRate: Fixture.rate)
        let voiced = contour.voiced.compactMap(\.frequencyHz).sorted()
        #expect(!voiced.isEmpty, "440 Hz produced no voiced frames at all")
        #expect(abs(Self.cents(voiced[voiced.count / 2], from: 440)) < 15,
                "440 Hz read \(voiced[voiced.count / 2]) Hz where it committed")
    }

    /// §5.6.5's low-F0 weak-fundamental leg, with H2 louder than H1 — the
    /// `Syrinx` #81 failure mode, synthesised where the H1/H2 balance is a dial.
    ///
    /// ⚠️ MEASURED CLEAN: zero octave-up frames at 82.41 / 98 / 110 Hz. The leg
    /// is therefore reported as **not reproduced**, and §5.6.5's second clause
    /// is UNTESTED here (a clause about octave-up frames is vacuous when there
    /// are none). It is asserted as a fixture-behaviour pin, not as a pass.
    @Test func theLowF0WeakFundamentalCaseDoesNotReproduce() throws {
        let tracker = try SwiftF0PitchTracker()
        for f in [82.41, 98.0, 110.0] {
            // H1 at 0.3, H2 at 1.0 — the fundamental is the weaker partial.
            let n = Int(0.512 * Fixture.rate)
            var out = [Double](repeating: 0, count: n)
            let weights = [0.3, 1.0, 0.6, 0.4, 0.3, 0.2, 0.15, 0.1]
            for (index, w) in weights.enumerated() {
                let fk = f * Double(index + 1)
                guard fk < Fixture.rate / 2 else { break }
                for i in 0..<n { out[i] += w * sin(2 * .pi * fk * Double(i) / Fixture.rate) }
            }
            let peak = out.map(abs).max() ?? 1
            let samples = out.map { Float($0 * 0.5 / peak) }
            let contour = try tracker.analyze(samples: samples, sampleRate: Fixture.rate)
            #expect(contour.voicedFraction > 0.95, "\(f) Hz: \(contour.voicedFraction)")
            let octaveUp = contour.voiced.filter {
                guard let hz = $0.frequencyHz else { return false }
                return abs(Self.cents(hz, from: f) - 1200) <= 150
            }
            #expect(octaveUp.isEmpty,
                    "\(f) Hz weak-fundamental produced \(octaveUp.count) octave-up frames — §5.6.5 reproduced; re-open it")
        }
    }

    // MARK: - Input conditioning (48 k → 16 k)

    /// The conversion must not move the pitch. This compares a 48 kHz fixture
    /// against the SAME tone generated natively at 16 kHz — so a conversion
    /// defect shows as a difference between two readings rather than as an
    /// absolute error somebody could argue about.
    @Test func fortyEightKilohertzInputReadsTheSameAsNativeSixteen() throws {
        let tracker = try SwiftF0PitchTracker()
        for f in [110.0, 220.0, 440.0] {
            let native = try tracker.analyze(samples: Fixture.steady(f, seconds: 1.0),
                                             sampleRate: 16_000)
            let converted = try tracker.analyze(
                samples: Fixture.steady(f, seconds: 1.0, sampleRate: 48_000),
                sampleRate: 48_000)
            #expect(converted.observations.count == native.observations.count)
            #expect(converted.sourceSampleRate == 48_000)
            #expect(converted.analysisSampleRate == 16_000)
            let a = native.voiced.compactMap(\.frequencyHz).sorted()
            let b = converted.voiced.compactMap(\.frequencyHz).sorted()
            #expect(!a.isEmpty && !b.isEmpty)
            let delta = Self.cents(b[b.count / 2], from: a[a.count / 2])
            #expect(abs(delta) < 1.0, "\(f) Hz: 48k read \(delta) cents from the 16k reading")
        }
    }

    /// A 10 kHz tone at 48 kHz is above the 16 kHz analysis Nyquist. If the
    /// conversion did not band-limit it, it would fold down into the sung range
    /// and read as a confident pitch — a phantom note manufactured by our own
    /// input stage. Measured rejection is −155 dB, and the level floor then
    /// refuses what is left.
    @Test func outOfBandContentDoesNotBecomeAPhantomPitch() throws {
        let tracker = try SwiftF0PitchTracker()
        let tone: [Float] = (0..<48_000).map { index in
            Float(0.5 * sin(2 * .pi * 10_000 * Double(index) / 48_000))
        }
        let contour = try tracker.analyze(samples: tone, sampleRate: 48_000)
        #expect(!contour.observations.isEmpty)
        #expect(contour.voiced.isEmpty, "\(contour.voiced.count) phantom voiced frames from a 10 kHz tone")
        // The control: the SAME tone in band (3 kHz at 48 k survives conversion)
        // is not silenced — so the leg above is band-limiting, not a dead path.
        let inBand: [Float] = (0..<48_000).map { index in
            Float(0.5 * sin(2 * .pi * 3_000 * Double(index) / 48_000))
        }
        let audible = try tracker.analyze(samples: inBand, sampleRate: 48_000)
        #expect(audible.observations.contains { ($0.levelDbfs ?? -200) > -20 },
                "the 3 kHz control was silenced too — the rejection leg proves nothing")
    }

    /// The conversion loop hands the converter one input buffer and drains the
    /// output in 16,384-frame chunks. Every other leg in this suite uses about
    /// a second of audio, which fits in ONE chunk — so without this leg the
    /// loop past its first iteration, and the `maxIterations` bound, would ship
    /// untested. A 10-second 48 kHz buffer needs ten chunks, and it is the
    /// shape `clip.detectPitch` (m23-ap-3) will hand it on day one.
    @Test func aMultiChunkBufferConvertsWithoutTruncationOrDrift() throws {
        let tracker = try SwiftF0PitchTracker()
        let seconds = 10.0
        let samples = Fixture.steady(220, seconds: seconds, sampleRate: 48_000)
        #expect(samples.count == 480_000)
        let contour = try tracker.analyze(samples: samples, sampleRate: 48_000)

        // Nothing was truncated: 10 s at 62.5 fps is 625 frames, and the frame
        // count must follow the DURATION, not the chunk boundary (a loop that
        // stopped after one chunk would yield ~64).
        #expect(contour.observations.count == 625, "\(contour.observations.count) frames")
        #expect(abs(contour.observations.last!.timeSeconds - 9.984) < 1e-9)
        #expect(contour.voicedFraction > 0.95, "\(contour.voicedFraction)")

        // …and no drift across chunk seams: the last second reads the same
        // pitch as the first. A dropped or duplicated chunk would show up here
        // as a discontinuity rather than as a wrong count.
        let head = contour.observations[10..<60].compactMap(\.frequencyHz).sorted()
        let tail = contour.observations[565..<615].compactMap(\.frequencyHz).sorted()
        #expect(head.count > 45 && tail.count > 45)
        #expect(abs(Self.cents(tail[tail.count / 2], from: head[head.count / 2])) < 2,
                "head \(head[head.count / 2]) Hz vs tail \(tail[tail.count / 2]) Hz")
    }

    @Test func onsetTimingSurvivesResampling() throws {
        let tracker = try SwiftF0PitchTracker()
        var samples = [Float](repeating: 0, count: 24_000)     // 0.5 s at 48 k
        samples += Fixture.steady(220, seconds: 0.5, sampleRate: 48_000)
        let contour = try tracker.analyze(samples: samples, sampleRate: 48_000)
        let index = contour.observations.firstIndex { $0.isVoiced }
        let firstVoiced = try #require(index)
        // 0.5 s at 62.5 fps = frame 31.25.
        #expect(abs(firstVoiced - 31) <= 1, "first voiced frame was \(firstVoiced)")
        #expect(contour.observations[0..<30].allSatisfy { !$0.isVoiced })
    }

    // MARK: - The seam itself

    @Test func theSeamReportsItsOwnGeometry() throws {
        let tracker: any PitchTracker = try SwiftF0PitchTracker()
        #expect(tracker.analysisSampleRate == 16_000)
        #expect(tracker.frameRate == 62.5)
        #expect(tracker.detectableRange.lowerBound == 46.875)
        #expect(tracker.detectableRange.upperBound == 2093.75)
    }

    @Test func aBufferShorterThanOneFrameIsRefusedThroughTheSeam() throws {
        let tracker = try SwiftF0PitchTracker()
        #expect(throws: PitchTrackerError.self) {
            _ = try tracker.analyze(samples: [Float](repeating: 0.1, count: 8), sampleRate: 16_000)
        }
        #expect(throws: PitchTrackerError.self) {
            _ = try tracker.analyze(samples: Fixture.steady(220), sampleRate: 0)
        }
    }

    /// A caller-narrowed range is honoured, and a frame the model names outside
    /// it becomes an absence with its own reason rather than a clamped value.
    @Test func aNarrowedRangeReportsOutOfRangeRatherThanClamping() throws {
        let tracker = try SwiftF0PitchTracker()
        var options = PitchAnalysisOptions()
        options.frequencyRange = 300...800
        let contour = try tracker.analyze(samples: Fixture.steady(220),
                                          sampleRate: Fixture.rate, options: options)
        #expect(contour.voiced.isEmpty)
        #expect(contour.observations.allSatisfy { $0.absence == .outOfRange })
        #expect(contour.options.frequencyRange == 300...800)
    }
}
