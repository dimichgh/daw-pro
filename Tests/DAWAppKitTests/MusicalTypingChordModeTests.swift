import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// m23-cv — ONE-FINGER CHORDS: the controller half.
///
/// ⭐ **THIS SUITE'S FIRST JOB IS TO PROVE THE FEATURE IS ADDITIVE.** The 85 tests
/// in `MusicalTypingControllerTests` / `MusicalTypingRoutingTests` /
/// `MusicalTypingSiteTests` were run UNMODIFIED against the group-shaped ledger
/// before a line of chord behaviour existed, and they stay unmodified — none of
/// them is edited or retired by this item. What is added here is the chord mode's
/// own behaviour, plus the two rules that survive it: **offs are never gated**,
/// and **a dim key still plays**.
@Suite("Musical Typing chord mode (m23-cv)")
@MainActor
struct MusicalTypingChordModeTests {

    private final class SpySink: LiveNoteSink {
        var sets: [[Int]] = []
        var velocities: [Int] = []
        var last: [Int] { sets.last ?? [] }
        func setHeldPitches(_ pitches: [Int], velocity: Int) {
            sets.append(pitches)
            velocities.append(velocity)
        }
    }

    private func makeController(chords: Bool = true) -> (MusicalTypingController, SpySink) {
        let sink = SpySink()
        let controller = MusicalTypingController(sink: sink)
        controller.targetState = .ready
        controller.setEnabled(true)
        if chords { controller.setPlayMode(.chords) }
        return (controller, sink)
    }

    @discardableResult
    private func press(_ label: String, on controller: MusicalTypingController,
                       modifiers: TransportKeyModifiers = [],
                       isRepeat: Bool = false,
                       responder: TransportKeyResponder = .none,
                       window: TransportKeyWindow = .main) -> MusicalTypingDecision {
        guard let cap = MusicalTypingRouting.cap(forLabel: label) else {
            Issue.record("'\(label)' is not a layout key")
            return .passThrough(.unmapped)
        }
        return controller.handleKeyDown(keyCode: cap.keyCode, modifiers: modifiers,
                                        isRepeat: isRepeat, responder: responder,
                                        window: window)
    }

    @discardableResult
    private func release(_ label: String, on controller: MusicalTypingController) -> Bool {
        guard let cap = MusicalTypingRouting.cap(forLabel: label) else {
            Issue.record("'\(label)' is not a layout key")
            return false
        }
        return controller.releaseKey(keyCode: cap.keyCode)
    }

    /// The seven HOME-ROW cells, in order — the row the user's mock-up draws.
    /// ⚠️ NOT `chordCells.prefix(7)`: the cell list is in PITCH order, so its
    /// first seven entries are `A W S E D F T`, three of which are accidentals.
    /// That confusion is exactly what `chordDegree`'s banner records.
    private func homeRow(_ controller: MusicalTypingController) -> [String] {
        let byLabel = Dictionary(uniqueKeysWithValues:
            controller.chordCells.map { ($0.keyLabel, $0) })
        return ["A", "S", "D", "F", "G", "H", "J"].compactMap { byLabel[$0]?.chordName }
    }

    // MARK: - Additive by default

    @Test("a fresh controller is in NOTE mode, in C major, on the piano preset")
    func freshDefaults() {
        let controller = MusicalTypingController()
        #expect(controller.playMode == .notes)
        #expect(controller.chordKey == 0)
        #expect(controller.chordKeyMode == .major)
        #expect(controller.voicingPreset == .piano)
        #expect(controller.progression == nil)
    }

    /// ⛔ **THE ADDITIVE GUARANTEE, ASSERTED DIRECTLY.** With the mode off, one key
    /// is still exactly one note at exactly the pitch it always was.
    @Test("with chord mode OFF a key still sounds exactly one note")
    func noteModeUnchanged() {
        let (controller, sink) = makeController(chords: false)
        press("a", on: controller)
        #expect(controller.soundingPitches == [60])
        #expect(sink.last == [60])
        press("d", on: controller)
        #expect(controller.soundingPitches == [60, 64])
    }

    // MARK: - One key, one chord

    /// The user's own mock-up, keyed in: `A S D F G H J` → `C Dm Em F G Am Bdim`
    /// in C major, `I ii iii IV V vi vii°`.
    @Test("the seven home-row keys are the seven diatonic chords, exactly as the mock-up says")
    func homeRowIsTheDiatonicSeven() {
        let (controller, _) = makeController()
        let cells = controller.chordCells
        let byLabel = Dictionary(uniqueKeysWithValues: cells.map { ($0.keyLabel, $0) })
        for (label, name, numeral) in [
            ("A", "C", "I"), ("S", "Dm", "ii"), ("D", "Em", "iii"), ("F", "F", "IV"),
            ("G", "G", "V"), ("H", "Am", "vi"), ("J", "Bdim", "vii°"),
        ] {
            #expect(byLabel[label]?.chordName == name, "\(label) should be \(name)")
            #expect(byLabel[label]?.romanNumeral == numeral)
        }
    }

    @Test("pressing one key sounds a whole chord through the same seam")
    func onePressSoundsAChord() {
        let (controller, sink) = makeController()
        // ⚠️ BASELINE FIRST. Entering chord mode releases everything, which is a
        // push of its own — counting from zero here would assert against the mode
        // switch rather than against the chord.
        let before = sink.sets.count
        press("a", on: controller)
        // C3 bass + a close root-position C major triad at middle C. Stated as
        // pitches because nobody here can hear it: 48 = C3, 60/64/67 = C4/E4/G4.
        #expect(controller.soundingPitches == [48, 60, 64, 67])
        #expect(sink.last == [48, 60, 64, 67])
        #expect(sink.sets.count == before + 1, "a chord must cross the seam in ONE push")
    }

    /// ⭐ **THE ATOMIC-GROUP PROPERTY.** Four notes must arrive as one set, not as
    /// four sets — an edge-shaped crossing here would re-record the chord into the
    /// take on every heartbeat, which is the exact hazard `LiveNoteSink`'s banner
    /// documents.
    @Test("a chord change is ONE push, and common tones are not re-struck")
    func chordChangeIsOnePush() {
        let (controller, sink) = makeController()
        press("a", on: controller)          // C
        release("a", on: controller)
        let before = sink.sets.count
        press("f", on: controller)          // F
        #expect(sink.sets.count == before + 1)
        #expect(controller.soundingPitches.count == 4)
    }

    @Test("the octave keys move the chords, not just the notes")
    func octaveKeysMoveChords() {
        let (controller, _) = makeController()
        press("a", on: controller)
        let atHome = controller.soundingPitches
        release("a", on: controller)
        press("x", on: controller)          // octave up
        press("a", on: controller)
        let anOctaveUp = controller.soundingPitches
        #expect(anOctaveUp != atHome)
        // ⚠️ THE BODY MOVES; THE BASS MAY NOT. The bass window is 12 semitones
        // wide, so after a one-octave shift its old note is still inside the new
        // window and nearest-octave leading keeps it there. Asserting on `min`
        // would be asserting that voice leading is broken.
        #expect((anOctaveUp.max() ?? 0) > (atHome.max() ?? 0))
    }

    @Test("the key picker transposes every cell without moving which key plays which degree")
    func keyPickerTransposes() {
        let (controller, _) = makeController()
        controller.setChordKey(2)           // D major
        let byLabel = Dictionary(uniqueKeysWithValues:
            controller.chordCells.map { ($0.keyLabel, $0) })
        #expect(byLabel["A"]?.chordName == "D")
        #expect(byLabel["A"]?.romanNumeral == "I")     // the tonic stays on `A`
        #expect(byLabel["G"]?.chordName == "A")
        #expect(byLabel["G"]?.romanNumeral == "V")
    }

    @Test("switching to minor changes the qualities, not the layout")
    func minorMode() {
        let (controller, _) = makeController()
        controller.setChordKey(9, mode: .minor)       // A natural minor
        #expect(homeRow(controller) == ["Am", "Bdim", "C", "Dm", "Em", "F", "G"])
    }

    // MARK: - Voice leading through the controller

    /// ⭐ **THE LEDGER IS THE VOICE-LEADING MEMORY**, and this proves it is
    /// actually consulted: the same chord key produces different pitches depending
    /// on what was played before it. If `lastVoicing` were never read, both
    /// presses would return the home voicing and this test would fail.
    @Test("consecutive chords lead smoothly — the same key voices differently after a different predecessor")
    func voiceLeadingIsLive() {
        let (fresh, _) = makeController()
        press("f", on: fresh)                          // F straight from silence
        let fromSilence = fresh.soundingPitches
        release("f", on: fresh)

        let (played, _) = makeController()
        press("a", on: played)                         // C first
        release("a", on: played)
        press("f", on: played)                         // then F
        let afterC = played.soundingPitches

        #expect(fromSilence != afterC)
        // And the second one is genuinely smooth: the body holds the common tone
        // C4 and moves the other two voices by 1 and 2 semitones.
        #expect(Array(afterC.dropFirst()) == [60, 65, 69])
    }

    @Test("turning the mode off clears the voice-leading memory")
    func voicingMemoryIsSessionState() {
        let (controller, _) = makeController()
        press("a", on: controller)
        release("a", on: controller)
        controller.setEnabled(false)
        controller.setEnabled(true)
        press("f", on: controller)
        // Back to the home voicing for F, not led from a C nobody can hear.
        #expect(controller.soundingPitches
            == ChordVoicing.voice(ChordSymbol(rootPitchClass: 5, quality: .major),
                                  previous: nil,
                                  preset: InstrumentVoicingPreset.preset(for: .piano)))
    }

    @Test("a refused press does not move the voice-leading anchor")
    func refusalDoesNotMoveTheAnchor() {
        let (controller, _) = makeController()
        press("a", on: controller)
        let anchor = controller.soundingPitches
        release("a", on: controller)
        controller.targetState = .noTrack
        press("g", on: controller)                     // silenced
        #expect(controller.soundingPitches.isEmpty)
        controller.targetState = .ready
        press("f", on: controller)
        // F led from C, exactly as if the silenced G had never happened.
        #expect(Array(controller.soundingPitches.dropFirst()) == [60, 65, 69])
        #expect(anchor == [48, 60, 64, 67])
    }

    // MARK: - Instrument presets

    @Test("the bass preset plays one note per key, the piano preset plays four")
    func presetsChangeDensity() {
        let (controller, _) = makeController()
        press("a", on: controller)
        #expect(controller.soundingPitches.count == 4)
        release("a", on: controller)
        controller.setVoicingPreset(.bass)
        press("a", on: controller)
        #expect(controller.soundingPitches.count == 1)
        #expect(controller.soundingPitches[0] % 12 == 0, "the bass note must be the root")
    }

    @Test("changing the preset resets the voice-leading memory rather than dragging registers")
    func presetChangeResetsMemory() {
        let (controller, _) = makeController()
        controller.setVoicingPreset(.bass)
        press("a", on: controller)
        release("a", on: controller)
        controller.setVoicingPreset(.piano)
        press("f", on: controller)
        #expect(controller.soundingPitches
            == ChordVoicing.voice(ChordSymbol(rootPitchClass: 5, quality: .major),
                                  previous: nil,
                                  preset: InstrumentVoicingPreset.preset(for: .piano)))
    }

    @Test("the pad preset uses sevenths, so its cells are named with sevenths")
    func padUsesSevenths() {
        let (controller, _) = makeController()
        controller.setVoicingPreset(.pad)
        #expect(homeRow(controller)
            == ["Cmaj7", "Dm7", "Em7", "Fmaj7", "G7", "Am7", "Bm7b5"])
    }

    // MARK: - The progression overlay

    /// ⛔⛔ **THE RULE THE USER'S CHOICE TURNS ON: A PRESET LIGHTS KEYS, IT NEVER
    /// GATES THEM.** "Follow the lights, or ignore them. Same keys either way."
    @Test("a dim key plays exactly as well as a lit one")
    func dimKeysStillPlay() {
        let (controller, sink) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        let cells = controller.chordCells
        let lit = cells.first { $0.isLit && $0.octaveShift == 0 && !$0.addsColour }
        let dim = cells.first { !$0.isLit && $0.octaveShift == 0 && !$0.addsColour }
        #expect(lit != nil)
        #expect(dim != nil)
        // The DIM one, which the overlay does not name at all.
        press(dim?.keyLabel ?? "", on: controller)
        #expect(controller.soundingPitches.count == 4,
                "a dim key sounded \(controller.soundingPitches.count) notes")
        #expect(!sink.last.isEmpty)
        release(dim?.keyLabel ?? "", on: controller)
        // And the LIT one, so the comparison is against a measured baseline
        // rather than against an assumption.
        press(lit?.keyLabel ?? "", on: controller)
        #expect(controller.soundingPitches.count == 4)
    }

    /// ⚠️ **RENAMED AND RE-COMMENTED AT m34-i, ASSERTIONS UNCHANGED.** It used to
    /// say "lights and NUMBERS", which stopped being true of the screen the
    /// moment the badges were deleted — `progressionOrder` is seam data now, not
    /// paint. The record is retracted in place rather than left to rot into the
    /// record-says-X-source-says-Y shape this tree keeps closing.
    @Test("the Four Chords overlay lights exactly the mock-up's four keys, and steps them 1-4")
    func fourChordsOverlayMatchesTheMockup() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        let byLabel = Dictionary(uniqueKeysWithValues:
            controller.chordCells.map { ($0.keyLabel, $0) })
        #expect(byLabel["A"]?.progressionOrder == 1)      // I
        #expect(byLabel["G"]?.progressionOrder == 2)      // V
        #expect(byLabel["H"]?.progressionOrder == 3)      // vi
        #expect(byLabel["F"]?.progressionOrder == 4)      // IV
        #expect(byLabel["S"]?.progressionOrder == nil)    // ii — dim, still playable
        #expect(byLabel["D"]?.progressionOrder == nil)    // iii
        #expect(byLabel["J"]?.progressionOrder == nil)    // vii°
        // ⭐ EXACTLY FOUR STEPPED CELLS FOR A FOUR-CHORD PRESET. The first version
        // numbered every cell whose DEGREE was lit, which painted ten badges —
        // the colour keys and the second octave run share their degrees, so the
        // row showed four different cells all labelled `1`. Only a screenshot of
        // the live app could see it. The badge is gone (m34-i) but the narrowing
        // is not: `isNextInProgression` inherits it, so this pin is what stops
        // the same bug being re-earned by the border.
        #expect(controller.chordCells.compactMap(\.progressionOrder).sorted()
            == [1, 2, 3, 4])
        // …while LIT is wider than STEPPED, and deliberately: any lit key plays
        // that chord, the stepped one is just the one to press first.
        #expect(controller.chordCells.filter(\.isLit).count > 4)
        #expect(byLabel["W"]?.isLit == true, "the colour key of a lit degree is lit")
        #expect(byLabel["W"]?.progressionOrder == nil, "…but it carries no step")
        #expect(byLabel["K"]?.isLit == true, "the +8va run of a lit degree is lit")
        #expect(byLabel["K"]?.progressionOrder == nil, "…but it carries no step")
    }

    // MARK: - The next-chord border (m34-i)

    /// The chord cell wearing the border right now, if any.
    private func nextCell(_ controller: MusicalTypingController)
        -> MusicalTypingChordCell? {
        let bordered = controller.chordCells.filter(\.isNextInProgression)
        // ⛔ THE COUNT IS ASSERTED IN EVERY READ, not once in one test. The bug
        // this feature replaced was a COUNT bug that no assertion could see —
        // ten badges where four were meant — and it took a screenshot to find.
        // Every border read in this suite therefore pays for the count.
        #expect(bordered.count <= 1, "at most ONE cell may wear the border")
        return bordered.first
    }

    @Test("⭐ the border starts on the progression's FIRST chord, on exactly one cell")
    func borderStartsOnStepOne() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        #expect(controller.chordCells.filter(\.isNextInProgression).count == 1)
        let next = nextCell(controller)
        #expect(next?.keyLabel == "A", "Four Chords opens on I")
        #expect(next?.progressionOrder == 1)
        #expect(next?.isLit == true, "the bordered cell is always a lit one")
        #expect(controller.chordSequence?.nextStep == 1)
        #expect(controller.chordSequence?.count == 4)
    }

    @Test("⛔ with NO progression there is no border at all")
    func noProgressionNoBorder() {
        let (controller, _) = makeController()
        #expect(controller.chordSequence == nil)
        #expect(controller.chordCells.filter(\.isNextInProgression).isEmpty)
        controller.setProgression(ChordProgressionLibrary.fourChords)
        controller.setProgression(nil)
        #expect(controller.chordSequence == nil)
        #expect(controller.chordCells.filter(\.isNextInProgression).isEmpty,
                "clearing the preset clears the cue with it")
    }

    /// ⭐⭐ **THE USER'S DEFECT, ASSERTED DIRECTLY.** *"Four chords, 50 doowop,
    /// pop-punk does not change keyboard presets (lighted keys)"* — and they were
    /// right: those three light the identical set `{1,4,5,6}` because they are the
    /// same four chords in three orders. The border is what tells them apart.
    ///
    /// ⚠️ **AND THE HONEST LIMIT IS PINNED TOO: Four Chords and Doo-Wop both OPEN
    /// on I, so at rest two of the three still look alike.** They diverge from the
    /// SECOND chord onward, which is what this test measures. m34-g's
    /// lights-run-ahead queue is what would separate them before a note is played;
    /// inventing it here would preempt a choice the user has already made.
    @Test("⭐⭐ the three same-set presets light identically and CUE differently")
    func sameSetPresetsAreToldApartByTheBorder() {
        let (controller, _) = makeController()
        let presets = [ChordProgressionLibrary.fourChords,
                       ChordProgressionLibrary.dooWop,
                       ChordProgressionLibrary.popPunk]
        // The premise, measured rather than assumed.
        #expect(Set(presets.map(\.litDegrees)).count == 1,
                "all three light the same four degrees — that is the whole defect")

        var openings: [String] = []
        var seconds: [String] = []
        for preset in presets {
            controller.setProgression(preset)
            openings.append(nextCell(controller)?.keyLabel ?? "-")
            // Play the chord being cued; the border must move to the next one.
            press(nextCell(controller)?.keyLabel ?? "", on: controller)
            seconds.append(nextCell(controller)?.keyLabel ?? "-")
            controller.releaseAll()
        }
        #expect(openings == ["A", "A", "H"],
                "Four Chords and Doo-Wop both open on I; Pop-Punk opens on vi")
        #expect(seconds == ["G", "H", "F"],
                "…and by the SECOND chord all three are distinct: V, vi, IV")
        #expect(Set(seconds).count == 3)
    }

    @Test("⭐ playing the cued chord moves the border, and it WRAPS after the last one")
    func borderFollowsThePerformance() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        var visited: [String] = []
        for _ in 0..<5 {
            let label = nextCell(controller)?.keyLabel ?? "-"
            visited.append(label)
            press(label, on: controller)
            release(label, on: controller)
        }
        #expect(visited == ["A", "G", "H", "F", "A"],
                "I V vi IV, then back to the top — a four-chord loop is a loop")
    }

    /// ⛔⛔ **A CUE, NEVER A GATE.** The border does not advance when you play
    /// something else, and nothing is refused for it — the whole promise of the
    /// lit-preset design is that you can wander off it.
    ///
    /// ⚠️ **RENAMED AT m34-g AND PINNED TO `.onMatch` EXPLICITLY; THE ASSERTIONS
    /// ARE UNCHANGED.** It used to inherit the default, and the default moved:
    /// the user chose all three advance modes as a runtime switch and
    /// lights-run-ahead leads. *"Does not move the border"* is wait-for-you's
    /// contract, not chord mode's, so this test now says which mode it is
    /// speaking for. `offSequenceChordsSoundAndConsumeAStepInFreeMode` is the
    /// other half — and note what is common to both: **the chord SOUNDS, fully,
    /// in either mode.** That is the part that is not mode-dependent.
    @Test("⛔⛔ WAIT-FOR-YOU: a chord that is NOT the cued one sounds fully and does not move the border")
    func offSequenceChordsSoundAndDoNotAdvance() {
        let (controller, sink) = makeController()
        controller.setAdvanceMode(.onMatch)
        controller.setProgression(ChordProgressionLibrary.fourChords)
        #expect(nextCell(controller)?.keyLabel == "A")
        // "S" is ii — DIM, not in the progression at all.
        let decision = press("s", on: controller)
        #expect(decision == .perform(.note(semitone: 2)), "a dim key still performs")
        #expect(controller.soundingPitches.count == 4, "…and sounds a full chord")
        #expect(sink.last.count == 4, "…which reached the seam")
        #expect(nextCell(controller)?.keyLabel == "A", "and the cue did not budge")
        release("s", on: controller)
        // A LIT chord that is simply not the one being cued: same answer.
        press("f", on: controller)                       // IV — step 4, not step 1
        #expect(controller.soundingPitches.count == 4)
        #expect(nextCell(controller)?.keyLabel == "A")
        #expect(controller.chordSequence?.nextStep == 1)
    }

    /// ⭐⭐ **THE OTHER HALF, AND THE ONE THE DEFAULT NOW TAKES (m34-g).** In
    /// lights-run-ahead you are WRITING: what you played is the take, so the plan
    /// rolls on to its next suggestion rather than waiting for you to find the
    /// one it was offering.
    ///
    /// ⛔ **STILL A CUE, NEVER A GATE — and that is what this test spends most of
    /// its assertions on.** The off-plan chord `performs`, sounds a full
    /// four-note voicing, and reaches the seam. Nothing is refused. The only
    /// difference from wait-for-you is that the suggestion it passed over is not
    /// offered twice.
    @Test("⛔⛔ LIGHTS-RUN-AHEAD: an off-plan chord sounds fully, is refused nothing, and consumes a step")
    func offSequenceChordsSoundAndConsumeAStepInFreeMode() {
        let (controller, sink) = makeController()
        #expect(controller.advanceMode == .free, "the default the user chose")
        controller.setProgression(ChordProgressionLibrary.fourChords)
        #expect(nextCell(controller)?.keyLabel == "A")
        // "S" is ii — DIM, not in the progression at all.
        let decision = press("s", on: controller)
        #expect(decision == .perform(.note(semitone: 2)), "⛔ a dim key still performs")
        #expect(controller.soundingPitches.count == 4, "⛔ …and sounds a full chord")
        #expect(sink.last.count == 4, "⛔ …which reached the seam")
        #expect(controller.chordSequence?.nextStep == 2, "…and it consumed a suggestion")
        #expect(nextCell(controller)?.keyLabel == "G")
        release("s", on: controller)
    }

    /// ⛔ **THE SWITCH IS REAL: three positions, three different answers to the
    /// same press.** A three-position control with two identical positions would
    /// be a UI that lies, so the difference is asserted rather than assumed.
    @Test("⛔ the three advance modes give THREE different answers to one off-plan chord")
    func theThreeModesAreActuallyDifferent() {
        var results: [ChordSequenceAdvanceMode: Int?] = [:]
        for mode in ChordSequenceAdvanceMode.allCases {
            let (controller, _) = makeController()
            controller.setAdvanceMode(mode)
            controller.setProgression(ChordProgressionLibrary.fourChords)
            press("s", on: controller)                   // ii — off-plan
            release("s", on: controller)
            press("a", on: controller)                   // I — the cue
            release("a", on: controller)
            results[mode] = controller.chordSequence?.nextStep
        }
        #expect(results[.onMatch] == 2, "wait-for-you: only the cued chord counted")
        #expect(results[.free] == 3, "lights-run-ahead: both chords consumed a suggestion")
        #expect(results[.onBeat] == 1, "on-the-beat: playing does not move the click's cursor")
        #expect(Set(results.values.map { $0 ?? -1 }).count == 3,
                "three modes, three distinct outcomes — the switch is not decorative")
    }

    // MARK: - The advance-mode switch (m34-g)

    @Test("⭐ the default is LIGHTS-RUN-AHEAD, which is what the user was told would lead")
    func defaultIsLightsRunAhead() {
        let (controller, _) = makeController()
        #expect(controller.advanceMode == .free)
        controller.setProgression(ChordProgressionLibrary.fourChords)
        #expect(controller.chordSequence?.advanceMode == .free,
                "…and the player is armed with it, not with a hardcoded mode")
    }

    @Test("⚠️ changing the advance mode KEEPS your place — it is not a restart")
    func advanceModeChangeKeepsTheCursor() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        press("a", on: controller)
        release("a", on: controller)
        #expect(controller.chordSequence?.nextStep == 2)
        controller.setAdvanceMode(.onBeat)
        #expect(controller.chordSequence?.nextStep == 2,
                "'keep going, but with the click' — not 'start again'")
        #expect(controller.chordSequence?.advanceMode == .onBeat)
        controller.setAdvanceMode(.onMatch)
        #expect(controller.chordSequence?.nextStep == 2)
    }

    @Test("the advance mode SURVIVES a preset change — it is how you play, not what you play")
    func advanceModeSurvivesPresetChange() {
        let (controller, _) = makeController()
        controller.setAdvanceMode(.onMatch)
        controller.setProgression(ChordProgressionLibrary.fourChords)
        controller.setProgression(ChordProgressionLibrary.dooWop)
        #expect(controller.advanceMode == .onMatch)
        #expect(controller.chordSequence?.advanceMode == .onMatch)
    }

    /// ⭐⭐ **ON-THE-BEAT, DRIVEN. m34-i shipped `beat()` with no caller and said
    /// so; this is the caller's contract at the controller boundary.**
    @Test("⭐ on-the-beat moves the cue on a DOWNBEAT and on nothing else")
    func beatMovesTheCueOnlyInOnBeatMode() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        // In the other two modes the click is inert.
        #expect(controller.beat() == false)
        #expect(controller.chordSequence?.nextStep == 1)
        controller.setAdvanceMode(.onMatch)
        #expect(controller.beat() == false)
        controller.setAdvanceMode(.onBeat)
        #expect(controller.beat() == true)
        #expect(nextCell(controller)?.keyLabel == "G")
        #expect(controller.beat() == true)
        #expect(nextCell(controller)?.keyLabel == "H")
        // …and it wraps like every other mode.
        _ = controller.beat()
        _ = controller.beat()
        #expect(controller.chordSequence?.nextStep == 1)
    }

    @Test("a beat with NO progression is inert rather than fatal")
    func beatWithNoSequenceIsInert() {
        let (controller, _) = makeController()
        controller.setAdvanceMode(.onBeat)
        #expect(controller.chordSequence == nil)
        #expect(controller.beat() == false)
    }

    // MARK: - The look-ahead queue (m34-g)

    /// ⭐⭐⭐ **THE ASSERTION THIS ITEM EXISTS FOR, AT THE CELL LEVEL.** m34-i's
    /// own close recorded the limit it could not close: Four Chords and Doo-Wop
    /// light the same four degrees AND both open on I, so **two of the three
    /// presets still looked identical at rest**. The queue is what separates
    /// them before a note is played.
    @Test("⭐⭐ the QUEUE tells Four Chords from Doo-Wop AT REST — the limit m34-i could only state")
    func queueSeparatesThePresetsBeforeANoteIsPlayed() {
        func ranks(_ preset: ChordProgressionPreset) -> [String: Int] {
            let (controller, _) = makeController()
            controller.setProgression(preset)
            var out: [String: Int] = [:]
            for cell in controller.chordCells {
                if cell.isNextInProgression { out[cell.keyLabel] = 0 }
                if let rank = cell.queueRank { out[cell.keyLabel] = rank }
            }
            return out
        }
        let four = ranks(ChordProgressionLibrary.fourChords)
        let dooWop = ranks(ChordProgressionLibrary.dooWop)
        #expect(four == ["A": 0, "G": 1, "H": 2, "F": 3], "I V vi IV")
        #expect(dooWop == ["A": 0, "H": 1, "F": 2, "G": 3], "I vi IV V")
        #expect(four != dooWop,
                "⭐ …and THAT is the difference two identical-looking presets finally have")
        // The cue alone still cannot tell them apart — the defect, restated.
        #expect(four.first { $0.value == 0 }?.key == dooWop.first { $0.value == 0 }?.key)
    }

    /// ⛔ **THE COUNT PINS.** The bug this whole surface keeps re-earning is a
    /// COUNT bug that no assertion could see — ten badges where four were meant.
    /// Exactly one border, exactly `queueDepth` queue marks, and no cell wearing
    /// both.
    @Test("⛔ exactly ONE border and exactly THREE queue marks, on disjoint cells")
    func queueAndBorderCountsArePinned() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        let cells = controller.chordCells
        #expect(cells.filter(\.isNextInProgression).count == 1)
        #expect(cells.compactMap(\.queueRank).count == MusicalTypingController.queueDepth)
        #expect(cells.compactMap(\.queueRank).sorted() == [1, 2, 3],
                "…and they are ranked 1-2-3, not three copies of one rank")
        #expect(cells.filter { $0.isNextInProgression && $0.queueRank != nil }.isEmpty,
                "⛔ no cell is both the cue and in the queue — the two counts stay independent")
        // ⛔ The same narrowing the border has: a degree marks ONE cell, not the
        // four that share it (the +8va run and the colour keys).
        #expect(cells.filter { $0.queueRank != nil }.allSatisfy {
            $0.octaveShift == 0 && !$0.addsColour
        })
    }

    @Test("⛔ with NO progression there is no queue at all")
    func noProgressionNoQueue() {
        let (controller, _) = makeController()
        #expect(controller.chordCells.compactMap(\.queueRank).isEmpty)
        controller.setProgression(ChordProgressionLibrary.fourChords)
        #expect(!controller.chordCells.compactMap(\.queueRank).isEmpty,
                "positive control: a preset DOES produce a queue")
        controller.setProgression(nil)
        #expect(controller.chordCells.compactMap(\.queueRank).isEmpty)
    }

    @Test("the queue MOVES with the performance")
    func queueFollowsThePerformance() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        func rank(_ label: String) -> Int? {
            controller.chordCells.first { $0.keyLabel == label }?.queueRank
        }
        #expect(rank("G") == 1)
        press("a", on: controller)                       // play the cue
        release("a", on: controller)
        #expect(nextCell(controller)?.keyLabel == "G")
        #expect(rank("G") == nil, "the new cue left the queue and took the border")
        #expect(rank("H") == 1)
        #expect(rank("A") == 3, "…and the loop's top is now three away")
    }

    /// ⚠️ A three-chord loop cannot show three chords AFTER the cue without
    /// showing the cue again. Pinned rather than glossed.
    @Test("⚠️ a SHORT progression queues fewer than three, and never re-queues the cue")
    func shortProgressionQueuesFewer() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.jazzTwoFiveOne)   // [2,5,1]
        let cells = controller.chordCells
        #expect(cells.filter(\.isNextInProgression).count == 1)
        #expect(cells.compactMap(\.queueRank).sorted() == [1, 2],
                "three asked for, two available")
        #expect(cells.filter { $0.isNextInProgression && $0.queueRank != nil }.isEmpty)
    }

    // MARK: - Playbox (m34-g)

    /// ⭐⭐ **A GENERATED SEQUENCE GOES THROUGH THE SAME `setProgression` THE
    /// LIBRARY CHIPS USE.** One player, one overlay, one recorder — the lit keys,
    /// the border, the queue and the rewind rule all apply to it unchanged.
    @Test("⭐⭐ a generated plan lights keys through the SAME path a preset does")
    func playboxDrivesTheOnePlayer() {
        let (controller, _) = makeController()
        let plan = PlayboxPlan(degrees: [1, 4, 5, 4], name: "Playbox",
                               provenance: PlayboxProvenance(kind: .ai, detail: "anthropic"))
        controller.applyPlaybox(plan)
        #expect(controller.progression?.degrees == [1, 4, 5, 4])
        #expect(controller.chordSequence?.count == 4)
        #expect(controller.chordSequence?.nextStep == 1)
        #expect(nextCell(controller)?.keyLabel == "A", "the cue starts on I")
        #expect(controller.chordCells.filter(\.isNextInProgression).count == 1)
        // A repeated degree resolves to its soonest rank — two marks for three
        // remaining steps, which the player's own suite pins as the honest cost.
        #expect(controller.chordCells.compactMap(\.queueRank).sorted() == [1, 2])
        #expect(controller.chordSequence?.advanceMode == .free)
    }

    /// ⛔⛔ *"The AI wrote this"* and *"we picked a stock progression"* are
    /// different claims and only one is true at a time.
    @Test("⛔⛔ provenance follows the lights, and a LIBRARY preset clears it")
    func provenanceNeverOutlivesItsSequence() {
        let (controller, _) = makeController()
        #expect(controller.playboxProvenance == nil)
        controller.applyPlaybox(PlayboxPlan(
            degrees: [1, 5, 6, 4], name: "Playbox",
            provenance: PlayboxProvenance(kind: .ai, detail: "anthropic")))
        #expect(controller.playboxProvenance?.isAI == true)
        // Picking a hand-authored preset must not leave "Written by AI" standing.
        controller.setProgression(ChordProgressionLibrary.dooWop)
        #expect(controller.playboxProvenance == nil)
        // …and so must clearing the lights entirely.
        controller.applyPlaybox(PlayboxPlan(
            degrees: [1, 5, 6, 4], name: "Playbox",
            provenance: PlayboxProvenance(kind: .local, detail: "Four Chords")))
        #expect(controller.playboxProvenance?.kind == .local)
        controller.setProgression(nil)
        #expect(controller.playboxProvenance == nil)
    }

    /// ⛔ **A GENERATED SEQUENCE MUST NEVER YANK THE KEY THE USER CHOSE.**
    /// `setProgression` switches the scale to a preset's mode; the Playbox
    /// wrapper is therefore built in the CONTROLLER's mode, and the generator is
    /// asked for that mode in the first place.
    @Test("⛔ applying a generated plan does NOT change the user's key or scale")
    func playboxDoesNotYankTheScale() {
        let (controller, _) = makeController()
        controller.setChordKey(5, mode: .minor)          // F minor
        controller.applyPlaybox(PlayboxPlan(
            degrees: [1, 6, 3, 7], name: "Playbox",
            provenance: PlayboxProvenance(kind: .ai, detail: "anthropic")))
        #expect(controller.chordKey == 5)
        #expect(controller.chordKeyMode == .minor)
        #expect(controller.progression?.mode == .minor)
    }

    /// ⭐ The match is on the DEGREE, which is wider than the border on purpose:
    /// every cell of a lit degree plays that chord, so every one of them counts as
    /// following the lights. The border still lands on exactly one cell.
    @Test("⭐ the +8va run and the colour keys of the cued degree advance it too")
    func anyCellOfTheCuedDegreeAdvances() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        press("k", on: controller)                       // I, an octave up
        release("k", on: controller)
        #expect(nextCell(controller)?.keyLabel == "G", "the +8va I followed the lights")
        // "Y" is the colour key that flips V between triad and seventh.
        #expect(controller.chordCells.first { $0.keyLabel == "Y" }?.degree == 5)
        press("y", on: controller)
        release("y", on: controller)
        #expect(nextCell(controller)?.keyLabel == "H", "the seventh of V counted as V")
    }

    /// ⛔ Mirrors `refusedPressDoesNotMoveTheVoiceLeadingAnchor`: the border says
    /// *play this next*, so a press that made no sound did not play it.
    @Test("⛔ a REFUSED chord does not move the border")
    func refusedChordDoesNotAdvanceTheBorder() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        controller.targetState = .noTrack
        press("a", on: controller)
        #expect(controller.soundingPitches.isEmpty, "nothing sounded")
        #expect(nextCell(controller)?.keyLabel == "A", "so nothing advanced")
        controller.targetState = .ready
        press("a", on: controller)
        #expect(nextCell(controller)?.keyLabel == "G", "…and it still works afterwards")
    }

    /// ⛔ The m23-an law in a new mode: the mouse and the keyboard are ONE
    /// instrument, so they must drive ONE sequence.
    ///
    /// ⚠️ **PINNED TO `.onMatch` EXPLICITLY AT m34-g, ASSERTIONS UNCHANGED** — its
    /// last leg is an off-plan press, which is the one thing the three modes
    /// disagree about. What it is really asserting (mouse and keyboard drive ONE
    /// sequence) is mode-independent.
    @Test("⛔ the on-screen chord row advances the border exactly as the keys do")
    func pointerAdvancesTheBorderToo() {
        let (controller, _) = makeController()
        controller.setAdvanceMode(.onMatch)
        controller.setProgression(ChordProgressionLibrary.fourChords)
        // Cell index is a SEMITONE offset: 0 is the "A" cell (degree I).
        controller.pointerDown(cellIndex: 0)
        #expect(controller.soundingPitches.count == 4)
        #expect(nextCell(controller)?.keyLabel == "G")
        controller.pointerUp()
        controller.pointerDown(cellIndex: 2)             // "S" — ii, off-sequence
        #expect(nextCell(controller)?.keyLabel == "G", "…and off-sequence still does nothing")
        controller.pointerUp()
    }

    // MARK: - What resets the cursor, and what deliberately does not

    @Test("re-picking the SELECTED preset restarts the loop from the top")
    func rePickingThePresetRestarts() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        press("a", on: controller)
        release("a", on: controller)
        #expect(controller.chordSequence?.nextStep == 2)
        controller.setProgression(ChordProgressionLibrary.fourChords)
        #expect(controller.chordSequence?.nextStep == 1,
                "the only gesture on this surface that can mean 'take it from the top'")
    }

    @Test("a modulation and a voicing change KEEP your place in the progression")
    func keyAndVoicingChangesKeepTheCursor() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        press("a", on: controller)
        release("a", on: controller)
        #expect(controller.chordSequence?.nextStep == 2)
        controller.setChordKey(7)                        // G major
        #expect(controller.chordSequence?.nextStep == 2,
                "a progression is written in DEGREES, so it survives a modulation")
        controller.setVoicingPreset(.pad)
        #expect(controller.chordSequence?.nextStep == 2,
                "how a chord is voiced says nothing about which chord comes next")
        #expect(nextCell(controller)?.keyLabel == "G")
    }

    @Test("leaving chord mode, or the mode itself, rewinds the sequence")
    func modeChangesRewindTheCursor() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        press("a", on: controller)
        release("a", on: controller)
        #expect(controller.chordSequence?.nextStep == 2)
        controller.setPlayMode(.notes)
        #expect(controller.chordSequence?.nextStep == 1)
        controller.setPlayMode(.chords)
        press("a", on: controller)
        release("a", on: controller)
        #expect(controller.chordSequence?.nextStep == 2)
        controller.setEnabled(false)
        #expect(controller.chordSequence?.nextStep == 1,
                "session state dies with the session, exactly as lastVoicing does")
    }

    @Test("picking a minor progression switches the scale and keeps the user's tonic")
    func minorProgressionSwitchesMode() {
        let (controller, _) = makeController()
        controller.setChordKey(5)                        // F major
        controller.setProgression(ChordProgressionLibrary.minorRock)
        #expect(controller.chordKey == 5, "the tonic the user picked must survive")
        #expect(controller.chordKeyMode == .minor)
        #expect(homeRow(controller).first == "Fm")
    }

    @Test("clearing the progression leaves every key unlit and every key playable")
    func clearingTheOverlay() {
        let (controller, _) = makeController()
        controller.setProgression(ChordProgressionLibrary.fourChords)
        controller.setProgression(nil)
        #expect(controller.chordCells.allSatisfy { !$0.isLit })
        press("s", on: controller)
        #expect(controller.soundingPitches.count == 4)
    }

    // MARK: - Holding, replacing and releasing

    /// ⭐ **NEW CHORD REPLACES OLD** — §7.2's default, and the reason is the
    /// 8-voice ceiling as much as taste.
    @Test("pressing a second chord key replaces the first chord rather than stacking it")
    func newChordReplacesOld() {
        let (controller, _) = makeController()
        press("a", on: controller)
        let first = controller.soundingPitches
        press("g", on: controller)
        let second = controller.soundingPitches
        #expect(second.count == 4, "two chords stacked: \(second)")
        #expect(second != first)
        #expect(second.allSatisfy { !first.contains($0) || second.contains($0) })
    }

    /// ⛔⛔ **GATE THE ONS, NEVER GATE THE OFFS.** Every fact below refuses a
    /// note-ON. Applying any of them to the release strands a WHOLE CHORD ringing,
    /// which is strictly worse than the single stranded note m23-ct was guarding.
    @Test("a chord releases from every state that would refuse its press")
    func offsAreNeverGated() {
        for (name, mutate) in [
            ("mode off", { (c: MusicalTypingController) in c.setEnabled(false) }),
            ("text editing", { _ in }),
            ("no track", { (c: MusicalTypingController) in c.targetState = .noTrack }),
            ("preview off", { (c: MusicalTypingController) in c.targetState = .previewOff }),
        ] as [(String, (MusicalTypingController) -> Void)] {
            let (controller, sink) = makeController()
            press("a", on: controller)
            #expect(controller.soundingPitches.count == 4, "\(name): setup")
            mutate(controller)
            if controller.isEnabled {
                release("a", on: controller)
                #expect(controller.soundingPitches.isEmpty,
                        "\(name): a chord was left ringing")
            }
            #expect(sink.last.isEmpty, "\(name): the seam still holds \(sink.last)")
        }
    }

    /// The case a per-pitch ledger gets wrong. C major and A minor share C and E;
    /// releasing one while the other is held must not silence the shared tones.
    @Test("two keys sharing a pitch — releasing one keeps the other's notes alive")
    func sharedPitchesSurviveOneRelease() {
        let (controller, _) = makeController(chords: false)
        // Note mode, where layering IS possible: hold two keys that name one
        // pitch after an octave shift, then release one.
        press("a", on: controller)                       // C4 = 60
        press("z", on: controller)                       // octave down
        press("k", on: controller)                       // also 60 at the new octave
        #expect(controller.soundingPitches == [60])
        release("a", on: controller)
        #expect(controller.soundingPitches == [60], "the other holder lost its note")
        release("k", on: controller)
        #expect(controller.soundingPitches.isEmpty)
    }

    @Test("switching play mode mid-hold releases everything rather than stranding it")
    func modeSwitchReleases() {
        let (controller, sink) = makeController()
        press("a", on: controller)
        #expect(!controller.soundingPitches.isEmpty)
        controller.setPlayMode(.notes)
        #expect(controller.soundingPitches.isEmpty)
        #expect(sink.last.isEmpty)
        // And the key-up that arrives afterwards is harmless.
        release("a", on: controller)
        #expect(controller.soundingPitches.isEmpty)
    }

    @Test("a chord never exceeds the live path's voice ceiling")
    func respectsVoiceCeiling() {
        for kind in VoicingPresetKind.allCases {
            let (controller, _) = makeController()
            controller.setVoicingPreset(kind)
            for label in ["a", "s", "d", "f", "g", "h", "j"] {
                press(label, on: controller)
                #expect(controller.soundingPitches.count <= MusicalTypingController.maxVoices,
                        "\(kind): \(controller.soundingPitches.count) voices")
            }
        }
    }

    // MARK: - The on-screen chord row

    @Test("the pointer plays a chord cell through the same voicing path as the keys")
    func pointerPlaysChords() {
        let (typed, _) = makeController()
        press("a", on: typed)
        let byKey = typed.soundingPitches

        let (clicked, sink) = makeController()
        clicked.pointerDown(cellIndex: 0)
        #expect(clicked.soundingPitches == byKey, "the two surfaces voiced it differently")
        #expect(sink.last == byKey)
        clicked.pointerUp()
        #expect(clicked.soundingPitches.isEmpty)
        #expect(sink.last.isEmpty)
    }

    @Test("dragging across the chord row moves the chord instead of piling chords up")
    func pointerDragMovesTheChord() {
        let (controller, _) = makeController()
        controller.pointerDown(cellIndex: 0)
        controller.pointerDown(cellIndex: 5)
        controller.pointerDown(cellIndex: 7)
        #expect(controller.soundingPitches.count == 4)
        controller.pointerUp()
        #expect(controller.soundingPitches.isEmpty)
    }

    @Test("the pointer is refused when the target cannot sound, and says why")
    func pointerRefusal() {
        let (controller, sink) = makeController()
        controller.targetState = .notInstrument
        controller.pointerDown(cellIndex: 0)
        #expect(controller.soundingPitches.isEmpty)
        #expect(controller.lastSilencedBy == .notInstrument)
        #expect(sink.sets.allSatisfy { $0.isEmpty }, "a refused press reached the seam")
    }

    // MARK: - The 17-key layout

    @Test("all 17 keys map to real degrees, and the octave run is capped at one")
    func layoutCoversEveryKey() {
        let (controller, _) = makeController()
        let cells = controller.chordCells
        #expect(cells.count == MusicalTypingRouting.noteCaps.count)
        #expect(cells.count == 17)
        #expect(cells.allSatisfy { (1...7).contains($0.degree) })
        #expect(cells.allSatisfy { $0.octaveShift <= MusicalTypingRouting.maxChordOctaveShift })
        // Every key sounds something. A silently dead key is the failure this
        // project calls characteristic, so it is asserted rather than assumed —
        // and it is asserted for all 17, including the seven accidentals, which
        // an earlier design would have left silent.
        for cap in MusicalTypingRouting.noteCaps {
            guard let semitone = cap.semitone else { continue }
            #expect(!controller.chordPitches(forKeyIndex: semitone).isEmpty,
                    "\(cap.label) sounds nothing")
        }
    }

    /// ⭐ **THE SEVEN ACCIDENTAL KEYS ARE NOT DEAD.** Each one colours the natural
    /// below it, flipping that degree between a triad and its seventh chord —
    /// which is exactly §2.2's lo-fi / neo-soul move, and the alternative was
    /// seven silent keys in the middle of a performance surface.
    @Test("an accidental key colours the natural below it, and the legend says so")
    func accidentalKeysAddColour() {
        let (controller, _) = makeController()
        let byLabel = Dictionary(uniqueKeysWithValues:
            controller.chordCells.map { ($0.keyLabel, $0) })
        // W sits above A. A is C; W is Cmaj7.
        #expect(byLabel["A"]?.chordName == "C")
        #expect(byLabel["A"]?.addsColour == false)
        #expect(byLabel["W"]?.chordName == "Cmaj7")
        #expect(byLabel["W"]?.addsColour == true)
        #expect(byLabel["W"]?.degree == byLabel["A"]?.degree)
        #expect(byLabel["Y"]?.chordName == "G7")      // above G, the V
        #expect(byLabel["U"]?.chordName == "Am7")     // above H, the vi
        // ⚠️ DEGREES 3 AND 7 HAVE NO COLOUR KEY, because a piano has no black key
        // between E and F or between B and C. Pinned so the asymmetry is a
        // recorded fact rather than a surprise.
        #expect(!controller.chordCells.contains { $0.addsColour && $0.degree == 3 })
        #expect(!controller.chordCells.contains { $0.addsColour && $0.degree == 7 })
        // And it flips BOTH ways: on a preset that already voices sevenths, the
        // accidental gives the plain triad back.
        controller.setVoicingPreset(.pad)
        let pad = Dictionary(uniqueKeysWithValues:
            controller.chordCells.map { ($0.keyLabel, $0) })
        #expect(pad["A"]?.chordName == "Cmaj7")
        #expect(pad["W"]?.chordName == "C")
    }

    @Test("an accidental key actually sounds the coloured chord it names")
    func accidentalKeysSoundTheirColour() {
        let (controller, _) = makeController()
        press("w", on: controller)
        // Cmaj7 on the piano preset: C3 bass, then the body with the fifth
        // dropped to fit the 4-note budget (root, third, seventh).
        #expect(controller.soundingPitches.count == 4)
        let body = Set(controller.soundingPitches.dropFirst().map { $0 % 12 })
        #expect(body.contains(11), "the major 7th is missing: \(controller.soundingPitches)")
    }

    @Test("the second run really is an octave higher than the first")
    func secondRunIsHigher() {
        let (controller, _) = makeController()
        press("a", on: controller)                      // degree 1, run 0
        let low = controller.soundingPitches
        release("a", on: controller)
        press("k", on: controller)                      // degree 1, run 1
        let high = controller.soundingPitches
        // The BODY, not the bass — see `octaveKeysMoveChords` for why `min` is
        // the wrong instrument here.
        #expect((high.max() ?? 0) > (low.max() ?? 0))
    }
}
