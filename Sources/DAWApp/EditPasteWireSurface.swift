import DAWControl
import Foundation

// `edit.pasteClips`'s app-layer seam (m26-k) — the `PluginWindowManager` /
// `PluginUIControlling` precedent, at the smallest possible footprint:
// `AppModel` already holds every piece of state `pasteClipsFromClipboardDetailed`
// needs (the clipboard, the store, the arrange selection, the active-track
// cursor), so it conforms directly rather than through a second owned object.
// This file exists separately from `DAWProApp.swift` for the SAME reason
// `EditClipboardStaging.swift` does (that file's header, m23-cq-1): the host
// file is 10 000+ lines and a standing merge magnet, so the footprint there
// stays the one-line `router.editPaste = self` at startup
// (`DAWProApp.swift`'s control-server wiring, beside `router.pluginUI`).
//
// The whole conformance is a pass-through: `pasteClips(intoTrack:)` is
// `pasteClipsFromClipboardDetailed(intoTrack:)` under the protocol's name.
// `pasteClipsFromClipboardDetailed` is the ONE HOME for the paste's actual
// work (targeting, the store call, selection, the refusal bubble); nothing
// here may reimplement any of it.
extension AppModel: EditPasteControlling {
    func pasteClips(intoTrack: UUID?) -> EditPasteResult {
        pasteClipsFromClipboardDetailed(intoTrack: intoTrack)
    }
}
