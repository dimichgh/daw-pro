import AVFAudio
import CAtomics
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-d follow-up — the SUSTAIN gate.
///
/// The original m23-d suite proved the renderer emits the right EVENTS and never
/// allocates, using `EventCaptureInstrument`. That instrument records events and
/// writes nothing, so it cannot observe whether the instrument is ever asked to
/// RENDER on a quantum that carries no events — and that turned out to be the
/// whole bug: with the transport stopped a held audition sounded for exactly one
/// quantum, then the node went silent underneath the still-open voice.
///
/// So these tests use `PolySynthInstrument`, which actually sustains, and assert
/// on AUDIO rather than on events: the level is FLAT across the middle of the
/// hold, and exactly ONE onset occurs per audition.
@MainActor
@Suite("Audition sustain (m23-d follow-up)", .serialized)
struct AuditionSustainTests {
    private let rate = 48_000.0
    private let frames: AVAudioFrameCount = 512

    private struct Harness {
        static let frames: AVAudioFrameCount = 512
        let synth: PolySynthInstrument
        let renderer: InstrumentRenderer
        let buffer: AVAudioPCMBuffer
        var sampleTime = 0.0

        @MainActor
        init() {
            synth = PolySynthInstrument(params: .init())
            synth.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 2)
            renderer = InstrumentRenderer(instrument: synth, sampleRate: 48_000,
                                          mergedCapacity: InstrumentRenderer.defaultMergedCapacity)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            buffer.frameLength = 512
        }

        /// One quantum. Returns the peak magnitude actually written to the node's
        /// output — which is zero both when the instrument renders silence AND
        /// when the renderer skips the instrument entirely, so it measures what
        /// the master bus would receive rather than what the code intended.
        @MainActor
        mutating func pull() -> Float {
            var ts = AudioTimeStamp()
            ts.mSampleTime = sampleTime
            ts.mFlags = .sampleTimeValid
            var silence = ObjCBool(false)
            // The node's buffers are dirtied first: a renderer that neither
            // writes nor zero-fills would otherwise read as "silence" by
            // accident. Every code path must actively produce its own output.
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
            return peak
        }
    }

    /// Quanta per second, and the heartbeat cadence the live controller uses.
    private var quantaPerSecond: Int { Int(rate / Double(frames)) }   // 93

    @Test("a held audition SUSTAINS with the transport stopped — flat across the hold")
    func heldAuditionSustains() {
        var h = Harness()
        h.renderer.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 110)
        h.renderer.beatAuditionHeartbeat()

        // Two seconds of frames, heartbeat every 500 ms of frames exactly as
        // `AuditionController` does it. Time is FRAMES, never a clock.
        let total = quantaPerSecond * 2
        let heartbeatEvery = quantaPerSecond / 2
        var peaks: [Float] = []
        for q in 0..<total {
            if q > 0, q % heartbeatEvery == 0 { h.renderer.beatAuditionHeartbeat() }
            peaks.append(h.pull())
        }

        // ONSET: the note speaks at all.
        #expect(peaks[0] > 0.01)
        #expect(h.renderer.openAuditionCount == 1)

        // THE ASSERTION WHOSE ABSENCE HID THE BUG. The middle of the hold must
        // be FLAT — not merely "non-zero somewhere". A note that sounded for one
        // quantum and then went silent passes any "it made sound" check and any
        // "it collapsed and is still falling" release check; it fails this.
        let middle = Array(peaks[(total / 4)..<(3 * total / 4)])
        let lo = middle.min() ?? 0
        let hi = middle.max() ?? 0
        #expect(lo > 0.01, "the hold went silent — min peak \(lo) across the middle of the hold")
        #expect(hi / max(lo, 1e-9) < 2.0,
                "the hold is not flat — min \(lo) max \(hi) across the middle of the hold")
    }

    @Test("exactly ONE onset per audition — the release must not re-trigger the voice")
    func oneOnsetPerAudition() {
        var h = Harness()
        h.renderer.pushAudition(kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 110)
        h.renderer.beatAuditionHeartbeat()

        let holdQuanta = quantaPerSecond          // 1 s held
        let tailQuanta = quantaPerSecond * 2      // 2 s watched after the off
        let heartbeatEvery = quantaPerSecond / 2
        var peaks: [Float] = []
        for q in 0..<holdQuanta {
            if q > 0, q % heartbeatEvery == 0 { h.renderer.beatAuditionHeartbeat() }
            peaks.append(h.pull())
        }
        // The release the controller sends at `durationMs`.
        h.renderer.pushAudition(kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0)
        h.renderer.beatAuditionHeartbeat()
        for _ in 0..<tailQuanta { peaks.append(h.pull()) }

        #expect(h.renderer.openAuditionCount == 0)

        // An ONSET is a quantum whose peak rises sharply over the previous one.
        // The bug produced a SECOND onset at exactly the release, because the
        // off was the only event that made the node render the still-open voice
        // for one quantum — the note "sounded again" when it was told to stop.
        var onsets: [Int] = []
        for i in 1..<peaks.count where peaks[i] > peaks[i - 1] * 2.5 && peaks[i] > 0.02 {
            onsets.append(i)
        }
        #expect(peaks[0] > 0.01)                       // the first onset is quantum 0
        #expect(onsets.isEmpty,
                "a second onset appeared at quanta \(onsets) — the audition sounded more than once")

        // And the release really did release: the tail decays away rather than
        // holding. Shape, not an absolute threshold (the m23-d gate lesson).
        let atRelease = peaks[holdQuanta]
        let atEnd = peaks[peaks.count - 1]
        #expect(atEnd < atRelease * 0.5,
                "the voice did not release — \(atRelease) → \(atEnd)")
    }

    @Test("an idle node with NO open voice is still honestly silent (the fast path survives)")
    func idleNodeStaysSilent() {
        var h = Harness()
        // Never touched: no schedule, no live events, no audition.
        for _ in 0..<20 { #expect(h.pull() == 0) }
        #expect(h.renderer.openAuditionCount == 0)
    }
}
