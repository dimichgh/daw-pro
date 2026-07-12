import Foundation

/// Pure commit resolution for the track-header inline rename (beta m10-i). The
/// double-click rename field hands this namespace the raw draft and the track's
/// current name; it decides whether the edit is a real rename, an empty-input
/// cancel, or an unchanged no-op — so the SwiftUI row stays thin and the commit
/// rules unit-test headless (the `CopilotSummaryFormat`/`PianoRollPlayhead`
/// precedent). Every commit that survives routes through `ProjectStore.renameTrack`,
/// which already journals one undo step and rejects an empty name.
public enum TrackRename {

    /// Whitespace-trimmed draft — leading/trailing spaces and newlines removed.
    /// The single place the field's raw text is normalized, so the min-width
    /// field and the validator agree on what a name "is".
    public static func trimmed(_ draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The name to commit, or `nil` when the edit should be dropped without
    /// touching the store:
    /// - empty (or whitespace-only) input → `nil` (Escape-equivalent cancel — an
    ///   accidental clear never wipes a track's name),
    /// - trimmed input equal to the current name → `nil` (a no-op re-type of the
    ///   same name should not push a pointless undo step),
    /// - otherwise the trimmed new name.
    ///
    /// Trimming is applied to BOTH sides so " Bass " over "Bass" reads as
    /// unchanged, not a rename to a padded duplicate.
    public static func committedName(draft: String, current: String) -> String? {
        let candidate = trimmed(draft)
        guard !candidate.isEmpty else { return nil }
        guard candidate != trimmed(current) else { return nil }
        return candidate
    }
}
