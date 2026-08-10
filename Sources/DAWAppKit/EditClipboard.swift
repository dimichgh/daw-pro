import DAWCore
import Foundation

/// One copied arrange clip, plus where it came from.
///
/// THE VALUE COPY *IS* THE SNAPSHOT. `Clip` is a DAWCore value type
/// (`Codable, Sendable, Equatable`), so holding one here freezes every field —
/// media URL, source offset, gain, both fades and their curves, stretch, pitch,
/// the gain envelope and the controller lanes — at copy time. A later edit to
/// the source clip cannot reach into the clipboard, and nothing has to be deep
/// copied by hand.
///
/// ⚠️ THE ID IN `clip` IS THE SOURCE'S AND IS NEVER PASTED. Fresh ids are minted
/// at PASTE time (`ProjectStore.pasteClips` routes every landing through
/// `reidentified`), because pasting twice must yield two distinct sets of
/// objects. Minting at copy time would make a second paste re-use the first
/// paste's ids.
public struct ClipboardClip: Equatable, Sendable {
    /// The copied clip, verbatim. Its `startBeat` is the SOURCE position — the
    /// paste rewrites it; `PasteAnchorPolicy` needs the original to compute each
    /// member's offset from the group's earliest.
    public var clip: Clip
    /// The track the clip was copied from. Drives the P1 "paste in place" test:
    /// if EVERY source track still exists, each clip goes home.
    public var sourceTrackID: UUID
    /// The source track's index in store order. Drives the P2 relocated paste's
    /// vertical geometry — a copy spanning tracks 3 and 5 keeps its two-track
    /// gap when it lands somewhere else.
    public var sourceTrackIndex: Int

    public init(clip: Clip, sourceTrackID: UUID, sourceTrackIndex: Int) {
        self.clip = clip
        self.sourceTrackID = sourceTrackID
        self.sourceTrackIndex = sourceTrackIndex
    }
}

/// A copied group of piano-roll notes.
///
/// `notes` carry CLIP-LOCAL starts, exactly as they sit in `Clip.notes`. The
/// paste translates them rigidly against a clip-local anchor, so the group's
/// internal rhythm survives verbatim.
public struct ClipboardNotes: Equatable, Sendable {
    public var notes: [MIDINote]
    /// The clip the notes were copied from. Recorded for diagnosis and for the
    /// seam's echo; a note paste targets whatever clip the roll is CURRENTLY
    /// open on, so this is deliberately NOT a constraint on the destination —
    /// copying from one clip and pasting into another is a wanted workflow.
    public var sourceClipID: UUID

    public init(notes: [MIDINote], sourceClipID: UUID) {
        self.notes = notes
        self.sourceClipID = sourceClipID
    }
}

/// What the clipboard is holding.
///
/// A SUM TYPE, NOT TWO OPTIONAL PROPERTIES, and that is the property the whole
/// paste routing stands on: notes can only go in a roll and clips can only go in
/// the arrange, so a clipboard that could hold both at once would need an
/// arbitration rule that this design does not have and does not want. One
/// payload, one destination surface, no ambiguity.
public enum ClipboardPayload: Equatable, Sendable {
    case clips([ClipboardClip])
    case notes(ClipboardNotes)
}

/// The payload's discriminator, spelled as a `String` raw value so the debug
/// seam can echo it and a gate can assert on it.
public enum ClipboardKind: String, Sendable, CaseIterable, Equatable {
    case clips
    case notes
}

/// THE APP'S EDIT CLIPBOARD (m23-ek-3) — in-app, typed, and held by `AppModel`.
///
/// WHY NOT `NSPasteboard`, and this was killed EMPIRICALLY rather than assumed.
/// `DAWProApp` is a SINGLE `WindowGroup` over an App-level `@State private var
/// model = AppModel()`, and `FileCommands` does `CommandGroup(replacing:
/// .newItem)`, which replaces the group macOS puts *New Window* in. There is no
/// `DocumentGroup`. **One project per process** — so every "cross-window" paste
/// is a paste inside the same project, which this covers completely. The
/// cross-project motivation an `NSPasteboard` mirror would serve is a FUTURE
/// premise, not a current one.
///
/// Three more reasons, kept short: two clipboards need a `changeCount`
/// arbitration rule and get it wrong quietly; the obvious pasteboard flavour for
/// notes is a Standard MIDI File, whose mapper is under concurrent edit; and an
/// audio `Clip` has no honest lossless pasteboard representation short of the
/// whole private struct. An `NSPasteboard` MIRROR (in-app stays authoritative,
/// copy additionally writes an SMF flavour so ⌘C in the roll can paste into
/// Logic) is genuinely valuable and genuinely a separate item.
///
/// THE `PianoRollNoteSelectionBridge` SHAPE VERBATIM: a small `@Observable`
/// class in DAWAppKit that `AppModel` holds, so the menu policy that reads it is
/// testable headlessly while `DAWApp` — which has no test target — keeps only
/// the composition.
@MainActor
@Observable
public final class EditClipboard {

    /// What was last copied or cut, or nil when nothing has been.
    ///
    /// OBSERVABLE, and that is load-bearing: Edit ▸ Paste's enabled state and
    /// its title are computed from this, so a `Commands` body must re-evaluate
    /// the moment a copy lands. It is the same property `deleteMenuItem`'s doc
    /// calls out — every input to a menu item has to be observable or the item
    /// goes stale, and a Paste that is greyed after a successful Copy is the
    /// exact staleness a user cannot diagnose.
    public private(set) var payload: ClipboardPayload?

    /// Bumped on every `put` and every `clear`.
    ///
    /// WHY A SEQUENCE AND NOT A BOOL. A gate that copies the SAME selection
    /// twice sees an identical `payload` both times, so it has nothing to wait
    /// on and nothing to distinguish "the second copy ran" from "the first copy
    /// is still standing" — the `externalScrollNonce` problem, which this tree
    /// answers with a monotonic counter everywhere it appears. Bumped by
    /// `clear()` too, deliberately: a cut that empties the clipboard is an
    /// event, and a counter that only counted puts could not report it.
    public private(set) var seq = 0

    /// DERIVED, NEVER STORED. "What is on the clipboard" and "which surface can
    /// receive it" are the same fact; a stored twin could drift from `payload`,
    /// which is precisely the failure `DeleteMenuItem.isEnabled` is derived to
    /// avoid.
    public var kind: ClipboardKind? {
        switch payload {
        case .clips: return .clips
        case .notes: return .notes
        case nil: return nil
        }
    }

    /// How many clips are held; 0 for a note payload or an empty clipboard.
    /// Named rather than derived at each call site so the menu title, the seam
    /// echo and the tests all count the same way.
    public var clipCount: Int {
        if case .clips(let clips) = payload { return clips.count }
        return 0
    }

    /// How many notes are held; 0 for a clip payload or an empty clipboard.
    public var noteCount: Int {
        if case .notes(let group) = payload { return group.notes.count }
        return 0
    }

    public init() {}

    /// Writes the clipboard.
    ///
    /// ⚠️ AN EMPTY PAYLOAD IS REFUSED AND LEAVES THE PREVIOUS CONTENTS
    /// STANDING, rather than being stored as an empty-but-present clipboard.
    /// Two reasons. (1) A clipboard holding `.clips([])` would make Paste light
    /// up with the title "Paste 0 Clips" and then do nothing — a live menu item
    /// that is a no-op is the failure shape the whole `refusedBy` idiom exists
    /// to remove. (2) macOS's own pasteboard behaves this way: a copy that
    /// captured nothing does not destroy what you copied a minute ago. Returns
    /// false when it refused, so a CUT can decline to delete on the same
    /// condition.
    @discardableResult
    public func put(_ payload: ClipboardPayload) -> Bool {
        switch payload {
        case .clips(let clips) where clips.isEmpty: return false
        case .notes(let group) where group.notes.isEmpty: return false
        default: break
        }
        self.payload = payload
        seq &+= 1
        return true
    }

    /// Empties the clipboard. Bumps `seq` (see above) only when there was
    /// something to drop, so a clear on an already-empty clipboard is a true
    /// no-op and cannot satisfy a bounded wait that is standing on a real one.
    public func clear() {
        guard payload != nil else { return }
        payload = nil
        seq &+= 1
    }
}
