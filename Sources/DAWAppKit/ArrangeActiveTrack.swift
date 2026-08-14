import Foundation
import DAWCore

// THE ACTIVE TRACK (m25-l-1) — "where I am" in the arrange, and the ONE place
// that answers it. Headless (no SwiftUI, no AppKit) for `ArrangeTrackSelection`'s
// stated reason: `DAWApp` has no test target, so a rule decided inside a SwiftUI
// `body` — or inside the `AppModel` — would be invisible to `Tests/`.
//
// ═══ THE ACTIVE TRACK IS A CURSOR, NOT A SELECTION ═══
//
// This is the distinction the whole design turns on, and it is what lets the
// concept exist without reopening anything `ArrangeTrackSelection`'s banner
// closed. A SELECTION is *what a verb acts on*; the active track is *where the
// next thing goes* — the arrange's insertion point, the text caret's analogue.
//
// Every consequence the old prohibition protected therefore survives intact:
//
//   • The active track is NOT a member of `ArrangeSelection.ids`. Nothing here
//     writes to a selection at all.
//   • Group DELETE still removes exactly `ids`, so it remains structurally
//     incapable of being ambiguous about whether it deletes clips or a whole
//     track. That was the destructive-verb ambiguity the alternative would have
//     bought, and it is still not bought.
//   • A mixed track+clip selection is still just a bigger `ids` set.
//
// What changes is only that "which track" now has an answer when nothing is
// selected — which is the user's report (m25-l): *"user should be able to select
// a track which becomes active for any implicit or explicit actions."* The
// prohibition in `ArrangeTrackSelection` was explicitly conditional — *"ships
// only on the user's word"* — and that word has now been given.
//
// ═══ ONE HOME, TWO INPUTS ═══
//
// `resolve` is the SINGLE point that answers "which track". It takes two inputs
// at documented precedence and returns one answer. Do NOT add a parallel lookup
// beside it: before this existed the paste path derived its target inline
// (`DAWProApp.swift`, "the track owning `arrangeSelection.focusID`"), and a
// second expression of the same question is the one-home violation this
// codebase repeatedly pays for.
//
// ═══ m25-l-3: THE ANSWER CARRIES ITS PROVENANCE ═══
//
// `resolve` returned a bare `UUID?` until m25-l-3, and that lost the one fact
// its consumer most needed. The two precedence terms are not interchangeable —
// term 1 is a DELIBERATE statement (a header click), term 2 is an INFERENCE
// (whatever clip happens to be focused) — but collapsing both into an id made
// them indistinguishable downstream, where the id is also almost never nil.
// `PasteAnchorPolicy` therefore could not ask the question it actually needs to
// ask. "Is there an active track?" is the wrong question and answers yes nearly
// always; **"did the user deliberately choose a track?"** is the right one.
// `Resolution` is that distinction made visible.
//
// ⚠️ WHAT THIS IS NOT: it is not `ContentView.trackID(ofClip:)` nor
// `isDrumKitTrack(ofClip:)`. Those resolve the owner of a NAMED clip — the open
// editor's clip, a specific fix target. Same shape, different question: they ask
// "who owns THIS clip", this asks "where is the user". Folding them together
// would make the note editor's track depend on which header was last clicked.
public enum ArrangeActiveTrack {

    /// HOW "where I am" was arrived at (m25-l-3) — the provenance of the answer,
    /// not a second answer.
    ///
    /// ⭐ **THIS IS THE DISCRIMINATOR A PASTE STEERS ON**, so read
    /// `PasteAnchorPolicy.resolveClipPaste` before changing either case's
    /// meaning. A `String` raw value so the `debug.arrangeSelection` and
    /// `debug.editClipboard` seams can echo the decision verbatim (the
    /// `ArrangeTrackClickEffect` / `NotePasteMode` convention) — a leg that read
    /// back only the id could not tell "the user pointed here" from "this is
    /// merely where the last selected clip lives", which is exactly the
    /// distinction the paste turns on.
    public enum Origin: String, Sendable, CaseIterable, Equatable {
        /// Term 1 — a HEADER CLICK. The user said this, in as many words.
        case explicit
        /// Term 2 — the owner of the focused clip. Nobody stated a track; this
        /// is where the app *infers* the user to be from what they last touched.
        case inferred
    }

    /// WHERE THE USER IS, and HOW WE KNOW — the whole answer, as one value.
    ///
    /// ONE VALUE RATHER THAN TWO PARAMETERS, and that is a correctness choice
    /// with precedent in this module. The alternative considered at m25-l-3 was
    /// threading an `explicitTrackID` alongside the existing `activeTrackID`
    /// into `resolveClipPaste`. Two ids side by side can NAME DIFFERENT TRACKS —
    /// an invalid state, representable, with no defined behaviour — which is the
    /// same hazard `ArrangeTrackClickOutcome`'s `fileprivate init` exists to
    /// close ("an intent/effect/ids/changed QUADRUPLE the rule would not have
    /// produced is UNREPRESENTABLE"). Here the id and its provenance cannot
    /// disagree because there is only one id.
    ///
    /// ⚠️ `resolve` is the ONLY producer in shipped code, and a right-click
    /// destination (m25-f-4) is expected to reach it by feeding `explicit:`
    /// rather than by building one of these. The memberwise init is public
    /// anyway, for `PasteAnchorPolicy`'s own stated reason about pure public
    /// functions: its behaviour on a `Resolution` naming a track that is not in
    /// the `tracks` argument is a DEFINED, TESTED property (it degrades to the
    /// in-place rule), not an accident of who happened to call it.
    public struct Resolution: Equatable, Sendable {
        /// The track. Live at the moment `resolve` produced it; re-checked by
        /// any consumer that takes `tracks` separately.
        public let id: UUID
        /// Which precedence term produced `id`.
        public let origin: Origin

        public init(id: UUID, origin: Origin) {
            self.id = id
            self.origin = origin
        }
    }

    /// WHERE THE USER IS — the track a paste is aimed at, and the answer
    /// any future "implicit action" should consume rather than re-derive.
    ///
    /// ═══ PRECEDENCE, AND WHY IT IS THIS WAY ROUND ═══
    ///
    /// 1. **`explicit`, when it names a LIVE track → `.explicit`.** A header
    ///    click is a direct statement of intent and must beat anything inferred.
    ///    This is the whole point of the item: with no clip selected there is no
    ///    focus, so before this term existed there was no track and a paste fell
    ///    back to "the first track in store order that can hold the payload's
    ///    topmost clip" (`PasteAnchorPolicy.resolveClipPaste`, `.relocated`).
    /// 2. **The track owning `focusClipID` → `.inferred`.** The pre-existing
    ///    behaviour, kept verbatim: a user who clicked a CLIP has said something
    ///    about where they are, and has always been answered this way. It is
    ///    still an INFERENCE, though — the clip was clicked to select it, not to
    ///    nominate its track — and m25-l-3 turns on exactly that difference.
    /// 3. **nil.** No statement, no inference — the policy's own fallback runs.
    ///
    /// ⚠️ **THE STALENESS RULE IS RESOLUTION, NEVER INVALIDATION.** `explicit` is
    /// stored raw and checked against `tracks` on every read, so deleting the
    /// active track needs no observer, no notification and no cleanup pass — it
    /// simply stops resolving and the focus term takes over. That is exactly how
    /// the focus term itself has always behaved (a stale focus id yields nil),
    /// and it is why removing a track cannot leave a dangling pointer to it.
    ///
    /// ⚠️ **A ZERO-CLIP TRACK IS A LEGITIMATE ANSWER, and it is the sharpest case
    /// the item exists for.** An empty track can never win term 2 — it owns no
    /// clip, so no focus can resolve to it — which is precisely why "you cannot
    /// paste onto an empty track" was true. Term 1 has no clip predicate at all,
    /// so an empty track resolves like any other. **Do not add an
    /// `isEmpty`/`canHold` guard here**: whether a track can hold the payload is
    /// `PasteAnchorPolicy`'s question (via `Track.canHold`), asked per clip and
    /// reported as a skip with a reason. Pre-filtering here would turn a named,
    /// explainable skip into a silent redirection to some other track.
    ///
    /// - Parameters:
    ///   - explicit: the last header-clicked track id. May be stale.
    ///   - focusClipID: `ArrangeSelection.focusID` — the anchor CLIP, if any.
    ///   - tracks: the project's live tracks, in store order.
    /// - Returns: the active track WITH ITS PROVENANCE, or nil when the user has
    ///   stated nothing and nothing can be inferred.
    public static func resolve(explicit: UUID?,
                               focusClipID: UUID?,
                               tracks: [Track]) -> Resolution? {
        if let explicit, tracks.contains(where: { $0.id == explicit }) {
            return Resolution(id: explicit, origin: .explicit)
        }
        guard let focusClipID else { return nil }
        guard let owner = tracks.first(where: { $0.clips.contains { $0.id == focusClipID } })
        else { return nil }
        return Resolution(id: owner.id, origin: .inferred)
    }
}
