import Foundation

/// Generation → project import pipeline (M6 iii-a). Turns a finished ACE-Step
/// generation into project material: a new AI-flagged audio track + clip, with
/// optional project-tempo adoption from the generation's `metas.bpm` — all in
/// ONE `performEdit("Import Generation")`, so a single undo removes the track
/// AND restores any tempo change.
@MainActor
extension ProjectStore {
    /// Imports a finished generation job as a new audio track + clip.
    ///
    /// - Parameters:
    ///   - jobID: the generation jobId (from `ai.generateSong`). The job must
    ///     have reached `succeeded` with a local audio path; a still-running or
    ///     unknown/expired job throws an actionable error.
    ///   - trackName: the new track's name. Defaults to `"AI: <first words of
    ///     the prompt>"` (or `"AI: Generated"` when no prompt is available).
    ///   - atBeat: where the clip lands (default 0, clamped to ≥ 0).
    ///   - setProjectTempo: tempo-adoption control. `nil` (default) adopts the
    ///     generation's `metas.bpm` ONLY when the project currently has no other
    ///     clips (so the first imported track sets the grid, but a later import
    ///     never silently moves everything). `true` forces adoption; `false`
    ///     forbids it. Adoption also requires `metas.bpm` to be present.
    /// - Returns: the new track id, the new clip id, and the tempo actually
    ///   adopted (nil when tempo was left unchanged).
    @discardableResult
    public func importGeneration(
        jobID: String,
        trackName: String? = nil,
        atBeat: Double? = nil,
        setProjectTempo: Bool? = nil
    ) async throws -> (trackID: UUID, clipID: UUID, adoptedTempoBPM: Double?) {
        guard let generationSource else { throw ProjectError.generationSourceUnavailable }
        guard let media else { throw ProjectError.mediaServiceUnavailable }

        // 1. Poll the job. An unknown/expired/failed job throws here (the
        //    provider's own jobNotFound/jobFailed message, surfaced verbatim).
        let result = try await generationSource.fetchGeneration(jobID: jobID)

        // 2. Must be a finished job with a local file to import.
        guard let audioPath = result.audioPath, !audioPath.isEmpty else {
            throw ProjectError.generationNotReady(jobID: jobID, state: result.state)
        }
        let sourceURL = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ProjectError.generationAudioMissing(audioPath)
        }

        // 3. Copy the volatile cache file into a stable, project-adjacent home
        //    (the recording-take model: the file must outlive the temp cache
        //    and undo/redo resurrection so a later save can fold it into the
        //    bundle's media/).
        let stableURL = try copyGeneratedAudioToStableLocation(from: sourceURL, jobID: jobID)

        // 4. Read the authoritative on-disk duration (like importAudio /
        //    recording finalize) — not metas.duration, which is only the
        //    requested/approximate length.
        let info = try media.audioFileInfo(at: stableURL)

        // 5. Tempo adoption decision.
        let projectHasClips = tracks.contains { !$0.clips.isEmpty }
        let wantsTempo = setProjectTempo ?? !projectHasClips
        let adoptedBPM: Double? = (wantsTempo ? result.bpm : nil)
            .map { $0.clamped(to: TransportState.tempoRange) }

        // 6. Clip length in beats is measured at the FINAL tempo (adopted or
        //    current) so the clip's beat span matches how it will play.
        let finalTempo = adoptedBPM ?? transport.tempoBPM
        let lengthBeats = info.durationSeconds * finalTempo / 60.0

        let resolvedName = trackName?.isEmpty == false
            ? trackName!
            : Self.defaultGenerationTrackName(prompt: result.prompt)
        let startBeat = max(0, atBeat ?? 0)

        // The track AND its clip are flagged AI-generated (violet in the UI —
        // "violet always means AI-generated", DESIGN-LANGUAGE.md).
        let clip = Clip(
            name: resolvedName,
            startBeat: startBeat,
            lengthBeats: lengthBeats,
            audioFileURL: stableURL,
            isAIGenerated: true
        )
        var newTrack = Track(name: resolvedName, kind: .audio)
        newTrack.isAIGenerated = true
        newTrack.clips = [clip]
        let trackID = newTrack.id
        let clipID = clip.id

        performEdit("Import Generation") {
            // Tempo adoption folds into this SAME edit, so one undo restores
            // the previous tempo together with removing the track.
            if let adoptedBPM {
                applyTempoChange(adoptedBPM)
            }
            tracks.append(newTrack)
            engine?.tracksDidChange(tracks)
        }
        return (trackID, clipID, adoptedBPM)
    }

    /// Copies a finished generation's audio into `generationImportsDirectory`
    /// under a jobId-derived name. Re-importing the same job reuses the already
    /// copied file (its bytes are identical) rather than duplicating it.
    /// Internal (not private): M6 v-b `importClipFix` reuses it with a
    /// `"fix-<jobId>"` key to stage the repainted WAV.
    func copyGeneratedAudioToStableLocation(from sourceURL: URL, jobID: String) throws -> URL {
        let dir = generationImportsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let safeJob = jobID.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let destination = dir
            .appendingPathComponent("gen-\(String(safeJob))")
            .appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        }
        return destination
    }

    /// Default AI-track name: `"AI: <first words of the prompt>"`, or a plain
    /// `"AI: Generated"` when no prompt is available. Trimmed to the first few
    /// words so the name stays readable in the track header.
    static func defaultGenerationTrackName(prompt: String?) -> String {
        guard let prompt else { return "AI: Generated" }
        let words = prompt
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "," })
            .prefix(4)
            .joined(separator: " ")
        return words.isEmpty ? "AI: Generated" : "AI: \(words)"
    }

    // MARK: - Multi-track import (M6 iii-c: stems / Lego)

    /// Imports a finished stems-extraction or Lego composite job as N new
    /// audio tracks + clips — one per named result. Mirrors `importGeneration`
    /// (M6 iii-a) exactly, just fanned out over `GeneratedStemsResult.stems`:
    /// every stem's audio is copied into `generationImportsDirectory` FIRST
    /// (all-or-nothing — if any one file is missing, the whole import throws
    /// before any track is added, so a partial stems set never lands), then
    /// every track + clip is appended in ONE `performEdit("Import Generated
    /// Stems")` alongside any tempo adoption, so a SINGLE undo removes every
    /// track (and restores the tempo) together.
    ///
    /// - Parameters:
    ///   - jobID: the composite jobId returned by `ai.extractStems` /
    ///     `ai.legoGenerate`. The job must have every underlying track
    ///     `succeeded`; a still-running or unknown/expired job throws an
    ///     actionable error exactly like `importGeneration`.
    ///   - atBeat: where every clip lands (default 0, clamped to ≥ 0) — all
    ///     stems share the same start, since they're meant to play together.
    ///   - setProjectTempo: same tempo-adoption control as `importGeneration`.
    ///     ASSUMPTION: upstream's per-track `metas.bpm` can, in principle, be
    ///     supplied for ANY task type (the sidecar's `query_result` payload
    ///     shape doesn't special-case it) but is not verified live for
    ///     extract/lego specifically (weights-complete real-gate is a
    ///     separate roadmap item) — when present, the FIRST track's bpm
    ///     (in submission order) is the adoption candidate, same "empty
    ///     project only" default rule as `importGeneration`.
    /// - Returns: one `(trackID, clipID, trackName)` per imported stem (in
    ///   submission order) plus the tempo actually adopted (nil when
    ///   unchanged).
    @discardableResult
    public func importGeneratedStems(
        jobID: String,
        atBeat: Double? = nil,
        setProjectTempo: Bool? = nil
    ) async throws -> (tracks: [(trackID: UUID, clipID: UUID, trackName: String)], adoptedTempoBPM: Double?) {
        guard let generationSource else { throw ProjectError.generationSourceUnavailable }
        guard let media else { throw ProjectError.mediaServiceUnavailable }

        // 1. Poll the job. An unknown/expired/failed job throws here (the
        //    provider's own jobNotFound/jobFailed message, surfaced verbatim).
        let result = try await generationSource.fetchGenerationStems(jobID: jobID)

        // 2. Must be a finished job with at least one named result.
        guard !result.stems.isEmpty else {
            throw ProjectError.generationNotReady(jobID: jobID, state: result.state)
        }

        // 3. Copy EVERY stem's audio into a stable, project-adjacent home
        //    BEFORE building any track — all-or-nothing, so a missing file
        //    for stem 3 of 4 never leaves stems 1-2 half-imported.
        struct StagedStem {
            var trackName: String
            var stableURL: URL
            var durationSeconds: Double
            var bpm: Double?
        }
        var staged: [StagedStem] = []
        staged.reserveCapacity(result.stems.count)
        for stem in result.stems {
            let sourceURL = URL(fileURLWithPath: stem.audioPath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw ProjectError.generationAudioMissing(stem.audioPath)
            }
            let stableURL = try copyGeneratedAudioToStableLocation(
                from: sourceURL, jobID: "\(jobID)-\(stem.trackName)")
            let info = try media.audioFileInfo(at: stableURL)
            staged.append(StagedStem(
                trackName: stem.trackName, stableURL: stableURL,
                durationSeconds: info.durationSeconds, bpm: stem.bpm))
        }

        // 4. Tempo adoption decision — same rule as importGeneration, using
        //    the first track (in submission order) that reports a bpm.
        let projectHasClips = tracks.contains { !$0.clips.isEmpty }
        let wantsTempo = setProjectTempo ?? !projectHasClips
        let candidateBPM = staged.first(where: { $0.bpm != nil })?.bpm
        let adoptedBPM: Double? = (wantsTempo ? candidateBPM : nil)
            .map { $0.clamped(to: TransportState.tempoRange) }

        // 5. Every clip's length in beats is measured at the FINAL tempo
        //    (adopted or current), same as importGeneration.
        let finalTempo = adoptedBPM ?? transport.tempoBPM
        let startBeat = max(0, atBeat ?? 0)

        var newTracks: [Track] = []
        var newTrackClipNames: [(trackID: UUID, clipID: UUID, trackName: String)] = []
        newTracks.reserveCapacity(staged.count)
        newTrackClipNames.reserveCapacity(staged.count)
        for stem in staged {
            let lengthBeats = stem.durationSeconds * finalTempo / 60.0
            let resolvedName = Self.defaultStemTrackName(trackName: stem.trackName)
            // The track AND its clip are flagged AI-generated (violet in the
            // UI — "violet always means AI-generated", DESIGN-LANGUAGE.md).
            let clip = Clip(
                name: resolvedName,
                startBeat: startBeat,
                lengthBeats: lengthBeats,
                audioFileURL: stem.stableURL,
                isAIGenerated: true
            )
            var newTrack = Track(name: resolvedName, kind: .audio)
            newTrack.isAIGenerated = true
            newTrack.clips = [clip]
            newTracks.append(newTrack)
            newTrackClipNames.append((newTrack.id, clip.id, stem.trackName))
        }

        performEdit("Import Generated Stems") {
            // Tempo adoption folds into this SAME edit, so one undo restores
            // the previous tempo together with removing every track.
            if let adoptedBPM {
                applyTempoChange(adoptedBPM)
            }
            tracks.append(contentsOf: newTracks)
            engine?.tracksDidChange(tracks)
        }
        return (newTrackClipNames, adoptedBPM)
    }

    /// Default AI-track name for one stem: `"AI: <Readable Track Name>"`,
    /// title-casing an underscore-separated upstream track name (e.g.
    /// `"backing_vocals"` -> `"AI: Backing Vocals"`).
    static func defaultStemTrackName(trackName: String) -> String {
        let words = trackName
            .split(separator: "_")
            .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
        let readable = words.joined(separator: " ")
        return readable.isEmpty ? "AI: Stem" : "AI: \(readable)"
    }
}
