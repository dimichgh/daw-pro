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
    /// halves are then independent: dragging one moves one. TWO exceptions,
    /// re-derived rather than copied: the right half's wobble fade-in
    /// (`vibratoOnsetSeconds`, C5a-2, vibrato-handle design §11.1), so a split
    /// never restarts a generated wobble's fade at the cut; and the DRAWN
    /// SHAPE (C5b-3a, design §5.3), which each half keeps only on its own side
    /// of the cut (`NoteShapeSamples.halves`).
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
        let table = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
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
        // ⭐ Natural tuning §4.b.5, THE SPLIT RULE FOR SLIDES: the LEFT half's
        // join is the NEW interior one (Δ = 0 across a cut), so its width goes
        // back to Auto; the RIGHT half keeps the parent's rear width (it is
        // the same join as before), and both keep the parent's `glideFollow`
        // (the round trip below carries it).
        left.transitionOutMs = 0
        var right = try Self.reidentified(parent, startSeconds: cut, endSeconds: parent.endSeconds)
        // ⭐ C5a-2 (vibrato-handle design §11.1): THE ONE FIELD A SPLIT
        // RE-DERIVES. The fade-in of a generated wobble is measured from the
        // note's START, so a verbatim copy would restart the right half's fade
        // at the cut and dip the wobble to nothing there. The right half keeps
        // only the fade time the parent had LEFT at the cut. Exact once the
        // cut is past the fade (onset 0: full depth from the cut, which is what
        // the parent played, and the phase continues because the anchor is
        // shared). Inside the fade it is bounded, not exact: the right half's
        // fade starts at zero while the parent's is part-way up. Rate, depth,
        // anchor and both scales ride the round trip unchanged; the LEFT half
        // is untouched. A parked onset on a note with no generated wobble is
        // inert and is copied as it is.
        if parent.hasGeneratedVibrato && parent.vibratoOnsetSeconds > 0 {
            right.vibratoOnsetSeconds = max(0, parent.vibratoOnsetSeconds - (cut - parent.startSeconds))
        }
        // ⭐ C5b-3a (design §5.3): THE DRAWN SHAPE IS SLICED, NOT COPIED. The
        // round trip above hands the right half the parent's WHOLE drawing.
        // On the global grid that would even SOUND right (each half reads only
        // its own gate), which is exactly why the storage test, not a physics
        // test, is the gate: both halves would carry, re-save and re-hash the
        // other half's samples forever. `NoteShapeSamples.halves` is the rule:
        // an index split at `ceil(cut·100)`, each half re-based, an empty or
        // all-zero half stored as no drawing. Direct assignment skips
        // `NoteSegment.init`, so it relies on `halves` for index 0 on a clear.
        let shapes = NoteShapeSamples.halves(of: parent, atSourceSecond: cut)
        left.shapeStartIndex = shapes.left.startIndex
        left.shapeTenthsOfCents = shapes.left.tenthsOfCents
        right.shapeStartIndex = shapes.right.startIndex
        right.shapeTenthsOfCents = shapes.right.tenthsOfCents

        var segments = table.segments
        segments.replaceSubrange(index...index, with: [left, right])
        // ⭐ `withSegments`, THE ONE REBUILD (natural tuning X2): every other
        // stored field of the set rides along. The memberwise rebuild this
        // replaced carried only the analysis version and the retune: it
        // dropped the natural-tuning fields (a split would silently revert a
        // vocal to legacy tuning) and the auto-correct stamp, which the
        // stamp's own doc says a split leaves alone. A split is a HAND edit,
        // and never a no-op (it always adds a note): through D4-1's home,
        // `afterHandEdit(from:)`, on a vocal that predates natural tuning the
        // split also updates the whole vocal, in this undo step (the user's
        // ruling (b), `handEditUpgradesLegacyVocal`).
        let stored = table.withSegments(segments).afterHandEdit(from: table)

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
    /// `cleared: false` brings a note back at its own level. ⚠️ The one
    /// exception is D4-1 (b), shared by every per-note writer: on a vocal
    /// tuned before natural tuning (`predatesNaturalTuning`) this first hand
    /// edit also updates the whole vocal (`afterHandEdit(from:)`), in the same
    /// undo step, unless it changes no note (a Restore of a note that is not
    /// cleared), which updates nothing and journals nothing. The offline
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
        let before = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        var table = before
        var indices: [Int] = []
        var seen = Set<UUID>()
        for segmentId in segmentIds where seen.insert(segmentId).inserted {
            indices.append(try segmentIndex(of: segmentId, in: table, clipId: clipId))
        }
        for index in indices {
            table.segments[index].isCleared = cleared
        }
        // Natural tuning D4-1 (b): clearing or restoring a note is a HAND
        // edit, so D4-1's home, `afterHandEdit(from:)`, is the last step: it
        // updates an old vocal, unless nothing changed (a Restore of a note
        // that is not cleared), which updates nothing and journals nothing
        // (`NaturalTuningHandEditCensusTests` keeps every per-note writer
        // routed through it).
        let stored = table.afterHandEdit(from: before)

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
    ///
    /// D4-1 (b): a level is a hand edit, so on a vocal that
    /// `predatesNaturalTuning` it also updates the whole vocal
    /// (`afterHandEdit(from:)`), in the same undo step; the level a note
    /// already has changes nothing and updates nothing.
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
        let before = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        var table = before
        var indices: [Int] = []
        var seen = Set<UUID>()
        for segmentId in segmentIds where seen.insert(segmentId).inserted {
            indices.append(try segmentIndex(of: segmentId, in: table, clipId: clipId))
        }
        let clamped = PitchCorrectionMath.finite(gainDb, default: 0).clamped(to: Clip.gainDbRange)
        for index in indices {
            table.segments[index].amplitudeDb = clamped
        }
        // Natural tuning D4-1 (b): a level is a HAND edit (`setClipNotesCleared`).
        let stored = table.afterHandEdit(from: before)

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

    /// Bring a vocal tuned BEFORE natural tuning onto it (m23-nt, design
    /// `docs/design/2026-09-25-natural-tuning.md` X4): the voice size kept
    /// (`formantCorrection`), consonants left untuned, and soft joins
    /// (`transitionSlopeCentsPerSecond`), all at the values a NEW set is
    /// seeded with (`PitchEditSet.seeded`). ⭐ **THE ONE UPGRADE PATH.** The
    /// editor's "Tuned before this update. Tap to update." line, the wire's
    /// `clip.upgradeNaturalTuning`, and §4's D4-1 hook all call this.
    ///
    /// It writes the three set-level fields and NOTHING ELSE: no note, no
    /// `glideFollow` (the part kinds are gone once a table is stored), no
    /// retune, no stamp. ONE undo step ("Update Tuning") under
    /// `PitchCorrectionUndoKey.structuralKey`: a deliberate switch never
    /// coalesces. A set that already carries the seed values journals nothing
    /// (the `setClipNotePitchOffset` no-op idiom).
    ///
    /// ⚠️ It SETS the formant amount, as X4 says; it switches consonants on
    /// UNLESS somebody switched them off (`.offByChoice`, NT-C2-F1); and it
    /// fills the SLOPE only when it is 0 (C4's ruling). Both exceptions are
    /// argued at `PitchEditSet.upgradedToNaturalTuning`, the pure transform
    /// this and D4-1's `afterHandEdit()` share: an explicit pick survives the
    /// tap.
    ///
    /// Refuses in words: an unknown clip, a MIDI clip or a comp member (the
    /// per-note gates), and a clip with no stored table (nothing was tuned, so
    /// nothing predates the feature; a table the editor seeds now is already
    /// seeded with these values).
    @discardableResult
    public func upgradeToNaturalTuning(clipId: UUID) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        guard let table = tracks[t].clips[c].pitchEdits else {
            throw ProjectError.invalidClipEdit(
                "This clip has no tuning to update. Tune it first (the note editor or "
                    + "`clip.autoCorrectPitch`); new tuning already keeps the singer's voice "
                    + "size, consonants and slides.")
        }
        let stored = table.upgradedToNaturalTuning()

        performEdit("Update Tuning", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            // The three fields are render material (digest slots 7/8/9 once
            // NT-E1 lands), the `setClipNotesCleared` precedent for a
            // key-affecting edit.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Set a GROUP of notes' VOICE (formant) offset, in semitones: natural
    /// tuning §1(b), the Voice tool's store leg and `clip.setNoteFormant`'s
    /// one home. `setClipNoteGain`'s mirror for `formantOffsetSemitones`:
    /// same refusals, all-or-nothing, a repeated id folded, an empty list
    /// refused in words, a no-op journals nothing, ONE undo step for N notes
    /// ("Set Note Voice", `structuralKey`: the Voice drag commits once, on
    /// gesture end).
    ///
    /// `semitones` is the note's FINAL offset, 0 = as sung, NOT a delta (the
    /// `setClipNoteGain` rule, for its reason). Negative = deeper, positive =
    /// brighter; the pitch does not move.
    ///
    /// ⛔ **CLAMPED HERE, EXPLICITLY,** to `NoteSegment.formantOffsetSemitonesRange`
    /// (±24): a direct field assignment bypasses the healing `init` (this
    /// file's banner). A non-finite value reads as 0, as `setClipNoteGain`'s
    /// does.
    ///
    /// ⚠️ **ONE REFUSAL `setClipNoteGain` DOES NOT HAVE: a SOUND
    /// (`.unpitched`).** A breath or consonant has no sung f0 and no voice to
    /// reshape, the formant curve does not read an untouched sound's offset,
    /// and under `keepsConsonantsUntuned` it plays the dry take anyway
    /// (`NoteSegment.engagesFormantCurve` argues the ruling). Storing the
    /// value would be a write that takes and does nothing, so it is refused
    /// in words, before anything is written.
    ///
    /// D4-1 (b): a note's Voice is a hand edit, so on a vocal that
    /// `predatesNaturalTuning` it also updates the whole vocal
    /// (`afterHandEdit(from:)`), in the same undo step; the Voice a note
    /// already has changes nothing and updates nothing. The set-level amount
    /// (`setClipFormantCorrection`) is an explicit switch and never does.
    @discardableResult
    public func setClipNoteFormant(clipId: UUID,
                                   segmentIds: [UUID],
                                   semitones: Double,
                                   seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        guard !segmentIds.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "Name at least one note to change the voice of. Read the clip's "
                    + "note ids with `clip.getPitchEdits` first.")
        }
        let before = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        var table = before
        var indices: [Int] = []
        var seen = Set<UUID>()
        for segmentId in segmentIds where seen.insert(segmentId).inserted {
            let index = try segmentIndex(of: segmentId, in: table, clipId: clipId)
            guard table.segments[index].origin != .unpitched else {
                throw ProjectError.invalidClipEdit(
                    "Note \(segmentId) is a sound with no sung pitch (a breath or a "
                        + "consonant), so it has no voice to make deeper or brighter. "
                        + "Nothing was changed. Name sung notes only.")
            }
            indices.append(index)
        }
        let clamped = PitchCorrectionMath.finite(semitones, default: 0)
            .clamped(to: NoteSegment.formantOffsetSemitonesRange)
        for index in indices {
            table.segments[index].formantOffsetSemitones = clamped
        }
        // Natural tuning D4-1 (b): a note's Voice is a HAND edit
        // (`setClipNotesCleared`). The set-level amount below is not.
        let stored = table.afterHandEdit(from: before)

        performEdit("Set Note Voice", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            // The offset is hashed inline in the digest and engages the
            // formant curve (slot 7, NT-E1): a key-affecting edit.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Set how much of a moved note's formant shift the clip's tuning REMOVES
    /// (`PitchEditSet.formantCorrection`, natural tuning §1(b)): the
    /// set-level voice-size control and `clip.setFormantCorrection`'s one home.
    ///
    ///  * `nil` restores LEGACY: the clip's `formantPreserve` flag alone,
    ///    exactly as a set tuned before §1 renders.
    ///  * otherwise the value is clamped to `formantCorrectionRange` (0...1).
    ///    ⚠️ `0.0` is an ENGAGED amount, not legacy: it is stored and saved
    ///    as 0.0 (`PitchEditSet.encode`).
    ///  * a NON-FINITE amount is REFUSED in words. The set's `init` would read
    ///    it as nil, and a NaN silently becoming legacy is a tone change
    ///    nobody asked for.
    ///
    /// ONE undo step ("Keep Voice Size", R26's row name; `structuralKey`: the control
    /// commits once per gesture); a no-op journals nothing. Nothing else in
    /// the set moves. `seedIfAbsent` is the per-note setters' seam (this
    /// file's banner): the editor's header control works on a clip whose
    /// table is still only the editor's seed.
    ///
    /// Refuses in words: an unknown clip, a MIDI clip or a comp member (the
    /// per-note gates), and no stored table with no seed.
    @discardableResult
    public func setClipFormantCorrection(clipId: UUID,
                                         amount: Double?,
                                         seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        if let amount, !amount.isFinite {
            throw ProjectError.invalidClipEdit(
                "The voice-size amount has to be a number from 0 to 1 (or null for the "
                    + "behaviour from before voice-keeping); \(amount) is not one. "
                    + "Nothing was changed.")
        }
        var table = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        table.formantCorrection = amount?.clamped(to: PitchEditSet.formantCorrectionRange)
        let stored = table

        performEdit("Keep Voice Size", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            // A set-level field of the edit set: render material through the
            // set digest (slot 7, NT-E1), a key-affecting edit.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    // MARK: - Consonants keep their own pitch (natural tuning §2, NT-C C2)
    //
    // ✅ SHIPPED (NT-W, 2026-09-25): the wire verb is
    //   `clip.setConsonantProtection {clipId, enabled}` (`Commands.swift`) and
    //   the MCP tool is `clip_set_consonant_protection`.

    /// Switch "consonants and breaths keep their own pitch" on or off for a
    /// clip's tuning: `PitchEditSet.keepsConsonantsUntuned`, natural tuning
    /// §2e's `clip.setConsonantProtection` and the editor's Consonants row.
    /// On, the gaps between notes play the untouched take
    /// (`PitchConsonantMask.swift`); off, they play the tuned render as
    /// before.
    ///
    /// An EXPLICIT request, so it writes this one field and nothing else,
    /// whatever D4-1 says: on a LEGACY set it does not upgrade the voice size
    /// or the slides (the `setClipPitchTransitionSmoothness` and
    /// `setClipFormantCorrection` rule; `upgradeToNaturalTuning` is the one
    /// path that sets all three). It is stored whatever the clip's stretch or
    /// transpose: the mix is then inactive, and
    /// `PitchEditSet.consonantMixInactiveReason` says why.
    ///
    /// ⭐ **IT RECORDS A CHOICE** (NT-C2-F1, W7-D2): OFF is stored as
    /// `.offByChoice`, which a preset re-run and the natural-tuning update
    /// keep; ON is `.on`, the seed's own state, which they keep anyway.
    ///
    /// ONE undo step ("Keep Consonants", `structuralKey`: a deliberate
    /// on/off never coalesces); a no-op journals nothing. ⚠️ Switching OFF a
    /// set that is off BY DEFAULT is NOT a no-op: it sounds the same, but it
    /// records the choice, which changes what the next preset does (it keeps
    /// the consonants off instead of switching them on), so it is one undo
    /// step back to "never chosen". Picking the state already stored (ON on
    /// ON, OFF on a chosen OFF) journals nothing. Refuses in words:
    /// an unknown clip, a MIDI clip or a comp member (the per-note gates), and
    /// a clip with no tuning and no seed (`PitchConsonantSentences.noTuning`):
    /// silently minting an empty table would be a side effect nobody asked
    /// for (§2e). `seedIfAbsent` is the per-note setters' seam, so the
    /// editor's row works on a clip whose table is still only the editor's
    /// seed.
    @discardableResult
    public func setClipConsonantProtection(clipId: UUID,
                                           enabled: Bool,
                                           seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        guard tracks[t].clips[c].pitchEdits != nil || !(seedIfAbsent?.isEmpty ?? true) else {
            throw ProjectError.invalidClipEdit(PitchConsonantSentences.noTuning)
        }
        var table = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        // A CHOICE either way (see the doc): never the Bool accessor, which
        // cannot record one.
        table.consonantProtection = enabled ? .on : .offByChoice
        let stored = table

        performEdit("Keep Consonants", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            // A set-level field: render material through digest slot 8, a
            // key-affecting edit (the `setClipFormantCorrection` precedent).
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    // MARK: - Slides between notes (natural tuning §4, NT-C C4)
    //
    // ✅ SHIPPED (NT-W): `clip.setNoteTransition`,
    //   `clip.setPitchTransitionSmoothness` and `clip.setNoteGlideFollow`
    //   reach the three functions below (`Commands.swift`).

    /// Set the width of the slide from ONE note into the next: natural
    /// tuning §4.e's `clip.setNoteTransition` and the pitch editor's
    /// rear-edge drag (R12). `segmentId` is the LEFT note of the join
    /// (Melodyne's "rear part of the note").
    ///
    /// `widthMs` is ms of the ORIGINAL take: nil or 0 = Auto (the width
    /// grows with the size of the jump, `PitchEditSet.softJoin`), otherwise
    /// clamped to 30...1000. What APPLIES is also capped at the shorter of
    /// the two notes; `PitchEditSet.joinReading(afterSegmentAt:)` reports it.
    ///
    /// ⭐ **THE RULE LIVES IN `PitchEditSet.applyingNoteTransition`**
    /// (`NotePitchDraft.swift`), the one home a drag's draft also calls. It
    /// refuses in words (`PitchTransitionSentences`): a negative or
    /// non-finite width, an unknown note, a SOUND, the LAST sung note, and a
    /// note followed by a GAP. The per-note gates come first: an unknown
    /// clip, a MIDI clip or a comp member, and no table with no seed.
    ///
    /// Coalescing key `PitchCorrectionUndoKey.transition(clipID:segmentID:)`:
    /// two width drags of the same join inside 800 ms fold into ONE undo
    /// step; a no-op journals nothing. On a LEGACY set (`predatesNaturalTuning`)
    /// the transform's `afterHandEdit(from:)` also updates the whole vocal, in the
    /// same undo step: D4-1 (b), the user's ruling of 2026-09-26.
    @discardableResult
    public func setClipNoteTransition(clipId: UUID,
                                      segmentId: UUID,
                                      widthMs: Double?,
                                      seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        let stored = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
            .applyingNoteTransition(segmentId: segmentId, widthMs: widthMs, clipId: clipId)

        performEdit("Change Slide",
                    key: PitchCorrectionUndoKey.transition(clipID: clipId, segmentID: segmentId)) {
            tracks[t].clips[c].pitchEdits = stored
            // A width is render material (digest slot 9), a key-affecting
            // edit: the `setClipNotePitchOffset` precedent.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Set how smoothly EVERY moved note slides into the next: the set-level
    /// `transitionSlopeCentsPerSecond`, natural tuning §4.e's
    /// `clip.setPitchTransitionSmoothness` and the editor's "Slides" row.
    ///
    /// nil = the default (`PitchEditSet.defaultTransitionSlope`, 3000 c/s);
    /// otherwise clamped to 500...20000. **0 is refused in words:** going
    /// back to the legacy rule is Undo's job, never a setting (§4.e), and a
    /// negative or non-finite value is refused too
    /// (`PitchEditSet.applyingTransitionSmoothness`, the one home).
    ///
    /// An EXPLICIT request, so on a LEGACY set it switches this field alone,
    /// whatever D4-1 says (§4.j, X4). ONE undo step ("Slide Smoothness",
    /// `structuralKey`: the control commits once per pick); a no-op journals
    /// nothing. Refuses in words: an unknown clip, a MIDI clip or a comp
    /// member, and no table with no seed.
    @discardableResult
    public func setClipPitchTransitionSmoothness(clipId: UUID,
                                                 centsPerSecond: Double?,
                                                 seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        let stored = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
            .applyingTransitionSmoothness(centsPerSecond: centsPerSecond)

        performEdit("Slide Smoothness", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            // A set-level field: render material through digest slot 9.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Make ONE sung note follow the notes beside it (or stop following):
    /// natural tuning §4.e's `clip.setNoteGlideFollow`. `amount` 0 = the
    /// note keeps its own pitch (today); 1 = it TILTS from the previous
    /// note's offset to the next one's, so a slide starts where a moved
    /// neighbour now is instead of snapping back. Clamped to 0...1.
    ///
    /// New editor tables already follow on every sung slide (`glideFollow`
    /// 1 on `.transition` parts); presets never do (the user's (a-T) ruling).
    /// This is how an agent makes a PRESET-built slide follow: read
    /// `origin == .transition` on `clip.getPitchEdits` to find the slides.
    ///
    /// ⭐ The rule lives in `PitchEditSet.applyingNoteGlideFollow`. Refuses
    /// in words: a non-finite amount, an unknown note, a SOUND (a lone sound
    /// is refused, C5a-2's rule for a one-note verb), and an amount above 0
    /// on a note with a GAP on both sides (the write would take and do
    /// nothing); 0 is always allowed. ONE undo step ("Slide Follow",
    /// `structuralKey`: a deliberate on/off); a no-op journals nothing.
    @discardableResult
    public func setClipNoteGlideFollow(clipId: UUID,
                                       segmentId: UUID,
                                       amount: Double,
                                       seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        let stored = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
            .applyingNoteGlideFollow(segmentId: segmentId, amount: amount, clipId: clipId)

        performEdit("Slide Follow", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            // A follow amount is render material (digest slot 9).
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    // MARK: - A note's wobble (m23-ap C5a-2, natural tuning §3 L2)
    //
    // TODO(C5a-3): wire `clip.setNoteVibrato` (Sources/DAWControl/Commands.swift,
    //   vibrato-handle design §12.1; `reset: true` → `resetClipNoteVibrato`) and
    //   expose it as MCP tool `clip_set_note_vibrato` (mcp-server/src/server.ts, §12.4).
    // TODO(NT-L3): wire `clip.setNoteVibratos` (natural tuning §3e, batch, no
    //   `reset`) → `setClipNotesVibrato` with `structuralKey`, and expose it as
    //   MCP tool `clip_set_note_vibratos`. Both lanes copy the refusal sentences
    //   from `NoteVibratoLimits` verbatim and echo `skippedSoundIds` in words.

    /// Change ONE note's wobble: C5a-2's store leg and the one home of the
    /// C5a-3 verb `clip.setNoteVibrato` (design
    /// `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §10).
    ///
    /// ⭐ **A ONE-ITEM CALL OF `setClipNotesVibrato`** (natural tuning §3b), so
    /// the single and the batch forms cannot drift apart: the same clamp, the
    /// same refusals, the same words. Everything that function's doc says
    /// holds here; what this form adds is its undo key.
    ///
    /// Coalescing key: `PitchCorrectionUndoKey.vibrato(clipID:segmentID:)`, ONE
    /// key for both mechanisms (see the key's doc), so two commits on the SAME
    /// note inside the journal's 800 ms window fold into one undo step. A
    /// single-note DRIFT drag (natural tuning's Drift tool) wants
    /// `.drift(clipID:segmentID:)` instead, and gets it by calling the batch
    /// form with one item and that key.
    ///
    /// A SOUND (`.unpitched`) is refused with the unpitched design's §1.7
    /// sentence, verbatim: "No pitch here, so there is no wobble to change."
    @discardableResult
    public func setClipNoteVibrato(clipId: UUID,
                                   segmentId: UUID,
                                   edit: NoteVibratoEdit,
                                   seedIfAbsent: PitchEditSet? = nil) throws -> NoteVibratoResult {
        let batch = try setClipNotesVibrato(
            clipId: clipId,
            edits: [NoteVibratoItem(segmentId: segmentId, edit: edit)],
            seedIfAbsent: seedIfAbsent,
            undoKey: PitchCorrectionUndoKey.vibrato(clipID: clipId, segmentID: segmentId))
        // One item that is not a sound (a lone sound is refused), so exactly
        // one report. The guard is a second line of defence, never a path.
        guard let note = batch.notes.first else {
            throw ProjectError.invalidClipEdit(NoteVibratoLimits.noPitchHereSentence)
        }
        return NoteVibratoResult(clip: batch.clip, requested: note.requested,
                                 segment: note.segment, clamped: note.bound)
    }

    /// Change a GROUP of notes' wobble in ONE undo step: natural tuning §3b's
    /// batch twin (L2), the store leg of the Wobble and Drift tools on a
    /// selection and of the NT-L3 verb `clip.setNoteVibratos`.
    ///
    /// Each item is ABSOLUTE, never a delta (the `setClipNotePitchOffsets`
    /// rule, for its reason: a dropped call and a call of 1 must read back
    /// differently). A selection drag moves every note "by the same Δ from its
    /// OWN mouse-down value"; the CALLER computes where each note lands, and
    /// this clamps each landing PER NOTE with `NoteVibratoLimits.clamp` at the
    /// clip's `stretchRatio`.
    ///
    /// ⭐ **THE RULE LIVES IN `PitchEditSet.applyingNoteVibratos`**, the one
    /// home a gesture's draft can also call, so a drag cannot play one wobble
    /// and its release store another. Its doc carries the full list; in short:
    ///  * refused in words, ALL OR NOTHING: an empty list, an item with no
    ///    field ("Nothing to change: give at least one wobble setting."), a NaN
    ///    or an infinity (naming the field), an unknown note (naming the
    ///    count), one note named with two different edits, and a batch whose
    ///    every note is a sound;
    ///  * ⭐ **A SOUND NAMED BESIDE SUNG NOTES IS SKIPPED AND REPORTED**
    ///    (`NoteVibratoBatchResult.skippedSoundIds` and its sentence), never
    ///    written and never silent. Why skip here when `setClipNoteFormant`
    ///    refuses: "select all, then Drift" is natural tuning's macro, agents
    ///    "send the batch verb with every id", and every table the editor
    ///    seeds carries its sounds, so refusing would fail that macro on any
    ///    take with a breath in it.
    ///
    /// ⚠️ **NO HIDDEN DEFAULTS** (design §10 item 5): only the fields an item
    /// supplies are written. An agent that asks for depth 50 gets depth 50 and
    /// nothing else; the anchor stays where it was.
    ///
    /// ⭐ **ONE `performEdit` UNDER THE CALLER'S `undoKey`, ONE
    /// `tracksDidChange`.** NO DEFAULT KEY, the `setClipNotePitchOffsets` rule:
    /// which key a caller means is a decision. The Wobble tool on a selection
    /// passes `PitchCorrectionUndoKey.vibratoGroup(clipID:selectionToken:)`,
    /// the Drift tool `driftGroup`, a one-note Drift drag `drift`, a discrete
    /// action (Flatten, the double-click toggle) or a wire batch
    /// `structuralKey`. The step is named "Change Drift" when every item
    /// touches `driftScale` alone and "Change Wobble" otherwise, so the Edit
    /// menu never names the wobble for a change that left it alone.
    ///
    /// A no-op (every value already stored) journals nothing: `performEdit`
    /// records only a changed state (design §10 item 7). An inaudible result
    /// (depth with no rate) is reported in `NoteVibratoNoteReport.silentWobble`,
    /// never refused: an agent may send depth and rate in two calls.
    ///
    /// The per-note setters' shared refusals come first: an unknown clip, a
    /// MIDI clip or a take-group comp member (`locateEditableNoteClip`), and
    /// no stored table with no seed (`noteTable`).
    ///
    /// D4-1 (b): a wobble or drift change is a hand edit, so on a vocal that
    /// `predatesNaturalTuning` it also updates the whole vocal
    /// (`afterHandEdit(from:)`), in the same undo step; an edit whose values
    /// are all already stored changes nothing and updates nothing.
    /// `setClipNoteVibrato` is a one-item call of this, so it does too.
    ///
    /// ⚠️ Natural tuning §3e's per-item `tooShortToSeparate` needs
    /// `minimumSeparableSeconds`, which G3 (L1) has not produced yet, so it is
    /// not reported here. The wire lane derives it from each report's
    /// `segment.durationSeconds` once that constant exists.
    @discardableResult
    public func setClipNotesVibrato(clipId: UUID,
                                    edits: [NoteVibratoItem],
                                    seedIfAbsent: PitchEditSet? = nil,
                                    undoKey: String?) throws -> NoteVibratoBatchResult {
        let (t, c) = try locateEditableNoteClip(clipId)
        // ⚠️ THE EMPTY LIST IS REFUSED BEFORE `noteTable`, the
        // `setClipNotePitchOffsets` order: a bare clip handed `[]` is told
        // "name at least one note", not "no notes to edit yet".
        guard !edits.isEmpty else {
            throw ProjectError.invalidClipEdit(NoteVibratoLimits.nameAtLeastOneNoteSentence)
        }
        let application = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
            .applyingNoteVibratos(edits, stretchRatio: tracks[t].clips[c].stretchRatio,
                                  clipId: clipId)
        // Natural tuning D4-1 (b): a wobble or drift change is a HAND edit;
        // `applyingNoteVibratos` ends in `afterHandEdit(from: self)` (the one
        // home the pitch editor's wobble draft also runs), so this set is
        // already updated on an old vocal, and left alone by a no-op.
        let stored = application.set
        let label = edits.allSatisfy(\.edit.isDriftOnly) ? "Change Drift" : "Change Wobble"

        performEdit(label, key: undoKey) {
            tracks[t].clips[c].pitchEdits = stored
            // Every wobble field is render material: the scales and the
            // generator are hashed inline per segment, the anchor in the
            // digest's slot 2. A key-affecting edit, ONE `tracksDidChange`
            // for the whole group.
            engine?.tracksDidChange(tracks)
        }
        return NoteVibratoBatchResult(clip: tracks[t].clips[c], notes: application.notes,
                                      skippedSoundIds: application.skippedSoundIds)
    }

    /// Put ONE note's wobble back to how it was sung: all six fields to their
    /// defaults (keep 1, drift 1, rate 0, depth 0, onset 0, anchor 0), design
    /// §10 item 8. The one home of "Back to how you sang it" and of the C5a-3
    /// verb's `reset: true`.
    ///
    /// ONE `performEdit("Reset Wobble")` under
    /// `PitchCorrectionUndoKey.structuralKey`: a deliberate, discrete reset
    /// never merges into the drag before it (the preset rule, 09-22 §8.3). A
    /// note already as sung journals nothing.
    ///
    /// ⚠️ **A SOUND**: refused with §1.7's sentence while it carries no wobble
    /// field (there is nothing to put back). A sound that DOES carry one can
    /// only come from a hand-authored file, since every setter refuses sounds,
    /// and reset is then its one cleanup path, so it is allowed: it only ever
    /// removes.
    ///
    /// D4-1 (b): a reset is a hand edit, so on a vocal that
    /// `predatesNaturalTuning` it also updates the whole vocal
    /// (`afterHandEdit(from:)`), in the same undo step. A note already as
    /// sung changes nothing, so it updates nothing and journals nothing.
    @discardableResult
    public func resetClipNoteVibrato(clipId: UUID,
                                     segmentId: UUID,
                                     seedIfAbsent: PitchEditSet? = nil) throws -> NoteVibratoResult {
        let (t, c) = try locateEditableNoteClip(clipId)
        let before = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        var table = before
        let index = try segmentIndex(of: segmentId, in: table, clipId: clipId)
        let note = table.segments[index]
        // The defaults are inside every range, so the clamp binds nothing;
        // it is called so the write goes through the one door.
        let clamp = try NoteVibratoLimits.clamp(.asSung, stretchRatio: tracks[t].clips[c].stretchRatio)
        let reset = clamp.applied(to: note)
        guard note.origin != .unpitched || reset != note else {
            throw ProjectError.invalidClipEdit(NoteVibratoLimits.noPitchHereSentence)
        }
        table.segments[index] = reset
        // Natural tuning D4-1 (b): putting a wobble back is a HAND edit too
        // (`setClipNotesCleared`).
        let stored = table.afterHandEdit(from: before)

        performEdit("Reset Wobble", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            engine?.tracksDidChange(tracks)
        }
        return NoteVibratoResult(clip: tracks[t].clips[c], requested: .asSung,
                                 segment: reset, clamped: clamp.bound)
    }

    // MARK: - A note's drawn pitch line (m23-ap C5b-3a, freehand design §5.7)
    //
    // ✅ C5b-3b SHIPPED: `clip.setNoteShape {clipId, noteId, points?, clear?}`
    //   (Sources/DAWControl/Commands.swift, immediately after
    //   clip.setConsonantProtection) and MCP tool `clip_set_note_shape`
    //   (mcp-server/src/server.ts) call the function below. `clip.getPitchEdits`
    //   gains a per-segment `shape {startSeconds, stepSeconds: 0.01, cents}`,
    //   present only when `NoteSegment.hasShape`.

    /// Draw (or clear) the pitch line of one or more notes in ONE undo step:
    /// C5b's store leg (design §5.7), the one home the brush (C5b-4, every note
    /// a stroke touched) and the wire verb `clip.setNoteShape` (C5b-3b) call.
    ///
    /// Each value is the note's WHOLE new drawing, ABSOLUTE, never a patch —
    /// this file's "a final value, not a delta" rule, for its reason. The
    /// rule lives in `PitchEditSet.applyingNoteShapes` (`NoteShapeSamples.swift`),
    /// the one home a brush's live draft can also call:
    ///  * trimmed to the note's grid span, ZERO-FILLED where the value does not
    ///    reach (the held-ends trap), clamped to ±1200 c, and stored EMPTY when
    ///    all zero (design §5.2); `NoteShapeSamples.clear` removes a drawing;
    ///  * to change PART of a note, build the value with
    ///    `NoteShapeSamples.splicing(points:onto:)`, which keeps the rest.
    ///
    /// ⭐ **ONE `performEdit`, ONE `tracksDidChange`**, under
    /// `PitchCorrectionUndoKey.structuralKey`: two strokes are two undo steps,
    /// like two cuts (§5.5). The step is "Draw Pitch"; a call that only clears
    /// is "Reset Drawn Shape", the note menu's own words (§5.5), so the Edit
    /// menu never names a drawing for a change that removed one. A no-op
    /// (every note already stores exactly what it would store) journals
    /// nothing: normalising is deterministic and `performEdit` records only a
    /// changed state.
    ///
    /// ⚠️ **ALL OR NOTHING.** Refused in words, before anything is written: an
    /// unknown clip, a MIDI clip or a take-group comp member
    /// (`locateEditableNoteClip`); an empty map (before `noteTable`, the
    /// `setClipNotePitchOffsets` order); no stored table and no seed
    /// (`noteTable`); an unknown note id (`segmentIndex`, which names the
    /// count); and the transform's own refusals (`NoteShapeSentences`).
    ///
    /// ⭐ **THE SOUND RULING (C5b-3a): REFUSE.** A breath or a consonant
    /// (`.unpitched`) has no pitch line to draw, so drawing on one is refused
    /// in words, like `setClipNoteFormant` (not moved like a pitch drag, R21:
    /// a move has a meaning on a sound, a line does not). A CLEAR of a drawing
    /// a sound already carries is allowed: only a hand-written file can put
    /// one there, and this is its cleanup path (`resetClipNoteVibrato`'s rule).
    /// A brush must treat sounds as GAPS.
    ///
    /// On a vocal that `predatesNaturalTuning` it also updates the whole
    /// vocal, in the same undo step: a drawing is a HAND edit, and the
    /// transform ends in `afterHandEdit()`, D4-1's hook (the user's ruling
    /// (b), `handEditUpgradesLegacyVocal`; the C4 slide setters' rule).
    @discardableResult
    public func setClipNoteShapes(clipId: UUID,
                                  shapes: [UUID: NoteShapeSamples],
                                  seedIfAbsent: PitchEditSet? = nil) throws -> Clip {
        let (t, c) = try locateEditableNoteClip(clipId)
        guard !shapes.isEmpty else {
            throw ProjectError.invalidClipEdit(NoteShapeSentences.nameAtLeastOneNote)
        }
        let table = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        // The unknown-id refusal is `segmentIndex`'s own, in a fixed order so
        // the same bad call names the same note every time.
        for segmentId in shapes.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            _ = try segmentIndex(of: segmentId, in: table, clipId: clipId)
        }
        let stored = try table.applyingNoteShapes(shapes, clipId: clipId)
        let label = shapes.values.allSatisfy(\.isClear) ? "Reset Drawn Shape" : "Draw Pitch"

        performEdit(label, key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = stored
            // The drawing is render material (digest slot 4, and it breaks
            // `isPitchIdentity`), a key-affecting edit: ONE `tracksDidChange`
            // for every note the call names.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }


    /// C5b-3b — the stored note `noteId` on audio clip `clipId`, READ-ONLY,
    /// refused with the SAME sentences in the SAME order as every per-note
    /// writer (`locateEditableNoteClip` → `noteTable` → `segmentIndex`), so a
    /// wire pre-check (`clip.setNoteShape` splices onto the CURRENT drawing)
    /// never keeps its own copy of them. No seed: the wire rule.
    public func editableStoredNote(clipId: UUID, noteId: UUID) throws -> NoteSegment {
        let (t, c) = try locateEditableNoteClip(clipId)
        let table = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: nil)
        return table.segments[try segmentIndex(of: noteId, in: table, clipId: clipId)]
    }

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

// MARK: - What the wobble setters return

/// What `ProjectStore.setClipNoteVibrato` and `resetClipNoteVibrato` return
/// (design §10's shape). `segment` is the note as STORED, after clamping.
///
/// ⛔ A caller that checks whether its edit TOOK must compare the stored note
/// with an INDEPENDENT expectation, `NoteVibratoLimits.clamp(edit,
/// stretchRatio:).edit`, never with this value (design §10, natural tuning
/// G5): a check of the store against the store passes against a setter that
/// dropped a field.
public struct NoteVibratoResult: Sendable, Equatable {
    public let clip: Clip
    /// The edit exactly as the caller sent it (`.asSung` for a reset).
    public let requested: NoteVibratoEdit
    /// The note as stored.
    public let segment: NoteSegment
    /// The limits that bound a value, at most one per field
    /// (`NoteVibratoClamp.bound`). Empty when nothing bound.
    public let clamped: [NoteVibratoLimit]

    public init(clip: Clip, requested: NoteVibratoEdit, segment: NoteSegment,
                clamped: [NoteVibratoLimit]) {
        self.clip = clip
        self.requested = requested
        self.segment = segment
        self.clamped = clamped
    }

    /// What a listener hears: stored ÷ the clip's ratio (C5a-1, output time).
    public var heardRateHz: Double {
        segment.vibratoRateHz / NoteVibratoLimits.sanitisedRatio(clip.stretchRatio)
    }
    /// A depth with no rate: it never moves, and is said out loud (design §10
    /// item 10), never refused.
    public var silentWobble: Bool { segment.vibratoDepthCents > 0 && segment.vibratoRateHz == 0 }
    /// A rate with no depth: stored, inert, "no new wobble yet".
    public var parkedRate: Bool { segment.vibratoRateHz > 0 && segment.vibratoDepthCents == 0 }
}

/// What `ProjectStore.setClipNotesVibrato` returns.
public struct NoteVibratoBatchResult: Sendable, Equatable {
    public let clip: Clip
    /// One report per note written, in the order first named.
    public let notes: [NoteVibratoNoteReport]
    /// The sounds named and left untouched (see `setClipNotesVibrato`).
    public let skippedSoundIds: [UUID]

    public init(clip: Clip, notes: [NoteVibratoNoteReport], skippedSoundIds: [UUID]) {
        self.clip = clip
        self.notes = notes
        self.skippedSoundIds = skippedSoundIds
    }

    /// The words for `skippedSoundIds`, or `nil` when none was skipped.
    public var skippedSoundsSentence: String? {
        skippedSoundIds.isEmpty ? nil
            : NoteVibratoLimits.skippedSoundsSentence(count: skippedSoundIds.count)
    }
}

// MARK: - The note table an editor draws

/// The DETECTED, UNEDITED note table: one segment per NOTE PART
/// (`PitchNoteSplitter.parts`) plus one per SOUND between them (U-A,
/// `PitchUnpitchedFinder`), every edit field at its default.
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
        build(from: result, retuneMs: retuneMs, analysisVersion: analysisVersion).editSet
    }

    /// `detected(from:…)` plus what the unpitched finder decided (U-A,
    /// unpitched-notes design §1.10). `detected` forwards here, so the two
    /// cannot build different tables.
    ///
    /// ⭐ **SOUNDS (U-A, §1.6).** After the splitter's parts, one IDENTITY
    /// `.unpitched` segment per audible stretch between notes
    /// (`PitchAutoCorrect.segment(forSound:)`, the one home the preset builder
    /// shares), so a fresh editor seed shows every breath and consonant as
    /// something to grab. Untouched, a sound renders as the source.
    public static func build(
        from result: PitchDetectionResult,
        retuneMs: Double = PitchEditSet.engineMinimumRetuneMs,
        analysisVersion: Int = PitchEditSet.currentAnalysisVersion
    ) -> PitchNoteTableBuild {
        // f0 alone decides (design §12 item 3: onset placement, S3, is not scheduled).
        let parts = PitchNoteSplitter.parts(in: result.frames, frameRateHz: result.frameRateHz,
                                            onsetSeconds: [])
        // UA-2: each sung slide is stamped `.transition` (the one mapping,
        // `PitchAutoCorrect.origin(of:)`, which the preset builder shares).
        let segments = parts.map { part in
            NoteSegment(startSeconds: part.startSeconds,
                        endSeconds: part.endSeconds,
                        detectedHz: part.centreHz,
                        detectedConfidence: part.medianConfidence,
                        origin: PitchAutoCorrect.origin(of: part.kind))
        }
        let unpitched = PitchUnpitchedFinder.sounds(
            in: result, notes: parts.map(PitchUnpitchedFinder.Note.init(part:)))
        let sounds = unpitched.sounds.map(PitchAutoCorrect.segment(forSound:))
        // Natural tuning X3/R29: THE editor seed. This is the last moment the
        // part kinds exist, so it hands them over (transient, never stored)
        // and `seeded` marks each sung slide as following its neighbours. A
        // sound has no part kind, so it never follows (`glideFollow` 0). The
        // hint and the stored origin (UA-2) are read from the same `part.kind`
        // in this one pass, so a segment follows exactly when it is stamped
        // `.transition` (`SlideOriginStampTests` pins it).
        let partKinds = Dictionary(uniqueKeysWithValues: zip(segments.map(\.id),
                                                             parts.map(\.kind)))
        return PitchNoteTableBuild(
            editSet: PitchEditSet.seeded(analysisVersion: analysisVersion,
                                         segments: segments + sounds,
                                         retuneMs: retuneMs,
                                         partKinds: partKinds,
                                         seedPolicy: .editor),
            unpitched: unpitched)
    }
}
