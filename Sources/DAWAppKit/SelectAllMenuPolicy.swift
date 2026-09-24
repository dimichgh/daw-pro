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
/// ═══ ⭐⭐ OVERRULED BY THE USER AT m34-d (2026-08-30) — OPEN, NOT ENGAGED ═══
///
/// **THIS POLICY SHIPPED ON THE ENGAGEMENT VERDICT AND THE USER REPORTED IT AS A
/// BUG:** *"⌘A does nothing on the first press."* Opening a clip shows the roll
/// but did not yet count as being *in* it; one click inside and ⌘A worked every
/// time. They were shown the choice and ruled, **verbatim:**
///
/// > ***"Make it work whenever the editor is open."***
///
/// So the first guard now reads `EditorSurfaceRouter.openSurface` — "is the roll
/// ON SCREEN" — and no longer `resolve` — "did the user last ENGAGE the roll".
/// ⚠️ **THE PARAGRAPH THAT USED TO STAND HERE CALLED THAT BEHAVIOUR AN ACCEPTED
/// CONSEQUENCE**, citing Logic's active-area model and "one answer, one place".
/// It was a defensible design and it was wrong in the user's hands; it is
/// recorded here rather than deleted so nobody re-derives it from first
/// principles and quietly re-lands it.
///
/// ⭐ **WHAT MADE ⌘A SAFE TO WIDEN, WHERE ⌘+ AND ⌫ ARE NOT.** Acting on OPEN-ness
/// means acting on a surface the user has not touched yet, so the act must be one
/// that cannot be mistaken for an act on the *other* surface:
///
///   • ⌘A **has no other meaning anywhere in this app.** m25-s deliberately did
///     not invent an arrange-wide select-all (see the scope note below, still
///     live), so with the roll open there is nothing else ⌘A could have meant —
///     acting immediately steals from nothing and destroys nothing.
///   • ⌘+ / ⌘− / ⌘0 **both surfaces zoom**, so "open" would zoom the one the user
///     is not working in. They keep `resolve`.
///   • ⌫ **is destructive AND both surfaces claim it.** It keeps a third term
///     again (`pianoRollWouldConsumeKey`), and m34-d deliberately did NOT change
///     it — see the sibling section below.
///
/// ⚠️ **AND THE FIX IS NOT IN `resolve`.** `EditorSurfaceRouter`'s banner offers
/// "drop the `lastEngaged` term" as the one-line overrule, and taking that line
/// would have re-routed ⌘+/⌘−/⌘0 too, on a ruling that named one keystroke. The
/// router grew a SECOND verdict instead, implemented on top of the first so the
/// shared terms cannot drift. This policy still takes a VERDICT, never its terms:
/// no `openEditorClip`, no workspace flag, no focus, no second arbitration.
///
/// ═══ WHY THIS READS A ROUTER VERDICT AND ITS TWO SIBLINGS DO NOT ═══
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
/// was unnecessary. m34-d is the same argument one notch further out: gating it
/// on "the user already clicked in here" made it reachable only after the gesture
/// that would have told them where they were.
///
/// ⚠️ **SO ⌫ IS NOT A CANDIDATE FOR THIS TERM AND WAS NOT GIVEN IT.** The
/// roadmap notes that splitting the two is a real architectural choice; it is
/// made HERE, on purpose, and the asymmetry is the answer rather than a
/// leftover. Delete asks "would this surface CONSUME the key", which needs a live
/// note selection; select-all asks "is this surface IN FRONT OF THE USER", which
/// must not. Unifying them would either make ⌫ destroy notes in a roll the user
/// has not touched, or put select-all back behind a selection that does not exist
/// yet. Three items, three questions, three terms.
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
    ///   1. THE ROLL MUST BE **OPEN** (m34-d — was "must be the ACTIVE surface").
    ///      The Mix console and "no clip open" still refuse, each under its own
    ///      name. `OpenEditorSurface` already folds the workspace and roll-open
    ///      terms in (`EditorSurfaceRouter.openSurface`), so re-deriving either
    ///      here would be the second computation this tree has a census to
    ///      prevent.
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
    ///   - openSurface: `AppModel.openEditorSurface` — the VERDICT of the tree's
    ///     one arbitration, never a re-derivation of its terms.
    ///
    ///     ⚠️ **THE WHOLE VERDICT, NOT ITS `.surface`, AND THAT IS WHAT BUYS THE
    ///     TWO NAMED REFUSALS BELOW.** A bare `EditorSurface` (what this
    ///     parameter used to be) collapses "the Mix console is up" and "no clip
    ///     is open" into one `.arrange` — two different bugs with two different
    ///     fixes, and `SelectAllRefusal`'s own doc is why that collapse is not
    ///     acceptable in a refusal. The `.reason` is switched on rather than the
    ///     `.surface` for exactly that reason; the two agree by construction
    ///     (`.rollOpen` is the only reason that carries `.pianoRoll`).
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
        openSurface: OpenEditorSurface,
        isModalPresented: Bool,
        rollNoteCount: Int
    ) -> SelectAllMenuItem {
        switch openSurface.reason {
        case .notArrangeWorkspace:
            return SelectAllMenuItem(refusedBy: .notArrangeWorkspace)
        case .noRollOpen:
            return SelectAllMenuItem(refusedBy: .noRollOpen)
        case .rollOpen:
            break
        case .pitchEditorOpen:
            // ⛔ m23-ap p2-b — REFUSED BY NAME, NOT ROUTED. ⌘A means "select all
            // NOTES" in this app and nowhere else; a pitch SEGMENT is not a
            // note, and the pitch editor's Increment A is read-only and has no
            // selection at all. Design §3.6 assigns ⌘A-inside-the-pitch-editor
            // to the (unwritten) interaction model, §7 — so until the user's
            // TUNE X video settles it, the honest answer is a greyed item with
            // its own reason, never a silent fall-through to `noRollOpen` that
            // would tell a red gate "no clip is open" about a pane that is
            // plainly on screen.
            return SelectAllMenuItem(refusedBy: .pitchEditorOpen)
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
    /// The **Mix console** is up, so no `PianoRollView` is mounted at all —
    /// `EditorSurfaceRouter.openSurface`'s `.notArrangeWorkspace`.
    ///
    /// ⚠️ SEPARATE FROM `noRollOpen` SINCE m34-d, and the split is the point
    /// rather than tidiness. The two used to share one `.notPianoRoll`, which was
    /// tolerable while the guard was `activeSurface == .pianoRoll` (one term, one
    /// answer). Now that the guard IS the openness verdict, a single refusal
    /// would tell a red test "the roll was not open" for a fixture whose real
    /// problem is that it left the app in the mixer — the "three different bugs"
    /// argument `ActiveEditorSurface.Reason` makes, applied to the refusal side.
    case notArrangeWorkspace = "not-arrange-workspace"
    /// The arrange workspace is live but **no MIDI clip is open** — there is no
    /// roll on screen to select notes in.
    ///
    /// ⚠️ THE COMMONEST STATE IN THE APP, AND IT IS NOT A BUG. m25-s deliberately
    /// does not invent an arrange-wide select-all; here ⌘A greys out, exactly as
    /// it did before this feature existed (MEASURED: with nothing claiming
    /// `selectAll:`, `NSApp.target(forAction:)` answers nil and the native item is
    /// already disabled).
    ///
    /// ⭐ **AND THE STATE THAT USED TO REACH THIS REFUSAL AND NO LONGER DOES IS
    /// THE WHOLE OF m34-d:** roll open, arrange engaged. That refused before the
    /// user ruled on it; it is now the LIVE case.
    case noRollOpen = "no-roll-open"
    case modal
    /// The roll is active but its clip holds no notes — nothing to select.
    case emptyRoll = "empty-roll"
    /// The **pitch editor** is the open pane (m23-ap p2-b). ⌘A has no meaning
    /// there yet: Increment A is read-only and holds no selection, and design
    /// §3.6 assigns the gesture to the unwritten interaction model (§7).
    ///
    /// ⚠️ **NOT `noRollOpen`.** A pane IS open; saying "no clip is open" about a
    /// surface the user is looking at is the conflation
    /// `ActiveEditorSurface.Reason`'s "three different bugs" argument exists to
    /// prevent, and it would make a red gate chase the wrong fixture.
    case pitchEditorOpen = "pitch-editor-open"
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
