import Foundation

/// One BY-ID field update inside a `ProjectStore.patchNotes` call
/// (m26-a / m27-n — filed twice from two real sessions and MERGED per the
/// roadmap: m27-n from the legato pass that changed only `lengthBeats` on
/// 225 of a clip's notes and had to round-trip all 225 through
/// `setClipNotes` to do it; m26-a from a report that raising the velocity of
/// 48 shaker notes cost a read of all 907 notes in that clip (~80 KB) to
/// change 48).
///
/// Every field but `id` is OPTIONAL, and an omitted field is UNCHANGED —
/// that is the entire point. `clip.setNotes` already covers "replace every
/// field of every note"; forcing a caller to resend fields it is NOT
/// touching is exactly the whole-array round trip this type exists to avoid.
public struct NotePatch: Sendable, Equatable {
    public var id: UUID
    public var pitch: Int?
    public var velocity: Int?
    public var startBeat: Double?
    public var lengthBeats: Double?

    public init(
        id: UUID, pitch: Int? = nil, velocity: Int? = nil,
        startBeat: Double? = nil, lengthBeats: Double? = nil
    ) {
        self.id = id
        self.pitch = pitch
        self.velocity = velocity
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
    }
}

/// Counts-only report for `ProjectStore.patchNotes` — the `NoteRepeatReport`
/// precedent (`ProjectStore+RepeatNotes.swift`): a verb whose whole purpose
/// is avoiding a big note array in the REQUEST must not turn around and put
/// one in the RESPONSE. Read the patched notes back with `clip.getNotes` if
/// you need to see them.
public struct NotePatchReport: Equatable, Sendable {
    public var clipID: UUID
    /// Always equal to the request's `update.count` on success — patchNotes
    /// is ALL-OR-NOTHING (an unknown or duplicate id refuses the WHOLE call
    /// before anything is written), so there is no partial count to report.
    public var updated: Int
    /// The clip's note count after the write. patchNotes never adds or
    /// removes a note, so this always equals the count before — carried
    /// anyway so a caller never has to special-case this one verb's response
    /// to sanity-check nothing else moved (the `clip.getNotes`/
    /// `clip.repeatNotes` naming, reused rather than reinvented).
    public var totalNotes: Int
    /// Notes whose PATCHED `startBeat` lands at/past the clip's end after
    /// this write — legal (m18-f) but silent. patchNotes does NO auto-extend
    /// (see the `patchNotes` doc comment for why), so this is the only
    /// signal a caller gets that a startBeat/lengthBeats edit just silenced
    /// a note. Zero whenever nothing landed past the end.
    public var latentNotesPastClipEnd: Int

    public init(
        clipID: UUID, updated: Int = 0, totalNotes: Int = 0,
        latentNotesPastClipEnd: Int = 0
    ) {
        self.clipID = clipID
        self.updated = updated
        self.totalNotes = totalNotes
        self.latentNotesPastClipEnd = latentNotesPastClipEnd
    }
}

@MainActor
extension ProjectStore {

    // MARK: - Patch notes (m26-a / m27-n)

    /// BY-ID partial note edit — the missing rung between `clip.getNotes`
    /// (read, shipped 2026-08-17) and `clip.setNotes` (whole-array replace,
    /// which can also add/remove/reorder notes). `patchNotes` can only ever
    /// change fields on notes that ALREADY EXIST; it never creates or
    /// removes one. Reach for `setClipNotes` when authoring or replacing a
    /// clip's content; reach for this when a FEW existing notes need a field
    /// changed and the rest must be left completely alone.
    ///
    /// ⚠️⚠️ **NOT `setClipNotes`'s "read the safety property" fix — it
    /// REMOVES THE HAZARD CLASS.** `clip.getNotes` followed by a FILTERED
    /// whole-array `clip.setNotes` write silently deletes every note the
    /// filter excluded; that hazard is defended only by prose (the
    /// `totalNotes`/`returnedNotes` contract). `patchNotes` cannot delete a
    /// note under any input — there is no code path from "call this" to
    /// "note gone" — so the hazard does not need documenting here, it needs
    /// nothing.
    ///
    /// ⚠️ **NO `add`/`remove` IN v1 — DELIBERATE, not an oversight.** Both
    /// measured motivating cases (the legato `lengthBeats` pass, the shaker
    /// velocity bump) are pure field edits on notes that already exist.
    /// Adding create/delete-by-id would (a) widen the overlap with
    /// `setClipNotes` — already flagged as a confusable pair before this
    /// shipped at all — and (b) drag in the auto-extend decision
    /// `setClipNotes`/`repeatNotes` both carry (which of possibly-mixed
    /// add/update/remove ids should be allowed to grow the clip?), which is
    /// real design work the two real-world reports never asked for. Filed as
    /// a follow-up if a real run shows the gap; see the roadmap close note.
    ///
    /// ⚠️ **NO AUTO-EXTEND.** A patched `startBeat`/`lengthBeats` that lands
    /// past the clip's current end stores fine (m18-f, legal-but-latent) and
    /// is reported via `latentNotesPastClipEnd`, but the clip does not grow
    /// to reach it — this is `setClipNotes`'s OWN default behavior
    /// (`extendToCover: []`), so a caller who wants growth already has
    /// `setClipNotes`/`clip.fitToContent` for it; patchNotes just does not
    /// reimplement that decision for a v1 whose motivating cases never
    /// needed it.
    ///
    /// ⚠️⚠️ **UNDO COALESCING — `performEdit` with NO `key:`, deliberately.**
    /// `setClipNotes` opts INTO coalescing (`key: "clip.notes:<id>"`) so a
    /// drag of one note in the piano roll is a single undo step across many
    /// frames. A batch id-addressed patch is the opposite shape — it must
    /// never fold into a stranger's edit that happens to land inside the
    /// same 800 ms window, and nothing after it should fold into IT either.
    /// See `ProjectStore+RepeatNotes.swift`'s banner, the reason this file
    /// exists at all, and `PatchNotesTests`' coalescing test + control.
    ///
    /// Validation is ALL-OR-NOTHING and happens entirely BEFORE any
    /// mutation, the `removeClips` precedent (`ProjectStore.swift`): every
    /// id in `update` is located first, and only once every id is known
    /// good does the edit open. An unknown id, or the SAME id named twice in
    /// one call, refuses the WHOLE call and leaves the model byte-identical
    /// — never a partial apply. (Duplicate ids collapse silently in
    /// `removeClips`, because "remove X" repeated is unambiguous; two
    /// DIFFERENT field edits for the same note id are not, so this throws
    /// instead of silently picking a winner.)
    ///
    /// - Parameters:
    ///   - update: notes to change, by id. May be empty (a no-op: returns a
    ///     zeroed report and touches nothing — entering `performEdit` would
    ///     mark the project dirty unconditionally even for a no-op write,
    ///     the `repeatNotes` "nothing to write" precedent). Each entry must
    ///     set at least one of pitch/velocity/startBeat/lengthBeats — an
    ///     entry that sets none of them is almost certainly a caller
    ///     mistake and is refused rather than silently accepted as a no-op.
    @discardableResult
    public func patchNotes(clipID: UUID, update: [NotePatch]) throws -> NotePatchReport {
        // `locateClip` is `private` to ProjectStore.swift, so — exactly like
        // `pasteNotes`/`repeatNotes` — the lookup is inlined here rather
        // than shared.
        guard let t = tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let c = tracks[t].clips.firstIndex(where: { $0.id == clipID }) else {
            throw ProjectError.clipNotFound(clipID)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard let existingNotes = tracks[t].clips[c].notes else {
            throw ProjectError.notAMIDIClip(clipID, verb: "clip.patchNotes")
        }

        guard !update.isEmpty else {
            return NotePatchReport(clipID: clipID, updated: 0, totalNotes: existingNotes.count)
        }

        // Phase 1 — LOCATE AND VALIDATE EVERYTHING, no mutation yet.
        var seenIDs = Set<UUID>()
        for patch in update {
            guard seenIDs.insert(patch.id).inserted else {
                throw ProjectError.invalidClipEdit(
                    "clip.patchNotes: update names note \(patch.id.uuidString) more than once "
                    + "in the same call — patch each note exactly once per call, or send your "
                    + "second edit as a follow-up call")
            }
            // An entry naming no field is almost certainly a caller mistake
            // (forgot to set a field), not a deliberate no-op — refused
            // rather than silently accepted, the same "loud, not silent"
            // stance every other guard here takes. Enforced HERE, not only
            // at the wire (Commands.swift pre-teaches the same rule), so a
            // direct DAWCore caller gets it too — the store is the one home
            // for this verb's semantics.
            guard patch.pitch != nil || patch.velocity != nil
                    || patch.startBeat != nil || patch.lengthBeats != nil else {
                throw ProjectError.invalidClipEdit(
                    "clip.patchNotes: the update entry for note \(patch.id.uuidString) sets none "
                    + "of pitch/velocity/startBeat/lengthBeats — nothing to change; omit this "
                    + "entry or set at least one field")
            }
        }
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(existingNotes.count)
        for (i, note) in existingNotes.enumerated() { indexByID[note.id] = i }
        var targetIndices: [Int] = []
        targetIndices.reserveCapacity(update.count)
        for patch in update {
            guard let i = indexByID[patch.id] else {
                throw ProjectError.invalidClipEdit(
                    "clip.patchNotes: no note with id \(patch.id.uuidString) in clip "
                    + "\(clipID.uuidString) — nothing was changed")
            }
            targetIndices.append(i)
        }

        // Phase 2 — apply. Reconstructed through MIDINote's own clamping
        // init (the `setClipNotes` precedent: "Reconstruct each note
        // through the clamping init before ordering, so a caller that
        // mutated a note's fields out of range can't slip past"), so this
        // stays correct even for a direct DAWCore caller that bypassed the
        // wire's own field-range teaching errors.
        var patched = existingNotes
        for (patch, i) in zip(update, targetIndices) {
            let note = patched[i]
            patched[i] = MIDINote(
                id: note.id,
                pitch: patch.pitch ?? note.pitch,
                velocity: patch.velocity ?? note.velocity,
                startBeat: patch.startBeat ?? note.startBeat,
                lengthBeats: patch.lengthBeats ?? note.lengthBeats)
        }
        let ordered = MIDINote.canonicallyOrdered(patched)

        performEdit("Patch Notes \u{00D7}\(update.count)") {
            tracks[t].clips[c].notes = ordered
            engine?.tracksDidChange(tracks)
        }

        // Re-find by id — belt-and-braces with `repeatNotes`/`setClipNotes`,
        // even though patchNotes never adds/removes a clip or resolves
        // overlaps, so `c` in fact stays valid across this particular edit.
        let finalClip = tracks[t].clips.first { $0.id == clipID }
        let finalNotes = finalClip?.notes ?? ordered
        let finalLength = finalClip?.lengthBeats ?? tracks[t].clips[c].lengthBeats
        let latent = finalNotes.filter { $0.startBeat >= finalLength }.count
        return NotePatchReport(
            clipID: clipID,
            updated: update.count,
            totalNotes: finalNotes.count,
            latentNotesPastClipEnd: latent)
    }
}
