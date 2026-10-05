import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

/// Tune to Melody, M3 (W7-TTM3): the card's HEADLESS half — what the clip menu offers, what the
/// card lists and sends, and every word it says (design
/// `2026-09-24-unpitched-notes-presets-midi-targets.md` §3.3/§3.4).
///
/// NOT `@MainActor`: every type here is a nonisolated value (`TuneToMelodyMenu`,
/// `TuneToMelodyChoice`, `TuneToMelodyCard`, `TuneToMelodyOutcome`, `TuneToMelodyCopy`), so
/// nothing here touches an actor. The door and the real store are
/// `TuneToMelodyDoorTests.swift`'s, an extension of an existing `@MainActor` suite.
///
/// Fixture arithmetic (120 bpm, a beat is 0.5 s): the vocal starts at beat 2, plays its file from
/// 0.5 s, is 8 beats long, so its window is source seconds 0.5 to 4.5 at ratio 1.
@Suite("Tune to Melody M3 — the card's headless half (W7-TTM3)")
struct TuneToMelodyCardTests {

    static let at120 = TempoMap(constantBPM: 120)
    /// 120 bpm to beat 6, then 90.
    static let tempoChange = try! TempoMap(segments: [
        TempoMap.Segment(startBeat: 0, bpm: 120), TempoMap.Segment(startBeat: 6, bpm: 90),
    ])

    static func vocal(startBeat: Double = 2, lengthBeats: Double = 8, offset: Double = 0.5,
                      ratio: Double = 1, name: String = "Verse take") -> Clip {
        Clip(name: name, startBeat: startBeat, lengthBeats: lengthBeats,
             audioFileURL: URL(fileURLWithPath: "/tmp/w7-ttm3-vocal.wav"),
             startOffsetSeconds: offset, stretchRatio: ratio)
    }

    static func melody(_ name: String = "Melody", startBeat: Double, lengthBeats: Double = 4,
                       _ notes: [MIDINote]) -> Clip {
        Clip(name: name, startBeat: startBeat, lengthBeats: lengthBeats, notes: notes)
    }

    static func note(_ start: Double, _ length: Double = 1, pitch: Int = 60) -> MIDINote {
        MIDINote(pitch: pitch, startBeat: start, lengthBeats: length)
    }

    static func instrument(_ name: String, _ clips: [Clip]) -> Track {
        Track(name: name, kind: .instrument, clips: clips)
    }

    static func project(vocal: Clip, _ melodyTracks: [Track]) -> [Track] {
        [Track(name: "Vocals", kind: .audio, clips: [vocal])] + melodyTracks
    }

    /// The store's own refusal test, spelled the way the store spells it for "every MIDI clip".
    static func storeWouldAccept(_ vocal: Clip, _ tracks: [Track], _ map: TempoMap) -> Bool {
        let midi = tracks.flatMap(\.clips).filter(\.isMIDI)
        return !MelodyTuning.notes(of: midi, under: vocal, tempoMap: map).isEmpty
    }

    // MARK: - The menu item

    /// ⭐ THE MENU CANNOT DISAGREE WITH THE STORE. Over a grid of three stretch ratios, two tempo
    /// maps, two offsets and MIDI clips placed before, touching, across, inside, after and
    /// beyond the vocal (with notes inside, outside and hanging past their clip), the menu item
    /// is live EXACTLY when the store's `MelodyTuning.notes(of:under:tempoMap:)` finds a note,
    /// and the card's list is non-empty in exactly the same cases. The grid holds both answers
    /// (counted), so a menu stuck on one answer cannot pass.
    @Test("T1 the menu item is live exactly when the store's own test finds a melody note (grid)")
    func menuMatchesTheStoresOwnTestOverAGrid() {
        // The vocal sits at beats 10-18 so no placement starts before beat 0: `Clip.init` clamps a
        // negative start to 0 (Model.swift, `max(0, startBeat)`), which turned the first draft's
        // "touching" clip at beat -2 into one at 0 that sings under the vocal (MEASURED: the
        // grid read 480/180 against the predicted 408/252, and a per-placement probe found it).
        // (clip start beat, clip length, note start in the clip, note length)
        let placements: [(Double, Double, Double, Double)] = [
            (2, 4, 0, 1),      // wholly before (the note ends at beat 3)
            (6, 4, 0, 4),      // ends exactly at the vocal's start (beat 10): touching only
            (8, 4, 1, 2),      // across the vocal's start: the note sounds beats 9-11
            (8, 4, 0, 1),      // overlaps the vocal in BEATS, but its only note ends at beat 9
            (12, 2, 0, 1),     // inside
            (12, 2, 1.5, 3),   // inside, the note hangs past its clip (clipped at the clip end)
            (17.5, 4, 0, 1),   // across the vocal's end (beat 18)
            (18, 4, 0, 2),     // starts exactly at the vocal's end: touching only
            (22, 4, 0, 2),     // wholly after
            (12, 0.5, 1, 1),   // inside, but the note starts past its clip's end: silent
        ]
        var live = 0
        var dead = 0
        for ratio in [1.0, 1.25, 0.8] {
            for map in [Self.at120, Self.tempoChange] {
                for offset in [0.0, 0.5] {
                    let vocal = Self.vocal(startBeat: 10, offset: offset, ratio: ratio)
                    // Each placement alone, and every pair (a live clip beside a dead one).
                    var sets: [[Clip]] = placements.map {
                        [Self.melody(startBeat: $0.0, lengthBeats: $0.1, [Self.note($0.2, $0.3)])]
                    }
                    for i in placements.indices {
                        for j in placements.indices where j > i {
                            sets.append([sets[i][0], sets[j][0]])
                        }
                    }
                    for clips in sets {
                        let tracks = Self.project(vocal: vocal, [Self.instrument("Keys", clips)])
                        let expected = Self.storeWouldAccept(vocal, tracks, map)
                        let item = TuneToMelodyMenu.availability(vocal: vocal, tracks: tracks,
                                                                 tempoMap: map)
                        let listed = TuneToMelodyChoice.choices(vocal: vocal, tracks: tracks,
                                                                tempoMap: map)
                        #expect(item.isEnabled == expected,
                                "ratio \(ratio) offset \(offset) clips \(clips.map(\.startBeat)): menu \(item.isEnabled), store \(expected)")
                        #expect(listed.isEmpty == !expected)
                        if expected { live += 1 } else { dead += 1 }
                    }
                }
            }
        }
        print("[measured] TTM3 grid: live \(live), dead \(dead)")
        #expect(live > 100 && dead > 100, "the grid must exercise BOTH answers: live \(live), dead \(dead)")
    }

    @Test("T2 with no MIDI under the vocal the item is greyed with the design's sentence; live, it says what it does")
    func menuItemSaysWhy() {
        let vocal = Self.vocal()
        let none = TuneToMelodyMenu.availability(
            vocal: vocal, tracks: Self.project(vocal: vocal, []), tempoMap: Self.at120)
        #expect(none == TuneToMelodyMenu.Availability(
            isEnabled: false, help: "Add a MIDI melody under this vocal first."))
        let live = TuneToMelodyMenu.availability(
            vocal: vocal,
            tracks: Self.project(vocal: vocal, [Self.instrument("Lead", [
                Self.melody(startBeat: 2, [Self.note(0)])])]),
            tempoMap: Self.at120)
        #expect(live.isEnabled)
        #expect(live.help == TuneToMelodyCopy.menuHelp)
        // An AUDIO clip under the vocal is not a melody (the store's `.isMIDI` rule).
        let audioOnly = TuneToMelodyMenu.availability(
            vocal: vocal,
            tracks: Self.project(vocal: vocal, [Track(name: "Guitar", kind: .audio, clips: [
                Self.vocal(name: "Guitar take")])]),
            tempoMap: Self.at120)
        #expect(audioOnly.isEnabled == false)
    }

    // MARK: - The picker

    @Test("T3 the list puts a track named Lead first (any case), then project order; dead tracks and audio are not listed")
    func leadComesFirst() throws {
        let vocal = Self.vocal()
        let tracks = Self.project(vocal: vocal, [
            Self.instrument("Strings", [Self.melody("Pad", startBeat: 2, [Self.note(0), Self.note(1)])]),
            Self.instrument("Bass", [Self.melody("Bassline", startBeat: 20, [Self.note(0)])]),
            Track(name: "Lead", kind: .audio, clips: [Self.vocal(name: "Lead vocal take")]),
            Self.instrument("  lead ", [Self.melody("Hook", startBeat: 4, [Self.note(0, pitch: 67)])]),
            Self.instrument("Keys", [Self.melody("Chords", startBeat: 6, [Self.note(0)])]),
        ])
        let list = TuneToMelodyChoice.choices(vocal: vocal, tracks: tracks, tempoMap: Self.at120)
        #expect(list.map(\.name) == ["  lead ", "Strings", "Keys"])
        #expect(list.map(\.isClip) == [false, false, false])
        #expect(list.map(\.notesUnderVocal) == [1, 2, 1])
        let lead = try #require(list.first)
        #expect(lead.source == .track(tracks[4].id))
        #expect(TuneToMelodyCopy.choiceDetail(list[1]) == "2 notes under this vocal")
        #expect(TuneToMelodyCopy.choiceDetail(list[0]) == "1 note under this vocal")
    }

    /// One clip under the vocal would tune exactly what its track row tunes (the store keeps
    /// only notes under the vocal), so a clip gets its own row only when two or more of its
    /// track's clips sing under the vocal.
    @Test("T4 a track's clips get their own rows (quoted, under the track) only when two or more of them are under the vocal")
    func clipRowsOnlyWhenTheyChangeSomething() {
        let vocal = Self.vocal()
        let one = Self.instrument("Lead", [
            Self.melody("Verse melody", startBeat: 2, [Self.note(0), Self.note(1)]),
            Self.melody("Outro melody", startBeat: 30, [Self.note(0)]),
        ])
        let two = Self.instrument("Synth", [
            Self.melody("Hook A", startBeat: 2, [Self.note(0)]),
            Self.melody("Hook B", startBeat: 6, [Self.note(0), Self.note(1, pitch: 62)]),
        ])
        let list = TuneToMelodyChoice.choices(vocal: vocal, tracks: Self.project(vocal: vocal, [two, one]),
                                              tempoMap: Self.at120)
        #expect(list.map(\.name) == ["Lead", "Synth", "Hook A", "Hook B"])
        #expect(list.map(\.isClip) == [false, false, true, true])
        #expect(list.map(\.notesUnderVocal) == [2, 3, 1, 2])
        #expect(list[2].trackName == "Synth")
        #expect(list[2].source == .clip(two.clips[0].id))
        #expect(TuneToMelodyCopy.choiceName(list[2]) == "\u{201C}Hook A\u{201D}")
        #expect(TuneToMelodyCopy.choiceName(list[1]) == "Synth")
        // Ids are stable and distinct (the picker's ForEach and the seam pick by them).
        #expect(Set(list.map(\.id)).count == list.count)
    }

    // MARK: - The card's state

    static func leadProject() -> (vocal: Clip, tracks: [Track]) {
        let vocal = vocal()
        return (vocal, project(vocal: vocal, [
            instrument("Strings", [melody("Pad", startBeat: 2, [note(0)])]),
            instrument("Lead", [melody("Hook", startBeat: 4, [note(0, pitch: 67), note(1, pitch: 69)])]),
        ]))
    }

    @Test("T5 the card opens on Natural, Match octave ON and the first row (Lead) picked; with nothing listed, Apply is off")
    func cardDefaults() {
        let (vocal, tracks) = Self.leadProject()
        let card = TuneToMelodyCard(vocal: vocal, vocalTrackName: "Vocals", tracks: tracks,
                                    tempoMap: Self.at120)
        #expect(card.preset == .natural)
        #expect(card.matchOctave)
        #expect(card.selected?.name == "Lead")
        #expect(card.phase == .choosing)
        #expect(card.canApply && card.canClose && card.canEdit)
        #expect(TuneToMelodyCard.presets == PitchCorrectionPreset.offeredInUI)
        #expect(TuneToMelodyCopy.sourceLine(vocalName: card.vocalName, trackName: card.vocalTrackName)
                == "\u{201C}Verse take\u{201D} on Vocals")

        let empty = TuneToMelodyCard(vocal: vocal, vocalTrackName: "Vocals",
                                     tracks: Self.project(vocal: vocal, []), tempoMap: Self.at120)
        #expect(empty.choices.isEmpty)
        #expect(empty.selected == nil)
        #expect(empty.canApply == false)
        #expect(empty.melodyTuning == nil)
        #expect(empty.canClose)
    }

    @Test("T6 Match octave ON sends nearestOctave, OFF sends exact; the card sends no strength and the preset door's own options")
    func whatApplySends() throws {
        let (vocal, tracks) = Self.leadProject()
        var card = TuneToMelodyCard(vocal: vocal, vocalTrackName: "Vocals", tracks: tracks,
                                    tempoMap: Self.at120)
        let on = try #require(card.melodyTuning)
        #expect(on.octaveMatch == .nearestOctave)
        #expect(on.source == .track(tracks[2].id))
        #expect(on.strength == nil, "rule 5 is the store's: the card must not send a strength")
        #expect(on.unmatched == .asSung)
        card.setMatchOctave(false)
        #expect(try #require(card.melodyTuning).octaveMatch == .exact)
        card.setMatchOctave(true)
        #expect(try #require(card.melodyTuning).octaveMatch == .nearestOctave)
        for preset in TuneToMelodyCard.presets {
            card.choosePreset(preset)
            #expect(card.options == preset.options())
        }
        card.select(card.choices[1].id)
        #expect(try #require(card.melodyTuning).source == .track(tracks[1].id))
        // A row that is not listed is ignored, not half-applied.
        card.select("track:\(UUID().uuidString)")
        #expect(card.selected?.name == "Strings")
    }

    @Test("T7 settings freeze while tuning or asking; any change after a result clears it; Cancel returns to picking")
    func phases() {
        let (vocal, tracks) = Self.leadProject()
        var card = TuneToMelodyCard(vocal: vocal, vocalTrackName: "Vocals", tracks: tracks,
                                    tempoMap: Self.at120)
        card.markWaitingForAnswer()
        #expect(!card.canApply && !card.canClose && !card.canEdit)
        card.choosePreset(.tight)
        card.setMatchOctave(false)
        card.select(card.choices[1].id)
        #expect(card.preset == .natural && card.matchOctave && card.selected?.name == "Lead",
                "a frozen card changed under the question it is asking")
        card.markDeclined()
        #expect(card.phase == .choosing)

        card.markTuning()
        #expect(!card.canApply && !card.canClose)
        card.markDeclined()   // a Cancel that is not about this run changes nothing
        #expect(card.phase == .tuning)
        let outcome = TuneToMelodyOutcome(melodyName: "Lead", melodyIsClip: false, foundSinging: true,
                                          tunedNotes: 3, untouchedNotes: 0, farMoves: 0,
                                          matchedOctave: true)
        card.finish(outcome)
        #expect(card.phase == .finished(outcome))
        #expect(card.canApply && card.canClose, "after a result the person may apply again or close")
        card.choosePreset(.tight)
        #expect(card.phase == .choosing, "a result line beside different settings describes nothing on screen")
        card.refuse("No.")
        card.setMatchOctave(false)
        #expect(card.phase == .choosing)
    }

    // MARK: - The words

    static func outcome(_ name: String = "Lead", clip: Bool = false, found: Bool = true,
                        tuned: Int, untouched: Int = 0, far: Int = 0,
                        octave: Bool = true) -> TuneToMelodyOutcome {
        TuneToMelodyOutcome(melodyName: name, melodyIsClip: clip, foundSinging: found,
                            tunedNotes: tuned, untouchedNotes: untouched, farMoves: far,
                            matchedOctave: octave)
    }

    @Test("T8 the one result line, in every case (§3.4's example, singulars, a clip in quotes, nothing matched, no singing)")
    func summaryWords() {
        typealias C = TuneToMelodyCopy
        #expect(C.summary(Self.outcome(tuned: 31, untouched: 4))
                == "Tuned 31 notes to Lead. 4 had no melody note under them and stayed as you sang them.")
        #expect(C.summary(Self.outcome(tuned: 1, untouched: 1))
                == "Tuned 1 note to Lead. 1 had no melody note under it and stayed as you sang it.")
        #expect(C.summary(Self.outcome(tuned: 12)) == "Tuned 12 notes to Lead.")
        #expect(C.summary(Self.outcome("Verse melody", clip: true, tuned: 3))
                == "Tuned 3 notes to \u{201C}Verse melody\u{201D}.")
        #expect(C.summary(Self.outcome(tuned: 0, untouched: 5))
                == "No sung note had a note of Lead under it, so every note stayed as you sang it.")
        #expect(C.summary(Self.outcome(found: false, tuned: 0)) == C.foundNoSinging)
    }

    @Test("T9 the far-move note: only when a note jumped, singular/plural, the Match octave tip only when it was off")
    func farMoveWords() {
        typealias C = TuneToMelodyCopy
        #expect(C.farMoveNote(Self.outcome(tuned: 3)) == nil)
        #expect(C.farMoveNote(Self.outcome(tuned: 3, far: 1))
                == "1 note had to jump a long way to reach the melody. A big jump can change how the "
                    + "voice sounds, so give it a listen.")
        #expect(C.farMoveNote(Self.outcome(tuned: 3, far: 3, octave: false))
                == "3 notes had to jump a long way to reach the melody. A big jump can change how the "
                    + "voice sounds, so give them a listen. Turning on Match octave keeps notes nearer "
                    + "where you sang them.")
        #expect(C.farMoveNote(Self.outcome(found: false, tuned: 0, far: 2)) == nil)
    }

    /// Every word the card can draw, for the copy rules and the fit suite.
    static func everyString() -> [String] {
        typealias C = TuneToMelodyCopy
        var all = [C.menuTitle, C.menuHelp, C.noMelodyUnderVocal, C.title, C.closeHelp, C.intro,
                   C.melodyLabel, C.soundLabel, C.octaveLabel, C.octaveOnLine, C.octaveOffLine,
                   C.applyLabel, C.tuningLabel, C.applyHelp, C.undoNote, C.foundNoSinging,
                   C.noReport, C.octaveOffFarMoveTip]
        all += PitchCorrectionPreset.offeredInUI.map(C.presetLine)
        for o in [outcome(tuned: 31, untouched: 4, far: 2, octave: false), outcome(tuned: 1, untouched: 1, far: 1),
                  outcome(tuned: 0, untouched: 3)] {
            all.append(C.summary(o))
            if let n = C.farMoveNote(o) { all.append(n) }
        }
        return all
    }

    /// M2 measured the detector reading a held note up to ~7 c off what was sung, and a tuned
    /// note lands that far off the melody: nothing may promise "exactly" (or "perfect").
    @Test("T10 no word promises an exact landing; the melody-mode chip lines are the card's own (Gentle is not 'halfway')")
    func wordsNeverOverclaim() {
        for text in Self.everyString() {
            let lower = text.lowercased()
            #expect(!lower.contains("exact") && !lower.contains("perfect") && !lower.contains("precise"),
                    "overclaims: \(text)")
            #expect(!text.isEmpty)
        }
        #expect(!TuneToMelodyCopy.presetLine(.gentle).lowercased().contains("halfway"),
                "in melody mode every preset runs at strength 1: Gentle does not stop halfway")
        let lines = PitchCorrectionPreset.offeredInUI.map(TuneToMelodyCopy.presetLine)
        #expect(Set(lines).count == lines.count, "two chips with one line say nothing about the difference")
        for preset in PitchCorrectionPreset.offeredInUI {
            #expect(TuneToMelodyCopy.presetLine(preset) != preset.summary)
        }
    }

    /// "Tuned N notes" counts SUNG notes, not the rows the pass wrote: a held note the melody
    /// cut in two is ONE note. `tuneToMelodyDoor D9`/`D10` pin it through the real store; this
    /// pins the arithmetic, including the case the store never makes today (a middle piece
    /// left as sung), where subtracting one per cut would count one note twice.
    @Test("T11 the result counts SUNG notes: a note cut into pieces is one note, tuned, left as sung or moved far")
    func countsSungNotesNotPieces() {
        let (a, b, c, d, e) = (UUID(), UUID(), UUID(), UUID(), UUID())
        // No cut: every row is its own sung note.
        let plain = TuneToMelodySungNotes(matchedPieces: 3, cuts: [], unmatched: [d], farMoved: [a])
        #expect(plain == TuneToMelodySungNotes.expected(tuned: 3, untouched: 1, farMoved: 1))
        // One held note cut once (A|B) plus one other note: 3 rows, 2 sung notes.
        let once = TuneToMelodySungNotes(matchedPieces: 3, cuts: [[a, b]], unmatched: [], farMoved: [])
        #expect(once.tuned == 2)
        // Cut twice (A|B|C): 4 rows with one other note, 2 sung notes.
        let twice = TuneToMelodySungNotes(matchedPieces: 4, cuts: [[a, b], [b, c]], unmatched: [], farMoved: [])
        #expect(twice.tuned == 2)
        // A|B|C with the MIDDLE piece left as sung, plus D left as sung: the cuts each touch an
        // untuned piece, so one-per-cut would subtract nothing and say 3. Sung notes: A|B|C (tuned)
        // and E (tuned), with D untouched.
        let middle = TuneToMelodySungNotes(matchedPieces: 3, cuts: [[a, b], [b, c]], unmatched: [b, d],
                                           farMoved: [])
        #expect(middle == TuneToMelodySungNotes.expected(tuned: 2, untouched: 1, farMoved: 0))
        // Both pieces of one cut note moved far, and one other note: 2 sung notes jumped, not 3.
        let far = TuneToMelodySungNotes(matchedPieces: 3, cuts: [[a, b]], unmatched: [], farMoved: [a, b, e])
        #expect(far.farMoved == 2)
        // A cut note whose every piece is left as sung is ONE untouched note.
        let restCut = TuneToMelodySungNotes(matchedPieces: 1, cuts: [[a, b]], unmatched: [a, b], farMoved: [])
        #expect(restCut == TuneToMelodySungNotes.expected(tuned: 1, untouched: 1, farMoved: 0))
        // A cut the report could not give ids for is taken at the store's invariant.
        #expect(TuneToMelodySungNotes(matchedPieces: 2, cuts: [[a]], unmatched: [], farMoved: []).tuned == 1)
        // The words then say what was sung.
        let outcome = TuneToMelodyOutcome(melodyName: "Lead", melodyIsClip: false, foundSinging: true,
                                          tunedNotes: once.tuned, untouchedNotes: once.untouched,
                                          farMoves: once.farMoved, matchedOctave: true)
        #expect(TuneToMelodyCopy.summary(outcome) == "Tuned 2 notes to Lead.")
    }

    /// The product's own preset lines (drawn under the Note Editor's chips, the Tune Vocal
    /// menu's tooltips) keep the rule this card's words keep. Hard Tune's once said "Replaces your
    /// pitch with the exact note": measured, it keeps each note on pitch and cuts its vibrato by
    /// about a third (TuneToMelodyChipRenderTests C1: 36 c to 23 c; the preset's own notes:
    /// 49 % to 68 % on a real vocal). It does not replace the pitch with an exact note.
    @Test("T12 no preset's own one-line summary promises an exact note; Hard Tune's says what was measured")
    func presetSummariesNeverOverclaim() {
        for preset in PitchCorrectionPreset.allCases {
            let lower = preset.summary.lowercased()
            #expect(!lower.contains("exact") && !lower.contains("perfect") && !lower.contains("precise")
                    && !lower.contains("replaces your pitch"), "overclaims: \(preset.summary)")
        }
        #expect(PitchCorrectionPreset.hardTune.summary.contains("less vibrato"))
    }
}

extension TuneToMelodySungNotes {
    /// A value to compare against, built without the arithmetic under test.
    static func expected(tuned: Int, untouched: Int, farMoved: Int) -> TuneToMelodySungNotes {
        TuneToMelodySungNotes(tuned: tuned, untouched: untouched, farMoved: farMoved)
    }
}
