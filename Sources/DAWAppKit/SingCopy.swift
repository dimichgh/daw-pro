import AIServices
import DAWCore
import Foundation

/// The Sing screens' words (p2-sing-f; design `docs/design/2026-09-27-p2-sing-integration.md` §5).
///
/// ONLY sentences with no other home live here. Every sentence that already has one is READ from it and never
/// retyped, so the screen and the wire cannot drift apart:
/// - the W > N / held words / chords / not English / no lyrics / drum track / audio clip / note too long lines:
///   `SingPlanRefusal.sentence`, `LyricRefusal.sentence`, `SingPlanWarning.sentence`;
/// - the height lines ("Fits your voice.", "…one octave lower…", the key change, "Keep the key"):
///   `KeyProposal.sentence` / `.alternativeSentence` (`VoiceRangeFit`);
/// - the progress lines ("Singing line i of n…", "Stopping after this line…", "Checking the words…"):
///   `SingJobCoordinator.Copy` and `SingJobStatus.stageText`;
/// - the results line: `SingJobCoordinator.Copy.results`;
/// - "Your voice sits around {note}…": `VoiceRangeFit.voiceSavedSentence`;
/// - the recording check's nine sentences: `SingVoiceAddRefusal.sentence` (`VoiceClipCheck.sentence`);
/// - "Built-in singer": `SingJobVoice.builtInName`; "My voice": `SingVoicePreparation.defaultName`.
///
/// Every constant below names its source: **VERBATIM §5.x** (a §5.7 row, or a §5.1–§5.6 quotation) or
/// **PROVISIONAL** (no row in §5; this lane's words, listed in the p2-sing-f report for the docs pass).
public enum SingCopy {

    // MARK: - Entry points (§5.1)

    /// VERBATIM §5.1 (the clip context menu item; the piano-roll chip reads `entryChip`).
    public static let menuTitle = "Sing these notes…"
    /// PROVISIONAL: the piano-roll header chip (the header's chips are short SF Mono capitals: QUANTIZE, HUMANIZE).
    public static let entryChip = "SING"
    /// PROVISIONAL: the chip's tooltip.
    public static let entryHelp = "Type words and hear them sung on this melody"

    // MARK: - The Sing sheet (§5.2)

    /// PROVISIONAL: the sheet's title (the house card header is a tracked capital word).
    public static let sheetTitle = "SING THESE NOTES"
    /// VERBATIM §5.2 section names ("Words.", "Voice.", "Height."), drawn as the card's capital labels.
    public static let wordsSection = "WORDS"
    public static let voiceSection = "VOICE"
    public static let heightSection = "HEIGHT"
    /// VERBATIM §5.2.
    public static let wordsPlaceholder = "Type the words to sing"
    /// VERBATIM §5.2.
    public static let holdLegend = "A + holds the word before it onto the next note."
    /// VERBATIM §5.2.
    public static let addYourVoice = "Add your voice…"
    /// VERBATIM §5.2 "[Move the song up 3]". The downward mirror is PROVISIONAL (§5.7 writes only "up").
    public static func moveSong(_ semitones: Int) -> String {
        semitones >= 0 ? "Move the song up \(semitones)" : "Move the song down \(abs(semitones))"
    }
    /// VERBATIM §5.2.
    public static let keepTheKey = "Keep the key"
    /// VERBATIM §5.2.
    public static let singIt = "Sing it"
    /// PROVISIONAL (design §3.5: "the UI words it as a suggestion" while `calibrated` is false).
    public static let suggestionCaption = "This is only a suggestion. I'm still checking how well it fits."
    /// PROVISIONAL: the confirm button under the transpose preview.
    public static let confirmMove = "Move the song"
    /// PROVISIONAL: the clip went away while the sheet was open (deleted, or another project opened).
    public static let clipGone = "This clip is no longer in the song. Pick a melody clip, then try again."
    /// PROVISIONAL: shown while the take is being handed to the singing engine.
    public static let submitting = "Starting…"
    /// VERBATIM §5.7 "Transpose preview".
    public static func transposePreview(instrumentTracks n: Int, recordedTracks m: Int) -> String {
        "This moves \(n) instrument tracks and \(m) recorded tracks. Drums stay as they are."
    }
    /// VERBATIM §5.7 "Transpose, audio".
    public static func transposeAudio(trackName: String) -> String {
        "Your recorded track '\(trackName)' will be pitch-shifted too, which can sound slightly processed."
    }

    // MARK: - Install / consent (§5.3, §2.5)

    /// VERBATIM §5.7 "Install card".
    public static let installCardBody = "To sing, DAW Pro needs its singing engine: a one-time download of about "
        + "7 GB. It runs on this Mac, and nothing you sing leaves it."
    /// VERBATIM §5.7 "Install card, agent-requested".
    public static let agentAsked = "An AI agent asked for this."
    /// PROVISIONAL: the install card's title.
    public static let installTitle = "SINGING ENGINE"
    /// VERBATIM §5.3.
    public static let install = "Install"
    /// VERBATIM §5.3.
    public static let notNow = "Not now"
    /// VERBATIM §5.3 / §5.5.
    public static let cancel = "Cancel"
    /// PROVISIONAL (§2.5 "works the same way"; no §5.7 row): the removal button, the wire's own word ("Nothing is
    /// deleted until Remove the engine is clicked"). "Remove the engine", not "Remove": it can sit beside a
    /// harmony part's own [Remove] (W8-DOC2 review).
    public static let remove = "Remove the engine"
    /// VERBATIM §5.7 "Install stopped".
    public static func installStopped(step: String, cause: String) -> String {
        let trimmed = cause.trimmingCharacters(in: .whitespacesAndNewlines)
        let stop = trimmed.hasSuffix(".") ? "" : "."
        return "Installing stopped at '\(step)': \(trimmed)\(stop)"
    }
    /// VERBATIM §5.7 "Install stopped" / "Engine won't start" ([Try again]).
    public static let tryAgain = "Try again"
    /// PROVISIONAL: the install's progress line (the wire's own `installingMessage` shape).
    public static func installing(step: Int, of count: Int, name: String) -> String {
        "Installing the singing engine: step \(step) of \(count) (\(name))…"
    }
    /// PROVISIONAL: before the first progress line arrives.
    public static let installStarting = "Installing the singing engine…"
    /// PROVISIONAL: after Cancel, until the install's own clean-up finishes.
    public static let installCancelling = "Stopping the install…"
    /// PROVISIONAL.
    public static let installCancelled = "The install was stopped. Nothing was kept."
    /// PROVISIONAL.
    public static let installDone = "The singing engine is installed. Press Sing it to hear your words."
    /// PROVISIONAL.
    public static let removing = "Removing the singing engine…"
    /// PROVISIONAL (the wire's own words for the same outcome, `sing.uninstallEngine`).
    public static let removed = "The singing engine was removed. Your voices and songs stay."
    /// PROVISIONAL.
    public static let done = "Done"

    // MARK: - The recorder (§5.4)

    /// VERBATIM §5.4's heading "Add your voice", as the card's capital title.
    public static let recorderTitle = "ADD YOUR VOICE"
    /// VERBATIM §5.4 step 1.
    public static let pickTune = "Pick the tune that's easiest for you."
    /// VERBATIM §5.4 step 1 ("[▶ Higher] [▶ Lower]").
    public static let higher = "Higher"
    public static let lower = "Lower"
    /// VERBATIM §5.4 step 2.
    public static let headphonesQuestion = "Are you wearing headphones?"
    public static let headphonesYes = "Yes — I'll sing along"
    public static let headphonesNo = "No — I'll listen first, then sing"
    /// VERBATIM §5.7 "Mic permission".
    public static let micPermission = "Your Mac will ask whether DAW Pro may use the microphone — click Allow."
    /// VERBATIM §5.7 "Mic denied".
    public static let micDenied = "DAW Pro isn't allowed to use the microphone. Open System Settings → Privacy & "
        + "Security → Microphone and turn on DAW Pro."
    /// VERBATIM §5.4 step 3's name.
    public static let record = "Record"
    /// VERBATIM §5.4 step 3.
    public static let getReady = "Get ready…"
    /// VERBATIM §5.4 step 3.
    public static let stop = "Stop"
    /// VERBATIM §5.4 step 3.
    public static let singNaturally = "Sing it at whatever height feels natural — you don't have to match the tune."
    /// PROVISIONAL: the no-headphones path plays the tune before recording.
    public static let listenFirst = "Listen to the tune first. Recording starts when it ends."
    /// PROVISIONAL: during the count-in and the singing.
    public static let singNow = "Sing now"
    /// PROVISIONAL (§5.4 step 4 "The check (~2 s)").
    public static let checking = "Checking your recording…"
    /// VERBATIM §5.4 step 4.
    public static let gotIt = "Got it!"
    public static let listen = "Listen"
    public static let nameLabel = "Name:"
    public static let save = "Save"
    public static let recordAgain = "Record again"
    /// PROVISIONAL.
    public static let saving = "Saving your voice…"
    /// VERBATIM §5.4 "Use a recording you already have… [Choose file]".
    public static let useExisting = "Use a recording you already have…"
    public static let chooseFile = "Choose file"
    /// PROVISIONAL: the song started playing during a recording (an agent's `transport.play`, or a key).
    public static let playbackInterrupted = "The song started playing, so I stopped recording. Nothing was "
        + "saved. Record again when it's quiet."
    /// PROVISIONAL: another project was opened during a recording (RT review F5: the recorder owns this).
    public static let projectChanged = "Another project was opened, so I stopped recording. Nothing was saved."
    /// PROVISIONAL: the project's own take is recording when the recorder wants the microphone.
    public static let takeIsRecording = "A take is being recorded in the song. Stop it, then record your voice."
    /// PROVISIONAL: the project's Record while the recorder is open (RT1's "refuse record() while open").
    public static let recorderIsOpen = "The voice recorder is open. Close it before recording in the song."
    /// PROVISIONAL: the engine ended the capture by itself (it shut down, say) before it finished.
    public static let recordingStopped = "The recording stopped before it finished. Nothing was saved. Record again."
    /// PROVISIONAL: a guide or the recording would not play.
    public static func cannotPlay(_ cause: String) -> String { "I couldn't play that: \(cause)" }
    /// PROVISIONAL: the bundled guide file is missing from this build.
    public static let guideMissing = "The guide tune is missing from this copy of DAW Pro, so it can't play. "
        + "You can still record: sing \"Row, row, row your boat, gently down the stream\"."

    // MARK: - Progress and results (§5.5, §5.6)

    /// VERBATIM §5.5 (the coordinator has "Checking the words…" but not this one).
    public static let checkingNotes = "Checking the notes…"
    /// VERBATIM §5.6.
    public static let playFromHere = "Play from here"
    public static let tryAnotherTake = "Try another take"
    public static let chooseDifferentVoice = "Choose a different voice"
    /// VERBATIM §5.6.
    public static let firstTakeTip = "Turn the melody track down to hear the voice clearly."
    /// PROVISIONAL (§5.5 "an ETA"): SF Mono in the card.
    public static func eta(seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return String(format: "about %d:%02d left", whole / 60, whole % 60)
    }
    /// PROVISIONAL: the results card's title.
    public static let takeTitle = "SUNG TAKE"

    // MARK: - The singing expansion (design `docs/design/2026-10-06-p2-sing-expansion.md` §14), p2-sing-x8
    //
    // Sentences that already have a home are READ from it, never retyped here:
    // - the note field's refusals ("This note isn't sung…", "Type one word per note…", "Type the words in the box
    //   first…", "I couldn't place that word…"): `LyricEditRefusal.sentence`;
    // - the language refusals (§6.7): `LyricLanguage.Copy` through `LyricRefusal.sentence`;
    // - "Fits your voice." / "I'll sing this part an octave lower." / the out-of-range lines: `HarmonyRange.sentence`;
    // - "I couldn't tell this song's key…": `HarmonyRefusal.needsKey.sentence`;
    // - "You can add up to 3 harmony parts.": `SingJobError.tooManyParts(maximum:)`;
    // - "Singing part {p} of {P} · line {i} of {n}…": the coordinator's `stageText` (`Copy.singingPart`);
    // - "Some lines didn't fit the tune: {lines}…": `LyricsFit.Copy.notFit(lines:)`;
    // - the style refusals (the looper's included): `SingStyleRefusal.sentence`;
    // - the install pre-check's two refusals: `SingInstallPreflight.Copy`.

    /// VERBATIM §14 "Note field placeholder".
    public static let noteWordPlaceholder = "Word on this note"
    /// VERBATIM §14 "Note field hint".
    public static let noteWordHint = "Type + to hold the word before onto this note."

    /// VERBATIM §14 "Language" (the label; the picker reads "Language: English ▾", §6.1).
    public static let languageLabel = "Language"
    /// VERBATIM §14 "Language": the names. Spanish is OUT of this round (the orchestrator's scope cut), so it has no
    /// name here and `languageCodes` never lists it.
    public static func languageName(_ code: String?) -> String {
        guard let stored = LyricLanguage.stored(code) else { return "English" }
        if stored == LyricLanguage.mandarin { return "Chinese (Mandarin)" }
        if stored == LyricLanguage.cantonese { return "Chinese (Cantonese)" }
        return stored   // never offered; an unsupported stored code reads as itself
    }
    /// The picker's list, from `LyricLanguage` (THE one home of the codes): English, then the Chinese codes.
    public static var languageCodes: [String] { [LyricLanguage.english] + LyricLanguage.chinese }

    /// VERBATIM §14 "Singing without words".
    public static let wordlessLead = "No words? Sing:"
    public static func wordlessSound(_ sound: WordlessLyrics.Sound) -> String {
        switch sound {
        case .ooh: return "Ooh"
        case .aah: return "Aah"
        case .mm: return "Mm"
        }
    }
    /// VERBATIM §14.
    public static let wordlessPerLine = "One sound per line"
    /// VERBATIM §14.
    public static let wordlessPerNote = "One per note"

    /// VERBATIM §14 "Write words for me".
    public static let writeWordsForMe = "Write words for me"
    /// VERBATIM §14.
    public static let writingWords = "Writing words that fit your tune…"
    /// PROVISIONAL: the theme field the writer needs (`LyricsWriteRequest.prompt` is required).
    public static let writeWordsThemePlaceholder = "What should the words be about?"
    /// PROVISIONAL: the theme field's button.
    public static let writeWordsGo = "Write"
    /// PROVISIONAL: the theme field's ✕ (its tooltip).
    public static let writeWordsClose = "Close without writing"

    /// VERBATIM §14 "Harmony card".
    public static let harmonySection = "HARMONY"
    /// VERBATIM §14 "[Add a harmony]".
    public static let addHarmony = "Add a harmony"
    /// VERBATIM §14 "Harmony choices".
    public static let harmonyThirdAbove = "A third above (sweet, close)"
    public static let harmonySixthBelow = "A sixth below (warm, under the tune)"
    public static let harmonyThirdBelow = "A third below"
    public static let harmonyOtherMelody = "Sing my other melody…"
    public static let harmonyChordNotes = "Sing the chord's other notes"
    /// PROVISIONAL: a clip in "Sing my other melody…", named with its track so two "Melody" clips differ.
    public static func otherMelody(clip: String, track: String) -> String { "\(clip) (on \(track))" }
    /// PROVISIONAL: no other melody clip to sing.
    public static let noOtherMelody = "No other melody clip in the song yet."
    /// VERBATIM §4.1 "[Remove]".
    public static let removePart = "Remove"
    /// PROVISIONAL: the key line over the parts.
    public static func harmonyKey(_ name: String, worked: Bool) -> String {
        worked ? "Key: \(name) (worked out from the song)" : "Key: \(name)"
    }
    /// PROVISIONAL: the key menu before any key is known.
    public static let pickKey = "Pick the key"
    /// PROVISIONAL: the key menu's item that goes back to the worked-out key.
    public static let keyFromSong = "Work it out from the song"

    /// VERBATIM §14 "Expression card, closed".
    public static let styleAsSung = "Style: as sung"
    /// PROVISIONAL: the card's capital label.
    public static let expressionSection = "EXPRESSION"
    /// VERBATIM §14 "Vibrato".
    public static let vibratoLabel = "Vibrato"
    public static func vibratoName(_ vibrato: SingStyle.Vibrato) -> String {
        switch vibrato {
        case .asSung: return "As sung"
        case .straight: return "Straight"
        case .gentle: return "Gentle"
        case .normal: return "Normal"
        case .wide: return "Wide"
        }
    }
    /// VERBATIM §14.
    public static let vibratoHelp = "Vibrato is the gentle wobble singers put on long notes."
    /// VERBATIM §14 "Air".
    public static let airLabel = "Air (breathiness)"
    public static let airNone = "None"
    public static let airLots = "Lots"
    /// VERBATIM §14.
    public static let airHelp = "Adds a soft breathy layer to the notes you choose."
    /// PROVISIONAL (§5.1's example "Air a little"): an air amount in words.
    public static func airWords(_ air: Double) -> String {
        switch air {
        case ..<0.005: return "none"
        case ..<0.34: return "a little"
        case ..<0.67: return "some"
        default: return "lots"
        }
    }
    /// VERBATIM §14 "Follow note loudness".
    public static let followLoudness = "Follow note loudness"
    public static let followLoudnessHelp = "Quieter notes in your melody are sung quieter."
    /// PROVISIONAL: the toggle while notes are picked (`NoteSingStyle` has no loudness choice).
    public static let followLoudnessIsClipWide = "Follow note loudness is for the whole vocal."
    /// VERBATIM §14 "Notes selected" ("{n} notes selected"); the one-note form is PROVISIONAL.
    public static func notesSelected(_ n: Int) -> String { n == 1 ? "1 note selected" : "\(n) notes selected" }
    /// PROVISIONAL: how to pick notes while the card is open.
    public static let pickNotesHint = "Click notes in the strip to style just those. With none picked, this styles "
        + "the whole vocal."
    /// PROVISIONAL.
    public static let clearSelection = "Style the whole vocal"
    /// PROVISIONAL (§5.1's example shape "Vibrato Wide, Air a little"): the closed card's line. A nil vibrato is the
    /// default one (`SingStyle.defaultVibrato`, "Vibrato Normal"); only a chosen "As sung" with nothing else set reads
    /// `styleAsSung`.
    public static func styleSummary(vibrato: SingStyle.Vibrato?, air: Double?, follows: Bool, notesStyled: Int) -> String {
        var parts: [String] = []
        let sung = vibrato ?? SingStyle.defaultVibrato
        if sung != .asSung { parts.append("Vibrato \(vibratoName(sung))") }
        if let air, air >= 0.005 { parts.append("Air \(airWords(air))") }
        if follows { parts.append("Follows note loudness") }
        if notesStyled > 0 { parts.append(notesStyled == 1 ? "1 note styled" : "\(notesStyled) notes styled") }
        return parts.isEmpty ? styleAsSung : "Style: " + parts.joined(separator: ", ")
    }
    /// VERBATIM §14 "After a styled take".
    public static let afterStyledTake = "You can fine-tune the wobble on any note in the pitch editor."

    /// PROVISIONAL (design §3.1/§8.2 need the melody to play while the sheet is open; the sheet is a modal, so the
    /// transport's keys do not reach it): play the melody from the clip's start, and stop.
    public static let playTune = "Play the tune"
    public static let stopTune = "Stop"
}

/// An error in its own words: every refusal type the Sing screens meet carries `.sentence`, and only some are
/// `LocalizedError` (`SingJobError`, `ProjectError`, `SingInstallPreflight.Refusal`). Without this a
/// `LyricEditRefusal` would read as `String(describing:)`, which is not a sentence.
public enum SingScreenWords {
    public static func sentence(_ error: any Error) -> String {
        switch error {
        case let refusal as LyricEditRefusal: return refusal.sentence
        case let refusal as SingStyleRefusal: return refusal.sentence
        case let refusal as HarmonyRefusal: return refusal.sentence
        case let refusal as LyricRefusal: return refusal.sentence
        case let refusal as SingPlanRefusal: return refusal.sentence
        default: return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
