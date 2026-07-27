import Foundation

// Arrange clip selection (m23-g1) — the ONE home for "which clips are selected
// in the arrange, and which one is the FOCUS". Headless (no SwiftUI, no AppKit)
// so every branch is unit-testable, in the `ArrangeDropSnap` / `MixerStripLayout`
// / `KnobGeometry` / `PianoRollPlayhead` tradition.
//
// WHY A FOCUS AT ALL — and why this type exists instead of a bare `Set<UUID>`:
// the arrange's pre-g1 selection (`AppModel.selectedClipID`) is not merely a
// highlight. It RESOLVES THE PIANO-ROLL EDITOR TARGET (`AppModel.openEditorClip`
// filters it to MIDI; `ContentView` renders the editor branch exactly when that
// is non-nil). Replacing it wholesale with a set would have had to invent an
// answer to "which of the three selected clips is the note editor open on?" at
// every one of its ~19 call sites. Instead the set and the focus live in ONE
// value with a stated invariant, and `AppModel.selectedClipID` becomes a
// computed mirror of `focusID` — so every pre-existing call site keeps its exact
// single-selection behaviour, which is the ONLY behaviour that existed before
// g1. That, rather than a call-site audit, is what makes the m23-e note-editor
// fix safe from this change.
//
// INVARIANTS (enforced structurally — `ids`/`focusID` are `private(set)`, so the
// mutators below are the only things in the program that can move them):
//   INV1  focusID != nil  =>  ids.contains(focusID!)
//   INV2  ids.isEmpty     =>  focusID == nil
// The converse of INV2 deliberately does NOT hold: ⌘-clicking the focused clip
// out of a multi-selection leaves the others selected with NO focus (see
// `toggle` for why that is the honest outcome).
//
// SCOPE: clips only — including the m23-g3 rubber band, which selects CLIPS.
// TRACK selection is m23-y (split out of g3 by the orch pass), and it carries
// its own semantics question ("does selecting a track select its clips?") that
// this type takes no position on.
//
// NOT FOLDED IN, deliberately: `PianoRollModel.selection` (notes). Its toggle
// looks identical (`contains ? remove : insert`) but its INVARIANT is not — notes
// have no focus concept, because nothing opens an editor "on a note". Folding
// the roll onto this type would mean giving note selection a focus field that
// means nothing, on the exact surface m23-e/m23-d just repaired. The shared
// thing here is a three-line idiom, not a rule.

/// The chord modifiers an arrange click can carry. Mirrored from
/// `NSEvent.ModifierFlags` WITHOUT importing AppKit (DAWAppKit stays headless) —
/// the `TransportKeyModifiers` precedent. The app maps the live event; this type
/// carries only what the decision needs.
public struct ArrangeClickModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ArrangeClickModifiers(rawValue: 1 << 0)
    public static let command = ArrangeClickModifiers(rawValue: 1 << 1)

    /// No modifiers — a plain click.
    public static let none: ArrangeClickModifiers = []
}

/// What a click on a clip block should do to the selection.
public enum ArrangeClickIntent: String, Equatable, Sendable {
    /// Plain click: this clip becomes the whole selection, and the focus.
    case replace
    /// Shift- or ⌘-click: add/remove this clip, leaving the rest alone.
    case toggle

    /// The ONE mapping from a click's chord to its intent.
    ///
    /// SHIFT AND ⌘ BOTH MEAN TOGGLE in g1, deliberately. On many surfaces shift
    /// means "extend a RANGE" and ⌘ means "toggle one" — but a range needs an
    /// ORDER to extend along, and the arrange's clips are a 2-D field (tracks ×
    /// beats) with no canonical order. A rubber band is the honest 2-D range
    /// gesture, and it is m23-g3. Until then, giving shift a second, subtly
    /// different meaning would be inventing an ordering the surface does not
    /// have. Any other chord (⌥, ⌃, or a combination that includes them) that
    /// carries neither shift nor command is a plain click here; ⌥-click already
    /// belongs to the fade-curve toggle (`optionClickFadeToggle`).
    ///
    /// m23-g3 SHIPPED that rubber band, and it reuses THIS mapping rather than
    /// growing a second chord table: a marquee held with shift (or ⌘) is
    /// `.toggle` = additive (`ArrangeSelection.formUnion`), and a bare one is
    /// `.replace`. So the chord means the same thing on a click and on a band.
    public static func intent(for modifiers: ArrangeClickModifiers) -> ArrangeClickIntent {
        (modifiers.contains(.shift) || modifiers.contains(.command)) ? .toggle : .replace
    }
}

/// The arrange's clip selection: a set plus the focus clip the note editor
/// resolves against.
public struct ArrangeSelection: Equatable, Sendable {
    /// Every selected clip id. Rendered as the selected state on each block.
    public private(set) var ids: Set<UUID> = []
    /// The clip the piano roll opens on (nil = the editor is closed). Always a
    /// member of `ids` when non-nil (INV1).
    public private(set) var focusID: UUID?

    public init() {}

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }
    public func contains(_ id: UUID) -> Bool { ids.contains(id) }
    public func isFocus(_ id: UUID) -> Bool { focusID == id }

    /// A plain click: exactly this clip, focused. Byte-identical to the pre-g1
    /// `selectedClipID = id`.
    public mutating func selectOnly(_ id: UUID) {
        ids = [id]
        focusID = id
    }

    /// Nothing selected, nothing focused (closes the note editor). Byte-identical
    /// to the pre-g1 `selectedClipID = nil`.
    public mutating func clear() {
        ids = []
        focusID = nil
    }

    /// The `selectedClipID` setter's semantics, verbatim: a non-nil assignment is
    /// a fresh single selection, nil is "nothing selected". Every pre-g1 write to
    /// `selectedClipID` (open the editor on a created clip, close the panel, the
    /// `debug.captureUI {selectClip}` seam) lands here and behaves exactly as it
    /// did before — the set simply follows along instead of drifting out of sync.
    public mutating func focus(_ id: UUID?) {
        if let id { selectOnly(id) } else { clear() }
    }

    /// Shift/⌘-click: add or remove one clip, leaving the rest of the selection
    /// alone.
    ///
    /// FOCUS RULE — "adopted when there is none, never stolen, never inherited":
    ///   • adding when there is no focus  -> this clip becomes the focus
    ///   • adding when a focus exists     -> the focus does NOT move
    ///   • removing the focused clip      -> focus becomes nil, `ids` survives
    ///   • removing any other clip        -> focus untouched
    /// The second rule is why building a group does not make the note editor
    /// flicker from clip to clip as you shift-click. The third is the one worth
    /// stating loudly: the alternative — promoting some OTHER member to focus —
    /// would open the note editor on a clip the user never clicked, purely
    /// because they deselected a different one. Closing the editor and keeping
    /// the remaining selection is the outcome that surprises nobody.
    public mutating func toggle(_ id: UUID) {
        if ids.contains(id) {
            ids.remove(id)
            if focusID == id { focusID = nil }
        } else {
            ids.insert(id)
            if focusID == nil { focusID = id }
        }
    }

    /// The RUBBER BAND's replace (m23-g3): the selection becomes exactly this
    /// set. Used by a plain marquee drag, which re-decides the whole selection
    /// on every update as the band grows and shrinks.
    ///
    /// FOCUS RULE — a strict reading of `toggle`'s "adopted when there is none,
    /// NEVER stolen, NEVER inherited", which for a SET resolves to **never
    /// adopted**:
    ///   • the focus SURVIVES when it is still a member of the new set
    ///   • otherwise it becomes nil (INV1) — and a fresh one is NOT invented
    /// The second half is the decision worth stating, because "adopt when there
    /// is none" is under-determined for a set and could be read the other way.
    /// A band has NO anchor clip: `ArrangeClickIntent`'s own doc records that
    /// the arrange's clips are a 2-D field with no canonical order, which is
    /// why shift means toggle there and why a rubber band was left as the
    /// honest 2-D range gesture. So promoting "some member" to focus would open
    /// the piano roll on a clip the user never clicked — the exact outcome
    /// `toggle` refuses — and, because a marquee applies LIVE on every pointer
    /// update, the editor would flicker from clip to clip as the band swept.
    /// Selecting is not opening.
    public mutating func replace(with newIDs: Set<UUID>) {
        ids = newIDs
        if let focus = focusID, !newIDs.contains(focus) { focusID = nil }
    }

    /// The RUBBER BAND's shift chord (m23-g3): add these to the selection,
    /// leaving everything already selected — and the focus — alone.
    ///
    /// The focus needs no adjustment in either direction: `ids` only GROWS, so
    /// a focus that satisfied INV1 still does, and no focus is adopted for the
    /// `replace(with:)` reasons above.
    public mutating func formUnion(_ newIDs: Set<UUID>) {
        ids.formUnion(newIDs)
    }

    /// Routes a click through `ArrangeClickIntent`. The ONE entry point the app's
    /// tap handler and the `debug.arrangeSelection` seam both call, so the seam
    /// cannot drift from the gesture.
    @discardableResult
    public mutating func apply(click id: UUID, modifiers: ArrangeClickModifiers) -> ArrangeClickIntent {
        let intent = ArrangeClickIntent.intent(for: modifiers)
        switch intent {
        case .replace: selectOnly(id)
        case .toggle: toggle(id)
        }
        return intent
    }

    /// The subset of `ids` that still exists, in the caller's `live` set.
    ///
    /// STALE-ID POLICY, stated once here because it is the question every
    /// selection model eventually gets wrong: a selected clip can vanish under
    /// the selection (an undo, a redo, an agent's `clip.remove` over the wire),
    /// and this type does NOT try to observe that. A stale id is HARMLESS by
    /// construction — every consumer resolves ids against live clips:
    /// rendering asks `contains(clip.id)` per EXISTING block, `focusID` runs
    /// through `AppModel.openEditorClip` which already resolves against the
    /// store and yields nil, and group delete filters through this method before
    /// touching the store. So there is no pruning pass, no observer, and no
    /// window in which a stale id can do damage.
    public func resolved(in live: Set<UUID>) -> Set<UUID> {
        ids.filter { live.contains($0) }
    }
}
