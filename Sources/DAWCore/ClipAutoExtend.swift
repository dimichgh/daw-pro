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
        // 1. Already covered → not an extension, not an edit.
        guard coveringEndBeat > currentLengthBeats + epsilon else { return nil }

        // 2. Next bar line at or after the covered end.
        var target = barSnappedLength(coveringEndBeat, beatsPerBar: beatsPerBar)

        // 3. Ceilings. Both are hard; either may break bar alignment.
        let bpb = Double(Swift.max(1, beatsPerBar))
        target = Swift.min(target, currentLengthBeats + Double(maxGrowthBars) * bpb)
        if let maxLengthBeats { target = Swift.min(target, maxLengthBeats) }
        guard target > currentLengthBeats + epsilon else { return nil }

        // 4. Would the note actually sound? Engine truth is a STRICT `<` on the
        //    onset (`PianoRollModel.playableEndBeat`, `MIDISchedule.buildEvents`)
        //    — an onset exactly AT the new end is still latent.
        guard coveringOnsetBeat < target else { return nil }
        return target
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
