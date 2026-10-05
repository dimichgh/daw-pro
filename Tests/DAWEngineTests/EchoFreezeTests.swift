import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`, for the reason
// `DJFilterTests` and `BitCrusherTests` record at length: the main actor is ONE
// serialization point for the whole test process, these legs render minutes of
// audio, and they need no main-actor state at all. (There is also a hard
// structural reason: `MainActorOccupancySiteTests` Leg C pins the
// `@MainActor`-isolated SUITE count at its cap with ZERO slack, so a new
// isolated suite would redden a gate in a different target.)
//
// The one main-actor thing an effect owns is `apply(params:)`; these legs
// construct effects with their params instead — the FXPack2 / DJFilter
// precedent for a param set that never changes mid-render. Where a leg needs a
// value the clamping init refuses, it goes through `storeAutomatedParam`, which
// is the real automation path and pokes the overlay field directly.
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-k — the echo freeze. `DelayParams.feedbackRange` went `0…0.95` →
/// `0…0.999`, and every claim about WHY it stops at 0.999 is measured from
/// rendered output here rather than argued.
///
/// ⭐ **What separates the plausible wrong implementations:**
///
///  · the range never widened (or is widened back)  → L1, L2
///  · the ceiling raised to exactly 1.0             → L3 (the DC input grows
///    linearly and never converges) — L3 is the leg that justifies the bound
///  · the render-path re-clamp deleted, so an
///    automation poke can exceed the ceiling        → L4
///  · `highCutHz` neutralised inside the loop       → L5 (and only L5: every
///    other leg holds highCut constant)
///  · the loop's denormal flush removed             → L7
///  · ANY change to the delay's arithmetic, which
///    would silently re-voice saved projects        → L8, a byte pin captured
///    from the PRE-m39-k build
struct EchoFreezeTests {
    private static let sampleRate = 48_000.0
    private static let chunk = 512

    // MARK: - Harness

    /// Per-bin statistics of a rendered tail.
    private struct Bin {
        var peak = 0.0
        var g1 = 0.0, g2 = 0.0     // Goertzel state for `probe`
        var frames = 0
        var subnormals = 0
        var nonFinite = 0
        var nonZeroSamples = 0
        var minNonZero = Double.greatestFiniteMagnitude
    }

    /// Renders `totalFrames` of `input` through a `DelayEffect` in 512-frame
    /// quanta and returns per-`binFrames` statistics. `feedbackOverride`, when
    /// given, is stored through the RENDER-THREAD automation path before every
    /// quantum — the overlay reverts a store after one quantum
    /// (`AutomationParamOverlay.endQuantum`), so a single store would not hold.
    private func render(params: DelayParams,
                        feedbackOverride: Double? = nil,
                        input: (Int) -> Float,
                        totalFrames: Int,
                        binFrames: Int,
                        probe: Double = 220) throws -> [Bin] {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunk)))
        let delay = DelayEffect(params: params)
        delay.prepare(sampleRate: Self.sampleRate,
                      maxFramesPerQuantum: Self.chunk, channelCount: 2)
        let coeff = 2.0 * cos(2.0 * .pi * probe / Self.sampleRate)

        var bins: [Bin] = []
        var bin = Bin()
        var offset = 0
        while offset < totalFrames {
            let frames = min(Self.chunk, totalFrames - offset)
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<frames {
                let value = input(offset + frame)
                data[0][frame] = value
                data[1][frame] = value
            }
            if let feedbackOverride {
                delay.storeAutomatedParam(slot: 1, value: feedbackOverride)
            }
            delay.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frames)
            for frame in 0..<frames {
                let raw = data[0][frame]
                if !raw.isFinite {
                    bin.nonFinite += 1
                    bin.frames += 1
                    if bin.frames == binFrames { bins.append(bin); bin = Bin() }
                    continue
                }
                if raw != 0 {
                    bin.nonZeroSamples += 1
                    let magnitude = abs(Double(raw))
                    bin.minNonZero = min(bin.minNonZero, magnitude)
                    if abs(raw) < Float.leastNormalMagnitude { bin.subnormals += 1 }
                }
                let out = Double(raw)
                bin.peak = max(bin.peak, abs(out))
                let s0 = out + coeff * bin.g1 - bin.g2
                bin.g2 = bin.g1
                bin.g1 = s0
                bin.frames += 1
                if bin.frames == binFrames { bins.append(bin); bin = Bin() }
            }
            offset += frames
        }
        if bin.frames > 0 { bins.append(bin) }
        return bins
    }

    /// Single-bin Goertzel amplitude for the bin's probe frequency.
    private func amplitude(_ bin: Bin, probe: Double = 220) -> Double {
        let coeff = 2.0 * cos(2.0 * .pi * probe / Self.sampleRate)
        let power = bin.g1 * bin.g1 + bin.g2 * bin.g2 - coeff * bin.g1 * bin.g2
        return max(power, 0).squareRoot() * 2.0 / Double(bin.frames)
    }

    private func db(_ ratio: Double) -> Double { ratio > 0 ? 20 * log10(ratio) : -999 }

    /// A 0.5 s two-tone burst then silence — the program every tail leg uses.
    private func burst(_ index: Int) -> Float {
        guard index < 24_000 else { return 0 }
        let t = Double(index) / Self.sampleRate
        return Float(0.35 * sin(2 * .pi * 220 * t) + 0.25 * sin(2 * .pi * 660 * t))
    }

    // MARK: - L1: the bound itself

    @Test("L1: the feedback ceiling is 0.999, reachable, and clamps above it")
    func feedbackCeilingIsNineNineNine() {
        #expect(DelayParams.feedbackRange == 0...0.999)
        // Reachable exactly: a saved 0.999 survives a round trip through the
        // clamping init unchanged.
        #expect(DelayParams(feedback: 0.999).feedback == 0.999)
        // 1.0 is NOT reachable — the measured divergence bound (L3).
        #expect(DelayParams(feedback: 1.0).feedback == 0.999)
        #expect(DelayParams(feedback: 12).feedback == 0.999)
        #expect(DelayParams(feedback: -3).feedback == 0)
        // The ONE home: the generic param surface (and so `fx.describe`, the
        // wire setter's clamp and automation-lane points) resolves here.
        let spec = EffectParamSpec.specs(for: .delay).first { $0.name == "feedback" }
        #expect(spec?.range == DelayParams.feedbackRange)
        #expect(spec?.range.upperBound == 0.999)
        // The note is the user-facing half of this item: it must carry the
        // freeze, the measured reason for 0.999, and the build-up warning.
        let note = spec?.note ?? ""
        #expect(note.contains("ECHO FREEZE"))
        #expect(note.contains("0.999 AND NOT 1.0"))
        #expect(note.contains("1/(1 - feedback)"))
        let highCutNote = EffectParamSpec.specs(for: .delay)
            .first { $0.name == "highCutHz" }?.note ?? ""
        #expect(highCutNote.contains("3.19 dB down after 110 seconds"))
        #expect(highCutNote.contains("NOT a safety margin"))
    }

    // MARK: - L2: the freeze holds where 0.95 dies

    @Test("L2: at the ceiling a 60 s tail holds; at the old 0.95 maximum it is gone")
    func freezeHoldsWhereTheOldMaximumDied() throws {
        // 350 ms delay, mix 1 (the tail IS the output), highCut wide open.
        // ⚠️ The feedback comes from the RANGE, not a literal, so narrowing the
        // range reddens this leg instead of quietly weakening it.
        let seconds = 60
        let frozen = try render(
            params: DelayParams(timeMs: 350, feedback: DelayParams.feedbackRange.upperBound,
                                mix: 1, highCutHz: 20_000),
            input: burst, totalFrames: seconds * 48_000, binFrames: 10 * 48_000)
        let old = try render(
            params: DelayParams(timeMs: 350, feedback: 0.95, mix: 1, highCutHz: 20_000),
            input: burst, totalFrames: seconds * 48_000, binFrames: 10 * 48_000)

        let frozenEarly = amplitude(frozen[0]), frozenLate = amplitude(frozen[5])
        let oldEarly = amplitude(old[0]), oldLate = amplitude(old[5])
        print(String(format:
            "[measured] 350 ms tail, 220 Hz: FREEZE(%.3f) %.4f -> %.4f (%.2f dB over 50 s, "
            + "%.4f dB/s) · 0.95 %.4f -> %.6f (%.1f dB) · peaks %.4f -> %.4f",
            DelayParams.feedbackRange.upperBound, frozenEarly, frozenLate,
            db(frozenLate / frozenEarly), db(frozenLate / frozenEarly) / 50,
            oldEarly, oldLate, db(oldLate / oldEarly), frozen[0].peak, frozen[5].peak))

        // The freeze is still there, essentially at level, a minute later.
        #expect(frozenLate > 0.1)
        #expect(db(frozenLate / frozenEarly) > -2.5)      // measured -1.06 dB
        #expect(frozen[5].peak > 0.5)                     // measured 0.752
        // The old maximum is a decaying echo, not a freeze: 0.4455 dB per
        // repeat x 143 repeats in 50 s is ~64 dB, and that is what it measures
        // (-62.9). The claim is the RATIO — an absolute floor here would be
        // pinning the burst's level, not the decay.
        #expect(oldEarly > 0.05)                          // it DID ring at first
        #expect(db(oldLate / oldEarly) < -40)             // …and has decayed away
        #expect(oldLate < frozenLate * 0.01)              // three orders under the freeze
        #expect(frozen.allSatisfy { $0.nonFinite == 0 })  // NaN/Inf guard
    }

    // MARK: - L3: THE DIVERGENCE BOUND — why the ceiling is not 1.0

    @Test("L3: at the ceiling a sustained DC input converges; the increments collapse")
    func sustainedInputConvergesAtTheCeiling() throws {
        // DC is the worst case for this loop: the feedback filter is a one-pole
        // low-pass whose gain at DC is EXACTLY 1 at every highCutHz, so DC is
        // the frequency where the loop gain equals `feedback` outright. A 10 ms
        // delay makes the time constant timeMs/(1-f) ≈ 10 s, so 40 s of render
        // is four time constants — the asymptote is visible, not extrapolated.
        let feedback = DelayParams.feedbackRange.upperBound
        let predictedCeiling = 0.1 / (1 - feedback)          // 100 at 0.999
        for highCut in [500.0, 20_000.0] {
            let bins = try render(
                params: DelayParams(timeMs: 10, feedback: feedback, mix: 1,
                                    highCutHz: highCut),
                input: { _ in 0.1 }, totalFrames: 40 * 48_000, binFrames: 10 * 48_000)
            let peaks = bins.map(\.peak)
            let firstStep = peaks[1] - peaks[0]
            let lastStep = peaks[3] - peaks[2]
            print(String(format:
                "[measured] DC 0.1 into a 10 ms delay at feedback %.3f, highCut %.0f: "
                + "%.2f %.2f %.2f %.2f (ceiling 1/(1-f)x0.1 = %.1f) · steps %.2f -> %.2f",
                feedback, highCut, peaks[0], peaks[1], peaks[2], peaks[3],
                predictedCeiling, firstStep, lastStep))

            // It converges: each 10 s window adds less than the one before, and
            // the last window adds under a fifth of what the first did. At
            // feedback 1.0 the steps are CONSTANT (measured 96.97 per 10 s,
            // forever) and this is the assertion that catches it.
            #expect(lastStep < firstStep * 0.2)
            // …onto the predicted ceiling, not past it.
            #expect(peaks[3] < predictedCeiling * 1.05)
            #expect(peaks[3] > predictedCeiling * 0.9)     // it DID build (control)
            #expect(bins.allSatisfy { $0.nonFinite == 0 })
        }
    }

    @Test("L3b: highCutHz changes nothing about that ceiling — it is unity at DC")
    func theLoopFilterGivesNoMarginAtDC() throws {
        // The corrective half of L3, and the reason the design note's
        // "highCutHz is what keeps it from ringing forever" is only half true:
        // at DC the filter contributes NOTHING, so the 500 Hz and 20 kHz
        // settings build to the same place. What bounds this loop is the
        // feedback ceiling alone.
        let feedback = DelayParams.feedbackRange.upperBound
        var finalPeaks: [Double] = []
        for highCut in [500.0, 20_000.0] {
            let bins = try render(
                params: DelayParams(timeMs: 10, feedback: feedback, mix: 1,
                                    highCutHz: highCut),
                input: { _ in 0.1 }, totalFrames: 20 * 48_000, binFrames: 20 * 48_000)
            finalPeaks.append(bins[0].peak)
        }
        let spread = abs(finalPeaks[0] - finalPeaks[1]) / finalPeaks[1]
        print(String(format:
            "[measured] DC build-up at feedback %.3f: highCut 500 -> %.2f, 20000 -> %.2f "
            + "(spread %.4f%%)", feedback, finalPeaks[0], finalPeaks[1], spread * 100))
        #expect(spread < 0.02)
    }

    // MARK: - L4: the render-path re-clamp

    @Test("L4: an automation poke above the ceiling renders as the ceiling, bit-exact")
    func automationPokeCannotExceedTheCeiling() throws {
        // `storeAutomatedParam` pokes the overlay field directly and so bypasses
        // `DelayParams.init` — the clamp that matters on this path is the one in
        // `DelayEffect.deriveRenderParams`. Delete it and a lane (or a future
        // modulation route) could put the loop at or past unity.
        let params = DelayParams(timeMs: 120, feedback: 0.2, mix: 1, highCutHz: 12_000)
        let runaway = try render(params: params, feedbackOverride: 5.0, input: burst,
                                 totalFrames: 10 * 48_000, binFrames: 48_000)
        let ceiling = try render(params: params,
                                 feedbackOverride: DelayParams.feedbackRange.upperBound,
                                 input: burst, totalFrames: 10 * 48_000, binFrames: 48_000)
        print(String(format:
            "[measured] automation poke 5.0 vs ceiling: peaks %.5f / %.5f, "
            + "amp220 %.5f / %.5f", runaway[9].peak, ceiling[9].peak,
            amplitude(runaway[9]), amplitude(ceiling[9])))
        for index in runaway.indices {
            #expect(runaway[index].peak == ceiling[index].peak)
            #expect(runaway[index].nonFinite == 0)
        }
        #expect(ceiling[9].peak > 0.1)   // the renders were not both silence
    }

    // MARK: - L5: highCutHz is load-bearing at a freeze-grade feedback

    @Test("L5: at the ceiling the high-cut, not the feedback, sets how long the tail lasts")
    func highCutBoundsTheTailAtTheCeiling() throws {
        let feedback = DelayParams.feedbackRange.upperBound
        let seconds = 40
        var decayPerSecond: [Double] = []
        for highCut in [20_000.0, 500.0] {
            let bins = try render(
                params: DelayParams(timeMs: 350, feedback: feedback, mix: 1,
                                    highCutHz: highCut),
                input: burst, totalFrames: seconds * 48_000, binFrames: 10 * 48_000)
            let early = amplitude(bins[0]), late = amplitude(bins[3])
            decayPerSecond.append(-db(late / early) / 30)
            print(String(format:
                "[measured] 350 ms tail at feedback %.3f, highCut %.0f: 220 Hz %.5f -> %.6f "
                + "(%.3f dB/s) · peak %.4f -> %.4f",
                feedback, highCut, early, late, -db(late / early) / 30,
                bins[0].peak, bins[3].peak))
        }
        // ⚠️ Measured ON THE 220 Hz COMPONENT (what `amplitude` returns):
        // 0.013 dB/s wide open vs 2.201 dB/s at 500 Hz — 169x faster. The
        // BROADBAND PEAK figures for the same renders are 0.029 and 0.845
        // dB/s (the printout carries both); the param note quotes the peak
        // one. Two measures, both real — the burst's 660 Hz partial is
        // damped harder than its 220 Hz one, so the peak falls faster.
        // The bounds below stay loose on purpose: this leg is about the
        // ORDER OF THE TWO, not a pinned rate.
        #expect(decayPerSecond[0] < 0.1)
        #expect(decayPerSecond[1] > decayPerSecond[0] * 8)
    }

    // MARK: - L7: denormals on the way down

    @Test("L7: a released tail flushes to exact zero without crossing the subnormal band")
    func releasedTailNeverGoesSubnormal() throws {
        // ⚠️ The window is chosen so it ACTUALLY REACHES the band: feedback 0.5
        // at a 10 ms delay is 100 repeats a second at -6 dB each, so the loop
        // passes 1e-15 inside half a second and would reach ~1e-38 — real
        // subnormals — about a second later if the flush were gone. Every
        // quantum is inspected, not just the end: an effect whose tail lands on
        // exact zero at ONE instant hides the whole defect from a single read.
        let bins = try render(
            params: DelayParams(timeMs: 10, feedback: 0.5, mix: 1, highCutHz: 20_000),
            input: { $0 < 480 ? 0.5 : 0 },
            totalFrames: 3 * 48_000, binFrames: Self.chunk)   // one bin per quantum
        #expect(bins.count > 250)

        let subnormals = bins.reduce(0) { $0 + $1.subnormals }
        let nonFinite = bins.reduce(0) { $0 + $1.nonFinite }
        // The window really did descend into the danger zone…
        let floor = bins.map(\.minNonZero).filter { $0 < .greatestFiniteMagnitude }.min() ?? 1
        // …and everything after 1.5 s is EXACTLY zero, quantum by quantum.
        let tailQuanta = bins.dropFirst(Int(1.5 * Self.sampleRate) / Self.chunk)
        let liveTailQuanta = tailQuanta.filter { $0.nonZeroSamples > 0 }.count
        print(String(format:
            "[measured] released tail: %d quanta, smallest non-zero %.3e, subnormals %d, "
            + "non-finite %d, quanta with any non-zero sample after 1.5 s: %d",
            bins.count, floor, subnormals, nonFinite, liveTailQuanta))
        #expect(floor < 1e-15)          // the window reached the band (control)
        #expect(subnormals == 0)        // …and nothing subnormal was produced
        #expect(nonFinite == 0)
        #expect(liveTailQuanta == 0)    // the flush terminated the tail
    }

    // MARK: - L8: the byte pin for every project saved before m39-k

    @Test("L8: a feedback-0.95 render is byte-identical to the pre-m39-k build")
    func existingProjectsRenderExactlyAsBefore() throws {
        // ⚠️ THIS IS THE ONE-WAY-DOOR GUARD. Widening a range re-voices saved
        // work the moment any arithmetic on the path moves with it. The hash
        // below was captured from the build IMMEDIATELY BEFORE m39-k, over a
        // deterministic stereo render at the OLD maximum, and every byte of
        // every sample feeds it.
        //
        // If a future change to this effect is INTENDED to alter its sound,
        // this leg is the place that has to be updated deliberately — and the
        // projects that already sound a particular way are the reason that
        // should be a decision rather than a diff.
        let params = DelayParams(timeMs: 250, feedback: 0.95, mix: 0.45,
                                 pingPong: 1, highCutHz: 6_000)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunk)))
        let delay = DelayEffect(params: params)
        delay.prepare(sampleRate: Self.sampleRate,
                      maxFramesPerQuantum: Self.chunk, channelCount: 2)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var offset = 0
        let total = 96_000
        while offset < total {
            let frames = min(Self.chunk, total - offset)
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<frames {
                let index = offset + frame
                let t = Double(index) / Self.sampleRate
                let env = index < 9_600 ? 1.0 : 0.0
                data[0][frame] = Float(env * (0.4 * sin(2 * .pi * 220 * t)
                                              + 0.2 * sin(2 * .pi * 1_320 * t)))
                data[1][frame] = Float(env * 0.35 * sin(2 * .pi * 330 * t))
            }
            delay.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frames)
            for channel in 0..<2 {
                for frame in 0..<frames {
                    hash ^= UInt64(data[channel][frame].bitPattern)
                    hash = hash &* 0x0000_0100_0000_01B3
                }
            }
            offset += frames
        }
        print(String(format: "[measured] feedback-0.95 render FNV-1a = 0x%016llx "
                     + "(pre-m39-k pin 0x6c9d0055116388e8)", hash))
        #expect(hash == 0x6c9d_0055_1163_88e8)
    }

    // MARK: - L9: non-finite params never reach the loop

    @Test("L9: NaN in any field renders finite audio instead of trapping")
    func nonFiniteParamsAreGuarded() throws {
        // Fields are `var`s, so a caller CAN build a `DelayParams` that never
        // passed the clamping init. `Int(Double.nan)` traps outright, and a
        // NaN feedback would poison the line for the rest of the render.
        for field in 0..<3 {
            var params = DelayParams(timeMs: 200, feedback: 0.5, mix: 1, highCutHz: 9_000)
            switch field {
            case 0: params.timeMs = .nan
            case 1: params.feedback = .nan
            default: params.highCutHz = .nan
            }
            let bins = try render(params: params, input: burst,
                                  totalFrames: 2 * 48_000, binFrames: 48_000)
            #expect(bins.allSatisfy { $0.nonFinite == 0 })
            #expect(bins.allSatisfy { $0.subnormals == 0 })
        }
    }
}
