import Foundation

// m23-ap Phase 2, Increment C (items C1 + C3) — THE PER-NOTE WRITER.
//
// Design record: `docs/design/2026-09-22-pitch-editor-ui.md` §7.3 (C1 = drag a
// note's pitch, C3 = split a note), §8.2 (ONE `performEdit` on gesture END),
// §8.3 (the undo keys), §9.1 (the verbs these ops are the one home for).
//
// `ProjectStore+PitchCorrection.swift` writes a WHOLE auto-correct pass.
// This file writes ONE NOTE. Own extension file, the `+PitchDetection` /
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
        var table = try noteTable(trackIndex: t, clipIndex: c, seedIfAbsent: seedIfAbsent)
        let index = try segmentIndex(of: segmentId, in: table, clipId: clipId)

        // ⛔⛔ **CLAMPED HERE, BECAUSE A DIRECT FIELD ASSIGNMENT BYPASSES THE
        // HEALING `init` — AND THE FIRST DRAFT OF THIS FUNCTION DID NOT, WHICH
        // `setNotePitchClamps` CAUGHT.** `NoteSegment.init` clamps
        // `pitchOffsetCents` to ±2400 cents; `segments[i].pitchOffsetCents = x`
        // does not go near it, so 99999 went in and read back as 99999. That is
        // the same shape `ProjectStore+PitchCorrection.swift` records for
        // `pitchEdits` itself ("a direct field assignment, which this is,
        // bypasses it") — one struct down.
        table.segments[index].pitchOffsetCents = PitchCorrectionMath
            .finite(offsetCents, default: 0)
            .clamped(to: NoteSegment.pitchOffsetCentsRange)
        let stored = table

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
