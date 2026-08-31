import Foundation
import Observation
import DAWCore
// m34-c: the one-click SoundFont download lives in AIServices (the
// external-services module — network clients live there, per Package.swift).
// DAWAppKit already depends on it; the model only ever holds CLOSURES over the
// shared coordinator, never constructs one, so a test drives this surface with
// no network and no actor.
import AIServices

/// Headless state machine for the instrument picker (m10-n-3): the three-section
/// browser (Built-in / Sound Banks / Audio Units), the GM program browser with
/// category grouping + search, the Simple-density "Instrument Sets" mapping, and
/// the single `InstrumentChoice` value a selection produces. No SwiftUI, no
/// AppKit — the view is thin over this and the tests drive it against injected
/// data providers (the `ClipFixModel`/`PanelDensityStore` precedent: all logic
/// here, testable without a window OR a store).
///
/// The model NEVER touches the store: it produces an `InstrumentChoice` that the
/// VIEW hands to `ProjectStore.setInstrument` — the SAME one-command surface the
/// wire uses (design §7). Data flows IN through injected providers
/// (`ProjectStore.availableSoundBanks` / `soundBankPrograms` /
/// `availableAudioUnits` / `importSoundBank` in the app; fakes in tests), so the
/// model stays off the engine bridge.
///
/// NO VIOLET anywhere in the picker — it is standard chrome, not AI-generated
/// content (docs/DESIGN-LANGUAGE.md Rule 3: violet is AI identity only).
@MainActor
@Observable
public final class InstrumentPickerModel {
    // MARK: - Injected data providers

    /// Discoverable sound banks, GM first (wired to `ProjectStore.availableSoundBanks`).
    private let soundBanksProvider: () -> [SoundBankInfo]
    /// The program listing for a bank source (wired to `ProjectStore.soundBankPrograms`,
    /// its throw swallowed at the app boundary → `([], false)` for a missing bank —
    /// the picker never errors on a resolvable-but-empty bank).
    private let programsProvider: (SoundBankSource) -> (programs: [SoundBankProgram], namesParsed: Bool)
    /// Installed Audio Unit music devices (wired to `ProjectStore.availableAudioUnits`).
    private let audioUnitsProvider: () -> [AudioUnitComponentInfo]
    /// Copies a `.sf2`/`.dls` into the central library, or CONVERTS a `.sf3`
    /// into one on the way in (m31-h; wired to
    /// `ProjectStore.importSoundBank`); throws in the MediaImporting tone.
    private let bankImporter: (URL) throws -> SoundBankInfo

    // MARK: Download providers (m34-c) — all optional

    /// The downloadable-bank catalogue with per-bank "already installed"
    /// (wired to `SoundBankDownloadCoordinator.offerings`).
    ///
    /// ⚠️ ALL FOUR download providers default to nil, and nil means the
    /// download affordance is simply ABSENT rather than broken. That keeps
    /// every existing construction of this model — and every test that
    /// predates m34-c — compiling and behaving exactly as before, which is
    /// the additive rule applied to an initializer.
    private let downloadableBanksProvider: (() -> [SoundBankOffering])?
    /// Starts a download and returns the accepted status (wired to the SHARED
    /// `SoundBankDownloadCoordinator.start`, the same actor the wire uses).
    private let startDownloadProvider: ((String) async throws -> SoundBankDownloadStatus)?
    /// Reads the current status (wired to the same actor's `status`).
    private let downloadStatusProvider: (() async -> SoundBankDownloadStatus)?
    /// Requests a cancel (wired to the same actor's `cancel`).
    private let cancelDownloadProvider: (() async throws -> SoundBankDownloadStatus)?

    // MARK: - Loaded data (refreshed from the providers)

    /// The discovered sound banks — GM first, then imported/scanned (§6.2 order).
    public private(set) var banks: [SoundBankInfo] = []
    /// Installed AU instruments — search is essential at 64 entries (§7).
    public private(set) var audioUnits: [AudioUnitComponentInfo] = []

    // MARK: - Target context (the track the picker is choosing an instrument for)

    /// The track being edited; nil until `prepare`. The view hands the produced
    /// choice back with this id.
    public private(set) var targetTrackID: UUID?
    /// The track's CURRENT instrument descriptor — drives the "current selection"
    /// highlight and the chip's display name. nil = no instrument yet (default).
    public private(set) var currentDescriptor: InstrumentDescriptor?
    /// The hosted-instrument lifecycle status for the current soundBank/audioUnit
    /// selection (nil for built-ins / when the engine tracks none). The row + chip
    /// show `.pending` as a subtle loading affordance and `.failed(reason)`
    /// verbatim (design §7 — honest states, never a spinner takeover).
    public var currentStatus: AudioUnitTrackStatus?

    // MARK: - Density (synced from the picker's SimpleProToggle; tests set directly)

    /// Simple = the curated "Instrument Sets" (the 16 GM categories, each → its
    /// first program) + Poly Synth / Sampler + a flat AU list. Pro = the full
    /// browser (built-ins incl. Test Tone, the bank list → program browser with
    /// raw program/MSB/LSB, AU search). Design §7.
    public var density: PanelDensity = .simple

    // MARK: - Interaction state

    /// The single search field — spans EVERY visible section (built-ins, banks or
    /// Instrument Sets, AUs; the program list while a bank is drilled in). At 64
    /// AUs this is essential (§7). Case-insensitive substring.
    public var searchText: String = ""

    /// The bank whose program browser is open (Pro only); nil = the bank list.
    public private(set) var drilledBankSource: SoundBankSource?
    /// The drilled bank's info (for the browser header + display-name suffix).
    public private(set) var drilledBank: SoundBankInfo?
    private var drilledProgramsRaw: [SoundBankProgram] = []
    /// Whether the drilled bank's program names are real (GM/parsed SF2) or the
    /// generic "Program N" fallback — the browser tells the user honestly.
    public private(set) var drilledNamesParsed: Bool = true
    /// Program-browser categories the user has collapsed (Pro). A category not in
    /// the set is expanded (the default).
    public private(set) var collapsedCategories: Set<String> = []

    // MARK: - Import feedback

    /// Set when an `importBank` throws — the Sound Banks section shows it in an
    /// inline alert. Cleared on the next import attempt or `clearImportError`.
    public private(set) var importError: String?

    /// Sample-library import outcome (m19-c): the honest "imported, but…"
    /// summary — zone/layer/group counts plus the report's degradation
    /// sentences — shown as a NEUTRAL inline notice under the Built-in
    /// section (degradations are facts, not failures, so they never wear the
    /// red error chrome). Cleared on `prepare` or `clearImportNotice`.
    public private(set) var importNotice: String?

    public init(
        soundBanks: @escaping () -> [SoundBankInfo],
        programs: @escaping (SoundBankSource) -> (programs: [SoundBankProgram], namesParsed: Bool),
        audioUnits: @escaping () -> [AudioUnitComponentInfo],
        importer: @escaping (URL) throws -> SoundBankInfo,
        downloadableBanks: (() -> [SoundBankOffering])? = nil,
        startDownload: ((String) async throws -> SoundBankDownloadStatus)? = nil,
        downloadStatus: (() async -> SoundBankDownloadStatus)? = nil,
        cancelDownload: (() async throws -> SoundBankDownloadStatus)? = nil
    ) {
        self.soundBanksProvider = soundBanks
        self.programsProvider = programs
        self.audioUnitsProvider = audioUnits
        self.bankImporter = importer
        self.downloadableBanksProvider = downloadableBanks
        self.startDownloadProvider = startDownload
        self.downloadStatusProvider = downloadStatus
        self.cancelDownloadProvider = cancelDownload
    }

    // MARK: - Lifecycle

    /// Reloads the bank + AU lists from the providers (cheap file/registry reads).
    /// Called by `prepare` and after an import.
    public func refresh() {
        banks = soundBanksProvider()
        audioUnits = audioUnitsProvider()
    }

    /// `refresh()` plus the download catalogue — what `prepare` calls. Kept
    /// separate from `refresh()` itself because `pollUntilTerminal` calls both
    /// deliberately and a self-call would be circular.
    private func refreshAll() {
        refresh()
        refreshDownloadableBanks()
    }

    /// Points the picker at a track: records its current instrument (for the
    /// highlight + status), reloads the lists, and resets the navigation (search,
    /// drill, collapse, import error). `density` is set separately by the view
    /// from the shared density store.
    public func prepare(trackID: UUID, descriptor: InstrumentDescriptor?,
                        status: AudioUnitTrackStatus?) {
        targetTrackID = trackID
        currentDescriptor = descriptor
        currentStatus = status
        searchText = ""
        drilledBankSource = nil
        drilledBank = nil
        drilledProgramsRaw = []
        drilledNamesParsed = true
        collapsedCategories = []
        importError = nil
        importNotice = nil
        downloadRequestError = nil
        refreshAll()
        // A download may already be running — started from the wire, or from a
        // previous visit to this panel — and one may START while this panel is
        // open, so this WATCHES rather than reads once.
        beginWatchingDownloads()
    }

    /// Updates ONLY the current-instrument highlight + status after a selection
    /// applies, WITHOUT resetting the navigation (search / drilled bank / collapse)
    /// — so the user can keep browsing/comparing programs while the highlight moves.
    public func updateCurrent(descriptor: InstrumentDescriptor?, status: AudioUnitTrackStatus?) {
        currentDescriptor = descriptor
        currentStatus = status
    }

    // MARK: - Built-in section

    /// Built-in engine instruments. Simple hides Test Tone (an engine-verify
    /// instrument a beginner never reaches for); Pro shows all three (design §7).
    public var builtIns: [BuiltInInstrument] {
        var list: [BuiltInInstrument] = [
            BuiltInInstrument(kind: .polySynth, name: "Poly Synth",
                              detail: "Built-in synthesizer — warm, tunable tones."),
            BuiltInInstrument(kind: .sampler, name: "Sampler",
                              detail: "Plays your own audio files across the keys."),
        ]
        if density == .pro {
            list.append(BuiltInInstrument(kind: .testTone, name: "Test Tone",
                                          detail: "A steady reference note for checking your setup."))
        }
        return list.filter { Self.matches($0.name, query: searchText) }
    }

    // MARK: - Sound Banks section

    /// The bank list (Pro), filtered by search. GM first (provider order).
    /// Includes DISCOVERED-BUT-UNSUPPORTED banks (m31-g) — they are shown,
    /// badged, and not drillable; hiding them is the defect.
    public var filteredBanks: [SoundBankInfo] {
        banks.filter { Self.matches($0.name, query: searchText) }
    }

    /// The Simple-density "Instrument Sets": the 16 GM categories (each → its
    /// first program: Piano→0, Brass→56, …) plus "Drums" (120/0) — the curated,
    /// zero-detail entry point (design §7). GM-backed, so universal. Filtered by
    /// search on the set name.
    public var instrumentSets: [InstrumentSet] {
        Self.allInstrumentSets.filter { Self.matches($0.name, query: searchText) }
    }

    /// Drills into a bank's program browser (Pro): loads its programs, resets the
    /// browser search + collapse. A no-op-safe call for any bank.
    /// ⛔ m31-g: an UNSUPPORTED bank (a discovered `.sf3`) is listed so the
    /// user can see it exists, but must never become a selection — drilling in
    /// would offer programs that cannot load. It is refused here, and refused
    /// LOUDLY: the reason goes to the same inline alert an import failure uses,
    /// because a click that silently does nothing is this very defect wearing
    /// a different hat.
    public func drillInto(_ bank: SoundBankInfo) {
        if let reason = bank.unsupportedReason {
            importError = reason
            return
        }
        importError = nil
        let listing = programsProvider(bank.source)
        drilledBankSource = bank.source
        drilledBank = bank
        drilledProgramsRaw = listing.programs
        drilledNamesParsed = listing.namesParsed
        collapsedCategories = []
        searchText = ""
    }

    /// Returns to the bank list from the program browser.
    public func drillOut() {
        drilledBankSource = nil
        drilledBank = nil
        drilledProgramsRaw = []
        searchText = ""
    }

    /// True while a bank's program browser is open.
    public var isDrilledIn: Bool { drilledBankSource != nil }

    /// The drilled bank's programs grouped by category, in program order, each
    /// carrying its collapse state — the program browser's rows (Pro). Search
    /// filters programs by name across all categories; a category with no
    /// surviving programs drops out. The GM "Drum Kits" group (bankMSB 120) rides
    /// this naturally (it is one of the categories). A program with an empty
    /// category (unparsed SF2/DLS) lands in a trailing "Programs" group.
    public var programGroups: [ProgramGroup] {
        let query = searchText
        var order: [String] = []
        var buckets: [String: [SoundBankProgram]] = [:]
        for program in drilledProgramsRaw {
            guard Self.matches(program.name, query: query) else { continue }
            let category = program.category.isEmpty ? "Programs" : program.category
            if buckets[category] == nil { order.append(category); buckets[category] = [] }
            buckets[category]?.append(program)
        }
        return order.map { category in
            ProgramGroup(category: category, programs: buckets[category] ?? [],
                         isCollapsed: collapsedCategories.contains(category))
        }
    }

    /// Toggles a program-browser category open/closed.
    public func toggleCategory(_ category: String) {
        if collapsedCategories.contains(category) {
            collapsedCategories.remove(category)
        } else {
            collapsedCategories.insert(category)
        }
    }

    // MARK: - Audio Units section

    /// Installed AU instruments, filtered by search across `name` +
    /// `manufacturerName` (mandatory at 64 entries — no pagination, §7).
    public var filteredAudioUnits: [AudioUnitComponentInfo] {
        audioUnits.filter {
            Self.matches($0.name, query: searchText) || Self.matches($0.manufacturerName, query: searchText)
        }
    }

    // MARK: - Import

    /// Imports a `.sf2`/`.dls` — or a `.sf3`, converted on the way in (m31-h) —
    /// into the central library, refreshes the bank list,
    /// and returns the new bank (so the view can drill straight into it). On
    /// failure sets `importError` for the inline alert and returns nil.
    @discardableResult
    public func importBank(from url: URL) -> SoundBankInfo? {
        importError = nil
        do {
            let info = try bankImporter(url)
            refresh()
            return info
        } catch {
            importError = Self.message(from: error)
            return nil
        }
    }

    /// Clears the inline import error.
    public func clearImportError() { importError = nil }

    /// Presents a sample-library import outcome inline (m19-c): exactly one
    /// of `notice` (imported — the report summary) or `error` (refused — the
    /// structured import error's message) at a time, mirroring how a fresh
    /// `importBank` attempt replaces the previous error. The model stays
    /// store-free — the app's panel flow computes both strings.
    public func presentSampleLibraryOutcome(notice: String?, error: String?) {
        importNotice = notice
        importError = error
    }

    /// Clears the inline sample-library notice.
    public func clearImportNotice() { importNotice = nil }

    // MARK: - Downloadable banks (m34-c)

    /// True when this build was given the download providers at all. The view
    /// hides the whole affordance when false rather than showing a button that
    /// cannot work.
    public var canDownloadBanks: Bool { downloadableBanksProvider != nil }

    /// Banks that are NOT already in the library — the only ones worth
    /// offering. An installed one would be refused by the installer, so
    /// offering it would be an invitation to a refusal.
    public var downloadableBanks: [SoundBankOffering] {
        downloadOfferings.filter { !$0.isInstalled }
    }

    /// The live download status, nil before anything has ever been read.
    public private(set) var downloadStatus: SoundBankDownloadStatus?

    /// Set when `startDownload`/`cancelDownload` itself is REFUSED (an unknown
    /// id, a second download while one runs, nothing to cancel). Distinct from
    /// a FAILED download, which arrives through `downloadStatus.errorMessage`
    /// — the first never started, the second stopped partway, and telling a
    /// user the wrong one wastes their time.
    public private(set) var downloadRequestError: String?

    /// The bank currently being downloaded, if any — for the row's own label.
    public var downloadingBank: SoundBankOffering? {
        guard let id = downloadStatus?.bankID,
              downloadStatus?.state == .downloading else { return nil }
        return downloadOfferings.first { $0.id == id }
    }

    /// One beginner-readable sentence for the current download state, or nil
    /// when there is nothing to say. ⭐ Plain language, never a percentage on
    /// its own: "Downloading 88 MB of 206 MB" tells a beginner what is
    /// happening; "43%" tells them a number.
    public var downloadStatusLine: String? {
        guard let status = downloadStatus else { return nil }
        let name = status.bankName ?? "the sound bank"
        switch status.state {
        case .idle:
            return nil
        case .downloading:
            if status.cancelRequested { return "Stopping…" }
            guard let progress = status.progress else { return "Starting…" }
            switch progress.phase {
            case .preparing:
                return "Getting ready…"
            case .downloading:
                let done = Self.megabytes(progress.completedBytes)
                let total = Self.megabytes(progress.totalBytes)
                return "Downloading \(done) of \(total)…"
            case .verifying:
                return "Checking the download…"
            case .installing:
                return "Adding \(name) to your instruments…"
            case .finished:
                return "Finishing up…"
            }
        case .succeeded:
            return "\(name) is ready — pick a sound below."
        case .failed:
            return status.errorMessage
        case .cancelled:
            return "Download stopped. Nothing was added."
        }
    }

    /// 0…1 for a progress bar, or nil when there is no measurable transfer to
    /// draw. Deliberately the TRANSFER's fraction only: the verify and install
    /// phases have no honest fraction, and inventing one is how a progress bar
    /// starts lying.
    public var downloadFraction: Double? {
        guard downloadStatus?.state == .downloading,
              let progress = downloadStatus?.progress,
              progress.phase == .downloading,
              progress.totalBytes > 0 else { return nil }
        return min(1, max(0, Double(progress.completedBytes) / Double(progress.totalBytes)))
    }

    /// THE size arithmetic, shared with the catalogue's own `sizeDescription`
    /// and every installer error — see
    /// `DownloadableSoundBank.formattedMegabytes`. Do not re-derive it here: a
    /// local copy is exactly how the offer row came to say "206 MB" while the
    /// progress line counted toward "216 MB".
    static func megabytes(_ bytes: Int64) -> String {
        DownloadableSoundBank.formattedMegabytes(bytes)
    }

    /// Reload the catalogue (cheap: a compile-time list plus one directory
    /// scan). Called by `prepare`/`refresh` and after a download finishes.
    public func refreshDownloadableBanks() {
        downloadOfferings = downloadableBanksProvider?() ?? []
    }

    /// Start downloading `id`. Returns immediately; `pollDownload` keeps
    /// `downloadStatus` current until the job reaches a terminal state.
    public func startDownload(id: String) {
        guard let start = startDownloadProvider else { return }
        downloadRequestError = nil
        Task { [weak self] in
            do {
                let accepted = try await start(id)
                self?.downloadStatus = accepted
                // The watcher takes it from here — and is (re)started rather
                // than assumed, so a Download press works even if the panel
                // somehow opened without one running.
                self?.beginWatchingDownloads()
            } catch {
                self?.downloadRequestError = Self.message(from: error)
            }
        }
    }

    /// Ask the running download to stop. ⚠️ Does NOT claim it stopped — the
    /// status keeps reporting `.downloading` with `cancelRequested` until the
    /// job unwinds and its partial file is gone, and the UI says "Stopping…"
    /// for exactly that window.
    public func cancelDownload() {
        guard let cancel = cancelDownloadProvider else { return }
        Task { [weak self] in
            do {
                let status = try await cancel()
                self?.downloadStatus = status
            } catch {
                self?.downloadRequestError = Self.message(from: error)
            }
        }
    }

    /// Clears an inline download-request refusal.
    public func clearDownloadRequestError() { downloadRequestError = nil }

    /// Watch the shared download slot for as long as this panel is open.
    ///
    /// ⚠️ This started life as a ONE-SHOT read called at `prepare` — and that
    /// was wrong in a way only a screenshot could show. The coordinator is
    /// SHARED with the control protocol, so a download can begin while the
    /// picker is already open (an agent calls `instrument.downloadSoundBank`).
    /// A one-shot read taken before that saw `.idle`, stopped, and the picker
    /// went on showing an idle Download button while 28 MB streamed in behind
    /// it — MEASURED on the live wire, invisible to every assertion here.
    /// Polling an in-process actor three times a second costs nothing next to
    /// what it is watching.
    ///
    /// Idempotent: calling it again replaces the running watcher.
    public func beginWatchingDownloads() {
        guard let read = downloadStatusProvider else { return }
        downloadPollTask?.cancel()
        downloadPollTask = Task { [weak self] in
            var previous: SoundBankDownloadState?
            while !Task.isCancelled {
                let status = await read()
                guard let self else { return }
                self.downloadStatus = status
                // Refresh ONLY on the transition out of `.downloading` — the
                // downloaded bank has to APPEAR in the list for the feature to
                // have done anything, but a directory scan three times a
                // second would be absurd.
                if previous == .downloading && status.state != .downloading {
                    self.refresh()
                    self.refreshDownloadableBanks()
                }
                previous = status.state
                try? await Task.sleep(nanoseconds: Self.downloadPollIntervalNanoseconds)
            }
        }
    }

    /// Stop watching — the panel closed. Leaves any running download alone;
    /// this only stops LOOKING at it.
    public func endWatchingDownloads() {
        downloadPollTask?.cancel()
        downloadPollTask = nil
    }

    /// 300 ms: fast enough that a progress bar moves smoothly, slow enough
    /// that polling an actor costs nothing next to a 206 MB transfer.
    static let downloadPollIntervalNanoseconds: UInt64 = 300_000_000

    private var downloadOfferings: [SoundBankOffering] = []
    @ObservationIgnored private var downloadPollTask: Task<Void, Never>?

    // MARK: - Choice construction

    /// The `InstrumentChoice` for a sound-bank program in a specific bank, with a
    /// display name captured for the chip ("Trumpet — General MIDI").
    public func choice(for program: SoundBankProgram, in bank: SoundBankInfo) -> InstrumentChoice {
        .soundBank(SoundBankConfig(
            source: bank.source, program: program.program,
            bankMSB: program.bankMSB, bankLSB: program.bankLSB,
            displayName: Self.displayName(for: program, bankName: bank.name,
                                          namesParsed: drilledNamesParsed)))
    }

    /// The `InstrumentChoice` for an AU instrument — the component triple + the
    /// display facts captured at selection (so a later missing plugin still reads).
    public func choice(for au: AudioUnitComponentInfo) -> InstrumentChoice {
        .audioUnit(AudioUnitConfig(component: au.component, name: au.name,
                                   manufacturerName: au.manufacturerName))
    }

    // MARK: - Current-selection highlighting

    /// Whether `choice` matches the track's current instrument — the row's
    /// "you're on this" highlight. Sound banks compare on the STRUCTURAL address
    /// (source/program/MSB/LSB), never the cosmetic display name (LAW L8); AUs on
    /// the component triple; built-ins on the kind (only when no AU/bank is set).
    public func isCurrent(_ choice: InstrumentChoice) -> Bool {
        guard let descriptor = currentDescriptor else { return false }
        switch choice {
        case .builtIn(let kind):
            return descriptor.kind == kind
        case .soundBank(let config):
            return descriptor.kind == .soundBank && descriptor.soundBank?.address == config.address
        case .audioUnit(let config):
            return descriptor.kind == .audioUnit && descriptor.audioUnit?.component == config.component
        }
    }

    /// The current instrument's display name for the track-header / mixer chip
    /// ("Poly Synth", "Trumpet — General MIDI", "DLSMusicDevice"). Reads the
    /// stored descriptor — never the engine.
    public var currentDisplayName: String {
        Self.displayName(for: currentDescriptor)
    }

    // MARK: - Static catalog + helpers

    /// The Simple-density Instrument Sets (16 GM categories + Drums), built once.
    /// Each category maps to its FIRST program (Piano→0, Brass→56, …); "Drums"
    /// maps to the Standard Drum Kit (bankMSB 120, program 0). Design §7.
    public static let allInstrumentSets: [InstrumentSet] =
        GMProgramCatalog.categories.enumerated().map { index, category in
            let program = index * 8
            return InstrumentSet(name: category, program: SoundBankProgram(
                program: program, bankMSB: GMProgramCatalog.melodicBankMSB,
                bankLSB: GMProgramCatalog.bankLSB,
                name: GMProgramCatalog.name(forProgram: program), category: category))
        } + [InstrumentSet(name: "Drums", program: GMProgramCatalog.standardDrumKit)]

    /// The chip display name for a descriptor. Mirrors the wire's derivation so the
    /// header chip and the snapshot read identically (Commands.swift
    /// `deriveSoundBankName`): built-ins by kind, AUs by their captured name,
    /// sound banks by the config's stored `displayName` (already "Name — Bank").
    public nonisolated static func displayName(for descriptor: InstrumentDescriptor?) -> String {
        guard let descriptor else { return "Poly Synth" }
        switch descriptor.kind {
        case .polySynth: return "Poly Synth"
        case .sampler: return "Sampler"
        case .testTone: return "Test Tone"
        case .audioUnit:
            let name = descriptor.audioUnit?.name ?? ""
            return name.isEmpty ? "Audio Unit" : name
        case .soundBank:
            let name = descriptor.soundBank?.displayName ?? ""
            return name.isEmpty ? "Sound Bank" : name
        }
    }

    /// The captured display name for a chosen program: "‹Name› — ‹Bank›" when the
    /// names are real (GM/parsed SF2), else "‹Bank› · P‹n›" (the generic fallback,
    /// mirroring the wire's `deriveSoundBankName`).
    nonisolated static func displayName(for program: SoundBankProgram, bankName: String,
                                        namesParsed: Bool) -> String {
        if namesParsed && !program.name.isEmpty {
            return "\(program.name) — \(bankName)"
        }
        return "\(bankName) · P\(program.program)"
    }

    /// Case-insensitive substring match; an empty query matches everything.
    nonisolated static func matches(_ text: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return text.range(of: trimmed, options: .caseInsensitive) != nil
    }

    private nonisolated static func message(from error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }
}

/// The single value a picker selection produces — the view hands exactly this to
/// `ProjectStore.setInstrument` (design §7, "the UI converges on the exact store
/// methods the wire uses"). Three cases mirror the three sections.
public enum InstrumentChoice: Equatable, Sendable {
    /// A built-in engine instrument — `polySynth` / `sampler` / `testTone`.
    case builtIn(InstrumentDescriptor.Kind)
    /// A sound-bank program (GM or an imported/scanned bank), display name captured.
    case soundBank(SoundBankConfig)
    /// A hosted Audio Unit music device (component triple + captured display facts).
    case audioUnit(AudioUnitConfig)
}

/// One built-in instrument row (Built-in section).
public struct BuiltInInstrument: Identifiable, Equatable, Sendable {
    public var kind: InstrumentDescriptor.Kind
    /// Display name — "Poly Synth" / "Sampler" / "Test Tone".
    public var name: String
    /// One-line beginner subtitle.
    public var detail: String
    public var id: String { kind.rawValue }
    /// The selection this row produces.
    public var choice: InstrumentChoice { .builtIn(kind) }

    public init(kind: InstrumentDescriptor.Kind, name: String, detail: String) {
        self.kind = kind
        self.name = name
        self.detail = detail
    }
}

/// One Simple-density "Instrument Set" — a curated GM category presented as a
/// single click (design §7). Selecting it applies the category's first program.
public struct InstrumentSet: Identifiable, Equatable, Sendable {
    /// The set's display name — a GM category ("Piano", "Brass") or "Drums".
    public var name: String
    /// The GM program the set maps to (the category's first program, or the
    /// Standard Drum Kit).
    public var program: SoundBankProgram
    public var id: String { name }

    /// The selection this set produces — always GM-backed, with the display name
    /// captured for the chip ("Trumpet — General MIDI" for Brass).
    public var choice: InstrumentChoice {
        .soundBank(SoundBankConfig(
            source: .generalMIDI, program: program.program,
            bankMSB: program.bankMSB, bankLSB: program.bankLSB,
            displayName: InstrumentPickerModel.displayName(
                for: program, bankName: "General MIDI", namesParsed: true)))
    }

    public init(name: String, program: SoundBankProgram) {
        self.name = name
        self.program = program
    }
}

/// One collapsible category group in the program browser (Pro).
public struct ProgramGroup: Identifiable, Equatable, Sendable {
    /// The category name — a GM category, "Drum Kits", or "Programs" (unparsed).
    public var category: String
    /// The programs in this category, in program order.
    public var programs: [SoundBankProgram]
    /// Whether the user has collapsed this group.
    public var isCollapsed: Bool
    public var id: String { category }

    public init(category: String, programs: [SoundBankProgram], isCollapsed: Bool) {
        self.category = category
        self.programs = programs
        self.isCollapsed = isCollapsed
    }
}
