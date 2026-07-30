import AVFAudio
import CAtomics
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-u — the live-THRU SUSTAIN gate.
///
/// `LiveThruRenderTests` proves the renderer emits the right EVENTS, using
/// `EventCaptureInstrument`. That instrument records events and writes no
/// audio, so it structurally cannot observe whether the instrument is ever
/// asked to RENDER on a quantum that carries no events — and that was the whole
/// m23-u defect: step 7's silence fast path returned before `instrument.render`
/// on any node with no published schedule, and 6d's re-arm had a term for
/// scheduled/audition voices but NONE for thru. A key the user was physically
/// still holding went silent after `liveTailSeconds`.
///
/// So this suite uses `PolySynthInstrument`, which actually sustains, and
/// asserts on AUDIO. The discriminating window lies STRICTLY AFTER
/// `liveTailSeconds`: a leg that measured the middle of a short hold would sit
/// entirely inside the region where the pre-fix code was already correct.
@MainActor
@Suite("Live thru sustain (m23-u)", .serialized)
struct LiveThruSustainTests {
    private let rate = 48_000.0

    private struct Harness {
        static let frames: AVAudioFrameCount = 512
        let synth: PolySynthInstrument
        let renderer: InstrumentRenderer
        let buffer: AVAudioPCMBuffer
        var sampleTime = 0.0

        @MainActor
        init() {
            // `LiveControllerThruTests.polyHarness()`'s params verbatim: a
            // SUSTAIN of 1.0 makes a held voice perfectly flat, so "flat across
            // the hold" needs no tolerance argument at all. `PolySynthParams()`
            // defaults decay away and would force one.
            synth = PolySynthInstrument(params: PolySynthParams(
                waveform: .sine, attack: 0.005, decay: 0.05, sustain: 1.0,
                release: 0.05, cutoffHz: 18_000, resonance: 0, gain: 1.0))
            synth.prepare(sampleRate: 48_000, maxFramesPerQuantum: Int(Self.frames),
                          channelCount: 2)
            renderer = InstrumentRenderer(instrument: synth, sampleRate: 48_000)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.frames)!
            buffer.frameLength = Self.frames
        }

        /// One quantum. Returns the peak magnitude actually written to the
        /// node's output AND the reported `isSilence` — the peak is what the
        /// master bus would receive, which is zero both when the instrument
        /// renders silence and when the renderer skips the instrument entirely.
        @MainActor
        mutating func pull() -> (peak: Float, isSilence: Bool) {
            var ts = AudioTimeStamp()
            ts.mSampleTime = sampleTime
            ts.mFlags = .sampleTimeValid
            var silence = ObjCBool(false)
            // The node's buffers are dirtied first (AuditionSustainTests:56-61):
            // a path that neither writes nor zero-fills would otherwise read as
            // "silence" by accident. Every code path must produce its own output.
            for ch in 0..<Int(buffer.format.channelCount) {
                if let p = buffer.floatChannelData?[ch] {
                    for i in 0..<Int(Self.frames) { p[i] = 999 }
                }
            }
            let status = renderer.renderQuantum(
                timestamp: &ts, frameCount: Self.frames,
                audioBufferList: buffer.mutableAudioBufferList, isSilence: &silence)
            #expect(status == noErr)
            sampleTime += Double(Self.frames)
            var peak: Float = 0
            for ch in 0..<Int(buffer.format.channelCount) {
                if let p = buffer.floatChannelData?[ch] {
                    for i in 0..<Int(Self.frames) { peak = max(peak, abs(p[i])) }
                }
            }
            // 999 surviving anywhere means the path wrote nothing at all.
            #expect(peak != 999)
            return (peak, silence.boolValue)
        }

        func pushLive(kind: UInt8, pitch: UInt8, velocity: UInt8 = 100) {
            renderer.thruRing.push(LiveMIDIEvent(
                hostTime: 0, source: 1, kind: kind,
                pitch: pitch, velocity: velocity, channel: 0))
        }
    }

    /// Quanta the idle tail runs for. DERIVED exactly the way the renderer
    /// derives `liveTailFrames`, never hardcoded to 750 — if the quantum size
    /// or `liveTailSeconds` ever moves, every leg here moves with it.
    private var tailQuanta: Int {
        Int(InstrumentRenderer.liveTailSeconds * rate) / Int(Harness.frames)
    }
    /// 1.5 × the tail, so the hold runs comfortably PAST the expiry it must
    /// survive. Derived from `tailQuanta` so the two cannot drift apart.
    private var holdQuanta: Int { tailQuanta * 3 / 2 }

    // MARK: - T1: the headline leg

    @Test("T1 a HELD thru note sustains PAST liveTailSeconds (audio, real synth)")
    func heldThruNoteSustainsPastTheTail() {
        var h = Harness()
        h.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        // No note-off is EVER sent: the key stays physically down for the whole
        // hold, which is the entire scenario.

        var peaks: [Float] = []
        var silences: [Bool] = []
        for _ in 0..<holdQuanta {
            let quantum = h.pull()
            peaks.append(quantum.peak)
            silences.append(quantum.isSilence)
        }

        // ONSET: the note speaks at all.
        #expect(peaks[0] > 0.01, "the thru note never spoke — quantum 0 peak \(peaks[0])")
        #expect(h.renderer.openLiveCount == 1)

        // THE DISCRIMINATING WINDOW, STRICTLY AFTER THE TAIL. Quartiles of the
        // whole hold would STRADDLE `tailQuanta` and a partial cut could still
        // read as "mostly flat"; every quantum in this window is past the point
        // where the pre-m23-u code had already stopped rendering.
        let from = tailQuanta + 50
        let window = Array(peaks[from..<holdQuanta])
        let lo = window.min() ?? 0
        let hi = window.max() ?? 0
        print("[measured] m23-u T1 window [\(from), \(holdQuanta)) — min \(lo), max \(hi), ratio \(hi / max(lo, 1e-9))")
        #expect(lo > 0.01,
                "the HELD thru note was CUT — min peak \(lo) over quanta [\(from), \(holdQuanta)), i.e. entirely after liveTailSeconds")
        #expect(hi / max(lo, 1e-9) < 1.05,
                "the held thru note is not flat — min \(lo) max \(hi) over [\(from), \(holdQuanta))")
        #expect(silences[from..<holdQuanta].allSatisfy { !$0 },
                "the node reported SILENCE past the tail under a held key")

        // No second onset: the hold is one continuous voice, never a re-trigger.
        var onsets: [Int] = []
        for i in 1..<peaks.count where peaks[i] > peaks[i - 1] * 2.5 && peaks[i] > 0.02 {
            onsets.append(i)
        }
        #expect(onsets.isEmpty,
                "a second onset appeared at quanta \(onsets) — the thru note sounded more than once")
    }

    // MARK: - T2: the anti-runaway leg

    @Test("T2 releasing a held thru note bounds the tail — the node goes honestly idle")
    func releasedThruNoteLetsTheTailExpire() {
        var h = Harness()
        h.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        // Held well past the tail, so the re-arm path is genuinely exercised
        // before the release (a hold shorter than `tailQuanta` would prove
        // nothing about the counter keeping the node awake).
        for _ in 0..<(tailQuanta + 50) { _ = h.pull() }
        #expect(h.renderer.openLiveCount == 1)

        h.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        let atRelease = h.pull()
        #expect(h.renderer.openLiveCount == 0)
        // The voice the off just closed is in its RELEASE — cutting the node
        // here chops it dead (a click), so this quantum is NOT silent.
        #expect(!atRelease.isSilence)
        #expect(atRelease.peak > 0.01, "the release was chopped — peak \(atRelease.peak)")

        // And now the tail really is bounded: nothing is held, so the idle fast
        // path resumes. This is the property m23-u must not trade away.
        for _ in 0..<(tailQuanta + 4) { _ = h.pull() }
        let idle = h.pull()
        #expect(idle.isSilence, "the node never went idle after the key was released")
        #expect(idle.peak == 0, "the idle node still wrote audio — peak \(idle.peak)")
    }

    // MARK: - T3: the fast path's whole purpose

    @Test("T3 an idle node that never sounded is silent from its FIRST quantum")
    func idleNodeIsSilentFromQuantumOne() {
        var h = Harness()
        // Never touched: no schedule, no thru event, no audition.
        for q in 0..<20 {
            let quantum = h.pull()
            #expect(quantum.peak == 0, "quantum \(q) wrote audio on an untouched node")
            #expect(quantum.isSilence, "quantum \(q) was not reported silent on an untouched node")
        }
        #expect(h.renderer.openLiveCount == 0)
    }

    // MARK: - T4: the mutation leg — the increment guard is load-bearing

    @Test("T4 a same-pitch RETRIGGER counts once (the increment guard)")
    func retriggerOfAnOpenPitchCountsOnce() {
        var h = Harness()
        h.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        #expect(h.renderer.openLiveCount == 1)

        // The retrigger: a second on for a pitch that is ALREADY open. The map
        // slot is overwritten unconditionally, so an unguarded increment would
        // read 2 here and never come back to 0.
        h.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        #expect(h.renderer.openLiveCount == 1)

        h.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        _ = h.pull()
        #expect(h.renderer.openLiveCount == 0)

        // …and the node can therefore still go idle. Unguarded, the counter
        // would sit at 1 forever and 6d would re-arm every quantum for the life
        // of the app — a silence bug traded for permanent wakefulness.
        for _ in 0..<(tailQuanta + 4) { _ = h.pull() }
        let last = h.pull()
        #expect(last.isSilence, "the node never idles — the retrigger leaked a count")
        #expect(last.peak == 0)

        // DELIBERATELY NOT ASSERTED: how many events the instrument received.
        // A future defensive retrigger close (the audition path has one) makes
        // that 3 → 4 while leaving every assertion above unchanged.
    }

    // MARK: - T5: the orphan-off branch must not decrement

    @Test("T5 an ORPHAN note-off does not underflow the counter")
    func orphanNoteOffDoesNotUnderflow() {
        var h = Harness()
        // An off whose on never reached this renderer: the ring dropped it, a
        // merge overflow requeued it, or the source was mid-note when this
        // renderer joined the fanout. All ordinary.
        h.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        _ = h.pull()
        // −1, not 0, is the failure this leg exists for: `openLiveCount > 0`
        // would then be false FOREVER and m23-u would ship green and fix
        // nothing. Idleness alone cannot see it, so assert the VALUE.
        #expect(h.renderer.openLiveCount == 0)

        // A real note-on afterwards must still be counted (a negative counter
        // would come back to 0 here and look correct).
        h.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        #expect(h.renderer.openLiveCount == 1)
        for _ in 0..<(tailQuanta + 4) { _ = h.pull() }
        #expect(!h.pull().isSilence, "a held note after an orphan off was cut")

        h.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        _ = h.pull()
        #expect(h.renderer.openLiveCount == 0)
        for _ in 0..<(tailQuanta + 4) { _ = h.pull() }
        #expect(h.pull().isSilence)
    }

    // MARK: - T6: the C11 leg — controller traffic must not count

    @Test("T6 C11: CC / bend / pressure never touch the live voice count")
    func controllerTrafficNeverCountsAsAVoice() {
        var h = Harness()
        // 200 controller events, some with data1 == 60 — the map-collision
        // hazard. STILL NO CC64, but the reason INVERTED at m23-ae: a pedal-down
        // now keeps the node awake BY DESIGN, so mixing one in here would fail
        // the "controller traffic alone kept the node awake" leg below for a
        // correct reason. The pedal has its own legs, T8 and T9.
        for n in 0..<200 {
            switch n % 3 {
            case 0: h.pushLive(kind: ScheduledMIDIEvent.controlChange, pitch: 60, velocity: 99)
            case 1: h.pushLive(kind: ScheduledMIDIEvent.pitchBend, pitch: 60, velocity: 0x40)
            default: h.pushLive(kind: ScheduledMIDIEvent.channelPressure, pitch: 60, velocity: 0)
            }
        }
        _ = h.pull()
        // A single increment leaked into the kind ≥ 2 branch reads 200 here and
        // NOTHING ever decrements it — one bend gesture is hundreds of events.
        #expect(h.renderer.openLiveCount == 0)
        for _ in 0..<(tailQuanta + 4) { _ = h.pull() }
        #expect(h.pull().isSilence, "controller traffic alone kept the node awake")

        // Under a HELD note: the count is the note's, never the controllers'.
        var g = Harness()
        g.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = g.pull()
        for n in 0..<100 {
            g.pushLive(kind: ScheduledMIDIEvent.pitchBend,
                       pitch: UInt8(n % 128), velocity: 0x40)
        }
        _ = g.pull()
        #expect(g.renderer.openLiveCount == 1)   // 1, not 101
    }

    // MARK: - T7: both bulk-zero sites

    @Test("T7 requestFlush() zeroes the live voice count with the map")
    func flushClearsTheLiveVoiceCount() {
        var h = Harness()
        h.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        #expect(h.renderer.openLiveCount == 1)

        h.renderer.requestFlush()
        let afterFlush = h.pull()
        #expect(h.renderer.openLiveCount == 0)
        // `reset()` contracts silence until the next note-on and the flush zeroes
        // the tail, so this very quantum takes the fast path. A counter left
        // stale by a bulk clear re-arms 6d instead and this reads non-silent —
        // which is why the map and its popcount are cleared through ONE helper.
        #expect(afterFlush.isSilence, "the flush left the live voice count stale")
        #expect(afterFlush.peak == 0)
        for _ in 0..<(tailQuanta + 4) { _ = h.pull() }
        #expect(h.pull().isSilence)
    }

    @Test("T7 a thru-ring overflow reset zeroes the count, and 512 same-pitch ons count ONCE")
    func droppedFlagResetClearsTheLiveVoiceCount() {
        var h = Harness()
        // Overflow the 512-slot ring: the 513th push fails and sets droppedFlag.
        for _ in 0...InstrumentRenderer.thruRingCapacity {
            h.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        }
        #expect(daw_atomic_u32_load(h.renderer.thruRing.droppedFlag) == 1)

        // Step 1b resets and clears, THEN the 512 queued same-pitch ons drain in
        // the same quantum: the first opens the slot, the other 511 retrigger it.
        _ = h.pull()
        // 1, not 512. Since m23-ad this holds for a different reason than it
        // used to: the `== 0` increment guard is gone, and each retrigger now
        // decrements in the defensive close then increments — netting zero
        // because the popcount of a pitch going id₁ → id₂ does not change.
        #expect(h.renderer.openLiveCount == 1)

        h.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        _ = h.pull()
        #expect(h.renderer.openLiveCount == 0)
        for _ in 0..<(tailQuanta + 4) { _ = h.pull() }
        let last = h.pull()
        #expect(last.isSilence)
        #expect(last.peak == 0)
    }

    // MARK: - T8: m23-ae — the pedal is a SECOND term, not a kind of key

    /// The residual m23-u left behind and documented: `openLiveCount` counts
    /// KEYS HELD, but under CC64 both built-ins DEFER the note-off
    /// (`PolySynthInstrument.swift:377`), so the key can be up — popcount 0 —
    /// while the voice is still sounding. 6d then let the tail expire and cut it
    /// mid-sustain. Any pianist who uses a pedal hit this within one bar.
    @Test("T8 a CC64-sustained thru voice survives PAST liveTailSeconds after the key is released")
    func pedalSustainedThruVoiceSurvivesPastTheTail() {
        var h = Harness()
        h.pushLive(kind: ScheduledMIDIEvent.controlChange, pitch: 64, velocity: 127)
        h.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        // THE KEY GOES UP IMMEDIATELY — that is the whole scenario. The synth
        // defers the release because the pedal is down, so the voice sounds on
        // with NOTHING in the pitch map to keep 6d arming the tail.
        h.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        _ = h.pull()
        #expect(h.renderer.openLiveCount == 0,
                "the key is UP — if this reads 1 the leg below passes for the wrong reason")

        var peaks: [Float] = []
        var silences: [Bool] = []
        for _ in 0..<holdQuanta {
            let quantum = h.pull()
            peaks.append(quantum.peak)
            silences.append(quantum.isSilence)
        }

        // Same discriminating window as T1, and for the same reason: everything
        // before `tailQuanta` is a region where the pre-m23-ae code was already
        // correct, so a leg measured there proves nothing.
        let from = tailQuanta + 50
        let window = Array(peaks[from..<holdQuanta])
        let lo = window.min() ?? 0
        let hi = window.max() ?? 0
        print("[measured] m23-ae T8 window [\(from), \(holdQuanta)) — min \(lo), max \(hi)")
        #expect(lo > 0.01,
                "the PEDAL-SUSTAINED voice was CUT — min peak \(lo) over quanta [\(from), \(holdQuanta)), entirely after liveTailSeconds")
        #expect(silences[from..<holdQuanta].allSatisfy { !$0 },
                "the node reported SILENCE past the tail under a held pedal")
        // The counter is UNCHANGED by all of this — the point of the item. If a
        // future refactor folds the pedal into `openLiveCount`, this reddens and
        // the popcount invariant (InstrumentSourceNode.swift:140) is protected.
        #expect(h.renderer.openLiveCount == 0)

        // PEDAL UP: the deferred release finally lands and the tail becomes
        // bounded again. Without this leg the fix is indistinguishable from
        // "the node never sleeps once a pedal event is seen".
        h.pushLive(kind: ScheduledMIDIEvent.controlChange, pitch: 64, velocity: 0)
        _ = h.pull()
        for _ in 0..<(tailQuanta + 8) { _ = h.pull() }
        let idle = h.pull()
        #expect(idle.isSilence, "the node never went idle after the pedal was released")
        #expect(idle.peak == 0, "still writing audio after pedal-up — peak \(idle.peak)")
    }

    // MARK: - T10: the flush must clear the PEDAL too, not just the map

    /// `clearLiveVoices()` is the one home for the bulk clear, and m23-ae added
    /// the pedal to it. Both call sites pair it with `instrument.reset()`, which
    /// clears the instrument's own `pedalDown` (`PolySynthInstrument.swift:227`)
    /// — so a latch left set diverges from the instrument permanently: nothing
    /// is sounding, nothing can ever lift the pedal (the physical pedal-up went
    /// to the flushed stream), and the node re-arms 6d forever.
    ///
    /// THE DISCRIMINATOR IS `isSilence`, NOT `peak`. A stuck latch renders the
    /// instrument every quantum and the instrument renders zeros, so the peak is
    /// 0 either way — only the fast path's own signal separates "asked and got
    /// silence" from "never asked".
    @Test("T10 a flush clears the sustain-pedal latch, not just the pitch map")
    func flushClearsThePedalLatch() {
        var h = Harness()
        h.pushLive(kind: ScheduledMIDIEvent.controlChange, pitch: 64, velocity: 127)
        h.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        h.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        _ = h.pull()
        // Pedal genuinely down with a sustaining voice — T8's state. This is the
        // moment a MIDI device is unplugged (MIDIInputManager.swift:256-260).
        #expect(!h.pull().isSilence, "precondition: the pedal-held voice must be sounding")

        h.renderer.requestFlush()
        let afterFlush = h.pull()
        #expect(h.renderer.openLiveCount == 0)
        #expect(afterFlush.isSilence, "the flush left the PEDAL latch set — the node re-arms forever")
        #expect(afterFlush.peak == 0)
        for _ in 0..<(tailQuanta + 8) { _ = h.pull() }
        #expect(h.pull().isSilence, "the node never slept after a flush under a held pedal")
    }

    // MARK: - T9: the trap — `pitch == 64` does NOT mean "pedal"

    /// In the kind ≥ 2 branch `pitch` is a controller number ONLY for kind 2.
    /// For `pitchBend` it is the LSB and for `channelPressure` it is the value
    /// (MIDISchedule.swift:21-25). So the latch must test the KIND, and both
    /// directions of getting that wrong are live bugs: a CENTRED bend (LSB 64,
    /// MSB 0x40 ≥ 64 — the most common single message in any bend gesture)
    /// would latch the pedal ON forever, and an aftertouch of 64 (velocity 0)
    /// would latch it OFF under a genuinely held pedal, restoring the exact
    /// m23-ae bug. One leg each.
    @Test("T9 a bend LSB of 64 and an aftertouch of 64 are NOT the sustain pedal")
    func onlyControlChangeSixtyFourLatchesThePedal() {
        // A: a centred bend must not latch the pedal ON. Nothing is held, so the
        // node must go idle exactly as in T2.
        var h = Harness()
        h.pushLive(kind: ScheduledMIDIEvent.pitchBend, pitch: 64, velocity: 0x40)
        h.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        h.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        _ = h.pull()
        for _ in 0..<(tailQuanta + 8) { _ = h.pull() }
        let afterBend = h.pull()
        #expect(afterBend.isSilence,
                "a centred pitch-bend latched the sustain pedal — the node never sleeps again")
        #expect(afterBend.peak == 0, "peak \(afterBend.peak) after a bend-only stimulus")

        // B: channel pressure of 64 must not latch the pedal OFF. The pedal IS
        // genuinely down here, so the voice must still be sounding past the tail
        // — the same measurement as T8, with the aftertouch injected mid-hold.
        var g = Harness()
        g.pushLive(kind: ScheduledMIDIEvent.controlChange, pitch: 64, velocity: 127)
        g.pushLive(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = g.pull()
        g.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        _ = g.pull()
        // Aftertouch whose VALUE is 64 — `velocity` is 0 for this kind, so a
        // guard that reads `pitch == 64` alone computes `0 >= 64` = false and
        // silently lifts the pedal.
        g.pushLive(kind: ScheduledMIDIEvent.channelPressure, pitch: 64, velocity: 0)
        _ = g.pull()

        for _ in 0..<(tailQuanta + 50) { _ = g.pull() }
        let stillHeld = g.pull()
        #expect(stillHeld.peak > 0.01,
                "an aftertouch of 64 lifted the sustain pedal — voice cut at \(stillHeld.peak)")
        #expect(!stillHeld.isSilence,
                "the node reported silence past the tail after an aftertouch of 64")
    }
}
