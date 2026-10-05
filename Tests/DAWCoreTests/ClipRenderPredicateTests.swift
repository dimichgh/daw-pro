import Foundation
import Testing
import DAWCore

/// m23-ap-p2 **p2-snapshot**: `Clip.rendersThroughStretchCache` is the ONE home
/// of "does the engine play this clip from a render". The engine's
/// `StretchRenderCache.needsRender` forwards to it, and so does
/// `project.snapshot`'s gate for `stretchRendering`/`stretchError` — two
/// callers that used to ask different questions (the snapshot asked
/// `!isStretchIdentity`, which is blind to a tuning).
///
/// The expected column is written out by hand, case by case, rather than
/// restating the property's own disjunction: a test that re-derives the
/// predicate agrees with a wrong predicate.
@Suite("Clip.rendersThroughStretchCache — one home for 'does this clip render' (m23-ap-p2)")
struct ClipRenderPredicateTests {

    private static let url = URL(fileURLWithPath: "/tmp/x.wav")

    private static func note(cents: Double) -> NoteSegment {
        NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 220,
                    detectedConfidence: 0.9, pitchOffsetCents: cents)
    }

    @Test("renders for a time-stretch, a transpose, or a tuning that bends the curve — and for nothing else")
    func truthTable() {
        let tuned = PitchEditSet(segments: [Self.note(cents: 25)])
        let detectedOnly = PitchEditSet(segments: [Self.note(cents: 0)])
        let cases: [(label: String, clip: Clip, renders: Bool)] = [
            ("untouched", Clip(name: "u", audioFileURL: Self.url), false),
            ("formant-preserve alone", Clip(name: "f", audioFileURL: Self.url, formantPreserve: true), false),
            ("empty edit set", Clip(name: "e", audioFileURL: Self.url, pitchEdits: .empty), false),
            ("detected note table, no edit", Clip(name: "d", audioFileURL: Self.url, pitchEdits: detectedOnly), false),
            ("tuned only", Clip(name: "t", audioFileURL: Self.url, pitchEdits: tuned), true),
            ("time-stretched", Clip(name: "s", audioFileURL: Self.url, stretchRatio: 1.5), true),
            ("transposed", Clip(name: "p", audioFileURL: Self.url, pitchShiftSemitones: 3), true),
            ("stretched and tuned", Clip(name: "b", audioFileURL: Self.url, stretchRatio: 1.5, pitchEdits: tuned), true),
        ]
        for c in cases {
            #expect(c.clip.rendersThroughStretchCache == c.renders, "\(c.label)")
        }
    }

    @Test("a tuned clip is stretch-identity AND renders — the exact case the old snapshot gate dropped")
    func tunedClipIsTheGap() {
        let clip = Clip(name: "Lead Vox", audioFileURL: Self.url,
                        pitchEdits: PitchEditSet(segments: [Self.note(cents: -30)]))
        // `isStretchIdentity` keeps its narrower meaning ("is it stretched or
        // transposed") for the callers that want that question…
        #expect(clip.isStretchIdentity)
        #expect(clip.hasPitchEdits)
        // …and the render question is answered here.
        #expect(clip.rendersThroughStretchCache)
    }
}
