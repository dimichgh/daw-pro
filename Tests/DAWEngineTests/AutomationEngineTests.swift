import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M4 (vii-b) automation read path — schedule build math (beats → Int64 sample
/// times, hold vs linear), analytic per-sample assertions on the offline
/// bounce, pan-center bit-exact null, the fader-override rule while rolling,
/// stopped-WYSIWYG previews, mid-playback republish re-seek, the no-restart
/// guard, and live/offline equivalence.
@MainActor
@Suite("Automation engine — read path", .serialized)
struct AutomationEngineTests {
    private static let sampleRate = 48_000.0

    // MARK: - Harness helpers

    /// Stereo 48 kHz buffer with both channels filled to `fill`.
    private func stereoBuffer(frames: Int, fill: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<frames { data[channel][frame] = fill }
        }
        return buffer
    }

    /// Offline-mode timestamp: only `mSampleTime` is meaningful (the manual
    /// rendering shape — the renderer latches the first pull as its epoch).
    private func offlineTimestamp(sample: Double) -> AudioTimeStamp {
        var ts = AudioTimeStamp()
        ts.mSampleTime = sample
        ts.mFlags = .sampleTimeValid
        return ts
    }

    /// The renderer's own tick→seconds factor, computed the same way
    /// `AutomationRenderer.init` does, so live-mode tests can place quanta on
    /// the host timeline and derive the EXACT schedule-relative frame the
    /// renderer will compute (same double ops, same bits).
    private var ticksToSeconds: Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase.denom == 0
            ? 1e-9
            : Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }

    /// Live-mode timestamp for schedule-relative `sample` against `anchor`.
    /// Returns the timestamp AND the renderStart the renderer will derive from
    /// it (host-tick granularity can shift it ±1 frame from `sample`).
    private func liveTimestamp(anchor: UInt64, sample: Int64) -> (ts: AudioTimeStamp, renderStart: Int64) {
        let seconds = Double(sample) / Self.sampleRate
        let hostTime = anchor + UInt64((seconds / ticksToSeconds).rounded())
        var ts = AudioTimeStamp()
        ts.mHostTime = hostTime
        ts.mFlags = [.hostTimeValid, .sampleTimeValid]
        let dt = Double(hostTime - anchor) * ticksToSeconds
        return (ts, Int64((dt * Self.sampleRate).rounded()))
    }

    /// Runs one quantum of ones through `renderer.apply` (the render surface,
    /// called directly per its doc contract) and returns both channels.
    private func applyQuantum(_ renderer: AutomationRenderer, frames: Int,
                              timestamp: AudioTimeStamp) throws -> [[Float]] {
        let buffer = try stereoBuffer(frames: frames, fill: 1)
        var ts = timestamp
        renderer.apply(bufferList: buffer.mutableAudioBufferList,
                       frameCount: frames, timestamp: &ts)
        let data = try #require(buffer.floatChannelData)
        return (0..<2).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
    }

    /// Writes a stereo Float32 WAV holding `frames` of the constant `value` on
    /// both channels — the DC fixture that makes per-sample gain assertions
    /// analytic. Scoped so the AVAudioFile closes before it is read back.
    private func writeConstantWAV(value: Float, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-dc-\(UUID().uuidString).wav")
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
        try file.write(from: stereoBuffer(frames: frames, fill: value))
        return url
    }

    /// A PlaybackGraph on a manual-rendering engine (deterministic 48 kHz
    /// graph rate) with `tracks` reconciled and parameters applied — the
    /// AudioEngine call order for the stopped state.
    private func makeGraph(tracks: [Track],
                           playheadBeat: Double = 0) throws -> (AVAudioEngine, PlaybackGraph) {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode   // implicit mixer→output wiring, the OfflineRenderer rule
        _ = graph.reconcile(tracks: tracks)
        graph.applyParameters(tracks: tracks, playheadBeat: playheadBeat)
        return (engine, graph)
    }

    /// Counts sample positions where two renders differ in BIT PATTERN.
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

    // MARK: - 1. Schedule build math

    @Test("build maps beats to Int64 sample times at fixed tempo (hold vs linear, negative anchor-relative, same-sample dedupe)")
    func scheduleBuildMapsBeatsToSampleTimes() {
        // 120 BPM at 48 kHz: 1 beat = 0.5 s = 24 000 samples.
        let points = [
            AutomationPoint(beat: 0, value: 0.2, curve: .hold),
            AutomationPoint(beat: 2, value: 0.8, curve: .linear),
            AutomationPoint(beat: 4, value: 0.4),
        ]
        // Anchored at beat 1: the beat-0 point keeps its NEGATIVE time so a
        // straddling segment interpolates instead of snapping.
        let anchored = AutomationSchedule.buildBreakpoints(
            points: points, fromBeat: 1, tempoMap: TempoMap(constantBPM: 120), sampleRate: 48_000)
        #expect(anchored.map(\.sampleTime) == [-24_000, 24_000, 72_000])
        #expect(anchored.map(\.value) == [0.2, 0.8, 0.4])
        #expect(anchored.map(\.holdsSegment) == [true, false, false])

        // From beat 0 at 90 BPM: beat 3 → 3 × (60/90) × 48 000 = 96 000.
        let ninety = AutomationSchedule.buildBreakpoints(
            points: [AutomationPoint(beat: 3, value: 1)],
            fromBeat: 0, tempoMap: TempoMap(constantBPM: 90), sampleRate: 48_000)
        #expect(ninety.map(\.sampleTime) == [96_000])

        // Two beats that round onto the SAME sample dedupe last-wins, so
        // segments always have positive span.
        let deduped = AutomationSchedule.buildBreakpoints(
            points: [
                AutomationPoint(beat: 1, value: 0.1, curve: .hold),
                AutomationPoint(beat: 1 + 1e-9, value: 0.9),
            ],
            fromBeat: 0, tempoMap: TempoMap(constantBPM: 120), sampleRate: 48_000)
        #expect(deduped.count == 1)
        #expect(deduped[0].sampleTime == 24_000)
        #expect(deduped[0].value == 0.9)          // last wins
        #expect(deduped[0].holdsSegment == false) // the whole breakpoint, not just the value

        // The activeLane predicate and nil-build guard: disabled or empty
        // lanes are inert; neither target automated → no schedule at all.
        let inert = [
            AutomationLane(target: .volume,
                           points: [AutomationPoint(beat: 0, value: 1)], isEnabled: false),
            AutomationLane(target: .pan, points: []),
        ]
        #expect(inert.activeLane(for: .volume) == nil)
        #expect(inert.activeLane(for: .pan) == nil)
        #expect(AutomationSchedule.build(
            volumeLane: nil, panLane: nil, fromBeat: 0, tempoMap: TempoMap(constantBPM: 120),
            sampleRate: 48_000, generation: 1, mode: .offline) == nil)
    }

    @Test("evaluation: before-first / hold / linear midpoint / after-last, cursor re-seek")
    func scheduleEvaluationHoldAndLinearSemantics() {
        let schedule = AutomationSchedule(
            generation: 1, mode: .offline, sampleRate: 48_000,
            volumePoints: [
                AutomationBreakpoint(sampleTime: 0, value: 0.2, holdsSegment: true),
                AutomationBreakpoint(sampleTime: 24_000, value: 0.8, holdsSegment: false),
                AutomationBreakpoint(sampleTime: 72_000, value: 0.4, holdsSegment: false),
            ],
            panPoints: [])
        let points = schedule.volumePoints
        var cursor = -1
        // Before the first point: first value.
        #expect(AutomationSchedule.value(at: -5_000, points: points, cursor: &cursor) == 0.2)
        // Inside the .hold segment: flat at the departing point's value.
        #expect(AutomationSchedule.value(at: 12_345, points: points, cursor: &cursor) == 0.2)
        // Step lands exactly at the next point's time.
        #expect(AutomationSchedule.value(at: 24_000, points: points, cursor: &cursor) == 0.8)
        // Linear midpoint is exact: (0.8 + 0.4) / 2.
        let mid = AutomationSchedule.value(at: 48_000, points: points, cursor: &cursor)
        #expect(abs(mid - 0.6) < 1e-12)
        // At/after the last point: last value.
        #expect(AutomationSchedule.value(at: 72_000, points: points, cursor: &cursor) == 0.4)
        #expect(AutomationSchedule.value(at: 500_000, points: points, cursor: &cursor) == 0.4)
        // A stale cursor AHEAD of t re-seeks (defensive path) — same answers.
        var stale = 2
        #expect(AutomationSchedule.value(at: 12_345, points: points, cursor: &stale) == 0.2)
        #expect(stale == 0)
        // seek() itself: greatest index with time ≤ t; 0 before the first.
        #expect(AutomationSchedule.seek(points: points, to: -1) == 0)
        #expect(AutomationSchedule.seek(points: points, to: 24_000) == 1)
        #expect(AutomationSchedule.seek(points: points, to: 71_999) == 1)
        #expect(AutomationSchedule.seek(points: points, to: 1_000_000) == 2)
    }

    // MARK: - 2. Offline bounce: analytic per-sample volume ramp

    @Test("offline bounce: volume-ramp lane matches analytic per-sample values (≤1e-6)")
    func offlineBounceVolumeRampMatchesAnalyticPerSample() throws {
        // DC clip at exactly 0.25 for 2 s; ONE linear volume segment 0→1
        // spanning the whole render (beats 0…4 at 120 BPM = 96 000 samples),
        // so every quantum is interior to the segment and the per-quantum
        // ramp is EXACT by design — no breakpoint chording anywhere.
        let url = try writeConstantWAV(value: 0.25, frames: 96_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = Track(
            name: "DC", kind: .audio,
            clips: [Clip(name: "dc", startBeat: 0, lengthBeats: 4, audioFileURL: url)],
            automation: [AutomationLane(target: .volume, points: [
                AutomationPoint(beat: 0, value: 0),
                AutomationPoint(beat: 4, value: 1),
            ])])
        let audio = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 2.0)
        #expect(audio.frameCount == 96_000)
        var maxDiff = 0.0
        for channel in audio.channelData {
            for frame in 0..<channel.count {
                let analytic = 0.25 * Double(frame) / 96_000.0
                maxDiff = max(maxDiff, abs(Double(channel[frame]) - analytic))
            }
        }
        let mid = Double(audio.channelData[0][48_000])
        print("[measured] offline volume ramp: max |out − analytic| \(maxDiff) "
              + "over 2 × 96 000 samples; sample 48 000 = \(mid) (analytic 0.125)")
        #expect(maxDiff < 1e-6)
        #expect(abs(mid - 0.125) < 1e-6)
    }

    // MARK: - 3. Pan-center bit-exact null

    @Test("enabled pan lane sitting at 0 leaves the render bit-identical to no lane")
    func panCenterLaneNullsBitExactAgainstNoLaneRender() throws {
        let fixtures = try TestSignals.fixtures()
        let clip = Clip(name: "cos", startBeat: 0, lengthBeats: 4,
                        audioFileURL: fixtures.cos1k48)
        let plain = Track(name: "A", kind: .audio, clips: [clip])
        var automated = plain
        automated.automation = [AutomationLane(target: .pan, points: [
            AutomationPoint(beat: 0, value: 0),
            AutomationPoint(beat: 4, value: 0),
        ])]
        let a = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: [plain], tempoMap: TempoMap(constantBPM: 120), durationSeconds: 1.0)
        let b = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: [automated], tempoMap: TempoMap(constantBPM: 120), durationSeconds: 1.0)
        #expect(a.frameCount == b.frameCount)
        let diffs = bitDiffCount(a, b)
        let peak = a.channelData.flatMap { $0 }.map(abs).max() ?? 0
        print("[measured] pan-center null: \(diffs) differing bit patterns across "
              + "\(a.frameCount) × 2 samples (signal peak \(peak) — a real render, not silence)")
        #expect(diffs == 0)     // the center short-circuit skips the multiply entirely
        #expect(peak > 0.4)     // and the null is over actual signal
    }

    // MARK: - 4. Fader override while rolling

    @Test("volume lane overrides the fader while rolling: mixer pinned to 1/0, audible level follows the lane")
    func volumeLaneOverridesFaderWhileRolling() throws {
        // (a) Mixer pin. Stopped: WYSIWYG preview of the lane, not the fader.
        // Rolling: pinned to 1 (or 0 when mute-gated) — the render stage owns
        // the gain, and no mixer property moves during playback.
        let rampLane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 0.3),
            AutomationPoint(beat: 4, value: 0.9),
        ])
        let track = Track(name: "T", kind: .audio, volume: 0.25, automation: [rampLane])
        let muted = Track(name: "M", kind: .audio, volume: 0.8, isMuted: true,
                          automation: [rampLane])
        let (_, graph) = try makeGraph(tracks: [track, muted], playheadBeat: 2)
        let mixer = try #require(graph.stripMixer(forTrack: track.id))
        let mutedMixer = try #require(graph.stripMixer(forTrack: muted.id))
        #expect(abs(mixer.outputVolume - 0.6) < 1e-6)  // lane @ beat 2, not the 0.25 fader
        #expect(mutedMixer.outputVolume == 0)          // mute wins while stopped too
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))
        graph.startAllPlayers(at: nil)
        #expect(mixer.outputVolume == 1)               // pinned — lane gain is render-side
        #expect(mutedMixer.outputVolume == 0)          // gated pin
        #expect(graph.automationRenderer(forTrack: track.id)?.currentSchedule != nil)
        graph.stopAllPlayers()
        // Stop unpublishes; the next parameter pass restores WYSIWYG.
        #expect(graph.automationRenderer(forTrack: track.id)?.currentSchedule == nil)
        graph.applyParameters(tracks: [track, muted], playheadBeat: 2)
        #expect(abs(mixer.outputVolume - 0.6) < 1e-6)

        // (b) Audible level. Fader 0.25 with a constant-1 lane renders
        // BIT-IDENTICAL to fader 1 with no lane (whole-quantum unity skips
        // the multiply); a muted track with the same lane renders exact 0.
        let fixtures = try TestSignals.fixtures()
        let clip = Clip(name: "cos", startBeat: 0, lengthBeats: 4,
                        audioFileURL: fixtures.cos1k48)
        let unityLane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 1),
            AutomationPoint(beat: 4, value: 1),
        ])
        let reference = Track(name: "Ref", kind: .audio, volume: 1, clips: [clip])
        let overridden = Track(name: "Ovr", kind: .audio, volume: 0.25, clips: [clip],
                               automation: [unityLane])
        let mutedLane = Track(name: "Mut", kind: .audio, volume: 0.8, isMuted: true,
                              clips: [clip], automation: [unityLane])
        let renderer = OfflineRenderer(sampleRate: Self.sampleRate)
        let ref = try renderer.render(tracks: [reference], tempoMap: TempoMap(constantBPM: 120), durationSeconds: 0.5)
        let ovr = try renderer.render(tracks: [overridden], tempoMap: TempoMap(constantBPM: 120), durationSeconds: 0.5)
        let mut = try renderer.render(tracks: [mutedLane], tempoMap: TempoMap(constantBPM: 120), durationSeconds: 0.5)
        let overrideDiffs = bitDiffCount(ref, ovr)
        let mutedPeak = mut.channelData.flatMap { $0 }.map(abs).max() ?? -1
        print("[measured] fader override: fader-0.25+lane-1 vs fader-1-no-lane → "
              + "\(overrideDiffs) differing bit patterns; muted+lane peak \(mutedPeak)")
        #expect(overrideDiffs == 0)   // the lane, not the fader, set the level
        #expect(mutedPeak == 0)       // gate pin: silence despite the lane
    }

    // MARK: - 5. Stopped WYSIWYG

    @Test("stopped: applyParameters previews lane value(atBeat: playhead) on the mixer")
    func stoppedApplyParametersPreviewsLaneAtPlayhead() throws {
        let volLane = AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 0),
            AutomationPoint(beat: 2, value: 1),
        ])
        let panLane = AutomationLane(target: .pan, points: [
            AutomationPoint(beat: 0, value: -0.5),
        ])
        var track = Track(name: "W", kind: .audio, volume: 0.7, pan: 0.25,
                          automation: [volLane, panLane])
        let (_, graph) = try makeGraph(tracks: [track], playheadBeat: 1)
        let mixer = try #require(graph.stripMixer(forTrack: track.id))
        #expect(abs(mixer.outputVolume - 0.5) < 1e-6)  // midpoint of the 0→1 segment
        #expect(mixer.pan == -0.5)                     // lane preview, not the 0.25 knob
        graph.applyParameters(tracks: [track], playheadBeat: 5)  // past the last point
        #expect(mixer.outputVolume == 1)
        graph.applyParameters(tracks: [track], playheadBeat: 0)
        #expect(mixer.outputVolume == 0)
        // Disabled lanes are inert — the manual fader/pan values rule.
        track.automation = [
            AutomationLane(target: .volume, points: volLane.points, isEnabled: false),
            AutomationLane(target: .pan, points: panLane.points, isEnabled: false),
        ]
        graph.applyParameters(tracks: [track], playheadBeat: 1)
        #expect(abs(mixer.outputVolume - 0.7) < 1e-7)
        #expect(mixer.pan == 0.25)
    }

    // MARK: - 6. Mid-playback republish re-seek

    @Test("mid-playback republish: the render cursor lands on the correct new segment")
    func midPlaybackRepublishReseeksToCorrectSegment() throws {
        // (a) Render surface, LIVE mode: quanta advance on the host timeline,
        // then the schedule is REPLACED mid-timeline (a point edit during
        // playback). The next quantum must evaluate the NEW schedule at the
        // CURRENT transport position — segment 2, value 0.75 — not restart at
        // its first point (0.1).
        let anchor: UInt64 = 1 << 32
        let renderer = AutomationRenderer()
        renderer.publish(AutomationSchedule(
            generation: 1, mode: .live(anchorHostTime: anchor), sampleRate: Self.sampleRate,
            volumePoints: [
                AutomationBreakpoint(sampleTime: 0, value: 0.25, holdsSegment: true),
                AutomationBreakpoint(sampleTime: 96_000, value: 0.25, holdsSegment: false),
            ],
            panPoints: []))
        let out0 = try applyQuantum(renderer, frames: 512,
                                    timestamp: liveTimestamp(anchor: anchor, sample: 0).ts)
        #expect(out0[0].allSatisfy { $0 == 0.25 })
        let out1 = try applyQuantum(renderer, frames: 512,
                                    timestamp: liveTimestamp(anchor: anchor, sample: 512).ts)
        #expect(out1[0].allSatisfy { $0 == 0.25 })

        renderer.publish(AutomationSchedule(
            generation: 2, mode: .live(anchorHostTime: anchor), sampleRate: Self.sampleRate,
            volumePoints: [
                AutomationBreakpoint(sampleTime: 0, value: 0.1, holdsSegment: true),
                AutomationBreakpoint(sampleTime: 24_000, value: 0.75, holdsSegment: true),
                AutomationBreakpoint(sampleTime: 96_000, value: 0.75, holdsSegment: false),
            ],
            panPoints: []))
        let (ts2, start2) = liveTimestamp(anchor: anchor, sample: 48_000)
        let out2 = try applyQuantum(renderer, frames: 512, timestamp: ts2)
        print("[measured] republish re-seek: quantum at schedule sample \(start2) after the "
              + "generation swap reads \(out2[0][0]) (new segment 2 holds 0.75; "
              + "a timeline restart would read 0.1)")
        #expect(out2[0].allSatisfy { $0 == 0.75 })
        // Defensive stale-cursor path: a quantum BEHIND the cursor re-seeks too.
        let out3 = try applyQuantum(renderer, frames: 512,
                                    timestamp: liveTimestamp(anchor: anchor, sample: 12_000).ts)
        #expect(out3[0].allSatisfy { $0 == Float(0.1) })

        // (b) Engine path: an automation edit during playback republishes the
        // strip's schedule against the SAME live anchor with a bumped
        // generation and the new breakpoints — exactly the inputs (a) proved
        // the render side re-seeks on.
        let hostAnchor = mach_absolute_time()
        var track = Track(name: "L", kind: .audio, automation: [
            AutomationLane(target: .volume, points: [
                AutomationPoint(beat: 0, value: 0.25, curve: .hold),
                AutomationPoint(beat: 2, value: 0.25),
            ]),
        ])
        let (_, graph) = try makeGraph(tracks: [track])
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))
        graph.startAllPlayers(at: AVAudioTime(hostTime: hostAnchor))
        let head = try #require(graph.automationRenderer(forTrack: track.id))
        let before = try #require(head.currentSchedule)
        if case .live(let anchorBefore) = before.mode {
            #expect(anchorBefore == hostAnchor)
        } else {
            Issue.record("expected a .live schedule after a live start")
        }
        track.automation = [AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 0.1, curve: .hold),
            AutomationPoint(beat: 0.5, value: 0.75, curve: .hold),
            AutomationPoint(beat: 2, value: 0.75),
        ])]
        graph.applyParameters(tracks: [track], playheadBeat: 1)   // setAutomationPoints lands here
        let after = try #require(head.currentSchedule)
        #expect(after.generation > before.generation)
        if case .live(let anchorAfter) = after.mode {
            #expect(anchorAfter == hostAnchor)   // same anchor: same timeline, only re-seek
        } else {
            Issue.record("republish must preserve the live mode/anchor")
        }
        #expect(Array(after.volumePoints) == [
            AutomationBreakpoint(sampleTime: 0, value: 0.1, holdsSegment: true),
            AutomationBreakpoint(sampleTime: 12_000, value: 0.75, holdsSegment: true),
            AutomationBreakpoint(sampleTime: 48_000, value: 0.75, holdsSegment: false),
        ])
        graph.stopAllPlayers()
    }

    // MARK: - 7. No-restart guard

    @Test("no-restart guard: player/MIDI schedule generations survive an automation edit during playback")
    func automationEditDuringPlaybackLeavesSchedulesUntouched() throws {
        let fixtures = try TestSignals.fixtures()
        var audio = Track(
            name: "A", kind: .audio,
            clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4,
                         audioFileURL: fixtures.cos1k48)],
            automation: [AutomationLane(target: .volume, points: [
                AutomationPoint(beat: 0, value: 0.5),
                AutomationPoint(beat: 4, value: 1),
            ])])
        let inst = Track(
            name: "I", kind: .instrument,
            clips: [Clip(name: "m", startBeat: 0, lengthBeats: 4,
                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])])
        let (engine, graph) = try makeGraph(tracks: [audio, inst])
        try engine.start()
        graph.applyParameters(tracks: [audio, inst])   // post-start pass, AudioEngine order
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))
        graph.startAllPlayers(at: nil)
        let midiRenderer = try #require(graph.instrumentRenderer(forTrack: inst.id))
        let midiBefore = try #require(midiRenderer.currentSchedule)
        let autoBefore = try #require(
            graph.automationRenderer(forTrack: audio.id)?.currentSchedule)

        audio.automation = [AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 0.2),
            AutomationPoint(beat: 4, value: 0.9),
        ])]
        // AudioEngine.tracksDidChange order: reconcile first (must see NO
        // structural change — automation is in no reconcile signature), then
        // the parameter pass republishes the strip's schedule in place.
        #expect(graph.reconcile(tracks: [audio, inst]) == false)
        graph.applyParameters(tracks: [audio, inst], playheadBeat: 1)

        let midiAfter = try #require(midiRenderer.currentSchedule)
        #expect(midiAfter === midiBefore)                          // same published object
        #expect(midiAfter.generation == midiBefore.generation)     // no reschedule
        let autoAfter = try #require(
            graph.automationRenderer(forTrack: audio.id)?.currentSchedule)
        #expect(autoAfter.generation > autoBefore.generation)      // only automation moved
        print("[measured] no-restart: MIDI schedule generation \(midiBefore.generation) → "
              + "\(midiAfter.generation) (identical object: \(midiAfter === midiBefore)); "
              + "automation generation \(autoBefore.generation) → \(autoAfter.generation)")
        graph.stopAllPlayers()
        engine.stop()
    }

    // MARK: - 8. Live/offline equivalence

    @Test("live and offline modes produce the same analytic gain/pan trajectory")
    func liveAndOfflineRendererPathsMatchAnalytic() throws {
        // Same lane set both modes: ONE linear volume segment 0→1 across
        // 96 000 samples plus a constant pan of 0.5. Offline latches a
        // NONZERO first-pull epoch (schedule t=0 ≡ first pulled sample); live
        // maps host ticks against the anchor. Both are held to the same
        // analytic curve; live quantum starts are derived with the renderer's
        // own tick math, so host-tick granularity cannot loosen the bound.
        let volumePoints = [
            AutomationBreakpoint(sampleTime: 0, value: 0, holdsSegment: false),
            AutomationBreakpoint(sampleTime: 96_000, value: 1, holdsSegment: false),
        ]
        let panPoints = [
            AutomationBreakpoint(sampleTime: 0, value: 0.5, holdsSegment: false),
        ]
        let theta = (0.5 + 1) * Double.pi / 4
        let gainL = 2.0.squareRoot() * cos(theta)
        let gainR = 2.0.squareRoot() * sin(theta)
        let total = 24_576
        let chunk = 512

        let offline = AutomationRenderer()
        offline.publish(AutomationSchedule(
            generation: 1, mode: .offline, sampleRate: Self.sampleRate,
            volumePoints: volumePoints, panPoints: panPoints))
        var offlineOut: [[Float]] = [[], []]
        var pos = 0
        while pos < total {
            let frames = min(chunk, total - pos)
            let out = try applyQuantum(offline, frames: frames,
                                       timestamp: offlineTimestamp(sample: Double(1_000 + pos)))
            offlineOut[0] += out[0]
            offlineOut[1] += out[1]
            pos += frames
        }

        let anchor: UInt64 = 1 << 33
        let live = AutomationRenderer()
        live.publish(AutomationSchedule(
            generation: 1, mode: .live(anchorHostTime: anchor), sampleRate: Self.sampleRate,
            volumePoints: volumePoints, panPoints: panPoints))
        var liveOut: [[Float]] = [[], []]
        var liveStarts: [Int64] = []
        pos = 0
        while pos < total {
            let frames = min(chunk, total - pos)
            let (ts, start) = liveTimestamp(anchor: anchor, sample: Int64(pos))
            liveStarts.append(start)
            let out = try applyQuantum(live, frames: frames, timestamp: ts)
            liveOut[0] += out[0]
            liveOut[1] += out[1]
            pos += frames
        }

        func analyticDiff(_ output: [[Float]], scheduleSample: (Int) -> Double) -> Double {
            var maxDiff = 0.0
            for index in 0..<total {
                let gain = scheduleSample(index) / 96_000.0
                maxDiff = max(maxDiff, abs(Double(output[0][index]) - gain * gainL))
                maxDiff = max(maxDiff, abs(Double(output[1][index]) - gain * gainR))
            }
            return maxDiff
        }
        let offlineDiff = analyticDiff(offlineOut) { Double($0) }
        let liveDiff = analyticDiff(liveOut) { index in
            Double(liveStarts[index / chunk]) + Double(index % chunk)
        }
        var crossDiff: Float = 0
        for channel in 0..<2 {
            for index in 0..<total {
                crossDiff = max(crossDiff, abs(liveOut[channel][index] - offlineOut[channel][index]))
            }
        }
        print("[measured] live/offline equivalence over \(total) samples: "
              + "offline |out − analytic| ≤ \(offlineDiff), live ≤ \(liveDiff), "
              + "live-vs-offline ≤ \(crossDiff)")
        #expect(offlineDiff < 1e-6)   // linear segment: exact by design
        #expect(liveDiff < 1e-6)      // same, on the host-tick-derived positions
        // Host-tick granularity can shift a live quantum ≤ 1 frame; the ramp
        // slope is 1/96 000 ≈ 1.04e-5 per frame — the only slack allowed.
        #expect(crossDiff < 2e-5)
    }
}
