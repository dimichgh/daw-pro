import Foundation

// I1-F1: THE SET A PITCH DRAG WOULD COMMIT, BUILT WITHOUT COMMITTING IT.
//
// `ProjectStore.previewClipNotePitchDraft` hands the engine a DRAFT edit set to
// span-render while a drag is still in flight. The draft has to be exactly the
// set the release will store, or the user hears one thing while dragging and
// gets another on release.
//
// ⭐ ONE HOME (m23-ap I1 UI hooks, item 0). I1-F1 wrote this transform beside
// a commit that built the stored set inline (two homes, held together by a
// test). Both commits now CALL it: `setClipNotePitchOffsets` (a group drag,
// `clip.setNotePitches`) and `setClipNotePitchOffset` (a one-note drag,
// `clip.setNotePitch`), in `ProjectStore+PitchNoteEdits.swift`. So the clamp,
// the fold of a repeated id and the refusals exist once, here.
//
// `ClipNoteSpanAuditionTests`' agreement test STAYS: for every input the draft
// equals what each commit stores, and a refused commit is a refused draft. It
// is now the guard against a SECOND home coming back — an inline copy in a
// commit with a different clamp turns it red (planted and shown red when this
// became one home).

extension PitchEditSet {

    /// This set with each named note's `pitchOffsetCents` set to its offset
    /// (ABSOLUTE cents from the note's detected centre, the commit's number),
    /// exactly as `ProjectStore.setClipNotePitchOffsets` would store it:
    ///  * each offset is made finite (NaN and ±∞ read as 0) and clamped to
    ///    `NoteSegment.pitchOffsetCentsRange` (±2400 c) BEFORE anything else,
    ///    so "the same offset twice" is judged on what would be written;
    ///  * a repeated id with the same clamped offset is folded; with two
    ///    different offsets it is refused in words;
    ///  * an unknown id is refused, naming how many notes the set carries;
    ///  * an empty list is refused.
    /// All or nothing: a refusal returns no set. `clipId` only words the
    /// refusals.
    public func applyingNotePitchOffsets(_ offsets: [NotePitchOffset],
                                         clipId: UUID) throws -> PitchEditSet {
        guard !offsets.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "Name at least one note to tune. Read the clip's note ids with "
                    + "`clip.getPitchEdits` first.")
        }
        var table = self
        var resolved: [(index: Int, cents: Double)] = []
        var named: [UUID: Double] = [:]
        for offset in offsets {
            let cents = PitchCorrectionMath.finite(offset.offsetCents, default: 0)
                .clamped(to: NoteSegment.pitchOffsetCentsRange)
            if let earlier = named[offset.segmentId] {
                guard earlier == cents else {
                    throw ProjectError.invalidClipEdit(
                        "Note \(offset.segmentId) is named twice with two different pitches "
                            + "(\(earlier) and \(cents) cents). Name each note once.")
                }
                continue
            }
            named[offset.segmentId] = cents
            guard let index = table.segments.firstIndex(where: { $0.id == offset.segmentId }) else {
                throw ProjectError.invalidClipEdit(
                    "No note with id \(offset.segmentId) on clip \(clipId). That clip carries "
                        + "\(table.segments.count) note(s); read them back with "
                        + "`clip.getPitchEdits` before editing one.")
            }
            resolved.append((index, cents))
        }
        for entry in resolved {
            table.segments[entry.index].pitchOffsetCents = entry.cents
        }
        // Natural tuning D4-1 (b), the user's ruling of 2026-09-26: a pitch
        // drag is a HAND edit, so on a vocal tuned before natural tuning it
        // updates the whole vocal; a drag that ends where it started changes
        // no note and updates nothing (the no-op rule). Here, in the one
        // home, so the drag's draft (`previewClipNotePitchDraft`) plays the
        // SAME set both commits store.
        return table.afterHandEdit(from: self)
    }
}

// MARK: - vf-18: THE GROUP PITCH MOVE, ONE HOME (W9-SLFX, 2026-10-12)
//
// A followed slide's own offset is RELATIVE to the line between its neighbours
// (natural tuning §4.b.3: the bridge ADDS the neighbours' offsets, so a lone
// drag of the slide moves it by its own offset). A GROUP move that adds the
// same delta to the slide AND to the notes it follows therefore moves the
// slide twice: +12 on every note played the slide at +24 (vf-18, measured by
// W9-SLIDE). The fix is at the WRITER (design `$S/w9/SLRV/REVIEW.md` §1, §3.5):
// a group move stores `own + k·Δ`, with `k = 1 − glideFollow` for a followed
// slide that one of its ANCHORS (the notes its bridge reads) moves with, and
// `k = 1` for everything else. The pitch editor's group drag and the store's
// `moveClipNotePitches` (the wire's `clip.setNotePitches {moveByCents}`) both
// call `applyingGroupPitchMove`, so the carry exists once.
//
// ⚠️ The LITERAL writer keeps its meaning: `applyingNotePitchOffsets` /
// `clip.setNotePitches {notes}` store each note's ABSOLUTE own offset, so +M
// on a slide and on its anchors still plays the slide at about 2M. That is
// what the literal form asks for (§4.b.3's additive rule); a "move these
// notes together" goes through THIS transform.

/// The refusal sentences of the group pitch move, ONE home (the wire lane
/// echoes them verbatim). The unknown-note and empty-list refusals are
/// `applyingNotePitchOffsets`'s own, never restated here.
public enum NotePitchMoveSentences {
    /// A move that is not a number.
    public static func moveNotANumber(_ value: Double) -> String {
        "The move has to be a number of cents (100 cents is one semitone); \(value) is not one. "
            + "Nothing was changed."
    }

    /// A move that would take some note past `NoteSegment.pitchOffsetCentsRange`.
    /// `lowest`/`highest` are the whole-cent moves the group CAN make, so the
    /// caller can retry inside them.
    public static func moveOutOfRange(byCents: Double, segmentId: UUID,
                                      lowest: Double, highest: Double) -> String {
        "Moving these notes together by \(wholeCents(byCents)) cents would take note \(segmentId) "
            + "past the pitch limit (2400 cents, two octaves, either way from where it was sung). "
            + "Together these notes can move by \(wholeCents(lowest)) to \(wholeCents(highest)) "
            + "cents. Nothing was changed."
    }

    /// No note named and no sung note to move (the store's "every sung note").
    public static let noSungNotes =
        "This clip has no sung notes to move (only sounds like breaths or consonants). Name the "
        + "notes to move with segmentIds. Nothing was changed."

    /// A signed whole number of cents, `+0` never `-0`. Formatted, never
    /// converted to `Int`, so an absurd but finite move cannot trap.
    static func wholeCents(_ value: Double) -> String {
        let rounded = value.rounded()
        return rounded == 0 ? "+0" : String(format: "%+.0f", rounded)
    }
}

extension PitchEditSet {

    /// vf-18: the stored-offset factor `k` for the note at `index` in a GROUP
    /// pitch move, every member of which (`movingIDs`) moves by the same delta.
    ///  * `1 − glideFollow` for a followed slide (`glideFollow` > 0, the
    ///    render's own test for a bridge) in the group, at least one of whose
    ///    ANCHORS is in the group too: its bridge already adds that move, so
    ///    its own offset takes only the rest (`k = 0` at a full follow).
    ///  * `1` for everything else: a note, a sound, a slide moved WITHOUT its
    ///    anchors (a lone drag of a slide keeps meaning +D, §4.b.3), and a note
    ///    that is not in the group.
    /// The anchors are read as the moved set will render them: a SOUND in the
    /// group counts as a curve note (a moved sound enters the curve, R21),
    /// whatever its offset now, because the carry is fixed at the start of a
    /// gesture and does not know the delta. Which neighbours are anchors is
    /// the rule the move will STORE (`ruleAfterHandEdit()`, adoption
    /// included): every neighbour across a soft join under the legacy rule,
    /// only a HELD one under the hold rule (`PitchEditSet.isSlideAnchor`).
    /// Constant for a given group, so the pitch editor computes it once per
    /// gesture (`groupMoveCarries(movingIDs:)` reads the rule once for all).
    public func groupMoveCarry(ofSegmentAt index: Int, movingIDs: Set<UUID>) -> Double {
        groupMoveCarry(ofSegmentAt: index, movingIDs: movingIDs, rule: ruleAfterHandEdit())
    }

    /// `groupMoveCarry` for every member of `movingIDs` at once (the rule is
    /// read once): the factor per moving note's id. A note not in the table
    /// is absent.
    public func groupMoveCarries(movingIDs: Set<UUID>) -> [UUID: Double] {
        let rule = ruleAfterHandEdit()
        var out: [UUID: Double] = [:]
        for index in segments.indices where movingIDs.contains(segments[index].id) {
            out[segments[index].id] = groupMoveCarry(ofSegmentAt: index, movingIDs: movingIDs, rule: rule)
        }
        return out
    }

    func groupMoveCarry(ofSegmentAt index: Int, movingIDs: Set<UUID>, rule: SlideFollowRule) -> Double {
        guard segments.indices.contains(index) else { return 1 }
        let note = segments[index]
        guard note.glideFollow > 0, movingIDs.contains(note.id) else { return 1 }
        let anchors = groupMoveAnchorIndices(ofSegmentAt: index, movingIDs: movingIDs, rule: rule)
        let anchorMoves = [anchors.previous, anchors.next].contains { anchor in
            anchor.map { movingIDs.contains(segments[$0].id) } == true
        }
        return anchorMoves ? 1 - note.glideFollow : 1
    }

    /// The notes a followed slide at `index` reads as its anchors under
    /// `rule` once the group `movingIDs` has moved: its previous and next
    /// CURVE notes across a SOFT join (R15) that `isSlideAnchor` admits, nil
    /// on a side with none. A curve note is one that `entersPitchCurve`, or a
    /// sound in the group (see `groupMoveCarry`).
    func groupMoveAnchorIndices(ofSegmentAt index: Int, movingIDs: Set<UUID>,
                                rule: SlideFollowRule) -> (previous: Int?, next: Int?) {
        func isCurveNote(_ j: Int) -> Bool {
            segments[j].entersPitchCurve || movingIDs.contains(segments[j].id)
        }
        let note = segments[index]
        var previous: Int?
        var j = index - 1
        while j >= 0 {
            if isCurveNote(j) { previous = j; break }
            j -= 1
        }
        var next: Int?
        j = index + 1
        while j < segments.count {
            if isCurveNote(j) { next = j; break }
            j += 1
        }
        if let p = previous, Self.joinKind(leftEndSeconds: segments[p].endSeconds,
                                           rightStartSeconds: note.startSeconds) != .soft {
            previous = nil
        }
        if let n = next, Self.joinKind(leftEndSeconds: note.endSeconds,
                                       rightStartSeconds: segments[n].startSeconds) != .soft {
            next = nil
        }
        if let p = previous, !Self.isSlideAnchor(segments[p], rule: rule) { previous = nil }
        if let n = next, !Self.isSlideAnchor(segments[n], rule: rule) { next = nil }
        return (previous, next)
    }

    /// ⭐ **THE GROUP PITCH MOVE (vf-18), one transform.** Every named note
    /// moves by `byCents` together, the way dragging them together in the
    /// pitch editor does: each lands at `baseline + k·byCents`, `k` from
    /// `groupMoveCarry` (a followed slide moved with its anchors is CARRIED by
    /// them, so it plays exactly `byCents` higher, never twice that).
    ///  * `k == 1` keeps `baseline + byCents`, the literal expression, bit for
    ///    bit; only `k < 1` takes `baseline + byCents · k`.
    ///  * ALL OR NOTHING: if any note would land outside
    ///    `NoteSegment.pitchOffsetCentsRange` (±2400 c), the move is refused in
    ///    words naming the whole-cent range the group CAN move, and nothing is
    ///    stored. A non-finite move is refused in words.
    ///  * An empty list and an unknown id are refused in
    ///    `applyingNotePitchOffsets`' own words; a repeated id is folded.
    ///  * The stored set comes from `applyingNotePitchOffsets` (the ONE home of
    ///    the clamp, the no-op rule and D4-1's `afterHandEdit(from: self)`), so
    ///    a drag's draft, its release and the wire store the same set.
    /// Returns the stored set, the ABSOLUTE offsets it wrote (segment order,
    /// the literal writer's shape) and the ids of the carried slides (`k < 1`).
    public func applyingGroupPitchMove(segmentIDs: [UUID], byCents: Double, clipId: UUID) throws
        -> (set: PitchEditSet, offsets: [NotePitchOffset], carriedSlideIDs: [UUID]) {
        guard !segmentIDs.isEmpty else {
            // `applyingNotePitchOffsets` refuses an empty list in its words.
            return (try applyingNotePitchOffsets([], clipId: clipId), [], [])
        }
        guard byCents.isFinite else {
            throw ProjectError.invalidClipEdit(NotePitchMoveSentences.moveNotANumber(byCents))
        }
        // Unknown ids first, in the per-note setters' words (`transitionIndex`
        // is `applyingNotePitchOffsets`' sentence, verbatim).
        let movingIDs = Set(segmentIDs)
        for id in segmentIDs { _ = try Self.transitionIndex(of: id, in: self, clipId: clipId) }

        let rule = ruleAfterHandEdit()
        let range = NoteSegment.pitchOffsetCentsRange
        let tolerance = 1e-9
        var offsets: [NotePitchOffset] = []
        var carried: [UUID] = []
        var lowest = -Double.infinity
        var highest = Double.infinity
        var outside: UUID?
        for index in segments.indices where movingIDs.contains(segments[index].id) {
            let note = segments[index]
            let carry = groupMoveCarry(ofSegmentAt: index, movingIDs: movingIDs, rule: rule)
            let baseline = note.pitchOffsetCents
            let target = carry == 1 ? baseline + byCents : baseline + byCents * carry
            if carry < 1 { carried.append(note.id) }
            if carry > 0 {
                lowest = max(lowest, (range.lowerBound - baseline) / carry)
                highest = min(highest, (range.upperBound - baseline) / carry)
            }
            if outside == nil
                && (target < range.lowerBound - tolerance || target > range.upperBound + tolerance) {
                outside = note.id
            }
            offsets.append(NotePitchOffset(segmentId: note.id, offsetCents: target))
        }
        if let outside {
            // Inward to whole cents, so the range the sentence names is safe.
            throw ProjectError.invalidClipEdit(NotePitchMoveSentences.moveOutOfRange(
                byCents: byCents, segmentId: outside,
                lowest: (lowest - tolerance).rounded(.up),
                highest: (highest + tolerance).rounded(.down)))
        }
        return (try applyingNotePitchOffsets(offsets, clipId: clipId), offsets, carried)
    }

    /// ⭐ vf-18 — **WHERE A FOLLOWED SLIDE PLAYS, ONE HOME** (design
    /// `$S/w9/SLRV/REVIEW.md` §3.7): for every note with `glideFollow` g > 0,
    /// `g · (from + to) / 2` cents — the mean of the tilt its bridge adds over
    /// its span (`PitchCorrectionCurve.bridge` is `g · (from + (to − from)·u)`
    /// with `u` a smoothstep, whose mean is ½), so a flat note drawn there sits
    /// on the middle of the line it plays. The pitch editor draws every blob
    /// from it (`NoteBlob.followCents`) and re-reads it from the draft set
    /// during a drag.
    ///  * `(from, to)` are `slideAnchorCents(ofSegmentAt:rule:)` under this
    ///    set's OWN rule (`slideFollowRule`): the curve's hold branch reads that
    ///    helper, and its legacy case reads the same soft neighbours the curve's
    ///    legacy loop reads (that helper's doc says the CURVE never calls the
    ///    legacy case; a display reading it is the inertness predicate's use,
    ///    not a second curve).
    ///  * A DISPLAY read: no render, no stored offset and no carry reads it
    ///    (the carry is `groupMoveCarries`, fixed at a gesture's start).
    ///  * Only non-zero entries; `ids` limits the notes asked (the editor's
    ///    live drag asks for its moving notes only).
    /// Moved here from the editor (`PitchEditorModel`, W9-SLED) unchanged, so
    /// what the editor draws stays bit for bit what it drew.
    public func slideFollowCents(only ids: Set<UUID>? = nil) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for index in segments.indices {
            let note = segments[index]
            guard note.glideFollow > 0, ids.map({ $0.contains(note.id) }) ?? true,
                  let anchors = slideAnchorCents(ofSegmentAt: index, rule: slideFollowRule)
            else { continue }
            let follow = note.glideFollow * (anchors.from + anchors.to) / 2
            if follow != 0 { out[note.id] = follow }
        }
        return out
    }
}

// MARK: - Natural tuning §4: the slide transforms (NT-C C4)
//
// The same ONE-HOME rule as `applyingNotePitchOffsets`, for the joins: the
// store's commit (`ProjectStore.setClipNoteTransition` /
// `setClipNoteGlideFollow` / `setClipPitchTransitionSmoothness`) and any draft
// (the pitch editor's rear-edge drag, NT-U2) call THESE, so what a drag draws
// and plays is what its release stores. The curve does the rest: every width
// the set carries is read through `PitchEditSet.softJoin`, so a draft built
// here draws its line through the same `make` the render uses.

/// The refusal sentences of the three slide verbs, ONE home. The wire lane
/// (NT-W) echoes them verbatim.
public enum PitchTransitionSentences {
    /// A slide width that is not 0/null (Auto) or a positive number of ms.
    public static func widthNotANumber(_ value: Double) -> String {
        "The slide width has to be 0 or null (Auto), or a number of milliseconds from "
            + "30 to 1000; \(value) is not one. Nothing was changed."
    }

    /// A SOUND named as the left note of a slide.
    public static func soundHasNoSlide(_ segmentId: UUID) -> String {
        "Note \(segmentId) is a sound with no sung pitch (a breath or a consonant), so it "
            + "has no slide into the next note to shape. Nothing was changed. Name a sung note."
    }

    /// The last sung note: nothing after it to slide into.
    public static func lastNoteHasNoSlide(_ segmentId: UUID) -> String {
        "Note \(segmentId) is the last sung note on this clip, so there is no next note for "
            + "it to slide into. Nothing was changed. Name the note on the LEFT of the slide "
            + "you want to shape."
    }

    /// A note whose right edge faces a gap (R15 `.gap`).
    public static func gapHasNoSlide(_ segmentId: UUID) -> String {
        "Note \(segmentId) is followed by a gap (a silence, a breath or a consonant) before "
            + "the next sung note, so there is no slide between them to shape. Nothing was "
            + "changed."
    }

    /// A smoothness of exactly 0: legacy is Undo's job, never a setting (§4.e).
    public static let smoothnessZero =
        "The slide smoothness has to be a speed from 500 to 20000 cents per second, or null "
        + "for the default (3000). 0 is not a setting: to go back to how this vocal slid "
        + "before, use Undo. Nothing was changed."

    /// A smoothness that is negative or not a number.
    public static func smoothnessNotANumber(_ value: Double) -> String {
        "The slide smoothness has to be a speed from 500 to 20000 cents per second, or null "
            + "for the default (3000); \(value) is not one. Nothing was changed."
    }

    /// A follow amount that is not a number.
    public static func followNotANumber(_ value: Double) -> String {
        "The follow amount has to be a number from 0 (the slide keeps its own pitch) to 1 "
            + "(it follows the notes on both sides fully); \(value) is not one. Nothing was "
            + "changed."
    }

    /// A SOUND named to follow its neighbours.
    public static func soundCannotFollow(_ segmentId: UUID) -> String {
        "Note \(segmentId) is a sound with no sung pitch (a breath or a consonant), so it "
            + "cannot follow the notes beside it like a sung slide. Nothing was changed. Name "
            + "a sung note."
    }

    /// A follow asked of a note joined to no curve note on either side.
    public static func nothingToFollow(_ segmentId: UUID) -> String {
        "Note \(segmentId) meets no sung note on either side (there is a gap before it and "
            + "after it), so there is nothing for it to follow. Nothing was changed. Name a "
            + "slide that sits between two notes."
    }
}

extension PitchEditSet {

    /// This set with the join to the RIGHT of `segmentId` given a width,
    /// exactly as `ProjectStore.setClipNoteTransition` stores it (§4.e):
    ///  * nil or 0 = Auto (`transitionOutMs` 0); a positive width is clamped
    ///    to `NoteSegment.transitionOutMsRange` (30...1000 ms of the ORIGINAL
    ///    take). The note-length clamp is NOT stored: the curve applies it
    ///    (`softJoin`), and `joinReading(afterSegmentAt:)` reports what
    ///    applies, so a later split or retime cannot leave a stale clamp;
    ///  * refused in words: a negative or non-finite width, an unknown note
    ///    (naming the count), a SOUND, the LAST curve note, and a note whose
    ///    right edge faces a GAP (R15);
    ///  * writes that one field and nothing else, then
    ///    `afterHandEdit(from: self)`.
    /// On a LEGACY set (`predatesNaturalTuning`) a width that changes the
    /// note also updates the whole vocal (D4-1 (b), the user's ruling of
    /// 2026-09-26): every join takes the default slope, not only this one.
    /// The width it already has changes nothing, so it updates nothing.
    public func applyingNoteTransition(segmentId: UUID, widthMs: Double?,
                                       clipId: UUID) throws -> PitchEditSet {
        let width = widthMs ?? 0
        guard width.isFinite, width >= 0 else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.widthNotANumber(width))
        }
        let index = try Self.transitionIndex(of: segmentId, in: self, clipId: clipId)
        guard segments[index].origin != .unpitched else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.soundHasNoSlide(segmentId))
        }
        guard let next = nextCurveNoteIndex(after: index) else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.lastNoteHasNoSlide(segmentId))
        }
        guard joinKind(between: index, and: next) == .soft else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.gapHasNoSlide(segmentId))
        }
        var table = self
        table.segments[index].transitionOutMs = width > 0
            ? width.clamped(to: NoteSegment.transitionOutMsRange) : 0
        return table.afterHandEdit(from: self)
    }

    /// This set with `segmentId`'s follow amount set, exactly as
    /// `ProjectStore.setClipNoteGlideFollow` stores it (§4.e
    /// `clip.setNoteGlideFollow`): 0 = the slide keeps its own pitch, 1 =
    /// it tilts from the previous note's offset to the next one's.
    ///  * a finite amount is clamped to `NoteSegment.glideFollowRange`;
    ///  * refused in words: a non-finite amount, an unknown note, a SOUND,
    ///    and an amount above 0 on a note joined to no curve note on either
    ///    side (the write would take and do nothing). 0 is always allowed;
    ///  * any sung note may follow, not only a `.transition` part: an agent
    ///    marks the slides of a preset-built table this way (the preset seed
    ///    never does, (a-T)), and `origin` tells it which ones are slides;
    ///  * writes that one field and nothing else, then
    ///    `afterHandEdit(from: self)` (a follow already at that amount
    ///    changes nothing, so it updates nothing).
    public func applyingNoteGlideFollow(segmentId: UUID, amount: Double,
                                        clipId: UUID) throws -> PitchEditSet {
        guard amount.isFinite else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.followNotANumber(amount))
        }
        let index = try Self.transitionIndex(of: segmentId, in: self, clipId: clipId)
        guard segments[index].origin != .unpitched else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.soundCannotFollow(segmentId))
        }
        let clamped = amount.clamped(to: NoteSegment.glideFollowRange)
        if clamped > 0 {
            let before = previousCurveNoteIndex(before: index)
                .map { joinKind(between: $0, and: index) == .soft } ?? false
            let after = nextCurveNoteIndex(after: index)
                .map { joinKind(between: index, and: $0) == .soft } ?? false
            guard before || after else {
                throw ProjectError.invalidClipEdit(PitchTransitionSentences.nothingToFollow(segmentId))
            }
        }
        var table = self
        table.segments[index].glideFollow = clamped
        return table.afterHandEdit(from: self)
    }

    /// This set with its slide smoothness set, exactly as
    /// `ProjectStore.setClipPitchTransitionSmoothness` stores it (§4.e):
    /// nil = `defaultTransitionSlope`; a positive value is clamped to
    /// `transitionSlopeRange`; 0, a negative value and a non-finite one are
    /// refused in words (going back to legacy is Undo's job, not a setting).
    /// An explicit request, so on a LEGACY set it upgrades THIS field alone
    /// (§4.j, X4), regardless of D4-1: it is a set-level switch, not a hand
    /// edit, and never calls `afterHandEdit()`. Nothing else moves.
    public func applyingTransitionSmoothness(centsPerSecond: Double?) throws -> PitchEditSet {
        let slope = centsPerSecond ?? Self.defaultTransitionSlope
        guard slope != 0 else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.smoothnessZero)
        }
        guard slope.isFinite, slope > 0 else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.smoothnessNotANumber(slope))
        }
        var table = self
        table.transitionSlopeCentsPerSecond = slope.clamped(to: Self.transitionSlopeRange)
        return table
    }

    /// The note's index, or the per-note setters' unknown-note refusal in the
    /// same words (`ProjectStore`'s `segmentIndex`, `applyingNotePitchOffsets`).
    private static func transitionIndex(of segmentId: UUID, in set: PitchEditSet,
                                        clipId: UUID) throws -> Int {
        guard let index = set.segments.firstIndex(where: { $0.id == segmentId }) else {
            throw ProjectError.invalidClipEdit(
                "No note with id \(segmentId) on clip \(clipId). That clip carries "
                    + "\(set.segments.count) note(s); read them back with "
                    + "`clip.getPitchEdits` before editing one.")
        }
        return index
    }
}
