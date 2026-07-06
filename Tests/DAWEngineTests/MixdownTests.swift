import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// Offline mixdown proof for M1 `render.mixdown`: the WAV writer is
/// frame-exact and bit-exact against the in-memory render, and the offline
/// render path itself is bit-deterministic (the null test the engine harness
/// requires).
@MainActor
@Suite("Mixdown — offline WAV render", .serialized)
struct MixdownTests {
    private func audioTrack(clip url: URL, startBeat: Double, lengthBeats: Double) -> Track {
        Track(name: "T", kind: .audio, clips: [
            Clip(name: "clip", startBeat: startBeat, lengthBeats: lengthBeats, audioFileURL: url),
        ])
    }

    // a.
    @Test("renderToWAV writes a frame-exact, bit-exact Float32 stereo WAV")
    func wavWriteRoundTrip() throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(clip: fixtures.cos1k48, startBeat: 0, lengthBeats: 4)
        // A nested, not-yet-existing directory proves recursive parent creation.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-mixdown-\(UUID().uuidString)")
            .appendingPathComponent("nested")
            .appendingPathComponent("mix.wav")

        let info = try OfflineRenderer().renderToWAV(
            tracks: [track], tempoBPM: 120, masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0, to: url
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(info.sampleRate == 48_000)
        #expect(info.channelCount == 2)
        #expect(abs(info.durationSeconds - 1.0) < 0.001)

        // Re-open the written file: frame length matches the requested
        // duration ±1 frame, at the manual-rendering format's rate/channels.
        let file = try AVAudioFile(forReading: url)
        #expect(abs(Int(file.length) - 48_000) <= 1)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.channelCount == 2)

        // Bit-exact round trip: the file's samples equal a fresh in-memory
        // render of the same project, sample for sample. (Two renders agree
        // exactly — see the determinism null test below — so any nonzero diff
        // here would be a write-path corruption.)
        let written = try TestSignals.readFile(url)
        let rerendered = try OfflineRenderer().render(
            tracks: [track], tempoBPM: 120, fromBeat: 0,
            durationSeconds: 1.0, masterVolume: 1
        )
        #expect(written.count == rerendered.channelData.count)
        var maxDifference: Float = 0
        for channel in 0..<min(written.count, rerendered.channelData.count) {
            #expect(written[channel].count == rerendered.channelData[channel].count)
            let frames = min(written[channel].count, rerendered.channelData[channel].count)
            for frame in 0..<frames {
                maxDifference = max(
                    maxDifference,
                    abs(written[channel][frame] - rerendered.channelData[channel][frame])
                )
            }
        }
        print("[measured] mixdown WAV round-trip max |written − rerendered|: \(maxDifference)")
        #expect(maxDifference == 0)
    }

    // b.
    @Test("determinism null test: two identical renders cancel to exactly zero")
    func determinismNullTest() throws {
        // This test closes the M1 roadmap requirement "Engine test harness:
        // offline-render assertions (null test, …)": the offline render path
        // is bit-deterministic, so subtracting two renders of the same
        // project nulls to exactly 0.0 — any future change that alters the
        // audible output shows up here as a nonzero residual.
        let fixtures = try TestSignals.fixtures()
        let tracks = [
            audioTrack(clip: fixtures.cos1k48, startBeat: 0, lengthBeats: 4),
            audioTrack(clip: fixtures.cos1k48Quarter, startBeat: 1, lengthBeats: 2),
        ]
        let first = try OfflineRenderer().render(
            tracks: tracks, tempoBPM: 120, fromBeat: 0, durationSeconds: 1.5
        )
        let second = try OfflineRenderer().render(
            tracks: tracks, tempoBPM: 120, fromBeat: 0, durationSeconds: 1.5
        )
        #expect(first.frameCount == second.frameCount)
        #expect(first.channelData.count == second.channelData.count)

        var maxDifference: Float = 0
        for channel in 0..<min(first.channelData.count, second.channelData.count) {
            for frame in 0..<min(first.frameCount, second.frameCount) {
                maxDifference = max(
                    maxDifference,
                    abs(first.channelData[channel][frame] - second.channelData[channel][frame])
                )
            }
        }
        print("[measured] determinism null test max |a − b|: \(maxDifference)")
        #expect(maxDifference == 0.0)

        // Sanity: the null only means something over actual signal, not silence.
        #expect(TestSignals.peak(first.channelData[0], in: 0..<first.frameCount) > 0.4)
    }
}
