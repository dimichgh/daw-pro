import AVFAudio
import CAtomics
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m34-l — the AUDITION-ring SUSTAIN-PEDAL gate, and the twin `LiveThruSustain-
/// Tests` was missing.
///
/// ══ WHY THIS SUITE EXISTS: A MEASURED GAP, NOT A SYMMETRY TIDY-UP ═══════════
///
/// m23-ae fixed exactly this bug on the THRU ring (`LiveThruSustainTests` T8):
/// both built-in instruments DEFER a note-off while CC 64 is down, so the key
/// can be up — pitch map clear, popcount 0 — while the voice sounds on, and 6d's
/// tail re-arm had no term for it. The voice was cut at `liveTailSeconds`.
///
/// The fix latched `livePedalDown` in the THRU drain (6b) **and nowhere else.**
/// Musical Typing's Tab pedal (m34-l) rides the **AUDITION** ring, so it set the
/// instrument's CC 64 — the event reaches `instrument.apply` either way — while
/// leaving the renderer's mirror false. The bug came back, on the other ring,
/// for the surface the user actually plays.
///
/// ⭐ **REPRODUCED ON STAGING BEFORE THE FIX, ON ALL THREE INSTRUMENT PATHS**,
/// by holding CC 64 through `pad.playEffort {expressionCC: 64}` and releasing
/// the key with `note.play {pitches: []}` — momentary LUFS at OFF+5 s vs OFF+9 s:
/// polySynth **−16.54 → null**, built-in sampler **−13.94 → null**, hosted GM
/// sound bank **−23.05 → null**. Every one of them silent past the tail.
///
/// The measurement discipline is `LiveThruSustainTests`', verbatim and for its
/// reason: audio through a REAL synth (an event-capturing instrument cannot see
/// whether the node ever asked it to render), and a discriminating window
/// STRICTLY AFTER `liveTailSeconds`, because everything before it is a region
/// where the broken code was already correct.
@MainActor
@Suite("Audition sustain pedal (m34-l)", .serialized)
struct AuditionPedalSustainTests {
    private let rate = 48_000.0

    private struct Harness {
        static let frames: AVAudioFrameCount = 512
        let synth: PolySynthInstrument
        let renderer: InstrumentRenderer
        let buffer: AVAudioPCMBuffer
        var sampleTime = 0.0

        @MainActor
        init() {
            // `LiveThruSustainTests.Harness`' params verbatim: SUSTAIN 1.0 makes
            // a held voice perfectly flat, so "still sounding" needs no envelope
            // tolerance argument at all.
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

        @MainActor
        mutating func pull() -> (peak: Float, isSilence: Bool) {
            var ts = AudioTimeStamp()
            ts.mSampleTime = sampleTime
            ts.mFlags = .sampleTimeValid
            var silence = ObjCBool(false)
            // Dirtied first: a path that neither writes nor zero-fills would
            // otherwise read as "silence" by accident.
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
            #expect(peak != 999)
            return (peak, silence.boolValue)
        }

        /// The AUDITION ring — what `AudioEngine.previewController` and
        /// `setLiveExpression` push through, and therefore what the Tab pedal
        /// uses. Deliberately NOT `thruRing`: a suite that pushed there would be
        /// re-running m23-ae's already-green gate under a new name.
        func pushAudition(kind: UInt8, pitch: UInt8, velocity: UInt8 = 100) {
            renderer.auditionRing.push(LiveMIDIEvent(
                hostTime: 0, source: 1, kind: kind,
                pitch: pitch, velocity: velocity, channel: 0))
        }
    }

    /// DERIVED exactly the way the renderer derives `liveTailFrames`, never
    /// hardcoded: if the quantum size or `liveTailSeconds` moves, every leg here
    /// moves with it.
    private var tailQuanta: Int {
        Int(InstrumentRenderer.liveTailSeconds * rate) / Int(Harness.frames)
    }
    private var holdQuanta: Int { tailQuanta * 3 / 2 }

    // MARK: - P1: the headline leg

    @Test("P1 a CC64-sustained AUDITION voice survives PAST liveTailSeconds after key-up")
    func pedalledAuditionVoiceSurvivesPastTheTail() {
        var h = Harness()
        h.pushAudition(kind: ScheduledMIDIEvent.controlChange, pitch: 64, velocity: 127)
        h.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        // THE KEY GOES UP IMMEDIATELY — the whole scenario, and exactly what
        // `MusicalTypingController.releaseKey` pushes when a finger lifts while
        // Tab is latched. The synth defers the release; the voice sounds on with
        // NOTHING in the audition pitch map to keep 6d arming the tail.
        h.pushAudition(kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0)
        _ = h.pull()
        #expect(h.renderer.openAuditionCount == 0,
                "the key is UP — if this reads 1 the leg below passes for the wrong reason")

        var peaks: [Float] = []
        var silences: [Bool] = []
        for _ in 0..<holdQuanta {
            let quantum = h.pull()
            peaks.append(quantum.peak)
            silences.append(quantum.isSilence)
        }

        // STRICTLY AFTER THE TAIL. A window opened any earlier sits inside the
        // region the pre-fix code handled correctly and proves nothing.
        let from = tailQuanta + 50
        let window = Array(peaks[from..<holdQuanta])
        let lo = window.min() ?? 0
        let hi = window.max() ?? 0
        print("[measured] m34-l P1 window [\(from), \(holdQuanta)) — min \(lo), max \(hi)")
        #expect(lo > 0.01,
                "the PEDAL-SUSTAINED audition voice was CUT — min peak \(lo) over quanta [\(from), \(holdQuanta)), entirely after liveTailSeconds")
        let quietPastTail = silences[from..<holdQuanta].allSatisfy { !$0 }
        #expect(quietPastTail,
                "the node reported SILENCE past the tail under a held pedal")
        // The audition popcount is UNCHANGED by all of this. If a future
        // refactor folds the pedal into it, this reddens and the m23-d pitch-map
        // invariant is protected.
        #expect(h.renderer.openAuditionCount == 0)

        // PEDAL UP: the deferred release lands and the tail becomes bounded
        // again. Without this leg the fix is indistinguishable from "the node
        // never sleeps once any audition CC is seen".
        h.pushAudition(kind: ScheduledMIDIEvent.controlChange, pitch: 64, velocity: 0)
        _ = h.pull()
        for _ in 0..<(tailQuanta + 8) { _ = h.pull() }
        let idle = h.pull()
        #expect(idle.isSilence, "the node never went idle after the pedal was released")
        #expect(idle.peak == 0, "still writing audio after pedal-up — peak \(idle.peak)")
    }

    // MARK: - P2: the control that makes P1 mean something

    /// ⛔ **WITHOUT THE PEDAL THE SAME SEQUENCE MUST GO SILENT.** P1 alone would
    /// pass against a renderer that simply never slept, and against a synth that
    /// ignored the note-off entirely. This is the leg that says the harness can
    /// see a released voice at all — the positive control for P1's absence
    /// claim, run in the opposite direction.
    @Test("P2 CONTROL: the same key-up with NO pedal releases the voice")
    func unpedalledAuditionVoiceIsReleasedByKeyUp() {
        var h = Harness()
        h.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        let onset = h.pull()
        #expect(onset.peak > 0.01, "precondition: the note must speak at all — \(onset.peak)")
        h.pushAudition(kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0)
        _ = h.pull()
        // Release is 0.05 s; a handful of quanta is far past it.
        for _ in 0..<20 { _ = h.pull() }
        let released = h.pull()
        #expect(released.peak < 0.001,
                "the voice did not release without a pedal — peak \(released.peak)")
        // And the node goes honestly idle once the tail expires, which is what
        // P1's "still sounding" is measured against.
        for _ in 0..<(tailQuanta + 8) { _ = h.pull() }
        #expect(h.pull().isSilence, "the node never slept after an ordinary key-up")
    }

    // MARK: - P3: the trap — `pitch == 64` does NOT mean "pedal"

    /// The audition twin of `LiveThruSustainTests` T9, and it is not
    /// belt-and-braces: 6c's controller branch is reached by kinds 2, 3 AND 4,
    /// and `pitch` is a controller number only for kind 2. For `pitchBend` it is
    /// the LSB and for `channelPressure` the value
    /// (`MIDISchedule.swift:21-25`). Both directions of getting that wrong are
    /// live bugs — a CENTRED bend (LSB 64, MSB 0x40 ≥ 64, the single most common
    /// message in any bend gesture) would latch the pedal ON forever and the
    /// node would never sleep again; an aftertouch of 64 (velocity 0) would
    /// latch it OFF under a genuinely held pedal and restore the whole defect.
    ///
    /// ⚠️ **THE BEND LEG IS REACHABLE FROM SHIPPED CODE.** `pad.playEffort` and
    /// `BreathPadModel` push controllers down this exact ring, and the breath
    /// round writes pitch bend beside expression — so this is a message the
    /// audition ring genuinely carries, not a synthetic one.
    @Test("P3 a bend LSB of 64 and an aftertouch of 64 are NOT the sustain pedal")
    func onlyControlChangeSixtyFourLatchesTheAuditionPedal() {
        // A: a centred bend must not latch the pedal ON. Nothing is held after
        // the key-up, so the node must go idle.
        var h = Harness()
        h.pushAudition(kind: ScheduledMIDIEvent.pitchBend, pitch: 64, velocity: 0x40)
        h.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        h.pushAudition(kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0)
        _ = h.pull()
        for _ in 0..<(tailQuanta + 8) { _ = h.pull() }
        let afterBend = h.pull()
        #expect(afterBend.isSilence,
                "a centred pitch-bend latched the audition sustain pedal — the node never sleeps")
        #expect(afterBend.peak == 0, "peak \(afterBend.peak) after a bend-only stimulus")

        // B: channel pressure of 64 must not latch the pedal OFF. The pedal IS
        // genuinely down, so the voice must still be sounding past the tail.
        var g = Harness()
        g.pushAudition(kind: ScheduledMIDIEvent.controlChange, pitch: 64, velocity: 127)
        g.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = g.pull()
        g.pushAudition(kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0)
        _ = g.pull()
        // `velocity` is 0 for this kind, so a guard reading `pitch == 64` alone
        // computes `0 >= 64` = false and silently lifts the pedal.
        g.pushAudition(kind: ScheduledMIDIEvent.channelPressure, pitch: 64, velocity: 0)
        _ = g.pull()

        for _ in 0..<(tailQuanta + 50) { _ = g.pull() }
        let stillHeld = g.pull()
        #expect(stillHeld.peak > 0.01,
                "an aftertouch of 64 lifted the audition pedal — voice cut at \(stillHeld.peak)")
        #expect(!stillHeld.isSilence,
                "the node reported silence past the tail after an aftertouch of 64")
    }

    // MARK: - P4: the two rings share ONE pedal, on purpose

    /// ⚠️ **ONE `livePedalDown`, LAST WRITER WINS ACROSS BOTH RINGS**, mirroring
    /// the instrument, which holds one CC 64 state per channel written by both
    /// producers. This leg pins the direction that matters: a pedal pressed on
    /// the AUDITION ring is lifted by a CC 64 = 0 arriving on the THRU ring —
    /// which is what happens when the user latches Tab and then a hardware pedal
    /// they are also holding comes up. The alternative (a per-ring pedal) would
    /// be a SECOND record of the instrument's one pedal, and the two could
    /// disagree with nothing able to see it.
    @Test("P4 the audition pedal and the thru pedal are ONE latch, mirroring the instrument")
    func theTwoRingsShareOnePedal() {
        var h = Harness()
        h.pushAudition(kind: ScheduledMIDIEvent.controlChange, pitch: 64, velocity: 127)
        h.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        h.pushAudition(kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0)
        _ = h.pull()
        // ⛔ **PAST THE TAIL BEFORE THE LIFT, AND THAT IS NOT PADDING.** The
        // first draft asserted the precondition three quanta in, which is deep
        // inside the window the BROKEN code also handles correctly — so the leg
        // passed unchanged when the audition latch was deleted (measured, during
        // this item's own mutation run). Holding past `liveTailSeconds` first
        // makes the precondition itself depend on the fix.
        for _ in 0..<(tailQuanta + 50) { _ = h.pull() }
        #expect(h.pull().peak > 0.01,
                "precondition: the pedalled voice must still be sounding past the tail")

        // The lift arrives on the OTHER ring. The instrument's own `pedalDown`
        // is one bit and will release the voice; the renderer's mirror must
        // follow, or the node re-arms its tail forever over silence.
        h.renderer.thruRing.push(LiveMIDIEvent(
            hostTime: 0, source: 1, kind: ScheduledMIDIEvent.controlChange,
            pitch: 64, velocity: 0, channel: 0))
        _ = h.pull()
        for _ in 0..<(tailQuanta + 8) { _ = h.pull() }
        let idle = h.pull()
        #expect(idle.isSilence,
                "a thru pedal-up left the AUDITION pedal latched — two records of one pedal")
        #expect(idle.peak == 0, "still writing audio after a cross-ring pedal-up — \(idle.peak)")
    }

    // MARK: - P5: a flush clears it from this side too

    /// `clearLiveVoices()` is the one home for the bulk clear and m23-ae added
    /// the pedal to it; this pins that the AUDITION producer cannot leave a
    /// latch behind that the flush then fails to clear.
    ///
    /// THE DISCRIMINATOR IS `isSilence`, NOT `peak` (T10's reason verbatim): a
    /// stuck latch renders the instrument every quantum and the instrument
    /// renders zeros, so the peak is 0 either way — only the fast path's own
    /// signal separates "asked and got silence" from "never asked".
    ///
    /// ⚠️ **SAID PLAINLY: THIS LEG IS A NO-REGRESSION PIN, NOT A DISCRIMINATOR
    /// FOR m34-l's OWN FIX.** Deleting the audition latch leaves it green
    /// (measured on this item's mutation run) — because with no latch there is
    /// nothing for the flush to fail to clear. It earns its place against the
    /// OPPOSITE mistake: a future change that latches from this ring and forgets
    /// to add it to `clearLiveVoices()`, which is the shape m23-ae's T10 exists
    /// for. P1, P3-B and P4 are the legs that redden on the fix itself.
    @Test("P5 a flush clears a pedal latched from the AUDITION ring")
    func flushClearsAnAuditionLatchedPedal() {
        var h = Harness()
        h.pushAudition(kind: ScheduledMIDIEvent.controlChange, pitch: 64, velocity: 127)
        h.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100)
        _ = h.pull()
        h.pushAudition(kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0)
        _ = h.pull()
        #expect(!h.pull().isSilence, "precondition: the pedal-held voice must be sounding")

        h.renderer.requestFlush()
        let afterFlush = h.pull()
        #expect(h.renderer.openAuditionCount == 0)
        #expect(afterFlush.isSilence,
                "the flush left the PEDAL latch set — the node re-arms forever")
        #expect(afterFlush.peak == 0)
        for _ in 0..<(tailQuanta + 8) { _ = h.pull() }
        #expect(h.pull().isSilence, "the node never slept after a flush under a held pedal")
    }
}
