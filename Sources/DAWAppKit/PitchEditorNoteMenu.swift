import Foundation

// m23-ap interaction batch, item I7b — THE NOTE EDITOR'S ONE SELECTION MENU.
//
// Design record: `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §10
// "UI (I7b)" and §17.4 ("I7b's selection menu is the ONLY one, for notes and
// sounds: 'Clear' / 'Restore', nouns from `PitchEditorNoteMenu`"). The user's
// words: "remove/clear while maintaining position of other vocals by selecting
// segment and then right click and remove/clear from menu".
//
// ⭐ **WHAT "CLEAR" IS.** A cleared note is SILENCED IN PLACE
// (`NoteSegment.isCleared`, I7a): it stays in the table, stays drawn, keeps its
// pitch and its level, and nothing around it moves. Restore brings it back at
// its own level. ⌫ (`delete-clears = yes`, the user's answer on the handoff
// page), Edit ▸ Delete and this menu's Clear all reach the SAME model action
// (`PitchEditorModel.performNoteAction`), so the three can never disagree about
// what was cleared.
//
// ⭐ **THE TITLES NAME THEIR BLAST RADIUS** (`docs/DESIGN-LANGUAGE.md`, "A
// destructive item NAMES ITS BLAST RADIUS"). Clear counts the notes it would
// CHANGE — the selected notes not already cleared — and Restore counts the
// cleared ones. "Clear 3 Notes" over a selection of three with one already
// cleared would claim three changes and make two, so it reads "Clear 2 Notes"
// beside "Restore Note". A disabled item is SHOWN and DROPS ITS COUNT ("Clear
// Notes"), the house rule: a greyed count claims a pending action that is not
// pending. The plural itself is `EditMenuTitles.counted` — the ONE producer, so
// this menu invents no plural of its own.
//
// ⚠️ **SOUNDS ARE MAPPED, NOT PRODUCED.** Unpitched sounds (U-A/U-E,
// `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §1.8) are
// cleared from this same menu once they exist as selectable segments. The noun
// mapping is ready ("Clear Sound", "Clear 3 Sounds", "Clear 3 Selected" for a
// mix) so U-E adds a producer and not a second menu; until then every caller
// hands in `.note`.
//
// NO NEW WIRE VERB IS OWED FOR THIS MENU. Clear
// and Restore are `clip.setNoteCleared` (MCP tool `clip_set_note_cleared`) and
// the level the readout shows is `clip.setNoteGain` (`clip_set_note_gain`),
// both shipped; the staged menu step is `debug.pitchEditor {act:"noteMenu"}`,
// app tier and off MCP by design. THE PRODUCER IS FIXED (I7b-2):
// `PitchPlayedLine.make` itself leaves a hole over every cleared note, so
// `clip.getPlayedPitch` now returns no point there, the editor's line and the
// wire's are one value.
//
// ✅ DONE (mcp-lane, I7b-2 wire leg, 2026-09-25): the DAWControl wire test —
// `getPlayedPitchHasNoPointOverAClearedNote`
// (`Tests/DAWControlTests/PitchCorrectionCommandTests.swift`) — pairs a
// cleared clip's `clip.getPlayedPitch` against the SAME clip uncleared (the
// `PitchPlayedLineClearedTests` positive-control idiom): no point falls
// inside the cleared note's span, and every point outside it is
// byte-identical to before clearing. `clip_get_played_pitch`'s MCP
// description (`mcp-server/src/server.ts`) now says a cleared note's stretch
// is a hole in `runs`, like an unvoiced gap.

/// The note editor's selection menu — Clear and Restore — and the words that
/// go with clearing. Pure: no store, no view, no model.
public enum PitchEditorNoteMenu {

    /// What an item does. The raw values are the debug tier's spelling
    /// (`debug.pitchEditor {act:"noteMenu", action}`), additive only.
    public enum Action: String, Sendable, Equatable, CaseIterable {
        /// Silence the targets in place (`setClipNotesCleared(cleared: true)`).
        case clear
        /// Bring cleared targets back at their own level (`cleared: false`).
        case restore
    }

    /// What a target IS, for its noun. Only `.note` is produced today.
    public enum Kind: String, Sendable, Equatable {
        case note
        case sound
    }

    /// One thing the menu would act on.
    public struct Target: Sendable, Equatable {
        public var kind: Kind
        public var isCleared: Bool

        public init(kind: Kind = .note, isCleared: Bool) {
            self.kind = kind
            self.isCleared = isCleared
        }
    }

    /// One menu item: what it does, what it says, whether it is live.
    public struct Item: Sendable, Equatable, Identifiable {
        public var action: Action
        public var title: String
        public var isEnabled: Bool

        public var id: Action { action }

        public init(action: Action, title: String, isEnabled: Bool) {
            self.action = action
            self.title = title
            self.isEnabled = isEnabled
        }
    }

    /// The word a CLEARED note is labelled with on the surface — the menu's own
    /// verb, so the label a person reads matches the item they pressed.
    public static let clearedLabel = "cleared"

    /// The menu for these targets, in order: Clear ALWAYS (shown, disabled when
    /// nothing would change), then Restore only when a target is cleared.
    ///
    /// - With nothing to act on: `[Clear Notes (disabled)]` — the menu still
    ///   appears, greyed, so a person who right-clicks without selecting learns
    ///   the operation exists and wants a selection (the roll's
    ///   `DeleteMenuPolicy.noteContextTitle` rule).
    /// - Every target already cleared: Clear is disabled and count-free, and
    ///   Restore is live — the way back is the one live item.
    public static func items(for targets: [Target]) -> [Item] {
        let toClear = targets.filter { !$0.isCleared }
        let toRestore = targets.filter(\.isCleared)
        var items = [Item(action: .clear,
                          title: title(verb: "Clear", changing: toClear, all: targets),
                          isEnabled: !toClear.isEmpty)]
        if !toRestore.isEmpty {
            items.append(Item(action: .restore,
                              title: title(verb: "Restore", changing: toRestore, all: targets),
                              isEnabled: true))
        }
        return items
    }

    /// The ONE refusal line of a Clear that would change nothing, because every
    /// target is already cleared — ⌫ or Edit ▸ Delete on an all-cleared
    /// selection (the menu's own Clear is greyed there instead). Nothing is
    /// committed; the line points at the way back.
    ///
    /// The plural sentence is the brief's, verbatim. ONE target reads in the
    /// singular — "That note is already cleared." — because a novice with one
    /// note selected reading "Those notes" is being told about notes they did
    /// not select.
    public static func alreadyClearedLine(_ targets: [Target]) -> String {
        let kinds = Set(targets.map(\.kind))
        if targets.count == 1 {
            let noun = kinds == [.sound] ? "sound" : "note"
            return "That \(noun) is already cleared. Right-click ▸ Restore brings it back."
        }
        let subject: String
        switch kinds {
        case [.sound]: subject = "Those sounds are"
        case [.note], []: subject = "Those notes are"
        default: subject = "Those are"
        }
        return "\(subject) already cleared. Right-click ▸ Restore brings them back."
    }

    /// The help line of **Remove Tuning** — the clip menu's and the note
    /// editor's own button, the same operation (`clearClipTuningFromContextMenu`
    /// → `ProjectStore.clearClipPitchEdits`), so ONE sentence for both.
    ///
    /// ⭐ WHY IT NAMES CLEARED NOTES (design §17.4). Remove Tuning wipes the
    /// whole note table, and a cleared note's silence LIVES in that table — so
    /// removing the tuning also brings every cleared note back. That is a side
    /// effect its label does not name, and a person who cleared a cough and then
    /// pressed Remove Tuning would hear the cough return. The help says so, with
    /// the count, whenever there is one.
    public static func removeTuningHelp(clearedNoteCount: Int) -> String {
        let base = "Take every tuning change off this clip, so it plays the way it was recorded."
        guard clearedNoteCount > 0 else { return base }
        let notes = clearedNoteCount == 1 ? "1 cleared note" : "\(clearedNoteCount) cleared notes"
        return base + " It also brings back \(notes)."
    }

    // MARK: - The nouns

    /// "Clear 2 Notes" — counted over the targets that CHANGE — or, when none
    /// would, the verb with the whole target set's plural noun and NO count.
    private static func title(verb: String, changing: [Target], all: [Target]) -> String {
        guard !changing.isEmpty else {
            return "\(verb) \(nouns(for: all.map(\.kind)).plural)"
        }
        let noun = nouns(for: changing.map(\.kind))
        return EditMenuTitles.counted(verb: verb, count: changing.count,
                                      singular: noun.singular, plural: noun.plural)
    }

    /// Note / Notes, Sound / Sounds, and "Selected" for a mix ("Clear 3
    /// Selected", design §17.4). An empty set reads as notes — the only thing
    /// this editor draws today.
    private static func nouns(for kinds: [Kind]) -> (singular: String, plural: String) {
        let set = Set(kinds)
        if set == [.sound] { return ("Sound", "Sounds") }
        if set.count > 1 { return ("Selected", "Selected") }
        return ("Note", "Notes")
    }
}
