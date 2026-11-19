import Foundation
import Testing
@testable import DAWCore

/// m39-w4-10 — the ready-made drum beats, pure (`DrumPatternLibrary`).
/// Design `docs/design/2026-10-07-loop-drum-depth.md` §8, §9.2, §10.2 L2.
///
/// Every expected note number in this file is HAND-TYPED, never read back from
/// `primaryNote(in:)` or the lane map: a test that restates the code under test
/// cannot fail when that code is wrong.
///
/// nonisolated: the library is pure (no `@MainActor` suite added).
@Suite("Drum patterns — the library (m39-w4-10)")
struct DrumPatternLibraryTests {

    /// The drum machine's own pad order, hand-typed (`pads`).
    static let padsNotes: [DrumVoice: Int] = [
        .kick: 36, .snare: 37, .closedHat: 38, .openHat: 39,
        .clap: 40, .tom: 41, .rim: 42, .cymbal: 43,
    ]
    /// General MIDI, hand-typed: Bass Drum 1, Acoustic Snare, Closed Hi-Hat,
    /// Open Hi-Hat, Hand Clap, Low Tom, Side Stick, Crash Cymbal 1.
    static let gmNotes: [DrumVoice: Int] = [
        .kick: 36, .snare: 38, .closedHat: 42, .openHat: 46,
        .clap: 39, .tom: 45, .rim: 37, .cymbal: 49,
    ]

    static func zone(_ note: Int, role: DrumVoice?) -> SamplerZone {
        SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w9-pat-loop.wav"),
                    rootPitch: note, minPitch: note, maxPitch: note,
                    startFrame: note * 100, endFrame: note * 100 + 90, drumRole: role)
    }

    /// A loop sorted into a kit with NO open hat: two kicks (36 loudest, 35),
    /// a snare, a closed hat, and one unrecognised hit on the extra pad 84.
    static var sortedKitWithoutOpenHat: InstrumentDescriptor {
        InstrumentDescriptor(kind: .sampler, sampler: SamplerParams(zones: [
            zone(42, role: .closedHat), zone(35, role: .kick), zone(36, role: .kick),
            zone(38, role: .snare), zone(84, role: nil),
        ]))
    }

    // MARK: - The set

    @Test("the shipped definitions parse with no authoring mistake")
    func definitionsAreSound() {
        #expect(DrumPatternLibrary.authoringProblems == [])
        // Positive control: the checker DOES find a mistake when there is one.
        let broken = DrumPatternLibrary.Definition(
            id: "broken", name: "Broken", summary: "x", bars: 1,
            rows: [(.kick, "x...x...x...x.."), (.snare, "....q.......x..."), (.kick, "x...............")])
        let problems = DrumPatternLibrary.build(broken).problems
        #expect(problems.count == 3, "expected a short row, a bad letter and a doubled drum: \(problems)")
    }

    @Test("seven patterns, in menu order, with the user's L2 pick first")
    func theSetAndItsOrder() {
        let ids = DrumPatternLibrary.patterns.map(\.id)
        #expect(ids == ["basicRock", "fourOnTheFloor", "boomBap", "trap", "halfTime", "breakbeat", "oneDrop"])
        #expect(Set(DrumPatternLibrary.patterns.map(\.name)).count == ids.count)
        #expect(DrumPatternLibrary.firstPattern.id == "basicRock")
    }

    @Test("L2 = eighths: the first pattern is the backbeat with a closed hat on every eighth, every hit at 100")
    func firstPatternIsTheL2Pick() throws {
        let rock = DrumPatternLibrary.firstPattern
        #expect(rock.bars == 1)
        func steps(_ role: DrumVoice) -> [Int] { rock.hits.filter { $0.role == role }.map(\.step) }
        #expect(steps(.kick) == [0, 8])
        #expect(steps(.snare) == [4, 12])
        #expect(steps(.closedHat) == [0, 2, 4, 6, 8, 10, 12, 14])
        #expect(rock.roles == [.kick, .snare, .closedHat])
        // The listening material the pick was made on held every hit at 100.
        #expect(rock.hits.allSatisfy { $0.velocity == 100 })
    }

    @Test("every pattern is 1 or 2 bars of sixteenths, with legal velocities and a beginner's description")
    func everyPatternIsWellFormed() {
        let jargon = ["MIDI", "velocity", "BPM", "16th", "sixteenth", "syncopat", "quantiz", "1/16",
                      "transient", "ghost note"]
        for pattern in DrumPatternLibrary.patterns {
            #expect((1...2).contains(pattern.bars), "\(pattern.id)")
            #expect(!pattern.hits.isEmpty, "\(pattern.id)")
            #expect(pattern.hits.allSatisfy { (0..<(pattern.bars * 16)).contains($0.step) }, "\(pattern.id)")
            #expect(pattern.hits.allSatisfy { (1...127).contains($0.velocity) }, "\(pattern.id)")
            // One hit per drum per step: a doubled hit would play twice as loud.
            let keys = pattern.hits.map { "\($0.role.rawValue)@\($0.step)" }
            #expect(Set(keys).count == keys.count, "\(pattern.id) has a doubled hit")
            #expect(pattern.summary.count >= 40 && pattern.summary.count <= 220, "\(pattern.id)")
            for word in jargon {
                #expect(pattern.summary.range(of: word, options: .caseInsensitive) == nil,
                        "\(pattern.id)'s description uses '\(word)'")
            }
        }
    }

    @Test("the only shared velocity is the accent, and trap's clap is that accent")
    func accentIsTheSharedConstant() throws {
        let legend: Set<Int> = [NoteEntryDefaults.accentVelocity, 112, 100, 84, 68, 40]
        for pattern in DrumPatternLibrary.patterns {
            #expect(pattern.hits.allSatisfy { legend.contains($0.velocity) }, "\(pattern.id)")
        }
        let trap = try #require(DrumPatternLibrary.pattern(named: "trap"))
        let claps = trap.hits.filter { $0.role == .clap }
        #expect(claps.count == 2)
        #expect(claps.allSatisfy { $0.velocity == NoteEntryDefaults.accentVelocity })
        #expect(DrumPatternLibrary.velocity(for: "A") == NoteEntryDefaults.accentVelocity)
    }

    @Test("four on the floor: a kick on every beat (the P2 premise)")
    func fourOnTheFloorKicksEveryBeat() throws {
        let four = try #require(DrumPatternLibrary.pattern(named: "fourOnTheFloor"))
        #expect(four.hits.filter { $0.role == .kick }.map(\.step) == [0, 4, 8, 12])
        #expect(four.roles.contains(.openHat), "the P3 fixture needs a pattern with an open hat")
    }

    @Test("a pattern is found by its id or its name, whatever the case, spaces or dashes")
    func lookupByName() {
        for spelling in ["fourOnTheFloor", "Four on the Floor", "four-on-the-floor", "FOUR ON THE FLOOR"] {
            #expect(DrumPatternLibrary.pattern(named: spelling)?.id == "fourOnTheFloor", "\(spelling)")
        }
        #expect(DrumPatternLibrary.pattern(named: "half time")?.id == "halfTime")
        #expect(DrumPatternLibrary.pattern(named: "Half-Time")?.id == "halfTime")
        #expect(DrumPatternLibrary.pattern(named: "polka") == nil)
        #expect(DrumPatternLibrary.pattern(named: "") == nil)
        #expect(DrumPatternLibrary.pattern(named: " - ") == nil)
    }

    // MARK: - Roles to notes, through the target's own map

    @Test("a drum machine's drums sit on ITS layout's notes: pads 36–43, General MIDI on a new kit")
    func drumMachineRoleNotes() throws {
        var pads = DrumKitParams()
        pads.noteLayout = .pads
        let padsMachine = InstrumentDescriptor(kind: .drumSynth, drumKit: pads)
        #expect(DrumPatternLibrary.roleNotes(for: padsMachine) == Self.padsNotes)

        let newMachine = InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams.newDrumMachineKit)
        #expect(DrumKitParams.newDrumMachineKit.noteLayout == .gm)
        #expect(DrumPatternLibrary.roleNotes(for: newMachine) == Self.gmNotes)

        // A drum machine saved and never edited (no kit stored) plays the factory pads kit.
        let neverEdited = InstrumentDescriptor(kind: .drumSynth)
        #expect(DrumPatternLibrary.roleNotes(for: neverEdited) == Self.padsNotes)
    }

    @Test("the General MIDI drum kit plays every drum at its General MIDI note, side stick and clap included")
    func generalMIDIKitRoleNotes() {
        let kit = GMProgramCatalog.standardDrumKit
        let drums = InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: kit.program, bankMSB: kit.bankMSB))
        #expect(DrumPatternLibrary.roleNotes(for: drums) == Self.gmNotes)
        // A melodic sound bank is not a drum kit.
        let piano = InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: 0, bankMSB: 0))
        #expect(DrumPatternLibrary.roleNotes(for: piano) == nil)
    }

    @Test("a sorted kit plays each labelled drum on its first pad; a drum no pad has is absent")
    func sortedKitRoleNotes() throws {
        let notes = try #require(DrumPatternLibrary.roleNotes(for: Self.sortedKitWithoutOpenHat))
        #expect(notes == [.kick: 36, .snare: 38, .closedHat: 42])
        #expect(notes[.openHat] == nil)
    }

    @Test("anything that is not a drum instrument has no drum notes, a stored drum kit notwithstanding")
    func nonDrumInstrumentsHaveNone() {
        #expect(DrumPatternLibrary.roleNotes(for: nil) == nil)
        #expect(DrumPatternLibrary.roleNotes(for: InstrumentDescriptor(kind: .polySynth)) == nil)
        #expect(DrumPatternLibrary.roleNotes(for: InstrumentDescriptor(kind: .testTone)) == nil)
        #expect(DrumPatternLibrary.roleNotes(for: InstrumentDescriptor(kind: .audioUnit)) == nil)
        // A sampler with no drum labels keeps its melodic keys.
        let melodic = InstrumentDescriptor(kind: .sampler, sampler: SamplerParams(zones: [Self.zone(60, role: nil)]))
        #expect(DrumPatternLibrary.roleNotes(for: melodic) == nil)
        // ⛔ A drum kit carried under the poly synth is not heard: `drumKit` does not imply `kind`.
        let carried = InstrumentDescriptor(kind: .polySynth, drumKit: DrumKitParams.newDrumMachineKit)
        #expect(DrumPatternLibrary.roleNotes(for: carried) == nil)
    }

    // MARK: - Notes

    @Test("a two-bar pattern over three bars repeats its first bar; over one bar it stops at the bar line")
    func tilingAndTruncation() throws {
        let boom = try #require(DrumPatternLibrary.pattern(named: "boomBap"))
        let two = DrumPatternLibrary.notes(for: boom, bars: 2, roleNotes: Self.gmNotes).notes
        let three = DrumPatternLibrary.notes(for: boom, bars: 3, roleNotes: Self.gmNotes).notes
        let one = DrumPatternLibrary.notes(for: boom, bars: 1, roleNotes: Self.gmNotes).notes
        func shape(_ notes: [MIDINote]) -> [String] {
            notes.map { "\($0.pitch)@\($0.startBeat)v\($0.velocity)" }
        }
        let barOne = two.filter { $0.startBeat < 4 }
        #expect(shape(one) == shape(barOne))
        #expect(two.count == boom.hits.count)
        // Bar 3 is bar 1, eight beats later.
        let barThree = three.filter { $0.startBeat >= 8 }
        #expect(shape(barThree) == shape(barOne.map {
            MIDINote(pitch: $0.pitch, velocity: $0.velocity, startBeat: $0.startBeat + 8, lengthBeats: $0.lengthBeats)
        }))
        #expect(three.count == boom.hits.count + barOne.count)
        // Every hit is one step long and on the sixteenth grid.
        #expect(three.allSatisfy { $0.lengthBeats == 0.25 })
        #expect(three.allSatisfy { ($0.startBeat * 4).rounded() == $0.startBeat * 4 })
    }

    @Test("P3 (pure): a kit with no open hat gets no open-hat note, nothing in its place, and the drum is named")
    func missingDrumIsLeftOut() throws {
        let four = try #require(DrumPatternLibrary.pattern(named: "fourOnTheFloor"))
        let roleNotes = try #require(DrumPatternLibrary.roleNotes(for: Self.sortedKitWithoutOpenHat))
        let built = DrumPatternLibrary.notes(for: four, bars: 2, roleNotes: roleNotes)
        #expect(!built.notes.contains { $0.pitch == 46 }, "no note on the General MIDI open hat")
        // Nothing in its place: exactly the kicks (the kit has no clap either).
        #expect(built.notes.count == 8)
        #expect(built.notes.allSatisfy { $0.pitch == 36 })
        #expect(built.written == [DrumPatternRoleUse(role: .kick, note: 36, hits: 8)])
        #expect(built.leftOut == [DrumPatternRoleUse(role: .openHat, note: nil, hits: 8),
                                  DrumPatternRoleUse(role: .clap, note: nil, hits: 4)])
        let sentence = DrumPatternLibrary.leftOutSentence(built.leftOut[0])
        #expect(sentence.contains(DrumVoice.openHat.displayName))
        #expect(sentence.range(of: "open hat", options: .caseInsensitive) != nil)
        #expect(sentence.contains("8 Open Hat hits"))
        #expect(DrumPatternLibrary.leftOutSentence(DrumPatternRoleUse(role: .clap, note: nil, hits: 1))
                    .contains("1 Clap hit was"))
    }
}
