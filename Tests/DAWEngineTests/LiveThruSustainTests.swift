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
        // hazard. NO CC64: the sustain-pedal residual survives m23-u (a
        // pedal-held voice is still cut at the tail), so a pedal-down stimulus
        // here would pin that bug as intended behaviour.
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
        #expect(h.renderer.openLiveCount == 1)   // 1, not 512 — the guard again

        h.pushLive(kind: ScheduledMIDIEvent.noteOff, pitch: 60)
        _ = h.pull()
        #expect(h.renderer.openLiveCount == 0)
        for _ in 0..<(tailQuanta + 4) { _ = h.pull() }
        let last = h.pull()
        #expect(last.isSilence)
        #expect(last.peak == 0)
    }
}
