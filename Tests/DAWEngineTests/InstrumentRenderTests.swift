import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M3 (iii) end-to-end: instrument tracks render through `OfflineRenderer` —
/// the same graph code as live playback — with event timestamps validated by
/// `EventCaptureInstrument` (frame assertions EXACT: this is the offline
/// determinism claim) and audibility validated by `TestToneInstrument`.
/// 48 kHz stereo, 120 BPM → 1 beat = 24 000 frames.
@MainActor
@Suite("Instrument offline render", .serialized)
struct InstrumentRenderTests {
    private func instrumentTrack(clips: [Clip], isMuted: Bool = false,
                                 isSoloed: Bool = false,
                                 instrument: InstrumentDescriptor? = nil) -> Track {
        Track(name: "Keys", kind: .instrument, isMuted: isMuted,
              isSoloed: isSoloed, clips: clips, instrument: instrument)
    }

    /// The audible-tone tests below pin `TestToneInstrument` behavior, which
    /// since M3 (iv) requires opting in — a nil descriptor resolves to the
    /// poly synth (see PolySynthTests for that coverage).
    private var testTone: InstrumentDescriptor { InstrumentDescriptor(kind: .testTone) }

    /// K's project: clip@beat 1 len 4; p60 v100 @0 len 1, p64 v90 @1.5 len 0.5.
    private func timestampClip() -> Clip {
        Clip(name: "midi", startBeat: 1, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, velocity: 90, startBeat: 1.5, lengthBeats: 0.5),
        ])
    }

    private func renderCapturing(
        clips: [Clip], fromBeat: Double, durationSeconds: Double,
        maximumFrameCount: Int = 4_096
    ) throws -> [EventCaptureInstrument.CapturedEvent] {
        let capture = EventCaptureInstrument()
        let renderer = OfflineRenderer(maximumFrameCount: maximumFrameCount)
        renderer.instrumentFactory = { _ in capture }
        _ = try renderer.render(
            tracks: [instrumentTrack(clips: clips)], tempoBPM: 120,
            fromBeat: fromBeat, durationSeconds: durationSeconds
        )
        #expect(capture.overflowCount == 0)
        return capture.capturedEvents().filter { !$0.wasReset }
    }

    // K. THE timestamp test.
    @Test("event timestamps are frame-exact through the offline graph")
    func timestampsExact() throws {
        let fired = try renderCapturing(clips: [timestampClip()],
                                        fromBeat: 0, durationSeconds: 3.0)
        print("[measured] K captured: "
              + fired.map { "\($0.event.kind == 0 ? "on" : "off") p\($0.event.pitch) @\($0.firedAtFrame) v\($0.event.velocity)" }
                     .joined(separator: ", "))
        try #require(fired.count == 4)
        #expect(fired[0].event.kind == 0 && fired[0].event.pitch == 60)
        #expect(fired[0].firedAtFrame == 24_000)
        #expect(fired[0].event.velocity == 100)
        #expect(fired[1].event.kind == 1 && fired[1].event.pitch == 60)
        #expect(fired[1].firedAtFrame == 48_000)
        #expect(fired[1].event.velocity == 0)
        #expect(fired[2].event.kind == 0 && fired[2].event.pitch == 64)
        #expect(fired[2].firedAtFrame == 60_000)
        #expect(fired[2].event.velocity == 90)
        #expect(fired[3].event.kind == 1 && fired[3].event.pitch == 64)
        #expect(fired[3].firedAtFrame == 72_000)
        #expect(fired[3].event.velocity == 0)
    }

    // L. fromBeat offset (and no chase — p60 vanishes entirely).
    @Test("fromBeat 2 → only the p64 pair, at 12000/24000")
    func fromBeatOffset() throws {
        let fired = try renderCapturing(clips: [timestampClip()],
                                        fromBeat: 2, durationSeconds: 1.0)
        try #require(fired.count == 2)
        #expect(fired[0].event.kind == 0 && fired[0].event.pitch == 64)
        #expect(fired[0].firedAtFrame == 12_000)
        #expect(fired[1].event.kind == 1 && fired[1].event.pitch == 64)
        #expect(fired[1].firedAtFrame == 24_000)
    }

    // M. Quantum-size independence.
    @Test("512-frame quanta capture identically to 4096-frame quanta")
    func quantumSizeIndependence() throws {
        let reference = try renderCapturing(clips: [timestampClip()],
                                            fromBeat: 0, durationSeconds: 3.0)
        let small = try renderCapturing(clips: [timestampClip()],
                                        fromBeat: 0, durationSeconds: 3.0,
                                        maximumFrameCount: 512)
        try #require(reference.count == small.count)
        for (a, b) in zip(reference, small) {
            #expect(a.event == b.event)
            #expect(a.firedAtFrame == b.firedAtFrame)
        }
    }

    // N. Same-pitch overlap end-to-end.
    @Test("same-pitch overlap fires 4 exact events with paired IDs end-to-end")
    func overlapIdentity() throws {
        let clip = Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2),
            MIDINote(pitch: 60, velocity: 100, startBeat: 1, lengthBeats: 2),
        ])
        let fired = try renderCapturing(clips: [clip], fromBeat: 0, durationSeconds: 2.0)
        try #require(fired.count == 4)
        #expect(fired[0].event.kind == 0 && fired[0].firedAtFrame == 0)
        #expect(fired[1].event.kind == 0 && fired[1].firedAtFrame == 24_000)
        #expect(fired[2].event.kind == 1 && fired[2].firedAtFrame == 48_000)
        #expect(fired[3].event.kind == 1 && fired[3].firedAtFrame == 72_000)
        let idA = fired[0].event.noteID
        let idB = fired[1].event.noteID
        #expect(idA != idB)
        #expect(fired[2].event.noteID == idA)
        #expect(fired[3].event.noteID == idB)
    }

    // O. Multi-clip merge on one track.
    @Test("two clips on one track merge into one sorted capture stream")
    func multiClipMerge() throws {
        let clip1 = Clip(name: "a", startBeat: 0, lengthBeats: 2, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
        ])
        let clip2 = Clip(name: "b", startBeat: 2, lengthBeats: 2, notes: [
            MIDINote(pitch: 64, velocity: 90, startBeat: 0, lengthBeats: 1),
        ])
        let fired = try renderCapturing(clips: [clip1, clip2],
                                        fromBeat: 0, durationSeconds: 2.0)
        try #require(fired.count == 4)
        #expect(fired[0].event.pitch == 60 && fired[0].event.kind == 0
                && fired[0].firedAtFrame == 0)
        #expect(fired[1].event.pitch == 60 && fired[1].event.kind == 1
                && fired[1].firedAtFrame == 24_000)
        #expect(fired[2].event.pitch == 64 && fired[2].event.kind == 0
                && fired[2].firedAtFrame == 48_000)
        #expect(fired[3].event.pitch == 64 && fired[3].event.kind == 1
                && fired[3].firedAtFrame == 72_000)
    }

    // MARK: - Audible tone (.testTone descriptor → TestToneInstrument)

    // P. Onset + silence + hard stop.
    @Test("A440 blip: true zeros before onset, 440 Hz body, hard stop at the off frame")
    func testToneOnsetAndStop() throws {
        let clip = Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 69, velocity: 127, startBeat: 1, lengthBeats: 1),
        ])
        let audio = try OfflineRenderer().render(
            tracks: [instrumentTrack(clips: [clip], instrument: testTone)], tempoBPM: 120,
            fromBeat: 0, durationSeconds: 2.0
        )
        let left = audio.channelData[0]

        #expect(TestSignals.peak(left, in: 0..<24_000) == 0)  // synth writes true zeros
        let onset = try #require(TestSignals.firstFrame(in: left, exceeding: 1e-4))
        print("[measured] TestTone onset frame: \(onset)")
        #expect(onset >= 24_000 && onset <= 24_002)  // sine starts at phase 0
        let frequency = TestSignals.dominantFrequency(
            byZeroCrossings: left, sampleRate: 48_000, in: 26_000..<45_000)
        print("[measured] TestTone dominant frequency: \(frequency) Hz")
        #expect(abs(frequency - 440.0) < 1.0)
        #expect(TestSignals.peak(left, in: 48_000..<96_000) == 0)  // hard stop, exact
        // Stereo-identical channels.
        #expect(left == audio.channelData[1])
    }

    // Q. Pitch math.
    @Test("p60 sounds middle C (261.626 Hz ± 1)")
    func testTonePitchMath() throws {
        let clip = Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 127, startBeat: 1, lengthBeats: 1),
        ])
        let audio = try OfflineRenderer().render(
            tracks: [instrumentTrack(clips: [clip], instrument: testTone)], tempoBPM: 120,
            fromBeat: 0, durationSeconds: 2.0
        )
        let frequency = TestSignals.dominantFrequency(
            byZeroCrossings: audio.channelData[0], sampleRate: 48_000, in: 26_000..<45_000)
        print("[measured] TestTone p60 dominant frequency: \(frequency) Hz")
        #expect(abs(frequency - 261.626) < 1.0)
    }

    // R. Polyphony.
    @Test("C-major chord: RMS > 1.5 × single note, peak ≤ 0.75")
    func testTonePolyphony() throws {
        func render(_ pitches: [Int]) throws -> RenderedAudio {
            let clip = Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: pitches.map {
                MIDINote(pitch: $0, velocity: 127, startBeat: 1, lengthBeats: 1)
            })
            return try OfflineRenderer().render(
                tracks: [instrumentTrack(clips: [clip], instrument: testTone)], tempoBPM: 120,
                fromBeat: 0, durationSeconds: 2.0
            )
        }
        let window = 26_000..<45_000
        let single = try render([60])
        let chord = try render([60, 64, 67])
        let singleRMS = TestSignals.rms(single.channelData[0], in: window)
        let chordRMS = TestSignals.rms(chord.channelData[0], in: window)
        let chordPeak = TestSignals.peak(chord.channelData[0], in: window)
        print("[measured] single RMS \(singleRMS), chord RMS \(chordRMS), chord peak \(chordPeak)")
        #expect(chordRMS > 1.5 * singleRMS)
        #expect(chordPeak <= 0.75)  // 3 voices × 0.25 amplitude, no clipping
    }

    // S. Mixer semantics across kinds.
    @Test("mute silences; cross-kind solo isolates bit-identically")
    func mixerSemantics() throws {
        let fixtures = try TestSignals.fixtures()
        let midiClip = Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 69, velocity: 127, startBeat: 0, lengthBeats: 2),
        ])
        let audioTrack = Track(name: "Audio", kind: .audio, clips: [
            Clip(name: "clip", startBeat: 0, lengthBeats: 4, audioFileURL: fixtures.cos1k48),
        ])

        // (a) Muted instrument track → the whole render is exact silence.
        let muted = try OfflineRenderer().render(
            tracks: [instrumentTrack(clips: [midiClip], isMuted: true, instrument: testTone)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        for channel in muted.channelData {
            #expect(TestSignals.peak(channel, in: 0..<channel.count) == 0)
        }

        // (b) Audio soloed against an instrument track → bit-identical to the
        // audio-only render.
        var soloedAudio = audioTrack
        soloedAudio.isSoloed = true
        let audioOnly = try OfflineRenderer().render(
            tracks: [audioTrack], tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let audioSolo = try OfflineRenderer().render(
            tracks: [soloedAudio, instrumentTrack(clips: [midiClip], instrument: testTone)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        #expect(maxDifference(audioOnly, audioSolo) == 0.0)

        // (c) Instrument soloed against an audio track → bit-identical to the
        // instrument-only render (pins the NEW cross-kind solo semantics).
        let instOnly = try OfflineRenderer().render(
            tracks: [instrumentTrack(clips: [midiClip], instrument: testTone)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let instSolo = try OfflineRenderer().render(
            tracks: [audioTrack,
                     instrumentTrack(clips: [midiClip], isSoloed: true, instrument: testTone)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        #expect(TestSignals.peak(instOnly.channelData[0], in: 0..<instOnly.frameCount) > 0.2)
        #expect(maxDifference(instOnly, instSolo) == 0.0)
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
}
