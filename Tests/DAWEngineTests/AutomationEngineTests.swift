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

    // The hook, the counter cells and the process-wide window lock live in
    // `Support/MallocProbe.swift` (m39-test-mallocprobe): one measurement at a time.

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
            MallocProbe.slot(),
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
        events = MallocProbe.events(slot: slot) {
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
        let control = MallocProbe.events(slot: slot) {
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

    /// W9-PLRT review R3: the probe above owns its pan with a modulation route, so it never reaches the knob pan
    /// stage (`applyPan`). This leg publishes `publishStaticPan(0.4)` on a strip with NO pan route, once with no
    /// schedule and once with a volume-only schedule. The count is RECORDED per quantum; zero is asserted, and the
    /// control proves the pan stage actually ran (the audio moved) and the probe can count.
    @Test("W9-PLRT R3: the knob pan stage (publishStaticPan) raises ZERO malloc/free events per quantum")
    func staticPanStageAllocatesNothing() throws {
        let slot = try #require(MallocProbe.slot(),
                                "malloc_logger is unavailable: FAILURE, not a skip")
        let frames = 512
        let quanta = 8
        for withVolumeSchedule in [false, true] {
            let renderer = AutomationRenderer()
            if withVolumeSchedule {
                renderer.publish(AutomationSchedule(
                    generation: 1, mode: .offline, sampleRate: Self.sampleRate,
                    volumePoints: [
                        AutomationBreakpoint(sampleTime: 0, value: 0.2, holdsSegment: false),
                        AutomationBreakpoint(sampleTime: 96_000, value: 0.9, holdsSegment: false),
                    ],
                    panPoints: []))
            }
            renderer.publishStaticPan(0.4)
            let buffer = try stereoBuffer(frames: frames, fill: 0.5)
            let list = buffer.mutableAudioBufferList
            var warm = offlineTimestamp(sample: 0)
            renderer.apply(bufferList: list, frameCount: frames, timestamp: &warm)
            let events = MallocProbe.events(slot: slot) {
                var quantum = 0
                while quantum < quanta {
                    var stamp = AudioTimeStamp()
                    stamp.mSampleTime = Double(quantum * frames)
                    stamp.mFlags = .sampleTimeValid
                    renderer.apply(bufferList: list, frameCount: frames, timestamp: &stamp)
                    quantum += 1
                }
            }
            // Anti-vacuity: the pan stage ran. A 0.4 pan makes the channels differ.
            let channels = UnsafeMutableAudioBufferListPointer(list)
            let left = channels[0].mData?.assumingMemoryBound(to: Float.self)[10] ?? 0
            let right = channels[1].mData?.assumingMemoryBound(to: Float.self)[10] ?? 0
            let label = withVolumeSchedule ? "volume-only schedule" : "no schedule"
            print("[measured] W9-PLRT R3 static pan, \(label): \(events) malloc/free events over \(quanta) quanta "
                  + "(\(Double(events) / Double(quanta)) per quantum); L \(left) R \(right)")
            #expect(left != right, "\(label): the pan stage did not run (L \(left) == R \(right))")
            // FINDING (MEASURED 2026-10-11, W9-PROBE, debug -Onone): 1 024 events per quantum with no schedule and
            // 3 072 with a volume-only schedule (2 per sample per `for … in 0..<n` loop: `applyPan`, plus
            // `applyGainRamp`). W9-PANFIX turned those loops into `while` loops and removed the known-issue
            // wrapper, so a regression goes red here.
            #expect(events == 0, "\(label): static pan raised \(events) malloc/free events over \(quanta) quanta")
        }
        let control = MallocProbe.events(slot: slot) {
            var sink: [Int] = []
            var index = 0
            while index < 64 { sink.append(index); index += 1 }
            _ = sink.count
        }
        #expect(control > 0, "the probe itself is blind: the zeros above prove nothing")
    }

    /// W9-PFRT P3b: the leg above warms once and then HOLDS 0.4, so it measures only `apply` → the knob stage's
    /// CONSTANT arm. This one probes the render-thread paths it does not reach, each with a control that the path RAN:
    ///  (a) `applyKnobStage` (W9-PLRT R4a, the idle drain), with no schedule and with a published volume-only schedule
    ///      (the second runs its atomic load and the borrowed `takeUnretainedValue`);
    ///  (b) `apply`'s no-host-time arm (R4b): a LIVE schedule, quanta stamped without `.hostTimeValid`;
    ///  (c) the knob stage's RAMP arm (`applyPan`'s per-sample cos/sin): the knob moves before EVERY probed quantum;
    ///  (d) the volume lane's two arms (`applyGainRamp`, ramp and flat), knob centred.
    @Test("W9-PFRT P3b: applyKnobStage, the no-host-time arm, the knob ramp and the volume arms raise ZERO malloc/free events")
    func knobStagePathsAllocateNothing() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable: FAILURE, not a skip")
        let frames = 512
        let quanta = 8
        func volumeSchedule(_ mode: AutomationSchedule.Mode, _ from: Double, _ to: Double) -> AutomationSchedule {
            AutomationSchedule(generation: 1, mode: mode, sampleRate: Self.sampleRate,
                               volumePoints: [AutomationBreakpoint(sampleTime: 0, value: from, holdsSegment: false),
                                              AutomationBreakpoint(sampleTime: 96_000, value: to, holdsSegment: false)],
                               panPoints: [])
        }
        func sample(_ list: UnsafeMutablePointer<AudioBufferList>, channel: Int, frame: Int) -> Float {
            UnsafeMutableAudioBufferListPointer(list)[channel].mData?.assumingMemoryBound(to: Float.self)[frame] ?? .nan
        }
        // The knob stage's constant gains at 0.4, the arithmetic `applyPan` uses (same Double ops, same bits).
        let theta = (0.4 + 1) * (Double.pi / 4)
        let gainL = Float(2.0.squareRoot() * cos(theta))
        let gainR = Float(2.0.squareRoot() * sin(theta))
        var heldL: Float = 0.5
        var heldR: Float = 0.5
        var calls = 0
        while calls < quanta + 1 { heldL *= gainL; heldR *= gainR; calls += 1 }   // warm-up + the probed quanta

        // (a) applyKnobStage.
        for withSchedule in [false, true] {
            let renderer = AutomationRenderer()
            if withSchedule { renderer.publish(volumeSchedule(.offline, 0.2, 0.9)) }
            renderer.publishStaticPan(0.4)
            let buffer = try stereoBuffer(frames: frames, fill: 0.5)
            let list = buffer.mutableAudioBufferList
            renderer.applyKnobStage(bufferList: list, frameCount: frames)       // warm-up
            let events = MallocProbe.events(slot: slot) {
                var quantum = 0
                while quantum < quanta {
                    renderer.applyKnobStage(bufferList: list, frameCount: frames)
                    quantum += 1
                }
            }
            let label = withSchedule ? "applyKnobStage, volume-only schedule" : "applyKnobStage, no schedule"
            let left = sample(list, channel: 0, frame: 10), right = sample(list, channel: 1, frame: 10)
            print("[measured] W9-PFRT P3b \(label): \(events) malloc/free events over \(quanta) quanta; L \(left) R \(right)")
            #expect(left == heldL && right == heldR,
                    "\(label): not the knob stage alone at 0.4 (L \(left) R \(right), expected \(heldL) \(heldR))")
            #expect(events == 0, "\(label): \(events) malloc/free events over \(quanta) quanta")
        }

        // (b) apply's no-host-time arm: a LIVE schedule, and no quantum carries a host time.
        do {
            let renderer = AutomationRenderer()
            renderer.publish(volumeSchedule(.live(anchorHostTime: mach_absolute_time()), 0.2, 0.9))
            renderer.publishStaticPan(0.4)
            let buffer = try stereoBuffer(frames: frames, fill: 0.5)
            let list = buffer.mutableAudioBufferList
            var warm = AudioTimeStamp()
            warm.mFlags = .sampleTimeValid
            renderer.apply(bufferList: list, frameCount: frames, timestamp: &warm)
            let events = MallocProbe.events(slot: slot) {
                var quantum = 0
                while quantum < quanta {
                    var stamp = AudioTimeStamp()
                    stamp.mSampleTime = Double(quantum * frames)
                    stamp.mFlags = .sampleTimeValid       // no .hostTimeValid: the quantum cannot be placed
                    renderer.apply(bufferList: list, frameCount: frames, timestamp: &stamp)
                    quantum += 1
                }
            }
            let left = sample(list, channel: 0, frame: 10), right = sample(list, channel: 1, frame: 10)
            print("[measured] W9-PFRT P3b apply, no host time: \(events) malloc/free events over \(quanta) quanta; "
                  + "L \(left) R \(right)")
            // The knob alone, at its constant gains: the arm ran, and the volume lane (which needs a position) did not.
            #expect(left == heldL && right == heldR,
                    "no-host-time arm: not the knob stage alone (L \(left) R \(right), expected \(heldL) \(heldR))")
            #expect(events == 0, "no-host-time arm: \(events) malloc/free events over \(quanta) quanta")
        }

        // (c) the knob stage's ramp arm: the knob moves before every probed quantum (no schedule, no route).
        do {
            let renderer = AutomationRenderer()
            renderer.publishStaticPan(0.4)
            let buffer = try stereoBuffer(frames: frames, fill: 0.5)
            let list = buffer.mutableAudioBufferList
            var warm = offlineTimestamp(sample: 0)
            renderer.apply(bufferList: list, frameCount: frames, timestamp: &warm)
            let events = MallocProbe.events(slot: slot) {
                var quantum = 0
                while quantum < quanta {
                    renderer.publishStaticPan(quantum % 2 == 0 ? -0.3 : 0.4)
                    var stamp = AudioTimeStamp()
                    stamp.mSampleTime = Double((quantum + 1) * frames)
                    stamp.mFlags = .sampleTimeValid
                    renderer.apply(bufferList: list, frameCount: frames, timestamp: &stamp)
                    quantum += 1
                }
            }
            let first = sample(list, channel: 0, frame: 0), last = sample(list, channel: 0, frame: frames - 1)
            print("[measured] W9-PFRT P3b knob ramp: \(events) malloc/free events over \(quanta) quanta; "
                  + "L[0] \(first) L[\(frames - 1)] \(last)")
            // A constant gain leaves a constant buffer constant; only the per-sample ramp makes its ends differ.
            #expect(first != last, "knob ramp: the ramp arm did not run (L[0] == L[last] == \(first))")
            #expect(events == 0, "knob ramp: \(events) malloc/free events over \(quanta) quanta")
        }

        // (d) the volume lane's ramp and flat arms, knob centred.
        for (label, from, to) in [("volume ramp 0.2->0.9", 0.2, 0.9), ("volume flat 0.5", 0.5, 0.5)] {
            let renderer = AutomationRenderer()
            renderer.publish(volumeSchedule(.offline, from, to))
            let buffer = try stereoBuffer(frames: frames, fill: 0.5)
            let list = buffer.mutableAudioBufferList
            var warm = offlineTimestamp(sample: 0)
            renderer.apply(bufferList: list, frameCount: frames, timestamp: &warm)
            let events = MallocProbe.events(slot: slot) {
                var quantum = 0
                while quantum < quanta {
                    var stamp = AudioTimeStamp()
                    stamp.mSampleTime = Double((quantum + 1) * frames)
                    stamp.mFlags = .sampleTimeValid
                    renderer.apply(bufferList: list, frameCount: frames, timestamp: &stamp)
                    quantum += 1
                }
            }
            let first = sample(list, channel: 0, frame: 0), last = sample(list, channel: 0, frame: frames - 1)
            print("[measured] W9-PFRT P3b \(label): \(events) malloc/free events over \(quanta) quanta; "
                  + "L[0] \(first) L[\(frames - 1)] \(last)")
            #expect(first != 0.5, "\(label): the volume stage did not run")
            #expect((first != last) == (from != to), "\(label): the \(from != to ? "ramp" : "flat") arm did not run")
            #expect(events == 0, "\(label): \(events) malloc/free events over \(quanta) quanta")
        }

        let control = MallocProbe.events(slot: slot) {
            var sink: [Int] = []
            var index = 0
            while index < 64 { sink.append(index); index += 1 }
            _ = sink.count
        }
        #expect(control > 0, "the probe itself is blind: the zeros above prove nothing")
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


    // MARK: - m39-w4-4 — the musical clock (W8-W44)
    //
    // ⚠️ APPENDED to this suite on purpose: it is `@MainActor`, it already owns
    // the modulation render gates, and the `MainActorOccupancySiteTests` cap
    // forbids a new `@MainActor` suite. The nonisolated half of the clock's
    // tests (compile, alignment against the MIDI schedule, zero allocation,
    // timing) lives in `ModulationClockTests.swift`.

    /// 120 BPM up to bar 3 (beat 8), 90 BPM after it: the design's G2 map.
    /// Every sixteenth edge on it is a whole sample at 48 kHz (6 000 and 8 000
    /// frames per sixteenth), which is what lets G2 demand exact edges.
    private static func w44TempoMap() throws -> TempoMap {
        try TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 8, bpm: 90)])
    }

    /// A stereo Float32 sine (440 Hz, amplitude 0.5) — a tone, so the
    /// follower follows something real and an effect sees a real signal.
    private func w44SineWAV(seconds: Double) throws -> URL {
        let frames = Int(seconds * Self.sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w44-sine-\(UUID().uuidString).wav")
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
        let buffer = try stereoBuffer(frames: frames, fill: 0)
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            let value = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame) / Self.sampleRate))
            data[0][frame] = value
            data[1][frame] = value
        }
        try file.write(from: buffer)
        return url
    }

    /// The modulation kinds that existed before the clock, plus "none".
    private enum W44Kind: String, CaseIterable {
        case none, stepFree, lfo, follower, macro
    }

    /// One audio track carrying `kind`, routed to the fader (the per-sample
    /// stage) AND to a gain insert's `gainLinear` (the block-rate effect path).
    private func w44AudioTrack(clip url: URL, kind: W44Kind) -> Track {
        let gain = EffectDescriptor(kind: .gain)
        var track = Track(name: "W44 \(kind.rawValue)", kind: .audio,
                          clips: [Clip(name: "tone", startBeat: 0, lengthBeats: 24,
                                       audioFileURL: url)],
                          effects: [gain])
        let source: ModulationSource
        switch kind {
        case .none:
            return track
        case .stepFree:
            source = ModulationSource(kind: .stepSequencer, params: .stepSequencer(
                StepSequencerSourceParams(steps: [1, 0, 0.5, -0.5, 0.25], rateHz: 7.3, edgeMs: 3)))
        case .lfo:
            source = ModulationSource(kind: .lfo, params: .lfo(
                LFOSourceParams(waveform: .sine, rateHz: 3.1, bipolar: false)))
        case .follower:
            source = ModulationSource(kind: .envelopeFollower, params: .envelopeFollower(
                EnvelopeFollowerSourceParams(detector: .peak, attackMs: 10, releaseMs: 120,
                                             floorDb: -60)))
        case .macro:
            source = ModulationSource(kind: .macro, params: .macro(MacroSourceParams(value: 0.6)))
        }
        track.modulationSources = [source]
        track.modulationRoutes = [
            ModulationRoute(sourceID: source.id, target: .volume, depth: -0.4),
            ModulationRoute(sourceID: source.id,
                            target: .effectParam(effectID: gain.id, paramName: "gainLinear"),
                            depth: 0.3),
        ]
        return track
    }

    /// The drum machine with a FREE-RUNNING step source on `openHat.decay`:
    /// the instrument-side latch path (P1), read at note-on.
    private func w44FreeRunningDrumTrack() -> Track {
        var notes: [MIDINote] = []
        var beat = 0.0
        while beat < 16 {
            notes.append(MIDINote(pitch: 39, velocity: 90, startBeat: beat, lengthBeats: 0.25))
            beat += 0.5
        }
        var track = Track(name: "W44 drums", kind: .instrument,
                          clips: [Clip(name: "hats", startBeat: 0, lengthBeats: 16, notes: notes)],
                          instrument: InstrumentDescriptor(kind: .drumSynth))
        let source = ModulationSource(kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: [1, -1, 0.5], rateHz: 5.3, edgeMs: 2)))
        track.modulationSources = [source]
        track.modulationRoutes = [ModulationRoute(
            sourceID: source.id, target: .instrumentParam(paramName: "openHat.decay"), depth: 0.5)]
        return track
    }

    /// A looped roll through the REAL graph machinery, the `L2GraphRig` idiom
    /// verbatim (reconcile → applyParameters → start → applyParameters →
    /// scheduleAll(loop:) → topUp → startAllPlayers), with `topUpLoopCycles`
    /// ticked after every third 512-frame pull — the live playhead cadence.
    private func w44LoopRoll(tracks: [Track], tempoMap: TempoMap, fromBeat: Double,
                             loop: PlaybackGraph.LoopWindow, frames: Int,
                             meterMap: MeterMap? = nil) throws -> [[Float]] {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: tracks))
        graph.applyParameters(tracks: tracks)
        try engine.start()
        defer { engine.stop() }
        graph.applyParameters(tracks: tracks)
        graph.scheduleAll(fromBeat: fromBeat, tempoMap: tempoMap, loop: loop, meterMap: meterMap)
        graph.topUpLoopCycles(elapsedPlayerSeconds: 0, horizonSeconds: 0.2)
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                   frameCapacity: 4_096))
        var out: [[Float]] = [[], []]
        var rendered = 0
        var pulls = 0
        while rendered < frames {
            let request = AVAudioFrameCount(min(frames - rendered, 512))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            let data = try #require(buffer.floatChannelData)
            let count = Int(buffer.frameLength)
            for channel in 0..<2 {
                out[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: count))
            }
            rendered += count
            pulls += 1
            if pulls % 3 == 0 {
                graph.topUpLoopCycles(elapsedPlayerSeconds: Double(rendered) / Self.sampleRate,
                                      horizonSeconds: 0.2)
            }
        }
        return out
    }

    /// FNV-1a 64 over the Float BIT PATTERNS of every channel: the print-side
    /// fingerprint. The gate itself is `cmp` over the raw files.
    private func w44Fingerprint(_ channels: [[Float]]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for channel in channels {
            for sample in channel {
                var bits = sample.bitPattern
                var byte = 0
                while byte < 4 {
                    hash ^= UInt64(bits & 0xff)
                    hash = hash &* 0x0000_0100_0000_01b3
                    bits >>= 8
                    byte += 1
                }
            }
        }
        return hash
    }

    /// Writes `channels` as raw little-endian Float32, channel after channel.
    private func w44WriteRaw(_ channels: [[Float]], to url: URL) throws {
        var data = Data()
        for channel in channels {
            channel.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        try data.write(to: url)
    }

    /// ⭐ G1 — THE BYTE GATE. Every modulation kind that existed before the
    /// clock, through both render paths that carry a tempo map: the offline
    /// bounce across 120 → 90 BPM, and a looped graph roll whose loop (beat 6
    /// → 14) spans that change, so a free-running source that accidentally
    /// followed the clock would show. Plus the drum machine's note-on latch.
    ///
    /// With `W44_BYTEGATE_OUT=<folder>` each render's raw bytes land there;
    /// the lane captured BEFORE the clock existed and AFTER and compared the
    /// folders with `cmp`. Without it, the test still proves the gate can see:
    /// each render repeats bit-exactly, none is silent, and every modulated
    /// render differs from the unmodulated one (a byte gate that cannot tell
    /// "modulated" from "not" compares nothing).
    @Test("m39-w4-4 G1: byte gate over every pre-clock modulation render — offline over a tempo change, and looped across it")
    func w44ByteGateOverPreClockRenders() throws {
        let tempoMap = try Self.w44TempoMap()
        let tone = try w44SineWAV(seconds: 20)
        defer { try? FileManager.default.removeItem(at: tone) }
        let outFolder = ProcessInfo.processInfo.environment["W44_BYTEGATE_OUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let outFolder {
            try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        }
        var renders: [(name: String, channels: [[Float]])] = []

        // Offline bounce, 10 s from beat 0: crosses the tempo change at 4 s.
        for kind in W44Kind.allCases {
            let track = w44AudioTrack(clip: tone, kind: kind)
            let audio = try OfflineRenderer(sampleRate: Self.sampleRate, maximumFrameCount: 512)
                .render(tracks: [track], tempoMap: tempoMap, fromBeat: 0, durationSeconds: 10)
            renders.append(("offline-\(kind.rawValue)", audio.channelData))
        }
        // The drum machine's note-on latch, free-running.
        let drums = try OfflineRenderer(sampleRate: Self.sampleRate, maximumFrameCount: 512)
            .render(tracks: [w44FreeRunningDrumTrack()], tempoMap: tempoMap,
                    fromBeat: 0, durationSeconds: 9)
        renders.append(("offline-drums-stepFree", drums.channelData))
        // Looped roll: from beat 4, loop 6 → 14 (cycle 5 s, head 6 s), 18 s.
        let loop = PlaybackGraph.LoopWindow(startBeat: 6, endBeat: 14)
        for kind in W44Kind.allCases {
            let channels = try w44LoopRoll(tracks: [w44AudioTrack(clip: tone, kind: kind)],
                                           tempoMap: tempoMap, fromBeat: 4, loop: loop,
                                           frames: Int(18 * Self.sampleRate))
            renders.append(("loop-\(kind.rawValue)", channels))
        }

        // The gate can see: deterministic, non-silent, and modulation changes bytes.
        let repeatStep = try OfflineRenderer(sampleRate: Self.sampleRate, maximumFrameCount: 512)
            .render(tracks: [w44AudioTrack(clip: tone, kind: .stepFree)], tempoMap: tempoMap,
                    fromBeat: 0, durationSeconds: 10)
        let firstStep = try #require(renders.first { $0.name == "offline-stepFree" })
        #expect(w44Fingerprint(repeatStep.channelData) == w44Fingerprint(firstStep.channels),
                "a byte gate over a render that does not repeat bit-exactly measures nothing")
        let offlineNone = try #require(renders.first { $0.name == "offline-none" })
        let loopNone = try #require(renders.first { $0.name == "loop-none" })
        for render in renders {
            let peak = render.channels.flatMap { $0 }.reduce(Float(0)) { max($0, abs($1)) }
            #expect(peak > 0.01, "\(render.name) is silent (peak \(peak))")
            if render.name.hasPrefix("offline-"), render.name != "offline-none",
               !render.name.hasPrefix("offline-drums") {
                #expect(w44Fingerprint(render.channels) != w44Fingerprint(offlineNone.channels),
                        "\(render.name) is byte-identical to no modulation")
            }
            if render.name.hasPrefix("loop-"), render.name != "loop-none" {
                #expect(w44Fingerprint(render.channels) != w44Fingerprint(loopNone.channels),
                        "\(render.name) is byte-identical to no modulation")
            }
            let fingerprint = String(w44Fingerprint(render.channels), radix: 16)
            print("[measured] W44 G1 \(render.name): frames \(render.channels.first?.count ?? 0) "
                  + "fnv \(fingerprint)")
            if let outFolder {
                try w44WriteRaw(render.channels,
                                to: outFolder.appendingPathComponent("\(render.name).f32"))
            }
        }
    }


    // MARK: m39-w4-4 — render gates for the SYNCED path (G2–G7)

    /// The G2 meter: 4/4, then 3/4 from bar 5 (beat 16) — bar 6 is beat 19.
    private static func w44MeterMap() throws -> MeterMap {
        try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                               .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4)])
    }

    private func w44Synced(_ steps: [Double], division: String = "1/16",
                           edgeMs: Double = 0) -> ModulationSource {
        ModulationSource(kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: steps, stepDivision: division, rateHz: 4, edgeMs: edgeMs)))
    }

    /// A DC clip on the fader: the output IS the gain, so every step edge is a
    /// level change at one exact frame.
    private func w44DCTrack(dc: URL, source: ModulationSource, depth: Double = -0.5) -> Track {
        var track = Track(name: "W44 DC", kind: .audio,
                          clips: [Clip(name: "dc", startBeat: 0, lengthBeats: 64, audioFileURL: dc)])
        track.modulationSources = [source]
        track.modulationRoutes = [ModulationRoute(sourceID: source.id, target: .volume, depth: depth)]
        return track
    }

    /// Frames where the level jumps (|x[n] − x[n−1]| > threshold), n ≥ 1.
    private func w44Edges(_ x: [Float], threshold: Float = 0.02) -> [Int] {
        var edges: [Int] = []
        var n = 1
        while n < x.count {
            if abs(x[n] - x[n - 1]) > threshold { edges.append(n) }
            n += 1
        }
        return edges
    }

    /// The step a beat was written on (pattern restarts at every meter change).
    private func w44AuthoredIndex(beat: Double, meterMap: MeterMap, count: Int) -> Int {
        let origin = meterMap.changes.last { $0.startBeat <= beat }?.startBeat ?? 0
        let k = Int(((beat - origin) / 0.25).rounded())
        return ((k % count) + count) % count
    }

    /// Every sixteenth boundary in (fromBeat, throughBeat) where the authored
    /// value changes, at `round(seconds(from: fromBeat, to: B) · rate)` — the
    /// MIDI schedule's frame for a note on B.
    private func w44ExpectedEdges(steps: [Double], tempoMap: TempoMap, meterMap: MeterMap,
                                  fromBeat: Double, throughBeat: Double) -> [(beat: Double, frame: Int)] {
        var result: [(beat: Double, frame: Int)] = []
        var beat = (fromBeat / 0.25).rounded(.down) * 0.25 + 0.25
        while beat < throughBeat {
            let now = steps[w44AuthoredIndex(beat: beat, meterMap: meterMap, count: steps.count)]
            let before = steps[w44AuthoredIndex(beat: beat - 0.25, meterMap: meterMap, count: steps.count)]
            if now != before {
                result.append((beat, Int((tempoMap.seconds(from: fromBeat, to: beat) * Self.sampleRate)
                    .rounded())))
            }
            beat += 0.25
        }
        return result
    }

    /// Matches every expected edge to a measured one within ±`tolerance`
    /// frames; returns the worst offset, the unmatched expected edges and the
    /// measured edges nobody expected.
    private func w44Match(expected: [(beat: Double, frame: Int)], measured: [Int],
                          tolerance: Int = 1) -> (worst: Int, missing: [Double], spurious: [Int]) {
        var unused = Set(measured)
        var worst = 0
        var missing: [Double] = []
        for edge in expected {
            // Nearest unused measured edge, searching 0, +1, −1, +2, −2 …
            var hit: Int?
            var offset = 0
            while hit == nil, offset <= tolerance {
                if unused.contains(edge.frame + offset) {
                    hit = edge.frame + offset
                } else if offset > 0, unused.contains(edge.frame - offset) {
                    hit = edge.frame - offset
                }
                offset += 1
            }
            if let hit {
                unused.remove(hit)
                worst = max(worst, abs(hit - edge.frame))
            } else {
                missing.append(edge.beat)
            }
        }
        return (worst, missing, unused.sorted())
    }

    /// ⭐ G2 — EDGES ON THE MAP. A synced 1/16 pattern on the fader over a DC
    /// clip; the tempo goes 120 → 90 at bar 3 and the meter becomes 3/4 at bar
    /// 5. Every gain edge must sit within ±1 frame of the MIDI schedule's frame
    /// for that boundary. Two patterns: alternating 1/0 (the design's) and
    /// 1/0/0, whose restart at the meter change is VISIBLE (16 sixteenths of
    /// 4/4 hide a 2-step restart).
    ///
    /// POSITIVE CONTROL for the edge finder: a FREE-RUNNING 8 steps/s source
    /// (6 000 frames a step) through the same render and the same finder must
    /// land on k·6 000 exactly. (The design's control, an automation hold lane,
    /// cannot serve: the automation stage chords a breakpoint that falls inside
    /// a quantum across that quantum — `AutomationRenderer.apply`'s doc — so its
    /// edges are 512-frame ramps by design.)
    @Test("⭐ m39-w4-4 G2: a synced 1/16 pattern's gain edges sit on the MIDI schedule's frames across 120→90 at bar 3 and 3/4 at bar 5")
    func w44SyncedEdgesSitOnTheMap() throws {
        let tempo = try Self.w44TempoMap()
        let meter = try Self.w44MeterMap()
        let lastBeat = 26.0
        let seconds = tempo.seconds(from: 0, to: lastBeat)
        let dc = try writeConstantWAV(value: 0.5, frames: Int((seconds + 1) * Self.sampleRate))
        defer { try? FileManager.default.removeItem(at: dc) }
        func render(_ source: ModulationSource) throws -> [Float] {
            try OfflineRenderer(sampleRate: Self.sampleRate, maximumFrameCount: 512)
                .render(tracks: [w44DCTrack(dc: dc, source: source)], tempoMap: tempo,
                        fromBeat: 0, durationSeconds: seconds, meterMap: meter).channelData[0]
        }
        // Positive control first: a finder that cannot find known edges proves nothing.
        let free = ModulationSource(kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: [1, 0], rateHz: 8, edgeMs: 0)))
        let freeEdges = w44Edges(try render(free))
        var expectedFree: [(beat: Double, frame: Int)] = []
        var k = 1
        while k * 6_000 < Int(seconds * Self.sampleRate) {
            expectedFree.append((Double(k), k * 6_000))
            k += 1
        }
        let control = w44Match(expected: expectedFree, measured: freeEdges)
        print("[measured] W44 G2 control (free-running, 6 000 frames a step): \(expectedFree.count) "
              + "expected, worst \(control.worst), missing \(control.missing.count), spurious "
              + "\(control.spurious.count)")
        #expect(control.missing.isEmpty && control.spurious.isEmpty && control.worst == 0)

        for steps in [[1.0, 0.0], [1.0, 0.0, 0.0]] {
            let measured = w44Edges(try render(w44Synced(steps)))
            let expected = w44ExpectedEdges(steps: steps, tempoMap: tempo, meterMap: meter,
                                            fromBeat: 0, throughBeat: lastBeat)
            let match = w44Match(expected: expected, measured: measured)
            let afterBar3 = expected.filter { $0.beat > 8 }.count
            let afterBar5 = expected.filter { $0.beat >= 16 }.count
            print("[measured] W44 G2 steps \(steps): \(expected.count) expected edges (\(afterBar3) after "
                  + "bar 3, \(afterBar5) from bar 5), measured \(measured.count), worst offset "
                  + "\(match.worst) frames, missing \(match.missing.prefix(4)), spurious "
                  + "\(match.spurious.prefix(4))")
            #expect(expected.count > 60 && afterBar5 > 10)
            #expect(match.missing.isEmpty, "edges not found within ±1 frame at beats \(match.missing.prefix(8))")
            #expect(match.spurious.isEmpty, "edges nobody wrote at frames \(match.spurious.prefix(8))")
            #expect(match.worst <= 1)
        }
    }

    /// G3 — LOOP-EXACT. Loop from beat 1.5 to bar 4 (beat 12) at 120 BPM, so a
    /// cycle is exactly 252 000 frames; three unrolled cycles must be bit-equal
    /// to cycle 1. CONTROL: a free-running source at 7.3 steps/s (which does not
    /// divide the cycle) through the same rig must differ between cycles.
    @Test("m39-w4-4 G3: loop-exact — beat 1.5 → bar 4, three cycles: cycles 2 and 3 are bit-equal to cycle 1")
    func w44LoopCyclesAreBitEqual() throws {
        let tempo = TempoMap(constantBPM: 120)
        let cycle = 252_000
        let dc = try writeConstantWAV(value: 0.5, frames: 5 * cycle)
        defer { try? FileManager.default.removeItem(at: dc) }
        let loop = PlaybackGraph.LoopWindow(startBeat: 1.5, endBeat: 12)
        func cyclesDiffering(_ source: ModulationSource) throws -> (two: Int, three: Int) {
            let out = try w44LoopRoll(tracks: [w44DCTrack(dc: dc, source: source)], tempoMap: tempo,
                                      fromBeat: 1.5, loop: loop, frames: 4 * cycle)
            var two = 0
            var three = 0
            for channel in 0..<2 {
                var n = 0
                while n < cycle {
                    let reference = out[channel][cycle + n].bitPattern
                    if out[channel][2 * cycle + n].bitPattern != reference { two += 1 }
                    if out[channel][3 * cycle + n].bitPattern != reference { three += 1 }
                    n += 1
                }
            }
            return (two, three)
        }
        let synced = try cyclesDiffering(w44Synced([1, -0.5, 0.25, 0, 0.75], edgeMs: 2))
        let free = try cyclesDiffering(ModulationSource(kind: .stepSequencer, params: .stepSequencer(
            StepSequencerSourceParams(steps: [1, -0.5, 0.25, 0, 0.75], rateHz: 7.3, edgeMs: 2))))
        print("[measured] W44 G3 synced: cycle 2 vs 1 \(synced.two), cycle 3 vs 1 \(synced.three) "
              + "differing of \(2 * cycle); free-running control \(free.two) / \(free.three)")
        #expect(synced.two == 0 && synced.three == 0)
        #expect(free.two > 0 && free.three > 0, "the control: the comparison must be able to see a difference")
    }

    /// G4 — SEEK-EXACT. A render from bar 6 (beat 19, frame 544 000 of the G2
    /// map) must be bit-equal to that slice of a full render; so must one from
    /// bar 2 (beat 4, frame 96 000), whose roll still has the tempo and meter
    /// changes ahead of it (a cursor carried over from the full render would
    /// start that roll in the wrong segment). Hard steps are
    /// bit-equal by construction (a frame centre is half a sample from any
    /// integer-sample edge). With 2 ms ramps the beat is computed from a
    /// different segment start in each render, so the ramp values may differ
    /// in the last bits: measured and reported, bounded at 1e-6.
    @Test("m39-w4-4 G4: seek-exact — renders from bar 6 and from bar 2 equal those bars of a full render")
    func w44SeekFromBar6EqualsThePlaythrough() throws {
        let tempo = try Self.w44TempoMap()
        let meter = try Self.w44MeterMap()
        let lastBeat = 26.0
        let dc = try writeConstantWAV(value: 0.5,
                                      frames: Int((tempo.seconds(from: 0, to: lastBeat) + 1) * Self.sampleRate))
        defer { try? FileManager.default.removeItem(at: dc) }
        for (seekBeat, expectedOrigin) in [(19.0, 544_000), (4.0, 96_000)] {
            let origin = Int((tempo.seconds(from: 0, to: seekBeat) * Self.sampleRate).rounded())
            #expect(origin == expectedOrigin)
            for edgeMs in [0.0, 2.0] {
                let track = w44DCTrack(dc: dc, source: w44Synced([1, -0.5, 0.25, 0, 0.75], edgeMs: edgeMs))
                let full = try OfflineRenderer(sampleRate: Self.sampleRate, maximumFrameCount: 512)
                    .render(tracks: [track], tempoMap: tempo, fromBeat: 0,
                            durationSeconds: tempo.seconds(from: 0, to: lastBeat), meterMap: meter)
                let seeked = try OfflineRenderer(sampleRate: Self.sampleRate, maximumFrameCount: 512)
                    .render(tracks: [track], tempoMap: tempo, fromBeat: seekBeat,
                            durationSeconds: tempo.seconds(from: seekBeat, to: lastBeat), meterMap: meter)
                var differing = 0
                var shiftedDiffering = 0
                var worst: Float = 0
                let count = min(seeked.frameCount, full.frameCount - origin - 512)
                for channel in 0..<2 {
                    var n = 0
                    while n < count {
                        let a = seeked.channelData[channel][n]
                        let b = full.channelData[channel][origin + n]
                        if a.bitPattern != b.bitPattern { differing += 1; worst = max(worst, abs(a - b)) }
                        if a.bitPattern != full.channelData[channel][origin + n + 512].bitPattern {
                            shiftedDiffering += 1
                        }
                        n += 1
                    }
                }
                print("[measured] W44 G4 from beat \(seekBeat) edgeMs \(edgeMs): \(differing) differing of "
                      + "\(2 * count) (worst |Δ| \(worst)); control shifted by 512 frames: \(shiftedDiffering)")
                if edgeMs == 0 { #expect(differing == 0) }
                #expect(worst < 1e-6)
                #expect(shiftedDiffering > 0, "the control: a shifted comparison must differ")
            }
        }
    }

    /// The drum machine with the open hat on every sixteenth, `openHat.decay`
    /// at `knob`, optionally driven by `source` at `depth`.
    private func w44HatTrack(knob: Double, source: ModulationSource?, depth: Double,
                             lastBeat: Double) -> Track {
        var kit = DrumKitParams()
        kit.openHat.decay = knob
        var notes: [MIDINote] = []
        var index = 0
        while Double(index) * 0.25 < lastBeat {
            notes.append(MIDINote(pitch: 39, velocity: 90, startBeat: Double(index) * 0.25,
                                  lengthBeats: 0.125))
            index += 1
        }
        var track = Track(name: "W44 hats", kind: .instrument,
                          clips: [Clip(name: "hats", startBeat: 0, lengthBeats: lastBeat + 1, notes: notes)],
                          instrument: InstrumentDescriptor(kind: .drumSynth, drumKit: kit))
        if let source {
            track.modulationSources = [source]
            track.modulationRoutes = [ModulationRoute(
                sourceID: source.id, target: .instrumentParam(paramName: "openHat.decay"), depth: depth)]
        }
        return track
    }

    /// Time from a hit to its envelope's −20 dB point: the peak over the first
    /// 3 ms, then the first 0.5 ms window (from 1 ms on) whose peak is below a
    /// tenth of it. Capped at the next hit.
    private func w44MinusTwentyDb(_ x: [Float], from start: Int, to end: Int) -> Double {
        var peak: Float = 0
        var n = start
        while n < min(start + 144, end) { peak = max(peak, abs(x[n])); n += 1 }
        var window = start + 48
        while window + 24 <= end {
            var level: Float = 0
            var j = window
            while j < window + 24 { level = max(level, abs(x[j])); j += 1 }
            if level < peak * 0.1 { return Double(window - start) / Self.sampleRate }
            window += 24
        }
        return Double(end - start) / Self.sampleRate
    }

    /// Per hit: the modulated render's −20 dB time against the static-knob
    /// reference for the step that hit was written on. Returns (hits, wrong,
    /// worst relative error, the short/long reference ratio).
    private func w44LatchCheck(modulated m: [Float], short: [Float], long: [Float],
                               hits: [(frame: Int, step: Int)]) -> (hits: Int, wrong: Int, worst: Double, ratio: Double) {
        var wrong = 0
        var worst = 0.0
        var ratioSum = 0.0
        var counted = 0
        var index = 0
        while index + 1 < hits.count {
            let start = hits[index].frame
            let end = min(hits[index + 1].frame, m.count, short.count, long.count)
            let measured = w44MinusTwentyDb(m, from: start, to: end)
            let shortT = w44MinusTwentyDb(short, from: start, to: end)
            let longT = w44MinusTwentyDb(long, from: start, to: end)
            let expected = hits[index].step == 0 ? shortT : longT
            let error = abs(measured - expected) / expected
            worst = max(worst, error)
            if error > 0.05 { wrong += 1 }
            ratioSum += longT / shortT
            counted += 1
            index += 1
        }
        return (counted, wrong, worst, counted == 0 ? 0 : ratioSum / Double(counted))
    }

    /// ⭐ G5 — THE LATCH. The drum machine reads modulation when a hit starts,
    /// so a hit on the grid line must latch ITS step — not the step before
    /// (the `+0.5` alignment) and not the average of two (the trailing edge).
    /// Steps alternate short/long `openHat.decay`; every hit's −20 dB decay
    /// must match a static-knob render at its own step's latched value within
    /// 5 %. 90, 120 and 174 BPM (174 puts every sixteenth edge between
    /// samples), hard and 2 ms edges, and through a loop wrap.
    @Test("⭐ m39-w4-4 G5: every open-hat hit latches its own step's decay — 90/120/174 BPM, hard and 2 ms edges, across a loop wrap")
    func w44EveryHitLatchesItsOwnStep() throws {
        let knob = 0.06
        let depth = 0.32
        // The value the drum machine computes for a step of 1, read off the
        // published target so the reference cannot disagree with the render.
        let probe = w44HatTrack(knob: knob, source: w44Synced([0, 1]), depth: depth, lastBeat: 1)
        let snapshot = try #require(ModulationSnapshotBuilder.build(
            strip: ModulationSnapshotBuilder.Strip(
                sources: probe.modulationSources, routes: probe.modulationRoutes,
                instrument: probe.instrument, isInstrumentTrack: true),
            generation: 1, timelineID: 1, sampleRate: Self.sampleRate, originSample: 0,
            positionValid: true))
        let target = snapshot.targets[0]
        let longValue = ModulationDepthLaw.value(
            base: knob, sum: 0.0 + depth * 1.0, range: target.rangeLo...target.rangeHi,
            curve: ModulationEvaluator.curve(for: target.curveCode))
        print("[measured] W44 G5 latched decay: step 0 → \(knob) s, step 1 → \(longValue) s")
        #expect(longValue > 2.5 * knob && longValue < 0.25)

        let lastBeat = 8.0
        for bpm in [90.0, 120.0, 174.0] {
            let tempo = TempoMap(constantBPM: bpm)
            let seconds = tempo.seconds(from: 0, to: lastBeat + 1)
            func render(_ track: Track) throws -> [Float] {
                try OfflineRenderer(sampleRate: Self.sampleRate, maximumFrameCount: 512)
                    .render(tracks: [track], tempoMap: tempo, fromBeat: 0, durationSeconds: seconds)
                    .channelData[0]
            }
            let short = try render(w44HatTrack(knob: knob, source: nil, depth: 0, lastBeat: lastBeat))
            let long = try render(w44HatTrack(knob: longValue, source: nil, depth: 0, lastBeat: lastBeat))
            var hits: [(frame: Int, step: Int)] = []
            var index = 0
            while Double(index) * 0.25 < lastBeat {
                hits.append((Int((tempo.seconds(from: 0, to: Double(index) * 0.25) * Self.sampleRate)
                    .rounded()), index % 2))
                index += 1
            }
            for edgeMs in [0.0, 2.0] {
                let modulated = try render(w44HatTrack(knob: knob, source: w44Synced([0, 1], edgeMs: edgeMs),
                                                       depth: depth, lastBeat: lastBeat))
                let check = w44LatchCheck(modulated: modulated, short: short, long: long, hits: hits)
                print("[measured] W44 G5 \(bpm) BPM edgeMs \(edgeMs): \(check.hits) hits, \(check.wrong) "
                      + "off their step, worst error \(String(format: "%.4f", check.worst)), "
                      + "long/short −20 dB ratio \(String(format: "%.2f", check.ratio))")
                #expect(check.hits > 20)
                #expect(check.ratio > 2, "the references must be told apart, or the check sees nothing")
                #expect(check.wrong == 0)
            }
        }

        // Through a loop wrap at 174 BPM: loop beat 2 → 5 (twelve sixteenths), from 0, three cycles.
        let tempo = TempoMap(constantBPM: 174)
        let loop = PlaybackGraph.LoopWindow(startBeat: 2, endBeat: 5)
        let headSeconds = tempo.seconds(from: 0, to: 5)
        let cycleSeconds = tempo.seconds(from: 2, to: 5)
        let frames = Int((headSeconds + 3 * cycleSeconds) * Self.sampleRate)
        func roll(_ track: Track) throws -> [Float] {
            try w44LoopRoll(tracks: [track], tempoMap: tempo, fromBeat: 0, loop: loop, frames: frames)[0]
        }
        let short = try roll(w44HatTrack(knob: knob, source: nil, depth: 0, lastBeat: 6))
        let long = try roll(w44HatTrack(knob: longValue, source: nil, depth: 0, lastBeat: 6))
        var hits: [(frame: Int, step: Int)] = []
        var beat = 0.0
        while beat < 5 {   // the head pass
            hits.append((Int((tempo.seconds(from: 0, to: beat) * Self.sampleRate).rounded()),
                         Int((beat / 0.25).rounded()) % 2))
            beat += 0.25
        }
        var cycle = 1
        while cycle <= 3 {   // the builders' cycle offset, verbatim
            let offset = headSeconds + Double(cycle - 1) * cycleSeconds
            beat = 2
            while beat < 5 {
                hits.append((Int(((offset + tempo.seconds(from: 2, to: beat)) * Self.sampleRate).rounded()),
                             Int((beat / 0.25).rounded()) % 2))
                beat += 0.25
            }
            cycle += 1
        }
        for edgeMs in [0.0, 2.0] {
            let modulated = try roll(w44HatTrack(knob: knob, source: w44Synced([0, 1], edgeMs: edgeMs),
                                                 depth: depth, lastBeat: 6))
            let check = w44LatchCheck(modulated: modulated, short: short, long: long, hits: hits)
            print("[measured] W44 G5 loop 2→5 @174 edgeMs \(edgeMs): \(check.hits) hits over 3 wraps, "
                  + "\(check.wrong) off their step, worst error \(String(format: "%.4f", check.worst))")
            #expect(check.hits > 40)
            #expect(check.wrong == 0)
        }
    }

    /// ⭐ G6 — THE STOPPED EDIT, and the publish key's clock. A tempo edit made
    /// while STOPPED, after the playhead, leaves `originSample` unchanged, so
    /// without the clock in the key the next play press would keep the old
    /// clock. The sequence is the graph's own, with NO parameter pass while
    /// stopped (a stopped publish would mask the defect): roll, stop, re-stage,
    /// roll. Also: a replay with the SAME map republishes nothing; a strip with
    /// no synced source is not republished by the tempo edit; an unrelated edit
    /// does not republish the synced strip.
    @Test("⭐ m39-w4-4 G6: a tempo edit made while stopped reaches the next roll's clock, and only a clock change republishes")
    func w44StoppedTempoEditReachesTheClock() throws {
        let constant = TempoMap(constantBPM: 120)
        let edited = try Self.w44TempoMap()   // 120 → 90 at beat 8: after the playhead at 0
        let dc = try writeConstantWAV(value: 0.5, frames: Int(12 * Self.sampleRate))
        defer { try? FileManager.default.removeItem(at: dc) }
        let syncedTrack = w44DCTrack(dc: dc, source: w44Synced([1, 0]))
        var freeTrack = w44DCTrack(dc: dc, source: ModulationSource(
            kind: .stepSequencer, params: .stepSequencer(StepSequencerSourceParams(steps: [1, 0], rateHz: 3))))
        freeTrack.volume = 0   // silent: only its publish behaviour is under test
        var tracks = [syncedTrack, freeTrack]

        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: tracks))
        graph.applyParameters(tracks: tracks)
        try engine.start()
        defer { engine.stop() }
        graph.applyParameters(tracks: tracks)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        func roll(_ map: TempoMap, frames: Int) throws -> [Float] {
            graph.scheduleAll(fromBeat: 0, tempoMap: map)
            graph.prepareAllPlayers(withFrameCount: 8_192)
            graph.startAllPlayers(at: nil)
            var out: [Float] = []
            while out.count < frames {
                let status = try engine.renderOffline(AVAudioFrameCount(min(frames - out.count, 512)), to: buffer)
                try #require(status == .success)
                let data = try #require(buffer.floatChannelData)
                out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            }
            return out
        }
        func generation(_ track: Track) -> UInt64? {
            graph.automationRenderer(forTrack: track.id)?.currentModulation?.generation
        }

        _ = try roll(constant, frames: 48_000)
        let first = (generation(syncedTrack), generation(freeTrack))
        graph.stopAllPlayers()
        _ = try roll(constant, frames: 4_800)   // the same map again
        let replay = (generation(syncedTrack), generation(freeTrack))
        graph.stopAllPlayers()
        // THE STOPPED EDIT: no parameter pass, playhead still at beat 0.
        let measured = try roll(edited, frames: Int(edited.seconds(from: 0, to: 14) * Self.sampleRate))
        let afterEdit = (generation(syncedTrack), generation(freeTrack))
        let clock = graph.automationRenderer(forTrack: syncedTrack.id)?.currentModulation
        // An unrelated edit while rolling: the silent strip's fader moves.
        tracks[1].volume = 0.001
        graph.applyParameters(tracks: tracks)
        let afterUnrelated = (generation(syncedTrack), generation(freeTrack))
        graph.stopAllPlayers()

        let expected = w44ExpectedEdges(steps: [1, 0], tempoMap: edited, meterMap: MeterMap(constant: TimeSignature()),
                                        fromBeat: 0, throughBeat: 14)
        let match = w44Match(expected: expected, measured: w44Edges(measured))
        print("[measured] W44 G6 generations synced/free: first \(String(describing: first)), same-map "
              + "replay \(String(describing: replay)), after the stopped edit \(String(describing: afterEdit)), "
              + "after an unrelated edit \(String(describing: afterUnrelated)); clock segments "
              + "\(clock?.clock.count ?? -1); edges after the edit: \(expected.count) expected, worst "
              + "\(match.worst), missing \(match.missing.prefix(4)), spurious \(match.spurious.prefix(4))")
        #expect(first.0 != nil && first.1 != nil)
        #expect(replay.0 == first.0, "the same map must not republish the synced strip")
        #expect(replay.1 == first.1)
        #expect(afterEdit.0 != replay.0, "the stopped tempo edit must republish the synced strip")
        #expect(afterEdit.1 == replay.1, "a strip with no synced source keeps its old publish behaviour")
        #expect(afterUnrelated.0 == afterEdit.0, "an unrelated edit must not republish the synced strip")
        #expect(clock?.clock.count == 2, "the new clock carries the change at beat 8")
        #expect(expected.filter { $0.beat > 8 }.count > 20)
        #expect(match.missing.isEmpty && match.spurious.isEmpty && match.worst <= 1)
    }

    /// G7b — ZERO ALLOCATION through the real render surface: four synced
    /// sources on volume and pan, across a tempo change and a loop wrap inside
    /// the measured quanta (head of 0.1 beat at 90 BPM = 3 200 frames).
    @Test("m39-w4-4 G7b: four synced sources through the modulation stage raise ZERO malloc/free events, across a loop wrap")
    func w44FourSyncedSourcesAllocateNothing() throws {
        let slot = try #require(MallocProbe.slot(),
                                Comment(rawValue: "malloc_logger is unavailable — a skipped gate is no gate"))
        let tempo = try Self.w44TempoMap()
        let fromBeat = 13.9
        let spec = ModulationClockSpec(
            fromBeat: fromBeat, tempoMap: tempo, meterMap: try Self.w44MeterMap(),
            loop: .init(startBeat: 6, endBeat: 14,
                        headSeconds: tempo.seconds(from: fromBeat, to: 14),
                        cycleSeconds: tempo.seconds(from: 6, to: 14)),
            sampleRate: Self.sampleRate)
        let sources = [w44Synced([1, -0.5, 0.25, 0, 0.75], edgeMs: 2),
                       w44Synced([0, 1], division: "1/8t", edgeMs: 0),
                       w44Synced([1, 0, 1], division: "1/4d", edgeMs: 5),
                       w44Synced([-1, 1], division: "1/32", edgeMs: 1)]
        let routes = sources.map { ModulationRoute(sourceID: $0.id, target: .volume, depth: -0.1) }
            + [ModulationRoute(sourceID: sources[0].id, target: .pan, depth: 0.3)]
        let snapshot = try #require(ModulationSnapshotBuilder.build(
            strip: ModulationSnapshotBuilder.Strip(sources: sources, routes: routes, baseVolume: 0.7),
            generation: 1, timelineID: 1, sampleRate: Self.sampleRate,
            originSample: Int64((tempo.seconds(from: 0, to: fromBeat) * Self.sampleRate).rounded()),
            positionValid: true, clock: spec))
        #expect(snapshot.clock.count > snapshot.clockHeadCount, "the fixture must carry a cycle template")
        let renderer = AutomationRenderer()
        renderer.publish(anchorSchedule())
        renderer.publishModulation(snapshot)
        let frames = 512
        let buffer = try stereoBuffer(frames: frames, fill: 0.5)
        var ts = offlineTimestamp(sample: 0)
        renderer.apply(bufferList: buffer.mutableAudioBufferList, frameCount: frames, timestamp: &ts)
        let list = buffer.mutableAudioBufferList
        let events = MallocProbe.events(slot: slot) {
            var quantum = 1
            while quantum <= 8 {
                var stamp = AudioTimeStamp()
                stamp.mSampleTime = Double(quantum * frames)
                stamp.mFlags = .sampleTimeValid
                renderer.apply(bufferList: list, frameCount: frames, timestamp: &stamp)
                quantum += 1
            }
        }
        let control = MallocProbe.events(slot: slot) {
            var sink: [Int] = []
            var index = 0
            while index < 64 { sink.append(index); index += 1 }
            _ = sink.count
        }
        print("[measured] W44 G7b: \(events) malloc/free events over 8 quanta, 4 synced sources, a wrap "
              + "at roll frame \(Int(spec.loop!.headSeconds * Self.sampleRate)) (control \(control))")
        #expect(events == 0)
        #expect(control > 0, "the probe itself is blind — the zero above proves nothing")
    }


    // MARK: - m39-w4-4a/4b/4d (W8-W44F): the meter reaches every bounce and every live meter edit

    /// `w44ExpectedEdges` for any step length (that helper hard-codes 1/16):
    /// every step boundary in (fromBeat, throughBeat) where the authored value
    /// changes, at the MIDI schedule's frame for a note on that beat. The
    /// pattern restarts at every meter change.
    private func w44fExpectedEdges(steps: [Double], stepBeats: Double, tempoMap: TempoMap,
                                   meterMap: MeterMap, fromBeat: Double,
                                   throughBeat: Double) -> [(beat: Double, frame: Int)] {
        func index(_ beat: Double) -> Int {
            let origin = meterMap.changes.last { $0.startBeat <= beat }?.startBeat ?? 0
            let k = Int(((beat - origin) / stepBeats).rounded())
            return ((k % steps.count) + steps.count) % steps.count
        }
        var result: [(beat: Double, frame: Int)] = []
        var beat = (fromBeat / stepBeats).rounded(.down) * stepBeats + stepBeats
        while beat < throughBeat {
            if steps[index(beat)] != steps[index(beat - stepBeats)] {
                result.append((beat, Int((tempoMap.seconds(from: fromBeat, to: beat) * Self.sampleRate)
                    .rounded())))
            }
            beat += stepBeats
        }
        return result
    }

    /// What a call did: "served", "engineUnavailable", or any other error by
    /// name, so a refusal for the WRONG reason fails.
    private static func w44fOutcome(_ body: @MainActor () async throws -> Void) async -> String {
        do {
            try await body()
            return "served"
        } catch ProjectError.engineUnavailable {
            return "engineUnavailable"
        } catch {
            return "other: \(error)"
        }
    }

    /// ⭐ T-N1b (W8-W44R N1): the PRODUCTION offline entry carries the meter.
    /// A synced 1/4 `[1, 0, 0]` on the fader over a DC clip at 120 BPM (24 000
    /// frames a beat), meter 4/4 → 3/4 at beat 16. The pattern restarts at
    /// beat 16, so beats 15 AND 16 both read step 0 (closed); with the meter
    /// dropped, beat 16 reads step 16 mod 3 = 1 (open). Every edge must sit on
    /// the MIDI schedule's frame. The meter-less overloads, which cannot know
    /// whether dropping the meter changes the render, REFUSE this project; with
    /// the route disabled they serve it (the refusal is about the synced route).
    @Test("⭐ m39-w4-4a T-N1b: AudioEngine.renderOffline carries the meter — a synced 1/4 pattern restarts at the 3/4 change, and the meter-less overloads refuse it")
    func w44fProductionEntryCarriesTheMeter() async throws {
        let tempo = TempoMap(constantBPM: 120)
        let meter = try Self.w44MeterMap()   // 4/4, then 3/4 from beat 16
        let constant = MeterMap(constant: TimeSignature())
        let seconds = 10.5                    // through beat 21
        let dc = try writeConstantWAV(value: 0.5, frames: Int((seconds + 1) * Self.sampleRate))
        defer { try? FileManager.default.removeItem(at: dc) }
        let track = w44DCTrack(dc: dc, source: w44Synced([1, 0, 0], division: "1/4"))
        let engine = AudioEngine()
        func render(_ map: MeterMap, tracks: [Track]) async throws -> [Float] {
            try await engine.renderOffline(
                tracks: tracks, tempoMap: tempo, meterMap: map, masterVolume: 1,
                masterEffects: [], masterAutomation: [],
                masterModulationSources: [], masterModulationRoutes: [],
                fromBeat: 0, durationSeconds: seconds, forcedCompensationTargets: nil).channelData[0]
        }
        let withMeter = try await render(meter, tracks: [track])
        let dropped = try await render(constant, tracks: [track])
        let peak = withMeter.reduce(Float(0)) { max($0, abs($1)) }
        func closed(_ x: [Float], _ beat: Double) -> Bool { x[Int(beat * 24_000)] < 0.25 * peak }
        let probes: [(beat: Double, closed: Bool)] = [(14.5, false), (15.5, true), (16.5, true),
                                                     (17.5, false), (18.5, false), (19.5, true)]
        let read = probes.map { closed(withMeter, $0.beat) }
        print("[measured] W44F T-N1b mid-beat closed? with the meter \(read) "
              + "(expected \(probes.map(\.closed))); meter dropped, beat 16.5 closed? "
              + "\(closed(dropped, 16.5)); peak \(peak)")
        #expect(peak > 0.1)
        #expect(read == probes.map(\.closed), "the pattern must restart at the 3/4 change (beat 16)")
        #expect(!closed(dropped, 16.5), "the dropped meter reads step 16 mod 3 = 1 (open) at beat 16")

        let expected = w44fExpectedEdges(steps: [1, 0, 0], stepBeats: 1, tempoMap: tempo,
                                         meterMap: meter, fromBeat: 0, throughBeat: 21)
        let match = w44Match(expected: expected, measured: w44Edges(withMeter))
        let control = w44Match(
            expected: w44fExpectedEdges(steps: [1, 0, 0], stepBeats: 1, tempoMap: tempo,
                                        meterMap: constant, fromBeat: 0, throughBeat: 21),
            measured: w44Edges(dropped))
        print("[measured] W44F T-N1b edges: \(expected.count) expected, worst \(match.worst), missing "
              + "\(match.missing.prefix(4)), spurious \(match.spurious.prefix(4)); constant-map control "
              + "worst \(control.worst), missing \(control.missing.count), spurious \(control.spurious.count)")
        #expect(match.missing.isEmpty && match.spurious.isEmpty && match.worst <= 1)
        #expect(control.missing.isEmpty && control.spurious.isEmpty && control.worst <= 1)

        // The meter-carrying mixdown writes exactly the buffer above.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w44f-tn1b-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mixURL = dir.appendingPathComponent("mix.wav")
        _ = try await engine.renderMixdown(
            tracks: [track], tempoMap: tempo, meterMap: meter, masterVolume: 1,
            masterEffects: [], masterAutomation: [],
            masterModulationSources: [], masterModulationRoutes: [],
            fromBeat: 0, durationSeconds: seconds, to: mixURL, format: .default)
        let written = try TestSignals.readFile(mixURL)[0]
        #expect(written.map(\.bitPattern) == withMeter.map(\.bitPattern),
                "renderMixdown(meterMap:) must write the renderOffline(meterMap:) buffer")

        // The meter-less overloads cannot see the meter: they refuse a synced route…
        func meterless(_ tracks: [Track]) async -> [String] {
            let url = dir.appendingPathComponent("never-\(UUID().uuidString).wav")
            var result: [String] = []
            result.append(await Self.w44fOutcome {
                _ = try await engine.renderOffline(
                    tracks: tracks, tempoMap: tempo, masterVolume: 1,
                    fromBeat: 0, durationSeconds: 1, forcedCompensationTargets: nil)
            })
            result.append(await Self.w44fOutcome {
                _ = try await engine.renderOffline(
                    tracks: tracks, tempoMap: tempo, masterVolume: 1,
                    masterEffects: [], masterAutomation: [],
                    masterModulationSources: [], masterModulationRoutes: [],
                    fromBeat: 0, durationSeconds: 1, forcedCompensationTargets: nil)
            })
            result.append(await Self.w44fOutcome {
                _ = try await engine.renderMixdown(
                    tracks: tracks, tempoMap: tempo, masterVolume: 1,
                    fromBeat: 0, durationSeconds: 1, to: url)
            })
            result.append(await Self.w44fOutcome {
                _ = try await engine.renderMixdown(
                    tracks: tracks, tempoMap: tempo, masterVolume: 1,
                    masterEffects: [], masterAutomation: [],
                    masterModulationSources: [], masterModulationRoutes: [],
                    fromBeat: 0, durationSeconds: 1, to: url, format: .default)
            })
            return result
        }
        let refused = await meterless([track])
        // …and serve the same project once the synced route is off.
        var disabled = track
        disabled.modulationRoutes[0].enabled = false
        let served = await meterless([disabled])
        print("[measured] W44F T-N1b meter-less overloads (legacy, m39-e-2, mixdown, format mixdown): "
              + "synced route \(refused); route disabled \(served)")
        #expect(refused == Array(repeating: "engineUnavailable", count: 4))
        #expect(served == Array(repeating: "served", count: 4))
    }

    /// T-INV — the meter reaches NOTHING but a synced source's clock. Through
    /// the production entry: every pre-clock modulation kind (and the drum
    /// machine's free-running latch) renders bit-identically with a mid-song
    /// meter change, with the constant map, and through the meter-less
    /// overload; and a synced source under a single-change 3/4 map (pattern
    /// origin 0 everywhere) renders bit-identically to the 4/4 default.
    /// CONTROL: the synced project DOES change with a real meter change, so the
    /// equalities above are not a blind gate.
    @Test("m39-w4-4a T-INV: the meter moves nothing but a synced clock — every pre-clock kind is bit-identical with, without, and before the meter seam")
    func w44fMeterReachesOnlyTheClock() async throws {
        let tempo = try Self.w44TempoMap()   // 120 → 90 at beat 8
        let meter = try Self.w44MeterMap()   // 3/4 from beat 16
        let constant = MeterMap(constant: TimeSignature())
        let tone = try w44SineWAV(seconds: 12)
        defer { try? FileManager.default.removeItem(at: tone) }
        let free: [Track] = [W44Kind.stepFree, .lfo, .follower, .macro].map { w44AudioTrack(clip: tone, kind: $0) }
            + [w44FreeRunningDrumTrack()]
        let engine = AudioEngine()
        func render(_ tracks: [Track], _ map: MeterMap?) async throws -> [[UInt32]] {
            let audio: RenderedAudio
            if let map {
                audio = try await engine.renderOffline(
                    tracks: tracks, tempoMap: tempo, meterMap: map, masterVolume: 1,
                    masterEffects: [], masterAutomation: [],
                    masterModulationSources: [], masterModulationRoutes: [],
                    fromBeat: 0, durationSeconds: 10, forcedCompensationTargets: nil)
            } else {
                audio = try await engine.renderOffline(
                    tracks: tracks, tempoMap: tempo, masterVolume: 1,
                    fromBeat: 0, durationSeconds: 10, forcedCompensationTargets: nil)
            }
            return audio.channelData.map { $0.map(\.bitPattern) }
        }
        let freeMeter = try await render(free, meter)
        let freeConstant = try await render(free, constant)
        let freeMeterless = try await render(free, nil)
        #expect(freeMeter == freeConstant, "a meter change moved a project with no synced source")
        #expect(freeConstant == freeMeterless, "the meter-carrying entry is not the old entry's bytes")

        let dc = try writeConstantWAV(value: 0.5, frames: 11 * Int(Self.sampleRate))
        defer { try? FileManager.default.removeItem(at: dc) }
        let synced = [w44DCTrack(dc: dc, source: w44Synced([1, 0, 0.5], division: "1/8"))]
        let threeFour = MeterMap(constant: TimeSignature(beatsPerBar: 3, beatUnit: 4))
        let syncedThreeFour = try await render(synced, threeFour)
        let syncedDefault = try await render(synced, constant)
        let syncedChange = try await render(synced, meter)
        print("[measured] W44F T-INV free kinds: meter==constant \(freeMeter == freeConstant), "
              + "constant==meter-less \(freeConstant == freeMeterless); synced: 3/4 single change == "
              + "4/4 default \(syncedThreeFour == syncedDefault), real change differs "
              + "\(syncedChange != syncedDefault)")
        #expect(syncedThreeFour == syncedDefault, "a single-change map puts the pattern origin at 0, like the default")
        #expect(syncedChange != syncedDefault, "CONTROL: a real meter change must reach the synced clock")
    }

    /// ⭐ T-F1 (W8-W44R Finding 1): the offline arm stages the meter WITH the
    /// roll context, so the pre-start parameter pass compiles the synced clock
    /// from the real map (two segments: the head splits at the 3/4 change at
    /// beat 16), and the roll start, which restages the same map, finds an
    /// equal publish key and republishes nothing. CONTROL: an arm with no meter
    /// (the fixture callers' default) compiles one segment, and the roll start
    /// has to republish: the corrective republish the finding describes.
    @Test("⭐ m39-w4-4b T-F1: armOfflineAutomation(meterMap:) compiles the real meter pre-start, so the roll start republishes nothing")
    func w44fOfflineArmStagesTheMeter() throws {
        let tempo = TempoMap(constantBPM: 120)
        let meter = try Self.w44MeterMap()
        let dc = try writeConstantWAV(value: 0.5, frames: 2 * Int(Self.sampleRate))
        defer { try? FileManager.default.removeItem(at: dc) }
        let tracks = [w44DCTrack(dc: dc, source: w44Synced([1, 0, 0]))]
        func arm(_ armMeter: MeterMap?) throws -> (armed: ModulationSnapshot?, started: ModulationSnapshot?,
                                                    staged: MeterMap) {
            let engine = AVAudioEngine()
            let graph = PlaybackGraph(engine: engine)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
            _ = engine.mainMixerNode
            #expect(graph.reconcile(tracks: tracks))
            // `OfflineRenderer.beginSession`'s order, verbatim.
            if let armMeter {
                graph.armOfflineAutomation(fromBeat: 0, tempoMap: tempo, meterMap: armMeter)
            } else {
                graph.armOfflineAutomation(fromBeat: 0, tempoMap: tempo)
            }
            graph.applyParameters(tracks: tracks, playheadBeat: 0)
            try engine.start()
            defer { engine.stop() }
            graph.applyParameters(tracks: tracks, playheadBeat: 0)
            let armed = graph.automationRenderer(forTrack: tracks[0].id)?.currentModulation
            let staged = graph.rollMeterMapForTesting
            graph.scheduleAll(fromBeat: 0, tempoMap: tempo, meterMap: meter)
            graph.startAllPlayers(at: nil)
            let started = graph.automationRenderer(forTrack: tracks[0].id)?.currentModulation
            graph.stopAllPlayers()
            return (armed, started, staged)
        }
        let fixed = try arm(meter)
        let bare = try arm(nil)
        print("[measured] W44F T-F1 armed with the meter: segments \(fixed.armed?.clock.count ?? -1), "
              + "generation armed \(fixed.armed?.generation ?? 0) → started \(fixed.started?.generation ?? 0); "
              + "armed bare (control): segments \(bare.armed?.clock.count ?? -1), generation "
              + "\(bare.armed?.generation ?? 0) → \(bare.started?.generation ?? 0)")
        #expect(fixed.staged == meter)
        #expect(fixed.armed?.clock.count == 2, "the pre-start pass must compile the head split at beat 16")
        #expect(fixed.armed?.generation != nil)
        #expect(fixed.started?.generation == fixed.armed?.generation,
                "the roll start must find an equal key: nothing to correct")
        #expect(fixed.started?.clock.count == 2)
        // CONTROL: the default arm stages the constant map, and the start corrects it.
        #expect(bare.staged == MeterMap(constant: TimeSignature()))
        #expect(bare.armed?.clock.count == 1)
        #expect(bare.started?.generation != bare.armed?.generation)
        #expect(bare.started?.clock.count == 2)
    }

    /// ⭐ T-N3b (W8-W44R N3): a meter edit while ROLLING reaches the clock with
    /// no restart. A synced 1/4 `[1, 0, 0]` at 120 BPM under a constant 4/4
    /// rolls beats 0 → 4; then, without stopping, the meter becomes 3/4 from
    /// beat 8 (restage + one parameter pass, what `metronomeChanged` does).
    /// From beat 4 every edge must sit on the NEW map's frames: step 0 at beat
    /// 8, where the stale clock reads step 2. Only the synced strip rebuilds,
    /// exactly once; restaging the same map again is a no-op.
    @Test("⭐ m39-w4-4d T-N3b: a mid-roll meter restage moves the synced pattern from the next edge — one rebuild, synced strip only")
    func w44fMidRollMeterRestageMovesThePattern() throws {
        let tempo = TempoMap(constantBPM: 120)
        let newMeter = try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                              .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4)])
        let constant = MeterMap(constant: TimeSignature())
        let dc = try writeConstantWAV(value: 0.5, frames: 8 * Int(Self.sampleRate))
        defer { try? FileManager.default.removeItem(at: dc) }
        let syncedTrack = w44DCTrack(dc: dc, source: w44Synced([1, 0, 0], division: "1/4"))
        var freeTrack = w44DCTrack(dc: dc, source: ModulationSource(
            kind: .stepSequencer, params: .stepSequencer(StepSequencerSourceParams(steps: [1, 0], rateHz: 3))))
        freeTrack.volume = 0   // silent: only its publish behaviour is under test
        let tracks = [syncedTrack, freeTrack]

        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        #expect(graph.reconcile(tracks: tracks))
        graph.applyParameters(tracks: tracks)
        try engine.start()
        defer { engine.stop() }
        graph.applyParameters(tracks: tracks)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        var out: [Float] = []
        func pull(through frames: Int) throws {
            while out.count < frames {
                let status = try engine.renderOffline(AVAudioFrameCount(min(frames - out.count, 512)), to: buffer)
                try #require(status == .success)
                let data = try #require(buffer.floatChannelData)
                out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            }
        }
        func generation(_ track: Track) -> UInt64? {
            graph.automationRenderer(forTrack: track.id)?.currentModulation?.generation
        }
        graph.scheduleAll(fromBeat: 0, tempoMap: tempo)   // nil meter: constant 4/4
        graph.prepareAllPlayers(withFrameCount: 8_192)
        graph.startAllPlayers(at: nil)
        try pull(through: 4 * 24_000)                     // beats 0 → 4
        let before = (generation(syncedTrack), generation(freeTrack))
        let staleSegments = graph.automationRenderer(forTrack: syncedTrack.id)?.currentModulation?.clock.count
        // THE MID-ROLL EDIT — no stop, no scheduleAll.
        let restaged = graph.restageRollMeterMap(newMeter)
        graph.applyParameters(tracks: tracks)
        let after = (generation(syncedTrack), generation(freeTrack))
        let segments = graph.automationRenderer(forTrack: syncedTrack.id)?.currentModulation?.clock.count
        // The same map again: nothing to restage, nothing to rebuild.
        let again = graph.restageRollMeterMap(newMeter)
        graph.applyParameters(tracks: tracks)
        let afterAgain = (generation(syncedTrack), generation(freeTrack))
        try pull(through: 14 * 24_000)                    // beats 4 → 14
        graph.stopAllPlayers()

        let expected = w44fExpectedEdges(steps: [1, 0, 0], stepBeats: 1, tempoMap: tempo, meterMap: newMeter,
                                         fromBeat: 0, throughBeat: 14).filter { $0.beat > 4 }
        let stale = w44fExpectedEdges(steps: [1, 0, 0], stepBeats: 1, tempoMap: tempo, meterMap: constant,
                                      fromBeat: 0, throughBeat: 14).filter { $0.beat > 4 }
        let match = w44Match(expected: expected, measured: w44Edges(out).filter { $0 > 4 * 24_000 })
        // Not `previous + 1`: the generation counter is shared with the MASTER
        // strip, which with no sources still takes a number on every key change
        // and publishes nil (`publishMasterModulation` increments before
        // `ModulationSnapshotBuilder.build`, which returns nil for an empty
        // strip), so the last number handed out is invisible here. One pass
        // calls `publishModulation` once per strip, so "once" is pinned
        // observably: newer than everything seen, and an identical pass after
        // it changes nothing.
        let previous = max(before.0 ?? 0, before.1 ?? 0)
        let masterRenderer = graph.masterAutomationRendererForTesting()
        print("[measured] W44F T-N3b generations synced/free: before \(String(describing: before)), after the "
              + "restage \(String(describing: after)), after the same map again \(String(describing: afterAgain)); "
              + "master renderer present \(masterRenderer != nil), its snapshot "
              + "\(masterRenderer?.currentModulation == nil ? "nil" : "non-nil"); "
              + "restage returned \(restaged) then \(again); clock segments \(staleSegments ?? -1) → "
              + "\(segments ?? -1); edges beats 4–14: \(expected.count) expected (stale map would be "
              + "\(stale.map(\.beat))), worst \(match.worst), missing \(match.missing.prefix(4)), spurious "
              + "\(match.spurious.prefix(4))")
        #expect(before.0 != nil && before.1 != nil)
        #expect(restaged, "a changed map while rolling must ask for a parameter pass")
        #expect((after.0 ?? 0) > previous, "the restage pass must rebuild the synced strip")
        #expect(after.1 == before.1, "a strip with no synced source is not republished")
        #expect(staleSegments == 1)
        #expect(segments == 2, "the new clock carries the change at beat 8")
        #expect(!again, "restaging an identical map asks for nothing")
        #expect(afterAgain.0 == after.0 && afterAgain.1 == after.1,
                "an identical pass after the restage must rebuild nothing: one rebuild per edit")
        #expect(expected.map(\.beat) != stale.map(\.beat), "the fixture must tell the two maps apart")
        #expect(match.missing.isEmpty && match.spurious.isEmpty && match.worst <= 1)
    }
}
