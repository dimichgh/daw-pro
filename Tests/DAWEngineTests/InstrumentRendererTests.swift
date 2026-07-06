import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M3 (iii) renderer state machine: direct `renderQuantum` calls with
/// fabricated `AudioTimeStamp`s against an `EventCaptureInstrument` — no
/// engine, no hardware. Validates the offline epoch latch, generation-change
/// cursor reset, the flush (all-notes-off) contract, and the late-event
/// clamp after a skipped quantum.
@MainActor
@Suite("Instrument renderer state machine", .serialized)
struct InstrumentRendererTests {
    private let rate = 48_000.0

    private struct Harness {
        let capture: EventCaptureInstrument
        let renderer: InstrumentRenderer
        let buffer: AVAudioPCMBuffer

        @MainActor
        init(frames: AVAudioFrameCount = 512) {
            capture = EventCaptureInstrument()
            capture.prepare(sampleRate: 48_000, maxFramesPerQuantum: Int(frames), channelCount: 2)
            renderer = InstrumentRenderer(instrument: capture, sampleRate: 48_000)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
        }

        /// One fabricated offline pull at `sampleTime`. Returns isSilence.
        @MainActor
        func pull(sampleTime: Double, frames: AVAudioFrameCount = 512) -> Bool {
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
    }

    private func onEvent(at sampleTime: Int64, id: UInt64 = 0,
                         pitch: UInt8 = 60, velocity: UInt8 = 100) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(sampleTime: sampleTime, noteID: id, kind: 0,
                           pitch: pitch, velocity: velocity)
    }

    // G. Offline epoch latch.
    @Test("offline epoch latches on the first pull; event @1000 fires at frame 1000")
    func offlineEpochLatch() {
        let harness = Harness()
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate,
            events: [onEvent(at: 1_000)]))

        _ = harness.pull(sampleTime: 0)
        _ = harness.pull(sampleTime: 512)
        _ = harness.pull(sampleTime: 1_024)

        let fired = harness.capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 1)
        #expect(fired.first?.firedAtFrame == 1_000)
        #expect(fired.first?.renderStart == 512)
        #expect(harness.capture.overflowCount == 0)
    }

    // H. Generation change → cursor reset + epoch re-latch.
    @Test("new generation re-latches the epoch and resets the cursor")
    func generationChangeRelatches() {
        let harness = Harness()
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate,
            events: [onEvent(at: 1_000)]))
        _ = harness.pull(sampleTime: 0)
        _ = harness.pull(sampleTime: 512)
        _ = harness.pull(sampleTime: 1_024)

        // New schedule: mSampleTime keeps counting (1536), but the fresh
        // generation re-latches the epoch there, so event @100 is schedule-
        // relative frame 100 — NOT 1636.
        harness.renderer.publish(MIDIEventSchedule(
            generation: 2, mode: .offline, sampleRate: rate,
            events: [onEvent(at: 100, id: 7)]))
        _ = harness.pull(sampleTime: 1_536)

        let fired = harness.capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 2)
        #expect(fired.last?.event.noteID == 7)
        #expect(fired.last?.firedAtFrame == 100)
        #expect(fired.last?.renderStart == 0)
        #expect(harness.capture.overflowCount == 0)
    }

    // I. Flush: reset() honored at the next quantum; nil schedule silences.
    @Test("flush + unpublish → wasReset entry, zero output, isSilence")
    func flushResetsAndSilences() {
        let harness = Harness()
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate,
            events: [onEvent(at: 0)]))
        _ = harness.pull(sampleTime: 0)

        harness.renderer.requestFlush()
        harness.renderer.publish(nil)

        // Poison the buffer so the zero-fill is provable.
        let channels = harness.buffer.floatChannelData!
        for channel in 0..<2 {
            for frame in 0..<512 { channels[channel][frame] = 1.0 }
        }
        let silent = harness.pull(sampleTime: 512)
        #expect(silent)

        let captured = harness.capture.capturedEvents()
        #expect(captured.filter { $0.wasReset }.count == 1)
        // The reset marker is the LAST entry — nothing fires after a flush
        // with no schedule.
        #expect(captured.last?.wasReset == true)
        for channel in 0..<2 {
            for frame in 0..<512 {
                #expect(channels[channel][frame] == 0)
                if channels[channel][frame] != 0 { return }  // fail fast, not 1024 times
            }
        }
        #expect(harness.capture.overflowCount == 0)
    }

    // J. Skipped quantum → late event clamps to the quantum start, fires once.
    @Test("late event after a skipped quantum clamps to quantum start, exactly once")
    func lateEventClampsAfterSkippedQuantum() {
        let harness = Harness()
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate,
            events: [onEvent(at: 600)]))

        _ = harness.pull(sampleTime: 0)          // window [0, 512): no fire
        _ = harness.pull(sampleTime: 1_024)      // SKIP 512..<1024 (overload)
        _ = harness.pull(sampleTime: 1_536)      // must not re-fire

        let fired = harness.capture.capturedEvents().filter { !$0.wasReset }
        #expect(fired.count == 1)                // never dropped, exactly once
        #expect(fired.first?.event.sampleTime == 600)
        #expect(fired.first?.firedAtFrame == 1_024)  // clamped to quantum start
        #expect(fired.first?.renderStart == 1_024)
        #expect(harness.capture.overflowCount == 0)
    }
}
