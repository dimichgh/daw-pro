import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DAWCore
import DAWAppKit

/// Live hover state for a Finder audio-file drop over the arrange lanes (beta
/// m10-k): where the drop would land (snapped beat, for the drop line) and which
/// lane it targets (for the lane highlight). `targetLaneIndex` is non-nil only when
/// a SINGLE file drops onto an existing audio lane (the plan's routing) — otherwise
/// the drop creates new tracks and only the beat drop-line shows. `rawBeat` is the
/// unsnapped landing beat handed to the import callback (the plan re-snaps it).
struct AudioDropHover: Equatable {
    var targetTrackID: UUID?
    var targetLaneIndex: Int?
    var snappedBeat: Double
    var rawBeat: Double
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

/// Drop handling for audio files dragged from Finder onto the arrange lanes (beta
/// m10-k). Tracks the live hover (so the view paints the cyan target affordance),
/// accepts only drops that carry at least one audio file, and on drop loads the
/// file URLs and routes them through the shared import callback. The actual
/// routing/fan-out/naming/snap lives in the headless `AudioImportPlan` behind the
/// callback — this delegate only maps the pointer to a (target lane, beat) context.
struct AudioLaneDropDelegate: DropDelegate {
    @Binding var hover: AudioDropHover?
    /// Maps a content-space point + the dragged file count to the hover preview.
    let resolve: (_ point: CGPoint, _ fileCount: Int) -> AudioDropHover
    /// Runs the shared import (urls, target lane id, unsnapped drop beat).
    let onImport: (_ urls: [URL], _ targetTrackID: UUID?, _ atBeatRaw: Double) -> Void

    /// Only accept a drop that carries at least one audio file (a bare folder /
    /// text file gets the OS no-drop cursor). A MIXED drop with any audio is
    /// accepted; the plan filters + reports the non-audio members.
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.audio])
    }

    func dropEntered(info: DropInfo) {
        hover = resolve(info.location, providerCount(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hover = resolve(info.location, providerCount(info))
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        hover = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        // Capture the target synchronously at the drop location, then clear the
        // hover; the URL loads finish async.
        let resolved = resolve(info.location, providers.count)
        hover = nil
        guard !providers.isEmpty else { return false }

        let collector = DropURLCollector(total: providers.count) { urls in
            guard !urls.isEmpty else { return }
            onImport(urls, resolved.targetTrackID, resolved.rawBeat)
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

    private func providerCount(_ info: DropInfo) -> Int {
        info.itemProviders(for: [.fileURL]).count
    }
}
