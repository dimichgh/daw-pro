import DAWCore
import Foundation

// MARK: - The engine seam

/// What a sing job needs from the singing sidecar. `SingingSidecarManager` conforms; tests script a fake.
public protocol SingJobEngine: Sendable {
    func status() async -> SingingSidecarStatus
    func start() async throws -> SingingSidecarStatus
    /// Why the sidecar last stopped, recorded BEFORE its first signal (ARCH-REVIEW FIX-NOW #1), so a render
    /// that fails because the engine was evicted can be told from one that failed because it crashed.
    func lastStopClassification() async -> SingingStopReason?
}

extension SingingSidecarManager: SingJobEngine {}

// MARK: - Request, status, errors

/// One "sing this clip" request (design §6 row 14, `sing.render`, once the wire resolves its parameters).
public struct SingJobRequest: Sendable, Equatable {
    /// The melody clip.
    public var clipID: UUID
    /// Whole octaves, −2...2. `"auto"` is resolved by the caller (`sing.proposeKey`'s octave-only pick) before
    /// it reaches the job: the job never chooses a key.
    public var octaveShift: Int
    public var voice: SingJobVoice
    /// nil = the first-take seed (`SingJobRequestBuilder.firstTakeSeed`); "Try another take" passes
    /// `SingJobRequestBuilder.anotherTakeSeed()`.
    public var seed: UInt64?
    /// nil = "Vocals — <voice name>" (design §4.5).
    public var trackName: String?
    /// The semitones the song was moved by as part of this take's key choice (`project.transpose` before the
    /// render), for the provenance only (design §3.9). 0 when the key was kept.
    public var songTransposeSemitones: Int
    public var options: SingRenderOptions
    /// True when an AI agent asked (the wire); the progress card tags it "AGENT", else "SING" (design §5.5).
    public var fromAgent: Bool
    /// p2-sing-x6 (design `2026-10-06-p2-sing-expansion.md` §4.4): up to `SingJobPart.maximumCount` more lines,
    /// sung after the lead in this order, each landing on its own new track, every landed line in ONE undo step
    /// ("Land Sung Harmony"). Empty = today's job, byte for byte (§9.2 S5).
    public var parts: [SingJobPart]
    /// The key a harmony part is counted in (`sing.render`'s `key`/`mode`); nil = the song's estimated key.
    public var key: SongKey?

    public init(clipID: UUID, octaveShift: Int = 0, voice: SingJobVoice = .builtIn, seed: UInt64? = nil,
                trackName: String? = nil, songTransposeSemitones: Int = 0, options: SingRenderOptions = .v1,
                fromAgent: Bool = false, parts: [SingJobPart] = [], key: SongKey? = nil) {
        self.clipID = clipID
        self.octaveShift = octaveShift
        self.voice = voice
        self.seed = seed
        self.trackName = trackName
        self.songTransposeSemitones = songTransposeSemitones
        self.options = options
        self.fromAgent = fromAgent
        self.parts = parts
        self.key = key
    }
}

/// Design §4.2's phases. `landed` and `checking` come after the track is in the song; `done`, `failed` and
/// `cancelled` are terminal.
public enum SingJobPhase: String, Sendable, Equatable, Codable {
    case queued, waitingForModel, startingEngine, preparingVoice, singing, finishing, landed, checking
    case done, failed, cancelled

    public var isTerminal: Bool { self == .done || self == .failed || self == .cancelled }
    /// The track is in the song: nothing can be cancelled any more (undo removes it).
    public var hasLanded: Bool { self == .landed || self == .checking || self == .done }
}

/// Why a job ended `failed`: a stable code for the wire, the sentence a beginner reads, and the technical
/// detail (a facade message, a log path) for whoever debugs it.
public struct SingJobFailure: Error, Sendable, Equatable, Codable {
    public var code: String
    public var message: String
    public var detail: String?

    public init(code: String, message: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }
}

/// What landed, and what the checks after landing found.
public struct SingJobResult: Sendable, Equatable, Codable {
    public var trackID: UUID
    public var clipID: UUID
    public var loudness: BounceLoudnessReport?
    public var gates: SingGateReport
    public var melodyChanged: Bool
    public var transposedSemitones: Int
    /// Filled while `checking` (design §4.6); nil before.
    public var noteAccuracy: SungNoteAccuracy?
    public var wordCheck: SungWordCheck?
}

/// The one payload `submit`, `status`, `statuses` and `cancel` all return (the `SoundBankDownloadStatus`
/// rule: one job, one response shape).
public struct SingJobStatus: Sendable, Equatable, Codable {
    public var jobID: String
    public var clipID: UUID
    public var phase: SingJobPhase
    /// The sentence the progress card shows now (design §5.5/§5.7).
    public var stageText: String
    /// The unit being sung, 1-based ("line i of n"); nil outside `singing`/`preparingVoice`.
    public var unitIndex: Int?
    public var unitCount: Int
    /// 0...1, weighted by unit length (design §4.2). 1 once the take is assembled.
    public var progress: Double
    /// Seconds to go, from the measured warm real-time factor and the cold start (design §4.2); nil when it
    /// cannot be known (waiting for another model) or once the take has landed.
    public var etaSeconds: Double?
    /// The model a `waitingForModel` job waits for.
    public var waitingFor: String?
    /// Set by `cancel`; the job stops at the next unit boundary and only then reads `cancelled`.
    public var cancelRequested: Bool
    /// The take's seed (design §4.4).
    public var seed: UInt64
    /// 1-based lines that came back non-finite or silent and were rendered again at seed + 1.
    public var retriedUnits: [Int]
    /// Units served from the phrase cache / rendered by the engine in this job.
    public var cachedUnits: Int
    public var renderedUnits: Int
    /// Times the engine gave way to another model mid-job (design §2.7 R3), and restarts after a crash.
    public var yields: Int
    public var engineRestarts: Int
    /// The plan's warnings (held words, chords, a split line), as sentences.
    public var warnings: [String]
    /// Things worth telling the user about the take: the melody changed or moved, a quiet take, the song
    /// generator running outside DAW Pro, a word check that could not run.
    public var notices: [String]
    public var result: SingJobResult?
    /// The gate report of a take that did NOT land (the result carries the landed one's).
    public var gates: SingGateReport?
    public var error: SingJobFailure?
    /// Where a finished take was kept when it could not land (a different project was open).
    public var keptTakePath: String?
    public var fromAgent: Bool
    public var submittedAt: Date
    public var finishedAt: Date?
    /// p2-sing-x6: one entry per line of a job that had parts (the lead first); nil for a single-part job, whose
    /// status is exactly today's. In a parts job `unitIndex`/`unitCount` count the lines of the part being sung,
    /// `retriedUnits` numbers lines across the whole job, and `result` is the lead's (else the first landed part's).
    public var parts: [SingJobPartStatus]? = nil
}

/// One line of a parts job (p2-sing-x6, design §4.4, §4.7 `sing.jobStatus.parts`).
public struct SingJobPartStatus: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Equatable, Codable {
        /// Not started yet.
        case waiting
        /// Its lines are being sung.
        case singing
        /// Every line is sung; it is being put together and checked.
        case sung
        case landed, failed, cancelled
    }

    /// `SungVocalProvenance.PartRole`: "lead", "harmony" or "double".
    public var role: String
    /// What the sentences call it: "lead", "third above", "chord notes", a clip's name, "double".
    public var name: String
    public var state: State
    public var unitCount: Int
    /// The whole octaves this line is sung at (its own fit, §4.5).
    public var octaveShift: Int
    public var seed: UInt64
    public var voiceId: String
    /// §14's range line ("Fits your voice." …); nil when no fit was made (a given octave, the lead, a double, a
    /// voice with no known range).
    public var range: String?
    /// False when even the best octave leaves the line outside the voice's usual range: the amber line, a warning.
    public var fits: Bool
    /// The plan's own warnings and the range warning, as sentences.
    public var warnings: [String]
    public var trackID: UUID?
    public var clipID: UUID?
    public var trackName: String
    public var gates: SingGateReport?
    public var error: SingJobFailure?
}

/// Refusals a caller gets back at once (design §6's codes; `code` is the wire's).
public enum SingJobError: Error, Equatable, LocalizedError {
    case clipNotFound(UUID)
    case planRefused(SingPlanRefusal)
    case engineNotInstalled(String)
    case engineNeedsUpdate(String)
    case queueFull(capacity: Int)
    case jobNotFound(String)
    case jobFinished(String)
    // p2-sing-x6 (design §4.7's refusals):
    /// More than `SingJobPart.maximumCount` parts.
    case tooManyParts(maximum: Int)
    /// A harmony part's key could not be worked out (`HarmonyRefusal`).
    case harmony(HarmonyRefusal)
    /// A clip part names a clip that is not in the song.
    case partClipNotFound(UUID)
    /// A part's own plan refused (its clip's words do not fit its notes, …); `part` is its name.
    case partRefused(part: String, SingPlanRefusal)
    /// A part's setting is out of range; `field` is the wire's name for it.
    case partInvalid(field: String, message: String)

    public var code: String {
        switch self {
        case .clipNotFound: return "clipNotFound"
        case .planRefused(let refusal):
            switch refusal {
            case .octaveShiftInvalid: return "singOctaveShiftInvalid"
            case .audioClip: return "singNeedsMIDIClip"
            case .noNotes: return "singClipHasNoNotes"
            case .drumTrack: return "singDrumTrack"
            case .lyrics(.noWords): return "singNeedsLyrics"
            case .lyrics(.tooManyWords): return "lyricsTooManyWords"
            case .lyrics(.notEnglish): return "lyricsNotEnglish"
            case .lyrics(.scriptMismatch): return "lyricsScriptMismatch"
            case .lyrics(.languageUnsupported): return "lyricsLanguageUnsupported"
            // PROVISIONAL codes: these refusals exist in the planner but have no row in design §6.
            case .lyrics(.markupNeedsMoreNotes), .lyrics(.markedWordDoesNotFit): return "lyricsMarkupDoesNotFit"
            case .targetOutOfRange: return "singTargetOutOfRange"
            case .noteTooLong: return "singNoteTooLong"
            case .wordTooLong: return "singWordTooLong"
            }
        case .engineNotInstalled: return "singEngineNotInstalled"
        case .engineNeedsUpdate: return "singEngineNeedsUpdate"
        case .queueFull: return "singQueueFull"
        case .jobNotFound: return "singJobNotFound"
        case .jobFinished: return "singJobFinished"
        case .tooManyParts: return "singTooManyParts"
        case .harmony(let refusal): return refusal.code
        case .partClipNotFound: return "singPartClipNotFound"
        case .partRefused(_, let refusal): return SingJobError.planRefused(refusal).code
        case .partInvalid: return "singPartInvalid"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .clipNotFound(let id):
            return "No clip with id \(id.uuidString) — pick a melody clip that is in the song."
        case .planRefused(let refusal):
            return refusal.sentence
        case .engineNotInstalled(let message), .engineNeedsUpdate(let message):
            return message
        case .queueFull(let capacity):
            return capacity == 1
                ? "A take is already waiting to be sung. Wait for it to finish, then try again."
                : "\(capacity) takes are already waiting to be sung. Wait for one to finish, then try again."
        case .jobNotFound(let id):
            return "No sing job with id \"\(id)\" — sing.jobStatus with no id lists the recent ones."
        case .jobFinished(let id):
            return "The sing job \"\(id)\" has already finished or landed, so there is nothing to stop. "
                + "Undo removes a take that landed."
        case .tooManyParts(let maximum):
            // §14 "Too many parts".
            return "You can add up to \(maximum) harmony parts."
        case .harmony(let refusal):
            return refusal.sentence
        case .partClipNotFound(let id):
            // PROVISIONAL (no §14 row).
            return "No clip with id \(id.uuidString) — pick another melody clip that is in the song."
        case .partRefused(let part, let refusal):
            // PROVISIONAL (§4.2: "the assigner's own refusal sentence names the part").
            return "The part '\(part)': \(refusal.sentence)"
        case .partInvalid(_, let message):
            return message
        }
    }
}

// MARK: - The coordinator

/// THE sing job (design §4, item p2-sing-e): plans a melody clip into units, renders them one at a time
/// through the singing sidecar, keeps a phrase cache, assembles and gains the take, runs the landing gates,
/// lands ONE new violet track per line of the job (the lead, then each harmony part) in ONE undo step
/// ("Land Sung Vocal" / "Land Sung Harmony"), then checks the notes and the words.
///
/// ## ⚠️ ONE INSTANCE PER APP (the `SoundBankDownloadCoordinator` rule, design §4.1)
/// `DAWProApp` builds exactly one and hands the SAME actor to `CommandRouter` (the wire) and to the Sing
/// sheet. Two instances would mean two queues, two caches in use at once and a job the other surface
/// cannot see.
///
/// ## Start, then poll; cancel never invents a terminal state
/// `submit` plans (refusals come back at once, in words), checks the engine is installed, queues the job and
/// returns. Every later outcome is read by polling `status`. `cancel` only REQUESTS: a job that has started
/// stops at its next unit boundary (the model cannot stop inside a unit, design §4.2) and reads `cancelled`
/// only after the unit in flight has returned and nothing has landed. A job still in the queue has started
/// nothing, so leaving the queue IS its whole unwind: it reads `cancelled` at once. Once landing has started,
/// `cancel` is REFUSED (`jobFinished`, design 2026-10-06 §16 S1): a cancel is honoured or refused, never ignored.
///
/// ## Never `Task.cancel()`
/// Cancelling a task parked in `Task.sleep` aborts this build's test process
/// (`ModelLifecycleCoordinator.cancelIdleUnload`'s measured note). Every wait here polls a flag after an
/// injected sleep; no task this type starts is ever cancelled.
///
/// ## Residency (design §2.7)
/// - **R2**: before the engine boots, the job waits while any OTHER model is busy (or booting, or booted in
///   the last `freshBootGraceSeconds` and not yet given its first job [A]: the window between a model's
///   boot and its job's submission, in which booting SoulX would evict it).
/// - **R3**: a render that fails because SoulX was evicted (`lastStopClassification() ==
///   .evictedByCoordinator`, which reads as a yield until ARCH-REVIEW Q2's eviction reason exists) is a
///   YIELD: the job waits (R2) and renders that unit again; finished units are already in hand.
/// - **R5**: every unit render registers as a lifecycle job `"<jobId>#<unit>"` while it runs; a job with parts
///   (p2-sing-x6) registers `"<jobId>#<part>.<unit>"` (design 2026-10-06 §4.4: a shape extension, the lead is part 0).
/// - **L6**: after a watchdog kill or an unexplained stop, the residency record is reconciled
///   (`noteStoppedExternally`) before the engine is started again.
public actor SingJobCoordinator {

    public struct Configuration: Sendable {
        /// How many jobs may WAIT behind the one rendering (design §4.2: 4 [A]).
        public var queueCapacity: Int
        /// The rate takes are rendered and landed at.
        public var outputSampleRate: Int
        /// R2's poll (design §2.7: 2 s).
        public var modelPollSeconds: Double
        /// How often a job re-reads an engine that is starting or still loading.
        public var enginePollSeconds: Double
        /// [A] See the type doc: a model booted this recently with no job yet still counts as busy.
        public var freshBootGraceSeconds: Double
        /// For the ETA: the measured cold start (7–20 s, design §2.6) and warm RTF (0.38–0.51, the slow end).
        public var coldStartSeconds: Double
        public var warmRealTimeFactor: Double
        /// Finished jobs kept for `statuses` (design §6 row 15 lists the last 20).
        public var historyLimit: Int
        /// Every wait's only sleep. `nil` = the real `Task.sleep`, supplied in `init`'s BODY (an async closure
        /// as a default argument miscompiles across modules in Swift 6.3.3; `scripts/gates/async-default-dup.py`).
        public var sleepSeconds: @Sendable (Double) async -> Void
        public var now: @Sendable () -> Date
        /// R4: is a song generator running that DAW Pro did not start? nil = ask the lifecycle coordinator
        /// (`residency(includeProcessDetail: true)`: one `ps` and one `lsof` per job).
        public var songGeneratorRunsOutside: (@Sendable () async -> Bool)?
        /// [A] The startup sweep of `takes/` (W8-RV6 N3) deletes only files last modified at least this long
        /// before the coordinator was made: a take a job of ANOTHER running copy of the app is still finishing,
        /// landing or checking (minutes) is never that old. 1 hour.
        public var orphanTakeMinimumAgeSeconds: Double
        /// Reads a written take back (L3 is measured on the written bytes). nil = `SingWAV.read(url).mono`. A test
        /// seam: a read-back that fails after a good write is otherwise unreachable (W8-RV6 N3).
        public var readTakeBack: (@Sendable (URL) throws -> [Float])?

        public init(queueCapacity: Int = 4, outputSampleRate: Int = SingJobRequestBuilder.defaultOutputSampleRate,
                    modelPollSeconds: Double = 2, enginePollSeconds: Double = 0.5,
                    freshBootGraceSeconds: Double = 30, coldStartSeconds: Double = 20,
                    warmRealTimeFactor: Double = 0.51, historyLimit: Int = 50,
                    sleepSeconds: (@Sendable (Double) async -> Void)? = nil,
                    now: @escaping @Sendable () -> Date = { Date() },
                    songGeneratorRunsOutside: (@Sendable () async -> Bool)? = nil,
                    orphanTakeMinimumAgeSeconds: Double = 3_600,
                    readTakeBack: (@Sendable (URL) throws -> [Float])? = nil) {
            self.queueCapacity = queueCapacity
            self.outputSampleRate = outputSampleRate
            self.modelPollSeconds = modelPollSeconds
            self.enginePollSeconds = enginePollSeconds
            self.freshBootGraceSeconds = freshBootGraceSeconds
            self.coldStartSeconds = coldStartSeconds
            self.warmRealTimeFactor = warmRealTimeFactor
            self.historyLimit = historyLimit
            self.sleepSeconds = sleepSeconds ?? { seconds in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            }
            self.now = now
            self.songGeneratorRunsOutside = songGeneratorRunsOutside
            self.orphanTakeMinimumAgeSeconds = orphanTakeMinimumAgeSeconds
            self.readTakeBack = readTakeBack
        }
    }

    // MARK: Copy (design §5.7; PROVISIONAL where §5.7 has no row)

    public enum Copy {
        public static let starting = "Starting the singing engine… (about 20 seconds)"
        public static let waitingForSongGenerator =
            "Waiting for the song generator to finish — it's using most of this Mac's memory."
        /// PROVISIONAL: §5.7 names only the song generator.
        public static func waiting(for model: String) -> String {
            "Waiting for \(model) to finish — it's using most of this Mac's memory."
        }
        public static let yielded = "Paused while the song generator runs; I'll carry on after."
        public static let songGeneratorOutside =
            "The song generator is also running outside DAW Pro, so this Mac may run short of memory."
        public static func singing(line: Int, of count: Int) -> String { "Singing line \(line) of \(count)…" }
        public static let stopping = "Stopping after this line…"
        public static func badUnit(line: Int) -> String {
            "One line didn't come out right (line \(line)). Try another take."
        }
        public static let crash = "The singing engine stopped unexpectedly."
        public static let watchdogFootprint =
            "The singing engine used too much memory, so I stopped it. Try shorter lines."
        public static let watchdogPressure = "Your Mac ran very low on memory, so I stopped the singing engine. "
            + "Close other apps or the song generator and try again."
        public static func engineWontStart(_ cause: String) -> String { "The singing engine couldn't start: \(cause)" }
        public static let quietTake =
            "This take came out quieter than usual because of a sharp peak; turn the track up if you need to."
        public static let checkingWords = "Checking the words…"
        // PROVISIONAL (no §5.7 row):
        public static let queued = "Waiting for the take before this one to finish…"
        public static let preparingVoice = "Getting the voice ready…"
        public static let finishing = "Putting the take together…"
        public static let landed = "Added to your song."
        public static let cancelled = "Stopped. Nothing was added to your song."
        public static let engineStopped = "The singing engine was stopped before this take finished."
        public static func wordCheckFailed(_ cause: String) -> String { "The word check couldn't run: \(cause)" }

        // p2-sing-x6 (design `2026-10-06-p2-sing-expansion.md` §14):
        /// §14 "Progress, parts".
        public static func singingPart(_ part: Int, of parts: Int, line: Int, of count: Int) -> String {
            "Singing part \(part) of \(parts) · line \(line) of \(count)…"
        }
        /// §14 "A part failed" (its [Try again] is the card's button, not text).
        public static func partFailed(_ name: String) -> String { "The part '\(name)' didn't come out right." }
        /// PROVISIONAL (no §14 row): the names a parts job's sentences use for its lines.
        public static let leadPartName = "lead"
        public static let chordNotesPartName = "chord notes"
        public static let doublePartName = "double"
        /// PROVISIONAL (no §14 row): the style pass could not run, so the take landed as sung (design §5.4).
        public static let styleNotApplied = "I couldn't add the singing style to this take, so it is sung as is."
        public static func styleNotApplied(part: String) -> String {
            "I couldn't add the singing style to the part '\(part)', so it is sung as is."
        }
        /// PROVISIONAL (no §14 row): a part whose best octave is still out of range, named (§4.5).
        public static func partRange(_ name: String, _ sentence: String) -> String { "The part '\(name)': \(sentence)" }

        /// §5.7 "Results".
        public static func results(notes: SungNoteAccuracy?, words: SungWordCheck?) -> String {
            var parts: [String] = []
            if let notes {
                if notes.inTune {
                    parts.append("In tune")
                } else if notes.offBars.isEmpty {
                    // Every note hit, but too little of the take had a clear pitch to call it in tune.
                    parts.append("Some notes may be off.")
                } else {
                    parts.append("Some notes may be off (bars \(notes.offBars.map(String.init).joined(separator: ", "))).")
                }
            }
            if let words { parts.append(SingWordCheck.sentence(words)) }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: State

    /// One line a job sings: the lead (always first), or one of `SingJobRequest.parts` (p2-sing-x6). Snapshotted
    /// on the main actor at submit, like the lead always was.
    private struct Part: Sendable {
        /// `SungVocalProvenance.PartRole`.
        let role: String
        let name: String
        let planning: SungVocalPlanning
        let voice: SingJobVoice
        let seed: UInt64
        let trackName: String
        /// nil = `Track`'s defaults (the lead, as today).
        let pan: Double?
        let volume: Double?
        /// The lyrics as they were when the take was planned (the provenance's snapshot).
        let lyricsText: String
        /// Planned note i's 1-based bar, for the amber notes notice.
        let noteBars: [Int]
        /// The clip's singing style as planned (normalised; a harmony's per-note choices already moved to its
        /// notes by `HarmonyPlanner.transientClip`), and its notes' velocities by id.
        let style: SingStyle?
        let velocities: [UUID: Int]
        let harmony: SungVocalHarmony?
        /// A part sung from ANOTHER clip, which landing checks on its own.
        let ownSource: SungVocalPartSource?
        /// A harmony or chord-notes part: how it was derived and its planned notes, which landing derives again
        /// over the project as it is then (design §16; W8-RV6 S2). nil for the lead, a double, another clip.
        let derived: SungVocalDerivedPart?
        let range: String?
        let fits: Bool
        let warnings: [String]
        /// The index of its first unit in the job's flattened `weights`.
        let firstUnit: Int
    }

    private struct Job {
        var status: SingJobStatus
        let request: SingJobRequest
        let parts: [Part]
        /// Unit weights across every part, in render order.
        let weights: [Double]
        var doneWeight: Double = 0
        /// Takes written for this job (deleted when it ends, or once landed and checked).
        var takeURLs: [URL] = []
        /// The engine's identity from its last healthy read in this job: the provenance's, even when the
        /// engine has gone away by the time the take lands.
        var identity: SingEngineIdentity?
        /// Set at the last cancel check before the landing, with no suspension in between (design §16, W8-RV6 S1):
        /// from then on `cancel` refuses with `jobFinished`, so a cancel is either honoured or refused, never
        /// accepted and then ignored.
        var landingStarted = false

        /// A job that had parts. A job without any keeps today's every byte (S5): lifecycle ids, sentences,
        /// `landSungVocal`, no `partRole`.
        var hasParts: Bool { !request.parts.isEmpty }
        var lead: Part { parts[0] }
    }

    /// How a run ends early. Internal: callers see the status.
    private enum JobStop: Error {
        case cancelled
        case failed(SingJobFailure)
        /// Only this part went wrong (a line bad after its retry, a facade refusal): a parts job carries on with
        /// the next part; a single-part job fails exactly as with `failed`.
        case partFailed(SingJobFailure)
    }

    /// One part's take after assembly: what the landing needs, whether or not its gates passed.
    private struct FinishedPart: Sendable {
        let part: Int
        let url: URL
        let gates: SingGateReport
        let report: BounceLoudnessReport?
        let frames: [ClipPitchFrame]
        let analysisDetail: String?
        let pitchEdits: PitchEditSet?
        /// The style the take was sung with (nil when there was none, or the style pass could not run).
        let style: SingStyle?
    }

    private let store: ProjectStore
    private let engine: any SingJobEngine
    private let synthesizer: any SingingSynthesizing
    private let lifecycle: ModelLifecycleCoordinator
    private let cache: SingPhraseCache
    private let detectPitch: @Sendable (URL) async throws -> [ClipPitchFrame]
    private let transcribe: @Sendable (URL) async throws -> String?
    public let configuration: Configuration

    private var jobs: [String: Job] = [:]
    /// Submission order, oldest first, for `statuses` and the history trim.
    private var order: [String] = []
    private var queue: [String] = []
    private var running: String?
    private var pumping = false
    /// Own voices the running engine has already loaded ("<pid>|<voice id>"): the first unit of one that is
    /// not here reads `preparingVoice`.
    private var preparedVoices: Set<String> = []
    private var realTimeFactor: Double
    /// Checks that are still running after their job landed (tests wait on these).
    private var pendingChecks: Set<String> = []
    /// When this coordinator was made, by the WALL clock (never `configuration.now`, which a test fixes): the
    /// startup sweep's cutoff.
    private let createdAt = Date()

    /// - Parameters:
    ///   - store: the app's ONE `ProjectStore` (plans and lands through it, on the main actor).
    ///   - engine: the singing sidecar (`SingingSidecarManager`).
    ///   - synthesizer: `SingingSynthesisClient` against the same base URL.
    ///   - lifecycle: the app's ONE `ModelLifecycleCoordinator` (never `.shared` in a test).
    ///   - cache: the phrase cache, in a folder that is one of the facade's allowed roots
    ///     (`SingingSidecarManager.Configuration.cacheDir`).
    ///   - detectPitch: SwiftF0 frames over a file (`AudioEngineControlling.detectPitch(inFileAt:…)` with
    ///     `confidenceThreshold` 0.9, the whole file).
    ///   - transcribe: what the router's ONE `WhisperTranscriber` hears in a file (language "en"); nil when no
    ///     speech model is installed.
    public init(store: ProjectStore, engine: any SingJobEngine, synthesizer: any SingingSynthesizing,
                lifecycle: ModelLifecycleCoordinator, cache: SingPhraseCache,
                detectPitch: @escaping @Sendable (URL) async throws -> [ClipPitchFrame],
                transcribe: @escaping @Sendable (URL) async throws -> String?,
                configuration: Configuration = Configuration()) {
        self.store = store
        self.engine = engine
        self.synthesizer = synthesizer
        self.lifecycle = lifecycle
        self.cache = cache
        self.detectPitch = detectPitch
        self.transcribe = transcribe
        self.configuration = configuration
        self.realTimeFactor = configuration.warmRealTimeFactor
        // The startup sweep (W8-RV6 N3). It reads the open project's clips on the main actor, so it cannot run
        // inside `init`; it starts at once and never touches a file a job of this coordinator wrote.
        Task { await self.sweepOrphanTakes() }
    }

    // MARK: - Orphan takes (W8-RV6 N3)

    /// The folder every job writes its takes (and pre-air sums) into.
    private var takesFolder: URL { cache.directory.appendingPathComponent("takes", isDirectory: true) }

    /// Deletes the takes a run that never finished left in `takes/` (the app quit or crashed mid-job: a take
    /// or a `-preair.wav` sum is then never removed, and `takes/` is outside the phrase cache's cap and
    /// eviction, `SingPhraseCache.evict`, which lists only the top folder). Like `evict`, it lists ONE folder
    /// level and reads each file's size-free facts (`modificationDate`); a file it cannot read is kept.
    ///
    /// A `.wav` file is deleted only when ALL of these hold:
    /// - it was last modified `Configuration.orphanTakeMinimumAgeSeconds` or more before this coordinator was
    ///   made (so no job of this coordinator wrote it, and no job of another running copy is still using it);
    /// - no job record of this coordinator names it (its name does not start with a job id in `jobs`);
    /// - no clip of the open project plays it (`Clip.audioFileURL`, symlinks resolved). Landing copies a take
    ///   into the Generations folder, so a clip never points into `takes/`; this guard makes sure of it.
    ///
    /// Runs once when the coordinator is made. Returns the files it deleted.
    @discardableResult
    public func sweepOrphanTakes() async -> [URL] {
        let fm = FileManager.default
        let folder = takesFolder
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        let cutoff = createdAt.addingTimeInterval(-max(0, configuration.orphanTakeMinimumAgeSeconds))
        let store = self.store
        // The main actor only copies the clips' file URLs; resolving them (file-system calls) happens here.
        let clipFiles: [URL] = await MainActor.run { store.tracks.flatMap(\.clips).compactMap(\.audioFileURL) }
        let played = Set(clipFiles.map { $0.resolvingSymlinksInPath().path })
        let recorded = Set(jobs.keys)
        var deleted: [URL] = []
        for name in names {
            let url = folder.appendingPathComponent(name)
            guard url.pathExtension == "wav" else { continue }
            guard !recorded.contains(where: { name.hasPrefix($0) }) else { continue }
            guard !played.contains(url.resolvingSymlinksInPath().path) else { continue }
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            if (try? fm.removeItem(at: url)) != nil { deleted.append(url) }
        }
        return deleted
    }

    // MARK: - Submit

    /// Plans the clip and queues the job. Returns at once with the job's first status.
    ///
    /// - Throws: `SingJobError` — the clip is unknown; the planner refuses (in words: no lyrics, too many
    ///   words, not English, a drum track, an audio clip, an octave shift that is not whole octaves in
    ///   −2...2, a note longer than 20 s, …); the engine is not installed or needs an update; the queue is full.
    public func submit(_ request: SingJobRequest) async throws -> SingJobStatus {
        let parts = try await planParts(request)
        let planned = Self.preview(parts, request: request)
        let engineStatus = await engine.status()
        switch engineStatus.state {
        case .notInstalled: throw SingJobError.engineNotInstalled(engineStatus.message)
        case .needsUpdate: throw SingJobError.engineNeedsUpdate(engineStatus.message)
        default: break
        }
        // No `await` from here to the end: the actor's one-message-at-a-time processing is the queue's guard.
        let inSystem = queue.count + (running == nil ? 0 : 1)
        guard inSystem <= configuration.queueCapacity else {
            throw SingJobError.queueFull(capacity: configuration.queueCapacity)
        }
        let plan = parts[0].planning.plan
        let id = "sing-" + UUID().uuidString.lowercased()
        let weights = parts.flatMap { part in
            part.planning.plan.units.map { $0.spanSeconds + SingPlanner.leadSeconds + SingPlanner.trailSeconds }
        }
        var status = SingJobStatus(
            jobID: id, clipID: request.clipID, phase: .queued, stageText: Copy.queued, unitIndex: nil,
            unitCount: plan.units.count, progress: 0, etaSeconds: nil, waitingFor: nil, cancelRequested: false,
            seed: request.seed ?? SingJobRequestBuilder.firstTakeSeed, retriedUnits: [], cachedUnits: 0,
            renderedUnits: 0, yields: 0, engineRestarts: 0, warnings: planned.warnings, notices: [],
            result: nil, gates: nil, error: nil, keptTakePath: nil, fromAgent: request.fromAgent,
            submittedAt: configuration.now(), finishedAt: nil)
        if let partStatuses = planned.parts { status.parts = partStatuses }
        jobs[id] = Job(status: status, request: request, parts: parts, weights: weights)
        order.append(id)
        queue.append(id)
        trimHistory()
        startPumpIfNeeded()
        return jobs[id]!.status
    }

    /// What `submit` plans before it checks the engine or queues anything (W8-X6F, for the wire's dry run).
    public struct PlanPreview: Sendable, Equatable {
        /// The lead's plan.
        public var plan: SingPlan
        /// One per line, the lead first, exactly as `submit`'s first status carries them; nil for a job without
        /// parts (as `SingJobStatus.parts`).
        public var parts: [SingJobPartStatus]?
        /// `submit`'s first status's warnings: the lead plan's, then each part's out-of-range sentence.
        public var warnings: [String]
    }

    /// Plans `request` WITHOUT submitting it: the SAME `planParts` and `preview` that `submit` runs, so it returns
    /// what `submit`'s first status would carry, or throws the same planning refusal (an unknown clip, the
    /// planner's, a part's). It does not ask the engine, never queues, and changes nothing.
    public func plan(_ request: SingJobRequest) async throws -> PlanPreview {
        try await plan(request, lyrics: nil)
    }

    /// `plan(_:)` over words that are not stored yet (p2-sing-x7d): the lead and every part are planned from a copy
    /// of the clip holding `lyrics`, through the same planner calls. `nil` keeps the stored words; `.some(nil)`
    /// plans as if they were cleared. Nothing in the project changes.
    public func plan(_ request: SingJobRequest, lyrics: ClipLyrics??) async throws -> PlanPreview {
        Self.preview(try await planParts(request, lyrics: lyrics), request: request)
    }

    /// `submit`'s planning step (and `plan`'s): the lead and every part on the main actor, with the refusals put
    /// into `SingJobError` words.
    private func planParts(_ request: SingJobRequest, lyrics: ClipLyrics?? = nil) async throws -> [Part] {
        let store = self.store
        do {
            return try await MainActor.run { try Self.planSnapshot(store: store, request: request, lyrics: lyrics) }
        } catch let refusal as SingPlanRefusal {
            throw SingJobError.planRefused(refusal)
        } catch ProjectError.clipNotFound(let id) {
            throw SingJobError.clipNotFound(id)
        }
    }

    /// The parts' first statuses and the job's first warnings, from its planned parts.
    private static func preview(_ parts: [Part], request: SingJobRequest) -> PlanPreview {
        var warnings = parts[0].planning.plan.warnings.map(\.sentence)
        var statuses: [SingJobPartStatus]?
        if !request.parts.isEmpty {
            statuses = parts.map(partStatus)
            for part in parts.dropFirst() where !part.fits {
                if let range = part.range { warnings.append(Copy.partRange(part.name, range)) }
            }
        }
        return PlanPreview(plan: parts[0].planning.plan, parts: statuses, warnings: warnings)
    }

    /// The lead, then every requested part, planned against ONE consistent read of the project.
    @MainActor
    private static func planSnapshot(store: ProjectStore, request: SingJobRequest, lyrics: ClipLyrics?? = nil) throws -> [Part] {
        let planning = try store.planSungVocal(clipId: request.clipID, octaveShift: request.octaveShift, lyrics: lyrics)
        var clip = store.tracks.lazy.flatMap(\.clips).first { $0.id == request.clipID }
        // The override covers the lead's `lyricsText` and the clip every part is planned from.
        if let lyrics { clip?.lyrics = lyrics }
        let leadSeed = request.seed ?? SingJobRequestBuilder.firstTakeSeed
        let lead = Part(
            role: SungVocalProvenance.PartRole.lead, name: Copy.leadPartName, planning: planning,
            voice: request.voice, seed: leadSeed,
            trackName: request.trackName ?? ProjectStore.sungVocalTrackName(voiceName: request.voice.name),
            pan: nil, volume: nil, lyricsText: clip?.lyrics?.text ?? "", noteBars: noteBars(planning.plan, store),
            style: SingStyle.resolved(clip?.singStyle), velocities: velocities(of: clip?.notes ?? []),
            harmony: nil, ownSource: nil, derived: nil, range: nil, fits: true,
            warnings: planning.plan.warnings.map(\.sentence), firstUnit: 0)
        guard !request.parts.isEmpty else { return [lead] }
        guard request.parts.count <= SingJobPart.maximumCount else {
            throw SingJobError.tooManyParts(maximum: SingJobPart.maximumCount)
        }
        guard let clip, let track = store.tracks.first(where: { $0.clips.contains { $0.id == clip.id } }) else {
            throw ProjectError.clipNotFound(request.clipID)
        }
        var parts = [lead]
        var onSide: [Int: Int] = [:]
        for (k, part) in request.parts.enumerated() {
            parts.append(try planPart(part, index: k + 1, lead: lead, clip: clip, track: track, request: request,
                                      store: store, onSide: &onSide,
                                      firstUnit: parts.reduce(0) { $0 + $1.planning.plan.units.count }))
        }
        return parts
    }

    /// One requested part (design §4.2-§4.6, §8.4). Every default is [A] (`SingJobPart`'s).
    @MainActor
    private static func planPart(_ part: SingJobPart, index: Int, lead: Part, clip: Clip, track: Track,
                                 request: SingJobRequest, store: ProjectStore, onSide: inout [Int: Int],
                                 firstUnit: Int) throws -> Part {
        if let pan = part.pan, !(pan.isFinite && Track.panRange.contains(pan)) {
            throw SingJobError.partInvalid(field: "pan", message: "A part's pan must be between −1 (left) and 1 (right).")
        }
        if let db = part.volumeDb, !(db.isFinite && SingJobPart.volumeDbRange.contains(db)) {
            throw SingJobError.partInvalid(field: "volumeDb", message: "A part's level must be between −60 and +6 dB.")
        }
        if let octave = part.octaveShift, !VoiceRangeFit.octaveShiftRange.contains(octave) {
            throw SingJobError.partInvalid(field: "octaveShift",
                                           message: "A part moves by whole octaves, from −2 to 2.")
        }
        let tempo = store.transport.tempoMap, meter = store.transport.meterMap
        let voice = part.voice ?? request.voice
        let generation = store.projectGeneration
        func planning(_ plan: SingPlan) -> SungVocalPlanning {
            SungVocalPlanning(plan: plan, landingGuard: SungVocalLandingGuard(
                projectGeneration: generation, signature: plan.signature, plan: plan))
        }
        func sung(_ transient: Clip, on track: Track, octave: Int, name: String) throws -> SingPlan {
            do throws(SingPlanRefusal) {
                return try SingPlanner.plan(clip: transient, on: track, tempoMap: tempo, meterMap: meter,
                                            octaveShift: octave)
            } catch { throw SingJobError.partRefused(part: name, error) }
        }
        /// The side defaults (§4.6): the first part on a side ±0.3 at −4 dB, the next ones ±0.5 at −6 dB, " · n".
        func sided(_ side: Int, name: String) -> (trackName: String, pan: Double, volume: Double) {
            let rank = (onSide[side] ?? 0) + 1
            onSide[side] = rank
            let first = rank == 1
            return (part.trackName ?? SingJobPart.trackName(partName: name, voiceName: voice.name, isDouble: false,
                                                            sideRank: rank),
                    part.pan ?? Double(side) * (first ? SingJobPart.firstOnASidePan : SingJobPart.moreOnASidePan),
                    SingJobPart.volume(db: part.volumeDb ?? (first ? SingJobPart.firstOnASideDb
                                                                   : SingJobPart.moreOnASideDb)))
        }
        func fromHarmony(_ harmony: HarmonyPlan, name: String, side: Int, record: SungVocalHarmony,
                         rule: SungVocalDerivedPart.Rule) throws -> Part {
            let range = HarmonyPlanner.range(of: harmony, clipStartBeat: clip.startBeat, tempoMap: tempo,
                                             voice: voice.range, leadOctaveShift: request.octaveShift)
            let octave = part.octaveShift ?? range.octaveShift
            let transient = harmony.transientClip(replacingNotesOf: clip)
            let plan = try sung(transient, on: track, octave: octave, name: name)
            let mix = sided(side, name: name)
            let fitted = part.octaveShift == nil
            return Part(role: SungVocalProvenance.PartRole.harmony, name: name, planning: planning(plan),
                        voice: voice, seed: part.seed ?? (lead.seed &+ SingJobPart.harmonySeedOffset),
                        trackName: mix.trackName, pan: mix.pan,
                        volume: mix.volume, lyricsText: lead.lyricsText, noteBars: noteBars(plan, store),
                        style: SingStyle.resolved(transient.singStyle), velocities: velocities(of: transient.notes ?? []),
                        harmony: record, ownSource: nil,
                        derived: SungVocalDerivedPart(rule: rule, givenKey: request.key, partIndex: index, name: name,
                                                      plannedNotes: harmony.partNotes),
                        range: fitted ? range.sentence : nil, fits: fitted ? range.fits : true,
                        warnings: plan.warnings.map(\.sentence), firstUnit: firstUnit)
        }
        /// THE ONE derivation (`SungVocalDerivedPart.derive`), which landing runs again (design §16).
        func derive(_ rule: SungVocalDerivedPart.Rule) throws -> HarmonyPlan {
            do throws(HarmonyRefusal) {
                return try SungVocalDerivedPart.derive(rule, givenKey: request.key, partIndex: index, clip: clip,
                                                       on: track, tracks: store.tracks, tempoMap: tempo)
            } catch { throw SingJobError.harmony(error) }
        }

        switch part.kind {
        case .harmony(let spec):
            let rule = SungVocalDerivedPart.Rule.harmony(spec)
            let harmony = try derive(rule)
            return try fromHarmony(harmony, name: spec.name, side: spec.direction == .above ? 1 : -1,
                                   record: SungVocalHarmony(spec: spec, key: harmony.key), rule: rule)
        case .chordTones(let rank, let fillInterval, let fillChordSource):
            let rule = SungVocalDerivedPart.Rule.chordTones(rank: rank, fillInterval: fillInterval,
                                                            fillChordSource: fillChordSource)
            let harmony = try derive(rule)
            let fill = HarmonySpec(interval: fillInterval, direction: .below, chordSource: fillChordSource)
            return try fromHarmony(harmony, name: Copy.chordNotesPartName, side: -1,
                                   record: SungVocalHarmony(spec: fill, key: harmony.key, chordToneRank: rank),
                                   rule: rule)
        case .clip(let otherID):
            guard otherID != request.clipID else {
                throw SingJobError.partInvalid(field: "sourceClipId", message: "That clip is the melody itself. "
                    + "Pick another melody clip, or double the vocal instead.")
            }
            guard let otherTrack = store.tracks.first(where: { $0.clips.contains { $0.id == otherID } }),
                  let other = otherTrack.clips.first(where: { $0.id == otherID }) else {
                throw SingJobError.partClipNotFound(otherID)
            }
            let range = HarmonyPlanner.range(ofClipNotes: SingPlanner.melody(of: other).notes,
                                             clipStartBeat: other.startBeat, tempoMap: tempo, voice: voice.range,
                                             leadOctaveShift: request.octaveShift)
            let octave = part.octaveShift ?? range.octaveShift
            let borrowed = other.lyrics == nil ? clip.lyrics : nil
            let plan: SingPlan
            do throws(SingPlanRefusal) {
                plan = try SungVocalPartSource.plan(clip: other, on: otherTrack, borrowedLyrics: borrowed,
                                                    octaveShift: octave, tempoMap: tempo, meterMap: meter)
            } catch { throw SingJobError.partRefused(part: other.name, error) }
            // Its side [A]: below the lead when it sits lower on average, else above.
            func mean(_ plan: SingPlan) -> Double {
                let notes = plan.notes
                return notes.isEmpty ? 0 : Double(notes.map(\.midi).reduce(0, +)) / Double(notes.count)
            }
            let mix = sided(mean(plan) <= mean(lead.planning.plan) ? -1 : 1, name: other.name)
            let fitted = part.octaveShift == nil
            return Part(role: SungVocalProvenance.PartRole.harmony, name: other.name, planning: planning(plan),
                        voice: voice, seed: part.seed ?? (lead.seed &+ SingJobPart.harmonySeedOffset),
                        trackName: mix.trackName, pan: mix.pan,
                        volume: mix.volume, lyricsText: other.lyrics?.text ?? lead.lyricsText,
                        noteBars: noteBars(plan, store), style: SingStyle.resolved(other.singStyle),
                        velocities: velocities(of: other.notes ?? []), harmony: nil,
                        ownSource: SungVocalPartSource(plan: plan, borrowedLyrics: borrowed), derived: nil,
                        range: fitted ? range.sentence : nil, fits: fitted ? range.fits : true,
                        warnings: plan.warnings.map(\.sentence), firstUnit: firstUnit)
        case .double:
            let seed = part.seed ?? (lead.seed &+ SingJobPart.doubleSeedOffset)
            guard seed != lead.seed else {
                throw SingJobError.partInvalid(field: "seed", message: "A double needs a different seed from the "
                    + "lead's; on the same seed it sings an exact copy.")
            }
            if let octave = part.octaveShift, octave != request.octaveShift {
                throw SingJobError.partInvalid(field: "octaveShift", message: "A double sings at the lead's octave.")
            }
            return Part(role: SungVocalProvenance.PartRole.double, name: Copy.doublePartName,
                        planning: lead.planning, voice: voice, seed: seed,
                        trackName: part.trackName ?? SingJobPart.trackName(partName: Copy.doublePartName,
                                                                           voiceName: voice.name, isDouble: true,
                                                                           sideRank: 1),
                        pan: part.pan ?? SingJobPart.doublePan,
                        volume: SingJobPart.volume(db: part.volumeDb ?? SingJobPart.doubleDb),
                        lyricsText: lead.lyricsText, noteBars: lead.noteBars, style: lead.style,
                        velocities: lead.velocities, harmony: nil, ownSource: nil, derived: nil, range: nil,
                        fits: true, warnings: [], firstUnit: firstUnit)
        }
    }

    /// Planned note i's 1-based bar (the amber notes notice).
    @MainActor
    private static func noteBars(_ plan: SingPlan, _ store: ProjectStore) -> [Int] {
        let tempo = store.transport.tempoMap
        let meter = store.transport.meterMap
        return plan.units.flatMap { unit in
            unit.notes.map { note in
                meter.barBeat(atBeat: tempo.beat(atSecondsFromZero: unit.onsetSeconds + note.startSeconds)).bar + 1
            }
        }
    }

    /// Each note's velocity by id. `uniquingKeysWith` (first wins): `uniqueKeysWithValues` traps on a duplicate
    /// id, and a damaged clip may hold one (W8-X5D's correction).
    static func velocities(of notes: [MIDINote]) -> [UUID: Int] {
        Dictionary(notes.map { ($0.id, $0.velocity) }, uniquingKeysWith: { first, _ in first })
    }

    private static func partStatus(_ part: Part) -> SingJobPartStatus {
        SingJobPartStatus(role: part.role, name: part.name, state: .waiting,
                          unitCount: part.planning.plan.units.count, octaveShift: part.planning.plan.octaveShift,
                          seed: part.seed, voiceId: part.voice.id, range: part.range, fits: part.fits,
                          warnings: part.warnings, trackID: nil, clipID: nil, trackName: part.trackName, gates: nil,
                          error: nil)
    }

    // MARK: - Read and cancel

    public func status(jobID: String) throws -> SingJobStatus {
        guard let job = jobs[jobID] else { throw SingJobError.jobNotFound(jobID) }
        return job.status
    }

    /// The most recent jobs, newest first (design §6 row 15: `sing.jobStatus` with no id lists the last 20).
    public func statuses(limit: Int = 20) -> [SingJobStatus] {
        order.reversed().prefix(max(0, limit)).compactMap { jobs[$0]?.status }
    }

    /// Asks a job to stop. See the type doc: a started job stops at its next unit boundary; a queued one
    /// leaves the queue and reads `cancelled` at once.
    ///
    /// - Throws: `jobNotFound`, or `jobFinished` once it is terminal, has landed, or has started landing (design
    ///   §16: a cancel that arrives while the take is going into the song is refused, never ignored).
    @discardableResult
    public func cancel(jobID: String) throws -> SingJobStatus {
        guard var job = jobs[jobID] else { throw SingJobError.jobNotFound(jobID) }
        guard !job.status.phase.isTerminal, !job.status.phase.hasLanded, !job.landingStarted else {
            throw SingJobError.jobFinished(jobID)
        }
        if let index = queue.firstIndex(of: jobID) {
            queue.remove(at: index)
            jobs[jobID] = job
            finish(jobID, .cancelled)
            return jobs[jobID]!.status
        }
        job.status.cancelRequested = true
        if job.status.phase == .singing || job.status.phase == .preparingVoice {
            job.status.stageText = Copy.stopping
        }
        jobs[jobID] = job
        return job.status
    }

    /// True while a job is rendering or waiting, or a landed job's checks are still running.
    public func isBusy() -> Bool {
        running != nil || !queue.isEmpty || !pendingChecks.isEmpty
    }

    // MARK: - The pump: one job at a time

    private func startPumpIfNeeded() {
        guard !pumping else { return }
        pumping = true
        Task { await self.pump() }
    }

    private func pump() async {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            running = id
            await run(id)
            running = nil
        }
        pumping = false
    }

    private func trimHistory() {
        while order.count > configuration.historyLimit,
              let oldest = order.first(where: { jobs[$0]?.status.phase.isTerminal ?? true }) {
            order.removeAll { $0 == oldest }
            jobs[oldest] = nil
        }
    }

    // MARK: - One job

    private func run(_ id: String) async {
        guard let job = jobs[id] else { return }
        var rendered: [Int: [[Float]]] = [:]
        var engineRetryUsed = false
        // Every step throws only `JobStop`: each failure was already put into words where it happened.
        do throws(JobStop) {
            _ = try await ensureEngine(id)
            await noteSongGeneratorOutside(id)
            // Part by part, in order (design §4.4); a job without parts has exactly one, the lead.
            for p in job.parts.indices {
                var units: [[Float]] = []
                setPartState(id, p, .singing)
                do throws(JobStop) {
                    for index in job.parts[p].planning.plan.units.indices {
                        try checkCancelled(id)
                        units.append(try await renderUnit(id, part: p, index: index,
                                                          engineRetryUsed: &engineRetryUsed))
                    }
                } catch {
                    // A parts job carries on past a part that went wrong; anything else ends the job.
                    guard job.hasParts, case .partFailed(let failure) = error else { throw error }
                    partFailed(id, p, failure)
                    continue
                }
                rendered[p] = units
                setPartState(id, p, .sung)
            }
            try checkCancelled(id)
            // `inout`: each part's units are freed once its take is assembled (W8-RV6 N1).
            try await assembleAndLand(id, rendered: &rendered)
        } catch {
            switch error {
            case .cancelled: finish(id, .cancelled)
            case .failed(let failure), .partFailed(let failure): finish(id, .failed, failure: failure)
            }
        }
    }

    private func checkCancelled(_ id: String) throws(JobStop) {
        if jobs[id]?.status.cancelRequested == true { throw JobStop.cancelled }
    }

    // MARK: Engine (design §2.6, §2.7 R2)

    /// Returns the healthy engine's status, starting it if it is not running (after R2's wait).
    private func ensureEngine(_ id: String) async throws(JobStop) -> SingingSidecarStatus {
        while true {
            try checkCancelled(id)
            let status = await engine.status()
            switch status.state {
            case .healthy:
                return status
            case .notInstalled:
                throw JobStop.failed(SingJobFailure(code: "singEngineNotInstalled", message: status.message))
            case .needsUpdate:
                throw JobStop.failed(SingJobFailure(code: "singEngineNeedsUpdate", message: status.message))
            case .error:
                throw JobStop.failed(SingJobFailure(code: "singStartFailed", message: Copy.engineWontStart(status.message)))
            case .starting:
                setPhase(id, .startingEngine, Copy.starting)
                await configuration.sleepSeconds(configuration.enginePollSeconds)
            case .installedNotRunning:
                // L6: a record that still says "resident" for an engine that is not running (a crash, a
                // watchdog kill) would make the next boot run with no flight ticket.
                if await lifecycle.residency().models.contains(where: { $0.modelID == .soulxSinger && $0.resident }) {
                    await lifecycle.noteStoppedExternally(.soulxSinger)
                }
                try await waitForOtherModels(id)
                setPhase(id, .startingEngine, Copy.starting)
                let started: SingingSidecarStatus
                do {
                    started = try await engine.start()
                } catch SidecarError.admissionRefused(let message) {
                    // Another model is booting (single flight): wait, then try again.
                    setPhase(id, .waitingForModel, Copy.waiting(for: "another model"), waitingFor: message)
                    await configuration.sleepSeconds(configuration.modelPollSeconds)
                    continue
                } catch {
                    throw JobStop.failed(SingJobFailure(code: "singStartFailed",
                                                 message: Copy.engineWontStart(error.localizedDescription)))
                }
                switch started.state {
                case .healthy:
                    preparedVoices.removeAll()
                    return started
                case .starting:
                    throw JobStop.failed(SingJobFailure(
                        code: "singStartFailed",
                        message: Copy.engineWontStart("it did not become ready in time."), detail: started.message))
                default:
                    throw JobStop.failed(SingJobFailure(code: "singStartFailed",
                                                 message: Copy.engineWontStart(started.message)))
                }
            }
        }
    }

    /// R2: waits, polling every `modelPollSeconds`, while another model is busy.
    private func waitForOtherModels(_ id: String, afterYield: Bool = false) async throws(JobStop) {
        while true {
            try checkCancelled(id)
            guard let (model, name) = await busyOtherModel() else { return }
            let text = afterYield ? Copy.yielded
                : model == .aceStep ? Copy.waitingForSongGenerator : Copy.waiting(for: name)
            setPhase(id, .waitingForModel, text, waitingFor: name)
            await configuration.sleepSeconds(configuration.modelPollSeconds)
        }
    }

    private func busyOtherModel() async -> (ModelID, String)? {
        let report = await lifecycle.residency()
        if let flight = report.inFlight, flight.modelID != .soulxSinger {
            return (flight.modelID, flight.displayName)
        }
        let now = configuration.now()
        for model in report.models where model.modelID != .soulxSinger {
            if model.activeJobs > 0 { return (model.modelID, model.displayName) }
            if model.resident, model.idleForSeconds == nil, let admitted = model.admittedAt,
               now.timeIntervalSince(admitted) < configuration.freshBootGraceSeconds {
                return (model.modelID, model.displayName)
            }
        }
        return nil
    }

    /// R4: a song generator DAW Pro did not start is never signalled; the job goes on, with a notice.
    private func noteSongGeneratorOutside(_ id: String) async {
        let outside: Bool
        if let check = configuration.songGeneratorRunsOutside {
            outside = await check()
        } else {
            let report = await lifecycle.residency(includeProcessDetail: true)
            outside = report.models.contains { $0.modelID == .aceStep && $0.portBusy == true && !$0.resident }
        }
        if outside { addNotice(id, Copy.songGeneratorOutside) }
    }

    // MARK: Units (design §4.3, §4.4, §4.7)

    private func renderUnit(_ id: String, part p: Int, index: Int,
                            engineRetryUsed: inout Bool) async throws(JobStop) -> [Float] {
        guard let job = jobs[id] else { throw JobStop.cancelled }
        let part = job.parts[p]
        let unit = part.planning.plan.units[index]
        let takeSeed = part.seed
        // Lines are numbered across the whole job (one part: exactly today's numbers).
        let line = part.firstUnit + index + 1
        let rate = configuration.outputSampleRate
        var seed = takeSeed
        var retried = false
        while true {
            try checkCancelled(id)
            let health = try await ensureEngine(id)
            let identity = SingEngineIdentity(status: health)
            mutate(id) { $0.identity = identity }
            var request = SingJobRequestBuilder.phraseRequest(
                unit: unit, voice: part.voice.reference, seed: seed, outputPath: "",
                outputSampleRate: rate, options: job.request.options)
            let key: String
            do {
                key = try SingJobRequestBuilder.cacheKey(for: request, engine: identity)
                try cache.prepare()
            } catch {
                throw JobStop.failed(SingJobFailure(code: "singCacheFailed", message: Copy.crash,
                                             detail: error.localizedDescription))
            }
            request.outputPath = cache.wavURL(key).path
            if let hit = cache.lookup(key, sampleRate: rate) {
                unitDone(id, unit: part.firstUnit + index, cached: true)
                return hit.samples
            }

            let voiceKey = "\(health.pid ?? 0)|\(part.voice.id)"
            let preparing: Bool
            if case .own = part.voice { preparing = !preparedVoices.contains(voiceKey) } else { preparing = false }
            setSinging(id, part: p, index: index, preparing: preparing)

            let before = await engine.lastStopClassification()
            // R5; a parts job names the part too (design §4.4): "<jobId>#<part>.<unit>".
            let lifecycleJob = job.hasParts ? "\(id)#\(p).\(index)" : "\(id)#\(index)"
            await lifecycle.noteJobStarted(.soulxSinger, jobID: lifecycleJob)
            let started = configuration.now()
            let outcome: Result<SingingRenderResult, Error>
            do {
                outcome = .success(try await synthesizer.renderPhrase(request))
            } catch {
                outcome = .failure(error)
            }
            await lifecycle.noteJobEnded(.soulxSinger, jobID: lifecycleJob)

            switch outcome {
            case .success(let result):
                let samples: [Float]
                var check: SingUnitCheck
                if let wav = try? SingWAV.read(URL(fileURLWithPath: request.outputPath)),
                   wav.sampleRate == rate, wav.frameCount == result.frames {
                    samples = wav.mono
                    check = SingUnitCheck.check(samples)
                } else {
                    samples = []
                    check = .unreadable
                }
                if result.nonFinite, check == .ok { check = .nonFinite }
                guard check == .ok else {
                    cache.remove(key)
                    guard !retried else {
                        throw JobStop.partFailed(SingJobFailure(code: "singBadUnit", message: Copy.badUnit(line: line),
                                                     detail: "line \(line): \(check) after its retry at seed \(seed)"))
                    }
                    retried = true
                    seed = SingJobRequestBuilder.retrySeed(after: takeSeed)
                    markRetried(id, line: line)
                    continue
                }
                try? cache.store(SingPhraseCache.Entry(key: key, frames: samples.count, sampleRate: rate, seed: seed,
                                                       inferSeconds: result.inferSeconds, rtf: result.rtf))
                cache.evict(protecting: [key])
                if case .own = part.voice { preparedVoices.insert(voiceKey) }
                let elapsed = configuration.now().timeIntervalSince(started)
                learnRealTimeFactor(result.rtf ?? (result.durationS > 0 ? elapsed / result.durationS : nil))
                unitDone(id, unit: part.firstUnit + index, cached: false)
                return samples

            case .failure(let error):
                switch error {
                case SingingFacadeError.nonFinite(let message):
                    guard !retried else {
                        throw JobStop.partFailed(SingJobFailure(code: "singBadUnit", message: Copy.badUnit(line: line),
                                                     detail: message))
                    }
                    retried = true
                    seed = SingJobRequestBuilder.retrySeed(after: takeSeed)
                    markRetried(id, line: line)
                case SingingFacadeError.loading:
                    // Still loading the model: `ensureEngine` waits for it on the next pass.
                    await configuration.sleepSeconds(configuration.enginePollSeconds)
                case SingingFacadeError.transport:
                    try await engineTrouble(id, error: error, before: before, engineRetryUsed: &engineRetryUsed)
                case let refusal as SingingFacadeError:
                    throw JobStop.partFailed(SingJobFailure(code: "singFacadeRefused",
                                                 message: refusal.errorDescription ?? "\(refusal)"))
                default:
                    try await engineTrouble(id, error: error, before: before, engineRetryUsed: &engineRetryUsed)
                }
            }
        }
    }

    /// A render that never got an answer. Why the engine went away decides what happens (design §4.7):
    /// a yield waits and renders the unit again; the watchdog fails in its own words; an explicit stop ends
    /// the job; anything unexplained (a crash, or a lost connection to an engine still up) is retried ONCE,
    /// after restarting the engine if it is down, and fails the second time.
    private func engineTrouble(_ id: String, error: Error, before: SingingStopReason?,
                               engineRetryUsed: inout Bool) async throws(JobStop) {
        let after = await engine.lastStopClassification()
        // `start()` clears the classification on a real boot, so a value equal to the one read before this
        // unit is stale: it explains an earlier stop, not this one.
        let reason = after == before ? nil : after
        switch reason {
        case .evictedByCoordinator?:
            mutate(id) { $0.status.yields += 1 }
            try await waitForOtherModels(id, afterYield: true)
        case .watchdog(let trigger, let detail)?:
            await lifecycle.noteStoppedExternally(.soulxSinger)
            switch trigger {
            case .footprint:
                throw JobStop.failed(SingJobFailure(code: "singWatchdogFootprint", message: Copy.watchdogFootprint,
                                             detail: detail))
            case .pressure:
                throw JobStop.failed(SingJobFailure(code: "singWatchdogPressure", message: Copy.watchdogPressure,
                                             detail: detail))
            }
        case .explicit?:
            try checkCancelled(id)
            throw JobStop.failed(SingJobFailure(code: "singEngineStopped", message: Copy.engineStopped))
        case nil:
            guard !engineRetryUsed else {
                throw JobStop.failed(SingJobFailure(code: "singEngineCrashed", message: Copy.crash,
                                             detail: error.localizedDescription))
            }
            engineRetryUsed = true
            mutate(id) { $0.status.engineRestarts += 1 }
            if await engine.status().state != .healthy {
                await lifecycle.noteStoppedExternally(.soulxSinger)
            }
        }
    }

    // MARK: Finish: assemble, style and air, gain, gates, land (design §4.5, §7.1; x6: §4.4, §5.4)

    /// `rendered` is taken `inout` and each part's entry is REMOVED before its take is finished, so `finishPart`
    /// holds that part's units alone and frees them once they are summed (W8-RV6 N1).
    private func assembleAndLand(_ id: String, rendered: inout [Int: [[Float]]]) async throws(JobStop) {
        guard let job = jobs[id] else { throw JobStop.cancelled }
        setPhase(id, .finishing, Copy.finishing)
        guard job.hasParts else {
            // One part: today's finish, exactly (the style pass does nothing without a style).
            var units = rendered.removeValue(forKey: 0) ?? []
            let finished = try await finishPart(id, part: 0, units: &units)
            guard let firstFailed = finished.gates.failed.first else {
                try await land(id, finished)
                return
            }
            mutate(id) { $0.status.gates = finished.gates }
            throw JobStop.failed(SingJobFailure(code: "singGate\(firstFailed.rawValue)", message: firstFailed.sentence,
                                         detail: finished.analysisDetail ?? Self.gateDetail(finished.gates)))
        }
        // Every part runs L1-L4 on its own take (§4.4): the ones that pass land together; one that fails does not.
        var passed: [FinishedPart] = []
        for p in job.parts.indices {
            guard var units = rendered.removeValue(forKey: p) else { continue }   // it went wrong while being sung
            try checkCancelled(id)
            let finished = try await finishPart(id, part: p, units: &units)
            if let firstFailed = finished.gates.failed.first {
                mutate(id) { $0.status.parts?[p].gates = finished.gates }
                partFailed(id, p, SingJobFailure(code: "singGate\(firstFailed.rawValue)", message: firstFailed.sentence,
                                                 detail: finished.analysisDetail ?? Self.gateDetail(finished.gates)))
                continue
            }
            passed.append(finished)
        }
        guard !passed.isEmpty else {
            // Nothing passed: the job fails with its first part's failure (with one part, today's rule).
            let first = jobs[id]?.status.parts?.first { $0.error != nil }
            mutate(id) { $0.status.gates = first?.gates }
            throw JobStop.failed(first?.error ?? SingJobFailure(code: "singLandingFailed", message: Copy.crash))
        }
        try await landParts(id, passed)
    }

    /// One part's take, in design §5.4's fixed order (`SungExpressionPlanner`'s doc): (1) sum the units;
    /// (2) detect pitch on the sum BEFORE any air; (3) plan, then mix the air; (4) gain; (5) write, measure,
    /// detect and run L1-L4 on the written bytes. Steps 2-3 are skipped, detection included, when
    /// `SungExpressionPlanner.isNoOp(style:)` on the style pruned to the part's notes (`styleForNoOpCheck`).
    /// Throws only when the take cannot be written.
    ///
    /// Memory (W8-RV6 N1): ONE buffer, `signal`, carries the take from step to step, and each step's input is
    /// released as soon as its output replaces it: the units (`units`, emptied once summed: the caller removed
    /// them from the job's `rendered`), the pre-air sum, the pre-gain take, and the gained take once written.
    /// Only the normalising step holds two: its input stays referenced until it returns, because a `bounceSilent`
    /// take is still written and gated as it was (L2, L4 refuse it).
    private func finishPart(_ id: String, part p: Int, units: inout [[Float]]) async throws(JobStop) -> FinishedPart {
        guard let job = jobs[id] else { throw JobStop.cancelled }
        let part = job.parts[p]
        let plan = part.planning.plan
        let rate = configuration.outputSampleRate
        var signal: [Float]
        do {
            let placed = zip(plan.units, units).map {
                SingTakeAssembly.Placed(offsetSeconds: $0.offsetSeconds, samples: $1)
            }
            signal = SingTakeAssembly.assemble(placed, sampleRate: rate)
        }
        units = []
        let fileName = job.hasParts ? "\(id)-\(p)" : id
        let folder = cache.directory.appendingPathComponent("takes", isDirectory: true)

        var pitchEdits: PitchEditSet?
        var style = part.style
        if !SungExpressionPlanner.isNoOp(style: Self.styleForNoOpCheck(part.style, heldNoteIDs: part.velocities.keys)) {
            switch await expressionPass(take: signal, part: part, sampleRate: rate,
                                        preAirURL: folder.appendingPathComponent("\(fileName)-preair.wav")) {
            case .success(let pass):
                signal = pass.aired
                pitchEdits = pass.plan.table
            case .failure:
                // Land WITHOUT the style, and say so (never a half-styled take, never silently).
                style = nil
                addWarning(id, job.hasParts ? Copy.styleNotApplied(part: part.name) : Copy.styleNotApplied)
            }
        }

        var report: BounceLoudnessReport?
        do {
            let normalized = try await ProjectStore.normalizeSungVocalTake(
                RenderedAudio(sampleRate: Double(rate), channelData: [signal]))
            signal = normalized.audio.channelData.first ?? []
            report = normalized.report
        } catch {
            // `bounceSilent`: nothing to gain toward. The gates below refuse it (L2, L4).
            report = nil
        }

        let url = folder.appendingPathComponent("\(fileName).wav")
        let written: [Float]
        do {
            try SingWAV.writeFloat32Mono(signal, sampleRate: rate, to: url)
            signal = []
            written = try readTakeBack(url)            // L3 is measured on the WRITTEN bytes
        } catch {
            // A take written but never tracked would outlive the job (W8-RV6 N3): remove it on this path.
            try? FileManager.default.removeItem(at: url)
            throw JobStop.failed(SingJobFailure(code: "singTakeWriteFailed", message: SingLandingGate.physics.sentence,
                                         detail: error.localizedDescription))
        }
        mutate(id) { $0.takeURLs.append(url) }
        let measured = await Loudness.measureDetached(RenderedAudio(sampleRate: Double(rate), channelData: [written]))
        let frames: [ClipPitchFrame]
        var analysisDetail: String?
        do {
            frames = try await detectPitch(url)
        } catch {
            frames = []                                // a gate that cannot measure does not pass
            analysisDetail = "pitch detection failed: \(error.localizedDescription)"
        }
        let gates = SingLandingGates.evaluate(samples: written, sampleRate: rate, plan: plan, frames: frames,
                                              written: measured, report: report)
        return FinishedPart(part: p, url: url, gates: gates, report: report, frames: frames,
                            analysisDetail: analysisDetail, pitchEdits: pitchEdits, style: style)
    }

    /// The style `isNoOp` is asked about (W8-XL; W8-X6 MEASURED that a style whose per-note choices all point at
    /// deleted notes still ran the pre-air detection and landed no table): `style` with the per-note choices of
    /// notes the part's clip no longer holds dropped, by `SingStyle.keepingOverrides(for:)` (W8-X5M). Such a style
    /// then reads as "as sung" and skips the detection. `heldNoteIDs` is `Part.velocities`' keys: EVERY note of the
    /// part's clip by id (the lead's clip, a harmony's transient clip, another clip, or the lead's for a double).
    /// `keepingOverrides` reads only its notes' ids, so stand-in notes carrying those ids are enough. Used for that
    /// question ONLY: the expression pass and the provenance keep the part's style exactly as planned.
    static func styleForNoOpCheck(_ style: SingStyle?, heldNoteIDs: some Collection<UUID>) -> SingStyle? {
        style?.keepingOverrides(for: heldNoteIDs.map { MIDINote(id: $0, pitch: 60, startBeat: 0) })
    }

    /// A written take, read back: `Configuration.readTakeBack`, else `SingWAV.read(url).mono`.
    private func readTakeBack(_ url: URL) throws -> [Float] {
        if let read = configuration.readTakeBack { return try read(url) }
        return try SingWAV.read(url).mono
    }

    private struct ExpressionPass: Sendable {
        let plan: SungExpressionPlanner.Plan
        let aired: [Float]
    }

    private enum ExpressionPassFailure: Error, Sendable {
        case detection(String)
        case notesDoNotMatch
        case planner(String)
    }

    /// Design §5.4 steps 2-3 on the PRE-air sum: a second detection through the same `detectPitch` seam (a temp
    /// file, removed on every path), the pitch editor's own table (`PitchNoteTable.detected`), the planner with
    /// the notes' landed times (`SingTakeAssembly.noteWindows`, W8-X5D's correction), then the air on the take's
    /// own seed. The table build, planning and air run DETACHED on buffers this job owns (never cancelled), so
    /// status polls are not held up; nothing here touches the render thread.
    private func expressionPass(take: [Float], part: Part, sampleRate rate: Int,
                                preAirURL: URL) async -> Result<ExpressionPass, ExpressionPassFailure> {
        let frames: [ClipPitchFrame]
        do {
            defer { try? FileManager.default.removeItem(at: preAirURL) }
            try SingWAV.writeFloat32Mono(take, sampleRate: rate, to: preAirURL)
            frames = try await detectPitch(preAirURL)
        } catch {
            return .failure(.detection(error.localizedDescription))
        }
        let plan = part.planning.plan
        let style = part.style
        let velocities = part.velocities
        let seed = part.seed
        let duration = Double(take.count) / Double(max(1, rate))
        return await Task.detached { () -> Result<ExpressionPass, ExpressionPassFailure> in
            let detected = PitchNoteTable.detected(
                from: SingJobCoordinator.detectionResult(frames, sampleRate: rate, durationSeconds: duration))
            guard let notes = SungExpressionPlanner.notes(planned: plan.notes,
                                                          windows: SingTakeAssembly.noteWindows(plan),
                                                          velocities: velocities) else {
                return .failure(.notesDoNotMatch)
            }
            let expression: SungExpressionPlanner.Plan
            do {
                expression = try SungExpressionPlanner.plan(notes: notes, style: style, detected: detected,
                                                            clipID: plan.clipID)
            } catch {
                return .failure(.planner("\(error)"))
            }
            let aired = SungAirLayer.apply(expression.airSpans, to: take, sampleRate: Double(rate), seed: seed)
            return .success(ExpressionPass(plan: expression, aired: aired))
        }.value
    }

    /// SwiftF0's frame rate, Hz: the fallback when frames give no spacing to read.
    static let swiftF0FrameRateHz = 62.5

    /// The `detectPitch` seam's frames as the `PitchDetectionResult` `PitchNoteTable.detected(from:)` reads (W8-X5D's
    /// correction). The rate is the frames' OWN, from their median spacing (62.5 Hz for SwiftF0, also the
    /// fallback): `PitchNoteSplitter` derives every frame count from it, so a hardcoded rate would stretch another
    /// detector's segments. Fields the table never reads echo SwiftF0's defaults; the range is not known here (0).
    static func detectionResult(_ frames: [ClipPitchFrame], sampleRate: Int,
                                durationSeconds: Double) -> PitchDetectionResult {
        let gaps = zip(frames.dropFirst(), frames).map { $0.timeSeconds - $1.timeSeconds }
            .filter { $0.isFinite && $0 > 0 }.sorted()
        let rate = gaps.isEmpty ? swiftF0FrameRateHz : 1 / gaps[gaps.count / 2]
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: frames.isEmpty ? 0 : Double(voiced) / Double(frames.count), frameRateHz: rate,
            analysisSampleRateHz: 16_000, sourceSampleRateHz: Double(sampleRate), windowStartSeconds: 0,
            windowDurationSeconds: durationSeconds,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs, minFrequencyHz: 0, maxFrequencyHz: 0)
    }

    private static func gateDetail(_ gates: SingGateReport) -> String {
        let peak = gates.truePeakDbtp.map { String(format: "%.2f dBTP", $0) } ?? "none"
        let lufs = gates.integratedLufs.map { String(format: "%.2f LUFS", $0) } ?? "none"
        return "failed \(gates.failed.map(\.rawValue).joined(separator: ", ")): length "
            + String(format: "%.3f s of %.3f s planned", gates.lengthSeconds, gates.plannedSeconds)
            + ", finite \(gates.allFinite), voiced \(String(format: "%.2f", gates.voicedCoverage))"
            + ", true peak \(peak), integrated \(lufs)"
    }

    private func knownIdentity(_ job: Job) async -> SingEngineIdentity {
        if let known = job.identity { return known }
        return SingEngineIdentity(status: await engine.status())
    }

    private func provenance(_ job: Job, _ part: Part, identity: SingEngineIdentity, report: BounceLoudnessReport?,
                            notes: SungNoteAccuracy, style: SingStyle?) -> SungVocalProvenance {
        let plan = part.planning.plan
        return SungVocalProvenance(
            engineId: ModelID.soulxSinger.rawValue, engineCommit: identity.commit,
            weightsRevision: identity.weightsRevision, facadeVersion: identity.facadeVersion,
            voiceId: part.voice.id, voiceName: part.voice.name, voiceKind: part.voice.kind,
            lyricsText: part.lyricsText, sourceClipId: plan.clipID, octaveShift: plan.octaveShift,
            songTransposeSemitones: job.request.songTransposeSemitones,
            seed: Int(truncatingIfNeeded: part.seed), nSteps: job.request.options.nSteps,
            cfg: job.request.options.cfg, renderedAt: configuration.now(), loudness: report, noteAccuracy: notes,
            style: style, partRole: job.hasParts ? part.role : nil, harmony: part.harmony)
    }

    private func landingFailure(_ id: String, _ error: any Error) -> JobStop {
        if let landingError = error as? SungVocalLandingError {
            if case .projectChanged(let savedPath) = landingError {
                mutate(id) { $0.status.keptTakePath = savedPath }
            }
            return JobStop.failed(SingJobFailure(code: "singProjectChanged",
                                                 message: landingError.errorDescription ?? "The project changed."))
        }
        return JobStop.failed(SingJobFailure(code: "singLandingFailed",
                                             message: "The take couldn't be added to the song: \(error.localizedDescription)"))
    }

    /// One part: today's landing, ONE track in ONE undo step ("Land Sung Vocal"), now with the style's table.
    private func land(_ id: String, _ finished: FinishedPart) async throws(JobStop) {
        guard let job = jobs[id] else { throw JobStop.cancelled }
        let part = job.lead
        let plan = part.planning.plan
        let identity = await knownIdentity(job)
        // The notes are scored from the same frames gate L2 read (the landed file is a byte copy of the
        // checked take), so their result goes into the provenance AT landing, inside its one undo step.
        let notes = SingNoteCheck.score(frames: finished.frames, plan: plan, noteBars: part.noteBars)
        let provenance = provenance(job, part, identity: identity, report: finished.report, notes: notes,
                                    style: finished.style)
        let store = self.store
        let landingGuard = part.planning.landingGuard
        let trackName = part.trackName
        let url = finished.url
        let pitchEdits = finished.pitchEdits
        // The last boundary (design §16): nothing has landed yet, so a cancel honoured here means "nothing was
        // added". From the flag on, `cancel` refuses. NO `await` between the check, the flag and the landing.
        try checkCancelled(id)
        mutate(id) { $0.landingStarted = true }
        let landing: SungVocalLanding
        do {
            landing = try await MainActor.run {
                try store.landSungVocal(fileURL: url, trackName: trackName, atBeat: plan.atBeat,
                                        provenance: provenance, planned: landingGuard, pitchEdits: pitchEdits)
            }
        } catch {
            throw landingFailure(id, error)
        }

        mutate(id) { job in
            job.status.result = SingJobResult(
                trackID: landing.trackID, clipID: landing.clipID, loudness: finished.report, gates: finished.gates,
                melodyChanged: landing.melodyChanged, transposedSemitones: landing.transposedSemitones,
                noteAccuracy: notes, wordCheck: nil)
            if let notice = landing.notice { job.status.notices.append(notice) }
            if finished.gates.quieterThanUsual { job.status.notices.append(Copy.quietTake) }
            job.status.progress = 1
            job.status.etaSeconds = nil
        }
        // The word check runs in the background; the job reads `landed` until it starts.
        setPhase(id, .landed, Copy.landed)
        pendingChecks.insert(id)
        let generation = landingGuard.projectGeneration
        Task { await self.checkWords(id, part: 0, url: url, trackID: landing.trackID, generation: generation,
                                     notes: notes) }
    }

    /// A parts job: every line that passed its gates, in ONE undo step ("Land Sung Harmony",
    /// `ProjectStore.landSungVocals`), each on its own new track with its own mix and record.
    private func landParts(_ id: String, _ finished: [FinishedPart]) async throws(JobStop) {
        guard let job = jobs[id] else { throw JobStop.cancelled }
        let identity = await knownIdentity(job)
        var takes: [SungVocalTake] = []
        var scored: [SungNoteAccuracy] = []
        for take in finished {
            let part = job.parts[take.part]
            let notes = SingNoteCheck.score(frames: take.frames, plan: part.planning.plan, noteBars: part.noteBars)
            scored.append(notes)
            takes.append(SungVocalTake(
                fileURL: take.url, trackName: part.trackName, atBeat: part.planning.plan.atBeat,
                provenance: provenance(job, part, identity: identity, report: take.report, notes: notes,
                                       style: take.style),
                pitchEdits: take.pitchEdits, pan: part.pan, volume: part.volume, ownSource: part.ownSource,
                derived: part.derived))
        }
        let store = self.store
        let landingGuard = job.lead.planning.landingGuard
        let ready = takes
        // The last boundary (design §16), as in `land`: NO `await` between the check, the flag and the landing.
        try checkCancelled(id)
        mutate(id) { $0.landingStarted = true }
        let landings: [SungVocalLanding]
        do {
            landings = try await MainActor.run { try store.landSungVocals(ready, planned: landingGuard) }
        } catch {
            throw landingFailure(id, error)
        }
        mutate(id) { job in
            for (k, take) in finished.enumerated() {
                let landing = landings[k]
                job.status.parts?[take.part].state = .landed
                job.status.parts?[take.part].trackID = landing.trackID
                job.status.parts?[take.part].clipID = landing.clipID
                job.status.parts?[take.part].gates = take.gates
                // The job's result is its first landed line: the lead whenever it landed.
                if k == 0 {
                    job.status.result = SingJobResult(
                        trackID: landing.trackID, clipID: landing.clipID, loudness: take.report, gates: take.gates,
                        melodyChanged: landing.melodyChanged, transposedSemitones: landing.transposedSemitones,
                        noteAccuracy: scored[k], wordCheck: nil)
                }
                if let notice = landing.notice, !job.status.notices.contains(notice) {
                    job.status.notices.append(notice)
                }
                if take.gates.quieterThanUsual, !job.status.notices.contains(Copy.quietTake) {
                    job.status.notices.append(Copy.quietTake)
                }
            }
            job.status.progress = 1
            job.status.etaSeconds = nil
        }
        // The lines are in the song (copied); only the take the word check listens to is kept until it is done.
        let checked = finished[0]
        for url in jobs[id]?.takeURLs ?? [] where url != checked.url { try? FileManager.default.removeItem(at: url) }
        mutate(id) { $0.takeURLs = [checked.url] }
        setPhase(id, .landed, Copy.landed)
        pendingChecks.insert(id)
        let generation = landingGuard.projectGeneration
        let trackID = landings[0].trackID
        let notes = scored[0]
        Task { await self.checkWords(id, part: checked.part, url: checked.url, trackID: trackID,
                                     generation: generation, notes: notes) }
    }

    // MARK: After landing (design §4.6: advisory, never un-lands)

    private func checkWords(_ id: String, part p: Int, url: URL, trackID: UUID, generation: UInt64,
                            notes: SungNoteAccuracy) async {
        guard let job = jobs[id] else { pendingChecks.remove(id); return }
        let part = job.parts[p]
        setPhase(id, .checking, Copy.checkingWords)
        var heard: String?
        var failure: String?
        do {
            heard = try await transcribe(url)
        } catch {
            failure = error.localizedDescription
        }
        // A transcriber that failed is not "no speech model": the check did not run, and the notice says why.
        let words: SungWordCheck? = failure != nil ? nil
            : SingWordCheck.check(assignment: part.planning.plan.assignment, heard: heard,
                                  voiceIsReliable: part.voice.wordCheckIsReliable)
        if let words {
            let store = self.store
            _ = await MainActor.run {
                store.recordSungVocalChecks(trackId: trackID, projectGeneration: generation,
                                            noteAccuracy: nil, wordCheck: words)
            }
        }
        mutate(id) { job in
            job.status.result?.wordCheck = words
            if let failure { job.status.notices.append(Copy.wordCheckFailed(failure)) }
        }
        try? FileManager.default.removeItem(at: url)
        mutate(id) { $0.takeURLs.removeAll { $0 == url } }
        setPhase(id, .done, Copy.results(notes: notes, words: words))
        mutate(id) { $0.status.finishedAt = configuration.now() }
        pendingChecks.remove(id)
    }

    // MARK: Bookkeeping

    private func mutate(_ id: String, _ body: (inout Job) -> Void) {
        guard var job = jobs[id] else { return }
        body(&job)
        jobs[id] = job
    }

    private func setPhase(_ id: String, _ phase: SingJobPhase, _ text: String, waitingFor: String? = nil) {
        mutate(id) { job in
            job.status.phase = phase
            job.status.stageText = text
            job.status.waitingFor = phase == .waitingForModel ? waitingFor : nil
            if phase != .singing && phase != .preparingVoice { job.status.unitIndex = nil }
            job.status.etaSeconds = eta(job)
        }
    }

    private func setSinging(_ id: String, part p: Int, index: Int, preparing: Bool) {
        mutate(id) { job in
            job.status.phase = preparing ? .preparingVoice : .singing
            job.status.unitIndex = index + 1
            job.status.waitingFor = nil
            // A parts job counts the lines of the part being sung (§14 "Progress, parts").
            let count = job.parts[p].planning.plan.units.count
            if job.hasParts { job.status.unitCount = count }
            job.status.stageText = job.status.cancelRequested ? Copy.stopping
                : preparing ? Copy.preparingVoice
                : job.hasParts ? Copy.singingPart(p + 1, of: job.parts.count, line: index + 1, of: count)
                : Copy.singing(line: index + 1, of: job.status.unitCount)
            job.status.etaSeconds = eta(job)
        }
    }

    /// A parts job's per-part state (a no-op for a job without parts).
    private func setPartState(_ id: String, _ p: Int, _ state: SingJobPartStatus.State) {
        mutate(id) { $0.status.parts?[p].state = state }
    }

    /// A part that went wrong in a parts job: it will not land; the job goes on, and its sentence names it
    /// (§4.4, §14 "A part failed"). The code stays the cause's; the detail keeps the cause's words.
    private func partFailed(_ id: String, _ p: Int, _ failure: SingJobFailure) {
        mutate(id) { job in
            let sentence = Copy.partFailed(job.parts[p].name)
            let detail = [failure.message, failure.detail].compactMap { $0 }.joined(separator: " — ")
            job.status.parts?[p].state = .failed
            job.status.parts?[p].error = SingJobFailure(code: failure.code, message: sentence, detail: detail)
            if !job.status.notices.contains(sentence) { job.status.notices.append(sentence) }
        }
    }

    private func addWarning(_ id: String, _ text: String) {
        mutate(id) { job in
            if !job.status.warnings.contains(text) { job.status.warnings.append(text) }
        }
    }

    private func unitDone(_ id: String, unit: Int, cached: Bool) {
        mutate(id) { job in
            job.doneWeight += job.weights[unit]
            let total = job.weights.reduce(0, +)
            job.status.progress = total > 0 ? min(1, job.doneWeight / total) : 1
            if cached { job.status.cachedUnits += 1 } else { job.status.renderedUnits += 1 }
            job.status.etaSeconds = eta(job)
        }
    }

    private func markRetried(_ id: String, line: Int) {
        mutate(id) { job in
            if !job.status.retriedUnits.contains(line) { job.status.retriedUnits.append(line) }
        }
    }

    private func addNotice(_ id: String, _ text: String) {
        mutate(id) { job in
            if !job.status.notices.contains(text) { job.status.notices.append(text) }
        }
    }

    private func learnRealTimeFactor(_ sample: Double?) {
        guard let sample, sample.isFinite, sample > 0 else { return }
        realTimeFactor = 0.5 * realTimeFactor + 0.5 * sample
    }

    /// Design §4.2: the remaining audio × the warm RTF, plus a cold start while the engine is not up. Unknown
    /// while waiting for another model; nil once the take is assembled.
    private func eta(_ job: Job) -> Double? {
        switch job.status.phase {
        case .waitingForModel: return nil
        case .finishing, .landed, .checking, .done, .failed, .cancelled: return nil
        default:
            let remaining = max(0, job.weights.reduce(0, +) - job.doneWeight)
            let cold = job.status.phase == .startingEngine || job.status.phase == .queued
                ? configuration.coldStartSeconds : 0
            return remaining * realTimeFactor + cold
        }
    }

    private func finish(_ id: String, _ phase: SingJobPhase, failure: SingJobFailure? = nil) {
        mutate(id) { job in
            job.status.phase = phase
            job.status.unitIndex = nil
            job.status.waitingFor = nil
            job.status.etaSeconds = nil
            job.status.error = failure
            job.status.stageText = failure?.message ?? (phase == .cancelled ? Copy.cancelled : job.status.stageText)
            job.status.finishedAt = configuration.now()
            for url in job.takeURLs { try? FileManager.default.removeItem(at: url) }
            job.takeURLs = []
            // A parts job: every line that neither landed nor failed on its own ends with the job.
            if let parts = job.status.parts {
                for p in parts.indices where parts[p].state != .landed && parts[p].state != .failed {
                    job.status.parts?[p].state = phase == .cancelled ? .cancelled : .failed
                    if phase == .failed { job.status.parts?[p].error = failure }
                }
            }
        }
    }
}
