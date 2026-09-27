import Foundation

/// `project.transpose` (p2-sing-k), the store door: the ONLY way the whole
/// song changes key (design `docs/design/2026-09-27-p2-sing-integration.md`
/// §3.6). Every decision lives in the pure planner, `ProjectTranspose.plan`
/// (`ProjectTranspose.swift`, whose banner holds the field census); this door
/// only reads the store, applies the plan as ONE undo step, and tells the
/// engine once.
///
/// TODO(p2-sing-k wire round, W7-WIRE lane): expose as the control command
/// `project.transpose` (`semitones` −12…12 through
/// `ProjectTranspose.validatedSemitones`, `excludeTrackIds?`, `dryRun?`;
/// `rejectUnknownKeys`) in `Sources/DAWControl/Commands.swift`, returning the
/// `TransposeReport` encoded verbatim, and as the MCP tool `project_transpose`
/// in `mcp-server/src/server.ts`. Refusals: `TransposeRefusal.code` +
/// `message` (`transposeOutOfRange`, `transposeNoteOutOfRange`,
/// `transposeAudioShiftOutOfRange`, and `transposeLooperOpen`, an addition to
/// the design's three), plus `ProjectError.trackNotFound` for an unknown
/// `excludeTrackIds` entry.
@MainActor
extension ProjectStore {

    /// Moves the whole song by `semitones` (−12…12) as ONE undo step, and
    /// returns what moved, what was left alone and why, and what to watch out
    /// for.
    ///
    /// **Moves:** every note on a pitched track and every audio clip's pitch
    /// shift, takes included. **Skips:** drum tracks
    /// (`ProjectTranspose.isDrumTrack`) and every track in `excludeTrackIds`.
    /// **Keeps:** a tuned clip's corrections, which follow the clip's shift
    /// (see the planner's banner for why moving them would be wrong).
    ///
    /// **Writes nothing, journals nothing, marks nothing dirty and never calls
    /// the engine** when `dryRun` is true, when `semitones` is 0, or when there
    /// is nothing to move. Those return the report alone. A refusal
    /// (`TransposeRefusal`, `ProjectError.trackNotFound`) is thrown before
    /// anything is written.
    ///
    /// A looper layer on a track this would move is refused: the looper keeps
    /// its own copy of each layer's notes and would put the old key back on
    /// its next pass (`materializeDeckLayers`).
    @discardableResult
    public func transposeProject(semitones: Int, excludeTrackIds: Set<UUID> = [],
                                 dryRun: Bool = false) throws -> TransposeReport {
        var loopTracks = Set(loopDeck?.layers.map(\.trackID) ?? [])
        if let pending = loopDeck?.pending { loopTracks.insert(pending.trackID) }
        let plan = try ProjectTranspose.plan(tracks: tracks, semitones: semitones,
                                             excludeTrackIds: excludeTrackIds,
                                             loopLayerTrackIds: loopTracks, dryRun: dryRun)
        // Not `performEdit` for a preview or a no-op: it marks the project
        // dirty unconditionally, and a preview that raised "unsaved changes"
        // would be a write in all but name.
        guard !dryRun, plan.changesAnything else { return plan.report }
        performEdit(ProjectTranspose.undoLabel(semitones: semitones)) {
            tracks = plan.tracks
            // Notes and clip shifts are ClipKey-affecting edits: the same one
            // restart seam `setClipNotes` and `setClipStretch` ride.
            engine?.tracksDidChange(tracks)
        }
        return plan.report
    }
}
