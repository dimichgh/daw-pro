import Foundation
import DAWCore

// The VERTICAL axis of an arrange body drag (m25-l-2) — "which lane is the
// pointer over, and what will the drop actually achieve". Headless (no SwiftUI,
// no AppKit) in the `ArrangeGroupDrag` / `ArrangeBodyDrag` / `ArrangeNudge`
// tradition, because `DAWApp` has no test target and a rule decided inside a
// SwiftUI `body` is invisible to `Tests/`.
//
// It is the deliberate third member of the drag trio:
//
//   • `ArrangeGroupDrag`  — HOW FAR the drag translates horizontally.
//   • `ArrangeBodyDrag`   — WHEN that translation reaches the store.
//   • `ArrangeVerticalDrag` (this) — WHICH LANE it lands on.
//
// ═══ THE VERB, AND WHY IT IS `byTracks` AND NOT `toTrack` ═══
//
// `ProjectStore` offers two cross-track shapes. This gesture resolves the
// ABSOLUTE row under the pointer (`row(atContentY:)`), converts it to a delta
// against the ANCHOR's row, and hands that delta to
// `moveClips(ids:byTracks:byBeats:)` — the RIGID, shape-preserving verb.
//
// Two reasons, both load-bearing:
//
//  1. **The keyboard already ships `byTracks`.** Bare ↑/↓ moves the arrange
//     selection across lanes through `ArrangeNudge` →
//     `moveClips(ids:byTracks:)`, and that route is gate-verified end to end
//     (`scripts/gates/m23aj-cross-track-move.mjs`, 66/66). If the DRAG collapsed
//     a multi-track selection onto one lane while the ARROW KEY preserved its
//     shape, the same surface would have two vertical semantics for the same
//     selection — the divergence `ProjectStore`'s own axis rule exists to
//     prevent, one level up.
//
//  2. **It fails safe.** `.toTrack` piles every mover onto a single lane, where
//     each one resolves overlap against that lane's residents; three lanes'
//     worth of clips landing on one destroys strictly more than the same clips
//     spread across three. This item exists because a drag ATE THE USER'S CLIPS
//     (m25-k), so where the two verbs disagree, the one that touches fewer
//     residents wins.
//
// ⚠️ A doc comment in `ProjectStore` predicts that the drag would resolve "an
// ABSOLUTE destination (the row under the pointer)". It is honoured in the half
// that is actually a RULE — the axis is the raw `tracks` index and this resolver
// NEVER SKIPS a row, so a bus occupies a row exactly as the arrange draws it.
// Only the choice of landing SHAPE differs, and that comment predates any
// gesture; see the two reasons above.
//
// ═══ WHAT THIS TYPE DOES NOT DO ═══
//
// It holds no store reference and returns plain values, so — like
// `ArrangeBodyDrag` — "the preview accidentally mutated something" is not a bug
// that can be reintroduced by editing a call site. It would take a new
// dependency.
public enum ArrangeVerticalDrag {

    // MARK: - Pointer → row

    /// The track row whose band contains content-space `y`, or **nil** when the
    /// pointer is not over the lane stack at all.
    ///
    /// ⚠️⚠️ **NIL MEANS "NO VERTICAL CHANGE", NEVER ROW 0.** Every caller must
    /// read it that way. A `?? 0` here would teleport the drag to the TOP track
    /// the instant the pointer strayed into the ruler or below the last lane —
    /// a silent, destructive landing the user never aimed at, and one that would
    /// fire constantly because the ruler sits directly above lane 0 and empty
    /// space sits directly below the last one.
    ///
    /// ⚠️ Do NOT inherit the file-drop path's reading of the same geometry.
    /// `TimelineLanesView.resolveDropHover` treats "below the last lane" as
    /// *make a new track*, which is right for importing a file and wrong for
    /// moving a clip that already lives somewhere.
    ///
    /// THE LADDER IS NON-UNIFORM — this is why the resolver takes measured band
    /// tops rather than a row height. A track with expanded take lanes or an
    /// open automation lane is TALLER than its neighbours, so `y / rowHeight`
    /// is wrong the moment any track is expanded (the same trap
    /// `ArrangeMarqueeTests` documents for the marquee).
    ///
    /// - Parameters:
    ///   - y: pointer y in the lanes' CONTENT space.
    ///   - bandTops: the top of every track's band, ascending and CONTIGUOUS —
    ///     band `i` runs to `bandTops[i + 1]`.
    ///   - stackBottom: the bottom of the last band.
    public static func row(atContentY y: Double,
                           bandTops: [Double],
                           stackBottom: Double) -> Int? {
        guard let first = bandTops.first, y >= first, y < stackBottom else { return nil }
        var found = 0
        for (i, top) in bandTops.enumerated() where y >= top { found = i }
        return found
    }

    /// The vertical delta a pointer at `y` REQUESTS, given the row the drag's
    /// anchor started on. Zero when the pointer is off the lane stack.
    ///
    /// Deriving the delta from an ABSOLUTE row (rather than from
    /// `translation.height`) is what keeps the anchor under the pointer on a
    /// non-uniform ladder: dragging across one expanded track and one collapsed
    /// track covers two different pixel distances for the same one-row intent.
    public static func requestedDelta(fromRow anchorRow: Int,
                                      pointerContentY y: Double,
                                      bandTops: [Double],
                                      stackBottom: Double) -> Int {
        guard let target = row(atContentY: y, bandTops: bandTops, stackBottom: stackBottom)
        else { return 0 }
        return target - anchorRow
    }

    // MARK: - Requested → achieved

    /// What the drop will ACTUALLY achieve vertically — the number both the
    /// ghost and the commit use, so they cannot disagree.
    ///
    /// ═══ PHASE ORDER MIRRORS THE STORE, AND THAT IS THE DECISION ═══
    ///
    /// `ProjectStore.moveClips(ids:landing:byBeats:)` clamps FIRST and
    /// kind-checks the CLAMPED landing SECOND, "the reverse would make the kind
    /// check a function of an out-of-range index". This function repeats that
    /// order for the same reason plus one more: inverting it here would check
    /// compatibility against a row the drop is never going to use, which is
    /// exactly where a ghost that promises a refused landing would hide.
    ///
    ///  1. **CLAMP** — `ProjectStore.clampedTrackDelta`, called directly rather
    ///     than re-derived, so the whole-group clamp has ONE home. Never per
    ///     clip: a per-clip clamp would silently break the selection's vertical
    ///     offsets the moment the topmost mover hit row 0 while the others still
    ///     had room.
    ///  2. **BACK OFF TO ZERO** if any mover's clamped destination cannot hold
    ///     it (`Track.canHold`, the domain's own predicate — asked, not copied).
    ///
    /// ═══ WHY BACK OFF INSTEAD OF LETTING THE STORE REFUSE ═══
    ///
    /// The store REFUSES THE WHOLE CALL when a landing cannot hold a mover, and
    /// `byBeats` rides in that same call — so a MIDI clip dragged from bar 1 to
    /// bar 9 whose pointer ends a few pixels over an AUDIO lane would lose the
    /// HORIZONTAL move too. Destroying the part of the user's intent that was
    /// perfectly legal is worse than declining the part that was not.
    ///
    /// Backing off also satisfies `ArrangeDragPreview`'s own contract — *"a
    /// preview that showed the raw request would promise a landing the commit
    /// then refuses, which is the honesty violation the design language
    /// forbids"*. The ghost simply stays on its own lane, continuously, while
    /// the pointer is over an incompatible one. That is feedback, not silence:
    /// unlike a dead keypress, the user can SEE the clip decline to cross.
    ///
    /// ⚠️ **IT NEVER SEARCHES.** A request of +3 blocked at +3 backs off to 0,
    /// not to +2. Hunting for a landing that works is precisely what
    /// `clampedTrackDelta`'s "pure RANGE clamp and never SEARCHES" rule
    /// forbids, and a drag that quietly lands somewhere other than where the
    /// pointer is would be a worse lie than declining.
    ///
    /// ⚠️ **THE KEYBOARD NOW DOES SEARCH, AND THAT ASYMMETRY IS DELIBERATE**
    /// (m25-l-1 ④, `ArrangeVerticalNudgeReach.delta`). A press carries no
    /// absolute row — only a direction — so "the next lane I can use" is the
    /// whole of its meaning, while a drag names a row and must honour it. Do NOT
    /// "harmonise" the two by teaching this function to search: the paragraph
    /// above is the reason, and it is unchanged. Both resolvers ask the SAME two
    /// homes (`clampedTrackDelta`, `Track.canHold`); only the question differs.
    ///
    /// ⚠️ **COMP MEMBERS ARE NOT HANDLED HERE, DELIBERATELY.** A take-comp
    /// member refuses on BOTH axes (`requireNotCompMember` guards
    /// `moveClips(ids:byBeats:)` as well as the cross-track core), so backing
    /// the VERTICAL off would not rescue a horizontal move that is already
    /// refused. That refusal, and its amber bubble, are pre-existing behaviour
    /// this item leaves exactly as it found them.
    ///
    /// - Parameters:
    ///   - requested: the raw pointer request from `requestedDelta`.
    ///   - movingClipIDs: the resolved arrange selection — every clip that will
    ///     travel with the gesture.
    ///   - tracks: the project's live tracks, in store order.
    public static func effectiveDelta(requested: Int,
                                      movingClipIDs: Set<UUID>,
                                      tracks: [Track]) -> Int {
        guard requested != 0, !tracks.isEmpty, !movingClipIDs.isEmpty else { return 0 }

        var sources: [Int] = []
        var movers: [(source: Int, clip: Clip)] = []
        for (index, track) in tracks.enumerated() {
            for clip in track.clips where movingClipIDs.contains(clip.id) {
                sources.append(index)
                movers.append((index, clip))
            }
        }
        guard let lo = sources.min(), let hi = sources.max() else { return 0 }

        // Phase 1 — the whole-group clamp, from its one home.
        let (effective, _) = ProjectStore.clampedTrackDelta(
            requested: requested, minTrackIndex: lo, maxTrackIndex: hi,
            trackCount: tracks.count)
        guard effective != 0 else { return 0 }

        // Phase 2 — kind-check the CLAMPED destination. Under `byTracks` a
        // non-zero delta moves EVERY mover, so unlike the store's core (which
        // also serves `.toTrack`, where a mover can already be on the
        // destination) there is no non-crossing case to exempt here.
        for mover in movers {
            let destination = mover.source + effective
            guard destination >= 0, destination < tracks.count,
                  tracks[destination].canHold(mover.clip) else { return 0 }
        }
        return effective
    }
}
