import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m15-c master volume automation — the engine gates:
///
///  1. PLACEMENT: a flat master lane == `masterVolume` of the same value,
///     BYTE-identical — with an empty chain AND through a nonlinear master
///     limiter (only possible if the lane gain applies at the exact §1-B
///     fader point, the chain-host input ≡ mainMixer output). The multi-track
///     cases document the measured C0 per-input-accumulation law: a
///     power-of-two gain stays byte-identical for any track count; an
///     arbitrary gain is ulp-class.
///  2. ANALYTIC FADE: a programmed 1→0 linear master fade offline-renders to
///     the analytic per-sample curve within the automation suite's
///     established ≤1e-6 (AutomationEngineTests §2).
///  3. LIVE == OFFLINE: the master read head is the SAME AutomationRenderer
///     machinery (host-tick epoch math vs first-pull epoch), asserted on the
///     REAL master chain host's renderer.
///  4. PDC COMPOSITION: fade + master limiter (240-sample lookahead) ==
///     the chain-less fade render delayed by EXACTLY 240 samples, BIT-exact
///     (the limiter's below-ceiling null law) — fade and audio delay
///     TOGETHER; relative alignment is exact and the absolute shift is the
///     documented m13-d C7 ruler-to-speaker figure.
///  5. NULL ERA: disabled/empty/absent lanes render byte-identical.
///  6. LOOP UNROLL: the master publish shares `buildRollSchedule` with strips
///     by construction; the unrolled block math is pinned breakpoint ==
///     integral across cycles (the m14-b idiom).
@MainActor
@Suite("Master automation — render gates (m15-c)", .serialized)
struct MasterAutomationRenderTests {
    private static let sampleRate = 48_000.0

    // MARK: - Helpers

    /// Stereo Float32 DC WAV — the AutomationEngineTests fixture pattern.
    private func writeConstantWAV(value: Float, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("master-auto-dc-\(UUID().uuidString).wav")
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
        for channel in 0..<2 {
            for frame in 0..<frames { data[channel][frame] = value }
        }
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    private func bitDiffCount(_ a: RenderedAudio, _ b: RenderedAudio) -> Int {
        var diffs = 0
        for channel in 0..<min(a.channelData.count, b.channelData.count) {
            for frame in 0..<min(a.channelData[channel].count, b.channelData[channel].count)
            where a.channelData[channel][frame].bitPattern
                != b.channelData[channel][frame].bitPattern {
                diffs += 1
            }
        }
        return diffs
    }

    private func maxAbsDiff(_ a: RenderedAudio, _ b: RenderedAudio) -> Double {
        var diff = 0.0
        for channel in 0..<min(a.channelData.count, b.channelData.count) {
            for frame in 0..<min(a.channelData[channel].count, b.channelData[channel].count) {
                diff = max(diff, abs(Double(a.channelData[channel][frame])
                    - Double(b.channelData[channel][frame])))
            }
        }
        return diff
    }

    /// One flat-value master volume lane.
    private func flatLane(_ value: Double) -> AutomationLane {
        AutomationLane(target: .volume, points: [AutomationPoint(beat: 0, value: value)])
    }

    private func dcTrack(url: URL, name: String = "DC", volume: Double = 1,
                         pan: Double = 0) -> Track {
        Track(name: name, kind: .audio, volume: volume, pan: pan,
              clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url)])
    }

    // MARK: - 1. Placement: static equivalence

    @Test("flat master lane == masterVolume, byte-identical (single source; lane REPLACES the fader)")
    func staticEquivalenceSingleSource() throws {
        let url = try writeConstantWAV(value: 0.25, frames: 96_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let tracks = [dcTrack(url: url)]

        // A: the manual fader at 0.7, no lane — pre-m15-c path verbatim.
        let manual = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
            durationSeconds: 1.0, masterVolume: 0.7)
        // B: a flat lane at 0.7 with a DIFFERENT manual value — the lane must
        // REPLACE the fader (0.35 leaking through would show instantly).
        let lane = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
            durationSeconds: 1.0, masterVolume: 0.35,
            masterAutomation: [flatLane(0.7)])

        let diffs = bitDiffCount(manual, lane)
        let mid = Double(lane.channelData[0][24_000])
        print("[measured] static equivalence (single source, 0.7): bit diffs \(diffs) "
              + "over 2×48 000 samples; sample 24 000 = \(mid) (analytic 0.175)")
        #expect(diffs == 0)
        #expect(abs(mid - 0.175) < 1e-6)   // real audio, not agreeing silences
    }

    @Test("flat master lane == masterVolume THROUGH the master limiter, byte-identical (the pre-chain placement proof)")
    func staticEquivalenceThroughNonlinearChain() throws {
        let url = try writeConstantWAV(value: 0.9, frames: 96_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let tracks = [dcTrack(url: url)]
        // A HOT limiter (−10 dB ceiling) so the chain genuinely bends the
        // signal: 0.9 × 0.7 = 0.63 ≫ 0.316 — placement AFTER the chain would
        // produce a visibly different file, and even the same nonlinearity
        // fed a differently-placed gain cannot agree byte-for-byte.
        let chain = [EffectDescriptor(kind: .limiter,
                                      limiter: LimiterParams(ceilingDb: -10))]

        let manual = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
            durationSeconds: 1.0, masterVolume: 0.7, masterEffects: chain)
        let lane = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
            durationSeconds: 1.0, masterVolume: 0.35, masterEffects: chain,
            masterAutomation: [flatLane(0.7)])

        let diffs = bitDiffCount(manual, lane)
        print("[measured] static equivalence through limiter(−10): bit diffs \(diffs)")
        #expect(diffs == 0)
        // The limiter actually worked (didn't pass silence): peak ≈ ceiling.
        var peak: Float = 0
        for channel in lane.channelData { for s in channel { peak = max(peak, abs(s)) } }
        #expect(peak > 0.2)
    }

    @Test("multi-track: power-of-two gain byte-identical; arbitrary gain ulp-class (the C0 per-input law)")
    func staticEquivalenceMultiTrack() throws {
        let fixtures = try TestSignals.fixtures()
        let dc = try writeConstantWAV(value: 0.2, frames: 96_000)
        defer { try? FileManager.default.removeItem(at: dc) }
        let tracks = [
            Track(name: "A", kind: .audio, pan: -0.3,
                  clips: [Clip(name: "a", startBeat: 0, lengthBeats: 4,
                               audioFileURL: fixtures.cos1k48)]),
            Track(name: "B", kind: .audio, volume: 0.7, pan: 0.4,
                  clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                               audioFileURL: fixtures.cos1k48Quarter)]),
            dcTrack(url: dc, name: "C"),
        ]
        let map = TempoMap(constantBPM: 120)

        // 0.5 = 2^-1: exact halving commutes through per-input accumulation —
        // byte-identical even with three live inputs.
        let manualHalf = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: tracks, tempoMap: map, durationSeconds: 1.0, masterVolume: 0.5)
        let laneHalf = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: tracks, tempoMap: map, durationSeconds: 1.0, masterVolume: 1,
            masterAutomation: [flatLane(0.5)])
        let halfDiffs = bitDiffCount(manualHalf, laneHalf)
        print("[measured] multi-track 0.5 (power of two): bit diffs \(halfDiffs)")
        #expect(halfDiffs == 0)

        // 0.7: AVAudioMixerNode applies its output volume PER INPUT during
        // accumulation (the m13-d C0 measured law: Σ(xᵢ·v) vs (Σxᵢ)·v is a
        // 1-ulp float drift), so the manual path and the post-sum lane stage
        // may differ at ulp scale — documented, bounded, and printed.
        let manual = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: tracks, tempoMap: map, durationSeconds: 1.0, masterVolume: 0.7)
        let lane = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: tracks, tempoMap: map, durationSeconds: 1.0, masterVolume: 1,
            masterAutomation: [flatLane(0.7)])
        let diff = maxAbsDiff(manual, lane)
        print("[measured] multi-track 0.7 (arbitrary): max |Δ| \(diff) (C0 ulp class)")
        #expect(diff < 1e-6)
    }

    // MARK: - 2. Analytic fade

    @Test("programmed master fade 1→0 over 4 beats matches the analytic curve ≤1e-6 per sample")
    func masterFadeMatchesAnalyticCurve() throws {
        let url = try writeConstantWAV(value: 0.25, frames: 96_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let fade = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 1),
            AutomationPoint(beat: 4, value: 0),
        ])
        // 4 beats @ 120 = 2 s = 96 000 samples: one linear segment spans the
        // whole render, so the per-quantum ramp is exact by design — the
        // AutomationEngineTests §2 shape, inherited tolerance ≤1e-6.
        let audio = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: [dcTrack(url: url)], tempoMap: TempoMap(constantBPM: 120),
            durationSeconds: 2.0, masterVolume: 1, masterAutomation: [fade])
        #expect(audio.frameCount == 96_000)
        var maxDiff = 0.0
        for channel in audio.channelData {
            for frame in 0..<channel.count {
                let analytic = 0.25 * (1.0 - Double(frame) / 96_000.0)
                maxDiff = max(maxDiff, abs(Double(channel[frame]) - analytic))
            }
        }
        let mid = Double(audio.channelData[0][48_000])
        print("[measured] master fade: max |out − analytic| \(maxDiff) over "
              + "2 × 96 000 samples; sample 48 000 = \(mid) (analytic 0.125)")
        #expect(maxDiff < 1e-6)
        #expect(abs(mid - 0.125) < 1e-6)
    }

    // MARK: - 3. Live == offline on the REAL master read head

    @Test("master chain host: volume stage is pre-chain, strips post-chain; live epoch math == offline on its renderer")
    func masterReadHeadLiveOfflineEquivalence() throws {
        // Placement flags: a fresh (strip-shape) host defaults post-chain;
        // the graph's master host is flipped pre-chain at creation.
        let stripHost = ChainHostAU.makeChainHostNode()
        #expect(ChainHostAU.isVolumeStagePreChain(of: stripHost) == false)

        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        _ = graph.reconcile(tracks: [Track(name: "T", kind: .audio)])
        let masterHost = try #require(graph.masterChainHost)
        #expect(ChainHostAU.isVolumeStagePreChain(of: masterHost) == true)
        let renderer = try #require(graph.masterAutomationRendererForTesting())

        // The SAME schedule points in live vs offline mode, applied through
        // the REAL master renderer — the AutomationEngineTests live/offline
        // idiom on the master read head. Linear fade 1→0 over 96 000 samples.
        let points = [
            AutomationBreakpoint(sampleTime: 0, value: 1, holdsSegment: false),
            AutomationBreakpoint(sampleTime: 96_000, value: 0, holdsSegment: false),
        ]
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksToSeconds = timebase.denom == 0
            ? 1e-9 : Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
        let anchor: UInt64 = 1_000_000_000

        func applyQuantum(_ schedule: AutomationSchedule, ts: AudioTimeStamp,
                          frames: Int) throws -> [Float] {
            renderer.publish(schedule)
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try #require(buffer.floatChannelData)
            for channel in 0..<2 {
                for frame in 0..<frames { data[channel][frame] = 1 }
            }
            var stamp = ts
            renderer.apply(bufferList: buffer.mutableAudioBufferList,
                           frameCount: frames, timestamp: &stamp)
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }

        var offlineTS = AudioTimeStamp()
        offlineTS.mSampleTime = 24_000   // epoch latches on first pull
        offlineTS.mFlags = .sampleTimeValid
        var probe = offlineTS
        probe.mSampleTime = 24_000 + 24_000  // schedule-relative 24 000 after latch
        let offlineSchedule = AutomationSchedule(
            generation: 1, mode: .offline, sampleRate: Self.sampleRate,
            volumePoints: points, panPoints: [])
        _ = try applyQuantum(offlineSchedule, ts: offlineTS, frames: 512)  // latch epoch at 0
        let offlineOut = try applyQuantum(offlineSchedule, ts: probe, frames: 512)

        // Live: place the quantum at schedule-relative 24 000 via host ticks.
        let liveSeconds = 24_000.0 / Self.sampleRate
        var liveTS = AudioTimeStamp()
        liveTS.mHostTime = anchor + UInt64((liveSeconds / ticksToSeconds).rounded())
        liveTS.mFlags = [.hostTimeValid, .sampleTimeValid]
        let liveSchedule = AutomationSchedule(
            generation: 2, mode: .live(anchorHostTime: anchor),
            sampleRate: Self.sampleRate, volumePoints: points, panPoints: [])
        let liveOut = try applyQuantum(liveSchedule, ts: liveTS, frames: 512)

        var crossDiff = 0.0
        for frame in 0..<512 {
            crossDiff = max(crossDiff, abs(Double(liveOut[frame]) - Double(offlineOut[frame])))
        }
        print("[measured] master read head live-vs-offline (frame 24 000, 512 frames): "
              + "max |Δ| \(crossDiff); offline[0] = \(offlineOut[0]) (analytic 0.75)")
        // Host-tick granularity can shift the live quantum ±1 frame; on this
        // fade the per-frame step is 1/96 000 ≈ 1.05e-5 — the established
        // live/offline bound (AutomationEngineTests §live/offline).
        #expect(crossDiff < 2.1e-5)
        #expect(abs(Double(offlineOut[0]) - 0.75) < 1e-6)
        renderer.publish(nil)
    }

    // MARK: - 4. PDC composition

    @Test("fade through master limiter == chain-less fade delayed by EXACTLY 240 samples, bit-exact")
    func fadeComposesWithMasterChainLatency() throws {
        let url = try writeConstantWAV(value: 0.25, frames: 96_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let fade = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 1),
            AutomationPoint(beat: 4, value: 0),
        ])
        // Program peaks at 0.25 (−12 dB) — safely under the −1 dB default
        // ceiling, where the limiter's documented law is a bit-exact null
        // against the DELAYED dry signal (LimiterEffect below-ceiling
        // contract). 240 = round(0.005 × 48 000), the m13-d C7 figure.
        let dry = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: [dcTrack(url: url)], tempoMap: TempoMap(constantBPM: 120),
            durationSeconds: 2.0, masterVolume: 1, masterAutomation: [fade])
        let limited = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: [dcTrack(url: url)], tempoMap: TempoMap(constantBPM: 120),
            durationSeconds: 2.0, masterVolume: 1,
            masterEffects: [EffectDescriptor(kind: .limiter)],
            masterAutomation: [fade])

        let latency = 240
        var mismatches = 0
        for channel in 0..<2 {
            let dryChannel = dry.channelData[channel]
            let limitedChannel = limited.channelData[channel]
            for frame in 0..<(dryChannel.count - latency)
            where limitedChannel[frame + latency].bitPattern != dryChannel[frame].bitPattern {
                mismatches += 1
            }
            // The lookahead priming region is the ring's zero fill.
            for frame in 0..<latency where limitedChannel[frame] != 0 {
                mismatches += 1
            }
        }
        print("[measured] PDC composition: limiter render vs dry render delayed by 240 — "
              + "\(mismatches) bit mismatches over 2×\(dry.channelData[0].count - latency) samples")
        #expect(mismatches == 0)
        // Fade-to-audio alignment is therefore EXACT (both delayed together);
        // the absolute 240-sample shift is the documented m13-d C7
        // ruler-to-speaker behavior (no master ring absorbs it, by design).
    }

    // MARK: - 5. Null era

    @Test("no lane == disabled lane == empty lane, all byte-identical (null path untouched)")
    func nullEraDisabledAndEmptyLanesAreInert() throws {
        let fixtures = try TestSignals.fixtures()
        let tracks = [
            Track(name: "A", kind: .audio, volume: 0.8, pan: -0.2,
                  clips: [Clip(name: "a", startBeat: 0, lengthBeats: 4,
                               audioFileURL: fixtures.cos1k48)]),
        ]
        let map = TempoMap(constantBPM: 120)
        func render(_ lanes: [AutomationLane]) throws -> RenderedAudio {
            try OfflineRenderer(sampleRate: Self.sampleRate).render(
                tracks: tracks, tempoMap: map, durationSeconds: 1.0,
                masterVolume: 0.9, masterAutomation: lanes)
        }
        let none = try render([])
        let disabled = try render([AutomationLane(
            target: .volume,
            points: [AutomationPoint(beat: 0, value: 0.1)], isEnabled: false)])
        let empty = try render([AutomationLane(target: .volume, points: [])])

        let disabledDiffs = bitDiffCount(none, disabled)
        let emptyDiffs = bitDiffCount(none, empty)
        print("[measured] null era: disabled-lane diffs \(disabledDiffs), "
              + "empty-lane diffs \(emptyDiffs) vs no-lane render")
        #expect(disabledDiffs == 0)
        #expect(emptyDiffs == 0)
        // Real audio, not agreeing silences.
        #expect(TestSignals.rms(none.channelData[0], in: 0..<24_000) > 0.1)
    }

    // MARK: - 6. Loop unroll pin (breakpoint == integral, the m14-b idiom)

    @Test("master lane unrolls across cycles: every block's frames are the absolute integral, values re-state per cycle")
    func masterLaneLoopUnrollBreakpointsMatchIntegral() throws {
        // The MASTER publish routes through PlaybackGraph.buildRollSchedule —
        // the ONE builder strips use (shared by construction, m15-c) — whose
        // loop branch is AutomationSchedule.buildLoopUnrolled. Pin the master
        // lane's unrolled block math directly: play from beat 0 with loop
        // [2, 6) @ 120 BPM — head = 0→loopEnd = 3 s, cycle = 2 s — through
        // cycle 2. Lane: fade 1→0 across the loop window.
        let lane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 2, value: 1),
            AutomationPoint(beat: 6, value: 0),
        ])
        let map = TempoMap(constantBPM: 120)
        let schedule = try #require(AutomationSchedule.buildLoopUnrolled(
            volumeLane: lane, panLane: nil,
            fromBeat: 0, loopStartBeat: 2, loopEndBeat: 6,
            headSeconds: 3.0, cycleSeconds: 2.0, throughCycle: 2,
            tempoMap: map, sampleRate: Self.sampleRate,
            generation: 1, mode: .offline, timelineID: 1))
        let points = Array(schedule.volumePoints)

        // Head: the beat-2 point at 48 000 (integral from beat 0) + the
        // synthesized boundary on the head-end frame 144 000. Cycle k spans
        // [head + (k−1)·cycle, head + k·cycle] — the ABSOLUTE integral from
        // the state constants (never previous + cycleFrames, the anchor
        // law) — each block re-stating entry value 1 and exit value 0;
        // adjacent blocks deliberately duplicate the boundary frame.
        let cycle1Start = Int64(((3.0 + 0.0) * Self.sampleRate).rounded())   // 144 000
        let cycle1End = Int64(((3.0 + 2.0) * Self.sampleRate).rounded())     // 240 000
        let cycle2Start = cycle1End                                          // 240 000
        let cycle2End = Int64(((3.0 + 4.0) * Self.sampleRate).rounded())     // 336 000
        #expect(points.map(\.sampleTime) == [48_000, cycle1Start,
                                             cycle1Start, cycle1End,
                                             cycle2Start, cycle2End])
        #expect(points.map(\.value) == [1, 0, 1, 0, 1, 0])

        // Evaluated mid-cycle values match the lane's beat-domain integral:
        // halfway through cycle 2 (frame 288 000 ≡ beat 4 in the window) the
        // fade reads 0.5.
        var cursor = -1
        let midCycle2 = AutomationSchedule.value(
            at: (cycle2Start + cycle2End) / 2, points: schedule.volumePoints, cursor: &cursor)
        print("[measured] loop unroll: cycle-2 midpoint value \(midCycle2) (analytic 0.5); "
              + "block frames \(points.map(\.sampleTime))")
        #expect(abs(midCycle2 - 0.5) < 1e-9)
        // The wrap is a step ~0 → 1 exactly ON the boundary frame (the next
        // cycle's start owns it — loop semantics, design §5).
        var wrapCursor = -1
        #expect(AutomationSchedule.value(
            at: cycle1End - 1, points: schedule.volumePoints, cursor: &wrapCursor) < 0.001)
        var afterCursor = -1
        #expect(AutomationSchedule.value(
            at: cycle2Start, points: schedule.volumePoints, cursor: &afterCursor) == 1)
    }
}
