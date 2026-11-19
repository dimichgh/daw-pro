import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x4: `HarmonyPlanner` (design `docs/design/2026-10-06-p2-sing-expansion.md` §4.2, §4.3, §4.5, §4.8). Pure
/// values, so NOT `@MainActor`. Every expected pitch below is written out by hand from the scale, never computed with
/// the planner's own arithmetic.
@Suite("HarmonyPlanner: harmony notes from a melody, the chord snap, the rules that never bend (p2-sing-x4)")
struct HarmonyPlannerTests {

    static let cMajor = SongKey(tonicPitchClass: 0, mode: .major)
    static let aMinor = SongKey(tonicPitchClass: 9, mode: .minor)
    static let gMajor = SongKey(tonicPitchClass: 7, mode: .major)

    static func note(_ pitch: Int, _ start: Double, _ length: Double = 1) -> MIDINote {
        MIDINote(pitch: pitch, velocity: 100, startBeat: start, lengthBeats: length)
    }

    /// One note per beat.
    static func melody(_ pitches: [Int]) -> [MIDINote] {
        pitches.enumerated().map { note($0.element, Double($0.offset)) }
    }

    static func clip(_ notes: [MIDINote], lyrics: String? = nil, start: Double = 0) -> Clip {
        Clip(name: "Melody", startBeat: start, lengthBeats: notes.map(\.endBeat).max() ?? 4, notes: notes,
             lyrics: lyrics.map { ClipLyrics(text: $0) })
    }

    static func track(_ name: String, _ notes: [MIDINote], instrument: InstrumentDescriptor? = nil,
                      muted: Bool = false) -> Track {
        var track = Track(name: name, kind: .instrument, clips: [clip(notes)])
        track.instrument = instrument
        track.isMuted = muted
        return track
    }

    static func pitches(_ lead: [Int], _ interval: HarmonySpec.Interval, _ direction: HarmonySpec.Direction,
                        key: SongKey) -> [Int] {
        HarmonyPlanner.notes(lead: melody(lead), spec: HarmonySpec(interval: interval, direction: direction,
                                                                     chordSource: .none),
                             key: key, partIndex: 1, chordAt: { _ in nil }).notes.map(\.pitch)
    }

    static let drumKit = InstrumentDescriptor(kind: .drumSynth)
    static var sliceKit: InstrumentDescriptor {
        var params = SamplerParams(zones: (0..<3).map { i in
            SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/x4-slices.wav"),
                        rootPitch: 36 + i, minPitch: 36 + i, maxPitch: 36 + i, gain: 1)
        }, gain: 1)
        params.markSliceKit()
        return InstrumentDescriptor(kind: .sampler, sampler: params)
    }

    // MARK: - The musical controls (§4.8)

    @Test("musical control: a diatonic third above C-D-E-F-G in C major is E-F-G-A-B")
    func thirdAboveCToG() {
        let plan = HarmonyPlanner.notes(lead: Self.melody([72, 74, 76, 77, 79]),
                                        spec: HarmonySpec(interval: .third, direction: .above, chordSource: .none),
                                        key: Self.cMajor, partIndex: 1, chordAt: { _ in nil })
        #expect(plan.notes.map(\.pitch) == [76, 77, 79, 81, 83])           // E5 F5 G5 A5 B5
        #expect(plan.notes.allSatisfy { $0.rule == .diatonic })
    }

    /// The lead C5-G5; a G major triad (G3 B3 D4) sounds only under the D (beat 1).
    static let leadCToG = melody([72, 74, 76, 77, 79])
    static let gTriadUnderD = [note(55, 1), note(59, 1), note(62, 1)]
    static let snappedCToG = [76, 79, 79, 81, 83]
    static let unsnappedCToG = [76, 77, 79, 81, 83]

    @Test("musical control: a G major triad under the D moves the third above (F) to G, the nearest chord tone above")
    func gTriadSnapFromAnotherTrack() {
        let lead = Self.clip(Self.leadCToG)
        let leadTrack = Track(name: "Lead", kind: .instrument, clips: [lead])
        let keys = Self.track("Keys", Self.gTriadUnderD)
        for source in [HarmonySpec.ChordSource.otherTracks, .auto] {
            let plan = HarmonyPlanner.derivedPart(clip: lead, on: leadTrack, tracks: [leadTrack, keys],
                                                  spec: HarmonySpec(interval: .third, direction: .above,
                                                                    chordSource: source),
                                                  key: Self.cMajor, partIndex: 1)
            #expect(plan.notes.map(\.pitch) == Self.snappedCToG, "\(source)")
            #expect(plan.notes[1].unsnappedPitch == 77, "\(source): the diatonic step under the D is F")
            #expect(plan.notes.map(\.rule) == [.diatonic, .chordSnap, .diatonic, .diatonic, .diatonic], "\(source)")
        }
        // `.none` never snaps.
        let plain = HarmonyPlanner.derivedPart(clip: lead, on: leadTrack, tracks: [leadTrack, keys],
                                               spec: HarmonySpec(interval: .third, direction: .above,
                                                                 chordSource: .none),
                                               key: Self.cMajor, partIndex: 1)
        #expect(plain.notes.map(\.pitch) == Self.unsnappedCToG)
    }

    @Test("chord snap from this clip: the melody clip's own G triad under the D snaps the same way")
    func gTriadSnapFromThisClip() {
        let lead = Self.clip(Self.leadCToG + Self.gTriadUnderD)
        let leadTrack = Track(name: "Lead", kind: .instrument, clips: [lead])
        for source in [HarmonySpec.ChordSource.thisClip, .auto] {
            let plan = HarmonyPlanner.derivedPart(clip: lead, on: leadTrack, tracks: [leadTrack],
                                                  spec: HarmonySpec(interval: .third, direction: .above,
                                                                    chordSource: source),
                                                  key: Self.cMajor, partIndex: 1)
            #expect(plan.notes.map(\.leadPitch) == [72, 74, 76, 77, 79], "\(source): the melody is the top line")
            #expect(plan.notes.map(\.pitch) == Self.snappedCToG, "\(source)")
        }
        // `.otherTracks` does not read this clip.
        let others = HarmonyPlanner.derivedPart(clip: lead, on: leadTrack, tracks: [leadTrack],
                                                spec: HarmonySpec(interval: .third, direction: .above,
                                                                  chordSource: .otherTracks),
                                                key: Self.cMajor, partIndex: 1)
        #expect(others.notes.map(\.pitch) == Self.unsnappedCToG)
    }

    @Test("chords the part must NOT follow: drum tracks, slice kits, muted tracks, the lead's own track, a two-note interval")
    func chordsThatDoNotCount() {
        let lead = Self.clip(Self.leadCToG)
        let leadTrack = Track(name: "Lead", kind: .instrument, clips: [lead])
        let spec = HarmonySpec(interval: .third, direction: .above, chordSource: .otherTracks)
        var sameTrack = leadTrack
        sameTrack.clips.append(Self.clip(Self.gTriadUnderD))
        let cases: [(String, [Track], Track)] = [
            ("drum track", [leadTrack, Self.track("Drums", Self.gTriadUnderD, instrument: Self.drumKit)], leadTrack),
            ("slice kit", [leadTrack, Self.track("Chops", Self.gTriadUnderD, instrument: Self.sliceKit)], leadTrack),
            ("muted", [leadTrack, Self.track("Keys", Self.gTriadUnderD, muted: true)], leadTrack),
            ("another clip on the lead's own track", [sameTrack], sameTrack),
            ("a two-note interval (G-B)", [leadTrack, Self.track("Keys", [Self.note(55, 1), Self.note(59, 1)])],
             leadTrack),
        ]
        for (name, tracks, onTrack) in cases {
            let plan = HarmonyPlanner.derivedPart(clip: lead, on: onTrack, tracks: tracks, spec: spec,
                                                  key: Self.cMajor, partIndex: 1)
            #expect(plan.notes.map(\.pitch) == Self.unsnappedCToG, "\(name)")
        }
        // Positive control: the same triad on an ordinary unmuted keys track DOES snap.
        let control = HarmonyPlanner.derivedPart(clip: lead, on: leadTrack,
                                                 tracks: [leadTrack, Self.track("Keys", Self.gTriadUnderD)],
                                                 spec: spec, key: Self.cMajor, partIndex: 1)
        #expect(control.notes.map(\.pitch) == Self.snappedCToG)
    }

    // MARK: - Tables: every interval and direction, C major and A minor

    @Test("C major: every interval, above and below, on each of the seven scale notes")
    func cMajorTable() {
        let lead = [60, 62, 64, 65, 67, 69, 71]                                      // C4 D E F G A B
        #expect(Self.pitches(lead, .third, .above, key: Self.cMajor) == [64, 65, 67, 69, 71, 72, 74])
        #expect(Self.pitches(lead, .third, .below, key: Self.cMajor) == [57, 59, 60, 62, 64, 65, 67])
        #expect(Self.pitches(lead, .sixth, .above, key: Self.cMajor) == [69, 71, 72, 74, 76, 77, 79])
        #expect(Self.pitches(lead, .sixth, .below, key: Self.cMajor) == [52, 53, 55, 57, 59, 60, 62])
        #expect(Self.pitches(lead, .fifth, .above, key: Self.cMajor) == [67, 69, 71, 72, 74, 76, 77])
        #expect(Self.pitches(lead, .fifth, .below, key: Self.cMajor) == [53, 55, 57, 59, 60, 62, 64])
        #expect(Self.pitches(lead, .octave, .above, key: Self.cMajor) == lead.map { $0 + 12 })
        #expect(Self.pitches(lead, .octave, .below, key: Self.cMajor) == lead.map { $0 - 12 })
    }

    @Test("A minor (natural): every interval, above and below, on each of the seven scale notes")
    func aMinorTable() {
        let lead = [57, 59, 60, 62, 64, 65, 67]                                      // A3 B C D E F G
        #expect(Self.pitches(lead, .third, .above, key: Self.aMinor) == [60, 62, 64, 65, 67, 69, 71])
        #expect(Self.pitches(lead, .third, .below, key: Self.aMinor) == [53, 55, 57, 59, 60, 62, 64])
        #expect(Self.pitches(lead, .sixth, .above, key: Self.aMinor) == [65, 67, 69, 71, 72, 74, 76])
        #expect(Self.pitches(lead, .sixth, .below, key: Self.aMinor) == [48, 50, 52, 53, 55, 57, 59])
        #expect(Self.pitches(lead, .fifth, .above, key: Self.aMinor) == [64, 65, 67, 69, 71, 72, 74])
        #expect(Self.pitches(lead, .fifth, .below, key: Self.aMinor) == [50, 52, 53, 55, 57, 59, 60])
        #expect(Self.pitches(lead, .octave, .above, key: Self.aMinor) == lead.map { $0 + 12 })
        #expect(Self.pitches(lead, .octave, .below, key: Self.aMinor) == lead.map { $0 - 12 })
    }

    @Test("G major: the tonic is not C, so the F# is a scale note (third above G-A-B-C-D-E-F#)")
    func gMajorThirds() {
        #expect(Self.pitches([67, 69, 71, 72, 74, 76, 78], .third, .above, key: Self.gMajor)
                == [71, 72, 74, 76, 78, 79, 81])                                     // B C D E F# G A
        #expect(Self.pitches([66], .third, .below, key: Self.gMajor) == [62])          // F# -> D
    }

    @Test("a chromatic lead note takes the step of its scale degree below, as a semitone distance")
    func chromaticLeadNotes() {
        let plan = HarmonyPlanner.notes(lead: Self.melody([61, 66]),
                                        spec: HarmonySpec(interval: .third, direction: .above, chordSource: .none),
                                        key: Self.cMajor, partIndex: 1, chordAt: { _ in nil })
        // C# takes C's third (+4): F. F# takes F's third (+4): A#.
        #expect(plan.notes.map(\.pitch) == [65, 70])
        #expect(plan.notes.allSatisfy { $0.rule == .chromatic })
        // A minor's raised seventh (G#) takes G's third (+4): C, not B. MEASURED consequence of the §4.3 [A] rule…
        #expect(Self.pitches([68], .third, .above, key: Self.aMinor) == [72])
        // …which the chord snap corrects when the V chord (E G# B) sounds: B, 1 semitone from C, not E (4).
        let lead = Self.clip([Self.note(68, 0)])
        let leadTrack = Track(name: "Lead", kind: .instrument, clips: [lead])
        let snapped = HarmonyPlanner.derivedPart(
            clip: lead, on: leadTrack,
            tracks: [leadTrack, Self.track("Keys", [Self.note(52, 0), Self.note(56, 0), Self.note(59, 0)])],
            spec: HarmonySpec(interval: .third, direction: .above, chordSource: .otherTracks), key: Self.aMinor,
            partIndex: 1)
        #expect(snapped.notes.map(\.pitch) == [71])
        #expect(snapped.notes.map(\.rule) == [.chordSnap])
    }

    // MARK: - The snap's edges

    @Test("snap edges: a tie goes to the tone nearer the lead; no tone in 3-9 semitones keeps the step; octaves never snap")
    func snapEdges() {
        // Lead C5, diatonic E5 (76). Chord D# F A#: D#5 (75) and F5 (77) are both 1 from E: the nearer the lead wins.
        #expect(HarmonyPlanner.snap(lead: 72, diatonic: 76, interval: .third, direction: .above, chord: [3, 5, 10])
                == 75)
        // Below: lead C5, a sixth below is E4 (64). Chord D# F A#: F4 (65, 7 below) and D#4 (63, 9 below) are both 1
        // from E: F4, nearer the lead, wins. (A#4 is only 2 below the lead: outside the window.)
        #expect(HarmonyPlanner.snap(lead: 72, diatonic: 64, interval: .sixth, direction: .below, chord: [3, 5, 10])
                == 65)
        // Only one candidate in the window: G#4 (68) for the third below C5 (A4, 69) under G# A# D.
        #expect(HarmonyPlanner.snap(lead: 72, diatonic: 69, interval: .third, direction: .below, chord: [8, 10, 2])
                == 68)
        // Chord C C# D: nothing 3-9 semitones above C5 (75-81) is a chord tone: no snap.
        #expect(HarmonyPlanner.snap(lead: 72, diatonic: 76, interval: .third, direction: .above, chord: [0, 1, 2])
                == nil)
        // The diatonic note already a chord tone: no snap.
        #expect(HarmonyPlanner.snap(lead: 72, diatonic: 76, interval: .third, direction: .above, chord: [0, 4, 7])
                == nil)
        // An octave doubles the lead and is never moved, chord or not.
        #expect(HarmonyPlanner.snap(lead: 74, diatonic: 86, interval: .octave, direction: .above, chord: [7, 11, 2])
                == nil)
        #expect(HarmonyPlanner.snap(lead: 74, diatonic: 86, interval: .octave, direction: .above, chord: [0, 4, 9])
                == nil)
    }

    // MARK: - The rules that never bend

    /// Seeded chords (3-5 pitch classes) at every onset.
    static func seededChords(count: Int) -> [Set<Int>] {
        var state: UInt64 = 0x4A12_0004
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        return (0..<count).map { _ in
            var chord = Set<Int>()
            let size = 3 + next(3)
            while chord.count < size { chord.insert(next(12)) }
            return chord
        }
    }

    @Test("never unison, never a crossing: every lead pitch 36-96, every interval and side, three keys, seeded chords")
    func neverUnisonNeverCrossing() {
        let lead = Self.melody(Array(36...96))
        let chords = Self.seededChords(count: lead.count)
        for key in [Self.cMajor, Self.aMinor, SongKey(tonicPitchClass: 6, mode: .minor)] {
            for interval in HarmonySpec.Interval.allCases {
                for direction in HarmonySpec.Direction.allCases {
                    for source in [HarmonySpec.ChordSource.none, .otherTracks] {
                        let plan = HarmonyPlanner.notes(
                            lead: lead, spec: HarmonySpec(interval: interval, direction: direction, chordSource: source),
                            key: key, partIndex: 1, chordAt: { chords[Int($0)] })
                        for note in plan.notes {
                            let side = direction == .above ? note.pitch > note.leadPitch : note.pitch < note.leadPitch
                            #expect(side, "\(key.name) \(interval) \(direction) \(source): lead \(note.leadPitch) -> \(note.pitch)")
                        }
                        #expect(plan.notes.count == lead.count)
                    }
                }
            }
        }
    }

    @Test("a step is a real interval: thirds 3-4 semitones, fifths 6-7, sixths 8-9, octaves 12, chromatic notes included")
    func stepSizes() {
        let lead = Self.melody(Array(48...84))
        let sizes: [HarmonySpec.Interval: Set<Int>] = [.third: [3, 4], .fifth: [6, 7], .sixth: [8, 9], .octave: [12]]
        for key in [Self.cMajor, Self.aMinor, Self.gMajor] {
            for (interval, allowed) in sizes {
                for direction in HarmonySpec.Direction.allCases {
                    let plan = HarmonyPlanner.notes(lead: lead, spec: HarmonySpec(interval: interval,
                                                                                   direction: direction,
                                                                                   chordSource: .none),
                                                    key: key, partIndex: 1, chordAt: { _ in nil })
                    for note in plan.notes {
                        #expect(allowed.contains(abs(note.pitch - note.leadPitch)),
                                "\(key.name) \(interval) \(direction): \(note.leadPitch) -> \(note.pitch)")
                    }
                }
            }
        }
    }

    // MARK: - Ids, the transient clip, the fold

    @Test("same input, same plan and same note ids; another part index, other ids; never a lead note's id")
    func noteIDsAreDerived() {
        let lead = Self.clip(Self.leadCToG, lyrics: "la la la la la")
        let track = Track(name: "Lead", kind: .instrument, clips: [lead])
        let spec = HarmonySpec(interval: .sixth, direction: .below)
        let first = HarmonyPlanner.derivedPart(clip: lead, on: track, tracks: [track], spec: spec, key: Self.cMajor,
                                               partIndex: 1)
        let again = HarmonyPlanner.derivedPart(clip: lead, on: track, tracks: [track], spec: spec, key: Self.cMajor,
                                               partIndex: 1)
        let second = HarmonyPlanner.derivedPart(clip: lead, on: track, tracks: [track], spec: spec, key: Self.cMajor,
                                                partIndex: 2)
        #expect(first == again)
        let ids = first.notes.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids).isDisjoint(with: Set(second.notes.map(\.id))))
        #expect(Set(ids).isDisjoint(with: Set(Self.leadCToG.map(\.id))))
        for note in first.notes {
            #expect(note.id == HarmonyPlanner.partNoteID(leadNoteID: note.leadNoteID, partIndex: 1))
        }
        // The transient clip: same id, same words, the part's notes with the lead's timing.
        let transient = first.transientClip(replacingNotesOf: lead)
        #expect(transient.id == lead.id && transient.lyrics == lead.lyrics && transient.lengthBeats == lead.lengthBeats)
        #expect(transient.notes?.map(\.startBeat) == Self.leadCToG.map(\.startBeat))
        #expect(transient.notes?.map(\.lengthBeats) == Self.leadCToG.map(\.lengthBeats))
        #expect(transient.notes?.map(\.pitch) == [64, 65, 67, 69, 71])               // a sixth below C5-G5
    }

    @Test("a part past the top of MIDI moves as a WHOLE by octaves; no note is clamped")
    func wholePartFold() {
        // F9 (125) and G9 (127): a third above is A9 (129) and B9 (131), past 127.
        let plan = HarmonyPlanner.notes(lead: Self.melody([125, 127]),
                                        spec: HarmonySpec(interval: .third, direction: .above, chordSource: .none),
                                        key: Self.cMajor, partIndex: 1, chordAt: { _ in nil })
        #expect(plan.foldOctaves == -1)
        #expect(plan.notes.map(\.pitch) == [117, 119])
        #expect(plan.partNotes.map(\.pitch) == [117, 119])
        // Every note moved by the same whole octave from its step.
        #expect(plan.notes.allSatisfy { ($0.pitch - $0.leadPitch) - 4 == -12 })
    }

    // MARK: - Chord tones of the melody clip (§4.2)

    @Test("chord tones: the 2nd (or 3rd) note from the top where the clip has a chord; a third below fills single notes")
    func chordTonesPart() throws {
        // Beat 0: C5 over G4 E4. Beat 1: D5 alone. Beat 2: E5 over C5 (two notes).
        let notes = [Self.note(72, 0), Self.note(67, 0), Self.note(64, 0), Self.note(74, 1),
                     Self.note(76, 2), Self.note(72, 2)]
        let lead = Self.clip(notes)
        let track = Track(name: "Lead", kind: .instrument, clips: [lead])
        let second = try HarmonyPlanner.chordTonePart(clip: lead, on: track, tracks: [track], rank: .second,
                                                      fillInterval: .third, fillChordSource: .none, key: Self.cMajor,
                                                      partIndex: 1)
        #expect(second.notes.map(\.leadPitch) == [72, 74, 76])
        #expect(second.notes.map(\.pitch) == [67, 71, 72])                          // G4, B4 (third below D), C5
        #expect(second.notes.map(\.rule) == [.chordTone, .diatonic, .chordTone])
        let third = try HarmonyPlanner.chordTonePart(clip: lead, on: track, tracks: [track], rank: .third,
                                                     fillInterval: .third, fillChordSource: .none, key: Self.cMajor,
                                                     partIndex: 1)
        #expect(third.notes.map(\.pitch) == [64, 71, 72])                           // E4, B4, C5 (third below E5)
        #expect(third.notes.map(\.rule) == [.chordTone, .diatonic, .diatonic])
        // Always below the lead.
        #expect((second.notes + third.notes).allSatisfy { $0.pitch < $0.leadPitch })
    }

    @Test("chord tones need a key only when a single note needs the fill")
    func chordTonesKey() throws {
        let allChords = Self.clip([Self.note(72, 0), Self.note(67, 0), Self.note(64, 0),
                                   Self.note(74, 1), Self.note(71, 1), Self.note(67, 1)])
        let track = Track(name: "Lead", kind: .instrument, clips: [allChords])
        let plan = try HarmonyPlanner.chordTonePart(clip: allChords, on: track, tracks: [track], rank: .second,
                                                    fillInterval: .third, fillChordSource: .none, key: nil,
                                                    partIndex: 1)
        #expect(plan.notes.map(\.pitch) == [67, 71])
        #expect(plan.key == nil)
        let oneSingle = Self.clip([Self.note(72, 0), Self.note(67, 0), Self.note(64, 0), Self.note(74, 1)])
        let single = Track(name: "Lead", kind: .instrument, clips: [oneSingle])
        #expect(throws: HarmonyRefusal.needsKey) {
            try HarmonyPlanner.chordTonePart(clip: oneSingle, on: single, tracks: [single], rank: .second,
                                             fillInterval: .third, fillChordSource: .none, key: nil, partIndex: 1)
        }
    }
}

/// The key a part is counted in, and the height it is sung at (§4.3 "The key", §4.5).
@Suite("HarmonyPlanner: the song's key and the part's octave (p2-sing-x4)")
struct HarmonyPlannerKeyAndRangeTests {

    static let tempo = TempoMap(constantBPM: 120)
    static let meter = MeterMap(constant: TimeSignature())
    static let cMajor = SongKey(tonicPitchClass: 0, mode: .major)

    static func note(_ pitch: Int, _ start: Double, _ length: Double = 1) -> MIDINote {
        MIDINote(pitch: pitch, velocity: 100, startBeat: start, lengthBeats: length)
    }

    static func track(_ name: String, _ notes: [MIDINote], instrument: InstrumentDescriptor? = nil,
                      muted: Bool = false, clipLength: Double? = nil) -> Track {
        let clip = Clip(name: name, startBeat: 0, lengthBeats: clipLength ?? (notes.map(\.endBeat).max() ?? 4),
                        notes: notes)
        var track = Track(name: name, kind: .instrument, clips: [clip])
        track.instrument = instrument
        track.isMuted = muted
        return track
    }

    /// C - F - G - C triads, 4 beats each, and a melody over them.
    static var songInC: [Track] {
        let chords: [[Int]] = [[48, 52, 55], [53, 57, 60], [55, 59, 62], [48, 52, 55]]
        let keys = chords.enumerated().flatMap { index, chord in chord.map { note($0, Double(index * 4), 4) } }
        let melody = [72, 74, 76, 77, 79, 77, 76, 74, 72, 71, 72, 74, 76, 74, 72, 72].enumerated()
            .map { note($0.element, Double($0.offset)) }
        return [track("Keys", keys), track("Melody", melody)]
    }

    // MARK: - The key

    @Test("the project key: a C-F-G-C song with a melody reads C major, tonal, source 'estimated'")
    func estimatesTheSongKey() throws {
        let estimate = HarmonyPlanner.estimateKey(tracks: Self.songInC, tempoMap: Self.tempo)
        #expect(estimate.tonic == "C" && estimate.mode == "major" && estimate.tonal)
        let key = try HarmonyPlanner.resolveKey(given: nil, tracks: Self.songInC, tempoMap: Self.tempo)
        #expect(key.tonicPitchClass == 0 && key.mode == .major && key.source == .estimated)
        #expect(key.confidence == estimate.confidence)
        #expect(key.name == "C major")
    }

    @Test("the key chroma is seconds of sound per pitch class, by playback's rule (a note past the clip end is cut)")
    func keyChromaIsSecondsAsPlayed() {
        // 120 BPM: C4 for 2 beats = 1 s; E4 for 1 beat = 0.5 s; G4 starts at beat 3 of a 4-beat clip and is cut to
        // 1 beat = 0.5 s; a note starting AT the clip end never sounds.
        let track = Self.track("Keys", [Self.note(60, 0, 2), Self.note(64, 2, 1), Self.note(67, 3, 4),
                                        Self.note(71, 4, 1)], clipLength: 4)
        let chroma = HarmonyPlanner.keyChroma(tracks: [track], tempoMap: Self.tempo)
        var expected = [Double](repeating: 0, count: 12)
        expected[0] = 1.0
        expected[4] = 0.5
        expected[7] = 0.5
        #expect(chroma == expected)
    }

    @Test("drum tracks and slice kits are not pitched: their notes never reach the key; muted tracks do count")
    func keyChromaSources() {
        let base = Self.songInC
        let baseChroma = HarmonyPlanner.keyChroma(tracks: base, tempoMap: Self.tempo)
        let noise = (0..<16).map { Self.note(61 + ($0 % 5), Double($0)) }               // C# D D# E F, 16 beats
        var params = SamplerParams(zones: [SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/x4-slices.wav"),
                                                       rootPitch: 36, minPitch: 36, maxPitch: 36, gain: 1)], gain: 1)
        params.markSliceKit()
        let excluded = base + [Self.track("Drums", noise, instrument: InstrumentDescriptor(kind: .drumSynth)),
                               Self.track("Chops", noise, instrument: InstrumentDescriptor(kind: .sampler,
                                                                                            sampler: params))]
        #expect(HarmonyPlanner.keyChroma(tracks: excluded, tempoMap: Self.tempo) == baseChroma)
        // Positive control: the same notes on an ordinary track DO change the chroma; muted, they still count.
        let pitched = base + [Self.track("Lead 2", noise)]
        let mutedPitched = base + [Self.track("Lead 2", noise, muted: true)]
        #expect(HarmonyPlanner.keyChroma(tracks: pitched, tempoMap: Self.tempo) != baseChroma)
        #expect(HarmonyPlanner.keyChroma(tracks: mutedPitched, tempoMap: Self.tempo)
                == HarmonyPlanner.keyChroma(tracks: pitched, tempoMap: Self.tempo))
    }

    @Test("not tonal: singHarmonyNeedsKey, with §14's sentence; a given key never refuses")
    func needsKey() throws {
        // Twelve pitch classes, equal time each: a flat chroma.
        let chromatic = [Self.track("Keys", (0..<12).map { Self.note(60 + $0, Double($0)) })]
        #expect(!HarmonyPlanner.estimateKey(tracks: chromatic, tempoMap: Self.tempo).tonal)
        #expect(throws: HarmonyRefusal.needsKey) {
            try HarmonyPlanner.resolveKey(given: nil, tracks: chromatic, tempoMap: Self.tempo)
        }
        #expect(throws: HarmonyRefusal.needsKey) {
            try HarmonyPlanner.resolveKey(given: nil, tracks: [], tempoMap: Self.tempo)
        }
        #expect(HarmonyRefusal.needsKey.code == "singHarmonyNeedsKey")
        #expect(HarmonyRefusal.needsKey.sentence
                == "I couldn't tell this song's key. Pick the key, and I'll work out the harmony.")
        let given = SongKey(tonicPitchClass: 14, mode: .minor)
        #expect(given.tonicPitchClass == 2 && given.source == .given && given.confidence == 1)
        #expect(try HarmonyPlanner.resolveKey(given: given, tracks: chromatic, tempoMap: Self.tempo) == given)
    }

    @Test("an estimate bridges to a SongKey through the one pitch-class table; an unknown name does not")
    func estimateBridge() {
        for (index, name) in KeyEstimate.pitchClassesSharp.enumerated() {
            for mode in KeyMode.allCases {
                let estimate = KeyEstimate(tonic: name, mode: mode.rawValue, confidence: 0.5, tonal: true,
                                           alternatives: [])
                #expect(SongKey(estimate: estimate)
                        == SongKey(tonicPitchClass: index, mode: mode, source: .estimated, confidence: 0.5))
            }
        }
        #expect(SongKey(estimate: KeyEstimate(tonic: "H", mode: "major", confidence: 1, tonal: true,
                                              alternatives: [])) == nil)
        #expect(SongKey(estimate: KeyEstimate(tonic: "C", mode: "dorian", confidence: 1, tonal: true,
                                              alternatives: [])) == nil)
    }

    // MARK: - The part's octave (§4.5)

    static func part(_ lead: [Int], _ interval: HarmonySpec.Interval, _ direction: HarmonySpec.Direction)
        -> HarmonyPlan {
        HarmonyPlanner.notes(lead: lead.enumerated().map { note($0.element, Double($0.offset)) },
                             spec: HarmonySpec(interval: interval, direction: direction, chordSource: .none),
                             key: cMajor, partIndex: 1, chordAt: { _ in nil })
    }

    static func range(_ plan: HarmonyPlan, voice: VoiceRange?, lead: Int = 0) -> HarmonyRange {
        HarmonyPlanner.range(of: plan, clipStartBeat: 0, tempoMap: tempo, voice: voice, leadOctaveShift: lead)
    }

    @Test("range: a part that fits takes the lead's octave")
    func partThatFits() {
        // C4-G4, a third above: E4-B4, inside a voice of C4..C5 (band B3..C#5).
        let result = Self.range(Self.part([60, 62, 64, 65, 67], .third, .above),
                                voice: VoiceRange(p10Midi: 60, medianMidi: 66, p90Midi: 72))
        #expect(result.octaveShift == 0)
        #expect(result.fits)
        #expect(result.sentence == "Fits your voice.")
    }

    @Test("range: a part one octave too low moves up one WHOLE octave")
    func partTooLow() {
        // C3-G3, a third above: E3-B3, all under the same voice: the whole part goes up 12.
        let result = Self.range(Self.part([48, 50, 52, 53, 55], .third, .above),
                                voice: VoiceRange(p10Midi: 60, medianMidi: 66, p90Midi: 72))
        #expect(result.octaveShift == 1)
        #expect(result.fits)
        #expect(result.sentence == "I'll sing this part an octave higher.")
    }

    @Test("range: a tie goes to the LEAD's octave, not the smallest move (VoiceRangeFit.pick's rule)")
    func tieGoesToTheLeadsOctave() {
        // E4-B4 (median G4 = 67) and E3-B3 (median 55) sit 6 semitones either side of the voice's median (61), both
        // inside its band (52...71): equal costs.
        let plan = Self.part([60, 62, 64, 65, 67], .third, .above)
        let voice = VoiceRange(p10Midi: 53, medianMidi: 61, p90Midi: 70)
        let atZero = Self.range(plan, voice: voice, lead: 0)
        let atMinusOne = Self.range(plan, voice: voice, lead: -1)
        let costs = Dictionary(uniqueKeysWithValues: atZero.candidates.map { ($0.octaveShift, $0.cost) })
        #expect(abs((costs[0] ?? 99) - (costs[-1] ?? -99)) <= KeyFitWeights.provisional.tieWindow)
        #expect(atZero.octaveShift == 0)
        #expect(atMinusOne.octaveShift == -1)
        #expect(atMinusOne.sentence == "I'll sing this part an octave lower.")
    }

    @Test("range: out of the voice's band after the best octave is an amber warning, never a refusal")
    func outOfRange() {
        // p2-sing-x9-f3 (W8-X9F3B) moved this voice: at 36/40/44 E4-B4 two octaves down (E2-B2) pokes only 2 semitones
        // over the band with its B2, 0.4 on average, and a harmony part now fits up to 3.0 (checked below). A voice
        // far lower (p10 19, p90 27: band F#0 (18) to E1 (28), the same width) leaves E2-B2 12 to 19 semitones over.
        let high = Self.range(Self.part([60, 62, 64, 65, 67], .third, .above),
                              voice: VoiceRange(p10Midi: 19, medianMidi: 23, p90Midi: 27))
        #expect(high.octaveShift == -2)
        #expect(!high.fits)
        let before = Self.range(Self.part([60, 62, 64, 65, 67], .third, .above),
                                voice: VoiceRange(p10Midi: 36, medianMidi: 40, p90Midi: 44))
        #expect(before.octaveShift == -2 && before.fits && before.sentence == "I'll sing this part two octaves lower.")
        // p2-sing-x9-f1: the line says the part was moved, and names no other choice, because neither 'a sixth below'
        // nor 'a third below' fits this voice when measured on its own (`HarmonyPlannerRangeLineTests`).
        #expect(high.sentence == "I'll sing this part two octaves lower. That's the closest fit, but it still goes "
                + "higher than this voice usually sings. 'A sixth below' and 'a third below' don't fit this voice "
                + "either. Try a different voice, or move the song's key.")
        // A high voice: E3-B3 stays under its band even two octaves up.
        let low = Self.range(Self.part([48, 50, 52, 53, 55], .third, .above),
                             voice: VoiceRange(p10Midi: 84, medianMidi: 88, p90Midi: 92))
        #expect(low.octaveShift == 2)
        #expect(!low.fits)
        #expect(low.sentence == "I'll sing this part two octaves higher. That's the closest fit, but it still goes "
                + "lower than this voice usually sings. 'A sixth below' and 'a third below' don't fit this voice "
                + "either. Try a different voice, or move the song's key.")
    }

    @Test("range: an octave part is never moved into unison with the lead; no voice keeps the lead's octave")
    func unisonHeightAndNoVoice() {
        let octave = Self.part([60, 62, 64, 65, 67], .octave, .above)
        // The voice sits right on the lead: an octave above one octave down would be the lead itself.
        let result = Self.range(octave, voice: VoiceRange(p10Midi: 58, medianMidi: 64, p90Midi: 70))
        #expect(!result.candidates.contains { $0.octaveShift == -1 })
        #expect(result.octaveShift != -1)
        #expect(result.candidates.count == 4)
        let none = Self.range(octave, voice: nil, lead: -1)
        #expect(none.octaveShift == -1 && none.fits && none.sentence == nil && none.fit == nil)
    }

    @Test("target − source = the planned interval + 12k for every note, k one whole octave for the part (base §3.4 extended)")
    func octaveLawThroughTheSingPlanner() throws {
        let leadNotes = [48, 50, 52, 53, 55].enumerated().map { Self.note($0.element, Double($0.offset)) }
        let lead = Clip(name: "Melody", startBeat: 0, lengthBeats: 5, notes: leadNotes,
                        lyrics: ClipLyrics(text: "la la la la la"))
        let track = Track(name: "Lead", kind: .instrument, clips: [lead])
        let voice = VoiceRange(p10Midi: 60, medianMidi: 66, p90Midi: 72)
        for (interval, direction) in [(HarmonySpec.Interval.third, HarmonySpec.Direction.above), (.sixth, .below),
                                      (.fifth, .above), (.third, .below)] {
            let plan = HarmonyPlanner.derivedPart(clip: lead, on: track, tracks: [track],
                                                  spec: HarmonySpec(interval: interval, direction: direction),
                                                  key: Self.cMajor, partIndex: 1)
            let height = HarmonyPlanner.range(of: plan, clipStartBeat: 0, tempoMap: Self.tempo, voice: voice,
                                              leadOctaveShift: 0)
            let sung = try SingPlanner.plan(clip: plan.transientClip(replacingNotesOf: lead), on: track,
                                            tempoMap: Self.tempo, meterMap: Self.meter,
                                            octaveShift: height.octaveShift)
            let leadPlan = try SingPlanner.plan(clip: lead, on: track, tempoMap: Self.tempo, meterMap: Self.meter,
                                                octaveShift: 0)
            let byID = Dictionary(uniqueKeysWithValues: plan.notes.map { ($0.id, $0) })
            #expect(sung.notes.count == leadNotes.count, "\(interval) \(direction)")
            for note in sung.notes {
                let planned = try #require(byID[note.noteID])
                #expect(note.midi - planned.leadPitch
                        == (planned.pitch - planned.leadPitch) + 12 * height.octaveShift, "\(interval) \(direction)")
                #expect(note.midi - note.sourcePitch == 12 * height.octaveShift)
            }
            // The words land on the same notes: same units, same words, same note indices, same times.
            #expect(sung.units.map { $0.words.map(\.text) } == leadPlan.units.map { $0.words.map(\.text) })
            #expect(sung.units.map { $0.words.map(\.noteIndices) } == leadPlan.units.map { $0.words.map(\.noteIndices) })
            #expect(sung.notes.map(\.startSeconds) == leadPlan.notes.map(\.startSeconds))
            #expect(sung.notes.map(\.endSeconds) == leadPlan.notes.map(\.endSeconds))
        }
    }
}
