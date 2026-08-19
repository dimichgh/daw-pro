import Foundation
import Testing
@testable import DAWCore

/// m27 leg D — the pure breath/air contour generator.
///
/// NOT `@MainActor`: `BreathContour` is a free enum of pure functions with no
/// store, engine or UI reach, so its tests have no reason to be isolated (and
/// the tree is at its 330-`@MainActor`-suite ceiling).
///
/// Every assertion here is about the POINTS. That the points move rendered
/// audio is a different question, answered by `SamplerTests`' offline renders —
/// the original defect in this whole round was a CC contour that reached the
/// model correctly and produced byte-identical audio.
struct BreathContourTests {

    private let map = TempoMap(constantBPM: 120)   // 1 beat = 0.5 s

    private func generate(lengthBeats: Double,
                          startBeat: Double = 0,
                          clipStartBeat: Double = 0,
                          _ options: BreathContour.Options = .init()) -> BreathContour.Generated {
        BreathContour.generate(noteStartBeat: startBeat, noteLengthBeats: lengthBeats,
                               clipStartBeat: clipStartBeat, tempoMap: map, options: options)
    }

    // MARK: - Determinism and boundaries

    @Test("the generator is pure: identical arguments produce identical points")
    func determinism() {
        let a = generate(lengthBeats: 4)
        let b = generate(lengthBeats: 4)
        #expect(a == b)
        #expect(a.expression == b.expression)
        #expect(a.pitchBend == b.pitchBend)
    }

    @Test("every emitted point lies inside the note, and survives lane canonicalization intact")
    func pointsStayInsideTheNote() {
        let g = generate(lengthBeats: 4, startBeat: 2.5)
        #expect(!g.expression.isEmpty)
        #expect(!g.pitchBend.isEmpty)
        for point in g.expression + g.pitchBend {
            #expect(point.beat >= 2.5 - 1e-9)
            #expect(point.beat <= 6.5 + 1e-9)
        }
        // Canonicalization must not drop anything: no duplicate beats, already
        // ascending, values already inside their type's range.
        let cc = MIDIControllerLane(type: .cc(controller: 11), points: g.expression)
        let bend = MIDIControllerLane(type: .pitchBend, points: g.pitchBend)
        print("[measured] 4-beat note: \(g.expression.count) expression points "
              + "(canonical \(cc.points.count)), \(g.pitchBend.count) bend points "
              + "(canonical \(bend.points.count))")
        #expect(cc.points.count == g.expression.count)
        #expect(bend.points.count == g.pitchBend.count)
    }

    @Test("a zero-length note produces no points at all rather than a degenerate contour")
    func zeroLengthNote() {
        let g = generate(lengthBeats: 0)
        #expect(g.expression.isEmpty)
        #expect(g.pitchBend.isEmpty)
        #expect(g.vibratoStartBeat == nil)
        #expect(g.noteDurationSeconds == 0)
    }

    // MARK: - The expression contour's shape

    @Test("expression dips after the attack, peaks past the middle, then tapers")
    func expressionShape() {
        let g = generate(lengthBeats: 4)                       // 2.0 s
        let values = g.expression.map(\.value)
        let peak = values.max() ?? 0
        let trough = values.min() ?? 0
        let peakBeat = g.expression.first { $0.value == peak }?.beat ?? -1
        let troughBeat = g.expression.first { $0.value == trough }?.beat ?? -1
        print("[measured] expression peak \(peak) at beat \(peakBeat); trough \(trough) "
              + "at beat \(troughBeat); first \(values.first ?? -1) last \(values.last ?? -1)")

        // Peak is exactly the requested ceiling, trough exactly peak−travel.
        #expect(peak == 127)
        #expect(trough == Int((127.0 - 127.0 * 0.25).rounded()))   // 95
        // The trough is the SETTLING dip: 0.05 s in = beat 0.1.
        #expect(abs(troughBeat - 0.1) < 0.05)
        // The peak sits at 65 % of a 4-beat note = beat 2.6 — but the emitted
        // value SATURATES at 127 slightly before that (the raised-cosine is
        // flat near its top, so `raw` crosses 126.5 at ≈92 % of the rise) and
        // stepwise thinning keeps only the first point of the plateau. So the
        // assertion is "the plateau opens just before the nominal peak", not
        // "a sample lands exactly on it".
        #expect(peakBeat > 2.0)
        #expect(peakBeat <= 2.6)
        // Onset above the dip, taper between the dip and the peak.
        #expect(values.first! > trough)
        #expect(values.last! > trough)
        #expect(values.last! < peak)
        // Monotone rise from the dip to the peak, monotone fall after it.
        let rising = g.expression.filter { $0.beat >= troughBeat && $0.beat <= peakBeat }
        #expect(zip(rising, rising.dropFirst()).allSatisfy { $0.value <= $1.value })
        let falling = g.expression.filter { $0.beat >= peakBeat }
        #expect(zip(falling, falling.dropFirst()).allSatisfy { $0.value >= $1.value })
    }

    @Test("depth 0 is a valid no-op on the loudness axis: one flat value at the peak")
    func zeroDepthIsFlat() {
        let g = generate(lengthBeats: 4, .init(depth: 0))
        #expect(Set(g.expression.map(\.value)) == [127])
        // Stepwise thinning collapses a constant run to its two endpoints.
        #expect(g.expression.count == 2)
    }

    @Test("depth and peakValue set the contour's real endpoints, not an abstract scale")
    func depthControlsTravel() {
        let g = generate(lengthBeats: 4, .init(depth: 0.5, peakValue: 100))
        let values = g.expression.map(\.value)
        print("[measured] depth 0.5 / peak 100: peak \(values.max()!) trough \(values.min()!)")
        #expect(values.max() == 100)
        #expect(values.min() == 50)
    }

    /// ⭐ THE EMERGENT PROPERTY, pinned so it cannot regress unnoticed.
    /// Stepwise thinning makes the expression run's LENGTH a function of the
    /// contour's VALUE range, not of the sampling rate: the rise passes through
    /// ~32 distinct CC values at the default depth and cannot emit more than
    /// that however finely it is sampled. `expressionSpacingSeconds` therefore
    /// buys resolution in TIME (when each step lands), and only coarsening it
    /// past the value spacing reduces the count. That is what keeps a whole
    /// clip of notes clear of the 16384-point lane cap.
    @Test("expression point count is bounded by DISTINCT VALUES, not by the sampling rate")
    func expressionDensityIsValueBounded() {
        func riseCount(_ spacing: Double) -> Int {
            let g = generate(lengthBeats: 8, .init(expressionSpacingSeconds: spacing))
            return g.expression.filter { $0.beat > 0.2 && $0.beat < 5.2 }.count
        }
        let fine = riseCount(0.005), mid = riseCount(0.02), coarse = riseCount(0.5)
        // 127 × 0.25 travel, rising from the dip = at most ~32 distinct values.
        print("[measured] rise-region point count: 5 ms → \(fine), 20 ms → \(mid), "
              + "500 ms → \(coarse) (distinct values available on the rise: 32)")
        #expect(fine <= 33)
        #expect(abs(fine - mid) <= 3)             // 4× the rate buys ~nothing
        #expect(coarse < mid / 2)                 // coarser than the values DOES bite
    }

    // MARK: - The short-note rule

    @Test("a note too short for the straight opening plus one vibrato cycle gets NO bend lane")
    func shortNoteHasNoVibrato() {
        // 0.3 beats at 120 BPM = 0.15 s, well under 0.5 s + 1/5.5 s.
        let g = generate(lengthBeats: 0.3)
        print("[measured] 0.3-beat note: \(g.expression.count) expression points, "
              + "\(g.pitchBend.count) bend points, vibratoStartBeat \(String(describing: g.vibratoStartBeat))")
        #expect(g.pitchBend.isEmpty)
        #expect(g.vibratoStartBeat == nil)
        #expect(!g.expression.isEmpty)          // it still breathes, just straight
    }

    @Test("the boundary is exactly onset + one cycle, and it is crossable from both sides")
    func vibratoBoundary() {
        // 0.5 s onset + 1/5.5 s cycle = 0.68182 s = 1.36364 beats at 120 BPM.
        let justUnder = generate(lengthBeats: 1.36)
        let justOver = generate(lengthBeats: 1.37)
        print("[measured] 1.36 beats → bend \(justUnder.pitchBend.count); "
              + "1.37 beats → bend \(justOver.pitchBend.count)")
        #expect(justUnder.pitchBend.isEmpty)
        #expect(!justOver.pitchBend.isEmpty)
    }

    @Test("the settling dip is clamped to a quarter of a short note instead of swallowing it")
    func shortNoteDipIsClamped() {
        // 0.1 beats = 0.05 s: the dip's own default length is the WHOLE note.
        let g = generate(lengthBeats: 0.1)
        let trough = g.expression.min { $0.value < $1.value }!
        print("[measured] 0.1-beat note: trough at beat \(trough.beat) of 0.1, "
              + "\(g.expression.count) points, values \(g.expression.map(\.value))")
        #expect(trough.beat <= 0.1 * BreathContour.maxSettleFraction + 1e-9)
        #expect(trough.beat > 0)
        // Still the same curve, just small: it dips, then rises to the peak.
        #expect(g.expression.map(\.value).max() == 127)
    }

    // MARK: - Vibrato

    @Test("vibrato is DELAYED: the bend lane holds centre-ish until the onset, then oscillates")
    func vibratoIsDelayed() {
        let g = generate(lengthBeats: 8)          // 4.0 s
        let onsetBeat = try! #require(g.vibratoStartBeat)
        #expect(abs(onsetBeat - 1.0) < 1e-6)      // 0.5 s at 120 BPM

        // Before the onset the only deflection is micro-sharpening (≤ 4 cents
        // = 164 units at ±2 semitones); after it, vibrato dwarfs that.
        let before = g.pitchBend.filter { $0.beat < onsetBeat }
        let after = g.pitchBend.filter { $0.beat > onsetBeat + 1.5 }
        let beforeMax = before.map { abs($0.value - 8192) }.max() ?? 0
        let afterMax = after.map { abs($0.value - 8192) }.max() ?? 0
        print("[measured] max |bend−8192|: before onset \(beforeMax), settled vibrato \(afterMax)")
        #expect(beforeMax <= 200)
        #expect(afterMax > 400)
    }

    @Test("vibrato oscillates at the requested rate — measured by zero crossings, not asserted")
    func vibratoRateIsMeasured() {
        // Measure inside the fully-bloomed, pre-relax window so the envelope
        // cannot add or remove a crossing at either end.
        func measuredHz(_ rate: Double) -> Double {
            let g = generate(lengthBeats: 16, .init(vibratoRateHz: rate))   // 8.0 s
            let window = g.pitchBend.filter { $0.beat > 3.6 && $0.beat < 15.0 }
            var crossings = 0
            for (a, b) in zip(window, window.dropFirst()) {
                let x = a.value - 8192, y = b.value - 8192
                if (x < 0 && y >= 0) || (x > 0 && y <= 0) { crossings += 1 }
            }
            let seconds = (15.0 - 3.6) * 0.5
            return Double(crossings) / 2 / seconds
        }
        let five = measuredHz(5.5)
        let seven = measuredHz(7.0)
        print("[measured] vibrato rate: requested 5.5 Hz → \(five) Hz; "
              + "requested 7.0 Hz → \(seven) Hz")
        #expect(abs(five - 5.5) < 0.25)
        #expect(abs(seven - 7.0) < 0.25)
    }

    /// ⚠️⚠️ Every vibrato-WIDTH measurement below turns micro-sharpening OFF
    /// (`sharpenCents: 0`), exactly as leg C's filter tests drive the cutoff
    /// from CC1 with `expressionModDepth` off. Measured, not assumed: with
    /// sharpening on, `max |value − 8192|` over the settled region reads **653**
    /// for a ±12-cent vibrato (= 491 + the 163-unit sharpen bias) and even a
    /// peak-to-trough swing reads **572** (the sharpen DRIFTS across the
    /// window). Both would have been recorded as a 14-16 cent vibrato. Two
    /// correlated gestures on one lane cannot be measured together.
    private func swingUnits(_ points: [MIDIControllerPoint],
                            _ window: Range<Double>) -> Int {
        let inWindow = points.filter { window.contains($0.beat) }.map(\.value)
        guard let hi = inWindow.max(), let lo = inWindow.min() else { return 0 }
        return (hi - lo) / 2
    }

    @Test("vibrato WIDENS: the first cycle is far narrower than the settled depth")
    func vibratoBlooms() {
        let g = generate(lengthBeats: 12, .init(sharpenCents: 0))          // 6.0 s
        let onset = try! #require(g.vibratoStartBeat)
        // First cycle after the onset (1/5.5 s = 0.364 beats) vs the settled
        // region well past the 0.7 s bloom and before the 80 ms relax.
        let firstDepth = swingUnits(g.pitchBend, onset ..< (onset + 0.364))
        let settledDepth = swingUnits(g.pitchBend, (onset + 2.0) ..< 11.0)
        // ±12 cents at ±2 semitones (200 cents per 8192 units) = 491 units.
        print("[measured] first-cycle swing \(firstDepth) units, settled \(settledDepth) "
              + "(±12 cents = 491)")
        #expect(firstDepth < settledDepth / 2)
        #expect(abs(Double(settledDepth) - 491) < 15)
    }

    @Test("vibratoDepthCents scales the deflection proportionally")
    func vibratoDepthScales() {
        func depth(_ cents: Double) -> Int {
            swingUnits(generate(lengthBeats: 12,
                                .init(vibratoDepthCents: cents, sharpenCents: 0)).pitchBend,
                       3 ..< 11)
        }
        let twelve = depth(12), twentyFour = depth(24)
        print("[measured] ±12 cents → \(twelve) units swing; ±24 cents → \(twentyFour)")
        #expect(abs(Double(twentyFour) / Double(twelve) - 2) < 0.02)
    }

    @Test("a wider bendRangeSemitones needs FEWER units for the same cents")
    func bendRangeIsHonoured() {
        func depth(_ semitones: Double) -> Int {
            swingUnits(generate(lengthBeats: 12,
                                .init(sharpenCents: 0,
                                      bendRangeSemitones: semitones)).pitchBend,
                       3 ..< 11)
        }
        let two = depth(2), twelve = depth(12)
        print("[measured] ±12 cents at ±2 st → \(two) units; at ±12 st → \(twelve) units")
        #expect(abs(Double(two) / Double(twelve) - 6) < 0.1)
    }

    @Test("THE HAND-OFF GUARD: the bend lane ends at exactly 8192 so the next note starts in tune")
    func bendReturnsToCentre() {
        for length in [1.4, 2.0, 4.0, 8.0, 33.0] {
            let g = generate(lengthBeats: length, startBeat: 1)
            let last = try! #require(g.pitchBend.last)
            #expect(last.value == 8192)
            #expect(abs(last.beat - (1 + length)) < 1e-9)
            // And nothing sits past the note's end.
            #expect(g.pitchBend.allSatisfy { $0.beat <= 1 + length + 1e-9 })
        }
    }

    // MARK: - Micro-sharpening

    @Test("the contour sharpens at the top of the swell and resolves as it falls")
    func microSharpening() {
        // Vibrato off isolates the sharpening: with it on, the ± oscillation
        // swamps a 4-cent bias in any single sample.
        let g = generate(lengthBeats: 8, .init(vibratoDepthCents: 0))
        let peakBeat = 8.0 * 0.65
        let atPeak = g.pitchBend.min { abs($0.beat - peakBeat) < abs($1.beat - peakBeat) }!
        let atStart = g.pitchBend.first!
        let atEnd = g.pitchBend.last!
        // 4 cents at ±2 semitones = 4 / (200/8192) = 164 units.
        print("[measured] sharpening: onset \(atStart.value - 8192), peak "
              + "\(atPeak.value - 8192) units (4 cents = 164), end \(atEnd.value - 8192)")
        #expect(atStart.value == 8192)
        #expect(abs(Double(atPeak.value - 8192) - 164) < 6)
        #expect(atEnd.value == 8192)
    }

    @Test("sharpenCents 0 leaves the pre-vibrato region exactly at centre")
    func sharpeningCanBeDisabled() {
        let g = generate(lengthBeats: 8, .init(sharpenCents: 0))
        let onset = try! #require(g.vibratoStartBeat)
        let before = g.pitchBend.filter { $0.beat < onset }
        #expect(!before.isEmpty)
        #expect(before.allSatisfy { $0.value == 8192 })
    }

    // MARK: - The point budget

    @Test("a budget too small for the requested spacing WIDENS the spacing and reports it")
    func budgetWidensSpacing() {
        // A 40-beat (20 s) note at 8 ms needs ~2400 bend points. A 1000-point
        // budget forces ~20 ms — coarser than requested, but still finer than
        // the 22.7 ms floor (one cycle / 8), so widening alone is enough and
        // no vibrato is lost.
        let g = generate(lengthBeats: 40, .init(maxPointsPerLane: 1000))
        print("[measured] cap 1000 on a 40-beat note: \(g.pitchBend.count) bend points, "
              + "\(g.expression.count) expression, bendSpacing \(g.bendSpacingSecondsUsed) s "
              + "(requested 0.008), truncatedAt \(String(describing: g.vibratoTruncatedAtBeat))")
        #expect(g.pitchBend.count <= 1000)
        #expect(g.expression.count <= 1000)
        #expect(g.bendSpacingSecondsUsed > 0.008)
        #expect(g.vibratoTruncatedAtBeat == nil)      // widening was enough
        #expect(g.pitchBend.last?.value == 8192)      // the guard survives the squeeze
        // And the vibrato still runs to the note's end (the note is 40 beats
        // long; 30...39 is the last quarter of it).
        #expect(swingUnits(g.pitchBend, 30 ..< 39) > 400)
    }

    @Test("a budget too small even at the coarsest representable spacing TRUNCATES, never aliases")
    func budgetTruncatesRatherThanAliasing() {
        // 200 beats = 100 s of vibrato. The coarsest spacing that still shows
        // the oscillation is one cycle / 8 = 22.7 ms, so ~4370 points are
        // needed; a 60-point cap cannot buy that at any spacing.
        let g = generate(lengthBeats: 200, .init(maxPointsPerLane: 60))
        let truncated = try! #require(g.vibratoTruncatedAtBeat)
        print("[measured] cap 60 on a 200-beat note: \(g.pitchBend.count) bend points, "
              + "spacing \(g.bendSpacingSecondsUsed) s, vibrato cut at beat \(truncated) of 200")
        #expect(g.pitchBend.count <= 60)
        #expect(truncated < 200)
        #expect(truncated > 1)
        // Never coarser than 8 points per cycle — that is the whole point of
        // truncating instead of stretching further.
        #expect(g.bendSpacingSecondsUsed <= (1 / 5.5) / BreathContour.minPointsPerVibratoCycle + 1e-9)
        // After the cut the lane holds centre to the end.
        #expect(g.pitchBend.last?.value == 8192)
        #expect(abs((g.pitchBend.last?.beat ?? 0) - 200) < 1e-9)
    }

    @Test("at the default 16384 budget a realistic ballad note is nowhere near the cap")
    func realisticNoteIsWellUnderTheCap() {
        let g = generate(lengthBeats: 6)     // 3 s — a long held sax note
        print("[measured] 3-second note: \(g.expression.count) expression + "
              + "\(g.pitchBend.count) bend points (cap 16384 each)")
        #expect(g.pitchBend.count < 500)
        #expect(g.expression.count < 200)
        #expect(g.bendSpacingSecondsUsed == 0.008)
    }

    // MARK: - Tempo

    @Test("the shape is anchored in SECONDS, so halving the tempo doubles the beat span")
    func tempoMapIsHonoured() {
        let slow = BreathContour.generate(noteStartBeat: 0, noteLengthBeats: 2,
                                          clipStartBeat: 0, tempoMap: TempoMap(constantBPM: 60))
        let fast = BreathContour.generate(noteStartBeat: 0, noteLengthBeats: 2,
                                          clipStartBeat: 0, tempoMap: TempoMap(constantBPM: 120))
        print("[measured] 2 beats @60 BPM = \(slow.noteDurationSeconds) s, vibrato at beat "
              + "\(String(describing: slow.vibratoStartBeat)); @120 BPM = "
              + "\(fast.noteDurationSeconds) s, vibrato at beat "
              + "\(String(describing: fast.vibratoStartBeat))")
        #expect(abs(slow.noteDurationSeconds - 2.0) < 1e-9)
        #expect(abs(fast.noteDurationSeconds - 1.0) < 1e-9)
        // 0.5 s of straight playing is HALF a beat at 60 BPM and a WHOLE beat
        // at 120 — the thing a scalar seconds-per-beat could not get right
        // across a tempo change. Same note, same options, different lanes.
        #expect(abs(try! #require(slow.vibratoStartBeat) - 0.5) < 1e-9)
        #expect(abs(try! #require(fast.vibratoStartBeat) - 1.0) < 1e-9)
        // And the SHORT-NOTE RULE is a seconds rule too: at 240 BPM those same
        // 2 beats are 0.5 s, under the onset, so there is no bend lane at all.
        let veryFast = BreathContour.generate(noteStartBeat: 0, noteLengthBeats: 2,
                                              clipStartBeat: 0,
                                              tempoMap: TempoMap(constantBPM: 240))
        #expect(veryFast.pitchBend.isEmpty)
        #expect(veryFast.vibratoStartBeat == nil)
    }

    @Test("a tempo RAMP under the note is integrated, not approximated from one BPM")
    func tempoRampIsIntegrated() throws {
        let ramp = try TempoMap(segments: [.init(startBeat: 0, bpm: 60),
                                           .init(startBeat: 2, bpm: 240)])
        let g = BreathContour.generate(noteStartBeat: 0, noteLengthBeats: 4,
                                       clipStartBeat: 0, tempoMap: ramp)
        // 2 beats at 60 BPM (2 s) + 2 beats at 240 BPM (0.5 s) = 2.5 s.
        print("[measured] 4 beats across a 60→240 ramp: \(g.noteDurationSeconds) s "
              + "(a flat 60 BPM read would say 4.0, a flat 240 read 1.0)")
        #expect(abs(g.noteDurationSeconds - 2.5) < 1e-9)
        #expect(g.expression.allSatisfy { $0.beat >= 0 && $0.beat <= 4 + 1e-9 })
        #expect(g.pitchBend.last?.value == 8192)
    }

    // MARK: - Helpers

    @Test("stepwise thinning drops repeats but never the endpoints")
    func thinningKeepsEndpoints() {
        let points = [MIDIControllerPoint(beat: 0, value: 10),
                      MIDIControllerPoint(beat: 1, value: 10),
                      MIDIControllerPoint(beat: 2, value: 20),
                      MIDIControllerPoint(beat: 3, value: 20),
                      MIDIControllerPoint(beat: 4, value: 20)]
        let thinned = BreathContour.thin(points)
        #expect(thinned.map(\.beat) == [0, 2, 4])
        #expect(thinned.map(\.value) == [10, 20, 20])
    }

    @Test("out-of-domain options are healed rather than producing nonsense")
    func optionsAreSanitized() {
        let g = generate(lengthBeats: 4, .init(depth: 9, peakValue: 400, peakPosition: -3,
                                               expressionSpacingSeconds: 0,
                                               vibratoRateHz: 0, bendSpacingSeconds: -1,
                                               bendRangeSemitones: 0, maxPointsPerLane: 0))
        print("[measured] healed run: \(g.expression.count) expression + \(g.pitchBend.count) bend")
        #expect(!g.expression.isEmpty)
        #expect(g.expression.allSatisfy { (0...127).contains($0.value) })
        #expect(g.pitchBend.allSatisfy { (0...16383).contains($0.value) })
    }
}
