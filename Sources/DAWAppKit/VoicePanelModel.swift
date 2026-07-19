import Foundation
import DAWCore
import AIServices

/// Headless state machine for the Voice panel (m10-p-5): named local voices
/// with per-voice training-sample DATASETS, the RVC-sidecar banner mapping,
/// the facade voice list, the Train affordance (honest 501 handling until
/// real training ships with m10-p-6), and the "Convert to voice…" clip
/// action. No SwiftUI, no networking of its own — every hop is an injected
/// provider (the `ClipFixModel`/`SketchpadModel` precedent), so tests drive
/// everything against fakes with no sidecar, no UI, and no real app-support
/// directory.
///
/// ## Storage split (settled, m10-p-4/p-5)
/// - **Datasets** (the user's own training RECORDINGS) are app-side data and
///   live under `~/Library/Application Support/DAWPro/VoiceDatasets/<voice>/`
///   (the `SoundBankLibrary.defaultLibraryDirectory()` shape) — one directory
///   per named voice, plain audio files inside.
/// - **Trained MODELS** stay facade-owned in `scripts/rvc/runtime/voices/`
///   (m10-p-2's design, recorded in ARCHITECTURE.md) — this model NEVER
///   duplicates or touches that store; it only ever names a `voiceId`.
///
/// ## Import law
/// Sample imports are **copies, never moves** — the `SoundBankLibrary
/// .importBank` law verbatim: validate first (extension, existence,
/// readability), create the destination lazily, uniquify the name on
/// collision (`name-2.wav`, mirroring `ProjectBundle.uniqueName`), `copyItem`,
/// and never touch the source.
///
/// ## Convert law (the m10-n-3 `applyInstrumentChoice` law)
/// `convertClip` rides the SAME two seams the wire's `vc.convertVocals`
/// clipId-form uses — `ProjectStore.voiceConversionSource` → the client's
/// `convert` → `ProjectStore.importConvertedVoice` — through injected
/// closures; there is no parallel mutation path, so UI and wire land
/// byte-identical results (one undoable edit, violet AI track).
///
/// ## Copy register
/// The panel speaks USER copy, never wire-speak (the m10-q fold-in law):
/// the banner says "The voice engine isn't running — press Start." with a
/// Start button driving the manager — never "call vc.sidecarStart". Store
/// refusals (e.g. the MIDI-clip rejection) surface VERBATIM (the
/// refusal-bubble law: one vocabulary, human and machine).
@MainActor
@Observable
public final class VoicePanelModel {
    // MARK: - Policy copy (standing legal/policy constraint, not decoration)

    /// The own-voice-only policy line the panel renders verbatim. The phrase
    /// "a voice you have the rights to use" is a REQUIRED verbatim fragment
    /// (m10-p-5 brief) — pinned by `VoicePanelModelTests`.
    public static let policyLine =
        "Train and convert only with your own voice — a voice you have the rights to use."
    /// The no-celebrity/no-third-party companion line, also rendered verbatim.
    public static let policyDetail =
        "Never a celebrity voice, and never anyone else's voice without their explicit permission."
    /// The record-path hint: direct mic-record-into-panel is deferred (the
    /// record path already exists via normal track recording), and the panel
    /// SAYS so instead of hiding the gap.
    public static let recordHint =
        "To record new material: record on a track as usual, then select the clip and add it here as a sample."
    /// The honest not-yet state for training (m10-p-6 ships the real thing);
    /// rendered as the headline of the `.comingSoon` card, above the facade's
    /// own teaching message.
    public static let trainingComingSoonHeadline = "Real training arrives with a coming update."

    /// Audio extensions accepted as training samples (what AVAudioFile reads;
    /// the RVC facade trains from plain audio files).
    public static let audioExtensions: Set<String> = ["wav", "aif", "aiff", "caf", "mp3", "m4a", "flac"]

    // MARK: - Sidecar state → user-copy banner

    /// Latest sidecar health (drives the banner). Fed by the view's status
    /// poll, `refreshSidecar()`, or `debug.voicePanel` seeding; nil until the
    /// first probe lands.
    public private(set) var sidecarStatus: VoiceConversionStatus?

    /// True while a `startSidecar()` call is in flight (the banner swaps its
    /// Start button for a disabled STARTING… twin even before the manager
    /// reports `.starting`).
    public private(set) var isStartingSidecar = false

    /// The user-copy banner (nil when healthy — the panel is ready). Tones
    /// mirror `SketchpadBanner`'s: `.progress` is the truthful M10-b starting
    /// state (spinner + elapsed seconds, never a faked "ready").
    public var banner: VoicePanelBanner? {
        guard let status = sidecarStatus else {
            return VoicePanelBanner(message: "Checking the voice engine…",
                                    canStart: false, tone: .neutral)
        }
        switch status.state {
        case .healthy:
            return nil
        case .installedNotRunning:
            // status.message is wire-speak ("call vc.sidecarStart") — right
            // for agents, wrong register here (the m10-q law).
            return VoicePanelBanner(message: "The voice engine isn't running — press Start.",
                                    canStart: true, tone: .warning)
        case .starting:
            return VoicePanelBanner(message: Self.startingMessage(status),
                                    canStart: false, tone: .progress)
        case .notInstalled:
            return VoicePanelBanner(
                message: "The voice engine isn't installed on this Mac — run scripts/rvc/install.sh "
                    + "once from the DAW Pro folder, then reopen this panel.",
                canStart: false, tone: .warning)
        case .error:
            // The manager's error message is already human ("responded but
            // couldn't be parsed — check <log>") — verbatim.
            return VoicePanelBanner(message: status.message, canStart: false, tone: .error)
        }
    }

    /// Composes the truthful `.starting` line: elapsed seconds when the
    /// manager reports them (M10-b — the count visibly advances), a plain
    /// sentence otherwise. The RVC manager never populates `phase` (v1 has no
    /// phase classifier by design), so unlike the Sketchpad twin there is no
    /// phase clause.
    static func startingMessage(_ status: VoiceConversionStatus) -> String {
        guard let elapsed = status.startingForSeconds else {
            return "Starting the voice engine…"
        }
        return "Starting the voice engine… (\(elapsed)s)"
    }

    /// Feeds a fresh sidecar status in (the view's poll / `debug.voicePanel`
    /// seeding — the `SketchpadModel.updateSidecar` twin).
    public func updateSidecar(_ status: VoiceConversionStatus) {
        sidecarStatus = status
    }

    /// Probes the manager and updates the banner state.
    public func refreshSidecar() async {
        sidecarStatus = await sidecarStatusProvider()
    }

    /// The banner's Start button: drives the manager's `start()` (blocking
    /// through its own health window) and lands whatever status it returns —
    /// falling back to a plain re-probe if the start attempt threw (the
    /// `startSketchpadSidecar` shape). Refreshes the facade voice list once
    /// healthy so the panel populates without a second click.
    public func startSidecar() async {
        guard !isStartingSidecar else { return }
        isStartingSidecar = true
        defer { isStartingSidecar = false }
        if let started = try? await sidecarStarter() {
            sidecarStatus = started
        } else {
            await refreshSidecar()
        }
        if sidecarStatus?.state == .healthy {
            await refreshVoices()
        }
    }

    // MARK: - Facade voice list

    /// The facade's `GET /v1/voice/list` descriptors, verbatim (the same
    /// shape `vc.listVoices` serves). Contains the reserved `"base"` entry —
    /// the view labels it as the pipeline smoke target, never a real voice.
    public private(set) var voices: [VoiceDescriptor] = []
    /// User-copy error when the last refresh failed (nil on success).
    public private(set) var voicesError: String?
    /// True after at least one successful refresh (distinguishes "no voices"
    /// from "never asked").
    public private(set) var hasLoadedVoices = false

    /// Whether a descriptor is the reserved pipeline smoke target (the ONE
    /// definition the view + convert sheet share).
    public static func isSmokeTarget(_ descriptor: VoiceDescriptor) -> Bool {
        descriptor.id == "base" || descriptor.kind == "builtin"
    }

    public func refreshVoices() async {
        do {
            voices = try await voicesProvider()
            voicesError = nil
            hasLoadedVoices = true
        } catch {
            voicesError = Self.userCopy(for: error)
        }
    }

    /// Capture staging: replaces the facade list wholesale (the
    /// `setCandidatesForCapture` precedent) so a shot can show voices without
    /// a live sidecar.
    public func setVoicesForCapture(_ seeded: [VoiceDescriptor]) {
        voices = seeded
        voicesError = nil
        hasLoadedVoices = true
    }

    // MARK: - Local datasets (app-side, user recordings)

    /// The named local voices found under `datasetsRoot`, sorted by name.
    public private(set) var localVoices: [VoiceDataset] = []
    /// User-copy error from the last dataset operation (nil on success);
    /// cleared by the next successful operation.
    public private(set) var datasetError: String?

    /// Re-scans `datasetsRoot` (one subdirectory per named voice; audio files
    /// inside are the samples). A missing root is an honest empty list, never
    /// an error — the root is created lazily on the first create/import.
    public func rescanDatasets() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: datasetsRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            localVoices = []
            return
        }
        localVoices = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { Self.dataset(at: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func dataset(at dir: URL) -> VoiceDataset {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let samples = files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .map { VoiceSample(name: $0.lastPathComponent, url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return VoiceDataset(name: dir.lastPathComponent, directory: dir, samples: samples)
    }

    /// Creates a new named voice dataset (an empty directory). Validation is
    /// teaching-style: trimmed non-empty, no path separators, not the
    /// reserved "base" id (case-insensitive — that's the facade's smoke
    /// target, never trainable), and not already taken (case-insensitive).
    /// Returns true on success; failures land user copy in `datasetError`.
    @discardableResult
    public func createVoice(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            datasetError = "Give the voice a name first."
            return false
        }
        guard !name.contains("/"), !name.contains(":") else {
            datasetError = "A voice name can't contain \"/\" or \":\" — pick a plain name."
            return false
        }
        guard name.lowercased() != "base" else {
            datasetError = "\"base\" is reserved for the built-in pipeline test — pick another name."
            return false
        }
        guard !localVoices.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            datasetError = "A voice named \"\(name)\" already exists."
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: datasetsRoot.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        } catch {
            datasetError = "Couldn't create the voice folder: \(error.localizedDescription)"
            return false
        }
        datasetError = nil
        rescanDatasets()
        return true
    }

    /// Deletes a named voice's DATASET directory (recordings only — any
    /// trained model in the facade's own store is untouched; this model never
    /// reaches that store).
    @discardableResult
    public func deleteVoice(named name: String) -> Bool {
        guard let dataset = localVoices.first(where: { $0.name == name }) else { return false }
        do {
            try FileManager.default.removeItem(at: dataset.directory)
        } catch {
            datasetError = "Couldn't remove \"\(name)\": \(error.localizedDescription)"
            return false
        }
        datasetError = nil
        rescanDatasets()
        return true
    }

    /// Imports audio files into a named voice's dataset — copy-never-move
    /// (the `SoundBankLibrary.importBank` law): validate first, uniquify on
    /// collision, `copyItem`, source untouched. Stops at the first failure
    /// with user copy in `datasetError` (files before it stay imported).
    /// Returns how many files landed.
    @discardableResult
    public func importSamples(_ urls: [URL], intoVoice name: String) -> Int {
        guard let dataset = localVoices.first(where: { $0.name == name }) else {
            datasetError = "No voice named \"\(name)\" — create it first."
            return 0
        }
        let fm = FileManager.default
        var imported = 0
        datasetError = nil
        for url in urls {
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else {
                datasetError = "\"\(url.lastPathComponent)\" isn't an audio file this panel can use — "
                    + "bring a WAV, AIFF, CAF, MP3, M4A, or FLAC recording."
                break
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                datasetError = "No audio file at \(url.path)."
                break
            }
            guard fm.isReadableFile(atPath: url.path) else {
                datasetError = "Can't read \(url.path)."
                break
            }
            do {
                try fm.createDirectory(at: dataset.directory, withIntermediateDirectories: true)
                let taken = Set((try? fm.contentsOfDirectory(atPath: dataset.directory.path)) ?? [])
                let destinationName = Self.uniqueName(for: url.lastPathComponent, taken: taken)
                try fm.copyItem(
                    at: url, to: dataset.directory.appendingPathComponent(destinationName))
                imported += 1
            } catch {
                datasetError = "Couldn't copy \"\(url.lastPathComponent)\": \(error.localizedDescription)"
                break
            }
        }
        rescanDatasets()
        return imported
    }

    /// "Add selected clip as sample": resolves the clip to its backing audio
    /// file through the store's EXISTING resolution seam
    /// (`voiceConversionSource` — the same one the wire's clipId-form
    /// convert uses) and imports that file as a sample (a COPY — the backing
    /// take stays where it is). A MIDI clip is rejected with the store's own
    /// teaching error VERBATIM (the refusal-bubble law). Returns true when
    /// the sample landed.
    @discardableResult
    public func addClipAsSample(clipID: UUID, intoVoice name: String) -> Bool {
        let sourceURL: URL
        do {
            sourceURL = try clipSource(clipID).url
        } catch {
            datasetError = Self.userCopy(for: error)
            return false
        }
        return importSamples([sourceURL], intoVoice: name) == 1
    }

    /// Removes one sample file from a voice's dataset.
    @discardableResult
    public func removeSample(named sampleName: String, fromVoice name: String) -> Bool {
        guard let dataset = localVoices.first(where: { $0.name == name }),
              let sample = dataset.samples.first(where: { $0.name == sampleName }) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: sample.url)
        } catch {
            datasetError = "Couldn't remove \"\(sampleName)\": \(error.localizedDescription)"
            return false
        }
        datasetError = nil
        rescanDatasets()
        return true
    }

    /// Mirrors `ProjectBundle.uniqueName` (internal to DAWCore): `take.wav` →
    /// `take-2.wav` on collision, counting up.
    static func uniqueName(for basename: String, taken: Set<String>) -> String {
        guard taken.contains(basename) else { return basename }
        let ns = basename as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }

    // MARK: - Train

    /// Per-voice training lifecycle. `.progress` is the SHIPPED-but-unfed
    /// state machine slot: nothing today may construct a fractional value —
    /// the facade answers 501 until m10-p-6 feeds real progress — so the UI
    /// can NEVER show fake progress. An unexpected 2xx today (a facade ahead
    /// of this app) lands `.progress(fraction: nil, detail: nil)`: an honest
    /// indeterminate "training is running", never an invented percentage.
    public enum TrainState: Equatable, Sendable {
        case idle
        case submitting
        case progress(fraction: Double?, detail: String?)
        /// The designed honest 501 state: the facade's teaching message,
        /// verbatim, under the `trainingComingSoonHeadline`.
        case comingSoon(message: String)
        case failed(message: String)
    }

    /// Keyed by voice name; a missing key reads `.idle`.
    public private(set) var trainStates: [String: TrainState] = [:]

    public func trainState(forVoice name: String) -> TrainState {
        trainStates[name] ?? .idle
    }

    /// Clears a terminal train card (comingSoon/failed dismiss).
    public func dismissTrainState(forVoice name: String) {
        trainStates[name] = nil
    }

    /// The Train affordance: validates the dataset LOCALLY first (a non-empty
    /// set of audio files — no pointless round trip for an empty folder),
    /// then calls the client's `train` and maps the outcome honestly:
    /// today's 501 `trainingNotYetAvailable` becomes the designed
    /// `.comingSoon` state carrying the facade's teaching message verbatim.
    public func train(voiceNamed name: String) async {
        if case .submitting = trainState(forVoice: name) { return }
        rescanDatasets()
        guard let dataset = localVoices.first(where: { $0.name == name }) else {
            trainStates[name] = .failed(message: "No voice named \"\(name)\" — create it first.")
            return
        }
        guard !dataset.samples.isEmpty else {
            trainStates[name] = .failed(
                message: "Add at least one recording to this voice before training — "
                    + "import audio files, or add a selected clip as a sample.")
            return
        }
        trainStates[name] = .submitting
        do {
            _ = try await trainer(VoiceTrainRequest(name: name, datasetDir: dataset.directory.path))
            // A 2xx has no defined schema until m10-p-6 — honest indeterminate
            // progress, never a fake number (see TrainState's doc).
            trainStates[name] = .progress(fraction: nil, detail: nil)
        } catch let error as VoiceConversionError {
            switch error {
            case .requestFailed(_, let code, let message) where code == "trainingNotYetAvailable":
                trainStates[name] = .comingSoon(message: message)
            default:
                trainStates[name] = .failed(message: Self.userCopy(for: error))
            }
        } catch {
            trainStates[name] = .failed(message: Self.userCopy(for: error))
        }
    }

    // MARK: - Convert to voice (the clip action)

    /// True while a blocking convert is in flight — conversion is
    /// seconds-class (m10-p-2: ~37x real time), so this is a brief busy
    /// state, NOT the generation-status job machinery (the settled m10-p-5
    /// difference from `ClipFixModel`).
    public private(set) var isConverting = false
    /// User-copy error from the last convert attempt (nil on success/idle).
    public private(set) var convertError: String?
    /// The last successful conversion — the sheet's honest result state,
    /// including the `realConversion:false` + note truth for "base".
    public private(set) var lastConversion: VoiceConvertOutcome?

    /// The wire's default-track-name rule, shared verbatim
    /// (`vc.convertVocals`: `"Voice: <voiceId>"`).
    public static func defaultTrackName(voiceID: String) -> String {
        "Voice: \(voiceID)"
    }

    /// Converts an audio clip to `voiceID` and lands the result at the
    /// clip's own beat as a new violet AI track — the EXACT semantics of the
    /// wire's `vc.convertVocals` clipId-form, through the same two seams
    /// (`clipSource` = `voiceConversionSource`, then `converter` +
    /// `importer` = client.convert + `importConvertedVoice`), one undoable
    /// edit. Returns true when the track landed.
    @discardableResult
    public func convertClip(
        clipID: UUID, voiceID: String, pitchSemitones: Int = 0, trackName: String? = nil
    ) async -> Bool {
        guard !isConverting else { return false }
        convertError = nil
        lastConversion = nil

        // Resolve the source FIRST — a MIDI clip must never reach the
        // converter (the store's teaching error surfaces verbatim).
        let source: (url: URL, startBeat: Double)
        do {
            source = try clipSource(clipID)
        } catch {
            convertError = Self.userCopy(for: error)
            return false
        }

        isConverting = true
        defer { isConverting = false }
        do {
            let result = try await converter(VoiceConvertRequest(
                inputPath: source.url.path, voiceId: voiceID, pitchSemitones: pitchSemitones))
            let resolvedName = (trackName?.isEmpty == false)
                ? trackName! : Self.defaultTrackName(voiceID: voiceID)
            _ = try importer(
                URL(fileURLWithPath: result.outputPath), resolvedName, source.startBeat)
            lastConversion = VoiceConvertOutcome(
                voiceID: result.voiceId, trackName: resolvedName,
                realConversion: result.realConversion, note: result.note,
                inputSeconds: result.inputSeconds, inferSeconds: result.inferSeconds)
            return true
        } catch {
            convertError = Self.userCopy(for: error)
            return false
        }
    }

    /// Clears the convert sheet's transient state (open/close reset).
    public func resetConvertState() {
        convertError = nil
        lastConversion = nil
    }

    // MARK: - Error → user copy

    /// Maps errors to the panel's register: a bare unreachable-sidecar
    /// becomes the Start-button teaching line (never "call vc.sidecarStart"
    /// wire-speak — the m10-q law); everything else surfaces its own
    /// human-readable message VERBATIM (store refusals and the facade's
    /// teaching errors are already one shared vocabulary).
    static func userCopy(for error: Error) -> String {
        if case VoiceConversionError.sidecarUnreachable = error {
            return "The voice engine isn't running — press Start at the top of the Voice panel, then try again."
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }

    // MARK: - Injected dependencies

    /// One directory per named voice under here (created lazily).
    public let datasetsRoot: URL

    private let sidecarStatusProvider: @Sendable () async -> VoiceConversionStatus
    private let sidecarStarter: @Sendable () async throws -> VoiceConversionStatus
    private let voicesProvider: @Sendable () async throws -> [VoiceDescriptor]
    private let trainer: @Sendable (VoiceTrainRequest) async throws -> Data
    private let converter: @Sendable (VoiceConvertRequest) async throws -> VoiceConvertResult
    /// `ProjectStore.voiceConversionSource(clipId:)` — @MainActor (store).
    private let clipSource: @MainActor (UUID) throws -> (url: URL, startBeat: Double)
    /// `ProjectStore.importConvertedVoice(fileURL:trackName:atBeat:)` —
    /// @MainActor (store). Returns the new (trackID, clipID).
    private let importer: @MainActor (URL, String, Double) throws -> (trackID: UUID, clipID: UUID)

    public init(
        datasetsRoot: URL,
        sidecarStatus: @escaping @Sendable () async -> VoiceConversionStatus,
        startSidecar: @escaping @Sendable () async throws -> VoiceConversionStatus,
        voices: @escaping @Sendable () async throws -> [VoiceDescriptor],
        train: @escaping @Sendable (VoiceTrainRequest) async throws -> Data,
        convert: @escaping @Sendable (VoiceConvertRequest) async throws -> VoiceConvertResult,
        clipSource: @escaping @MainActor (UUID) throws -> (url: URL, startBeat: Double),
        importConverted: @escaping @MainActor (URL, String, Double) throws -> (trackID: UUID, clipID: UUID)
    ) {
        self.datasetsRoot = datasetsRoot
        self.sidecarStatusProvider = sidecarStatus
        self.sidecarStarter = startSidecar
        self.voicesProvider = voices
        self.trainer = train
        self.converter = convert
        self.clipSource = clipSource
        self.importer = importConverted
        rescanDatasets()
    }

    /// Default datasets root: `~/Library/Application Support/DAWPro/
    /// VoiceDatasets/` (the `SoundBankLibrary.defaultLibraryDirectory` shape).
    public static func defaultDatasetsRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("VoiceDatasets", isDirectory: true)
    }
}

// MARK: - Value types

/// The user-copy sidecar banner (the `SketchpadBanner` twin for the RVC
/// sidecar): `canStart` is true only for installed-not-running, where the
/// Start button is the fix; `.progress` is the truthful starting state.
public struct VoicePanelBanner: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case neutral, warning, error, progress
    }

    public var message: String
    public var canStart: Bool
    public var tone: Tone

    public init(message: String, canStart: Bool, tone: Tone) {
        self.message = message
        self.canStart = canStart
        self.tone = tone
    }
}

/// One named local voice dataset: a directory of the user's own recordings.
public struct VoiceDataset: Identifiable, Equatable, Sendable {
    public var name: String
    public var directory: URL
    public var samples: [VoiceSample]
    public var id: String { name }

    public init(name: String, directory: URL, samples: [VoiceSample]) {
        self.name = name
        self.directory = directory
        self.samples = samples
    }
}

/// One training-sample audio file inside a voice dataset.
public struct VoiceSample: Identifiable, Equatable, Sendable {
    public var name: String
    public var url: URL
    public var id: String { name }

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// The honest result of a finished conversion — what the convert sheet shows
/// after the violet track lands, including the `realConversion:false` truth
/// (+ the facade's note) for the "base" smoke target.
public struct VoiceConvertOutcome: Equatable, Sendable {
    public var voiceID: String
    public var trackName: String
    public var realConversion: Bool
    public var note: String?
    public var inputSeconds: Double
    public var inferSeconds: Double

    public init(
        voiceID: String, trackName: String, realConversion: Bool, note: String? = nil,
        inputSeconds: Double, inferSeconds: Double
    ) {
        self.voiceID = voiceID
        self.trackName = trackName
        self.realConversion = realConversion
        self.note = note
        self.inputSeconds = inputSeconds
        self.inferSeconds = inferSeconds
    }
}
