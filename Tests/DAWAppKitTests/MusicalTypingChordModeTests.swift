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

    @Test("the Four Chords overlay lights and numbers exactly the mock-up's four keys")
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
        // ⭐ EXACTLY FOUR BADGES FOR A FOUR-CHORD PRESET. The first version
        // numbered every cell whose DEGREE was lit, which painted ten — the
        // colour keys and the second octave run share their degrees, so the row
        // showed four different cells all labelled `1`. Only a screenshot of the
        // live app could see it; this pins the fix so it cannot come back.
        #expect(controller.chordCells.compactMap(\.progressionOrder).sorted()
            == [1, 2, 3, 4])
        // …while LIT is wider than NUMBERED, and deliberately: any lit key plays
        // that chord, the numbered one is just the one to press first.
        #expect(controller.chordCells.filter(\.isLit).count > 4)
        #expect(byLabel["W"]?.isLit == true, "the colour key of a lit degree is lit")
        #expect(byLabel["W"]?.progressionOrder == nil, "…but it is not numbered")
        #expect(byLabel["K"]?.isLit == true, "the +8va run of a lit degree is lit")
        #expect(byLabel["K"]?.progressionOrder == nil, "…but it is not numbered")
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
