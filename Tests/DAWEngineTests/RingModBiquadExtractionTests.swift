import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-ae — the biquad that moved house, and the proof that it arrived
/// unchanged.
///
/// ## What happened, and why it needed proving
///
/// `RingModEffect` carried a private `struct Biquad` — one 2-pole transposed
/// direct-form-II section. m39-ae needed exactly that for the compressor's
/// de-ess detector, so under the tree's `Oversampler` rule (a primitive is
/// extracted when a SECOND caller appears, not on spec) it moved to
/// `Sources/DAWEngine/Effects/Primitives/Biquad.swift`.
///
/// `.ringMod` is a SHIPPED kind. "I moved it unchanged" is an arithmetic claim,
/// and arithmetic claims made by whoever did the moving are the least reliable
/// kind there is: a reordered expression, a dropped `@inline(__always)`, a
/// `Float` where a `Double` was, or a denormal flush at a different threshold
/// would each change a low bit while every behavioural test stayed green and the
/// effect went on sounding exactly like a ring modulator.
///
/// ## Two instruments, because one is not enough
///
///  · `scripts/gates/m39ae-ringmod-unchanged-bytes.mjs` pins all four renders of
///    the `ringmod` demo set against hashes captured from the build before the
///    primitive existed. It proves the OUTPUT did not move but says nothing
///    about why. **It was positive-controlled**: moving the denormal flush from
///    1e-25 to 1e-20 — the smallest change the file can carry — reddened all
///    three effect variants while the control held.
///  · this suite runs the primitive against `Reference`, a hand-copy of the
///    ORIGINAL inline expressions, over a long recursive run at coefficients
///    that come from `EQFilterResponse`. It proves WHY, on bit patterns.
///
/// ⚠️ NOT `@MainActor` — pure arithmetic, and the occupancy census is at its cap.
@Suite("m39-ae Biquad extraction")
struct RingModBiquadExtractionTests {

    /// ⛔ A CHARACTER-FOR-CHARACTER COPY OF THE PRE-EXTRACTION
    /// `RingModEffect.Biquad`, and it must never be "tidied". Its whole value is
    /// that it was typed from the old file rather than derived from the new one:
    /// the moment someone simplifies it to match `Biquad`, this test becomes a
    /// comparison of a thing with itself and proves nothing at all.
    private struct Reference {
        var z1: Double = 0
        var z2: Double = 0

        mutating func step(_ x: Double, b0: Double, b1: Double, b2: Double,
                           a1: Double, a2: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            if abs(z1) < 1e-25 { z1 = 0 }
            if abs(z2) < 1e-25 { z2 = 0 }
            return y
        }

        mutating func clear() {
            z1 = 0
            z2 = 0
        }
    }

    /// The ring modulator's own coefficients: a 2-pole low-pass at its input
    /// high-cut, Butterworth Q, taken from the SAME one home the effect uses.
    /// Several corners, because a recurrence can agree at one pole radius and
    /// diverge at another.
    private static func sections() -> [(String, EQBiquad)] {
        [500.0, 4_000.0, 20_000.0].map { hz in
            ("\(Int(hz)) Hz", EQFilterResponse.cutSection(
                highPass: false, freq: hz, q: EQFilterResponse.butterworth2Q,
                sampleRate: 48_000))
        }
    }

    /// ⭐ THE SIGNAL IS NOT A SINE. A steady tone drives a filter to a steady
    /// state where two slightly different recurrences agree to more digits than
    /// they deserve. This is an impulse, then noise, then a DECAY TO SILENCE —
    /// and the decay is the point: it is the only part of the run that reaches
    /// the subnormal region where the 1e-25 flush is the difference between the
    /// two implementations agreeing and not.
    private static func signal(count: Int) -> [Double] {
        var x = [Double](repeating: 0, count: count)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        x[0] = 1.0
        for n in 1..<count {
            // xorshift64* — deterministic, no dependency on the platform RNG.
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            let u = Double(state &* 0x2545_F491_4F6C_DD1D >> 11) / Double(1 << 53)
            if n < count / 2 {
                x[n] = (u * 2 - 1) * 0.8
            } else if n < (count * 3) / 4 {
                // Exponential decay toward the floor.
                x[n] = (u * 2 - 1) * exp(-Double(n - count / 2) / 400.0)
            } else {
                // ⭐ THEN PURE SILENCE, AND IT IS THE POINT OF THE SIGNAL. A
                // decaying INPUT only gets the state to ~1e-11; the last quarter
                // feeds zeros so the recursion rings itself down through the
                // subnormal region and into the 1e-25 flush, which is the one
                // place the two implementations could have differed without any
                // other test noticing. The assertion `extracted.z1 == 0` at the
                // end is what proves this quarter did its job — the first draft
                // had no silence and that assertion failed, correctly.
                x[n] = 0
            }
        }
        return x
    }

    @Test("the extracted Biquad is BIT-EQUAL to the original inline expressions")
    func extractedBiquadIsBitEqualToTheOriginal() {
        let x = Self.signal(count: 20_000)
        for (label, s) in Self.sections() {
            var extracted = Biquad()
            var reference = Reference()
            var firstDivergence = -1
            var lastNonZero = -1
            for n in 0..<x.count {
                let a = extracted.step(x[n], b0: s.b0, b1: s.b1, b2: s.b2, a1: s.a1, a2: s.a2)
                let b = reference.step(x[n], b0: s.b0, b1: s.b1, b2: s.b2, a1: s.a1, a2: s.a2)
                if a.bitPattern != b.bitPattern, firstDivergence < 0 { firstDivergence = n }
                if a != 0 { lastNonZero = n }
            }
            #expect(firstDivergence < 0, Comment(rawValue:
                "\(label): the extracted Biquad and the original inline expressions diverge at "
                + "sample \(firstDivergence). The extraction changed the arithmetic — check the "
                + "TDF2 operand order, the 1e-25 flush on BOTH state words, and that nothing "
                + "(a NaN guard, a clamp) was added to the primitive."))
            // ⭐ POSITIVE CONTROL ON THE COMPARISON ITSELF. If the signal never
            // reached the filter, both sides would be an endless run of zeros
            // and the equality above would be perfectly true and perfectly
            // empty — the exact shape of a hand-built probe that never looked.
            #expect(lastNonZero > 10_000, Comment(rawValue:
                "\(label): the filter produced its last nonzero output at sample \(lastNonZero) "
                + "of \(x.count). The comparison above is mostly comparing zeros."))
            // …and the state really did land in the flushed region, which is the
            // one place the two implementations could have differed silently.
            #expect(extracted.z1 == 0 && extracted.z2 == 0, Comment(rawValue:
                "\(label): the decay never drove the state into the flush region, so the "
                + "denormal half of this comparison was never exercised"))
        }
    }

    /// The flush threshold is not decoration: it is a render-thread cost
    /// argument, and it is the constant most likely to be "improved" by someone
    /// who does not know that. Asserted directly rather than inferred.
    @Test("both state words flush below 1e-25, and only below it")
    func flushThresholdIsUnchanged() {
        var b = Biquad()
        // A pure feed-through section (b0 = 1, everything else 0) so the state
        // words take exactly the values fed in and nothing is inferred.
        _ = b.step(1e-24, b0: 0, b1: 1, b2: 1, a1: 0, a2: 0)
        #expect(b.z1 == 1e-24 && b.z2 == 1e-24)
        b.clear()
        _ = b.step(1e-26, b0: 0, b1: 1, b2: 1, a1: 0, a2: 0)
        #expect(b.z1 == 0 && b.z2 == 0)
        // And `clear()` really clears, which `reset()` on two effects relies on.
        _ = b.step(0.5, b0: 0, b1: 1, b2: 1, a1: 0, a2: 0)
        #expect(b.z1 != 0)
        b.clear()
        #expect(b.z1 == 0 && b.z2 == 0)
    }

    /// `InlineBiquads` is the de-esser's per-channel bank. The thing that can
    /// go wrong in a hand-written 8-way switch is a duplicated case — two
    /// channels sharing one section, which on real stereo material produces a
    /// subtle detector error and no crash. This proves the eight are eight.
    @Test("InlineBiquads keeps eight INDEPENDENT sections")
    func inlineBiquadsAreIndependent() {
        var bank = InlineBiquads()
        // Feed a distinct impulse into each slot through a feed-through section,
        // then read each slot's response to a zero input.
        for i in 0..<8 {
            _ = bank.step(i, Double(i + 1), b0: 0, b1: 1, b2: 0, a1: 0, a2: 0)
        }
        for i in 0..<8 {
            let y = bank.step(i, 0, b0: 0, b1: 1, b2: 0, a1: 0, a2: 0)
            #expect(y == Double(i + 1), Comment(rawValue:
                "slot \(i) returned \(y), expected \(i + 1). Two slots of the switch in "
                + "InlineBiquads.step are addressing the same stored section, so two audio "
                + "channels would share one filter's memory."))
        }
        bank.clearAll()
        for i in 0..<8 {
            #expect(bank.step(i, 0, b0: 0, b1: 1, b2: 0, a1: 0, a2: 0) == 0)
        }
    }
}
