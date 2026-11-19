import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// Mixer-parameter proof for M1: track volume/pan/mute/solo and the master
/// volume all render offline through the same PlaybackGraph the live engine
/// uses, assertion-checked against the 1 kHz amp-0.5 cosine fixture at 48 kHz.
/// Steady-window baseline RMS R = 0.5/√2 ≈ 0.3536.
@MainActor
@Suite("Mixer parameters — offline render", .serialized)
struct MixerRenderTests {
    /// Steady-state window: clip starts at beat 0, so frames 12k–36k sit well
    /// inside the tone with margin on both sides of the 1.0 s render.
    private static let window = 12_000..<36_000
    /// amp 0.5 / √2.
    private static let baselineRMS: Float = 0.3536

    private func track(clip url: URL, volume: Double = 1, pan: Double = 0,
                       isMuted: Bool = false, isSoloed: Bool = false) -> Track {
        Track(name: "T", kind: .audio, volume: volume, pan: pan,
              isMuted: isMuted, isSoloed: isSoloed,
              clips: [Clip(name: "clip", startBeat: 0, lengthBeats: 4, audioFileURL: url)])
    }

    // a.
    @Test("track volume 0.5 halves the rendered RMS")
    func trackVolumeHalvesRMS() throws {
        let fixtures = try TestSignals.fixtures()
        let audio = try OfflineRenderer().render(
            tracks: [track(clip: fixtures.cos1k48, volume: 0.5)],
            tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 1.0
        )
        let expected = Self.baselineRMS / 2
        for channel in audio.channelData {
            let rms = TestSignals.rms(channel, in: Self.window)
            print("[measured] mixer track volume 0.5 RMS: \(rms) (expected \(expected) ± 2%)")
            #expect(abs(rms - expected) < 0.02 * expected)
        }
    }

    // b.
    @Test("muted track renders exact silence")
    func mutedTrackIsSilent() throws {
        let fixtures = try TestSignals.fixtures()
        let audio = try OfflineRenderer().render(
            tracks: [track(clip: fixtures.cos1k48, isMuted: true)],
            tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 1.0
        )
        for channel in audio.channelData {
            let peak = TestSignals.peak(channel, in: 0..<channel.count)
            print("[measured] mixer muted-track peak: \(peak)")
            #expect(peak < 1e-6)
        }
    }

    // c.
    @Test("solo keeps the soloed track and removes the other's contribution")
    func soloIsolatesTrack() throws {
        let fixtures = try TestSignals.fixtures()
        // The non-soloed track carries the LOUDER amp-0.5 tone: any leak into
        // the solo mix would push the RMS visibly above the solo-only value.
        let soloed = track(clip: fixtures.cos1k48Quarter, isSoloed: true)
        let other = track(clip: fixtures.cos1k48)

        let soloMix = try OfflineRenderer().render(
            tracks: [soloed, other], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 1.0
        )
        let soloAlone = try OfflineRenderer().render(
            tracks: [soloed], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 1.0
        )

        let mixRMS = TestSignals.rms(soloMix.channelData[0], in: Self.window)
        let aloneRMS = TestSignals.rms(soloAlone.channelData[0], in: Self.window)
        print("[measured] mixer solo: two-track solo mix RMS \(mixRMS), "
              + "soloed-track-alone RMS \(aloneRMS) (must match ± 2%)")
        // Soloed track is audible (amp 0.25 → ≈ 0.177)…
        #expect(mixRMS > 0.1)
        // …and the mix equals the soloed track alone: the amp-0.5 neighbor
        // contributes nothing.
        #expect(abs(mixRMS - aloneRMS) < 0.02 * aloneRMS)
    }

    // d.
    @Test("pan hard left routes signal to the left channel only")
    func panHardLeft() throws {
        let fixtures = try TestSignals.fixtures()
        let audio = try OfflineRenderer().render(
            tracks: [track(clip: fixtures.cos1k48, pan: -1)],
            tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 1.0
        )
        let leftRMS = TestSignals.rms(audio.channelData[0], in: Self.window)
        let rightRMS = TestSignals.rms(audio.channelData[1], in: Self.window)
        // AVAudioMixerNode's pan law is not ours to assert exactly —
        // directional assertions only, with the measured values logged.
        print("[measured] mixer pan -1: left RMS \(leftRMS), right RMS \(rightRMS)")
        #expect(leftRMS > 0.2)
        #expect(rightRMS < 0.02)
    }

    // f.
    /// ⚠️ PINS A DOCUMENTED LIMITATION, NOT A DESIRED BEHAVIOUR (`p2-sing-x9-f2`,
    /// measured 2026-10-07). The SAME pan value is NOT the same loudness: a STATIC
    /// pan (`Track.pan` → `AVAudioMixerNode.pan`) and an AUTOMATED / MODULATED pan
    /// (our own equal-power stage with the node pinned to centre) follow different
    /// laws. Measured per-channel RMS against the p=0 render shows the static
    /// side leaves the loud channel at ~unity while the automated side lifts it
    /// ~+3 dB (equal-power, unity centre), so a pan lane flat at hard-right is
    /// ~3 dB louder on the right than the same static pan.
    ///
    /// It is pinned rather than fixed because unifying the laws changes the sound
    /// of every saved project that has a pan lane or pan route. **If the pan law
    /// is ever deliberately unified, this test turns red ON PURPOSE: re-measure,
    /// rewrite the expected relations, and re-listen.** Tolerances were
    /// pre-registered (`w8/PANM/PREDICTIONS.md`) before the first run.
    ///
    /// m39-panlaw-new (2026-10-11, the user's pick "One rule for new songs
    /// only"): this pin now holds for SAVED songs — the song's pan rule
    /// `PanLaw.balance`, which is what a bare `OfflineRenderer()` renders. A NEW
    /// song (`PanLaw.equalPower`) pans the knob with the automation rule, so its
    /// knob and lane agree sample for sample: `PanLawRenderTests`.
    @Test("⚠️ p2-sing-x9-f2: static pan and automated/modulated pan follow different laws (pins a limitation)")
    func staticVersusAutomatedPanLaw() throws {
        let fixtures = try TestSignals.fixtures()
        let clip = Clip(name: "clip", startBeat: 0, lengthBeats: 8, audioFileURL: fixtures.cos1k48)
        func dB(_ x: Float) -> Double { 20 * log10(max(Double(x), 1e-9)) }

        func render(_ way: String, _ p: Double) throws -> (l: Double, r: Double) {
            var t = Track(name: "T", kind: .audio, pan: way == "S" ? p : 0, clips: [clip])
            if way == "A" {
                t.automation = [AutomationLane(target: .pan, points: [
                    AutomationPoint(beat: 0, value: p), AutomationPoint(beat: 8, value: p)])]
            } else if way == "M" {
                let macro = ModulationSource(kind: .macro, params: .macro(MacroSourceParams(value: p)))
                t.modulationSources = [macro]
                t.modulationRoutes = [ModulationRoute(sourceID: macro.id, target: .pan, depth: 1)]
            }
            let audio = try OfflineRenderer().render(
                tracks: [t], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 1.0)
            return (dB(TestSignals.rms(audio.channelData[0], in: Self.window)),
                    dB(TestSignals.rms(audio.channelData[1], in: Self.window)))
        }

        var table: [String: [Double: (l: Double, r: Double)]] = [:]
        for way in ["S", "A", "M"] {
            for p in [0.0, 0.5, 1.0] {
                // p = 0 on the macro way is value 0 (sum 0): the route still pins the node to centre.
                table[way, default: [:]][p] = try render(way, p)
            }
        }
        for way in ["S", "A", "M"] {
            for p in [0.0, 0.5, 1.0] {
                let v = table[way]![p]!
                let power = 10 * log10(pow(10, v.l / 10) + pow(10, v.r / 10))
                print("[measured] pan law \(way) p=\(p): L \(v.l) dB, R \(v.r) dB, total \(power) dB")
            }
        }
        let ref = table["S"]![0]!
        // CONTROL: centre is unity in both laws — every way agrees at p = 0 within 0.1 dB.
        for way in ["A", "M"] {
            let c = table[way]![0]!
            #expect(abs(c.l - ref.l) < 0.1 && abs(c.r - ref.r) < 0.1, "p=0 control, way \(way)")
        }
        #expect(ref.r > -12, "the render is real signal, not silence")
        // STATIC: the loud channel stays ~unity, the far channel is gone.
        let s1 = table["S"]![1]!
        #expect(abs(s1.r - ref.r) < 0.5, "static hard-right R vs centre: \(s1.r - ref.r) dB")
        #expect(s1.l - ref.l < -40)
        // STATIC half-way: the far channel falls LINEARLY (gain 1-p = -6.02 dB at p=0.5), the near one stays at unity.
        let sHalf = table["S"]![0.5]!
        #expect(abs(sHalf.r - ref.r) < 0.5 && abs((sHalf.l - ref.l) + 6.02) < 0.5,
                "static p=0.5: L \(sHalf.l - ref.l) dB, R \(sHalf.r - ref.r) dB")
        // AUTOMATED and MODULATED: equal-power, the loud channel is lifted ~+3 dB.
        for way in ["A", "M"] {
            let v = table[way]![1]!
            #expect(abs((v.r - ref.r) - 3.01) < 0.5, "\(way) hard-right R vs centre: \(v.r - ref.r) dB")
            #expect(v.l - ref.l < -40)
            let h = table[way]![0.5]!
            #expect(abs((h.r - ref.r) - 2.32) < 0.5, "\(way) p=0.5 R: \(h.r - ref.r) dB")
            #expect(abs((h.l - ref.l) + 5.34) < 0.5, "\(way) p=0.5 L: \(h.l - ref.l) dB")
        }
        // The spike's claim: same pan value, automated minus static, on the loud channel.
        let delta = table["A"]![1]!.r - s1.r
        print("[measured] pan law: automated minus static at hard-right, R channel = \(delta) dB")
        #expect(delta > 2.5 && delta < 3.5)
        // Modulation and automation share one law.
        #expect(abs(table["M"]![1]!.r - table["A"]![1]!.r) < 0.2)
    }

    // e.
    @Test("master volume 0.5 halves the mix RMS; 0 renders exact silence")
    func masterVolumeScalesMix() throws {
        let fixtures = try TestSignals.fixtures()
        let tracks = [track(clip: fixtures.cos1k48)]

        let half = try OfflineRenderer().render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120), fromBeat: 0,
            durationSeconds: 1.0, masterVolume: 0.5
        )
        let expected = Self.baselineRMS / 2
        for channel in half.channelData {
            let rms = TestSignals.rms(channel, in: Self.window)
            print("[measured] mixer master volume 0.5 RMS: \(rms) (expected \(expected) ± 2%)")
            #expect(abs(rms - expected) < 0.02 * expected)
        }

        let zero = try OfflineRenderer().render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120), fromBeat: 0,
            durationSeconds: 1.0, masterVolume: 0
        )
        for channel in zero.channelData {
            let peak = TestSignals.peak(channel, in: 0..<channel.count)
            print("[measured] mixer master volume 0 peak: \(peak)")
            #expect(peak < 1e-6)
        }
    }
}
