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
