import Foundation
import Observation
import DAWCore
import DAWAppKit

/// Translates real `ProjectStore` mutations into onboarding tour signals (M8 ob-b).
///
/// This is the app-side OBSERVING ADAPTER the brief settles on — deliberately NOT
/// scattered `model.signal(_:)` calls at each UI site. Why an adapter: (ob-c) will
/// walk the tour over the CONTROL WIRE, so every signal must fire for wire-driven
/// actions too — and both UI and wire mutate the same `@Observable` store. Observing
/// the store once catches both. The tour model's strict active-step matching makes
/// firing several signals for one action benign: a skeleton apply flips content AND
/// journals an edit, so this emits both `projectGainedContent` and `editPerformed`;
/// only the one the active step expects advances, the other is a tested no-op.
///
/// It observes four store facts and maps each to a signal:
///  - tracks-with-clips count 0 → >0  ⟶  `projectGainedContent`
///  - `transport.isPlaying` false → true  ⟶  `playbackStarted`
///  - `lastEditEvent.seq` change  ⟶  `OnboardingEditClassifier` → `editPerformed` /
///    `mixerAdjusted` (a fader NEVER reads as `editPerformed`)
///  - `renderCompletedCount` increment  ⟶  `renderCompleted`
///
/// The tour model NEVER reads the store (design decision 2); this adapter is the
/// only bridge, and it only ever calls `model.signal(_:)`. Baselines are refreshed
/// even while the tour is inactive, so a tour that STARTS mid-session reacts only to
/// actions taken during the tour — never a stale pre-existing-content delta.
@MainActor
final class OnboardingSignalAdapter {
    private let store: ProjectStore
    private let model: OnboardingModel

    private var lastContentPositive = false
    private var lastPlaying = false
    private var lastEditSeq = 0
    private var lastRenderCount = 0
    private var started = false

    init(store: ProjectStore, model: OnboardingModel) {
        self.store = store
        self.model = model
    }

    /// Seeds the baselines from the CURRENT store (so pre-existing content doesn't
    /// spuriously fire) and arms observation. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        lastContentPositive = Self.hasContent(store)
        lastPlaying = store.transport.isPlaying
        lastEditSeq = store.lastEditEvent?.seq ?? 0
        lastRenderCount = store.renderCompletedCount
        observe()
    }

    /// Arms one `withObservationTracking` pass over the four facts, then re-arms on
    /// the next runloop tick (the mutation has settled by then, so `sync()` reads
    /// post-change values). The canonical "observe an @Observable from a controller"
    /// pattern.
    private func observe() {
        withObservationTracking {
            _ = Self.hasContent(store)
            _ = store.transport.isPlaying
            _ = store.lastEditEvent?.seq
            _ = store.renderCompletedCount
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.sync()
                self.observe()
            }
        }
    }

    /// Compares each fact to its baseline and emits the matching signal(s), then
    /// advances the baselines. While the tour is inactive it only refreshes
    /// baselines (no signal work) — so the next tour reacts to fresh deltas only.
    private func sync() {
        let contentPositive = Self.hasContent(store)
        let playing = store.transport.isPlaying
        let editSeq = store.lastEditEvent?.seq ?? 0
        let renderCount = store.renderCompletedCount

        guard model.currentStep != nil else {
            // Tour inactive: keep baselines current, do nothing else.
            lastContentPositive = contentPositive
            lastPlaying = playing
            lastEditSeq = editSeq
            lastRenderCount = renderCount
            return
        }

        // content 0 → >0
        if contentPositive && !lastContentPositive {
            model.signal(.projectGainedContent)
        }
        lastContentPositive = contentPositive

        // playback false → true
        if playing && !lastPlaying {
            model.signal(.playbackStarted)
        }
        lastPlaying = playing

        // a newly journaled edit → classified signal
        if editSeq != lastEditSeq, let event = store.lastEditEvent {
            model.signal(OnboardingEditClassifier.signal(for: event))
        }
        lastEditSeq = editSeq

        // a bounce/mixdown finished writing a file
        if renderCount > lastRenderCount {
            model.signal(.renderCompleted)
        }
        lastRenderCount = renderCount
    }

    /// Whether any track carries at least one clip — the "project gained content"
    /// test (an empty track is not content).
    static func hasContent(_ store: ProjectStore) -> Bool {
        store.tracks.contains { !$0.clips.isEmpty }
    }
}
