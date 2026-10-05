import Foundation
import Testing
@testable import DAWCore

/// m23-ap I7b-2 — **THE PLAYED LINE HAS ONE PRODUCER, AND IT LEAVES A HOLE
/// OVER A CLEARED NOTE.**
///
/// A cleared note plays silence (`PitchEditSet.gain(atSourceSecond:)` is 0
/// between its ramps), so the line the render plays has no pitch there. I7b
/// hid that stretch in the EDITOR (`PitchEditorModel`) while
/// `PitchPlayedLine.make` ignored the flag, so the wire verb
/// `clip.getPlayedPitch` still reported pitch over a note that plays nothing —
/// two producers that disagreed. `make` now cuts the hole itself, as a run
/// boundary (the representation an unvoiced gap already has), and every
/// reader takes its answer.
///
/// Every test pairs the cleared line with the SAME inputs uncleared: the
/// absence inside the cleared note is checked against a line that HAS points
/// there (positive control), and every other point is checked value for value
/// (the invariance control, which is what catches a cut in the wrong place).
///
/// Planted and seen red: `make` passing no `silenced` spans (the flag
/// ignored), in the tree for one command and reverted with `cmp` proof.
///
/// ⚠️ NOT `@MainActor`: pure DAWCore values, and `MainActorOccupancySiteTests`
/// bounds the isolated suites.
@Suite("The played line leaves a cleared note silent — one producer (m23-ap I7b-2)")
struct PitchPlayedLineClearedTests {

    // MARK: - The fixture

    static let rate = 62.5
    static let period = 1 / 62.5
    static let tempo = try! TempoMap(segments: [.init(startBeat: 0, bpm: 120)])

    /// Three voiced runs with a 5.5 Hz, ±40 c vibrato (so neighbouring points
    /// differ and "verbatim" means something), split by unvoiced holes. Frame
    /// indices at 62.5 fps:
    ///   A 0..<50 (220 Hz) · hole 50..<56 · B 56..<116 (246.94 Hz)
    ///   · hole 116..<126 · C 126..<186 (196 Hz) · tail 186..<196.
    static func frames(gridOffset: Double = 0) -> [ClipPitchFrame] {
        var out: [ClipPitchFrame] = []
        func voiced(_ range: Range<Int>, hz: Double) {
            for i in range {
                let t = Double(i) * period + gridOffset
                let cents = 40 * sin(2 * .pi * 5.5 * t)
                out.append(ClipPitchFrame(timeSeconds: t, frequencyHz: hz * pow(2, cents / 1200),
                                          confidence: 0.97, levelDbfs: -16, absence: nil))
            }
        }
        func unvoiced(_ range: Range<Int>) {
            for i in range {
                out.append(ClipPitchFrame(timeSeconds: Double(i) * period + gridOffset,
                                          frequencyHz: nil, confidence: 0.2, levelDbfs: -90,
                                          absence: .belowLevel))
            }
        }
        voiced(0..<50, hz: 220)
        unvoiced(50..<56)
        voiced(56..<116, hz: 246.94)
        unvoiced(116..<126)
        voiced(126..<186, hz: 196)
        unvoiced(186..<196)
        return out
    }

    static func result(_ frames: [ClipPitchFrame]) -> PitchDetectionResult {
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: frames.isEmpty ? 0 : Double(voiced) / Double(frames.count),
            frameRateHz: rate, analysisSampleRateHz: 16_000, sourceSampleRateHz: 48_000,
            windowStartSeconds: frames.first?.timeSeconds ?? 0,
            windowDurationSeconds: Double(frames.count) * period,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs,
            minFrequencyHz: 46, maxFrequencyHz: 2_093)
    }

    /// The render's whole-file contour (what THE seam answers).
    static let wholeFile = result(frames())
    static let window: Range<Double> = 0..<(196 * period)

    /// A note over frames `range`, cut at frame STARTS like the note builders.
    static func note(_ range: Range<Int>, hz: Double, cents: Double = 0,
                     cleared: Bool = false, id: UUID = UUID()) -> NoteSegment {
        NoteSegment(id: id, startSeconds: Double(range.lowerBound) * period,
                    endSeconds: Double(range.upperBound) * period,
                    detectedHz: hz, detectedConfidence: 0.97,
                    pitchOffsetCents: cents, isCleared: cleared)
    }

    static func line(_ segments: [NoteSegment],
                     contour: PitchRenderContour? = .detected(wholeFile),
                     fallback: PitchDetectionResult? = nil,
                     shift: Double = 0) -> PitchPlayedLine {
        PitchPlayedLine.make(contour: contour, fallback: fallback,
                             editSet: PitchEditSet(segments: segments),
                             clipPitchShiftSemitones: shift, sourceWindow: window)
    }

    /// The same table with the notes at `indices` cleared, ids kept.
    static func clearing(_ indices: Set<Int>, in segments: [NoteSegment]) -> [NoteSegment] {
        segments.enumerated().map { index, segment in
            var copy = segment
            if indices.contains(index) { copy.isCleared = true }
            return copy
        }
    }

    static func points(_ line: PitchPlayedLine, in segment: NoteSegment) -> [PitchPlayedLine.Point] {
        line.runs.joined().filter {
            $0.sourceSeconds >= segment.startSeconds && $0.sourceSeconds < segment.endSeconds
        }
    }

    /// Tuned so the curve is not flat: `playedMidi` carries real offsets, and
    /// "value for value" covers the curve's arithmetic, not just the sung line.
    static let threeNotes = [Self.note(0..<50, hz: 220, cents: 30),
                             note(56..<116, hz: 246.94, cents: -45),
                             note(126..<186, hz: 196, cents: 20)]

    // MARK: - The tests

    @Test("a cleared note between runs: no point inside it, and every other run is the uncleared line's, value for value")
    func clearedBetweenRuns() throws {
        let plain = Self.line(Self.threeNotes)
        let table = Self.clearing([1], in: Self.threeNotes)
        let cleared = Self.line(table)
        // POSITIVE CONTROL: the uncleared line has B's stretch — the absence
        // below is the clear talking, not a line that was never there.
        try #require(plain.runs.count == 3)
        #expect(Self.points(plain, in: table[1]).count == 60)
        // THE HOLE.
        #expect(Self.points(cleared, in: table[1]).isEmpty, "the line still has pitch over a cleared note")
        // THE INVARIANCE CONTROL: A and C, point for point.
        #expect(cleared.runs == [plain.runs[0], plain.runs[2]])
        // A clear is a LEVEL edit: the curve, the basis and the unresolved
        // list are the uncleared line's.
        #expect(cleared.curve == plain.curve)
        #expect(cleared.basis == plain.basis)
        #expect(cleared.unresolvedSegmentIDsInWindow == plain.unresolvedSegmentIDsInWindow)
        // The per-note summary a surface reads: B empty, A and C unchanged.
        let before = plain.noteSummaries(for: table)
        let after = cleared.noteSummaries(for: table)
        #expect(after[1].pointCount == 0 && after[1].medianMidi == nil)
        #expect([after[0], after[2]] == [before[0], before[2]])
    }

    @Test("inside one run: a cleared note CUTS the run, never bridges it, and both sides keep their own points verbatim")
    func clearedInsideARun() throws {
        // Run B split into three notes at frames 76 and 96; the middle one cleared.
        let notes = [Self.note(0..<50, hz: 220, cents: 30),
                     Self.note(56..<76, hz: 246.94, cents: -45),
                     Self.note(76..<96, hz: 246.94, cents: -45),
                     Self.note(96..<116, hz: 246.94, cents: -45),
                     Self.note(126..<186, hz: 196, cents: 20)]
        let plain = Self.line(notes)
        let cleared = Self.line(Self.clearing([2], in: notes))
        try #require(plain.runs.count == 3)
        try #require(plain.runs[1].count == 60)
        // Frame 75's centre (75.5 periods) is the left note's; frame 76's is
        // the cleared one's, and frame 96's is the right note's again.
        // (`#require`, not `#expect`: the indexing below must not trap the
        // whole test process when the count is wrong — a plant showed it.)
        try #require(cleared.runs.count == 4)
        #expect(cleared.runs[1] == Array(plain.runs[1][0..<20]))
        #expect(cleared.runs[2] == Array(plain.runs[1][40..<60]))
        #expect(cleared.runs[0] == plain.runs[0])
        #expect(cleared.runs[3] == plain.runs[2])
        #expect(Self.points(cleared, in: notes[2]).isEmpty)
    }

    @Test("the cut is made AFTER the run rule: a neighbour's stub shorter than a note still keeps its line")
    func aShortNeighbourKeepsItsLine() throws {
        // A 3-frame (48 ms) note before a cleared one inside run A. Fed into
        // `voicedRuns` as unvoiced frames, the stub would be a run under
        // `PitchAutoCorrect.minimumNoteSeconds` and would be DROPPED — its
        // line gone while it still plays.
        #expect(3 * Self.period < PitchAutoCorrect.minimumNoteSeconds)
        let notes = [Self.note(0..<3, hz: 220, cents: 30),
                     Self.note(3..<50, hz: 220, cents: 30),
                     Self.note(56..<116, hz: 246.94, cents: -45),
                     Self.note(126..<186, hz: 196, cents: 20)]
        let plain = Self.line(notes)
        let cleared = Self.line(Self.clearing([1], in: notes))
        try #require(!plain.runs.isEmpty)
        #expect(cleared.runs.first == Array(plain.runs[0].prefix(3)))
        #expect(Self.points(cleared, in: notes[1]).isEmpty)
        #expect(Array(cleared.runs.dropFirst()) == Array(plain.runs.dropFirst()))
    }

    @Test("a cleared note keeps no point even while it carries a pitch move — the dragged draft's case")
    func clearedAndMoved() throws {
        // The editor's draft line is `make` over the table with the dragged
        // note's offset set; a cleared note being dragged must stay silent.
        var moved = Self.threeNotes
        moved[1].pitchOffsetCents = 300
        let plain = Self.line(moved)
        let cleared = Self.line(Self.clearing([1], in: moved))
        try #require(plain.runs.count == 3)
        #expect(Self.points(plain, in: moved[1]).count == 60)
        #expect(Self.points(cleared, in: moved[1]).isEmpty)
        #expect(cleared.runs == [plain.runs[0], plain.runs[2]])
    }

    @Test("the ESTIMATE line (no contour answered yet) leaves the same hole")
    func estimateLeavesTheHoleToo() throws {
        // The editor's own window detection, its grid 2 ms off the render's.
        let fallback = Self.result(Self.frames(gridOffset: 0.002))
        let plain = Self.line(Self.threeNotes, contour: nil, fallback: fallback)
        let cleared = Self.line(Self.clearing([1], in: Self.threeNotes), contour: nil, fallback: fallback)
        try #require(plain.runs.count == 3)
        #expect(plain.basis.key == "estimate")
        #expect(Self.points(plain, in: Self.threeNotes[1]).count == 60)
        #expect(Self.points(cleared, in: Self.threeNotes[1]).isEmpty)
        #expect(cleared.runs == [plain.runs[0], plain.runs[2]])
    }

    @Test("the wire's one-line door — make(inputs:clip:tempoMap:), what clip.getPlayedPitch calls — returns the same hole, transposed or not")
    func theWireDoorLeavesTheHole() {
        for shift in [0.0, 2.0] {
            let table = PitchEditSet(segments: Self.clearing([1], in: Self.threeNotes))
            let clip = Clip(name: "vox", startBeat: 0, lengthBeats: 8,
                            audioFileURL: URL(fileURLWithPath: "/tmp/i7b2-vox.wav"),
                            pitchShiftSemitones: shift, pitchEdits: table)
            let inputs = PitchRenderInputs(contour: .detected(Self.wholeFile), sourceDurationSeconds: 3.2)
            let viaDoor = PitchPlayedLine.make(inputs: inputs, clip: clip, tempoMap: Self.tempo)
            let direct = PitchPlayedLine.make(
                contour: inputs.contour, fallback: nil, editSet: table,
                clipPitchShiftSemitones: shift,
                sourceWindow: PitchPlayedLine.sourceWindow(of: clip, tempoMap: Self.tempo))
            #expect(viaDoor == direct)
            #expect(Self.points(viaDoor, in: table.segments[1]).isEmpty)
            #expect(viaDoor.runs.count == 2)
        }
    }

    @Test("nothing cleared: the line is exactly what it always was, value for value")
    func nothingClearedChangesNothing() {
        // A LEVEL (not a clear) is no hole either: -72 dB is quiet, not silent.
        var levelled = Self.threeNotes
        levelled[1].amplitudeDb = -72
        #expect(Self.line(levelled).runs == Self.line(Self.threeNotes).runs)
        #expect(Self.line(Self.threeNotes).runs.count == 3)
    }
}
