import Foundation

/// m31-f ② — **"does this instrument have more than one timbre?"**, as a
/// measurement an agent that cannot hear can act on.
///
/// WHY THIS EXISTS. A user listened to an M31 dogfood render and said the sax
/// "sounded awful, like a toy instrument". Three full cycles of green tests had
/// said nothing, because no gate in this tree can hear. But the specific thing
/// that makes a sampled instrument read as a toy IS measurable: on a real
/// acoustic instrument, playing harder changes the SPECTRUM as well as the
/// level — a saxophone leaned on throws far more upper-harmonic energy and its
/// spectral centroid roughly doubles from pp to ff. A single-sample instrument
/// just gets louder. Loudness moves; timbre does not.
///
/// This is the Swift twin of `scripts/probes/timbre-liveness.sh` (deliverable
/// ①). The shell probe measures a WAV you already rendered; this one is reached
/// from the wire (`instrument.probeLiveness` → `instrument_probe_liveness`), so
/// an agent can refuse a dead patch BEFORE building a whole arrangement on it.
///
/// WHAT IT CANNOT DO, stated plainly so nobody over-reads it: this measures
/// LIVELINESS, not quality. It cannot tell you an instrument is out of tune, is
/// the wrong articulation, or is simply ugly-but-dynamic. Taste is not on the
/// wire. Deadness is.
///
/// ## Why the DSP is hand-rolled here
///
/// `AudioContentAnalyzer.spectralBalance` (DAWEngine) already computes a
/// power-weighted spectral centroid over an Accelerate FFT, and reusing it
/// would be the first instinct. It is not reachable: DAWControl depends on
/// DAWCore and AIServices ONLY (Package.swift:163) — not DAWEngine — so a
/// control verb can only call into DAWCore, and DAWCore is deliberately
/// Foundation-only (`Loudness.swift:223`: "No Accelerate, no libebur128 —
/// DAWCore stays dependency-free"). BS.1770 is hand-rolled in this module for
/// exactly that reason, and this ~60 lines of Hann/FFT/centroid follows the
/// same precedent rather than inverting the module graph for it. The
/// consequence to keep in mind: this centroid is NOT numerically identical to
/// ffmpeg's `aspectralstats` or to `AudioContentAnalyzer`'s — different window
/// geometry gives different absolute Hz. **Compare spreads and shapes across
/// rungs measured by THIS code; never compare an absolute Hz reading here to
/// one from another tool.**
public enum TimbreLiveness {

    // MARK: - Geometry

    /// STFT geometry for the centroid. 4096 pt at 48 kHz is 85 ms — long
    /// enough that the bin width (11.7 Hz) resolves the partials of any
    /// melodic pitch, short enough that a 0.6 s analysis window still averages
    /// several frames.
    public static let fftSize = 4096
    public static let hopSize = 2048

    /// dB floor for level fields (JSON has no −inf) — the
    /// `MasterAnalysisSnapshot.floorDB` convention, one octave lower because a
    /// pp velocity rung on a quiet patch legitimately sits near −60 dB and
    /// must not be confused with silence.
    public static let floorDb = -120.0

    /// A rung whose window RMS sits at/below this reads as SILENT — the probe
    /// could not measure it, which is a different answer from "static".
    public static let silenceDb = -90.0

    // MARK: - Thresholds (NOT calibrated — see `Thresholds`)

    /// Below this centroid spread, and with a single detected timbre group,
    /// the verdict is STATIC.
    ///
    /// ⚠️ **THIS NUMBER IS A HYPOTHESIS, NOT A CALIBRATED RULE.** It came from
    /// ONE instrument family (Apple `gs_instruments.dls`, measured 0.05 %
    /// against GeneralUser GS's 6.59 %). It is echoed in every response
    /// (`thresholds`) precisely so a caller can disagree with it from the raw
    /// table rather than inherit it silently.
    ///
    /// ⭐⭐ **VALIDATED AGAINST REAL INSTRUMENTS 2026-08-28, AND THAT RUN
    /// FOUND A BUG THIS THRESHOLD WAS HIDING.** Measured live on staging,
    /// same pitch, velocities 25/60/95/127, AFTER the magnitude-weighting fix
    /// in `centroid(of:sampleRate:)`:
    ///
    ///     Apple GM DLS alto sax   2165 / 2167 / 2165 / 2167 Hz   0.089 %  STATIC
    ///     GeneralUser GS alto sax 2371 / 2489 / 2557 / 2557 Hz   7.87  %  LIVE
    ///
    /// Both verdicts are now correct, both agree with the independent ffmpeg
    /// reference within ~6 % on absolutes, and the LIVE case resolves into
    /// THREE distinct timbre groups with v95 and v127 sharing one — which
    /// independently reproduces a layer structure first observed months
    /// earlier with a different tool. The 5 % boundary sits comfortably
    /// between 0.089 % and 7.87 %, so it separates these two cleanly.
    ///
    /// ⚠️ It is still a hypothesis for everything ELSE. Two instruments do not
    /// calibrate a threshold; they only show it is not obviously wrong. The
    /// raw ladder rides in every response so a caller can disagree.
    ///
    /// ⛔⛔ **AN EARLIER VERSION OF THIS COMMENT SAID THE OPPOSITE AND WOULD
    /// HAVE PREVENTED ANYONE FROM FINDING THE BUG.** It recorded that this
    /// implementation disagreed with ffmpeg by "a few percent", declared this
    /// one "the accurate one" on the strength of a pure-sine check, and told
    /// the reader not to be alarmed. Every clause was defensible and the
    /// conclusion was wrong: the real disagreement was a FACTOR OF 2-3, it
    /// was caused by power-weighting, and the reassurance would have talked
    /// the next reader out of investigating. **A comment that explains away a
    /// discrepancy is a load-bearing claim and needs the same evidence as
    /// code.** Left recorded rather than quietly rewritten.
    public static let staticCentroidSpreadPercent = 5.0

    /// A ladder whose RMS barely moves has not tested velocity at all
    /// (patch ignoring velocity, limiter in the chain, notes not actually
    /// differing) — that is INCONCLUSIVE, never STATIC.
    public static let minimumRMSSpreadDb = 6.0

    /// Two adjacent rungs whose centroids differ by less than this (relative)
    /// are the SAME velocity layer. Measured same-layer noise on Apple's DLS
    /// was 0.05 %; distinct GeneralUser layers differed by 40 %+, so 2 % sits
    /// in a very wide empty band.
    public static let timbreGroupTolerancePercent = 2.0

    /// The self positive-control tones. A flat centroid across velocities is
    /// EXACTLY the shape a broken measurement produces, so the meter must be
    /// shown to move before a flat reading is allowed to mean anything.
    public static let selfCheckLowHz = 440.0
    public static let selfCheckHighHz = 1760.0
    public static let selfCheckSeconds = 1.0

    // MARK: - Wire shapes (Codable IS the wire — the `Loudness.swift` rule)

    public enum Verdict: String, Codable, Sendable {
        /// Level moved, timbre did not: one sample with a volume knob.
        case `static`
        /// Velocity changes the tone, not just the volume.
        case live
        /// The ladder did not move the level enough to test the question.
        case inconclusive
        /// At least one rung produced no measurable signal — the probe could
        /// not measure this patch. **NOT the same answer as `static`**: a
        /// tool that never looked and a tool that looked and found nothing
        /// must not produce the same output.
        case silent
    }

    /// The meter's proof that it can discriminate, carried in EVERY response.
    /// This is the field that distinguishes "measured, and it is flat" from
    /// "the measurement is broken and flat is what broken looks like".
    public struct SelfCheck: Codable, Sendable, Equatable {
        public let passed: Bool
        public let lowToneHz: Double
        public let lowToneCentroidHz: Double?
        public let highToneHz: Double
        public let highToneCentroidHz: Double?
        /// The rule the two readings had to satisfy, in words.
        public let rule: String
    }

    /// One velocity rung.
    public struct Rung: Codable, Sendable, Equatable {
        public let velocity: Int
        /// Window RMS in dB (floored at `floorDb`; JSON has no −inf).
        public let rmsDb: Double
        /// Power-weighted spectral centroid. **nil when the rung produced no
        /// measurable signal** — never 0, which would read as "very dark" and
        /// would silently drag the spread.
        public let centroidHz: Double?
        /// 1-based index of the detected timbre group (velocity layer) this
        /// rung belongs to; nil for a silent rung. Two rungs sharing a group
        /// share a layer.
        public let timbreGroup: Int?
    }

    /// The thresholds the verdict was computed with, echoed so a caller can
    /// re-derive a different verdict from the same table.
    public struct Thresholds: Codable, Sendable, Equatable {
        public let staticCentroidSpreadPercent: Double
        public let minimumRMSSpreadDb: Double
        public let timbreGroupTolerancePercent: Double
        public let calibrated: Bool
    }

    /// The whole answer. `ladder` is the evidence; everything else is a
    /// summary of it, and the summary is allowed to be wrong.
    public struct Result: Codable, Sendable, Equatable {
        public let trackId: String
        public let instrumentKind: String?
        public let instrumentDetail: String?
        public let pitch: Int
        public let noteSeconds: Double
        public let sampleRate: Double
        /// Proof the meter moves, on this very run.
        public let selfCheck: SelfCheck
        public let ladder: [Rung]
        public let rmsSpreadDb: Double?
        public let centroidSpreadPercent: Double?
        /// How many DISTINCT timbres the ladder found — the layer count, and
        /// the single most informative number here. 1 means one sample.
        ///
        /// A LOWER BOUND at these velocities: four rungs cannot see a fifth
        /// layer, and two layers that happen to share a centroid read as one.
        public let distinctTimbreCount: Int
        public let verdict: Verdict
        public let summary: String
        public let thresholds: Thresholds
        public let caveats: [String]
    }

    /// Refusals. `meterSelfCheckFailed` is deliberately an ERROR and not a
    /// verdict: reporting deadness from a meter that cannot discriminate is
    /// the single worst failure this tool could have, because it is
    /// indistinguishable from a true finding.
    public enum ProbeError: Error, LocalizedError, Equatable {
        case meterSelfCheckFailed(lowHz: Double?, highHz: Double?)
        case emptyRender
        case noVelocities

        public var errorDescription: String? {
            switch self {
            case let .meterSelfCheckFailed(low, high):
                let lowText = low.map { String(format: "%.1f", $0) } ?? "no reading"
                let highText = high.map { String(format: "%.1f", $0) } ?? "no reading"
                return "the spectral-centroid meter failed its own positive control"
                    + " (a \(Int(selfCheckLowHz)) Hz tone read \(lowText) Hz, a"
                    + " \(Int(selfCheckHighHz)) Hz tone read \(highText) Hz; the high tone"
                    + " must read more than twice the low one). No liveness verdict was"
                    + " produced: a flat centroid is exactly the shape a BROKEN measurement"
                    + " makes, so a reading from a meter that cannot discriminate is not"
                    + " evidence of anything."
            case .emptyRender:
                return "the velocity-ladder render produced no audio frames at all"
                    + " — nothing to measure."
            case .noVelocities:
                return "a velocity ladder needs at least two velocities."
            }
        }
    }

    // MARK: - Window measurement

    /// Mono mixdown (channel average) of a rendered buffer. Offline only.
    public static func mono(_ audio: RenderedAudio) -> [Float] {
        guard let first = audio.channelData.first else { return [] }
        if audio.channelData.count == 1 { return first }
        var out = [Float](repeating: 0, count: first.count)
        for channel in audio.channelData {
            let n = min(out.count, channel.count)
            for i in 0..<n { out[i] += channel[i] }
        }
        let scale = Float(1.0 / Double(audio.channelData.count))
        for i in out.indices { out[i] *= scale }
        return out
    }

    /// RMS (dB) and power-weighted spectral centroid (Hz) over one window.
    ///
    /// This is the ONE measurement home: the ladder rungs AND the self
    /// positive-control both come through here, so the control genuinely
    /// exercises the code the verdict depends on rather than a parallel
    /// implementation that could stay healthy while this one rots.
    public static func measureWindow(
        _ samples: [Float], from startSeconds: Double, seconds: Double, sampleRate: Double
    ) -> (rmsDb: Double, centroidHz: Double?) {
        guard sampleRate > 0, seconds > 0, !samples.isEmpty else { return (floorDb, nil) }
        let start = max(0, Int((startSeconds * sampleRate).rounded()))
        let end = min(samples.count, start + Int((seconds * sampleRate).rounded()))
        guard end > start else { return (floorDb, nil) }
        let window = Array(samples[start..<end])

        var sumSquares = 0.0
        for value in window where value.isFinite { sumSquares += Double(value) * Double(value) }
        let rms = (sumSquares / Double(window.count)).squareRoot()
        let rmsDb = rms > 0 ? max(floorDb, 20 * log10(rms)) : floorDb

        return (rmsDb, centroid(of: window, sampleRate: sampleRate))
    }

    /// Mean MAGNITUDE spectrum over Hann-windowed frames → the standard
    /// magnitude-weighted spectral centroid, Σ(f·|X(f)|) / Σ|X(f)|.
    ///
    /// ⚠️⚠️ **THIS WAS POWER-WEIGHTED (|X|²) UNTIL 2026-08-28 AND IT PRODUCED A
    /// CONFIDENT WRONG ANSWER ON REAL MATERIAL.** Squaring over-weights the
    /// fundamental — which barely moves between velocity layers — and
    /// under-weights the upper harmonics, which is exactly where layers
    /// differ. MEASURED on ONE bounced GeneralUser GS sax ladder, analysed by
    /// both meters (RMS agreed to two decimals, so the render was identical
    /// and only the analysis differed):
    ///
    ///     meter                 v25     v60     v95    v127   spread  verdict
    ///     magnitude (ffmpeg)   2236.6  2331.4  2383.7 2383.9   6.59 %  LIVE
    ///     power     (old)       794.4   796.6   796.7  796.7   0.295 % STATIC
    ///
    /// A 22× compression, and the verdict FLIPPED on the very instrument this
    /// probe exists to tell apart: it called a genuinely layered saxophone
    /// "velocity is a volume knob… it will read as lifeless."
    ///
    /// ⭐⭐⭐ **AND THE SELF-CHECK COULD NOT HAVE CAUGHT IT — THAT IS THE REAL
    /// LESSON.** The positive control measures PURE SINES, and a pure sine has
    /// exactly ONE partial, so power- and magnitude-weighting agree to the
    /// digit (both read 440.0000000 Hz). **A control built from a signal
    /// simpler than the signal under test can be structurally blind to a whole
    /// class of error while passing perfectly.** The control proved the meter
    /// could discriminate FREQUENCY; nothing proved it weighted a HARMONIC
    /// SPECTRUM the way the calibration did. Only measuring a real instrument
    /// found it.
    /// nil when the window carries no finite power (silence): 0 Hz would read
    /// as "very dark" and quietly drag every spread computed from it.
    public static func centroid(of samples: [Float], sampleRate: Double) -> Double? {
        guard sampleRate > 0, samples.count >= 64 else { return nil }
        let n = min(fftSize, largestPowerOfTwo(atMost: samples.count))
        guard n >= 64 else { return nil }
        let half = n / 2
        let hop = max(1, min(hopSize, n / 2))
        let window = hann(n)

        var meanMagnitude = [Double](repeating: 0, count: half)
        var frames = 0
        var offset = 0
        while offset + n <= samples.count {
            var real = [Double](repeating: 0, count: n)
            var imaginary = [Double](repeating: 0, count: n)
            for i in 0..<n {
                let value = Double(samples[offset + i])
                real[i] = value.isFinite ? value * window[i] : 0
            }
            fft(real: &real, imaginary: &imaginary)
            for bin in 0..<half {
                let power = real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                // Magnitude, accumulated PER FRAME. Summing power and taking
                // one square root at the end is a different (power-weighted)
                // quantity — that was the bug.
                if power.isFinite { meanMagnitude[bin] += power.squareRoot() }
            }
            frames += 1
            offset += hop
        }
        guard frames > 0 else { return nil }

        let binHz = sampleRate / Double(n)
        var weighted = 0.0
        var total = 0.0
        // Bin 0 (DC) is skipped: a DC offset is not brightness, and on a
        // near-silent rung it would dominate the weighting.
        for bin in 1..<half {
            let magnitude = meanMagnitude[bin]
            guard magnitude > 0, magnitude.isFinite else { continue }
            weighted += magnitude * Double(bin) * binHz
            total += magnitude
        }
        guard total > 0 else { return nil }
        let value = weighted / total
        return value.isFinite ? value : nil
    }

    // MARK: - Self positive-control

    /// Measures a synthesised `selfCheckLowHz` and `selfCheckHighHz` tone
    /// THROUGH `measureWindow`, and requires the high tone to read more than
    /// twice the low one.
    ///
    /// ⭐ The whole point: prove the meter can move before reporting that it
    /// did not. Run at the SAME sample rate as the ladder, so a rate-dependent
    /// break (a bin-width bug, a wrong `binHz`) cannot pass the control and
    /// then corrupt the ladder.
    public static func selfCheck(sampleRate: Double) -> SelfCheck {
        let low = centroid(of: sine(hz: selfCheckLowHz, seconds: selfCheckSeconds,
                                    sampleRate: sampleRate),
                           sampleRate: sampleRate)
        let high = centroid(of: sine(hz: selfCheckHighHz, seconds: selfCheckSeconds,
                                     sampleRate: sampleRate),
                            sampleRate: sampleRate)
        var passed = false
        if let low, let high, low > 0 { passed = high > low * 2 }
        return SelfCheck(
            passed: passed,
            lowToneHz: selfCheckLowHz, lowToneCentroidHz: low,
            highToneHz: selfCheckHighHz, highToneCentroidHz: high,
            rule: "a \(Int(selfCheckHighHz)) Hz tone must read a centroid more than"
                + " TWICE that of a \(Int(selfCheckLowHz)) Hz tone, measured through the"
                + " same code path as the ladder. If this fails the probe errors out"
                + " instead of returning a verdict.")
    }

    static func sine(hz: Double, seconds: Double, sampleRate: Double) -> [Float] {
        let count = max(0, Int(seconds * sampleRate))
        guard count > 0, sampleRate > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        let step = 2 * Double.pi * hz / sampleRate
        for i in 0..<count { out[i] = Float(sin(step * Double(i))) }
        return out
    }

    // MARK: - The ladder

    /// Analyses an already-rendered velocity ladder: `velocities.count` notes
    /// of the SAME pitch, note *i* starting at `noteStarts[i]` seconds.
    ///
    /// The analysis window sits `windowOffsetSeconds` into each note and runs
    /// for `windowSeconds` — past the attack transient, inside the sustain,
    /// the geometry `scripts/probes/timbre-liveness.sh` uses, so figures
    /// measured with the shell probe transfer.
    ///
    /// Throws `meterSelfCheckFailed` rather than returning a verdict when the
    /// meter cannot discriminate.
    public static func analyzeLadder(
        audio: RenderedAudio,
        velocities: [Int],
        noteStarts: [Double],
        windowOffsetSeconds: Double,
        windowSeconds: Double,
        trackId: String,
        instrumentKind: String?,
        instrumentDetail: String?,
        pitch: Int,
        noteSeconds: Double
    ) throws -> Result {
        guard velocities.count >= 2 else { throw ProbeError.noVelocities }
        guard audio.frameCount > 0, audio.sampleRate > 0 else { throw ProbeError.emptyRender }

        // ⭐ THE CONTROL RUNS FIRST AND ABORTS. Never after the ladder, never
        // as an advisory flag on a verdict that already shipped.
        let check = selfCheck(sampleRate: audio.sampleRate)
        guard check.passed else {
            throw ProbeError.meterSelfCheckFailed(lowHz: check.lowToneCentroidHz,
                                                  highHz: check.highToneCentroidHz)
        }

        let samples = mono(audio)
        var measured: [(velocity: Int, rmsDb: Double, centroidHz: Double?)] = []
        for (index, velocity) in velocities.enumerated() {
            let start = index < noteStarts.count ? noteStarts[index] : 0
            let reading = measureWindow(samples, from: start + windowOffsetSeconds,
                                        seconds: windowSeconds, sampleRate: audio.sampleRate)
            // A rung at/below the silence floor has no timbre to report; its
            // centroid is suppressed so it cannot masquerade as a dark layer.
            let usable = reading.rmsDb > silenceDb
            measured.append((velocity, reading.rmsDb, usable ? reading.centroidHz : nil))
        }

        let groups = timbreGroups(measured.map(\.centroidHz))
        let ladder = zip(measured, groups).map { reading, group in
            Rung(velocity: reading.velocity, rmsDb: reading.rmsDb,
                 centroidHz: reading.centroidHz, timbreGroup: group)
        }

        let centroids = measured.compactMap(\.centroidHz)
        let levels = measured.map(\.rmsDb)
        let rmsSpread = levels.isEmpty ? nil : (levels.max()! - levels.min()!)
        var centroidSpread: Double?
        if let low = centroids.min(), let high = centroids.max(), low > 0 {
            centroidSpread = (high - low) / low * 100
        }
        let distinct = Set(groups.compactMap { $0 }).count

        let verdict = self.verdict(centroids: centroids, expected: velocities.count,
                                   rmsSpreadDb: rmsSpread, centroidSpreadPercent: centroidSpread,
                                   distinctTimbreCount: distinct)

        return Result(
            trackId: trackId,
            instrumentKind: instrumentKind,
            instrumentDetail: instrumentDetail,
            pitch: pitch,
            noteSeconds: noteSeconds,
            sampleRate: audio.sampleRate,
            selfCheck: check,
            ladder: ladder,
            rmsSpreadDb: rmsSpread,
            centroidSpreadPercent: centroidSpread,
            distinctTimbreCount: distinct,
            verdict: verdict,
            summary: summary(verdict: verdict, rmsSpreadDb: rmsSpread,
                             centroidSpreadPercent: centroidSpread,
                             distinctTimbreCount: distinct, rungs: ladder),
            thresholds: Thresholds(
                staticCentroidSpreadPercent: staticCentroidSpreadPercent,
                minimumRMSSpreadDb: minimumRMSSpreadDb,
                timbreGroupTolerancePercent: timbreGroupTolerancePercent,
                calibrated: false),
            caveats: caveats)
    }

    /// Clusters ADJACENT rungs (in velocity order) whose centroids agree to
    /// within `timbreGroupTolerancePercent` of the running group mean.
    ///
    /// ⚠️ Adjacent-in-velocity, NOT sorted-by-centroid, because layered banks
    /// **need not be monotonic**: GeneralUser GS's piano measured
    /// 1856 → 1063 → 3662 → 3662 Hz, and a soft layer being brighter than the
    /// one above it is perfectly normal sample-library authoring. Sorting
    /// would fold that into two groups and lose the middle layer.
    static func timbreGroups(_ centroids: [Double?]) -> [Int?] {
        var groups: [Int?] = []
        var current = 0
        var runningSum = 0.0
        var runningCount = 0
        for centroid in centroids {
            guard let centroid, centroid > 0 else { groups.append(nil); continue }
            if runningCount == 0 {
                current += 1
                runningSum = centroid
                runningCount = 1
            } else {
                let mean = runningSum / Double(runningCount)
                if abs(centroid - mean) / mean * 100 > timbreGroupTolerancePercent {
                    current += 1
                    runningSum = centroid
                    runningCount = 1
                } else {
                    runningSum += centroid
                    runningCount += 1
                }
            }
            groups.append(current)
        }
        return groups
    }

    static func verdict(centroids: [Double], expected: Int, rmsSpreadDb: Double?,
                        centroidSpreadPercent: Double?, distinctTimbreCount: Int) -> Verdict {
        // "Could not measure" is answered BEFORE "measured and found flat".
        guard centroids.count == expected, let rmsSpreadDb, let centroidSpreadPercent,
              distinctTimbreCount > 0
        else { return .silent }
        guard rmsSpreadDb >= minimumRMSSpreadDb else { return .inconclusive }
        if distinctTimbreCount == 1 && centroidSpreadPercent < staticCentroidSpreadPercent {
            return .static
        }
        return .live
    }

    static func summary(verdict: Verdict, rmsSpreadDb: Double?,
                        centroidSpreadPercent: Double?, distinctTimbreCount: Int,
                        rungs: [Rung]) -> String {
        func dbText() -> String { rmsSpreadDb.map { String(format: "%.1f dB", $0) } ?? "no" }
        func pctText() -> String {
            centroidSpreadPercent.map { String(format: "%.2f %%", $0) } ?? "no"
        }
        switch verdict {
        case .silent:
            let dead = rungs.filter { $0.centroidHz == nil }.map { String($0.velocity) }
            return "COULD NOT MEASURE. \(dead.count) of \(rungs.count) rungs produced no"
                + " usable signal (velocity \(dead.joined(separator: ", "))). This is NOT a"
                + " finding of deadness — the instrument may not be loaded, may not cover this"
                + " pitch, or may be muted upstream. Check the patch and probe again."
        case .inconclusive:
            return "INCONCLUSIVE. Only \(dbText()) of level movement across the ladder, so it"
                + " does not test the question: something is flattening velocity (a"
                + " velocity-insensitive patch, or a compressor/limiter in the chain) before"
                + " timbre gets a chance to matter."
        case .static:
            return "STATIC — one timbre. \(dbText()) of level movement and only \(pctText())"
                + " of timbre movement, with \(distinctTimbreCount) distinct timbre detected."
                + " Velocity is a volume knob on this patch: it has effectively ONE sample."
                + " It will read as lifeless on any exposed melodic part — prefer an"
                + " instrument with real velocity layers for leads and solos."
        case .live:
            return "LIVE — \(distinctTimbreCount) distinct timbres across the ladder"
                + " (\(pctText()) centroid movement over \(dbText()) of level). Velocity"
                + " changes the tone, not just the volume."
        }
    }

    static let caveats = [
        "This measures LIVELINESS, not quality: it says nothing about tuning, articulation,"
            + " or whether the sound is pleasant. Those still need a human.",
        "The thresholds are NOT calibrated. 'centroid spread < 5 % while RMS spread > 20 dB'"
            + " began as a hypothesis from ONE instrument (Apple's GM DLS sax measured 0.05 %"
            + " against GeneralUser GS's 6.59 %). Read `ladder`, not just `verdict`.",
        "`centroidSpreadPercent` is min-to-max, a CRUDE summary: layered banks step between"
            + " PLATEAUS and need not be monotonic (a soft layer can be brighter than the one"
            + " above it). `distinctTimbreCount` is the more informative number, and it is a"
            + " LOWER BOUND — this many velocities cannot see more layers than they sample.",
        "The ladder renders the instrument DRY: no track effects, no sends, no master chain,"
            + " so the reading describes the patch and not the mix around it.",
        "Centroid Hz here is not comparable to ffmpeg's `aspectralstats` or to any other"
            + " tool's — window geometry differs. Compare rungs to each other, not to"
            + " numbers from elsewhere.",
    ]

    // MARK: - Pure-Swift FFT (Foundation-only, DAWCore's rule)

    static func hann(_ n: Int) -> [Double] {
        guard n > 1 else { return [Double](repeating: 1, count: max(0, n)) }
        var w = [Double](repeating: 0, count: n)
        for i in 0..<n { w[i] = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)) }
        return w
    }

    static func largestPowerOfTwo(atMost value: Int) -> Int {
        guard value >= 1 else { return 0 }
        var n = 1
        while n * 2 <= value { n *= 2 }
        return n
    }

    /// In-place iterative radix-2 Cooley-Tukey FFT. `real.count` must be a
    /// power of two and equal `imaginary.count`. Offline analysis only — this
    /// allocates nothing per call beyond its own loop scalars, but it is never
    /// on the render path regardless.
    static func fft(real: inout [Double], imaginary: inout [Double]) {
        let n = real.count
        guard n > 1, n & (n - 1) == 0, imaginary.count == n else { return }
        // Bit-reversal permutation.
        var j = 0
        for i in 0..<(n - 1) {
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
            var k = n >> 1
            while k <= j {
                j -= k
                k >>= 1
            }
            j += k
        }
        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            let wReal = cos(angle)
            let wImaginary = sin(angle)
            var start = 0
            while start < n {
                var curReal = 1.0
                var curImaginary = 0.0
                for offset in 0..<(length / 2) {
                    let a = start + offset
                    let b = a + length / 2
                    let tReal = curReal * real[b] - curImaginary * imaginary[b]
                    let tImaginary = curReal * imaginary[b] + curImaginary * real[b]
                    real[b] = real[a] - tReal
                    imaginary[b] = imaginary[a] - tImaginary
                    real[a] += tReal
                    imaginary[a] += tImaginary
                    let nextReal = curReal * wReal - curImaginary * wImaginary
                    curImaginary = curReal * wImaginary + curImaginary * wReal
                    curReal = nextReal
                }
                start += length
            }
            length <<= 1
        }
    }
}
