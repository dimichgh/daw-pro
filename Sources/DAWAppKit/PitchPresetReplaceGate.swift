import DAWCore
import Foundation
import Observation

// m23-ap C-F3 (design `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md`,
// finding F22) — THE PRESET DOORS ASK BEFORE THEY ERASE HAND EDITS.
//
// Both preset doors (the clip menu's Tune Vocal ▸ <preset> and the note
// editor's preset chips) reach one funnel, `AppModel.tuneVocalFromContextMenu`.
// The funnel asks this gate first. The gate answers from ONE signal,
// `PitchEditSet.hasHandEditsSinceAutoCorrect`, which DAWCore owns and tests.
// No second estimate of "was this edited" is made here.
//
// The gate is a headless model rather than a stored property on `AppModel`
// because `DAWApp` has no test target. Here, "Cancel applies nothing",
// "Replace applies the request that was held, once" and "a clip with no hand
// edits never asks" are SPY tests (`PitchTuneDoorSiteTests`), not greps.

/// A preset click that would replace hand edits, held while the card asks.
public struct PitchPresetReplaceRequest: Equatable, Sendable {
    public let clipID: UUID
    /// The clip's name AT THE CLICK. It is only for the card's sentence, and
    /// nothing is looked up by it.
    public let clipName: String
    public let preset: PitchCorrectionPreset
    /// W7-NTU (W7-D2's item 3) — what the preset will do to the header group's
    /// settings, read from the clip's set AT THE CLICK
    /// (`PitchPresetReplaceSettings(current:)`), for the card's sentence.
    public let settings: PitchPresetReplaceSettings

    public init(clipID: UUID, clipName: String, preset: PitchCorrectionPreset,
                settings: PitchPresetReplaceSettings = .none) {
        self.clipID = clipID
        self.clipName = clipName
        self.preset = preset
        self.settings = settings
    }
}

/// W7-NTU (W7-D2's item 3) — WHAT A PRESET DOES TO THE THREE SETTINGS OF THE
/// HEADER GROUP "Sound like the singer", read from the clip's set at the click.
///
/// ⚠️ **WHY THE CARD NEEDS THIS.** The gate's one signal
/// (`hasHandEditsSinceAutoCorrect`) is a stamp over the WHOLE set, so a
/// set-level pick made after a preset (a voice size, a Consonants switch, a
/// Slides step) moves it exactly as a moved note does, and the card asks.
/// W7-D2 made one more pick journaled (a consonant OFF on an OFF nobody
/// chose). In that case nothing on the note list was made by hand, and the
/// card's old sentence ("including the notes you moved…") was false. The
/// stamp cannot tell the two apart: the value a preset stored for a setting is
/// not kept anywhere. So the card's note list now says "any", which is true
/// with or without such edits, and this says what happens to each SETTING,
/// which the card CAN know.
///
/// ⭐ **THE RULES ARE THE STORE'S, READ HERE, AND A TEST HOLDS THEM TO IT.**
/// `ProjectStore.autoCorrectClipPitchReport` is their one home: the new set is
/// SEEDED (`PitchEditSet.seeded`: voice size 100 %, Consonants ON, Slides
/// Smooth), then a voice size the current set CARRIES is kept (no preset in
/// `PitchCorrectionPreset.offeredInUI` names one of its own), and a
/// consonant setting somebody CHOSE is kept (NT-C2-F1: all but
/// `.offByDefault`). The slide smoothness is NOT carried. Reading them again
/// here is a second copy, so
/// `PitchTuneDoorSiteTests.replaceCardSettingsMatchTheStore` runs the REAL
/// store's preset after each pick and reads the result back: if the store's
/// rules move, that test goes red, not the card.
public struct PitchPresetReplaceSettings: Equatable, Sendable {

    /// One of the header group's three rows.
    public enum Row: String, Sendable, Equatable, CaseIterable {
        case voiceSize
        case consonants
        case slides

        /// The row's drawn name (`PitchEditorFormantCopy`), so the card names
        /// the row a person can see.
        public var name: String {
            switch self {
            case .voiceSize: return PitchEditorFormantCopy.voiceLabel
            case .consonants: return PitchEditorFormantCopy.consonantsLabel
            case .slides: return PitchEditorFormantCopy.slidesLabel
            }
        }
    }

    /// A row the preset CHANGES, and the face it lands on, drawn as the header
    /// draws it ("100%", "ON", "Smooth").
    public struct Change: Equatable, Sendable {
        public let row: Row
        public let to: String

        public init(row: Row, to: String) {
            self.row = row
            self.to = to
        }
    }

    /// The rows the preset KEEPS, named only when their value differs from the
    /// one a preset would pick (a person who changed them learns the change
    /// survives). A row already at the preset's own value is not named: there
    /// is nothing to lose there and nothing to reassure.
    public let kept: [Row]
    /// The rows the preset CHANGES, in the header's row order.
    public let changed: [Change]

    public init(kept: [Row], changed: [Change]) {
        self.kept = kept
        self.changed = changed
    }

    /// Nothing to say (no set, or a set already at the preset's own values).
    public static let none = PitchPresetReplaceSettings(kept: [], changed: [])

    /// Read from `current`, the clip's STORED set at the click.
    public init(current: PitchEditSet?) {
        guard let current else {
            self = .none
            return
        }
        var kept: [Row] = []
        var changed: [Change] = []
        // Voice size: a carried amount is kept; none (a vocal tuned before
        // this update) takes the seed.
        if let amount = current.formantCorrection {
            if amount != PitchEditSet.newSetFormantCorrection { kept.append(.voiceSize) }
        } else {
            changed.append(Change(row: .voiceSize, to: PitchEditorFormantCopy.voiceReadout(
                PitchEditSet.newSetFormantCorrection)))
        }
        // Consonants: kept unless nobody chose them (NT-C2-F1); an OFF nobody
        // chose takes the seed, ON.
        switch current.consonantProtection {
        case .on: break
        case .offByChoice: kept.append(.consonants)
        case .offByDefault:
            changed.append(Change(row: .consonants, to: PitchEditorFormantCopy.switchOn))
        }
        // Slides: never carried; every preset seeds the default smoothness.
        let seeded = PitchEditSet.defaultTransitionSlope
        if current.transitionSlopeCentsPerSecond != seeded {
            let face = PitchEditorSlideStep.step(atCentsPerSecond: seeded)?.label
                ?? PitchEditorFormantCopy.slidesCustomLine
            changed.append(Change(row: .slides, to: face))
        }
        self.init(kept: kept, changed: changed)
    }
}

/// The one question every preset door asks before calling
/// `ProjectStore.autoCorrectClipPitch`, and the request it holds while the
/// person answers.
@MainActor
@Observable
public final class PitchPresetReplaceGate {

    public enum Decision: Equatable, Sendable {
        /// Nothing irreplaceable would be lost. Call the store now, with no
        /// dialog. This is the preset-comparison path: a clip holding only a
        /// preset's own output switches presets freely.
        case applyNow
        /// The clip carries hand edits. The request is now `pending`, and the
        /// store must NOT be called until the person says so.
        case askFirst
    }

    /// The request the confirm card is showing, or nil when no card is up.
    public private(set) var pending: PitchPresetReplaceRequest?

    public init() {}

    /// Decide whether a preset click may apply now.
    ///
    /// `current` is the clip's stored set AT THE CLICK. A clip with no set
    /// (never tuned, or tuning removed) has nothing to lose.
    public func request(_ preset: PitchCorrectionPreset, clipID: UUID, clipName: String,
                        current: PitchEditSet?) -> Decision {
        guard current?.hasHandEditsSinceAutoCorrect == true else { return .applyNow }
        pending = PitchPresetReplaceRequest(clipID: clipID, clipName: clipName, preset: preset,
                                            settings: PitchPresetReplaceSettings(current: current))
        return .askFirst
    }

    /// "Replace my edits": hands back the request the card was showing,
    /// EXACTLY ONCE. A second press, or a press after Cancel, returns nil, so
    /// it can never apply a preset nobody was asked about.
    public func confirm() -> PitchPresetReplaceRequest? {
        guard let held = pending else { return nil }
        pending = nil
        return held
    }

    /// "Cancel": drops the request. Nothing is applied.
    public func cancel() {
        pending = nil
    }
}

/// The card's words: one home, read by the view and pinned by tests.
///
/// Written for someone who is not a musician. It names the preset they
/// clicked, says what it does, names what they would lose in the note editor's
/// own verbs (its tools are labelled Move and Split), and says Undo brings it
/// back. `PitchCorrectionWriterTests` proves that last claim at the store
/// rather than taking it on trust.
///
/// ⚠️ **IT NAMES ONLY THE HAND EDITS THAT EXIST TODAY: moves and splits.**
/// The design's sentence also names timing and drawn shapes. Neither can be
/// made by hand yet, and a warning that lists losses the person cannot have
/// made teaches them to stop reading warnings. When one ships, `handEdits`
/// below grows its words — as it did for the Wobble tool (m23-ap C5a-4b, design
/// 2026-09-24 vibrato-handle V14: "a preset silently erases every hand-made
/// wobble"), in the palette's own word. The SIGNAL
/// needs no change, because any write through any path already reads as a
/// hand edit. `PitchTuneDoorSiteTests.replaceCopyNamesEveryEditorTool` trips
/// when the editor gains a tool, so this sentence cannot silently fall behind.
public struct PitchPresetReplaceCopy: Equatable, Sendable {
    public let title: String
    public let body: String
    public let undoNote: String
    public let confirmLabel: String
    public let cancelLabel: String

    /// What the person would lose, in the editor's own verbs.
    /// C5b-4b (2026-09-27): a pitch line drawn with ⌘-drag is a hand edit a
    /// preset erases too, so it is named, in plain words ("drawn shape" is jargon).
    ///
    /// W7-NTU U3 + W7-D2's item 3 (2026-09-27):
    ///  * a note made deeper or brighter with the Voice tool is a hand edit a
    ///    preset erases (the new set's notes are new), so it is named, by what
    ///    it DOES: "voice" alone would read as the header's "Keep voice size",
    ///    which a preset KEEPS;
    ///  * every item says "any", because the card now also asks when the only
    ///    change since the preset is a SETTING (see
    ///    `PitchPresetReplaceSettings`). "The notes you moved" would then claim
    ///    edits nobody made; "any note you moved" is true either way.
    public static let handEdits = "any note you moved or split by hand, any note you made deeper "
        + "or brighter, any wobble you changed and any pitch line you drew"

    public init(_ request: PitchPresetReplaceRequest) {
        let clip = request.clipName.isEmpty ? "this clip" : "“\(request.clipName)”"
        title = "Replace your hand edits?"
        let settings = Self.settingsSentence(request.settings)
        body = "\(request.preset.displayName) tunes all of \(clip) from scratch. "
            + "This replaces the tuning already on this clip, including \(Self.handEdits)."
            + (settings.isEmpty ? "" : " " + settings)
        undoNote = "Changed your mind afterwards? Undo (⌘Z) brings your edits back."
        confirmLabel = "Replace my edits"
        cancelLabel = "Cancel"
    }

    /// W7-NTU (W7-D2's item 3) — what the preset does to the header group's
    /// settings, or "" when it leaves each at the value it would pick anyway:
    /// "“Keep voice size” and “Consonants” stay as they are." then
    /// "“Slides” changes to Smooth." (several changes: "“Keep voice size”
    /// changes to 100%, “Consonants” to ON and “Slides” to Smooth.").
    public static func settingsSentence(_ settings: PitchPresetReplaceSettings) -> String {
        var sentences: [String] = []
        if !settings.kept.isEmpty {
            let names = list(settings.kept.map { "“\($0.name)”" })
            sentences.append(settings.kept.count == 1 ? "\(names) stays as it is."
                                                      : "\(names) stay as they are.")
        }
        if let first = settings.changed.first {
            let rest = settings.changed.dropFirst().map { "“\($0.row.name)” to \($0.to)" }
            let parts = ["“\(first.row.name)” changes to \(first.to)"] + rest
            sentences.append(list(parts) + ".")
        }
        return sentences.joined(separator: " ")
    }

    /// "A", "A and B", "A, B and C" — the card's own list style (no serial comma,
    /// as in `handEdits`).
    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
