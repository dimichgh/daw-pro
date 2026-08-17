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
    /// Rejections, verbatim: no file at `path` → `audioFileNotFound`
    /// (naming the path); headless / an engine without the capability →
    /// `engineUnavailable` (a profile is never fabricated).
    public func profileFile(
        path: String, windowSeconds: Double,
        fromSeconds: Double = 0, durationSeconds: Double? = nil
    ) async throws -> FileProfile {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProjectError.audioFileNotFound(url.path)
        }
        guard let engine else { throw ProjectError.engineUnavailable }
        return try await engine.profileFile(
            at: url, windowSeconds: windowSeconds,
            fromSeconds: fromSeconds, durationSeconds: durationSeconds)
    }
}
