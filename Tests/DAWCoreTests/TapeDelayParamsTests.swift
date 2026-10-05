import Foundation
import Testing
@testable import DAWCore

/// m39-n — the SCHEMA and LAW half of `.tapeDelay` (free-ms mode). The DSP half
/// is `DAWEngineTests/TapeDelayTests`; the store's name→field mapping rides in
/// `EffectChainStoreTests`' generic coverage and the document mirror in
/// `PersistenceTests`.
///
/// ⭐ THE LEG THAT MATTERS MOST HERE IS `minimumDelayInvariantHolds`. Everything
/// about this effect's memory safety reduces to one inequality — the shortest
/// delay time must exceed the deepest wobble — and NOTHING in the compiler
/// connects `timeRange.lowerBound` to the two depth ranges. Widen a depth
/// without widening the floor and the read tap walks into the write head, on
/// the render thread, with no bounds check (§4.1 froze that there is none).
///
/// NOT `@MainActor`: every leg is pure value-type arithmetic (the m23-aw
/// cadence — the honest way to not spend a main-actor suite is to not need one,
/// and `MainActorOccupancySiteTests` Leg C pins the isolated-suite count at its
/// cap with zero slack).
@Suite("m39-n tapeDelay — ranges, the transport law, and the cents arithmetic")
struct TapeDelayParamsTests {

    // MARK: - The invariant the whole effect's safety rests on

    /// ⛔ The downward-only sweep can reach `timeMs - wowDepth - flutterDepth`.
    /// At the worst case that is `timeRange.lowerBound` minus BOTH maxima, and
    /// it must stay comfortably positive — and above `.cubicHermite`'s 2-sample
    /// stencil floor at every sample rate CoreAudio can deliver.
    @Test("the shortest delay exceeds the deepest wobble, at every plausible rate")
    func minimumDelayInvariantHolds() {
        let deepest = TapeDelayParams.wowDepthRange.upperBound
            + TapeDelayParams.flutterDepthRange.upperBound
        #expect(TapeDelayParams.timeRange.lowerBound > deepest,
                "a depth range was widened without widening the time floor")
        #expect(abs(TapeDelayParams.minimumDelayMs
                    - (TapeDelayParams.timeRange.lowerBound - deepest)) < 1e-12)
        #expect(TapeDelayParams.minimumDelayMs == 11.0)

        // `.cubicHermite` needs 2 samples. The floor clears it by orders of
        // magnitude at every rate anyone can select, INCLUDING the 8 kHz a
        // speech codec might hand us.
        for rate in [8_000.0, 22_050, 44_100, 48_000, 96_000, 192_000] {
            let samples = TapeDelayParams.minimumDelaySamples(sampleRate: rate)
            #expect(samples >= 2,
                    Comment(rawValue: "at \(rate) Hz the floor is \(samples) samples, "
                        + "below cubicHermite's stencil"))
        }
        #expect(abs(TapeDelayParams.minimumDelaySamples(sampleRate: 48_000) - 528) < 1e-9)
        // Non-finite rate falls back rather than producing a NaN that would
        // reach `prepare` and be refused for the wrong reason.
        #expect(TapeDelayParams.minimumDelaySamples(sampleRate: .nan).isFinite)
    }

    /// §4.1 fixed the capacity for this caller at 4.0 s, and the time range's
    /// ceiling IS that number. One home, so they cannot drift apart.
    @Test("§4.1: the declared line capacity is 4.0 s and equals the longest delay")
    func capacityMatchesTheLongestDelay() {
        #expect(TapeDelayParams.lineCapacitySeconds == 4.0)
        #expect(TapeDelayParams.lineCapacitySeconds
                == TapeDelayParams.timeRange.upperBound * 0.001)
    }

    // MARK: - The transport law

    /// The offset is UNIPOLAR and bounded — checked over a dense phase grid at
    /// the maximum depths, which is where a sign error or a factor of two
    /// would show. Non-vacuity: the grid must actually reach both ends.
    @Test("the transport offset never leaves [0, wowDepth + flutterDepth]")
    func transportOffsetIsBounded() {
        let wowD = TapeDelayParams.wowDepthRange.upperBound
        let flutD = TapeDelayParams.flutterDepthRange.upperBound
        var minimum = Double.infinity
        var maximum = -Double.infinity
        for i in 0..<720 {
            let w = Double(i) * .pi / 180
            for j in 0..<72 {
                let a = Double(j) * .pi / 36
                let b = Double(j) * 1.6027 * .pi / 36
                let offset = TapeDelayParams.transportOffsetMs(
                    wowPhase: w, flutterPhaseA: a, flutterPhaseB: b,
                    wowDepthMs: wowD, flutterDepthMs: flutD)
                minimum = min(minimum, offset)
                maximum = max(maximum, offset)
            }
        }
        #expect(minimum >= 0)
        #expect(maximum <= wowD + flutD + 1e-12)
        // Non-vacuity: the grid really did sweep, so "bounded" is not "constant".
        #expect(maximum - minimum > 0.9 * wowD,
                "the grid never moved — this leg would pass on a frozen transport")
    }

    /// Depth 0 on both axes is a PERFECTLY STEADY transport: the offset is
    /// exactly 0 and the read delay is exactly `timeMs`, at every phase. This
    /// is what makes every other measurement in the engine suite possible.
    @Test("zero depth is an exactly steady transport at every phase")
    func zeroDepthIsExactlySteady() {
        for i in 0..<360 {
            let phase = Double(i) * .pi / 180
            let offset = TapeDelayParams.transportOffsetMs(
                wowPhase: phase, flutterPhaseA: phase * 2, flutterPhaseB: phase * 3,
                wowDepthMs: 0, flutterDepthMs: 0)
            #expect(offset == 0)
            #expect(TapeDelayParams.readDelayMs(
                timeMs: 350, wowPhase: phase, flutterPhaseA: phase * 2,
                flutterPhaseB: phase * 3, wowDepthMs: 0, flutterDepthMs: 0) == 350)
        }
    }

    /// Non-finite inputs fall back instead of propagating — the value reaches
    /// `Int()` on the render thread and `Int(Double.nan)` TRAPS. A
    /// field-by-field automation poke bypasses `init`, so the guard has to be
    /// in the law (the `FlangerParams.sweptDelayMs` precedent).
    @Test("every non-finite input to the transport law is guarded, not propagated")
    func transportLawGuardsNonFinite() {
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(TapeDelayParams.transportOffsetMs(
                wowPhase: bad, flutterPhaseA: 0, flutterPhaseB: 0,
                wowDepthMs: 4, flutterDepthMs: 0.5).isFinite)
            #expect(TapeDelayParams.transportOffsetMs(
                wowPhase: 0, flutterPhaseA: 0, flutterPhaseB: 0,
                wowDepthMs: bad, flutterDepthMs: bad).isFinite)
            let delay = TapeDelayParams.readDelayMs(
                timeMs: bad, wowPhase: 0, flutterPhaseA: 0, flutterPhaseB: 0,
                wowDepthMs: bad, flutterDepthMs: bad)
            #expect(delay.isFinite)
            #expect(delay >= TapeDelayParams.minimumDelayMs)
        }
        // Out-of-range depths are CLAMPED by the law, not trusted — that is
        // what keeps the bound above true on the automation path.
        let huge = TapeDelayParams.transportOffsetMs(
            wowPhase: .pi / 2, flutterPhaseA: .pi / 2, flutterPhaseB: .pi / 2,
            wowDepthMs: 900, flutterDepthMs: 900)
        #expect(huge <= TapeDelayParams.wowDepthRange.upperBound
                + TapeDelayParams.flutterDepthRange.upperBound + 1e-12)
    }

    // MARK: - The cents arithmetic, checked against an INDEPENDENT derivation

    /// ⭐⭐ THE HEADLINE NUMBER, AND IT IS NOT CHECKED AGAINST ITSELF. A delay
    /// line read at `d(t)` replays at pitch ratio `1 - d'(t)`. This leg
    /// NUMERICALLY DIFFERENTIATES `readDelayMs` over a full wow cycle, takes
    /// the peak, converts to cents, and compares against the closed form
    /// `wowCents`. The two share no code: one is finite differences on the
    /// transport law, the other is `1200·log2(1 + π·f·D)`. If the closed form
    /// were off by the factor of two that `0.5 + 0.5·sin` invites, this leg
    /// would catch it.
    @Test("wowCents matches a numeric differentiation of the transport law")
    func wowCentsMatchesNumericDifferentiation() {
        let sampleRate = 48_000.0
        for (depthMs, rateHz) in [(2.5, 0.8), (8.0, 3.0), (1.0, 0.5), (5.0, 1.6)] {
            let increment = 2.0 * .pi * rateHz / sampleRate
            var peakRatio = 0.0
            let cycleFrames = Int(sampleRate / rateHz) + 2
            var previous = TapeDelayParams.readDelayMs(
                timeMs: 350, wowPhase: 0, flutterPhaseA: 0, flutterPhaseB: 0,
                wowDepthMs: depthMs, flutterDepthMs: 0)
            for frame in 1...cycleFrames {
                let phase = Double(frame) * increment
                let current = TapeDelayParams.readDelayMs(
                    timeMs: 350, wowPhase: phase, flutterPhaseA: 0, flutterPhaseB: 0,
                    wowDepthMs: depthMs, flutterDepthMs: 0)
                // d'(t) in seconds per second: ms per sample -> s per s.
                let slope = (current - previous) * 0.001 * sampleRate
                peakRatio = max(peakRatio, abs(slope))
                previous = current
            }
            let numericCents = 1200 * log2(1 + peakRatio)
            let closedForm = TapeDelayParams.wowCents(depthMs: depthMs, rateHz: rateHz)
            print("[measured] m39-n wow — depth \(depthMs) ms @ \(rateHz) Hz: "
                  + "closed form \(String(format: "%.2f", closedForm)) cents, "
                  + "numeric \(String(format: "%.2f", numericCents)) cents")
            #expect(abs(numericCents - closedForm) < 0.05,
                    Comment(rawValue: "closed form \(closedForm), numeric \(numericCents)"))
        }
    }

    /// The numbers the param notes quote, pinned so the prose and the code
    /// cannot drift. Also the shape claim: cents is INDEPENDENT of `timeMs`
    /// (the wobble is an absolute excursion, not a percentage).
    ///
    /// ⚠️ THE TOLERANCE IS 0.05 ON PURPOSE, AND IT WAS 0.5 WHEN THIS SHIPPED
    /// (m39-n, caught in review). At 0.5 the prose could say "125.5 cents"
    /// while the arithmetic said 125.845 and this test stayed green — which is
    /// exactly what happened, in TWO places: the wow maximum and the flutter
    /// maximum (51.1 quoted against 50.913). A pin whose tolerance is wider
    /// than the rounding of the figure it pins is not pinning the figure, it is
    /// pinning the order of magnitude. 0.05 is half of the last quoted digit,
    /// so every figure below is now checked to the precision it is WRITTEN at.
    @Test("the quoted cents figures are the ones the arithmetic produces")
    func quotedCentsFiguresAreReal() {
        let atDefault = TapeDelayParams.wowCents(depthMs: 2.5, rateHz: 0.8)
        let atMaximum = TapeDelayParams.wowCents(
            depthMs: TapeDelayParams.wowDepthRange.upperBound,
            rateHz: TapeDelayParams.wowRateRange.upperBound)
        print("[measured] m39-n quoted figures — wow default \(atDefault), "
              + "wow maximum \(atMaximum)")
        #expect(abs(atDefault - 10.8) < 0.05)
        #expect(abs(atMaximum - 125.8) < 0.05)
        #expect(TapeDelayParams.wowCents(depthMs: 0, rateHz: 3) == 0)

        let flutterDefault = TapeDelayParams.flutterCents(depthMs: 0.25)
        let flutterMax = TapeDelayParams.flutterCents(
            depthMs: TapeDelayParams.flutterDepthRange.upperBound)
        print("[measured] m39-n quoted figures — flutter default \(flutterDefault), "
              + "flutter maximum \(flutterMax)")
        #expect(abs(flutterDefault - 12.9) < 0.05)
        #expect(abs(flutterMax - 50.9) < 0.05)
        #expect(TapeDelayParams.flutterCents(depthMs: 0) == 0)

        // ⭐ THE ASYMMETRY, pinned as arithmetic rather than left as a surprise
        // in a render log. The pitch ratio is `1 - d'(t)`, so the DOWNWARD peak
        // is `-1200*log2(1 - pi*f*D)` and is always the larger of the two. This
        // is the whole explanation of L3's measured +40.32 / -41.28 against a
        // single predicted 40.32, and of the flutter leg's 51.85 measured
        // against 50.91 predicted.
        let downAtMaximum = -1200 * log2(1 - Double.pi * 3 * 0.008)
        #expect(abs(downAtMaximum - 135.7) < 0.05)
        #expect(downAtMaximum > atMaximum, "the downward branch is the larger one")
        let downAtFiveMs = -1200 * log2(1 - Double.pi * 1.5 * 0.005)
        let upAtFiveMs = TapeDelayParams.wowCents(depthMs: 5, rateHz: 1.5)
        #expect(abs(upAtFiveMs - 40.32) < 0.01)
        #expect(abs(downAtFiveMs - 41.28) < 0.01)

        // Doubling either axis roughly doubles the deviation (exactly, before
        // the log compresses it) — the "the two controls multiply" claim.
        let doubled = TapeDelayParams.wowCents(depthMs: 5.0, rateHz: 0.8)
        #expect(doubled > 1.95 * atDefault && doubled < 2.0 * atDefault)

        // Non-finite in, finite out.
        #expect(TapeDelayParams.wowCents(depthMs: .nan, rateHz: .nan).isFinite)
        #expect(TapeDelayParams.flutterCents(depthMs: .infinity).isFinite)
    }

    /// ⭐⭐ THE PIN ABOVE DOES NOT ACTUALLY READ THE PROSE, AND THAT IS HOW THE
    /// PROSE DRIFTED.
    ///
    /// `quotedCentsFiguresAreReal` compares the arithmetic to LITERALS that
    /// were copied out of the param notes by hand. Copies rot: the wow note
    /// said 125.5 and the flutter note 51.1 while the closed forms were 125.845
    /// and 50.913, and the test stayed green because it was checking its own
    /// copy, not the shipped sentence. THIS test reads the note strings an
    /// agent and a novice actually see and asserts the arithmetic is IN them,
    /// formatted to the precision they are written at. There is no literal
    /// here to keep in sync — `%.1f` of the closed form IS the expectation.
    @Test("the shipped param NOTES quote the figures the arithmetic produces")
    func paramNotesQuoteTheRealFigures() throws {
        let specs = EffectParamSpec.specs(for: .tapeDelay)
        let wowNote = try #require(specs.first { $0.name == "wowDepthMs" }?.note)
        let flutterNote = try #require(specs.first { $0.name == "flutterDepthMs" }?.note)

        func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }

        let defaultWow = oneDecimal(TapeDelayParams.wowCents(depthMs: 2.5, rateHz: 0.8))
        let maxWow = oneDecimal(TapeDelayParams.wowCents(
            depthMs: TapeDelayParams.wowDepthRange.upperBound,
            rateHz: TapeDelayParams.wowRateRange.upperBound))
        #expect(wowNote.contains("\(defaultWow) cents"),
                Comment(rawValue: "the wow note does not quote \(defaultWow) cents: \(wowNote)"))
        #expect(wowNote.contains("\(maxWow) cents"),
                Comment(rawValue: "the wow note does not quote \(maxWow) cents: \(wowNote)"))

        let defaultFlutter = oneDecimal(TapeDelayParams.flutterCents(depthMs: 0.25))
        let maxFlutter = oneDecimal(TapeDelayParams.flutterCents(
            depthMs: TapeDelayParams.flutterDepthRange.upperBound))
        #expect(flutterNote.contains("\(defaultFlutter) cents"),
                Comment(rawValue: "the flutter note does not quote \(defaultFlutter) cents"))
        #expect(flutterNote.contains("\(maxFlutter) cents"),
                Comment(rawValue: "the flutter note does not quote \(maxFlutter) cents"))

        // ⭐ POSITIVE CONTROL FOR THE SEARCH ITSELF. Every `contains` above
        // would also pass against a note that happened to contain the digits
        // for another reason, and — more to the point — would pass VACUOUSLY
        // if `contains` were matching something trivial. These are the two
        // figures that were actually there and were WRONG; they must now be
        // absent, and the same search shape finds them absent.
        #expect(!wowNote.contains("125.5 cents"), "the rotted wow figure is back")
        #expect(!flutterNote.contains("51.1 cents"), "the rotted flutter figure is back")
        print("[measured] m39-n note pins — wow quotes \(defaultWow)/\(maxWow) cents, "
              + "flutter quotes \(defaultFlutter)/\(maxFlutter) cents")
    }

    // MARK: - The record-path shaper

    /// ⭐ THE THREE PROPERTIES THE SHAPER MUST HAVE BECAUSE IT SITS IN A
    /// FEEDBACK LOOP: exactly linear at drive 0, unity small-signal gain at
    /// every drive, and bounded. The middle one is the load-bearing one — a
    /// shaper that RAISES the loop gain turns a stable `feedback` into a
    /// divergent one, which is precisely the `.delay` E11 measurement.
    @Test("the tape shaper is exactly linear at 0, unity for small signals, and bounded")
    func shaperHasTheThreePropertiesALoopNeeds() {
        // 1. Drive 0 is the IDENTITY, bit-exact, not merely gentle.
        let unityGain = TapeDelayParams.driveGain(saturation: 0)
        #expect(unityGain == 1.0)
        for x in stride(from: -2.0, through: 2.0, by: 0.05) {
            #expect(TapeDelayParams.saturated(x, driveGain: unityGain, amount: 0) == x,
                    Comment(rawValue: "drive 0 altered \(x)"))
        }

        // 2. Unity small-signal gain at EVERY drive: a quiet signal comes back
        //    within a whisker of itself, so the loop gain is `feedback` alone.
        for amount in stride(from: 0.0, through: 1.0, by: 0.1) {
            let g = TapeDelayParams.driveGain(saturation: amount)
            let tiny = 1e-4
            let ratio = TapeDelayParams.saturated(tiny, driveGain: g, amount: amount) / tiny
            #expect(abs(ratio - 1) < 1e-6,
                    Comment(rawValue: "small-signal gain \(ratio) at drive \(amount)"))
        }

        // 3. Bounded, and monotonic, and odd-symmetric (a shaper that is not
        //    odd adds even harmonics and a DC offset into a feedback loop).
        let fullGain = TapeDelayParams.driveGain(saturation: 1)
        #expect(fullGain == TapeDelayParams.driveCeiling)
        var previous = -Double.infinity
        for x in stride(from: -8.0, through: 8.0, by: 0.01) {
            let y = TapeDelayParams.saturated(x, driveGain: fullGain, amount: 1)
            #expect(abs(y) <= 1.0 / fullGain + 1e-12)
            #expect(y > previous - 1e-12)
            previous = y
            let mirrored = TapeDelayParams.saturated(-x, driveGain: fullGain, amount: 1)
            #expect(abs(y + mirrored) < 1e-12)
        }

        // 4. It actually COMPRESSES at full drive — non-vacuity for the bound.
        let loud = TapeDelayParams.saturated(0.5, driveGain: fullGain, amount: 1)
        #expect(loud < 0.5 * 0.5, "the shaper is not shaping anything")

        // 5. Non-finite in, finite out — this is inside the render loop.
        #expect(TapeDelayParams.saturated(.nan, driveGain: 2, amount: 0.5).isFinite)
        #expect(TapeDelayParams.saturated(1, driveGain: .nan, amount: 0.5).isFinite)
        #expect(TapeDelayParams.driveGain(saturation: .nan).isFinite)
    }

    // MARK: - The spec table

    /// ⛔ POSITION IS THE AUTOMATION SLOT AND THE ORDER IS APPEND-ONLY FOREVER
    /// (rule 6.0.1). Inserting a param in the middle silently re-points every
    /// saved automation lane on every `.tapeDelay` insert in every project.
    @Test("the spec order is frozen: 8 params, this order, these defaults")
    func specOrderIsFrozen() {
        let specs = EffectParamSpec.specs(for: .tapeDelay)
        #expect(specs.map(\.name) == ["timeMs", "feedback", "mix", "wowDepthMs",
                                      "wowRateHz", "flutterDepthMs", "saturationDrive",
                                      "highCutHz"])
        let defaults = TapeDelayParams()
        #expect(specs[0].defaultValue == defaults.timeMs)
        #expect(specs[1].defaultValue == defaults.feedback)
        #expect(specs[2].defaultValue == defaults.mix)
        #expect(specs[3].defaultValue == defaults.wowDepthMs)
        #expect(specs[4].defaultValue == defaults.wowRateHz)
        #expect(specs[5].defaultValue == defaults.flutterDepthMs)
        #expect(specs[6].defaultValue == defaults.saturationDrive)
        #expect(specs[7].defaultValue == defaults.highCutHz)
        // Ranges are the struct's ranges — the table cannot fork the schema.
        #expect(specs[0].range == TapeDelayParams.timeRange)
        #expect(specs[1].range == TapeDelayParams.feedbackRange)
        #expect(specs[7].range == TapeDelayParams.highCutRange)
        // ⛔ NO TEMPO SYNC ON THIS KIND IN v1 (design §8.2/§8.3). If a `sync`
        // or `division` name ever appears here, the sync resolver was
        // hand-rolled a second time — the one thing m39-c exists to prevent.
        #expect(!specs.contains { $0.name == "sync" || $0.name == "division" })
    }

    /// `.logarithmic` and `.decibel` REQUIRE `lo > 0`
    /// (`ParamCurveConformanceTests`), and the runtime fallback to linear is
    /// SILENT — so a range that touches 0 must declare `.linear`. Both depth
    /// params reach 0, and both must therefore be linear.
    @Test("every curve is legal for its range, and the two depths are linear because they reach 0")
    func curvesAreLegalForTheirRanges() {
        let specs = EffectParamSpec.specs(for: .tapeDelay)
        for spec in specs where spec.curve == .logarithmic || spec.curve == .decibel {
            #expect(spec.range.lowerBound > 0,
                    Comment(rawValue: "\(spec.name) declares \(spec.curve) with a "
                        + "lower bound of \(spec.range.lowerBound)"))
        }
        #expect(specs.first { $0.name == "wowDepthMs" }?.curve == .linear)
        #expect(specs.first { $0.name == "flutterDepthMs" }?.curve == .linear)
        // And the ones that CAN be logarithmic are, because they span decades.
        #expect(specs.first { $0.name == "timeMs" }?.curve == .logarithmic)
        #expect(specs.first { $0.name == "highCutHz" }?.curve == .logarithmic)
        #expect(specs.first { $0.name == "wowRateHz" }?.curve == .logarithmic)
    }

    // MARK: - Clamping and defaults

    @Test("every field clamps on init, and NaN falls back rather than propagating")
    func initClampsAndGuards() {
        let over = TapeDelayParams(timeMs: 90_000, feedback: 5, mix: 9,
                                   wowDepthMs: 400, wowRateHz: 900,
                                   flutterDepthMs: 80, saturationDrive: 3,
                                   highCutHz: 90_000)
        #expect(over.timeMs == TapeDelayParams.timeRange.upperBound)
        #expect(over.feedback == TapeDelayParams.feedbackRange.upperBound)
        #expect(over.mix == 1)
        #expect(over.wowDepthMs == TapeDelayParams.wowDepthRange.upperBound)
        #expect(over.wowRateHz == TapeDelayParams.wowRateRange.upperBound)
        #expect(over.flutterDepthMs == TapeDelayParams.flutterDepthRange.upperBound)
        #expect(over.saturationDrive == 1)
        #expect(over.highCutHz == TapeDelayParams.highCutRange.upperBound)

        let under = TapeDelayParams(timeMs: -5, feedback: -1, mix: -1,
                                    wowDepthMs: -1, wowRateHz: -1,
                                    flutterDepthMs: -1, saturationDrive: -1,
                                    highCutHz: 1)
        #expect(under.timeMs == TapeDelayParams.timeRange.lowerBound)
        #expect(under.feedback == 0)
        #expect(under.wowDepthMs == 0)
        #expect(under.highCutHz == TapeDelayParams.highCutRange.lowerBound)

        let nan = TapeDelayParams(timeMs: .nan, feedback: .nan, mix: .nan,
                                  wowDepthMs: .nan, wowRateHz: .nan,
                                  flutterDepthMs: .nan, saturationDrive: .nan,
                                  highCutHz: .nan)
        let defaults = TapeDelayParams()
        #expect(nan == defaults, "a NaN must land on the default, not propagate")
    }

    /// Decoding routes through the clamping init, and a PARTIAL object decodes
    /// (the `ChorusParams` forward-compat pattern).
    @Test("a partial or hostile JSON object decodes through the clamping init")
    func decodingClampsAndTolerates() throws {
        let partial = Data(#"{"timeMs":600}"#.utf8)
        let decoded = try JSONDecoder().decode(TapeDelayParams.self, from: partial)
        #expect(decoded.timeMs == 600)
        #expect(decoded.feedback == TapeDelayParams().feedback)
        #expect(decoded.highCutHz == TapeDelayParams().highCutHz)

        let hostile = Data(#"{"timeMs":1e9,"feedback":4,"wowDepthMs":-3}"#.utf8)
        let clamped = try JSONDecoder().decode(TapeDelayParams.self, from: hostile)
        #expect(clamped.timeMs == TapeDelayParams.timeRange.upperBound)
        #expect(clamped.feedback == TapeDelayParams.feedbackRange.upperBound)
        #expect(clamped.wowDepthMs == 0)

        // Round trip.
        let original = TapeDelayParams(timeMs: 812.5, feedback: 0.72, mix: 0.55,
                                       wowDepthMs: 5.25, wowRateHz: 1.7,
                                       flutterDepthMs: 0.62, saturationDrive: 0.85,
                                       highCutHz: 3_150)
        let bytes = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(TapeDelayParams.self, from: bytes) == original)
    }

    /// The descriptor carries the params as an additive optional and
    /// `resolvedTapeDelay` manufactures defaults from nil — the rule-6.0.10
    /// shape every kind inherits.
    @Test("the descriptor field is additive-optional and resolves to defaults")
    func descriptorFieldIsAdditiveOptional() {
        let bare = EffectDescriptor(kind: .tapeDelay)
        #expect(bare.tapeDelay == nil)
        #expect(bare.resolvedTapeDelay == TapeDelayParams())
        let set = EffectDescriptor(kind: .tapeDelay,
                                   tapeDelay: TapeDelayParams(timeMs: 500))
        #expect(set.resolvedTapeDelay.timeMs == 500)
        #expect(set.paramValue("timeMs") == 500)
        #expect(set.paramValue("wowDepthMs") == TapeDelayParams().wowDepthMs)
        #expect(set.paramValue("nonsense") == nil)
    }
}
