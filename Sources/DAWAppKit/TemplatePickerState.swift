import Foundation
import DAWCore

// m39-tpl-8 — THE TEMPLATE PICKER'S DECISIONS, as pure values
// (docs/design/2026-09-27-multi-instrument-templates.md §9.2–§9.4).
//
// Everything the card shows — which tiles, which one is selected, which button
// is primary, which is enabled and WHY, the Song style menu, the plug-in notices,
// the re-tempo warning, the refusal — is a computed property of
// `TemplatePickerState`, a plain `Sendable` value with no store and no actor.
// `TemplatePickerModelTests` (nonisolated) asserts every one of them without a
// window. The only inputs that need the live song arrive as DATA:
// `TemplatePickerFacts` (does the song have tracks, is it recording, its tempo)
// and `TemplatePickerPreflight` (what the store's OWN dry run said about the
// selected template). `TemplatePickerModel` (the `@MainActor` half) fills those
// in from the store and runs the presses.

/// What the two buttons do. Each is exactly one store call, the one a wire verb
/// makes (§9.4: there is no UI-only path).
public enum TemplatePickerAction: String, Sendable, Equatable, CaseIterable {
    /// `ProjectStore.applySongSkeleton(genre:template:)` — `macro.songSkeleton
    /// {genre, template}`.
    case startSong
    /// `ProjectStore.applyTemplate(_:)` — `template.apply {template}`.
    case addToSong
}

/// Built-in or the person's own saved templates. Simple always shows built-ins.
public enum TemplatePickerTab: String, Sendable, Equatable, CaseIterable {
    case builtIn
    case saved

    public var title: String {
        switch self {
        case .builtIn: return TemplatePickerCopy.builtInTab
        case .saved: return TemplatePickerCopy.savedTab
        }
    }

    var source: TemplateSource {
        switch self {
        case .builtIn: return .builtIn
        case .saved: return .saved
        }
    }
}

/// The live song's facts the card depends on, read from the store by the model.
public struct TemplatePickerFacts: Sendable, Equatable {
    /// The song already has at least one track: "Add to my song" becomes primary.
    public var songHasTracks: Bool
    /// The transport is recording: a template that connects its tracks can't be
    /// added (`requireRoutingMutationAllowed`).
    public var isRecording: Bool
    /// The song's tempo now, to say whether "Start a song" would change it.
    public var tempoBPM: Double

    public init(songHasTracks: Bool, isRecording: Bool, tempoBPM: Double) {
        self.songHasTracks = songHasTracks
        self.isRecording = isRecording
        self.tempoBPM = tempoBPM
    }
}

/// What the STORE said about the selected template before anyone pressed —
/// `applyTemplate(_:dryRun: true)` for "Add to my song" and
/// `planSongSkeleton(genre:template:)` for "Start a song", the two dry runs the
/// wire's `dryRun: true` makes. Each refusal is the store's `errorDescription`,
/// verbatim.
public struct TemplatePickerPreflight: Sendable, Equatable {
    /// The template (id) and song style this was computed for — a stale
    /// preflight is never shown against another selection.
    public var templateID: String
    public var genre: String
    /// From `TemplateBuilder.plan` (pure): the template connects its tracks.
    /// Nil when the builder itself refused (then both refusals below say why).
    public var hasRouting: Bool?
    /// The "Start a song" dry run's refusal, or nil when it would succeed.
    public var startRefusal: String?
    /// The "Add to my song" dry run's refusal, or nil when it would succeed.
    public var addRefusal: String?
    /// The dry runs' warnings, deduplicated, in order (e.g. `audioUnitMissing`,
    /// `duplicateTrackNames`), plus the file's own reading warnings.
    public var warnings: [TemplateWarning]
    /// Every Audio Unit the template uses: its path in the template and its name.
    public var plugIns: [PlugIn]
    /// The tempo "Start a song" would set (the style's default), or nil when the
    /// style is unknown (the start refusal then says so).
    public var startTempoBPM: Double?

    public struct PlugIn: Sendable, Equatable {
        public var path: String
        public var name: String
        public init(path: String, name: String) {
            self.path = path
            self.name = name
        }
    }

    public init(templateID: String, genre: String, hasRouting: Bool?, startRefusal: String?,
                addRefusal: String?, warnings: [TemplateWarning], plugIns: [PlugIn],
                startTempoBPM: Double?) {
        self.templateID = templateID
        self.genre = genre
        self.hasRouting = hasRouting
        self.startRefusal = startRefusal
        self.addRefusal = addRefusal
        self.warnings = warnings
        self.plugIns = plugIns
        self.startTempoBPM = startTempoBPM
    }

    /// The paths the store's dry run reported as a plug-in this Mac lacks.
    public var missingPlugInPaths: Set<String> {
        Set(warnings.filter { $0.code == .audioUnitMissing }.map(\.path))
    }
}

/// One template tile (§9.2: name, one-sentence summary, a glyph row, "6 tracks").
public struct TemplatePickerTile: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let glyphs: [TemplateTrackGlyph]
    public let trackCountLabel: String
    public let source: TemplateSource
}

/// A file that could not be read, drawn greyed with its reason (§9.3, §7.3).
public struct TemplatePickerUnreadableTile: Sendable, Equatable, Identifiable {
    public var id: String { "\(source.rawValue):\(file)" }
    public let file: String
    public let source: TemplateSource
    public let reason: String
}

/// One button as the card draws it.
public struct TemplatePickerButton: Sendable, Equatable, Identifiable {
    public var id: TemplatePickerAction { action }
    public let action: TemplatePickerAction
    public let title: String
    /// The one-line caption under it (§9.2).
    public let explanation: String
    public let isPrimary: Bool
    public let isEnabled: Bool
    /// Why it is disabled, in words a person can act on; nil when enabled.
    public let disabledReason: String?
}

/// One line in the card's message slot.
public struct TemplatePickerMessage: Sendable, Equatable, Identifiable {
    public enum Tone: String, Sendable, Equatable {
        /// Amber: a refusal, a reason something is disabled, or a side effect to
        /// take care over (`PanelRefusalLine`'s semantics).
        case caution
        /// Secondary ink: information, nothing wrong.
        case info
    }

    public var id: String { "\(tone.rawValue):\(text)" }
    public let tone: Tone
    public let text: String
}

/// The Song style menu beside "Start a song" for a template with no song form
/// (§9.3): the 14 styles, set to the template's first genre, or Pop.
public struct TemplatePickerSongStyleMenu: Sendable, Equatable {
    public struct Option: Sendable, Equatable, Identifiable {
        public var id: String { genre }
        public let genre: String
        public let title: String
    }

    public let options: [Option]
    public let selectedGenre: String

    public var selectedTitle: String {
        options.first { $0.genre == selectedGenre }?.title ?? selectedGenre
    }
}

/// The whole card, as a value.
public struct TemplatePickerState: Sendable, Equatable {
    /// Every template on offer and every file that could not be read.
    public var listing: TemplateLibrary.Listing
    /// The person's tab (Pro only; Simple always shows built-ins).
    public var tab: TemplatePickerTab
    public var selectedID: String?
    public var isPro: Bool
    public var facts: TemplatePickerFacts
    /// The Song style the person picked from the menu, for the selected template;
    /// cleared when the selection changes.
    public var songStyleChoice: String?
    public var preflight: TemplatePickerPreflight?
    /// The store's refusal from the last press, verbatim; cleared on any change.
    public var pressRefusal: String?
    /// The last library operation's result (import, export, remove, save).
    public var libraryLine: TemplatePickerMessage?
    /// A saved template waiting for "Remove for Good".
    public var pendingRemovalID: String?

    public init(listing: TemplateLibrary.Listing, tab: TemplatePickerTab = .builtIn,
                selectedID: String? = nil, isPro: Bool = false, facts: TemplatePickerFacts,
                songStyleChoice: String? = nil, preflight: TemplatePickerPreflight? = nil,
                pressRefusal: String? = nil, libraryLine: TemplatePickerMessage? = nil,
                pendingRemovalID: String? = nil) {
        self.listing = listing
        self.tab = tab
        self.selectedID = selectedID
        self.isPro = isPro
        self.facts = facts
        self.songStyleChoice = songStyleChoice
        self.preflight = preflight
        self.pressRefusal = pressRefusal
        self.libraryLine = libraryLine
        self.pendingRemovalID = pendingRemovalID
    }

    // MARK: - Tiles

    /// The tab actually shown: Simple shows the built-ins only (§9.2).
    public var visibleTab: TemplatePickerTab { isPro ? tab : .builtIn }

    /// Pro only: the Built-in / My Templates switch.
    public var showsTabs: Bool { isPro }
    /// Pro only: Import, Export, Remove, Save as Template, and the detail pane.
    public var showsLibraryRow: Bool { isPro }
    public var showsDetail: Bool { isPro }

    /// The tiles of the visible tab, built-ins in catalog order, saved by file name.
    public var tiles: [TemplatePickerTile] {
        listing.templates.filter { $0.source == visibleTab.source }.map(Self.tile(for:))
    }

    /// The visible tab's unreadable files, greyed with their reason (§9.3).
    public var unreadableTiles: [TemplatePickerUnreadableTile] {
        listing.unreadable.filter { $0.source == visibleTab.source }.map {
            TemplatePickerUnreadableTile(file: $0.file, source: $0.source, reason: $0.message)
        }
    }

    /// The grid's cell count, for `TemplatePickerLayout`.
    public var gridCellCount: Int { tiles.count + unreadableTiles.count }

    /// My Templates is empty: the grid shows `TemplatePickerCopy.noSavedTemplates`.
    public var showsEmptySavedLine: Bool { visibleTab == .saved && gridCellCount == 0 }

    static func tile(for entry: TemplateLibrary.Entry) -> TemplatePickerTile {
        TemplatePickerTile(
            id: entry.id, name: entry.name, summary: entry.template.summary ?? "",
            glyphs: entry.template.tracks.compactMap(TemplateTrackGlyph.glyph(for:)),
            trackCountLabel: TemplatePickerCopy.trackCount(entry.template.tracks.count),
            source: entry.source)
    }

    /// The selected template, only if it is on the visible tab.
    public var selectedEntry: TemplateLibrary.Entry? {
        guard let selectedID else { return nil }
        return listing.templates.first { $0.id == selectedID && $0.source == visibleTab.source }
    }

    /// Which template to select when the card opens or the tab changes: the
    /// requested one if it is on the tab, else the tab's first.
    public func defaultSelection(preferring id: String?) -> String? {
        let ids = tiles.map(\.id)
        if let id, ids.contains(id) { return id }
        return ids.first
    }

    // MARK: - Song style (§9.3)

    /// The genre "Start a song" uses: the template's song form; for one with none,
    /// the person's menu choice, else its first catalog genre, else Pop.
    public var startGenre: String? {
        guard let template = selectedEntry?.template else { return nil }
        if let form = template.songForm { return form }
        if let songStyleChoice { return songStyleChoice }
        return template.genres.first { SongSkeletonCatalog.genre(named: $0) != nil } ?? "pop"
    }

    /// The menu, shown only for a template with no song form.
    public var songStyleMenu: TemplatePickerSongStyleMenu? {
        guard let template = selectedEntry?.template, template.songForm == nil,
              let genre = startGenre else { return nil }
        return TemplatePickerSongStyleMenu(
            options: SongSkeletonCatalog.v1.map { .init(genre: $0.name, title: $0.displayName) },
            selectedGenre: genre)
    }

    // MARK: - Buttons (§9.2, §9.3)

    /// The primary action: "Start a song" for an empty song, "Add to my song"
    /// once it has tracks (§9.3).
    public var primaryAction: TemplatePickerAction { facts.songHasTracks ? .addToSong : .startSong }

    /// The preflight, only if it was computed for what is selected now.
    public var currentPreflight: TemplatePickerPreflight? {
        guard let preflight, let entry = selectedEntry, preflight.templateID == entry.id,
              preflight.genre == startGenre else { return nil }
        return preflight
    }

    /// Why `action` can't run now, or nil. In order: nothing selected; recording
    /// with a template that connects its tracks (§9.3's own sentence); the
    /// store's dry-run refusal, verbatim.
    public func disabledReason(for action: TemplatePickerAction) -> String? {
        guard selectedEntry != nil else { return TemplatePickerCopy.pickOne }
        guard let preflight = currentPreflight else { return nil }
        if facts.isRecording && preflight.hasRouting == true { return TemplatePickerCopy.stopRecording }
        switch action {
        case .startSong: return preflight.startRefusal
        case .addToSong: return preflight.addRefusal
        }
    }

    /// Both buttons, secondary first and primary last (the macOS order: the
    /// default button sits at the trailing edge).
    public var buttons: [TemplatePickerButton] {
        let order: [TemplatePickerAction] = primaryAction == .startSong
            ? [.addToSong, .startSong] : [.startSong, .addToSong]
        return order.map { action in
            let reason = disabledReason(for: action)
            return TemplatePickerButton(
                action: action,
                title: action == .startSong ? TemplatePickerCopy.startSongTitle
                    : TemplatePickerCopy.addToSongTitle,
                explanation: action == .startSong ? TemplatePickerCopy.startSongExplanation
                    : TemplatePickerCopy.addToSongExplanation,
                isPrimary: action == primaryAction,
                isEnabled: reason == nil,
                disabledReason: reason)
        }
    }

    public func button(_ action: TemplatePickerAction) -> TemplatePickerButton? {
        buttons.first { $0.action == action }
    }

    // MARK: - The message slot (§9.3)

    /// Every line the card shows under the buttons, in order: the last press's
    /// refusal; why a button is disabled (once, when both say the same); what
    /// "Start a song" also changes in a song that has tracks; the plug-in
    /// notices; the store's other warnings, verbatim; the last library result.
    public var messages: [TemplatePickerMessage] {
        var lines: [TemplatePickerMessage] = []
        func add(_ tone: TemplatePickerMessage.Tone, _ text: String) {
            guard !lines.contains(where: { $0.text == text }) else { return }
            lines.append(TemplatePickerMessage(tone: tone, text: text))
        }
        if let pressRefusal { add(.caution, pressRefusal) }
        for action in [primaryAction, primaryAction == .startSong ? .addToSong : .startSong] {
            if let reason = disabledReason(for: action), reason != TemplatePickerCopy.pickOne {
                add(.caution, reason)
            }
        }
        if let preflight = currentPreflight {
            if facts.songHasTracks, preflight.startRefusal == nil, let tempo = preflight.startTempoBPM,
               !(facts.isRecording && preflight.hasRouting == true) {
                add(.caution, TemplatePickerCopy.startSongAlsoChanges(
                    tempoBPM: tempo, currentTempoBPM: facts.tempoBPM))
            }
            let missing = preflight.missingPlugInPaths
            for plugIn in preflight.plugIns {
                if missing.contains(plugIn.path) {
                    add(.caution, TemplatePickerCopy.plugInMissing(plugIn.name))
                } else {
                    add(.info, TemplatePickerCopy.usesPlugIn(plugIn.name))
                }
            }
            for warning in preflight.warnings where warning.code != .audioUnitMissing {
                add(.info, warning.message)
            }
        }
        if let libraryLine { add(libraryLine.tone, libraryLine.text) }
        return lines
    }

    // MARK: - Pro detail (§9.2)

    /// One plain line per track of the selected template.
    public var detailLines: [String] {
        guard isPro, let template = selectedEntry?.template else { return [] }
        return TemplatePickerCopy.detailLines(for: template)
    }

    /// Remove is offered for a SAVED template only (§9.2: "Remove (saved only)").
    public var canRemove: Bool { isPro && selectedEntry?.source == .saved }
    /// Export works for a built-in or a saved template.
    public var canExport: Bool { isPro && selectedEntry != nil }
}

// MARK: - Save as Template (§7.2, §9.1)

/// The Save as Template card, as a value: a name, the song's tracks with a tick
/// each, and the store's refusal when there is one.
public struct TemplateSaveSheetState: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let name: String
        public let kind: TrackKind
        public var isChecked: Bool

        public init(id: UUID, name: String, kind: TrackKind, isChecked: Bool) {
            self.id = id
            self.name = name
            self.kind = kind
            self.isChecked = isChecked
        }
    }

    public var name: String
    public var rows: [Row]
    /// `ProjectStore.saveTemplate`'s refusal, verbatim.
    public var refusal: String?
    /// Opened from the picker's Pro row: after saving, the picker comes back on
    /// My Templates with the new template selected. Opened from a track's menu:
    /// the card closes and a notice says where to find it.
    public var returnsToPicker: Bool

    public init(name: String = "", rows: [Row], refusal: String? = nil, returnsToPicker: Bool) {
        self.name = name
        self.rows = rows
        self.refusal = refusal
        self.returnsToPicker = returnsToPicker
    }

    /// The song's tracks, in song order, with `checked` ticked.
    public static func rows(for tracks: [Track], checked: Set<UUID>) -> [Row] {
        tracks.map { Row(id: $0.id, name: $0.name, kind: $0.kind, isChecked: checked.contains($0.id)) }
    }

    /// The ticked tracks, in song order — `template.save`'s `trackIds`.
    public var chosenTrackIDs: [UUID] { rows.filter(\.isChecked).map(\.id) }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why Save is disabled, or nil. Only the two things the card itself can
    /// see; every other rule (a name over 40 characters, too many tracks, a file
    /// too big) is the store's, and comes back as `refusal` in its words.
    public var disabledReason: String? {
        if rows.isEmpty { return TemplatePickerCopy.saveNoTracksInSong }
        if trimmedName.isEmpty { return TemplatePickerCopy.saveNeedsName }
        if chosenTrackIDs.isEmpty { return TemplatePickerCopy.saveNeedsTrack }
        return nil
    }

    public var canSave: Bool { disabledReason == nil }
}
