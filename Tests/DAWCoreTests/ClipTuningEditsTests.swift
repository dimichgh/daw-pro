import Foundation
import Testing
import DAWCore

/// m23-ap I7b-2 — `Clip.hasTuningEdits`, the PITCH half of `hasPitchEdits`.
///
/// The note editor's header said "TUNING APPLIED" on `hasPitchEdits`, which
/// since I7a is also true for a clip whose only edits clear notes or change
/// their level. `hasTuningEdits` is the display door for "was a pitch moved";
/// `hasPitchEdits` keeps its meaning (wire contract, Remove Tuning, and — via
/// `rendersThroughStretchCache` — whether the clip renders at all).
///
/// The expected columns are written out BY HAND, row by row, never re-derived
/// from `isPitchIdentity`: a test that restates the predicate agrees with a
/// wrong predicate (`ClipRenderPredicateTests`' rule).
@Suite("Clip.hasTuningEdits — the pitch half of hasPitchEdits, for the TUNING APPLIED badge (m23-ap I7b-2)")
struct ClipTuningEditsTests {

    private static let url = URL(fileURLWithPath: "/tmp/i7b2-tuning.wav")

    private static func note(_ start: Double, cents: Double = 0, cleared: Bool = false,
                             db: Double = 0, drift: Double = 1, vibrato: Double = 1,
                             depth: Double = 0, rate: Double = 0, formant: Double = 0,
                             timeStart: Double = 0) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: start + 0.5, detectedHz: 220,
                    detectedConfidence: 0.9, pitchOffsetCents: cents,
                    driftScale: drift, vibratoScale: vibrato, vibratoRateHz: rate,
                    vibratoDepthCents: depth, formantOffsetSemitones: formant,
                    timeStartDeltaSeconds: timeStart, amplitudeDb: db, isCleared: cleared)
    }

    private static func clip(_ segments: [NoteSegment]?) -> Clip {
        Clip(name: "Lead Vox", audioFileURL: url,
             pitchEdits: segments.map { PitchEditSet(segments: $0) })
    }

    /// `(label, clip, hasPitchEdits, hasTuningEdits)`, both columns by hand.
    private static let rows: [(label: String, clip: Clip, edits: Bool, tuning: Bool)] = [
        ("no edit set at all", clip(nil), false, false),
        ("an empty edit set", clip([]), false, false),
        ("detected notes, nobody touched them", clip([note(0), note(1)]), false, false),
        ("one note cleared, nothing else", clip([note(0, cleared: true), note(1)]), true, false),
        ("every note cleared", clip([note(0, cleared: true), note(1, cleared: true)]), true, false),
        ("one note turned down 6 dB", clip([note(0, db: -6), note(1)]), true, false),
        ("a cleared note and a levelled one", clip([note(0, cleared: true), note(1, db: 4)]), true, false),
        ("one note moved +25 cents", clip([note(0, cents: 25), note(1)]), true, true),
        ("a moved note beside a cleared one", clip([note(0, cents: -40), note(1, cleared: true)]), true, true),
        ("a cleared note that also carries a pitch move", clip([note(0, cents: 30, cleared: true)]), true, true),
        ("Hard Tune's shape on a note already in tune", clip([note(0, drift: 0, vibrato: 0)]), true, true),
        ("a generated vibrato", clip([note(0, depth: 20, rate: 5.5)]), true, true),
        ("a formant move alone", clip([note(0, formant: 2)]), true, true),
        ("a retimed note alone", clip([note(0, timeStart: 0.05)]), true, true),
        // A generator RATE with zero depth renders as nothing (see
        // `NoteSegment.isIdentity`'s doc) — no edit on either half, as before.
        ("a vibrato rate with zero depth", clip([note(0, rate: 5.5)]), false, false),
    ]

    @Test("a clip whose ONLY edits clear notes or change a level carries edits and NO tuning — the rows that used to say TUNING APPLIED")
    func levelsOnlyAreNotTuning() {
        let clearsOnly = Self.clip([Self.note(0, cleared: true), Self.note(1), Self.note(2, cleared: true)])
        #expect(clearsOnly.hasPitchEdits, "the wire contract moved: a cleared note is an edit")
        #expect(!clearsOnly.hasTuningEdits, "a clears-only clip claims a moved pitch")
        let levelsOnly = Self.clip([Self.note(0, db: -12), Self.note(1, db: 3)])
        #expect(levelsOnly.hasPitchEdits)
        #expect(!levelsOnly.hasTuningEdits, "a levels-only clip claims a moved pitch")
    }

    @Test("the whole table, by hand: hasPitchEdits unchanged, hasTuningEdits true exactly when a pitch, shape, formant or timing moved")
    func truthTable() {
        for row in Self.rows {
            #expect(row.clip.hasPitchEdits == row.edits, "hasPitchEdits — \(row.label)")
            #expect(row.clip.hasTuningEdits == row.tuning, "hasTuningEdits — \(row.label)")
        }
    }

    @Test("a moved pitch is always an edit: no row has tuning without hasPitchEdits (so one badge slot covers both faces)")
    func tuningImpliesAnEdit() {
        for row in Self.rows where row.clip.hasTuningEdits {
            #expect(row.clip.hasPitchEdits, "\(row.label)")
        }
        // …and the table actually exercises both sides of that implication.
        #expect(Self.rows.contains { $0.clip.hasTuningEdits })
        #expect(Self.rows.contains { $0.clip.hasPitchEdits && !$0.clip.hasTuningEdits })
    }

    @Test("the render predicate is untouched: a clears-only clip still renders, through the level mask")
    func clearsOnlyStillRenders() {
        let clearsOnly = Self.clip([Self.note(0, cleared: true)])
        #expect(clearsOnly.rendersThroughStretchCache)
        #expect(!clearsOnly.hasTuningEdits)
        let untouched = Self.clip([Self.note(0)])
        #expect(!untouched.rendersThroughStretchCache)
    }
}
