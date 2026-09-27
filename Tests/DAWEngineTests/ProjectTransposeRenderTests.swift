import DAWAppKit
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// p2-sing-k (lane W7-PK): design §3.6 said a tuned vocal's correction TONIC
/// must move with `project.transpose` "so a corrected vocal keeps snapping to
/// the new key". The render order says the opposite, and this suite proves it
/// by TRACKED PITCH through the product render, never by bytes.
///
/// The order, read from source: `detectClipPitch` analyses the SOURCE FILE
/// (the clip's shift is only echoed), `PitchAutoCorrect` stores each note's
/// correction as cents from that source pitch, and the render plays
/// `clipPitchShiftSemitones + correction` (`PitchCorrectionCurve.semitones`,
/// fed `Params.semitones` by `StretchCurvePlan.make`). So the recording stays
/// in the OLD key, the stored correction snaps it onto the old key's scale,
/// and the shift alone moves the tuned result to the new key. Re-snapping with
/// a moved tonic would snap an old-key recording onto the new scale and then
/// shift it again.
///
/// The recording sings three notes deliberately off the C-major pitches it
/// aims at — A3 −35 c, B3 +30 c, D4 −40 c — and the REAL corrector runs on it.
/// Every pitch any leg can produce sits inside `M23QToneTracker`'s default
/// 150–400 Hz band.
///
/// Deliberately NOT `@MainActor`: the planner is pure and the render body is
/// the offline one (`StretchRenderCache.renderAudio`).
@Suite("p2-sing-k — a tuned vocal follows project.transpose by its shift alone, by tracked pitch")
struct ProjectTransposeRenderTests {
    static let sampleRate = 48_000.0
    static let frameRateHz = 62.5
    static let durationSeconds = 3.2

    /// (start, end) in source seconds, and the pitch actually SUNG, MIDI.
    static let sung: [(start: Double, end: Double, midi: Double)] = [
        (0.2, 1.0, 56.65), (1.2, 2.0, 59.3), (2.2, 3.0, 61.6),
    ]
    /// A played note is "the intended note" within this many cents.
    static let toleranceCents = 15.0

    static let eFlatMajor = PitchCorrectionScale(tonicPitchClass: 3, mode: .major)

    static func hz(midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
    static func midi(hz: Double) -> Double { 69 + 12 * log2(hz / 440) }

    /// The recording: a phase-continuous sine stepping between the sung
    /// pitches at the middle of each gap.
    static func source() -> [Float] {
        let frames = Int(durationSeconds * sampleRate)
        return M23QSignal.frequencyModulated(frames: frames, sampleRate: sampleRate) { n in
            let t = Double(n) / sampleRate
            return hz(midi: t < 1.1 ? sung[0].midi : (t < 2.1 ? sung[1].midi : sung[2].midi))
        }
    }

    /// What the detector reports for that recording at SwiftF0's rate: three
    /// voiced runs, with unvoiced holes between them.
    static func contour() -> [ClipPitchFrame] {
        let period = 1 / frameRateHz
        let count = Int((durationSeconds / period).rounded())
        return (0..<count).map { i in
            let t = Double(i) * period
            if let note = sung.first(where: { t >= $0.start && t < $0.end }) {
                return ClipPitchFrame(timeSeconds: t, frequencyHz: hz(midi: note.midi),
                                      confidence: 0.97, levelDbfs: -18, absence: nil)
            }
            return ClipPitchFrame(timeSeconds: t, frequencyHz: nil, confidence: 0.2,
                                  levelDbfs: -54, absence: .belowConfidence)
        }
    }

    /// THE REAL CORRECTOR (`PitchAutoCorrect`, the policy `clip.autoCorrectPitch`
    /// runs) on the SOURCE contour, at full strength, keeping the performance's
    /// shape (the preset ladder: constant per-note offsets, no contour needed at
    /// render). Fails loudly if the splitter stops seeing three notes.
    static func tuned(to scale: PitchCorrectionScale) throws -> PitchEditSet {
        let options = PitchAutoCorrectOptions(scale: scale, strength: 1, retuneMs: 30,
                                              preserveVibrato: true)
        let set = PitchAutoCorrect.editSet(contour: contour(), frameRateHz: frameRateHz,
                                           options: options)
        let notes = set.segments.filter { $0.origin != .unpitched }
        try #require(notes.count == 3)
        for (segment, note) in zip(notes, sung) {
            try #require(abs(midi(hz: segment.detectedHz) - note.midi) < 0.01)
        }
        return set
    }

    static func vocal(_ edits: PitchEditSet?, shift: Double = 0) -> Track {
        Track(name: "Lead vocal", kind: .audio, clips: [
            Clip(name: "Verse take", startBeat: 0, lengthBeats: 8,
                 audioFileURL: URL(fileURLWithPath: "/tmp/w7-pk-verse.wav"),
                 pitchShiftSemitones: shift, pitchEdits: edits),
        ])
    }

    /// THE PRODUCT: `StretchRenderCache.renderAudio` fed `Params(clip:)`, so
    /// what renders is exactly the clip the planner produced.
    static func render(_ clip: Clip, _ source: [Float]) throws -> [Float] {
        var whole = [source]
        let out = try StretchRenderCache.renderAudio(
            whole: &whole, window: nil, sampleRate: sampleRate,
            params: StretchRenderCache.Params(clip: clip), curveContour: nil,
            isCancelled: { false })
        return out.output.planar[0]
    }

    /// The sounding pitch of each held note, MIDI: the median tracked pitch
    /// over the middle half of the note, clear of the retune ramps.
    static func heldMidi(_ samples: [Float]) -> [Double] {
        let estimates = M23QToneTracker.track(samples, sampleRate: sampleRate)
        return sung.map { note in
            let quarter = (note.end - note.start) / 4
            let frames = ((note.start + quarter) * sampleRate)..<((note.end - quarter) * sampleRate)
            guard let hz = M23QToneTracker.medianHz(estimates, centreIn: frames) else { return .nan }
            return midi(hz: hz)
        }
    }

    static func cents(_ played: Double, from target: Double) -> Double { (played - target) * 100 }

    static func bitPatterns(_ samples: [Float]) -> [UInt32] { samples.map(\.bitPattern) }

    // MARK: - Controls on the instrument and on the render

    @Test("POSITIVE CONTROL: the tracker reads the recording as sung, and the recording IS off-key")
    func trackerReadsTheRecording() {
        let played = Self.heldMidi(Self.source())
        for (value, note) in zip(played, Self.sung) {
            #expect(abs(Self.cents(value, from: note.midi)) < 3, "read \(value) for \(note.midi)")
            // More than 25 cents from the nearest semitone: an in-tune reading
            // here would mean the legs below prove nothing.
            #expect(abs(Self.cents(value, from: value.rounded())) > 25)
        }
    }

    @Test("POSITIVE CONTROL: the corrector plus the render put the untransposed vocal on C major")
    func correctionLandsOnCMajor() throws {
        let track = Self.vocal(try Self.tuned(to: PitchCorrectionScale(tonicPitchClass: 0, mode: .major)))
        let played = Self.heldMidi(try Self.render(track.clips[0], Self.source()))
        for (value, intended) in zip(played, [57.0, 59, 62]) {
            #expect(abs(Self.cents(value, from: intended)) < Self.toleranceCents,
                    "played \(value), intended \(intended)")
        }
    }

    // MARK: - The claim

    @Test("A C-major-tuned vocal moved +3 plays every held note on E-flat major: the INTENDED notes, corrections untouched")
    func transposedTunedVocalLandsOnTheNewKey() throws {
        let cMajor = try Self.tuned(to: PitchCorrectionScale(tonicPitchClass: 0, mode: .major))
        let track = Self.vocal(cMajor)
        let plan = try ProjectTranspose.plan(tracks: [track], semitones: 3)
        let moved = plan.tracks[0].clips[0]
        // Each note's correction is unchanged: the shift alone moved.
        #expect(moved.pitchEdits == cMajor)
        #expect(moved.pitchShiftSemitones == 3)
        #expect(plan.report.tracks.first?.clips.first?.keepsTuning == true)

        let played = Self.heldMidi(try Self.render(moved, Self.source()))
        let intended: [Double] = [60, 62, 65]   // C4, D4, F4: the C-major notes + 3
        for (value, target) in zip(played, intended) {
            #expect(abs(Self.cents(value, from: target)) < Self.toleranceCents,
                    "played \(value), intended \(target)")
            let pitchClass = ((Int(value.rounded()) % 12) + 12) % 12
            #expect(Self.eFlatMajor.allowedPitchClasses.contains(pitchClass))
        }

        // CONTROL: the shift without the correction does NOT tune anything — the
        // sung offsets ride along (+3 on 56.65/59.3/61.6), so it is the stored
        // correction, carried by the shift, that lands the notes.
        var untuned = moved
        untuned.pitchEdits = nil
        let raw = Self.heldMidi(try Self.render(untuned, Self.source()))
        for (value, note) in zip(raw, Self.sung) {
            #expect(abs(Self.cents(value, from: note.midi + 3)) < 5)
        }
    }

    @Test("NEGATIVE CONTROL, the other choice: re-snapping to the moved tonic puts notes OFF E-flat major, or on the wrong note")
    func movingTheTonicPlaysWrongNotes() throws {
        let cMajor = try Self.tuned(to: PitchCorrectionScale(tonicPitchClass: 0, mode: .major))
        // "The tonic moves with the song": the corrector re-run with E-flat
        // major on the recording, which is still in the old key.
        let movedTonic = try Self.tuned(to: Self.eFlatMajor)
        #expect(movedTonic != cMajor)
        let clip = Self.vocal(movedTonic, shift: 3).clips[0]
        let played = Self.heldMidi(try Self.render(clip, Self.source()))
        // The arithmetic of that choice: A3−35c → A♭3 → B3; B3+30c → C4 → E♭4.
        #expect(abs(Self.cents(played[0], from: 59)) < Self.toleranceCents, "played \(played[0])")
        #expect(abs(Self.cents(played[1], from: 63)) < Self.toleranceCents, "played \(played[1])")
        // Note 1 is OFF the new key's scale.
        #expect(!Self.eFlatMajor.allowedPitchClasses.contains(((Int(played[0].rounded()) % 12) + 12) % 12))
        // Note 2 is ON the scale and still WRONG: a semitone from the intended
        // D4. "On the scale" alone would have passed it.
        #expect(Self.eFlatMajor.allowedPitchClasses.contains(((Int(played[1].rounded()) % 12) + 12) % 12))
        #expect(abs(Self.cents(played[1], from: 62)) > 90)
        #expect(abs(Self.cents(played[0], from: 60)) > 90)
    }

    @Test("A HAND-MOVED note follows the shift too: the editor stores its drag relative to the recording")
    func handMovedNoteFollowsTheShift() throws {
        var set = try Self.tuned(to: PitchCorrectionScale(tonicPitchClass: 0, mode: .major))
        let index = try #require(set.segments.firstIndex { abs($0.detectedHz - Self.hz(midi: 59.3)) < 0.01 })
        // The pitch editor's ONE conversion for a drag that lands on D4 (drawn
        // MIDI 62) on the untransposed clip: (drawn − clip shift − sung) × 100.
        set.segments[index].pitchOffsetCents = PitchEditorGeometry.storedOffsetCents(
            drawnMidi: 62, centreMidi: 59.3, clipPitchShiftSemitones: 0)
        #expect(abs(set.segments[index].pitchOffsetCents - 270) < 1e-9)
        let plan = try ProjectTranspose.plan(tracks: [Self.vocal(set)], semitones: 3)
        #expect(plan.tracks[0].clips[0].pitchEdits == set)
        let played = Self.heldMidi(try Self.render(plan.tracks[0].clips[0], Self.source()))
        // A3→C4 and D4→F4 as before; the dragged B3 now plays D4 + 3 = F4.
        for (value, intended) in zip(played, [60.0, 65, 65]) {
            #expect(abs(Self.cents(value, from: intended)) < Self.toleranceCents,
                    "played \(value), intended \(intended)")
        }
        // And the editor draws it where it plays: the same conversion forward.
        #expect(abs(PitchEditorGeometry.drawnMidi(
            centreMidi: 59.3, offsetCents: set.segments[index].pitchOffsetCents,
            clipPitchShiftSemitones: plan.tracks[0].clips[0].pitchShiftSemitones) - 65) < 1e-9)
    }

    // MARK: - Invariance

    @Test("0 semitones renders byte-identically; +3 renders different bytes (and, above, the right pitch)")
    func zeroIsByteIdentical() throws {
        let cMajor = try Self.tuned(to: PitchCorrectionScale(tonicPitchClass: 0, mode: .major))
        let track = Self.vocal(cMajor)
        let source = Self.source()
        let original = try Self.render(track.clips[0], source)

        let zero = try ProjectTranspose.plan(tracks: [track], semitones: 0)
        #expect(zero.tracks == [track])
        #expect(Self.bitPatterns(try Self.render(zero.tracks[0].clips[0], source))
                == Self.bitPatterns(original))

        let up = try ProjectTranspose.plan(tracks: [track], semitones: 3)
        #expect(Self.bitPatterns(try Self.render(up.tracks[0].clips[0], source))
                != Self.bitPatterns(original))
    }
}
