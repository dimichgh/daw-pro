import Foundation
import Testing
@testable import DAWCore

// M5 iv-a (spec §3, §7): BS.1770-4 loudness core — pure analytic fixtures, no
// files, no engine. The 997 Hz calibration identity (K-gain at 997 Hz cancels
// the −0.691 offset) makes every expected value exact: a 997 Hz sine at
// −X dBFS peak per channel measures −X − 3.01 + 10·log10(channelCount) LUFS.

// MARK: - Fixtures

/// 997 Hz-style sine, `dbfs` = PEAK level (the BS.1770 calibration convention).
private func sine(frequency: Double, dbfs: Double, seconds: Double,
                  sampleRate: Double, phaseRadians: Double = 0) -> [Float] {
    let amplitude = pow(10.0, dbfs / 20.0)
    let count = Int((seconds * sampleRate).rounded())
    var out = [Float](repeating: 0, count: count)
    for n in 0..<count {
        out[n] = Float(amplitude * sin(2.0 * .pi * frequency * Double(n) / sampleRate + phaseRadians))
    }
    return out
}

private func stereo(_ channel: [Float], sampleRate: Double) -> RenderedAudio {
    RenderedAudio(sampleRate: sampleRate, channelData: [channel, channel])
}

private func magnitudeDb(_ c: Loudness.Biquad, frequency: Double, sampleRate: Double) -> Double {
    let w = 2.0 * .pi * frequency / sampleRate
    let bRe = c.b0 + c.b1 * cos(w) + c.b2 * cos(2 * w)
    let bIm = -(c.b1 * sin(w) + c.b2 * sin(2 * w))
    let aRe = 1.0 + c.a1 * cos(w) + c.a2 * cos(2 * w)
    let aIm = -(c.a1 * sin(w) + c.a2 * sin(2 * w))
    return 10.0 * log10((bRe * bRe + bIm * bIm) / (aRe * aRe + aIm * aIm))
}

// MARK: - K-weighting coefficients (§3.1)

@Suite("K-weighting — derivation vs the BS.1770-4 tables")
struct KWeightingCoefficientTests {

    // 1. The 48 kHz pin: re-derived coefficients match the published tables ≤ 1e-6.
    @Test("48 kHz derivation reproduces BS.1770-4 Tables 1–2 within 1e-6")
    func pinAt48k() {
        let stages = Loudness.kWeightingStages(sampleRate: 48_000)
        #expect(abs(stages.shelf.b0 - 1.53512485958697) <= 1e-6)
        #expect(abs(stages.shelf.b1 - -2.69169618940638) <= 1e-6)
        #expect(abs(stages.shelf.b2 - 1.19839281085285) <= 1e-6)
        #expect(abs(stages.shelf.a1 - -1.69065929318241) <= 1e-6)
        #expect(abs(stages.shelf.a2 - 0.73248077421585) <= 1e-6)
        // RLB b side is [1, −2, 1] EXACTLY (unnormalized, per the ITU table).
        #expect(stages.highPass.b0 == 1.0)
        #expect(stages.highPass.b1 == -2.0)
        #expect(stages.highPass.b2 == 1.0)
        #expect(abs(stages.highPass.a1 - -1.99004745483398) <= 1e-6)
        #expect(abs(stages.highPass.a2 - 0.99007225036621) <= 1e-6)
    }

    // 2. Rate-derivation sanity at 44.1 k / 96 k: the shelf is a monotone
    //    high shelf approaching +4 dB; the RLB high-pass blocks DC and is
    //    transparent at 1 kHz.
    @Test("re-derivation at other rates keeps the filter shapes",
          arguments: [44_100.0, 96_000.0])
    func rateDerivationSanity(fs: Double) {
        let stages = Loudness.kWeightingStages(sampleRate: fs)

        let probes = [100.0, 300.0, 1_000.0, 3_000.0, 8_000.0, 0.4 * fs]
        let shelfResponse = probes.map { magnitudeDb(stages.shelf, frequency: $0, sampleRate: fs) }
        for i in 1..<shelfResponse.count {
            #expect(shelfResponse[i] > shelfResponse[i - 1], "shelf gain must rise with frequency")
        }
        #expect(abs(shelfResponse[0]) < 0.05)                       // ~0 dB in the low band
        #expect(shelfResponse.last! > 3.7 && shelfResponse.last! < 4.05)  // ~+4 dB up top

        // DC is an exact zero: b sums to 0 ⇒ |H(0)| = 0.
        #expect(stages.highPass.b0 + stages.highPass.b1 + stages.highPass.b2 == 0.0)
        #expect(magnitudeDb(stages.highPass, frequency: 10, sampleRate: fs) < -20)
        #expect(abs(magnitudeDb(stages.highPass, frequency: 1_000, sampleRate: fs)) < 0.1)
    }
}

// MARK: - Integrated loudness (§3.2)

@Suite("Integrated loudness — calibration + channel weighting")
struct IntegratedLoudnessTests {

    // 1. The standard calibration: 997 Hz stereo at −23 dBFS/channel → −23.0 LUFS.
    @Test("997 Hz stereo sine at −23 dBFS/channel, 20 s → −23.0 ± 0.1 LUFS (48 k)")
    func calibrationAt48k() throws {
        let audio = stereo(sine(frequency: 997, dbfs: -23, seconds: 20, sampleRate: 48_000),
                           sampleRate: 48_000)
        let m = Loudness.measure(audio)
        let integrated = try #require(m.integratedLufs)
        #expect(abs(integrated - -23.0) <= 0.1)
        // Momentary/short-term on a steady tone sit at the same level.
        #expect(abs(try #require(m.maxMomentaryLufs) - -23.0) <= 0.1)
        #expect(abs(try #require(m.maxShortTermLufs) - -23.0) <= 0.1)
    }

    // 2. Same calibration at 44.1 k — the derived-coefficient path, not the pinned table.
    @Test("calibration holds at 44.1 kHz (derived coefficients)")
    func calibrationAt44k() throws {
        let audio = stereo(sine(frequency: 997, dbfs: -23, seconds: 10, sampleRate: 44_100),
                           sampleRate: 44_100)
        let integrated = try #require(Loudness.measure(audio).integratedLufs)
        #expect(abs(integrated - -23.0) <= 0.1)
    }

    // 3. The −33 dBFS variant.
    @Test("997 Hz stereo sine at −33 dBFS/channel → −33.0 ± 0.1 LUFS")
    func minus33Variant() throws {
        let audio = stereo(sine(frequency: 997, dbfs: -33, seconds: 20, sampleRate: 48_000),
                           sampleRate: 48_000)
        let integrated = try #require(Loudness.measure(audio).integratedLufs)
        #expect(abs(integrated - -33.0) <= 0.1)
    }

    // 4. Channel-sum math: left-only −23 dBFS loses the 10·log10(2) stereo sum → −26.0.
    @Test("left-only 997 Hz at −23 dBFS → −26.0 ± 0.1 LUFS")
    func leftOnlyChannelWeight() throws {
        let left = sine(frequency: 997, dbfs: -23, seconds: 20, sampleRate: 48_000)
        let audio = RenderedAudio(sampleRate: 48_000,
                                  channelData: [left, [Float](repeating: 0, count: left.count)])
        let integrated = try #require(Loudness.measure(audio).integratedLufs)
        #expect(abs(integrated - -26.0) <= 0.1)
    }

    // 5. Channel weights: L/R/C at 1.0, surround at 1.41 (documented future).
    @Test("BS.1770 channel weights by index")
    func channelWeights() {
        #expect(Loudness.channelWeight(0) == 1.0)
        #expect(Loudness.channelWeight(1) == 1.0)
        #expect(Loudness.channelWeight(2) == 1.0)
        #expect(Loudness.channelWeight(3) == 1.41)
        #expect(Loudness.channelWeight(4) == 1.41)
    }
}

@Suite("Gating — absolute and relative gates")
struct GatingTests {

    // 1. The relative gate drops the quiet span: −36 blocks fall below
    //    (energy-mean − 10 LU) ≈ −35.8, so only the −23 span integrates.
    @Test("20 s at −36 then 20 s at −23 → −23.0 ± 0.1 LUFS (gate drops the quiet span)")
    func relativeGateDropsQuietSpan() throws {
        var samples = sine(frequency: 997, dbfs: -36, seconds: 20, sampleRate: 48_000)
        samples += sine(frequency: 997, dbfs: -23, seconds: 20, sampleRate: 48_000)
        let integrated = try #require(Loudness.measure(stereo(samples, sampleRate: 48_000)).integratedLufs)
        #expect(abs(integrated - -23.0) <= 0.1)
    }

    // 2. Absolute gate: a −80 dBFS program never crosses −70 LUFS → integrated nil.
    //    Momentary is UNGATED by definition, so it still reads ≈ −80 (honest);
    //    true peak likewise.
    @Test("−80 dBFS program → nil integrated (below the −70 absolute gate)")
    func absoluteGateSilence() throws {
        let audio = stereo(sine(frequency: 997, dbfs: -80, seconds: 5, sampleRate: 48_000),
                           sampleRate: 48_000)
        let m = Loudness.measure(audio)
        #expect(m.integratedLufs == nil)
        #expect(abs(try #require(m.maxMomentaryLufs) - -80.0) <= 0.2)
        #expect(abs(try #require(m.truePeakDbtp) - -80.0) <= 0.1)
    }

    // 3. Digital silence: nothing to report at all — every field nil, and the
    //    wire encoding is an empty JSON object (no −0 dB, no −inf).
    @Test("digital silence → all fields nil, encodes as {}")
    func digitalSilence() throws {
        let zeros = [Float](repeating: 0, count: 5 * 48_000)
        let m = Loudness.measure(RenderedAudio(sampleRate: 48_000, channelData: [zeros, zeros]))
        #expect(m == LoudnessMeasurement())
        let json = String(decoding: try JSONEncoder().encode(m), as: UTF8.self)
        #expect(json == "{}")
    }
}

// MARK: - Momentary / short-term maxima

@Suite("Momentary and short-term maxima")
struct MomentaryShortTermTests {

    // 1. Stepped level: the loud half owns both maxima.
    @Test("5 s at −33 then 5 s at −23: both maxima read −23.0 ± 0.1")
    func steppedLevel() throws {
        var samples = sine(frequency: 997, dbfs: -33, seconds: 5, sampleRate: 48_000)
        samples += sine(frequency: 997, dbfs: -23, seconds: 5, sampleRate: 48_000)
        let m = Loudness.measure(stereo(samples, sampleRate: 48_000))
        #expect(abs(try #require(m.maxMomentaryLufs) - -23.0) <= 0.1)
        #expect(abs(try #require(m.maxShortTermLufs) - -23.0) <= 0.1)
    }

    // 2. A 1 s burst separates the two: a 400 ms block fits inside the burst
    //    (max momentary = burst level) but every 3 s window dilutes it.
    //    Analytic short-term: burst-relative window energy
    //    (1·E₋₂₃ + 2·E₋₄₃)/(3·E₋₂₃) = 0.34 → −23 + 10·log10(0.34) = −27.68.
    @Test("1 s burst at −23 in −43 bed: momentary −23.0 ± 0.1, short-term −27.7 ± 0.25")
    func burstSeparatesMaxima() throws {
        var samples = sine(frequency: 997, dbfs: -43, seconds: 4, sampleRate: 48_000)
        samples += sine(frequency: 997, dbfs: -23, seconds: 1, sampleRate: 48_000)
        samples += sine(frequency: 997, dbfs: -43, seconds: 4, sampleRate: 48_000)
        let m = Loudness.measure(stereo(samples, sampleRate: 48_000))
        #expect(abs(try #require(m.maxMomentaryLufs) - -23.0) <= 0.1)
        let expectedShortTerm = -23.0 + 10.0 * log10((1.0 + 2.0 * 0.01) / 3.0)
        #expect(abs(try #require(m.maxShortTermLufs) - expectedShortTerm) <= 0.25)
    }

    // 3. Shorter than 3 s: short-term has no window, momentary still reports.
    @Test("2 s program: momentary present, short-term nil")
    func tooShortForShortTerm() throws {
        let audio = stereo(sine(frequency: 997, dbfs: -23, seconds: 2, sampleRate: 48_000),
                           sampleRate: 48_000)
        let m = Loudness.measure(audio)
        #expect(m.maxMomentaryLufs != nil)
        #expect(m.maxShortTermLufs == nil)
    }
}

// MARK: - True peak (§3.3)

@Suite("True peak — 4× oversampled per Annex 2")
struct TruePeakTests {

    // 1. The EBU 3341 inter-sample case: fs/4 at 0 dBFS with 45° phase offset
    //    never samples the crest (sample peak −3.01 dBFS) but the true peak
    //    is 0 dBTP; the 4× grid lands exactly on 90°.
    @Test("fs/4 sine at 0 dBFS, 45° phase: sample peak −3.01 dBFS, true peak in (−0.4, +0.2) dBTP",
          arguments: [48_000.0, 44_100.0])
    func ebu3341InterSamplePeak(fs: Double) throws {
        let samples = sine(frequency: fs / 4, dbfs: 0, seconds: 1, sampleRate: fs,
                           phaseRadians: .pi / 4)
        let samplePeakDb = 20.0 * log10(Double(samples.map { abs($0) }.max()!))
        #expect(abs(samplePeakDb - -3.01) <= 0.01)

        let tp = try #require(Loudness.measure(stereo(samples, sampleRate: fs)).truePeakDbtp)
        #expect(tp > -0.4 && tp < 0.2)
    }

    // 2. Sanity: a mid-band full-scale sine (dense phase coverage) reads ≈ 0 dBTP.
    @Test("997 Hz at 0 dBFS reads ≈ 0 dBTP")
    func midBandFullScale() throws {
        let audio = stereo(sine(frequency: 997, dbfs: 0, seconds: 1, sampleRate: 48_000),
                           sampleRate: 48_000)
        let tp = try #require(Loudness.measure(audio).truePeakDbtp)
        #expect(abs(tp) <= 0.1)
    }

    // 3. Interpolator shape: 3 interpolation phases (phase 0 ≡ original
    //    samples), ≥ 12 taps each per spec, unity DC gain per phase.
    @Test("interpolator: 3 phases, ≥ 12 taps/phase, unity DC gain")
    func interpolatorShape() {
        let phases = Loudness.interpolatorPhases
        #expect(phases.count == 3)
        for taps in phases {
            #expect(taps.count >= 12)
            #expect(abs(taps.reduce(0, +) - 1.0) <= 1e-12)
        }
    }
}

// MARK: - RenderedAudio + applyGain

@Suite("RenderedAudio — applyGain and shape")
struct RenderedAudioTests {

    // 1. In-place values.
    @Test("applyGain scales every sample in place")
    func applyGainValues() {
        var audio = RenderedAudio(sampleRate: 48_000,
                                  channelData: [[1.0, -2.0], [0.5, 0.0]])
        audio.applyGain(linear: 0.5)
        #expect(audio.channelData == [[0.5, -1.0], [0.25, 0.0]])
        #expect(audio.frameCount == 2)
        #expect(audio.sampleRate == 48_000)
    }

    // 2. The normalization contract: a linear gain of G dB shifts integrated
    //    loudness by exactly G (± Float32 quantization slack).
    @Test("applyGain(−6 dB) shifts integrated loudness by −6.0 ± 0.05 LU")
    func applyGainShiftsLoudness() throws {
        var audio = stereo(sine(frequency: 997, dbfs: -23, seconds: 10, sampleRate: 48_000),
                           sampleRate: 48_000)
        let before = try #require(Loudness.measure(audio).integratedLufs)
        audio.applyGain(linear: Float(pow(10.0, -6.0 / 20.0)))
        let after = Loudness.measure(audio)
        #expect(abs(try #require(after.integratedLufs) - (before - 6.0)) <= 0.05)
        // True peak rides the same gain.
        #expect(abs(try #require(after.truePeakDbtp) - (-23.0 - 6.0)) <= 0.1)
    }
}

// MARK: - Determinism + wire shape

@Suite("Loudness — determinism and Codable wire shape")
struct LoudnessWireTests {

    // 1. Bit-identical across runs (pure Double pipeline, no threading).
    @Test("two measurements of the same buffer are identical")
    func determinism() {
        var samples = sine(frequency: 997, dbfs: -33, seconds: 3, sampleRate: 48_000)
        samples += sine(frequency: 997, dbfs: -23, seconds: 3, sampleRate: 48_000)
        let audio = stereo(samples, sampleRate: 48_000)
        #expect(Loudness.measure(audio) == Loudness.measure(audio))
    }

    // 2. The m20-a detached hop is a pure executor change: `measureDetached`
    //    must equal `measure` EXACTLY on the same buffer (the determinism pin
    //    above makes this exact equality, not tolerance). Varied multi-segment
    //    program (> 3 s, level steps, an inter-sample-peak segment) so every
    //    measurement field is non-nil and the equality is meaningful.
    @Test("measureDetached equals measure exactly on a varied program")
    func detachedHopEqualsSynchronous() async {
        var samples = sine(frequency: 997, dbfs: -33, seconds: 3, sampleRate: 48_000)
        samples += sine(frequency: 440, dbfs: -23, seconds: 3, sampleRate: 48_000)
        samples += sine(frequency: 12_000, dbfs: -6, seconds: 2, sampleRate: 48_000,
                        phaseRadians: .pi / 4)
        let audio = stereo(samples, sampleRate: 48_000)
        let synchronous = Loudness.measure(audio)
        let detached = await Loudness.measureDetached(audio)
        #expect(detached == synchronous)
        // The fixture exercises every field — nil == nil would be vacuous.
        #expect(synchronous.integratedLufs != nil)
        #expect(synchronous.truePeakDbtp != nil)
        #expect(synchronous.maxMomentaryLufs != nil)
        #expect(synchronous.maxShortTermLufs != nil)
    }

    // 3. The m20-h fused hop (applyGain + re-measure in ONE detached unit)
    //    must equal the synchronous sequence EXACTLY: byte-for-byte channel
    //    data (`==` on the arrays) AND an identical measurement (determinism
    //    makes both exact, not tolerance). Same varied 3-segment 8 s fixture
    //    idiom as the m20-a pin above so every measurement field is non-nil
    //    and the equality is meaningful.
    @Test("applyGainAndMeasureDetached equals synchronous applyGain + measure exactly")
    func gainHopEqualsSynchronous() async {
        var samples = sine(frequency: 997, dbfs: -33, seconds: 3, sampleRate: 48_000)
        samples += sine(frequency: 440, dbfs: -23, seconds: 3, sampleRate: 48_000)
        samples += sine(frequency: 12_000, dbfs: -6, seconds: 2, sampleRate: 48_000,
                        phaseRadians: .pi / 4)
        let gain = Float(pow(10.0, -3.5 / 20.0))

        // Synchronous reference: the pre-m20-h call-site sequence.
        var reference = stereo(samples, sampleRate: 48_000)
        reference.applyGain(linear: gain)
        let referenceMeasurement = Loudness.measure(reference)

        let hopped = await Loudness.applyGainAndMeasureDetached(
            stereo(samples, sampleRate: 48_000), linear: gain)
        #expect(hopped.audio.channelData == reference.channelData)
        #expect(hopped.audio.sampleRate == reference.sampleRate)
        #expect(hopped.measurement == referenceMeasurement)
        // The fixture exercises every field — nil == nil would be vacuous.
        #expect(referenceMeasurement.integratedLufs != nil)
        #expect(referenceMeasurement.truePeakDbtp != nil)
        #expect(referenceMeasurement.maxMomentaryLufs != nil)
        #expect(referenceMeasurement.maxShortTermLufs != nil)
    }

    // 4. The hop's ownership contract: `consume` hands the ONLY reference
    //    across the detached unit, so the in-place mutation never triggers a
    //    copy-on-write duplication — pinned by storage identity (the gained
    //    buffers live at the SAME base addresses the originals did). Distinct
    //    per-channel buffers on purpose: the shared-buffer `stereo` fixture
    //    aliases both channels to one storage, which forces one legitimate
    //    CoW split inside applyGain itself.
    @Test("the gain hop mutates the consumed buffer in place (storage identity held)")
    func gainHopKeepsStorageUnique() async {
        let audio = RenderedAudio(
            sampleRate: 48_000,
            channelData: [sine(frequency: 997, dbfs: -23, seconds: 2, sampleRate: 48_000),
                          sine(frequency: 440, dbfs: -23, seconds: 2, sampleRate: 48_000)])
        let before = audio.channelData.map { channel in
            channel.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
        let hopped = await Loudness.applyGainAndMeasureDetached(consume audio, linear: 0.5)
        let after = hopped.audio.channelData.map { channel in
            channel.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        }
        #expect(after == before)
        #expect(before.allSatisfy { $0 != 0 })  // anti-vacuity: real storage
    }

    // 5. Codable round-trip preserves every field (this struct IS the wire shape).
    @Test("LoudnessMeasurement round-trips through JSON")
    func codableRoundTrip() throws {
        let m = LoudnessMeasurement(integratedLufs: -23.0, truePeakDbtp: -1.2,
                                    maxMomentaryLufs: -20.5, maxShortTermLufs: -21.75)
        let decoded = try JSONDecoder().decode(LoudnessMeasurement.self,
                                               from: JSONEncoder().encode(m))
        #expect(decoded == m)
    }

    // 6. Degenerate inputs never crash and report nothing.
    @Test("empty buffers → all-nil measurement")
    func emptyBuffers() {
        #expect(Loudness.measure(RenderedAudio(sampleRate: 48_000, channelData: []))
                == LoudnessMeasurement())
        #expect(Loudness.measure(RenderedAudio(sampleRate: 48_000, channelData: [[], []]))
                == LoudnessMeasurement())
    }
}
