import Foundation

/// THE ONE RULE for "grow a MIDI clip so a note the user just placed actually
/// sounds" (m25-a). Pure value math, no store, no UI — so the two gestures that
/// need it cannot drift apart:
///
///  - **m25-a — double-click-to-create past the clip end** (`PianoRollView`'s
///    `SpatialTapGesture(count: 2)` → `commit(extendToCover:)`).
///  - **m25-f-3 — the note DRAG that reaches the clip edge.** It calls this
///    through the SAME store verb (`setClipNotes(clipID:notes:extendToCover:)`)
///    with the dragged ids; nothing here changes for it.
///
/// The user ruled on 2026-08-13 (*"extend in both as you suggested"*) that BOTH
/// paths auto-extend. Clamping/refusing the note was explicitly rejected.
///
/// ⚠️ **THIS DOES NOT MAKE OUT-OF-RANGE NOTES ILLEGAL.** The m18-f/m19-g
/// "legal-but-latent" rule (`PianoRollModel.drawnWidth` / `playableEndBeat`)
/// survives untouched: a note past the clip end is still store-legal, still
/// drawn, still engine-windowed by strict `<`. Auto-extend only means the clip
/// GROWS to cover a note the user just placed, so that note becomes AUDIBLE.
/// Every other route to a past-the-end note (AI authoring, `clip.setNotes` over
/// the wire, paste, a shrinking trim) still produces latent data, and this
/// namespace is never consulted on those paths.
///
/// ## Wire decision (m25-a): NO new command, and no new parameter either
///
/// The house rule is that every user-facing CAPABILITY ships a control command
/// and an MCP tool. m25-a adds no capability — it changes how one existing
/// gesture behaves. Concretely:
///
///  - **Nothing becomes unreachable to an agent.** Growing a clip is already
///    two wire verbs deep: `clip.fitToContent` and `clip.stretchToLength`. An
///    agent that wants the m25-a outcome writes the notes and calls one of
///    them; it does not need a gesture's convenience bundled into one call.
///  - **`extendToCover` is deliberately NOT plumbed onto `clip.setNotes`.**
///    Doing so would change a shipped verb's contract and drag in its
///    `CopilotCatalog` entry, spending real surface to expose a shortcut for
///    something already expressible — and the auto-extend default an AGENT
///    wants is "off": batch note-writing that silently reshaped clip geometry
///    would be a worse tool, not a better one.
///  - **Coverage does not depend on the wire here.** The rule is a pure
///    function in `DAWCore` and the store verb is `@MainActor` domain code, so
///    the Swift suite reaches both directly (`ClipAutoExtendTests`,
///    `ClipAutoExtendAudibilityTests`) — no `debug.*` staging seam is needed to
///    observe it, which is the usual reason a UI-only rule earns wire surface.
///
/// If m25-f-3 or a later item ever needs an agent to drive auto-extend, the
/// additive move is a NEW verb (`clip.setNotesExtending`), not a mutation of
/// `clip.setNotes` — live commands are never renamed or re-contracted.
public enum ClipAutoExtend {

    /// Float slack for the "is it already covered?" comparisons. Beats arrive
    /// snapped to grid fractions (1/64 = 0.015625, triplets are not exact), so
    /// an exact `==` would grow a clip by a bar over a rounding crumb.
    private static let epsilon: Double = 1e-9

    /// The most a single gesture may grow a clip, in BARS. A double-click lands
    /// anywhere the grid is drawn, and the grid is drawn to the viewport edge
    /// (`PianoRollModel.drawnWidth`), so at a zoomed-OUT scale a stray click can
    /// be dozens of bars past the end. Growing a 4-bar clip to 90 bars because
    /// of one mis-aimed click is not an edit the user asked for.
    ///
    /// 16 bars is deliberately generous rather than tight: at the default
    /// 32 px/beat in 4/4 a bar is 128 px, so a ~1400 pt viewport reaches about
    /// 11 bars past the clip end — the cap sits beyond every click a normally
    /// zoomed editor can produce, and only bites when the user is zoomed far
    /// out. Past the cap the note stays LATENT (the pre-existing documented
    /// behaviour, shade and hairline still showing) rather than silently
    /// reshaping the arrangement.
    public static let maxGrowthBars: Int = 16

    /// The span a set of notes needs the clip to cover: the furthest END (what
    /// the clip must reach) and the furthest ONSET (what must land strictly
    /// inside the clip for the engine to schedule it at all).
    ///
    /// Returns nil when none of `ids` is present in `notes` — the honest answer
    /// for a caller that named notes the submission does not contain.
    ///
    /// ⚠️ **`ids` IS NOT OPTIONAL SUGAR — IT IS THE WHOLE REASON THIS IS SAFE.**
    /// `setClipNotes` receives the piano roll's ENTIRE draft, which may already
    /// hold latent notes far past the end (legal-but-latent data authored by an
    /// AI, a paste, or an earlier trim). Deriving the required span from ALL
    /// notes would mean that adding one note at bar 2 resurrects a forgotten
    /// note at bar 20 and stretches the clip to it. Only the notes the CURRENT
    /// gesture touched may move the clip's edge.
    public static func coverage(of notes: [MIDINote], ids: Set<UUID>)
        -> (onsetBeat: Double, endBeat: Double)? {
        guard !ids.isEmpty else { return nil }
        var onset = -Double.infinity
        var end = -Double.infinity
        for note in notes where ids.contains(note.id) {
            onset = Swift.max(onset, note.startBeat)
            end = Swift.max(end, note.endBeat)
        }
        guard onset.isFinite, end.isFinite else { return nil }
        return (onset, end)
    }

    /// The clip's new length, or nil to leave the clip ALONE.
    ///
    /// The rule, in order:
    ///  1. **Already covered?** If the covered end already fits, nothing happens
    ///     — creating a note INSIDE the clip never resizes it.
    ///  2. **Grow to the next BAR LINE at or after the covered end**, not to the
    ///     note's exact end. See `barSnappedLength` for why.
    ///  3. **Two ceilings, whichever is lower**: `maxGrowthBars` past the
    ///     current length, and `maxLengthBeats` (the caller's headroom — the
    ///     distance to the next clip on the track). Both override the bar
    ///     alignment, so a clamped result can be mid-bar; butting exactly
    ///     against a neighbour is worth more than a tidy length.
    ///  4. **Audibility test.** If, after the ceilings, the covered ONSET is not
    ///     STRICTLY inside the new length, return nil and change NOTHING. This
    ///     is the case that would otherwise be the worst of both worlds: the
    ///     clip's geometry changes (and the user has an undo entry to deal with)
    ///     while the note they placed is still silent. Refusing leaves exactly
    ///     the documented latent-note behaviour they had before.
    ///
    /// - Parameters:
    ///   - currentLengthBeats: the clip's length now.
    ///   - coveringOnsetBeat: clip-local onset that must become audible.
    ///   - coveringEndBeat: clip-local end the clip should reach.
    ///   - beatsPerBar: the meter at the clip's start (`MeterMap.beatsPerBar`).
    ///     The piano roll draws its bar emphasis at clip-local multiples of this
    ///     (`PianoRollGrid.drawGridLines`, `b % beatsPerBar == 0` counted from
    ///     clip-local 0), so a bar-snapped length lands the clip's end exactly
    ///     on a line the user can already see.
    ///   - maxLengthBeats: the longest this clip may become without colliding
    ///     with the next clip on its track, or nil when nothing follows it.
    ///     ⚠️ **NOT OPTIONAL IN PRACTICE — see the doc on the store verb.**
    ///     Growing over a same-track neighbour would send the grow through
    ///     `resolvingOverlaps`, which TRIMS OR DELETES the stationary clip. A
    ///     double-click in the piano roll must never destroy part of a clip the
    ///     user is not even looking at.
    public static func extendedLength(
        currentLengthBeats: Double,
        coveringOnsetBeat: Double,
        coveringEndBeat: Double,
        beatsPerBar: Int,
        maxLengthBeats: Double? = nil
    ) -> Double? {
        // ⚠️ A THIN WRAPPER, AND THAT IS THE POINT (m25-a-2). The rule lives in
        // `outcome(...)` and NOWHERE ELSE. A sibling `reason(...)` recomputing
        // the same decision from the same inputs would be a SECOND HOME that
        // drifts the first time either is touched; this shape makes drift a
        // compile error instead. It is also the report-only proof: m25-a-2
        // changes which WORDS the user sees and not one growth decision, and the
        // way you can tell is that every caller of this function still receives
        // the number this function always returned.
        if case .grew(let length) = outcome(
            currentLengthBeats: currentLengthBeats,
            coveringOnsetBeat: coveringOnsetBeat,
            coveringEndBeat: coveringEndBeat,
            beatsPerBar: beatsPerBar,
            maxLengthBeats: maxLengthBeats) {
            return length
        }
        return nil
    }

    /// What auto-extend DID, named (m25-a-2).
    ///
    /// ⭐ **THE CASE THAT MATTERS IS `.notNeeded`, AND IT IS NOT A REFUSAL.**
    /// `extendedLength` collapses four distinct outcomes into one `nil`, and the
    /// most common of them by far is "the notes already fit" — which fires on
    /// essentially every note edit INSIDE a clip. Anything that warns the user on
    /// a bare `nil` therefore warns on every ordinary edit, which is far worse
    /// than the silence m25-a-2 exists to fix. Switch over this enum
    /// EXHAUSTIVELY and never write `default:`: the compiler forcing a human to
    /// say what `.notNeeded` means is the whole safety property.
    public enum ExtendOutcome: Equatable, Sendable {
        /// The notes already fit — nothing was wrong and nothing was done.
        /// **Say nothing to the user.**
        case notNeeded
        /// The clip grew to this new length in beats.
        case grew(Double)
        /// Refused: the note is further past the clip's end than one gesture may
        /// grow it (`maxGrowthBars`). Remedy: place the note nearer, or lengthen
        /// the clip deliberately first.
        case refusedByGrowthCap
        /// Refused: the next clip on the same track is in the way. Remedy: move
        /// that clip later, or place the note inside this one. **The tiebreak
        /// when both ceilings bind** — see `outcome(...)`.
        case refusedByNeighbour
        /// Refused: no ceiling was in the way, but the onset still would not be
        /// STRICTLY inside the grown clip, so the note would stay silent anyway.
        ///
        /// ⚠️ **REACHABLE ON THIS PURE FUNCTION (1,452,018 of a 52 M sweep), AND
        /// ARGUED — NOT MEASURED — TO BE UNREACHABLE THROUGH THE STORE.** The
        /// argument: `coverage(of:ids:)` takes the max onset and the max end over
        /// the same notes, and `MIDINote.minLengthBeats` is 0.001, so the max
        /// onset is always at least a hair BELOW the max end and therefore below
        /// the bar-snapped target. That is CODE REASONING over a constant in
        /// another file; no store-level fixture was ever observed reaching here,
        /// which is a different and weaker statement than one that was.
        /// It is kept because this function is public and
        /// its two beat parameters are independent — a caller may pass anything,
        /// and folding this into a ceiling case would make the message lie while
        /// returning a length instead would change a growth decision. Do not
        /// delete it on a reachability argument that rests on a constant in
        /// another file.
        case refusedOnsetStillLatent
    }

    /// THE decision, named. `extendedLength` is a wrapper over this.
    ///
    /// Same rule, same order, same arithmetic as before — the only thing added is
    /// that each `nil` now says which of the four things happened.
    ///
    /// ## Which ceiling bound, and why the min-chain cannot answer it
    ///
    /// `target` is `min(barTarget, growthCeiling, maxLengthBeats)`. Once the mins
    /// have run, a clamped `target` cannot say which ceiling clamped it — so this
    /// compares the CEILING VALUES, which are both still in scope, rather than
    /// re-deriving from the result. Naming the wrong one is not cosmetic: it
    /// sends the user to move a neighbouring clip when the growth cap was the
    /// real constraint, and the remedy it names does not work.
    ///
    /// ⭐ **TIEBREAK, PINNED BY A TEST: when the two ceilings sit at the SAME
    /// value, the blame is `.refusedByNeighbour`.** It is the more actionable
    /// obstacle and the only one of the two the user can actually SEE — a clip
    /// sitting right there on the track, which they can drag. The growth cap is
    /// an invisible policy constant.
    ///
    /// ## Where each refusal actually comes from — MEASURED, not assumed
    ///
    /// A 52,254,720-fixture sweep of this arithmetic (m25-a-2) found:
    ///
    ///  - **The "ceilings squeezed it flat" refusal is ALWAYS the neighbour.**
    ///    `growthCeiling` is `currentLengthBeats + maxGrowthBars * bpb` with
    ///    `bpb >= 1` and `maxGrowthBars` 16, so it is never within epsilon of the
    ///    current length; only `maxLengthBeats` can push `target` down to it.
    ///    Zero of the 52 M fixtures reached that refusal with `maxLengthBeats`
    ///    nil, and zero reached it with the cap as the binding ceiling. That case
    ///    means the neighbour is already FLUSH: no growth was ever possible.
    ///  - **The growth cap bites at the AUDIBILITY test instead.** A note dozens
    ///    of bars past the end clamps `target` to the cap, and the onset then
    ///    sits far beyond it. Blaming that on "the note is exactly at the clip's
    ///    edge" would be flatly false, which is why the audibility refusal is
    ///    split by ceiling rather than reported as one thing.
    public static func outcome(
        currentLengthBeats: Double,
        coveringOnsetBeat: Double,
        coveringEndBeat: Double,
        beatsPerBar: Int,
        maxLengthBeats: Double? = nil
    ) -> ExtendOutcome {
        // 1. Already covered → not an extension, not an edit, and NOT A REFUSAL.
        guard coveringEndBeat > currentLengthBeats + epsilon else { return .notNeeded }

        // 2. Next bar line at or after the covered end.
        let barTarget = barSnappedLength(coveringEndBeat, beatsPerBar: beatsPerBar)

        // 3. Ceilings. Both are hard; either may break bar alignment. Kept as
        //    NAMED VALUES rather than folded straight into `target`, because the
        //    blame below needs them after the mins have collapsed them.
        let bpb = Double(Swift.max(1, beatsPerBar))
        let growthCeiling = currentLengthBeats + Double(maxGrowthBars) * bpb
        var target = Swift.min(barTarget, growthCeiling)
        if let maxLengthBeats { target = Swift.min(target, maxLengthBeats) }

        /// Which obstacle to name once we know the grow is refused.
        ///
        /// The comparisons are EXACT, deliberately without epsilon: `target` is
        /// literally one of the three values, so `target < barTarget` is true
        /// exactly when some ceiling clamped the ideal. An epsilon here would
        /// only blur a decision that has no float error in it.
        func blame() -> ExtendOutcome {
            // Nothing clamped the bar-snapped ideal, so neither ceiling is the
            // obstacle — the onset itself is.
            guard target < barTarget else { return .refusedOnsetStillLatent }
            // `<=`, not `<`: THE TIEBREAK. Equal ceilings blame the neighbour.
            if let maxLengthBeats, maxLengthBeats <= growthCeiling { return .refusedByNeighbour }
            return .refusedByGrowthCap
        }

        // 3b. No room at all after the ceilings.
        guard target > currentLengthBeats + epsilon else { return blame() }

        // 4. Would the note actually sound? Engine truth is a STRICT `<` on the
        //    onset (`PianoRollModel.playableEndBeat`, `MIDISchedule.buildEvents`)
        //    — an onset exactly AT the new end is still latent.
        guard coveringOnsetBeat < target else { return blame() }
        return .grew(target)
    }

    /// `endBeat` rounded UP to a whole number of bars.
    ///
    /// ⚠️ **GROW-TO-GRID, NOT GROW-TO-EXACT — a recorded decision, not a
    /// detail.** Fitting the clip to the note's exact end produces lengths like
    /// 6.25 or 9.0625 beats: every stray sixteenth the user places would leave
    /// the clip a shape no other part of this editor produces. Bars are the unit
    /// the roll draws (`drawGridLines` emphasises `b % beatsPerBar == 0`), the
    /// unit its own bar ops work in (`PianoRollBarOps`), and the unit the
    /// default new clip already uses. Snapping up means the clip end lands on a
    /// line already on screen, and it is generous in the right direction: the
    /// note is comfortably inside the clip rather than flush against its edge,
    /// which matters because the engine truncates a tail landing exactly at the
    /// end. `fitClipToContent` deliberately keeps the OTHER rule (exact content
    /// length) because that verb's contract is "match the content"; this one's
    /// is "make room for it".
    ///
    /// Meter-aware: 3 beats per bar in 3/4, 7 in 7/8.
    public static func barSnappedLength(_ endBeat: Double, beatsPerBar: Int) -> Double {
        let bpb = Double(Swift.max(1, beatsPerBar))
        guard endBeat > 0 else { return bpb }
        let bars = (endBeat / bpb).rounded(.up)
        let snapped = bars * bpb
        // A float crumb below the true end would leave the note overhanging by a
        // hair — round up one more bar rather than ship a length that fails its
        // own purpose.
        return snapped < endBeat - epsilon ? snapped + bpb : snapped
    }
}
