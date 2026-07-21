import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m22-f delay tempo sync — the engine half: the control-plane recompute on
/// tempo change (the roadmap gate: real `AudioEngine`, real intake seams,
/// observed through the resolved-descriptor test seams), the division→ms
/// truth through the REAL delay DSP (exact-sample echo offsets, the FXPack2
/// convention), and the offline bounce deriving from the render-start tempo.
@MainActor
@Suite("Delay tempo sync — engine control plane & DSP truth", .serialized)
struct DelayTempoSyncEngineTests {
    private static let sampleRate = 48_000.0

    private func syncedDelayTrack() -> Track {
        Track(name: "Echo", kind: .audio,
              effects: [EffectDescriptor(
                  kind: .delay,
                  delay: DelayParams(timeMs: 350, feedback: 0, mix: 1,
                                     sync: true, division: .quarter))])
    }

    // MARK: - The control-plane recompute (roadmap gate)

    @Test("a tempo change recomputes a synced delay's effective time on the track chain")
    func tempoChangeRecomputesTrackDelay() {
        let engine = AudioEngine()
        engine.tracksDidChange([syncedDelayTrack()])

        // Intake resolve at the default 120 BPM: 1/4 → 500 ms; the stored
        // 350 ms fallback is what the MODEL keeps — the engine's copy is the
        // resolved render truth.
        #expect(engine.lastTracksForTesting[0].effects[0].delay?.timeMs == 500)

        // The store's tempo push (applyTempoChange → engine.setTempo).
        var transport = TransportState()
        transport.tempoBPM = 90
        engine.setTempo(transport)
        let at90 = engine.lastTracksForTesting[0].effects[0].delay?.timeMs ?? 0
        #expect(abs(at90 - 2_000.0 / 3) < 1e-9)

        // And back — the resolve is idempotent under repeated recompute.
        transport.tempoBPM = 120
        engine.setTempo(transport)
        #expect(engine.lastTracksForTesting[0].effects[0].delay?.timeMs == 500)
        // sync/division ride in the engine copy (what makes re-resolve work).
        #expect(engine.lastTracksForTesting[0].effects[0].delay?.sync == true)
        #expect(engine.lastTracksForTesting[0].effects[0].delay?.division == .quarter)
    }

    @Test("the master chain recomputes too, through the same funnel")
    func tempoChangeRecomputesMasterDelay() {
        let engine = AudioEngine()
        engine.masterEffectsChanged([EffectDescriptor(
            kind: .delay,
            delay: DelayParams(timeMs: 350, feedback: 0, mix: 1,
                               sync: true, division: .eighthDotted))])
        // 1/8d @ 120 = 375 ms.
        #expect(engine.lastMasterEffectsForTesting[0].delay?.timeMs == 375)

        var transport = TransportState()
        transport.tempoBPM = 90
        engine.setTempo(transport)
        // 1/8d @ 90 = 0.75 × 60000 / 90 = 500 ms.
        #expect(engine.lastMasterEffectsForTesting[0].delay?.timeMs == 500)
    }

    @Test("a free-running delay never moves on tempo changes (the unsync fallback)")
    func freeRunningDelayIgnoresTempo() {
        let engine = AudioEngine()
        var track = syncedDelayTrack()
        track.effects[0].delay = DelayParams(timeMs: 350)  // sync absent = legacy
        engine.tracksDidChange([track])
        #expect(engine.lastTracksForTesting[0].effects[0].delay?.timeMs == 350)
        var transport = TransportState()
        transport.tempoBPM = 90
        engine.setTempo(transport)
        #expect(engine.lastTracksForTesting[0].effects[0].delay?.timeMs == 350)
    }

    // MARK: - DSP truth (the render path hears the derived time)

    /// Runs `channels` through `effect` in 512-frame quanta (the FXPack2
    /// helper, locally).
    private func processChunked(_ effect: any EffectRendering,
                                channels: [[Float]], chunk: Int = 512) throws -> [[Float]] {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(channels.count)))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
        var output = channels.map { _ in [Float]() }
        let total = channels[0].count
        var offset = 0
        while offset < total {
            let frames = min(chunk, total - offset)
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try #require(buffer.floatChannelData)
            for channel in 0..<channels.count {
                for frame in 0..<frames {
                    data[channel][frame] = channels[channel][offset + frame]
                }
            }
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frames)
            for channel in 0..<channels.count {
                output[channel].append(contentsOf:
                    UnsafeBufferPointer(start: data[channel], count: frames))
            }
            offset += frames
        }
        return output
    }

    @Test("the resolved params land the echo at the division's exact sample offset, per tempo")
    func resolvedParamsMoveTheEcho() throws {
        let descriptor = syncedDelayTrack().effects[0]
        // 1/4 @ 120 = 500 ms → exactly 24 000 samples at 48 kHz.
        let at120 = DelayTempoSync.resolved(descriptor, tempoBPM: 120).resolvedDelay
        let delay = DelayEffect(params: at120)
        delay.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        var dry = [Float](repeating: 0, count: 26_000)
        dry[0] = 1
        var wet = try processChunked(delay, channels: [dry, dry])
        var hits = wet[0].indices.filter { wet[0][$0] != 0 }
        print("[measured] synced delay @120: echo at \(hits) (expected [24000])")
        #expect(hits == [24_000])
        #expect(wet[0][24_000] == 1)

        // The live recompute path: apply() the re-resolved params (what the
        // engine's parameter pass publishes after setTempo), reset, re-feed.
        // 1/4 @ 90 = 666.66… ms → round(0.66… × 48 000) = 32 000 samples.
        let at90 = DelayTempoSync.resolved(descriptor, tempoBPM: 90).resolvedDelay
        delay.apply(params: at90)
        delay.reset()
        dry = [Float](repeating: 0, count: 34_000)
        dry[0] = 1
        wet = try processChunked(delay, channels: [dry, dry])
        hits = wet[0].indices.filter { wet[0][$0] != 0 }
        print("[measured] synced delay @90: echo at \(hits) (expected [32000])")
        #expect(hits == [32_000])
        #expect(wet[0][32_000] == 1)
    }

    // MARK: - Offline bounce truth

    /// Writes a stereo Float32 WAV whose frame 0 is a unit impulse.
    private func writeImpulseWAV(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("delay-sync-impulse-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: Self.sampleRate, channels: 2,
                                                interleaved: false))
        let frames = Int(seconds * Self.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        let channels = try #require(buffer.floatChannelData)
        channels[0][0] = 1
        channels[1][0] = 1
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
        return url
    }

    @Test("an offline bounce derives the synced time from the render-start tempo")
    func offlineBounceUsesRenderTempo() throws {
        let impulse = try writeImpulseWAV(seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: impulse) }
        var track = syncedDelayTrack()
        track.clips = [Clip(name: "i", startBeat: 0, lengthBeats: 4, audioFileURL: impulse)]

        func echoFrame(atBPM bpm: Double) throws -> Int? {
            let audio = try OfflineRenderer().render(
                tracks: [track], tempoMap: TempoMap(constantBPM: bpm),
                durationSeconds: 1.0)
            return audio.channelData[0].firstIndex { abs($0) > 0.25 }
        }
        // mix 1 zeroes the dry impulse, so the FIRST audible frame is the
        // echo itself: 1/4 @ 120 = 500 ms → frame 24 000; @ 90 → 32 000.
        let echo120 = try echoFrame(atBPM: 120)
        let echo90 = try echoFrame(atBPM: 90)
        print("[measured] offline synced delay echoes: @120 \(String(describing: echo120)) "
              + "(expected 24000), @90 \(String(describing: echo90)) (expected 32000)")
        #expect(echo120 == 24_000)
        #expect(echo90 == 32_000)
    }
}
