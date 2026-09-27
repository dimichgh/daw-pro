import Accelerate
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// NT-F220 (vendored patch 0004, `PitchEditSet.formantRenderVersion` 3):
/// **THE FORMANT ENVELOPE, READ HARMONIC BY HARMONIC.**
///
/// G2's cepstral meter reads one number per cell. This reads what the
/// library's envelope estimate is FOR: the level of every output harmonic
/// against the IDEAL kept signal (the source's formants at the moved f0,
/// `SourceFilterVoice`, known by construction), 250-2500 Hz, after one
/// total-power match. Its six cells are down-shifts where signalsmith's
/// decay-and-erode envelope measurably over-corrected (predicted by W7-F220's
/// C++ port of this instrument: 5.42 dB mean without 0004, 2.38 dB with it;
/// the port reproduced every NT-E1 G2 line of a real test log exactly).
///
/// Every render goes through `NaturalTuningFormantRenderTests`' shipping
/// shape and G2's plan (one note over [0.2, 1.8] s, c = 1).
/// Deliberately NOT `@MainActor`.
@Suite("NT-F220 — the formant envelope, harmonic by harmonic (vendored patch 0004)")
struct NaturalTuningFormantEnvelopeTests {
    typealias R = NaturalTuningFormantRenderTests
    static let sampleRate = R.sampleRate

    /// Level (dB) of each harmonic k·f of `x` with k·f in [loHz, hiHz], over
    /// [0.5, 1.5) s: Blackman-Harris window, zero-padded 2^20 FFT (0.046 Hz
    /// bins), the largest bin within ±0.3 f of k·f (so a partial the render
    /// moved or smeared is found, not read as weak). nil below `loHz`.
    static func harmonicLevels(_ x: [Float], f: Double, loHz: Double, hiHz: Double) -> [Double?] {
        let start = 24_000, n = 48_000, log2m = 20, m = 1 << log2m
        var buffer = [Float](repeating: 0, count: m)
        for i in 0..<n {
            let t = 2 * Double.pi * Double(i) / Double(n - 1)
            let w = 0.35875 - 0.48829 * cos(t) + 0.14128 * cos(2 * t) - 0.01168 * cos(3 * t)
            buffer[i] = Float(w * Double(x[start + i]))
        }
        var re = [Float](repeating: 0, count: m / 2)
        var im = [Float](repeating: 0, count: m / 2)
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2m), FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buffer.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: m / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(m / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2m), FFTDirection(FFT_FORWARD))
            }
        }
        let binHz = sampleRate / Double(m)
        var levels: [Double?] = []
        var k = 1
        while Double(k) * f <= hiHz {
            let hz = Double(k) * f
            k += 1
            guard hz >= loHz else { levels.append(nil); continue }
            let a = max(1, Int((hz - 0.3 * f) / binHz))
            let b = min(m / 2 - 1, Int((hz + 0.3 * f) / binHz))
            var best = 0.0
            for i in a...b { best = max(best, Double(re[i]) * Double(re[i]) + Double(im[i]) * Double(im[i])) }
            levels.append(10 * log10(best + 1e-300))
        }
        return levels
    }

    /// RMS dB error of `x`'s harmonics of `f` against `ideal`'s, 250-2500 Hz,
    /// after one total-power match (so a level change is not an error).
    static func harmonicRms(_ x: [Float], ideal: [Float], f: Double) -> Double {
        let a = harmonicLevels(x, f: f, loHz: 250, hiHz: 2_500)
        let r = harmonicLevels(ideal, f: f, loHz: 250, hiHz: 2_500)
        var pa = 0.0, pr = 0.0
        for (la, lr) in zip(a, r) {
            if let la, let lr { pa += pow(10, la / 10); pr += pow(10, lr / 10) }
        }
        let d = 10 * log10(pr / pa)
        var se = 0.0, count = 0
        for (la, lr) in zip(a, r) {
            if let la, let lr { let e = la + d - lr; se += e * e; count += 1 }
        }
        return count > 0 ? sqrt(se / Double(count)) : .nan
    }

    /// Six down-shifts, c = 1, where the old envelope was measurably wrong.
    static let cells: [(f0: Double, cents: Double)] = [
        (196, -500), (220, -500), (262, -500), (294, -700), (330, -700), (440, -700),
    ]

    /// ⭐ F220-1, THE ENVELOPE GATE. The mean per-harmonic error of the kept
    /// render is at most 3.5 dB (predicted 2.38 with 0004; 5.42 without it,
    /// so a re-vendor that drops 0004 turns this red). Controls, all in-test:
    /// the ideal against itself reads exactly 0; a PLANTED +200 c formant
    /// scale reads at least 3 dB in every cell (predicted 4.8-5.5); the
    /// WITHHELD curve (formants follow the pitch) reads at least 8 dB on
    /// average (predicted 9.80). And the coupling: 0004's envelope is in the
    /// library, so `formantRenderVersion` must be at least 3, or engaged
    /// renders cached under 2 would serve the old envelope.
    @Test("F220-1: c = 1 keeps every harmonic's level near the ideal on six down-shifts (mean ≤ 3.5 dB); controls read 0, a planted scale and the withheld curve read large")
    func harmonicsFollowTheEnvelope() throws {
        #expect(PitchEditSet.formantRenderVersion >= 3,
                "vendored patch 0004 changes every engaged render: bump formantRenderVersion with it")
        var kept: [Double] = []
        var withheld: [Double] = []
        for (f0, cents) in Self.cells {
            let source = R.sourceVoice(f0: f0)
            let fo = f0 * pow(2, cents / 1200)
            let ideal = R.sourceVoice(f0: fo)
            let plan = try R.physicsPlan(f0: f0, cents: cents, amount: 1)
            let k = Self.harmonicRms(try R.render([source], plan: plan, formantPreserve: false), ideal: ideal, f: fo)
            let w = Self.harmonicRms(try R.render([source], plan: plan, formantPreserve: false, formant: .some(nil)),
                                     ideal: ideal, f: fo)
            let identity = Self.harmonicRms(ideal, ideal: ideal, f: fo)
            let plantedScale = Self.harmonicRms(R.sourceVoice(f0: fo, scaleCents: 200), ideal: ideal, f: fo)
            print(String(format: "NT-F220|harm| f0 %3.0f %+4.0f c: kept %.2f dB, withheld %.2f dB | controls: ideal vs itself %.2f, planted +200 c %.2f",
                         f0, cents, k, w, identity, plantedScale))
            #expect(identity == 0, "control: the instrument reads the ideal against itself as \(identity) dB")
            #expect(plantedScale >= 3, "control: the instrument cannot see a +200 c formant scale at f0 \(f0) (\(plantedScale) dB)")
            #expect(k.isFinite && w.isFinite)
            kept.append(k)
            withheld.append(w)
        }
        let meanKept = kept.reduce(0, +) / Double(kept.count)
        let meanWithheld = withheld.reduce(0, +) / Double(withheld.count)
        print(String(format: "NT-F220|harm| mean kept %.2f dB (max %.2f), mean withheld %.2f dB",
                     meanKept, kept.max() ?? .nan, meanWithheld))
        #expect(meanWithheld >= 8, "control: the withheld curve reads only \(meanWithheld) dB: the instrument is blind to a full follow")
        #expect(meanKept <= 3.5,
                "the formant envelope over-corrects again: mean per-harmonic error \(meanKept) dB (0004: ~2.4; without it ~5.4)")
    }

    /// F220-2, THE GUARDS. The engaged branch on hostile input and hostile
    /// bases: every sample finite, none subnormal, and silence in is silence
    /// out. Bases an octave either side of the voice, the 50 Hz floor, and
    /// bases so high that one peak spans the spectrum (predicted: all clean,
    /// on the shipped header and with 0004).
    @Test("F220-2: the engaged branch stays finite and normal on silence, a whisper, a sine, noise, an impulse, a full-scale square and extreme bases")
    func engagedBranchStaysFinite() throws {
        let frames = Int(R.physicsSeconds * Self.sampleRate)
        let voice = R.sourceVoice(f0: 220)
        var rng: UInt32 = 12_345
        let noise: [Float] = (0..<frames).map { _ in
            rng = rng &* 1_664_525 &+ 1_013_904_223
            return Float(Double(rng >> 8) / Double(1 << 24) * 2 - 1) * 0.5
        }
        var impulse = [Float](repeating: 0, count: frames)
        impulse[frames / 2] = 1
        let silence = [Float](repeating: 0, count: frames)
        let whisper: [Float] = voice.map { $0 * 1e-20 }
        let sine: [Float] = (0..<frames).map { i in
            Float(0.5 * sin(2 * Double.pi * 1_000 * Double(i) / Self.sampleRate))
        }
        let square: [Float] = (0..<frames).map { i -> Float in
            (Double(i) * 147 / Self.sampleRate).truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : -1
        }
        let cases: [(label: String, source: [Float], base: Double, cents: Double)] = [
            ("silence", silence, 220, -500),
            ("voice × 1e-20", whisper, 220, -500),
            ("sine 1 kHz", sine, 220, -500),
            ("white noise", noise, 220, -500),
            ("one impulse", impulse, 220, 700),
            ("full-scale square 147 Hz", square, 147, -700),
            ("voice 220, base 110", voice, 110, -500),
            ("voice 220, base 440", voice, 440, -500),
            ("voice 220, base 50 (the floor)", voice, 50, -500),
            ("voice 220, base 20 kHz", voice, 20_000, -500),
        ]
        for c in cases {
            let plan = try R.physicsPlan(f0: c.base, cents: c.cents, amount: 1)
            let out = try R.render([c.source], plan: plan, formantPreserve: false)
            let nonFinite = out.filter { !$0.isFinite }.count
            let subnormal = out.filter { $0.isSubnormal }.count
            let peakIn = c.source.map { abs($0) }.max() ?? 0
            let peakOut = out.filter { $0.isFinite }.map { abs($0) }.max() ?? 0
            print("NT-F220|guard| \(c.label): non-finite \(nonFinite), subnormal \(subnormal), max|out| \(peakOut) (max|in| \(peakIn))")
            #expect(nonFinite == 0, "\(c.label): \(nonFinite) non-finite samples")
            #expect(subnormal == 0, "\(c.label): \(subnormal) subnormal samples")
            if peakIn == 0 { #expect(peakOut == 0, "\(c.label): silence in, \(peakOut) out") }
        }
    }
}
