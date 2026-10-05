import Foundation
import Testing
@testable import DAWCore

// Tune to Melody M1 — THE MATCHING ENGINE (`Sources/DAWCore/PitchMelodyTarget.swift`).
// Design `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §3.2, §3.3, §3.6;
// the D-rules are the source file's banner (D1–D13), each pinned here by name.
//
// Not `@MainActor`: the engine is pure DAWCore, and `MainActorOccupancySiteTests` counts
// suite-level `@MainActor` against a cap that is nearly used up.
//
// ═══ ON FIXTURES ═══
// Frames are DETECTED CONTOURS at the detector's 62.5 fps, never audio. Unless a test says
// otherwise they are UNQUANTISED (a constant pitch per frame), so a hand-derived number is
// exact to ~1e-12 c. Frame i starts at `Double(i) * (1 / 62.5)`, the splitter tests' rule.
// Where a test needs the REAL splitter it asserts the part shape first (`kinds`), so a
// fixture that stopped making the structure it was written for fails loudly instead of
// testing something else. Where a test pins one D-rule in isolation it builds the part from
// `voicedRuns` (an unsplit run), which the plan accepts like any part.
//
// ═══ ON PLANTS ═══ Pre-registered in the lane's PREREG.md: which tests each plant turns
// red, and which stay green.

enum MelodyFx {
    static let rate: Double = 62.5
    static let period: Double = 1 / 62.5
    typealias Note = PitchMelodyTarget.MelodyNote

    /// Frame i's start time.
    static func t(_ i: Int) -> Double { Double(i) * period }

    static func voiced(_ i: Int, midi: Double, level: Double = -18) -> ClipPitchFrame {
        ClipPitchFrame(timeSeconds: t(i), frequencyHz: PitchCorrectionMath.hz(fromMidi: midi),
                       confidence: 0.9 + 0.001 * Double(i % 7), levelDbfs: level, absence: nil)
    }

    static func unvoiced(_ i: Int, level: Double = -60) -> ClipPitchFrame {
        ClipPitchFrame(timeSeconds: t(i), frequencyHz: nil, confidence: 0.05,
                       levelDbfs: level, absence: .belowConfidence)
    }

    /// Frames `from ..< from + count` held at a constant fractional MIDI pitch.
    static func held(_ midi: Double, from: Int, count: Int) -> [ClipPitchFrame] {
        (from ..< from + count).map { voiced($0, midi: midi) }
    }

    /// Frames from explicit per-frame MIDI pitches, starting at frame `from`.
    static func line(_ midis: [Double], from: Int = 0) -> [ClipPitchFrame] {
        midis.enumerated().map { voiced(from + $0.offset, midi: $0.element) }
    }

    static func gap(from: Int, count: Int, level: Double = -60) -> [ClipPitchFrame] {
        (from ..< from + count).map { unvoiced($0, level: level) }
    }

    /// ONE unsplit run as a part (D-rule tests): exactly what the splitter emits for a run
    /// with nothing to split, built whatever the frames' shape.
    static func unsplit(_ frames: [ClipPitchFrame]) throws -> NotePart {
        let runs = PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: rate)
        try #require(runs.count == 1)
        return NotePart(unsplit: runs[0], runIndex: 0)
    }

    static func parts(_ frames: [ClipPitchFrame]) -> [NotePart] {
        PitchNoteSplitter.parts(in: frames, frameRateHz: rate)
    }

    /// "H40 T21 H32" for messages and shape asserts.
    static func kinds(_ parts: [NotePart]) -> String {
        parts.map { $0.kind == .held ? "H\($0.frameCount)" : "T\($0.frameCount)" }
            .joined(separator: " ")
    }

    /// A melody note between two frame starts.
    static func note(_ startFrame: Int, _ endFrame: Int, _ midi: Int) -> Note {
        Note(startSeconds: t(startFrame), endSeconds: t(endFrame), midi: midi)
    }

    static func plan(_ parts: [NotePart], _ frames: [ClipPitchFrame], _ melody: [Note],
                     _ match: PitchMelodyTarget.OctaveMatch = .nearestOctave,
                     strength: Double = 1) -> PitchMelodyTarget.Plan {
        PitchMelodyTarget.plan(parts: parts, frames: frames, frameRateHz: rate, melody: melody,
                               octaveMatch: match, strength: strength)
    }

    /// THE PHYSICS: each voiced frame's pitch after the plan — its sung MIDI pitch plus the
    /// offset of the row that covers it (0 where none, or the row has no offset).
    static func tuned(_ frames: [ClipPitchFrame], _ plan: PitchMelodyTarget.Plan) -> [Double] {
        frames.compactMap { frame -> Double? in
            guard let hz = frame.frequencyHz else { return nil }
            let row = plan.pieces.first { frame.timeSeconds >= $0.startSeconds && frame.timeSeconds < $0.endSeconds }
            return PitchCorrectionMath.midi(fromHz: hz) + (row?.offsetCents ?? 0) / 100
        }
    }

    static func offsets(_ plan: PitchMelodyTarget.Plan) -> [Double?] { plan.pieces.map(\.offsetCents) }
}

private func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

@Suite("Tune to Melody M1: the matching engine (PitchMelodyTarget)")
struct PitchMelodyTargetTests {

    // MARK: Physics (design §3.6), the real splitter end to end

    /// A voice 40 c flat of a three-note melody, sung 3 frames (48 ms) late.
    /// By hand: each note is sung at (written − 0.40) MIDI, so the row's offset is
    /// (written − (written − 0.40)) × 100 = +40 c, and every frame lands ON its note:
    /// 59.6 + 0.4 = 60, 61.6 + 0.4 = 62, 63.6 + 0.4 = 64. Lateness changes nothing (§3.3 row 3):
    /// each part still overlaps its own note almost wholly and the next one not at all.
    @Test("physics: a voice 40 c flat of three notes lands on each, sung late")
    func fortyCentsFlatLandsOnEachNote() {
        let frames = MelodyFx.gap(from: 0, count: 10) + MelodyFx.held(59.6, from: 10, count: 40)
            + MelodyFx.gap(from: 50, count: 6) + MelodyFx.held(61.6, from: 56, count: 40)
            + MelodyFx.gap(from: 96, count: 6) + MelodyFx.held(63.6, from: 102, count: 40)
        let parts = MelodyFx.parts(frames)
        #expect(MelodyFx.kinds(parts) == "H40 H40 H40")
        let melody = [MelodyFx.note(7, 53, 60), MelodyFx.note(53, 99, 62), MelodyFx.note(99, 145, 64)]
        for match in PitchMelodyTarget.OctaveMatch.allCases {
            let plan = MelodyFx.plan(parts, frames, melody, match)
            #expect(plan.pieces.map(\.targetMidi) == [60, 62, 64], "\(match)")
            #expect(plan.pieces.map(\.melodyIndex) == [0, 1, 2], "\(match)")
            #expect(MelodyFx.offsets(plan).allSatisfy { near($0, 40) }, "\(match): \(MelodyFx.offsets(plan))")
            #expect(plan.cutsAdded.isEmpty && plan.unmatchedParts.isEmpty && plan.unsungNotes.isEmpty
                    && plan.outvotedNotes.isEmpty && plan.octaveFolded.isEmpty && plan.farMoves.isEmpty)
            let tuned = MelodyFx.tuned(frames, plan)
            let expected = Array(repeating: 60.0, count: 40) + Array(repeating: 62.0, count: 40)
                + Array(repeating: 64.0, count: 40)
            #expect(tuned.count == expected.count)
            #expect(zip(tuned, expected).allSatisfy { abs($0 - $1) < 1e-9 }, "\(match)")
        }
    }

    /// One held part with a sung STEP the splitter keeps whole (80 c, under τ_short), and a
    /// melody that changes 5 frames AFTER the singer did.
    /// By hand (D5–D7): frames 0–29 sing 59.6, frames 30–44 sing 60.4, one run of 45 → "H45".
    /// Melody A = 59 on [f0, f35), B = 61 on [f35, f60). Boundary b = t35 → j = 35 (frames
    /// 0–34 have their midpoint before t35); 35 > 8 and 45 − 35 = 10 > 8, so it may cut.
    /// Provisional targets: under A, frames 0–34 (30 × 59.6, 5 × 60.4) → median 59.6 → 59;
    /// under B, frames 35–44 → 60.4 → 61. m = 60. Window [max(27, 4), min(43, 41)] = [27, 41].
    /// The de-glitched f0 steps 59.6 → 60.4 at frame 30, so the cut is AT 30 (a crossing),
    /// not at 35. Pieces: [0, 30) median 59.6 → 59, offset −60 c; [30, 45) median 60.4 → 61,
    /// offset +60 c. Every frame then lands on a melody pitch: 59.6 − 0.6 = 59 for frames
    /// 0–29 and 60.4 + 0.6 = 61 for frames 30–44. Cut at the melody boundary instead, frames
    /// 30–34 would get −60 c and land on 59.8: 80 c sharp of A and 120 c flat of B.
    @Test("physics: a sung step inside one part moves the melody's cut onto the step")
    func stepInsideOnePartCutsAtTheCrossing() {
        let frames = MelodyFx.held(59.6, from: 0, count: 30) + MelodyFx.held(60.4, from: 30, count: 15)
        let parts = MelodyFx.parts(frames)
        #expect(MelodyFx.kinds(parts) == "H45")
        let plan = MelodyFx.plan(parts, frames, [MelodyFx.note(0, 35, 59), MelodyFx.note(35, 60, 61)])
        #expect(plan.cutsAdded == [PitchMelodyTarget.Cut(partIndex: 0, seconds: MelodyFx.t(30),
                                                          melodyBoundarySeconds: MelodyFx.t(35),
                                                          placement: .crossing)])
        #expect(plan.pieces.map(\.frameCount) == [30, 15])
        #expect(plan.pieces.map(\.targetMidi) == [59, 61])
        #expect(near(plan.pieces.first?.offsetCents, -60) && near(plan.pieces.last?.offsetCents, 60),
                "\(MelodyFx.offsets(plan))")
        let tuned = MelodyFx.tuned(frames, plan)
        let expected = Array(repeating: 59.0, count: 30) + Array(repeating: 61.0, count: 15)
        #expect(tuned.count == 45)
        #expect(zip(tuned, expected).allSatisfy { abs($0 - $1) < 1e-9 }, "\(tuned)")
    }

    /// One flat held part across two melody notes: no crossing, so the cut is the melody's.
    /// By hand: 60 frames at 59.6 → "H60". A = 60 on [f0, f30), B = 62 on [f30, f60): j = 30,
    /// targets 60 and 62 (62 is 2.4 above 59.6, 50 is 9.6 below), m = 61, f0 never reaches it
    /// → cut at frame 30, `.melodyBoundary`. Offsets +40 c and +240 c; frames land on 60 and 62.
    @Test("physics: a note held across two melody notes is cut at the melody's boundary")
    func heldAcrossTwoNotesCutsAtTheBoundary() {
        let frames = MelodyFx.held(59.6, from: 0, count: 60)
        let parts = MelodyFx.parts(frames)
        #expect(MelodyFx.kinds(parts) == "H60")
        let plan = MelodyFx.plan(parts, frames, [MelodyFx.note(0, 30, 60), MelodyFx.note(30, 60, 62)])
        #expect(plan.cutsAdded.map(\.placement) == [.melodyBoundary])
        #expect(plan.cutsAdded.first?.seconds == MelodyFx.t(30))
        #expect(plan.pieces.map(\.targetMidi) == [60, 62])
        #expect(near(plan.pieces.first?.offsetCents, 40) && near(plan.pieces.last?.offsetCents, 240))
        #expect(plan.farMoves.isEmpty)
        let tuned = MelodyFx.tuned(frames, plan)
        let expected = Array(repeating: 60.0, count: 30) + Array(repeating: 62.0, count: 30)
        #expect(zip(tuned, expected).allSatisfy { abs($0 - $1) < 1e-9 })
        // The two sides share the boundary bit for bit (the splitter's convention).
        #expect(plan.pieces[0].endSeconds.bitPattern == plan.pieces[1].startSeconds.bitPattern)
    }

    // MARK: Rule 2: the S-frame guard (D6)

    /// 30 frames at 60. A boundary exactly S = 8 frames from an edge is NOT "more than S"
    /// (no cut; the larger side wins by majority), 9 frames is (a cut). Both edges.
    @Test("rule 2: a melody boundary must be MORE than S frames from both part edges")
    func sGuardNeedsMoreThanSFrames() throws {
        let frames = MelodyFx.held(60, from: 0, count: 30)
        let part = try MelodyFx.unsplit(frames)
        // 8 frames after the start: no cut; B (22 frames) wins, A is outvoted.
        let start8 = MelodyFx.plan([part], frames, [MelodyFx.note(0, 8, 60), MelodyFx.note(8, 30, 64)])
        #expect(start8.cutsAdded.isEmpty)
        #expect(start8.pieces.map(\.melodyIndex) == [1])
        #expect(start8.outvotedNotes == [0])
        // 8 frames before the end: no cut; A (22 frames) wins.
        let end8 = MelodyFx.plan([part], frames, [MelodyFx.note(0, 22, 60), MelodyFx.note(22, 30, 64)])
        #expect(end8.cutsAdded.isEmpty)
        #expect(end8.pieces.map(\.melodyIndex) == [0])
        #expect(end8.outvotedNotes == [1])
    }

    @Test("rule 2: 9 frames from an edge is enough to cut (the S guard's control)")
    func sGuardControlNineFramesCuts() throws {
        let frames = MelodyFx.held(60, from: 0, count: 30)
        let part = try MelodyFx.unsplit(frames)
        let start9 = MelodyFx.plan([part], frames, [MelodyFx.note(0, 9, 60), MelodyFx.note(9, 30, 64)])
        #expect(start9.cutsAdded.map(\.seconds) == [MelodyFx.t(9)])
        #expect(start9.pieces.map(\.frameCount) == [9, 21])
        #expect(start9.pieces.map(\.targetMidi) == [60, 64])
        // +400 c: applied, and reported as far (§3.3 row 7).
        #expect(start9.farMoves.map(\.pieceIndex) == [1])
        let end9 = MelodyFx.plan([part], frames, [MelodyFx.note(0, 21, 60), MelodyFx.note(21, 30, 64)])
        #expect(end9.cutsAdded.map(\.seconds) == [MelodyFx.t(21)])
        #expect(end9.pieces.map(\.frameCount) == [21, 9])
    }

    // MARK: Rule 2: the midpoint search (D7)

    /// Per-frame f0: 60 for frames 0–19, 62 for 20–23, 60 for 24–27, 62 for 28–47 (one run,
    /// built unsplit: this pins D7 alone). By hand, the de-glitched track (width 5) keeps
    /// every 4-frame feature, so x rises through m = 61 at k = 20 and at k = 28 (and falls at
    /// 24, the wrong direction). Boundary at t27 → j = 27: 28 is nearer (1 vs 7) → cut at 28.
    /// Boundary at t24 → j = 24: 20 and 28 are both 4 away → the earlier, 20.
    @Test("rule 2: of several crossings the one nearest the boundary wins, a tie the earlier")
    func nearestCrossingWins() throws {
        let midis = Array(repeating: 60.0, count: 20) + Array(repeating: 62.0, count: 4)
            + Array(repeating: 60.0, count: 4) + Array(repeating: 62.0, count: 20)
        let frames = MelodyFx.line(midis)
        let part = try MelodyFx.unsplit(frames)
        let at27 = MelodyFx.plan([part], frames, [MelodyFx.note(0, 27, 60), MelodyFx.note(27, 48, 62)])
        #expect(at27.cutsAdded == [PitchMelodyTarget.Cut(partIndex: 0, seconds: MelodyFx.t(28),
                                                          melodyBoundarySeconds: MelodyFx.t(27),
                                                          placement: .crossing)])
        let at24 = MelodyFx.plan([part], frames, [MelodyFx.note(0, 24, 60), MelodyFx.note(24, 48, 62)])
        #expect(at24.cutsAdded.map(\.seconds) == [MelodyFx.t(20)])
        #expect(at24.cutsAdded.map(\.placement) == [.crossing])
    }

    /// The singer moved MORE than S frames before the melody did: frames 0–9 at 60, 10–39 at
    /// 62. Melody A = 60 on [f0, f25), B = 62 after: j = 25, window [17, 33]. x is already 62
    /// at frame 16, so nothing in the window crosses m = 61 → the melody's own boundary, 25.
    /// (The design's rule, pinned as written: a move that early is not followed.)
    @Test("rule 2: an f0 already past the midpoint when the window opens is no crossing")
    func pastTheMidpointIsNoCrossing() throws {
        let frames = MelodyFx.held(60, from: 0, count: 10) + MelodyFx.held(62, from: 10, count: 30)
        let part = try MelodyFx.unsplit(frames)
        let plan = MelodyFx.plan([part], frames, [MelodyFx.note(0, 25, 60), MelodyFx.note(25, 40, 62)])
        #expect(plan.cutsAdded == [PitchMelodyTarget.Cut(partIndex: 0, seconds: MelodyFx.t(25),
                                                          melodyBoundarySeconds: MelodyFx.t(25),
                                                          placement: .melodyBoundary)])
    }

    // MARK: Rule 3: the octave (D10, D11)

    /// By hand: a part at 48 (C3) and a written E5 (76): its pitch class E sits at 40, 52,
    /// 64…; 52 is 4 above 48 → 52, two octaves down, +400 c. `exact` keeps 76: +2800 c asked,
    /// stored as +2400 c (`NoteSegment.pitchOffsetCentsRange`).
    /// A part at 72 (C5) and a written E3 (52) folds UP to 76: +400 c, two octaves up.
    @Test("rule 3: nearestOctave folds down and up; exact keeps the written note")
    func octaveFoldsBothWays() throws {
        let low = MelodyFx.held(48, from: 0, count: 40)
        let lowPart = try MelodyFx.unsplit(low)
        let folded = MelodyFx.plan([lowPart], low, [MelodyFx.note(0, 40, 76)])
        #expect(folded.pieces.first?.targetMidi == 52)
        #expect(folded.octaveFolded == [PitchMelodyTarget.OctaveFold(pieceIndex: 0, octaves: -2)])
        #expect(near(folded.pieces.first?.offsetCents, 400))
        #expect(folded.farMoves.map(\.pieceIndex) == [0])
        let exact = MelodyFx.plan([lowPart], low, [MelodyFx.note(0, 40, 76)], .exact)
        #expect(exact.pieces.first?.targetMidi == 76)
        #expect(exact.octaveFolded.isEmpty)
        // +2800 c asked; clamped where every stored offset is (±2400 c), and reported as applied.
        #expect(near(exact.farMoves.first?.cents, 2400))
        let high = MelodyFx.held(72, from: 0, count: 40)
        let up = MelodyFx.plan([try MelodyFx.unsplit(high)], high, [MelodyFx.note(0, 40, 52)])
        #expect(up.pieces.first?.targetMidi == 76)
        #expect(up.octaveFolded == [PitchMelodyTarget.OctaveFold(pieceIndex: 0, octaves: 2)])
    }

    /// By hand: a part at exactly 54 (F#3) and a written C4: C3 = 48 and C4 = 60 are both
    /// 6 semitones away → the LOWER, 48: −600 c, one octave down (D11).
    @Test("rule 3: a 6-semitone tie folds LOWER")
    func sixSemitoneTieFoldsLower() throws {
        let frames = MelodyFx.held(54, from: 0, count: 40)
        let plan = MelodyFx.plan([try MelodyFx.unsplit(frames)], frames, [MelodyFx.note(0, 40, 60)])
        #expect(plan.pieces.first?.targetMidi == 48)
        #expect(plan.octaveFolded.map(\.octaves) == [-1])
        #expect(near(plan.pieces.first?.offsetCents, -600))
    }

    /// The tie's controls: 5 c either side of the tie is no tie. 54.05 → 60 (5.95 up beats
    /// 6.05 down); 53.95 → 48 (5.95 down beats 6.05 up).
    @Test("rule 3: 5 cents off the tie folds to the truly nearer octave")
    func offTheTieFoldsToTheNearer() throws {
        let above = MelodyFx.held(54.05, from: 0, count: 40)
        #expect(MelodyFx.plan([try MelodyFx.unsplit(above)], above, [MelodyFx.note(0, 40, 60)]).pieces.first?.targetMidi == 60)
        let below = MelodyFx.held(53.95, from: 0, count: 40)
        #expect(MelodyFx.plan([try MelodyFx.unsplit(below)], below, [MelodyFx.note(0, 40, 60)]).pieces.first?.targetMidi == 48)
    }

    /// D4: C4 then C5 over one part at 48 fold to ONE target under nearestOctave, so no cut;
    /// the halves tie (30 frames each) and the earlier note takes the part (D2), the other is
    /// outvoted. Under `exact`, 60 and 72 differ: a cut at frame 30, +1200 c and +2400 c.
    @Test("D4: notes an octave apart are one target under nearestOctave and never cut")
    func octaveApartIsNotCutUnderNearestOctave() throws {
        let frames = MelodyFx.held(48, from: 0, count: 60)
        let part = try MelodyFx.unsplit(frames)
        let melody = [MelodyFx.note(0, 30, 60), MelodyFx.note(30, 60, 72)]
        let nearest = MelodyFx.plan([part], frames, melody)
        #expect(nearest.cutsAdded.isEmpty)
        #expect(nearest.pieces.map(\.melodyIndex) == [0])
        #expect(nearest.pieces.map(\.targetMidi) == [48])
        #expect(nearest.outvotedNotes == [1])
        let exact = MelodyFx.plan([part], frames, melody, .exact)
        #expect(exact.cutsAdded.map(\.seconds) == [MelodyFx.t(30)])
        #expect(exact.pieces.map(\.targetMidi) == [60, 72])
        #expect(exact.farMoves.count == 2)
        #expect(exact.notesUsed == [0, 1])
    }

    // MARK: Rule 1: the majority (D1, D2, D13)

    /// No frames, so no cut can be made (D13) and rule 1 decides alone. A part [0, 1) s,
    /// listed melody [B, A] so the earlier START (A, index 1) is not the lower index.
    /// Overlaps 0.5 / 0.5 → tie → A. 0.497 / 0.503 differ by 6 ms, inside half a frame
    /// (8 ms) → still a tie → A. 0.49 / 0.51 differ by 20 ms → B, the larger.
    @Test("rule 1: the larger overlap wins; within half a frame the earlier note wins")
    func majorityAndItsTie() {
        let part = NotePart(kind: .held, startSeconds: 0, endSeconds: 1, centreHz: 261.6255653005986,
                            medianConfidence: 0.9, frameCount: 62, runIndex: 0, runCentreHz: 261.6255653005986)
        func winner(_ boundary: Double) -> PitchMelodyTarget.Plan {
            let b = MelodyFx.Note(startSeconds: boundary, endSeconds: 1.5, midi: 62)
            let a = MelodyFx.Note(startSeconds: -0.5, endSeconds: boundary, midi: 60)
            return MelodyFx.plan([part], [], [b, a])
        }
        let tie = winner(0.5)
        #expect(tie.pieces.map(\.melodyIndex) == [1])
        #expect(tie.partsWithoutFrames == [0])
        #expect(tie.cutsAdded.isEmpty)
        #expect(winner(0.503).pieces.map(\.melodyIndex) == [1])
        #expect(winner(0.49).pieces.map(\.melodyIndex) == [0])
    }

    /// D1: a part [1, 2) s and one note ending just past its start. 1e-12 s (the store's
    /// float noise at an abutment) and 7 ms do not count: the part is unmatched and the note
    /// unsung. 9 ms counts, and a counted overlap is a match (rule 1 has no other minimum).
    @Test("rule 1: an overlap of half a frame or less does not count")
    func overlapFloor() {
        let part = NotePart(kind: .held, startSeconds: 1, endSeconds: 2, centreHz: 261.6255653005986,
                            medianConfidence: 0.9, frameCount: 62, runIndex: 0, runCentreHz: 261.6255653005986)
        for tail in [1e-12, 0.007] {
            let plan = MelodyFx.plan([part], [], [MelodyFx.Note(startSeconds: 0, endSeconds: 1 + tail, midi: 60)])
            #expect(plan.unmatchedParts == [0], "tail \(tail)")
            #expect(plan.unsungNotes == [0], "tail \(tail)")
            #expect(plan.pieces.first?.offsetCents == nil)
        }
        let counted = MelodyFx.plan([part], [], [MelodyFx.Note(startSeconds: 0, endSeconds: 1.009, midi: 62)])
        #expect(counted.pieces.map(\.melodyIndex) == [0])
        #expect(counted.unmatchedParts.isEmpty)
    }

    // MARK: Chords and legato (D3)

    private typealias Fragment = PitchMelodyTarget.Fragment

    private func line(_ notes: [PitchMelodyTarget.MelodyNote]) -> PitchMelodyTarget.Line {
        PitchMelodyTarget.line(notes, valid: Array(notes.indices))
    }

    /// A tail overlap under 60 ms: the earlier note ends where the later starts, whichever is
    /// higher, and nothing is "reduced". 50 ms here.
    @Test("D3: a tail overlap under 60 ms is legato, not a chord")
    func legatoTail() {
        let rising = line([.init(startSeconds: 0, endSeconds: 0.55, midi: 60),
                           .init(startSeconds: 0.5, endSeconds: 1, midi: 64)])
        #expect(rising.fragments == [Fragment(start: 0, end: 0.5, midi: 60, source: 0),
                                     Fragment(start: 0.5, end: 1, midi: 64, source: 1)])
        #expect(rising.reduced.isEmpty)
        let falling = line([.init(startSeconds: 0, endSeconds: 0.55, midi: 64),
                            .init(startSeconds: 0.5, endSeconds: 1, midi: 60)])
        #expect(falling.fragments == [Fragment(start: 0, end: 0.5, midi: 64, source: 0),
                                      Fragment(start: 0.5, end: 1, midi: 60, source: 1)])
        #expect(falling.reduced.isEmpty)
    }

    /// A tail overlap of 70 ms is a chord: the higher note sounds through the overlap and
    /// the lower is reduced, whichever came first.
    @Test("D3: a 70 ms overlap is a chord, and the higher note takes it")
    func chordOverlapTakesTheHigher() {
        let upperFirst = line([.init(startSeconds: 0, endSeconds: 0.57, midi: 64),
                               .init(startSeconds: 0.5, endSeconds: 1, midi: 60)])
        #expect(upperFirst.fragments == [Fragment(start: 0, end: 0.57, midi: 64, source: 0),
                                         Fragment(start: 0.57, end: 1, midi: 60, source: 1)])
        #expect(upperFirst.reduced == [1])
        let lowerFirst = line([.init(startSeconds: 0, endSeconds: 0.57, midi: 60),
                               .init(startSeconds: 0.5, endSeconds: 1, midi: 64)])
        #expect(lowerFirst.fragments == [Fragment(start: 0, end: 0.5, midi: 60, source: 0),
                                         Fragment(start: 0.5, end: 1, midi: 64, source: 1)])
        #expect(lowerFirst.reduced == [0])
    }

    /// A triad is its top note. A 40 ms grace note INSIDE a long note is not legato (that
    /// would end the long note at it): above, it takes its 40 ms; below, it never sounds.
    @Test("D3: a triad is its top note; a note inside another is never legato")
    func triadAndContainment() {
        let triad = line([.init(startSeconds: 0, endSeconds: 1, midi: 60),
                          .init(startSeconds: 0, endSeconds: 1, midi: 64),
                          .init(startSeconds: 0, endSeconds: 1, midi: 67)])
        #expect(triad.fragments == [Fragment(start: 0, end: 1, midi: 67, source: 2)])
        #expect(triad.reduced == [0, 1])
        let graceAbove = line([.init(startSeconds: 0, endSeconds: 2, midi: 60),
                               .init(startSeconds: 0.5, endSeconds: 0.54, midi: 72)])
        #expect(graceAbove.fragments == [Fragment(start: 0, end: 0.5, midi: 60, source: 0),
                                         Fragment(start: 0.5, end: 0.54, midi: 72, source: 1),
                                         Fragment(start: 0.54, end: 2, midi: 60, source: 0)])
        #expect(graceAbove.reduced == [0])
        let graceBelow = line([.init(startSeconds: 0, endSeconds: 2, midi: 72),
                               .init(startSeconds: 0.5, endSeconds: 0.54, midi: 60)])
        #expect(graceBelow.fragments == [Fragment(start: 0, end: 2, midi: 72, source: 0)])
        #expect(graceBelow.reduced == [1])
    }

    /// Two copies of one pitch are not a chord: the earlier keeps the line, nothing reduced.
    @Test("D3: a doubled note is not a chord")
    func unisonIsNotAChord() {
        let doubled = line([.init(startSeconds: 0, endSeconds: 1, midi: 60),
                            .init(startSeconds: 0, endSeconds: 1, midi: 60)])
        #expect(doubled.fragments == [Fragment(start: 0, end: 1, midi: 60, source: 0)])
        #expect(doubled.reduced.isEmpty)
    }

    /// End to end: a part at 66.8 under C-E-G takes G (67): +20 c. C and E are reduced and
    /// outvoted. (Under a lowest-note rule it would take C, folded to 72: +520 c.)
    @Test("§3.3 row 5: a chord in the melody tunes the voice to its top note")
    func chordTunesToTheTopNote() throws {
        let frames = MelodyFx.held(66.8, from: 0, count: 40)
        let plan = MelodyFx.plan([try MelodyFx.unsplit(frames)], frames,
                           [MelodyFx.note(0, 40, 60), MelodyFx.note(0, 40, 64), MelodyFx.note(0, 40, 67)])
        #expect(plan.pieces.map(\.targetMidi) == [67])
        #expect(near(plan.pieces.first?.offsetCents, 20))
        #expect(plan.chordsReduced == [0, 1])
        #expect(plan.outvotedNotes == [0, 1])
        #expect(plan.notesUsed == [2])
    }

    // MARK: F-fast, rests, slides

    /// F-fast: a 40 ms note on top of a long one inside a 60-frame part at 60 is too short to
    /// cut (D4); the long note keeps the part, the short one is outvoted, and the long one is
    /// reduced (it lost 40 ms to a higher note). Alone, the same short note still tunes a part
    /// (rule 1): a part at 60 over only a 40 ms D4 takes it, +200 c.
    @Test("F-fast: a melody note under 60 ms never cuts, but can still be matched alone")
    func fastNotes() throws {
        let frames = MelodyFx.held(60, from: 0, count: 60)
        let part = try MelodyFx.unsplit(frames)
        let long = MelodyFx.note(0, 60, 60)
        let grace = MelodyFx.Note(startSeconds: MelodyFx.t(30), endSeconds: MelodyFx.t(30) + 0.04, midi: 64)
        let plan = MelodyFx.plan([part], frames, [long, grace])
        #expect(plan.cutsAdded.isEmpty)
        #expect(plan.pieces.map(\.melodyIndex) == [0])
        #expect(plan.outvotedNotes == [1])
        #expect(plan.chordsReduced == [0])
        let alone = MelodyFx.plan([part], frames,
                            [MelodyFx.Note(startSeconds: MelodyFx.t(10), endSeconds: MelodyFx.t(10) + 0.04, midi: 62)])
        #expect(alone.pieces.map(\.targetMidi) == [62])
        #expect(near(alone.pieces.first?.offsetCents, 200))
    }

    /// Two runs ("H40 H40") and a melody: A under the first; N in the silence between the
    /// runs (unsung: nobody sang there); nothing under the second (unmatched: as sung, no
    /// offset).
    @Test("§3.3 rows 1–2: a rest leaves a part unmatched, a note in silence is unsung")
    func restsAndUnsungNotes() {
        let frames = MelodyFx.held(60, from: 0, count: 40) + MelodyFx.gap(from: 40, count: 20)
            + MelodyFx.held(62, from: 60, count: 40)
        let parts = MelodyFx.parts(frames)
        #expect(MelodyFx.kinds(parts) == "H40 H40")
        let plan = MelodyFx.plan(parts, frames, [MelodyFx.note(0, 40, 60), MelodyFx.note(45, 55, 65)])
        #expect(plan.pieces.map(\.role) == [.matched, .unmatched])
        #expect(plan.unmatchedParts == [1])
        #expect(plan.unsungNotes == [1])
        #expect(plan.outvotedNotes.isEmpty)
        #expect(plan.notesUsed == [0])
        #expect(plan.pieces[1].offsetCents == nil && plan.pieces[1].targetMidi == nil)
        #expect(plan.pieces[1].centreHz.bitPattern == parts[1].centreHz.bitPattern)
    }

    /// A slide between two held notes is a `.transition` part ("H32 T21 H32" by hand: the
    /// first plateau absorbs the glide's first two frames, +19 c and +38 c, inside the 52 c
    /// band, and the second its last two). It is passed through untouched: no note, no
    /// offset, its own numbers.
    @Test("a slide is passed through: the melody never targets a transition")
    func transitionsPassThrough() {
        let glide = (30 ..< 55).map { 57 + 5 * Double($0 - 29) / 26 }
        let frames = MelodyFx.held(57, from: 0, count: 30) + MelodyFx.line(glide, from: 30)
            + MelodyFx.held(62, from: 55, count: 30)
        let parts = MelodyFx.parts(frames)
        #expect(MelodyFx.kinds(parts) == "H32 T21 H32")
        #expect(parts.map(\.kind) == [.held, .transition, .held])
        let plan = MelodyFx.plan(parts, frames, [MelodyFx.note(0, 42, 57), MelodyFx.note(42, 85, 62)])
        #expect(plan.pieces.map(\.role) == [.matched, .transition, .matched])
        #expect(plan.pieces.map(\.targetMidi) == [57, nil, 62])
        if parts.count == 3, plan.pieces.count == 3 {
            let slide = plan.pieces[1]
            #expect(slide.offsetCents == nil && slide.melodyIndex == nil)
            #expect(slide.startSeconds.bitPattern == parts[1].startSeconds.bitPattern
                    && slide.endSeconds.bitPattern == parts[1].endSeconds.bitPattern
                    && slide.centreHz.bitPattern == parts[1].centreHz.bitPattern)
        }
        #expect(plan.cutsAdded.isEmpty)
    }

    // MARK: Guards

    /// Bad input is named, never a NaN: invalid notes are listed and take part in nothing;
    /// a non-finite strength heals to 0 (offsets exactly 0); a rate that is not a number
    /// makes no cut.
    @Test("guards: invalid notes, a NaN strength and a bad rate")
    func guards() throws {
        let frames = MelodyFx.held(59.6, from: 0, count: 60)
        let parts = MelodyFx.parts(frames)
        let melody = [MelodyFx.Note(startSeconds: .nan, endSeconds: 1, midi: 60),
                      MelodyFx.note(0, 30, 60),
                      MelodyFx.Note(startSeconds: 0.5, endSeconds: 0.5, midi: 60),
                      MelodyFx.Note(startSeconds: 0, endSeconds: .infinity, midi: 60),
                      MelodyFx.Note(startSeconds: 0, endSeconds: 1, midi: 128),
                      MelodyFx.note(30, 60, 62),
                      MelodyFx.Note(startSeconds: 0, endSeconds: 1, midi: -1)]
        let plan = MelodyFx.plan(parts, frames, melody)
        #expect(plan.invalidNotes == [0, 2, 3, 4, 6])
        #expect(plan.notesUsed == [1, 5])
        #expect(plan.cutsAdded.count == 1)
        let limp = MelodyFx.plan(parts, frames, melody, strength: .nan)
        #expect(limp.strength == 0)
        #expect(limp.pieces.allSatisfy { $0.offsetCents == 0 })
        let noRate = PitchMelodyTarget.plan(parts: parts, frames: frames, frameRateHz: .nan,
                                            melody: melody)
        #expect(noRate.cutsAdded.isEmpty)
        #expect(noRate.pieces.allSatisfy { ($0.offsetCents ?? 0).isFinite })
        let empty = MelodyFx.plan([], [], [])
        #expect(empty.pieces.isEmpty && empty.unsungNotes.isEmpty)
    }

    /// Strength scales the move and what counts as far: 400 c at strength 0.5 is 200 c.
    @Test("strength scales the offset, and far is judged on the applied move")
    func strengthScalesTheMove() throws {
        let frames = MelodyFx.held(60, from: 0, count: 40)
        let part = try MelodyFx.unsplit(frames)
        let half = MelodyFx.plan([part], frames, [MelodyFx.note(0, 40, 64)], strength: 0.5)
        #expect(near(half.pieces.first?.offsetCents, 200))
        #expect(half.farMoves.isEmpty)
        let full = MelodyFx.plan([part], frames, [MelodyFx.note(0, 40, 64)])
        #expect(near(full.farMoves.first?.cents, 400))
        // 290 c is not far, 310 c is.
        let f290 = MelodyFx.held(59.1, from: 0, count: 40)
        #expect(MelodyFx.plan([try MelodyFx.unsplit(f290)], f290, [MelodyFx.note(0, 40, 62)]).farMoves.isEmpty)
        let f310 = MelodyFx.held(58.9, from: 0, count: 40)
        #expect(MelodyFx.plan([try MelodyFx.unsplit(f310)], f310, [MelodyFx.note(0, 40, 62)]).farMoves.count == 1)
    }
}
