import Foundation
import Observation
import DAWCore

/// Headless state machine for the Quantize & Groove flow (m11-a): the musical
/// grid picker, the strength/swing sliders, the quantize-ends toggle, the groove
/// picker (built-in MPC swings + saved templates), and the extract-from-clip
/// affordance. No SwiftUI, no AppKit — the panel view is thin over this and the
/// tests drive it against injected closures (the `InstrumentPickerModel` /
/// `ClipFixModel` precedent: all logic here, testable without a window OR a store).
///
/// The model NEVER touches the store directly. It builds a `QuantizeSettings`
/// value the view hands to `ProjectStore.quantizeClipNotes` — the SAME method the
/// `clip.quantize` wire uses (one mutation path, never a parallel one). Data flows
/// IN through injected providers (`store.grooveTemplates`, `GrooveTemplate.builtin`,
/// `store.extractGroove`); fakes in tests.
///
/// GROOVE-WINS is surfaced HONESTLY (design contract, not a silent ignore): when a
/// groove is selected it governs BOTH the grid and the feel, so the model reports
/// `gridIsGrooveLocked`/`swingIsInert` and `buildSettings` uses the groove's own
/// grid — the view disables + explains the grid + swing rather than pretending they
/// still do something (docs/DESIGN-LANGUAGE.md "Quantize panel").
///
/// NO VIOLET anywhere in the flow — quantize is standard editing chrome, not
/// AI-generated content (docs/DESIGN-LANGUAGE.md Rule 3: violet is AI identity
/// only). Cyan marks only earned active state (the selected groove, the readouts).
@MainActor
@Observable
public final class QuantizeModel {
    // MARK: - Injected providers

    /// The project's SAVED groove templates (wired to `ProjectStore.grooveTemplates`;
    /// a fixed array in tests). Read fresh each access so an extract shows up live.
    private let savedGroovesProvider: () -> [GrooveTemplate]
    /// Applies a built `QuantizeSettings` to the target clip (wired to
    /// `ProjectStore.quantizeClipNotes` — ONE undo step via its `clip.quantize:<id>`
    /// coalescing key; a recorder in tests). MIDI-only, matching the store method.
    private let applyClosure: (UUID, QuantizeSettings) -> Void
    /// Extracts a groove from the target clip and appends it to the palette (wired
    /// to `ProjectStore.extractGroove`; async because an audio clip detects
    /// transients on the engine). Args: clipID, name, gridBeats, cycleBeats.
    private let extractClosure: (UUID, String, Double, Double) async throws -> GrooveTemplate

    /// The built-in MPC swing presets (`GrooveTemplate.builtinNames` resolved), shown
    /// at the top of the groove picker. Injected so the app passes the canonical set
    /// and a test can pass a fixed one; never persisted (computed on demand).
    public let builtinGrooves: [GrooveTemplate]

    // MARK: - Target context (the clip being quantized)

    /// The clip the flow acts on; nil until `prepare`.
    public private(set) var targetClipID: UUID?
    /// The target clip's name — the panel header + the default extract name.
    public private(set) var targetClipName: String = ""
    /// True for a MIDI clip (note quantize applies), false for audio. Note quantize
    /// is MIDI-only (matching `ProjectStore.quantizeClipNotes`); an audio target
    /// shows only the extract affordance (`groove.extract` supports both).
    public private(set) var targetIsMIDI: Bool = true

    // MARK: - Density (synced from the panel's SimpleProToggle; tests set directly)

    /// Simple = grid + strength only. Pro = adds swing, quantize-ends, the groove
    /// picker, and the extract affordance (design decision, docs/simple-pro-inventory).
    public var density: PanelDensity = .simple

    // MARK: - Settings state

    /// Index into `Self.grids` — the picked musical grid (1/4 … 1/64). The
    /// picker is inert while a groove is selected (the groove defines the grid).
    /// Raw here; `grid` reads it clamped, so a stray index can never crash the view.
    public var gridIndex: Int = QuantizeModel.defaultGridIndex
    /// How far each onset moves toward the grid, `0...1` (1 = snap fully, 0 = leave).
    /// Raw here; `buildSettings` clamps it, so the built settings are always valid.
    public var strength: Double = 1.0
    /// MPC swing, `50...75` (50 = straight). Inert while a groove is selected. Raw
    /// here; `buildSettings` clamps it (below 50 reads straight, above 75 pinned).
    public var swingPercent: Double = 50
    /// MIDI only: also snap note ENDS to the grid (Pro).
    public var quantizeEnds: Bool = false

    /// The selected groove template (a built-in swing OR a saved template), by
    /// value — nil = the straight/swing grid. Captured by value so it keeps working
    /// even if the saved template is later removed (the store's by-value rule).
    public private(set) var selectedGroove: GrooveTemplate?

    // MARK: - Extract affordance state

    /// Whether the "Extract from this clip" name field is revealed.
    public var isExtractExpanded: Bool = false
    /// The name for the extracted template (defaults from the clip name).
    public var extractName: String = ""
    /// Set when an extract throws — shown inline; cleared on the next attempt.
    public private(set) var extractError: String?
    /// True while an extract is in flight (an audio clip awaits transient detection).
    public private(set) var isExtracting: Bool = false

    public init(
        builtinGrooves: [GrooveTemplate],
        savedGrooves: @escaping () -> [GrooveTemplate],
        apply: @escaping (UUID, QuantizeSettings) -> Void,
        extract: @escaping (UUID, String, Double, Double) async throws -> GrooveTemplate
    ) {
        self.builtinGrooves = builtinGrooves
        self.savedGroovesProvider = savedGrooves
        self.applyClosure = apply
        self.extractClosure = extract
    }

    // MARK: - Lifecycle

    /// Points the flow at a clip and resets the transient navigation (groove
    /// selection, extract field, errors) — but KEEPS the grid/strength/swing/ends
    /// settings, so re-opening the panel on another clip remembers the last feel
    /// (a per-session sticky, the piano-roll snap idiom). Density is set separately
    /// by the view from the shared store.
    public func prepare(clipID: UUID, clipName: String, isMIDI: Bool) {
        targetClipID = clipID
        targetClipName = clipName
        targetIsMIDI = isMIDI
        selectedGroove = nil
        isExtractExpanded = false
        extractName = ""
        extractError = nil
        isExtracting = false
    }

    // MARK: - Grid catalog

    /// One musical grid resolution: a beginner-readable name over the beats value
    /// `QuantizeSettings.gridBeats` expects (quarter note = 1 beat). Triplets are
    /// the 2/3-scaled values documented on `QuantizeSettings.gridBeats`.
    public struct MusicalGrid: Equatable, Sendable, Identifiable {
        public let label: String
        public let beats: Double
        public var id: String { label }
        public init(label: String, beats: Double) { self.label = label; self.beats = beats }
    }

    /// The picker's grid options, coarsest → finest (with triplets interleaved).
    public static let grids: [MusicalGrid] = [
        MusicalGrid(label: "1/4", beats: 1.0),
        MusicalGrid(label: "1/4 triplet", beats: 2.0 / 3.0),
        MusicalGrid(label: "1/8", beats: 0.5),
        MusicalGrid(label: "1/8 triplet", beats: 1.0 / 3.0),
        MusicalGrid(label: "1/16", beats: 0.25),
        MusicalGrid(label: "1/16 triplet", beats: 1.0 / 6.0),
        MusicalGrid(label: "1/32", beats: 0.125),
        MusicalGrid(label: "1/64", beats: 0.0625),
    ]

    /// Default grid: 1/16 — the common beat-programming quantize default (also the
    /// `groove.extract` / `clip.quantize` fixture grid).
    public static let defaultGridIndex: Int = 4

    /// The currently PICKED grid (ignores the groove lock — `effectiveGridBeats`
    /// applies that). Clamped, so a bad index can never crash the view.
    public var grid: MusicalGrid { Self.grids[gridIndex.clamped(to: 0...(Self.grids.count - 1))] }

    /// The grid the built settings actually use: the groove's own grid when a
    /// groove is selected (groove-wins, musically correct — the store's documented
    /// expectation that `groove.gridBeats == gridBeats`), else the picked grid.
    public var effectiveGridBeats: Double { selectedGroove?.gridBeats ?? grid.beats }

    /// The grid label to DISPLAY — the groove's grid name while locked, else the
    /// picked grid's label.
    public var effectiveGridLabel: String {
        if let groove = selectedGroove { return Self.gridLabel(forBeats: groove.gridBeats) }
        return grid.label
    }

    /// A groove selected → the grid is defined by the groove, so the picker is inert
    /// (disabled + explained, never silently ignored — the groove-wins honesty rule).
    public var gridIsGrooveLocked: Bool { selectedGroove != nil }
    /// A groove selected → swing is replaced by the groove's per-slot offsets, so the
    /// swing slider is inert (disabled + explained — the design contract).
    public var swingIsInert: Bool { selectedGroove != nil }

    /// The nearest musical grid name for a beats value (for displaying a groove's
    /// grid); falls back to a compact numeric form for an off-catalog value.
    public static func gridLabel(forBeats beats: Double) -> String {
        if let match = grids.first(where: { abs($0.beats - beats) < 1e-6 }) { return match.label }
        return String(format: "%.3g beats", beats)
    }

    // MARK: - Groove picker

    /// The SAVED groove templates (read fresh, so an extract appears immediately).
    public var savedGrooves: [GrooveTemplate] { savedGroovesProvider() }

    /// Selects a groove (or nil = the straight/swing grid). Selecting a groove makes
    /// the grid + swing inert (groove-wins).
    public func selectGroove(_ groove: GrooveTemplate?) { selectedGroove = groove }

    /// Whether `groove` is the current selection. Compared by VALUE, not id — full
    /// value equality (name + grid + offsets). The DAWCore built-in-id hash
    /// collision that originally forced this (the whole `swing8` family shared one
    /// id) is FIXED in m11-g, but value comparison is kept as defensive keying: it
    /// never depends on the id derivation and correctly distinguishes any two
    /// grooves (built-in or saved) regardless of how ids are computed.
    public func isGrooveSelected(_ groove: GrooveTemplate) -> Bool {
        selectedGroove == groove
    }

    /// The display title + detail for a built-in swing preset, from its reserved
    /// name (`"swing8:66"` → "1/8 Swing" · "66%"). A saved template just shows its
    /// own `name`; this is only the built-in formatter.
    public static func builtinDisplay(_ groove: GrooveTemplate) -> (title: String, detail: String) {
        let raw = groove.name
        if raw.hasPrefix("swing8:") {
            return ("1/8 Swing", raw.dropFirst("swing8:".count) + "%")
        } else if raw.hasPrefix("swing16:") {
            return ("1/16 Swing", raw.dropFirst("swing16:".count) + "%")
        }
        return (raw, "")
    }

    // MARK: - Settings build + apply

    /// The `QuantizeSettings` the current state produces — the value the view hands
    /// straight to `ProjectStore.quantizeClipNotes` (the wire's method). Density
    /// gates the Pro-only fields HONESTLY: in Simple the built value carries no
    /// swing / groove / end-snap, so what a beginner sees is exactly what applies.
    public func buildSettings() -> QuantizeSettings {
        let s = strength.clamped(to: 0...1)
        let swing = swingPercent.clamped(to: 50...75)
        // Simple: grid + strength only (straight, no groove, ends kept verbatim).
        guard density == .pro else {
            return QuantizeSettings(gridBeats: grid.beats, strength: s)
        }
        // Groove wins: it governs the grid AND the feel (its per-slot offsets replace
        // swing). Strength still controls how far notes move toward the groove targets.
        if let groove = selectedGroove {
            return QuantizeSettings(gridBeats: groove.gridBeats, strength: s,
                                    swingPercent: 50, quantizeEnds: quantizeEnds, groove: groove)
        }
        return QuantizeSettings(gridBeats: grid.beats, strength: s,
                                swingPercent: swing, quantizeEnds: quantizeEnds)
    }

    /// Applies the built settings to the target clip through the injected apply
    /// closure (`ProjectStore.quantizeClipNotes`) — ONE undo step. A no-op with no
    /// target. Note-quantize is MIDI-only, so audio targets never reach here (the
    /// view hides Apply for audio); the guard keeps it safe regardless.
    public func apply() {
        guard let clipID = targetClipID, targetIsMIDI else { return }
        applyClosure(clipID, buildSettings())
    }

    // MARK: - Extract affordance

    /// The default name for an extracted groove, seeded from the clip name.
    public var defaultExtractName: String {
        let trimmed = targetClipName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Groove" : "\(trimmed) Groove"
    }

    /// Reveals the extract name field, seeding the default name once.
    public func beginExtract() {
        isExtractExpanded = true
        extractError = nil
        if extractName.trimmingCharacters(in: .whitespaces).isEmpty {
            extractName = defaultExtractName
        }
    }

    /// Collapses the extract affordance (Cancel).
    public func cancelExtract() {
        isExtractExpanded = false
        extractError = nil
    }

    /// Whether the extract button can fire — a target + a non-blank name + not
    /// already extracting.
    public var canExtract: Bool {
        targetClipID != nil
            && !extractName.trimmingCharacters(in: .whitespaces).isEmpty
            && !isExtracting
    }

    /// Extracts a groove from the target clip (grid 1/16, one-bar cycle — the store
    /// defaults), appends it to the palette, and AUTO-SELECTS it so the just-made
    /// feel is what applies. On failure sets `extractError` for the inline alert.
    /// The new template appears in `savedGrooves` via the provider immediately.
    public func extract() async {
        guard let clipID = targetClipID else { return }
        let name = extractName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { extractError = "Name the groove first."; return }
        extractError = nil
        isExtracting = true
        defer { isExtracting = false }
        do {
            let template = try await extractClosure(clipID, name, Self.extractGridBeats, Self.extractCycleBeats)
            selectedGroove = template
            isExtractExpanded = false
        } catch {
            extractError = Self.message(from: error)
        }
    }

    /// Extract defaults, matching `ProjectStore.extractGroove` (1/16 grid, one bar
    /// at x/4). Kept here so the model + the store agree without a wire round-trip.
    public static let extractGridBeats: Double = 0.25
    public static let extractCycleBeats: Double = 4.0

    private nonisolated static func message(from error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }
}
