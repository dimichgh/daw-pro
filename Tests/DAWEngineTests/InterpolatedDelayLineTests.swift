import Foundation
import Testing
@testable import DAWEngine

/// m39-j-0 — the extracted `InterpolatedDelayLine` home, tested DIRECTLY with
/// no caller (design §4.1 sequence step 1: extract and unit-test the home
/// before migrating `ChorusEffect` onto it, so a red byte-identity gate later
/// cannot be ambiguous about which half moved).
///
/// Every assertion is EXACT, not tolerance-based: the fixtures are integer
/// ramps and quarter-sample fractions, so every expected value is exactly
/// representable in Float and a one-index or dropped-fraction error cannot
/// hide inside an epsilon.
///
/// Falsifiability pins these tests exist to catch (each was planted and
/// observed to redden — see the m39-j-0 report):
///  · `return s0` (drop the fractional term)  → the fractional-delay tests
///  · `i1 = i0 + 1` (wrong wrap direction)    → the wrap + fractional tests
///  · accept `minDelaySamples == 0`           → the prepare-refusal test
/// ⚠️ Deliberately NOT `@MainActor`, unlike most engine suites: nothing here
/// is main-actor by necessity — `InterpolatedDelayLine` is a plain nonisolated
/// class and `prepare()` carries no isolation (it inherits `EffectRendering`'s
/// convention of being main-actor BY CALLER, not by annotation). Spelling
/// `@MainActor` here would have added a suite to the m23-aw occupancy census
/// for nothing; it measured 381 against the 380 cadence cap until this line.
@Suite("InterpolatedDelayLine — the shared fractional delay line")
struct InterpolatedDelayLineTests {
    /// A line whose capacity lands on a round 100 samples: 0.096 s × 1 kHz =
    /// 96, plus the home's 4-sample stencil margin. Round capacity is what
    /// makes the wrap test able to place `i0` at EXACTLY 0.
    private static func roundCapacityLine(
        _ interpolation: InterpolatedDelayLine.Interpolation = .linear,
        minDelaySamples: Double = 1, channels: Int = 1
    ) throws -> InterpolatedDelayLine {
        let line = InterpolatedDelayLine(capacitySeconds: 0.096, interpolation: interpolation)
        try line.prepare(sampleRate: 1_000, minDelaySamples: minDelaySamples,
                         channelCount: channels)
        return line
    }

    /// Writes `count` ramp samples (value n+1 for the n-th, so every sample is
    /// distinct and none is 0) into every channel of `line`, advancing once
    /// per frame. After this, delay `d` addresses ramp sample `count - d`.
    private static func feedRamp(_ line: InterpolatedDelayLine, count: Int,
                                 channelOffset: Float = 0) {
        for n in 0..<count {
            for ch in 0..<line.channelCount {
                line.write(channel: ch, Float(n + 1) + Float(ch) * channelOffset)
            }
            line.advance()
        }
    }

    // MARK: - Known impulse at a known fractional delay (§4.1 test 1)

    @Test("an impulse 10 samples back splits across two fractional taps by exactly the fraction")
    func impulseSplitsAcrossFractionalTaps() throws {
        let line = try Self.roundCapacityLine()
        // Impulse, then 9 zeros: the impulse now sits exactly 10 samples back.
        line.write(channel: 0, 1)
        line.advance()
        for _ in 0..<9 {
            line.write(channel: 0, 0)
            line.advance()
        }

        // Integer delay lands on the impulse itself.
        #expect(line.tap(channel: 0, delaySamples: 10) == 1)
        #expect(line.tap(channel: 0, delaySamples: 9) == 0)
        #expect(line.tap(channel: 0, delaySamples: 11) == 0)

        // 9.25 interpolates FROM the zero at delay 9 TOWARD the impulse at
        // delay 10 — the older neighbour. A tap that read the NEWER neighbour
        // (`i1 = i0 + 1`) returns 0 here, and one that dropped the fractional
        // term returns 0 too.
        #expect(line.tap(channel: 0, delaySamples: 9.25) == 0.25)
        #expect(line.tap(channel: 0, delaySamples: 9.75) == 0.75)
        // 10.25 interpolates away from the impulse toward the zero behind it.
        #expect(line.tap(channel: 0, delaySamples: 10.25) == 0.75)
        #expect(line.tap(channel: 0, delaySamples: 10.75) == 0.25)
    }

    @Test("a fractional tap on a ramp is the exact linear blend of its two integer neighbours")
    func fractionalTapOnRampIsExactBlend() throws {
        let line = try Self.roundCapacityLine()
        Self.feedRamp(line, count: 64)

        // delay 3 → ramp sample 61 (value 62); delay 4 → value 61.
        #expect(line.tap(channel: 0, delaySamples: 3) == 62)
        #expect(line.tap(channel: 0, delaySamples: 4) == 61)
        // Older neighbour is SMALLER here, so a dropped fraction (62) and a
        // newer-neighbour wrap (62.5 at f = 0.5) are both distinguishable.
        #expect(line.tap(channel: 0, delaySamples: 3.5) == 61.5)
        #expect(line.tap(channel: 0, delaySamples: 3.25) == 61.75)
        #expect(line.tap(channel: 0, delaySamples: 3.75) == 61.25)
    }

    // MARK: - Wrap across the capacity boundary (§4.1 test 2)

    @Test("a fractional tap wraps correctly when i0 is exactly 0 and when i0 goes negative")
    func fractionalTapWrapsAcrossTheCapacityBoundary() throws {
        let line = try Self.roundCapacityLine()
        #expect(line.capacityPerChannel == 100)
        // 250 writes = two full wraps plus 50: the write head sits at 50, and
        // the line holds ramp samples 150…249.
        Self.feedRamp(line, count: 250)
        #expect(line.writeIndex == 50)

        // whole == 50 puts i0 at EXACTLY 0, so i1 must wrap to capacity - 1
        // (index 99 = ramp sample 199, value 200). A tap that stepped the
        // wrong way lands on index 1 (ramp sample 201, value 202).
        #expect(line.tap(channel: 0, delaySamples: 50) == 201)
        #expect(line.tap(channel: 0, delaySamples: 51) == 200)
        #expect(line.tap(channel: 0, delaySamples: 50.25) == 200.75)
        #expect(line.tap(channel: 0, delaySamples: 50.75) == 200.25)

        // whole == 60 drives i0 negative (-10 → 90) before the fractional
        // neighbour is taken; both stencil samples are on the far side.
        #expect(line.tap(channel: 0, delaySamples: 60) == 191)
        #expect(line.tap(channel: 0, delaySamples: 61) == 190)
        #expect(line.tap(channel: 0, delaySamples: 60.25) == 190.75)

        // The deepest legal tap still reads real history, never the write head.
        #expect(line.tap(channel: 0, delaySamples: 96) == 155)
    }

    @Test("the capacity DECLARED in seconds is really available as history at the prepared rate")
    func declaredCapacityIsRealHistory() throws {
        let line = try Self.roundCapacityLine()
        // 0.096 s at 1 kHz = 96 samples of declared history; the 4 extra slots
        // are the interpolator's stencil margin, not capacity the caller owns.
        #expect(line.capacityPerChannel == 100)
        Self.feedRamp(line, count: 250)
        // The deepest DECLARED tap, and the one just inside it, are both true
        // ramp history after two wraps — not zeros, not aliased neighbours.
        #expect(line.tap(channel: 0, delaySamples: 96) == 155)
        #expect(line.tap(channel: 0, delaySamples: 95) == 156)
        #expect(line.tap(channel: 0, delaySamples: 95.5) == 155.5)
    }

    // MARK: - Prepare-time refusal (§4.1 test 3)

    @Test("prepare REFUSES a caller whose minimum delay can reach 0, and the line stays unusable")
    func prepareRefusesZeroMinimumDelay() {
        let line = InterpolatedDelayLine(capacitySeconds: 0.025)
        #expect(throws: InterpolatedDelayLine.PrepareRefusal
            .minimumDelayBelowStencil(minDelaySamples: 0, required: 1)) {
            try line.prepare(sampleRate: 48_000, minDelaySamples: 0, channelCount: 2)
        }
        // A refused line owns no storage: silent, never reading its own head.
        #expect(line.isPrepared == false)
        #expect(line.capacityPerChannel == 0)
        #expect(line.tap(channel: 0, delaySamples: 10) == 0)
        line.write(channel: 0, 1)
        line.advance()
        #expect(line.writeIndex == 0)
        #expect(line.tap(channel: 0, delaySamples: 10) == 0)
    }

    @Test("the refusal boundary is exactly 1 sample for linear — 1 is ACCEPTED, so the check cannot be over-strict")
    func linearAcceptsOneSampleMinimum() throws {
        let line = InterpolatedDelayLine(capacitySeconds: 0.025)
        try line.prepare(sampleRate: 48_000, minDelaySamples: 1, channelCount: 2)
        #expect(line.isPrepared)
        #expect(line.capacityPerChannel == 1_204)  // 0.025 × 48 kHz + 4 margin
    }

    @Test("cubic Hermite refuses a 1-sample minimum — its stencil reads one sample NEWER than the tap")
    func cubicHermiteRefusesOneSampleMinimum() throws {
        let line = InterpolatedDelayLine(capacitySeconds: 0.025, interpolation: .cubicHermite)
        #expect(throws: InterpolatedDelayLine.PrepareRefusal
            .minimumDelayBelowStencil(minDelaySamples: 1, required: 2)) {
            try line.prepare(sampleRate: 48_000, minDelaySamples: 1, channelCount: 2)
        }
        #expect(line.isPrepared == false)
        try line.prepare(sampleRate: 48_000, minDelaySamples: 2, channelCount: 2)
        #expect(line.isPrepared)
    }

    @Test("prepare refuses a non-positive capacity, a non-positive rate, a bad channel count, and NaN")
    func prepareRefusesTheOtherMalformedDeclarations() {
        let zeroCapacity = InterpolatedDelayLine(capacitySeconds: 0)
        #expect(throws: InterpolatedDelayLine.PrepareRefusal.nonPositiveCapacity(seconds: 0)) {
            try zeroCapacity.prepare(sampleRate: 48_000, minDelaySamples: 1, channelCount: 2)
        }

        let line = InterpolatedDelayLine(capacitySeconds: 0.025)
        #expect(throws: InterpolatedDelayLine.PrepareRefusal.nonPositiveSampleRate(0)) {
            try line.prepare(sampleRate: 0, minDelaySamples: 1, channelCount: 2)
        }
        #expect(throws: InterpolatedDelayLine.PrepareRefusal.unsupportedChannelCount(3)) {
            try line.prepare(sampleRate: 48_000, minDelaySamples: 1, channelCount: 3)
        }
        #expect(throws: InterpolatedDelayLine.PrepareRefusal.unsupportedChannelCount(0)) {
            try line.prepare(sampleRate: 48_000, minDelaySamples: 1, channelCount: 0)
        }
        // A minimum deeper than the line is as broken as one that reaches 0.
        #expect(throws: InterpolatedDelayLine.PrepareRefusal
            .minimumDelayExceedsCapacity(minDelaySamples: 5_000, capacitySamples: 1_204)) {
            try line.prepare(sampleRate: 48_000, minDelaySamples: 5_000, channelCount: 2)
        }
        // NaN fails every comparison and therefore refuses rather than passing.
        #expect(throws: (any Error).self) {
            try line.prepare(sampleRate: 48_000, minDelaySamples: .nan, channelCount: 2)
        }
        #expect(line.isPrepared == false)
    }

    // MARK: - Channels, reset, and the cubic branch

    @Test("two channels are independent regions of one flat block sharing one write head")
    func channelsAreIndependent() throws {
        let line = try Self.roundCapacityLine(channels: 2)
        Self.feedRamp(line, count: 64, channelOffset: 1_000)
        #expect(line.tap(channel: 0, delaySamples: 3.5) == 61.5)
        #expect(line.tap(channel: 1, delaySamples: 3.5) == 1_061.5)
        // One shared write head, not one per channel.
        #expect(line.writeIndex == 64)
    }

    @Test("a mono line ignores writes and taps on a channel it does not have")
    func monoLineRefusesTheSecondChannel() throws {
        let line = try Self.roundCapacityLine(channels: 1)
        Self.feedRamp(line, count: 64)
        line.write(channel: 1, 999)      // inert, and must not corrupt channel 0
        #expect(line.tap(channel: 1, delaySamples: 3.5) == 0)
        #expect(line.tap(channel: 0, delaySamples: 3.5) == 61.5)
    }

    @Test("reset zeroes the line and rewinds the write head")
    func resetClearsEverything() throws {
        let line = try Self.roundCapacityLine(channels: 2)
        Self.feedRamp(line, count: 250, channelOffset: 1_000)
        line.reset()
        #expect(line.writeIndex == 0)
        for delay in stride(from: 1.0, through: 96.0, by: 1.0) {
            #expect(line.tap(channel: 0, delaySamples: delay) == 0)
            #expect(line.tap(channel: 1, delaySamples: delay) == 0)
        }
        #expect(line.tap(channel: 0, delaySamples: 3.5) == 0)
    }

    @Test("cubic Hermite reproduces a ramp exactly and matches the integer samples")
    func cubicHermiteIsExactOnARamp() throws {
        let line = try Self.roundCapacityLine(.cubicHermite, minDelaySamples: 2)
        Self.feedRamp(line, count: 64)
        // 3rd-order Hermite is exact for polynomials up to degree 3; a ramp is
        // degree 1, so the fractional reads must match linear EXACTLY.
        #expect(line.tap(channel: 0, delaySamples: 3) == 62)
        #expect(line.tap(channel: 0, delaySamples: 3.5) == 61.5)
        #expect(line.tap(channel: 0, delaySamples: 3.25) == 61.75)
        #expect(line.tap(channel: 0, delaySamples: 4) == 61)
    }

    @Test("cubic Hermite is exact on a QUADRATIC — which pins c2, and which a linear tap gets wrong")
    func cubicHermiteIsExactOnAQuadratic() throws {
        // A ramp alone does NOT pin the coefficients: on a degree-1 signal c2
        // and c3 vanish for any coefficient set whose terms sum to zero, so a
        // wrong c2 would survive. A degree-2 signal does pin it — and it is
        // also where cubic and linear visibly part company.
        let line = try Self.roundCapacityLine(.cubicHermite, minDelaySamples: 2)
        for n in 0..<64 {
            line.write(channel: 0, Float(n * n))
            line.advance()
        }
        // delay d addresses sample 64 − d, whose value is (64 − d)². Every
        // intermediate (c1 = −122, c2 = 1, c3 = 0) is exact in Float.
        #expect(line.tap(channel: 0, delaySamples: 3) == 3_721)     // 61²
        #expect(line.tap(channel: 0, delaySamples: 4) == 3_600)     // 60²
        #expect(line.tap(channel: 0, delaySamples: 3.5) == 3_660.25)  // 60.5²
        // A LINEAR tap on the same data would return the midpoint 3660.5 —
        // this assertion is what makes the cubic branch a distinct thing.
        #expect(line.tap(channel: 0, delaySamples: 3.5) != 3_660.5)
    }

    @Test("cubic Hermite wraps its 4-sample stencil across the capacity boundary")
    func cubicHermiteWrapsItsStencil() throws {
        let line = try Self.roundCapacityLine(.cubicHermite, minDelaySamples: 2)
        Self.feedRamp(line, count: 250)
        #expect(line.writeIndex == 50)
        // whole == 50 → i0 == 0: the newer stencil sample is at index 1 and
        // the two older ones wrap to 99 and 98. A ramp stays a ramp only if
        // all four land right.
        #expect(line.tap(channel: 0, delaySamples: 50.25) == 200.75)
        // whole == 49 → the OLDER stencil samples sit at 0 and 99: the wrap
        // happens inside the stencil rather than at its edge.
        #expect(line.tap(channel: 0, delaySamples: 49.25) == 201.75)
    }

    // MARK: - Denormal / NaN posture (the home has NO flush, by contract)

    @Test("denormal-magnitude and finite extreme input stay finite — the home adds no flush and needs none")
    func denormalAndExtremeInputStayFinite() throws {
        // §4.1 freezes the flush OUT of this home: it is feedforward (taps
        // only) and cannot generate a denormal that was not written in. What
        // it MUST do is never manufacture a NaN or an infinity from finite
        // input — a feedback caller adds its own flush to its own state.
        let line = try Self.roundCapacityLine()
        // Genuinely SUBNORMAL (≈ 1.2e-41), and built by arithmetic rather than
        // written as a literal — a subnormal Float literal is a compiler
        // warning, and this tree builds warning-free.
        let tiny = Float.leastNormalMagnitude * 1e-3
        for n in 0..<64 {
            line.write(channel: 0, n.isMultiple(of: 2) ? tiny : -tiny)
            line.advance()
        }
        for delay in stride(from: 1.0, through: 90.0, by: 0.25) {
            let s = line.tap(channel: 0, delaySamples: delay)
            #expect(s.isFinite)
            #expect(abs(s) <= Float.leastNormalMagnitude)
        }

        line.reset()
        for _ in 0..<64 {
            line.write(channel: 0, 1e30)
            line.advance()
        }
        #expect(line.tap(channel: 0, delaySamples: 3.5).isFinite)
        #expect(line.tap(channel: 0, delaySamples: 3.5) == 1e30)
    }
}
