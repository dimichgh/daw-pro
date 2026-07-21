import Foundation
import Testing
import DAWCore
@testable import DAWEngine

/// Headless tests for the engine-side live-loudness wrapper (m22-c):
/// pointer-shaped feeding (the tap's `floatChannelData` shape), the atomic
/// reset/generation handshake, and equivalence with the DAWCore stream —
/// no audio I/O, no engine, no taps. The DSP itself is proven in
/// DAWCoreTests (LRA fixtures + the offline-convergence gate).
@Suite("Live loudness analyzer — engine wrapper (m22-c)")
struct LiveLoudnessAnalyzerTests {

    private static let sampleRate = 48_000.0

    private static func sine(
        frequency: Double, amplitude: Float, seconds: Double
    ) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { frame in
            amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
    }

    /// Feed deinterleaved channels through the tap-shaped pointer entry
    /// point (exactly what the meter tap closure hands over).
    private static func feed(
        _ analyzer: LiveLoudnessAnalyzer, _ channels: [[Float]]
    ) -> (snapshot: LiveLoudnessSnapshot, generation: UInt64) {
        let frames = channels.map(\.count).min() ?? 0
        let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>
            .allocate(capacity: channels.count)
        defer { pointers.deallocate() }
        for (index, channel) in channels.enumerated() {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            channel.withUnsafeBufferPointer {
                buffer.update(from: $0.baseAddress!, count: frames)
            }
            pointers[index] = buffer
        }
        defer { for index in 0..<channels.count { pointers[index].deallocate() } }
        return analyzer.processAndSnapshot(
            channels: pointers, channelCount: channels.count, frameCount: frames)
    }

    // 1. The wrapper is a pure conduit: pointer-fed analyzer == the DAWCore
    //    stream fed the same samples (exact snapshot equality — same class,
    //    same order).
    @Test("processAndSnapshot equals a directly-fed Loudness.Stream exactly")
    func matchesDirectStream() {
        let tone = Self.sine(frequency: 997, amplitude: 0.1, seconds: 1.0)
        let analyzer = LiveLoudnessAnalyzer(sampleRate: Self.sampleRate, channelCount: 2)
        let viaWrapper = Self.feed(analyzer, [tone, tone]).snapshot

        let direct = Loudness.Stream(sampleRate: Self.sampleRate, channelCount: 2)
        direct.process([tone, tone])
        #expect(viaWrapper == direct.snapshot())
        #expect(viaWrapper.momentaryLufs != nil)  // anti-vacuity
    }

    // 2. Generation handshake: snapshots tag generation 0 until a reset;
    //    requestReset returns the bumped generation; the NEXT delivery
    //    consumes the pending reset (post-reset stats, new tag).
    @Test("requestReset bumps the generation and the next delivery starts fresh")
    func resetHandshake() throws {
        let analyzer = LiveLoudnessAnalyzer(sampleRate: Self.sampleRate, channelCount: 2)
        let loud = Self.sine(frequency: 997, amplitude: 0.5, seconds: 1.0)
        let before = Self.feed(analyzer, [loud, loud])
        #expect(before.generation == 0)
        #expect(before.snapshot.secondsAnalyzed == 1.0)

        let newGeneration = analyzer.requestReset()
        #expect(newGeneration == 1)

        // Next tap delivery: reset consumed FIRST, so the loud second is
        // forgotten — only the quiet chunk is measured, tagged gen 1.
        let quiet = Self.sine(frequency: 997, amplitude: 0.01, seconds: 0.5)
        let after = Self.feed(analyzer, [quiet, quiet])
        #expect(after.generation == 1)
        #expect(after.snapshot.secondsAnalyzed == 0.5)
        let momentary = try #require(after.snapshot.momentaryLufs)
        #expect(momentary < -30)  // 0.5 amplitude memory would read ≈ −5.3

        // Two resets between deliveries collapse into one restart with the
        // latest generation (the flag is a level, not a queue).
        _ = analyzer.requestReset()
        let third = analyzer.requestReset()
        #expect(third == 3)
        let final = Self.feed(analyzer, [quiet, quiet])
        #expect(final.generation == 3)
        #expect(final.snapshot.secondsAnalyzed == 0.5)
    }

    // 3. matches(): the engine's reuse-across-rebuild test.
    @Test("matches() keys on the live format")
    func formatMatching() {
        let analyzer = LiveLoudnessAnalyzer(sampleRate: 48_000, channelCount: 2)
        #expect(analyzer.matches(sampleRate: 48_000, channelCount: 2))
        #expect(!analyzer.matches(sampleRate: 44_100, channelCount: 2))
        #expect(!analyzer.matches(sampleRate: 48_000, channelCount: 1))
    }
}
