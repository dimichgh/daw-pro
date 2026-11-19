import DAWCore
import Foundation
import Testing

// m39-w4-10 — `ProjectStore.addDrumPattern`, the STORE half of `clip.addDrumPattern`.
// Design `docs/design/2026-10-07-loop-drum-depth.md` §8, §9.2.
//
// Appended to the existing `@MainActor` suite `DrumKitStoreTests` (the store is
// main-actor; no new `@MainActor` suite: the `KitSliceWireTests` precedent).
//
// ⛔ THE OVERLAP DECISION, MEASURED HERE RATHER THAN ASSUMED: `addMIDIClip`, the
// funnel this verb uses, TRIMS a resident it lands on (`overlapCensusTheFunnelTrims`).
// The verb refuses instead (`overlapIsRefusedAndNothingChanges`), the `clip.addAudio`
// m33-j rule.

/// A fixed drum-pattern fixture vocabulary (hand-typed notes; never `primaryNote`).
enum DrumPatternStoreFixture {
    static let gmKick = 36, gmSnare = 38, gmClosedHat = 42, gmOpenHat = 46

    static func zone(_ note: Int, role: DrumVoice?) -> SamplerZone {
        SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w9-pat-loop.wav"),
                    rootPitch: note, minPitch: note, maxPitch: note,
                    startFrame: note * 100, endFrame: note * 100 + 90, drumRole: role)
    }

    /// A sampler sorted into a kit with no open hat (and no clap): kick, snare, closed hat.
    /// ⚠️ Built straight into the track: `setInstrument` would open the zone files.
    static func sortedKitTrack(name: String = "Chopped Loop") -> Track {
        Track(name: name, kind: .instrument, instrument: InstrumentDescriptor(
            kind: .sampler, sampler: SamplerParams(zones: [
                zone(36, role: .kick), zone(38, role: .snare), zone(42, role: .closedHat),
                zone(84, role: nil),
            ])))
    }
}

extension DrumKitStoreTests {

    /// A new song with one NEW drum machine (General MIDI keys). ⚠️ `kind: .drumSynth`
    /// is set explicitly: a stored `drumKit` alone would leave the poly synth playing.
    private func patSong() throws -> (ProjectStore, UUID) {
        let store = ProjectStore(projectName: "W9-PAT store")
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try store.setInstrument(id: id, kind: .drumSynth)
        #expect(store.tracks.first { $0.id == id }?.instrument?.kind == .drumSynth)
        #expect(store.tracks.first { $0.id == id }?.instrument?.drumKit?.noteLayout == .gm)
        return (store, id)
    }

    private func patClips(_ store: ProjectStore, _ id: UUID) -> [Clip] {
        store.tracks.first { $0.id == id }?.clips ?? []
    }

    private func patMessage(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return (error as? LocalizedError)?.errorDescription ?? "\(error)" }
    }

    @Test("m39-w4-10: a drum beat is ONE new clip and ONE undo step, on the kit's own notes")
    func patternIsOneClipAndOneUndoStep() throws {
        let (store, id) = try patSong()
        let undoBefore = store.undoHistory().undo.count
        let written = try store.addDrumPattern(named: "basicRock", toTrack: id)

        #expect(store.undoHistory().undo.count == undoBefore + 1)
        #expect(patClips(store, id).count == 1)
        let clip = try #require(patClips(store, id).first)
        #expect(clip.id == written.clip.id)
        #expect(clip.name == "Basic Rock")
        #expect(clip.startBeat == 0 && clip.lengthBeats == 4)
        let notes = try #require(clip.notes)
        func beats(_ pitch: Int) -> [Double] { notes.filter { $0.pitch == pitch }.map(\.startBeat) }
        #expect(beats(DrumPatternStoreFixture.gmKick) == [0, 2])
        #expect(beats(DrumPatternStoreFixture.gmSnare) == [1, 3])
        #expect(beats(DrumPatternStoreFixture.gmClosedHat) == [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5])
        #expect(notes.count == 12)
        #expect(written.warnings.isEmpty && written.leftOut.isEmpty)
        #expect(written.written.map(\.role) == [.kick, .snare, .closedHat])

        // One undo removes the whole beat.
        _ = try store.undo()
        #expect(patClips(store, id).isEmpty)
    }

    @Test("m39-w4-10: with no atBeat the beat goes after the last clip, on the next bar line; bars sets the length")
    func appendLandsOnTheNextBarLine() throws {
        let (store, id) = try patSong()
        _ = try store.addMIDIClip(toTrack: id, name: "Fill", atBeat: 0, lengthBeats: 5)
        let written = try store.addDrumPattern(named: "boomBap", toTrack: id, bars: 3)
        #expect(written.clip.startBeat == 8, "a 5-beat clip ends inside bar 2; bar 3 starts on beat 8")
        #expect(written.clip.lengthBeats == 12)
        #expect(written.bars == 3)
        #expect(written.warnings.isEmpty)
    }

    @Test("m39-w4-10 census: the addMIDIClip funnel TRIMS a clip it lands on (the behaviour the verb must not inherit)")
    func overlapCensusTheFunnelTrims() throws {
        let (store, id) = try patSong()
        _ = try store.addMIDIClip(toTrack: id, name: "Riff", atBeat: 0, lengthBeats: 4,
                                  notes: [MIDINote(pitch: 36, startBeat: 3, lengthBeats: 0.5)])
        _ = try store.addMIDIClip(toTrack: id, name: "On top", atBeat: 2, lengthBeats: 4)
        let riff = try #require(patClips(store, id).first { $0.name == "Riff" })
        #expect(riff.lengthBeats == 2, "MEASURED: the funnel cut the resident to make room")
    }

    @Test("m39-w4-10: a beat landing on another clip is REFUSED, names the clip, and changes nothing")
    func overlapIsRefusedAndNothingChanges() throws {
        let (store, id) = try patSong()
        let riff = try store.addMIDIClip(toTrack: id, name: "Riff", atBeat: 0, lengthBeats: 4,
                                         notes: [MIDINote(pitch: 36, startBeat: 3, lengthBeats: 0.5)])
        let undoBefore = store.undoHistory().undo.count
        let before = patClips(store, id)

        let refusal = patMessage { _ = try store.addDrumPattern(named: "basicRock", toTrack: id, atBeat: 2) }
        let text = try #require(refusal)
        #expect(text.contains("'Riff'"))
        #expect(text.contains(riff.id.uuidString))
        #expect(text.contains("it would start at beat 4"), "the append beat is named: \(text)")
        #expect(patClips(store, id) == before, "the resident is untouched and no clip was added")
        #expect(store.undoHistory().undo.count == undoBefore)

        // Touching is not overlapping: starting exactly where the riff ends is fine.
        let after = try store.addDrumPattern(named: "basicRock", toTrack: id, atBeat: 4)
        #expect(after.clip.startBeat == 4)
        #expect(patClips(store, id).first { $0.id == riff.id } == riff)
    }

    @Test("m39-w4-10: a song not in 4 beats to the bar where the beat would go is refused, with the meter named")
    func meterNotFourBeatsIsRefused() throws {
        let (store, id) = try patSong()
        try store.setTempoMap(store.transport.tempoMap,
                              meterMap: MeterMap(constant: TimeSignature(beatsPerBar: 3, beatUnit: 4)))
        let text = try #require(patMessage { _ = try store.addDrumPattern(named: "basicRock", toTrack: id) })
        #expect(text.contains("3/4"))
        #expect(text.contains("4 beats to a bar"))
        #expect(patClips(store, id).isEmpty)

        // A 4/4 song that turns 3/4 at beat 8: a beat over beats 0–8 fits, one over 4–12 does not.
        let meter = try MeterMap(changes: [
            MeterMap.Change(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            MeterMap.Change(startBeat: 8, beatsPerBar: 3, beatUnit: 4),
        ])
        try store.setTempoMap(store.transport.tempoMap, meterMap: meter)
        let fits = try store.addDrumPattern(named: "basicRock", toTrack: id, bars: 2, atBeat: 0)
        #expect(fits.clip.lengthBeats == 8)
        let crossing = try #require(patMessage {
            _ = try store.addDrumPattern(named: "basicRock", toTrack: id, bars: 2, atBeat: 4)
        })
        #expect(crossing.contains("3/4 at beat 8"), "the meter is named where it changes: \(crossing)")
        #expect(patClips(store, id).count == 1)
    }

    @Test("m39-w4-10: a track that is not a drum track is refused with a sentence that says why")
    func nonDrumTracksAreRefused() throws {
        let store = ProjectStore(projectName: "W9-PAT refusals")
        let synth = store.addTrack(name: "Bass", kind: .instrument).id
        let synthText = try #require(patMessage { _ = try store.addDrumPattern(named: "basicRock", toTrack: synth) })
        #expect(synthText.contains("'Bass' plays the Poly Synth, not drums"))
        #expect(synthText.contains("Drum Machine"))

        let audio = store.addTrack(name: "Vocal", kind: .audio).id
        let audioText = try #require(patMessage { _ = try store.addDrumPattern(named: "basicRock", toTrack: audio) })
        #expect(audioText.contains("'Vocal' is an audio track"))

        let bus = store.addTrack(name: "Verb Bus", kind: .bus).id
        let busText = try #require(patMessage { _ = try store.addDrumPattern(named: "basicRock", toTrack: bus) })
        #expect(busText.contains("'Verb Bus' is a bus"))

        // ⛔ A drum kit carried under the poly synth is not a drum track.
        _ = try store.setInstrument(id: synth, drumKit: DrumKitParams.newDrumMachineKit)
        #expect(store.tracks.first { $0.id == synth }?.instrument?.kind == .polySynth)
        #expect(patMessage { _ = try store.addDrumPattern(named: "basicRock", toTrack: synth) } != nil)

        let unknown = try #require(patMessage { _ = try store.addDrumPattern(named: "polka", toTrack: synth) })
        #expect(unknown.contains("no drum beat called 'polka'"))
        #expect(unknown.contains("Basic Rock (basicRock)"))
        #expect(store.tracks.allSatisfy { $0.clips.isEmpty })
    }

    @Test("m39-w4-10: bars outside 1…64 are refused")
    func barsOutOfRangeIsRefused() throws {
        let (store, id) = try patSong()
        for bars in [0, 65, -1] {
            let text = try #require(patMessage { _ = try store.addDrumPattern(named: "trap", toTrack: id, bars: bars) })
            #expect(text.contains("1 to 64 bars"), "\(bars)")
        }
        #expect(try store.addDrumPattern(named: "trap", toTrack: id, bars: 64).clip.lengthBeats == 256)
    }

    @Test("m39-w4-10 P3: a sorted kit with no open hat gets no open-hat note and a warning naming the Open Hat")
    func sortedKitLeavesTheOpenHatOut() throws {
        let track = DrumPatternStoreFixture.sortedKitTrack()
        let store = ProjectStore(projectName: "W9-PAT P3", tracks: [track])
        let written = try store.addDrumPattern(named: "fourOnTheFloor", toTrack: track.id)
        let notes = try #require(written.clip.notes)
        #expect(!notes.contains { $0.pitch == DrumPatternStoreFixture.gmOpenHat })
        // Nothing in the open hat's place: only the four kicks (the kit has no clap either).
        #expect(notes.map(\.pitch) == [36, 36, 36, 36])
        #expect(written.leftOut.map(\.role) == [.openHat, .clap])
        #expect(written.warnings.contains { $0.contains("Open Hat") })
        #expect(written.warnings.contains { $0.range(of: "open hat", options: .caseInsensitive) != nil })
        #expect(written.warnings.contains { $0.contains("Clap") })
    }

    @Test("m39-w4-10: a kit with none of the beat's drums adds nothing and names what is missing")
    func kitWithNoneOfTheDrumsIsRefused() throws {
        let tomOnly = Track(name: "Toms", kind: .instrument, instrument: InstrumentDescriptor(
            kind: .sampler, sampler: SamplerParams(zones: [DrumPatternStoreFixture.zone(45, role: .tom)])))
        let store = ProjectStore(projectName: "W9-PAT nothing", tracks: [tomOnly])
        let text = try #require(patMessage { _ = try store.addDrumPattern(named: "basicRock", toTrack: tomOnly.id) })
        #expect(text.contains("Kick, Snare and Closed Hat"))
        #expect(store.tracks[0].clips.isEmpty)
    }

    @Test("m39-w4-10: a start partway through a bar is written, with a warning naming the nearest bar lines")
    func offBarStartWarns() throws {
        let (store, id) = try patSong()
        let written = try store.addDrumPattern(named: "halfTime", toTrack: id, atBeat: 6)
        #expect(written.clip.startBeat == 6)
        let warning = try #require(written.warnings.first)
        #expect(warning.contains("partway through bar 2"))
        #expect(warning.contains("beats 4 and 8"))
        #expect(written.warnings.count == 1)
    }

    @Test("m39-w4-10: the General MIDI drum kit gets General MIDI notes")
    func generalMIDIKitGetsGeneralMIDINotes() throws {
        let store = ProjectStore(projectName: "W9-PAT GM kit")
        let id = store.addTrack(name: "GM Drums", kind: .instrument).id
        let kit = GMProgramCatalog.standardDrumKit
        _ = try store.setInstrument(id: id, kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: kit.program, bankMSB: kit.bankMSB))
        let written = try store.addDrumPattern(named: "oneDrop", toTrack: id)
        let pitches = Set(try #require(written.clip.notes).map(\.pitch))
        #expect(pitches == [36, 37, 42], "kick, side stick, closed hi-hat")
    }
}
