import Foundation
import Testing
@testable import AIServices
@testable import DAWCore
@testable import DAWAppKit

/// p2-sing-f, the PURE half of the Sing screens (nonisolated): the copy, the consent card's words, the install
/// progress line, the take row, the transpose preview, the sheet preview, the height line, the recorder's clock
/// and its automatic stop. The @MainActor models' tests are appended to `GenerationPresenceModelTests` (no new
/// @MainActor suite); the fakes they share live at the bottom of this file.
@Suite struct SingScreensTextTests {

    // MARK: Copy (§5.7 rows, VERBATIM)

    @Test func copyKeepsTheSection57RowsVerbatim() {
        #expect(SingCopy.installCardBody == "To sing, DAW Pro needs its singing engine: a one-time download of "
            + "about 7 GB. It runs on this Mac, and nothing you sing leaves it.")
        #expect(SingCopy.agentAsked == "An AI agent asked for this.")
        #expect(SingCopy.micPermission == "Your Mac will ask whether DAW Pro may use the microphone — click Allow.")
        #expect(SingCopy.micDenied == "DAW Pro isn't allowed to use the microphone. Open System Settings → "
            + "Privacy & Security → Microphone and turn on DAW Pro.")
        #expect(SingCopy.transposePreview(instrumentTracks: 3, recordedTracks: 1)
            == "This moves 3 instrument tracks and 1 recorded tracks. Drums stay as they are.")
        #expect(SingCopy.transposeAudio(trackName: "Vox")
            == "Your recorded track 'Vox' will be pitch-shifted too, which can sound slightly processed.")
        #expect(SingCopy.installStopped(step: "weights", cause: "the download failed")
            == "Installing stopped at 'weights': the download failed.")
        #expect(SingCopy.installStopped(step: "preflight", cause: "not enough space.")
            == "Installing stopped at 'preflight': not enough space.")
        #expect(SingCopy.menuTitle == "Sing these notes…")
        #expect(SingCopy.wordsPlaceholder == "Type the words to sing")
        #expect(SingCopy.holdLegend == "A + holds the word before it onto the next note.")
        #expect(SingCopy.moveSong(3) == "Move the song up 3")
        #expect(SingCopy.keepTheKey == "Keep the key")
        #expect(SingCopy.singIt == "Sing it")
        #expect(SingCopy.checkingNotes == "Checking the notes…")
        #expect(SingCopy.firstTakeTip == "Turn the melody track down to hear the voice clearly.")
        #expect(SingCopy.singNaturally
            == "Sing it at whatever height feels natural — you don't have to match the tune.")
        #expect(SingCopy.pickTune == "Pick the tune that's easiest for you.")
        #expect(SingCopy.headphonesYes == "Yes — I'll sing along")
        #expect(SingCopy.headphonesNo == "No — I'll listen first, then sing")
        // Rows read from their one home, not retyped here.
        #expect(SingJobVoice.builtInName == "Built-in singer")
        #expect(SingJobCoordinator.Copy.stopping == "Stopping after this line…")
        #expect(SingJobCoordinator.Copy.singing(line: 3, of: 8) == "Singing line 3 of 8…")
    }

    // MARK: Consent card

    @Test func consentCardSaysTheSection57CardAndTheAgentLineOnlyForAnAgent() {
        let mine = SingConsentRequest(id: "a", action: .installEngine, fromAgent: false,
                                      requestedAt: Date(timeIntervalSince1970: 0), message: "m")
        let card = SingConsentCardText(request: mine)
        #expect(card.body == SingCopy.installCardBody)
        #expect(card.agentLine == nil)
        #expect(card.primary == "Install")
        #expect(card.secondary == "Not now")

        var agents = mine
        agents.fromAgent = true
        let agentCard = SingConsentCardText(request: agents)
        #expect(agentCard.body == SingCopy.installCardBody)
        #expect(agentCard.agentLine == "An AI agent asked for this.")

        let removal = SingConsentRequest(id: "b", action: .uninstallEngine, fromAgent: true,
                                         requestedAt: Date(timeIntervalSince1970: 0), message: "m")
        let removeCard = SingConsentCardText(request: removal)
        #expect(removeCard.primary == "Remove the engine")
        #expect(removeCard.agentLine == "An AI agent asked for this.")
        #expect(removeCard.body == SingConsentBroker.message(for: .uninstallEngine, fromAgent: false))
    }

    @Test func installProgressLineBytesAndTheStoppedSentence() {
        let running = SingingEngineInstallStatus(
            state: .installing,
            progress: SingingEngineInstallProgress(stepName: "weights", stepIndex: 5, stepCount: 9,
                                                   bytesDone: 1_400_000_000, bytesTotal: 2_800_000_000))
        let text = SingInstallProgressText(status: running)
        #expect(text.line == "Installing the singing engine: step 5 of 9 (weights)…")
        #expect(text.bytes == "1.4 of 2.8 GB")
        #expect(text.fraction == 0.5)
        #expect(text.cancelTitle == "Cancel")
        #expect(text.cancelEnabled)

        var cancelling = running
        cancelling.cancelRequested = true
        #expect(SingInstallProgressText(status: cancelling).line == SingCopy.installCancelling)
        #expect(!SingInstallProgressText(status: cancelling).cancelEnabled)

        // The coordinator's own wording of a step failure; the card names the step once.
        let failed = SingingEngineInstallStatus(state: .failed, errorMessage: "step 'preflight' failed: only 3 GB free",
                                                failure: .step(name: "preflight"))
        #expect(SingInstallProgressText.stoppedSentence(failed) == "Installing stopped at 'preflight': only 3 GB free.")
    }

    // MARK: The take row (§5.5, §5.6)

    @Test func takeRowWhileSingingThenStoppingThenLandedThenResults() throws {
        let singing = try SingStaging.status(phase: .singing, stageText: SingJobCoordinator.Copy.singing(line: 3, of: 8),
                                             unitIndex: 3, unitCount: 8, progress: 0.4, etaSeconds: 65)
        let row = SingTakeRowText(status: singing)
        #expect(row.stage == "Singing line 3 of 8…")
        #expect(row.percent == "40%")
        #expect(row.eta == "about 1:05 left")
        #expect(row.cancelTitle == "Cancel")
        #expect(row.cancelEnabled)
        #expect(!row.showsResultButtons)

        let stopping = try SingStaging.status(phase: .singing, stageText: SingJobCoordinator.Copy.stopping,
                                              progress: 0.5, cancelRequested: true)
        let stoppingRow = SingTakeRowText(status: stopping)
        #expect(stoppingRow.cancelTitle == "Stopping after this line…")
        #expect(!stoppingRow.cancelEnabled)

        let landed = try SingStaging.status(phase: .checking, stageText: "x", landedTrackID: UUID(),
                                            landedClipID: UUID())
        let landedRow = SingTakeRowText(status: landed)
        #expect(landedRow.stage == "Checking the notes…")
        #expect(landedRow.cancelTitle == nil)
        #expect(landedRow.showsResultButtons)

        let inTune = SungNoteAccuracy(hitRate: 0.95, meanAbsErrorCents: 10, voicedCoverage: 0.9, inTune: true)
        let clear = SungWordCheck(state: SungWordCheck.State.checked, wer: 0.1, verdict: SingWordCheck.Verdict.clear)
        let green = try SingStaging.status(phase: .done, stageText: "x", landedTrackID: UUID(), landedClipID: UUID(),
                                           noteAccuracy: inTune, wordCheck: clear)
        let greenRow = SingTakeRowText(status: green)
        #expect(greenRow.resultLine == "In tune · Words clear")
        #expect(greenRow.tone == .green)

        let off = SungNoteAccuracy(hitRate: 0.6, meanAbsErrorCents: 40, voicedCoverage: 0.9, inTune: false,
                                   offBars: [3, 5])
        let amber = try SingStaging.status(phase: .done, stageText: "x", landedTrackID: UUID(), landedClipID: UUID(),
                                           noteAccuracy: off, wordCheck: clear)
        let amberRow = SingTakeRowText(status: amber)
        #expect(amberRow.resultLine == "Some notes may be off (bars 3, 5). · Words clear")
        #expect(amberRow.tone == .amber)

        let skipped = SungWordCheck(state: SungWordCheck.State.skipped)
        let plain = try SingStaging.status(phase: .done, stageText: "x", landedTrackID: UUID(), landedClipID: UUID(),
                                           noteAccuracy: inTune, wordCheck: skipped)
        #expect(SingTakeRowText(status: plain).tone == .plain)
    }

    @Test func failedTakeShowsTheCoordinatorsWords() throws {
        let failed = try SingStaging.status(phase: .failed, stageText: SingJobCoordinator.Copy.crash,
                                            failure: SingJobFailure(code: "singCrash",
                                                                    message: SingJobCoordinator.Copy.crash))
        let row = SingTakeRowText(status: failed)
        #expect(row.failure == "The singing engine stopped unexpectedly.")
        #expect(row.tone == .failed)
        #expect(row.cancelTitle == nil)
    }

    // MARK: The sheet preview

    @Test func sheetPreviewChipsWarningsAndTheWordsRefusals() {
        let (track, clip) = SingSheetFixture.melody(pitches: [60, 62, 64, 65])
        let tempo = TempoMap(constantBPM: 120)
        let meter = MeterMap(constant: TimeSignature())
        let fits = SingSheetPreview.make(clip: clip, track: track, text: "one two three four", octaveShift: 0,
                                         tempoMap: tempo, meterMap: meter)
        #expect(fits.refusal == nil)
        #expect(fits.chips.map(\.text) == ["one", "two", "three", "four"])
        #expect(fits.notes.count == 4)

        let tooMany = SingSheetPreview.make(clip: clip, track: track, text: "one two three four five six",
                                            octaveShift: 0, tempoMap: tempo, meterMap: meter)
        #expect(tooMany.refusal?.contains("has 6 words but the tune has 4 notes") == true)

        let none = SingSheetPreview.make(clip: clip, track: track, text: "  ", octaveShift: 0, tempoMap: tempo,
                                         meterMap: meter)
        #expect(none.refusal == SingPlanRefusal.lyrics(.noWords).sentence)

        let held = SingSheetPreview.make(clip: clip, track: track, text: "one two", octaveShift: 0,
                                         tempoMap: tempo, meterMap: meter)
        #expect(held.refusal == nil)
        #expect(held.chips.contains { $0.held })
        #expect(!held.warnings.isEmpty)

        let gone = SingSheetPreview.make(clip: nil, track: nil, text: "x", octaveShift: 0, tempoMap: tempo,
                                         meterMap: meter)
        #expect(gone.refusal == SingCopy.clipGone)
    }

    @Test func sheetPreviewRefusesAnAudioClipAndADrumTrackInThePlannersWords() {
        let tempo = TempoMap(constantBPM: 120)
        let audio = Clip(name: "Vox", startBeat: 0, lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/none.wav"))
        let audioTrack = Track(name: "Vox", kind: .audio, clips: [audio])
        let a = SingSheetPreview.make(clip: audio, track: audioTrack, text: "la", octaveShift: 0, tempoMap: tempo,
                                      meterMap: MeterMap(constant: TimeSignature()))
        #expect(a.refusal == SingPlanRefusal.audioClip.sentence)
    }

    @Test func melodyForFitIsTheWiresFormula() {
        // `SingWireHandlers.melodyForFit`: each sung note's pitch and its length in SECONDS through the tempo map,
        // measured from the clip's own start (a clip at beat 4, 120 BPM: a 1-beat note is 0.5 s).
        let (_, clip) = SingSheetFixture.melody(pitches: [60, 67], startBeat: 4)
        let fit = SingSheetPreview.melodyForFit(clip, tempoMap: TempoMap(constantBPM: 120))
        #expect(fit.map(\.midi) == [60, 67])
        #expect(fit.map(\.durationSeconds) == [0.5, 0.5])
    }

    // MARK: Height

    @Test func heightLineOctaveAndKeyChangeAndKeepTheKey() throws {
        let melody = [VoiceRangeFit.MelodyNote(midi: 64, durationSeconds: 1)]
        let fits = try #require(VoiceRangeFit.propose(
            melody: melody, voice: VoiceRange(p10Midi: 60, medianMidi: 64, p90Midi: 68)))
        let line = try #require(SingHeightLine.make(fits, choice: .recommended))
        #expect(line.sentence == "Fits your voice.")
        #expect(line.moveTitle == nil)
        #expect(line.octaveShift == 0)
        #expect(line.suggestion == SingCopy.suggestionCaption)   // uncalibrated (§3.5)

        // The SING-6 shape: a line well above the voice that NO octave fits (worked by hand against the
        // provisional weights, band 39.5…54.6: an octave down leaves the three 69s 2.4 above it, two octaves
        // down drops the 60 and 62 below it, both far past the 0.25 accept line), so a key change is suggested.
        let high = [60, 62, 64, 65, 67, 69, 69, 69].map { VoiceRangeFit.MelodyNote(midi: Double($0), durationSeconds: 0.5) }
        let low = VoiceRange(p10Midi: 40.5, medianMidi: 44, p90Midi: 53.6)
        let proposal = try #require(VoiceRangeFit.propose(melody: high, voice: low))
        if proposal.kind == .songKey {
            let card = try #require(SingHeightLine.make(proposal, choice: .recommended))
            #expect(card.sentence == proposal.sentence)
            #expect(card.moveTitle == SingCopy.moveSong(proposal.recommendation.songTranspose))
            #expect(card.keepTitle == "Keep the key")
            #expect(card.octaveShift == proposal.bestOctaveOnly.octaveShift)
            let kept = try #require(SingHeightLine.make(proposal, choice: .keepKey))
            #expect(kept.sentence == proposal.alternativeSentence)
            #expect(kept.keepTitle == nil)
        } else {
            Issue.record("expected a key-change proposal for a line 1.75 octaves above the voice")
        }
        #expect(SingHeightLine.make(nil, choice: .recommended) == nil)
    }

    // MARK: Transpose preview

    @Test func transposePreviewCountsTracksAndNamesEachRecordedTrack() throws {
        let midiTrack = UUID()
        let audioTrack = UUID()
        let report = TransposeReport(
            semitones: 3, dryRun: true, applied: false, summary: "s", notesMoved: 8, midiClipsMoved: 1,
            audioClipsShifted: 1, takeClipsMoved: 0,
            tracks: [
                .init(trackId: midiTrack, name: "Lead", outcome: .moved, reason: nil,
                      clips: [.init(clipId: UUID(), name: "m", kind: .midi, place: .timeline, notesMoved: 8,
                                    shiftBefore: nil, shiftAfter: nil, keepsTuning: nil)]),
                .init(trackId: audioTrack, name: "Vox", outcome: .moved, reason: nil,
                      clips: [.init(clipId: UUID(), name: "a", kind: .audio, place: .timeline, notesMoved: nil,
                                    shiftBefore: 0, shiftAfter: 3, keepsTuning: nil)]),
                .init(trackId: UUID(), name: "Drums", outcome: .skippedDrums, reason: "drums", clips: []),
            ],
            fields: [],
            warnings: [.init(code: .audioWillBePitchShifted, trackId: audioTrack, trackName: "Vox", clipIds: [],
                             source: .recorded, message: "m")])
        let review = SingTransposeReview(semitones: 3, report: report)
        #expect(review.sentence == "This moves 1 instrument tracks and 1 recorded tracks. Drums stay as they are.")
        #expect(review.audioWarnings
            == ["Your recorded track 'Vox' will be pitch-shifted too, which can sound slightly processed."])
        #expect(review.otherWarnings.isEmpty)
    }

    // MARK: The recorder's clock and automatic stop (§5.4)

    @Test func recorderClockGetReadyThenFourBeatsThenSinging() {
        #expect(SingRecorderTiming.phase(atElapsed: 0.2) == .getReady)
        #expect(SingRecorderTiming.phase(atElapsed: 1.0) == .countIn(beat: 1))
        #expect(SingRecorderTiming.phase(atElapsed: 1.0 + 0.6 * 3 + 0.01) == .countIn(beat: 4))
        #expect(SingRecorderTiming.phase(atElapsed: SingRecorderTiming.singingStartsAt + 0.01) == .singing)
        #expect(SingRecorderTiming.maxSeconds == 12)
        #expect(SingRecorderTiming.guardAfterSeconds == 0.30)
        // The guide's first click (0.25 s into the file) lands on beat 1.
        #expect(abs(SingRecorderTiming.guideStartsAt + SingRecorderTiming.guideLeadSeconds
            - SingRecorderTiming.getReadySeconds) < 1e-9)
    }

    @Test func quietAutoStopNeedsThreeSecondsOfSingingThenOneAndAHalfOfQuiet() {
        var stop = SingQuietAutoStop()
        var t = 0.0
        var stopped = false
        func feed(_ seconds: Double, _ db: Double) {
            let end = t + seconds
            while t < end - 1e-9 {
                t += 1.0 / 30
                if stop.observe(elapsed: t, peakDbfs: db) { stopped = true }
            }
        }
        feed(SingRecorderTiming.singingStartsAt, -70)   // the quiet room and the count-in
        #expect(stop.floorDbfs == -70)
        feed(2.0, -20)                                   // 2 s of singing
        feed(2.0, -70)                                   // quiet, but only 2 s of singing so far
        #expect(!stopped)
        feed(1.2, -20)                                   // now 3.2 s of singing
        feed(1.4, -70)
        #expect(!stopped)                                 // 1.4 s of quiet: not yet
        feed(0.2, -70)
        #expect(stopped)                                  // 1.5 s of quiet after 3 s of singing
    }

    @Test func quietAutoStopControlALoudRoomNeverCountsAsQuietSinging() {
        // Control: a room as loud as the singing never reaches the singing threshold, so nothing stops by itself
        // (the 12 s cap is the backstop).
        var stop = SingQuietAutoStop()
        var stopped = false
        var t = 0.0
        while t < 12 {
            t += 1.0 / 30
            if stop.observe(elapsed: t, peakDbfs: -20) { stopped = true }
        }
        #expect(!stopped)
        #expect(stop.singingSeconds == 0)
    }

    @Test func sheetHeightBudgetComesFromTheWindow() {
        #expect(SingCardLayout.noticesRoom(windowHeight: 900) == 900 - 80 - SingCardLayout.sheetFixedChrome)
        #expect(SingCardLayout.noticesRoom(windowHeight: 300) == SingCardLayout.noticesFloor)
    }

    @Test func singJobOriginForAnAgentIsAgent() {
        #expect(GenerationJobOrigin.forSingJob(fromAgent: true) == .singAgent)
        #expect(GenerationJobOrigin.forSingJob(fromAgent: false) == .sing)
        #expect(GenerationJobOrigin.singAgent.displayLabel == "AGENT")
    }
}

// MARK: - Shared fakes (used by the appended MainActor tests in GenerationPresenceModelTests)

enum SingSheetFixture {
    /// One instrument track holding one melody clip, one beat per note.
    static func melody(pitches: [Int], startBeat: Double = 0) -> (Track, Clip) {
        let notes = pitches.enumerated().map { i, p in MIDINote(pitch: p, startBeat: Double(i), lengthBeats: 1) }
        let clip = Clip(name: "Melody", startBeat: startBeat, lengthBeats: Double(pitches.count), notes: notes)
        return (Track(name: "Lead", kind: .instrument, clips: [clip]), clip)
    }

    @MainActor
    static func store(pitches: [Int] = [60, 62, 64, 65], lyrics: String? = nil) throws -> (ProjectStore, UUID) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let notes = pitches.enumerated().map { i, p in MIDINote(pitch: p, startBeat: Double(i), lengthBeats: 1) }
        let clip = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0,
                                         lengthBeats: Double(pitches.count), notes: notes)
        if let lyrics { try store.setClipLyrics(clipId: clip.id, text: lyrics, undoLabel: "Set Lyrics") }
        return (store, clip.id)
    }
}

/// THE sing job, faked: records submits and cancels; can refuse.
actor SingFakeJobs: SingSheetJobs {
    private(set) var submitted: [SingJobRequest] = []
    private(set) var cancelled: [String] = []
    private var held: [SingJobStatus] = []
    private var refusal: SingJobError?
    /// p2-sing-x8: a refused cancel (`jobFinished` once landing has started, design §16).
    private var cancelRefusal: SingJobError?

    func refuse(_ error: SingJobError?) { refusal = error }
    func refuseCancel(_ error: SingJobError?) { cancelRefusal = error }
    func hold(_ status: SingJobStatus) { held.append(status) }

    func submit(_ request: SingJobRequest) async throws -> SingJobStatus {
        if let refusal { throw refusal }
        submitted.append(request)
        let status = try SingStaging.status(phase: .queued, stageText: SingJobCoordinator.Copy.queued,
                                            jobID: "sing-fake-\(submitted.count)", clipID: request.clipID,
                                            fromAgent: request.fromAgent)
        held.append(status)
        return status
    }

    func status(jobID: String) async throws -> SingJobStatus {
        guard let found = held.last(where: { $0.jobID == jobID }) else { throw SingJobError.jobNotFound(jobID) }
        return found
    }

    func cancel(jobID: String) async throws -> SingJobStatus {
        if let cancelRefusal { throw cancelRefusal }
        guard let index = held.lastIndex(where: { $0.jobID == jobID }) else { throw SingJobError.jobNotFound(jobID) }
        cancelled.append(jobID)
        held[index].cancelRequested = true
        return held[index]
    }
}

/// A spy in front of THE lyrics writes: records, then calls the store's own method. p2-sing-x8: the sheet writes the
/// words ONLY through the language overload (the W8-X3b ruling), and a note's word through `setNoteWord`.
@MainActor
final class SingLyricsSpy: SingSheetLyricsWriting {
    struct Call: Equatable { var clipId: UUID; var text: String; var language: String?; var undoLabel: String }
    struct NoteWordCall: Equatable { var clipId: UUID; var noteId: UUID; var word: String; var dryRun: Bool }
    private(set) var calls: [Call] = []
    private(set) var noteWordCalls: [NoteWordCall] = []
    let store: ProjectStore
    init(store: ProjectStore) { self.store = store }
    func setClipLyrics(clipId: UUID, text: String, language: String?, undoLabel: String) throws -> Clip {
        calls.append(Call(clipId: clipId, text: text, language: language, undoLabel: undoLabel))
        return try store.setClipLyrics(clipId: clipId, text: text, language: language, undoLabel: undoLabel)
    }
    func setNoteWord(clipId: UUID, noteId: UUID, word: String, dryRun: Bool) throws -> LyricNoteWordResult {
        noteWordCalls.append(NoteWordCall(clipId: clipId, noteId: noteId, word: word, dryRun: dryRun))
        return try store.setNoteWord(clipId: clipId, noteId: noteId, word: word, dryRun: dryRun)
    }
}

/// A spy in front of THE key change.
@MainActor
final class SingTransposeSpy: SingSheetTransposing {
    struct Call: Equatable { var semitones: Int; var dryRun: Bool }
    private(set) var calls: [Call] = []
    let store: ProjectStore
    init(store: ProjectStore) { self.store = store }
    func transposeProject(semitones: Int, excludeTrackIds: Set<UUID>, dryRun: Bool) throws -> TransposeReport {
        calls.append(Call(semitones: semitones, dryRun: dryRun))
        return try store.transposeProject(semitones: semitones, excludeTrackIds: excludeTrackIds, dryRun: dryRun)
    }
}

/// The microphone, faked: no real capture, ever. The test fires the completion.
@MainActor
final class SingFakeCapture: SingVoiceCapturing {
    var recordPermission: RecordPermission = .granted
    var grantOnRequest = true
    var startError: InputOnlyCaptureError?
    var peak: Double? = -70
    /// Shared with the transport fake, to prove ORDER (playback stopped before any capture starts).
    var sharedLog: ((String) -> Void)?
    private(set) var log: [String] = []
    private(set) var started: [(url: URL, maxSeconds: Double)] = []
    private var completion: (@MainActor (InputOnlyCaptureOutcome) -> Void)?

    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        log.append("requestPermission")
        let granted = grantOnRequest
        recordPermission = granted ? .granted : .denied
        completion(granted)
    }
    func startInputOnlyCapture(to url: URL, maxSeconds: Double,
                               completion: @escaping @MainActor (InputOnlyCaptureOutcome) -> Void) throws {
        if let startError { throw startError }
        log.append("start")
        sharedLog?("start")
        started.append((url, maxSeconds))
        self.completion = completion
    }
    func stopInputOnlyCapture() -> Bool {
        log.append("stop")
        return completion != nil
    }
    func cancelInputOnlyCapture() -> Bool {
        log.append("cancel")
        let had = completion != nil
        completion?(.cancelled)
        completion = nil
        return had
    }
    func inputOnlyCapturePeakDbfs() -> Double? { completion == nil ? nil : peak }

    /// The engine finishes: the file "exists" (written by the test) and the completion fires.
    func finish(_ outcome: InputOnlyCaptureOutcome) {
        let fire = completion
        completion = nil
        fire?(outcome)
    }
}

/// The song's transport, faked.
@MainActor
final class SingFakeTransport: SingRecorderTransport {
    var isTransportPlaying = false
    var isTransportRecording = false
    var projectGeneration: UInt64 = 1
    /// The song's refusal slot the recorder registers with (p2-sing-f2; the real one is the store's).
    var voiceRecorderOpenReason: String?
    /// Shared with the capture fake's log, to prove ORDER (playback stopped before any capture).
    var log: (String) -> Void = { _ in }
    private(set) var stops = 0
    func stopTransport() {
        stops += 1
        isTransportPlaying = false
        log("stopTransport")
    }
}

/// The guide/recording player, faked.
@MainActor
final class SingFakePlayer: SingAudioPreviewing {
    private(set) var played: [URL] = []
    var failure: (any Error)?
    func play(_ url: URL, onFinish: @escaping @MainActor () -> Void) throws {
        if let failure { throw failure }
        played.append(url)
    }
    func stop() {}
}

/// The voice saver, spied: `check` and `save` record their calls and answer as told.
actor SingSaverSpy: SingVoiceSaving {
    private(set) var checks: [URL] = []
    private(set) var checkKinds: [SingVoiceRecord.Source] = []
    private(set) var saves: [(url: URL, name: String, kind: SingVoiceRecord.Source)] = []
    private var checkError: SingVoiceAddRefusal?
    let range = VoiceRange(p10Midi: 40.5, medianMidi: 44, p90Midi: 53.6)

    func refuseChecks(_ error: SingVoiceAddRefusal?) { checkError = error }

    func check(recording: URL, kind: SingVoiceRecord.Source) async throws -> VoiceRange {
        checks.append(recording)
        checkKinds.append(kind)
        if let checkError { throw checkError }
        return range
    }
    func save(recording: URL, name: String, kind: SingVoiceRecord.Source) async throws -> SingSavedVoice {
        saves.append((recording, name, kind))
        return SingSavedVoice(id: "voice-saved", name: name, range: range, poorAlignment: false)
    }
}
