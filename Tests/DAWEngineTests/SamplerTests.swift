import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M3 (v): the built-in sampler. Fixture WAVs are generated programmatically
/// at 44.1 kHz and rendered through the 48 kHz graph rate, so every pitched
/// assertion also exercises the fileRate/graphRate resampling math.
///
///  · DIRECT renders drive `SamplerInstrument.render()` in 512-frame quanta
///    with hand-built event arrays (mimicking `InstrumentRenderer`'s
///    slicing) — frequencies, envelopes, and zone routing measured
///    sample-exactly.
///  · OFFLINE renders go through `OfflineRenderer` with NO factory override,
///    pinning the `.sampler` descriptor → SamplerInstrument wiring through
///    the real graph.
@MainActor
@Suite("Sampler instrument", .serialized)
struct SamplerTests {
    private let sampleRate = 48_000.0

    // MARK: - Fixtures (written once per run)

    private struct Fixtures {
        let dir: URL
        /// 1.0 s, 440 Hz sine, amp 0.5, 44.1 kHz, MONO (exercises mono→both).
        let sine440Mono: URL
        /// 1.0 s, 300 Hz sine, amp 0.5, 44.1 kHz, stereo (identical channels).
        let sine300Stereo: URL
        /// 1.0 s, 1 kHz sine, amp 0.5, 44.1 kHz, mono.
        let sine1kMono: URL
        /// 6.0 s, 440 Hz sine, amp 0.5, 44.1 kHz, mono. m27 leg D needs a note
        /// that SOUNDS for several seconds: the breath contour's vibrato does
        /// not start until 0.5 s in, and measuring its ~5.5 Hz rate off the
        /// rendered audio needs several whole cycles after that. The 1 s
        /// fixtures free their voice long before any of that happens.
        let sine440MonoLong: URL
        /// 6.0 s, 1 kHz sine, amp 0.5, 44.1 kHz, mono — the leg D brightness
        /// probe, for the same duration reason.
        let sine1kMonoLong: URL
        /// Never created on disk.
        let missing: URL
    }

    private static var cachedFixtures: Fixtures?

    private func fixtures() throws -> Fixtures {
        if let cached = Self.cachedFixtures { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-sampler-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sine440Mono = dir.appendingPathComponent("sine440_44k1_mono.wav")
        try Self.writeSine(to: sine440Mono, frequency: 440, channels: 1)
        let sine300Stereo = dir.appendingPathComponent("sine300_44k1_stereo.wav")
        try Self.writeSine(to: sine300Stereo, frequency: 300, channels: 2)
        let sine1kMono = dir.appendingPathComponent("sine1k_44k1_mono.wav")
        try Self.writeSine(to: sine1kMono, frequency: 1_000, channels: 1)
        let sine440MonoLong = dir.appendingPathComponent("sine440_44k1_mono_6s.wav")
        try Self.writeSine(to: sine440MonoLong, frequency: 440, channels: 1, seconds: 6)
        let sine1kMonoLong = dir.appendingPathComponent("sine1k_44k1_mono_6s.wav")
        try Self.writeSine(to: sine1kMonoLong, frequency: 1_000, channels: 1, seconds: 6)
        let set = Fixtures(dir: dir, sine440Mono: sine440Mono, sine300Stereo: sine300Stereo,
                           sine1kMono: sine1kMono, sine440MonoLong: sine440MonoLong,
                           sine1kMonoLong: sine1kMonoLong,
                           missing: dir.appendingPathComponent("does-not-exist.wav"))
        Self.cachedFixtures = set
        return set
    }

    /// A Float32 WAV at 44.1 kHz, amp 0.5, identical channels — 1.0 s unless
    /// `seconds` says otherwise. Scoped so the AVAudioFile flushes and closes
    /// before anyone reads it.
    private static func writeSine(to url: URL, frequency: Double,
                                  channels channelCount: UInt32,
                                  seconds: Double = 1) throws {
        let fileRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fileRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(fileRate * seconds)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fileRate,
                                         channels: AVAudioChannelCount(channelCount),
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw NSError(domain: "SamplerTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        for frame in 0..<frames {
            let value = Float(0.5 * sin(2.0 * .pi * frequency * Double(frame) / fileRate))
            for channel in 0..<Int(channelCount) {
                data[channel][frame] = value
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    // MARK: - Harness

    private func makeSampler(_ params: SamplerParams) -> SamplerInstrument {
        let sampler = SamplerInstrument(params: params)
        sampler.prepare(sampleRate: sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return sampler
    }

    private func note(on: Int64, off: Int64, pitch: UInt8,
                      velocity: UInt8 = 127, id: UInt64) -> [ScheduledMIDIEvent] {
        [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                            kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
         ScheduledMIDIEvent(sampleTime: off, noteID: id,
                            kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
    }

    /// Renders the instrument directly in 512-frame quanta, replicating
    /// InstrumentRenderer's slicing. Optionally publishes `paramsToApply`
    /// once, at the quantum boundary ≥ `applyAtFrame`. Returns BOTH channels.
    private func renderDirect(
        _ instrument: SamplerInstrument,
        events unsorted: [ScheduledMIDIEvent],
        frames totalFrames: Int,
        quantum: Int = 512,
        applyAtFrame: Int? = nil,
        paramsToApply: SamplerParams? = nil
    ) throws -> (left: [Float], right: [Float]) {
        let events = unsorted.sorted { a, b in
            if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
            let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            return a.noteID < b.noteID
        }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        let channels = try #require(buffer.floatChannelData)

        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(totalFrames)
        right.reserveCapacity(totalFrames)
        var cursor = 0
        var rendered = 0
        var applied = false
        while rendered < totalFrames {
            if let applyAtFrame, let paramsToApply, !applied, rendered >= applyAtFrame {
                instrument.apply(params: paramsToApply)
                applied = true
            }
            let frames = min(quantum, totalFrames - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) {
                end += 1
            }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                let slice = UnsafeBufferPointer(rebasing: all[cursor..<end])
                instrument.render(events: slice, renderStart: Int64(rendered),
                                  frameCount: frames, output: output)
            }
            cursor = end
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))
            rendered += frames
        }
        return (left, right)
    }

    /// Goertzel magnitude at exactly `hz` (choose windows with a whole number
    /// of cycles for leakage-free bins). Absolute scale arbitrary.
    private func magnitude(_ samples: ArraySlice<Float>, hz: Double) -> Double {
        let w = 2.0 * Double.pi * hz / sampleRate
        let coeff = 2.0 * cos(w)
        var s1 = 0.0
        var s2 = 0.0
        for x in samples {
            let s0 = Double(x) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return max(0, power).squareRoot() / Double(samples.count)
    }

    /// Asserts the 0.4 s steady window (whole cycles at every asserted bin)
    /// is Goertzel-dominant at `hz`, corroborated by the zero-crossing
    /// frequency estimate. Returns the measured estimate.
    private func expectDominant(_ samples: [Float], hz: Double,
                                window: Range<Int>, label: String) -> Double {
        let target = magnitude(samples[window], hz: hz)
        let below = magnitude(samples[window], hz: hz / 2)
        let above = magnitude(samples[window], hz: hz * 2)
        let measured = TestSignals.dominantFrequency(
            byZeroCrossings: samples, sampleRate: sampleRate, in: window)
        print("[measured] \(label): zero-crossing \(measured) Hz; Goertzel @\(hz) "
              + "\(target), @\(hz / 2) \(below), @\(hz * 2) \(above)")
        #expect(target > 10 * below)
        #expect(target > 10 * above)
        #expect(abs(measured - hz) < 0.01 * hz)
        return measured
    }

    private func maxDifference(_ a: RenderedAudio, _ b: RenderedAudio) -> Float {
        #expect(a.frameCount == b.frameCount)
        #expect(a.channelData.count == b.channelData.count)
        var maxDifference: Float = 0
        for channel in 0..<min(a.channelData.count, b.channelData.count) {
            for frame in 0..<min(a.frameCount, b.frameCount) {
                maxDifference = max(maxDifference,
                                    abs(a.channelData[channel][frame] - b.channelData[channel][frame]))
            }
        }
        return maxDifference
    }

    // MARK: - Pitch (direct, 44.1 kHz source → 48 kHz graph)

    @Test("root-pitch playback preserves frequency: root 69 played at 69 → 440 Hz")
    func rootPitchPlayback() throws {
        let fixtures = try fixtures()
        let sampler = makeSampler(SamplerParams(
            zones: [SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69)],
            attack: 0.001, release: 0.05, gain: 0.8))
        let out = try renderDirect(sampler, events: note(on: 0, off: 90_000, pitch: 69, id: 0),
                                   frames: 24_000)
        _ = expectDominant(out.left, hz: 440, window: 4_800..<24_000, label: "root 69@69")
        // Mono source plays identically on both channels.
        #expect(out.left == out.right)
        // Amplitude: 0.5 fixture × (127/127) × zone gain 1 × params gain 0.8.
        let steady = TestSignals.peak(out.left, in: 4_800..<24_000)
        print("[measured] root-pitch steady peak: \(steady) (expected ≈ 0.4)")
        #expect(abs(steady - 0.4) < 0.02)
    }

    @Test("transposition: +12 semitones → 880 Hz, −12 semitones → 220 Hz")
    func transposition() throws {
        let fixtures = try fixtures()
        let params = SamplerParams(
            zones: [SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69)],
            attack: 0.001, release: 0.05, gain: 0.8)

        // +12: increment doubles, so the 1.0 s file lasts ~24 000 out frames.
        let up = try renderDirect(makeSampler(params),
                                  events: note(on: 0, off: 90_000, pitch: 81, id: 0),
                                  frames: 24_000)
        _ = expectDominant(up.left, hz: 880, window: 2_400..<21_600, label: "root 69@81")

        let down = try renderDirect(makeSampler(params),
                                    events: note(on: 0, off: 90_000, pitch: 57, id: 0),
                                    frames: 24_000)
        _ = expectDominant(down.left, hz: 220, window: 4_800..<24_000, label: "root 69@57")
    }

    @Test("zone mapping: split at 60 routes low notes to the 300 Hz zone, high to the 1 kHz zone")
    func zoneMapping() throws {
        let fixtures = try fixtures()
        let params = SamplerParams(
            zones: [
                SamplerZone(audioFileURL: fixtures.sine300Stereo, rootPitch: 48,
                            minPitch: 0, maxPitch: 59),
                SamplerZone(audioFileURL: fixtures.sine1kMono, rootPitch: 72,
                            minPitch: 60, maxPitch: 127),
            ],
            attack: 0.001, release: 0.05, gain: 0.8)

        // Played at each zone's root → no transposition, frequency proves routing.
        let low = try renderDirect(makeSampler(params),
                                   events: note(on: 0, off: 90_000, pitch: 48, id: 0),
                                   frames: 24_000)
        _ = expectDominant(low.left, hz: 300, window: 4_800..<24_000, label: "zone low 48")

        let high = try renderDirect(makeSampler(params),
                                    events: note(on: 0, off: 90_000, pitch: 72, id: 0),
                                    frames: 24_000)
        _ = expectDominant(high.left, hz: 1_000, window: 4_800..<24_000, label: "zone high 72")
    }

    // MARK: - One-shot vs release (direct)

    @Test("one-shot ignores noteOff and plays to buffer end; non-one-shot ramps to exact zero")
    func oneShotVersusRelease() throws {
        let fixtures = try fixtures()
        let zone = [SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69)]
        // 1.0 s file at root ≡ 48 000 output frames; noteOff halfway (24 000).
        let events = note(on: 0, off: 24_000, pitch: 69, id: 0)

        let oneShot = try renderDirect(
            makeSampler(SamplerParams(zones: zone, oneShot: true,
                                      attack: 0.001, release: 0.05, gain: 0.8)),
            events: events, frames: 52_000)
        let sustained = try renderDirect(
            makeSampler(SamplerParams(zones: zone, oneShot: false,
                                      attack: 0.001, release: 0.05, gain: 0.8)),
            events: events, frames: 52_000)

        let oneShotPastOff = TestSignals.peak(oneShot.left, in: 30_000..<44_000)
        // Non-one-shot: release 0.05 s = 2400 frames → exact zeros from
        // 26 400 + one 512-frame quantum of slack.
        let sustainedPastRelease = TestSignals.peak(sustained.left, in: 27_500..<52_000)
        // One-shot voice frees itself at buffer end (48 000) — zeros after.
        let oneShotPastEnd = TestSignals.peak(oneShot.left, in: 48_600..<52_000)
        print("[measured] one-shot past off: \(oneShotPastOff), past buffer end: "
              + "\(oneShotPastEnd); sustained past release: \(sustainedPastRelease)")
        #expect(oneShotPastOff > 0.3)          // still sounding well past the off
        #expect(sustainedPastRelease == 0)     // exact zeros: voice freed
        #expect(oneShotPastEnd == 0)           // buffer end frees the voice
    }

    @Test("release ramp: audible tail, then exact zeros within release + one quantum")
    func releaseReachesExactZeros() throws {
        let fixtures = try fixtures()
        let sampler = makeSampler(SamplerParams(
            zones: [SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69)],
            attack: 0.001, release: 0.1, gain: 0.8))
        // off at 24 000; release 0.1 s = 4800 frames → zeros from 28 800 (+512 slack).
        let out = try renderDirect(sampler, events: note(on: 0, off: 24_000, pitch: 69, id: 0),
                                   frames: 48_000)
        let tailStart = TestSignals.peak(out.left, in: 24_100..<24_600)
        let tailLate = TestSignals.peak(out.left, in: 27_500..<28_000)
        let silence = TestSignals.peak(out.left, in: 29_500..<48_000)
        print("[measured] release — tailStart: \(tailStart), tailLate: \(tailLate), "
              + "silence from 29 500: \(silence)")
        #expect(tailStart > 0.1)        // NOT a hard stop
        #expect(tailLate > 0)           // still decaying inside the release
        #expect(tailLate < tailStart)
        #expect(silence == 0)           // exact zeros: voice freed
    }

    // MARK: - Degenerate zones (direct)

    @Test("no matching zone / empty zones / missing file → exact silence, no crash")
    func degenerateZoneCases() throws {
        let fixtures = try fixtures()
        let events = note(on: 0, off: 12_000, pitch: 40, id: 0)

        // Pitch 40 outside the only zone's 60...127 span → ignored.
        let unmatched = try renderDirect(
            makeSampler(SamplerParams(zones: [
                SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69,
                            minPitch: 60, maxPitch: 127)])),
            events: events, frames: 24_000)
        #expect(TestSignals.peak(unmatched.left, in: 0..<24_000) == 0)
        #expect(TestSignals.peak(unmatched.right, in: 0..<24_000) == 0)

        // No zones at all (the SamplerParams() nil-default resolution).
        let empty = try renderDirect(makeSampler(SamplerParams()),
                                     events: events, frames: 24_000)
        #expect(TestSignals.peak(empty.left, in: 0..<24_000) == 0)

        // Missing file: the zone is skipped with a readable note; a later
        // GOOD zone still loads and is not shadowed by the dead one.
        let mixed = makeSampler(SamplerParams(
            zones: [
                SamplerZone(audioFileURL: fixtures.missing, rootPitch: 69),
                SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69),
            ],
            attack: 0.001, release: 0.05, gain: 0.8))
        print("[measured] zone load notes: \(mixed.zoneLoadNotes)")
        #expect(mixed.zoneLoadNotes.count == 1)
        let out = try renderDirect(mixed, events: note(on: 0, off: 90_000, pitch: 69, id: 1),
                                   frames: 24_000)
        #expect(TestSignals.peak(out.left, in: 4_800..<24_000) > 0.3)

        // ONLY a missing zone → silence, no crash.
        let dead = makeSampler(SamplerParams(
            zones: [SamplerZone(audioFileURL: fixtures.missing, rootPitch: 69)]))
        #expect(dead.zoneLoadNotes.count == 1)
        let silent = try renderDirect(dead, events: note(on: 0, off: 90_000, pitch: 69, id: 2),
                                      frames: 24_000)
        #expect(TestSignals.peak(silent.left, in: 0..<24_000) == 0)
    }

    // MARK: - RT-safe scalar updates (direct)

    @Test("apply(params:) gain change mid-render: held voice keeps sounding, pre-switch bit-identical, post-switch doubled")
    func scalarUpdateInPlace() throws {
        let fixtures = try fixtures()
        let zone = [SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69)]
        let initial = SamplerParams(zones: zone, attack: 0.001, release: 0.05, gain: 0.4)
        let doubled = SamplerParams(zones: zone, attack: 0.001, release: 0.05, gain: 0.8)
        let events = note(on: 0, off: 90_000, pitch: 69, id: 0)  // held throughout
        let switchFrame = 24_064  // 47 × 512-frame quanta

        let unswitched = try renderDirect(makeSampler(initial), events: events, frames: 46_000)
        let out = try renderDirect(makeSampler(initial), events: events, frames: 46_000,
                                   applyAtFrame: switchFrame, paramsToApply: doubled)

        // Before the publish lands, the two renders are bit-identical.
        #expect(Array(out.left[0..<switchFrame]) == Array(unswitched.left[0..<switchFrame]))
        // The held voice never gaps: every 256-frame window across the switch
        // boundary carries signal (440 Hz period ≈ 109 frames < window).
        var minWindowPeak: Float = .greatestFiniteMagnitude
        var window = 23_552
        while window < 25_600 {
            minWindowPeak = min(minWindowPeak,
                                TestSignals.peak(out.left, in: window..<(window + 256)))
            window += 256
        }
        // Post-switch the same voice sounds at exactly 2× (gain 0.4 → 0.8);
        // 26 400..<45 600 is 0.4 s = 176 whole cycles of 440 Hz.
        let ratio = magnitude(out.left[26_400..<45_600], hz: 440)
            / magnitude(unswitched.left[26_400..<45_600], hz: 440)
        print("[measured] scalar switch — min 256-frame window peak: \(minWindowPeak), "
              + "post-switch magnitude ratio: \(ratio)")
        #expect(minWindowPeak > 0.05)          // no gap of zeros at the boundary
        #expect(abs(ratio - 2.0) < 0.02)       // in-place gain landed on the held voice
    }

    // MARK: - Descriptor wiring + graph semantics

    private func midiClip(pitch: Int = 69) -> Clip {
        Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: pitch, velocity: 127, startBeat: 0, lengthBeats: 2),
        ])
    }

    @Test("offline sampler renders are bit-identical run to run and audibly the sample")
    func determinismThroughOfflineRenderer() throws {
        let fixtures = try fixtures()
        let track = Track(
            name: "Sampler", kind: .instrument, clips: [midiClip()],
            instrument: InstrumentDescriptor(
                kind: .sampler,
                sampler: SamplerParams(
                    zones: [SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69)],
                    attack: 0.001, release: 0.05, gain: 0.8)))
        let a = try OfflineRenderer().render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                             fromBeat: 0, durationSeconds: 1.5)
        let b = try OfflineRenderer().render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                             fromBeat: 0, durationSeconds: 1.5)
        let difference = maxDifference(a, b)
        let peak = TestSignals.peak(a.channelData[0], in: 0..<a.frameCount)
        let measured = TestSignals.dominantFrequency(
            byZeroCrossings: a.channelData[0], sampleRate: sampleRate, in: 4_800..<40_000)
        print("[measured] offline determinism null: \(difference), peak: \(peak), "
              + "frequency: \(measured) Hz")
        #expect(difference == 0.0)
        #expect(peak > 0.3)                    // the null means something: real signal
        #expect(abs(measured - 440) < 4.4)     // and it IS the sample, through the graph
    }

    @Test("sampler ZONES change flips the reconcile signature; scalar-only change does not")
    func zonesAreStructuralScalarsAreNot() throws {
        let fixtures = try fixtures()
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        let graph = PlaybackGraph(engine: engine)

        let zoneA = SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69)
        var track = Track(name: "Sampler", kind: .instrument, clips: [midiClip()],
                          instrument: InstrumentDescriptor(
                              kind: .sampler, sampler: SamplerParams(zones: [zoneA])))
        #expect(graph.reconcile(tracks: [track]) == true)   // first build

        // Scalar-only change (gain): same zones → NOT schedule-affecting; it
        // lands via applyParameters → apply(params:) with no rebuild.
        track.instrument = InstrumentDescriptor(
            kind: .sampler, sampler: SamplerParams(zones: [zoneA], gain: 0.5))
        #expect(graph.reconcile(tracks: [track]) == false)
        graph.applyParameters(tracks: [track])

        // Zones change (different root) → STRUCTURAL: rebuild + reschedule.
        track.instrument = InstrumentDescriptor(
            kind: .sampler,
            sampler: SamplerParams(zones: [SamplerZone(
                id: zoneA.id, audioFileURL: fixtures.sine440Mono, rootPitch: 60)]))
        #expect(graph.reconcile(tracks: [track]) == true)
        #expect(graph.trackIDs == [track.id])

        // Kind change away from sampler → also structural.
        track.instrument = InstrumentDescriptor(kind: .polySynth)
        #expect(graph.reconcile(tracks: [track]) == true)
        #expect(graph.trackIDs == [track.id])
    }

    // MARK: - m27 continuous expression (CC11 / CC2 / CC1 → amplitude)

    /// The bug this whole round exists to kill: an authored CC11 contour
    /// reached the model and produced BYTE-IDENTICAL audio, because the
    /// sampler dropped every CC but 64 at the voice. So the gate is not "the
    /// value reached the model" — it is "the rendered SAMPLES moved, in the
    /// right direction, by the right amount".

    private func expressionTrack(_ fixtures: Fixtures,
                                 lanes: [MIDIControllerLane],
                                 modDepth: Double? = nil) -> Track {
        Track(name: "Sampler", kind: .instrument,
              clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 4,
                           notes: [MIDINote(pitch: 69, velocity: 127,
                                            startBeat: 0, lengthBeats: 2)],
                           controllerLanes: lanes)],
              instrument: InstrumentDescriptor(
                kind: .sampler,
                sampler: SamplerParams(
                    zones: [SamplerZone(audioFileURL: fixtures.sine440Mono, rootPitch: 69)],
                    attack: 0.001, release: 0.05, gain: 0.8,
                    expressionModDepth: modDepth)))
    }

    private func renderExpression(_ track: Track) throws -> RenderedAudio {
        try OfflineRenderer().render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                     fromBeat: 0, durationSeconds: 1.5)
    }

    /// RMS of one channel over a frame window. Absolute scale is the render's.
    private func rmsLevel(_ audio: RenderedAudio, _ window: Range<Int>) -> Double {
        var sum = 0.0
        for frame in window { sum += Double(audio.channelData[0][frame] * audio.channelData[0][frame]) }
        return (sum / Double(window.count)).squareRoot()
    }

    /// THE REGRESSION GUARD. CC11's neutral is 127 = FULL, so a lane pinned at
    /// 127 must be indistinguishable from having no lane at all — EXACTLY, not
    /// within an epsilon. If this ever drifts, every existing project in the
    /// tree got quieter the day expression shipped.
    @Test("a CC11 lane pinned at 127 renders BIT-IDENTICALLY to no lane at all")
    func fullExpressionLaneIsBitIdenticalToNoLane() throws {
        let fixtures = try fixtures()
        let bare = try renderExpression(expressionTrack(fixtures, lanes: []))
        let pinned = try renderExpression(expressionTrack(fixtures, lanes: [
            MIDIControllerLane(type: .cc(controller: 11),
                               points: [MIDIControllerPoint(beat: 0, value: 127),
                                        MIDIControllerPoint(beat: 1, value: 127)]),
        ]))
        let difference = maxDifference(bare, pinned)
        let peak = TestSignals.peak(bare.channelData[0], in: 0..<bare.frameCount)
        print("[measured] CC11@127 vs no-lane null: \(difference), peak: \(peak)")
        #expect(difference == 0.0)   // exact — ×1.0 is an IEEE identity
        #expect(peak > 0.3)          // the null means something: real signal underneath
    }

    /// The same guard for the two controllers whose MIDI neutral is 0. Their
    /// chase prefix injects 0 at the block anchor, so an UNCONDITIONAL
    /// CC1/CC2 attenuator would render silence here. `expressionModDepth`
    /// defaults to off precisely so it does not.
    @Test("a CC1 lane sitting at 0 is inert until expressionModDepth opts in")
    func modWheelNeedsTheDepthOptIn() throws {
        let fixtures = try fixtures()
        let lanes = [MIDIControllerLane(type: .cc(controller: 1),
                                        points: [MIDIControllerPoint(beat: 0, value: 0),
                                                 MIDIControllerPoint(beat: 1, value: 127)])]
        let bare = try renderExpression(expressionTrack(fixtures, lanes: []))
        let offByDefault = try renderExpression(expressionTrack(fixtures, lanes: lanes))
        let optedIn = try renderExpression(expressionTrack(fixtures, lanes: lanes, modDepth: 1))

        let difference = maxDifference(bare, offByDefault)
        // 0.10-0.40 s: mod wheel at 0. 0.60-0.90 s: mod wheel at 127.
        let quiet = rmsLevel(optedIn, 4_800..<19_200)
        let loud = rmsLevel(optedIn, 28_800..<43_200)
        print("[measured] CC1 depth-nil null: \(difference); depth-1 RMS quiet \(quiet) "
              + "→ loud \(loud), ratio \(loud / max(quiet, 1e-12))")
        #expect(difference == 0.0)            // depth 0 ⇒ the lane cannot bite
        #expect(loud > quiet * 20)            // depth 1 ⇒ it bites hard
        #expect(quiet < 0.01)                 // and 0 really means (near) silence
    }

    /// The direction-and-amount assertion. A CC11 step from 127 to 32 must
    /// scale the sustained tone by 32/127 = 0.252 — measured, not asserted by
    /// eye — while leaving everything before the step untouched.
    @Test("a CC11 contour changes the rendered samples by the amount it asks for")
    func expressionContourScalesTheRenderedAudio() throws {
        let fixtures = try fixtures()
        let flat = try renderExpression(expressionTrack(fixtures, lanes: [
            MIDIControllerLane(type: .cc(controller: 11),
                               points: [MIDIControllerPoint(beat: 0, value: 127),
                                        MIDIControllerPoint(beat: 1, value: 127)]),
        ]))
        let contour = try renderExpression(expressionTrack(fixtures, lanes: [
            MIDIControllerLane(type: .cc(controller: 11),
                               points: [MIDIControllerPoint(beat: 0, value: 127),
                                        MIDIControllerPoint(beat: 1, value: 32)]),
        ]))
        // Beat 1 at 120 BPM = 0.5 s = frame 24000. Before it the two renders
        // must agree bit-for-bit; after it the contour must be 32/127 of flat.
        var beforeDifference: Float = 0
        for frame in 0..<24_000 {
            beforeDifference = max(beforeDifference,
                                   abs(flat.channelData[0][frame] - contour.channelData[0][frame]))
        }
        let flatAfter = rmsLevel(flat, 28_800..<43_200)      // 0.60-0.90 s, fully settled
        let contourAfter = rmsLevel(contour, 28_800..<43_200)
        let ratio = contourAfter / flatAfter
        print("[measured] CC11 127→32: pre-step null \(beforeDifference); post-step RMS "
              + "\(flatAfter) → \(contourAfter), ratio \(ratio) (expected \(32.0 / 127.0))")
        #expect(beforeDifference == 0.0)                     // nothing moved before the point
        #expect(abs(ratio - 32.0 / 127.0) < 0.01)            // and exactly what was asked after
    }

    /// Controller lanes are STEPWISE, so an unsmoothed multiplier is one click
    /// per lane point. A 127→0 step is the worst case: unsmoothed it would put
    /// a ~0.4 discontinuity into a single sample interval, ~17× the 440 Hz
    /// tone's own steepest slope.
    @Test("a hard CC11 step is smoothed — no click at the lane point")
    func expressionStepIsSmoothed() throws {
        let fixtures = try fixtures()
        let stepped = try renderExpression(expressionTrack(fixtures, lanes: [
            MIDIControllerLane(type: .cc(controller: 11),
                               points: [MIDIControllerPoint(beat: 0, value: 127),
                                        MIDIControllerPoint(beat: 1, value: 0)]),
        ]))
        // The tone's own steepest slope: 0.4 peak × 2π × 440 / 48000.
        let naturalSlope = 0.4 * 2.0 * Double.pi * 440.0 / sampleRate
        var maxDelta: Float = 0
        for frame in 23_000..<26_000 {   // ±~20 ms around the step at frame 24000
            maxDelta = max(maxDelta, abs(stepped.channelData[0][frame]
                                         - stepped.channelData[0][frame - 1]))
        }
        print("[measured] 127→0 step, max adjacent-sample delta: \(maxDelta) "
              + "(tone's own slope \(naturalSlope); an unsmoothed step would be ~0.4)")
        #expect(maxDelta < 0.05)         // ≫ smaller than the 0.4 an unsmoothed step gives
        #expect(rmsLevel(stepped, 28_800..<43_200) < 0.005)   // and it did reach silence
    }

    // MARK: - m27 leg B: dynamic-layer crossfade

    /// Two layers on ONE key in different groups, so a single note-on fires
    /// both: a 440 Hz "soft" layer that fades OUT as CC1 rises and a 1 kHz
    /// "loud" layer that fades IN. The two Goertzel bins then read the
    /// crossfade directly. CC1 drives it (not CC11) because CC11 also
    /// attenuates amplitude — using it here would confound layer mix with
    /// loudness and the measurement would prove nothing.
    private func layeredTrack(_ fixtures: Fixtures,
                              cc1: [MIDIControllerPoint]) -> Track {
        let soft = SamplerZone(
            audioFileURL: fixtures.sine440Mono, rootPitch: 69, group: 1,
            crossfade: SamplerCrossfade(controller: 1, ccOutLo: 0, ccOutHi: 127))
        let loud = SamplerZone(
            audioFileURL: fixtures.sine1kMono, rootPitch: 69, group: 2,
            crossfade: SamplerCrossfade(controller: 1, ccInLo: 0, ccInHi: 127))
        return Track(
            name: "Sampler", kind: .instrument,
            clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 4,
                         notes: [MIDINote(pitch: 69, velocity: 127,
                                          startBeat: 0, lengthBeats: 2)],
                         controllerLanes: [MIDIControllerLane(
                            type: .cc(controller: 1), points: cc1)])],
            instrument: InstrumentDescriptor(
                kind: .sampler,
                sampler: SamplerParams(zones: [soft, loud],
                                       attack: 0.001, release: 0.05, gain: 0.8)))
    }

    @Test("leg B: a CC crossfade moves the layer mix, and does it MID-NOTE")
    func ccCrossfadeMovesTheLayerMix() throws {
        let fixtures = try fixtures()
        let window = 28_800..<43_200                       // 0.60-0.90 s
        let atZero = try renderExpression(layeredTrack(
            fixtures, cc1: [MIDIControllerPoint(beat: 0, value: 0)]))
        let atFull = try renderExpression(layeredTrack(
            fixtures, cc1: [MIDIControllerPoint(beat: 0, value: 127)]))
        let soft0 = magnitude(atZero.channelData[0][window], hz: 440)
        let loud0 = magnitude(atZero.channelData[0][window], hz: 1_000)
        let soft1 = magnitude(atFull.channelData[0][window], hz: 440)
        let loud1 = magnitude(atFull.channelData[0][window], hz: 1_000)
        print("[measured] leg B CC1=0: 440 Hz \(soft0), 1 kHz \(loud0); "
              + "CC1=127: 440 Hz \(soft1), 1 kHz \(loud1)")
        #expect(soft0 > loud0 * 50)      // at 0 the soft layer owns the sound
        #expect(loud1 > soft1 * 50)      // at 127 the loud layer does

        // THE POINT OF LEG B over a velocity crossfade: this happens WITHIN
        // one held note. Ramp CC1 across the note and watch the mix invert.
        let sweep = try renderExpression(layeredTrack(fixtures, cc1: [
            MIDIControllerPoint(beat: 0, value: 0),
            MIDIControllerPoint(beat: 1, value: 127),
        ]))
        let early = 4_800..<19_200                        // 0.10-0.40 s
        let earlySoft = magnitude(sweep.channelData[0][early], hz: 440)
        let earlyLoud = magnitude(sweep.channelData[0][early], hz: 1_000)
        let lateSoft = magnitude(sweep.channelData[0][window], hz: 440)
        let lateLoud = magnitude(sweep.channelData[0][window], hz: 1_000)
        print("[measured] leg B mid-note sweep: early 440/1k \(earlySoft)/\(earlyLoud) "
              + "→ late \(lateSoft)/\(lateLoud)")
        #expect(earlySoft > earlyLoud)   // starts soft-dominant
        #expect(lateLoud > lateSoft)     // ends loud-dominant, same note
    }

    @Test("leg B: the crossfade is equal-power — the midpoint holds level, not 0.5")
    func ccCrossfadeIsEqualPower() throws {
        let fixtures = try fixtures()
        let window = 28_800..<43_200
        let full = try renderExpression(layeredTrack(
            fixtures, cc1: [MIDIControllerPoint(beat: 0, value: 127)]))
        let mid = try renderExpression(layeredTrack(
            fixtures, cc1: [MIDIControllerPoint(beat: 0, value: 64)]))
        // At CC1 = 64 both gains are sqrt(64/127) and sqrt(63/127) ≈ 0.71, so
        // each layer's own bin sits at ~0.71 of its solo level — the
        // equal-power signature. A LINEAR-gain crossfade would put it at 0.50.
        let ratio = magnitude(mid.channelData[0][window], hz: 1_000)
            / magnitude(full.channelData[0][window], hz: 1_000)
        let expected = (64.0 / 127.0).squareRoot()
        print("[measured] leg B equal-power midpoint: 1 kHz ratio \(ratio), "
              + "expected \(expected) (a linear-gain curve would give \(64.0 / 127.0))")
        #expect(abs(ratio - expected) < 0.02)
    }

    // MARK: - m27 leg C: per-voice low-pass, cutoff tracking the controller

    /// A 1 kHz tone through the filter, so the Goertzel bin IS the frequency
    /// response. The filter is driven by CC1 here and `expressionModDepth` is
    /// left off, which isolates BRIGHTNESS from LOUDNESS — otherwise CC11
    /// would move both at once and the measurement would not be a filter
    /// measurement.
    private func filterTrack(_ fixtures: Fixtures, cc1Value: Int?,
                             filterDepth: Double?) -> Track {
        let lanes = cc1Value.map {
            [MIDIControllerLane(type: .cc(controller: 1),
                                points: [MIDIControllerPoint(beat: 0, value: $0)])]
        } ?? []
        return Track(name: "Sampler", kind: .instrument,
                     clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 4,
                                  notes: [MIDINote(pitch: 60, velocity: 127,
                                                   startBeat: 0, lengthBeats: 2)],
                                  controllerLanes: lanes)],
                     instrument: InstrumentDescriptor(
                        kind: .sampler,
                        sampler: SamplerParams(
                            zones: [SamplerZone(audioFileURL: fixtures.sine1kMono,
                                                rootPitch: 60)],
                            attack: 0.001, release: 0.05, gain: 0.8,
                            expressionFilterDepth: filterDepth,
                            expressionFilterCC: filterDepth == nil ? nil : 1)))
    }

    @Test("leg C: the filter is OFF by default and sweeps 1 kHz by its one-pole response")
    func expressionFilterFrequencyResponse() throws {
        let fixtures = try fixtures()
        let window = 28_800..<43_200                      // 0.60-0.90 s, settled
        let open = try renderExpression(filterTrack(fixtures, cc1Value: nil, filterDepth: nil))
        // Depth nil must be indistinguishable from having no filter concept.
        let laneOnly = try renderExpression(
            filterTrack(fixtures, cc1Value: 0, filterDepth: nil))
        let offNull = maxDifference(open, laneOnly)

        let wideOpen = try renderExpression(
            filterTrack(fixtures, cc1Value: 127, filterDepth: 1))
        let closed = try renderExpression(filterTrack(fixtures, cc1Value: 0, filterDepth: 1))

        let reference = magnitude(open.channelData[0][window], hz: 1_000)
        let openRatio = magnitude(wideOpen.channelData[0][window], hz: 1_000) / reference
        let closedRatio = magnitude(closed.channelData[0][window], hz: 1_000) / reference
        // One-pole g = 1 − e^(−2π fc/fs) at fs = 48 kHz:
        //   fc = 20 kHz → |H(1 kHz)| = 0.9993 (effectively transparent)
        //   fc =  400 Hz → |H(1 kHz)| = 0.3717 (−8.6 dB)
        print("[measured] leg C — depth-nil null: \(offNull); |H(1kHz)| at CC1=127: "
              + "\(openRatio) (expect ~0.9993), at CC1=0: \(closedRatio) (expect ~0.3717)")
        #expect(offNull == 0.0)                          // off means OFF, bit-exact
        #expect(abs(openRatio - 0.9993) < 0.01)
        #expect(abs(closedRatio - 0.3717) < 0.02)
        // And the amplitude path stayed out of it: CC1 with modDepth off must
        // not have attenuated anything, so the closed render is DARKER, not
        // merely quieter — its broadband RMS falls far less than its 1 kHz bin
        // would if this were a gain change.
        #expect(closedRatio < 0.5)
    }

    @Test("leg C: brightness follows the controller mid-note, and denormals stay flushed")
    func expressionFilterTracksMidNote() throws {
        let fixtures = try fixtures()
        let track = Track(
            name: "Sampler", kind: .instrument,
            clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 4,
                         notes: [MIDINote(pitch: 60, velocity: 127,
                                          startBeat: 0, lengthBeats: 2)],
                         controllerLanes: [MIDIControllerLane(
                            type: .cc(controller: 1),
                            points: [MIDIControllerPoint(beat: 0, value: 0),
                                     MIDIControllerPoint(beat: 1, value: 127)])])],
            instrument: InstrumentDescriptor(
                kind: .sampler,
                sampler: SamplerParams(
                    zones: [SamplerZone(audioFileURL: fixtures.sine1kMono, rootPitch: 60)],
                    attack: 0.001, release: 0.05, gain: 0.8,
                    expressionFilterDepth: 1, expressionFilterCC: 1)))
        let out = try renderExpression(track)
        let dark = magnitude(out.channelData[0][9_600..<19_200], hz: 1_000)   // 0.20-0.40 s
        let bright = magnitude(out.channelData[0][28_800..<43_200], hz: 1_000) // 0.60-0.90 s
        // After the note ends and releases, the one-pole is fed exact zeros —
        // its memory must reach TRUE zero, not a denormal trickle.
        let tail = out.channelData[0][(out.frameCount - 2_400)..<out.frameCount]
        let tailPeak = tail.map { abs($0) }.max() ?? 0
        print("[measured] leg C mid-note sweep: 1 kHz dark \(dark) → bright \(bright), "
              + "ratio \(bright / dark); post-release tail peak \(tailPeak)")
        #expect(bright > dark * 2)        // the controller really opened it up
        #expect(tailPeak == 0.0)          // and the recursive state flushed to zero
    }

    // MARK: - m27 leg D: the GENERATED breath contour must move a render

    /// ⛔ The gate for leg D is NOT "the points landed in the model". The bug
    /// this whole round exists to kill was a CC11 contour that reached the
    /// model correctly and produced BYTE-IDENTICAL audio. So every assertion
    /// below is on rendered SAMPLES: the swell scales them by the amount the
    /// generated lane asks for, the vibrato shows up as a measurable ~5.5 Hz
    /// frequency modulation of the rendered tone, and the neutral case is
    /// bit-identical to having no contour at all.
    ///
    /// All of these use the 6 s fixtures: the default contour does not start
    /// vibrato until 0.5 s in, and measuring its rate needs several cycles
    /// after that. On a 1 s fixture the voice frees before any of it happens —
    /// and a test that renders silence passes a "the audio changed" assertion
    /// exactly as readily as one that renders the feature.

    /// One 5.5 s note (11 beats at 120 BPM) carrying whatever `BreathContour`
    /// generates for it, on a sampler whose only zone is the 6 s tone.
    private func breathTrack(_ fixtures: Fixtures,
                             options: BreathContour.Options?,
                             tone: URL,
                             rootPitch: Int = 69,
                             filterDepth: Double? = nil,
                             filterCC: Int? = nil) -> Track {
        let noteBeats = 11.0
        let lanes: [MIDIControllerLane]
        if let options {
            let generated = BreathContour.generate(
                noteStartBeat: 0, noteLengthBeats: noteBeats, clipStartBeat: 0,
                tempoMap: TempoMap(constantBPM: 120), options: options)
            var built = [MIDIControllerLane(type: .cc(controller: options.expressionCC),
                                            points: generated.expression)]
            if !generated.pitchBend.isEmpty {
                built.append(MIDIControllerLane(type: .pitchBend, points: generated.pitchBend))
            }
            lanes = built
        } else {
            lanes = []
        }
        return Track(
            name: "Sampler", kind: .instrument,
            clips: [Clip(name: "midi", startBeat: 0, lengthBeats: noteBeats + 1,
                         notes: [MIDINote(pitch: rootPitch, velocity: 127,
                                          startBeat: 0, lengthBeats: noteBeats)],
                         controllerLanes: lanes)],
            instrument: InstrumentDescriptor(
                kind: .sampler,
                sampler: SamplerParams(zones: [SamplerZone(audioFileURL: tone,
                                                           rootPitch: rootPitch)],
                                       attack: 0.001, release: 0.05, gain: 0.8,
                                       expressionFilterDepth: filterDepth,
                                       expressionFilterCC: filterCC)))
    }

    private func renderBreath(_ track: Track) throws -> RenderedAudio {
        try OfflineRenderer().render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                     fromBeat: 0, durationSeconds: 6.0)
    }

    /// THE REGRESSION GUARD, leg D's copy of leg A's. A contour with every
    /// amount turned off is CC11 pinned at its peak (127 = unity) and pitch
    /// bend pinned at 8192 (centre) — both are IEEE identities, so the render
    /// must be bit-identical to having no lanes at all. If this drifts, merely
    /// CALLING the primitive changed the sound of a part.
    @Test("leg D: a contour with every amount at zero renders BIT-IDENTICALLY to no contour")
    func neutralContourIsBitIdentical() throws {
        let fixtures = try fixtures()
        let neutral = BreathContour.Options(depth: 0, vibratoDepthCents: 0, sharpenCents: 0)
        let bare = try renderBreath(breathTrack(fixtures, options: nil,
                                                tone: fixtures.sine440MonoLong))
        let flat = try renderBreath(breathTrack(fixtures, options: neutral,
                                                tone: fixtures.sine440MonoLong))
        let difference = maxDifference(bare, flat)
        let peak = TestSignals.peak(bare.channelData[0], in: 0..<bare.frameCount)
        // Prove the lanes were really there — a null over two EMPTY lane sets
        // would pass this test while proving nothing.
        let laneCounts = breathTrack(fixtures, options: neutral, tone: fixtures.sine440MonoLong)
            .clips[0].controllerLanes.map { ($0.type.wireKey, $0.points.count) }
        print("[measured] leg D neutral-contour null: \(difference), peak \(peak), "
              + "lanes actually written: \(laneCounts)")
        #expect(difference == 0.0)
        #expect(peak > 0.3)
        #expect(laneCounts.count == 2)               // CC11 AND pitchBend were written
        #expect(laneCounts.allSatisfy { $0.1 >= 2 })
    }

    /// THE HEADLINE GATE. A default contour must scale the rendered samples by
    /// what its own expression lane asks for — measured against the lane, not
    /// against a hand-written expectation, so the assertion cannot drift away
    /// from the generator.
    @Test("leg D: the generated swell scales the render by the amount the lane asks for")
    func breathSwellScalesTheRender() throws {
        let fixtures = try fixtures()
        let options = BreathContour.Options(vibratoDepthCents: 0, sharpenCents: 0)
        let track = breathTrack(fixtures, options: options, tone: fixtures.sine440MonoLong)
        let bare = try renderBreath(breathTrack(fixtures, options: nil,
                                                tone: fixtures.sine440MonoLong))
        let contour = try renderBreath(track)
        let lane = try #require(track.clips[0].controllerLanes
            .first { $0.type == .cc(controller: 11) })

        // 0.15-0.35 s: just past the settling dip. 3.7-4.1 s: the top of the
        // swell (65 % of a 5.5 s note = 3.575 s).
        let earlyWindow = 7_200..<16_800
        let peakWindow = 177_600..<196_800
        func meanLaneValue(_ window: Range<Int>) -> Double {
            let values = window.map { frame -> Double in
                Double(lane.value(atBeat: Double(frame) / sampleRate * 2) ?? 127)
            }
            return values.reduce(0, +) / Double(values.count)
        }
        let expected = meanLaneValue(earlyWindow) / meanLaneValue(peakWindow)
        let measured = rmsLevel(contour, earlyWindow) / rmsLevel(contour, peakWindow)
        let moved = maxDifference(bare, contour)
        print("[measured] leg D swell: lane mean \(meanLaneValue(earlyWindow)) early vs "
              + "\(meanLaneValue(peakWindow)) at the peak → expected ratio \(expected); "
              + "rendered RMS ratio \(measured); max |bare − contour| \(moved)")
        #expect(abs(measured - expected) < 0.02)     // the audio did what the lane said
        #expect(measured < 0.9)                       // and it is a real swell, not a nudge
        #expect(moved > 0.05)                         // audibly different from no contour
    }

    /// Upward zero crossings of `samples`, linearly interpolated to sub-sample
    /// accuracy, as (time in seconds, instantaneous frequency in Hz) pairs. The
    /// interpolation matters: at 48 kHz one sample is 4.5 % of a 440 Hz period,
    /// which is six times the ±0.7 % deviation a ±12-cent vibrato produces, so
    /// a raw integer crossing index cannot see this feature at all.
    private func instantaneousFrequency(_ samples: [Float],
                                        in window: Range<Int>) -> [(t: Double, hz: Double)] {
        var crossings: [Double] = []
        for frame in window.dropFirst() where samples[frame - 1] < 0 && samples[frame] >= 0 {
            let a = Double(samples[frame - 1]), b = Double(samples[frame])
            crossings.append((Double(frame - 1) + a / (a - b)) / sampleRate)
        }
        guard crossings.count > 1 else { return [] }
        return zip(crossings, crossings.dropFirst()).map {
            (t: $0.0, hz: 1 / ($0.1 - $0.0))
        }
    }

    /// ⭐ THE ONE THAT AN RMS TEST CANNOT ANSWER. ±12 cents is ±3 Hz on a
    /// 440 Hz tone: a Goertzel bin at 440 cannot resolve it, and RMS is blind
    /// to it entirely. So the rendered tone's own instantaneous frequency is
    /// measured, and both the RATE and the DEPTH of the modulation come back as
    /// real numbers. Expression and sharpening are turned off so the only thing
    /// moving is vibrato — the same isolation leg C used for the filter.
    @Test("leg D: vibrato is a MEASURABLE ~5.5 Hz modulation of the rendered tone, delayed")
    func vibratoModulatesTheRenderedFrequency() throws {
        let fixtures = try fixtures()
        let options = BreathContour.Options(depth: 0, sharpenCents: 0)
        let contour = try renderBreath(breathTrack(fixtures, options: options,
                                                   tone: fixtures.sine440MonoLong))
        let samples = contour.channelData[0]

        // Smooth over 5 periods (~11 ms) to cut per-crossing noise; the vibrato
        // period is 182 ms, so this leaves it essentially untouched.
        func smoothed(_ series: [(t: Double, hz: Double)]) -> [(t: Double, hz: Double)] {
            guard series.count > 5 else { return series }
            return (2..<(series.count - 2)).map { i in
                (t: series[i].t,
                 hz: (series[(i - 2)...(i + 2)].map(\.hz).reduce(0, +)) / 5)
            }
        }
        // 2.0-5.0 s: fully bloomed, before the 80 ms relax at 5.5 s.
        let settled = smoothed(instantaneousFrequency(samples, in: 96_000..<240_000))
        // 0.05-0.45 s: the STRAIGHT opening, before the 0.5 s vibrato onset.
        let straight = smoothed(instantaneousFrequency(samples, in: 2_400..<21_600))

        let hi = settled.map(\.hz).max() ?? 0, lo = settled.map(\.hz).min() ?? 0
        let mean = settled.map(\.hz).reduce(0, +) / Double(settled.count)
        // Rate: how often the instantaneous frequency crosses its own mean.
        var meanCrossings = 0
        for (a, b) in zip(settled, settled.dropFirst())
        where (a.hz < mean && b.hz >= mean) || (a.hz > mean && b.hz <= mean) {
            meanCrossings += 1
        }
        let span = (settled.last?.t ?? 0) - (settled.first?.t ?? 0)
        let rateHz = Double(meanCrossings) / 2 / span
        // Half the peak-to-trough excursion, expressed in cents.
        let depthCents = 1_200 * log2(hi / lo) / 2
        let straightSpread = (straight.map(\.hz).max() ?? 0) - (straight.map(\.hz).min() ?? 0)

        print("[measured] leg D vibrato IN THE RENDERED AUDIO: mean \(mean) Hz, "
              + "range \(lo)...\(hi) Hz = ±\(depthCents) cents (asked for ±12), "
              + "rate \(rateHz) Hz (asked for 5.5); straight-opening spread "
              + "\(straightSpread) Hz over 0.05-0.45 s")
        #expect(abs(mean - 440) < 1.5)               // still the same note
        #expect(abs(rateHz - 5.5) < 0.6)             // at the rate that was asked for
        #expect(abs(depthCents - 12) < 3)            // to the depth that was asked for
        // THE DELAYED half: before the onset the tone is straight. ±12 cents
        // is ±3.05 Hz, so a spread under 1 Hz is unambiguously "not vibrato".
        #expect(straightSpread < 1.0)
    }

    /// The other half of what legs A + C bought: with the contour routed to the
    /// filter, the SAME generated shape moves BRIGHTNESS. Driven on CC1 with
    /// `expressionModDepth` left off, so nothing touches amplitude and this is
    /// a filter measurement rather than a loudness one (leg C's isolation).
    @Test("leg D: the same contour on the filter CC sweeps brightness, not loudness")
    func breathContourSweepsBrightness() throws {
        let fixtures = try fixtures()
        // depth 0.9 drives CC1 down to 13 at the dip: cutoff 400 × 50^0.1922 =
        // 848 Hz, where a one-pole passes |H(1 kHz)| = 0.647. At the peak
        // (CC 127) the cutoff is 20 kHz and |H(1 kHz)| = 0.9993.
        let options = BreathContour.Options(depth: 0.9, expressionCC: 1,
                                            vibratoDepthCents: 0, sharpenCents: 0)
        let reference = try renderBreath(breathTrack(fixtures, options: nil,
                                                     tone: fixtures.sine1kMonoLong,
                                                     rootPitch: 60))
        let swept = try renderBreath(breathTrack(fixtures, options: options,
                                                 tone: fixtures.sine1kMonoLong,
                                                 rootPitch: 60,
                                                 filterDepth: 0.9, filterCC: 1))
        let darkWindow = 4_800..<14_400          // 0.10-0.30 s, CC1 sitting at its floor
        let brightWindow = 177_600..<196_800     // 3.70-4.10 s, the top of the swell
        let base = magnitude(reference.channelData[0][darkWindow], hz: 1_000)
        let dark = magnitude(swept.channelData[0][darkWindow], hz: 1_000) / base
        let bright = magnitude(swept.channelData[0][brightWindow], hz: 1_000)
            / magnitude(reference.channelData[0][brightWindow], hz: 1_000)
        // And loudness did NOT move: CC1 with modDepth off is filter-only, so
        // the broadband level away from the filter's reach is unchanged.
        print("[measured] leg D brightness: |H(1 kHz)| at the dip \(dark) "
              + "(one-pole prediction 0.647), at the peak \(bright) (prediction 0.9993)")
        #expect(abs(dark - 0.647) < 0.05)
        #expect(abs(bright - 0.9993) < 0.01)
        #expect(bright > dark * 1.3)
    }
}
