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

    // MARK: - m39-e — the modulation takeover stage (P2)
    //
    // ⚠️ These live in THIS suite rather than a new one on purpose. The
    // `MainActorOccupancySiteTests` Leg C census is AT its 380 cap with zero
    // slack and its validating campaign is unrunnable; a new `@MainActor`
    // suite would force a fourth unbacked bump. `AutomationRenderer.apply` is
    // exactly this suite's subject — the modulation stage is a branch inside
    // it — so this is the honest home, not a hiding place.

    /// Builds a publishable snapshot straight from the domain model, through
    /// the same builder `PlaybackGraph.applyParameters` uses.
    private func modulationSnapshot(
        sources: [ModulationSource], routes: [ModulationRoute],
        baseVolume: Double = 1, basePan: Double = 0,
        effects: [EffectDescriptor] = [], originSample: Int64 = 0,
        positionValid: Bool = true, generation: UInt64 = 1
    ) -> ModulationSnapshot? {
        ModulationSnapshotBuilder.build(
            strip: ModulationSnapshotBuilder.Strip(
                sources: sources, routes: routes, effects: effects,
                baseVolume: baseVolume, basePan: basePan),
            generation: generation, timelineID: 1, sampleRate: Self.sampleRate,
            originSample: originSample, positionValid: positionValid)
    }

    /// The ANCHOR-ONLY schedule a strip gets when its only automation is a
    /// modulation route: no points, just the position mapping.
    private func anchorSchedule(generation: UInt64 = 1) -> AutomationSchedule {
        AutomationSchedule(generation: generation, mode: .offline,
                           sampleRate: Self.sampleRate,
                           volumePoints: [], panPoints: [])
    }

    /// ⭐⭐ THE SINGLE MOST VALUABLE TEST IN THE CONTRACT'S LIST (§11.2 test 2).
    ///
    /// A ZERO-DEPTH route must render BIT-IDENTICALLY to no route at all. It
    /// proves the takeover stage reproduces the automation stage's arithmetic
    /// exactly, which is the one place a silent tonal regression could hide:
    /// `√2·cos(π/4)` is NOT bit-exactly 1.0, so a stage that "multiplied by
    /// unity" at centre pan would move the last bit of every sample.
    ///
    /// ITS OWN CONTROL IS BUILT IN: depth 1e-6 must DIFFER. A bit-comparison
    /// that has never failed is indistinguishable from one that compares
    /// nothing.
    @Test("⭐ m39-e: a ZERO-DEPTH route on volume AND pan is bit-identical to no route — control: 1e-6 differs")
    func zeroDepthRouteIsBitIdenticalToNoRoute() throws {
        let frames = 512
        let noRoute = AutomationRenderer()
        noRoute.publish(anchorSchedule())
        let baseline = try applyQuantum(noRoute, frames: frames,
                                        timestamp: offlineTimestamp(sample: 0))

        let lfo = ModulationSource(kind: .lfo,
                                   params: .lfo(LFOSourceParams(waveform: .sine, rateHz: 5)))
        func render(depth: Double) throws -> [[Float]] {
            let renderer = AutomationRenderer()
            renderer.publish(anchorSchedule())
            renderer.publishModulation(modulationSnapshot(
                sources: [lfo],
                routes: [ModulationRoute(sourceID: lfo.id, target: .volume, depth: depth),
                         ModulationRoute(sourceID: lfo.id, target: .pan, depth: depth)]))
            return try applyQuantum(renderer, frames: frames,
                                    timestamp: offlineTimestamp(sample: 0))
        }

        let zero = try render(depth: 0)
        var differingAtZero = 0
        for channel in 0..<2 {
            for frame in 0..<frames
            where zero[channel][frame].bitPattern != baseline[channel][frame].bitPattern {
                differingAtZero += 1
            }
        }
        let tiny = try render(depth: 1e-6)
        var differingAtTiny = 0
        for channel in 0..<2 {
            for frame in 0..<frames
            where tiny[channel][frame].bitPattern != baseline[channel][frame].bitPattern {
                differingAtTiny += 1
            }
        }
        print("[measured] m39-e zero-depth identity: depth 0 → \(differingAtZero) differing "
              + "bit patterns of \(frames * 2); depth 1e-6 → \(differingAtTiny)")
        #expect(differingAtZero == 0)
        #expect(differingAtTiny > 0,
                "the CONTROL: if a 1e-6 depth changes nothing, this comparison compares nothing")
    }

    /// ⭐ §3.2 — POSITION-ABSOLUTE DETERMINISM, the test that catches someone
    /// "optimising" the evaluator with a phase register.
    ///
    /// Render a span in one pass, and render its TAIL from a fresh renderer
    /// after a seek. The overlapping samples must be BIT-EXACT: every source
    /// is a function of the transport position, so a seek lands on exactly the
    /// value a full playthrough would have had.
    @Test("⭐ m39-e §3.2: a SEEK lands bit-exactly where a full playthrough would have — no phase register")
    func positionAbsoluteDeterminismAcrossASeek() throws {
        let frames = 512
        // ⚠️ AUTHORED THE IDIOMATIC WAY ON PURPOSE (§7.3): unipolar source,
        // attenuation-only depth. A BIPOLAR source at this depth saturates
        // `Track.volumeRange`'s +6.02 dB ceiling at BOTH positions, and two
        // saturated values are equal — which silently disarms this test's own
        // control. Measured: the control read 0 differing samples until the
        // fixture stopped clipping.
        let lfo = ModulationSource(
            kind: .lfo, params: .lfo(LFOSourceParams(waveform: .sawUp, rateHz: 3.7,
                                                     phaseDeg: 40, bipolar: false)))
        let route = ModulationRoute(sourceID: lfo.id, target: .volume, depth: -0.4)

        // Pass A — four contiguous quanta from the project start.
        let whole = AutomationRenderer()
        whole.publish(anchorSchedule())
        whole.publishModulation(modulationSnapshot(sources: [lfo], routes: [route],
                                                   originSample: 0))
        var passA: [[Float]] = []
        for quantum in 0..<4 {
            passA.append(try applyQuantum(
                whole, frames: frames,
                timestamp: offlineTimestamp(sample: Double(quantum * frames)))[0])
        }

        // Pass B — a fresh renderer SEEKED to quantum 2. Its schedule epoch
        // latches at its own first pull, so the roll-relative position starts
        // at 0 again; `originSample` is what makes the SOURCE agree.
        let seeked = AutomationRenderer()
        seeked.publish(anchorSchedule(generation: 2))
        seeked.publishModulation(modulationSnapshot(
            sources: [lfo], routes: [route],
            originSample: Int64(2 * frames), generation: 2))
        var passB: [[Float]] = []
        for quantum in 0..<2 {
            passB.append(try applyQuantum(
                seeked, frames: frames,
                timestamp: offlineTimestamp(sample: Double(quantum * frames)))[0])
        }

        var differing = 0
        for quantum in 0..<2 {
            for frame in 0..<frames
            where passA[quantum + 2][frame].bitPattern != passB[quantum][frame].bitPattern {
                differing += 1
            }
        }
        print("[measured] m39-e seek determinism: \(differing) differing bit patterns of "
              + "\(frames * 2) across the seek")
        #expect(differing == 0)
        // Control: without the origin the seeked pass restarts the phase, and
        // the comparison MUST redden — otherwise it is comparing nothing.
        let unanchored = AutomationRenderer()
        unanchored.publish(anchorSchedule(generation: 3))
        unanchored.publishModulation(modulationSnapshot(
            sources: [lfo], routes: [route], originSample: 0, generation: 3))
        let restarted = try applyQuantum(unanchored, frames: frames,
                                         timestamp: offlineTimestamp(sample: 0))[0]
        var restartedDiffering = 0
        for frame in 0..<frames
        where passA[2][frame].bitPattern != restarted[frame].bitPattern {
            restartedDiffering += 1
        }
        #expect(restartedDiffering > 0,
                Comment(rawValue: "the CONTROL: a phase that restarted at the seek MUST "
                    + "differ from the playthrough, or this test cannot detect a phase "
                    + "register"))
    }

    /// §3.2's DECLARED EXCEPTION, asserted rather than assumed: the same seek
    /// test on an `envelopeFollower` route must FAIL. A determinism test that
    /// passes for every source is a broken test.
    @Test("m39-e §3.2: the envelopeFollower is the ONE source a seek does NOT reproduce")
    func followerIsTheDeclaredNonDeterministicException() throws {
        let frames = 512
        let follower = ModulationSource(
            kind: .envelopeFollower,
            params: .envelopeFollower(EnvelopeFollowerSourceParams(
                detector: .peak, attackMs: 40, releaseMs: 200, floorDb: -60)))
        let route = ModulationRoute(sourceID: follower.id, target: .volume, depth: -0.5)

        func render(quanta: Int, generation: UInt64) throws -> [Float] {
            let renderer = AutomationRenderer()
            renderer.publish(anchorSchedule(generation: generation))
            renderer.publishModulation(modulationSnapshot(
                sources: [follower], routes: [route], generation: generation))
            var last: [Float] = []
            for quantum in 0..<quanta {
                last = try applyQuantum(
                    renderer, frames: frames,
                    timestamp: offlineTimestamp(sample: Double(quantum * frames)))[0]
            }
            return last
        }
        let warmed = try render(quanta: 4, generation: 10)      // detector caught up
        let cold = try render(quanta: 1, generation: 11)        // started here
        var differing = 0
        for frame in 0..<frames where warmed[frame].bitPattern != cold[frame].bitPattern {
            differing += 1
        }
        print("[measured] m39-e follower non-determinism: \(differing) differing bit "
              + "patterns of \(frames) between a warmed and a cold detector")
        #expect(differing > 0,
                Comment(rawValue: "the follower is DECLARED history-dependent; if a partial "
                    + "render matched a full one, the detector is not running at all"))
    }

    /// §7.3 — summation order is the PUBLISHED ROUTE ARRAY ORDER. Float
    /// addition is not associative, so an unspecified order would make a
    /// render non-reproducible. Same routes, same order → bit-exact.
    @Test("m39-e §7.3: three routes on one target sum in the published array order, bit-exactly")
    func summationOrderIsPinned() throws {
        let frames = 256
        let a = ModulationSource(kind: .lfo,
                                 params: .lfo(LFOSourceParams(waveform: .sine, rateHz: 1.3)))
        let b = ModulationSource(kind: .lfo,
                                 params: .lfo(LFOSourceParams(waveform: .triangle, rateHz: 7.1)))
        let c = ModulationSource(kind: .macro, params: .macro(MacroSourceParams(value: 0.37)))
        let depths = [-0.31, -0.17, -0.23]
        func render(order: [Int], generation: UInt64) throws -> [Float] {
            let sources = [a, b, c]
            let routes = order.map {
                ModulationRoute(sourceID: sources[$0].id, target: .volume, depth: depths[$0])
            }
            let renderer = AutomationRenderer()
            renderer.publish(anchorSchedule(generation: generation))
            renderer.publishModulation(modulationSnapshot(
                sources: sources, routes: routes, baseVolume: 0.8, generation: generation))
            return try applyQuantum(renderer, frames: frames,
                                    timestamp: offlineTimestamp(sample: 0))[0]
        }
        let forward = try render(order: [0, 1, 2], generation: 20)
        let again = try render(order: [0, 1, 2], generation: 21)
        for frame in 0..<frames {
            #expect(forward[frame].bitPattern == again[frame].bitPattern,
                    "the SAME order must reproduce bit-exactly")
        }
        // The order is load-bearing, not incidental: a different array order
        // is a different (legal) sum, and the test says so rather than
        // pretending float addition is associative.
        let reversed = try render(order: [2, 1, 0], generation: 22)
        var differing = 0
        for frame in 0..<frames
        where forward[frame].bitPattern != reversed[frame].bitPattern {
            differing += 1
        }
        // Reported, not asserted: three small addends often DO sum identically
        // in any order. The load-bearing assertion is the one above — the
        // PUBLISHED order reproduces bit-exactly, every time.
        print("[measured] m39-e summation order: reordering three routes moved "
              + "\(differing) of \(frames) bit patterns")
    }

    /// ⚠️ THE SINGLE MOST LIKELY IMPLEMENTATION BUG IN THE CONTRACT (§7.3):
    /// applying the knob TWICE. The stage carries the base because the mixer
    /// node has been neutralised; a stage that multiplied on top of the node
    /// would square it.
    @Test("⚠️ m39-e §7.3: the stage carries the base ONCE — a 0.5 fader with a neutral route is 0.5, not 0.25")
    func theKnobIsNotAppliedTwice() throws {
        let frames = 64
        let macro = ModulationSource(kind: .macro, params: .macro(MacroSourceParams(value: 0)))
        let renderer = AutomationRenderer()
        renderer.publish(anchorSchedule())
        renderer.publishModulation(modulationSnapshot(
            sources: [macro],
            routes: [ModulationRoute(sourceID: macro.id, target: .volume, depth: -1)],
            baseVolume: 0.5))
        let out = try applyQuantum(renderer, frames: frames,
                                   timestamp: offlineTimestamp(sample: 0))
        print("[measured] m39-e base-once: fader 0.5, macro 0 at depth -1 → \(out[0][0])")
        #expect(out[0][0] == 0.5, "0.25 would mean the knob was applied twice")
        #expect(out[1][0] == 0.5)
    }

    /// §7.8 — STOPPED TRANSPORT. There is no schedule, so there is no
    /// position: `lfo` and `stepSequencer` hold NEUTRAL while `macro` keeps
    /// ruling. This is the workflow an agent uses to dial a sound in before
    /// pressing play, and tidying the snapshot's lifecycle into symmetry with
    /// the schedule's would silently kill it.
    @Test("m39-e §7.8: stopped — a macro still rules the fader, an LFO holds neutral")
    func stoppedTransportKeepsMacrosLiveAndHoldsPositionSourcesNeutral() throws {
        let frames = 64
        let macro = ModulationSource(kind: .macro, params: .macro(MacroSourceParams(value: 1)))
        let lfo = ModulationSource(kind: .lfo,
                                   params: .lfo(LFOSourceParams(waveform: .sine, rateHz: 5)))
        // No schedule published at all — the stopped state.
        let macroRenderer = AutomationRenderer()
        macroRenderer.publishModulation(modulationSnapshot(
            sources: [macro],
            routes: [ModulationRoute(sourceID: macro.id, target: .volume, depth: -0.25)],
            baseVolume: 1, positionValid: false))
        let macroOut = try applyQuantum(macroRenderer, frames: frames,
                                        timestamp: offlineTimestamp(sample: 0))
        let expected = Float(ModulationDepthLaw.volumeGain(base: 1, sum: -0.25))
        print("[measured] m39-e stopped macro: \(macroOut[0][0]) (expected \(expected))")
        #expect(abs(macroOut[0][0] - expected) < 1e-6)
        // depth -0.25 × the 48 dB full-scale window = exactly -12 dB.
        let macroDb = 20 * log10(Double(macroOut[0][0]))
        #expect(abs(macroDb + 12) < 0.01, Comment(rawValue: "measured \(macroDb) dB"))

        let lfoRenderer = AutomationRenderer()
        lfoRenderer.publishModulation(modulationSnapshot(
            sources: [lfo],
            routes: [ModulationRoute(sourceID: lfo.id, target: .volume, depth: -1)],
            baseVolume: 1, positionValid: false))
        let lfoOut = try applyQuantum(lfoRenderer, frames: frames,
                                      timestamp: offlineTimestamp(sample: 0))
        // Neutral (0 offset) → the fader sits at its knob value, bit-exactly,
        // so a stopped strip sounds like its knobs.
        for frame in 0..<frames {
            #expect(lfoOut[0][frame] == 1.0, "an LFO with no transport position must hold neutral")
        }
    }

    /// §7.2.0's polarity convention, measured on the RENDER path rather than
    /// only asserted in the depth law: `[1, 0, 1, 0]` under the mandatory
    /// negative depth gates the DOWNBEAT silent, and `[0, 1, 0, 1]` opens on it.
    @Test("m39-e §7.2.0: the step-gate polarity is what the amendment says it is, in rendered samples")
    func stepGatePolarityIsMeasuredNotAssumed() throws {
        let frames = 64
        func firstSample(steps: [Double], generation: UInt64) throws -> Float {
            let source = ModulationSource(
                kind: .stepSequencer,
                params: .stepSequencer(StepSequencerSourceParams(steps: steps, rateHz: 4,
                                                                 edgeMs: 0)))
            let renderer = AutomationRenderer()
            renderer.publish(anchorSchedule(generation: generation))
            renderer.publishModulation(modulationSnapshot(
                sources: [source],
                routes: [ModulationRoute(sourceID: source.id, target: .volume, depth: -1)],
                generation: generation))
            return try applyQuantum(renderer, frames: frames,
                                    timestamp: offlineTimestamp(sample: 0))[0][0]
        }
        let obvious = try firstSample(steps: [1, 0, 1, 0], generation: 30)
        let corrected = try firstSample(steps: [0, 1, 0, 1], generation: 31)
        print("[measured] m39-e step polarity — [1,0,1,0] downbeat = \(obvious), "
              + "[0,1,0,1] downbeat = \(corrected)")
        #expect(obvious < 0.01, "[1,0,1,0] CLOSES on the downbeat — the amendment's point")
        #expect(corrected == 1.0, "[0,1,0,1] is OPEN on the downbeat, bit-exactly the knob")
    }


    // MARK: - m39-e RT-safety: ABSOLUTE ZERO heap allocation on the stage
    //
    // The `InsertSpectrumChainTests` probe, verbatim: `malloc_logger` is
    // libmalloc's hook behind `MallocStackLogging`/`leaks`, resolved with
    // `dlsym` so no C shim is needed. It fires on EVERY malloc AND free, so a
    // transient allocation is counted twice rather than cancelling out —
    // which is the whole point. Unavailable is a FAILURE, never a skip: a
    // silently absent probe is exactly the vacuity this leg exists to prevent.

    private typealias ModMallocLoggerFn =
        @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Heap cells, NOT Swift stored properties: the hook runs INSIDE malloc
    /// with its locks held, so it must never allocate and never trip a lazy
    /// global initializer.
    private nonisolated(unsafe) static let modEventCount =
        UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private nonisolated(unsafe) static let modWatchedThread =
        UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    private static let modEventHook: ModMallocLoggerFn = { _, _, _, _, _, _ in
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)  // no allocation, safe under malloc
        if tid == AutomationEngineTests.modWatchedThread.pointee {
            AutomationEngineTests.modEventCount.pointee &+= 1
        }
    }

    private static func modMallocLoggerSlot() -> UnsafeMutablePointer<ModMallocLoggerFn?>? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "malloc_logger") else { return nil }
        return raw.assumingMemoryBound(to: ModMallocLoggerFn?.self)
    }

    private static func modMallocEvents(
        slot: UnsafeMutablePointer<ModMallocLoggerFn?>, _ body: () -> Void
    ) -> Int {
        pthread_threadid_np(nil, &modWatchedThread.pointee)
        modEventCount.pointee = 0
        let previous = slot.pointee
        slot.pointee = modEventHook
        body()
        slot.pointee = previous
        return modEventCount.pointee
    }

    /// §3.4 — the modulation stage and evaluator allocate NOTHING on the
    /// render path. Every source kind is exercised in one pass, including the
    /// stateful follower and the step sequencer (whose steps live in the
    /// snapshot's flat pool precisely so no `Array` is touched here), plus the
    /// effect-param store (P3) which walks the target table.
    ///
    /// ⚠️ The `while`-not-`for` law this pins is not style: the measured note
    /// at `EffectChainProcessor.swift:402-412` records that at `-Onone` a
    /// `Range` iteration raises ~2 malloc/free events PER ITERATION inside the
    /// render path. The test suite builds at `-Onone`, so a `for i in 0..<n`
    /// anywhere in the evaluator would light this up in the thousands.
    @Test("⭐ m39-e §3.4: the modulation stage + evaluator raise ZERO malloc/free events per quantum")
    func modulationStageAllocatesNothing() throws {
        let slot = try #require(
            Self.modMallocLoggerSlot(),
            Comment(rawValue: "malloc_logger is unavailable — the probe cannot run, and a "
                + "skipped allocation gate is worse than no gate"))
        let frames = 512
        let lfo = ModulationSource(kind: .lfo,
                                   params: .lfo(LFOSourceParams(waveform: .square, rateHz: 6,
                                                                pulseWidth: 0.3, edgeMs: 4,
                                                                bipolar: false)))
        let hold = ModulationSource(kind: .lfo,
                                    params: .lfo(LFOSourceParams(waveform: .sampleHold,
                                                                 rateHz: 9, edgeMs: 2,
                                                                 bipolar: false, seed: 77)))
        let steps = ModulationSource(
            kind: .stepSequencer,
            params: .stepSequencer(StepSequencerSourceParams(steps: [0, 1, 0.5, 0.25, 1, 0],
                                                             rateHz: 8, edgeMs: 3)))
        let macro = ModulationSource(kind: .macro,
                                     params: .macro(MacroSourceParams(value: 0.6)))
        let follower = ModulationSource(
            kind: .envelopeFollower,
            params: .envelopeFollower(EnvelopeFollowerSourceParams(detector: .rms)))
        let sources = [lfo, hold, steps, macro, follower]
        let routes = sources.map {
            ModulationRoute(sourceID: $0.id, target: .volume, depth: -0.12)
        } + [ModulationRoute(sourceID: lfo.id, target: .pan, depth: 0.4)]

        let renderer = AutomationRenderer()
        renderer.publish(anchorSchedule())
        renderer.publishModulation(try #require(modulationSnapshot(
            sources: sources, routes: routes, baseVolume: 0.7, basePan: -0.2)))

        let buffer = try stereoBuffer(frames: frames, fill: 0.5)
        var ts = offlineTimestamp(sample: 0)
        // WARM-UP outside the probe: first-touch lazy globals, the buffer's own
        // COW, and the Testing framework's machinery are not the subject.
        renderer.apply(bufferList: buffer.mutableAudioBufferList,
                       frameCount: frames, timestamp: &ts)

        var events = 0
        let list = buffer.mutableAudioBufferList
        events = Self.modMallocEvents(slot: slot) {
            var quantum = 0
            while quantum < 8 {
                var stamp = AudioTimeStamp()
                stamp.mSampleTime = Double(quantum * frames)
                stamp.mFlags = .sampleTimeValid
                renderer.apply(bufferList: list, frameCount: frames, timestamp: &stamp)
                quantum += 1
            }
        }
        print("[measured] m39-e allocation probe: \(events) malloc/free events across 8 "
              + "quanta of a 5-source, 6-route strip (volume + pan takeover, follower "
              + "detector, step pool)")
        #expect(events == 0)

        // ⭐ POSITIVE CONTROL: the probe must be able to SEE an allocation, or
        // a zero above means the hook never fired.
        let control = Self.modMallocEvents(slot: slot) {
            var sink: [Int] = []
            var index = 0
            while index < 64 {
                sink.append(index)
                index += 1
            }
            _ = sink.count
        }
        print("[measured] m39-e allocation probe CONTROL: \(control) events from a "
              + "deliberate heap allocation")
        #expect(control > 0, "the probe itself is blind — the zero above proves nothing")
    }

    // MARK: - m39-e: the base the takeover carries must not go stale

    /// ⚠️ The trap this pins. A `.volume` route pins `mixer.outputVolume` to 1
    /// and hands the fader to `ModulationStage`, which multiplies
    /// `base × modulation` with `base` BAKED INTO THE SNAPSHOT. The graph has a
    /// macro fast path that, when the `structural` key is unchanged, stores one
    /// atomic per macro instead of republishing. If `baseVolume` / `basePan`
    /// were excluded from the structural key, a fader move under a live route
    /// would take that fast path and the fader would be DEAD — silently, with
    /// audio still playing at the stale gain.
    ///
    /// So: a base move must break structural equality (no fast path), and a
    /// macro move must NOT (fast path taken). Both directions are asserted,
    /// because only asserting one of them would pass on a key that ignored
    /// everything.
    @Test("m39-e: a fader move under a live route breaks the structural key, a macro move does not")
    func modulationPublishKeySeparatesBaseFromMacro() throws {
        let macro = ModulationSource(kind: .macro, params: .macro(MacroSourceParams(value: 0.25)))
        let route = ModulationRoute(sourceID: macro.id, target: .volume, depth: -0.25)
        func key(baseVolume: Double, basePan: Double = 0,
                 macroValue: Double = 0.25) -> PlaybackGraph.ModulationPublishKey {
            var source = macro
            source.params = .macro(MacroSourceParams(value: macroValue))
            return PlaybackGraph.ModulationPublishKey(
                strip: ModulationSnapshotBuilder.Strip(
                    sources: [source], routes: [route],
                    baseVolume: baseVolume, basePan: basePan),
                originSample: 0, positionValid: false)
        }
        let reference = key(baseVolume: 1)
        let faderMoved = key(baseVolume: 0.5)
        let panMoved = key(baseVolume: 1, basePan: -0.4)
        let macroMoved = key(baseVolume: 1, macroValue: 0.9)

        #expect(reference != faderMoved)
        #expect(reference.structural != faderMoved.structural,
                "a fader move MUST republish — the stage carries the base")
        #expect(reference.structural != panMoved.structural,
                "a pan-knob move MUST republish for the same reason")
        // The fast path, proven to still exist: a macro move differs, but
        // NOT structurally, so the graph stores one atomic instead of
        // rebuilding a snapshot.
        #expect(reference != macroMoved)
        #expect(reference.structural == macroMoved.structural)
    }

    /// And the base actually REACHES the snapshot the render thread reads —
    /// the key test above would pass against a builder that hardcoded 1.0.
    @Test("m39-e: the published snapshot carries the strip's base volume, not a constant")
    func modulationSnapshotCarriesTheBase() throws {
        let macro = ModulationSource(kind: .macro, params: .macro(MacroSourceParams(value: 0)))
        let route = ModulationRoute(sourceID: macro.id, target: .volume, depth: -0.25)
        func baseValue(_ volume: Double) throws -> Double {
            let snapshot = try #require(ModulationSnapshotBuilder.build(
                strip: ModulationSnapshotBuilder.Strip(
                    sources: [macro], routes: [route], baseVolume: volume),
                generation: 1, timelineID: 1, sampleRate: Self.sampleRate,
                originSample: 0, positionValid: false))
            let index = snapshot.volumeTargetIndex
            #expect(index >= 0)
            return snapshot.targets[Int(index)].baseValue
        }
        let unity = try baseValue(1.0)
        let half = try baseValue(0.5)
        print("[measured] m39-e snapshot base volume: 1.0 → \(unity), 0.5 → \(half)")
        #expect(unity == 1.0)
        #expect(half == 0.5)
    }

    // MARK: - m39-e regression: the modulation anchor must survive roll start

    /// ⭐ THE GATE THAT WAS MISSING, and the reason it had to render.
    ///
    /// m39-e shipped with 24 tests that published a `ModulationSnapshot`
    /// STRAIGHT to an `AutomationRenderer`. Every one passed. All of them
    /// tested the stage; none tested the PUBLICATION, and the defect lived in
    /// the publication: `startAllPlayers` rebuilt each strip's schedule from
    /// `activeAutomationLanes` alone, saw a strip with no lanes, and published
    /// NIL — wiping the anchor-only schedule `applyParameters` had just
    /// published. With no schedule the render path takes
    /// `applyModulationWithoutSchedule`, where position-dependent sources hold
    /// NEUTRAL, so an LFO on the fader contributed exactly zero and a gated
    /// render came back BYTE-IDENTICAL to an ungated one — live and offline.
    ///
    /// ⛔ A TEST THAT ONLY CALLS `applyParameters` PASSES BOTH BEFORE AND AFTER
    /// THE FIX: that pass publishes the anchor correctly; roll start is what
    /// destroyed it. This test therefore goes through a real render, which is
    /// the only path that reaches `startAllPlayers`.
    @Test("LFO routed to volume survives roll start and changes the render")
    func volumeModulationSurvivesRollStartInOfflineRender() throws {
        let fixtures = try TestSignals.fixtures()
        let clip = Clip(name: "cos", startBeat: 0, lengthBeats: 4,
                        audioFileURL: fixtures.cos1k48)
        let plain = Track(name: "A", kind: .audio, clips: [clip])

        // A source with NO route: the byte-identity claim at this file's
        // `apply(...)` doc says an unrouted strip is structurally untouched.
        let lfo = ModulationSource(
            kind: .lfo, name: "Gate",
            params: .lfo(LFOSourceParams(waveform: .square, rateHz: 4,
                                         pulseWidth: 0.5, bipolar: false)))
        var sourceOnly = plain
        sourceOnly.modulationSources = [lfo]

        // The same source, now ROUTED to the fader. Unipolar square with a
        // NEGATIVE depth: the high half closes the gate.
        var gated = sourceOnly
        gated.modulationRoutes = [ModulationRoute(sourceID: lfo.id, target: .volume,
                                                  depth: -0.5)]

        let tempo = TempoMap(constantBPM: 120)
        func render(_ track: Track) throws -> RenderedAudio {
            try OfflineRenderer(sampleRate: Self.sampleRate).render(
                tracks: [track], tempoMap: tempo, durationSeconds: 1.0)
        }
        let a = try render(plain)
        let unrouted = try render(sourceOnly)
        let b = try render(gated)

        // POSITIVE CONTROL: this is a real render, not silence — without it a
        // "the two differ" assertion could be satisfied by noise on nothing,
        // and a "bit-identical" one by two silent buffers.
        let peak = a.channelData.flatMap { $0 }.map(abs).max() ?? 0
        #expect(peak > 0.4)

        // An unrouted source changes nothing at all.
        #expect(bitDiffCount(a, unrouted) == 0)

        // THE ASSERTION THE OLD CODE FAILED: routed modulation must reach the
        // render. Pre-fix this was 0 differing samples out of ~96,000.
        let diffs = bitDiffCount(a, b)
        func rms(_ audio: RenderedAudio) -> Double {
            var sum = 0.0, n = 0
            for channel in audio.channelData {
                for sample in channel { sum += Double(sample) * Double(sample); n += 1 }
            }
            return n == 0 ? 0 : (sum / Double(n)).squareRoot()
        }
        let plainRMS = rms(a), gatedRMS = rms(b)
        print("[measured] volume modulation through a real render: \(diffs) differing "
              + "samples, RMS \(plainRMS) -> \(gatedRMS) (peak \(peak))")
        #expect(diffs > 0)
        // A 50%-duty gate at depth -0.5 removes real energy — this fails if the
        // route is present but the sources are holding neutral.
        #expect(gatedRMS < plainRMS * 0.95)
    }

}
