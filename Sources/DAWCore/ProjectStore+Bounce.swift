import Foundation

/// Result of `ProjectStore.bounceTrackInPlace` (m11-e). Codable = the
/// `track.bounceInPlace` wire shape (wire-never-drifts): the new audio `track`
/// and its landed `clip` (the same full-object encodings `track.add` /
/// `clip.addAudio` return), the rendered `file` on disk, whether the source
/// track ended up muted, and the bounced audio's own `LoudnessMeasurement`
/// (exactly what a `render.stems` pass over the same track reports — never
/// normalized, > 0 dBFS overshoots stay visible).
public struct BounceInPlaceResult: Codable, Sendable, Equatable {
    /// The new audio track that received the bounce (inserted directly after
    /// the source in track order).
    public var track: Track
    /// The single clip landed on `track`, at `fromBeat`, referencing `file`.
    public var clip: Clip
    /// Absolute path of the rendered WAV, in the project-stable media home (it
    /// survives undo — see the store method's undo contract).
    public var file: String
    /// The source track that was rendered.
    public var sourceTrackId: UUID
    /// Whether the source track is muted after the bounce (true under the
    /// default `muteSource`; false when the caller kept it audible).
    public var sourceMuted: Bool
    /// The bounced audio's loudness report (BS.1770-4), same shape and policy
    /// as a `render.stems` stem file — un-normalized, honest for the file on
    /// disk. Fields are nil for a program below the −70 LUFS gate.
    public var measurement: LoudnessMeasurement

    public init(track: Track, clip: Clip, file: String, sourceTrackId: UUID,
                sourceMuted: Bool, measurement: LoudnessMeasurement) {
        self.track = track
        self.clip = clip
        self.file = file
        self.sourceTrackId = sourceTrackId
        self.sourceMuted = sourceMuted
        self.measurement = measurement
    }
}

/// Track bounce-in-place (m11-e): render ONE track's stem offline and land it
/// as a new audio track + clip in ONE undo step — the render-and-land pattern,
/// reusing `render.stems`' render machinery and `importGeneration`'s land
/// discipline (media work OUTSIDE the edit body, model mutation inside a single
/// `performEdit`). Reversible "Freeze" is explicitly OUT of scope (a plain
/// render-and-land, not a hideable/thaw-able freeze — a separate future item).
@MainActor
extension ProjectStore {
    /// Renders `trackId`'s stem and lands it as a new `<source> (Bounced)`
    /// audio track directly after the source, in ONE undo step.
    ///
    /// - Eligibility is IDENTICAL to `render.stems` for one track (via
    ///   `StemPlan.descriptors`): the target must be a master input — a
    ///   direct-to-master audio/instrument track, or a bus. A bus-ROUTED source
    ///   track rejects `.stemNotMasterInput` verbatim (its signal lives in the
    ///   destination bus's stem); an unknown id rejects `.trackNotFound`; a
    ///   session with no clips in the render window rejects `.nothingToRender`
    ///   (exactly what the stem path does — an empty track when OTHER tracks
    ///   have clips renders legitimate silence, never an error).
    /// - The render reuses the stem path EXACTLY: the full-session PDC plan is
    ///   probed once and FORCED, the single stem pass runs post-fader under it,
    ///   over the SAME default window as `render.stems` (`fromBeat` +
    ///   `durationSeconds`; default = whole-session extent + 2 s tail). So the
    ///   bounced file is byte-identical to `render.stems {trackIds:[trackId]}`
    ///   for the same window. NEVER normalized.
    /// - The rendered WAV is written into the project-stable media home
    ///   (`generationImportsDirectory`, the same home `importGeneration` uses)
    ///   OUTSIDE the edit body, so a read/write failure never journals a
    ///   half-edit. Then ONE `performEdit("Bounce in Place")` inserts the new
    ///   audio track + clip and — when `muteSource` (default true) — mutes the
    ///   source. Undo removes the new track+clip AND restores the source's prior
    ///   mute together. The rendered FILE stays on disk after undo (import
    ///   semantics: undo un-references it but never deletes media — a redo, or a
    ///   later save fold, still needs it).
    /// - `name` overrides the default `<source> (Bounced)` track/clip name.
    ///
    /// Blocking on the main actor while the offline render runs (~one stem's
    /// worth), the `render.stems` precedent — v0 accepts the stall.
    @discardableResult
    public func bounceTrackInPlace(
        trackId: UUID,
        fromBeat: Double = 0,
        durationSeconds: Double? = nil,
        muteSource: Bool = true,
        name: String? = nil
    ) async throws -> BounceInPlaceResult {
        guard let engine else { throw ProjectError.engineUnavailable }
        let startBeat = max(0, fromBeat)

        // 1. Eligibility + the solo pass — the SAME plan `render.stems` uses for
        //    one track. Throws trackNotFound / stemNotMasterInput here, before
        //    anything is rendered or written.
        let descriptors = try StemPlan.descriptors(tracks: tracks, including: [trackId])
        guard let descriptor = descriptors.first else {
            // Unreachable: descriptors(including:[id]) yields exactly one entry
            // for an eligible id, else it throws above. Defensive.
            throw ProjectError.nothingToRender
        }
        let duration = try renderWindowSeconds(fromBeat: startBeat, requested: durationSeconds)

        // 2. Render the single stem OUTSIDE the edit body, under the FORCED
        //    full-session compensation plan (probed once) — byte-parity with
        //    render.stems' one-track pass.
        let targets = await engine.offlineCompensationTargets(tracks: tracks)
        // STEM class (m13-d, design §2): a track bounce must never bake the
        // master bus into clip material — byte==stem stays BY CONSTRUCTION.
        // The master volume lane is excluded too (m15-c, S-3′ extension): a
        // baked fade would double-apply when the landed clip plays back
        // through the live master fade.
        let audio = try await engine.renderOffline(
            tracks: StemPlan.passTracks(for: descriptor, session: tracks),
            tempoMap: transport.tempoMap, masterVolume: masterVolume,
            masterEffects: [],
            masterAutomation: [],
            fromBeat: startBeat, durationSeconds: duration,
            forcedCompensationTargets: targets
        )
        let measurement = await Loudness.measureDetached(audio)

        // 3. Write into the project-stable media home (survives temp sweeps and
        //    undo/redo resurrection, and folds into the .dawproj media/ on save
        //    — the importGeneration home).
        let dir = generationImportsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("bounce-\(UUID().uuidString.prefix(8)).wav")
        let info = try engine.writeAudioFile(audio, to: fileURL)
        // NOTE: renderCompletedCount is deliberately NOT ticked — that signal is
        // the "you exported your song" onboarding milestone (renderBounce); a
        // bounce-in-place is a compositional import, not an export.

        // 4. Build the new track + clip OUTSIDE the edit body (the
        //    importGeneration discipline). Length in beats is the inverse
        //    integral of the authoritative on-disk duration from the landing
        //    beat (m12-b, design row 32).
        let lengthBeats = transport.tempoMap.beat(
            from: startBeat, elapsedSeconds: info.durationSeconds) - startBeat
        let resolvedName = name?.isEmpty == false ? name! : "\(descriptor.name) (Bounced)"
        let clip = Clip(name: resolvedName, startBeat: startBeat,
                        lengthBeats: lengthBeats, audioFileURL: fileURL)
        var newTrack = Track(name: resolvedName, kind: .audio)
        newTrack.clips = [clip]

        // 5. ONE edit: insert the bounced track directly after the source, and
        //    mute the source when asked. Undo reverses BOTH together.
        performEdit("Bounce in Place") {
            let insertIndex = tracks.firstIndex(where: { $0.id == trackId })
                .map { $0 + 1 } ?? tracks.count
            tracks.insert(newTrack, at: insertIndex)
            if muteSource, let si = tracks.firstIndex(where: { $0.id == trackId }) {
                tracks[si].isMuted = true
            }
            engine.tracksDidChange(tracks)
        }

        let sourceMuted = tracks.first(where: { $0.id == trackId })?.isMuted ?? false
        return BounceInPlaceResult(
            track: newTrack, clip: clip, file: fileURL.path,
            sourceTrackId: trackId, sourceMuted: sourceMuted, measurement: measurement)
    }
}
