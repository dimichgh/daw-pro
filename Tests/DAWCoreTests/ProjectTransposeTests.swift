import Foundation
import Testing
@testable import DAWCore

/// p2-sing-k (lane W7-PK): the pure planner behind `project.transpose`,
/// `ProjectTranspose.plan`. One test per census verdict (`ProjectTranspose.swift`'s
/// banner), the skip and refusal rules of design §3.6, the zero-move invariance
/// control, and the report the wire echoes.
///
/// Deliberately NOT `@MainActor`: the planner is a pure function of `[Track]`.
/// The store door (one undo step, `dryRun`, the engine call) is pinned in
/// `UndoRoundTripTests`; the tuned-vocal physics in DAWEngineTests'
/// `ProjectTransposeRenderTests`.
@Suite("p2-sing-k — project.transpose planner: census, skips, refusals, report")
struct ProjectTransposeTests {

    // MARK: - Fixtures

    static func note(_ pitch: Int, at beat: Double) -> MIDINote {
        MIDINote(pitch: pitch, velocity: 90 + pitch % 7, startBeat: beat, lengthBeats: 0.5)
    }

    /// A chord on beat 0 (so canonical order is decided by PITCH at one onset)
    /// followed by a melody.
    static func midiClip(_ name: String, pitches: [Int] = [60, 64, 67, 72, 71]) -> Clip {
        let notes = pitches.enumerated().map { i, pitch in
            note(pitch, at: i < 3 ? 0 : Double(i - 2) * 0.5)
        }
        return Clip(name: name, startBeat: 0, lengthBeats: 4, notes: notes)
    }

    static func audioClip(_ name: String, shift: Double = 0) -> Clip {
        Clip(name: name, startBeat: 0, lengthBeats: 4,
             audioFileURL: URL(fileURLWithPath: "/tmp/w7-pk-\(name).wav"),
             pitchShiftSemitones: shift)
    }

    static func keys(_ name: String = "Keys", clips: [Clip]? = nil,
                     instrument: InstrumentDescriptor = .default) -> Track {
        Track(name: name, kind: .instrument, clips: clips ?? [midiClip("\(name) part")],
              instrument: instrument)
    }

    static func vocals(_ name: String = "Vocals", clips: [Clip]? = nil) -> Track {
        Track(name: name, kind: .audio, clips: clips ?? [audioClip("\(name) take")])
    }

    static let drumSynth = InstrumentDescriptor(kind: .drumSynth)

    /// What Chop to Sampler writes: one-key zones (36, 37, 38) over one
    /// recording, gain 1. Unmarked: the marker is the only thing that makes it
    /// a kit (round 2, PK-F2).
    static var chopParams: SamplerParams {
        SamplerParams(zones: (0..<3).map { i in
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w7-pk-break.wav"),
                        rootPitch: 36 + i, minPitch: 36 + i, maxPitch: 36 + i, gain: 1)
        }, gain: 1)
    }
    static let gmDrums = InstrumentDescriptor(
        kind: .soundBank,
        soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                   bankMSB: GMProgramCatalog.percussionBankMSB))
    static let sf2Drums = InstrumentDescriptor(
        kind: .soundBank,
        soundBank: SoundBankConfig(source: .file(path: "/tmp/w7-pk-kit.sf2"), program: 0,
                                   bankMSB: GMProgramCatalog.percussionBankMSB))
    static let gmPiano = InstrumentDescriptor(
        kind: .soundBank,
        soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                   bankMSB: GMProgramCatalog.melodicBankMSB))

    /// A tuned vocal: three moved notes plus a sound, with the natural-tuning
    /// fields set, so any rebuild of it would show.
    static func tunedSet(consonants: Bool = false) -> PitchEditSet {
        PitchEditSet(analysisVersion: 1, segments: [
            NoteSegment(startSeconds: 0.2, endSeconds: 1.0, detectedHz: 215.6,
                        detectedConfidence: 0.95, pitchOffsetCents: 35, vibratoRateHz: 5.5,
                        vibratoDepthCents: 20, formantOffsetSemitones: -0.5),
            NoteSegment(startSeconds: 1.2, endSeconds: 2.0, detectedHz: 251.2,
                        detectedConfidence: 0.9, pitchOffsetCents: -30, driftScale: 0.5),
            NoteSegment(startSeconds: 2.0, endSeconds: 2.1, detectedHz: 251.2,
                        detectedConfidence: 0.3, origin: .unpitched),
            NoteSegment(startSeconds: 2.2, endSeconds: 3.0, detectedHz: 286.9,
                        detectedConfidence: 0.92, pitchOffsetCents: 40, amplitudeDb: -2),
        ], retuneMs: 45, formantCorrection: 1, keepsConsonantsUntuned: consonants,
           transitionSlopeCentsPerSecond: PitchEditSet.defaultTransitionSlope)
    }

    /// `tunedSet` plus every per-note HAND edit the pitch editor can store — a
    /// drawn line, per-note timing, a join width, a followed slide, a cleared
    /// note — for the invariance control. All of them are relative to the
    /// recording or to the note, so none may change.
    static func richTunedSet() -> PitchEditSet {
        var set = tunedSet(consonants: true)
        set.segments[0].timeStartDeltaSeconds = -0.01
        set.segments[0].transitionOutMs = 60
        set.segments[1].shapeStartIndex = 130
        set.segments[1].shapeTenthsOfCents = [0, 50, 120, 80, 0]
        set.segments[1].glideFollow = 0.5
        set.segments[1].timeEndDeltaSeconds = 0.02
        set.segments[3].isCleared = true
        return set
    }

    static func withId(_ clip: Clip, _ id: UUID) throws -> Clip {
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(clip)) as? [String: Any])
        object["id"] = id.uuidString
        return try JSONDecoder().decode(Clip.self,
                                        from: JSONSerialization.data(withJSONObject: object))
    }

    static func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// THE DEFINITION of a key change, applied by hand: +t on every note of a
    /// pitched track and on every audio clip's shift, takes included, and
    /// nothing else. The invariance control compares the planner against it.
    static func expected(_ tracks: [Track], movedBy t: Int, moving: Set<UUID>) -> [Track] {
        tracks.map { original in
            guard moving.contains(original.id) else { return original }
            var track = original
            func move(_ clip: inout Clip) {
                if clip.notes != nil {
                    for n in clip.notes!.indices { clip.notes![n].pitch += t }
                } else {
                    clip.pitchShiftSemitones += Double(t)
                }
            }
            for c in track.clips.indices { move(&track.clips[c]) }
            for g in track.takeGroups.indices {
                for l in track.takeGroups[g].lanes.indices { move(&track.takeGroups[g].lanes[l].clip) }
            }
            return track
        }
    }

    // MARK: - MOVES: MIDINote.pitch

    @Test("MIDINote.pitch: every note on a pitched track moves; ids, velocity, timing and order ride along")
    func notesMove() throws {
        let clip = Self.midiClip("Chords")
        let track = Self.keys(clips: [clip])
        let up = try ProjectTranspose.plan(tracks: [track], semitones: 3)
        let moved = try #require(up.tracks.first?.clips.first?.notes)
        let before = try #require(clip.notes)
        #expect(moved.map(\.pitch) == before.map { $0.pitch + 3 })
        #expect(moved.map(\.id) == before.map(\.id))
        #expect(moved.map(\.velocity) == before.map(\.velocity))
        #expect(moved.map(\.startBeat) == before.map(\.startBeat))
        #expect(moved.map(\.lengthBeats) == before.map(\.lengthBeats))
        #expect(MIDINote.canonicallyOrdered(moved) == moved)
        #expect(up.report.notesMoved == before.count)
        #expect(up.report.midiClipsMoved == 1)
        #expect(up.report.audioClipsShifted == 0)
        #expect(up.report.tracks.map(\.outcome) == [.moved])
        #expect(up.report.tracks[0].clips.map(\.notesMoved) == [before.count])
        #expect(up.changesAnything)

        let down = try ProjectTranspose.plan(tracks: [track], semitones: -5)
        #expect(down.tracks[0].clips[0].notes?.map(\.pitch) == before.map { $0.pitch - 5 })
    }

    // MARK: - MOVES: Clip.pitchShiftSemitones

    @Test("Clip.pitchShiftSemitones: every audio clip's shift moves by the same amount, fractions kept")
    func audioShiftMoves() throws {
        let track = Self.vocals(clips: [Self.audioClip("Lead", shift: 0),
                                        Self.audioClip("Double", shift: -2.5)])
        let plan = try ProjectTranspose.plan(tracks: [track], semitones: 3)
        #expect(plan.tracks[0].clips.map(\.pitchShiftSemitones) == [3, 0.5])
        var restored = plan.tracks[0]
        restored.clips[0].pitchShiftSemitones = 0
        restored.clips[1].pitchShiftSemitones = -2.5
        #expect(restored == track)
        #expect(plan.report.audioClipsShifted == 2)
        #expect(plan.report.notesMoved == 0)
        let results = plan.report.tracks[0].clips
        #expect(results.map(\.kind) == [.audio, .audio])
        #expect(results.map(\.shiftBefore) == [0, -2.5])
        #expect(results.map(\.shiftAfter) == [3, 0.5])
        #expect(results.map(\.keepsTuning) == [false, false])
    }

    // MARK: - MOVES: TakeGroup.lanes[].clip

    @Test("TakeGroup lanes move with their comp members, and re-flattening the moved takes gives the moved comp")
    func takesMoveWithTheirComp() throws {
        let map = TempoMap(constantBPM: 120)
        func check(track original: Track, group: TakeGroup) throws {
            var track = original
            track.clips = CompFlattener.flatten(group, tempoMap: map)
            track.takeGroups = [group]
            try #require(track.clips.count == 2)
            let plan = try ProjectTranspose.plan(tracks: [track], semitones: 3)
            let moved = plan.tracks[0]
            #expect(moved == Self.expected([track], movedBy: 3, moving: [track.id])[0])
            let reflattened = CompFlattener.flatten(moved.takeGroups[0], tempoMap: map)
            try #require(reflattened.count == moved.clips.count)
            for (fresh, member) in zip(reflattened, moved.clips) {
                #expect(try Self.withId(fresh, member.id) == member)
            }
            // NEGATIVE CONTROL: moving the members alone leaves the takes behind,
            // and the next flatten silently puts the old key back.
            var membersOnly = track
            for c in membersOnly.clips.indices {
                if membersOnly.clips[c].notes != nil {
                    for n in membersOnly.clips[c].notes!.indices { membersOnly.clips[c].notes![n].pitch += 3 }
                } else {
                    membersOnly.clips[c].pitchShiftSemitones += 3
                }
            }
            let stale = CompFlattener.flatten(membersOnly.takeGroups[0], tempoMap: map)
            #expect(try Self.withId(stale[0], membersOnly.clips[0].id) != membersOnly.clips[0])
            #expect(plan.report.takeClipsMoved == 2)
        }

        let audioA = TakeLane(name: "Take 1", clip: Self.audioClip("Take 1", shift: 0))
        let audioB = TakeLane(name: "Take 2", clip: Self.audioClip("Take 2", shift: 1))
        try check(track: Self.vocals(clips: []),
                  group: TakeGroup(name: "Vox takes", lanes: [audioA, audioB], comp: [
                      CompSegment(laneID: audioA.id, startBeat: 0, endBeat: 2),
                      CompSegment(laneID: audioB.id, startBeat: 2, endBeat: 4)]))

        let midiA = TakeLane(name: "Take 1", clip: Self.midiClip("Take 1", pitches: [60, 62, 64, 65, 67]))
        let midiB = TakeLane(name: "Take 2", clip: Self.midiClip("Take 2", pitches: [72, 71, 69, 67, 65]))
        try check(track: Self.keys(clips: []),
                  group: TakeGroup(name: "Solo takes", lanes: [midiA, midiB], comp: [
                      CompSegment(laneID: midiA.id, startBeat: 0, endBeat: 1),
                      CompSegment(laneID: midiB.id, startBeat: 1, endBeat: 4)]))
    }

    // MARK: - KEPT: the invariance control over every other field

    @Test("Everything that is not MIDINote.pitch or Clip.pitchShiftSemitones comes out bit-identical")
    func everyOtherFieldIsUntouched() throws {
        var zone = SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w7-pk-c4.wav"),
                               rootPitch: 60, minPitch: 48, maxPitch: 72, tuneCents: 12)
        zone.gain = 0.9
        let sampler = InstrumentDescriptor(
            kind: .sampler, sampler: SamplerParams(zones: [zone], bendRangeSemitones: 7))
        var synth = PolySynthParams()
        synth.subOctave = -1
        synth.unisonDetuneCents = 14
        let bend = MIDIControllerLane(type: .pitchBend, points: [
            MIDIControllerPoint(beat: 0, value: 8192), MIDIControllerPoint(beat: 1, value: 12000)])
        let modWheel = MIDIControllerLane(type: .cc(controller: 1), points: [
            MIDIControllerPoint(beat: 0.5, value: 64)])
        var lead = Self.midiClip("Lead")
        lead.controllerLanes = Clip.canonicalControllerLanes([bend, modWheel])
        lead.fadeInBeats = 0.25
        lead.isAIGenerated = true
        var samplerTrack = Self.keys("Sampled Bass", clips: [lead], instrument: sampler)
        samplerTrack.effects = [EffectDescriptor(kind: .gain)]
        samplerTrack.automation = [AutomationLane(target: .volume, points: [
            AutomationPoint(beat: 0, value: 0.5), AutomationPoint(beat: 4, value: 1)])]
        let synthTrack = Self.keys("Pad", instrument: InstrumentDescriptor(kind: .polySynth, polySynth: synth))

        var tuned = Self.audioClip("Lead vocal", shift: -1)
        tuned.pitchEdits = Self.richTunedSet()
        // The fixture's premise: the hand edits really are on the set.
        #expect(tuned.pitchEdits?.segments[1].hasShape == true)
        #expect(tuned.pitchEdits?.hasTimeEdits == true)
        tuned.formantPreserve = true
        tuned.stretchRatio = 1.25
        tuned.startOffsetSeconds = 0.5
        tuned.gainEnvelope = [ClipGainPoint(beat: 0, gainDb: -3), ClipGainPoint(beat: 2, gainDb: 0)]
        var vocal = Self.vocals("Converted vocal", clips: [tuned])
        vocal.voiceProvenance = VoiceProvenance(voiceId: "voice-1", voiceName: "Voice One",
                                                pitchSemitones: -5,
                                                convertedAt: Date(timeIntervalSince1970: 1_800_000_000))
        vocal.isAIGenerated = true

        var kit = DrumKitParams()
        kit.kick.tune = 0.3
        let drums = Self.keys("Drums", clips: [Self.midiClip("Beat", pitches: [36, 38, 42, 42, 36])],
                              instrument: InstrumentDescriptor(kind: .drumSynth, drumKit: kit))
        let bus = Track(name: "Reverb bus", kind: .bus)

        let project = [samplerTrack, synthTrack, vocal, drums, bus]
        let plan = try ProjectTranspose.plan(tracks: project, semitones: 4)
        let expected = Self.expected(project, movedBy: 4,
                                     moving: [samplerTrack.id, synthTrack.id, vocal.id])
        #expect(plan.tracks == expected)
        #expect(try Self.sortedJSON(plan.tracks) == Self.sortedJSON(expected))
        // Spot pins on the census's KEPT verdicts, so a failure names the field.
        #expect(plan.tracks[0].instrument == samplerTrack.instrument)
        #expect(plan.tracks[0].clips[0].controllerLanes == lead.controllerLanes)
        #expect(plan.tracks[1].instrument?.polySynth == synth)
        #expect(plan.tracks[2].clips[0].pitchEdits == tuned.pitchEdits)
        #expect(plan.tracks[2].voiceProvenance == vocal.voiceProvenance)
        #expect(plan.tracks[3] == drums)
        #expect(plan.tracks[4] == bus)
        // POSITIVE CONTROL: the comparison can fail — a plan with the zones
        // moved too is not the expected project.
        var zonesMoved = expected
        zonesMoved[0].instrument?.sampler?.zones[0].rootPitch += 4
        #expect(zonesMoved != plan.tracks)
    }

    // MARK: - KEPT: Clip.pitchEdits (the headline decision)

    @Test("A tuned clip keeps its corrections: the shift carries them (design §3.6's tonic claim, corrected)")
    func tunedClipKeepsItsCorrections() throws {
        var clip = Self.audioClip("Lead vocal")
        clip.pitchEdits = Self.tunedSet()
        let plan = try ProjectTranspose.plan(tracks: [Self.vocals(clips: [clip])], semitones: 3)
        let moved = plan.tracks[0].clips[0]
        #expect(moved.pitchEdits == clip.pitchEdits)
        #expect(moved.pitchEdits?.segments.map(\.pitchOffsetCents)
                == clip.pitchEdits?.segments.map(\.pitchOffsetCents))
        #expect(moved.pitchEdits?.segments.map(\.detectedHz)
                == clip.pitchEdits?.segments.map(\.detectedHz))
        #expect(moved.pitchShiftSemitones == 3)
        #expect(plan.report.tracks.first?.clips.first?.keepsTuning == true)
        let field = plan.report.fields.first { $0.field == "Clip.pitchEdits" }
        #expect(field?.verdict == .kept)
        #expect(field?.count == 1)
        #expect(plan.report.fields.first { $0.field == "PitchCorrectionScale.tonicPitchClass" }?
                    .verdict == .notStored)
    }

    @Test("A sampler's key map stays put while its notes move")
    func samplerKeyMapIsKept() throws {
        let zones = [
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w7-pk-lo.wav"),
                        rootPitch: 48, minPitch: 36, maxPitch: 59),
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/w7-pk-hi.wav"),
                        rootPitch: 72, minPitch: 60, maxPitch: 84),
        ]
        let track = Self.keys("Piano", instrument: InstrumentDescriptor(
            kind: .sampler, sampler: SamplerParams(zones: zones)))
        let plan = try ProjectTranspose.plan(tracks: [track], semitones: -2)
        #expect(plan.tracks[0].instrument?.sampler?.zones == zones)
        #expect(plan.tracks[0].clips[0].notes?.map(\.pitch)
                == track.clips[0].notes?.map { $0.pitch - 2 })
        #expect(plan.report.fields.first { $0.field == "SamplerZone.rootPitch" }?.count == 2)
    }

    // MARK: - SKIPPED: drums and excluded tracks

    @Test("Drum tracks are skipped: our drum machine, a GM percussion bank, and an SF2 kit on bank 120")
    func drumTracksAreSkipped() throws {
        let project = [Self.keys("808", instrument: Self.drumSynth),
                       Self.keys("GM kit", instrument: Self.gmDrums),
                       Self.keys("SF2 kit", instrument: Self.sf2Drums),
                       Self.keys("Piano", instrument: Self.gmPiano)]
        let plan = try ProjectTranspose.plan(tracks: project, semitones: 5)
        #expect(Array(plan.tracks[0...2]) == Array(project[0...2]))
        #expect(plan.tracks[3].clips[0].notes?.map(\.pitch)
                == project[3].clips[0].notes?.map { $0.pitch + 5 })
        #expect(plan.report.tracks.map(\.outcome)
                == [.skippedDrums, .skippedDrums, .skippedDrums, .moved])
        #expect(plan.report.fields.first { $0.field == "Drum track notes" }?.count == 3)
        #expect(project.map(ProjectTranspose.isDrumTrack) == [true, true, true, false])
    }

    @Test("A drum descriptor only makes a drum track on an instrument track that plays it")
    func staleDrumDescriptorsDoNotSkip() throws {
        // A poly synth carrying a stale percussion bank (kinds round-trip their
        // settings) plays the synth: its notes are pitches.
        let synth = Self.keys("Lead", instrument: InstrumentDescriptor(
            kind: .polySynth, soundBank: Self.gmDrums.soundBank))
        // An audio track never plays an instrument, whatever it carries.
        var audio = Self.vocals("Loop")
        audio.instrument = Self.drumSynth
        let plan = try ProjectTranspose.plan(tracks: [synth, audio], semitones: 2)
        #expect(!ProjectTranspose.isDrumTrack(synth))
        #expect(!ProjectTranspose.isDrumTrack(audio))
        #expect(plan.report.tracks.map(\.outcome) == [.moved, .moved])
        #expect(plan.tracks[1].clips[0].pitchShiftSemitones == 2)
    }

    @Test("Excluded tracks are left as they are, and exclusion wins over the drum rule")
    func excludedTracksAreSkipped() throws {
        let vocal = Self.vocals()
        let keys = Self.keys()
        let drums = Self.keys("808", instrument: Self.drumSynth)
        let bass = Self.keys("Bass")
        let plan = try ProjectTranspose.plan(tracks: [vocal, keys, drums, bass], semitones: 3,
                                             excludeTrackIds: [vocal.id, keys.id, drums.id])
        #expect(Array(plan.tracks[0...2]) == [vocal, keys, drums])
        #expect(plan.report.tracks.map(\.outcome)
                == [.skippedExcluded, .skippedExcluded, .skippedExcluded, .moved])
        #expect(plan.report.fields.first { $0.field == "Excluded tracks" }?.count == 3)
        #expect(plan.report.warnings.isEmpty)
    }

    @Test("An excludeTrackIds entry no track has is refused, so a typo cannot move the track it meant to keep")
    func unknownExcludeIdIsRefused() throws {
        let bogus = UUID()
        let error = #expect(throws: ProjectError.self) {
            try ProjectTranspose.plan(tracks: [Self.keys()], semitones: 1, excludeTrackIds: [bogus])
        }
        guard case .trackNotFound(let id)? = error else {
            Issue.record("expected trackNotFound, got \(String(describing: error))")
            return
        }
        #expect(id == bogus)
    }

    // MARK: - SKIPPED: slice kits (round 2, PK-F2)

    @Test("A slice kit is skipped like drums: its notes pick slices, not pitches, so none moves and none is refused")
    func sliceKitTracksAreSkipped() throws {
        let kit = Self.keys("Break chops", clips: [Self.midiClip("Break", pitches: [36, 37, 38, 39, 127])],
                            instrument: InstrumentDescriptor(kind: .sampler, sampler: Self.chopParams))
        let keys = Self.keys()
        let isKit: (Track) -> Bool = { $0.id == kit.id }
        let plan = try ProjectTranspose.plan(tracks: [kit, keys], semitones: 3, sliceKit: isKit)
        #expect(plan.tracks[0] == kit)
        #expect(plan.tracks[1] == Self.expected([keys], movedBy: 3, moving: [keys.id])[0])
        #expect(plan.report.tracks.map(\.outcome) == [.skippedSliceKit, .moved])
        #expect(plan.report.tracks[0].reason?.contains("one slice of the recording") == true)
        #expect(plan.report.tracks[0].clips.isEmpty)
        #expect(plan.report.fields.first { $0.field == "Slice kit notes" }?.count == 1)
        #expect(plan.report.fields.first { $0.field == "Slice kit notes" }?.verdict == .skipped)
        #expect(plan.report.summary.hasSuffix("Skipped 1 chopped loop."))
        // The caller's word still wins, and a looper layer on a kit blocks nothing.
        let excluded = try ProjectTranspose.plan(tracks: [kit, keys], semitones: 3,
                                                 excludeTrackIds: [kit.id], sliceKit: isKit)
        #expect(excluded.report.tracks[0].outcome == .skippedExcluded)
        let looped = try ProjectTranspose.plan(tracks: [kit, keys], semitones: 3,
                                               loopLayerTrackIds: [kit.id], sliceKit: isKit)
        #expect(looped.report.tracks[0].outcome == .skippedSliceKit)
        // NEGATIVE CONTROL: the same track, not recognised as a kit, moves, so
        // its note at 127 is refused. The skip above is what spared it.
        let error = #expect(throws: TransposeRefusal.self) {
            try ProjectTranspose.plan(tracks: [kit, keys], semitones: 3, sliceKit: { _ in false })
        }
        #expect(error?.code == .transposeNoteOutOfRange)
        #expect(error?.clipName == "Break")
    }

    @Test("Every skipped kind is named in one plain sentence: drums, chopped loops, tracks left out")
    func skippedSentenceNamesEveryKind() throws {
        let kit = Self.keys("Chops", instrument: InstrumentDescriptor(kind: .sampler, sampler: Self.chopParams))
        let drums = Self.keys("808", instrument: Self.drumSynth)
        let guide = Self.keys("Guide")
        let project = [Self.keys(), kit, drums, guide]
        let plan = try ProjectTranspose.plan(tracks: project, semitones: 2, excludeTrackIds: [guide.id],
                                             sliceKit: { $0.id == kit.id })
        #expect(plan.report.summary.hasSuffix(
            "Skipped 1 drum track, 1 chopped loop and 1 track you left out."))
        let two = try ProjectTranspose.plan(tracks: [Self.keys(), kit, drums], semitones: 2,
                                            sliceKit: { $0.id == kit.id })
        #expect(two.report.summary.hasSuffix("Skipped 1 drum track and 1 chopped loop."))
    }

    @Test("The production predicate reads only the STORED marker, and only on a sampler instrument track")
    func sliceKitPredicateReadsTheStoredMarker() throws {
        var marked = Self.chopParams
        marked.markSliceKit()
        let onSampler = Self.keys("Chops", instrument: InstrumentDescriptor(kind: .sampler, sampler: marked))
        // Never a kit, before or after the marker lands: another instrument kind
        // carrying a stale sampler payload, an audio track, and one-key zones
        // without the marker (the zone shapes decide nothing).
        let underSynth = Self.keys("Synth", instrument: InstrumentDescriptor(kind: .polySynth, sampler: marked))
        var onAudio = Self.vocals("Audio")
        onAudio.instrument = InstrumentDescriptor(kind: .sampler, sampler: marked)
        let unmarked = Self.keys("One per key",
                                 instrument: InstrumentDescriptor(kind: .sampler, sampler: Self.chopParams))
        #expect(!ProjectTranspose.isSliceKitTrack(underSynth))
        #expect(!ProjectTranspose.isSliceKitTrack(onAudio))
        #expect(!ProjectTranspose.isSliceKitTrack(unmarked))
        #expect(!Self.chopParams.isSliceKit)
        // The production default, end to end through the planner.
        let plan = try ProjectTranspose.plan(tracks: [onSampler, unmarked], semitones: 3)
        #expect(plan.report.tracks[1].outcome == .moved)
        withKnownIssue("PK-F2: SamplerParams.sliceKit is not stored until the marker patch lands") {
            #expect(marked.isSliceKit)
            #expect(ProjectTranspose.isSliceKitTrack(onSampler))
            #expect(plan.report.tracks[0].outcome == .skippedSliceKit)
        }
    }

    @Test("The marker is in the save format: a chopped sampler writes it, an unchopped one writes no key")
    func sliceKitMarkerIsInTheSaveFormat() throws {
        func saved(_ params: SamplerParams) throws -> (keys: Set<String>, reopened: SamplerParams?) {
            let document = InstrumentDocument(
                from: InstrumentDescriptor(kind: .sampler, sampler: params), mediaRefs: [:])
            let data = try JSONEncoder().encode(document)
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let sampler = try #require(json["sampler"] as? [String: Any])
            let decoded = try JSONDecoder().decode(InstrumentDocument.self, from: data)
            let back = decoded.instrumentDescriptor(
                bundleURL: FileManager.default.temporaryDirectory, warn: { _ in })
            return (Set(sampler.keys), back.sampler)
        }
        // An unchopped sampler's saved shape is byte-identical to a pre-PK-F2 save.
        let plain = try saved(Self.chopParams)
        #expect(!plain.keys.contains("sliceKit"))
        #expect(plain.keys.contains("gain"))  // control: the probe sees the sampler's keys
        #expect(plain.reopened?.isSliceKit == false)
        var marked = Self.chopParams
        marked.markSliceKit()
        let kit = try saved(marked)
        withKnownIssue("PK-F2: SamplerParams.sliceKit is not stored until the marker patch lands") {
            #expect(kit.keys.contains("sliceKit"))
            #expect(kit.reopened?.isSliceKit == true)
        }
    }

    // MARK: - Refusals (nothing is planned)

    @Test("More than an octave either way is refused in words; exactly 12 is allowed")
    func outOfRangeIsRefused() throws {
        for bad in [13, -13, 24] {
            let error = #expect(throws: TransposeRefusal.self) {
                try ProjectTranspose.plan(tracks: [Self.keys()], semitones: bad)
            }
            #expect(error?.code == .transposeOutOfRange)
            #expect(error?.message.contains("\(bad)") == true)
            #expect(error?.message.contains("Nothing was changed.") == true)
        }
        #expect(try ProjectTranspose.plan(tracks: [Self.keys()], semitones: 12).changesAnything)
        #expect(try ProjectTranspose.plan(tracks: [Self.keys()], semitones: -12).changesAnything)
        // The wire's door: whole numbers only, never rounded.
        #expect(try ProjectTranspose.validatedSemitones(3) == 3)
        #expect(try ProjectTranspose.validatedSemitones(-12) == -12)
        for bad in [2.5, 12.5, 13, -13, .nan, .infinity] {
            let error = #expect(throws: TransposeRefusal.self) {
                try ProjectTranspose.validatedSemitones(bad)
            }
            #expect(error?.code == .transposeOutOfRange)
        }
    }

    @Test("A note that would leave MIDI 0…127 is refused, naming the clip and the note")
    func noteOutOfRangeIsRefused() throws {
        let high = Self.keys("Synth", clips: [Self.midiClip("Lead", pitches: [60, 64, 67, 126, 127])])
        let up = #expect(throws: TransposeRefusal.self) {
            try ProjectTranspose.plan(tracks: [high], semitones: 2)
        }
        #expect(up?.code == .transposeNoteOutOfRange)
        #expect(up?.clipName == "Lead")
        #expect(up?.trackName == "Synth")
        #expect(up?.wouldBe == 128)
        #expect(up?.noteId == high.clips[0].notes?.first { $0.pitch == 126 }?.id)
        #expect(up?.message.contains("'Lead' on track 'Synth'") == true)
        #expect(up?.message.contains("F#9") == true)
        #expect(up?.message.contains("1 other note would go out of range too.") == true)
        #expect(try ProjectTranspose.plan(tracks: [high], semitones: 0).changesAnything == false)

        let low = Self.keys("Sub", clips: [Self.midiClip("Rumble", pitches: [0, 12, 24, 30, 36])])
        let down = #expect(throws: TransposeRefusal.self) {
            try ProjectTranspose.plan(tracks: [low], semitones: -1)
        }
        #expect(down?.code == .transposeNoteOutOfRange)
        #expect(down?.message.contains("below the lowest note") == true)

        // A note that will not move cannot be refused: drums and excluded tracks.
        let drums = Self.keys("808", clips: [Self.midiClip("Hat", pitches: [127, 127, 127, 127, 127])],
                              instrument: Self.drumSynth)
        #expect(try ProjectTranspose.plan(tracks: [drums], semitones: 5).changesAnything == false)
        #expect(try ProjectTranspose.plan(tracks: [high], semitones: 5,
                                          excludeTrackIds: [high.id]).changesAnything == false)
    }

    @Test("An audio clip pushed past ±24 semitones is refused, naming the clip; exactly 24 is allowed")
    func audioShiftOutOfRangeIsRefused() throws {
        let track = Self.vocals(clips: [Self.audioClip("Choir", shift: 21), Self.audioClip("Vox", shift: 22)])
        let error = #expect(throws: TransposeRefusal.self) {
            try ProjectTranspose.plan(tracks: [track], semitones: 3)
        }
        #expect(error?.code == .transposeAudioShiftOutOfRange)
        #expect(error?.clipName == "Vox")
        #expect(error?.wouldBe == 25)
        #expect(error?.message.contains("'Vox' on track 'Vocals'") == true)
        #expect(error?.message.contains("+25 semitones") == true)
        // The boundary: 21 + 3 = 24 is inside the range.
        let edge = try ProjectTranspose.plan(tracks: [Self.vocals(clips: [Self.audioClip("Choir", shift: 21)])],
                                             semitones: 3)
        #expect(edge.tracks[0].clips[0].pitchShiftSemitones == 24)
        let low = #expect(throws: TransposeRefusal.self) {
            try ProjectTranspose.plan(tracks: [Self.vocals(clips: [Self.audioClip("Deep", shift: -24)])],
                                      semitones: -1)
        }
        #expect(low?.code == .transposeAudioShiftOutOfRange)
    }

    @Test("A take that would go out of range is refused too, and named as a take")
    func takeOutOfRangeIsRefused() throws {
        let laneA = TakeLane(name: "Take 1", clip: Self.audioClip("Take 1", shift: 0))
        let laneB = TakeLane(name: "Take 2", clip: Self.audioClip("Take 2", shift: 23))
        var track = Self.vocals(clips: [])
        track.takeGroups = [TakeGroup(name: "Takes", lanes: [laneA, laneB],
                                      comp: [CompSegment(laneID: laneA.id, startBeat: 0, endBeat: 4)])]
        track.clips = CompFlattener.flatten(track.takeGroups[0], tempoMap: TempoMap(constantBPM: 120))
        let error = #expect(throws: TransposeRefusal.self) {
            try ProjectTranspose.plan(tracks: [track], semitones: 2)
        }
        #expect(error?.code == .transposeAudioShiftOutOfRange)
        #expect(error?.message.contains("the take 'Take 2'") == true)
    }

    @Test("An open looper with a layer on a track that would move is refused; on a drum or excluded track it is not")
    func openLooperIsRefused() throws {
        let keys = Self.keys()
        let drums = Self.keys("808", instrument: Self.drumSynth)
        let error = #expect(throws: TransposeRefusal.self) {
            try ProjectTranspose.plan(tracks: [keys, drums], semitones: 3, loopLayerTrackIds: [keys.id])
        }
        #expect(error?.code == .transposeLooperOpen)
        #expect(error?.trackId == keys.id)
        #expect(error?.message.contains("'Keys'") == true)
        #expect(try ProjectTranspose.plan(tracks: [keys, drums], semitones: 3,
                                          loopLayerTrackIds: [drums.id]).changesAnything)
        #expect(try ProjectTranspose.plan(tracks: [keys, drums], semitones: 3, excludeTrackIds: [keys.id],
                                          loopLayerTrackIds: [keys.id]).changesAnything == false)
        #expect(try ProjectTranspose.plan(tracks: [keys], semitones: 0,
                                          loopLayerTrackIds: [keys.id]).changesAnything == false)
    }

    // MARK: - Invariance controls

    @Test("0 semitones is a no-op: the same tracks, byte for byte, and a report that moved nothing")
    func zeroMovesNothing() throws {
        var tuned = Self.audioClip("Lead vocal", shift: 2)
        tuned.pitchEdits = Self.tunedSet(consonants: true)
        let project = [Self.keys(), Self.vocals(clips: [tuned]), Self.keys("808", instrument: Self.drumSynth)]
        let plan = try ProjectTranspose.plan(tracks: project, semitones: 0)
        #expect(plan.tracks == project)
        #expect(try Self.sortedJSON(plan.tracks) == Self.sortedJSON(project))
        #expect(!plan.changesAnything)
        #expect(!plan.report.applied)
        #expect(plan.report.notesMoved == 0 && plan.report.audioClipsShifted == 0)
        #expect(plan.report.warnings.isEmpty)
        #expect(plan.report.tracks.map(\.outcome) == [.nothingToMove, .nothingToMove, .skippedDrums])
        #expect(plan.report.summary.contains("0 semitones"))
    }

    @Test("Up then down by the same amount gives the song back exactly")
    func upThenDownRestores() throws {
        let project = [Self.keys(), Self.vocals(clips: [Self.audioClip("Lead", shift: -3)])]
        let up = try ProjectTranspose.plan(tracks: project, semitones: 5)
        let back = try ProjectTranspose.plan(tracks: up.tracks, semitones: -5)
        #expect(back.tracks == project)
    }

    @Test("Only drums, excluded tracks or empty tracks: nothing to move, and nothing changes")
    func nothingToMove() throws {
        let project = [Self.keys("808", instrument: Self.drumSynth), Self.keys("Empty", clips: []),
                       Track(name: "Bus", kind: .bus)]
        let plan = try ProjectTranspose.plan(tracks: project, semitones: 7)
        #expect(plan.tracks == project)
        #expect(!plan.changesAnything)
        #expect(!plan.report.applied)
        #expect(plan.report.tracks.map(\.outcome) == [.skippedDrums, .nothingToMove, .nothingToMove])
        #expect(plan.report.summary.hasPrefix("Nothing to move"))
    }

    // MARK: - Warnings

    @Test("Each recorded or generated audio track that shifts is warned about by name; MIDI, drums and excluded are not")
    func audioTracksAreWarnedByName() throws {
        let recorded = Self.vocals("Vocals", clips: [Self.audioClip("Verse"), Self.audioClip("Chorus")])
        var generated = Self.vocals("AI Choir")
        generated.isAIGenerated = true
        var converted = Self.vocals("Converted")
        converted.voiceProvenance = VoiceProvenance(voiceId: "v", voiceName: "V")
        let kept = Self.vocals("Guide")
        let project = [recorded, generated, converted, kept, Self.keys(),
                       Self.keys("808", instrument: Self.drumSynth)]
        let plan = try ProjectTranspose.plan(tracks: project, semitones: -2, excludeTrackIds: [kept.id])
        let audio = plan.report.warnings.filter { $0.code == .audioWillBePitchShifted }
        #expect(audio.map(\.trackName) == ["Vocals", "AI Choir", "Converted"])
        #expect(audio.map(\.source) == [.recorded, .generated, .generated])
        // A length check BEFORE any index: a defect that drops warnings must fail this test, not crash
        // the whole test process (it did, in the W7-PK plant window at 06:55, taking every later test with it).
        try #require(audio.count == 3)
        #expect(audio[0].clipIds == recorded.clips.map(\.id))
        #expect(audio[0].message.contains("recorded audio on 'Vocals' down 2 semitones (2 clips)"))
        #expect(audio[1].message.contains("generated audio on 'AI Choir'"))
    }

    @Test("A tuned clip whose consonant protection would stop is warned about; one already stopped is not")
    func consonantProtectionWarning() throws {
        var active = Self.audioClip("Lead vocal", shift: 0)
        active.pitchEdits = Self.tunedSet(consonants: true)
        var alreadyShifted = Self.audioClip("Harmony", shift: 2)
        alreadyShifted.pitchEdits = Self.tunedSet(consonants: true)
        var unprotected = Self.audioClip("Double", shift: 0)
        unprotected.pitchEdits = Self.tunedSet(consonants: false)
        // The fixture's own premise, through the ONE rule.
        #expect(active.pitchEdits?.consonantMixIsActive(stretchRatio: 1, clipSemitones: 0) == true)
        #expect(alreadyShifted.pitchEdits?.consonantMixIsActive(stretchRatio: 1, clipSemitones: 2) == false)
        let plan = try ProjectTranspose.plan(
            tracks: [Self.vocals(clips: [active, alreadyShifted, unprotected])], semitones: 3)
        let stops = plan.report.warnings.filter { $0.code == .consonantProtectionStops }
        #expect(stops.map(\.clipIds) == [[active.id]])
        #expect(stops.first?.message.contains("'Lead vocal'") == true)
    }

    // MARK: - The report

    @Test("The report round-trips through JSON, lists every track in order and carries the census")
    func reportShape() throws {
        let project = [Self.keys(), Self.vocals(), Self.keys("808", instrument: Self.drumSynth)]
        let preview = try ProjectTranspose.plan(tracks: project, semitones: 1, dryRun: true)
        let report = preview.report
        #expect(try JSONDecoder().decode(TransposeReport.self, from: Self.sortedJSON(report)) == report)
        #expect(report.tracks.map(\.trackId) == project.map(\.id))
        #expect(report.dryRun && !report.applied)
        #expect(report.summary.hasPrefix("Would move the song up 1 semitone"))
        #expect(report.fields.map(\.field) == [
            "MIDINote.pitch", "Clip.pitchShiftSemitones", "TakeGroup.lanes[].clip",
            "Clip.pitchEdits", "NoteSegment.detectedHz", "PitchCorrectionScale.tonicPitchClass",
            "SamplerZone.rootPitch", "MIDIControllerLane.pitchBend", "Instrument pitch settings",
            "VoiceProvenance.pitchSemitones", "Drum track notes", "Slice kit notes",
            "Excluded tracks", "Musical Typing chord key"])
        #expect(report.fields.filter { $0.verdict == .moved }.map(\.field)
                == ["MIDINote.pitch", "Clip.pitchShiftSemitones", "TakeGroup.lanes[].clip"])
        let applied = try ProjectTranspose.plan(tracks: project, semitones: 1).report
        #expect(applied.applied && !applied.dryRun)
        #expect(applied.summary.hasPrefix("Moved the song up 1 semitone:"))
        #expect(applied.summary.contains("Skipped 1 drum track."))
        #expect(ProjectTranspose.undoLabel(semitones: 3) == "Move Song Up 3 Semitones")
        #expect(ProjectTranspose.undoLabel(semitones: -1) == "Move Song Down 1 Semitone")
    }
}
