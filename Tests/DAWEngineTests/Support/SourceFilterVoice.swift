import Foundation

/// m23-nt NT-G — **THE KNOWN-ANSWER VOICE.** A source-filter synthesiser (a
/// pulse train through cascaded formant resonators, the textbook model behind
/// classic formant/cascade speech synthesisers), plus a "Star"-shaped
/// syllable (s + t + /a/) with ground-truth voicing. It exists so the natural
/// tuning meters (`SpectralEnvelopeMeter`, `ConsonantSpectrumMeter`) can be
/// proven against a signal whose formant frequencies and whose f0 are BOTH
/// independently known and independently controllable — real voice never
/// offers that.
///
/// **Why a pulse train, not white noise or a sung take.** A source-filter
/// model has two orthogonal knobs: the SOURCE's rate (f0, glottal pulses/sec)
/// and the FILTER's shape (the vocal-tract resonances, "formants"). Moving
/// one must not move a meter reading the other — that is exactly the
/// distinction natural tuning exists to preserve (design
/// `docs/design/2026-09-25-natural-tuning.md` §1). Single-sample impulses are
/// used rather than a shaped glottal pulse so the SOURCE's own spectrum is
/// flat (excluding the periodicity comb): any envelope shape a meter reads
/// back is the FILTER's, not a source artefact riding along.
///
/// nonisolated, no shared state: reachable from both `@MainActor` and free
/// suites, and safe to call from multiple tests concurrently.
enum SourceFilterVoice {
    /// One resonator: a centre frequency and a −3 dB bandwidth, both Hz.
    struct Formant: Sendable {
        var frequencyHz: Double
        var bandwidthHz: Double
        init(_ frequencyHz: Double, _ bandwidthHz: Double) {
            self.frequencyHz = frequencyHz
            self.bandwidthHz = bandwidthHz
        }
    }

    /// Roughly an open, low-back vowel ("ah"). Not tied to any real speaker —
    /// only its RATIOS under a formant-scale shift matter to the meters this
    /// fixture proves.
    static let defaultFormants: [Formant] = [
        Formant(700, 80), Formant(1220, 90), Formant(2600, 120), Formant(3400, 150),
    ]

    /// Scales every formant's centre AND bandwidth by the same factor
    /// `2^(cents/1200)`. Scaling the bandwidth too is deliberate: it keeps a
    /// "formant scale" a pure shift along the LOG-frequency axis (every
    /// resonance keeps the same shape in octaves), which is what makes the
    /// cepstral meter's known answer exact rather than approximate — a
    /// scale-only shift correlates against itself at a constant lag in
    /// log-frequency, a bandwidth-only widening would not.
    static func scaledFormants(
        _ cents: Double, base: [Formant] = defaultFormants
    ) -> [Formant] {
        let k = pow(2, cents / 1200)
        return base.map { Formant($0.frequencyHz * k, $0.bandwidthHz * k) }
    }

    // MARK: - The source: a single-sample impulse train

    /// A phase-continuous impulse train at `f0Hz`: exactly one non-zero
    /// sample per period, carried with fractional-phase accumulation so f0
    /// stays exact over a long buffer (no cumulative rounding drift — a
    /// rounded-period train would slowly detune, which would confound the
    /// "f0 moves, envelope must not" instrument control).
    ///
    /// ⚠️ **A −50 dB WHITE NOISE FLOOR IS MIXED IN, DELIBERATELY, SEEDED FOR
    /// REPRODUCIBILITY, FOR REALISM — NOT AS THE LPC FIX.** A perfectly
    /// ideal, noise-free impulse train is more periodic than any real
    /// glottal source (which always carries jitter and breath noise); this
    /// floor makes the fixture closer to that. It was FIRST tried as a fix
    /// for `SpectralEnvelopeMeter.lpcFormants`'s Levinson-Durbin instability
    /// on this fixture (measured: the noise-free train collapsed the
    /// recursion at order ~4, hiding F2/F3) and MEASURED NOT TO FIX IT —
    /// noise added HERE, before the resonators, is coloured by the same
    /// filter it is meant to regularise, so it adds no white component to
    /// the autocorrelation the recursion actually sees. The real fix is in
    /// `lpcFormants` (fit the model at a decimated rate; see its doc). This
    /// floor stays for realism and is harmless to every known-answer test in
    /// this file, re-checked after the LPC fix landed.
    static func pulseTrain(
        f0Hz: Double, frames: Int, sampleRate: Double, amplitude: Float = 0.9,
        noiseFloorDb: Double = -50, seed: UInt64 = 0xF0F0
    ) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        guard f0Hz > 0, sampleRate > 0 else { return out }
        let period = sampleRate / f0Hz
        var nextImpulse = 0.0
        while nextImpulse < Double(frames) {
            let idx = Int(nextImpulse.rounded())
            if idx >= 0 && idx < frames { out[idx] = amplitude }
            nextImpulse += period
        }
        let noiseAmplitude = amplitude * Float(pow(10, noiseFloorDb / 20))
        var generator = SplitMix64(seed: seed)
        for i in 0..<frames { out[i] += (generator.nextUnit() * 2 - 1) * noiseAmplitude }
        return out
    }

    // MARK: - The filter: a cascade of 2-pole formant resonators

    /// Runs `x` through a cascade (series) of resonant filters, one per
    /// formant — the classic "cascade synthesiser" topology, where each
    /// stage imprints one spectral peak and the whole chain is the vocal
    /// tract's envelope. Each stage is a standard 2-pole resonator:
    ///
    ///     r  = exp(-pi * bandwidthHz / sampleRate)
    ///     th = 2 * pi * frequencyHz / sampleRate
    ///     y[n] = (1 - r) * x[n] + 2 r cos(th) y[n-1] - r^2 y[n-2]
    ///
    /// The output is peak-normalised to 0.8 after the cascade: four stages in
    /// series can gain up by orders of magnitude, and only the SHAPE of the
    /// envelope is under test, never its absolute level.
    static func resonatorCascade(
        _ x: [Float], formants: [Formant], sampleRate: Double
    ) -> [Float] {
        var y = x
        for formant in formants {
            let r = exp(-Double.pi * formant.bandwidthHz / sampleRate)
            let theta = 2 * Double.pi * formant.frequencyHz / sampleRate
            let a1 = 2 * r * cos(theta)
            let a2 = r * r
            let b0 = Float(1 - r)
            var out = [Float](repeating: 0, count: y.count)
            var y1: Float = 0, y2: Float = 0
            for n in 0..<y.count {
                let v = b0 * y[n] + Float(a1) * y1 - Float(a2) * y2
                out[n] = v
                y2 = y1
                y1 = v
            }
            y = out
        }
        var peak: Float = 0
        for v in y { peak = max(peak, abs(v)) }
        guard peak > 0 else { return y }
        let scale: Float = 0.8 / peak
        return y.map { $0 * scale }
    }

    /// One voiced sample: a pulse train at `f0Hz` through `formants` (scaled
    /// by `formantScaleCents` from `defaultFormants` when `formants` is nil).
    /// The two parameters are ORTHOGONAL by construction — this is the whole
    /// point of the fixture.
    static func voice(
        f0Hz: Double, formantScaleCents: Double = 0, frames: Int,
        sampleRate: Double, amplitude: Float = 0.9, formants: [Formant]? = nil
    ) -> [Float] {
        let source = pulseTrain(f0Hz: f0Hz, frames: frames, sampleRate: sampleRate,
                                amplitude: amplitude)
        let filter = formants ?? scaledFormants(formantScaleCents)
        return resonatorCascade(source, formants: filter, sampleRate: sampleRate)
    }

    // MARK: - Unvoiced parts: the 's' fricative and the 't' stop

    /// A shaped noise burst standing in for a fricative ('s'): white noise
    /// high-passed by a one-pole difference (`x[n] - 0.97 x[n-1]`), which
    /// pushes most of its energy above ~2-3 kHz the way a real sibilant does
    /// (READ: this is the standard cheap "hiss" shaping, not a claim of
    /// phonetic accuracy — the meters below only need SOME identifiable
    /// high-frequency energy that a pitch move could, wrongly, be seen to
    /// shift). Deterministic: seeded, so a fixture rendered twice compares
    /// byte for byte.
    static func fricativeBurst(
        durationSeconds: Double, sampleRate: Double, amplitude: Float = 0.5,
        seed: UInt64 = 0xA11CE
    ) -> [Float] {
        let frames = max(0, Int((durationSeconds * sampleRate).rounded()))
        var generator = SplitMix64(seed: seed)
        var raw = [Float](repeating: 0, count: frames)
        for i in 0..<frames { raw[i] = generator.nextUnit() * 2 - 1 }
        var out = [Float](repeating: 0, count: frames)
        var prev: Float = 0
        for i in 0..<frames {
            let v = raw[i] - 0.97 * prev
            prev = raw[i]
            out[i] = v * amplitude
        }
        // Short raised-cosine fades so the burst does not click at its own edges.
        applyEdgeFades(&out, sampleRate: sampleRate, fadeSeconds: 0.003)
        return out
    }

    /// A stop consonant standing in for 't': near silence (the closure) then
    /// a very brief broadband click (the release burst) in the final third of
    /// the duration.
    static func stopBurst(
        durationSeconds: Double, sampleRate: Double, amplitude: Float = 0.4,
        seed: UInt64 = 0x570B
    ) -> [Float] {
        let frames = max(0, Int((durationSeconds * sampleRate).rounded()))
        var out = [Float](repeating: 0, count: frames)
        let releaseFrames = max(1, Int((0.004 * sampleRate).rounded()))
        let releaseStart = max(0, frames - releaseFrames - Int(0.002 * sampleRate))
        var generator = SplitMix64(seed: seed)
        for i in 0..<releaseFrames {
            let idx = releaseStart + i
            guard idx < frames else { break }
            out[idx] = (generator.nextUnit() * 2 - 1) * amplitude
        }
        return out
    }

    /// Raised-cosine amplitude fades at both ends, in place — keeps
    /// concatenated bursts from clicking at their own seams.
    private static func applyEdgeFades(_ x: inout [Float], sampleRate: Double, fadeSeconds: Double) {
        let n = max(1, Int((fadeSeconds * sampleRate).rounded()))
        guard x.count > 2 * n else { return }
        for i in 0..<n {
            let g = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(n)))
            x[i] *= g
            x[x.count - 1 - i] *= g
        }
    }

    /// One rendered "Star"-shaped syllable: 's' (120 ms) + 't' (20 ms) + a
    /// held /a/ (400 ms), concatenated with no gap — the §2 fixture the
    /// design names (2g: "s 120 ms, t 20 ms, /a/ 400 ms, with ground-truth
    /// voicing"). `voicedRange` is the /a/'s time span in the returned
    /// buffer's own seconds: the ONLY voiced part, by construction.
    struct StarSyllable: Sendable {
        let audio: [Float]
        let sampleRate: Double
        let sSeconds: ClosedRange<Double>
        let tSeconds: ClosedRange<Double>
        let voicedRange: ClosedRange<Double>
        let f0Hz: Double
    }

    static func starSyllable(
        f0Hz: Double, formantScaleCents: Double = 0, sampleRate: Double,
        sSeconds: Double = 0.120, tSeconds: Double = 0.020, aSeconds: Double = 0.400
    ) -> StarSyllable {
        let s = fricativeBurst(durationSeconds: sSeconds, sampleRate: sampleRate)
        let t = stopBurst(durationSeconds: tSeconds, sampleRate: sampleRate)
        let aFrames = max(0, Int((aSeconds * sampleRate).rounded()))
        var a = voice(f0Hz: f0Hz, formantScaleCents: formantScaleCents, frames: aFrames,
                     sampleRate: sampleRate)
        applyEdgeFades(&a, sampleRate: sampleRate, fadeSeconds: 0.003)
        let audio = s + t + a
        let sEnd = Double(s.count) / sampleRate
        let tEnd = sEnd + Double(t.count) / sampleRate
        let aEnd = tEnd + Double(a.count) / sampleRate
        return StarSyllable(audio: audio, sampleRate: sampleRate,
                            sSeconds: 0...sEnd, tSeconds: sEnd...tEnd,
                            voicedRange: tEnd...aEnd, f0Hz: f0Hz)
    }
}

/// A tiny deterministic PRNG (SplitMix64) — Foundation's `SystemRandomNumberGenerator`
/// is not seedable, and a fixture that is not byte-reproducible cannot back a
/// golden. Test-only; not the product's RNG.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// Uniform Float in [0, 1).
    mutating func nextUnit() -> Float {
        Float(next() >> 11) * (1.0 / Float(1 << 53))
    }
}
