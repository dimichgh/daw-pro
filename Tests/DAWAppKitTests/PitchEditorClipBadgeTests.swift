import DAWAppKit
import DAWCore
import Foundation
import Testing

/// m23-ap I7b-2 — the note editor header's ONE clip badge.
///
/// MEASURED on staging during I7b: a clip with three cleared notes and not
/// one pitch moved wore "TUNING APPLIED", because the badge read
/// `Clip.hasPitchEdits` and a cleared note is (rightly, for the wire and for
/// Remove Tuning) an edit. The badge now follows the PITCH half only.
///
/// ⛔ THE PLANT THIS SUITE EXISTS FOR: the badge reading `hasPitchEdits` for
/// its TUNING face. The clears-only and levels-only rows go red.
@Suite("The note editor's clip badge says TUNING APPLIED only when a pitch moved (m23-ap I7b-2)")
struct PitchEditorClipBadgeTests {

    private static let url = URL(fileURLWithPath: "/tmp/i7b2-badge.wav")

    private static func note(_ start: Double, cents: Double = 0, cleared: Bool = false,
                             db: Double = 0, drift: Double = 1) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: start + 0.5, detectedHz: 220,
                    detectedConfidence: 0.9, pitchOffsetCents: cents,
                    driftScale: drift, amplitudeDb: db, isCleared: cleared)
    }

    private static func clip(_ segments: [NoteSegment]?) -> Clip {
        Clip(name: "Lead Vox", audioFileURL: url,
             pitchEdits: segments.map { PitchEditSet(segments: $0) })
    }

    /// `(label, clip, the badge a person should read)`, by hand.
    private static let rows: [(label: String, clip: Clip, badge: PitchEditorClipBadge?)] = [
        ("no edit set", clip(nil), nil),
        ("detected notes, untouched", clip([note(0), note(1)]), nil),
        ("clears only", clip([note(0, cleared: true), note(1), note(2, cleared: true)]), .notesEdited),
        ("levels only", clip([note(0, db: -6), note(1, db: 3)]), .notesEdited),
        ("a clear and a level", clip([note(0, cleared: true), note(1, db: -3)]), .notesEdited),
        ("a pitch moved", clip([note(0, cents: 25), note(1)]), .tuningApplied),
        ("a pitch moved and a note cleared", clip([note(0, cents: 25), note(1, cleared: true)]), .tuningApplied),
        ("Hard Tune's shape, offset 0", clip([note(0, drift: 0)]), .tuningApplied),
    ]

    @Test("a clip whose only edits are clears says NOTES EDITED, never TUNING APPLIED")
    func clearsOnlySaysNotesEdited() {
        let clearsOnly = Self.clip([Self.note(0, cleared: true), Self.note(1), Self.note(2, cleared: true)])
        #expect(clearsOnly.hasPitchEdits, "precondition: the clip DOES carry an edit")
        #expect(PitchEditorClipBadge.resolve(clearsOnly) == .notesEdited,
                "a clears-only clip is badged as tuned")
        #expect(PitchEditorClipBadge.resolve(clearsOnly)?.title == "NOTES EDITED")
    }

    @Test("every row, by hand: no badge, NOTES EDITED, or TUNING APPLIED")
    func table() {
        for row in Self.rows {
            #expect(PitchEditorClipBadge.resolve(row.clip) == row.badge, "\(row.label)")
        }
    }

    @Test("a badge is drawn exactly when Remove Tuning is offered (Clip.hasPitchEdits) — never an edited clip unmarked")
    func badgeIffAnEdit() {
        for row in Self.rows {
            #expect((PitchEditorClipBadge.resolve(row.clip) != nil) == row.clip.hasPitchEdits, "\(row.label)")
        }
    }

    @Test("the words, verbatim — one per face, and only two faces")
    func titles() {
        #expect(PitchEditorClipBadge.tuningApplied.title == "TUNING APPLIED")
        #expect(PitchEditorClipBadge.notesEdited.title == "NOTES EDITED")
        #expect(PitchEditorClipBadge.allCases.count == 2)
    }
}
