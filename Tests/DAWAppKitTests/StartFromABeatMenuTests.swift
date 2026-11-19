import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// m39-w4-10 UI — the step grid's "Start from a beat" menu, the headless half
/// (`StepStartFromBeat`). Design `docs/design/2026-10-07-loop-drum-depth.md` §8
/// (last bullet) and §10.2 L2 (the user's pick is listed first).
///
/// What the menu offers, where, and how a pick's answer becomes the lines the
/// grid shows. The write itself (twin-track equality with `clip.addDrumPattern`,
/// one undo step, a missing drum left out) is pinned at the store, in
/// `StartFromABeatStoreTests` (an extension of the `@MainActor` suite
/// `DrumKitStoreTests`).
///
/// Deliberately NOT `@MainActor`: every function here is a pure static, and no
/// store is built (no `@MainActor` slot spent).
@Suite("Start from a beat — the menu (m39-w4-10 UI)")
struct StartFromABeatMenuTests {

    // MARK: - Fixtures (hand-typed; the instruments, never the lane rows)

    static let newDrumMachine = InstrumentDescriptor(kind: .drumSynth,
                                                     drumKit: DrumKitParams.newDrumMachineKit)
    static var padsDrumMachine: InstrumentDescriptor {
        var kit = DrumKitParams()
        kit.noteLayout = .pads
        return InstrumentDescriptor(kind: .drumSynth, drumKit: kit)
    }
    static let gmKit = InstrumentDescriptor(
        kind: .soundBank,
        soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                   bankMSB: GMProgramCatalog.percussionBankMSB))
    static let sortedKit = InstrumentDescriptor(kind: .sampler, sampler: SamplerParams(zones: [
        SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w9-patui-loop.wav"),
                    rootPitch: 36, minPitch: 36, maxPitch: 36, startFrame: 0, endFrame: 90,
                    drumRole: .kick),
    ]))
    static let polySynth = InstrumentDescriptor(kind: .polySynth)
    static let melodicSampler = InstrumentDescriptor(kind: .sampler, sampler: SamplerParams(zones: [
        SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w9-patui-piano.wav"),
                    rootPitch: 60, minPitch: 0, maxPitch: 127, startFrame: 0, endFrame: 90),
    ]))

    static var drumKits: [(String, InstrumentDescriptor)] {
        [("new drum machine", newDrumMachine), ("pads drum machine", padsDrumMachine),
         ("General MIDI kit", gmKit), ("sorted sampler kit", sortedKit)]
    }

    static let oneNote = [MIDINote(pitch: 36, startBeat: 0, lengthBeats: 0.25)]

    // MARK: - The menu

    @Test("the menu lists the seven beats in library order, Basic Rock (the user's L2 pick) first")
    func menuListsTheSevenBeatsInLibraryOrder() throws {
        let lanes = try #require(DrumLaneMap.lanes(for: Self.newDrumMachine))
        let choices = try #require(StepStartFromBeat.choices(drumLanes: lanes, notes: []))
        // Hand-typed: the order the menu must show, not a re-derivation.
        #expect(choices.map(\.id) == ["basicRock", "fourOnTheFloor", "boomBap", "trap",
                                      "halfTime", "breakbeat", "oneDrop"])
        #expect(choices.map(\.name) == ["Basic Rock", "Four on the Floor", "Boom Bap", "Trap",
                                        "Half-Time", "Breakbeat", "One Drop"])
        #expect(choices.first?.name == "Basic Rock")
        // Each item's help is that beat's own one-line description.
        #expect(choices.map(\.help) == DrumPatternLibrary.patterns.map(\.summary))
        #expect(choices.allSatisfy { !$0.help.isEmpty })
        #expect(choices.first?.help.contains("closed hi-hat") == true)
    }

    @Test("the menu is offered on an EMPTY clip of every kind of drum track, the same seven each time")
    func offeredOnEveryEmptyDrumClip() throws {
        for (label, instrument) in Self.drumKits {
            let lanes = DrumLaneMap.lanes(for: instrument)
            #expect(lanes != nil, "\(label) has drum rows")
            let choices = StepStartFromBeat.choices(drumLanes: lanes, notes: [])
            #expect(choices?.count == 7, "\(label)")
            #expect(choices?.first?.id == "basicRock", "\(label)")
        }
    }

    @Test("a clip that already has a note, or a track that does not play drums, is not offered the menu")
    func notOfferedOnANonEmptyOrNonDrumClip() {
        // Non-empty drum clips: any note at all, a latent one past the end included.
        let latent = [MIDINote(pitch: 38, startBeat: 64, lengthBeats: 0.25)]
        for (label, instrument) in Self.drumKits {
            let lanes = DrumLaneMap.lanes(for: instrument)
            #expect(StepStartFromBeat.choices(drumLanes: lanes, notes: Self.oneNote) == nil, "\(label)")
            #expect(StepStartFromBeat.choices(drumLanes: lanes, notes: latent) == nil, "\(label) latent")
        }
        // Not drum tracks: the melodic window, empty or not.
        for instrument in [Self.polySynth, Self.melodicSampler] {
            let lanes = DrumLaneMap.lanes(for: instrument)
            #expect(lanes == nil)
            #expect(StepStartFromBeat.choices(drumLanes: lanes, notes: []) == nil)
        }
        #expect(StepStartFromBeat.choices(drumLanes: nil, notes: []) == nil)
        // A GM sound bank on a melodic bank (a piano) is not a drum kit either.
        let piano = InstrumentDescriptor(kind: .soundBank,
                                         soundBank: SoundBankConfig(source: .generalMIDI, program: 0))
        #expect(StepStartFromBeat.choices(drumLanes: DrumLaneMap.lanes(for: piano), notes: []) == nil)
    }

    // MARK: - What a pick shows

    static func result(warnings: [String], leftOut: [DrumPatternRoleUse] = []) throws -> DrumPatternFillResult {
        let pattern = try #require(DrumPatternLibrary.pattern(named: "fourOnTheFloor"))
        return DrumPatternFillResult(
            clip: Clip(name: "Beat", notes: []), pattern: pattern, bars: 1,
            written: [DrumPatternRoleUse(role: .kick, note: 36, hits: 4)],
            leftOut: leftOut, warnings: warnings)
    }

    @Test("a pick that wrote the beat shows the result line, then every warning, and changed the clip")
    func pickShowsTheResultLineThenTheWarnings() throws {
        let plain = StepStartFromBeat.outcome { try Self.result(warnings: []) }
        #expect(plain.changed)
        #expect(!plain.isWarning)
        #expect(plain.lines == ["Added the Four on the Floor beat: 4 hits on Kick."])

        let leftOut = DrumPatternRoleUse(role: .openHat, note: nil, hits: 4)
        let sentence = DrumPatternLibrary.leftOutSentence(leftOut)
        let warned = StepStartFromBeat.outcome { try Self.result(warnings: [sentence], leftOut: [leftOut]) }
        #expect(warned.changed)
        #expect(warned.isWarning)
        #expect(warned.lines.count == 2)
        #expect(warned.lines.last?.contains("Open Hat") == true, "the result line NAMES the missing drum")
    }

    @Test("a refused pick changes nothing and shows the refusal sentence verbatim")
    func refusedPickShowsTheSentence() {
        let error = DrumPatternFillError.clipNotEmpty(clipName: "Verse Beat", noteCount: 3)
        let refused = StepStartFromBeat.outcome { throw error }
        #expect(!refused.changed)
        #expect(refused.isWarning)
        #expect(refused.lines == [error.errorDescription ?? ""])
        #expect(refused.lines.first?.contains("'Verse Beat' already has 3 notes") == true)
        #expect(StepBeatOutcome.nothing.lines.isEmpty && !StepBeatOutcome.nothing.changed)
    }
}
