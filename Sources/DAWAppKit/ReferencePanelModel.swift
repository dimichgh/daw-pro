import Foundation
import Observation
import DAWCore

/// Headless state + copy for the **REFERENCE panel** and the master strip's
/// REFERENCE row (m22-g P3, design-m22g-reference-tracks §7.1/§7.2/§7.3).
///
/// The panel is a thin view over m22-g P1/P2 store state: this model owns the
/// panel's own state machine (empty / importing / analyzing / ready /
/// fileMissing), the plain-language derivations the two surfaces print, the
/// mix-spectrum average, and the VERBATIM surfacing of store refusals (the
/// one-vocabulary law — the panel never re-words a teaching error). Every
/// input arrives through injected closures (the `SketchpadModel` /
/// `VoicePanelModel` / `StereoScopeModel` precedent), so this file imports
/// only Foundation/Observation/DAWCore — no SwiftUI, and the whole surface is
/// unit-testable without a running app.
///
/// NO VIOLET anywhere downstream of this model: a reference is user-chosen
/// material, not AI content (DESIGN-LANGUAGE Rule 3). Cyan marks the earned
/// ACTIVE state (monitoring the reference), amber the honest ceiling clamp.
@MainActor
@Observable
public final class ReferencePanelModel {

    // MARK: - State machine (§7.3)

    public enum Phase: String, Sendable, Equatable, CaseIterable {
        /// No reference slot in the project — the import invitation.
        case empty
        /// A file copy + one-time analysis is running.
        case importing
        /// A re-analysis of the existing slot is running.
        case analyzing
        /// A slot is present and its file is on disk.
        case ready
        /// A slot is present but its file is gone (a moved/deleted import, or
        /// a project opened on another machine) — the slot and its stored
        /// analysis survive; monitoring refuses. Honest absence, never a
        /// silent drop (design §3.3).
        case fileMissing
    }

    /// What a running job is, so the view can say which one truthfully.
    public enum Busy: String, Sendable, Equatable {
        case importing, analyzing
    }

    // MARK: - Injected reads

    /// The project's reference slot (nil = none).
    public var slotProvider: () -> ReferenceSlot?
    /// `ProjectStore.referenceStatus()` — monitor state + match evidence.
    public var statusProvider: () -> ReferenceStatus
    /// The mix-vs-reference comparison, or nil when there is no evidence to
    /// compare (no slot, no analysis, no live meter). Resolved at the call
    /// site so the app can prefer a `debug.referenceSeed` staging override
    /// over the live polls (the `scopeSeed` idiom).
    public var compareProvider: () -> ReferenceCompareResult?
    /// Does the slot's file still exist? Injected (never a `FileManager` hit
    /// from a 5 Hz view tick): evaluated on open and after each action.
    public var fileExists: (String) -> Bool

    // MARK: - Injected actions (each routes to the SAME store method the
    // matching `reference.*` wire command calls — UI == wire by construction)

    public var importAction: (String) async throws -> Void
    public var analyzeAction: () async throws -> Void
    public var removeAction: () throws -> Void
    public var monitorAction: (Bool) throws -> Void
    public var offsetAction: (Double) throws -> Void
    public var trimAction: (Double) throws -> Void

    // MARK: - Panel state

    /// Whether the centered card is up. Owned here so `debug.referenceSeed
    /// {panel}` can stage it and tests can drive open/close.
    public private(set) var isOpen = false
    public private(set) var busy: Busy?
    /// The last store refusal, surfaced VERBATIM (the one-vocabulary law).
    public private(set) var refusal: String?
    /// In-row delete confirmation (the chat-delete idiom — never a system
    /// alert): REMOVE arms, a second press commits.
    public var confirmingRemove = false
    /// Cached file-presence answer for the current slot path.
    public private(set) var fileIsMissing = false

    /// The mix curve's running average — `@ObservationIgnored` scratch so the
    /// spectrum `TimelineView` can advance it inside its body without
    /// scheduling an invalidation (the `EQCurveEditorModel.spectrumHeights`
    /// precedent).
    @ObservationIgnored public let mixAverage = ReferenceSpectrumAverage()

    // MARK: - Stepper grain (§7.2 point 5)

    /// OFFSET grain: 0.1 s — coarse enough to walk a chorus into place in a
    /// few presses, fine enough to nail a downbeat by ear.
    public static let offsetStepSeconds = 0.1
    /// TRIM grain: 0.5 dB — the smallest level move most ears resolve on an
    /// A/B, and 48 presses cover the whole ±24 clamp.
    public static let trimStepDb = 0.5

    public init(
        slotProvider: @escaping () -> ReferenceSlot? = { nil },
        statusProvider: @escaping () -> ReferenceStatus = { ReferenceStatus() },
        compareProvider: @escaping () -> ReferenceCompareResult? = { nil },
        fileExists: @escaping (String) -> Bool = { _ in true },
        importAction: @escaping (String) async throws -> Void = { _ in },
        analyzeAction: @escaping () async throws -> Void = {},
        removeAction: @escaping () throws -> Void = {},
        monitorAction: @escaping (Bool) throws -> Void = { _ in },
        offsetAction: @escaping (Double) throws -> Void = { _ in },
        trimAction: @escaping (Double) throws -> Void = { _ in }
    ) {
        self.slotProvider = slotProvider
        self.statusProvider = statusProvider
        self.compareProvider = compareProvider
        self.fileExists = fileExists
        self.importAction = importAction
        self.analyzeAction = analyzeAction
        self.removeAction = removeAction
        self.monitorAction = monitorAction
        self.offsetAction = offsetAction
        self.trimAction = trimAction
    }

    // MARK: - Derived state

    public var slot: ReferenceSlot? { slotProvider() }
    public var status: ReferenceStatus { statusProvider() }
    public var isMonitoring: Bool { statusProvider().monitoring }

    public var phase: Phase {
        if let busy { return busy == .importing ? .importing : .analyzing }
        guard slotProvider() != nil else { return .empty }
        return fileIsMissing ? .fileMissing : .ready
    }

    /// True when the slot exists but was never successfully analyzed — the
    /// panel then offers ANALYZE instead of the numbers (a slot always lands,
    /// even if the analysis failed; design §3.4).
    public var needsAnalysis: Bool {
        guard let slot = slotProvider() else { return false }
        return slot.analysis == nil
    }

    // MARK: - Lifecycle

    public func open() {
        isOpen = true
        confirmingRemove = false
        refusal = nil
        mixAverage.reset()
        refreshFileState()
    }

    public func close() {
        isOpen = false
        confirmingRemove = false
        refusal = nil
        mixAverage.reset()
    }

    public func toggleOpen() {
        isOpen ? close() : open()
    }

    public func clearRefusal() { refusal = nil }

    /// Re-evaluates the slot file's presence (open, and after every action).
    public func refreshFileState() {
        guard let slot = slotProvider() else {
            fileIsMissing = false
            return
        }
        fileIsMissing = !fileExists(slot.sourcePath)
    }

    // MARK: - Actions (refusals surfaced verbatim, never re-worded)

    public func runImport(path: String) async {
        refusal = nil
        confirmingRemove = false
        busy = .importing
        do {
            try await importAction(path)
            mixAverage.reset()
        } catch {
            surface(error)
        }
        busy = nil
        refreshFileState()
    }

    public func runAnalyze() async {
        refusal = nil
        busy = .analyzing
        do {
            try await analyzeAction()
        } catch {
            surface(error)
        }
        busy = nil
        refreshFileState()
    }

    /// REMOVE is the one destructive verb: the first press arms the in-row
    /// confirmation, the second commits (never a system alert).
    public func requestRemove() {
        refusal = nil
        if confirmingRemove {
            confirmingRemove = false
            do {
                try removeAction()
                mixAverage.reset()
            } catch {
                surface(error)
            }
            refreshFileState()
        } else {
            confirmingRemove = true
        }
    }

    public func cancelRemove() { confirmingRemove = false }

    /// A/B: flips the monitor. The refusal ladder (`referenceNotSet` /
    /// `referenceNotAnalyzed` / `referenceSilent` / `referenceFileMissing` /
    /// `engineUnavailable`) reaches the user WORD FOR WORD.
    public func toggleMonitor() {
        setMonitor(!statusProvider().monitoring)
    }

    public func setMonitor(_ on: Bool) {
        refusal = nil
        do {
            try monitorAction(on)
        } catch {
            surface(error)
        }
        refreshFileState()
    }

    public func nudgeOffset(_ steps: Int) {
        guard let slot = slotProvider() else { return }
        applyOffset(slot.offsetSeconds + Double(steps) * Self.offsetStepSeconds)
    }

    public func applyOffset(_ seconds: Double) {
        refusal = nil
        // Kill float dust from repeated 0.1 s steps so the readout never
        // shows 0.30000000000000004.
        let rounded = (seconds * 1000).rounded() / 1000
        do { try offsetAction(rounded) } catch { surface(error) }
    }

    public func nudgeTrim(_ steps: Int) {
        guard let slot = slotProvider() else { return }
        applyTrim(slot.trimDb + Double(steps) * Self.trimStepDb)
    }

    public func applyTrim(_ db: Double) {
        refusal = nil
        let clamped = db.clamped(to: ReferenceSlot.trimRangeDb)
        do { try trimAction(clamped) } catch { surface(error) }
    }

    private func surface(_ error: any Error) {
        refusal = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
    }

    // MARK: - Spectrum feed

    /// One spectrum frame: advances the mix average toward the compare
    /// block's live bands and hands back both curves' band arrays (reference
    /// first). Either side is nil when it has no evidence — the view then
    /// draws only what it actually has.
    public func advanceSpectrum(deltaTime: Double)
        -> (reference: [Double]?, mix: [Double]?) {
        let compare = compareProvider()
        if let bands = compare?.mix.bandsDb {
            mixAverage.advance(toward: bands, deltaTime: deltaTime)
        }
        return (compare?.reference.bandsDb ?? slotProvider()?.analysis?.bandsDb,
                mixAverage.bandsDb)
    }
}

// MARK: - Copy + formatting (pure; the panel and the strip row share it)

extension ReferencePanelModel {

    /// The match-gain readout: a signed one-decimal dB number, or the honest
    /// dash when there is nothing to show. The view appends the dim "dB" unit
    /// (the `DbReadout` / GAIN REDUCTION voice) — never beside a dash.
    public static func matchGainText(_ db: Double?) -> String {
        guard let db, db.isFinite else { return "–" }
        let rounded = (db * 10).rounded() / 10
        if rounded == 0 { return "0.0" }
        return String(format: "%+.1f", rounded)
    }

    /// The plain-language basis line under the A/B cluster (§7.2 point 4).
    /// Order matters: the ceiling clamp is the loudest fact when it applies,
    /// because it is the one that changes what you hear.
    public static func basisLine(_ status: ReferenceStatus) -> String {
        if status.ceilingLimited == true {
            return "Turned down to protect your speakers — "
                + "the reference would have clipped at a full match."
        }
        switch status.matchBasis {
        case "liveIntegrated":
            return "Matched to your mix's loudness, so the louder-sounds-better "
                + "bias is out of the comparison."
        case "fallbackTarget":
            return "No mix loudness yet — the reference is matched to "
                + "−14 LUFS. Play your mix to match against it."
        default:
            if status.wouldMatchGainDb != nil {
                return "Press REF to hear the reference at your mix's loudness."
            }
            return "Analyze the reference to enable a level-matched comparison."
        }
    }

    /// Which match number a surface should print: the LIVE snapshot while
    /// monitoring, else the preview of what a toggle-ON would apply.
    public static func displayedMatchGainDb(_ status: ReferenceStatus) -> Double? {
        status.monitoring ? status.matchGainDb : status.wouldMatchGainDb
    }

    /// "3:42 · 44.1 kHz" — the loaded-state fact line (§7.2 point 3). An
    /// un-analyzed slot has no facts to print and says so.
    public static func fileFactsLine(_ analysis: ReferenceAnalysis?) -> String {
        guard let analysis else { return "Not analyzed yet" }
        return "\(durationText(analysis.durationSeconds)) · \(sampleRateText(analysis.sampleRateHz))"
    }

    /// "3:42" (m:ss, hours fold into minutes — a reference is a song).
    public static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "44.1 kHz" / "48 kHz" — trailing zeros trimmed.
    public static func sampleRateText(_ hz: Double) -> String {
        guard hz.isFinite, hz > 0 else { return "–" }
        let k = hz / 1000
        return k == k.rounded()
            ? "\(Int(k)) kHz"
            : String(format: "%.1f kHz", k)
    }

    /// OFFSET readout: signed seconds, two decimals ("+0.30 s", "0.00 s").
    public static func offsetText(_ seconds: Double) -> String {
        let rounded = (seconds * 100).rounded() / 100
        if rounded == 0 { return "0.00" }
        return String(format: "%+.2f", rounded)
    }

    /// TRIM readout: signed dB, one decimal.
    public static func trimText(_ db: Double) -> String {
        let rounded = (db * 10).rounded() / 10
        if rounded == 0 { return "0.0" }
        return String(format: "%+.1f", rounded)
    }

    // MARK: Delta row (§7.2 point 7)

    /// One DELTA cell: a label and its signed value text. Neutral by design —
    /// v1 ships NO green/red verdict, because a delta is information, not a
    /// judgment (a wider reference isn't a better one).
    public struct DeltaCell: Sendable, Equatable {
        public var label: String
        public var text: String
        /// The beginner gloss shown as the cell's tooltip.
        public var help: String

        public init(label: String, text: String, help: String) {
            self.label = label
            self.text = text
            self.help = help
        }
    }

    /// A signed delta, or "—" where the mix lacks evidence (the m22-c
    /// omission law rendered honestly: absence is shown, never floored to 0).
    public static func deltaText(_ value: Double?, decimals: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        let scale = pow(10.0, Double(decimals))
        let rounded = (value * scale).rounded() / scale
        if rounded == 0 { return decimals == 1 ? "0.0" : "0.00" }
        return String(format: "%+.\(decimals)f", rounded)
    }

    /// The five DELTA cells, in the design's order. Every value is
    /// `reference − mix`, so a POSITIVE number means the reference has more
    /// of it than your mix does.
    public static func deltaCells(_ delta: ReferenceCompareResult.Delta?) -> [DeltaCell] {
        [
            DeltaCell(label: "Δ LUFS", text: deltaText(delta?.lufs),
                      help: "How much louder the reference is overall than your mix."),
            DeltaCell(label: "Δ TRUE PEAK", text: deltaText(delta?.truePeakDb),
                      help: "How much higher the reference's loudest instant sits than your mix's."),
            DeltaCell(label: "Δ LRA", text: deltaText(delta?.lra),
                      help: "How much more the reference moves between its quiet and loud parts."),
            DeltaCell(label: "Δ WIDTH", text: deltaText(delta?.width, decimals: 2),
                      help: "How much wider the reference's stereo image is than your mix's."),
            DeltaCell(label: "Δ CORR", text: deltaText(delta?.correlation, decimals: 2),
                      help: "How much more mono-safe the reference is than your mix."),
        ]
    }

    /// The beginner sub-caption under the delta row (the m22-e
    /// plain-language convention). nil when the mix has no loudness evidence
    /// yet — silence beats a fabricated sentence.
    public static func deltaCaption(_ delta: ReferenceCompareResult.Delta?) -> String? {
        guard let lufs = delta?.lufs, lufs.isFinite else { return nil }
        let magnitude = (abs(lufs) * 10).rounded() / 10
        if magnitude < 0.1 {
            return "Your mix is sitting at the same loudness as the reference."
        }
        let direction = lufs > 0 ? "quieter than" : "louder than"
        return String(format: "Your mix is %.1f loudness units %@ the reference.",
                      magnitude, direction)
    }
}

// MARK: - Capture staging (`debug.referenceSeed`)

/// The `debug.referenceSeed` payload — a VIEW-SIDE override the REFERENCE row
/// and panel prefer over the live store polls, so a headless capture / E2E can
/// stage every §7.1/§7.2 state deterministically (the `debug.scopeSeed` /
/// `debug.grSeed` idiom). The STORE is never touched: seeding a slot here
/// creates no journaled edit, no dirty flag, and no undo entry — which is also
/// what makes an UNSEEDED capture meaningful evidence that the live polls tick.
public struct ReferenceSeed: Sendable, Equatable {
    /// The staged slot, or nil to stage the EMPTY state even though the
    /// project may hold a real one.
    public var slot: ReferenceSlot?
    /// The staged status (monitor state + match evidence).
    public var status: ReferenceStatus
    /// Staged mix-side loudness evidence — nil means "no live reading", which
    /// renders the honest dashes.
    public var mixLive: LiveLoudnessSnapshot?
    /// Staged mix-side spectrum/stereo evidence. nil falls through to the
    /// app's live poll (or `debug.vibeSeed`, the existing spectrum override).
    public var mixAnalysis: MasterAnalysisSnapshot?
    /// Stages the fileMissing phase without deleting anything on disk.
    public var fileMissing: Bool

    public init(slot: ReferenceSlot? = nil,
                status: ReferenceStatus = ReferenceStatus(),
                mixLive: LiveLoudnessSnapshot? = nil,
                mixAnalysis: MasterAnalysisSnapshot? = nil,
                fileMissing: Bool = false) {
        self.slot = slot
        self.status = status
        self.mixLive = mixLive
        self.mixAnalysis = mixAnalysis
        self.fileMissing = fileMissing
    }

    /// A plausible, fully-populated reference analysis for captures: a gentle
    /// low-tilt 24-band curve plus mastered-record loudness numbers. Pure
    /// arithmetic (no randomness), so a seeded capture is bit-identical every
    /// run — the `StereoScopePreset` determinism rule.
    public static func sampleAnalysis(integratedLufs: Double = -9.4,
                                      truePeakDbtp: Double = -0.9,
                                      loudnessRangeLu: Double = 5.2) -> ReferenceAnalysis {
        let bands = (0..<MasterAnalysisSnapshot.bandCount).map { index -> Double in
            // A −24 dB → −46 dB tilt with a small presence lift, so the curve
            // reads as music rather than a ramp.
            let t = Double(index) / Double(MasterAnalysisSnapshot.bandCount - 1)
            let tilt = -24.0 - 22.0 * t
            let presence = 4.0 * exp(-pow((t - 0.72) / 0.12, 2))
            return ((tilt + presence) * 10).rounded() / 10
        }
        return ReferenceAnalysis(
            integratedLufs: integratedLufs,
            maxMomentaryLufs: integratedLufs + 3.1,
            maxShortTermLufs: integratedLufs + 1.8,
            truePeakDbtp: truePeakDbtp,
            loudnessRangeLu: loudnessRangeLu,
            bandsDb: bands,
            correlation: 0.62,
            width: 0.34,
            balance: 0.01,
            durationSeconds: 222,
            sampleRateHz: 44_100,
            analyzerVersion: 1)
    }

    /// The mix-side spectrum companion to `sampleAnalysis` — the same shape a
    /// few dB down with less top end, so a seeded capture shows two curves
    /// that are clearly different but plausibly the same song.
    public static func sampleMixAnalysis() -> MasterAnalysisSnapshot {
        let reference = sampleAnalysis().bandsDb
        let bands = reference.enumerated().map { index, db -> Float in
            let t = Double(index) / Double(MasterAnalysisSnapshot.bandCount - 1)
            return Float(((db - 3.0 - 6.0 * t) * 10).rounded() / 10)
        }
        var snapshot = MasterAnalysisSnapshot.floor
        snapshot.bands = bands
        snapshot.levelDB = -12
        snapshot.peakDB = -6
        snapshot.centroidHz = 1800
        snapshot.flux = 0.25
        snapshot.correlation = 0.41
        snapshot.width = 0.52
        snapshot.balance = 0.0
        return snapshot
    }
}
