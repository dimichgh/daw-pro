import AVFAudio
import CAtomics
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M3 (vii) live-thru render path: the thru ring drained inside
/// `renderQuantum`, offset-0 delivery with no schedule (thru while stopped),
/// the schedule-wins-ties merge rule, live noteID pairing, merge-overflow
/// back-pressure, and the dropped-flag → reset contract. Direct quantum calls
/// against `EventCaptureInstrument` — no engine, no hardware, no CoreMIDI.
@MainActor
@Suite("Live thru render path", .serialized)
struct LiveThruRenderTests {
    private let rate = 48_000.0

    private struct Harness {
        let capture: EventCaptureInstrument
        let renderer: InstrumentRenderer
        let buffer: AVAudioPCMBuffer

        @MainActor
        init(frames: AVAudioFrameCount = 512, mergedCapacity: Int = InstrumentRenderer.defaultMergedCapacity) {
            capture = EventCaptureInstrument()
            capture.prepare(sampleRate: 48_000, maxFramesPerQuantum: Int(frames), channelCount: 2)
            renderer = InstrumentRenderer(instrument: capture, sampleRate: 48_000,
                                          mergedCapacity: mergedCapacity)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
        }

        /// One fabricated offline pull at `sampleTime`. Returns isSilence.
        @MainActor
        func pull(sampleTime: Double = 0, frames: AVAudioFrameCount = 512) -> Bool {
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = sampleTime
            timestamp.mFlags = .sampleTimeValid
            var silence = ObjCBool(false)
            let status = renderer.renderQuantum(
                timestamp: &timestamp, frameCount: frames,
                audioBufferList: buffer.mutableAudioBufferList, isSilence: &silence)
            #expect(status == noErr)
            return silence.boolValue
        }

        func pushLive(kind: UInt8, pitch: UInt8, velocity: UInt8 = 100) {
            renderer.thruRing.push(LiveMIDIEvent(
                hostTime: 0, source: 1, kind: kind,
                pitch: pitch, velocity: velocity, channel: 0))
        }
    }

    @Test("live events render at offset 0 with no schedule published (thru while stopped)")
    func liveEventsRenderAtOffsetZeroWithNoSchedule() {
        let harness = Harness()
        #expect(harness.pull())  // empty ring, no schedule → still silence

        harness.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60)
        harness.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 64)
        let silent = harness.pull()
        #expect(!silent)  // something rendered → meters show thru energy

        let fired = harness.capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 2)
        #expect(fired.allSatisfy { $0.firedAtFrame == 0 && $0.renderStart == 0 })
        #expect(fired.map(\.event.pitch) == [60, 64])  // wire (FIFO) order

        // Ring drained: the next pull with nothing queued is silent again.
        #expect(harness.pull())
    }

    @Test("a scheduled note-off at the same frame precedes a live note-on (schedule wins ties)")
    func scheduleOffPrecedesLiveOnAtSameFrame() {
        let harness = Harness()
        // Offline schedule: on @0, off @512 — second quantum starts exactly at
        // the off's frame, where a live re-trigger of the same pitch arrives.
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate,
            events: [
                ScheduledMIDIEvent(sampleTime: 0, noteID: 0, kind: ScheduledMIDIEvent.noteOn,
                                   pitch: 60, velocity: 100),
                ScheduledMIDIEvent(sampleTime: 512, noteID: 0, kind: ScheduledMIDIEvent.noteOff,
                                   pitch: 60, velocity: 0),
            ]))
        _ = harness.pull(sampleTime: 0)
        harness.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60)
        _ = harness.pull(sampleTime: 512)

        let fired = harness.capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 3)
        // Quantum 2 delivers the SCHEDULED off (frame 512) BEFORE the live on
        // (also frame 512) — off-before-on preserved at the shared frame.
        #expect(fired[1].event.kind == ScheduledMIDIEvent.noteOff)
        #expect(fired[1].event.noteID == 0)
        #expect(fired[2].event.kind == ScheduledMIDIEvent.noteOn)
        #expect(fired[2].event.noteID != 0)          // a live ID, not the schedule's
        #expect(fired[1].firedAtFrame == 512)
        #expect(fired[2].firedAtFrame == 512)
    }

    @Test("a live note-off carries its note-on's live noteID")
    func liveNoteOffCarriesItsOnsNoteID() {
        let harness = Harness()
        harness.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60)
        harness.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 64)
        _ = harness.pull()
        harness.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        harness.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 64)
        _ = harness.pull()

        let fired = harness.capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 4)
        let on60 = fired[0], on64 = fired[1], off60 = fired[2], off64 = fired[3]
        #expect(on60.event.pitch == 60 && off60.event.pitch == 60)
        #expect(off60.event.noteID == on60.event.noteID)
        #expect(off64.event.noteID == on64.event.noteID)
        #expect(on60.event.noteID != on64.event.noteID)
    }

    @Test("live noteIDs have the top bit set (can never collide with schedule IDs)")
    func liveNoteIDsHaveTopBitSet() {
        let harness = Harness()
        for pitch in [60, 64, 67] {
            harness.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: UInt8(pitch))
        }
        _ = harness.pull()
        let fired = harness.capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 3)
        #expect(fired.allSatisfy { $0.event.noteID & (1 << 63) != 0 })
        // And they are distinct.
        #expect(Set(fired.map(\.event.noteID)).count == 3)
    }

    @Test("merge overflow leaves live events QUEUED (never dropped, never reordered)")
    func mergeOverflowLeavesLiveEventsQueuedNotDropped() {
        // Tiny merged scratch: 4 slots. Schedule fills the window with 4
        // events; 2 live events would overflow the merge → schedule renders
        // alone, live stays in the ring for the next quantum.
        let harness = Harness(mergedCapacity: 4)
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate,
            events: (0..<4).map {
                ScheduledMIDIEvent(sampleTime: Int64($0), noteID: UInt64($0),
                                   kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
            }))
        harness.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 72)
        harness.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 72)

        _ = harness.pull(sampleTime: 0)
        var fired = harness.capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 4)                      // schedule slice alone
        #expect(fired.allSatisfy { $0.event.pitch == 60 })
        #expect(harness.renderer.thruRing.count == 2)  // live untouched
        #expect(daw_atomic_u32_load(harness.renderer.thruRing.droppedFlag) == 0)

        // Next quantum: schedule exhausted, live drains in wire order.
        _ = harness.pull(sampleTime: 512)
        fired = harness.capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 6)
        #expect(fired[4].event.pitch == 72 && fired[4].event.kind == ScheduledMIDIEvent.noteOn)
        #expect(fired[5].event.pitch == 72 && fired[5].event.kind == ScheduledMIDIEvent.noteOff)
        #expect(fired[5].event.noteID == fired[4].event.noteID)
    }

    @Test("thru-ring dropped flag triggers instrument reset (no stuck voices)")
    func droppedFlagTriggersInstrumentReset() {
        let harness = Harness()
        // Overflow the 512-slot ring: pushes 513 events; the last returns
        // false and sets the flag.
        for n in 0...InstrumentRenderer.thruRingCapacity {
            harness.renderer.thruRing.push(LiveMIDIEvent(
                hostTime: UInt64(n), source: 1, kind: ScheduledMIDIEvent.noteOn,
                pitch: 60, velocity: 100, channel: 0))
        }
        _ = harness.pull()
        let captured = harness.capture.capturedEvents()
        // The reset lands BEFORE the drained events this quantum.
        #expect(captured.first?.wasReset == true)
        #expect(captured.filter { !$0.wasReset }.count == InstrumentRenderer.thruRingCapacity)
        // Flag consumed: the next quantum does not reset again.
        _ = harness.pull()
        #expect(harness.capture.capturedEvents().filter(\.wasReset).count == 1)
    }
}
