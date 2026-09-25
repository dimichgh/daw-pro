import Foundation

/// The pitch-correction WRITER leg (m23-q Phase 2): `PitchCorrection.swift`'s
/// model and `ProjectStore+PitchDetection.swift`'s read-only detector had no
/// store setter until this file. New domain, own extension file — the
/// `ProjectStore+PitchDetection.swift` precedent (per-frame f0 is its own
/// file; per-clip edits are this one).
@MainActor
extension ProjectStore {

    /// Run the auto-correct POLICY (`PitchAutoCorrect.editSet`) against a
    /// clip's freshly detected contour and store the result on
    /// `clip.pitchEdits`.
    ///
    /// **How this gets its contour — the open design question the brief
    /// named, answered here:** it calls `detectClipPitch(clipId:)` itself,
    /// over the clip's WHOLE current window (the same default that verb
    /// already has), rather than requiring the caller to have run
    /// `clip.detectPitch` first and ferry the per-frame contour back over the
    /// wire. Two reasons: (1) one call is what an agent — and a person
    /// clicking a preset button — actually wants, the `quantizeAudioClip`/
    /// `sliceClipToSampler`/`extractGroove` precedent (each detects THEN
    /// mutates in the same store op, never asks the caller to shuttle
    /// analysis frames back in); (2) the contour is explicitly NOT persisted
    /// (design §7.3 — `PitchCorrectionCurve.unresolvedShapingSegmentIDs`'s
    /// own doc says it is "regenerable and belongs beside the renders"), so
    /// asking a caller to carry ~60 KB/10 s of frames across the wire just to
    /// hand them straight back buys nothing and risks a stale contour being
    /// applied against a clip that has since changed.
    ///
    /// This inherits `detectClipPitch`'s own rejections for free: a MIDI clip
    /// or a clip with no backing file → `pitchDetectionRequiresAudioClip` /
    /// a teaching `invalidClipEdit`; a missing file on disk → a teaching
    /// `invalidClipEdit`; headless → `engineUnavailable`. The MIDI check is
    /// ALSO run here, first, before the (potentially slow) detection —
    /// the `quantizeAudioClip` fail-fast convention, so a MIDI clip gets its
    /// actionable error without waiting on a detector that would reject it
    /// anyway.
    ///
    /// `requireNotCompMember` gates this like `setClipStretch` does: a comp
    /// lane's read-only member must not silently grow pitch edits underneath
    /// the take group. Checked twice — once before the (async) detection so a
    /// comp member fails fast, once after re-locating post-await so a
    /// concurrent edit that turned the clip into (or out of) a comp member
    /// during detection cannot slip through the gap the `await` opens (the
    /// same "spec §8 risk 7" race every async store op here names).
    ///
    /// **What gets stored, and the `isEmpty`-not-`isIdentity` distinction on
    /// purpose:** `PitchAutoCorrect.editSet` returns `.empty` at `strength ==
    /// 0` and an empty-segments set when the clip has no voiced runs at all
    /// (silence, an instrumental clip, a contour the detector could not
    /// voice). Both must land on `nil`, not a stored empty `PitchEditSet` —
    /// `Clip.init`'s own omit-when-empty normalisation (`Model.swift`'s
    /// `(pitchEdits?.isEmpty ?? true) ? nil : pitchEdits`) only runs through
    /// `init`; a direct field assignment, which this is, bypasses it and
    /// would otherwise persist a zero-segment key that reopens the project
    /// with a non-nil `pitchEdits` an edit-free clip never had. A set of
    /// freshly DETECTED, UNEDITED notes (`isIdentity == true`, `isEmpty ==
    /// false`) is deliberately NOT collapsed to `nil` here — it is still the
    /// note table a future editor draws, and `StretchRenderCache`/
    /// `OfflineStretcher` already render it byte-identically to no edits at
    /// all via `PitchEditSet.isIdentity`.
    ///
    /// A silent zero-note result (no voiced runs, e.g. an all-instrumental or
    /// too-quiet clip) is exactly the "accepts input and quietly does
    /// nothing" failure shape this tree is full of warnings about, so the
    /// caller can tell: read `clip.pitchEdits` back (this function returns
    /// the updated clip) — `nil` plus zero segments after asking for a
    /// correction is the signal to check `clip.detectPitch`'s own
    /// `voicedFraction` before assuming the feature is broken.
    ///
    /// Coalescing key: `PitchCorrectionUndoKey.structuralKey` (`nil` —
    /// design §7.4: "apply or clear a whole auto-correct pass" is
    /// structural, never coalesces).
    ///
    /// - Parameter replaceExisting: **C-F3 (F22).** Defaults to `true`,
    ///   today's behaviour — additive, unconditional: a preset always
    ///   overwrites whatever was there. `false` REFUSES with a teaching
    ///   error whenever `PitchEditSet.hasHandEditsSinceAutoCorrect` is true
    ///   for the clip's CURRENT table — the same question
    ///   `PitchEditProvenance.swift` argues and the app's own confirm dialog
    ///   asks, so the wire and the UI can never disagree about what counts
    ///   as "would lose work". ⚠️ **DELIBERATELY NOT `!PitchEditSet.isIdentity`**:
    ///   a preset's own output routinely sets per-note fields too (a
    ///   correction that does nothing is not much of a correction), so that
    ///   predicate would also fire while merely comparing Gentle → Natural →
    ///   Tight — exactly the confirm-on-every-switch failure
    ///   `PitchEditProvenance.swift`'s banner names. A clip with NO table
    ///   (`pitchEdits == nil`) proceeds regardless — there is nothing this
    ///   flag could protect. Checked BEFORE the (potentially slow) detection,
    ///   the same fail-fast place the MIDI check lives, so a doomed call
    ///   never pays for a model run it cannot keep — AND checked AGAIN, on
    ///   the table's CURRENT content, right before the write: a hand-edit
    ///   landing during that detection gap (a drag released mid-call) must
    ///   not be silently replaced just because the table looked untouched
    ///   when the call started.
    @discardableResult
    public func autoCorrectClipPitch(
        clipId: UUID, options: PitchAutoCorrectOptions, replaceExisting: Bool = true
    ) async throws -> Clip {
        guard let (t, c) = locateClipIndexForPitchCorrection(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard !tracks[t].clips[c].isMIDI else {
            throw ProjectError.pitchDetectionRequiresAudioClip(clipId)
        }
        if !replaceExisting, let existing = tracks[t].clips[c].pitchEdits,
           existing.hasHandEditsSinceAutoCorrect {
            throw Self.replaceExistingRefusal(existing)
        }

        let detection = try await detectClipPitch(clipId: clipId)
        let editSet = PitchAutoCorrect.editSet(from: detection.pitch, options: options)

        guard let (t2, c2) = locateClipIndexForPitchCorrection(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        try requireNotCompMember(trackIndex: t2, clipIndex: c2)
        // m23-ap C-F3 RE-CHECK (swift-app review, 2026-09-24): detection just
        // awaited — on the measured dry vocal, a real model pass, seconds —
        // and the pre-check above ran BEFORE that gap opened. A hand-edit
        // landing DURING the gap (a drag released while this call was still
        // detecting, or a concurrent clip.setNotePitch) would otherwise be
        // silently replaced below despite `replaceExisting: false`, even
        // though the pre-check answered honestly for the clip it saw at the
        // time — the exact "a write that succeeds and quietly breaks the
        // guard" shape `PitchEditProvenance.swift`'s own banner names for
        // per-note setters, here on the OTHER side of the same seam. Reads
        // the CURRENT table at (t2, c2), not the one the pre-check saw.
        if !replaceExisting, let currentExisting = tracks[t2].clips[c2].pitchEdits,
           currentExisting.hasHandEditsSinceAutoCorrect {
            throw Self.replaceExistingRefusal(currentExisting)
        }

        // m23-ap C-F3: STAMPED with its own content, so the preset doors can
        // later tell "exactly what a preset wrote" (switch presets freely) from
        // "changed by hand since" (ask before replacing).
        // `PitchEditSet.hasHandEditsSinceAutoCorrect` is the one question, and
        // `PitchEditProvenance.swift` argues the mechanism. The stamp is not
        // render material: `PitchEditSetDigest.hex` never reads it.
        let stored = editSet.stampedAsAutoCorrectOutput()
        performEdit("Auto-Correct Pitch", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t2].clips[c2].pitchEdits = editSet.isEmpty ? nil : stored
            // pitchEdits rides the render cache key (StretchRenderCache) —
            // the setClipStretch precedent for a ClipKey-affecting edit.
            engine?.tracksDidChange(tracks)
        }
        return tracks[t2].clips[c2]
    }

    /// Removes a clip's pitch edits entirely — `nil`, not `PitchEditSet.empty`
    /// (the same nil-not-empty rule `autoCorrectClipPitch` follows), so a
    /// cleared clip is byte-identical to one that was never corrected.
    /// Idempotent: clearing an already-`nil` set is a no-op `performEdit`
    /// that records no undo entry (`captureEditState() != before` sees no
    /// change), the `clip.getNotes` doc's own "byte-identical clip" idiom.
    ///
    /// Works on a MIDI clip too (a no-op, since a MIDI clip can never have
    /// carried pitch edits) rather than rejecting it — there is nothing to
    /// teach an agent that asks to clear a field already clear.
    ///
    /// Coalescing key: `PitchCorrectionUndoKey.structuralKey` — clearing is
    /// structural, the same reasoning as applying.
    @discardableResult
    public func clearClipPitchEdits(clipId: UUID) throws -> Clip {
        guard let (t, c) = locateClipIndexForPitchCorrection(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        performEdit("Clear Pitch Edits", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t].clips[c].pitchEdits = nil
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    /// Reads a clip's pitch edits back, unmodified. `nil` when the clip
    /// carries none (never detected, cleared, or a MIDI clip — MIDI notes
    /// already have a definite pitch and never carry this field).
    ///
    /// STRICTLY READ-ONLY — the `clip.getNotes` idiom: no `performEdit`, no
    /// engine call, no undo entry, no dirty flag, no `requireNotCompMember`
    /// (reading a comp member's edits is harmless; only writing to one is
    /// gated).
    public func pitchEdits(forClipId clipId: UUID) throws -> PitchEditSet? {
        try pitchEditClip(forClipId: clipId).pitchEdits
    }

    /// The clip `pitchEdits(forClipId:)` reads from: the same lookup and the
    /// same refusal, one function. It exists so that a reader that reports
    /// "does this clip bend the curve" can ask the clip's own
    /// `Clip.hasPitchEdits`, the ONE home of that rule, instead of restating
    /// it over the set (I7a: `clip.getPitchEdits`' response had a second
    /// spelling of it). The same read-only rule as its twin applies.
    public func pitchEditClip(forClipId clipId: UUID) throws -> Clip {
        guard let (t, c) = locateClipIndexForPitchCorrection(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        return tracks[t].clips[c]
    }

    /// The ONE place `replaceExisting: false`'s refusal text is built — both
    /// the fast-fail pre-check and the post-detection re-check
    /// (`autoCorrectClipPitch`, C-F3) call this, so the two can never drift
    /// apart into two different wordings for the same fact.
    private static func replaceExistingRefusal(_ existing: PitchEditSet) -> ProjectError {
        .invalidClipEdit(
            "This clip's pitch edits (\(existing.segments.count) note(s)) have changed by "
                + "hand since the last auto-correct pass — pitch moves, timing changes or "
                + "drawn shapes — and running a preset now would replace ALL of them. Call "
                + "again with replaceExisting:true (today's default — just omit the flag) to "
                + "replace them anyway, or clip.clearPitchEdits first if you want to start "
                + "over deliberately.")
    }

    /// Locates a clip by id across every track (extension-local; the
    /// repo-wide convention — `ProjectStore.swift`'s private `locateClip(_:)`
    /// is not visible cross-file, so every extension that needs this keeps
    /// its own hand-kept twin: `+PitchDetection.swift`, `+Analysis.swift`,
    /// `+Humanize.swift`, `+Quantize.swift`, `+Transcription.swift` all do
    /// the same thing under the same shape).
    private func locateClipIndexForPitchCorrection(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
