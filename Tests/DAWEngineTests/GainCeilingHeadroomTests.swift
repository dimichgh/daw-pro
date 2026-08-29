import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m27-c — the `gain` insert's ceiling, raised 4 (+12.04 dB) → 16 (+24.08 dB)
/// so ONE insert lifts quiet General-MIDI-sourced material to a streaming
/// level. The defect: reaching −14 LUFS took TWO chained gain inserts, which
/// the reporter correctly read as a workaround.
///
/// ⭐ THE GATE IS AN AUDIO MEASUREMENT, NOT A SETTER'S RETURN. Every claim
/// here is a rendered level measured with the same BS.1770-4 machinery
/// `render_measure_loudness` serves, and the OLD ceiling is carried as a
/// live positive control in the same test — if 4.0 ever reaches the target
/// too, the measurement is not measuring what it says it is.
///
/// SOURCE CHOICE. The program is deterministic broadband noise from a fixed
/// LCG, NOT a sine: this suite's own history (`bc9bde9`, "the sine that hid
/// it") is a case of a single tone flattering a level measurement, and K
/// weighting is only meaningfully exercised by something with bandwidth. The
/// level is placed at the reported dogfood anchor (−28 LUFS unity), and the
/// GM renders that justified the ceiling are deliberately NOT the gate —
/// AUSampler's absolute output level is an OS property, not ours, so it may
/// justify a number but must not pin CI to one. Those measurements live in
/// `GainParams.gainRange`'s doc comment.
@MainActor
@Suite("Gain insert headroom — the −14 LUFS reach (m27-c)", .serialized)
struct GainCeilingHeadroomTests {
    private static let sampleRate = 48_000.0
    private static let streamingTargetLufs = -14.0
    /// The ceiling this item replaced. Kept as a NAMED constant so the
    /// positive control cannot silently drift onto the new value.
    private static let oldCeiling = 4.0

    /// Amplitude placing the noise program at the reported unity anchor
    /// (−28.05 LUFS). MEASURED, then pinned by `anchorIsInTheReportedRegime`
    /// — if this constant or the loudness path drifts, that test fails rather
    /// than the whole file quietly measuring a different problem.
    private static let anchorAmplitude: Float = 0.03375

    // MARK: - Fixtures

    /// Deterministic broadband noise, identical in both channels. Fixed-seed
    /// LCG — no `Float.random`, so the rendered level is reproducible across
    /// machines and runs.
    private func writeNoiseWAV(amplitude: Float, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m27c-noise-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        for frame in 0..<frames {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(Double(state >> 40) / Double(1 << 24)) * 2 - 1  // −1…1
            let sample = unit * amplitude
            data[0][frame] = sample
            data[1][frame] = sample
        }
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    private func noiseTrack(url: URL) -> Track {
        Track(name: "GM-quiet stand-in", kind: .audio,
              clips: [Clip(name: "c", startBeat: 0, lengthBeats: 32, audioFileURL: url)])
    }

    /// Renders 10 s of the program through `masterEffects` and measures it.
    /// The gain insert always sits at INDEX 0 of the MASTER chain — the exact
    /// placement m31-d measured as the one that works (a normalizing bounce
    /// applies its own gain AFTER the whole chain, so makeup taken anywhere
    /// later cannot be what lifts the mix).
    private func measure(url: URL, masterEffects: [EffectDescriptor] = [])
        throws -> LoudnessMeasurement {
        let audio = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: [noiseTrack(url: url)], tempoMap: TempoMap(constantBPM: 120),
            durationSeconds: 10.0, masterEffects: masterEffects)
        return Loudness.measure(audio)
    }

    private func gainInsert(_ linear: Double) -> EffectDescriptor {
        EffectDescriptor(kind: .gain, gain: GainParams(gainLinear: linear))
    }

    // MARK: - 1. The premise

    @Test("the unity program sits at the reported GM anchor, and needs more than the OLD ceiling")
    func anchorIsInTheReportedRegime() throws {
        let url = try writeNoiseWAV(amplitude: Self.anchorAmplitude, frames: 480_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let unity = try measure(url: url)
        let l0 = try #require(unity.integratedLufs)
        let needDb = Self.streamingTargetLufs - l0
        print(String(format:
            "[measured] unity program %.2f LUFS (reported anchor -28.05) · needs %+.2f dB "
            + "to reach %.1f · old ceiling gives +12.04 dB · new ceiling gives +24.08 dB",
            l0, needDb, Self.streamingTargetLufs))

        // The premise: this really is the reported regime, not some other one.
        #expect(l0 > -30 && l0 < -26)
        // …and it really does out-reach the ceiling this item replaced.
        #expect(needDb > 20 * log10(Self.oldCeiling))
        // …while landing inside the new one. Both halves, or the claim
        // "one insert now suffices" is not what was measured.
        #expect(needDb <= 20 * log10(GainParams.gainRange.upperBound))
    }

    // MARK: - 2. The before/after, in one test with its own positive control

    @Test("ONE gain insert reaches -14 LUFS at the new ceiling — and FALLS SHORT at the old one")
    func oneInsertReachesStreamingLevelOnlyAboveTheOldCeiling() throws {
        let url = try writeNoiseWAV(amplitude: Self.anchorAmplitude, frames: 480_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let l0 = try #require(try measure(url: url).integratedLufs)
        let needLinear = pow(10, (Self.streamingTargetLufs - l0) / 20)

        // POSITIVE CONTROL — the old ceiling, on the identical program.
        // A value of 4.0 was the MOST a single insert could hold before this
        // item; if this ever reaches the target, the gate is broken.
        let atOldCeiling = try #require(
            try measure(url: url, masterEffects: [gainInsert(Self.oldCeiling)]).integratedLufs)

        // The fix — ONE insert, holding the value the program actually needs.
        // Under the old range this would have clamped to 4.0; it does not now.
        let stored = GainParams(gainLinear: needLinear).gainLinear
        let atNewCeiling = try #require(
            try measure(url: url, masterEffects: [gainInsert(needLinear)]).integratedLufs)

        print(String(format:
            "[measured] one insert: unity %.2f LUFS → old ceiling 4.000 gives %.2f LUFS "
            + "(SHORT of %.1f by %.2f dB) → needed %.3f (stored %.3f, unclamped) gives "
            + "%.2f LUFS",
            l0, atOldCeiling, Self.streamingTargetLufs,
            Self.streamingTargetLufs - atOldCeiling, needLinear, stored, atNewCeiling))

        // The requested value survived — the whole point of raising the range.
        #expect(stored == needLinear)
        #expect(needLinear > Self.oldCeiling)
        // The old ceiling FALLS SHORT, measured, not assumed.
        #expect(atOldCeiling < Self.streamingTargetLufs - 1.0)
        // ONE insert now lands on target.
        #expect(abs(atNewCeiling - Self.streamingTargetLufs) < 0.25)
    }

    @Test("one insert == the two chained inserts it replaces")
    func oneInsertMatchesTheTwoItReplaces() throws {
        let url = try writeNoiseWAV(amplitude: Self.anchorAmplitude, frames: 480_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let l0 = try #require(try measure(url: url).integratedLufs)
        let needLinear = pow(10, (Self.streamingTargetLufs - l0) / 20)

        // The workaround, verbatim in shape: insert #1 maxed at the old
        // ceiling, insert #2 carrying the remainder (the dogfood run's
        // 4.000 then 1.386).
        let chained = try #require(try measure(
            url: url,
            masterEffects: [gainInsert(Self.oldCeiling),
                            gainInsert(needLinear / Self.oldCeiling)]).integratedLufs)
        let single = try #require(
            try measure(url: url, masterEffects: [gainInsert(needLinear)]).integratedLufs)

        print(String(format:
            "[measured] two chained inserts (%.3f × %.3f) %.2f LUFS vs ONE insert (%.3f) "
            + "%.2f LUFS · difference %.4f dB",
            Self.oldCeiling, needLinear / Self.oldCeiling, chained, needLinear, single,
            abs(single - chained)))

        // Same destination, one stage instead of two.
        #expect(abs(single - chained) < 0.05)
    }

    // MARK: - 3. Known-signal gain, and the guards a DSP unit owes

    @Test("the new ceiling multiplies EXACTLY +24.08 dB and stays finite")
    func newCeilingIsExactAndFinite() throws {
        // Quiet enough that 16× cannot reach full scale (0.03 × 16 = 0.48),
        // so this measures the gain and nothing else — no clipping, no
        // limiting, no reconstruction overshoot.
        let url = try writeNoiseWAV(amplitude: 0.03, frames: 480_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let ceiling = GainParams.gainRange.upperBound
        let unity = try measure(url: url)
        let boosted = try measure(url: url, masterEffects: [gainInsert(ceiling)])

        let lufsDelta = try #require(boosted.integratedLufs) - #require(unity.integratedLufs)
        let peakDelta = try #require(boosted.truePeakDbtp) - #require(unity.truePeakDbtp)
        let analytic = 20 * log10(ceiling)
        print(String(format:
            "[measured] ceiling %.0f: LUFS delta %+.4f dB · true-peak delta %+.4f dB · "
            + "analytic %+.4f dB", ceiling, lufsDelta, peakDelta, analytic))

        #expect(abs(lufsDelta - analytic) < 0.02)
        #expect(abs(peakDelta - analytic) < 0.02)

        // Denormal/NaN guard: a memoryless multiply cannot blow up, and this
        // is the assertion that says so rather than assuming it.
        let audio = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: [noiseTrack(url: url)], tempoMap: TempoMap(constantBPM: 120),
            durationSeconds: 2.0, masterEffects: [gainInsert(ceiling)])
        var nonFinite = 0
        var peak: Float = 0
        for channel in audio.channelData {
            for sample in channel {
                if !sample.isFinite { nonFinite += 1 }
                peak = max(peak, abs(sample))
            }
        }
        print("[measured] non-finite samples at ceiling: \(nonFinite); peak \(peak)")
        #expect(nonFinite == 0)
        #expect(peak > 0.4 && peak < 1.0)
    }

    // MARK: - 4. The range itself

    @Test("the ceiling is 16, unity/old values still round-trip, and RAISING kept them valid")
    func rangeMovedUpAndOldValuesSurvive() throws {
        #expect(GainParams.gainRange == 0...16)
        #expect(abs(20 * log10(GainParams.gainRange.upperBound) - 24.0824) < 0.001)

        // Raising a ceiling cannot invalidate a stored value; every project
        // written against 0…4 still decodes to exactly what it stored. (The
        // reverse — lowering — would silently re-clamp, through this same init.)
        for stored in [0.0, 0.5, 1.0, 2.0, 3.5, 4.0] {
            #expect(GainParams(gainLinear: stored).gainLinear == stored)
        }
        // The values the old range could not hold now survive verbatim.
        for stored in [4.0001, 5.544, 11.868, 16.0] {
            #expect(GainParams(gainLinear: stored).gainLinear == stored)
        }
        // The clamp still exists — it just moved.
        #expect(GainParams(gainLinear: 20).gainLinear == 16)
        #expect(GainParams(gainLinear: -3).gainLinear == 0)

        // Decoding routes through the clamping init, so a hand-edited project
        // cannot carry more than the ceiling either.
        let json = Data(#"{"gainLinear": 99}"#.utf8)
        let decoded = try JSONDecoder().decode(GainParams.self, from: json)
        #expect(decoded.gainLinear == 16)
    }
}
