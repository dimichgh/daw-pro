import Foundation

/// m39-dm — the drum machine's render-path primitives, factored out of
/// `DrumSynthInstrument` SO THEY CAN BE TESTED IN ISOLATION.
///
/// ⭐ That is not tidiness, it is the only way one of the acceptance gates can
/// exist at all. The hat's aliasing assertion CANNOT be made in situ: a hat is
/// six squares at 205–800 Hz through a 7100 Hz bandpass and a 6000 Hz highpass,
/// so everything below ~2 kHz is attenuated regardless of whether the
/// oscillator is band-limited — an "energy below 200 Hz" bound would be a plant
/// multiplied by zero, passing identically for a polyBLEP square and a naive
/// one. The aliases that matter land IN the kHz passband, mixed with the hat's
/// legitimate content, where no in-situ measurement can separate them. So the
/// oscillator is asserted alone, at a frequency chosen to put its foldover
/// somewhere a measurement can see it.
///
/// ⚠️ EVERY FUNCTION HERE IS RENDER-THREAD CODE: no allocation, no locks, no
/// ObjC, no logging, and no `Int()` on a value that could be NaN.
enum DrumDSP {

    // MARK: - Envelopes

    /// The per-sample multiplier of a one-pole exponential decay whose
    /// parameter IS its −60 dB time.
    ///
    /// ⭐ `e[n] = e[n-1] · c` with `c = 10^(−3/(T·fs))` reaches exactly
    /// `10⁻³` = −60 dB at `n = T·fs`. That identity is deliberate: it makes the
    /// knob's published contract and the test assertion THE SAME STATEMENT, so
    /// the decay gates check the documented meaning of the parameter rather
    /// than an implementation detail.
    ///
    /// ⚠️ Guards `T` and `fs`: a zero or negative time gives `-inf` in the
    /// exponent and a coefficient of 0 or NaN. A NaN coefficient poisons every
    /// subsequent sample and several of these values later become sample counts.
    @inline(__always)
    static func decayCoefficient(seconds: Double, sampleRate: Double) -> Double {
        guard seconds.isFinite, seconds > 0, sampleRate > 0 else { return 0 }
        let samples = seconds * sampleRate
        guard samples >= 1 else { return 0 }
        return pow(10.0, -3.0 / samples)
    }

    /// Below this the envelope is inaudible and the slot is retired. It also
    /// keeps the recursion out of the denormal range: repeatedly multiplying a
    /// Double by a coefficient < 1 walks into subnormals, where some CPUs take
    /// a large penalty per operation, and the voice would otherwise never stop.
    static let silenceFloor = 1e-7

    // MARK: - Modal resonator (a decaying sinusoid without transcendentals)

    /// Coefficients for `y[n] = a1·y[n-1] − a2·y[n-2]`, a partial at `frequency`
    /// decaying to −60 dB in `seconds`. Derived ONCE per note-on and frozen for
    /// the life of the hit — which is affordable precisely because a one-shot
    /// never changes its coefficients mid-note.
    ///
    /// Seeded with `y[-1] = 0`, `y[-2] = −sin(ω)/R`, the recursion produces
    /// `y[n] = R^(n+1)·sin((n+1)ω)` — a unit-amplitude decaying sinusoid whose
    /// envelope is exactly `R^n`, so `seconds` means the same thing here as it
    /// does for `decayCoefficient`.
    @inline(__always)
    static func modalCoefficients(frequency: Double, seconds: Double, sampleRate: Double)
        -> (a1: Double, a2: Double, y1: Double, y2: Double) {
        guard frequency.isFinite, frequency > 0, sampleRate > 0 else {
            return (0, 0, 0, 0)
        }
        // Above Nyquist the recursion is not a resonator at all; fold it back
        // rather than letting a modulated `tune` produce a runaway filter.
        let f = min(frequency, sampleRate * 0.49)
        let omega = 2.0 * Double.pi * f / sampleRate
        let r = decayCoefficient(seconds: seconds, sampleRate: sampleRate)
        guard r > 0 else { return (0, 0, 0, 0) }
        return (a1: 2.0 * r * cos(omega), a2: r * r,
                y1: 0, y2: -sin(omega) / r)
    }

    // MARK: - Band-limited square (Simper/Välimäki polyBLEP)

    /// Two-sample polyBLEP residual — the difference between an ideal step and
    /// its band-limited version, applied around each discontinuity.
    @inline(__always)
    static func polyBLEP(_ t: Double, _ dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1.0
        }
        if t > 1.0 - dt {
            let x = (t - 1.0) / dt
            return x * x + x + x + 1.0
        }
        return 0.0
    }

    /// A band-limited square at normalised `phase` with per-sample increment
    /// `dt`. Both discontinuities are corrected: the rise at phase 0 and the
    /// fall at phase 0.5.
    ///
    /// ⛔ THIS IS THE ONE PLACE THE DESIGN OVERRULES "CIRCUIT-ACCURATE", AND
    /// THE REASON IS THAT THE ALTERNATIVE CORRUPTS ITS OWN TEST. Six naive
    /// squares at 205–800 Hz fold a large set of odd harmonics back down, and
    /// the foldover is inharmonic garbage landing INSIDE the hat's own
    /// passband — where the hat's entire identity (a specific inharmonic
    /// spectrum) also lives. Worse, foldover frequencies move the WRONG WAY as
    /// `tune` rises, so the `tune`-sweep assertion would end up measuring the
    /// artefact rather than the oscillator.
    @inline(__always)
    static func blepSquare(phase: Double, dt: Double) -> Double {
        var value = phase < 0.5 ? 1.0 : -1.0
        value += polyBLEP(phase, dt)
        var fallPhase = phase + 0.5
        if fallPhase >= 1.0 { fallPhase -= 1.0 }
        value -= polyBLEP(fallPhase, dt)
        return value
    }

    // MARK: - Antiderivative-antialiased tanh saturation

    /// `ln cosh x`, written so it cannot overflow. The direct form overflows
    /// `cosh` around |x| = 710; this one is exact to the last bit for every
    /// input the drive stage can produce.
    @inline(__always)
    static func logCosh(_ x: Double) -> Double {
        let a = abs(x)
        return a + log1p(exp(-2.0 * a)) - 0.6931471805599453
    }

    /// Level compensation for a `tanh` drive stage, so `drive` adds HARMONICS
    /// RATHER THAN LEVEL.
    ///
    /// ⚠️ THE OBVIOUS FORMULAE ARE ALL WRONG, AND MEASURABLY SO. Normalising by
    /// `1/g` is right only in the linear region; normalising by `1/tanh(g)`
    /// preserves PEAK, not level — and preserving the peak while the waveform
    /// squares up RAISES the RMS by about 3 dB, because a square of amplitude 1
    /// has an RMS of 1 where a sine of amplitude 1 has 0.707. That 3 dB is not
    /// a rounding error, it is the entire quantity the "drive is not a volume
    /// knob" assertion measures, and an earlier version of this function failed
    /// that assertion by exactly 3.06 dB.
    ///
    /// So: normalise by the actual RMS of `tanh(g·sin)`, computed by
    /// quadrature. 32 points over a quarter period, ONCE PER NOTE-ON — an
    /// event, never a per-sample cost — and exactly 1.0 at `g == 1`, so a
    /// drive-free voice is bit-identical to having no drive stage at all.
    static func driveNormalisation(gain: Double) -> Double {
        guard gain.isFinite, gain > 1.0 else { return 1 }
        let reference = tanhSineRMS(1.0)
        let actual = tanhSineRMS(gain)
        guard actual > 1e-9 else { return 1 }
        return reference / actual
    }

    private static func tanhSineRMS(_ gain: Double) -> Double {
        let points = 32
        var sum = 0.0
        for index in 0..<points {
            let theta = (Double(index) + 0.5) * (Double.pi / 2.0) / Double(points)
            let value = tanh(gain * sin(theta))
            sum += value * value
        }
        return (sum / Double(points)).squareRoot()
    }

    /// First-order ADAA `tanh`. Returns the shaped value and the new history
    /// pair, so the caller decides where the state lives (one pair per voice —
    /// drum drive is post-voice and pre-pan, i.e. mono, so one pair suffices).
    ///
    /// ⚠️ The `|Δx| < ε` fallback is NOT optional: the quotient is 0/0 at a
    /// stationary input — a held DC value or silence — which is exactly what a
    /// decayed drum voice becomes.
    @inline(__always)
    static func adaaTanh(_ x: Double, prevX: Double, prevF: Double)
        -> (value: Double, x: Double, f: Double) {
        let f = logCosh(x)
        let delta = x - prevX
        let shaped: Double
        if abs(delta) > 1e-5 {
            shaped = (f - prevF) / delta
        } else {
            shaped = tanh(0.5 * (x + prevX))
        }
        return (shaped, x, f)
    }

    // MARK: - Filters

    /// Simper TPT state-variable coefficients. Derived at note-on and frozen.
    @inline(__always)
    static func svfCoefficients(cutoff: Double, q: Double, sampleRate: Double)
        -> (a1: Double, a2: Double, a3: Double, k: Double) {
        guard sampleRate > 0 else { return (0, 0, 0, 0) }
        let guarded = min(max(cutoff.isFinite ? cutoff : 1000, 10.0), sampleRate * 0.45)
        let safeQ = (q.isFinite && q > 0.01) ? q : 0.707
        let g = tan(.pi * guarded / sampleRate)
        let k = 1.0 / safeQ
        let a1 = 1.0 / (1.0 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2
        return (a1, a2, a3, k)
    }

    /// One TPT SVF step. `ic1`/`ic2` are the two integrator states. Returns
    /// (lowpass, bandpass, highpass) — the drum voices use band and high.
    @inline(__always)
    static func svfStep(_ input: Double, ic1: inout Double, ic2: inout Double,
                        a1: Double, a2: Double, a3: Double, k: Double)
        -> (low: Double, band: Double, high: Double) {
        let v3 = input - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2.0 * v1 - ic1
        ic2 = 2.0 * v2 - ic2
        return (low: v2, band: v1, high: input - k * v1 - v2)
    }

    /// One-pole highpass coefficient (`exp(-2π f / fs)`).
    @inline(__always)
    static func onePoleCoefficient(cutoff: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0, cutoff.isFinite, cutoff > 0 else { return 0 }
        return exp(-2.0 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate)
    }

    /// One-pole highpass step: `y = x − lp`, where `lp` tracks the input.
    @inline(__always)
    static func onePoleHighpass(_ input: Double, state: inout Double, coefficient: Double)
        -> Double {
        state = input + coefficient * (state - input)
        return input - state
    }

    // MARK: - Position-seeded noise

    /// ⛔⛔ THE ONE RT DETAIL A NAIVE IMPLEMENTATION GETS WRONG AND NO UNIT TEST
    /// CATCHES. A free-running PRNG makes the render a function of HOW MANY
    /// NOTES CAME BEFORE, which breaks the project's position-absolute
    /// determinism law — the same law `ModulationSnapshot` exists to protect.
    /// Rendering from bar 5 would then not match bar 5 of a full render, and
    /// nothing but a suffix-identity test would ever notice.
    ///
    /// So: seed PER NOTE-ON, from the note's absolute sample position and the
    /// voice slot. Each hit still varies (analogue-like), the whole render stays
    /// a pure function of position, and `reset()` has nothing to clear.
    @inline(__always)
    static func seed(noteOnSample: Int64, voiceSlot: Int32) -> UInt32 {
        // `truncatingIfNeeded`, never `UInt32(_:)` — the latter TRAPS on a
        // negative or large position, and `renderStart` is an Int64 that a
        // pre-roll can make negative.
        var x = UInt32(truncatingIfNeeded: noteOnSample)
            ^ (UInt32(bitPattern: voiceSlot) &* 0x9E37_79B9)
        // splitmix32 finaliser — decorrelates adjacent positions, so two hits
        // one sample apart do not sound like the same hit.
        x = x &+ 0x9E37_79B9
        var z = x
        z = (z ^ (z >> 16)) &* 0x21F0_AAAD
        z = (z ^ (z >> 15)) &* 0x735A_2D97
        z = z ^ (z >> 15)
        // xorshift32 cannot escape zero.
        return z == 0 ? 0x1234_5678 : z
    }

    /// xorshift32 step, returning bipolar white noise in [−1, 1).
    @inline(__always)
    static func nextNoise(_ state: inout UInt32) -> Double {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        // Top 24 bits → [−1, 1). Using the low bits of an xorshift is the
        // classic way to get a visibly poor sequence.
        return Double(Int32(bitPattern: state)) * (1.0 / 2_147_483_648.0)
    }

    // MARK: - Guards

    /// Clamps a value that is about to become a sample count.
    ///
    /// ⛔ `Int(Double.nan)` TRAPS — it does not return 0, it crashes the render
    /// thread. Modulated parameters can arrive non-finite if a source
    /// misbehaves, and several drum parameters (`clap.spread`, every decay)
    /// become sample counts. Never call `Int()` on a parameter without this.
    @inline(__always)
    static func sampleCount(seconds: Double, sampleRate: Double,
                            fallback: Int32 = 0, maximum: Int32 = 1 << 24) -> Int32 {
        guard seconds.isFinite, sampleRate > 0 else { return fallback }
        let raw = seconds * sampleRate
        guard raw.isFinite else { return fallback }
        if raw <= 0 { return 0 }
        if raw >= Double(maximum) { return maximum }
        return Int32(raw)
    }

    /// Replaces a non-finite value with a stated fallback, so one poisoned
    /// parameter cannot turn a whole quantum into NaN.
    @inline(__always)
    static func finite(_ value: Double, _ fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }
}
