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
    /// - Parameter melody: **Tune to Melody** (design §3.2-§3.4): `nil`, the
    ///   default, is everything above, untouched. A request tunes each sung
    ///   note to the melody note it overlaps most; see
    ///   `autoCorrectClipPitchReport` for how the melody is read and refused.
    @discardableResult
    public func autoCorrectClipPitch(
        clipId: UUID, options: PitchAutoCorrectOptions, replaceExisting: Bool = true,
        melody: MelodyTuning? = nil
    ) async throws -> Clip {
        try await autoCorrectClipPitchReport(clipId: clipId, options: options,
                                             replaceExisting: replaceExisting,
                                             melody: melody).clip
    }

    /// `autoCorrectClipPitch`, plus what the unpitched finder decided while
    /// building the set (U-A/U-B, unpitched-notes design §1.10): the ONE
    /// implementation, which `autoCorrectClipPitch` forwards to. It exists so
    /// the wire's `unpitchedCount` / `unpitchedSkippedReason` echo (UB-2) has
    /// a path: the plain verb returns only the clip, and the finder's reason
    /// never reaches a `Clip`.
    ///
    /// ⭐ **TUNE TO MELODY (`melody`, M2).** The melody is the TARGET and the
    /// options stay the preset (retune, wobble, slide shape): each held note
    /// goes to the melody note it overlaps most (`PitchMelodyTarget`), and the
    /// report's `melody` says what happened to every note on both sides (§3.3).
    ///  * **Strength (rule 5):** `melody.strength`, or 1 when none was sent,
    ///    over the options' own; `appliedOptions` echoes it.
    ///  * **Read AFTER the detection's await**, in its final state: the
    ///    melody's clips, the vocal's window and the tempo map as they are
    ///    when the table is built (§3.3's last row), the shift's rule.
    ///  * **Refused in words, nothing run or stored:** a strength that tunes
    ///    nothing, an unknown or non-MIDI source, a track with no MIDI clip,
    ///    and no melody note under the vocal. All of them are checked before
    ///    the detection (argument errors, beside the voice-size refusal), and
    ///    the source and the overlap again after it, on the final state.
    ///  * The replace guard, the C-F3 re-check, the carries, the stamp and the
    ///    ONE `performEdit` are this function's own: a melody pass goes through
    ///    every one of them, so there is no second copy (§3.4).
    @discardableResult
    public func autoCorrectClipPitchReport(
        clipId: UUID, options: PitchAutoCorrectOptions, replaceExisting: Bool = true,
        melody: MelodyTuning? = nil
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
        // Tune to Melody: the request's own argument errors, the same place
        // and the same reason as the voice size above (fail fast, before the
        // slow detection). The source and the overlap are asked again after
        // the await, on the final state.
        if let melody {
            _ = try melody.appliedStrength()
            _ = try melodyNotes(melodySourceClips(melody.source), under: tracks[t].clips[c])
        }
        if !replaceExisting, let existing = tracks[t].clips[c].pitchEdits,
           existing.hasHandEditsSinceAutoCorrect {
            throw Self.replaceExistingRefusal(existing)
        }

        let detection = try await detectClipPitch(clipId: clipId)

        guard let (t2, c2) = locateClipIndexForPitchCorrection(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        try requireNotCompMember(trackIndex: t2, clipIndex: c2)
        // PK-F1: the scale applies to what PLAYS, so the policy is given the
        // clip's pitch shift, read NOW (after the detection's await), because
        // that is the shift this table will play under. The wire reply
        // (`clip.autoCorrectPitch`) echoes the kept detune as
        // `keptDetuneCents` / `keptDetuneNotice`, and the MCP tool
        // `clip_auto_correct_pitch` says the scale is the key as heard.
        let clipShift = tracks[t2].clips[c2].pitchShiftSemitones
        // Tune to Melody: resolved HERE, after the await, from the melody's
        // clips, the vocal and the tempo map as they are NOW (§3.3: "the
        // melody is edited during detection" -> its final state). Rule 5's
        // strength replaces the options' own for this pass.
        var passOptions = options
        var resolved: (request: PitchMelodyTarget.Request, refs: [PitchMelodyReport.NoteRef],
                       name: String)?
        if let melody {
            passOptions.strength = try melody.appliedStrength()
            let source = try melodySourceClips(melody.source)
            let notes = try melodyNotes(source, under: tracks[t2].clips[c2])
            resolved = (PitchMelodyTarget.Request(notes: notes.map(\.note),
                                                  octaveMatch: melody.octaveMatch,
                                                  unmatched: melody.unmatched),
                        notes.map(\.ref), source.name)
        }
        let build = PitchAutoCorrect.build(
            from: detection.pitch, options: passOptions, clipShiftSemitones: clipShift,
            melody: resolved?.request)
        let editSet = build.editSet
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
        // The 10-04 ruling: a fractional shift is a detune the pass KEPT; the
        // report says so, in cents, whenever a note was corrected under one.
        let detune = PitchAutoCorrect.splitClipShift(clipShift).fraction
        let corrected = editSet.segments.contains { $0.origin != .unpitched }
        // Tune to Melody's report, mapped from the plan's indices to the
        // stored segments' ids and the MIDI notes. A melody pass always has a
        // plan here: its strength is above 0, so `build` never short-circuits.
        var melodyReport: PitchMelodyReport?
        if let melody, let resolved, let applied = build.melody {
            melodyReport = PitchMelodyReport(
                source: melody.source, sourceName: resolved.name,
                octaveMatch: melody.octaveMatch, unmatched: melody.unmatched,
                refs: resolved.refs, applied: applied)
        }
        return PitchAutoCorrectReport(
            clip: tracks[t2].clips[c2], unpitched: build.unpitched,
            keptDetuneCents: corrected && abs(detune) > PitchAutoCorrectReport.detuneEpsilonSemitones
                ? detune * 100 : nil,
            appliedOptions: passOptions, melody: melodyReport)
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

    // MARK: Tune to Melody (M2)

    /// Tune to Melody: the MIDI clips a `MelodySource` names and the name a sentence uses,
    /// read from the store as it is NOW. Refused in words: an unknown clip or track, a clip
    /// that is not MIDI, a track with no MIDI clip.
    private func melodySourceClips(_ source: MelodySource) throws -> (clips: [Clip], name: String) {
        switch source {
        case .clip(let id):
            guard let (t, c) = locateClipIndexForPitchCorrection(id) else {
                throw ProjectError.clipNotFound(id)
            }
            let clip = tracks[t].clips[c]
            guard clip.isMIDI else {
                throw ProjectError.invalidClipEdit(
                    "The melody has to be a MIDI clip or a track with MIDI clips; "
                        + "\u{201C}\(clip.name)\u{201D} is an audio clip. Pick the clip or track "
                        + "that holds the melody's notes. Nothing was changed.")
            }
            return ([clip], clip.name)
        case .track(let id):
            guard let track = tracks.first(where: { $0.id == id }) else {
                throw ProjectError.trackNotFound(id)
            }
            let clips = track.clips.filter(\.isMIDI)
            guard !clips.isEmpty else {
                throw ProjectError.invalidClipEdit(
                    "The track \u{201C}\(track.name)\u{201D} has no MIDI clips, so there is no "
                        + "melody on it to tune to. Pick the track or clip that holds the "
                        + "melody's notes. Nothing was changed.")
            }
            return (clips, track.name)
        }
    }

    /// The melody's notes under `vocal` (§3.2), or the refusal naming both spans (§3.3).
    private func melodyNotes(_ source: (clips: [Clip], name: String),
                             under vocal: Clip) throws -> [MelodyTuning.SourcedNote] {
        let notes = MelodyTuning.notes(of: source.clips, under: vocal, tempoMap: transport.tempoMap)
        guard !notes.isEmpty else {
            throw MelodyTuning.noOverlapRefusal(vocal: vocal, melodyName: source.name,
                                                melodyClips: source.clips)
        }
        return notes
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
    /// The detune the pass KEPT, in cents (the 2026-10-04 ruling): the part of
    /// the clip's pitch shift past its nearest whole semitone
    /// (`PitchAutoCorrect.splitClipShift`), which Auto-Correct never snaps.
    /// Each corrected note plays this far off the scale. `nil` when the shift
    /// is whole or no note was corrected.
    public let keptDetuneCents: Double?
    /// The options the pass RAN with: the caller's, except that a Tune to
    /// Melody pass runs at rule 5's strength (`MelodyTuning.strength`: 1
    /// unless one was sent). The wire's `appliedOptions` echo reads this, so
    /// it says what was applied, never what the preset would have used.
    public let appliedOptions: PitchAutoCorrectOptions
    /// What a Tune to Melody pass did (§3.3); `nil` for a pass without a melody.
    public let melody: PitchMelodyReport?

    /// A shift within this many semitones of a whole number keeps no detune:
    /// a fractional shift moved up and back down is float addition.
    public static let detuneEpsilonSemitones = 1e-6

    public init(clip: Clip, unpitched: PitchUnpitchedFinder.Result?,
                keptDetuneCents: Double? = nil, appliedOptions: PitchAutoCorrectOptions,
                melody: PitchMelodyReport? = nil) {
        self.clip = clip
        self.unpitched = unpitched
        self.keptDetuneCents = keptDetuneCents
        self.appliedOptions = appliedOptions
        self.melody = melody
    }

    /// `keptDetuneCents` in words for a person, or nil. For a clip shifted
    /// +3.3: "Kept this clip's +30 cent detune (its pitch shift is +3.3
    /// semitones): each corrected note plays 30 cents sharp of the scale, as
    /// the shift asks." A Tune to Melody pass says "of the melody": its notes
    /// are aimed at the melody's notes, and the detune is kept the same way.
    public var keptDetuneNotice: String? {
        guard let cents = keptDetuneCents else { return nil }
        let size = ClampNotice.number(abs(cents))
        let shift = clip.pitchShiftSemitones
        let target = melody == nil ? "the scale" : "the melody"
        return "Kept this clip's \(cents > 0 ? "+" : "-")\(size) cent detune (its pitch shift is "
            + "\(shift > 0 ? "+" : "")\(ClampNotice.number(shift)) semitones): each corrected note "
            + "plays \(size) cents \(cents > 0 ? "sharp" : "flat") of \(target), as the shift asks."
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

// MARK: - Tune to Melody, M2: the store's half (design `2026-09-24-unpitched-notes-presets-midi-targets.md` §3.2-§3.4)

/// Where a Tune to Melody pass reads its melody (design §3.4).
public enum MelodySource: Sendable, Equatable {
    /// One MIDI clip.
    case clip(UUID)
    /// Every MIDI clip on one track.
    case track(UUID)
}

/// A Tune to Melody request to the store (`ProjectStore.autoCorrectClipPitchReport(…,
/// melody:)`): where the melody is, and the rules the caller chose. Not a
/// `PitchAutoCorrectOptions` field: the options are the preset (retune, wobble, slide
/// shape), the melody is the target (§3.4).
///
/// A struct rather than a bare `MelodySource`, on purpose: rule 5's "strength is 1 unless
/// sent" needs to know whether a strength was SENT, which `PitchAutoCorrectOptions` cannot
/// say (its `strength` always holds a number, the preset's own when nobody sent one).
public struct MelodyTuning: Sendable, Equatable {
    public var source: MelodySource
    /// Rule 3: the melody's note in the octave nearest what was sung (the default), so a low
    /// voice can follow a high lead, or the note exactly as written.
    public var octaveMatch: PitchMelodyTarget.OctaveMatch
    /// §3.3 row 1: a sung note where the melody rests stays as sung (the default), or goes
    /// to the options' scale. The wire picks `.toScale` exactly when the request named a scale.
    public var unmatched: PitchMelodyTarget.Unmatched
    /// Rule 5: `nil` (the default) tunes at strength 1, so the notes land ON the melody
    /// whatever the preset's own strength (Natural's 0.85 would stop 15 % short). A number is
    /// a strength the caller SENT, and it wins; above 1 reads as 1. Zero, a negative or a
    /// non-number is refused in words: it would leave every note as sung.
    public var strength: Double?

    public init(source: MelodySource,
                octaveMatch: PitchMelodyTarget.OctaveMatch = .nearestOctave,
                unmatched: PitchMelodyTarget.Unmatched = .asSung,
                strength: Double? = nil) {
        self.source = source
        self.octaveMatch = octaveMatch
        self.unmatched = unmatched
        self.strength = strength
    }

    /// An overlap shorter than this, seconds, is the arithmetic of two beat sums meeting at
    /// a shared edge, not a note under the vocal.
    public static let overlapEpsilonSeconds = 1e-9

    /// One melody note in VOCAL SOURCE seconds, and the MIDI note it came from.
    public struct SourcedNote: Sendable, Equatable {
        public let note: PitchMelodyTarget.MelodyNote
        public let ref: PitchMelodyReport.NoteRef
    }

    /// **§3.2, beats to vocal seconds**: a TIMELINE beat as the vocal's SOURCE-file second,
    /// `startOffsetSeconds + tempoMap.seconds(from: vocal.startBeat, to: beat) / stretchRatio`.
    /// The inverse of `ProjectStore.detectClipTransients`' projection, and the
    /// `ClipPitchFrame.timeSeconds` domain the detection's frames are in. A beat before the
    /// vocal's start gives a second before its offset (the map's integral is signed).
    public static func sourceSeconds(atBeat beat: Double, vocal: Clip,
                                     tempoMap: TempoMap) -> Double {
        vocal.startOffsetSeconds
            + tempoMap.seconds(from: vocal.startBeat, to: beat) / vocal.stretchRatio
    }

    /// The vocal's window in source seconds, `[offset, offset + sourceWindowSeconds)`: the
    /// span `ProjectStore.detectClipPitch` analyses.
    public static func vocalWindow(of vocal: Clip, tempoMap: TempoMap)
        -> (start: Double, end: Double) {
        (vocal.startOffsetSeconds,
         vocal.startOffsetSeconds + vocal.sourceWindowSeconds(tempoMap: tempoMap))
    }

    /// A note's sounding span in its clip's own beats: clipped to `[0, lengthBeats)` (a MIDI
    /// clip sounds nothing past its end), `nil` when nothing of it sounds.
    static func soundingBeats(of note: MIDINote, in clip: Clip) -> (start: Double, end: Double)? {
        let start = max(0, note.startBeat)
        let end = min(note.endBeat, clip.lengthBeats)
        guard start < clip.lengthBeats, end > start else { return nil }
        return (start, end)
    }

    /// **§3.2, every melody note under the vocal**: each note of `melodyClips` (non-MIDI clips
    /// are skipped) clipped to its clip, converted to vocal source seconds, and KEPT when it
    /// overlaps the vocal's window. Kept notes are not clipped to that window: two notes
    /// starting before it would otherwise share a start and read as a chord instead of
    /// legato. Sorted by start, then pitch, then clip order, then note order, so the plan's
    /// melody indices are deterministic.
    public static func notes(of melodyClips: [Clip], under vocal: Clip,
                             tempoMap: TempoMap) -> [SourcedNote] {
        let window = vocalWindow(of: vocal, tempoMap: tempoMap)
        var kept: [(sourced: SourcedNote, clip: Int, note: Int)] = []
        for (clipIndex, clip) in melodyClips.enumerated() {
            guard let notes = clip.notes else { continue }
            for (noteIndex, note) in notes.enumerated() {
                guard let beats = soundingBeats(of: note, in: clip) else { continue }
                let start = sourceSeconds(atBeat: clip.startBeat + beats.start, vocal: vocal,
                                          tempoMap: tempoMap)
                let end = sourceSeconds(atBeat: clip.startBeat + beats.end, vocal: vocal,
                                        tempoMap: tempoMap)
                guard min(end, window.end) - max(start, window.start) > overlapEpsilonSeconds
                else { continue }
                let sourced = SourcedNote(
                    note: PitchMelodyTarget.MelodyNote(startSeconds: start, endSeconds: end,
                                                       midi: note.pitch),
                    ref: PitchMelodyReport.NoteRef(clipId: clip.id, noteId: note.id,
                                                   pitch: note.pitch, startBeat: note.startBeat))
                kept.append((sourced, clipIndex, noteIndex))
            }
        }
        kept.sort {
            if $0.sourced.note.startSeconds != $1.sourced.note.startSeconds {
                return $0.sourced.note.startSeconds < $1.sourced.note.startSeconds
            }
            if $0.sourced.note.midi != $1.sourced.note.midi {
                return $0.sourced.note.midi < $1.sourced.note.midi
            }
            return ($0.clip, $0.note) < ($1.clip, $1.note)
        }
        return kept.map(\.sourced)
    }

    /// The TIMELINE beats the melody's notes sound over, first start to last end, or `nil`
    /// when none sounds: the refusal names it.
    static func soundingSpan(of melodyClips: [Clip]) -> (start: Double, end: Double)? {
        var span: (start: Double, end: Double)?
        for clip in melodyClips {
            for note in clip.notes ?? [] {
                guard let beats = soundingBeats(of: note, in: clip) else { continue }
                let start = clip.startBeat + beats.start
                let end = clip.startBeat + beats.end
                span = (min(span?.start ?? start, start), max(span?.end ?? end, end))
            }
        }
        return span
    }

    /// The refusal when no melody note overlaps the vocal (§3.3: "refused, with a teaching
    /// error naming both clips' spans"). The plan itself never refuses: with nothing under
    /// the vocal it would leave every note unmatched, a pass that changes nothing it promised.
    static func noOverlapRefusal(vocal: Clip, melodyName: String,
                                 melodyClips: [Clip]) -> ProjectError {
        let vocalSpan = "the vocal \u{201C}\(vocal.name)\u{201D} (beats "
            + "\(ClampNotice.number(vocal.startBeat)) to "
            + "\(ClampNotice.number(vocal.startBeat + vocal.lengthBeats)))"
        guard let span = soundingSpan(of: melodyClips) else {
            return .invalidClipEdit(
                "The melody \u{201C}\(melodyName)\u{201D} has no notes, so there is nothing to "
                    + "tune \(vocalSpan) to. Add the melody's notes, or pick another melody. "
                    + "Nothing was changed.")
        }
        return .invalidClipEdit(
            "No note of the melody \u{201C}\(melodyName)\u{201D} plays under \(vocalSpan): its "
                + "notes play from beat \(ClampNotice.number(span.start)) to beat "
                + "\(ClampNotice.number(span.end)). Move the melody under the vocal, or pick "
                + "another melody. Nothing was changed.")
    }

    /// Rule 5 as a number, or the refusal for a strength that would tune nothing.
    func appliedStrength() throws -> Double {
        guard let sent = strength else { return 1 }
        guard sent > 0, sent.isFinite else {
            throw ProjectError.invalidClipEdit(
                "Tune to Melody moves each sung note onto the melody, so its strength has to be "
                    + "above 0 (at most 1); \(sent) would leave every note as sung. Leave the "
                    + "strength out to land on the melody exactly, or use clip.clearPitchEdits "
                    + "to remove tuning. Nothing was changed.")
        }
        return min(sent, 1)
    }
}

/// What a Tune to Melody pass did (§3.3: "every case gets a defined result and a field;
/// nothing is silent"), mapped from `PitchMelodyTarget.Plan`'s indices to the STORED
/// segments' ids and to the MIDI notes, so a reader never re-derives one.
public struct PitchMelodyReport: Sendable, Equatable {
    /// One MIDI note, as the clip stores it.
    public struct NoteRef: Sendable, Equatable {
        public let clipId: UUID
        public let noteId: UUID
        public let pitch: Int
        /// Relative to its clip's start, as `MIDINote.startBeat` (and `clip.getNotes`) has it.
        public let startBeat: Double
    }
    /// A cut the melody added inside one sung note (rule 2).
    public struct Cut: Sendable, Equatable {
        /// Source seconds: where the right-hand piece starts.
        public let seconds: Double
        /// The melody's own boundary the cut was searched around.
        public let melodyBoundarySeconds: Double
        public let placement: PitchMelodyTarget.Cut.Placement
        /// The two stored segments either side of the cut, left first.
        public let segmentIds: [UUID]
    }
    public struct OctaveFold: Sendable, Equatable {
        public let segmentId: UUID
        /// Octaves between the target and the written note (−1: an octave below it).
        public let octaves: Int
    }
    public struct FarMove: Sendable, Equatable {
        public let segmentId: UUID
        /// The stored move, cents (more than `PitchMelodyTarget.farMoveCents`).
        public let cents: Double
    }

    public let source: MelodySource
    /// The melody clip's or track's name, for a sentence.
    public let sourceName: String
    public let octaveMatch: PitchMelodyTarget.OctaveMatch
    public let unmatched: PitchMelodyTarget.Unmatched
    /// Melody notes that overlap the vocal's window: what the match was given.
    public let notesConsidered: Int
    /// How many of those some sung note took.
    public let notesUsed: Int
    /// How many sung notes (and pieces of cut notes) were tuned to the melody.
    public let matchedParts: Int
    /// Sung notes where the melody rests (§3.3 row 1): as sung, or to the scale.
    public let unmatchedParts: [UUID]
    /// Melody notes nobody sang (§3.3 row 2): nothing to tune.
    public let unsungNotes: [NoteRef]
    /// Melody notes a sung note overlaps but none took (a note under 60 ms inside a longer
    /// one, an edge the cut guard kept, a majority lost).
    public let outvotedNotes: [NoteRef]
    public let cutsAdded: [Cut]
    /// Notes that lost sounding time to a HIGHER note: a chord reduced to its top note.
    public let chordsReduced: [NoteRef]
    public let octaveFolded: [OctaveFold]
    public let farMoves: [FarMove]

    /// The report of `applied`, a melody pass's plan and its rows' stored ids, over the
    /// notes it was given (`refs[i]` is melody index `i`'s MIDI note).
    init(source: MelodySource, sourceName: String, octaveMatch: PitchMelodyTarget.OctaveMatch,
         unmatched: PitchMelodyTarget.Unmatched, refs: [NoteRef],
         applied: PitchMelodyTarget.Applied) {
        let plan = applied.plan
        let ids = applied.segmentIDs
        func id(_ piece: Int) -> UUID? { ids.indices.contains(piece) ? ids[piece] : nil }
        func refsOf(_ indices: [Int]) -> [NoteRef] {
            indices.compactMap { refs.indices.contains($0) ? refs[$0] : nil }
        }
        self.source = source
        self.sourceName = sourceName
        self.octaveMatch = octaveMatch
        self.unmatched = unmatched
        self.notesConsidered = refs.count
        self.notesUsed = plan.notesUsed.count
        self.matchedParts = plan.matchedParts
        self.unmatchedParts = plan.unmatchedParts.compactMap(id)
        self.unsungNotes = refsOf(plan.unsungNotes)
        self.outvotedNotes = refsOf(plan.outvotedNotes)
        // A cut's right-hand piece starts at the cut, bit for bit (`PitchMelodyTarget.Piece`).
        self.cutsAdded = plan.cutsAdded.map { cut in
            let right = plan.pieces.indices.first {
                plan.pieces[$0].partIndex == cut.partIndex
                    && plan.pieces[$0].startSeconds == cut.seconds
            }
            let sides = right.map { [id($0 - 1), id($0)].compactMap { $0 } } ?? []
            return Cut(seconds: cut.seconds, melodyBoundarySeconds: cut.melodyBoundarySeconds,
                       placement: cut.placement, segmentIds: sides)
        }
        self.chordsReduced = refsOf(plan.chordsReduced)
        self.octaveFolded = plan.octaveFolded.compactMap { fold in
            id(fold.pieceIndex).map { OctaveFold(segmentId: $0, octaves: fold.octaves) }
        }
        self.farMoves = plan.farMoves.compactMap { move in
            id(move.pieceIndex).map { FarMove(segmentId: $0, cents: move.cents) }
        }
    }
}
