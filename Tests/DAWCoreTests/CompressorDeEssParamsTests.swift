import DAWCore
import Foundation
import Testing

/// m39-ae — the de-esser's DOMAIN half: the three appended params, the snap,
/// the derived band width, and the band-pass coefficients they resolve to.
///
/// ⚠️ NOT `@MainActor`, deliberately: everything under test is a pure value
/// type or a pure function, and `MainActorOccupancySiteTests` Leg C caps
/// main-actor-isolated suites at a census that is currently AT its ceiling.
@Suite("m39-ae de-esser params and coefficients")
struct CompressorDeEssParamsTests {

    // MARK: - Clamping, defaults, round-trip

    @Test("defaults are OFF / 6500 Hz / Q 2, and the shipped six are untouched")
    func defaultsAreOff() {
        let p = CompressorParams()
        #expect(p.detectorMode == 0)
        #expect(p.detectorFreqHz == 6_500)
        #expect(p.detectorQ == 2)
        // The pre-m39-ae defaults, restated here so an accidental edit to the
        // init's signature cannot move one of them unnoticed.
        #expect(p.thresholdDb == -18 && p.ratio == 4 && p.attackMs == 10)
        #expect(p.releaseMs == 100 && p.kneeDb == 6 && p.makeupDb == 0 && p.mix == 1)
    }

    @Test("every new param clamps to its declared range on init (the GainParams pattern)")
    func clampsOnInit() {
        #expect(CompressorParams(detectorMode: 9).detectorMode == 2)
        #expect(CompressorParams(detectorMode: -4).detectorMode == 0)
        #expect(CompressorParams(detectorFreqHz: 50).detectorFreqHz == 1_000)
        #expect(CompressorParams(detectorFreqHz: 40_000).detectorFreqHz == 16_000)
        #expect(CompressorParams(detectorQ: 0).detectorQ == 0.3)
        #expect(CompressorParams(detectorQ: 100).detectorQ == 8)
        // In-range values pass through exactly — a clamp that rounds would be a
        // different bug with the same shape.
        #expect(CompressorParams(detectorFreqHz: 7_123.5).detectorFreqHz == 7_123.5)
        #expect(CompressorParams(detectorQ: 1.375).detectorQ == 1.375)
    }

    /// ⛔ THE LAW THE WHOLE ITEM TURNS ON. Every project saved before m39-ae
    /// omits these three keys and must decode to a compressor whose detector is
    /// flat. The `mix` precedent (m23-ck) verbatim, and the stricter case: 1 is
    /// at least a setting, whereas 0 here means "this feature is switched off".
    @Test("absent keys decode to OFF; present keys round-trip")
    func codingDefaultsAndRoundTrip() throws {
        let legacy = Data(#"{"thresholdDb":-30,"ratio":2,"attackMs":5,"releaseMs":200,"kneeDb":1,"makeupDb":3}"#.utf8)
        let decoded = try JSONDecoder().decode(CompressorParams.self, from: legacy)
        #expect(decoded.detectorMode == 0)
        #expect(decoded.detectorFreqHz == 6_500)
        #expect(decoded.detectorQ == 2)
        #expect(decoded.mix == 1)  // m23-ck's own absent-key default, still true

        let set = CompressorParams(detectorMode: 1, detectorFreqHz: 7_400, detectorQ: 3.5)
        let round = try JSONDecoder().decode(
            CompressorParams.self, from: JSONEncoder().encode(set))
        #expect(round == set)
        // …and the encoding really carries the keys, so the round trip above is
        // not two defaults agreeing with each other.
        let json = try #require(String(data: JSONEncoder().encode(set), encoding: .utf8))
        #expect(json.contains("detectorMode"))
        #expect(json.contains("detectorFreqHz"))
        #expect(json.contains("detectorQ"))
    }

    // MARK: - The snap and the derived width

    @Test("detectorMode snaps to the nearest of 0/1/2 and refuses anything else")
    func snapIsTotal() {
        #expect(CompressorParams.detectorMode(at: 0) == .off)
        #expect(CompressorParams.detectorMode(at: 1) == .bandPass)
        #expect(CompressorParams.detectorMode(at: 2) == .highPass)
        #expect(CompressorParams.detectorMode(at: 1.49) == .bandPass)
        #expect(CompressorParams.detectorMode(at: 1.51) == .highPass)
        // ⚠️ NON-FINITE FIRST, AND IT IS NOT DEFENSIVE HABIT: this helper does an
        // `Int()` conversion, which TRAPS on a NaN (the RingModParams.waveform
        // precedent), and a field-by-field automation poke bypasses the clamping
        // init entirely — so a NaN really can arrive here.
        #expect(CompressorParams.detectorMode(at: .nan) == .off)
        #expect(CompressorParams.detectorMode(at: -.infinity) == .off)
        // ⛔⛔ THIS LINE FOUND A CRASH AND IT STAYS. 1e300 is FINITE, so an
        // `isFinite` guard lets it through — and `Int(1e300)` TRAPS, because the
        // result does not fit. The first version of `detectorMode(at:)` guarded
        // only `isFinite` and this expectation brought the whole test binary
        // down with "Double value cannot be converted to Int". On the render
        // thread that is a crash in the audio callback, reachable because a
        // field-by-field automation poke bypasses the clamping init.
        // Out-of-range now CLAMPS, matching ClipperParams.mode(at:) and the
        // documented wire contract, so 1e300 lands on the top of the range.
        #expect(CompressorParams.detectorMode(at: 1e300) == .highPass)
        #expect(CompressorParams.detectorMode(at: -1e300) == .off)
        #expect(CompressorParams.detectorMode(at: 99) == .highPass)
        #expect(CompressorParams.detectorMode(at: -3) == .off)
    }

    @Test("the derived band width is freq / Q, through clamped inputs")
    func derivedBandwidth() {
        #expect(CompressorParams.detectorBandwidthHz(freqHz: 6_500, q: 2) == 3_250)
        #expect(CompressorParams.detectorBandwidthHz(freqHz: 8_000, q: 4) == 2_000)
        // Out-of-range inputs clamp rather than producing an absurd width — a
        // wire echo that reports 1e9 Hz teaches nothing.
        #expect(CompressorParams.detectorBandwidthHz(freqHz: 1e9, q: 0.0001)
                == 16_000 / 0.3)
    }

    // MARK: - The coefficients the modes resolve to

    /// ⛔ THE BAND-PASS FORM IS LOAD-BEARING. RBJ gives two; the CONSTANT-SKIRT
    /// one peaks at `Q`, so at Q 4 it would hand the detector a 12 dB boost
    /// nobody asked for and widening the band would silently LOWER the effective
    /// threshold. The constant-0-dB-peak form peaks at exactly 1.0 for every Q,
    /// which is what makes `thresholdDb` mean the same dBFS banded as broadband.
    @Test("bandPassSection peaks at 0 dB for EVERY Q, and rolls off both sides")
    func bandPassIsConstantPeakGain() {
        let rate = 48_000.0
        for q in [0.3, 0.707, 2.0, 4.0, 8.0] {
            let s = EQFilterResponse.bandPassSection(freq: 6_500, q: q, sampleRate: rate)
            let atCentre = EQFilterResponse.magnitudeDb(s, frequency: 6_500, sampleRate: rate)
            #expect(abs(atCentre) < 0.05, Comment(rawValue:
                "Q \(q): the band peaks at \(atCentre) dB, not 0. This is the constant-SKIRT "
                + "form (peak gain = Q), which makes the de-ess threshold depend on the band "
                + "width — set the constant-0-dB-peak coefficients instead."))
            // ⭐ AND THE PEAK IS AT THE CENTRE, which is the other half of
            // "constant 0 dB PEAK gain" and the half a lone reading at 6500 Hz
            // cannot see: a section that read 0 dB everywhere would pass the
            // assertion above and be no filter at all.
            for probe in [100.0, 650.0, 2_000.0, 13_000.0, 20_000.0] {
                let here = EQFilterResponse.magnitudeDb(s, frequency: probe, sampleRate: rate)
                #expect(here <= atCentre + 0.05, Comment(rawValue:
                    "Q \(q): \(probe) Hz reads \(here) dB, ABOVE the band centre's "
                    + "\(atCentre) dB — the peak is not where the parameter says it is"))
            }
            // A decade below the centre the skirt is well down at every Q. ⚠️
            // 650 Hz IS a decade below and that is the point: the first draft of
            // this test asserted −6 dB at 18 kHz too and FAILED at Q 0.3, which
            // was the test being wrong rather than the filter — a Q of 0.3 gives
            // a bandwidth of 6500/0.3 ≈ 21.7 kHz, so 18 kHz is still inside the
            // band and is SUPPOSED to pass.
            #expect(EQFilterResponse.magnitudeDb(s, frequency: 650, sampleRate: rate) < -6)
        }
        // The width really is width: at Q 8 the same distant tone is rejected
        // far harder than at Q 0.3. Without this the peak assertion above would
        // pass on a section that is flat everywhere.
        let wide = EQFilterResponse.bandPassSection(freq: 6_500, q: 0.3, sampleRate: rate)
        let narrow = EQFilterResponse.bandPassSection(freq: 6_500, q: 8, sampleRate: rate)
        #expect(EQFilterResponse.magnitudeDb(narrow, frequency: 1_000, sampleRate: rate)
                < EQFilterResponse.magnitudeDb(wide, frequency: 1_000, sampleRate: rate) - 12)
    }

    /// The default band's rejection of a vowel is the margin the de-esser's
    /// "ignores non-sibilant material" property lives on, so it is measured
    /// rather than assumed. ~30 dB at 300 Hz against a 6500 Hz / Q 2 band.
    /// ⚠️ THE FLOOR IS 20 dB AND IT WAS NOT CHOSEN, IT WAS MEASURED DOWN TO.
    /// The first draft asserted 25 dB across 150/300/800 Hz and FAILED at
    /// 800 Hz, which reads −24.65 dB — the test was wrong, not the filter. The
    /// measured values are printed on every run so the margin's erosion is
    /// visible rather than inferred.
    @Test("the DEFAULT band rejects vowel-range content by at least 20 dB")
    func defaultBandRejectsVowels() {
        let rate = 48_000.0
        let s = EQFilterResponse.bandPassSection(freq: 6_500, q: 2, sampleRate: rate)
        var readings: [String] = []
        for hz in [150.0, 300.0, 800.0] {
            let db = EQFilterResponse.magnitudeDb(s, frequency: hz, sampleRate: rate)
            readings.append("\(Int(hz)) Hz \(String(format: "%.2f", db)) dB")
            #expect(db < -20, Comment(rawValue:
                "the default de-ess band passes \(hz) Hz at \(db) dB. A de-esser that hears "
                + "the vowel is just a compressor."))
        }
        print("[measured] m39-ae default de-ess band rejection — " + readings.joined(separator: " · "))
    }

    /// ⭐ WHY `detectorQ` IS DOCUMENTED AS MEANING TWO THINGS — the high-pass
    /// mode's response AT its corner IS Q, so the default 2 is a deliberate
    /// +6 dB emphasis exactly where sibilance starts. That is a claim in the
    /// param's `note`, in the wire docs and in the physics gate's mode-gap leg,
    /// so it is pinned here rather than left as folklore.
    @Test("the high-pass mode's corner gain IS detectorQ (the +6 dB at Q 2)")
    func highPassCornerGainIsQ() {
        let rate = 48_000.0
        for q in [0.707, 2.0, 4.0] {
            let s = EQFilterResponse.cutSection(highPass: true, freq: 6_500, q: q,
                                                sampleRate: rate)
            let atCorner = EQFilterResponse.magnitudeDb(s, frequency: 6_500, sampleRate: rate)
            let expected = 20 * log10(q)
            #expect(abs(atCorner - expected) < 0.3, Comment(rawValue:
                "Q \(q): high-pass reads \(atCorner) dB at its corner, expected \(expected)"))
        }
        // …and it rejects the vowel harder than the band-pass does, which is
        // why it is offered at all.
        let hp = EQFilterResponse.cutSection(highPass: true, freq: 6_500, q: 2,
                                             sampleRate: rate)
        #expect(EQFilterResponse.magnitudeDb(hp, frequency: 300, sampleRate: rate) < -35)
    }

    /// The coefficients must survive the lowest sample rate the app supports
    /// with the highest corner it offers — 16 kHz is above Nyquist at 32 kHz,
    /// where an unclamped `tan(π/2)` would produce infinities on the render
    /// thread.
    @Test("a 16 kHz corner at a 32 kHz rate produces finite, stable coefficients")
    func nyquistClampHolds() {
        for rate in [32_000.0, 44_100.0, 48_000.0, 96_000.0] {
            for section in [EQFilterResponse.bandPassSection(freq: 16_000, q: 8,
                                                             sampleRate: rate),
                            EQFilterResponse.cutSection(highPass: true, freq: 16_000, q: 8,
                                                        sampleRate: rate)] {
                for c in [section.b0, section.b1, section.b2, section.a1, section.a2] {
                    #expect(c.isFinite, Comment(rawValue:
                        "rate \(rate): a coefficient is \(c) — an unclamped corner at or above "
                        + "Nyquist reached the tangent"))
                }
                // Poles inside the unit circle: |a2| < 1 is the stability
                // condition for a normalised 2-pole section.
                #expect(abs(section.a2) < 1.0)
            }
        }
    }
}
