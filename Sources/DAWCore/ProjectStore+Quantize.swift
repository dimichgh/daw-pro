import Foundation

/// One clip-mapped transient for the control surface (M5 iii-e, spec §7):
/// the raw SOURCE-FILE time plus its position mapped into timeline beats
/// through the clip's window at the current tempo and stretch ratio. The
/// `clip.detectTransients` response is exactly `{transients: [ClipTransient],
/// count}` through this Codable (wire-never-drifts rule).
public struct ClipTransient: Codable, Sendable, Equatable {
    /// Onset position in SOURCE-FILE seconds (geometry-free, cache-stable).
    public var sourceSeconds: Double
    /// The same onset mapped to timeline beats:
    /// `clip.startBeat + (t − startOffsetSeconds) · stretchRatio · tempo/60`.
    public var beat: Double
    /// 0...1, normalized against the strongest onset in the source file.
    public var strength: Double

    public init(sourceSeconds: Double, beat: Double, strength: Double) {
        self.sourceSeconds = sourceSeconds
        self.beat = beat
        self.strength = strength
    }
}

/// Quantize store operations (M5 iii-d, spec §4). Destructive quantize with
/// snapshot-journal undo: the note edit rides the SAME `tracksDidChange`
/// restart seam `setClipNotes` uses — the engine never learns about quantize.
/// New domains live in extension files (ProjectStore.swift is 2.3k lines).
@MainActor
extension ProjectStore {

    /// Transient onsets for an AUDIO clip (M5 iii-e, spec §5a/§7): forwards
    /// to the engine's offline `detectTransients` (content-key cached,
    /// whole-source-file analysis — the `clipStretchStatus` engine-forwarding
    /// precedent, async because analysis is), then WINDOW-FILTERS to the
    /// clip's current source window `[startOffsetSeconds, startOffset +
    /// sourceWindowSeconds)` and maps each onset to timeline beats at the
    /// current tempo/stretch. `sensitivity` 0...1 (higher finds more onsets).
    ///
    /// Rejections, verbatim: a MIDI clip → `transientsRequireAudioClip`;
    /// unknown id → `clipNotFound`; headless (no engine) →
    /// `engineUnavailable`. The clip is RE-LOCATED after the await (spec §8
    /// risk 7): deleted mid-detect → `clipNotFound`; window edits are
    /// harmless because detection is per-file, not per-clip.
    ///
    /// Read-only — no `performEdit`, no undo entry, nothing persisted
    /// (transient maps are regenerable by definition, the stretch-cache rule).
    public func detectClipTransients(clipId: UUID, sensitivity: Double = 0.5) async throws -> [ClipTransient] {
        // Clip validation FIRST: a MIDI clip is wrong regardless of engine
        // availability — headless callers get the actionable rejection, not
        // engineUnavailable.
        guard let (t, c) = locateClipIndex(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let clip = tracks[t].clips[c]
        guard !clip.isMIDI else {
            throw ProjectError.transientsRequireAudioClip(clipId)
        }
        guard let url = clip.audioFileURL else {
            throw ProjectError.invalidClipEdit(
                "clip \(clipId.uuidString) has no audio file to analyze")
        }
        guard let engine else { throw ProjectError.engineUnavailable }
        let markers = try await engine.detectTransients(inFileAt: url, sensitivity: sensitivity)
        // Async race (spec §8 risk 7): re-locate by id after the await.
        guard let (t2, c2) = locateClipIndex(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let current = tracks[t2].clips[c2]
        let tempoMap = transport.tempoMap
        let windowStart = current.startOffsetSeconds
        let windowEnd = windowStart + current.sourceWindowSeconds(tempoMap: tempoMap)
        // Half-open window: an onset exactly at the clip's end boundary
        // belongs to the material after it (the splitClip partition rule).
        // Beat projection = inverse integral from the clip start of the
        // stretch-scaled source offset (m12-b, design row 22).
        return markers
            .filter { $0.timeSeconds >= windowStart && $0.timeSeconds < windowEnd }
            .map { marker in
                ClipTransient(
                    sourceSeconds: marker.timeSeconds,
                    beat: tempoMap.beat(
                        from: current.startBeat,
                        elapsedSeconds: (marker.timeSeconds - windowStart) * current.stretchRatio),
                    strength: marker.strength)
            }
    }

    /// Quantizes a MIDI clip's note onsets toward the grid (spec §4). Note
    /// lengths are preserved unless `settings.quantizeEnds`; onsets move by
    /// `settings.strength` toward the swing-adjusted grid target
    /// (`QuantizeTarget.nearest`); output stays canonically ordered.
    ///
    /// ⭐ **THE GRID IS THE SONG'S (m23-ap I5-F4).** The clip's own `startBeat`
    /// is read HERE and handed to `MIDIQuantizer.quantize(_:settings:
    /// clipStartBeat:)`, so a clip that starts off a grid line quantizes onto
    /// the lines the piano roll draws, not onto lines counted from its own
    /// first beat. Reading it here rather than taking it from the caller is the
    /// point: the quantize panel (`QuantizeModel` → `DAWProApp`) and the wire's
    /// `clip.quantize` both converge on this method, so neither can pass a
    /// stale start, and there is no second home for "where does this clip sit".
    /// Swing and grooves count from the song's beat 0 too (the 2026-09-27
    /// ruling; `clip.quantizeAudio` always did), so the notes that swing are
    /// the song's offbeats. A clip that starts on a grid line gets exactly what
    /// it got before when the quantize is straight, or when the line's song
    /// slot is even (swing) and a whole number of groove cycles from beat 0.
    ///
    /// Rejections, verbatim: an AUDIO clip → `quantizeRequiresMIDIClip`
    /// (audio quantize is the separate `clip.quantizeAudio`, M5 iii-f); a comp
    /// MEMBER → `clipInTakeGroup` via the shared `requireNotCompMember` guard
    /// (edit the comp or `take.flatten` first). An unknown id → `clipNotFound`.
    ///
    /// Coalesces under `clip.quantize:<clipId>` so a strength-slider scrub folds
    /// into ONE undo step (the `setClipNotes` per-clip-coalesce precedent).
    /// `performEdit("Quantize Notes")`. Returns the updated clip.
    @discardableResult
    public func quantizeClipNotes(clipId: UUID, settings: QuantizeSettings) throws -> Clip {
        guard let (t, c) = locateClipIndex(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        // Comp members are store-managed — reject before touching notes (§2).
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        // MIDI only in v0 — audio quantize is a different op (iii-f).
        guard let notes = tracks[t].clips[c].notes else {
            throw ProjectError.quantizeRequiresMIDIClip(clipId)
        }
        let quantized = MIDIQuantizer.quantize(notes, settings: settings,
                                               clipStartBeat: tracks[t].clips[c].startBeat)
        performEdit("Quantize Notes", key: "clip.quantize:\(clipId.uuidString)") {
            tracks[t].clips[c].notes = quantized
            engine?.tracksDidChange(tracks)
        }
        return tracks[t].clips[c]
    }

    // MARK: - Audio quantize (M5 iii-f, spec §5b)

    /// Slices an AUDIO clip at its transients and nudges each slice toward the
    /// grid, replacing the clip with the plan's slices in ONE
    /// `performEdit("Quantize Audio")` (NO coalescing — a re-run compounds; undo
    /// first). The slices are ordinary clips on the existing `tracksDidChange`
    /// restart seam; the engine never learns about quantize.
    ///
    /// Rejections, verbatim: a comp MEMBER → `clipInTakeGroup` (edit the comp or
    /// `take.flatten` first); a MIDI clip → `quantizeRequiresAudioClip`; a
    /// NON-IDENTITY stretch → `audioQuantizeStretchUnsupported` (v0 cut —
    /// un-stretch or bounce first); fewer than 2 usable transients →
    /// `audioQuantizeNoTransients` (nothing changes). An unknown track/clip →
    /// `trackNotFound`/`clipNotFound`.
    ///
    /// `transientsSourceSeconds` are raw source-file onsets (from the engine or a
    /// fixture); the plan window-filters and beat-maps them itself. Returns the
    /// emitted slices in timeline order.
    @discardableResult
    public func applyAudioQuantize(trackId: UUID, clipId: UUID,
                                   transientsSourceSeconds: [Double],
                                   settings: AudioQuantizeSettings) throws -> [Clip] {
        let (t, c) = try locateClip(trackId: trackId, clipId: clipId)
        // Comp members are store-managed — reject before slicing (§2). compute
        // handles the MIDI / stretch / too-few-transients rejections.
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let clip = tracks[t].clips[c]
        let slices = try AudioQuantizePlan.compute(
            clip: clip,
            transientsSourceSeconds: transientsSourceSeconds,
            tempoMap: transport.tempoMap,
            settings: settings)
        performEdit("Quantize Audio") {
            tracks[t].clips.remove(at: c)
            tracks[t].clips.insert(contentsOf: slices, at: c)
            engine?.tracksDidChange(tracks)
        }
        return slices
    }

    /// Async convenience (spec §5b): detects the clip's transients on the engine
    /// (content-key cached, off the render thread), RE-LOCATES the clip by id
    /// after the await (deleted/edited mid-detect → `clipNotFound`; detection is
    /// per-FILE so window edits are harmless), then `applyAudioQuantize`.
    ///
    /// Fails fast BEFORE the (potentially slow) detection: `engineUnavailable`
    /// headless, and the same comp-member / MIDI / stretch rejections
    /// `applyAudioQuantize` surfaces, so an agent gets the actionable error
    /// without waiting on analysis. Returns the emitted slices.
    ///
    /// m32-b1: `settings.divisions` skips detection entirely — boundaries are
    /// N equal parts of the clip's own source window — so that path needs no
    /// engine and succeeds headless. Every other rejection is unchanged.
    @discardableResult
    public func quantizeAudioClip(trackId: UUID, clipId: UUID,
                                  settings: AudioQuantizeSettings) async throws -> [Clip] {
        // m32-b1: the engine is needed ONLY to detect transients. A
        // fixed-division chop derives its boundaries arithmetically from the
        // clip's own window, so it works headless.
        //
        // ⚠️ The guard deliberately stays FIRST rather than moving below the
        // validation block: for a detector-path caller (`divisions == nil`)
        // the thrown-error ORDER must be byte-identical to the shipped
        // behaviour. Moving it down would flip headless + MIDI clip from
        // `engineUnavailable` to `quantizeRequiresAudioClip`.
        guard settings.divisions != nil || engine != nil else {
            throw ProjectError.engineUnavailable
        }
        // Pre-detection validation (fast, correct errors).
        let (t, c) = try locateClip(trackId: trackId, clipId: clipId)
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let clip = tracks[t].clips[c]
        guard !clip.isMIDI else { throw ProjectError.quantizeRequiresAudioClip(clipId) }
        guard clip.isStretchIdentity else {
            throw ProjectError.audioQuantizeStretchUnsupported(clipId)
        }
        guard let url = clip.audioFileURL else {
            throw ProjectError.invalidClipEdit(
                "clip \(clipId.uuidString) has no audio file to quantize")
        }
        // m32-b1: fixed-division chop — no detection, no PCM, no engine.
        // `[]` says out loud that the transient argument is unused here
        // (`AudioQuantizePlan.compute` ignores it whenever `divisions` is set).
        if settings.divisions != nil {
            return try applyAudioQuantize(
                trackId: trackId, clipId: clipId,
                transientsSourceSeconds: [], settings: settings)
        }
        // Unreachable when `divisions == nil` (the first guard already proved
        // the engine is present); re-bound here only to unwrap it.
        guard let engine else { throw ProjectError.engineUnavailable }
        let markers = try await engine.detectTransients(inFileAt: url, sensitivity: settings.sensitivity)
        // Re-locate by id (spec §8 risk 7) happens inside applyAudioQuantize.
        return try applyAudioQuantize(
            trackId: trackId, clipId: clipId,
            transientsSourceSeconds: markers.map(\.timeSeconds),
            settings: settings)
    }

    // MARK: - Groove templates (M5 iii-g, spec §6)

    /// Extracts a groove template from a clip's onsets and appends it to the
    /// project palette (`grooveTemplates`). A MIDI clip uses its note onsets
    /// (clip-relative beats) directly; an AUDIO clip is detected first
    /// (`detectClipTransients` on the engine, content-key cached), and each
    /// transient's timeline beat is taken clip-relative. Onsets fold into the
    /// cycle and per-slot deviations AVERAGE; empty slots read 0
    /// (`GrooveTemplate.extract`). Defaults: `gridBeats` 0.25 (1/16),
    /// `cycleBeats` 4 (one bar at x/4 — spec §6 ASSUMPTION, no meter model yet).
    ///
    /// ⚠️ SUPERSEDED (m23-ap I5-F4): spec §6 took onsets RELATIVE to the clip
    /// start (slot 0 = clip start). A groove's slots now count from the SONG's
    /// beat 0, as `quantizeClipNotes` applies them (the orchestrator's
    /// 2026-09-27 ruling), so a groove taken from one clip lands on the same
    /// song beats when it is applied to another — a push on the "and" of each
    /// beat stays on the "and", wherever either clip starts.
    ///
    /// Two steps. (1) The deviations are measured from the SONG's grid lines —
    /// the ones `quantizeClipNotes` lands notes on: an off-grid clip's onsets
    /// are shifted by its phase before `GrooveTemplate.extract` measures them,
    /// so a take played squarely on the drawn lines extracts as straight (from
    /// the clip's own first beat it would read as a constant push of the phase
    /// — a groove nobody played). (2) The measured table, whose slot 0 is the
    /// line at or before the clip's first beat, is RELABELLED so that line
    /// becomes its song slot: entry `j` moves to `(firstLine + j) mod count`.
    /// A relabel, not a shift of the onsets by the clip's whole start, so no
    /// deviation loses bits on a late clip. Extract → apply on the same clip
    /// round-trips wherever it starts; a clip that starts on a line whose song
    /// slot is a whole number of cycles from beat 0 extracts exactly as before.
    ///
    /// Rejections, verbatim: unknown id → `clipNotFound`; a non-positive grid or
    /// cycle → `invalidClipEdit`; a grid finer than `QuantizeLimits
    /// .minimumGridBeats` or not finite, a cycle of more than `QuantizeLimits
    /// .maximumGrooveSlots` slots or not finite, or an onset 2^53 or more grid
    /// slots into the clip → `invalidClipEdit` naming the bound (m23-ap I5-F4
    /// round 3: `GrooveTemplate.extract` converts `cycle / grid` and each
    /// `onset / grid` to `Int`, which traps at 2^63, and a huge cycle allocates
    /// gigabytes well before that. This store is its only caller in `Sources/`,
    /// so these three guards keep every app path off those traps); an AUDIO clip with no engine → `engineUnavailable`;
    /// an audio clip with no file → `invalidClipEdit`. The clip is RE-LOCATED after
    /// the (audio) await (deleted mid-detect → `clipNotFound`). Appends inside
    /// `performEdit("Extract Groove")` so undo covers it. Returns the new template.
    @discardableResult
    public func extractGroove(fromClipId clipId: UUID, name: String,
                              gridBeats: Double = 0.25,
                              cycleBeats: Double = 4) async throws -> GrooveTemplate {
        guard gridBeats > 0 else {
            throw ProjectError.invalidClipEdit(
                "cannot extract a groove with gridBeats \(gridBeats) — must be > 0")
        }
        guard cycleBeats > 0 else {
            throw ProjectError.invalidClipEdit(
                "cannot extract a groove with cycleBeats \(cycleBeats) — must be > 0")
        }
        guard gridBeats.isFinite, gridBeats >= QuantizeLimits.minimumGridBeats else {
            throw ProjectError.invalidClipEdit(
                "cannot extract a groove with gridBeats \(gridBeats) — the finest grid is 1/1024 beat "
                + "(\(QuantizeLimits.minimumGridBeats))")
        }
        let slots = (cycleBeats / gridBeats).rounded()
        guard cycleBeats.isFinite, slots <= Double(QuantizeLimits.maximumGrooveSlots) else {
            throw ProjectError.invalidClipEdit(
                "cannot extract a groove with cycleBeats \(cycleBeats) on a \(gridBeats)-beat grid — "
                + "a groove holds at most \(QuantizeLimits.maximumGrooveSlots) slots (cycleBeats ÷ gridBeats)")
        }
        guard let (t, c) = locateClipIndex(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let onsets: [Double]
        let clipStart: Double
        if let notes = tracks[t].clips[c].notes {
            // MIDI: note onsets are already clip-relative beats.
            onsets = notes.map(\.startBeat)
            clipStart = tracks[t].clips[c].startBeat
        } else {
            // Audio: detect transients (async, engine), then take each onset's
            // beat RELATIVE to the clip start. detectClipTransients re-locates the
            // clip itself; we re-locate again (same actor hop, no interleave) to
            // read the current start for the clip-relative subtraction.
            let transients = try await detectClipTransients(clipId: clipId, sensitivity: 0.5)
            guard let (t2, c2) = locateClipIndex(clipId) else {
                throw ProjectError.clipNotFound(clipId)
            }
            clipStart = tracks[t2].clips[c2].startBeat
            onsets = transients.map { $0.beat - clipStart }
        }
        // m23-ap I5-F4: (1) measured from the SONG's grid lines, (2) slots
        // relabelled to count from the song's beat 0 (see the doc above). A
        // clip on a line has phase exactly 0 and its onsets go in untouched.
        let phase = SongGridPhase.phase(of: clipStart, step: gridBeats)
        let measured = phase == 0 ? onsets : onsets.map { $0 + phase }
        // m23-ap I5-F4 round 3: `GrooveTemplate.extract` converts each onset's
        // slot, `(onset / gridBeats).rounded()`, to `Int`, which traps at 2^63:
        // a note 2.4e18 beats into a clip at 1/16, or 9.1e15 beats in at the
        // finest grid (`parseNotes` puts no ceiling on a note's start). Past
        // 2^53 slots a Double cannot tell adjacent slots apart, so no deviation
        // that far out can be measured: refuse in words, before extracting.
        // No take comes near it (2^53 sixteenths is 2.25e15 beats), so every
        // real extraction is untouched. A non-finite onset is refused too.
        let slotCeiling = 9_007_199_254_740_992.0   // 2^53
        if let far = measured.first(where: { !(($0 / gridBeats).magnitude < slotCeiling) }) {
            throw ProjectError.invalidClipEdit(
                "cannot extract a groove: an onset \(far) beats into the clip is too far out to measure on a "
                + "\(gridBeats)-beat grid (at most 2^53 grid slots = \(slotCeiling * gridBeats) beats from the clip's start)")
        }
        let clipCounted = GrooveTemplate.extract(
            fromOnsetBeats: measured, gridBeats: gridBeats, cycleBeats: cycleBeats, name: name)
        let template = Self.relabelledFromSongStart(
            clipCounted, firstLine: SongGridPhase.firstLineIndex(of: clipStart, step: gridBeats))
        performEdit("Extract Groove") {
            grooveTemplates.append(template)
        }
        return template
    }

    /// Relabels a groove measured with slot 0 at a clip's first grid line so its
    /// slots count from the SONG's beat 0 (m23-ap I5-F4): entry `j` moves to
    /// `(firstLine + j) mod count`, `firstLine` being that line's song slot
    /// (`SongGridPhase.firstLineIndex`). A whole number of cycles returns the
    /// template untouched, bit for bit. The fold is taken in `Double`, so a
    /// huge `firstLine` (a degenerate grid) cannot trap an `Int` conversion; a
    /// non-finite one reads as 0.
    nonisolated static func relabelledFromSongStart(_ template: GrooveTemplate,
                                                    firstLine: Double) -> GrooveTemplate {
        let count = template.offsets.count
        guard count > 1, firstLine.isFinite else { return template }
        var fold = firstLine.truncatingRemainder(dividingBy: Double(count))
        if fold < 0 { fold += Double(count) }
        let rotation = Int(fold)
        guard rotation != 0 else { return template }
        var relabelled = template.offsets
        for (j, offset) in template.offsets.enumerated() {
            relabelled[(j + rotation) % count] = offset
        }
        return GrooveTemplate(id: template.id, name: template.name,
                              gridBeats: template.gridBeats, cycleBeats: template.cycleBeats,
                              offsets: relabelled)
    }

    /// Removes a stored groove template by id. Built-in swings aren't stored, so
    /// they're never removable (nor do they dangle — grooves apply BY VALUE).
    /// Unknown id → `grooveNotFound`. Removes inside `performEdit("Remove Groove")`
    /// so undo restores it. A `QuantizeSettings.groove` already captured on a past
    /// edit keeps working — the template travels by value.
    public func removeGrooveTemplate(id: UUID) throws {
        guard grooveTemplates.contains(where: { $0.id == id }) else {
            throw ProjectError.grooveNotFound(id)
        }
        performEdit("Remove Groove") {
            grooveTemplates.removeAll { $0.id == id }
        }
    }

    /// Resolves a groove reference string to a template (M5 iii-g, spec §6). A
    /// reserved BUILT-IN name (`"swing8:66"` etc.) wins first (so a built-in
    /// always beats a project template that happens to share the name), then a
    /// stored template by id-string, then by name. Returns nil for an unknown
    /// ref — the command layer turns that into a field-named error.
    public func resolveGroove(_ ref: String) -> GrooveTemplate? {
        if let builtin = GrooveTemplate.builtin(named: ref) { return builtin }
        if let uuid = UUID(uuidString: ref),
           let byID = grooveTemplates.first(where: { $0.id == uuid }) {
            return byID
        }
        return grooveTemplates.first(where: { $0.name == ref })
    }

    /// Locates a clip by BOTH its track and its id (extension-local; the private
    /// `locateClip(trackID:clipID:)` in ProjectStore.swift is not visible
    /// cross-file). Throws `trackNotFound`/`clipNotFound`.
    private func locateClip(trackId: UUID, clipId: UUID) throws -> (t: Int, c: Int) {
        guard let t = tracks.firstIndex(where: { $0.id == trackId }) else {
            throw ProjectError.trackNotFound(trackId)
        }
        guard let c = tracks[t].clips.firstIndex(where: { $0.id == clipId }) else {
            throw ProjectError.clipNotFound(clipId)
        }
        return (t, c)
    }

    /// Locates a clip by id across every track (extension-local; the private
    /// `locateClip(_:)` in ProjectStore.swift is not visible cross-file).
    private func locateClipIndex(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
