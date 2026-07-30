import Foundation

/// The ONE home for the question "would the PIANO ROLL have consumed this
/// keystroke?", plus the debug-tier seam that lets a gate put the roll into the
/// state where it would.
///
/// WHY THIS EXISTS (m23-x, second pass). The arrange's arrow-key nudge must not
/// fire while the user is editing notes — press ← meaning "nudge this note" and
/// the whole CLIP sliding a bar underneath the open editor is the worst kind of
/// surprise. The obvious guard, `AppModel.pianoRollEditorFocused`, was written,
/// shipped to a staging binary, and MEASURED TO BE WRONG: `PianoRollView` does
/// `.onAppear { isFocused = true }` and `AppModel.openEditorClip` is non-nil for
/// ANY single selected MIDI clip, so that flag is already true in the perfectly
/// ordinary state "user clicked one MIDI clip in the arrange". Guarding on it
/// alone did not close a leak, it DELETED the feature's primary case — measured
/// on staging: one MIDI clip selected, → pressed, `refusedBy: piano-roll-focused`
/// and the clip did not move (0 → 0), with 9 of 46 gate assertions red and every
/// one of them a CONTROL half ("with the guard inactive the same call nudges").
///
/// THE RULE THIS ENCODES IS THE APP'S OWN, NOT A NEW ONE. `PianoRollView`'s
/// DELETE handler already reads:
///
///     .onKeyPress(.delete) {
///         guard !model.selection.isEmpty else { return .ignored }
///
/// — the roll consumes the key only when it HAS A NOTE SELECTION, and otherwise
/// lets it fall through so the arrange acts on the clip. (With the roll open and
/// no notes selected, DELETE deletes the whole clip today; that is shipped,
/// accepted behaviour.) So the faithful mirror of DELETE is not "refuse while
/// the roll is focused" but "refuse when the roll would have consumed it": the
/// editor is on screen AND holds a note selection. That fixes exactly the
/// reported surprise and leaves single-clip nudge alive.
///
/// AND FOCUS IS NOT A TERM IN THE SHIPPED PREDICATE AT ALL — a second
/// measurement, after the obvious repair. Keeping `pianoRollEditorFocused` as an
/// EXTRA term (focus AND notes) looks conservative and is in fact worse than
/// useless: the flag ALTERNATES DETERMINISTICALLY on clip switches. Twelve
/// consecutive select-a-MIDI-clip cycles reported
/// `true,false,true,false,…` — exactly 6 true and 6 false, with `editorClipId`
/// non-null on all twelve, and the false readings persisted through a further
/// 1.4 s (they latch; they are not late reports). `.onAppear { isFocused = true }`
/// on the incoming instance and `.onDisappear { onFocusChange(false) }` on the
/// outgoing one race on every `.id(clip.id)` rebuild, and the loser is whichever
/// SwiftUI runs second. A guard carrying that term would let the clip slide
/// underneath the editor on every OTHER clip selection — an intermittent version
/// of the very bug being fixed, which is harder to report and harder to trust
/// than a consistent one. `AppModel.openEditorClip` (derived from
/// `selectedClipID` + a store lookup, no focus anywhere) is the deterministic
/// way to ask "is the roll on screen", so the guard asks that instead.
///
/// The flag is still fine for what m21-c uses it for — routing ⌘+/⌘−/⌘0 to
/// whichever zoom the user most recently engaged, where being wrong every other
/// clip switch is a mild annoyance the user corrects with one more click. It is
/// not fine for silently moving the user's music. Same flag, different stakes.
///
/// WHY A BRIDGE OBJECT rather than a bare `Bool` on `AppModel`: the flag has to
/// be REPORTED OUT of a view whose `PianoRollModel` is `@State private` (so
/// nothing outside can read it), and the staging seam has to reach INTO that
/// same private model. Both directions, one subject, one file — the
/// `FollowPlayheadModel.externalScrollNonce` pattern this copies verbatim in
/// shape (observed nonce in, observed state out).
@MainActor
@Observable
public final class PianoRollNoteSelectionBridge {

    /// REPORTED BY THE ROLL. True while the open editor has at least one note
    /// selected — i.e. while the roll's own `.onKeyPress` handlers would claim a
    /// keystroke rather than let it fall through to the arrange.
    ///
    /// Reported from `.onChange(of:initial:)`, never from `body` (a write during
    /// `body` is the thing `onBarOpsStyle` gets away with only because nothing
    /// observes it; this one gates a keyboard path and must be observable).
    public private(set) var hasSelection = false

    /// STAGED FOR THE ROLL by `debug.arrangeSelection {act:"pianoRollNotes"}`.
    /// The view watches the nonce, so re-staging the same intent still applies
    /// (the `externalScrollNonce` reason: a gate must be able to ask twice).
    public private(set) var stageNonce = 0
    /// What the staged event asks for: select every note in the draft, or none.
    @ObservationIgnored public private(set) var stagedSelectAll = false

    public init() {}

    /// The roll's report. Idempotent — the view calls it with `initial: true`.
    public func report(hasSelection: Bool) { self.hasSelection = hasSelection }

    /// Stage a note selection into whatever roll is on screen.
    public func stage(selectAll: Bool) {
        stagedSelectAll = selectAll
        stageNonce += 1
    }

    /// THE ROLL WENT AWAY. Called from `.onDisappear`, mirroring the existing
    /// `onFocusChange(false)` next to it, and load-bearing: a `hasSelection`
    /// left latched `true` after the editor closes would kill the arrow keys
    /// permanently, with nothing on screen to explain why — strictly worse than
    /// the bug this whole bridge exists to fix.
    public func clear() { hasSelection = false }
}
