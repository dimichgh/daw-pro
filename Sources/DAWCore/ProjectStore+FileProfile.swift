import Foundation

/// File-profiling store ops (m25-z, the `ProjectStore+Analysis`/
/// `ProjectStore+Reference` sibling for a windowing question instead of a
/// content-analysis or program-loudness one). New domains live in extension
/// files (ProjectStore.swift is 2.3k lines).
@MainActor
extension ProjectStore {

    /// Windowed peak/RMS profile of an ARBITRARY file on disk (m25-z):
    /// forwards to the engine's offline `profileFile` (async because
    /// analysis is; no cache — a profile is a throwaway diagnostic read).
    /// `path` is `~`-expanded and never required to be inside the project
    /// or the References library — this is a general-purpose "what does
    /// this file on disk actually contain, windowed" probe, not a
    /// reference-track operation. Read-only: no `performEdit`, no undo
    /// entry, nothing persisted, nothing copied, the reference slot and the
    /// References library are UNTOUCHED (this never calls into any
    /// reference.* machinery).
    ///
    /// `loudness` (m27-k, default false) adds `FileProfile.loudness`: the
    /// BS.1770 reading for the profiled range from the meter
    /// `reference.import` uses, so a bounce's loudness can be checked without
    /// importing (copying) it. Still read-only. Without it the call takes the
    /// m25-z path unchanged and the reply carries no `loudness` key.
    ///
    /// Rejections, verbatim: no file at `path` → `audioFileNotFound`
    /// (naming the path); headless / an engine without the capability →
    /// `engineUnavailable` (a profile is never fabricated, and neither is a
    /// loudness reading: one asked for and missing refuses too).
    public func profileFile(
        path: String, windowSeconds: Double,
        fromSeconds: Double = 0, durationSeconds: Double? = nil,
        loudness: Bool = false
    ) async throws -> FileProfile {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.audioFileNotFound(url.path)
        }
        guard let engine else { throw ProjectError.engineUnavailable }
        guard loudness else {
            return try await engine.profileFile(
                at: url, windowSeconds: windowSeconds,
                fromSeconds: fromSeconds, durationSeconds: durationSeconds)
        }
        let profile = try await engine.profileFile(
            at: url, windowSeconds: windowSeconds, fromSeconds: fromSeconds,
            durationSeconds: durationSeconds, measuringLoudness: true)
        // A reading that was asked for and came back absent is an engine
        // defect: refuse rather than let it read as "no loudness".
        guard profile.loudness != nil else { throw ProjectError.engineUnavailable }
        return profile
    }
}
