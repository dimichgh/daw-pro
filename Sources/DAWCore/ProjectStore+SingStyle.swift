import Foundation

// p2-sing-x7: writing a melody clip's singing style (design `docs/design/2026-10-06-p2-sing-expansion.md` §5.3, §5.6).
// `setSingStyle` is THE one write: the wire's `clip.setSingStyle` and the Sing sheet's Expression card (x8) both call
// it, so they cannot disagree about what a style write checks or how it is undone.

/// One note's change inside a `SingStyleEdit`: the note's WHOLE own choice after the edit (design §5.6
/// `notes: [{noteId, vibrato?, air?}]`). A choice with neither field (`NoteSingStyle.isEmpty`) removes the note's own
/// choice, so the note follows the clip again. At the note level `.asSung` and an air of 0 are real choices
/// ("no wobble / no air on this note"), as `SingStyle` documents.
public struct NoteSingStyleEdit: Equatable, Sendable {
    public var noteID: UUID
    public var style: NoteSingStyle

    public init(noteID: UUID, style: NoteSingStyle) {
        self.noteID = noteID
        self.style = style
    }
}

/// What one `setSingStyle` call changes. A nil clip-wide field is left as it is; `notes` lists the notes whose own
/// choice is replaced (nil or empty: none). `clear` removes the whole style and must come alone.
public struct SingStyleEdit: Equatable, Sendable {
    public var vibrato: SingStyle.Vibrato?
    /// In `SingStyle.airRange` (0 = none, 1 = lots).
    public var air: Double?
    public var followVelocity: Bool?
    public var notes: [NoteSingStyleEdit]?
    public var clear: Bool

    public init(vibrato: SingStyle.Vibrato? = nil, air: Double? = nil, followVelocity: Bool? = nil,
                notes: [NoteSingStyleEdit]? = nil, clear: Bool = false) {
        self.vibrato = vibrato
        self.air = air
        self.followVelocity = followVelocity
        self.notes = notes
        self.clear = clear
    }

    /// True when the edit names a change besides `clear`.
    var namesAChange: Bool {
        vibrato != nil || air != nil || followVelocity != nil || !(notes ?? []).isEmpty
    }
}

/// What `setSingStyle` did.
public struct SingStyleWriteResult: Equatable, Sendable {
    public var clipID: UUID
    /// The style the clip holds after the call (nil: no style, the clip is sung with the defaults: `SingStyle.defaultVibrato`, no air, every note at one level).
    public var style: SingStyle?
    /// False when the call left the clip exactly as it was: no undo step was recorded.
    public var changed: Bool
    /// Per-note choices whose notes were already gone from the clip (INERT, `SingStyle.orphanedNoteIDs(in:)`); this
    /// write removed them. Sorted by `uuidString`.
    public var removedOrphanNoteIDs: [UUID]

    public init(clipID: UUID, style: SingStyle?, changed: Bool, removedOrphanNoteIDs: [UUID]) {
        self.clipID = clipID
        self.style = style
        self.changed = changed
        self.removedOrphanNoteIDs = removedOrphanNoteIDs
    }
}

/// Why a style write was refused (design §5.6). Every case has its wire code and its sentence; nothing is changed
/// by a refusal.
public enum SingStyleRefusal: Error, Equatable, Sendable {
    /// The clip is audio (`singStyleNeedsMIDIClip`).
    case needsMIDIClip
    /// A vibrato name the wire does not know (`singStyleVibratoInvalid`, "lists the five"). The UI never sends one.
    case vibratoInvalid(String)
    /// An air amount outside 0...1, or not a number (`singStyleAirOutOfRange`).
    case airOutOfRange
    /// A per-note choice names a note the clip does not hold (`noteNotFound`, "all or nothing, names the id").
    case noteNotFound(noteID: UUID)
    /// `clear` together with another change (`singStyleClearAlone`, "send clear on its own").
    case clearAlone
    /// Nothing to change was named (`nothingToChange`).
    case nothingToChange
    /// Per-note choices on a live-looper layer's clip while the deck is open (W8-X5M's finding: every pass re-mints
    /// that clip's note ids, `LoopDeckMath.tile`, so a per-note choice would be orphaned on the next pass). Clip-wide
    /// choices are still allowed. PROVISIONAL code `singStyleLoopNotes`.
    case loopLayerNotes

    /// The wire's refusal code (design §5.6; `singStyleLoopNotes` is PROVISIONAL).
    public var code: String {
        switch self {
        case .needsMIDIClip: return "singStyleNeedsMIDIClip"
        case .vibratoInvalid: return "singStyleVibratoInvalid"
        case .airOutOfRange: return "singStyleAirOutOfRange"
        case .noteNotFound: return "noteNotFound"
        case .clearAlone: return "singStyleClearAlone"
        case .nothingToChange: return "nothingToChange"
        case .loopLayerNotes: return "singStyleLoopNotes"
        }
    }

    public var sentence: String {
        switch self {
        case .needsMIDIClip:
            // Base §5.7 "Audio clip", VERBATIM (the lyrics write's own sentence).
            return LyricEditRefusal.needsMIDIClip.sentence
        case .vibratoInvalid(let name):
            // PROVISIONAL (§5.6 names the code and "lists the five"; no sentence).
            let five = SingStyle.Vibrato.allCases.map(\.rawValue).joined(separator: ", ")
            return "'\(name)' isn't a vibrato choice. Pick one of: \(five)."
        case .airOutOfRange:
            // PROVISIONAL (§5.6 names the code only).
            return "Air goes from 0 (none) to 1 (lots). Pick a number in that range."
        case .noteNotFound(let id):
            // PROVISIONAL (§5.6: "all or nothing, names the id"; no sentence).
            return "There is no note \(id.uuidString) in this clip, so nothing was changed. "
                + "Check the note ids with clip.getNotes."
        case .clearAlone:
            // PROVISIONAL sentence around §5.6's own words, "send clear on its own".
            return "Clear removes the whole singing style, so send clear on its own, with no other changes."
        case .nothingToChange:
            // PROVISIONAL (§5.6 names the code only).
            return "Nothing to change: choose a vibrato, an air amount, follow note loudness or single notes, "
                + "or send clear to remove the style."
        case .loopLayerNotes:
            // PROVISIONAL (no §14 row; W8-X5M's finding).
            return "This clip is a loop that's still being recorded, and its notes are rewritten on every pass. "
                + "Choose a style for the whole clip now, or style single notes after you finish looping."
        }
    }
}

@MainActor
extension ProjectStore {

    /// The undo step a style write records (design §5.6).
    public static let setSingStyleUndoLabel = "Set Singing Style"

    /// Changes `clipId`'s singing style as ONE undo step, "Set Singing Style" (design §5.6), all or nothing: every
    /// check runs, and the whole new style is built, BEFORE anything is written.
    ///
    /// - The clip-wide fields of `edit` that are set replace the clip's; the ones left nil stay.
    /// - Each entry of `edit.notes` replaces that note's own choice (an empty choice removes it).
    /// - `edit.clear` removes the whole style (it must come alone).
    /// - The write prunes per-note choices whose notes are gone (`SingStyle.keepingOverrides(for:)`, the rebuild
    ///   rule) and reports them; the stored style is normalised, so an all-default style is stored as nil.
    /// - A call that leaves the clip as it was records no undo step (`changed == false`).
    ///
    /// - Throws: `ProjectError.clipNotFound`; `ProjectError.clipInTakeGroup` for a comp member (its clip is rebuilt
    ///   from the takes on every comp edit, the rule every ordinary clip edit follows); `SingStyleRefusal`.
    @discardableResult
    public func setSingStyle(clipId: UUID, edit: SingStyleEdit) throws -> SingStyleWriteResult {
        guard let (t, c) = locateClipForSingStyle(clipId) else { throw ProjectError.clipNotFound(clipId) }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let clip = tracks[t].clips[c]
        guard clip.isMIDI else { throw SingStyleRefusal.needsMIDIClip }
        if edit.clear {
            guard !edit.namesAChange else { throw SingStyleRefusal.clearAlone }
        } else if !edit.namesAChange {
            throw SingStyleRefusal.nothingToChange
        }
        if let air = edit.air, !Self.airIsValid(air) { throw SingStyleRefusal.airOutOfRange }
        let noteEdits = edit.notes ?? []
        if !noteEdits.isEmpty {
            if loopDeck?.layers.contains(where: { $0.clipID == clipId }) == true {
                throw SingStyleRefusal.loopLayerNotes
            }
            let held = Set((clip.notes ?? []).map(\.id))
            for noteEdit in noteEdits {
                guard held.contains(noteEdit.noteID) else { throw SingStyleRefusal.noteNotFound(noteID: noteEdit.noteID) }
                if let air = noteEdit.style.air, !Self.airIsValid(air) { throw SingStyleRefusal.airOutOfRange }
            }
        }

        // Every check has passed: build the whole new style, then write it once.
        let before = clip.singStyle
        let removedOrphans = before?.orphanedNoteIDs(in: clip.notes) ?? []
        var next = edit.clear ? SingStyle() : (before ?? SingStyle())
        if let vibrato = edit.vibrato { next.vibrato = vibrato }
        if let air = edit.air { next.air = air }
        if let followVelocity = edit.followVelocity { next.followVelocity = followVelocity }
        if !noteEdits.isEmpty {
            var overrides = next.notes ?? [:]
            for noteEdit in noteEdits {
                overrides[noteEdit.noteID] = noteEdit.style.isEmpty ? nil : noteEdit.style
            }
            next.notes = overrides.isEmpty ? nil : overrides
        }
        let stored = next.keepingOverrides(for: clip.notes)
        let changed = stored != before
        if changed {
            performEdit(Self.setSingStyleUndoLabel) {
                tracks[t].clips[c].singStyle = stored
                engine?.tracksDidChange(tracks)
            }
        }
        return SingStyleWriteResult(clipID: clipId, style: stored, changed: changed,
                                    removedOrphanNoteIDs: changed ? removedOrphans : [])
    }

    /// An air amount the style accepts: a finite number in `SingStyle.airRange`.
    static func airIsValid(_ air: Double) -> Bool {
        air.isFinite && SingStyle.airRange.contains(air)
    }

    /// Locates a clip by id across every track (extension-local: the private `locateClip(_:)` in ProjectStore.swift
    /// is not visible here, the ProjectStore+LyricTextEdit.swift precedent).
    private func locateClipForSingStyle(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
