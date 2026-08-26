import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m23-bv — THE MEASUREMENT, AND (since 2026-08-17) THE CONVERGENCE IT BOUGHT.
//
// This suite exists because it MEASURED, in samples through the real
// `OfflineRenderer.render` / `renderToWAV` production path, something the
// roadmap had only inferred from a flag's name: under the old
// `RescheduleCause.relocation` a bounce never chased held notes, so a MIDI note
// straddling a non-zero `fromBeat` was dropped from the rendered audio
// entirely.
//
// WHAT IT MEASURED, kept verbatim as the record of what was traded — these are
// the numbers the user ruled on:
//
//   A  held MIDI [0, 32) bounced from beat 16  → rms 0.0     ← DIGITAL SILENCE
//   B  control, onset exactly at beat 16       → rms 0.066
//   C  AUDIO clip [14, 18) bounced from 16     → rms 0.354   ← it always sounded
//   D  MIDI note [14, 18), C's geometry EXACTLY→ rms 0.0     ← the asymmetry
//   E  arm A played THROUGH from beat 0        → rms 0.064
//
// A and E are the same project at the same musical instant; only the render's
// start beat differed. C and D differ ONLY in whether the straddling material
// is audio or MIDI, and they disagreed — the same edit, expressed in two media,
// bounced differently.
//
// ⭐ THE RULING (user, 2026-08-17): "make the bounce chase held notes, like the
// play button already does." `OfflineRenderer` now passes `.offlineRender`, a
// FOURTH `RescheduleCause` whose `chasesHeldNotes` is true. So this suite no
// longer pins a divergence — IT PINS THE CONVERGENCE, and arms A and D flip
// from silence to sound. The accepted cost is named in `RescheduleCause`: a
// chased note RE-ATTACKS at full velocity, so arm A is a fresh attack at bar 5,
// not a continuation of the bar-1 attack. The user was shown that counter-case
// ("missing pad" vs "phantom attack") before ruling.
//
// ⚠️ THE REGRESSION THIS SUITE STILL GUARDS is the one it was born measuring:
// if the offline cause is ever reverted to `.relocation` — by an edit, a merge,
// or a "revert for byte-identity" — arms A and D go to DIGITAL SILENCE and both
// legs below fail loudly, naming the ruling. That is why the silent arms were
// converted rather than deleted.
//
// ⚠️ WHAT CANNOT BE PINNED HERE, stated so nobody builds on it: B measured
// 0.066 and E 0.064, so this fixture CANNOT discriminate "re-attacked at the
// anchor" from "sustained through". The honest assertion is that A SOUNDS and
// that A and D no longer disagree with C — not a claim about attack shape.
// `NoteChaseScheduleTests` G2 owns the frame-exact re-attack semantics.
//
// Geometry, 48 kHz / 120 BPM ⇒ 1 beat = 24 000 frames = 0.5 s:
//   bar 1 = beat 0 (t 0.0 s) · bar 5 = beat 16 (t 8.0 s) · bar 9 = beat 32.
//
// FIVE arms, so no single reading can be mistaken for a finding (the
// NoteChaseGraphTests "a broken rig must not pass as a finding" rule):
//
//   A  held MIDI note [0, 32), rendered from beat 16   → THE RULING's subject
//   B  ANTI-VACUITY control: note onset exactly at 16  → the rig sounds at all
//   C  audio clip [14, 18), rendered from beat 16      → the media asymmetry
//   D  MIDI note [14, 18) — C's geometry EXACTLY       → the asymmetry's other half
//   E  REFERENCE: arm A rendered from beat 0, read at  → "playing THROUGH bar 5"
//      the same musical instant (frames 384 000…)         measured, not assumed

private let ocdRate = 48_000.0
private let ocdFramesPerBeat = 24_000        // 120 BPM at 48 kHz
private let ocdFromBeat = 16.0               // bar 5
private let ocdAttackSkip = 480              // 10 ms — past the ADSR attack

@MainActor
@Suite("Offline render: held-note chase — the bounce chases (m23-bv, ruled 2026-08-17)",
       .serialized)
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
          m23-bv RULED: a note held across `fromBeat` SOUNDS in the bounce, \
          like the same instant played through from the top
          """)
    func heldNoteIsChasedIntoARegionBounce() throws {
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

        // ⭐ THE RULING, IN SAMPLES — and THE REGRESSION GUARD. Bounced from bar
        // 5, the held pad SOUNDS. This is the exact assertion that read
        // `a < 1e-6` before 2026-08-17; it is inverted, not deleted, so a revert
        // of `OfflineRenderer`'s cause to `.relocation` fails HERE, loudly, in
        // the audio a user would have lost.
        let ruledButSilent = "THE m23-bv RULING IS NOT IN EFFECT: a MIDI note held "
            + "across `fromBeat` is SILENT in the bounce (rms \(a)). The user ruled on "
            + "2026-08-17 that a bounce chases held notes. First thing to check: does "
            + "`OfflineRenderer` still pass `cause: .offlineRender` to `scheduleAll`? "
            + "A revert to `.relocation` reproduces exactly this silence."
        #expect(a > 1e-3, "\(ruledButSilent)")
        // … and the very same instant reached by playing through still sounds,
        // which is the comparison the ruling was about: a region bounce now
        // agrees with the song it is a region of.
        #expect(e > 1e-3)

        // THE ASYMMETRY, NOW CLOSED. Identical geometry, and since the ruling
        // identical treatment. A straddling AUDIO clip was always entered
        // mid-file by `scheduleAll`'s `offsetSec = max(0, -clipStartSec)`; a
        // straddling MIDI note used to be dropped whole and now chases.
        let audioSilent = "a straddling audio clip is expected to sound (entered "
            + "mid-file) — if this went silent the asymmetry claim is wrong"
        #expect(c > 1e-3, "\(audioSilent)")
        let asymmetryReturned = "THE AUDIO/MIDI ASYMMETRY IS BACK: a straddling AUDIO "
            + "clip sounds (rms \(c)) but a straddling MIDI note at the IDENTICAL "
            + "geometry is silent (rms \(d)). m23-bv closed this by making the bounce "
            + "chase; check `OfflineRenderer`'s `cause:` argument."
        #expect(d > 1e-3, "\(asymmetryReturned)")

        // Denormal / NaN guard on every arm.
        let nonFinite = nonFiniteCount(armA.channelData) + nonFiniteCount(armB.channelData)
            + nonFiniteCount(armC.channelData) + nonFiniteCount(armD.channelData)
            + nonFiniteCount(armE.channelData)
        #expect(nonFinite == 0)
    }

    /// The same result read back off DISK, through `renderToWAV` — the verb
    /// `render.bounce` actually calls. `OfflineRenderer.writeAudioFile` is
    /// frame-exact against what `render` produced, so this is belt-and-braces:
    /// it proves the ruling reaches the write path a user's file takes, and not
    /// merely the in-memory buffer.
    @Test("m23-bv: the chased note is in the written WAV, not just in memory")
    func chaseSurvivesTheWAVWrite() throws {
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
        // THE RULING, on disk. Was `bouncedRMS < 1e-6` before 2026-08-17.
        let silentOnDisk = "the bounced WAV a user would receive is SILENT at bar 5 "
            + "(rms \(bouncedRMS)) though the pad is held across it — the m23-bv ruling "
            + "is not reaching `renderToWAV`."
        #expect(bouncedRMS > 1e-3, "\(silentOnDisk)")
    }
}
