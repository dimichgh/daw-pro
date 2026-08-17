import Foundation

/// The `edit.pasteClips` control surface (m26-k), following the `plugin.*`
/// precedent (`PluginUISurface.swift`) point for point: a Foundation-only
/// protocol + result types live here in DAWControl so the command router can
/// validate and route without importing DAWAppKit (`Package.swift`: DAWControl
/// depends on DAWCore + AIServices only); the concrete implementation is
/// installed by DAWApp at startup (the `copilotEngine`/`pluginUI` two-phase
/// precedent). When no implementation is installed (a headless control
/// session), the route fails with a readable error rather than crashing.

/// One clip `edit.pasteClips` actually placed.
public struct EditPasteLanding: Sendable {
    /// The pasted clip's FRESH id (never the source clip's — a paste always
    /// mints a new one; see `ProjectStore.reidentified`).
    public var clipID: UUID
    /// The track it landed on.
    public var trackID: UUID
    /// The project beat its start moved to.
    public var startBeat: Double

    public init(clipID: UUID, trackID: UUID, startBeat: Double) {
        self.clipID = clipID
        self.trackID = trackID
        self.startBeat = startBeat
    }
}

/// One clip the paste could NOT place, and why. `reason` is a plain string
/// (mirrors `DAWAppKit.PasteAnchorPolicy.ClipPasteSkipReason`'s raw value —
/// e.g. `"track-kind-mismatch"`, `"overlaps-pasted-sibling"` — rather than
/// that DAWAppKit enum itself; DAWControl cannot import DAWAppKit, the same
/// boundary `PluginUIWindowInfo.BodyKind` mirrors AU concepts across without
/// importing AVFoundation).
public struct EditPasteSkip: Sendable {
    public var sourceClipID: UUID
    public var clipName: String
    public var reason: String

    public init(sourceClipID: UUID, clipName: String, reason: String) {
        self.sourceClipID = sourceClipID
        self.clipName = clipName
        self.reason = reason
    }
}

/// What `edit.pasteClips` actually did. A bare `Bool` — what
/// `AppModel.pasteClipsFromClipboard` returns today — cannot tell "the
/// clipboard was already empty" apart from "the clipboard holds notes, not
/// clips" apart from "every clip was refused by its destination": three
/// outcomes an agent needs told apart, because only one of them points at a
/// different route entirely.
public enum EditPasteResult: Sendable {
    /// One or more clips landed. `trimmedClipIDs`/`removedClipIDs` are the
    /// ordinary residents the paste's overlap resolution trimmed or removed
    /// outright (`ProjectStore.pasteClips`'s own honesty contract — the
    /// `clip.moveMany` capital-"IDs" key spelling, matched here since both
    /// answer the same question). `skipped` is non-empty only when part of a
    /// multi-clip payload didn't land alongside the rest (e.g. the relocation
    /// clamp folded two source tracks onto one, so a sibling was skipped as
    /// `overlaps-pasted-sibling`).
    case pasted(landings: [EditPasteLanding], skipped: [EditPasteSkip],
                trimmedClipIDs: [UUID], removedClipIDs: [UUID])
    /// The clipboard held nothing to paste.
    case emptyClipboard
    /// The clipboard holds NOTES, not clips — that is a piano-roll paste, not
    /// an arrange one; `actual` echoes `DAWAppKit.ClipboardKind`'s raw value
    /// (always `"notes"` today, spelled out rather than hardcoded so a future
    /// clipboard payload kind fails loudly here instead of silently).
    case wrongPayloadKind(actual: String)
    /// Nothing landed. `reason` names why: either
    /// `DAWAppKit.PasteAnchorPolicy.ClipPasteRefusal`'s raw value
    /// (`"no-tracks"` / `"no-compatible-track"` / `"empty-payload"`) when the
    /// policy refused before resolving any landing at all, or
    /// `"all-skipped"` when a plan WAS resolved but every member individually
    /// mismatched its own destination (a MIDI clip pasted onto an audio
    /// track, most commonly) — `skipped` then names each one and why.
    case blocked(reason: String, skipped: [EditPasteSkip])
}

/// The app-layer seam `edit.pasteClips` routes through — the
/// `PluginUIControlling` precedent verbatim. `@MainActor`: the implementation
/// touches `ProjectStore`/`ArrangeSelection`, both main-actor-only.
@MainActor
public protocol EditPasteControlling: AnyObject {
    /// Pastes the app clipboard's clips. `intoTrack` nil = the resolved
    /// active track, exactly what Cmd-V uses; non-nil overrides it for THIS
    /// paste only (does not move the stored cursor). Rides
    /// `AppModel.pasteClipsFromClipboard(intoTrack:)`'s exact targeting —
    /// this is a new WIRE ROUTE to that shipped operation, not a new one.
    func pasteClips(intoTrack: UUID?) -> EditPasteResult
}
