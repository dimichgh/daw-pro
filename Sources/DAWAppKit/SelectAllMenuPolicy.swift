import Foundation

/// The ONE home for the question "**what does ⌘A / Edit ▸ Select All act on, and
/// is it live?**" (m25-s).
///
/// ═══ THE USER'S WORDS, AND THE SCOPE THEY SET ═══
///
/// 2026-08-13: *"One small feature to add when in node editor and user uses
/// keyboard shortcut \"select all\"/cmd+A - it should select all the notes in the
/// editor"* — "node editor" is the piano roll.
///
/// ⚠️ **THE REQUEST NAMES ONE SURFACE, AND THIS POLICY REFUSES EVERYWHERE ELSE.**
/// `ClipboardResponderRouting` recorded, as a reason for NOT claiming `selectAll:`
/// at m25-f-1, that *"there is no arrange-wide 'select all clips' verb in this app
/// yet, and inventing one here would ship it through a keystroke nobody
/// reviewed."* THAT OBJECTION IS STILL LIVE AND IS HONOURED: this returns a
/// surface for the ROLL only. An arrange-wide select-all remains uninvented, and
/// the day somebody wants one it is a product decision with a `SelectAllSurface`
/// case to add — not a silent widening of a keystroke.
///
/// ═══ WHY THIS READS `EditorSurface` AND ITS TWO SIBLINGS DO NOT ═══
///
/// `DeleteMenuPolicy` and `ClipboardMenuPolicy` route on
/// `AppModel.pianoRollWouldConsumeKey` — "the roll is on screen AND HOLDS A NOTE
/// SELECTION" — and `AppModel` states at length why they must not use
/// `activeEditorSurface`: engagement answers "which editor did the user last
/// ENGAGE", which comes apart from "which surface would CONSUME this", and
/// routing DELETE by engagement would delete clips while notes sat selected.
///
/// ⭐⭐ **THAT TERM IS UNUSABLE HERE, AND THE REASON IS THE WHOLE POINT OF ⌘A: A
/// SELECT-ALL EXISTS TO BE PRESSED WHEN NOTHING IS SELECTED.** Gating it on
/// "already holds a note selection" would make the feature reachable only once it
/// was unnecessary. So the discriminator has to be the OTHER question — which
/// surface is the user working in — and this tree already has exactly one home
/// for it (`EditorSurfaceRouter.resolve`, consumed via
/// `AppModel.activeEditorSurface`). This policy takes its VERDICT, never its
/// terms: no `openEditorClip`, no workspace flag, no focus, no second arbitration.
///
/// The accepted consequence is `EditorSurfaceRouter`'s own, stated there and
/// unchanged here: clicking a MIDI clip in the arrange OPENS the roll but leaves
/// the ARRANGE engaged, so ⌘A does nothing until the user clicks into the roll.
/// That is "most recently engaged", it matches Logic's active-area model, and it
/// is the same gesture that already decides ⌘+ and DELETE. One answer, one place.
///
/// ═══ WHERE THE TEXT-FIELD OBJECTION WENT ═══
///
/// The other recorded reason for not claiming `selectAll:` was *"⌘A inside a
/// rename field must keep selecting TEXT."* ⭐ **THAT ONE IS ANSWERED
/// STRUCTURALLY AND IS NOT A TERM IN THIS POLICY — deliberately.** AppKit
/// resolves a nil-target `selectAll:` to the FIRST responder that claims it, and
/// every text surface sits nearer the front than the window our responder is
/// spliced behind. MEASURED for `selectAll:` specifically at m25-s (not merely
/// inherited from `copy:`): with a field editor focused the target became
/// `NSTextView` and our `validateMenuItem` was **not called at all** — the P4
/// result, reproduced for this selector, with `copy:` as the positive control.
///
/// So a policy term for text focus would be dead code AND a liability: the
/// responder classifier reads `NSApp.keyWindow.firstResponder`, which is not
/// observable, and `DeleteMenuPolicy` records what that costs an item's enabled
/// state. Both siblings omit it for the same pair of reasons.
public enum SelectAllMenuPolicy {

    /// What the native Edit ▸ Select All item reads — **in every state, live or
    /// greyed**.
    ///
    /// ⚠️⚠️ **THE BARE macOS WORDS, AND THAT IS THE USER'S OWN RULING APPLIED TO
    /// THIS ROW RATHER THAN A MISSED OPPORTUNITY.** A qualified "Select All
    /// Notes" is technically available — `validateMenuItem` CAN retitle these
    /// items and the retitle sticks (P3), and the display-time reset that keeps
    /// it honest works too (P5/P6), both measured at m25-f-1 and kept precisely
    /// so nobody re-measures them. It is not used, because `selectAll:` is a
    /// member of the SAME native pasteboard group (P2: Cut / Copy / Paste /
    /// Delete / **Select All**) that the user ruled on 2026-08-12: *"we do not
    /// need to use copy 3 clips… use common logic and commonly adopted partice
    /// for such behavior."* `ClipboardResponderRouting.plainTitle` states the
    /// consequence for that group as "the ONLY thing a native pasteboard item
    /// ever reads, in every state". Shipping a qualified title on the row
    /// directly below Copy would re-open a ruling three days old.
    ///
    /// ⭐ `DeleteMenuPolicy.inertTitle` ("Delete Selection") IS NOT A COUNTER-
    /// EXAMPLE: that title is on the app's OWN `Button` in `EditCommands`, which
    /// exists alongside macOS's native Delete and has to distinguish itself from
    /// it. This is the native item.
    public static let title = "Select All"

    /// Resolves the Edit ▸ Select All item: which surface it targets, and whether
    /// it is live.
    ///
    /// ═══ THE GUARD STACK, IN ORDER ═══
    ///
    ///   1. THE ROLL MUST BE THE ACTIVE SURFACE. Anything else — the arrange, the
    ///      Mix console, no clip open — refuses. `EditorSurface` already folds the
    ///      workspace and roll-open terms in (`EditorSurfaceRouter.resolve`), so
    ///      re-deriving either here would be the second computation this tree has
    ///      a census to prevent.
    ///   2. `!isModalPresented` — `DeleteMenuPolicy`'s second guard, kept for the
    ///      same reason and not a weaker one: acting on the user's music behind a
    ///      scrimmed panel they are looking at is a change they did not see. It is
    ///      not destructive here, but a selection silently swapped underneath a
    ///      sheet is still state they did not ask for, and BOTH siblings refuse
    ///      there — an item that behaved differently would need its own argument.
    ///   3. THERE MUST BE SOMETHING TO SELECT. A live item that provably does
    ///      nothing is the lie the disabled state exists to prevent, and the
    ///      house style already greys on exactly this
    ///      (`DeleteMenuRefusal.emptySelection`, `ClipboardRefusal.noTracks`).
    ///
    /// - Parameters:
    ///   - activeSurface: `AppModel.activeEditorSurface.surface` — the VERDICT of
    ///     the tree's one arbitration, never a re-derivation of its terms.
    ///   - isModalPresented: a blocking modal is on screen (`AppModel.isModalPresented`).
    ///   - rollNoteCount: how many notes the open clip holds.
    ///
    ///     ⚠️ **STORE TRUTH, NOT DRAFT TRUTH — and the divergence is named rather
    ///     than hidden.** The roll edits a `draft` that `PianoRollModel` keeps
    ///     `@State private`, so a `Commands` body and a `validateMenuItem` can
    ///     only see the committed clip. The two differ exactly while a gesture is
    ///     in flight, and the only shape that could grey a menu over VISIBLE notes
    ///     is "the clip has 0 committed notes while the draft has some" — which
    ///     needs an add that has not committed. Every add path in `PianoRollView`
    ///     commits at once (the double-tap add and the paste both call `commit(`,
    ///     which is why that file's `commit(` count is pinned), so the state is
    ///     unreachable outside the frames of a live gesture, and ⌘A mid-drag is
    ///     not a gesture a user makes. ⭐ THE ALTERNATIVE WAS WORSE: the bridge's
    ///     `surface` echo carries a live note count but is `@ObservationIgnored`
    ///     AND one body pass behind (measured — see
    ///     `awaitPianoRollMarqueeApplied`), so reading it would trade a
    ///     theoretical staleness for a measured one.
    public static func editMenuItem(
        activeSurface: EditorSurface,
        isModalPresented: Bool,
        rollNoteCount: Int
    ) -> SelectAllMenuItem {
        guard activeSurface == .pianoRoll else {
            return SelectAllMenuItem(refusedBy: .notPianoRoll)
        }
        guard !isModalPresented else { return SelectAllMenuItem(refusedBy: .modal) }
        guard rollNoteCount > 0 else { return SelectAllMenuItem(refusedBy: .emptyRoll) }
        return SelectAllMenuItem(surface: .pianoRollNotes)
    }
}

/// Which surface a Select All acts on.
///
/// ⚠️ **ONE CASE, AND THAT IS THE POINT RATHER THAN AN UNFINISHED ENUM.** A sum
/// type with a single case forces the arrange to arrive as a `nil` surface — an
/// explicit refusal a caller must handle — instead of as a default that some
/// later edit could quietly point at clips. `DeleteSurface`'s note ("a fourth
/// deletable surface must be routed, not silently defaulted to the arrange")
/// states the same rule from the other end.
public enum SelectAllSurface: String, Sendable, CaseIterable, Equatable {
    case pianoRollNotes = "piano-roll-notes"
}

/// WHY Edit ▸ Select All is inert, named for the guard that refused.
///
/// Carried rather than discarded for `DeleteMenuRefusal`'s reason: a bare
/// `isEnabled == false` cannot tell a test that meant to prove the MODAL guard
/// from one whose roll had quietly emptied, which is how a dead policy passes a
/// refusal-only suite.
public enum SelectAllRefusal: String, Sendable, Equatable, CaseIterable {
    /// The user is working in the arrange, or in the Mix console, or has no clip
    /// open — `EditorSurfaceRouter`'s verdict was `.arrange`.
    ///
    /// ⚠️ THE COMMONEST STATE IN THE APP, AND IT IS NOT A BUG. m25-s deliberately
    /// does not invent an arrange-wide select-all; here ⌘A greys out, exactly as
    /// it did before this feature existed (MEASURED: with nothing claiming
    /// `selectAll:`, `NSApp.target(forAction:)` answers nil and the native item is
    /// already disabled).
    case notPianoRoll = "not-piano-roll"
    case modal
    /// The roll is active but its clip holds no notes — nothing to select.
    case emptyRoll = "empty-roll"
}

/// The resolved Edit ▸ Select All item.
public struct SelectAllMenuItem: Equatable, Sendable {
    /// What the menu says. **Constant** — see `SelectAllMenuPolicy.title` for the
    /// ruling behind that, and note it is carried on the struct anyway so a future
    /// retitle is one line in the policy rather than a new field on the wire
    /// between the policy and the responder.
    public var title: String
    /// The surface the item acts on; nil when inert.
    public var surface: SelectAllSurface?
    /// Which guard refused; nil when the item is live.
    public var refusedBy: SelectAllRefusal?

    /// DERIVED, never stored — `DeleteMenuItem`'s rule: "there is a surface to act
    /// on" and "the item is clickable" are the same fact, and a stored twin could
    /// drift from it.
    public var isEnabled: Bool { surface != nil }

    public init(surface: SelectAllSurface? = nil, refusedBy: SelectAllRefusal? = nil) {
        self.title = SelectAllMenuPolicy.title
        self.surface = surface
        self.refusedBy = refusedBy
    }
}
