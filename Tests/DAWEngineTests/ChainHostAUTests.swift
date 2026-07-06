import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// THE M4 (ii) gating spike: `AUAudioUnit.registerSubclass` +
/// SYNCHRONOUS `AVAudioUnitEffect(audioComponentDescription:)` instantiation
/// must work from this bare-SPM (Command Line Tools only) process, the node
/// must attach to a manual-rendering engine, and an empty chain must be
/// bit-exact pull-through. Everything for audio/bus strip inserts depends on
/// this; the fallback ladder (async instantiate → instrument-only chains) is
/// specified in the M4 (ii) spec §8.
@MainActor
@Suite("ChainHostAU — in-process registered insert host", .serialized)
struct ChainHostAUTests {
    /// player → [chainHost?] → mainMixer at 48 kHz, manual rendering; pulls
    /// `frames` frames and returns deinterleaved output.
    private func renderThroughGraph(withChainHost: Bool, frames: Int) throws -> [[Float]] {
        let fixtures = try TestSignals.fixtures()
        let engine = AVAudioEngine()
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let file = try AVAudioFile(forReading: fixtures.cos1k48)

        if withChainHost {
            let host = ChainHostAU.makeChainHostNode()
            // The sync path must hand back OUR in-process subclass (that is
            // what makes the processor reachable and the walk render-safe).
            #expect(host.auAudioUnit is ChainHostAU)
            #expect(ChainHostAU.chainProcessor(of: host) != nil)
            engine.attach(host)
            engine.connect(player, to: host, format: file.processingFormat)
            engine.connect(host, to: engine.mainMixerNode, format: file.processingFormat)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        }

        try engine.start()
        player.scheduleFile(file, at: nil)
        player.play(at: nil)

        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var channelData: [[Float]] = [[], []]
        var rendered = 0
        while rendered < frames {
            let request = AVAudioFrameCount(min(frames - rendered, 4_096))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            let source = try #require(buffer.floatChannelData)
            let count = Int(buffer.frameLength)
            for channel in 0..<2 {
                channelData[channel].append(contentsOf:
                    UnsafeBufferPointer(start: source[channel], count: count))
            }
            rendered += count
        }
        engine.stop()
        return channelData
    }

    @Test("registerSubclass + sync AVAudioUnitEffect init renders bit-exact passthrough offline")
    func chainHostRegistersAndRendersPassthroughOffline() throws {
        let reference = try renderThroughGraph(withChainHost: false, frames: 48_000)
        let hosted = try renderThroughGraph(withChainHost: true, frames: 48_000)

        // Real signal (not silence-vs-silence): amp-0.5 cosine.
        let referencePeak = TestSignals.peak(reference[0], in: 0..<48_000)
        #expect(referencePeak > 0.45)

        var maxDiff: Float = 0
        for channel in 0..<2 {
            for frame in 0..<48_000 {
                maxDiff = max(maxDiff, abs(hosted[channel][frame] - reference[channel][frame]))
            }
        }
        print("[measured] ChainHostAU empty-chain passthrough: "
              + "max |hosted − reference| = \(maxDiff), reference peak \(referencePeak)")
        #expect(maxDiff == 0)
    }

    @Test("chain host survives engine start/stop cycles (render-resource realloc)")
    func chainHostSurvivesEngineStartStopCycles() throws {
        let fixtures = try TestSignals.fixtures()
        let engine = AVAudioEngine()
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let file = try AVAudioFile(forReading: fixtures.cos1k48)
        let host = ChainHostAU.makeChainHostNode()
        engine.attach(host)
        engine.connect(player, to: host, format: file.processingFormat)
        engine.connect(host, to: engine.mainMixerNode, format: file.processingFormat)

        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        for cycle in 0..<3 {
            try engine.start()  // re-allocates the AU's render resources
            player.scheduleFile(file, at: nil)
            player.play(at: nil)
            var peak: Float = 0
            for _ in 0..<6 {  // 24 576 frames ≈ 0.5 s
                let status = try engine.renderOffline(4_096, to: buffer)
                try #require(status == .success)
                let source = try #require(buffer.floatChannelData)
                for channel in 0..<2 {
                    for frame in 0..<Int(buffer.frameLength) {
                        peak = max(peak, abs(source[channel][frame]))
                    }
                }
            }
            print("[measured] ChainHostAU start/stop cycle \(cycle): peak \(peak)")
            #expect(abs(peak - 0.5) < 0.001)  // tone flows through every cycle
            player.stop()
            engine.stop()  // deallocates render resources
        }
    }
}
