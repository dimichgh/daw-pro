import DAWAppKit
@testable import DAWCore
import Foundation
import Testing

/// p2-sing-pr-words-f2: a door to the Sing sheet is offered exactly when the
/// singer would not refuse the clip for a reason the door can see ahead of
/// time (an audio clip, a drum track).
///
/// A behaviour gate, not a source pin: every fixture is also handed to the REAL
/// planner (`SingPlanner.plan`), and the policy must agree with what it does.
/// The fixture that matters is the drum machine in its `pads` note layout:
/// the export predicate (`SMFProjectExporter.isDrumKit`, the one the roll's
/// chip used) says "not a drum kit" there, while the planner refuses it as a
/// drum track. Nonisolated: everything here is pure value code.
@Suite("Sing entry policy (p2-sing-pr-words-f2)")
struct SingEntryPolicyTests {

    static let tempo = TempoMap(constantBPM: 120)
    static let meter = MeterMap(constant: TimeSignature())

    /// Four one-beat notes with a rest between each, one word on each: a clip
    /// the planner accepts on any melodic track.
    static func melody() -> Clip {
        Clip(name: "Tune", startBeat: 0, lengthBeats: 8,
             notes: [0.0, 2, 4, 6].map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: 1) },
             lyrics: ClipLyrics(text: "one two three four"))
    }

    static func instrumentTrack(_ instrument: InstrumentDescriptor) -> Track {
        Track(name: "Part", kind: .instrument, clips: [melody()], instrument: instrument)
    }

    /// Our drum machine with no saved kit: `DrumKitParams()`, the `pads` layout.
    static let padsDrumMachine = InstrumentDescriptor(kind: .drumSynth)
    /// Our drum machine as a new one is born since W9-DRUMDEF: the `gm` layout.
    static let gmDrumMachine = InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams.newDrumMachineKit)
    static let gmDrumKit = InstrumentDescriptor(
        kind: .soundBank,
        soundBank: SoundBankConfig(source: .generalMIDI, program: 0, bankMSB: GMProgramCatalog.percussionBankMSB))
    static let gmPiano = InstrumentDescriptor(
        kind: .soundBank,
        soundBank: SoundBankConfig(source: .generalMIDI, program: 0, bankMSB: GMProgramCatalog.melodicBankMSB))
    /// A sampler whose zones name drums (a kit-sorted chop): it has drum rows,
    /// yet the planner sings it, so the door stays.
    static let drumRoleSampler = InstrumentDescriptor(
        kind: .sampler,
        sampler: SamplerParams(zones: [
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w10-prwf-kick.wav"),
                        rootPitch: 36, minPitch: 36, maxPitch: 36, drumRole: .kick),
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w10-prwf-snare.wav"),
                        rootPitch: 38, minPitch: 38, maxPitch: 38, drumRole: .snare),
        ], gain: 1))

    /// What the real planner says about `clip` on `track`: nil when it plans.
    static func plannerRefusal(_ clip: Clip, on track: Track) -> SingPlanRefusal? {
        do throws(SingPlanRefusal) {
            _ = try SingPlanner.plan(clip: clip, on: track, tempoMap: tempo, meterMap: meter, octaveShift: 0)
            return nil
        } catch {
            return error
        }
    }

    static func offers(_ track: Track) -> Bool {
        SingEntryPolicy.offersSing(clip: track.clips[0], on: track)
    }

    @Test("a pads drum machine hides the door: the planner refuses it, though the export predicate says it is no drum kit")
    func padsDrumMachineHidesTheDoor() {
        let track = Self.instrumentTrack(Self.padsDrumMachine)
        #expect(track.instrument?.resolvedDrumKit.noteLayout == .pads, "control: the fixture is the pads layout")
        #expect(!SMFProjectExporter.isDrumKit(track), "control: the export predicate answers no here (the bug's cause)")
        #expect(Self.plannerRefusal(track.clips[0], on: track) == .drumTrack, "control: the singer refuses it")
        #expect(!Self.offers(track))
    }

    @Test("a melodic track shows the door, and the planner plans it")
    func melodicTrackShowsTheDoor() {
        for instrument in [InstrumentDescriptor(), Self.gmPiano] {
            let track = Self.instrumentTrack(instrument)
            #expect(Self.plannerRefusal(track.clips[0], on: track) == nil, "control: the singer plans it")
            #expect(Self.offers(track))
        }
    }

    @Test("a General MIDI drum kit hides the door (a sound bank on the drum bank, and a gm-layout drum machine)")
    func generalMIDIDrumKitHidesTheDoor() {
        for instrument in [Self.gmDrumKit, Self.gmDrumMachine] {
            let track = Self.instrumentTrack(instrument)
            #expect(SMFProjectExporter.isDrumKit(track), "control: both predicates agree here")
            #expect(Self.plannerRefusal(track.clips[0], on: track) == .drumTrack)
            #expect(!Self.offers(track))
        }
    }

    @Test("a sampler with drum rows keeps the door: the planner sings it, so drum rows are not the question")
    func drumRoleSamplerKeepsTheDoor() {
        let track = Self.instrumentTrack(Self.drumRoleSampler)
        #expect(DrumLaneMap.lanes(for: track.instrument) != nil, "control: it has drum rows")
        #expect(Self.plannerRefusal(track.clips[0], on: track) == nil, "control: the singer plans it")
        #expect(Self.offers(track))
    }

    @Test("an audio clip is never offered")
    func audioClipIsNotOffered() {
        let clip = Clip(name: "Take", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/w10-prwf-take.wav"))
        let track = Track(name: "Vocal", kind: .audio, clips: [clip])
        #expect(Self.plannerRefusal(clip, on: track) == .audioClip, "control: the singer refuses it")
        #expect(!SingEntryPolicy.offersSing(clip: clip, on: track))
    }

    @Test("on every fixture the door is offered exactly when the planner refuses neither an audio clip nor a drum track")
    func agreesWithThePlannerOnEveryFixture() {
        let instruments = [InstrumentDescriptor(), Self.gmPiano, Self.padsDrumMachine, Self.gmDrumMachine,
                           Self.gmDrumKit, Self.drumRoleSampler]
        var seen: [Bool] = []
        for instrument in instruments {
            let track = Self.instrumentTrack(instrument)
            let refusal = Self.plannerRefusal(track.clips[0], on: track)
            let plannerWouldOpen = refusal != .audioClip && refusal != .drumTrack
            #expect(Self.offers(track) == plannerWouldOpen, "\(instrument.kind): door and singer disagree")
            seen.append(plannerWouldOpen)
        }
        #expect(seen.contains(true) && seen.contains(false), "control: the sweep covers both answers")
    }
}
