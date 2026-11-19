import AIServices
import DAWCore
import Foundation
import Observation

// MARK: - The pure parts (nonisolated; `SingScreensTextTests`)

/// One note of the strip under the words (§5.2 "the melody's notes as a strip").
public struct SingStripNote: Equatable, Sendable, Identifiable {
    /// The note's own id (p2-sing-x8: the note field and the Expression card name notes by it).
    public var id: UUID
    public var pitch: Int
    /// Clip-relative beats.
    public var startBeat: Double
    public var lengthBeats: Double
}

/// One glowing word chip over its notes (§5.2). A stretched chip is a held word.
public struct SingWordChip: Equatable, Sendable, Identifiable {
    public var id: Int
    public var text: String
    /// Clip-relative beats, first note's onset to last note's end.
    public var startBeat: Double
    public var endBeat: Double
    public var noteCount: Int
    public var held: Bool
    /// The notes the word sings, in order (p2-sing-x8: a click on the chip opens its first note's field).
    public var noteIDs: [UUID]
    /// The word's hyphen parts ("twin", "kle"); one element for a word with no hyphen (`LyricWord.parts`). vf-2: the
    /// strip draws each part on its own note, by the piano roll's Words-lane layout (`SingWordStripLayout`).
    public var parts: [String]
    /// The breath phrase (0-based) its notes are in (`AssignedLyricWord.phrase`).
    public var phrase: Int
}

/// What the sheet shows for the words typed so far, from THE one derivation (`SingPlanner.plan`, which runs
/// `SingPlanner.assignment`): the strip, the chips, the warnings and, when the take cannot be sung, the reason in
/// the planner's own words (§5.7 W > N, No lyrics, Drum track, Audio clip, Note too long, Not English, …).
public struct SingSheetPreview: Equatable, Sendable {
    public var notes: [SingStripNote]
    /// The strip's span: the clip's length in beats.
    public var lengthBeats: Double
    public var chips: [SingWordChip]
    public var warnings: [String]
    /// Why [Sing it] is dark, verbatim; nil when it can be pressed.
    public var refusal: String?
    /// Notes no word reaches (a chord's other notes are not in the strip at all): the note field says so (§14 "Note
    /// not sung") before anything is typed.
    public var unsungNoteIDs: [UUID]

    public static let empty = SingSheetPreview(notes: [], lengthBeats: 0, chips: [], warnings: [], refusal: nil)

    public init(notes: [SingStripNote], lengthBeats: Double, chips: [SingWordChip], warnings: [String],
                refusal: String?, unsungNoteIDs: [UUID] = []) {
        self.notes = notes
        self.lengthBeats = lengthBeats
        self.chips = chips
        self.warnings = warnings
        self.refusal = refusal
        self.unsungNoteIDs = unsungNoteIDs
    }

    /// The preview for `text` on `clip`, planned at `octaveShift` (the height the take will sing at), the way
    /// `sing.render {dryRun: true, lyrics}` plans it, in the clip's own language.
    public static func make(clip: Clip?, track: Track?, text: String, octaveShift: Int, tempoMap: TempoMap,
                            meterMap: MeterMap) -> SingSheetPreview {
        make(clip: clip, track: track, text: text, language: clip?.lyrics?.language, octaveShift: octaveShift,
             tempoMap: tempoMap, meterMap: meterMap)
    }

    /// The same preview in `language` (a `ClipLyrics` code, nil = English): the picker's value, so §6.7's sentences
    /// appear exactly when the words and the picked language disagree (p2-sing-x8).
    public static func make(clip: Clip?, track: Track?, text: String, language: String?, octaveShift: Int,
                            tempoMap: TempoMap, meterMap: MeterMap) -> SingSheetPreview {
        guard let clip, let track else {
            return SingSheetPreview(notes: [], lengthBeats: 0, chips: [], warnings: [], refusal: SingCopy.clipGone)
        }
        let notes = SingPlanner.melody(of: clip).notes.map {
            SingStripNote(id: $0.id, pitch: $0.pitch, startBeat: $0.startBeat, lengthBeats: $0.lengthBeats)
        }
        var preview = SingSheetPreview(notes: notes, lengthBeats: clip.lengthBeats, chips: [], warnings: [],
                                       refusal: nil)
        // The wire's length check comes before the plan (`validatedLyrics`), in the store's words.
        if text.count > ClipLyrics.maxTextLength {
            preview.refusal = LyricEditRefusal.tooLong(characters: text.count).sentence
            return preview
        }
        var probe = clip
        probe.lyrics = ClipLyrics.normalized(ClipLyrics(text: text, language: LyricLanguage.stored(language)))
        do throws(SingPlanRefusal) {
            let plan = try SingPlanner.plan(clip: probe, on: track, tempoMap: tempoMap, meterMap: meterMap,
                                            octaveShift: octaveShift)
            preview.chips = chips(plan.assignment)
            preview.warnings = plan.warnings.map(\.sentence)
            preview.unsungNoteIDs = plan.assignment.unsungNoteIDs
        } catch {
            preview.refusal = error.sentence
            // A plan refused for the HEIGHT (a note pushed out of range, a note too long) can still show which word
            // sits on which note: the assignment alone does not depend on it.
            if case .lyrics(_) = error { return preview }
            do throws(LyricRefusal) {
                let assignment = try SingPlanner.assignment(for: probe, tempoMap: tempoMap)
                preview.chips = chips(assignment)
                preview.warnings = assignment.warnings.map(\.sentence)
                preview.unsungNoteIDs = assignment.unsungNoteIDs
            } catch {
                // The refusal above already says what is wrong; there are just no chips to draw.
            }
        }
        return preview
    }

    static func chips(_ assignment: LyricAssignment) -> [SingWordChip] {
        assignment.words.enumerated().map { index, word in
            SingWordChip(id: index, text: word.word.typed, startBeat: word.startBeat, endBeat: word.endBeat,
                         noteCount: word.noteIDs.count, held: word.held, noteIDs: word.noteIDs,
                         parts: word.word.parts, phrase: word.phrase)
        }
    }

    /// The chip whose notes hold `beat` (clip-relative), for the playback glow (design §8.2). A lookup over chips
    /// derived once per text or note change; it derives nothing.
    public func chipID(atClipBeat beat: Double) -> Int? {
        var low = 0, high = chips.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let chip = chips[mid]
            if beat < chip.startBeat {
                high = mid - 1
            } else if beat >= chip.endBeat {
                low = mid + 1
            } else {
                return chip.id
            }
        }
        return nil
    }

    /// The melody a voice is fitted to: the notes the take sings (`SingPlanner.melody`), at their lengths in
    /// seconds. ⚠️ A MIRROR of `SingWireHandlers.melodyForFit` (DAWControl, internal): DAWAppKit cannot import
    /// DAWControl and no test target sees both modules. `melodyForFitIsTheWiresFormula` pins this one's arithmetic,
    /// and `wiresHandMirrorsAreEqual` (SingScreensExpansionTests) reads BOTH sources and fails when the two bodies
    /// differ by anything but whitespace.
    public static func melodyForFit(_ clip: Clip, tempoMap: TempoMap) -> [VoiceRangeFit.MelodyNote] {
        SingPlanner.melody(of: clip).notes.map {
            VoiceRangeFit.MelodyNote(midi: Double($0.pitch),
                                     durationSeconds: tempoMap.seconds(from: clip.startBeat + $0.startBeat,
                                                                       to: clip.startBeat + $0.startBeat
                                                                           + $0.lengthBeats))
        }
    }
}

/// One voice in the picker (§5.2 "Built-in singer", each saved voice, "Add your voice…").
public struct SingVoiceChoice: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var range: VoiceRange
    /// nil for the built-in singer.
    public var record: SingVoiceRecord?

    public static let builtIn = SingVoiceChoice(id: SingJobVoice.builtInID, name: SingJobVoice.builtInName,
                                                range: SingVoiceLibrary.builtInRange, record: nil)

    public init(id: String, name: String, range: VoiceRange, record: SingVoiceRecord?) {
        self.id = id
        self.name = name
        self.range = range
        self.record = record
    }

    public init(record: SingVoiceRecord) {
        self.init(id: record.id, name: record.name, range: record.range, record: record)
    }
}

/// The person's answer to a key-change card.
public enum SingHeightChoice: Equatable, Sendable {
    /// No answer yet (or the octave case, where there is nothing to answer).
    case recommended
    /// [Keep the key].
    case keepKey
}

/// §5.2 step 3, "Height": the one line from the key proposal, or the key-change card.
public struct SingHeightLine: Equatable, Sendable {
    /// "Fits your voice.", "…one octave lower…", the key-change sentence, or "Keep the song as it is…".
    public var sentence: String
    /// The card's [Move the song up t], when a key change is on offer.
    public var moveTitle: String?
    /// [Keep the key], while the key change is still the suggestion.
    public var keepTitle: String?
    /// The song move [Move] would make.
    public var songTranspose: Int
    /// Shown while the proposal is uncalibrated (§3.5).
    public var suggestion: String?
    /// The octaves the take is sung at with this answer. Until [Move] is confirmed the song keeps its key, so a
    /// key-change proposal still sings at the best octave-only fit: the wire's `octaveShift: "auto"` rule.
    public var octaveShift: Int

    public static func make(_ proposal: KeyProposal?, choice: SingHeightChoice) -> SingHeightLine? {
        guard let proposal else { return nil }
        let suggestion = proposal.calibrated ? nil : SingCopy.suggestionCaption
        switch (proposal.kind, choice) {
        case (.octave, _):
            return SingHeightLine(sentence: proposal.sentence, moveTitle: nil, keepTitle: nil, songTranspose: 0,
                                  suggestion: suggestion, octaveShift: proposal.recommendation.octaveShift)
        case (.songKey, .recommended):
            return SingHeightLine(sentence: proposal.sentence,
                                  moveTitle: SingCopy.moveSong(proposal.recommendation.songTranspose),
                                  keepTitle: SingCopy.keepTheKey,
                                  songTranspose: proposal.recommendation.songTranspose, suggestion: suggestion,
                                  octaveShift: proposal.bestOctaveOnly.octaveShift)
        case (.songKey, .keepKey):
            return SingHeightLine(sentence: proposal.alternativeSentence ?? proposal.sentence,
                                  moveTitle: SingCopy.moveSong(proposal.recommendation.songTranspose),
                                  keepTitle: nil, songTranspose: proposal.recommendation.songTranspose,
                                  suggestion: suggestion, octaveShift: proposal.bestOctaveOnly.octaveShift)
        }
    }
}

/// What [Move the song up t] shows before anything moves (§5.2: "[Move] shows the `project.transpose` preview
/// first"), from the store's own dry run.
public struct SingTransposeReview: Equatable, Sendable {
    public var semitones: Int
    /// §5.7 "Transpose preview".
    public var sentence: String
    /// §5.7 "Transpose, audio", one per recorded track.
    public var audioWarnings: [String]
    /// The report's other warnings, in its own words.
    public var otherWarnings: [String]

    public init(semitones: Int, report: TransposeReport) {
        self.semitones = semitones
        let moved = report.tracks.filter { $0.outcome == .moved }
        let instrument = moved.filter { $0.clips.contains { $0.kind == .midi } }.count
        let recorded = moved.filter { $0.clips.contains { $0.kind == .audio } }.count
        sentence = SingCopy.transposePreview(instrumentTracks: instrument, recordedTracks: recorded)
        audioWarnings = report.warnings.filter { $0.code == .audioWillBePitchShifted }
            .map { SingCopy.transposeAudio(trackName: $0.trackName) }
        otherWarnings = report.warnings.filter { $0.code != .audioWillBePitchShifted }.map(\.message)
    }
}

// MARK: - The sheet (§5.2)

/// The Sing sheet: words, voice, height, [Sing it]. Every press is a call the wire makes too (see
/// `SingSeams.swift`): lyrics through `setClipLyrics`, a key change through `transposeProject`, the take through
/// `SingJobCoordinator.submit`. Nothing here is a second way to do any of them.
@MainActor
@Observable
public final class SingSheetModel {

    /// The undo step the lyrics write records: the wire's `SingWireHandlers.setLyricsUndoLabel` ("Set Lyrics",
    /// DAWControl, internal). No test target sees both modules, so `wiresHandMirrorsAreEqual`
    /// (SingScreensExpansionTests) reads the wire's SOURCE and compares it with this value.
    public static let undoLabel = "Set Lyrics"

    let store: ProjectStore
    let lyrics: any SingSheetLyricsWriting
    private let transposer: any SingSheetTransposing
    private let jobs: any SingSheetJobs
    private let engineStatus: @Sendable () async -> SingingSidecarStatus
    let library: SingVoiceLibrary?
    /// "Write words for me" (design §8.3): the app's lyrics writer, resolved from the key chain at each use (the
    /// `LyricsWorkshopModel` shape). nil: the button is not offered.
    let makeWriter: (@MainActor () throws -> any LyricsGenerating)?

    /// The Expression card (design §5.1): the style write and the note selection.
    public let expression: SingExpressionModel

    // MARK: p2-sing-x8 state (design 2026-10-06 §3.1, §4.1, §6.1, §8.1-§8.3)

    /// The language picker's value as `ClipLyrics` stores it (nil = English). Set from the clip on open and then
    /// owned HERE: every lyrics write sends it (the W8-X3b ruling), so clearing the box keeps it.
    public internal(set) var language: String?
    /// The note field (design §3.1), open over one note; nil when closed.
    public internal(set) var noteWord: SingNoteWordField?
    /// "One sound per line" (false) / "One per note" (true).
    public internal(set) var wordlessPerNote = false
    /// True when the box is empty or holds a text the wordless buttons wrote (so switching sounds stays one click).
    public internal(set) var wordlessOffered = false
    var wordlessTexts: Set<String> = []
    /// "Write words for me" (design §8.3).
    public internal(set) var writeWords = SingWriteWordsState()
    /// Harmony parts the person added, in order (design §4.1), and the key they picked (nil = worked out).
    public internal(set) var harmonyParts: [SingHarmonyPart] = []
    public internal(set) var givenKey: SongKey?
    /// Derived once per refresh (never per frame): each part's row, the key line, the menu's choices.
    public internal(set) var harmonyRows: [SingHarmonyRow] = []
    public internal(set) var harmonyKey = SingHarmonyKeyState.notNeeded
    public internal(set) var tuneHasChords = false
    public internal(set) var otherMelodies: [SingOtherMelody] = []
    /// How many times the words were derived into chips (`refresh`). The playback glow must never raise it
    /// (design §8.2: "derived once per text or note change, never per frame").
    public internal(set) var derivationCount = 0
    /// Where the clip starts (absolute beats) at the last derivation: the glow's only other input.
    var derivedClipStartBeat = 0.0
    /// A screenshot-only playhead (`debug.singScreens`): shows the glow with nothing playing.
    public internal(set) var stagedPlayheadBeat: Double?

    /// The engine is not installed: ask for consent (the consent card). Nothing has been stored.
    public var onNeedsInstall: (@MainActor () async -> Void)?
    /// A take was accepted: put it on the progress card and the results card.
    public var onSubmitted: (@MainActor (SingJobStatus, SingJobRequest) -> Void)?
    /// "Add your voice…": open the recorder.
    public var onAddVoice: (@MainActor () -> Void)?

    public private(set) var clipID: UUID?
    public internal(set) var text = ""
    public private(set) var preview = SingSheetPreview.empty
    public private(set) var voices: [SingVoiceChoice] = [.builtIn]
    /// Saved voices whose `voice.json` could not be read (listed so they are not silently missing).
    public private(set) var unreadableVoices: [String] = []
    public private(set) var selectedVoiceID = SingJobVoice.builtInID
    public private(set) var proposal: KeyProposal?
    public private(set) var heightChoice = SingHeightChoice.recommended
    public private(set) var transposeReview: SingTransposeReview?
    /// Semitones the song was moved by from this sheet (the take's provenance, `songTransposeSemitones`).
    public private(set) var movedSemitones = 0
    /// The last refusal, in its own words (the store's, the coordinator's, the broker's).
    public internal(set) var refusal: String?
    public private(set) var isSubmitting = false

    /// - Parameters:
    ///   - styles: THE style write; nil = `store` itself (the app's conformer, `ProjectStore.setSingStyle`).
    ///   - makeWriter: "Write words for me"'s writer; nil = the button is not offered.
    public init(store: ProjectStore, lyrics: any SingSheetLyricsWriting, transposer: any SingSheetTransposing,
                jobs: any SingSheetJobs, engineStatus: @escaping @Sendable () async -> SingingSidecarStatus,
                library: SingVoiceLibrary?, styles: (any SingSheetStyleWriting)? = nil,
                makeWriter: (@MainActor () throws -> any LyricsGenerating)? = nil) {
        self.store = store
        self.lyrics = lyrics
        self.transposer = transposer
        self.jobs = jobs
        self.engineStatus = engineStatus
        self.library = library
        self.makeWriter = makeWriter
        self.expression = SingExpressionModel(store: store, styles: styles ?? store)
    }

    public var isOpen: Bool { clipID != nil }

    public var height: SingHeightLine? { SingHeightLine.make(proposal, choice: heightChoice) }

    public var selectedVoice: SingVoiceChoice {
        voices.first { $0.id == selectedVoiceID } ?? .builtIn
    }

    /// The clip's name for the header.
    public var clipName: String { located?.clip.name ?? "" }

    /// Why [Sing it] is dark, or nil: the words' refusal, then a harmony part's (a key that cannot be worked out),
    /// then "Starting…".
    public var singItDisabledReason: String? {
        if let reason = preview.refusal { return reason }
        if let reason = harmonyRows.lazy.compactMap(\.refusal).first { return reason }
        return isSubmitting ? SingCopy.submitting : nil
    }

    public var canSing: Bool { clipID != nil && singItDisabledReason == nil }

    // MARK: Open / close

    /// Opens on `clipID` with the clip's own lyrics and language, the saved voices, and a fresh proposal.
    public func open(clipID: UUID) async {
        self.clipID = clipID
        text = located?.clip.lyrics?.text ?? ""
        language = LyricLanguage.stored(located?.clip.lyrics?.language)
        refusal = nil
        transposeReview = nil
        heightChoice = .recommended
        movedSemitones = 0
        isSubmitting = false
        noteWord = nil
        writeWords = SingWriteWordsState()
        harmonyParts = []
        givenKey = nil
        stagedPlayheadBeat = nil
        expression.attach(clipID: clipID)
        recomputeProposal()
        refresh()
        await reloadVoices(selecting: nil)
    }

    public func close() {
        clipID = nil
        transposeReview = nil
        refusal = nil
        isSubmitting = false
        noteWord = nil
        writeWords = SingWriteWordsState()
        stagedPlayheadBeat = nil
        expression.attach(clipID: nil)
    }

    // MARK: Words

    public func setText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        refusal = nil
        noteWord = nil   // its word was read from the old text
        refresh()
    }

    // MARK: Voice

    public func selectVoice(_ id: String) {
        guard voices.contains(where: { $0.id == id }) else { return }
        selectedVoiceID = id
        heightChoice = .recommended
        transposeReview = nil
        recomputeProposal()
        refresh()
    }

    /// Re-reads the voice library (after the recorder saved one, `selecting` it).
    public func reloadVoices(selecting id: String?) async {
        var list = [SingVoiceChoice.builtIn]
        var unreadable: [String] = []
        if let library {
            let found = await Task.detached { library.list() }.value
            list += found.voices.map(SingVoiceChoice.init(record:))
            unreadable = found.unreadable
        }
        voices = list
        unreadableVoices = unreadable
        if let id, list.contains(where: { $0.id == id }) {
            selectedVoiceID = id
        } else if !list.contains(where: { $0.id == selectedVoiceID }) {
            selectedVoiceID = SingJobVoice.builtInID
        }
        recomputeProposal()
        refresh()
    }

    // MARK: Height

    /// [Move the song up t]: the store's dry run first; nothing moves until `confirmMove`.
    public func chooseMove() {
        guard let line = height, line.moveTitle != nil else { return }
        refusal = nil
        do {
            let report = try transposer.transposeProject(semitones: line.songTranspose, excludeTrackIds: [],
                                                         dryRun: true)
            transposeReview = SingTransposeReview(semitones: line.songTranspose, report: report)
        } catch {
            refusal = Self.words(error)
        }
    }

    /// The preview's [Move the song]: `project.transpose`'s own store method, one undo step.
    public func confirmMove() {
        guard let review = transposeReview else { return }
        refusal = nil
        do {
            try transposer.transposeProject(semitones: review.semitones, excludeTrackIds: [], dryRun: false)
        } catch {
            refusal = Self.words(error)
            return
        }
        movedSemitones += review.semitones
        transposeReview = nil
        heightChoice = .recommended
        recomputeProposal()
        refresh()
    }

    public func cancelMove() { transposeReview = nil }

    /// [Keep the key].
    public func chooseKeepKey() {
        transposeReview = nil
        heightChoice = .keepKey
        refresh()
    }

    // MARK: Sing it

    /// [Sing it], in the wire's order (`sing.render`): the engine first (not installed → the consent card, nothing
    /// stored), then the lyrics only if they changed, then the coordinator. Every refusal stays on the sheet in
    /// its own words; only an accepted take closes it.
    public func singIt() async {
        guard let clipID, canSing else { return }
        refusal = nil
        isSubmitting = true
        defer { isSubmitting = false }

        let engine = await engineStatus()
        switch engine.state {
        case .notInstalled, .needsUpdate:
            await onNeedsInstall?()
            return
        default:
            break
        }
        guard located != nil else {
            refusal = SingCopy.clipGone
            return
        }
        do {
            try writeLyricsIfChanged()
        } catch {
            refusal = Self.words(error)
            return
        }
        // ONE job: the lead and every harmony part (design §4.4), the parts built ONLY as `SingJobRequest.parts`.
        let request = SingJobRequest(clipID: clipID, octaveShift: height?.octaveShift ?? 0, voice: jobVoice,
                                     songTransposeSemitones: movedSemitones, fromAgent: false,
                                     parts: harmonyJobParts, key: givenKey)
        let status: SingJobStatus
        do {
            status = try await jobs.submit(request)
        } catch {
            refusal = Self.words(error)
            return
        }
        onSubmitted?(status, request)
        close()
    }

    // MARK: Helpers

    var located: (track: Track, clip: Clip)? {
        guard let clipID else { return nil }
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.id == clipID }) { return (track, clip) }
        }
        return nil
    }

    private var jobVoice: SingJobVoice { jobVoice(for: selectedVoice) }

    /// A picker choice as the job's voice (`SingVoiceLibrary.ownVoice`, the one home of an own voice's fields).
    func jobVoice(for choice: SingVoiceChoice) -> SingJobVoice {
        guard let record = choice.record, let library else { return .builtIn }
        return .own(library.ownVoice(record))
    }

    /// THE lyrics write of the sheet: `setClipLyrics(…language:…)` with the picker's value, "Set Lyrics", ONLY when
    /// the clip's lyrics would change (the wire's rule, SingWire `setLyrics`: `after != clip.lyrics`), so an unchanged
    /// box records no undo step. Throws the store's refusal.
    func writeLyricsIfChanged() throws {
        guard let clipID, let clip = located?.clip else { return }
        let after = ClipLyrics.normalized(ClipLyrics(text: text, language: LyricLanguage.stored(language)))
        guard after != clip.lyrics else { return }
        try lyrics.setClipLyrics(clipId: clipID, text: text, language: language, undoLabel: Self.undoLabel)
    }

    private func recomputeProposal() {
        guard let clip = located?.clip, clip.isMIDI else {
            proposal = nil
            return
        }
        proposal = VoiceRangeFit.propose(
            melody: SingSheetPreview.melodyForFit(clip, tempoMap: store.transport.tempoMap),
            voice: selectedVoice.range)
    }

    /// THE derivation: the words into chips (the planner's one assignment), and everything else the sheet shows that
    /// depends on the text, the notes or the voice. Runs on open, on each text/voice/height/language/part change and
    /// after each write; NEVER per frame (`derivationCount` is the test's spy).
    func refresh() {
        let found = located
        derivationCount += 1
        derivedClipStartBeat = found?.clip.startBeat ?? 0
        preview = SingSheetPreview.make(clip: found?.clip, track: found?.track, text: text, language: language,
                                        octaveShift: height?.octaveShift ?? 0,
                                        tempoMap: store.transport.tempoMap, meterMap: store.transport.meterMap)
        refreshWordless(found?.clip)
        refreshHarmony(found)
    }

    /// An error's own sentence, never a paraphrase (`SingScreenWords`: `.sentence` for the refusal types, then
    /// `LocalizedError`).
    static func words(_ error: any Error) -> String { SingScreenWords.sentence(error) }
}

// MARK: - The height budget

/// The Sing sheet's height budget (docs/DESIGN-LANGUAGE.md "Centered modal cards": the ceiling comes from the
/// window, and exactly ONE region yields: the notices under the words). Every other region is fixed.
///
/// ⚠️ [A] `sheetFixedChrome` is an ESTIMATE summed from the layout's own constants, NOT a measurement: the design
/// language's rule is to measure it from the running app (`debug.explainFrames`, two notice counts, then the window
/// floor). The p2-sing-f dogfood script does that and replaces this number; until then only this constant can make
/// the card overflow.
public enum SingCardLayout {
    public static let sheetFixedChrome = 430.0
    public static let windowMargin = 40.0
    /// Two lines of notices always show.
    public static let noticesFloor = 32.0

    public static func noticesRoom(windowHeight: Double) -> Double {
        max(noticesFloor, windowHeight - 2 * windowMargin - sheetFixedChrome)
    }

    // p2-sing-x8: the expansion's regions are FIXED, computed heights too (the notices stay the ONE region that
    // yields). ⚠️ [A] every constant below is an ESTIMATE from the views' own frames, replaced by the look half's
    // measurement (`debug.explainFrames`), exactly like `sheetFixedChrome`.

    /// The language row over the words box.
    public static let languageRow = 30.0
    /// "No words? Sing: Ooh · Aah · Mm" and "Write words for me", one row under the box.
    public static let wordsToolsRow = 30.0
    /// The theme field "Write words for me" opens, with its line under it.
    public static let writeWordsOpen = 52.0
    /// The Expression card, closed ("Style: Vibrato Normal" by default) and open (vibrato row, air row, loudness row, hint).
    public static let expressionClosed = 34.0
    public static let expressionOpen = 176.0
    /// The Harmony card's header + [Add a harmony], one part row, and the key line.
    public static let harmonyHeader = 58.0
    public static let harmonyPartRow = 40.0
    public static let harmonyKeyLine = 22.0

    /// The fixed chrome for the sheet as it stands: SF's base plus each expansion region in its current state.
    public static func sheetChrome(expressionOpen open: Bool, partCount: Int, writeWordsOpen theme: Bool) -> Double {
        sheetFixedChrome + languageRow + wordsToolsRow + (theme ? writeWordsOpen : 0)
            + (open ? expressionOpen : expressionClosed)
            + harmonyHeader + Double(max(0, partCount)) * harmonyPartRow + (partCount > 0 ? harmonyKeyLine : 0)
    }

    /// The notices' room with the expansion's regions in place: still from the window, never a constant ceiling.
    public static func noticesRoom(windowHeight: Double, expressionOpen: Bool, partCount: Int,
                                   writeWordsOpen: Bool) -> Double {
        max(noticesFloor, windowHeight - 2 * windowMargin
            - sheetChrome(expressionOpen: expressionOpen, partCount: partCount, writeWordsOpen: writeWordsOpen))
    }
}
