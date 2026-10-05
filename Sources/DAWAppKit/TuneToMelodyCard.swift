import DAWCore
import Foundation

// Tune to Melody, M3 (W7-TTM3; design `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md`
// §3.4 "UI", §3.3 for what the result can say) — THE CARD'S HEADLESS HALF: what the clip
// menu's Tune Vocal ▸ Tune to Melody… offers, what the card lists and picks, what Apply sends,
// and every word the card draws. `DAWApp` has no test target, so every decision lives here, as
// plain values, and the SwiftUI view only draws them (`TuneToMelodyCardView`).
//
// ⭐ **THE MENU AND THE STORE CANNOT DISAGREE.** The store refuses a melody with no note under
// the vocal by asking `MelodyTuning.notes(of:under:tempoMap:)` (empty → the teaching refusal).
// The menu item, the card's list and the count each row shows ask the SAME function, so an
// enabled item always leads to a melody the store accepts, and a disabled one is exactly the
// case the store would refuse. `TuneToMelodyCardTests` pins that equivalence over a grid of
// tempo changes, stretch ratios, offsets and edge-touching clips.
//
// ⭐ **NO SECOND POLICY.** The card sends `preset.options()` (the preset door's own options)
// and a `MelodyTuning` with no strength: rule 5 (strength 1 unless one is sent) is the store's,
// so the card, the wire and an agent get the same answer for the same preset. The card never
// computes a strength, a target or a count of its own; the result line is read off the store's
// `PitchMelodyReport`.

// MARK: - What the menu offers

/// The clip menu's **Tune Vocal ▸ Tune to Melody…** item, decided for one vocal.
public enum TuneToMelodyMenu {

    /// Enabled or not, and the sentence its tooltip carries.
    public struct Availability: Sendable, Equatable {
        public let isEnabled: Bool
        /// Enabled: what the item does. Disabled: what to do first.
        public let help: String

        public init(isEnabled: Bool, help: String) {
            self.isEnabled = isEnabled
            self.help = help
        }
    }

    /// The item for `vocal` in a project holding `tracks`. Enabled exactly when at least one
    /// MIDI note sounds under the vocal: `MelodyTuning.notes(of:under:tempoMap:)` non-empty for
    /// some MIDI clip, the store's own refusal test.
    ///
    /// ⚡ **CHEAP ON PURPOSE.** The clip menu's content is built with the block, and the block is
    /// rebuilt as the playhead moves, so this must not convert every note of every melody per
    /// rebuild. It first keeps the MIDI clips whose BEAT span overlaps the vocal's (a superset:
    /// a vocal source second is a strictly increasing function of the timeline beat,
    /// `MelodyTuning.sourceSeconds(atBeat:vocal:tempoMap:)`, and its window is the vocal's own
    /// beat span mapped through it, `Clip.sourceWindowSeconds`, so a note that overlaps the
    /// window in seconds overlaps the vocal in beats), then asks the store's function one clip at
    /// a time and stops at the first note.
    public static func availability(vocal: Clip, tracks: [Track],
                                    tempoMap: TempoMap) -> Availability {
        for track in tracks {
            for clip in track.clips where clip.isMIDI && overlapsInBeats(clip, vocal) {
                if !MelodyTuning.notes(of: [clip], under: vocal, tempoMap: tempoMap).isEmpty {
                    return Availability(isEnabled: true, help: TuneToMelodyCopy.menuHelp)
                }
            }
        }
        return Availability(isEnabled: false, help: TuneToMelodyCopy.noMelodyUnderVocal)
    }

    /// The MIDI clip's beat span overlaps the vocal's by more than nothing. A clip that only
    /// touches the vocal's edge sounds nothing under it.
    static func overlapsInBeats(_ clip: Clip, _ vocal: Clip) -> Bool {
        clip.startBeat < vocal.startBeat + vocal.lengthBeats
            && clip.startBeat + clip.lengthBeats > vocal.startBeat
    }
}

// MARK: - What the card lists

/// One melody the card offers: a whole MIDI track, or one of its clips.
public struct TuneToMelodyChoice: Sendable, Equatable, Identifiable {
    /// What Apply sends the store.
    public let source: MelodySource
    /// The track's name, or the clip's.
    public let name: String
    /// The track it lives on (its own name for a track choice).
    public let trackName: String
    /// The MIDI notes of this melody that sound under the vocal, counted by the store's own
    /// function (`MelodyTuning.notes(of:under:tempoMap:)`): what the match will be given.
    public let notesUnderVocal: Int

    public init(source: MelodySource, name: String, trackName: String, notesUnderVocal: Int) {
        self.source = source
        self.name = name
        self.trackName = trackName
        self.notesUnderVocal = notesUnderVocal
    }

    public var isClip: Bool {
        if case .clip = source { return true }
        return false
    }

    /// Stable across rebuilds of the list: the kind and the id.
    public var id: String {
        switch source {
        case .track(let id): return "track:\(id.uuidString)"
        case .clip(let id): return "clip:\(id.uuidString)"
        }
    }

    /// Every melody under `vocal`, in the order the card draws them:
    ///  * one row per MIDI track with a note under the vocal (the store's `.track` source reads
    ///    ALL the track's MIDI clips, so this does too);
    ///  * that track's clips as their own rows, right under it, ONLY when two or more of them
    ///    have a note under the vocal. With one, the clip row would tune exactly what the track
    ///    row tunes (the store keeps only notes under the vocal), a choice that changes nothing;
    ///  * a track named "Lead" (any case, the name a generated song gives its melody track)
    ///    first, then the rest in the project's track order.
    public static func choices(vocal: Clip, tracks: [Track], tempoMap: TempoMap)
        -> [TuneToMelodyChoice] {
        var leads: [TuneToMelodyChoice] = []
        var others: [TuneToMelodyChoice] = []
        for track in tracks {
            let midi = track.clips.filter(\.isMIDI)
            guard !midi.isEmpty else { continue }
            let trackNotes = MelodyTuning.notes(of: midi, under: vocal, tempoMap: tempoMap)
            guard !trackNotes.isEmpty else { continue }
            var group = [TuneToMelodyChoice(source: .track(track.id), name: track.name,
                                            trackName: track.name,
                                            notesUnderVocal: trackNotes.count)]
            let clipRows = midi.compactMap { clip -> TuneToMelodyChoice? in
                let count = MelodyTuning.notes(of: [clip], under: vocal, tempoMap: tempoMap).count
                guard count > 0 else { return nil }
                return TuneToMelodyChoice(source: .clip(clip.id), name: clip.name,
                                          trackName: track.name, notesUnderVocal: count)
            }
            if clipRows.count >= 2 { group += clipRows }
            if isLeadName(track.name) { leads += group } else { others += group }
        }
        return leads + others
    }

    /// "Lead", in any case and with any surrounding spaces.
    static func isLeadName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Lead") == .orderedSame
    }
}

// MARK: - The card's state

/// What the card shows and what Apply sends: a plain value, so every decision is testable
/// without a window. `TuneToMelodyDoor` holds one while the card is up.
public struct TuneToMelodyCard: Sendable, Equatable {

    /// Where the card is in its one job.
    public enum Phase: Sendable, Equatable {
        /// Picking. Apply is live when a melody is picked.
        case choosing
        /// Apply was pressed on a vocal with hand edits: the "Replace your hand edits?" card
        /// (`PitchPresetReplaceGate`) is asking, and nothing has run.
        case waitingForAnswer
        /// The store is reading the voice and tuning it (seconds on a long take).
        case tuning
        /// It ran. The result line is the outcome's.
        case finished(TuneToMelodyOutcome)
        /// The store refused, in its own words (shown verbatim).
        case refused(String)
    }

    public let vocalClipID: UUID
    public let vocalName: String
    public let vocalTrackName: String
    /// The melodies under the vocal when the card opened (`TuneToMelodyChoice.choices`).
    public let choices: [TuneToMelodyChoice]
    /// The picked row's `id`, or nil when there is nothing to pick.
    public private(set) var selectedID: String?
    /// The preset chip: its retune speed, wobble and slides. Natural, as the menu's own
    /// recommendation.
    public private(set) var preset: PitchCorrectionPreset = .natural
    /// "Match octave": on = the melody's note in the octave nearest what was sung (rule 3's
    /// default), off = the note as written.
    public private(set) var matchOctave = true
    public private(set) var phase: Phase = .choosing

    /// A card for the vocal `vocal` on the track named `vocalTrackName`, listing the
    /// melodies under it, the first one picked.
    public init(vocal: Clip, vocalTrackName: String, tracks: [Track], tempoMap: TempoMap) {
        vocalClipID = vocal.id
        vocalName = vocal.name
        self.vocalTrackName = vocalTrackName
        choices = TuneToMelodyChoice.choices(vocal: vocal, tracks: tracks, tempoMap: tempoMap)
        selectedID = choices.first?.id
    }

    /// The presets the chips offer: the menu's own list, in its order.
    public static let presets = PitchCorrectionPreset.offeredInUI

    public var selected: TuneToMelodyChoice? {
        choices.first { $0.id == selectedID }
    }

    /// Apply is live: a melody is picked and nothing is running or asking.
    public var canApply: Bool {
        guard selected != nil else { return false }
        switch phase {
        case .tuning, .waitingForAnswer: return false
        case .choosing, .finished, .refused: return true
        }
    }

    /// Close is live: everything but a run in flight or a question the replace card is still
    /// asking. The store cannot be stopped mid-run, and a result (or a refusal) landing on a
    /// card nobody can see would be a silent one.
    public var canClose: Bool { canEdit }

    /// The preset door's own options for the chip (chromatic). No strength of the card's own:
    /// the store's rule 5 runs a melody pass at 1.
    public var options: PitchAutoCorrectOptions { preset.options() }

    /// What Apply sends as the melody, or nil with nothing picked.
    public var melodyTuning: MelodyTuning? {
        selected.map {
            MelodyTuning(source: $0.source,
                         octaveMatch: matchOctave ? .nearestOctave : .exact)
        }
    }

    // A change of any setting clears a result: a line about the LAST settings, beside
    // different ones, would describe something the person no longer has on screen.

    public mutating func select(_ id: String) {
        guard choices.contains(where: { $0.id == id }), canEdit else { return }
        selectedID = id
        settingChanged()
    }

    public mutating func choosePreset(_ preset: PitchCorrectionPreset) {
        guard Self.presets.contains(preset), canEdit else { return }
        self.preset = preset
        settingChanged()
    }

    public mutating func setMatchOctave(_ on: Bool) {
        guard canEdit else { return }
        matchOctave = on
        settingChanged()
    }

    /// Settings are frozen while a run is in flight or the replace card is asking: the
    /// request already sent must stay the one on screen.
    public var canEdit: Bool {
        switch phase {
        case .tuning, .waitingForAnswer: return false
        case .choosing, .finished, .refused: return true
        }
    }

    private mutating func settingChanged() {
        switch phase {
        case .finished, .refused: phase = .choosing
        case .choosing, .tuning, .waitingForAnswer: break
        }
    }

    // Phase moves, made by `TuneToMelodyDoor` only.

    mutating func markWaitingForAnswer() { phase = .waitingForAnswer }
    mutating func markTuning() { phase = .tuning }
    mutating func markDeclined() {
        if phase == .waitingForAnswer { phase = .choosing }
    }
    mutating func finish(_ outcome: TuneToMelodyOutcome) { phase = .finished(outcome) }
    mutating func refuse(_ message: String) { phase = .refused(message) }
}

// MARK: - What a run did

/// The result of one Apply, lifted off the store's report so the words can be built (and
/// tested) without a store.
public struct TuneToMelodyOutcome: Sendable, Equatable {
    /// The melody's name as the store read it (`PitchMelodyReport.sourceName`).
    public let melodyName: String
    /// A clip is named in quotes, a track bare (the Chop to Pads source-line convention).
    public let melodyIsClip: Bool
    /// The detector found singing and a table was stored. False: nothing was tuned at all.
    public let foundSinging: Bool
    /// SUNG notes tuned to the melody (`TuneToMelodySungNotes.tuned`): a sung note the melody
    /// cut in two is ONE note here, though the report counts its two pieces.
    public let tunedNotes: Int
    /// Sung notes with no melody note under them, left as sung (`TuneToMelodySungNotes`).
    public let untouchedNotes: Int
    /// Sung notes moved more than `PitchMelodyTarget.farMoveCents` (§3.3 row 7), each counted
    /// once however many of its pieces moved far (`TuneToMelodySungNotes`).
    public let farMoves: Int
    /// The pass ran with Match octave on (`.nearestOctave`).
    public let matchedOctave: Bool

    public init(melodyName: String, melodyIsClip: Bool, foundSinging: Bool, tunedNotes: Int,
                untouchedNotes: Int, farMoves: Int, matchedOctave: Bool) {
        self.melodyName = melodyName
        self.melodyIsClip = melodyIsClip
        self.foundSinging = foundSinging
        self.tunedNotes = tunedNotes
        self.untouchedNotes = untouchedNotes
        self.farMoves = farMoves
        self.matchedOctave = matchedOctave
    }

    /// Read off a melody pass's report. A pass that stored no table found no singing, whatever
    /// else it carries. nil only for a report with a table and no melody block (a pass without
    /// a melody, which the card never sends).
    public init?(report: PitchAutoCorrectReport) {
        guard let melody = report.melody else {
            guard report.clip.pitchEdits == nil else { return nil }
            self.init(melodyName: "", melodyIsClip: false, foundSinging: false, tunedNotes: 0,
                      untouchedNotes: 0, farMoves: 0, matchedOctave: true)
            return
        }
        let isClip: Bool
        if case .clip = melody.source { isClip = true } else { isClip = false }
        let sung = TuneToMelodySungNotes(matchedPieces: melody.matchedParts,
                                         cuts: melody.cutsAdded.map(\.segmentIds),
                                         unmatched: melody.unmatchedParts,
                                         farMoved: melody.farMoves.map(\.segmentId))
        self.init(melodyName: melody.sourceName, melodyIsClip: isClip,
                  foundSinging: report.clip.pitchEdits != nil,
                  tunedNotes: sung.tuned,
                  untouchedNotes: sung.untouched,
                  farMoves: sung.farMoved,
                  matchedOctave: melody.octaveMatch == .nearestOctave)
    }
}

/// The report's counts, turned from ROWS into the SUNG NOTES a person means by "notes".
///
/// ⚠️ **A ROW IS NOT A SUNG NOTE.** Where the melody changes under one held note, the pass cuts
/// it (rule 2) and tunes each piece to its own melody note: `PitchMelodyReport.matchedParts`
/// counts those pieces, so "Tuned 3 notes" was said of two sung notes (W7-TTM3, found reading
/// the report, pinned by `tuneToMelodyDoor D9`). The report gives every cut's two stored ids
/// (`cutsAdded[].segmentIds`), so the pieces of one sung note are exactly the ids its cuts
/// join: a component of that union is one sung note.
///
/// READ from `PitchMelodyTarget.pieces(of:…)`: every piece of a cut note takes a melody note
/// (its "Defensive" branch says a group's notes always overlap the note by 60 ms), so in
/// practice `tuned = matchedParts − cutsAdded.count`. The union is kept anyway so the count
/// stays true if a middle piece is ever left as sung (`TuneToMelodyCardTests` T11 covers it).
/// A cut whose ids the report could not give is taken at that invariant: two tuned pieces of
/// one note.
public struct TuneToMelodySungNotes: Sendable, Equatable {
    /// Sung notes with at least one piece tuned to the melody.
    public let tuned: Int
    /// Sung notes with no piece tuned: the melody rests under them.
    public let untouched: Int
    /// Sung notes with at least one piece moved far.
    public let farMoved: Int

    /// The three counts as given (for a test's expected value).
    init(tuned: Int, untouched: Int, farMoved: Int) {
        self.tuned = tuned
        self.untouched = untouched
        self.farMoved = farMoved
    }

    /// - Parameters:
    ///   - matchedPieces: rows tuned to the melody (`PitchMelodyReport.matchedParts`);
    ///   - cuts: each cut's stored ids, left first (`cutsAdded[].segmentIds`);
    ///   - unmatched: rows left as sung (`unmatchedParts`);
    ///   - farMoved: rows moved far (`farMoves[].segmentId`).
    public init(matchedPieces: Int, cuts: [[UUID]], unmatched: [UUID], farMoved: [UUID]) {
        // Union the ids each cut joins: one component per cut sung note.
        var parent: [UUID: UUID] = [:]
        func root(_ id: UUID) -> UUID {
            var node = id
            while let up = parent[node], up != node { node = up }
            return node
        }
        var unresolvedCuts = 0
        for ids in cuts {
            guard let first = ids.first, ids.count >= 2 else {
                unresolvedCuts += 1
                continue
            }
            if parent[first] == nil { parent[first] = first }
            for id in ids.dropFirst() {
                if parent[id] == nil { parent[id] = id }
                let a = root(first)
                let b = root(id)
                if a != b { parent[b] = a }
            }
        }
        let leftAsSung = Set(unmatched)
        var piecesInNote: [UUID: Int] = [:]
        var tunedPiecesInNote: [UUID: Int] = [:]
        for id in parent.keys {
            let note = root(id)
            piecesInNote[note, default: 0] += 1
            if !leftAsSung.contains(id) { tunedPiecesInNote[note, default: 0] += 1 }
        }
        // Each cut sung note with k tuned pieces was counted k times: count it once.
        let extraPieces = piecesInNote.keys.reduce(0) { sum, note in
            sum + max(0, (tunedPiecesInNote[note] ?? 0) - 1)
        } + unresolvedCuts
        self.tuned = max(0, matchedPieces - extraPieces)
        // A row left as sung is its own sung note unless a cut joins it to a tuned piece.
        self.untouched = Set(unmatched.map { parent[$0] == nil ? $0 : root($0) })
            .filter { (tunedPiecesInNote[$0] ?? 0) == 0 }.count
        self.farMoved = Set(farMoved.map { parent[$0] == nil ? $0 : root($0) }).count
    }
}

// MARK: - The words

/// Every word the menu item and the card draw: one home, read by the view and pinned (and
/// measured) by the tests. Written for someone who is not a musician.
///
/// ⚠️ **NEVER "EXACTLY ON THE MELODY".** M2 measured the detector reading a held note up to
/// ~7 cents off what was sung, and a tuned note lands that far off the melody. The words say
/// "tuned to the melody", never "exactly".
///
/// ⚠️ **THE CHIPS' LINES ARE THIS CARD'S OWN, NOT `PitchCorrectionPreset.summary`.** A melody
/// pass runs every preset at strength 1 (the store's rule 5: the person asked for the notes the
/// melody plays), so Gentle's own line, "Pulls notes halfway to pitch", would be false here.
/// `TuneToMelodyDoorTests` (D6) runs the real store and pins that premise.
///
/// ⭐ **WHAT A CHIP STILL CHANGES IN MELODY MODE IS MEASURED, NOT ASSUMED**
/// (`TuneToMelodyChipRenderTests`, the product detector and render, an independent tracker):
///  * On notes with a gap between them, Gentle, Natural and Tight render ALIKE (onset within
///    0.6 c, vibrato within 0.1 c). A first draft of these lines promised Gentle "eases onto each
///    note" and Tight "snaps the moment they start": both false, so neither is said.
///  * Where one note runs into the next AND the two were sung off by different amounts, a slower
///    chip lets more of the singing show through: mean error over the 100 ms either side of the
///    join 11.3 / 7.6 / 4.5 c (Gentle / Natural / Tight; untuned 35). Where both were off by the
///    same amount, nothing shows (6.1 / 6.2 / 6.2 c), hence "can show through", not "shows".
///  * Hard Tune is Tight at a join (4.3 c) and the only one that thins vibrato: a ±35 c
///    vibrato reads 23 c after it (36 before), with or without a melody. "Less vibrato", never
///    "flattened" or "steady": it does not remove it.
public enum TuneToMelodyCopy {

    /// The action's name, in a sentence ("Tune to Melody tunes all of …" on the replace card).
    public static let actionName = "Tune to Melody"

    // The menu item.
    public static let menuTitle = actionName + "…"
    public static let menuHelp = "Tune each sung note to the MIDI melody playing under it."
    /// The disabled item's reason (§3.4), and the card's line when nothing is under the vocal.
    public static let noMelodyUnderVocal = "Add a MIDI melody under this vocal first."

    // The card.
    public static let title = "TUNE TO MELODY"
    public static let closeHelp = "Close. Anything already tuned stays tuned."
    public static let intro = "Each sung note moves to the melody note playing under it. "
        + "Your timing stays as you sang it."
    public static let melodyLabel = "Tune to"
    public static let soundLabel = "How it sounds"
    public static let octaveLabel = "Match octave"
    public static let octaveOnLine = "Each note goes to the melody's note in your own range, so a "
        + "low voice can follow a high melody."
    public static let octaveOffLine = "Each note goes to the melody's note as written, even when "
        + "that is much higher or lower than you sang."
    public static let applyLabel = "APPLY"
    public static let tuningLabel = "TUNING…"
    public static let applyHelp = "Tune this vocal to the picked melody. Undo puts it back."
    public static let undoNote = "Undo (⌘Z) puts your singing back in one step."
    public static let foundNoSinging = "Found no singing to tune in this clip. Tuning moves sung "
        + "notes, so a clip that is instrumental, very quiet or silent has nothing to move."

    /// A melody pass whose report came back without its melody block (never seen: the store
    /// always answers a melody request with one). The table may have changed, so it says where
    /// to look, rather than guessing a count.
    public static let noReport = "The tuning ran, but its result could not be read. Open the "
        + "Note Editor to see what changed, or Undo (⌘Z) and try again."

    /// "“Verse take” on Vocals": what is about to be tuned, named, so the person can see it
    /// is the clip they meant.
    public static func sourceLine(vocalName: String, trackName: String) -> String {
        let clip = vocalName.isEmpty ? "This clip" : "\u{201C}\(vocalName)\u{201D}"
        return trackName.isEmpty ? clip : "\(clip) on \(trackName)"
    }

    /// A picker row's name: a track bare, a clip in quotes.
    public static func choiceName(_ choice: TuneToMelodyChoice) -> String {
        choice.isClip ? "\u{201C}\(choice.name)\u{201D}" : choice.name
    }

    /// A picker row's detail: "31 notes under this vocal".
    public static func choiceDetail(_ choice: TuneToMelodyChoice) -> String {
        "\(choice.notesUnderVocal) \(choice.notesUnderVocal == 1 ? "note" : "notes") under this vocal"
    }

    /// The line under the chips, for the picked preset, in melody mode.
    public static func presetLine(_ preset: PitchCorrectionPreset) -> String {
        switch preset {
        case .gentle:
            return "Where one note runs into the next, a little of your own singing can show through. Vibrato stays."
        case .natural:
            return "Where one note runs into the next, only a trace of your own singing can show through. Vibrato stays."
        case .tight:
            return "Each note stays tuned right up to the next one. Vibrato stays."
        case .hardTune:
            return "Each note stays tuned right up to the next, with less vibrato. The robot effect."
        }
    }

    /// The melody's name in a sentence: a clip in quotes, a track bare.
    static func melodyName(_ outcome: TuneToMelodyOutcome) -> String {
        outcome.melodyIsClip ? "\u{201C}\(outcome.melodyName)\u{201D}" : outcome.melodyName
    }

    /// THE one line after Apply (§3.4): "Tuned 31 notes to Lead. 4 had no melody note under
    /// them and stayed as you sang them."
    public static func summary(_ outcome: TuneToMelodyOutcome) -> String {
        guard outcome.foundSinging else { return foundNoSinging }
        let melody = melodyName(outcome)
        guard outcome.tunedNotes > 0 else {
            return "No sung note had a note of \(melody) under it, so every note stayed as you "
                + "sang it."
        }
        var line = "Tuned \(outcome.tunedNotes) \(outcome.tunedNotes == 1 ? "note" : "notes") "
            + "to \(melody)."
        switch outcome.untouchedNotes {
        case 0: break
        case 1: line += " 1 had no melody note under it and stayed as you sang it."
        default:
            line += " \(outcome.untouchedNotes) had no melody note under them and stayed as you "
                + "sang them."
        }
        return line
    }

    /// The short note when some notes moved a long way (§3.3 row 7, `farMoves`), or nil.
    public static func farMoveNote(_ outcome: TuneToMelodyOutcome) -> String? {
        guard outcome.foundSinging, outcome.farMoves > 0 else { return nil }
        var note = outcome.farMoves == 1
            ? "1 note had to jump a long way to reach the melody. A big jump can change how the "
                + "voice sounds, so give it a listen."
            : "\(outcome.farMoves) notes had to jump a long way to reach the melody. A big jump "
                + "can change how the voice sounds, so give them a listen."
        if !outcome.matchedOctave {
            note += " " + octaveOffFarMoveTip
        }
        return note
    }

    /// Added to the far-move note when the pass ran with Match octave off.
    public static let octaveOffFarMoveTip =
        "Turning on Match octave keeps notes nearer where you sang them."
}

// MARK: - The card's layout (the view draws with these; the fit tests measure with them)

/// The card's dimensions and type sizes: ONE home, so the fit tests measure the card the view
/// draws (`PitchEditorPaletteLayout`'s rule).
public enum TuneToMelodyCardLayout {
    public static let cardWidth: CGFloat = 440
    public static let padding: CGFloat = 18
    /// The width every line of prose wraps in.
    public static var textWidth: CGFloat { cardWidth - 2 * padding }
    /// Between the card's sections.
    public static let sectionSpacing: CGFloat = 14
    /// Between a label and its control, and a control and its line.
    public static let innerSpacing: CGFloat = 6

    public static let titleSize: CGFloat = 11
    public static let sourceSize: CGFloat = 11
    public static let bodySize: CGFloat = 11
    public static let captionSize: CGFloat = 10
    public static let fieldLabelSize: CGFloat = 9
    public static let chipLabelSize: CGFloat = 10
    public static let rowNameSize: CGFloat = 11
    public static let rowDetailSize: CGFloat = 10
    public static let buttonLabelSize: CGFloat = 10

    public static let headerHeight: CGFloat = 20
    public static let chipHeight: CGFloat = 24
    public static let rowHeight: CGFloat = 30
    /// Rows the picker shows before it scrolls: the card must fit the window floor's height
    /// however many melodies a project has.
    public static let maxVisibleRows = 4
    public static let rowSpacing: CGFloat = 2
    public static let rowHorizontalPadding: CGFloat = 10
    /// The space a row keeps for its name before the detail (the name truncates, never the
    /// detail).
    public static let rowMinNameWidth: CGFloat = 120
    public static let checkboxSize: CGFloat = 13
    public static let checkboxSpacing: CGFloat = 8
    public static let footerHeight: CGFloat = 26
    /// The result's icon column (the line wraps beside it).
    public static let resultIconColumn: CGFloat = 16
    /// The space left above and below the card inside the window.
    public static let verticalMargin: CGFloat = 24

    /// The picker's height for `rows` rows, capped at `maxVisibleRows`.
    public static func pickerHeight(rows: Int) -> CGFloat {
        let shown = CGFloat(max(1, min(rows, maxVisibleRows)))
        return shown * rowHeight + (shown - 1) * rowSpacing
    }
}
