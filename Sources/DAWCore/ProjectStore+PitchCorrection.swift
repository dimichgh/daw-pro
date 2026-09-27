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
    /// **Natural tuning §1(e): `options.formantCorrection`** names the voice
    /// size the new set stores, over both the seed and the carry below (nil,
    /// every preset's, keeps today's rule). A NON-FINITE one is refused in
    /// words after the clip gates and BEFORE the `replaceExisting` refusal and
    /// the detection: an argument error, so nothing runs and nothing is
    /// journaled. **NT-C2-F1:** the consonant setting the current table holds
    /// is kept unless nobody chose it (see the one home below).
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
        try await autoCorrectClipPitchReport(clipId: clipId, options: options,
                                             replaceExisting: replaceExisting).clip
    }

    /// `autoCorrectClipPitch`, plus what the unpitched finder decided while
    /// building the set (U-A/U-B, unpitched-notes design §1.10): the ONE
    /// implementation, which `autoCorrectClipPitch` forwards to. It exists so
    /// the wire's `unpitchedCount` / `unpitchedSkippedReason` echo (UB-2) has
    /// a path: the plain verb returns only the clip, and the finder's reason
    /// never reaches a `Clip`.
    @discardableResult
    public func autoCorrectClipPitchReport(
        clipId: UUID, options: PitchAutoCorrectOptions, replaceExisting: Bool = true
    ) async throws -> PitchAutoCorrectReport {
        guard let (t, c) = locateClipIndexForPitchCorrection(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard !tracks[t].clips[c].isMIDI else {
            throw ProjectError.pitchDetectionRequiresAudioClip(clipId)
        }
        // Natural tuning §1(e): a voice size that is not a number is an
        // ARGUMENT error, refused in words before the table-state refusal
        // below and before the (slow) detection, so nothing runs, nothing is
        // stored and nothing is journaled. The pure policy would quietly
        // keep the seed instead: a request dropped without a word.
        if let amount = options.formantCorrection, !amount.isFinite {
            throw ProjectError.invalidClipEdit(
                "The voice-size amount has to be a number from 0 to 1 (or left out to keep "
                    + "this clip's own amount); \(amount) is not one. Nothing was changed.")
        }
        if !replaceExisting, let existing = tracks[t].clips[c].pitchEdits,
           existing.hasHandEditsSinceAutoCorrect {
            throw Self.replaceExistingRefusal(existing)
        }

        let detection = try await detectClipPitch(clipId: clipId)
        let build = PitchAutoCorrect.build(from: detection.pitch, options: options)
        let editSet = build.editSet

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
        //
        // Natural tuning §1(c) D-F2 (NT-C C1): the new set is SEEDED
        // (`newSetFormantCorrection`), which is what a legacy set, or a clip
        // with no table, gets. But a voice-size amount the CURRENT table
        // already carries is the user's (or an agent's) own pick, so a preset
        // never resets it: it is carried over. Read from the table as it is
        // NOW (t2, c2), after the await, for the C-F3 re-check's reason, and
        // written BEFORE the stamp, so the stamp describes what is stored.
        //
        // §1(e): a voice size the OPTIONS name wins over both. The policy
        // has already written it over the seed, so the carry steps aside.
        var carried = editSet
        if !carried.isEmpty, options.formantCorrectionOverride == nil,
           let amount = tracks[t2].clips[c2].pitchEdits?.formantCorrection {
            carried.formantCorrection = amount
        }
        // NT-C2-F1 (W7-D2): ⭐ THE ONE HOME of the consonant rule. The
        // setting the CURRENT table holds is kept unless it is
        // `.offByDefault` (nobody chose it), which takes the new set's seed.
        // So an OFF somebody chose stays off, on a legacy table and a natural
        // one alike, and ON stays ON. Stated as "keep unless nobody chose"
        // rather than "keep only a chosen OFF": if the seed ever stops being
        // ON, a set that is ON keeps its sound instead of losing it. Read
        // after the await, for the formant carry's reason, and written before
        // the stamp.
        if !carried.isEmpty,
           let consonants = tracks[t2].clips[c2].pitchEdits?.consonantProtection,
           consonants != .offByDefault {
            carried.consonantProtection = consonants
        }
        let stored = carried.stampedAsAutoCorrectOutput()
        performEdit("Auto-Correct Pitch", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t2].clips[c2].pitchEdits = editSet.isEmpty ? nil : stored
            // pitchEdits rides the render cache key (StretchRenderCache) —
            // the setClipStretch precedent for a ClipKey-affecting edit.
            engine?.tracksDidChange(tracks)
        }
        return PitchAutoCorrectReport(clip: tracks[t2].clips[c2], unpitched: build.unpitched)
    }

    /// Add the SOUNDS with no detected pitch to a clip's STORED note table
    /// (U-B, unpitched-notes design §1.6/§1.10): the merge verb, for a table
    /// made before sounds existed (F-stale). A fresh table already has them:
    /// both builders run the finder.
    ///
    /// The shape of `autoCorrectClipPitch`: pre-check, `await
    /// detectClipPitch`, re-locate and re-check, then ONE
    /// `performEdit("Find Sounds", structuralKey)` — a deliberate pass never
    /// coalesces.
    ///
    /// ⭐ **IT FILLS ONLY UNCOVERED TIME, AND NEVER MOVES OR RE-IDENTIFIES A
    /// SEGMENT.** Every STORED segment covers its time, so the user's own
    /// splits and moves count, and a sound is only ever added in a gap.
    /// A sound borrows its drawing anchor from the nearer stored note
    /// (`detectedHz`, never the moved pitch: the anchor is where the sound is
    /// drawn, relative to what was sung). ⛔ A stored `.unpitched` segment is
    /// covered time but NEVER a lender (`Note.lendsPitch: false`): a sound
    /// drawn at another sound's borrowed anchor would be a guess about a
    /// guess. Any sound that would overlap a stored segment is dropped
    /// before the write, because `PitchEditSet.canonical` heals an overlap
    /// FIRST-WINS by trimming the LATER segment, which could be the user's
    /// note (the finder clamps to note edges, so this is a guard, not a path).
    ///
    /// ⭐ **THE RE-STAMP RULE (delegated default: "Find Sounds" is not a hand
    /// edit).** Adding sounds changes the set's content, so its
    /// `contentStamp` moves. A set that was EXACTLY a preset's output before
    /// the merge (`autoCorrectStamp` present and matching) is re-stamped
    /// after it, so switching presets still asks nothing. A set that was
    /// already hand-edited, or that no preset wrote, keeps its stamp and so
    /// keeps reading as hand-edited: the merge never launders a hand edit.
    ///
    /// **Refuses, in words:** an unknown clip, a MIDI clip or a comp member
    /// (before and after the detection, the `autoCorrectClipPitch` race
    /// rule); a clip with no stored table (nothing to merge into: opening
    /// the note editor or a preset makes a table that already has sounds);
    /// a table from another detector generation (`analysisVersion`), whose
    /// notes this detector's frames cannot be laid against.
    ///
    /// **Finding nothing is not a failure.** A guard that fired
    /// (`notEnoughQuiet`, `tooNoisy`, `noNotes`) or a table with no audible
    /// gap returns the finder's result with no sounds added, and journals
    /// nothing (no undo entry, no dirty mark).
    ///
    /// - Parameter marginDb: the finder's threshold above the clip's floor,
    ///   `PitchUnpitchedFinder.defaultMarginDb` (9) by default. A non-finite
    ///   value heals to the default inside the finder; its RANGE is the wire
    ///   verb's to validate (UB-2), not this function's.
    @discardableResult
    public func findUnpitchedSounds(
        clipId: UUID, marginDb: Double = PitchUnpitchedFinder.defaultMarginDb
    ) async throws -> FoundUnpitchedSounds {
        guard let (t, c) = locateClipIndexForPitchCorrection(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard !tracks[t].clips[c].isMIDI else {
            throw ProjectError.pitchDetectionRequiresAudioClip(clipId)
        }
        try Self.requireMergeableTable(tracks[t].clips[c].pitchEdits)

        let detection = try await detectClipPitch(clipId: clipId)

        // Re-locate and RE-CHECK on the table as it is NOW: an edit, a
        // preset or a Remove Tuning may have landed during the detection.
        guard let (t2, c2) = locateClipIndexForPitchCorrection(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        try requireNotCompMember(trackIndex: t2, clipIndex: c2)
        let table = try Self.requireMergeableTable(tracks[t2].clips[c2].pitchEdits)

        let notes = table.segments.map { segment in
            PitchUnpitchedFinder.Note(startSeconds: segment.startSeconds,
                                      endSeconds: segment.endSeconds,
                                      hz: segment.detectedHz,
                                      lendsPitch: segment.origin != .unpitched)
        }
        let result = PitchUnpitchedFinder.sounds(in: detection.pitch, notes: notes,
                                                 marginDb: marginDb)
        var added: [NoteSegment] = []
        var found: [FoundUnpitchedSounds.Sound] = []
        for sound in result.sounds {
            // The guard `canonical` needs (see the doc): never trim a stored note.
            guard !table.segments.contains(where: {
                $0.startSeconds < sound.endSeconds && sound.startSeconds < $0.endSeconds
            }) else { continue }
            let segment = PitchAutoCorrect.segment(forSound: sound)
            added.append(segment)
            found.append(FoundUnpitchedSounds.Sound(
                segmentId: segment.id,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                anchorHz: sound.anchorHz,
                borrowedFromSegmentId: table.segments[sound.lenderIndex].id,
                borrowedFrom: sound.borrowedFrom))
        }
        guard !added.isEmpty else {
            return FoundUnpitchedSounds(clip: tracks[t2].clips[c2], finder: result, sounds: [])
        }

        // The re-stamp rule, decided on the table BEFORE the merge.
        let wasPresetOutput = table.autoCorrectStamp != nil && !table.hasHandEditsSinceAutoCorrect
        let merged = table.withSegments(table.segments + added)
        let stored = wasPresetOutput ? merged.stampedAsAutoCorrectOutput() : merged

        performEdit("Find Sounds", key: PitchCorrectionUndoKey.structuralKey) {
            tracks[t2].clips[c2].pitchEdits = stored
            // pitchEdits rides the render key. Untouched sounds bend nothing,
            // so an identity table stays keyless; an edited one re-keys once
            // (the digest's origin block) and re-renders the same audio.
            engine?.tracksDidChange(tracks)
        }
        return FoundUnpitchedSounds(clip: tracks[t2].clips[c2], finder: result, sounds: found)
    }

    /// The merge verb's table refusals (`findUnpitchedSounds`), one home for
    /// the pre-check and the post-detection re-check so their words agree.
    @discardableResult
    private static func requireMergeableTable(_ table: PitchEditSet?) throws -> PitchEditSet {
        guard let table else {
            throw ProjectError.invalidClipEdit(
                "This clip has no note table to add sounds to. Open it in the note editor "
                    + "or run `clip.autoCorrectPitch`: a new table already includes the sounds "
                    + "with no detected pitch.")
        }
        guard table.analysisVersion == PitchEditSet.currentAnalysisVersion else {
            throw ProjectError.invalidClipEdit(
                "This clip's notes were found by a different version of the pitch detector "
                    + "(analysis version \(table.analysisVersion); this build uses "
                    + "\(PitchEditSet.currentAnalysisVersion)), so new sounds could not be "
                    + "lined up with them. Nothing was changed. `clip.autoCorrectPitch` "
                    + "rebuilds the table with its sounds, but replaces the notes' edits.")
        }
        return table
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

// MARK: - What the two passes report (U-A/U-B)

/// What `ProjectStore.autoCorrectClipPitchReport` did: the clip as stored,
/// and what the unpitched finder decided while the set was built. The wire's
/// `unpitchedCount` / `unpitchedSkippedReason` echo (UB-2) reads it.
public struct PitchAutoCorrectReport: Sendable, Equatable {
    /// The clip after the pass, read back from the store.
    public let clip: Clip
    /// `nil` exactly when the pass never ran the finder (strength 0).
    public let unpitched: PitchUnpitchedFinder.Result?

    public init(clip: Clip, unpitched: PitchUnpitchedFinder.Result?) {
        self.clip = clip
        self.unpitched = unpitched
    }

    /// Sounds in the STORED set, counted off the set itself rather than the
    /// finder's list, so it is what a reader of `clip.getPitchEdits` sees.
    public var unpitchedCount: Int {
        clip.pitchEdits?.segments.filter { $0.origin == .unpitched }.count ?? 0
    }
}

/// What `ProjectStore.findUnpitchedSounds` did (U-B, unpitched-notes design
/// §1.10): the shape the wire's `clip.findUnpitchedSounds` answer is built
/// from — `{added, skippedReason?, floorDbfs, thresholdDbfs, sounds}`.
public struct FoundUnpitchedSounds: Sendable, Equatable {
    /// One sound the merge ADDED to the stored table.
    public struct Sound: Sendable, Equatable {
        /// The new segment's id, as stored.
        public let segmentId: UUID
        /// Source-file seconds, the stored segment's own span.
        public let startSeconds: Double
        public let endSeconds: Double
        /// Where it is drawn: the lending note's `detectedHz` (§1.5).
        public let anchorHz: Double
        /// The STORED note it borrowed from, by id.
        public let borrowedFromSegmentId: UUID
        /// Which side that note sits on.
        public let borrowedFrom: PitchUnpitchedFinder.Side
    }

    /// The clip after the merge (unchanged when nothing was added).
    public let clip: Clip
    /// The finder's own result: floor, threshold, margin and skip reason.
    public let finder: PitchUnpitchedFinder.Result
    /// The sounds ADDED, in time order. Empty when the finder skipped, found
    /// nothing audible, or every sound it found was already covered.
    public let sounds: [Sound]

    public var added: Int { sounds.count }
}
