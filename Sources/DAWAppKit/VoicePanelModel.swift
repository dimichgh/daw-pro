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
/// `convertClips` rides the SAME store seam the wire's `vc.convertClips` uses —
/// `ProjectStore.convertClipsToVoice(clipIds:trackName:convert:)` with the
/// client's `convert` as the injected per-clip converter. There is no parallel
/// mutation path, so UI and wire land byte-identical results: ONE undoable
/// `performEdit("Convert Voice")`, one new violet AI track carrying a converted
/// counterpart of every selected clip at the same beats, all-or-nothing.
///
/// ⚠️ **The single-clip `convertClip` was RETIRED at m24-m leg B** and must not
/// come back. It landed geometry from the CONVERTED file's on-disk duration
/// (`importConvertedVoice`'s rule) rather than from the source clip, and it did
/// not carry the clip's level-domain shaping across — so the two routes would
/// have produced measurably different clips from the same menu, which is the
/// "two instruments disagreeing" failure this tree keeps closing. One action,
/// one seam; `N = 1` is just the small case of it.
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

    /// The rights-responsibility line the panel renders verbatim. The phrase
    /// "a voice you have the rights to use" is a REQUIRED verbatim fragment
    /// (m10-p-5 brief) — pinned by `VoicePanelModelTests` — and it SURVIVED
    /// the m23-n2d policy change unchanged: the user withdrew the
    /// own-voice-only prohibition, not the rights requirement.
    public static let policyLine =
        "Train and convert with a voice you have the rights to use."
    /// The companion line, also rendered verbatim. m23-n2d: this used to
    /// assert an own-voice-only prohibition ("Never a celebrity voice…").
    /// The user WITHDREW that policy — the product supports third-party
    /// voice models and places provenance on the user. State the
    /// responsibility; do not restate the prohibition.
    public static let policyDetail =
        "You are responsible for the rights to any voice you train or convert with, including third-party voices."
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

    // MARK: - Convert Voice (the selection-driven clip action, m24-m leg B)

    /// Live progress of a conversion in flight — nil when idle. **It is also the
    /// busy flag** (`isConvertingClips`), on purpose: one truth, so a staged
    /// capture state and the live state can never disagree about whether the
    /// panel is working.
    public private(set) var clipsConvertProgress: VoiceClipsConvertProgress?
    /// User-copy error from the last convert attempt (nil on success/idle).
    /// **Store refusals arrive here VERBATIM** — `ProjectError`'s messages are
    /// already written for a human, and the refusal-bubble law says the words an
    /// agent gets over the wire are the words the user gets.
    public private(set) var clipsConvertError: String?
    /// The last successful conversion — the panel's honest result state,
    /// carrying leg A's non-fatal `warnings` and the `realConversion:false` +
    /// note truth for the "base" smoke target.
    public private(set) var lastClipsConversion: VoiceClipsConvertOutcome?

    /// True while a conversion is running. Conversion is MINUTES-class for a
    /// real RVC model over N clips (leg A converts them serially), which is why
    /// this leg ships a legible progress block rather than the single-clip
    /// sheet's brief busy label.
    public var isConvertingClips: Bool { clipsConvertProgress != nil }

    /// The picked voice (nil = nothing picked, so the primary is disarmed) and
    /// the pitch shift the run will use.
    ///
    /// ⭐ **MODEL STATE, NOT VIEW `@State`, AND THAT IS DELIBERATE.** The ARMED
    /// primary button — violet, glowing, the single most important pixel in the
    /// panel — exists only once a voice is picked, and a `@State` selection is
    /// unreachable from `debug.voicePanel`, which makes that state
    /// unphotographable. "A UI phase is not done until someone has looked at
    /// it" is not satisfiable for a state no capture can stage. It is also the
    /// honest home: which voice to convert with is a parameter of the action,
    /// not a presentation detail.
    public var selectedConvertVoiceID: String?
    /// The facade's own bounds are ±24 semitones (`VoiceConvertRequest`); the
    /// view clamps to them, and this holds whatever it was given.
    public var convertPitchSemitones: Int = 0

    /// Per-clip converter results, accumulated across one `convertClips` run so
    /// the outcome can report the facade's honesty fields. Reset at each start;
    /// a property rather than a local because the accumulation happens inside an
    /// escaping closure the store owns.
    private var clipsConvertResults: [VoiceConvertResult] = []

    /// The wire's default-track-name rule, shared verbatim
    /// (`vc.convertVocals` / `vc.convertClips`: `"Voice: <voiceId>"`).
    public static func defaultTrackName(voiceID: String) -> String {
        "Voice: \(voiceID)"
    }

    /// Converts EVERY clip in `clipIDs` to `voiceID` and lands the matching set
    /// on ONE new violet AI track at the same beats — the m24-m action the user
    /// ratified 2026-08-13, through `ProjectStore.convertClipsToVoice` (leg A).
    /// Returns true when the track landed.
    ///
    /// ⭐ **THE UI GOES THROUGH THE SAME STORE SEAM AS THE WIRE** (the m10-n-3
    /// law): `vc.convertClips` and this method both call
    /// `convertClipsToVoice(clipIds:trackName:convert:)` with a converter
    /// closure, so there is no parallel mutation path and the two land
    /// byte-identical results — ONE `performEdit("Convert Voice")`, all-or-
    /// nothing, geometry taken from the SOURCE clips.
    ///
    /// **Progress is reported from inside the converter closure**, which is the
    /// only place that knows which clip is being worked on. The store's per-clip
    /// order is extract → convert → land, so entering the closure for clip *k*
    /// means clip *k*'s extraction is done; returning from it means clip *k* is
    /// finished. Between the two the phase reads `.preparing`, which is the
    /// truth (the next clip is being rendered) rather than a frozen bar.
    ///
    /// **Nothing here re-validates the selection.** Empty sets, duplicate ids,
    /// unknown ids, MIDI clips and overlapping pairs are refused by leg A before
    /// any expensive work, each with a teaching message that lands in
    /// `clipsConvertError` verbatim.
    ///
    /// - Parameters:
    ///   - clipIDs: the selected clips. Order is irrelevant — the result is
    ///     ordered by start beat.
    ///   - trackName: nil/empty resolves to `defaultTrackName(voiceID:)` HERE,
    ///     because the store takes the name verbatim (an empty string would land
    ///     as an empty string).
    ///   - startedAt: injected so a test can pin the elapsed readout without
    ///     sleeping.
    @discardableResult
    public func convertClips(
        clipIDs: [UUID], voiceID: String, pitchSemitones: Int = 0,
        trackName: String? = nil, startedAt: Date = Date()
    ) async -> Bool {
        guard clipsConvertProgress == nil else { return false }
        clipsConvertError = nil
        lastClipsConversion = nil
        clipsConvertResults = []

        let resolvedName = (trackName?.isEmpty == false)
            ? trackName! : Self.defaultTrackName(voiceID: voiceID)
        clipsConvertProgress = VoiceClipsConvertProgress(
            total: clipIDs.count, completed: 0, currentClipName: nil,
            phase: .preparing, startedAt: startedAt)
        defer { clipsConvertProgress = nil }

        do {
            // m24-n: the display name comes from the loaded voice list — the
            // same list the picker row showed — falling back to the id when the
            // list has not loaded. Recorded at conversion time so it survives
            // the voice's deletion.
            let provenance = VoiceProvenance(
                voiceId: voiceID,
                voiceName: voices.first { $0.id == voiceID }?.name ?? voiceID,
                pitchSemitones: pitchSemitones,
                convertedAt: startedAt)
            let result = try await clipsConverter(clipIDs, resolvedName, provenance) { _, source in
                self.clipsConvertProgress?.beginConverting(clipNamed: source.name)
                let converted = try await self.converter(VoiceConvertRequest(
                    inputPath: source.url.path, voiceId: voiceID,
                    pitchSemitones: pitchSemitones))
                self.clipsConvertResults.append(converted)
                self.clipsConvertProgress?.finishOne()
                return URL(fileURLWithPath: converted.outputPath)
            }
            lastClipsConversion = VoiceClipsConvertOutcome(
                voiceID: voiceID, result: result,
                // ONE not-real conversion makes the whole set not-real: the
                // honesty strip must not be hidden by a majority vote.
                realConversion: clipsConvertResults.allSatisfy(\.realConversion),
                note: clipsConvertResults.compactMap(\.note).first,
                totalInferSeconds: clipsConvertResults.reduce(0) { $0 + $1.inferSeconds })
            return true
        } catch {
            clipsConvertError = Self.userCopy(for: error)
            return false
        }
    }

    /// Clears the panel's transient convert state (open/close reset).
    /// Deliberately does NOT clear a run in flight — the progress belongs to the
    /// work, not to the presentation — and does NOT clear the picked voice,
    /// which `resetConvertChoice` owns: the view's `.task` calls this on every
    /// appearance, so folding the choice in here would wipe a staged (or a
    /// user's) pick on the next body evaluation.
    public func resetClipsConvertState() {
        clipsConvertError = nil
        lastClipsConversion = nil
    }

    /// Clears the picked voice and pitch — called ONCE when the panel is opened
    /// on a new set of clips, so a fresh run never inherits the last one's
    /// parameters.
    public func resetConvertChoice() {
        selectedConvertVoiceID = nil
        convertPitchSemitones = 0
    }

    /// Capture staging (`setVoicesForCapture` precedent): plants a progress
    /// state so a shot can show the converting face without a live sidecar and
    /// without waiting minutes for a real conversion. `nil` clears it.
    public func setClipsConvertProgressForCapture(_ progress: VoiceClipsConvertProgress?) {
        clipsConvertProgress = progress
    }

    /// Capture staging: plants a finished outcome (warnings included) so the
    /// result face can be photographed.
    public func setClipsConversionForCapture(_ outcome: VoiceClipsConvertOutcome?) {
        lastClipsConversion = outcome
        if outcome != nil { clipsConvertError = nil }
    }

    /// Capture staging: plants a refusal so the error face can be photographed
    /// with the store's own words. An EMPTY string clears it rather than
    /// planting a blank one — a refusal strip with no words in it is a claim
    /// that something went wrong and a refusal to say what.
    public func setClipsConvertErrorForCapture(_ message: String?) {
        clipsConvertError = (message?.isEmpty == true) ? nil : message
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
    /// ⚠️ DATASET material only (`addClipAsSample`): it resolves a clip to its
    /// BACKING recording, which is the right thing to copy into a training
    /// set and the WRONG thing to feed a converter (m24-o). Conversion goes
    /// through `clipsConverter`, which extracts per clip inside the store.
    private let clipSource: @MainActor (UUID) throws -> (url: URL, startBeat: Double)
    /// `ProjectStore.convertClipsToVoice(clipIds:trackName:provenance:convert:)`
    /// — the m24-m leg A action, injected so DAWAppKit never learns what an
    /// engine or a media service is. This is the SAME method `CommandRouter`
    /// calls for `vc.convertClips`; a test passes a stub.
    ///
    /// ⚠️ The third element is the m24-n `VoiceProvenance`. It is threaded
    /// through THIS route as well as the wire's on purpose: a UI route that
    /// omitted it would convert perfectly, look perfectly correct, and silently
    /// produce tracks whose voice is never embedded — a valid-looking answer
    /// that is wrong, which is this tree's characteristic failure mode.
    private let clipsConverter: @MainActor ([UUID], String, VoiceProvenance?, ClipVoiceConverting) async throws -> ClipVoiceConversionResult

    public init(
        datasetsRoot: URL,
        sidecarStatus: @escaping @Sendable () async -> VoiceConversionStatus,
        startSidecar: @escaping @Sendable () async throws -> VoiceConversionStatus,
        voices: @escaping @Sendable () async throws -> [VoiceDescriptor],
        train: @escaping @Sendable (VoiceTrainRequest) async throws -> Data,
        convert: @escaping @Sendable (VoiceConvertRequest) async throws -> VoiceConvertResult,
        clipSource: @escaping @MainActor (UUID) throws -> (url: URL, startBeat: Double),
        convertClips: @escaping @MainActor ([UUID], String, VoiceProvenance?, ClipVoiceConverting) async throws -> ClipVoiceConversionResult
    ) {
        self.datasetsRoot = datasetsRoot
        self.sidecarStatusProvider = sidecarStatus
        self.sidecarStarter = startSidecar
        self.voicesProvider = voices
        self.trainer = train
        self.converter = convert
        self.clipSource = clipSource
        self.clipsConverter = convertClips
        rescanDatasets()
    }

    /// Default datasets root: `~/Library/Application Support/DAWPro/
    /// VoiceDatasets/` (m23-n1b — `DAWCore.AppDirectories` owns the rule; this
    /// is one category of it).
    public static func defaultDatasetsRoot() -> URL {
        AppDirectories.applicationSupport(.voiceDatasets)
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

/// The per-clip converter seam leg A takes: given a source clip id and the
/// audio that clip presents, hand back the converted file.
public typealias ClipVoiceConverting =
    @MainActor (UUID, ClipConversionSource) async throws -> URL

/// How far a multi-clip conversion has got — the panel's progress block.
///
/// ⭐ **A SPINNER IS NOT PROGRESS.** A real RVC conversion is seconds-to-minutes
/// PER CLIP and leg A converts them serially, so a bare spinner would leave the
/// user unable to tell a working conversion from a hung one for minutes at a
/// time. Every field here exists to answer one of the two questions that
/// actually get asked: *which clip of how many* (`completed`/`total`/
/// `currentClipName`) and *is it still alive* (`phase` moves, and `startedAt`
/// drives a ticking elapsed readout).
///
/// ⚠️ **THE FRACTION IS COMPLETED WORK ONLY, NEVER AN ESTIMATE.** It steps at
/// clip boundaries because that is the only place this path has a fact; a smooth
/// bar interpolated over an unknown per-clip duration would be an invented
/// number, which is the same failure the Voice panel's TRAIN slot refuses (fake
/// progress is structurally impossible there, and it is here too).
public struct VoiceClipsConvertProgress: Equatable, Sendable {

    /// Where the run is inside one clip's cycle. Leg A's per-clip order is
    /// extract → convert → copy, then ONE edit at the end.
    public enum Phase: Equatable, Sendable {
        /// Rendering the next clip's own audio (leg A's offline extraction).
        case preparing
        /// The voice engine is working on `currentClipName`.
        case converting
        /// Every clip is converted; the new track is being added.
        case landing
    }

    public var total: Int
    /// Clips whose conversion has RETURNED. Never optimistic.
    public var completed: Int
    /// The clip the engine is on (nil before the first one starts).
    public var currentClipName: String?
    public var phase: Phase
    /// When the run began — the view derives the ticking elapsed readout from
    /// this, so the model holds no timer and allocates nothing per second.
    public var startedAt: Date

    public init(total: Int, completed: Int, currentClipName: String?,
                phase: Phase, startedAt: Date) {
        self.total = total
        self.completed = completed
        self.currentClipName = currentClipName
        self.phase = phase
        self.startedAt = startedAt
    }

    /// 1-based index of the clip being worked on, clamped so the readout never
    /// says "clip 6 of 5" during the landing phase.
    public var currentIndex: Int { min(completed + 1, max(total, 1)) }

    /// Completed work as a 0…1 fraction. Reaches 1 only when every clip is done.
    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    /// The SF Mono step readout: `CLIP 2/5`.
    public var stepText: String { "CLIP \(currentIndex)/\(total)" }

    /// One plain-language line naming what is happening right now (Rule 6 —
    /// beginner-readable, no wire-speak).
    public var detailText: String {
        switch phase {
        case .landing:
            return "Adding the new track…"
        case .converting:
            guard let name = currentClipName else { return "Converting…" }
            return "Converting \u{201C}\(name)\u{201D}…"
        case .preparing:
            guard let name = currentClipName else { return "Preparing the first clip…" }
            return "Preparing the clip after \u{201C}\(name)\u{201D}…"
        }
    }

    /// Elapsed whole seconds at `now` — the "it is still alive" signal (the
    /// M10-b truthful-starting-state idiom).
    public func elapsedSeconds(at now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt)))
    }

    /// The engine has picked up `name`.
    mutating func beginConverting(clipNamed name: String) {
        currentClipName = name
        phase = .converting
    }

    /// One clip finished; the next one's extraction starts (or, at the end, the
    /// track lands).
    mutating func finishOne() {
        completed = min(completed + 1, total)
        phase = completed >= total ? .landing : .preparing
    }
}

/// The honest result of a finished multi-clip conversion — what the panel shows
/// after the violet track lands: leg A's own report (track, per-clip landings,
/// non-fatal warnings) plus the facade's `realConversion:false` truth and note
/// for the "base" smoke target.
public struct VoiceClipsConvertOutcome: Equatable, Sendable {
    public var voiceID: String
    /// Leg A's report, verbatim. `warnings` is NON-fatal — the conversion
    /// happened; something is worth knowing.
    public var result: ClipVoiceConversionResult
    /// False when ANY clip's conversion was not a real one. One not-real
    /// conversion makes the whole set not-real; the honesty strip is never
    /// hidden by a majority vote.
    public var realConversion: Bool
    /// The facade's own note, verbatim (present for "base").
    public var note: String?
    /// Total engine time across the set — an SF Mono readout, never a claim
    /// about wall-clock.
    public var totalInferSeconds: Double

    public init(voiceID: String, result: ClipVoiceConversionResult,
                realConversion: Bool, note: String? = nil, totalInferSeconds: Double) {
        self.voiceID = voiceID
        self.result = result
        self.realConversion = realConversion
        self.note = note
        self.totalInferSeconds = totalInferSeconds
    }
}
