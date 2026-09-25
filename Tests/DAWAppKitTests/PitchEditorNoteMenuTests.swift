import Foundation
import Testing
@testable import DAWAppKit

/// m23-ap interaction batch I7b — the note editor's ONE selection menu
/// (`PitchEditorNoteMenu`): its title table, its nouns, and the two sentences
/// that go with clearing.
///
/// ⚠️ NOT `@MainActor`, on purpose: everything here is a pure function of its
/// arguments, and an isolated suite would spend one of the review-cadence slots
/// `MainActorOccupancySiteTests` bounds for nothing. The model half (which
/// notes a right-click or ⌫ targets, and the one commit it makes) is
/// `PitchEditorModelTests`'.
@Suite("Pitch editor note menu (m23-ap I7b)")
struct PitchEditorNoteMenuTests {

    private func notes(_ cleared: [Bool]) -> [PitchEditorNoteMenu.Target] {
        cleared.map { PitchEditorNoteMenu.Target(kind: .note, isCleared: $0) }
    }

    private func menu(_ targets: [PitchEditorNoteMenu.Target]) -> [String] {
        PitchEditorNoteMenu.items(for: targets).map { "\($0.title)\($0.isEnabled ? "" : " (disabled)")" }
    }

    @Test("the title table: none, one, three, a mix, all cleared")
    func titleTable() {
        // NOTHING SELECTED: shown, greyed, and count-free — a greyed count
        // claims a pending action that is not pending.
        #expect(menu([]) == ["Clear Notes (disabled)"])
        // One, and three: the count is the blast radius.
        #expect(menu(notes([false])) == ["Clear Note"])
        #expect(menu(notes([false, false, false])) == ["Clear 3 Notes"])
        // A MIX: Clear counts only what it would CHANGE, and Restore appears for
        // the cleared ones — "Clear 3 Notes" would claim three changes and make two.
        #expect(menu(notes([false, true, false])) == ["Clear 2 Notes", "Restore Note"])
        #expect(menu(notes([true, false, true])) == ["Clear Note", "Restore 2 Notes"])
        // ALL CLEARED: nothing to clear (greyed, count-free), and the way back is
        // the one live item.
        #expect(menu(notes([true])) == ["Clear Notes (disabled)", "Restore Note"])
        #expect(menu(notes([true, true, true])) == ["Clear Notes (disabled)", "Restore 3 Notes"])
        // The ORDER is fixed — Clear first, always present — and each item says
        // which action it runs.
        #expect(PitchEditorNoteMenu.items(for: notes([true, false])).map(\.action) == [.clear, .restore])
    }

    @Test("the nouns are ready for sounds: \"Clear Sound\", and \"Clear 3 Selected\" for a mix")
    func soundNouns() {
        let sound = PitchEditorNoteMenu.Target(kind: .sound, isCleared: false)
        let note = PitchEditorNoteMenu.Target(kind: .note, isCleared: false)
        #expect(menu([sound]) == ["Clear Sound"])
        #expect(menu([sound, sound, sound]) == ["Clear 3 Sounds"])
        #expect(menu([note, sound, note]) == ["Clear 3 Selected"])
        // The count and the noun follow the targets that CHANGE: one note
        // uncleared beside two cleared sounds is "Clear Note".
        let clearedSound = PitchEditorNoteMenu.Target(kind: .sound, isCleared: true)
        #expect(menu([note, clearedSound, clearedSound]) == ["Clear Note", "Restore 2 Sounds"])
    }

    @Test("ONE plural producer: every counted title is `EditMenuTitles.counted`'s")
    func thePluralIsTheSharedOne() {
        for count in [1, 2, 3, 12] {
            let title = PitchEditorNoteMenu.items(for: notes(Array(repeating: false, count: count)))[0].title
            #expect(title == EditMenuTitles.counted(verb: "Clear", count: count,
                                                    singular: "Note", plural: "Notes"))
        }
    }

    @Test("the already-cleared line points at Restore — the brief's sentence for many, the singular for one")
    func alreadyClearedLine() {
        #expect(PitchEditorNoteMenu.alreadyClearedLine(notes([true, true, true]))
                == "Those notes are already cleared. Right-click ▸ Restore brings them back.")
        #expect(PitchEditorNoteMenu.alreadyClearedLine(notes([true]))
                == "That note is already cleared. Right-click ▸ Restore brings it back.")
        let sound = PitchEditorNoteMenu.Target(kind: .sound, isCleared: true)
        #expect(PitchEditorNoteMenu.alreadyClearedLine([sound, sound])
                == "Those sounds are already cleared. Right-click ▸ Restore brings them back.")
    }

    @Test("Remove Tuning's help adds \"also brings back N cleared notes\" only when N > 0")
    func removeTuningHelp() {
        let none = PitchEditorNoteMenu.removeTuningHelp(clearedNoteCount: 0)
        #expect(none == "Take every tuning change off this clip, so it plays the way it was recorded.")
        #expect(!none.contains("cleared"))
        #expect(PitchEditorNoteMenu.removeTuningHelp(clearedNoteCount: 1)
                == none + " It also brings back 1 cleared note.")
        #expect(PitchEditorNoteMenu.removeTuningHelp(clearedNoteCount: 3)
                == none + " It also brings back 3 cleared notes.")
        #expect(PitchEditorNoteMenu.removeTuningHelp(clearedNoteCount: 3)
                    .contains("also brings back 3 cleared notes"))
    }

    @Test("the level readout: a non-zero level always reads, in the house dB style; 0 dB and a cleared note read nothing")
    func levelReadout() {
        func blob(_ db: Double, cleared: Bool = false) -> NoteBlob {
            NoteBlob(startSeconds: 0, endSeconds: 1, detectedHz: 220, medianConfidence: 0.9,
                     frameCount: 60, isCleared: cleared, amplitudeDb: db)
        }
        #expect(blob(-6).levelReadout == "Level -6.0 dB")
        #expect(blob(3).levelReadout == "Level +3.0 dB")
        #expect(blob(-72).levelReadout == "Level -72.0 dB")
        // NEVER INVISIBLE: a level that rounds to 0.0 is still an edited level.
        #expect(blob(0.04).levelReadout == "Level 0.0 dB")
        #expect(blob(0).levelReadout == nil)
        #expect(blob(-6, cleared: true).levelReadout == nil)
        // A blob built with a level or a clear is an EDITED blob even with no
        // `hasEdits` handed in — the default derivation covers both fields.
        #expect(blob(-6).isEdited)
        #expect(blob(0, cleared: true).isEdited)
        #expect(!blob(0).isEdited)
    }

    @Test("the staged menu step is its own act on the debug tier")
    func stagedStepKey() {
        #expect(PitchEditorStagedStep.noteMenu(.clear, nil).key == "noteMenu")
        #expect(PitchEditorStagedStep.noteMenu(.restore, CGPoint(x: 1, y: 2)).key == "noteMenu")
        #expect(PitchEditorNoteMenu.Action(rawValue: "clear") == .clear)
        #expect(PitchEditorNoteMenu.Action(rawValue: "restore") == .restore)
        #expect(PitchEditorNoteMenu.clearedLabel == "cleared")
    }
}
