import AIServices
import DAWCore
import Foundation
import Observation

// MARK: - The pure parts (nonisolated; `SingScreensTextTests`)

/// §5.4 step 3's clock: "Get ready…" (1 s of quiet for the noise check), four visual count-in beats, then singing.
public enum SingRecorderTiming {
    /// VERBATIM §5.4: "captures 1 s of quiet for the noise check".
    public static let getReadySeconds = 1.0
    /// The guide files' count-in: four clicks, one beat apart (`SingGuideLine`, `make_guides.py`).
    public static let countInBeats = SingGuideLine.guideCountInBeats
    public static var beatSeconds: Double { SingGuideLine.secondsPerBeat }
    /// The guide's silence before its first click: the guide starts this long before the count-in so its clicks
    /// land on the visual beats.
    public static let guideLeadSeconds = SingGuideLine.guideLeadSilenceSeconds
    /// VERBATIM §5.4: capture continues 0.30 s after [Stop] (the check's `GUARD_AFTER`).
    public static let guardAfterSeconds = VoiceClipCheck.guardAfter
    /// VERBATIM §5.4: "at 12 s" (the check's own longest recording). The engine adds its 3 s wall-clock backstop.
    public static let maxSeconds = VoiceClipCheck.durMax
    /// VERBATIM §5.4: stops "after 1.5 s of quiet once 3 s of singing has been heard".
    public static let quietStopSeconds = 1.5
    public static let minSingingSeconds = 3.0
    /// [A] (no design number): a reading counts as singing when it is this far above the loudest reading of the
    /// "Get ready…" second, and never below `singingFloorDbfs`.
    public static let singingMarginDb = 20.0
    public static let singingFloorDbfs = -50.0
    /// [A] The longest gap between two readings the quiet clock will count (a stalled UI must not stop a take).
    public static let maxReadingGapSeconds = 0.25

    public enum Phase: Equatable, Sendable {
        case getReady
        /// 1...4.
        case countIn(beat: Int)
        case singing
    }

    public static var singingStartsAt: Double { getReadySeconds + Double(countInBeats) * beatSeconds }

    public static func phase(atElapsed t: Double) -> Phase {
        if t < getReadySeconds { return .getReady }
        if t < singingStartsAt {
            return .countIn(beat: min(countInBeats, Int((t - getReadySeconds) / beatSeconds) + 1))
        }
        return .singing
    }

    /// With headphones, the guide starts here (its first click then lands on beat 1).
    public static var guideStartsAt: Double { getReadySeconds - guideLeadSeconds }
}

/// §5.4's automatic stop: "after 1.5 s of quiet once 3 s of singing has been heard". Fed the engine's peak meter
/// (`inputOnlyCapturePeakDbfs`) at UI rate; the "Get ready…" second sets the room's floor.
public struct SingQuietAutoStop: Equatable, Sendable {
    public private(set) var floorDbfs: Double?
    public private(set) var singingSeconds = 0.0
    public private(set) var quietRunSeconds = 0.0
    private var lastElapsed: Double?

    public init() {}

    public var thresholdDbfs: Double {
        max((floorDbfs ?? -120) + SingRecorderTiming.singingMarginDb, SingRecorderTiming.singingFloorDbfs)
    }

    /// One reading. True when the recording should stop now.
    public mutating func observe(elapsed: Double, peakDbfs: Double) -> Bool {
        let dt = lastElapsed.map { min(max(0, elapsed - $0), SingRecorderTiming.maxReadingGapSeconds) } ?? 0
        lastElapsed = elapsed
        switch SingRecorderTiming.phase(atElapsed: elapsed) {
        case .getReady:
            floorDbfs = max(floorDbfs ?? -120, peakDbfs)
            return false
        case .countIn:
            return false
        case .singing:
            if peakDbfs >= thresholdDbfs {
                singingSeconds += dt
                quietRunSeconds = 0
            } else {
                quietRunSeconds += dt
            }
            return singingSeconds >= SingRecorderTiming.minSingingSeconds
                && quietRunSeconds >= SingRecorderTiming.quietStopSeconds
        }
    }
}

// MARK: - The recorder (§5.4)

/// "Add your voice": pick a tune, say whether you wear headphones, record, check, name, save. A human act: an agent
/// can OPEN it (`sing.openVoiceRecorder`), only the person presses Record.
///
/// Rules this type keeps (W8-RT1's notes for this UI):
/// - Opening it stops playback, and Record stops it again, so the song never plays into the microphone. Playback
///   starting DURING a recording (a key, an agent's `transport.play`) cancels the recording.
/// - Microphone permission is asked before the first capture, never by the engine.
/// - A fresh file per attempt (a retry at the same path can be refused while the old delete is pending).
/// - A project swap ends a running capture (RT review F5: the engine does not; the recorder must).
/// - While it is open the project's own Record is refused AT THE STORE (p2-sing-f2): every change of `step` writes
///   `projectRecordRefusal` into `SingRecorderTransport.voiceRecorderOpenReason`, which `ProjectStore.record()` and
///   every layer take check first, so `transport.record`, the transport's button and any key meet one sentence.
///   It follows the CARD, not the project: the recorder outlives a project swap, so the new project's Record stays
///   refused until the card closes. Also: the scrim covers the transport's button, this recorder's `record()`
///   refuses while a take records (`takeIsRecording`), and the engine refuses a take while a capture runs (RTFIX F2).
/// - Save is `SingVoicePreparation.prepare`, the function `sing.addVoice` runs.
@MainActor
@Observable
public final class SingVoiceRecorderModel {

    public enum Step: Equatable, Sendable {
        case closed
        /// Steps 1 and 2: pick the tune, answer the headphones question.
        case choose
        /// The macOS microphone prompt is up (§5.7 "Mic permission").
        case askingPermission
        /// §5.7 "Mic denied".
        case permissionDenied
        /// No headphones: the tune plays first.
        case listening
        /// [Record] is ready.
        case ready
        /// Capturing: get ready, count-in, singing (`SingRecorderTiming.phase`).
        case recording
        /// [Stop] or the automatic stop: 0.30 s more, then the capture ends.
        case finishing
        /// The check (~2 s).
        case checking
        /// "Got it!" [▶ Listen] Name: [My voice] [Save].
        case passed
        /// One sentence and [Record again].
        case failed(String)
        case saving
        /// §5.7 "Voice saved".
        case saved(String)
    }

    private let capture: any SingVoiceCapturing
    private let transport: any SingRecorderTransport
    private let player: any SingAudioPreviewing
    private let saver: any SingVoiceSaving
    private let recordingsDirectory: URL
    private let guideURL: @MainActor (SingGuideLine.Guide) -> URL?
    private let now: @MainActor () -> Double
    private let startsDriver: Bool

    /// Told when a voice was saved (the sheet selects it).
    public var onSaved: (@MainActor (SingSavedVoice) -> Void)?

    public private(set) var step = Step.closed {
        // p2-sing-f2: the song's store follows the card on EVERY transition (open, close, save, a swap's abort,
        // the debug staging) by construction, not per close path.
        didSet { syncProjectRecordRefusal() }
    }
    public private(set) var openedByAgent = false
    public private(set) var guide = SingGuideLine.Guide.high
    public private(set) var wearsHeadphones: Bool?
    /// Seconds since the capture started (the count-in and the meter read it).
    public private(set) var elapsed = 0.0
    /// The live input level, dBFS (nil when nothing is capturing).
    public private(set) var levelDbfs: Double?
    /// A refusal or an error in its own words, under the buttons (the engine's, the player's, the saver's).
    public private(set) var notice: String?
    /// The range the check measured (the passed card's evidence).
    public private(set) var checkedRange: VoiceRange?
    public private(set) var savedVoice: SingSavedVoice?
    /// The file being checked or saved.
    public private(set) var recordingURL: URL?
    /// The guide or recording playing now.
    public private(set) var playing: URL?
    public var name = SingVoicePreparation.defaultName

    private var attempt = 0
    private var openGeneration: UInt64 = 0
    private var captureStartedAt: Double?
    private var stopRequestedAt: Double?
    private var autoStop = SingQuietAutoStop()
    private var guideStarted = false
    private var driverAlive = false
    private var source = SingVoiceRecord.Source.recorder
    /// True for a file this recorder created (deleted when not kept); false for the person's own file.
    private var ownsRecording = false

    public init(capture: any SingVoiceCapturing, transport: any SingRecorderTransport,
                player: any SingAudioPreviewing, saver: any SingVoiceSaving,
                recordingsDirectory: URL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("DAWPro-voice-recorder", isDirectory: true),
                guideURL: @escaping @MainActor (SingGuideLine.Guide) -> URL? = { SingGuideLine.url(for: $0) },
                now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
                startsDriver: Bool = true) {
        self.capture = capture
        self.transport = transport
        self.player = player
        self.saver = saver
        self.recordingsDirectory = recordingsDirectory
        self.guideURL = guideURL
        self.now = now
        self.startsDriver = startsDriver
    }

    public var isOpen: Bool { step != .closed }

    /// The sentence for refusing the project's own Record while this is open (nil when closed). Registered with
    /// the song's store on every step change (`syncProjectRecordRefusal`); echoed by `debug.singScreens`.
    public var projectRecordRefusal: String? { isOpen ? SingCopy.recorderIsOpen : nil }

    /// Writes `projectRecordRefusal` into the song's store when it differs (an unchanged write would still tell
    /// every observer of the store that it changed).
    private func syncProjectRecordRefusal() {
        let reason = projectRecordRefusal
        if transport.voiceRecorderOpenReason != reason { transport.voiceRecorderOpenReason = reason }
    }

    /// Where the capture is: get ready, which count-in beat, or singing.
    public var recordingPhase: SingRecorderTiming.Phase? {
        switch step {
        case .recording, .finishing: return SingRecorderTiming.phase(atElapsed: elapsed)
        default: return nil
        }
    }

    // MARK: Open / close

    /// Opens on step 1. Stops playback FIRST (§5.4: "Opening the recorder stops playback").
    public func open(fromAgent: Bool) {
        if transport.isTransportPlaying { transport.stopTransport() }
        openedByAgent = fromAgent
        guard step == .closed else { return }
        openGeneration = transport.projectGeneration
        notice = nil
        name = SingVoicePreparation.defaultName
        wearsHeadphones = nil
        checkedRange = nil
        savedVoice = nil
        step = .choose
    }

    /// Closes: a running capture is cancelled (its file deleted by the engine), anything playing stops, and an
    /// unsaved recording this recorder made is deleted.
    public func close() {
        if step == .recording || step == .finishing {
            attempt += 1   // the cancelled completion is no longer ours
            capture.cancelInputOnlyCapture()
        }
        stopDriver()
        stopPlaying()
        discardUnsavedRecording()
        step = .closed
        notice = nil
    }

    // MARK: Steps 1 and 2

    /// [▶ Higher] / [▶ Lower]: picks the tune and plays it.
    public func pickAndPlay(_ guide: SingGuideLine.Guide) {
        self.guide = guide
        notice = nil
        play(guideFile: guide, onFinish: nil)
    }

    /// The headphones answer, then the microphone permission (asked here if needed, §5.4 step 2).
    public func answerHeadphones(_ wearing: Bool) {
        guard step == .choose || step == .permissionDenied else { return }
        wearsHeadphones = wearing
        notice = nil
        stopPlaying()
        switch capture.recordPermission {
        case .granted:
            afterPermission()
        case .denied:
            step = .permissionDenied
        case .undetermined:
            step = .askingPermission
            capture.requestRecordPermission { [weak self] granted in
                guard let self, self.step == .askingPermission else { return }
                if granted { self.afterPermission() } else { self.step = .permissionDenied }
            }
        }
    }

    private func afterPermission() {
        if wearsHeadphones == false {
            step = .listening
            let played = play(guideFile: guide) { [weak self] in
                guard let self, self.step == .listening else { return }
                self.step = .ready
            }
            if !played { step = .ready }
        } else {
            step = .ready
        }
    }

    // MARK: Step 3: record

    /// [Record] / [Record again].
    public func record() {
        switch step {
        case .ready, .failed, .passed: break
        default: return
        }
        notice = nil
        if transport.projectGeneration != openGeneration { openGeneration = transport.projectGeneration }
        guard !transport.isTransportRecording else {
            notice = SingCopy.takeIsRecording
            return
        }
        // STOP PLAYBACK FIRST, again: something may have started it since the recorder opened.
        if transport.isTransportPlaying { transport.stopTransport() }
        stopPlaying()
        discardUnsavedRecording()
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        } catch {
            notice = Self.words(error)
            return
        }
        let url = recordingsDirectory.appendingPathComponent("voice-\(UUID().uuidString.lowercased()).wav")
        attempt += 1
        let mine = attempt
        do {
            try capture.startInputOnlyCapture(to: url, maxSeconds: SingRecorderTiming.maxSeconds) { [weak self] in
                self?.captureEnded($0, attempt: mine)
            }
        } catch {
            notice = Self.words(error)
            step = .ready
            return
        }
        source = .recorder
        ownsRecording = true
        recordingURL = url
        checkedRange = nil
        captureStartedAt = now()
        stopRequestedAt = nil
        elapsed = 0
        levelDbfs = nil
        autoStop = SingQuietAutoStop()
        guideStarted = false
        step = .recording
        startDriver()
    }

    /// [Stop]: 0.30 s more capture, then the end (a quick click never trips the check's `cut_end`).
    public func stop() {
        guard step == .recording else { return }
        stopRequestedAt = now()
        step = .finishing
    }

    /// One UI-rate reading (the driver calls it ~30 times a second; a test calls it directly).
    public func tick() {
        guard step == .recording || step == .finishing, let start = captureStartedAt else { return }
        let t = now()
        elapsed = t - start
        // A project swap ends the capture (F5), and so does the song starting to play into the microphone.
        if transport.projectGeneration != openGeneration {
            abortCapture(SingCopy.projectChanged)
            openGeneration = transport.projectGeneration
            return
        }
        if transport.isTransportPlaying {
            abortCapture(SingCopy.playbackInterrupted)
            return
        }
        levelDbfs = capture.inputOnlyCapturePeakDbfs()
        if wearsHeadphones == true, !guideStarted, elapsed >= SingRecorderTiming.guideStartsAt {
            guideStarted = true
            play(guideFile: guide, onFinish: nil)
        }
        if step == .recording, let level = levelDbfs, autoStop.observe(elapsed: elapsed, peakDbfs: level) {
            stop()
        }
        if step == .finishing, let asked = stopRequestedAt, t - asked >= SingRecorderTiming.guardAfterSeconds {
            stopRequestedAt = nil
            capture.stopInputOnlyCapture()
        }
    }

    private func captureEnded(_ outcome: InputOnlyCaptureOutcome, attempt ended: Int) {
        guard ended == attempt else {
            // A capture this recorder already let go of: its file is not wanted.
            if case .recorded(let recording) = outcome { Self.remove(recording.fileURL) }
            return
        }
        stopDriver()
        stopPlaying()
        levelDbfs = nil
        captureStartedAt = nil
        switch outcome {
        case .recorded(let recording):
            recordingURL = recording.fileURL
            runCheck()
        case .cancelled:
            step = .failed(SingCopy.recordingStopped)
        case .failed(let reason):
            step = .failed(reason)
        }
    }

    private func abortCapture(_ sentence: String) {
        attempt += 1
        capture.cancelInputOnlyCapture()
        stopDriver()
        stopPlaying()
        levelDbfs = nil
        captureStartedAt = nil
        recordingURL = nil   // the engine deletes a cancelled capture's file
        ownsRecording = false
        step = .failed(sentence)
    }

    // MARK: Step 4: the check, then Save

    /// "Use a recording you already have… [Choose file]": the same check and save, on the person's own file
    /// (never deleted here).
    public func useExistingRecording(_ url: URL) {
        guard isOpen, step != .recording, step != .finishing else { return }
        stopPlaying()
        discardUnsavedRecording()
        source = .file
        ownsRecording = false
        recordingURL = url
        notice = nil
        attempt += 1
        runCheck()
    }

    private func runCheck() {
        guard let url = recordingURL else { return }
        step = .checking
        let mine = attempt
        let kind = source
        Task { [weak self, saver] in
            do {
                let range = try await saver.check(recording: url, kind: kind)
                guard let self, self.attempt == mine, self.step == .checking else { return }
                self.checkedRange = range
                self.step = .passed
            } catch {
                guard let self, self.attempt == mine, self.step == .checking else { return }
                self.step = .failed(Self.words(error))
            }
        }
    }

    /// [▶ Listen]: the recording back.
    public func listen() {
        guard let url = recordingURL else { return }
        if playing == url {
            stopPlaying()
            return
        }
        play(url, onFinish: nil)
    }

    /// [Save]: `SingVoicePreparation.prepare` into the voice library under the name (what `sing.addVoice` runs).
    public func save() async {
        guard step == .passed, let url = recordingURL else { return }
        stopPlaying()
        notice = nil
        step = .saving
        let saved: SingSavedVoice
        do {
            saved = try await saver.save(recording: url, name: name, kind: source)
        } catch {
            step = .passed
            notice = Self.words(error)
            return
        }
        savedVoice = saved
        // The reference now lives in the voice's folder; the recorder's own capture is no longer needed.
        discardUnsavedRecording()
        var sentence = VoiceRangeFit.voiceSavedSentence(saved.range)
        if saved.poorAlignment { sentence += " " + VoiceReferenceLabeler.poorAlignmentMessage }
        step = .saved(sentence)
        onSaved?(saved)
    }

    // MARK: Debug staging (`debug.singScreens`)

    /// Puts the card in `step` for a screenshot, with nothing capturing.
    public func stageForCapture(_ step: Step, elapsed: Double = 0, levelDbfs: Double? = nil,
                                headphones: Bool? = true) {
        if self.step == .closed { openGeneration = transport.projectGeneration }
        self.step = step
        self.elapsed = elapsed
        self.levelDbfs = levelDbfs
        wearsHeadphones = headphones
    }

    // MARK: Helpers

    @discardableResult
    private func play(guideFile guide: SingGuideLine.Guide, onFinish: (@MainActor () -> Void)?) -> Bool {
        guard let url = guideURL(guide) else {
            notice = SingCopy.guideMissing
            return false
        }
        return play(url, onFinish: onFinish)
    }

    @discardableResult
    private func play(_ url: URL, onFinish: (@MainActor () -> Void)?) -> Bool {
        do {
            try player.play(url) { [weak self] in
                if self?.playing == url { self?.playing = nil }
                onFinish?()
            }
            playing = url
            return true
        } catch {
            notice = SingCopy.cannotPlay(Self.words(error))
            playing = nil
            return false
        }
    }

    private func stopPlaying() {
        if playing != nil { player.stop() }
        playing = nil
    }

    private func discardUnsavedRecording() {
        if ownsRecording, let url = recordingURL { Self.remove(url) }
        ownsRecording = false
        recordingURL = nil
        checkedRange = nil
    }

    /// Removes a capture this recorder made. A file that is already gone is not an error.
    private static func remove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            FileHandle.standardError.write(Data("SingVoiceRecorder: could not delete \(url.path): \(error)\n".utf8))
        }
    }

    private func startDriver() {
        guard startsDriver, !driverAlive else { return }
        driverAlive = true
        Task { @MainActor [weak self] in
            while true {
                guard let self, self.driverAlive else { return }
                self.tick()
                do {
                    try await Task.sleep(nanoseconds: 33_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func stopDriver() { driverAlive = false }

    static func words(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
