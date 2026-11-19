import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d1b: `Clip.lyrics` in the project FILE. The disk path is the
/// `ClipDocument` mirror (the m12-f lesson: a second hand-maintained field
/// list), rebuilt into clips in TWO places, `ProjectDocument.runtimeState`
/// (timeline clips) and `TakeGroupDocument.takeGroup` (take-lane clips). This
/// suite pins all of them with one fixture that reaches all three
/// `ClipDocument` paths: a timeline MIDI clip, an audio clip, and a take group
/// of MIDI lanes with a comp member.
///
/// ⭐ `golden` was CAPTURED FROM THE ENCODER BEFORE p2-sing-d1b (a scratch
/// build of the unmodified `Sources/DAWCore`, see the note on `golden`), so a
/// project without lyrics or sung vocals saves byte for byte as it did.
/// Pure values, so NOT `@MainActor`; the store's own save and reopen is pinned
/// in SD2's extension of `ProjectStoreClipEditTests`.
@Suite("Clip lyrics in the project file: ClipDocument and both reconstructions (p2-sing-d1b)")
struct ClipLyricsPersistenceTests {

    typealias F = ClipLyricsPersistenceFixture

    static func encode(_ document: ProjectDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(document), as: UTF8.self)
    }

    static func decode(_ json: String) throws -> ProjectDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectDocument.self, from: Data(json.utf8))
    }

    /// The runtime tracks a saved document opens as.
    static func reopened(_ json: String) throws -> [Track] {
        try decode(json).runtimeState(bundleURL: F.bundleURL).tracks
    }

    /// `json` with `"lyrics":<value>` spliced into the clip whose id is
    /// `clipID`, exactly where the sorted-keys encoder puts it: after
    /// `lengthBeats`, before `media` (which `ClipDocument` always writes,
    /// `null` for a MIDI clip). Unchanged when the clip is not found.
    static func withLyrics(_ json: String, clipID: UUID, _ value: String) -> String {
        guard let id = json.range(of: #""id":"\#(clipID.uuidString)""#),
              let media = json.range(of: #","media":"#, range: id.upperBound..<json.endIndex) else { return json }
        var out = json
        out.insert(contentsOf: #","lyrics":\#(value)"#, at: media.lowerBound)
        return out
    }

    static let melodyLyrics = #"{"text":"twin-kle +\nlit-tle star"}"#
    static let takeLyrics = #"{"text":"hel-lo"}"#

    /// The golden with the fixture's lyrics in their three places.
    static var goldenWithLyrics: String {
        var json = withLyrics(golden, clipID: F.id(11), melodyLyrics)
        json = withLyrics(json, clipID: F.id(32), takeLyrics)
        return withLyrics(json, clipID: F.id(35), takeLyrics)
    }

    // MARK: - The golden

    @Test("⭐ a project without lyrics encodes byte-identically to the pre-lyrics golden, and round-trips")
    func goldenWithoutLyrics() throws {
        let json = try Self.encode(F.document(F.tracks(lyrics: false)))
        #expect(json == Self.golden)
        #expect(try Self.encode(Self.decode(Self.golden)) == Self.golden, "decode + encode changes nothing")
        let tracks = try Self.reopened(Self.golden)
        let clips = tracks.flatMap { $0.clips } + tracks.flatMap { $0.takeGroups }.flatMap { $0.lanes }.map { $0.clip }
        let carried = clips.filter { $0.lyrics != nil }.count
        #expect(clips.count == 5, "control: the fixture's five clips all came back")
        #expect(carried == 0)
        let sung = tracks.filter { $0.sungVocalProvenance != nil }.count
        #expect(sung == 0, "an old file has no sung-vocal record")
    }

    @Test("lyrics add exactly one key per clip that has them, and nothing else")
    func lyricsAreTheOnlyDifference() throws {
        let json = try Self.encode(F.document(F.tracks(lyrics: true)))
        #expect(json != Self.golden, "control: the lyrics are written")
        #expect(json == Self.goldenWithLyrics)
        let keys = json.components(separatedBy: #""lyrics":"#).count - 1
        #expect(keys == 3, "the timeline clip, the take-lane clip and the comp member")
    }

    @Test("save and reopen: the text comes back on the timeline clip, the take lane and the comp member")
    func roundTripThroughBothReconstructions() throws {
        let tracks = try Self.reopened(Self.goldenWithLyrics)
        let melody = try #require(tracks.flatMap { $0.clips }.first { $0.name == "Melody" })
        #expect(melody.lyrics == ClipLyrics(text: "twin-kle +\nlit-tle star"), "runtimeState")
        let member = try #require(tracks.flatMap { $0.clips }.first { $0.name == "Keys comp" })
        #expect(member.lyrics == ClipLyrics(text: "hel-lo"), "runtimeState, a comp member")
        let lanes = tracks.flatMap { $0.takeGroups }.flatMap { $0.lanes }
        let laneTexts = lanes.map { $0.clip.lyrics?.text }
        #expect(laneTexts == ["hel-lo", nil], "TakeGroupDocument.takeGroup")
        let vox = try #require(tracks.flatMap { $0.clips }.first { $0.name == "Vox take" })
        #expect(vox.lyrics == nil)
        // And back to the same bytes: the full circle.
        #expect(try Self.encode(F.document(tracks)) == Self.goldenWithLyrics)
        let reopenedURL = try #require(vox.audioFileURL)
        #expect(tracks == F.tracks(lyrics: true, audioURL: reopenedURL),
                "the reopened project equals the one that was saved")
    }

    @Test("blank text is no lyrics, in the model and in a file")
    func blankIsNil() throws {
        let blank = F.tracks(lyrics: true, melodyText: " \n\t ")
        #expect(try Self.encode(F.document(blank)).contains(#""text":"hel-lo""#), "control: the take lyrics stay")
        let melody = try #require(blank.first?.clips.first)
        #expect(melody.lyrics == nil, "Clip.init normalises blank text to nil")
        // A file that carries blank text opens as none and saves without the key.
        let file = Self.withLyrics(Self.golden, clipID: F.id(11), #"{"text":" \n "}"#)
        #expect(file != Self.golden, "control: the key is in the file")
        let tracks = try Self.reopened(file)
        #expect(tracks.first?.clips.first?.lyrics == nil)
        #expect(try Self.encode(F.document(tracks)) == Self.golden)
    }

    @Test("an audio clip never carries lyrics, even when a file says it does")
    func audioClipNeverCarries() throws {
        let file = Self.withLyrics(Self.golden, clipID: F.id(21), #"{"text":"la la"}"#)
        #expect(file != Self.golden, "control: the key is in the file")
        let tracks = try Self.reopened(file)
        let vox = try #require(tracks.flatMap { $0.clips }.first { $0.name == "Vox take" })
        #expect(vox.lyrics == nil)
        #expect(try Self.encode(F.document(tracks)) == Self.golden, "the stray key is gone after one save")
    }

    @Test("ClipDocument carries lyrics in its own init, encode and decode")
    func clipDocumentCarries() throws {
        let clip = try #require(F.tracks(lyrics: true).first?.clips.first)
        let document = ClipDocument(from: clip, media: nil)
        #expect(document.lyrics == ClipLyrics(text: "twin-kle +\nlit-tle star"))
        let data = try JSONEncoder().encode(document)
        let back = try JSONDecoder().decode(ClipDocument.self, from: data)
        #expect(back.lyrics == document.lyrics)
        #expect(back == document)
    }

    /// Captured by W7-SD2 at 2026-09-27 10:11 PDT from a scratch build of the tree's
    /// UNMODIFIED `Sources/DAWCore` (Model.swift d75cb551…, ProjectDocument.swift
    /// d6e264ad…, Takes.swift 8fc798d6…), encoding
    /// `ClipLyricsPersistenceFixture.document(tracks(lyrics: false))` with this
    /// suite's encoder. That build dropped lyrics on save: it encoded
    /// `tracks(lyrics: true)` to these same bytes (the bug p2-sing-d1b fixes).
    static let golden = #"{"masterVolume":1,"name":"SD2 lyrics golden","savedAt":"2026-09-21T14:13:20Z","schemaVersion":1,"tracks":[{"clips":[{"id":"00000000-0000-0000-0000-000000000011","isAIGenerated":false,"lengthBeats":8,"media":null,"name":"Melody","notes":[{"id":"00000000-0000-0000-0000-000000000101","lengthBeats":1,"pitch":60,"startBeat":0,"velocity":100},{"id":"00000000-0000-0000-0000-000000000102","lengthBeats":0.5,"pitch":62,"startBeat":1,"velocity":90},{"id":"00000000-0000-0000-0000-000000000103","lengthBeats":2,"pitch":64,"startBeat":2,"velocity":80}],"startBeat":4}],"id":"00000000-0000-0000-0000-000000000001","isAIGenerated":false,"isArmed":false,"isMuted":false,"isSoloed":false,"kind":"instrument","name":"Lead","pan":0,"volume":1},{"clips":[{"id":"00000000-0000-0000-0000-000000000021","isAIGenerated":false,"lengthBeats":8,"media":"media\/vox.wav","name":"Vox take","startBeat":0}],"id":"00000000-0000-0000-0000-000000000002","isAIGenerated":false,"isArmed":false,"isMuted":false,"isSoloed":false,"kind":"audio","name":"Vox","pan":0,"volume":1},{"clips":[{"id":"00000000-0000-0000-0000-000000000035","isAIGenerated":false,"lengthBeats":4,"media":null,"name":"Keys comp","notes":[{"id":"00000000-0000-0000-0000-000000000301","lengthBeats":2,"pitch":67,"startBeat":0,"velocity":100},{"id":"00000000-0000-0000-0000-000000000302","lengthBeats":2,"pitch":69,"startBeat":2,"velocity":100}],"startBeat":0,"takeGroupId":"00000000-0000-0000-0000-000000000030"}],"id":"00000000-0000-0000-0000-000000000003","isAIGenerated":false,"isArmed":false,"isMuted":false,"isSoloed":false,"kind":"instrument","name":"Keys","pan":0,"takeGroups":[{"comp":[{"endBeat":4,"laneId":"00000000-0000-0000-0000-000000000031","startBeat":0}],"crossfadeSeconds":0.01,"id":"00000000-0000-0000-0000-000000000030","lanes":[{"clip":{"id":"00000000-0000-0000-0000-000000000032","isAIGenerated":false,"lengthBeats":4,"media":null,"name":"Keys one","notes":[{"id":"00000000-0000-0000-0000-000000000301","lengthBeats":2,"pitch":67,"startBeat":0,"velocity":100},{"id":"00000000-0000-0000-0000-000000000302","lengthBeats":2,"pitch":69,"startBeat":2,"velocity":100}],"startBeat":0},"id":"00000000-0000-0000-0000-000000000031","name":"Take 1"},{"clip":{"id":"00000000-0000-0000-0000-000000000034","isAIGenerated":false,"lengthBeats":4,"media":null,"name":"Keys two","notes":[{"id":"00000000-0000-0000-0000-000000000303","lengthBeats":4,"pitch":65,"startBeat":0,"velocity":100}],"startBeat":0},"id":"00000000-0000-0000-0000-000000000033","name":"Take 2"}],"name":"Keys takes"}],"volume":1}],"transport":{"countInBars":1,"isLoopEnabled":false,"isMetronomeEnabled":false,"isPunchEnabled":false,"loopEndBeat":16,"loopStartBeat":0,"positionBeats":0,"punchInBeat":0,"punchOutBeat":4,"tempoBPM":120,"timeSignature":{"beatUnit":4,"beatsPerBar":4}}}"#
}

// BEGIN FIXTURE (compiled verbatim into the pre-change capture build; do not edit without re-capturing)
/// The golden's project, with fixed ids and a fixed save date.
enum ClipLyricsPersistenceFixture {

    static let bundleURL = URL(fileURLWithPath: "/tmp/sd2-lyrics-golden.dawproj")

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func takeNotes() -> [MIDINote] {
        [MIDINote(id: id(301), pitch: 67, velocity: 100, startBeat: 0, lengthBeats: 2),
         MIDINote(id: id(302), pitch: 69, velocity: 100, startBeat: 2, lengthBeats: 2)]
    }

    /// Lead: a timeline MIDI clip. Vox: an audio clip. Keys: a take group of
    /// two MIDI lanes and one comp member. With `lyrics`, the timeline clip,
    /// the first lane's clip and the member carry text.
    static func tracks(lyrics: Bool, melodyText: String = "twin-kle +\nlit-tle star",
                       audioURL: URL = URL(fileURLWithPath: "/tmp/sd2-golden-vox.wav")) -> [Track] {
        func text(_ s: String) -> ClipLyrics? { lyrics ? ClipLyrics(text: s) : nil }
        let melody = Clip(id: id(11), name: "Melody", startBeat: 4, lengthBeats: 8,
                          notes: [MIDINote(id: id(101), pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
                                  MIDINote(id: id(102), pitch: 62, velocity: 90, startBeat: 1, lengthBeats: 0.5),
                                  MIDINote(id: id(103), pitch: 64, velocity: 80, startBeat: 2, lengthBeats: 2)],
                          lyrics: text(melodyText))
        let lead = Track(id: id(1), name: "Lead", kind: .instrument, clips: [melody])
        let vox = Track(id: id(2), name: "Vox", kind: .audio,
                        clips: [Clip(id: id(21), name: "Vox take", startBeat: 0, lengthBeats: 8,
                                     audioFileURL: audioURL)])
        let laneOne = TakeLane(id: id(31), name: "Take 1",
                               clip: Clip(id: id(32), name: "Keys one", startBeat: 0, lengthBeats: 4,
                                          notes: takeNotes(), lyrics: text("hel-lo")))
        let laneTwo = TakeLane(id: id(33), name: "Take 2",
                               clip: Clip(id: id(34), name: "Keys two", startBeat: 0, lengthBeats: 4,
                                          notes: [MIDINote(id: id(303), pitch: 65, velocity: 100,
                                                           startBeat: 0, lengthBeats: 4)]))
        let group = TakeGroup(id: id(30), name: "Keys takes", lanes: [laneOne, laneTwo],
                              comp: [CompSegment(laneID: id(31), startBeat: 0, endBeat: 4)])
        let member = Clip(id: id(35), name: "Keys comp", startBeat: 0, lengthBeats: 4, notes: takeNotes(),
                          takeGroupID: id(30), lyrics: text("hel-lo"))
        let keys = Track(id: id(3), name: "Keys", kind: .instrument, clips: [member], takeGroups: [group])
        return [lead, vox, keys]
    }

    static func document(_ tracks: [Track]) -> ProjectDocument {
        var document = ProjectDocument(name: "SD2 lyrics golden", transport: TransportState(), tracks: tracks,
                                       masterVolume: 1, mediaRefs: [id(21): "media/vox.wav"])
        document.savedAt = Date(timeIntervalSince1970: 1_790_000_000)
        return document
    }
}
// END FIXTURE

// MARK: - S1 (p2-sing-x3, design docs/design/2026-10-06-p2-sing-expansion.md §9.2)

extension ClipLyricsPersistenceTests {

    /// PIN-BEFORE: these bytes were confirmed by W8-X3 on 2026-10-06 against the tree BEFORE
    /// `ClipLyrics.language` existed (run PB2 in the lane's STATUS). Lyrics without a language must keep
    /// encoding to exactly them, alone, inside a clip, and inside the project file.
    static let s1LyricsBytes = #"{"text":"twin-kle +\nlit-tle star"}"#
    static let s1ClipBytes =
        #"{"id":"00000000-0000-0000-0000-000000000011","isAIGenerated":false,"lengthBeats":8,"lyrics":{"text":"twin-kle +\nlit-tle star"},"name":"Melody","notes":[{"id":"00000000-0000-0000-0000-000000000101","lengthBeats":1,"pitch":60,"startBeat":0,"velocity":100},{"id":"00000000-0000-0000-0000-000000000102","lengthBeats":0.5,"pitch":62,"startBeat":1,"velocity":90},{"id":"00000000-0000-0000-0000-000000000103","lengthBeats":2,"pitch":64,"startBeat":2,"velocity":80}],"startBeat":4}"#

    static func sortedKeysJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("S1: lyrics without a language encode to the pin-before bytes: alone, in a clip, in the file; old bytes decode")
    func languageAbsentIsByteIdentical() throws {
        let lyrics = ClipLyrics(text: "twin-kle +\nlit-tle star")
        let lyricsJSON = try Self.sortedKeysJSON(lyrics)
        #expect(lyricsJSON == Self.s1LyricsBytes)
        let melody = try #require(F.tracks(lyrics: true).first?.clips.first)
        let clipJSON = try Self.sortedKeysJSON(melody)
        #expect(clipJSON == Self.s1ClipBytes)
        let fileJSON = try Self.encode(F.document(F.tracks(lyrics: true)))
        #expect(fileJSON == Self.goldenWithLyrics)
        // An old clip's lyrics (no language key) decode, and re-encode to the same bytes.
        let old = try JSONDecoder().decode(ClipLyrics.self, from: Data(Self.s1LyricsBytes.utf8))
        #expect(old == lyrics)
        let oldJSON = try Self.sortedKeysJSON(old)
        #expect(oldJSON == Self.s1LyricsBytes)
        let oldClip = try JSONDecoder().decode(Clip.self, from: Data(Self.s1ClipBytes.utf8))
        #expect(oldClip.lyrics == lyrics)
        let oldClipJSON = try Self.sortedKeysJSON(oldClip)
        #expect(oldClipJSON == Self.s1ClipBytes)
        // Added after the change (p2-sing-x3): an old clip is English, and "en" writes nothing.
        #expect(old.language == nil, "an old clip's lyrics are English")
        #expect(oldClip.lyrics?.language == nil)
        let english = try Self.sortedKeysJSON(ClipLyrics(text: "twin-kle +\nlit-tle star", language: "en"))
        #expect(english == Self.s1LyricsBytes, "\"en\" is English: stored as nil, written as nothing")
        let reopened = try Self.reopened(Self.goldenWithLyrics)
        let languages = reopened.flatMap { $0.clips }.compactMap { $0.lyrics }.map { $0.language }
        #expect(languages == [nil, nil], "the file's lyrics come back English (control: two clips carry lyrics)")
    }
}
