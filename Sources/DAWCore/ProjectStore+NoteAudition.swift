import Foundation

// I1: HEAR THE NOTE WHILE EDITING IT. THE STORE'S DOORS.
//
// Design: `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §4. The
// policy lives in `ClipNoteAuditionController` (`ClipNoteAudition.swift`); the
// mechanism in `AudioEngineControlling.auditionClipSpan`. This file turns a
// clip id and note ids into the SOURCE-second span that plays, from the
// clip's STORED note table, so no editor pane has to be open (the wire's door
// and an agent have none).
//
// Own extension file, the `+PitchNoteEdits` precedent: the per-note writers
// live there, and another lane is editing that file.

/// One `auditionClipNotes` answer: what was asked for, what played, and why
/// not when nothing did.
public struct ClipNoteAuditionResult: Sendable, Equatable {

    /// Which file the audition reads: the clip's RENDER (a tuned, stretched or
    /// transposed clip, so the edits are heard) or its SOURCE file (a clip that
    /// plays its source as-is).
    public enum Source: String, Sendable, Equatable {
        case render
        case source
        /// I1-F1: a span of the clip rendered for this audition alone, through
        /// the render loop playback's render uses (the stored or a draft set of
        /// edits), without waiting for the whole recording to re-render.
        case spanRender = "span-render"
    }

    /// Why nothing will be heard. Stable machine tags (kebab-case) an agent can
    /// branch on, never sentences. Additive only, never renamed.
    public enum Reason: String, Sendable, Equatable {
        /// The transport is running or recording. Stop it and ask again.
        case transportRunning = "transport-running"
        /// The clip's render is still in flight. Ask again in a moment.
        case stillRendering = "still-rendering"
        /// A commit's audition is waiting for its render and plays once it
        /// lands (the editor's release door, never the wire's).
        case waitingForRender = "waiting-for-render"
        /// The track is muted, or an active solo leaves it out.
        case trackMuted = "track-muted"
        /// The audio engine is not running and would not start.
        case engineStopped = "engine-stopped"
        /// Nothing to play: the clip left the engine (a mid-rebuild gap) or
        /// has no audio.
        case noAudio = "no-audio"
        /// This engine cannot audition a clip (headless, or a test fake).
        case unsupported
        /// The caller's audition switch is off.
        case auditionOff = "audition-off"
        /// The commit does not change the sound (a split), so nothing plays.
        case unchanged
        /// I1-F1: a free (⌥) drag step is waiting behind the render in flight
        /// and plays as soon as that one finishes, unless a newer step
        /// replaces it first.
        case previewQueued = "preview-queued"
    }

    /// The engine's answer, or nil when the request was refused before it
    /// reached the engine (see `reason`).
    public var outcome: AuditionOutcome?
    /// The SOURCE-second span that plays (or would have played).
    public var startSeconds: Double
    public var endSeconds: Double
    public var source: Source
    /// Why nothing will be heard; nil when `outcome == .sounded`.
    public var reason: Reason?

    public var isAudible: Bool { outcome == .sounded }

    public init(outcome: AuditionOutcome?, startSeconds: Double, endSeconds: Double,
                source: Source, reason: Reason?) {
        self.outcome = outcome
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.source = source
        self.reason = reason
    }
}

@MainActor
extension ProjectStore {

    /// Plays `segmentIds` of `clipId` ONCE, as they sound NOW, with
    /// `contextSeconds` of audio either side (default: the 60 ms pick). The
    /// press half of I1, and the one home the wire's audition verb will call.
    ///
    /// Resolves from the clip's STORED note table: no editor pane is needed.
    /// The span is the notes ± context, clipped to what the clip plays and
    /// capped at 6 s (`ClipNoteAuditionPolicy.span`).
    ///
    /// `enabled` is the CALLER's audition switch, the release and drag doors'
    /// input: the pitch editor passes `panelLayout.auditionEnabled` (off →
    /// `reason: audition-off`, nothing reaches the engine). The wire passes
    /// nothing, so it reads true: `clip.auditionNote` ignores the app's switch
    /// (design §4) — an agent asking to hear a note is an explicit request.
    ///
    /// `seedIfAbsent` (m23-ap I1 UI hooks) is the editor's own note table for a
    /// clip that has never been edited, so a press on a note of an untouched
    /// take plays it instead of refusing "no notes to hear yet". ⭐ The stored
    /// table wins unconditionally, the `+PitchNoteEdits` rule; the seed is read
    /// only for the note bounds, and never stored.
    ///
    /// Refuses, without throwing, while the transport runs or records
    /// (`reason: transport-running`). Throws for a caller mistake: an unknown
    /// clip, a MIDI clip, a clip with no stored notes (and no seed), no note
    /// ids, an unknown note id, or a context outside
    /// `ClipNoteAuditionPolicy.contextSecondsRange`.
    @discardableResult
    public func auditionClipNotes(clipId: UUID, segmentIds: [UUID],
                                  contextSeconds: Double = ClipNoteAuditionPolicy.contextSeconds,
                                  enabled: Bool = true,
                                  seedIfAbsent: PitchEditSet? = nil)
        throws -> ClipNoteAuditionResult {
        let (clip, span) = try resolveNoteAuditionSpan(
            clipId: clipId, segmentIds: segmentIds, contextSeconds: contextSeconds,
            seedIfAbsent: seedIfAbsent)
        let status = clipNoteAudition.press(
            span, enabled: enabled, transportRunning: isTransportRunningForAudition,
            engine: engine)
        return Self.noteAuditionResult(status, span: span, clip: clip)
    }

    /// The RELEASE half of I1: call it after a note edit has been committed
    /// (the store method returned). If `edit` changed the sound, the edited
    /// notes play once, as soon as THAT clip's render lands (at once when it
    /// is already on disk). A split plays nothing. `enabled` is the app's
    /// audition switch; the latest request wins; a wait over 8 s is dropped.
    /// `contextSeconds` nil means the edit kind's own context (0.3 s for a
    /// clear, 60 ms otherwise).
    @discardableResult
    public func auditionClipNotesAfterEdit(_ edit: ClipNoteEdit, clipId: UUID,
                                           segmentIds: [UUID], enabled: Bool,
                                           contextSeconds: Double? = nil)
        throws -> ClipNoteAuditionResult {
        let (clip, span) = try resolveNoteAuditionSpan(
            clipId: clipId, segmentIds: segmentIds,
            contextSeconds: contextSeconds ?? edit.contextSeconds)
        let status = clipNoteAudition.commitDidChange(
            edit, span: span, enabled: enabled,
            transportRunning: isTransportRunningForAudition, engine: engine)
        return Self.noteAuditionResult(status, span: span, clip: clip)
    }

    /// I1-F1: HEAR A PITCH DRAG WHILE IT IS STILL IN FLIGHT. Plays the named
    /// notes as they WOULD sound with `offsets` written (absolute cents, the
    /// numbers `setClipNotePitchOffsets` would commit), WITHOUT writing them:
    /// the engine renders just their span (± `contextSeconds`, capped at 6 s)
    /// with the draft in place of the stored edits, off-thread, and plays it.
    ///
    /// Call it when the drag's offset CHANGED. `snapped` is false while ⌥
    /// frees the drag from the semitone grid; snapped steps are latest-wins,
    /// free steps keep one render in flight plus the newest one waiting
    /// (`reason: preview-queued`). `enabled` is the app's audition switch.
    /// The release still goes through the commit, then
    /// `auditionClipNotesAfterEdit(.pitch, …)`, which plays the committed span.
    ///
    /// The draft is built by the commit's own rule
    /// (`PitchEditSet.applyingNotePitchOffsets`): the same ±2400 c clamp, the
    /// same fold of a repeated id and the same refusals, checked in the
    /// commit's order: an unknown clip, a take-group comp member, a MIDI
    /// clip, an empty list, no stored notes and no `seedIfAbsent`, a repeated
    /// note with two pitches, an unknown note. Then the audition's own: a clip
    /// with no audio file, a context outside
    /// `ClipNoteAuditionPolicy.contextSecondsRange`, notes wholly outside what
    /// the clip plays. Refuses without throwing while the transport runs or
    /// records.
    ///
    /// TODO(mcp-integration-engineer, after m23-ap I1 UI hooks): this door is
    /// the pitch editor's drag audition and has no wire twin yet. Proposed
    /// verb `clip.previewNotePitches {clipId, notes: [{segmentId, cents}],
    /// snapped?, contextSeconds?}` in `Sources/DAWControl/Commands.swift`
    /// (the `clip.setNotePitches` shape: hear the offsets without storing
    /// them) and MCP tool `clip_preview_note_pitches`. Its `audible` means
    /// ACCEPTED, as `clip_audition_note`'s does. Stopping needs no new verb:
    /// `transport.stop` now stops a note audition even with the transport
    /// stopped, and `transport.panic` always did.
    @discardableResult
    public func previewClipNotePitchDraft(clipId: UUID, offsets: [NotePitchOffset],
                                          snapped: Bool, enabled: Bool,
                                          seedIfAbsent: PitchEditSet? = nil,
                                          contextSeconds: Double = ClipNoteAuditionPolicy.contextSeconds)
        throws -> ClipNoteAuditionResult {
        // The commit's gates, in the commit's order (`setClipNotePitchOffsets`).
        guard let (t, c) = locateClipIndexForNoteAudition(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        let track = tracks[t]
        let clip = track.clips[c]
        guard !clip.isMIDI else { throw ProjectError.pitchDetectionRequiresAudioClip(clipId) }
        guard !offsets.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "Name at least one note to tune. Read the clip's note ids with "
                    + "`clip.getPitchEdits` first.")
        }
        let table: PitchEditSet
        if let stored = clip.pitchEdits {
            table = stored
        } else if let seed = seedIfAbsent, !seed.isEmpty {
            table = seed
        } else {
            throw ProjectError.invalidClipEdit(
                "This clip has no notes to edit yet. Run pitch detection on it first — "
                    + "`clip.autoCorrectPitch` stores the note table, and opening the note "
                    + "editor on the clip builds one from what it hears.")
        }
        let draft = try table.applyingNotePitchOffsets(offsets, clipId: clipId)
        // The audition's own gates, then the span of every moving note.
        guard clip.audioFileURL != nil else {
            throw ProjectError.invalidAudition(
                "clip \(clipId.uuidString) has no audio file to hear.")
        }
        try validateNoteAuditionContext(contextSeconds)
        var seen = Set<UUID>()
        let moving = offsets.compactMap { offset -> NoteSegment? in
            guard seen.insert(offset.segmentId).inserted else { return nil }
            return draft.segments.first { $0.id == offset.segmentId }
        }
        let span = try noteAuditionSpan(of: moving, track: track, clip: clip,
                                        contextSeconds: contextSeconds)
        let status = clipNoteAudition.dragDidStep(
            span, draft: draft, snapped: snapped, enabled: enabled,
            transportRunning: isTransportRunningForAudition, engine: engine)
        return Self.noteAuditionResult(status, span: span, clip: clip)
    }

    /// Stops a sounding note audition, drops one waiting for its render or
    /// behind a span render, and cancels a span render in flight.
    ///
    /// The pitch editor's stop doors call it (m23-ap I1 UI hooks, the RT
    /// review's H5: a slowed clip played up to 6 SOURCE seconds, stretched;
    /// since I1-F2 an audition plays at most 6 HEARD seconds, still long
    /// enough to want a stop):
    /// Escape, the pane going away (closed, or switched to another clip), the
    /// audition switch turned off; and `stop()`, the transport's Stop, even
    /// with the transport already stopped.
    public func stopClipNoteAudition() {
        clipNoteAudition.stop(engine: engine)
    }

    /// The serial of the newest release that WAITED for its clip's render
    /// (`ClipNoteAuditionController.waitSerial`). Keep it with the answer that
    /// said `waiting-for-render`, then ask `clipNoteAuditionWaitState`.
    public var clipNoteAuditionWaitSerial: UInt64 { clipNoteAudition.waitSerial }

    /// How the release wait numbered `serial` stands: still waiting, played,
    /// expired (nothing will play — say so), or cancelled. Notices an expiry
    /// on read. "Honest waiting" (m23-ap I1 UI hooks).
    public func clipNoteAuditionWaitState(serial: UInt64) -> ClipNoteAuditionWaitState {
        clipNoteAudition.waitState(of: serial)
    }

    /// The engine's render-complete sink, installed with the engine.
    func clipRenderDidComplete(clipID: UUID) {
        clipNoteAudition.renderDidComplete(clipID: clipID,
                                           transportRunning: isTransportRunningForAudition,
                                           engine: engine)
    }

    // MARK: - Resolution

    private var isTransportRunningForAudition: Bool {
        transport.isPlaying || transport.isRecording
    }

    /// The clip, its track, and the span its named notes play, from the STORED
    /// table (or, for a clip with none, the caller's non-empty seed: the
    /// `noteTable` rule of `+PitchNoteEdits`, the stored table winning).
    /// All-or-nothing: every id is resolved before anything plays.
    private func resolveNoteAuditionSpan(clipId: UUID, segmentIds: [UUID],
                                         contextSeconds: Double,
                                         seedIfAbsent: PitchEditSet? = nil)
        throws -> (Clip, ClipNoteAuditionSpan) {
        guard let (t, c) = locateClipIndexForNoteAudition(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let track = tracks[t]
        let clip = track.clips[c]
        guard !clip.isMIDI, clip.audioFileURL != nil else {
            throw ProjectError.invalidAudition(
                "clip \(clipId.uuidString) is a MIDI clip. Hearing a note from its recording "
                    + "applies only to audio clips; MIDI notes play through `note.audition`.")
        }
        try validateNoteAuditionContext(contextSeconds)
        guard !segmentIds.isEmpty else {
            throw ProjectError.invalidAudition(
                "Name at least one note to hear. Read the clip's note ids with "
                    + "`clip.getPitchEdits` first.")
        }
        let seed = seedIfAbsent.flatMap { $0.isEmpty ? nil : $0 }
        guard let table = clip.pitchEdits ?? seed, !table.segments.isEmpty else {
            throw ProjectError.invalidAudition(
                "This clip has no notes to hear yet. Run pitch detection on it first: "
                    + "`clip.autoCorrectPitch` stores the note table, and opening the note "
                    + "editor on the clip builds one from what it hears.")
        }
        var notes: [NoteSegment] = []
        var seen = Set<UUID>()
        for id in segmentIds where seen.insert(id).inserted {
            guard let note = table.segments.first(where: { $0.id == id }) else {
                throw ProjectError.invalidAudition(
                    "No note with id \(id) on clip \(clipId). That clip carries "
                        + "\(table.segments.count) note(s); read them back with "
                        + "`clip.getPitchEdits`.")
            }
            notes.append(note)
        }
        return (clip, try noteAuditionSpan(of: notes, track: track, clip: clip,
                                           contextSeconds: contextSeconds))
    }

    private func validateNoteAuditionContext(_ contextSeconds: Double) throws {
        guard contextSeconds.isFinite,
              ClipNoteAuditionPolicy.contextSecondsRange.contains(contextSeconds) else {
            throw ProjectError.invalidAudition(
                "contextSeconds must be \(ClipNoteAuditionPolicy.contextSecondsRange.lowerBound)…"
                    + "\(ClipNoteAuditionPolicy.contextSecondsRange.upperBound) s, got \(contextSeconds)")
        }
    }

    /// The span `notes` play: ± `contextSeconds`, clipped to what the clip
    /// plays of its source (from its offset, for as long as its timeline
    /// window lasts at its stretch, `sourceWindowSeconds`), capped so that
    /// what is HEARD lasts at most 6 s (I1-F2): the source span that covers at
    /// the clip's ratio is the ENGINE's answer, from its one output↔source
    /// mapping, the same answer its own plan uses, so the span reported here
    /// is the span that plays. An engine without the mapping (or none) leaves
    /// the cap at 6 source seconds, as before.
    private func noteAuditionSpan(of notes: [NoteSegment], track: Track, clip: Clip,
                                  contextSeconds: Double) throws -> ClipNoteAuditionSpan {
        let windowStart = clip.startOffsetSeconds
        let window = windowStart...(windowStart
            + clip.sourceWindowSeconds(tempoMap: transport.tempoMap))
        let maxSource = engine?.clipAuditionSourceSeconds(
            heardSeconds: ClipNoteAuditionPolicy.maxSpanSeconds, ratio: clip.stretchRatio)
            ?? ClipNoteAuditionPolicy.maxSpanSeconds
        guard let span = ClipNoteAuditionPolicy.span(of: notes, contextSeconds: contextSeconds,
                                                     within: window,
                                                     maxSourceSeconds: maxSource) else {
            throw ProjectError.invalidAudition(
                "Those notes lie outside the part of the recording this clip plays, "
                    + "so there is nothing to hear. Lengthen the clip to reach them.")
        }
        return ClipNoteAuditionSpan(trackID: track.id, clipID: clip.id,
                                    startSeconds: span.lowerBound, endSeconds: span.upperBound)
    }

    private static func noteAuditionResult(_ status: ClipNoteAuditionStatus,
                                           span: ClipNoteAuditionSpan,
                                           clip: Clip) -> ClipNoteAuditionResult {
        var source: ClipNoteAuditionResult.Source =
            clip.rendersThroughStretchCache ? .render : .source
        let outcome: AuditionOutcome?
        let reason: ClipNoteAuditionResult.Reason?
        func why(_ answer: AuditionOutcome) -> ClipNoteAuditionResult.Reason? {
            switch answer {
            case .sounded: return nil
            case .inaudibleNotReady: return .stillRendering
            case .inaudibleMuted: return .trackMuted
            case .inaudibleEngineStopped: return .engineStopped
            case .noRenderer: return .noAudio
            case .unsupported: return .unsupported
            }
        }
        switch status {
        case .attempted(let answer):
            outcome = answer
            reason = why(answer)
        case .spanRender(let answer):
            outcome = answer
            reason = why(answer)
            source = .spanRender
        case .queued:
            outcome = nil
            reason = .previewQueued
            source = .spanRender
        case .waitingForRender:
            outcome = .inaudibleNotReady
            reason = .waitingForRender
        case .refusedTransportRunning:
            outcome = nil
            reason = .transportRunning
        case .disabled:
            outcome = nil
            reason = .auditionOff
        case .unchanged:
            outcome = nil
            reason = .unchanged
        }
        return ClipNoteAuditionResult(outcome: outcome, startSeconds: span.startSeconds,
                                      endSeconds: span.endSeconds, source: source, reason: reason)
    }

    /// Extension-local clip lookup, the repo-wide convention (each `+` file
    /// keeps its own twin, because `ProjectStore`'s private `locateClip(_:)`
    /// is not visible cross-file).
    private func locateClipIndexForNoteAudition(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
