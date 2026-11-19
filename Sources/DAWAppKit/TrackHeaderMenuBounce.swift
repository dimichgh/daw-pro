import DAWCore
import Foundation

/// The track header menu's "Bounce in Place" press (m39-render-pass-race-ui).
///
/// The menu used to run `Task { try? await store.bounceTrackInPlace(trackId:) }`, which threw every refusal away at
/// the call site. Since m39-render-pass-race one of those refusals is a song change: press Bounce in Place, then New
/// or Open before the render finishes, and the store refuses to land the bounce in either song
/// (`ProjectError.bounceInPlaceSongChanged`). Under `try?` the menu then did nothing and said nothing. Every other
/// refusal went the same way (a song with no clips is `nothingToRender`).
///
/// `press` runs the store's own bounce with the menu's exact arguments (the defaults) and returns the refusal in the
/// store's words, or nil when the bounced track landed. The view shows that sentence in the alert the track menu
/// already uses for Export MIDI (`TrackListView.presentRefusal`). The `TransportRecordButtonModel.press` shape: a
/// refusal is never swallowed, and no sentence is written here.
///
/// One exception: `nothingToRender`'s store sentence is wire contract and teaches agents a parameter
/// ("pass an explicit durationSeconds") that a menu user has no way to pass, so the menu shows `emptySongSentence`
/// in its place.
///
/// No SwiftUI. `BounceRefusalTests` drives a real store through it and pins the menu case that calls it.
public enum TrackHeaderMenuBounce {

    /// What the menu says for a song with no clips. The store's own sentence names a wire parameter.
    public static let emptySongSentence =
        "There's nothing to bounce yet: this song has no clips. Add a clip, then try Bounce in Place again."

    /// Bounces `trackID` in place. Returns nil when the new track landed, otherwise the refusal sentence: the
    /// store's own, except `emptySongSentence` for a song with no clips.
    @MainActor
    public static func press(_ store: ProjectStore, trackID: UUID) async -> String? {
        do {
            try await store.bounceTrackInPlace(trackId: trackID)
            return nil
        } catch ProjectError.nothingToRender {
            return emptySongSentence
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
