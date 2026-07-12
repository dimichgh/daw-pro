import Foundation
import Testing
@testable import DAWCore

// Pure audio-quantize plan math (M5 iii-f, spec §5b). Fully headless: known
// onsets (source seconds) → exact expected slice geometry. Canonical fixture:
// 120 BPM (spb = 0.5), clip [0, 4) beats, offset 0 → source window [0, 2)s;
// grid = 1 beat. Onset→beat mapping is `beat = (o − windowStart)/spb = 2·o`.

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

private let audioURL = URL(fileURLWithPath: "/tmp/audioquantize-fixture.wav")

/// A whole-file audio clip at [startBeat, startBeat+length), identity stretch.
private func audioClip(startBeat: Double = 0, length: Double = 4,
                       offset: Double = 0, gainDb: Double = 0,
                       fadeIn: Double = 0, fadeInCurve: FadeCurve = .linear,
                       fadeOut: Double = 0, fadeOutCurve: FadeCurve = .linear,
                       stretchRatio: Double = 1) -> Clip {
    Clip(name: "Src", startBeat: startBeat, lengthBeats: length,
         audioFileURL: audioURL, startOffsetSeconds: offset, gainDb: gainDb,
         fadeInBeats: fadeIn, fadeOutBeats: fadeOut,
         fadeInCurve: fadeInCurve, fadeOutCurve: fadeOutCurve,
         stretchRatio: stretchRatio)
}

/// Timeline beat at which a slice sounds a source-seconds onset (ratio 1):
/// `slice.startBeat + (onset − slice.startOffsetSeconds)/spb`.
private func onsetBeat(in slice: Clip, onsetSeconds: Double, spb: Double) -> Double {
    slice.startBeat + (onsetSeconds - slice.startOffsetSeconds) / spb
}

@Suite("AudioQuantizePlan — slice geometry")
struct AudioQuantizePlanGeometryTests {

    // 1. strength 1 → every transient lands EXACTLY on the grid; head/slices/tail
    //    layout and crossfade geometry are analytic.
    @Test("strength 1: transients snap to grid, head+slices+tail emitted")
    func strengthOneGeometry() throws {
        let clip = audioClip()
        // beats 1.1, 1.9, 3.1 → source seconds 0.55, 0.95, 1.55.
        let onsets = [0.55, 0.95, 1.55]
        let s = AudioQuantizeSettings(gridBeats: 1.0, strength: 1)
        let slices = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: onsets, tempoMap: TempoMap(constantBPM: 120), settings: s)

        // head + 3 onsets = 4 clips.
        #expect(slices.count == 4)
        let spb = 0.5

        // Head: [0, ~1), offset 0.
        #expect(approx(slices[0].startBeat, 0))
        #expect(approx(slices[0].startOffsetSeconds, 0))

        // xf = 0.010s/0.5 = 0.02 beats → half 0.01. Onsets 0.55/0.95/1.55 s map to
        // beats 1.1/1.9/3.1; natural inter-onset spans are 1.1 / 0.8 / 1.2 / 0.9
        // beats. Placed at 1/2/3, so the head→s0 and s1→tail pairs are COMPRESSED
        // (a crossfade opens; the right slice is pulled back half with its offset
        // reduced 0.005 s), while s0→s1 is EXPANDED (a clean-cut gap — s1 is NOT
        // pulled back).
        #expect(approx(slices[1].startBeat, 0.99))
        #expect(approx(slices[1].startOffsetSeconds, 0.545))
        #expect(approx(slices[2].startBeat, 2.0))     // s0→s1 gap: no pull-back
        #expect(approx(slices[2].startOffsetSeconds, 0.95))
        #expect(approx(slices[3].startBeat, 2.99))
        #expect(approx(slices[3].startOffsetSeconds, 1.545))

        // The three real transients land dead on grid beats 1, 2, 3.
        #expect(approx(onsetBeat(in: slices[1], onsetSeconds: 0.55, spb: spb), 1.0))
        #expect(approx(onsetBeat(in: slices[2], onsetSeconds: 0.95, spb: spb), 2.0))
        #expect(approx(onsetBeat(in: slices[3], onsetSeconds: 1.55, spb: spb), 3.0))

        // Compressed joins are equal-power crossfades of width 0.02 beats; the
        // expanded s0→s1 join is a clean cut (no fades on that seam).
        #expect(approx(slices[0].fadeOutBeats, 0.02)); #expect(slices[0].fadeOutCurve == .equalPower)
        #expect(approx(slices[1].fadeInBeats, 0.02)); #expect(slices[1].fadeInCurve == .equalPower)
        #expect(approx(slices[1].fadeOutBeats, 0))    // gap after s0: clean cut
        #expect(approx(slices[2].fadeInBeats, 0))     // gap before s1: crisp onset
        #expect(approx(slices[2].fadeOutBeats, 0.02)); #expect(slices[2].fadeOutCurve == .equalPower)
        #expect(approx(slices[3].fadeInBeats, 0.02))
        // Tail carries no clip fade here, so its fade-out is clean.
        #expect(approx(slices[3].fadeOutBeats, 0))
        // All slices are ordinary clips (never comp members) reading the source.
        for sl in slices {
            #expect(sl.takeGroupID == nil)
            #expect(sl.audioFileURL == audioURL)
            #expect(approx(sl.stretchRatio, 1))
        }
    }

    // 2. strength 0.5 → transients land at the midpoint between original and grid.
    @Test("strength 0.5: transients move exactly halfway to grid")
    func strengthHalf() throws {
        let clip = audioClip()
        let onsets = [0.55, 0.95, 1.55]   // beats 1.1, 1.9, 3.1
        let s = AudioQuantizeSettings(gridBeats: 1.0, strength: 0.5, crossfadeSeconds: 0)
        let slices = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: onsets, tempoMap: TempoMap(constantBPM: 120), settings: s)
        #expect(slices.count == 4)
        let spb = 0.5
        // Halfway: 1.1→1.05, 1.9→1.95, 3.1→3.05. No crossfade (0) so base geometry.
        #expect(approx(onsetBeat(in: slices[1], onsetSeconds: 0.55, spb: spb), 1.05))
        #expect(approx(onsetBeat(in: slices[2], onsetSeconds: 0.95, spb: spb), 1.95))
        #expect(approx(onsetBeat(in: slices[3], onsetSeconds: 1.55, spb: spb), 3.05))
        // With crossfadeSeconds 0, no fades at all.
        for sl in slices { #expect(approx(sl.fadeInBeats, 0)); #expect(approx(sl.fadeOutBeats, 0)) }
    }

    // 3. Monotone clamp: onsets whose grid targets collide never reorder — the
    //    second is pushed exactly minSlice past the first.
    @Test("monotone: colliding targets keep minSlice separation, never reorder")
    func monotoneClamp() throws {
        let clip = audioClip()
        // beats 1.1 and 1.4 → both nearest grid slot 1. source 0.55, 0.70
        // (0.15 s apart, comfortably past the 0.05 s minSlice merge threshold).
        let onsets = [0.55, 0.70]
        let s = AudioQuantizeSettings(gridBeats: 1.0, strength: 1,
                                      crossfadeSeconds: 0, minSliceSeconds: 0.05)
        let slices = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: onsets, tempoMap: TempoMap(constantBPM: 120), settings: s)
        #expect(slices.count == 3)  // head + 2
        // minSliceBeats = 0.05/0.5 = 0.1. First → 1.0, second clamped to 1.1.
        #expect(approx(slices[1].startBeat, 1.0))
        #expect(approx(slices[2].startBeat, 1.1))
        // Strictly increasing starts (no reorder), gap >= minSlice.
        #expect(slices[2].startBeat > slices[1].startBeat)
        #expect(approx(slices[2].startBeat - slices[1].startBeat, 0.1))
    }

    // 4. Gain copied to all; head keeps the clip fade-in, tail keeps the fade-out
    //    (curves preserved), independent of the crossfade fades.
    @Test("gain copied to all slices; head fade-in and tail fade-out preserved")
    func gainAndEdgeFades() throws {
        let clip = audioClip(gainDb: 3, fadeIn: 0.5, fadeInCurve: .linear,
                             fadeOut: 0.5, fadeOutCurve: .linear)
        let onsets = [0.55, 0.95, 1.55]
        let s = AudioQuantizeSettings(gridBeats: 1.0, strength: 1)
        let slices = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: onsets, tempoMap: TempoMap(constantBPM: 120), settings: s)
        for sl in slices { #expect(approx(sl.gainDb, 3)) }
        // Head keeps the clip's fade-in (linear), and gets the join fade-out (eq).
        #expect(approx(slices[0].fadeInBeats, 0.5))
        #expect(slices[0].fadeInCurve == .linear)
        #expect(slices[0].fadeOutCurve == .equalPower)
        // Tail keeps the clip's fade-out (linear), and gets the join fade-in (eq).
        let tail = slices[slices.count - 1]
        #expect(approx(tail.fadeOutBeats, 0.5))
        #expect(tail.fadeOutCurve == .linear)
        #expect(tail.fadeInCurve == .equalPower)
    }
}

@Suite("AudioQuantizePlan — rejections")
struct AudioQuantizePlanRejectionTests {

    @Test("MIDI clip → quantizeRequiresAudioClip")
    func midiRejected() {
        let midi = Clip(name: "m", startBeat: 0, lengthBeats: 4, notes: [])
        #expect(throws: ProjectError.self) {
            _ = try AudioQuantizePlan.compute(
                clip: midi, transientsSourceSeconds: [0.5, 1.0], tempoMap: TempoMap(constantBPM: 120),
                settings: AudioQuantizeSettings(gridBeats: 1))
        }
    }

    @Test("non-identity stretch → audioQuantizeStretchUnsupported")
    func stretchRejected() {
        let stretched = audioClip(stretchRatio: 2)
        var thrown: ProjectError?
        do {
            _ = try AudioQuantizePlan.compute(
                clip: stretched, transientsSourceSeconds: [0.5, 1.0], tempoMap: TempoMap(constantBPM: 120),
                settings: AudioQuantizeSettings(gridBeats: 1))
        } catch let e as ProjectError { thrown = e } catch {}
        guard case .audioQuantizeStretchUnsupported = thrown else {
            Issue.record("expected audioQuantizeStretchUnsupported, got \(String(describing: thrown))")
            return
        }
    }

    @Test("clip spanning a tempo boundary → audioQuantizeTempoBoundaryUnsupported (m12-c)")
    func tempoBoundaryRejected() throws {
        // 120→90 at beat 2 — the clip [0, 4) crosses it. The plan's constant
        // spb assumption cannot hold, so compute rejects with the teaching
        // error (split at the boundary first).
        let map = try TempoMap(segments: [
            .init(startBeat: 0, bpm: 120), .init(startBeat: 2, bpm: 90),
        ])
        var thrown: ProjectError?
        do {
            _ = try AudioQuantizePlan.compute(
                clip: audioClip(), transientsSourceSeconds: [0.55, 0.95],
                tempoMap: map, settings: AudioQuantizeSettings(gridBeats: 1))
        } catch let e as ProjectError { thrown = e } catch {}
        guard case .audioQuantizeTempoBoundaryUnsupported = thrown else {
            Issue.record("expected audioQuantizeTempoBoundaryUnsupported, got \(String(describing: thrown))")
            return
        }
        // A clip fully inside ONE segment of the same map still computes.
        let inside = audioClip(startBeat: 2, length: 2)
        let slices = try AudioQuantizePlan.compute(
            clip: inside, transientsSourceSeconds: [0.55, 0.95],
            tempoMap: map, settings: AudioQuantizeSettings(gridBeats: 1))
        #expect(!slices.isEmpty)
    }

    @Test("fewer than 2 usable transients → audioQuantizeNoTransients")
    func tooFewTransients() {
        let clip = audioClip()
        // Only one onset inside the window.
        var thrown: ProjectError?
        do {
            _ = try AudioQuantizePlan.compute(
                clip: clip, transientsSourceSeconds: [0.9], tempoMap: TempoMap(constantBPM: 120),
                settings: AudioQuantizeSettings(gridBeats: 1))
        } catch let e as ProjectError { thrown = e } catch {}
        guard case .audioQuantizeNoTransients = thrown else {
            Issue.record("expected audioQuantizeNoTransients, got \(String(describing: thrown))")
            return
        }
    }

    @Test("onsets outside the clip window are ignored")
    func outOfWindowIgnored() {
        let clip = audioClip(offset: 0)   // window [0, 2)s
        // 3.0 and -1.0 are outside; only 0.5 and 1.5 are usable → still 2, ok.
        #expect(throws: Never.self) {
            _ = try AudioQuantizePlan.compute(
                clip: clip, transientsSourceSeconds: [-1.0, 0.5, 1.5, 3.0],
                tempoMap: TempoMap(constantBPM: 120), settings: AudioQuantizeSettings(gridBeats: 1))
        }
        // With only one in-window onset, it rejects.
        #expect(throws: ProjectError.self) {
            _ = try AudioQuantizePlan.compute(
                clip: clip, transientsSourceSeconds: [0.5, 3.0, 5.0],
                tempoMap: TempoMap(constantBPM: 120), settings: AudioQuantizeSettings(gridBeats: 1))
        }
    }
}
