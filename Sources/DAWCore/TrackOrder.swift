import Foundation

/// The ONE home for "what does the track array look like after a reorder"
/// (m23-z), extracted from `ProjectStore.reorderTrack` so the store's mutation
/// and any surface that must PREDICT it share one implementation.
///
/// WHY THIS EXISTS AS A TYPE: the mixer's drag (m23-z) has to know, before it
/// commits anything, whether a candidate landing changes what the console
/// actually SHOWS — the console renders `channels ++ buses`, so an array move
/// can be visually inert. Answering that means applying the move to a candidate
/// array. Written a second time in the mixer, that permutation would be free to
/// disagree with the store's, and the drag would then draw an insertion line for
/// a landing the store resolves differently — the exact class of bug the
/// `ResolvedDropBeat` / `ResolvedTrackDrop` registries exist to make
/// unrepresentable. So there is one function, and `reorderTrack` calls it.
public enum TrackOrder {
    /// `tracks` after moving `id` so it ends up AT `index`.
    ///
    /// FINAL-INDEX SEMANTICS (the `reorderEffect`/`track.reorder` convention,
    /// m23-h): `index` is where the track ENDS UP, not SwiftUI's `onMove`
    /// pre-removal offset. Remove-then-insert-at-`index` yields that for both
    /// directions — a down-move's removal shifts the tail left by one, exactly
    /// cancelling.
    ///
    /// Out-of-range indices clamp; an unknown id returns the array untouched.
    /// Total by construction: a predictor that trapped on a stale index would
    /// crash the drag it was asked to preview.
    public static func applying(_ tracks: [Track], moving id: UUID, to index: Int) -> [Track] {
        guard let from = tracks.firstIndex(where: { $0.id == id }), !tracks.isEmpty else {
            return tracks
        }
        let dest = min(max(0, index), tracks.count - 1)
        guard dest != from else { return tracks }
        var next = tracks
        let track = next.remove(at: from)
        next.insert(track, at: min(dest, next.count))
        return next
    }
}
