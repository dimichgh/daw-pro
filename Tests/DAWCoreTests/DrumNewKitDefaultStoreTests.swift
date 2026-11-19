import DAWCore
import Foundation
import Testing

// W9-DRUMDEF (m39-hat-default + m39-dm-gm-default) — the STORE half: where a drum
// machine is born, and what a kind change does to a kit.
//
// ⛔ AN EXTENSION OF `DrumKitStoreTests`, NOT A NEW SUITE: these touch
// `ProjectStore`, which is `@MainActor`, and the tree takes no new `@MainActor`
// suite. Swift Testing runs `@Test`s declared in an extension of a suite type
// inside that suite. Its own helpers are `private`, so this file carries two
// small ones.
extension DrumKitStoreTests {

    /// A store holding one instrument track that already plays `instrument` —
    /// what opening a saved song gives (`ProjectStore(tracks:)`, no edit, no undo).
    fileprivate func w9Store(with instrument: InstrumentDescriptor) -> (ProjectStore, UUID) {
        let track = Track(name: "Drums", kind: .instrument, instrument: instrument)
        return (ProjectStore(tracks: [track]), track.id)
    }

    fileprivate func w9Instrument(_ store: ProjectStore, _ id: UUID) -> InstrumentDescriptor? {
        store.tracks.first { $0.id == id }?.instrument
    }

    /// ⭐ THE BIRTH. The instrument picker and `track.setInstrument {kind:
    /// "drumSynth"}` both call `setInstrument(kind: .drumSynth)`; the new kit must
    /// be WRITTEN into the track (a nil kit means "saved before" and plays the
    /// old factory kit) — from a fresh track and from every other instrument.
    @Test("W9-DRUMDEF: a drum machine picked on any other instrument is BORN with the picks, written in")
    func w9PickedDrumMachineIsBornNew() throws {
        for from in InstrumentDescriptor.Kind.allCases where from != .drumSynth {
            let store = ProjectStore()
            let id = store.addTrack(name: "Drums", kind: .instrument).id
            if from != .polySynth { _ = try store.setInstrument(id: id, kind: from) }
            #expect(w9Instrument(store, id)?.drumKit == nil, "\(from): a kit grew before the drum machine")
            _ = try store.setInstrument(id: id, kind: .drumSynth)
            let born = try #require(w9Instrument(store, id))
            #expect(born.kind == .drumSynth)
            #expect(born.drumKit == DrumKitParams.newDrumMachineKit, "\(from): not born with the new kit")
            #expect(born.drumKit?.hatsLevelDb == 23.4 && born.drumKit?.cymbalsLevelDb == 5.7
                        && born.drumKit?.noteLayout == .gm, "\(from): the picks are not in the stored kit")
        }
    }

    /// ⛔ A SAVED SONG'S NEVER-EDITED DRUM MACHINE IS LEFT ALONE: re-picking it,
    /// or editing an unrelated knob, keeps its kit nil — byte for byte the file it
    /// was opened from.
    @Test("W9-DRUMDEF: re-picking a saved never-edited drum machine, or an unrelated edit, leaves its kit nil")
    func w9SavedDrumMachineIsLeftAlone() throws {
        let (store, id) = w9Store(with: InstrumentDescriptor(kind: .drumSynth))
        _ = try store.setInstrument(id: id, kind: .drumSynth)
        #expect(w9Instrument(store, id)?.drumKit == nil, "re-picking wrote a kit into a saved drum machine")
        _ = try store.setInstrument(id: id, cutoffHz: 900)
        #expect(w9Instrument(store, id)?.drumKit == nil, "an unrelated knob wrote a kit")
        #expect(w9Instrument(store, id)?.resolvedDrumKit == DrumKitParams())
    }

    /// ⛔ THE COMPARE-IN-THE-PICKER HAZARD. A saved song's never-edited drum
    /// machine, switched to another instrument and back, must come back as the
    /// kit it PLAYED (pad layout, trims 0): its beat is written in pad order. The
    /// kit is written out on the way OUT, never inferred on the way back.
    @Test("W9-DRUMDEF: a saved drum machine left for another instrument and picked again plays as before")
    func w9LeavingAndComingBackKeepsTheSound() throws {
        for via in InstrumentDescriptor.Kind.allCases where via != .drumSynth {
            let (store, id) = w9Store(with: InstrumentDescriptor(kind: .drumSynth))
            _ = try store.setInstrument(id: id, kind: via)
            #expect(w9Instrument(store, id)?.drumKit == DrumKitParams(),
                    "\(via): leaving did not write out the kit it played")
            _ = try store.setInstrument(id: id, kind: .drumSynth)
            let back = try #require(w9Instrument(store, id))
            #expect(back.resolvedDrumKit == DrumKitParams(), "\(via): came back as a different kit")
            #expect(back.resolvedDrumKit.noteLayout == .pads)
        }
    }

    @Test("W9-DRUMDEF: switching between two other instruments never grows a drum kit")
    func w9OtherSwitchesGrowNoKit() throws {
        let store = ProjectStore()
        let id = store.addTrack(name: "Keys", kind: .instrument).id
        for kind in [InstrumentDescriptor.Kind.soundBank, .sampler, .testTone, .audioUnit, .polySynth] {
            _ = try store.setInstrument(id: id, kind: kind)
            #expect(w9Instrument(store, id)?.drumKit == nil, "\(kind): a drum kit grew")
        }
    }

    @Test("W9-DRUMDEF: a new drum machine keeps its kit through another instrument and back")
    func w9NewKitSurvivesAKindRoundTrip() throws {
        let store = ProjectStore()
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try store.setInstrument(id: id, kind: .drumSynth)
        _ = try store.setInstrument(id: id, kind: .soundBank)
        _ = try store.setInstrument(id: id, kind: .drumSynth)
        #expect(w9Instrument(store, id)?.drumKit == DrumKitParams.newDrumMachineKit)
    }

    /// A one-knob edit starts from the kit the track PLAYS: the factory kit on a
    /// saved never-edited drum machine (so it keeps its sound but for that knob),
    /// a new drum machine's kit on a track that is not one yet.
    @Test("W9-DRUMDEF: a one-knob drum edit starts from the kit the track plays")
    func w9DrumParamStartsFromWhatPlays() throws {
        let (store, saved) = w9Store(with: InstrumentDescriptor(kind: .drumSynth))
        _ = try store.setInstrument(id: saved, drumParam: (name: "kick.decay", value: 0.9))
        var expectedSaved = DrumKitParams()
        expectedSaved.setValue(0.9, forParamName: "kick.decay")
        #expect(w9Instrument(store, saved)?.drumKit == expectedSaved)

        let fresh = store.addTrack(name: "Keys", kind: .instrument).id
        _ = try store.setInstrument(id: fresh, drumParam: (name: "kick.decay", value: 0.9))
        var expectedFresh = DrumKitParams.newDrumMachineKit
        expectedFresh.setValue(0.9, forParamName: "kick.decay")
        #expect(w9Instrument(store, fresh)?.drumKit == expectedFresh)
        #expect(w9Instrument(store, fresh)?.kind == .polySynth, "a drum edit changed the kind")
    }
}
