import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DAWCore
import DAWAppKit

/// Live hover state for a Finder audio-file drop over the arrange lanes (beta
/// m10-k): where the drop would land and which lane it targets (for the lane
/// highlight). `targetLaneIndex` is non-nil only when a SINGLE file drops onto an
/// existing audio lane (the plan's routing) — otherwise the drop creates new
/// tracks and only the beat drop-line shows.
///
/// m23-f: `landing` is THE resolved beat — the drop line draws at it and the
/// clip lands on it, because they are the same stored value, produced by one
/// `ArrangeDropSnap.resolve` call and carried (never recomputed) into
/// `AudioImportContext`. `rawBeat` survives for the debug echo only; nothing
/// places a clip from it.
struct AudioDropHover: Equatable {
    var targetTrackID: UUID?
    var targetLaneIndex: Int?
    var landing: ResolvedDropBeat
    var rawBeat: Double

    /// The beat the drop line paints at — by definition the landing beat.
    var snappedBeat: Double { landing.beat }
}

/// Accumulates the asynchronously-loaded file URLs from a drop's item providers,
/// preserving order, and fires once every provider has reported. MainActor-isolated
/// (so it is `Sendable` and its mutation is race-free), fed from each provider's
/// background completion via a `@MainActor` `Task` carrying only `Sendable` values.
@MainActor
final class DropURLCollector {
    private var urls: [Int: URL] = [:]
    private var remaining: Int
    private let total: Int
    private let completion: ([URL]) -> Void

    init(total: Int, completion: @escaping ([URL]) -> Void) {
        self.total = total
        self.remaining = total
        self.completion = completion
    }

    func set(_ url: URL?, at index: Int) {
        if let url { urls[index] = url }
        remaining -= 1
        if remaining <= 0 {
            completion((0..<total).compactMap { urls[$0] })
        }
    }
}

/// The `DropInfo`-FREE core of the arrange audio drop (m23-f). Every drop
/// behaviour lives here as a plain point/url function, because `DropInfo` has no
/// public initializer — a staging seam can never synthesize one. This is the
/// `applyPointerStage` precedent exactly: the seam does not fake the OS event, it
/// calls the same handler the OS event calls. `AudioLaneDropDelegate` below is a
/// thin `DropInfo` → core adapter, and `debug.arrangeDrop` drives the same core,
/// so "the staged path and the real path agree" is structural rather than
/// reviewed.
///
/// Every mutator RETURNS the hover it produced rather than leaving the caller to
/// re-read the binding: a `@State` read-after-write inside one event turn is not
/// a contract to lean on, and the seam's echo must report what the handler
/// actually decided (the `onPointerState` precedent, which likewise reports its
/// own local value rather than re-reading `@State`).
@MainActor
struct AudioLaneDropCore {
    @Binding var hover: AudioDropHover?
    /// The drag-session phase (m23-f). Owned by the view as `@State` so it
    /// survives the per-body reconstruction of this struct.
    @Binding var session: ArrangeDropSession
    /// Maps a content-space point + what the drag carries to the hover preview.
    let resolve: (_ point: CGPoint, _ contents: ArrangeDragContents) -> AudioDropHover
    /// Runs the shared import at the ALREADY-RESOLVED landing (urls, target lane
    /// id, the one resolved beat). No beat math happens downstream of here —
    /// including for a `.mid`, which lands at this same beat (m23-k4b).
    let onImport: (_ urls: [URL], _ targetTrackID: UUID?, _ landing: ResolvedDropBeat) -> Void

    @discardableResult
    func enter(at point: CGPoint, contents: ArrangeDragContents) -> AudioDropHover? {
        session.entered()
        let resolved = resolve(point, contents)
        hover = resolved
        return resolved
    }

    /// A drag move. Refused after a drop has closed the session: re-arming there
    /// strands the overlay, since no further drag callback is coming (m23-f).
    @discardableResult
    func update(at point: CGPoint, contents: ArrangeDragContents) -> AudioDropHover? {
        guard session.updated() else {
            hover = nil
            return nil
        }
        let resolved = resolve(point, contents)
        hover = resolved
        return resolved
    }

    @discardableResult
    func exit() -> AudioDropHover? {
        session.exited()
        hover = nil
        return nil
    }

    /// The synchronous half of a drop: resolve the landing at `point`, close the
    /// session and clear the hover. Returns the captured target so the (possibly
    /// async) URL load finishes against the position the pointer was actually
    /// released at.
    func beginDrop(at point: CGPoint, contents: ArrangeDragContents) -> AudioDropHover {
        let resolved = resolve(point, contents)
        session.dropped()
        hover = nil
        return resolved
    }

    /// The async half: run the import for a captured target. Clears the hover
    /// again — the URL load lands a whole runloop turn later, and anything that
    /// re-armed the preview in between would otherwise outlive the drag.
    func finishDrop(urls: [URL], resolved: AudioDropHover) {
        hover = nil
        guard !urls.isEmpty else { return }
        onImport(urls, resolved.targetTrackID, resolved.landing)
    }

    /// An ordinary pointer event reached the lanes: dismiss a STRANDED drop
    /// overlay. This is what makes the m23-f artifact removable regardless of
    /// which drag callback the OS withheld — the user's next mouse move clears
    /// it. Guarded on the mouse button, so it can never cancel a live drag
    /// preview (a Finder drag holds the primary button down throughout).
    /// Returns true when it actually dismissed something.
    @discardableResult
    func dismissStrandedHover(pressedMouseButtons: Int) -> Bool {
        guard ArrangeDropSession.pointerMayDismissHover(
            hoverPresent: hover != nil, pressedMouseButtons: pressedMouseButtons) else {
            return false
        }
        hover = nil
        session.exited()
        return true
    }

    /// A whole drop in one synchronous call — the staging seam's path, and the
    /// path a real drop takes once its URLs have arrived. The contents come from
    /// the URLs themselves here, because by this point they are known.
    @discardableResult
    func drop(at point: CGPoint, urls: [URL]) -> AudioDropHover {
        let resolved = beginDrop(at: point, contents: .of(urls: urls))
        finishDrop(urls: urls, resolved: resolved)
        return resolved
    }
}

/// Drop handling for audio files dragged from Finder onto the arrange lanes (beta
/// m10-k). A thin adapter: it converts `DropInfo` into points/urls and delegates
/// every decision to `AudioLaneDropCore`, which the `debug.arrangeDrop` staging
/// seam drives directly. The actual routing/fan-out/naming/snap lives in the
/// headless `AudioImportPlan` behind the callback.
struct AudioLaneDropDelegate: DropDelegate {
    let core: AudioLaneDropCore

    /// Only accept a drop that carries at least one audio file (a bare folder /
    /// text file gets the OS no-drop cursor). A MIXED drop with any audio is
    /// accepted; the plan filters + reports the non-audio members.
    ///
    /// m23-k4b deliberately leaves this UNCHANGED and adds NO second predicate:
    /// `public.midi-audio` CONFORMS TO `public.audio`, so a `.mid` has always
    /// been accepted here — the item is a routing split INSIDE this accepting
    /// path, not a new path beside it. (Verified: `UTType(filenameExtension:
    /// "mid")!.conforms(to: .audio) == true`, pinned in
    /// `MIDIDropRoutingTests`.)
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.audio])
    }

    func dropEntered(info: DropInfo) {
        core.enter(at: info.location, contents: contents(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        core.update(at: info.location, contents: contents(info))
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        core.exit()
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        // Capture the target synchronously at the drop location, then clear the
        // hover; the URL loads finish async.
        let resolved = core.beginDrop(at: info.location, contents: contents(info))
        guard !providers.isEmpty else { return false }

        let collector = DropURLCollector(total: providers.count) { urls in
            core.finishDrop(urls: urls, resolved: resolved)
        }
        for (index, provider) in providers.enumerated() {
            // `loadObject` completes on a background queue; hop to the main actor
            // carrying only Sendable values (the URL + its index). `provider` is
            // never captured across the actor boundary (used synchronously here).
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in collector.set(url, at: index) }
            }
        }
        return true
    }

    /// What the live drag carries. The file count and the MIDI flag are BOTH
    /// read from `DropInfo` synchronously — the URLs are not loaded yet, and a
    /// hover that waited for them would preview nothing (m23-k4b).
    private func contents(_ info: DropInfo) -> ArrangeDragContents {
        ArrangeDragContents(fileCount: info.itemProviders(for: [.fileURL]).count,
                            carriesMIDI: info.hasItemsConforming(to: [.midi]))
    }
}

/// A staged arrange-drop event (`debug.arrangeDrop`, m23-f; debug tier only, nil
/// in normal use). A real Finder drag cannot be driven over the control port —
/// `DropInfo` has no public initializer and the unbundled staging binary has no
/// Accessibility grant (the m17-b −1712 measurement) — so the seam drives the
/// same `AudioLaneDropCore` methods the `DropDelegate` adapter drives, each
/// action independently addressable so a gate can reproduce a REAL sequence
/// (`enter → update → update → drop`) and not just an isolated drop.
///
/// Coordinates are CONTENT-space points (x = beats · pixelsPerBeat), matching
/// `ArrangePointerStage`.
struct ArrangeDropStage: Equatable {
    enum Action: String {
        case enter
        case update
        case drop
        case exit
    }

    var action: Action
    var x: CGFloat
    var y: CGFloat
    /// `drop` only: the files to import, resolved synchronously (no
    /// `NSItemProvider`, so one bounded wait is enough for the whole drop).
    var urls: [URL]
    /// `enter`/`update`: how many files the drag carries (routing depends on it).
    var fileCount: Int
    /// `enter`/`update`: whether the drag carries a `.mid` (m23-k4b). A real
    /// drag reads this from its UTIs before its URLs load, so a staged HOVER has
    /// no URLs to derive it from either — hence a field. On a `drop` it is
    /// derived from `urls` instead, exactly as the real drop derives it.
    var carriesMIDI: Bool
    /// Bumped per request so a repeat of the same stage still fires `.onChange`.
    var nonce: Int

    /// What this stage's action tells the core the drag carries.
    var contents: ArrangeDragContents {
        action == .drop
            ? .of(urls: urls)
            : ArrangeDragContents(fileCount: fileCount, carriesMIDI: carriesMIDI)
    }
}
