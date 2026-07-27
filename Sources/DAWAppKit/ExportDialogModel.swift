import Foundation
import DAWCore

/// One track as the export dialog's "leave tracks out" list sees it (m23-m3):
/// the three fields a checkbox row renders, derived from the session snapshot
/// `prepare(tracks:)` takes when the sheet opens.
///
/// The model never reaches into a store to find out what tracks exist — it is
/// handed plain `Track` VALUES and keeps them, which is what makes it
/// previewable and unit-testable. This type is the ROW's view of one of them,
/// not a second source of truth: nothing plans a render from it (m23-m3c's
/// stems preview plans from the `Track` snapshot itself, through `StemPlan`),
/// because a hand-built choice carrying a wrong routing would preview a file set
/// the render does not write.
public struct ExportTrackChoice: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let kind: TrackKind

    public init(id: UUID, name: String, kind: TrackKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public init(_ track: Track) {
        self.init(id: track.id, name: track.name, kind: track.kind)
    }
}

/// The exact argument set the dialog will hand `ProjectStore.renderBounce`
/// (m23-m3). Built in ONE place (`ExportDialogModel.request`) so the sheet's
/// EXPORT button, the `debug.exportDialog` staging command and the tests all
/// drive identical arguments — a UI that spread these fields inline could
/// silently drop one and still pass a model-level test.
///
/// Every field's ABSENT value is the pre-m23-m1/m2 default, so a dialog opened
/// and left alone produces `renderBounce(toPath:)` verbatim.
public struct ExportRequest: Sendable, Equatable {
    /// nil → Float32 (the lossless default).
    public let bitDepth: Int?
    /// nil → WAV. A string because that is what `renderBounce` takes; it comes
    /// from `DeliveryContainer.rawValue`, never a literal.
    public let container: String?
    /// nil → nothing excluded. An EMPTY selection must encode as nil, not `[]`:
    /// `[]` is a distinct meaning on the wire ("you asked to exclude nothing"),
    /// and it would make `excludedTracks` present in every default response.
    public let excludeTrackIds: [UUID]?
    /// nil → no normalization gain at all (the report echoes `appliedGainDb` 0).
    public let lufsTarget: Double?
    /// Only read by `deliveryNormalized` when `lufsTarget` is non-nil — but it
    /// IS echoed into the report either way, so with normalization off this
    /// carries the shipped default rather than a stale slider value.
    public let truePeakCeilingDb: Double
}

/// The exact argument set the dialog will hand `ProjectStore.renderStems`
/// (m23-m3c) — the STEMS sibling of `ExportRequest`, and the ONE place stems
/// dialog state becomes render arguments.
///
/// A separate type rather than optional fields on `ExportRequest` because the
/// two parameter sets genuinely differ: `excludeTrackIds` exists only on the
/// bounce, `includeMixdown` / `includeMasteredMixdown` /
/// `masteredLufsTarget` / `masteredTruePeakCeilingDb` only on the stems call.
/// One merged struct would carry a field that is inert in whichever mode is
/// live — the class of control this dialog already refuses to draw.
///
/// Every field's ABSENT value is `renderStems`' own default, so a dialog opened,
/// switched to STEMS and left alone calls `renderStems(toDirectory:)` verbatim.
public struct StemExportRequest: Sendable, Equatable {
    /// Which master inputs get stems. **Always nil in v0, deliberately** — nil
    /// means every master input, which is what a stems export nearly always
    /// wants. The dialog shows NO track list in stems mode: `renderStems` takes
    /// an INCLUSION list while the bounce takes an EXCLUSION list, so one
    /// checkbox column would mean opposite things in the two modes. The
    /// read-only file preview teaches the eligibility rule instead, and the wire
    /// keeps per-track selection for agents. The field is here — rather than
    /// omitted — so that decision is visible and assertable rather than implied
    /// by an argument nobody passes.
    public let trackIds: [UUID]?
    /// Writes `StemPlan.mixdownBaseName` beside the stems: the chain-EXCLUDED
    /// reference the stems sum back to.
    public let includeMixdown: Bool
    /// Writes `StemPlan.masteredMixdownBaseName` beside the stems: the real
    /// mastered deliverable (m23-m1), rendered the way `render.bounce` renders.
    public let includeMasteredMixdown: Bool
    /// nil → the mastered sibling gets no normalization gain. Read ONLY when
    /// `includeMasteredMixdown` is on — nothing else in the call looks at it,
    /// because stems are never normalized (spec §4.1).
    public let masteredLufsTarget: Double?
    /// Echoed into the mastered file's report either way, so it carries the
    /// shipped default rather than a stale stepper value when no target is set.
    public let masteredTruePeakCeilingDb: Double
    /// Shared with the bounce — `renderStems` resolves through the same
    /// `DeliveryFormat.resolve`, so the dialog has ONE format control, not two.
    public let bitDepth: Int?
    public let container: String?
}

/// What the export dialog is exporting (m23-m3c) — the "what to export"
/// selector's vocabulary, and the reason there is one dialog rather than two.
///
/// Exactly TWO members, and `render.mixdown` is deliberately not one of them:
/// `includeMixdown` is a stems PARAMETER that writes a reference file INSIDE the
/// stems folder, not the raw/fast mixdown verb. A third mode named "mixdown"
/// would put the same word on two different things.
public enum ExportMode: String, Sendable, CaseIterable, Identifiable {
    /// One finished file — `renderBounce`, the m23-m3 dialog verbatim.
    case bounce
    /// One file per master input, into a folder — `renderStems`.
    case stems

    public var id: String { rawValue }

    /// The chip label. Lives here, beside the raw value, so the sheet and any
    /// later surface spell it once (the `DeliveryContainer.label` precedent).
    public var label: String {
        switch self {
        case .bounce: return "SONG"
        case .stems: return "STEMS"
        }
    }

    /// The card's title for this mode — the header is the first thing read, so
    /// it must not say "SONG" while a folder of stems is being written.
    public var title: String {
        switch self {
        case .bounce: return "EXPORT SONG"
        case .stems: return "EXPORT STEMS"
        }
    }

    /// One beginner-readable line under the selector. No wire spelling, no
    /// "bounce" — the word means nothing to a newcomer.
    public var detail: String {
        switch self {
        case .bounce:
            return "One finished file: the whole mix, through your master effects."
        case .stems:
            return "A folder with one file per mixer input — what a mixing engineer or a collaborator asks for."
        }
    }
}

/// The Export dialog's headless model (m23-m3, m23-m3c) — the state behind the
/// transport EXPORT chip's sheet, and the ONE place dialog state becomes
/// `renderBounce` / `renderStems` arguments.
///
/// Design notes that are load-bearing, not decoration:
///
/// **Two modes, one dialog, one format control.** `mode` picks between the
/// bounce (one file) and the stems (a folder of files); `request()` and
/// `stemRequest()` are the two mapping sites, `export` and `exportStems` the two
/// run sites, and NOTHING else assembles render arguments. The format section is
/// shared because `renderStems` resolves depth and container through the same
/// `DeliveryFormat.resolve` the bounce does — a second pair of format controls
/// would be two homes for one fact. What is NOT shared is the track list: the
/// bounce EXCLUDES, the stems call INCLUDES, so stems mode shows no list at all
/// (see `StemExportRequest.trackIds`) and shows the planned file set instead.
///
/// **The stems preview plans through `StemPlan`, never beside it.**
/// `plannedStemFiles` calls `StemPlan.fileSet` with the same values
/// `stemRequest()` carries, so the names on screen are produced by the code that
/// produces the names on disk — numbering, sanitizing, collision suffixes and
/// the container's extension included.
///
/// **The format is a `DeliveryFormat`, not a loose pair.** `DeliveryFormat` is
/// the ONE home for depth + container + file extension (m23-m2), and its `init`
/// is fileprivate so `resolve` is its only producer. This model therefore
/// STORES a resolved value and mutates it only through `resolve` — it never
/// recomputes an extension, a container name or a depth label. A depth outside
/// `DeliveryFormat.selectableBitDepths` is REFUSED (the previous valid format
/// stands) rather than coerced to a default, so the model can never hold a
/// format the render will reject.
///
/// **No loudness numbers live here on purpose.** The dialog shows none: the
/// numbers in `BounceResult.report` describe the buffer BEFORE integer
/// quantization (the m23-m2 open hazard, filed in ARCHITECTURE.md), so beside a
/// 16-bit choice they would name a peak — and an integrated loudness — the file
/// on disk does not have. `lastExport` keeps the path, the duration and the
/// format label, which are all true of the delivered file.
@MainActor
@Observable
public final class ExportDialogModel {

    /// What a finished export left behind — only facts that survive
    /// quantization (see the type doc's second note).
    public struct Outcome: Sendable, Equatable {
        public let path: String
        public let durationSeconds: Double
        /// `DeliveryFormat.label` — the format actually written.
        public let formatLabel: String
        /// Names of the tracks silenced for this render, in session order.
        public let excludedTracks: [String]
        /// True when a loudness target was requested AND the true-peak ceiling
        /// clamped the gain (no limiter in v0) — a fact about the RENDER, not a
        /// measurement of the file, so it survives the quantization hazard.
        public let limitedByCeiling: Bool
    }

    /// What a finished STEMS export left behind (m23-m3c). Same honesty rule as
    /// `Outcome` — no loudness numbers — plus one fact worth surfacing that a
    /// single-file export has no equivalent of: whether the project's master
    /// chain was left OFF the stems.
    public struct StemOutcome: Sendable, Equatable {
        public let directory: String
        /// The files that ACTUALLY landed, read off `StemExportResult`'s own
        /// paths — never re-derived from the plan. The plan is a promise; this
        /// is the delivery, and the two are compared by test, not by hope.
        public let fileNames: [String]
        public let durationSeconds: Double
        /// `DeliveryFormat.label` — the format actually written.
        public let formatLabel: String
        /// True when the mastered sibling was asked to hit a loudness target and
        /// the true-peak ceiling clamped the gain. A fact about the RENDER, not
        /// a measurement of a file.
        public let limitedByCeiling: Bool
        /// True when the project carries master insert effects, which the stems
        /// deliberately do NOT carry (S-3′: a nonlinear master chain does not
        /// distribute over the partition). `StemExportResult.masterChain`'s
        /// honesty field, in the one place a person can act on it.
        public let masterChainExcluded: Bool
    }

    // MARK: - Mode

    /// Bounce (one file) or stems (a folder). Plain and settable: switching
    /// modes changes nothing else — the format, the exclusions and both sets of
    /// loudness settings all survive, because a mode switch is a change of mind
    /// about the deliverable, not about the settings.
    public var mode: ExportMode = .bounce

    // MARK: - Format

    /// The resolved output format. `private(set)` + `resolve`-only mutators:
    /// the ONE producer stays the only producer (m23-m2's law), and the sheet
    /// reads its extension/labels from here rather than computing them.
    public private(set) var format: DeliveryFormat = .default

    /// Picks an integer depth (or nil for the Float32 default). A value outside
    /// `DeliveryFormat.selectableBitDepths` is REFUSED — the current format
    /// stands. Unreachable from the sheet (its picker is built from that same
    /// array); the refusal exists so an out-of-vocabulary value can never be
    /// smuggled in through the debug seam and reach a render.
    public func setBitDepth(_ bitDepth: Int?) {
        guard let next = try? DeliveryFormat.resolve(
            bitDepth: bitDepth, container: format.container.rawValue) else { return }
        format = next
    }

    /// Picks the container. Typed, so it cannot fail — but it still goes
    /// through `resolve` so there is exactly one construction site.
    public func setContainer(_ container: DeliveryContainer) {
        guard let next = try? DeliveryFormat.resolve(
            bitDepth: format.bitDepth, container: container.rawValue) else { return }
        format = next
    }

    // MARK: - Leave tracks out (the instrumental)

    /// The session as the list shows it — DERIVED from `sessionTracks` by
    /// `prepare(tracks:)`, never set independently, so a row can never describe
    /// a track the stems preview plans differently.
    public private(set) var tracks: [ExportTrackChoice] = []

    /// The session snapshot the sheet opened on — plain `Track` VALUES, copied
    /// once, never a live store read.
    ///
    /// It is the whole track and not a reduced view because the stems preview
    /// plans through `StemPlan`, which needs the routing (`outputBusID`) and the
    /// kind to decide which tracks are master inputs at all. Feeding the planner
    /// a reduced type would create a second thing capable of producing stem
    /// names — exactly the divergence m23-m3c exists to close.
    public private(set) var sessionTracks: [Track] = []

    /// Ids the user asked to silence. Kept as a set for the checkbox rows;
    /// emitted in SESSION order so the response's `excludedTracks` echo is
    /// stable.
    public private(set) var excludedTrackIDs: Set<UUID> = []

    public func toggleExcluded(_ id: UUID) {
        if excludedTrackIDs.contains(id) {
            excludedTrackIDs.remove(id)
        } else if tracks.contains(where: { $0.id == id }) {
            // Only a track that is actually in the session can be excluded —
            // an unknown id would throw `trackNotFound` at render time, after
            // the save panel, which is the worst possible moment to find out.
            excludedTrackIDs.insert(id)
        }
    }

    public func clearExclusions() { excludedTrackIDs.removeAll() }

    public func isExcluded(_ id: UUID) -> Bool { excludedTrackIDs.contains(id) }

    /// The excluded tracks' names in session order — the sheet's summary line.
    public var excludedNames: [String] {
        tracks.filter { excludedTrackIDs.contains($0.id) }.map(\.name)
    }

    // MARK: - Normalization (m16-d params, reachable at last)

    /// Off by default — the shipped `renderBounce` behaviour is no gain at all.
    public var normalize = false

    /// The loudness target, used ONLY when `normalize` is on. −14 is the
    /// streaming-platform convention and the value the app's own teaching text
    /// uses elsewhere. CLAMPED to the store's contract range on the way in, so
    /// the readout can never show a number the request would not carry.
    ///
    /// Computed over a private stored pair rather than a `didSet`: under
    /// `@Observable` a `didSet` that assigns to its own property re-enters the
    /// macro-generated setter and recurses until the stack dies (measured here —
    /// SIGSEGV, not a warning).
    public var lufsTarget: Double {
        get { storedLufsTarget }
        set { storedLufsTarget = min(0, max(-70, newValue)) }
    }
    private var storedLufsTarget: Double = -14

    /// The true-peak ceiling the normalization gain is clamped against. Read
    /// only while `normalize` is on — which is exactly why the sheet nests its
    /// control under the toggle: shown while normalization is off it would be a
    /// control that changes no samples. Clamped like the target above.
    public var truePeakCeilingDb: Double {
        get { storedTruePeakCeilingDb }
        set { storedTruePeakCeilingDb = min(0, max(-20, newValue)) }
    }
    private var storedTruePeakCeilingDb = ExportDialogModel.defaultTruePeakCeilingDb

    /// `renderBounce`'s own default — the value the request carries whenever
    /// normalization is off, so the report never echoes a ceiling the user
    /// dialled but the render never read. `renderStems`' `masteredTruePeakCeilingDb`
    /// shares it: one number, one meaning.
    public static let defaultTruePeakCeilingDb = -1.0

    // MARK: - Stems (m23-m3c)

    /// Write the chain-EXCLUDED reference mix beside the stems. Off by default,
    /// like the wire's own `includeMixdown` — a dialog left alone must call
    /// `renderStems(toDirectory:)` verbatim.
    public var includeMixdown = false

    /// Write the real mastered mix beside the stems (m23-m1). Independent of
    /// `includeMixdown`, never a shared "which chain" switch: the two files
    /// have different, non-overlapping meanings and both may be asked for at
    /// once.
    public var includeMasteredMixdown = false

    /// Whether the mastered sibling is normalized. Separate from the bounce's
    /// `normalize` because they are separate parameters on separate calls —
    /// sharing one flag would let a stems export inherit a target the user set
    /// for a song export they never ran.
    public var masteredNormalize = false

    /// The mastered sibling's loudness target, used ONLY when
    /// `includeMasteredMixdown` AND `masteredNormalize` are both on. Clamped to
    /// the store's contract range on the way in, over a private stored pair —
    /// under `@Observable`, a `didSet` that assigns to its own property
    /// re-enters the macro-generated setter and recurses until the stack dies
    /// (measured at m23-m3: SIGSEGV, not a warning).
    public var masteredLufsTarget: Double {
        get { storedMasteredLufsTarget }
        set { storedMasteredLufsTarget = min(0, max(-70, newValue)) }
    }
    private var storedMasteredLufsTarget: Double = -14

    /// The mastered sibling's true-peak ceiling. Same clamp contract and the
    /// same stored-pair idiom as above.
    public var masteredTruePeakCeilingDb: Double {
        get { storedMasteredTruePeakCeilingDb }
        set { storedMasteredTruePeakCeilingDb = min(0, max(-20, newValue)) }
    }
    private var storedMasteredTruePeakCeilingDb = ExportDialogModel.defaultTruePeakCeilingDb

    // MARK: - Transient run state

    public private(set) var isExporting = false
    public private(set) var lastError: String?
    public private(set) var lastExport: Outcome?
    public private(set) var lastStemExport: StemOutcome?

    public init() {}

    // MARK: - Lifecycle

    /// Called every time the sheet opens. Refreshes the session snapshot, PRUNES
    /// any exclusion whose track is gone (a stale id would throw
    /// `trackNotFound` mid-export) and clears the previous run's results.
    ///
    /// Takes whole `Track` values (m23-m3c, was `[ExportTrackChoice]`): the
    /// stems preview plans through `StemPlan`, which reads routing and kind, and
    /// ONE input type to the planner is what keeps the preview and the disk
    /// honest. The checkbox rows' `ExportTrackChoice` list is derived here.
    ///
    /// The MODE, the FORMAT and both sets of loudness settings deliberately
    /// survive: a second export in one session almost always wants the first
    /// one's settings, and they cannot go stale the way a track id can.
    public func prepare(tracks: [Track]) {
        sessionTracks = tracks
        self.tracks = tracks.map(ExportTrackChoice.init)
        let known = Set(tracks.map(\.id))
        excludedTrackIDs.formIntersection(known)
        lastError = nil
        lastExport = nil
        lastStemExport = nil
    }

    /// The default file name offered in the save panel — the project's name
    /// under the FORMAT's extension, from `DeliveryFormat.fileName` (never a
    /// literal ".wav", which is how a name and its bytes drift apart).
    public func suggestedFileName(projectName: String) -> String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return format.fileName(trimmed.isEmpty ? "Untitled" : trimmed)
    }

    // MARK: - The one request builder

    /// Dialog state → `renderBounce` arguments. The ONLY place this mapping
    /// exists.
    public func request() -> ExportRequest {
        ExportRequest(
            bitDepth: format.bitDepth,
            // `reportedContainer` is nil for WAV — the same "absence means the
            // default" rule the wire echo follows, so a default export passes
            // container: nil and stays byte-identical to today's bounce.
            container: format.reportedContainer,
            excludeTrackIds: excludedTrackIDs.isEmpty ? nil : orderedExcludedIDs,
            lufsTarget: normalize ? lufsTarget : nil,
            truePeakCeilingDb: normalize ? truePeakCeilingDb : Self.defaultTruePeakCeilingDb)
    }

    /// Excluded ids in SESSION order (not set order) — deterministic, so the
    /// `excludedTracks` echo and any log line read the same way twice.
    private var orderedExcludedIDs: [UUID] {
        tracks.filter { excludedTrackIDs.contains($0.id) }.map(\.id)
    }

    /// Stems dialog state → `renderStems` arguments (m23-m3c). The ONLY place
    /// this mapping exists, and — through `plannedStemFiles` — the same values
    /// the preview is built from, so what the card promises and what the render
    /// receives cannot come apart.
    public func stemRequest() -> StemExportRequest {
        StemExportRequest(
            // v0 exports every master input; see the field's doc for why the
            // dialog does not offer a selection.
            trackIds: nil,
            includeMixdown: includeMixdown,
            includeMasteredMixdown: includeMasteredMixdown,
            // A target is carried only when the file that would use it is
            // actually being written — a normalization setting on an unwritten
            // file is a setting that changes no samples.
            masteredLufsTarget: includeMasteredMixdown && masteredNormalize
                ? masteredLufsTarget : nil,
            masteredTruePeakCeilingDb: includeMasteredMixdown && masteredNormalize
                ? masteredTruePeakCeilingDb : Self.defaultTruePeakCeilingDb,
            bitDepth: format.bitDepth,
            container: format.reportedContainer)
    }

    /// The exact file names a stems export would write, in the order they read
    /// on disk — **produced by `StemPlan.fileSet`, the same code the render
    /// names its files with** (m23-m3c). The sheet renders this list verbatim.
    ///
    /// Built from `stemRequest()` rather than from the toggles directly, so the
    /// preview and the render can only ever disagree if `renderStems` itself
    /// disagrees with `StemPlan` — which is what the on-disk equality test
    /// pins.
    ///
    /// Non-throwing on purpose: `fileSet` only throws while VALIDATING an
    /// explicit id list, and v0 always passes nil (every master input), so the
    /// failure branch is unreachable. Swallowing it here keeps `try` out of a
    /// view body; an empty list renders as "no tracks reach the main mix yet",
    /// which is also the honest answer for a session with none.
    public var plannedStemFiles: [String] {
        let request = stemRequest()
        return (try? StemPlan.fileSet(
            tracks: sessionTracks,
            including: request.trackIds,
            includeMixdown: request.includeMixdown,
            includeMasteredMixdown: request.includeMasteredMixdown,
            format: format)) ?? []
    }

    // MARK: - The export itself

    /// Runs the bounce the dialog describes. **The sheet's EXPORT button, the
    /// `debug.exportDialog` staging command and the tests all call THIS** — a
    /// path that spread `request()` into `renderBounce` at the call site could
    /// drop a parameter and still satisfy a request-level assertion.
    ///
    /// `path` comes from the save panel (or the debug seam). Errors are held on
    /// `lastError` for the sheet rather than thrown, so a failed export leaves
    /// the dialog open with its reason on screen.
    @discardableResult
    public func export(store: ProjectStore, toPath path: String) async -> Bool {
        guard !isExporting else { return false }
        isExporting = true
        // BOTH results clear, not just the error: the sheet hides the button in
        // the result branch so a user cannot reach this with a stale outcome,
        // but the debug seam can — and a card showing a fresh failure BESIDE a
        // previous run's success path is a lie about which file is on disk.
        lastError = nil
        lastExport = nil
        lastStemExport = nil
        defer { isExporting = false }
        let request = request()
        do {
            let result = try await store.renderBounce(
                toPath: path,
                lufsTarget: request.lufsTarget,
                truePeakCeilingDb: request.truePeakCeilingDb,
                excludeTrackIds: request.excludeTrackIds,
                bitDepth: request.bitDepth,
                container: request.container)
            lastExport = Outcome(
                path: result.path,
                durationSeconds: result.durationSeconds,
                formatLabel: format.label,
                excludedTracks: result.excludedTracks ?? [],
                limitedByCeiling: result.report.limitedByCeiling)
            return true
        } catch {
            // `ProjectError` is a `LocalizedError`, so this is its own
            // `errorDescription` — the same sentence the wire returns.
            lastError = error.localizedDescription
            return false
        }
    }

    /// Runs the stems export the dialog describes (m23-m3c). **The sheet's
    /// EXPORT button, the `debug.exportDialog {exportToDirectory}` staging
    /// command and the tests all call THIS** — the same one-function rule the
    /// bounce follows, for the same reason: a call site that spread
    /// `stemRequest()` into `renderStems` could drop a parameter and still
    /// satisfy a request-level assertion.
    ///
    /// `directory` comes from the open panel (or the debug seam) — a FOLDER,
    /// not a file: this call writes a SET, and `renderStems` creates the
    /// directory if it does not exist. Errors are held on `lastError` rather
    /// than thrown, so a failed export leaves the dialog open with its reason on
    /// screen.
    ///
    /// **The result's file list is read back off `StemExportResult`'s own
    /// paths**, never re-derived from `plannedStemFiles`: the plan is what was
    /// promised, this is what landed. They are equal on the success path (pinned
    /// by test) — and NOT necessarily after a mid-set failure, because the
    /// mastered pass runs last and can throw with the stems already on disk.
    @discardableResult
    public func exportStems(store: ProjectStore, toDirectory directory: String) async -> Bool {
        guard !isExporting else { return false }
        isExporting = true
        lastError = nil
        lastExport = nil
        lastStemExport = nil
        defer { isExporting = false }
        let request = stemRequest()
        do {
            let result = try await store.renderStems(
                toDirectory: directory,
                trackIds: request.trackIds,
                includeMixdown: request.includeMixdown,
                includeMasteredMixdown: request.includeMasteredMixdown,
                masteredLufsTarget: request.masteredLufsTarget,
                masteredTruePeakCeilingDb: request.masteredTruePeakCeilingDb,
                bitDepth: request.bitDepth,
                container: request.container)
            // In `StemPlan.fileSet` order — the two `00 …` siblings first, then
            // the partition — so the result strip and the preview read the same
            // way down the card.
            var names: [String] = []
            if let mixdown = result.mixdown { names.append(Self.fileName(mixdown.path)) }
            if let mastered = result.masteredMixdown {
                names.append(Self.fileName(mastered.path))
            }
            names += result.stems.map { Self.fileName($0.path) }
            lastStemExport = StemOutcome(
                directory: result.directory,
                fileNames: names,
                durationSeconds: result.durationSeconds,
                formatLabel: format.label,
                limitedByCeiling: result.masteredMixdown?.report.limitedByCeiling ?? false,
                // Present — as "excluded" — exactly when the project carries a
                // master chain the stems do not (m13-d's honesty field).
                masterChainExcluded: result.masterChain != nil)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// The last path component — the delivered file's name, for a card that has
    /// already shown the folder above it.
    private static func fileName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
