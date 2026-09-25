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
        return table
    }
}
