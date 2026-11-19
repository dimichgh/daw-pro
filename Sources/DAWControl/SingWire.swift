import AIServices
import DAWCore
import Foundation

// p2-sing-e part 2: the handlers behind the 17 singing verbs of design §6
// (`docs/design/2026-09-27-p2-sing-integration.md`). Each verb's `case` in
// `Commands.swift` keeps its own `rejectUnknownKeys` (the census reads it
// there) and calls one method here. The handlers reach the SAME store and
// coordinator methods the Sing sheet will (design §6 "spy test" rule): the
// lyrics through `ProjectStore.setClipLyrics`, the key through
// `ProjectStore.transposeProject`, every render through
// `SingJobCoordinator.submit`. The three protocols below exist so a test can
// put a recording spy in front of each and prove the wire reaches it.
//
// Refusals read "<code>: <sentence>" (`SingWireRefusal`): the code is the
// design's, machine-readable for an agent; the sentence is §5.7's where it has
// a row, and marked PROVISIONAL here where it does not.

// MARK: - The spy seams

/// THE lyrics write (`ProjectStore+LyricTextEdit.swift`). `clip.setLyrics` and `sing.render {lyrics}` call it.
@MainActor
public protocol SingLyricsWriting: AnyObject {
    @discardableResult
    func setClipLyrics(clipId: UUID, text: String, undoLabel: String) throws -> Clip
}

extension ProjectStore: SingLyricsWriting {}

/// p2-sing-x7: the expansion's lyrics writes (`ProjectStore+LyricTextEdit.swift`): `clip.setLyrics {language}` calls
/// the language overload and `clip.setNoteWord` calls `setNoteWord`, the methods the words box's language picker and
/// the note field call. A protocol of its own (not new requirements on `SingLyricsWriting`), so every spy written
/// for the base verbs stays valid.
@MainActor
public protocol SingLyricsEditing: AnyObject {
    @discardableResult
    func setClipLyrics(clipId: UUID, text: String, language: String?, undoLabel: String) throws -> Clip
    @discardableResult
    func setNoteWord(clipId: UUID, noteId: UUID, word: String, dryRun: Bool) throws -> LyricNoteWordResult
}

extension ProjectStore: SingLyricsEditing {}

/// p2-sing-x7: THE style write (`ProjectStore+SingStyle.swift`). `clip.setSingStyle` calls it, and so will the
/// Sing sheet's Expression card.
@MainActor
public protocol SingStyleWriting: AnyObject {
    @discardableResult
    func setSingStyle(clipId: UUID, edit: SingStyleEdit) throws -> SingStyleWriteResult
}

extension ProjectStore: SingStyleWriting {}

/// THE key change (`ProjectStore+Transpose.swift`). `project.transpose` calls it.
@MainActor
public protocol SongTransposing: AnyObject {
    @discardableResult
    func transposeProject(semitones: Int, excludeTrackIds: Set<UUID>, dryRun: Bool) throws -> TransposeReport
}

extension ProjectStore: SongTransposing {}

/// THE sing job (`SingJobCoordinator`, ONE per app). `sing.render`, `sing.jobStatus`, `sing.cancelJob` and the
/// sidecar verbs' job checks call it.
public protocol SingJobSubmitting: Sendable {
    func submit(_ request: SingJobRequest) async throws -> SingJobStatus
    /// What `submit` would plan (the lead and every part), changing nothing (W8-X6F's plan-only entry): `sing.render
    /// {dryRun, parts}` reads its `parts` here, never from a planner of its own.
    func plan(_ request: SingJobRequest) async throws -> SingJobCoordinator.PlanPreview
    /// The same, over words that are not stored yet (p2-sing-x7d): `sing.render` with `parts` and new `lyrics` plans
    /// here BEFORE it stores anything, so a refusal changes nothing. `nil` keeps the stored words.
    func plan(_ request: SingJobRequest, lyrics: ClipLyrics??) async throws -> SingJobCoordinator.PlanPreview
    func status(jobID: String) async throws -> SingJobStatus
    func statuses(limit: Int) async -> [SingJobStatus]
    func cancel(jobID: String) async throws -> SingJobStatus
}

extension SingJobCoordinator: SingJobSubmitting {}

/// The voice recorder window (item f). `sing.openVoiceRecorder` answers `singNoWindow` until one registers
/// (`CommandRouter.singVoiceRecorder`, held weakly). Opening it is all an agent can do: only the user presses
/// Record (design §5.4).
@MainActor
public protocol SingVoiceRecorderPresenting: AnyObject {
    func openVoiceRecorder(fromAgent: Bool) throws
}

// MARK: - What the app hands the router

/// Everything the singing verbs need beyond the store, built ONCE by the app (`DAWProApp`) and shared with the
/// Sing sheet. A router built without it (every test that does not ask, every headless session) still answers
/// `clip.setLyrics`, `clip.getLyrics`, `project.transpose`, `sing.proposeKey` for the built-in voice and
/// `sing.render {dryRun}`; the engine and voice verbs then refuse with `singNotConnected`.
public struct SingWireServices: Sendable {
    public var engine: any SingEngineControlling
    public var jobs: any SingJobSubmitting
    public var install: SingingEngineInstallCoordinator
    public var consent: SingConsentBroker
    public var voices: SingVoiceLibrary
    public var engineFiles: SingEngineFiles
    public var lifecycle: ModelLifecycleCoordinator
    /// SwiftF0 frames over a file from 0 for the given seconds, confidence 0.9 (the engine's `detectPitch`).
    public var detectPitch: @Sendable (URL, Double) async throws -> [ClipPitchFrame]
    /// What the speech model hears in a file; nil when none is installed (`SingSpeech.transcribe`).
    public var transcribe: @Sendable (URL) async throws -> String?
    /// Free bytes on the volume a path is on (`SingEngineFiles.freeBytes(near:)`).
    public var freeDiskBytes: @Sendable (URL) -> Int64?
    /// Moves a voice's folder to the Trash and returns where it went (`SingVoiceLibrary.moveToTrash`).
    public var trash: @Sendable (URL) throws -> URL
    /// The guide tunes `sing.addVoice`'s leak check compares against; nil = the bundled ones (the app). A test
    /// passes `[:]` (the check then reports "not measured", as a build without the guide files does).
    public var voiceCheckGuides: [SingGuideLine.Guide: RenderedAudio]?

    public init(engine: any SingEngineControlling, jobs: any SingJobSubmitting,
                install: SingingEngineInstallCoordinator, consent: SingConsentBroker, voices: SingVoiceLibrary,
                engineFiles: SingEngineFiles, lifecycle: ModelLifecycleCoordinator,
                detectPitch: @escaping @Sendable (URL, Double) async throws -> [ClipPitchFrame],
                transcribe: @escaping @Sendable (URL) async throws -> String?,
                freeDiskBytes: @escaping @Sendable (URL) -> Int64? = { SingEngineFiles.freeBytes(near: $0) },
                trash: @escaping @Sendable (URL) throws -> URL = { try SingVoiceLibrary.moveToTrash($0) },
                voiceCheckGuides: [SingGuideLine.Guide: RenderedAudio]? = nil) {
        self.engine = engine
        self.jobs = jobs
        self.install = install
        self.consent = consent
        self.voices = voices
        self.engineFiles = engineFiles
        self.lifecycle = lifecycle
        self.detectPitch = detectPitch
        self.transcribe = transcribe
        self.freeDiskBytes = freeDiskBytes
        self.trash = trash
        self.voiceCheckGuides = voiceCheckGuides
    }
}

// MARK: - Refusals

/// A singing verb's refusal: `"<code>: <sentence>"` on the wire.
public struct SingWireRefusal: Error, Equatable, LocalizedError {
    public var code: String
    public var sentence: String

    public init(_ code: String, _ sentence: String) {
        self.code = code
        self.sentence = sentence
    }

    public var errorDescription: String? { "\(code): \(sentence)" }
}

// MARK: - The handlers

@MainActor
final class SingWireHandlers {

    /// The undo step `clip.setLyrics` and `sing.render {lyrics}` record. PROVISIONAL (design §6 names none; the
    /// note field's is "Type Word").
    static let setLyricsUndoLabel = "Set Lyrics"
    /// How many recent jobs `sing.jobStatus` lists without an id (design §6 row 15).
    static let recentJobs = 20

    private let store: ProjectStore
    private let lyrics: any SingLyricsWriting
    private let transposer: any SongTransposing
    /// p2-sing-x7: the language-aware lyrics write and the note field's write.
    private let lyricEdits: any SingLyricsEditing
    /// p2-sing-x7: the style write.
    private let styles: any SingStyleWriting
    let services: SingWireServices?

    weak var voiceRecorder: (any SingVoiceRecorderPresenting)?
    /// Told about every job the wire submits, with the card's label (the app registers it with the progress
    /// card as `GenerationJobOrigin.forSingJob(fromAgent:)`, never as an ACE job).
    var onJobSubmitted: (@MainActor (_ status: SingJobStatus, _ label: String) -> Void)?
    /// True while `sing.sidecarStop` runs (`sing.sidecarStatus` then reads `stopping`).
    private var stopping = false
    /// The last background word check `sing.addVoice` started (tests wait on it).
    var lastVoiceWordCheck: Task<Void, Never>?
    /// What the last uninstall freed (the consent performer has no reply of its own).
    private(set) var lastUninstallBytesFreed: Int64?

    init(store: ProjectStore, lyrics: any SingLyricsWriting, transposer: any SongTransposing,
         services: SingWireServices?, lyricEdits: (any SingLyricsEditing)? = nil,
         styles: (any SingStyleWriting)? = nil) {
        self.store = store
        self.lyrics = lyrics
        self.transposer = transposer
        self.lyricEdits = lyricEdits ?? store
        self.styles = styles ?? store
        self.services = services
        services?.consent.performer = { [weak self] action in
            guard let self else { throw SingConsentError.notConnected }
            try await self.perform(action)
        }
    }

    private func requireServices(_ verb: String) throws -> SingWireServices {
        guard let services else {
            // PROVISIONAL (no §6 row: a router built without the singing services, e.g. a headless session).
            throw SingWireRefusal("singNotConnected",
                                  "\(verb) needs the singing engine, which is not connected in this control "
                                      + "session. Start DAW Pro (or run `swift run DAWApp`) and send it to that "
                                      + "app's control port.")
        }
        return services
    }

    // MARK: 1. sing.sidecarStatus

    func sidecarStatus(_ params: [String: JSONValue]) async throws -> JSONValue {
        let verify = try Self.optionalBool(params, "verify") ?? false
        let s = try requireServices("sing.sidecarStatus")
        let engine = await s.engine.status()
        let install = await s.install.status()
        var state = Self.wireState(engine.state)
        var message = engine.message
        var problems: [String] = []
        if engine.state == .installedNotRunning {
            problems = s.engineFiles.preflightProblems()
            if !problems.isEmpty {
                state = "error"
                // PROVISIONAL (no §5.7 row).
                message = "The singing engine's install is incomplete: \(problems.joined(separator: "; ")). "
                    + "Call sing.installEngine to repair it."
            }
        }
        if (engine.state == .notInstalled || engine.state == .needsUpdate),
           s.consent.pendingRequest(for: .installEngine) != nil {
            state = "awaitingUserConsent"
            // PROVISIONAL.
            message = "DAW Pro is asking for permission to download the singing engine (about 7 GB). Nothing "
                + "downloads until Install is clicked in DAW Pro's window."
        }
        if install.state == .installing {
            state = "installing"
            message = install.cancelRequested ? "Stopping the singing engine's install…"
                : Self.installingMessage(install.progress)
        }
        if stopping {
            state = "stopping"
            message = "The singing engine is stopping…"   // PROVISIONAL
        }
        let residency = await s.lifecycle.residency()
        let resident = residency.models.first { $0.modelID == .soulxSinger }?.resident ?? false
        var lastError: String?
        if install.state == .failed || install.state == .cancelled { lastError = install.errorMessage }
        if engine.state == .error { lastError = engine.message }

        var reply: [String: JSONValue] = [
            "state": .string(state),
            "message": .string(message),
            "engineState": .string(engine.state.rawValue),
            "pid": Self.number(engine.pid.map(Double.init)),
            "startingForSeconds": Self.number(engine.startingForSeconds.map(Double.init)),
            "resident": .bool(resident),
            "install": try JSONValue(encoding: install),
            "runtime": try s.engineFiles.runtimeFacts().map { try JSONValue(encoding: $0) } ?? .null,
            "builtInVoice": .bool(s.engineFiles.builtInVoiceAvailable()),
            "problems": .array(problems.map(JSONValue.string)),
            "consent": try JSONValue(encoding: s.consent.pending),
            "lastError": Self.string(lastError),
        ]
        if engine.state == .healthy {
            reply["health"] = .object([
                "facadeVersion": Self.number(engine.facadeVersion.map(Double.init)),
                "commit": Self.string(engine.commit),
                "weightsRevision": Self.string(engine.weightsRevision),
                "weightsBytes": Self.number(engine.weightsBytes.map(Double.init)),
                "device": Self.string(engine.device),
                "loadSeconds": Self.number(engine.loadSeconds),
                "mpsDriverBytes": Self.number(engine.mpsDriverBytes.map(Double.init)),
                "rendered": Self.number(engine.rendered.map(Double.init)),
                "ffmpegMajor": Self.number(engine.ffmpegMajor.map(Double.init)),
            ])
        }
        if verify {
            let files = s.engineFiles
            let verification = await Task.detached { files.verifyWeights() }.value
            reply["verify"] = try JSONValue(encoding: verification)
        }
        return .object(reply)
    }

    /// The manager's states in design §2.8's words (`healthy` is §2.8's `ready`).
    static func wireState(_ state: SingingSidecarState) -> String {
        switch state {
        case .notInstalled: return "notInstalled"
        case .needsUpdate: return "needsUpdate"
        case .installedNotRunning: return "installedNotRunning"
        case .starting: return "starting"
        case .healthy: return "ready"
        case .error: return "error"
        }
    }

    /// PROVISIONAL (no §5.7 row for the install's progress line).
    static func installingMessage(_ progress: SingingEngineInstallProgress?) -> String {
        guard let progress else { return "Installing the singing engine…" }
        return "Installing the singing engine: step \(progress.stepIndex) of \(progress.stepCount) "
            + "(\(progress.stepName))…"
    }

    private func statusReply(_ status: SingingSidecarStatus) -> JSONValue {
        .object([
            "state": .string(Self.wireState(status.state)),
            "engineState": .string(status.state.rawValue),
            "message": .string(status.message),
            "pid": Self.number(status.pid.map(Double.init)),
            "startingForSeconds": Self.number(status.startingForSeconds.map(Double.init)),
        ])
    }

    // MARK: 2. sing.sidecarStart

    func sidecarStart() async throws -> JSONValue {
        let s = try requireServices("sing.sidecarStart")
        let current = await s.engine.status()
        switch current.state {
        case .notInstalled: throw SingWireRefusal("singEngineNotInstalled", current.message)
        case .needsUpdate: throw SingWireRefusal("singEngineNeedsUpdate", current.message)
        case .healthy: return statusReply(current)
        case .installedNotRunning, .starting, .error: break
        }
        let config = s.engine.engineConfig
        if current.state != .starting,
           let foreign = s.engineFiles.foreignListener(baseURL: config.baseURL, pidfileURL: config.pidfileURL) {
            let port = config.baseURL.port.map(String.init) ?? config.baseURL.absoluteString
            // PROVISIONAL (the manager's own words for the same check, `checkPortNotForeign`).
            throw SingWireRefusal("singPortBusy",
                                  "Port \(port) is already in use by something that is not the singing engine: "
                                      + "\(foreign). Stop it, or set SING_API_URL to point the singing engine "
                                      + "at a different port.")
        }
        let started: SingingSidecarStatus
        do {
            started = try await s.engine.start()
        } catch SidecarError.notInstalled(let message) {
            throw SingWireRefusal("singEngineNotInstalled", message)
        } catch {
            throw Self.startFailed(error.localizedDescription)
        }
        if started.state == .error { throw Self.startFailed(started.message) }
        return statusReply(started)
    }

    /// §5.7 "Engine won't start", with the wire's way to try again (PROVISIONAL tail: the card's buttons are
    /// [Try again] [Details]).
    static func startFailed(_ cause: String) -> SingWireRefusal {
        let trimmed = cause.trimmingCharacters(in: .whitespacesAndNewlines)
        let stop = trimmed.hasSuffix(".") ? "" : "."
        return SingWireRefusal("singStartFailed",
                               SingJobCoordinator.Copy.engineWontStart(trimmed) + stop
                                   + " Call sing.sidecarStart to try again.")
    }

    // MARK: 3. sing.sidecarStop

    func sidecarStop(_ params: [String: JSONValue]) async throws -> JSONValue {
        let cancelJobs = try Self.optionalBool(params, "cancelJobs") ?? false
        let s = try requireServices("sing.sidecarStop")
        let active = await activeJobs(s)
        var cancelled: [String] = []
        if !active.isEmpty {
            guard cancelJobs else {
                // PROVISIONAL sentence (§6 names the code only).
                throw SingWireRefusal("singJobsRunning",
                                      "A take is being sung right now. Wait for it to finish (sing.jobStatus), "
                                          + "or send cancelJobs: true to stop it and the engine together.")
            }
            for job in active {
                if (try? await s.jobs.cancel(jobID: job.jobID)) != nil { cancelled.append(job.jobID) }
            }
        }
        stopping = true
        defer { stopping = false }
        let report: SingingStopReport
        do {
            report = try await s.engine.stopReportingEvidence()
        } catch {
            // PROVISIONAL code (not in §6): the manager's own stop refusal, verbatim.
            throw SingWireRefusal("singStopFailed", error.localizedDescription)
        }
        await s.lifecycle.noteStoppedExternally(.soulxSinger)
        return .object([
            "state": .string(Self.wireState(report.status.state)),
            "engineState": .string(report.status.state.rawValue),
            "message": .string(report.status.message),
            "pid": Self.number(report.status.pid.map(Double.init)),
            "stopped": .bool(report.evidence.stopped),
            "evidence": try JSONValue(encoding: report.evidence),
            "cancelledJobs": .array(cancelled.map(JSONValue.string)),
        ])
    }

    /// Jobs still rendering or waiting (not landed: a landed take's checks need no engine).
    private func activeJobs(_ s: SingWireServices) async -> [SingJobStatus] {
        await s.jobs.statuses(limit: 10_000).filter { !$0.phase.isTerminal && !$0.phase.hasLanded }
    }

    // MARK: 4. sing.installEngine

    func installEngine() async throws -> JSONValue {
        let s = try requireServices("sing.installEngine")
        let install = await s.install.status()
        if install.state == .installing {
            throw SingWireRefusal("singInstallInProgress",
                                  SingingEngineInstallCoordinatorError.installAlreadyInFlight.errorDescription ?? "")
        }
        let engine = await s.engine.status()
        let broken = !s.engineFiles.preflightProblems().isEmpty
        if engine.state != .notInstalled, engine.state != .needsUpdate, !broken {
            return .object([
                "state": .string("alreadyInstalled"),
                // PROVISIONAL.
                "message": .string("The singing engine is already installed. Call sing.sidecarStart to start it, "
                                   + "or just call sing.render: a render starts it."),
                "runtime": try s.engineFiles.runtimeFacts().map { try JSONValue(encoding: $0) } ?? .null,
            ])
        }
        // The pre-consent checks (the Mac, then the free disk where the engine goes) through THE one seam the Sing
        // sheet's install path calls too (p2-sing-x7b, W8-SF's finding). Its sentences are this verb's, unchanged.
        if let refusal = SingInstallPreflight.check(engineFiles: s.engineFiles,
                                                    runtimeDir: s.engine.engineConfig.runtimeDir,
                                                    freeDiskBytes: s.freeDiskBytes) {
            throw SingWireRefusal(refusal.code, refusal.sentence)
        }
        switch try await s.consent.request(.installEngine, fromAgent: true) {
        case .awaitingUserConsent(let request):
            return .object([
                "state": .string("awaitingUserConsent"),
                "requestId": .string(request.id),
                // PROVISIONAL.
                "message": .string("DAW Pro is asking for permission to download the singing engine (about 7 GB, "
                                   + "one time). Nothing downloads until Install is clicked in DAW Pro's window. "
                                   + "Poll sing.sidecarStatus to see when it starts."),
            ])
        case .performed:
            let started = await s.install.status()
            return .object([
                "state": .string("installing"),
                "message": .string(Self.installingMessage(started.progress)),
                "install": try JSONValue(encoding: started),
            ])
        }
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }

    // MARK: 5. sing.cancelInstall

    func cancelInstall() async throws -> JSONValue {
        let s = try requireServices("sing.cancelInstall")
        if let withdrawn = s.consent.withdraw(.installEngine) {
            return .object([
                "cancelRequested": .bool(true),
                "withdrewRequestId": .string(withdrawn.id),
                "install": try JSONValue(encoding: await s.install.status()),
            ])
        }
        do {
            let status = try await s.install.cancel()
            return .object(["cancelRequested": .bool(true), "install": try JSONValue(encoding: status)])
        } catch let error as SingingEngineInstallCoordinatorError {
            throw SingWireRefusal("singNoInstallRunning", error.errorDescription ?? "")
        }
    }

    // MARK: 6. sing.uninstallEngine

    func uninstallEngine(_ params: [String: JSONValue]) async throws -> JSONValue {
        let dryRun = try Self.optionalBool(params, "dryRun") ?? false
        let s = try requireServices("sing.uninstallEngine")
        try await refuseUninstallWhileBusy(s)
        let files = s.engineFiles
        guard files.isPresent else {
            return .object([
                "installed": .bool(false), "dryRun": .bool(dryRun), "bytes": .number(0),
                // PROVISIONAL.
                "message": .string("The singing engine is not installed, so there is nothing to remove."),
            ])
        }
        let bytes = await Task.detached { files.sizeOnDisk() }.value
        if dryRun {
            return .object([
                "installed": .bool(true), "dryRun": .bool(true), "wouldFreeBytes": .number(Double(bytes)),
                "path": Self.string(files.runtimeDir?.path),
                // PROVISIONAL.
                "message": .string("Removing the singing engine would free \(Self.gigabytes(bytes)) GB. Your "
                                   + "voices and songs stay."),
            ])
        }
        switch try await s.consent.request(.uninstallEngine, fromAgent: true) {
        case .awaitingUserConsent(let request):
            return .object([
                "state": .string("awaitingUserConsent"),
                "requestId": .string(request.id),
                "wouldFreeBytes": .number(Double(bytes)),
                // PROVISIONAL.
                "message": .string("DAW Pro is asking for permission to remove the singing engine "
                                   + "(\(Self.gigabytes(bytes)) GB). Nothing is deleted until someone clicks Remove the engine "
                                   + "in DAW Pro's window."),
            ])
        case .performed:
            return .object([
                "state": .string("uninstalled"),
                "bytesFreed": .number(Double(lastUninstallBytesFreed ?? 0)),
                "message": .string("The singing engine was removed. Your voices and songs stay."),
            ])
        }
    }

    private func refuseUninstallWhileBusy(_ s: SingWireServices) async throws {
        if await s.install.status().state == .installing {
            // PROVISIONAL sentence.
            throw SingWireRefusal("singInstallInProgress",
                                  "The singing engine is being installed right now. Cancel it with "
                                      + "sing.cancelInstall, or wait for it to finish, before removing it.")
        }
        if !(await activeJobs(s)).isEmpty {
            // PROVISIONAL sentence.
            throw SingWireRefusal("singJobsRunning",
                                  "A take is being sung right now. Wait for it to finish, or stop it with "
                                      + "sing.cancelJob, before removing the singing engine.")
        }
    }

    // MARK: The consent performer (the user's yes)

    /// What a yes does. Called by `SingConsentBroker.approve(id:)` (the window, item f) or at once under the
    /// staging launch flag. Never called by a wire verb directly.
    func perform(_ action: SingConsentAction) async throws {
        let s = try requireServices("sing.\(action.rawValue)")
        switch action {
        case .installEngine:
            _ = try await s.install.start()
        case .uninstallEngine:
            try await refuseUninstallWhileBusy(s)
            stopping = true
            defer { stopping = false }
            _ = try await s.engine.stopReportingEvidence()
            await s.lifecycle.noteStoppedExternally(.soulxSinger)
            let files = s.engineFiles
            lastUninstallBytesFreed = try await Task.detached { try files.removeRuntime() }.value
        }
    }

    // MARK: 7. sing.listVoices

    func listVoices() async throws -> JSONValue {
        let s = try requireServices("sing.listVoices")
        let library = s.voices
        let (voices, unreadable) = await Task.detached { library.list() }.value
        var list: [JSONValue] = [builtInVoiceJSON(available: s.engineFiles.builtInVoiceAvailable())]
        list += voices.map { Self.voiceJSON($0) }
        return .object(["voices": .array(list), "unreadable": .array(unreadable.map(JSONValue.string))])
    }

    private func builtInVoiceJSON(available: Bool) -> JSONValue {
        .object([
            "id": .string(SingJobVoice.builtInID),
            "name": .string(SingJobVoice.builtInName),
            "kind": .string(SungVocalProvenance.VoiceKind.builtIn),
            "createdAt": .null,
            "durationS": .null,
            "range": Self.rangeJSON(SingVoiceLibrary.builtInRange),
            "alignment": .null,
            "wordCheck": .null,
            "available": .bool(available),
        ])
    }

    static func voiceJSON(_ r: SingVoiceRecord) -> JSONValue {
        .object([
            "id": .string(r.id),
            "name": .string(r.name),
            "kind": .string(r.kind),
            "createdAt": .string(iso8601(r.createdAt)),
            "durationS": .number(r.durationS),
            "range": rangeJSON(r.range),
            "alignment": .object(["method": .string(r.labels.method), "verdict": .string(r.labels.verdict.rawValue)]),
            "wordCheck": r.wordCheck.map(wordCheckJSON) ?? .null,
            "source": .string(r.source.rawValue),
            "available": .bool(true),
        ])
    }

    static func rangeJSON(_ v: VoiceRange) -> JSONValue {
        .object([
            "p10Midi": .number(v.p10Midi), "p50Midi": .number(v.medianMidi), "p90Midi": .number(v.p90Midi),
            "lowNote": .string(VoiceRangeFit.noteName(midi: v.p10Midi)),
            "medianNote": .string(VoiceRangeFit.noteName(midi: v.medianMidi)),
        ])
    }

    static func wordCheckJSON(_ w: SungWordCheck) -> JSONValue {
        .object(["state": .string(w.state), "wer": number(w.wer), "heard": string(w.heard),
                 "verdict": string(w.verdict)])
    }

    // MARK: 8. sing.addVoice

    func addVoice(_ params: [String: JSONValue]) async throws -> JSONValue {
        let s = try requireServices("sing.addVoice")
        let hasPath = params["path"] != nil
        let hasClip = params["clipId"] != nil
        guard hasPath != hasClip else {
            throw ControlError("sing.addVoice: pass exactly one of 'path' (an audio file) or 'clipId' (an audio clip)")
        }
        var name: String?
        if let raw = params["name"] {
            guard let value = raw.stringValue else { throw ControlError("'name' must be a string") }
            name = value
        }
        let source: URL
        var start = 0.0
        var window: Double?
        let kind: SingVoiceRecord.Source
        let sourceName: String
        if hasPath {
            source = URL(fileURLWithPath: try params.requireAbsolutePath("path"))
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw SingWireRefusal("singVoiceFileUnreadable",
                                      SingVoiceAddRefusal.unreadable("there is no file at \(source.path)").sentence)
            }
            kind = .file
            sourceName = source.lastPathComponent
        } else {
            let clipId = try params.requireClipID()
            let resolved: ProjectStore.ClipTranscriptionSource
            do {
                resolved = try store.transcriptionSource(clipId: clipId)
            } catch ProjectError.clipNotFound(let id) {
                throw Self.clipNotFound(id)
            } catch ProjectError.transcriptionRequiresAudioClip {
                // PROVISIONAL sentence.
                throw SingWireRefusal("singVoiceNeedsAudioClip",
                                      "A voice is made from a recording of someone singing. This clip is MIDI "
                                          + "notes, so pick an audio clip instead.")
            } catch ProjectError.transcriptionRequiresUnstretchedClip {
                // PROVISIONAL sentence (the clip.transcribe rule: a stretched clip's timing is not the source's).
                throw SingWireRefusal("singVoiceClipStretched",
                                      "This clip is time-stretched, so it no longer sounds the way it was sung. "
                                          + "Set its stretch back to normal, or use the original recording.")
            }
            source = resolved.audioURL
            start = resolved.startSeconds
            window = resolved.endSeconds - resolved.startSeconds
            kind = .clip
            sourceName = store.tracks.lazy.flatMap(\.clips).first { $0.id == clipId }?.name ?? source.lastPathComponent
        }
        let record: SingVoiceRecord
        do {
            record = try await SingVoicePreparation.prepare(
                source: source, startSeconds: start, windowSeconds: window, name: name, kind: kind,
                sourceName: sourceName, library: s.voices, detectPitch: s.detectPitch,
                guides: s.voiceCheckGuides)
        } catch let refusal as SingVoiceAddRefusal {
            throw SingWireRefusal(refusal.code, refusal.sentence)
        }
        startVoiceWordCheck(record, s)
        var reply = Self.voiceJSON(record).objectValue ?? [:]
        var message = VoiceRangeFit.voiceSavedSentence(record.range)
        if record.labels.verdict == .poor { message += " " + VoiceReferenceLabeler.poorAlignmentMessage }
        reply["message"] = .string(message)
        reply["wordCheckRunning"] = .bool(true)
        return .object(reply)
    }

    /// Design §6 row 8: "the word check follows in the background". It never blocks the reply and never fails
    /// the voice; with no speech model it records `skipped`.
    private func startVoiceWordCheck(_ record: SingVoiceRecord, _ s: SingWireServices) {
        let library = s.voices
        let transcribe = s.transcribe
        let reference = library.referenceURL(for: record.id)
        lastVoiceWordCheck = Task.detached {
            let heard: String?
            do {
                heard = try await transcribe(reference)
            } catch {
                return   // the transcriber failed: leave the voice unchecked rather than guess
            }
            guard var current = try? library.record(id: record.id) else { return }
            current.wordCheck = SingVoiceWordCheck.check(heard: heard)
            try? library.update(current)
        }
    }

    // MARK: 9. sing.removeVoice

    func removeVoice(_ params: [String: JSONValue]) async throws -> JSONValue {
        let id = try params.require("voiceId", \.stringValue)
        if id.hasPrefix("builtin-") {
            // PROVISIONAL sentence.
            throw SingWireRefusal("singVoiceBuiltIn",
                                  "The built-in singer comes with the singing engine, so it can't be removed.")
        }
        let s = try requireServices("sing.removeVoice")
        do {
            let moved = try s.voices.remove(id: id, trash: s.trash)
            return .object(["voiceId": .string(id), "movedToTrash": .string(moved.path)])
        } catch SingVoiceLibraryError.notFound, SingVoiceLibraryError.builtIn {
            throw Self.voiceNotFound(id)
        }
    }

    /// PROVISIONAL sentence.
    static func voiceNotFound(_ id: String) -> SingWireRefusal {
        SingWireRefusal("singVoiceNotFound",
                        "There is no voice \"\(id)\". Call sing.listVoices to see the voices you can use.")
    }

    // MARK: 10. sing.openVoiceRecorder

    func openVoiceRecorder() throws -> JSONValue {
        guard let recorder = voiceRecorder else {
            // PROVISIONAL sentence.
            throw SingWireRefusal("singNoWindow",
                                  "No DAW Pro window can show the voice recorder right now. Open DAW Pro's main "
                                      + "window and try again, or add a recording you already have with "
                                      + "sing.addVoice.")
        }
        try recorder.openVoiceRecorder(fromAgent: true)
        return .object(["opened": .bool(true)])
    }

    // MARK: 11. sing.proposeKey

    func proposeKey(_ params: [String: JSONValue]) async throws -> JSONValue {
        let clipId = try params.requireClipID()
        let voiceID = try Self.optionalString(params, "voiceId")
        let (track, clip) = try locate(clipId)
        guard clip.isMIDI else {
            throw SingWireRefusal("singNeedsMIDIClip", SingPlanRefusal.audioClip.sentence)
        }
        guard !ProjectTranspose.isDrumTrack(track) else {
            // PROVISIONAL refusal for this verb (§6 lists it for sing.render): a drum part has no range to fit.
            throw SingWireRefusal("singDrumTrack", SingPlanRefusal.drumTrack.sentence)
        }
        let (voice, range) = try resolveVoice(voiceID)
        let melody = Self.melodyForFit(clip, tempoMap: store.transport.tempoMap)
        guard let proposal = VoiceRangeFit.propose(melody: melody, voice: range) else {
            // PROVISIONAL refusal for this verb.
            throw SingWireRefusal("singClipHasNoNotes", SingPlanRefusal.noNotes.sentence)
        }
        let pitches = melody.filter { $0.durationSeconds > 0 }.map(\.midi)
        let low = pitches.min() ?? 0
        let high = pitches.max() ?? 0
        var alternatives: [JSONValue] = []
        if let alternative = proposal.alternative { alternatives.append(Self.candidateJSON(alternative, proposal)) }
        return .object([
            "clipId": .string(clipId.uuidString),
            "voice": .object(["id": .string(voice.id), "name": .string(voice.name), "range": Self.rangeJSON(range)]),
            "melody": .object([
                "lowMidi": .number(low), "highMidi": .number(high), "medianMidi": .number(proposal.melodyMedianMidi),
                "lowNote": .string(VoiceRangeFit.noteName(midi: low)),
                "highNote": .string(VoiceRangeFit.noteName(midi: high)),
            ]),
            "recommendation": .object([
                "kind": .string(proposal.kind.rawValue),
                "octaveShift": .number(Double(proposal.recommendation.octaveShift)),
                "songTranspose": .number(Double(proposal.recommendation.songTranspose)),
                "vocalOffset": .number(Double(proposal.recommendation.vocalOffset)),
                "calibrated": .bool(proposal.calibrated),
                // p2-sing-x9-f5 (additive): false when even the recommendation leaves notes outside the voice.
                "fits": .bool(proposal.fits),
            ]),
            "alternatives": .array(alternatives),
            "sentence": .string(proposal.sentence),
            "alternativeSentence": Self.string(proposal.alternativeSentence),
            "bestOctaveOnly": .object([
                "octaveShift": .number(Double(proposal.bestOctaveOnly.octaveShift)),
                "cost": .number(proposal.bestOctaveOnly.cost),
            ]),
        ])
    }

    private static func candidateJSON(_ c: KeyFitCandidate, _ p: KeyProposal) -> JSONValue {
        .object([
            "kind": .string(c.songTranspose == 0 ? KeyProposal.Kind.octave.rawValue : KeyProposal.Kind.songKey.rawValue),
            "octaveShift": .number(Double(c.octaveShift)),
            "songTranspose": .number(Double(c.songTranspose)),
            "vocalOffset": .number(Double(c.vocalOffset)),
            "calibrated": .bool(p.calibrated),
            "sentence": string(p.alternativeSentence),
        ])
    }

    /// The melody a voice is fitted to: the notes `sing.render` would sing (`SingPlanner.melody`), at their
    /// lengths in seconds.
    static func melodyForFit(_ clip: Clip, tempoMap: TempoMap) -> [VoiceRangeFit.MelodyNote] {
        SingPlanner.melody(of: clip).notes.map {
            VoiceRangeFit.MelodyNote(midi: Double($0.pitch),
                                     durationSeconds: tempoMap.seconds(from: clip.startBeat + $0.startBeat,
                                                                       to: clip.startBeat + $0.startBeat
                                                                           + $0.lengthBeats))
        }
    }

    private func resolveVoice(_ id: String?) throws -> (voice: SingJobVoice, range: VoiceRange) {
        let id = id ?? SingJobVoice.builtInID
        if id == SingJobVoice.builtInID { return (.builtIn, SingVoiceLibrary.builtInRange) }
        guard let library = services?.voices else { throw Self.voiceNotFound(id) }
        do {
            let record = try library.record(id: id)
            // The voice's measured range rides along inside `ownVoice` itself (p2-sing-x7c: one home, shared with the
            // Sing sheet), so a harmony part sung in this voice gets its own whole-octave fit (`SingJobVoice.range`).
            return (.own(library.ownVoice(record)), record.range)
        } catch SingVoiceLibraryError.unreadable(_, let detail) {
            // PROVISIONAL.
            throw SingWireRefusal("singVoiceNotFound", "The voice \"\(id)\" could not be read (\(detail)). "
                                      + "Call sing.listVoices to see the voices you can use.")
        } catch {
            throw Self.voiceNotFound(id)
        }
    }

    // MARK: 12. clip.setLyrics

    func setLyrics(_ params: [String: JSONValue]) throws -> JSONValue {
        let clipId = try params.requireClipID()
        // p2-sing-x7: `wordless` (design 2026-10-06 §8.1) writes the text from the clip's own phrases; without it,
        // `text` is required exactly as before (same check, same sentence).
        let wordless = try Self.wordlessChoice(params)
        var typed: String?
        if wordless == nil {
            guard let raw = params["text"], let text = raw.stringValue else {
                throw ControlError("missing or invalid required param 'text' (a string; \"\" clears the lyrics)")
            }
            typed = text
        }
        let language = try Self.lyricLanguage(params)
        let dryRun = try Self.optionalBool(params, "dryRun") ?? false
        let (_, clip) = try locate(clipId)
        let text = try typed ?? Self.wordlessText(wordless!, clip: clip)
        let (normalized, assignment, after) = try validatedLyrics(text, on: clip, language: language,
                                                                  codes: .setLyrics)
        // Without `language` the text is the whole edit (the base rule); with it, a language-only change is an
        // edit too (`setClipLyrics(…language:…)`'s rule).
        let changed = language == .keep ? normalized != (clip.lyrics?.text ?? "") : after != clip.lyrics
        if !dryRun, changed {
            do {
                switch language {
                case .keep:
                    try lyrics.setClipLyrics(clipId: clipId, text: text, undoLabel: Self.setLyricsUndoLabel)
                case .set(let code):
                    try lyricEdits.setClipLyrics(clipId: clipId, text: text, language: code,
                                                 undoLabel: Self.setLyricsUndoLabel)
                }
            } catch let error as ProjectError {
                throw Self.storeRefusal(error)
            } catch let error as LyricEditRefusal {
                throw Self.lyricEditRefusal(error)
            }
        }
        var reply: [String: JSONValue] = [
            "clipId": .string(clipId.uuidString),
            "text": .string(normalized),
            "stored": .bool(!dryRun),
            "changed": .bool(changed),
            "assignment": Self.assignmentJSON(assignment),
            "warnings": .array((assignment?.warnings ?? []).map { .string($0.sentence) }),
        ]
        // Only when the request named a language (S6: without it, the base reply exactly).
        if case .set(let code) = language {
            reply["language"] = .string(LyricLanguage.stored(code) ?? LyricLanguage.english)
        }
        return .object(reply)
    }

    private enum LyricCodes { case setLyrics, render }

    /// The checks a lyrics write makes BEFORE anything is stored, the same for a dry run and a real one: an audio
    /// clip, the length cap, then the one derivation (`SingPlanner.assignment`) over the new text. "No words"
    /// is not a refusal here: blank text clears the lyrics.
    private func validatedLyrics(_ text: String, on clip: Clip, language: LyricLanguageChoice,
                                 codes: LyricCodes) throws
        -> (text: String, assignment: LyricAssignment?, lyrics: ClipLyrics?) {
        guard clip.isMIDI else {
            switch codes {
            case .setLyrics: throw SingWireRefusal("lyricsNeedMIDIClip", LyricEditRefusal.needsMIDIClip.sentence)
            case .render: throw SingWireRefusal("singNeedsMIDIClip", SingPlanRefusal.audioClip.sentence)
            }
        }
        guard text.count <= ClipLyrics.maxTextLength else {
            throw SingWireRefusal("lyricsTooLong", LyricEditRefusal.tooLong(characters: text.count).sentence)
        }
        // p2-sing-x7: the probe carries the language the STORE would write. Without `language` the store's text-only
        // write keeps the clip's own (`ClipLyrics.withText`), so a Chinese clip is checked as Chinese; an English
        // clip has none, so this is the base check exactly. A code that cannot be sung is refused here, before
        // anything is stored (a dry run too), with the store's own code and sentence.
        let typed: ClipLyrics
        switch language {
        case .keep:
            typed = clip.lyrics?.withText(text) ?? ClipLyrics(text: text)
        case .set(let code):
            guard LyricLanguage.isSupported(code) else { throw Self.lyricRefusal(.languageUnsupported(language: code)) }
            typed = ClipLyrics(text: text, language: code)
        }
        let normalized = ClipLyrics.normalized(typed)
        var probe = clip
        probe.lyrics = normalized
        do throws(LyricRefusal) {
            return (normalized?.text ?? "", try SingPlanner.assignment(for: probe, tempoMap: store.transport.tempoMap),
                    normalized)
        } catch .noWords {
            return (normalized?.text ?? "", nil, normalized)
        } catch {
            throw Self.lyricRefusal(error)
        }
    }

    static func assignmentJSON(_ a: LyricAssignment?) -> JSONValue {
        guard let a else {
            return .object(["words": .array([]), "lines": .number(0), "phrases": .number(0),
                            "unsungNoteIds": .array([])])
        }
        return .object([
            "words": .array(a.words.map { w in
                .object([
                    "text": .string(w.word.typed),
                    "noteIds": .array(w.noteIDs.map { .string($0.uuidString) }),
                    "startBeat": .number(w.startBeat),
                    "endBeat": .number(w.endBeat),
                    "held": .bool(w.held),
                ])
            }),
            "lines": .number(Double(a.lineCount)),
            "phrases": .number(Double(a.phraseCount)),
            "unsungNoteIds": .array(a.unsungNoteIDs.map { .string($0.uuidString) }),
        ])
    }

    private static func storeRefusal(_ error: ProjectError) -> SingWireRefusal {
        switch error {
        case .clipNotFound(let id): return clipNotFound(id)
        case .clipInTakeGroup: return SingWireRefusal("clipInTakeGroup", error.errorDescription ?? "")
        default: return SingWireRefusal("lyricsNotStored", error.errorDescription ?? "\(error)")
        }
    }

    // MARK: 13. clip.getLyrics

    func getLyrics(_ params: [String: JSONValue]) throws -> JSONValue {
        let clipId = try params.requireClipID()
        let (_, clip) = try locate(clipId)
        var reply: [String: JSONValue] = [
            "clipId": .string(clipId.uuidString),
            "text": .string(clip.lyrics?.text ?? ""),
            "assignment": Self.assignmentJSON(nil),
            "warnings": .array([]),
            "problem": .null,
        ]
        // p2-sing-x7 (design 2026-10-06 §6.9): the clip's language, ONLY when it has one. English is stored as no
        // code, so an English clip's reply is the base reply exactly (S6).
        if let language = clip.lyrics?.language { reply["language"] = .string(language) }
        guard clip.isMIDI, clip.lyrics != nil else { return .object(reply) }
        do throws(LyricRefusal) {
            let assignment = try SingPlanner.assignment(for: clip, tempoMap: store.transport.tempoMap)
            reply["assignment"] = Self.assignmentJSON(assignment)
            reply["warnings"] = .array(assignment.warnings.map { .string($0.sentence) })
        } catch {
            // The stored words no longer fit the notes (the notes changed since): reported, never thrown.
            let wrapped = SingJobError.planRefused(.lyrics(error))
            reply["problem"] = .object(["code": .string(wrapped.code),
                                        "sentence": .string(wrapped.errorDescription ?? error.sentence)])
        }
        return .object(reply)
    }

    // MARK: 14. sing.render

    func render(_ params: [String: JSONValue]) async throws -> JSONValue {
        let clipId = try params.requireClipID()
        let auto: Bool
        var octaveShift = 0
        switch params["octaveShift"] {
        case nil, .some(.string("auto")):
            auto = true
        case .some(.number(let n)):
            guard n.rounded() == n, let whole = Int(exactly: n), SingPlanner.octaveShiftRange.contains(whole) else {
                throw Self.octaveInvalid(Int(exactly: n.rounded()) ?? 0)
            }
            auto = false
            octaveShift = whole
        default:
            throw Self.octaveInvalid(0)
        }
        var seed: UInt64?
        if let raw = params["seed"] {
            guard let n = raw.doubleValue, n >= 0, n.rounded() == n, n < 9_007_199_254_740_992 else {
                // PROVISIONAL code and sentence (§6 names no seed refusal).
                throw SingWireRefusal("singSeedInvalid", "seed must be a whole number from 0 to 9007199254740991.")
            }
            seed = UInt64(n)
        }
        var trackName: String?
        if let raw = params["trackName"] {
            guard let value = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { throw ControlError("'trackName' must be a non-empty string") }
            trackName = value
        }
        let newLyrics = try Self.optionalString(params, "lyrics")
        let dryRun = try Self.optionalBool(params, "dryRun") ?? false
        // p2-sing-x7b (design 2026-10-06 §4.7): `parts` (at most 3) and `key`/`mode`, the key they are counted in.
        // Absent (or `parts: []`), the request, the plan and the reply are exactly the base verb's (§9.2 S6).
        let partParams = try Self.renderParts(params)
        let key = try Self.renderKey(params, hasParts: partParams != nil)

        guard let found = Self.find(clipId, in: store.tracks) else {
            let error = SingJobError.clipNotFound(clipId)
            throw SingWireRefusal(error.code, error.errorDescription ?? "")
        }
        let (track, clip) = found
        let (voice, range) = try resolveVoice(try Self.optionalString(params, "voiceId"))

        // The planner's clip-level refusals first, in its order (audio, no notes, drums), so a clip that cannot be
        // sung at all says so rather than counting the new words against notes it does not have.
        if clip.isMIDI {
            if SingPlanner.melody(of: clip).notes.isEmpty { throw Self.planRefusal(.noNotes) }
            if ProjectTranspose.isDrumTrack(track) { throw Self.planRefusal(.drumTrack) }
        }

        // The plan, over the lyrics the take will sing: the new ones when given (checked BEFORE anything is
        // stored, the same checks clip.setLyrics makes), else the clip's own.
        var probe = clip
        var newText: String?
        var checkedLyrics: ClipLyrics??
        if let newLyrics {
            let (normalized, _, checked) = try validatedLyrics(newLyrics, on: clip, language: .keep, codes: .render)
            probe.lyrics = checked
            checkedLyrics = .some(checked)
            newText = normalized
        }
        var choiceSentence: String?
        if auto, probe.isMIDI {
            let melody = Self.melodyForFit(probe, tempoMap: store.transport.tempoMap)
            if let proposal = VoiceRangeFit.propose(melody: melody, voice: range) {
                octaveShift = proposal.bestOctaveOnly.octaveShift
                choiceSentence = proposal.kind == .octave ? proposal.sentence : proposal.alternativeSentence
            }
        }
        let plan: SingPlan
        do throws(SingPlanRefusal) {
            plan = try SingPlanner.plan(clip: probe, on: track, tempoMap: store.transport.tempoMap,
                                        meterMap: store.transport.meterMap, octaveShift: octaveShift)
        } catch {
            throw Self.planRefusal(error)
        }

        // The parts, as X6's `SingJobPart`s: what can be checked without planning is refused here, before anything
        // is stored; the coordinator plans them (and refuses the rest) at submit.
        let jobParts = try partParams.map { try singJobParts($0, melodyClipID: clipId, key: key) } ?? []
        let request = SingJobRequest(
            clipID: clipId, octaveShift: octaveShift, voice: voice, seed: seed, trackName: trackName,
            fromAgent: true, parts: jobParts, key: key)
        let wordsChange = newLyrics != nil && newText != (clip.lyrics?.text ?? "")

        var engineState: SingingSidecarStatus?
        if let services { engineState = await services.engine.status() }
        let summary = planJSON(plan, voice: voice, auto: auto, choiceSentence: choiceSentence, engine: engineState)
        if dryRun {
            var shown = summary
            if partParams != nil, case .object(var fields) = summary {
                // The parts over the words the take would sing: the new ones when given (nothing is stored), through
                // the coordinator's own planner.
                let preview: SingJobCoordinator.PlanPreview
                do {
                    preview = try await requireServices("sing.render").jobs.plan(request, lyrics: checkedLyrics)
                } catch let error as SingJobError {
                    throw SingWireRefusal(error.code, error.errorDescription ?? "\(error)")
                }
                fields["parts"] = .array((preview.parts ?? []).map(Self.planPartJSON))
                shown = .object(fields)
            }
            return .object(["dryRun": .bool(true), "plan": shown])
        }

        let s = try requireServices("sing.render")
        // Refused before the lyrics are stored, so a refusal changes nothing (the coordinator checks again).
        if let engineState {
            switch engineState.state {
            case .notInstalled:
                throw SingWireRefusal("singEngineNotInstalled", engineState.message)
            case .needsUpdate:
                throw SingWireRefusal("singEngineNeedsUpdate", engineState.message)
            default: break
            }
        }
        // With parts and new words, the coordinator plans over the NEW words first, so every planning refusal is thrown
        // with nothing stored (p2-sing-x7d). Nothing is rolled back: a refusal here has changed nothing at all.
        if partParams != nil, wordsChange {
            do {
                _ = try await s.jobs.plan(request, lyrics: checkedLyrics)
            } catch let error as SingJobError {
                throw SingWireRefusal(error.code, error.errorDescription ?? "\(error)")
            }
        }
        if let newLyrics, wordsChange {
            do {
                try lyrics.setClipLyrics(clipId: clipId, text: newLyrics, undoLabel: Self.setLyricsUndoLabel)
            } catch let error as ProjectError {
                throw Self.storeRefusal(error)
            }
        }
        let status: SingJobStatus
        do {
            status = try await s.jobs.submit(request)
        } catch let error as SingJobError {
            // Planning already passed over these words (above), so what is left are the refusals `plan` cannot foresee:
            // the engine, the queue (see the report on p2-sing-x7d). The new words stay saved, as for a request
            // without parts: they are one undo step.
            throw SingWireRefusal(error.code, error.errorDescription ?? "\(error)")
        }
        onJobSubmitted?(status, SingPresenceBridge.label(voiceName: voice.name))
        var reply = summary
        if partParams != nil, case .object(var fields) = summary {
            // Only when `parts` was sent (§4.7): the coordinator's plan of every line, the lead first.
            fields["parts"] = .array((status.parts ?? []).map(Self.planPartJSON))
            reply = .object(fields)
        }
        return .object(["jobId": .string(status.jobID), "plan": reply, "status": Self.jobJSON(status)])
    }

    /// A planner refusal in the coordinator's codes and words (`SingJobError.planRefused`), so the wire and the
    /// job read the same.
    static func planRefusal(_ refusal: SingPlanRefusal) -> SingWireRefusal {
        let wrapped = SingJobError.planRefused(refusal)
        return SingWireRefusal(wrapped.code, wrapped.errorDescription ?? refusal.sentence)
    }

    static func octaveInvalid(_ n: Int) -> SingWireRefusal {
        let error = SingJobError.planRefused(.octaveShiftInvalid(n))
        return SingWireRefusal(error.code, error.errorDescription ?? "")
    }

    private func planJSON(_ plan: SingPlan, voice: SingJobVoice, auto: Bool, choiceSentence: String?,
                          engine: SingingSidecarStatus?) -> JSONValue {
        let config = SingJobCoordinator.Configuration()
        let audioSeconds = plan.units.reduce(0) {
            $0 + $1.spanSeconds + SingPlanner.leadSeconds + SingPlanner.trailSeconds
        }
        let cold = engine?.state == .healthy ? 0 : config.coldStartSeconds
        var engineJSON: JSONValue = .null
        if let engine {
            engineJSON = .object([
                "state": .string(Self.wireState(engine.state)),
                "needsInstall": .bool(engine.state == .notInstalled || engine.state == .needsUpdate),
                "needsStart": .bool(engine.state != .healthy),
            ])
        }
        return .object([
            "clipId": .string(plan.clipID.uuidString),
            "voice": .object(["id": .string(voice.id), "name": .string(voice.name)]),
            "octaveShift": .number(Double(plan.octaveShift)),
            "octaveChoice": .object(["auto": .bool(auto), "octaveShift": .number(Double(plan.octaveShift)),
                                     "sentence": Self.string(choiceSentence)]),
            "units": .array(plan.units.enumerated().map { i, unit in
                .object([
                    "index": .number(Double(i + 1)),
                    "onsetSeconds": .number(unit.onsetSeconds),
                    "spanSeconds": .number(unit.spanSeconds),
                    "notes": .number(Double(unit.notes.count)),
                    "words": .array(unit.words.map { .string($0.typed) }),
                    "sung": .array(unit.words.map { .string($0.text) }),
                ])
            }),
            "assignment": Self.assignmentJSON(plan.assignment),
            "warnings": .array(plan.warnings.map { .string($0.sentence) }),
            "estimatedSeconds": .number((cold + audioSeconds * config.warmRealTimeFactor).rounded()),
            "engine": engineJSON,
        ])
    }

    // MARK: 15. sing.jobStatus

    func jobStatus(_ params: [String: JSONValue]) async throws -> JSONValue {
        let jobID = try Self.optionalString(params, "jobId")
        let s = try requireServices("sing.jobStatus")
        guard let jobID else {
            let recent = await s.jobs.statuses(limit: Self.recentJobs)
            return .object(["jobs": .array(recent.map(Self.jobJSON))])
        }
        do {
            return Self.jobJSON(try await s.jobs.status(jobID: jobID))
        } catch let error as SingJobError {
            throw SingWireRefusal(error.code, error.errorDescription ?? "\(error)")
        }
    }

    // MARK: 16. sing.cancelJob

    func cancelJob(_ params: [String: JSONValue]) async throws -> JSONValue {
        let jobID = try params.require("jobId", \.stringValue)
        let s = try requireServices("sing.cancelJob")
        do {
            let status = try await s.jobs.cancel(jobID: jobID)
            return .object(["cancelRequested": .bool(true), "jobId": .string(jobID), "status": Self.jobJSON(status)])
        } catch let error as SingJobError {
            throw SingWireRefusal(error.code, error.errorDescription ?? "\(error)")
        }
    }

    /// The coarse state an agent polls on: `queued`, `running`, `landed` (in the song, checks running), `done`,
    /// `failed` or `cancelled`. `phase` carries the detail.
    static func coarseState(_ phase: SingJobPhase) -> String {
        switch phase {
        case .queued: return "queued"
        case .waitingForModel, .startingEngine, .preparingVoice, .singing, .finishing: return "running"
        case .landed, .checking: return "landed"
        case .done: return "done"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        }
    }

    /// One job's reply. A job with parts (p2-sing-x7b) also has `parts`, one entry per line, the lead first; then
    /// `result` (and its word check) is the LEAD's take when the lead landed, else the FIRST landed part's (X6's
    /// rule, W8-RV6 N8), so a caller reads `parts[].role` to know whose it is. A job without parts has no `parts` key.
    static func jobJSON(_ s: SingJobStatus) -> JSONValue {
        var result: JSONValue = .null
        if let r = s.result {
            result = .object([
                "trackId": .string(r.trackID.uuidString),
                "clipId": .string(r.clipID.uuidString),
                "loudness": (try? r.loudness.map { try JSONValue(encoding: $0) }) ?? .null,
                "noteAccuracy": (try? r.noteAccuracy.map { try JSONValue(encoding: $0) }) ?? .null,
                "wordCheck": r.wordCheck.map(wordCheckJSON) ?? .null,
                "gates": (try? JSONValue(encoding: r.gates)) ?? .null,
                "melodyChanged": .bool(r.melodyChanged),
                "transposedSemitones": .number(Double(r.transposedSemitones)),
            ])
        }
        var error: JSONValue = .null
        if let e = s.error {
            error = .object(["code": .string(e.code), "message": .string(e.message), "detail": string(e.detail)])
        }
        var fields: [String: JSONValue] = [
            "jobId": .string(s.jobID),
            "clipId": .string(s.clipID.uuidString),
            "state": .string(coarseState(s.phase)),
            "phase": .string(s.phase.rawValue),
            "stageText": .string(s.stageText),
            "unit": .object(["index": number(s.unitIndex.map(Double.init)), "count": .number(Double(s.unitCount))]),
            "progress": .number(s.progress),
            "etaSeconds": number(s.etaSeconds),
            "waitingFor": string(s.waitingFor),
            "cancelRequested": .bool(s.cancelRequested),
            "seed": .number(Double(s.seed)),
            "warnings": .array(s.warnings.map(JSONValue.string)),
            "notices": .array(s.notices.map(JSONValue.string)),
            "retriedUnits": .array(s.retriedUnits.map { .number(Double($0)) }),
            "cachedUnits": .number(Double(s.cachedUnits)),
            "renderedUnits": .number(Double(s.renderedUnits)),
            "yields": .number(Double(s.yields)),
            "engineRestarts": .number(Double(s.engineRestarts)),
            "result": result,
            "gates": (try? s.gates.map { try JSONValue(encoding: $0) }) ?? .null,
            "error": error,
            "keptTakePath": string(s.keptTakePath),
            "fromAgent": .bool(s.fromAgent),
            "submittedAt": .string(iso8601(s.submittedAt)),
            "finishedAt": string(s.finishedAt.map(iso8601)),
        ]
        if let parts = s.parts { fields["parts"] = .array(parts.map(jobPartJSON)) }
        return .object(fields)
    }

    // MARK: 17. project.transpose

    func transpose(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let raw = params["semitones"]?.doubleValue else {
            throw ControlError("missing or invalid required param 'semitones' (a whole number from -12 to 12)")
        }
        var excluded = Set<UUID>()
        if let list = params["excludeTrackIds"] {
            guard let items = list.arrayValue else {
                throw ControlError("'excludeTrackIds' must be a list of track ids")
            }
            for item in items {
                guard let text = item.stringValue, let id = UUID(uuidString: text) else {
                    throw ControlError("'excludeTrackIds' holds something that is not a track id: \(item)")
                }
                excluded.insert(id)
            }
        }
        let dryRun = try Self.optionalBool(params, "dryRun") ?? false
        do {
            let semitones = try ProjectTranspose.validatedSemitones(raw)
            let report = try transposer.transposeProject(semitones: semitones, excludeTrackIds: excluded,
                                                         dryRun: dryRun)
            return try JSONValue(encoding: report)
        } catch let refusal as TransposeRefusal {
            throw SingWireRefusal(refusal.code.rawValue, refusal.message)
        } catch ProjectError.trackNotFound(let id) {
            throw SingWireRefusal("trackNotFound", ProjectError.trackNotFound(id).errorDescription ?? "")
        }
    }

    // MARK: - Shared helpers

    private func locate(_ clipId: UUID) throws -> (Track, Clip) {
        guard let found = Self.find(clipId, in: store.tracks) else { throw Self.clipNotFound(clipId) }
        return found
    }

    static func find(_ clipId: UUID, in tracks: [Track]) -> (Track, Clip)? {
        for track in tracks {
            if let clip = track.clips.first(where: { $0.id == clipId }) { return (track, clip) }
        }
        return nil
    }

    static func clipNotFound(_ id: UUID) -> SingWireRefusal {
        SingWireRefusal("clipNotFound", ProjectError.clipNotFound(id).errorDescription ?? "no clip with id \(id)")
    }

    static func optionalBool(_ params: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let raw = params[key] else { return nil }
        guard let value = raw.boolValue else { throw ControlError("'\(key)' must be true or false") }
        return value
    }

    static func optionalString(_ params: [String: JSONValue], _ key: String) throws -> String? {
        guard let raw = params[key] else { return nil }
        guard let value = raw.stringValue else { throw ControlError("'\(key)' must be a string") }
        return value
    }

    static func number(_ value: Double?) -> JSONValue { value.map(JSONValue.number) ?? .null }
    static func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}

// MARK: - p2-sing-x7: the expansion's verbs (design `docs/design/2026-10-06-p2-sing-expansion.md`)
//
// clip.setNoteWord (§3.4), clip.setSingStyle / clip.getSingStyle (§5.6), sing.proposeHarmony (§4.7) and
// sing.capabilities (§6.9), plus the helpers clip.setLyrics' new `language` / `wordless` params use (§6.9, §8.1).
// Each verb reaches the SAME store method the Sing sheet will (`setNoteWord`, `setClipLyrics(…language:…)`,
// `setSingStyle`) through a protocol a spy test can stand in front of. Sentences with a design row are VERBATIM;
// every other one is marked PROVISIONAL where it is written.

extension SingWireHandlers {

    // MARK: clip.setLyrics' new params

    /// `language` absent keeps the clip's language (the store's text-only write); present sets it.
    enum LyricLanguageChoice: Equatable {
        case keep
        case set(String)
    }

    static func lyricLanguage(_ params: [String: JSONValue]) throws -> LyricLanguageChoice {
        guard let raw = params["language"] else { return .keep }
        guard let code = raw.stringValue else {
            throw ControlError("'language' must be a string: \"en\" (English), \"zh\" (Chinese, Mandarin) or "
                                   + "\"yue\" (Chinese, Cantonese)")
        }
        return .set(code)
    }

    /// `wordless` + `wordlessPerNote?` (design §8.1), nil when `wordless` is absent. Refuses `wordless` with `text`,
    /// `wordlessPerNote` without `wordless`, and a sound that is not one of the three.
    static func wordlessChoice(_ params: [String: JSONValue]) throws -> (sound: WordlessLyrics.Sound, perNote: Bool)? {
        let perNote = try optionalBool(params, "wordlessPerNote")
        guard let raw = params["wordless"] else {
            if perNote != nil {
                // PROVISIONAL code and sentence.
                throw SingWireRefusal("lyricsWordlessPerNoteAlone",
                                      "wordlessPerNote goes with wordless: send wordless too (ooh, aah or mm).")
            }
            return nil
        }
        if params["text"] != nil {
            // PROVISIONAL code and sentence (§8.1: "mutually exclusive with text; refused together").
            throw SingWireRefusal("lyricsWordlessWithText",
                                  "Send either text or wordless, not both: wordless writes the words for you.")
        }
        guard let name = raw.stringValue, let sound = WordlessLyrics.Sound(rawValue: name) else {
            // PROVISIONAL code and sentence.
            throw SingWireRefusal("lyricsWordlessInvalid", "wordless can be ooh, aah or mm.")
        }
        return (sound, perNote ?? false)
    }

    /// The text a `wordless` request writes on `clip` (`WordlessLyrics`, the one generator). A melody clip with no
    /// notes has nothing to sing on: refused, never turned into a blank text that would clear the lyrics.
    static func wordlessText(_ choice: (sound: WordlessLyrics.Sound, perNote: Bool), clip: Clip) throws -> String {
        let text = WordlessLyrics.text(for: clip, sound: choice.sound, perNote: choice.perNote)
        if text.isEmpty, clip.isMIDI { throw planRefusal(.noNotes) }
        return text
    }

    /// An assigner refusal in the coordinator's codes and words (`SingJobError.planRefused(.lyrics)`), the codes
    /// `lyricsScriptMismatch` / `lyricsLanguageUnsupported` included.
    static func lyricRefusal(_ refusal: LyricRefusal) -> SingWireRefusal {
        let wrapped = SingJobError.planRefused(.lyrics(refusal))
        return SingWireRefusal(wrapped.code, wrapped.errorDescription ?? refusal.sentence)
    }

    /// A lyrics-edit refusal (`LyricTextEdit` / the store's lyrics writes) in the wire's codes (design §3.4). The
    /// sentence is always the refusal's own.
    static func lyricEditRefusal(_ refusal: LyricEditRefusal) -> SingWireRefusal {
        let code: String
        switch refusal {
        case .needsMIDIClip: code = "lyricsNeedMIDIClip"
        case .noText: code = "lyricsNoText"
        case .noteNotFound: code = "noteNotFound"
        case .noteNotSung: code = "noteNotSung"
        case .wordHasSpace: code = "lyricWordHasSpace"
        // PROVISIONAL codes: these refusals exist in `LyricTextEdit` but have no row in design §3.4.
        case .wordHasMarks: code = "lyricWordHasMarks"
        case .wordHasNoLetters: code = "lyricWordHasNoLetters"
        case .nothingToHold: code = "lyricNothingToHold"
        case .noteInsideHyphenatedWord: code = "lyricNoteInsideWord"
        case .lyrics(let inner): return lyricRefusal(inner)
        case .unstable: code = "lyricEditUnstable"
        case .tooLong: code = "lyricsTooLong"
        }
        return SingWireRefusal(code, refusal.sentence)
    }

    // MARK: clip.setNoteWord (design §3.4)

    func setNoteWord(_ params: [String: JSONValue]) throws -> JSONValue {
        let clipId = try params.requireClipID()
        let noteId = try params.requireUUID("noteId")
        guard let raw = params["word"], let word = raw.stringValue else {
            throw ControlError("missing or invalid required param 'word' (one word; \"+\" holds the word before onto "
                                   + "this note; \"\" clears the note's word)")
        }
        let dryRun = try Self.optionalBool(params, "dryRun") ?? false
        let result: LyricNoteWordResult
        do {
            result = try lyricEdits.setNoteWord(clipId: clipId, noteId: noteId, word: word, dryRun: dryRun)
        } catch let error as LyricEditRefusal {
            throw Self.lyricEditRefusal(error)
        } catch let error as ProjectError {
            throw Self.storeRefusal(error)
        }
        return .object([
            "clipId": .string(clipId.uuidString),
            "text": .string(result.text),
            "stored": .bool(result.stored),
            "changed": .bool(result.changed),
            "assignment": Self.assignmentJSON(result.assignment),
            "warnings": .array(result.assignment.warnings.map { .string($0.sentence) }),
        ])
    }

    // MARK: clip.setSingStyle / clip.getSingStyle (design §5.6)

    /// The wire's params as ONE `SingStyleEdit`. Type errors are ControlErrors naming the field; a vibrato name
    /// that is not one of the five is `singStyleVibratoInvalid`. The range, the note ids, `clear`'s rule and
    /// "nothing to change" are the STORE's checks (`setSingStyle`), so the wire and the Expression card refuse alike.
    static func singStyleEdit(_ params: [String: JSONValue]) throws -> SingStyleEdit {
        var edit = SingStyleEdit()
        if let raw = params["vibrato"] { edit.vibrato = try vibrato(raw, field: "vibrato") }
        if let raw = params["air"] { edit.air = try air(raw, field: "air") }
        edit.followVelocity = try optionalBool(params, "followVelocity")
        edit.clear = try optionalBool(params, "clear") ?? false
        if let raw = params["notes"] {
            guard let items = raw.arrayValue else {
                throw ControlError("'notes' must be a list of {noteId, vibrato?, air?}")
            }
            edit.notes = try items.enumerated().map { (i: Int, item: JSONValue) throws -> NoteSingStyleEdit in
                guard let fields = item.objectValue else {
                    throw ControlError("notes[\(i)] must be an object {noteId, vibrato?, air?}")
                }
                let unknown = fields.keys.filter { !["noteId", "vibrato", "air"].contains($0) }.sorted()
                guard unknown.isEmpty else {
                    throw ControlError("notes[\(i)]: unknown key \(unknown.map { "'\($0)'" }.joined(separator: ", ")) "
                                           + "— valid keys are 'air', 'noteId', 'vibrato'")
                }
                guard let text = fields["noteId"]?.stringValue, let id = UUID(uuidString: text) else {
                    throw ControlError("notes[\(i)].noteId must be a note id (from clip.getNotes)")
                }
                var style = NoteSingStyle()
                if let v = fields["vibrato"] { style.vibrato = try vibrato(v, field: "notes[\(i)].vibrato") }
                if let a = fields["air"] { style.air = try air(a, field: "notes[\(i)].air") }
                return NoteSingStyleEdit(noteID: id, style: style)
            }
        }
        return edit
    }

    private static func vibrato(_ raw: JSONValue, field: String) throws -> SingStyle.Vibrato {
        guard let name = raw.stringValue else {
            throw ControlError("'\(field)' must be a string: asSung, straight, gentle, normal or wide")
        }
        guard let vibrato = SingStyle.Vibrato(rawValue: name) else {
            let refusal = SingStyleRefusal.vibratoInvalid(name)
            throw SingWireRefusal(refusal.code, refusal.sentence)
        }
        return vibrato
    }

    private static func air(_ raw: JSONValue, field: String) throws -> Double {
        guard let value = raw.doubleValue else { throw ControlError("'\(field)' must be a number from 0 to 1") }
        return value
    }

    func setSingStyle(_ params: [String: JSONValue]) throws -> JSONValue {
        let clipId = try params.requireClipID()
        let edit = try Self.singStyleEdit(params)
        let result: SingStyleWriteResult
        do {
            result = try styles.setSingStyle(clipId: clipId, edit: edit)
        } catch let refusal as SingStyleRefusal {
            throw SingWireRefusal(refusal.code, refusal.sentence)
        } catch let error as ProjectError {
            switch error {
            case .clipNotFound(let id): throw Self.clipNotFound(id)
            case .clipInTakeGroup: throw SingWireRefusal("clipInTakeGroup", error.errorDescription ?? "")
            // PROVISIONAL code (no other store error is expected here).
            default: throw SingWireRefusal("singStyleNotStored", error.errorDescription ?? "\(error)")
            }
        }
        return .object([
            "clipId": .string(clipId.uuidString),
            "style": Self.styleJSON(result.style),
            "changed": .bool(result.changed),
            "orphanedNoteIds": .array(result.removedOrphanNoteIDs.map { .string($0.uuidString) }),
        ])
    }

    func getSingStyle(_ params: [String: JSONValue]) throws -> JSONValue {
        let clipId = try params.requireClipID()
        let (_, clip) = try locate(clipId)
        let orphans = clip.singStyle?.orphanedNoteIDs(in: clip.notes) ?? []
        return .object([
            "clipId": .string(clipId.uuidString),
            "style": Self.styleJSON(clip.singStyle),
            "orphanedNoteIds": .array(orphans.map { .string($0.uuidString) }),
        ])
    }

    /// A stored style as the wire shows it: null for none (sung with the defaults); otherwise every clip-wide field
    /// (null = its default: `SingStyle.defaultVibrato` "normal", no air, velocity not followed) and the per-note
    /// choices sorted by note id (a null field there follows the clip).
    static func styleJSON(_ style: SingStyle?) -> JSONValue {
        guard let style else { return .null }
        let notes = (style.notes ?? [:]).sorted { $0.key.uuidString < $1.key.uuidString }
        return .object([
            "vibrato": string(style.vibrato?.rawValue),
            "air": number(style.air),
            "followVelocity": style.followVelocity.map(JSONValue.bool) ?? .null,
            "notes": .array(notes.map { id, choice in
                .object([
                    "noteId": .string(id.uuidString),
                    "vibrato": string(choice.vibrato?.rawValue),
                    "air": number(choice.air),
                ])
            }),
        ])
    }

    // MARK: sing.proposeHarmony (design §4.7)

    /// `interval` + `direction` + `chordSource?` as ONE `HarmonySpec`. Reusable by `sing.render {parts}` (x7b).
    static func harmonySpec(_ params: [String: JSONValue]) throws -> HarmonySpec {
        let intervalName = try params.require("interval", \.stringValue)
        guard let interval = HarmonySpec.Interval(rawValue: intervalName) else {
            // PROVISIONAL sentence (§4.7 names the code only).
            throw SingWireRefusal("singHarmonyIntervalInvalid",
                                  "'\(intervalName)' isn't a harmony interval. Pick third, sixth, fifth or octave.")
        }
        let directionName = try params.require("direction", \.stringValue)
        guard let direction = HarmonySpec.Direction(rawValue: directionName) else {
            // PROVISIONAL sentence (§4.7 has no direction code; the interval's is used).
            throw SingWireRefusal("singHarmonyIntervalInvalid",
                                  "'\(directionName)' isn't a direction for a harmony. Pick above or below.")
        }
        var chordSource = HarmonySpec.ChordSource.auto
        if let raw = params["chordSource"] {
            guard let name = raw.stringValue, let parsed = HarmonySpec.ChordSource(rawValue: name) else {
                throw ControlError("'chordSource' must be one of "
                                       + HarmonySpec.ChordSource.allCases.map(\.rawValue).joined(separator: ", "))
            }
            chordSource = parsed
        }
        return HarmonySpec(interval: interval, direction: direction, chordSource: chordSource)
    }

    /// `key?` (0 = C … 11 = B) + `mode?` as a given `SongKey`, nil when `key` is absent (the planner then estimates
    /// it). `mode` defaults to major; `mode` without `key` is refused. Reusable by `sing.render {key, mode}` (x7b).
    static func givenSongKey(_ params: [String: JSONValue]) throws -> SongKey? {
        var mode = KeyMode.major
        if let raw = params["mode"] {
            guard let name = raw.stringValue, let parsed = KeyMode(rawValue: name) else {
                throw ControlError("'mode' must be major or minor")
            }
            mode = parsed
        }
        guard let raw = params["key"] else {
            if params["mode"] != nil {
                throw ControlError("'mode' needs 'key' (the key's note, 0 = C … 11 = B); omit both and the key is "
                                       + "worked out from the song")
            }
            return nil
        }
        guard let n = raw.doubleValue, n.rounded() == n, (0...11).contains(n) else {
            throw ControlError("'key' must be a whole number from 0 (C) to 11 (B)")
        }
        return SongKey(tonicPitchClass: Int(n), mode: mode, source: .given)
    }

    func proposeHarmony(_ params: [String: JSONValue]) throws -> JSONValue {
        let clipId = try params.requireClipID()
        let spec = try Self.harmonySpec(params)
        let given = try Self.givenSongKey(params)
        let voiceID = try Self.optionalString(params, "voiceId")
        let (track, clip) = try locate(clipId)
        guard clip.isMIDI else { throw SingWireRefusal("singNeedsMIDIClip", SingPlanRefusal.audioClip.sentence) }
        guard !ProjectTranspose.isDrumTrack(track) else {
            // PROVISIONAL refusal for this verb (§4.7 does not list it; sing.proposeKey's precedent).
            throw SingWireRefusal("singDrumTrack", SingPlanRefusal.drumTrack.sentence)
        }
        guard !SingPlanner.melody(of: clip).notes.isEmpty else {
            throw SingWireRefusal("singClipHasNoNotes", SingPlanRefusal.noNotes.sentence)
        }
        let (voice, range) = try resolveVoice(voiceID)
        let tempoMap = store.transport.tempoMap
        let key: SongKey
        do throws(HarmonyRefusal) {
            key = try HarmonyPlanner.resolveKey(given: given, tracks: store.tracks, tempoMap: tempoMap)
        } catch {
            throw SingWireRefusal(error.code, error.sentence)
        }
        let plan = HarmonyPlanner.derivedPart(clip: clip, on: track, tracks: store.tracks, spec: spec, key: key,
                                              partIndex: 1)
        // The lead's octave as sing.render's "auto" picks it, so the part's height is judged against the lead as it
        // will be sung.
        let leadShift = VoiceRangeFit.propose(melody: Self.melodyForFit(clip, tempoMap: tempoMap), voice: range)?
            .bestOctaveOnly.octaveShift ?? 0
        let height = HarmonyPlanner.range(of: plan, clipStartBeat: clip.startBeat, tempoMap: tempoMap, voice: range,
                                          leadOctaveShift: leadShift)
        var warnings: [JSONValue] = []
        if key.source == .estimated {
            // PROVISIONAL.
            warnings.append(.string("I worked out the key from the song's notes: \(key.name). If that's wrong, pick "
                                        + "the key (key and mode), and I'll work out the harmony again."))
        }
        if plan.foldOctaves != 0 {
            // PROVISIONAL.
            let n = abs(plan.foldOctaves)
            warnings.append(.string("Some notes would have gone past the end of the keyboard, so I moved the whole "
                                        + "part \(n) octave\(n == 1 ? "" : "s") \(plan.foldOctaves < 0 ? "down" : "up")."))
        }
        return .object([
            "clipId": .string(clipId.uuidString),
            "harmony": .object(["interval": .string(spec.interval.rawValue),
                                "direction": .string(spec.direction.rawValue),
                                "chordSource": .string(spec.chordSource.rawValue)]),
            "key": .object([
                "tonic": .number(Double(key.tonicPitchClass)),
                "mode": .string(key.mode.rawValue),
                "name": .string(key.name),
                "source": .string(key.source.rawValue),
                "confidence": .number(key.confidence),
            ]),
            "notes": .array(plan.notes.map { note in
                .object([
                    "leadNoteId": .string(note.leadNoteID.uuidString),
                    "leadPitch": .number(Double(note.leadPitch)),
                    "pitch": .number(Double(note.pitch)),
                    "rule": .string(note.rule.rawValue),
                ])
            }),
            "range": .object([
                "voiceId": .string(voice.id),
                "octaveShift": .number(Double(height.octaveShift)),
                "leadOctaveShift": .number(Double(leadShift)),
                "outOfBandSemitones": Self.number(height.fit?.outOfBandSemitones),
                "fits": .bool(height.fits),
                "sentence": Self.string(height.sentence),
            ]),
            "warnings": .array(warnings),
        ])
    }

    // MARK: sing.capabilities (design §6.9)

    /// Works with the engine down and in a session with no engine wired in (then `engine` is null). Never starts,
    /// installs or downloads anything.
    func capabilities() async -> JSONValue {
        var needsUpdate = false
        if let services { needsUpdate = await services.engine.status().state == .needsUpdate }
        let caps = SingCapabilities.read(files: services?.engineFiles, engineNeedsUpdate: needsUpdate)
        var engine: JSONValue = .null
        if let e = caps.engine {
            engine = .object([
                "installed": .bool(e.installed),
                "scriptsVersion": Self.number(e.scriptsVersion.map(Double.init)),
                "shippedScriptsVersion": Self.number(e.shippedScriptsVersion.map(Double.init)),
                "needsUpdate": .bool(e.needsUpdate),
            ])
        }
        return .object([
            "languages": .array(caps.languages.map { language in
                .object([
                    "code": .string(language.code),
                    "name": .string(language.name),
                    "status": .string(language.status),
                    "needsEngineUpdate": .bool(language.needsEngineUpdate),
                ])
            }),
            "expression": .array([
                .object(["field": .string("vibrato"), "choices": .array(caps.vibratoChoices.map(JSONValue.string))]),
                .object(["field": .string("air"), "min": .number(caps.airRange.lowerBound),
                         "max": .number(caps.airRange.upperBound)]),
                .object(["field": .string("followVelocity"), "choices": .array([.bool(false), .bool(true)])]),
            ]),
            "maxParts": .number(Double(caps.maxParts)),
            "engine": engine,
        ])
    }
}

// MARK: - p2-sing-x7 part B: sing.render {parts}, sing.jobStatus.parts, ai.writeLyrics {fitClipId, language}
//
// Design `docs/design/2026-10-06-p2-sing-expansion.md` §4.7 (`sing.render` / `sing.jobStatus` rows), §8.3, §8.4. The
// parts are X6's `SingJobPart`s, handed to the coordinator in `SingJobRequest.parts` (a spy test proves it): the wire
// parses and checks what it can WITHOUT planning, and every part's plan, octave, range line and landing is the
// coordinator's. Sentences with a design row are VERBATIM (the coordinator's own); the rest are PROVISIONAL.

extension SingWireHandlers {

    /// One `parts` entry as sent, before its voice is looked up.
    struct RenderPartParams: Equatable {
        var kind: SingJobPart.Kind
        var voiceId: String?
        var seed: UInt64?
        var trackName: String?
        var pan: Double?
        var volumeDb: Double?
    }

    /// The keys every part takes, and the ones each kind adds (§4.7's part shape).
    static let renderPartCommonKeys = ["kind", "voiceId", "seed", "trackName", "pan", "volumeDb"]
    static let renderPartKindKeys: [String: [String]] = [
        "harmony": ["interval", "direction", "chordSource"],
        "chordTones": ["interval", "chordSource"],
        "clip": ["sourceClipId"],
        "double": [],
    ]
    static let renderPartKinds = ["harmony", "chordTones", "clip", "double"]

    /// A coordinator refusal in its own code and words.
    static func jobRefusal(_ error: SingJobError) -> SingWireRefusal {
        SingWireRefusal(error.code, error.errorDescription ?? "\(error)")
    }

    /// PROVISIONAL code and sentence: a part's field the wire cannot read, named.
    static func partInvalid(_ number: Int, _ sentence: String) -> SingWireRefusal {
        SingWireRefusal(SingJobError.partInvalid(field: "", message: "").code, "Part \(number) \(sentence)")
    }

    /// `sing.render`'s `parts`: nil when absent or empty (then the verb is exactly the base one, §9.2 S6). More than
    /// `SingJobPart.maximumCount` is refused with the coordinator's own `tooManyParts`.
    static func renderParts(_ params: [String: JSONValue]) throws -> [RenderPartParams]? {
        guard let raw = params["parts"] else { return nil }
        guard let array = raw.arrayValue else {
            // PROVISIONAL.
            throw SingWireRefusal(SingJobError.partInvalid(field: "", message: "").code,
                                  "'parts' must be a list of parts, like [{\"kind\": \"harmony\", \"interval\": "
                                      + "\"third\", \"direction\": \"above\"}].")
        }
        if array.isEmpty { return nil }
        guard array.count <= SingJobPart.maximumCount else {
            throw jobRefusal(.tooManyParts(maximum: SingJobPart.maximumCount))
        }
        return try array.enumerated().map { try renderPart($1, number: $0 + 1) }
    }

    /// One part (PROVISIONAL sentences throughout: §4.7 names the code `singPartInvalid` and that it names the field).
    static func renderPart(_ raw: JSONValue, number n: Int) throws -> RenderPartParams {
        guard let fields = raw.objectValue else {
            throw partInvalid(n, "must be an object, like {\"kind\": \"double\"}.")
        }
        guard let kindName = fields["kind"]?.stringValue, let kindKeys = renderPartKindKeys[kindName] else {
            throw partInvalid(n, "needs a kind: " + listed(renderPartKinds, or: true) + ".")
        }
        let allowed = renderPartCommonKeys + kindKeys
        if let unknown = fields.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw partInvalid(n, "(\(kindName)) doesn't take '\(unknown)'. It takes: "
                                + allowed.joined(separator: ", ") + ".")
        }
        let kind: SingJobPart.Kind
        switch kindName {
        case "harmony":
            for key in ["interval", "direction"] where fields[key] == nil {
                throw partInvalid(n, key == "interval"
                    ? "(harmony) needs an interval: third, sixth, fifth or octave."
                    : "(harmony) needs a direction: above or below.")
            }
            kind = .harmony(try harmonySpec(fields))
        case "chordTones":
            // [A] "Sing the chord's other notes" (§4.1): the melody clip's second chord note from the top, filled
            // where there is none by `interval` below (default a third), snapping by `chordSource` (default auto).
            var probe: [String: JSONValue] = ["interval": fields["interval"] ?? .string("third"),
                                              "direction": .string("below")]
            probe["chordSource"] = fields["chordSource"]
            let fill = try harmonySpec(probe)
            kind = .chordTones(rank: .second, fillInterval: fill.interval, fillChordSource: fill.chordSource)
        case "clip":
            guard let text = fields["sourceClipId"]?.stringValue, let id = UUID(uuidString: text) else {
                throw partInvalid(n, "(clip) needs sourceClipId: the id of another MIDI melody clip, from "
                                    + "project.snapshot.")
            }
            kind = .clip(id)
        default:
            kind = .double
        }
        var part = RenderPartParams(kind: kind)
        if let raw = fields["voiceId"] {
            guard let id = raw.stringValue, !id.isEmpty else {
                throw partInvalid(n, "has a voiceId that isn't a voice id. Call sing.listVoices to see them.")
            }
            part.voiceId = id
        }
        if let raw = fields["seed"] {
            guard let s = raw.doubleValue, s >= 0, s.rounded() == s, s < 9_007_199_254_740_992 else {
                throw partInvalid(n, "has a seed that isn't a whole number from 0 to 9007199254740991.")
            }
            part.seed = UInt64(s)
        }
        if let raw = fields["trackName"] {
            guard let name = raw.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw partInvalid(n, "has a trackName that is empty. Give it a name, or leave it out.")
            }
            part.trackName = name
        }
        // The ranges (pan −1…1, level −60…+6 dB) are the coordinator's to judge, in its words.
        if let raw = fields["pan"] {
            guard let pan = raw.doubleValue else { throw partInvalid(n, "has a pan that isn't a number from −1 to 1.") }
            part.pan = pan
        }
        if let raw = fields["volumeDb"] {
            guard let db = raw.doubleValue else {
                throw partInvalid(n, "has a volumeDb that isn't a number of dB from −60 to +6.")
            }
            part.volumeDb = db
        }
        return part
    }

    /// `key?` + `mode?`: the key a harmony part is counted in (X7A's `givenSongKey`). They only mean something with
    /// parts, so without them they are refused rather than ignored (PROVISIONAL sentence).
    static func renderKey(_ params: [String: JSONValue], hasParts: Bool) throws -> SongKey? {
        guard params["key"] != nil || params["mode"] != nil else { return nil }
        guard hasParts else {
            throw ControlError("'key' and 'mode' set the key a harmony part is worked out in, so they go with "
                                   + "'parts'. To change the song's key, use project.transpose.")
        }
        return try givenSongKey(params)
    }

    /// The parts as X6's `SingJobPart`s, each part's voice looked up like the lead's (`voiceId` absent = the lead's
    /// voice). The checks that need no planning are made HERE, before `sing.render {lyrics}` stores anything, through
    /// the coordinator's own errors: a clip part's clip is in the song; a harmony part has a key (given, or one the
    /// song's notes make clear: the same `HarmonyPlanner.resolveKey` call over the same tracks the coordinator makes).
    /// Everything else (ranges, a double's seed, the melody named as its own part, a part's plan) is the
    /// coordinator's, at submit.
    func singJobParts(_ parts: [RenderPartParams], melodyClipID: UUID, key: SongKey?) throws -> [SingJobPart] {
        let built = try parts.map { p -> SingJobPart in
            let voice = try p.voiceId.map { try resolveVoice($0).voice }
            return SingJobPart(p.kind, voice: voice, seed: p.seed, trackName: p.trackName, pan: p.pan,
                               volumeDb: p.volumeDb)
        }
        for part in built {
            if case .clip(let id) = part.kind, id != melodyClipID, Self.find(id, in: store.tracks) == nil {
                throw Self.jobRefusal(.partClipNotFound(id))
            }
        }
        let needsKey = built.contains { part in
            if case .harmony = part.kind { return true }
            return false
        }
        if key == nil, needsKey {
            do throws(HarmonyRefusal) {
                _ = try HarmonyPlanner.resolveKey(given: nil, tracks: store.tracks, tempoMap: store.transport.tempoMap)
            } catch {
                throw Self.jobRefusal(.harmony(error))
            }
        }
        return built
    }

    /// One line of a parts job's plan (§4.7 `{role, units, octaveShift, range, warnings}`, plus its name, voice, seed
    /// and track name so two harmony parts can be told apart): the coordinator's own plan, read from `submit`'s status.
    /// `units` is how many lines (units) it sings.
    static func planPartJSON(_ p: SingJobPartStatus) -> JSONValue {
        .object([
            "role": .string(p.role),
            "name": .string(p.name),
            "units": .number(Double(p.unitCount)),
            "octaveShift": .number(Double(p.octaveShift)),
            "range": .object(["sentence": string(p.range), "fits": .bool(p.fits)]),
            "warnings": .array(p.warnings.map(JSONValue.string)),
            "voiceId": .string(p.voiceId),
            "seed": .number(Double(p.seed)),
            "trackName": .string(p.trackName),
        ])
    }

    /// One line of a parts job's status (§4.7 `{role, state, trackId?, error?}`, plus its name and landed clip).
    static func jobPartJSON(_ p: SingJobPartStatus) -> JSONValue {
        var error: JSONValue = .null
        if let e = p.error {
            error = .object(["code": .string(e.code), "message": .string(e.message), "detail": string(e.detail)])
        }
        return .object([
            "role": .string(p.role),
            "name": .string(p.name),
            "state": .string(p.state.rawValue),
            "trackId": string(p.trackID?.uuidString),
            "clipId": string(p.clipID?.uuidString),
            "error": error,
        ])
    }

    // MARK: ai.writeLyrics {fitClipId, language} (design §8.3)

    /// The melody clip to fit (nil without `fitClipId`) and the language to write in: `language` when sent (a
    /// `ClipLyrics` code; "en" is English, nil), else, with `fitClipId`, the clip's own words' language. Refuses an
    /// unsupported language with the assigner's code and words, an unknown/audio/empty clip, and `structure` with
    /// `fitClipId` (words written to fit a tune have no section tags).
    func lyricsFitTarget(_ params: [String: JSONValue]) throws -> (clip: Clip?, language: String?) {
        let choice = try Self.lyricLanguage(params)
        var asked: String?
        if case .set(let code) = choice {
            guard LyricLanguage.isSupported(code) else { throw Self.lyricRefusal(.languageUnsupported(language: code)) }
            asked = LyricLanguage.stored(code)
        }
        guard let raw = params["fitClipId"] else { return (nil, asked) }
        guard let text = raw.stringValue, let id = UUID(uuidString: text) else {
            throw ControlError("'fitClipId' must be the id of a MIDI melody clip (a UUID string), from project.snapshot")
        }
        if params["structure"] != nil {
            // PROVISIONAL.
            throw ControlError("'structure' asks for section tags, and words written to fit a tune have none (one "
                                   + "line per phrase of the melody). Leave 'structure' out with 'fitClipId'.")
        }
        let (_, clip) = try locate(id)
        guard clip.isMIDI else { throw SingWireRefusal("lyricsNeedMIDIClip", LyricEditRefusal.needsMIDIClip.sentence) }
        guard !SingPlanner.melody(of: clip).notes.isEmpty else { throw Self.planRefusal(.noNotes) }
        return (clip, choice == .keep ? clip.lyrics?.language : asked)
    }

    /// `ai.writeLyrics`' `fit`: §8.3's `{lines: [{phrase, notes, syllables, fits}], allFit}`, plus how many times the
    /// writer was asked and, when a line does not fit, §14's sentence naming the lines.
    static func lyricsFitJSON(_ outcome: LyricsFitOutcome) -> JSONValue {
        let report = outcome.report
        let misfits = report.lines.filter { !$0.fits }.map(\.phrase)
        return .object([
            "lines": .array(report.lines.map { line in
                .object([
                    "phrase": .number(Double(line.phrase)),
                    "notes": .number(Double(line.notes)),
                    "syllables": .number(Double(line.syllables)),
                    "fits": .bool(line.fits),
                ])
            }),
            "allFit": .bool(report.allFit),
            "attempts": .number(Double(outcome.attempts)),
            "sentence": report.allFit ? .null : .string(LyricsFit.Copy.notFit(lines: misfits)),
        ])
    }

    /// "a, b or c" / "a, b and c".
    static func listed(_ items: [String], or: Bool) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + (or ? " or " : " and ") + items.last!
    }
}
