import Foundation
import Testing
@testable import DAWCore

/// I1 (hear the note while editing it, design
/// `2026-09-24-pitch-editor-interaction-batch.md` §4): the POLICY's numbers and
/// the span arithmetic, headless and nonisolated. The controller's behaviour
/// (press, wait, render-complete, latest wins, expiry, transport) is pinned in
/// `AuditionControllerTests` against a spy engine; the engine's physics in
/// `AuditionEngineTests` and `ClipSpanAuditionTests`.
@Suite("I1 clip-note audition policy — the numbers and the span")
struct ClipNoteAuditionPolicyTests {

    private func note(_ start: Double, _ end: Double) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: 0.9)
    }

    @Test("I1 the three picks are the design's numbers: 60 ms context, 6 s cap, 5 ms fades; waits end at 8 s; a clear is heard with 0.3 s")
    func picksAreTheDesignNumbers() {
        // Literals on purpose: each is the design's stated number, and a test
        // that compared the constant to itself could not fail.
        #expect(ClipNoteAuditionPolicy.contextSeconds == 0.060)
        #expect(ClipNoteAuditionPolicy.maxSpanSeconds == 6.0)
        #expect(ClipNoteAuditionPolicy.fadeSeconds == 0.005)
        #expect(ClipNoteAuditionPolicy.renderWaitSeconds == 8.0)
        #expect(ClipNoteAuditionPolicy.clearContextSeconds == 0.3)
        // Every pick fits inside what a caller may ask for.
        #expect(ClipNoteAuditionPolicy.contextSecondsRange.contains(ClipNoteAuditionPolicy.contextSeconds))
        #expect(ClipNoteAuditionPolicy.contextSecondsRange.contains(ClipNoteAuditionPolicy.clearContextSeconds))
    }

    @Test("I1 span = notes ± context, never before the file start, clipped to the clip's window, capped at 6 s")
    func spanArithmetic() throws {
        // One note, default context.
        let one = try #require(ClipNoteAuditionPolicy.span(of: [note(1.0, 1.5)],
                                                           contextSeconds: 0.06))
        #expect(abs(one.lowerBound - 0.94) < 1e-12)
        #expect(abs(one.upperBound - 1.56) < 1e-12)

        // Several notes, in any order: earliest start to latest end.
        let group = try #require(ClipNoteAuditionPolicy.span(
            of: [note(3.0, 3.4), note(1.0, 1.2), note(2.0, 2.5)], contextSeconds: 0.06))
        #expect(abs(group.lowerBound - 0.94) < 1e-12)
        #expect(abs(group.upperBound - 3.46) < 1e-12)

        // The context never reaches before the file's first second.
        let early = try #require(ClipNoteAuditionPolicy.span(of: [note(0.02, 0.3)],
                                                             contextSeconds: 0.06))
        #expect(early.lowerBound == 0)

        // Clipped to the window the clip plays.
        let windowed = try #require(ClipNoteAuditionPolicy.span(
            of: [note(1.0, 1.5)], contextSeconds: 0.06, within: 1.2...1.4))
        #expect(windowed == 1.2...1.4)

        // Capped at 6 s from its start, however long the group.
        let long = try #require(ClipNoteAuditionPolicy.span(
            of: [note(1.0, 2.0), note(10.0, 11.0)], contextSeconds: 0.06))
        #expect(abs(long.lowerBound - 0.94) < 1e-12)
        #expect(abs(long.upperBound - (0.94 + 6.0)) < 1e-12)
    }

    /// I1-F2 (RT re-review, the span cap): the cap is the SOURCE span that
    /// 6 HEARD seconds cover at the clip's ratio, which the engine supplies
    /// (`AudioEngineControlling.clipAuditionSourceSeconds`); the policy keeps
    /// the span's start and cuts its end, exactly as with 6.
    @Test("I1-F2 the cap is the SOURCE span the engine says 6 heard seconds cover: the start is kept and the end cut; the default is the old cap bit for bit; an invalid cap falls back to 6")
    func spanCapInSourceSeconds() throws {
        let long = [note(1.0, 2.0), note(10.0, 11.0)]
        // Ratio 4: 6 heard seconds are 1.5 source seconds.
        let slow = try #require(ClipNoteAuditionPolicy.span(of: long, contextSeconds: 0.06,
                                                            maxSourceSeconds: 1.5))
        #expect(abs(slow.lowerBound - 0.94) < 1e-12)
        #expect(abs(slow.upperBound - (0.94 + 1.5)) < 1e-12)
        // Ratio 0.25: 24 source seconds; a span shorter than that is left alone.
        let fast = try #require(ClipNoteAuditionPolicy.span(of: long, contextSeconds: 0.06,
                                                            maxSourceSeconds: 24))
        #expect(abs(fast.upperBound - 11.06) < 1e-12)
        // The default IS the old cap.
        let old = try #require(ClipNoteAuditionPolicy.span(of: long, contextSeconds: 0.06))
        #expect(ClipNoteAuditionPolicy.span(of: long, contextSeconds: 0.06, maxSourceSeconds: 6) == old)
        // A cap the engine could not give falls back to 6.
        for bad in [0.0, -1, .nan, .infinity] {
            #expect(ClipNoteAuditionPolicy.span(of: long, contextSeconds: 0.06, maxSourceSeconds: bad) == old,
                    "cap \(bad)")
        }
        // The window first, then the cap from the clipped start.
        let windowed = try #require(ClipNoteAuditionPolicy.span(
            of: [note(1.0, 9.0)], contextSeconds: 0.06, within: 2.0...8.0, maxSourceSeconds: 1.5))
        #expect(windowed == 2.0...3.5)
    }

    @Test("I1 no notes, a negative or non-finite context, or notes wholly outside the window give no span")
    func spanRefusals() {
        #expect(ClipNoteAuditionPolicy.span(of: [], contextSeconds: 0.06) == nil)
        #expect(ClipNoteAuditionPolicy.span(of: [note(1, 2)], contextSeconds: -0.01) == nil)
        #expect(ClipNoteAuditionPolicy.span(of: [note(1, 2)], contextSeconds: .nan) == nil)
        #expect(ClipNoteAuditionPolicy.span(of: [note(1, 2)], contextSeconds: .infinity) == nil)
        #expect(ClipNoteAuditionPolicy.span(of: [note(5, 6)], contextSeconds: 0.06,
                                            within: 0...2) == nil)
        // Control: the same note inside the window does span.
        #expect(ClipNoteAuditionPolicy.span(of: [note(1, 1.5)], contextSeconds: 0.06,
                                            within: 0...2) != nil)
    }

    @Test("I1 only a split leaves the sound unchanged; a clear is heard with 0.3 s of context, every other edit with 60 ms")
    func editKindsThatChangeSound() {
        #expect(ClipNoteEdit.pitch.changesSound)
        #expect(ClipNoteEdit.level.changesSound)
        #expect(ClipNoteEdit.clear.changesSound)
        #expect(!ClipNoteEdit.split.changesSound)
        #expect(ClipNoteEdit.allCases.filter { !$0.changesSound } == [.split])
        #expect(ClipNoteEdit.clear.contextSeconds == 0.3)
        for edit in ClipNoteEdit.allCases where edit != .clear {
            #expect(edit.contextSeconds == 0.060)
        }
    }
}
