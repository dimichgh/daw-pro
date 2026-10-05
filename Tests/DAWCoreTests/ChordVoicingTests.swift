import Testing
@testable import DAWCore

// m23-cv — THE VOICING ENGINE'S TEST SUITE.
//
// ⚠️⚠️ **NOBODY ON THIS SIDE OF THE SCREEN CAN HEAR ANYTHING, SO THESE TESTS ARE
// THE EAR.** Not one assertion below says a voicing sounds good — that judgement
// is the user's and is claimed nowhere. What they assert is the arithmetic the
// musical claims reduce to: that the chosen voicing MINIMISES summed semitone
// motion over the whole enumerated space, that no close interval sits under the
// mud floor, that nothing leaves the preset's register window, that the density
// stays under the live path's voice ceiling, and that the same inputs always
// produce the same pitches.
//
// ⭐ **THE MINIMISATION TEST IS THE LOAD-BEARING ONE**, and it is written the
// only way it can be trusted: it re-enumerates every candidate itself through
// the public `candidates` / `cost` pair and asserts the answer is the minimum
// over ALL of them. A test that merely asserted "the F chord came back as
// [60, 65, 69]" would pass just as happily against a lookup table, and would
// tell us nothing about the chord the table did not anticipate.

@Suite("Chord voicing (m23-cv)")
struct ChordVoicingTests {

    // MARK: - Vocabulary

    @Test("The diatonic seven of C major are the seven every progression is drawn from")
    func diatonicMajor() {
        let chords = ChordVoicing.diatonicChords(key: 0, mode: .major)
        #expect(chords.map(\.name) == ["C", "Dm", "Em", "F", "G", "Am", "Bdim"])
        #expect(ChordVoicing.romanNumerals(mode: .major)
            == ["I", "ii", "iii", "IV", "V", "vi", "vii°"])
    }

    @Test("Natural minor gives i ii° III iv v VI VII")
    func diatonicMinor() {
        let chords = ChordVoicing.diatonicChords(key: 9, mode: .minor)
        #expect(chords.map(\.name) == ["Am", "Bdim", "C", "Dm", "Em", "F", "G"])
        #expect(ChordVoicing.romanNumerals(mode: .minor)
            == ["i", "ii°", "III", "iv", "v", "VI", "VII"])
    }

    @Test("A non-C key transposes the whole set, it does not re-spell it")
    func diatonicTransposes() {
        #expect(ChordVoicing.diatonicChords(key: 2, mode: .major).map(\.name)
            == ["D", "Em", "F#m", "G", "A", "Bm", "C#dim"])
    }

    /// ⭐ **THE ONE A NAIVE IMPLEMENTATION GETS WRONG.** "Seventh chords" is not
    /// "the triad with a 7 glued on": the leading-tone chord of a major key is
    /// HALF-diminished, and the seventh on the second degree of a minor key is
    /// too. Shipping `Bdim7` where `Bm7b5` belongs is an audibly wrong note that
    /// no other test in this repo would notice.
    @Test("Diatonic sevenths get the half-diminished leading-tone chord right")
    func diatonicSevenths() {
        #expect(ChordVoicing.diatonicChords(key: 0, mode: .major, density: .seventh)
            .map(\.name) == ["Cmaj7", "Dm7", "Em7", "Fmaj7", "G7", "Am7", "Bm7b5"])
        #expect(ChordVoicing.diatonicChords(key: 9, mode: .minor, density: .seventh)
            .map(\.name) == ["Am7", "Bm7b5", "Cmaj7", "Dm7", "Em7", "Fmaj7", "G7"])
    }

    @Test("Degrees are 1-based and wrap, which is what the 17-key layout needs")
    func degreesWrap() {
        for mode in KeyMode.allCases {
            for degree in 1...7 {
                #expect(ChordVoicing.diatonicChord(degree: degree, key: 0, mode: mode)
                    == ChordVoicing.diatonicChord(degree: degree + 7, key: 0, mode: mode))
            }
        }
    }

    @Test("A root pitch class out of range normalises instead of crashing")
    func rootNormalises() {
        #expect(ChordSymbol(rootPitchClass: 12, quality: .major).rootPitchClass == 0)
        #expect(ChordSymbol(rootPitchClass: -1, quality: .major).rootPitchClass == 11)
        #expect(ChordSymbol(rootPitchClass: 64, quality: .minor).name == "Em")
    }

    // MARK: - Voice leading (§5.2)

    /// ⭐⭐ **THE CENTRAL PROPERTY, PROVED AGAINST THE WHOLE SEARCH SPACE.**
    /// For every preset, every key, both modes and a long run of chords, the
    /// voicing that comes back is the cheapest member of the candidate set — not
    /// merely a plausible one.
    @Test("The chosen voicing minimises the cost over EVERY enumerated candidate")
    func choiceIsTheMinimum() {
        for kind in VoicingPresetKind.allCases where kind != .bass {
            let preset = InstrumentVoicingPreset.preset(for: kind)
            for key in [0, 5, 7, 11] {
                for mode in KeyMode.allCases {
                    var previous: [Int]? = nil
                    for degree in [1, 5, 6, 4, 2, 7, 3, 1] {
                        let chord = ChordVoicing.diatonicChord(
                            degree: degree, key: key, mode: mode, density: preset.density)
                        let voiced = ChordVoicing.voice(chord, previous: previous,
                                                        preset: preset)
                        let body = preset.playsBassNote
                            ? Array(voiced.dropFirst()) : voiced
                        let reference = (previous ?? []).filter {
                            $0 >= preset.bodyWindow.lowerBound
                        }
                        let pool = survivors(chord: chord, preset: preset, previous: previous)
                        #expect(pool.contains(body),
                                "\(kind) \(chord.name): the answer \(body) is not in its own candidate set")
                        let home = preset.homeRootMIDI
                        let chosenCost = ChordVoicing.cost(
                            body, previous: reference, preset: preset,
                            rootPitchClass: chord.rootPitchClass, home: home)
                        for candidate in pool {
                            let cost = ChordVoicing.cost(
                                candidate, previous: reference, preset: preset,
                                rootPitchClass: chord.rootPitchClass, home: home)
                            #expect(chosenCost <= cost,
                                    "\(kind) \(chord.name): \(body) cost \(chosenCost) but \(candidate) cost \(cost)")
                        }
                        previous = voiced
                    }
                }
            }
        }
    }

    /// The textbook case, stated as pitches so a reader can check it by hand:
    /// C major voiced C4–E4–G4, then F major. Efficient voice leading holds the
    /// common tone C, moves E→F by a semitone and G→A by a tone — three semitones
    /// of motion in total, and every other placement of F costs more.
    @Test("C to F holds the common tone and moves the other two by 1 and 2")
    func textbookVoiceLeading() {
        let piano = InstrumentVoicingPreset.preset(for: .piano)
        let f = ChordSymbol(rootPitchClass: 5, quality: .major)
        let voiced = ChordVoicing.voice(f, previous: [48, 60, 64, 67], preset: piano)
        let body = Array(voiced.dropFirst())
        #expect(body == [60, 65, 69])
        #expect(ChordVoicing.voiceLeadingCost(body, [60, 64, 67]) == 3)
    }

    @Test("The cost function is symmetric and zero against itself")
    func costIsSymmetric() {
        let a = [60, 64, 67], b = [59, 62, 67], c = [60, 64, 67, 71]
        #expect(ChordVoicing.voiceLeadingCost(a, a) == 0)
        #expect(ChordVoicing.voiceLeadingCost(a, b) == ChordVoicing.voiceLeadingCost(b, a))
        #expect(ChordVoicing.voiceLeadingCost(a, c) == ChordVoicing.voiceLeadingCost(c, a))
        // Unequal cardinality is handled rather than short-circuited: a triad
        // becoming a seventh adds one voice a semitone away, and nothing else.
        #expect(ChordVoicing.voiceLeadingCost(a, c) == 4)
    }

    /// ⚠️ **A POSITIVE CONTROL FOR THE MINIMISER ITSELF.** If voice leading were
    /// silently disabled — if `voice` ignored `previous` and always returned the
    /// home voicing — this test fails, because the home voicing of G major sits a
    /// long way from a C chord voiced at C4. It is here so a green run of
    /// `choiceIsTheMinimum` cannot come from a `previous` argument that is never
    /// read.
    @Test("Voice leading actually moves the answer — the same chord voices differently after different predecessors")
    func previousChangesTheAnswer() {
        let piano = InstrumentVoicingPreset.preset(for: .piano)
        let g = ChordSymbol(rootPitchClass: 7, quality: .major)
        let afterNothing = ChordVoicing.voice(g, previous: nil, preset: piano)
        let afterC = ChordVoicing.voice(g, previous: [48, 60, 64, 67], preset: piano)
        let afterHighC = ChordVoicing.voice(g, previous: [48, 72, 76, 79], preset: piano)
        #expect(afterNothing != afterC)
        #expect(afterC != afterHighC)
        // And the leading is SMOOTH in each case: no body voice moves more than a
        // major third from its predecessor.
        #expect(ChordVoicing.voiceLeadingCost(Array(afterC.dropFirst()), [60, 64, 67]) <= 4)
        #expect(ChordVoicing.voiceLeadingCost(Array(afterHighC.dropFirst()), [72, 76, 79]) <= 4)
    }

    @Test("With no previous voicing the first chord is root position at the home octave")
    func homeVoicingIsRootPosition() {
        let piano = InstrumentVoicingPreset.preset(for: .piano)
        let c = ChordSymbol(rootPitchClass: 0, quality: .major)
        // C3 bass + a close root-position C4 triad. Both halves matter: the bass
        // is separated from the body (§5.4) and the body is not opened up.
        #expect(ChordVoicing.voice(c, previous: nil, preset: piano) == [48, 60, 64, 67])
    }

    // MARK: - The mud floor (§5.3)

    @Test("No shipped preset ever puts a close interval below its mud floor")
    func mudFloorHolds() {
        for kind in VoicingPresetKind.allCases {
            let preset = InstrumentVoicingPreset.preset(for: kind)
            for key in 0..<12 {
                for mode in KeyMode.allCases {
                    var previous: [Int]? = nil
                    for degree in 1...7 {
                        let chord = ChordVoicing.diatonicChord(
                            degree: degree, key: key, mode: mode, density: preset.density)
                        for shift in [0, 1] {
                            let voiced = ChordVoicing.voice(chord, previous: previous,
                                                            preset: preset,
                                                            octaveShift: shift)
                            #expect(ChordVoicing.satisfiesMudFloor(voiced, preset: preset),
                                    "\(kind) \(chord.name) shift \(shift): \(voiced)")
                        }
                        previous = ChordVoicing.voice(chord, previous: previous,
                                                      preset: preset)
                    }
                }
            }
        }
    }

    /// ⚠️ **WHEN THE FLOOR IS UNSATISFIABLE THE ENGINE DEGRADES, IT DOES NOT GO
    /// SILENT — and the first version of this test asserted the wrong thing.**
    ///
    /// I expected shifting the piano preset down two octaves to break the floor
    /// and wrote `#expect(!satisfiesMudFloor(...))`. It failed, because the engine
    /// was cleverer than the prediction: it returned `[24, 36, 43, 52]`, whose only
    /// non-exempt interval (a major sixth, 43→52) lands its upper note EXACTLY on
    /// the floor. Every other pair is an octave or a fifth. So the filter did not
    /// have to degrade at all.
    ///
    /// The degradation path is real and still needs a test, so this one forces it
    /// with a preset whose entire window lies under the floor — the only way to
    /// make the constraint genuinely unsatisfiable. What is asserted is what
    /// matters: **a chord still comes back.** A key press that produced silence
    /// because an arranging guideline could not be met would be exactly the
    /// "returns something that looks like a valid answer" failure this tree calls
    /// characteristic.
    @Test("An unsatisfiable mud floor degrades to a sounding chord, never to silence")
    func unsatisfiableFloorStillSounds() {
        let cellar = InstrumentVoicingPreset(
            kind: .piano, playsBassNote: false, bassWindow: 30...45,
            bodyWindow: 30...45, maxNotes: 3, spacing: .close, density: .triad,
            rootOnly: false, mudFloorMIDI: 52, minimumSpanSemitones: 0,
            rootPositionBias: 0, homeRootMIDI: 36)
        let chord = ChordVoicing.diatonicChord(degree: 1, key: 0, mode: .major)
        let voiced = ChordVoicing.voice(chord, preset: cellar)
        #expect(voiced.count == 3, "the chord was thinned or silenced: \(voiced)")
        #expect(voiced.allSatisfy { cellar.bodyWindow.contains($0) })
        // The positive control for this test: the floor genuinely CANNOT be met
        // in this window, so a green run above is the degrade path and not a
        // window that happened to be legal after all.
        #expect(!ChordVoicing.satisfiesMudFloor(voiced, preset: cellar),
                "this window was supposed to be unsatisfiable: \(voiced)")
    }

    /// A deep downward octave shift still sounds a full chord in range. This is
    /// the register the octave chip (Z) can actually reach, and it must not thin
    /// out or fall off the bottom of MIDI.
    @Test("A two-octave downward shift still sounds a full, in-range chord")
    func lowShiftStillSounds() {
        let piano = InstrumentVoicingPreset.preset(for: .piano)
        let chord = ChordVoicing.diatonicChord(degree: 1, key: 0, mode: .major)
        let voiced = ChordVoicing.voice(chord, preset: piano, octaveShift: -2)
        #expect(voiced.count == piano.maxNotes)
        #expect(voiced.allSatisfy { (0...127).contains($0) })
    }

    /// The predicate's own positive control — it must be able to say NO. A floor
    /// check that returned true for everything would make the test above vacuous.
    @Test("The mud-floor predicate rejects a low third and forgives a low fifth")
    func mudFloorDiscriminates() {
        let piano = InstrumentVoicingPreset.preset(for: .piano)
        #expect(piano.mudFloorMIDI == 52)
        // A major third sitting on C2 — the classic mud. Upper note is E2 = 40.
        #expect(!ChordVoicing.satisfiesMudFloor([36, 40], preset: piano))
        // A fifth in the same register is fine, which is the exemption §5.3 names.
        #expect(ChordVoicing.satisfiesMudFloor([36, 43], preset: piano))
        // So is an octave.
        #expect(ChordVoicing.satisfiesMudFloor([36, 48], preset: piano))
        // And a compound fifth, which is what a bass note under a chord body is.
        #expect(ChordVoicing.satisfiesMudFloor([36, 55], preset: piano))
        // A single note has no intervals to muddy.
        #expect(ChordVoicing.satisfiesMudFloor([24], preset: piano))
    }

    // MARK: - Register windows and density

    @Test("Every pitch stays inside the preset's register window")
    func staysInWindow() {
        for kind in VoicingPresetKind.allCases {
            let preset = InstrumentVoicingPreset.preset(for: kind)
            for key in 0..<12 {
                for degree in 1...7 {
                    let chord = ChordVoicing.diatonicChord(
                        degree: degree, key: key, mode: .major, density: preset.density)
                    let voiced = ChordVoicing.voice(chord, preset: preset)
                    for pitch in voiced {
                        let inBody = preset.bodyWindow.contains(pitch)
                        let inBass = preset.playsBassNote && preset.bassWindow.contains(pitch)
                        #expect(inBody || inBass,
                                "\(kind) \(chord.name): \(pitch) is outside \(preset.bodyWindow) / \(preset.bassWindow)")
                    }
                }
            }
        }
    }

    @Test("Nothing ever leaves MIDI 0...127, at any octave shift")
    func staysInMIDIRange() {
        for kind in VoicingPresetKind.allCases {
            let preset = InstrumentVoicingPreset.preset(for: kind)
            for shift in -6...6 {
                for key in [0, 6, 11] {
                    let chord = ChordVoicing.diatonicChord(degree: 1, key: key, mode: .major,
                                                           density: preset.density)
                    let voiced = ChordVoicing.voice(chord, preset: preset, octaveShift: shift)
                    #expect(!voiced.isEmpty, "\(kind) shift \(shift) produced silence")
                    #expect(voiced.allSatisfy { (0...127).contains($0) },
                            "\(kind) shift \(shift): \(voiced)")
                }
            }
        }
    }

    /// ⛔ **THE CEILING IS THE LIVE PATH'S, NOT THIS MODULE'S OPINION.** A chord
    /// that filled all 8 voices by itself would have the oldest note of the chord
    /// the user is still holding stolen the instant they touched anything else.
    @MainActor
    @Test("No voicing exceeds the density cap, and the cap leaves headroom under maxVoices")
    func densityCap() {
        #expect(ChordVoicing.maxVoicedNotes < AuditionController.maxVoices)
        for kind in VoicingPresetKind.allCases {
            let preset = InstrumentVoicingPreset.preset(for: kind)
            #expect(preset.maxNotes <= ChordVoicing.maxVoicedNotes)
            for key in 0..<12 {
                for degree in 1...7 {
                    for density in ChordDensity.allCases {
                        let chord = ChordVoicing.diatonicChord(degree: degree, key: key,
                                                               mode: .minor, density: density)
                        let voiced = ChordVoicing.voice(chord, preset: preset)
                        #expect(voiced.count <= preset.maxNotes,
                                "\(kind) \(chord.name): \(voiced.count) notes")
                        #expect(voiced.count == Set(voiced).count, "duplicate pitch in \(voiced)")
                        #expect(voiced == voiced.sorted(), "\(voiced) is not ascending")
                    }
                }
            }
        }
    }

    // MARK: - Per-instrument presets (§6)

    /// ⭐ **THE USER ASKED THIS QUESTION DIRECTLY** — should a bass instrument play
    /// the root only? §6's answer is yes, and it is not a simplification: handing
    /// a bass the full chord is named there as "the single most common way a naive
    /// auto-harmonizer sounds wrong".
    @Test("The bass preset plays exactly one note — the root — in the bass register")
    func bassPlaysRootOnly() {
        let bass = InstrumentVoicingPreset.preset(for: .bass)
        for key in 0..<12 {
            for degree in 1...7 {
                let chord = ChordVoicing.diatonicChord(degree: degree, key: key, mode: .major)
                let voiced = ChordVoicing.voice(chord, previous: [40], preset: bass)
                #expect(voiced.count == 1)
                #expect(voiced[0] % 12 == chord.rootPitchClass)
                #expect(bass.bodyWindow.contains(voiced[0]))
            }
        }
    }

    @Test("Open presets spread more than an octave; close presets do not have to")
    func spacingDiffers() {
        for kind in VoicingPresetKind.allCases where kind != .bass {
            let preset = InstrumentVoicingPreset.preset(for: kind)
            guard preset.spacing == .open else { continue }
            #expect(preset.minimumSpanSemitones >= 12)
            for key in 0..<12 {
                let chord = ChordVoicing.diatonicChord(degree: 1, key: key, mode: .major,
                                                       density: preset.density)
                let voiced = ChordVoicing.voice(chord, preset: preset)
                let span = (voiced.max() ?? 0) - (voiced.min() ?? 0)
                #expect(span >= preset.minimumSpanSemitones,
                        "\(kind) \(chord.name) spans only \(span): \(voiced)")
            }
        }
    }

    /// The guitar preset is the ONE that prefers root position, and the reason is
    /// De Clercq & Temperley's measured 94.1 % (§2.3) — a fact about guitars, not
    /// about keyboards. This asserts the bias exists and only there.
    @Test("Only the guitar preset biases toward root position")
    func rootPositionBiasIsGuitarOnly() {
        for kind in VoicingPresetKind.allCases {
            let preset = InstrumentVoicingPreset.preset(for: kind)
            if kind == .guitar {
                #expect(preset.rootPositionBias > 0)
            } else {
                #expect(preset.rootPositionBias == 0)
            }
        }
        // And it bites: after a chord that would otherwise pull the voicing into
        // an inversion, the guitar preset still lands with the root at the bottom.
        let guitar = InstrumentVoicingPreset.preset(for: .guitar)
        var previous: [Int]? = nil
        for degree in [1, 5, 6, 4] {
            let chord = ChordVoicing.diatonicChord(degree: degree, key: 0, mode: .major)
            let voiced = ChordVoicing.voice(chord, previous: previous, preset: guitar)
            previous = voiced
            #expect((voiced.first ?? 0) % 12 == chord.rootPitchClass,
                    "\(chord.name) is not in root position: \(voiced)")
        }
    }

    @Test("The piano preset separates a bass note from the chord body")
    func pianoSeparatesBass() {
        let piano = InstrumentVoicingPreset.preset(for: .piano)
        #expect(piano.playsBassNote)
        for key in 0..<12 {
            let chord = ChordVoicing.diatonicChord(degree: 1, key: key, mode: .major)
            let voiced = ChordVoicing.voice(chord, preset: piano)
            let bass = voiced[0]
            #expect(piano.bassWindow.contains(bass))
            #expect(bass % 12 == chord.rootPitchClass, "the bass is not the root: \(voiced)")
            #expect(voiced.dropFirst().allSatisfy { piano.bodyWindow.contains($0) })
            #expect((voiced[1] - bass) >= 7, "the bass is not separated: \(voiced)")
        }
    }

    // MARK: - Purity

    @Test("Same inputs, byte-identical output — every time, for every preset")
    func deterministic() {
        for kind in VoicingPresetKind.allCases {
            let preset = InstrumentVoicingPreset.preset(for: kind)
            for key in 0..<12 {
                for degree in 1...7 {
                    let chord = ChordVoicing.diatonicChord(degree: degree, key: key,
                                                           mode: .major,
                                                           density: preset.density)
                    let first = ChordVoicing.voice(chord, previous: [60, 64, 67],
                                                   preset: preset, octaveShift: 1)
                    for _ in 0..<5 {
                        #expect(ChordVoicing.voice(chord, previous: [60, 64, 67],
                                                   preset: preset, octaveShift: 1) == first)
                    }
                }
            }
        }
    }

    @Test("A voicing is never empty, even at an absurd octave shift")
    func neverSilent() {
        for kind in VoicingPresetKind.allCases {
            let preset = InstrumentVoicingPreset.preset(for: kind)
            for shift in [-12, -8, 0, 8, 12] {
                let chord = ChordSymbol(rootPitchClass: 3, quality: .halfDiminished7)
                #expect(!ChordVoicing.voice(chord, preset: preset, octaveShift: shift).isEmpty,
                        "\(kind) at shift \(shift) produced silence")
            }
        }
    }

    // MARK: - Named progressions (§2.2)

    @Test("Every shipped progression uses only real scale degrees and spells itself correctly")
    func progressionsAreWellFormed() {
        #expect(ChordProgressionLibrary.all.count == 6)
        #expect(Set(ChordProgressionLibrary.all.map(\.id)).count == 6)
        for preset in ChordProgressionLibrary.all {
            #expect(!preset.degrees.isEmpty)
            #expect(preset.degrees.allSatisfy { (1...7).contains($0) },
                    "\(preset.id) has a degree outside 1...7")
            #expect(ChordProgressionLibrary.preset(id: preset.id) == preset)
        }
        #expect(ChordProgressionLibrary.fourChords.numeralLine() == "I – V – vi – IV")
        #expect(ChordProgressionLibrary.dooWop.numeralLine() == "I – vi – IV – V")
        #expect(ChordProgressionLibrary.popPunk.numeralLine() == "vi – IV – I – V")
        #expect(ChordProgressionLibrary.jazzTwoFiveOne.numeralLine() == "ii – V – I")
        #expect(ChordProgressionLibrary.blues.numeralLine() == "I – IV – V")
        #expect(ChordProgressionLibrary.minorRock.numeralLine() == "i – VI – III – VII")
    }

    /// The number printed under a lit key — the `1 … 4 2 3` row of the user's own
    /// mock-up. Four Chords is I–V–vi–IV, so I is 1st, IV is 4th, V is 2nd and
    /// vi is 3rd, which is exactly the out-of-order row the mock-up shows.
    @Test("The order numbers match the user's mock-up exactly")
    func progressionOrderMatchesTheMockup() {
        let four = ChordProgressionLibrary.fourChords
        #expect(four.order(ofDegree: 1) == 1)
        #expect(four.order(ofDegree: 5) == 2)
        #expect(four.order(ofDegree: 6) == 3)
        #expect(four.order(ofDegree: 4) == 4)
        // ⛔ AND THE THREE UNUSED DEGREES ARE UNNUMBERED, NOT UNAVAILABLE. `nil`
        // here means DIM, and dim means fully playable — nothing on the sounding
        // path reads this value at all.
        #expect(four.order(ofDegree: 2) == nil)
        #expect(four.order(ofDegree: 3) == nil)
        #expect(four.order(ofDegree: 7) == nil)
        #expect(four.litDegrees == [1, 4, 5, 6])
    }

    @Test("A progression repeated in a real key produces the chords its name promises")
    func fourChordsInC() {
        let names = ChordProgressionLibrary.fourChords.degrees.map {
            ChordVoicing.diatonicChord(degree: $0, key: 0, mode: .major).name
        }
        #expect(names == ["C", "G", "Am", "F"])
        let minorNames = ChordProgressionLibrary.minorRock.degrees.map {
            ChordVoicing.diatonicChord(degree: $0, key: 9, mode: .minor).name
        }
        #expect(minorNames == ["Am", "F", "C", "G"])
    }

    // MARK: - Helpers

    /// Re-derives the candidate pool the engine chose from, through the engine's
    /// OWN filter (`survivingCandidates`) so the two cannot drift. Only the
    /// density trim is re-stated here, and it is deliberately spelled out rather
    /// than called: it is the one step whose rule ("drop the fifth, then the
    /// root") a test should restate independently.
    private func survivors(chord: ChordSymbol,
                           preset: InstrumentVoicingPreset,
                           previous: [Int]?) -> [[Int]] {
        var tones = chord.pitchClasses
        let budget = max(2, min(preset.maxNotes - (preset.playsBassNote ? 1 : 0),
                                ChordVoicing.maxVoicedNotes))
        if tones.count > budget, tones.count >= 3 { tones.remove(at: 2) }
        if tones.count > budget, preset.playsBassNote, tones.count >= 2 { tones.remove(at: 0) }
        tones = Array(tones.prefix(budget))
        let all = ChordVoicing.candidates(pitchClasses: tones,
                                          window: preset.bodyWindow, preset: preset)
        let bass = ChordVoicing.bassPitch(for: chord, previous: previous, preset: preset)
        return ChordVoicing.survivingCandidates(all, preset: preset, bass: bass)
    }
}
