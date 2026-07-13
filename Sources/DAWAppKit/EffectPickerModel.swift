import Foundation
import Observation
import DAWCore

/// Headless state machine for the mixer's AU-effect picker (m13-g, audit F6): a
/// searchable flat list of the installed Audio Unit EFFECT components, and the
/// `AudioUnitConfig` a selection applies — the SAME value the wire's `fx.add
/// kind:"audioUnit"` resolves against the installed components (UI == wire). No
/// SwiftUI / AppKit: the modal picker is thin over this and the tests drive it
/// against fixture component lists (the `InstrumentPickerModel` precedent — all
/// logic here, testable without a window OR a store).
///
/// The picker is a PRO-only, track/bus-only affordance by construction: it is
/// reached only from the Pro inserts add-menu, and the master chain is built-ins-
/// only in v1 (`ProjectStore.masterChainBuiltInOnly`), so the master strip omits
/// the "Audio Units…" opener rather than offering-then-erroring. NO VIOLET —
/// standard signal-flow chrome, not AI content (docs/DESIGN-LANGUAGE.md Rule 3);
/// cyan marks nothing here (there is no "current" effect when adding).
@MainActor
@Observable
public final class EffectPickerModel {
    /// Installed AU effects (wired to `ProjectStore.availableAudioUnitEffects`).
    private let audioUnitsProvider: () -> [AudioUnitComponentInfo]

    /// The loaded AU list, refreshed from the provider on open.
    public private(set) var audioUnits: [AudioUnitComponentInfo] = []
    /// The track/bus the picker is adding an effect to; nil until `prepare`.
    public private(set) var targetTrackID: UUID?
    /// The single search field — spans name + maker (essential at the dozens-of-
    /// plugins scale a real Mac carries). Case-insensitive substring.
    public var searchText: String = ""

    public init(audioUnits: @escaping () -> [AudioUnitComponentInfo]) {
        self.audioUnitsProvider = audioUnits
    }

    /// Points the picker at a track and reloads the AU list, resetting the search.
    public func prepare(trackID: UUID) {
        targetTrackID = trackID
        searchText = ""
        refresh()
    }

    /// Reloads the AU list from the provider (a cheap cached registry read).
    public func refresh() { audioUnits = audioUnitsProvider() }

    /// The installed AU effects filtered by search across `name` +
    /// `manufacturerName`, sorted by name then maker for a stable list.
    public var filteredAudioUnits: [AudioUnitComponentInfo] {
        audioUnits
            .filter {
                Self.matches($0.name, query: searchText)
                    || Self.matches($0.manufacturerName, query: searchText)
            }
            .sorted {
                let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
                if byName != .orderedSame { return byName == .orderedAscending }
                return $0.manufacturerName.localizedCaseInsensitiveCompare($1.manufacturerName)
                    == .orderedAscending
            }
    }

    /// The `AudioUnitConfig` a chosen AU effect applies — the component triple plus
    /// the display facts captured at selection time (so a later-missing plugin
    /// still reads). This is byte-for-byte the `InstrumentPickerModel.choice(for
    /// au:)` construction, and produces the SAME config the wire builds from
    /// `fx.add {audioUnit:{type,subType,manufacturer}}` (component identity is the
    /// key; `stateData` starts nil for a freshly-added insert).
    public func config(for au: AudioUnitComponentInfo) -> AudioUnitConfig {
        AudioUnitConfig(component: au.component, name: au.name,
                        manufacturerName: au.manufacturerName)
    }

    /// Case-insensitive substring match; an empty query matches everything.
    nonisolated static func matches(_ text: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return text.range(of: trimmed, options: .caseInsensitive) != nil
    }
}
