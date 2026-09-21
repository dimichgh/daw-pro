import Foundation

/// ONE 2-pole transposed-direct-form-II biquad section, one channel, `Double`
/// state.
///
/// ## Why this is a primitive (m39-ae)
///
/// It was `RingModEffect.Biquad`, private, and it is EXTRACTED HERE UNCHANGED —
/// expression for expression, constant for constant — the moment a SECOND
/// caller appeared (`CompressorEffect`'s de-ess detector filter). That is the
/// `Oversampler` precedent exactly: the saturator's shaper became a primitive
/// when the clipper became its second caller, not before and not on spec.
///
/// ⛔⛔ **THE EXTRACTION IS PROVEN, NOT ASSERTED.** The ring modulator is a
/// SHIPPED kind and moving its filter out of the file must not change one byte
/// of what it renders. `scripts/gates/m39ae-ringmod-unchanged-bytes.mjs` pins
/// all four renders of `scripts/demos/specs/ringmod.json` against hashes
/// measured from the build that existed BEFORE this file did, and
/// `RingModBiquadExtractionTests` re-runs the same coefficients through this
/// type and the original inline expressions and requires BIT-EQUAL output.
///
/// ## The shape, and why it is this shape
///
/// TDF2 is what `BassEnhancerEffect` uses for the same coefficients, for the
/// same reasons: two state words, good numerical behaviour at low corners, and
/// it is what `EQFilterResponse`'s a0 normalisation assumes. Coefficients are
/// passed IN per call rather than stored, deliberately: every caller in this
/// tree recomputes them on a stride (32 frames in the ring modulator, on
/// parameter change in the compressor) and storing them here would duplicate
/// state that already has an owner.
///
/// ## Render-path contract
///
/// `step` and `clear` allocate nothing, take no locks, log nothing and touch no
/// ObjC. `step` is `@inline(__always)` and is pure arithmetic.
///
/// ⚠️ **NO NaN GUARD LIVES HERE, ON PURPOSE.** A recursive filter fed a NaN is
/// poisoned permanently — `z1`/`z2` never recover — so the guard is real work
/// that some caller must do. It is not done here because adding a branch would
/// change the ring modulator's arithmetic, which is the one thing this
/// extraction promises not to do. Each caller guards at its own boundary:
/// `CompressorEffect` clears the detector filters when a filtered sample comes
/// back non-finite (`CompressorDeEssTests.nanInputDoesNotPoisonTheDetector`),
/// and the ring modulator relies on its input already being finite.
struct Biquad {
    var z1: Double = 0
    var z2: Double = 0

    /// ⚠️ Both state words are denormal-flushed on EVERY sample — the
    /// `DJFilterEffect.SVFSection` convention, and for the same reason: a
    /// recursive filter decaying toward zero on silence lands in subnormal
    /// territory, where each operation costs orders of magnitude more, on
    /// the render thread, during silence, which is exactly when nobody is
    /// looking. A 500 Hz corner's poles sit at radius ~0.955, so a
    /// quantum-boundary flush would leave hundreds of samples in the slow
    /// path on every fade-out.
    @inline(__always)
    mutating func step(_ x: Double, b0: Double, b1: Double, b2: Double,
                       a1: Double, a2: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        if abs(z1) < 1e-25 { z1 = 0 }
        if abs(z2) < 1e-25 { z2 = 0 }
        return y
    }

    @inline(__always)
    mutating func clear() {
        z1 = 0
        z2 = 0
    }
}

/// Eight `Biquad`s in fixed-size stack storage — the `InlineChannelPointers`
/// shape, for the same reason: a per-channel filter bank with no heap
/// allocation anywhere on the render path, sized to the same 8-channel ceiling
/// the effects already cap at.
///
/// ⚠️ An ARRAY would allocate on `init` and, worse, a `[Biquad]` mutated
/// through a subscript inside the per-sample loop is a CoW check per sample.
/// This is a struct of eight stored properties; there is nothing to check.
struct InlineBiquads {
    var b0, b1, b2, b3, b4, b5, b6, b7: Biquad

    init() {
        b0 = Biquad(); b1 = Biquad(); b2 = Biquad(); b3 = Biquad()
        b4 = Biquad(); b5 = Biquad(); b6 = Biquad(); b7 = Biquad()
    }

    mutating func clearAll() {
        b0.clear(); b1.clear(); b2.clear(); b3.clear()
        b4.clear(); b5.clear(); b6.clear(); b7.clear()
    }

    /// Runs channel `index`'s section. A `switch` rather than a subscript so
    /// the mutation is in-place on a stored property — `withUnsafeMutablePointer`
    /// would work too and is harder to read for no measured gain.
    @inline(__always)
    mutating func step(_ index: Int, _ x: Double,
                       b0 c0: Double, b1 c1: Double, b2 c2: Double,
                       a1 d1: Double, a2 d2: Double) -> Double {
        switch index {
        case 0: return b0.step(x, b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
        case 1: return b1.step(x, b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
        case 2: return b2.step(x, b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
        case 3: return b3.step(x, b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
        case 4: return b4.step(x, b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
        case 5: return b5.step(x, b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
        case 6: return b6.step(x, b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
        default: return b7.step(x, b0: c0, b1: c1, b2: c2, a1: d1, a2: d2)
        }
    }
}
