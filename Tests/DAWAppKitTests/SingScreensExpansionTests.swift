import AIServices
import DAWAppKit
import DAWCore
import Foundation
import Testing

/// p2-sing-x8 (design `docs/design/2026-10-06-p2-sing-expansion.md` §3.1, §4.1, §5.1, §6.1, §8.1-§8.3, §14): the Sing
/// sheet expansion's PURE halves. NOT `@MainActor` (the cap): the store-backed halves are appended to
/// `GenerationPresenceModelTests` (its "p2-sing-x8" section). Never a real engine, provider, network or microphone.
@Suite struct SingScreensExpansionTests {

    // MARK: §14 copy, VERBATIM

    @Test func copyKeepsTheSection14RowsVerbatim() {
        #expect(SingCopy.noteWordPlaceholder == "Word on this note")
        #expect(SingCopy.noteWordHint == "Type + to hold the word before onto this note.")
        #expect(SingCopy.languageLabel == "Language")
        #expect(SingCopy.languageName(nil) == "English")
        #expect(SingCopy.languageName("en") == "English")
        #expect(SingCopy.languageName("zh") == "Chinese (Mandarin)")
        #expect(SingCopy.languageName("yue") == "Chinese (Cantonese)")
        #expect(SingCopy.wordlessLead + " " + WordlessLyrics.Sound.allCases.map(SingCopy.wordlessSound)
            .joined(separator: " · ") == "No words? Sing: Ooh · Aah · Mm")
        #expect(SingCopy.wordlessPerLine == "One sound per line")
        #expect(SingCopy.wordlessPerNote == "One per note")
        #expect(SingCopy.writeWordsForMe == "Write words for me")
        #expect(SingCopy.writingWords == "Writing words that fit your tune…")
        #expect(SingCopy.addHarmony == "Add a harmony")
        #expect([SingCopy.harmonyThirdAbove, SingCopy.harmonySixthBelow, SingCopy.harmonyThirdBelow,
                 SingCopy.harmonyOtherMelody, SingCopy.harmonyChordNotes]
                == ["A third above (sweet, close)", "A sixth below (warm, under the tune)", "A third below",
                    "Sing my other melody…", "Sing the chord's other notes"])
        #expect(SingCopy.styleAsSung == "Style: as sung")
        #expect(SingCopy.vibratoLabel == "Vibrato")
        #expect(SingStyle.Vibrato.allCases.map(SingCopy.vibratoName)
                == ["As sung", "Straight", "Gentle", "Normal", "Wide"])
        #expect(SingCopy.vibratoHelp == "Vibrato is the gentle wobble singers put on long notes.")
        #expect(SingCopy.airLabel == "Air (breathiness)")
        #expect(SingCopy.airNone == "None")
        #expect(SingCopy.airLots == "Lots")
        #expect(SingCopy.airHelp == "Adds a soft breathy layer to the notes you choose.")
        #expect(SingCopy.followLoudness == "Follow note loudness")
        #expect(SingCopy.followLoudnessHelp == "Quieter notes in your melody are sung quieter.")
        #expect(SingCopy.notesSelected(3) == "3 notes selected")
        #expect(SingCopy.afterStyledTake == "You can fine-tune the wobble on any note in the pitch editor.")
    }

    @Test func sentencesWithAHomeAreReadFromItVerbatim() {
        // Each of these is §14's row, read from the type that says it on the wire too.
        #expect(LyricEditRefusal.noteNotSung(noteID: UUID()).sentence
                == "This note isn't sung: it is part of a chord, or no words reach this line yet.")
        #expect(LyricEditRefusal.wordHasSpace(word: "a b").sentence
                == "Type one word per note. To type several, use the words box.")
        #expect(LyricEditRefusal.noText.sentence == "Type the words in the box first; then you can change single notes.")
        #expect(LyricEditRefusal.unstable.sentence
                == "I couldn't place that word without moving others. Type the line in the box instead.")
        #expect(HarmonyRefusal.needsKey.sentence
                == "I couldn't tell this song's key. Pick the key, and I'll work out the harmony.")
        #expect(SingScreenWords.sentence(SingJobError.tooManyParts(maximum: SingJobPart.maximumCount))
                == "You can add up to 3 harmony parts.")
        #expect(SingJobCoordinator.Copy.singingPart(2, of: 3, line: 1, of: 4) == "Singing part 2 of 3 · line 1 of 4…")
        #expect(LyricsFit.Copy.notFit(lines: [2]) == "Some lines didn't fit the tune: 2. Edit them, or try again.")
        #expect(LyricLanguage.Copy.scriptMismatch == "These look like Chinese characters. Set Language to Chinese "
                + "(Mandarin) or Chinese (Cantonese), and I'll sing them.")
    }

    @Test func refusalsReadAsTheirSentencesNotTheirCaseNames() {
        // A `LyricEditRefusal` is not a `LocalizedError`: without `SingScreenWords` it would read "wordHasSpace(…)".
        #expect(SingScreenWords.sentence(LyricEditRefusal.wordHasSpace(word: "a b"))
                == LyricEditRefusal.wordHasSpace(word: "a b").sentence)
        #expect(SingScreenWords.sentence(SingStyleRefusal.loopLayerNotes) == SingStyleRefusal.loopLayerNotes.sentence)
        #expect(SingScreenWords.sentence(HarmonyRefusal.needsKey) == HarmonyRefusal.needsKey.sentence)
        #expect(SingScreenWords.sentence(SingInstallPreflight.Copy.unsupportedMac)
                == SingInstallPreflight.Copy.unsupportedMac.sentence)
        // Control: a LocalizedError still reads as its description.
        #expect(SingScreenWords.sentence(SingJobError.queueFull(capacity: 1))
                == SingJobError.queueFull(capacity: 1).errorDescription)
    }

    // MARK: Language (§6.1, §6.7)

    @Test func languagePickerListsEnglishAndTheTwoChineseNeverSpanish() {
        #expect(SingCopy.languageCodes == ["en", "zh", "yue"])
        #expect(SingCopy.languageCodes.allSatisfy { LyricLanguage.isSupported($0) })
        #expect(!SingCopy.languageCodes.contains("es"))
        #expect(!SingCopy.languageCodes.map(SingCopy.languageName).contains { $0.contains("Spanish") })
    }

    @Test func previewPlansInThePickersLanguage() {
        let (track, clip) = SingSheetFixture.melody(pitches: [60, 62, 64, 65])
        let tempo = TempoMap(constantBPM: 120)
        let meter = MeterMap(constant: TimeSignature())
        let english = SingSheetPreview.make(clip: clip, track: track, text: "我爱你们", language: nil, octaveShift: 0,
                                           tempoMap: tempo, meterMap: meter)
        #expect(english.refusal == LyricLanguage.Copy.scriptMismatch)
        let mandarin = SingSheetPreview.make(clip: clip, track: track, text: "我爱你们", language: "zh",
                                            octaveShift: 0, tempoMap: tempo, meterMap: meter)
        #expect(mandarin.refusal == nil)
        #expect(mandarin.chips.map(\.text) == ["我", "爱", "你", "们"])
        // The old entry point plans in the clip's own language (nil here: English), unchanged.
        let old = SingSheetPreview.make(clip: clip, track: track, text: "我爱你们", octaveShift: 0, tempoMap: tempo,
                                       meterMap: meter)
        #expect(old.refusal == english.refusal)
    }

    // MARK: The glow's lookup (§8.2)

    @Test func chipLookupFindsTheChipUnderABeatAndNothingBetween() {
        let (track, clip) = SingSheetFixture.melody(pitches: [60, 62, 64, 65])
        let preview = SingSheetPreview.make(clip: clip, track: track, text: "one two three four", octaveShift: 0,
                                            tempoMap: TempoMap(constantBPM: 120),
                                            meterMap: MeterMap(constant: TimeSignature()))
        #expect(preview.chips.count == 4)
        #expect(preview.chipID(atClipBeat: 0) == 0)
        #expect(preview.chipID(atClipBeat: 1.5) == 1)
        #expect(preview.chipID(atClipBeat: 3.99) == 3)
        #expect(preview.chipID(atClipBeat: 4) == nil)
        #expect(preview.chipID(atClipBeat: -0.5) == nil)
        // Each chip names the notes it sings (the note field opens on the first).
        #expect(preview.chips.map(\.noteIDs.count) == [1, 1, 1, 1])
        #expect(preview.chips.first?.noteIDs.first == preview.notes.first?.id)
    }

    // MARK: Harmony (§4.1)

    @Test func harmonyChoicesUseTheWiresDefaults() {
        #expect(SingHarmonyChoice.thirdAbove.kind
                == .harmony(HarmonySpec(interval: .third, direction: .above, chordSource: .auto)))
        #expect(SingHarmonyChoice.sixthBelow.kind
                == .harmony(HarmonySpec(interval: .sixth, direction: .below, chordSource: .auto)))
        #expect(SingHarmonyChoice.thirdBelow.kind
                == .harmony(HarmonySpec(interval: .third, direction: .below, chordSource: .auto)))
        // `sing.render {parts: [{kind: "chordTones"}]}`'s defaults (SingWire `renderPart`).
        #expect(SingHarmonyChoice.chordNotes.kind == .chordTones(rank: .second, fillInterval: .third,
                                                                  fillChordSource: .auto))
        #expect(SingHarmony.name(of: SingHarmonyChoice.thirdAbove.kind, tracks: []) == "third above")
        #expect(SingHarmony.name(of: SingHarmonyChoice.chordNotes.kind, tracks: [])
                == SingJobCoordinator.Copy.chordNotesPartName)
    }

    @Test func chordNotesAreOfferedOnlyWhenTheTuneHasChords() {
        let (plainTrack, plain) = SingSheetFixture.melody(pitches: [60, 62, 64, 65])
        #expect(!SingHarmony.tuneHasChords(clip: plain, on: plainTrack, tracks: [plainTrack]))
        // A C major chord under the first melody note.
        var notes = plain.notes ?? []
        notes[0] = MIDINote(pitch: 72, startBeat: 0)
        notes += [MIDINote(pitch: 64, startBeat: 0), MIDINote(pitch: 67, startBeat: 0)]
        let chorded = Clip(name: "Melody", startBeat: 0, lengthBeats: 4, notes: notes)
        let chordTrack = Track(name: "Lead", kind: .instrument, clips: [chorded])
        #expect(SingHarmony.tuneHasChords(clip: chorded, on: chordTrack, tracks: [chordTrack]))
    }

    @Test func harmonyRowsComeFromTheCoordinatorsOwnCalls() throws {
        let (track, clip) = SingSheetFixture.melody(pitches: [60, 62, 64, 65, 67, 65, 64, 62])
        let tempo = TempoMap(constantBPM: 120)
        let key = SongKey(tonicPitchClass: 0, mode: .major)
        let part = SingHarmonyPart(kind: SingHarmonyChoice.thirdAbove.kind)
        let row = SingHarmony.row(part: part, index: 1, clip: clip, track: track, tracks: [track], tempoMap: tempo,
                                  givenKey: key, voiceName: "Built-in singer",
                                  voiceRange: SingVoiceLibrary.builtInRange, leadOctaveShift: 0)
        // The oracle: the coordinator's two calls, made here by hand.
        let plan = try SungVocalDerivedPart.derive(.harmony(HarmonySpec(interval: .third, direction: .above,
                                                                         chordSource: .auto)),
                                                   givenKey: key, partIndex: 1, clip: clip, on: track,
                                                   tracks: [track], tempoMap: tempo)
        let range = HarmonyPlanner.range(of: plan, clipStartBeat: 0, tempoMap: tempo,
                                         voice: SingVoiceLibrary.builtInRange, leadOctaveShift: 0)
        #expect(row.refusal == nil)
        #expect(row.rangeLine == range.sentence)
        #expect(row.rangeLine != nil)
        #expect(row.fits == range.fits)
        #expect(row.name == "third above")
        #expect(row.voiceName == "Built-in singer")
        // Another clip that is gone reads as the coordinator's own refusal.
        let gone = UUID()
        let missing = SingHarmony.row(part: SingHarmonyPart(kind: .clip(gone)), index: 1, clip: clip, track: track,
                                      tracks: [track], tempoMap: tempo, givenKey: nil, voiceName: "x",
                                      voiceRange: nil, leadOctaveShift: 0)
        #expect(missing.refusal == SingJobError.partClipNotFound(gone).errorDescription)
    }

    @Test func aKeyIsNeededOnlyForAHarmonyOrChordNotesPart() {
        let (track, _) = SingSheetFixture.melody(pitches: [60, 62, 64, 65])
        let tempo = TempoMap(constantBPM: 120)
        #expect(SingHarmony.keyState(kinds: [.clip(UUID()), .double], given: nil, tracks: [track], tempoMap: tempo)
                == .notNeeded)
        let given = SongKey(tonicPitchClass: 9, mode: .minor)
        #expect(SingHarmony.keyState(kinds: [SingHarmonyChoice.thirdAbove.kind], given: given, tracks: [track],
                                     tempoMap: tempo) == .given(given))
        #expect(SingHarmonyKeyState.unknown.line == HarmonyRefusal.needsKey.sentence)
        #expect(SingHarmonyKeyState.notNeeded.line == nil)
    }

    // MARK: The height budget (DESIGN-LANGUAGE "WHICH region yields")

    @Test func sheetChromeGrowsWithEachRegionAndTheNoticesStillYield() {
        let closed = SingCardLayout.sheetChrome(expressionOpen: false, partCount: 0, writeWordsOpen: false)
        #expect(closed == SingCardLayout.sheetFixedChrome + SingCardLayout.languageRow + SingCardLayout.wordsToolsRow
                + SingCardLayout.expressionClosed + SingCardLayout.harmonyHeader)
        let open = SingCardLayout.sheetChrome(expressionOpen: true, partCount: 3, writeWordsOpen: true)
        #expect(open == closed - SingCardLayout.expressionClosed + SingCardLayout.expressionOpen
                + 3 * SingCardLayout.harmonyPartRow + SingCardLayout.harmonyKeyLine + SingCardLayout.writeWordsOpen)
        // The room comes from the window, with the floor as a valve.
        let tall = SingCardLayout.noticesRoom(windowHeight: 1400, expressionOpen: false, partCount: 0,
                                              writeWordsOpen: false)
        #expect(tall == 1400 - 2 * SingCardLayout.windowMargin - closed)
        #expect(SingCardLayout.noticesRoom(windowHeight: 500, expressionOpen: true, partCount: 3,
                                           writeWordsOpen: true) == SingCardLayout.noticesFloor)
    }

    // MARK: Expression summary (§5.1)

    /// W9-PICKS (round V): a vibrato nobody chose is the default, Normal, and the line names it; "Style: as sung" is
    /// what a chosen As sung reads.
    @Test func styleSummaryNamesTheDefaultVibratoUntilSomethingIsSet() {
        #expect(SingCopy.styleSummary(vibrato: nil, air: nil, follows: false, notesStyled: 0) == "Style: Vibrato Normal")
        #expect(SingCopy.styleSummary(vibrato: .asSung, air: 0, follows: false, notesStyled: 0) == "Style: as sung")
        #expect(SingCopy.styleSummary(vibrato: .wide, air: 0.2, follows: false, notesStyled: 0)
                == "Style: Vibrato Wide, Air a little")
        #expect(SingCopy.styleSummary(vibrato: nil, air: nil, follows: true, notesStyled: 2)
                == "Style: Vibrato Normal, Follows note loudness, 2 notes styled")
        #expect(SingCopy.styleSummary(vibrato: .asSung, air: nil, follows: true, notesStyled: 2)
                == "Style: Follows note loudness, 2 notes styled")
    }

    // MARK: The two hand mirrors (W8-SF's filing): a test that SEES BOTH HOMES

    /// `SingSheetModel.undoLabel` mirrors `SingWireHandlers.setLyricsUndoLabel`, and `SingSheetPreview.melodyForFit`
    /// mirrors `SingWireHandlers.melodyForFit`. DAWAppKit cannot import DAWControl and no test target links both
    /// (Package.swift), so this reads the wire's SOURCE: the label's literal must equal the sheet's value, and the two
    /// `melodyForFit` bodies must match token for token (whitespace aside).
    @Test func wiresHandMirrorsAreEqual() async throws {
        let wire = try Self.source("DAWControl/SingWire.swift")
        let sheet = try Self.source("DAWAppKit/SingSheetModel.swift")

        let label = try Regex(#"static let setLyricsUndoLabel = "([^"]*)""#)
        let found = wire.matches(of: label).compactMap { $0.output[1].substring.map(String.init) }
        #expect(found.count == 1, "the wire's undo label literal was not found exactly once (\(found.count))")
        let sheetLabel = await MainActor.run { SingSheetModel.undoLabel }
        #expect(found.first == sheetLabel)

        let signature = "func melodyForFit(_ clip: Clip, tempoMap: TempoMap) -> [VoiceRangeFit.MelodyNote]"
        let wireBody = try #require(Self.body(after: signature, in: wire))
        let sheetBody = try #require(Self.body(after: signature, in: sheet))
        // Positive control: the extraction found the real formula, not an empty pair of braces.
        #expect(wireBody.contains("VoiceRangeFit.MelodyNote(midi:"))
        #expect(wireBody.count > 80)
        #expect(Self.squeezed(wireBody) == Self.squeezed(sheetBody))
    }

    /// The body (braces included) of the first function whose declaration contains `signature`.
    static func body(after signature: String, in source: String) -> String? {
        guard let at = source.range(of: signature), let open = source[at.upperBound...].firstIndex(of: "{") else {
            return nil
        }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    static func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    static func source(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(relative).path) {
                return try String(contentsOf: candidate.appendingPathComponent(relative), encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

// MARK: - Fakes for the appended MainActor tests (GenerationPresenceModelTests, "p2-sing-x8")

/// THE style write, spied: records each edit, then calls the store's own `setSingStyle`, or throws as told.
@MainActor
final class SingStyleSpy: SingSheetStyleWriting {
    private(set) var edits: [SingStyleEdit] = []
    var refusal: SingStyleRefusal?
    let store: ProjectStore
    init(store: ProjectStore) { self.store = store }
    func setSingStyle(clipId: UUID, edit: SingStyleEdit) throws -> SingStyleWriteResult {
        edits.append(edit)
        if let refusal { throw refusal }
        return try store.setSingStyle(clipId: clipId, edit: edit)
    }
}

/// A lyrics writer that never reaches a provider: it answers from a list and records what it was asked.
actor SingFakeWriter: LyricsGenerating {
    private var replies: [String]
    private(set) var requests: [LyricsWriteRequest] = []

    init(replies: [String]) { self.replies = replies }

    func generateLyrics(theme: String, style: String?) async throws -> String { "" }

    func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult {
        requests.append(request)
        let reply = replies.isEmpty ? "" : replies.removeFirst()
        return LyricsWriteResult(lyrics: reply, provider: "fake")
    }
}

/// The narrowest engine (the `BreathPadHardwareModelTests.SpyEngine` shape) that COUNTS `tracksDidChange`: the one
/// engine push a lyrics or style write makes inside its `performEdit`.
@MainActor
final class SingCountingEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted
    private(set) var tracksPushes = 0

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) { tracksPushes += 1 }
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
    func midiEventCount() -> Int { 0 }
    func availableMIDIInputs() -> [MIDIInputDevice] { [] }
    func setControlChangeObserver(_ observer: (@MainActor ([MIDIControlChangeEvent]) -> Void)?) {}
}
