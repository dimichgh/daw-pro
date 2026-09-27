import DAWCore
import Foundation

// UE-1 — "FIND SOUNDS WITH NO PITCH": the note editor's door to the merge verb
// (`ProjectStore.findUnpitchedSounds`, U-B), for a clip whose STORED note table
// was made before sounds existed. Design
// `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §1.6 ("An editor
// opened on an older table offers 'Find sounds with no pitch' (U-E)") and §1.10
// (F-stale; the refusals and the finder's two guards "shown on the wire and in the
// editor").
//
// ⭐ **ONLY THE WORDS AND THE OFFER LIVE HERE. THE VERB IS THE STORE'S.** One
// `performEdit("Find Sounds")`, one undo step, the re-stamp rule and the "fills only
// uncovered time" rule all belong to `findUnpitchedSounds` (U-B). This file decides
// when the editor OFFERS it and what a person READS about the answer, and nothing
// else. Pure: no store, no view, no model.
//
// ⚠️ **A FRESH TABLE NEVER NEEDS IT.** Both builders run the finder (U-A), so the
// editor's own seed and every preset pass already carry their sounds. The offer is
// therefore "a STORED table with no sound in it". That also offers it on a new table
// whose finder declined (too little quiet, too noisy); a press then says why in
// words, which is the honest answer rather than a hidden button.
//
// NO NEW WIRE VERB IS OWED: the store verb is `clip.findUnpitchedSounds`, MCP tool
// `clip_find_unpitched_sounds` (UB-2), both shipped. The staged press is
// `debug.pitchEditor {act:"findSounds"}`, app tier and off MCP by design.

/// What a press of "Find sounds with no pitch" came back with — the store's answer
/// reduced to what the words need, or its refusal verbatim.
public enum PitchEditorFindSoundsOutcome: Sendable, Equatable {
    /// The verb ran: `added` sounds joined the table, or none, and why
    /// (`skipped`, the finder's own guard) when it declined on purpose.
    case finished(added: Int, skipped: PitchUnpitchedFinder.SkipReason?)
    /// The store refused, in its own words (a comp member, a clip deleted while
    /// the pitch was being read). Shown verbatim, never swallowed.
    case refused(String)

    /// The store's answer, as the editor reads it.
    public init(_ found: FoundUnpitchedSounds) {
        self = .finished(added: found.added, skipped: found.finder.skipped)
    }
}

/// The one line the editor shows about a Find Sounds press.
public struct PitchEditorFindSoundsLine: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// Still looking — PROGRESS, drawn quietly (a spinner, never amber:
        /// nothing refused).
        case working
        /// It ran and this is the answer, sounds added or none to add.
        case done
        /// What was asked for did not happen: a guard declined, or the store
        /// refused. `PanelRefusalLine`'s amber.
        case shortfall
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// The offer and the words (see this file's banner).
public enum PitchEditorFindSounds {

    /// The button's words. Sentence case, a verb first, the house's action style.
    public static let label = "Find sounds with no pitch"

    /// What the button does, for a person who has never used a tuner.
    public static let help = "Look for breaths and consonants between the notes and add "
        + "them to this clip, so you can clear them or turn them down. Undo takes them away."

    /// The line while the pitch is read (seconds on a long take).
    public static let workingLine = PitchEditorFindSoundsLine(
        kind: .working, text: "Looking for breaths and other sounds with no pitch…")

    /// Whether the editor OFFERS the action: the clip has a STORED note table, and
    /// not one segment of it is a sound. A clip with no stored table draws the
    /// editor's own seed, which already has its sounds (both builders run the
    /// finder), so there is nothing to merge into and nothing missing.
    public static func isOffered(storedTable: PitchEditSet?) -> Bool {
        guard let storedTable else { return false }
        return !storedTable.segments.contains { $0.origin == .unpitched }
    }

    /// The refusal a press would meet BEFORE the pitch is read, in a person's
    /// words, or `nil` when the store will run.
    ///
    /// ⚠️ **THIS MIRRORS `ProjectStore.requireMergeableTable` AND MUST NOT DRIFT
    /// FROM IT.** The store refuses both cases in words written for an agent (they
    /// name `clip.autoCorrectPitch`); the editor asks first so a person reads a
    /// sentence written for them. `PitchEditorModelTests` pins that the two agree
    /// case by case, against a real store.
    public static func refusal(storedTable: PitchEditSet?) -> String? {
        guard let storedTable else {
            return "This clip's notes have not been saved yet, and new notes already "
                + "include their sounds, so there is nothing to add."
        }
        guard storedTable.analysisVersion == PitchEditSet.currentAnalysisVersion else {
            return "These notes were found by an older version of the pitch finder, so new "
                + "sounds cannot be lined up with them. Nothing was changed. Choosing a tuning "
                + "preset again finds the sounds, but replaces your note edits."
        }
        return nil
    }

    /// The line for an answer. Never silent: finding nothing says so.
    public static func line(for outcome: PitchEditorFindSoundsOutcome) -> PitchEditorFindSoundsLine {
        switch outcome {
        case .refused(let words):
            return PitchEditorFindSoundsLine(kind: .shortfall, text: words)
        case .finished(let added, let skipped):
            if let skipped {
                return PitchEditorFindSoundsLine(kind: .shortfall, text: skipLine(skipped))
            }
            guard added > 0 else {
                return PitchEditorFindSoundsLine(
                    kind: .done,
                    text: "Found no breaths or other sounds between the notes, so nothing was added.")
            }
            let found = added == 1
                ? "Added 1 sound with no pitch, like a breath or an \"s\". Undo takes it away."
                : "Added \(added) sounds with no pitch, like breaths and \"s\" sounds. "
                    + "Undo takes them away."
            return PitchEditorFindSoundsLine(kind: .done, text: found)
        }
    }

    /// The finder's three guards, each in a person's words (§1.3, §1.10 F-floor,
    /// F-hum). Every one says that nothing was added, and why.
    public static func skipLine(_ reason: PitchUnpitchedFinder.SkipReason) -> String {
        switch reason {
        case .notEnoughQuiet:
            let seconds = PitchUnpitchedFinder.minimumQuietSeconds
            let amount = seconds == 1 ? "1 second" : String(format: "%g seconds", seconds)
            return "Nothing was added: this clip has less than \(amount) of quiet, and that "
                + "is what tells a breath apart from background noise."
        case .tooNoisy:
            return "Nothing was added: the background noise is almost as loud as the singing, "
                + "so a breath cannot be told apart from it."
        case .noNotes:
            return "Nothing was added: there are no sung notes here to place a sound beside."
        }
    }
}

/// UE-2 — each clip's last Find-sounds DECLINE, app-held
/// (`PitchEditorInteractionBridge.findSoundsMemory`) so it outlives the pane's
/// `.id(clip.id)` rebuild.
///
/// ⭐ **WHY A MEMORY, NOT A HIDDEN BUTTON.** The offer is "a stored table with no
/// sound" (`isOffered`), and a table the finder DECLINED (`notEnoughQuiet`,
/// `tooNoisy`, `noNotes`) still holds no sound, so the button comes back on every
/// rebuild. Hiding it would hide the only door to finding out WHY nothing was
/// found; keeping it bare makes a press that already failed look as if it had
/// never been tried. So the button stays, and the line remembers the answer.
///
/// ⚠️ **KEYED ON THE TABLE THE ANSWER WAS FOR, NOT ONLY THE CLIP.** The finder
/// reads the note SPANS (and the audio), so an edit that re-identifies notes (a
/// split, a preset pass) voids the memory and the button stands bare again —
/// ask again, the answer may differ. A pitch drag keeps every id and keeps it.
/// Only DECLINES are remembered: an "Added" line describes sounds that are on
/// screen, and a store refusal can be transient.
@MainActor
public final class PitchEditorFindSoundsMemory {
    /// What a remembered answer is keyed on: the detector generation and the
    /// notes' ids, in table order.
    private struct TableKey: Equatable {
        let analysisVersion: Int
        let segmentIDs: [UUID]

        init(_ table: PitchEditSet) {
            analysisVersion = table.analysisVersion
            segmentIDs = table.segments.map(\.id)
        }
    }

    private var entries: [UUID: (key: TableKey, line: PitchEditorFindSoundsLine)] = [:]

    public init() {}

    /// Remember `line` as this clip's answer on `table`, replacing any earlier one.
    public func remember(clipID: UUID, table: PitchEditSet, line: PitchEditorFindSoundsLine) {
        entries[clipID] = (TableKey(table), line)
    }

    /// The remembered line for this clip, or `nil` when there is none or it was
    /// for another table.
    public func line(clipID: UUID, table: PitchEditSet?) -> PitchEditorFindSoundsLine? {
        guard let table, let entry = entries[clipID], entry.key == TableKey(table) else { return nil }
        return entry.line
    }
}
