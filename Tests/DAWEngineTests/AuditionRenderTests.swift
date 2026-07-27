import AVFAudio
import CAtomics
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-d note-audition render path: the SECOND live producer on the same merge
/// — its own ring, its own pitch→ID map, its own overflow policy, and a
/// render-side liveness watchdog. Direct `renderQuantum` calls against
/// `EventCaptureInstrument` (the `LiveThruRenderTests` harness idiom) — no
/// engine, no hardware, no CoreMIDI, and no wall clock: every time-based gate
/// below is driven by a QUANTUM LOOP, because a `Task.sleep` gate would be
/// load-sensitive on a busy machine and would prove scheduling, not audio.
/// Gates C3–C9 of docs/research/design-note-audition.md §13.
@MainActor
@Suite("Note audition render path", .serialized)
struct AuditionRenderTests {
    private let rate = 48_000.0

    private struct Harness {
        let capture: EventCaptureInstrument
        let renderer: InstrumentRenderer
        let buffer: AVAudioPCMBuffer
        let frames: AVAudioFrameCount

        @MainActor
        init(frames: AVAudioFrameCount = 512,
             mergedCapacity: Int = InstrumentRenderer.defaultMergedCapacity) {
            capture = EventCaptureInstrument()
            capture.prepare(sampleRate: 48_000, maxFramesPerQuantum: Int(frames), channelCount: 2)
            renderer = InstrumentRenderer(instrument: capture, sampleRate: 48_000,
                                          mergedCapacity: mergedCapacity)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            self.frames = frames
        }

        /// One fabricated offline pull at `sampleTime`. Returns isSilence.
        @MainActor
        @discardableResult
        func pull(sampleTime: Double = 0) -> Bool {
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

        /// `count` consecutive quanta, sample times advancing by `frames`
        /// starting at quantum index `from` — the ONLY clock these tests use.
        @MainActor
        func pullQuanta(_ count: Int, from: Int = 0) {
            for q in 0..<count { pull(sampleTime: Double((from + q) * Int(frames))) }
        }

        func pushThru(kind: UInt8, pitch: UInt8, velocity: UInt8 = 100) {
            renderer.thruRing.push(LiveMIDIEvent(
                hostTime: 0, source: 1, kind: kind,
                pitch: pitch, velocity: velocity, channel: 0))
        }

        @MainActor
        @discardableResult
        func pushAudition(kind: UInt8, pitch: UInt8, velocity: UInt8 = 100) -> Bool {
            renderer.pushAudition(kind: kind, pitch: pitch, velocity: velocity)
        }

        func fired() -> [EventCaptureInstrument.CapturedEvent] {
            capture.capturedEvents().filter { !$0.wasReset }
        }

        func resetCount() -> Int {
            capture.capturedEvents().filter(\.wasReset).count
        }
    }

    /// Quanta of heartbeat silence after which an open audition voice is cut,
    /// COMPUTED from the renderer's own authority (3 s at 48 kHz / 512 frames
    /// = 281.25 → the off lands on the 283rd pull after the on's pull, because
    /// the voice's clock starts at the END of the quantum it opened in). The
    /// gates below assert a ±1-quantum window around this rather than an exact
    /// index: `lastAuditionHeartbeat` is only refreshed while a voice is open,
    /// so a heartbeat that arrived before the voice opened produces exactly one
    /// extra deadline refresh.
    private var watchdogQuanta: Int {
        Int((rate * InstrumentRenderer.auditionWatchdogSeconds / 512.0).rounded(.up)) + 1
    }

    // MARK: - C3: capacity

    @Test("C3 capacity: liveScratch bound derives from the emit arithmetic")
    func liveScratchCapacityDerivesFromEmitBounds() {
        #expect(InstrumentRenderer.liveScratchCapacity
                == 128 + InstrumentRenderer.thruRingCapacity
                   + 2 * InstrumentRenderer.auditionRingCapacity)
        #expect(InstrumentRenderer.liveScratchCapacity == 768)
        #expect(InstrumentRenderer.auditionRingCapacity == 64)
        // Power of two — LiveEventRing.init preconditions on it.
        #expect(InstrumentRenderer.auditionRingCapacity
                & (InstrumentRenderer.auditionRingCapacity - 1) == 0)
        #expect(InstrumentRenderer.defaultMergedCapacity
                == InstrumentRenderer.liveScratchCapacity + 4_096)
    }

    @Test("C3 a full audition ring of same-pitch retriggers emits exactly 2N-1 events")
    func fullRingOfRetriggersEmitsExactCount() {
        let harness = Harness()
        // A FULL ring (64 = capacity) of note-ons on ONE pitch: the first opens
        // a voice (1 event), each of the other 63 closes the open voice and
        // opens a new one (2 events) → 127. That is the `2 * audTake` bound
        // being exercised, and 2 × 64 = 128 ≤ 768 is why it cannot overrun.
        for _ in 0..<InstrumentRenderer.auditionRingCapacity {
            #expect(harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60))
        }
        // A full ring is not an overflowed ring.
        #expect(daw_atomic_u32_load(harness.renderer.auditionRing.droppedFlag) == 0)
        harness.pull()

        let fired = harness.fired()
        #expect(fired.count == 2 * InstrumentRenderer.auditionRingCapacity - 1)
        #expect(fired.count == 127)
        #expect(harness.resetCount() == 0)
        #expect(harness.renderer.openAuditionCount == 1)
        // Alternating off/on after the first, every off carrying the ID of the
        // on immediately before it.
        #expect(fired[0].event.kind == ScheduledMIDIEvent.noteOn)
        for index in stride(from: 1, to: fired.count, by: 2) {
            #expect(fired[index].event.kind == ScheduledMIDIEvent.noteOff)
            #expect(fired[index].event.noteID == fired[index - 1].event.noteID)
            #expect(fired[index + 1].event.kind == ScheduledMIDIEvent.noteOn)
        }
        #expect(Set(fired.map(\.event.noteID)).count == InstrumentRenderer.auditionRingCapacity)
    }

    @Test("C3 the watchdog's offs never overrun a small merged scratch (§6.3 amendment)")
    func watchdogOffsRespectTheMergeBound() {
        // The 6a watchdog emits OUTSIDE the drains' bound check, so it carries
        // the merge bound itself: with a schedule slice that already fills
        // `mergedScratch`, the cut DEFERS to the next quantum instead of writing
        // past the allocation. mergedCapacity 8 is the seam (LiveThruRenderTests
        // uses 4 the same way).
        let harness = Harness(mergedCapacity: 8)
        for pitch: UInt8 in [60, 64, 67] {
            harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: pitch)
        }
        harness.pull(sampleTime: 0)                        // 3 voices open
        #expect(harness.renderer.openAuditionCount == 3)
        let ons = harness.fired()
        #expect(ons.count == 3)

        // A schedule slice that exactly fills the merged scratch this quantum.
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate,
            events: (0..<8).map {
                ScheduledMIDIEvent(sampleTime: Int64($0), noteID: UInt64(100 + $0),
                                   kind: ScheduledMIDIEvent.noteOn, pitch: 36, velocity: 100)
            }))
        // Overflow the audition ring so the cut is demanded on a KNOWN quantum
        // (the watchdog's own 3 s deadline would land on a quantum with an
        // empty slice, which cannot overrun).
        for _ in 0...InstrumentRenderer.auditionRingCapacity {
            harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 72)
        }
        #expect(daw_atomic_u32_load(harness.renderer.auditionRing.droppedFlag) == 1)

        harness.pull(sampleTime: 512)
        let afterSchedule = Array(harness.fired().dropFirst(3))
        // EXACTLY the schedule slice: 8 events into an 8-slot merge buffer. The
        // three cuts did not fit and were deferred, NOT written past the end.
        #expect(afterSchedule.count == 8)
        #expect(afterSchedule.allSatisfy { $0.event.pitch == 36 })
        #expect(harness.renderer.openAuditionCount == 3)   // still held, not lost

        // Next quantum: the slice is exhausted, so the deferred cut lands.
        harness.pull(sampleTime: 1_024)
        let cuts = Array(harness.fired().dropFirst(11))
        #expect(cuts.count == 3)
        #expect(cuts.allSatisfy { $0.event.kind == ScheduledMIDIEvent.noteOff })
        #expect(Set(cuts.map(\.event.pitch)) == [60, 64, 67])
        #expect(Set(cuts.map(\.event.noteID)) == Set(ons.map(\.event.noteID)))
        #expect(harness.renderer.openAuditionCount == 0)
        #expect(harness.resetCount() == 0)                 // audition NEVER resets
    }

    // MARK: - C4: audible one-shot with the transport STOPPED

    @Test("C4 an audition note sounds with NO schedule published (transport stopped)")
    func auditionSoundsWithTransportStopped() {
        let harness = Harness()
        #expect(harness.pull())                    // empty rings, no schedule → silence

        harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 88)
        let silent = harness.pull()
        #expect(!silent)                           // the strip rendered → it is audible

        let fired = harness.fired()
        #expect(fired.count == 1)
        #expect(fired[0].event.kind == ScheduledMIDIEvent.noteOn)
        #expect(fired[0].event.pitch == 60)
        #expect(fired[0].event.velocity == 88)
        #expect(fired[0].firedAtFrame == 0)        // offset 0 of the draining quantum
        #expect(fired[0].renderStart == 0)
        #expect(fired[0].event.noteID & (1 << 63) != 0)   // a LIVE id, never a schedule id
        #expect(harness.renderer.openAuditionCount == 1)

        harness.pushAudition(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        #expect(!harness.pull())
        let all = harness.fired()
        #expect(all.count == 2)
        #expect(all[1].event.kind == ScheduledMIDIEvent.noteOff)
        #expect(all[1].event.noteID == all[0].event.noteID)
        #expect(harness.renderer.openAuditionCount == 0)

        // Rings drained and nothing open — but the node must STILL render: the
        // voice the off just closed is in its RELEASE, and cutting the node
        // here chops it dead (a click). This assertion previously read
        // `#expect(harness.pull())`; that silence was the m23-d defect, not a
        // property worth keeping.
        #expect(!harness.pull())

        // And the release tail is BOUNDED — after `liveTailSeconds` the idle
        // fast path resumes, so a node that once sounded does not render
        // forever. 8 s is derived from the built-in instruments' maximum
        // release (`releaseRange.upperBound`), whose ramp reaches exactly zero.
        let tailQuanta = Int(InstrumentRenderer.liveTailSeconds * rate) / Int(harness.frames)
        for _ in 0..<tailQuanta { _ = harness.pull() }
        #expect(harness.pull())
    }

    // MARK: - C5: during playback, without disturbing the schedule

    @Test("C5 an audition during playback disturbs no scheduled note")
    func auditionDuringPlaybackLeavesScheduleIntact() {
        let harness = Harness()
        // Four scheduled notes spread across four quanta.
        var events: [ScheduledMIDIEvent] = []
        for index in 0..<4 {
            events.append(ScheduledMIDIEvent(
                sampleTime: Int64(index * 512), noteID: UInt64(index * 2),
                kind: ScheduledMIDIEvent.noteOn, pitch: UInt8(40 + index), velocity: 100))
            events.append(ScheduledMIDIEvent(
                sampleTime: Int64(index * 512 + 256), noteID: UInt64(index * 2),
                kind: ScheduledMIDIEvent.noteOff, pitch: UInt8(40 + index), velocity: 0))
        }
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate, events: events))

        harness.pull(sampleTime: 0)
        harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 72)
        harness.pull(sampleTime: 512)
        harness.pull(sampleTime: 1_024)
        harness.pushAudition(kind: ScheduledMIDIEvent.noteOff, pitch: 72)
        harness.pull(sampleTime: 1_536)

        let fired = harness.fired()
        #expect(harness.resetCount() == 0)         // no all-notes-off anywhere
        // Every scheduled event fired exactly once, at its own frame, with its
        // own noteID — the audition is additive, never substitutive.
        let scheduled = fired.filter { $0.event.pitch != 72 }
        #expect(scheduled.count == 8)
        for index in 0..<4 {
            let on = scheduled[index * 2], off = scheduled[index * 2 + 1]
            #expect(on.event.kind == ScheduledMIDIEvent.noteOn)
            #expect(on.firedAtFrame == Int64(index * 512))
            #expect(off.event.kind == ScheduledMIDIEvent.noteOff)
            #expect(off.firedAtFrame == Int64(index * 512 + 256))
            #expect(on.event.noteID == UInt64(index * 2))
            #expect(off.event.noteID == UInt64(index * 2))
        }
        // The audition pair rode along at each quantum's renderStart.
        let audition = fired.filter { $0.event.pitch == 72 }
        #expect(audition.count == 2)
        #expect(audition[0].firedAtFrame == 512)
        #expect(audition[1].firedAtFrame == 1_536)
        #expect(audition[1].event.noteID == audition[0].event.noteID)
        // …and its IDs collide with no scheduled ID (top bit set).
        #expect(audition.allSatisfy { $0.event.noteID & (1 << 63) != 0 })
    }

    // MARK: - C6: the aliasing regression pin (§4)

    @Test("C6 hardware thru and audition on the SAME pitch never steal each other's voice")
    func thruAndAuditionDoNotAliasOnTheSamePitch() {
        let harness = Harness()
        // The two-handed gesture from §4.1: hardware holds C4, the user drags a
        // note onto C4 and releases it, then releases the hardware key. With ONE
        // pitch-keyed map the audition on orphans the thru voice and the thru
        // off mints an ID no voice holds — a stuck note. Two maps, two pairings.
        harness.pushThru(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 90)
        harness.pull(sampleTime: 0)
        harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 70)
        harness.pull(sampleTime: 512)
        harness.pushAudition(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        harness.pull(sampleTime: 1_024)
        harness.pushThru(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        harness.pull(sampleTime: 1_536)

        let fired = harness.fired()
        #expect(fired.count == 4)
        let thruOn = fired[0], auditionOn = fired[1], auditionOff = fired[2], thruOff = fired[3]
        #expect(thruOn.event.kind == ScheduledMIDIEvent.noteOn && thruOn.event.velocity == 90)
        #expect(auditionOn.event.kind == ScheduledMIDIEvent.noteOn && auditionOn.event.velocity == 70)
        #expect(auditionOff.event.kind == ScheduledMIDIEvent.noteOff)
        #expect(thruOff.event.kind == ScheduledMIDIEvent.noteOff)
        // THE PIN: each off carries ITS OWN on's id.
        #expect(auditionOff.event.noteID == auditionOn.event.noteID)
        #expect(thruOff.event.noteID == thruOn.event.noteID)
        #expect(thruOn.event.noteID != auditionOn.event.noteID)
        #expect(harness.renderer.openAuditionCount == 0)
        #expect(harness.resetCount() == 0)
    }

    // MARK: - C7: overflow isolation

    @Test("C7 an audition-ring overflow cuts ONLY audition voices — never the schedule")
    func auditionOverflowCutsOnlyAuditionVoices() {
        let harness = Harness()
        harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60)
        harness.pull(sampleTime: 0)
        let auditionOn = harness.fired()[0]
        #expect(harness.renderer.openAuditionCount == 1)

        // A schedule the user is listening to, running through the overflow.
        harness.renderer.publish(MIDIEventSchedule(
            generation: 1, mode: .offline, sampleRate: rate,
            events: [
                ScheduledMIDIEvent(sampleTime: 0, noteID: 7, kind: ScheduledMIDIEvent.noteOn,
                                   pitch: 45, velocity: 100),
                ScheduledMIDIEvent(sampleTime: 600, noteID: 7, kind: ScheduledMIDIEvent.noteOff,
                                   pitch: 45, velocity: 0),
            ]))
        // 65 pushes into a 64-slot ring: the last fails and sets the flag.
        for _ in 0...InstrumentRenderer.auditionRingCapacity {
            harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 72)
        }
        #expect(daw_atomic_u32_load(harness.renderer.auditionRing.droppedFlag) == 1)

        harness.pull(sampleTime: 512)
        let afterOverflow = Array(harness.fired().dropFirst(1))
        // The held C4 was cut with its OWN id …
        let cut = afterOverflow.first { $0.event.pitch == 60 }
        #expect(cut?.event.kind == ScheduledMIDIEvent.noteOff)
        #expect(cut?.event.noteID == auditionOn.event.noteID)
        // … the schedule fired untouched …
        #expect(afterOverflow.contains { $0.event.pitch == 45 && $0.event.noteID == 7 })
        // … and NOTHING called instrument.reset(): a global all-notes-off here
        // would kill the scheduled voice, which is exactly what m23-d forbids.
        #expect(harness.resetCount() == 0)
        // Flag consumed: the next quantum does not cut again.
        let openAfter = harness.renderer.openAuditionCount
        harness.pull(sampleTime: 1_024)
        #expect(harness.renderer.openAuditionCount == openAfter)
        #expect(harness.resetCount() == 0)
    }

    @Test("C7 a THRU-ring overflow still resets — and takes the audition map with it")
    func thruOverflowStillResetsAndClearsAuditionVoices() {
        let harness = Harness()
        harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60)
        harness.pull(sampleTime: 0)
        #expect(harness.renderer.openAuditionCount == 1)

        for n in 0...InstrumentRenderer.thruRingCapacity {
            harness.pushThru(kind: ScheduledMIDIEvent.noteOn, pitch: 61, velocity: UInt8(n % 128))
        }
        harness.pull(sampleTime: 512)
        // The m16-b3 contract is unchanged: a thru drop IS a global reset …
        #expect(harness.resetCount() == 1)
        // … and reset() kills every voice, so the audition map must not keep
        // stale IDs that a later off would carry.
        #expect(harness.renderer.openAuditionCount == 0)
        // The cut is not double-reported as an audition note-off: the reset did it.
        #expect(harness.fired().filter { $0.event.pitch == 60 }.count == 1)
    }

    // MARK: - C8 / C9: the liveness watchdog (quantum-driven, never Task.sleep)

    @Test("C8 an audition voice with NO heartbeat is cut after the watchdog window")
    func watchdogCutsAVoiceWhoseMainActorWentAway() {
        let harness = Harness()
        harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60)
        harness.pull(sampleTime: 0)
        let on = harness.fired()[0]
        #expect(harness.renderer.openAuditionCount == 1)

        // Simulates a wedged / crashed / descheduled main actor: the voice is
        // held and NOTHING ever heartbeats again. Frames, not seconds.
        var quanta = 0
        while harness.fired().count == 1, quanta < watchdogQuanta + 8 {
            quanta += 1
            harness.pull(sampleTime: Double(quanta * 512))
        }
        let fired = harness.fired()
        #expect(fired.count == 2)
        #expect(fired[1].event.kind == ScheduledMIDIEvent.noteOff)
        #expect(fired[1].event.pitch == 60)
        #expect(fired[1].event.noteID == on.event.noteID)
        #expect(harness.renderer.openAuditionCount == 0)
        // Landed inside the computed window (3 s of frames ± one quantum), so a
        // stuck note is structurally impossible while the render thread runs.
        #expect(quanta >= watchdogQuanta - 2)
        #expect(quanta <= watchdogQuanta + 1)
        // Exactly once: the map slot is cleared with the off.
        harness.pullQuanta(8, from: quanta + 1)
        #expect(harness.fired().count == 2)
        #expect(harness.resetCount() == 0)
    }

    @Test("C9 a heartbeat every 500 ms of frames holds a note for 10 s of frames")
    func heartbeatHoldsAVoiceIndefinitely() {
        let harness = Harness()
        harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60)
        harness.renderer.beatAuditionHeartbeat()
        harness.pull(sampleTime: 0)
        let on = harness.fired()[0]

        // 10 s of FRAMES = 938 quanta at 512/48 kHz; the controller's 500 ms
        // heartbeat = every 47 quanta. Both computed from the rate, never slept.
        let heldQuanta = Int((rate * 10 / 512).rounded(.up))          // 938
        let heartbeatQuanta = Int((rate * 0.5 / 512).rounded())       // 47
        #expect(heldQuanta == 938 && heartbeatQuanta == 47)
        #expect(heldQuanta > watchdogQuanta * 3)   // the window is really exceeded
        for quantum in 1...heldQuanta {
            if quantum % heartbeatQuanta == 0 { harness.renderer.beatAuditionHeartbeat() }
            harness.pull(sampleTime: Double(quantum * 512))
        }
        // Held for >3× the watchdog window: a legitimately held key is NEVER cut.
        #expect(harness.fired().count == 1)
        #expect(harness.renderer.openAuditionCount == 1)
        #expect(harness.resetCount() == 0)

        // Now the heartbeat stops — the off arrives within the window.
        var quanta = heldQuanta
        while harness.fired().count == 1, quanta < heldQuanta + watchdogQuanta + 8 {
            quanta += 1
            harness.pull(sampleTime: Double(quanta * 512))
        }
        let fired = harness.fired()
        #expect(fired.count == 2)
        #expect(fired[1].event.kind == ScheduledMIDIEvent.noteOff)
        #expect(fired[1].event.noteID == on.event.noteID)
        #expect(quanta - heldQuanta <= watchdogQuanta + 1)
        #expect(harness.renderer.openAuditionCount == 0)
    }

    @Test("the render clock advances on silent and bailed quanta too")
    func renderClockAdvancesOnEveryExitPath() {
        // The watchdog's time base must advance while the strip is SILENT
        // (stopped transport, nothing queued) — otherwise a voice opened just
        // before a long idle stretch would never expire. Proven by opening a
        // voice, running the idle path, and observing the cut land on schedule.
        let harness = Harness()
        harness.pullQuanta(50)                                   // silence fast-path
        harness.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60)
        harness.pull(sampleTime: 50 * 512)
        #expect(harness.renderer.openAuditionCount == 1)
        // Every quantum from here takes the "live block only" path, never the
        // silence early-return, because an open voice alone does not queue
        // events — so this also pins that an open voice does not keep the strip
        // artificially non-silent.
        var quanta = 51
        while harness.fired().count == 1, quanta < 51 + watchdogQuanta + 8 {
            harness.pull(sampleTime: Double(quanta * 512))
            quanta += 1
        }
        #expect(harness.fired().count == 2)
        #expect(harness.renderer.openAuditionCount == 0)
    }
}
