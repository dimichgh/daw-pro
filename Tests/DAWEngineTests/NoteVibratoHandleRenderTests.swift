import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// m23-ap C5a-1 — THE WOBBLE AT OTHER STRETCH RATIOS, AND ITS PHASE ANCHOR,
/// MEASURED IN RENDERED AUDIO (vibrato-handle design §7, §15 T1, finding V5).
///
/// Every generator measurement before this file ran at ratio 1
/// (`NoteVibratoGeneratorTests` §C). The generator is evaluated in SOURCE
/// seconds, and an output second is `ratio` source seconds, so a stored rate
/// is HEARD at `stored ÷ ratio` (V5, [INFERRED] until this file). Here that is
/// measured in the output, the 8 Hz ceiling is shown to be an OUTPUT-time
/// limit (the recorded leg the item stops on), and the stored phase anchor is
/// shown to reach the render.
///
/// ⚠️ **TRANSPOSER ACCURACY (scratchpad/w3/cents/report.md, fix under review).**
/// The vendored pitch shifter reads fractional bins wrongly, so a non-zero
/// transpose lands up to ~10 c off. Nothing here asserts an ABSOLUTE depth in
/// cents: rates are peak LOCATIONS, the anchor leg compares two renders
/// through the same chain (the error cancels), the ceiling leg compares two
/// ratios through the same chain, and the widened-depth figure is RECORDED
/// with only a loose sanity band. No golden digest of audio is pinned here.
///
/// Rendered through `StretchCurvePlan` + `OfflineStretcher.stretchTransposeCurve`
/// with the shipping compensation, which is what `StretchRenderCache.performRender`
/// does (the `NoteVibratoGeneratorTests` precedent). Deliberately NOT
/// `@MainActor`: DSP has no business there, and `MainActorOccupancySiteTests`
/// Leg C is at its cap.
@Suite("m23-ap C5a-1 — the wobble's heard rate and phase anchor, rendered")
struct NoteVibratoHandleRenderTests {
    static let sampleRate = 48_000.0
    static let baseHz = 220.0
    static let amplitude: Float = 0.8
    /// The render settles, and the first ~50 ms cannot be latency-compensated
    /// at all by construction (`NoteVibratoGeneratorTests.measureDepth`).
    static let guardSeconds = 0.4

    static func log(_ leg: String, _ message: String) {
        print("m23-ap-C5a-1|\(leg)| \(message)")
    }

    /// One note covering the whole source (and past it), carrying only a
    /// generator: the `NoteVibratoGeneratorTests.generatorSet` shape, with an
    /// anchor.
    static func generatorSet(rateHz: Double, depthCents: Double, sourceSeconds: Double,
                             anchorSeconds: Double = 0) -> PitchEditSet {
        PitchEditSet(
            segments: [NoteSegment(
                startSeconds: 0, endSeconds: sourceSeconds + 10, detectedHz: baseHz,
                detectedConfidence: 1, vibratoRateHz: rateHz,
                vibratoDepthCents: depthCents, vibratoPhaseAnchorSeconds: anchorSeconds)],
            retuneMs: PitchEditSet.engineMinimumRetuneMs)
    }

    /// Render `sourceSeconds` of a 220 Hz sine through the SHIPPING path at
    /// `ratio`. The output is `round(frames × ratio)` frames long.
    static func render(_ set: PitchEditSet, ratio: Double, sourceSeconds: Double,
                       contour: PitchRenderContour? = nil,
                       input: [Float]? = nil) throws -> [Float] {
        let frames = Int(sampleRate * sourceSeconds)
        let source = input ?? M23QSignal.sine(hz: baseHz, frames: frames,
                                              sampleRate: sampleRate, amplitude: amplitude)
        let plan = try #require(StretchCurvePlan.make(
            editSet: set, clipPitchShiftSemitones: 0,
            sampleRate: sampleRate, ratio: ratio, contour: contour))
        return try OfflineStretcher.stretchTransposeCurve(
            input: [source], sampleRate: sampleRate, ratio: ratio,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(
                sampleRate: sampleRate))[0]
    }

    /// The rendered f0, in cents above `baseHz`, at each estimate's window
    /// CENTRE (`M23QToneEstimate.centreFrame`, the harness's own contract),
    /// in OUTPUT frames, with `guardSeconds` dropped at each end.
    static func f0Series(_ signal: [Float]) -> [(frame: Double, value: Double)] {
        let guardFrames = sampleRate * guardSeconds
        return M23QToneTracker.track(signal, sampleRate: sampleRate)
            .filter { $0.centreFrame >= guardFrames
                && $0.centreFrame <= Double(signal.count) - guardFrames }
            .map { (frame: $0.centreFrame,
                    value: M23QToneTracker.cents($0.hz, above: baseHz)) }
    }

    /// The series cut to a WHOLE number of periods at `rateHz`: a partial
    /// cycle biases a one-bin DFT's amplitude (`NoteVibratoGeneratorTests.measureDepth`).
    static func wholeCycles(_ series: [(frame: Double, value: Double)],
                            rateHz: Double) -> [(frame: Double, value: Double)] {
        let period = sampleRate / rateHz
        let first = series.first?.frame ?? 0
        let span = (series.last?.frame ?? 0) - first
        let whole = (span / period).rounded(.down)
        return whole >= 1 ? series.filter { $0.frame < first + whole * period } : series
    }

    /// Where the rendered f0's strongest periodic component sits, scanning
    /// 2–10 Hz in 0.05 Hz steps. ⚠️ The projection amplitudes are NOT depths
    /// (a partial cycle per candidate biases them); they LOCATE a peak only,
    /// exactly as in `NoteVibratoGeneratorTests.rateIsDelivered`.
    static func strongestRate(_ series: [(frame: Double, value: Double)])
        -> (rate: Double, amplitude: Double) {
        var best = (rate: 0.0, amplitude: 0.0)
        for step in 0...160 {
            let rate = 2.0 + Double(step) * 0.05
            guard let fit = M23QToneTracker.fitSinusoid(
                series, rateHz: rate, sampleRate: sampleRate) else { continue }
            if fit.amplitude > best.amplitude { best = (rate, fit.amplitude) }
        }
        return best
    }

    /// The fitted wobble at a KNOWN heard rate over whole cycles: depth,
    /// lag (output frames, `fitSinusoid`'s convention: how far the series
    /// trails `sin(2π·rate·t)`), and the RMS of everything that is not that
    /// sinusoid.
    static func fit(_ signal: [Float], heardRateHz: Double) throws
        -> (amplitude: Double, lagFrames: Double, residualRMS: Double) {
        let series = wholeCycles(f0Series(signal), rateHz: heardRateHz)
        return try #require(M23QToneTracker.fitSinusoid(
            series, rateHz: heardRateHz, sampleRate: sampleRate))
    }

    /// The instrument's own control: a 220 Hz tone carrying EXACTLY a
    /// `depthCents` sine at `heardRateHz`, `frames` long, no stretcher. It is
    /// built in OUTPUT time, because that is where the listener hears it.
    static func idealHeard(heardRateHz: Double, depthCents: Double, frames: Int) -> [Float] {
        M23QSignal.vibratoSine(baseHz: baseHz, depthCents: depthCents, rateHz: heardRateHz,
                               frames: frames, sampleRate: sampleRate, amplitude: amplitude)
    }

    // MARK: - T1: the asked rate is HEARD at stored ÷ ratio

    /// ⭐⭐ **T1 (design §15): the rendered f0 carries the HEARD rate.** Three
    /// legs, each ~6 s of OUTPUT: ratio 1 stored 6.0 (heard 6.0); ratio 2
    /// stored 6.0 (heard 3.0); ratio 0.5 stored 3.0 (heard 6.0). The scan is
    /// 2–10 Hz, not `rateIsDelivered`'s 4–12, which cannot see heard 3.0.
    ///
    /// Planted, red: the generator evaluated per OUTPUT second (the ratio
    /// dropped from `StretchCurvePlan.semitones(atOutputFrame:)`'s time
    /// argument). The ratio-2 leg then peaks at 6.0, not 3.0.
    @Test("T1 the wobble is heard at stored ÷ ratio, at ratios 1, 2 and 0.5")
    func askedRateIsHeard() throws {
        let legs: [(ratio: Double, stored: Double)] = [(1, 6.0), (2, 6.0), (0.5, 3.0)]
        for leg in legs {
            let heard = leg.stored / leg.ratio
            let sourceSeconds = 6.0 / leg.ratio
            let rendered = try Self.render(
                Self.generatorSet(rateHz: leg.stored, depthCents: 60,
                                  sourceSeconds: sourceSeconds),
                ratio: leg.ratio, sourceSeconds: sourceSeconds)
            #expect(rendered.count == Int((Self.sampleRate * sourceSeconds * leg.ratio)
                .rounded()))
            let series = Self.f0Series(rendered)
            let best = Self.strongestRate(series)
            let wrong = try #require(M23QToneTracker.fitSinusoid(
                series, rateHz: heard * 1.35, sampleRate: Self.sampleRate))
            Self.log("T1", "ratio \(leg.ratio): stored \(leg.stored) Hz, heard (stored ÷ ratio) "
                + "\(heard) Hz; the rendered f0 peaks at \(best.rate) Hz (projection "
                + "\(best.amplitude), NOT a depth); at 1.35 × heard it reads \(wrong.amplitude)")
            #expect(abs(best.rate - heard) < 0.2,
                    """
                    ratio \(leg.ratio): a stored \(leg.stored) Hz wobble should be heard at \
                    \(heard) Hz, and the rendered f0's strongest component is at \
                    \(best.rate) Hz. The readout's "heard rate = stored ÷ ratio" is wrong.
                    """)
            // ⭐ CONTROL: the scan resolves rates, so "it peaked at the heard
            // rate" is not merely "the heard rate was in the list".
            #expect(wrong.amplitude < best.amplitude * 0.5,
                    """
                    ratio \(leg.ratio): 1.35 × the heard rate reads \(wrong.amplitude) \
                    against \(best.amplitude) at the peak, so the scan cannot tell rates apart.
                    """)
        }
    }

    /// What the CHAIN adds to the rendered f0 beyond a pure sine, over the
    /// instrument's own floor, as a fraction of the depth asked for: §C's
    /// `excessResidualFraction`, with the control built at the HEARD rate over
    /// the OUTPUT's length.
    static func excessResidualFraction(ratio: Double, stored: Double,
                                       depthCents: Double) throws
        -> (excess: Double, chain: Double, floor: Double, controlDepth: Double) {
        let heard = stored / ratio
        let sourceSeconds = 6.0 / ratio
        let rendered = try render(generatorSet(rateHz: stored, depthCents: depthCents,
                                               sourceSeconds: sourceSeconds),
                                  ratio: ratio, sourceSeconds: sourceSeconds)
        let chain = try fit(rendered, heardRateHz: heard)
        let control = try fit(idealHeard(heardRateHz: heard, depthCents: depthCents,
                                         frames: rendered.count), heardRateHz: heard)
        return (max(0, chain.residualRMS - control.residualRMS) / depthCents,
                chain.residualRMS, control.residualRMS, control.amplitude)
    }

    /// ⭐⭐ **T1's RECORDED LEG, AND THE ONE THE ITEM STOPS ON (design §15, V5):
    /// the 8 Hz ceiling is an OUTPUT-time limit.** The curve is read once per
    /// 30 ms hop of OUTPUT frames, so what breaks a fast wobble's shape should
    /// be the HEARD rate, not the stored one. Heard 7.8 Hz reached two ways, at
    /// ratio 1 (stored 7.8) and at ratio 0.5 (stored 3.9), must carry the same
    /// non-sinusoidal excess within 3 percentage points. If it does not, the
    /// heard clamp (`8 × ratio`, C5a-2) is built on a wrong model: STOP and
    /// report, never widen the band.
    ///
    /// ⭐ The CONTRAST that proves the leg can tell the two models apart: the
    /// SAME stored 3.9 at ratio 1 is heard at 3.9 Hz, where §C measured a
    /// small excess. If the ceiling were a SOURCE-time limit, ratio 0.5's
    /// figure would sit there instead of at ratio 1's 7.8 Hz figure.
    @Test("T1 recorded: heard 7.8 Hz carries the same staircase at ratio 0.5 as at ratio 1")
    func ceilingIsOutputTime() throws {
        let depth = 93.0
        let atRatio1 = try Self.excessResidualFraction(ratio: 1, stored: 7.8, depthCents: depth)
        let atRatioHalf = try Self.excessResidualFraction(ratio: 0.5, stored: 3.9,
                                                          depthCents: depth)
        let slowStored = try Self.excessResidualFraction(ratio: 1, stored: 3.9,
                                                         depthCents: depth)
        Self.log("T1", "CEILING (±\(depth) c): heard 7.8 via ratio 1 → excess "
            + "\(atRatio1.excess * 100) % (residual \(atRatio1.chain) c over floor "
            + "\(atRatio1.floor) c); heard 7.8 via ratio 0.5 (stored 3.9) → excess "
            + "\(atRatioHalf.excess * 100) % (residual \(atRatioHalf.chain) c over floor "
            + "\(atRatioHalf.floor) c); CONTRAST stored 3.9 at ratio 1 (heard 3.9) → "
            + "\(slowStored.excess * 100) %; difference ratio 0.5 − ratio 1 = "
            + "\((atRatioHalf.excess - atRatio1.excess) * 100) percentage points")
        // The instrument reads a known ±93 c sine at both lengths, or the
        // residuals are uninterpretable.
        for control in [atRatio1.controlDepth, atRatioHalf.controlDepth] {
            #expect(abs(control / depth - 1) < 0.03,
                    "the instrument control reads ±\(control) c on an exact ±\(depth) c sine")
        }
        #expect(abs(atRatioHalf.excess - atRatio1.excess) <= 0.03,
                """
                heard 7.8 Hz carries \(atRatioHalf.excess * 100) % excess at ratio 0.5 and \
                \(atRatio1.excess * 100) % at ratio 1: the ceiling is NOT an output-time \
                limit as V5 assumed. STOP: the heard clamp must be revisited (design §15 T1).
                """)
        // The contrast must be distinguishable, or the leg above proves nothing.
        #expect(atRatio1.excess - slowStored.excess > 0.03,
                """
                heard 7.8 (\(atRatio1.excess * 100) %) and heard 3.9 \
                (\(slowStored.excess * 100) %) carry the same excess, so the leg above \
                cannot tell an output-time ceiling from a source-time one.
                """)
    }

    // MARK: - The phase anchor reaches the render

    /// ⭐⭐ **The stored anchor moves the RENDERED wobble's phase, by exactly
    /// the anchor, in output time (design §7.1, D7).** The same generator at
    /// anchor 0 and at anchor `a`, through the same chain: the generator is
    /// `sin(ω(t − a))`, so the rendered f0 trails the anchor-0 render by `a`
    /// SOURCE seconds, which is `a × ratio` OUTPUT seconds. RELATIVE by
    /// construction: both renders share the transposer, so its ~10 c
    /// fractional-bin error (and its latency) cancels in the difference.
    ///
    /// `a` is 0.3 of a period, not a quarter or a half, so neither a lost
    /// anchor (0), a sign error (−a) nor a doubled one lands on a lag the
    /// modulo could fold back onto the right answer.
    ///
    /// Planted, red: the generator ignoring the anchor (`sin(ω · t)`): the
    /// lags then agree to the tracker's noise and the difference reads 0.
    @Test("the phase anchor shifts the rendered wobble by exactly the anchor, at ratios 1 and 2")
    func anchorReachesTheRender() throws {
        let stored = 5.5
        for ratio in [1.0, 2.0] {
            let heard = stored / ratio
            let sourceSeconds = 6.0 / ratio
            let anchor = 0.3 / stored  // 0.3 of a SOURCE period
            func lag(_ anchorSeconds: Double) throws -> Double {
                let rendered = try Self.render(
                    Self.generatorSet(rateHz: stored, depthCents: 60,
                                      sourceSeconds: sourceSeconds,
                                      anchorSeconds: anchorSeconds),
                    ratio: ratio, sourceSeconds: sourceSeconds)
                return try Self.fit(rendered, heardRateHz: heard).lagFrames
            }
            let periodFrames = Self.sampleRate / heard
            var shift = try lag(anchor) - lag(0)
            // Fold into (−½, ½] of a period: the fit's lag is modulo a period.
            while shift > periodFrames / 2 { shift -= periodFrames }
            while shift <= -periodFrames / 2 { shift += periodFrames }
            let expected = anchor * ratio * Self.sampleRate
            Self.log("anchor", "ratio \(ratio): anchor \(anchor * 1000) ms (source) → the "
                + "rendered wobble moved \(shift / Self.sampleRate * 1000) ms (output); "
                + "expected anchor × ratio = \(expected / Self.sampleRate * 1000) ms")
            #expect(abs(shift - expected) < 0.002 * Self.sampleRate,
                    """
                    ratio \(ratio): a phase anchor of \(anchor * 1000) ms moved the rendered \
                    wobble by \(shift / Self.sampleRate * 1000) ms of output, not the \
                    \(expected / Self.sampleRate * 1000) ms (anchor × ratio) it must.
                    """)
        }
    }

    /// **The anchor is where the synthesised wobble crosses zero, rising, on
    /// the curve (design §7.1), and under per-note timing that point is
    /// `W(anchor)` (§7.6).** Two notes carry a generator anchored inside them:
    /// an untimed one 12.3 s into the file (T4's fixture time, where an anchor
    /// at source 0 would sit ~1.2 cycles away after any rate change), and one
    /// whose end edge is retimed, so the generator runs in EDITED time and
    /// `W(anchor) ≠ anchor`. At source second `anchor` the curve must equal the
    /// same table with no generator, BIT FOR BIT (the generator term is
    /// `sin(0) = +0`), and just after it the wobble must be rising.
    ///
    /// Planted, red: the retimed anchor not mapped through W (the raw source
    /// second on the edited axis): the retimed note then reads ~21 c off at
    /// its anchor.
    @Test("§7.6 the wobble crosses zero rising at the anchor, and at W(anchor) when retimed")
    func anchorIsTheZeroCrossing() throws {
        func table(depth: Double, endDelta: Double, start: Double, anchor: Double)
            -> PitchEditSet {
            PitchEditSet(segments: [
                NoteSegment(startSeconds: start, endSeconds: start + 1, detectedHz: 220,
                            detectedConfidence: 1, pitchOffsetCents: -37.5,
                            vibratoRateHz: 5.5, vibratoDepthCents: depth,
                            vibratoPhaseAnchorSeconds: anchor,
                            timeEndDeltaSeconds: endDelta),
            ], retuneMs: 30)
        }
        let legs: [(name: String, start: Double, anchor: Double, endDelta: Double,
                    duration: Double)] = [
            ("untimed at 12.3 s", 11.8, 12.3, 0, 20),
            ("retimed, end +0.1 s", 0.25, 1.0, 0.1, 2.5),
        ]
        for leg in legs {
            let wobbling = table(depth: 40, endDelta: leg.endDelta, start: leg.start,
                                 anchor: leg.anchor)
            let still = table(depth: 0, endDelta: leg.endDelta, start: leg.start,
                              anchor: leg.anchor)
            let warp = PitchTimeWarp.make(editSet: wobbling, sourceDurationSeconds: leg.duration)
            #expect((warp != nil) == (leg.endDelta != 0), "precondition: W exists iff retimed")
            if let warp {
                #expect(abs(warp.editedSecond(forSourceSecond: leg.anchor) - leg.anchor) > 0.05,
                        "precondition: W must MOVE the anchor, or this leg cannot see W")
            }
            let curve = PitchCorrectionCurve.make(editSet: wobbling, timeWarp: warp)
            let plain = PitchCorrectionCurve.make(editSet: still, timeWarp: warp)
            let atAnchor = curve.semitones(atSourceSecond: leg.anchor)
            let justAfter = curve.semitones(atSourceSecond: leg.anchor + 0.005)
                - plain.semitones(atSourceSecond: leg.anchor + 0.005)
            Self.log("zero", "\(leg.name): at the anchor the wobble adds "
                + "\((atAnchor - plain.semitones(atSourceSecond: leg.anchor)) * 100) c; "
                + "5 ms later \(justAfter * 100) c")
            #expect(atAnchor.bitPattern == plain.semitones(atSourceSecond: leg.anchor).bitPattern,
                    """
                    \(leg.name): the wobble is not at zero at its anchor: it adds \
                    \((atAnchor - plain.semitones(atSourceSecond: leg.anchor)) * 100) c there.
                    """)
            #expect(justAfter > 0.01, "\(leg.name): the wobble is not RISING through its anchor")
        }
    }

    // MARK: - Failure mode 16: widening a SUNG wobble (recorded, not gated)

    /// A synthetic whole-file DETECTION of `vibratoSine(220 Hz, ±depth, rate)`
    /// at the detector's 62.5 fps. ⚠️ Stamped the way SwiftF0 stamps: each
    /// frame's `timeSeconds` is its START and its value is the pitch at its
    /// CENTRE, because `.detected` adds `frameValueOffsetSeconds` (half a frame)
    /// back. A point-sampled contour wrapped in `.detected` would sit 8 ms late
    /// and dephase the very wobble being doubled.
    static func sungDetection(depthCents: Double, rateHz: Double,
                              seconds: Double) -> PitchDetectionResult {
        let rate = 62.5
        let count = Int(seconds * rate)
        let frames = (0..<count).map { i -> ClipPitchFrame in
            let start = Double(i) / rate
            let centre = start + 0.5 / rate
            let cents = depthCents * sin(2 * .pi * rateHz * centre)
            return ClipPitchFrame(timeSeconds: start, frequencyHz: baseHz * pow(2, cents / 1200),
                                  confidence: 0.97, levelDbfs: -16, absence: nil)
        }
        return PitchDetectionResult(
            frames: frames, frameCount: count, voicedFrameCount: count, voicedFraction: 1,
            frameRateHz: rate, analysisSampleRateHz: 16_000, sourceSampleRateHz: sampleRate,
            windowStartSeconds: 0, windowDurationSeconds: Double(count) / rate,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs,
            minFrequencyHz: 46, maxFrequencyHz: 2_093)
    }

    /// ⭐ **FAILURE MODE 16, RECORDED (design §14 row 16, feeds C5a-F2).**
    /// Widening "your wobble" writes the two scales APART for the first time:
    /// keep (`vibratoScale`) 2, drift 1 — an UNEQUAL-scale note
    /// (`NoteSegment.takesSeparatedShaping`).
    ///
    /// **v1, until 2026-09-27:** every unequal-scale note took the 250 ms
    /// separator's 17-tap boxcar, which leaks −21.5 % of a 5.5 Hz wobble into
    /// "drift", so its "vibrato" part was 1.215 × the wobble, and keep 2
    /// should have delivered about 1 + 1.215 = 2.2 × the sung depth, not 2 ×
    /// (V3, [INFERRED]).
    ///
    /// **v2 since 2026-09-27 (W7-C3, natural tuning §3b):** an unequal-scale
    /// note now takes the triangular kernel instead
    /// (`PitchCorrectionCurve.separatedDriftWindowSeconds` = 0.16 s,
    /// `.separatedDriftEdge` = `.truncate`), whose response at 5.5 Hz is
    /// close to 0 (H ≈ +0.001, see `PitchWobbleGestureTests.readoutNeverOverclaims`'s
    /// doc), so the curve-level prediction is ≈ 2.0 ×, not 2.2 ×. MEASURED on
    /// this render (W7-STX, 2026-09-27): 1.957× (log tag F16; no formant base
    /// on this render — `engagesFormantCurve` is printed and false). Hard Tune
    /// (equal scales) still takes v1 and is unaffected. See
    /// `docs/ROADMAP.md` "W7-C3: drift/wobble separator v2 DONE".
    ///
    /// Rendered through the shipping contour path (`StretchCurvePlan.make`
    /// with a `.detected` contour, so `PitchRenderContour.curve` builds the
    /// curve) on a sung ±40 c, 5.5 Hz input; the depth is read from the
    /// output with the tracker that reads the INPUT as the sung reference.
    /// **Recorded, not gated:** the band below only catches a broken set-up
    /// (and admits the transposer's ~10 c error), it does not pin the figure.
    @Test("failure mode 16 (recorded): keep 2 on a sung ±40 c, 5.5 Hz wobble renders ~2.0× under v2 (was ~2.2× under v1)")
    func widenedDepthIsRecorded() throws {
        let seconds = 6.0
        let sung = M23QSignal.vibratoSine(baseHz: Self.baseHz, depthCents: 40, rateHz: 5.5,
                                          frames: Int(Self.sampleRate * seconds),
                                          sampleRate: Self.sampleRate, amplitude: Self.amplitude)
        let widened = PitchEditSet(segments: [NoteSegment(
            startSeconds: 0, endSeconds: seconds, detectedHz: Self.baseHz,
            detectedConfidence: 1, driftScale: 1, vibratoScale: 2)],
            retuneMs: PitchEditSet.engineMinimumRetuneMs)
        let contour = PitchRenderContour.detected(
            Self.sungDetection(depthCents: 40, rateHz: 5.5, seconds: seconds))
        let rendered = try Self.render(widened, ratio: 1, sourceSeconds: seconds,
                                       contour: contour, input: sung)
        let asSung = try Self.fit(sung, heardRateHz: 5.5)
        let kept2 = try Self.fit(rendered, heardRateHz: 5.5)
        let ratio = kept2.amplitude / asSung.amplitude
        Self.log("F16", "sung ±40 c @ 5.5 Hz reads ±\(asSung.amplitude) c; keep 2 / drift 1 "
            + "renders ±\(kept2.amplitude) c = \(ratio)× the sung reading (v1 09-24 prediction "
            + "~2.215×, V3, boxcar; v2 since 2026-09-27 predicts ~2.0× on this unequal-scale "
            + "note, triangular L 0.16, MEASURED 1.957×; 2.0× would mean no separator leak); "
            + "residual \(kept2.residualRMS) c; engagesFormantCurve \(widened.engagesFormantCurve)")
        #expect(abs(asSung.amplitude / 40 - 1) < 0.03,
                "the instrument reads the sung ±40 c input as ±\(asSung.amplitude) c")
        #expect(ratio > 1.6 && ratio < 2.8,
                "keep 2 rendered \(ratio)× the sung depth: the set-up is broken, not the figure")
    }
}
