import Foundation

// m23-ap Phase 2, Increment C (items C1 + C3) — THE PER-NOTE WRITER.
//
// Design record: `docs/design/2026-09-22-pitch-editor-ui.md` §7.3 (C1 = drag a
// note's pitch, C3 = split a note), §8.2 (ONE `performEdit` on gesture END),
// §8.3 (the undo keys), §9.1 (the verbs these ops are the one home for).
//
// `ProjectStore+PitchCorrection.swift` writes a WHOLE auto-correct pass.
// This file writes ONE NOTE — or, since I7a/U-D/I4, a GROUP of named notes in
// one undo step (`setClipNotesCleared`, `setClipNoteGain`,
// `setClipNotePitchOffsets`). Own extension file, the `+PitchDetection` /
// `+PitchCorrection` precedent: per-frame f0 is its own file, per-clip passes
// are their own file, per-note edits are this one.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⛔ THE SEEDING PROBLEM, AND WHY `seedIfAbsent` IS A PARAMETER
// ═══════════════════════════════════════════════════════════════════════════
//
// A note can only be ADDRESSED once a note table exists, and a clip that has
// never been tuned carries `pitchEdits == nil`. Something has to mint the
// table on the first edit, and the three shapes that do NOT work are worth
// naming so nobody re-proposes one:
//
//  1. **Detect inside the op.** `autoCorrectClipPitch` does exactly that and is
//     right to — it is a whole-clip pass a person waits for. A per-note drag is
//     not: it commits on POINTER-UP, and a model run there would stall the
//     gesture for seconds on a clip whose contour the editor is already drawing.
//  2. **Materialise the table when the editor OPENS.** Opening a viewer would
//     then dirty the project and light the TUNING APPLIED badge on a clip
//     nobody has touched.
//  3. **Mint ids in the store and hand them back.** The editor has already
//     drawn the notes by then; re-keying them underneath a live gesture is the
//     identity churn m23-q condition 4 exists to prevent.
//
// So the CALLER — which is holding the detection it is drawing — supplies the
// table it wants seeded, and the store decides whether to use it. ⭐ **THE SEED
// IS IGNORED WHENEVER THE CLIP ALREADY CARRIES A TABLE**, so a stale seed from
// an editor that has been open across a preset apply can never clobber the
// stored notes. `seedIgnoredWhenTheClipAlreadyCarriesATable` pins that with a
// deliberate clobber attempt, because "it returned the clip" is not proof.

@MainActor
extension ProjectStore {

    /// Set ONE note's pitch offset, in cents. C1's store leg.
    ///
    /// `offsetCents` is ABSOLUTE, not a delta — the editor holds the live value
    /// in its own draft during a drag and submits the final number once, on
    /// gesture end (§8.2). A delta API would make a dropped commit
    /// indistinguishable from a commit of zero.
    ///
    /// Coalescing key: `PitchCorrectionUndoKey.segment(clipID:segmentID:)`, so
    /// two drags of the SAME note inside the journal's 800 ms window fold into
    /// one undo step and a drag of a DIFFERENT note starts a new one — per-note
    /// undo for free, from the key alone.
    ///
    /// ⚠️ **A NO-OP IS SILENT, DELIBERATELY.** Writing the offset a note already
    /// carries leaves `captureEditState()` unchanged, so `performEdit` journals
    /// nothing — the `clearClipPitchEdits` idiom. A drag that ends where it
    /// began therefore costs no undo entry even if the caller submits it.
    ///
    /// Refuses a MIDI clip (`pitchDetectionRequiresAudioClip`) and a take-group
    /// comp member (`requireNotCompMember`), the same two gates
    /// `autoCorrectClipPitch` applies and for the same reasons.
    @discardableResult
    public func setClipNotePitchOffset(clipId: UUID,
                                       segmentId: UUID,
                                       offsetCents: Double,
                                       seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)

        // ⛔⛔ **CLAMPED, BECAUSE A DIRECT FIELD ASSIGNMENT BYPASSES THE HEALING
        // `init` — AND THE FIRST DRAFT OF THIS FUNCTION DID NOT, WHICH
        // `setNotePitchClamps` CAUGHT.** `NoteSegment.init` clamps
        // `pitchOffsetCents` to ±2400 cents; `segments[i].pitchOffsetCents = x`
        // does not go near it, so 99999 went in and read back as 99999. That is
        // the same shape `ProjectStore+PitchCorrection.swift` records for
        // `pitchEdits` itself ("a direct field assignment, which this is,
        // bypasses it") — one struct down.
        //
        // ⭐ m23-ap I1 UI hooks, item 0: the clamp now lives in ONE home,
        // `PitchEditSet.applyingNotePitchOffsets` — the transform the pitch
        // editor's drag preview hands the engine — so the note a one-note drag
        // PLAYS is the note this commit STORES. Same clamp, and the same
        // unknown-note refusal in the same words as `segmentIndex`'s.
        let stored = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
            .applyingNotePitchOffsets(
                [NotePitchOffset(segmentId: segmentId, offsetCents: offsetCents)], clipId: clipId)

        performEdit("Tune Note",
                    key: PitchCorrectionUndoKey.segment(clipID: clipId, segmentID: segmentId)) {
            tracks[t].clips[c].pitchEdits = stored
            // pitchEdits rides the render cache key (`ClipKey.pitchEditSetHash`)
            // — the `autoCorrectClipPitch` precedent for a key-affecting edit.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Split ONE note into two at a source-file second. C3's store leg.
    ///
    /// Both halves inherit every EDIT the parent carried, so a split of a note
    /// the user had already tuned does not silently untune half of it. The
    /// halves are then independent: dragging one moves one.
    ///
    /// ⭐⭐ **THE RIGHT HALF IS BUILT BY A `Codable` ROUND TRIP, NOT BY A
    /// HAND-WRITTEN ARGUMENT LIST, AND THAT IS THE POINT.** `NoteSegment.id` is
    /// `let`, so a second segment cannot be made by copying and mutating — it
    /// has to be constructed. A hand-listed `NoteSegment(startSeconds:…)` call
    /// is precisely the shape this tree keeps paying for: it compiles fine
    /// after a field is added to the type and silently drops that field's value
    /// on every split. Re-encoding the parent, swapping three keys and decoding
    /// makes **the type's own `encode`/`init(from:)` the field census** — a
    /// field added tomorrow is carried without this function being touched.
    /// `splitCarriesEveryEditFieldTheParentHad` is the test; the round trip is
    /// what makes it stay true.
    ///
    /// **Refused when either half would be shorter than
    /// `PitchAutoCorrect.minimumNoteSeconds`** (0.06 s) — the same floor the
    /// segmentation policy already applies, not a second opinion about what
    /// counts as a note. A shorter half could not be corrected anyway: the
    /// renderer's own ramp is 30 ms and would swallow it whole.
    ///
    /// Coalescing key: `PitchCorrectionUndoKey.structuralKey` (`nil`) — a split
    /// is structural and never coalesces (§8.3), so splitting twice in a second
    /// is two undo steps, which is what a person expects from two cuts.
    ///
    /// The LEFT half keeps the parent's id. Arbitrary but fixed: something has
    /// to, or a split would orphan the undo key of a drag that is still inside
    /// the coalescing window.
    @discardableResult
    public func splitClipNoteSegment(clipId: UUID,
                                     segmentId: UUID,
                                     atSourceSecond: Double,
                                     seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        var table = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        let index = try segmentIndex(of: segmentId, in: table, clipId: clipId)
        let parent = table.segments[index]

        let cut = PitchCorrectionMath.finite(atSourceSecond, default: .nan)
        let floor = PitchAutoCorrect.minimumNoteSeconds
        guard cut.isFinite,
              cut - parent.startSeconds >= floor,
              parent.endSeconds - cut >= floor else {
            throw ProjectError.invalidClipEdit(
                "That note is too short to split there. Each half has to be at least "
                    + "\(Int((floor * 1000).rounded())) ms long, and this note runs from "
                    + "\(Self.secondsText(parent.startSeconds)) to "
                    + "\(Self.secondsText(parent.endSeconds)). Zoom in and cut nearer the middle.")
        }

        var left = parent
        left.endSeconds = cut
        let right = try Self.reidentified(parent, startSeconds: cut, endSeconds: parent.endSeconds)

        var segments = table.segments
        segments.replaceSubrange(index...index, with: [left, right])
        table.segments = segments
        let stored = PitchEditSet(analysisVersion: table.analysisVersion,
                                  segments: segments,
                                  retuneMs: table.retuneMs)

        performEdit("Split Note", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Clear (silence) or restore a GROUP of notes in place. This is I7a's
    /// store leg (design `docs/design/2026-09-24-pitch-editor-interaction-batch.md`
    /// §10, ruled in §17), and the one home every door calls: the wire verb
    /// `clip.setNoteCleared` today, and later the editor's Clear/Restore menu
    /// (I7b) and ⌫ (I4, `delete-clears = yes`).
    ///
    /// It sets `NoteSegment.isCleared` to `cleared` on every named note and
    /// changes NOTHING ELSE. No note moves and no pitch or level is written, so
    /// `cleared: false` brings a note back at its own level. The offline
    /// render silences a cleared note between its ramps
    /// (`PitchEditSet.gain(atSourceSecond:)`).
    ///
    /// ⭐ **ONE journal entry for N notes** ("Clear Notes" / "Restore Notes"),
    /// under `PitchCorrectionUndoKey.structuralKey`. A deliberate on/off never
    /// coalesces (UI design §8.3), and a multi-select edit is one entry over
    /// all N (the undo-key doc's `clip.moveMany` precedent). One
    /// `tracksDidChange`.
    ///
    /// ⚠️ **ALL OR NOTHING.** Every id is resolved BEFORE anything is written,
    /// so an unknown id among several leaves the table untouched, never
    /// half-cleared. A repeated id is harmless (the same value written twice)
    /// and is folded. An empty list is refused in words: a call that names no
    /// note would otherwise succeed silently and change nothing.
    ///
    /// The refusals are the per-note setters' own, shared rather than
    /// restated: an unknown clip, a MIDI clip or a take-group comp member
    /// (`locateEditableNoteClip`); no stored table and no seed (`noteTable`); an
    /// unknown note id (`segmentIndex`, which names how many notes the clip
    /// does carry). A no-op (every named note already in that state) journals
    /// nothing, the `setClipNotePitchOffset` idiom.
    @discardableResult
    public func setClipNotesCleared(clipId: UUID,
                                    segmentIds: [UUID],
                                    cleared: Bool,
                                    seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        guard !segmentIds.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "Name at least one note to \(cleared ? "clear" : "restore"). Read the clip's "
                    + "note ids with `clip.getPitchEdits` first.")
        }
        var table = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        var indices: [Int] = []
        var seen = Set<UUID>()
        for segmentId in segmentIds where seen.insert(segmentId).inserted {
            indices.append(try segmentIndex(of: segmentId, in: table, clipId: clipId))
        }
        for index in indices {
            table.segments[index].isCleared = cleared
        }
        let stored = table

        performEdit(cleared ? "Clear Notes" : "Restore Notes",
                    key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            // The flag rides the render key through the digest's level block
            // (`PitchEditSetDigest`, slot 5), the `autoCorrectClipPitch`
            // precedent for a key-affecting edit.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Set a GROUP of notes' LEVEL, in dB. U-D's store leg (design
    /// `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §1.8,
    /// as amended by `docs/design/2026-09-24-pitch-editor-interaction-batch.md`
    /// §17.3), `setClipNotesCleared`'s MIRROR for the other half of the same
    /// mask: that flag silences, this sets what a note plays AT when it is
    /// not silenced. Sits beside it for that reason, and shares its shape —
    /// same refusals, all-or-nothing, a no-op journals nothing, one undo step
    /// for N notes.
    ///
    /// `gainDb` is the note's FINAL level, 0 = as sung, NOT a delta — the
    /// `setClipNotePitchOffset` rule verbatim, for the same reason (a dropped
    /// call and a call of 0 must read back differently). Every named note
    /// gets exactly this ONE value; a per-note fan-out is a caller loop, same
    /// as `setClipNotesCleared`'s single `cleared` flag.
    ///
    /// ⛔ **CLAMPED HERE, EXPLICITLY, BECAUSE A DIRECT FIELD ASSIGNMENT
    /// BYPASSES THE HEALING `init`** — `setClipNotePitchOffset`'s own rule
    /// (this file's banner), restated because `amplitudeDb` shares
    /// `Clip.gainDbRange` (−72…24) with a whole clip's own gain rather than
    /// minting a second range (`PitchCorrection.swift:437`).
    ///
    /// ⭐ **ONE journal entry for N notes** ("Set Note Level"), under
    /// `PitchCorrectionUndoKey.structuralKey` — a deliberate level pick never
    /// coalesces, the `setClipNotesCleared` on/off rule extended to a value:
    /// there is no continuous-drag caller for this verb yet, so there is
    /// nothing to coalesce toward (unlike `setClipNotePitchOffset`'s
    /// `.segment` key).
    ///
    /// ⚠️ **ALL OR NOTHING**, the `setClipNotesCleared` rule verbatim: every
    /// id is resolved BEFORE anything is written, a repeated id is folded,
    /// and an empty list is refused in words.
    ///
    /// The refusals are the per-note setters' own, shared rather than
    /// restated. A no-op (every named note already at exactly this dB)
    /// journals nothing, the `setClipNotePitchOffset` idiom.
    ///
    /// Setting every named note back to 0 dB does not clear anything — level
    /// and cleared are independent fields (`NoteSegment.hasLevelEdits`'s own
    /// banner) — it only means "as sung."
    @discardableResult
    public func setClipNoteGain(clipId: UUID,
                                segmentIds: [UUID],
                                gainDb: Double,
                                seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        guard !segmentIds.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "Name at least one note to set the level of. Read the clip's "
                    + "note ids with `clip.getPitchEdits` first.")
        }
        var table = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        var indices: [Int] = []
        var seen = Set<UUID>()
        for segmentId in segmentIds where seen.insert(segmentId).inserted {
            indices.append(try segmentIndex(of: segmentId, in: table, clipId: clipId))
        }
        let clamped = PitchCorrectionMath.finite(gainDb, default: 0).clamped(to: Clip.gainDbRange)
        for index in indices {
            table.segments[index].amplitudeDb = clamped
        }
        let stored = table

        performEdit("Set Note Level", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            // amplitudeDb rides the render key through the digest's level
            // block (`PitchEditSetDigest`, slot 5) — the `setClipNotesCleared`
            // precedent for a key-affecting edit; the field itself is hashed
            // inline rather than moved, so this write re-keys the same slot.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Set a GROUP of notes' pitch offsets in ONE undo step — the pitch
    /// editor's GROUP DRAG (m23-ap I4, design
    /// `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §7): every
    /// selected note moved by the same landed delta, each landing at its OWN
    /// absolute offset. `setClipNotePitchOffset`'s group twin, and the MIRROR of
    /// `setClipNotesCleared` / `setClipNoteGain` beside it — same refusals,
    /// all-or-nothing, a no-op journals nothing, one undo step for N notes.
    ///
    /// Each offset is ABSOLUTE, never a delta — `setClipNotePitchOffset`'s rule
    /// verbatim, for its reason (a dropped call and a call of zero must read
    /// back differently). Unlike `setClipNoteGain`'s single value, every note
    /// carries its own number: a group drag keeps the INTERVALS between notes,
    /// so the notes land on different offsets.
    ///
    /// ⛔ **CLAMPED PER NOTE, EXPLICITLY** to `NoteSegment.pitchOffsetCentsRange`
    /// — a direct field assignment bypasses the healing `init` (this file's
    /// `setClipNotePitchOffset` note). The clamp, the fold of a repeated id and
    /// the refusals are `PitchEditSet.applyingNotePitchOffsets`'s: THE ONE HOME
    /// of the draft rule (`NotePitchDraft.swift`), which the pitch editor's drag
    /// preview also calls, so what a drag plays is what its release stores.
    ///
    /// ⭐ **ONE `performEdit("Tune Notes")` UNDER THE CALLER'S `undoKey`.** The
    /// editor passes `PitchCorrectionUndoKey.group(clipID:selectionToken:)`
    /// (UI design §8.4): a second drag of the SAME selection inside the 800 ms
    /// window coalesces, a different selection starts a new step. A caller with
    /// no selection to name (a batch verb on the wire) passes
    /// `PitchCorrectionUndoKey.structuralKey`. NO DEFAULT, deliberately: which
    /// of the two a caller means is a decision, and a defaulted key is the
    /// silent omission of it.
    ///
    /// ⚠️ **ALL OR NOTHING.** Every id is resolved BEFORE anything is written,
    /// so one unknown id among several leaves the table untouched. A repeated
    /// id with the SAME offset is folded (the `setClipNotesCleared` rule); a
    /// repeated id with two DIFFERENT offsets is REFUSED in words — "last one
    /// wins" would be a silent choice between two things the caller asked for.
    /// An empty list is refused in words.
    ///
    /// The refusals are the per-note setters' own, shared rather than
    /// restated: an unknown clip, a MIDI clip or a take-group comp member
    /// (`locateEditableNoteClip`); no stored table and no seed (`noteTable`);
    /// an unknown note id (`segmentIndex`, which names the count). A no-op
    /// (every named note already at exactly its offset) journals nothing:
    /// `performEdit` records only a changed state.
    ///
    /// The wire verb is `clip.setNotePitches {clipId, notes: [{segmentId,
    /// cents}]}` (`Sources/DAWControl/Commands.swift`) and its MCP tool
    /// `clip_set_note_pitches`, both shipped by the MCP lane after I4; `cents`
    /// is each note's absolute offset, this function's `offsetCents`. A caller
    /// with no selection to name passes `PitchCorrectionUndoKey.structuralKey`
    /// (see the undo-key paragraph above), which is what the verb does.
    @discardableResult
    public func setClipNotePitchOffsets(clipId: UUID,
                                        offsets: [NotePitchOffset],
                                        seedIfAbsent: PitchEditSet? = nil,
                                        undoKey: String?) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        // ⚠️ THE EMPTY LIST IS REFUSED HERE, BEFORE `noteTable`, ON PURPOSE.
        // `applyingNotePitchOffsets` refuses it too, with the same words, but
        // only AFTER a table exists: without this guard a bare clip handed `[]`
        // would be told "no notes to edit yet" instead of "name at least one
        // note". The preview (`previewClipNotePitchDraft`) keeps the same order.
        guard !offsets.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "Name at least one note to tune. Read the clip's note ids with "
                    + "`clip.getPitchEdits` first.")
        }
        // ⭐ THE ONE HOME OF THE DRAFT RULE (m23-ap I1 UI hooks, item 0). The
        // clamp (first, so "the same offset twice" is judged on what would be
        // WRITTEN), the fold of a repeated id, the refusal of one id with two
        // pitches and the unknown-id refusal are all
        // `PitchEditSet.applyingNotePitchOffsets`'s — the transform the drag
        // preview hands the engine. One rule, so a drag cannot play one pitch
        // and its release store another. `ClipNoteSpanAuditionTests`' agreement
        // test still pins the two against each other, so a future inline copy
        // here goes red.
        let stored = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
            .applyingNotePitchOffsets(offsets, clipId: clipId)

        performEdit("Tune Notes", key: undoKey) {
            tracks[t].clips[c].pitchEdits = stored
            // pitchEdits rides the render cache key (`ClipKey.pitchEditSetHash`)
            // — ONE `tracksDidChange` for the whole group, the
            // `setClipNotePitchOffset` precedent for a key-affecting edit.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    // MARK: - Shared resolution

    /// Locate + the two gates every per-note write shares.
    private func locateEditableNoteClip(_ clipId: UUID) throws -> (Int, Int) {
        guard let (t, c) = locateClipIndexForNoteEdits(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard !tracks[t].clips[c].isMIDI else {
            throw ProjectError.pitchDetectionRequiresAudioClip(clipId)
        }
        return (t, c)
    }

    /// The stored table, or the caller's seed, or a teaching refusal.
    ///
    /// ⭐ **THE STORED TABLE WINS UNCONDITIONALLY.** See this file's banner.
    private func noteTable(trackIndex t: Int, clipIndex c: Int,
                           seedIfAbsent: PitchEditSet?) throws -> PitchEditSet {
        if let stored = tracks[t].clips[c].pitchEdits { return stored }
        if let seed = seedIfAbsent, !seed.isEmpty { return seed }
        throw ProjectError.invalidClipEdit(
            "This clip has no notes to edit yet. Run pitch detection on it first — "
                + "`clip.autoCorrectPitch` stores the note table, and opening the note "
                + "editor on the clip builds one from what it hears.")
    }

    /// Find the note, or say how many there are. ⚠️ Naming the count is what
    /// separates "you asked for a note that is not here" from "this clip has no
    /// notes at all" — two different facts that a bare not-found merges.
    private func segmentIndex(of segmentId: UUID, in table: PitchEditSet,
                              clipId: UUID) throws -> Int {
        guard let index = table.segments.firstIndex(where: { $0.id == segmentId }) else {
            throw ProjectError.invalidClipEdit(
                "No note with id \(segmentId) on clip \(clipId). That clip carries "
                    + "\(table.segments.count) note(s); read them back with "
                    + "`clip.getPitchEdits` before editing one.")
        }
        return index
    }

    /// A copy of `segment` with a NEW identity and a new span, every other
    /// field carried by the type's own `Codable`. See `splitClipNoteSegment`.
    private nonisolated static func reidentified(_ segment: NoteSegment,
                                                 startSeconds: Double,
                                                 endSeconds: Double) throws -> NoteSegment {
        let data = try JSONEncoder().encode(segment)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectError.invalidClipEdit(
                "Could not copy that note's settings onto the new half. "
                    + "Nothing was changed.")
        }
        object["id"] = UUID().uuidString
        object["startSeconds"] = startSeconds
        object["endSeconds"] = endSeconds
        let rebuilt = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(NoteSegment.self, from: rebuilt)
    }

    /// Seconds for a person: one decimal, the pitch editor's own ruler density.
    private nonisolated static func secondsText(_ seconds: Double) -> String {
        String(format: "%.1f s", seconds)
    }

    /// Extension-local clip lookup — the repo-wide convention
    /// (`+PitchCorrection`, `+PitchDetection`, `+Analysis`, `+Humanize`,
    /// `+Quantize`, `+Transcription` each keep their own hand-kept twin,
    /// because `ProjectStore`'s private `locateClip(_:)` is not visible
    /// cross-file).
    private func locateClipIndexForNoteEdits(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}

// MARK: - One note's pitch, as a group edit names it

/// ONE note's ABSOLUTE pitch offset, as `ProjectStore.setClipNotePitchOffsets`
/// takes it (m23-ap I4). A named pair rather than a tuple or a dictionary: a
/// dictionary would make a repeated id unrepresentable and so hide the one
/// ambiguity the store refuses in words, and a tuple cannot carry a doc.
public struct NotePitchOffset: Sendable, Equatable, Hashable {
    /// The note, by `NoteSegment.id`.
    public var segmentId: UUID
    /// Where the note lands, in cents from its detected centre — ABSOLUTE.
    public var offsetCents: Double

    public init(segmentId: UUID, offsetCents: Double) {
        self.segmentId = segmentId
        self.offsetCents = offsetCents
    }
}

// MARK: - The note table an editor draws

/// The DETECTED, UNEDITED note table: one segment per NOTE PART
/// (`PitchNoteSplitter.parts`), every edit field at its default.
///
/// ⚠️ **WHY THIS IS NOT `PitchAutoCorrect.editSet(…, strength: 0)`.** That call
/// short-circuits to `PitchEditSet.empty` — no segments at all — because a
/// zero-strength CORRECTION is structurally the identity and the policy is
/// right to say so. An EDITOR needs the opposite: the notes, with no correction
/// asked for. `isEmpty` and `isIdentity` are distinct on `PitchEditSet` for
/// exactly this distinction (its own doc says so), and this is the constructor
/// that produces the second one.
///
/// ⭐ **SEGMENTATION IS `PitchNoteSplitter`'S JOB — THE SAME CALL
/// `PitchAutoCorrect.editSet` MAKES** (p2-seg, design
/// `docs/design/2026-09-24-pitch-note-splitting.md` §4.5). This does not
/// re-decide where a note starts, how short is too short, what a hole means,
/// or where a legato phrase changes note — the splitter answers all four (on
/// top of `PitchAutoCorrect.voicedRuns`, the run rule) and this only drops the
/// correction arithmetic. `PitchEditorModel` draws its blobs from the result,
/// so the editor and the corrector cannot disagree about what a note is: a
/// fresh editor seed shows exactly the notes a Hard Tune pass just wrote.
/// (The editor's measured CONTOUR stays per voiced run, on purpose — see
/// `PitchEditorModel.apply`.)
public enum PitchNoteTable {

    /// Build the table from a detection result.
    public static func detected(
        from result: PitchDetectionResult,
        retuneMs: Double = PitchEditSet.engineMinimumRetuneMs,
        analysisVersion: Int = PitchEditSet.currentAnalysisVersion
    ) -> PitchEditSet {
        // f0 alone decides (design §12 item 3: onset placement, S3, is not scheduled).
        let parts = PitchNoteSplitter.parts(in: result.frames, frameRateHz: result.frameRateHz,
                                            onsetSeconds: [])
        let segments = parts.map { part in
            NoteSegment(startSeconds: part.startSeconds,
                        endSeconds: part.endSeconds,
                        detectedHz: part.centreHz,
                        detectedConfidence: part.medianConfidence)
        }
        return PitchEditSet(analysisVersion: analysisVersion,
                            segments: segments,
                            retuneMs: retuneMs)
    }
}
