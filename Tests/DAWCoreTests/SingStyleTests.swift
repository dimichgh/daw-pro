import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x5 (design `docs/design/2026-10-06-p2-sing-expansion.md` §5.3, §5.7 "Model"): `Clip.singStyle` as a
/// value — one spelling for "no style", lenient decoding, the JSON shape, the `ClipDocument` mirror and both
/// reconstructions, what one note resolves to, and the pure rebuild sites (`CompFlattener`). Pure values, so NOT
/// `@MainActor`; the store's rebuild sites are pinned in `SingStyleRebuildStoreTests.swift` (an extension of the
/// existing `ProjectStoreClipEditTests`).
@Suite("Singing style on a melody clip: the model, its file form and its rebuild rule (p2-sing-x5)")
struct SingStyleTests {

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func sortedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func melody(_ style: SingStyle?, onsets: [Double] = [0, 1, 2, 3]) -> Clip {
        let notes = onsets.enumerated().map {
            MIDINote(id: id(100 + $0.offset), pitch: 60 + $0.offset, startBeat: $0.element, lengthBeats: 1)
        }
        return Clip(id: id(11), name: "Melody", lengthBeats: (onsets.last ?? 0) + 1, notes: notes, singStyle: style)
    }

    // MARK: - One spelling for "no style"

    // W9-PICKS (round V): the default vibrato became Normal, so a NAMED As sung is a choice and is no longer folded
    // into nil (that would sing Normal); see `picksDefaultVibratoIsNormal`.
    @Test("a style that chooses nothing is nil: air 0, followVelocity false, and empty per-note choices")
    func allDefaultIsNil() {
        #expect(SingStyle.normalized(nil) == nil)
        #expect(SingStyle.normalized(SingStyle()) == nil)
        #expect(SingStyle.normalized(SingStyle(air: 0, followVelocity: false, notes: [:])) == nil)
        #expect(SingStyle.normalized(SingStyle(notes: [Self.id(1): NoteSingStyle()])) == nil,
                "a per-note entry that chooses nothing is dropped, and then the map is empty")
        #expect(SingStyle(air: 0, followVelocity: false).isDefault)
        #expect(!SingStyle(vibrato: .straight).isDefault, "control: a real choice is not default")
        #expect(!SingStyle(vibrato: .asSung).isDefault, "As sung is a real choice")
        // Through Clip.init: the same rule, so "no style" survives a save unchanged.
        #expect(Self.melody(SingStyle(air: 0, followVelocity: false)).singStyle == nil)
    }

    @Test("at the NOTE level, asSung and air 0 are choices of their own and are kept")
    func perNoteDefaultsAreChoices() throws {
        let style = SingStyle(vibrato: .wide, air: 0.5,
                              notes: [Self.id(100): NoteSingStyle(vibrato: .asSung, air: 0)])
        let normalized = try #require(SingStyle.normalized(style))
        #expect(normalized.notes?[Self.id(100)] == NoteSingStyle(vibrato: .asSung, air: 0))
        #expect(normalized.resolvedVibrato(forNote: Self.id(100)) == .asSung)
        #expect(normalized.resolvedAir(forNote: Self.id(100)) == 0)
        #expect(normalized.resolvedVibrato(forNote: Self.id(101)) == .wide, "a note without a choice follows the clip")
        #expect(normalized.resolvedAir(forNote: Self.id(101)) == 0.5)
    }

    @Test("air is clamped to 0...1; NaN and infinities are no air; a clip-wide air that clamps to 0 is nil")
    func airIsClamped() {
        #expect(SingStyle.normalized(SingStyle(air: 1.5))?.air == 1)
        #expect(SingStyle.normalized(SingStyle(air: -0.2)) == nil)
        #expect(SingStyle.normalized(SingStyle(air: .nan)) == nil)
        #expect(SingStyle.normalized(SingStyle(air: .infinity)) == nil)
        #expect(SingStyle.normalized(SingStyle(notes: [Self.id(1): NoteSingStyle(air: -3)]))?.notes?[Self.id(1)]?.air
                == 0, "a per-note air below 0 clamps to an explicit 0")
        #expect(SingStyle.normalized(SingStyle(notes: [Self.id(1): NoteSingStyle(air: .nan)])) == nil)
        #expect(SingStyle(air: 7).resolvedAir(forNote: Self.id(1)) == 1, "resolution clamps too")
    }

    @Test("defaults resolve: no style sings Normal vibrato (the round-V pick, W9-PICKS), no air, at the notes' own level")
    func resolvedDefaults() {
        let none = SingStyle()
        #expect(none.resolvedVibrato(forNote: Self.id(1)) == .normal)
        #expect(none.resolvedAir(forNote: Self.id(1)) == 0)
        #expect(!none.followsVelocity)
        #expect(SingStyle(followVelocity: true).followsVelocity)
        #expect(SingStyle.Vibrato.allCases.map(\.rawValue) == ["asSung", "straight", "gentle", "normal", "wide"],
                "the five choices, in the card's order, spelled as the wire spells them")
    }

    // MARK: - On the clip

    @Test("only a MIDI clip carries a style: an audio clip drops it, as it drops lyrics")
    func midiOnly() {
        let style = SingStyle(vibrato: .normal)
        #expect(Self.melody(style).singStyle == style)
        let audio = Clip(name: "Vox", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/x5.wav"),
                         singStyle: style)
        #expect(audio.singStyle == nil)
        #expect(Clip(name: "Empty MIDI", lengthBeats: 4, notes: [], singStyle: style).singStyle == style,
                "an EMPTY MIDI clip is still MIDI")
    }

    @Test("a clip without a style writes no key; a styled one writes exactly one, in the agreed shape")
    func clipJSONShape() throws {
        let plain = try Self.sortedJSON(Self.melody(nil))
        #expect(!plain.contains("singStyle"))
        let style = SingStyle(vibrato: .gentle, air: 0.25, followVelocity: true,
                              notes: [Self.id(101): NoteSingStyle(vibrato: .straight, air: 0),
                                      Self.id(100): NoteSingStyle(vibrato: .wide)])
        let styled = try Self.sortedJSON(Self.melody(style))
        #expect(styled.components(separatedBy: "\"singStyle\"").count - 1 == 1)
        // The per-note choices are ONE object keyed by note id (not a key, value, key, value array).
        let expected = #"{"air":0.25,"followVelocity":true,"notes":{"00000000-0000-0000-0000-000000000100":{"vibrato":"wide"},"00000000-0000-0000-0000-000000000101":{"air":0,"vibrato":"straight"}},"vibrato":"gentle"}"#
        #expect(try Self.sortedJSON(style) == expected)
        #expect(styled.contains(#""singStyle":\#(expected)"#))
        let back = try JSONDecoder().decode(Clip.self, from: Data(styled.utf8))
        #expect(back == Self.melody(style), "the round trip is exact")
    }

    @Test("the encoders write the one spelling even when a default style was assigned directly")
    func encodersNormalise() throws {
        var clip = Self.melody(nil)
        clip.singStyle = SingStyle(air: 0, followVelocity: false)  // direct assignment skips Clip.init
        #expect(clip.singStyle != nil, "control: the property holds the non-nil default")
        #expect(!(try Self.sortedJSON(clip)).contains("singStyle"))
        #expect(ClipDocument(from: clip, media: nil).singStyle == nil)
        var audio = Clip(name: "Vox", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/x5.wav"))
        audio.singStyle = SingStyle(vibrato: .wide)
        #expect(!(try Self.sortedJSON(audio)).contains("singStyle"), "an audio clip never writes one")
        #expect(ClipDocument(from: audio, media: nil).singStyle == nil)
    }

    // MARK: - Lenient decoding

    @Test("decoding is lenient: missing keys, an unknown vibrato name, a key that is not a note id")
    func lenientDecode() throws {
        let empty = try JSONDecoder().decode(SingStyle.self, from: Data("{}".utf8))
        #expect(empty == SingStyle())
        let later = #"{"vibrato":"tremolo","air":0.5,"notes":{"00000000-0000-0000-0000-000000000100":{"vibrato":"choir","air":0.2},"not-a-note":{"vibrato":"wide"},"00000000-0000-0000-0000-000000000101":{"vibrato":"chorus"}}}"#
        let style = try JSONDecoder().decode(SingStyle.self, from: Data(later.utf8))
        #expect(style.vibrato == nil, "a preset from a later build reads as nil (as sung)")
        #expect(style.air == 0.5)
        #expect(style.notes?[Self.id(100)] == NoteSingStyle(vibrato: nil, air: 0.2))
        #expect(style.notes?.count == 2, "the key that is not a note id is skipped")
        // Through a clip, the entry left with no choice at all is normalised away.
        let clipJSON = #"{"id":"00000000-0000-0000-0000-000000000011","name":"Melody","notes":[],"singStyle":\#(later)}"#
        let clip = try JSONDecoder().decode(Clip.self, from: Data(clipJSON.utf8))
        #expect(clip.singStyle == SingStyle(air: 0.5, notes: [Self.id(100): NoteSingStyle(air: 0.2)]))
        let nullNotes = try JSONDecoder().decode(SingStyle.self, from: Data(#"{"notes":null}"#.utf8))
        #expect(nullNotes.notes == nil)
    }

    @Test("leniency covers missing keys and unknown names only: a field of the wrong type still throws")
    func wrongTypeThrows() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SingStyle.self, from: Data(#"{"air":"lots"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SingStyle.self, from: Data(#"{"vibrato":3}"#.utf8))
        }
    }

    @Test("an audio clip in a file that claims a style opens without one")
    func audioClipInAFileDropsIt() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000021","name":"Vox","audioFileURL":"file:///tmp/x5.wav","singStyle":{"vibrato":"wide"}}"#
        let clip = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
        #expect(clip.audioFileURL != nil, "control: it is an audio clip")
        #expect(clip.singStyle == nil)
    }

    // MARK: - Notes that come and go

    @Test("orphaned choices: a choice whose note the clip no longer holds is reported, sorted, and pruned only on request")
    func orphansAndPruning() throws {
        let style = SingStyle(vibrato: .normal,
                              notes: [Self.id(103): NoteSingStyle(vibrato: .wide),
                                      Self.id(100): NoteSingStyle(air: 0.3),
                                      Self.id(999): NoteSingStyle(vibrato: .straight)])
        let clip = Self.melody(style)
        #expect(clip.singStyle?.orphanedNoteIDs(in: clip.notes) == [Self.id(999)], "nothing pruned at construction")
        let pruned = try #require(style.keepingOverrides(for: clip.notes))
        #expect(pruned.notes?.keys.sorted { $0.uuidString < $1.uuidString } == [Self.id(100), Self.id(103)])
        #expect(pruned.vibrato == .normal, "the clip-wide choice stays")
        #expect(SingStyle(notes: [Self.id(999): NoteSingStyle(air: 1)]).keepingOverrides(for: clip.notes) == nil,
                "a piece left with no choice at all carries nil")
        #expect(style.keepingOverrides(for: nil)?.notes == nil, "no notes, no per-note choices")
        #expect(SingStyle().orphanedNoteIDs(in: clip.notes) == [])
    }

    // MARK: - The file: ClipDocument and both reconstructions

    /// A timeline melody, a take group of two MIDI lanes, and a comp member, each with its own style.
    static func persistenceTracks(styled: Bool) -> [Track] {
        func style(_ v: SingStyle.Vibrato, _ note: Int) -> SingStyle? {
            styled ? SingStyle(vibrato: v, air: 0.2, notes: [id(note): NoteSingStyle(vibrato: .asSung, air: 0)]) : nil
        }
        let laneNotes = [MIDINote(id: id(301), pitch: 67, startBeat: 0, lengthBeats: 2),
                         MIDINote(id: id(302), pitch: 69, startBeat: 2, lengthBeats: 2)]
        let lead = Self.melody(style(.wide, 100))
        let laneOne = TakeLane(id: id(31), name: "Take 1",
                               clip: Clip(id: id(32), name: "Keys one", lengthBeats: 4, notes: laneNotes,
                                          singStyle: style(.gentle, 301)))
        let laneTwo = TakeLane(id: id(33), name: "Take 2",
                               clip: Clip(id: id(34), name: "Keys two", lengthBeats: 4,
                                          notes: [MIDINote(id: id(303), pitch: 65, startBeat: 0, lengthBeats: 4)]))
        let group = TakeGroup(id: id(30), name: "Keys takes", lanes: [laneOne, laneTwo],
                              comp: [CompSegment(laneID: id(31), startBeat: 0, endBeat: 4)])
        let member = Clip(id: id(35), name: "Keys comp", lengthBeats: 4, notes: laneNotes, takeGroupID: id(30),
                          singStyle: style(.gentle, 302))
        return [Track(id: id(1), name: "Lead", kind: .instrument, clips: [lead]),
                Track(id: id(3), name: "Keys", kind: .instrument, clips: [member], takeGroups: [group])]
    }

    static func document(_ tracks: [Track]) -> ProjectDocument {
        var document = ProjectDocument(name: "x5 style", transport: TransportState(), tracks: tracks,
                                       masterVolume: 1, mediaRefs: [:])
        document.savedAt = Date(timeIntervalSince1970: 1_790_000_000)
        return document
    }

    @Test("ClipDocument carries the style in its init, encode and decode, and both reconstructions bring it back")
    func fileRoundTrip() throws {
        let tracks = Self.persistenceTracks(styled: true)
        let melody = try #require(tracks.first?.clips.first)
        let record = ClipDocument(from: melody, media: nil)
        #expect(record.singStyle == melody.singStyle)
        #expect(try JSONDecoder().decode(ClipDocument.self, from: JSONEncoder().encode(record)) == record)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bytes = try encoder.encode(Self.document(tracks))
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.components(separatedBy: "\"singStyle\"").count - 1 == 3,
                "the timeline clip, the take-lane clip and the comp member")
        let reopened = try decoder.decode(ProjectDocument.self, from: bytes)
            .runtimeState(bundleURL: URL(fileURLWithPath: "/tmp/x5-style.dawproj")).tracks
        #expect(reopened == tracks, "runtimeState AND TakeGroupDocument.takeGroup carry it")
        let lanes = reopened.flatMap { $0.takeGroups }.flatMap { $0.lanes }.map { $0.clip.singStyle?.vibrato }
        #expect(lanes == [.gentle, nil], "control: the lane clip came back through the take-group reconstruction")

        // Without a style, not one key, and the bytes equal a styled project's minus its three keys' worth.
        let plain = String(decoding: try encoder.encode(Self.document(Self.persistenceTracks(styled: false))),
                           as: UTF8.self)
        #expect(!plain.contains("singStyle"))
    }

    // MARK: - The pure rebuild site: take comp members (CompFlattener)

    @Test("comp members carry the lane's clip-wide style and the choices of the notes in their own window")
    func compMembers() throws {
        let notes = [0.0, 1, 2, 3].enumerated().map {
            MIDINote(id: Self.id(400 + $0.offset), pitch: 60, startBeat: $0.element, lengthBeats: 1)
        }
        var choices: [UUID: NoteSingStyle] = [:]
        for note in notes { choices[note.id] = NoteSingStyle(vibrato: .wide) }
        let style = SingStyle(vibrato: .normal, followVelocity: true, notes: choices)
        let lane = TakeLane(name: "Take 1", clip: Clip(name: "Take 1", lengthBeats: 4, notes: notes, singStyle: style))
        let plain = TakeLane(name: "Take 2", clip: Clip(name: "Take 2", lengthBeats: 4, notes: notes))
        let group = TakeGroup(name: "Takes", lanes: [lane, plain],
                              comp: [CompSegment(laneID: lane.id, startBeat: 0, endBeat: 2),
                                     CompSegment(laneID: plain.id, startBeat: 2, endBeat: 3),
                                     CompSegment(laneID: lane.id, startBeat: 3, endBeat: 4)])
        let members = CompFlattener.flatten(group, tempoMap: TempoMap(constantBPM: 120))
        #expect(members.count == 3)
        let held = members.map { Set(($0.notes ?? []).map(\.id)) }
        #expect(held == [[Self.id(400), Self.id(401)], [Self.id(402)], [Self.id(403)]], "control: ids survive")
        #expect(members[0].singStyle == SingStyle(vibrato: .normal, followVelocity: true,
                                                  notes: [Self.id(400): NoteSingStyle(vibrato: .wide),
                                                          Self.id(401): NoteSingStyle(vibrato: .wide)]))
        #expect(members[1].singStyle == nil, "the member from the plain take has none")
        #expect(members[2].singStyle == SingStyle(vibrato: .normal, followVelocity: true,
                                                  notes: [Self.id(403): NoteSingStyle(vibrato: .wide)]))
        #expect(group.lanes[0].clip.singStyle == style, "the lane keeps its whole style")
    }
}

// MARK: - W9-PICKS (p2-sing-x9-picks): round V, Normal is the default vibrato

extension SingStyleTests {

    @Test("PICKS V: an unnamed vibrato is Normal (the round-V pick); a NAMED As sung is a choice and is kept")
    func picksDefaultVibratoIsNormal() {
        #expect(SingStyle.defaultVibrato == .normal)
        #expect(SingStyle().resolvedVibrato(forNote: Self.id(1)) == .normal)
        #expect(SingStyle(vibrato: .asSung).resolvedVibrato(forNote: Self.id(1)) == .asSung)
        #expect(SingStyle.normalized(SingStyle(vibrato: .asSung)) == SingStyle(vibrato: .asSung),
                "As sung is not folded into nil: nil would sing the default")
        #expect(!SingStyle(vibrato: .asSung).isDefault)
        #expect(Self.melody(SingStyle(vibrato: .asSung, air: 0)).singStyle == SingStyle(vibrato: .asSung))
        #expect(SingStyle.normalized(SingStyle(air: 0, followVelocity: false, notes: [:])) == nil,
                "choosing nothing is still nil")
        // Resolved at JOB time: the job's style names the vibrato; a named one is sung as given.
        #expect(SingStyle.resolved(nil) == SingStyle(vibrato: .normal))
        #expect(SingStyle.resolved(SingStyle(air: 0.5)) == SingStyle(vibrato: .normal, air: 0.5))
        for vibrato in SingStyle.Vibrato.allCases {
            #expect(SingStyle.resolved(SingStyle(vibrato: vibrato)).vibrato == vibrato, "an explicit \(vibrato)")
        }
    }

    @Test("PICKS V: resolved at job time, NEVER at decode: a saved clip opens with exactly the choices it was saved with")
    func picksDefaultIsNotResolvedAtDecode() throws {
        let plain = try Self.sortedJSON(Self.melody(nil))
        #expect(!plain.contains("singStyle"))
        #expect(try JSONDecoder().decode(Clip.self, from: Data(plain.utf8)).singStyle == nil,
                "a clip saved with no style opens with no style")
        let asSung = Self.melody(SingStyle(vibrato: .asSung))
        let json = try Self.sortedJSON(asSung)
        #expect(json.contains(#""singStyle":{"vibrato":"asSung"}"#), "a named As sung is written")
        #expect(try JSONDecoder().decode(Clip.self, from: Data(json.utf8)) == asSung)
        #expect(ClipDocument(from: asSung, media: nil).singStyle == SingStyle(vibrato: .asSung))
        let normal = try Self.sortedJSON(Self.melody(SingStyle(vibrato: .normal)))
        #expect(normal.contains(#""singStyle":{"vibrato":"normal"}"#), "a named Normal stays named")
    }
}
