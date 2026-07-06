import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// Sample-accuracy proof for M1 multitrack playback: everything renders
/// offline at 48 kHz stereo through the same PlaybackGraph the live engine
/// uses, then gets assertion-checked frame by frame.
@MainActor
@Suite("Multitrack playback — offline render", .serialized)
struct PlaybackRenderTests {
    private func audioTrack(clip url: URL, startBeat: Double, lengthBeats: Double) -> Track {
        Track(name: "T", kind: .audio, clips: [
            Clip(name: "clip", startBeat: startBeat, lengthBeats: lengthBeats, audioFileURL: url),
        ])
    }

    // 1.
    @Test("silence before the clip, onset at beat 2 within ±2 frames")
    func silenceThenOnset() throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(clip: fixtures.cos1k48, startBeat: 2, lengthBeats: 4)
        let audio = try OfflineRenderer().render(
            tracks: [track], tempoBPM: 120, fromBeat: 0, durationSeconds: 2.0
        )
        let left = audio.channelData[0]

        #expect(TestSignals.peak(left, in: 0..<47_984) == 0)

        let onset = try #require(TestSignals.firstFrame(in: left, exceeding: 0.1))
        let delta = onset - 48_000
        print("[measured] test1 onset delta: \(delta) frames (onset at \(onset), expected 48_000)")
        #expect(abs(delta) <= 2)
    }

    // 2.
    @Test("steady-state RMS matches amp/√2 per channel")
    func steadyStateRMS() throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(clip: fixtures.cos1k48, startBeat: 2, lengthBeats: 4)
        let audio = try OfflineRenderer().render(
            tracks: [track], tempoBPM: 120, fromBeat: 0, durationSeconds: 2.0
        )
        for channel in audio.channelData {
            let rms = TestSignals.rms(channel, in: 60_000..<90_000)
            #expect(abs(rms - 0.3536) < 0.01)
        }
    }

    // 3.
    @Test("render starting at beat 1 places the beat-2 clip at 0.5 s")
    func onsetWithNonZeroStart() throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(clip: fixtures.cos1k48, startBeat: 2, lengthBeats: 4)
        let audio = try OfflineRenderer().render(
            tracks: [track], tempoBPM: 120, fromBeat: 1, durationSeconds: 1.5
        )
        let left = audio.channelData[0]

        let onset = try #require(TestSignals.firstFrame(in: left, exceeding: 0.1))
        let delta = onset - 24_000
        print("[measured] test3 onset delta: \(delta) frames (onset at \(onset), expected 24_000)")
        #expect(abs(delta) <= 2)
    }

    // 4.
    @Test("two tracks sum coherently: peak 0.5, RMS doubles")
    func twoTrackSumming() throws {
        let fixtures = try TestSignals.fixtures()
        let one = audioTrack(clip: fixtures.cos1k48Quarter, startBeat: 0, lengthBeats: 4)
        let two = audioTrack(clip: fixtures.cos1k48Quarter, startBeat: 0, lengthBeats: 4)

        let dual = try OfflineRenderer().render(
            tracks: [one, two], tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let single = try OfflineRenderer().render(
            tracks: [one], tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )

        let window = 0..<48_000
        let dualPeak = TestSignals.peak(dual.channelData[0], in: window)
        #expect(abs(dualPeak - 0.5) < 0.01)

        let dualRMS = TestSignals.rms(dual.channelData[0], in: window)
        let singleRMS = TestSignals.rms(single.channelData[0], in: window)
        #expect(abs(dualRMS - 2 * singleRMS) < 0.02 * dualRMS)
    }

    // 5.
    @Test("starting mid-clip at beat 2 reproduces the file from 1.0 s exactly")
    func midClipStart() throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(clip: fixtures.cos1k48, startBeat: 0, lengthBeats: 4)
        let audio = try OfflineRenderer().render(
            tracks: [track], tempoBPM: 120, fromBeat: 2, durationSeconds: 0.5
        )
        let rendered = audio.channelData[0]
        let source = try TestSignals.readFile(fixtures.cos1k48)[0]

        var maxDifference: Float = 0
        for frame in 0..<24_000 {
            maxDifference = max(maxDifference, abs(rendered[frame] - source[48_000 + frame]))
        }
        #expect(maxDifference < 1e-4)
    }

    // 6.
    @Test("44.1 kHz clip in a 48 kHz render: onset within ±64, pitch preserved")
    func crossRateSRC() throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(clip: fixtures.sine440_44k1, startBeat: 1, lengthBeats: 4)
        let audio = try OfflineRenderer().render(
            tracks: [track], tempoBPM: 120, fromBeat: 0, durationSeconds: 1.5
        )
        let left = audio.channelData[0]

        let onset = try #require(TestSignals.firstFrame(in: left, exceeding: 0.1))
        let delta = onset - 24_000
        print("[measured] test6 onset delta: \(delta) frames (onset at \(onset), expected 24_000 ± 64)")
        #expect(abs(delta) <= 64)

        let frequency = TestSignals.dominantFrequency(
            byZeroCrossings: left, sampleRate: 48_000, in: 30_000..<66_000
        )
        print("[measured] test6 dominant frequency: \(frequency) Hz")
        #expect(abs(frequency - 440) < 1)
    }

    // 7.
    @Test("region shorter than the file truncates playback")
    func regionTruncation() throws {
        let fixtures = try TestSignals.fixtures()
        // File is 4 beats at 120 BPM; region only 2 beats → ends at 1.0 s.
        let track = audioTrack(clip: fixtures.cos1k48, startBeat: 0, lengthBeats: 2)
        let audio = try OfflineRenderer().render(
            tracks: [track], tempoBPM: 120, fromBeat: 0, durationSeconds: 1.5
        )
        let left = audio.channelData[0]
        #expect(TestSignals.peak(left, in: 48_008..<72_000) < 1e-4)
    }

    // 8.
    @Test("empty project renders exact silence")
    func emptyProject() throws {
        let audio = try OfflineRenderer().render(
            tracks: [], tempoBPM: 120, fromBeat: 0, durationSeconds: 0.5
        )
        #expect(audio.frameCount == 24_000)
        for channel in audio.channelData {
            #expect(TestSignals.peak(channel, in: 0..<channel.count) == 0)
        }
    }

    // 9.
    @Test("per-track meter taps: signal track reads ≈ amp/√2, silent track stays dark")
    func perTrackMetering() async throws {
        let fixtures = try TestSignals.fixtures()
        let signalTrack = audioTrack(clip: fixtures.cos1k48, startBeat: 0, lengthBeats: 4)
        let silentTrack = Track(name: "empty", kind: .audio, clips: [])

        let renderer = OfflineRenderer()
        var frames: [UUID: [MeterFrame]] = [:]
        renderer.meterSink = { trackID, frame in
            frames[trackID, default: []].append(frame)
        }

        _ = try renderer.render(
            tracks: [signalTrack, silentTrack], tempoBPM: 120,
            fromBeat: 0, durationSeconds: 1.0
        )
        // Tap frames hop to the main actor as queued Tasks; the pulls are
        // synchronous, so they only land once we suspend. Drain them.
        try await Task.sleep(for: .milliseconds(300))

        let signalFrames = try #require(frames[signalTrack.id])
        let maxRMS = signalFrames.map(\.rms).max() ?? 0
        let maxPeak = signalFrames.map(\.peak).max() ?? 0
        print("[measured] test9 per-track meter: max RMS \(maxRMS) (expected 0.3536 ± 0.06), "
              + "max peak \(maxPeak), \(signalFrames.count) frames")
        #expect(abs(maxRMS - 0.3536) < 0.06)

        // The silent track's tap may fire (zero buffers) or not at all —
        // either way nothing above the noise floor is allowed.
        let silentFrames = frames[silentTrack.id] ?? []
        print("[measured] test9 silent track: \(silentFrames.count) frames, "
              + "max RMS \(silentFrames.map(\.rms).max() ?? 0)")
        #expect(silentFrames.allSatisfy { $0.rms < 0.01 && $0.peak < 0.01 })
    }

    // 10.
    @Test("live smoke: start/seek/stop pushes a monotonic playhead")
    func liveSmoke() async throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            // Headless machine without an output device — nothing to verify live.
            return
        }

        var pushes: [Double] = []
        engine.playheadHandler = { pushes.append($0) }

        var transport = TransportState()
        transport.isPlaying = true
        engine.startPlayback(transport)
        try await Task.sleep(for: .milliseconds(250))

        transport.positionBeats = 8  // forward seek keeps monotonicity meaningful
        engine.seek(transport)
        try await Task.sleep(for: .milliseconds(250))

        engine.stopPlayback()
        engine.shutdown()

        #expect(!pushes.isEmpty)
        #expect(pushes.allSatisfy { $0 >= 0 })
        #expect(zip(pushes, pushes.dropFirst()).allSatisfy { $0 <= $1 })
    }
}

/// Reconcile signature diffing — parameter changes must never look
/// schedule-affecting. No engine start needed; manual rendering mode keeps
/// the graph off the hardware entirely.
@MainActor
@Suite("PlaybackGraph signature")
struct PlaybackGraphSignatureTests {
    private func makeGraph() throws -> (engine: AVAudioEngine, graph: PlaybackGraph) {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        return (engine, PlaybackGraph(engine: engine))
    }

    @Test("parameter-only track change does not change the signature")
    func parameterOnlyChange() throws {
        let (engine, graph) = try makeGraph()
        defer { _ = engine }  // keep the engine alive for the graph's lifetime

        var track = Track(name: "A", kind: .audio,
                          clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4)])
        #expect(graph.reconcile(tracks: [track]))  // first sight of the track

        track.volume = 0.25
        track.pan = -0.5
        track.isMuted = true
        track.isSoloed = true
        track.name = "renamed"
        #expect(!graph.reconcile(tracks: [track]))
    }

    @Test("arming a track is parameter-only — signature unchanged")
    func armOnlyChange() throws {
        let (engine, graph) = try makeGraph()
        defer { _ = engine }

        var track = Track(name: "A", kind: .audio,
                          clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4)])
        #expect(graph.reconcile(tracks: [track]))  // first sight of the track

        // Arm flips on every record enable/disable — it must never trigger a
        // stop-reschedule-resume mid-playback.
        track.isArmed = true
        #expect(!graph.reconcile(tracks: [track]))
    }

    @Test("adding a clip changes the signature")
    func clipAddition() throws {
        let (engine, graph) = try makeGraph()
        defer { _ = engine }

        var track = Track(name: "A", kind: .audio, clips: [])
        graph.reconcile(tracks: [track])
        track.clips.append(Clip(name: "c", startBeat: 1, lengthBeats: 2))
        #expect(graph.reconcile(tracks: [track]))
    }

    @Test("moving a clip changes the signature")
    func clipMove() throws {
        let (engine, graph) = try makeGraph()
        defer { _ = engine }

        var track = Track(name: "A", kind: .audio,
                          clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4)])
        graph.reconcile(tracks: [track])
        track.clips[0].startBeat = 3
        #expect(graph.reconcile(tracks: [track]))
    }

    @Test("removing a track changes the signature")
    func trackRemoval() throws {
        let (engine, graph) = try makeGraph()
        defer { _ = engine }

        let track = Track(name: "A", kind: .audio,
                          clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4)])
        graph.reconcile(tracks: [track])
        #expect(graph.reconcile(tracks: []))
        #expect(graph.signature.isEmpty)
    }
}
