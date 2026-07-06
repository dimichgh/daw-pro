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
        let set = Fixtures(dir: dir, sine440Mono: sine440Mono, sine300Stereo: sine300Stereo,
                           sine1kMono: sine1kMono,
                           missing: dir.appendingPathComponent("does-not-exist.wav"))
        Self.cachedFixtures = set
        return set
    }

    /// 1.0 s Float32 WAV at 44.1 kHz, amp 0.5, identical channels. Scoped so
    /// the AVAudioFile flushes and closes before anyone reads it.
    private static func writeSine(to url: URL, frequency: Double,
                                  channels channelCount: UInt32) throws {
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
        let frames = Int(fileRate)
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
        let a = try OfflineRenderer().render(tracks: [track], tempoBPM: 120,
                                             fromBeat: 0, durationSeconds: 1.5)
        let b = try OfflineRenderer().render(tracks: [track], tempoBPM: 120,
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
}
