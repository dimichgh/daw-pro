import AVFAudio
import AudioToolbox
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m16-b2 gates — instrument delivery for kinds 2/3/4 (design-m16b §4.3,
// conditions C4, C9):
//
//  · C9 built-ins: pitch bend audibly bends PolySynth (frequency factor ==
//    2^(semitones/12), pinned analytically on rendered zero-crossing
//    frequency) and Sampler (playback-rate factor, same pin); CC64 sustain
//    holds a released note and pedal-up releases it; `reset()` neutralizes
//    bend and pedal. The FULL offline path (clip controller lanes → schedule
//    → graph → PolySynth) shows the bend ramp's pitch trajectory.
//  · C4: unknown-kind fall-through on every built-in — channel pressure and
//    a future kind interleaved with notes leave the render BIT-IDENTICAL.
//  · Hosted AU: byte translation pinned via the captured-schedule-block seam
//    — 0xB0/0xE0 length 3, channel pressure 0xD0 LENGTH 2 (the named trap),
//    unknown kinds emit nothing; `reset()` sends CC123, CC120, CC121,
//    bend-center, CC64 0 in order. The b2 rider spot-measures Apple DLS
//    `scheduleMIDIEventBlock` cost under the dense-512 scenario.
//
// 48 kHz throughout; 120 BPM → 1 beat = 24 000 frames.

private let ciRate = 48_000.0

// MARK: - Event shorthand

private func onEvent(_ t: Int64, pitch: UInt8, velocity: UInt8 = 127,
                     id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: t, noteID: id, kind: ScheduledMIDIEvent.noteOn,
                       pitch: pitch, velocity: velocity)
}

private func offEvent(_ t: Int64, pitch: UInt8, id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: t, noteID: id, kind: ScheduledMIDIEvent.noteOff,
                       pitch: pitch, velocity: 0)
}

private func ccEvent(_ t: Int64, controller: UInt8, value: UInt8,
                     id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: t, noteID: id, kind: ScheduledMIDIEvent.controlChange,
                       pitch: controller, velocity: value)
}

private func bendEvent(_ t: Int64, value: Int, id: UInt64) -> ScheduledMIDIEvent {
    ScheduledMIDIEvent(sampleTime: t, noteID: id, kind: ScheduledMIDIEvent.pitchBend,
                       pitch: UInt8(value & 0x7F), velocity: UInt8((value >> 7) & 0x7F))
}

private let semitone = exp2(1.0 / 12.0)   // 2^(1/12): bend 12288 = exactly +1 st

@MainActor
@Suite("MIDI controller instrument delivery (m16-b2)", .serialized)
struct MIDIControllerInstrumentTests {

    // MARK: - Direct render harness (the PolySynthTests renderDirect idiom)

    /// Renders any `InstrumentRendering` in 512-frame quanta, replicating
    /// `InstrumentRenderer`'s slicing. Events are pre-sorted with THE
    /// canonical order. Returns channel 0.
    private func renderDirect(_ instrument: any InstrumentRendering,
                              events unsorted: [ScheduledMIDIEvent],
                              frames totalFrames: Int) throws -> [Float] {
        let events = unsorted.sorted(by: MIDIEventSchedule.orderedBefore)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: ciRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let channels = try #require(buffer.floatChannelData)

        var out: [Float] = []
        out.reserveCapacity(totalFrames)
        var cursor = 0
        var rendered = 0
        while rendered < totalFrames {
            let frames = min(512, totalFrames - rendered)
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

    private func sinePolySynth() -> PolySynthInstrument {
        let synth = PolySynthInstrument(params: PolySynthParams(
            waveform: .sine, attack: 0.005, decay: 0.05, sustain: 1.0, release: 0.05,
            cutoffHz: 18_000, resonance: 0, gain: 1.0))
        synth.prepare(sampleRate: ciRate, maxFramesPerQuantum: 512, channelCount: 2)
        return synth
    }

    private func samplerOn1k() throws -> SamplerInstrument {
        let fixtures = try TestSignals.fixtures()
        let sampler = SamplerInstrument(params: SamplerParams(
            zones: [SamplerZone(audioFileURL: fixtures.cos1k48,
                                rootPitch: 60, minPitch: 0, maxPitch: 127, gain: 1)],
            oneShot: false, attack: 0.001, release: 0.05, gain: 1.0), sampleRate: ciRate)
        sampler.prepare(sampleRate: ciRate, maxFramesPerQuantum: 512, channelCount: 2)
        return sampler
    }

    // MARK: - C9: PolySynth pitch bend

    @Test("C9 PolySynth bend: +1 st (12288) mid-note shifts a held A4 by exactly 2^(1/12)")
    func polySynthBendFactor() throws {
        let out = try renderDirect(sinePolySynth(), events: [
            onEvent(0, pitch: 69, id: 0),                 // A4 = 440 Hz, held
            bendEvent(24_000, value: 12_288, id: 1),      // center + 4096 = +1 st
        ], frames: 48_000)

        let before = TestSignals.dominantFrequency(
            byZeroCrossings: out, sampleRate: ciRate, in: 4_800..<22_000)
        let after = TestSignals.dominantFrequency(
            byZeroCrossings: out, sampleRate: ciRate, in: 26_000..<46_000)
        let ratio = after / before
        print("[measured] PolySynth bend: \(before) Hz → \(after) Hz, "
              + "ratio \(ratio) (expected 2^(1/12) = \(semitone))")
        #expect(abs(before - 440.0) < 2.0)
        #expect(abs(ratio - semitone) / semitone < 0.005)   // factor == 2^(1/12) ± 0.5%
    }

    @Test("C9 PolySynth full path: a clip's bend-ramp lane renders an audible pitch trajectory offline")
    func polySynthBendRampOfflineFullPath() throws {
        // Full-range ramp beats [1, 2] (dense stepwise points — exactly what
        // capture produces), through OfflineRenderer → PlaybackGraph →
        // schedule → the real instrument. The doc's C9 contract: a held note
        // with a full-range ramp shows a MEASURABLE pitch trajectory.
        var ramp: [MIDIControllerPoint] = []
        for step in 0...8 {
            ramp.append(MIDIControllerPoint(beat: 1.0 + Double(step) * 0.125,
                                            value: 8_192 + step * 1_024))  // → 16383 (clamped)
        }
        let track = Track(name: "Keys", kind: .instrument, clips: [
            Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
                MIDINote(pitch: 69, velocity: 127, startBeat: 0, lengthBeats: 4),
            ], controllerLanes: [
                MIDIControllerLane(type: .pitchBend, points: ramp),
            ]),
        ], instrument: InstrumentDescriptor(
            kind: .polySynth,
            polySynth: PolySynthParams(waveform: .sine, attack: 0.005, decay: 0.05,
                                       sustain: 1.0, release: 0.1, cutoffHz: 18_000,
                                       resonance: 0, gain: 1.0)))
        let audio = try OfflineRenderer().render(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 0, durationSeconds: 2.0)
        let left = audio.channelData[0]

        let start = TestSignals.dominantFrequency(
            byZeroCrossings: left, sampleRate: ciRate, in: 6_000..<22_000)      // pre-ramp
        let mid = TestSignals.dominantFrequency(
            byZeroCrossings: left, sampleRate: ciRate, in: 34_000..<38_000)     // mid-ramp
        let end = TestSignals.dominantFrequency(
            byZeroCrossings: left, sampleRate: ciRate, in: 62_400..<91_200)     // post-ramp hold
        let expectedEnd = 440.0 * exp2((Double(16_383 - 8_192) / 8_192.0) * 2.0 / 12.0)
        print("[measured] offline bend ramp trajectory: \(start) Hz → \(mid) Hz → \(end) Hz "
              + "(expected end \(expectedEnd))")
        #expect(abs(start - 440.0) < 3.0)               // unbent before the ramp
        #expect(mid > start + 5.0)                      // rising THROUGH the ramp
        #expect(mid < end - 5.0)
        #expect(abs(end - expectedEnd) / expectedEnd < 0.01)  // full-range bend lands ±1%
    }

    // MARK: - C9: PolySynth sustain + reset

    @Test("C9 PolySynth sustain: CC64 holds a released note; pedal-up releases it; no-pedal control decays")
    func polySynthSustainHoldsAndReleases() throws {
        // Control: no pedal — off at 12 000, release 0.05 s → exact zeros
        // well before 16 000.
        let control = try renderDirect(sinePolySynth(), events: [
            onEvent(0, pitch: 69, id: 0),
            offEvent(12_000, pitch: 69, id: 0),
        ], frames: 48_000)
        let controlTail = TestSignals.peak(control, in: 16_000..<48_000)

        // Pedal down before the note, off at 12 000 (deferred), pedal up at
        // 24 000 → release runs from THERE.
        let pedaled = try renderDirect(sinePolySynth(), events: [
            ccEvent(0, controller: 64, value: 127, id: 10),
            onEvent(0, pitch: 69, id: 0),
            offEvent(12_000, pitch: 69, id: 0),
            ccEvent(24_000, controller: 64, value: 0, id: 11),
        ], frames: 48_000)
        let held = TestSignals.peak(pedaled, in: 16_000..<24_000)
        let released = TestSignals.peak(pedaled, in: 28_800..<48_000)
        print("[measured] PolySynth sustain: control tail \(controlTail), "
              + "pedal-held [16000,24000) \(held), post-pedal-up [28800,...) \(released)")
        #expect(controlTail == 0)      // without the pedal the voice freed
        #expect(held > 0.1)            // THE keyboardist controller: the note held
        #expect(released == 0)         // pedal-up delivered the deferred release
    }

    @Test("C9 PolySynth reset(): bend re-centers and the pedal lifts (no stale controller state)")
    func polySynthResetNeutralizes() throws {
        let synth = sinePolySynth()
        // Roll 1: bend to max, pedal down, note released under the pedal —
        // maximally stale state.
        let first = try renderDirect(synth, events: [
            bendEvent(0, value: 16_383, id: 20),
            ccEvent(0, controller: 64, value: 127, id: 21),
            onEvent(0, pitch: 69, id: 0),
            offEvent(6_000, pitch: 69, id: 0),
        ], frames: 12_000)
        #expect(TestSignals.peak(first, in: 8_000..<12_000) > 0.1)  // pedal held it

        synth.reset()   // the flush-family contract

        // Roll 2 on the SAME instrument: unbent pitch, off honored.
        let second = try renderDirect(synth, events: [
            onEvent(0, pitch: 69, id: 1),
            offEvent(12_000, pitch: 69, id: 1),
        ], frames: 48_000)
        let frequency = TestSignals.dominantFrequency(
            byZeroCrossings: second, sampleRate: ciRate, in: 4_800..<11_000)
        let tail = TestSignals.peak(second, in: 16_000..<48_000)
        print("[measured] PolySynth post-reset: \(frequency) Hz (expect 440), tail peak \(tail)")
        #expect(abs(frequency - 440.0) < 2.0)   // bend cleared to center
        #expect(tail == 0)                      // pedal cleared: the off released
    }

    // MARK: - C9: Sampler bend + sustain

    @Test("C9 Sampler bend: +1 st (12288) shifts the 1 kHz zone by exactly 2^(1/12) (playback rate)")
    func samplerBendFactor() throws {
        let out = try renderDirect(try samplerOn1k(), events: [
            onEvent(0, pitch: 60, id: 0),                 // root → 1 kHz unshifted
            bendEvent(24_000, value: 12_288, id: 1),
        ], frames: 48_000)
        let before = TestSignals.dominantFrequency(
            byZeroCrossings: out, sampleRate: ciRate, in: 4_800..<22_000)
        let after = TestSignals.dominantFrequency(
            byZeroCrossings: out, sampleRate: ciRate, in: 26_000..<46_000)
        let ratio = after / before
        print("[measured] Sampler bend: \(before) Hz → \(after) Hz, "
              + "ratio \(ratio) (expected \(semitone))")
        #expect(abs(before - 1_000.0) < 5.0)
        #expect(abs(ratio - semitone) / semitone < 0.005)
    }

    @Test("C9 Sampler sustain: CC64 holds a released voice; pedal-up releases to exact zeros")
    func samplerSustainHoldsAndReleases() throws {
        let control = try renderDirect(try samplerOn1k(), events: [
            onEvent(0, pitch: 60, id: 0),
            offEvent(12_000, pitch: 60, id: 0),
        ], frames: 48_000)
        let pedaled = try renderDirect(try samplerOn1k(), events: [
            ccEvent(0, controller: 64, value: 127, id: 10),
            onEvent(0, pitch: 60, id: 0),
            offEvent(12_000, pitch: 60, id: 0),
            ccEvent(24_000, controller: 64, value: 0, id: 11),
        ], frames: 48_000)
        let controlTail = TestSignals.peak(control, in: 16_000..<48_000)
        let held = TestSignals.peak(pedaled, in: 16_000..<24_000)
        let released = TestSignals.peak(pedaled, in: 28_800..<48_000)
        print("[measured] Sampler sustain: control tail \(controlTail), held \(held), "
              + "post-pedal-up \(released)")
        #expect(controlTail == 0)
        #expect(held > 0.1)
        #expect(released == 0)
    }

    // MARK: - C4: unknown-kind fall-through on every built-in

    @Test("C4: channel pressure + an unknown kind interleaved with notes leave every built-in bit-identical")
    func unknownKindsAreInertOnBuiltIns() throws {
        let noteOnly = [onEvent(0, pitch: 60, id: 0), offEvent(12_000, pitch: 60, id: 0)]
        let interleaved = noteOnly + [
            ScheduledMIDIEvent(sampleTime: 6_000, noteID: 5,
                               kind: ScheduledMIDIEvent.channelPressure, pitch: 100, velocity: 0),
            ScheduledMIDIEvent(sampleTime: 6_000, noteID: 6, kind: 9, pitch: 1, velocity: 1),
        ]
        // PolySynth
        let synthA = try renderDirect(sinePolySynth(), events: noteOnly, frames: 24_000)
        let synthB = try renderDirect(sinePolySynth(), events: interleaved, frames: 24_000)
        #expect(synthA == synthB)
        #expect(TestSignals.peak(synthA, in: 0..<12_000) > 0.1)  // over real signal
        // Sampler
        let samplerA = try renderDirect(try samplerOn1k(), events: noteOnly, frames: 24_000)
        let samplerB = try renderDirect(try samplerOn1k(), events: interleaved, frames: 24_000)
        #expect(samplerA == samplerB)
        #expect(TestSignals.peak(samplerA, in: 0..<12_000) > 0.1)
        // TestTone
        let toneA = try renderDirect(TestToneInstrument(), events: noteOnly, frames: 24_000)
        let toneB = try renderDirect(TestToneInstrument(), events: interleaved, frames: 24_000)
        #expect(toneA == toneB)
        #expect(TestSignals.peak(toneA, in: 0..<12_000) > 0.1)
        print("[measured] C4 fall-through nulls: polySynth/sampler/testTone all bit-identical")
    }

    // MARK: - Hosted AU: byte translation + reset sequence (the captured-block seam)

    /// Byte log for the `scheduleMIDIOverride` seam. Same-thread use only
    /// (render is invoked directly by the test).
    private final class MIDILogBox: @unchecked Sendable {
        var entries: [(time: Int64, bytes: [UInt8])] = []
    }

    /// A real, allocated Apple DLS AUAudioUnit (in-process v2, the m10-n
    /// precedent) wrapped with the byte-capturing seam.
    private func makeSeamedDLS(box: MIDILogBox) throws -> HostedAUInstrument {
        func fourCC(_ code: String) -> OSType {
            code.utf8.reduce(0) { ($0 << 8) | OSType($1) }
        }
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: fourCC("dls "),
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        let au = try AUAudioUnit(componentDescription: description)
        au.maximumFramesToRender = 512
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: ciRate,
                                                channels: 2))
        try au.outputBusses[0].setFormat(format)
        try au.allocateRenderResources()
        return try HostedAUInstrument(au: au, sampleRate: ciRate,
                                      scheduleMIDIOverride: { time, _, length, bytes in
            box.entries.append((time, Array(UnsafeBufferPointer(start: bytes, count: length))))
        })
    }

    @Test("hosted AU translation: CC/bend 3 bytes, channel pressure 2 BYTES, unknown kinds dropped")
    func hostedAUByteTranslation() throws {
        let box = MIDILogBox()
        let instrument = try makeSeamedDLS(box: box)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: ciRate,
                                                channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        let events: [ScheduledMIDIEvent] = [
            onEvent(0, pitch: 60, velocity: 100, id: 0),
            ccEvent(10, controller: 11, value: 42, id: 1),
            bendEvent(20, value: 16_383, id: 2),
            ScheduledMIDIEvent(sampleTime: 30, noteID: 3,
                               kind: ScheduledMIDIEvent.channelPressure, pitch: 77, velocity: 0),
            ScheduledMIDIEvent(sampleTime: 40, noteID: 4, kind: 9, pitch: 1, velocity: 1),
            offEvent(50, pitch: 60, id: 0),
        ]
        events.withUnsafeBufferPointer {
            instrument.render(events: $0, renderStart: 0, frameCount: 512, output: output)
        }
        print("[measured] hosted-AU bytes: "
              + box.entries.map { "\($0.bytes.map { String(format: "%02X", $0) }.joined(separator: " "))" }
                          .joined(separator: " | "))
        #expect(box.entries.count == 5)   // the unknown kind emitted NOTHING
        #expect(box.entries[0].bytes == [0x90, 60, 100])
        #expect(box.entries[1].bytes == [0xB0, 11, 42])
        #expect(box.entries[2].bytes == [0xE0, 127, 127])
        #expect(box.entries[3].bytes == [0xD0, 77])       // LENGTH 2 — the named trap
        #expect(box.entries[3].bytes.count == 2)
        #expect(box.entries[4].bytes == [0x80, 60, 0])
        // In-quantum offsets survive the translation (FIFO at the AU).
        let offsets = box.entries.map { $0.time &- AUEventSampleTimeImmediate }
        #expect(offsets == [0, 10, 20, 30, 50])
    }

    @Test("hosted AU reset(): CC123, CC120, CC121, bend-center, CC64 0 — in order, immediate")
    func hostedAUResetSequence() throws {
        let box = MIDILogBox()
        let instrument = try makeSeamedDLS(box: box)
        instrument.reset()
        #expect(box.entries.map(\.bytes) == [
            [0xB0, 123, 0],     // all notes off
            [0xB0, 120, 0],     // all sound off
            [0xB0, 121, 0],     // reset all controllers
            [0xE0, 0x00, 0x40], // pitch bend → center 8192
            [0xB0, 64, 0],      // sustain pedal up
        ])
        #expect(box.entries.allSatisfy { $0.time == AUEventSampleTimeImmediate })
    }

    // MARK: - The b2 rider: hosted-AU scheduleMIDIEventBlock cost, measured

    @Test("rider: Apple DLS scheduleMIDIEventBlock per-event cost under the dense-512 scenario")
    func hostedAUScheduleCostRider() async throws {
        let registry = AUHostRegistry()
        let track = Track(name: "AU", kind: .instrument, clips: [],
                          instrument: InstrumentDescriptor(
                              kind: .audioUnit,
                              audioUnit: AudioUnitConfig(component: AudioUnitComponentID(
                                  subType: "dls ", manufacturer: "appl"))))
        await registry.prepare(track: track, sampleRate: ciRate)
        let instrument = try #require(registry.preparedInstrument(forTrack: track.id))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: ciRate,
                                                channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        var pull = 0
        func renderQuantum(_ events: [ScheduledMIDIEvent]) -> Duration {
            let renderStart = Int64(pull * 512)
            pull += 1
            let clock = ContinuousClock()
            return clock.measure {
                events.withUnsafeBufferPointer {
                    instrument.render(events: $0, renderStart: renderStart,
                                      frameCount: 512, output: output)
                }
            }
        }
        func denseBlock(at renderStart: Int64) -> [ScheduledMIDIEvent] {
            (0..<512).map { index in
                ccEvent(renderStart + Int64(index), controller: 11,
                        value: UInt8(index % 128), id: UInt64(index))
            }
        }

        for _ in 0..<8 { _ = renderQuantum([]) }   // warm-up (the probe law)
        var emptyBest = Duration.seconds(1)
        var denseBest = Duration.seconds(1)
        for _ in 0..<5 {
            emptyBest = min(emptyBest, renderQuantum([]))
            denseBest = min(denseBest, renderQuantum(denseBlock(at: Int64(pull * 512))))
        }
        let emptyNs = Double(emptyBest.components.attoseconds) / 1e9
            + Double(emptyBest.components.seconds) * 1e9
        let denseNs = Double(denseBest.components.attoseconds) / 1e9
            + Double(denseBest.components.seconds) * 1e9
        let perEventMicroseconds = max(0, denseNs - emptyNs) / 512.0 / 1_000.0
        print("[measured] DLS dense-512 quantum: empty \(emptyNs / 1e6) ms, "
              + "dense \(denseNs / 1e6) ms → scheduleMIDIEventBlock ≈ "
              + "\(perEventMicroseconds) µs/event")
        // Sanity envelope only — the number itself is the rider deliverable.
        #expect(perEventMicroseconds < 100)
    }
}
