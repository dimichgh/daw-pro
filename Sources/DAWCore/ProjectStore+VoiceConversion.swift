import Foundation

/// Voice-conversion → project import pipeline (m10-p-4). Turns a finished
/// RVC voice conversion (`vc.convertVocals`, `scripts/rvc/README.md`'s v1
/// `POST /v1/voice/convert`) into project material: a new AI-flagged audio
/// track + clip, in ONE `performEdit("Import Converted Voice")` — mirrors
/// `importGeneration` (M6 iii-a, `ProjectStore+Generation.swift`) mechanics
/// exactly EXCEPT for two settled differences (m10-p-4 design):
///
/// 1. **No job polling.** `vc.convertVocals` is a BLOCKING command (the
///    facade's convert endpoint is synchronous, unlike ACE-Step's async job
///    queue) — `CommandRouter` already awaited the finished
///    `VoiceConversionClient.convert(_:)` call before it ever reaches this
///    method, so there is no `generationSource`/jobID hop here at all; the
///    caller just hands over the already-finished local output file.
/// 2. **No tempo adoption.** A converted vocal take never carries a bpm meta
///    (the facade's `/v1/voice/convert` response has no such field) — that
///    whole concern is omitted rather than faked with a bogus default.
///
/// DAWCore stays AI-free: this file never imports AIServices — it only ever
/// receives a plain local file URL that `CommandRouter` (DAWControl) already
/// resolved via the (AIServices) conversion client.
@MainActor
extension ProjectStore {
    /// Imports a finished voice-conversion output file as a new audio track +
    /// clip — the shared landing primitive for BOTH the `clipId`- and
    /// `path`-sourced forms of `vc.convertVocals` (the source only matters
    /// for what got fed INTO the conversion; landing the result is identical
    /// either way).
    ///
    /// - Parameters:
    ///   - fileURL: the converted audio file on disk (the facade's own
    ///     `outputPath`) — must exist.
    ///   - trackName: the new track's name. The caller resolves the default
    ///     (e.g. `"Voice: <voiceId>"`) — this method never invents one, so an
    ///     empty string lands verbatim rather than being silently replaced.
    ///   - atBeat: where the clip lands. The caller resolves the default
    ///     (the source clip's own start beat when `clipId` was given, else
    ///     0) — this method only clamps to >= 0, the same floor
    ///     `importGeneration`/`importAudio` apply.
    /// - Returns: the new track id and clip id.
    @discardableResult
    public func importConvertedVoice(
        fileURL: URL,
        trackName: String,
        atBeat: Double
    ) throws -> (trackID: UUID, clipID: UUID) {
        guard let media else { throw ProjectError.mediaServiceUnavailable }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ProjectError.generationAudioMissing(fileURL.path)
        }

        // Copy into the SAME stable, project-adjacent home importGeneration
        // uses (the recording-take model: the file must outlive the facade's
        // own runtime/temp output and undo/redo resurrection so a later save
        // can fold it into the bundle's media/) — a converted take is exactly
        // as durable as a generated one. A fresh UUID keys the copy (unlike
        // importGeneration's jobId key) since a blocking convert call has no
        // job id to key on; re-running the same conversion simply produces a
        // second distinct copy, which is correct (it may be a retake).
        let stableURL = try copyGeneratedAudioToStableLocation(
            from: fileURL, jobID: "voice-\(UUID().uuidString)")

        // Authoritative on-disk duration (like importGeneration/importAudio),
        // not any duration the facade might have echoed.
        let info = try media.audioFileInfo(at: stableURL)
        let startBeat = max(0, atBeat)
        let lengthBeats = transport.tempoMap.beat(
            from: startBeat, elapsedSeconds: info.durationSeconds) - startBeat

        // The track AND its clip are flagged AI-generated (violet in the UI —
        // "violet always means AI-generated", DESIGN-LANGUAGE.md) — a voice
        // conversion is exactly as AI-authored as a generation.
        let clip = Clip(
            name: trackName,
            startBeat: startBeat,
            lengthBeats: lengthBeats,
            audioFileURL: stableURL,
            isAIGenerated: true
        )
        var newTrack = Track(name: trackName, kind: .audio)
        newTrack.isAIGenerated = true
        newTrack.clips = [clip]
        let trackID = newTrack.id
        let clipID = clip.id

        performEdit("Import Converted Voice") {
            tracks.append(newTrack)
            engine?.tracksDidChange(tracks)
        }
        return (trackID, clipID)
    }

    // MARK: - Source resolution (clipId form)

    /// Resolves `vc.convertVocals`'s `clipId` param to a source audio file +
    /// default placement beat, for `CommandRouter` to call BEFORE it ever
    /// touches the (AIServices) conversion client — DAWCore itself must never
    /// import AIServices, so this stays a pure read with no knowledge of the
    /// convert call that follows.
    ///
    /// Searches every track (clip ids are unique project-wide, the
    /// `locateClip(_:)` precedent in `ProjectStore.swift`) rather than
    /// requiring a track id — `vc.convertVocals` takes only `clipId`, unlike
    /// the two-key `trackId`+`clipId` shape `ai.fixClipRegion` uses.
    ///
    /// ⚠️⚠️ **NOT THE CONVERSION SEAM ANY MORE (m24-o).** This hands back the
    /// clip's FULL BACKING RECORDING: trims, `startOffsetSeconds` and
    /// `stretchRatio` are NOT applied. That was fine for the flow it was built
    /// for — a freshly imported full-length stem — and silently WRONG for the
    /// flow the user described: comped, trimmed clips, several per track,
    /// converting to the untrimmed takes landed at the clip start beats. The
    /// user's 2026-08-13 ruling reclassified it from a documented limitation
    /// to a **defect**, and the fix is
    /// `extractClipAudioForConversion(clipId:)` — an offline render of that
    /// ONE clip over its own window. Every path that feeds a converter uses
    /// that one now: `vc.convertVocals`' clipId form, `vc.convertClips`, and
    /// `VoicePanelModel.convertClip`.
    ///
    /// What is left here is the one job the full recording IS right for:
    /// resolving a clip to a FILE TO COPY. `VoicePanelModel.addClipAsSample`
    /// puts that file in a training dataset, where the backing take — not a
    /// rendered excerpt — is the natural material. Kept (not deleted) for that
    /// caller and because the wire never renames or removes live behaviour.
    /// ⭐ If you are adding a new CONVERSION caller, you want the other one.
    ///
    /// - Throws: `clipNotFound` if no track holds `clipId`;
    ///   `voiceConversionRequiresAudioClip` if the clip is a MIDI clip (or,
    ///   structurally unreachable via any current mutation, an audio clip
    ///   with no backing file).
    public func voiceConversionSource(clipId: UUID) throws -> (url: URL, startBeat: Double) {
        for track in tracks {
            guard let clip = track.clips.first(where: { $0.id == clipId }) else { continue }
            guard !clip.isMIDI, let audioFileURL = clip.audioFileURL else {
                throw ProjectError.voiceConversionRequiresAudioClip(clipId)
            }
            return (audioFileURL, clip.startBeat)
        }
        throw ProjectError.clipNotFound(clipId)
    }
}
