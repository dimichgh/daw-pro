import Foundation
import Testing
@testable import DAWCore

// m32-b1 — the FIXED-DIVISION chop on `AudioQuantizePlan`. Pure and headless:
// no engine, no PCM, no detector. Canonical fixture matches
// AudioQuantizePlanTests: 120 BPM (spb = 0.5), clip [0, 4) beats, offset 0 →
// source window [0, 2) s, so a division boundary at source second `s` sits at
// timeline beat `2·s`.
//
// ⭐ Deliberately NOT a render suite. The m32-b2 keeper law applies with full
// force here: at strength 0 ANY boundary set tiles the window contiguously, so
// a render-and-reassemble gate is structurally blind to wrong cut PLACEMENT —
// the pieces still concatenate back into the same audio. The discriminating
// assertions are the exact offsets, the tiling identity, and (at the control
// layer) the detector-call spy.

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

private let divAudioURL = URL(fileURLWithPath: "/tmp/audioquantize-divisions-fixture.wav")

/// A whole-file audio clip at [startBeat, startBeat+length), identity stretch.
private func divClip(startBeat: Double = 0, length: Double = 4,
                     offset: Double = 0) -> Clip {
    Clip(name: "Src", startBeat: startBeat, lengthBeats: length,
         audioFileURL: divAudioURL, startOffsetSeconds: offset, stretchRatio: 1)
}

private let map120 = TempoMap(constantBPM: 120)

@Suite("AudioQuantizePlan — fixed-division chop (m32-b1)")
struct AudioQuantizeDivisionsTests {

    // MARK: - The shipped default is untouched

    @Test("divisions defaults to nil — the shipped detector path is the default")
    func divisionsDefaultsNil() {
        #expect(AudioQuantizeSettings(gridBeats: 1).divisions == nil)
        #expect(AudioQuantizeSettings(gridBeats: 1, strength: 0).divisions == nil)
    }

    /// EXISTING-CALLER NO-CHANGE PIN. The same clip and onsets through the
    /// detector path must produce byte-identical geometry to the shipped
    /// `AudioQuantizePlanTests.strengthOneGeometry` fixture — the divisions
    /// branch must not have perturbed the path it sits beside.
    @Test("detector path is byte-identical with divisions nil (existing callers)")
    func detectorPathUnchanged() throws {
        let clip = divClip()
        let onsets = [0.55, 0.95, 1.55]
        let slices = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: onsets, tempoMap: map120,
            settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 1))
        #expect(slices.count == 4)
        #expect(approx(slices[0].startBeat, 0))
        #expect(approx(slices[0].startOffsetSeconds, 0))
        // Onsets land exactly on beats 1 / 2 / 3 (strength 1, xf half = 0.01).
        #expect(approx(slices[1].startBeat, 1 - 0.01))
        #expect(approx(slices[2].startBeat, 2))
        #expect(approx(slices[3].startBeat, 3 - 0.01))
    }

    // MARK: - Geometry

    @Test("divisions 8 at strength 0: 8 clips at exact quarter-second offsets")
    func eightEqualParts() throws {
        let clip = divClip()
        let settings = AudioQuantizeSettings(gridBeats: 1.0, strength: 0, divisions: 8)
        let slices = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: [], tempoMap: map120, settings: settings)

        #expect(slices.count == 8)
        // Window [0, 2) s in eighths → 0.25 s each → 0.5 beats each at spb 0.5.
        for i in 0..<8 {
            #expect(approx(slices[i].startOffsetSeconds, Double(i) * 0.25),
                    "slice \(i) source offset")
            #expect(approx(slices[i].startBeat, Double(i) * 0.5), "slice \(i) startBeat")
            #expect(approx(slices[i].lengthBeats, 0.5), "slice \(i) length")
        }
        // ⭐ Click-free by construction: strength 0 makes spacing == natural, so
        // every crossfade self-clamps to a CLEAN CUT. No equal-power fades.
        for slice in slices {
            #expect(slice.fadeInBeats == 0)
            #expect(slice.fadeOutBeats == 0)
        }
    }

    /// POSITIVE CONTROL for the assertion above: a different `divisions` must
    /// produce a different array, so "8 offsets at 0.25 s" cannot be satisfied
    /// by a no-op that ignored the parameter.
    @Test("divisions 4 yields a DIFFERENT array (positive control for the offsets)")
    func fourEqualPartsDiffers() throws {
        let clip = divClip()
        func offsets(_ divisions: Int) throws -> [Double] {
            try AudioQuantizePlan.compute(
                clip: clip, transientsSourceSeconds: [], tempoMap: map120,
                settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 0,
                                                divisions: divisions))
                .map(\.startOffsetSeconds)
        }
        let eight = try offsets(8)
        let four = try offsets(4)
        #expect(four.count == 4)
        #expect(four != eight)
        for (i, o) in four.enumerated() { #expect(approx(o, Double(i) * 0.5)) }
    }

    /// THE RECONSTRUCTION PROPERTY, stated where it is actually discriminating:
    /// the slices TILE the window with no gap and no overlap, so concatenating
    /// them replays the source exactly. Asserted geometrically (see the suite
    /// note on why a render cannot see this).
    @Test("slices tile the window exactly — concatenation reconstructs the source")
    func slicesTileTheWindow() throws {
        let clip = divClip()
        for divisions in [2, 3, 5, 8, 16] {
            let slices = try AudioQuantizePlan.compute(
                clip: clip, transientsSourceSeconds: [], tempoMap: map120,
                settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 0,
                                                divisions: divisions))
            #expect(slices.count == divisions, "divisions \(divisions) → \(slices.count) clips")
            // Head starts at the window start, on the beat the clip started on.
            #expect(approx(slices[0].startOffsetSeconds, 0))
            #expect(approx(slices[0].startBeat, clip.startBeat))
            for i in 0..<(slices.count - 1) {
                // Slice i ends in SOURCE exactly where slice i+1 begins…
                #expect(approx(slices[i].startOffsetSeconds + slices[i].lengthBeats * 0.5,
                               slices[i + 1].startOffsetSeconds),
                        "source seam \(i) at divisions \(divisions)")
                // …and in TIMELINE exactly where slice i+1 begins.
                #expect(approx(slices[i].startBeat + slices[i].lengthBeats,
                               slices[i + 1].startBeat),
                        "timeline seam \(i) at divisions \(divisions)")
            }
            // The tail reaches the window end, and the whole run spans the clip.
            let last = slices[slices.count - 1]
            #expect(approx(last.startOffsetSeconds + last.lengthBeats * 0.5, 2.0))
            #expect(approx(last.startBeat + last.lengthBeats,
                           clip.startBeat + clip.lengthBeats))
        }
    }

    // MARK: - The detector argument is genuinely unused

    @Test("divisions IGNORES transientsSourceSeconds — three wildly different lists agree")
    func transientsIgnoredInDivisionsMode() throws {
        let clip = divClip()
        let settings = AudioQuantizeSettings(gridBeats: 1.0, strength: 0, divisions: 5)
        func geometry(_ transients: [Double]) throws -> [String] {
            try AudioQuantizePlan.compute(
                clip: clip, transientsSourceSeconds: transients,
                tempoMap: map120, settings: settings)
                .map { "\($0.startBeat)|\($0.lengthBeats)|\($0.startOffsetSeconds)" }
        }
        let none = try geometry([])
        #expect(try geometry([0.13, 0.61, 1.42]) == none)
        #expect(try geometry([0.9]) == none)
        #expect(try geometry([0.05, 0.4, 0.8, 1.2, 1.6, 1.9]) == none)
        // Positive control: the SAME transient lists DO change the detector
        // path, so "they agree" is a fact about divisions, not about the lists.
        let detector = AudioQuantizeSettings(gridBeats: 1.0, strength: 0)
        let a = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: [0.13, 0.61, 1.42],
            tempoMap: map120, settings: detector).map(\.startOffsetSeconds)
        let b = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: [0.05, 0.4, 0.8, 1.2, 1.6, 1.9],
            tempoMap: map120, settings: detector).map(\.startOffsetSeconds)
        #expect(a != b)
    }

    // MARK: - The two count rules differ ON PURPOSE

    @Test("divisions 2 is legal (one boundary, head + tail) — the >= 2 rule is detector-only")
    func halvingIsLegal() throws {
        let clip = divClip()
        let slices = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: [], tempoMap: map120,
            settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 0, divisions: 2))
        #expect(slices.count == 2)
        #expect(approx(slices[0].startOffsetSeconds, 0))
        #expect(approx(slices[1].startOffsetSeconds, 1.0))

        // Positive control: ONE onset on the DETECTOR path still throws, so the
        // relaxation is scoped to divisions and did not leak.
        #expect(throws: ProjectError.self) {
            _ = try AudioQuantizePlan.compute(
                clip: clip, transientsSourceSeconds: [0.9], tempoMap: map120,
                settings: AudioQuantizeSettings(gridBeats: 1.0))
        }
    }

    @Test("too-fine divisions throw audioQuantizeDivisionsTooFine, not NoTransients")
    func tooFineDivisions() throws {
        // Window 0.08 s (0.16 beats at spb 0.5): the midpoint is 0.04 s from
        // each edge, under the 0.05 s floor, so every boundary is squeezed out.
        let tiny = divClip(length: 0.16)
        var thrown: Error?
        do {
            _ = try AudioQuantizePlan.compute(
                clip: tiny, transientsSourceSeconds: [], tempoMap: map120,
                settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 0, divisions: 2))
        } catch { thrown = error }
        let error = try #require(thrown as? ProjectError)
        guard case .audioQuantizeDivisionsTooFine(let id, let divisions, _, _) = error else {
            Issue.record("expected audioQuantizeDivisionsTooFine, got \(error)")
            return
        }
        #expect(id == tiny.id)
        #expect(divisions == 2)
        let message = error.errorDescription ?? ""
        // The message carries the ARITHMETIC and does NOT give detector advice.
        #expect(message.contains("cannot be cut into 2 equal parts"))
        #expect(message.contains("0.080 s"))
        #expect(message.contains("0.050 s minimum slice width"))
        #expect(!message.contains("sensitivity"))
        #expect(!message.contains("transient"))

        // POSITIVE CONTROL: a window only a little longer divides fine, so the
        // refusal is about the arithmetic and not about divisions mode itself.
        let ok = try AudioQuantizePlan.compute(
            clip: divClip(length: 0.6), transientsSourceSeconds: [], tempoMap: map120,
            settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 0, divisions: 2))
        #expect(ok.count == 2)
    }

    @Test("128 divisions of a 2 s window honestly returns fewer, never sub-floor slivers")
    func honestlyFewerBoundaries() throws {
        let clip = divClip()
        let slices = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: [], tempoMap: map120,
            settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 0, divisions: 128))
        // 2 s / 0.05 s floor = at most 40 slices, so 128 is not honoured…
        #expect(slices.count < 128)
        #expect(slices.count > 1)
        // …and every emitted slice is at least the floor wide in SOURCE seconds.
        for (i, slice) in slices.enumerated() {
            #expect(slice.lengthBeats * 0.5 >= 0.05 - 1e-9, "slice \(i) width")
        }
    }

    // MARK: - Orthogonality: divisions picks the CUT, the grid picks the MOVE

    @Test("divisions still nudges to the grid at strength 1 (grid params stay live)")
    func divisionsWithGridNudge() throws {
        // Clip starts at beat 0.3, so its equal divisions land OFF the grid and
        // a real nudge is observable.
        let clip = divClip(startBeat: 0.3)
        let chopOnly = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: [], tempoMap: map120,
            settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 0, divisions: 4))
        let snapped = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: [], tempoMap: map120,
            settings: AudioQuantizeSettings(gridBeats: 1.0, strength: 1, divisions: 4))
        #expect(chopOnly.count == 4)
        #expect(snapped.count == 4)
        // Chop-only: boundaries at 0.5/1.0/1.5 s → beats 1.3/2.3/3.3.
        #expect(approx(chopOnly[1].startBeat, 1.3))
        #expect(approx(chopOnly[2].startBeat, 2.3))
        #expect(approx(chopOnly[3].startBeat, 3.3))
        // Snapped: those onsets land on beats 1 / 2 / 3.
        //
        // ⚠️ Only the HEAD→s0 join carries a crossfade, and this asymmetry is
        // the algorithm, not an accident. Left-extension room is
        // `natural − base`: the head spans 1.0 beats of source but only 0.7 of
        // timeline (0.3 → 1), so it was COMPRESSED and has 0.6 beats of room —
        // s0 is pulled back the crossfade half to 0.99. Every later pair moves
        // by a uniform 1.3 → 1.0 beat shift, so spacing == natural, room is 0,
        // and the join self-clamps to a CLEAN CUT at exactly 2 and 3.
        #expect(approx(snapped[1].startBeat, 1 - 0.01))
        #expect(approx(snapped[1].fadeInBeats, 0.02))
        #expect(approx(snapped[2].startBeat, 2))
        #expect(snapped[2].fadeInBeats == 0)
        #expect(approx(snapped[3].startBeat, 3))
        #expect(snapped[3].fadeInBeats == 0)
    }

    @Test("strength 0 chops identically at every grid — the grid is irrelevant there")
    func gridIrrelevantAtStrengthZero() throws {
        let clip = divClip()
        func offsets(gridBeats: Double, strength: Double) throws -> [Double] {
            try AudioQuantizePlan.compute(
                clip: clip, transientsSourceSeconds: [], tempoMap: map120,
                settings: AudioQuantizeSettings(gridBeats: gridBeats, strength: strength,
                                                divisions: 6))
                .map(\.startBeat)
        }
        let atOne = try offsets(gridBeats: 1.0, strength: 0)
        #expect(try offsets(gridBeats: 0.25, strength: 0) == atOne)
        #expect(try offsets(gridBeats: 3.0, strength: 0) == atOne)
        // POSITIVE CONTROL: the grid DOES matter above strength 0, so the
        // equality above is a fact about strength 0, not an inert comparison.
        #expect(try offsets(gridBeats: 1.0, strength: 1) != atOne)
    }
}
