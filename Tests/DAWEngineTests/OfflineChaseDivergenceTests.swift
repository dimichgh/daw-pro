import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m23-bv — THE MEASUREMENT.
//
// `OfflineRenderer` schedules with `RescheduleCause.relocation` (m23-bp), so a
// bounce never chases held notes. The roadmap entry asserted, from the flag's
// NAME, that a note straddling a non-zero `fromBeat` is therefore dropped from
// the rendered audio. This suite MEASURES it, in samples, through the real
// `OfflineRenderer.render` / `renderToWAV` production path — because "the flag
// is called no-chase" is a claim about a flag, not about what a user hears.
//
// ⚠️ THIS SUITE PINS THE CURRENT BEHAVIOUR, IT DOES NOT ENDORSE IT. Whether a
// region bounce SHOULD reproduce the song it is a region of is an open PRODUCT
// question (m23-bv), and the answer is the user's, not a cycle's. If that
// decision lands on "a bounce chases", the expectations here flip and this
// header is the record of what was traded.
//
// Geometry, 48 kHz / 120 BPM ⇒ 1 beat = 24 000 frames = 0.5 s:
//   bar 1 = beat 0 (t 0.0 s) · bar 5 = beat 16 (t 8.0 s) · bar 9 = beat 32.
//
// FIVE arms, so no single silence can be mistaken for a finding (the
// NoteChaseGraphTests "a broken rig must not pass as a finding" rule):
//
//   A  held MIDI note [0, 32), rendered from beat 16   → the question
//   B  ANTI-VACUITY control: note onset exactly at 16  → the rig sounds at all
//   C  audio clip [14, 18), rendered from beat 16      → the asymmetry
//   D  MIDI note [14, 18) — C's geometry EXACTLY       → the asymmetry's other half
//   E  REFERENCE: arm A rendered from beat 0, read at  → "playing THROUGH bar 5"
//      the same musical instant (frames 384 000…)         measured, not assumed
//
// Arms C and D differ ONLY in whether the straddling material is audio or MIDI.

private let ocdRate = 48_000.0
private let ocdFramesPerBeat = 24_000        // 120 BPM at 48 kHz
private let ocdFromBeat = 16.0               // bar 5
private let ocdAttackSkip = 480              // 10 ms — past the ADSR attack

@MainActor
@Suite("Offline render: held-note chase divergence (m23-bv measurement)", .serialized)
struct OfflineChaseDivergenceTests {

    // MARK: - Fixtures

    /// The brief's literal shape: one pad held bar 1 → bar 9.
    private func heldPadTrack() -> Track {
        Track(name: "Pad", kind: .instrument, clips: [
            Clip(name: "held", startBeat: 0, lengthBeats: 32, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 32),
            ]),
        ])
    }

    /// Anti-vacuity control: identical track/clip, but the note ONSETS at the
    /// render's own start beat, so it is admitted by the no-chase rule.
    private func onsetAtStartTrack() -> Track {
        Track(name: "Pad", kind: .instrument, clips: [
            Clip(name: "held", startBeat: 0, lengthBeats: 32, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: ocdFromBeat, lengthBeats: 4),
            ]),
        ])
    }

    /// Audio clip [14, 18): starts before the render, ends after it. The
    /// fixture is 2.0 s = exactly 4 beats, so the region is fully backed.
    private func straddlingAudioTrack(_ url: URL) -> Track {
        Track(name: "Bed", kind: .audio, clips: [
            Clip(name: "bed", startBeat: 14, lengthBeats: 4, audioFileURL: url),
        ])
    }

    /// MIDI note [14, 18) — arm C's geometry, expressed in notes.
    private func straddlingMIDITrack() -> Track {
        Track(name: "Pad", kind: .instrument, clips: [
            Clip(name: "held", startBeat: 14, lengthBeats: 4, notes: [
                MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 4),
            ]),
        ])
    }

    // MARK: - Measurement helpers

    private func render(_ tracks: [Track], fromBeat: Double,
                        seconds: Double) throws -> RenderedAudio {
        try OfflineRenderer().render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
            fromBeat: fromBeat, durationSeconds: seconds, masterVolume: 1)
    }

    private func rms(_ channelData: [[Float]], _ range: Range<Int>) -> Double {
        var sum = 0.0
        for frame in range {
            let sample = Double(channelData[0][frame])
            sum += sample * sample
        }
        return (sum / Double(range.count)).squareRoot()
    }

    private func peak(_ channelData: [[Float]], _ range: Range<Int>) -> Double {
        var maximum = 0.0
        for frame in range { maximum = max(maximum, Double(abs(channelData[0][frame]))) }
        return maximum
    }

    private func nonFiniteCount(_ channelData: [[Float]]) -> Int {
        channelData.reduce(0) { $0 + $1.lazy.filter { !$0.isFinite }.count }
    }

    // MARK: - THE measurement

    @Test("""
          m23-bv: a note held across `fromBeat` is ABSENT from the bounce, \
          while the same instant played through from the top SOUNDS
          """)
    func heldNoteIsDroppedFromARegionBounce() throws {
        let fixtures = try TestSignals.fixtures()
        let windowFrames = ocdFramesPerBeat            // 0.5 s
        let window = ocdAttackSkip..<windowFrames

        // A — the question. Pad held [0, 32), bounce starts at bar 5.
        let armA = try render([heldPadTrack()], fromBeat: ocdFromBeat, seconds: 0.5)
        // B — anti-vacuity. Same rig, onset AT bar 5.
        let armB = try render([onsetAtStartTrack()], fromBeat: ocdFromBeat, seconds: 0.5)
        // C — straddling AUDIO clip, same bounce start.
        let armC = try render([straddlingAudioTrack(fixtures.cos1k48)],
                              fromBeat: ocdFromBeat, seconds: 0.5)
        // D — straddling MIDI note with arm C's exact geometry.
        let armD = try render([straddlingMIDITrack()], fromBeat: ocdFromBeat, seconds: 0.5)
        // E — reference: the SAME project rendered from the top, read at the
        //     same musical instant (beat 16 = frame 384 000).
        let armE = try render([heldPadTrack()], fromBeat: 0, seconds: 8.5)
        let referenceStart = 16 * ocdFramesPerBeat
        let referenceWindow = referenceStart..<(referenceStart + windowFrames)

        let a = rms(armA.channelData, window)
        let b = rms(armB.channelData, window)
        let c = rms(armC.channelData, window)
        let d = rms(armD.channelData, window)
        let e = rms(armE.channelData, referenceWindow)
        print("""
              [measured] m23-bv @ bar 5 (beat 16), RMS/peak over 0.5 s:
                A held MIDI [0,32) bounced from 16 : rms \(a) peak \(peak(armA.channelData, window))
                B control  onset == 16            : rms \(b) peak \(peak(armB.channelData, window))
                C audio    [14,18) bounced from 16: rms \(c) peak \(peak(armC.channelData, window))
                D MIDI     [14,18) bounced from 16: rms \(d) peak \(peak(armD.channelData, window))
                E REFERENCE played through from 0 : rms \(e) peak \(peak(armE.channelData, referenceWindow))
                frames A \(armA.frameCount) E \(armE.frameCount)
              """)

        // ANTI-VACUITY FIRST — if these fail, nothing below is a finding.
        let rigSilent = "the rig itself is silent: an instrument track whose note "
            + "onsets at the render start produced nothing, so arm A's silence "
            + "would prove nothing about note chase"
        let referenceSilent = "the reference render is silent: the pad does not sound "
            + "at beat 16 even when played through, so the divergence below is a "
            + "broken fixture, not a policy"
        #expect(b > 1e-3, "\(rigSilent)")
        #expect(e > 1e-3, "\(referenceSilent)")

        // THE FINDING: bounced from bar 5, the held pad is gone …
        #expect(a < 1e-6)
        // … while the very same instant, reached by playing through, sounds.
        #expect(e > 1e-3)

        // THE ASYMMETRY: identical geometry, opposite treatment. A straddling
        // AUDIO clip is entered mid-file by `scheduleAll`'s `offsetSec =
        // max(0, -clipStartSec)`; a straddling MIDI note is dropped whole.
        let audioSilent = "a straddling audio clip is expected to sound (entered "
            + "mid-file) — if this went silent the asymmetry claim is wrong"
        #expect(c > 1e-3, "\(audioSilent)")
        #expect(d < 1e-6)

        // Denormal / NaN guard on every arm.
        let nonFinite = nonFiniteCount(armA.channelData) + nonFiniteCount(armB.channelData)
            + nonFiniteCount(armC.channelData) + nonFiniteCount(armD.channelData)
            + nonFiniteCount(armE.channelData)
        #expect(nonFinite == 0)
    }

    /// The same finding read back off DISK, through `renderToWAV` — the verb
    /// `render.bounce` actually calls. `OfflineRenderer.writeAudioFile` is
    /// frame-exact against what `render` produced, so this is belt-and-braces:
    /// it proves the divergence survives the write path a user's file takes.
    @Test("m23-bv: the same divergence is in the written WAV, not just in memory")
    func divergenceSurvivesTheWAVWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m23bv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bounced = directory.appendingPathComponent("from-bar-5.wav")
        let played = directory.appendingPathComponent("from-the-top.wav")

        let renderer = OfflineRenderer()
        let bouncedInfo = try renderer.renderToWAV(
            tracks: [heldPadTrack()], tempoMap: TempoMap(constantBPM: 120),
            masterVolume: 1, fromBeat: ocdFromBeat, durationSeconds: 0.5, to: bounced)
        _ = try renderer.renderToWAV(
            tracks: [heldPadTrack()], tempoMap: TempoMap(constantBPM: 120),
            masterVolume: 1, fromBeat: 0, durationSeconds: 8.5, to: played)

        let bouncedSamples = try TestSignals.readFile(bounced)
        let playedSamples = try TestSignals.readFile(played)
        let window = ocdAttackSkip..<ocdFramesPerBeat
        let referenceStart = 16 * ocdFramesPerBeat
        let referenceWindow = referenceStart..<(referenceStart + ocdFramesPerBeat)

        let bouncedRMS = rms(bouncedSamples, window)
        let playedRMS = rms(playedSamples, referenceWindow)
        print("[measured] m23-bv WAV: bounce-from-bar-5 rms \(bouncedRMS) "
              + "(\(bouncedInfo.durationSeconds) s, \(bouncedInfo.sampleRate) Hz); "
              + "play-through-bar-5 rms \(playedRMS); files \(bounced.lastPathComponent), "
              + "\(played.lastPathComponent)")

        #expect(bouncedInfo.sampleRate == ocdRate)
        #expect(playedRMS > 1e-3)      // anti-vacuity, on disk
        #expect(bouncedRMS < 1e-6)     // the finding, on disk
    }
}
