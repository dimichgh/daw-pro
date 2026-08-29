import Foundation

/// Counts-and-geometry report for `ProjectStore.repeatNotes` (m31-c). NEVER a
/// note array, under any parameter: a verb whose whole purpose is to stop an
/// agent from materializing N notes in its own context must not then
/// materialize them in its response. A caller that needs the resulting ids
/// reads them back with `clip.getNotes`, which already windows by beat/pitch
/// and already reports `totalNotes` vs `returnedNotes`.
public struct NoteRepeatReport: Equatable, Sendable {
    public var clipID: UUID
    public var copiesMade: Int
    public var sourceNoteCount: Int
    public var notesAdded: Int
    /// The clip's note count AFTER this write (pre-existing + notesAdded —
    /// repeatNotes never removes anything).
    public var totalNotes: Int
    public var patternSpanBeats: Double
    /// Clip-relative.
    public var firstCopyStartBeat: Double
    /// Clip-relative.
    public var lastCopyEndBeat: Double
    public var clipLengthBeats: Double
    public var extended: Bool
    /// Composed by the store's ONE `autoExtendRefusalMessage`, so repeat,
    /// paste and note-edit can never describe the same obstacle three
    /// different ways. nil whenever nothing was refused (includes
    /// `extendClip: false`, where extension is never attempted).
    public var extendRefusal: String?
    public var latentNotesPastClipEnd: Int
    public var meterChangesInSpan: Int
    public var preExistingNotesInSpan: Int
    public var copiesOverlapEachOther: Bool
    /// `MIDINote.init` clamps pitch to 0...127 silently — a transposed copy
    /// that clamps is a note that is still there, still audible, just at the
    /// wrong interval. Reported, never refused (the same stance
    /// `meterChangesInSpan` takes on a meter crossing). Zero whenever
    /// `transposeSemitones` is empty.
    public var pitchesClamped: Int

    public init(
        clipID: UUID, copiesMade: Int = 0, sourceNoteCount: Int = 0,
        notesAdded: Int = 0, totalNotes: Int = 0, patternSpanBeats: Double = 0,
        firstCopyStartBeat: Double = 0, lastCopyEndBeat: Double = 0,
        clipLengthBeats: Double = 0, extended: Bool = false,
        extendRefusal: String? = nil, latentNotesPastClipEnd: Int = 0,
        meterChangesInSpan: Int = 0, preExistingNotesInSpan: Int = 0,
        copiesOverlapEachOther: Bool = false, pitchesClamped: Int = 0
    ) {
        self.clipID = clipID
        self.copiesMade = copiesMade
        self.sourceNoteCount = sourceNoteCount
        self.notesAdded = notesAdded
        self.totalNotes = totalNotes
        self.patternSpanBeats = patternSpanBeats
        self.firstCopyStartBeat = firstCopyStartBeat
        self.lastCopyEndBeat = lastCopyEndBeat
        self.clipLengthBeats = clipLengthBeats
        self.extended = extended
        self.extendRefusal = extendRefusal
        self.latentNotesPastClipEnd = latentNotesPastClipEnd
        self.meterChangesInSpan = meterChangesInSpan
        self.preExistingNotesInSpan = preExistingNotesInSpan
        self.copiesOverlapEachOther = copiesOverlapEachOther
        self.pitchesClamped = pitchesClamped
    }
}

@MainActor
extension ProjectStore {

    // MARK: - Repeat notes (m31-c)

    /// Time-shifted, optionally chromatically-transposed COPIES of a
    /// clip-relative note window or an explicit note set, written back into
    /// the SAME clip as an UNCOALESCED edit — the `pasteNotes` shape,
    /// verbatim, for the same reason.
    ///
    /// ⚠️⚠️ **THE OBVIOUS IMPLEMENTATION IS `getNotes` -> append -> `setClipNotes`,
    /// AND IT IS WRONG.** `setClipNotes` journals with `key:
    /// "clip.notes:<id>"`, and `UndoJournal.recordEdit` folds a fresh edit into
    /// the current top entry whenever both keys are non-nil, equal, and the top
    /// last merged inside `UndoJournal.coalescingWindow` (800 ms). A repeat
    /// landing within 800 ms of a note drag on the same clip would fold into
    /// the drag's undo entry, and one Cmd-Z would undo both, silently. See
    /// `ProjectStore+Paste.swift`'s `pasteNotes` banner — the primary source
    /// for this shape and the reason it exists as a separate method.
    ///
    /// **`key: nil` is the whole fix.** `recordEdit` requires BOTH keys
    /// non-nil to merge, so a repeat never folds into what came before it, and
    /// nothing folds into it afterward. This is also semantically correct, not
    /// merely safe: unlike a quantize-strength scrub (which coalesces
    /// deliberately), repeat COMPOUNDS on re-run — calling it twice produces
    /// twice the copies, `applyAudioQuantize`'s situation, and that method
    /// likewise takes no key.
    ///
    /// WHY NOT a defaulted parameter on `setClipNotes`: same reason as
    /// `pasteNotes` — the coalescing key is derived from `clipID`, and a Swift
    /// default expression cannot reference another parameter.
    ///
    /// Validation happens entirely OUTSIDE the edit body, in the order below;
    /// nothing here journals. Auto-extend rides INSIDE the same `performEdit`
    /// as the note write (`ClipAutoExtend`, ids = the FRESHLY-MINTED copy ids
    /// only — disjoint from every pre-existing note by construction, exactly
    /// `pasteNotes`' safety), so a repeat that both adds notes and grows the
    /// clip is ONE Cmd-Z. Nothing to write -> NO MUTATION AT ALL: entering
    /// `performEdit` calls `markDirty()` unconditionally, so a fully-refused
    /// (empty-selection) repeat returns the report and touches nothing rather
    /// than opening an edit that journals no change but still dirties the
    /// project (`pasteClips`' rule).
    ///
    /// There is no note-level equivalent of `resolvingOverlaps` — two notes of
    /// the same pitch at the same beat are legal and both play. So this never
    /// dedupes or trims; it reports what it stacked onto instead
    /// (`preExistingNotesInSpan`, `copiesOverlapEachOther`).
    ///
    /// - Parameters:
    ///   - fromBeat/toBeat: clip-relative, half-open on `startBeat` — the
    ///     `clip.getNotes` window convention, matched exactly. Mutually
    ///     exclusive with `noteIDs`. Omitting both selects the whole clip.
    ///   - noteIDs: an explicit selection, mutually exclusive with
    ///     `fromBeat`/`toBeat`.
    ///   - periodBeats: explicit beats between copies — meter-blind BY
    ///     CONSTRUCTION, so there is nothing to silently mis-infer across a
    ///     meter change. Must be > 0 (a zero period would stack `count`
    ///     copies on the source).
    ///   - count: 1...512. The ceiling is a judgment call (fails a typo'd
    ///     `count: 100000` loudly instead of allocating), not a measured
    ///     limit.
    ///   - firstCopyAtBeat: clip-relative start of copy 1; nil = the source
    ///     window's own origin + `periodBeats` (see `sourceWindowOrigin`
    ///     below for what "origin" means in each selection mode).
    ///   - transposeSemitones: `[]` (no transpose), `[n]` (broadcast to every
    ///     copy), or exactly `count` entries (one per copy). CHROMATIC, not
    ///     diatonic — `pitch + n`, clamped by `MIDINote.init` like every other
    ///     note write.
    ///   - extendClip: when true (default), a copy landing past the clip end
    ///     grows the clip exactly as `setClipNotes`'/`pasteNotes`' gestures do
    ///     (capped at `trailingHeadroom`, never eating a neighbour).
    @discardableResult
    public func repeatNotes(
        clipID: UUID,
        fromBeat: Double? = nil,
        toBeat: Double? = nil,
        noteIDs: Set<UUID>? = nil,
        periodBeats: Double,
        count: Int,
        firstCopyAtBeat: Double? = nil,
        transposeSemitones: [Int] = [],
        extendClip: Bool = true
    ) throws -> NoteRepeatReport {
        // m25-a-2 — cleared BEFORE the guards. Every throw below leaves the
        // call with nothing to report.
        lastAutoExtendOutcome = .notNeeded

        // `locateClip` is `private` to ProjectStore.swift, so — exactly like
        // `pasteNotes` — the lookup is inlined here rather than shared.
        guard let t = tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let c = tracks[t].clips.firstIndex(where: { $0.id == clipID }) else {
            throw ProjectError.clipNotFound(clipID)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard let existingNotes = tracks[t].clips[c].notes else {
            throw ProjectError.notAMIDIClip(clipID, verb: "repeat")
        }

        guard periodBeats > 0 else {
            throw ProjectError.invalidClipEdit(
                "clip.repeatNotes periodBeats \(periodBeats) must be > 0 — a zero or negative "
                + "period would stack every copy on the source")
        }
        guard count >= 1, count <= 512 else {
            throw ProjectError.invalidClipEdit(
                "clip.repeatNotes count \(count) must be 1...512 (512 is a judgment-call "
                + "ceiling, not a measured limit — it exists so a typo like count: 100000 fails "
                + "loudly instead of allocating)")
        }
        if noteIDs != nil, fromBeat != nil || toBeat != nil {
            throw ProjectError.invalidClipEdit(
                "clip.repeatNotes: pass either 'noteIds' or 'fromBeat'/'toBeat', not both")
        }
        if let fromBeat, let toBeat, fromBeat >= toBeat {
            throw ProjectError.invalidClipEdit(
                "clip.repeatNotes fromBeat \(fromBeat) must be < toBeat \(toBeat)")
        }
        guard transposeSemitones.isEmpty || transposeSemitones.count == 1
                || transposeSemitones.count == count else {
            throw ProjectError.invalidClipEdit(
                "clip.repeatNotes transposeSemitones has \(transposeSemitones.count) entries — "
                + "must be 0 (no transpose), 1 (broadcast to every copy), or exactly count "
                + "(\(count), one per copy)")
        }

        let clip = tracks[t].clips[c]

        // Select the source pattern, and — the one gap the design left open —
        // define `sourceWindowOrigin` for BOTH selection modes: window mode
        // anchors on `fromBeat` (or 0), noteIDs mode anchors on the minimum
        // selected `startBeat`. Both choices guarantee origin <= every
        // selected note's startBeat BY CONSTRUCTION (window selection already
        // requires `startBeat >= fromBeat`; noteIDs mode takes the min
        // directly), which is what makes "reject a negative resolved offset"
        // sufficient to prevent the beat-0 weld rather than a band-aid.
        let selected: [MIDINote]
        let sourceWindowOrigin: Double
        if let noteIDs {
            selected = existingNotes.filter { noteIDs.contains($0.id) }
            sourceWindowOrigin = selected.map(\.startBeat).min() ?? 0
        } else {
            let resolvedFrom = fromBeat ?? 0
            let resolvedTo = toBeat ?? clip.lengthBeats
            selected = existingNotes.filter { $0.startBeat >= resolvedFrom && $0.startBeat < resolvedTo }
            sourceWindowOrigin = resolvedFrom
        }

        // Selection empty (window matched nothing, or noteIDs matched
        // nothing) -> zeroed report, mutate nothing. NOT an empty
        // `performEdit`: entering it calls `markDirty()` unconditionally.
        guard !selected.isEmpty else {
            return NoteRepeatReport(clipID: clipID, totalNotes: existingNotes.count,
                                    clipLengthBeats: clip.lengthBeats)
        }

        let selectedStart = selected.map(\.startBeat).min() ?? 0
        let selectedEnd = selected.map(\.endBeat).max() ?? 0
        let patternSpanBeats = selectedEnd - selectedStart
        let firstCopyOrigin = firstCopyAtBeat ?? (sourceWindowOrigin + periodBeats)

        func copyOffset(_ i: Int) -> Double {
            firstCopyOrigin + Double(i) * periodBeats - sourceWindowOrigin
        }

        var newNotes: [MIDINote] = []
        newNotes.reserveCapacity(selected.count * count)
        var pitchesClamped = 0
        for i in 0..<count {
            let offset = copyOffset(i)
            let transposeForCopy = transposeSemitones.isEmpty ? 0
                : (transposeSemitones.count == 1 ? transposeSemitones[0] : transposeSemitones[i])
            for note in selected {
                let resolvedStart = note.startBeat + offset
                // ⚠️ `MIDINote.init` floors `startBeat` at 0 PER NOTE — a
                // negative resolved offset would silently weld separate
                // copies onto beat 0 rather than erroring. Reject it instead
                // of letting the clamp eat it (deliberately no epsilon: this
                // mirrors `MIDINote.init`'s own hard floor, so a copy landing
                // exactly AT beat 0 is legal and only a genuinely negative
                // start refuses).
                guard resolvedStart >= 0 else {
                    throw ProjectError.invalidClipEdit(
                        "clip.repeatNotes: copy \(i + 1) of \(count) would place a note at beat "
                        + "\(resolvedStart), before the clip start — raise firstCopyAtBeat or "
                        + "periodBeats")
                }
                let intendedPitch = note.pitch + transposeForCopy
                if !MIDINote.pitchRange.contains(intendedPitch) { pitchesClamped += 1 }
                newNotes.append(MIDINote(pitch: intendedPitch, velocity: note.velocity,
                                         startBeat: resolvedStart, lengthBeats: note.lengthBeats))
            }
        }

        let firstCopyStartBeat = selectedStart + copyOffset(0)
        let lastCopyEndBeat = selectedEnd + copyOffset(count - 1)

        // What this write stacks onto — reported, never dedupe'd or trimmed;
        // there is no note-level `resolvingOverlaps`.
        let preExistingNotesInSpan = existingNotes.filter {
            $0.startBeat >= firstCopyStartBeat && $0.startBeat < lastCopyEndBeat
        }.count
        // True only when there is more than one copy to overlap AND the
        // period is smaller than the pattern's own span — copy n would reach
        // into copy n+1.
        let copiesOverlapEachOther = count > 1 && periodBeats < patternSpanBeats

        // Note space is clip-relative; the meter map is absolute — `+
        // clip.startBeat` is the one place they meet. "Strictly inside":
        // a change exactly AT either edge already governs (or does not yet
        // govern) the whole span, so it is not a CROSSING.
        let timelineSpanStart = clip.startBeat + firstCopyStartBeat
        let timelineSpanEnd = clip.startBeat + lastCopyEndBeat
        let meterChangesInSpan = transport.meterMap.changes.filter {
            $0.startBeat > timelineSpanStart && $0.startBeat < timelineSpanEnd
        }.count

        // Decide the grow BEFORE the edit opens — `ClipAutoExtend` is pure.
        // `ids` is the FRESH copy id set only (disjoint from every
        // pre-existing note by construction, one fresh UUID() per copy via
        // `MIDINote.init` above) — deriving the span from every note would
        // let a forgotten latent note elsewhere in the clip stretch it.
        var grownLength: Double?
        if extendClip {
            let combined = MIDINote.canonicallyOrdered(existingNotes + newNotes)
            let freshIDs = Set(newNotes.map(\.id))
            let outcome = ClipAutoExtend.coverage(of: combined, ids: freshIDs)
                .map { span in
                    ClipAutoExtend.outcome(
                        currentLengthBeats: clip.lengthBeats,
                        coveringOnsetBeat: span.onsetBeat,
                        coveringEndBeat: span.endBeat,
                        beatsPerBar: transport.meterMap.beatsPerBar(atBeat: clip.startBeat),
                        maxLengthBeats: trailingHeadroom(trackIndex: t, clipIndex: c))
                } ?? .notNeeded
            lastAutoExtendOutcome = outcome
            if case .grew(let length) = outcome { grownLength = length }
        }
        // THE store's ONE home for this text — repeat, paste and note-edit
        // cannot describe the same obstacle three different ways. nil
        // whenever extendClip is false, since extension was never attempted.
        let extendRefusal = Self.autoExtendRefusalMessage(lastAutoExtendOutcome)
        let finalLengthForLatency = grownLength ?? clip.lengthBeats
        // m18-f legal-but-latent: the engine schedules on a STRICT `<` test
        // of the onset (`ClipAutoExtend`'s own audibility rule), so "past the
        // end" is an onset test, not a tail test.
        let latentNotesPastClipEnd = newNotes.filter { $0.startBeat >= finalLengthForLatency }.count

        // ONE `performEdit`, and NO `key:` — see the banner above; the
        // missing key is the entire point of this method. `performEdit` is
        // NOT re-entrant (captures before-state, journals unconditionally,
        // no depth counter), so the length is written by mutating `tracks`
        // in place here, exactly as `setClipNotes`/`pasteNotes` do — never
        // via `trimClip`/`fitClipToContent`/`applyTrimWindow` (the latter
        // DROPS notes starting past the new length, which on a capped grow
        // is precisely the legal-but-latent data m18-f promises to keep).
        let label = "Repeat Notes \u{00D7}\(count)"
        performEdit(label) {
            tracks[t].clips[c].notes = MIDINote.canonicallyOrdered(existingNotes + newNotes)
            if let grownLength {
                tracks[t].clips[c].lengthBeats = grownLength
                // No-silent-overlap choke point (m13-b), honoured even though
                // `trailingHeadroom` has already made this a no-op by
                // construction. Belt and braces in the safe direction.
                tracks[t].clips = Self.resolvingOverlaps(
                    in: tracks[t].clips, activeIDs: [clipID],
                    start: clip.startBeat, end: clip.startBeat + grownLength,
                    tempoMap: transport.tempoMap).clips
            }
            engine?.tracksDidChange(tracks)
        }

        // Re-find by id: `resolvingOverlaps` can remove clips and shift
        // indices, so `c` is not trustworthy after the edit closure runs.
        let final = tracks[t].clips.first { $0.id == clipID }
        return NoteRepeatReport(
            clipID: clipID,
            copiesMade: count,
            sourceNoteCount: selected.count,
            notesAdded: newNotes.count,
            totalNotes: final?.notes?.count ?? (existingNotes.count + newNotes.count),
            patternSpanBeats: patternSpanBeats,
            firstCopyStartBeat: firstCopyStartBeat,
            lastCopyEndBeat: lastCopyEndBeat,
            clipLengthBeats: final?.lengthBeats ?? finalLengthForLatency,
            extended: grownLength != nil,
            extendRefusal: extendRefusal,
            latentNotesPastClipEnd: latentNotesPastClipEnd,
            meterChangesInSpan: meterChangesInSpan,
            preExistingNotesInSpan: preExistingNotesInSpan,
            copiesOverlapEachOther: copiesOverlapEachOther,
            pitchesClamped: pitchesClamped)
    }
}
