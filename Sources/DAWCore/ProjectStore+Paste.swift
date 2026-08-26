import Foundation

/// One clip's landing, as the app's `PasteAnchorPolicy` resolved it.
///
/// ⚠️ THE STORE DOES NOT DECIDE *WHERE*. Every anchor rule — paste at the
/// playhead, preserve relative offsets, clamp the GROUP (never its members) at
/// beat 0, in-place vs relocated track resolution and its mandatory index clamp
/// — lives in `DAWAppKit.PasteAnchorPolicy`, which is pure and testable
/// headlessly. This type is the wire between the two layers, and DAWCore holds
/// its own spelling of it because `DAWAppKit` imports `DAWCore` and not the
/// reverse.
public struct ClipPasteLanding: Equatable, Sendable {
    /// The clip as it was COPIED. Its `id` is the source's and is deliberately
    /// not reused: `pasteClips` re-mints through `ProjectStore.reidentified`,
    /// because pasting twice must yield two distinct sets of objects.
    public var clip: Clip
    /// Which track it lands on.
    public var targetTrackID: UUID
    /// Which project beat its start moves to.
    public var startBeat: Double

    public init(clip: Clip, targetTrackID: UUID, startBeat: Double) {
        self.clip = clip
        self.targetTrackID = targetTrackID
        self.startBeat = startBeat
    }
}

/// What happened to one requested landing — the `AudioImportOutcome` shape.
public struct ClipPasteOutcome: Equatable, Sendable {
    /// The COPIED clip's id, so a caller can match an outcome back to the
    /// clipboard entry that produced it.
    public var sourceClipID: UUID
    /// The clip that landed, under its fresh id; nil when this landing failed.
    public var clip: Clip?
    /// The track it landed on; nil when this landing failed.
    public var trackID: UUID?
    /// Why this landing failed, verbatim from the store's own error, or nil.
    public var error: String?
    /// Ordinary residents this landing TRIMMED, and those it REMOVED outright —
    /// the `ClipMoveResult` honesty shape. A paste that silently ate a clip the
    /// user could still see is the complaint that convention exists to prevent.
    public var trimmedClipIDs: [UUID]
    public var removedClipIDs: [UUID]

    public init(sourceClipID: UUID, clip: Clip? = nil, trackID: UUID? = nil,
                error: String? = nil, trimmedClipIDs: [UUID] = [],
                removedClipIDs: [UUID] = []) {
        self.sourceClipID = sourceClipID
        self.clip = clip
        self.trackID = trackID
        self.error = error
        self.trimmedClipIDs = trimmedClipIDs
        self.removedClipIDs = removedClipIDs
    }
}

@MainActor
extension ProjectStore {

    // MARK: - Paste clips (m23-ek-3)

    /// Places N copied clips in ONE undo step.
    ///
    /// BUILT TO THE `importAudioBatch` TEMPLATE, which is the in-tree precedent
    /// for exactly this shape and is followed here point for point:
    ///
    ///   • **All validation happens OUTSIDE the edit body.** A landing whose
    ///     target track vanished, or whose content the target track cannot hold,
    ///     is reported as a per-item error and SKIPPED — it never aborts the
    ///     others. Guards must not journal.
    ///   • **Nothing placeable → NO MUTATION AT ALL.** Not an empty
    ///     `performEdit`: `performEdit` journals only when the captured state
    ///     actually changed, but entering it still calls `markDirty()`, so a
    ///     fully-refused paste would mark an untouched project dirty. It returns
    ///     the errors and touches nothing.
    ///   • **One `performEdit`, one `engine?.tracksDidChange` at the very end.**
    ///     N clips = ONE undo step.
    ///
    /// ⚠️ **OVERLAP RESOLVES, AND THE CLAIMANT SET IS THE WHOLE PASTE.** Every
    /// landing runs through `resolvingOverlaps` — the ONE no-silent-overlap
    /// choke point (m11-d/m13-b) — so a paste onto an occupied region trims its
    /// ordinary residents exactly as `clip.move` and `clip.duplicate` do, rather
    /// than shipping a silent +6 dB stack. The `activeIDs` set passed to it is
    /// EVERY clip this paste is placing on that track, not just the one whose
    /// window is being resolved: claimants are exempt from trimming, so without
    /// that a sibling landed a moment earlier would be treated as a resident and
    /// TRIMMED BY ITS OWN GROUP — a silent deformation of the material the user
    /// copied, which is a worse failure than the overlap it was guarding.
    ///
    /// ⚠️ The complementary half of that invariant lives in `PasteAnchorPolicy`,
    /// which refuses to emit two landings that overlap each other on one track
    /// (reachable only through the relocated paste's mandatory index clamp,
    /// which can fold two source tracks onto one). Claimant-exemption here plus
    /// sibling-skip there is what makes "pasted clips never silently stack" a
    /// property rather than a hope. **Both halves are needed; neither alone is
    /// sufficient.**
    ///
    /// TAKE/COMP MEMBERS CANNOT ARISE. `reidentified` clears `takeGroupID`,
    /// which is exactly a paste's semantics — the copy is an ordinary clip, not
    /// a member of the take group its source belonged to.
    ///
    /// - Returns: per-landing outcomes in REQUEST ORDER, so a caller can report
    ///   skips beside the clips that did land.
    @discardableResult
    public func pasteClips(_ landings: [ClipPasteLanding]) throws -> [ClipPasteOutcome] {
        guard !landings.isEmpty else { return [] }

        // ═══ VALIDATE OUTSIDE THE EDIT BODY ═══
        //
        // Fresh ids are minted HERE, before any mutation, for two reasons: the
        // outcomes can name the placed clip even for the first landing, and the
        // claimant set below has to be complete before the FIRST call to
        // `resolvingOverlaps` — a set assembled as we go would leave the earliest
        // sibling unprotected.
        struct Prepared {
            let sourceClipID: UUID
            let placed: Clip?
            let trackIndex: Int?
            let error: String?
        }

        var prepared: [Prepared] = []
        prepared.reserveCapacity(landings.count)
        for landing in landings {
            guard let index = tracks.firstIndex(where: { $0.id == landing.targetTrackID }) else {
                prepared.append(Prepared(
                    sourceClipID: landing.clip.id, placed: nil, trackIndex: nil,
                    error: ProjectError.trackNotFound(landing.targetTrackID).errorDescription))
                continue
            }
            // `Track.canHold(_:)` — the ONE home for clip/track eligibility
            // (m23-v / m23-aj), never a local `kind ==` test. CONTENT decides:
            // `Clip.isMIDI` is `notes != nil`, and a bus answers false to both
            // halves.
            guard tracks[index].canHold(landing.clip) else {
                let error: ProjectError = landing.clip.isMIDI
                    ? .midiClipsRequireInstrumentTrack(tracks[index].kind)
                    : .trackKindUnsupported(tracks[index].kind)
                prepared.append(Prepared(sourceClipID: landing.clip.id, placed: nil,
                                         trackIndex: nil, error: error.errorDescription))
                continue
            }
            // `reidentified` is the ONE home for the paste-shaped rebuild: fresh
            // id, controller lanes copied verbatim (points are identity-free),
            // `takeGroupID` cleared. `max(0, …)` is belt-and-braces — the group
            // clamp already ran in `PasteAnchorPolicy` — and mirrors
            // `duplicateClip`'s own landing clamp so the two verbs cannot
            // disagree about what a negative beat means.
            let placed = ProjectStore.reidentified(landing.clip, id: UUID(),
                                                   startBeat: max(0, landing.startBeat))
            prepared.append(Prepared(sourceClipID: landing.clip.id, placed: placed,
                                     trackIndex: index, error: nil))
        }

        // Nothing placeable → no mutation, no dirty flag, no stray undo entry.
        let placeable = prepared.filter { $0.placed != nil }
        guard !placeable.isEmpty else {
            return prepared.map { ClipPasteOutcome(sourceClipID: $0.sourceClipID, error: $0.error) }
        }

        // The claimant set, per track: EVERY id this paste places there.
        var claimants: [Int: Set<UUID>] = [:]
        for entry in placeable {
            guard let index = entry.trackIndex, let placed = entry.placed else { continue }
            claimants[index, default: []].insert(placed.id)
        }

        let tempoMap = transport.tempoMap
        var trimmed: [UUID: [UUID]] = [:]
        var removed: [UUID: [UUID]] = [:]

        let label = placeable.count == 1
            ? "Paste Clip '\(placeable[0].placed!.name)'"
            : "Paste \(placeable.count) Clips"

        performEdit(label) {
            // Append everything first, so the claimant exemption is in force for
            // the very first window resolved: a sibling that has not been added
            // yet cannot be protected by being named in `activeIDs`.
            for entry in placeable {
                guard let index = entry.trackIndex, let placed = entry.placed else { continue }
                tracks[index].clips.append(placed)
            }
            // Then resolve each landing's OWN window. Not one union window per
            // track: a group with gaps would have its gaps swept too, trimming
            // residents the paste never covered.
            for entry in placeable {
                guard let index = entry.trackIndex, let placed = entry.placed else { continue }
                let resolved = ProjectStore.resolvingOverlaps(
                    in: tracks[index].clips,
                    activeIDs: claimants[index] ?? [placed.id],
                    start: placed.startBeat, end: placed.startBeat + placed.lengthBeats,
                    tempoMap: tempoMap)
                tracks[index].clips = resolved.clips
                trimmed[placed.id, default: []].append(contentsOf: resolved.trimmedIDs)
                removed[placed.id, default: []].append(contentsOf: resolved.removedIDs)
            }
            engine?.tracksDidChange(tracks)
        }

        return prepared.map { entry in
            guard let placed = entry.placed, let index = entry.trackIndex else {
                return ClipPasteOutcome(sourceClipID: entry.sourceClipID, error: entry.error)
            }
            // Re-read: a landing can itself be reshaped by a LATER landing's
            // overlap resolution only if the two overlapped, which the policy
            // forbids — but reading the live clip rather than the prepared one
            // means this reports what is actually in the project either way.
            let final = tracks.first { $0.id == tracks[index].id }?
                .clips.first { $0.id == placed.id } ?? placed
            return ClipPasteOutcome(
                sourceClipID: entry.sourceClipID, clip: final, trackID: tracks[index].id,
                trimmedClipIDs: trimmed[placed.id] ?? [],
                removedClipIDs: removed[placed.id] ?? [])
        }
    }

    // MARK: - Paste notes (m23-ek-3)

    /// Replaces a MIDI clip's note list as an UNCOALESCED edit — the note
    /// paste's store entry point.
    ///
    /// ⚠️⚠️ **THIS EXISTS FOR ONE REASON: `setClipNotes` COALESCES, AND A PASTE
    /// MUST NOT.** That method journals with `key: "clip.notes:<id>"` and
    /// `UndoJournal.recordEdit` folds a fresh edit into the current top entry
    /// whenever both keys are non-nil and equal and the top last merged inside
    /// `UndoJournal.coalescingWindow` — **800 ms**. So a note paste routed
    /// through the roll's ordinary `commit()` → `setClipNotes` path, landing
    /// within 800 ms of a note drag on the same clip, **FOLDS INTO THE DRAG'S
    /// ENTRY, AND ONE ⌘Z UNDOES BOTH.** Two rapid pastes fold into one. This is
    /// not theoretical: it is the shipped behaviour of the obvious
    /// implementation, and a test that pastes once into a quiet clip passes
    /// while never seeing it.
    ///
    /// **`key: nil` is the whole fix.** `recordEdit` requires BOTH keys non-nil
    /// to merge, so a paste never folds into what came before it — and, in the
    /// other direction, a note drag immediately AFTER a paste does not fold into
    /// the paste either. Paste and its neighbours are always distinct entries.
    ///
    /// WHY NOT A DEFAULTED PARAMETER ON `setClipNotes`: the coalescing key is
    /// derived from `clipID`, and a Swift default expression cannot reference
    /// another parameter. A separate method is the clean version and it is
    /// purely ADDITIVE — `setClipNotes` and every one of its callers (the wire's
    /// `clip.setNotes`, the roll's `commit()`, MIDI import) are untouched, and
    /// no wire verb is added for this.
    ///
    /// Validation is `setClipNotes`', term for term: unknown id, take/comp
    /// member, not a MIDI clip, and the re-clamp of every note through
    /// `MIDINote.init` before canonical ordering so a caller that mutated a
    /// note's fields out of range cannot slip past. ⚠️ That re-clamp is also why
    /// `PasteAnchorPolicy` clamps the paste anchor as a GROUP: `MIDINote.init`
    /// floors `startBeat` at 0 PER NOTE, so a payload arriving here with
    /// negative starts would not error — it would silently weld every early note
    /// onto beat 0.
    ///
    /// **`extendToCover` (m25-f-2) — AUTO-EXTEND, still ONE undo step.** Names
    /// the notes THIS PASTE placed. If one of them lands past the clip's end the
    /// clip GROWS to cover it (`ClipAutoExtend` decides how far) inside THE SAME
    /// `performEdit` as the note write, so a paste that both adds notes and
    /// lengthens the clip is ONE undoable action. This is the defect the user
    /// reported on 2026-08-13: *"when I paste to the clip which is smaller then
    /// selected notes, it does not expand automatically to accomodate pasted
    /// notes"*. The default `[]` is the pre-m25-f-2 behaviour byte for byte.
    ///
    /// ⚠️ **WHY THIS VERB GROWS RATHER THAN THE PASTE ROUTING THROUGH
    /// `setClipNotes`.** The obvious "simplification" — send the paste down
    /// `setClipNotes(clipID:notes:extendToCover:)`, which already has this
    /// logic — reintroduces the exact trap the banner above exists to close:
    /// that verb journals under `clip.notes:<id>`, and one ⌘Z would undo the
    /// paste TOGETHER WITH whatever note edit preceded it inside 800 ms. The
    /// grow rule is duplicated here deliberately; the coalescing key is not.
    /// `ClipAutoExtend` being a pure `DAWCore` namespace is what keeps the two
    /// copies from drifting — the POLICY lives in one place, only the call does
    /// not.
    ///
    /// ⚠️ **IDS, NOT A BOOL — AND ON THIS PATH THE IDS ARE THE SAFETY.** The
    /// submission handed here is the roll's WHOLE draft, which can already hold
    /// legal-but-latent notes far past the clip end (m18-f: store-legal, drawn,
    /// engine-windowed by strict `<`). `ClipAutoExtend.coverage` takes the MAX
    /// end over the ids it is given, so deriving the span from all notes would
    /// mean a two-note paste at bar 2 resurrects a forgotten note at bar 20 and
    /// stretches the clip to it. Because `PasteAnchorPolicy.translatedNotes`
    /// mints a fresh `UUID()` per pasted note, this id set is DISJOINT from
    /// every pre-existing note by construction — which is how paste gets, by a
    /// different mechanism, the guarantee m25-f-3's `moveIDsStartingAudible`
    /// baseline filter buys for a drag. (That filter is inapplicable here: it
    /// keys off a PRE-gesture onset, and a pasted note has no prior position.)
    ///
    /// ⚠️ **THE GROW NEVER EATS A NEIGHBOUR** — same ceiling as `setClipNotes`:
    /// `trailingHeadroom`, because a grow is routed through `resolvingOverlaps`
    /// and that choke point resolves an overlap by TRIMMING OR DELETING the
    /// stationary clip. With no room the pasted notes simply stay latent.
    ///
    /// - Returns: the updated clip.
    @discardableResult
    public func pasteNotes(clipID: UUID, notes: [MIDINote],
                           extendToCover: Set<UUID> = []) throws -> Clip {
        // m25-a-2 — cleared before the guards; see `setClipNotes` for why.
        lastAutoExtendOutcome = .notNeeded
        guard let t = tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let c = tracks[t].clips.firstIndex(where: { $0.id == clipID }) else {
            throw ProjectError.clipNotFound(clipID)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard tracks[t].clips[c].notes != nil else {
            throw ProjectError.notAMIDIClip(clipID, verb: "paste")
        }
        let reclamped = notes.map {
            MIDINote(id: $0.id, pitch: $0.pitch, velocity: $0.velocity,
                     startBeat: $0.startBeat, lengthBeats: $0.lengthBeats)
        }
        let ordered = MIDINote.canonicallyOrdered(reclamped)

        // Decide the grow BEFORE the edit opens — `ClipAutoExtend` is pure, and
        // the meter is sampled at the clip's start exactly as `setClipNotes`
        // and the piano roll's own bar lines sample it, so the new end lands on
        // a line the user can already see.
        let clip = tracks[t].clips[c]
        // m25-a-2 — the SAME outcome shape as `setClipNotes`, and `?? .notNeeded`
        // for the same reason: an empty/unmatched `extendToCover` is the ordinary
        // case, never a refusal. The refusal MESSAGE is composed by the store's
        // one `autoExtendRefusalMessage`, so paste and note-edit cannot describe
        // the same obstacle in two different ways.
        let outcome = ClipAutoExtend.coverage(of: ordered, ids: extendToCover)
            .map { span in
                ClipAutoExtend.outcome(
                    currentLengthBeats: clip.lengthBeats,
                    coveringOnsetBeat: span.onsetBeat,
                    coveringEndBeat: span.endBeat,
                    beatsPerBar: transport.meterMap.beatsPerBar(atBeat: clip.startBeat),
                    maxLengthBeats: trailingHeadroom(trackIndex: t, clipIndex: c))
            } ?? .notNeeded
        lastAutoExtendOutcome = outcome
        var grownLength: Double?
        if case .grew(let length) = outcome { grownLength = length }

        // ONE `performEdit`, and NO `key:`. See the banner — the missing key is
        // the entire point of the method, and the single edit is what keeps a
        // grown paste one ⌘Z rather than two. `performEdit` is NOT re-entrant
        // (it captures before-state and journals unconditionally, with no depth
        // counter), so the length is written by mutating `tracks` in place here
        // rather than by calling `trimClip` — `setClipNotes`' group-verb
        // precedent, including its reason for NOT routing through
        // `applyTrimWindow`: that helper DROPS every note starting past the new
        // length, which on a capped grow is precisely the legal-but-latent data
        // m18-f promises to keep.
        let label = grownLength == nil ? "Paste Notes" : "Paste Notes & Extend Clip"
        performEdit(label) {
            tracks[t].clips[c].notes = ordered
            if let grownLength {
                tracks[t].clips[c].lengthBeats = grownLength
                // The no-silent-overlap choke point (m13-b), honoured even
                // though `trailingHeadroom` has already made it a no-op by
                // construction. Belt and braces in the safe direction.
                tracks[t].clips = Self.resolvingOverlaps(
                    in: tracks[t].clips, activeIDs: [clipID],
                    start: clip.startBeat, end: clip.startBeat + grownLength,
                    tempoMap: transport.tempoMap).clips
            }
            engine?.tracksDidChange(tracks)
        }
        // Re-find by id: `resolvingOverlaps` can remove clips and shift indices.
        return tracks[t].clips.first { $0.id == clipID } ?? tracks[t].clips[c]
    }
}
