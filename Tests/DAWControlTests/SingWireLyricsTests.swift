import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

/// p2-sing-e part 2: `clip.setLyrics` and `clip.getLyrics` (design §6 rows 12–13), through the router, with a SPY in
/// front of `ProjectStore.setClipLyrics` (THE lyrics write, the words box's and the note field's). Nonisolated: each
/// test hops to the main actor for the store.
@Suite("SingWire — clip.setLyrics / clip.getLyrics reach ProjectStore.setClipLyrics (p2-sing-e)")
struct SingWireLyricsTests {

    func keys(_ value: JSONValue?) -> Set<String> { Set(value?.objectValue.map { Array($0.keys) } ?? []) }

    struct Rig {
        let router: CommandRouter
        let store: ProjectStore
        let clipID: UUID
        let spy: SingWireLyricsSpy
    }

    private func rig(lyrics: String? = nil) async throws -> Rig {
        let root = try SingWireFixture.tempDir("lyrics")
        return try await MainActor.run {
            let (store, clipID) = try SingWireFixture.store(root: root, lyrics: lyrics)
            let spy = SingWireLyricsSpy(store: store)
            return Rig(router: CommandRouter(store: store, singLyrics: spy), store: store, clipID: clipID, spy: spy)
        }
    }

    private func setLyrics(_ rig: Rig, _ text: String, dryRun: Bool? = nil, clip: UUID? = nil) async -> ControlResponse {
        var params: [String: JSONValue] = ["clipId": .string((clip ?? rig.clipID).uuidString), "text": .string(text)]
        if let dryRun { params["dryRun"] = .bool(dryRun) }
        return await rig.router.handle(SingWireFixture.request("clip.setLyrics", params))
    }

    @Test("SPY: clip.setLyrics stores through setClipLyrics, once, as the undo step \"Set Lyrics\"")
    func setLyricsReachesSetClipLyrics() async throws {
        let rig = try await self.rig()
        let response = await setLyrics(rig, SingWireFixture.twoUnitLyrics)
        #expect(response.ok, "\(response.error ?? "")")
        let calls = await MainActor.run { rig.spy.calls }
        #expect(calls == [.init(clipId: rig.clipID, text: SingWireFixture.twoUnitLyrics, undoLabel: "Set Lyrics")])
        #expect(response.result?["stored"]?.boolValue == true)
        #expect(response.result?["changed"]?.boolValue == true)
        let words = response.result?["assignment"]?["words"]?.arrayValue ?? []
        #expect(words.map { $0["text"]?.stringValue ?? "" }
            == ["one", "two", "three", "four", "five", "six", "seven", "eight"])
        #expect(words.allSatisfy { ($0["noteIds"]?.arrayValue?.count ?? 0) == 1 })
        #expect(response.result?["assignment"]?["lines"]?.doubleValue == 2)
        let stored = await MainActor.run {
            rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID }?.lyrics?.text
        }
        #expect(stored == SingWireFixture.twoUnitLyrics)
        #expect(try await MainActor.run { try rig.store.undo() } == "Set Lyrics")
        let afterUndo = await MainActor.run { rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID }?.lyrics }
        #expect(afterUndo == nil)
    }

    @Test("dryRun answers the same assignment and stores nothing; the same text twice records no second step")
    func dryRunAndUnchangedStoreNothing() async throws {
        let rig = try await self.rig()
        let dry = await setLyrics(rig, SingWireFixture.twoUnitLyrics, dryRun: true)
        #expect(dry.ok, "\(dry.error ?? "")")
        #expect(dry.result?["stored"]?.boolValue == false)
        #expect(dry.result?["assignment"]?["words"]?.arrayValue?.count == 8)
        #expect(await MainActor.run { rig.spy.calls.isEmpty })
        #expect(await MainActor.run { rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID }?.lyrics } == nil)

        _ = await setLyrics(rig, SingWireFixture.twoUnitLyrics)
        let again = await setLyrics(rig, SingWireFixture.twoUnitLyrics)
        #expect(again.ok)
        #expect(again.result?["changed"]?.boolValue == false)
        #expect(await MainActor.run { rig.spy.calls.count } == 1, "an edit that changes nothing records no step")
    }

    @Test("\"\" clears the lyrics, through the same write")
    func emptyTextClears() async throws {
        let rig = try await self.rig(lyrics: "la la")
        let response = await setLyrics(rig, "")
        #expect(response.ok, "\(response.error ?? "")")
        #expect(response.result?["text"]?.stringValue == "")
        #expect(response.result?["assignment"]?["words"]?.arrayValue?.isEmpty == true)
        #expect(await MainActor.run { rig.spy.calls.map(\.text) } == [""])
        #expect(await MainActor.run { rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID }?.lyrics } == nil)
    }

    @Test("every refusal reads \"<code>: <sentence>\" exactly, and NOTHING is written")
    func refusalsAreExactAndWriteNothing() async throws {
        let rig = try await self.rig()
        let audioClipID = try await MainActor.run { () -> UUID in
            let track = rig.store.addTrack(kind: .audio)
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("sing-wire-\(UUID()).wav")
            try SingWAV.writeFloat32Mono([Float](repeating: 0, count: 4_800), sampleRate: 48_000, to: wav)
            return try rig.store.importAudio(url: wav, toTrack: track.id, atBeat: 0).id
        }
        let unknown = UUID()
        let cases: [(String, UUID, String)] = [
            ("one two", unknown,
             "clipNotFound: no clip with id \(unknown.uuidString) — use project.snapshot to list clips"),
            ("one two", audioClipID,
             "lyricsNeedMIDIClip: Sing needs a melody clip with notes. This one is audio."),
            ("one two three four five\nfive six seven eight", rig.clipID,
             "lyricsTooManyWords: This line has 5 words but the tune has 4 notes. Each note sings one word, "
                 + "so remove 1 word or add 1 note."),
            ("one two café four\nfive six seven eight", rig.clipID,
             "lyricsNotEnglish: I can only sing English words so far — 'café' isn't one I can pronounce."),
            (String(repeating: "a", count: 4_001), rig.clipID,
             "lyricsTooLong: The words can be up to 4,000 characters long, and this would go over. Shorten them first."),
        ]
        for (text, clip, expected) in cases {
            for dryRun in [false, true] {
                let response = await setLyrics(rig, text, dryRun: dryRun, clip: clip)
                #expect(!response.ok)
                #expect(response.error == expected, "dryRun \(dryRun)")
            }
        }
        #expect(await MainActor.run { rig.spy.calls.isEmpty })
        #expect(await MainActor.run { rig.store.tracks.flatMap(\.clips).allSatisfy { $0.lyrics == nil } })
    }

    @Test("x7 added language/wordless/wordlessPerNote (SingWireExpansionTests): a typo'd key is still refused with the teaching hint")
    func noLanguageParam() async throws {
        let rig = try await self.rig()
        let response = await rig.router.handle(SingWireFixture.request("clip.setLyrics", [
            "clipId": .string(rig.clipID.uuidString), "text": .string("la"), "langauge": .string("en")]))
        #expect(response.error
            == "clip.setLyrics: unknown parameter 'langauge' — valid keys are 'clipId', 'dryRun', 'language', 'text', "
                + "'wordless', 'wordlessPerNote'")
        #expect(await MainActor.run { rig.spy.calls.isEmpty })
    }

    @Test("clip.getLyrics derives the words NOW: notes changed under stored words come back as a problem, not a throw")
    func getLyricsDerivesNow() async throws {
        let rig = try await self.rig(lyrics: SingWireFixture.twoUnitLyrics)
        let get = SingWireFixture.request("clip.getLyrics", ["clipId": .string(rig.clipID.uuidString)])
        let first = await rig.router.handle(get)
        #expect(first.ok, "\(first.error ?? "")")
        #expect(first.result?["text"]?.stringValue == SingWireFixture.twoUnitLyrics)
        #expect(first.result?["assignment"]?["words"]?.arrayValue?.count == 8)
        #expect(first.result?["problem"] == .null)

        // Drop the second phrase's notes: the second line's four words now have no notes.
        try await MainActor.run {
            let clip = try #require(rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID })
            _ = try rig.store.setClipNotes(clipID: rig.clipID, notes: Array((clip.notes ?? []).prefix(4)))
        }
        let second = await rig.router.handle(get)
        #expect(second.ok, "\(second.error ?? "")")
        #expect(second.result?["problem"]?["code"]?.stringValue == "lyricsTooManyWords")
        #expect(second.result?["assignment"]?["words"]?.arrayValue?.isEmpty == true)

        let unknown = UUID()
        let missing = await rig.router.handle(SingWireFixture.request("clip.getLyrics",
                                                                      ["clipId": .string(unknown.uuidString)]))
        #expect(missing.error == "clipNotFound: no clip with id \(unknown.uuidString) — use project.snapshot to list clips")
    }

    @Test("S6 pin-before: the reply keys of clip.setLyrics and clip.getLyrics (x7 must keep them without its new params)")
    func replyKeysArePinned() async throws {
        let rig = try await self.rig()
        let set = await setLyrics(rig, SingWireFixture.twoUnitLyrics)
        #expect(keys(set.result)
            == ["clipId", "text", "stored", "changed", "assignment", "warnings"])
        #expect(keys(set.result?["assignment"])
            == ["words", "lines", "phrases", "unsungNoteIds"])
        #expect(keys(set.result?["assignment"]?["words"]?.arrayValue?.first)
            == ["text", "noteIds", "startBeat", "endBeat", "held"])
        let get = await rig.router.handle(SingWireFixture.request("clip.getLyrics",
                                                                  ["clipId": .string(rig.clipID.uuidString)]))
        #expect(keys(get.result)
            == ["clipId", "text", "assignment", "warnings", "problem"])
    }

    @Test("braces are NOT markup yet (expansion §8.5 deferred): today they are dropped and the letters sung joined")
    func bracesTodayArePunctuation() async throws {
        let rig = try await self.rig()
        let text = "Siobhan{shi-vawn} two three\nfive six seven eight"
        let response = await setLyrics(rig, text, dryRun: true)
        #expect(response.ok, "\(response.error ?? "")")
        let first = response.result?["assignment"]?["words"]?.arrayValue?.first
        #expect(first?["text"]?.stringValue == "Siobhan{shi-vawn}")
        #expect(first?["noteIds"]?.arrayValue?.count == 2, "the hyphen inside the braces asks for two notes")
        try await MainActor.run {
            var clip = try #require(rig.store.tracks.flatMap(\.clips).first { $0.id == rig.clipID })
            clip.lyrics = ClipLyrics(text: text)
            let assignment = try SingPlanner.assignment(for: clip, tempoMap: rig.store.transport.tempoMap)
            #expect(assignment.words.first?.word.sung == "Siobhanshivawn", "today's sung form: braces dropped")
        }
    }
}
