import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M3 (iv): the built-in subtractive poly synth. Two layers of coverage:
///
///  · DIRECT renders drive `PolySynthInstrument.render()` in 512-frame quanta
///    with hand-built event arrays (mimicking `InstrumentRenderer`'s slicing),
///    so envelope frames, harmonic ratios, and voice-stealing behavior are
///    measured sample-exactly with no graph in between.
///  · OFFLINE renders go through `OfflineRenderer` with NO factory override,
///    pinning the descriptor → instrument wiring (`.testTone` vs nil/.default
///    vs `.polySynth` params) through the real graph.
///
/// 48 kHz throughout; 120 BPM → 1 beat = 24 000 frames for the offline cases.
@MainActor
@Suite("PolySynth instrument", .serialized)
struct PolySynthTests {
    private let sampleRate = 48_000.0

    // MARK: - Harness

    private func makeSynth(_ params: PolySynthParams) -> PolySynthInstrument {
        let synth = PolySynthInstrument(params: params)
        synth.prepare(sampleRate: sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return synth
    }

    /// noteOn/noteOff pair sharing one noteID (offs may land beyond the
    /// rendered range — they then simply never deliver, i.e. a held note).
    private func note(on: Int64, off: Int64, pitch: UInt8,
                      velocity: UInt8 = 127, id: UInt64) -> [ScheduledMIDIEvent] {
        [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                            kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: velocity),
         ScheduledMIDIEvent(sampleTime: off, noteID: id,
                            kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
    }

    /// Renders the instrument directly in `quantum`-frame slices, replicating
    /// InstrumentRenderer's slicing (sorted events, sampleTime < window end,
    /// offsets clamp inside the instrument). Optionally publishes
    /// `paramsToApply` once, at the quantum boundary ≥ `applyAtFrame`.
    /// Returns channel 0.
    private func renderDirect(
        _ instrument: PolySynthInstrument,
        events unsorted: [ScheduledMIDIEvent],
        frames totalFrames: Int,
        quantum: Int = 512,
        applyAtFrame: Int? = nil,
        paramsToApply: PolySynthParams? = nil
    ) throws -> [Float] {
        // Same sort as MIDIEventSchedule.buildEvents (off before on on ties).
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

        var out: [Float] = []
        out.reserveCapacity(totalFrames)
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
            out.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            rendered += frames
        }
        return out
    }

    /// Goertzel magnitude at exactly `hz` over `samples` (choose windows with
    /// a whole number of cycles for leakage-free bins). Absolute scale is
    /// arbitrary; only ratios are asserted.
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

    // MARK: - ADSR timing (direct)

    // 100 ms attack @ 48 kHz = 4800 frames; sine voice so windowed peaks read
    // the envelope directly (LPF wide open, resonance 0, gain 1).
    @Test("linear attack: level at frame ~2400 sits strictly between 0 and the frame-4800 level")
    func attackTiming() throws {
        let synth = makeSynth(PolySynthParams(
            waveform: .sine, attack: 0.1, decay: 0.5, sustain: 1.0, release: 0.1,
            cutoffHz: 18_000, resonance: 0, gain: 1.0))
        let out = try renderDirect(synth, events: note(on: 0, off: 40_000, pitch: 69, id: 0),
                                   frames: 24_000)

        let early = TestSignals.peak(out, in: 0..<200)
        let mid = TestSignals.peak(out, in: 2_200..<2_600)     // ≈ frame 2400
        let full = TestSignals.peak(out, in: 4_800..<5_600)    // attack complete
        print("[measured] attack peaks — early(0..200): \(early), mid@~2400: \(mid), full@4800+: \(full)")
        #expect(early < 0.05 * full)     // ramp starts from (near) zero
        #expect(mid > 0)
        #expect(mid < full)
        #expect(abs(Double(mid / full) - 0.5) < 0.15)  // linear ramp midpoint ≈ half
    }

    @Test("noteOff enters release: tail decays and reaches exact silence within release + tolerance")
    func releaseReachesSilence() throws {
        let synth = makeSynth(PolySynthParams(
            waveform: .sine, attack: 0.005, decay: 0.05, sustain: 1.0, release: 0.1,
            cutoffHz: 18_000, resonance: 0, gain: 1.0))
        // off at frame 24 000; release 0.1 s = 4800 frames → zero from ≈ 28 800.
        let out = try renderDirect(synth, events: note(on: 0, off: 24_000, pitch: 69, id: 0),
                                   frames: 48_000)

        let tailStart = TestSignals.peak(out, in: 24_100..<24_600)
        let tailLate = TestSignals.peak(out, in: 27_500..<28_000)
        print("[measured] release — tailStart: \(tailStart), tailLate: \(tailLate), "
              + "silence-window peak from 29 500 (zero expected ≈ 28 800): "
              + "\(TestSignals.peak(out, in: 29_500..<48_000))")
        #expect(tailStart > 0.1)               // NOT a hard stop — audible tail
        #expect(tailLate > 0)                  // still decaying inside the release
        #expect(tailLate < tailStart)          // monotonic-ish decay
        #expect(TestSignals.peak(out, in: 29_500..<48_000) == 0)  // exact zeros: voice freed
    }

    @Test("sustain stage holds at the sustain fraction of full level")
    func sustainRatio() throws {
        func steadyPeak(sustain: Double) throws -> Float {
            let synth = makeSynth(PolySynthParams(
                waveform: .sine, attack: 0.005, decay: 0.05, sustain: sustain, release: 0.1,
                cutoffHz: 18_000, resonance: 0, gain: 1.0))
            let out = try renderDirect(synth, events: note(on: 0, off: 40_000, pitch: 69, id: 0),
                                       frames: 24_000)
            return TestSignals.peak(out, in: 12_000..<24_000)  // deep in sustain
        }
        let full = try steadyPeak(sustain: 1.0)
        let half = try steadyPeak(sustain: 0.5)
        print("[measured] sustain peaks — s=1.0: \(full), s=0.5: \(half), ratio: \(half / full)")
        #expect(abs(Double(half / full) - 0.5) < 0.05)
    }

    // MARK: - Polyphony (direct)

    @Test("3-note chord RMS clearly exceeds a single note")
    func chordRMS() throws {
        func rms(_ pitches: [UInt8]) throws -> Float {
            let synth = makeSynth(PolySynthParams(
                waveform: .saw, attack: 0.005, decay: 0.05, sustain: 0.8, release: 0.1,
                cutoffHz: 18_000, resonance: 0, gain: 0.8))
            var events: [ScheduledMIDIEvent] = []
            for (index, pitch) in pitches.enumerated() {
                events += note(on: 0, off: 40_000, pitch: pitch, id: UInt64(index))
            }
            let out = try renderDirect(synth, events: events, frames: 24_000)
            return TestSignals.rms(out, in: 4_800..<24_000)
        }
        let single = try rms([60])
        let chord = try rms([60, 64, 67])
        print("[measured] RMS — single: \(single), chord: \(chord), ratio: \(chord / single)")
        #expect(chord > 1.5 * single)
    }

    @Test("17 simultaneous notes: the OLDEST voice is stolen, ≤16 sound, no crash")
    func voiceStealing() throws {
        let synth = makeSynth(PolySynthParams(
            waveform: .sine, attack: 0.005, decay: 0.05, sustain: 1.0, release: 0.05,
            cutoffHz: 18_000, resonance: 0, gain: 1.0))
        // 17 noteOns at frame 0 (ids 0...16). At frame 12 000, offs for ids
        // 0...15. Steal-oldest ⇒ id 16 stole id 0's voice, so id 0's off
        // no-ops and ONLY id 16 keeps sounding; a drop-the-new policy would
        // leave silence instead. id 16 is released at frame 36 000.
        var events: [ScheduledMIDIEvent] = []
        for id in 0..<16 {
            events += note(on: 0, off: 12_000, pitch: UInt8(48 + id), id: UInt64(id))
        }
        events += note(on: 0, off: 36_000, pitch: 64, id: 16)
        let out = try renderDirect(synth, events: events, frames: 48_000)

        let allNotes = TestSignals.peak(out, in: 2_000..<12_000)
        let survivor = TestSignals.peak(out, in: 16_000..<20_000)   // past 0.05 s release + slack
        let end = TestSignals.peak(out, in: 40_000..<48_000)        // past id 16's release
        print("[measured] stealing peaks — 16 voices: \(allNotes), survivor: \(survivor), end: \(end)")
        #expect(allNotes > 0.5)          // a real 16-voice pile-up sounded
        #expect(allNotes < 4.5)          // …but bounded: never more than 16 voices
        #expect(survivor > 0.1)          // the NEWEST note survived ⇒ oldest was stolen
        #expect(end == 0)                // and everything frees cleanly
    }

    // MARK: - Waveform identity (direct, Goertzel bins)

    @Test("harmonic identity: saw has H2, square suppresses H2 but keeps H3, sine has neither")
    func waveformHarmonics() throws {
        func harmonics(_ waveform: PolySynthParams.Waveform) throws -> (h1: Double, h2: Double, h3: Double) {
            let synth = makeSynth(PolySynthParams(
                waveform: waveform, attack: 0.005, decay: 0.05, sustain: 1.0, release: 0.1,
                cutoffHz: 18_000, resonance: 0, gain: 1.0))
            let out = try renderDirect(synth, events: note(on: 0, off: 40_000, pitch: 69, id: 0),
                                       frames: 14_400)
            // 440 Hz × 0.2 s = 88 whole cycles → leakage-free bins at 440/880/1320.
            let window = out[4_800..<14_400]
            return (magnitude(window, hz: 440), magnitude(window, hz: 880),
                    magnitude(window, hz: 1_320))
        }
        let saw = try harmonics(.saw)
        let square = try harmonics(.square)
        let sine = try harmonics(.sine)
        print("[measured] saw H1 \(saw.h1) H2 \(saw.h2) H3 \(saw.h3); "
              + "square H1 \(square.h1) H2 \(square.h2) H3 \(square.h3); "
              + "sine H1 \(sine.h1) H2 \(sine.h2) H3 \(sine.h3)")
        #expect(saw.h2 > 0.3 * saw.h1)         // saw: even harmonics present (ideal ½)
        #expect(square.h2 < 0.02 * square.h1)  // square: even harmonics suppressed
        #expect(square.h3 > 0.2 * square.h1)   // …odd harmonics present (ideal ⅓)
        #expect(saw.h2 > 10 * square.h2)       // the H2 gap is decisive, not marginal
        #expect(sine.h2 < 0.01 * sine.h1)      // sine: pure
        #expect(sine.h3 < 0.01 * sine.h1)
    }

    // MARK: - RT-safe parameter updates (direct)

    @Test("apply(params:) mid-render: held note keeps sounding, pre-switch bit-identical, post-switch differs")
    func paramUpdateInPlace() throws {
        let initial = PolySynthParams(
            waveform: .saw, attack: 0.005, decay: 0.05, sustain: 0.8, release: 0.1,
            cutoffHz: 18_000, resonance: 0, gain: 0.8)
        let switched = PolySynthParams(
            waveform: .square, attack: 0.005, decay: 0.05, sustain: 0.8, release: 0.1,
            cutoffHz: 600, resonance: 0.3, gain: 0.8)
        let events = note(on: 0, off: 90_000, pitch: 57, id: 0)  // A3, held throughout
        let switchFrame = 24_064  // 47 × 512-frame quanta

        let unswitched = try renderDirect(makeSynth(initial), events: events, frames: 48_000)
        let out = try renderDirect(makeSynth(initial), events: events, frames: 48_000,
                                   applyAtFrame: switchFrame, paramsToApply: switched)

        // Before the publish lands, the two renders are bit-identical.
        #expect(Array(out[0..<switchFrame]) == Array(unswitched[0..<switchFrame]))
        // The held note never gaps: every 256-frame window across the switch
        // boundary carries signal (220 Hz period ≈ 218 frames < window).
        var minWindowPeak: Float = .greatestFiniteMagnitude
        var window = 23_552
        while window < 25_600 {
            minWindowPeak = min(minWindowPeak, TestSignals.peak(out, in: window..<(window + 256)))
            window += 256
        }
        var difference: Float = 0
        for frame in switchFrame..<26_000 {
            difference = max(difference, abs(out[frame] - unswitched[frame]))
        }
        print("[measured] param switch — min 256-frame window peak: \(minWindowPeak), "
              + "post-switch max divergence: \(difference)")
        #expect(minWindowPeak > 0.01)   // no gap of zeros at the boundary
        #expect(difference > 0.05)      // waveform + cutoff change is audible
    }

    // MARK: - Descriptor wiring (OfflineRenderer, default factory)

    private func midiClip(pitch: Int = 69) -> Clip {
        Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: pitch, velocity: 127, startBeat: 0, lengthBeats: 2),
        ])
    }

    @Test(".testTone descriptor null-tests against an injected TestToneInstrument")
    func testToneDescriptorWiring() throws {
        let viaDescriptor = try OfflineRenderer().render(
            tracks: [Track(name: "Keys", kind: .instrument, clips: [midiClip()],
                           instrument: InstrumentDescriptor(kind: .testTone))],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.5
        )
        let injected = OfflineRenderer()
        injected.instrumentFactory = { _ in TestToneInstrument() }
        let viaInjection = try injected.render(
            tracks: [Track(name: "Keys", kind: .instrument, clips: [midiClip()])],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.5
        )
        let difference = maxDifference(viaDescriptor, viaInjection)
        let peak = TestSignals.peak(viaDescriptor.channelData[0],
                                    in: 0..<viaDescriptor.frameCount)
        print("[measured] .testTone descriptor null: \(difference), peak: \(peak)")
        #expect(difference == 0.0)
        #expect(peak > 0.2)  // the null means something: real signal on both sides
    }

    @Test("nil descriptor renders the poly synth (≡ .default, ≢ testTone)")
    func nilDescriptorIsPolySynth() throws {
        func render(_ descriptor: InstrumentDescriptor?) throws -> RenderedAudio {
            try OfflineRenderer().render(
                tracks: [Track(name: "Keys", kind: .instrument, clips: [midiClip()],
                               instrument: descriptor)],
                tempoBPM: 120, fromBeat: 0, durationSeconds: 1.5
            )
        }
        let nilRender = try render(nil)
        let defaultRender = try render(.default)
        let toneRender = try render(InstrumentDescriptor(kind: .testTone))

        let nilVsDefault = maxDifference(nilRender, defaultRender)
        let peak = TestSignals.peak(nilRender.channelData[0], in: 0..<nilRender.frameCount)
        print("[measured] nil≡default null: \(nilVsDefault), polySynth peak: \(peak)")
        #expect(nilVsDefault == 0.0)                            // nil ⇒ .default
        #expect(peak > 0.05)                                    // audibly the synth…
        #expect(maxDifference(nilRender, toneRender) > 0.05)    // …and NOT the test tone
        #expect(nilRender.channelData[0] == nilRender.channelData[1])  // stereo-identical
    }

    @Test("descriptor params reach the synth: a 100 Hz cutoff crushes a 440 Hz saw")
    func cutoffResponseThroughDescriptor() throws {
        func rms(cutoffHz: Double) throws -> Float {
            let audio = try OfflineRenderer().render(
                tracks: [Track(name: "Keys", kind: .instrument, clips: [midiClip()],
                               instrument: InstrumentDescriptor(
                                   kind: .polySynth,
                                   polySynth: PolySynthParams(
                                       waveform: .saw, attack: 0.005, decay: 0.05,
                                       sustain: 1.0, release: 0.1, cutoffHz: cutoffHz,
                                       resonance: 0, gain: 0.8)))],
                tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
            )
            return TestSignals.rms(audio.channelData[0], in: 12_000..<48_000)
        }
        let open = try rms(cutoffHz: 18_000)
        let closed = try rms(cutoffHz: 100)
        print("[measured] cutoff response — open(18k): \(open), closed(100): \(closed), "
              + "ratio: \(closed / open)")
        #expect(open > 0.05)             // wide open really sounds
        #expect(closed < 0.3 * open)     // 2-pole LPF two octaves down bites hard
    }

    @Test("offline poly-synth renders are bit-identical run to run")
    func determinism() throws {
        let track = Track(name: "Keys", kind: .instrument, clips: [
            Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2),
                MIDINote(pitch: 64, velocity: 90, startBeat: 0.5, lengthBeats: 1.5),
                MIDINote(pitch: 67, velocity: 110, startBeat: 1, lengthBeats: 1),
            ]),
        ])
        let a = try OfflineRenderer().render(tracks: [track], tempoBPM: 120,
                                             fromBeat: 0, durationSeconds: 2.0)
        let b = try OfflineRenderer().render(tracks: [track], tempoBPM: 120,
                                             fromBeat: 0, durationSeconds: 2.0)
        let difference = maxDifference(a, b)
        print("[measured] determinism null: \(difference)")
        #expect(difference == 0.0)
        #expect(TestSignals.peak(a.channelData[0], in: 0..<a.frameCount) > 0.05)
    }

    // MARK: - Graph signature semantics

    @Test("instrument KIND change flips the reconcile signature; param-only change does not")
    func kindChangeSignature() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        let graph = PlaybackGraph(engine: engine)

        var track = Track(name: "Keys", kind: .instrument, clips: [midiClip()],
                          instrument: InstrumentDescriptor(kind: .polySynth))
        #expect(graph.reconcile(tracks: [track]) == true)   // first build

        // Param-only change: same kind → NOT schedule-affecting; it lands via
        // applyParameters → apply(params:) with no rebuild.
        track.instrument = InstrumentDescriptor(
            kind: .polySynth, polySynth: PolySynthParams(cutoffHz: 500))
        #expect(graph.reconcile(tracks: [track]) == false)
        graph.applyParameters(tracks: [track])

        // Kind change → rebuild that track's node + reschedule.
        track.instrument = InstrumentDescriptor(kind: .testTone)
        #expect(graph.reconcile(tracks: [track]) == true)
        #expect(graph.trackIDs == [track.id])
    }
}
