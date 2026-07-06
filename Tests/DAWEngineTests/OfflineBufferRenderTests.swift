import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// M5 iv-b engine seam (spec §5, §7): `renderOffline` is `renderMixdown`
/// minus the write (bit-identical output), `writeAudioFile` is frame-exact,
/// `forcedCompensationTargets` actually forces ring targets, the planning
/// probe matches the auto-plan, and the whole normalized-bounce path proves
/// itself against the WRITTEN file re-read from disk.
@MainActor
@Suite("Offline buffer seam — renderOffline/writeAudioFile (M5 iv-b)", .serialized)
struct OfflineBufferRenderTests {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-bufseam-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func audioTrack(_ url: URL, lengthBeats: Double = 4,
                            effects: [EffectDescriptor] = []) -> Track {
        Track(name: "T", kind: .audio,
              clips: [Clip(name: "c", startBeat: 0, lengthBeats: lengthBeats,
                           audioFileURL: url)],
              effects: effects)
    }

    // MARK: - renderOffline ≡ renderMixdown minus the write

    @Test("renderOffline buffer is bit-identical to renderMixdown's file")
    func renderOfflineMatchesMixdownFile() async throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(fixtures.cos1k48)
        let engine = AudioEngine()

        let buffer = try await engine.renderOffline(
            tracks: [track], tempoBPM: 120, masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0, forcedCompensationTargets: nil)

        let out = try makeTempDir("mix").appendingPathComponent("mix.wav")
        _ = try await engine.renderMixdown(
            tracks: [track], tempoBPM: 120, masterVolume: 1,
            fromBeat: 0, durationSeconds: 1.0, to: out)
        let written = try TestSignals.readFile(out)

        #expect(buffer.sampleRate == 48_000)
        #expect(buffer.channelData.count == written.count)
        var maxDifference: Float = 0
        for channel in 0..<min(buffer.channelData.count, written.count) {
            #expect(buffer.channelData[channel].count == written[channel].count)
            let frames = min(buffer.channelData[channel].count, written[channel].count)
            for frame in 0..<frames {
                maxDifference = max(maxDifference,
                                    abs(buffer.channelData[channel][frame] - written[channel][frame]))
            }
        }
        print("[measured] renderOffline vs mixdown file max diff: \(maxDifference)")
        #expect(maxDifference == 0)
        // Real audio, not two agreeing silences.
        #expect(TestSignals.rms(buffer.channelData[0], in: 12_000..<24_000) > 0.2)
    }

    // MARK: - writeAudioFile round trip

    @Test("writeAudioFile writes a frame-exact Float32 WAV, parents created")
    func writeAudioFileRoundTrip() throws {
        // Distinct channels prove deinterleave order survives the trip; the
        // > 1.0 sample proves Float32 keeps over-full-scale content (the ii-e
        // no-baked-headroom stance).
        let frames = 1_000
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            left[frame] = Float(frame) * 1e-4
            right[frame] = -Float(frame) * 2e-4
        }
        left[500] = 1.25
        let audio = RenderedAudio(sampleRate: 48_000, channelData: [left, right])

        // Nested not-yet-existing directory proves recursive parent creation.
        let url = try makeTempDir("write")
            .appendingPathComponent("nested")
            .appendingPathComponent("out.wav")
        let info = try AudioEngine().writeAudioFile(audio, to: url)

        #expect(info.sampleRate == 48_000)
        #expect(info.channelCount == 2)
        #expect(abs(info.durationSeconds - Double(frames) / 48_000.0) < 1e-9)

        let reread = try TestSignals.readFile(url)
        #expect(reread.count == 2)
        #expect(reread[0] == left)
        #expect(reread[1] == right)
    }

    // MARK: - Forced compensation targets reach the ring

    @Test("forcedCompensationTargets delays the strip by exactly the target")
    func forcedTargetsAreApplied() async throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(fixtures.cos1k48)
        let engine = AudioEngine()

        // No effects anywhere: the automatic plan is all-zero, so any shift
        // in the forced pass is the forced ring target and nothing else.
        let reference = try await engine.renderOffline(
            tracks: [track], tempoBPM: 120, masterVolume: 1,
            fromBeat: 0, durationSeconds: 0.5, forcedCompensationTargets: nil)
        let forced = try await engine.renderOffline(
            tracks: [track], tempoBPM: 120, masterVolume: 1,
            fromBeat: 0, durationSeconds: 0.5, forcedCompensationTargets: [track.id: 480])

        // The cosine peaks at frame 0 — the unforced render is loud
        // immediately; the forced one is ring-silence for 480 frames.
        #expect(abs(reference.channelData[0][0]) > 0.1)
        #expect(TestSignals.peak(forced.channelData[0], in: 0..<478) < 1e-6)
        let onset = TestSignals.firstFrame(in: forced.channelData[0], exceeding: 0.1)
        #expect(onset != nil && abs((onset ?? 0) - 480) <= 2)
    }

    // MARK: - Planning probe parity (spec §5)

    @Test("offlineCompensationTargets equals the automatic plan's targets")
    func compensationTargetsMatchAutoPlan() async throws {
        let fixtures = try TestSignals.fixtures()
        // One limiter track (240-sample lookahead @ 48 kHz) + one dry track:
        // the plan pads the dry strip to the 240-sample track stage and gives
        // the limiter strip 0.
        let limited = audioTrack(fixtures.cos1k48,
                                 effects: [EffectDescriptor(kind: .limiter)])
        let dry = audioTrack(fixtures.cos1k48Quarter)
        let engine = AudioEngine()

        let targets = await engine.offlineCompensationTargets(tracks: [limited, dry])
        #expect(targets[limited.id] == 0)
        #expect(targets[dry.id] == 240)

        // Parity with the pure plan math over the same strip facts — the
        // probe IS the auto-plan, not a reimplementation.
        let plan = PDCPlan.compute(input: PDCInput(strips: [
            PDCStripInput(id: limited.id,
                          kind: .track(outputsToMaster: true, hasSends: false),
                          chainLatencyAll: 240, chainLatencyActive: 240),
            PDCStripInput(id: dry.id,
                          kind: .track(outputsToMaster: true, hasSends: false),
                          chainLatencyAll: 0, chainLatencyActive: 0),
        ]))
        let expected = Dictionary(uniqueKeysWithValues:
            plan.strips.map { ($0.id, $0.compensationSamples) })
        #expect(targets == expected)
    }

    // MARK: - Normalized bounce, verified from the WRITTEN file (spec §7)

    @Test("renderBounce hits the LUFS target ±0.1 LU re-measured from disk")
    func normalizedBounceHitsTargetFromDisk() async throws {
        let fixtures = try TestSignals.fixtures()
        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        // 1 kHz cosine, amp 0.5 → ≈ −6 LUFS program; clip covers the whole
        // 2 s window (4 beats @ 120 BPM).
        store.tracks = [audioTrack(fixtures.cos1k48)]

        let out = try makeTempDir("bounce").appendingPathComponent("normalized.wav")
        let result = try await store.renderBounce(
            toPath: out.path, durationSeconds: 2.0, lufsTarget: -16)

        // Ground truth: read the file back off disk and measure THAT.
        let reread = RenderedAudio(sampleRate: 48_000,
                                   channelData: try TestSignals.readFile(out))
        let measured = Loudness.measure(reread)
        let achieved = try #require(measured.integratedLufs)
        print("[measured] normalized bounce from disk: target -16, achieved \(achieved) LUFS")
        #expect(abs(achieved - (-16.0)) <= 0.1)

        // The report is that same ground truth (Float32 write is bit-exact,
        // so re-measuring the file reproduces the report's output block).
        let reported = try #require(result.report.output.integratedLufs)
        #expect(abs(reported - achieved) <= 1e-9)
        #expect(!result.report.limitedByCeiling)
        #expect(result.report.lufsTarget == -16)
        // Gain math closes: input + gain == achieved (static gain, linear op).
        let inputLufs = try #require(result.report.input.integratedLufs)
        #expect(abs(inputLufs + result.report.appliedGainDb - achieved) <= 0.05)
        #expect(result.path == out.path)
        #expect(result.channels == 2)
        #expect(result.sampleRate == 48_000)
        #expect(abs(result.durationSeconds - 2.0) < 0.001)
    }
}
