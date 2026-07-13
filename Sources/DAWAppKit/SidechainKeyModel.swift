import Foundation
import Observation
import DAWCore

/// The KEY (sidechain) picker for a compressor/gate insert row (m12-g S-4,
/// design docs/research/design-m11f-sidechain.md §7). A keyed effect reacts to
/// ANOTHER track's post-fader signal (the classic kick→pad pump) instead of its
/// own; `ProjectStore.setSidechain` is the ONE mutation path (the wire command
/// `fx.setSidechain` calls the same method), so the picker only has to (1) offer
/// a valid list of source tracks and (2) funnel a choice through that method.
///
/// Structure mirrors the `TempoLaneModel` / `InstrumentPickerModel` idiom: a
/// pure candidate-filter (`SidechainKeyPicker`, value-in → value-out, tested
/// without a window or store) plus a thin `@Observable` model that reads the
/// candidate list + current key through injected providers and applies every
/// set/clear through an injected closure wired to `ProjectStore.setSidechain`.
/// So the UI and the wire stay equivalent BY CONSTRUCTION — the view never
/// re-implements the store's cycle/kind/one-per-strip validation; those throw
/// from the store and surface here as `lastErrorMessage` (the design's
/// "let the STORE errors be the backstop, don't duplicate the validator in the
/// view" rule).
///
/// NO VIOLET anywhere: a sidechain key is standard signal routing, not
/// AI-generated content (docs/DESIGN-LANGUAGE.md Rule 3). The keyed badge earns
/// the cyan playback/routing accent, never violet.

// MARK: - Source candidate

/// One track offered as a sidechain KEY source — the id the picker submits and
/// the name it shows. A minimal projection of a `Track` so the picker logic
/// stays headless-testable (the `SidechainSource` value never carries a view).
public struct SidechainKeySource: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - Candidate filter (pure)

/// Pure eligibility filter for the sidechain KEY picker. Value-in → value-out,
/// so a test proves the picker only ever offers a source the store will accept
/// (UI ⊆ wire) WITHOUT a window (the `ClipSnap`/`MeterMap` static-helper
/// precedent).
public enum SidechainKeyPicker {
    /// The tracks eligible as a key SOURCE for an effect on `destinationTrackID`,
    /// in project order. v1 offers AUDIO tracks only (real recorded signal —
    /// the canonical kick→pad workflow) and NEVER the destination strip itself
    /// (a strip cannot key itself). Buses are excluded (bus key sources are a
    /// deferred v1 phase — `sidechainUnsupportedSource`). Cycles are DELIBERATELY
    /// not pre-filtered here: the store's `sidechainWouldCreateCycle` validator
    /// is the single source of truth (design §5) and its teaching message names
    /// the offending path — the picker surfaces it rather than silently hiding a
    /// candidate the user might expect to see.
    public static func eligibleSources(
        destinationTrackID: UUID, tracks: [Track]
    ) -> [SidechainKeySource] {
        tracks.compactMap { track in
            guard track.kind == .audio, track.id != destinationTrackID else { return nil }
            return SidechainKeySource(id: track.id, name: track.name)
        }
    }
}

// MARK: - Model

/// Headless orchestration for one compressor/gate insert row's KEY picker: reads
/// the candidate list + current key through injected providers, applies a
/// set/clear through an injected closure wired to `ProjectStore.setSidechain`
/// (so a UI choice and a `fx.setSidechain` wire call are the SAME edit), and
/// holds the last teaching error a rejected key produced. No SwiftUI, no store
/// reference — the `TempoLaneModel` idiom.
@MainActor
@Observable
public final class SidechainKeyModel {
    /// The eligible key SOURCE tracks (wired to
    /// `SidechainKeyPicker.eligibleSources` over `ProjectStore.tracks`). Read
    /// fresh so a track added/removed over the wire shows up live.
    private let sourcesProvider: () -> [SidechainKeySource]
    /// The effect's current key source id, or nil for self-keyed (wired to the
    /// effect's `sidechainSourceTrackID`). Read fresh so a wire `fx.setSidechain`
    /// updates the badge without the view re-plumbing the model.
    private let currentProvider: () -> UUID?
    /// Resolves a track id to its display name for the keyed badge (wired to
    /// `ProjectStore.tracks`), so the badge still reads a name even if the source
    /// later falls out of the candidate list.
    private let nameResolver: (UUID) -> String?
    /// Applies a set (`sourceID` non-nil) or clear (`nil`) — wired to
    /// `ProjectStore.setSidechain`; a recorder in tests. Throws the store's
    /// field-named teaching errors, which this model surfaces.
    private let applyClosure: (UUID?) throws -> Void

    /// The last teaching error a rejected key produced (unsupported kind/track/
    /// source, cycle, one-per-strip), surfaced inline; cleared on the next
    /// successful set/clear.
    public private(set) var lastErrorMessage: String?

    public init(
        sources: @escaping () -> [SidechainKeySource],
        current: @escaping () -> UUID?,
        nameForTrack: @escaping (UUID) -> String?,
        apply: @escaping (UUID?) throws -> Void
    ) {
        self.sourcesProvider = sources
        self.currentProvider = current
        self.nameResolver = nameForTrack
        self.applyClosure = apply
    }

    // MARK: Reads (fresh from the providers)

    /// The eligible key sources for the picker menu.
    public var candidates: [SidechainKeySource] { sourcesProvider() }
    /// The current key source id (nil = self-keyed).
    public var currentKeyID: UUID? { currentProvider() }
    /// True when the effect is keyed off another track.
    public var isKeyed: Bool { currentProvider() != nil }
    /// The current key source's display name for the keyed badge (nil when
    /// self-keyed, or when the source resolves to nothing — defensive).
    public var currentKeyName: String? {
        guard let id = currentProvider() else { return nil }
        return nameResolver(id)
    }

    // MARK: Mutations (every path funnels through `apply`)

    /// Key off `sourceID` (nil clears the key). A store rejection sets
    /// `lastErrorMessage` and touches nothing.
    public func setKey(_ sourceID: UUID?) {
        do {
            try applyClosure(sourceID)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Clear the key (return the effect to self-keyed).
    public func clear() { setKey(nil) }
}
