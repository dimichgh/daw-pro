import AVFAudio
import CAtomics
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m16-b3 gates — live thru + ring-overflow honesty for controller kinds
/// (design-m16b §8.2/§8.3, conditions C11 + C15):
///
///  · C11: a live CC/bend/pressure reaches the sounding instrument within
///    ≤ 1 quantum — offset 0 of the quantum it drains in, schedule published
///    or not (the M3-vii law extended); kind ≥ 2 BYPASSES the pitch-pairing
///    map, so an interleaved controller whose data1 equals an open note's
///    pitch can never corrupt that note's on/off pairing.
///  · C15: a thru-ring overflow (`droppedFlag`) answers with
///    `instrument.reset()`, which NEUTRALIZES pedal and bend on the built-ins
///    (b2's reset work) — a dropped pedal-up can no more stick than a dropped
///    note-off. Pinned end-to-end on a real PolySynth through the renderer:
///    held-by-pedal + bent state before the overflow; silent, centered,
///    pedal-up after.
@MainActor
@Suite("Live controller thru + overflow honesty (m16-b3)", .serialized)
struct LiveControllerThruTests {
    private let rate = 48_000.0

    /// The LiveThruRenderTests harness shape, generalized over the instrument.
    private struct Harness {
        let instrument: any InstrumentRendering
        let renderer: InstrumentRenderer
        let buffer: AVAudioPCMBuffer
        let frames: AVAudioFrameCount

        @MainActor
        init(instrument: any InstrumentRendering, frames: AVAudioFrameCount = 512) {
            self.instrument = instrument
            self.frames = frames
            instrument.prepare(sampleRate: 48_000, maxFramesPerQuantum: Int(frames), channelCount: 2)
            renderer = InstrumentRenderer(instrument: instrument, sampleRate: 48_000)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
        }

        /// One fabricated offline pull at `sampleTime`; returns isSilence and
        /// appends channel 0 to `out` when given.
        @MainActor
        @discardableResult
        func pull(sampleTime: Double = 0, into out: inout [Float]) -> Bool {
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = sampleTime
            timestamp.mFlags = .sampleTimeValid
            var silence = ObjCBool(false)
            let status = renderer.renderQuantum(
                timestamp: &timestamp, frameCount: frames,
                audioBufferList: buffer.mutableAudioBufferList, isSilence: &silence)
            #expect(status == noErr)
            if let channels = buffer.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(frames)))
            }
            return silence.boolValue
        }

        @MainActor
        @discardableResult
        func pull(sampleTime: Double = 0) -> Bool {
            var sink: [Float] = []
            let silent = pull(sampleTime: sampleTime, into: &sink)
            return silent
        }

        func push(kind: UInt8, data1: UInt8, data2: UInt8 = 0) {
            renderer.thruRing.push(LiveMIDIEvent(
                hostTime: 0, source: 1, kind: kind,
                pitch: data1, velocity: data2, channel: 0))
        }
    }

    private func captureHarness() -> (EventCaptureInstrument, Harness) {
        let capture = EventCaptureInstrument()
        return (capture, Harness(instrument: capture))
    }

    private func polyHarness() -> Harness {
        Harness(instrument: PolySynthInstrument(params: PolySynthParams(
            waveform: .sine, attack: 0.005, decay: 0.05, sustain: 1.0, release: 0.05,
            cutoffHz: 18_000, resonance: 0, gain: 1.0)))
    }

    // MARK: - C11: ≤ 1 quantum, playing or stopped

    @Test("C11: live CC/bend/pressure render at offset 0 with no schedule (thru while stopped)")
    func liveControllersRenderAtOffsetZeroWhileStopped() {
        let (capture, harness) = captureHarness()
        harness.push(kind: ScheduledMIDIEvent.controlChange, data1: 64, data2: 127)
        harness.push(kind: ScheduledMIDIEvent.pitchBend, data1: 0x12, data2: 0x34)
        harness.push(kind: ScheduledMIDIEvent.channelPressure, data1: 99)
        let silent = harness.pull()
        #expect(!silent)  // the drain made the quantum non-silent — thru is live

        let fired = capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 3)
        // Same quantum, offset 0 — ≤ 1 quantum of latency by construction.
        #expect(fired.allSatisfy { $0.firedAtFrame == 0 && $0.renderStart == 0 })
        #expect(fired.map(\.event.kind) == [
            ScheduledMIDIEvent.controlChange, ScheduledMIDIEvent.pitchBend,
            ScheduledMIDIEvent.channelPressure,
        ])
        // The §4.1 one-data-rule survives the drain byte-for-byte.
        #expect(fired[0].event.pitch == 64 && fired[0].event.velocity == 127)
        #expect(fired[1].event.pitch == 0x12 && fired[1].event.velocity == 0x34)
        #expect(fired[2].event.pitch == 99 && fired[2].event.velocity == 0)
        // Fresh live IDs: top bit set, all distinct.
        #expect(fired.allSatisfy { $0.event.noteID & (1 << 63) != 0 })
        #expect(Set(fired.map(\.event.noteID)).count == 3)
    }

    @Test("C11: with a schedule published (playing), a live CC drains in the same quantum it was queued")
    func liveCCDrainsWithinOneQuantumWhilePlaying() {
        let (capture, harness) = captureHarness()
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate,
            events: [
                ScheduledMIDIEvent(sampleTime: 0, noteID: 0, kind: ScheduledMIDIEvent.noteOn,
                                   pitch: 60, velocity: 100),
            ]))
        _ = harness.pull(sampleTime: 0)
        harness.push(kind: ScheduledMIDIEvent.controlChange, data1: 87, data2: 42)
        _ = harness.pull(sampleTime: 512)

        let fired = capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 2)
        // The CC fired in the SAME (second) quantum it was queued before —
        // at that quantum's renderStart (offset 0).
        #expect(fired[1].event.kind == ScheduledMIDIEvent.controlChange)
        #expect(fired[1].renderStart == 512)
        #expect(fired[1].firedAtFrame == 512)
    }

    @Test("C11: kind ≥ 2 bypasses the pitch map — a CC whose controller equals an open pitch never corrupts the pairing")
    func interleavedControllerNeverCorruptsOpenNotePairing() {
        let (capture, harness) = captureHarness()
        // Open note 60, then a CC on CONTROLLER 60 (data1 == the open pitch —
        // the exact map-collision hazard), a bend, and the note's off.
        harness.push(kind: ScheduledMIDIEvent.noteOn, data1: 60, data2: 100)
        harness.push(kind: ScheduledMIDIEvent.controlChange, data1: 60, data2: 99)
        harness.push(kind: ScheduledMIDIEvent.pitchBend, data1: 0, data2: 0x40)
        harness.push(kind: ScheduledMIDIEvent.noteOff, data1: 60)
        _ = harness.pull()

        let fired = capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 4)
        let on = fired[0], cc = fired[1], bend = fired[2], off = fired[3]
        #expect(on.event.kind == ScheduledMIDIEvent.noteOn)
        #expect(off.event.kind == ScheduledMIDIEvent.noteOff)
        // The pairing survived: the off carries its on's ID.
        #expect(off.event.noteID == on.event.noteID)
        // Controller events got FRESH ids, never the note's.
        #expect(cc.event.noteID != on.event.noteID)
        #expect(bend.event.noteID != on.event.noteID)
        #expect(cc.event.noteID != bend.event.noteID)
    }

    // MARK: - C15: overflow honesty

    @Test("C15: ring-overflow droppedFlag → reset neutralizes pedal AND bend (measured on PolySynth)")
    func droppedFlagResetNeutralizesPedalAndBend() {
        let harness = polyHarness()
        // An (empty) published schedule keeps the node rendering every
        // quantum — a stopped idle node with an empty ring early-returns
        // silence and would never sound the pedal-held voice between drains.
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate, events: []))
        var clock = 0.0
        func pullNext(into out: inout [Float]) {
            _ = harness.pull(sampleTime: clock, into: &out)
            clock += 512
        }

        // 1. Establish maximally stale live state: bend to max (+2 st), pedal
        //    down, note released UNDER the pedal — the voice must keep ringing.
        harness.push(kind: ScheduledMIDIEvent.pitchBend, data1: 0x7F, data2: 0x7F)   // 16383
        harness.push(kind: ScheduledMIDIEvent.controlChange, data1: 64, data2: 127)  // pedal down
        harness.push(kind: ScheduledMIDIEvent.noteOn, data1: 69, data2: 100)         // A4
        harness.push(kind: ScheduledMIDIEvent.noteOff, data1: 69)                    // deferred by pedal
        var held: [Float] = []
        for _ in 0..<20 { pullNext(into: &held) }           // 10 240 frames
        let heldPeak = TestSignals.peak(held, in: 4_800..<10_240)
        let heldHz = TestSignals.dominantFrequency(
            byZeroCrossings: held, sampleRate: rate, in: 4_800..<10_240)
        print("[measured] C15 pre-overflow: peak \(heldPeak), \(heldHz) Hz (bent, expect ≈ 493.9)")
        #expect(heldPeak > 0.1)     // pedal held the released note
        #expect(heldHz > 480)       // bend applied (440 → ≈ 493.9 at +2 st)

        // 2. Overflow the 512-slot thru ring with inert channel-pressure
        //    events: the 513th push fails and sets droppedFlag.
        for _ in 0...InstrumentRenderer.thruRingCapacity {
            harness.push(kind: ScheduledMIDIEvent.channelPressure, data1: 1)
        }
        #expect(daw_atomic_u32_load(harness.renderer.thruRing.droppedFlag) == 1)

        // 3. The next quantum answers the flag with reset(): voice wiped —
        //    exact silence even though 512 inert events drain.
        var afterReset: [Float] = []
        pullNext(into: &afterReset)
        #expect(TestSignals.peak(afterReset, in: 0..<512) == 0)

        // 4. Bend NEUTRALIZED: a fresh note sounds at 440, not 493.9.
        harness.push(kind: ScheduledMIDIEvent.noteOn, data1: 69, data2: 100)
        var fresh: [Float] = []
        for _ in 0..<10 { pullNext(into: &fresh) }
        let freshHz = TestSignals.dominantFrequency(
            byZeroCrossings: fresh, sampleRate: rate, in: 1_000..<5_000)
        print("[measured] C15 post-reset: \(freshHz) Hz (expect 440 ± 2)")
        #expect(abs(freshHz - 440.0) < 2.0)

        // 5. Pedal NEUTRALIZED: the off releases (release 0.05 s → exact
        //    zeros well past 2 400 frames). A stuck pedal would ring on.
        harness.push(kind: ScheduledMIDIEvent.noteOff, data1: 69)
        var tail: [Float] = []
        for _ in 0..<8 { pullNext(into: &tail) }            // 4 096 frames
        let tailPeak = TestSignals.peak(tail, in: 3_072..<4_096)
        print("[measured] C15 post-reset release tail peak: \(tailPeak) (expect 0)")
        #expect(tailPeak == 0)
    }
}
